import Foundation

struct ReconstructionWorkspaceStateBinding: Hashable, Sendable {
    let workspaceID: UUID
    let documentID: UUID

    /// A standardized, absolute package path supplied by the document/runtime boundary.
    /// This value is compared exactly; the reconciler never resolves or reopens it.
    let canonicalPackagePath: String
}

struct ReconstructionWorkspaceContentAvailability: Hashable, Sendable {
    let contentIdentity: ReconstructionContentIdentity
    let isAvailable: Bool
}

struct ReconstructionWorkspaceStateCut: Equatable, Sendable {
    let binding: ReconstructionWorkspaceStateBinding
    let state: ReconstructionWorkspaceState
    let contentAvailability: [ReconstructionWorkspaceContentAvailability]
}

enum ReconstructionDurableCorpusBasis: Equatable, Sendable {
    case untrusted

    /// The runtime proved this cut came from MacScope's app-owned durable database for the exact
    /// workspace/document/path binding. This is the only authority that may advance a project's
    /// current corpus, because corpus manifests do not persist a parent edge.
    case trustedSamePathAppOwned
}

enum ReconstructionDurableWorkspaceStateCut: Equatable, Sendable {
    /// Absence must be established by the durable owner. An empty state is not proof of absence.
    case absent(binding: ReconstructionWorkspaceStateBinding)
    case present(
        cut: ReconstructionWorkspaceStateCut,
        corpusBasis: ReconstructionDurableCorpusBasis
    )
}

struct ReconstructionRequiredContentAvailability: Hashable, Sendable {
    let contentIdentity: ReconstructionContentIdentity
    let isAvailableFromPackage: Bool
    let isAvailableFromDurable: Bool
}

struct ReconstructionWorkspaceStateResolution: Equatable, Sendable {
    let state: ReconstructionWorkspaceState
    let requiredContentAvailability: [ReconstructionRequiredContentAvailability]
}

enum ReconstructionWorkspaceStateRecordKind: String, Equatable, Sendable {
    case project
    case corpusManifest
    case evidence
    case evidenceRelation
    case evidenceGap
    case job
    case task
    case checkpoint
    case toolReceipt
    case modelReceipt
}

enum ReconstructionWorkspaceStateConflictReason: Equatable, Sendable {
    case invalidCanonicalPackagePath
    case workspaceIdentityMismatch
    case documentIdentityMismatch
    case canonicalPackagePathMismatch
    case invalidPackageState
    case invalidDurableState
    case packageSourceCatalogMismatch
    case durableSourceCatalogMismatch
    case contentIdentityConflict(String)
    case missingRequiredSource(ReconstructionContentIdentity)
    case untrustedCorpusAncestry(UUID)
    case missingAncestorRecord(ReconstructionWorkspaceStateRecordKind, String)
    case immutableRecordDrift(ReconstructionWorkspaceStateRecordKind, String)
    case jobStateRegression(UUID)
    case taskStateRegression(UUID)
    case checkpointAncestryDiverged(UUID)
    case authorityDiverged
}

enum ReconstructionWorkspaceStateReconciliationDecision: Equatable, Sendable {
    case seedPackage(ReconstructionWorkspaceStateResolution)
    case equal(ReconstructionWorkspaceStateResolution)
    case useDurableDescendant(ReconstructionWorkspaceStateResolution)
    case fastForwardDurableFromPackage(ReconstructionWorkspaceStateResolution)
    case conflict(ReconstructionWorkspaceStateConflictReason)
}

/// Pure, fail-closed selection between package and durable Reconstruction authority.
///
/// The caller remains responsible for retaining the real attachment-source objects (and their
/// private lifetime tokens), mapping this value-only content decision back to those sources, and
/// atomically publishing the selected state before any job is resumed.
enum ReconstructionWorkspaceStateReconciler {
    static func reconcile(
        package: ReconstructionWorkspaceStateCut,
        durable: ReconstructionDurableWorkspaceStateCut
    ) throws -> ReconstructionWorkspaceStateReconciliationDecision {
        try Task.checkCancellation()
        guard isCanonicalAbsolutePackagePath(package.binding.canonicalPackagePath) else {
            return .conflict(.invalidCanonicalPackagePath)
        }

        switch durable {
        case .absent(let durableBinding):
            if let conflict = bindingConflict(package.binding, durableBinding) {
                return .conflict(conflict)
            }
            guard try canonicalStateIsValid(package.state) else {
                return .conflict(.invalidPackageState)
            }
            switch try validateCatalog(package, role: .package) {
            case .failure(let conflict):
                return .conflict(conflict)
            case .success:
                break
            }
            return try resolution(
                state: package.state,
                package: package,
                durable: nil
            ).mapDecision(ReconstructionWorkspaceStateReconciliationDecision.seedPackage)

        case .present(let durableCut, let corpusBasis):
            if let conflict = bindingConflict(package.binding, durableCut.binding) {
                return .conflict(conflict)
            }
            guard try canonicalStateIsValid(package.state) else {
                return .conflict(.invalidPackageState)
            }
            guard try canonicalStateIsValid(durableCut.state) else {
                return .conflict(.invalidDurableState)
            }
            switch try validateCatalog(package, role: .package) {
            case .failure(let conflict):
                return .conflict(conflict)
            case .success:
                break
            }
            switch try validateCatalog(durableCut, role: .durable) {
            case .failure(let conflict):
                return .conflict(conflict)
            case .success:
                break
            }
            if let conflict = crossCatalogConflict(package, durableCut) {
                return .conflict(conflict)
            }

            if package.state == durableCut.state {
                return try resolution(
                    state: package.state,
                    package: package,
                    durable: durableCut
                ).mapDecision(ReconstructionWorkspaceStateReconciliationDecision.equal)
            }

            let durableProof = try proveDescendant(
                durableCut.state,
                of: package.state,
                permitsCorpusAdvance: corpusBasis == .trustedSamePathAppOwned
            )
            if case .proven = durableProof {
                return try resolution(
                    state: durableCut.state,
                    package: package,
                    durable: durableCut
                ).mapDecision(
                    ReconstructionWorkspaceStateReconciliationDecision.useDurableDescendant
                )
            }

            let packageProof = try proveDescendant(
                package.state,
                of: durableCut.state,
                permitsCorpusAdvance: false
            )
            if case .proven = packageProof {
                return try resolution(
                    state: package.state,
                    package: package,
                    durable: durableCut
                ).mapDecision(
                    ReconstructionWorkspaceStateReconciliationDecision
                        .fastForwardDurableFromPackage
                )
            }

            let durableFailure = durableProof.failure
            let packageFailure = packageProof.failure
            return .conflict(classifyDivergence(
                package: package.state,
                durable: durableCut.state,
                durableFailure: durableFailure,
                packageFailure: packageFailure
            ))
        }
    }

    private enum CatalogRole {
        case package
        case durable
    }

    private enum CatalogValidation {
        case success
        case failure(ReconstructionWorkspaceStateConflictReason)
    }

    private enum ResolutionResult {
        case success(ReconstructionWorkspaceStateResolution)
        case failure(ReconstructionWorkspaceStateConflictReason)

        func mapDecision(
            _ transform: (ReconstructionWorkspaceStateResolution)
                -> ReconstructionWorkspaceStateReconciliationDecision
        ) -> ReconstructionWorkspaceStateReconciliationDecision {
            switch self {
            case .success(let resolution): transform(resolution)
            case .failure(let conflict): .conflict(conflict)
            }
        }
    }

    private enum DescendantProof {
        case proven
        case refused(ReconstructionWorkspaceStateConflictReason)

        var failure: ReconstructionWorkspaceStateConflictReason? {
            guard case .refused(let failure) = self else { return nil }
            return failure
        }
    }

    private struct CorpusManifestKey: Hashable {
        let projectID: UUID
        let canonicalSHA256: String
    }

    private static func isCanonicalAbsolutePackagePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func bindingConflict(
        _ package: ReconstructionWorkspaceStateBinding,
        _ durable: ReconstructionWorkspaceStateBinding
    ) -> ReconstructionWorkspaceStateConflictReason? {
        guard isCanonicalAbsolutePackagePath(durable.canonicalPackagePath) else {
            return .invalidCanonicalPackagePath
        }
        guard package.workspaceID == durable.workspaceID else {
            return .workspaceIdentityMismatch
        }
        guard package.documentID == durable.documentID else {
            return .documentIdentityMismatch
        }
        guard package.canonicalPackagePath == durable.canonicalPackagePath else {
            return .canonicalPackagePathMismatch
        }
        return nil
    }

    private static func canonicalStateIsValid(
        _ state: ReconstructionWorkspaceState
    ) throws -> Bool {
        do {
            let normalized = try state.normalizedJobRecords()
            guard normalized == state else { return false }
            let encoded = try ReconstructionPackageCodec.encode(normalized)
            let reopened = try ReconstructionPackageCodec.decode(
                descriptor: encoded.descriptor,
                corpusData: encoded.corpusData,
                evidenceData: encoded.evidenceData,
                checkpointData: encoded.checkpointData
            )
            return reopened == normalized
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            return false
        }
    }

    private static func validateCatalog(
        _ cut: ReconstructionWorkspaceStateCut,
        role: CatalogRole
    ) throws -> CatalogValidation {
        let mismatch: ReconstructionWorkspaceStateConflictReason = role == .package
            ? .packageSourceCatalogMismatch
            : .durableSourceCatalogMismatch
        let required = try ReconstructionPackageCodec.contentRecords(in: cut.state)
            .map(\.contentIdentity)
        var providedByIdentity: [
            ReconstructionContentIdentity: ReconstructionWorkspaceContentAvailability
        ] = [:]
        var providedByDigest: [String: ReconstructionContentIdentity] = [:]
        for availability in cut.contentAvailability {
            try Task.checkCancellation()
            let identity = availability.contentIdentity
            if let existing = providedByDigest[identity.digest], existing != identity {
                return .failure(.contentIdentityConflict(identity.digest))
            }
            providedByDigest[identity.digest] = identity
            guard providedByIdentity.updateValue(availability, forKey: identity) == nil else {
                return .failure(mismatch)
            }
        }
        guard Set(providedByIdentity.keys) == Set(required) else {
            return .failure(mismatch)
        }
        return .success
    }

    private static func crossCatalogConflict(
        _ package: ReconstructionWorkspaceStateCut,
        _ durable: ReconstructionWorkspaceStateCut
    ) -> ReconstructionWorkspaceStateConflictReason? {
        var identitiesByDigest: [String: ReconstructionContentIdentity] = [:]
        for availability in package.contentAvailability + durable.contentAvailability {
            let identity = availability.contentIdentity
            if let existing = identitiesByDigest[identity.digest], existing != identity {
                return .contentIdentityConflict(identity.digest)
            }
            identitiesByDigest[identity.digest] = identity
        }
        return nil
    }

    private static func resolution(
        state: ReconstructionWorkspaceState,
        package: ReconstructionWorkspaceStateCut,
        durable: ReconstructionWorkspaceStateCut?
    ) throws -> ResolutionResult {
        let required = try ReconstructionPackageCodec.contentRecords(in: state)
            .map(\.contentIdentity)
        let packageAvailability = Dictionary(uniqueKeysWithValues: package.contentAvailability.map {
            ($0.contentIdentity, $0.isAvailable)
        })
        let durableAvailability = Dictionary(uniqueKeysWithValues:
            (durable?.contentAvailability ?? []).map {
                ($0.contentIdentity, $0.isAvailable)
            }
        )
        var selected: [ReconstructionRequiredContentAvailability] = []
        selected.reserveCapacity(required.count)
        for identity in required {
            try Task.checkCancellation()
            let packageHasSource = packageAvailability[identity] == true
            let durableHasSource = durableAvailability[identity] == true
            guard packageHasSource || durableHasSource else {
                return .failure(.missingRequiredSource(identity))
            }
            selected.append(ReconstructionRequiredContentAvailability(
                contentIdentity: identity,
                isAvailableFromPackage: packageHasSource,
                isAvailableFromDurable: durableHasSource
            ))
        }
        return .success(ReconstructionWorkspaceStateResolution(
            state: state,
            requiredContentAvailability: selected.sorted {
                $0.contentIdentity.digest < $1.contentIdentity.digest
            }
        ))
    }

    private static func proveDescendant(
        _ candidate: ReconstructionWorkspaceState,
        of ancestor: ReconstructionWorkspaceState,
        permitsCorpusAdvance: Bool
    ) throws -> DescendantProof {
        try Task.checkCancellation()
        guard candidate.schemaVersion == ancestor.schemaVersion else {
            return .refused(.immutableRecordDrift(.project, "workspace-schema"))
        }

        let candidateProjects = Dictionary(uniqueKeysWithValues: candidate.projects.map {
            ($0.projectID, $0)
        })
        for project in ancestor.projects {
            try Task.checkCancellation()
            guard let successor = candidateProjects[project.projectID] else {
                return .refused(.missingAncestorRecord(
                    .project,
                    project.projectID.uuidString.lowercased()
                ))
            }
            guard successor.schemaVersion == project.schemaVersion,
                  successor.projectID == project.projectID,
                  successor.name == project.name else {
                return .refused(.immutableRecordDrift(
                    .project,
                    project.projectID.uuidString.lowercased()
                ))
            }
            if successor.currentCorpusManifestSHA256 != project.currentCorpusManifestSHA256,
               !permitsCorpusAdvance {
                return .refused(.untrustedCorpusAncestry(project.projectID))
            }
        }

        if let failure = try exactSuperset(
            ancestor: ancestor.corpusManifests,
            candidate: candidate.corpusManifests,
            keyedBy: { CorpusManifestKey(
                projectID: $0.reconstructionProjectID,
                canonicalSHA256: $0.canonicalSHA256
            ) },
            kind: .corpusManifest,
            identifier: { "\($0.projectID.uuidString.lowercased())/\($0.canonicalSHA256)" }
        ) { return .refused(failure) }
        if let failure = try exactSuperset(
            ancestor: ancestor.evidence,
            candidate: candidate.evidence,
            keyedBy: \.evidenceID,
            kind: .evidence,
            identifier: { $0.uuidString.lowercased() }
        ) { return .refused(failure) }
        if let failure = try exactSuperset(
            ancestor: ancestor.evidenceRelations,
            candidate: candidate.evidenceRelations,
            keyedBy: \.relationID,
            kind: .evidenceRelation,
            identifier: { $0.uuidString.lowercased() }
        ) { return .refused(failure) }
        if let failure = try exactSuperset(
            ancestor: ancestor.evidenceGaps,
            candidate: candidate.evidenceGaps,
            keyedBy: \.gapID,
            kind: .evidenceGap,
            identifier: { $0.uuidString.lowercased() }
        ) { return .refused(failure) }
        if let failure = try exactSuperset(
            ancestor: ancestor.toolReceipts,
            candidate: candidate.toolReceipts,
            keyedBy: \.receiptID,
            kind: .toolReceipt,
            identifier: { $0.uuidString.lowercased() }
        ) { return .refused(failure) }
        if let failure = try exactSuperset(
            ancestor: ancestor.modelReceipts,
            candidate: candidate.modelReceipts,
            keyedBy: \.receiptID,
            kind: .modelReceipt,
            identifier: { $0.uuidString.lowercased() }
        ) { return .refused(failure) }
        if let failure = try exactSuperset(
            ancestor: ancestor.checkpoints,
            candidate: candidate.checkpoints,
            keyedBy: \.checkpointID,
            kind: .checkpoint,
            identifier: { $0.uuidString.lowercased() }
        ) { return .refused(failure) }

        guard candidate.jobs.count >= ancestor.jobs.count else {
            return .refused(.missingAncestorRecord(.job, "creation-order-prefix"))
        }
        let candidateJobs = Dictionary(uniqueKeysWithValues: candidate.jobs.map { ($0.jobID, $0) })
        let candidateCheckpoints = Dictionary(uniqueKeysWithValues: candidate.checkpoints.map {
            ($0.checkpointID, $0)
        })
        var advancedJobIDs = Set<UUID>()
        for (index, job) in ancestor.jobs.enumerated() {
            try Task.checkCancellation()
            let candidateAtOrdinal = candidate.jobs[index]
            guard candidateAtOrdinal.jobID == job.jobID,
                  candidateAtOrdinal.creationOrdinal == job.creationOrdinal else {
                return .refused(.immutableRecordDrift(
                    .job,
                    job.jobID.uuidString.lowercased()
                ))
            }
            guard let successor = candidateJobs[job.jobID] else {
                return .refused(.missingAncestorRecord(
                    .job,
                    job.jobID.uuidString.lowercased()
                ))
            }
            // A feature scope is admitted once without a checkpoint and never changes afterwards.
            guard immutableJobProjection(successor) == immutableJobProjection(job),
                  job.featureScope == nil || successor.featureScope == job.featureScope else {
                return .refused(.immutableRecordDrift(
                    .job,
                    job.jobID.uuidString.lowercased()
                ))
            }
            if successor.currentCheckpointID == job.currentCheckpointID {
                let admittedOnly = job.featureScope == nil && successor.featureScope != nil
                guard successor == job || (admittedOnly && (try? successor.removingFeatureScope()) == job) else {
                    return .refused(.immutableRecordDrift(
                        .job,
                        job.jobID.uuidString.lowercased()
                    ))
                }
            } else {
                // Admission never advances a checkpoint, so an advancing step cannot add a scope.
                guard successor.featureScope == job.featureScope,
                      let successorCheckpointID = successor.currentCheckpointID else {
                    return .refused(.checkpointAncestryDiverged(job.jobID))
                }
                if let ancestorCheckpointID = job.currentCheckpointID,
                   !checkpoint(
                       successorCheckpointID,
                       reaches: ancestorCheckpointID,
                       in: candidateCheckpoints
                   ) {
                    return .refused(.checkpointAncestryDiverged(job.jobID))
                }
                guard jobTransitionCanAdvance(from: job, to: successor) else {
                    return .refused(.jobStateRegression(job.jobID))
                }
                advancedJobIDs.insert(job.jobID)
            }
        }
        for index in ancestor.jobs.count..<candidate.jobs.count {
            try Task.checkCancellation()
            guard candidate.jobs[index].creationOrdinal == UInt64(index + 1) else {
                return .refused(.immutableRecordDrift(
                    .job,
                    candidate.jobs[index].jobID.uuidString.lowercased()
                ))
            }
        }

        let candidateTasks = Dictionary(uniqueKeysWithValues: candidate.tasks.map {
            ($0.identity.taskID, $0)
        })
        let ancestorTaskIDs = Set(ancestor.tasks.map { $0.identity.taskID })
        for task in ancestor.tasks {
            try Task.checkCancellation()
            let taskID = task.identity.taskID
            guard let successor = candidateTasks[taskID] else {
                return .refused(.missingAncestorRecord(
                    .task,
                    taskID.uuidString.lowercased()
                ))
            }
            guard successor.identity == task.identity else {
                return .refused(.immutableRecordDrift(
                    .task,
                    taskID.uuidString.lowercased()
                ))
            }
            if successor != task {
                guard advancedJobIDs.contains(task.identity.jobID) else {
                    return .refused(.immutableRecordDrift(
                        .task,
                        taskID.uuidString.lowercased()
                    ))
                }
                guard taskTransitionCanAdvance(from: task, to: successor) else {
                    return .refused(.taskStateRegression(taskID))
                }
            }
        }
        for task in candidate.tasks where !ancestorTaskIDs.contains(task.identity.taskID) {
            try Task.checkCancellation()
            if ancestor.jobs.contains(where: { $0.jobID == task.identity.jobID }),
               !advancedJobIDs.contains(task.identity.jobID) {
                return .refused(.checkpointAncestryDiverged(task.identity.jobID))
            }
        }
        return .proven
    }

    private struct ImmutableJobProjection: Equatable {
        let recordSchemaVersion: Int
        let creationOrdinal: UInt64?
        let jobID: UUID
        let reconstructionProjectID: UUID
        let objective: String
        let objectiveSHA256: String
        let creationCorpusManifestSHA256: String
        let budget: ReconstructionJobBudget
        let focus: ReconstructionSubjectCoordinate?
        let sourceProfileID: String?
    }

    private static func immutableJobProjection(
        _ job: ReconstructionJobRecord
    ) -> ImmutableJobProjection {
        ImmutableJobProjection(
            // Schema 6 only marks an admitted scope; compare the underlying record schema.
            recordSchemaVersion: job.featureScope == nil ? job.recordSchemaVersion : ReconstructionJobRecord.schemaVersion,
            creationOrdinal: job.creationOrdinal,
            jobID: job.jobID,
            reconstructionProjectID: job.reconstructionProjectID,
            objective: job.objective,
            objectiveSHA256: job.objectiveSHA256,
            creationCorpusManifestSHA256: job.creationCorpusManifestSHA256,
            budget: job.budget,
            focus: job.focus,
            sourceProfileID: job.sourceProfileID
        )
    }

    private static func taskTransitionCanAdvance(
        from ancestor: ReconstructionTaskRecord,
        to candidate: ReconstructionTaskRecord
    ) -> Bool {
        guard ancestor.identity == candidate.identity else { return false }
        if ancestor.state == candidate.state { return ancestor == candidate }
        switch ancestor.state {
        case .pending:
            return candidate.state == .running
                || candidate.state == .completed
                || candidate.state == .failed
                || candidate.state == .blocked
                || candidate.state == .cancelled
        case .running:
            return candidate.state == .pending
                || candidate.state == .completed
                || candidate.state == .failed
                || candidate.state == .blocked
                || candidate.state == .cancelled
        case .completed, .failed, .blocked, .cancelled:
            return false
        }
    }

    private static func jobTransitionCanAdvance(
        from ancestor: ReconstructionJobRecord,
        to candidate: ReconstructionJobRecord
    ) -> Bool {
        if ancestor.state == candidate.state {
            return ReconstructionJobState.activeStates.contains(candidate.state)
                && ancestor.pauseContext == nil
                && candidate.pauseContext == nil
                && ancestor.terminalReason == candidate.terminalReason
        }

        let resumeTarget: ReconstructionJobState? = if ancestor.state == .paused {
            candidate.state == .cancelled || candidate.state == .failed
                ? nil
                : ancestor.pauseContext?.resumeTarget
        } else if candidate.state == .paused {
            candidate.pauseContext?.resumeTarget
        } else {
            nil
        }
        do {
            try ReconstructionJobStateMachine.transition(
                from: ancestor.state,
                to: candidate.state,
                resumeTarget: resumeTarget
            )
            return true
        } catch {
            return false
        }
    }

    private static func checkpoint(
        _ candidateTailID: UUID,
        reaches ancestorCheckpointID: UUID,
        in checkpoints: [UUID: ReconstructionCheckpoint]
    ) -> Bool {
        var currentID = candidateTailID
        var visited = Set<UUID>()
        while visited.insert(currentID).inserted {
            guard let current = checkpoints[currentID] else { return false }
            if currentID == ancestorCheckpointID { return true }
            guard let parentID = current.parentCheckpointID,
                  let parent = checkpoints[parentID],
                  current.parentCheckpointSHA256 == parent.canonicalSHA256,
                  current.revision == parent.revision + 1 else {
                return false
            }
            currentID = parentID
        }
        return false
    }

    private static func exactSuperset<Value: Equatable, Key: Hashable>(
        ancestor: [Value],
        candidate: [Value],
        keyedBy key: (Value) -> Key,
        kind: ReconstructionWorkspaceStateRecordKind,
        identifier: (Key) -> String
    ) throws -> ReconstructionWorkspaceStateConflictReason? {
        let candidateByKey = Dictionary(uniqueKeysWithValues: candidate.map { (key($0), $0) })
        for record in ancestor {
            try Task.checkCancellation()
            let recordKey = key(record)
            guard let successor = candidateByKey[recordKey] else {
                return .missingAncestorRecord(kind, identifier(recordKey))
            }
            guard successor == record else {
                return .immutableRecordDrift(kind, identifier(recordKey))
            }
        }
        return nil
    }

    private static func classifyDivergence(
        package: ReconstructionWorkspaceState,
        durable: ReconstructionWorkspaceState,
        durableFailure: ReconstructionWorkspaceStateConflictReason?,
        packageFailure: ReconstructionWorkspaceStateConflictReason?
    ) -> ReconstructionWorkspaceStateConflictReason {
        if let durableFailure,
           case .untrustedCorpusAncestry = durableFailure {
            return durableFailure
        }
        if let packageFailure,
           case .untrustedCorpusAncestry = packageFailure {
            return packageFailure
        }
        if let jobID = divergentCheckpointJob(package: package, durable: durable) {
            return .checkpointAncestryDiverged(jobID)
        }
        for failure in [durableFailure, packageFailure] {
            guard let failure else { continue }
            switch failure {
            case .immutableRecordDrift, .jobStateRegression, .taskStateRegression:
                return failure
            default:
                break
            }
        }
        for failure in [durableFailure, packageFailure] {
            guard let failure else { continue }
            if case .missingAncestorRecord = failure { return failure }
        }
        return .authorityDiverged
    }

    private static func divergentCheckpointJob(
        package: ReconstructionWorkspaceState,
        durable: ReconstructionWorkspaceState
    ) -> UUID? {
        let packageJobs = Dictionary(uniqueKeysWithValues: package.jobs.map { ($0.jobID, $0) })
        let durableJobs = Dictionary(uniqueKeysWithValues: durable.jobs.map { ($0.jobID, $0) })
        let packageCheckpoints = Dictionary(uniqueKeysWithValues: package.checkpoints.map {
            ($0.checkpointID, $0)
        })
        let durableCheckpoints = Dictionary(uniqueKeysWithValues: durable.checkpoints.map {
            ($0.checkpointID, $0)
        })
        for jobID in Set(packageJobs.keys).intersection(durableJobs.keys).sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard let packageCurrent = packageJobs[jobID]?.currentCheckpointID,
                  let durableCurrent = durableJobs[jobID]?.currentCheckpointID,
                  packageCurrent != durableCurrent else { continue }
            let packageReachesDurable = checkpoint(
                packageCurrent,
                reaches: durableCurrent,
                in: packageCheckpoints
            )
            let durableReachesPackage = checkpoint(
                durableCurrent,
                reaches: packageCurrent,
                in: durableCheckpoints
            )
            if !packageReachesDurable && !durableReachesPackage { return jobID }
        }
        return nil
    }
}
