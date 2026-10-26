import Foundation

extension ReconstructionEvidenceReadAuthority {
    static func capture(request: ReconstructionToolRequestEnvelope,
        result: ReconstructionToolProjectionResult, cut: ReconstructionEvidenceCut) throws -> Self {
        guard let query = request.retrievalQuery, request.operationID == .evidenceQuery,
              request.authority.corpusManifestSHA256 == cut.corpusManifestSHA256,
              request.authority.evidenceFrontierSHA256 == cut.frontierSHA256,
              result.evidenceCandidates.isEmpty, result.diagnostic == nil else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        let packet = try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)
        guard result.payload == packet.canonicalBytes,
              result.payloadSHA256 == packet.canonicalSHA256,
              result.itemCount == packet.records.count,
              result.outcome == (packet.hasMore ? .truncated : .success) else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        if packet.hasMore {
            guard let cursor = packet.nextCursor else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
            }
            let next = try copy(query, cursor: cursor)
            let expected = ReconstructionToolRequest(operationID: .evidenceQuery,
                taskID: request.taskID, subject: request.subject, retrievalQuery: next, offset: 1,
                maximumRecords: next.maximumRecords, maximumEncodedBytes: next.maximumEncodedBytes)
            guard result.continuationRequest == expected else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
            }
        } else if result.continuationRequest != nil {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        return try .init(request: request, packetSHA256: packet.canonicalSHA256,
            readEvidenceIDs: packet.records.map(\.evidenceID), nextCursor: packet.nextCursor)
    }

    /// Reissue under the caller's current authority when the old frontier or query is no longer
    /// admissible. Never replay an old cursor against a changed cut.
    func successorQuery(cut: ReconstructionEvidenceCut,
        defaultQuery: ReconstructionRetrievalQuery) throws -> ReconstructionRetrievalQuery {
        try resolveSuccessor(cut: cut, defaultQuery: defaultQuery).query
    }

    /// Resolve the only admissible successor read for this committed authority cut.
    ///
    /// A retained cursor is admissible only when the corpus manifest (artifact bytes) and the
    /// canonical query identity (including the exact focus image binding) are unchanged, and the
    /// complete evidence frontier (records, classifications, checkpoint revisions, relations and
    /// gaps) is either unchanged or a proven append-only extension whose additions all sort after
    /// the already-delivered prefix (see `rebasedSuccessor`). Otherwise the successor restarts at
    /// offset zero and states why; it never serves a stale page or skips a record. A qualified read
    /// that reached the end of its query retains the final page and reports explicit end of
    /// coverage rather than restarting or claiming completeness.
    func resolveSuccessor(cut: ReconstructionEvidenceCut,
        defaultQuery: ReconstructionRetrievalQuery) throws -> ReconstructionEvidenceReadSuccessor {
        try validate()
        guard let original = request.retrievalQuery else {
            throw ReconstructionEvidenceReadAuthorityError.invalidDescriptor
        }
        guard request.authority.corpusManifestSHA256 == cut.corpusManifestSHA256,
              original.corpusManifestSHA256 == defaultQuery.corpusManifestSHA256 else {
            return .init(query: defaultQuery, outcome: .restarted(.corpusManifestChanged))
        }
        guard request.authority.evidenceFrontierSHA256 == cut.frontierSHA256 else {
            return try rebasedSuccessor(cut: cut, original: original, defaultQuery: defaultQuery)
        }
        guard try ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(original)
                == ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(defaultQuery) else {
            return .init(query: defaultQuery, outcome: .restarted(.queryIdentityChanged))
        }
        let packet = try ReconstructionRetrievalCompiler().compile(cut: cut, query: original)
        guard packet.canonicalSHA256 == packetSHA256,
              packet.records.map(\.evidenceID) == readEvidenceIDs,
              packet.nextCursor == nextCursor else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        // An exhausted read retains the selected last page in later context instead of restarting.
        let query = try Self.copy(original, cursor: nextCursor ?? original.cursor,
            maximumRecords: min(original.maximumRecords, defaultQuery.maximumRecords),
            maximumEncodedBytes: min(original.maximumEncodedBytes, defaultQuery.maximumEncodedBytes))
        return .init(query: query, outcome: nextCursor == nil ? .endOfCoverage : .nextPage)
    }

    /// Resolve a retained read whose evidence frontier differs from the current cut.
    ///
    /// The cursor is rebased only when all of the following are proven from committed data:
    ///
    /// 1. Append-only frontier. The prior frontier is reconstructed from the current cut by
    ///    removing exactly the records this job created at checkpoint revisions after the read's
    ///    authority revision (and any relation touching them). Everything else, including the
    ///    current projected classifications, payload digests, supersession links, gaps, other
    ///    jobs' records and checkpoint revisions, is kept verbatim. That subset must hash to the
    ///    read's committed `evidenceFrontierSHA256`. SHA-256 binds the complete canonical frontier,
    ///    so a match proves that nothing the read was authorized against was removed, rewritten,
    ///    reclassified or superseded and that the only differences are this job's later records.
    ///    Any other difference (removal, reclassification, new gap or relation between prior
    ///    records, another job's record) fails the digest and restarts with
    ///    `evidenceFrontierChanged`.
    /// 2. Authentic read. The retained query recompiled over the reconstructed prior cut must
    ///    reproduce the committed packet digest, record IDs and next cursor; a mismatch is a
    ///    tampered read and throws, exactly as for an unchanged frontier.
    /// 3. Unchanged delivered prefix. The canonical order of the current cut, up to and including
    ///    the last record this query chain delivered, must equal the prior order up to the same
    ///    record. Ordering keys are functions of digest-bound fields, so prior records keep their
    ///    relative order; this check additionally proves no appended record sorts at or before
    ///    the delivered boundary. Otherwise the successor restarts with
    ///    `evidenceInsertedBeforeCursor` so the inserted record is delivered, never skipped.
    ///
    /// The rebased cursor is minted by the compiler at the boundary's position in the current cut;
    /// no stale cursor is ever replayed and no model-supplied claim is consulted.
    private func rebasedSuccessor(cut: ReconstructionEvidenceCut,
        original: ReconstructionRetrievalQuery,
        defaultQuery: ReconstructionRetrievalQuery) throws -> ReconstructionEvidenceReadSuccessor {
        let frontierChanged = ReconstructionEvidenceReadSuccessor(query: defaultQuery,
            outcome: .restarted(.evidenceFrontierChanged))
        let priorFrontierSHA256 = request.authority.evidenceFrontierSHA256
        guard try ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(original)
                == ReconstructionToolRegistry.canonicalRetrievalQueryIdentitySHA256(defaultQuery),
              let priorCut = try Self.appendOnlyPriorCut(of: cut, jobID: request.authority.jobID,
                throughRevision: request.authority.checkpointRevision,
                priorFrontierSHA256: priorFrontierSHA256) else {
            return frontierChanged
        }
        let compiler = ReconstructionRetrievalCompiler()
        let packet = try compiler.compile(cut: priorCut, query: original)
        guard packet.canonicalSHA256 == packetSHA256,
              packet.records.map(\.evidenceID) == readEvidenceIDs,
              packet.nextCursor == nextCursor else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        let prior = try compiler.orderedPositions(cut: priorCut, query: original)
        let current = try compiler.orderedPositions(cut: cut, query: original)
        // The last delivered position of this query chain. Nothing delivered means offset zero
        // is the exact continuation.
        guard let boundary = nextCursor?.evidenceID ?? readEvidenceIDs.last
                ?? original.cursor?.evidenceID,
              let boundaryIndex = prior.firstIndex(where: { $0.evidenceID == boundary }) else {
            return frontierChanged
        }
        if let nextCursor, prior[boundaryIndex] != nextCursor {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        guard current.count > boundaryIndex,
              current[...boundaryIndex].map(\.evidenceID) == prior[...boundaryIndex].map(\.evidenceID)
        else {
            return .init(query: defaultQuery, outcome: .restarted(.evidenceInsertedBeforeCursor))
        }
        for index in 0...boundaryIndex
        where !Self.samePosition(prior[index], current[index]) {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        let maximumRecords = min(original.maximumRecords, defaultQuery.maximumRecords)
        let maximumEncodedBytes = min(original.maximumEncodedBytes, defaultQuery.maximumEncodedBytes)
        if nextCursor == nil, current.count == prior.count {
            // No admitted record was appended to this query: its coverage is unchanged and
            // complete. Retain the final page at the rebased form of its own cursor.
            let retained = original.cursor.flatMap { cursor in
                prior.firstIndex(where: { $0.evidenceID == cursor.evidenceID }).map { current[$0] }
            }
            guard (original.cursor == nil) == (retained == nil) else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
            }
            return .init(query: try Self.copy(original, cursor: retained,
                maximumRecords: maximumRecords, maximumEncodedBytes: maximumEncodedBytes),
                outcome: .endOfCoverage)
        }
        return .init(query: try Self.copy(original, cursor: current[boundaryIndex],
            maximumRecords: maximumRecords, maximumEncodedBytes: maximumEncodedBytes),
            outcome: .rebased(fromFrontierSHA256: priorFrontierSHA256))
    }

    /// The evidence cut the read was authorized against, reconstructed from `cut` by removing only
    /// this job's records created after `revision`, or nil when that subset does not hash to the
    /// committed prior frontier (so the change is not a proven append).
    static func appendOnlyPriorCut(of cut: ReconstructionEvidenceCut, jobID: UUID,
        throughRevision revision: UInt64,
        priorFrontierSHA256: String) throws -> ReconstructionEvidenceCut? {
        var appended: Set<UUID> = []
        for record in cut.records where record.creatingJobID == jobID {
            guard let created = cut.checkpointRevisionsByID[record.creatingCheckpointID] else {
                return nil
            }
            if created > revision { appended.insert(record.evidenceID) }
        }
        guard !appended.isEmpty else { return nil }
        let records = cut.records.filter { !appended.contains($0.evidenceID) }
        let relations = cut.relations.filter {
            !appended.contains($0.sourceEvidenceID) && !appended.contains($0.targetEvidenceID)
        }
        let classifications = cut.projectedClassificationsByEvidenceID.filter {
            !appended.contains($0.key)
        }
        let checkpointIDs = Set(records.map(\.creatingCheckpointID))
        let revisions = cut.checkpointRevisionsByID.filter { checkpointIDs.contains($0.key) }
        let digest: String
        do {
            digest = try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: cut.corpusManifestSHA256, records: records,
                projectedClassificationsByEvidenceID: classifications, relations: relations,
                gaps: cut.gaps, checkpointRevisionsByID: revisions)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard digest == priorFrontierSHA256 else { return nil }
        return try ReconstructionEvidenceCut(corpusManifestSHA256: cut.corpusManifestSHA256,
            records: records, relations: relations, gaps: cut.gaps, frontierSHA256: digest,
            projectedClassificationsByEvidenceID: classifications,
            checkpointRevisionsByID: revisions)
    }

    /// Same ordering position (every key field) in two cuts; only the frontier fence differs.
    private static func samePosition(_ lhs: ReconstructionRetrievalCursor,
        _ rhs: ReconstructionRetrievalCursor) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.corpusManifestSHA256 == rhs.corpusManifestSHA256
            && lhs.queryIdentitySHA256 == rhs.queryIdentitySHA256
            && lhs.currentBucket == rhs.currentBucket
            && lhs.subjectSpecificity == rhs.subjectSpecificity
            && lhs.operationPriority == rhs.operationPriority
            && lhs.canonicalSubjectIdentity == rhs.canonicalSubjectIdentity
            && lhs.checkpointRevision == rhs.checkpointRevision
            && lhs.evidenceID == rhs.evidenceID
    }

}

/// Why a retained evidence-read continuation could not be resumed at the current authority cut.
enum ReconstructionEvidenceReadRestartReason: String, Hashable, Sendable {
    /// The committed corpus manifest changed, so artifact bytes or image identity may differ.
    case corpusManifestChanged
    /// Evidence, classifications, checkpoint revisions, relations or gaps changed.
    case evidenceFrontierChanged
    /// The canonical query (operations, classifications, subject or focus image binding) changed.
    case queryIdentityChanged
    /// The frontier is a proven append-only extension, but an appended record sorts at or before
    /// the already-delivered boundary. Continuing would skip it, so the query restarts.
    case evidenceInsertedBeforeCursor
}

/// Disposition of the selected prior read relative to the successor query.
enum ReconstructionEvidenceReadSuccessorOutcome: Hashable, Sendable {
    /// The retained cursor is admissible; the successor reads the next page.
    case nextPage
    /// The prior read was the final page of its query. The page is retained; no further page exists.
    case endOfCoverage
    /// The frontier grew append-only after the delivered prefix; the successor continues after
    /// the last delivered record with a cursor re-minted at the current frontier.
    case rebased(fromFrontierSHA256: String)
    /// The retained cursor is not admissible here; the successor restarts at offset zero.
    case restarted(ReconstructionEvidenceReadRestartReason)
}

struct ReconstructionEvidenceReadSuccessor: Hashable, Sendable {
    let query: ReconstructionRetrievalQuery
    let outcome: ReconstructionEvidenceReadSuccessorOutcome
}

/// Explicit continuation state of a prepared model round's evidence query. It is derived only
/// from committed, selected, receipt-qualified reads and is never persisted separately: the
/// durable authority remains `ReconstructionToolReceipt.evidenceReadAuthority`.
enum ReconstructionEvidenceReadContinuation: Hashable, Sendable {
    /// No qualified selected read exists; the round starts at offset zero.
    case initial
    case nextPage(sourceReceiptID: UUID)
    case endOfCoverage(sourceReceiptID: UUID)
    case rebased(sourceReceiptID: UUID, fromFrontierSHA256: String)
    case restarted(sourceReceiptID: UUID, reason: ReconstructionEvidenceReadRestartReason)

    init(sourceReceiptID: UUID, outcome: ReconstructionEvidenceReadSuccessorOutcome) {
        switch outcome {
        case .nextPage: self = .nextPage(sourceReceiptID: sourceReceiptID)
        case .endOfCoverage: self = .endOfCoverage(sourceReceiptID: sourceReceiptID)
        case .rebased(let frontier):
            self = .rebased(sourceReceiptID: sourceReceiptID, fromFrontierSHA256: frontier)
        case .restarted(let reason): self = .restarted(sourceReceiptID: sourceReceiptID, reason: reason)
        }
    }
}
