import Foundation

/// Immutable source-task resolution from the database owner's existing committed cut. The stage
/// contains only revalidated admitted bytes; neither model payloads nor a registry select authority.
struct ReconstructionProductionSourceCutResolver: ReconstructionProductionSourceTaskResolving {
    let basis: ReconstructionProductionRoundBasis
    let stageParent: URL
    let original: ReconstructionProductionSourceTaskResolution.Original?

    init(basis: ReconstructionProductionRoundBasis, stageParent: URL,
         original: ReconstructionProductionSourceTaskResolution.Original? = nil) {
        self.basis = basis; self.stageParent = stageParent; self.original = original
    }

    func resolve(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
                 cancellation: ReconstructionCancellation) async throws -> ReconstructionProductionSourceTaskResolution {
        try cancellation.check()
        let function = try ReconstructionProductionSourceCutBinding.function(task: task, authority: authority, basis: basis)
        _ = try ReconstructionProductionSourceCutBinding.macScopeEvidence(function: function, basis: basis)
        let profileID = try ReconstructionSourceProfile.retainedSourceProfile(basis.job.sourceProfileID).rawValue
        let work: ReconstructionProductionSourceTaskResolution.Work
        switch task.identity.operationContractIdentity {
        case ReconstructionSourceExecutionTaskContract.evaluate:
            let revisions = try ReconstructionProductionSourceAuthority.committedRevisions(function: function, basis: basis)
            guard let committed = revisions.last,
                  committed.context.checkpoint.revision <= basis.checkpoint.revision,
                  committed.record.creatingTaskID == previousModelTask(task)?.identity.taskID,
                  basis.evidenceCut.projectedClassificationsByEvidenceID[committed.record.evidenceID] == .acceptedCurrent else {
                throw ReconstructionProductionSourceCutBinding.Failure.invalidRevision
            }
            let captured = try ReconstructionProductionSourceAuthority.oracleContext(function: function, basis: basis)
            let oracle = try ReconstructionSourceExecutionWorkflow.ValidatedOracle(record: captured.record, context: captured.context)
            try cancellation.check()
            let stage = try ReconstructionSourceExecutionStage.create(revision: committed.revision,
                authority: committed.context.admissionAuthority,
                harness: ReconstructionSourceBehaviorHarness.forProfile(profileID), parent: stageParent)
            work = .evaluation(.init(stage: stage, revision: committed.revision,
                                    authority: committed.context.admissionAuthority, oracle: oracle))
        case ReconstructionSourceExecutionTaskContract.oracle:
            guard let original, original.function == function else {
                throw ReconstructionProductionSourceCutBinding.Failure.originalUnavailable
            }
            switch original {
            case .qualified(let stage, _):
                guard stage.profileID == profileID, case .trustedOriginal = stage.sourceAuthority else {
                    throw ReconstructionProductionSourceCutBinding.Failure.invalidOriginal
                }
                try stage.verifyInputs()
            case .prepared(let prepared, _):
                guard prepared.stage.profileID == profileID, prepared.failure == nil, case .trustedOriginal = prepared.stage.sourceAuthority,
                      prepared.hasPreparationPhases,
                      let executable = prepared.executable,
                      executable.sha256 == function.artifact.contentIdentity.digest,
                      UInt64(executable.byteCount) == function.artifact.contentIdentity.byteCount else {
                    throw ReconstructionProductionSourceCutBinding.Failure.invalidOriginal
                }
                try prepared.stage.verifyExecutable(executable)
            }
            work = .oracle(original)
        default: throw ReconstructionProductionSourceCutBinding.Failure.invalidTask
        }
        try cancellation.check()
        return .init(projectID: basis.project.projectID, taskID: task.identity.taskID, authority: authority, work: work)
    }

    private func previousModelTask(_ task: ReconstructionTaskRecord) -> ReconstructionTaskRecord? {
        guard let checkpointID = task.identity.dependencyTaskIDs.first,
              let checkpoint = basis.tasks.first(where: { $0.identity.taskID == checkpointID }),
              let previousID = checkpoint.identity.dependencyTaskIDs.first else { return nil }
        return basis.tasks.first { $0.identity.taskID == previousID }
    }
}

/// Assembles provenance from the workflow's actual terminal values and the exact accepted function
/// evidence. Receipt/checkpoint creation and persistence remain with their existing owner.
struct ReconstructionProductionSourceCutOracleAssembler: ReconstructionProductionSourceOracleAssembling {
    let basis: ReconstructionProductionRoundBasis
    let producer: ReconstructionProducerIdentity

    init(basis: ReconstructionProductionRoundBasis, producer: ReconstructionProducerIdentity) {
        self.basis = basis; self.producer = producer
    }

    func authority(projectID: UUID, task: ReconstructionTaskRecord,
                   batchAuthority: ReconstructionBatchAuthority,
                   outcome: ReconstructionSourceExecutionWorkflow.Outcome) async throws -> ReconstructionSourceOracleAuthority {
        try Task.checkCancellation()
        let function = try ReconstructionProductionSourceCutBinding.function(task: task, authority: batchAuthority, basis: basis)
        let evidenceIDs = try ReconstructionProductionSourceCutBinding.macScopeEvidence(function: function, basis: basis)
        guard projectID == basis.project.projectID,
              task.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle,
              producer.operationIdentity == ReconstructionSourceOracleEvidence.operationID,
              producer.modelKey == nil, producer.endpointOrigin == nil,
              try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(producer) == producer.canonicalSHA256,
              outcome.function == function, outcome.observedOriginal,
              outcome.sourceAuthority == .trustedOriginal(sourceSHA256: outcome.sourceSHA256),
              outcome.phases.map(\.request.operation) == (outcome.executableOrigin == .retained
                ? [.inspect, .behavior] : [.inspect, .compile, .behavior]),
              outcome.inspection != nil, outcome.astAdmission != nil,
              let executable = outcome.executable,
              executable.sha256 == function.artifact.contentIdentity.digest,
              UInt64(executable.byteCount) == function.artifact.contentIdentity.byteCount else {
            throw ReconstructionProductionSourceCutBinding.Failure.invalidOutcome
        }
        let phases = outcome.phases
        // A retained original was not compiled in this stage. Its compile-argument digest records the
        // fixed profile argv bound to this stage's paths (the inspect request carries the identical
        // compiler/SDK/stage fields); the executable itself is bound by the admitted SHA-256 above.
        let compile = phases[outcome.executableOrigin == .retained ? 0 : 1].request
        let behavior = phases[phases.count - 1].request
        guard Set(phases.map { $0.request.requestID }).count == phases.count,
              phases.allSatisfy({ phase in
                  let request = phase.request
                  guard let response = phase.response, let cleanup = response.cleanup else { return false }
                  return phase.transportError == nil && request.sessionID == behavior.sessionID
                      && request.stageRootPath == behavior.stageRootPath
                      && request.sourceAuthority == .original && request.revisionSHA256 == nil
                      && request.sourceSHA256 == outcome.sourceSHA256 && request.harnessSHA256 == outcome.harnessSHA256
                      && request.compilerPath == outcome.toolAuthority.compilerPath
                      && request.sdkRootPath == outcome.toolAuthority.sdkRootPath
                      && request.toolchainRootPath == outcome.toolAuthority.toolchainRootPath
                      && request.runnerSHA256 == outcome.toolAuthority.runnerSHA256
                      && request.compilerSHA256 == outcome.toolAuthority.compilerSHA256
                      && request.sdkSettingsSHA256 == outcome.toolAuthority.sdkSettingsSHA256
                      && response.requestID == request.requestID && response.sessionID == request.sessionID
                      && response.operation == request.operation && response.isValid && response.status == .completed
                      && response.failure == nil && response.terminal == .init(kind: .exited, status: 0)
                      && cleanup.requestID == request.requestID && cleanup.sessionID == request.sessionID
                      && cleanup.outcome == response.terminal && cleanup.observedProcessAbsent
                      && cleanup.processIdentifier > 0 && response.sampledProcessIDs.contains(cleanup.processIdentifier)
              }), let response = phases[phases.count - 1].response, let cleanup = response.cleanup else {
            throw ReconstructionProductionSourceCutBinding.Failure.invalidOutcome
        }
        let profileID = try ReconstructionSourceProfile.retainedSourceProfile(basis.job.sourceProfileID).rawValue
        guard phases.allSatisfy({ $0.request.sourceProfile?.rawValue == profileID }) else {
            throw ReconstructionProductionSourceCutBinding.Failure.invalidOutcome
        }
        let harness = try ReconstructionSourceBehaviorHarness.forProfile(profileID)
        let outputs = try harness.decodeObservedOutputs(response.diagnostics)
        guard outcome.harnessSHA256 == ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
              outcome.observations.map(\.input) == harness.inputs,
              outcome.observations.map(\.output) == outputs, outcome.mismatches.isEmpty else {
            throw ReconstructionProductionSourceCutBinding.Failure.invalidOutcome
        }
        let execution = ReconstructionSourceOracle.Execution(
            originalImageSHA256: function.artifact.contentIdentity.digest,
            originalExecutableSHA256: executable.sha256, originalSourceSHA256: outcome.sourceSHA256,
            harnessSHA256: outcome.harnessSHA256, compilerSHA256: outcome.toolAuthority.compilerSHA256,
            sdkIdentitySHA256: outcome.toolAuthority.sdkSettingsSHA256,
            compileProfileSHA256: try ReconstructionCanonicalJSON.sha256(of: CompileProfile(
                version: 1, profileID: profileID,
                runnerSHA256: outcome.toolAuthority.runnerSHA256,
                flags: Self.compilerFlags + ["-ffreestanding", "-fno-builtin", "-ferror-limit=8"],
                target: "arm64-apple-macos27.0", compilerSHA256: outcome.toolAuthority.compilerSHA256,
                sdkSettingsSHA256: outcome.toolAuthority.sdkSettingsSHA256)),
            compileArgumentsSHA256: try ReconstructionCanonicalJSON.sha256(of: Self.compileArguments(compile)),
            executionArgumentsSHA256: try ReconstructionCanonicalJSON.sha256(of: Self.behaviorArguments(behavior)),
            producerSHA256: producer.canonicalSHA256, standardOutput: response.diagnostics,
            sessionID: behavior.sessionID, requestID: behavior.requestID,
            processIdentifier: cleanup.processIdentifier, sampledProcessIDs: response.sampledProcessIDs,
            exitCode: 0, observedProcessAbsent: cleanup.observedProcessAbsent)
        let authority = ReconstructionSourceOracleAuthority(projectID: projectID, jobID: batchAuthority.jobID,
            function: function, execution: execution, evidenceIDs: evidenceIDs, profileID: profileID)
        _ = try ReconstructionSourceOracleEvidence.admit(authority: authority)
        try Task.checkCancellation()
        return authority
    }

    // These are the compiler and candidate argv vectors executed by SourceExecutionRunner/main.c.
    // Its sandbox launcher is confinement, attested separately by runnerSHA256; it is not an
    // additional compiler argument. Paths are taken only from actual typed phase requests.
    private static let compilerFlags = ["-std=c11", "-O0", "-Wall", "-Wextra", "-Werror"]
    static func compileArguments(_ request: Phase2SourceExecutionRequest) -> [String] {
        [request.compilerPath] + compilerFlags + ["-target", "arm64-apple-macos27.0", "-isysroot", request.sdkRootPath,
            "-ffreestanding", "-fno-builtin", "-ferror-limit=8", request.stageRootPath + "/candidate.c",
            request.stageRootPath + "/harness.c", "-o", request.stageRootPath + "/output/candidate"]
    }
    static func behaviorArguments(_ request: Phase2SourceExecutionRequest) -> [String] {
        [request.stageRootPath + "/output/candidate"]
    }
    private struct CompileProfile: Encodable {
        let version: Int
        let profileID: String
        let runnerSHA256: String
        let flags: [String]
        let target: String
        let compilerSHA256: String
        let sdkSettingsSHA256: String
    }
}

private enum ReconstructionProductionSourceCutBinding {
    enum Failure: Error, Equatable { case invalidCut, invalidTask, staleFunction, missingFunctionEvidence,
        invalidRevision, originalUnavailable, invalidOriginal, invalidOutcome }

    static func function(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
                         basis: ReconstructionProductionRoundBasis) throws -> ReconstructionFunctionCoordinate {
        try task.identity.verifyCanonicalIdentity()
        guard authority.jobID == basis.job.jobID,
              authority.checkpointID == basis.checkpoint.checkpointID,
              authority.checkpointRevision == basis.checkpoint.revision,
              authority.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
              basis.checkpoint.corpusManifestSHA256 == authority.corpusManifestSHA256 else { throw Failure.invalidCut }
        guard ReconstructionSourceExecutionTaskContract.admits(task), task.identity.jobID == authority.jobID,
              basis.tasks.contains(where: { $0.identity == task.identity && ReconstructionSourceExecutionTaskContract.admits($0) }),
              case .function(let function)? = task.identity.subject,
              task.identity.dependencyTaskIDs.count == 1,
              let dependency = basis.tasks.first(where: { $0.identity.taskID == task.identity.dependencyTaskIDs[0] }),
              dependency.identity.kind == .checkpoint, dependency.state == .completed,
              basis.checkpoint.completedTaskIDs.contains(dependency.identity.taskID),
              dependency.identity.dependencyTaskIDs.count == 1,
              let previous = basis.tasks.first(where: { $0.identity.taskID == dependency.identity.dependencyTaskIDs[0] }),
              previous.identity.kind == .modelRound, previous.state == .completed else { throw Failure.invalidTask }
        if task.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.evaluate {
            guard previous.identity.operationContractIdentity == ReconstructionProductionTaskContract.sourceRevision,
                  previous.identity.subject == .function(function) else { throw Failure.invalidTask }
        } else {
            guard previous.identity.operationContractIdentity != ReconstructionProductionTaskContract.sourceRevision else {
                throw Failure.invalidTask
            }
        }
        guard basis.freshnessAuthority.currentArtifacts.contains(function.artifact),
              basis.freshnessAuthority.currentImages.contains(where: {
                  $0.artifact == function.artifact && $0.image == function.image
                      && $0.analysisFingerprintSHA256 == function.analysisFingerprintSHA256
              }) else { throw Failure.staleFunction }
        return function
    }

    static func macScopeEvidence(function: ReconstructionFunctionCoordinate,
                                 basis: ReconstructionProductionRoundBasis) throws -> [UUID] {
        let records = basis.evidenceCut.records.filter {
            $0.creatingJobID == basis.job.jobID && $0.subject == .function(function)
                && $0.operationID == ReconstructionOperationID.decompilerMacScope.rawValue
                && basis.evidenceCut.projectedClassificationsByEvidenceID[$0.evidenceID] == .acceptedCurrent
        }
        guard !records.isEmpty, records.count <= 64 else { throw Failure.missingFunctionEvidence }
        for record in records {
            guard record.payloadByteCount == UInt64(record.payload.count),
                  record.payloadSHA256 == ReconstructionSourceRevisionAdmission.sourceSHA256(record.payload),
                  let task = basis.tasks.first(where: { $0.identity.taskID == record.creatingTaskID }),
                  task.identity.kind == .decompileMacScope, task.identity.subject == record.subject, task.state == .completed,
                  let receipt = basis.toolReceipts.first(where: { $0.receiptID == record.toolReceiptID }),
                  receipt.jobID == basis.job.jobID, receipt.taskID == task.identity.taskID,
                  receipt.terminalState == .completed, receipt.diagnostic == nil,
                  receipt.outputEvidenceIDs.contains(record.evidenceID), receipt.producer == record.producer,
                  record.producer.operationIdentity == ReconstructionOperationID.decompilerMacScope.rawValue,
                  record.producer.modelKey == nil, record.producer.endpointOrigin == nil,
                  try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt),
                  try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(record.producer) == record.producer.canonicalSHA256 else {
                throw Failure.missingFunctionEvidence
            }
        }
        return ReconstructionValidation.sortedUUIDs(records.map(\.evidenceID))
    }
}
