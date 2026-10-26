import CryptoKit
import Foundation

enum ReconstructionProductionReceiptPlanAuthorError: Error, Equatable, Sendable {
    case invalidCommittedAuthority
    case invalidBasePlan
    case invalidTaskFrontier
    case duplicateTerminalResult
    case missingTerminalResult
    case mismatchedTerminalResult
    case invalidTerminalReceipt
    case invalidToolExecution
    case invalidToolReceipt
    case invalidEvidence
    case invalidGapDeclaration
    case invalidGapResolution
    case missingModelTerminalAuthority
    case sufficientEvidenceRequiresDurableFinalSynthesisLeaf
    case unsupportedControl
    case budgetExceeded
}

/// The production owner of receipt-bearing reconstruction mutations.
///
/// This type is deliberately pure. It receives an immutable committed basis plus terminal values,
/// recomputes every durable identity, and returns one complete mutation. It never consults Store,
/// reopens an attachment, or persists launch-local provider coordinates.
struct ReconstructionProductionReceiptPlanAuthor:
    ReconstructionProductionReceiptPlanAuthoring,
    Sendable
{
    private static let checkpointIdentityDomain =
        "MacScope.ReconstructionCheckpoint.v1"
    private static let batchReceiptIdentityDomain =
        "MacScope.ReconstructionBatchReceipt.v1"
    private static let batchEvidenceIdentityDomain =
        "MacScope.ReconstructionBatchEvidence.v1"
    private static let citationIdentityDomain =
        "MacScope.ReconstructionEvidenceCitation.v1"

    private let modelProducerContext: ReconstructionModelProducerIdentityContext
    private let evidenceAcceptor: ReconstructionEvidenceAcceptor
    private let contextCompiler: ReconstructionContextCompiler
    private let registry: ReconstructionToolRegistry

    /// Production composition injects identities from the signed build/provenance authority.
    /// `providerRevision` is intentionally absent: the ready lease contributes only its stable
    /// inventory digest and canonical configuration identity through `ReconstructionReceiptAuthority`.
    init(
        modelProducerContext: ReconstructionModelProducerIdentityContext,
        evidenceAcceptor: ReconstructionEvidenceAcceptor = .init(
            maximumPayloadBytes: 1_048_576,
            maximumDiagnosticUTF8Bytes: 1_024
        ),
        contextCompiler: ReconstructionContextCompiler = .init(),
        registry: ReconstructionToolRegistry = .init()
    ) {
        self.modelProducerContext = modelProducerContext
        self.evidenceAcceptor = evidenceAcceptor
        self.contextCompiler = contextCompiler
        self.registry = registry
    }

    /// Production-only convenience initializer. The caller must obtain `provenance` by parsing
    /// the signed bundle resource with `Phase2QualificationGateBuildProvenance.parseCanonical`;
    /// that parser rejects Debug placeholders, dirty repositories, alternate encodings, and
    /// incomplete toolchain/source authority before this adapter can be constructed.
    init(
        releaseProvenance provenance: Phase2QualificationGateBuildProvenance,
        evidenceAcceptor: ReconstructionEvidenceAcceptor = .init(
            maximumPayloadBytes: 1_048_576,
            maximumDiagnosticUTF8Bytes: 1_024
        ),
        contextCompiler: ReconstructionContextCompiler = .init(),
        registry: ReconstructionToolRegistry = .init()
    ) {
        self.init(
            modelProducerContext: .production(provenance: provenance),
            evidenceAcceptor: evidenceAcceptor,
            contextCompiler: contextCompiler,
            registry: registry
        )
    }

    /// Exposes the same canonical, non-native producer authority used by this author so the
    /// prepared tool-projection cut cannot advertise an operation with an independently forged
    /// producer. Native task receipts use the terminal result's attested runtime identity instead.
    func makeToolProducer(
        operationID: ReconstructionOperationID
    ) throws -> ReconstructionProducerIdentity {
        try makeToolProducer(
            operationIdentity: operationID.rawValue,
            nativeSuccess: nil
        )
    }

    func makeSourceToolProducer(contract: String) throws -> ReconstructionProducerIdentity {
        guard contract == ReconstructionSourceExecutionTaskContract.oracle
            || contract == ReconstructionSourceExecutionTaskContract.evaluate else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        return try makeToolProducer(operationIdentity: contract == ReconstructionSourceExecutionTaskContract.oracle
            ? ReconstructionSourceOracleEvidence.operationID : ReconstructionSourceEvaluationEvidence.operationID,
            nativeSuccess: nil)
    }

    func makeBatchCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan
    ) async throws -> ReconstructionJobCommitPlan {
        try Task.checkCancellation()
        try validate(cut: cut, basis: basis)
        let successorRevision = try successorRevision(for: basis)
        guard let base = basePlan.mutation,
              basePlan.successorRevision == successorRevision,
              base.jobID == basis.job.jobID,
              base.expectedParentCheckpointID == basis.checkpoint.checkpointID,
              base.expectedParentCheckpointSHA256 == basis.checkpoint.canonicalSHA256,
              base.expectedParentRevision == basis.checkpoint.revision,
              base.evidence.isEmpty,
              base.evidenceRelations.isEmpty,
              base.evidenceGaps.isEmpty,
              base.toolReceipts.isEmpty,
              base.modelReceipts.isEmpty,
              !cut.batchTerminalResults.isEmpty else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
        }

        let tasksByID = try uniqueTasks(basis.tasks)
        let resultIDs = cut.batchTerminalResults.map(\.taskID)
        guard Set(resultIDs).count == resultIDs.count else {
            throw ReconstructionProductionReceiptPlanAuthorError.duplicateTerminalResult
        }
        let resultIDSet = Set(resultIDs)
        let transitionedIDs = base.taskTransitions.map(\.taskID)
        let transitionedIDSet = Set(transitionedIDs)
        guard transitionedIDSet.count == transitionedIDs.count,
              resultIDSet.isSubset(of: transitionedIDSet) else {
            throw ReconstructionProductionReceiptPlanAuthorError.missingTerminalResult
        }
        let hasNoncompletedResult = cut.batchTerminalResults.contains {
            $0.outcome != .completed
        }
        let extraTransitions = base.taskTransitions.filter {
            !resultIDSet.contains($0.taskID)
        }
        if hasNoncompletedResult {
            guard extraTransitions.allSatisfy({ transition in
                guard let task = tasksByID[transition.taskID] else { return false }
                return (task.state == .pending || task.state == .running)
                    && transition.expectedState == task.state
                    && transition.successorState == .blocked
                    && transition.diagnostic != nil
            }) else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
        } else if !extraTransitions.isEmpty {
            // Source execution settles its paired checkpoint atomically with the terminal
            // observation. This is the only completed transition without its own batch result.
            guard cut.batchTerminalResults.count == 1,
                  let result = cut.batchTerminalResults.first,
                  let sourceTask = tasksByID[result.taskID],
                  ReconstructionSourceExecutionTaskContract.admits(sourceTask),
                  (try? sourceTask.identity.verifyCanonicalIdentity()) != nil,
                  extraTransitions.count == 1, let transition = extraTransitions.first,
                  let checkpoint = tasksByID[transition.taskID],
                  checkpoint.identity.kind == .checkpoint,
                  checkpoint.identity.operationContractIdentity == ReconstructionProductionTaskContract.checkpoint,
                  checkpoint.identity.subject == nil,
                  checkpoint.identity.jobID == sourceTask.identity.jobID,
                  checkpoint.identity.dependencyTaskIDs == [sourceTask.identity.taskID],
                  (try? checkpoint.identity.verifyCanonicalIdentity()) != nil,
                  basis.tasks.filter({ $0.identity.kind == .checkpoint
                    && $0.identity.dependencyTaskIDs == [sourceTask.identity.taskID] }).count == 1,
                  checkpoint.state == .pending, transition.expectedState == checkpoint.state,
                  transition.successorState == .completed, transition.diagnostic == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
        }

        let successorCheckpointID = base.successorCheckpoint.checkpointID
        var acceptedEvidence: [ReconstructionEvidenceRecord] = []
        var receipts: [ReconstructionToolReceipt] = []
        var sourceEvidenceBuilders: [(ReconstructionCheckpoint) throws -> ReconstructionEvidenceRecord] = []
        var observationBuilders: [(ReconstructionJobCommitPlan) -> ReconstructionProductionObservationDiagnostic?] = []
        for result in cut.batchTerminalResults.sorted(by: {
            $0.taskID.uuidString.lowercased() < $1.taskID.uuidString.lowercased()
        }) {
            try Task.checkCancellation()
            guard let task = tasksByID[result.taskID] else {
                throw ReconstructionProductionReceiptPlanAuthorError.missingTerminalResult
            }
            try validate(
                batchResult: result,
                task: task,
                basis: basis
            )
            let operation = durableOperation(for: task.identity.kind)
            let resultDiagnostic = base.taskTransitions.first {
                $0.taskID == task.identity.taskID
            }?.diagnostic ?? diagnostic(for: result.outcome)
            let producer = try makeToolProducer(
                operationIdentity: task.identity.kind == .executeSource
                    ? (task.identity.operationContractIdentity == ReconstructionSourceExecutionTaskContract.oracle
                        ? ReconstructionSourceOracleEvidence.operationID : ReconstructionSourceEvaluationEvidence.operationID)
                    : (operation?.rawValue ?? task.identity.operationContractIdentity),
                nativeSuccess: completedNativeSuccess(result.nativeResult)
            )
            let requestSHA256 = try ReconstructionCanonicalJSON.sha256(
                of: BatchRequestIdentity(
                    schemaVersion: 1,
                    jobID: basis.job.jobID,
                    task: task.identity,
                    checkpointID: basis.checkpoint.checkpointID,
                    checkpointRevision: basis.checkpoint.revision,
                    checkpointSHA256: basis.checkpoint.canonicalSHA256,
                    corpusManifestSHA256: basis.manifest.canonicalSHA256
                )
            )
            let receiptID = try nameDerivedUUID(
                domain: Self.batchReceiptIdentityDomain,
                value: BatchReceiptIdentity(
                    jobID: basis.job.jobID,
                    taskID: task.identity.taskID,
                    successorRevision: basePlan.successorRevision,
                    requestIdentitySHA256: requestSHA256
                )
            )

            if task.identity.kind == .executeSource, result.outcome == .completed {
                guard let payload = result.sourceExecution,
                      let completedTask = try applying(base.taskTransitions, to: basis.tasks).first(where: {
                        $0.identity.taskID == task.identity.taskID
                      }), case .function(let function)? = task.identity.subject else {
                    throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
                }
                switch payload {
                case .oracle(let oracle):
                    guard oracle.projectID == basis.project.projectID,
                          oracle.jobID == basis.job.jobID, oracle.function == function,
                          oracle.execution.producerSHA256 == producer.canonicalSHA256,
                          oracle.execution.originalExecutableSHA256 == function.artifact.contentIdentity.digest else {
                        throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
                    }
                    let bytes = try ReconstructionSourceOracleEvidence.encode(oracle)
                    let evidenceID = try nameDerivedUUID(domain: Self.batchEvidenceIdentityDomain,
                        value: BatchEvidenceIdentity(receiptID: receiptID, payloadSHA256: sha256(bytes)))
                    let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: receiptID,
                        jobID: basis.job.jobID, taskID: task.identity.taskID,
                        checkpointRevision: basePlan.successorRevision, requestIdentitySHA256: requestSHA256,
                        producer: producer, terminalState: .completed, outputEvidenceIDs: [evidenceID], diagnostic: nil)
                    receipts.append(receipt)
                    sourceEvidenceBuilders.append { checkpoint in
                        try ReconstructionSourceOracleEvidence.make(evidenceID: evidenceID, context: .init(
                            authority: .init(projectID: oracle.projectID, jobID: oracle.jobID,
                                function: function, execution: oracle.execution, evidenceIDs: oracle.evidenceIDs),
                            task: completedTask, checkpoint: checkpoint, toolReceipt: receipt,
                            expectedRequestIdentitySHA256: requestSHA256, expectedProducer: producer,
                            committedEvidenceCut: basis.evidenceCut.records))
                    }
                case .evaluation(let outcome):
                    let revisions = try ReconstructionProductionSourceAuthority.committedRevisions(function: function, basis: basis)
                    let oracle = try ReconstructionProductionSourceAuthority.oracleContext(function: function, basis: basis)
                    guard let source = revisions.last,
                          outcome.function == function,
                          outcome.sourceAuthority == .admittedRevision(revisionSHA256: source.revision.revisionSHA256),
                          outcome.sourceSHA256 == source.revision.sourceSHA256,
                          outcome.oracleSuiteSHA256 == source.revision.oracleSuiteSHA256,
                          outcome.toolAuthority.compilerSHA256 == oracle.context.authority.execution.compilerSHA256,
                          outcome.toolAuthority.sdkSettingsSHA256 == oracle.context.authority.execution.sdkIdentitySHA256 else {
                        throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
                    }
                    let captured = try ReconstructionSourceEvaluationCapture.capture(outcome)
                    let evidenceID = try nameDerivedUUID(domain: Self.batchEvidenceIdentityDomain,
                        value: BatchEvidenceIdentity(receiptID: receiptID,
                            payloadSHA256: try ReconstructionCanonicalJSON.sha256(of: captured)))
                    let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: receiptID,
                        jobID: basis.job.jobID, taskID: task.identity.taskID,
                        checkpointRevision: basePlan.successorRevision, requestIdentitySHA256: requestSHA256,
                        producer: producer, terminalState: .completed, outputEvidenceIDs: [evidenceID], diagnostic: nil)
                    receipts.append(receipt)
                    let evaluationContext: (ReconstructionCheckpoint) -> ReconstructionSourceEvaluationEvidence.Context = { checkpoint in
                        .init(sourceRecord: source.record, sourceContext: source.context,
                            oracleRecord: oracle.record, oracleContext: oracle.context,
                            task: completedTask, checkpoint: checkpoint, toolReceipt: receipt,
                            expectedRequestIdentitySHA256: requestSHA256, expectedProducer: producer,
                            expectedCapturedOutcome: captured)
                    }
                    sourceEvidenceBuilders.append { checkpoint in
                        try ReconstructionSourceEvaluationEvidence.make(evidenceID: evidenceID,
                            context: evaluationContext(checkpoint))
                    }
                    observationBuilders.append { finalPlan in
                        guard let finalCheckpoint = finalPlan.mutation?.successorCheckpoint else { return nil }
                        return ReconstructionProductionObservationProjection.project(basis: basis, cut: cut,
                            plan: finalPlan, evaluationEvidenceID: evidenceID, context: evaluationContext(finalCheckpoint))
                    }
                }
                continue
            }
            let evidence: ReconstructionEvidenceRecord?
            if let operation,
               let subject = task.identity.subject,
               shouldPersistEvidence(for: task.identity.kind, outcome: result.outcome) {
                let payload = try ReconstructionCanonicalJSON.encode(BatchEvidencePayload(
                    schemaVersion: 1,
                    task: task.identity,
                    outcome: result.outcome.durableName,
                    projection: result.analysisProjection.map(AnalysisProjectionPayload.init),
                    diagnostic: resultDiagnostic
                ))
                let evidenceID = try nameDerivedUUID(
                    domain: Self.batchEvidenceIdentityDomain,
                    value: BatchEvidenceIdentity(
                        receiptID: receiptID,
                        payloadSHA256: sha256(payload)
                    )
                )
                let citationID = try nameDerivedUUID(
                    domain: Self.citationIdentityDomain,
                    value: EvidenceCitationIdentity(
                        evidenceID: evidenceID,
                        taskID: task.identity.taskID
                    )
                )
                let candidate = try ReconstructionEvidenceCandidate(
                    evidenceID: evidenceID,
                    subject: subject,
                    operationID: operation,
                    payloadKind: .structuredJSON,
                    payload: payload,
                    payloadByteCount: UInt64(payload.count),
                    payloadSHA256: sha256(payload),
                    facetDependencies: [],
                    producer: producer,
                    citations: [try ReconstructionEvidenceCitation(
                        citationID: citationID,
                        sourceEvidenceID: nil,
                        subject: subject,
                        locator: "task:\(task.identity.taskID.uuidString.lowercased())"
                    )],
                    creatingJobID: basis.job.jobID,
                    creatingTaskID: task.identity.taskID,
                    creatingCheckpointID: successorCheckpointID,
                    modelReceiptID: nil,
                    toolReceiptID: receiptID,
                    supersedesEvidenceID: nil,
                    diagnostic: resultDiagnostic
                )
                evidence = try accept(
                    candidate,
                    operation: operation,
                    producer: producer,
                    taskID: task.identity.taskID,
                    receiptID: receiptID,
                    checkpointID: successorCheckpointID,
                    checkpointRevision: basePlan.successorRevision,
                    freshnessAuthority: base.freshnessAuthority,
                    basis: basis,
                    alreadyAccepted: acceptedEvidence
                )
            } else {
                evidence = nil
            }
            if let evidence { acceptedEvidence.append(evidence) }

            receipts.append(try ReconstructionReceiptAuthority.makeToolReceipt(
                receiptID: receiptID,
                jobID: basis.job.jobID,
                taskID: task.identity.taskID,
                checkpointRevision: basePlan.successorRevision,
                requestIdentitySHA256: requestSHA256,
                producer: producer,
                terminalState: receiptState(for: result.outcome),
                outputEvidenceIDs: evidence.map { [$0.evidenceID] } ?? [],
                diagnostic: diagnostic(for: result.outcome)
            ))
        }

        // Database recapture gives committed exact function subjects explicit facet authority.
        // Establish that same authority for this validated batch's first function evidence,
        // before computing its successor frontier; model records cannot create this authority.
        var successorFacets = base.freshnessAuthority.currentFacetFingerprints
        for record in acceptedEvidence {
            guard record.classification == .acceptedCurrent,
                  case .function(let function) = record.subject else { continue }
            let image = try ReconstructionImageCoordinate(artifact: function.artifact,
                image: function.image, analysisFingerprintSHA256: function.analysisFingerprintSHA256)
            guard record.facetDependencies.isEmpty,
                  record.operationID == ReconstructionOperationID.decompilerMacScope.rawValue,
                  base.freshnessAuthority.currentArtifacts.contains(function.artifact),
                  base.freshnessAuthority.currentImages.contains(image),
                  let task = tasksByID[record.creatingTaskID], task.identity.kind == .decompileMacScope,
                  task.identity.subject == record.subject,
                  let result = cut.batchTerminalResults.first(where: { $0.taskID == task.identity.taskID }),
                  result.outcome == .completed, let projection = result.analysisProjection,
                  projection.artifact == function.artifact, projection.image == function.image,
                  projection.analysisFingerprintSHA256 == function.analysisFingerprintSHA256,
                  projection.function.map({ ReconstructionReboundFunctionAuthority.matches($0,
                    coordinate: function) }) == true,
                  successorFacets[record.subject]?.isEmpty != false else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
            }
            successorFacets[record.subject] = [:]
        }
        let successorFreshness = try ReconstructionFreshnessAuthority(
            corpusManifestSHA256: base.freshnessAuthority.corpusManifestSHA256,
            currentArtifacts: base.freshnessAuthority.currentArtifacts,
            currentImages: base.freshnessAuthority.currentImages,
            currentFacetFingerprints: successorFacets)
        if !sourceEvidenceBuilders.isEmpty {
            let provisional = try makePlan(basis: basis, disposition: basePlan.disposition,
                evidence: acceptedEvidence, evidenceRelations: [], evidenceGaps: [], toolReceipts: receipts,
                modelReceipts: [], newTasks: base.newTasks, transitions: base.taskTransitions,
                freshnessAuthority: successorFreshness, successorCheckpointID: successorCheckpointID,
                terminalReason: base.successorCheckpoint.terminalReason,
                successorPauseContext: base.successorPauseContext)
            guard let checkpoint = provisional.mutation?.successorCheckpoint else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            for builder in sourceEvidenceBuilders { acceptedEvidence.append(try builder(checkpoint)) }
        }
        let plan = try makePlan(
            basis: basis,
            disposition: basePlan.disposition,
            evidence: acceptedEvidence,
            evidenceRelations: [],
            evidenceGaps: [],
            toolReceipts: receipts,
            modelReceipts: [],
            newTasks: base.newTasks,
            transitions: base.taskTransitions,
            freshnessAuthority: successorFreshness,
            successorCheckpointID: successorCheckpointID,
            terminalReason: base.successorCheckpoint.terminalReason,
            successorPauseContext: base.successorPauseContext,
            analysisImports: cut.batchTerminalResults.compactMap(\.loadedImageAdmission)
        )
        guard let finalCheckpoint = plan.mutation?.successorCheckpoint else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
        }
        for builder in sourceEvidenceBuilders {
            let rebuilt = try builder(finalCheckpoint)
            guard acceptedEvidence.contains(rebuilt) else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
            }
        }
        // Only the final authored records/checkpoint reach projection. Provisional builders above
        // establish durable evidence identity and never emit observation diagnostics.
        let diagnostics = observationBuilders.compactMap { $0(plan) }
        return .init(successorRevision: plan.successorRevision, acceptedEvidenceCount: plan.acceptedEvidenceCount,
            disposition: plan.disposition, mutation: plan.mutation, observationDiagnostics: diagnostics)
    }

    func makeModelCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        inference: ReconstructionInferenceExecutionResult,
        executions: [ReconstructionToolExecution]
    ) async throws -> ReconstructionJobCommitPlan {
        try Task.checkCancellation()
        try validate(cut: cut, basis: basis)
        guard cut.prepared.finalSynthesisRequest == nil else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
        }
        let frontier = try modelTaskFrontier(basis.tasks)
        guard modelProducerContext.operationIdentity
                == frontier.model.identity.operationContractIdentity else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
        }
        let request = try makeRoundRequest(cut.prepared, basis: basis)
        try validate(
            requestAuthority: requestAuthority,
            expectedRequest: try boundRequest(.round(request), prepared: cut.prepared, basis: basis),
            expectedStatus: .completed
        )
        guard inference.terminalReceipt == requestAuthority.terminalReceipt else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTerminalReceipt
        }
        try validate(inference: inference, request: request)
        try validateGapDeclarations(inference.candidate, prepared: cut.prepared)
        let base = try validateReceiptFreeBasePlan(basePlan, basis: basis)

        let handles = try registry.mintHandles(
            authority: cut.prepared.authority,
            requests: cut.prepared.requests
        )
        let selectedIDs = inference.candidate.selectedHandleIDs
        guard Set(selectedIDs).count == selectedIDs.count else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        let handlesByID = Dictionary(uniqueKeysWithValues: handles.map { ($0.handleID, $0) })
        guard selectedIDs.allSatisfy({ handlesByID[$0] != nil }),
              executions.count == selectedIDs.count,
              Set(executions.map(\.handleID)) == Set(selectedIDs),
              Set(executions.map(\.handleID)).count == executions.count else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }

        let successorRevision = basePlan.successorRevision
        let successorCheckpointID = base.successorCheckpoint.checkpointID
        var acceptedEvidence: [ReconstructionEvidenceRecord] = []
        var durableToolReceipts: [ReconstructionToolReceipt] = []
        let executionsByID = Dictionary(uniqueKeysWithValues: executions.map {
            ($0.handleID, $0)
        })
        let demandCount = selectedIDs.filter {
            handlesByID[$0]?.operationID == .analysisMacScopeRefresh
        }.count
        guard demandCount <= 1,
              demandCount == 0 || inference.candidate.disposition == .continue else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        for handleID in selectedIDs {
            try Task.checkCancellation()
            guard let handle = handlesByID[handleID],
                  let execution = executionsByID[handleID] else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
            }
            let output = try reauthorize(
                execution: execution,
                handle: handle,
                successorCheckpointID: successorCheckpointID,
                successorRevision: successorRevision,
                basis: basis,
                prepared: cut.prepared,
                alreadyAccepted: acceptedEvidence
            )
            acceptedEvidence.append(contentsOf: output.evidence)
            durableToolReceipts.append(output.receipt)
        }
        guard Set(acceptedEvidence.map(\.evidenceID)).count == acceptedEvidence.count else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
        }
        let supersessionRelations = try makeSupersessionRelations(
            for: acceptedEvidence,
            basis: basis
        )
        let gapResolutionRelations = try makeGapResolutionRelations(
            candidate: inference.candidate,
            executionsByID: executionsByID,
            supersessionRelations: supersessionRelations,
            basis: basis,
            prepared: cut.prepared
        )

        let producer = try makeModelProducerIdentity(
            lease: lease,
            operationIdentity: frontier.model.identity.operationContractIdentity,
            request: requestAuthority.request
        )
        let modelReceipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: requestAuthority.expectedRequestID,
            jobID: basis.job.jobID,
            taskID: frontier.model.identity.taskID,
            checkpointRevision: successorRevision,
            requestIdentitySHA256: requestAuthority.requestIdentitySHA256,
            producer: producer,
            terminalState: .completed,
            selectedHandleIDs: selectedIDs.map { $0.uuidString.lowercased() },
            // Tool-produced evidence remains owned by its exact tool receipt. The model receipt
            // records the ordered selection but cannot claim evidence it did not create.
            acceptedEvidenceIDs: [],
            diagnostic: nil
        )

        let sourceTargetMissing = inference.candidate.disposition == .sufficientEvidence
            && cut.prepared.sourceOracleRequested && cut.prepared.sourceOracleFunction == nil
        let successorTaskCount = inference.candidate.disposition == .sufficientEvidence
            ? (sourceTargetMissing ? 3 : 2) : 3 + demandCount
        if demandCount == 1, successorTaskCount <= basis.job.budget.maxTasks - basis.tasks.count {
            guard let demandHandle = selectedIDs.compactMap({ handlesByID[$0] }).first(where: {
                $0.operationID == .analysisMacScopeRefresh
            }) else { throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan }
            let demand = try registry.decodeCanonicalRequest(demandHandle)
            guard case .function(let function)? = demand.subject else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            let enumeration = try ReconstructionMacScopeAnalysisDemand.enumerationTask(
                for: function, tasks: basis.tasks, evidenceCut: basis.evidenceCut)
            let refreshTasks = base.newTasks.filter { $0.identity.kind == .decompileMacScope }
            guard base.newTasks.count == 4, refreshTasks.count == 1,
                  let refresh = refreshTasks.first,
                  refresh.identity.subject == .function(function), refresh.state == .pending,
                  refresh.identity.operationContractIdentity == "reconstruction.decompileMacScope.v1",
                  Set(refresh.identity.dependencyTaskIDs) == Set([enumeration.identity.taskID,
                    frontier.checkpoint.identity.taskID]),
                  base.newTasks.filter({ $0.identity.kind == .retrieveEvidence
                    && Set($0.identity.dependencyTaskIDs) == Set([refresh.identity.taskID,
                        frontier.checkpoint.identity.taskID]) }).count == 1 else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
        }
        let expectedDisposition: ReconstructionJobCoordinatorDisposition
        if sourceTargetMissing || successorTaskCount > basis.job.budget.maxTasks - basis.tasks.count {
            expectedDisposition = .paused(.evidenceStalled)
        } else {
            expectedDisposition = switch inference.candidate.disposition {
            case .continue, .sufficientEvidence:
                basis.job.state == .executingReads ? .advancePhase(.acceptingEvidence) : .continue
            case .blocked:
                .paused(.evidenceStalled)
            }
        }
        guard basePlan.disposition == expectedDisposition else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
        }

        return try makePlan(
            basis: basis,
            disposition: basePlan.disposition,
            evidence: acceptedEvidence,
            evidenceRelations: supersessionRelations + gapResolutionRelations,
            evidenceGaps: [],
            toolReceipts: durableToolReceipts,
            modelReceipts: [modelReceipt],
            newTasks: base.newTasks,
            transitions: base.taskTransitions,
            freshnessAuthority: base.freshnessAuthority,
            successorCheckpointID: successorCheckpointID,
            terminalReason: base.successorCheckpoint.terminalReason,
            successorPauseContext: base.successorPauseContext
        )
    }

    func makeSourceCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        source: ReconstructionSourceRevisionExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        try Task.checkCancellation()
        try validate(cut: cut, basis: basis)
        guard cut.prepared.finalSynthesisRequest == nil,
              let request = cut.prepared.sourceRevisionRequest,
              let frontier = try ReconstructionProductionRoundPlanBuilder
                .authorizedSourceRevisionFrontier(in: basis.tasks),
              request.taskID == frontier.model.identity.taskID,
              request.roundID == cut.prepared.roundID,
              source.terminalReceipt == requestAuthority.terminalReceipt else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
        }
        try source.candidate.validate(for: request)
        try validate(requestAuthority: requestAuthority,
            expectedRequest: try boundRequest(.sourceRevision(request), prepared: cut.prepared, basis: basis),
            expectedStatus: .completed)
        let captured = try ReconstructionProductionSourceAuthority.capture(request: request, basis: basis)
        let base = try validateReceiptFreeBasePlan(basePlan, basis: basis)
        let producer = try makeModelProducerIdentity(lease: lease,
            operationIdentity: ReconstructionSourceRevisionEvidence.operationID,
            request: requestAuthority.request)
        let evidenceID = try nameDerivedUUID(domain: "MacScope.ReconstructionSourceEvidence.v1",
            value: FinalResultIdentityPreimage(jobID: basis.job.jobID,
                taskID: request.taskID, requestID: requestAuthority.expectedRequestID,
                checkpointID: base.successorCheckpoint.checkpointID))
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: requestAuthority.expectedRequestID, jobID: basis.job.jobID,
            taskID: request.taskID, checkpointRevision: basePlan.successorRevision,
            requestIdentitySHA256: requestAuthority.requestIdentitySHA256, producer: producer,
            terminalState: .completed, selectedHandleIDs: [], acceptedEvidenceIDs: [evidenceID], diagnostic: nil)
        func authoredPlan(_ evidence: [ReconstructionEvidenceRecord]) throws -> ReconstructionJobCommitPlan {
            try makePlan(basis: basis, disposition: basePlan.disposition, evidence: evidence,
                evidenceRelations: [], evidenceGaps: [], toolReceipts: [], modelReceipts: [receipt],
                newTasks: base.newTasks, transitions: base.taskTransitions,
                freshnessAuthority: base.freshnessAuthority,
                successorCheckpointID: base.successorCheckpoint.checkpointID,
                terminalReason: base.successorCheckpoint.terminalReason,
                successorPauseContext: base.successorPauseContext)
        }
        let provisional = try authoredPlan([])
        guard let completedTask = try applying(base.taskTransitions, to: basis.tasks).first(where: {
            $0.identity.taskID == request.taskID
        }), let provisionalCheckpoint = provisional.mutation?.successorCheckpoint else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
        }
        var context = ReconstructionSourceRevisionEvidence.Context(
            admissionAuthority: captured.authority, task: completedTask,
            checkpoint: provisionalCheckpoint, modelReceipt: receipt,
            expectedRequestIdentitySHA256: requestAuthority.requestIdentitySHA256,
            committedEvidenceCut: basis.evidenceCut.records,
            committedPriorRevisionRecords: captured.priorRecords,
            priorRevisionContexts: captured.priorContexts)
        let record = try ReconstructionSourceRevisionEvidence.make(evidenceID: evidenceID,
            proposal: .init(profileID: source.candidate.profileID, parentRevisionSHA256: source.candidate.parentRevisionSHA256,
                sourceUTF8: Data(source.candidate.sourceText.utf8),
                claimedSourceSHA256: source.candidate.sourceSHA256, evidenceIDs: source.candidate.evidenceIDs),
            context: context)
        let result = try authoredPlan([record])
        guard let committedCheckpoint = result.mutation?.successorCheckpoint else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
        }
        context = .init(admissionAuthority: context.admissionAuthority, task: context.task,
            checkpoint: committedCheckpoint, modelReceipt: receipt,
            expectedRequestIdentitySHA256: context.expectedRequestIdentitySHA256,
            committedEvidenceCut: context.committedEvidenceCut,
            committedPriorRevisionRecords: context.committedPriorRevisionRecords,
            priorRevisionContexts: context.priorRevisionContexts)
        _ = try ReconstructionSourceRevisionEvidence.validate(record: record, context: context)
        return result
    }

    func makeFailedModelPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        reason: ReconstructionJobCoordinatorFailure
    ) async throws -> ReconstructionJobCommitPlan {
        try Task.checkCancellation()
        try validate(cut: cut, basis: basis)
        let diagnostic: ReconstructionDiagnostic
        if case .retryableProviderFailure(let providerReason) = reason {
            diagnostic = .sanitizing("Model request paused: \(providerReason).")
        } else if reason == .malformedOutput {
            diagnostic = .sanitizing(requestAuthority.terminalReceipt.providerFailureReason.map {
                "The model request failed: \($0.rawValue)."
            } ?? "The model request returned malformed terminal output.")
        } else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
        }
        let base = try validateReceiptFreeBasePlan(basePlan, basis: basis)
        let expectedRequest: ReconstructionAIWorkerRequest
        let task: ReconstructionTaskRecord
        if let sourceRequest = cut.prepared.sourceRevisionRequest {
            expectedRequest = try boundRequest(.sourceRevision(sourceRequest), prepared: cut.prepared, basis: basis)
            guard let sourceFrontier = try ReconstructionProductionRoundPlanBuilder
                .authorizedSourceRevisionFrontier(in: basis.tasks) else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
            }
            task = sourceFrontier.model
        } else if let finalRequest = cut.prepared.finalSynthesisRequest {
            expectedRequest = try boundRequest(.finalSynthesis(finalRequest), prepared: cut.prepared, basis: basis)
            task = try finalSynthesisTaskFrontier(basis.tasks).model
        } else {
            expectedRequest = try boundRequest(.round(try makeRoundRequest(cut.prepared, basis: basis)), prepared: cut.prepared, basis: basis)
            task = try modelTaskFrontier(basis.tasks).model
        }
        try validate(
            requestAuthority: requestAuthority,
            expectedRequest: expectedRequest,
            expectedStatus: requestAuthority.terminalReceipt.status
        )
        let producer = try makeModelProducerIdentity(
            lease: lease,
            operationIdentity: cut.prepared.sourceRevisionRequest == nil
                ? task.identity.operationContractIdentity : ReconstructionSourceRevisionEvidence.operationID,
            request: requestAuthority.request
        )
        let terminalState: ReconstructionReceiptTerminalState = switch
            requestAuthority.terminalReceipt.status {
        case .cancelled: .cancelled
        case .failed: .failed
        case .completed: .completed
        }
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: requestAuthority.expectedRequestID,
            jobID: basis.job.jobID,
            taskID: task.identity.taskID,
            checkpointRevision: basePlan.successorRevision,
            requestIdentitySHA256: requestAuthority.requestIdentitySHA256,
            producer: producer,
            terminalState: terminalState,
            selectedHandleIDs: [],
            acceptedEvidenceIDs: [],
            diagnostic: diagnostic
        )
        return try makePlan(
            basis: basis,
            disposition: basePlan.disposition,
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            toolReceipts: [],
            modelReceipts: [receipt],
            newTasks: base.newTasks,
            transitions: base.taskTransitions,
            freshnessAuthority: base.freshnessAuthority,
            successorCheckpointID: base.successorCheckpoint.checkpointID,
            terminalReason: base.successorCheckpoint.terminalReason,
            successorPauseContext: base.successorPauseContext
        )
    }

    func makeFinalCommitPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        basePlan: ReconstructionJobCommitPlan,
        lease: Phase2ReadyInferenceLease,
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        synthesis: ReconstructionFinalSynthesisExecutionResult
    ) async throws -> ReconstructionJobCommitPlan {
        try Task.checkCancellation()
        try validate(cut: cut, basis: basis)
        guard let request = cut.prepared.finalSynthesisRequest else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
        }
        let base = try validateReceiptFreeBasePlan(basePlan, basis: basis)
        guard basePlan.disposition == .completed,
              synthesis.terminalReceipt == requestAuthority.terminalReceipt,
              finalCandidateIsValid(synthesis.candidate, for: request) else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTerminalReceipt
        }
        try validate(
            requestAuthority: requestAuthority,
            expectedRequest: try boundRequest(.finalSynthesis(request), prepared: cut.prepared, basis: basis),
            expectedStatus: .completed
        )
        let evidenceByID = Dictionary(uniqueKeysWithValues: basis.evidenceCut.records.map {
            ($0.evidenceID, $0)
        })
        guard synthesis.candidate.evidenceIDs.allSatisfy({ evidenceID in
            evidenceByID[evidenceID] != nil
                && basis.evidenceCut.projectedClassificationsByEvidenceID[evidenceID]
                    == .acceptedCurrent
                && evidenceByID[evidenceID]?.supersededByEvidenceID == nil
        }) else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
        }
        let frontier = try finalSynthesisTaskFrontier(basis.tasks)
        let producer = try makeModelProducerIdentity(
            lease: lease,
            operationIdentity: frontier.model.identity.operationContractIdentity,
            request: requestAuthority.request
        )
        let resultID = try nameDerivedUUID(
            domain: "MacScope.ReconstructionFinalResult.v1",
            value: FinalResultIdentityPreimage(
                jobID: basis.job.jobID,
                taskID: frontier.model.identity.taskID,
                requestID: requestAuthority.expectedRequestID,
                checkpointID: base.successorCheckpoint.checkpointID
            )
        )
        let result = try ReconstructionReceiptAuthority.makeFinalResult(
            resultID: resultID,
            jobID: basis.job.jobID,
            taskID: frontier.model.identity.taskID,
            checkpointID: base.successorCheckpoint.checkpointID,
            checkpointRevision: basePlan.successorRevision,
            requestID: requestAuthority.expectedRequestID,
            requestIdentitySHA256: requestAuthority.requestIdentitySHA256,
            kind: synthesis.candidate.kind,
            payloadUTF8: Data(synthesis.candidate.text.utf8),
            citedEvidenceIDs: synthesis.candidate.evidenceIDs,
            producer: producer,
            modelReceiptID: requestAuthority.expectedRequestID
        )
        let receipt = try ReconstructionReceiptAuthority.makeModelReceipt(
            receiptID: requestAuthority.expectedRequestID,
            jobID: basis.job.jobID,
            taskID: frontier.model.identity.taskID,
            checkpointRevision: basePlan.successorRevision,
            requestIdentitySHA256: requestAuthority.requestIdentitySHA256,
            producer: producer,
            terminalState: .completed,
            selectedHandleIDs: [],
            acceptedEvidenceIDs: result.citedEvidenceIDs,
            diagnostic: nil,
            finalResultCommitment: try ReconstructionFinalResultCommitment(
                resultID: result.resultID,
                canonicalSHA256: result.canonicalSHA256
            )
        )
        return try makePlan(
            basis: basis,
            disposition: basePlan.disposition,
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            toolReceipts: [],
            modelReceipts: [receipt],
            finalResults: [result],
            newTasks: base.newTasks,
            transitions: base.taskTransitions,
            freshnessAuthority: base.freshnessAuthority,
            successorCheckpointID: base.successorCheckpoint.checkpointID,
            terminalReason: base.successorCheckpoint.terminalReason,
            successorPauseContext: base.successorPauseContext
        )
    }

    func makeRecoveryPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        transitions: [ReconstructionTaskTransition]
    ) async throws -> ReconstructionJobCommitPlan {
        try Task.checkCancellation()
        try validate(cut: cut, basis: basis)
        try validate(transitions: transitions, tasks: basis.tasks)
        let successorRevision = try successorRevision(for: basis)
        return try makePlan(
            basis: basis,
            disposition: .continue,
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            toolReceipts: [],
            modelReceipts: [],
            newTasks: [],
            transitions: transitions,
            freshnessAuthority: basis.freshnessAuthority,
            successorCheckpointID: deterministicCheckpointID(
                jobID: basis.job.jobID,
                parentCheckpointID: basis.checkpoint.checkpointID,
                successorRevision: successorRevision
            ),
            terminalReason: nil,
            successorPauseContext: nil
        )
    }

    func makeControlPlan(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis,
        reason: ReconstructionJobPauseReason
    ) async throws -> ReconstructionJobCommitPlan {
        try Task.checkCancellation()
        try validate(cut: cut, basis: basis)
        let disposition = reason.controlDisposition
        let transitions: [ReconstructionTaskTransition]
        let pauseContext: ReconstructionJobPauseContext?
        let terminalReason: ReconstructionDiagnostic?
        switch disposition {
        case .paused:
            guard let cause = reason.durablePauseCause,
                  let active = basis.snapshot.currentDurableActiveState else {
                throw ReconstructionProductionReceiptPlanAuthorError.unsupportedControl
            }
            transitions = []
            pauseContext = try ReconstructionJobPauseContext(
                cause: cause,
                resumeTarget: active
            )
            terminalReason = nil
        case .cancelled:
            transitions = terminalTransitions(in: basis.tasks, to: .cancelled)
            pauseContext = nil
            terminalReason = .sanitizing("The reconstruction job was cancelled.")
        case .failed:
            transitions = terminalTransitions(in: basis.tasks, to: .failed)
            pauseContext = nil
            terminalReason = .sanitizing(reason == .modelChanged
                ? ReconstructionJobPauseReason.modelChangedDiagnostic : "The reconstruction job failed.")
        case .continue, .advancePhase, .completed:
            throw ReconstructionProductionReceiptPlanAuthorError.unsupportedControl
        }
        let successorRevision = try successorRevision(for: basis)
        return try makePlan(
            basis: basis,
            disposition: disposition,
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            toolReceipts: [],
            modelReceipts: [],
            newTasks: [],
            transitions: transitions,
            freshnessAuthority: basis.freshnessAuthority,
            successorCheckpointID: deterministicCheckpointID(
                jobID: basis.job.jobID,
                parentCheckpointID: basis.checkpoint.checkpointID,
                successorRevision: successorRevision
            ),
            terminalReason: terminalReason,
            successorPauseContext: pauseContext
        )
    }
}

private extension ReconstructionProductionReceiptPlanAuthor {
    struct ModelTaskFrontier {
        let retrieve: ReconstructionTaskRecord
        let model: ReconstructionTaskRecord
        let checkpoint: ReconstructionTaskRecord
    }

    struct FinalResultIdentityPreimage: Encodable {
        let jobID: UUID
        let taskID: UUID
        let requestID: UUID
        let checkpointID: UUID
    }

    struct EvidenceRelationIdentityPreimage: Encodable {
        let kind: ReconstructionEvidenceRelationKind
        let sourceEvidenceID: UUID
        let targetEvidenceID: UUID
    }

    struct ReauthorizedExecution {
        let evidence: [ReconstructionEvidenceRecord]
        let receipt: ReconstructionToolReceipt
    }

    struct BatchRequestIdentity: Encodable {
        let schemaVersion: Int
        let jobID: UUID
        let task: ReconstructionTaskIdentity
        let checkpointID: UUID
        let checkpointRevision: UInt64
        let checkpointSHA256: String
        let corpusManifestSHA256: String
    }

    struct BatchReceiptIdentity: Encodable {
        let jobID: UUID
        let taskID: UUID
        let successorRevision: UInt64
        let requestIdentitySHA256: String
    }

    struct BatchEvidenceIdentity: Encodable {
        let receiptID: UUID
        let payloadSHA256: String
    }

    struct EvidenceCitationIdentity: Encodable {
        let evidenceID: UUID
        let taskID: UUID
    }

    struct BatchEvidencePayload: Encodable {
        let schemaVersion: Int
        let task: ReconstructionTaskIdentity
        let outcome: String
        let projection: AnalysisProjectionPayload?
        let diagnostic: ReconstructionDiagnostic?
    }

    struct AnalysisProjectionPayload: Encodable {
        let taskID: UUID
        let taskKind: ReconstructionTaskKind
        let artifact: ReconstructionArtifactCoordinate
        let image: ReconstructionImageBinding
        let analysisFingerprintSHA256: String
        let functionCatalog: [FunctionSummary]
        let functionCatalogWasTruncated: Bool
        let functionNamesWereTruncated: Bool
        let function: FunctionSummary?
        let macScopePseudocode: String?
        let macScopePseudocodeWasTruncated: Bool

        init(_ projection: ReconstructionTransientAnalysisProjection) {
            taskID = projection.taskID
            taskKind = projection.taskKind
            artifact = projection.artifact
            image = projection.image
            analysisFingerprintSHA256 = projection.analysisFingerprintSHA256
            functionCatalog = projection.functionCatalog
            functionCatalogWasTruncated = projection.functionCatalogWasTruncated
            functionNamesWereTruncated = projection.functionNamesWereTruncated
            function = projection.function
            macScopePseudocode = projection.macScopePseudocode
            macScopePseudocodeWasTruncated = projection.macScopePseudocodeWasTruncated
        }
    }

    func validate(
        cut: ReconstructionProductionCommittedRoundCut,
        basis: ReconstructionProductionRoundBasis
    ) throws {
        guard cut.snapshot == basis.snapshot,
              cut.parentCheckpointID == basis.checkpoint.checkpointID,
              cut.parentCheckpointSHA256 == basis.checkpoint.canonicalSHA256,
              cut.prepared.evidenceCut == basis.evidenceCut,
              cut.prepared.authority.jobID == basis.job.jobID,
              cut.prepared.authority.checkpointRevision == basis.checkpoint.revision,
              cut.prepared.authority.roundID == cut.prepared.roundID,
              cut.prepared.authority.corpusManifestSHA256
                == basis.manifest.canonicalSHA256,
              cut.prepared.authority.evidenceFrontierSHA256
                == basis.evidenceCut.frontierSHA256 else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
        }
    }

    func uniqueTasks(
        _ tasks: [ReconstructionTaskRecord]
    ) throws -> [UUID: ReconstructionTaskRecord] {
        var result: [UUID: ReconstructionTaskRecord] = [:]
        for task in tasks {
            guard result.updateValue(task, forKey: task.identity.taskID) == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
            }
        }
        return result
    }

    func modelTaskFrontier(
        _ tasks: [ReconstructionTaskRecord]
    ) throws -> ModelTaskFrontier {
        let retrieves = tasks.filter {
            $0.identity.kind == .retrieveEvidence
                && $0.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.evidenceQuery
                && $0.state == .running
        }
        let models = tasks.filter {
            $0.identity.kind == .modelRound
                && $0.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.modelRound
                && $0.state == .running
        }
        guard retrieves.count == 1, let retrieve = retrieves.first,
              models.count == 1, let model = models.first else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
        }
        let checkpoints = tasks.filter {
            $0.identity.kind == .checkpoint
                && $0.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.checkpoint
                && $0.state == .pending
                && $0.identity.dependencyTaskIDs == [model.identity.taskID]
        }
        guard checkpoints.count == 1, let checkpoint = checkpoints.first,
              model.identity.dependencyTaskIDs == [retrieve.identity.taskID],
              checkpoint.identity.dependencyTaskIDs == [model.identity.taskID] else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
        }
        return .init(retrieve: retrieve, model: model, checkpoint: checkpoint)
    }

    func finalSynthesisTaskFrontier(
        _ tasks: [ReconstructionTaskRecord]
    ) throws -> ReconstructionProductionFinalSynthesisFrontier {
        let models = tasks.filter {
            $0.identity.kind == .modelRound
                && $0.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.finalSynthesis
                && $0.state == .running
        }
        guard models.count == 1, let model = models.first else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
        }
        let checkpoints = tasks.filter {
            $0.identity.kind == .checkpoint
                && $0.identity.operationContractIdentity
                    == ReconstructionProductionTaskContract.checkpoint
                && $0.state == .pending
                && $0.identity.dependencyTaskIDs == [model.identity.taskID]
        }
        guard checkpoints.count == 1, let checkpoint = checkpoints.first else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
        }
        return .init(model: model, checkpoint: checkpoint)
    }

    func validateReceiptFreeBasePlan(
        _ basePlan: ReconstructionJobCommitPlan,
        basis: ReconstructionProductionRoundBasis
    ) throws -> ReconstructionCheckpointMutation {
        let successorRevision = try successorRevision(for: basis)
        guard let base = basePlan.mutation,
              basePlan.successorRevision == successorRevision,
              base.jobID == basis.job.jobID,
              base.expectedParentCheckpointID == basis.checkpoint.checkpointID,
              base.expectedParentCheckpointSHA256 == basis.checkpoint.canonicalSHA256,
              base.expectedParentRevision == basis.checkpoint.revision,
              base.evidence.isEmpty,
              base.evidenceRelations.isEmpty,
              base.evidenceGaps.isEmpty,
              base.toolReceipts.isEmpty,
              base.modelReceipts.isEmpty,
              base.finalResults.isEmpty,
              base.successorCheckpoint.revision == successorRevision else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
        }
        return base
    }

    func validate(
        requestAuthority: ReconstructionModelTerminalRequestAuthority,
        expectedRequest: ReconstructionAIWorkerRequest,
        expectedStatus: ReconstructionTerminalStatus
    ) throws {
        let expectedSHA256: String = switch expectedRequest {
        case .sourceRevision(let request): try ReconstructionCanonicalJSON.sha256(of: request)
        case .round(let request):
            try ReconstructionCanonicalJSON.sha256(of: request)
        case .finalSynthesis(let request):
            try ReconstructionCanonicalJSON.sha256(of: request)
        case .roundR2(let request):
            try ReconstructionCanonicalJSON.sha256(of: request)
        case .finalSynthesisR2(let request):
            try ReconstructionCanonicalJSON.sha256(of: request)
        }
        let rebuilt = try ReconstructionModelTerminalRequestAuthority.make(
            expectedRequestID: requestAuthority.expectedRequestID,
            request: requestAuthority.request,
            terminalReceipt: requestAuthority.terminalReceipt
        )
        guard requestAuthority.request == expectedRequest,
              requestAuthority.requestIdentitySHA256 == expectedSHA256,
              rebuilt.requestIdentitySHA256 == expectedSHA256,
              requestAuthority.terminalReceipt.status == expectedStatus else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTerminalReceipt
        }
    }

    func makeModelProducerIdentity(
        lease: Phase2ReadyInferenceLease,
        operationIdentity: String,
        request: ReconstructionAIWorkerRequest
    ) throws -> ReconstructionProducerIdentity {
        let protocolIdentity: String
        switch request {
        case .sourceRevision:
            guard modelProducerContext.protocolIdentity == Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest
                || modelProducerContext.protocolIdentity == Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
            }
            protocolIdentity = Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest
        case .roundR2, .finalSynthesisR2:
            guard modelProducerContext.protocolIdentity
                    == Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
            }
            protocolIdentity = modelProducerContext.protocolIdentity
        case .round, .finalSynthesis:
            protocolIdentity = modelProducerContext.protocolIdentity
        }
        return try ReconstructionReceiptAuthority.makeModelProducerIdentity(
            lease: lease,
            context: ReconstructionModelProducerIdentityContext(
                macScopeBuildIdentity: modelProducerContext.macScopeBuildIdentity,
                macScopeSourceIdentity: modelProducerContext.macScopeSourceIdentity,
                operationIdentity: operationIdentity,
                registryIdentity: modelProducerContext.registryIdentity,
                protocolIdentity: protocolIdentity,
                toolchainIdentity: modelProducerContext.toolchainIdentity
            )
        )
    }

    func boundRequest(_ request: ReconstructionAIWorkerRequest,
        prepared: ReconstructionPreparedModelRound,
        basis: ReconstructionProductionRoundBasis) throws -> ReconstructionAIWorkerRequest {
        guard let objective = prepared.objective else { return request }
        // R2 preparation captures the durable source intent in its objective. Source v10
        // retains its separate, profile-free objective contract.
        let sourceProfileID: String?
        switch request {
        case .round, .finalSynthesis:
            sourceProfileID = basis.job.sourceProfileID
        case .sourceRevision:
            sourceProfileID = nil
        case .roundR2, .finalSynthesisR2:
            throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
        }
        let committedObjective = try ReconstructionRequestObjective(jobID: basis.job.jobID,
            text: basis.job.objective, sha256: basis.job.objectiveSHA256,
            sourceProfileID: sourceProfileID)
        guard objective == committedObjective else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
        }
        switch request {
        case .round(let value):
            return .roundR2(.init(protocolVersion: 9, objective: objective, request: value))
        case .finalSynthesis(let value):
            return .finalSynthesisR2(.init(protocolVersion: 9, objective: objective, request: value))
        case .sourceRevision(let value):
            guard value == prepared.sourceRevisionRequest, value.objective == objective else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
            }
            try value.validate()
            return request
        case .roundR2, .finalSynthesisR2:
            throw ReconstructionProductionReceiptPlanAuthorError.invalidCommittedAuthority
        }
    }

    func makeRoundRequest(
        _ prepared: ReconstructionPreparedModelRound,
        basis: ReconstructionProductionRoundBasis
    ) throws -> ReconstructionInferenceRoundRequest {
        let context = try contextCompiler.compile(
            cut: prepared.evidenceCut,
            query: prepared.retrievalQuery,
            allowedGapSubjects: prepared.allowedGapSubjects,
            allowedGapCategories: prepared.allowedGapCategories
        )
        let handles = try registry.mintHandles(
            authority: prepared.authority,
            requests: prepared.requests
        )
        return ReconstructionInferenceRoundRequest(
            protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
            jobID: basis.job.jobID,
            checkpointRevision: basis.checkpoint.revision,
            roundID: prepared.roundID,
            corpusManifestSHA256: prepared.authority.corpusManifestSHA256,
            evidenceFrontierSHA256: prepared.authority.evidenceFrontierSHA256,
            registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
                .toolRegistry.identity.sha256,
            context: context,
            handles: handles.map {
                .init(handleID: $0.handleID, operationID: $0.operationID)
            },
            transientAnalysis: prepared.objective == nil ? nil : prepared.transientAnalysis
        )
    }

    func validate(
        inference: ReconstructionInferenceExecutionResult,
        request: ReconstructionInferenceRoundRequest
    ) throws {
        guard inference.candidate.jobID == request.jobID,
              inference.candidate.checkpointRevision == request.checkpointRevision,
              inference.candidate.roundID == request.roundID,
              inference.terminalReceipt.jobID == request.jobID,
              inference.terminalReceipt.checkpointRevision == request.checkpointRevision,
              inference.terminalReceipt.roundID == request.roundID,
              inference.terminalReceipt.status == .completed else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTerminalReceipt
        }
    }

    func validateGapDeclarations(
        _ candidate: ReconstructionInferenceRoundCandidate,
        prepared: ReconstructionPreparedModelRound
    ) throws {
        let allowedSubjects = Set(prepared.allowedGapSubjects)
        let allowedCategories = Set(prepared.allowedGapCategories)
        let allowedPairs = try Set(prepared.evidenceCut.gaps.map { gap in
            "subject:\(try ReconstructionCanonicalJSON.sha256(of: gap.subject))"
                + "\u{0}" + gap.operationID
        })
        var identities: Set<String> = []
        for declaration in candidate.unresolvedGaps {
            let reason = declaration.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            let identity = declaration.subject + "\u{0}" + declaration.category
            guard allowedSubjects.contains(declaration.subject),
                  allowedCategories.contains(declaration.category),
                  allowedPairs.contains(identity),
                  !reason.isEmpty,
                  reason.utf8.count <= ReconstructionDiagnostic.defaultMaxUTF8Bytes,
                  identities.insert(identity).inserted else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidGapDeclaration
            }
        }
    }

    func makeGapResolutionRelations(
        candidate: ReconstructionInferenceRoundCandidate,
        executionsByID: [UUID: ReconstructionToolExecution],
        supersessionRelations: [ReconstructionEvidenceRelation],
        basis: ReconstructionProductionRoundBasis,
        prepared: ReconstructionPreparedModelRound
    ) throws -> [ReconstructionEvidenceRelation] {
        let claims = candidate.resolvedGaps
        let canonicalClaims = claims.sorted {
            if $0.gapID != $1.gapID {
                return $0.gapID.uuidString.lowercased() < $1.gapID.uuidString.lowercased()
            }
            if $0.handleID != $1.handleID {
                return $0.handleID.uuidString.lowercased() < $1.handleID.uuidString.lowercased()
            }
            return $0.evidenceID.uuidString.lowercased()
                < $1.evidenceID.uuidString.lowercased()
        }
        guard claims.count <= 64,
              claims == canonicalClaims,
              Set(claims).count == claims.count,
              Set(claims.map(\.gapID)).count == claims.count,
              Set(claims.map(\.handleID)).isSubset(of: Set(candidate.selectedHandleIDs)) else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidGapResolution
        }
        let claimsByHandleID = Dictionary(grouping: claims, by: \.handleID)
        for (handleID, execution) in executionsByID {
            let expected = ReconstructionValidation.sortedUUIDs(
                claimsByHandleID[handleID, default: []].map(\.gapID)
            )
            guard execution.resolvedGapIDs == expected else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidGapResolution
            }
        }
        let gapsByID = Dictionary(uniqueKeysWithValues: basis.evidenceCut.gaps.map {
            ($0.gapID, $0)
        })
        let evidenceByID = Dictionary(uniqueKeysWithValues: basis.evidenceCut.records.map {
            ($0.evidenceID, $0)
        })
        let retrievedPacket: ReconstructionRetrievalPacket
        do {
            retrievedPacket = try ReconstructionRetrievalCompiler().compile(
                cut: prepared.evidenceCut,
                query: prepared.retrievalQuery
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidGapResolution
        }
        let retrievedEvidenceIDs = Set(retrievedPacket.records.map(\.evidenceID))
        var relationIDs = Set(
            (basis.evidenceCut.relations + supersessionRelations).map(\.relationID)
        )
        var relations: [ReconstructionEvidenceRelation] = []
        for claim in claims {
            guard let execution = executionsByID[claim.handleID],
                  execution.operationID == .evidenceQuery,
                  execution.resolvedGapIDs.contains(claim.gapID),
                  execution.acceptedEvidence.isEmpty,
                  execution.result.outcome
                    == (retrievedPacket.hasMore ? .truncated : .success),
                  execution.result.payload == retrievedPacket.canonicalBytes,
                  execution.result.payloadSHA256 == retrievedPacket.canonicalSHA256,
                  execution.result.itemCount == retrievedPacket.records.count,
                  retrievedEvidenceIDs.contains(claim.evidenceID),
                  let gap = gapsByID[claim.gapID],
                  let evidence = evidenceByID[claim.evidenceID],
                  basis.evidenceCut.projectedClassificationsByEvidenceID[claim.evidenceID]
                    == .acceptedCurrent,
                  evidence.supersededByEvidenceID == nil,
                  evidence.subject == gap.subject,
                  evidence.operationID == gap.operationID else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidGapResolution
            }
            let relationID = try nameDerivedUUID(
                domain: "MacScope.ReconstructionEvidenceRelation.v1",
                value: EvidenceRelationIdentityPreimage(
                    kind: .resolvesGap,
                    sourceEvidenceID: evidence.evidenceID,
                    targetEvidenceID: gap.gapID
                )
            )
            guard relationIDs.insert(relationID).inserted else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidGapResolution
            }
            relations.append(.init(
                relationID: relationID,
                kind: .resolvesGap,
                sourceEvidenceID: evidence.evidenceID,
                targetEvidenceID: gap.gapID
            ))
        }
        return relations
    }

    func reauthorize(
        execution: ReconstructionToolExecution,
        handle: ReconstructionToolHandle,
        successorCheckpointID: UUID,
        successorRevision: UInt64,
        basis: ReconstructionProductionRoundBasis,
        prepared: ReconstructionPreparedModelRound,
        alreadyAccepted: [ReconstructionEvidenceRecord]
    ) throws -> ReauthorizedExecution {
        guard execution.handleID == handle.handleID,
              execution.operationID == handle.operationID,
              prepared.projectorInput.authority == prepared.authority,
              prepared.projectorInput.corpusManifest == basis.manifest,
              prepared.projectorInput.evidenceCut == basis.evidenceCut,
              prepared.projectorInput.tasks == basis.tasks,
              prepared.projectorInput.receipts == basis.toolReceipts else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        let envelope: ReconstructionToolRequestEnvelope
        do {
            envelope = try registry.decodeCanonicalRequest(handle)
        } catch {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        let isDemand = handle.operationID == .analysisMacScopeRefresh
        if isDemand {
            guard case .function(let function)? = envelope.subject,
                  envelope.retrievalQuery == nil, envelope.offset == 0,
                  envelope.maximumRecords == 1,
                  execution.result.outcome == .success,
                  execution.result.itemCount == 1,
                  execution.result.diagnostic == nil,
                  execution.result.continuationRequest == nil,
                  execution.result.evidenceCandidates.isEmpty,
                  execution.acceptedEvidence.isEmpty,
                  execution.resolvedGapIDs.isEmpty,
                  execution.result.payload == (try ReconstructionMacScopeAnalysisDemand
                    .acknowledgement(for: envelope)),
                  sha256(execution.result.payload) == execution.result.payloadSHA256 else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
            }
            _ = try ReconstructionMacScopeAnalysisDemand.enumerationTask(for: function,
                tasks: basis.tasks, evidenceCut: basis.evidenceCut)
        }
        guard envelope.authority == prepared.authority,
              let requestTask = basis.tasks.first(where: {
                  $0.identity.taskID == envelope.taskID
              }),
              basis.tasks.lazy.filter({
                  $0.identity.taskID == envelope.taskID
              }).count == 1,
              requestTask.identity.jobID == basis.job.jobID,
              requestTask.identity.kind == .retrieveEvidence,
              requestTask.state == .running,
              (isDemand ? requestTask.identity.subject == nil
                : requestTask.identity.subject == envelope.subject),
              requestTask.identity.operationContractIdentity == (isDemand
                ? ReconstructionProductionTaskContract.evidenceQuery : handle.operationID.rawValue),
              let expectedProducer = prepared.projectorInput
                .producersByOperation[handle.operationID],
              expectedProducer.operationIdentity == handle.operationID.rawValue,
              ReconstructionEvidenceIntegrity
                .producerContainsOnlyDurableBoundedIdentity(expectedProducer),
              try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(expectedProducer)
                == expectedProducer.canonicalSHA256 else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
        }
        let source = execution.receipt
        // Broker receipts are unextended. Only this commit owner retains independently verified
        // reads under their durable successor receipt; no model or projector supplies that authority.
        guard source.evidenceReadAuthority == nil else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolReceipt
        }
        let evidenceReadAuthority: ReconstructionEvidenceReadAuthority?
        if handle.operationID == .evidenceQuery,
           execution.result.outcome == .success || execution.result.outcome == .truncated {
            do {
                evidenceReadAuthority = try ReconstructionEvidenceReadAuthority.capture(
                    request: envelope, result: execution.result, cut: prepared.evidenceCut)
                let deliveredContext = try contextCompiler.compile(cut: prepared.evidenceCut,
                    query: prepared.retrievalQuery, allowedGapSubjects: prepared.allowedGapSubjects,
                    allowedGapCategories: prepared.allowedGapCategories)
                guard evidenceReadAuthority?.readEvidenceIDs == deliveredContext.evidenceIDs else {
                    throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolExecution
            }
        } else { evidenceReadAuthority = nil }
        let expectedState: ReconstructionReceiptTerminalState = switch execution.result.outcome {
        case .success, .unavailable, .stale: .completed
        case .truncated: .truncated
        case .failed: .failed
        }
        let evidenceIDs = ReconstructionValidation.sortedUUIDs(
            execution.acceptedEvidence.map(\.evidenceID)
        )
        guard source.receiptID == handle.handleID,
              source.jobID == basis.job.jobID,
              source.taskID == envelope.taskID,
              source.checkpointRevision == basis.checkpoint.revision,
              source.requestIdentitySHA256 == handle.requestSHA256,
              source.terminalState == expectedState,
              source.outputEvidenceIDs == evidenceIDs,
              source.diagnostic == execution.result.diagnostic,
              execution.acceptedEvidence.allSatisfy({ record in
                  envelope.subject != nil
                    && record.subject == envelope.subject
                    && record.creatingJobID == basis.job.jobID
                    && record.creatingTaskID == envelope.taskID
                    && record.creatingCheckpointID == basis.checkpoint.checkpointID
                    && record.toolReceiptID == source.receiptID
                    && record.modelReceiptID == nil
                    && record.producer == source.producer
              }),
              try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(source),
              try ReconstructionReceiptAuthority.makeToolReceipt(
                receiptID: source.receiptID,
                jobID: source.jobID,
                taskID: source.taskID,
                checkpointRevision: source.checkpointRevision,
                requestIdentitySHA256: source.requestIdentitySHA256,
                producer: source.producer,
                terminalState: source.terminalState,
                outputEvidenceIDs: source.outputEvidenceIDs,
                diagnostic: source.diagnostic
              ) == source else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolReceipt
        }
        guard source.producer == expectedProducer else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidToolReceipt
        }

        var rebound: [ReconstructionEvidenceRecord] = []
        for record in execution.acceptedEvidence.sorted(by: {
            $0.evidenceID.uuidString.lowercased() < $1.evidenceID.uuidString.lowercased()
        }) {
            guard record.operationID == handle.operationID.rawValue,
                  sha256(record.payload) == record.payloadSHA256,
                  UInt64(record.payload.count) == record.payloadByteCount else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
            }
            let candidate = try ReconstructionEvidenceCandidate(
                evidenceID: record.evidenceID,
                subject: record.subject,
                operationID: handle.operationID,
                payloadKind: record.payloadKind,
                payload: record.payload,
                payloadByteCount: record.payloadByteCount,
                payloadSHA256: record.payloadSHA256,
                facetDependencies: record.facetDependencies,
                producer: record.producer,
                citations: record.citations,
                creatingJobID: record.creatingJobID,
                creatingTaskID: record.creatingTaskID,
                creatingCheckpointID: successorCheckpointID,
                modelReceiptID: nil,
                toolReceiptID: source.receiptID,
                supersedesEvidenceID: record.supersedesEvidenceID,
                diagnostic: record.diagnostic
            )
            rebound.append(try accept(
                candidate,
                operation: handle.operationID,
                producer: record.producer,
                taskID: envelope.taskID,
                receiptID: source.receiptID,
                checkpointID: successorCheckpointID,
                checkpointRevision: successorRevision,
                freshnessAuthority: basis.freshnessAuthority,
                basis: basis,
                alreadyAccepted: alreadyAccepted + rebound
            ))
        }
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: source.receiptID,
            jobID: source.jobID,
            taskID: source.taskID,
            checkpointRevision: successorRevision,
            requestIdentitySHA256: source.requestIdentitySHA256,
            producer: source.producer,
            terminalState: source.terminalState,
            outputEvidenceIDs: rebound.map(\.evidenceID),
            diagnostic: source.diagnostic,
            evidenceReadAuthority: evidenceReadAuthority
        )
        return .init(evidence: rebound, receipt: receipt)
    }

    func accept(
        _ candidate: ReconstructionEvidenceCandidate,
        operation: ReconstructionOperationID,
        producer: ReconstructionProducerIdentity,
        taskID: UUID,
        receiptID: UUID,
        checkpointID: UUID,
        checkpointRevision: UInt64,
        freshnessAuthority: ReconstructionFreshnessAuthority,
        basis: ReconstructionProductionRoundBasis,
        alreadyAccepted: [ReconstructionEvidenceRecord]
    ) throws -> ReconstructionEvidenceRecord {
        var candidateSubjects = freshnessAuthority.currentArtifacts.map {
            ReconstructionSubjectCoordinate.artifact($0)
        }
        candidateSubjects.append(contentsOf: freshnessAuthority.currentImages.map {
            ReconstructionSubjectCoordinate.image($0)
        })
        candidateSubjects.append(contentsOf: freshnessAuthority.currentFacetFingerprints.keys)
        // Persisted task identities are already part of the immutable committed basis. They may
        // authorize an exact function subject that has no independent facet fingerprint yet;
        // an untrusted candidate itself never widens this set.
        candidateSubjects.append(contentsOf: basis.tasks.compactMap(\.identity.subject))
        var seenSubjects = Set<ReconstructionSubjectCoordinate>()
        let authoritativeSubjects = candidateSubjects.filter {
            seenSubjects.insert($0).inserted
        }
        let cut = ReconstructionAuthorityCut(
            corpusManifest: basis.manifest,
            authoritativeSubjects: authoritativeSubjects,
            facetFingerprints: freshnessAuthority.currentFacetFingerprints[candidate.subject] ?? [:],
            creatingJobID: basis.job.jobID,
            creatingTaskID: taskID,
            creatingCheckpointID: checkpointID,
            checkpointRevision: checkpointRevision,
            operationID: operation,
            toolReceiptID: receiptID,
            modelReceiptID: nil,
            producer: producer,
            evidence: basis.evidenceCut.records + alreadyAccepted
        )
        do {
            return try evidenceAcceptor.validate(candidate, against: cut)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
        }
    }

    func makeSupersessionRelations(
        for acceptedEvidence: [ReconstructionEvidenceRecord],
        basis: ReconstructionProductionRoundBasis
    ) throws -> [ReconstructionEvidenceRelation] {
        let allEvidence = basis.evidenceCut.records + acceptedEvidence
        guard Set(allEvidence.map(\.evidenceID)).count == allEvidence.count else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
        }
        let evidenceByID = Dictionary(uniqueKeysWithValues: allEvidence.map {
            ($0.evidenceID, $0)
        })
        var relationIDs = Set(basis.evidenceCut.relations.map(\.relationID))
        var relations: [ReconstructionEvidenceRelation] = []
        for record in acceptedEvidence.sorted(by: {
            $0.evidenceID.uuidString.lowercased() < $1.evidenceID.uuidString.lowercased()
        }) {
            guard let predecessorID = record.supersedesEvidenceID else { continue }
            guard let predecessor = evidenceByID[predecessorID],
                  predecessor.subject == record.subject,
                  predecessor.operationID == record.operationID else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
            }
            let relationID = try nameDerivedUUID(
                domain: "MacScope.ReconstructionEvidenceRelation.v1",
                value: EvidenceRelationIdentityPreimage(
                    kind: .supersedes,
                    sourceEvidenceID: record.evidenceID,
                    targetEvidenceID: predecessorID
                )
            )
            guard relationIDs.insert(relationID).inserted else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
            }
            relations.append(.init(
                relationID: relationID,
                kind: .supersedes,
                sourceEvidenceID: record.evidenceID,
                targetEvidenceID: predecessorID
            ))
        }
        do {
            _ = try ReconstructionEvidenceGraphIntegrity.validate(
                records: allEvidence,
                relations: basis.evidenceCut.relations + relations,
                gapIDs: Set(basis.evidenceCut.gaps.map(\.gapID))
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidEvidence
        }
        return relations
    }

    func validate(
        batchResult: ReconstructionTerminalTaskResult,
        task: ReconstructionTaskRecord,
        basis: ReconstructionProductionRoundBasis
    ) throws {
        guard batchResult.jobID == basis.job.jobID,
              batchResult.taskID == task.identity.taskID,
              batchResult.checkpointID == basis.checkpoint.checkpointID,
              batchResult.checkpointRevision == basis.checkpoint.revision,
              batchResult.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
              task.state == .pending || task.state == .running,
              batchResult.outcome != .staleAuthority else {
            throw ReconstructionProductionReceiptPlanAuthorError.mismatchedTerminalResult
        }
        switch (task.identity.kind, batchResult.outcome) {
        case (.loadBinary, .completed), (.indexImage, .completed),
             (.enumerateFunctions, .completed), (.decompileMacScope, .completed):
            guard batchResult.analysisProjection?.taskID == task.identity.taskID,
                  batchResult.analysisProjection?.taskKind == task.identity.kind,
                  batchResult.nativeResult == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.missingTerminalResult
            }
        case (.decompileNative, .completed), (.compareDecompilers, .completed)
            where batchResult.nativeResult == nil && batchResult.decompileFallbackReason != nil:
            // D13 MacIR fallback: no native bytes or native producer identity.
            guard batchResult.analysisProjection?.taskID == task.identity.taskID,
                  batchResult.analysisProjection?.taskKind == task.identity.kind else {
                throw ReconstructionProductionReceiptPlanAuthorError.missingTerminalResult
            }
        case (.decompileNative, .completed), (.compareDecompilers, .completed):
            guard batchResult.analysisProjection?.taskID == task.identity.taskID,
                  batchResult.analysisProjection?.taskKind == task.identity.kind,
                  let native = completedNativeSuccess(batchResult.nativeResult),
                  native.taskID == task.identity.taskID,
                  native.checkpointID == basis.checkpoint.checkpointID,
                  native.checkpointRevision == basis.checkpoint.revision,
                  native.corpusManifestSHA256 == basis.manifest.canonicalSHA256 else {
                throw ReconstructionProductionReceiptPlanAuthorError.missingTerminalResult
            }
        case (.ingest, .completed), (.classify, .completed),
             (.discoverRelations, .completed):
            guard batchResult.analysisProjection == nil,
                  batchResult.nativeResult == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.mismatchedTerminalResult
            }
        case (.executeSource, .completed):
            guard batchResult.analysisProjection == nil, batchResult.nativeResult == nil,
                  batchResult.sourceExecution?.isValid(for: task, authority: try .init(
                    jobID: basis.job.jobID, checkpointID: basis.checkpoint.checkpointID,
                    checkpointRevision: basis.checkpoint.revision,
                    corpusManifestSHA256: basis.manifest.canonicalSHA256)) == true else {
                throw ReconstructionProductionReceiptPlanAuthorError.mismatchedTerminalResult
            }
        case (.retrieveEvidence, _), (.modelRound, _), (.checkpoint, _):
            throw ReconstructionProductionReceiptPlanAuthorError.mismatchedTerminalResult
        case (_, .failed), (_, .cancelled):
            guard batchResult.analysisProjection == nil,
                  batchResult.nativeResult == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.mismatchedTerminalResult
            }
        case (_, .staleAuthority):
            throw ReconstructionProductionReceiptPlanAuthorError.mismatchedTerminalResult
        }
        if let admission = batchResult.loadedImageAdmission {
            guard task.identity.kind == .loadBinary, batchResult.outcome == .completed,
                  admission.taskID == task.identity.taskID,
                  let projection = batchResult.analysisProjection,
                  admission.snapshot.artifact == projection.artifact,
                  admission.snapshot.image == projection.image,
                  admission.snapshot.analysisInputFingerprintSHA256 == projection.analysisFingerprintSHA256 else {
                throw ReconstructionProductionReceiptPlanAuthorError.mismatchedTerminalResult
            }
        }
    }

    func validate(
        transitions: [ReconstructionTaskTransition],
        tasks: [ReconstructionTaskRecord]
    ) throws {
        let byID = try uniqueTasks(tasks)
        guard !transitions.isEmpty,
              Set(transitions.map(\.taskID)).count == transitions.count,
              transitions.allSatisfy({ transition in
                  byID[transition.taskID]?.state == transition.expectedState
                    && transition.expectedState != transition.successorState
              }) else {
            throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
        }
    }

    func makeToolProducer(
        operationIdentity: String,
        nativeSuccess: ReconstructionNativeTaskSuccess?
    ) throws -> ReconstructionProducerIdentity {
        let nativeIdentity: String?
        let nativeCapabilities: [String]
        if let success = nativeSuccess {
            nativeIdentity = try ReconstructionCanonicalJSON.sha256(
                of: success.execution.success.availability.runtimeIdentity
            )
            let capabilities = success.execution.success.availability.capabilities
            nativeCapabilities = [
                capabilities.nativeDecompilerHeritage ? "native-heritage" : nil,
                capabilities.completeRegisterSSA ? "complete-register-ssa" : nil,
                capabilities.memorySSA ? "memory-ssa" : nil,
                capabilities.recoveredVariables ? "recovered-variables" : nil,
                capabilities.recoveredTypes ? "recovered-types" : nil,
                capabilities.structuredControlFlow ? "structured-control-flow" : nil,
                capabilities.tokenizedPseudocode ? "tokenized-pseudocode" : nil,
                capabilities.imageQualifiedSourceRanges ? "image-qualified-source-ranges" : nil,
            ].compactMap { $0 }
        } else {
            nativeIdentity = nil
            nativeCapabilities = []
        }
        let provisional = try ReconstructionProducerIdentity(
            macScopeBuildIdentity: modelProducerContext.macScopeBuildIdentity,
            macScopeSourceIdentity: modelProducerContext.macScopeSourceIdentity,
            operationIdentity: operationIdentity,
            registryIdentity: modelProducerContext.registryIdentity,
            protocolIdentity: modelProducerContext.protocolIdentity,
            nativeProviderIdentity: nativeIdentity,
            nativeCapabilityIdentities: nativeCapabilities,
            modelKey: nil,
            endpointOrigin: nil,
            observedModelInventorySHA256: nil,
            observedConfigurationSHA256: nil,
            toolchainIdentity: modelProducerContext.toolchainIdentity,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        return try ReconstructionProducerIdentity(
            schemaVersion: provisional.schemaVersion,
            macScopeBuildIdentity: provisional.macScopeBuildIdentity,
            macScopeSourceIdentity: provisional.macScopeSourceIdentity,
            operationIdentity: provisional.operationIdentity,
            registryIdentity: provisional.registryIdentity,
            protocolIdentity: provisional.protocolIdentity,
            nativeProviderIdentity: provisional.nativeProviderIdentity,
            nativeCapabilityIdentities: provisional.nativeCapabilityIdentities,
            modelKey: provisional.modelKey,
            endpointOrigin: provisional.endpointOrigin,
            observedModelInventorySHA256: provisional.observedModelInventorySHA256,
            observedConfigurationSHA256: provisional.observedConfigurationSHA256,
            toolchainIdentity: provisional.toolchainIdentity,
            canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(provisional)
        )
    }

    func makePlan(
        basis: ReconstructionProductionRoundBasis,
        disposition: ReconstructionJobCoordinatorDisposition,
        evidence: [ReconstructionEvidenceRecord],
        evidenceRelations: [ReconstructionEvidenceRelation],
        evidenceGaps: [ReconstructionEvidenceGap],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        finalResults: [ReconstructionFinalResultRecord] = [],
        newTasks: [ReconstructionTaskRecord],
        transitions: [ReconstructionTaskTransition],
        freshnessAuthority: ReconstructionFreshnessAuthority,
        successorCheckpointID: UUID,
        terminalReason: ReconstructionDiagnostic?,
        successorPauseContext: ReconstructionJobPauseContext?,
        analysisImports: [ReconstructionLoadedImageAdmission] = []
    ) throws -> ReconstructionJobCommitPlan {
        let successorRevision = try successorRevision(for: basis)
        guard evidence.count <= basis.job.budget.maxEvidenceRecords,
              basis.evidenceCut.records.count
                <= basis.job.budget.maxEvidenceRecords - evidence.count,
              Set(evidence.map(\.evidenceID)).count == evidence.count,
              Set(toolReceipts.map(\.receiptID)).count == toolReceipts.count,
              Set(modelReceipts.map(\.receiptID)).count == modelReceipts.count,
              Set(finalResults.map(\.resultID)).count == finalResults.count,
              Set(basis.evidenceCut.records.map(\.evidenceID)).isDisjoint(
                with: evidence.map(\.evidenceID)
              ),
              Set(basis.toolReceipts.map(\.receiptID)).isDisjoint(
                with: toolReceipts.map(\.receiptID)
              ),
              Set(basis.modelReceipts.map(\.receiptID)).isDisjoint(
                with: modelReceipts.map(\.receiptID)
              ) else {
            throw ReconstructionProductionReceiptPlanAuthorError.budgetExceeded
        }
        for receipt in toolReceipts {
            guard try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt),
                  receipt.checkpointRevision == successorRevision else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidToolReceipt
            }
        }
        for receipt in modelReceipts {
            guard try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt),
                  receipt.checkpointRevision == successorRevision else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidTerminalReceipt
            }
        }
        for result in finalResults {
            guard try ReconstructionReceiptAuthority.finalResultHasCanonicalIdentity(result),
                  result.checkpointRevision == successorRevision,
                  result.checkpointID == successorCheckpointID else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidTerminalReceipt
            }
        }

        let tasks = try applying(transitions, to: basis.tasks) + newTasks
        guard tasks.count <= basis.job.budget.maxTasks,
              Set(tasks.map(\.identity.taskID)).count == tasks.count,
              try UInt64(ReconstructionCanonicalJSON.encode(tasks).count)
                <= basis.job.budget.maxEncodedBytes else {
            throw ReconstructionProductionReceiptPlanAuthorError.budgetExceeded
        }
        let allEvidence = basis.evidenceCut.records + evidence
        let allRelations = basis.evidenceCut.relations + evidenceRelations
        let allGaps = basis.evidenceCut.gaps + evidenceGaps
        let projection = try ReconstructionEvidenceProjector().project(
            records: allEvidence,
            relations: allRelations.filter { $0.kind != .resolvesGap },
            authority: freshnessAuthority
        )
        let classifications = Dictionary(uniqueKeysWithValues: projection.records.map {
            ($0.record.evidenceID, $0.classification)
        })
        var revisions = basis.evidenceCut.checkpointRevisionsByID
        if !evidence.isEmpty { revisions[successorCheckpointID] = successorRevision }
        let evidenceFrontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            records: allEvidence,
            projectedClassificationsByEvidenceID: classifications,
            relations: allRelations,
            gaps: allGaps,
            checkpointRevisionsByID: revisions
        )
        let gapProjection = try ReconstructionGapProjector().project(
            gaps: allGaps,
            records: allEvidence,
            relations: allRelations,
            projectedClassificationsByEvidenceID: classifications
        )

        let coordinatorState: ReconstructionJobState
        switch disposition {
        case .advancePhase(let phase):
            guard basis.job.state != .paused, terminalReason == nil,
                  successorPauseContext == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            do {
                try ReconstructionJobStateMachine.transition(
                    from: basis.job.state, to: phase, resumeTarget: nil
                )
            } catch {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            coordinatorState = phase
        case .continue:
            guard let active = basis.snapshot.currentDurableActiveState,
                  terminalReason == nil,
                  successorPauseContext == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            coordinatorState = active
        case .completed:
            guard terminalReason == nil, successorPauseContext == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            coordinatorState = .completed
        case .paused(let reason):
            guard successorPauseContext?.cause == reason.durablePauseCause,
                  terminalReason == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            coordinatorState = .paused
        case .cancelled:
            guard terminalReason != nil, successorPauseContext == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            coordinatorState = .cancelled
        case .failed:
            guard terminalReason != nil, successorPauseContext == nil else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidBasePlan
            }
            coordinatorState = .failed
        }

        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: successorCheckpointID,
            jobID: basis.job.jobID,
            revision: successorRevision,
            parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: evidenceFrontier,
            pendingTaskIDs: taskIDs(in: tasks, states: [.pending]),
            runningTaskIDs: taskIDs(in: tasks, states: [.running]),
            completedTaskIDs: taskIDs(in: tasks, states: [.completed]),
            failedTaskIDs: taskIDs(in: tasks, states: [.failed, .cancelled]),
            blockedTaskIDs: taskIDs(in: tasks, states: [.blocked]),
            unresolvedEvidenceGapSHA256: gapProjection.unresolvedGapFrontierSHA256,
            modelReceiptIDs: basis.checkpoint.modelReceiptIDs
                + modelReceipts.map(\.receiptID),
            toolReceiptIDs: basis.checkpoint.toolReceiptIDs
                + toolReceipts.map(\.receiptID),
            coordinatorState: coordinatorState,
            terminalReason: terminalReason
        )
        guard checkpoint.canonicalEncodedByteCount <= basis.job.budget.maxEncodedBytes else {
            throw ReconstructionProductionReceiptPlanAuthorError.budgetExceeded
        }
        return ReconstructionJobCommitPlan(
            successorRevision: successorRevision,
            acceptedEvidenceCount: evidence.count,
            disposition: disposition,
            mutation: ReconstructionCheckpointMutation(
                jobID: basis.job.jobID,
                expectedParentCheckpointID: basis.checkpoint.checkpointID,
                expectedParentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
                expectedParentRevision: basis.checkpoint.revision,
                evidence: evidence.sorted {
                    $0.evidenceID.uuidString.lowercased()
                        < $1.evidenceID.uuidString.lowercased()
                },
                evidenceRelations: evidenceRelations.sorted {
                    $0.relationID.uuidString.lowercased()
                        < $1.relationID.uuidString.lowercased()
                },
                evidenceGaps: evidenceGaps.sorted {
                    $0.gapID.uuidString.lowercased() < $1.gapID.uuidString.lowercased()
                },
                toolReceipts: toolReceipts.sorted {
                    $0.receiptID.uuidString.lowercased()
                        < $1.receiptID.uuidString.lowercased()
                },
                modelReceipts: modelReceipts.sorted {
                    $0.receiptID.uuidString.lowercased()
                        < $1.receiptID.uuidString.lowercased()
                },
                finalResults: finalResults.sorted {
                    $0.resultID.uuidString.lowercased()
                        < $1.resultID.uuidString.lowercased()
                },
                newTasks: newTasks,
                taskTransitions: transitions,
                freshnessAuthority: freshnessAuthority,
                successorCheckpoint: checkpoint,
                successorPauseContext: successorPauseContext,
                analysisImports: analysisImports
            )
        )
    }

    func successorRevision(
        for basis: ReconstructionProductionRoundBasis
    ) throws -> UInt64 {
        let (successor, overflow) = basis.checkpoint.revision.addingReportingOverflow(1)
        guard !overflow else {
            throw ReconstructionProductionReceiptPlanAuthorError.budgetExceeded
        }
        return successor
    }

    func applying(
        _ transitions: [ReconstructionTaskTransition],
        to tasks: [ReconstructionTaskRecord]
    ) throws -> [ReconstructionTaskRecord] {
        let byID = try uniqueTasks(tasks)
        var transitionByID: [UUID: ReconstructionTaskTransition] = [:]
        for transition in transitions {
            guard transitionByID.updateValue(transition, forKey: transition.taskID) == nil,
                  byID[transition.taskID]?.state == transition.expectedState,
                  transition.expectedState != transition.successorState else {
                throw ReconstructionProductionReceiptPlanAuthorError.invalidTaskFrontier
            }
        }
        return tasks.map { task in
            guard let transition = transitionByID[task.identity.taskID] else { return task }
            return ReconstructionTaskRecord(
                identity: task.identity,
                state: transition.successorState,
                diagnostic: transition.diagnostic,
                decompileBackend: transition.decompileBackend
            )
        }
    }

    func terminalTransitions(
        in tasks: [ReconstructionTaskRecord],
        to state: ReconstructionTaskState
    ) -> [ReconstructionTaskTransition] {
        tasks.compactMap { task in
            guard task.state == .pending || task.state == .running else { return nil }
            return ReconstructionTaskTransition(
                taskID: task.identity.taskID,
                expectedState: task.state,
                successorState: state,
                diagnostic: nil
            )
        }
    }

    func taskIDs(
        in tasks: [ReconstructionTaskRecord],
        states: Set<ReconstructionTaskState>
    ) -> [UUID] {
        tasks.compactMap { states.contains($0.state) ? $0.identity.taskID : nil }
    }

    func durableOperation(
        for kind: ReconstructionTaskKind
    ) -> ReconstructionOperationID? {
        switch kind {
        case .ingest, .classify: .corpusArtifactDescribe
        case .discoverRelations: .corpusRelationsPage
        case .loadBinary, .indexImage: .imagesPage
        case .enumerateFunctions: .functionsPage
        case .decompileNative: .decompilerNative
        case .decompileMacScope: .decompilerMacScope
        case .compareDecompilers: .decompilerCompare
        case .retrieveEvidence: .evidenceQuery
        case .modelRound, .checkpoint, .executeSource: nil
        }
    }

    func shouldPersistEvidence(
        for kind: ReconstructionTaskKind,
        outcome: ReconstructionTerminalTaskOutcome
    ) -> Bool {
        // A terminal failure/cancellation has receipt and task-transition authority, but no
        // successful semantic payload. The evidence acceptor classifies every accepted candidate
        // as current evidence, so manufacturing a diagnostic payload here would falsely promote
        // failure into analysis truth. A durable gap needs its own explicit policy and identity.
        guard outcome == .completed else { return false }
        // Native structured results remain transient by product contract. Their canonical receipt
        // is durable, but the result bytes cannot enter workspace authority.
        return kind != .decompileNative && kind != .compareDecompilers
    }

    func receiptState(
        for outcome: ReconstructionTerminalTaskOutcome
    ) -> ReconstructionReceiptTerminalState {
        switch outcome {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .staleAuthority: .failed
        }
    }

    func diagnostic(
        for outcome: ReconstructionTerminalTaskOutcome
    ) -> ReconstructionDiagnostic? {
        switch outcome {
        case .completed: nil
        case .failed: .sanitizing("The deterministic reconstruction task failed.")
        case .cancelled: .sanitizing("The deterministic reconstruction task was cancelled.")
        case .staleAuthority: .sanitizing("The deterministic reconstruction authority was stale.")
        }
    }

    func completedNativeSuccess(
        _ result: ReconstructionNativeTaskResult?
    ) -> ReconstructionNativeTaskSuccess? {
        guard case .completed(let success)? = result else { return nil }
        return success
    }

    func deterministicCheckpointID(
        jobID: UUID,
        parentCheckpointID: UUID,
        successorRevision: UInt64
    ) -> UUID {
        var data = Data(Self.checkpointIdentityDomain.utf8)
        data.append(0)
        data.append(contentsOf: jobID.uuidString.lowercased().utf8)
        data.append(0)
        data.append(contentsOf: parentCheckpointID.uuidString.lowercased().utf8)
        data.append(0)
        var revision = successorRevision.bigEndian
        withUnsafeBytes(of: &revision) { data.append(contentsOf: $0) }
        return uuid(from: data)
    }

    func nameDerivedUUID<Value: Encodable>(
        domain: String,
        value: Value
    ) throws -> UUID {
        var data = Data(domain.utf8)
        data.append(0)
        data.append(try ReconstructionCanonicalJSON.encode(value))
        return uuid(from: data)
    }

    func uuid(from data: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension ReconstructionTerminalTaskOutcome {
    var durableName: String {
        switch self {
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .staleAuthority: "stale-authority"
        }
    }
}

/// Internal so tests exercise the exact final-synthesis citation guard used by production.
extension ReconstructionProductionReceiptPlanAuthor {
    func finalCandidateIsValid(
        _ candidate: ReconstructionFinalSynthesisCandidate,
        for request: ReconstructionFinalSynthesisRequest
    ) -> Bool {
        let evidenceIDs = candidate.evidenceIDs
        guard evidenceIDs.count <= 4_096,
              Set(evidenceIDs).count == evidenceIDs.count,
              evidenceIDs == ReconstructionValidation.sortedUUIDs(evidenceIDs),
              Set(evidenceIDs).isSubset(of: Set(request.acceptedEvidenceIDs)) else {
            return false
        }
        switch candidate.kind {
        case .synthesis:
            return !evidenceIDs.isEmpty && (1...60_000).contains(candidate.text.utf8.count)
        case .insufficientEvidence:
            return evidenceIDs.isEmpty && (1...4_096).contains(candidate.text.utf8.count)
        }
    }
}
