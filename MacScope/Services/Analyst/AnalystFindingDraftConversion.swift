import Foundation

/// Lossless value conversion only. Reconstructing a saved request does not replay it, restore
/// runtime authority, refresh provider provenance, or make historical evidence current.
enum AnalystFindingDraftConversion {
    static func content(from draft: Phase2AssistantUnsavedDraft) throws -> AnalystFindingContentSnapshot {
        guard draft.originalRequest.groundedContext == draft.originalContext else { throw AnalystFindingError.invalidContent }
        let request = draft.originalRequest
        let limits = request.limits
        let snapshot = AnalystFindingContentSnapshot(originalRequest: .init(
            protocolVersion: request.protocolVersion.rawValue, phase: request.phase.rawValue,
            sessionID: request.sessionID, turnID: request.turnID, requestID: request.requestID,
            documentInstanceID: request.document.instanceID,
            workspaceDocumentInstanceID: request.workspace.document.instanceID,
            workspaceInstanceID: request.workspace.instanceID, lifecycleRevision: request.lifecycleRevision,
            userGoal: request.userGoal, groundedContext: context(request.groundedContext),
            toolHandles: request.toolHandles.map { .init(handleID: $0.handleID, operationID: $0.operationID.rawValue) },
            conversationContext: request.conversationContext.map { conversation in
                .init(turns: conversation.turns.map {
                    .init(conversationID: $0.conversationID, inferenceTurnID: $0.inferenceTurnID,
                        turnSequence: $0.turnSequence, user: $0.user, assistant: $0.assistant, isLegacy: $0.isLegacy)
                }, omittedTurnCount: conversation.omittedTurnCount)
            },
            shellContinuationCoordinate: try request.shellContinuationCoordinate.map {
                try JSONDecoder().decode(AnalystFindingContinuationSnapshot.self, from: JSONEncoder().encode($0))
            },
            limits: .init(maximumGoalBytes: limits.maximumGoalBytes, maximumEventBytes: limits.maximumEventBytes,
                maximumCumulativeEventBytes: limits.maximumCumulativeEventBytes, maximumEvents: limits.maximumEvents,
                maximumToolHandles: limits.maximumToolHandles, maximumToolProposals: limits.maximumToolProposals,
                maximumFinalTextBytes: limits.maximumFinalTextBytes, maximumEvidenceReferences: limits.maximumEvidenceReferences),
            maximumOutputTokens: request.maximumOutputTokens),
            candidateKind: draft.candidate.kind.rawValue, candidateText: draft.candidate.text,
            evidenceIDs: draft.candidate.evidenceIDs, runnerReportedProviderRevision: draft.runnerReportedProviderRevision,
            recompiledContext: context(draft.recompiledContext))
        let restored = try restoredValue(snapshot)
        guard restored.originalRequest == draft.originalRequest, restored.candidate == draft.candidate,
              restored.originalContext == draft.originalContext, restored.recompiledContext == draft.recompiledContext,
              restored.runnerReportedProviderRevision == draft.runnerReportedProviderRevision else {
            throw AnalystFindingError.invalidContent
        }
        return snapshot
    }

    static func initialRecord(from draft: Phase2AssistantUnsavedDraft, findingID: UUID,
                              workspaceID: UUID, documentID: UUID, now: Date,
                              citesFacts: [FactCitation] = []) throws -> AnalystFindingRecord {
        let content = try content(from: draft)
        let state = AnalystFindingRevisionState<AnalystFindingContentSnapshot, String>(
            identity: .init(findingID: findingID, workspaceID: workspaceID, documentID: documentID), content: content)
        return .init(id: state.identity.findingID, workspaceID: state.identity.workspaceID,
            documentID: state.identity.documentID, createdAt: now,
            contentRevision: state.revisions.content, reviewRevision: state.revisions.review, content: state.content,
            citesFacts: citesFacts)
    }

    /// Resolves the ids a navigator answer was derived from into citations. Each cited fact or annotation
    /// is found in `slot`'s state (every slot when nil), and the citation records the slot that knows it and
    /// the generation it carries now. An id nothing knows keeps a bare citation: the support check then
    /// reports it as unsupported rather than this conversion dropping it. Order is kept; repeats are folded.
    static func citations(derivedFrom ids: [String], in source: AnalystFindingSupportSource,
                          slot: ImageSlot?) -> [FactCitation] {
        var seen = Set<String>()
        var citations: [FactCitation] = []
        for id in ids where seen.insert(id).inserted {
            var found: FactCitation?
            for candidate in slot.map({ [$0] }) ?? source.slots {
                guard let store = source.stores[candidate] else { continue }
                if let fact = store.allFacts()[id] {
                    found = .init(id: id, generation: fact.generation, slot: candidate)
                } else if let annotation = store.annotations()[id] {
                    found = .init(id: id, generation: annotation.generation, slot: candidate)
                }
                if found != nil { break }
            }
            citations.append(found ?? .init(id: id, generation: nil, slot: slot))
        }
        return citations
    }

    static func validate(_ record: AnalystFindingRecord) throws {
        _ = try restoredValue(record.content)
        try record.validateRevisionState()
    }

    static func restoredValue(_ content: AnalystFindingContentSnapshot) throws -> Phase2AssistantUnsavedDraft {
        try content.validate()
        let source = content.originalRequest
        guard let phase = Phase2InferencePhase(rawValue: source.phase),
              let kind = Phase2InferenceFinalKind(rawValue: content.candidateKind) else { throw AnalystFindingError.invalidContent }
        let limits = source.limits
        let nativeLimits = Phase2InferenceLimits(maximumGoalBytes: limits.maximumGoalBytes,
            maximumEventBytes: limits.maximumEventBytes, maximumCumulativeEventBytes: limits.maximumCumulativeEventBytes,
            maximumEvents: limits.maximumEvents, maximumToolHandles: limits.maximumToolHandles,
            maximumToolProposals: limits.maximumToolProposals, maximumFinalTextBytes: limits.maximumFinalTextBytes,
            maximumEvidenceReferences: limits.maximumEvidenceReferences)
        guard nativeLimits.isValid, source.userGoal.utf8.count <= nativeLimits.maximumGoalBytes,
              content.candidateText.utf8.count <= nativeLimits.maximumFinalTextBytes,
              content.evidenceIDs.count <= nativeLimits.maximumEvidenceReferences,
              source.toolHandles.count <= nativeLimits.maximumToolHandles,
              source.maximumOutputTokens.map({ (1...16_384).contains($0) }) ?? true else { throw AnalystFindingError.invalidContent }
        if let conversation = source.conversationContext {
            guard conversation.omittedTurnCount >= 0, conversation.turns.count <= Phase2InferenceConversationContext.maximumTurns,
                  conversation.turns.allSatisfy({ $0.turnSequence > 0 }),
                  conversation.turns.reduce(0, { $0 + $1.user.utf8.count + $1.assistant.utf8.count })
                    <= Phase2InferenceConversationContext.maximumUTF8Bytes else { throw AnalystFindingError.invalidContent }
        }
        let context = try nativeContext(source.groundedContext)
        let request = Phase2InferenceRequest(protocolVersion: .init(rawValue: source.protocolVersion), phase: phase,
            sessionID: source.sessionID, turnID: source.turnID, requestID: source.requestID,
            document: .init(instanceID: source.documentInstanceID),
            workspace: .init(document: .init(instanceID: source.workspaceDocumentInstanceID), instanceID: source.workspaceInstanceID),
            lifecycleRevision: source.lifecycleRevision, userGoal: source.userGoal, groundedContext: context,
            toolHandles: source.toolHandles.map { .init(handleID: $0.handleID, operationID: .init(rawValue: $0.operationID)) },
            conversationContext: source.conversationContext.map { conversation in
                .init(turns: conversation.turns.map {
                    .init(conversationID: $0.conversationID, inferenceTurnID: $0.inferenceTurnID,
                        turnSequence: $0.turnSequence, user: $0.user, assistant: $0.assistant, isLegacy: $0.isLegacy)
                }, omittedTurnCount: conversation.omittedTurnCount)
            }, shellContinuationCoordinate: try source.shellContinuationCoordinate.map {
                try JSONDecoder().decode(Phase2AssistantShellContinuationCoordinate.self, from: JSONEncoder().encode($0))
            }, limits: nativeLimits, maximumOutputTokens: source.maximumOutputTokens)
        return .init(originalRequest: request,
            candidate: .init(kind: kind, text: content.candidateText, evidenceIDs: content.evidenceIDs),
            runnerReportedProviderRevision: content.runnerReportedProviderRevision, originalContext: context,
            recompiledContext: try nativeContext(content.recompiledContext))
    }

    private static func context(_ native: Phase2GroundedContext) -> AnalystFindingContextSnapshot {
        .init(manifest: .init(records: native.records, omissions: native.omissions),
              canonicalBytes: native.canonicalBytes, digest: native.digest)
    }
    private static func nativeContext(_ snapshot: AnalystFindingContextSnapshot) throws -> Phase2GroundedContext {
        try snapshot.validate()
        return .make(records: snapshot.manifest.records, omissions: snapshot.manifest.omissions,
                     canonicalBytes: snapshot.canonicalBytes, digest: snapshot.digest)
    }
}
