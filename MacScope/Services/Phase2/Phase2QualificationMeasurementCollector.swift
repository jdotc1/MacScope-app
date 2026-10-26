import Foundation

enum Phase2QualificationMeasurementV2Error: Error, Equatable, Sendable {
    case invalidAttemptID
    case outOfRange
    case inconsistentSample
    case duplicateAttemptID
    case scopeMismatch
    case tooManySamples
    case overflow
    case invalidMetricPlan
    case outOfPlanAttemptID
    case admissionMismatch
    case duplicateObservationID
    case observationMismatch
    case duplicatePhase
    case clockRegression
}

struct Phase2QualificationTrialKey: Hashable, Comparable, Sendable {
    let requirementID: String
    let trialIndex: Int
    let attempt: Int

    init(requirementID: String, trialIndex: Int, attempt: Int) throws {
        guard phase2IsCategoricalToken(requirementID, maximumBytes: 128),
              (1...100).contains(trialIndex), attempt == 1
        else { throw Phase2QualificationMeasurementV2Error.invalidAttemptID }
        self.requirementID = requirementID
        self.trialIndex = trialIndex
        self.attempt = attempt
    }

    var canonicalID: String { "\(requirementID)#\(trialIndex)#1" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.requirementID != rhs.requirementID {
            return lhs.requirementID.utf8.lexicographicallyPrecedes(rhs.requirementID.utf8)
        }
        return lhs.trialIndex < rhs.trialIndex
    }
}

enum Phase2QualificationMeasuredPhase: String, CaseIterable, Hashable, Sendable {
    case toolSelection = "tool-selection"
    case finalization
}

struct Phase2QualificationPhaseUsage: Hashable, Sendable {
    let promptTokens: Int64
    let completionTokens: Int64
    let totalTokens: Int64

    init(promptTokens: Int64, completionTokens: Int64, totalTokens: Int64) throws {
        guard (0...1_000_000).contains(promptTokens),
              (0...1_000_000).contains(completionTokens),
              (0...2_000_000).contains(totalTokens)
        else { throw Phase2QualificationMeasurementV2Error.outOfRange }
        let (sum, overflow) = promptTokens.addingReportingOverflow(completionTokens)
        guard !overflow, sum == totalTokens else {
            throw Phase2QualificationMeasurementV2Error.inconsistentSample
        }
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

struct Phase2QualificationPhaseMeasurement: Hashable, Sendable {
    let phase: Phase2QualificationMeasuredPhase
    let usage: Phase2QualificationPhaseUsage
    let generationMilliseconds: Int64

    fileprivate init(
        phase: Phase2QualificationMeasuredPhase,
        usage: Phase2QualificationPhaseUsage,
        generationMilliseconds: Int64
    ) throws {
        guard (1...86_400_000).contains(generationMilliseconds) else {
            throw Phase2QualificationMeasurementV2Error.outOfRange
        }
        self.phase = phase
        self.usage = usage
        self.generationMilliseconds = generationMilliseconds
    }
}

struct Phase2QualificationResidentSetSnapshot: Hashable, Sendable {
    let appBytes: Int64
    let aiWorkerBytes: Int64
    let providerBytes: Int64

    init(appBytes: Int64, aiWorkerBytes: Int64, providerBytes: Int64) throws {
        let values = [appBytes, aiWorkerBytes, providerBytes]
        guard values.allSatisfy({ (0...1_099_511_627_776).contains($0) }) else {
            throw Phase2QualificationMeasurementV2Error.outOfRange
        }
        self.appBytes = appBytes
        self.aiWorkerBytes = aiWorkerBytes
        self.providerBytes = providerBytes
    }

    func checkedSum() throws -> Int64 {
        let (first, firstOverflow) = appBytes.addingReportingOverflow(aiWorkerBytes)
        let (total, secondOverflow) = first.addingReportingOverflow(providerBytes)
        guard !firstOverflow, !secondOverflow,
              total <= Phase2QualificationAttemptMeasurement.maximumResidentBytes
        else { throw Phase2QualificationMeasurementV2Error.overflow }
        return total
    }
}

protocol Phase2QualificationMonotonicClock: Sendable {
    func nowNanoseconds() throws -> UInt64
}

/// Declares what one sampler value proves. F4C accepts only complete contemporaneous scoped
/// snapshots and derives their observed maximum; independently collected per-process high-water
/// values cannot be substituted because their peaks need not occur at the same instant.
enum Phase2QualificationResidentSetMeasurementSemantics: Hashable, Sendable {
    case contemporaneousSnapshot
    case noncontemporaneousProcessHighWater
    case unsupported
}

protocol Phase2QualificationResidentSetSampling: Sendable {
    var measurementSemantics: Phase2QualificationResidentSetMeasurementSemantics { get }
    /// Returns nil unless app, exact embedded AI worker, and endpoint-bound provider are all scoped.
    func sample() throws -> Phase2QualificationResidentSetSnapshot?
}

extension Phase2QualificationResidentSetSampling {
    var measurementSemantics: Phase2QualificationResidentSetMeasurementSemantics {
        // The pre-existing protocol contract is a complete current-scope sample. Alternative
        // sources such as per-process lifetime maxima must opt out explicitly.
        .contemporaneousSnapshot
    }
}

struct Phase2ContinuousMonotonicClock: Phase2QualificationMonotonicClock {
    private let origin = ContinuousClock().now
    func nowNanoseconds() throws -> UInt64 {
        let duration = origin.duration(to: ContinuousClock().now).components
        guard duration.seconds >= 0, duration.attoseconds >= 0 else {
            throw Phase2QualificationMeasurementV2Error.clockRegression
        }
        let (seconds, overflow) = UInt64(duration.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        let fractional = UInt64(duration.attoseconds / 1_000_000_000)
        let (value, sumOverflow) = seconds.addingReportingOverflow(fractional)
        guard !overflow, !sumOverflow else { throw Phase2QualificationMeasurementV2Error.overflow }
        return value
    }
}

final class Phase2QualificationAttemptAccumulator: @unchecked Sendable {
    private let clock: any Phase2QualificationMonotonicClock
    private let residentSetSampler: any Phase2QualificationResidentSetSampling
    private let admissionNanoseconds: UInt64
    private var firstSemanticNanoseconds: UInt64?
    private var cancellationNanoseconds: UInt64?
    private var cancellationDrainNanoseconds: UInt64?
    private var terminalBoundaryNanoseconds: UInt64?
    private var phaseGenerationStarts: [Phase2QualificationMeasuredPhase: UInt64] = [:]
    private var phases: [Phase2QualificationMeasuredPhase: Phase2QualificationPhaseMeasurement] = [:]
    private var abandonedPhases: Set<Phase2QualificationMeasuredPhase> = []
    private var peakResidentBytes: Int64?
    private var residentScopeComplete = true
    private var finished = false
    private var lastEventNanoseconds: UInt64
    private let lock = NSLock()

    var residentScopeIsComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return residentScopeComplete
    }

    init(
        clock: any Phase2QualificationMonotonicClock,
        residentSetSampler: any Phase2QualificationResidentSetSampling
    ) throws {
        self.clock = clock
        self.residentSetSampler = residentSetSampler
        admissionNanoseconds = try clock.nowNanoseconds()
        lastEventNanoseconds = admissionNanoseconds
        if residentSetSampler.measurementSemantics == .contemporaneousSnapshot,
           let snapshot = try residentSetSampler.sample() {
            peakResidentBytes = try snapshot.checkedSum()
        } else {
            residentScopeComplete = false
        }
    }

    func recordFirstSemanticEvent() throws {
        lock.lock(); defer { lock.unlock() }
        guard firstSemanticNanoseconds == nil, !finished else {
            throw Phase2QualificationMeasurementV2Error.inconsistentSample
        }
        firstSemanticNanoseconds = try nextEventNanoseconds()
    }

    func beginPhaseGeneration(_ phase: Phase2QualificationMeasuredPhase) throws {
        lock.lock(); defer { lock.unlock() }
        guard phaseGenerationStarts[phase] == nil,
              phases[phase] == nil,
              !abandonedPhases.contains(phase),
              !finished
        else {
            throw Phase2QualificationMeasurementV2Error.duplicatePhase
        }
        phaseGenerationStarts[phase] = try nextEventNanoseconds()
    }

    func endPhaseGeneration(
        _ phase: Phase2QualificationMeasuredPhase,
        usage: Phase2QualificationPhaseUsage
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard let start = phaseGenerationStarts[phase], phases[phase] == nil, !finished else {
            throw Phase2QualificationMeasurementV2Error.inconsistentSample
        }
        let end = try nextEventNanoseconds()
        guard end > start else { throw Phase2QualificationMeasurementV2Error.outOfRange }
        let duration = try Self.milliseconds(from: start, to: end)
        guard duration > 0 else { throw Phase2QualificationMeasurementV2Error.outOfRange }
        phases[phase] = try .init(
            phase: phase, usage: usage, generationMilliseconds: duration
        )
        phaseGenerationStarts.removeValue(forKey: phase)
    }

    /// Closes an admitted phase at its provider-drain boundary when exact usage was unavailable.
    /// No phase measurement is synthesized, so token and generation aggregates remain nil.
    func abandonPhaseGeneration(_ phase: Phase2QualificationMeasuredPhase) throws {
        lock.lock(); defer { lock.unlock() }
        guard phaseGenerationStarts[phase] != nil,
              phases[phase] == nil,
              !abandonedPhases.contains(phase),
              !finished
        else {
            throw Phase2QualificationMeasurementV2Error.inconsistentSample
        }
        _ = try nextEventNanoseconds()
        phaseGenerationStarts.removeValue(forKey: phase)
        abandonedPhases.insert(phase)
    }

    func recordResidentSet() throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { throw Phase2QualificationMeasurementV2Error.inconsistentSample }
        guard residentScopeComplete,
              residentSetSampler.measurementSemantics == .contemporaneousSnapshot
        else {
            residentScopeComplete = false
            peakResidentBytes = nil
            return
        }
        guard let snapshot = try residentSetSampler.sample() else {
            residentScopeComplete = false
            peakResidentBytes = nil
            return
        }
        if residentScopeComplete {
            peakResidentBytes = max(peakResidentBytes ?? 0, try snapshot.checkedSum())
        }
    }

    func recordCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        guard cancellationNanoseconds == nil,
              cancellationDrainNanoseconds == nil,
              !finished
        else {
            throw Phase2QualificationMeasurementV2Error.inconsistentSample
        }
        cancellationNanoseconds = try nextEventNanoseconds()
    }

    /// Records the exact provider-drain boundary. Final lease/runtime revalidation occurs later
    /// and remains part of total attempt latency, but not cancellation latency.
    func recordCancellationDrain() throws {
        lock.lock(); defer { lock.unlock() }
        guard cancellationNanoseconds != nil,
              cancellationDrainNanoseconds == nil,
              !finished
        else {
            throw Phase2QualificationMeasurementV2Error.inconsistentSample
        }
        cancellationDrainNanoseconds = try nextEventNanoseconds()
    }

    /// Captures the post-provider, post-lease/runtime-validation boundary. It may advance between
    /// phases of one logical attempt, but semantic scoring after the final boundary is excluded.
    func recordTerminalBoundary() throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else {
            throw Phase2QualificationMeasurementV2Error.inconsistentSample
        }
        terminalBoundaryNanoseconds = try nextEventNanoseconds()
    }

    /// Call only after final lease revalidation or cancellation drain has completed.
    func finish(
        trialKey: Phase2QualificationTrialKey,
        scope: Phase2ProtocolComponentIdentity
    ) throws -> Phase2QualificationAttemptMeasurement {
        lock.lock(); defer { lock.unlock() }
        guard !finished,
              phaseGenerationStarts.isEmpty,
              (cancellationNanoseconds == nil) == (cancellationDrainNanoseconds == nil),
              let terminal = terminalBoundaryNanoseconds
        else {
            throw Phase2QualificationMeasurementV2Error.inconsistentSample
        }
        finished = true
        return try .init(
            trialKey: trialKey,
            totalLatencyMilliseconds: try Self.milliseconds(
                from: admissionNanoseconds, to: terminal
            ),
            timeToFirstSemanticEventMilliseconds: try firstSemanticNanoseconds.map {
                try Self.milliseconds(from: admissionNanoseconds, to: $0)
            },
            phaseUsages: Phase2QualificationMeasuredPhase.allCases.compactMap { phases[$0] },
            peakResidentBytes: residentScopeComplete ? peakResidentBytes : nil,
            cancellationLatencyMilliseconds: try cancellationNanoseconds.map { cancellation in
                try Self.milliseconds(
                    from: cancellation,
                    to: cancellationDrainNanoseconds!
                )
            },
            measurementScopeIdentity: scope
        )
    }

    private func nextEventNanoseconds() throws -> UInt64 {
        let now = try clock.nowNanoseconds()
        guard now >= lastEventNanoseconds else {
            throw Phase2QualificationMeasurementV2Error.clockRegression
        }
        lastEventNanoseconds = now
        return now
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) throws -> Int64 {
        guard end >= start else { throw Phase2QualificationMeasurementV2Error.clockRegression }
        let (nanoseconds, underflow) = end.subtractingReportingOverflow(start)
        guard !underflow else { throw Phase2QualificationMeasurementV2Error.clockRegression }
        let milliseconds = nanoseconds / 1_000_000
        guard milliseconds <= UInt64(Int64.max) else {
            throw Phase2QualificationMeasurementV2Error.overflow
        }
        return Int64(milliseconds)
    }
}

struct Phase2QualificationAttemptMeasurement: Hashable, Sendable {
    static let maximumLatencyMilliseconds: Int64 = 86_400_000
    static let maximumGeneratedTokens: Int64 = 1_000_000
    static let maximumResidentBytes: Int64 = 1_099_511_627_776

    let trialKey: Phase2QualificationTrialKey
    let totalLatencyMilliseconds: Int64
    let timeToFirstSemanticEventMilliseconds: Int64?
    let phaseUsages: [Phase2QualificationPhaseMeasurement]
    let peakResidentBytes: Int64?
    let cancellationLatencyMilliseconds: Int64?
    let measurementScopeIdentity: Phase2ProtocolComponentIdentity

    var generatedTokenCount: Int64? { try? checkedPhaseSum(\.usage.completionTokens) }
    var generationMilliseconds: Int64? { try? checkedPhaseSum(\.generationMilliseconds) }

    init(
        trialKey: Phase2QualificationTrialKey,
        totalLatencyMilliseconds: Int64,
        timeToFirstSemanticEventMilliseconds: Int64?,
        phaseUsages: [Phase2QualificationPhaseMeasurement],
        peakResidentBytes: Int64?,
        cancellationLatencyMilliseconds: Int64?,
        measurementScopeIdentity: Phase2ProtocolComponentIdentity
    ) throws {
        guard (0...Self.maximumLatencyMilliseconds).contains(totalLatencyMilliseconds),
              timeToFirstSemanticEventMilliseconds.map({ (0...totalLatencyMilliseconds).contains($0) }) ?? true,
              peakResidentBytes.map({ (0...Self.maximumResidentBytes).contains($0) }) ?? true,
              cancellationLatencyMilliseconds.map({ (0...totalLatencyMilliseconds).contains($0) }) ?? true,
              Set(phaseUsages.map(\.phase)).count == phaseUsages.count,
              phaseUsages == Phase2QualificationMeasuredPhase.allCases.compactMap({ phase in
                  phaseUsages.first(where: { $0.phase == phase })
              })
        else { throw Phase2QualificationMeasurementV2Error.outOfRange }
        guard measurementScopeIdentity.availability == .available,
              measurementScopeIdentity.sha256 != nil
        else { throw Phase2QualificationMeasurementV2Error.scopeMismatch }
        self.trialKey = trialKey
        self.totalLatencyMilliseconds = totalLatencyMilliseconds
        self.timeToFirstSemanticEventMilliseconds = timeToFirstSemanticEventMilliseconds
        self.phaseUsages = phaseUsages
        self.peakResidentBytes = peakResidentBytes
        self.cancellationLatencyMilliseconds = cancellationLatencyMilliseconds
        self.measurementScopeIdentity = measurementScopeIdentity
        guard (try checkedPhaseSum(\.usage.completionTokens) ?? 0) <= Self.maximumGeneratedTokens,
              (try checkedPhaseSum(\.generationMilliseconds) ?? 0) <= Self.maximumLatencyMilliseconds
        else { throw Phase2QualificationMeasurementV2Error.outOfRange }
    }

    private func checkedPhaseSum(_ keyPath: KeyPath<Phase2QualificationPhaseMeasurement, Int64>) throws -> Int64? {
        guard !phaseUsages.isEmpty else { return nil }
        var sum: Int64 = 0
        for phase in phaseUsages {
            let (next, overflow) = sum.addingReportingOverflow(phase[keyPath: keyPath])
            guard !overflow else { throw Phase2QualificationMeasurementV2Error.overflow }
            sum = next
        }
        return sum
    }
}

enum Phase2QualificationMeasurementV2Kind: String, CaseIterable, Hashable, Sendable {
    case totalLatencyMilliseconds = "total-latency-milliseconds"
    case timeToFirstSemanticEventMilliseconds = "time-to-first-semantic-event-milliseconds"
    case generatedTokenCount = "generated-token-count"
    case throughputMilliTokensPerSecond = "throughput-millitokens-per-second"
    case peakResidentBytes = "peak-resident-bytes"
    case varianceBasisPoints = "variance-basis-points"
    case cancellationLatencyMilliseconds = "cancellation-latency-milliseconds"
}

struct Phase2QualificationMetricPlan: Sendable {
    let applicableTrialKeys: [Phase2QualificationMeasurementV2Kind: Set<Phase2QualificationTrialKey>]
    let varianceRequirementID: String?

    init(
        applicableTrialKeys: [Phase2QualificationMeasurementV2Kind: Set<Phase2QualificationTrialKey>],
        varianceRequirementID: String? = nil
    ) throws {
        guard !applicableTrialKeys.isEmpty,
              applicableTrialKeys.values.allSatisfy({ !$0.isEmpty })
        else { throw Phase2QualificationMeasurementV2Error.invalidMetricPlan }
        if let varianceKeys = applicableTrialKeys[.varianceBasisPoints] {
            guard let varianceRequirementID,
                  varianceKeys.count == 5,
                  varianceKeys == Set(try (1...5).map {
                      try Phase2QualificationTrialKey(
                          requirementID: varianceRequirementID, trialIndex: $0, attempt: 1
                      )
                  })
            else { throw Phase2QualificationMeasurementV2Error.invalidMetricPlan }
        } else if varianceRequirementID != nil {
            throw Phase2QualificationMeasurementV2Error.invalidMetricPlan
        }
        self.applicableTrialKeys = applicableTrialKeys
        self.varianceRequirementID = varianceRequirementID
    }

    func contentIdentity() throws -> Phase2ProtocolComponentIdentity {
        let applicability: [[String: Any]] = Phase2QualificationMeasurementV2Kind
            .allCases.compactMap { kind -> [String: Any]? in
                guard let keys = applicableTrialKeys[kind] else { return nil }
                return [
                    "kind": kind.rawValue,
                    "trial_keys": keys.sorted().map(\.canonicalID),
                ]
            }
        return try Phase2QualificationV2Identity.make(
            id: "phase2.r1.qualification-metric-plan.v2", version: 2,
            object: [
                "applicability": applicability,
                "variance_requirement_id": varianceRequirementID.map { $0 as Any } ?? NSNull(),
            ]
        )
    }

    func containsEveryApplicableValue(
        in sample: Phase2QualificationAttemptMeasurement
    ) -> Bool {
        for (kind, keys) in applicableTrialKeys where keys.contains(sample.trialKey) {
            switch kind {
            case .totalLatencyMilliseconds, .varianceBasisPoints:
                break
            case .timeToFirstSemanticEventMilliseconds:
                guard sample.timeToFirstSemanticEventMilliseconds != nil else { return false }
            case .generatedTokenCount:
                guard sample.generatedTokenCount != nil else { return false }
            case .throughputMilliTokensPerSecond:
                guard sample.generatedTokenCount != nil,
                      sample.generationMilliseconds != nil
                else { return false }
            case .peakResidentBytes:
                guard sample.peakResidentBytes != nil else { return false }
            case .cancellationLatencyMilliseconds:
                guard sample.cancellationLatencyMilliseconds != nil else { return false }
            }
        }
        return true
    }
}

struct Phase2QualificationMeasurementsV2: Hashable, Sendable {
    let totalLatencyMilliseconds: Int64?
    let timeToFirstSemanticEventMilliseconds: Int64?
    let generatedTokenCount: Int64?
    let throughputMilliTokensPerSecond: Int64?
    let peakResidentBytes: Int64?
    let varianceBasisPoints: Int64?
    let cancellationLatencyMilliseconds: Int64?
}

struct Phase2QualificationMeasurementAggregate: Hashable, Sendable {
    let scopeIdentity: Phase2ProtocolComponentIdentity
    let metricPlanIdentity: Phase2ProtocolComponentIdentity
    let samples: [Phase2QualificationAttemptMeasurement]
    let measurements: Phase2QualificationMeasurementsV2

    func contentIdentity() throws -> Phase2ProtocolComponentIdentity {
        try Phase2QualificationV2Identity.make(
            id: "phase2.r1.qualification-measurements.v2", version: 2,
            object: [
                "metric_plan": component(metricPlanIdentity),
                "measurements": measurementObject,
                "samples": samples.map(Self.sampleObject),
                "scope": component(scopeIdentity),
            ]
        )
    }

    private var measurementObject: [String: Any] {
        [
            "cancellation_latency_milliseconds": measurements.cancellationLatencyMilliseconds.map { $0 as Any } ?? NSNull(),
            "generated_token_count": measurements.generatedTokenCount.map { $0 as Any } ?? NSNull(),
            "peak_resident_bytes": measurements.peakResidentBytes.map { $0 as Any } ?? NSNull(),
            "throughput_millitokens_per_second": measurements.throughputMilliTokensPerSecond.map { $0 as Any } ?? NSNull(),
            "time_to_first_semantic_event_milliseconds": measurements.timeToFirstSemanticEventMilliseconds.map { $0 as Any } ?? NSNull(),
            "total_latency_milliseconds": measurements.totalLatencyMilliseconds.map { $0 as Any } ?? NSNull(),
            "variance_basis_points": measurements.varianceBasisPoints.map { $0 as Any } ?? NSNull(),
        ]
    }

    private func component(_ identity: Phase2ProtocolComponentIdentity) -> [String: Any] {
        ["id": identity.id, "sha256": identity.sha256!, "version": identity.version]
    }

    private static func sampleObject(_ sample: Phase2QualificationAttemptMeasurement) -> [String: Any] {
        [
            "attempt_id": sample.trialKey.canonicalID,
            "cancellation_latency_milliseconds": sample.cancellationLatencyMilliseconds.map { $0 as Any } ?? NSNull(),
            "peak_resident_bytes": sample.peakResidentBytes.map { $0 as Any } ?? NSNull(),
            "phase_usage": sample.phaseUsages.map { phase in
                [
                    "completion_tokens": phase.usage.completionTokens,
                    "generation_milliseconds": phase.generationMilliseconds,
                    "phase": phase.phase.rawValue,
                    "prompt_tokens": phase.usage.promptTokens,
                    "total_tokens": phase.usage.totalTokens,
                ] as [String: Any]
            },
            "time_to_first_semantic_event_milliseconds": sample.timeToFirstSemanticEventMilliseconds.map { $0 as Any } ?? NSNull(),
            "total_latency_milliseconds": sample.totalLatencyMilliseconds,
        ]
    }
}

struct Phase2QualificationMeasurementCollector: Sendable {
    func aggregate(
        samples: [Phase2QualificationAttemptMeasurement],
        observations: [Phase2QualificationProbeObservation],
        plannedTrialKeys: [Phase2QualificationTrialKey],
        admittedAttemptKeys: [Phase2QualificationTrialKey],
        scope: Phase2ProtocolComponentIdentity,
        metricPlan: Phase2QualificationMetricPlan
    ) throws -> Phase2QualificationMeasurementAggregate {
        guard !plannedTrialKeys.isEmpty,
              plannedTrialKeys.count <= 1_000,
              admittedAttemptKeys.count <= 1_000,
              samples.count <= 1_000,
              observations.count <= 1_000
        else { throw Phase2QualificationMeasurementV2Error.tooManySamples }

        let planned = Set(plannedTrialKeys)
        guard planned.count == plannedTrialKeys.count else {
            throw Phase2QualificationMeasurementV2Error.duplicateAttemptID
        }

        var admitted: Set<Phase2QualificationTrialKey> = []
        for key in admittedAttemptKeys {
            guard planned.contains(key) else {
                throw Phase2QualificationMeasurementV2Error.outOfPlanAttemptID
            }
            guard admitted.insert(key).inserted else {
                throw Phase2QualificationMeasurementV2Error.duplicateAttemptID
            }
        }

        var byKey: [Phase2QualificationTrialKey: Phase2QualificationAttemptMeasurement] = [:]
        for sample in samples {
            guard planned.contains(sample.trialKey) else {
                throw Phase2QualificationMeasurementV2Error.outOfPlanAttemptID
            }
            guard admitted.contains(sample.trialKey) else {
                throw Phase2QualificationMeasurementV2Error.admissionMismatch
            }
            guard byKey.updateValue(sample, forKey: sample.trialKey) == nil else {
                throw Phase2QualificationMeasurementV2Error.duplicateAttemptID
            }
            guard sample.measurementScopeIdentity == scope else {
                throw Phase2QualificationMeasurementV2Error.scopeMismatch
            }
        }
        guard Set(byKey.keys) == admitted else {
            throw Phase2QualificationMeasurementV2Error.admissionMismatch
        }

        var observationsByKey: [
            Phase2QualificationTrialKey: Phase2QualificationProbeObservation
        ] = [:]
        for observation in observations {
            guard observation.attempt == 1 else {
                throw Phase2QualificationMeasurementV2Error.outOfPlanAttemptID
            }
            let key = try Phase2QualificationTrialKey(
                requirementID: observation.probeID,
                trialIndex: observation.trial,
                attempt: observation.attempt
            )
            guard planned.contains(key) else {
                throw Phase2QualificationMeasurementV2Error.outOfPlanAttemptID
            }
            guard observationsByKey.updateValue(observation, forKey: key) == nil else {
                throw Phase2QualificationMeasurementV2Error.duplicateObservationID
            }
            guard Self.isCategoricallyValid(observation) else {
                throw Phase2QualificationMeasurementV2Error.inconsistentSample
            }
        }
        guard Set(observationsByKey.keys) == planned else {
            throw Phase2QualificationMeasurementV2Error.observationMismatch
        }

        let declared = metricPlan.applicableTrialKeys.values.reduce(
            into: Set<Phase2QualificationTrialKey>()
        ) { $0.formUnion($1) }
        guard declared.isSubset(of: planned), declared.isSubset(of: admitted) else {
            throw Phase2QualificationMeasurementV2Error.invalidMetricPlan
        }
        let passedObservationKeys = Set(observationsByKey.compactMap { key, observation in
            observation.outcome == .passed ? key : nil
        })
        func selected(_ kind: Phase2QualificationMeasurementV2Kind) -> [Phase2QualificationAttemptMeasurement] {
            (metricPlan.applicableTrialKeys[kind] ?? []).sorted().compactMap { byKey[$0] }
        }
        let latency = try sum(selected(.totalLatencyMilliseconds).map { Optional($0.totalLatencyMilliseconds) })
        let first = try sum(selected(.timeToFirstSemanticEventMilliseconds).map(\.timeToFirstSemanticEventMilliseconds))
        let tokens = try sum(selected(.generatedTokenCount).map(\.generatedTokenCount))
        let throughputSamples = selected(.throughputMilliTokensPerSecond)
        let throughputTokens = try sum(throughputSamples.map(\.generatedTokenCount))
        let generation = try sum(throughputSamples.map(\.generationMilliseconds))
        let cancellation = try sum(selected(.cancellationLatencyMilliseconds).map(\.cancellationLatencyMilliseconds))
        let peak = completeValues(selected(.peakResidentBytes).map(\.peakResidentBytes))?.max()
        let varianceSamples = selected(.varianceBasisPoints)
        let variance = varianceSamples.count == 5
            && Set(varianceSamples.map(\.trialKey)).isSubset(of: passedObservationKeys)
            ? try Self.varianceBasisPoints(varianceSamples.map(\.totalLatencyMilliseconds))
            : nil
        let canonicalSamples = samples.sorted { $0.trialKey < $1.trialKey }
        return .init(
            scopeIdentity: scope,
            metricPlanIdentity: try metricPlan.contentIdentity(),
            samples: canonicalSamples,
            measurements: .init(
                totalLatencyMilliseconds: latency,
                timeToFirstSemanticEventMilliseconds: first,
                generatedTokenCount: tokens,
                throughputMilliTokensPerSecond: try Self.throughput(
                    completionTokens: throughputTokens, generationMilliseconds: generation
                ),
                peakResidentBytes: peak,
                varianceBasisPoints: variance,
                cancellationLatencyMilliseconds: cancellation
            )
        )
    }

    private static func isCategoricallyValid(
        _ observation: Phase2QualificationProbeObservation
    ) -> Bool {
        switch observation.outcome {
        case .passed:
            observation.reasonCode == nil && observation.evidenceDigest != nil
        case .failed:
            observation.reasonCode != nil && observation.evidenceDigest != nil
        case .unavailable, .cancelled, .notRun:
            observation.reasonCode != nil && observation.evidenceDigest == nil
        }
    }

    static func throughput(completionTokens: Int64?, generationMilliseconds: Int64?) throws -> Int64? {
        guard let completionTokens, let generationMilliseconds else { return nil }
        guard completionTokens >= 0, generationMilliseconds > 0 else {
            throw Phase2QualificationMeasurementV2Error.outOfRange
        }
        let (scaled, overflow) = completionTokens.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { throw Phase2QualificationMeasurementV2Error.overflow }
        return scaled / generationMilliseconds
    }

    static func varianceBasisPoints(_ values: [Int64]) throws -> Int64? {
        guard values.count == 5, values.allSatisfy({ $0 >= 0 }) else {
            throw Phase2QualificationMeasurementV2Error.outOfRange
        }
        let doubles = values.map(Double.init)
        let mean = doubles.reduce(Double(0), +) / 5
        guard mean > 0 else { return nil }
        let populationVariance = doubles.reduce(Double(0)) { result, value in
            let delta = value - mean
            return result + delta * delta
        } / 5
        let scaled = (populationVariance.squareRoot() / mean) * 10_000
        return try roundedBasisPoints(scaled)
    }

    static func roundedBasisPoints(_ scaled: Double) throws -> Int64 {
        guard scaled.isFinite, scaled >= 0, scaled <= Double(Int64.max) else {
            throw Phase2QualificationMeasurementV2Error.overflow
        }
        return Int64(scaled.rounded(.toNearestOrAwayFromZero))
    }

    private func sum(_ values: [Int64?]) throws -> Int64? {
        guard let values = completeValues(values) else { return nil }
        var total: Int64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { throw Phase2QualificationMeasurementV2Error.overflow }
            total = next
        }
        return total
    }

    private func completeValues<T>(_ values: [T?]) -> [T]? {
        guard !values.isEmpty else { return nil }
        let complete = values.compactMap { $0 }
        return complete.count == values.count ? complete : nil
    }
}
