import Foundation
import XCTest
@testable import MacScope

@MainActor
final class MCPInstructionReadBudgetTests: XCTestCase {
    private func snapshot(count: Int) -> WorkspaceSnapshot {
        WorkspaceSnapshot(binaries: [], functions: [
            FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000,
                            endAddress: 0x1000 + UInt64(count * 4), confidence: 1)
        ], instructions: (0..<count).map {
            InstructionRow(address: 0x1000 + UInt64($0 * 4), bytes: "1f 20 03 d5",
                           mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
        }, xrefs: [], hexBytes: Data())
    }

    func testInstructionSelectionCheckpointsBeforeMaterializingMatches() throws {
        let input = snapshot(count: 513)
        var checkpoints = 0
        let result = try WorkspaceScriptingAPI.snapshotListRead("instructions", arguments: .object([
            "address": .hex(0x1000 + 512 * 4), "count": .int(1)
        ]), snapshot: input, scope: .attached) { checkpoints += 1 }
        guard case .array(let rows) = result else { return XCTFail("expected rows") }
        XCTAssertEqual(rows.count, 1)
        XCTAssertGreaterThanOrEqual(checkpoints, 3, "selection must checkpoint nonmatching rows before materialization")
    }

    func testSelectionRefusesAtInjectedWorkBudgetBeforeFindingRow() throws {
        var checkpoints = 0
        XCTAssertThrowsError(try WorkspaceScriptingAPI.snapshotListRead("instructions", arguments: .object([
            "address": .hex(0x101c), "count": .int(1)
        ]), snapshot: snapshot(count: 8), scope: .attached, selectionWorkLimit: 2) { checkpoints += 1 })
        XCTAssertGreaterThan(checkpoints, 0)
    }

    func testInBudgetInstructionEncodingKeepsAnalysisOrderAndShape() throws {
        var input = snapshot(count: 3)
        input.instructions.swapAt(0, 2)
        let arguments = MCPAttachExecutor.boundedArguments("instructions", .object(["function": .string("f"), "count": .int(1)]))
        XCTAssertEqual(arguments["count"], .int(1), "bounding must not raise a caller's count")
        let actual = try WorkspaceScriptingAPI.snapshotListRead("instructions", arguments: arguments, snapshot: input, scope: .attached)
        let expected = ScriptValue.array(input.instructions.map { WorkspaceScriptingAPI.instructionObject($0, input) })
        XCTAssertEqual(try actual.jsonData(), try expected.jsonData())
        let inline = try WorkspaceScriptingAPI.snapshotListRead("instructions", arguments: .object(["function": .string("f"), "count": .int(1)]), snapshot: input)
        XCTAssertEqual(try inline.jsonData(), try expected.jsonData())
    }

    func testNullFunctionPreservesExactAddressCountJSON() throws {
        let arguments = try ScriptValue.decode(Data(#"{"function":null,"address":"0x1000","count":1}"#.utf8))
        let bounded = MCPAttachExecutor.boundedArguments("instructions", arguments)
        XCTAssertEqual(bounded["count"], .int(1))
        let actual = try WorkspaceScriptingAPI.snapshotListRead("instructions", arguments: bounded, snapshot: snapshot(count: 3), scope: .attached)
        XCTAssertEqual(String(decoding: try actual.jsonData(), as: UTF8.self),
                       #"[{"address":"0x1000","bytes":"1f 20 03 d5","mnemonic":"nop","operands":""}]"#)
    }

    func testNullFunctionPreservesExactZeroCountJSON() throws {
        let arguments = try ScriptValue.decode(Data(#"{"function":null,"address":"0x1000","count":0}"#.utf8))
        let bounded = MCPAttachExecutor.boundedArguments("instructions", arguments)
        XCTAssertEqual(bounded["count"], .int(0))
        let actual = try WorkspaceScriptingAPI.snapshotListRead("instructions", arguments: bounded, snapshot: snapshot(count: 3), scope: .attached)
        XCTAssertEqual(String(decoding: try actual.jsonData(), as: UTF8.self), "[]")
    }

    func testNamedFunctionRowsHaveFiniteAttachedBudget() throws {
        let input = snapshot(count: 2_001)
        let arguments = MCPAttachExecutor.boundedArguments("instructions", .object(["function": .string("f")]))
        let result = try WorkspaceScriptingAPI.snapshotListRead("instructions", arguments: arguments, snapshot: input, scope: .attached)
        guard case .array(let rows) = result else { return XCTFail("expected rows") }
        XCTAssertEqual(rows.count, 2_000, "named-function reads must cap selection before row allocation")
        XCTAssertEqual(rows.last?["address"], .hex(0x1000 + 1_999 * 4))
    }
}
