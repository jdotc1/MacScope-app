import Foundation

/// Exact, content-addressed model artifact revision selected before live qualification.
/// Paths and host/user identifiers are intentionally excluded.
struct Phase2ProductionModelRevisionIdentity: Hashable, Sendable {
    let modelSource: String
    let upstreamRevisionSHA1: String
    let localArtifactManifestSHA256: String
    let localArtifactManifestAlgorithm: String
    let identity: Phase2ProtocolComponentIdentity

    fileprivate init(
        identityID: String = "phase2.r1.qwen3-coder-30b-a3b-instruct-8bit.model-revision.v1",
        modelSource: String,
        upstreamRevisionSHA1: String,
        localArtifactManifestSHA256: String,
        localArtifactManifestAlgorithm: String
    ) throws {
        guard Self.isLowercaseHex(upstreamRevisionSHA1, count: 40),
              phase2IsSHA256Hex(localArtifactManifestSHA256),
              phase2IsBoundedIdentifier(modelSource, maximumBytes: 256),
              phase2IsCategoricalToken(localArtifactManifestAlgorithm)
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.modelSource = modelSource
        self.upstreamRevisionSHA1 = upstreamRevisionSHA1
        self.localArtifactManifestSHA256 = localArtifactManifestSHA256
        self.localArtifactManifestAlgorithm = localArtifactManifestAlgorithm
        identity = try Phase2QualificationV2Identity.make(
            id: identityID,
            version: 1,
            object: [
                "local_artifact_manifest_algorithm": localArtifactManifestAlgorithm,
                "local_artifact_manifest_sha256": localArtifactManifestSHA256,
                "model_source": modelSource,
                "upstream_revision_git_sha1": upstreamRevisionSHA1,
                "version": 1,
            ]
        )
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

/// Build-number-flexible toolchain/OS policy plus the exact declared hardware tier.
/// Exact observed build identities remain run evidence; this policy freezes compatibility bounds.
struct Phase2ProductionQualificationEnvironmentPolicy: Hashable, Sendable {
    let requiredXcodeMajorVersion: Int
    let requiredSDKMajorVersion: Int
    let minimumMacOSMajorVersion: Int
    let requiredArchitecture: String
    let hardwarePolicy: Phase2QualificationHardwarePolicy
    let identity: Phase2ProtocolComponentIdentity

    fileprivate init(
        requiredXcodeMajorVersion: Int,
        requiredSDKMajorVersion: Int,
        minimumMacOSMajorVersion: Int,
        requiredArchitecture: String,
        hardwarePolicy: Phase2QualificationHardwarePolicy
    ) throws {
        guard requiredXcodeMajorVersion == 27,
              requiredSDKMajorVersion == 27,
              minimumMacOSMajorVersion == 27,
              requiredArchitecture == "arm64"
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.requiredXcodeMajorVersion = requiredXcodeMajorVersion
        self.requiredSDKMajorVersion = requiredSDKMajorVersion
        self.minimumMacOSMajorVersion = minimumMacOSMajorVersion
        self.requiredArchitecture = requiredArchitecture
        self.hardwarePolicy = hardwarePolicy
        identity = try Phase2QualificationV2Identity.make(
            id: "phase2.r1.m1-max-64g.qualification-environment-policy.v1",
            version: 1,
            object: [
                "hardware": Self.hardwareObject(hardwarePolicy),
                "minimum_macos_major_version": minimumMacOSMajorVersion,
                "required_architecture": requiredArchitecture,
                "required_sdk_major_version": requiredSDKMajorVersion,
                "required_xcode_major_version": requiredXcodeMajorVersion,
                "version": 1,
            ]
        )
    }

    func accepts(_ environment: Phase2QualificationEnvironmentV2) -> Bool {
        Self.majorVersion(in: environment.xcodeVersion) == requiredXcodeMajorVersion
            && Self.majorVersion(in: environment.sdkVersion) == requiredSDKMajorVersion
            && (Self.majorVersion(in: environment.operatingSystemVersion) ?? -1)
                >= minimumMacOSMajorVersion
            && environment.architecture == requiredArchitecture
            && environment.hardwareModel == hardwarePolicy.hardwareModel
            && environment.processorFamily == hardwarePolicy.processorFamily
            && environment.physicalMemoryBytes == hardwarePolicy.physicalMemoryBytes
            && environment.physicalCoreCount == hardwarePolicy.physicalCoreCount
            && environment.logicalCoreCount == hardwarePolicy.logicalCoreCount
            && environment.performanceCoreCount == hardwarePolicy.performanceCoreCount
            && environment.efficiencyCoreCount == hardwarePolicy.efficiencyCoreCount
    }

    fileprivate static func hardwareObject(
        _ hardware: Phase2QualificationHardwarePolicy
    ) -> [String: Any] {
        [
            "efficiency_core_count": hardware.efficiencyCoreCount,
            "hardware_model": hardware.hardwareModel,
            "logical_core_count": hardware.logicalCoreCount,
            "performance_core_count": hardware.performanceCoreCount,
            "physical_core_count": hardware.physicalCoreCount,
            "physical_memory_bytes": Int64(hardware.physicalMemoryBytes),
            "processor_family": hardware.processorFamily,
        ]
    }

    private static func majorVersion(in value: String) -> Int? {
        let firstDigits = value.split(whereSeparator: { !$0.isNumber }).first
        return firstDigits.flatMap { Int($0) }
    }
}

struct Phase2ProductionQualificationThreshold: Hashable, Sendable {
    let requirementID: String
    let rule: Phase2QualificationNumericRule

    init(
        requirementID: String,
        measurement: Phase2QualificationMeasurementKind,
        scope: Phase2QualificationNumericScope,
        comparison: Phase2QualificationNumericComparison,
        threshold: Int64
    ) throws {
        guard phase2IsCategoricalToken(requirementID, maximumBytes: 128) else {
            throw Phase2ModelProfileValidationError.invalidIdentifier
        }
        self.requirementID = requirementID
        rule = try .init(
            measurement: measurement,
            scope: scope,
            comparison: comparison,
            threshold: threshold
        )
    }
}

struct Phase2ProductionQualificationThresholdSet: Hashable, Sendable {
    let id: String
    let version: Int
    let hardwarePolicy: Phase2QualificationHardwarePolicy
    let thresholds: [Phase2ProductionQualificationThreshold]
    let identity: Phase2ProtocolComponentIdentity

    fileprivate init(
        id: String,
        version: Int,
        hardwarePolicy: Phase2QualificationHardwarePolicy,
        thresholds: [Phase2ProductionQualificationThreshold]
    ) throws {
        guard id == "phase2.r1.m1-max-64g.standard-thresholds.v1", version == 1,
              thresholds.count == 6,
              Set(thresholds.map { $0.rule.measurement }).count == thresholds.count
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.id = id
        self.version = version
        self.hardwarePolicy = hardwarePolicy
        self.thresholds = thresholds
        identity = try Phase2QualificationV2Identity.make(
            id: id,
            version: version,
            object: [
                "hardware": Phase2ProductionQualificationEnvironmentPolicy.hardwareObject(
                    hardwarePolicy
                ),
                "thresholds": thresholds.map(Self.canonicalObject),
                "version": version,
            ]
        )
    }

    func thresholds(for requirementID: String) -> [Phase2ProductionQualificationThreshold] {
        thresholds.filter { $0.requirementID == requirementID }
    }

    private static func canonicalObject(
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

enum Phase2ProductionQualificationMetricUnit: String, Hashable, Sendable {
    case milliseconds
    case tokens
    case milliTokensPerSecond = "milli-tokens-per-second"
    case bytes
    case basisPoints = "basis-points"
}

enum Phase2ProductionQualificationMetricAggregation: String, Hashable, Sendable {
    case checkedSum = "checked-sum"
    case ratioOfCheckedSums = "ratio-of-checked-sums"
    case maximum
    case populationCoefficientOfVariation = "population-coefficient-of-variation"
}

enum Phase2ProductionQualificationMetricRounding: String, Hashable, Sendable {
    case exactInteger = "exact-integer"
    case downToWholeMilliseconds = "down-to-whole-milliseconds"
    case integerDivisionTowardZero = "integer-division-toward-zero"
    case nearestOrAwayFromZero = "nearest-or-away-from-zero"
}

enum Phase2ProductionQualificationMetricCompleteness: String, Hashable, Sendable {
    case everyApplicableSample = "every-applicable-sample"
    case completeProviderUsageAndPositiveGenerationDuration =
        "complete-provider-usage-and-positive-generation-duration"
    case exactThreeProcessScopeEverySample = "exact-three-process-scope-every-sample"
    case exactlyFivePassedDeclaredTrials = "exactly-five-passed-declared-trials"
    case controlledCancellationThroughTerminalDrain =
        "controlled-cancellation-through-terminal-drain"
}

struct Phase2ProductionQualificationMetricSemanticsEntry: Hashable, Sendable {
    let measurement: Phase2QualificationMeasurementV2Kind
    let numericScope: Phase2QualificationNumericScope
    let applicableTrialKeys: Set<Phase2QualificationTrialKey>
    let unit: Phase2ProductionQualificationMetricUnit
    let aggregation: Phase2ProductionQualificationMetricAggregation
    let formulaID: String
    let scale: Int64
    let rounding: Phase2ProductionQualificationMetricRounding
    let completeness: Phase2ProductionQualificationMetricCompleteness
}

/// The existing metric plan schedules samples. This stronger identity additionally binds the
/// exact formula, unit, scale, rounding, completeness, and numeric evaluation scope.
struct Phase2ProductionQualificationMetricSemantics: Sendable {
    let entries: [Phase2ProductionQualificationMetricSemanticsEntry]
    let identity: Phase2ProtocolComponentIdentity

    init(
        metricPlan: Phase2QualificationMetricPlan,
        thresholds: [Phase2ProductionQualificationThreshold]
    ) throws {
        let scopes = Dictionary(
            grouping: thresholds,
            by: { Self.v2Kind(for: $0.rule.measurement) }
        ).mapValues { values -> Phase2QualificationNumericScope in
            precondition(Set(values.map { $0.rule.scope }).count == 1)
            return values[0].rule.scope
        }
        entries = try Phase2QualificationMeasurementV2Kind.allCases.map { measurement in
            guard let keys = metricPlan.applicableTrialKeys[measurement], !keys.isEmpty else {
                throw Phase2QualificationMeasurementV2Error.invalidMetricPlan
            }
            let description = Self.description(for: measurement)
            return .init(
                measurement: measurement,
                numericScope: scopes[measurement] ?? .perAttempt,
                applicableTrialKeys: keys,
                unit: description.unit,
                aggregation: description.aggregation,
                formulaID: description.formulaID,
                scale: description.scale,
                rounding: description.rounding,
                completeness: description.completeness
            )
        }
        identity = try Phase2QualificationV2Identity.make(
            id: "phase2.r1.qualification-metric-semantics.v2",
            version: 2,
            object: [
                "metrics": entries.map(Self.canonicalObject),
                "variance_requirement_id": metricPlan.varianceRequirementID
                    .map { $0 as Any } ?? NSNull(),
                "version": 2,
            ]
        )
    }

    private static func description(
        for measurement: Phase2QualificationMeasurementV2Kind
    ) -> (
        unit: Phase2ProductionQualificationMetricUnit,
        aggregation: Phase2ProductionQualificationMetricAggregation,
        formulaID: String,
        scale: Int64,
        rounding: Phase2ProductionQualificationMetricRounding,
        completeness: Phase2ProductionQualificationMetricCompleteness
    ) {
        switch measurement {
        case .totalLatencyMilliseconds:
            return (
                .milliseconds, .checkedSum,
                "continuous-clock.admission-through-final-lease-revalidation.v1",
                1, .downToWholeMilliseconds, .everyApplicableSample
            )
        case .timeToFirstSemanticEventMilliseconds:
            return (
                .milliseconds, .checkedSum,
                "continuous-clock.admission-to-first-semantic-event.v1",
                1, .downToWholeMilliseconds, .everyApplicableSample
            )
        case .generatedTokenCount:
            return (
                .tokens, .checkedSum,
                "provider-usage.checked-completion-token-sum-across-phases.v1",
                1, .exactInteger, .completeProviderUsageAndPositiveGenerationDuration
            )
        case .throughputMilliTokensPerSecond:
            return (
                .milliTokensPerSecond, .ratioOfCheckedSums,
                "completion-tokens-times-1000000-divided-by-generation-milliseconds.v1",
                1_000_000, .integerDivisionTowardZero,
                .completeProviderUsageAndPositiveGenerationDuration
            )
        case .peakResidentBytes:
            return (
                .bytes, .maximum,
                "max-contemporaneous-app-ai-worker-endpoint-provider-rss.v1",
                1, .exactInteger, .exactThreeProcessScopeEverySample
            )
        case .varianceBasisPoints:
            return (
                .basisPoints, .populationCoefficientOfVariation,
                "population-standard-deviation-divided-by-mean-times-10000.v1",
                10_000, .nearestOrAwayFromZero, .exactlyFivePassedDeclaredTrials
            )
        case .cancellationLatencyMilliseconds:
            return (
                .milliseconds, .checkedSum,
                "continuous-clock.cancellation-through-provider-drain.v1",
                1, .downToWholeMilliseconds,
                .controlledCancellationThroughTerminalDrain
            )
        }
    }

    private static func canonicalObject(
        _ entry: Phase2ProductionQualificationMetricSemanticsEntry
    ) -> [String: Any] {
        [
            "aggregation": entry.aggregation.rawValue,
            "applicable_trial_keys": entry.applicableTrialKeys.sorted().map(\.canonicalID),
            "completeness": entry.completeness.rawValue,
            "formula_id": entry.formulaID,
            "measurement": entry.measurement.rawValue,
            "numeric_scope": entry.numericScope.rawValue,
            "rounding": entry.rounding.rawValue,
            "scale": entry.scale,
            "unit": entry.unit.rawValue,
        ]
    }

    fileprivate static func v2Kind(
        for measurement: Phase2QualificationMeasurementKind
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
}

/// Sole production authority for the first exact F4C standard profile. There is intentionally no
/// caller-supplied initializer: preflight and the runner compare against this singleton identity.
struct Phase2ProductionQualificationPolicy: Sendable {
    static let standard: Self = try! makeStandard()

    /// Only the closed profile registry uses this factory. Preflight independently resolves and
    /// compares the entire compiled definition; a caller-made definition grants no authority.
    static func makeQwen38V2Candidate(
        providerAdmission: Phase2ProtocolComponentIdentity,
        generationAdmission: Phase2ProtocolComponentIdentity
    ) throws -> Self {
        let base = standard
        let revision = try Phase2ProductionModelRevisionIdentity(
            identityID: "phase2.local.qwen38-v2-q6k.model-revision.v1",
            modelSource: "OBLITERATUS/Qwen3.8-27B-OBLITERATED",
            upstreamRevisionSHA1: "7ef7657167b8c795077c14a09c84769659fcc0f5",
            localArtifactManifestSHA256:
                "d4ab1fe8f27e4f6c8544198d5971f43e6c98801d5b2a24654ab2c1bdb9c4c717",
            localArtifactManifestAlgorithm: "sorted-utf8-relative-path-size-file-sha256.v1"
        )
        let definition = try Phase2QualificationV2Identity.make(
            id: "phase2.local.qwen38-v2-q6k.qualification-definition.v1",
            version: 1,
            object: [
                "environment_policy": componentObject(base.environmentPolicy.identity),
                "deterministic_fixture_corpus": componentObject(base.deterministicFixtureCorpusIdentity),
                "live_qualification_corpus": componentObject(base.liveScenarioCatalog.identity),
                "metric_semantics": componentObject(base.metricSemantics.identity),
                "model_revision": componentObject(revision.identity),
                "protocol_probe_catalog": componentObject(base.protocolProbeCatalogIdentity),
                "qualification_policy": componentObject(base.policyIdentity),
                "threshold_set": componentObject(base.thresholdSet.identity),
                "provider_admission_policy": componentObject(providerAdmission),
                "generation_admission": componentObject(generationAdmission),
                "version": 1,
            ]
        )
        return .init(
            protocolProbeCatalog: base.protocolProbeCatalog,
            protocolProbeCatalogIdentity: base.protocolProbeCatalogIdentity,
            deterministicFixtureCorpusIdentity: base.deterministicFixtureCorpusIdentity,
            liveScenarioCatalog: base.liveScenarioCatalog,
            hardwarePolicy: base.hardwarePolicy,
            environmentPolicy: base.environmentPolicy,
            modelRevision: revision,
            thresholdSet: base.thresholdSet,
            deterministicRequirements: base.deterministicRequirements,
            liveRequirements: base.liveRequirements,
            metricPlan: base.metricPlan,
            metricSemantics: base.metricSemantics,
            policy: base.policy,
            policyIdentity: base.policyIdentity,
            definitionIdentity: definition
        )
    }

    let protocolProbeCatalog: Phase2ProductionProtocolProbeCatalog
    let protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity
    let deterministicFixtureCorpusIdentity: Phase2ProtocolComponentIdentity
    let liveScenarioCatalog: Phase2LiveQualificationScenarioCatalog
    let hardwarePolicy: Phase2QualificationHardwarePolicy
    let environmentPolicy: Phase2ProductionQualificationEnvironmentPolicy
    let modelRevision: Phase2ProductionModelRevisionIdentity
    let thresholdSet: Phase2ProductionQualificationThresholdSet
    let deterministicRequirements: [Phase2QualificationProbeRequirement]
    let liveRequirements: [Phase2QualificationProbeRequirement]
    let metricPlan: Phase2QualificationMetricPlan
    let metricSemantics: Phase2ProductionQualificationMetricSemantics
    let metricSemanticsIdentity: Phase2ProtocolComponentIdentity
    let policy: Phase2ModelQualificationPolicy
    let policyIdentity: Phase2ProtocolComponentIdentity
    let definitionIdentity: Phase2ProtocolComponentIdentity

    private init(
        protocolProbeCatalog: Phase2ProductionProtocolProbeCatalog,
        protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity,
        deterministicFixtureCorpusIdentity: Phase2ProtocolComponentIdentity,
        liveScenarioCatalog: Phase2LiveQualificationScenarioCatalog,
        hardwarePolicy: Phase2QualificationHardwarePolicy,
        environmentPolicy: Phase2ProductionQualificationEnvironmentPolicy,
        modelRevision: Phase2ProductionModelRevisionIdentity,
        thresholdSet: Phase2ProductionQualificationThresholdSet,
        deterministicRequirements: [Phase2QualificationProbeRequirement],
        liveRequirements: [Phase2QualificationProbeRequirement],
        metricPlan: Phase2QualificationMetricPlan,
        metricSemantics: Phase2ProductionQualificationMetricSemantics,
        policy: Phase2ModelQualificationPolicy,
        policyIdentity: Phase2ProtocolComponentIdentity,
        definitionIdentity: Phase2ProtocolComponentIdentity
    ) {
        self.protocolProbeCatalog = protocolProbeCatalog
        self.protocolProbeCatalogIdentity = protocolProbeCatalogIdentity
        self.deterministicFixtureCorpusIdentity = deterministicFixtureCorpusIdentity
        self.liveScenarioCatalog = liveScenarioCatalog
        self.hardwarePolicy = hardwarePolicy
        self.environmentPolicy = environmentPolicy
        self.modelRevision = modelRevision
        self.thresholdSet = thresholdSet
        self.deterministicRequirements = deterministicRequirements
        self.liveRequirements = liveRequirements
        self.metricPlan = metricPlan
        self.metricSemantics = metricSemantics
        metricSemanticsIdentity = metricSemantics.identity
        self.policy = policy
        self.policyIdentity = policyIdentity
        self.definitionIdentity = definitionIdentity
    }

    private static func makeStandard() throws -> Self {
        let protocolProbeCatalog = Phase2ProductionProtocolProbeCatalog()
        let historicalCatalogDigest = protocolProbeCatalog.qualificationPolicyIdentity.sha256
        let protocolProbeCatalogIdentity = try Phase2ProtocolComponentIdentity(
            id: Phase2ProductionProtocolProbeCatalog.catalogID,
            version: 1,
            sha256: historicalCatalogDigest
        )
        let deterministicFixtureCorpusIdentity = try Phase2ProtocolComponentIdentity(
            id: "phase2.r1.deterministic-fixture-corpus.v1",
            version: 1,
            sha256: "a0d3fdecde2d39f0723ec2f2a5f65aa6f5be5942b8fc18671a4114bace4eb27f"
        )
        let liveScenarioCatalog = Phase2LiveQualificationScenarioCatalog()
        let hardwarePolicy = Phase2QualificationHardwarePolicy.thisM1Max64GiB
        let environmentPolicy = try Phase2ProductionQualificationEnvironmentPolicy(
            requiredXcodeMajorVersion: 27,
            requiredSDKMajorVersion: 27,
            minimumMacOSMajorVersion: 27,
            requiredArchitecture: "arm64",
            hardwarePolicy: hardwarePolicy
        )
        let modelRevision = try Phase2ProductionModelRevisionIdentity(
            modelSource: "mlx-community/Qwen3-Coder-30B-A3B-Instruct-8bit",
            upstreamRevisionSHA1: "7c6ee1bbb5ee3051c4b3bc6553f24bdc2d01393a",
            localArtifactManifestSHA256:
                "49060c25bb8c4f63ef7471796832dc9e7c12b63e553472907ae27f05c7596ace",
            localArtifactManifestAlgorithm:
                "sorted-utf8-relative-path-size-file-sha256.v1"
        )
        let thresholdSet = try makeThresholdSet(hardwarePolicy: hardwarePolicy)
        let deterministicRequirements = try protocolProbeCatalog.probes.map {
            try deterministicRequirement(
                for: $0,
                protocolProbeCatalogIdentity: protocolProbeCatalogIdentity
            )
        }
        let liveRequirements = try liveScenarioCatalog.scenarios.map {
            try liveRequirement(for: $0, thresholdSet: thresholdSet)
        }
        let requirements = deterministicRequirements + liveRequirements
        let metricPlan = try makeMetricPlan(from: requirements)
        let metricSemantics = try Phase2ProductionQualificationMetricSemantics(
            metricPlan: metricPlan,
            thresholds: thresholdSet.thresholds
        )
        let policy = try Phase2ModelQualificationPolicy(
            id: "phase2.r1.qualification-policy.v2",
            version: 2,
            protocolProbeCatalog: protocolProbeCatalogIdentity,
            deterministicFixtureCorpus: deterministicFixtureCorpusIdentity,
            liveQualificationCorpus: liveScenarioCatalog.identity,
            metricSemantics: metricSemantics.identity,
            maximumEvidenceAgeMilliseconds: 300_000,
            requirements: requirements
        )
        let policyIdentity = try Phase2ModelProfileCanonicalizer()
            .qualificationPolicyIdentity(for: policy)
        let definitionIdentity = try Phase2QualificationV2Identity.make(
            id: "phase2.r1.standard-qualification-definition.v1",
            version: 1,
            object: [
                "environment_policy": componentObject(environmentPolicy.identity),
                "deterministic_fixture_corpus": componentObject(
                    deterministicFixtureCorpusIdentity
                ),
                "live_qualification_corpus": componentObject(liveScenarioCatalog.identity),
                "metric_semantics": componentObject(metricSemantics.identity),
                "model_revision": componentObject(modelRevision.identity),
                "protocol_probe_catalog": componentObject(protocolProbeCatalogIdentity),
                "qualification_policy": componentObject(policyIdentity),
                "threshold_set": componentObject(thresholdSet.identity),
                "version": 1,
            ]
        )
        return .init(
            protocolProbeCatalog: protocolProbeCatalog,
            protocolProbeCatalogIdentity: protocolProbeCatalogIdentity,
            deterministicFixtureCorpusIdentity: deterministicFixtureCorpusIdentity,
            liveScenarioCatalog: liveScenarioCatalog,
            hardwarePolicy: hardwarePolicy,
            environmentPolicy: environmentPolicy,
            modelRevision: modelRevision,
            thresholdSet: thresholdSet,
            deterministicRequirements: deterministicRequirements,
            liveRequirements: liveRequirements,
            metricPlan: metricPlan,
            metricSemantics: metricSemantics,
            policy: policy,
            policyIdentity: policyIdentity,
            definitionIdentity: definitionIdentity
        )
    }

    private static func makeThresholdSet(
        hardwarePolicy: Phase2QualificationHardwarePolicy
    ) throws -> Phase2ProductionQualificationThresholdSet {
        try .init(
            id: "phase2.r1.m1-max-64g.standard-thresholds.v1",
            version: 1,
            hardwarePolicy: hardwarePolicy,
            thresholds: [
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
        )
    }

    private static func deterministicRequirement(
        for probe: Phase2ProductionProtocolProbe,
        protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity
    ) throws -> Phase2QualificationProbeRequirement {
        let category: Phase2QualificationProbeCategory
        if probe.id.hasPrefix("identity.") {
            category = .identity
        } else if deterministicSafetyProbeIDs.contains(probe.id) {
            category = .safety
        } else {
            category = .protocolConformance
        }
        let acceptanceCriteria = try Phase2QualificationV2Identity.make(
            id: "\(probe.id).acceptance-criteria",
            version: 1,
            object: [
                "acceptance_criterion": probe.acceptanceCriterion,
                "catalog_identity": componentObject(protocolProbeCatalogIdentity),
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
        return try .init(
            probeID: probe.id,
            executionKind: .deterministicFixture,
            category: category,
            severity: .hard,
            requiredTrialCount: 1,
            acceptanceCriteria: acceptanceCriteria,
            evidenceRequirement: .requiredSHA256
        )
    }

    private static func liveRequirement(
        for scenario: Phase2LiveQualificationScenario,
        thresholdSet: Phase2ProductionQualificationThresholdSet
    ) throws -> Phase2QualificationProbeRequirement {
        let severity: Phase2QualificationProbeSeverity = switch scenario.category {
        case .identity, .protocolConformance, .safety: .hard
        case .quality, .performance: .quality
        }
        let thresholds = thresholdSet.thresholds(for: scenario.id)
        return try .init(
            probeID: scenario.id,
            executionKind: .liveProvider,
            category: scenario.category,
            severity: severity,
            requiredTrialCount: scenario.trialCount,
            acceptanceCriteria: scenario.acceptanceCriteriaIdentity,
            evidenceRequirement: .requiredSHA256,
            requiredMeasurements: thresholds.map { $0.rule.measurement },
            numericRules: thresholds.map(\.rule)
        )
    }

    private static func makeMetricPlan(
        from requirements: [Phase2QualificationProbeRequirement]
    ) throws -> Phase2QualificationMetricPlan {
        var applicability: [
            Phase2QualificationMeasurementV2Kind: Set<Phase2QualificationTrialKey>
        ] = [:]
        var varianceRequirementID: String?
        for requirement in requirements where !requirement.numericRules.isEmpty {
            let trialKeys = Set(try (1...requirement.requiredTrialCount).map {
                try Phase2QualificationTrialKey(
                    requirementID: requirement.probeID,
                    trialIndex: $0,
                    attempt: 1
                )
            })
            for rule in requirement.numericRules {
                let kind = Phase2ProductionQualificationMetricSemantics.v2Kind(
                    for: rule.measurement
                )
                applicability[kind, default: []].formUnion(trialKeys)
                if rule.measurement == .varianceBasisPoints {
                    guard varianceRequirementID == nil else {
                        throw Phase2QualificationMeasurementV2Error.invalidMetricPlan
                    }
                    varianceRequirementID = requirement.probeID
                }
                if rule.measurement == .throughputMilliTokensPerSecond {
                    applicability[.generatedTokenCount, default: []].formUnion(trialKeys)
                }
            }
        }
        return try .init(
            applicableTrialKeys: applicability,
            varianceRequirementID: varianceRequirementID
        )
    }

    private static func componentObject(
        _ identity: Phase2ProtocolComponentIdentity
    ) -> [String: Any] {
        [
            "id": identity.id,
            "sha256": identity.sha256!,
            "version": identity.version,
        ]
    }

    private static let deterministicSafetyProbeIDs: Set<String> = [
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
}
