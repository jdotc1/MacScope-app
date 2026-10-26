import Foundation
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceStoreAnalystFindingAcceptanceTests: XCTestCase {
    private func store() -> WorkspaceStore {
        WorkspaceStore(workspaceName: "Finding acceptance", snapshot: .init(binaries: [], analysisBySlot: [:]),
                       engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func result(in store: WorkspaceStore) throws -> Phase2AssistantSessionResult {
        let fixture = AnalystFindingNativeFixture(workspace: store.phase2ReadCurrentState(for: nil).workspace,
                                                 revision: store.phase2ReadCurrentState(for: nil).workspaceRevision)
        let executions = try [fixture.execution()]
        let context = try fixture.context(executions)
        return fixture.result(context, executions: executions, request: fixture.request(context, revision: fixture.revision))
    }

    private func accepted(in store: WorkspaceStore) throws -> AnalystFindingRecord {
        store.stageAnalystFinding(from: try result(in: store),
            publicationToken: .capture(intent: .askMacScope, store: store))
        return try store.acceptPendingAnalystFinding()
    }

    func testAuthoredEditReviewUndoRedoRetainsHistoryAndOriginalProvenance() throws {
        let store = store(), original = try accepted(in: store)
        _ = try store.editAnalystFinding(store.analystFindingEditToken(for: original.id), text: "First authored edit")
        _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: original.id), decision: .reviewed)
        _ = try store.editAnalystFinding(store.analystFindingEditToken(for: original.id), text: "Second authored edit")
        XCTAssertFalse(store.analystFindings.records[0].authoredLifecycle.isReviewCurrent)
        store.undoManager.undo()
        var record = store.analystFindings.records[0]
        XCTAssertEqual(record.authoredText, "First authored edit")
        XCTAssertEqual(record.contentRevision, 4)
        XCTAssertFalse(record.authoredLifecycle.isReviewCurrent)
        store.undoManager.redo()
        record = store.analystFindings.records[0]
        XCTAssertEqual(record.authoredText, "Second authored edit")
        XCTAssertEqual(record.contentRevision, 5)
        XCTAssertEqual(record.authoredLifecycle.history.count, 5)
        XCTAssertEqual(record.content, original.content)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(try store.persistableAnalystFindings()?.records[0], record)
    }

    func testMultipleDocumentUndoStepsKeepMonotonicHistoryAndReviewSelection() throws {
        let store = store(), original = try accepted(in: store)
        _ = try store.editAnalystFinding(store.analystFindingEditToken(for: original.id), text: "A")
        _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: original.id), decision: .needsChanges)
        _ = try store.editAnalystFinding(store.analystFindingEditToken(for: original.id), text: "B")
        store.undoManager.undo() // B -> A; historical review stays historical.
        store.undoManager.undo() // Review selection -> none; decision remains archived.
        XCTAssertNil(store.analystFindings.records[0].authoredLifecycle.selectedReview)
        XCTAssertEqual(store.analystFindings.records[0].reviewRevision, 1)
        store.undoManager.undo() // A -> original text, with a new content revision.
        XCTAssertEqual(store.analystFindings.records[0].authoredText, original.content.candidateText)
        XCTAssertEqual(store.analystFindings.records[0].contentRevision, 5)
        XCTAssertTrue(store.hasUnsavedChanges)
        store.undoManager.redo()
        store.undoManager.redo()
        store.undoManager.redo()
        let lifecycle = store.analystFindings.records[0].authoredLifecycle
        XCTAssertEqual(lifecycle.state.text, "B")
        XCTAssertEqual(lifecycle.state.contentRevision, 7)
        XCTAssertEqual(lifecycle.state.reviewRevision, 1)
        XCTAssertEqual(lifecycle.selectedReview?.decision, .needsChanges)
        XCTAssertFalse(lifecycle.isReviewCurrent)
        XCTAssertEqual(lifecycle.history.count, 9)
    }

    func testStaleEditorAndReviewSelectionCallbacksRejectWithoutDocumentMutation() throws {
        let store = store(), original = try accepted(in: store)
        let initial = try store.analystFindingEditToken(for: original.id)
        _ = try store.reviewAnalystFinding(initial, decision: .reviewed)
        let reviewed = try store.analystFindingEditToken(for: original.id)
        store.undoManager.undo()
        // Same reducer revision vector, different selected review/history event.
        XCTAssertEqual(try store.analystFindingEditToken(for: original.id).revisions, reviewed.revisions)
        let before = store.analystFindings, generation = store.mutationGeneration
        XCTAssertThrowsError(try store.editAnalystFinding(initial, text: "stale"))
        XCTAssertThrowsError(try store.reviewAnalystFinding(reviewed, decision: .reviewed))
        XCTAssertEqual(store.analystFindings, before)
        XCTAssertEqual(store.mutationGeneration, generation)
        store.undoManager.redo()
        XCTAssertTrue(store.analystFindings.records[0].authoredLifecycle.isReviewCurrent)
    }

    func testRevisionOwnershipAndBoundsRefuseBeforeDirtyingOrUndoRegistration() throws {
        let store = store(), original = try accepted(in: store)
        let token = try store.analystFindingEditToken(for: original.id)
        let before = store.analystFindings, generation = store.mutationGeneration
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertThrowsError(try store.editAnalystFinding(token, text: String(repeating: "Ω", count: 32_769)))
        XCTAssertThrowsError(try store.editAnalystFinding(token, text: original.authoredText))
        XCTAssertEqual(store.mutationGeneration, generation)
        XCTAssertEqual(store.analystFindings, before)
        XCTAssertFalse(store.undoManager.canUndo)
        _ = try store.editAnalystFinding(token, text: "A")
        store.forkWorkspaceIdentity()
        let forkGeneration = store.mutationGeneration, forkContents = store.analystFindings
        XCTAssertThrowsError(try store.reviewAnalystFinding(token, decision: .reviewed))
        store.undoManager.undo() // Captured document installation has retired.
        XCTAssertEqual(store.mutationGeneration, forkGeneration)
        XCTAssertEqual(store.analystFindings, forkContents)
    }

    func testExplicitAcceptancePreservesFullContentAndInitialRevision() throws {
        let store = store(), result = try result(in: store)
        store.stageAnalystFinding(from: result, publicationToken: .capture(intent: .askMacScope, store: store))
        XCTAssertTrue(store.analystFindings.isEmpty)
        XCTAssertNotNil(store.pendingAnalystFinding)
        let accepted = try store.acceptPendingAnalystFinding()
        XCTAssertEqual(accepted.content.candidateText, result.inferenceOutcome?.finalCandidate?.text)
        XCTAssertEqual(accepted.content.originalRequest.requestID, result.request?.requestID)
        XCTAssertEqual(accepted.contentRevision, 1)
        XCTAssertEqual(accepted.reviewRevision, 0)
        XCTAssertNil(accepted.review)
        XCTAssertNil(store.pendingAnalystFinding)
        XCTAssertEqual(try store.persistableAnalystFindings()?.records, [accepted])
        XCTAssertThrowsError(try store.acceptPendingAnalystFinding())
        XCTAssertEqual(store.analystFindings.records.count, 1)
    }

    func testRejectAndStaleDocumentCannotCreateFinding() throws {
        let store = store(), result = try result(in: store)
        let token = Phase2AssistantPublicationToken.capture(intent: .askMacScope, store: store)
        store.stageAnalystFinding(from: result, publicationToken: token)
        store.dismissPendingAnalystFinding()
        XCTAssertTrue(store.analystFindings.isEmpty)
        store.stageAnalystFinding(from: result, publicationToken: token)
        store.forkWorkspaceIdentity()
        XCTAssertThrowsError(try store.acceptPendingAnalystFinding())
        XCTAssertTrue(store.analystFindings.isEmpty)
    }

    func testInstallRestoresHistoricalProvenanceWithoutRestagingOrInference() throws {
        let original = store(), result = try result(in: original)
        original.stageAnalystFinding(from: result, publicationToken: .capture(intent: .askMacScope, store: original))
        _ = try original.acceptPendingAnalystFinding()
        let saved = try XCTUnwrap(original.persistableAnalystFindings())
        let reopened = WorkspaceStore(workspaceName: "Reopened", snapshot: .init(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil, documentID: original.documentID, workspaceID: original.workspaceID)
        try WorkspaceStore.validateAnalystFindingsForRestore(saved, workspaceID: reopened.workspaceID, documentID: reopened.documentID)
        reopened.installValidatedAnalystFindings(saved)
        XCTAssertEqual(reopened.analystFindings, saved)
        XCTAssertNil(reopened.pendingAnalystFinding)
        XCTAssertNotEqual(reopened.phase2ReadCurrentState(for: nil).workspace.instanceID,
                          saved.records[0].content.originalRequest.workspaceInstanceID)
        XCTAssertEqual(reopened.analystFindings.records[0].content.originalRequest.workspaceInstanceID,
                       result.request?.workspace.instanceID)
    }
}

private struct AnalystFindingNativeFixture {
        let workspace: Phase2ReadWorkspaceIdentity
        let revision: UInt64
        var precondition: Phase2ReadPrecondition {
            .init(workspace: workspace, workspaceRevision: revision, strictWholeWorkspace: true,
                  image: nil, dependencies: [])
        }
        var current: Phase2ReadCurrentState {
            .init(workspace: workspace, workspaceRevision: revision, image: nil, facetRevisions: [])
        }
        func execution(data: Phase2ReadCandidateData = .value(.text("Original native fact")),
                       evidenceID: UUID = UUID()) throws -> Phase2ReadExecution {
            let descriptor = Phase2ReadOperationDescriptor(registryVersion: .v1, id: .workspaceSummary,
                operationVersion: .v1, effects: [.a1])
            let candidate = Phase2ReadEvidenceCandidate(candidateID: UUID(), invocationID: UUID(), sequence: 1,
                registryVersion: .v1, operationID: .workspaceSummary, operationVersion: .v1,
                producingPrincipal: .app, precondition: precondition,
                citations: [.init(id: UUID(), target: .workspace(workspace), dependencies: [])],
                data: data, cancelled: false)
            let request = Phase2ReadRequest(requestID: UUID(), invocationID: candidate.invocationID, sequence: 1,
                proposingPrincipal: .model, descriptor: descriptor, subject: .workspace(workspace),
                precondition: precondition, limits: .maximum)
            let authorization = Phase2ReadAuthorization(request: request, canonicalDescriptor: descriptor,
                authorizingPrincipal: .app, approvedLimits: .maximum)
            var acceptor = Phase2EvidenceAcceptor()
            let terminal = acceptor.evaluate(candidate, authorization: authorization, against: current,
                                             acceptingEvidenceID: evidenceID)
            _ = try XCTUnwrap(acceptor.acceptedEvidence(for: candidate.invocationID))
            return .init(candidate: candidate, outcome: terminal,
                         acceptedEvidence: acceptor.acceptedEvidence(for: candidate.invocationID))
        }
        func context(_ executions: [Phase2ReadExecution]) throws -> Phase2GroundedContext {
            let evidence = try executions.map { try XCTUnwrap($0.acceptedEvidence) }
            return try Phase2GroundedContextCompiler().compile(records: evidence,
                currentStateByEvidenceID: Dictionary(uniqueKeysWithValues: evidence.map { ($0.evidenceID, current) }))
        }
        func request(_ context: Phase2GroundedContext, phase: Phase2InferencePhase = .finalization,
                     workspaceOverride: Phase2ReadWorkspaceIdentity? = nil,
                     revision: UInt64 = 1) -> Phase2InferenceRequest {
            .init(protocolVersion: .init(rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion),
                phase: phase, sessionID: UUID(), turnID: UUID(), requestID: UUID(),
                document: workspace.document, workspace: workspaceOverride ?? workspace,
                lifecycleRevision: revision, userGoal: "Authored goal", groundedContext: context,
                toolHandles: [], limits: .assistantMaximum)
        }
        func result(_ context: Phase2GroundedContext, executions: [Phase2ReadExecution],
                    evidenceIDs: [UUID]? = nil, text: String = "Entire authored answer\nΩ",
                    kind: Phase2InferenceFinalKind = .answer,
                    request: Phase2InferenceRequest? = nil, omitRequest: Bool = false,
                    provider: UInt64? = 7, disposition: Phase2InferenceDisposition = .completed,
                    unverified: [String] = [], failure: Phase2AssistantSessionFailure? = nil,
                    omitContext: Bool = false, primary: Phase2ReadExecution? = nil) -> Phase2AssistantSessionResult {
            let candidate = Phase2InferenceFinalCandidate(kind: kind, text: text,
                evidenceIDs: evidenceIDs ?? context.records.map(\.evidenceID))
            return .init(intent: .askMacScope, request: omitRequest ? nil : (request ?? self.request(context)),
                groundedContext: omitContext ? nil : context, readExecution: primary ?? executions.first, readExecutions: executions,
                inferenceOutcome: .init(disposition: disposition, previewDeltas: [], toolProposals: [],
                    finalCandidate: candidate, providerUsage: nil, violation: nil,
                    acceptedEventCount: 1, cumulativeEventBytes: 1),
                providerRevision: provider, failure: failure, unverifiedAddresses: unverified)
        }
        func states(_ context: Phase2GroundedContext) -> [UUID: Phase2ReadCurrentState] {
            Dictionary(uniqueKeysWithValues: context.records.map { ($0.evidenceID, current) })
        }
    }

