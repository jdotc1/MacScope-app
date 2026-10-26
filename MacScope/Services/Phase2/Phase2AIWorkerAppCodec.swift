import Foundation

enum Phase2AIWorkerAppDecodedEvent: Sendable {
    case inference(Phase2InferenceEvent)
    case providerConnection(
        requestID: UUID,
        phase: Phase2InferencePhase,
        receipt: Phase2InferenceProviderConnectionReceipt
    )
    case providerDispatch(requestID: UUID, phase: Phase2InferencePhase)
}

/// App-owned translation between provider-neutral inference values and closed AI-worker DTOs.
/// Keeping this mapping here prevents XPC serialization concerns from leaking into the accepted
/// `Phase2InferenceRequest` and `Phase2InferenceEvent` models.
struct Phase2AIWorkerAppCodec: Sendable {
    private let wireCodec: Phase2AIWorkerWireCodec

    init(wireCodec: Phase2AIWorkerWireCodec = .init()) {
        self.wireCodec = wireCodec
    }

    func encodeRequest(_ request: Phase2InferenceRequest) throws -> Data {
        let protocolBundle: Phase2AIWorkerProductionProtocolBundle
        switch request.protocolVersion.rawValue {
        case Phase2AIWorkerProductionProtocol.standard.inferenceVersion:
            protocolBundle = Phase2AIWorkerProductionProtocol.standard
        case Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion:
            protocolBundle = Phase2AIWorkerProductionProtocol.assistantR2
        case Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion:
            protocolBundle = Phase2AIWorkerProductionProtocol.assistantR3
        case Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion:
            protocolBundle = Phase2AIWorkerProductionProtocol.assistantR4
        default:
            throw Phase2AIWorkerWireError.unsupportedProtocolVersion(
                request.protocolVersion.rawValue
            )
        }
        let wireCoordinate = request.shellContinuationCoordinate.map(
            Phase2AIWorkerWireShellContinuationCoordinate.init
        )
        guard wireCoordinate?.appCoordinate() == request.shellContinuationCoordinate else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        return try wireCodec.encodeRequest(
            .init(
                wireProtocol: protocolBundle.wireIdentity,
                protocolVersion: request.protocolVersion.rawValue,
                phase: wirePhase(request.phase),
                sessionID: request.sessionID,
                turnID: request.turnID,
                requestID: request.requestID,
                documentID: request.document.instanceID,
                workspaceID: request.workspace.instanceID,
                lifecycleRevision: request.lifecycleRevision,
                userGoal: request.userGoal,
                canonicalContext: request.groundedContext.canonicalBytes,
                contextDigest: request.groundedContext.digest,
                evidenceIDs: request.groundedContext.records.map(\.evidenceID),
                toolHandles: request.toolHandles.map {
                    .init(handleID: $0.handleID, operationID: $0.operationID.rawValue)
                },
                conversationContext: request.conversationContext.map { context in
                    .init(
                        turns: context.turns.map {
                            .init(
                                conversationID: $0.conversationID,
                                inferenceTurnID: $0.inferenceTurnID,
                                turnSequence: $0.turnSequence,
                                user: $0.user,
                                assistant: $0.assistant,
                                isLegacy: $0.isLegacy
                            )
                        },
                        omittedTurnCount: context.omittedTurnCount
                    )
                },
                shellContinuationCoordinate: wireCoordinate,
                limits: .init(
                    maximumGoalBytes: request.limits.maximumGoalBytes,
                    maximumEventBytes: request.limits.maximumEventBytes,
                    maximumCumulativeEventBytes: request.limits.maximumCumulativeEventBytes,
                    maximumEvents: request.limits.maximumEvents,
                    maximumToolHandles: request.limits.maximumToolHandles,
                    maximumToolProposals: request.limits.maximumToolProposals,
                    maximumFinalTextBytes: request.limits.maximumFinalTextBytes,
                    maximumEvidenceReferences: request.limits.maximumEvidenceReferences
                )
            )
        )
    }

    func decodeEvent(_ data: Data) throws -> Phase2InferenceEvent {
        guard case .inference(let event) = try decodeWorkerEvent(data) else {
            throw Phase2AIWorkerWireError.invalidEnvelope
        }
        return event
    }

    func decodeWorkerEvent(_ data: Data) throws -> Phase2AIWorkerAppDecodedEvent {
        let event = try wireCodec.decodeEvent(data)
        if case .providerDispatch = event.body {
            return .providerDispatch(
                requestID: event.requestID,
                phase: try inferencePhase(event.phase)
            )
        }
        if case .providerConnection(let receipt) = event.body {
            let value = try Phase2InferenceProviderConnectionReceipt(
                localAddress: receipt.localAddress,
                localPort: receipt.localPort,
                remoteAddress: receipt.remoteAddress,
                remotePort: receipt.remotePort
            )
            return .providerConnection(
                requestID: event.requestID,
                phase: try inferencePhase(event.phase),
                receipt: value
            )
        }
        let body: Phase2InferenceEventBody
        switch event.body {
        case .contentDelta(let text):
            body = .contentDelta(text)
        case .toolProposal(let callID, let handleID, let functionName, let operationID):
            guard let opaqueCallID = Phase2ProviderToolCallID(rawValue: callID),
                  let operation = Phase2ReadOperationID.allProviderVisible.first(where: {
                      $0.rawValue == operationID
                  })
            else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            body = .toolProposal(.init(
                callID: opaqueCallID,
                handleID: handleID,
                functionName: functionName,
                operationID: operation
            ))
        case .shellProposal(let proposal):
            guard let executionSurface = Phase2AIShellExecutionSurface(rawValue: proposal.executionSurface) else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            let effects = Set(proposal.requestedEffects.compactMap(Phase2EffectClass.init(rawValue:)))
            guard effects.count == proposal.requestedEffects.count else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            let candidate = Phase2AIShellCommandProposal(
                proposalID: proposal.proposalID,
                executablePath: proposal.executablePath,
                arguments: proposal.arguments,
                environment: proposal.environment,
                workingDirectoryPath: proposal.workingDirectoryPath,
                timeoutMilliseconds: proposal.timeoutMilliseconds,
                maximumOutputBytes: proposal.maximumOutputBytes,
                executionSurface: executionSurface,
                requestedEffects: effects
            )
            guard Phase2AIShellProposalValidator.validate(candidate).isAccepted else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            body = .shellProposal(candidate)
        case .debuggerActionProposal(let proposal):
            guard let action = Phase2AIDebuggerAction(rawValue: proposal.action),
                  let authority = Phase2DebuggerToolAuthority(rawValue: proposal.requestedAuthority)
            else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            let candidate = Phase2AIDebuggerActionProposal(
                proposalID: proposal.proposalID,
                action: action,
                sessionID: proposal.sessionID,
                lifecycleRevision: proposal.lifecycleRevision,
                stopRevision: proposal.stopRevision,
                eventSequence: proposal.eventSequence,
                requestedAuthority: authority
            )
            guard Phase2AIDebuggerProposalValidator.validate(candidate).isAccepted else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            body = .debuggerActionProposal(candidate)
        case .finalCandidate(let kind, let text, let evidenceIDs):
            body = .finalCandidate(.init(
                kind: inferenceFinalKind(kind),
                text: text,
                evidenceIDs: evidenceIDs
            ))
        case .usage(let usage):
            guard let value = Phase2ProviderUsage(
                promptTokens: usage.promptTokens,
                completionTokens: usage.completionTokens,
                totalTokens: usage.totalTokens
            ) else {
                throw Phase2AIWorkerWireError.invalidEnvelope
            }
            body = .usage(value)
        case .providerConnection:
            throw Phase2AIWorkerWireError.invalidEnvelope
        case .providerDispatch:
            throw Phase2AIWorkerWireError.invalidEnvelope
        case .awaitingTools:
            body = .awaitingTools
        case .completed:
            body = .completed
        }

        let document = Phase2ReadDocumentIdentity(instanceID: event.documentID)
        return .inference(.init(
            protocolVersion: .init(rawValue: event.protocolVersion),
            phase: try inferencePhase(event.phase),
            sessionID: event.sessionID,
            turnID: event.turnID,
            requestID: event.requestID,
            document: document,
            workspace: .init(document: document, instanceID: event.workspaceID),
            lifecycleRevision: event.lifecycleRevision,
            sequence: event.sequence,
            body: body
        ))
    }

    private func wirePhase(_ phase: Phase2InferencePhase) -> Phase2AIWorkerWirePhase {
        switch phase {
        case .toolSelection: .toolSelection
        case .finalization: .finalization
        case .shellContinuation: .shellContinuation
        }
    }

    private func inferencePhase(
        _ phase: Phase2AIWorkerWirePhase
    ) throws -> Phase2InferencePhase {
        switch phase {
        case .toolSelection: .toolSelection
        case .finalization: .finalization
        case .shellContinuation: .shellContinuation
        }
    }

    private func inferenceFinalKind(
        _ kind: Phase2AIWorkerWireFinalKind
    ) -> Phase2InferenceFinalKind {
        switch kind {
        case .answer: .answer
        case .insufficientEvidence: .insufficientEvidence
        }
    }
}

extension Phase2AIWorkerWireShellContinuationCoordinate {
    init(_ coordinate: Phase2AssistantShellContinuationCoordinate) {
        self.init(
            workspaceID: coordinate.workspaceID,
            workspaceDocumentIdentityDigest: coordinate.workspaceDocumentIdentityDigest,
            conversationID: coordinate.conversationID,
            inferenceTurnID: coordinate.inferenceTurnID,
            turnSequence: coordinate.turnSequence,
            originatingFinalizationRequestID: coordinate.originatingFinalizationRequestID,
            shellProposalID: coordinate.shellProposalID,
            shellExecutionID: coordinate.shellExecutionID,
            runtimeAuthorityRecordID: coordinate.runtimeAuthorityRecordID,
            shellProposalDigest: coordinate.shellProposalDigest,
            shellExecutionResultDigest: coordinate.shellExecutionResultDigest,
            runtimeAuthorityRecordDigest: coordinate.runtimeAuthorityRecordDigest,
            productionManifestIdentity: coordinate.productionManifestIdentity,
            providerRevision: coordinate.providerRevision,
            continuationOrdinal: coordinate.continuationOrdinal,
            continuationRequestID: coordinate.continuationRequestID,
            integrityDigest: coordinate.integrityDigest
        )
    }

    func appCoordinate() -> Phase2AssistantShellContinuationCoordinate? {
        Phase2AssistantShellContinuationCoordinate(
            workspaceID: workspaceID,
            workspaceDocumentIdentityDigest: workspaceDocumentIdentityDigest,
            conversationID: conversationID,
            inferenceTurnID: inferenceTurnID,
            turnSequence: turnSequence,
            originatingFinalizationRequestID: originatingFinalizationRequestID,
            shellProposalID: shellProposalID,
            shellExecutionID: shellExecutionID,
            runtimeAuthorityRecordID: runtimeAuthorityRecordID,
            shellProposalDigest: shellProposalDigest,
            shellExecutionResultDigest: shellExecutionResultDigest,
            runtimeAuthorityRecordDigest: runtimeAuthorityRecordDigest,
            productionManifestIdentity: productionManifestIdentity,
            providerRevision: providerRevision,
            continuationOrdinal: continuationOrdinal,
            continuationRequestID: continuationRequestID,
            integrityDigest: integrityDigest
        )
    }
}
