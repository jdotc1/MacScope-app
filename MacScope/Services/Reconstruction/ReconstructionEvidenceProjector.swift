import Foundation


private struct ReconstructionFreshnessImageKey: Hashable, Sendable {
    let artifact: ReconstructionArtifactCoordinate
    let image: ReconstructionImageBinding
    let analysisFingerprintSHA256: String

    init(_ coordinate: ReconstructionImageCoordinate) {
        artifact = coordinate.artifact
        image = coordinate.image
        analysisFingerprintSHA256 = coordinate.analysisFingerprintSHA256
    }

    init(_ coordinate: ReconstructionFunctionCoordinate) {
        artifact = coordinate.artifact
        image = coordinate.image
        analysisFingerprintSHA256 = coordinate.analysisFingerprintSHA256
    }
}

private struct ReconstructionFreshnessIndex: Sendable {
    let artifactsByOccurrence: [ReconstructionArtifactOccurrenceID: ReconstructionArtifactCoordinate]
    let currentArtifacts: Set<ReconstructionArtifactCoordinate>
    let currentImages: Set<ReconstructionFreshnessImageKey>

    init(
        currentArtifacts: [ReconstructionArtifactCoordinate],
        currentImages: [ReconstructionImageCoordinate]
    ) {
        artifactsByOccurrence = Dictionary(
            uniqueKeysWithValues: currentArtifacts.map { ($0.occurrenceID, $0) }
        )
        self.currentArtifacts = Set(currentArtifacts)
        self.currentImages = Set(currentImages.map(ReconstructionFreshnessImageKey.init))
    }

    func analysisIsCurrent(_ subject: ReconstructionSubjectCoordinate) -> Bool {
        switch subject {
        case .artifact(let artifact):
            currentArtifacts.contains(artifact)
        case .image(let image):
            currentArtifacts.contains(image.artifact)
                && currentImages.contains(ReconstructionFreshnessImageKey(image))
        case .function(let function):
            currentArtifacts.contains(function.artifact)
                && currentImages.contains(ReconstructionFreshnessImageKey(function))
        }
    }
}

struct ReconstructionFreshnessAuthority: Sendable {
    let corpusManifestSHA256: String
    let currentArtifacts: [ReconstructionArtifactCoordinate]
    let currentImages: [ReconstructionImageCoordinate]
    let currentFacetFingerprints: [ReconstructionSubjectCoordinate: [String: String]]

    init(
        corpusManifestSHA256: String,
        currentArtifacts: [ReconstructionArtifactCoordinate],
        currentImages: [ReconstructionImageCoordinate],
        currentFacetFingerprints: [ReconstructionSubjectCoordinate: [String: String]]
    ) throws {
        try ReconstructionValidation.requireSHA256(
            corpusManifestSHA256,
            field: "freshness corpus manifest digest"
        )
        try ReconstructionValidation.requireUnique(
            currentArtifacts.map(\.occurrenceID),
            field: "freshness artifact occurrences"
        )
        try ReconstructionValidation.requireUnique(
            currentImages,
            field: "freshness images"
        )
        struct ImageBindingAuthorityKey: Hashable {
            let artifact: ReconstructionArtifactCoordinate
            let image: ReconstructionImageBinding
        }
        try ReconstructionValidation.requireUnique(
            currentImages.map {
                ImageBindingAuthorityKey(artifact: $0.artifact, image: $0.image)
            },
            field: "freshness image bindings"
        )
        let index = ReconstructionFreshnessIndex(
            currentArtifacts: currentArtifacts,
            currentImages: currentImages
        )
        guard currentImages.allSatisfy({ index.currentArtifacts.contains($0.artifact) }) else {
            throw ReconstructionValidationError.invalidReference(field: "freshness image artifact")
        }
        for (subject, fingerprints) in currentFacetFingerprints {
            guard index.analysisIsCurrent(subject) else {
                throw ReconstructionValidationError.invalidReference(
                    field: "freshness facet subject"
                )
            }
            for (identity, fingerprint) in fingerprints {
                try ReconstructionValidation.requireNonempty(
                    identity,
                    field: "freshness facet identity"
                )
                try ReconstructionValidation.requireSHA256(
                    fingerprint,
                    field: "freshness facet fingerprint"
                )
            }
        }
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.currentArtifacts = currentArtifacts.sorted {
            $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString
        }
        self.currentImages = currentImages
        self.currentFacetFingerprints = currentFacetFingerprints
    }
}

struct ReconstructionProjectedEvidenceRecord: Hashable, Codable, Sendable {
    let record: ReconstructionEvidenceRecord
    let classification: ReconstructionEvidenceClassification
}

struct ReconstructionEvidenceProjection: Hashable, Codable, Sendable {
    let records: [ReconstructionProjectedEvidenceRecord]
    let currentRecords: [ReconstructionEvidenceRecord]
    let relations: [ReconstructionEvidenceRelation]
}

/// Canonical identity of the complete immutable evidence cut used to fence retrieval cursors.
enum ReconstructionEvidenceFrontier {
    private struct EvidenceIdentity: Encodable {
        let evidenceID: UUID
        let schemaVersion: Int
        let subject: ReconstructionSubjectCoordinate
        let operationID: String
        let payloadKind: ReconstructionEvidencePayloadKind
        let payloadByteCount: UInt64
        let payloadSHA256: String
        let facetDependencies: [ReconstructionFacetDependency]
        let producer: ReconstructionProducerIdentity
        let citations: [ReconstructionEvidenceCitation]
        let creatingJobID: UUID
        let creatingTaskID: UUID
        let creatingCheckpointID: UUID
        let modelReceiptID: UUID?
        let toolReceiptID: UUID?
        let terminalClassification: ReconstructionEvidenceClassification
        let projectedClassification: ReconstructionEvidenceClassification
        let supersedesEvidenceID: UUID?
        let supersededByEvidenceID: UUID?
        let diagnostic: ReconstructionDiagnostic?
    }

    private struct CheckpointRevisionIdentity: Encodable {
        let checkpointID: UUID
        let revision: UInt64
    }

    private struct Preimage: Encodable {
        let schemaVersion: Int
        let domain: String
        let corpusManifestSHA256: String
        let evidence: [EvidenceIdentity]
        let relations: [ReconstructionEvidenceRelation]
        let gaps: [ReconstructionEvidenceGap]
        let checkpointRevisions: [CheckpointRevisionIdentity]
    }

    static func canonicalSHA256(
        corpusManifestSHA256: String,
        records: [ReconstructionEvidenceRecord],
        projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification],
        relations: [ReconstructionEvidenceRelation],
        gaps: [ReconstructionEvidenceGap],
        checkpointRevisionsByID: [UUID: UInt64]
    ) throws -> String {
        try Task.checkCancellation()
        try ReconstructionValidation.requireSHA256(
            corpusManifestSHA256,
            field: "evidence-frontier corpus manifest digest"
        )
        try ReconstructionValidation.requireUnique(
            records.map(\.evidenceID),
            field: "evidence-frontier evidence IDs"
        )
        try ReconstructionValidation.requireUnique(
            relations.map(\.relationID),
            field: "evidence-frontier relation IDs"
        )
        try ReconstructionValidation.requireUnique(
            gaps.map(\.gapID),
            field: "evidence-frontier gap IDs"
        )
        let evidenceIDs = Set(records.map(\.evidenceID))
        let checkpointIDs = Set(records.map(\.creatingCheckpointID))
        guard Set(projectedClassificationsByEvidenceID.keys) == evidenceIDs,
              Set(checkpointRevisionsByID.keys) == checkpointIDs else {
            throw ReconstructionValidationError.invalidReference(
                field: "evidence-frontier projection maps"
            )
        }

        let orderedRecords = records.sorted {
            $0.evidenceID.uuidString.lowercased() < $1.evidenceID.uuidString.lowercased()
        }
        var evidence: [EvidenceIdentity] = []
        evidence.reserveCapacity(orderedRecords.count)
        for (index, record) in orderedRecords.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let projectedClassification =
                    projectedClassificationsByEvidenceID[record.evidenceID] else {
                throw ReconstructionValidationError.invalidReference(
                    field: "evidence-frontier projected classification"
                )
            }
            evidence.append(EvidenceIdentity(
                evidenceID: record.evidenceID,
                schemaVersion: record.schemaVersion,
                subject: record.subject,
                operationID: record.operationID,
                payloadKind: record.payloadKind,
                payloadByteCount: record.payloadByteCount,
                payloadSHA256: record.payloadSHA256,
                facetDependencies: record.facetDependencies,
                producer: record.producer,
                citations: record.citations,
                creatingJobID: record.creatingJobID,
                creatingTaskID: record.creatingTaskID,
                creatingCheckpointID: record.creatingCheckpointID,
                modelReceiptID: record.modelReceiptID,
                toolReceiptID: record.toolReceiptID,
                terminalClassification: record.classification,
                projectedClassification: projectedClassification,
                supersedesEvidenceID: record.supersedesEvidenceID,
                supersededByEvidenceID: record.supersededByEvidenceID,
                diagnostic: record.diagnostic
            ))
        }
        let orderedRelations = relations.sorted {
            $0.relationID.uuidString.lowercased() < $1.relationID.uuidString.lowercased()
        }
        let orderedGaps = gaps.sorted {
            $0.gapID.uuidString.lowercased() < $1.gapID.uuidString.lowercased()
        }
        let checkpointRevisions = checkpointRevisionsByID.keys.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        }.map {
            CheckpointRevisionIdentity(
                checkpointID: $0,
                revision: checkpointRevisionsByID[$0]!
            )
        }
        try Task.checkCancellation()
        let digest = try ReconstructionCanonicalJSON.sha256(of: Preimage(
            schemaVersion: 2,
            domain: "reconstruction.evidence-frontier.v2",
            corpusManifestSHA256: corpusManifestSHA256,
            evidence: evidence,
            relations: orderedRelations,
            gaps: orderedGaps,
            checkpointRevisions: checkpointRevisions
        ))
        try Task.checkCancellation()
        return digest
    }
}

struct ReconstructionEvidenceCut: Hashable, Codable, Sendable {
    let corpusManifestSHA256: String
    let records: [ReconstructionEvidenceRecord]
    let relations: [ReconstructionEvidenceRelation]
    let gaps: [ReconstructionEvidenceGap]
    let frontierSHA256: String
    let projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification]
    let checkpointRevisionsByID: [UUID: UInt64]

    /// Backwards-compatible construction for persisted cuts that predate explicit projection and
    /// checkpoint-revision maps. Durable row classifications remain the conservative projection.
    init(
        corpusManifestSHA256: String,
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        gaps: [ReconstructionEvidenceGap],
        frontierSHA256: String
    ) {
        let projectedClassifications = Dictionary(
            records.map { ($0.evidenceID, $0.classification) },
            uniquingKeysWith: { first, _ in first }
        )
        let verifiedFrontierSHA256: String
        if let computed = try? ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: corpusManifestSHA256,
            records: records,
            projectedClassificationsByEvidenceID: projectedClassifications,
            relations: relations,
            gaps: gaps,
            checkpointRevisionsByID: [:]
        ), computed == frontierSHA256 {
            verifiedFrontierSHA256 = computed
        } else {
            verifiedFrontierSHA256 = ""
        }
        self.init(
            validatedCorpusManifestSHA256: corpusManifestSHA256,
            records: records,
            relations: relations,
            gaps: gaps,
            frontierSHA256: verifiedFrontierSHA256,
            projectedClassificationsByEvidenceID: projectedClassifications,
            checkpointRevisionsByID: [:]
        )
    }

    init(
        corpusManifestSHA256: String,
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        gaps: [ReconstructionEvidenceGap],
        frontierSHA256: String,
        projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification],
        checkpointRevisionsByID: [UUID: UInt64]
    ) throws {
        try ReconstructionValidation.requireSHA256(
            corpusManifestSHA256,
            field: "evidence-cut corpus manifest digest"
        )
        try ReconstructionValidation.requireSHA256(
            frontierSHA256,
            field: "evidence-cut frontier digest"
        )
        try ReconstructionValidation.requireUnique(
            records.map(\.evidenceID),
            field: "evidence-cut evidence IDs"
        )
        try ReconstructionValidation.requireUnique(
            relations.map(\.relationID),
            field: "evidence-cut relation IDs"
        )
        try ReconstructionValidation.requireUnique(
            gaps.map(\.gapID),
            field: "evidence-cut gap IDs"
        )
        guard Set(projectedClassificationsByEvidenceID.keys) == Set(records.map(\.evidenceID)) else {
            throw ReconstructionValidationError.invalidReference(
                field: "evidence-cut projected classifications"
            )
        }
        guard Set(checkpointRevisionsByID.keys) == Set(records.map(\.creatingCheckpointID)) else {
            throw ReconstructionValidationError.invalidReference(
                field: "evidence-cut checkpoint revisions"
            )
        }
        let canonicalFrontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: corpusManifestSHA256,
            records: records,
            projectedClassificationsByEvidenceID: projectedClassificationsByEvidenceID,
            relations: relations,
            gaps: gaps,
            checkpointRevisionsByID: checkpointRevisionsByID
        )
        guard frontierSHA256 == canonicalFrontierSHA256 else {
            throw ReconstructionValidationError.invalidReference(
                field: "evidence-cut frontier digest"
            )
        }
        try Task.checkCancellation()
        self.init(
            validatedCorpusManifestSHA256: corpusManifestSHA256,
            records: records,
            relations: relations,
            gaps: gaps,
            frontierSHA256: frontierSHA256,
            projectedClassificationsByEvidenceID: projectedClassificationsByEvidenceID,
            checkpointRevisionsByID: checkpointRevisionsByID
        )
    }

    private init(
        validatedCorpusManifestSHA256: String,
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        gaps: [ReconstructionEvidenceGap],
        frontierSHA256: String,
        projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification],
        checkpointRevisionsByID: [UUID: UInt64]
    ) {
        corpusManifestSHA256 = validatedCorpusManifestSHA256
        self.records = records.sorted { $0.evidenceID.uuidString < $1.evidenceID.uuidString }
        self.relations = relations.sorted { $0.relationID.uuidString < $1.relationID.uuidString }
        self.gaps = gaps.sorted { $0.gapID.uuidString < $1.gapID.uuidString }
        self.frontierSHA256 = frontierSHA256
        self.projectedClassificationsByEvidenceID = projectedClassificationsByEvidenceID
        self.checkpointRevisionsByID = checkpointRevisionsByID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(corpusManifestSHA256)
        hasher.combine(records)
        hasher.combine(relations)
        hasher.combine(gaps)
        hasher.combine(frontierSHA256)
        for evidenceID in projectedClassificationsByEvidenceID.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            hasher.combine(evidenceID)
            hasher.combine(projectedClassificationsByEvidenceID[evidenceID])
        }
        for checkpointID in checkpointRevisionsByID.keys.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            hasher.combine(checkpointID)
            hasher.combine(checkpointRevisionsByID[checkpointID])
        }
    }
}

enum ReconstructionEvidenceProjectionError: Error, Equatable, Sendable {
    case duplicateEvidenceID
    case duplicateRelationID
    case relationEndpointMissing
    case selfRelation
    case cycleDetected
    case inconsistentSupersession
    case incompleteCheckpointRevisions
}

/// Builds freshness and current-value projections without changing persisted evidence rows.
struct ReconstructionEvidenceProjector: Sendable {
    func project(
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        authority: ReconstructionFreshnessAuthority
    ) throws -> ReconstructionEvidenceProjection {
        try project(
            records: records,
            relations: relations,
            authority: authority,
            gapIDs: nil
        )
    }

    private func project(
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        authority: ReconstructionFreshnessAuthority,
        gapIDs: Set<UUID>?
    ) throws -> ReconstructionEvidenceProjection {
        try Task.checkCancellation()
        let relationValidation = try validatedRelationGraph(
            records: records,
            relations: relations,
            gapIDs: gapIDs
        )
        let successorsByPredecessor = relationValidation.successorByPredecessor
        try Task.checkCancellation()
        let freshnessIndex = ReconstructionFreshnessIndex(
            currentArtifacts: authority.currentArtifacts,
            currentImages: authority.currentImages
        )
        var projected: [ReconstructionProjectedEvidenceRecord] = []
        projected.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            projected.append(ReconstructionProjectedEvidenceRecord(
                record: record,
                classification: projectedClassification(
                    for: record,
                    isSuperseded: successorsByPredecessor[record.evidenceID] != nil,
                    authority: authority,
                    freshnessIndex: freshnessIndex
                )
            ))
        }
        try Task.checkCancellation()
        projected.sort { $0.record.evidenceID.uuidString < $1.record.evidenceID.uuidString }
        let currentRecords = projected.compactMap {
            $0.classification == .acceptedCurrent ? $0.record : nil
        }
        let sortedRelations = relations.sorted {
            $0.relationID.uuidString < $1.relationID.uuidString
        }
        try Task.checkCancellation()
        return ReconstructionEvidenceProjection(
            records: projected,
            currentRecords: currentRecords,
            relations: sortedRelations
        )
    }

    /// Compatibility projection from the acceptance authority into the retrieval cut.
    func project(
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        gaps: [ReconstructionEvidenceGap],
        against authority: ReconstructionAuthorityCut
    ) throws -> ReconstructionEvidenceCut {
        let checkpointIDs = Set(records.map(\.creatingCheckpointID))
        let derivedRevisions = checkpointIDs.contains(authority.creatingCheckpointID)
            ? [authority.creatingCheckpointID: authority.checkpointRevision]
            : [:]
        return try project(
            records: records,
            relations: relations,
            gaps: gaps,
            against: authority,
            checkpointRevisionsByID: derivedRevisions
        )
    }

    /// Compatibility projection with an explicit complete revision authority for retained history.
    func project(
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        gaps: [ReconstructionEvidenceGap],
        against authority: ReconstructionAuthorityCut,
        checkpointRevisionsByID: [UUID: UInt64]
    ) throws -> ReconstructionEvidenceCut {
        try Task.checkCancellation()
        let checkpointIDs = Set(records.map(\.creatingCheckpointID))
        guard Set(checkpointRevisionsByID.keys) == checkpointIDs,
              !checkpointIDs.contains(authority.creatingCheckpointID)
                || checkpointRevisionsByID[authority.creatingCheckpointID]
                    == authority.checkpointRevision else {
            throw ReconstructionEvidenceProjectionError.incompleteCheckpointRevisions
        }
        let currentArtifacts = authority.corpusManifest.artifacts.map {
            ReconstructionArtifactCoordinate(
                occurrenceID: $0.occurrenceID,
                contentIdentity: $0.contentIdentity
            )
        }
        let currentArtifactSet = Set(currentArtifacts)
        var currentImages: Set<ReconstructionImageCoordinate> = []
        for (index, subject) in authority.authoritativeSubjects.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard currentArtifactSet.contains(Self.artifactCoordinate(for: subject)) else {
                continue
            }
            switch subject {
            case .artifact:
                break
            case .image(let image):
                currentImages.insert(image)
            case .function(let function):
                currentImages.insert(try ReconstructionImageCoordinate(
                    artifact: function.artifact,
                    image: function.image,
                    analysisFingerprintSHA256: function.analysisFingerprintSHA256
                ))
            }
        }
        let currentImageArray = Array(currentImages)
        let freshnessIndex = ReconstructionFreshnessIndex(
            currentArtifacts: currentArtifacts,
            currentImages: currentImageArray
        )
        var currentFacetFingerprints: [ReconstructionSubjectCoordinate: [String: String]] = [:]
        for (index, subject) in authority.authoritativeSubjects.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard freshnessIndex.analysisIsCurrent(subject) else { continue }
            currentFacetFingerprints[subject] = authority.facetFingerprints
        }
        let freshnessAuthority = try ReconstructionFreshnessAuthority(
            corpusManifestSHA256: authority.corpusManifest.canonicalSHA256,
            currentArtifacts: currentArtifacts,
            currentImages: currentImageArray,
            currentFacetFingerprints: currentFacetFingerprints
        )
        try Task.checkCancellation()
        let projection = try project(
            records: records,
            relations: relations,
            authority: freshnessAuthority,
            gapIDs: Set(gaps.map(\.gapID))
        )
        let classifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })
        let sortedRecords = projection.records.map(\.record)
        let sortedRelations = projection.relations
        let sortedGaps = gaps.sorted { $0.gapID.uuidString < $1.gapID.uuidString }
        try Task.checkCancellation()
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: authority.corpusManifest.canonicalSHA256,
            records: sortedRecords,
            projectedClassificationsByEvidenceID: classifications,
            relations: sortedRelations,
            gaps: sortedGaps,
            checkpointRevisionsByID: checkpointRevisionsByID
        )
        try Task.checkCancellation()
        let cut = try ReconstructionEvidenceCut(
            corpusManifestSHA256: authority.corpusManifest.canonicalSHA256,
            records: sortedRecords,
            relations: sortedRelations,
            gaps: sortedGaps,
            frontierSHA256: frontier,
            projectedClassificationsByEvidenceID: classifications,
            checkpointRevisionsByID: checkpointRevisionsByID
        )
        try Task.checkCancellation()
        return cut
    }

    func validateRelationGraph(
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation]
    ) throws {
        _ = try validatedRelationGraph(
            records: records,
            relations: relations,
            gapIDs: nil
        )
    }

    private func validatedRelationGraph(
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        gapIDs: Set<UUID>?
    ) throws -> ReconstructionEvidenceGraphValidation {
        do {
            return try ReconstructionEvidenceGraphIntegrity.validate(
                records: records,
                relations: relations,
                gapIDs: gapIDs
            )
        } catch let error as ReconstructionEvidenceGraphIntegrityError {
            switch error {
            case .duplicateEvidenceID:
                throw ReconstructionEvidenceProjectionError.duplicateEvidenceID
            case .duplicateRelationID:
                throw ReconstructionEvidenceProjectionError.duplicateRelationID
            case .relationEndpointMissing:
                throw ReconstructionEvidenceProjectionError.relationEndpointMissing
            case .selfRelation:
                throw ReconstructionEvidenceProjectionError.selfRelation
            case .cycleDetected:
                throw ReconstructionEvidenceProjectionError.cycleDetected
            case .inconsistentSupersession:
                throw ReconstructionEvidenceProjectionError.inconsistentSupersession
            }
        }
    }

    private func projectedClassification(
        for record: ReconstructionEvidenceRecord,
        isSuperseded: Bool,
        authority: ReconstructionFreshnessAuthority,
        freshnessIndex: ReconstructionFreshnessIndex
    ) -> ReconstructionEvidenceClassification {
        if isSuperseded { return .superseded }
        switch record.classification {
        case .unavailable, .failed, .cancelled, .truncated, .superseded:
            return record.classification
        case .acceptedCurrent, .acceptedHistorical, .staleArtifact, .staleAnalysis:
            break
        }
        let artifact = Self.artifactCoordinate(for: record.subject)
        guard freshnessIndex.artifactsByOccurrence[artifact.occurrenceID] == artifact else {
            return .staleArtifact
        }
        guard freshnessIndex.analysisIsCurrent(record.subject) else {
            return .staleAnalysis
        }
        if case .function = record.subject,
           authority.currentFacetFingerprints[record.subject] == nil {
            return .staleAnalysis
        }
        let currentFacets = authority.currentFacetFingerprints[record.subject] ?? [:]
        let storedFacetIdentities = Set(record.facetDependencies.map(\.facetIdentity))
        guard storedFacetIdentities == Set(currentFacets.keys),
              record.facetDependencies.allSatisfy({
            currentFacets[$0.facetIdentity] == $0.fingerprintSHA256
        }) else {
            return .staleAnalysis
        }
        return record.classification
    }

    private static func artifactCoordinate(
        for subject: ReconstructionSubjectCoordinate
    ) -> ReconstructionArtifactCoordinate {
        switch subject {
        case .artifact(let artifact): return artifact
        case .image(let image): return image.artifact
        case .function(let function): return function.artifact
        }
    }

}
