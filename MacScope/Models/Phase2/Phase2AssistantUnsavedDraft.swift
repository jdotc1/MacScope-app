import Foundation

/// Inert authored output from the trusted app-owned Assistant runner. It is neither a saved
/// finding nor an observation and provides no apply/save/publication capability.
struct Phase2AssistantUnsavedDraft: Sendable {
    let originalRequest: Phase2InferenceRequest
    let candidate: Phase2InferenceFinalCandidate
    /// Retained runner provenance only. The returned SessionResult contains no independently
    /// verifiable request/outcome/provider-lease attestation; do not infer one from this integer.
    let runnerReportedProviderRevision: UInt64
    let originalContext: Phase2GroundedContext
    /// Selected references recompiled against supplied current state. The original answer was
    /// generated from originalContext; it is not relabelled as generated from this smaller packet.
    let recompiledContext: Phase2GroundedContext
}

enum Phase2AssistantUnsavedDraftError: Error, Equatable, Sendable {
    case missingRequest
    case missingSourceContext
    case missingProviderRevision
    case invalidProviderRevision(UInt64)
    case unacceptedAnswer
    case requestPhaseMismatch
    case requestContextMismatch
    case requestOwnerMismatch(evidenceID: UUID?)
    case requestLifecycleMismatch(evidenceID: UUID)
    case invalidReferences
    case missingAcceptedEvidence(UUID)
    case conflictingAcceptedEvidence(UUID)
    case nativeRecordMismatch(UUID)
    case namedEvidenceOmitted(UUID)
}

/// Pure result mapping, with no invocation or persistence. Accepted evidence remains minted only
/// by the original app acceptor, and native compilation/freshness stays with the original compiler.
enum Phase2AssistantUnsavedDraftAdapter {
    static func make(result: Phase2AssistantSessionResult,
                     currentStateByEvidenceID: [UUID: Phase2ReadCurrentState]) throws -> Phase2AssistantUnsavedDraft {
        guard let request = result.request else { throw Phase2AssistantUnsavedDraftError.missingRequest }
        guard let source = result.groundedContext else { throw Phase2AssistantUnsavedDraftError.missingSourceContext }
        guard let provider = result.providerRevision else { throw Phase2AssistantUnsavedDraftError.missingProviderRevision }
        guard provider > 0 else { throw Phase2AssistantUnsavedDraftError.invalidProviderRevision(provider) }
        guard request.phase == .finalization else { throw Phase2AssistantUnsavedDraftError.requestPhaseMismatch }
        guard request.groundedContext == source else { throw Phase2AssistantUnsavedDraftError.requestContextMismatch }
        guard request.document == request.workspace.document else {
            throw Phase2AssistantUnsavedDraftError.requestOwnerMismatch(evidenceID: nil)
        }
        for record in source.records {
            guard record.precondition.workspace == request.workspace,
                  record.precondition.workspace.document == request.document else {
                throw Phase2AssistantUnsavedDraftError.requestOwnerMismatch(evidenceID: record.evidenceID)
            }
            guard record.precondition.workspaceRevision == request.lifecycleRevision else {
                throw Phase2AssistantUnsavedDraftError.requestLifecycleMismatch(evidenceID: record.evidenceID)
            }
        }
        guard let candidate = result.inferenceOutcome?.finalCandidate else {
            throw Phase2AssistantUnsavedDraftError.unacceptedAnswer
        }
        let ids = candidate.evidenceIDs
        guard request.limits.isValid, (1...Phase2GroundedContextLimits.maximum.maximumRecords).contains(ids.count),
              ids.count <= request.limits.maximumEvidenceReferences,
              Set(ids).count == ids.count,
              source.records.count <= Phase2GroundedContextLimits.maximum.maximumRecords else {
            throw Phase2AssistantUnsavedDraftError.invalidReferences
        }
        guard result.isFullyGrounded, candidate.kind == .answer,
              result.inferenceOutcome?.violation == nil else {
            throw Phase2AssistantUnsavedDraftError.unacceptedAnswer
        }

        var selected: [Phase2AcceptedEvidence] = []
        for id in ids {
            guard !source.omissions.contains(where: { $0.evidenceID == id }) else {
                throw Phase2AssistantUnsavedDraftError.namedEvidenceOmitted(id)
            }
            guard source.records.filter({ $0.evidenceID == id }).count == 1 else {
                throw Phase2AssistantUnsavedDraftError.conflictingAcceptedEvidence(id)
            }
            let executions = result.readExecutions.filter { $0.acceptedEvidence?.evidenceID == id }
            guard !executions.isEmpty else { throw Phase2AssistantUnsavedDraftError.missingAcceptedEvidence(id) }
            guard executions.count == 1, let execution = executions.first,
                  let evidence = execution.acceptedEvidence,
                  matches(execution, evidence: evidence),
                  result.readExecutions.filter({
                      $0.candidate.invocationID == evidence.invocationID || $0.outcome.invocationID == evidence.invocationID
                  }).count == 1 else {
                throw Phase2AssistantUnsavedDraftError.conflictingAcceptedEvidence(id)
            }
            // readExecution is a legacy/first-execution alias, not a second independent receipt.
            // If it names the selected provenance, it must be the very same native facts.
            if let alias = result.readExecution,
               alias.acceptedEvidence?.evidenceID == id || alias.candidate.invocationID == evidence.invocationID
                    || alias.outcome.invocationID == evidence.invocationID {
                guard alias.candidate == execution.candidate, alias.outcome == execution.outcome,
                      alias.acceptedEvidence == evidence else {
                    throw Phase2AssistantUnsavedDraftError.conflictingAcceptedEvidence(id)
                }
            }
            selected.append(evidence)
        }

        // Do not copy the compiler's canonical encoder or reimplement its freshness semantics.
        // All original compiler errors propagate; named omissions cannot become partial success.
        let compiled = try Phase2GroundedContextCompiler().compile(records: selected,
            currentStateByEvidenceID: currentStateByEvidenceID)
        for id in ids {
            guard !compiled.omissions.contains(where: { $0.evidenceID == id }),
                  let record = compiled.records.first(where: { $0.evidenceID == id }) else {
                throw Phase2AssistantUnsavedDraftError.namedEvidenceOmitted(id)
            }
            guard let original = source.records.first(where: { $0.evidenceID == id }), record == original else {
                throw Phase2AssistantUnsavedDraftError.nativeRecordMismatch(id)
            }
        }
        return .init(originalRequest: request, candidate: candidate,
            runnerReportedProviderRevision: provider, originalContext: source, recompiledContext: compiled)
    }

    private static func matches(_ execution: Phase2ReadExecution, evidence: Phase2AcceptedEvidence) -> Bool {
        let candidate = execution.candidate
        let outcome = execution.outcome
        return !candidate.cancelled
            && candidate.candidateID == evidence.candidateID && candidate.invocationID == evidence.invocationID
            && candidate.sequence == evidence.sequence
            && candidate.registryVersion == evidence.descriptor.registryVersion
            && candidate.operationID == evidence.descriptor.id
            && candidate.operationVersion == evidence.descriptor.operationVersion
            && candidate.producingPrincipal == evidence.producingPrincipal
            && candidate.precondition == evidence.precondition && candidate.citations == evidence.citations
            && candidate.data == evidence.data
            && outcome.invocationID == evidence.invocationID && outcome.sequence == evidence.sequence
            && outcome.disposition == .accepted && outcome.evidenceIDs == [evidence.evidenceID]
            && outcome.conflicts.isEmpty
    }
}
