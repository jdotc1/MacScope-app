import Foundation

/// Captured when an editor opens. History sequence also fences review-selection-only undo,
/// which deliberately does not consume a new explicit review revision.
struct AnalystFindingEditToken: Equatable, Sendable {
    let identity: AnalystFindingRevisionIdentity
    let installationID: UUID
    let revisions: AnalystFindingRevisionVector
    let historySequence: Int
}

@MainActor
extension WorkspaceStore {
    func analystFindingEditToken(for findingID: UUID) throws -> AnalystFindingEditToken {
        guard let record = analystFindings.records.first(where: { $0.id == findingID }),
              record.workspaceID == workspaceID, record.documentID == documentID else {
            throw AnalystFindingError.wrongOwner
        }
        return .init(identity: record.revisionIdentity, installationID: documentInstallationID,
                     revisions: record.authoredLifecycle.state.vector,
                     historySequence: record.authoredLifecycle.history.count)
    }

    @discardableResult
    func editAnalystFinding(_ token: AnalystFindingEditToken, text: String) throws -> AnalystFindingRecord {
        try applyAnalystFindingRevision(.edit(text), token: token, actionName: "Edit Finding")
    }

    @discardableResult
    func reviewAnalystFinding(_ token: AnalystFindingEditToken,
                              decision: AnalystFindingReviewDecision) throws -> AnalystFindingRecord {
        try applyAnalystFindingRevision(.review(decision), token: token, actionName: "Review Finding")
    }

    /// Withdraws the finding. One undo step restores the prior standing; the authored text, the review
    /// and the cited facts are untouched. A retracted finding is frozen until the retraction is undone.
    @discardableResult
    func retractFinding(_ token: AnalystFindingEditToken, reason: String) throws -> AnalystFindingRecord {
        try applyAnalystFindingRevision(.retract(reason), token: token, actionName: "Retract Finding")
    }

    /// The analyst's decision to stand behind a stale finding again. Refused with
    /// `supportNotConfirmed` unless every citation is supported now. `source` replaces the live
    /// navigator state for this call and for the undo and redo of it; tests pass a hand-built one.
    @discardableResult
    func readmitAnalystFinding(_ token: AnalystFindingEditToken,
                               source: AnalystFindingSupportSource? = nil) throws -> AnalystFindingRecord {
        try applyAnalystFindingRevision(.readmit, token: token, actionName: "Readmit Finding", supportSource: source)
    }

    /// System action: records that cited evidence stopped supporting the finding. It is not an analyst
    /// edit, so it registers no undo step; the analyst's way back is `readmitAnalystFinding`.
    @discardableResult
    func markAnalystFindingStale(_ findingID: UUID, reason: AnalystFindingStaleReason) throws -> AnalystFindingRecord {
        try applyAnalystFindingRevision(.stale(reason), token: try analystFindingEditToken(for: findingID),
                                        actionName: "Mark Finding Stale")
    }

    // MARK: - semantic support

    /// The navigator state the support check reads: each analysed image's contract store and the identity
    /// its image has now.
    func analystFindingSupportSource() -> AnalystFindingSupportSource {
        var source = AnalystFindingSupportSource()
        for binary in snapshot.binaries {
            if let identity = navigatorImageIdentity(of: binary) {
                source.imageIdentities[binary.slot] = identity
            }
            if let state = navigatorState(for: binary.slot) { source.stores[binary.slot] = state }
        }
        return source
    }

    /// The string the navigator generation carries as `imageIdentity` for this image: the canonical image
    /// ref of its slice identity (`NavigatorSubjectRef.imageRef`, `uuid/sha-prefix16`), or the bridge's
    /// `slice:<sha256>` fallback for an image without an artifact identity. Read from the generation the
    /// bridge recorded at the last landing, else recomputed; nil for a slot without a binary or analysis
    /// (such a slot has no navigator state, so no citation into it can be checked).
    func navigatorImageIdentity(of binary: BinaryImage) -> String? {
        navigatorGenerations[binary.slot]?.imageIdentity ?? navigatorGeneration(for: binary.slot)?.imageIdentity
    }

    /// Compares the finding's cited facts with the navigator state: which are supported, which no longer
    /// exist, which went stale, and which contradict each other.
    func supportCheck(for record: AnalystFindingRecord, source: AnalystFindingSupportSource? = nil) -> SupportResult {
        AnalystFindingSupport.check(record.citations, source: source ?? analystFindingSupportSource())
    }

    func supportCheck(for findingID: UUID, source: AnalystFindingSupportSource? = nil) throws -> SupportResult {
        guard let record = analystFindings.records.first(where: { $0.id == findingID }),
              record.workspaceID == workspaceID, record.documentID == documentID else {
            throw AnalystFindingError.wrongOwner
        }
        return supportCheck(for: record, source: source)
    }

    // MARK: - invalidation hooks

    /// Call after the generation-fencing pass has marked facts `staleGeneration` in `slots`.
    @discardableResult
    func analystFindingsFactsFenced(in slots: Set<ImageSlot>,
                                    source: AnalystFindingSupportSource? = nil) -> [AnalystFindingStaleMark] {
        reconcileAnalystFindings(touching: slots, source: source)
    }

    /// Call after the image in `slot` was replaced, or reopened with a different identity.
    @discardableResult
    func analystFindingsImageIdentityChanged(in slot: ImageSlot,
                                             source: AnalystFindingSupportSource? = nil) -> [AnalystFindingStaleMark] {
        let source = source ?? analystFindingSupportSource()
        var applied: [AnalystFindingStaleMark] = []
        if let identity = source.imageIdentities[slot] {
            applied += applyAnalystFindingStaleMarks(AnalystFindingSupport.imageChangeMarks(
                in: analystFindings.records, slot: slot, currentIdentity: identity))
        }
        return applied + reconcileAnalystFindings(touching: [slot], source: source)
    }

    /// Call after an annotation in `slot` was reverted (`NavigatorContractStore.revert`).
    @discardableResult
    func analystFindingsAnnotationReverted(in slot: ImageSlot,
                                           source: AnalystFindingSupportSource? = nil) -> [AnalystFindingStaleMark] {
        reconcileAnalystFindings(touching: [slot], source: source)
    }

    /// Call once after a document has opened and both its findings and its navigator state are installed:
    /// an image that has another identity than the one a citation was made against, then every other
    /// citation the restored state no longer supports.
    @discardableResult
    func reconcileAnalystFindingsAfterOpen(source: AnalystFindingSupportSource? = nil) -> [AnalystFindingStaleMark] {
        let source = source ?? analystFindingSupportSource()
        var applied: [AnalystFindingStaleMark] = []
        for (slot, identity) in source.imageIdentities.sorted(by: { $0.key < $1.key }) {
            applied += applyAnalystFindingStaleMarks(AnalystFindingSupport.imageChangeMarks(
                in: analystFindings.records, slot: slot, currentIdentity: identity))
        }
        return applied + reconcileAnalystFindings(touching: nil, source: source)
    }

    /// Records a stale mark, including under retraction, when citations in `slots` (all slots when nil) the navigator state
    /// no longer supports. Returns the marks that were applied.
    @discardableResult
    func reconcileAnalystFindings(touching slots: Set<ImageSlot>? = nil,
                                  source: AnalystFindingSupportSource? = nil) -> [AnalystFindingStaleMark] {
        let source = source ?? analystFindingSupportSource()
        return applyAnalystFindingStaleMarks(AnalystFindingSupport.staleMarks(
            in: analystFindings.records, touching: slots, source: source))
    }

    private func applyAnalystFindingStaleMarks(_ marks: [AnalystFindingStaleMark]) -> [AnalystFindingStaleMark] {
        marks.filter { (try? markAnalystFindingStale($0.findingID, reason: $0.reason)) != nil }
    }

    /// Validation of the complete candidate (including immutable native snapshots) precedes
    /// publication, dirty state, or UndoManager registration. No live inference or source reads, except
    /// the navigator support check that gates a readmit and the redo of one.
    private func applyAnalystFindingRevision(_ operation: AnalystFindingHistoryOperation,
                                            token: AnalystFindingEditToken,
                                            actionName: String,
                                            supportSource: AnalystFindingSupportSource? = nil) throws -> AnalystFindingRecord {
        do {
            guard token.installationID == documentInstallationID,
                  token.identity.workspaceID == workspaceID, token.identity.documentID == documentID,
                  let record = analystFindings.records.first(where: { $0.id == token.identity.findingID }),
                  record.revisionIdentity == token.identity,
                  record.authoredLifecycle.history.count == token.historySequence else {
                throw AnalystFindingLifecycleError.staleEditor
            }
            if record.authoredLifecycle.clearsStaleness(operation),
               !supportCheck(for: record, source: supportSource).isFullySupported {
                throw AnalystFindingError.supportNotConfirmed
            }
            let lifecycle = try record.authoredLifecycle.applying(operation, identity: token.identity,
                initialText: record.content.candidateText, expected: token.revisions, now: Date())
            let revised = record.revising(with: lifecycle)
            var candidate = analystFindings
            try candidate.replace(revised, workspaceID: workspaceID, documentID: documentID)
            try Self.validateAnalystFindingsForRestore(candidate, workspaceID: workspaceID, documentID: documentID)

            let inverse: AnalystFindingHistoryOperation?
            switch operation.kind {
            case .edit, .review, .retract, .readmit: inverse = .undo(lifecycle.history.count)
            case .stale: inverse = nil
            case .undo:
                guard let target = operation.targetSequence else { throw AnalystFindingError.invalidContent }
                inverse = .redo(target)
            case .redo:
                guard let target = operation.targetSequence else { throw AnalystFindingError.invalidContent }
                inverse = .undo(target)
            }
            let manager = undoManager
            let needsGroup = inverse != nil && !manager.groupsByEvent && !manager.isUndoing && !manager.isRedoing
            if needsGroup { manager.beginUndoGrouping() }
            defer {
                if inverse != nil { manager.setActionName(actionName) }
                if needsGroup { manager.endUndoGrouping() }
            }
            // The manager's command stack supplies sequencing; the persisted per-finding stack
            // additionally rejects retired/out-of-order callbacks. A fresh vector is captured
            // only inside this owner after installation and command identity checks. A system
            // `stale` mark has no inverse and registers nothing.
            if let inverse {
                manager.registerUndo(withTarget: self) { store in
                    do {
                        guard store.documentInstallationID == token.installationID,
                              store.workspaceID == token.identity.workspaceID,
                              store.documentID == token.identity.documentID else { throw AnalystFindingError.wrongOwner }
                        let current = try store.analystFindingEditToken(for: token.identity.findingID)
                        _ = try store.applyAnalystFindingRevision(inverse, token: current, actionName: actionName,
                                                                  supportSource: supportSource)
                    } catch { store.publishAnalystFindingIssue(error.localizedDescription) }
                }
            }
            publishAnalystFindings(candidate)
            publishAnalystFindingIssue(nil)
            // Compensating events are new durable history, even when visible text is restored.
            // Do not rewind the dirty token to the baseline of an earlier serialized document.
            markDocumentMutated()
            return revised
        } catch {
            publishAnalystFindingIssue(error.localizedDescription)
            throw error
        }
    }
}
