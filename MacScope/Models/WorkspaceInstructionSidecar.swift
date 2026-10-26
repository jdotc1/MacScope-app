import Foundation

/// Manifest metadata for the package-v4 instruction payload. The package reader owns
/// path, regular-file, byte-count and SHA-256 admission before calling the codec.
struct WorkspaceInstructionSidecarDescriptor: Codable, Equatable, Sendable {
    var path: String
    var byteCount: UInt64
    var sha256: String
    var analysisFormatVersion: Int
    var groups: [WorkspaceInstructionSidecarGroupDescriptor]
}

struct WorkspaceInstructionSidecarGroupDescriptor: Codable, Equatable, Sendable {
    var binaryID: UUID?
    var imageSlot: ImageSlot?
    var rowCount: UInt64
    var controlFlowEdgeCount: UInt64? = nil
    var basicBlockCount: UInt64? = nil
}

/// Deterministic wire format, independent of Swift's in-memory representation:
/// "MSINST" + UInt16(1), UInt32 group count, then ordered groups. All integers are
/// little-endian. Owner tag 0 means legacy; tag 1 adds a 16-byte UUID in RFC byte
/// order and a UInt64 image slot. Each owner is followed by UInt64 row count.
/// Version 2 adds UInt64 control-flow count after each instruction group, then
/// UUID (16 RFC bytes), UInt64 from/to and a length-prefixed UTF-8 kind per edge.
/// Its optional descriptor edge counts are required for every v2 group.
/// Version 3 additionally appends UInt64 block count and ordered 56-byte block rows:
/// UUID id, UUID functionID, UInt64 start/end, and signed Int64 instruction count.
/// Every v3 descriptor includes edge and block counts, even when zero.
/// Rows contain UInt64 address, UInt8 breakpoint, then UInt32-length-prefixed UTF-8
/// bytes/mnemonic/operands/comment. UInt32.max means nil only for comment.
/// Version 4 is selected only when at least one row has structured operands. A UInt8
/// flags field immediately after the eight-byte magic selects flow (bit 0) and blocks
/// (bit 1); other bits are reserved, and blocks require flow. Group descriptor counts
/// follow those flags, including zero counts and the existing global nil-to-empty rules.
/// Every v4 row appends UInt32 JSON byte length after comment, or UInt32.max for nil.
/// JSON uses InstructionOperandsStorageCodec and is bounded before allocation on read.
/// Minimum row size is 25 bytes for v1-v3 and 29 bytes for v4. Outer package version is 4.
enum WorkspaceInstructionSidecarCodec {
    static let fileName = "instructions.bin"
    static let maximumBytes: UInt64 = 1_073_741_824
    static let maximumControlFlowBytes: UInt64 = 268_435_456
    static let maximumBasicBlockBytes: UInt64 = 268_435_456
    static let basicBlockRowBytes: UInt64 = 56

    struct Group {
        let binaryID: UUID?
        let imageSlot: ImageSlot?
        let instructions: [InstructionRow]
        var controlFlowEdges: [ControlFlowEdge]? = nil {
            didSet { controlFlowFingerprintMemo = AnalysisFacetDigestMemo() }
        }
        var basicBlocks: [BasicBlockSummary]? = nil
        let instructionFingerprintMemo = AnalysisFacetDigestMemo()
        var controlFlowFingerprintMemo = AnalysisFacetDigestMemo()
    }

    enum Failure: Error, Equatable, LocalizedError {
        case invalidHeader
        case exceedsMaximumSize
        case invalidOwner
        case duplicateOwner
        case groupCountMismatch
        case ownerMismatch
        case rowCountMismatch
        case invalidBreakpointFlag
        case duplicateAddress(UInt64)
        case invalidUTF8
        case invalidStringLength
        case truncated
        case trailingBytes

        var errorDescription: String? {
            switch self {
            case .invalidHeader: "The instruction sidecar has an unsupported header or version."
            case .exceedsMaximumSize: "The instruction sidecar exceeds its size limit."
            case .invalidOwner: "The instruction sidecar has an invalid image identity."
            case .duplicateOwner: "The instruction sidecar repeats an image identity."
            case .groupCountMismatch: "The instruction sidecar group count differs from its manifest."
            case .ownerMismatch: "The instruction sidecar image identity differs from its manifest."
            case .rowCountMismatch: "The instruction sidecar row count differs from its manifest or available bytes."
            case .invalidBreakpointFlag: "The instruction sidecar contains an unknown breakpoint flag."
            case .duplicateAddress(let address): "The instruction sidecar repeats address \(address) within an image."
            case .invalidUTF8: "The instruction sidecar contains invalid UTF-8."
            case .invalidStringLength: "The instruction sidecar contains an invalid string length."
            case .truncated: "The instruction sidecar is truncated."
            case .trailingBytes: "The instruction sidecar contains undeclared trailing bytes."
            }
        }
    }

    private static let magic: [UInt8] = [0x4D, 0x53, 0x49, 0x4E, 0x53, 0x54, 0x01, 0x00]
    private static let flowMagic: [UInt8] = [0x4D, 0x53, 0x49, 0x4E, 0x53, 0x54, 0x02, 0x00]
    private static let blockMagic: [UInt8] = [0x4D, 0x53, 0x49, 0x4E, 0x53, 0x54, 0x03, 0x00]
    private static let operandMagic: [UInt8] = [0x4D, 0x53, 0x49, 0x4E, 0x53, 0x54, 0x04, 0x00]
    private static let minimumRowBytes: UInt64 = 25
    private static let minimumOperandRowBytes: UInt64 = 29

    static func encode(_ groups: [Group]) throws -> Data {
        try Task.checkCancellation()
        guard let groupCount = UInt32(exactly: groups.count) else {
            throw Failure.exceedsMaximumSize
        }
        let includesOperands = groups.contains { $0.instructions.contains { $0.structuredOperands != nil } }
        let includesBlocks = groups.contains { $0.basicBlocks != nil }
        let includesFlow = includesBlocks || groups.contains { $0.controlFlowEdges != nil }
        let rowMinimum = includesOperands ? minimumOperandRowBytes : minimumRowBytes
        var owners = Owners()
        var minimumBytes: UInt64 = includesOperands ? 13 : 12
        for (index, group) in groups.enumerated() {
            if index & 0x3FF == 0 { try Task.checkCancellation() }
            try owners.insert(binaryID: group.binaryID, imageSlot: group.imageSlot)
            let headerBytes: UInt64 = group.binaryID == nil ? 9 : 33
            guard headerBytes <= maximumBytes - minimumBytes else {
                throw Failure.exceedsMaximumSize
            }
            minimumBytes += headerBytes
            let count = UInt64(group.instructions.count)
            guard count <= (maximumBytes - minimumBytes) / rowMinimum else {
                throw Failure.exceedsMaximumSize
            }
            minimumBytes += count * rowMinimum
        }

        var flowBytes: UInt64 = 0
        var blockBytes: UInt64 = 0
        var writer = Writer()
        // Avoid an enormous speculative allocation for a malformed input. Normal
        // vim-sized saves grow this buffer geometrically beyond the initial 16 MiB.
        writer.data.reserveCapacity(Int(min(minimumBytes, 16 * 1_024 * 1_024)))
        writer.data.append(contentsOf: includesOperands ? operandMagic : (includesBlocks ? blockMagic : (includesFlow ? flowMagic : magic)))
        if includesOperands {
            try writer.byte((includesFlow ? 1 : 0) | (includesBlocks ? 2 : 0))
        }
        try writer.integer(groupCount)
        for group in groups {
            try Task.checkCancellation()
            if let binaryID = group.binaryID, let imageSlot = group.imageSlot {
                try writer.byte(1)
                var uuid = binaryID.uuid
                try withUnsafeBytes(of: &uuid) { try writer.append($0) }
                try writer.integer(UInt64(imageSlot.rawValue))
            } else {
                try writer.byte(0)
            }
            try writer.integer(UInt64(group.instructions.count))
            var addresses = Set<UInt64>()
            addresses.reserveCapacity(min(group.instructions.count, 65_536))
            for (index, row) in group.instructions.enumerated() {
                if index & 0x3FF == 0 { try Task.checkCancellation() }
                guard addresses.insert(row.address).inserted else {
                    throw Failure.duplicateAddress(row.address)
                }
                try writer.integer(row.address)
                try writer.byte(row.hasBreakpoint ? 1 : 0)
                try writer.string(row.bytes)
                try writer.string(row.mnemonic)
                try writer.string(row.operands)
                if let comment = row.comment {
                    try writer.string(comment)
                } else {
                    try writer.integer(UInt32.max)
                }
                if includesOperands {
                    if let operands = row.structuredOperands {
                        let payload = try InstructionOperandsStorageCodec.encode(operands)
                        guard payload.count <= InstructionOperandsStorageCodec.maximumBytes,
                              let length = UInt32(exactly: payload.count), length != UInt32.max else {
                            throw Failure.exceedsMaximumSize
                        }
                        try writer.integer(length)
                        try payload.withUnsafeBytes { try writer.append($0) }
                    } else {
                        try writer.integer(UInt32.max)
                    }
                }
            }
            if includesFlow {
                let edges = group.controlFlowEdges ?? []
                try addFlowBytes(8, total: &flowBytes)
                guard UInt64(edges.count) <= (maximumControlFlowBytes - flowBytes) / 36 else {
                    throw Failure.exceedsMaximumSize
                }
                try writer.integer(UInt64(edges.count))
                for (index, edge) in edges.enumerated() {
                    if index & 0x3FF == 0 { try Task.checkCancellation() }
                    try addFlowBytes(36 + UInt64(edge.kind.utf8.count), total: &flowBytes)
                    var id = edge.id.uuid
                    try withUnsafeBytes(of: &id) { try writer.append($0) }
                    try writer.integer(edge.from)
                    try writer.integer(edge.to)
                    try writer.string(edge.kind)
                }
            }
            if includesBlocks {
                let blocks = group.basicBlocks ?? []
                try addBlockBytes(8, total: &blockBytes)
                guard UInt64(blocks.count) <= (maximumBasicBlockBytes - blockBytes) / basicBlockRowBytes else {
                    throw Failure.exceedsMaximumSize
                }
                try writer.integer(UInt64(blocks.count))
                for (index, block) in blocks.enumerated() {
                    if index & 0x3FF == 0 { try Task.checkCancellation() }
                    try addBlockBytes(basicBlockRowBytes, total: &blockBytes)
                    var id = block.id.uuid
                    var functionID = block.functionID.uuid
                    try withUnsafeBytes(of: &id) { try writer.append($0) }
                    try withUnsafeBytes(of: &functionID) { try writer.append($0) }
                    try writer.integer(block.startAddress)
                    try writer.integer(block.endAddress)
                    guard let instructionCount = Int64(exactly: block.instructionCount) else {
                        throw Failure.rowCountMismatch
                    }
                    try writer.integer(instructionCount)
                }
            }
        }
        try Task.checkCancellation()
        return writer.data
    }

    /// The descriptor order is part of the format; every UUID, slot and row count
    /// must match before rows can join a logical image in the manifest.
    static func decode(
        _ data: Data,
        groups descriptors: [WorkspaceInstructionSidecarGroupDescriptor]
    ) throws -> [Group] {
        try Task.checkCancellation()
        guard UInt64(data.count) <= maximumBytes else { throw Failure.exceedsMaximumSize }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= magic.count else { throw Failure.invalidHeader }
            let includesOperands = bytes.prefix(magic.count).elementsEqual(operandMagic)
            var reader = Reader(bytes: bytes, offset: magic.count)
            let includesBlocks: Bool
            let includesFlow: Bool
            if includesOperands {
                let flags = try reader.byte()
                guard flags & ~UInt8(3) == 0, flags & 2 == 0 || flags & 1 != 0 else {
                    throw Failure.invalidHeader
                }
                includesFlow = flags & 1 != 0
                includesBlocks = flags & 2 != 0
            } else {
                includesBlocks = bytes.prefix(magic.count).elementsEqual(blockMagic)
                includesFlow = includesBlocks || bytes.prefix(magic.count).elementsEqual(flowMagic)
                guard includesFlow || bytes.prefix(magic.count).elementsEqual(magic) else {
                    throw Failure.invalidHeader
                }
            }
            guard descriptors.allSatisfy({ ($0.controlFlowEdgeCount != nil) == includesFlow
                && ($0.basicBlockCount != nil) == includesBlocks }) else {
                throw Failure.invalidHeader
            }
            let rowMinimum = includesOperands ? minimumOperandRowBytes : minimumRowBytes
            var flowBytes: UInt64 = 0
            var blockBytes: UInt64 = 0
            let count = try reader.uint32()
            guard UInt64(count) == UInt64(descriptors.count) else { throw Failure.groupCountMismatch }
            guard UInt64(count) <= UInt64(reader.remaining / 9) else { throw Failure.truncated }

            var expectedOwners = Owners()
            for (index, descriptor) in descriptors.enumerated() {
                if index & 0x3FF == 0 { try Task.checkCancellation() }
                try expectedOwners.insert(binaryID: descriptor.binaryID, imageSlot: descriptor.imageSlot)
            }
            var groups: [Group] = []
            groups.reserveCapacity(min(descriptors.count, 1_024))
            var actualOwners = Owners()
            for descriptor in descriptors {
                try Task.checkCancellation()
                let binaryID: UUID?
                let imageSlot: ImageSlot?
                switch try reader.byte() {
                case 0:
                    binaryID = nil
                    imageSlot = nil
                case 1:
                    binaryID = try reader.uuid()
                    guard let slot = Int(exactly: try reader.uint64()) else { throw Failure.invalidOwner }
                    imageSlot = ImageSlot(rawValue: slot)
                default:
                    throw Failure.invalidOwner
                }
                try actualOwners.insert(binaryID: binaryID, imageSlot: imageSlot)
                guard binaryID == descriptor.binaryID, imageSlot == descriptor.imageSlot else {
                    throw Failure.ownerMismatch
                }
                let rowCount = try reader.uint64()
                guard rowCount == descriptor.rowCount,
                      rowCount <= UInt64(reader.remaining) / rowMinimum,
                      let integerCount = Int(exactly: rowCount) else {
                    throw Failure.rowCountMismatch
                }
                var instructions: [InstructionRow] = []
                instructions.reserveCapacity(min(integerCount, 65_536))
                var addresses = Set<UInt64>()
                addresses.reserveCapacity(min(integerCount, 65_536))
                for index in 0..<integerCount {
                    if index & 0x3FF == 0 { try Task.checkCancellation() }
                    let address = try reader.uint64()
                    guard addresses.insert(address).inserted else { throw Failure.duplicateAddress(address) }
                    let breakpoint = try reader.byte()
                    guard breakpoint <= 1 else { throw Failure.invalidBreakpointFlag }
                    let bytes = try reader.string()
                    let mnemonic = try reader.string()
                    let operands = try reader.string()
                    let comment = try reader.optionalString()
                    let structuredOperands = includesOperands ? try reader.optionalOperands() : nil
                    instructions.append(InstructionRow(
                        address: address,
                        bytes: bytes,
                        mnemonic: mnemonic,
                        operands: operands,
                        hasBreakpoint: breakpoint == 1,
                        comment: comment,
                        structuredOperands: structuredOperands
                    ))
                }
                var edges: [ControlFlowEdge]?
                if includesFlow {
                    try addFlowBytes(8, total: &flowBytes)
                    let count = try reader.uint64()
                    guard count == descriptor.controlFlowEdgeCount,
                          count <= UInt64(reader.remaining) / 36,
                          count <= (maximumControlFlowBytes - flowBytes) / 36,
                          let integerCount = Int(exactly: count) else { throw Failure.rowCountMismatch }
                    var decoded: [ControlFlowEdge] = []
                    decoded.reserveCapacity(min(integerCount, 65_536))
                    for index in 0..<integerCount {
                        if index & 0x3FF == 0 { try Task.checkCancellation() }
                        let start = reader.offset
                        let id = try reader.uuid()
                        let from = try reader.uint64()
                        let to = try reader.uint64()
                        guard 36 <= maximumControlFlowBytes - flowBytes else { throw Failure.exceedsMaximumSize }
                        let kind = try reader.string(maximumBytes: maximumControlFlowBytes - flowBytes - 36)
                        try addFlowBytes(UInt64(reader.offset - start), total: &flowBytes)
                        decoded.append(ControlFlowEdge(id: id, from: from, to: to, kind: kind))
                    }
                    edges = decoded
                }
                var blocks: [BasicBlockSummary]?
                if includesBlocks {
                    try addBlockBytes(8, total: &blockBytes)
                    let count = try reader.uint64()
                    guard count == descriptor.basicBlockCount,
                          count <= UInt64(reader.remaining) / basicBlockRowBytes,
                          count <= (maximumBasicBlockBytes - blockBytes) / basicBlockRowBytes,
                          let integerCount = Int(exactly: count) else { throw Failure.rowCountMismatch }
                    var decoded: [BasicBlockSummary] = []
                    decoded.reserveCapacity(min(integerCount, 65_536))
                    for index in 0..<integerCount {
                        if index & 0x3FF == 0 { try Task.checkCancellation() }
                        try addBlockBytes(basicBlockRowBytes, total: &blockBytes)
                        let id = try reader.uuid()
                        let functionID = try reader.uuid()
                        let start = try reader.uint64()
                        let end = try reader.uint64()
                        guard let instructionCount = Int(exactly: Int64(bitPattern: try reader.uint64())) else {
                            throw Failure.rowCountMismatch
                        }
                        decoded.append(BasicBlockSummary(id: id, functionID: functionID,
                            startAddress: start, endAddress: end, instructionCount: instructionCount))
                    }
                    blocks = decoded
                }
                groups.append(Group(binaryID: binaryID, imageSlot: imageSlot, instructions: instructions,
                                    controlFlowEdges: edges, basicBlocks: blocks))
            }
            guard reader.remaining == 0 else { throw Failure.trailingBytes }
            try Task.checkCancellation()
            return groups
        }
    }

    private static func addFlowBytes(_ count: UInt64, total: inout UInt64) throws {
        guard count <= maximumControlFlowBytes - total else { throw Failure.exceedsMaximumSize }
        total += count
    }

    private static func addBlockBytes(_ count: UInt64, total: inout UInt64) throws {
        guard count <= maximumBasicBlockBytes - total else { throw Failure.exceedsMaximumSize }
        total += count
    }

    private struct Owners {
        var hasLegacy = false
        var binaryIDs = Set<UUID>()
        var slots = Set<ImageSlot>()

        mutating func insert(binaryID: UUID?, imageSlot: ImageSlot?) throws {
            switch (binaryID, imageSlot) {
            case (nil, nil):
                guard !hasLegacy else { throw Failure.duplicateOwner }
                hasLegacy = true
            case (.some(let binaryID), .some(let imageSlot)):
                guard imageSlot.rawValue >= 0 else { throw Failure.invalidOwner }
                guard binaryIDs.insert(binaryID).inserted, slots.insert(imageSlot).inserted else {
                    throw Failure.duplicateOwner
                }
            default:
                throw Failure.invalidOwner
            }
        }
    }

    private struct Writer {
        var data = Data()

        mutating func byte(_ value: UInt8) throws {
            guard UInt64(data.count) < maximumBytes else { throw Failure.exceedsMaximumSize }
            data.append(value)
        }

        mutating func integer<T: FixedWidthInteger>(_ value: T) throws {
            var littleEndian = value.littleEndian
            try withUnsafeBytes(of: &littleEndian) { try append($0) }
        }

        mutating func append(_ bytes: UnsafeRawBufferPointer) throws {
            guard UInt64(bytes.count) <= maximumBytes - UInt64(data.count) else {
                throw Failure.exceedsMaximumSize
            }
            data.append(contentsOf: bytes)
        }

        mutating func string(_ value: String) throws {
            let utf8 = value.utf8
            let count = utf8.count
            guard let length = UInt32(exactly: count), length != UInt32.max else {
                throw Failure.invalidStringLength
            }
            try integer(length)
            guard UInt64(count) <= maximumBytes - UInt64(data.count) else {
                throw Failure.exceedsMaximumSize
            }
            if count <= 65_536 {
                data.append(contentsOf: utf8)
            } else {
                // Most fields are tiny. Bound cooperative cancellation for a rare
                // large user-authored comment without copying it to another Data.
                var start = utf8.startIndex
                while start < utf8.endIndex {
                    try Task.checkCancellation()
                    let end = utf8.index(start, offsetBy: 65_536, limitedBy: utf8.endIndex) ?? utf8.endIndex
                    data.append(contentsOf: utf8[start..<end])
                    start = end
                }
            }
        }
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var offset: Int

        var remaining: Int { bytes.count - offset }

        mutating func byte() throws -> UInt8 {
            guard remaining >= 1 else { throw Failure.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func uint32() throws -> UInt32 {
            guard remaining >= 4 else { throw Failure.truncated }
            defer { offset += 4 }
            return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }

        mutating func uint64() throws -> UInt64 {
            guard remaining >= 8 else { throw Failure.truncated }
            defer { offset += 8 }
            return UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }

        mutating func uuid() throws -> UUID {
            guard remaining >= 16 else { throw Failure.truncated }
            let i = offset
            offset += 16
            return UUID(uuid: (
                bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3],
                bytes[i + 4], bytes[i + 5], bytes[i + 6], bytes[i + 7],
                bytes[i + 8], bytes[i + 9], bytes[i + 10], bytes[i + 11],
                bytes[i + 12], bytes[i + 13], bytes[i + 14], bytes[i + 15]
            ))
        }

        mutating func string(maximumBytes: UInt64 = UInt64.max) throws -> String {
            let length = try uint32()
            guard length != UInt32.max else { throw Failure.invalidStringLength }
            guard UInt64(length) <= maximumBytes else { throw Failure.exceedsMaximumSize }
            return try string(length: length)
        }

        mutating func optionalString() throws -> String? {
            let length = try uint32()
            if length == UInt32.max { return nil }
            return try string(length: length)
        }

        mutating func optionalOperands() throws -> InstructionOperands? {
            let length = try uint32()
            if length == UInt32.max { return nil }
            guard UInt64(length) <= UInt64(InstructionOperandsStorageCodec.maximumBytes) else {
                throw Failure.exceedsMaximumSize
            }
            let count = Int(length)
            guard count <= remaining else { throw Failure.truncated }
            try Task.checkCancellation()
            let payload = Data(bytes[offset..<(offset + count)])
            let value = try InstructionOperandsStorageCodec.decode(payload)
            offset += count
            return value
        }

        private mutating func string(length: UInt32) throws -> String {
            let count = Int(length)
            guard count <= remaining else { throw Failure.truncated }
            if count > 65_536 { try Task.checkCancellation() }
            guard let value = String(bytes: bytes[offset..<(offset + count)], encoding: .utf8) else {
                throw Failure.invalidUTF8
            }
            offset += count
            return value
        }
    }
}
