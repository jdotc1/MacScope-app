import CryptoKit
import Foundation

/// Complete value cut consumed by the compiler. It deliberately contains no path, database,
/// store, projector callback, or mutable resolver authority.
struct ReconstructionRetrievalProjectionInput: Hashable, Codable, Sendable {
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let records: [ReconstructionEvidenceRecord]
    let projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification]
    let checkpointRevisionsByID: [UUID: UInt64]
    private let relations: [ReconstructionEvidenceRelation]
    private let gaps: [ReconstructionEvidenceGap]

    init(cut: ReconstructionEvidenceCut) throws {
        try self.init(
            corpusManifestSHA256: cut.corpusManifestSHA256,
            evidenceFrontierSHA256: cut.frontierSHA256,
            records: cut.records,
            projectedClassificationsByEvidenceID: cut.projectedClassificationsByEvidenceID,
            checkpointRevisionsByID: cut.checkpointRevisionsByID,
            relations: cut.relations,
            gaps: cut.gaps
        )
    }

    private init(
        corpusManifestSHA256: String,
        evidenceFrontierSHA256: String,
        records: [ReconstructionEvidenceRecord],
        projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification],
        checkpointRevisionsByID: [UUID: UInt64],
        relations: [ReconstructionEvidenceRelation],
        gaps: [ReconstructionEvidenceGap]
    ) throws {
        try Task.checkCancellation()
        let evidenceIDs = Set(records.map(\.evidenceID))
        let checkpointIDs = Set(records.map(\.creatingCheckpointID))
        guard Self.isCanonicalSHA256(corpusManifestSHA256),
              Self.isCanonicalSHA256(evidenceFrontierSHA256),
              evidenceIDs.count == records.count,
              Set(projectedClassificationsByEvidenceID.keys) == evidenceIDs,
              Set(checkpointRevisionsByID.keys) == checkpointIDs else {
            throw ReconstructionRetrievalError.invalidProjectionInput
        }
        do {
            _ = try ReconstructionEvidenceGraphIntegrity.validate(
                records: records,
                relations: relations,
                gapIDs: Set(gaps.map(\.gapID))
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReconstructionRetrievalError.invalidProjectionInput
        }
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard record.payloadByteCount == UInt64(record.payload.count),
                  Self.sha256(record.payload) == record.payloadSHA256 else {
                throw ReconstructionRetrievalError.invalidProjectionInput
            }
        }
        try Task.checkCancellation()
        let canonicalFrontierSHA256: String
        do {
            canonicalFrontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: corpusManifestSHA256,
                records: records,
                projectedClassificationsByEvidenceID: projectedClassificationsByEvidenceID,
                relations: relations,
                gaps: gaps,
                checkpointRevisionsByID: checkpointRevisionsByID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReconstructionRetrievalError.invalidProjectionInput
        }
        guard evidenceFrontierSHA256 == canonicalFrontierSHA256 else {
            throw ReconstructionRetrievalError.invalidProjectionInput
        }
        try Task.checkCancellation()
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.evidenceFrontierSHA256 = canonicalFrontierSHA256
        self.records = records.sorted {
            $0.evidenceID.uuidString.lowercased() < $1.evidenceID.uuidString.lowercased()
        }
        self.projectedClassificationsByEvidenceID = projectedClassificationsByEvidenceID
        self.checkpointRevisionsByID = checkpointRevisionsByID
        self.relations = relations.sorted {
            $0.relationID.uuidString.lowercased() < $1.relationID.uuidString.lowercased()
        }
        self.gaps = gaps.sorted {
            $0.gapID.uuidString.lowercased() < $1.gapID.uuidString.lowercased()
        }
        try Task.checkCancellation()
    }

    private enum CodingKeys: String, CodingKey {
        case corpusManifestSHA256
        case evidenceFrontierSHA256
        case records
        case projectedClassificationsByEvidenceID
        case checkpointRevisionsByID
        case relations
        case gaps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            corpusManifestSHA256: container.decode(
                String.self,
                forKey: .corpusManifestSHA256
            ),
            evidenceFrontierSHA256: container.decode(
                String.self,
                forKey: .evidenceFrontierSHA256
            ),
            records: container.decode(
                [ReconstructionEvidenceRecord].self,
                forKey: .records
            ),
            projectedClassificationsByEvidenceID: container.decode(
                [UUID: ReconstructionEvidenceClassification].self,
                forKey: .projectedClassificationsByEvidenceID
            ),
            checkpointRevisionsByID: container.decode(
                [UUID: UInt64].self,
                forKey: .checkpointRevisionsByID
            ),
            relations: container.decodeIfPresent(
                [ReconstructionEvidenceRelation].self,
                forKey: .relations
            ) ?? [],
            gaps: container.decodeIfPresent(
                [ReconstructionEvidenceGap].self,
                forKey: .gaps
            ) ?? []
        )
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReconstructionRetrievedEvidenceRecord: Hashable, Codable, Sendable {
    let record: ReconstructionEvidenceRecord
    let classification: ReconstructionEvidenceClassification
    let checkpointRevision: UInt64

    var evidenceID: UUID { record.evidenceID }
    var payload: Data { record.payload }
}

/// Typed marker for one record that cannot be delivered even on its own oversize page. The model
/// sees its identity and size; the evidence is never truncated and the cursor moves past it.
struct ReconstructionRetrievalRecordTooLarge: Hashable, Codable, Sendable {
    let evidenceID: UUID
    let encodedByteCount: Int
}

struct ReconstructionRetrievalPacket: Hashable, Sendable {
    /// One record larger than the query's page budget may still travel alone on a page flagged
    /// `oversizePage`, up to this hard cap. Above it, the page carries `recordTooLarge` instead.
    static let oversizePageHardCapBytes = 65_536
    let records: [ReconstructionRetrievedEvidenceRecord]
    let nextCursor: ReconstructionRetrievalCursor?
    let hasMore: Bool
    let canonicalBytes: Data
    let canonicalSHA256: String
    let encodedByteCount: Int
    var oversizePage = false
    var recordTooLarge: ReconstructionRetrievalRecordTooLarge?
    /// Canonical packet encoder invocations performed during selection and final emission.
    let selectionEncodingPassCount: Int
    /// Standalone canonical record encoder invocations performed during prefix accounting.
    let selectionRecordAccountingCount: Int
}

/// Deterministic, projection-only retrieval compiler.
struct ReconstructionRetrievalCompiler: Sendable {
    private struct OrderingKey: Hashable, Codable, Sendable {
        let currentBucket: Int
        let subjectSpecificity: Int
        let operationPriority: Int
        let canonicalSubjectIdentity: Data
        let checkpointRevision: UInt64
        let evidenceID: UUID
    }

    private struct Candidate: Sendable {
        let output: ReconstructionRetrievedEvidenceRecord
        let orderingKey: OrderingKey
    }

    private struct SelectedPrefix: Sendable {
        let count: Int
        let encodedByteCount: Int
        let nextCursor: ReconstructionRetrievalCursor?
        let hasMore: Bool
    }

    private struct QueryIdentityPreimage: Encodable {
        let schemaVersion: Int
        let domain: String
        let subject: ReconstructionDurableSubject?
        let focus: ReconstructionSubjectCoordinate?
        let operationIDs: [String]
        let classifications: [String]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, domain, subject, focus, operationIDs, classifications
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(domain, forKey: .domain)
            // Preserve the original preimage when no focus is supplied.
            try container.encodeIfPresent(subject, forKey: .subject)
            try container.encodeIfPresent(focus, forKey: .focus)
            try container.encode(operationIDs, forKey: .operationIDs)
            try container.encode(classifications, forKey: .classifications)
        }
    }

    private struct SubjectIdentityPreimage: Encodable {
        let schemaVersion: Int
        let domain: String
        let subject: ReconstructionDurableSubject
    }

    private struct PacketPreimage: Encodable {
        let schemaVersion: Int
        let domain: String
        let corpusManifestSHA256: String
        let evidenceFrontierSHA256: String
        let queryIdentitySHA256: String
        let requestCursor: ReconstructionRetrievalCursor?
        let records: [ReconstructionRetrievedEvidenceRecord]
        let nextCursor: ReconstructionRetrievalCursor?
        let hasMore: Bool
        /// Omitted unless set, so every ordinary page keeps its existing canonical bytes.
        var oversizePage: Bool? = nil
        var recordTooLarge: ReconstructionRetrievalRecordTooLarge? = nil
    }

    func compile(
        cut: ReconstructionEvidenceCut,
        query: ReconstructionRetrievalQuery
    ) throws -> ReconstructionRetrievalPacket {
        try compile(input: ReconstructionRetrievalProjectionInput(cut: cut), query: query)
    }

    /// Select ordinary evidence for the source envelope without granting source records ordinary
    /// query/tool authority. Validate the complete cut before excluding these evidence-only rows,
    /// so its canonical frontier, payload hashes, graph and projection fences remain authoritative.
    func compileSourceBase(
        cut: ReconstructionEvidenceCut,
        query: ReconstructionRetrievalQuery
    ) throws -> ReconstructionRetrievalPacket {
        try compile(input: ReconstructionRetrievalProjectionInput(cut: cut), query: query)
    }

    func compileSourceBase(
        input: ReconstructionRetrievalProjectionInput,
        query: ReconstructionRetrievalQuery
    ) throws -> ReconstructionRetrievalPacket {
        try compile(input: input, query: query)
    }

    private static let sourceEnvelopeOperations: Set<String> = [
        "reconstruction.source.oracle", "reconstruction.source.revision",
        "reconstruction.source.evaluate", "reconstruction.source.build", "reconstruction.source.behavior",
    ]

    func compile(
        input: ReconstructionRetrievalProjectionInput,
        query: ReconstructionRetrievalQuery
    ) throws -> ReconstructionRetrievalPacket {
        let (candidates, queryIdentitySHA256) = try remainingCandidates(input: input, query: query)
        return try packet(
            from: candidates,
            input: input,
            query: query,
            queryIdentitySHA256: queryIdentitySHA256
        )
    }

    /// Count the records this exact query can still select after its fenced cursor. The context
    /// compiler uses this for its repeated-ID wire reserve; source-channel rows are excluded by
    /// the same selection path as an emitted page.
    func remainingCandidateCount(
        input: ReconstructionRetrievalProjectionInput,
        query: ReconstructionRetrievalQuery
    ) throws -> Int {
        try remainingCandidates(input: input, query: query).candidates.count
    }

    private func remainingCandidates(
        input: ReconstructionRetrievalProjectionInput,
        query: ReconstructionRetrievalQuery
    ) throws -> (candidates: [Candidate], queryIdentitySHA256: String) {
        try Task.checkCancellation()
        guard query.corpusManifestSHA256 == input.corpusManifestSHA256 else {
            throw ReconstructionRetrievalError.queryCorpusMismatch
        }

        let queryIdentitySHA256 = try queryIdentity(for: query)
        if let cursor = query.cursor {
            guard cursorIsValid(
                cursor,
                input: input,
                queryIdentitySHA256: queryIdentitySHA256
            ) else {
                throw ReconstructionRetrievalError.cursorFenceMismatch
            }
        }

        var candidates = try orderedCandidates(input: input, query: query)
        if let cursor = query.cursor {
            guard let cursorIndex = candidates.firstIndex(where: {
                $0.output.evidenceID == cursor.evidenceID
            }), Self.cursor(cursor, matches: candidates[cursorIndex].orderingKey) else {
                throw ReconstructionRetrievalError.cursorFenceMismatch
            }
            candidates.removeFirst(cursorIndex + 1)
        }
        try Task.checkCancellation()
        return (candidates, queryIdentitySHA256)
    }

    /// Every record admitted by `query`'s filters, in canonical retrieval order. `query.cursor`
    /// is not consulted; callers apply (and fence) it.
    private func orderedCandidates(
        input: ReconstructionRetrievalProjectionInput,
        query: ReconstructionRetrievalQuery
    ) throws -> [Candidate] {
        let operationFilter = Set(query.operationIDs)
        let classificationFilter = Set(query.classifications)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(input.records.count)

        for record in input.records {
            try Task.checkCancellation()
            // A project cut also contains other jobs' source observations. Their dedicated
            // consumer owns selection; they cannot block or become ordinary read/tool results.
            // The complete projection input already validated their payloads and frontier.
            if Self.sourceEnvelopeOperations.contains(record.operationID) { continue }
            guard let operation = ReconstructionOperationID(rawValue: record.operationID) else {
                throw ReconstructionRetrievalError.unknownOperation(record.operationID)
            }
            guard let classification =
                    input.projectedClassificationsByEvidenceID[record.evidenceID],
                  let checkpointRevision =
                    input.checkpointRevisionsByID[record.creatingCheckpointID] else {
                throw ReconstructionRetrievalError.invalidProjectionInput
            }
            guard operationFilter.contains(operation),
                  classificationFilter.contains(classification),
                  query.includes(subject: record.subject) else {
                continue
            }
            let canonicalSubjectIdentity = try ReconstructionCanonicalJSON.encode(
                SubjectIdentityPreimage(
                    schemaVersion: 1,
                    domain: "reconstruction.durable-subject.v1",
                    subject: try Self.structuralSubject(record.subject)
                )
            )
            candidates.append(Candidate(
                output: ReconstructionRetrievedEvidenceRecord(
                    record: record,
                    classification: classification,
                    checkpointRevision: checkpointRevision
                ),
                orderingKey: OrderingKey(
                    currentBucket: classification == .acceptedCurrent ? 0 : 1,
                    subjectSpecificity: Self.subjectSpecificity(record.subject),
                    operationPriority: operation.priority,
                    canonicalSubjectIdentity: canonicalSubjectIdentity,
                    checkpointRevision: checkpointRevision,
                    evidenceID: record.evidenceID
                )
            ))
        }

        candidates.sort { Self.precedes($0.orderingKey, $1.orderingKey) }
        return candidates
    }

    /// The complete canonical position sequence of `query` over `cut`: every admitted record in
    /// retrieval order, each paired with the exact cursor this compiler mints at that position.
    /// `query.cursor` is ignored. This emits no evidence payload and grants no read authority;
    /// it exists so a retained cursor can be proven to occupy the same position in two cuts.
    func orderedPositions(
        cut: ReconstructionEvidenceCut,
        query: ReconstructionRetrievalQuery
    ) throws -> [ReconstructionRetrievalCursor] {
        let input = try ReconstructionRetrievalProjectionInput(cut: cut)
        guard query.corpusManifestSHA256 == input.corpusManifestSHA256 else {
            throw ReconstructionRetrievalError.queryCorpusMismatch
        }
        let queryIdentitySHA256 = try queryIdentity(for: query)
        return try orderedCandidates(input: input, query: query).map {
            makeCursor(for: $0.orderingKey, input: input, queryIdentitySHA256: queryIdentitySHA256)
        }
    }

    private func packet(
        from candidates: [Candidate],
        input: ReconstructionRetrievalProjectionInput,
        query: ReconstructionRetrievalQuery,
        queryIdentitySHA256: String
    ) throws -> ReconstructionRetrievalPacket {
        let candidateLimit = min(query.maximumRecords, candidates.count)
        let emptyHasMore = !candidates.isEmpty
        var packetEncodingPassCount = 0
        packetEncodingPassCount += 1
        let emptyPacketBytes = try encodePacket(
            records: [],
            input: input,
            query: query,
            queryIdentitySHA256: queryIdentitySHA256,
            nextCursor: nil,
            hasMore: emptyHasMore
        )
        try Task.checkCancellation()
        guard emptyPacketBytes.count <= query.maximumEncodedBytes else {
            throw ReconstructionRetrievalError.packetEnvelopeExceedsByteBudget
        }

        var selected = SelectedPrefix(
            count: 0,
            encodedByteCount: emptyPacketBytes.count,
            nextCursor: nil,
            hasMore: emptyHasMore
        )
        var selectedRecordByteCount = 0
        var recordAccountingCount = 0

        for index in 0..<candidateLimit {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let encodedRecordByteCount = try ReconstructionCanonicalJSON
                .encode(candidates[index].output).count
            recordAccountingCount += 1
            try Task.checkCancellation()

            let prospectiveCount = index + 1
            let prospectiveHasMore = prospectiveCount < candidates.count
            let prospectiveCursor = prospectiveHasMore
                ? makeCursor(
                    for: candidates[index].orderingKey,
                    input: input,
                    queryIdentitySHA256: queryIdentitySHA256
                )
                : nil
            packetEncodingPassCount += 1
            let prospectiveEnvelopeByteCount = try encodePacket(
                records: [],
                input: input,
                query: query,
                queryIdentitySHA256: queryIdentitySHA256,
                nextCursor: prospectiveCursor,
                hasMore: prospectiveHasMore
            ).count
            guard let prospectiveRecordByteCount = Self.addingWithoutOverflow(
                selectedRecordByteCount,
                encodedRecordByteCount
            ), let minimumPossiblePacketByteCount = Self.addingWithoutOverflow(
                emptyPacketBytes.count,
                prospectiveRecordByteCount,
                prospectiveCount - 1
            ), let prospectivePacketByteCount = Self.addingWithoutOverflow(
                prospectiveEnvelopeByteCount,
                prospectiveRecordByteCount,
                prospectiveCount - 1
            ) else {
                break
            }

            selectedRecordByteCount = prospectiveRecordByteCount
            if prospectivePacketByteCount <= query.maximumEncodedBytes {
                selected = SelectedPrefix(
                    count: prospectiveCount,
                    encodedByteCount: prospectivePacketByteCount,
                    nextCursor: prospectiveCursor,
                    hasMore: prospectiveHasMore
                )
            }
            if minimumPossiblePacketByteCount > query.maximumEncodedBytes {
                break
            }
        }

        if selected.count == 0, candidateLimit > 0, let first = candidates.first {
            return try oversizePacket(first: first, remaining: candidates.count, input: input, query: query,
                queryIdentitySHA256: queryIdentitySHA256, passCount: packetEncodingPassCount,
                accountingCount: recordAccountingCount)
        }
        try Task.checkCancellation()
        let records = candidates.prefix(selected.count).map(\.output)
        let canonicalBytes: Data
        if candidateLimit == 0 {
            canonicalBytes = emptyPacketBytes
        } else {
            packetEncodingPassCount += 1
            canonicalBytes = try encodePacket(
                records: records,
                input: input,
                query: query,
                queryIdentitySHA256: queryIdentitySHA256,
                nextCursor: selected.nextCursor,
                hasMore: selected.hasMore
            )
        }
        try Task.checkCancellation()
        guard canonicalBytes.count == selected.encodedByteCount,
              canonicalBytes.count <= query.maximumEncodedBytes else {
            throw ReconstructionRetrievalError.invalidProjectionInput
        }
        let canonicalSHA256 = Self.sha256(canonicalBytes)
        try Task.checkCancellation()
        return ReconstructionRetrievalPacket(
            records: records,
            nextCursor: selected.nextCursor,
            hasMore: selected.hasMore,
            canonicalBytes: canonicalBytes,
            canonicalSHA256: canonicalSHA256,
            encodedByteCount: canonicalBytes.count,
            selectionEncodingPassCount: packetEncodingPassCount,
            selectionRecordAccountingCount: recordAccountingCount
        )
    }

    /// The first remaining record alone exceeds the page budget. It travels on its own page
    /// flagged `oversizePage` when that page fits the hard cap; otherwise the page carries a typed
    /// `recordTooLarge` marker (identity and size) and no records. Either way the next cursor is
    /// positioned after this record, so a continuation always makes progress and nothing is
    /// silently skipped or truncated.
    private func oversizePacket(first: Candidate, remaining: Int, input: ReconstructionRetrievalProjectionInput,
        query: ReconstructionRetrievalQuery, queryIdentitySHA256: String, passCount: Int,
        accountingCount: Int) throws -> ReconstructionRetrievalPacket {
        let hasMore = remaining > 1
        let cursor = hasMore ? makeCursor(for: first.orderingKey, input: input,
            queryIdentitySHA256: queryIdentitySHA256) : nil
        func encode(records: [ReconstructionRetrievedEvidenceRecord], oversize: Bool?,
                    tooLarge: ReconstructionRetrievalRecordTooLarge?) throws -> Data {
            try ReconstructionCanonicalJSON.encode(PacketPreimage(schemaVersion: 1,
                domain: "reconstruction.evidence-retrieval-packet.v1",
                corpusManifestSHA256: input.corpusManifestSHA256,
                evidenceFrontierSHA256: input.evidenceFrontierSHA256,
                queryIdentitySHA256: queryIdentitySHA256, requestCursor: query.cursor, records: records,
                nextCursor: cursor, hasMore: hasMore, oversizePage: oversize, recordTooLarge: tooLarge))
        }
        try Task.checkCancellation()
        let single = try encode(records: [first.output], oversize: true, tooLarge: nil)
        var records = [first.output], oversize = true
        var tooLarge: ReconstructionRetrievalRecordTooLarge?
        var bytes = single
        if single.count > ReconstructionRetrievalPacket.oversizePageHardCapBytes {
            tooLarge = .init(evidenceID: first.output.evidenceID,
                encodedByteCount: try ReconstructionCanonicalJSON.encode(first.output).count)
            records = []; oversize = false
            bytes = try encode(records: [], oversize: nil, tooLarge: tooLarge)
            guard bytes.count <= query.maximumEncodedBytes else {
                throw ReconstructionRetrievalError.packetEnvelopeExceedsByteBudget
            }
        }
        try Task.checkCancellation()
        return ReconstructionRetrievalPacket(records: records, nextCursor: cursor, hasMore: hasMore,
            canonicalBytes: bytes, canonicalSHA256: Self.sha256(bytes), encodedByteCount: bytes.count,
            oversizePage: oversize, recordTooLarge: tooLarge,
            selectionEncodingPassCount: passCount + 1, selectionRecordAccountingCount: accountingCount)
    }

    private static func addingWithoutOverflow(_ values: Int...) -> Int? {
        var total = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = sum
        }
        return total
    }

    private func encodePacket(
        records: [ReconstructionRetrievedEvidenceRecord],
        input: ReconstructionRetrievalProjectionInput,
        query: ReconstructionRetrievalQuery,
        queryIdentitySHA256: String,
        nextCursor: ReconstructionRetrievalCursor?,
        hasMore: Bool
    ) throws -> Data {
        try ReconstructionCanonicalJSON.encode(PacketPreimage(
            schemaVersion: 1,
            domain: "reconstruction.evidence-retrieval-packet.v1",
            corpusManifestSHA256: input.corpusManifestSHA256,
            evidenceFrontierSHA256: input.evidenceFrontierSHA256,
            queryIdentitySHA256: queryIdentitySHA256,
            requestCursor: query.cursor,
            records: records,
            nextCursor: nextCursor,
            hasMore: hasMore
        ))
    }

    private func queryIdentity(
        for query: ReconstructionRetrievalQuery
    ) throws -> String {
        try ReconstructionCanonicalJSON.sha256(of: QueryIdentityPreimage(
            schemaVersion: 1,
            domain: "reconstruction.evidence-retrieval-query.v1",
            subject: try query.subject.map { try Self.structuralSubject($0) },
            focus: try query.focus.map { try Self.structuralSubject($0) },
            operationIDs: query.operationIDs.map(\.rawValue),
            classifications: query.classifications.map(\.rawValue)
        ))
    }

    private static func structuralSubject(
        _ subject: ReconstructionDurableSubject
    ) throws -> ReconstructionDurableSubject {
        switch subject {
        case .artifact, .image:
            return subject
        case .function(let function):
            return .function(try ReconstructionFunctionCoordinate(
                artifact: function.artifact,
                image: function.image,
                analysisFingerprintSHA256: function.analysisFingerprintSHA256,
                startAddress: function.startAddress,
                endAddressExclusive: function.endAddressExclusive,
                boundarySchemaVersion: function.boundarySchemaVersion,
                functionUUIDHint: nil,
                symbolHint: nil
            ))
        }
    }

    private func cursorIsValid(
        _ cursor: ReconstructionRetrievalCursor,
        input: ReconstructionRetrievalProjectionInput,
        queryIdentitySHA256: String
    ) -> Bool {
        cursor.schemaVersion == 1
            && cursor.corpusManifestSHA256 == input.corpusManifestSHA256
            && cursor.evidenceFrontierSHA256 == input.evidenceFrontierSHA256
            && cursor.queryIdentitySHA256 == queryIdentitySHA256
            && (0...1).contains(cursor.currentBucket)
            && (0...2).contains(cursor.subjectSpecificity)
            && ReconstructionOperationID.allCases.map(\.priority)
                .contains(cursor.operationPriority)
            && cursor.canonicalSubjectIdentity.count == SHA256.byteCount
    }

    private func makeCursor(
        for key: OrderingKey,
        input: ReconstructionRetrievalProjectionInput,
        queryIdentitySHA256: String
    ) -> ReconstructionRetrievalCursor {
        ReconstructionRetrievalCursor(
            schemaVersion: 1,
            corpusManifestSHA256: input.corpusManifestSHA256,
            evidenceFrontierSHA256: input.evidenceFrontierSHA256,
            queryIdentitySHA256: queryIdentitySHA256,
            currentBucket: key.currentBucket,
            subjectSpecificity: key.subjectSpecificity,
            operationPriority: key.operationPriority,
            canonicalSubjectIdentity: Self.subjectIdentitySHA256(
                key.canonicalSubjectIdentity
            ),
            checkpointRevision: key.checkpointRevision,
            evidenceID: key.evidenceID
        )
    }

    private static func cursor(
        _ cursor: ReconstructionRetrievalCursor,
        matches key: OrderingKey
    ) -> Bool {
        cursor.currentBucket == key.currentBucket
            && cursor.subjectSpecificity == key.subjectSpecificity
            && cursor.operationPriority == key.operationPriority
            && cursor.canonicalSubjectIdentity == subjectIdentitySHA256(
                key.canonicalSubjectIdentity
            )
            && cursor.checkpointRevision == key.checkpointRevision
            && cursor.evidenceID == key.evidenceID
    }

    private static func subjectIdentitySHA256(_ identity: Data) -> Data {
        Data(SHA256.hash(data: identity))
    }

    private static func subjectSpecificity(
        _ subject: ReconstructionDurableSubject
    ) -> Int {
        switch subject {
        case .function: 0
        case .image: 1
        case .artifact: 2
        }
    }

    private static func precedes(_ lhs: OrderingKey, _ rhs: OrderingKey) -> Bool {
        if lhs.currentBucket != rhs.currentBucket {
            return lhs.currentBucket < rhs.currentBucket
        }
        if lhs.subjectSpecificity != rhs.subjectSpecificity {
            return lhs.subjectSpecificity < rhs.subjectSpecificity
        }
        if lhs.operationPriority != rhs.operationPriority {
            return lhs.operationPriority < rhs.operationPriority
        }
        if lhs.canonicalSubjectIdentity != rhs.canonicalSubjectIdentity {
            return lhs.canonicalSubjectIdentity.lexicographicallyPrecedes(
                rhs.canonicalSubjectIdentity
            )
        }
        if lhs.checkpointRevision != rhs.checkpointRevision {
            return lhs.checkpointRevision > rhs.checkpointRevision
        }
        return lhs.evidenceID.uuidString.lowercased()
            < rhs.evidenceID.uuidString.lowercased()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
