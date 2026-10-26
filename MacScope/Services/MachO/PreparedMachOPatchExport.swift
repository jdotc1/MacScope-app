import CryptoKit
import Foundation

/// MS-15: Save Patched Binary from the CAPTURED image bytes, never from whatever file is at
/// `binary.path` now. Shared by the GUI "Save Patched Binary" handler and scripting
/// `save-patched-binary` (see `WorkspaceStore+PatchedBinaryExport.swift`).
///
/// The host captures, in ONE MainActor turn:
/// - `rawBytes`: `ImageAnalysis.imageBytes` for the exported image (the retained selected
///   slice, the same bytes persisted as a package attachment);
/// - `identity`: built from `BinaryImage.artifactIdentity` (`MachOSliceArtifactIdentity`
///   carries the selected-slice SHA-256 and byte count), the image owner and its
///   `ImageSlot.rawValue`, plus how the image was obtained;
/// - `patches`: `patches(in: slot)`.
/// It then calls `prepare` (off the main actor where the caller can await) and, back on the
/// MainActor before writing, `data(ifStillOwnedBy:currentPatches:)`.
struct PreparedMachOPatchExport: Sendable {
    /// How the captured bytes relate to a file on disk. Only `.thinFile` keeps today's
    /// writer contract (a thin Mach-O file in, a thin Mach-O file out). Exporting a
    /// universal binary's selected slice or a dyld-cache projection would silently change
    /// what "Save Patched Binary" produces, so both are refused until an explicit
    /// "export selected slice" workflow exists.
    enum Origin: Equatable, Sendable {
        case thinFile, universalSlice, dyldCacheProjection, other
    }

    /// D07: a changed signed executable is re-signed ad hoc in process; otherwise the output keeps
    /// the copied (invalid) signature and needs an external re-sign.
    enum Signing: Equatable, Sendable {
        /// The bytes are unchanged and carry a code-signature command; validity is not re-verified.
        case unchanged
        case adHoc(identifier: String, warnings: [String])
        case unsigned(reason: String)

        var summary: String {
            switch self {
            case .unchanged:
                return "The output matches the captured bytes; it keeps the input's code signature (not re-verified)."
            case let .adHoc(identifier, warnings):
                return (["The output is ad-hoc signed (identifier \(identifier)); it carries no team or certificate identity."]
                    + warnings).joined(separator: " ")
            case let .unsigned(reason):
                return "The output is UNSIGNED (\(reason)); re-sign it before running, e.g. codesign -f -s - <file>."
            }
        }
    }

    struct Identity: Equatable, Sendable {
        let imageOwnerID: UUID
        let slotRawValue: Int
        let origin: Origin
        /// `MachOSliceArtifactIdentity.selectedSliceSHA256`, lowercase hex.
        let selectedSliceSHA256: String
        /// `MachOSliceArtifactIdentity.selectedSliceByteCount`.
        let selectedSliceByteCount: Int
    }

    enum PreparationError: LocalizedError, Equatable {
        case unsupportedOrigin(Origin)
        case byteIdentityMismatch
        case staleInvestigation

        var errorDescription: String? {
            switch self {
            case .unsupportedOrigin(.universalSlice):
                // Same contract (and text) as today's fat-original refusal.
                return MachOPatchWriter.PatchWriteError.fatBinaryUnsupported.errorDescription
            case .unsupportedOrigin(.dyldCacheProjection):
                return "Saving a patched binary is not supported for an image projected from a dyld shared cache."
            case .unsupportedOrigin:
                return "Saving a patched binary is only supported for thin Mach-O files."
            case .byteIdentityMismatch:
                return "The captured image bytes no longer match the image's recorded identity, so no patched copy was written."
            case .staleInvestigation:
                return "The image or its patches changed while the export was being prepared. Start Save Patched Binary again."
            }
        }
    }

    let identity: Identity
    let patchDigest: String
    let appendedCave: AppendedExecutableCaveAuthoring?
    let outputSHA256: String
    /// True when the output differs from the captured bytes. An altered signed binary
    /// needs re-signing before it can run; keep the existing signature warning.
    let bytesChanged: Bool
    /// D07: how the changed output is signed.
    let signing: Signing
    let patchCount: Int
    private let outputBytes: Data

    static func prepare(rawBytes: Data, identity: Identity,
                        patches: [UInt64: BytePatch],
                        appendedCave: AppendedExecutableCaveAuthoring? = nil) throws -> Self {
        guard identity.origin == .thinFile else {
            throw PreparationError.unsupportedOrigin(identity.origin)
        }
        guard rawBytes.count == identity.selectedSliceByteCount,
              sha256(rawBytes) == identity.selectedSliceSHA256 else {
            throw PreparationError.byteIdentityMismatch
        }
        // Keeps the writer's thin-Mach-O checks, mapping/overlap semantics and typed errors.
        let output: Data
        if let appendedCave {
            guard appendedCave.isWellFormed,
                  appendedCave.ownerBinaryID == identity.imageOwnerID,
                  appendedCave.selectedSliceSHA256 == identity.selectedSliceSHA256 else {
                throw PreparationError.byteIdentityMismatch
            }
            output = try MachOPatchWriter().makePatchedDataWithAppendedExecutableCave(
                originalData: rawBytes, patches: patches,
                caveBytes: appendedCave.codeBytes,
                branchSourceAddress: appendedCave.branchSourceAddress
            ).data
        } else {
            output = try MachOPatchWriter().makePatchedData(originalData: rawBytes, patches: patches)
        }
        let bytesChanged = output != rawBytes
        var signed = output
        let signing: Signing
        if !bytesChanged {
            signing = MachOAdHocSigner.hasCodeSignatureCommand(rawBytes)
                ? .unchanged : .unsigned(reason: "the input has no code signature")
        } else {
            do {
                let outcome = try MachOAdHocSigner.resign(output)
                signed = outcome.data
                signing = .adHoc(identifier: outcome.identifier, warnings: outcome.warnings)
            } catch let refusal as MachOAdHocSigner.Refusal {
                signing = .unsigned(reason: Self.reason(refusal))
            }
        }
        return .init(identity: identity, patchDigest: canonicalPatchDigest(patches),
                     appendedCave: appendedCave,
                     outputSHA256: sha256(signed), bytesChanged: bytesChanged, signing: signing,
                     patchCount: patches.count + (appendedCave == nil ? 0 : 1), outputBytes: signed)
    }

    private static func reason(_ refusal: MachOAdHocSigner.Refusal) -> String {
        switch refusal {
        case .notThinARM64Executable: "not a thin arm64 executable"
        case .noCodeSignature: "the input has no code signature"
        case .signatureNotFinalLinkeditPayload: "its code signature is not the final __LINKEDIT payload"
        case .malformedSignature: "its code signature could not be read"
        case .layoutOverflow: "the signed layout would overflow"
        }
    }

    /// Call on the MainActor immediately before the atomic write. Refuses when the image
    /// or its patch map changed after capture, e.g. a patch edit while the Save panel was open.
    func data(ifStillOwnedBy current: Identity?, currentPatches: [UInt64: BytePatch],
              currentAppendedCave: AppendedExecutableCaveAuthoring? = nil) throws -> Data {
        guard let current, current == identity,
              Self.canonicalPatchDigest(currentPatches) == patchDigest,
              currentAppendedCave == appendedCave else {
            throw PreparationError.staleInvestigation
        }
        return outputBytes
    }

    /// Order-independent digest of a patch map: address-sorted (UInt64 LE address,
    /// UInt32 LE byte count, bytes). Empty patches are skipped, matching how the store prunes them.
    static func canonicalPatchDigest(_ patches: [UInt64: BytePatch]) -> String {
        var encoded = Data()
        for (address, patch) in patches.sorted(by: { $0.key < $1.key }) where !patch.isEmpty {
            withUnsafeBytes(of: address.littleEndian) { encoded.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(patch.bytes.count).littleEndian) { encoded.append(contentsOf: $0) }
            encoded.append(contentsOf: patch.bytes)
        }
        return sha256(encoded)
    }

    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension BinaryImage {
    /// How this image's captured bytes were obtained. Byte authority stays the captured
    /// `imageBytes`; this only classifies the origin from the persisted identity record (a dyld
    /// cache's unnamed image is recognised by the 16-byte magic of the cache file it names).
    var captureOrigin: PreparedMachOPatchExport.Origin {
        if elfArchiveMemberIdentity != nil { return .other }
        if isNamedDyldCacheProjection || isUnnamedDyldCacheImage { return .dyldCacheProjection }
        guard let fact = machOSelectedSliceFact else { return .other }
        return fact.containerKind == .universal ? .universalSlice : .thinFile
    }

    /// `DyldSharedCacheBinaryLoader` names a projected image `"<cache path>(<image path>)"`,
    /// a display path that names no file.
    var isNamedDyldCacheProjection: Bool {
        guard path.hasSuffix(")"), path.contains("(") else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// The open-time cache image choice recorded in a named projection's display path
    /// (`"<cache path>(<install name>)"`): the cache file and the install name to project again.
    /// Nil unless the cache prefix is an existing dyld shared cache file. Splits are tried from the
    /// last `(` so an install name never swallows a cache directory containing parentheses.
    var dyldCacheProjectionSelection: (cacheURL: URL, installName: String)? {
        guard elfArchiveMemberIdentity == nil, path.hasSuffix(")") else { return nil }
        let body = path.dropLast()
        var searchEnd = body.endIndex
        while let open = body[..<searchEnd].lastIndex(of: "(") {
            let cachePath = String(body[..<open])
            let installName = String(body[body.index(after: open)...])
            if !cachePath.isEmpty,
               BinaryLoadSelection.isWellFormedDyldCacheImagePath(installName),
               let handle = FileHandle(forReadingAtPath: cachePath) {
                defer { try? handle.close() }
                if let magic = try? handle.read(upToCount: 16), DyldSharedCacheParser.isDyldSharedCache(magic) {
                    return (URL(fileURLWithPath: cachePath), installName)
                }
            }
            searchEnd = open
        }
        return nil
    }

    /// A dyld-cache image without an install name (the loader's empty-name
    /// `?? header.images.first` path) keeps the bare cache path as its `path`. Reloading that
    /// path selects the cache's first NAMED image instead, so this image cannot be recaptured.
    var isUnnamedDyldCacheImage: Bool {
        guard !path.isEmpty, elfArchiveMemberIdentity == nil,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 16) else { return false }
        return DyldSharedCacheParser.isDyldSharedCache(magic)
    }
}

/// MS-16: a structural reanalysis the store refused instead of silently analyzing other bytes.
enum ReanalysisRefusal: Error, Equatable, Sendable {
    /// The image came from a dyld shared cache without an install name; the retained projection
    /// lacks the cache context, and reloading the cache path would select a different image.
    /// The prior accepted analysis is kept unchanged. Reopen the image from the cache to recapture.
    case recaptureRequired(slot: ImageSlot)
    /// The image is an exact ELF static-archive member. Its reanalysis authority is the persisted
    /// outer `.a` path plus the member selection (the loader re-checks container and member
    /// hashes); a retained-bytes temp copy would drop that provenance. The outer archive is no
    /// longer at its recorded path, so the prior accepted analysis is kept unchanged.
    case archiveContainerUnavailable(slot: ImageSlot, path: String)

    var message: String {
        switch self {
        case .recaptureRequired:
            return "Couldn’t reanalyze: this image was projected from a dyld shared cache without an install name, "
                + "so it can’t be recaptured. The previous analysis is unchanged; reopen the image from the cache to reanalyze it."
        case .archiveContainerUnavailable(_, let path):
            return "Couldn’t reanalyze: this archive member’s container is no longer at \(path). "
                + "The previous analysis is unchanged; restore the archive or reopen the member from it to reanalyze."
        }
    }
}
