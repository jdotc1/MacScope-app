import CryptoKit
import Foundation

/// Typed failures from a "Read Debug Symbols File…" import. Each carries a user-facing
/// message; the UUID-mismatch case is deliberately distinct (a wrong dSYM is the common,
/// recoverable user error — picking the build that doesn't correspond to the loaded binary).
enum DSYMImportError: LocalizedError, Equatable {
    case dwarfBinaryNotFound(URL)
    case unreadable(URL)
    case notMachO(String)
    case missingDSYMUUID
    case missingBinaryUUID
    /// No candidate slice (across every DWARF file in the bundle and every slice of each
    /// universal container) carries the loaded binary's UUID. `candidates` lists every slice
    /// examined, in file/slice order, including ones without LC_UUID or that failed to parse.
    case uuidMismatch(expected: String, candidates: [DSYMSliceIdentity])
    /// More than one slice carries the expected UUID; MacScope refuses to guess between them.
    case ambiguousUUIDMatch(uuid: String, candidates: [DSYMSliceIdentity])
    case tooManyDWARFFiles(URL, count: Int)
    case dwarf(DWARFReaderError)
    case noFunctionsRecovered
    /// HS-9: the dSYM matched a caller-supplied UUID, but the image it would be applied to
    /// carries a different LC_UUID. Debug names are never applied across a UUID mismatch.
    case imageUUIDMismatch(imageUUID: String, dsymUUID: String)

    var errorDescription: String? {
        switch self {
        case .dwarfBinaryNotFound(let url):
            "No DWARF binary was found inside \(url.lastPathComponent) (expected Contents/Resources/DWARF/…)."
        case .unreadable(let url):
            "The debug-symbols file at \(url.lastPathComponent) could not be read."
        case .notMachO(let reason):
            "The debug-symbols file is not a readable Mach-O: \(reason)."
        case .missingDSYMUUID:
            "The dSYM has no LC_UUID, so it cannot be matched to the loaded binary."
        case .missingBinaryUUID:
            "The loaded binary has no recorded UUID, so a dSYM cannot be safely matched to it."
        case .uuidMismatch(let expected, let candidates):
            "This dSYM does not match the loaded binary.\nLoaded binary UUID: \(expected)\n"
                + (candidates.count == 1 && candidates[0].sliceIndex == nil
                    ? "dSYM UUID: \(candidates[0].uuidDescription)"
                    : "dSYM slices:\n" + candidates.map { "  \($0.summary)" }.joined(separator: "\n"))
                + "\n\nOpen the dSYM produced for THIS build."
        case .ambiguousUUIDMatch(let uuid, let candidates):
            "More than one slice in the dSYM carries UUID \(uuid), so the debug symbols cannot be "
                + "attributed to exactly one of them:\n"
                + candidates.map { "  \($0.summary)" }.joined(separator: "\n")
        case .tooManyDWARFFiles(let url, let count):
            "\(url.lastPathComponent) contains \(count) DWARF files; at most "
                + "\(DSYMImportService.maximumDWARFFiles) are examined."
        case .dwarf(let underlying):
            underlying.errorDescription
        case .noFunctionsRecovered:
            "No named functions with addresses were recovered from the dSYM's debug info."
        case .imageUUIDMismatch(let imageUUID, let dsymUUID):
            "This dSYM was not generated for the loaded image.\nLoaded image LC_UUID: \(imageUUID)\n"
                + "dSYM UUID: \(dsymUUID)\n\nOpen the dSYM produced for THIS build."
        }
    }
}

/// One Mach-O slice examined while matching a dSYM to the loaded binary: a thin DWARF file
/// (`sliceIndex == nil`) or one architecture of a universal container.
struct DSYMSliceIdentity: Equatable, Sendable {
    /// Last path component of the DWARF file the slice lives in.
    var fileName: String
    /// Index in the fat architecture table; nil for a thin Mach-O.
    var sliceIndex: Int?
    /// Architecture from the slice's own Mach-O header (arm64 / arm64e / x86_64 / x86_64h /
    /// cpu(type,subtype)); for a slice that failed to parse, from its fat record.
    var architecture: String
    /// The slice's LC_UUID (lowercase canonical form); nil when it has none or failed to parse.
    var uuid: String?
    /// Why the slice could not be considered, when it failed to read/parse.
    var failure: String?

    var uuidDescription: String {
        if let uuid { return uuid }
        if let failure { return "unreadable (\(failure))" }
        return "no LC_UUID"
    }

    var summary: String {
        let location = sliceIndex.map { "\(fileName) slice \($0)" } ?? fileName
        return "\(location) [\(architecture)]: \(uuidDescription)"
    }
}

/// The outcome of a successful dSYM read: the recovered function symbols plus the matched
/// UUID, for the caller to inject into the workspace and report.
struct DSYMImportResult: Equatable {
    var functions: [DWARFFunctionSymbol]
    var signatures: [UInt64: FunctionSignatureOverride] = [:]
    /// Source attributes captured before any signature is merged into authored overrides.
    /// Authority requires the matched UUID, artifact seal and slice architecture below.
    var signatureDeclarations: [UInt64: DWARFFunctionDeclaration] = [:]
    /// Address-sorted DWARF line-table rows recovered from `.debug_line` (source file:line per
    /// address). Empty when the dSYM carried no line program.
    var sourceLines: [SourceLineEntry] = []
    /// Exact line-table evidence retained independently from the legacy display projection above.
    /// Production imports always populate this; synthetic/legacy test results may leave it empty.
    var canonicalLineRows: [LineRow] = []
    /// DWARF type DIEs recovered from `.debug_info`. Empty when the dSYM carries no modeled types
    /// or type recovery cannot enrich the import.
    var types: [DWARFType] = []
    var matchedUUID: String
    /// The DWARF Mach-O file that was actually read (inside the bundle, or the file itself).
    var dwarfURL: URL
    /// Cryptographic identity of the exact Mach-O slice selected by the parser, not the enclosing
    /// dSYM directory, filename, whole universal container, or a current-machine remap path.
    var debugArtifactSeal: DSYMDebugArtifactSeal? = nil
    /// Architecture of the UUID-matched slice (e.g. "arm64e"), for reporting. Nil only for
    /// synthetic/legacy results.
    var matchedSliceArchitecture: String? = nil
}

extension DSYMImportResult {
    /// HS-9: refuses to apply this result to an image whose LC_UUID differs from the dSYM UUID
    /// that was matched (which may have come from a caller-supplied override rather than the
    /// image). An image without LC_UUID has nothing to contradict; the caller's UUID is then the
    /// only gate, exactly as before.
    func requireMatchingImage(uuid imageUUID: String?) throws {
        guard let imageUUID, !imageUUID.isEmpty else { return }
        let matches: Bool
        if let image = UUID(uuidString: imageUUID), let dsym = UUID(uuidString: matchedUUID) {
            matches = image == dsym
        } else {
            matches = imageUUID.caseInsensitiveCompare(matchedUUID) == .orderedSame
        }
        guard matches else {
            throw DSYMImportError.imageUUIDMismatch(imageUUID: imageUUID, dsymUUID: matchedUUID)
        }
    }
}

struct DSYMDebugArtifactSeal: Equatable, Sendable {
    let uuid: UUID
    let selectedMachOSHA256: String
    let selectedMachOByteCount: UInt64
}

/// Reads debug symbols from a `.dSYM` bundle (or a bare DWARF Mach-O) and matches them to a
/// loaded binary by LC_UUID. Pure with respect to the workspace: it does the file I/O + parsing
/// and returns recovered functions, signatures, line rows, and best-effort types; the store does
/// the injection.
struct DSYMImportService {
    private let parser: MachOParser
    private let fileManager: FileManager

    init(parser: MachOParser = MachOParser(), fileManager: FileManager = .default) {
        self.parser = parser
        self.fileManager = fileManager
    }

    /// Reads `dsymURL` and recovers its function symbols, but ONLY when its UUID matches
    /// `expectedUUID` (the loaded binary's UUID). A nil/empty `expectedUUID` is itself an
    /// error: we never inject names from an unverified dSYM.
    func importDebugSymbols(at dsymURL: URL, expectedUUID: String?) throws -> DSYMImportResult {
        guard let expectedUUID, !expectedUUID.isEmpty else {
            throw DSYMImportError.missingBinaryUUID
        }

        // UUID-directed selection across every DWARF file and every universal slice: never the
        // first file, the first slice or the host architecture.
        let selection = try selectMatchingSlice(at: dsymURL, expectedUUID: expectedUUID)
        let dwarfURL = selection.url
        let bytes = selection.containerBytes
        let machO = selection.machO
        let foundUUID = selection.uuid
        guard let canonicalUUID = UUID(uuidString: foundUUID) else {
            throw DSYMImportError.missingDSYMUUID
        }
        let selectedMachOBytes = try exactSelectedMachOBytes(machO: machO, containerBytes: bytes)
        let selectedMachOSHA256 = SHA256.hash(data: selectedMachOBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let artifactSeal = DSYMDebugArtifactSeal(
            uuid: canonicalUUID,
            selectedMachOSHA256: selectedMachOSHA256,
            selectedMachOByteCount: UInt64(selectedMachOBytes.count)
        )

        // MachOParser reports section file offsets relative to the selected thin slice. Hash and
        // slice the exact same byte view; applying those offsets to the enclosing universal file
        // would read unrelated container bytes when the selected slice starts above zero.
        let sections = extractDWARFSections(machO: machO, bytes: selectedMachOBytes)
        let functions: [DWARFFunctionSymbol]
        do {
            functions = try DWARFReader(sections: sections).recoverFunctionSymbols()
        } catch let error as DWARFReaderError {
            throw DSYMImportError.dwarf(error)
        }

        guard !functions.isEmpty else {
            throw DSYMImportError.noFunctionsRecovered
        }

        let signatureRecovery = DWARFFunctionSignatureReader(sections: sections)
            .recoverSignaturesAndDeclarations()
        let types = (try? DWARFReader(sections: sections).recoverTypes()) ?? []

        // Recover the line-number program (address → source file:line). The line/line_str/str
        // sections were already sliced above; an absent line program just yields no rows.
        let canonicalLineRows = DWARFLineProgram(
            debugLine: sections.debugLine,
            debugLineStr: sections.debugLineStr,
            debugStr: sections.debugStr
        ).decode()
        let sourceLines = canonicalLineRows
            .map { row in
                let hasCompleteLineAuthority = row.fileTableIndex != nil
                    && row.canonicalTablePath != nil
                return SourceLineEntry(
                    address: row.address,
                    file: row.file,
                    line: Int(clamping: row.line),
                    column: Int(clamping: row.column),
                    endSequence: row.endSequence,
                    debugArtifactUUID: hasCompleteLineAuthority ? artifactSeal.uuid : nil,
                    debugArtifactMachOSHA256: hasCompleteLineAuthority
                        ? artifactSeal.selectedMachOSHA256 : nil,
                    debugArtifactMachOByteCount: hasCompleteLineAuthority
                        ? artifactSeal.selectedMachOByteCount : nil,
                    lineProgramUnitOffset: hasCompleteLineAuthority
                        ? row.lineProgramUnitOffset : nil,
                    fileTableIndex: hasCompleteLineAuthority ? row.fileTableIndex : nil,
                    tablePath: hasCompleteLineAuthority ? row.canonicalTablePath : nil
                )
            }
            .sorted { $0.address < $1.address }

        return DSYMImportResult(functions: functions, signatures: signatureRecovery.signatures,
                                signatureDeclarations: signatureRecovery.declarations,
                                sourceLines: sourceLines, canonicalLineRows: canonicalLineRows,
                                types: types, matchedUUID: foundUUID, dwarfURL: dwarfURL,
                                debugArtifactSeal: artifactSeal,
                                matchedSliceArchitecture: selection.identity.architecture)
    }

    /// Upper bound on DWARF files examined inside one bundle. Real dSYMs carry one (named after
    /// the binary); a few tools emit one per image. A hostile directory must not drive
    /// unbounded mapping/parsing.
    static let maximumDWARFFiles = 16

    private static let parseOptions = MachOParseOptions(
        // Parse only what we need — no string/ObjC/Swift/code-signature recovery — so a dSYM
        // (which has no real __TEXT payload) parses fast and never trips an unrelated path.
        recoverStringLiterals: false,
        recoverObjectiveCMetadata: false,
        recoverSwiftMetadata: false,
        parseCodeSignature: false
    )

    private struct SliceSelection {
        var url: URL
        var containerBytes: Data
        var machO: MachOFile
        var uuid: String
        var identity: DSYMSliceIdentity
    }

    /// Examines every slice of every candidate DWARF file and returns the single one whose
    /// LC_UUID equals `expectedUUID`. A universal container's table must pass the parser's
    /// strict layout validation before any of its slices is considered; a slice whose own
    /// header disagrees with its fat record is rejected. Unreadable siblings do not block a
    /// valid match, but are listed when nothing matches.
    private func selectMatchingSlice(at dsymURL: URL, expectedUUID: String) throws -> SliceSelection {
        let files = try resolveDWARFCandidates(at: dsymURL)
        var candidates: [DSYMSliceIdentity] = []
        var matches: [SliceSelection] = []
        var failures: [String] = []

        for url in files {
            let fileName = url.lastPathComponent
            guard let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                if files.count == 1 { throw DSYMImportError.unreadable(url) }
                failures.append("\(fileName) could not be read")
                candidates.append(DSYMSliceIdentity(fileName: fileName, sliceIndex: nil,
                                                    architecture: "unknown", uuid: nil,
                                                    failure: "could not be read"))
                continue
            }

            let fatSlices: [MachOUniversalSlice]?
            do {
                fatSlices = try parser.strictUniversalSlices(in: bytes)
            } catch {
                // A structurally invalid fat table contributes no candidates at all: none of its
                // slice boundaries can be trusted.
                failures.append(files.count == 1
                    ? error.localizedDescription
                    : "\(fileName): \(error.localizedDescription)")
                continue
            }

            let requests: [MachOUniversalSlice?] = fatSlices.map { $0.map { Optional($0) } } ?? [nil]
            for fatSlice in requests {
                var options = Self.parseOptions
                options.requestedSliceIndex = fatSlice?.index
                let machO: MachOFile
                do {
                    machO = try parser.parse(bytes, options: options)
                    if let fatSlice {
                        try Self.requireHeaderMatchesFatRecord(machO.header, fatSlice)
                    }
                } catch {
                    let reason = error.localizedDescription
                    let location = fatSlice.map { "\(fileName) slice \($0.index)" } ?? fileName
                    failures.append(files.count == 1 && fatSlice == nil ? reason : "\(location): \(reason)")
                    candidates.append(DSYMSliceIdentity(
                        fileName: fileName,
                        sliceIndex: fatSlice?.index,
                        architecture: fatSlice.map {
                            Self.architectureName(cpuType: $0.cpuType, cpuSubtype: $0.cpuSubtype)
                        } ?? "unknown",
                        uuid: nil,
                        failure: reason
                    ))
                    continue
                }

                let uuid = machO.uuid?.stringValue
                let identity = DSYMSliceIdentity(
                    fileName: fileName,
                    sliceIndex: fatSlice?.index,
                    architecture: Self.architectureName(cpuType: machO.header.cpuType,
                                                        cpuSubtype: machO.header.cpuSubtype),
                    uuid: uuid,
                    failure: nil
                )
                candidates.append(identity)
                if let uuid, uuid.caseInsensitiveCompare(expectedUUID) == .orderedSame {
                    matches.append(SliceSelection(url: url, containerBytes: bytes, machO: machO,
                                                  uuid: uuid, identity: identity))
                }
            }
        }

        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw DSYMImportError.ambiguousUUIDMatch(uuid: expectedUUID,
                                                     candidates: matches.map(\.identity))
        }
        if candidates.contains(where: { $0.uuid != nil }) {
            throw DSYMImportError.uuidMismatch(expected: expectedUUID, candidates: candidates)
        }
        if let firstFailure = failures.first {
            throw DSYMImportError.notMachO(firstFailure)
        }
        throw DSYMImportError.missingDSYMUUID
    }

    /// A fat record names the slice's architecture; the slice's own header must agree (CPU type
    /// and subtype with capability bits masked) or the container is lying about what it holds —
    /// e.g. an "arm64e" record over an arm64 image.
    private static func requireHeaderMatchesFatRecord(_ header: MachOHeader, _ slice: MachOUniversalSlice) throws {
        let mask = ~MachOConstants.cpuSubtypeCapabilityMask
        guard header.cpuType == slice.cpuType,
              header.cpuSubtype & mask == slice.cpuSubtype & mask else {
            throw MachOParserError.invalidUniversalBinary(
                "slice \(slice.index) header architecture "
                    + "\(architectureName(cpuType: header.cpuType, cpuSubtype: header.cpuSubtype)) "
                    + "disagrees with its fat record "
                    + "\(architectureName(cpuType: slice.cpuType, cpuSubtype: slice.cpuSubtype))"
            )
        }
    }

    static func architectureName(cpuType: Int32, cpuSubtype: Int32) -> String {
        let variant = MachOSliceArchitectureVariant.classify(rawCPUType: cpuType, rawCPUSubtype: cpuSubtype)
        if variant != .other { return variant.rawValue }
        let maskedSubtype = cpuSubtype & ~MachOConstants.cpuSubtypeCapabilityMask
        return "cpu(\(cpuType),\(maskedSubtype))"
    }

    /// Every candidate DWARF Mach-O for `url`: the regular files under a `.dSYM` bundle's
    /// `Contents/Resources/DWARF/`, sorted by name, or `url` itself when it is a plain file
    /// (a bare DWARF Mach-O). Which one is used is decided by UUID, not by this order.
    func resolveDWARFCandidates(at url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else { throw DSYMImportError.dwarfBinaryNotFound(url) }

        // A bare file (e.g. the user pointed directly at the DWARF Mach-O): use it directly.
        guard isDirectory.boolValue else { return [url] }

        let dwarfDir = url
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("DWARF", isDirectory: true)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: dwarfDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DSYMImportError.dwarfBinaryNotFound(url)
        }

        let regularFiles = contents
            .filter { candidate in
                (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && fileManager.isReadableFile(atPath: candidate.path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !regularFiles.isEmpty else {
            throw DSYMImportError.dwarfBinaryNotFound(url)
        }
        guard regularFiles.count <= Self.maximumDWARFFiles else {
            throw DSYMImportError.tooManyDWARFFiles(url, count: regularFiles.count)
        }
        return regularFiles
    }

    /// The first DWARF candidate by name (see `resolveDWARFCandidates`). Retained for callers
    /// that need the file of a single-file bundle; import itself selects by UUID.
    func resolveDWARFBinary(at url: URL) throws -> URL {
        let candidates = try resolveDWARFCandidates(at: url)
        guard let first = candidates.first else { throw DSYMImportError.dwarfBinaryNotFound(url) }
        return first
    }

    /// Slices the `__DWARF` section bytes the reader consults out of the dSYM's mapped
    /// bytes. Each section is range-validated against the file; a missing or out-of-range
    /// section is simply absent (the reader degrades), never a crash.
    private func extractDWARFSections(machO: MachOFile, bytes: Data) -> DWARFReader.Sections {
        var sections = DWARFReader.Sections()
        for section in machO.sections where section.segmentName == "__DWARF" {
            guard let data = sliceSection(section, bytes: bytes) else { continue }
            switch section.sectionName {
            case "__debug_info":
                sections.debugInfo = data
            case "__debug_abbrev":
                sections.debugAbbrev = data
            case "__debug_str":
                sections.debugStr = data
            case "__debug_str_offs", "__debug_str_offsets":
                // Apple truncates the section name to 16 chars (__debug_str_offs); accept both.
                sections.debugStrOffsets = data
            case "__debug_addr":
                sections.debugAddr = data
            case "__debug_line":
                sections.debugLine = data
            case "__debug_line_str":
                sections.debugLineStr = data
            default:
                break
            }
        }
        return sections
    }

    private func exactSelectedMachOBytes(machO: MachOFile, containerBytes: Data) throws -> Data {
        let start = machO.selectedSliceOffset
        let byteCount = machO.universalBinary?.selectedSlice?.size ?? UInt64(containerBytes.count)
        let end = start.addingReportingOverflow(byteCount)
        guard byteCount > 0,
              !end.overflow,
              let lower = Int(exactly: start),
              let upper = Int(exactly: end.partialValue),
              lower >= 0,
              upper > lower,
              upper <= containerBytes.count else {
            throw DSYMImportError.notMachO("selected DWARF Mach-O slice is out of bounds")
        }
        return containerBytes.subdata(in: lower..<upper)
    }

    /// Bounds-checked extraction of `[fileOffset, fileOffset+size)` from the file bytes.
    /// nil for a zero-size or out-of-range section (so the reader treats it as absent).
    private func sliceSection(_ section: MachOSection, bytes: Data) -> Data? {
        // `section.size` is an attacker-controlled UInt64: `Int(section.size)` TRAPS above Int.max
        // and `start + Int(section.size)` can overflow Int — both BEFORE the post-read range guard.
        // Convert and add with overflow checks so a hostile section degrades to absent, never a crash.
        guard section.size > 0, let size = Int(exactly: section.size) else { return nil }
        let start = Int(section.fileOffset) // UInt32 → always representable as Int
        let (end, overflow) = start.addingReportingOverflow(size)
        guard !overflow, start <= end, end <= bytes.count else { return nil }
        let base = bytes.startIndex
        return bytes.subdata(in: (base + start)..<(base + end))
    }
}
