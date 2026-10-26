import Foundation
import zlib
import Darwin

enum MachOImportError: LocalizedError {
    case executableNotFound(URL)
    case unreadableExecutable(URL)
    case unsupportedArchitecture(String)
    case additionalBinaryRejected(URL)
    case additionalBundleRejected(URL)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let url):
            "No executable could be resolved for \(url.path)."
        case .unreadableExecutable(let url):
            "The executable at \(url.path) could not be read."
        case .unsupportedArchitecture(let architecture):
            "MacScope can only import arm64 or x86_64 Mach-O files in this slice. Found \(architecture)."
        case .additionalBinaryRejected(let url):
            "Loading additional binaries is disabled by the current import policy: \(url.path)."
        case .additionalBundleRejected(let url):
            "Loading app bundles as additional binaries is disabled by the current import policy: \(url.path)."
        }
    }
}

enum MachOImportPurpose: Sendable {
    case primary
    case additional
}

enum MachOAdditionalBinaryPolicy: String, Sendable {
    case reject
    case allowMachOFiles
    case allowMachOFilesAndBundles
}

struct MachOImportOptions: Hashable, Sendable {
    var parseOptions: MachOParseOptions
    var additionalBinaryPolicy: MachOAdditionalBinaryPolicy

    init(
        parseOptions: MachOParseOptions = .default,
        additionalBinaryPolicy: MachOAdditionalBinaryPolicy = .reject
    ) {
        self.parseOptions = parseOptions
        self.additionalBinaryPolicy = additionalBinaryPolicy
    }

    static let `default` = MachOImportOptions()
}

struct MachOImportDiagnostic: Hashable, Sendable {
    enum Severity: String, Sendable {
        case info
        case warning
    }

    var severity: Severity
    var code: String
    var message: String
}

struct MachOImportResult: Sendable {
    var originalURL: URL
    var executableURL: URL
    var isBundle: Bool
    var bytes: Data
    var machO: MachOFile
    var diagnostics: [MachOImportDiagnostic]
}

struct MachOImportService: @unchecked Sendable {
    private let parser: MachOParser
    private let fileManager: FileManager

    init(parser: MachOParser = MachOParser(), fileManager: FileManager = .default) {
        self.parser = parser
        self.fileManager = fileManager
    }

    func importBinary(
        at url: URL,
        purpose: MachOImportPurpose = .primary,
        options: MachOImportOptions = .default
    ) throws -> MachOImportResult {
        if url.pathExtension.lowercased() == "ipa" || IPAArchive.isZIP(at: url) {
            // Apply policy before allocating or extracting an untrusted archive.
            try validateAdditionalBinaryPolicy(for: (url, true), originalURL: url, purpose: purpose, options: options)
            let extraction = try IPAArchive.extract(at: url)
            return try importIPA(extraction, originalURL: url, purpose: purpose, options: options)
        }
        let resolved = try resolveExecutable(at: url)
        try validateAdditionalBinaryPolicy(for: resolved, originalURL: url, purpose: purpose, options: options)
        guard let bytes = try? Data(contentsOf: resolved.executableURL, options: [.mappedIfSafe]) else {
            throw MachOImportError.unreadableExecutable(resolved.executableURL)
        }

        return try importBytes(bytes, originalURL: url, resolved: resolved, purpose: purpose, options: options)
    }

    /// Rehydrate an already captured image without reopening a path or creating a scratch file.
    /// `sourceURL` supplies descriptive metadata only; package bytes are the sole input authority.
    func importBinary(
        bytes: Data,
        sourceURL: URL,
        options: MachOImportOptions = .default
    ) throws -> MachOImportResult {
        if IPAArchive.isZIP(bytes) {
            return try importIPA(IPAArchive.extract(bytes), originalURL: sourceURL, purpose: .primary, options: options)
        }
        return try importBytes(bytes, originalURL: sourceURL, resolved: (sourceURL, false),
                               purpose: .primary, options: options)
    }

    private func importIPA(_ extraction: (root: URL, app: URL), originalURL: URL,
                           purpose: MachOImportPurpose, options: MachOImportOptions) throws -> MachOImportResult {
        do {
            let resolved = try resolveExecutable(at: extraction.app)
            let bytes = try Data(contentsOf: resolved.executableURL)
            // The bounded process-lifetime owner preserves paths for downstream consumers
            // and removes its read-only extractions at normal process exit.
            return try importBytes(bytes, originalURL: originalURL, resolved: resolved, purpose: purpose, options: options)
        } catch {
            IPAArchive.removeExtraction(at: extraction.root)
            throw error
        }
    }

    private func importBytes(
        _ bytes: Data,
        originalURL url: URL,
        resolved: (executableURL: URL, isBundle: Bool),
        purpose: MachOImportPurpose,
        options: MachOImportOptions
    ) throws -> MachOImportResult {
        let machO = try parser.parse(bytes, options: options.parseOptions)
        guard machO.header.cpuType == MachOConstants.cpuTypeARM64
            || machO.header.cpuType == MachOConstants.cpuTypeX86_64 else {
            throw MachOImportError.unsupportedArchitecture(machO.architectureName)
        }

        let diagnostics = makeDiagnostics(
            machO: machO,
            purpose: purpose,
            options: options,
            resolved: resolved
        )

        return MachOImportResult(
            originalURL: url,
            executableURL: resolved.executableURL,
            isBundle: resolved.isBundle,
            bytes: bytes,
            machO: machO,
            diagnostics: diagnostics
        )
    }

    func resolveExecutable(at url: URL) throws -> (executableURL: URL, isBundle: Bool) {
        if url.pathExtension.caseInsensitiveCompare("app") != .orderedSame {
            return (url, false)
        }

        // iOS bundles have Info.plist and the executable directly in the app root.
        let flatInfo = url.appendingPathComponent("Info.plist")
        if fileManager.fileExists(atPath: flatInfo.path) {
            guard let data = try? Data(contentsOf: flatInfo),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let name = plist["CFBundleExecutable"] as? String,
                  Self.isExecutableComponent(name) else {
                throw MachOImportError.executableNotFound(url)
            }
            let executable = url.appendingPathComponent(name)
            let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  fileManager.isReadableFile(atPath: executable.path) else {
                throw MachOImportError.executableNotFound(url)
            }
            return (executable, true)
        }
        let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)

        if
            let infoData = try? Data(contentsOf: infoURL),
            let plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
            let executableName = plist["CFBundleExecutable"] as? String,
            Self.isExecutableComponent(executableName)
        {
            let executableURL = macOSURL.appendingPathComponent(executableName)
            if fileManager.isReadableFile(atPath: executableURL.path) {
                return (executableURL, true)
            }
        }

        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: macOSURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw MachOImportError.executableNotFound(url)
        }

        if let executableURL = contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first(where: { candidate in
            fileManager.isExecutableFile(atPath: candidate.path) && fileManager.isReadableFile(atPath: candidate.path)
        }) {
            return (executableURL, true)
        }

        throw MachOImportError.executableNotFound(url)
    }

    private static func isExecutableComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private func validateAdditionalBinaryPolicy(
        for resolved: (executableURL: URL, isBundle: Bool),
        originalURL: URL,
        purpose: MachOImportPurpose,
        options: MachOImportOptions
    ) throws {
        guard purpose == .additional else { return }

        switch options.additionalBinaryPolicy {
        case .reject:
            throw MachOImportError.additionalBinaryRejected(originalURL)
        case .allowMachOFiles:
            if resolved.isBundle {
                throw MachOImportError.additionalBundleRejected(originalURL)
            }
        case .allowMachOFilesAndBundles:
            break
        }
    }

    private func makeDiagnostics(
        machO: MachOFile,
        purpose: MachOImportPurpose,
        options: MachOImportOptions,
        resolved: (executableURL: URL, isBundle: Bool)
    ) -> [MachOImportDiagnostic] {
        var diagnostics: [MachOImportDiagnostic] = []

        if purpose == .additional {
            diagnostics.append(.info(
                code: "loader.additionalBinary.accepted",
                message: resolved.isBundle
                    ? "Additional app bundle executable was accepted by import policy."
                    : "Additional Mach-O file was accepted by import policy."
            ))
        }

        if let universalBinary = machO.universalBinary, let selectedSlice = universalBinary.selectedSlice {
            diagnostics.append(.info(
                code: "loader.universalBinary.sliceSelected",
                message: "Selected \(selectedSlice.architectureName) slice \(selectedSlice.index + 1) of \(universalBinary.slices.count)."
            ))
        }

        if !machO.relocations.isEmpty {
            let sectionCount = Set(machO.relocations.map(\.sourceSection)).count
            diagnostics.append(.info(
                code: "analysis.relocations.recovered",
                message: "Recovered \(machO.relocations.count) section relocation records across \(sectionCount) sections."
            ))
        }

        if let dyldChainedFixups = machO.dyldChainedFixups {
            diagnostics.append(.info(
                code: "analysis.dyldChainedFixups.recovered",
                message: "Recovered LC_DYLD_CHAINED_FIXUPS header metadata with \(dyldChainedFixups.importsCount) imports."
            ))
            if !dyldChainedFixups.fixups.isEmpty {
                diagnostics.append(.info(
                    code: "analysis.dyldChainedFixups.walked",
                    message: "Walked dyld chained-fixups: resolved \(dyldChainedFixups.bindCount) bind and \(dyldChainedFixups.rebaseCount) rebase targets."
                ))
            }
        }

        if !machO.exceptionMetadata.isEmpty {
            diagnostics.append(.info(
                code: "analysis.exceptionMetadata.detected",
                message: exceptionMetadataSummary(for: machO.exceptionMetadata)
            ))
        }

        appendLinkedDylibDiagnostics(
            to: &diagnostics,
            machO: machO,
            resolved: resolved
        )

        let parseOptions = options.parseOptions
        if !parseOptions.recoverStringLiterals {
            diagnostics.append(.info(
                code: "analysis.strings.disabled",
                message: "String literal recovery was disabled for this import."
            ))
        }
        if !parseOptions.recoverObjectiveCMetadata {
            diagnostics.append(.info(
                code: "analysis.objectiveC.disabled",
                message: "Objective-C metadata recovery was disabled for this import."
            ))
        }
        if !parseOptions.recoverSwiftMetadata {
            diagnostics.append(.info(
                code: "analysis.swift.disabled",
                message: "Swift metadata section recovery was disabled for this import."
            ))
        }

        let hasCodeSignatureCommand = machO.loadCommands.contains {
            $0.command == MachOConstants.loadCommandCodeSignature
        }
        if hasCodeSignatureCommand {
            if !parseOptions.parseCodeSignature {
                diagnostics.append(.info(
                    code: "analysis.codeSignature.disabled",
                    message: "Code signature payload parsing was disabled for this import."
                ))
            } else if machO.codeSignature?.superBlob == nil {
                diagnostics.append(.warning(
                    code: "analysis.codeSignature.unrecognized",
                    message: "A code signature load command was present, but no supported SuperBlob metadata was recovered."
                ))
            } else if let superBlob = machO.codeSignature?.superBlob {
                let codeDirectoryCount = superBlob.codeDirectories.count
                let entitlementCount = superBlob.entitlementSummaries.count
                if codeDirectoryCount > 0 || entitlementCount > 0 {
                    diagnostics.append(.info(
                        code: "analysis.codeSignature.payloadRecovered",
                        message: codeSignaturePayloadSummary(for: superBlob)
                    ))
                }
            }
        }

        return diagnostics
    }

    private func appendLinkedDylibDiagnostics(
        to diagnostics: inout [MachOImportDiagnostic],
        machO: MachOFile,
        resolved: (executableURL: URL, isBundle: Bool)
    ) {
        guard !machO.dylibs.isEmpty else { return }

        diagnostics.append(.info(
            code: "analysis.linkedDylibs.recovered",
            message: "Recovered \(machO.dylibs.count) linked dylib load command\(machO.dylibs.count == 1 ? "" : "s") (\(linkedDylibSummary(for: machO.dylibs)))."
        ))

        let rpathDylibs = machO.dylibs.filter { $0.pathKind == .rpathRelative }
        guard !rpathDylibs.isEmpty else { return }

        guard !machO.rpaths.isEmpty else {
            diagnostics.append(.warning(
                code: "analysis.linkedDylibs.rpathMissing",
                message: "\(rpathDylibs.count) linked dylib\(rpathDylibs.count == 1 ? "" : "s") use @rpath, but the binary declares no LC_RPATH search paths."
            ))
            return
        }

        let searchPaths = resolvedRPathSearchPaths(
            rpaths: machO.rpaths,
            executableURL: resolved.executableURL
        )
        guard !searchPaths.isEmpty else {
            diagnostics.append(.warning(
                code: "analysis.linkedDylibs.rpathSearchPathsUnresolved",
                message: "\(rpathDylibs.count) linked dylib\(rpathDylibs.count == 1 ? "" : "s") use @rpath, but none of the LC_RPATH entries could be resolved from the executable location."
            ))
            return
        }

        var resolvedCount = 0
        var unresolvedNames: [String] = []

        for dylib in rpathDylibs {
            guard let suffix = dylib.rpathSuffix, !suffix.isEmpty else {
                unresolvedNames.append(dylib.name)
                continue
            }

            let match = searchPaths.first { searchPath in
                let candidate = searchPath.url.appendingPathComponent(suffix).standardizedFileURL
                return fileManager.isReadableFile(atPath: candidate.path)
            }

            if match == nil {
                unresolvedNames.append(dylib.name)
            } else {
                resolvedCount += 1
            }
        }

        if resolvedCount > 0 {
            diagnostics.append(.info(
                code: "analysis.linkedDylibs.rpathResolved",
                message: "Resolved \(resolvedCount) @rpath linked dylib\(resolvedCount == 1 ? "" : "s") against \(searchPaths.count) LC_RPATH search path\(searchPaths.count == 1 ? "" : "s")."
            ))
        }

        if !unresolvedNames.isEmpty {
            diagnostics.append(.warning(
                code: "analysis.linkedDylibs.rpathUnresolved",
                message: "Could not resolve \(unresolvedNames.count) @rpath linked dylib\(unresolvedNames.count == 1 ? "" : "s"): \(displayList(unresolvedNames))."
            ))
        }
    }

    private func linkedDylibSummary(for dylibs: [MachODylib]) -> String {
        let kinds: [MachORuntimePathKind] = [
            .systemAbsolute,
            .absolute,
            .rpathRelative,
            .loaderPathRelative,
            .executablePathRelative,
            .installNameRelative,
            .relative,
            .empty
        ]
        let counts = Dictionary(grouping: dylibs, by: \.pathKind).mapValues(\.count)
        return kinds.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(count) \(kind.displayName)"
        }.joined(separator: ", ")
    }

    private func resolvedRPathSearchPaths(
        rpaths: [MachORPath],
        executableURL: URL
    ) -> [(original: String, url: URL)] {
        rpaths.compactMap { rpath in
            guard let url = resolvedRuntimeURL(for: rpath.path, executableURL: executableURL) else {
                return nil
            }
            return (rpath.path, url)
        }
    }

    private func resolvedRuntimeURL(for path: String, executableURL: URL) -> URL? {
        let executableDirectory = executableURL.deletingLastPathComponent()
        switch MachORuntimePathKind(path: path) {
        case .systemAbsolute, .absolute:
            return URL(fileURLWithPath: path).standardizedFileURL
        case .executablePathRelative:
            return urlByReplacingDyldToken(
                "@executable_path",
                in: path,
                with: executableDirectory
            )
        case .loaderPathRelative:
            return urlByReplacingDyldToken(
                "@loader_path",
                in: path,
                with: executableDirectory
            )
        case .relative:
            return executableDirectory.appendingPathComponent(path).standardizedFileURL
        case .rpathRelative, .installNameRelative, .empty:
            return nil
        }
    }

    private func urlByReplacingDyldToken(
        _ token: String,
        in path: String,
        with baseURL: URL
    ) -> URL? {
        guard path == token || path.hasPrefix("\(token)/") else { return nil }
        var suffix = String(path.dropFirst(token.count))
        if suffix.hasPrefix("/") {
            suffix.removeFirst()
        }
        if suffix.isEmpty {
            return baseURL.standardizedFileURL
        }
        return baseURL.appendingPathComponent(suffix).standardizedFileURL
    }

    private func displayList(_ values: [String], limit: Int = 3) -> String {
        let listed = values.prefix(limit).joined(separator: ", ")
        let remaining = values.count - limit
        if remaining > 0 {
            return "\(listed), and \(remaining) more"
        }
        return listed
    }

    private func codeSignaturePayloadSummary(for superBlob: MachOCodeSignatureSuperBlob) -> String {
        var parts: [String] = []
        let codeDirectoryCount = superBlob.codeDirectories.count
        if codeDirectoryCount > 0 {
            parts.append("\(codeDirectoryCount) CodeDirectory blob\(codeDirectoryCount == 1 ? "" : "s")")
        }

        let entitlements = superBlob.entitlementSummaries
        if !entitlements.isEmpty {
            let keyCount = entitlements.compactMap(\.keyCount).reduce(0, +)
            let formats = Array(Set(entitlements.map(\.format.displayName))).sorted().joined(separator: "/")
            let keySummary = keyCount > 0 ? " with \(keyCount) key\(keyCount == 1 ? "" : "s")" : ""
            parts.append("\(entitlements.count) \(formats) entitlement blob\(entitlements.count == 1 ? "" : "s")\(keySummary)")
        }

        return "Recovered code signature payload metadata: \(parts.joined(separator: ", "))."
    }

    private func exceptionMetadataSummary(for metadata: MachOExceptionMetadata) -> String {
        var parts: [String] = []

        if !metadata.sections.isEmpty {
            let sectionSummaries = metadata.sections.map { section in
                "\(section.kind.displayName) \(section.qualifiedName) \(hex(section.address))-\(hex(section.endAddress))"
            }
            parts.append("\(metadata.sections.count) section\(metadata.sections.count == 1 ? "" : "s"): \(displayList(sectionSummaries, limit: 4))")
        }

        if let unwindInfo = metadata.sections.compactMap(\.unwindInfoHeader).first {
            parts.append(
                "__unwind_info header v\(unwindInfo.version) with \(unwindInfo.indexCount) index entr\(unwindInfo.indexCount == 1 ? "y" : "ies"), \(unwindInfo.commonEncodingsArrayCount) common encoding\(unwindInfo.commonEncodingsArrayCount == 1 ? "" : "s"), \(unwindInfo.personalityArrayCount) personalit\(unwindInfo.personalityArrayCount == 1 ? "y" : "ies")"
            )
        }

        if metadata.compactUnwindEntryCount > 0 {
            parts.append("\(metadata.compactUnwindEntryCount) compact unwind row\(metadata.compactUnwindEntryCount == 1 ? "" : "s")")
        }

        if !metadata.relatedLoadCommands.isEmpty {
            let commandSummaries = metadata.relatedLoadCommands.map { command in
                if let dataOffset = command.dataOffset, let endOffset = command.endOffset {
                    return "\(command.name) \(hex(UInt64(dataOffset)))-\(hex(endOffset))"
                }
                return command.name
            }
            parts.append("related load command\(metadata.relatedLoadCommands.count == 1 ? "" : "s"): \(displayList(commandSummaries))")
        }

        return "Detected exception/unwind metadata: \(parts.joined(separator: "; "))."
    }

    private func hex(_ value: UInt64) -> String {
        "0x\(String(value, radix: 16))"
    }
}

private extension MachOImportDiagnostic {
    static func info(code: String, message: String) -> MachOImportDiagnostic {
        MachOImportDiagnostic(severity: .info, code: code, message: message)
    }

    static func warning(code: String, message: String) -> MachOImportDiagnostic {
        MachOImportDiagnostic(severity: .warning, code: code, message: message)
    }
}

/// Deliberately bounded ZIP subset for IPA import. ZIP64, split/encrypted archives,
/// links, special files and ambiguous paths are refused before any output is created.
enum IPAArchive {
    struct Limits {
        var archiveBytes = 512 * 1024 * 1024
        var entryBytes = 256 * 1024 * 1024
        var expandedBytes = 1024 * 1024 * 1024
        var entries = 20_000
        var ratio = 200
    }
    struct Invalid: LocalizedError {
        let reason: String
        var errorDescription: String? { "Cannot import IPA: \(reason)." }
    }
    private struct Entry {
        let path: String
        let directory: Bool
        let method: UInt16
        let crc: UInt32
        let size: Int
        let payload: Range<Int>
    }
    private static let localSignature = Data([0x50, 0x4b, 3, 4])
    static func isZIP(_ data: Data) -> Bool {
        if data.prefix(4) == localSignature { return true }
        return hasPrefixedZIPDirectory(size: data.count) { offset, count in
            guard offset >= 0, count <= data.count, offset <= data.count - count else { return nil }
            return data.subdata(in: offset..<offset + count)
        }
    }
    static func isZIP(at url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        if (try? file.read(upToCount: 4)) == localSignature { return true }
        guard let length = try? file.seekToEnd(), length <= UInt64(Int.max) else { return false }
        return hasPrefixedZIPDirectory(size: Int(length)) { offset, count in
            guard offset >= 0, count <= Int(length), offset <= Int(length) - count,
                  (try? file.seek(toOffset: UInt64(offset))) != nil else { return nil }
            return try? file.read(upToCount: count)
        }
    }
    /// A prefix is admitted only when the ZIP's absolute directory and local-header
    /// offsets point to records inside this file. Extraction still checks every member.
    private static func hasPrefixedZIPDirectory(
        size: Int, read: (Int, Int) -> Data?
    ) -> Bool {
        guard size >= 22 else { return false }
        let tailSize = min(size, 65_557)
        guard let tail = read(size - tailSize, tailSize), tail.count == tailSize else { return false }
        func u16(_ bytes: Data, _ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ bytes: Data, _ at: Int) -> Int {
            u16(bytes, at) | u16(bytes, at + 2) << 16
        }
        for position in stride(from: tailSize - 22, through: 0, by: -1) {
            guard u32(tail, position) == 0x06054b50,
                  position + 22 + u16(tail, position + 20) == tailSize,
                  u16(tail, position + 4) == 0, u16(tail, position + 6) == 0 else { continue }
            let count = u16(tail, position + 10)
            let centralStart = u32(tail, position + 16)
            let centralSize = u32(tail, position + 12)
            let end = size - tailSize + position
            guard count > 0, count == u16(tail, position + 8),
                  centralStart <= end, centralSize == end - centralStart,
                  centralStart <= end - 46,
                  let central = read(centralStart, 46), central.count == 46,
                  u32(central, 0) == 0x02014b50 else { continue }
            let local = u32(central, 42)
            guard local > 0, local <= centralStart - 30,
                  read(local, 4) == localSignature else { continue }
            return true
        }
        return false
    }
    static func extract(at url: URL, limits: Limits = Limits()) throws -> (root: URL, app: URL) {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limits.archiveBytes + 1) ?? Data()
        return try extract(data, limits: limits)
    }
    static func extract(_ data: Data, limits: Limits = Limits()) throws -> (root: URL, app: URL) {
        func reject(_ reason: String) -> Invalid { Invalid(reason: reason) }
        guard data.count <= limits.archiveBytes, data.count >= 22 else { throw reject("archive size limit or truncated ZIP") }
        func u16(_ offset: Int) throws -> UInt16 {
            guard offset >= 0, offset <= data.count - 2 else { throw reject("truncated header") }
            return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> UInt32 {
            UInt32(try u16(offset)) | UInt32(try u16(offset + 2)) << 16
        }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(offset) == 0x06054b50,
               offset + 22 + Int(try u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw reject("missing or split ZIP directory") }
        let count = Int(try u16(end + 10))
        let directorySize = Int(try u32(end + 12))
        let directoryStart = Int(try u32(end + 16))
        guard count > 0, count < 65_535, count <= limits.entries,
              Int(try u16(end + 8)) == count, directoryStart <= end,
              directorySize == end - directoryStart else { throw reject("invalid directory or entry count limit") }
        var cursor = directoryStart
        var total = 0
        var entries: [Entry] = []
        var seen: Set<String> = []
        var files: Set<String> = []
        var directories: Set<String> = []
        var apps: Set<String> = []
        var spans: [Range<Int>] = []
        for _ in 0..<count {
            guard cursor <= end - 46, try u32(cursor) == 0x02014b50 else { throw reject("invalid central header") }
            let flags = try u16(cursor + 8)
            let method = try u16(cursor + 10)
            let crc = try u32(cursor + 16)
            let compressed = Int(try u32(cursor + 20))
            let size = Int(try u32(cursor + 24))
            let nameLength = Int(try u16(cursor + 28))
            let extraLength = Int(try u16(cursor + 30))
            let commentLength = Int(try u16(cursor + 32))
            let attributes = try u32(cursor + 38)
            let local = Int(try u32(cursor + 42))
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard next <= end, nameLength > 0, nameLength <= 4096,
                  flags & ~UInt16(0x080e) == 0, method == 0 || method == 8,
                  try u16(cursor + 34) == 0, compressed <= limits.archiveBytes,
                  size <= limits.entryBytes, size <= limits.expandedBytes - total,
                  size <= max(compressed, 1) * limits.ratio,
                  let name = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8)
            else { throw reject("unsupported entry or expansion limit") }
            let directory = name.hasSuffix("/")
            let path = directory ? String(name.dropLast()) : name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.count <= 64,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":") && !$0.contains("\0") }),
                  !path.unicodeScalars.contains(where: { $0.value < 32 }) else { throw reject("unsafe entry path") }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else { throw reject("duplicate entry path") }
            let kind = (attributes >> 16) & 0xf000
            guard kind == 0 || kind == (directory ? 0x4000 : 0x8000),
                  attributes & 0x10 == 0 || directory,
                  !directory || size == 0 else { throw reject("links or special files are not allowed") }
            if directory { directories.insert(key) } else { files.insert(key) }
            for length in 1..<parts.count {
                directories.insert(parts.prefix(length).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased())
            }
            if parts.count >= 2, parts[0] == "Payload", parts[1].hasSuffix(".app") {
                guard parts.count > 2 || directory else { throw reject("app is not a directory") }
                apps.insert(String(parts[1]))
            }
            guard local <= directoryStart - 30, try u32(local) == 0x04034b50,
                  try u16(local + 6) == flags, try u16(local + 8) == method,
                  Int(try u16(local + 26)) == nameLength else { throw reject("invalid local header") }
            let payloadStart = local + 30 + nameLength + Int(try u16(local + 28))
            guard payloadStart <= directoryStart, compressed <= directoryStart - payloadStart,
                  data.subdata(in: local + 30..<local + 30 + nameLength) == data.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            else { throw reject("local path or payload mismatch") }
            if flags & 8 == 0 {
                guard try u32(local + 14) == crc, Int(try u32(local + 18)) == compressed,
                      Int(try u32(local + 22)) == size else { throw reject("local size mismatch") }
            }
            spans.append(local..<payloadStart + compressed)
            entries.append(Entry(path: path, directory: directory, method: method, crc: crc, size: size,
                                 payload: payloadStart..<payloadStart + compressed))
            total += size
            cursor = next
        }
        guard cursor == end, apps.count == 1, let app = apps.first, files.isDisjoint(with: directories) else {
            throw reject("expected exactly one Payload/*.app and unambiguous paths")
        }
        let ordered = spans.sorted { $0.lowerBound < $1.lowerBound }
        for index in ordered.indices.dropFirst() where ordered[index].lowerBound < ordered[index - 1].upperBound {
            throw reject("overlapping archive entries")
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("MacScope-IPA-\(UUID().uuidString)", isDirectory: true)
        try lifetime.reserve(root, bytes: total)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for entry in entries {
                let destination = root.appendingPathComponent(entry.path, isDirectory: entry.directory)
                if entry.directory {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    continue
                }
                let compressed = data.subdata(in: entry.payload)
                let bytes = try expand(compressed, method: entry.method, size: entry.size)
                let checksum = bytes.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)) }
                guard UInt32(checksum) == entry.crc else { throw reject("CRC mismatch") }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try bytes.write(to: destination, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
            }
            let children = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects as? [URL] ?? []
            for directory in children.sorted(by: { $0.path.count > $1.path.count }) {
                if try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
                }
            }
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            return (root, root.appendingPathComponent("Payload/\(app)", isDirectory: true))
        } catch {
            removeExtraction(at: root)
            throw error
        }
    }
    static func removeExtraction(at root: URL) {
        defer { lifetime.release(root) }
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in enumerator {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
            }
        }
        try? fm.removeItem(at: root)
    }
    // LoadedBinary exposes a resolved executable path without an ownership token.
    // Keep those paths valid for the worker/app lifetime, with aggregate admission
    // limits so repeated opens cannot consume unbounded disk space.
    private static let lifetime = Lifetime()
    private final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var roots: [URL: Int] = [:]
        init() { atexit { IPAArchive.lifetime.cleanUp() } }
        func reserve(_ root: URL, bytes: Int) throws {
            lock.lock()
            defer { lock.unlock() }
            guard roots.count < 8, bytes <= 1024 * 1024 * 1024 - roots.values.reduce(0, +) else {
                throw Invalid(reason: "temporary import budget exhausted; reopen the analysis session")
            }
            roots[root] = bytes
        }
        func release(_ root: URL) {
            lock.lock()
            defer { lock.unlock() }
            roots.removeValue(forKey: root)
        }
        func cleanUp() {
            lock.lock()
            let paths = Array(roots.keys)
            lock.unlock()
            for path in paths { IPAArchive.removeExtraction(at: path) }
        }
    }

    private static func expand(_ compressed: Data, method: UInt16, size: Int) throws -> Data {
        if method == 0 {
            guard compressed.count == size else { throw Invalid(reason: "stored entry size mismatch") }
            return compressed
        }
        // A one-byte sentinel detects expansion beyond the declared size, including
        // streams claiming zero output. No unbounded inflater allocation is permitted.
        var output = Data(count: size + 1)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Invalid(reason: "could not initialize decompressor")
        }
        defer { inflateEnd(&stream) }
        let status = compressed.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size + 1)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.total_in == compressed.count else {
            throw Invalid(reason: "invalid or oversized deflate stream")
        }
        output.removeLast()
        return output
    }
}
