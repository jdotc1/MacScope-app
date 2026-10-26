import CryptoKit
import Foundation

/// Bounded production model preparation. A regular round exposes one deterministic evidence-query
/// handle and optionally one exact, focused analysis demand; a final-synthesis round exposes no
/// tools. Neither branch can run until its exact model
/// leaf has been committed in `.running` state.
struct ReconstructionProductionPreparedRoundBuilder:
    ReconstructionProductionPreparedRoundBuilding
{
    private let evidenceQueryProducer: ReconstructionProducerIdentity
    private let analysisRefreshProducer: ReconstructionProducerIdentity?
    private let sourceOriginalRecovery: (any ReconstructionSourceOriginalRecovering)?
    private let nativePublications: ReconstructionTransientNativePublicationRegistry
    private let transientBudgetBytes: Int?
    private let replayOwner: ReconstructionDatabaseOwner?

    init(evidenceQueryProducer: ReconstructionProducerIdentity,
         analysisRefreshProducer: ReconstructionProducerIdentity? = nil,
         sourceOriginalRecovery: (any ReconstructionSourceOriginalRecovering)? = nil,
         nativePublications: ReconstructionTransientNativePublicationRegistry = .shared,
         transientBudgetBytes: Int? = nil,
         replayOwner: ReconstructionDatabaseOwner? = nil) throws {
        guard evidenceQueryProducer.operationIdentity
                == ReconstructionOperationID.evidenceQuery.rawValue,
              try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(
                evidenceQueryProducer
              ) == evidenceQueryProducer.canonicalSHA256 else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        self.evidenceQueryProducer = evidenceQueryProducer
        if let analysisRefreshProducer {
            guard analysisRefreshProducer.operationIdentity
                    == ReconstructionOperationID.analysisMacScopeRefresh.rawValue,
                  try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(
                    analysisRefreshProducer) == analysisRefreshProducer.canonicalSHA256 else {
                throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
            }
        }
        self.analysisRefreshProducer = analysisRefreshProducer
        self.sourceOriginalRecovery = sourceOriginalRecovery
        self.nativePublications = nativePublications
        self.transientBudgetBytes = transientBudgetBytes
        self.replayOwner = replayOwner
    }

    func makePreparedRound(
        from basis: ReconstructionProductionRoundBasis
    ) async throws -> ReconstructionPreparedModelRound {
        if let frontier = try ReconstructionProductionRoundPlanBuilder
            .authorizedSourceRevisionFrontier(in: basis.tasks) {
            return try Self.makeSourcePreparedRound(from: basis, frontier: frontier)
        }
        if try ReconstructionProductionRoundPlanBuilder
            .authorizedFinalSynthesisFrontier(in: basis.tasks) != nil {
            return try Self.makePreparedRound(
                from: basis,
                requestTaskID: basis.job.jobID,
                offersModelTool: false,
                buildsFinalSynthesisRequest: true,
                evidenceQueryProducer: nil
            )
        }
        guard let frontier = try ReconstructionProductionRoundPlanBuilder
            .authorizedRegularModelFrontier(in: basis.tasks) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        if ReconstructionSourceProfile.admits(basis.job.sourceProfileID) {
            _ = try await sourceOriginalRecovery?.session(for: basis)
        }
        let prepared = try Self.makePreparedRound(
            from: basis,
            requestTaskID: frontier.retrieve.identity.taskID,
            offersModelTool: true,
            buildsFinalSynthesisRequest: false,
            evidenceQueryProducer: evidenceQueryProducer,
            analysisRefreshProducer: analysisRefreshProducer
        )
        let sessionPresent = await ReconstructionSourceOriginalSessionRegistry.shared.session(
            workspaceID: basis.workspaceID, jobID: basis.job.jobID) != nil
        let sourceRequested = ReconstructionSourceProfile.admits(basis.job.sourceProfileID) || sessionPresent
        let sourceFunction = try await ReconstructionSourceOriginalSessionRegistry.shared.targetFunction(in: basis)
        var transient = try await transientAnalysis(for: basis, prepared: prepared)
        // After a restart the process-local native publications are gone. Committed native tasks
        // still exist, so the projector reports every target `.unavailable` with no facts and no
        // publication generation. That is the same "no current facts" state as nil: try the
        // frozen prompt observation of an already published reply (identical nontransient request
        // only; Ready admission still checks the complete prompt key). Any real current fact or
        // publication-derived omission keeps the fresh projection.
        let publicationsUnavailable = transient.map { current in
            current.facts.isEmpty && !current.omissions.isEmpty && current.omissions.allSatisfy {
                $0.reason == .unavailable && $0.publicationGeneration == nil
            }
        } ?? true
        if publicationsUnavailable, let replayOwner, let objective = prepared.objective {
            let context = try ReconstructionContextCompiler().compile(cut: prepared.evidenceCut,
                query: prepared.retrievalQuery, allowedGapSubjects: prepared.allowedGapSubjects,
                allowedGapCategories: prepared.allowedGapCategories)
            let handles = try ReconstructionToolRegistry().mintHandles(authority: prepared.authority,
                requests: prepared.requests)
            let request = ReconstructionInferenceRoundRequest(protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
                jobID: basis.job.jobID, checkpointRevision: basis.checkpoint.revision, roundID: prepared.roundID,
                corpusManifestSHA256: prepared.authority.corpusManifestSHA256,
                evidenceFrontierSHA256: prepared.authority.evidenceFrontierSHA256,
                registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
                context: context, handles: handles.map { .init(handleID: $0.handleID, operationID: $0.operationID) })
            if let recovered = try await replayOwner.historicalReplyPromptTransient(workspaceID: basis.workspaceID,
                jobID: basis.job.jobID, taskID: frontier.model.identity.taskID,
                objective: objective, request: request) {
                transient = recovered
            }
        }
        return ReconstructionPreparedModelRound(roundID: prepared.roundID, evidenceCut: prepared.evidenceCut,
            retrievalQuery: prepared.retrievalQuery, allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories, authority: prepared.authority,
            requests: prepared.requests, projectorInput: prepared.projectorInput,
            sourceOracleFunction: sourceFunction, sourceOracleRequested: sourceRequested,
            finalSynthesisRequest: prepared.finalSynthesisRequest,
            objective: prepared.objective, readContinuation: prepared.readContinuation,
            transientAnalysis: transient)
    }

    /// Projects admitted native results at this exact committed cut. Only the R2 regular-round
    /// request carries them; final synthesis and source rounds never do. Nothing is persisted.
    private func transientAnalysis(
        for basis: ReconstructionProductionRoundBasis,
        prepared: ReconstructionPreparedModelRound
    ) async throws -> ReconstructionTransientAnalysis? {
        guard prepared.objective != nil else { return nil }
        let publications = await nativePublications.publications(
            workspaceID: basis.workspaceID, jobID: basis.job.jobID)
        guard ReconstructionTransientNativeProjector.hasCandidates(
            basis: basis, publications: publications) else { return nil }
        let context = try ReconstructionContextCompiler().compile(
            cut: prepared.evidenceCut, query: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories)
        let budget = transientBudgetBytes ?? ReconstructionTransientNativeProjector.budgetBytes(
            contextCanonicalBytes: context.canonicalBytes.count)
        return try ReconstructionTransientNativeProjector.project(
            basis: basis, roundID: prepared.roundID, query: prepared.retrievalQuery,
            evidenceIDs: context.evidenceIDs, publications: publications, budgetBytes: budget)
    }

    static func makeDirectCommitDescriptor(
        from basis: ReconstructionProductionRoundBasis
    ) throws -> ReconstructionPreparedModelRound {
        if let frontier = try ReconstructionProductionRoundPlanBuilder
            .pendingSourceRevisionFrontier(in: basis.tasks) {
            return try makeSourcePreparedRound(from: basis, frontier: frontier)
        }
        return try makePreparedRound(
            from: basis,
            requestTaskID: basis.job.jobID,
            offersModelTool: false,
            buildsFinalSynthesisRequest: false,
            evidenceQueryProducer: nil,
            resolvesRetainedReadAuthority: false
        )
    }

    static func modelExecutionIsDurablyAuthorized(
        _ tasks: [ReconstructionTaskRecord]
    ) -> Bool {
        if (try? ReconstructionProductionRoundPlanBuilder
            .authorizedRegularModelFrontier(in: tasks)) != nil {
            return true
        }
        if (try? ReconstructionProductionRoundPlanBuilder
            .authorizedFinalSynthesisFrontier(in: tasks)) != nil {
            return true
        }
        return (try? ReconstructionProductionRoundPlanBuilder
            .authorizedSourceRevisionFrontier(in: tasks)) != nil
    }

    private static func makePreparedRound(
        from basis: ReconstructionProductionRoundBasis,
        requestTaskID: UUID,
        offersModelTool: Bool,
        buildsFinalSynthesisRequest: Bool,
        evidenceQueryProducer: ReconstructionProducerIdentity?,
        analysisRefreshProducer: ReconstructionProducerIdentity? = nil,
        resolvesRetainedReadAuthority: Bool = true
    ) throws -> ReconstructionPreparedModelRound {
        guard !(offersModelTool && buildsFinalSynthesisRequest) else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        // The fixed single-function source experiment uses a bounded evidence page compatible
        // with the verified FP16 model envelope. Durable job/evidence budgets remain unchanged.
        let isFixedSource = ReconstructionSourceProfile.admits(basis.job.sourceProfileID)
        let maximumRecords = max(1, min(basis.job.budget.maxEvidenceRecords, isFixedSource ? 8 : 4_096))
        let maximumEncodedBytes = min(
            Int(clamping: basis.job.budget.maxEncodedBytes),
            isFixedSource ? 8_192 : 1_048_576
        )
        guard maximumEncodedBytes >= 64 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        let roundID = deterministicRoundID(basis)
        let refreshFunction: ReconstructionFunctionCoordinate?
        if offersModelTool, analysisRefreshProducer != nil, basis.job.focus != nil,
           basis.job.budget.maxTasks - basis.tasks.count >= 4,
           basis.job.budget.maxEvidenceRecords > basis.evidenceCut.records.count {
            let focusQuery = try ReconstructionRetrievalQuery(
                corpusManifestSHA256: basis.manifest.canonicalSHA256,
                subject: nil, operationIDs: [.decompilerMacScope],
                classifications: [.acceptedCurrent], cursor: nil,
                maximumRecords: 1, maximumEncodedBytes: maximumEncodedBytes,
                focus: basis.job.focus)
            let functions = basis.evidenceCut.records.compactMap { record
                -> ReconstructionFunctionCoordinate? in
                guard case .function(let function) = record.subject,
                      focusQuery.includes(subject: record.subject),
                      (try? ReconstructionMacScopeAnalysisDemand.enumerationTask(
                        for: function, tasks: basis.tasks,
                        evidenceCut: basis.evidenceCut)) != nil,
                      !basis.tasks.contains(where: {
                          $0.identity.kind == .decompileMacScope
                              && $0.identity.subject == .function(function)
                              && $0.identity.dependencyTaskIDs.count == 2
                      }) else { return nil }
                return function
            }
            refreshFunction = functions.sorted {
                if $0.startAddress != $1.startAddress { return $0.startAddress < $1.startAddress }
                let lhs = (try? ReconstructionCanonicalJSON.sha256(of: $0)) ?? ""
                let rhs = (try? ReconstructionCanonicalJSON.sha256(of: $1)) ?? ""
                return lhs < rhs
            }.first
        } else { refreshFunction = nil }
        let producersByOperation: [
            ReconstructionOperationID: ReconstructionProducerIdentity
        ]
        if offersModelTool {
            guard let evidenceQueryProducer else {
                throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
            }
            var producers: [ReconstructionOperationID: ReconstructionProducerIdentity] =
                [.evidenceQuery: evidenceQueryProducer]
            if refreshFunction != nil, let analysisRefreshProducer {
                producers[.analysisMacScopeRefresh] = analysisRefreshProducer
            }
            producersByOperation = producers
        } else {
            producersByOperation = [:]
        }
        let projectionFrontier = try ReconstructionToolProjectorInput
            .canonicalProjectionFrontierSHA256(
                projectedItemsByOperation: [:],
                staleOperations: [],
                tasks: basis.tasks,
                receipts: basis.toolReceipts,
                producersByOperation: producersByOperation,
                evidenceAuthorityCutsByOperation: [:]
            )
        let authority = try ReconstructionToolAuthorityCut(
            jobID: basis.job.jobID,
            checkpointRevision: basis.checkpoint.revision,
            roundID: roundID,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256,
            projectionFrontierSHA256: projectionFrontier
        )
        let initialQuery = try ReconstructionRetrievalQuery(
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            subject: nil,
            operationIDs: ReconstructionOperationID.allCases,
            classifications: buildsFinalSynthesisRequest
                ? [.acceptedCurrent]
                : [.acceptedCurrent, .acceptedHistorical],
            cursor: nil,
            maximumRecords: maximumRecords,
            maximumEncodedBytes: maximumEncodedBytes,
            focus: basis.job.focus
        )
        var query = initialQuery
        var readContinuation = ReconstructionEvidenceReadContinuation.initial
        if !buildsFinalSynthesisRequest && resolvesRetainedReadAuthority {
            let reads = basis.toolReceipts.filter {
                $0.jobID == basis.job.jobID && $0.evidenceReadAuthority != nil
            }.sorted {
                if $0.checkpointRevision != $1.checkpointRevision {
                    return $0.checkpointRevision > $1.checkpointRevision
                }
                return $0.receiptID.uuidString.lowercased() < $1.receiptID.uuidString.lowercased()
            }
            if let receipt = reads.first, let read = receipt.evidenceReadAuthority {
                guard receipt.checkpointRevision <= basis.checkpoint.revision,
                      basis.tasks.contains(where: {
                          $0.identity.taskID == receipt.taskID
                            && $0.identity.jobID == basis.job.jobID
                            && $0.identity.kind == .retrieveEvidence && $0.state == .completed
                      }),
                      basis.modelReceipts.contains(where: {
                          $0.jobID == receipt.jobID
                            && $0.checkpointRevision == receipt.checkpointRevision
                            && $0.selectedHandleIDs.contains(receipt.receiptID.uuidString.lowercased())
                      }),
                      try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt) else {
                    throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
                }
                let successor = try read.resolveSuccessor(cut: basis.evidenceCut,
                    defaultQuery: initialQuery)
                query = successor.query
                readContinuation = .init(sourceReceiptID: receipt.receiptID,
                    outcome: successor.outcome)
            }
        }
        let focusedGaps = basis.evidenceCut.gaps.filter {
            query.focus == nil || query.includes(subject: $0.subject)
        }
        let gapSubjects = try Set(focusedGaps.map {
            "subject:\(try ReconstructionCanonicalJSON.sha256(of: $0.subject))"
        }).sorted()
        let gapCategories = Set(focusedGaps.map(\.operationID)).sorted()
        guard gapSubjects.count <= 4_096,
              gapCategories.count <= 4_096 else {
            throw ReconstructionJobCoordinatorFailure.invalidCommitPlan
        }
        query = try ReconstructionContextCompiler().boundedQuery(cut: basis.evidenceCut,
            query: query, allowedGapSubjects: gapSubjects, allowedGapCategories: gapCategories)
        let projectorInput = try ReconstructionToolProjectorInput(
            authority: authority,
            corpusManifest: basis.manifest,
            evidenceCut: basis.evidenceCut,
            tasks: basis.tasks,
            receipts: basis.toolReceipts,
            producersByOperation: producersByOperation,
            projectedItemsByOperation: [:],
            staleOperations: [],
            evidenceAuthorityCutsByOperation: [:]
        )
        let request = ReconstructionToolRequest(
            operationID: .evidenceQuery,
            taskID: requestTaskID,
            subject: nil,
            retrievalQuery: query,
            offset: query.cursor == nil ? 0 : 1,
            maximumRecords: query.maximumRecords,
            maximumEncodedBytes: query.maximumEncodedBytes
        )
        var requests = offersModelTool ? [request] : []
        if let refreshFunction {
            requests.append(.init(operationID: .analysisMacScopeRefresh,
                taskID: requestTaskID, subject: .function(refreshFunction),
                retrievalQuery: nil, offset: 0, maximumRecords: 1,
                maximumEncodedBytes: maximumEncodedBytes))
        }
        let finalSynthesisRequest: ReconstructionFinalSynthesisRequest?
        if buildsFinalSynthesisRequest {
            let context = try ReconstructionContextCompiler().compile(
                cut: basis.evidenceCut,
                query: query,
                allowedGapSubjects: gapSubjects,
                allowedGapCategories: gapCategories
            )
            finalSynthesisRequest = ReconstructionFinalSynthesisRequest(
                jobID: basis.job.jobID,
                checkpointRevision: basis.checkpoint.revision,
                corpusManifestSHA256: basis.manifest.canonicalSHA256,
                evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256,
                acceptedEvidenceIDs: context.evidenceIDs,
                context: context
            )
        } else {
            finalSynthesisRequest = nil
        }
        return ReconstructionPreparedModelRound(
            roundID: roundID,
            evidenceCut: basis.evidenceCut,
            retrievalQuery: query,
            allowedGapSubjects: gapSubjects,
            allowedGapCategories: gapCategories,
            authority: authority,
            requests: requests,
            projectorInput: projectorInput,
            finalSynthesisRequest: finalSynthesisRequest,
            objective: try ReconstructionRequestObjective(jobID: basis.job.jobID,
                text: basis.job.objective, sha256: basis.job.objectiveSHA256,
                sourceProfileID: isFixedSource ? basis.job.sourceProfileID : nil),
            readContinuation: readContinuation
        )
    }

    private static func makeSourcePreparedRound(
        from basis: ReconstructionProductionRoundBasis,
        frontier: ReconstructionProductionSourceRevisionFrontier
    ) throws -> ReconstructionPreparedModelRound {
        guard case .function(let function)? = frontier.model.identity.subject else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        let profileID = try ReconstructionSourceProfile.retainedSourceProfile(basis.job.sourceProfileID).rawValue
        let oracle = try ReconstructionProductionSourceAuthority.committedOracle(function: function, basis: basis)
        let prior = basis.evidenceCut.records.filter {
            $0.creatingJobID == basis.job.jobID && $0.operationID == ReconstructionSourceRevisionEvidence.operationID
        }
        guard prior.count <= 1 else { throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority }
        let parent = try prior.first.map { record -> ReconstructionSourceRevision in
            guard record.payload.count <= ReconstructionSourceRevision.maximumPayloadBytes else {
                throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
            }
            return try JSONDecoder().decode(ReconstructionSourceRevision.self, from: record.payload)
        }
        let query = try ReconstructionRetrievalQuery(corpusManifestSHA256: basis.manifest.canonicalSHA256,
            subject: .function(function), operationIDs: ReconstructionOperationID.allCases,
            classifications: [.acceptedCurrent], cursor: nil, maximumRecords: 4,
            maximumEncodedBytes: ReconstructionSourceContextCompiler.maximumBaseContextBytes, focus: basis.job.focus)
        let context = try ReconstructionSourceContextCompiler().compile(cut: basis.evidenceCut, query: query,
            function: function, oracleSuiteSHA256: oracle.suiteSHA256,
            parentRevisionSHA256: parent?.revisionSHA256)
        let roundID = deterministicRoundID(basis)
        let projectionFrontier = try ReconstructionToolProjectorInput.canonicalProjectionFrontierSHA256(
            projectedItemsByOperation: [:], staleOperations: [], tasks: basis.tasks, receipts: basis.toolReceipts,
            producersByOperation: [:], evidenceAuthorityCutsByOperation: [:])
        let authority = try ReconstructionToolAuthorityCut(jobID: basis.job.jobID,
            checkpointRevision: basis.checkpoint.revision, roundID: roundID,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256, projectionFrontierSHA256: projectionFrontier)
        let request = ReconstructionSourceRevisionRequest(protocolVersion: 10,
            objective: try ReconstructionRequestObjective(jobID: basis.job.jobID,
                text: basis.job.objective, sha256: basis.job.objectiveSHA256),
            projectID: basis.project.projectID, jobID: basis.job.jobID,
            taskID: frontier.model.identity.taskID, checkpointRevision: basis.checkpoint.revision,
            roundID: roundID, function: function, corpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256, oracleSuiteSHA256: oracle.suiteSHA256,
            profileID: profileID, parentRevisionSHA256: parent?.revisionSHA256,
            context: context)
        _ = try ReconstructionProductionSourceAuthority.capture(request: request, basis: basis)
        return .init(roundID: roundID, evidenceCut: basis.evidenceCut, retrievalQuery: query,
            allowedGapSubjects: [], allowedGapCategories: [], authority: authority, requests: [],
            projectorInput: try ReconstructionToolProjectorInput(authority: authority, corpusManifest: basis.manifest,
                evidenceCut: basis.evidenceCut, tasks: basis.tasks, receipts: basis.toolReceipts,
                producersByOperation: [:], projectedItemsByOperation: [:], staleOperations: [],
                evidenceAuthorityCutsByOperation: [:]), sourceRevisionRequest: request,
            objective: request.objective)
    }

    private static func deterministicRoundID(
        _ basis: ReconstructionProductionRoundBasis
    ) -> UUID {
        var preimage = Data("MacScope.ReconstructionModelRound.v1".utf8)
        preimage.append(0)
        preimage.append(contentsOf: basis.job.jobID.uuidString.lowercased().utf8)
        preimage.append(0)
        preimage.append(contentsOf: basis.checkpoint.checkpointID.uuidString.lowercased().utf8)
        preimage.append(0)
        preimage.append(contentsOf: basis.evidenceCut.frontierSHA256.utf8)
        var bytes = Array(SHA256.hash(data: preimage).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

}

/// Product cut provider. Database capture completes before scheduler work begins, so hashing,
/// detached analysis, native execution, and model preparation never hold the database actor.
struct ReconstructionProductionCommittedRoundCutProvider:
    ReconstructionProductionCommittedRoundCutProviding
{
    let workspaceID: UUID
    let owner: ReconstructionDatabaseOwner
    let batchExecutionBuilder: any ReconstructionProductionBatchExecutionBuilding
    let preparedRoundBuilder: any ReconstructionProductionPreparedRoundBuilding
    let basisRegistry: ReconstructionProductionRoundBasisRegistry
    let maximumConcurrentTasks: Int
    let nativePublications: ReconstructionTransientNativePublicationRegistry

    init(
        workspaceID: UUID,
        owner: ReconstructionDatabaseOwner,
        batchExecutionBuilder: any ReconstructionProductionBatchExecutionBuilding,
        preparedRoundBuilder: any ReconstructionProductionPreparedRoundBuilding,
        basisRegistry: ReconstructionProductionRoundBasisRegistry,
        maximumConcurrentTasks: Int,
        nativePublications: ReconstructionTransientNativePublicationRegistry = .shared
    ) {
        precondition(maximumConcurrentTasks > 0)
        self.workspaceID = workspaceID
        self.owner = owner
        self.batchExecutionBuilder = batchExecutionBuilder
        self.preparedRoundBuilder = preparedRoundBuilder
        self.basisRegistry = basisRegistry
        self.maximumConcurrentTasks = maximumConcurrentTasks
        self.nativePublications = nativePublications
    }

    func capture(
        snapshot requestedSnapshot: ReconstructionJobOrchestrationSnapshot
    ) async throws -> ReconstructionProductionCommittedRoundCut {
        let rows = try await owner.captureProductionRoundRows(
            workspaceID: workspaceID,
            jobID: requestedSnapshot.jobID
        )
        let basis = try ReconstructionProductionRoundBasis(rows: rows)
        guard basis.snapshot == requestedSnapshot else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }

        let authority = try ReconstructionBatchAuthority(
            jobID: basis.job.jobID,
            checkpointID: basis.checkpoint.checkpointID,
            checkpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: basis.manifest.canonicalSHA256
        )
        // Admission precedes every effect. A descriptor-only cut lets the planner checkpoint
        // the legal phase without executing work against the predecessor revision.
        let phaseAdmission = try ReconstructionProductionRoundPlanBuilder
            .preExecutionPhase(from: basis.snapshot)
        let requiresAdmission = basis.job.state == .paused || phaseAdmission != nil
        let results: [ReconstructionTerminalTaskResult]
        if requiresAdmission {
            results = []
        } else {
            let scheduler = try await batchExecutionBuilder.makeScheduler(
                for: basis, authority: authority
            )
            results = try await scheduler.executeReadyTasks(
                basis.tasks, authority: authority,
                budget: ReconstructionBatchBudget(
                    maximumTasks: basis.job.budget.maxTasks,
                    maximumConcurrentTasks: maximumConcurrentTasks
                ),
                allowedTaskKinds: basis.job.state == .ingesting ? [.ingest] : nil
            )
        }
        guard Set(results.map(\.taskID)).count == results.count,
              results.allSatisfy({ result in
                  result.jobID == authority.jobID
                    && result.checkpointID == authority.checkpointID
                    && result.checkpointRevision == authority.checkpointRevision
                    && result.corpusManifestSHA256 == authority.corpusManifestSHA256
                    && result.outcome != .staleAuthority
              }) else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        // Admitted native results stay in memory only. A later cut presents them transiently
        // after their task transition commits, and rejects them once bytes or images move.
        for result in results {
            guard case .completed(let success)? = result.nativeResult,
                  let task = basis.tasks.first(where: { $0.identity.taskID == result.taskID })
            else { continue }
            _ = try? await nativePublications.publish(
                workspaceID: workspaceID, task: task, success: success)
        }

        let prepared: ReconstructionPreparedModelRound
        if !requiresAdmission, results.isEmpty,
           ReconstructionProductionPreparedRoundBuilder
            .modelExecutionIsDurablyAuthorized(basis.tasks) {
            prepared = try await preparedRoundBuilder.makePreparedRound(from: basis)
        } else {
            // The materializer requires a round descriptor for every cut. This descriptor carries
            // authority only; it offers no model tool and is never executable as model input.
            prepared = try ReconstructionProductionPreparedRoundBuilder
                .makeDirectCommitDescriptor(from: basis)
        }
        guard prepared.authority.jobID == basis.job.jobID,
              prepared.authority.checkpointRevision == basis.checkpoint.revision,
              prepared.authority.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
              prepared.authority.evidenceFrontierSHA256 == basis.evidenceCut.frontierSHA256,
              prepared.evidenceCut == basis.evidenceCut else {
            throw ReconstructionProductionRoundBasisError.invalidCommittedAuthority
        }
        try await basisRegistry.register(basis, prepared: prepared)
        return ReconstructionProductionCommittedRoundCut(
            snapshot: basis.snapshot,
            parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            prepared: prepared,
            batchTerminalResults: results
        )
    }
}
