import CryptoKit
import Foundation

enum ReconstructionStatusTone: String, Equatable, Sendable {
    case neutral, active, ready, warning, failure
}

enum ReconstructionModelReadinessCase: String, CaseIterable, Equatable, Sendable {
    case endpointMissing, inventoryRequired, authenticationRequired, unavailable, incompatible
    case reconciliationRequired, selectionRequired, selectionIdentityMismatch
    case selectedModelMissing, selectedModelNotLanguage, loadRequired, ready
}

enum ReconstructionModelActivityProjection: String, CaseIterable, Equatable, Sendable {
    case idle, discovering, performingLifecycle

    init(_ activity: Phase2LocalAIProviderActivity) {
        switch activity {
        case .idle: self = .idle
        case .discovering: self = .discovering
        case .performingLifecycle: self = .performingLifecycle
        }
    }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .discovering: "Discovering models"
        case .performingLifecycle: "Changing model state"
        }
    }
}

/// Exact presentation of all twelve source readiness cases, separate activity, and launch-local
/// revision. Configuration readiness does not itself grant executable model authority.
struct ReconstructionModelReadinessProjection: Equatable, Sendable {
    let readinessCase: ReconstructionModelReadinessCase
    let activity: ReconstructionModelActivityProjection
    let providerRevision: UInt64
    let title: String
    let detail: String
    let endpoint: String?
    let model: String?
    let requiredModelKey: String?

    init(
        _ readiness: Phase2LocalAIProviderReadiness,
        activity: Phase2LocalAIProviderActivity = .idle,
        providerRevision: UInt64 = 1
    ) {
        self.activity = .init(activity)
        self.providerRevision = providerRevision
        switch readiness {
        case .endpointMissing:
            readinessCase = .endpointMissing
            title = "Model endpoint missing"
            detail = "Configure a local endpoint before starting or resuming reconstruction."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .inventoryRequired:
            readinessCase = .inventoryRequired
            title = "Model inventory required"
            detail = "Discover the current local model inventory before reconstruction continues."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .authenticationRequired:
            readinessCase = .authenticationRequired
            title = "Model authentication required"
            detail = "Complete local provider authentication before reconstruction continues."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .unavailable:
            readinessCase = .unavailable
            title = "Model provider unavailable"
            detail = "Restore the selected local provider before reconstruction continues."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .incompatible:
            readinessCase = .incompatible
            title = "Model provider incompatible"
            detail = "Use a local provider that supports MacScope's bounded inference protocol."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .reconciliationRequired:
            readinessCase = .reconciliationRequired
            title = "Model state requires reconciliation"
            detail = "Reconcile the current local provider state before reconstruction continues."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .selectionRequired:
            readinessCase = .selectionRequired
            title = "Language model selection required"
            detail = "Select a qualified local language model in Settings."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .selectionIdentityMismatch:
            readinessCase = .selectionIdentityMismatch
            title = "Model selection is stale"
            detail = "Reauthorize the selected model against the current inventory."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .selectedModelMissing:
            readinessCase = .selectedModelMissing
            title = "Selected model is missing"
            detail = "Select an available local language model."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .selectedModelNotLanguage:
            readinessCase = .selectedModelNotLanguage
            title = "Selected model is not a language model"
            detail = "Select a language model before reconstruction continues."
            endpoint = nil; model = nil; requiredModelKey = nil
        case .loadRequired(let modelKey):
            readinessCase = .loadRequired
            title = "Selected model must be loaded"
            detail = "Load the selected language model before reconstruction continues."
            endpoint = nil
            model = ReconstructionPresentationPrivacy.boundedSafeText(modelKey, maximumUTF8Bytes: 96)
            requiredModelKey = model
        case .ready(let configuration):
            readinessCase = .ready
            title = "Model ready"
            detail = "The selected local model is configured for bounded reconstruction rounds."
            endpoint = ReconstructionPresentationPrivacy.boundedSafeText(
                configuration.endpointOrigin,
                maximumUTF8Bytes: 128
            )
            model = ReconstructionPresentationPrivacy.boundedSafeText(
                configuration.model,
                maximumUTF8Bytes: 96
            )
            requiredModelKey = nil
        }
    }

    private init(
        readinessCase: ReconstructionModelReadinessCase,
        activity: ReconstructionModelActivityProjection,
        providerRevision: UInt64,
        title: String,
        detail: String,
        endpoint: String?,
        model: String?
    ) {
        self.readinessCase = readinessCase
        self.activity = activity
        self.providerRevision = providerRevision
        self.title = title
        self.detail = detail
        self.endpoint = endpoint
        self.model = model
        requiredModelKey = readinessCase == .loadRequired ? model : nil
    }

    static func ready(
        endpoint: String,
        model: String,
        activity: ReconstructionModelActivityProjection = .idle,
        providerRevision: UInt64 = 1
    ) -> Self {
        .init(
            readinessCase: .ready,
            activity: activity,
            providerRevision: providerRevision,
            title: "Model ready",
            detail: "The selected local model is configured for bounded reconstruction rounds.",
            endpoint: ReconstructionPresentationPrivacy.boundedSafeText(endpoint, maximumUTF8Bytes: 128),
            model: ReconstructionPresentationPrivacy.boundedSafeText(model, maximumUTF8Bytes: 96)
        )
    }

    static func unavailable(title: String, detail: String) -> Self {
        .init(
            readinessCase: .unavailable,
            activity: .idle,
            providerRevision: 1,
            title: ReconstructionPresentationPrivacy.boundedSafeText(title, maximumUTF8Bytes: 96)
                ?? "Model provider unavailable",
            detail: ReconstructionPresentationPrivacy.boundedSafeText(detail, maximumUTF8Bytes: 192)
                ?? "Restore the selected local provider before reconstruction continues.",
            endpoint: nil,
            model: nil
        )
    }

    var isReady: Bool { readinessCase == .ready }
    var isExecutable: Bool {
        isReady && activity == .idle && providerRevision > 0 && providerRevision < UInt64.max
    }
    var executionDisabledSummary: String? {
        guard !isExecutable else { return nil }
        if !isReady { return title }
        if activity != .idle { return "Model provider is busy" }
        return "Model authority revision is not executable"
    }
}

enum ReconstructionRestoreStatus: Equatable, Sendable {
    case restoring
    case complete
    case failed(ReconstructionWorkspaceActivationFailure)
}
enum ReconstructionCreationValidation: Equatable, Sendable {
    case valid
    case invalid
    case durableDocumentLocationMissing
}

enum ReconstructionCommandKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case create, start, pause, resume, cancel
    var label: String { rawValue.capitalized }
}

enum ReconstructionCommandDisabledReason: String, Equatable, Sendable {
    case pending, noJob, terminalState, notCreated, notActive, notPaused
    case resumeTargetMissing, resumeTargetInvalid, modelNotExecutable, staleProjection
    case creationInvalid, durableDocumentLocationRequired, restoreIncomplete
    case runtimeUnavailable, restoreFailed

    var message: String {
        switch self {
        case .pending: "Another Reconstruction command is awaiting a committed result."
        case .noJob: "No Reconstruction job is selected."
        case .terminalState: "The selected job is terminal."
        case .notCreated: "Start is available only for a committed created job."
        case .notActive: "Pause and Cancel require an active job state."
        case .notPaused: "Resume is available only for a paused job."
        case .resumeTargetMissing: "The paused job lacks a durable resume target."
        case .resumeTargetInvalid: "The paused job's resume target is not an active state."
        case .modelNotExecutable: "Current local-model authority is not executable."
        case .staleProjection: "The selected checkpoint or frontier is not current authority."
        case .creationInvalid: "The job-creation request is incomplete or invalid."
        case .durableDocumentLocationRequired:
            "Save this document to a durable location before creating a Reconstruction job."
        case .restoreIncomplete:
            "Durable reconstruction state must rehydrate before commands are enabled."
        case .runtimeUnavailable:
            String(localized: "A validated production runtime is required before Reconstruction commands can run.")
        case .restoreFailed:
            "The Reconstruction runtime is unavailable because durable restoration failed."
        }
    }
}

struct ReconstructionCommandAvailability: Equatable, Sendable {
    let command: ReconstructionCommandKind
    let enabled: Bool
    let disabledReason: ReconstructionCommandDisabledReason?
    let requiredTransition: String?
    let requiredResumeTarget: ReconstructionJobState?

    var help: String {
        disabledReason?.message
            ?? "Activates the \(command.label) command through the Reconstruction command boundary."
    }
}

struct ReconstructionControlProjection: Equatable, Sendable {
    let create: ReconstructionCommandAvailability
    let start: ReconstructionCommandAvailability
    let pause: ReconstructionCommandAvailability
    let resume: ReconstructionCommandAvailability
    let cancel: ReconstructionCommandAvailability
    let primaryAction: ReconstructionCommandKind
    let pauseCause: ReconstructionJobPauseCause?
    let resumeTarget: ReconstructionJobState?

    func availability(for command: ReconstructionCommandKind) -> ReconstructionCommandAvailability {
        switch command {
        case .create: create
        case .start: start
        case .pause: pause
        case .resume: resume
        case .cancel: cancel
        }
    }

    var canCreate: Bool { create.enabled }
    var canStart: Bool { start.enabled }
    var canPause: Bool { pause.enabled }
    var hasResumePath: Bool { resumeTarget != nil }
    var canResume: Bool { resume.enabled }
    var canCancel: Bool { cancel.enabled }
    var resumeBlockedReason: String? { resume.disabledReason?.message }
}

struct ReconstructionCorpusSummary: Equatable, Sendable {
    let occurrenceCount: Int
    let uniqueContentCount: Int
    let relationCount: Int
    let unresolvedRelationCount: Int

    static let empty = Self(
        occurrenceCount: 0,
        uniqueContentCount: 0,
        relationCount: 0,
        unresolvedRelationCount: 0
    )
}

enum ReconstructionProgressPhaseKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case ingestion, indexing, decompilation, retrieval, checkpoint
    case sourceExecution = "source execution"
}

enum ReconstructionProgressPhaseStatus: String, Equatable, Sendable {
    case notStarted, pending, running, completed, partiallyCompleted, blocked, failed
}

struct ReconstructionProgressPhase: Equatable, Sendable {
    let kind: ReconstructionProgressPhaseKind
    let status: ReconstructionProgressPhaseStatus
    let total: Int
    let completed: Int
    let failed: Int
    let blocked: Int
    let cancelled: Int
    let running: Int
    let pending: Int
}

struct ReconstructionProgressSummary: Equatable, Sendable {
    let pendingTaskCount: Int
    let runningTaskCount: Int
    let completedTaskCount: Int
    let failedTaskCount: Int
    let blockedTaskCount: Int
    let cancelledTaskCount: Int

    var totalTaskCount: Int {
        pendingTaskCount + runningTaskCount + completedTaskCount + failedTaskCount
            + blockedTaskCount + cancelledTaskCount
    }

    var completedFraction: Double {
        guard totalTaskCount > 0 else { return 0 }
        return Double(completedTaskCount) / Double(totalTaskCount)
    }

    static let empty = Self(
        pendingTaskCount: 0,
        runningTaskCount: 0,
        completedTaskCount: 0,
        failedTaskCount: 0,
        blockedTaskCount: 0,
        cancelledTaskCount: 0
    )
}

struct ReconstructionEvidenceSummary: Equatable, Sendable {
    let counts: [ReconstructionEvidenceClassification: Int]

    init(counts: [ReconstructionEvidenceClassification: Int]) {
        self.counts = Dictionary(
            uniqueKeysWithValues: ReconstructionEvidenceClassification.allCases.map {
                ($0, counts[$0, default: 0])
            }
        )
    }

    func count(_ classification: ReconstructionEvidenceClassification) -> Int {
        counts[classification, default: 0]
    }

    var currentCount: Int { count(.acceptedCurrent) }
    var historicalCount: Int { count(.acceptedHistorical) }
    var staleCount: Int { count(.staleArtifact) + count(.staleAnalysis) }
    var unavailableCount: Int {
        count(.superseded) + count(.unavailable) + count(.failed) + count(.cancelled)
            + count(.truncated)
    }
    var totalCount: Int { counts.values.reduce(0, +) }

    static let empty = Self(counts: [:])
}

enum ReconstructionCheckpointFreshnessStatus: String, Equatable, Sendable {
    case absent, current, stale
}

struct ReconstructionCheckpointFreshness: Equatable, Sendable {
    let status: ReconstructionCheckpointFreshnessStatus
    let issues: [String]
    var isCurrent: Bool { status == .current }
}

enum ReconstructionGapStatus: String, Equatable, Sendable { case none, current, stale }

struct ReconstructionStatusGapProjection: Equatable, Sendable {
    let status: ReconstructionGapStatus
    let operationID: String
    let reason: String
}

enum ReconstructionOutcomeProjection: String, Equatable, Sendable {
    case none, active, partialSuccess, completed, cancelled, failed
}

struct ReconstructionTerminalNoticeProjection: Equatable, Sendable {
    static let maximumUTF8Bytes = 192
    /// The durable terminal lifecycle state is cause authority. A diagnostic is optional detail;
    /// its digest identifies the exact durable detail without inventing another cause vocabulary.
    let cause: ReconstructionJobState
    let detailIdentity: String
    let detail: String?
    let detailSuppressed: Bool
}

enum ReconstructionFinalResultUnavailability: String, Equatable, Sendable {
    case notCommitted
    case ambiguous
    case authorityMismatch
    case unsafePayload
}

struct ReconstructionFinalResultSummary: Equatable, Sendable {
    static let maximumDisplayedUTF8Bytes = 4_096

    let text: String
    let checkpointRevision: UInt64
    let citedEvidenceCount: Int
    let sourcePayloadByteCount: UInt64
    let textWasTruncated: Bool
}

/// A final result is a durable semantic, not an evidence record or a raw payload inspector.
/// The closed cases preserve an explicit abstention and expose only bounded text plus aggregates.
enum ReconstructionFinalResultProjection: Equatable, Sendable {
    case unavailable(ReconstructionFinalResultUnavailability)
    case synthesis(ReconstructionFinalResultSummary)
    case insufficientEvidence(ReconstructionFinalResultSummary)

    var summary: ReconstructionFinalResultSummary? {
        switch self {
        case .unavailable: nil
        case .synthesis(let summary), .insufficientEvidence(let summary): summary
        }
    }
}

enum ReconstructionNoticeKind: Equatable, Sendable {
    case noJob, staleCheckpoint, partialFailure, currentGap, runtimeRestoring
    case runtimeFailed(ReconstructionWorkspaceActivationFailure)
    case pending(ReconstructionPendingCommandKind)
    case job(ReconstructionJobState)
    case model(ReconstructionModelReadinessCase)

    var stableName: String {
        switch self {
        case .noJob: "projection.noJob"
        case .staleCheckpoint: "projection.staleCheckpoint"
        case .partialFailure: "projection.partialFailure"
        case .currentGap: "projection.currentGap"
        case .runtimeRestoring: "runtime.restoring"
        case .runtimeFailed(let failure): "runtime.failed.\(failure.rawValue)"
        case .pending(let command): "intent.\(command.rawValue)"
        case .job(let state): "job.\(state.rawValue)"
        case .model(let readiness): "model.\(readiness.rawValue)"
        }
    }
}

struct ReconstructionNoticeProjection: Equatable, Sendable {
    let kind: ReconstructionNoticeKind
    let identity: String
    let title: String
    let detail: String?
    let tone: ReconstructionStatusTone
}

struct ReconstructionTaskSample: Equatable, Sendable, Identifiable {
    let taskID: UUID
    let kind: ReconstructionTaskKind
    let state: ReconstructionTaskState
    let operationContractIdentity: String?
    var id: UUID { taskID }
}

struct ReconstructionEvidenceSample: Equatable, Sendable, Identifiable {
    let evidenceID: UUID
    let classification: ReconstructionEvidenceClassification
    let payloadKind: ReconstructionEvidencePayloadKind
    let operationID: String?
    let sourceNavigationEligible: Bool
    var id: UUID { evidenceID }
}

struct ReconstructionJobDetailProjection: Equatable, Sendable {
    let creationOrdinal: UInt64?
    let state: ReconstructionJobState
    let checkpointRevision: UInt64?
    let finalResult: ReconstructionFinalResultProjection
    let taskSamples: [ReconstructionTaskSample]
    let evidenceSamples: [ReconstructionEvidenceSample]
}

enum ReconstructionSelectedDetailProjection: Equatable, Sendable {
    case unavailable(ReconstructionDetailSelectionFailure)
    case job(ReconstructionJobDetailProjection)
    case task(ReconstructionTaskSample)
    case evidence(ReconstructionEvidenceSample)
}

/// One immutable committed presentation cut plus a separately identified transient window intent.
/// The value contains no execution authority and never reads live store fields from SwiftUI.
struct ReconstructionStatusProjection: Equatable, Sendable {
    static let destinationTitle = "Reconstruction"
    static let destinationSymbol = "arrow.trianglehead.2.clockwise.rotate.90"
    static let sampleLimit = 8

    let projectID: UUID?
    let projectName: String?
    let jobID: UUID?
    let jobCreationOrdinal: UInt64?
    let objective: String?
    let state: ReconstructionJobState?
    let stateTitle: String
    let stateDetail: String
    let stateTone: ReconstructionStatusTone
    let projectionRevision: UInt64
    let checkpointRevision: UInt64?
    let checkpointFreshness: ReconstructionCheckpointFreshness
    let corpus: ReconstructionCorpusSummary
    let progress: ReconstructionProgressSummary
    let phases: [ReconstructionProgressPhase]
    let evidence: ReconstructionEvidenceSummary
    let readiness: ReconstructionModelReadinessProjection
    let restoreStatus: ReconstructionRestoreStatus
    let currentGap: ReconstructionStatusGapProjection
    let outcome: ReconstructionOutcomeProjection
    let partialFailure: Bool
    let terminalDetail: String?
    let terminalNotice: ReconstructionTerminalNoticeProjection?
    let finalResult: ReconstructionFinalResultProjection
    let controls: ReconstructionControlProjection
    let pendingIntent: ReconstructionPendingIntent
    let notice: ReconstructionNoticeProjection
    let taskSamples: [ReconstructionTaskSample]
    let evidenceSamples: [ReconstructionEvidenceSample]
    let selectedDetail: ReconstructionSelectedDetailProjection
    let windowState: ReconstructionWindowPresentationState

    var isEmpty: Bool { jobID == nil }
}

extension ReconstructionStatusProjection {
    static func project(
        workspace: ReconstructionWorkspaceState,
        selectedJobID: UUID?,
        readiness: Phase2LocalAIProviderReadiness,
        activity: Phase2LocalAIProviderActivity,
        providerRevision: UInt64,
        restoreStatus: ReconstructionRestoreStatus,
        windowState: ReconstructionWindowPresentationState? = nil,
        currentEvidenceFrontierSHA256: String? = nil,
        durableProjectionRevision: UInt64? = nil,
        creationValidation: ReconstructionCreationValidation = .valid
    ) -> Self {
        let effectiveWindow = windowState ?? ReconstructionWindowPresentationState(
            windowID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            selectedJobID: selectedJobID
        )
        let requestedJobID = effectiveWindow.selectedJobID ?? selectedJobID
        let readinessProjection = ReconstructionModelReadinessProjection(
            readiness,
            activity: activity,
            providerRevision: providerRevision
        )
        guard let job = selectedJob(in: workspace, selectedJobID: requestedJobID) else {
            return empty(
                readiness: readinessProjection,
                workspace: workspace,
                windowState: effectiveWindow,
                restoreStatus: restoreStatus,
                creationValidation: creationValidation
            )
        }

        let project = workspace.projects.first { $0.projectID == job.reconstructionProjectID }
        let manifestDigest = project?.currentCorpusManifestSHA256
            ?? job.creationCorpusManifestSHA256
        let manifest = workspace.corpusManifests.first { manifest in
            manifest.reconstructionProjectID == job.reconstructionProjectID
                && manifest.canonicalSHA256 == manifestDigest
        }
        let exactCheckpoint = job.currentCheckpointID.flatMap { checkpointID in
            workspace.checkpoints.first { $0.checkpointID == checkpointID }
        }
        let latestCheckpoint = workspace.checkpoints
            .filter { $0.jobID == job.jobID }
            .max { $0.revision < $1.revision }
        let checkpoint = exactCheckpoint ?? latestCheckpoint
        let freshness = checkpointFreshness(
            checkpoint: checkpoint,
            exactCheckpointID: job.currentCheckpointID,
            job: job,
            currentManifestSHA256: manifestDigest,
            currentEvidenceFrontierSHA256: currentEvidenceFrontierSHA256
        )
        let projectedState = freshness.isCurrent ? checkpoint?.coordinatorState ?? job.state : job.state
        let selectedTasks = workspace.tasks.filter { $0.identity.jobID == job.jobID }
        let selectedEvidence = workspace.evidence.filter { $0.creatingJobID == job.jobID }
        let progress = progressSummary(tasks: selectedTasks, checkpoint: checkpoint)
        let phases = progressPhases(tasks: selectedTasks)
        let evidence = evidenceSummary(classifications: selectedEvidence.map(\.classification))
        let partialFailure = hasPartialFailure(progress: progress, evidence: evidence)
        let outcome = outcome(state: projectedState, partialFailure: partialFailure)
        let terminalDiagnostic = freshness.isCurrent
            ? checkpoint?.terminalReason ?? job.terminalReason
            : job.terminalReason
        let terminalNotice = terminalProjection(
            state: projectedState,
            diagnostic: terminalDiagnostic
        )
        let finalResult = finalResultProjection(
            workspace: workspace,
            job: job,
            checkpoint: checkpoint
        )
        let taskSamples = taskSamples(selectedTasks)
        let evidenceSamples = evidenceSamples(selectedEvidence)
        let gap = gapProjection(
            workspace: workspace,
            manifest: manifest,
            checkpoint: checkpoint,
            checkpointIsCurrent: freshness.isCurrent
        )
        let presentation = statePresentation(projectedState, outcome: outcome)
        let controls = controls(
            state: projectedState,
            hasJob: true,
            readiness: readinessProjection,
            pauseContext: job.pauseContext,
            checkpointCurrent: freshness.isCurrent,
            restoreStatus: restoreStatus,
            creationValidation: creationValidation,
            pendingIntent: effectiveWindow.pendingIntent
        )
        let revision = durableProjectionRevision ?? checkpoint?.revision ?? 0
        let notice = notice(
            state: projectedState,
            jobID: job.jobID,
            projectionRevision: revision,
            freshness: freshness,
            partialFailure: partialFailure,
            gap: gap,
            readiness: readinessProjection,
            restoreStatus: restoreStatus,
            pendingIntent: effectiveWindow.pendingIntent,
            terminalNotice: terminalNotice
        )

        return .init(
            projectID: project?.projectID,
            projectName: ReconstructionPresentationPrivacy.boundedSafeText(
                project?.name,
                maximumUTF8Bytes: 128
            ),
            jobID: job.jobID,
            jobCreationOrdinal: job.creationOrdinal,
            objective: ReconstructionPresentationPrivacy.boundedSafeText(
                job.objective,
                maximumUTF8Bytes: 512
            ),
            state: projectedState,
            stateTitle: presentation.title,
            stateDetail: presentation.detail,
            stateTone: presentation.tone,
            projectionRevision: revision,
            checkpointRevision: checkpoint?.revision,
            checkpointFreshness: freshness,
            corpus: corpusSummary(manifest),
            progress: progress,
            phases: phases,
            evidence: evidence,
            readiness: readinessProjection,
            restoreStatus: restoreStatus,
            currentGap: gap,
            outcome: outcome,
            partialFailure: partialFailure,
            terminalDetail: terminalNotice?.detail,
            terminalNotice: terminalNotice,
            finalResult: finalResult,
            controls: controls,
            pendingIntent: effectiveWindow.pendingIntent,
            notice: notice,
            taskSamples: taskSamples,
            evidenceSamples: evidenceSamples,
            selectedDetail: selectedDetail(
                window: effectiveWindow,
                job: job,
                allTasks: workspace.tasks,
                allEvidence: workspace.evidence,
                taskSamples: taskSamples,
                evidenceSamples: evidenceSamples,
                checkpointRevision: checkpoint?.revision,
                finalResult: finalResult
            ),
            windowState: effectiveWindow
        )
    }

    /// Exact valid selection wins. A missing selection falls back only to the greatest durable
    /// creation ordinal; UUID lexical order never becomes presentation authority.
    static func selectedJob(
        in workspace: ReconstructionWorkspaceState,
        selectedJobID: UUID?
    ) -> ReconstructionJobRecord? {
        if let selectedJobID,
           let exact = workspace.jobs.first(where: { $0.jobID == selectedJobID }) {
            return exact
        }
        return workspace.jobs.compactMap { job in
            job.creationOrdinal.map { (ordinal: $0, job: job) }
        }.max { lhs, rhs in
            lhs.ordinal < rhs.ordinal
        }?.job
    }

    static func controlProjection(
        state: ReconstructionJobState,
        readiness: ReconstructionModelReadinessProjection,
        pauseContext: ReconstructionJobPauseContext? = nil,
        pendingIntent: ReconstructionPendingIntent = .none,
        checkpointCurrent: Bool = true,
        restoreStatus: ReconstructionRestoreStatus = .complete,
        creationValidation: ReconstructionCreationValidation = .valid
    ) -> Self {
        let projectedOutcome = outcome(state: state, partialFailure: false)
        let presentation = statePresentation(state, outcome: projectedOutcome)
        let window = ReconstructionWindowPresentationState(
            windowID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            pendingIntent: pendingIntent,
            commandGeneration: pendingIntent.generation
        )
        let freshness = ReconstructionCheckpointFreshness(
            status: checkpointCurrent ? .current : .stale,
            issues: checkpointCurrent ? [] : ["syntheticStaleProjection"]
        )
        let gap = ReconstructionStatusGapProjection(
            status: .none,
            operationID: "",
            reason: "No current unresolved gap."
        )
        let controls = controls(
            state: state,
            hasJob: true,
            readiness: readiness,
            pauseContext: pauseContext,
            checkpointCurrent: checkpointCurrent,
            restoreStatus: restoreStatus,
            creationValidation: creationValidation,
            pendingIntent: pendingIntent
        )
        return .init(
            projectID: nil, projectName: nil, jobID: nil, jobCreationOrdinal: nil,
            objective: nil, state: state,
            stateTitle: presentation.title,
            stateDetail: presentation.detail,
            stateTone: presentation.tone,
            projectionRevision: 0,
            checkpointRevision: nil,
            checkpointFreshness: freshness,
            corpus: .empty,
            progress: .empty,
            phases: emptyPhases,
            evidence: .empty,
            readiness: readiness,
            restoreStatus: restoreStatus,
            currentGap: gap,
            outcome: projectedOutcome,
            partialFailure: false,
            terminalDetail: nil,
            terminalNotice: nil,
            finalResult: .unavailable(.notCommitted),
            controls: controls,
            pendingIntent: pendingIntent,
            notice: notice(
                state: state,
                jobID: nil,
                projectionRevision: 0,
                freshness: freshness,
                partialFailure: false,
                gap: gap,
                readiness: readiness,
                restoreStatus: restoreStatus,
                pendingIntent: pendingIntent,
                terminalNotice: nil
            ),
            taskSamples: [],
            evidenceSamples: [],
            selectedDetail: .unavailable(.noSelectedJob),
            windowState: window
        )
    }

    static func evidenceSummary(
        classifications: [ReconstructionEvidenceClassification]
    ) -> ReconstructionEvidenceSummary {
        var counts: [ReconstructionEvidenceClassification: Int] = [:]
        for classification in classifications { counts[classification, default: 0] += 1 }
        return .init(counts: counts)
    }
}

private extension ReconstructionStatusProjection {
    static func empty(
        readiness: ReconstructionModelReadinessProjection,
        workspace: ReconstructionWorkspaceState,
        windowState: ReconstructionWindowPresentationState,
        restoreStatus: ReconstructionRestoreStatus,
        creationValidation: ReconstructionCreationValidation
    ) -> Self {
        let freshness = ReconstructionCheckpointFreshness(
            status: .absent,
            issues: ["noSelectedJob"]
        )
        let gap = ReconstructionStatusGapProjection(
            status: .none,
            operationID: "",
            reason: "No current unresolved gap."
        )
        let controls = controls(
            state: nil,
            hasJob: false,
            readiness: readiness,
            pauseContext: nil,
            checkpointCurrent: false,
            restoreStatus: restoreStatus,
            creationValidation: creationValidation,
            pendingIntent: windowState.pendingIntent
        )
        return .init(
            projectID: nil, projectName: nil, jobID: nil, jobCreationOrdinal: nil,
            objective: nil, state: nil,
            stateTitle: "No reconstruction job",
            stateDetail: "Create a bounded job from deliberately selected project items.",
            stateTone: .neutral,
            projectionRevision: 0,
            checkpointRevision: nil,
            checkpointFreshness: freshness,
            corpus: .empty,
            progress: .empty,
            phases: emptyPhases,
            evidence: .empty,
            readiness: readiness,
            restoreStatus: restoreStatus,
            currentGap: gap,
            outcome: .none,
            partialFailure: false,
            terminalDetail: nil,
            terminalNotice: nil,
            finalResult: .unavailable(.notCommitted),
            controls: controls,
            pendingIntent: windowState.pendingIntent,
            notice: notice(
                state: nil,
                jobID: nil,
                projectionRevision: 0,
                freshness: freshness,
                partialFailure: false,
                gap: gap,
                readiness: readiness,
                restoreStatus: restoreStatus,
                pendingIntent: windowState.pendingIntent,
                terminalNotice: nil
            ),
            taskSamples: [],
            evidenceSamples: [],
            selectedDetail: .unavailable(.noSelectedJob),
            windowState: windowState
        )
    }

    static func controls(
        state: ReconstructionJobState?,
        hasJob: Bool,
        readiness: ReconstructionModelReadinessProjection,
        pauseContext: ReconstructionJobPauseContext?,
        checkpointCurrent: Bool,
        restoreStatus: ReconstructionRestoreStatus,
        creationValidation: ReconstructionCreationValidation,
        pendingIntent: ReconstructionPendingIntent
    ) -> ReconstructionControlProjection {
        if pendingIntent.isPending {
            return disabledControls(reason: .pending, state: state, pauseContext: pauseContext)
        }
        switch restoreStatus {
        case .complete:
            break
        case .restoring:
            return disabledControls(
                reason: .restoreIncomplete,
                state: state,
                pauseContext: pauseContext
            )
        case .failed(let failure):
            return disabledControls(
                reason: failure == .runtimeUnavailable ? .runtimeUnavailable : .restoreFailed,
                state: state,
                pauseContext: pauseContext
            )
        }

        let createReason: ReconstructionCommandDisabledReason? = {
            switch creationValidation {
            case .valid: break
            case .invalid: return .creationInvalid
            case .durableDocumentLocationMissing: return .durableDocumentLocationRequired
            }
            return nil
        }()
        let create = availability(.create, reason: createReason)

        guard hasJob, let state else {
            let noJob = ReconstructionCommandDisabledReason.noJob
            return .init(
                create: create,
                start: availability(.start, reason: noJob),
                pause: availability(.pause, reason: noJob),
                resume: availability(.resume, reason: noJob),
                cancel: availability(.cancel, reason: noJob),
                primaryAction: create.enabled ? .create : .start,
                pauseCause: nil,
                resumeTarget: nil
            )
        }

        let durablePauseContext = state == .paused ? pauseContext : nil
        let startTransitionAllowed = commandTransitionIsAllowed(
            .start,
            from: state,
            pauseContext: durablePauseContext
        )
        let pauseTransitionAllowed = commandTransitionIsAllowed(
            .pause,
            from: state,
            pauseContext: durablePauseContext
        )
        let resumeTransitionAllowed = commandTransitionIsAllowed(
            .resume,
            from: state,
            pauseContext: durablePauseContext
        )
        let cancelTransitionAllowed = commandTransitionIsAllowed(
            .cancel,
            from: state,
            pauseContext: durablePauseContext
        )
        let startReason: ReconstructionCommandDisabledReason? = {
            guard startTransitionAllowed else {
                return state.isTerminal ? .terminalState : .notCreated
            }
            guard checkpointCurrent else { return .staleProjection }
            guard readiness.isExecutable else { return .modelNotExecutable }
            return nil
        }()
        let pauseReason: ReconstructionCommandDisabledReason? = {
            guard pauseTransitionAllowed else {
                return state.isTerminal ? .terminalState : .notActive
            }
            guard checkpointCurrent else { return .staleProjection }
            return nil
        }()
        let resumeReason: ReconstructionCommandDisabledReason? = {
            guard resumeTransitionAllowed else {
                if state.isTerminal { return .terminalState }
                guard state == .paused else { return .notPaused }
                guard durablePauseContext != nil else { return .resumeTargetMissing }
                return .resumeTargetInvalid
            }
            guard checkpointCurrent else { return .staleProjection }
            guard readiness.isExecutable else { return .modelNotExecutable }
            return nil
        }()
        let cancelReason: ReconstructionCommandDisabledReason? = {
            guard cancelTransitionAllowed else {
                return state.isTerminal ? .terminalState : .notActive
            }
            guard checkpointCurrent else { return .staleProjection }
            return nil
        }()

        let start = availability(
            .start,
            reason: startReason,
            transition: startReason == nil ? "created->ingesting" : nil
        )
        let pause = availability(
            .pause,
            reason: pauseReason,
            transition: pauseReason == nil ? "\(state.rawValue)->paused" : nil,
            resumeTarget: pauseReason == nil ? state : nil
        )
        let resume = availability(
            .resume,
            reason: resumeReason,
            transition: resumeReason == nil
                ? "paused->\(durablePauseContext!.resumeTarget.rawValue)"
                : nil,
            resumeTarget: resumeReason == nil ? durablePauseContext?.resumeTarget : nil
        )
        let cancel = availability(
            .cancel,
            reason: cancelReason,
            transition: cancelReason == nil ? "\(state.rawValue)->cancelled" : nil
        )
        let provisional = ReconstructionControlProjection(
            create: create,
            start: start,
            pause: pause,
            resume: resume,
            cancel: cancel,
            primaryAction: .start,
            pauseCause: durablePauseContext?.cause,
            resumeTarget: durablePauseContext?.resumeTarget
        )
        return .init(
            create: create,
            start: start,
            pause: pause,
            resume: resume,
            cancel: cancel,
            primaryAction: primaryAction(state: state, controls: provisional),
            pauseCause: durablePauseContext?.cause,
            resumeTarget: durablePauseContext?.resumeTarget
        )
    }

    /// The durable state machine remains the sole transition-legality authority. Presentation
    /// layers add readiness/freshness/restore policy only after this exact transition is proven.
    static func commandTransitionIsAllowed(
        _ command: ReconstructionCommandKind,
        from state: ReconstructionJobState,
        pauseContext: ReconstructionJobPauseContext?
    ) -> Bool {
        do {
            switch command {
            case .create:
                return false
            case .start:
                try ReconstructionJobStateMachine.transition(
                    from: state,
                    to: .ingesting,
                    resumeTarget: nil
                )
            case .pause:
                try ReconstructionJobStateMachine.transition(
                    from: state,
                    to: .paused,
                    resumeTarget: state
                )
            case .resume:
                guard let resumeTarget = pauseContext?.resumeTarget else { return false }
                try ReconstructionJobStateMachine.transition(
                    from: state,
                    to: resumeTarget,
                    resumeTarget: resumeTarget
                )
            case .cancel:
                guard ReconstructionJobState.activeStates.contains(state)
                        || state == .paused else { return false }
                try ReconstructionJobStateMachine.transition(
                    from: state,
                    to: .cancelled,
                    resumeTarget: nil
                )
            }
            return true
        } catch {
            return false
        }
    }

    static func disabledControls(
        reason: ReconstructionCommandDisabledReason,
        state: ReconstructionJobState?,
        pauseContext: ReconstructionJobPauseContext?
    ) -> ReconstructionControlProjection {
        let provisional = ReconstructionControlProjection(
            create: availability(.create, reason: reason),
            start: availability(.start, reason: reason),
            pause: availability(.pause, reason: reason),
            resume: availability(.resume, reason: reason),
            cancel: availability(.cancel, reason: reason),
            primaryAction: .start,
            pauseCause: state == .paused ? pauseContext?.cause : nil,
            resumeTarget: state == .paused ? pauseContext?.resumeTarget : nil
        )
        return .init(
            create: provisional.create,
            start: provisional.start,
            pause: provisional.pause,
            resume: provisional.resume,
            cancel: provisional.cancel,
            primaryAction: primaryAction(state: state, controls: provisional),
            pauseCause: provisional.pauseCause,
            resumeTarget: provisional.resumeTarget
        )
    }

    static func availability(
        _ command: ReconstructionCommandKind,
        reason: ReconstructionCommandDisabledReason?,
        transition: String? = nil,
        resumeTarget: ReconstructionJobState? = nil
    ) -> ReconstructionCommandAvailability {
        .init(
            command: command,
            enabled: reason == nil,
            disabledReason: reason,
            requiredTransition: transition,
            requiredResumeTarget: resumeTarget
        )
    }

    static func primaryAction(
        state: ReconstructionJobState?,
        controls: ReconstructionControlProjection
    ) -> ReconstructionCommandKind {
        let preference: [ReconstructionCommandKind]
        switch state {
        case nil, .completed, .cancelled, .failed:
            preference = [.create, .start, .resume, .pause, .cancel]
        case .created:
            preference = [.start, .pause, .cancel, .create, .resume]
        case .paused:
            preference = [.resume, .create, .cancel, .start, .pause]
        default:
            preference = [.pause, .cancel, .create, .start, .resume]
        }
        return preference.first { controls.availability(for: $0).enabled } ?? preference[0]
    }
}

extension ReconstructionStatusProjection {
    static func checkpointFreshness(
        checkpoint: ReconstructionCheckpoint?,
        exactCheckpointID: UUID?,
        job: ReconstructionJobRecord,
        currentManifestSHA256: String,
        currentEvidenceFrontierSHA256: String? = nil
    ) -> ReconstructionCheckpointFreshness {
        guard let checkpoint else {
            return .init(status: .absent, issues: ["checkpointMissing"])
        }
        var issues: [String] = []
        if checkpoint.jobID != job.jobID { issues.append("checkpointJobMismatch") }
        if checkpoint.checkpointID != exactCheckpointID {
            issues.append("checkpointIdentityStale")
        }
        if checkpoint.corpusManifestSHA256 != currentManifestSHA256 {
            issues.append("checkpointCorpusFrontierStale")
        }
        if let currentEvidenceFrontierSHA256,
           checkpoint.evidenceFrontierSHA256 != currentEvidenceFrontierSHA256 {
            issues.append("checkpointEvidenceFrontierStale")
        }
        if checkpoint.coordinatorState != job.state {
            issues.append("checkpointStateStale")
        }
        return .init(status: issues.isEmpty ? .current : .stale, issues: issues.sorted())
    }

    static func corpusSummary(
        _ manifest: ReconstructionCorpusManifest?
    ) -> ReconstructionCorpusSummary {
        guard let manifest else { return .empty }
        return .init(
            occurrenceCount: manifest.artifacts.count,
            uniqueContentCount: Set(manifest.artifacts.map(\.contentIdentity)).count,
            relationCount: manifest.relations.count,
            unresolvedRelationCount: manifest.relations.filter {
                $0.kind == .unresolvedDependency
            }.count
        )
    }

    static func progressSummary(
        tasks: [ReconstructionTaskRecord],
        checkpoint: ReconstructionCheckpoint?
    ) -> ReconstructionProgressSummary {
        guard !tasks.isEmpty else {
            guard let checkpoint else { return .empty }
            return .init(
                pendingTaskCount: checkpoint.pendingTaskIDs.count,
                runningTaskCount: checkpoint.runningTaskIDs.count,
                completedTaskCount: checkpoint.completedTaskIDs.count,
                failedTaskCount: checkpoint.failedTaskIDs.count,
                blockedTaskCount: checkpoint.blockedTaskIDs.count,
                cancelledTaskCount: 0
            )
        }
        return .init(
            pendingTaskCount: tasks.filter { $0.state == .pending }.count,
            runningTaskCount: tasks.filter { $0.state == .running }.count,
            completedTaskCount: tasks.filter { $0.state == .completed }.count,
            failedTaskCount: tasks.filter { $0.state == .failed }.count,
            blockedTaskCount: tasks.filter { $0.state == .blocked }.count,
            cancelledTaskCount: tasks.filter { $0.state == .cancelled }.count
        )
    }

    static var phaseKinds: [ReconstructionProgressPhaseKind: Set<ReconstructionTaskKind>] {
        [
            .ingestion: [.ingest, .classify, .discoverRelations],
            .indexing: [.loadBinary, .indexImage, .enumerateFunctions],
            .decompilation: [.decompileNative, .decompileMacScope, .compareDecompilers],
            .retrieval: [.retrieveEvidence, .modelRound],
            .checkpoint: [.checkpoint],
            .sourceExecution: [.executeSource],
        ]
    }

    static var emptyPhases: [ReconstructionProgressPhase] {
        ReconstructionProgressPhaseKind.allCases.filter { $0 != .sourceExecution }.map {
            .init(
                kind: $0,
                status: .notStarted,
                total: 0,
                completed: 0,
                failed: 0,
                blocked: 0,
                cancelled: 0,
                running: 0,
                pending: 0
            )
        }
    }

    static func progressPhases(
        tasks: [ReconstructionTaskRecord]
    ) -> [ReconstructionProgressPhase] {
        ReconstructionProgressPhaseKind.allCases.filter { phase in
            phase != .sourceExecution || tasks.contains { $0.identity.kind == .executeSource }
        }.map { phase in
            let kinds = phaseKinds[phase] ?? []
            let phaseTasks = tasks.filter { kinds.contains($0.identity.kind) }
            let total = phaseTasks.count
            let completed = phaseTasks.filter { $0.state == .completed }.count
            let failed = phaseTasks.filter { $0.state == .failed }.count
            let blocked = phaseTasks.filter { $0.state == .blocked }.count
            let cancelled = phaseTasks.filter { $0.state == .cancelled }.count
            let running = phaseTasks.filter { $0.state == .running }.count
            let pending = phaseTasks.filter { $0.state == .pending }.count
            let status: ReconstructionProgressPhaseStatus
            if total == 0 {
                status = .notStarted
            } else if running > 0 {
                status = .running
            } else if failed > 0 {
                status = .failed
            } else if blocked > 0 {
                status = .blocked
            } else if completed + failed + cancelled == total {
                status = completed == total ? .completed : .partiallyCompleted
            } else {
                status = .pending
            }
            return .init(
                kind: phase,
                status: status,
                total: total,
                completed: completed,
                failed: failed,
                blocked: blocked,
                cancelled: cancelled,
                running: running,
                pending: pending
            )
        }
    }

    static func hasPartialFailure(
        progress: ReconstructionProgressSummary,
        evidence: ReconstructionEvidenceSummary
    ) -> Bool {
        let taskFailure = progress.completedTaskCount > 0
            && progress.failedTaskCount + progress.blockedTaskCount + progress.cancelledTaskCount > 0
        let evidenceFailure = evidence.currentCount > 0
            && evidence.count(.failed) + evidence.count(.cancelled) + evidence.count(.truncated)
                + evidence.count(.unavailable) + evidence.count(.staleArtifact)
                + evidence.count(.staleAnalysis) > 0
        return taskFailure || evidenceFailure
    }

    static func outcome(
        state: ReconstructionJobState,
        partialFailure: Bool
    ) -> ReconstructionOutcomeProjection {
        switch state {
        case .completed: partialFailure ? .partialSuccess : .completed
        case .cancelled: .cancelled
        case .failed: .failed
        default: .active
        }
    }

    static func terminalProjection(
        state: ReconstructionJobState,
        diagnostic: ReconstructionDiagnostic?
    ) -> ReconstructionTerminalNoticeProjection? {
        guard state.isTerminal, let diagnostic else { return nil }
        let safe = ReconstructionPresentationPrivacy.boundedSafeText(
            diagnostic.text,
            maximumUTF8Bytes: ReconstructionTerminalNoticeProjection.maximumUTF8Bytes
        )
        // Hash the complete canonical durable diagnostic rather than the display excerpt. Two
        // details sharing the first 192 bytes stay distinct without widening the UI surface.
        let preimage = Data(
            "reconstructionDiagnostic\u{0}\(ReconstructionDiagnostic.schemaVersion)\u{0}"
                .appending(diagnostic.text)
                .utf8
        )
        let identity = SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
        return .init(
            cause: state,
            detailIdentity: identity,
            detail: safe,
            detailSuppressed: !diagnostic.text.isEmpty && safe == nil
        )
    }

    static func gapProjection(
        workspace: ReconstructionWorkspaceState,
        manifest: ReconstructionCorpusManifest?,
        checkpoint: ReconstructionCheckpoint?,
        checkpointIsCurrent: Bool
    ) -> ReconstructionStatusGapProjection {
        guard let checkpoint, let manifest else {
            return .init(status: .none, operationID: "", reason: "No current unresolved gap.")
        }
        let occurrenceIDs = Set(manifest.artifacts.map(\.occurrenceID))
        let gaps = workspace.evidenceGaps.filter {
            occurrenceIDs.contains(subjectOccurrenceID($0.subject))
        }
        guard !gaps.isEmpty,
              let frontierSHA256 = try? ReconstructionEvidenceGapFrontier.canonicalSHA256(
                  for: gaps
              ),
              frontierSHA256 == checkpoint.unresolvedEvidenceGapSHA256,
              let gap = gaps.sorted(by: { lhs, rhs in
                  if lhs.operationID != rhs.operationID {
                      return lhs.operationID < rhs.operationID
                  }
                  return lhs.gapID.uuidString < rhs.gapID.uuidString
              }).first else {
            return .init(status: .none, operationID: "", reason: "No current unresolved gap.")
        }
        return .init(
            status: checkpointIsCurrent ? .current : .stale,
            operationID: ReconstructionPresentationPrivacy.boundedSafeText(
                gap.operationID,
                maximumUTF8Bytes: 80
            ) ?? "",
            reason: checkpointIsCurrent
                ? "One current evidence gap remains unresolved."
                : "A retained evidence gap is not current authority."
        )
    }

    static func subjectOccurrenceID(
        _ subject: ReconstructionSubjectCoordinate
    ) -> ReconstructionArtifactOccurrenceID {
        switch subject {
        case .artifact(let artifact): artifact.occurrenceID
        case .image(let image): image.artifact.occurrenceID
        case .function(let function): function.artifact.occurrenceID
        }
    }
}

extension ReconstructionStatusProjection {
    static func taskSamples(
        _ tasks: [ReconstructionTaskRecord]
    ) -> [ReconstructionTaskSample] {
        tasks.sorted {
            if $0.identity.kind.rawValue != $1.identity.kind.rawValue {
                return $0.identity.kind.rawValue < $1.identity.kind.rawValue
            }
            return $0.identity.taskID.uuidString < $1.identity.taskID.uuidString
        }.prefix(sampleLimit).map {
            .init(
                taskID: $0.identity.taskID,
                kind: $0.identity.kind,
                state: $0.state,
                operationContractIdentity: ReconstructionPresentationPrivacy.boundedSafeText(
                    $0.identity.operationContractIdentity,
                    maximumUTF8Bytes: 96
                )
            )
        }
    }

    static func evidenceSamples(
        _ evidence: [ReconstructionEvidenceRecord]
    ) -> [ReconstructionEvidenceSample] {
        evidence.sorted {
            if $0.classification.rawValue != $1.classification.rawValue {
                return $0.classification.rawValue < $1.classification.rawValue
            }
            return $0.evidenceID.uuidString < $1.evidenceID.uuidString
        }.prefix(sampleLimit).map { record in
            let carriesCurrentFunction: Bool
            if case .function = record.subject {
                carriesCurrentFunction = record.classification == .acceptedCurrent
            } else {
                carriesCurrentFunction = false
            }
            return .init(
                evidenceID: record.evidenceID,
                classification: record.classification,
                payloadKind: record.payloadKind,
                operationID: ReconstructionPresentationPrivacy.boundedSafeText(
                    record.operationID,
                    maximumUTF8Bytes: 96
                ),
                sourceNavigationEligible: carriesCurrentFunction
            )
        }
    }

    static func finalResultProjection(
        workspace: ReconstructionWorkspaceState,
        job: ReconstructionJobRecord,
        checkpoint: ReconstructionCheckpoint?
    ) -> ReconstructionFinalResultProjection {
        let matching = workspace.finalResults.filter { $0.jobID == job.jobID }
        guard !matching.isEmpty else { return .unavailable(.notCommitted) }
        guard matching.count == 1, let result = matching.first else {
            return .unavailable(.ambiguous)
        }
        guard job.state == .completed,
              job.currentCheckpointID == result.checkpointID,
              let checkpoint,
              checkpoint.checkpointID == result.checkpointID,
              checkpoint.jobID == job.jobID,
              checkpoint.revision == result.checkpointRevision,
              checkpoint.coordinatorState == .completed,
              checkpoint.completedTaskIDs.contains(result.taskID),
              checkpoint.modelReceiptIDs.contains(result.modelReceiptID),
              let task = workspace.tasks.first(where: {
                  $0.identity.taskID == result.taskID
              }),
              task.identity.jobID == job.jobID,
              task.identity.kind == .modelRound,
              task.identity.operationContractIdentity == "reconstruction.finalSynthesis.v1",
              task.state == .completed,
              let receipt = workspace.modelReceipts.first(where: {
                  $0.receiptID == result.modelReceiptID
              }),
              receipt.receiptID == result.requestID,
              receipt.jobID == job.jobID,
              receipt.taskID == result.taskID,
              receipt.checkpointRevision == result.checkpointRevision,
              receipt.requestIdentitySHA256 == result.requestIdentitySHA256,
              receipt.producer == result.producer,
              receipt.terminalState == .completed,
              receipt.selectedHandleIDs.isEmpty,
              receipt.acceptedEvidenceIDs == result.citedEvidenceIDs,
              receipt.diagnostic == nil,
              receipt.finalResultCommitment?.resultID == result.resultID,
              receipt.finalResultCommitment?.canonicalSHA256 == result.canonicalSHA256,
              result.citedEvidenceIDs.allSatisfy({ evidenceID in
                  workspace.evidence.contains(where: {
                      $0.evidenceID == evidenceID
                          && $0.classification == .acceptedCurrent
                          && $0.supersededByEvidenceID == nil
                  })
              }),
              let rawText = String(data: result.payloadUTF8, encoding: .utf8)
        else { return .unavailable(.authorityMismatch) }

        let normalizedText = rawText
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard let safeText = ReconstructionPresentationPrivacy.boundedSafeText(
            rawText,
            maximumUTF8Bytes: ReconstructionFinalResultSummary.maximumDisplayedUTF8Bytes
        ) else { return .unavailable(.unsafePayload) }
        let summary = ReconstructionFinalResultSummary(
            text: safeText,
            checkpointRevision: result.checkpointRevision,
            citedEvidenceCount: result.citedEvidenceIDs.count,
            sourcePayloadByteCount: result.payloadByteCount,
            textWasTruncated: safeText.utf8.count < normalizedText.utf8.count
        )
        switch result.kind {
        case .synthesis: return .synthesis(summary)
        case .insufficientEvidence: return .insufficientEvidence(summary)
        }
    }

    static func selectedDetail(
        window: ReconstructionWindowPresentationState,
        job: ReconstructionJobRecord,
        allTasks: [ReconstructionTaskRecord],
        allEvidence: [ReconstructionEvidenceRecord],
        taskSamples: [ReconstructionTaskSample],
        evidenceSamples: [ReconstructionEvidenceSample],
        checkpointRevision: UInt64?,
        finalResult: ReconstructionFinalResultProjection = .unavailable(.notCommitted)
    ) -> ReconstructionSelectedDetailProjection {
        if window.selectedTaskID != nil && window.selectedEvidenceID != nil {
            return .unavailable(.ambiguousSelection)
        }
        if let selectedTaskID = window.selectedTaskID {
            guard let record = allTasks.first(where: { $0.identity.taskID == selectedTaskID }) else {
                return .unavailable(.selectedTaskMissing)
            }
            guard record.identity.jobID == job.jobID else {
                return .unavailable(.selectedTaskBelongsToAnotherJob)
            }
            return .task(.init(
                taskID: record.identity.taskID,
                kind: record.identity.kind,
                state: record.state,
                operationContractIdentity: ReconstructionPresentationPrivacy.boundedSafeText(
                    record.identity.operationContractIdentity,
                    maximumUTF8Bytes: 96
                )
            ))
        }
        if let selectedEvidenceID = window.selectedEvidenceID {
            guard let record = allEvidence.first(where: { $0.evidenceID == selectedEvidenceID }) else {
                return .unavailable(.selectedEvidenceMissing)
            }
            guard record.creatingJobID == job.jobID else {
                return .unavailable(.selectedEvidenceBelongsToAnotherJob)
            }
            let sourceNavigationEligible: Bool
            if case .function = record.subject {
                sourceNavigationEligible = record.classification == .acceptedCurrent
            } else {
                sourceNavigationEligible = false
            }
            return .evidence(.init(
                evidenceID: record.evidenceID,
                classification: record.classification,
                payloadKind: record.payloadKind,
                operationID: ReconstructionPresentationPrivacy.boundedSafeText(
                    record.operationID,
                    maximumUTF8Bytes: 96
                ),
                sourceNavigationEligible: sourceNavigationEligible
            ))
        }
        return .job(.init(
            creationOrdinal: job.creationOrdinal,
            state: job.state,
            checkpointRevision: checkpointRevision,
            finalResult: finalResult,
            taskSamples: taskSamples,
            evidenceSamples: evidenceSamples
        ))
    }

    static func notice(
        state: ReconstructionJobState?,
        jobID: UUID?,
        projectionRevision: UInt64,
        freshness: ReconstructionCheckpointFreshness,
        partialFailure: Bool,
        gap: ReconstructionStatusGapProjection,
        readiness: ReconstructionModelReadinessProjection,
        restoreStatus: ReconstructionRestoreStatus,
        pendingIntent: ReconstructionPendingIntent,
        terminalNotice: ReconstructionTerminalNoticeProjection?
    ) -> ReconstructionNoticeProjection {
        let kind: ReconstructionNoticeKind
        let title: String
        let detail: String?
        let tone: ReconstructionStatusTone
        if case .failed(let failure) = restoreStatus {
            kind = .runtimeFailed(failure)
            title = "Reconstruction runtime unavailable"
            detail = activationFailureDetail(failure)
            tone = failure == .runtimeUnavailable ? .warning : .failure
        } else if restoreStatus == .restoring {
            kind = .runtimeRestoring
            title = "Preparing Reconstruction runtime"
            detail = "Durable Reconstruction state is reconciling before commands are enabled."
            tone = .active
        } else if pendingIntent.isPending {
            kind = .pending(pendingIntent.kind)
            title = "Requesting \(pendingIntent.kind.rawValue)"
            detail = "The committed job state has not changed."
            tone = .active
        } else if state != nil && !freshness.isCurrent {
            kind = .staleCheckpoint
            title = "Checkpoint is not current"
            detail = "Current progress is withheld until checkpoint and frontier authority agree."
            tone = .warning
        } else if state == nil {
            kind = .noJob
            title = "No Reconstruction job"
            detail = "Create a durable job from deliberately selected corpus roots."
            tone = .neutral
        } else if partialFailure && state != .cancelled && state != .failed {
            kind = .partialFailure
            title = "Reconstruction is only partially successful"
            detail = "Completed records coexist with failed, blocked, cancelled, unavailable, "
                + "truncated, or stale records."
            tone = .warning
        } else if state == .paused && !readiness.isExecutable {
            kind = .model(readiness.readinessCase)
            title = readiness.title
            detail = "The durable job remains paused until current model authority is executable."
            tone = .warning
        } else if let state, state.isTerminal {
            kind = .job(state)
            let presentation = statePresentation(
                state,
                outcome: outcome(state: state, partialFailure: false)
            )
            title = presentation.title
            detail = terminalNotice?.detail
            tone = presentation.tone
        } else if gap.status == .current {
            kind = .currentGap
            title = "Evidence gap remains"
            detail = gap.reason
            tone = .warning
        } else if let state {
            kind = .job(state)
            let presentation = statePresentation(state, outcome: .active)
            title = presentation.title
            detail = nil
            tone = presentation.tone
        } else {
            kind = .noJob
            title = "No Reconstruction job"
            detail = nil
            tone = .neutral
        }
        let safeDetail = ReconstructionPresentationPrivacy.boundedSafeText(
            detail,
            maximumUTF8Bytes: ReconstructionTerminalNoticeProjection.maximumUTF8Bytes
        )
        let identityPreimage = [
            kind.stableName,
            jobID?.uuidString ?? "none",
            String(projectionRevision),
            safeDetail ?? "",
        ].joined(separator: "\u{0}")
        let identity = SHA256.hash(data: Data(identityPreimage.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return .init(kind: kind, identity: identity, title: title, detail: safeDetail, tone: tone)
    }

    static func activationFailureDetail(
        _ failure: ReconstructionWorkspaceActivationFailure
    ) -> String {
        switch failure {
        case .runtimeUnavailable:
            String(localized: "Reconstruction's production runtime is not available or has not completed validation.")
        case .documentLocationRequired:
            "Save this document to a durable location before starting Reconstruction."
        case .staleLifecycle:
            "The document lifecycle changed before Reconstruction restoration completed."
        case .sidecarUnavailable:
            "The durable Reconstruction sidecar could not be opened for this document."
        case .restorationUnavailable:
            "Durable Reconstruction state could not be reconciled and rehydrated."
        }
    }

    static func statePresentation(
        _ state: ReconstructionJobState,
        outcome: ReconstructionOutcomeProjection
    ) -> (title: String, detail: String, tone: ReconstructionStatusTone) {
        if outcome == .partialSuccess {
            return (
                "Completed with issues",
                "The terminal checkpoint includes useful results and explicit unsuccessful records.",
                .warning
            )
        }
        return switch state {
        case .created:
            ("Ready to start", "The job and revision-zero checkpoint are committed.", .neutral)
        case .ingesting:
            ("Ingesting corpus", "Capturing deliberately selected artifacts into the durable corpus.", .active)
        case .indexing:
            ("Indexing artifacts", "Building bounded indexes for admitted corpus content.", .active)
        case .retrieving:
            ("Retrieving evidence", "Projecting the next deterministic evidence packet.", .active)
        case .awaitingModel:
            ("Awaiting model", "The next bounded model round is waiting for fresh readiness.", .warning)
        case .executingReads:
            ("Executing approved reads", "Running app-owned, read-only tools within the authority cut.", .active)
        case .acceptingEvidence:
            ("Accepting evidence", "Validating structured results before durable acceptance.", .active)
        case .checkpointing:
            ("Committing checkpoint", "Publishing only after the database transaction succeeds.", .active)
        case .paused:
            ("Paused", "Durable progress is preserved at one exact active resume target.", .warning)
        case .completed:
            ("Completed", "The bounded reconstruction objective reached a clean terminal checkpoint.", .ready)
        case .cancelled:
            ("Cancelled", "The job stopped without discarding its last committed checkpoint.", .neutral)
        case .failed:
            (
                "Failed",
                "The durable failed state is authoritative; bounded diagnostic detail is optional.",
                .failure
            )
        }
    }
}
