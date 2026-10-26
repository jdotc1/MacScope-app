import Foundation

/// Transient review surface; only explicit acceptance creates a document-owned record.
struct PendingAnalystFinding {
    let id: UUID
    let workspaceID: UUID
    let documentID: UUID
    let installationID: UUID
    let result: Phase2AssistantSessionResult
    let draft: Phase2AssistantUnsavedDraft
    let publicationToken: Phase2AssistantPublicationToken
    /// Contract facts the answer rests on, resolved when the finding was staged. Empty for an answer
    /// that cites none.
    let citations: [FactCitation]
}

@MainActor
extension WorkspaceStore {
    func dismissPendingAnalystFinding() {
        publishPendingAnalystFinding(nil)
        publishAnalystFindingIssue(nil)
    }

    /// `derivedFrom` names the contract facts (or annotations) the answer rests on, by id. They are resolved
    /// against the navigator state now, so each citation carries the generation it was written against.
    func stageAnalystFinding(from result: Phase2AssistantSessionResult,
                             publicationToken: Phase2AssistantPublicationToken,
                             derivedFrom: [String] = []) {
        dismissPendingAnalystFinding()
        guard result.isFullyGrounded, result.inferenceOutcome?.finalCandidate?.kind == .answer else { return }
        do {
            guard publicationToken.isCurrent(in: self) else { throw AnalystFindingError.staleDraft }
            let draft = try currentAnalystDraft(from: result)
            _ = try AnalystFindingDraftConversion.content(from: draft)
            let citations = AnalystFindingDraftConversion.citations(derivedFrom: derivedFrom,
                in: derivedFrom.isEmpty ? .init() : analystFindingSupportSource(), slot: nil)
            try FactCitation.validate(citations)
            publishPendingAnalystFinding(.init(id: UUID(), workspaceID: workspaceID, documentID: documentID,
                installationID: documentInstallationID, result: result, draft: draft,
                publicationToken: publicationToken, citations: citations))
        } catch { publishAnalystFindingIssue(error.localizedDescription) }
    }

    /// Rechecks the original trusted runner result through the existing native compiler.
    /// Staging, rejecting and failed acceptance do not alter document state.
    @discardableResult
    func acceptPendingAnalystFinding() throws -> AnalystFindingRecord {
        guard let pending = pendingAnalystFinding else { throw AnalystFindingError.staleDraft }
        do {
            guard pending.workspaceID == workspaceID, pending.documentID == documentID,
                  pending.installationID == documentInstallationID,
                  pending.publicationToken.isCurrent(in: self) else { throw AnalystFindingError.staleDraft }
            let current = try currentAnalystDraft(from: pending.result)
            let content = try AnalystFindingDraftConversion.content(from: current)
            guard content == (try AnalystFindingDraftConversion.content(from: pending.draft)) else {
                throw AnalystFindingError.staleDraft
            }
            if let prior = analystFindings.records.first(where: {
                $0.content.originalRequest.requestID == content.originalRequest.requestID
            }) {
                guard prior.content == content else { throw AnalystFindingError.duplicateRequestConflict }
                dismissPendingAnalystFinding()
                return prior
            }
            // A finding may not start from evidence that is already gone or stale. Facts that contradict each
            // other are accepted; `supportCheck` keeps reporting both citations.
            if !pending.citations.isEmpty,
               AnalystFindingSupport.check(pending.citations, source: analystFindingSupportSource()).invalidates {
                throw AnalystFindingError.supportNotConfirmed
            }
            let record = try AnalystFindingDraftConversion.initialRecord(from: current, findingID: pending.id,
                workspaceID: workspaceID, documentID: documentID, now: Date(), citesFacts: pending.citations)
            var candidate = analystFindings
            try candidate.append(record, workspaceID: workspaceID, documentID: documentID)
            try AnalystFindingDraftConversion.validate(record)
            publishAnalystFindings(candidate)
            dismissPendingAnalystFinding()
            markDocumentMutated()
            return record
        } catch {
            publishAnalystFindingIssue(error.localizedDescription)
            throw error
        }
    }

    private func currentAnalystDraft(from result: Phase2AssistantSessionResult) throws -> Phase2AssistantUnsavedDraft {
        var states: [UUID: Phase2ReadCurrentState] = [:]
        for record in result.groundedContext?.records ?? [] {
            states[record.evidenceID] = phase2ReadCurrentState(for: record.precondition.image?.slot)
        }
        return try Phase2AssistantUnsavedDraftAdapter.make(result: result, currentStateByEvidenceID: states)
    }

    func persistableAnalystFindings() throws -> AnalystFindingEnvelope? {
        try Self.validateAnalystFindingsForRestore(analystFindings, workspaceID: workspaceID, documentID: documentID)
        return analystFindings.isEmpty ? nil : analystFindings
    }

    static func validateAnalystFindingsForRestore(_ envelope: AnalystFindingEnvelope,
                                                 workspaceID: UUID, documentID: UUID) throws {
        try envelope.validate(workspaceID: workspaceID, documentID: documentID)
        for record in envelope.records { try AnalystFindingDraftConversion.validate(record) }
    }

    /// Called by package restore only after complete validation and owner installation. Historical
    /// runtime identities remain archived provenance; they never enter the live evidence ledger.
    func installValidatedAnalystFindings(_ envelope: AnalystFindingEnvelope) {
        publishAnalystFindings(envelope)
        dismissPendingAnalystFinding()
    }
}
