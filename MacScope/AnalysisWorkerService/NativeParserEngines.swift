#if TESTING_PARSER_ENGINES
@testable import MacScope
#endif
import Foundation
import MacScopeParserEngines
import Darwin

/// The analysis worker's independent parser engines (RX-03): vendored LIEF 1.0.0, pe-parse
/// 2.1.1 and go-macho 1.1.283, built once into cached static archives and linked into this
/// XPC service only. Each engine parses an in-memory copy of the selected slice; nothing is
/// read from a path, mapped or executed. Untrusted engine output is decoded into bounded
/// MacScope facts; engine diagnostic text is dropped.
struct NativeParserEngines: ParserCrossChecking {
    static let maximumDocumentBytes = 64 * 1_024 * 1_024
    static let maximumSections = 65_536
    static let maximumSegments = 4_096
    /// One verdict cache per worker process, shared by every connection's analysis engine, so a
    /// slice digest is re-parsed by the engines at most once per process (decision D4).
    static let processVerdicts = ParserCrossCheckVerdictCache()

    func reports(forSliceBytes bytes: Data, format: ParserCrossCheckFormat) -> [ParserEngineReport] {
        switch format {
        case .machO:
            return [
                report(.lief, macho: bytes, call: macscope_lief_macho_facts),
                report(.goMacho, macho: bytes, call: macscope_gomacho_macho_facts),
            ]
        case .pe:
            return [
                report(.lief, pe: bytes, call: macscope_lief_pe_facts),
                report(.peParse, pe: bytes, call: macscope_peparse_pe_facts),
            ]
        }
    }

    /// Pinned engine identity compiled into the bridge.
    static var identity: String {
        String(cString: macscope_parser_engines_identity())
    }

    // MARK: - Engine calls

    typealias EngineCall = (UnsafePointer<UInt8>?, Int) -> UnsafeMutablePointer<CChar>?

    static func document(for bytes: Data, call: EngineCall) -> Data? {
        let pointer: UnsafeMutablePointer<CChar>? = bytes.withUnsafeBytes { raw in
            call(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        guard let pointer else { return nil }
        defer { macscope_parser_engines_free(pointer) }
        let length = strnlen(pointer, maximumDocumentBytes + 1)
        guard length <= maximumDocumentBytes else { return nil }
        return Data(bytes: pointer, count: length)
    }

    private func report(_ engine: ParserEngineID, macho bytes: Data, call: EngineCall) -> ParserEngineReport {
        guard let document = Self.document(for: bytes, call: call),
              let decoded = try? JSONDecoder().decode(RawMachODocument.self, from: document),
              decoded.status == "parsed",
              let slices = decoded.slices, slices.count == 1,
              let facts = Self.facts(machO: slices[0]) else {
            return ParserEngineReport(engine: engine, observation: .rejected)
        }
        return ParserEngineReport(engine: engine, observation: .parsed(facts))
    }

    private func report(_ engine: ParserEngineID, pe bytes: Data, call: EngineCall) -> ParserEngineReport {
        guard let document = Self.document(for: bytes, call: call),
              let decoded = try? JSONDecoder().decode(RawPEDocument.self, from: document),
              decoded.status == "parsed",
              let facts = Self.facts(pe: decoded) else {
            return ParserEngineReport(engine: engine, observation: .rejected)
        }
        return ParserEngineReport(engine: engine, observation: .parsed(facts))
    }

    // MARK: - Raw engine schema (shared by the LIEF, pe-parse and go-macho adapters)

    struct RawMachODocument: Decodable {
        var status: String
        var slices: [RawMachOSlice]?
    }

    struct RawMachOSlice: Decodable {
        struct Segment: Decodable {
            var name: String
            // Missing fields mean unavailable evidence, not zero. Both pinned adapters
            // emit these fields; optional decoding also preserves reduced/legacy documents.
            var vmaddr: UInt64?
            var vmsize: UInt64?
            var fileoff: UInt64?
            var filesize: UInt64?
            var sections: [Section]
        }

        struct Section: Decodable {
            var name: String
            var segment: String
            var addr: UInt64
            var size: UInt64
            var offset: UInt64?
        }

        var cputype: UInt32
        var cpusubtype: UInt32?
        var fat_offset: UInt64?
        var segments: [Segment]
        var uuid: String?
    }

    struct RawPEDocument: Decodable {
        struct Section: Decodable {
            var name: String
            var va: UInt64
            var virtual_size: UInt64
            var raw_size: UInt64
        }

        struct Import: Decodable {
            var module: String
            var function: String
        }

        var status: String
        var image_base: UInt64?
        var entry_point_va: UInt64?
        var machine: UInt32?
        var sections: [Section]?
        var imports: [Import]?
    }

    static func facts(machO slice: RawMachOSlice) -> ParserEngineFacts? {
        // The caller supplies one exact thin slice. An explicitly nonzero container
        // offset contradicts that contract; missing offset evidence stays unknown.
        guard slice.segments.count <= maximumSegments,
              slice.fat_offset == nil || slice.fat_offset == 0 else { return nil }
        let segments = slice.segments.map { segment in
            ParserEngineFacts.Segment(
                name: bounded(segment.name),
                address: segment.vmaddr,
                size: segment.vmsize,
                fileOffset: segment.fileoff,
                fileSize: segment.filesize
            )
        }
        var sections: [ParserEngineFacts.Section] = []
        for segment in slice.segments {
            for section in segment.sections {
                guard sections.count < maximumSections else { return nil }
                sections.append(.init(
                    name: "\(bounded(section.segment)),\(bounded(section.name))",
                    address: section.addr,
                    size: section.size,
                    fileOffset: section.offset
                ))
            }
        }
        return ParserEngineFacts(
            cpuType: Int32(bitPattern: slice.cputype),
            sections: sections,
            uuid: slice.uuid.flatMap(uuid(fromHex:)),
            entryPointAddress: nil,
            importCount: nil,
            cpuSubtype: slice.cpusubtype.map { Int32(bitPattern: $0) },
            segments: segments
        )
    }

    static func facts(pe document: RawPEDocument) -> ParserEngineFacts? {
        guard let rawSections = document.sections, rawSections.count <= maximumSections else { return nil }
        let sections = rawSections.map { section in
            ParserEngineFacts.Section(
                name: bounded(section.name),
                address: section.va,
                size: section.virtual_size != 0 ? section.virtual_size : section.raw_size
            )
        }
        return ParserEngineFacts(
            cpuType: document.machine.map(peCPUType),
            sections: sections,
            uuid: nil,
            entryPointAddress: document.entry_point_va,
            importCount: document.imports?.count
        )
    }

    /// PE machine values in MacScope's cpuType vocabulary, mirroring PEBinaryLoader's mapping
    /// (AMD64 and ARM64 only; every other machine is 0 there as well).
    static func peCPUType(_ machine: UInt32) -> Int32 {
        switch machine {
        case 0x8664: MachOConstants.cpuTypeX86_64
        case 0xAA64: MachOConstants.cpuTypeARM64
        default: 0
        }
    }

    static func bounded(_ text: String) -> String {
        text.utf8.count <= 256 ? text : String(decoding: text.utf8.prefix(256), as: UTF8.self)
    }

    static func uuid(fromHex text: String) -> UUID? {
        guard text.count == 32, text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return NSUUID(uuidBytes: bytes) as UUID
    }
}


// K2: compiler-recorded Go names. This adapter exists only in the isolated worker;
// LoadedBinary remains the byte/address authority and ordinary non-Go images skip it.
extension NativeParserEngines {
    struct GoFunctionDocument: Decodable, Sendable {
        struct Function: Decodable, Sendable {
            var name: String
            var start: UInt64
            var end: UInt64
            var sourceFile: String?
            var line: Int?
        }
        var status: String
        var reason: String?
        var textBaseProvenance: String?
        var goVersion: String?
        var functions: [Function]?
    }

    static func enrichGoFunctions(_ loaded: LoadedBinary) -> LoadedBinary {
        guard loaded.sections.contains(where: { $0.name == "__gopclntab" || $0.name.hasSuffix(",__gopclntab") }),
              let text = loaded.executableTextSection,
              text.address <= UInt64.max - text.size,
              loaded.sliceOffset <= UInt64(loaded.bytes.count) else { return loaded }
        let size = loaded.sliceSize ?? (UInt64(loaded.bytes.count) - loaded.sliceOffset)
        guard size > 0, size <= 64 * 1_024 * 1_024,
              size <= UInt64(loaded.bytes.count) - loaded.sliceOffset else { return loaded }
        let start = Int(loaded.sliceOffset)
        let bytes = loaded.bytes.subdata(in: start..<(start + Int(size)))
        #if !TESTING_PARSER_ENGINES
        // Vendor calls are synchronous. Retire this isolated worker if they do not
        // return; XPC invalidation delivers the existing worker-unavailable failure.
        let watchdog = GoParserWatchdog()
        defer { watchdog.disarm() }
        #endif
        guard let raw = document(for: bytes, call: macscope_gomacho_go_functions),
              raw.count <= 16 * 1_024 * 1_024,
              let parsed = try? JSONDecoder().decode(GoFunctionDocument.self, from: raw) else { return loaded }
        return applyingGoFunctions(parsed, to: loaded)
    }

    // Go's linker puts data markers in pclntab alongside code. Their byte-sized
    // intervals are valid metadata, but must never seed ARM64 instruction decoding.
    // See cmd/link/internal/ld/fips140.go and data.go in the linked Go toolchain.
    private static func isGoLinkerData(_ name: String) -> Bool {
        name == "go:buildid" || name == "go:textfipsstart" || name == "go:textfipsend"
    }

    /// All-or-nothing admission. Real symbol names always win; future DWARF/user
    /// overrides retain their existing precedence. A pclntab name is not a linkage symbol.
    static func applyingGoFunctions(_ parsed: GoFunctionDocument, to loaded: LoadedBinary) -> LoadedBinary {
        guard parsed.status == "parsed", let functions = parsed.functions,
              !functions.isEmpty, functions.count <= 50_000,
              let text = loaded.executableTextSection,
              text.address <= UInt64.max - text.size else { return loaded }
        let textEnd = text.address + text.size
        var previousEnd = text.address
        var stringBytes = 0
        for row in functions {
            guard row.start >= previousEnd, row.start >= text.address,
                  row.end > row.start, row.end <= textEnd,
                  (isGoLinkerData(row.name) || (row.start % 4 == 0 && row.end % 4 == 0)),
                  !row.name.isEmpty, row.name.utf8.count <= 4096,
                  (row.sourceFile?.utf8.count ?? 0) <= 4096,
                  (row.line ?? 0) >= 0 else { return loaded }
            stringBytes += row.name.utf8.count + (row.sourceFile?.utf8.count ?? 0)
            guard stringBytes <= 12 * 1_024 * 1_024 else { return loaded }
            previousEnd = row.end
        }
        var result = loaded
        var namedAddresses = Set(loaded.symbols.compactMap(\.address))
        var starts = Set(loaded.functionStarts)
        for row in functions where !isGoLinkerData(row.name) {
            starts.insert(row.start)
            if namedAddresses.insert(row.start).inserted {
                result.symbols.append(SymbolSummary(id: UUID(), name: row.name, address: row.start,
                                                    kind: "Go pclntab", libraryName: nil, rawLinkageName: nil))
            }
        }
        result.functionStarts = starts.sorted()
        return result
    }
}

#if !TESTING_PARSER_ENGINES
/// Process-local retirement is necessary: cancelling a dispatch work item cannot
/// interrupt a foreign parser. Never instantiate this in the app or test host.
private final class GoParserWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    init() {
        timer.schedule(deadline: .now() + .seconds(3))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.armed { Darwin._exit(124) }
            self.lock.unlock()
        }
        timer.resume()
    }

    func disarm() {
        lock.lock()
        armed = false
        lock.unlock()
        timer.cancel()
    }
}
#endif
