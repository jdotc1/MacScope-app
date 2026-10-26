import Foundation

struct Phase2LiveQualificationTrialKey: Hashable, Sendable {
    let probeID: String
    let trial: Int

    init(probeID: String, trial: Int) {
        self.probeID = probeID
        self.trial = trial
    }

    var trialID: String { "\(probeID)#\(trial)" }

    var isValid: Bool {
        phase2IsCategoricalToken(probeID, maximumBytes: 128)
            && (1...100).contains(trial)
    }
}

/// Project-authored, inert inputs for one live trial. Both contexts are fully prepared before
/// dispatch; model output can never cause the runner to construct or execute a project read.
struct Phase2LiveQualificationTrialFixture: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidTrialKey
        case invalidIdentity
        case invalidWorkspace
        case invalidLifecycleRevision
        case invalidGoal
        case invalidToolHandles
        case invalidLimits
    }

    let key: Phase2LiveQualificationTrialKey
    let sessionID: UUID
    let turnID: UUID
    let selectionRequestID: UUID
    let finalizationRequestID: UUID
    let document: Phase2ReadDocumentIdentity
    let workspace: Phase2ReadWorkspaceIdentity
    let lifecycleRevision: UInt64
    let userGoal: String
    let selectionContext: Phase2GroundedContext
    let finalizationContext: Phase2GroundedContext
    let toolHandles: [Phase2InferenceToolHandle]
    let limits: Phase2InferenceLimits

    init(
        key: Phase2LiveQualificationTrialKey,
        sessionID: UUID,
        turnID: UUID,
        selectionRequestID: UUID,
        finalizationRequestID: UUID,
        document: Phase2ReadDocumentIdentity,
        workspace: Phase2ReadWorkspaceIdentity,
        lifecycleRevision: UInt64,
        userGoal: String,
        selectionContext: Phase2GroundedContext,
        finalizationContext: Phase2GroundedContext,
        toolHandles: [Phase2InferenceToolHandle],
        limits: Phase2InferenceLimits
    ) throws {
        guard key.isValid else { throw ValidationError.invalidTrialKey }
        guard selectionRequestID != finalizationRequestID else {
            throw ValidationError.invalidIdentity
        }
        guard workspace.document == document,
              selectionContext.records.allSatisfy({ $0.precondition.workspace == workspace }),
              finalizationContext.records.allSatisfy({ $0.precondition.workspace == workspace })
        else { throw ValidationError.invalidWorkspace }
        guard lifecycleRevision > 0 else { throw ValidationError.invalidLifecycleRevision }
        guard !userGoal.isEmpty, userGoal.utf8.count <= limits.maximumGoalBytes else {
            throw ValidationError.invalidGoal
        }
        guard !toolHandles.isEmpty,
              toolHandles.count <= limits.maximumToolHandles,
              Set(toolHandles.map(\.handleID)).count == toolHandles.count,
              Set(toolHandles.map(\.operationID)).count == toolHandles.count,
              toolHandles.allSatisfy({ Phase2ReadOperationID.allKnown.contains($0.operationID) })
        else { throw ValidationError.invalidToolHandles }
        guard limits.isValid else { throw ValidationError.invalidLimits }

        self.key = key
        self.sessionID = sessionID
        self.turnID = turnID
        self.selectionRequestID = selectionRequestID
        self.finalizationRequestID = finalizationRequestID
        self.document = document
        self.workspace = workspace
        self.lifecycleRevision = lifecycleRevision
        self.userGoal = userGoal
        self.selectionContext = selectionContext
        self.finalizationContext = finalizationContext
        self.toolHandles = toolHandles
        self.limits = limits
    }
}

struct Phase2LiveQualificationScheduledTrial: Hashable, Sendable {
    let scenario: Phase2LiveQualificationScenario
    let fixture: Phase2LiveQualificationTrialFixture
}

/// Canonical policy order is semantic. The plan derives its complete live-provider denominator
/// from the exact v2 policy and frozen catalog; callers cannot supply an alternative schedule.
struct Phase2LiveQualificationPlan: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case policyPlanMismatch
        case duplicateCorrelationID
    }

    let scheduledTrials: [Phase2LiveQualificationScheduledTrial]

    var expectedTrialOrder: [Phase2LiveQualificationTrialKey] {
        scheduledTrials.map(\.fixture.key)
    }

    var fixtures: [Phase2LiveQualificationTrialFixture] {
        scheduledTrials.map(\.fixture)
    }

    init(
        policy: Phase2ModelQualificationPolicy,
        catalog: Phase2LiveQualificationScenarioCatalog,
        fixtures: [Phase2LiveQualificationTrialFixture]
    ) throws {
        let requirements = policy.requirements.filter { $0.executionKind == .liveProvider }
        guard policy.version == 2,
              policy.liveQualificationCorpus == catalog.identity,
              requirements.count == catalog.scenarios.count
        else { throw ValidationError.policyPlanMismatch }

        for (requirement, scenario) in zip(requirements, catalog.scenarios) {
            guard requirement.probeID == scenario.id,
                  requirement.category == scenario.category,
                  requirement.requiredTrialCount == scenario.trialCount,
                  requirement.acceptanceCriteria == scenario.acceptanceCriteriaIdentity,
                  requirement.evidenceRequirement == .requiredSHA256,
                  scenario.executionKind == .liveProvider,
                  scenario.maximumAttemptsPerTrial == 1
            else { throw ValidationError.policyPlanMismatch }
        }

        let expected = requirements.flatMap { requirement in
            (1...requirement.requiredTrialCount).map {
                Phase2LiveQualificationTrialKey(probeID: requirement.probeID, trial: $0)
            }
        }
        guard !expected.isEmpty, fixtures.map(\.key) == expected else {
            throw ValidationError.policyPlanMismatch
        }

        var correlationIDs: Set<UUID> = []
        for fixture in fixtures {
            for identifier in [
                fixture.sessionID, fixture.turnID,
                fixture.selectionRequestID, fixture.finalizationRequestID,
            ] where !correlationIDs.insert(identifier).inserted {
                throw ValidationError.duplicateCorrelationID
            }
        }

        let scenariosByID = Dictionary(uniqueKeysWithValues: catalog.scenarios.map {
            ($0.id, $0)
        })
        scheduledTrials = try fixtures.map { fixture in
            guard let scenario = scenariosByID[fixture.key.probeID] else {
                throw ValidationError.policyPlanMismatch
            }
            return .init(scenario: scenario, fixture: fixture)
        }
    }
}

enum Phase2LiveQualificationReasonCode: String, Hashable, Sendable {
    case selectionMismatch = "selection-mismatch"
    case finalizationMismatch = "finalization-mismatch"
    case protocolMismatch = "protocol-mismatch"
    case qualityMismatch = "quality-mismatch"
    case safetyMismatch = "safety-mismatch"
    case providerNotReady = "provider-not-ready"
    case coordinatorBusy = "coordinator-busy"
    case invalidFixture = "invalid-fixture"
    case authorityChanged = "authority-changed"
    case providerFailed = "provider-failed"
    case providerInterrupted = "provider-interrupted"
    case callerCancelled = "caller-cancelled"
    case runnerBusy = "runner-busy"
    case runAborted = "run-aborted"
}

/// The scorer may inspect a transient inference outcome, but only this payload-free categorical
/// value crosses from classification into retained qualification evidence.
struct Phase2LiveQualificationClassification: Hashable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidOutcome
        case invalidEvidenceDigest
    }

    let outcome: Phase2QualificationProbeOutcome
    let reason: Phase2LiveQualificationReasonCode?
    let evidenceDigest: String

    static func passed(evidenceDigest: String) throws -> Self {
        try .init(outcome: .passed, reason: nil, evidenceDigest: evidenceDigest)
    }

    static func failed(
        reason: Phase2LiveQualificationReasonCode,
        evidenceDigest: String
    ) throws -> Self {
        try .init(outcome: .failed, reason: reason, evidenceDigest: evidenceDigest)
    }

    private init(
        outcome: Phase2QualificationProbeOutcome,
        reason: Phase2LiveQualificationReasonCode?,
        evidenceDigest: String
    ) throws {
        guard outcome == .passed || outcome == .failed,
              (outcome == .passed) == (reason == nil)
        else { throw ValidationError.invalidOutcome }
        guard phase2IsSHA256Hex(evidenceDigest) else {
            throw ValidationError.invalidEvidenceDigest
        }
        self.outcome = outcome
        self.reason = reason
        self.evidenceDigest = evidenceDigest
    }
}

enum Phase2LiveQualificationSelectionClassification: Hashable, Sendable {
    case accepted(evidenceDigest: String)
    case failed(Phase2LiveQualificationClassification)
}

struct Phase2LiveQualificationExecution: Hashable, Sendable {
    let terminationStatus: Phase2QualificationRunTerminationStatus
    let observations: [Phase2QualificationProbeObservation]
    let admittedAttemptKeys: [Phase2QualificationTrialKey]
    let measurementSamples: [Phase2QualificationAttemptMeasurement]
    let firstAdmissionEpochMilliseconds: Int64?
    let terminalEpochMilliseconds: Int64?
    let dispatchEvidence: Phase2LiveQualificationDispatchEvidence?

    init(
        terminationStatus: Phase2QualificationRunTerminationStatus,
        observations: [Phase2QualificationProbeObservation],
        admittedAttemptKeys: [Phase2QualificationTrialKey] = [],
        measurementSamples: [Phase2QualificationAttemptMeasurement] = [],
        firstAdmissionEpochMilliseconds: Int64? = nil,
        terminalEpochMilliseconds: Int64? = nil,
        dispatchEvidence: Phase2LiveQualificationDispatchEvidence? = nil
    ) {
        self.terminationStatus = terminationStatus
        self.observations = observations
        self.admittedAttemptKeys = admittedAttemptKeys
        self.measurementSamples = measurementSamples
        self.firstAdmissionEpochMilliseconds = firstAdmissionEpochMilliseconds
        self.terminalEpochMilliseconds = terminalEpochMilliseconds
        self.dispatchEvidence = dispatchEvidence
    }
}

/// Bounded, payload-free evidence for one categorically finalized and fully measured live attempt.
/// Persistence remains owned by the CoreTests Gate through the runner's fail-closed callback.
struct Phase2LiveQualificationFinalizedTrialEvidence: Hashable, Sendable {
    let observation: Phase2QualificationProbeObservation
    let admittedAttemptKey: Phase2QualificationTrialKey
    let measurementSample: Phase2QualificationAttemptMeasurement
}

enum Phase2LiveQualificationRunnerState: Hashable, Sendable {
    case idle
    case preflighting
    case running(Phase2LiveQualificationTrialKey, Phase2InferencePhase)
    case classifying(Phase2LiveQualificationTrialKey, Phase2InferencePhase)
    case collectingMeasurements
    case assemblingRun
    case finished
}
