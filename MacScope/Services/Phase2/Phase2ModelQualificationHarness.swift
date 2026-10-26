import CryptoKit
import Foundation
@testable import MacScope

/// Pure finite adapter that turns one injected run into one content-addressed report.
struct Phase2ModelQualificationHarness: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case reportEncodingFailed
    }

    func evaluate(
        profile: Phase2ModelProfile,
        policy: Phase2ModelQualificationPolicy,
        run: Phase2ModelQualificationRun?,
        context: Phase2ModelQualificationEvaluationContext
    ) throws -> Phase2ModelQualificationReport? {
        guard let run else { return nil }
        let evaluation = try Phase2ModelQualificationEvaluator().evaluate(
            profile: profile,
            policy: policy,
            run: run,
            context: context
        )
        let reportContext: Phase2ModelQualificationEvaluationContext
        if run.version == 1 {
            reportContext = try .init(
                macScopeBuild: context.macScopeBuild,
                toolchainBuild: context.toolchainBuild,
                operatingSystemBuild: context.operatingSystemBuild,
                architecture: context.architecture,
                evaluatedAtEpochMilliseconds: context.evaluatedAtEpochMilliseconds,
                maximumEvidenceAgeMilliseconds: context.maximumEvidenceAgeMilliseconds
            )
        } else {
            reportContext = context
        }
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let expectedProfileID = try canonicalizer.stableID(for: profile)
        let expectedPolicyIdentity = try canonicalizer.qualificationPolicyIdentity(for: policy)
        let reportBytes = try canonicalReportBytes(
            profile: profile,
            policy: policy,
            run: run,
            context: reportContext,
            evaluation: evaluation
        )
        let reportID = try Phase2ModelQualificationReportID(
            rawValue: "sha256:\(digest(reportBytes))"
        )
        let retryAttemptCount = retryAttemptCount(in: evaluation.orderedObservations)
        let orderedAttemptMeasurements = run.attemptMeasurements.sorted {
            phase2UnicodeScalarOrder($0.attemptID, $1.attemptID)
        }
        return .init(
            version: run.version,
            reportID: reportID,
            expectedProfileID: expectedProfileID,
            claimedProfileID: run.profileID,
            expectedPolicyIdentity: expectedPolicyIdentity,
            claimedPolicyIdentity: run.policyIdentity,
            evaluationContext: reportContext,
            protocolManifestDigest: run.protocolManifestDigest,
            corpusDigest: run.corpusDigest,
            protocolProbeCatalogIdentity: run.protocolProbeCatalogIdentity,
            liveQualificationCorpusIdentity: run.liveQualificationCorpusIdentity,
            metricSemanticsIdentity: run.metricSemanticsIdentity,
            modelSource: run.modelSource,
            modelRevisionIdentity: run.modelRevisionIdentity,
            productionDefinitionIdentity: run.productionDefinitionIdentity,
            environmentIdentity: run.environmentIdentity,
            runtimeProvenanceIdentity: run.runtimeProvenanceIdentity,
            measurementEvidenceIdentity: run.measurementEvidenceIdentity,
            workflow: profile.workflow,
            authorityCeiling: profile.authorityCeiling,
            hardwareTier: run.hardwareTier,
            macScopeBuild: run.macScopeBuild,
            toolchainBuild: run.toolchainBuild,
            operatingSystemBuild: run.operatingSystemBuild,
            architecture: run.architecture,
            startedAtEpochMilliseconds: run.startedAtEpochMilliseconds,
            endedAtEpochMilliseconds: run.endedAtEpochMilliseconds,
            terminationStatus: run.terminationStatus,
            measurements: run.measurements,
            attemptMeasurements: orderedAttemptMeasurements,
            retryAttemptCount: retryAttemptCount,
            verdict: evaluation.verdict,
            declaredTrialCount: evaluation.declaredTrialCount,
            observedTrialCount: evaluation.observedTrialCount,
            observedAttemptCount: evaluation.observedAttemptCount,
            passedTrialCount: evaluation.passedTrialCount,
            failedTrialCount: evaluation.failedTrialCount,
            passedAttemptCount: evaluation.passedAttemptCount,
            failedAttemptCount: evaluation.failedAttemptCount,
            failedProbeIDs: evaluation.failedProbeIDs,
            missingTrialIDs: evaluation.missingTrialIDs,
            inconclusiveReasonCodes: evaluation.inconclusiveReasonCodes,
            observations: evaluation.orderedObservations
        )
    }

    private func canonicalReportBytes(
        profile: Phase2ModelProfile,
        policy: Phase2ModelQualificationPolicy,
        run: Phase2ModelQualificationRun,
        context: Phase2ModelQualificationEvaluationContext,
        evaluation: Phase2ModelQualificationEvaluation
    ) throws -> Data {
        var object: [String: Any] = [
            "architecture": run.architecture,
            "authority_ceiling": profile.authorityCeiling.rawValue,
            "corpus_digest": run.corpusDigest,
            "declared_trial_count": evaluation.declaredTrialCount,
            "ended_at_epoch_milliseconds": run.endedAtEpochMilliseconds,
            "evaluation_context": [
                "architecture": context.architecture,
                "evaluated_at_epoch_milliseconds": context.evaluatedAtEpochMilliseconds,
                "macscope_build": context.macScopeBuild,
                "maximum_evidence_age_milliseconds": context.maximumEvidenceAgeMilliseconds,
                "operating_system_build": context.operatingSystemBuild,
                "toolchain_build": context.toolchainBuild,
            ],
            "failed_probe_ids": evaluation.failedProbeIDs,
            "failed_attempt_count": evaluation.failedAttemptCount,
            "failed_trial_count": evaluation.failedTrialCount,
            "hardware_tier": [
                "id": run.hardwareTier.id,
                "version": run.hardwareTier.version,
            ],
            "inconclusive_reason_codes": evaluation.inconclusiveReasonCodes,
            "macscope_build": run.macScopeBuild,
            "measurements": measurementObject(run.measurements),
            "missing_trial_ids": evaluation.missingTrialIDs,
            "observations": evaluation.orderedObservations.map(observationObject),
            "observed_attempt_count": evaluation.observedAttemptCount,
            "observed_trial_count": evaluation.observedTrialCount,
            "operating_system_build": run.operatingSystemBuild,
            "passed_trial_count": evaluation.passedTrialCount,
            "passed_attempt_count": evaluation.passedAttemptCount,
            "claimed_policy": componentObject(run.policyIdentity),
            "claimed_profile_id": run.profileID.rawValue,
            "expected_policy": componentObject(
                try Phase2ModelProfileCanonicalizer().qualificationPolicyIdentity(for: policy)
            ),
            "expected_profile_id": try Phase2ModelProfileCanonicalizer()
                .stableID(for: profile).rawValue,
            "protocol_manifest_digest": run.protocolManifestDigest,
            "started_at_epoch_milliseconds": run.startedAtEpochMilliseconds,
            "termination_status": run.terminationStatus.rawValue,
            "toolchain_build": run.toolchainBuild,
            "retry_attempt_count": retryAttemptCount(in: evaluation.orderedObservations),
            "verdict": evaluation.verdict.rawValue,
            "version": run.version,
            "workflow": profile.workflow.rawValue,
        ]
        if run.version == 2 {
            object["environment_identity"] = componentObject(run.environmentIdentity!)
            object["runtime_provenance_identity"] = componentObject(
                run.runtimeProvenanceIdentity!
            )
            object["measurement_evidence_identity"] = componentObject(
                run.measurementEvidenceIdentity!
            )
            object["protocol_probe_catalog"] = componentObject(
                run.protocolProbeCatalogIdentity!
            )
            object["live_qualification_corpus"] = componentObject(
                run.liveQualificationCorpusIdentity!
            )
            object["metric_semantics"] = componentObject(run.metricSemanticsIdentity!)
            object["model_source"] = run.modelSource!
            object["model_revision"] = componentObject(run.modelRevisionIdentity!)
            object["production_qualification_definition"] = componentObject(
                run.productionDefinitionIdentity!
            )
            object["attempt_measurements"] = run.attemptMeasurements.sorted {
                phase2UnicodeScalarOrder($0.attemptID, $1.attemptID)
            }.map(attemptMeasurementObject)
            object["measurements"] = measurementObject(run.measurements, includeV2: true)
            var contextObject: [String: Any] = [
                "architecture": context.architecture,
                "evaluated_at_epoch_milliseconds": context.evaluatedAtEpochMilliseconds,
                "macscope_build": context.macScopeBuild,
                "maximum_evidence_age_milliseconds": context.maximumEvidenceAgeMilliseconds,
                "operating_system_build": context.operatingSystemBuild,
                "toolchain_build": context.toolchainBuild,
            ]
            if let expected = context.evidenceExpectations {
                contextObject["expected_environment_identity"] = componentObject(
                    expected.environmentIdentity
                )
                contextObject["expected_runtime_provenance_identity"] = componentObject(
                    expected.runtimeProvenanceIdentity
                )
                contextObject["expected_measurement_evidence_identity"] = componentObject(
                    expected.measurementEvidenceIdentity
                )
            } else {
                contextObject["expected_environment_identity"] = NSNull()
                contextObject["expected_runtime_provenance_identity"] = NSNull()
                contextObject["expected_measurement_evidence_identity"] = NSNull()
            }
            object["evaluation_context"] = contextObject
        }
        do {
            return try Phase2LengthFramedCanonicalEncoder().encode(object)
        } catch {
            throw Error.reportEncodingFailed
        }
    }

    private func observationObject(
        _ observation: Phase2QualificationProbeObservation
    ) -> [String: Any] {
        [
            "evidence_digest": observation.evidenceDigest.map { $0 as Any } ?? NSNull(),
            "outcome": observation.outcome.rawValue,
            "probe_id": observation.probeID,
            "reason_code": observation.reasonCode.map { $0 as Any } ?? NSNull(),
            "attempt": observation.attempt,
            "trial": observation.trial,
        ]
    }

    private func attemptMeasurementObject(
        _ sample: Phase2QualificationAttemptMeasurements
    ) -> [String: Any] {
        [
            "attempt": sample.attempt,
            "measurements": measurementObject(sample.measurements, includeV2: true),
            "probe_id": sample.probeID,
            "trial": sample.trial,
        ]
    }

    private func measurementObject(
        _ measurements: Phase2QualificationMeasurements,
        includeV2: Bool = false
    ) -> [String: Any] {
        var object: [String: Any] = [
            "generated_token_count": measurements.generatedTokenCount
                .map { $0 as Any } ?? NSNull(),
            "peak_resident_bytes": measurements.peakResidentBytes
                .map { $0 as Any } ?? NSNull(),
            "throughput_millitokens_per_second": measurements.throughputMilliTokensPerSecond
                .map { $0 as Any } ?? NSNull(),
            "total_latency_milliseconds": measurements.totalLatencyMilliseconds
                .map { $0 as Any } ?? NSNull(),
            "variance_basis_points": measurements.varianceBasisPoints
                .map { $0 as Any } ?? NSNull(),
        ]
        if includeV2 {
            object["time_to_first_semantic_event_milliseconds"] =
                measurements.timeToFirstSemanticEventMilliseconds.map { $0 as Any } ?? NSNull()
            object["cancellation_latency_milliseconds"] =
                measurements.cancellationLatencyMilliseconds.map { $0 as Any } ?? NSNull()
        }
        return object
    }

    private func retryAttemptCount(
        in observations: [Phase2QualificationProbeObservation]
    ) -> Int {
        observations.count { $0.attempt > 1 }
    }

    private func componentObject(_ identity: Phase2ProtocolComponentIdentity) -> [String: Any] {
        [
            "availability": identity.availability.rawValue,
            "id": identity.id,
            "sha256": identity.sha256.map { $0 as Any } ?? NSNull(),
            "version": identity.version,
        ]
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map {
            let unpadded = String($0, radix: 16, uppercase: false)
            return String(repeating: "0", count: 2 - unpadded.count) + unpadded
        }.joined()
    }
}
