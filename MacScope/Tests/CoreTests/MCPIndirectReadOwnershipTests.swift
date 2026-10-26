import Foundation
import XCTest
@testable import MacScope

@MainActor
final class MCPIndirectReadOwnershipTests: XCTestCase {
    func testColdAnalysisAllowsSentinelAndRevocationBeforeRelease() async throws {
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [
            FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000, endAddress: 0x1004, confidence: 1)
        ], instructions: [InstructionRow(address: 0x1000, bytes: "c0 03 5f d6", mnemonic: "ret",
                                         operands: "", hasBreakpoint: false, comment: nil)], xrefs: [], hexBytes: Data())
        let store = WorkspaceStore(workspaceName: "B9", snapshot: snapshot, engine: AnalysisEngine())
        let ownedSnapshot = store.snapshot
        let gate = IndirectReadCheckpoint()
        let executor = MCPAttachExecutor(store: store, api: {
            WorkspaceScriptingAPI(store: $0, snapshotReadCheckpoint: { gate.park() })
        })
        executor.setConsent(.allowed)
        let read = Task { try await executor.execute("indirect-call-targets", .object(["function": .string("f")])) }
        let parked = await Task.detached { gate.awaitParked() }.value
        defer { gate.release() }
        guard parked else {
            read.cancel()
            _ = try? await read.value
            return XCTFail("cold indirect analysis never reached its owned worker checkpoint")
        }
        // Reaching this actor-isolated continuation while the cold memo owns its build is
        // the sentinel. The nonblocking read must still use try(), never wait for that build.
        XCTAssertNil(ownedSnapshot.imageWideIndirectCalls(in: .primary, compute: false))
        executor.setConsent(.revoked)
        gate.release()
        do { _ = try await read.value; XCTFail("revoked analysis released a result") } catch {}
        XCTAssertTrue(gate.cancelled)
        XCTAssertNil(ownedSnapshot.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertNil(ownedSnapshot.imageWideIndirectCalls(in: .primary, compute: true), "cancelled cold build stays attempted")
    }

    func testInBudgetIndirectEncodingMatchesLegacyReport() async throws {
        let baseline = IndirectTargetResolutionTests.typedSnapshot()
        let expected = WorkspaceScriptingAPI.indirectCallTargets(snapshot: baseline, function: baseline.functions[1])
        let snapshot = IndirectTargetResolutionTests.typedSnapshot()
        let store = WorkspaceStore(workspaceName: "B9", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        let actual = try await executor.execute("indirect-call-targets", .object(["function": .string("_dispatch")]))
        XCTAssertEqual(try actual.jsonData(), try expected.jsonData())
    }

    func testInterruptedColdMemoMarksAttemptAndDoesNotRetry() {
        let snapshot = IndirectTargetResolutionTests.typedSnapshot()
        var checkpoints = 0
        var phases: [IndirectCallResolutionMemo.CheckpointPhase?] = []
        let report = snapshot.imageWideIndirectCalls(in: .primary, compute: true, checkpoint: {
            checkpoints += 1
            phases.append(IndirectCallResolutionMemo.checkpointPhase)
            return false
        })
        XCTAssertNil(report)
        XCTAssertEqual(checkpoints, 1)
        XCTAssertEqual(phases, [.typedPrototypePrerequisite])
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true), "interrupted attempt stays attempted for this identity")
    }

    func testAlreadyCancelledColdRequestMarksAttemptBeforePrerequisites() async {
        let snapshot = IndirectTargetResolutionTests.typedSnapshot()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        }
        let report = await task.value
        XCTAssertNil(report)
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true, checkpoint: {
            XCTFail("an already-cancelled cold request must not retry its prerequisites")
            return true
        }))
    }

    func testPrerequisiteInstructionRefusalDoesNotRetry() {
        let snapshot = IndirectTargetResolutionTests.typedSnapshot()
        var admissions = 0
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true, admitInstructions: { _ in
            admissions += 1
            return false
        }))
        XCTAssertEqual(admissions, 1)
        XCTAssertNil(snapshot.slotTypedPrototypeReport(in: .primary, compute: false))
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true, checkpoint: {
            XCTFail("a refused prerequisite must not retry any phase of the cold request")
            return true
        }, admitInstructions: { _ in
            XCTFail("a refused prerequisite must not admit instructions again")
            return true
        }))
    }

    func testPrerequisiteCheckpointDoesNotHoldIndirectMemoLock() {
        let snapshot = IndirectTargetResolutionTests.typedSnapshot()
        var inspectedClaim = false
        let report = snapshot.imageWideIndirectCalls(in: .primary, compute: true, checkpoint: {
            if !inspectedClaim,
               IndirectCallResolutionMemo.checkpointPhase == .typedPrototypePrerequisite {
                inspectedClaim = true
                XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true, checkpoint: {
                    XCTFail("a claimed request must not start a second build")
                    return true
                }))
            }
            return true
        })
        XCTAssertTrue(inspectedClaim)
        XCTAssertNotNil(report)
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
    }

    func testBusyPrerequisiteDoesNotRefuseIndirectResolution() throws {
        let baseline = IndirectTargetResolutionTests.typedSnapshot()
        let expected = try XCTUnwrap(baseline.imageWideIndirectCalls(in: .primary, compute: true))
        let snapshot = IndirectTargetResolutionTests.typedSnapshot()
        var requestedIndirect = false
        var indirectReport: MacIRIndirectTargetResolution.Report?
        let typedReport = snapshot.slotTypedPrototypeReport(in: .primary, compute: true, checkpoint: {
            if !requestedIndirect {
                requestedIndirect = true
                // The typed-only build owns its memo lock here. That prerequisite is
                // unavailable to this request, but it has not refused or been cancelled.
                indirectReport = snapshot.imageWideIndirectCalls(in: .primary, compute: true)
            }
            return true
        })
        XCTAssertTrue(requestedIndirect)
        XCTAssertNotNil(typedReport)
        let actual = try XCTUnwrap(indirectReport)
        XCTAssertEqual(actual.resolutions, expected.resolutions)
        XCTAssertEqual(actual.refusals, expected.refusals)
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
    }

    func testPreviouslyInterruptedPrerequisiteDoesNotStartIndirectResolution() {
        let snapshot = IndirectTargetResolutionTests.typedSnapshot()
        XCTAssertNil(snapshot.slotTypedPrototypeReport(in: .primary, compute: true, checkpoint: { false }))
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true, checkpoint: {
            XCTFail("an interrupted prerequisite must not enter indirect resolution")
            return true
        }, admitInstructions: { _ in
            XCTFail("an interrupted prerequisite must not admit more instructions")
            return true
        }))
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
    }

    func testFunctionInstructionBudgetRefusesBeforeLift() throws {
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [
            FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000, endAddress: 0x1000 + 2_049 * 4, confidence: 1)
        ], instructions: (0..<2_049).map {
            InstructionRow(address: 0x1000 + UInt64($0 * 4), bytes: "1f 20 03 d5", mnemonic: "nop",
                           operands: "", hasBreakpoint: false, comment: nil)
        }, xrefs: [], hexBytes: Data())
        XCTAssertThrowsError(try WorkspaceScriptingAPI.boundedIndirectCallTargets(
            arguments: .object(["function": .string("f")]), snapshot: snapshot, checkpoint: {}))
        XCTAssertNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
    }

}

private final class IndirectReadCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let parked = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var didPark = false
    private var sawCancellation = false
    var cancelled: Bool { lock.withLock { sawCancellation } }
    func park() {
        guard IndirectCallResolutionMemo.checkpointPhase == .typedPrototypePrerequisite else { return }
        let first = lock.withLock {
            guard !didPark else { return false }
            didPark = true
            return true
        }
        guard first else { return }
        parked.signal()
        // Timeout is only a broken-test failsafe, never a latency assertion.
        _ = resume.wait(timeout: .now() + 5)
        lock.withLock { sawCancellation = Task.isCancelled }
    }
    func awaitParked() -> Bool { parked.wait(timeout: .now() + 2) == .success }
    func release() { resume.signal() }
}
