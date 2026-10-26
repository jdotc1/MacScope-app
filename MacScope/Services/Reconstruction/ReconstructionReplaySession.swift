import Foundation
import OSLog

/// One ready-coordinator admission. A session cannot exist without the product planner's exact
/// owner/job/task scope. It retains the original reply separately from the current replay result.
struct ReconstructionReplaySession: Sendable {
    private static let processSessionID = UUID()
    private static let logger = Logger(subsystem: "org.macscope.MacScope", category: "ReconstructionReplay")
    let scope: ReconstructionReplayScope
    let request: ReconstructionAIWorkerRequest
    let lease: Phase2ReadyInferenceLease
    let requestID: UUID
    let selectedModelIdentitySHA256: String
    let record: ReconstructionReplayRecord

    var isReplay: Bool { record.freshReply != nil }
    var provider: ReconstructionReplayInferenceProvider? {
        record.freshReply.map { .init(reply: $0, request: request) }
    }

    static func begin(request: ReconstructionAIWorkerRequest, lease: Phase2ReadyInferenceLease,
                      inventory: Phase2LocalModelInventory?) async throws -> Self? {
        guard let scope = ReconstructionReplayScope.current else { return nil }
        await ReconstructionResumeFaultInjection.shared.observeQuit()
        if case .sourceRevision(let source) = request, source.parentRevisionSHA256 != nil {
            ReconstructionResumeFaultInjection.shared.hit("repairAdmission")
        }
        let selectedModelIdentitySHA256 = try ReconstructionReplayModelIdentity.stableSelectedModelIdentity(
            lease: lease, inventory: inventory)
        let identity = try ReconstructionPromptReplayIdentity.make(request: request, lease: lease,
            jobID: scope.jobID, taskID: scope.taskID, logicalRoundIndex: scope.logicalRoundIndex,
            objectiveSHA256: scope.objectiveSHA256, toolRequests: scope.toolRequests,
            selectedModelIdentitySHA256: selectedModelIdentitySHA256)
        let prior = try await scope.owner.replayRecord(workspaceID: scope.workspaceID,
            jobID: scope.jobID, key: identity.key)
        if let prior, let reply = prior.freshReply {
            try prior.validate()
            guard prior.identity == identity else { throw ReconstructionReplayError.staleAdmission }
            let original = try decodeOriginal(reply, kind: identity.requestKind)
            guard try ReconstructionPromptReplayIdentity.make(request: original, lease: lease,
                jobID: scope.jobID, taskID: scope.taskID, logicalRoundIndex: scope.logicalRoundIndex,
                objectiveSHA256: scope.objectiveSHA256, toolRequests: scope.toolRequests,
            selectedModelIdentitySHA256: selectedModelIdentitySHA256) == identity else {
                throw ReconstructionReplayError.staleAdmission
            }
            let originalAuthority = try ReconstructionModelTerminalRequestAuthority.make(
                expectedRequestID: reply.terminalReceipt.requestID, request: original,
                terminalReceipt: reply.terminalReceipt)
            guard originalAuthority.requestIdentitySHA256 == reply.requestIdentitySHA256 else {
                throw ReconstructionReplayError.invalidRecord
            }
            // The exact original candidate passes the wire validator under its ORIGINAL request;
            // the replay provider and runner will separately validate its current binding.
            try ReconstructionReplayInferenceProvider.validate(reply.candidate,
                request: original, requestID: reply.terminalReceipt.requestID)
            // One completed provider call keeps one receipt identity. Its eventual committed
            // receipt binds the recovered request/checkpoint; no original uncommitted completion
            // receipt or fresh worker dispatch is invented by this replay admission.
            return .init(scope: scope, request: request, lease: lease, requestID: reply.terminalReceipt.requestID,
                selectedModelIdentitySHA256: selectedModelIdentitySHA256, record: prior)
        }
        // A key miss is ordinarily a new prompt. But when this exact semantic request already
        // has a recorded reply under a different selected model, the job cannot replay it under
        // the current model and a fresh call would silently fork the round. Fail it once, typed.
        if prior?.freshReply == nil, try await scope.owner.hasRecordedReplyUnderDifferentModel(
            workspaceID: scope.workspaceID, jobID: scope.jobID, current: identity, request: request) {
            Self.logger.error("Replay admission rejected: recorded reply belongs to a different model")
            throw ReconstructionReplayError.modelChanged
        }
        if prior?.freshReply == nil, let differences = try? await scope.owner.replayMissDiagnostic(
            workspaceID: scope.workspaceID, jobID: scope.jobID, current: identity, request: request, lease: lease,
            scope: scope, selectedModelIdentitySHA256: selectedModelIdentitySHA256), !differences.isEmpty {
            for difference in differences {
                Self.logger.error("Replay key miss against published reply: \(difference, privacy: .public)")
            }
        }
        let requestID = UUID()
        let dispatch = ReconstructionReplayDispatch(requestID: requestID,
            processSessionID: processSessionID, dispatchedAt: Date(),
            previousRequestOutcomeUnknown: prior?.dispatches.last?.requestID)
        let next = ReconstructionReplayRecord(schemaVersion: ReconstructionReplayRecord.schemaVersion,
            identity: identity, dispatches: (prior?.dispatches ?? []) + [dispatch],
            freshReply: nil, latestObservation: nil, replayCount: 0)
        try await scope.owner.publishReplayRecord(workspaceID: scope.workspaceID, record: next, expected: prior)
        return .init(scope: scope, request: request, lease: lease, requestID: requestID,
            selectedModelIdentitySHA256: selectedModelIdentitySHA256, record: next)
    }

    func publish(authority: ReconstructionModelTerminalRequestAuthority,
                 candidate: ReconstructionReplayCandidate, usage: Phase2AIWorkerWireUsage,
                 provider: any ReconstructionInferenceProviding) async throws -> ReconstructionModelTerminalRequestAuthority {
        guard authority.expectedRequestID == requestID, authority.request == request,
              authority.terminalReceipt.status == .completed else { throw ReconstructionReplayError.invalidRecord }
        let reply: ReconstructionReplayFreshReply
        if let original = record.freshReply {
            reply = original
        } else {
            let attestation: ReconstructionReplayAttestation
            if let source = provider as? any ReconstructionReplayAttestationProviding {
                attestation = try await source.replayAttestation(requestID: requestID)
            } else { attestation = .notRequired }
            reply = .init(requestIdentitySHA256: authority.requestIdentitySHA256,
                originalRequestBytes: try request.replayEncodedRequest(), terminalReceipt: authority.terminalReceipt,
                candidate: candidate, usage: usage,
                modelIdentity: try .init(lease: lease, request: request, selectedModelIdentitySHA256: selectedModelIdentitySHA256), attestation: attestation,
                offeredHandles: request.replayHandles, publishedAt: Date())
        }
        let receipt = ReconstructionModelReplayReceipt(mode: isReplay ? .replayed : .fresh,
            idempotencyKey: try record.identity.key,
            canonicalPromptSHA256: record.identity.canonicalPromptSHA256,
            logicalRoundIndex: record.identity.logicalRoundIndex,
            modelIdentitySHA256: record.identity.modelIdentitySHA256,
            originalRequestID: reply.terminalReceipt.requestID, currentRequestID: requestID,
            originalReplySHA256: try reply.sha256, observedAt: Date(),
            previousRequestOutcomeUnknown: record.dispatches.last?.previousRequestOutcomeUnknown)
        guard record.replayCount < UInt64.max else { throw ReconstructionReplayError.journalFull }
        let completed = ReconstructionReplayRecord(schemaVersion: record.schemaVersion, identity: record.identity,
            dispatches: record.dispatches, freshReply: reply, latestObservation: receipt,
            replayCount: record.replayCount + (isReplay ? 1 : 0))
        try await scope.owner.publishReplayRecord(workspaceID: scope.workspaceID, record: completed, expected: record)
        if case .sourceRevision(let source) = request {
            ReconstructionResumeFaultInjection.shared.hit(source.parentRevisionSHA256 == nil
                ? "sourceReplyPublished" : "repairReplyPublished")
        } else if case .roundR2 = request {
            ReconstructionResumeFaultInjection.shared.hit("modelRound")
        }
        return try .make(expectedRequestID: requestID, request: request,
            terminalReceipt: authority.terminalReceipt, replayReceipt: receipt)
    }

    static func decodeOriginal(_ reply: ReconstructionReplayFreshReply, kind: String) throws -> ReconstructionAIWorkerRequest {
        let decoder = JSONDecoder()
        switch kind {
        case "sourceRevision": return .sourceRevision(try decoder.decode(ReconstructionSourceRevisionRequest.self, from: reply.originalRequestBytes))
        case "roundR2": return .roundR2(try decoder.decode(ReconstructionInferenceRoundRequestR2.self, from: reply.originalRequestBytes))
        case "finalSynthesisR2": return .finalSynthesisR2(try decoder.decode(ReconstructionFinalSynthesisRequestR2.self, from: reply.originalRequestBytes))
        default: throw ReconstructionReplayError.unsupportedRequest
        }
    }
}

protocol ReconstructionReplayAttestationProviding: Sendable {
    func replayAttestation(requestID: UUID) async throws -> ReconstructionReplayAttestation
}

/// Explicit replay adapter. It has no worker/process-receipt conformance and cannot masquerade as
/// a fresh provider or qualify another model round. Only volatile retry bindings are replaced.
struct ReconstructionReplayInferenceProvider: ReconstructionInferenceProviding {
    let reply: ReconstructionReplayFreshReply
    let request: ReconstructionAIWorkerRequest

    func cancel(requestID: UUID) async {}
    func runSourceRevision(requestID: UUID, request: ReconstructionSourceRevisionRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        guard self.request == .sourceRevision(request) else { throw ReconstructionReplayError.invalidScope }
        return try await run(requestID: requestID, emit: emit)
    }
    func runRound(requestID: UUID, request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        guard self.request.semanticRequest == .round(request) else { throw ReconstructionReplayError.invalidScope }
        return try await run(requestID: requestID, emit: emit)
    }
    func runRoundR2(requestID: UUID, request: ReconstructionInferenceRoundRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        guard self.request == .roundR2(request) else { throw ReconstructionReplayError.invalidScope }
        return try await run(requestID: requestID, emit: emit)
    }
    func runFinalSynthesis(requestID: UUID, request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        guard self.request.semanticRequest == .finalSynthesis(request) else { throw ReconstructionReplayError.invalidScope }
        return try await run(requestID: requestID, emit: emit)
    }
    func runFinalSynthesisR2(requestID: UUID, request: ReconstructionFinalSynthesisRequestR2,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        guard self.request == .finalSynthesisR2(request) else { throw ReconstructionReplayError.invalidScope }
        return try await run(requestID: requestID, emit: emit)
    }

    private func run(requestID: UUID,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void) async throws -> ReconstructionTerminalReceipt {
        try Task.checkCancellation()
        let candidate: ReconstructionReplayCandidate
        if case .round(let value) = reply.candidate {
            let old = Dictionary(uniqueKeysWithValues: reply.offeredHandles.map { ($0.handleID, $0.operationID) })
            let current = Dictionary(uniqueKeysWithValues: request.replayHandles.map { ($0.operationID, $0.handleID) })
            func rebind(_ handle: UUID) throws -> UUID {
                guard let operation = old[handle], let rebound = current[operation] else { throw ReconstructionReplayError.staleAdmission }
                return rebound
            }
            guard let roundID = request.replayRoundID else { throw ReconstructionReplayError.invalidScope }
            candidate = .round(.init(jobID: request.replayJobID,
                checkpointRevision: request.replayCheckpointRevision, roundID: roundID,
                selectedHandleIDs: try value.selectedHandleIDs.map(rebind), disposition: value.disposition,
                unresolvedGaps: value.unresolvedGaps, resolvedGaps: try value.resolvedGaps.map {
                    .init(gapID: $0.gapID, handleID: try rebind($0.handleID), evidenceID: $0.evidenceID)
                }))
        } else { candidate = reply.candidate }
        try Self.validate(candidate, request: request, requestID: requestID)
        try await emit(.init(requestID: requestID, sequence: 1, body: Self.body(candidate)))
        try await emit(.init(requestID: requestID, sequence: 2, body: .usage(reply.usage)))
        try await emit(.init(requestID: requestID, sequence: 3, body: .completed))
        return .init(requestID: requestID, jobID: request.replayJobID,
            checkpointRevision: request.replayCheckpointRevision, roundID: request.replayRoundID,
            status: .completed)
    }

    static func validate(_ candidate: ReconstructionReplayCandidate,
                         request: ReconstructionAIWorkerRequest, requestID: UUID) throws {
        let authority: ReconstructionAIWorkerAuthority
        switch request {
        case .sourceRevision(let value): authority = .sourceRevision(value)
        case .round(let value): authority = .round(value)
        case .roundR2(let value): authority = .roundR2(value)
        case .finalSynthesis(let value): authority = .finalSynthesis(value)
        case .finalSynthesisR2(let value): authority = .finalSynthesisR2(value)
        }
        _ = try Phase2ReconstructionAIWorkerWireCodec().encodeEvent(
            .init(requestID: requestID, sequence: 1, body: body(candidate)), authority: authority)
    }
    private static func body(_ candidate: ReconstructionReplayCandidate) -> ReconstructionAIWorkerEventBody {
        switch candidate {
        case .source(let value): .sourceCandidate(value)
        case .round(let value): .roundCandidate(value)
        case .final(let value): .finalCandidate(value)
        }
    }
}
