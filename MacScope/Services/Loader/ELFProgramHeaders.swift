import Foundation

enum ELFProgramHeaderError: Error, Equatable, LocalizedError {
    case notELF
    case truncated(String)
    case unsupported(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notELF: "The file is not an ELF binary."
        case .truncated(let context): "The ELF file is truncated (\(context))."
        case .unsupported(let detail): "Unsupported ELF program-header form: \(detail)."
        case .malformed(let detail): "Malformed ELF program headers: \(detail)."
        }
    }
}

struct ELFProgramHeaderRecord: Hashable, Sendable {
    let index: Int
    let type: UInt32
    let flags: UInt32
    let fileOffset: UInt64
    let virtualAddress: UInt64
    let physicalAddress: UInt64
    let fileSize: UInt64
    let memorySize: UInt64
    let alignment: UInt64

    var isLoadable: Bool { type == 1 }
    var isNote: Bool { type == 4 }
    var isExecutable: Bool { flags & 1 != 0 }
    var isWritable: Bool { flags & 2 != 0 }
    var isReadable: Bool { flags & 4 != 0 }
}

struct ELFNoteRecord: Hashable, Sendable {
    let segmentIndex: Int
    let name: String
    let type: UInt32
    let descriptor: Data
}

struct ELFProgramHeaderCatalog: Hashable, Sendable {
    let is64Bit: Bool
    let isBigEndian: Bool
    let objectType: UInt16
    let machine: UInt16
    let entryPoint: UInt64
    let records: [ELFProgramHeaderRecord]
    let notes: [ELFNoteRecord]
}

struct ELFProgramHeaderParser {
    struct Limits: Hashable, Sendable {
        let maximumProgramHeaders: Int
        let maximumProgramHeaderTableBytes: UInt64
        let maximumNotes: Int
        let maximumNoteNameBytes: UInt64
        let maximumSingleNotePayloadBytes: UInt64
        let maximumTotalNotePayloadBytes: UInt64
        let maximumTotalNoteRegionBytes: UInt64

        static let production = Limits(
            maximumProgramHeaders: 4_096,
            maximumProgramHeaderTableBytes: 8 * 1_024 * 1_024,
            maximumNotes: 4_096,
            maximumNoteNameBytes: 256 * 1_024,
            maximumSingleNotePayloadBytes: 1 * 1_024 * 1_024,
            maximumTotalNotePayloadBytes: 8 * 1_024 * 1_024,
            maximumTotalNoteRegionBytes: 16 * 1_024 * 1_024
        )
    }

    static func hasDeclaredSectionTable(_ bytes: Data) throws -> Bool {
        let header = try headerFields(bytes)
        return header.sectionOffset != 0 && header.sectionCount != 0
    }

    static func parse(_ bytes: Data, limits: Limits = .production) throws -> ELFProgramHeaderCatalog {
        let header = try headerFields(bytes)
        guard header.programHeaderCount != 0xffff else {
            throw ELFProgramHeaderError.unsupported("extended e_phnum (PN_XNUM)")
        }
        let count = Int(header.programHeaderCount)
        guard count <= limits.maximumProgramHeaders else {
            throw ELFProgramHeaderError.malformed("program-header count exceeds bound")
        }
        if count == 0 {
            return ELFProgramHeaderCatalog(
                is64Bit: header.is64Bit, isBigEndian: header.isBigEndian,
                objectType: header.objectType, machine: header.machine,
                entryPoint: header.entryPoint, records: [], notes: []
            )
        }
        guard header.programHeaderOffset != 0 else {
            throw ELFProgramHeaderError.malformed("nonzero e_phnum with zero e_phoff")
        }
        guard Int(header.programHeaderEntrySize) >= header.minimumProgramHeaderSize else {
            throw ELFProgramHeaderError.malformed("e_phentsize is smaller than the ABI record")
        }
        guard header.programHeaderOffset >= UInt64(header.declaredHeaderSize) else {
            throw ELFProgramHeaderError.malformed("program-header table overlaps the ELF header")
        }
        let (tableBytes, tableOverflow) = UInt64(count).multipliedReportingOverflow(
            by: UInt64(header.programHeaderEntrySize)
        )
        guard !tableOverflow, tableBytes <= limits.maximumProgramHeaderTableBytes else {
            throw ELFProgramHeaderError.malformed("program-header table exceeds bound")
        }
        guard let tableRange = checkedRange(
            offset: header.programHeaderOffset,
            size: tableBytes,
            byteCount: bytes.count
        ) else {
            throw ELFProgramHeaderError.truncated("program-header table")
        }

        let reader = ELFEndianReader(bytes: bytes, bigEndian: header.isBigEndian)
        var records: [ELFProgramHeaderRecord] = []
        records.reserveCapacity(count)
        for index in 0..<count {
            let base = tableRange.lowerBound + index * Int(header.programHeaderEntrySize)
            let record: ELFProgramHeaderRecord
            if header.is64Bit {
                record = ELFProgramHeaderRecord(
                    index: index,
                    type: try reader.u32(base),
                    flags: try reader.u32(base + 4),
                    fileOffset: try reader.u64(base + 8),
                    virtualAddress: try reader.u64(base + 16),
                    physicalAddress: try reader.u64(base + 24),
                    fileSize: try reader.u64(base + 32),
                    memorySize: try reader.u64(base + 40),
                    alignment: try reader.u64(base + 48)
                )
            } else {
                record = ELFProgramHeaderRecord(
                    index: index,
                    type: try reader.u32(base),
                    flags: try reader.u32(base + 24),
                    fileOffset: UInt64(try reader.u32(base + 4)),
                    virtualAddress: UInt64(try reader.u32(base + 8)),
                    physicalAddress: UInt64(try reader.u32(base + 12)),
                    fileSize: UInt64(try reader.u32(base + 16)),
                    memorySize: UInt64(try reader.u32(base + 20)),
                    alignment: UInt64(try reader.u32(base + 28))
                )
            }
            try validate(record: record, byteCount: bytes.count)
            records.append(record)
        }
        try validateLoadSegmentOverlap(records)

        var noteState = NoteBudgetState()
        var notes: [ELFNoteRecord] = []
        for record in records where record.isNote && record.fileSize > 0 {
            noteState.totalRegionBytes = try boundedAdd(
                noteState.totalRegionBytes, record.fileSize,
                maximum: limits.maximumTotalNoteRegionBytes,
                message: "aggregate PT_NOTE bytes exceed bound"
            )
            guard let region = checkedRange(
                offset: record.fileOffset, size: record.fileSize, byteCount: bytes.count
            ) else {
                throw ELFProgramHeaderError.truncated("PT_NOTE segment")
            }
            try parseNotes(
                in: region, segmentIndex: record.index, reader: reader,
                limits: limits, state: &noteState, output: &notes
            )
        }
        return ELFProgramHeaderCatalog(
            is64Bit: header.is64Bit, isBigEndian: header.isBigEndian,
            objectType: header.objectType, machine: header.machine,
            entryPoint: header.entryPoint, records: records, notes: notes
        )
    }

    private struct HeaderFields {
        let is64Bit: Bool
        let isBigEndian: Bool
        let objectType: UInt16
        let machine: UInt16
        let entryPoint: UInt64
        let programHeaderOffset: UInt64
        let programHeaderEntrySize: UInt16
        let programHeaderCount: UInt16
        let sectionOffset: UInt64
        let sectionCount: UInt16
        let declaredHeaderSize: Int
        let minimumHeaderSize: Int
        let minimumProgramHeaderSize: Int
    }

    private static func headerFields(_ bytes: Data) throws -> HeaderFields {
        // File-relative reads only: `bytes` may be a slice whose startIndex is above zero.
        let probe = ELFEndianReader(bytes: bytes, bigEndian: false)
        guard bytes.count >= 6,
              probe.byte(0) == 0x7f, probe.byte(1) == 0x45, probe.byte(2) == 0x4c, probe.byte(3) == 0x46 else {
            throw ELFProgramHeaderError.notELF
        }
        let is64Bit: Bool
        switch probe.byte(4) ?? 0 {
        case 1: is64Bit = false
        case 2: is64Bit = true
        default: throw ELFProgramHeaderError.unsupported("unknown ELF class")
        }
        let isBigEndian: Bool
        switch probe.byte(5) ?? 0 {
        case 1: isBigEndian = false
        case 2: isBigEndian = true
        default: throw ELFProgramHeaderError.unsupported("unknown ELF byte order")
        }
        let minimumHeaderSize = is64Bit ? 64 : 52
        guard bytes.count >= minimumHeaderSize else {
            throw ELFProgramHeaderError.truncated("ELF header")
        }
        let reader = ELFEndianReader(bytes: bytes, bigEndian: isBigEndian)
        let declaredHeaderSize = Int(try reader.u16(is64Bit ? 52 : 40))
        guard declaredHeaderSize >= minimumHeaderSize else {
            throw ELFProgramHeaderError.malformed("e_ehsize is smaller than the ABI header")
        }
        guard declaredHeaderSize <= bytes.count else {
            throw ELFProgramHeaderError.truncated("declared ELF header")
        }
        return HeaderFields(
            is64Bit: is64Bit,
            isBigEndian: isBigEndian,
            objectType: try reader.u16(16),
            machine: try reader.u16(18),
            entryPoint: is64Bit ? try reader.u64(24) : UInt64(try reader.u32(24)),
            programHeaderOffset: is64Bit ? try reader.u64(32) : UInt64(try reader.u32(28)),
            programHeaderEntrySize: try reader.u16(is64Bit ? 54 : 42),
            programHeaderCount: try reader.u16(is64Bit ? 56 : 44),
            sectionOffset: is64Bit ? try reader.u64(40) : UInt64(try reader.u32(32)),
            sectionCount: try reader.u16(is64Bit ? 60 : 48),
            declaredHeaderSize: declaredHeaderSize,
            minimumHeaderSize: minimumHeaderSize,
            minimumProgramHeaderSize: is64Bit ? 56 : 32
        )
    }

    private static func validate(record: ELFProgramHeaderRecord, byteCount: Int) throws {
        let (_, virtualOverflow) = record.virtualAddress.addingReportingOverflow(record.memorySize)
        guard !virtualOverflow else {
            throw ELFProgramHeaderError.malformed("program-header virtual range overflow")
        }
        if record.fileSize > 0,
           checkedRange(offset: record.fileOffset, size: record.fileSize, byteCount: byteCount) == nil {
            throw ELFProgramHeaderError.truncated("program-header file range")
        }
        guard record.alignment == 0 || record.alignment == 1 || record.alignment.isPowerOfTwo else {
            throw ELFProgramHeaderError.malformed("p_align is not a power of two")
        }
        guard record.isLoadable else { return }
        guard record.fileSize <= record.memorySize else {
            throw ELFProgramHeaderError.malformed("PT_LOAD p_filesz exceeds p_memsz")
        }
        if record.alignment > 1,
           record.fileOffset % record.alignment != record.virtualAddress % record.alignment {
            throw ELFProgramHeaderError.malformed("PT_LOAD offset/address alignment mismatch")
        }
    }

    private static func validateLoadSegmentOverlap(_ records: [ELFProgramHeaderRecord]) throws {
        let loads = records.filter { $0.isLoadable && $0.memorySize > 0 }
            .sorted { ($0.virtualAddress, $0.index) < ($1.virtualAddress, $1.index) }
        var previousEnd: UInt64?
        for record in loads {
            let end = record.virtualAddress + record.memorySize
            if let previousEnd, record.virtualAddress < previousEnd {
                throw ELFProgramHeaderError.unsupported("overlapping PT_LOAD virtual ranges")
            }
            previousEnd = end
        }
    }

    private struct NoteBudgetState {
        var count = 0
        var totalNameBytes: UInt64 = 0
        var totalPayloadBytes: UInt64 = 0
        var totalRegionBytes: UInt64 = 0
    }

    private static func parseNotes(
        in region: Range<Int>,
        segmentIndex: Int,
        reader: ELFEndianReader,
        limits: Limits,
        state: inout NoteBudgetState,
        output: inout [ELFNoteRecord]
    ) throws {
        var cursor = region.lowerBound
        while cursor < region.upperBound {
            if region.upperBound - cursor < 12 {
                guard reader.allZero(in: cursor..<region.upperBound) else {
                    throw ELFProgramHeaderError.truncated("ELF note header")
                }
                return
            }
            let nameSize = UInt64(try reader.u32(cursor))
            let descriptorSize = UInt64(try reader.u32(cursor + 4))
            let type = try reader.u32(cursor + 8)
            if nameSize == 0, descriptorSize == 0, type == 0 {
                guard reader.allZero(in: cursor..<region.upperBound) else {
                    throw ELFProgramHeaderError.malformed("nonzero bytes after ELF note terminator")
                }
                return
            }
            state.count += 1
            guard state.count <= limits.maximumNotes else {
                throw ELFProgramHeaderError.malformed("note count exceeds bound")
            }
            state.totalNameBytes = try boundedAdd(
                state.totalNameBytes, nameSize, maximum: limits.maximumNoteNameBytes,
                message: "aggregate ELF note names exceed bound"
            )
            guard descriptorSize <= limits.maximumSingleNotePayloadBytes else {
                throw ELFProgramHeaderError.malformed("ELF note payload exceeds per-note bound")
            }
            state.totalPayloadBytes = try boundedAdd(
                state.totalPayloadBytes, descriptorSize,
                maximum: limits.maximumTotalNotePayloadBytes,
                message: "aggregate ELF note payload exceeds bound"
            )
            let nameStart = cursor + 12
            guard let nameEnd = checkedIntAdd(nameStart, nameSize), nameEnd <= region.upperBound,
                  let descriptorStart = aligned4(nameEnd), descriptorStart <= region.upperBound,
                  let descriptorEnd = checkedIntAdd(descriptorStart, descriptorSize),
                  descriptorEnd <= region.upperBound,
                  let next = aligned4(descriptorEnd), next <= region.upperBound else {
                throw ELFProgramHeaderError.truncated("ELF note record")
            }
            let rawName = try reader.byteArray(in: nameStart..<nameEnd)
            let unpaddedName: ArraySlice<UInt8>
            if rawName.last == 0 { unpaddedName = rawName.dropLast() } else { unpaddedName = rawName[...] }
            guard !unpaddedName.contains(0), let name = String(bytes: unpaddedName, encoding: .utf8) else {
                throw ELFProgramHeaderError.malformed("ELF note name is not canonical UTF-8")
            }
            output.append(ELFNoteRecord(
                segmentIndex: segmentIndex,
                name: name,
                type: type,
                descriptor: try reader.subdata(in: descriptorStart..<descriptorEnd)
            ))
            cursor = next
        }
    }

    private static func checkedRange(offset: UInt64, size: UInt64, byteCount: Int) -> Range<Int>? {
        guard offset <= UInt64(byteCount), size <= UInt64(byteCount) - offset,
              let lower = Int(exactly: offset), let count = Int(exactly: size) else { return nil }
        return lower..<(lower + count)
    }

    private static func checkedIntAdd(_ base: Int, _ amount: UInt64) -> Int? {
        guard let amount = Int(exactly: amount), amount <= Int.max - base else { return nil }
        return base + amount
    }

    private static func aligned4(_ value: Int) -> Int? {
        let (sum, overflow) = value.addingReportingOverflow(3)
        return overflow ? nil : sum & ~3
    }

    private static func boundedAdd(
        _ current: UInt64, _ amount: UInt64, maximum: UInt64, message: String
    ) throws -> UInt64 {
        let (sum, overflow) = current.addingReportingOverflow(amount)
        guard !overflow, sum <= maximum else { throw ELFProgramHeaderError.malformed(message) }
        return sum
    }
}

/// Endian-aware reader over an ELF image. MS-25b: every offset and range is FILE-RELATIVE
/// (0 = the first byte of `bytes`), and `bytes` may be a `Data` slice whose `startIndex` is
/// above zero. Bounds are validated in file-relative coordinates before any add, so a crafted
/// offset near `Int.max` is a typed `ELFProgramHeaderError.truncated`, never an overflow trap,
/// and a slice reads exactly the bytes a rebased copy would.
struct ELFEndianReader {
    let bytes: Data
    let bigEndian: Bool
    private let start: Int

    init(bytes: Data, bigEndian: Bool) {
        self.bytes = bytes
        self.bigEndian = bigEndian
        self.start = bytes.startIndex
    }

    /// File-relative containment; once admitted, `start + offset + width <= bytes.endIndex`.
    func contains(offset: Int, width: Int) -> Bool {
        offset >= 0 && width >= 0 && offset <= bytes.count && width <= bytes.count - offset
    }

    private func contains(_ range: Range<Int>) -> Bool {
        contains(offset: range.lowerBound, width: range.count)
    }

    func byte(_ offset: Int) -> UInt8? {
        guard contains(offset: offset, width: 1) else { return nil }
        return bytes[start + offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        guard contains(offset: offset, width: 2) else {
            throw ELFProgramHeaderError.truncated("u16@\(offset)")
        }
        let value = UInt16(bytes[start + offset]) | UInt16(bytes[start + offset + 1]) << 8
        return bigEndian ? value.byteSwapped : value
    }

    func u32(_ offset: Int) throws -> UInt32 {
        guard contains(offset: offset, width: 4) else {
            throw ELFProgramHeaderError.truncated("u32@\(offset)")
        }
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[start + offset + index]) << UInt32(index * 8) }
        return bigEndian ? value.byteSwapped : value
    }

    func u64(_ offset: Int) throws -> UInt64 {
        guard contains(offset: offset, width: 8) else {
            throw ELFProgramHeaderError.truncated("u64@\(offset)")
        }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[start + offset + index]) << UInt64(index * 8) }
        return bigEndian ? value.byteSwapped : value
    }

    /// The file-relative `range` as a fresh zero-based array; typed truncation when out of bounds.
    func byteArray(in range: Range<Int>) throws -> [UInt8] {
        guard contains(range) else {
            throw ELFProgramHeaderError.truncated("bytes@\(range.lowerBound)+\(range.count)")
        }
        return Array(bytes[(start + range.lowerBound)..<(start + range.upperBound)])
    }

    /// The file-relative `range` as a fresh zero-based `Data`; typed truncation when out of bounds.
    func subdata(in range: Range<Int>) throws -> Data {
        guard contains(range) else {
            throw ELFProgramHeaderError.truncated("bytes@\(range.lowerBound)+\(range.count)")
        }
        return bytes.subdata(in: (start + range.lowerBound)..<(start + range.upperBound))
    }

    /// True when every byte of the file-relative `range` is zero; false when it is out of bounds.
    func allZero(in range: Range<Int>) -> Bool {
        guard contains(range) else { return false }
        return !bytes[(start + range.lowerBound)..<(start + range.upperBound)].contains { $0 != 0 }
    }
}

private extension UInt64 {
    var isPowerOfTwo: Bool { self != 0 && (self & (self - 1)) == 0 }
}
