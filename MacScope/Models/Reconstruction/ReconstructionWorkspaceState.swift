import Foundation

struct ReconstructionProjectRecord: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let projectID: UUID
    let schemaVersion: Int
    let name: String
    let currentCorpusManifestSHA256: String?

    init(
        projectID: UUID,
        schemaVersion: Int = Self.schemaVersion,
        name: String,
        currentCorpusManifestSHA256: String?
    ) throws {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        try ReconstructionValidation.requireNonempty(name, field: "reconstruction project name")
        if let currentCorpusManifestSHA256 {
            try ReconstructionValidation.requireSHA256(
                currentCorpusManifestSHA256,
                field: "project corpus manifest digest"
            )
        }
        self.projectID = projectID
        self.schemaVersion = schemaVersion
        self.name = name
        self.currentCorpusManifestSHA256 = currentCorpusManifestSHA256
    }
}

/// Portable owner-journal envelope. The payload is opaque to analysis workers; the database
/// owner validates its canonical record before admitting it. Job identity allows Save to remove
/// completed-job replay data without changing any historical evidence or model receipt.
struct ReconstructionWorkspaceReplayRecord: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case inference, executionBudget }
    let jobID: UUID
    let payload: Data
    let kind: Kind

    init(jobID: UUID, payload: Data, kind: Kind = .inference) {
        self.jobID = jobID
        self.payload = payload
        self.kind = kind
    }
}

struct ReconstructionWorkspaceState: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let projects: [ReconstructionProjectRecord]
    let corpusManifests: [ReconstructionCorpusManifest]
    let evidence: [ReconstructionEvidenceRecord]
    let evidenceRelations: [ReconstructionEvidenceRelation]
    let evidenceGaps: [ReconstructionEvidenceGap]
    let jobs: [ReconstructionJobRecord]
    let tasks: [ReconstructionTaskRecord]
    let checkpoints: [ReconstructionCheckpoint]
    let toolReceipts: [ReconstructionToolReceipt]
    let modelReceipts: [ReconstructionModelReceipt]
    let finalResults: [ReconstructionFinalResultRecord]
    let replayRecords: [ReconstructionWorkspaceReplayRecord]?

    static let empty = ReconstructionWorkspaceState(
        validatedSchemaVersion: schemaVersion,
        projects: [],
        corpusManifests: [],
        evidence: [],
        evidenceRelations: [],
        evidenceGaps: [],
        jobs: [],
        tasks: [],
        checkpoints: [],
        toolReceipts: [],
        modelReceipts: [],
        finalResults: []
    )

    init(
        schemaVersion: Int = Self.schemaVersion,
        projects: [ReconstructionProjectRecord],
        corpusManifests: [ReconstructionCorpusManifest],
        evidence: [ReconstructionEvidenceRecord],
        evidenceRelations: [ReconstructionEvidenceRelation],
        evidenceGaps: [ReconstructionEvidenceGap],
        jobs: [ReconstructionJobRecord],
        tasks: [ReconstructionTaskRecord],
        checkpoints: [ReconstructionCheckpoint],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        finalResults: [ReconstructionFinalResultRecord] = [],
        replayRecords: [ReconstructionWorkspaceReplayRecord]? = nil
    ) throws {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        if let replayRecords {
            let jobIDs = Set(jobs.map(\.jobID))
            guard !replayRecords.isEmpty, replayRecords.count <= 2_048,
                  replayRecords.allSatisfy({ jobIDs.contains($0.jobID) && !$0.payload.isEmpty && $0.payload.count <= 1_048_576 }),
                  replayRecords.reduce(0, { $0 + $1.payload.count }) <= 64 * 1_048_576 else {
                throw ReconstructionValidationError.invalidReference(field: "owner replay records")
            }
        }
        try ReconstructionEvidenceIntegrity.validateDurableBounds(
            projects: projects,
            corpusManifests: corpusManifests,
            evidence: evidence,
            relations: evidenceRelations,
            gaps: evidenceGaps,
            jobs: jobs,
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: toolReceipts,
            modelReceipts: modelReceipts,
            finalResults: finalResults
        )
        try ReconstructionValidation.requireUnique(projects.map(\.projectID), field: "project IDs")
        try ReconstructionValidation.requireUnique(evidence.map(\.evidenceID), field: "evidence IDs")
        try ReconstructionValidation.requireUnique(
            evidenceRelations.map(\.relationID),
            field: "evidence relation IDs"
        )
        try ReconstructionValidation.requireUnique(evidenceGaps.map(\.gapID), field: "gap IDs")
        try ReconstructionValidation.requireUnique(jobs.map(\.jobID), field: "job IDs")
        let legacyJobCount = jobs.lazy.filter { $0.creationOrdinal == nil }.count
        guard legacyJobCount == 0 || legacyJobCount == jobs.count else {
            throw ReconstructionValidationError.invalidReference(
                field: "mixed legacy and current job records"
            )
        }
        if legacyJobCount == 0 {
            let ordinals = jobs.compactMap(\.creationOrdinal).sorted()
            let expected = (0..<jobs.count).map { UInt64($0 + 1) }
            guard ordinals == expected else {
                throw ReconstructionValidationError.invalidReference(
                    field: "job creation ordinals"
                )
            }
        }
        try ReconstructionValidation.requireUnique(
            tasks.map { $0.identity.taskID },
            field: "task IDs"
        )
        try ReconstructionValidation.requireUnique(
            checkpoints.map(\.checkpointID),
            field: "checkpoint IDs"
        )
        try ReconstructionValidation.requireUnique(
            toolReceipts.map(\.receiptID),
            field: "tool receipt IDs"
        )
        try ReconstructionValidation.requireUnique(
            modelReceipts.map(\.receiptID),
            field: "model receipt IDs"
        )
        try ReconstructionValidation.requireUnique(
            finalResults.map(\.resultID),
            field: "final result IDs"
        )
        self.init(
            validatedSchemaVersion: schemaVersion,
            projects: projects,
            corpusManifests: corpusManifests,
            evidence: evidence,
            evidenceRelations: evidenceRelations,
            evidenceGaps: evidenceGaps,
            jobs: jobs,
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: toolReceipts,
            modelReceipts: modelReceipts,
            finalResults: finalResults,
            replayRecords: replayRecords
        )
    }

    private init(
        validatedSchemaVersion: Int,
        projects: [ReconstructionProjectRecord],
        corpusManifests: [ReconstructionCorpusManifest],
        evidence: [ReconstructionEvidenceRecord],
        evidenceRelations: [ReconstructionEvidenceRelation],
        evidenceGaps: [ReconstructionEvidenceGap],
        jobs: [ReconstructionJobRecord],
        tasks: [ReconstructionTaskRecord],
        checkpoints: [ReconstructionCheckpoint],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        finalResults: [ReconstructionFinalResultRecord],
        replayRecords: [ReconstructionWorkspaceReplayRecord]? = nil
    ) {
        schemaVersion = validatedSchemaVersion
        self.projects = projects.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
        self.corpusManifests = corpusManifests.sorted(
            by: ReconstructionCorpusHistoryIndex.manifestPrecedes
        )
        self.evidence = evidence.sorted { $0.evidenceID.uuidString < $1.evidenceID.uuidString }
        self.evidenceRelations = evidenceRelations.sorted {
            $0.relationID.uuidString < $1.relationID.uuidString
        }
        self.evidenceGaps = evidenceGaps.sorted { $0.gapID.uuidString < $1.gapID.uuidString }
        self.jobs = jobs.sorted {
            switch ($0.creationOrdinal, $1.creationOrdinal) {
            case let (lhs?, rhs?) where lhs != rhs:
                lhs < rhs
            default:
                $0.jobID.uuidString < $1.jobID.uuidString
            }
        }
        self.tasks = tasks.sorted {
            $0.identity.taskID.uuidString < $1.identity.taskID.uuidString
        }
        self.checkpoints = checkpoints.sorted {
            if $0.jobID != $1.jobID { return $0.jobID.uuidString < $1.jobID.uuidString }
            return $0.revision < $1.revision
        }
        self.toolReceipts = toolReceipts.sorted { $0.receiptID.uuidString < $1.receiptID.uuidString }
        self.modelReceipts = modelReceipts.sorted { $0.receiptID.uuidString < $1.receiptID.uuidString }
        self.finalResults = finalResults.sorted { $0.resultID.uuidString < $1.resultID.uuidString }
        self.replayRecords = replayRecords?.sorted {
            if $0.jobID != $1.jobID { return $0.jobID.uuidString < $1.jobID.uuidString }
            return $0.payload.lexicographicallyPrecedes($1.payload)
        }
    }

    /// Normalizes strictly admitted legacy jobs only at a package/database boundary.
    ///
    /// Historical schema-v1 creation time is unrecoverable, so UUID rank is used exactly once to
    /// assign its dense order. Schema-v2 already carries that order and only needs the schema-v3
    /// pause-context contract applied. A paused legacy job is rejected because no safe resume target
    /// or cause can be reconstructed from its wire representation.
    func normalizedJobRecords() throws -> Self {
        guard !jobs.isEmpty else { return self }
        let upgraded: [ReconstructionJobRecord]
        if jobs.allSatisfy({ $0.creationOrdinal == nil }) {
            upgraded = try jobs.enumerated().map { index, job in
                try job.upgraded(creationOrdinal: UInt64(index + 1))
            }
        } else {
            guard jobs.allSatisfy({ $0.creationOrdinal != nil }) else {
                throw ReconstructionValidationError.invalidReference(
                    field: "mixed legacy and current job records"
                )
            }
            upgraded = try jobs.map { try $0.normalizedToCurrentSchema() }
        }
        guard upgraded != jobs else { return self }
        return try Self(
            schemaVersion: schemaVersion,
            projects: projects,
            corpusManifests: corpusManifests,
            evidence: evidence,
            evidenceRelations: evidenceRelations,
            evidenceGaps: evidenceGaps,
            jobs: upgraded,
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: toolReceipts,
            modelReceipts: modelReceipts,
            finalResults: finalResults,
            replayRecords: replayRecords
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, projects, corpusManifests, evidence, evidenceRelations, evidenceGaps
        case jobs, tasks, checkpoints, toolReceipts, modelReceipts, finalResults, replayRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            projects: container.decode([ReconstructionProjectRecord].self, forKey: .projects),
            corpusManifests: container.decode(
                [ReconstructionCorpusManifest].self,
                forKey: .corpusManifests
            ),
            evidence: container.decode([ReconstructionEvidenceRecord].self, forKey: .evidence),
            evidenceRelations: container.decode(
                [ReconstructionEvidenceRelation].self,
                forKey: .evidenceRelations
            ),
            evidenceGaps: container.decode(
                [ReconstructionEvidenceGap].self,
                forKey: .evidenceGaps
            ),
            jobs: container.decode([ReconstructionJobRecord].self, forKey: .jobs),
            tasks: container.decode([ReconstructionTaskRecord].self, forKey: .tasks),
            checkpoints: container.decode(
                [ReconstructionCheckpoint].self,
                forKey: .checkpoints
            ),
            toolReceipts: container.decode(
                [ReconstructionToolReceipt].self,
                forKey: .toolReceipts
            ),
            modelReceipts: container.decode(
                [ReconstructionModelReceipt].self,
                forKey: .modelReceipts
            ),
            finalResults: try container.decodeIfPresent(
                [ReconstructionFinalResultRecord].self,
                forKey: .finalResults
            ) ?? [],
            replayRecords: container.decodeIfPresent([ReconstructionWorkspaceReplayRecord].self, forKey: .replayRecords)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(replayRecords, forKey: .replayRecords)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(projects, forKey: .projects)
        try container.encode(corpusManifests, forKey: .corpusManifests)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(evidenceRelations, forKey: .evidenceRelations)
        try container.encode(evidenceGaps, forKey: .evidenceGaps)
        try container.encode(jobs, forKey: .jobs)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(checkpoints, forKey: .checkpoints)
        try container.encode(toolReceipts, forKey: .toolReceipts)
        try container.encode(modelReceipts, forKey: .modelReceipts)
        if !finalResults.isEmpty {
            try container.encode(finalResults, forKey: .finalResults)
        }
    }

    func replacingReplayRecords(_ records: [ReconstructionWorkspaceReplayRecord]?) throws -> Self {
        try Self(schemaVersion: schemaVersion, projects: projects, corpusManifests: corpusManifests,
            evidence: evidence, evidenceRelations: evidenceRelations, evidenceGaps: evidenceGaps,
            jobs: jobs, tasks: tasks, checkpoints: checkpoints, toolReceipts: toolReceipts,
            modelReceipts: modelReceipts, finalResults: finalResults,
            replayRecords: records?.isEmpty == false ? records : nil)
    }

    func pruningTerminalReplayRecordsForSave() throws -> Self {
        let active = Set(jobs.filter { !$0.state.isTerminal }.map(\.jobID))
        return try replacingReplayRecords(replayRecords?.filter { active.contains($0.jobID) })
    }

    /// Backward-compatible spelling retained for existing package/database callers.
    func normalizedJobCreationOrder() throws -> Self {
        try normalizedJobRecords()
    }
}

/// Validates and indexes immutable corpus history without collapsing retained manifests.
struct ReconstructionCorpusHistoryIndex {
    enum Failure: Error, Equatable, Sendable {
        case manifestProjectOwnership
        case duplicateManifestDigest
        case manifestDigestDisagreement
        case occurrenceIdentityDisagreement
        case relationIdentityDisagreement
        case artifactRelationEndpoint
        case projectCurrentManifest

        var graphReason: String {
            switch self {
            case .manifestProjectOwnership:
                "manifest project ownership"
            case .duplicateManifestDigest:
                "duplicate manifest digest"
            case .manifestDigestDisagreement:
                "manifest digest disagreement"
            case .occurrenceIdentityDisagreement:
                "artifact occurrence identity disagreement"
            case .relationIdentityDisagreement:
                "artifact relation identity disagreement"
            case .artifactRelationEndpoint:
                "artifact relation endpoint"
            case .projectCurrentManifest:
                "project current manifest"
            }
        }

        var isIdentityConflict: Bool {
            switch self {
            case .duplicateManifestDigest, .manifestDigestDisagreement,
                 .occurrenceIdentityDisagreement, .relationIdentityDisagreement:
                true
            case .manifestProjectOwnership, .artifactRelationEndpoint,
                 .projectCurrentManifest:
                false
            }
        }
    }

    let manifestsByProjectID: [UUID: [String: ReconstructionCorpusManifest]]
    let occurrencesByID: [
        ReconstructionArtifactOccurrenceID:
            (projectID: UUID, record: ReconstructionArtifactOccurrenceRecord)
    ]
    let relationsByID: [
        UUID: (projectID: UUID, record: ReconstructionArtifactRelationRecord)
    ]
    private let occurrenceIDsByManifest: [
        UUID: [String: Set<ReconstructionArtifactOccurrenceID>]
    ]

    init(
        projects: [ReconstructionProjectRecord],
        manifests: [ReconstructionCorpusManifest]
    ) throws {
        let projectIDs = Set(projects.map(\.projectID))
        var manifestsByProjectID: [UUID: [String: ReconstructionCorpusManifest]] = [:]
        var occurrencesByID: [
            ReconstructionArtifactOccurrenceID:
                (projectID: UUID, record: ReconstructionArtifactOccurrenceRecord)
        ] = [:]
        var relationsByID: [
            UUID: (projectID: UUID, record: ReconstructionArtifactRelationRecord)
        ] = [:]
        var occurrenceIDsByManifest: [
            UUID: [String: Set<ReconstructionArtifactOccurrenceID>]
        ] = [:]

        for manifest in manifests {
            try Task.checkCancellation()
            let projectID = manifest.reconstructionProjectID
            guard projectIDs.contains(projectID) else {
                throw Failure.manifestProjectOwnership
            }
            let recomputedManifestSHA256 = try ReconstructionCorpusCanonicalizer
                .canonicalSHA256(of: manifest)
            try Task.checkCancellation()
            guard recomputedManifestSHA256 == manifest.canonicalSHA256 else {
                throw Failure.manifestDigestDisagreement
            }
            var projectManifests = manifestsByProjectID[projectID] ?? [:]
            if let existing = projectManifests[manifest.canonicalSHA256] {
                guard existing == manifest else {
                    throw Failure.manifestDigestDisagreement
                }
                throw Failure.duplicateManifestDigest
            }
            projectManifests[manifest.canonicalSHA256] = manifest
            manifestsByProjectID[projectID] = projectManifests

            let localOccurrenceIDs = Set(manifest.artifacts.map(\.occurrenceID))
            var projectMembership = occurrenceIDsByManifest[projectID] ?? [:]
            projectMembership[manifest.canonicalSHA256] = localOccurrenceIDs
            occurrenceIDsByManifest[projectID] = projectMembership
            for occurrence in manifest.artifacts {
                try Task.checkCancellation()
                if let existing = occurrencesByID[occurrence.occurrenceID] {
                    guard existing.projectID == projectID,
                          existing.record == occurrence else {
                        throw Failure.occurrenceIdentityDisagreement
                    }
                } else {
                    occurrencesByID[occurrence.occurrenceID] = (projectID, occurrence)
                }
            }
            for relation in manifest.relations {
                try Task.checkCancellation()
                guard localOccurrenceIDs.contains(relation.sourceOccurrenceID),
                      relation.targetOccurrenceID.map(localOccurrenceIDs.contains) ?? true else {
                    throw Failure.artifactRelationEndpoint
                }
                if let existing = relationsByID[relation.relationID] {
                    guard existing.projectID == projectID,
                          existing.record == relation else {
                        throw Failure.relationIdentityDisagreement
                    }
                } else {
                    relationsByID[relation.relationID] = (projectID, relation)
                }
            }
        }

        for project in projects {
            try Task.checkCancellation()
            let retained = manifestsByProjectID[project.projectID] ?? [:]
            switch project.currentCorpusManifestSHA256 {
            case nil where retained.isEmpty:
                break
            case let digest? where retained[digest] != nil:
                break
            default:
                throw Failure.projectCurrentManifest
            }
        }

        self.manifestsByProjectID = manifestsByProjectID
        self.occurrencesByID = occurrencesByID
        self.relationsByID = relationsByID
        self.occurrenceIDsByManifest = occurrenceIDsByManifest
    }

    func manifest(projectID: UUID, canonicalSHA256: String) -> ReconstructionCorpusManifest? {
        manifestsByProjectID[projectID]?[canonicalSHA256]
    }

    func projectID(containing subject: ReconstructionSubjectCoordinate) -> UUID? {
        let artifact = Self.artifactCoordinate(for: subject)
        guard let occurrence = occurrencesByID[artifact.occurrenceID],
              occurrence.record.contentIdentity == artifact.contentIdentity else { return nil }
        return occurrence.projectID
    }

    func contains(
        _ subject: ReconstructionSubjectCoordinate,
        projectID: UUID,
        manifestSHA256: String
    ) -> Bool {
        let artifact = Self.artifactCoordinate(for: subject)
        guard let occurrence = occurrencesByID[artifact.occurrenceID],
              occurrence.projectID == projectID,
              occurrence.record.contentIdentity == artifact.contentIdentity else { return false }
        return occurrenceIDsByManifest[projectID]?[manifestSHA256]?.contains(
            artifact.occurrenceID
        ) == true
    }

    private static func artifactCoordinate(
        for subject: ReconstructionSubjectCoordinate
    ) -> ReconstructionArtifactCoordinate {
        switch subject {
        case .artifact(let coordinate): coordinate
        case .image(let coordinate): coordinate.artifact
        case .function(let coordinate): coordinate.artifact
        }
    }

    static func manifestPrecedes(
        _ lhs: ReconstructionCorpusManifest,
        _ rhs: ReconstructionCorpusManifest
    ) -> Bool {
        let lhsProjectID = lhs.reconstructionProjectID.uuidString
        let rhsProjectID = rhs.reconstructionProjectID.uuidString
        if lhsProjectID != rhsProjectID { return lhsProjectID < rhsProjectID }
        return lhs.canonicalSHA256 < rhs.canonicalSHA256
    }
}
