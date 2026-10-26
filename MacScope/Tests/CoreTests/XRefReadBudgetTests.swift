import Foundation
import XCTest
@testable import MacScope

@MainActor
final class XRefReadBudgetTests: XCTestCase {
    private func snapshot(_ refs: [XRef], edits: [ManualXRef] = []) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], functions: [], instructions: [],
                                         xrefs: refs, hexBytes: Data())
        snapshot.manualXRefs = edits
        return snapshot
    }

    private func ref(_ from: UInt64, to: UInt64 = 0x2000) -> XRef {
        XRef(id: UUID(), from: from, to: to, kind: XRefKind.call)
    }

    func testRequestedPrefixStopsBeforeRemainingRecoveredRows() throws {
        let input = snapshot([ref(1), ref(2), ref(3)])
        let rows = try WorkspaceScriptingAPI.snapshotListRead("xrefs", arguments: .object([
            "to": .hex(0x2000), "limit": .int(1),
        ]), snapshot: input, scope: .attached, selectionWorkLimit: 1)
        XCTAssertEqual(rows.arrayValue?.count, 1)
        XCTAssertEqual(rows.arrayValue?.first?["from"], .hex(1))
    }

    func testZeroLimitDoesNotScanRecoveredOrManualRows() throws {
        let input = snapshot([ref(1)], edits: [
            ManualXRef(from: 2, to: 0x2000, kind: XRefKind.call, isSuppression: false),
        ])
        let rows = try WorkspaceScriptingAPI.snapshotXRefRead(.object([
            "to": .hex(0x2000), "limit": .int(0),
        ]), snapshot: input, selectionWorkLimit: 0)
        XCTAssertEqual(rows, .array([]))
    }

    func testSparseRecoveredSelectionRefusesAtWorkBudget() throws {
        let input = snapshot([ref(1, to: 1), ref(2, to: 2), ref(3)])
        XCTAssertThrowsError(try WorkspaceScriptingAPI.snapshotListRead("xrefs", arguments: .object([
            "to": .hex(0x2000), "limit": .int(1),
        ]), snapshot: input, scope: .attached, selectionWorkLimit: 2)) { error in
            XCTAssertEqual(error as? ScriptingError,
                           .invalidArgument("xrefs exceeds the snapshot work budget"))
        }
    }

    func testManualEditScanSharesWorkBudgetWithRecoveredRows() throws {
        let input = snapshot([ref(1)], edits: [
            ManualXRef(from: 7, to: 8, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 9, to: 10, kind: XRefKind.call, isSuppression: true),
        ])
        XCTAssertThrowsError(try WorkspaceScriptingAPI.snapshotXRefRead(.object([
            "to": .hex(0x2000), "limit": .int(1),
        ]), snapshot: input, selectionWorkLimit: 2)) { error in
            XCTAssertEqual(error as? ScriptingError,
                           .invalidArgument("xrefs exceeds the snapshot work budget"))
        }
    }

    func testResultBudgetRefusesInsteadOfReturningImplicitPartialList() throws {
        let input = snapshot([ref(1), ref(2), ref(3)])
        XCTAssertThrowsError(try WorkspaceScriptingAPI.snapshotXRefRead(.object([
            "to": .hex(0x2000),
        ]), snapshot: input, resultLimit: 2)) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument(
                "xrefs exceeds the snapshot result budget; request a smaller limit"))
        }
        let boundary = try WorkspaceScriptingAPI.snapshotXRefRead(.object([
            "to": .hex(0x2000), "limit": .int(2),
        ]), snapshot: input, resultLimit: 2)
        XCTAssertEqual(boundary.arrayValue?.count, 2)
    }

    func testOversizedRequestedLimitIsRefusedBeforeScan() throws {
        XCTAssertThrowsError(try WorkspaceScriptingAPI.snapshotXRefRead(.object([
            "to": .hex(0x2000), "limit": .int(3),
        ]), snapshot: snapshot([]), selectionWorkLimit: 0, resultLimit: 2)) { error in
            XCTAssertEqual(error as? ScriptingError, .invalidArgument(
                "xrefs exceeds the snapshot result budget; request a smaller limit"))
        }
    }

    func testInBudgetQueryPreservesRecoveredDuplicatesAndManualEditSemantics() throws {
        let first = ref(1)
        let duplicate = ref(1)
        let suppressed = ref(2)
        let input = snapshot([first, duplicate, suppressed, ref(9, to: 9)], edits: [
            ManualXRef(from: 1, to: 0x2000, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 3, to: 0x2000, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 3, to: 0x2000, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 2, to: 0x2000, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 2, to: 0x2000, kind: XRefKind.call, isSuppression: true),
            ManualXRef(from: 1, to: 0x2000, kind: XRefKind.call, isSuppression: true,
                       imageSlot: ImageSlot(rawValue: 1)),
            ManualXRef(from: 4, to: 0x2000, kind: XRefKind.call, isSuppression: false,
                       imageSlot: ImageSlot(rawValue: 1)),
        ])
        let actual = try input.boundedEffectiveXRefs(.to(0x2000), limit: nil,
            maximumRows: 4, maximumWork: 20, checkpoint: {})
        XCTAssertEqual(actual, input.effectiveXRefs(to: 0x2000))
        XCTAssertEqual(actual.map(\.from), [1, 1, 3])
        let from = try input.boundedEffectiveXRefs(.from(1), limit: nil,
            maximumRows: 3, maximumWork: 20, checkpoint: {})
        XCTAssertEqual(from, input.effectiveXRefs(from: 1))
    }

    func testLateSuppressionIsAppliedBeforeReturningRequestedPrefix() throws {
        let input = snapshot([ref(1), ref(2)], edits: [
            ManualXRef(from: 4, to: 5, kind: XRefKind.call, isSuppression: false),
            ManualXRef(from: 1, to: 0x2000, kind: XRefKind.call, isSuppression: true),
        ])
        let result = try input.boundedEffectiveXRefs(.to(0x2000), limit: 1,
            maximumRows: 1, maximumWork: 4, checkpoint: {})
        XCTAssertEqual(result.map(\.from), [2])
    }

    func testCancellationDuringSparseSelectionPublishesNoRows() throws {
        let input = snapshot((0..<300).map { ref(UInt64($0), to: 1) })
        var checkpoints = 0
        XCTAssertThrowsError(try WorkspaceScriptingAPI.snapshotXRefRead(.object([
            "to": .hex(0x2000), "limit": .int(1),
        ]), snapshot: input) {
            checkpoints += 1
            if checkpoints == 3 { throw CancellationError() }
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checkpoints, 3)
    }

    func testAttachPreservesExplicitLimitAndDoesNotInventImplicitPrefix() throws {
        let arguments = ScriptValue.object(["to": .hex(0x2000), "limit": .int(1)])
        XCTAssertEqual(MCPAttachExecutor.boundedArguments("xrefs", arguments), arguments)
        let unlimited = ScriptValue.object(["to": .hex(0x2000)])
        XCTAssertEqual(MCPAttachExecutor.boundedArguments("xrefs", unlimited), unlimited)
        XCTAssertTrue(WorkspaceScriptingAPI.snapshotListCommands.contains("xrefs"))
        let command = try XCTUnwrap(WorkspaceScriptingAPI.availableCommands.first { $0.name == "xrefs" })
        XCTAssertTrue(command.arguments.contains("limit"))
    }

    func testInlineAndAttachedReadsPreserveValidJSONAndHonorLimit() async throws {
        let input = snapshot([ref(1), ref(2), ref(3)])
        let store = WorkspaceStore(workspaceName: "Xref budget", snapshot: input,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let api = WorkspaceScriptingAPI(store: store)
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        let arguments = ScriptValue.object(["to": .hex(0x2000), "limit": .int(1)])
        let inline = try api.execute("xrefs", arguments: arguments)
        let attached = try await executor.execute("xrefs", arguments)
        XCTAssertEqual(inline.arrayValue?.count, 1)
        XCTAssertEqual(try attached.jsonData(), try inline.jsonData())
        let complete = try api.execute("xrefs", arguments: .object(["to": .hex(0x2000)]))
        // DEF-A04: every row names the image that produced it (a binary-less snapshot reads slot 0).
        let expected = ScriptValue.array(input.effectiveXRefs(to: 0x2000).map {
            .object([
                "from": .hex($0.from), "to": .hex($0.to), "kind": .string($0.kind),
                "imageSlot": .int(Int64(input.primarySlot.rawValue)),
            ])
        })
        XCTAssertEqual(try complete.jsonData(), try expected.jsonData())
    }
}
