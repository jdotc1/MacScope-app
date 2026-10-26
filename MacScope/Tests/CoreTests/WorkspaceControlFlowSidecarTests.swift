import Foundation
import XCTest
@testable import MacScope

final class WorkspaceControlFlowSidecarTests: XCTestCase {
    private typealias Codec = WorkspaceInstructionSidecarCodec

    func testVersion2PreservesEveryFieldAndImageOwnership() throws {
        let edge = ControlFlowEdge(id: UUID(), from: UInt64.max, to: 0, kind: "custom λ\u{0}")
        let groups = [Codec.Group(binaryID: UUID(), imageSlot: .init(rawValue: 3), instructions: [], controlFlowEdges: [edge]),
                      Codec.Group(binaryID: UUID(), imageSlot: .init(rawValue: 9), instructions: [], controlFlowEdges: [])]
        let descriptors = groups.map { WorkspaceInstructionSidecarGroupDescriptor(
            binaryID: $0.binaryID, imageSlot: $0.imageSlot, rowCount: 0,
            controlFlowEdgeCount: UInt64($0.controlFlowEdges!.count)) }
        let bytes = try Codec.encode(groups)
        XCTAssertEqual(bytes[6], 2)
        let decoded = try Codec.decode(bytes, groups: descriptors)
        XCTAssertEqual(decoded[0].controlFlowEdges, [edge])
        XCTAssertEqual(decoded[1].controlFlowEdges, [])
        XCTAssertEqual(decoded.map(\.binaryID), groups.map(\.binaryID))
        XCTAssertEqual(decoded.map(\.imageSlot), groups.map(\.imageSlot))
        XCTAssertEqual(try Codec.encode(decoded), bytes)
    }

    func testVersion2RejectsTruncationTrailingBytesAndDescriptorMismatch() throws {
        let edge = ControlFlowEdge(id: UUID(), from: 1, to: 2, kind: "branch")
        let bytes = try Codec.encode([.init(binaryID: nil, imageSlot: nil, instructions: [], controlFlowEdges: [edge])])
        let descriptor = WorkspaceInstructionSidecarGroupDescriptor(binaryID: nil, imageSlot: nil, rowCount: 0, controlFlowEdgeCount: 1)
        for length in [0, 7, 12, 20, 28, bytes.count - 1] {
            XCTAssertThrowsError(try Codec.decode(Data(bytes.prefix(length)), groups: [descriptor]))
        }
        XCTAssertThrowsError(try Codec.decode(bytes + Data([0]), groups: [descriptor]))
        for count in [nil, 0, 2, UInt64.max] as [UInt64?] {
            var wrong = descriptor
            wrong.controlFlowEdgeCount = count
            XCTAssertThrowsError(try Codec.decode(bytes, groups: [wrong]))
        }
    }

    func testControlFlowInvalidUTF8AndOversizedDeclaredCountFailBoundedly() throws {
        let edge = ControlFlowEdge(id: UUID(), from: 1, to: 2, kind: "x")
        var bytes = try Codec.encode([.init(binaryID: nil, imageSlot: nil, instructions: [], controlFlowEdges: [edge])])
        let descriptor = WorkspaceInstructionSidecarGroupDescriptor(binaryID: nil, imageSlot: nil, rowCount: 0, controlFlowEdgeCount: 1)
        bytes[bytes.count - 1] = 0xff
        XCTAssertThrowsError(try Codec.decode(bytes, groups: [descriptor]))
        var oversizedKind = bytes
        var declared = UInt32(Codec.maximumControlFlowBytes + 1).littleEndian
        withUnsafeBytes(of: &declared) { oversizedKind.replaceSubrange(61..<65, with: $0) }
        XCTAssertThrowsError(try Codec.decode(oversizedKind, groups: [descriptor])) { error in
            XCTAssertEqual(error as? Codec.Failure, .exceedsMaximumSize)
        }
        var excessive = bytes
        // v2 header12 + legacy owner1 + instruction count8 = edge count offset21.
        for index in 21..<29 { excessive[index] = 0xff }
        var huge = descriptor
        huge.controlFlowEdgeCount = UInt64.max
        XCTAssertThrowsError(try Codec.decode(excessive, groups: [huge]))
    }

    /// One new edge-only sample; intentionally excludes the already-measured T1 instruction workload.
    func testVimScaleControlFlowSingleBeforeAfterSample() throws {
        let rows = (0..<238_608).map { index in
            ControlFlowEdge(id: UUID(), from: 0x1000 + UInt64(index) * 4,
                            to: 0x1004 + UInt64(index) * 4,
                            kind: index % 3 == 0 ? "conditional" : "fallthrough")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let before = ContinuousClock.now
        let json = try encoder.encode(rows)
        let encodedJSON = ContinuousClock.now
        let jsonRows = try JSONDecoder().decode([ControlFlowEdge].self, from: json)
        let decodedJSON = ContinuousClock.now
        XCTAssertEqual(jsonRows, rows)
        let group = Codec.Group(binaryID: nil, imageSlot: nil, instructions: [], controlFlowEdges: rows)
        let descriptor = WorkspaceInstructionSidecarGroupDescriptor(binaryID: nil, imageSlot: nil, rowCount: 0,
                                                                     controlFlowEdgeCount: UInt64(rows.count))
        let binaryStart = ContinuousClock.now
        let binary = try Codec.encode([group])
        let encodedBinary = ContinuousClock.now
        let decoded = try Codec.decode(binary, groups: [descriptor])
        let decodedBinary = ContinuousClock.now
        XCTAssertEqual(decoded[0].controlFlowEdges, rows)
        XCTAssertLessThan(binary.count, json.count)
        print("T11_EDGE_SAMPLE rows=\(rows.count) jsonEncode=\(before.duration(to: encodedJSON)) jsonDecode=\(encodedJSON.duration(to: decodedJSON)) binaryEncode=\(binaryStart.duration(to: encodedBinary)) binaryDecode=\(encodedBinary.duration(to: decodedBinary)) jsonBytes=\(json.count) binaryBytes=\(binary.count)")
    }
}
