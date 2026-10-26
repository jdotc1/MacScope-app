import Foundation

/// Historical diagnostics for one authored round, never an execution capability or a claim that
/// the evidence remains current after this round. Nothing in this carrier is persisted.
struct ReconstructionProductionObservationDiagnostic: Sendable {
    struct Binding: Equatable, Sendable {
        let workspaceID: UUID
        let projectID: UUID
        let jobID: UUID
        let roundID: UUID
        let parentCheckpointID: UUID
        let parentCheckpointSHA256: String
        let parentCheckpointRevision: UInt64
        let corpusManifestSHA256: String
        let inputEvidenceFrontierSHA256: String
        let successorCheckpointID: UUID
        let successorCheckpointSHA256: String
        let successorCheckpointRevision: UInt64
        let successorEvidenceFrontierSHA256: String
        let scopeSHA256: String
        let sourceEvidenceID: UUID
        let oracleEvidenceID: UUID
        let evaluationEvidenceID: UUID
    }

    enum Unavailable: Equatable, Sendable {
        case differentRound
        case invalidRoundBinding
        case invalidFinalCheckpoint
        case missingEvaluation
        case foreignSourceOrOracle
        case staleScope([UUID])
        case invalidScope
        case evidenceValidation(String)
        case adaptation(ReconstructionObservationAdapterError)
        case comparison(ReconstructionObservationComparator.Failure)
    }

    enum Result: Sendable {
        case compared(original: ReconstructionObservationSet, candidate: ReconstructionObservationSet,
                      comparison: ReconstructionObservationComparison)
        case unavailable(Unavailable)
    }

    let binding: Binding
    private let projected: Result

    fileprivate init(binding: Binding, result: Result) {
        self.binding = binding
        self.projected = result
    }

    /// A consumer must name the complete originating round. Matching only a job or profile is
    /// insufficient; a retained result must not be presented as the result of a successor round.
    func result(for originatingRound: Binding) -> Result {
        guard originatingRound == binding else { return .unavailable(.differentRound) }
        return projected
    }
}

/// Called by the receipt author only after its final checkpoint rebuild equality check. The
/// independent evaluation context comes from the typed terminal outcome, not the record payload.
/// Refusals are diagnostics only: the existing evidence owner retains every acceptance decision.
enum ReconstructionProductionObservationProjection {
    static func project(
        basis: ReconstructionProductionRoundBasis,
        cut: ReconstructionProductionCommittedRoundCut,
        plan: ReconstructionJobCommitPlan,
        evaluationEvidenceID: UUID,
        context: ReconstructionSourceEvaluationEvidence.Context
    ) -> ReconstructionProductionObservationDiagnostic? {
        guard let scope = basis.job.featureScope else { return nil }
        let checkpoint = plan.mutation?.successorCheckpoint ?? context.checkpoint
        let binding = ReconstructionProductionObservationDiagnostic.Binding(
            workspaceID: basis.workspaceID, projectID: basis.project.projectID, jobID: basis.job.jobID,
            roundID: cut.prepared.roundID, parentCheckpointID: basis.checkpoint.checkpointID,
            parentCheckpointSHA256: basis.checkpoint.canonicalSHA256,
            parentCheckpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            inputEvidenceFrontierSHA256: basis.evidenceCut.frontierSHA256,
            successorCheckpointID: checkpoint.checkpointID, successorCheckpointSHA256: checkpoint.canonicalSHA256,
            successorCheckpointRevision: checkpoint.revision,
            successorEvidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
            scopeSHA256: scope.canonicalSHA256, sourceEvidenceID: context.sourceRecord.evidenceID,
            oracleEvidenceID: context.oracleRecord.evidenceID, evaluationEvidenceID: evaluationEvidenceID)
        func unavailable(_ reason: ReconstructionProductionObservationDiagnostic.Unavailable)
            -> ReconstructionProductionObservationDiagnostic {
            .init(binding: binding, result: .unavailable(reason))
        }
        guard cut.snapshot == basis.snapshot,
              cut.parentCheckpointID == basis.checkpoint.checkpointID,
              cut.parentCheckpointSHA256 == basis.checkpoint.canonicalSHA256,
              cut.prepared.evidenceCut == basis.evidenceCut,
              cut.prepared.authority.jobID == basis.job.jobID,
              cut.prepared.authority.roundID == cut.prepared.roundID,
              cut.prepared.authority.checkpointRevision == basis.checkpoint.revision,
              cut.prepared.authority.corpusManifestSHA256 == basis.manifest.canonicalSHA256,
              cut.prepared.authority.evidenceFrontierSHA256 == basis.evidenceCut.frontierSHA256 else {
            return unavailable(.invalidRoundBinding)
        }
        guard let mutation = plan.mutation, mutation.jobID == basis.job.jobID,
              mutation.expectedParentCheckpointID == basis.checkpoint.checkpointID,
              mutation.expectedParentCheckpointSHA256 == basis.checkpoint.canonicalSHA256,
              mutation.expectedParentRevision == basis.checkpoint.revision,
              checkpoint == context.checkpoint, checkpoint.jobID == basis.job.jobID,
              checkpoint.parentCheckpointID == basis.checkpoint.checkpointID,
              checkpoint.parentCheckpointSHA256 == basis.checkpoint.canonicalSHA256,
              checkpoint.revision > basis.checkpoint.revision,
              checkpoint.revision == plan.successorRevision,
              checkpoint.corpusManifestSHA256 == basis.manifest.canonicalSHA256 else {
            return unavailable(.invalidFinalCheckpoint)
        }
        let evaluations = mutation.evidence.filter { $0.evidenceID == evaluationEvidenceID }
        guard evaluations.count == 1, let record = evaluations.first,
              record.creatingCheckpointID == checkpoint.checkpointID else { return unavailable(.missingEvaluation) }
        guard basis.evidenceCut.records.contains(context.sourceRecord),
              basis.evidenceCut.records.contains(context.oracleRecord),
              context.sourceRecord.creatingJobID == basis.job.jobID,
              context.oracleRecord.creatingJobID == basis.job.jobID,
              basis.evidenceCut.projectedClassificationsByEvidenceID[context.sourceRecord.evidenceID] == .acceptedCurrent,
              basis.evidenceCut.projectedClassificationsByEvidenceID[context.oracleRecord.evidenceID] == .acceptedCurrent else {
            return unavailable(.foreignSourceOrOracle)
        }
        guard scope.projectID == basis.project.projectID, scope.jobID == basis.job.jobID,
              scope.feature == context.sourceContext.admissionAuthority.function else {
            return unavailable(.invalidScope)
        }
        let currency = ReconstructionFeatureScopeCurrency.of(scope,
            classifications: basis.evidenceCut.projectedClassificationsByEvidenceID)
        if case .stale(let ids) = currency { return unavailable(.staleScope(ids)) }
        do {
            // Reconstruct the exact final evidence against independently captured outcome and
            // owner contexts. Never derive expectedCapturedOutcome by decoding this payload.
            let evaluation = try ReconstructionSourceEvaluationEvidence.validate(record: record, context: context)
            let oracle = try ReconstructionSourceOracleEvidence.validate(record: context.oracleRecord,
                context: context.oracleContext)
            let original = try ReconstructionObservationAdapter.original(oracle,
                evidenceID: context.oracleRecord.evidenceID, contract: scope.observationContract)
            let candidate = try ReconstructionObservationAdapter.candidate(evaluation,
                evidenceID: evaluationEvidenceID, original: original, contract: scope.observationContract)
            let comparison = try ReconstructionObservationComparator.compare(scope: scope, currency: currency,
                original: original, candidate: candidate)
            return .init(binding: binding, result: .compared(original: original, candidate: candidate, comparison: comparison))
        } catch let error as ReconstructionObservationAdapterError {
            return unavailable(.adaptation(error))
        } catch let error as ReconstructionObservationComparator.Failure {
            return unavailable(.comparison(error))
        } catch {
            return unavailable(.evidenceValidation(String(String(describing: error).prefix(1_024))))
        }
    }
}
