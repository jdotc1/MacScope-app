import Foundation
import XCTest
@testable import MacScope

@MainActor
final class Phase2AssistantShellContinuationOrchestratorTests: XCTestCase {
    func testPersistsReservationsBeforeExecutionAndDispatch() async throws {
        let fixture = try Fixture()
        let log = Log()
        let checkpoint = Checkpoint(log: log)
        let executor = Executor(log: log, envelope: fixture.envelope)
        let dispatcher = Dispatcher(log: log, result: .completed(fixture.outcome))

        let result = await Phase2AssistantShellContinuationOrchestrator()
            .executeApprovedAndContinue(
                machine: fixture.machine,
                proposal: fixture.command,
                approval: fixture.approval,
                checkpoint: checkpoint,
                executor: executor,
                dispatcher: dispatcher
            )

        XCTAssertEqual(result.machine.state, .completed)
        XCTAssertNil(result.failure)
        XCTAssertEqual(
            log.events,
            [
                "persist:executingShell",
                "execute:\(fixture.executionID.uuidString)",
                "persist:awaitingShellContinuation",
                "persist:continuingShell",
                "dispatch:\(fixture.coordinate.continuationRequestID.uuidString)",
                "persist:completed",
            ]
        )
    }

    func testCheckpointFailurePreventsExternalExecution() async throws {
        let fixture = try Fixture()
        let log = Log()
        let checkpoint = Checkpoint(log: log, failAtWrite: 1)
        let executor = Executor(log: log, envelope: fixture.envelope)
        let dispatcher = Dispatcher(log: log, result: .completed(fixture.outcome))

        let result = await Phase2AssistantShellContinuationOrchestrator()
            .executeApprovedAndContinue(
                machine: fixture.machine,
                proposal: fixture.command,
                approval: fixture.approval,
                checkpoint: checkpoint,
                executor: executor,
                dispatcher: dispatcher
            )

        XCTAssertEqual(result.failure, .checkpointWriteFailed)
        XCTAssertEqual(log.events, ["persist:executingShell"])
    }

    func testCancellationBeforeReservationPreventsExternalExecutionAndDispatch() async throws {
        let fixture = try Fixture()
        let log = Log()
        let executor = Executor(log: log, envelope: fixture.envelope)
        let dispatcher = Dispatcher(log: log, result: .completed(fixture.outcome))

        let result = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Phase2AssistantShellContinuationOrchestrator()
                .executeApprovedAndContinue(
                    machine: fixture.machine,
                    proposal: fixture.command,
                    approval: fixture.approval,
                    checkpoint: Checkpoint(log: log),
                    executor: executor,
                    dispatcher: dispatcher
                )
        }.value

        XCTAssertEqual(result.failure, .continuationFailed)
        XCTAssertEqual(result.machine.state, .awaitingShellReview)
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertEqual(dispatcher.callCount, 0)
    }

    func testProviderFailureTerminatesWithoutRedispatch() async throws {
        let fixture = try Fixture()
        let log = Log()
        let checkpoint = Checkpoint(log: log)
        let executor = Executor(log: log, envelope: fixture.envelope)
        let dispatcher = Dispatcher(log: log, result: .failed)

        let result = await Phase2AssistantShellContinuationOrchestrator()
            .executeApprovedAndContinue(
                machine: fixture.machine,
                proposal: fixture.command,
                approval: fixture.approval,
                checkpoint: checkpoint,
                executor: executor,
                dispatcher: dispatcher
            )

        XCTAssertEqual(result.machine.state, .failed)
        XCTAssertEqual(result.failure, .continuationFailed)
        XCTAssertEqual(dispatcher.callCount, 1)
        XCTAssertEqual(checkpoint.states.last, .failed)
    }

    func testApprovedProposalCannotExecuteDifferentContentWithSameID() async throws {
        let fixture = try Fixture()
        let log = Log()
        let altered = Phase2AIShellCommandProposal(
            proposalID: fixture.command.proposalID,
            executablePath: "/usr/bin/false",
            timeoutMilliseconds: fixture.command.timeoutMilliseconds,
            maximumOutputBytes: fixture.command.maximumOutputBytes
        )
        let result = await Phase2AssistantShellContinuationOrchestrator()
            .executeApprovedAndContinue(
                machine: fixture.machine,
                proposal: altered,
                approval: fixture.approval,
                checkpoint: Checkpoint(log: log),
                executor: Executor(log: log, envelope: fixture.envelope),
                dispatcher: Dispatcher(log: log, result: .completed(fixture.outcome))
            )

        XCTAssertEqual(result.failure, .rejected(.invalidProposalProvenance))
        XCTAssertEqual(result.machine.state, .awaitingShellReview)
        XCTAssertTrue(log.events.isEmpty)
    }

    func testWorkspaceStoreProductionEntryPreservesTurnAndRunsAutomaticContinuation() async throws {
        let store = WorkspaceStore(
            workspaceName: "Continuation",
            snapshot: .init(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        let fixture = try Fixture(
            workspaceID: store.workspaceID,
            documentID: store.documentID
        )
        store.stagePhase2AIShellProposalForReview(fixture.command)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: fixture.command.proposalID)
        let log = Log()
        let dispatcher = Dispatcher(log: log, result: .completed(fixture.outcome))

        let result = await store.runApprovedPhase2AssistantShellContinuation(
            machine: fixture.machine,
            proposal: fixture.command,
            approval: fixture.approval,
            continuationRequestID: fixture.coordinate.continuationRequestID,
            productionManifestIdentity: fixture.coordinate.productionManifestIdentity,
            providerRevision: fixture.coordinate.providerRevision,
            checkpoint: Checkpoint(log: log),
            dispatcher: dispatcher,
            oneShotExecutor: CompletedOneShotExecutor()
        )

        XCTAssertEqual(result.machine.state, .completed)
        XCTAssertEqual(result.machine.coordinate?.conversationID, fixture.identity.conversationID)
        XCTAssertEqual(result.machine.coordinate?.inferenceTurnID, fixture.identity.inferenceTurnID)
        XCTAssertEqual(result.machine.coordinate?.turnSequence, fixture.identity.turnSequence)
        XCTAssertEqual(result.machine.coordinate?.shellExecutionID, fixture.executionID)
        XCTAssertEqual(dispatcher.lastCoordinate?.continuationRequestID,
                       fixture.coordinate.continuationRequestID)
        XCTAssertEqual(dispatcher.lastExecutionResult?.standardOutput, "ok\n")
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.sessionID, fixture.executionID)
    }

    func testWorkspaceStoreProductionEntryRejectsForeignWorkspaceBeforeExecution() async throws {
        let fixture = try Fixture()
        let store = WorkspaceStore(
            workspaceName: "Foreign continuation",
            snapshot: .init(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.stagePhase2AIShellProposalForReview(fixture.command)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: fixture.command.proposalID)
        let executor = RecordingOneShotExecutor()
        let log = Log()

        let result = await store.runApprovedPhase2AssistantShellContinuation(
            machine: fixture.machine,
            proposal: fixture.command,
            approval: fixture.approval,
            continuationRequestID: fixture.coordinate.continuationRequestID,
            productionManifestIdentity: fixture.coordinate.productionManifestIdentity,
            providerRevision: fixture.coordinate.providerRevision,
            checkpoint: Checkpoint(log: log),
            dispatcher: Dispatcher(log: log, result: .completed(fixture.outcome)),
            oneShotExecutor: executor
        )

        XCTAssertEqual(result.failure, .rejected(.invalidCoordinate))
        let executorCallCount = await executor.callCount
        XCTAssertEqual(executorCallCount, 0)
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertTrue(store.phase2RuntimeAuthorityRecords.isEmpty)
    }

    func testWorkspaceStoreProductionEntryDoesNotExecuteAliasedApprovedProposalContent() async throws {
        let store = WorkspaceStore(
            workspaceName: "Continuation",
            snapshot: .init(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        let fixture = try Fixture(
            workspaceID: store.workspaceID,
            documentID: store.documentID
        )
        let altered = Phase2AIShellCommandProposal(
            proposalID: fixture.command.proposalID,
            executablePath: "/usr/bin/false",
            timeoutMilliseconds: fixture.command.timeoutMilliseconds,
            maximumOutputBytes: fixture.command.maximumOutputBytes
        )
        store.stagePhase2AIShellProposalForReview(altered)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: altered.proposalID)
        let executor = RecordingOneShotExecutor()
        let log = Log()

        let result = await store.runApprovedPhase2AssistantShellContinuation(
            machine: fixture.machine,
            proposal: fixture.command,
            approval: fixture.approval,
            continuationRequestID: fixture.coordinate.continuationRequestID,
            productionManifestIdentity: fixture.coordinate.productionManifestIdentity,
            providerRevision: fixture.coordinate.providerRevision,
            checkpoint: Checkpoint(log: log),
            dispatcher: Dispatcher(log: log, result: .completed(fixture.outcome)),
            oneShotExecutor: executor
        )

        XCTAssertEqual(result.failure, .executionFailed)
        XCTAssertEqual(result.machine.state, .failed)
        let executorCallCount = await executor.callCount
        XCTAssertEqual(executorCallCount, 0)
    }

    func testWorkspaceStoreProductionEntryRejectsAliasedContinuationIDBeforeExecution() async throws {
        let store = WorkspaceStore(
            workspaceName: "Continuation",
            snapshot: .init(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        let fixture = try Fixture(
            workspaceID: store.workspaceID,
            documentID: store.documentID
        )
        store.stagePhase2AIShellProposalForReview(fixture.command)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: fixture.command.proposalID)
        let executor = RecordingOneShotExecutor()
        let log = Log()

        let result = await store.runApprovedPhase2AssistantShellContinuation(
            machine: fixture.machine,
            proposal: fixture.command,
            approval: fixture.approval,
            continuationRequestID: fixture.identity.inferenceTurnID,
            productionManifestIdentity:
                Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
            providerRevision: fixture.coordinate.providerRevision,
            checkpoint: Checkpoint(log: log),
            dispatcher: Dispatcher(log: log, result: .completed(fixture.outcome)),
            oneShotExecutor: executor
        )

        XCTAssertEqual(result.failure, .rejected(.invalidCoordinate))
        XCTAssertEqual(result.machine.state, .awaitingShellReview)
        let executorCallCount = await executor.callCount
        XCTAssertEqual(executorCallCount, 0)
        XCTAssertTrue(log.events.isEmpty)
    }
}

@MainActor
private final class Log {
    var events: [String] = []
}

@MainActor
private final class Checkpoint: Phase2AssistantShellContinuationCheckpointing {
    let log: Log
    let failAtWrite: Int?
    var states: [Phase2AssistantShellContinuationState] = []
    private var writeCount = 0

    init(log: Log, failAtWrite: Int? = nil) {
        self.log = log
        self.failAtWrite = failAtWrite
    }

    func persistAssistantShellContinuation(
        _ machine: Phase2AssistantShellContinuationMachine
    ) async throws {
        writeCount += 1
        states.append(machine.state)
        log.events.append("persist:\(machine.state.rawValue)")
        if writeCount == failAtWrite { throw Failure.injected }
    }

    enum Failure: Error { case injected }
}

@MainActor
private final class Executor: Phase2AssistantShellContinuationExecuting {
    let log: Log
    let envelope: Phase2AssistantShellContinuationExecutionEnvelope?

    init(log: Log, envelope: Phase2AssistantShellContinuationExecutionEnvelope?) {
        self.log = log
        self.envelope = envelope
    }

    func executeRestrictedOneShot(
        proposal: Phase2AIShellCommandProposal,
        reservedExecutionID: UUID
    ) async -> Phase2AssistantShellContinuationExecutionEnvelope? {
        log.events.append("execute:\(reservedExecutionID.uuidString)")
        return envelope
    }
}

@MainActor
private final class Dispatcher: Phase2AssistantShellContinuationDispatching {
    let log: Log
    let result: Phase2AssistantShellProviderContinuationResult
    var callCount = 0
    var lastCoordinate: Phase2AssistantShellContinuationCoordinate?
    var lastExecutionResult: Phase2AIShellOneShotExecutionResult?

    init(log: Log, result: Phase2AssistantShellProviderContinuationResult) {
        self.log = log
        self.result = result
    }

    func dispatchShellContinuation(
        coordinate: Phase2AssistantShellContinuationCoordinate,
        executionResult: Phase2AIShellOneShotExecutionResult
    ) async -> Phase2AssistantShellProviderContinuationResult {
        callCount += 1
        lastCoordinate = coordinate
        lastExecutionResult = executionResult
        log.events.append("dispatch:\(coordinate.continuationRequestID.uuidString)")
        return result
    }
}

private actor CompletedOneShotExecutor: Phase2AIShellOneShotExecuting {
    func run(_ proposal: Phase2AIShellCommandProposal) async -> Phase2AIShellOneShotExecutionResult {
        let now = Date()
        return .init(
            proposalID: proposal.proposalID,
            executablePath: proposal.executablePath,
            arguments: proposal.arguments,
            workingDirectoryPath: proposal.workingDirectoryPath,
            timeoutMilliseconds: proposal.timeoutMilliseconds,
            maximumOutputBytes: proposal.maximumOutputBytes,
            disposition: .completed,
            terminationStatus: 0,
            standardOutput: "ok\n",
            standardError: "",
            outputWasTruncated: false,
            startedAt: now,
            completedAt: now,
            failureMessage: nil
        )
    }
}

private actor RecordingOneShotExecutor: Phase2AIShellOneShotExecuting {
    private(set) var callCount = 0

    func run(_ proposal: Phase2AIShellCommandProposal) async -> Phase2AIShellOneShotExecutionResult {
        callCount += 1
        return await CompletedOneShotExecutor().run(proposal)
    }
}

private struct Fixture {
    let identity: Phase2AssistantShellTurnIdentity
    let command: Phase2AIShellCommandProposal
    let executionID: UUID
    let approval: Phase2AssistantShellApproval
    let coordinate: Phase2AssistantShellContinuationCoordinate
    let envelope: Phase2AssistantShellContinuationExecutionEnvelope
    let machine: Phase2AssistantShellContinuationMachine
    let outcome = Phase2InferenceOutcome(
        disposition: .completed,
        previewDeltas: [],
        toolProposals: [],
        finalCandidate: .init(kind: .answer, text: "Done", evidenceIDs: [UUID()]),
        providerUsage: nil,
        violation: nil,
        acceptedEventCount: 1,
        cumulativeEventBytes: 1
    )

    init(workspaceID: UUID = UUID(), documentID: UUID = UUID()) throws {
        let executionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 10)
        let identity = Phase2AssistantShellTurnIdentity(
            workspaceID: workspaceID,
            workspaceDocumentIdentityDigest: Phase2AssistantWorkspaceDocumentIdentity.digest(
                documentID: documentID,
                workspaceID: workspaceID
            ),
            conversationID: UUID(),
            inferenceTurnID: UUID(),
            turnSequence: 1,
            originatingFinalizationRequestID: UUID()
        )
        let command = Phase2AIShellCommandProposal(
            proposalID: UUID(),
            executablePath: "/usr/bin/true",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024
        )
        let proposalDigest = Phase2AssistantShellProposalCanonicalizer.digest(command)
        let approval = Phase2AssistantShellApproval(
            turnIdentity: identity,
            proposalID: command.proposalID,
            proposalDigest: proposalDigest,
            reservedExecutionID: executionID
        )
        let continuationRequestID = UUID()
        let authorityID = UUID()
        let executionResult = Phase2AIShellOneShotExecutionResult(
            id: executionID,
            proposalID: command.proposalID,
            executablePath: command.executablePath,
            arguments: command.arguments,
            workingDirectoryPath: command.workingDirectoryPath,
            timeoutMilliseconds: command.timeoutMilliseconds,
            maximumOutputBytes: command.maximumOutputBytes,
            disposition: .completed,
            terminationStatus: 0,
            standardOutput: "ok\n",
            standardError: "",
            outputWasTruncated: false,
            startedAt: startedAt,
            completedAt: startedAt,
            failureMessage: nil
        )
        let coordinate = try XCTUnwrap(Phase2AssistantShellContinuationCoordinate(
            workspaceID: identity.workspaceID,
            workspaceDocumentIdentityDigest: identity.workspaceDocumentIdentityDigest,
            conversationID: identity.conversationID,
            inferenceTurnID: identity.inferenceTurnID,
            turnSequence: identity.turnSequence,
            originatingFinalizationRequestID: identity.originatingFinalizationRequestID,
            shellProposalID: command.proposalID,
            shellExecutionID: executionID,
            runtimeAuthorityRecordID: authorityID,
            shellProposalDigest: proposalDigest,
            shellExecutionResultDigest:
                Phase2AssistantShellExecutionResultCanonicalizer.digest(executionResult),
            runtimeAuthorityRecordDigest: String(repeating: "d", count: 64),
            productionManifestIdentity:
                Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
            providerRevision: 1,
            continuationRequestID: continuationRequestID
        ))
        let join = Phase2AssistantShellExecutionAuthorityJoin(
            turnIdentity: identity,
            proposalID: command.proposalID,
            proposalDigest: proposalDigest,
            executionID: executionID,
            executionProposalID: command.proposalID,
            executionResultDigest: coordinate.shellExecutionResultDigest,
            executionDisposition: .completed,
            runtimeAuthorityRecordID: authorityID,
            runtimeAuthoritySessionID: executionID,
            runtimeAuthorityRecordDigest: coordinate.runtimeAuthorityRecordDigest,
            runtimeAuthoritySurfaces: [.providerVisibleShellExecution],
            providerVisibleShellExecutionEnabled: true,
            productionManifestIdentity: coordinate.productionManifestIdentity,
            providerRevision: coordinate.providerRevision,
            wasAlreadyConsumed: false,
            continuationRequestID: continuationRequestID
        )
        var machine = try XCTUnwrap(Phase2AssistantShellContinuationMachine(turnIdentity: identity))
        _ = machine.apply(.beginToolSelection(identity))
        _ = machine.apply(.beginFinalization(identity))
        _ = machine.apply(.stageProposal(.init(
            turnIdentity: identity,
            proposalID: command.proposalID,
            proposalDigest: proposalDigest,
            executionSurface: .restrictedOneShotJob,
            isLegacy: false
        )))
        self.identity = identity
        self.command = command
        self.executionID = executionID
        self.approval = approval
        self.coordinate = coordinate
        self.envelope = .init(
            authorityJoin: join,
            coordinate: coordinate,
            executionResult: executionResult
        )
        self.machine = machine
    }
}
