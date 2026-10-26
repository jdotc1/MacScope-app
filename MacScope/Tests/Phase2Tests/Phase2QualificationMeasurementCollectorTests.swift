import XCTest
@testable import MacScope

final class Phase2QualificationMeasurementCollectorTests: XCTestCase {
    func testTrialKeyRequiresAttemptOneAndSortsCanonically() throws {
        XCTAssertThrowsError(try Phase2QualificationTrialKey(
            requirementID: "live.performance.variance", trialIndex: 1, attempt: 2
        ))
        let keys = try [5, 1, 3, 2, 4].map {
            try Phase2QualificationTrialKey(
                requirementID: "live.performance.variance", trialIndex: $0, attempt: 1
            )
        }
        XCTAssertEqual(keys.sorted().map(\.canonicalID), (1...5).map {
            "live.performance.variance#\($0)#1"
        })
    }

    func testUsageRequiresCheckedPromptPlusCompletionEqualsTotal() throws {
        XCTAssertThrowsError(try Phase2QualificationPhaseUsage(
            promptTokens: 4, completionTokens: 3, totalTokens: 8
        ))
        XCTAssertEqual(try Phase2QualificationPhaseUsage(
            promptTokens: 4, completionTokens: 3, totalTokens: 7
        ).completionTokens, 3)
    }

    func testInjectedAccumulatorMeasuresAdmissionThroughFinishAndPerPhaseUsage() throws {
        let clock = TestClock([
            0, 10_000_000, 20_000_000, 30_000_000,
            40_000_000, 60_000_000, 80_000_000,
        ])
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: clock,
            residentSetSampler: TestRSSSampler([.init(appBytes: 100, aiWorkerBytes: 200, providerBytes: 300)])
        )
        try accumulator.recordFirstSemanticEvent()
        try accumulator.beginPhaseGeneration(.toolSelection)
        try accumulator.endPhaseGeneration(
            .toolSelection, usage: .init(promptTokens: 5, completionTokens: 2, totalTokens: 7)
        )
        try accumulator.beginPhaseGeneration(.finalization)
        try accumulator.endPhaseGeneration(
            .finalization, usage: .init(promptTokens: 6, completionTokens: 3, totalTokens: 9)
        )
        try accumulator.recordTerminalBoundary()
        let sample = try accumulator.finish(trialKey: key("live.standard", 1), scope: scope())

        XCTAssertEqual(sample.totalLatencyMilliseconds, 80)
        XCTAssertEqual(sample.timeToFirstSemanticEventMilliseconds, 10)
        XCTAssertEqual(sample.phaseUsages.map(\.phase), [.toolSelection, .finalization])
        XCTAssertEqual(sample.generatedTokenCount, 5)
        XCTAssertEqual(sample.generationMilliseconds, 30)
        XCTAssertEqual(sample.peakResidentBytes, 600)
    }

    func testPhaseGenerationRejectsZeroDurationDuplicateAndMissingUsage() throws {
        let zero = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 10, 10]), residentSetSampler: TestRSSSampler([nil])
        )
        try zero.beginPhaseGeneration(.finalization)
        XCTAssertThrowsError(try zero.endPhaseGeneration(
            .finalization, usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2)
        ))

        let duplicate = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 10, 20]), residentSetSampler: TestRSSSampler([nil])
        )
        try duplicate.beginPhaseGeneration(.finalization)
        XCTAssertThrowsError(try duplicate.beginPhaseGeneration(.finalization))

        let missingUsage = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 10, 20]), residentSetSampler: TestRSSSampler([nil])
        )
        try missingUsage.beginPhaseGeneration(.finalization)
        XCTAssertThrowsError(try missingUsage.finish(
            trialKey: key("live.missing-usage", 1), scope: scope()
        ))
    }

    func testAbandonPhaseGenerationAtDrainRetainsValidPartialAttempt() throws {
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([
                0, 10_000_000, 20_000_000, 30_000_000,
                40_000_000, 40_000_000, 50_000_000,
            ]),
            residentSetSampler: TestRSSSampler([
                .init(appBytes: 100, aiWorkerBytes: 200, providerBytes: 300),
            ])
        )
        try accumulator.recordFirstSemanticEvent()
        try accumulator.beginPhaseGeneration(.finalization)
        try accumulator.recordCancellation()
        try accumulator.recordCancellationDrain()
        try accumulator.abandonPhaseGeneration(.finalization)
        try accumulator.recordTerminalBoundary()

        let sample = try accumulator.finish(
            trialKey: key("live.partial-cancellation", 1), scope: scope()
        )

        XCTAssertEqual(sample.totalLatencyMilliseconds, 50)
        XCTAssertEqual(sample.timeToFirstSemanticEventMilliseconds, 10)
        XCTAssertEqual(sample.peakResidentBytes, 600)
        XCTAssertEqual(sample.cancellationLatencyMilliseconds, 10)
        XCTAssertTrue(sample.phaseUsages.isEmpty)
        XCTAssertNil(sample.generatedTokenCount)
        XCTAssertNil(sample.generationMilliseconds)
    }

    func testAbandonPhaseGenerationRejectsInvalidOrdering() throws {
        let beforeBegin = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0]), residentSetSampler: TestRSSSampler([nil])
        )
        XCTAssertThrowsError(try beforeBegin.abandonPhaseGeneration(.finalization)) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .inconsistentSample
            )
        }

        let duplicate = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 10, 20]), residentSetSampler: TestRSSSampler([nil])
        )
        try duplicate.beginPhaseGeneration(.finalization)
        try duplicate.abandonPhaseGeneration(.finalization)
        XCTAssertThrowsError(try duplicate.abandonPhaseGeneration(.finalization)) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .inconsistentSample
            )
        }
        XCTAssertThrowsError(try duplicate.beginPhaseGeneration(.finalization)) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .duplicatePhase
            )
        }

        let afterEnd = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 10_000_000, 20_000_000]),
            residentSetSampler: TestRSSSampler([nil])
        )
        try afterEnd.beginPhaseGeneration(.finalization)
        try afterEnd.endPhaseGeneration(
            .finalization,
            usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2)
        )
        XCTAssertThrowsError(try afterEnd.abandonPhaseGeneration(.finalization)) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .inconsistentSample
            )
        }
    }

    func testClockRegressionThrowsBeforeCancellationOrPhaseSubtraction() throws {
        let cancellation = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 70_000_000, 40_000_000]),
            residentSetSampler: TestRSSSampler([nil])
        )
        try cancellation.recordCancellation()
        XCTAssertThrowsError(try cancellation.recordCancellationDrain()) { error in
            XCTAssertEqual(error as? Phase2QualificationMeasurementV2Error, .clockRegression)
        }

        let phase = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 70_000_000, 40_000_000]),
            residentSetSampler: TestRSSSampler([nil])
        )
        try phase.beginPhaseGeneration(.finalization)
        XCTAssertThrowsError(try phase.endPhaseGeneration(
            .finalization, usage: .init(promptTokens: 1, completionTokens: 1, totalTokens: 2)
        )) { error in
            XCTAssertEqual(error as? Phase2QualificationMeasurementV2Error, .clockRegression)
        }
    }

    func testResidentSetBecomesNilWhenExactThreeProcessAuthorityIsIncomplete() throws {
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 10_000_000]),
            residentSetSampler: TestRSSSampler([nil])
        )
        try accumulator.recordTerminalBoundary()
        XCTAssertNil(try accumulator.finish(
            trialKey: key("live.standard", 1), scope: scope()
        ).peakResidentBytes)
    }

    func testContemporaneousResidentSetSnapshotsPopulateObservedMaximum() throws {
        let sampler = ContemporaneousSnapshotRSSSampler([
            try .init(appBytes: 10, aiWorkerBytes: 20, providerBytes: 30),
            try .init(appBytes: 1, aiWorkerBytes: 2, providerBytes: 3),
        ])
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 10_000_000]),
            residentSetSampler: sampler
        )

        try accumulator.recordResidentSet()
        try accumulator.recordTerminalBoundary()
        let sample = try accumulator.finish(
            trialKey: key("live.standard", 1),
            scope: scope()
        )

        XCTAssertTrue(accumulator.residentScopeIsComplete)
        XCTAssertEqual(sample.peakResidentBytes, 60)
        XCTAssertEqual(sampler.sampleCount, 2)
    }

    func testNoncontemporaneousProcessHighWaterCannotPopulatePeakResidentBytes() throws {
        let sampler = NoncontemporaneousHighWaterRSSSampler(
            try .init(appBytes: 100, aiWorkerBytes: 200, providerBytes: 300)
        )
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 10_000_000]),
            residentSetSampler: sampler
        )

        try accumulator.recordResidentSet()
        try accumulator.recordTerminalBoundary()
        let sample = try accumulator.finish(
            trialKey: key("live.standard", 1),
            scope: scope()
        )

        XCTAssertFalse(accumulator.residentScopeIsComplete)
        XCTAssertNil(sample.peakResidentBytes)
        XCTAssertEqual(sampler.sampleCount, 0)
    }

    func testAggregateUsesExactPolicyDeclaredMetricSubsets() throws {
        let standard = try key("live.performance.standard", 1)
        let variance = try (1...5).map { try key("live.performance.variance", $0) }
        let all = [standard] + variance
        let samples = try all.enumerated().map { offset, key in
            try sample(key, latency: Int64((offset + 1) * 100), first: 10,
                       completion: 10, generation: 50, peak: Int64(1000 + offset))
        }
        let plan = try Phase2QualificationMetricPlan(
            applicableTrialKeys: [
                .totalLatencyMilliseconds: Set([standard]),
                .timeToFirstSemanticEventMilliseconds: Set([standard]),
                .generatedTokenCount: Set([standard]),
                .throughputMilliTokensPerSecond: Set([standard]),
                .peakResidentBytes: Set(all),
                .varianceBasisPoints: Set(variance),
            ],
            varianceRequirementID: "live.performance.variance"
        )
        let result = try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: try all.map { try observation($0, outcome: .passed) },
            plannedTrialKeys: all,
            admittedAttemptKeys: all,
            scope: scope(),
            metricPlan: plan
        )

        XCTAssertEqual(result.measurements.totalLatencyMilliseconds, 100)
        XCTAssertEqual(result.measurements.generatedTokenCount, 10)
        XCTAssertEqual(result.measurements.throughputMilliTokensPerSecond, 200_000)
        XCTAssertEqual(result.measurements.peakResidentBytes, 1005)
        XCTAssertEqual(result.measurements.varianceBasisPoints, 3_536)
        XCTAssertNil(result.measurements.cancellationLatencyMilliseconds)
        XCTAssertEqual(result.metricPlanIdentity, try plan.contentIdentity())
        XCTAssertEqual(
            result.metricPlanIdentity.id,
            "phase2.r1.qualification-metric-plan.v2"
        )
        XCTAssertEqual(result.metricPlanIdentity.version, 2)
    }

    func testVarianceRequiresExactlyFivePassedDeclaredTrialObservations() throws {
        let keys = try (1...5).map { try key("live.performance.variance", $0) }
        let plan = try Phase2QualificationMetricPlan(
            applicableTrialKeys: [.varianceBasisPoints: Set(keys)],
            varianceRequirementID: "live.performance.variance"
        )
        let samples = try keys.map { try sample($0, latency: Int64($0.trialIndex * 100)) }
        XCTAssertNil(try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: try keys.enumerated().map { offset, key in
                try observation(key, outcome: offset == keys.count - 1 ? .failed : .passed)
            },
            plannedTrialKeys: keys,
            admittedAttemptKeys: keys,
            scope: scope(),
            metricPlan: plan
        ).measurements.varianceBasisPoints)
        XCTAssertNotNil(try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: try keys.map { try observation($0, outcome: .passed) },
            plannedTrialKeys: keys,
            admittedAttemptKeys: keys,
            scope: scope(),
            metricPlan: plan
        ).measurements.varianceBasisPoints)
    }

    func testVarianceCannotBeForgedByCompleteSamplesWhenObservationFailed() throws {
        let keys = try (1...5).map { try key("live.performance.variance", $0) }
        let plan = try Phase2QualificationMetricPlan(
            applicableTrialKeys: [.varianceBasisPoints: Set(keys)],
            varianceRequirementID: "live.performance.variance"
        )
        let samples = try keys.map { try sample($0, latency: Int64($0.trialIndex * 100)) }
        let observations = try keys.map { try observation($0, outcome: .failed) }

        let aggregate = try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: observations,
            plannedTrialKeys: keys,
            admittedAttemptKeys: keys,
            scope: scope(),
            metricPlan: plan
        )

        XCTAssertNil(aggregate.measurements.varianceBasisPoints)
    }

    func testAggregateRejectsDuplicateAndOutOfPlanAdmissions() throws {
        let planned = try [key("live.performance.standard", 1)]
        let plan = try Phase2QualificationMetricPlan(
            applicableTrialKeys: [.totalLatencyMilliseconds: Set(planned)]
        )
        let samples = try planned.map { try sample($0, latency: 100) }
        let observations = try planned.map { try observation($0, outcome: .passed) }

        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: observations,
            plannedTrialKeys: planned,
            admittedAttemptKeys: planned + planned,
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .duplicateAttemptID
            )
        }

        let unknown = try key("live.performance.unknown", 1)
        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: observations,
            plannedTrialKeys: planned,
            admittedAttemptKeys: [unknown],
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .outOfPlanAttemptID
            )
        }
    }

    func testAggregateRequiresSamplesToEqualAdmittedAttemptsExactly() throws {
        let planned = try [
            key("live.performance.standard", 1),
            key("live.performance.standard", 2),
        ]
        let plan = try Phase2QualificationMetricPlan(
            applicableTrialKeys: [.totalLatencyMilliseconds: Set(planned)]
        )
        let observations = try planned.map { try observation($0, outcome: .passed) }
        let first = try sample(planned[0], latency: 100)
        let second = try sample(planned[1], latency: 200)

        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: [first],
            observations: observations,
            plannedTrialKeys: planned,
            admittedAttemptKeys: planned,
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .admissionMismatch
            )
        }

        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: [first, first],
            observations: observations,
            plannedTrialKeys: planned,
            admittedAttemptKeys: [planned[0]],
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .duplicateAttemptID
            )
        }

        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: [first, second],
            observations: observations,
            plannedTrialKeys: planned,
            admittedAttemptKeys: [planned[0]],
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .admissionMismatch
            )
        }

        let unknown = try sample(
            key("live.performance.unknown", 1), latency: 300
        )
        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: [unknown],
            observations: observations,
            plannedTrialKeys: planned,
            admittedAttemptKeys: [planned[0]],
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .outOfPlanAttemptID
            )
        }
    }

    func testAggregateRejectsDuplicateUnknownAndNonAttemptOneObservations() throws {
        let planned = try [key("live.performance.standard", 1)]
        let plan = try Phase2QualificationMetricPlan(
            applicableTrialKeys: [.totalLatencyMilliseconds: Set(planned)]
        )
        let samples = try planned.map { try sample($0, latency: 100) }
        let valid = try observation(planned[0], outcome: .passed)

        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: [valid, valid],
            plannedTrialKeys: planned,
            admittedAttemptKeys: planned,
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .duplicateObservationID
            )
        }

        let unknown = try observation(
            key("live.performance.unknown", 1), outcome: .passed
        )
        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: [unknown],
            plannedTrialKeys: planned,
            admittedAttemptKeys: planned,
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .outOfPlanAttemptID
            )
        }

        let retry = try Phase2QualificationProbeObservation(
            probeID: planned[0].requirementID,
            trial: planned[0].trialIndex,
            attempt: 2,
            outcome: .passed,
            evidenceDigest: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector().aggregate(
            samples: samples,
            observations: [retry],
            plannedTrialKeys: planned,
            admittedAttemptKeys: planned,
            scope: scope(),
            metricPlan: plan
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .outOfPlanAttemptID
            )
        }
    }

    func testVarianceRoundingTiesAndExtremeCheckedInput() throws {
        XCTAssertEqual(
            try Phase2QualificationMeasurementCollector.roundedBasisPoints(2.5),
            3
        )
        XCTAssertEqual(
            try Phase2QualificationMeasurementCollector.varianceBasisPoints([1, 1, 1, 1, 2]),
            3_333
        )
        XCTAssertEqual(
            try Phase2QualificationMeasurementCollector.varianceBasisPoints([
                Int64.max, Int64.max, Int64.max, Int64.max, Int64.max,
            ]),
            0
        )
        XCTAssertEqual(
            try Phase2QualificationMeasurementCollector.varianceBasisPoints([
                100, 200, 300, 400, 500,
            ]),
            4_714
        )
    }

    func testCheckedPhaseSumAndThroughputOverflowFailClosed() throws {
        XCTAssertThrowsError(try sample(
            key("live.overflow", 1), latency: 100,
            phaseCompletions: [600_000, 600_000], phaseGeneration: [10, 10]
        ))
        XCTAssertThrowsError(try Phase2QualificationMeasurementCollector.throughput(
            completionTokens: Int64.max, generationMilliseconds: 1
        ))
    }

    func testMonotonicIntervalsRoundDownAtMillisecondBoundary() throws {
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 1_999_999]), residentSetSampler: TestRSSSampler([nil])
        )
        try accumulator.recordTerminalBoundary()
        XCTAssertEqual(try accumulator.finish(
            trialKey: key("live.rounding", 1), scope: scope()
        ).totalLatencyMilliseconds, 1)
    }

    func testFinishUsesCapturedValidationBoundaryNotLaterScoringTime() throws {
        let clock = TestClock([0, 50_000_000, 900_000_000])
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: clock,
            residentSetSampler: TestRSSSampler([nil])
        )
        try accumulator.recordTerminalBoundary()
        _ = try clock.nowNanoseconds() // Simulated semantic scoring after revalidation.

        XCTAssertEqual(
            try accumulator.finish(
                trialKey: key("live.boundary", 1),
                scope: scope()
            ).totalLatencyMilliseconds,
            50
        )
    }

    func testCancellationUsesDrainWhileTotalLatencyEndsAtFinalRevalidation() throws {
        XCTAssertThrowsError(try Phase2QualificationAttemptMeasurement(
            trialKey: key("live.cancel", 1),
            totalLatencyMilliseconds: 10,
            timeToFirstSemanticEventMilliseconds: nil,
            phaseUsages: [],
            peakResidentBytes: nil,
            cancellationLatencyMilliseconds: 11,
            measurementScopeIdentity: scope()
        ))
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 40_000_000, 70_000_000, 100_000_000]),
            residentSetSampler: TestRSSSampler([nil])
        )
        try accumulator.recordCancellation()
        try accumulator.recordCancellationDrain()
        try accumulator.recordTerminalBoundary()
        let sample = try accumulator.finish(trialKey: key("live.cancel", 1), scope: scope())
        XCTAssertEqual(sample.totalLatencyMilliseconds, 100)
        XCTAssertEqual(sample.cancellationLatencyMilliseconds, 30)
    }

    func testCancellationDrainIsRequiredExactlyOnceAndAfterCancellation() throws {
        let missing = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 40_000_000, 100_000_000]),
            residentSetSampler: TestRSSSampler([nil])
        )
        try missing.recordCancellation()
        XCTAssertThrowsError(try missing.finish(
            trialKey: key("live.cancel", 1), scope: scope()
        )) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .inconsistentSample
            )
        }

        let outOfOrder = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 40_000_000]),
            residentSetSampler: TestRSSSampler([nil])
        )
        XCTAssertThrowsError(try outOfOrder.recordCancellationDrain()) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .inconsistentSample
            )
        }

        let duplicate = try Phase2QualificationAttemptAccumulator(
            clock: TestClock([0, 40_000_000, 70_000_000, 80_000_000]),
            residentSetSampler: TestRSSSampler([nil])
        )
        try duplicate.recordCancellation()
        try duplicate.recordCancellationDrain()
        XCTAssertThrowsError(try duplicate.recordCancellationDrain()) { error in
            XCTAssertEqual(
                error as? Phase2QualificationMeasurementV2Error,
                .inconsistentSample
            )
        }
    }

    private func sample(
        _ key: Phase2QualificationTrialKey,
        latency: Int64,
        first: Int64? = nil,
        completion: Int64? = nil,
        generation: Int64? = nil,
        phaseCompletions: [Int64]? = nil,
        phaseGeneration: [Int64]? = nil,
        peak: Int64? = nil,
        cancellation: Int64? = nil
    ) throws -> Phase2QualificationAttemptMeasurement {
        let completions = phaseCompletions ?? completion.map { [$0] } ?? []
        let generations = phaseGeneration ?? generation.map { [$0] } ?? []
        XCTAssertEqual(completions.count, generations.count)
        var timeline: [UInt64] = [0]
        if let first { timeline.append(UInt64(first) * 1_000_000) }
        var cursor = max(first ?? 0, 0)
        for duration in generations {
            timeline.append(UInt64(cursor) * 1_000_000)
            cursor += duration
            timeline.append(UInt64(cursor) * 1_000_000)
        }
        if let cancellation {
            timeline.append(UInt64(latency - cancellation) * 1_000_000)
            timeline.append(UInt64(latency) * 1_000_000)
        }
        timeline.append(UInt64(latency) * 1_000_000)
        let accumulator = try Phase2QualificationAttemptAccumulator(
            clock: TestClock(timeline),
            residentSetSampler: TestRSSSampler([
                peak.map { try! .init(appBytes: $0, aiWorkerBytes: 0, providerBytes: 0) }
            ])
        )
        if first != nil { try accumulator.recordFirstSemanticEvent() }
        for (index, completion) in completions.enumerated() {
            let phase: Phase2QualificationMeasuredPhase = index == 0 && completions.count > 1
                ? .toolSelection : .finalization
            try accumulator.beginPhaseGeneration(phase)
            try accumulator.endPhaseGeneration(
                phase,
                usage: .init(promptTokens: 1, completionTokens: completion,
                             totalTokens: completion + 1)
            )
        }
        if cancellation != nil {
            try accumulator.recordCancellation()
            try accumulator.recordCancellationDrain()
        }
        try accumulator.recordTerminalBoundary()
        return try accumulator.finish(trialKey: key, scope: scope())
    }

    private func key(_ id: String, _ trial: Int) throws -> Phase2QualificationTrialKey {
        try .init(requirementID: id, trialIndex: trial, attempt: 1)
    }

    private func observation(
        _ key: Phase2QualificationTrialKey,
        outcome: Phase2QualificationProbeOutcome
    ) throws -> Phase2QualificationProbeObservation {
        try .init(
            probeID: key.requirementID,
            trial: key.trialIndex,
            attempt: key.attempt,
            outcome: outcome,
            reasonCode: outcome == .passed ? nil : "qualification-failed",
            evidenceDigest: String(repeating: outcome == .passed ? "a" : "b", count: 64)
        )
    }

    private func scope() throws -> Phase2ProtocolComponentIdentity {
        try .init(
            id: "phase2.r1.measurement-scope.app-worker-provider", version: 1,
            sha256: String(repeating: "d", count: 64)
        )
    }
}

private final class TestClock: Phase2QualificationMonotonicClock, @unchecked Sendable {
    private var values: [UInt64]
    private let lock = NSLock()
    init(_ values: [UInt64]) { self.values = values }
    func nowNanoseconds() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return values.removeFirst()
    }
}

private final class TestRSSSampler: Phase2QualificationResidentSetSampling, @unchecked Sendable {
    private var values: [Phase2QualificationResidentSetSnapshot?]
    private let lock = NSLock()
    let measurementSemantics = Phase2QualificationResidentSetMeasurementSemantics
        .contemporaneousSnapshot
    init(_ values: [Phase2QualificationResidentSetSnapshot?]) { self.values = values }
    func sample() throws -> Phase2QualificationResidentSetSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}

private final class ContemporaneousSnapshotRSSSampler:
    Phase2QualificationResidentSetSampling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [Phase2QualificationResidentSetSnapshot]
    private var count = 0

    init(_ values: [Phase2QualificationResidentSetSnapshot]) {
        self.values = values
    }

    var sampleCount: Int {
        lock.withLock { count }
    }

    func sample() throws -> Phase2QualificationResidentSetSnapshot? {
        lock.withLock {
            count += 1
            return values.isEmpty ? nil : values.removeFirst()
        }
    }
}

private final class NoncontemporaneousHighWaterRSSSampler:
    Phase2QualificationResidentSetSampling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let value: Phase2QualificationResidentSetSnapshot
    private var count = 0
    let measurementSemantics = Phase2QualificationResidentSetMeasurementSemantics
        .noncontemporaneousProcessHighWater

    init(_ value: Phase2QualificationResidentSetSnapshot) {
        self.value = value
    }

    var sampleCount: Int {
        lock.withLock { count }
    }

    func sample() throws -> Phase2QualificationResidentSetSnapshot? {
        lock.withLock {
            count += 1
            return value
        }
    }
}
