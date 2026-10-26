import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceRecoveryCoordinatorTests: XCTestCase {
    func testUnavailableOriginalPausesAndPreservesPendingWorkWithoutExecutionReceipts() async throws {
        let fixture = try RecoveryCoordinatorFixture(failure: .unavailable("Exact original bytes unavailable"))
        await fixture.coordinator.start(jobID: fixture.snapshot.jobID)
        let reasons = await fixture.planner.controlReasons
        let state = await fixture.persistence.current
        let plans = await fixture.persistence.plans
        let publications = await fixture.publisher.receipts
        XCTAssertEqual(reasons, [.evidenceStalled])
        XCTAssertEqual(state.currentDurableJobState, .paused)
        XCTAssertEqual(state.pauseContext?.cause, .evidenceStalled)
        XCTAssertEqual(state.pauseContext?.resumeTarget, .retrieving)
        XCTAssertEqual(state.tasks, fixture.snapshot.tasks)
        XCTAssertEqual(state.terminalReceiptStatesByTaskID, [:])
        XCTAssertEqual(state.evidenceFrontierSHA256, fixture.snapshot.evidenceFrontierSHA256)
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans.first?.acceptedEvidenceCount, 0)
        XCTAssertNil(plans.first?.mutation)
        XCTAssertEqual(publications.map(\.disposition), [.paused(.evidenceStalled)])
    }

    func testAuthorityMismatchAndOwnedRetirementFailWithoutExecutingPendingWork() async throws {
        for failure in [ReconstructionSourceOriginalRecoveryFailure.authorityMismatch, .retired] {
            let fixture = try RecoveryCoordinatorFixture(failure: failure)
            await fixture.coordinator.start(jobID: fixture.snapshot.jobID)
            let reasons = await fixture.planner.controlReasons
            let state = await fixture.persistence.current
            let plans = await fixture.persistence.plans
            XCTAssertEqual(reasons, [.failed])
            XCTAssertEqual(state.currentDurableJobState, .failed)
            XCTAssertEqual(state.tasks, fixture.snapshot.tasks)
            XCTAssertEqual(state.terminalReceiptStatesByTaskID, [:])
            XCTAssertEqual(plans.count, 1)
            XCTAssertEqual(plans.first?.acceptedEvidenceCount, 0)
            XCTAssertNil(plans.first?.mutation)
        }
    }

    func testRecoveryCancellationRetainsExistingTerminalCancellationPath() async throws {
        let fixture = try RecoveryCoordinatorFixture(failure: .retired, cancellationError: true)
        await fixture.coordinator.start(jobID: fixture.snapshot.jobID)
        let reasons = await fixture.planner.controlReasons
        let state = await fixture.persistence.current
        XCTAssertEqual(reasons, [.cancelled])
        XCTAssertEqual(state.currentDurableJobState, .cancelled)
        XCTAssertEqual(state.tasks, fixture.snapshot.tasks)
        XCTAssertEqual(state.terminalReceiptStatesByTaskID, [:])
    }

    func testLateRecoveryFailureAfterTransientRetirementCannotOwnControlCommit() async throws {
        let fixture = try RecoveryCoordinatorFixture(failure: .retired, held: true)
        let running = Task { await fixture.coordinator.start(jobID: fixture.snapshot.jobID) }
        await fixture.planner.waitUntilEntered()
        await fixture.coordinator.suspendWithoutDurableDisposition(jobID: fixture.snapshot.jobID)
        await running.value
        let reasons = await fixture.planner.controlReasons
        let state = await fixture.persistence.current
        let plans = await fixture.persistence.plans
        let receipts = await fixture.publisher.receipts
        XCTAssertTrue(reasons.isEmpty)
        XCTAssertTrue(plans.isEmpty)
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertEqual(state, fixture.snapshot)
    }

    func testQueuedUserCancelAndPauseTakePriorityOverUnavailableRecovery() async throws {
        for reason in [ReconstructionJobPauseReason.cancelled, .pausedByUser] {
            let fixture = try RecoveryCoordinatorFixture(failure: .unavailable("Tooling unavailable"), held: true)
            let running = Task { await fixture.coordinator.start(jobID: fixture.snapshot.jobID) }
            await fixture.planner.waitUntilEntered()
            if reason == .cancelled {
                await fixture.coordinator.cancel(jobID: fixture.snapshot.jobID)
            } else {
                await fixture.coordinator.pause(jobID: fixture.snapshot.jobID)
            }
            await running.value
            let reasons = await fixture.planner.controlReasons
            let plans = await fixture.persistence.plans
            let state = await fixture.persistence.current
            XCTAssertEqual(reasons, [reason])
            XCTAssertEqual(plans.map(\.disposition), [reason.controlDisposition])
            XCTAssertEqual(state.tasks, fixture.snapshot.tasks)
            XCTAssertEqual(state.terminalReceiptStatesByTaskID, [:])
        }
    }
}

private struct RecoveryCoordinatorFixture: Sendable {
    let snapshot: ReconstructionJobOrchestrationSnapshot
    let planner: RecoveryFailurePlanner
    let persistence: RecoveryControlPersistence
    let publisher: RecoveryControlPublisher
    let coordinator: ReconstructionJobCoordinator

    init(failure: ReconstructionSourceOriginalRecoveryFailure, held: Bool = false,
         cancellationError: Bool = false) throws {
        let jobID = UUID()
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256, digest: String(repeating: "3", count: 64), byteCount: 64))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: UUID(), imageSlot: .primary, selectedSliceIndex: nil,
                         architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: String(repeating: "4", count: 64), startAddress: 0x1000,
            endAddressExclusive: 0x1010, boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let pending = ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
            taskID: UUID(), jobID: jobID, kind: .executeSource, subject: .function(function),
            dependencyTaskIDs: [], operationContractIdentity: ReconstructionSourceExecutionTaskContract.oracle),
            state: .pending, diagnostic: nil)
        snapshot = .init(jobID: jobID, jobCreationOrder: 1, checkpointID: UUID(), checkpointRevision: 0,
            checkpointCorpusManifestSHA256: String(repeating: "1", count: 64),
            checkpointEvidenceFrontierSHA256: String(repeating: "2", count: 64),
            currentCorpusManifestSHA256: String(repeating: "1", count: 64),
            evidenceFrontierSHA256: String(repeating: "2", count: 64),
            currentDurableJobState: .retrieving, pauseContext: nil, maximumRoundsWithoutEvidence: 3,
            tasks: [pending], terminalReceiptStatesByTaskID: [:])
        planner = .init(failure: failure, held: held, cancellationError: cancellationError)
        persistence = .init(snapshot: snapshot)
        publisher = .init()
        coordinator = .init(persistence: persistence, planner: planner, publisher: publisher)
    }
}

private actor RecoveryFailurePlanner: ReconstructionJobRoundPlanning {
    let failure: ReconstructionSourceOriginalRecoveryFailure
    let held: Bool
    let cancellationError: Bool
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private(set) var controlReasons: [ReconstructionJobPauseReason] = []
    init(failure: ReconstructionSourceOriginalRecoveryFailure, held: Bool, cancellationError: Bool) {
        self.failure = failure; self.held = held; self.cancellationError = cancellationError
    }
    func planRound(from snapshot: ReconstructionJobOrchestrationSnapshot) async throws -> ReconstructionJobCommitPlan {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        if held { await withCheckedContinuation { release = $0 } }
        if cancellationError { throw CancellationError() }
        throw failure
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func planRecovery(from snapshot: ReconstructionJobOrchestrationSnapshot,
                      transitions: [ReconstructionTaskTransition]) async throws -> ReconstructionJobCommitPlan {
        throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
    }
    func planControl(from snapshot: ReconstructionJobOrchestrationSnapshot,
                     reason: ReconstructionJobPauseReason) async throws -> ReconstructionJobCommitPlan {
        controlReasons.append(reason)
        return .init(successorRevision: snapshot.checkpointRevision + 1, acceptedEvidenceCount: 0,
            disposition: reason.controlDisposition, mutation: nil)
    }
    func cancel(jobID: UUID) async { release?.resume(); release = nil }
}

private actor RecoveryControlPersistence: ReconstructionJobOrchestrationPersisting {
    private(set) var current: ReconstructionJobOrchestrationSnapshot
    private(set) var plans: [ReconstructionJobCommitPlan] = []
    init(snapshot: ReconstructionJobOrchestrationSnapshot) { current = snapshot }
    func load(jobID: UUID) async throws -> ReconstructionJobOrchestrationSnapshot { current }
    func commit(_ plan: ReconstructionJobCommitPlan, for snapshot: ReconstructionJobOrchestrationSnapshot)
        async throws -> ReconstructionJobCommitReceipt {
        plans.append(plan)
        current = try current.advancing(to: plan.successorRevision, disposition: plan.disposition)
        return .init(jobID: snapshot.jobID, checkpointRevision: current.checkpointRevision,
            evidenceFrontierSHA256: current.evidenceFrontierSHA256, disposition: plan.disposition)
    }
}

private actor RecoveryControlPublisher: ReconstructionJobStatusPublishing {
    private(set) var receipts: [ReconstructionJobCommitReceipt] = []
    func publish(_ receipt: ReconstructionJobCommitReceipt) async { receipts.append(receipt) }
}
