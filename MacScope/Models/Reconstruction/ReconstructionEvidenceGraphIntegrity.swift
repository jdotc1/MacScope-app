import Foundation

/// Durable citation identity shared by candidate acceptance and package admission.
struct ReconstructionEvidenceCitationAnchor: Hashable, Sendable {
    let sourceEvidenceID: UUID?
    let subject: ReconstructionSubjectCoordinate?
    let locator: String?

    init(_ citation: ReconstructionEvidenceCitation) {
        sourceEvidenceID = citation.sourceEvidenceID
        subject = citation.subject
        locator = citation.locator
    }
}

enum ReconstructionEvidenceGraphIntegrityError: Error, Equatable, Sendable {
    case duplicateEvidenceID
    case duplicateRelationID
    case relationEndpointMissing
    case selfRelation
    case cycleDetected
    case inconsistentSupersession
}

struct ReconstructionEvidenceGraphValidation: Sendable {
    let successorByPredecessor: [UUID: UUID]
}

/// Pure relation-graph admission shared by package persistence and projection.
enum ReconstructionEvidenceGraphIntegrity {
    static func validate(
        records: [ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation],
        gapIDs: Set<UUID>? = nil
    ) throws -> ReconstructionEvidenceGraphValidation {
        try Task.checkCancellation()
        var recordsByID: [UUID: ReconstructionEvidenceRecord] = [:]
        recordsByID.reserveCapacity(records.count)
        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard recordsByID.updateValue(record, forKey: record.evidenceID) == nil else {
                throw ReconstructionEvidenceGraphIntegrityError.duplicateEvidenceID
            }
        }

        var relationIDs = Set<UUID>()
        relationIDs.reserveCapacity(relations.count)
        let dependencyKinds: Set<ReconstructionEvidenceRelationKind> = [
            .derivedFrom, .summarizes, .supersedes,
        ]
        var dependencyRelations: [ReconstructionEvidenceRelation] = []
        dependencyRelations.reserveCapacity(relations.count)
        for (index, relation) in relations.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard relationIDs.insert(relation.relationID).inserted else {
                throw ReconstructionEvidenceGraphIntegrityError.duplicateRelationID
            }
            guard recordsByID[relation.sourceEvidenceID] != nil else {
                throw ReconstructionEvidenceGraphIntegrityError.relationEndpointMissing
            }
            if relation.kind == .resolvesGap {
                if let gapIDs, !gapIDs.contains(relation.targetEvidenceID) {
                    throw ReconstructionEvidenceGraphIntegrityError.relationEndpointMissing
                }
            } else {
                guard relation.sourceEvidenceID != relation.targetEvidenceID else {
                    throw ReconstructionEvidenceGraphIntegrityError.selfRelation
                }
                guard recordsByID[relation.targetEvidenceID] != nil else {
                    throw ReconstructionEvidenceGraphIntegrityError.relationEndpointMissing
                }
            }
            if dependencyKinds.contains(relation.kind) {
                dependencyRelations.append(relation)
            }
        }

        guard try !containsCycle(dependencyRelations) else {
            throw ReconstructionEvidenceGraphIntegrityError.cycleDetected
        }
        let successorByPredecessor = try validateSupersession(
            records: records,
            recordsByID: recordsByID,
            relations: relations
        )
        try Task.checkCancellation()
        return ReconstructionEvidenceGraphValidation(
            successorByPredecessor: successorByPredecessor
        )
    }

    private static func validateSupersession(
        records: [ReconstructionEvidenceRecord],
        recordsByID: [UUID: ReconstructionEvidenceRecord],
        relations: [ReconstructionEvidenceRelation]
    ) throws -> [UUID: UUID] {
        var predecessorBySuccessor: [UUID: UUID] = [:]
        var successorByPredecessor: [UUID: UUID] = [:]

        for (index, relation) in relations.enumerated() where relation.kind == .supersedes {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let successor = recordsByID[relation.sourceEvidenceID],
                  let predecessor = recordsByID[relation.targetEvidenceID],
                  successor.subject == predecessor.subject,
                  successor.operationID == predecessor.operationID,
                  successor.supersedesEvidenceID == predecessor.evidenceID,
                  predecessorBySuccessor.updateValue(
                      predecessor.evidenceID,
                      forKey: successor.evidenceID
                  ) == nil,
                  successorByPredecessor.updateValue(
                      successor.evidenceID,
                      forKey: predecessor.evidenceID
                  ) == nil else {
                throw ReconstructionEvidenceGraphIntegrityError.inconsistentSupersession
            }
        }

        for (index, record) in records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if let predecessorID = record.supersedesEvidenceID {
                guard predecessorBySuccessor[record.evidenceID] == predecessorID,
                      recordsByID[predecessorID]?.subject == record.subject,
                      recordsByID[predecessorID]?.operationID == record.operationID else {
                    throw ReconstructionEvidenceGraphIntegrityError.inconsistentSupersession
                }
            } else if predecessorBySuccessor[record.evidenceID] != nil {
                throw ReconstructionEvidenceGraphIntegrityError.inconsistentSupersession
            }

            // Reverse pointers are legacy denormalization. Nil preserves immutable accepted rows;
            // when present, the pointer must still agree exactly with the authoritative edge.
            if let successorID = record.supersededByEvidenceID {
                guard successorByPredecessor[record.evidenceID] == successorID,
                      let successor = recordsByID[successorID],
                      successor.supersedesEvidenceID == record.evidenceID,
                      successor.subject == record.subject,
                      successor.operationID == record.operationID else {
                    throw ReconstructionEvidenceGraphIntegrityError.inconsistentSupersession
                }
            }
        }
        try Task.checkCancellation()
        return successorByPredecessor
    }

    private static func containsCycle(
        _ relations: [ReconstructionEvidenceRelation]
    ) throws -> Bool {
        try Task.checkCancellation()
        var targetsBySource: [UUID: [UUID]] = [:]
        var incomingEdgeCount: [UUID: Int] = [:]
        for (index, relation) in relations.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            targetsBySource[relation.sourceEvidenceID, default: []]
                .append(relation.targetEvidenceID)
            if incomingEdgeCount[relation.sourceEvidenceID] == nil {
                incomingEdgeCount[relation.sourceEvidenceID] = 0
            }
            incomingEdgeCount[relation.targetEvidenceID, default: 0] += 1
        }

        var ready = incomingEdgeCount.compactMap { evidenceID, count in
            count == 0 ? evidenceID : nil
        }.sorted { $0.uuidString < $1.uuidString }
        var nextReadyIndex = 0
        var visitedCount = 0
        while nextReadyIndex < ready.count {
            if visitedCount.isMultiple(of: 256) { try Task.checkCancellation() }
            let evidenceID = ready[nextReadyIndex]
            nextReadyIndex += 1
            visitedCount += 1
            for target in targetsBySource[evidenceID] ?? [] {
                let remaining = (incomingEdgeCount[target] ?? 0) - 1
                incomingEdgeCount[target] = remaining
                if remaining == 0 { ready.append(target) }
            }
        }
        try Task.checkCancellation()
        return visitedCount != incomingEdgeCount.count
    }
}
