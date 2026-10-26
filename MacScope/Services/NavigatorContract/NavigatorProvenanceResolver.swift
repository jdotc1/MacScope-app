import Foundation

// MARK: - Ref grammar

/// The provenance ref grammar (`docs/contracts/navigator-engine/v1/proof-certificate.md` §3):
///
/// | kind                 | ref                                                                  |
/// |----------------------|----------------------------------------------------------------------|
/// | `loaderRecord`       | `lc[<n>]` \| `section[<segment>,<name>]` \| `<table>[<i>]@<address>` |
/// | `decodedInstruction` | `<address>`                                                          |
/// | `metadataRecord`     | `<section>@<address>`                                                |
/// | `rule`               | `<id>@<version>`                                                     |
/// | `proofCertificate`   | `sha256:<64 lowercase hex>`                                          |
/// | `signatureRecord`    | `<corpus>/<record id>`                                               |
/// | `analystAction`      | `ann:<session>/<seq>`                                                |
/// | `symbolGraph`        | `<module>:<usr>`                                                     |
///
/// Addresses use the subject-ref spelling (`0x`, lowercase hex, no leading zeros); indices are
/// decimal with no leading zeros. `parse(kind:ref:)?.ref == ref` for every canonical ref.
enum NavigatorProvenanceRef: Hashable, Sendable {
    case loadCommand(index: Int)
    case section(segment: String, name: String)
    case tableEntry(table: String, index: Int, address: UInt64)
    case instruction(address: UInt64)
    case metadataRecord(section: String, address: UInt64)
    case rule(id: String, version: String)
    case certificate(hash: String)
    case signatureRecord(corpus: String, recordID: String)
    case analystAction(session: String, seq: Int64)
    case symbolGraph(module: String, usr: String)

    /// Loader tables a `<table>[<i>]@<address>` ref may name.
    static let tables = ["functionStarts", "exports", "nlist", "unwind"]
    static let annotationPrefix = "ann:"

    var kind: String {
        switch self {
        case .loadCommand, .section, .tableEntry: "loaderRecord"
        case .instruction: "decodedInstruction"
        case .metadataRecord: "metadataRecord"
        case .rule: "rule"
        case .certificate: "proofCertificate"
        case .signatureRecord: "signatureRecord"
        case .analystAction: "analystAction"
        case .symbolGraph: "symbolGraph"
        }
    }

    var ref: String {
        switch self {
        case .loadCommand(let index): "lc[\(index)]"
        case .section(let segment, let name): "section[\(segment),\(name)]"
        case .tableEntry(let table, let index, let address): "\(table)[\(index)]@\(NavigatorSubjectRef.address(address))"
        case .instruction(let address): NavigatorSubjectRef.address(address)
        case .metadataRecord(let section, let address): "\(section)@\(NavigatorSubjectRef.address(address))"
        case .rule(let id, let version): "\(id)@\(version)"
        case .certificate(let hash): hash
        case .signatureRecord(let corpus, let recordID): "\(corpus)/\(recordID)"
        case .analystAction(let session, let seq): "\(Self.annotationPrefix)\(session)/\(seq)"
        case .symbolGraph(let module, let usr): "\(module):\(usr)"
        }
    }

    /// A provenance entry carrying this ref (no rule).
    var provenance: NavigatorProvenance {
        NavigatorProvenance(kind: kind, ref: ref)
    }

    static func parse(_ provenance: NavigatorProvenance) -> NavigatorProvenanceRef? {
        parse(kind: provenance.kind, ref: provenance.ref)
    }

    /// Decomposes `ref` as a ref of provenance kind `kind`; nil when it is not in the canonical grammar.
    static func parse(kind: String, ref: String) -> NavigatorProvenanceRef? {
        switch kind {
        case "loaderRecord":
            return parseLoaderRecord(ref)
        case "decodedInstruction":
            return NavigatorSubjectRef.parseAddress(ref).map { .instruction(address: $0) }
        case "metadataRecord":
            guard case .metadataRecord(let section, let address)? = NavigatorSubjectRef.parse(ref, kind: "metadataRecord") else {
                return nil
            }
            return .metadataRecord(section: section, address: address)
        case "rule":
            guard let at = ref.lastIndex(of: "@") else { return nil }
            let id = String(ref[..<at])
            let version = String(ref[ref.index(after: at)...])
            guard !id.isEmpty, !version.isEmpty, !containsControlOrSpace(id), !containsControlOrSpace(version) else {
                return nil
            }
            return .rule(id: id, version: version)
        case "proofCertificate":
            return NavigatorContractValidator.isCertificateRef(ref) ? .certificate(hash: ref) : nil
        case "signatureRecord":
            guard let slash = ref.firstIndex(of: "/") else { return nil }
            let corpus = String(ref[..<slash])
            let recordID = String(ref[ref.index(after: slash)...])
            guard !corpus.isEmpty, !recordID.isEmpty, !containsControlOrSpace(corpus), !containsControlOrSpace(recordID) else {
                return nil
            }
            return .signatureRecord(corpus: corpus, recordID: recordID)
        case "analystAction":
            guard ref.hasPrefix(annotationPrefix) else { return nil }
            let body = ref.dropFirst(annotationPrefix.count)
            guard let slash = body.lastIndex(of: "/") else { return nil }
            let session = String(body[..<slash])
            guard !session.isEmpty, !containsControlOrSpace(session),
                  let seq = parseDecimal(String(body[body.index(after: slash)...])) else { return nil }
            return .analystAction(session: session, seq: Int64(seq))
        case "symbolGraph":
            guard let colon = ref.firstIndex(of: ":") else { return nil }
            let module = String(ref[..<colon])
            let usr = String(ref[ref.index(after: colon)...])
            guard !module.isEmpty, !usr.isEmpty, !containsControlOrSpace(module), !containsControlOrSpace(usr) else {
                return nil
            }
            return .symbolGraph(module: module, usr: usr)
        default:
            return nil
        }
    }

    private static func parseLoaderRecord(_ ref: String) -> NavigatorProvenanceRef? {
        if let at = ref.lastIndex(of: "@") {
            guard let address = NavigatorSubjectRef.parseAddress(String(ref[ref.index(after: at)...])) else { return nil }
            let head = String(ref[..<at])
            guard let open = head.firstIndex(of: "["), head.hasSuffix("]") else { return nil }
            let table = String(head[..<open])
            let indexText = String(head[head.index(after: open) ..< head.index(before: head.endIndex)])
            guard NavigatorJSONCanonical.isIdentifier(table), let index = parseDecimal(indexText) else { return nil }
            return .tableEntry(table: table, index: index, address: address)
        }
        if ref.hasPrefix("lc["), ref.hasSuffix("]") {
            let indexText = String(ref.dropFirst(3).dropLast())
            return parseDecimal(indexText).map { .loadCommand(index: $0) }
        }
        if ref.hasPrefix("section["), ref.hasSuffix("]") {
            let body = ref.dropFirst("section[".count).dropLast()
            let parts = body.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let segment = String(parts[0])
            let name = String(parts[1])
            guard isMachOName(segment), isMachOName(name) else { return nil }
            return .section(segment: segment, name: name)
        }
        return nil
    }

    /// Decimal, no sign, no leading zero except `0`.
    static func parseDecimal(_ text: String) -> Int? {
        let digits = Array(text.utf8)
        guard !digits.isEmpty, digits.count <= 18, digits.allSatisfy({ (0x30 ... 0x39).contains($0) }) else { return nil }
        if digits.count > 1, digits[0] == UInt8(ascii: "0") { return nil }
        return Int(text)
    }

    /// A segment or section name: 1–16 printable ASCII bytes without `,`, `[`, `]`, `@` or space.
    static func isMachOName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1 ... 16).contains(bytes.count) else { return false }
        return bytes.allSatisfy { $0 > 0x20 && $0 < 0x7f && $0 != UInt8(ascii: ",") && $0 != UInt8(ascii: "[")
            && $0 != UInt8(ascii: "]") && $0 != UInt8(ascii: "@") }
    }

    private static func containsControlOrSpace(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value <= 0x20 || $0.value == 0x7f }
    }
}

// MARK: - Image evidence

/// One selected Mach-O slice, re-parsed so every loader record can be located by byte range.
///
/// `LoadedBinary` keeps the parsed summaries but not load-command offsets, section flags, nlist
/// indices or unwind rows, so the evidence re-parses the slice once with `MachOParser` (metadata
/// recovery off) and keeps the loader tables the resolver and the structural proof read. Every
/// range is relative to the start of the slice.
struct NavigatorImageEvidence {
    struct TableEntry: Hashable, Sendable {
        let index: Int
        let address: UInt64
        let range: Range<Int>
    }

    struct ExportTerminal: Hashable, Sendable {
        let range: Range<Int>
        let flags: UInt64
        let value: UInt64?
    }

    static let parseOptions = MachOParseOptions(
        recoverStringLiterals: false, recoverObjectiveCMetadata: false,
        recoverSwiftMetadata: false, parseCodeSignature: false
    )
    private static let nlistSize = 16
    private static let segmentCommandSize = 72
    private static let sectionHeaderSize = 80
    private static let maximumTrieSteps = 1 << 16

    /// The selected slice, indexed from 0.
    let slice: Data
    let file: MachOFile
    /// Image ref of the slice (`<uuid>/<sliceSHA256 prefix16>`), nil when no identity was supplied.
    let image: String?
    /// Base of `LC_FUNCTION_STARTS` and `__unwind_info` offsets: `__TEXT` vmaddr, else the lowest vmaddr.
    let imageBase: UInt64
    /// Base of export-trie values: `__TEXT` vmaddr, else the lowest vmaddr of a segment with file bytes.
    let exportBase: UInt64
    /// Index into `file.loadCommands` of each table's load command.
    let functionStartsCommand: Int?
    let exportTrieCommand: Int?
    let symtabCommand: Int?
    /// `LC_FUNCTION_STARTS` entries, each with the exact ULEB128 bytes of its delta.
    let functionStartEntries: [TableEntry]
    /// Byte range of the export trie.
    let exportTrie: Range<Int>?
    /// Offset and readable entry count of the `nlist_64` array.
    let symbolTableOffset: Int?
    let symbolCount: Int
    let unwindSection: MachOSection?
    let unwindRows: [MachOUnwindFunctionStarts.ResolvedRow]

    private let functionStartIndices: [UInt64: [Int]]
    private let exportIndices: [UInt64: [Int]]
    private let sectionSymbolIndices: [UInt64: [Int]]
    private let unwindIndices: [UInt64: [Int]]

    /// Evidence for the selected slice of `binary`; nil when the slice range lies outside the file
    /// bytes or the slice does not parse.
    init?(binary: LoadedBinary) {
        guard let start = Int(exactly: binary.sliceOffset), start <= binary.bytes.count else { return nil }
        let end: Int
        if let size = binary.sliceSize {
            guard let length = Int(exactly: size), length <= binary.bytes.count - start else { return nil }
            end = start + length
        } else {
            end = binary.bytes.count
        }
        let base = binary.bytes.startIndex
        self.init(slice: Data(binary.bytes[(base + start) ..< (base + end)]),
                  image: binary.artifactIdentity.map(NavigatorSubjectRef.imageRef))
    }

    /// Evidence for a thin slice; nil when it does not parse as a thin Mach-O image.
    init?(slice source: Data, image: String?) {
        let slice = Data(source)
        guard let file = try? MachOParser().parse(slice, options: Self.parseOptions),
              file.selectedSliceOffset == 0 else { return nil }
        self.slice = slice
        self.file = file
        self.image = image

        let text = file.segments.first(where: { $0.name == "__TEXT" })?.vmAddress
        let base = text ?? file.segments.map(\.vmAddress).min() ?? 0
        imageBase = base
        exportBase = text ?? file.segments.filter { $0.fileSize > 0 }.map(\.vmAddress).min() ?? 0

        let commands = file.loadCommands
        let startsIndex = commands.firstIndex { $0.command == MachOConstants.loadCommandFunctionStarts }
        functionStartsCommand = startsIndex
        let trieIndex = commands.firstIndex { $0.command == MachOConstants.loadCommandDyldExportsTrie }
            ?? commands.firstIndex {
                $0.command == MachOConstants.loadCommandDyldInfoOnly || $0.command == MachOConstants.loadCommandDyldInfo
            }
        exportTrieCommand = trieIndex
        let symtabIndex = commands.firstIndex { $0.command == MachOConstants.loadCommandSymtab }
        symtabCommand = symtabIndex

        // LC_FUNCTION_STARTS: ULEB128 deltas from the image base; a zero delta ends the list.
        var starts: [TableEntry] = []
        if let startsIndex, let commandOffset = Int(exactly: commands[startsIndex].offset),
           let dataOffset = Self.u32(slice, commandOffset + 8).map(Int.init),
           let dataSize = Self.u32(slice, commandOffset + 12).map(Int.init),
           dataOffset <= slice.count, dataSize <= slice.count - dataOffset {
            var cursor = dataOffset
            let limit = dataOffset + dataSize
            var address = base
            while cursor < limit {
                let entryStart = cursor
                guard let delta = Self.uleb(slice, &cursor, limit: limit), delta != 0 else { break }
                let (next, overflow) = address.addingReportingOverflow(delta)
                guard !overflow else { break }
                address = next
                starts.append(TableEntry(index: starts.count, address: address, range: entryStart ..< cursor))
            }
        }
        functionStartEntries = starts

        // Export trie: LC_DYLD_EXPORTS_TRIE dataoff/datasize at +8/+12, LC_DYLD_INFO export_off/size at +40/+44.
        var trie: Range<Int>?
        if let trieIndex, let commandOffset = Int(exactly: commands[trieIndex].offset) {
            let isTrieCommand = commands[trieIndex].command == MachOConstants.loadCommandDyldExportsTrie
            let fieldOffset = isTrieCommand ? 8 : 40
            if let offset = Self.u32(slice, commandOffset + fieldOffset).map(Int.init),
               let size = Self.u32(slice, commandOffset + fieldOffset + 4).map(Int.init),
               size > 0, offset <= slice.count, size <= slice.count - offset {
                trie = offset ..< (offset + size)
            }
        }
        exportTrie = trie

        // LC_SYMTAB: symoff at +8, nsyms at +12; only entries that lie inside the slice are readable.
        var symbolOffset: Int?
        var readableSymbols = 0
        if let symtabIndex, let commandOffset = Int(exactly: commands[symtabIndex].offset),
           let offset = Self.u32(slice, commandOffset + 8).map(Int.init),
           let count = Self.u32(slice, commandOffset + 12).map(Int.init), offset <= slice.count {
            symbolOffset = offset
            readableSymbols = min(count, (slice.count - offset) / Self.nlistSize)
        }
        symbolTableOffset = symbolOffset
        symbolCount = readableSymbols

        let unwind = file.sections.first { $0.segmentName == "__TEXT" && $0.sectionName == "__unwind_info" }
        unwindSection = unwind
        let rows = unwind.flatMap { MachOUnwindFunctionStarts.resolvedRows(in: slice, section: $0) } ?? []
        unwindRows = rows

        var byStart: [UInt64: [Int]] = [:]
        for entry in starts { byStart[entry.address, default: []].append(entry.index) }
        functionStartIndices = byStart

        var byExport: [UInt64: [Int]] = [:]
        for (index, export) in file.exports.enumerated() {
            if let address = export.address { byExport[address, default: []].append(index) }
        }
        exportIndices = byExport

        var bySymbol: [UInt64: [Int]] = [:]
        if let symbolOffset {
            for index in 0 ..< readableSymbols {
                let entry = symbolOffset + index * Self.nlistSize
                guard let type = Self.u8(slice, entry + 4), let value = Self.u64(slice, entry + 8) else { continue }
                if Self.isSectionSymbol(type) { bySymbol[value, default: []].append(index) }
            }
        }
        sectionSymbolIndices = bySymbol

        var byUnwind: [UInt64: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            let (address, overflow) = base.addingReportingOverflow(UInt64(row.range.lowerBound))
            if !overflow { byUnwind[address, default: []].append(index) }
        }
        unwindIndices = byUnwind
    }

    // MARK: Table lookups

    /// `LC_FUNCTION_STARTS` indices that list `address`.
    func functionStartHits(_ address: UInt64) -> [Int] { functionStartIndices[address] ?? [] }

    /// `MachOFile.exports` indices whose address is `address`.
    func exportHits(_ address: UInt64) -> [Int] { exportIndices[address] ?? [] }

    /// `nlist_64` indices of N_SECT, non-debug symbols whose value is `address`.
    func sectionSymbolHits(_ address: UInt64) -> [Int] { sectionSymbolIndices[address] ?? [] }

    /// `__unwind_info` second-level entry indices whose function starts at `address`.
    func unwindHits(_ address: UInt64) -> [Int] { unwindIndices[address] ?? [] }

    /// The non-zero-fill section whose address range holds `address`.
    func section(containing address: UInt64) -> MachOSection? {
        file.sections.first { section in
            !section.isZeroFill && address >= section.address && address - section.address < section.size
        }
    }

    /// True for a section that holds instructions: `S_ATTR_PURE_INSTRUCTIONS`, or `__TEXT,__text`.
    static func isExecutable(_ section: MachOSection) -> Bool {
        !section.isZeroFill && (section.flags & MachOConstants.sectionAttributePureInstructions != 0
            || (section.segmentName == "__TEXT" && section.sectionName == "__text"))
    }

    /// Slice offset of `address` inside `section`, when the section has file bytes for `length` bytes there.
    func fileOffset(of address: UInt64, length: Int, in section: MachOSection) -> Int? {
        guard !section.isZeroFill, address >= section.address else { return nil }
        let delta = address - section.address
        guard delta <= section.size, UInt64(length) <= section.size - delta,
              let offset = Int(exactly: UInt64(section.fileOffset) + delta),
              offset <= slice.count, length <= slice.count - offset else { return nil }
        return offset
    }

    // MARK: Record ranges

    /// Byte range of load command `index`, when it lies inside the slice.
    func loadCommandRange(_ index: Int) -> Range<Int>? {
        guard index >= 0, index < file.loadCommands.count,
              let start = Int(exactly: file.loadCommands[index].offset) else { return nil }
        let size = Int(file.loadCommands[index].commandSize)
        guard start <= slice.count, size <= slice.count - start else { return nil }
        return start ..< (start + size)
    }

    /// Byte range of the 80-byte `section_64` header named `segment,name`.
    func sectionHeaderRange(segment: String, name: String) -> Range<Int>? {
        for command in file.loadCommands where command.command == MachOConstants.loadCommandSegment64 {
            guard let base = Int(exactly: command.offset),
                  let sectionCount = Self.u32(slice, base + 64).map(Int.init) else { continue }
            let commandEnd = base + Int(command.commandSize)
            for index in 0 ..< sectionCount {
                let header = base + Self.segmentCommandSize + index * Self.sectionHeaderSize
                guard header + Self.sectionHeaderSize <= commandEnd, header + Self.sectionHeaderSize <= slice.count else {
                    break
                }
                if Self.fixedString(slice, header, length: 16) == name,
                   Self.fixedString(slice, header + 16, length: 16) == segment {
                    return header ..< (header + Self.sectionHeaderSize)
                }
            }
        }
        return nil
    }

    /// Byte range of `nlist_64` entry `index`.
    func symbolRange(_ index: Int) -> Range<Int>? {
        guard let symbolTableOffset, index >= 0, index < symbolCount else { return nil }
        let start = symbolTableOffset + index * Self.nlistSize
        return start ..< (start + Self.nlistSize)
    }

    /// `n_type` and `n_value` of `nlist_64` entry `index`.
    func symbolEntry(_ index: Int) -> (type: UInt8, value: UInt64)? {
        guard let range = symbolRange(index), let type = Self.u8(slice, range.lowerBound + 4),
              let value = Self.u64(slice, range.lowerBound + 8) else { return nil }
        return (type, value)
    }

    /// Byte range of the function-offset word of `__unwind_info` second-level entry `index`.
    func unwindEntryRange(_ index: Int) -> Range<Int>? {
        guard let unwindSection, index >= 0, index < unwindRows.count else { return nil }
        let start = Int(unwindSection.fileOffset) + Int(unwindRows[index].sourceSectionOffset)
        guard start + 4 <= slice.count else { return nil }
        return start ..< (start + 4)
    }

    /// Address of `__unwind_info` second-level entry `index`.
    func unwindAddress(_ index: Int) -> UInt64? {
        guard index >= 0, index < unwindRows.count else { return nil }
        let (address, overflow) = imageBase.addingReportingOverflow(UInt64(unwindRows[index].range.lowerBound))
        return overflow ? nil : address
    }

    /// The terminal-info bytes of `name` in the export trie, with its flags and value (nil for a re-export).
    func exportTerminal(named name: String) -> ExportTerminal? {
        guard let trie = exportTrie, !name.isEmpty else { return nil }
        let target = Array(name.utf8)
        var nodeOffset = 0
        var matched = 0
        for _ in 0 ..< Self.maximumTrieSteps {
            var cursor = trie.lowerBound + nodeOffset
            guard cursor < trie.upperBound, let terminalSize = Self.uleb(slice, &cursor, limit: trie.upperBound),
                  terminalSize <= UInt64(trie.upperBound - cursor) else { return nil }
            let terminalStart = cursor
            let terminalEnd = cursor + Int(terminalSize)
            if matched == target.count {
                guard terminalSize > 0 else { return nil }
                var terminalCursor = terminalStart
                guard let flags = Self.uleb(slice, &terminalCursor, limit: terminalEnd) else { return nil }
                var value: UInt64?
                if flags & MachOConstants.exportSymbolFlagsReexport == 0 {
                    guard let read = Self.uleb(slice, &terminalCursor, limit: terminalEnd) else { return nil }
                    value = read
                }
                return ExportTerminal(range: terminalStart ..< terminalEnd, flags: flags, value: value)
            }
            cursor = terminalEnd
            guard cursor < trie.upperBound, let childCount = Self.u8(slice, cursor).map(Int.init) else { return nil }
            cursor += 1
            var nextNode: Int?
            var nextLength = 0
            for _ in 0 ..< childCount {
                var label: [UInt8] = []
                while cursor < trie.upperBound, let byte = Self.u8(slice, cursor), byte != 0 {
                    label.append(byte)
                    cursor += 1
                }
                guard cursor < trie.upperBound else { return nil }
                cursor += 1
                guard let child = Self.uleb(slice, &cursor, limit: trie.upperBound) else { return nil }
                if nextNode == nil, !label.isEmpty, label.count <= target.count - matched,
                   Array(target[matched ..< (matched + label.count)]) == label {
                    guard let childOffset = Int(exactly: child), childOffset < trie.count else { return nil }
                    nextNode = childOffset
                    nextLength = label.count
                }
            }
            guard let nextNode else { return nil }
            nodeOffset = nextNode
            matched += nextLength
        }
        return nil
    }

    /// The address MachOParser assigns to an export-trie terminal: absolute kind as is, otherwise
    /// export base plus value; nil for a re-export.
    func exportAddress(of terminal: ExportTerminal) -> UInt64? {
        guard let value = terminal.value else { return nil }
        if terminal.flags & 0x3 == 0x2 { return value }
        let (address, overflow) = exportBase.addingReportingOverflow(value)
        return overflow ? nil : address
    }

    // MARK: Byte readers (offsets relative to the slice start)

    static func isSectionSymbol(_ type: UInt8) -> Bool {
        type & MachOConstants.symbolDebugMask == 0 && type & MachOConstants.symbolTypeMask == MachOConstants.symbolTypeSection
    }

    static func u8(_ data: Data, _ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        var value: UInt32 = 0
        for byte in 0 ..< 4 { value |= UInt32(data[data.startIndex + offset + byte]) << (8 * UInt32(byte)) }
        return value
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        var value: UInt64 = 0
        for byte in 0 ..< 8 { value |= UInt64(data[data.startIndex + offset + byte]) << (8 * UInt64(byte)) }
        return value
    }

    static func uleb(_ data: Data, _ cursor: inout Int, limit: Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < limit, cursor < data.count {
            let byte = data[data.startIndex + cursor]
            cursor += 1
            guard shift < 64, shift < 63 || byte & 0x7e == 0 else { return nil }
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func fixedString(_ data: Data, _ offset: Int, length: Int) -> String? {
        guard offset >= 0, offset <= data.count - length else { return nil }
        var bytes: [UInt8] = []
        for index in 0 ..< length {
            let byte = data[data.startIndex + offset + index]
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func sha256(_ range: Range<Int>) -> String {
        AnalysisFingerprintBuilder.sha256Hex(Data(slice[(slice.startIndex + range.lowerBound) ..< (slice.startIndex + range.upperBound)]))
    }
}

// MARK: - Resolver

/// Resolves a provenance entry to the bytes or record it names ("show me the evidence"). Never
/// throws: anything that cannot be shown is `unresolvable` with a typed reason.
enum NavigatorProvenanceResolver {
    enum Unresolvable: String, CaseIterable, Hashable, Sendable {
        /// The provenance kind is not in the contract vocabulary.
        case unknownKind
        /// An index or address lies outside the table, section or slice it names.
        case outOfBounds
        /// The ref is malformed, or names a record that does not exist or does not match.
        case noSuchRecord
        /// The record exists but its bytes do not hash to the cited hash.
        case hashMismatch
    }

    enum Resolved: Hashable {
        /// Raw image bytes: slice-relative range and the SHA-256 of those bytes.
        case bytes(range: Range<Int>, sha256: String)
        /// A structured record. `range` is slice-relative for a loader record and nil for a record
        /// held outside the image (signature corpus, symbol graph); `sha256` covers the record's bytes.
        case record(description: String, range: Range<Int>?, sha256: String)
        case rule(NavigatorPrimitiveDescriptor)
        case certificate(NavigatorProofCertificate)
        case annotation(id: String)
        case unresolvable(Unresolvable)

        var unresolvableReason: Unresolvable? {
            if case .unresolvable(let reason) = self { return reason }
            return nil
        }

        var isResolved: Bool { unresolvableReason == nil }

        /// The slice-relative byte range, for image-backed results.
        var range: Range<Int>? {
            switch self {
            case .bytes(let range, _): range
            case .record(_, let range, _): range
            default: nil
            }
        }

        var sha256: String? {
            switch self {
            case .bytes(_, let sha256), .record(_, _, let sha256): sha256
            default: nil
            }
        }
    }

    /// A record kept outside the image, returned by a signature-corpus or symbol-graph lookup.
    struct ExternalRecord: Hashable, Sendable {
        var description: String
        var bytes: Data
    }

    /// The stores non-image refs resolve against.
    struct Context {
        var rule: (String) -> NavigatorPrimitiveDescriptor?
        /// Certificates keyed by the ref that cites them (`sha256:<hex>`).
        var certificates: [String: NavigatorProofCertificate]
        var annotations: [NavigatorAnnotation]
        var signatureRecord: (_ corpus: String, _ recordID: String) -> ExternalRecord?
        var symbolGraph: (_ module: String, _ usr: String) -> ExternalRecord?

        init(registry: NavigatorPrimitiveRegistry = .standard,
             certificates: [NavigatorProofCertificate] = [],
             annotations: [NavigatorAnnotation] = [],
             signatureRecord: @escaping (_ corpus: String, _ recordID: String) -> ExternalRecord? = { _, _ in nil },
             symbolGraph: @escaping (_ module: String, _ usr: String) -> ExternalRecord? = { _, _ in nil }) {
            rule = { registry.lookup(id: $0) }
            var byHash: [String: NavigatorProofCertificate] = [:]
            for certificate in certificates { byHash[certificate.hash] = certificate }
            self.certificates = byHash
            self.annotations = annotations
            self.signatureRecord = signatureRecord
            self.symbolGraph = symbolGraph
        }
    }

    /// Kinds whose refs name something inside the image bytes.
    static let imageKinds = ["loaderRecord", "decodedInstruction", "metadataRecord"]

    /// Resolves `p` against the selected slice of `image`. The slice is re-parsed per call; callers
    /// resolving many entries build one `NavigatorImageEvidence` and use `resolve(_:in:context:)`.
    static func resolve(_ p: NavigatorProvenance, in image: LoadedBinary, context: Context = Context()) -> Resolved {
        guard NavigatorContractVocabulary.provenanceKinds.containsExactly(p.kind) else { return .unresolvable(.unknownKind) }
        guard imageKinds.containsExactly(p.kind) else { return resolve(p, in: nil, context: context) }
        guard let evidence = NavigatorImageEvidence(binary: image) else { return .unresolvable(.noSuchRecord) }
        return resolve(p, in: evidence, context: context)
    }

    /// Resolves `p`; image kinds need `evidence` and are `noSuchRecord` without it.
    static func resolve(_ p: NavigatorProvenance, in evidence: NavigatorImageEvidence?,
                        context: Context = Context()) -> Resolved {
        guard NavigatorContractVocabulary.provenanceKinds.containsExactly(p.kind) else { return .unresolvable(.unknownKind) }
        guard let parsed = NavigatorProvenanceRef.parse(p) else { return .unresolvable(.noSuchRecord) }
        switch parsed {
        case .loadCommand, .section, .tableEntry, .instruction, .metadataRecord:
            guard let evidence else { return .unresolvable(.noSuchRecord) }
            return resolveImage(parsed, evidence)
        case .rule(let id, let version):
            guard let descriptor = context.rule(id), descriptor.version == version else { return .unresolvable(.noSuchRecord) }
            return .rule(descriptor)
        case .certificate(let hash):
            guard let certificate = context.certificates[hash] else { return .unresolvable(.noSuchRecord) }
            guard certificate.hash == hash, certificate.isIntact else { return .unresolvable(.hashMismatch) }
            return .certificate(certificate)
        case .analystAction(let session, let seq):
            guard let annotation = context.annotations.first(where: { $0.session == session && $0.seq == seq }) else {
                return .unresolvable(.noSuchRecord)
            }
            return .annotation(id: annotation.id)
        case .signatureRecord(let corpus, let recordID):
            guard let record = context.signatureRecord(corpus, recordID) else { return .unresolvable(.noSuchRecord) }
            return .record(description: record.description, range: nil,
                           sha256: AnalysisFingerprintBuilder.sha256Hex(record.bytes))
        case .symbolGraph(let module, let usr):
            guard let record = context.symbolGraph(module, usr) else { return .unresolvable(.noSuchRecord) }
            return .record(description: record.description, range: nil,
                           sha256: AnalysisFingerprintBuilder.sha256Hex(record.bytes))
        }
    }

    private static func resolveImage(_ parsed: NavigatorProvenanceRef, _ evidence: NavigatorImageEvidence) -> Resolved {
        switch parsed {
        case .loadCommand(let index):
            guard index < evidence.file.loadCommands.count, let range = evidence.loadCommandRange(index) else {
                return .unresolvable(.outOfBounds)
            }
            let command = evidence.file.loadCommands[index]
            return .record(description: "\(command.name) (load command \(index), \(command.commandSize) bytes)",
                           range: range, sha256: evidence.sha256(range))
        case .section(let segment, let name):
            guard let range = evidence.sectionHeaderRange(segment: segment, name: name) else {
                return .unresolvable(.noSuchRecord)
            }
            return .record(description: "section_64 \(segment),\(name)", range: range, sha256: evidence.sha256(range))
        case .tableEntry(let table, let index, let address):
            return resolveTableEntry(table: table, index: index, address: address, evidence)
        case .instruction(let address):
            guard let section = evidence.section(containing: address) else { return .unresolvable(.outOfBounds) }
            guard NavigatorImageEvidence.isExecutable(section), address % 4 == 0 else { return .unresolvable(.noSuchRecord) }
            guard let offset = evidence.fileOffset(of: address, length: 4, in: section) else {
                return .unresolvable(.outOfBounds)
            }
            let range = offset ..< (offset + 4)
            return .bytes(range: range, sha256: evidence.sha256(range))
        case .metadataRecord(let sectionName, let address):
            let named = evidence.file.sections.filter { section in
                if let comma = sectionName.firstIndex(of: ",") {
                    return section.segmentName == String(sectionName[..<comma])
                        && section.sectionName == String(sectionName[sectionName.index(after: comma)...])
                }
                return section.sectionName == sectionName
            }
            guard !named.isEmpty else { return .unresolvable(.noSuchRecord) }
            guard let section = named.first(where: {
                !$0.isZeroFill && address >= $0.address && address - $0.address < $0.size
            }) else { return .unresolvable(.outOfBounds) }
            let length = Int(clamping: section.size - (address - section.address))
            guard let offset = evidence.fileOffset(of: address, length: length, in: section) else {
                return .unresolvable(.outOfBounds)
            }
            let range = offset ..< (offset + length)
            return .bytes(range: range, sha256: evidence.sha256(range))
        default:
            return .unresolvable(.noSuchRecord)
        }
    }

    private static func resolveTableEntry(table: String, index: Int, address: UInt64,
                                          _ evidence: NavigatorImageEvidence) -> Resolved {
        let label = NavigatorSubjectRef.address(address)
        switch table {
        case "functionStarts":
            guard index < evidence.functionStartEntries.count else { return .unresolvable(.outOfBounds) }
            let entry = evidence.functionStartEntries[index]
            guard entry.address == address else { return .unresolvable(.noSuchRecord) }
            return .record(description: "LC_FUNCTION_STARTS entry \(index) -> \(label)", range: entry.range,
                           sha256: evidence.sha256(entry.range))
        case "nlist":
            guard evidence.symbolTableOffset != nil, index < evidence.symbolCount else { return .unresolvable(.outOfBounds) }
            guard let entry = evidence.symbolEntry(index), let range = evidence.symbolRange(index) else {
                return .unresolvable(.outOfBounds)
            }
            guard NavigatorImageEvidence.isSectionSymbol(entry.type), entry.value == address else {
                return .unresolvable(.noSuchRecord)
            }
            return .record(description: "nlist_64 \(index) N_SECT -> \(label)", range: range,
                           sha256: evidence.sha256(range))
        case "exports":
            guard index < evidence.file.exports.count else { return .unresolvable(.outOfBounds) }
            let export = evidence.file.exports[index]
            guard export.address == address else { return .unresolvable(.noSuchRecord) }
            if let symbolIndex = export.symbolIndex {
                guard let entry = evidence.symbolEntry(symbolIndex), let range = evidence.symbolRange(symbolIndex) else {
                    return .unresolvable(.outOfBounds)
                }
                guard entry.value == address else { return .unresolvable(.noSuchRecord) }
                return .record(description: "export \(export.name) (nlist_64 \(symbolIndex)) -> \(label)", range: range,
                               sha256: evidence.sha256(range))
            }
            guard let terminal = evidence.exportTerminal(named: export.name),
                  evidence.exportAddress(of: terminal) == address else { return .unresolvable(.noSuchRecord) }
            return .record(description: "export \(export.name) (\(export.source) terminal) -> \(label)",
                           range: terminal.range, sha256: evidence.sha256(terminal.range))
        case "unwind":
            guard index < evidence.unwindRows.count, let range = evidence.unwindEntryRange(index) else {
                return .unresolvable(.outOfBounds)
            }
            guard evidence.unwindAddress(index) == address else { return .unresolvable(.noSuchRecord) }
            return .record(description: "__unwind_info entry \(index) -> \(label)", range: range,
                           sha256: evidence.sha256(range))
        default:
            return .unresolvable(.noSuchRecord)
        }
    }
}
