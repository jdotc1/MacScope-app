import Foundation

/// MS-15: the one capture/recheck path shared by the GUI "Save Patched Binary" handler (focused
/// image) and scripting `save-patched-binary` (primary image). Neither reads `binary.path`: the
/// output is derived from the image bytes captured when the workspace loaded it; only the source
/// file's permission bits are read from `binary.path`, so the patched copy stays executable.
struct PatchedBinaryExportCapture: Sendable {
    let slot: ImageSlot
    let binaryName: String
    let rawBytes: Data
    let identity: PreparedMachOPatchExport.Identity
    let patches: [UInt64: BytePatch]
    let appendedCave: AppendedExecutableCaveAuthoring?
    /// The mode the written copy gets: the source file's permission bits when it could be read at
    /// capture, else 0755 for a Mach-O executable, else nil (the default for a new file).
    var outputPermissions: Int? = nil

    /// Pure; safe to run off the main actor.
    func prepare() throws -> PreparedMachOPatchExport {
        try PreparedMachOPatchExport.prepare(
            rawBytes: rawBytes, identity: identity, patches: patches,
            appendedCave: appendedCave
        )
    }

    /// Writes the finished bytes and gives the file `outputPermissions`. `Data.write(.atomic)`
    /// alone creates a 0644 file, so an exported executable would not run even after re-signing.
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        if let outputPermissions {
            try FileManager.default.setAttributes([.posixPermissions: outputPermissions], ofItemAtPath: url.path)
        }
    }

    static func outputPermissions(sourcePath: String, rawBytes: Data) -> Int? {
        if !sourcePath.isEmpty,
           let mode = (try? FileManager.default.attributesOfItem(atPath: sourcePath))?[.posixPermissions] as? NSNumber {
            return mode.intValue & 0o777
        }
        return isMachOExecutable(rawBytes) ? 0o755 : nil
    }

    /// A thin 64-bit little-endian Mach-O whose header filetype is MH_EXECUTE.
    private static func isMachOExecutable(_ bytes: Data) -> Bool {
        guard bytes.count >= 16 else { return false }
        func word(_ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
        }
        return word(0) == MachOConstants.machMagic64 && word(12) == MachOConstants.fileTypeExecute
    }
}

/// The GUI Save Patched Binary sequence after capture: prepare off the main actor, ask for a
/// destination, then write. The requesting document can be retired at every await and around the
/// app-modal panel, so the owner is rechecked before the error alert, before the panel and between
/// the panel and the write; a retired owner gets no panel and no write. The panel and the write
/// are injected so the fence is testable without AppKit.
@MainActor
struct PatchedBinarySaveSequence {
    var isCurrentOwner: @MainActor () -> Bool
    var prepare: @MainActor () async throws -> PreparedMachOPatchExport
    /// Gets the prepared export so the panel can state how the output is signed.
    var chooseDestination: @MainActor (PreparedMachOPatchExport) -> URL?
    /// Rechecks identity and patch map, writes and reports; handles its own errors.
    var write: @MainActor (PreparedMachOPatchExport, URL) -> Void
    var reportPreparationError: @MainActor (Error) -> Void

    func run() async {
        let prepared: PreparedMachOPatchExport
        do {
            prepared = try await prepare()
        } catch {
            guard !Task.isCancelled, isCurrentOwner() else { return }
            reportPreparationError(error)
            return
        }
        guard !Task.isCancelled, isCurrentOwner() else { return }
        guard let url = chooseDestination(prepared) else { return }
        guard !Task.isCancelled, isCurrentOwner() else { return }
        write(prepared, url)
    }
}

enum PatchedBinaryExportError: LocalizedError, Equatable {
    case noImage
    case noCapturedBytes(name: String)
    case multipleAppendedCaves
    case invalidAppendedCaveAnchor

    var errorDescription: String? {
        switch self {
        case .noImage:
            return "No binary is loaded to patch."
        case .noCapturedBytes(let name):
            return "\(name) has no captured image bytes in this workspace, so a patched copy cannot be derived from them."
        case .multipleAppendedCaves:
            return "This image has more than one appended executable cave; resolve the conflicting edits before export."
        case .invalidAppendedCaveAnchor:
            return "The appended code is no longer attached to its original function. Clear or reauthor it before export."
        }
    }
}

extension WorkspaceStore {
    /// The identity of `slot`'s image as it stands NOW: owner, slot, origin and the selected-slice
    /// digest. `artifactIdentity` is the authority when the loader reconstructed one; otherwise the
    /// captured bytes' own digest stands in (synthetic or anonymous images).
    func patchedBinaryExportIdentity(in slot: ImageSlot) -> PreparedMachOPatchExport.Identity? {
        guard let binary = snapshot.binary(in: slot),
              let bytes = snapshot.analysis(in: slot)?.imageBytes, !bytes.isEmpty else { return nil }
        let digest: String
        let byteCount: Int
        if let artifact = binary.artifactIdentity,
           let count = Int(exactly: artifact.selectedSliceByteCount) {
            digest = artifact.selectedSliceSHA256
            byteCount = count
        } else {
            digest = PreparedMachOPatchExport.sha256(bytes)
            byteCount = bytes.count
        }
        return PreparedMachOPatchExport.Identity(
            imageOwnerID: binary.id, slotRawValue: slot.rawValue, origin: binary.captureOrigin,
            selectedSliceSHA256: digest, selectedSliceByteCount: byteCount
        )
    }

    /// Captures, in one MainActor turn, the bytes, identity and patch map to export for `slot`.
    func capturePatchedBinaryExport(in slot: ImageSlot) throws -> PatchedBinaryExportCapture {
        guard let binary = snapshot.binary(in: slot) else { throw PatchedBinaryExportError.noImage }
        guard let bytes = snapshot.analysis(in: slot)?.imageBytes, !bytes.isEmpty,
              let identity = patchedBinaryExportIdentity(in: slot) else {
            throw PatchedBinaryExportError.noCapturedBytes(name: binary.name)
        }
        let cave = try validatedAppendedCave(in: slot)
        return PatchedBinaryExportCapture(
            slot: slot, binaryName: binary.name, rawBytes: bytes,
            identity: identity, patches: snapshot.patches(in: slot),
            appendedCave: cave,
            outputPermissions: PatchedBinaryExportCapture.outputPermissions(sourcePath: binary.path, rawBytes: bytes)
        )
    }

    /// Back on the MainActor immediately before writing: the prepared output, or
    /// `.staleInvestigation` when the image's owner/identity or its patch map changed since capture.
    func finishPatchedBinaryExport(_ prepared: PreparedMachOPatchExport, in slot: ImageSlot) throws -> Data {
        let cave: AppendedExecutableCaveAuthoring?
        do {
            cave = try validatedAppendedCave(in: slot)
        } catch {
            throw PreparedMachOPatchExport.PreparationError.staleInvestigation
        }
        return try prepared.data(ifStillOwnedBy: patchedBinaryExportIdentity(in: slot),
                          currentPatches: snapshot.patches(in: slot),
                          currentAppendedCave: cave)
    }

    private func validatedAppendedCave(in slot: ImageSlot) throws -> AppendedExecutableCaveAuthoring? {
        let caves = snapshot.addressOverrides.compactMap { key, override -> (ImageAddress, AppendedExecutableCaveAuthoring)? in
            guard key.slot == slot, let cave = override.appendedExecutableCave else { return nil }
            return (key, cave)
        }
        guard caves.count <= 1 else { throw PatchedBinaryExportError.multipleAppendedCaves }
        guard let (key, cave) = caves.first else { return nil }
        guard let binary = snapshot.binary(in: slot),
              let analysis = snapshot.analysis(in: slot),
              let function = analysis.functions.first(where: { $0.id == cave.functionID }),
              cave.isWellFormed,
              cave.ownerBinaryID == binary.id,
              key.address == function.startAddress,
              function.startAddress < function.endAddress,
              function.endAddress >= 4,
              function.startAddress <= cave.branchSourceAddress,
              cave.branchSourceAddress <= function.endAddress - 4 else {
            throw PatchedBinaryExportError.invalidAppendedCaveAnchor
        }
        return cave
    }
}
