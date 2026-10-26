import Foundation

extension ReconstructionCommandKind {
    var pendingKind: ReconstructionPendingCommandKind {
        switch self {
        case .create: .create
        case .start: .start
        case .pause: .pause
        case .resume: .resume
        case .cancel: .cancel
        }
    }
}

enum ReconstructionPendingCommandKind: String, CaseIterable, Equatable, Sendable {
    case none, create, start, pause, resume, cancel
}

/// A transient request is deliberately not durable job state. Its fences let one window reject
/// a completion after selection, command generation, or the committed projection has changed.
struct ReconstructionPendingIntent: Equatable, Sendable {
    let kind: ReconstructionPendingCommandKind
    let commandScopeID: UUID?
    let generation: UInt64
    let baseProjectionRevision: UInt64?
    let jobID: UUID?
    /// The complete durable cut observed before dispatch. This is presentation-only fence data;
    /// it is never persisted and never substitutes for the Store/coordinator authority check.
    let baseProjectionIdentity: ReconstructionDurablePresentationIdentity?
    let expectedCommittedState: ReconstructionJobState?

    init(
        kind: ReconstructionPendingCommandKind,
        commandScopeID: UUID? = nil,
        generation: UInt64,
        baseProjectionRevision: UInt64?,
        jobID: UUID?,
        baseProjectionIdentity: ReconstructionDurablePresentationIdentity? = nil,
        expectedCommittedState: ReconstructionJobState? = nil
    ) {
        self.kind = kind
        self.commandScopeID = commandScopeID
        self.generation = generation
        self.baseProjectionRevision = baseProjectionRevision
        self.jobID = jobID
        self.baseProjectionIdentity = baseProjectionIdentity
        self.expectedCommittedState = expectedCommittedState
    }

    static let none = Self(
        kind: .none,
        commandScopeID: nil,
        generation: 0,
        baseProjectionRevision: nil,
        jobID: nil,
        baseProjectionIdentity: nil,
        expectedCommittedState: nil
    )

    var isPending: Bool { kind != .none }
}

/// The smallest immutable durable identity needed to detect a command publication or a stale
/// sibling advance. Aggregate task/evidence rows are deliberately excluded: a detail-only change
/// cannot complete a lifecycle command.
struct ReconstructionDurablePresentationIdentity: Equatable, Sendable {
    let jobID: UUID?
    let state: ReconstructionJobState?
    let projectionRevision: UInt64
    let checkpointRevision: UInt64?
}

enum ReconstructionPendingReconciliationFence: String, Equatable, Sendable {
    case commandScopeChanged
    case commandGenerationStale
    case selectedJobChanged
    case durableProjectionRegressed
    case unexpectedDurableProjectionChange
    case missingBaseProjectionIdentity
    case commandBoundaryUnavailable
}

enum ReconstructionPendingReconciliationDisposition: Equatable, Sendable {
    case unchanged
    case accepted
    case fenced(ReconstructionPendingReconciliationFence)
}

struct ReconstructionPendingReconciliationResult: Equatable, Sendable {
    let disposition: ReconstructionPendingReconciliationDisposition
    let window: ReconstructionWindowPresentationState
}

enum ReconstructionDetailSelectionFailure: String, Equatable, Sendable {
    case noSelectedJob
    case ambiguousSelection
    case selectedTaskMissing
    case selectedTaskBelongsToAnotherJob
    case selectedEvidenceMissing
    case selectedEvidenceBelongsToAnotherJob
}

enum ReconstructionCommandCompletionRejection: String, Equatable, Hashable, Sendable {
    case windowMismatch
    case commandScopeMismatch
    case commandGenerationStale
    case projectionRevisionStale
    case jobSelectionChanged
    case noMatchingPendingIntent
    case ambiguousSelection
}

struct ReconstructionCommandCompletion: Equatable, Sendable {
    let windowID: UUID
    let commandScopeID: UUID
    let commandGeneration: UInt64
    let baseProjectionRevision: UInt64
    let jobID: UUID?
    let selectedTaskID: UUID?
    let selectedEvidenceID: UUID?
}

struct ReconstructionCommandCompletionResult: Equatable, Sendable {
    let accepted: Bool
    let rejectionReasons: [ReconstructionCommandCompletionRejection]
    let window: ReconstructionWindowPresentationState
}

/// All state in this value belongs to one window and has value semantics. It carries no store,
/// database, XPC, provider, native-worker, file URL, or task reference.
struct ReconstructionWindowPresentationState: Equatable, Sendable {
    let windowID: UUID
    let selectedJobID: UUID?
    let selectedTaskID: UUID?
    let selectedEvidenceID: UUID?
    let inspectorVisible: Bool
    let scrollAnchor: String?
    let filterText: String
    let pendingIntent: ReconstructionPendingIntent
    let commandGeneration: UInt64

    init(
        windowID: UUID,
        selectedJobID: UUID? = nil,
        selectedTaskID: UUID? = nil,
        selectedEvidenceID: UUID? = nil,
        inspectorVisible: Bool = false,
        scrollAnchor: String? = nil,
        filterText: String = "",
        pendingIntent: ReconstructionPendingIntent = .none,
        commandGeneration: UInt64 = 0
    ) {
        self.windowID = windowID
        self.selectedJobID = selectedJobID
        self.selectedTaskID = selectedTaskID
        self.selectedEvidenceID = selectedEvidenceID
        self.inspectorVisible = inspectorVisible
        self.scrollAnchor = ReconstructionPresentationPrivacy.boundedSafeText(
            scrollAnchor,
            maximumUTF8Bytes: 96
        )
        self.filterText = ReconstructionPresentationPrivacy.boundedSafeText(
            filterText,
            maximumUTF8Bytes: 128
        ) ?? ""
        self.pendingIntent = pendingIntent
        self.commandGeneration = commandGeneration
    }

    func replacing(
        selectedJobID: UUID? = nil,
        selectedTaskID: UUID? = nil,
        selectedEvidenceID: UUID? = nil,
        inspectorVisible: Bool? = nil,
        scrollAnchor: String? = nil,
        filterText: String? = nil,
        pendingIntent: ReconstructionPendingIntent? = nil,
        commandGeneration: UInt64? = nil
    ) -> Self {
        Self(
            windowID: windowID,
            selectedJobID: selectedJobID ?? self.selectedJobID,
            selectedTaskID: selectedTaskID ?? self.selectedTaskID,
            selectedEvidenceID: selectedEvidenceID ?? self.selectedEvidenceID,
            inspectorVisible: inspectorVisible ?? self.inspectorVisible,
            scrollAnchor: scrollAnchor ?? self.scrollAnchor,
            filterText: filterText ?? self.filterText,
            pendingIntent: pendingIntent ?? self.pendingIntent,
            commandGeneration: commandGeneration ?? self.commandGeneration
        )
    }

    func selectingJob(_ jobID: UUID?) -> Self {
        Self(
            windowID: windowID,
            selectedJobID: jobID,
            selectedTaskID: nil,
            selectedEvidenceID: nil,
            inspectorVisible: inspectorVisible,
            scrollAnchor: scrollAnchor,
            filterText: filterText,
            pendingIntent: pendingIntent,
            commandGeneration: commandGeneration
        )
    }

    func selectingTask(_ taskID: UUID?) -> Self {
        Self(
            windowID: windowID,
            selectedJobID: selectedJobID,
            selectedTaskID: taskID,
            selectedEvidenceID: nil,
            inspectorVisible: inspectorVisible,
            scrollAnchor: scrollAnchor,
            filterText: filterText,
            pendingIntent: pendingIntent,
            commandGeneration: commandGeneration
        )
    }

    func selectingEvidence(_ evidenceID: UUID?) -> Self {
        Self(
            windowID: windowID,
            selectedJobID: selectedJobID,
            selectedTaskID: nil,
            selectedEvidenceID: evidenceID,
            inspectorVisible: inspectorVisible,
            scrollAnchor: scrollAnchor,
            filterText: filterText,
            pendingIntent: pendingIntent,
            commandGeneration: commandGeneration
        )
    }

    /// Begins one transient intent before its command closure is invoked. The caller supplies the
    /// exact committed cut and expected successor; no Store, task, database, or runtime reference
    /// enters this window-local value.
    func beginningCommand(
        _ kind: ReconstructionPendingCommandKind,
        commandScopeID: UUID,
        against base: ReconstructionDurablePresentationIdentity,
        expectedCommittedState: ReconstructionJobState?
    ) -> Self? {
        guard kind != .none, !pendingIntent.isPending else { return nil }
        let (nextGeneration, overflow) = commandGeneration.addingReportingOverflow(1)
        guard !overflow else { return nil }
        let targetJobID = kind == .create ? nil : base.jobID
        guard kind == .create || (targetJobID != nil && targetJobID == selectedJobID) else {
            return nil
        }
        return Self(
            windowID: windowID,
            selectedJobID: selectedJobID,
            selectedTaskID: selectedTaskID,
            selectedEvidenceID: selectedEvidenceID,
            inspectorVisible: inspectorVisible,
            scrollAnchor: scrollAnchor,
            filterText: filterText,
            pendingIntent: .init(
                kind: kind,
                commandScopeID: commandScopeID,
                generation: nextGeneration,
                baseProjectionRevision: base.projectionRevision,
                jobID: targetJobID,
                baseProjectionIdentity: base,
                expectedCommittedState: expectedCommittedState
            ),
            commandGeneration: nextGeneration
        )
    }

    /// Reconciles an in-flight intent only against a durable projection cut. A matching successor
    /// clears it as accepted; any incompatible durable advance clears it as fenced so a rejected
    /// or stale command cannot leave this window permanently disabled.
    func reconcilingPending(
        with current: ReconstructionDurablePresentationIdentity,
        activeCommandScopeID: UUID
    ) -> ReconstructionPendingReconciliationResult {
        guard pendingIntent.isPending else {
            return .init(disposition: .unchanged, window: self)
        }
        guard pendingIntent.commandScopeID == activeCommandScopeID else {
            return clearingPending(fencedBy: .commandScopeChanged)
        }
        guard pendingIntent.generation == commandGeneration else {
            return clearingPending(fencedBy: .commandGenerationStale)
        }
        guard let base = pendingIntent.baseProjectionIdentity else {
            return clearingPending(fencedBy: .missingBaseProjectionIdentity)
        }
        if pendingIntent.kind != .create, selectedJobID != pendingIntent.jobID {
            return clearingPending(fencedBy: .selectedJobChanged)
        }
        guard current != base else {
            return .init(disposition: .unchanged, window: self)
        }
        if current.jobID == base.jobID,
           current.projectionRevision < base.projectionRevision {
            return clearingPending(fencedBy: .durableProjectionRegressed)
        }

        let accepted: Bool
        switch pendingIntent.kind {
        case .none:
            accepted = false
        case .create:
            accepted = current.jobID != nil && current.jobID != base.jobID
        case .start, .pause, .resume, .cancel:
            accepted = current.jobID == pendingIntent.jobID
                && current.state == pendingIntent.expectedCommittedState
        }
        guard accepted else {
            return clearingPending(fencedBy: .unexpectedDurableProjectionChange)
        }
        return .init(disposition: .accepted, window: clearingPending())
    }

    func fencingPendingForUnavailableCommandBoundary()
        -> ReconstructionPendingReconciliationResult {
        guard pendingIntent.isPending else {
            return .init(disposition: .unchanged, window: self)
        }
        return clearingPending(fencedBy: .commandBoundaryUnavailable)
    }

    func accepting(
        _ completion: ReconstructionCommandCompletion,
        durableProjectionRevision: UInt64
    ) -> ReconstructionCommandCompletionResult {
        var reasons: [ReconstructionCommandCompletionRejection] = []
        if completion.windowID != windowID { reasons.append(.windowMismatch) }
        if completion.commandScopeID != pendingIntent.commandScopeID {
            reasons.append(.commandScopeMismatch)
        }
        if completion.commandGeneration != commandGeneration {
            reasons.append(.commandGenerationStale)
        }
        if completion.baseProjectionRevision != durableProjectionRevision {
            reasons.append(.projectionRevisionStale)
        }
        let selectedJobFence = pendingIntent.kind == .create
            ? pendingIntent.baseProjectionIdentity?.jobID
            : completion.jobID
        if selectedJobFence != selectedJobID {
            reasons.append(.jobSelectionChanged)
        }
        if completion.selectedTaskID != nil && completion.selectedEvidenceID != nil {
            reasons.append(.ambiguousSelection)
        }
        guard pendingIntent.isPending,
              pendingIntent.commandScopeID == completion.commandScopeID,
              pendingIntent.generation == completion.commandGeneration,
              pendingIntent.baseProjectionRevision == completion.baseProjectionRevision,
              pendingIntent.jobID == completion.jobID
        else {
            reasons.append(.noMatchingPendingIntent)
            return .init(
                accepted: false,
                rejectionReasons: Self.canonicalReasons(reasons),
                window: self
            )
        }
        guard reasons.isEmpty else {
            return .init(
                accepted: false,
                rejectionReasons: Self.canonicalReasons(reasons),
                window: self
            )
        }
        let nextTaskID: UUID?
        let nextEvidenceID: UUID?
        switch (completion.selectedTaskID, completion.selectedEvidenceID) {
        case let (taskID?, nil):
            nextTaskID = taskID
            nextEvidenceID = nil
        case let (nil, evidenceID?):
            nextTaskID = nil
            nextEvidenceID = evidenceID
        case (nil, nil):
            nextTaskID = selectedTaskID
            nextEvidenceID = selectedEvidenceID
        case (_?, _?):
            nextTaskID = selectedTaskID
            nextEvidenceID = selectedEvidenceID
        }
        return .init(
            accepted: true,
            rejectionReasons: [],
            window: Self(
                windowID: windowID,
                selectedJobID: selectedJobID,
                selectedTaskID: nextTaskID,
                selectedEvidenceID: nextEvidenceID,
                inspectorVisible: inspectorVisible,
                scrollAnchor: scrollAnchor,
                filterText: filterText,
                pendingIntent: .none,
                commandGeneration: commandGeneration
            )
        )
    }

    private static func canonicalReasons(
        _ reasons: [ReconstructionCommandCompletionRejection]
    ) -> [ReconstructionCommandCompletionRejection] {
        Array(Set(reasons)).sorted { $0.rawValue < $1.rawValue }
    }

    private func clearingPending() -> Self {
        Self(
            windowID: windowID,
            selectedJobID: selectedJobID,
            selectedTaskID: selectedTaskID,
            selectedEvidenceID: selectedEvidenceID,
            inspectorVisible: inspectorVisible,
            scrollAnchor: scrollAnchor,
            filterText: filterText,
            pendingIntent: .none,
            commandGeneration: commandGeneration
        )
    }

    private func clearingPending(
        fencedBy reason: ReconstructionPendingReconciliationFence
    ) -> ReconstructionPendingReconciliationResult {
        .init(disposition: .fenced(reason), window: clearingPending())
    }
}

struct ReconstructionAccessibilityCatalogEntry: Equatable, Sendable {
    let semanticName: String
    let identifier: String
    let focusOrder: Int
}

enum ReconstructionAccessibilityIdentifiers {
    static let destination = "reconstruction.destination"
    static let dashboard = "reconstruction.dashboard"
    static let jobIdentity = "reconstruction.job.identity"
    static let jobState = "reconstruction.job.state"
    static let progress = "reconstruction.progress"
    static let primaryAction = "reconstruction.primaryAction"
    static let pause = "reconstruction.pause"
    static let resume = "reconstruction.resume"
    static let cancel = "reconstruction.cancel"
    static let corpusSummary = "reconstruction.corpusSummary"
    static let taskSummary = "reconstruction.taskSummary"
    static let evidenceSummary = "reconstruction.evidenceSummary"
    static let currentGap = "reconstruction.currentGap"
    static let terminalNotice = "reconstruction.terminalNotice"
    static let details = "reconstruction.details"
    static let inspector = "reconstruction.inspector"
    /// Supplemental Task 10 result surface. The accepted 16-entry oracle remains unchanged;
    /// this identifier extends rather than renumbers that frozen catalog.
    static let result = "reconstruction.result"

    static let orderedCatalog: [ReconstructionAccessibilityCatalogEntry] = [
        .init(semanticName: "destination", identifier: destination, focusOrder: 0),
        .init(semanticName: "dashboard", identifier: dashboard, focusOrder: 1),
        .init(semanticName: "jobIdentity", identifier: jobIdentity, focusOrder: 2),
        .init(semanticName: "jobState", identifier: jobState, focusOrder: 3),
        .init(semanticName: "progress", identifier: progress, focusOrder: 4),
        .init(semanticName: "primaryAction", identifier: primaryAction, focusOrder: 5),
        .init(semanticName: "pause", identifier: pause, focusOrder: 6),
        .init(semanticName: "resume", identifier: resume, focusOrder: 7),
        .init(semanticName: "cancel", identifier: cancel, focusOrder: 8),
        .init(semanticName: "corpusSummary", identifier: corpusSummary, focusOrder: 9),
        .init(semanticName: "taskSummary", identifier: taskSummary, focusOrder: 10),
        .init(semanticName: "evidenceSummary", identifier: evidenceSummary, focusOrder: 11),
        .init(semanticName: "currentGap", identifier: currentGap, focusOrder: 12),
        .init(semanticName: "terminalNotice", identifier: terminalNotice, focusOrder: 13),
        .init(semanticName: "details", identifier: details, focusOrder: 14),
        .init(semanticName: "inspector", identifier: inspector, focusOrder: 15),
    ]

    static let supplementalCatalog: [ReconstructionAccessibilityCatalogEntry] = [
        .init(semanticName: "result", identifier: result, focusOrder: 16),
    ]

    static var completeCatalog: [ReconstructionAccessibilityCatalogEntry] {
        orderedCatalog + supplementalCatalog
    }
}

enum ReconstructionPresentationPrivacy {
    private static let forbiddenFragments = [
        "/users/", "/home/", "\\users\\", "file://", "/var/folders/", "bearer ",
        "api_key", "apikey", "token=", "password=", "secret=", "sk-", "select ",
        "insert ", "update ", "delete ", "sqlite", "prompt:", "pseudocode:",
    ]

    static func boundedSafeText(
        _ source: String?,
        maximumUTF8Bytes: Int
    ) -> String? {
        guard maximumUTF8Bytes > 0, let source else { return nil }
        let normalized = source.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let lowercased = normalized.lowercased()
        guard !forbiddenFragments.contains(where: lowercased.contains),
              !containsLargePointer(normalized)
        else { return nil }

        var result = ""
        var byteCount = 0
        for character in normalized {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumUTF8Bytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result.isEmpty ? nil : result
    }

    private static func containsLargePointer(_ source: String) -> Bool {
        let scalars = Array(source.lowercased().unicodeScalars)
        guard scalars.count >= 12 else { return false }
        for start in 0...(scalars.count - 12)
        where scalars[start].value == 48 && scalars[start + 1].value == 120 {
            var count = 0
            var index = start + 2
            while index < scalars.count,
                  (scalars[index].value >= 48 && scalars[index].value <= 57)
                    || (scalars[index].value >= 97 && scalars[index].value <= 102) {
                count += 1
                index += 1
            }
            if count >= 10 { return true }
        }
        return false
    }
}
