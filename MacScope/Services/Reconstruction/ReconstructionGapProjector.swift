import Foundation

enum ReconstructionGapProjectionError: Error, Equatable, Sendable {
    case duplicateGapID
    case duplicateEvidenceID
    case duplicateRelationID
    case duplicateResolutionEdge
    case projectedClassificationKeyMismatch
    case missingResolutionSource
    case missingResolutionTarget
}

struct ReconstructionProjectedEvidenceGap: Hashable, Codable, Sendable {
    let gap: ReconstructionEvidenceGap
    let resolvingEvidence: [ReconstructionEvidenceRecord]
    let currentResolvingEvidence: [ReconstructionEvidenceRecord]
    let isResolved: Bool
}

/// Pure projection result. The complete evidence and relation inputs remain available for audit;
/// derived gap state never deletes a durable gap, resolver, contradiction, or superseded record.
struct ReconstructionGapProjection: Hashable, Codable, Sendable, RandomAccessCollection {
    typealias Element = ReconstructionProjectedEvidenceGap
    typealias Index = Array<Element>.Index

    let gaps: [ReconstructionProjectedEvidenceGap]
    let evidence: [ReconstructionEvidenceRecord]
    let relations: [ReconstructionEvidenceRelation]
    let projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification]
    let unresolvedGapFrontierSHA256: String

    var unresolvedGaps: [ReconstructionEvidenceGap] {
        gaps.compactMap { $0.isResolved ? nil : $0.gap }
    }

    var startIndex: Index { gaps.startIndex }
    var endIndex: Index { gaps.endIndex }

    subscript(position: Index) -> Element { gaps[position] }
}

/// Derives resolved/current gap state from immutable evidence and explicit resolution relations.
///
/// A `.resolvesGap` relation connects source evidence directly to a durable gap ID. A target that
/// is only an evidence ID is invalid. A gap is resolved only by an accepted-current source whose
/// subject and operation exactly equal the gap's durable subject and operation.
struct ReconstructionGapProjector: Sendable {
    /// Compatibility projection for a caller whose durable classifications are already the exact
    /// current projection. Freshness-aware callers must supply the projected classification map.
    func project(
        gaps: [ReconstructionEvidenceGap],
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation]
    ) throws -> ReconstructionGapProjection {
        try Task.checkCancellation()
        return try project(
            gaps: gaps,
            records: records,
            relations: relations,
            projectedClassificationsByEvidenceID: Dictionary(
                records.map { ($0.evidenceID, $0.classification) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// Projects the durable audit history against the caller's exact freshness classification cut.
    func project(
        gaps: [ReconstructionEvidenceGap],
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        projectedClassificationsByEvidenceID: [UUID: ReconstructionEvidenceClassification]
    ) throws -> ReconstructionGapProjection {
        try Task.checkCancellation()
        guard Set(gaps.map(\.gapID)).count == gaps.count else {
            throw ReconstructionGapProjectionError.duplicateGapID
        }
        guard Set(records.map(\.evidenceID)).count == records.count else {
            throw ReconstructionGapProjectionError.duplicateEvidenceID
        }
        guard Set(relations.map(\.relationID)).count == relations.count else {
            throw ReconstructionGapProjectionError.duplicateRelationID
        }
        guard Set(projectedClassificationsByEvidenceID.keys)
                == Set(records.map(\.evidenceID)) else {
            throw ReconstructionGapProjectionError.projectedClassificationKeyMismatch
        }

        let orderedGaps = gaps.sorted(by: Self.uuidOrder(\.gapID))
        let orderedEvidence = records.sorted(by: Self.uuidOrder(\.evidenceID))
        let orderedRelations = relations.sorted(by: Self.uuidOrder(\.relationID))
        let evidenceByID = Dictionary(
            uniqueKeysWithValues: orderedEvidence.map { ($0.evidenceID, $0) }
        )
        let gapByID = Dictionary(uniqueKeysWithValues: orderedGaps.map { ($0.gapID, $0) })

        struct ResolutionEdge: Hashable {
            let sourceEvidenceID: UUID
            let targetGapID: UUID
        }

        var resolutionEdges: Set<ResolutionEdge> = []
        var gapIDsByResolverEvidenceID: [UUID: Set<UUID>] = [:]
        for (index, relation) in orderedRelations.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard relation.kind == .resolvesGap else { continue }
            guard evidenceByID[relation.sourceEvidenceID] != nil else {
                throw ReconstructionGapProjectionError.missingResolutionSource
            }
            guard gapByID[relation.targetEvidenceID] != nil else {
                throw ReconstructionGapProjectionError.missingResolutionTarget
            }
            let edge = ResolutionEdge(
                sourceEvidenceID: relation.sourceEvidenceID,
                targetGapID: relation.targetEvidenceID
            )
            guard resolutionEdges.insert(edge).inserted else {
                throw ReconstructionGapProjectionError.duplicateResolutionEdge
            }
            gapIDsByResolverEvidenceID[relation.sourceEvidenceID, default: []]
                .insert(relation.targetEvidenceID)
        }

        var resolversByGapID: [UUID: [ReconstructionEvidenceRecord]] = [:]
        var currentResolversByGapID: [UUID: [ReconstructionEvidenceRecord]] = [:]
        for evidence in orderedEvidence {
            try Task.checkCancellation()
            guard let gapIDs = gapIDsByResolverEvidenceID[evidence.evidenceID] else {
                continue
            }
            for gapID in gapIDs.sorted(by: Self.uuidOrder) {
                guard let gap = gapByID[gapID] else { continue }
                resolversByGapID[gapID, default: []].append(evidence)
                if projectedClassificationsByEvidenceID[evidence.evidenceID]
                        == .acceptedCurrent,
                   evidence.subject == gap.subject,
                   evidence.operationID == gap.operationID {
                    currentResolversByGapID[gapID, default: []].append(evidence)
                }
            }
        }

        let projected = orderedGaps.map { gap in
            let resolvers = resolversByGapID[gap.gapID, default: []]
            let currentResolvers = currentResolversByGapID[gap.gapID, default: []]
            return ReconstructionProjectedEvidenceGap(
                gap: gap,
                resolvingEvidence: resolvers,
                currentResolvingEvidence: currentResolvers,
                isResolved: !currentResolvers.isEmpty
            )
        }
        let unresolvedGaps = projected.compactMap { projectedGap in
            projectedGap.isResolved ? nil : projectedGap.gap
        }
        try Task.checkCancellation()
        let unresolvedGapFrontierSHA256 = try ReconstructionEvidenceGapFrontier.canonicalSHA256(
            for: unresolvedGaps
        )
        try Task.checkCancellation()
        return ReconstructionGapProjection(
            gaps: projected,
            evidence: orderedEvidence,
            relations: orderedRelations,
            projectedClassificationsByEvidenceID: projectedClassificationsByEvidenceID,
            unresolvedGapFrontierSHA256: unresolvedGapFrontierSHA256
        )
    }

    private static func uuidOrder<Value>(
        _ keyPath: KeyPath<Value, UUID>
    ) -> (Value, Value) -> Bool {
        { lhs, rhs in
            lhs[keyPath: keyPath].uuidString.lowercased()
                < rhs[keyPath: keyPath].uuidString.lowercased()
        }
    }

    private static func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }
}
