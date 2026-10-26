import Foundation
import XCTest
@testable import MacScope

final class Phase2ModelQualificationEvaluatorTests: XCTestCase {
    func testStandardEvidenceBundleIncludesGeneratedTokenDependencyForThroughput() throws {
        let standard = Phase2ProductionQualificationPolicy.standard
        let scope = component("qualification-measurement-scope", byte: "8")
        let liveKeys = try standard.liveRequirements.flatMap { requirement in
            try (1...requirement.requiredTrialCount).map { trial in
                try Phase2QualificationTrialKey(
                    requirementID: requirement.probeID,
                    trialIndex: trial,
                    attempt: 1
                )
            }
        }
        let samples = try liveKeys.map {
            try makeStandardEvidenceSample(
                key: $0,
                metricPlan: standard.metricPlan,
                scope: scope
            )
        }

        let bundle = try makeEvidenceBundle(
            policy: standard.policy,
            samples: samples,
            useStandardInitializer: true
        )

        XCTAssertEqual(
            bundle.measurementAggregate.metricPlanIdentity,
            try standard.metricPlan.contentIdentity()
        )
        XCTAssertNotNil(bundle.measurementAggregate.measurements.generatedTokenCount)
        XCTAssertNotNil(
            bundle.measurementAggregate.measurements.throughputMilliTokensPerSecond
        )
        XCTAssertThrowsError(try makeEvidenceBundle(
            policy: standard.policy,
            samples: samples,
            modelSource: "mlx-community/different-model",
            useStandardInitializer: true
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationEvidenceBundle.ValidationError,
                .productionIdentityMismatch
            )
        }
    }

    func testNoRunMeansNotEvaluated() throws {
        XCTAssertNil(try evaluateWithContext(
            profile: makeProfile(),
            policy: makePolicy(),
            run: nil
        ))
    }

    func testCompletePassingDenominatorProducesContentAddressedCertifiedReport() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let run = try makeRun(
            profile: profile,
            policy: policy,
            observations: passingObservations(for: policy)
        )

        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: run
        ))
        XCTAssertEqual(report.verdict, .certified)
        XCTAssertEqual(report.supportStatus, .certified)
        XCTAssertEqual(report.declaredTrialCount, 6)
        XCTAssertEqual(report.observedTrialCount, 6)
        XCTAssertEqual(report.observedAttemptCount, 6)
        XCTAssertEqual(report.passedTrialCount, 6)
        XCTAssertEqual(report.failedTrialCount, 0)
        XCTAssertEqual(report.passedAttemptCount, 6)
        XCTAssertEqual(report.failedAttemptCount, 0)
        XCTAssertEqual(report.reportID, try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: run
        )?.reportID)
        XCTAssertTrue(report.reportID.rawValue.hasPrefix("sha256:"))
    }

    func testMissingDuplicateUnknownAndNotRunTrialsAreInconclusive() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()

        let missing = try makeRun(
            profile: profile,
            policy: policy,
            observations: Array(passingObservations(for: policy).dropLast())
        )
        let missingReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: missing
        ))
        XCTAssertEqual(missingReport.verdict, .inconclusive)
        XCTAssertNil(missingReport.supportStatus)
        XCTAssertEqual(missingReport.missingTrialIDs, ["latency#2"])

        let first = passingObservations(for: policy)[0]
        let duplicate = try makeRun(
            profile: profile,
            policy: policy,
            observations: passingObservations(for: policy) + [first]
        )
        XCTAssertEqual(
            try evaluateWithContext(
                profile: profile,
                policy: policy,
                run: duplicate
            )?.verdict,
            .inconclusive
        )

        let unknown = try Phase2QualificationProbeObservation(
            probeID: "unknown-probe",
            trial: 1,
            outcome: .passed
        )
        let unknownRun = try makeRun(
            profile: profile,
            policy: policy,
            observations: passingObservations(for: policy) + [unknown]
        )
        XCTAssertEqual(
            try evaluateWithContext(
                profile: profile,
                policy: policy,
                run: unknownRun
            )?.verdict,
            .inconclusive
        )

        var notRun = passingObservations(for: policy)
        notRun[0] = try .init(
            probeID: notRun[0].probeID,
            trial: notRun[0].trial,
            outcome: .notRun,
            reasonCode: "fixture-unavailable"
        )
        let notRunReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: notRun)
        ))
        XCTAssertEqual(notRunReport.verdict, .inconclusive)
        XCTAssertEqual(notRunReport.inconclusiveReasonCodes, ["not-run"])
    }

    func testHardFailureDominatesAndEveryAttemptRemainsInDenominator() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        var observations = passingObservations(for: policy)
        observations[0] = try .init(
            probeID: "exact-identity",
            trial: 1,
            outcome: .failed,
            reasonCode: "identity-drift"
        )

        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: observations)
        ))
        XCTAssertEqual(report.verdict, .unsupported)
        XCTAssertEqual(report.supportStatus, .unsupported)
        XCTAssertEqual(report.declaredTrialCount, 6)
        XCTAssertEqual(report.observedTrialCount, 6)
        XCTAssertEqual(report.failedTrialCount, 1)
        XCTAssertEqual(report.failedProbeIDs, ["exact-identity"])
    }

    func testQualityFailureIsCompatibleAndCoreFailureIsExperimental() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()

        var qualityFailure = passingObservations(for: policy)
        qualityFailure[4] = try .init(
            probeID: "latency",
            trial: 1,
            outcome: .failed,
            reasonCode: "threshold-missed"
        )
        XCTAssertEqual(
            try evaluateWithContext(
                profile: profile,
                policy: policy,
                run: makeRun(profile: profile, policy: policy, observations: qualityFailure)
            )?.verdict,
            .compatible
        )

        var coreFailure = passingObservations(for: policy)
        coreFailure[1] = try .init(
            probeID: "grounded-citation",
            trial: 1,
            outcome: .failed,
            reasonCode: "citation-missing"
        )
        XCTAssertEqual(
            try evaluateWithContext(
                profile: profile,
                policy: policy,
                run: makeRun(profile: profile, policy: policy, observations: coreFailure)
            )?.verdict,
            .experimental
        )
    }

    func testWrongProfilePolicyCorpusProtocolOrHardwareBindingIsInconclusive() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let run = try makeRun(
            profile: profile,
            policy: policy,
            observations: passingObservations(for: policy),
            corpusDigest: String(repeating: "c", count: 64)
        )
        let changedProfile = try makeProfile(topP: 0.9)

        let report = try XCTUnwrap(try evaluateWithContext(
            profile: changedProfile,
            policy: policy,
            run: run
        ))
        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertNil(report.supportStatus)
        XCTAssertEqual(
            report.inconclusiveReasonCodes,
            ["corpus-digest-mismatch", "profile-identity-mismatch"]
        )
    }

    func testObservationPermutationIsStableButMaterialEvidenceChangesReportIdentity() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let observations = passingObservations(for: policy)
        let first = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: observations)
        ))
        let reordered = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: observations.reversed())
        ))
        XCTAssertEqual(first, reordered)

        var changed = observations
        changed[4] = try .init(
            probeID: "latency",
            trial: 1,
            outcome: .failed,
            reasonCode: "threshold-missed"
        )
        let changedReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: changed)
        ))
        XCTAssertNotEqual(first.reportID, changedReport.reportID)
    }

    func testReportIDBindsClaimedAndExpectedProfileAndPolicyIdentities() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let observations = passingObservations(for: policy)
        let exactRun = try makeRun(
            profile: profile,
            policy: policy,
            observations: observations
        )
        let exactReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: exactRun
        ))
        let wrongPolicy = component("different-policy", byte: "e")
        let wrongPolicyRun = try makeRun(
            profile: profile,
            policy: policy,
            observations: observations,
            claimedPolicyIdentity: wrongPolicy
        )
        let wrongPolicyReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: wrongPolicyRun
        ))
        XCTAssertNotEqual(exactReport.reportID, wrongPolicyReport.reportID)
        XCTAssertEqual(wrongPolicyReport.claimedPolicyIdentity, wrongPolicy)
        XCTAssertNotEqual(
            wrongPolicyReport.expectedPolicyIdentity,
            wrongPolicyReport.claimedPolicyIdentity
        )

        let otherProfile = try makeProfile(topP: 0.9)
        let wrongProfileReport = try XCTUnwrap(try evaluateWithContext(
            profile: otherProfile,
            policy: policy,
            run: exactRun
        ))
        XCTAssertNotEqual(exactReport.reportID, wrongProfileReport.reportID)
        XCTAssertNotEqual(
            wrongProfileReport.expectedProfileID,
            wrongProfileReport.claimedProfileID
        )

        let changedEvaluationContextReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: exactRun,
            context: evaluationContext(evaluatedAt: 2_000, maximumAge: 2_000)
        ))
        XCTAssertNotEqual(exactReport.reportID, changedEvaluationContextReport.reportID)
    }

    func testPolicyIdentityBindsCorpusCategoriesSeveritiesAndTrialCounts() throws {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let baseline = try makePolicy()
        let changedSeverity = try makePolicy(latencySeverity: .core)
        let changedThreshold = try makePolicy(latencyRuleByte: "c")
        let changedMeasurements = try makePolicy(
            latencyRequiredMeasurements: [.totalLatencyMilliseconds]
        )
        let reorderedMeasurements = try makePolicy(latencyRequiredMeasurements: [
            .throughputMilliTokensPerSecond,
            .totalLatencyMilliseconds,
        ])
        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(for: baseline),
            try canonicalizer.qualificationPolicyIdentity(for: changedSeverity)
        )
        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(for: baseline),
            try canonicalizer.qualificationPolicyIdentity(for: changedThreshold)
        )
        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(for: baseline),
            try canonicalizer.qualificationPolicyIdentity(for: changedMeasurements)
        )
        XCTAssertEqual(
            try canonicalizer.qualificationPolicyIdentity(for: baseline),
            try canonicalizer.qualificationPolicyIdentity(for: reorderedMeasurements)
        )
    }

    func testUnavailableProtocolArtifactCannotCertifyAnAllPassFixture() throws {
        let policy = try makePolicy()
        let profile = try makeProfile(unavailableToolRegistry: true)
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(
                profile: profile,
                policy: policy,
                observations: passingObservations(for: policy)
            )
        ))
        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertNil(report.supportStatus)
        XCTAssertEqual(report.inconclusiveReasonCodes, ["protocol-artifact-unavailable"])
    }

    func testSafetyAndProtocolRequirementsCannotBeDowngraded() throws {
        for category in [
            Phase2QualificationProbeCategory.identity,
            .protocolConformance,
            .safety,
        ] {
            XCTAssertThrowsError(try Phase2QualificationProbeRequirement(
                probeID: "weakened-probe",
                category: category,
                severity: .quality,
                requiredTrialCount: 1,
                acceptanceCriteria: component("weakened-rule", byte: "d")
            ))
        }
    }

    func testConflictingDuplicatePermutationHasStableInconclusiveReportID() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let first = try Phase2QualificationProbeObservation(
            probeID: "exact-identity",
            trial: 1,
            outcome: .passed,
            evidenceDigest: String(repeating: "a", count: 64)
        )
        let second = try Phase2QualificationProbeObservation(
            probeID: "exact-identity",
            trial: 1,
            outcome: .failed,
            reasonCode: "identity-drift",
            evidenceDigest: String(repeating: "b", count: 64)
        )
        let tail = Array(passingObservations(for: policy).dropFirst())
        let forward = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: [first, second] + tail)
        ))
        let reverse = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: [second, first] + tail)
        ))
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.inconclusiveReasonCodes, ["duplicate-attempt"])
    }

    func testBindingFailurePreservesMissingDenominatorAndStaleEvidenceIsInconclusive() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let emptyWrongProfileRun = try makeRun(
            profile: try makeProfile(topP: 0.9),
            policy: policy,
            observations: []
        )
        let missing = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: emptyWrongProfileRun
        ))
        XCTAssertEqual(missing.missingTrialIDs.count, policy.declaredTrialCount)
        XCTAssertTrue(missing.inconclusiveReasonCodes.contains("profile-identity-mismatch"))
        XCTAssertTrue(missing.inconclusiveReasonCodes.contains("missing-trial"))

        let oldRun = try makeRun(
            profile: profile,
            policy: policy,
            observations: passingObservations(for: policy),
            startedAtEpochMilliseconds: 100,
            endedAtEpochMilliseconds: 200
        )
        let stale = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: oldRun,
            context: evaluationContext(evaluatedAt: 10_000, maximumAge: 1_000)
        ))
        XCTAssertEqual(stale.verdict, .inconclusive)
        XCTAssertEqual(stale.inconclusiveReasonCodes, ["stale-evidence"])
    }

    func testReportVocabularyCannotCarryRawPayloads() throws {
        XCTAssertThrowsError(try Phase2QualificationProbeObservation(
            probeID: "exact-identity",
            trial: 1,
            outcome: .failed,
            reasonCode: "contains a path /Users/someone/private"
        ))
        XCTAssertThrowsError(try Phase2QualificationProbeObservation(
            probeID: "exact-identity",
            trial: 1,
            outcome: .failed,
            reasonCode: String(repeating: "x", count: 129)
        ))
    }

    func testPerformanceRequirementsMustDeclareBoundedMeasurements() throws {
        XCTAssertThrowsError(try Phase2QualificationProbeRequirement(
            probeID: "latency",
            category: .performance,
            severity: .quality,
            requiredTrialCount: 1,
            acceptanceCriteria: component("latency-rule", byte: "a")
        ))
        XCTAssertThrowsError(try Phase2QualificationProbeRequirement(
            probeID: "latency",
            category: .performance,
            severity: .quality,
            requiredTrialCount: 1,
            acceptanceCriteria: component("latency-rule", byte: "a"),
            requiredMeasurements: [.totalLatencyMilliseconds, .totalLatencyMilliseconds]
        ))
        XCTAssertThrowsError(try Phase2QualificationMeasurements(
            totalLatencyMilliseconds: -1
        ))
        XCTAssertThrowsError(try Phase2QualificationMeasurements(
            peakResidentBytes: 1_099_511_627_777
        ))
        XCTAssertThrowsError(try Phase2QualificationNumericRule(
            measurement: .totalLatencyMilliseconds,
            comparison: .maximumInclusive,
            threshold: 86_400_001
        ))
        XCTAssertThrowsError(try Phase2ModelQualificationPolicy(
            id: "qualification-policy",
            version: 2,
            corpusDigest: String(repeating: "a", count: 64),
            requirements: [
                try .init(
                    probeID: "exact-identity",
                    category: .identity,
                    severity: .hard,
                    requiredTrialCount: 1,
                    acceptanceCriteria: component("identity-rule", byte: "a")
                ),
            ]
        ))
    }

    func testV2NonperformanceRequiredMeasurementMustHaveExactNumericRule() throws {
        XCTAssertThrowsError(try Phase2QualificationProbeRequirement(
            probeID: "identity-with-latency",
            executionKind: .liveProvider,
            category: .identity,
            severity: .hard,
            requiredTrialCount: 1,
            acceptanceCriteria: component("identity-with-latency-rule", byte: "a"),
            evidenceRequirement: .requiredSHA256,
            requiredMeasurements: [.totalLatencyMilliseconds]
        ))

        XCTAssertNoThrow(try Phase2QualificationProbeRequirement(
            probeID: "identity-with-latency",
            executionKind: .liveProvider,
            category: .identity,
            severity: .hard,
            requiredTrialCount: 1,
            acceptanceCriteria: component("identity-with-latency-rule", byte: "a"),
            evidenceRequirement: .requiredSHA256,
            requiredMeasurements: [.totalLatencyMilliseconds],
            numericRules: [
                try .init(
                    measurement: .totalLatencyMilliseconds,
                    scope: .perAttempt,
                    comparison: .maximumInclusive,
                    threshold: 1_000
                ),
            ]
        ))
    }

    func testV1PolicyRejectsV2RequirementBeforeCanonicalIdentityCollision() throws {
        let legacyRequirement = try Phase2QualificationProbeRequirement(
            probeID: "identity-check",
            category: .identity,
            severity: .hard,
            requiredTrialCount: 1,
            acceptanceCriteria: component("identity-rule", byte: "a")
        )
        let v2Requirement = try Phase2QualificationProbeRequirement(
            probeID: "identity-check",
            executionKind: .deterministicFixture,
            category: .identity,
            severity: .hard,
            requiredTrialCount: 1,
            acceptanceCriteria: component("identity-rule", byte: "a"),
            evidenceRequirement: .requiredSHA256
        )
        let legacyPolicy = try Phase2ModelQualificationPolicy(
            id: "qualification-policy",
            version: 1,
            corpusDigest: String(repeating: "b", count: 64),
            requirements: [legacyRequirement]
        )
        XCTAssertNoThrow(
            try Phase2ModelProfileCanonicalizer().qualificationPolicyIdentity(for: legacyPolicy)
        )
        XCTAssertThrowsError(try Phase2ModelQualificationPolicy(
            id: "qualification-policy",
            version: 1,
            corpusDigest: String(repeating: "b", count: 64),
            requirements: [v2Requirement]
        ))
    }

    func testMissingRequiredAggregateMeasurementIsInconclusive() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let run = try makeRun(
            profile: profile,
            policy: policy,
            observations: passingObservations(for: policy),
            measurements: try .init(totalLatencyMilliseconds: 900)
        )

        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: run
        ))
        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertEqual(report.inconclusiveReasonCodes, ["required-measurement-missing"])
    }

    func testAggregateMeasurementChangeChangesReportIdentity() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let observations = passingObservations(for: policy)
        let first = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(
                profile: profile,
                policy: policy,
                observations: observations,
                measurements: try .init(
                    totalLatencyMilliseconds: 900,
                    throughputMilliTokensPerSecond: 1_000
                )
            )
        ))
        let changed = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(
                profile: profile,
                policy: policy,
                observations: observations,
                measurements: try .init(
                    totalLatencyMilliseconds: 901,
                    throughputMilliTokensPerSecond: 1_000
                )
            )
        ))

        XCTAssertNotEqual(first.reportID, changed.reportID)
        XCTAssertEqual(first.measurements.totalLatencyMilliseconds, 900)
        XCTAssertEqual(changed.measurements.totalLatencyMilliseconds, 901)
    }

    func testTerminationAndAttemptProvenanceChangeReportIdentity() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let observations = passingObservations(for: policy)
        let completed = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: observations)
        ))
        let cancelled = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(
                profile: profile,
                policy: policy,
                observations: observations,
                terminationStatus: .cancelled
            )
        ))
        XCTAssertNotEqual(completed.reportID, cancelled.reportID)

        var retryOnly = observations
        retryOnly.append(try .init(
            probeID: retryOnly[0].probeID,
            trial: retryOnly[0].trial,
            attempt: 2,
            outcome: retryOnly[0].outcome
        ))
        let retryReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: retryOnly)
        ))
        XCTAssertNotEqual(completed.reportID, retryReport.reportID)
        XCTAssertEqual(completed.retryAttemptCount, 0)
        XCTAssertEqual(retryReport.retryAttemptCount, 1)
    }

    func testRetriesAreAdditionalAttemptsAndCannotEraseFailure() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        var observations = passingObservations(for: policy)
        observations[0] = try .init(
            probeID: "exact-identity",
            trial: 1,
            attempt: 1,
            outcome: .failed,
            reasonCode: "identity-drift"
        )
        observations.append(try .init(
            probeID: "exact-identity",
            trial: 1,
            attempt: 2,
            outcome: .passed
        ))
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: observations)
        ))

        XCTAssertEqual(report.verdict, .unsupported)
        XCTAssertEqual(report.observedTrialCount, 6)
        XCTAssertEqual(report.observedAttemptCount, 7)
        XCTAssertEqual(report.passedTrialCount, 5)
        XCTAssertEqual(report.failedTrialCount, 1)
        XCTAssertEqual(report.passedAttemptCount, 6)
        XCTAssertEqual(report.failedAttemptCount, 1)
        XCTAssertEqual(report.retryAttemptCount, 1)
        XCTAssertEqual(
            report.observations.filter { $0.probeID == "exact-identity" }.map(\.attempt),
            [1, 2]
        )
    }

    func testDuplicateAttemptAndNoncompletedRunAreInconclusive() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let observations = passingObservations(for: policy)
        let duplicate = try makeRun(
            profile: profile,
            policy: policy,
            observations: observations + [observations[0]]
        )
        let duplicateReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: duplicate
        ))
        XCTAssertEqual(duplicateReport.inconclusiveReasonCodes, ["duplicate-attempt"])

        for (terminationStatus, reason) in [
            (Phase2QualificationRunTerminationStatus.cancelled, "run-cancelled"),
            (.failed, "run-failed"),
        ] {
            let run = try makeRun(
                profile: profile,
                policy: policy,
                observations: observations,
                terminationStatus: terminationStatus
            )
            let report = try XCTUnwrap(try evaluateWithContext(
                profile: profile,
                policy: policy,
                run: run
            ))
            XCTAssertEqual(report.verdict, .inconclusive)
            XCTAssertEqual(report.inconclusiveReasonCodes, [reason])
        }
    }

    func testAttemptSequencesMustStartAtOneAndRemainContiguous() throws {
        let profile = try makeProfile()
        let policy = try makePolicy()
        let observations = passingObservations(for: policy)

        var loneSecondAttempt = observations
        loneSecondAttempt[0] = try .init(
            probeID: loneSecondAttempt[0].probeID,
            trial: loneSecondAttempt[0].trial,
            attempt: 2,
            outcome: .passed
        )
        let loneReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: loneSecondAttempt)
        ))
        XCTAssertEqual(loneReport.verdict, .inconclusive)
        XCTAssertEqual(loneReport.inconclusiveReasonCodes, ["missing-attempt"])

        var gappedAttempts = observations
        gappedAttempts.append(try .init(
            probeID: observations[0].probeID,
            trial: observations[0].trial,
            attempt: 3,
            outcome: .passed
        ))
        let gappedReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeRun(profile: profile, policy: policy, observations: gappedAttempts)
        ))
        XCTAssertEqual(gappedReport.verdict, .inconclusive)
        XCTAssertEqual(gappedReport.inconclusiveReasonCodes, ["missing-attempt"])
    }

    func testV2PolicyIdentityBindsCorporaExecutionEvidenceAndNumericRules() throws {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let baseline = try makeV2Policy()
        let baselineIdentity = try canonicalizer.qualificationPolicyIdentity(for: baseline)
        let variants = [
            try makeV2Policy(protocolProbeByte: "1"),
            try makeV2Policy(liveCorpusByte: "2"),
            try makeV2Policy(metricSemanticsByte: "3"),
            try makeV2Policy(executionKind: .deterministicFixture),
            try makeV2Policy(
                numericRule: .init(
                    measurement: .totalLatencyMilliseconds,
                    comparison: .maximumInclusive,
                    threshold: 900
                )
            ),
        ]

        for variant in variants {
            XCTAssertNotEqual(
                baselineIdentity,
                try canonicalizer.qualificationPolicyIdentity(for: variant)
            )
        }
    }

    func testV2EvaluationRequiresEvidenceAndExactSeparateCorpusBindings() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let observations = try v2PassingObservations(policy: policy)
        let exact = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations
        )
        XCTAssertEqual(
            try evaluateWithContext(profile: profile, policy: policy, run: exact)?.verdict,
            .certified
        )

        let missingEvidence = try [Phase2QualificationProbeObservation(
            probeID: "live-latency",
            trial: 1,
            outcome: .passed
        )]
        let evidenceReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeV2Run(
                profile: profile,
                policy: policy,
                observations: missingEvidence
            )
        ))
        XCTAssertEqual(evidenceReport.verdict, .inconclusive)
        XCTAssertEqual(evidenceReport.inconclusiveReasonCodes, ["required-evidence-missing"])

        let mismatchedCatalog = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations,
            protocolProbeCatalogIdentity: component("protocol-probes", byte: "f")
        )
        let catalogReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: mismatchedCatalog
        ))
        XCTAssertEqual(catalogReport.verdict, .inconclusive)
        XCTAssertEqual(
            catalogReport.inconclusiveReasonCodes,
            ["protocol-probe-catalog-mismatch"]
        )
    }

    func testV2RunAndReportBindClaimedEvidenceToTrustedExpectations() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let observations = try v2PassingObservations(policy: policy)
        let evidence = try makeEvidenceBundle()
        let expected = try Phase2QualificationEvidenceExpectations(evidenceBundle: evidence)
        let context = try evaluationContext(evidenceBundle: evidence)
        let exact = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations,
            evidenceBundle: evidence
        )
        let exactReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: exact,
            context: context
        ))

        XCTAssertEqual(exactReport.verdict, .certified)
        XCTAssertEqual(exact.environmentIdentity, expected.environmentIdentity)
        XCTAssertEqual(exact.runtimeProvenanceIdentity, expected.runtimeProvenanceIdentity)
        XCTAssertEqual(exact.measurementEvidenceIdentity, expected.measurementEvidenceIdentity)
        XCTAssertEqual(exactReport.environmentIdentity, expected.environmentIdentity)
        XCTAssertEqual(exactReport.runtimeProvenanceIdentity, expected.runtimeProvenanceIdentity)
        XCTAssertEqual(exactReport.measurementEvidenceIdentity, expected.measurementEvidenceIdentity)
        XCTAssertEqual(exact.modelSource, profile.artifact.source)
        XCTAssertEqual(exactReport.modelSource, profile.artifact.source)
        XCTAssertEqual(
            exact.modelRevisionIdentity,
            evidence.runtimeProvenance.modelRevisionIdentity
        )
        XCTAssertEqual(
            exactReport.modelRevisionIdentity,
            evidence.runtimeProvenance.modelRevisionIdentity
        )
        XCTAssertEqual(
            exact.productionDefinitionIdentity,
            evidence.runtimeProvenance.productionDefinitionIdentity
        )
        XCTAssertEqual(
            exactReport.productionDefinitionIdentity,
            evidence.runtimeProvenance.productionDefinitionIdentity
        )
        let serializedReport = try XCTUnwrap(
            Phase2QualificationGateArtifactWriter.serializedData(for: exactReport)
        )
        let reportObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: serializedReport) as? [String: Any]
        )
        XCTAssertEqual(reportObject["model_source"] as? String, profile.artifact.source)
        XCTAssertEqual(
            (reportObject["model_revision"] as? [String: Any])?["sha256"] as? String,
            evidence.runtimeProvenance.modelRevisionIdentity.sha256
        )
        XCTAssertEqual(
            (reportObject["production_qualification_definition"] as? [String: Any])?["sha256"]
                as? String,
            evidence.runtimeProvenance.productionDefinitionIdentity.sha256
        )

        let drifts: [(Phase2ModelQualificationRun, String)] = [
            (
                try makeV2Run(
                    profile: profile,
                    policy: policy,
                    observations: observations,
                    evidenceBundle: makeEvidenceBundle(bundleVersion: "test-build-2")
                ),
                "environment-identity-mismatch"
            ),
            (
                try makeV2Run(
                    profile: profile,
                    policy: policy,
                    observations: observations,
                    evidenceBundle: makeEvidenceBundle(startedAt: 1_001)
                ),
                "runtime-provenance-identity-mismatch"
            ),
            (
                try makeV2Run(
                    profile: profile,
                    policy: policy,
                    observations: observations,
                    evidenceBundle: makeEvidenceBundle(
                        modelSource: "publisher/different-model"
                    )
                ),
                "runtime-provenance-identity-mismatch"
            ),
            (
                try makeV2Run(
                    profile: profile,
                    policy: policy,
                    observations: observations,
                    evidenceBundle: makeEvidenceBundle(
                        modelRevisionIdentity: component(
                            "phase2.r1.qwen3-coder-30b-a3b-instruct-8bit.model-revision.v1",
                            byte: "d"
                        )
                    )
                ),
                "runtime-provenance-identity-mismatch"
            ),
            (
                try makeV2Run(
                    profile: profile,
                    policy: policy,
                    observations: observations,
                    evidenceBundle: makeEvidenceBundle(
                        productionDefinitionIdentity: component(
                            "phase2.r1.standard-qualification-definition.v1",
                            byte: "f"
                        )
                    )
                ),
                "runtime-provenance-identity-mismatch"
            ),
            (
                try makeV2Run(
                    profile: profile,
                    policy: policy,
                    observations: observations,
                    evidenceBundle: makeEvidenceBundle(attemptLatency: 999)
                ),
                "measurement-evidence-identity-mismatch"
            ),
        ]

        for (run, expectedReason) in drifts {
            let report = try XCTUnwrap(try evaluateWithContext(
                profile: profile,
                policy: policy,
                run: run,
                context: context
            ))
            XCTAssertEqual(report.verdict, .inconclusive)
            XCTAssertTrue(report.inconclusiveReasonCodes.contains(expectedReason))
            XCTAssertNotEqual(report.reportID, exactReport.reportID)
        }
    }

    func testV2TrustedExpectationDriftAndAbsenceCannotCertifySelfClaimedRun() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let run = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: v2PassingObservations(policy: policy)
        )
        let exactReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: run,
            context: evaluationContext(evidenceBundle: run.evidenceBundle!)
        ))
        let driftReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: run,
            context: evaluationContext(
                evidenceBundle: makeEvidenceBundle(bundleVersion: "test-build-2")
            )
        ))
        let missingReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: run,
            context: evaluationContext()
        ))

        XCTAssertEqual(driftReport.verdict, .inconclusive)
        XCTAssertTrue(driftReport.inconclusiveReasonCodes.contains("environment-identity-mismatch"))
        XCTAssertNotEqual(driftReport.reportID, exactReport.reportID)
        XCTAssertEqual(missingReport.verdict, .inconclusive)
        XCTAssertEqual(
            missingReport.inconclusiveReasonCodes,
            ["qualification-evidence-expectations-missing"]
        )
    }

    func testV2EvidenceIdentityKindsAndVersionsAreDerivedFromConcreteEvidence() throws {
        let expected = try Phase2QualificationEvidenceExpectations(
            evidenceBundle: makeEvidenceBundle()
        )
        XCTAssertEqual(expected.environmentIdentity.id, "phase2.r1.qualification-environment.v2")
        XCTAssertEqual(expected.runtimeProvenanceIdentity.id, "phase2.r1.qualification-runtime-provenance.v3")
        XCTAssertEqual(expected.measurementEvidenceIdentity.id, "phase2.r1.qualification-measurements.v2")
        XCTAssertEqual(expected.environmentIdentity.version, 2)
        XCTAssertEqual(expected.runtimeProvenanceIdentity.version, 3)
        XCTAssertEqual(expected.measurementEvidenceIdentity.version, 2)
    }

    func testV2EvaluatorOwnsNumericThresholdVerdictAndRequiresAttemptMeasurements() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let observations = try v2PassingObservations(policy: policy)
        let passing = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations,
            latency: 1_000
        )
        XCTAssertEqual(
            try evaluateWithContext(profile: profile, policy: policy, run: passing)?.verdict,
            .certified
        )

        let thresholdFailure = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations,
            latency: 1_001
        )
        let failureReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: thresholdFailure
        ))
        XCTAssertEqual(failureReport.verdict, .compatible)
        XCTAssertEqual(failureReport.failedProbeIDs, ["live-latency"])
        XCTAssertEqual(failureReport.failedAttemptCount, 1)
        XCTAssertEqual(failureReport.observations.first?.reasonCode, "numeric-threshold-failed")

        XCTAssertThrowsError(try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations,
            attemptMeasurements: []
        ), "The derived evidence seam must reject an incomplete admitted denominator")
    }

    func testV2AttemptMeasurementIdentityChangesContentAddressedReport() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let observations = try v2PassingObservations(policy: policy)
        let first = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeV2Run(
                profile: profile,
                policy: policy,
                observations: observations,
                latency: 900
            )
        ))
        let changed = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeV2Run(
                profile: profile,
                policy: policy,
                observations: observations,
                latency: 901
            )
        ))

        XCTAssertNotEqual(first.reportID, changed.reportID)
        XCTAssertEqual(first.attemptMeasurements.first?.attemptID, "live-latency#1#1")
    }

    func testV2AttemptMeasurementDriftCannotInheritTrustedEvidence() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let expectedEvidence = try makeEvidenceBundle(attemptLatency: 900)
        let driftedRun = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: v2PassingObservations(policy: policy),
            evidenceBundle: makeEvidenceBundle(attemptLatency: 901)
        )
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: driftedRun,
            context: evaluationContext(evidenceBundle: expectedEvidence)
        ))

        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertTrue(report.inconclusiveReasonCodes.contains("measurement-evidence-identity-mismatch"))
    }

    func testV2AggregateMeasurementDriftCannotInheritTrustedEvidence() throws {
        let policy = try makeV2Policy(numericRule: .init(
            measurement: .totalLatencyMilliseconds,
            scope: .runAggregate,
            comparison: .maximumInclusive,
            threshold: 1_000
        ))
        let profile = try makeV2Profile(policy: policy)
        let expectedEvidence = try makeEvidenceBundle(aggregateLatency: 900)
        let driftedRun = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: v2PassingObservations(policy: policy),
            evidenceBundle: makeEvidenceBundle(aggregateLatency: 901)
        )
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: driftedRun,
            context: evaluationContext(evidenceBundle: expectedEvidence)
        ))

        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertTrue(report.inconclusiveReasonCodes.contains("measurement-evidence-identity-mismatch"))
    }

    func testV2RuntimeTimestampDriftCannotInheritTrustedEvidence() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let expectedEvidence = try makeEvidenceBundle(startedAt: 1_000, endedAt: 2_000)
        let driftedRun = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: v2PassingObservations(policy: policy),
            evidenceBundle: makeEvidenceBundle(startedAt: 1_001, endedAt: 2_000)
        )
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: driftedRun,
            context: evaluationContext(evidenceBundle: expectedEvidence)
        ))

        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertTrue(report.inconclusiveReasonCodes.contains("runtime-provenance-identity-mismatch"))
    }

    func testV2EnvironmentBuildDriftCannotInheritTrustedEvidence() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let expectedEvidence = try makeEvidenceBundle(bundleVersion: "test-build-1")
        let driftedRun = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: v2PassingObservations(policy: policy),
            evidenceBundle: makeEvidenceBundle(bundleVersion: "test-build-2")
        )
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: driftedRun,
            context: evaluationContext(evidenceBundle: expectedEvidence)
        ))

        XCTAssertEqual(report.verdict, .inconclusive)
        XCTAssertTrue(report.inconclusiveReasonCodes.contains("environment-identity-mismatch"))
    }

    func testV2PolicyIdentityBindsMaximumEvidenceAgeAndNumericScope() throws {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let baseline = try makeV2Policy(maximumEvidenceAgeMilliseconds: 1_000)
        let changedAge = try makeV2Policy(maximumEvidenceAgeMilliseconds: 1_001)
        let aggregateScope = try makeV2Policy(numericRule: .init(
            measurement: .totalLatencyMilliseconds,
            scope: .runAggregate,
            comparison: .maximumInclusive,
            threshold: 1_000
        ))

        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(for: baseline),
            try canonicalizer.qualificationPolicyIdentity(for: changedAge)
        )
        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(for: baseline),
            try canonicalizer.qualificationPolicyIdentity(for: aggregateScope)
        )
    }

    func testV2DeterministicFixtureCorpusDriftChangesRunAndReportIdentity() throws {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let baselinePolicy = try makeV2Policy(deterministicFixtureByte: "9")
        let driftedPolicy = try makeV2Policy(deterministicFixtureByte: "8")
        let baselineProfile = try makeV2Profile(policy: baselinePolicy)
        let driftedProfile = try makeV2Profile(policy: driftedPolicy)
        let baselineRun = try makeV2Run(
            profile: baselineProfile,
            policy: baselinePolicy,
            observations: v2PassingObservations(policy: baselinePolicy)
        )
        let driftedRun = try makeV2Run(
            profile: driftedProfile,
            policy: driftedPolicy,
            observations: v2PassingObservations(policy: driftedPolicy)
        )
        let baselineReport = try XCTUnwrap(try evaluateWithContext(
            profile: baselineProfile,
            policy: baselinePolicy,
            run: baselineRun
        ))
        let driftedReport = try XCTUnwrap(try evaluateWithContext(
            profile: driftedProfile,
            policy: driftedPolicy,
            run: driftedRun
        ))

        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(for: baselinePolicy),
            try canonicalizer.qualificationPolicyIdentity(for: driftedPolicy)
        )
        XCTAssertNotEqual(baselineRun.policyIdentity, driftedRun.policyIdentity)
        XCTAssertNotEqual(baselineRun.profileID, driftedRun.profileID)
        XCTAssertNotEqual(
            baselineRun.protocolManifestDigest,
            driftedRun.protocolManifestDigest
        )
        XCTAssertNotEqual(baselineReport.reportID, driftedReport.reportID)
        XCTAssertEqual(baselineReport.claimedPolicyIdentity, baselineRun.policyIdentity)
        XCTAssertEqual(driftedReport.claimedPolicyIdentity, driftedRun.policyIdentity)
    }

    func testV2PolicyFreshnessCannotBeEnlargedAndHandlesBoundaryAndUnderflow() throws {
        let policy = try makeV2Policy(maximumEvidenceAgeMilliseconds: 1_000)
        let profile = try makeV2Profile(policy: policy)
        let observations = try v2PassingObservations(policy: policy)

        let staleRun = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations,
            startedAtEpochMilliseconds: 999,
            endedAtEpochMilliseconds: 999
        )
        let enlargedContextReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: staleRun,
            context: evaluationContext(
                evaluatedAt: 2_000,
                maximumAge: 10_000,
                evidenceBundle: staleRun.evidenceBundle!
            )
        ))
        XCTAssertEqual(enlargedContextReport.verdict, .inconclusive)
        XCTAssertEqual(enlargedContextReport.inconclusiveReasonCodes, ["stale-evidence"])

        let boundaryRun = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations,
            startedAtEpochMilliseconds: 1_000,
            endedAtEpochMilliseconds: 1_000
        )
        let boundary = try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: boundaryRun,
            context: evaluationContext(
                evaluatedAt: 2_000,
                maximumAge: 10_000,
                evidenceBundle: boundaryRun.evidenceBundle!
            )
        )
        XCTAssertEqual(boundary?.verdict, .certified)

        let underflowRun = try makeV2Run(
            profile: profile,
            policy: policy,
            observations: observations,
            startedAtEpochMilliseconds: 0,
            endedAtEpochMilliseconds: 0
        )
        let underflow = try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: underflowRun,
            context: evaluationContext(
                evaluatedAt: 500,
                maximumAge: 10_000,
                evidenceBundle: underflowRun.evidenceBundle!
            )
        )
        XCTAssertEqual(underflow?.verdict, .certified)
    }

    func testV2RejectsMixedVersionsRetriesAndNonexactAttemptMeasurementKeysets() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let observations = try v2PassingObservations(policy: policy)
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let mixedVersionObservation = try Phase2QualificationProbeObservation(
            probeID: "live-latency",
            trial: 1,
            attempt: 2,
            outcome: .failed,
            reasonCode: "semantic-mismatch",
            evidenceDigest: String(repeating: "e", count: 64)
        )
        let legacyRun = try Phase2ModelQualificationRun(
            version: 1,
            profileID: canonicalizer.stableID(for: profile),
            policyIdentity: canonicalizer.qualificationPolicyIdentity(for: policy),
            protocolManifestDigest: canonicalizer.protocolManifestDigest(
                for: profile.protocolManifest
            ),
            corpusDigest: policy.corpusDigest,
            macScopeBuild: "test-build-1",
            toolchainBuild: "xcode-27-test",
            operatingSystemBuild: "macOS-27-test",
            architecture: "arm64",
            hardwareTier: profile.hardwareTier,
            startedAtEpochMilliseconds: 1_000,
            endedAtEpochMilliseconds: 2_000,
            measurements: .init(totalLatencyMilliseconds: 1_000),
            observations: [mixedVersionObservation]
        )
        let versionReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: legacyRun
        ))
        XCTAssertEqual(versionReport.inconclusiveReasonCodes, ["qualification-version-mismatch"])

        let retryObservation = try Phase2QualificationProbeObservation(
            probeID: "live-latency",
            trial: 1,
            attempt: 2,
            outcome: .failed,
            reasonCode: "semantic-mismatch",
            evidenceDigest: String(repeating: "e", count: 64)
        )
        let retryReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeV2Run(
                profile: profile,
                policy: policy,
                observations: [retryObservation]
            )
        ))
        XCTAssertEqual(
            retryReport.inconclusiveReasonCodes,
            ["retry-forbidden", "unknown-attempt-measurement"]
        )

        let duplicateReport = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeV2Run(
                profile: profile,
                policy: policy,
                observations: [observations[0], observations[0]],
                attemptMeasurements: [
                    try .init(
                        probeID: "live-latency",
                        trial: 1,
                        attempt: 1,
                        measurements: .init(totalLatencyMilliseconds: 1_000)
                    ),
                ]
            )
        ))
        XCTAssertEqual(duplicateReport.inconclusiveReasonCodes, ["duplicate-attempt"])

        let extraSample = try Phase2QualificationAttemptMeasurements(
            probeID: "live-latency",
            trial: 2,
            attempt: 1,
            measurements: .init(totalLatencyMilliseconds: 1_000)
        )
        XCTAssertThrowsError(try makeV2Run(
                profile: profile,
                policy: policy,
                observations: observations,
                attemptMeasurements: [
                    try .init(
                        probeID: "live-latency",
                        trial: 1,
                        attempt: 1,
                        measurements: .init(totalLatencyMilliseconds: 1_000)
                    ),
                    extraSample,
                ]
            ), "Out-of-policy measurement keys cannot enter an evidence bundle")

    }

    func testV2NumericScopeSelectsAggregateStoreAndMissingReasonsRemainDistinct() throws {
        let aggregateRule = try Phase2QualificationNumericRule(
            measurement: .totalLatencyMilliseconds,
            scope: .runAggregate,
            comparison: .maximumInclusive,
            threshold: 1_000
        )
        let policy = try makeV2Policy(numericRule: aggregateRule)
        let profile = try makeV2Profile(policy: policy)
        let observations = try v2PassingObservations(policy: policy)
        let emptyAttemptSample = try Phase2QualificationAttemptMeasurements(
            probeID: "live-latency",
            trial: 1,
            attempt: 1,
            measurements: .empty
        )

        let failed = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeV2Run(
                profile: profile,
                policy: policy,
                observations: observations,
                aggregateMeasurements: .init(totalLatencyMilliseconds: 1_001)
            )
        ))
        XCTAssertEqual(failed.verdict, .compatible)
        XCTAssertEqual(failed.observations.first?.reasonCode, "numeric-threshold-failed")

        XCTAssertThrowsError(try makeV2Run(
                profile: profile,
                policy: policy,
                observations: observations,
                aggregateMeasurements: .empty,
                attemptMeasurements: [emptyAttemptSample]
            ), "Required run-aggregate evidence must be derived completely")

        let perAttemptPolicy = try makeV2Policy()
        let perAttemptProfile = try makeV2Profile(policy: perAttemptPolicy)
        XCTAssertThrowsError(try makeV2Run(
                profile: perAttemptProfile,
                policy: perAttemptPolicy,
                observations: try v2PassingObservations(policy: perAttemptPolicy),
                attemptMeasurements: []
            ), "Required per-attempt evidence must be derived completely")
    }

    func testV2SemanticQualityFailureRemainsCompatibleWithoutNumericMeasurement() throws {
        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        let observation = try Phase2QualificationProbeObservation(
            probeID: "live-latency",
            trial: 1,
            outcome: .failed,
            reasonCode: "semantic-mismatch",
            evidenceDigest: String(repeating: "e", count: 64)
        )
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: makeV2Run(
                profile: profile,
                policy: policy,
                observations: [observation],
                aggregateMeasurements: .init(totalLatencyMilliseconds: 1_000)
            )
        ))

        XCTAssertEqual(report.verdict, .compatible)
        XCTAssertEqual(report.failedProbeIDs, ["live-latency"])
        XCTAssertEqual(report.inconclusiveReasonCodes, [])
        XCTAssertEqual(report.observations.first?.reasonCode, "semantic-mismatch")
    }

    func testV2PerformanceRulesCoverEveryRequiredMeasurementAndClosedOutcomesForbidEvidence() throws {
        XCTAssertThrowsError(try Phase2QualificationProbeRequirement(
            probeID: "live-performance",
            executionKind: .liveProvider,
            category: .performance,
            severity: .quality,
            requiredTrialCount: 1,
            acceptanceCriteria: component("performance-rule", byte: "a"),
            evidenceRequirement: .requiredSHA256,
            requiredMeasurements: [
                .totalLatencyMilliseconds,
                .throughputMilliTokensPerSecond,
            ],
            numericRules: [
                try .init(
                    measurement: .totalLatencyMilliseconds,
                    scope: .perAttempt,
                    comparison: .maximumInclusive,
                    threshold: 1_000
                ),
            ]
        ))

        let policy = try makeV2Policy()
        let profile = try makeV2Profile(policy: policy)
        for (outcome, reasonCode) in [
            (Phase2QualificationProbeOutcome.unavailable, "provider-unavailable"),
            (.cancelled, "cancelled-by-test"),
            (.notRun, "not-run-by-test"),
        ] {
            let observation = try Phase2QualificationProbeObservation(
                probeID: "live-latency",
                trial: 1,
                outcome: outcome,
                reasonCode: reasonCode,
                evidenceDigest: String(repeating: "e", count: 64)
            )
            let report = try XCTUnwrap(try evaluateWithContext(
                profile: profile,
                policy: policy,
                run: makeV2Run(
                    profile: profile,
                    policy: policy,
                    observations: [observation]
                )
            ))
            XCTAssertTrue(
                report.inconclusiveReasonCodes.contains("unexpected-evidence"),
                "Expected evidence rejection for \(outcome)"
            )
        }
    }

    func testV1CanonicalIdentityGoldensRemainParentDerived() throws {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let policy = try makePolicy()
        let profile = try makeProfile()
        let run = try makeRun(
            profile: profile,
            policy: policy,
            observations: passingObservations(for: policy)
        )
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: run
        ))

        XCTAssertEqual(
            canonicalizer.protocolManifestDigest(for: profile.protocolManifest),
            "7ddc3a16d03e886e37195c276545ef99c5aeef4d292355dc125e4ca42fec22e2"
        )
        XCTAssertEqual(
            try canonicalizer.qualificationPolicyIdentity(for: policy).sha256,
            "b0f642353968ffdd6849e55cff5c833b0fbe015e8ffcfb82dec3daa3d17d574d"
        )
        XCTAssertEqual(
            try canonicalizer.stableID(for: profile).rawValue,
            "sha256:63381a6d6dd7a93a992bbb393866bb3f5acc6d39ccd5b3f74e4f5e8c9d218264"
        )
        XCTAssertEqual(
            report.reportID.rawValue,
            "sha256:822b50ab6ab2d217f512f76f79e66c064219ee34de4cdef4418446d26146224a"
        )
    }

    func testV1ReportStripsV2EvidenceExpectationsWithoutChangingGoldenIdentity() throws {
        let policy = try makePolicy()
        let profile = try makeProfile()
        let run = try makeRun(
            profile: profile,
            policy: policy,
            observations: passingObservations(for: policy)
        )
        let report = try XCTUnwrap(try evaluateWithContext(
            profile: profile,
            policy: policy,
            run: run,
            context: evaluationContext(evidenceBundle: makeEvidenceBundle())
        ))

        XCTAssertNil(report.evaluationContext.evidenceExpectations)
        XCTAssertEqual(
            report.reportID.rawValue,
            "sha256:822b50ab6ab2d217f512f76f79e66c064219ee34de4cdef4418446d26146224a"
        )
    }

    private func makePolicy(
        latencySeverity: Phase2QualificationProbeSeverity = .quality,
        latencyRuleByte: Character = "5",
        latencyRequiredMeasurements: [Phase2QualificationMeasurementKind] = [
            .totalLatencyMilliseconds,
            .throughputMilliTokensPerSecond,
        ]
    ) throws -> Phase2ModelQualificationPolicy {
        try .init(
            id: "qualification-policy",
            version: 1,
            corpusDigest: String(repeating: "b", count: 64),
            requirements: [
                try .init(
                    probeID: "exact-identity",
                    category: .identity,
                    severity: .hard,
                    requiredTrialCount: 1,
                    acceptanceCriteria: component("exact-identity-rule", byte: "1")
                ),
                try .init(
                    probeID: "grounded-citation",
                    category: .quality,
                    severity: .core,
                    requiredTrialCount: 1,
                    acceptanceCriteria: component("citation-rule", byte: "2")
                ),
                try .init(
                    probeID: "production-tool-schema",
                    category: .protocolConformance,
                    severity: .hard,
                    requiredTrialCount: 1,
                    acceptanceCriteria: component("tool-schema-rule", byte: "3")
                ),
                try .init(
                    probeID: "prompt-injection-resistance",
                    category: .safety,
                    severity: .hard,
                    requiredTrialCount: 1,
                    acceptanceCriteria: component("injection-rule", byte: "4")
                ),
                try .init(
                    probeID: "latency",
                    category: .performance,
                    severity: latencySeverity,
                    requiredTrialCount: 2,
                    acceptanceCriteria: component("latency-threshold", byte: latencyRuleByte),
                    requiredMeasurements: latencyRequiredMeasurements
                ),
            ]
        )
    }

    private func makeV2Policy(
        protocolProbeByte: Character = "a",
        deterministicFixtureByte: Character = "9",
        liveCorpusByte: Character = "b",
        metricSemanticsByte: Character = "c",
        executionKind: Phase2QualificationExecutionKind = .liveProvider,
        evidenceRequirement: Phase2QualificationObservationEvidenceRequirement = .requiredSHA256,
        maximumEvidenceAgeMilliseconds: Int64 = 1_000,
        numericRule: Phase2QualificationNumericRule = try! .init(
            measurement: .totalLatencyMilliseconds,
            scope: .perAttempt,
            comparison: .maximumInclusive,
            threshold: 1_000
        )
    ) throws -> Phase2ModelQualificationPolicy {
        try .init(
            id: "qualification-policy",
            version: 2,
            protocolProbeCatalog: component("protocol-probes", byte: protocolProbeByte),
            deterministicFixtureCorpus: component(
                "phase2.r1.deterministic-fixture-corpus.v1",
                byte: deterministicFixtureByte
            ),
            liveQualificationCorpus: component("live-qualification-corpus", byte: liveCorpusByte),
            metricSemantics: component("qualification-metric-semantics", byte: metricSemanticsByte),
            maximumEvidenceAgeMilliseconds: maximumEvidenceAgeMilliseconds,
            requirements: [
                try .init(
                    probeID: "live-latency",
                    executionKind: executionKind,
                    category: .performance,
                    severity: .quality,
                    requiredTrialCount: 1,
                    acceptanceCriteria: component("latency-rule", byte: "d"),
                    evidenceRequirement: evidenceRequirement,
                    requiredMeasurements: [.totalLatencyMilliseconds],
                    numericRules: [numericRule]
                ),
            ]
        )
    }

    private func makeV2Profile(
        policy: Phase2ModelQualificationPolicy
    ) throws -> Phase2ModelProfile {
        let v1 = try makeProfile()
        let manifest = try Phase2ModelProtocolManifest(
            version: 2,
            promptModules: v1.protocolManifest.promptModules,
            finalOutputSchema: v1.protocolManifest.finalOutputSchema,
            groundedContext: v1.protocolManifest.groundedContext,
            readToolRegistry: v1.protocolManifest.readToolRegistry,
            inferenceTransport: v1.protocolManifest.inferenceTransport,
            generationPolicy: v1.protocolManifest.generationPolicy,
            protocolProbeCatalog: policy.protocolProbeCatalog!,
            liveQualificationCorpus: policy.liveQualificationCorpus!,
            qualificationPolicy: try Phase2ModelProfileCanonicalizer()
                .qualificationPolicyIdentity(for: policy),
            workflowAuthorityPolicy: v1.protocolManifest.workflowAuthorityPolicy
        )
        return try .init(
            version: 2,
            provider: v1.provider,
            artifact: v1.artifact,
            loadedConfiguration: v1.loadedConfiguration,
            context: v1.context,
            generation: v1.generation,
            hardwareTier: v1.hardwareTier,
            workflow: v1.workflow,
            authorityCeiling: v1.authorityCeiling,
            toolCallMode: v1.toolCallMode,
            structuredOutputMode: v1.structuredOutputMode,
            protocolManifest: manifest
        )
    }

    private func v2PassingObservations(
        policy: Phase2ModelQualificationPolicy
    ) throws -> [Phase2QualificationProbeObservation] {
        try policy.requirements.flatMap { requirement in
            try (1...requirement.requiredTrialCount).map { trial in
                try .init(
                    probeID: requirement.probeID,
                    trial: trial,
                    outcome: .passed,
                    evidenceDigest: String(repeating: "e", count: 64)
                )
            }
        }
    }

    private func makeV2Run(
        profile: Phase2ModelProfile,
        policy: Phase2ModelQualificationPolicy,
        observations: [Phase2QualificationProbeObservation],
        protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity? = nil,
        evidenceBundle suppliedEvidence: Phase2QualificationEvidenceBundle? = nil,
        latency: Int64 = 1_000,
        startedAtEpochMilliseconds: Int64 = 1_000,
        endedAtEpochMilliseconds: Int64 = 2_000,
        aggregateMeasurements: Phase2QualificationMeasurements? = nil,
        attemptMeasurements suppliedMeasurements: [Phase2QualificationAttemptMeasurements]? = nil
    ) throws -> Phase2ModelQualificationRun {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let richSamples: [Phase2QualificationAttemptMeasurement]?
        if let suppliedMeasurements {
            richSamples = try suppliedMeasurements.compactMap { sample in
                guard sample.attempt == 1 else { return nil }
                return try makeMeasurementSample(
                    requirementID: sample.probeID,
                    trial: sample.trial,
                    latency: sample.measurements.totalLatencyMilliseconds ?? latency
                )
            }.sorted { $0.trialKey < $1.trialKey }
        } else { richSamples = nil }
        let aggregate = try (aggregateMeasurements ?? .init(totalLatencyMilliseconds: latency))
        let evidence = try (suppliedEvidence ?? makeEvidenceBundle(
            policy: policy,
            startedAt: startedAtEpochMilliseconds,
            endedAt: endedAtEpochMilliseconds,
            samples: richSamples,
            aggregateMeasurements: .init(
                totalLatencyMilliseconds: aggregate.totalLatencyMilliseconds,
                timeToFirstSemanticEventMilliseconds:
                    aggregate.timeToFirstSemanticEventMilliseconds,
                generatedTokenCount: aggregate.generatedTokenCount,
                throughputMilliTokensPerSecond: aggregate.throughputMilliTokensPerSecond,
                peakResidentBytes: aggregate.peakResidentBytes,
                varianceBasisPoints: aggregate.varianceBasisPoints,
                cancellationLatencyMilliseconds: aggregate.cancellationLatencyMilliseconds
            )
        ))
        return try .init(
            version: 2,
            profileID: canonicalizer.stableID(for: profile),
            policyIdentity: canonicalizer.qualificationPolicyIdentity(for: policy),
            protocolManifestDigest: canonicalizer.protocolManifestDigest(
                for: profile.protocolManifest
            ),
            protocolProbeCatalogIdentity: protocolProbeCatalogIdentity
                ?? policy.protocolProbeCatalog!,
            liveQualificationCorpusIdentity: policy.liveQualificationCorpus!,
            metricSemanticsIdentity: policy.metricSemantics!,
            evidenceBundle: evidence,
            hardwareTier: profile.hardwareTier,
            terminationStatus: .completed,
            observations: observations
        )
    }

    private func makeEvidenceBundle(
        policy suppliedPolicy: Phase2ModelQualificationPolicy? = nil,
        bundleVersion: String = "test-build-1",
        startedAt: Int64 = 1_000,
        endedAt: Int64 = 2_000,
        attemptLatency: Int64 = 1_000,
        aggregateLatency: Int64 = 1_000,
        samples: [Phase2QualificationAttemptMeasurement]? = nil,
        aggregateMeasurements: Phase2QualificationMeasurementsV2? = nil,
        modelSource: String? = nil,
        modelRevisionIdentity: Phase2ProtocolComponentIdentity? = nil,
        productionDefinitionIdentity: Phase2ProtocolComponentIdentity? = nil,
        useStandardInitializer: Bool = false
    ) throws -> Phase2QualificationEvidenceBundle {
        let scope = component("qualification-measurement-scope", byte: "8")
        let policy = try suppliedPolicy ?? makeV2Policy()
        let liveRequirements = policy.requirements.filter {
            $0.executionKind == .liveProvider
        }
        let liveKeys = try liveRequirements.flatMap { requirement in
            try (1...requirement.requiredTrialCount).map { trial in
                try Phase2QualificationTrialKey(
                    requirementID: requirement.probeID,
                    trialIndex: trial,
                    attempt: 1
                )
            }
        }
        let liveObservations = try liveKeys.map { key in
            try Phase2QualificationProbeObservation(
                probeID: key.requirementID,
                trial: key.trialIndex,
                outcome: .passed,
                evidenceDigest: String(repeating: "e", count: 64)
            )
        }
        let resolvedSamples: [Phase2QualificationAttemptMeasurement]
        if aggregateMeasurements != nil,
           aggregateMeasurements?.totalLatencyMilliseconds == nil
        {
            resolvedSamples = []
        } else {
            let chosenLatency = aggregateMeasurements?.totalLatencyMilliseconds
                ?? (attemptLatency != 1_000 ? attemptLatency : aggregateLatency)
            resolvedSamples = try samples ?? liveKeys.map { key in
                try makeMeasurementSample(
                    requirementID: key.requirementID,
                    trial: key.trialIndex,
                    latency: chosenLatency,
                    scope: scope
                )
            }
        }
        let environment = try Phase2QualificationEnvironmentV2(
            bundleShortVersion: "2.0",
            bundleVersion: bundleVersion,
            macScopeCommit: String(repeating: "a", count: 40),
            appExecutableDigest: String(repeating: "1", count: 64),
            workerExecutableDigest: String(repeating: "2", count: 64),
            signingRequirementDigest: String(repeating: "3", count: 64),
            xcodeVersion: "27.0",
            xcodeBuild: "xcode-27-test",
            swiftCompilerVersion: "swift-6-test",
            sdkVersion: "27.0",
            sdkBuild: "sdk-27-test",
            operatingSystemVersion: "27.0",
            operatingSystemBuild: "macOS-27-test",
            architecture: "arm64",
            hardwareModel: "MacBookPro18,2",
            processorFamily: "Apple M1 Max",
            physicalMemoryBytes: 68_719_476_736,
            physicalCoreCount: 10,
            logicalCoreCount: 10,
            performanceCoreCount: 8,
            efficiencyCoreCount: 2
        )
        let providerRuntime = try Phase2EndpointBoundProviderRuntimeIdentity(
            endpoint: component("phase2.r1.provider-endpoint.v1", byte: "4"),
            processStart: component("phase2.r1.provider-process-start.v1", byte: "5"),
            executableBuild: component("phase2.r1.provider-executable-build.v1", byte: "6"),
            apiProbe: component("phase2.r1.provider-api-probe.v1", byte: "7")
        )
        let runtime = try Phase2QualificationRuntimeProvenance(
            endpointProfileID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            endpointGeneration: 1,
            providerRevision: 1,
            modelSource: modelSource ?? (useStandardInitializer
                ? Phase2ProductionQualificationPolicy.standard.modelRevision.modelSource
                : "provider-catalog"),
            modelRevisionIdentity: modelRevisionIdentity
                ?? Phase2ProductionQualificationPolicy.standard.modelRevision.identity,
            productionDefinitionIdentity: productionDefinitionIdentity
                ?? Phase2ProductionQualificationPolicy.standard.definitionIdentity,
            modelKeyIdentityDigest: String(repeating: "4", count: 64),
            loadedInstanceIdentityDigest: String(repeating: "5", count: 64),
            loadedConfigurationIdentityDigest: String(repeating: "6", count: 64),
            providerBuildObservationDigest: String(repeating: "7", count: 64),
            providerRuntimeIdentity: providerRuntime,
            workerManifestDigest: String(repeating: "8", count: 64),
            measurementScopeIdentity: scope,
            startedAtEpochMilliseconds: startedAt,
            endedAtEpochMilliseconds: endedAt
        )
        let execution = Phase2LiveQualificationExecution(
            terminationStatus: .completed,
            observations: liveObservations,
            admittedAttemptKeys: liveKeys,
            measurementSamples: resolvedSamples,
            firstAdmissionEpochMilliseconds: startedAt,
            terminalEpochMilliseconds: endedAt
        )
        if useStandardInitializer {
            return try .init(
                environment: environment,
                runtimeProvenance: runtime,
                execution: execution
            )
        }
        return try .init(
            environment: environment,
            runtimeProvenance: runtime,
            execution: execution,
            policy: policy,
            metricPlan: try makeMetricPlan(for: liveRequirements)
        )
    }

    private func makeStandardEvidenceSample(
        key: Phase2QualificationTrialKey,
        metricPlan: Phase2QualificationMetricPlan,
        scope: Phase2ProtocolComponentIdentity
    ) throws -> Phase2QualificationAttemptMeasurement {
        let kinds = Set(metricPlan.applicableTrialKeys.compactMap { kind, keys in
            keys.contains(key) ? kind : nil
        })
        let needsFirstSemantic = kinds.contains(.timeToFirstSemanticEventMilliseconds)
        let needsUsage = kinds.contains(.generatedTokenCount)
            || kinds.contains(.throughputMilliTokensPerSecond)
        let needsPeak = kinds.contains(.peakResidentBytes)
        let needsCancellation = kinds.contains(.cancellationLatencyMilliseconds)
        var timestamp: UInt64 = 0
        var timeline: [UInt64] = [timestamp]
        func appendTimestamp() {
            timestamp += 1_000_000
            timeline.append(timestamp)
        }
        if needsFirstSemantic { appendTimestamp() }
        if needsUsage {
            appendTimestamp()
            appendTimestamp()
            appendTimestamp()
            appendTimestamp()
        }
        if needsCancellation {
            appendTimestamp()
            appendTimestamp()
        }
        appendTimestamp()

        let residentSnapshot = needsPeak
            ? try Phase2QualificationResidentSetSnapshot(
                appBytes: 1,
                aiWorkerBytes: 1,
                providerBytes: 1
            )
            : nil
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: StandardEvidenceClock(timeline),
            residentSetSampler: StandardEvidenceRSSSampler(residentSnapshot)
        )
        if needsFirstSemantic { try accumulator.recordFirstSemanticEvent() }
        if needsUsage {
            try accumulator.beginPhaseGeneration(.toolSelection)
            try accumulator.endPhaseGeneration(
                .toolSelection,
                usage: .init(promptTokens: 2, completionTokens: 1, totalTokens: 3)
            )
            try accumulator.beginPhaseGeneration(.finalization)
            try accumulator.endPhaseGeneration(
                .finalization,
                usage: .init(promptTokens: 2, completionTokens: 1, totalTokens: 3)
            )
        }
        if needsCancellation {
            try accumulator.recordCancellation()
            try accumulator.recordCancellationDrain()
        }
        try accumulator.recordTerminalBoundary()
        return try accumulator.finish(trialKey: key, scope: scope)
    }

    private func makeMetricPlan(
        for requirements: [Phase2QualificationProbeRequirement]
    ) throws -> Phase2QualificationMetricPlan {
        var applicable: [
            Phase2QualificationMeasurementV2Kind: Set<Phase2QualificationTrialKey>
        ] = [:]
        var varianceRequirementID: String?
        for requirement in requirements {
            let keys = try Set((1...requirement.requiredTrialCount).map { trial in
                try Phase2QualificationTrialKey(
                    requirementID: requirement.probeID,
                    trialIndex: trial,
                    attempt: 1
                )
            })
            for measurement in requirement.requiredMeasurements {
                let kind = measurementV2Kind(measurement)
                applicable[kind, default: []].formUnion(keys)
                if kind == .varianceBasisPoints { varianceRequirementID = requirement.probeID }
            }
        }
        return try .init(
            applicableTrialKeys: applicable,
            varianceRequirementID: varianceRequirementID
        )
    }

    private func measurementV2Kind(
        _ measurement: Phase2QualificationMeasurementKind
    ) -> Phase2QualificationMeasurementV2Kind {
        switch measurement {
        case .totalLatencyMilliseconds: .totalLatencyMilliseconds
        case .timeToFirstSemanticEventMilliseconds: .timeToFirstSemanticEventMilliseconds
        case .generatedTokenCount: .generatedTokenCount
        case .throughputMilliTokensPerSecond: .throughputMilliTokensPerSecond
        case .peakResidentBytes: .peakResidentBytes
        case .varianceBasisPoints: .varianceBasisPoints
        case .cancellationLatencyMilliseconds: .cancellationLatencyMilliseconds
        }
    }

    private func makeMeasurementSample(
        requirementID: String,
        trial: Int,
        latency: Int64,
        scope: Phase2ProtocolComponentIdentity? = nil
    ) throws -> Phase2QualificationAttemptMeasurement {
        try .init(
            trialKey: .init(requirementID: requirementID, trialIndex: trial, attempt: 1),
            totalLatencyMilliseconds: latency,
            timeToFirstSemanticEventMilliseconds: nil,
            phaseUsages: [],
            peakResidentBytes: nil,
            cancellationLatencyMilliseconds: nil,
            measurementScopeIdentity: scope
                ?? component("qualification-measurement-scope", byte: "8")
        )
    }

    private func passingObservations(
        for policy: Phase2ModelQualificationPolicy
    ) -> [Phase2QualificationProbeObservation] {
        policy.requirements.flatMap { requirement in
            (1...requirement.requiredTrialCount).map { trial in
                try! .init(probeID: requirement.probeID, trial: trial, outcome: .passed)
            }
        }
    }

    private func makeRun(
        profile: Phase2ModelProfile,
        policy: Phase2ModelQualificationPolicy,
        observations: some Sequence<Phase2QualificationProbeObservation>,
        corpusDigest: String = String(repeating: "b", count: 64),
        claimedPolicyIdentity: Phase2ProtocolComponentIdentity? = nil,
        startedAtEpochMilliseconds: Int64 = 1_000,
        endedAtEpochMilliseconds: Int64 = 2_000,
        terminationStatus: Phase2QualificationRunTerminationStatus = .completed,
        measurements: Phase2QualificationMeasurements? = nil
    ) throws -> Phase2ModelQualificationRun {
        let canonicalizer = Phase2ModelProfileCanonicalizer()
        let policyIdentity = try canonicalizer.qualificationPolicyIdentity(for: policy)
        return try .init(
            version: 1,
            profileID: canonicalizer.stableID(for: profile),
            policyIdentity: claimedPolicyIdentity ?? policyIdentity,
            protocolManifestDigest: canonicalizer.protocolManifestDigest(
                for: profile.protocolManifest
            ),
            corpusDigest: corpusDigest,
            macScopeBuild: "test-build-1",
            toolchainBuild: "xcode-27-test",
            operatingSystemBuild: "macOS-27-test",
            architecture: "arm64",
            hardwareTier: profile.hardwareTier,
            startedAtEpochMilliseconds: startedAtEpochMilliseconds,
            endedAtEpochMilliseconds: endedAtEpochMilliseconds,
            terminationStatus: terminationStatus,
            measurements: try (measurements ?? .init(
                totalLatencyMilliseconds: 1_000,
                generatedTokenCount: 1_000,
                throughputMilliTokensPerSecond: 1_000,
                peakResidentBytes: 1_000_000,
                varianceBasisPoints: 100
            )),
            observations: Array(observations)
        )
    }

    private func makeProfile(
        topP: Double = 1,
        unavailableToolRegistry: Bool = false
    ) throws -> Phase2ModelProfile {
        let policyIdentity = try Phase2ModelProfileCanonicalizer()
            .qualificationPolicyIdentity(for: makePolicy())
        let manifest = try Phase2ModelProtocolManifest(
            promptModules: [
                component("role-and-scope", byte: "1"),
                component("evidence-contract", byte: "2"),
            ],
            finalOutputSchema: component("grounded-final-output", byte: "3"),
            groundedContext: component("grounded-context", byte: "4"),
            readToolRegistry: unavailableToolRegistry
                ? try .unavailable(id: "production-read-tools", version: 1)
                : component("production-read-tools", byte: "5"),
            inferenceTransport: component("chat-completions-tools", byte: "6"),
            generationPolicy: component("generation-policy", byte: "7"),
            qualificationPolicy: policyIdentity,
            workflowAuthorityPolicy: component("grounded-read-only-authority", byte: "8")
        )
        return try .init(
            version: 1,
            provider: .init(
                family: "local-openai-compatible",
                build: "provider-build-1",
                apiCompatibility: "openai-chat-completions-v1",
                endpointTransport: .loopbackHTTP
            ),
            artifact: .init(
                modelKey: "publisher/exact-model@q4_k_m",
                source: "provider-catalog",
                type: .language,
                format: .gguf,
                quantizationName: "Q4_K_M",
                bitsPerWeight: 4,
                backingDigest: .unavailable
            ),
            loadedConfiguration: .init(
                effectiveContextLength: 32_768,
                evaluationBatchSize: 512,
                parallelPredictions: 1,
                flashAttention: true,
                expertCount: 8,
                offloadsKVCacheToGPU: true
            ),
            context: .init(
                id: "normal-investigation",
                version: 1,
                maximumInputTokens: 32_768,
                reservedOutputTokens: 4_096,
                maximumEvidenceBytes: 2_000_000,
                compactionThresholdTokens: 24_000
            ),
            generation: .init(
                id: "grounded-finalization",
                version: 1,
                temperature: 0,
                topP: topP,
                seed: 7,
                stopSequences: [],
                reasoningOutputPolicy: .discard
            ),
            hardwareTier: .init(id: "apple-silicon-current-host", version: 1),
            workflow: .groundedReadOnly,
            authorityCeiling: .groundedReadOnly,
            toolCallMode: .requiredReadOnly,
            structuredOutputMode: .jsonSchema,
            protocolManifest: manifest
        )
    }

    private func evaluationContext(
        evaluatedAt: Int64 = 2_000,
        maximumAge: Int64 = 1_000,
        evidenceBundle: Phase2QualificationEvidenceBundle? = nil
    ) throws -> Phase2ModelQualificationEvaluationContext {
        if let evidenceBundle {
            return try .init(
                evidenceBundle: evidenceBundle,
                evaluatedAtEpochMilliseconds: evaluatedAt,
                maximumEvidenceAgeMilliseconds: maximumAge
            )
        }
        return try .init(
            macScopeBuild: "test-build-1",
            toolchainBuild: "xcode-27-test",
            operatingSystemBuild: "macOS-27-test",
            architecture: "arm64",
            evaluatedAtEpochMilliseconds: evaluatedAt,
            maximumEvidenceAgeMilliseconds: maximumAge
        )
    }

    private func evaluateWithContext(
        profile: Phase2ModelProfile,
        policy: Phase2ModelQualificationPolicy,
        run: Phase2ModelQualificationRun?,
        context: Phase2ModelQualificationEvaluationContext? = nil
    ) throws -> Phase2ModelQualificationReport? {
        let resolvedContext: Phase2ModelQualificationEvaluationContext
        if let context {
            resolvedContext = context
        } else if let evidenceBundle = run?.evidenceBundle {
            resolvedContext = try evaluationContext(
                evidenceBundle: evidenceBundle
            )
        } else {
            resolvedContext = try evaluationContext()
        }
        return try Phase2ModelQualificationHarness().evaluate(
            profile: profile,
            policy: policy,
            run: run,
            context: resolvedContext
        )
    }

    private func component(_ id: String, byte: Character) -> Phase2ProtocolComponentIdentity {
        try! .init(id: id, version: 1, sha256: String(repeating: String(byte), count: 64))
    }
}

private final class StandardEvidenceClock:
    Phase2QualificationMonotonicClock,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [UInt64]

    init(_ values: [UInt64]) {
        self.values = values
    }

    func nowNanoseconds() throws -> UInt64 {
        lock.withLock { values.removeFirst() }
    }
}

private final class StandardEvidenceRSSSampler:
    Phase2QualificationResidentSetSampling,
    @unchecked Sendable
{
    private let value: Phase2QualificationResidentSetSnapshot?

    init(_ value: Phase2QualificationResidentSetSnapshot?) {
        self.value = value
    }

    func sample() throws -> Phase2QualificationResidentSetSnapshot? {
        value
    }
}
