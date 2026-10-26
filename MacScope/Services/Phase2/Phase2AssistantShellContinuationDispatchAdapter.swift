import Foundation

struct Phase2AssistantShellContinuationDispatchContext: Sendable {
    let documentID: UUID
    let workspaceID: UUID
    let workspaceDocumentIdentityDigest: String
    let lifecycleRevision: UInt64
    let providerRevision: UInt64
    let originalUserGoal: String
    let groundedContext: Phase2GroundedContext
    let conversationContext: Phase2InferenceConversationContext
    let limits: Phase2InferenceLimits

    init(
        documentID: UUID,
        workspaceID: UUID,
        workspaceDocumentIdentityDigest: String,
        lifecycleRevision: UInt64,
        providerRevision: UInt64,
        originalUserGoal: String,
        groundedContext: Phase2GroundedContext,
        conversationContext: Phase2InferenceConversationContext,
        limits: Phase2InferenceLimits
    ) {
        self.documentID = documentID
        self.workspaceID = workspaceID
        self.workspaceDocumentIdentityDigest = workspaceDocumentIdentityDigest
        self.lifecycleRevision = lifecycleRevision
        self.providerRevision = providerRevision
        self.originalUserGoal = originalUserGoal
        self.groundedContext = groundedContext
        self.conversationContext = conversationContext
        self.limits = limits
    }
}

@MainActor
final class Phase2AssistantShellContinuationDispatchAdapter:
    Phase2AssistantShellContinuationDispatching
{
    typealias ContextProvider = @MainActor @Sendable (
        Phase2AssistantShellContinuationCoordinate
    ) -> Phase2AssistantShellContinuationDispatchContext?

    private let coordinator: any Phase2AssistantInferenceCoordinating
    private let contextProvider: ContextProvider

    init(
        coordinator: any Phase2AssistantInferenceCoordinating,
        context: @escaping ContextProvider
    ) {
        self.coordinator = coordinator
        contextProvider = context
    }

    func dispatchShellContinuation(
        coordinate: Phase2AssistantShellContinuationCoordinate,
        executionResult: Phase2AIShellOneShotExecutionResult
    ) async -> Phase2AssistantShellProviderContinuationResult {
        let executionDigest = Phase2AssistantShellExecutionResultCanonicalizer.digest(
            executionResult
        )
        guard coordinate.productionManifestIdentity
                == Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
              coordinate.continuationOrdinal
                == Phase2AssistantShellContinuationCoordinate.continuationOrdinal,
              let context = contextProvider(coordinate),
              context.workspaceID == coordinate.workspaceID,
              context.documentID != Phase2AssistantShellTurnIdentity.zeroUUID,
              !coordinateIdentifiers(coordinate).contains(context.documentID),
              Phase2AssistantWorkspaceDocumentIdentity.digest(
                  documentID: context.documentID,
                  workspaceID: context.workspaceID
              ) == coordinate.workspaceDocumentIdentityDigest,
              context.workspaceDocumentIdentityDigest
                == coordinate.workspaceDocumentIdentityDigest,
              context.providerRevision == coordinate.providerRevision,
              context.lifecycleRevision > 0,
              !context.originalUserGoal.isEmpty,
              context.limits.isValid,
              coordinate.isIntegrityValid,
              executionDigest == coordinate.shellExecutionResultDigest,
              executionResultIsValid(executionResult, coordinate: coordinate),
              Phase2AIWorkerWireShellContinuationCoordinate(coordinate).appCoordinate()
                == coordinate,
              context.groundedContext.records.allSatisfy({ record in
                  record.precondition.workspace.document.instanceID == context.documentID
                      && record.precondition.workspace.instanceID == context.workspaceID
              }),
              conversationContextIsValid(
                  context.conversationContext,
                  coordinate: coordinate
              ),
              let continuationGoal = continuationGoal(
                  originalGoal: context.originalUserGoal,
                  executionResult: executionResult,
                  executionDigest: executionDigest,
                  maximumBytes: context.limits.maximumGoalBytes
              )
        else { return .failed }

        let document = Phase2ReadDocumentIdentity(instanceID: context.documentID)
        let request = Phase2InferenceRequest(
            protocolVersion: .v6,
            phase: .shellContinuation,
            sessionID: coordinate.conversationID,
            turnID: coordinate.inferenceTurnID,
            requestID: coordinate.continuationRequestID,
            document: document,
            workspace: .init(document: document, instanceID: context.workspaceID),
            lifecycleRevision: context.lifecycleRevision,
            userGoal: continuationGoal,
            groundedContext: context.groundedContext,
            toolHandles: [],
            conversationContext: context.conversationContext,
            shellContinuationCoordinate: coordinate,
            limits: context.limits
        )
        switch await coordinator.run(request: request) {
        case .finished(let lease, let outcome)
            where lease.providerRevision == coordinate.providerRevision
                && outcome.disposition == .completed
                && outcome.violation == nil
                && finalCandidateIsGrounded(
                    outcome.finalCandidate,
                    in: context.groundedContext
                )
                && outcome.toolProposals.isEmpty
                && outcome.shellProposals.isEmpty
                && outcome.debuggerActionProposals.isEmpty:
            return .completed(outcome)
        case .notReady, .busy, .invalidRequest, .providerAuthorityChanged, .finished:
            return .failed
        }
    }

    private func coordinateIdentifiers(
        _ coordinate: Phase2AssistantShellContinuationCoordinate
    ) -> [UUID] {
        coordinate.turnIdentity.correlationIdentifiers + [
            coordinate.shellProposalID,
            coordinate.shellExecutionID,
            coordinate.runtimeAuthorityRecordID,
            coordinate.continuationRequestID,
        ]
    }

    private func executionResultIsValid(
        _ result: Phase2AIShellOneShotExecutionResult,
        coordinate: Phase2AssistantShellContinuationCoordinate
    ) -> Bool {
        let (outputBytes, overflow) = result.standardOutput.utf8.count.addingReportingOverflow(
            result.standardError.utf8.count
        )
        return result.id == coordinate.shellExecutionID
            && result.proposalID == coordinate.shellProposalID
            && result.schemaVersion == Phase2AIShellOneShotExecutionResult.schemaVersion
            && result.disposition == .completed
            && result.terminationStatus == 0
            && result.startedAt <= result.completedAt
            && !overflow
            && outputBytes <= result.maximumOutputBytes
            && (1...Phase2AIShellProposalValidator.maximumOutputBytes)
                .contains(result.maximumOutputBytes)
            && (1...Phase2AIShellProposalValidator.maximumTimeoutMilliseconds)
                .contains(result.timeoutMilliseconds)
    }

    private func conversationContextIsValid(
        _ context: Phase2InferenceConversationContext,
        coordinate: Phase2AssistantShellContinuationCoordinate
    ) -> Bool {
        guard context.turns.count <= Phase2InferenceConversationContext.maximumTurns,
              context.omittedTurnCount >= 0 else { return false }
        var priorSequence: UInt64?
        var turnIDs: Set<UUID> = []
        var bytes = 0
        for turn in context.turns {
            let (withUser, userOverflow) = bytes.addingReportingOverflow(turn.user.utf8.count)
            let (withAssistant, assistantOverflow) = withUser.addingReportingOverflow(
                turn.assistant.utf8.count
            )
            guard turn.conversationID == coordinate.conversationID,
                  turn.inferenceTurnID != Phase2AssistantShellTurnIdentity.zeroUUID,
                  turn.inferenceTurnID != coordinate.inferenceTurnID,
                  turnIDs.insert(turn.inferenceTurnID).inserted,
                  turn.turnSequence > 0,
                  turn.turnSequence < coordinate.turnSequence,
                  priorSequence.map({ turn.turnSequence > $0 }) ?? true,
                  !turn.isLegacy,
                  !turn.user.isEmpty,
                  !turn.assistant.isEmpty,
                  !turn.user.utf8.contains(0),
                  !turn.assistant.utf8.contains(0),
                  !userOverflow,
                  !assistantOverflow,
                  withAssistant <= Phase2InferenceConversationContext.maximumUTF8Bytes
            else { return false }
            priorSequence = turn.turnSequence
            bytes = withAssistant
        }
        return true
    }

    private func continuationGoal(
        originalGoal: String,
        executionResult: Phase2AIShellOneShotExecutionResult,
        executionDigest: String,
        maximumBytes: Int
    ) -> String? {
        let header = [
            "[MacScope exact same-turn restricted shell execution evidence]",
            "Execution result SHA-256: \(executionDigest)",
            "Execution ID: \(executionResult.id.uuidString.lowercased())",
            "Proposal ID: \(executionResult.proposalID.uuidString.lowercased())",
        ].joined(separator: "\n") + "\n"
        let separator = "\n\n"
        let fixedBytes = header.utf8.count + separator.utf8.count
        let availableBytes = maximumBytes - fixedBytes
        guard availableBytes > 256 else { return nil }
        let reservedEvidenceBytes = min(16_384, max(256, availableBytes / 2))

        let goalBudget = availableBytes - reservedEvidenceBytes
        let boundedGoal = Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            originalGoal,
            maximumBytes: goalBudget
        )
        let evidenceBudget = maximumBytes
            - boundedGoal.utf8.count
            - separator.utf8.count
            - header.utf8.count
        let evidence = executionResult.providerVisibleEvidenceText(
            maximumStreamBytes: max(1, evidenceBudget / 2)
        )
        let composed = boundedGoal + separator + header + evidence
        let bounded = Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            composed,
            maximumBytes: maximumBytes
        )
        guard bounded.contains(executionDigest),
              bounded.contains(executionResult.id.uuidString.lowercased()),
              bounded.contains("Disposition: completed") else { return nil }
        return bounded
    }

    private func finalCandidateIsGrounded(
        _ candidate: Phase2InferenceFinalCandidate?,
        in context: Phase2GroundedContext
    ) -> Bool {
        guard let candidate else { return false }
        switch candidate.kind {
        case .answer:
            return !candidate.evidenceIDs.isEmpty
                && Set(candidate.evidenceIDs).isSubset(of: Set(context.records.map(\.evidenceID)))
        case .insufficientEvidence:
            return candidate.evidenceIDs.isEmpty
        }
    }
}
