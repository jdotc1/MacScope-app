import XCTest
@testable import MacScope

final class Phase2ProductionQualificationPolicyTests: XCTestCase {
    func testStandardDefinitionPinsExactModelRevisionHardwareAndFreshness() throws {
        let definition = Phase2ProductionQualificationPolicy.standard

        XCTAssertEqual(
            definition.modelRevision.modelSource,
            "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit"
        )
        XCTAssertEqual(
            definition.modelRevision.upstreamRevisionSHA1,
            "7c6ee1bbb5ee3051c4b3bc6553f24bdc2d01393a"
        )
        XCTAssertEqual(
            definition.modelRevision.localArtifactManifestSHA256,
            "49060c25bb8c4f63ef7471796832dc9e7c12b63e553472907ae27f05c7596ace"
        )
        XCTAssertEqual(
            definition.modelRevision.localArtifactManifestAlgorithm,
            "sorted-utf8-relative-path-size-file-sha256.v1"
        )
        XCTAssertEqual(
            definition.modelRevision.identity,
            try Phase2QualificationV2Identity.make(
                id: "phase2.r1.qwen3-coder-30b-a3b-instruct-8bit.model-revision.v1",
                version: 1,
                object: [
                    "local_artifact_manifest_algorithm":
                        "sorted-utf8-relative-path-size-file-sha256.v1",
                    "local_artifact_manifest_sha256":
                        "49060c25bb8c4f63ef7471796832dc9e7c12b63e553472907ae27f05c7596ace",
                    "model_source": "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit",
                    "upstream_revision_git_sha1":
                        "7c6ee1bbb5ee3051c4b3bc6553f24bdc2d01393a",
                    "version": 1,
                ]
            )
        )
        XCTAssertEqual(definition.hardwarePolicy, .thisM1Max64GiB)
        XCTAssertEqual(definition.environmentPolicy.requiredXcodeMajorVersion, 27)
        XCTAssertEqual(definition.environmentPolicy.requiredSDKMajorVersion, 27)
        XCTAssertEqual(definition.environmentPolicy.minimumMacOSMajorVersion, 27)
        XCTAssertEqual(definition.environmentPolicy.requiredArchitecture, "arm64")
        XCTAssertEqual(definition.policy.maximumEvidenceAgeMilliseconds, 300_000)
    }

    func testPolicyHasExactCanonicalRequirementOrderAndTrialCount() throws {
        let definition = Phase2ProductionQualificationPolicy.standard
        let deterministicIDs = definition.protocolProbeCatalog.probes.map(\.id)
        let liveIDs = definition.liveScenarioCatalog.scenarios.map(\.id)

        XCTAssertEqual(definition.deterministicRequirements.count, 99)
        XCTAssertEqual(definition.liveRequirements.count, 20)
        XCTAssertEqual(definition.policy.requirements.count, 119)
        XCTAssertEqual(definition.policy.declaredTrialCount, 163)
        XCTAssertEqual(
            definition.policy.requirements.map(\.probeID),
            deterministicIDs + liveIDs
        )
        XCTAssertEqual(definition.policy.id, "phase2.r1.qualification-policy.v2")
        XCTAssertEqual(definition.policy.version, 2)
        XCTAssertEqual(
            definition.policy.protocolProbeCatalog,
            definition.protocolProbeCatalogIdentity
        )
        XCTAssertEqual(
            definition.policy.deterministicFixtureCorpus,
            definition.deterministicFixtureCorpusIdentity
        )
        XCTAssertEqual(
            definition.deterministicFixtureCorpusIdentity.sha256,
            "a0d3fdecde2d39f0723ec2f2a5f65aa6f5be5942b8fc18671a4114bace4eb27f"
        )
        XCTAssertEqual(
            definition.policy.liveQualificationCorpus,
            definition.liveScenarioCatalog.identity
        )
        XCTAssertEqual(definition.policy.metricSemantics, definition.metricSemanticsIdentity)
        XCTAssertEqual(
            definition.policyIdentity,
            try Phase2ModelProfileCanonicalizer().qualificationPolicyIdentity(
                for: definition.policy
            )
        )
        XCTAssertEqual(
            definition.policyIdentity.sha256,
            "f4e0d43b2b975840686c302740fe946578619eab309896e183225c65e1747559"
        )
        XCTAssertEqual(
            definition.definitionIdentity,
            try Phase2QualificationV2Identity.make(
                id: "phase2.r1.standard-qualification-definition.v1",
                version: 1,
                object: [
                    "deterministic_fixture_corpus": componentObject(
                        definition.deterministicFixtureCorpusIdentity
                    ),
                    "environment_policy": componentObject(
                        definition.environmentPolicy.identity
                    ),
                    "live_qualification_corpus": componentObject(
                        definition.liveScenarioCatalog.identity
                    ),
                    "metric_semantics": componentObject(
                        definition.metricSemanticsIdentity
                    ),
                    "model_revision": componentObject(
                        definition.modelRevision.identity
                    ),
                    "protocol_probe_catalog": componentObject(
                        definition.protocolProbeCatalogIdentity
                    ),
                    "qualification_policy": componentObject(
                        definition.policyIdentity
                    ),
                    "threshold_set": componentObject(
                        definition.thresholdSet.identity
                    ),
                    "version": 1,
                ]
            )
        )
        XCTAssertEqual(
            definition.definitionIdentity.sha256,
            "8f17c3acd8e42c50d942108e26ae3342953196d6c910a33b0aa06a0821b05523"
        )
    }

    func testDeterministicPartitionIsExactSevenSixtyTwoThirty() {
        let requirements = Phase2ProductionQualificationPolicy.standard
            .deterministicRequirements
        let safetyIDs: Set<String> = [
            "tool.atomic.id-mutation",
            "tool.atomic.type-mutation",
            "tool.atomic.name-mutation",
            "tool.argument.unknown",
            "tool.argument.duplicate",
            "tool.proposal.unoffered-name",
            "tool.proposal.invented-handle",
            "tool.proposal.repeated-handle",
            "tool.proposal.duplicate-call-id",
            "tool.output.content",
            "tool.output.final-answer",
            "tool.record.after-terminal",
            "tool.cancellation.partial",
            "final.evidence-id.lowercase",
            "final.evidence-id.mixed-case",
            "final.evidence-id.braced",
            "final.evidence-id.hyphenless",
            "final.evidence-id.padded",
            "final.evidence-id.other-parseable",
            "final.field.unknown",
            "final.field.duplicate",
            "final.variant.mixed",
            "final.citation.bad",
            "final.citation.duplicate",
            "final.citation.unallowed",
            "final.truncation",
            "final.prompt-injection-as-data",
            "final.tool-call",
            "limit.event-plus-one",
            "limit.cumulative-event-plus-one",
        ]

        XCTAssertEqual(requirements.filter { $0.category == .identity }.count, 7)
        XCTAssertEqual(
            requirements.filter { $0.category == .protocolConformance }.count,
            62
        )
        XCTAssertEqual(requirements.filter { $0.category == .safety }.count, 30)
        XCTAssertEqual(
            Set(requirements.filter { $0.category == .identity }.map(\.probeID)),
            Set(requirements.map(\.probeID).filter { $0.hasPrefix("identity.") })
        )
        XCTAssertEqual(
            Set(requirements.filter { $0.category == .safety }.map(\.probeID)),
            safetyIDs
        )
        XCTAssertTrue(requirements.allSatisfy {
            $0.executionKind == .deterministicFixture
                && $0.severity == .hard
                && $0.requiredTrialCount == 1
                && $0.evidenceRequirement == .requiredSHA256
                && $0.requiredMeasurements.isEmpty
                && $0.numericRules.isEmpty
        })
    }

    func testDeterministicCriteriaBindExactCatalogDescriptorAndTypedOutcome() throws {
        let definition = Phase2ProductionQualificationPolicy.standard
        let requirements = Dictionary(
            uniqueKeysWithValues: definition.deterministicRequirements.map {
                ($0.probeID, $0)
            }
        )

        for probe in definition.protocolProbeCatalog.probes {
            let expected = try Phase2QualificationV2Identity.make(
                id: "\(probe.id).acceptance-criteria",
                version: 1,
                object: [
                    "acceptance_criterion": probe.acceptanceCriterion,
                    "catalog_identity": componentObject(
                        definition.protocolProbeCatalogIdentity
                    ),
                    "fixture_id": probe.fixtureID.rawValue,
                    "oracle": [
                        "expected_outcome": probe.expectedOutcome.rawValue,
                        "kind": "exact-closed-outcome",
                        "version": 1,
                    ] as [String: Any],
                    "probe_category": probe.category.rawValue,
                    "probe_id": probe.id,
                    "version": 1,
                ]
            )
            XCTAssertEqual(requirements[probe.id]?.acceptanceCriteria, expected, probe.id)
        }
    }

    func testLiveRequirementsBindExactScenarioOracleCategoryTrialAndSeverity() {
        let definition = Phase2ProductionQualificationPolicy.standard

        XCTAssertEqual(definition.liveScenarioCatalog.scenarios.map(\.trialCount),
                       Array(repeating: 3, count: 18) + [5, 5])
        for (scenario, requirement) in zip(
            definition.liveScenarioCatalog.scenarios,
            definition.liveRequirements
        ) {
            let expectedSeverity: Phase2QualificationProbeSeverity = switch scenario.category {
            case .identity, .protocolConformance, .safety: .hard
            case .quality, .performance: .quality
            }
            XCTAssertEqual(requirement.probeID, scenario.id)
            XCTAssertEqual(requirement.executionKind, .liveProvider)
            XCTAssertEqual(requirement.category, scenario.category)
            XCTAssertEqual(requirement.severity, expectedSeverity)
            XCTAssertEqual(requirement.requiredTrialCount, scenario.trialCount)
            XCTAssertEqual(requirement.acceptanceCriteria, scenario.acceptanceCriteriaIdentity)
            XCTAssertEqual(requirement.evidenceRequirement, .requiredSHA256)
        }
    }

    func testThresholdsAndMetricSemanticsUseExactRequirementScopes() throws {
        let definition = Phase2ProductionQualificationPolicy.standard
        let expected: [Phase2ProductionQualificationThreshold] = [
            try .init(
                requirementID: "live.performance.standard-turn",
                measurement: .totalLatencyMilliseconds,
                scope: .perAttempt,
                comparison: .maximumInclusive,
                threshold: 120_000
            ),
            try .init(
                requirementID: "live.performance.standard-turn",
                measurement: .timeToFirstSemanticEventMilliseconds,
                scope: .perAttempt,
                comparison: .maximumInclusive,
                threshold: 30_000
            ),
            try .init(
                requirementID: "live.performance.standard-turn",
                measurement: .throughputMilliTokensPerSecond,
                scope: .perAttempt,
                comparison: .minimumInclusive,
                threshold: 5_000
            ),
            try .init(
                requirementID: "live.performance.standard-turn",
                measurement: .peakResidentBytes,
                scope: .runAggregate,
                comparison: .maximumInclusive,
                threshold: 60_129_542_144
            ),
            try .init(
                requirementID: "live.performance.repeated-run-variance",
                measurement: .varianceBasisPoints,
                scope: .runAggregate,
                comparison: .maximumInclusive,
                threshold: 2_500
            ),
            try .init(
                requirementID: "live.safety.cancellation-without-semantic-output",
                measurement: .cancellationLatencyMilliseconds,
                scope: .perAttempt,
                comparison: .maximumInclusive,
                threshold: 2_000
            ),
        ]
        XCTAssertEqual(definition.thresholdSet.id,
                       "phase2.r1.m1-max-64g.standard-thresholds.v1")
        XCTAssertEqual(definition.thresholdSet.version, 1)
        XCTAssertEqual(definition.thresholdSet.thresholds, expected)
        XCTAssertEqual(
            definition.thresholdSet.identity,
            try Phase2QualificationV2Identity.make(
                id: definition.thresholdSet.id,
                version: definition.thresholdSet.version,
                object: [
                    "hardware": [
                        "efficiency_core_count": 2,
                        "hardware_model": "MacBookPro18,2",
                        "logical_core_count": 10,
                        "performance_core_count": 8,
                        "physical_core_count": 10,
                        "physical_memory_bytes": Int64(68_719_476_736),
                        "processor_family": "Apple M1 Max",
                    ] as [String: Any],
                    "thresholds": expected.map(thresholdObject),
                    "version": 1,
                ]
            )
        )

        let standardKeys = Set(try (1...5).map {
            try Phase2QualificationTrialKey(
                requirementID: "live.performance.standard-turn",
                trialIndex: $0,
                attempt: 1
            )
        })
        let varianceKeys = Set(try (1...5).map {
            try Phase2QualificationTrialKey(
                requirementID: "live.performance.repeated-run-variance",
                trialIndex: $0,
                attempt: 1
            )
        })
        let cancellationKeys = Set(try (1...3).map {
            try Phase2QualificationTrialKey(
                requirementID: "live.safety.cancellation-without-semantic-output",
                trialIndex: $0,
                attempt: 1
            )
        })
        XCTAssertEqual(definition.metricPlan.applicableTrialKeys, [
            .totalLatencyMilliseconds: standardKeys,
            .timeToFirstSemanticEventMilliseconds: standardKeys,
            .generatedTokenCount: standardKeys,
            .throughputMilliTokensPerSecond: standardKeys,
            .peakResidentBytes: standardKeys,
            .varianceBasisPoints: varianceKeys,
            .cancellationLatencyMilliseconds: cancellationKeys,
        ])
        XCTAssertEqual(
            definition.metricPlan.varianceRequirementID,
            "live.performance.repeated-run-variance"
        )
        XCTAssertEqual(definition.metricSemantics.entries.map(\.measurement),
                       Phase2QualificationMeasurementV2Kind.allCases)
        XCTAssertEqual(definition.metricSemanticsIdentity,
                       definition.metricSemantics.identity)
        XCTAssertNotEqual(
            definition.metricSemanticsIdentity,
            try definition.metricPlan.contentIdentity(),
            "production semantics must bind formula/unit/scope/rounding/completeness"
        )
        XCTAssertEqual(
            try definition.metricPlan.contentIdentity().id,
            "phase2.r1.qualification-metric-plan.v2"
        )
        XCTAssertEqual(
            definition.metricSemanticsIdentity.id,
            "phase2.r1.qualification-metric-semantics.v2"
        )
        for entry in definition.metricSemantics.entries {
            XCTAssertEqual(
                entry.applicableTrialKeys,
                definition.metricPlan.applicableTrialKeys[entry.measurement]
            )
        }

        let semanticsByKind = Dictionary(
            uniqueKeysWithValues: definition.metricSemantics.entries.map {
                ($0.measurement, $0)
            }
        )
        XCTAssertEqual(semanticsByKind[.totalLatencyMilliseconds]?.numericScope, .perAttempt)
        XCTAssertEqual(semanticsByKind[.totalLatencyMilliseconds]?.unit, .milliseconds)
        XCTAssertEqual(semanticsByKind[.totalLatencyMilliseconds]?.aggregation, .checkedSum)
        XCTAssertEqual(semanticsByKind[.timeToFirstSemanticEventMilliseconds]?.rounding,
                       .downToWholeMilliseconds)
        XCTAssertEqual(semanticsByKind[.generatedTokenCount]?.unit, .tokens)
        XCTAssertEqual(semanticsByKind[.throughputMilliTokensPerSecond]?.scale, 1_000_000)
        XCTAssertEqual(semanticsByKind[.throughputMilliTokensPerSecond]?.rounding,
                       .integerDivisionTowardZero)
        XCTAssertEqual(semanticsByKind[.peakResidentBytes]?.numericScope, .runAggregate)
        XCTAssertEqual(semanticsByKind[.peakResidentBytes]?.aggregation, .maximum)
        XCTAssertEqual(semanticsByKind[.peakResidentBytes]?.completeness,
                       .exactThreeProcessScopeEverySample)
        XCTAssertEqual(semanticsByKind[.varianceBasisPoints]?.numericScope, .runAggregate)
        XCTAssertEqual(semanticsByKind[.varianceBasisPoints]?.aggregation,
                       .populationCoefficientOfVariation)
        XCTAssertEqual(semanticsByKind[.varianceBasisPoints]?.scale, 10_000)
        XCTAssertEqual(semanticsByKind[.varianceBasisPoints]?.rounding,
                       .nearestOrAwayFromZero)
        XCTAssertEqual(semanticsByKind[.varianceBasisPoints]?.completeness,
                       .exactlyFivePassedDeclaredTrials)
        XCTAssertEqual(semanticsByKind[.cancellationLatencyMilliseconds]?.completeness,
                       .controlledCancellationThroughTerminalDrain)

        let rules = Dictionary(
            uniqueKeysWithValues: definition.liveRequirements.map {
                ($0.probeID, $0.numericRules)
            }
        )
        XCTAssertEqual(
            rules["live.performance.standard-turn"],
            expected.filter { $0.requirementID == "live.performance.standard-turn" }
                .map(\.rule)
        )
        XCTAssertEqual(
            rules["live.performance.repeated-run-variance"],
            expected.filter {
                $0.requirementID == "live.performance.repeated-run-variance"
            }.map(\.rule)
        )
        XCTAssertEqual(
            rules["live.safety.cancellation-without-semantic-output"],
            expected.filter {
                $0.requirementID == "live.safety.cancellation-without-semantic-output"
            }.map(\.rule)
        )
    }

    func testCanonicalIdentityChangesForCriteriaThresholdAndMetricApplicabilityDrift() throws {
        let definition = Phase2ProductionQualificationPolicy.standard
        let canonicalizer = Phase2ModelProfileCanonicalizer()

        let deterministicFixtureDriftPolicy = try makePolicy(
            definition: definition,
            requirements: definition.policy.requirements,
            deterministicFixtureCorpus: try .init(
                id: definition.deterministicFixtureCorpusIdentity.id,
                version: definition.deterministicFixtureCorpusIdentity.version,
                sha256: String(repeating: "f", count: 64)
            )
        )
        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(
                for: deterministicFixtureDriftPolicy
            ),
            definition.policyIdentity
        )

        var criteriaDriftRequirements = definition.policy.requirements
        let original = criteriaDriftRequirements[0]
        criteriaDriftRequirements[0] = try Phase2QualificationProbeRequirement(
            probeID: original.probeID,
            executionKind: original.executionKind!,
            category: original.category,
            severity: original.severity,
            requiredTrialCount: original.requiredTrialCount,
            acceptanceCriteria: try Phase2QualificationV2Identity.make(
                id: original.acceptanceCriteria.id,
                version: original.acceptanceCriteria.version,
                object: ["drift": true]
            ),
            evidenceRequirement: original.evidenceRequirement!,
            requiredMeasurements: original.requiredMeasurements,
            numericRules: original.numericRules
        )
        let criteriaDriftPolicy = try makePolicy(
            definition: definition,
            requirements: criteriaDriftRequirements
        )
        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(for: criteriaDriftPolicy),
            definition.policyIdentity
        )

        var thresholdDriftRequirements = definition.policy.requirements
        let performanceIndex = try XCTUnwrap(thresholdDriftRequirements.firstIndex {
            $0.probeID == "live.performance.standard-turn"
        })
        let performance = thresholdDriftRequirements[performanceIndex]
        let changedRules = try performance.numericRules.map { rule in
            try Phase2QualificationNumericRule(
                measurement: rule.measurement,
                scope: rule.scope,
                comparison: rule.comparison,
                threshold: rule.measurement == .totalLatencyMilliseconds
                    ? rule.threshold + 1 : rule.threshold
            )
        }
        thresholdDriftRequirements[performanceIndex] = try Phase2QualificationProbeRequirement(
            probeID: performance.probeID,
            executionKind: performance.executionKind!,
            category: performance.category,
            severity: performance.severity,
            requiredTrialCount: performance.requiredTrialCount,
            acceptanceCriteria: performance.acceptanceCriteria,
            evidenceRequirement: performance.evidenceRequirement!,
            requiredMeasurements: changedRules.map(\.measurement),
            numericRules: changedRules
        )
        XCTAssertNotEqual(
            try canonicalizer.qualificationPolicyIdentity(for: makePolicy(
                definition: definition,
                requirements: thresholdDriftRequirements
            )),
            definition.policyIdentity
        )

        var applicability = definition.metricPlan.applicableTrialKeys
        applicability[.generatedTokenCount] = Set(applicability[.generatedTokenCount]!.dropFirst())
        let metricDrift = try Phase2QualificationMetricPlan(
            applicableTrialKeys: applicability,
            varianceRequirementID: definition.metricPlan.varianceRequirementID
        )
        let driftedMetricSemantics = try Phase2ProductionQualificationMetricSemantics(
            metricPlan: metricDrift,
            thresholds: definition.thresholdSet.thresholds
        )
        XCTAssertNotEqual(driftedMetricSemantics.identity, definition.metricSemanticsIdentity)
    }

    private func makePolicy(
        definition: Phase2ProductionQualificationPolicy,
        requirements: [Phase2QualificationProbeRequirement],
        deterministicFixtureCorpus: Phase2ProtocolComponentIdentity? = nil
    ) throws -> Phase2ModelQualificationPolicy {
        try .init(
            id: definition.policy.id,
            version: definition.policy.version,
            protocolProbeCatalog: definition.protocolProbeCatalogIdentity,
            deterministicFixtureCorpus: deterministicFixtureCorpus
                ?? definition.deterministicFixtureCorpusIdentity,
            liveQualificationCorpus: definition.liveScenarioCatalog.identity,
            metricSemantics: definition.metricSemanticsIdentity,
            maximumEvidenceAgeMilliseconds: definition.policy.maximumEvidenceAgeMilliseconds!,
            requirements: requirements
        )
    }

    private func componentObject(
        _ identity: Phase2ProtocolComponentIdentity
    ) -> [String: Any] {
        [
            "id": identity.id,
            "sha256": identity.sha256!,
            "version": identity.version,
        ]
    }

    private func thresholdObject(
        _ threshold: Phase2ProductionQualificationThreshold
    ) -> [String: Any] {
        [
            "comparison": threshold.rule.comparison.rawValue,
            "measurement": threshold.rule.measurement.rawValue,
            "requirement_id": threshold.requirementID,
            "scope": threshold.rule.scope.rawValue,
            "threshold": threshold.rule.threshold,
        ]
    }
}
