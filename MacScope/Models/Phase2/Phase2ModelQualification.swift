import Foundation

enum Phase2ModelQualificationStatus: String, Hashable, Sendable {
    case certified
    case compatible
    case experimental
    case unsupported
}

enum Phase2ModelQualificationVerdict: String, Hashable, Sendable {
    case certified
    case compatible
    case experimental
    case unsupported
    case inconclusive

    var supportStatus: Phase2ModelQualificationStatus? {
        switch self {
        case .certified: .certified
        case .compatible: .compatible
        case .experimental: .experimental
        case .unsupported: .unsupported
        case .inconclusive: nil
        }
    }
}

enum Phase2QualificationProbeCategory: String, Hashable, Sendable {
    case identity
    case protocolConformance = "protocol-conformance"
    case safety
    case quality
    case performance
}

enum Phase2QualificationProbeSeverity: String, Hashable, Sendable {
    /// Failure proves the declared workflow unsafe or protocol-incompatible.
    case hard
    /// Failure preserves an evaluated but explicitly experimental combination.
    case core
    /// Failure can retain compatible protocol support while missing certification quality.
    case quality
}

/// Closed, unit-qualified aggregate measurements that a qualification policy can require.
/// Integer units keep the evidence seam deterministic and avoid floating-point ambiguity.
enum Phase2QualificationMeasurementKind: String, CaseIterable, Hashable, Sendable {
    case totalLatencyMilliseconds = "total-latency-milliseconds"
    case timeToFirstSemanticEventMilliseconds = "time-to-first-semantic-event-milliseconds"
    case generatedTokenCount = "generated-token-count"
    case throughputMilliTokensPerSecond = "throughput-millitokens-per-second"
    case peakResidentBytes = "peak-resident-bytes"
    case varianceBasisPoints = "variance-basis-points"
    case cancellationLatencyMilliseconds = "cancellation-latency-milliseconds"

    var maximumAcceptedValue: Int64 {
        switch self {
        case .totalLatencyMilliseconds,
             .timeToFirstSemanticEventMilliseconds,
             .cancellationLatencyMilliseconds:
            86_400_000
        case .generatedTokenCount:
            10_000_000
        case .throughputMilliTokensPerSecond:
            1_000_000_000
        case .peakResidentBytes:
            1_099_511_627_776
        case .varianceBasisPoints:
            1_000_000
        }
    }
}

/// Bounded aggregate measurements for one complete qualification run. Absence is represented
/// explicitly by `nil`; provider payloads and per-request traces cannot cross this seam.
struct Phase2QualificationMeasurements: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case outOfRange(Phase2QualificationMeasurementKind)
    }

    static let empty = Phase2QualificationMeasurements(unchecked: ())

    let totalLatencyMilliseconds: Int64?
    let timeToFirstSemanticEventMilliseconds: Int64?
    let generatedTokenCount: Int64?
    let throughputMilliTokensPerSecond: Int64?
    let peakResidentBytes: Int64?
    let varianceBasisPoints: Int64?
    let cancellationLatencyMilliseconds: Int64?

    init(
        totalLatencyMilliseconds: Int64? = nil,
        timeToFirstSemanticEventMilliseconds: Int64? = nil,
        generatedTokenCount: Int64? = nil,
        throughputMilliTokensPerSecond: Int64? = nil,
        peakResidentBytes: Int64? = nil,
        varianceBasisPoints: Int64? = nil,
        cancellationLatencyMilliseconds: Int64? = nil
    ) throws {
        guard totalLatencyMilliseconds.map({ (0...86_400_000).contains($0) }) ?? true else {
            throw ValidationError.outOfRange(.totalLatencyMilliseconds)
        }
        guard generatedTokenCount.map({ (0...10_000_000).contains($0) }) ?? true else {
            throw ValidationError.outOfRange(.generatedTokenCount)
        }
        guard throughputMilliTokensPerSecond.map({ (0...1_000_000_000).contains($0) })
            ?? true else {
            throw ValidationError.outOfRange(.throughputMilliTokensPerSecond)
        }
        guard peakResidentBytes.map({ (0...1_099_511_627_776).contains($0) }) ?? true else {
            throw ValidationError.outOfRange(.peakResidentBytes)
        }
        guard varianceBasisPoints.map({ (0...1_000_000).contains($0) }) ?? true else {
            throw ValidationError.outOfRange(.varianceBasisPoints)
        }
        guard timeToFirstSemanticEventMilliseconds.map({ (0...86_400_000).contains($0) })
            ?? true else {
            throw ValidationError.outOfRange(.timeToFirstSemanticEventMilliseconds)
        }
        guard cancellationLatencyMilliseconds.map({ (0...86_400_000).contains($0) })
            ?? true else {
            throw ValidationError.outOfRange(.cancellationLatencyMilliseconds)
        }
        self.totalLatencyMilliseconds = totalLatencyMilliseconds
        self.timeToFirstSemanticEventMilliseconds = timeToFirstSemanticEventMilliseconds
        self.generatedTokenCount = generatedTokenCount
        self.throughputMilliTokensPerSecond = throughputMilliTokensPerSecond
        self.peakResidentBytes = peakResidentBytes
        self.varianceBasisPoints = varianceBasisPoints
        self.cancellationLatencyMilliseconds = cancellationLatencyMilliseconds
    }

    var availableKinds: Set<Phase2QualificationMeasurementKind> {
        var kinds: Set<Phase2QualificationMeasurementKind> = []
        if totalLatencyMilliseconds != nil { kinds.insert(.totalLatencyMilliseconds) }
        if timeToFirstSemanticEventMilliseconds != nil {
            kinds.insert(.timeToFirstSemanticEventMilliseconds)
        }
        if generatedTokenCount != nil { kinds.insert(.generatedTokenCount) }
        if throughputMilliTokensPerSecond != nil {
            kinds.insert(.throughputMilliTokensPerSecond)
        }
        if peakResidentBytes != nil { kinds.insert(.peakResidentBytes) }
        if varianceBasisPoints != nil { kinds.insert(.varianceBasisPoints) }
        if cancellationLatencyMilliseconds != nil {
            kinds.insert(.cancellationLatencyMilliseconds)
        }
        return kinds
    }

    func value(for kind: Phase2QualificationMeasurementKind) -> Int64? {
        switch kind {
        case .totalLatencyMilliseconds: totalLatencyMilliseconds
        case .timeToFirstSemanticEventMilliseconds: timeToFirstSemanticEventMilliseconds
        case .generatedTokenCount: generatedTokenCount
        case .throughputMilliTokensPerSecond: throughputMilliTokensPerSecond
        case .peakResidentBytes: peakResidentBytes
        case .varianceBasisPoints: varianceBasisPoints
        case .cancellationLatencyMilliseconds: cancellationLatencyMilliseconds
        }
    }

    private init(unchecked: Void) {
        totalLatencyMilliseconds = nil
        timeToFirstSemanticEventMilliseconds = nil
        generatedTokenCount = nil
        throughputMilliTokensPerSecond = nil
        peakResidentBytes = nil
        varianceBasisPoints = nil
        cancellationLatencyMilliseconds = nil
    }
}

enum Phase2QualificationExecutionKind: String, Hashable, Sendable {
    case deterministicFixture = "deterministic-fixture"
    case liveProvider = "live-provider"
}

enum Phase2QualificationObservationEvidenceRequirement: String, Hashable, Sendable {
    case requiredSHA256 = "required-sha256"
}

enum Phase2QualificationNumericComparison: String, Hashable, Sendable {
    case minimumInclusive = "minimum-inclusive"
    case maximumInclusive = "maximum-inclusive"
}

enum Phase2QualificationNumericScope: String, Hashable, Sendable {
    case perAttempt = "per-attempt"
    case runAggregate = "run-aggregate"
}

struct Phase2QualificationNumericRule: Hashable, Sendable {
    let measurement: Phase2QualificationMeasurementKind
    let scope: Phase2QualificationNumericScope
    let comparison: Phase2QualificationNumericComparison
    let threshold: Int64

    init(
        measurement: Phase2QualificationMeasurementKind,
        scope: Phase2QualificationNumericScope = .perAttempt,
        comparison: Phase2QualificationNumericComparison,
        threshold: Int64
    ) throws {
        guard (0...measurement.maximumAcceptedValue).contains(threshold) else {
            throw Phase2ModelProfileValidationError.invalidIdentifier
        }
        self.measurement = measurement
        self.scope = scope
        self.comparison = comparison
        self.threshold = threshold
    }

    func accepts(_ value: Int64) -> Bool {
        switch comparison {
        case .minimumInclusive: value >= threshold
        case .maximumInclusive: value <= threshold
        }
    }
}

struct Phase2QualificationProbeRequirement: Hashable, Sendable {
    let probeID: String
    let executionKind: Phase2QualificationExecutionKind?
    let category: Phase2QualificationProbeCategory
    let severity: Phase2QualificationProbeSeverity
    let requiredTrialCount: Int
    let acceptanceCriteria: Phase2ProtocolComponentIdentity
    let evidenceRequirement: Phase2QualificationObservationEvidenceRequirement?
    let requiredMeasurements: [Phase2QualificationMeasurementKind]
    let numericRules: [Phase2QualificationNumericRule]

    init(
        probeID: String,
        category: Phase2QualificationProbeCategory,
        severity: Phase2QualificationProbeSeverity,
        requiredTrialCount: Int,
        acceptanceCriteria: Phase2ProtocolComponentIdentity,
        requiredMeasurements: [Phase2QualificationMeasurementKind] = []
    ) throws {
        guard phase2IsCategoricalToken(probeID, maximumBytes: 128),
              (1...100).contains(requiredTrialCount),
              acceptanceCriteria.availability == .available,
              acceptanceCriteria.sha256 != nil
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        if [.identity, .protocolConformance, .safety].contains(category), severity != .hard {
            throw Phase2ModelProfileValidationError.invalidIdentifier
        }
        guard Set(requiredMeasurements).count == requiredMeasurements.count,
              category != .performance || !requiredMeasurements.isEmpty
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.probeID = probeID
        self.executionKind = nil
        self.category = category
        self.severity = severity
        self.requiredTrialCount = requiredTrialCount
        self.acceptanceCriteria = acceptanceCriteria
        self.evidenceRequirement = nil
        let requestedMeasurements = Set(requiredMeasurements)
        self.requiredMeasurements = Phase2QualificationMeasurementKind.allCases.filter {
            requestedMeasurements.contains($0)
        }
        self.numericRules = []
    }

    init(
        probeID: String,
        executionKind: Phase2QualificationExecutionKind,
        category: Phase2QualificationProbeCategory,
        severity: Phase2QualificationProbeSeverity,
        requiredTrialCount: Int,
        acceptanceCriteria: Phase2ProtocolComponentIdentity,
        evidenceRequirement: Phase2QualificationObservationEvidenceRequirement,
        requiredMeasurements: [Phase2QualificationMeasurementKind] = [],
        numericRules: [Phase2QualificationNumericRule] = []
    ) throws {
        guard phase2IsCategoricalToken(probeID, maximumBytes: 128),
              (1...100).contains(requiredTrialCount),
              acceptanceCriteria.availability == .available,
              acceptanceCriteria.sha256 != nil
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        if [.identity, .protocolConformance, .safety].contains(category), severity != .hard {
            throw Phase2ModelProfileValidationError.invalidIdentifier
        }
        let measurementSet = Set(requiredMeasurements)
        let ruleMeasurements = numericRules.map(\.measurement)
        guard measurementSet.count == requiredMeasurements.count,
              Set(ruleMeasurements).count == ruleMeasurements.count,
              Set(ruleMeasurements) == measurementSet,
              category != .performance || !requiredMeasurements.isEmpty
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.probeID = probeID
        self.executionKind = executionKind
        self.category = category
        self.severity = severity
        self.requiredTrialCount = requiredTrialCount
        self.acceptanceCriteria = acceptanceCriteria
        self.evidenceRequirement = evidenceRequirement
        let requestedMeasurements = Set(requiredMeasurements)
        self.requiredMeasurements = Phase2QualificationMeasurementKind.allCases.filter {
            requestedMeasurements.contains($0)
        }
        let rulesByKind = Dictionary(uniqueKeysWithValues: numericRules.map {
            ($0.measurement, $0)
        })
        self.numericRules = Phase2QualificationMeasurementKind.allCases.compactMap {
            rulesByKind[$0]
        }
    }
}

/// One concrete, app-owned evidence snapshot. The run derives every duplicated value and content
/// identity from this bundle; callers cannot pair a trusted digest with different measurements,
/// timestamps, or environment fields.
struct Phase2QualificationEvidenceBundle: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case inconsistentMeasurementScope
        case duplicateAttemptMeasurement
        case noncanonicalAttemptMeasurements
        case incompleteRequiredMeasurement
        case incompleteExecution
        case policyPlanMismatch
        case productionIdentityMismatch
    }

    let environment: Phase2QualificationEnvironmentV2
    let runtimeProvenance: Phase2QualificationRuntimeProvenance
    let measurementAggregate: Phase2QualificationMeasurementAggregate

    init(
        environment: Phase2QualificationEnvironmentV2,
        runtimeProvenance: Phase2QualificationRuntimeProvenance,
        execution: Phase2LiveQualificationExecution
    ) throws {
        let standard = Phase2ProductionQualificationPolicy.standard
        guard runtimeProvenance.modelSource == standard.modelRevision.modelSource,
              runtimeProvenance.modelRevisionIdentity == standard.modelRevision.identity,
              runtimeProvenance.productionDefinitionIdentity == standard.definitionIdentity
        else { throw ValidationError.productionIdentityMismatch }
        try self.init(
            validatingEnvironment: environment,
            runtimeProvenance: runtimeProvenance,
            execution: execution,
            policy: standard.policy,
            metricPlan: standard.metricPlan
        )
    }

    /// CoreTests fixture seam: it accepts no aggregate or pass set and always rebuilds numeric
    /// evidence from the exact execution denominator. It cannot emit a report because report
    /// composition is absent from the shipped app target.
    init(
        environment: Phase2QualificationEnvironmentV2,
        runtimeProvenance: Phase2QualificationRuntimeProvenance,
        execution: Phase2LiveQualificationExecution,
        policy: Phase2ModelQualificationPolicy,
        metricPlan: Phase2QualificationMetricPlan
    ) throws {
        try self.init(
            validatingEnvironment: environment,
            runtimeProvenance: runtimeProvenance,
            execution: execution,
            policy: policy,
            metricPlan: metricPlan
        )
    }
    private init(
        validatingEnvironment environment: Phase2QualificationEnvironmentV2,
        runtimeProvenance: Phase2QualificationRuntimeProvenance,
        execution: Phase2LiveQualificationExecution,
        policy: Phase2ModelQualificationPolicy,
        metricPlan: Phase2QualificationMetricPlan
    ) throws {
        guard policy.version == 2,
              execution.terminationStatus == .completed,
              execution.firstAdmissionEpochMilliseconds
                == runtimeProvenance.startedAtEpochMilliseconds,
              execution.terminalEpochMilliseconds
                == runtimeProvenance.endedAtEpochMilliseconds
        else { throw ValidationError.incompleteExecution }
        let liveRequirements = policy.requirements.filter {
            $0.executionKind == .liveProvider
        }
        let plannedKeys = try liveRequirements.flatMap { requirement in
            try (1...requirement.requiredTrialCount).map { trial in
                try Phase2QualificationTrialKey(
                    requirementID: requirement.probeID,
                    trialIndex: trial,
                    attempt: 1
                )
            }
        }
        let expectedPlan = try Self.metricPlan(for: liveRequirements)
        guard try expectedPlan.contentIdentity() == metricPlan.contentIdentity() else {
            throw ValidationError.policyPlanMismatch
        }
        guard execution.measurementSamples.allSatisfy({
            metricPlan.containsEveryApplicableValue(in: $0)
        }) else { throw ValidationError.incompleteRequiredMeasurement }
        let measurementAggregate = try Phase2QualificationMeasurementCollector().aggregate(
            samples: execution.measurementSamples,
            observations: execution.observations,
            plannedTrialKeys: plannedKeys,
            admittedAttemptKeys: execution.admittedAttemptKeys,
            scope: runtimeProvenance.measurementScopeIdentity,
            metricPlan: metricPlan
        )
        try self.init(
            validatedEnvironment: environment,
            runtimeProvenance: runtimeProvenance,
            measurementAggregate: measurementAggregate
        )
    }

    private static func metricPlan(
        for requirements: [Phase2QualificationProbeRequirement]
    ) throws -> Phase2QualificationMetricPlan {
        var applicable: [
            Phase2QualificationMeasurementV2Kind: Set<Phase2QualificationTrialKey>
        ] = [:]
        var varianceRequirementIDs: Set<String> = []
        for requirement in requirements {
            let keys = try Set((1...requirement.requiredTrialCount).map { trial in
                try Phase2QualificationTrialKey(
                    requirementID: requirement.probeID,
                    trialIndex: trial,
                    attempt: 1
                )
            })
            for measurement in requirement.requiredMeasurements {
                let kind = v2Kind(measurement)
                applicable[kind, default: []].formUnion(keys)
                if kind == .throughputMilliTokensPerSecond {
                    applicable[.generatedTokenCount, default: []].formUnion(keys)
                }
                if kind == .varianceBasisPoints {
                    varianceRequirementIDs.insert(requirement.probeID)
                }
            }
        }
        guard !applicable.isEmpty, varianceRequirementIDs.count <= 1 else {
            throw ValidationError.policyPlanMismatch
        }
        return try .init(
            applicableTrialKeys: applicable,
            varianceRequirementID: varianceRequirementIDs.first
        )
    }

    private static func v2Kind(
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

    private init(
        validatedEnvironment environment: Phase2QualificationEnvironmentV2,
        runtimeProvenance: Phase2QualificationRuntimeProvenance,
        measurementAggregate: Phase2QualificationMeasurementAggregate
    ) throws {
        let samples = measurementAggregate.samples
        guard runtimeProvenance.measurementScopeIdentity == measurementAggregate.scopeIdentity,
              samples.allSatisfy({
                  $0.measurementScopeIdentity == measurementAggregate.scopeIdentity
              }),
              measurementAggregate.scopeIdentity.availability == .available,
              measurementAggregate.scopeIdentity.sha256 != nil,
              measurementAggregate.metricPlanIdentity.availability == .available,
              measurementAggregate.metricPlanIdentity.sha256 != nil
        else { throw ValidationError.inconsistentMeasurementScope }
        guard Set(samples.map(\.trialKey)).count == samples.count else {
            throw ValidationError.duplicateAttemptMeasurement
        }
        guard samples == samples.sorted(by: { $0.trialKey < $1.trialKey }) else {
            throw ValidationError.noncanonicalAttemptMeasurements
        }
        self.environment = environment
        self.runtimeProvenance = runtimeProvenance
        self.measurementAggregate = measurementAggregate
    }

    var environmentIdentity: Phase2ProtocolComponentIdentity {
        get throws { try environment.contentIdentity() }
    }

    var runtimeProvenanceIdentity: Phase2ProtocolComponentIdentity {
        get throws { try runtimeProvenance.contentIdentity() }
    }

    var measurementEvidenceIdentity: Phase2ProtocolComponentIdentity {
        get throws { try measurementAggregate.contentIdentity() }
    }

    func aggregateMeasurements() throws -> Phase2QualificationMeasurements {
        let source = measurementAggregate.measurements
        return try .init(
            totalLatencyMilliseconds: source.totalLatencyMilliseconds,
            timeToFirstSemanticEventMilliseconds: source.timeToFirstSemanticEventMilliseconds,
            generatedTokenCount: source.generatedTokenCount,
            throughputMilliTokensPerSecond: source.throughputMilliTokensPerSecond,
            peakResidentBytes: source.peakResidentBytes,
            varianceBasisPoints: source.varianceBasisPoints,
            cancellationLatencyMilliseconds: source.cancellationLatencyMilliseconds
        )
    }

    func attemptMeasurements() throws -> [Phase2QualificationAttemptMeasurements] {
        try measurementAggregate.samples.map { sample in
            let throughput = try Self.throughput(
                completionTokens: sample.generatedTokenCount,
                generationMilliseconds: sample.generationMilliseconds
            )
            return try .init(
                probeID: sample.trialKey.requirementID,
                trial: sample.trialKey.trialIndex,
                attempt: sample.trialKey.attempt,
                measurements: .init(
                    totalLatencyMilliseconds: sample.totalLatencyMilliseconds,
                    timeToFirstSemanticEventMilliseconds:
                        sample.timeToFirstSemanticEventMilliseconds,
                    generatedTokenCount: sample.generatedTokenCount,
                    throughputMilliTokensPerSecond: throughput,
                    peakResidentBytes: sample.peakResidentBytes,
                    cancellationLatencyMilliseconds: sample.cancellationLatencyMilliseconds
                )
            )
        }
    }

    private static func throughput(
        completionTokens: Int64?,
        generationMilliseconds: Int64?
    ) throws -> Int64? {
        guard let completionTokens, let generationMilliseconds else { return nil }
        guard completionTokens >= 0, generationMilliseconds > 0 else {
            throw Phase2QualificationMeasurementV2Error.outOfRange
        }
        let (scaled, overflow) = completionTokens.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { throw Phase2QualificationMeasurementV2Error.overflow }
        return scaled / generationMilliseconds
    }
}

/// Trusted, app-owned identities for the environment and evidence-generation path. Each identity
/// is derived from a concrete bundle rather than accepted independently from a caller.
struct Phase2QualificationEvidenceExpectations: Hashable, Sendable {
    static let environmentIdentityID = "phase2.r1.qualification-environment.v2"
    static let runtimeProvenanceIdentityID =
        "phase2.r1.qualification-runtime-provenance.v3"
    static let measurementEvidenceIdentityID = "phase2.r1.qualification-measurements.v2"
    static let identityVersion = 2

    let environmentIdentity: Phase2ProtocolComponentIdentity
    let runtimeProvenanceIdentity: Phase2ProtocolComponentIdentity
    let measurementEvidenceIdentity: Phase2ProtocolComponentIdentity

    init(evidenceBundle: Phase2QualificationEvidenceBundle) throws {
        let environmentIdentity = try evidenceBundle.environmentIdentity
        let runtimeProvenanceIdentity = try evidenceBundle.runtimeProvenanceIdentity
        let measurementEvidenceIdentity = try evidenceBundle.measurementEvidenceIdentity
        guard Self.isExact(
            environmentIdentity,
            id: Self.environmentIdentityID,
            version: Self.identityVersion
        ), Self.isExact(
            runtimeProvenanceIdentity,
            id: Self.runtimeProvenanceIdentityID,
            version: 3
        ), Self.isExact(
            measurementEvidenceIdentity,
            id: Self.measurementEvidenceIdentityID,
            version: Self.identityVersion
        ) else {
            throw Phase2ModelProfileValidationError.invalidIdentifier
        }
        self.environmentIdentity = environmentIdentity
        self.runtimeProvenanceIdentity = runtimeProvenanceIdentity
        self.measurementEvidenceIdentity = measurementEvidenceIdentity
    }

    private static func isExact(
        _ identity: Phase2ProtocolComponentIdentity,
        id: String,
        version: Int
    ) -> Bool {
        identity.id == id
            && identity.version == version
            && identity.availability == .available
            && identity.sha256 != nil
    }
}

/// Pure expectations supplied by the app when an injected run is evaluated. This prevents an
/// old or differently built environment from inheriting a current qualification result.
struct Phase2ModelQualificationEvaluationContext: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidTime
        case invalidMaximumAge
    }

    let macScopeBuild: String
    let toolchainBuild: String
    let operatingSystemBuild: String
    let architecture: String
    let evaluatedAtEpochMilliseconds: Int64
    let maximumEvidenceAgeMilliseconds: Int64
    let evidenceExpectations: Phase2QualificationEvidenceExpectations?

    init(
        macScopeBuild: String,
        toolchainBuild: String,
        operatingSystemBuild: String,
        architecture: String,
        evaluatedAtEpochMilliseconds: Int64,
        maximumEvidenceAgeMilliseconds: Int64
    ) throws {
        guard phase2IsOpaqueToken(macScopeBuild, maximumBytes: 128),
              phase2IsOpaqueToken(toolchainBuild, maximumBytes: 128),
              phase2IsOpaqueToken(operatingSystemBuild, maximumBytes: 128),
              phase2IsOpaqueToken(architecture, maximumBytes: 32)
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        guard evaluatedAtEpochMilliseconds >= 0 else { throw ValidationError.invalidTime }
        guard maximumEvidenceAgeMilliseconds >= 0 else {
            throw ValidationError.invalidMaximumAge
        }
        self.macScopeBuild = macScopeBuild
        self.toolchainBuild = toolchainBuild
        self.operatingSystemBuild = operatingSystemBuild
        self.architecture = architecture
        self.evaluatedAtEpochMilliseconds = evaluatedAtEpochMilliseconds
        self.maximumEvidenceAgeMilliseconds = maximumEvidenceAgeMilliseconds
        self.evidenceExpectations = nil
    }

    init(
        evidenceBundle: Phase2QualificationEvidenceBundle,
        evaluatedAtEpochMilliseconds: Int64,
        maximumEvidenceAgeMilliseconds: Int64
    ) throws {
        guard evaluatedAtEpochMilliseconds >= 0 else { throw ValidationError.invalidTime }
        guard maximumEvidenceAgeMilliseconds >= 0 else {
            throw ValidationError.invalidMaximumAge
        }
        self.macScopeBuild = evidenceBundle.environment.bundleVersion
        self.toolchainBuild = evidenceBundle.environment.xcodeBuild
        self.operatingSystemBuild = evidenceBundle.environment.operatingSystemBuild
        self.architecture = evidenceBundle.environment.architecture
        self.evaluatedAtEpochMilliseconds = evaluatedAtEpochMilliseconds
        self.maximumEvidenceAgeMilliseconds = maximumEvidenceAgeMilliseconds
        self.evidenceExpectations = try .init(evidenceBundle: evidenceBundle)
    }
}

struct Phase2ModelQualificationPolicy: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case duplicateProbeID(String)
        case tooManyDeclaredTrials
    }

    let id: String
    let version: Int
    let corpusDigest: String
    let protocolProbeCatalog: Phase2ProtocolComponentIdentity?
    let deterministicFixtureCorpus: Phase2ProtocolComponentIdentity?
    let liveQualificationCorpus: Phase2ProtocolComponentIdentity?
    let metricSemantics: Phase2ProtocolComponentIdentity?
    let maximumEvidenceAgeMilliseconds: Int64?
    /// Policy order is semantic and determines canonical report ordering.
    let requirements: [Phase2QualificationProbeRequirement]

    init(
        id: String,
        version: Int,
        corpusDigest: String,
        requirements: [Phase2QualificationProbeRequirement]
    ) throws {
        guard phase2IsCategoricalToken(id), version == 1 else {
            throw Phase2ModelProfileValidationError.invalidVersion
        }
        guard phase2IsSHA256Hex(corpusDigest) else {
            throw Phase2ModelProfileValidationError.invalidSHA256Digest
        }
        guard !requirements.isEmpty,
              requirements.count <= 128,
              requirements.allSatisfy({
                  $0.executionKind == nil
                      && $0.evidenceRequirement == nil
                      && $0.numericRules.isEmpty
              })
        else {
            throw Phase2ModelProfileValidationError.invalidIdentifier
        }
        var seen: Set<String> = []
        var declaredTrials = 0
        for requirement in requirements {
            guard seen.insert(requirement.probeID).inserted else {
                throw ValidationError.duplicateProbeID(requirement.probeID)
            }
            let (sum, overflow) = declaredTrials.addingReportingOverflow(
                requirement.requiredTrialCount
            )
            guard !overflow, sum <= 1_000 else { throw ValidationError.tooManyDeclaredTrials }
            declaredTrials = sum
        }
        self.id = id
        self.version = version
        self.corpusDigest = corpusDigest
        self.protocolProbeCatalog = nil
        self.deterministicFixtureCorpus = nil
        self.liveQualificationCorpus = nil
        self.metricSemantics = nil
        self.maximumEvidenceAgeMilliseconds = nil
        self.requirements = requirements
    }

    init(
        id: String,
        version: Int,
        protocolProbeCatalog: Phase2ProtocolComponentIdentity,
        deterministicFixtureCorpus: Phase2ProtocolComponentIdentity,
        liveQualificationCorpus: Phase2ProtocolComponentIdentity,
        metricSemantics: Phase2ProtocolComponentIdentity,
        maximumEvidenceAgeMilliseconds: Int64,
        requirements: [Phase2QualificationProbeRequirement]
    ) throws {
        guard phase2IsCategoricalToken(id), version == 2 else {
            throw Phase2ModelProfileValidationError.invalidVersion
        }
        guard protocolProbeCatalog.availability == .available,
              deterministicFixtureCorpus.availability == .available,
              liveQualificationCorpus.availability == .available,
              metricSemantics.availability == .available,
              protocolProbeCatalog.sha256 != nil,
              deterministicFixtureCorpus.sha256 != nil,
              liveQualificationCorpus.sha256 != nil,
              metricSemantics.sha256 != nil,
              (0...86_400_000).contains(maximumEvidenceAgeMilliseconds),
              !requirements.isEmpty,
              requirements.count <= 128,
              requirements.allSatisfy({
                  $0.executionKind != nil && $0.evidenceRequirement != nil
              })
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        try Self.validateRequirements(requirements)
        self.id = id
        self.version = version
        self.corpusDigest = liveQualificationCorpus.sha256!
        self.protocolProbeCatalog = protocolProbeCatalog
        self.deterministicFixtureCorpus = deterministicFixtureCorpus
        self.liveQualificationCorpus = liveQualificationCorpus
        self.metricSemantics = metricSemantics
        self.maximumEvidenceAgeMilliseconds = maximumEvidenceAgeMilliseconds
        self.requirements = requirements
    }

    private static func validateRequirements(
        _ requirements: [Phase2QualificationProbeRequirement]
    ) throws {
        var seen: Set<String> = []
        var declaredTrials = 0
        for requirement in requirements {
            guard seen.insert(requirement.probeID).inserted else {
                throw ValidationError.duplicateProbeID(requirement.probeID)
            }
            let (sum, overflow) = declaredTrials.addingReportingOverflow(
                requirement.requiredTrialCount
            )
            guard !overflow, sum <= 1_000 else { throw ValidationError.tooManyDeclaredTrials }
            declaredTrials = sum
        }
    }

    var declaredTrialCount: Int {
        requirements.reduce(into: 0) { $0 += $1.requiredTrialCount }
    }
}

enum Phase2QualificationProbeOutcome: String, Hashable, Sendable {
    case passed
    case failed
    case unavailable
    case cancelled
    case notRun = "not-run"
}

struct Phase2QualificationProbeObservation: Hashable, Sendable {
    let probeID: String
    let trial: Int
    let attempt: Int
    let outcome: Phase2QualificationProbeOutcome
    let reasonCode: String?
    let evidenceDigest: String?

    init(
        probeID: String,
        trial: Int,
        attempt: Int = 1,
        outcome: Phase2QualificationProbeOutcome,
        reasonCode: String? = nil,
        evidenceDigest: String? = nil
    ) throws {
        guard phase2IsCategoricalToken(probeID, maximumBytes: 128),
              (1...100).contains(trial),
              (1...10).contains(attempt),
              reasonCode.map(phase2IsReasonCode) ?? true,
              evidenceDigest.map(phase2IsSHA256Hex) ?? true
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.probeID = probeID
        self.trial = trial
        self.attempt = attempt
        self.outcome = outcome
        self.reasonCode = reasonCode
        self.evidenceDigest = evidenceDigest
    }

    var trialID: String { "\(probeID)#\(trial)" }
    var attemptID: String { "\(trialID)#\(attempt)" }
}

struct Phase2QualificationAttemptMeasurements: Hashable, Sendable {
    let probeID: String
    let trial: Int
    let attempt: Int
    let measurements: Phase2QualificationMeasurements

    init(
        probeID: String,
        trial: Int,
        attempt: Int,
        measurements: Phase2QualificationMeasurements
    ) throws {
        guard phase2IsCategoricalToken(probeID, maximumBytes: 128),
              (1...100).contains(trial),
              (1...10).contains(attempt)
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.probeID = probeID
        self.trial = trial
        self.attempt = attempt
        self.measurements = measurements
    }

    var attemptID: String { "\(probeID)#\(trial)#\(attempt)" }
}

enum Phase2QualificationRunTerminationStatus: String, Hashable, Sendable {
    case completed
    case cancelled
    case failed
}

/// Deterministic input to the pure harness. It carries no endpoint authority, provider output,
/// prompt content, credentials, paths, private reasoning, or arbitrary error messages.
struct Phase2ModelQualificationRun: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidVersion
        case invalidTimeRange
        case tooManyObservations
    }

    let version: Int
    let profileID: Phase2ModelProfileID
    let policyIdentity: Phase2ProtocolComponentIdentity
    let protocolManifestDigest: String
    let corpusDigest: String
    let protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity?
    let liveQualificationCorpusIdentity: Phase2ProtocolComponentIdentity?
    let metricSemanticsIdentity: Phase2ProtocolComponentIdentity?
    let modelSource: String?
    let modelRevisionIdentity: Phase2ProtocolComponentIdentity?
    let productionDefinitionIdentity: Phase2ProtocolComponentIdentity?
    let evidenceBundle: Phase2QualificationEvidenceBundle?
    let environmentIdentity: Phase2ProtocolComponentIdentity?
    let runtimeProvenanceIdentity: Phase2ProtocolComponentIdentity?
    let measurementEvidenceIdentity: Phase2ProtocolComponentIdentity?
    let macScopeBuild: String
    let toolchainBuild: String
    let operatingSystemBuild: String
    let architecture: String
    let hardwareTier: Phase2HardwareTier
    let startedAtEpochMilliseconds: Int64
    let endedAtEpochMilliseconds: Int64
    let terminationStatus: Phase2QualificationRunTerminationStatus
    let measurements: Phase2QualificationMeasurements
    let attemptMeasurements: [Phase2QualificationAttemptMeasurements]
    let observations: [Phase2QualificationProbeObservation]

    init(
        version: Int,
        profileID: Phase2ModelProfileID,
        policyIdentity: Phase2ProtocolComponentIdentity,
        protocolManifestDigest: String,
        corpusDigest: String,
        macScopeBuild: String,
        toolchainBuild: String,
        operatingSystemBuild: String,
        architecture: String,
        hardwareTier: Phase2HardwareTier,
        startedAtEpochMilliseconds: Int64,
        endedAtEpochMilliseconds: Int64,
        terminationStatus: Phase2QualificationRunTerminationStatus = .completed,
        measurements: Phase2QualificationMeasurements = .empty,
        observations: [Phase2QualificationProbeObservation]
    ) throws {
        guard version == 1 else { throw ValidationError.invalidVersion }
        guard phase2IsSHA256Hex(protocolManifestDigest), phase2IsSHA256Hex(corpusDigest),
              phase2IsOpaqueToken(macScopeBuild, maximumBytes: 128),
              phase2IsOpaqueToken(toolchainBuild, maximumBytes: 128),
              phase2IsOpaqueToken(operatingSystemBuild, maximumBytes: 128),
              phase2IsOpaqueToken(architecture, maximumBytes: 32)
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        guard startedAtEpochMilliseconds >= 0,
              endedAtEpochMilliseconds >= startedAtEpochMilliseconds
        else { throw ValidationError.invalidTimeRange }
        guard observations.count <= 1_000 else { throw ValidationError.tooManyObservations }
        self.version = version
        self.profileID = profileID
        self.policyIdentity = policyIdentity
        self.protocolManifestDigest = protocolManifestDigest
        self.corpusDigest = corpusDigest
        self.protocolProbeCatalogIdentity = nil
        self.liveQualificationCorpusIdentity = nil
        self.metricSemanticsIdentity = nil
        self.modelSource = nil
        self.modelRevisionIdentity = nil
        self.productionDefinitionIdentity = nil
        self.evidenceBundle = nil
        self.environmentIdentity = nil
        self.runtimeProvenanceIdentity = nil
        self.measurementEvidenceIdentity = nil
        self.macScopeBuild = macScopeBuild
        self.toolchainBuild = toolchainBuild
        self.operatingSystemBuild = operatingSystemBuild
        self.architecture = architecture
        self.hardwareTier = hardwareTier
        self.startedAtEpochMilliseconds = startedAtEpochMilliseconds
        self.endedAtEpochMilliseconds = endedAtEpochMilliseconds
        self.terminationStatus = terminationStatus
        self.measurements = measurements
        self.attemptMeasurements = []
        self.observations = observations
    }

    /// CoreTests-owned F4A/F4C report composition consumes this immutable run value. The shipped
    /// app can build bounded run evidence but contains neither the report artifact nor its harness.
    init(
        version: Int,
        profileID: Phase2ModelProfileID,
        policyIdentity: Phase2ProtocolComponentIdentity,
        protocolManifestDigest: String,
        protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity,
        liveQualificationCorpusIdentity: Phase2ProtocolComponentIdentity,
        metricSemanticsIdentity: Phase2ProtocolComponentIdentity,
        evidenceBundle: Phase2QualificationEvidenceBundle,
        hardwareTier: Phase2HardwareTier,
        terminationStatus: Phase2QualificationRunTerminationStatus = .completed,
        observations: [Phase2QualificationProbeObservation]
    ) throws {
        guard version == 2 else { throw ValidationError.invalidVersion }
        let expectations = try Phase2QualificationEvidenceExpectations(
            evidenceBundle: evidenceBundle
        )
        let measurements = try evidenceBundle.aggregateMeasurements()
        let attemptMeasurements = try evidenceBundle.attemptMeasurements()
        let macScopeBuild = evidenceBundle.environment.bundleVersion
        let toolchainBuild = evidenceBundle.environment.xcodeBuild
        let operatingSystemBuild = evidenceBundle.environment.operatingSystemBuild
        let architecture = evidenceBundle.environment.architecture
        let startedAtEpochMilliseconds = evidenceBundle.runtimeProvenance
            .startedAtEpochMilliseconds
        let endedAtEpochMilliseconds = evidenceBundle.runtimeProvenance.endedAtEpochMilliseconds
        guard phase2IsSHA256Hex(protocolManifestDigest),
              protocolProbeCatalogIdentity.availability == .available,
              liveQualificationCorpusIdentity.availability == .available,
              metricSemanticsIdentity.availability == .available
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        guard startedAtEpochMilliseconds >= 0,
              endedAtEpochMilliseconds >= startedAtEpochMilliseconds
        else { throw ValidationError.invalidTimeRange }
        guard observations.count <= 1_000, attemptMeasurements.count <= 1_000 else {
            throw ValidationError.tooManyObservations
        }
        self.version = version
        self.profileID = profileID
        self.policyIdentity = policyIdentity
        self.protocolManifestDigest = protocolManifestDigest
        self.corpusDigest = liveQualificationCorpusIdentity.sha256!
        self.protocolProbeCatalogIdentity = protocolProbeCatalogIdentity
        self.liveQualificationCorpusIdentity = liveQualificationCorpusIdentity
        self.metricSemanticsIdentity = metricSemanticsIdentity
        self.modelSource = evidenceBundle.runtimeProvenance.modelSource
        self.modelRevisionIdentity = evidenceBundle.runtimeProvenance.modelRevisionIdentity
        self.productionDefinitionIdentity = evidenceBundle.runtimeProvenance
            .productionDefinitionIdentity
        self.evidenceBundle = evidenceBundle
        self.environmentIdentity = expectations.environmentIdentity
        self.runtimeProvenanceIdentity = expectations.runtimeProvenanceIdentity
        self.measurementEvidenceIdentity = expectations.measurementEvidenceIdentity
        self.macScopeBuild = macScopeBuild
        self.toolchainBuild = toolchainBuild
        self.operatingSystemBuild = operatingSystemBuild
        self.architecture = architecture
        self.hardwareTier = hardwareTier
        self.startedAtEpochMilliseconds = startedAtEpochMilliseconds
        self.endedAtEpochMilliseconds = endedAtEpochMilliseconds
        self.terminationStatus = terminationStatus
        self.measurements = measurements
        self.attemptMeasurements = attemptMeasurements
        self.observations = observations
    }
}

private func phase2IsReasonCode(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 128 else { return false }
    return bytes.allSatisfy { byte in
        (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x2D
            || byte == 0x2E
            || byte == 0x5F
    }
}
