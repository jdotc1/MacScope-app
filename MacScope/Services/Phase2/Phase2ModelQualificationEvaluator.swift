import Foundation

struct Phase2ModelQualificationEvaluation: Hashable, Sendable {
    let verdict: Phase2ModelQualificationVerdict
    let declaredTrialCount: Int
    let observedTrialCount: Int
    let observedAttemptCount: Int
    let passedTrialCount: Int
    let failedTrialCount: Int
    let passedAttemptCount: Int
    let failedAttemptCount: Int
    let failedProbeIDs: [String]
    let missingTrialIDs: [String]
    let inconclusiveReasonCodes: [String]
    let orderedObservations: [Phase2QualificationProbeObservation]
}

/// Sole app-owned qualification judgment. It consumes only validated values and never performs
/// I/O, retries, fallback, provider selection, or capability inference.
struct Phase2ModelQualificationEvaluator: Sendable {
    func evaluate(
        profile: Phase2ModelProfile,
        policy: Phase2ModelQualificationPolicy,
        run: Phase2ModelQualificationRun,
        context: Phase2ModelQualificationEvaluationContext
    ) throws -> Phase2ModelQualificationEvaluation {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let expectedPolicyIdentity = try canonicalizer.qualificationPolicyIdentity(for: policy)
        let qualificationVersionsMatch = run.version == policy.version
            && profile.protocolManifest.version == policy.version
            && run.policyIdentity.version == policy.version
            && profile.protocolManifest.qualificationPolicy.version == policy.version
        let structure = structuralAnalysis(
            policy: policy,
            observations: run.observations,
            enforceVersionSpecificRules: qualificationVersionsMatch
        )
        var bindingReasons: [String] = []
        if run.profileID != (try canonicalizer.stableID(for: profile)) {
            bindingReasons.append("profile-identity-mismatch")
        }
        if qualificationVersionsMatch,
           (run.policyIdentity != expectedPolicyIdentity
            || expectedPolicyIdentity != profile.protocolManifest.qualificationPolicy) {
            bindingReasons.append("qualification-policy-mismatch")
        }
        if run.protocolManifestDigest
            != canonicalizer.protocolManifestDigest(for: profile.protocolManifest) {
            bindingReasons.append("protocol-manifest-mismatch")
        }
        if !qualificationVersionsMatch {
            bindingReasons.append("qualification-version-mismatch")
        } else if policy.version == 1 {
            if run.corpusDigest != policy.corpusDigest {
                bindingReasons.append("corpus-digest-mismatch")
            }
        } else {
            if run.protocolProbeCatalogIdentity != policy.protocolProbeCatalog
                || profile.protocolManifest.protocolProbeCatalog != policy.protocolProbeCatalog {
                bindingReasons.append("protocol-probe-catalog-mismatch")
            }
            if run.liveQualificationCorpusIdentity != policy.liveQualificationCorpus
                || profile.protocolManifest.liveQualificationCorpus
                    != policy.liveQualificationCorpus {
                bindingReasons.append("live-qualification-corpus-mismatch")
            }
            if run.metricSemanticsIdentity != policy.metricSemantics {
                bindingReasons.append("metric-semantics-mismatch")
            }
            if let expected = context.evidenceExpectations {
                if run.environmentIdentity != expected.environmentIdentity {
                    bindingReasons.append("environment-identity-mismatch")
                }
                if run.runtimeProvenanceIdentity != expected.runtimeProvenanceIdentity {
                    bindingReasons.append("runtime-provenance-identity-mismatch")
                }
                if run.measurementEvidenceIdentity != expected.measurementEvidenceIdentity {
                    bindingReasons.append("measurement-evidence-identity-mismatch")
                }
            } else {
                bindingReasons.append("qualification-evidence-expectations-missing")
            }
        }
        if run.hardwareTier != profile.hardwareTier {
            bindingReasons.append("hardware-tier-mismatch")
        }
        if run.macScopeBuild != context.macScopeBuild {
            bindingReasons.append("macscope-build-mismatch")
        }
        if run.toolchainBuild != context.toolchainBuild {
            bindingReasons.append("toolchain-build-mismatch")
        }
        if run.operatingSystemBuild != context.operatingSystemBuild {
            bindingReasons.append("operating-system-build-mismatch")
        }
        if run.architecture != context.architecture {
            bindingReasons.append("architecture-mismatch")
        }
        let maximumEvidenceAge = policy.maximumEvidenceAgeMilliseconds.map {
            min($0, context.maximumEvidenceAgeMilliseconds)
        } ?? context.maximumEvidenceAgeMilliseconds
        let (candidateOldestEnd, ageUnderflow) = context.evaluatedAtEpochMilliseconds
            .subtractingReportingOverflow(maximumEvidenceAge)
        let oldestPermittedEnd = ageUnderflow ? 0 : candidateOldestEnd
        if run.endedAtEpochMilliseconds < oldestPermittedEnd
            || run.endedAtEpochMilliseconds > context.evaluatedAtEpochMilliseconds {
            bindingReasons.append("stale-evidence")
        }
        if !profile.protocolManifest.isCertificationEligible {
            bindingReasons.append("protocol-artifact-unavailable")
        }
        switch run.terminationStatus {
        case .completed:
            break
        case .cancelled:
            bindingReasons.append("run-cancelled")
        case .failed:
            bindingReasons.append("run-failed")
        }
        let requiredMeasurements = Set(policy.requirements.flatMap(\.requiredMeasurements))
        if policy.version == 1,
           !requiredMeasurements.isSubset(of: run.measurements.availableKinds) {
            bindingReasons.append("required-measurement-missing")
        }
        let numericAnalysis = numericAnalysis(
            policy: policy,
            runVersion: run.version,
            observations: structure.ordered,
            runMeasurements: run.measurements,
            attemptMeasurements: run.attemptMeasurements
        )
        let allInconclusiveReasons = bindingReasons + structure.reasons + numericAnalysis.reasons
        if !allInconclusiveReasons.isEmpty {
            return summarize(
                verdict: .inconclusive,
                policy: policy,
                observations: numericAnalysis.observations,
                missing: structure.missing,
                reasons: allInconclusiveReasons
            )
        }

        let requirements = Dictionary(uniqueKeysWithValues: policy.requirements.map {
            ($0.probeID, $0)
        })
        let failed = numericAnalysis.observations.filter { $0.outcome == .failed }
        let severities = failed.compactMap { requirements[$0.probeID]?.severity }
        let verdict: Phase2ModelQualificationVerdict
        if severities.contains(.hard) {
            verdict = .unsupported
        } else if severities.contains(.core) {
            verdict = .experimental
        } else if severities.contains(.quality) {
            verdict = .compatible
        } else {
            verdict = .certified
        }
        return summarize(
            verdict: verdict,
            policy: policy,
            observations: numericAnalysis.observations,
            missing: [],
            reasons: []
        )
    }

    private struct StructuralAnalysis {
        let ordered: [Phase2QualificationProbeObservation]
        let missing: [String]
        let reasons: [String]
    }

    private func structuralAnalysis(
        policy: Phase2ModelQualificationPolicy,
        observations: [Phase2QualificationProbeObservation],
        enforceVersionSpecificRules: Bool
    ) -> StructuralAnalysis {
        let requirements = Dictionary(uniqueKeysWithValues: policy.requirements.map {
            ($0.probeID, $0)
        })
        var seenAttempts: Set<String> = []
        var seenTrials: Set<String> = []
        var attemptsByTrial: [String: Set<Int>] = [:]
        var reasons: [String] = []
        for observation in observations {
            guard let requirement = requirements[observation.probeID] else {
                reasons.append("unknown-trial")
                continue
            }
            if observation.trial > requirement.requiredTrialCount {
                reasons.append("out-of-range-trial")
            } else {
                seenTrials.insert(observation.trialID)
                attemptsByTrial[observation.trialID, default: []].insert(observation.attempt)
            }
            if !seenAttempts.insert(observation.attemptID).inserted {
                reasons.append("duplicate-attempt")
            }
            if enforceVersionSpecificRules, policy.version == 2, observation.attempt != 1 {
                reasons.append("retry-forbidden")
            }
            if enforceVersionSpecificRules, policy.version == 2,
               [.passed, .failed].contains(observation.outcome),
               observation.evidenceDigest == nil {
                reasons.append("required-evidence-missing")
            }
            if enforceVersionSpecificRules, policy.version == 2,
               [.unavailable, .cancelled, .notRun].contains(observation.outcome),
               observation.reasonCode == nil {
                reasons.append("required-reason-missing")
            }
            if enforceVersionSpecificRules, policy.version == 2,
               [.unavailable, .cancelled, .notRun].contains(observation.outcome),
               observation.evidenceDigest != nil {
                reasons.append("unexpected-evidence")
            }
        }
        let expectedTrialIDs = policy.requirements.flatMap { requirement in
            (1...requirement.requiredTrialCount).map { "\(requirement.probeID)#\($0)" }
        }
        let missing = expectedTrialIDs.filter { !seenTrials.contains($0) }
        if !missing.isEmpty { reasons.append("missing-trial") }
        if enforceVersionSpecificRules,
           policy.version == 1,
           attemptsByTrial.values.contains(where: { attempts in
            guard let maximumAttempt = attempts.max() else { return false }
            return attempts != Set(1...maximumAttempt)
        }) {
            reasons.append("missing-attempt")
        }
        let ordered = observations.sorted(by: observationOrder(policy: policy))
        if ordered.contains(where: { $0.outcome == .notRun }) { reasons.append("not-run") }
        if ordered.contains(where: { $0.outcome == .unavailable }) { reasons.append("unavailable") }
        if ordered.contains(where: { $0.outcome == .cancelled }) { reasons.append("cancelled") }
        return .init(ordered: ordered, missing: missing, reasons: reasons)
    }

    private struct NumericAnalysis {
        let observations: [Phase2QualificationProbeObservation]
        let reasons: [String]
    }

    private func numericAnalysis(
        policy: Phase2ModelQualificationPolicy,
        runVersion: Int,
        observations: [Phase2QualificationProbeObservation],
        runMeasurements: Phase2QualificationMeasurements,
        attemptMeasurements: [Phase2QualificationAttemptMeasurements]
    ) -> NumericAnalysis {
        guard policy.version == 2, runVersion == 2 else {
            return .init(observations: observations, reasons: [])
        }
        let requirements = Dictionary(uniqueKeysWithValues: policy.requirements.map {
            ($0.probeID, $0)
        })
        var measurementsByAttempt: [String: Phase2QualificationMeasurements] = [:]
        var reasons: [String] = []
        for sample in attemptMeasurements {
            if measurementsByAttempt.updateValue(
                sample.measurements,
                forKey: sample.attemptID
            ) != nil {
                reasons.append("duplicate-attempt-measurement")
            }
        }
        let allowedAttemptMeasurementIDs: Set<String> = Set(observations.compactMap {
            observation -> String? in
            guard observation.outcome != .notRun,
                  let requirement = requirements[observation.probeID],
                  requirement.executionKind == .liveProvider
            else { return nil }
            return observation.attemptID
        })
        let requiredAttemptMeasurementIDs: Set<String> = Set(observations.compactMap {
            observation -> String? in
            guard observation.outcome == .passed,
                  let requirement = requirements[observation.probeID],
                  requirement.executionKind == .liveProvider
            else { return nil }
            return observation.attemptID
        })
        let actualAttemptMeasurementIDs = Set(attemptMeasurements.map(\.attemptID))
        if !actualAttemptMeasurementIDs.subtracting(allowedAttemptMeasurementIDs).isEmpty {
            reasons.append("unknown-attempt-measurement")
        }
        if !requiredAttemptMeasurementIDs.subtracting(actualAttemptMeasurementIDs).isEmpty {
            reasons.append("required-attempt-measurement-missing")
        }
        let observationsByAttempt = Dictionary(grouping: observations, by: \.attemptID)
        for sample in attemptMeasurements {
            guard let observation = observationsByAttempt[sample.attemptID]?.first,
                  let requirement = requirements[observation.probeID],
                  requirement.executionKind == .liveProvider,
                  observation.outcome != .notRun
            else { continue }
            let expectedKinds: Set<Phase2QualificationMeasurementKind>
            if [.passed, .failed].contains(observation.outcome) {
                expectedKinds = Set(requirement.numericRules.compactMap { rule in
                    rule.scope == .perAttempt ? rule.measurement : nil
                })
            } else {
                expectedKinds = []
            }
            if observation.outcome == .passed,
               !expectedKinds.subtracting(sample.measurements.availableKinds).isEmpty {
                reasons.append("required-attempt-measurement-missing")
            }
        }
        let evaluated = observations.map { observation -> Phase2QualificationProbeObservation in
            guard let requirement = requirements[observation.probeID],
                  !requirement.numericRules.isEmpty,
                  observation.outcome == .passed
            else { return observation }
            var values: [(Phase2QualificationNumericRule, Int64)] = []
            for rule in requirement.numericRules {
                let value: Int64?
                switch rule.scope {
                case .perAttempt:
                    value = measurementsByAttempt[observation.attemptID]?.value(
                        for: rule.measurement
                    )
                    if value == nil {
                        reasons.append("required-attempt-measurement-missing")
                    }
                case .runAggregate:
                    value = runMeasurements.value(for: rule.measurement)
                    if value == nil {
                        reasons.append("required-run-measurement-missing")
                    }
                }
                guard let value else { continue }
                values.append((rule, value))
            }
            guard values.count == requirement.numericRules.count else {
                return observation
            }
            let passes = values.allSatisfy { $0.0.accepts($0.1) }
            guard observation.outcome == .passed, !passes else { return observation }
            return try! .init(
                probeID: observation.probeID,
                trial: observation.trial,
                attempt: observation.attempt,
                outcome: .failed,
                reasonCode: "numeric-threshold-failed",
                evidenceDigest: observation.evidenceDigest
            )
        }
        return .init(observations: evaluated, reasons: reasons)
    }

    private func summarize(
        verdict: Phase2ModelQualificationVerdict,
        policy: Phase2ModelQualificationPolicy,
        observations: [Phase2QualificationProbeObservation],
        missing: [String],
        reasons: [String]
    ) -> Phase2ModelQualificationEvaluation {
        let requirements = Dictionary(uniqueKeysWithValues: policy.requirements.map {
            ($0.probeID, $0)
        })
        let validObservations = observations.filter { observation in
            guard let requirement = requirements[observation.probeID] else { return false }
            return observation.trial <= requirement.requiredTrialCount
        }
        let observationsByTrial = Dictionary(grouping: validObservations, by: \.trialID)
        let passedTrials = observationsByTrial.values.count { attempts in
            !attempts.isEmpty && attempts.allSatisfy { $0.outcome == .passed }
        }
        let failedTrials = observationsByTrial.values.count { attempts in
            attempts.contains { $0.outcome == .failed }
        }
        let failedProbeIDs = Array(Set(
            observations.filter { $0.outcome == .failed }.map(\.probeID)
        )).sorted(by: phase2UnicodeScalarOrder)
        return .init(
            verdict: verdict,
            declaredTrialCount: policy.declaredTrialCount,
            observedTrialCount: observationsByTrial.count,
            observedAttemptCount: observations.count,
            passedTrialCount: passedTrials,
            failedTrialCount: failedTrials,
            passedAttemptCount: observations.count { $0.outcome == .passed },
            failedAttemptCount: observations.count { $0.outcome == .failed },
            failedProbeIDs: failedProbeIDs,
            missingTrialIDs: missing,
            inconclusiveReasonCodes: Array(Set(reasons)).sorted(by: phase2UnicodeScalarOrder),
            orderedObservations: observations
        )
    }

    private func observationOrder(
        policy: Phase2ModelQualificationPolicy
    ) -> (Phase2QualificationProbeObservation, Phase2QualificationProbeObservation) -> Bool {
        let order = Dictionary(uniqueKeysWithValues: policy.requirements.enumerated().map {
            ($0.element.probeID, $0.offset)
        })
        return { lhs, rhs in
            let lhsOrder = order[lhs.probeID] ?? Int.max
            let rhsOrder = order[rhs.probeID] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            if lhs.probeID != rhs.probeID {
                return phase2UnicodeScalarOrder(lhs.probeID, rhs.probeID)
            }
            if lhs.trial != rhs.trial { return lhs.trial < rhs.trial }
            if lhs.attempt != rhs.attempt { return lhs.attempt < rhs.attempt }
            if lhs.outcome.rawValue != rhs.outcome.rawValue {
                return lhs.outcome.rawValue < rhs.outcome.rawValue
            }
            let lhsReason = lhs.reasonCode ?? ""
            let rhsReason = rhs.reasonCode ?? ""
            if lhsReason != rhsReason { return phase2UnicodeScalarOrder(lhsReason, rhsReason) }
            return phase2UnicodeScalarOrder(
                lhs.evidenceDigest ?? "",
                rhs.evidenceDigest ?? ""
            )
        }
    }
}
