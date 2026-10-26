import Foundation
import XCTest
@testable import MacScope

final class WorkspaceBasicBlockSidecarTests: XCTestCase {
    private typealias Codec = WorkspaceInstructionSidecarCodec

    func testVersion3PreservesRowsBoundariesCountsAndImageOwnership() throws {
        let functionID = UUID()
        let blocks = [
            BasicBlockSummary(id: UUID(), functionID: functionID, startAddress: UInt64.max, endAddress: 0, instructionCount: Int.min),
            BasicBlockSummary(id: UUID(), functionID: functionID, startAddress: 7, endAddress: 7, instructionCount: Int.max),
            BasicBlockSummary(id: UUID(), functionID: UUID(), startAddress: 7, endAddress: 9, instructionCount: 0)
        ]
        let edge = ControlFlowEdge(id: UUID(), from: 7, to: 9, kind: "unknown λ")
        let groups = [Codec.Group(binaryID: UUID(), imageSlot: .init(rawValue: 9), instructions: [],
                                 controlFlowEdges: [edge], basicBlocks: blocks),
                      Codec.Group(binaryID: UUID(), imageSlot: .init(rawValue: 3), instructions: [],
                                 controlFlowEdges: [], basicBlocks: [])]
        let data = try Codec.encode(groups)
        XCTAssertEqual(data[6], 3)
        let restored = try Codec.decode(data, groups: descriptors(groups))
        XCTAssertEqual(restored[0].basicBlocks, blocks)
        XCTAssertEqual(restored[1].basicBlocks, [])
        XCTAssertEqual(restored[0].controlFlowEdges, [edge])
        XCTAssertEqual(restored.map(\.binaryID), groups.map(\.binaryID))
        XCTAssertEqual(restored.map(\.imageSlot), groups.map(\.imageSlot))
        XCTAssertEqual(try Codec.encode(restored), data)
    }

    func testVersion3RejectsTruncationTrailingBytesAndMismatchedDescriptors() throws {
        let group = sampleGroup()
        let data = try Codec.encode([group])
        let descriptor = descriptors([group])[0]
        // Block-only legacy group: header12, owner1, instructions8, edges8, blocks8, row56.
        for length in [0, 7, 12, 20, 28, 36, data.count - 1] {
            XCTAssertThrowsError(try Codec.decode(Data(data.prefix(length)), groups: [descriptor]))
        }
        XCTAssertThrowsError(try Codec.decode(data + Data([0]), groups: [descriptor]))
        for count in [nil, 0, 2, UInt64.max] as [UInt64?] {
            var wrong = descriptor
            wrong.basicBlockCount = count
            XCTAssertThrowsError(try Codec.decode(data, groups: [wrong]))
        }
        var wrongOwner = descriptor
        wrongOwner.binaryID = UUID()
        wrongOwner.imageSlot = .primary
        XCTAssertThrowsError(try Codec.decode(data, groups: [wrongOwner]))
        var futureVersion = data
        futureVersion[6] = 4
        XCTAssertThrowsError(try Codec.decode(futureVersion, groups: [descriptor]))
    }

    func testBasicBlockDeclaredCountEnforcesIndependentCapWithoutAllocatingRows() throws {
        let group = sampleGroup()
        var data = try Codec.encode([group])
        var descriptor = descriptors([group])[0]
        let count = Codec.maximumBasicBlockBytes / Codec.basicBlockRowBytes + 1
        var littleEndian = count.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.replaceSubrange(29..<37, with: $0) }
        descriptor.basicBlockCount = count
        XCTAssertThrowsError(try Codec.decode(data, groups: [descriptor])) { error in
            XCTAssertEqual(error as? Codec.Failure, .rowCountMismatch)
        }
        // Counts are 56-byte records plus one count per group, bounded separately from 1 GiB transport.
        XCTAssertLessThan(Codec.maximumBasicBlockBytes, Codec.maximumBytes)
    }

    /// One new block-only sample. T1 instruction and T11 edge measurements are reused, not repeated.
    func testVimScaleBasicBlockSingleBeforeAfterSample() throws {
        let functionID = UUID()
        let rows = (0..<130_175).map { index in
            BasicBlockSummary(id: UUID(), functionID: functionID, startAddress: 0x1000 + UInt64(index) * 16,
                              endAddress: 0x1010 + UInt64(index) * 16, instructionCount: 4)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let before = ContinuousClock.now
        let json = try encoder.encode(rows)
        let encodedJSON = ContinuousClock.now
        let jsonRows = try JSONDecoder().decode([BasicBlockSummary].self, from: json)
        let decodedJSON = ContinuousClock.now
        XCTAssertEqual(jsonRows, rows)
        let group = Codec.Group(binaryID: nil, imageSlot: nil, instructions: [], controlFlowEdges: [], basicBlocks: rows)
        let descriptor = descriptors([group])
        let binaryStart = ContinuousClock.now
        let binary = try Codec.encode([group])
        let encodedBinary = ContinuousClock.now
        let decoded = try Codec.decode(binary, groups: descriptor)
        let decodedBinary = ContinuousClock.now
        XCTAssertEqual(decoded[0].basicBlocks, rows)
        XCTAssertLessThan(binary.count, json.count)
        print("T16_BLOCK_SAMPLE rows=\(rows.count) jsonEncode=\(before.duration(to: encodedJSON)) jsonDecode=\(encodedJSON.duration(to: decodedJSON)) binaryEncode=\(binaryStart.duration(to: encodedBinary)) binaryDecode=\(encodedBinary.duration(to: decodedBinary)) jsonBytes=\(json.count) binaryBytes=\(binary.count)")
    }

    private func sampleGroup() -> Codec.Group {
        .init(binaryID: nil, imageSlot: nil, instructions: [], controlFlowEdges: [], basicBlocks: [
            BasicBlockSummary(id: UUID(), functionID: UUID(), startAddress: 1, endAddress: 5, instructionCount: 1)
        ])
    }

    private func descriptors(_ groups: [Codec.Group]) -> [WorkspaceInstructionSidecarGroupDescriptor] {
        groups.map { .init(binaryID: $0.binaryID, imageSlot: $0.imageSlot, rowCount: UInt64($0.instructions.count),
                           controlFlowEdgeCount: UInt64($0.controlFlowEdges?.count ?? 0),
                           basicBlockCount: UInt64($0.basicBlocks?.count ?? 0)) }
    }
}
