import CryptoKit
import Foundation
import XCTest

@testable import MacScope

/// RX-04: BinExport2 interoperability that runs in CI without protoc. The product-side
/// `BinExport2Conformance` checks exported bytes against the vendored upstream schema
/// (`ThirdParty/BinExport/binexport2.proto`, google/binexport blob 7e1dc3b3) and the
/// requirements BinDiff enforces beyond proto2 defaults.
final class BinExport2InteropTests: XCTestCase {
    // MARK: - Schema pin

    private static var repositoryRoot: URL {
        TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent() // CoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MacScope
            .deletingLastPathComponent() // repository
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testGeneratedSchemaTableMatchesVendoredUpstreamProto() throws {
        let vendored = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent("ThirdParty/BinExport/binexport2.proto"))
        XCTAssertEqual(Self.sha256(vendored), BinExport2Schema.sourceSHA256,
                       "Regenerate with Scripts/dependencies/generate_binexport2_schema.py")
        // The protoc oracle tests decode against the bundled copy; it must be the upstream bytes.
        let bundled = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "binexport2", withExtension: "proto"))
        XCTAssertEqual(try Data(contentsOf: bundled), vendored)
        // Spot-check upstream proto2 names the hand-cut subset lacked.
        XCTAssertEqual(BinExport2Schema.messages["BinExport2"]?[1]?.name, "meta_information")
        XCTAssertEqual(BinExport2Schema.messages["BinExport2.BasicBlock"]?[1]?.repeated, true)
        XCTAssertEqual(BinExport2Schema.messages["BinExport2.FlowGraph"]?[3]?.name, "entry_basic_block_index")
        XCTAssertEqual(BinExport2Schema.messages["BinExport2.Expression"]?[4]?.name, "parent_index")
    }

    // MARK: - Exporter output conforms

    private func roundTripSnapshot() -> WorkspaceSnapshot {
        let f1 = FunctionSummary(id: UUID(), name: "func1", startAddress: 0x1000, endAddress: 0x100c, confidence: 1)
        let f2 = FunctionSummary(id: UUID(), name: "func2", startAddress: 0x2000, endAddress: 0x2008, confidence: 1)
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "01 00 00 58", mnemonic: "ldr", operands: "x0, [x1, #8]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "20 00 80 D2", mnemonic: "mov", operands: "x0, #1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 80 D2", mnemonic: "add", operands: "x1, x2, x3, lsl #2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2000, bytes: "00 00 80 D2", mnemonic: "mov", operands: "x0, #0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2004, bytes: "C0 03 5F D6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        return WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "interop", path: "/interop", kind: "Mach-O", architecture: "aarch64")],
            functions: [f1, f2],
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            basicBlocks: [
                BasicBlockSummary(id: UUID(), functionID: f1.id, startAddress: 0x1000, endAddress: 0x1004, instructionCount: 1),
                BasicBlockSummary(id: UUID(), functionID: f1.id, startAddress: 0x1004, endAddress: 0x100c, instructionCount: 2),
                BasicBlockSummary(id: UUID(), functionID: f2.id, startAddress: 0x2000, endAddress: 0x2008, instructionCount: 2),
            ],
            instructions: rows,
            xrefs: [XRef(id: UUID(), from: 0x1004, to: 0x2000, kind: XRefKind.call)],
            controlFlowEdges: [ControlFlowEdge(id: UUID(), from: 0x1000, to: 0x1004, kind: "fallthrough")],
            hexBytes: Data()
        )
    }

    /// Entry block 0 is the case the zero-omitting writer dropped; BinDiff rejects a flow
    /// graph without `entry_basic_block_index`.
    func testExportConformsIncludingEntryBlockZero() throws {
        let data = try BinExport2Exporter().exportForBinDiff(roundTripSnapshot())
        XCTAssertEqual(BinExport2Conformance.validate(data), [])
    }

    func testExportedCallGraphFixturesConform() {
        let f = FunctionSummary(id: UUID(), name: "zero", startAddress: 0, endAddress: 4, confidence: 1)
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "zero", path: "/zero", kind: "Mach-O", architecture: "arm64")],
            functions: [f], symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            basicBlocks: [BasicBlockSummary(id: UUID(), functionID: f.id, startAddress: 0, endAddress: 4, instructionCount: 1)],
            instructions: [InstructionRow(address: 0, bytes: "C0 03 5F D6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)],
            xrefs: [], controlFlowEdges: [], hexBytes: Data())
        // Address 0 must still be written explicitly for the entry instruction and the vertex.
        XCTAssertEqual(BinExport2Conformance.validate(BinExport2Exporter().export(snapshot)), [])
    }

    func testFunctionWithoutEntryBlockGetsNoFlowGraph() throws {
        var snapshot = roundTripSnapshot()
        // func2's only block no longer starts at the function start.
        snapshot.functions[1] = FunctionSummary(id: snapshot.functions[1].id, name: "func2",
                                                startAddress: 0x1ffc, endAddress: 0x2008, confidence: 1)
        let data = try BinExport2Exporter().exportForBinDiff(snapshot)
        XCTAssertEqual(BinExport2Conformance.validate(data), [])
    }

    // MARK: - Each BinDiff requirement is detected

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }
    private func field(_ number: Int, _ value: UInt64) -> [UInt8] { varint(UInt64(number << 3)) + varint(value) }
    private func message(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(payload.count)) + payload
    }
    private func rules(_ bytes: [UInt8]) -> Set<BinExport2Conformance.Rule> {
        Set(BinExport2Conformance.validate(Data(bytes)).map(\.rule))
    }

    private var instructions: [UInt8] {
        message(5, field(1, 0x1000) + message(5, [0, 0, 0, 0])) + message(5, message(5, [0, 0, 0, 0]))
    }
    private var oneBlock: [UInt8] { message(6, message(1, field(1, 0) + field(2, 2))) }

    func testMinimalConformingMessage() {
        XCTAssertEqual(rules(instructions + oneBlock + message(7, field(1, 0) + field(3, 0))
                             + message(8, message(1, field(1, 0x1000)))), [])
    }

    func testMissingEntryBasicBlockIndex() {
        XCTAssertEqual(rules(instructions + oneBlock + message(7, field(1, 0))), [.entryBasicBlockIndex])
    }

    func testEntryInstructionWithoutExplicitAddress() {
        // Block starts at instruction 1, whose address is only implied.
        let block = message(6, message(1, field(1, 1) + field(2, 2)))
        XCTAssertEqual(rules(instructions + block + message(7, field(1, 0) + field(3, 0))), [.functionEntryAddress])
    }

    func testEmptyBasicBlock() {
        let empty = message(6, message(1, field(1, 1) + field(2, 1)))
        XCTAssertTrue(rules(instructions + empty).contains(.emptyBasicBlock))
        XCTAssertTrue(rules(instructions + message(6, [])).contains(.emptyBasicBlock))
    }

    func testUnsortedBasicBlocksAndVertices() {
        let blocks = message(6, message(1, field(1, 0) + field(2, 1))) + message(6, message(1, field(1, 1) + field(2, 2)))
        XCTAssertTrue(rules(instructions + blocks + message(7, field(1, 1) + field(1, 0) + field(3, 0))).contains(.basicBlockOrder))
        let vertices = message(8, message(1, field(1, 0x2000)) + message(1, field(1, 0x1000)))
        XCTAssertEqual(rules(vertices), [.callGraphVertexOrder])
        XCTAssertEqual(rules(message(8, message(1, field(2, 2)))), [.callGraphVertexAddress])
    }

    func testNonRootExpressionWithoutParentIndex() {
        let expressions = message(2, field(1, 7)) + message(2, field(1, 5) + message(2, Array("x1".utf8)))
        XCTAssertEqual(rules(expressions + message(3, field(1, 0) + field(1, 1))), [.parentIndex])
        let linked = message(2, field(1, 7)) + message(2, field(1, 5) + field(4, 0))
        XCTAssertEqual(rules(linked + message(3, field(1, 0) + field(1, 1))), [])
    }

    func testFieldsOutsideTheUpstreamSchemaAndWireTypeMismatches() {
        XCTAssertEqual(rules(field(99, 1)), [.unknownField])
        // call_graph (8) is a message; a varint there contradicts the schema.
        XCTAssertEqual(rules(field(8, 1)), [.wireType])
        XCTAssertThrowsError(try BinExport2Conformance.requireConformance(Data(field(99, 1))))
    }
}
