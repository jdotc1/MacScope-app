import Foundation

struct Phase2LiveQualificationObservationCollector: Sendable {
    enum Error: Swift.Error, Equatable, Sendable {
        case emptyPlan
        case duplicateTrial(Phase2LiveQualificationTrialKey)
        case unexpectedTrial(
            expected: Phase2LiveQualificationTrialKey,
            actual: Phase2LiveQualificationTrialKey
        )
        case alreadyFinished
        case incomplete
        case invalidClassification
        case invalidMeasurement
        case finalizedEvidenceUnavailable
    }

    private let expectedTrialOrder: [Phase2LiveQualificationTrialKey]
    private var collected: [Phase2QualificationProbeObservation] = []
    private var admittedAttemptKeys: [Phase2QualificationTrialKey] = []
    private var measurementSamples: [Phase2QualificationAttemptMeasurement] = []
    private var finalizedEvidenceCount = 0
    private var finished = false

    var expectedOrderForFailure: [Phase2LiveQualificationTrialKey] {
        expectedTrialOrder
    }

    init(expectedTrialOrder: [Phase2LiveQualificationTrialKey]) throws {
        guard !expectedTrialOrder.isEmpty else { throw Error.emptyPlan }
        var seen: Set<Phase2LiveQualificationTrialKey> = []
        for key in expectedTrialOrder {
            guard seen.insert(key).inserted else { throw Error.duplicateTrial(key) }
        }
        self.expectedTrialOrder = expectedTrialOrder
    }

    mutating func record(
        _ classification: Phase2LiveQualificationClassification,
        for key: Phase2LiveQualificationTrialKey
    ) throws {
        guard !finished else { throw Error.alreadyFinished }
        try requireNext(key)
        guard classification.outcome == .passed || classification.reason != nil,
              phase2IsSHA256Hex(classification.evidenceDigest)
        else { throw Error.invalidClassification }
        collected.append(try .init(
            probeID: key.probeID,
            trial: key.trial,
            attempt: 1,
            outcome: classification.outcome,
            reasonCode: classification.reason?.rawValue,
            evidenceDigest: classification.evidenceDigest
        ))
    }

    mutating func terminate(
        status: Phase2QualificationRunTerminationStatus,
        current: Phase2QualificationProbeOutcome?,
        reason: Phase2LiveQualificationReasonCode
    ) throws -> Phase2LiveQualificationExecution {
        guard !finished else { throw Error.alreadyFinished }
        guard status != .completed else { throw Error.incomplete }

        if let current, collected.count < expectedTrialOrder.count {
            guard current == .unavailable || current == .cancelled || current == .notRun else {
                throw Error.invalidClassification
            }
            let key = expectedTrialOrder[collected.count]
            collected.append(try .init(
                probeID: key.probeID,
                trial: key.trial,
                attempt: 1,
                outcome: current,
                reasonCode: reason.rawValue,
                evidenceDigest: nil
            ))
        }

        while collected.count < expectedTrialOrder.count {
            let key = expectedTrialOrder[collected.count]
            collected.append(try .init(
                probeID: key.probeID,
                trial: key.trial,
                attempt: 1,
                outcome: .notRun,
                reasonCode: Phase2LiveQualificationReasonCode.runAborted.rawValue,
                evidenceDigest: nil
            ))
        }
        finished = true
        return execution(terminationStatus: status)
    }

    mutating func rejectWithoutStarting(
        reason: Phase2LiveQualificationReasonCode
    ) throws -> Phase2LiveQualificationExecution {
        guard !finished else { throw Error.alreadyFinished }
        guard collected.isEmpty else { throw Error.incomplete }
        collected = try expectedTrialOrder.map { key in
            try .init(
                probeID: key.probeID,
                trial: key.trial,
                attempt: 1,
                outcome: .notRun,
                reasonCode: reason.rawValue,
                evidenceDigest: nil
            )
        }
        finished = true
        return execution(terminationStatus: .failed)
    }

    mutating func complete() throws -> Phase2LiveQualificationExecution {
        guard !finished else { throw Error.alreadyFinished }
        guard collected.count == expectedTrialOrder.count else { throw Error.incomplete }
        finished = true
        return execution(terminationStatus: .completed)
    }

    mutating func recordAdmission(_ key: Phase2QualificationTrialKey) throws {
        guard !finished else { throw Error.alreadyFinished }
        guard admittedAttemptKeys.last != key,
              expectedTrialOrder.contains(where: {
                  $0.probeID == key.requirementID && $0.trial == key.trialIndex
              }),
              !admittedAttemptKeys.contains(key)
        else { throw Error.invalidMeasurement }
        admittedAttemptKeys.append(key)
    }

    mutating func recordMeasurement(_ sample: Phase2QualificationAttemptMeasurement) throws {
        guard !finished else { throw Error.alreadyFinished }
        guard admittedAttemptKeys.contains(sample.trialKey),
              !measurementSamples.contains(where: { $0.trialKey == sample.trialKey })
        else { throw Error.invalidMeasurement }
        measurementSamples.append(sample)
    }

    mutating func finalizedEvidence(
        for key: Phase2LiveQualificationTrialKey
    ) throws -> Phase2LiveQualificationFinalizedTrialEvidence {
        guard !finished,
              collected.count == finalizedEvidenceCount + 1,
              admittedAttemptKeys.count == collected.count,
              measurementSamples.count == collected.count,
              expectedTrialOrder[finalizedEvidenceCount] == key
        else { throw Error.finalizedEvidenceUnavailable }

        let observation = collected[finalizedEvidenceCount]
        let admittedAttemptKey = admittedAttemptKeys[finalizedEvidenceCount]
        let measurementSample = measurementSamples[finalizedEvidenceCount]
        guard observation.probeID == key.probeID,
              observation.trial == key.trial,
              observation.attempt == 1,
              admittedAttemptKey.requirementID == key.probeID,
              admittedAttemptKey.trialIndex == key.trial,
              admittedAttemptKey.attempt == 1,
              measurementSample.trialKey == admittedAttemptKey
        else { throw Error.finalizedEvidenceUnavailable }

        finalizedEvidenceCount += 1
        return .init(
            observation: observation,
            admittedAttemptKey: admittedAttemptKey,
            measurementSample: measurementSample
        )
    }

    private func requireNext(_ key: Phase2LiveQualificationTrialKey) throws {
        guard collected.count < expectedTrialOrder.count else { throw Error.alreadyFinished }
        let expected = expectedTrialOrder[collected.count]
        guard expected == key else { throw Error.unexpectedTrial(expected: expected, actual: key) }
    }

    private func execution(
        terminationStatus: Phase2QualificationRunTerminationStatus
    ) -> Phase2LiveQualificationExecution {
        .init(
            terminationStatus: terminationStatus,
            observations: collected,
            admittedAttemptKeys: admittedAttemptKeys,
            measurementSamples: measurementSamples
        )
    }
}
