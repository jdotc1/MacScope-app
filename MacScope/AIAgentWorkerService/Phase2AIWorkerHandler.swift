import Foundation
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

/// The worker handler receives only the closed turn envelope and immutable connection authority.
protocol Phase2AIWorkerHandling: Sendable {
    func run(
        request: Phase2AIWorkerWireRequest,
        configuration: Phase2AIWorkerConfigurationWire,
        emit: @escaping @Sendable (Phase2AIWorkerWireEvent) async throws -> Void
    ) async throws
}

enum Phase2LiveInferenceHandlerError: Error, Equatable, Sendable {
    case invalidToolSelection
    case invalidFinalization
    case unsupportedInferenceProtocol(Int)
    case providerConnectionUnavailable
}

/// Production fixed-route loopback inference handler.
struct Phase2LiveInferenceHandler: Phase2AIWorkerHandling {
    typealias TestExecuteChat = @Sendable (
        _ configuration: Phase2AIWorkerConfigurationWire,
        _ prompt: Phase2ProductionPrompt,
        _ phase: Phase2OpenAIProductionChatPhase,
        _ generationVariant: Phase2OpenAIRequestGenerationVariant,
        _ onEvent: @escaping @Sendable (Phase2OpenAIChatStreamEvent) async -> Void
    ) async throws -> Void

    private typealias ExecuteChat = @Sendable (
        _ configuration: Phase2AIWorkerConfigurationWire,
        _ prompt: Phase2ProductionPrompt,
        _ phase: Phase2OpenAIProductionChatPhase,
        _ generationVariant: Phase2OpenAIRequestGenerationVariant,
        _ acceptsFinalizationProposalTools: Bool,
        _ onEvent: @escaping @Sendable (Phase2OpenAIChatStreamEvent) async -> Void,
        _ onProviderDispatch: @escaping @Sendable () async throws -> Void,
        _ onConnectionReceipt: @escaping @Sendable (Phase2OpenAIChatConnectionReceipt)
            async throws -> Void
    ) async throws -> Void

    private let executeChat: ExecuteChat
    private let requiresProviderConnectionReceipt: Bool

    init(executeChat: @escaping TestExecuteChat) {
        self.executeChat = { configuration, prompt, phase, variant, _, onEvent, _, _ in
            try await executeChat(configuration, prompt, phase, variant, onEvent)
        }
        requiresProviderConnectionReceipt = false
    }

    init() {
        executeChat = {
            configuration, prompt, phase, generationVariant,
            acceptsFinalizationProposalTools, onEvent,
            onProviderDispatch, onConnectionReceipt in
            let endpoint = try Phase2LoopbackEndpoint(validating: configuration.endpointOrigin)
            let requestTimeout = TimeInterval(configuration.requestTimeoutMilliseconds) / 1_000
            let resourceTimeout = TimeInterval(configuration.resourceTimeoutMilliseconds) / 1_000
            let loader = Phase2OpenAIChatURLSessionLoader(
                requestTimeout: requestTimeout,
                resourceTimeout: resourceTimeout
            )
            let client = Phase2OpenAIChatHTTPClient(
                loader: loader,
                limits: .init(
                    requestTimeout: requestTimeout,
                    resourceTimeout: resourceTimeout
                )
            )
            try await client.execute(
                .init(
                    endpoint: endpoint,
                    model: configuration.model,
                    systemPrompt: prompt.system,
                    userPrompt: prompt.user,
                    maximumTokens: configuration.maximumTokens,
                    phase: phase,
                    generationVariant: generationVariant,
                    acceptsFinalizationProposalTools: acceptsFinalizationProposalTools,
                    conversationContext: prompt.conversationContext,
                    inferencePolicy: configuration.inferencePolicy
                ),
                onEvent: onEvent,
                onProviderDispatch: onProviderDispatch,
                onConnectionReceipt: onConnectionReceipt
            )
        }
        requiresProviderConnectionReceipt = true
    }

    func run(
        request: Phase2AIWorkerWireRequest,
        configuration: Phase2AIWorkerConfigurationWire,
        emit: @escaping @Sendable (Phase2AIWorkerWireEvent) async throws -> Void
    ) async throws {
        let emitsProviderUsage = request.protocolVersion
            == Phase2AIWorkerProductionProtocol.standard.inferenceVersion
            || request.protocolVersion == Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion
            || request.protocolVersion == Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion
            || request.protocolVersion == Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
        guard emitsProviderUsage else {
            throw Phase2LiveInferenceHandlerError.unsupportedInferenceProtocol(
                request.protocolVersion
            )
        }
        let generationVariant: Phase2OpenAIRequestGenerationVariant = request.protocolVersion
            == Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
            ? .assistantR4 : .stagedV2
        let configuredBundle: Phase2AIWorkerProductionProtocolBundle? = switch request.protocolVersion {
        case Phase2AIWorkerProductionProtocol.standard.inferenceVersion:
            Phase2AIWorkerProductionProtocol.standard
        case Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion:
            Phase2AIWorkerProductionProtocol.assistantR2
        case Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion:
            Phase2AIWorkerProductionProtocol.assistantR3
        case Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion:
            Phase2AIWorkerProductionProtocol.assistantR4
        default: nil
        }
        guard configuration.protocolManifestDigest == configuredBundle?.manifestDigest else {
            throw Phase2LiveInferenceHandlerError.unsupportedInferenceProtocol(request.protocolVersion)
        }
        let acceptsFinalizationProposalTools = (
            request.protocolVersion == Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion
                && configuration.protocolManifestDigest
                    == Phase2AIWorkerProductionProtocol.assistantR2.manifestDigest
        ) || (
            request.protocolVersion == Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion
                && configuration.protocolManifestDigest
                    == Phase2AIWorkerProductionProtocol.assistantR3.manifestDigest
        ) || (
            request.protocolVersion == Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
                && configuration.protocolManifestDigest
                    == Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest
        )

        let promptPhase: Phase2ProductionPromptPhase
        let providerPhase: Phase2OpenAIProductionChatPhase
        switch request.phase {
        case .toolSelection:
            promptPhase = .toolSelection
            providerPhase = .toolSelection(handles: request.toolHandles.map {
                .init(handleID: $0.handleID, operationID: $0.operationID)
            })
        case .finalization:
            promptPhase = .finalization
            providerPhase = .finalization
        case .shellContinuation:
            guard request.protocolVersion
                    == Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion,
                  request.shellContinuationCoordinate != nil,
                  request.toolHandles.isEmpty else {
                throw Phase2LiveInferenceHandlerError.invalidFinalization
            }
            promptPhase = .shellContinuation
            providerPhase = .shellContinuation
        }
        let prompt = try Phase2ProductionPromptCompiler().compile(.init(
            phase: promptPhase,
            userGoal: request.userGoal,
            canonicalContext: request.canonicalContext,
            evidenceIDs: request.evidenceIDs,
            conversationContext: request.phase == .finalization
                || request.phase == .shellContinuation
                ? request.conversationContext.map { context in
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
            } : nil
        ))

        let receiptState = Phase2ProviderConnectionEmissionState()
        let emitProviderDispatch: @Sendable () async throws -> Void = {
            guard await receiptState.beginDispatch() else {
                throw Phase2LiveInferenceHandlerError.providerConnectionUnavailable
            }
            try await emit(event(request, UInt64.max - 1, .providerDispatch))
            await receiptState.finishDispatch()
        }
        let emitConnectionReceipt: @Sendable (Phase2OpenAIChatConnectionReceipt)
            async throws -> Void = { receipt in
                guard await receiptState.begin() else {
                    throw Phase2LiveInferenceHandlerError.providerConnectionUnavailable
                }
                try await emit(event(
                    request,
                    UInt64.max,
                    .providerConnection(.init(
                        localAddress: receipt.localAddress,
                        localPort: receipt.localPort,
                        remoteAddress: receipt.remoteAddress,
                        remotePort: receipt.remotePort
                    ))
                ))
                await receiptState.finish()
            }

        switch request.phase {
        case .toolSelection:
            let selection = Phase2LiveToolSelectionAccumulator(
                offeredOperationsByHandleID: Dictionary(
                    uniqueKeysWithValues: request.toolHandles.map {
                        ($0.handleID, $0.operationID)
                    }
                )
            )
            try await executeChat(
                configuration,
                prompt,
                providerPhase,
                generationVariant,
                acceptsFinalizationProposalTools,
                { streamEvent in await selection.receive(streamEvent) },
                emitProviderDispatch,
                emitConnectionReceipt
            )
            let didFinishProviderDispatch = await receiptState.didFinishDispatch
            let didFinishProviderConnectionReceipt = await receiptState.didFinish
            guard !requiresProviderConnectionReceipt
                    || (didFinishProviderDispatch && didFinishProviderConnectionReceipt) else {
                throw Phase2LiveInferenceHandlerError.providerConnectionUnavailable
            }
            let (proposals, usage) = try await selection.result()
            for (index, proposal) in proposals.enumerated() {
                try await emit(event(
                    request,
                    UInt64(index + 1),
                    .toolProposal(
                        callID: proposal.opaqueCallID,
                        handleID: proposal.handleID,
                        functionName: proposal.functionName,
                        operationID: proposal.operationID
                    )
                ))
            }
            var terminalSequence = UInt64(proposals.count + 1)
            if emitsProviderUsage {
                try await emit(event(
                    request,
                    terminalSequence,
                    .usage(wireUsage(usage))
                ))
                terminalSequence += 1
            }
            try await emit(event(request, terminalSequence, .awaitingTools))

        case .finalization:
            let content = Phase2LiveContentAccumulator(
                acceptsProposalTools: request.protocolVersion
                    >= Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion
            )
            try await executeChat(
                configuration,
                prompt,
                providerPhase,
                generationVariant,
                acceptsFinalizationProposalTools,
                { streamEvent in await content.receive(streamEvent) },
                emitProviderDispatch,
                emitConnectionReceipt
            )
            let didFinishProviderDispatch = await receiptState.didFinishDispatch
            let didFinishProviderConnectionReceipt = await receiptState.didFinish
            guard !requiresProviderConnectionReceipt
                    || (didFinishProviderDispatch && didFinishProviderConnectionReceipt) else {
                throw Phase2LiveInferenceHandlerError.providerConnectionUnavailable
            }
            let (contentData, usage, shellProposals, debuggerProposals) = try await content.result()
            let candidate: Phase2GroundedFinalOutput
            if contentData.isEmpty, !shellProposals.isEmpty || !debuggerProposals.isEmpty {
                candidate = .insufficientEvidence(
                    text: "The provider returned an action proposal without a grounded final answer."
                )
            } else {
                candidate = try Phase2GroundedFinalDecoder().decode(
                    contentData,
                    allowedEvidenceIDs: Set(request.evidenceIDs),
                    proposalOperations: Phase2GroundedFinalProposal.operations(inUserGoal: request.userGoal)
                )
            }
            let kind: Phase2AIWorkerWireFinalKind
            let text: String
            let evidenceIDs: [UUID]
            switch candidate {
            case .answer(let answer, let citations):
                kind = .answer
                text = answer
                evidenceIDs = citations
            case .insufficientEvidence(let reason):
                kind = .insufficientEvidence
                text = reason
                evidenceIDs = []
            }
            var nextSequence: UInt64 = 1
            for proposal in shellProposals {
                try await emit(event(request, nextSequence, .shellProposal(proposal)))
                nextSequence += 1
            }
            for proposal in debuggerProposals {
                try await emit(event(request, nextSequence, .debuggerActionProposal(proposal)))
                nextSequence += 1
            }
            try await emit(event(
                request,
                nextSequence,
                .finalCandidate(kind: kind, text: text, evidenceIDs: evidenceIDs)
            ))
            nextSequence += 1
            if emitsProviderUsage {
                try await emit(event(request, nextSequence, .usage(wireUsage(usage))))
                nextSequence += 1
                try await emit(event(request, nextSequence, .completed))
            } else {
                try await emit(event(request, nextSequence, .completed))
            }
        case .shellContinuation:
            let content = Phase2LiveContentAccumulator(acceptsProposalTools: false)
            try await executeChat(
                configuration, prompt, providerPhase, generationVariant, false,
                { streamEvent in await content.receive(streamEvent) },
                emitProviderDispatch, emitConnectionReceipt
            )
            let didFinishProviderDispatch = await receiptState.didFinishDispatch
            let didFinishProviderConnectionReceipt = await receiptState.didFinish
            guard !requiresProviderConnectionReceipt
                    || (didFinishProviderDispatch && didFinishProviderConnectionReceipt) else {
                throw Phase2LiveInferenceHandlerError.providerConnectionUnavailable
            }
            let (contentData, usage, shellProposals, debuggerProposals) = try await content.result()
            guard shellProposals.isEmpty, debuggerProposals.isEmpty else {
                throw Phase2LiveInferenceHandlerError.invalidFinalization
            }
            let candidate = try Phase2GroundedFinalDecoder().decode(
                contentData,
                allowedEvidenceIDs: Set(request.evidenceIDs)
            )
            let body: Phase2AIWorkerWireEventBody = switch candidate {
            case .answer(let answer, let citations):
                .finalCandidate(kind: .answer, text: answer, evidenceIDs: citations)
            case .insufficientEvidence(let reason):
                .finalCandidate(kind: .insufficientEvidence, text: reason, evidenceIDs: [])
            }
            try await emit(event(request, 1, body))
            try await emit(event(request, 2, .usage(wireUsage(usage))))
            try await emit(event(request, 3, .completed))
        }
    }
}

private actor Phase2ProviderConnectionEmissionState {
    private var beganDispatch = false
    private(set) var didFinishDispatch = false
    private var began = false
    private(set) var didFinish = false

    func beginDispatch() -> Bool {
        guard !beganDispatch else { return false }
        beganDispatch = true
        return true
    }

    func finishDispatch() {
        guard beganDispatch else { return }
        didFinishDispatch = true
    }

    func begin() -> Bool {
        guard !began else { return false }
        began = true
        return true
    }

    func finish() {
        guard began else { return }
        didFinish = true
    }
}

private actor Phase2LiveContentAccumulator {
    private static let maximumEnvelopeBytes = Phase2GroundedFinalDecoder.maximumEnvelopeBytes
    private var data = Data()
    private var overflowed = false
    private var invalid = false
    private var sawDone = false
    private var usage: Phase2OpenAIChatUsage?
    private var shellProposals: [Phase2OpenAIShellProposalToolCall] = []
    private var debuggerActionProposals: [Phase2OpenAIDebuggerActionProposalToolCall] = []

    private let acceptsProposalTools: Bool

    init(acceptsProposalTools: Bool) {
        self.acceptsProposalTools = acceptsProposalTools
    }

    func receive(_ event: Phase2OpenAIChatStreamEvent) {
        switch event {
        case .contentDelta(let value):
            guard usage == nil, !sawDone else {
                invalid = true
                return
            }
            append(value)
        case .reasoningProgress:
            if usage != nil || sawDone { invalid = true }
        case .finished:
            break
        case .usage(let value):
            guard usage == nil, !sawDone else {
                invalid = true
                return
            }
            usage = value
        case .done:
            guard !sawDone else {
                invalid = true
                return
            }
            sawDone = true
        case .shellProposal(let proposal):
            guard acceptsProposalTools, usage == nil, !sawDone, shellProposals.count < 1 else {
                invalid = true
                return
            }
            shellProposals.append(proposal)
        case .debuggerActionProposal(let proposal):
            guard acceptsProposalTools,
                  usage == nil,
                  !sawDone,
                  debuggerActionProposals.count < 1 else {
                invalid = true
                return
            }
            debuggerActionProposals.append(proposal)
        case .toolCall, .awaitingTools:
            invalid = true
        }
    }

    private func append(_ value: String) {
        guard !overflowed else { return }
        let bytes = Data(value.utf8)
        guard bytes.count <= Self.maximumEnvelopeBytes - data.count else {
            data.removeAll(keepingCapacity: false)
            overflowed = true
            return
        }
        data.append(bytes)
    }

    func result() throws -> (
        Data,
        Phase2OpenAIChatUsage,
        [Phase2AIWorkerWireShellProposal],
        [Phase2AIWorkerWireDebuggerActionProposal]
    ) {
        guard !invalid, !overflowed, sawDone, let usage else {
            throw Phase2LiveInferenceHandlerError.invalidFinalization
        }
        let shellProposals = shellProposals.map {
            Phase2AIWorkerWireShellProposal(
                proposalID: $0.proposalID,
                executablePath: $0.executablePath,
                arguments: $0.arguments,
                environment: $0.environment,
                workingDirectoryPath: $0.workingDirectoryPath,
                timeoutMilliseconds: $0.timeoutMilliseconds,
                maximumOutputBytes: $0.maximumOutputBytes,
                executionSurface: $0.executionSurface,
                requestedEffects: $0.requestedEffects
            )
        }
        let debuggerProposals = debuggerActionProposals.map {
            Phase2AIWorkerWireDebuggerActionProposal(
                proposalID: $0.proposalID,
                action: $0.action,
                sessionID: $0.sessionID,
                lifecycleRevision: $0.lifecycleRevision,
                stopRevision: $0.stopRevision,
                eventSequence: $0.eventSequence,
                requestedAuthority: $0.requestedAuthority
            )
        }
        return (data, usage, shellProposals, debuggerProposals)
    }
}

private actor Phase2LiveToolSelectionAccumulator {
    struct AuthorizedProposal: Sendable {
        let opaqueCallID: String
        let handleID: UUID
        let functionName: String
        let operationID: String
    }

    private let offeredOperationsByHandleID: [UUID: String]
    private var proposals: [AuthorizedProposal] = []
    private var callIDs: Set<[UInt8]> = []
    private var handleIDs: Set<UUID> = []
    private var invalid = false
    private var usage: Phase2OpenAIChatUsage?
    private var sawAwaitingTools = false

    init(offeredOperationsByHandleID: [UUID: String]) {
        self.offeredOperationsByHandleID = offeredOperationsByHandleID
    }

    func receive(_ event: Phase2OpenAIChatStreamEvent) {
        switch event {
        case .toolCall(let proposal):
            let registry = Phase2ProductionToolRegistry(version: .assistantR2)
            guard let registryEntry = registry.entry(forFunctionName: proposal.functionName),
                  let offeredOperation = offeredOperationsByHandleID[proposal.handleID],
                  offeredOperation == registryEntry.operationID,
                  !sawAwaitingTools,
                  proposals.count < Phase2AIWorkerWireLimits.maximum.maximumToolProposals,
                  callIDs.insert(Array(proposal.opaqueCallID.utf8)).inserted,
                  handleIDs.insert(proposal.handleID).inserted else {
                invalid = true
                return
            }
            proposals.append(.init(
                opaqueCallID: proposal.opaqueCallID,
                handleID: proposal.handleID,
                functionName: proposal.functionName,
                operationID: offeredOperation
            ))
        case .awaitingTools:
            guard !sawAwaitingTools else {
                invalid = true
                return
            }
            sawAwaitingTools = true
        case .usage(let value):
            guard usage == nil, !sawAwaitingTools else {
                invalid = true
                return
            }
            usage = value
        case .reasoningProgress:
            if usage != nil || sawAwaitingTools { invalid = true }
        case .contentDelta, .finished, .done, .shellProposal, .debuggerActionProposal:
            invalid = true
        }
    }

    func result() throws -> ([AuthorizedProposal], Phase2OpenAIChatUsage) {
        guard !invalid, let usage, sawAwaitingTools, !proposals.isEmpty else {
            throw Phase2LiveInferenceHandlerError.invalidToolSelection
        }
        return (proposals, usage)
    }
}

private func wireUsage(_ usage: Phase2OpenAIChatUsage) -> Phase2AIWorkerWireUsage {
    .init(
        promptTokens: usage.promptTokens,
        completionTokens: usage.completionTokens,
        totalTokens: usage.totalTokens
    )
}

private func event(
    _ request: Phase2AIWorkerWireRequest,
    _ sequence: UInt64,
    _ body: Phase2AIWorkerWireEventBody
) -> Phase2AIWorkerWireEvent {
    Phase2AIWorkerWireEvent(
        wireProtocol: request.wireProtocol,
        protocolVersion: request.protocolVersion,
        phase: request.phase,
        sessionID: request.sessionID,
        turnID: request.turnID,
        requestID: request.requestID,
        documentID: request.documentID,
        workspaceID: request.workspaceID,
        lifecycleRevision: request.lifecycleRevision,
        sequence: sequence,
        body: body
    )
}
