import Foundation

enum NativeDecompilerRecoveryDisposition: String, Sendable, Codable {
    case requestAgain, retrySameAuthority, retryAfterReadiness
    case unsupportedForCurrentTarget, repairRuntimeAuthority, repairAuthoredInput
    case changeSemanticInput, refreshCurrentAuthority, terminalOwner
}

enum NativeDecompilerFailureAction: String, Sendable, Codable {
    case retry, refresh, reviewTypes, useMacScopeAnalysis
}

enum NativeDecompilerFallbackDisposition: String, Sendable, Codable {
    case none, disclosedMacScope, exactPriorRefreshContentOrMacScope
    case disclosedMacScopeNeverRetainRejectedResult
}

struct NativeDecompilerFailurePresentation: Equatable, Sendable, Codable {
    let rowID: Int
    let title: String
    let explanation: String
    let recovery: NativeDecompilerRecoveryDisposition
    let retryable: Bool
    let primaryAction: NativeDecompilerFailureAction?
    let secondaryAction: NativeDecompilerFailureAction?
    let fallback: NativeDecompilerFallbackDisposition
    let accessibilityLabel: String
    let accessibilityHint: String

    var permitsRefreshRetention: Bool {
        fallback == .exactPriorRefreshContentOrMacScope
    }
}

enum NativeDecompilerContentOrigin: String, CaseIterable, Sendable, Codable {
    case live, cache
}

enum NativeDecompilerContentCompleteness: String, CaseIterable, Sendable, Codable {
    case complete, truncated
}

enum NativeDecompilerContentMappingState: String, CaseIterable, Sendable, Codable {
    case verified, degraded
}

struct NativeDecompilerPresentationContentIdentity: Equatable, Sendable {
    let requestSHA256: String
    let analysisFingerprintSHA256: String
    let runtimeIdentitySHA256: String
    let semanticIdentitySHA256: String
}

struct NativeDecompilerPresentedContent: Equatable, Sendable {
    let identity: NativeDecompilerPresentationContentIdentity
    let origin: NativeDecompilerContentOrigin
    let completeness: NativeDecompilerContentCompleteness
    let mappingState: NativeDecompilerContentMappingState
}

enum NativeDecompilerPresentationIntent: String, CaseIterable, Sendable, Codable {
    case none, request, retry, refresh
}

enum NativeDecompilerPresentationAttempt: String, CaseIterable, Sendable, Codable {
    case none, preparing, queued, running, cancelling
}

enum NativeDecompilerPresentationNoticeLayer: Equatable, Sendable {
    case none
    case cancelled
    case failure(NativeDecompilerFailurePresentation)
    case unavailable(NativeDecompilerFailurePresentation)

    var isCancelled: Bool {
        if case .cancelled = self { true } else { false }
    }

    var failure: NativeDecompilerFailurePresentation? {
        if case let .failure(value) = self { value } else { nil }
    }

    var isFailure: Bool { failure != nil }
}

struct NativeDecompilerRefreshRetentionWitness: Equatable, Sendable {
    let identity: NativeDecompilerPresentationContentIdentity
}

enum NativeDecompilerPresentationStateValidationError: Error, Equatable, Sendable {
    case intentAttemptMismatch
    case activeNotice
    case activeContentWithoutRefresh
    case refreshWithoutContent
    case unavailableRetainedContent
    case terminalContentNotRetainable
    case missingOrMismatchedRetentionWitness
    case orphanedRetentionWitness
}

struct NativeDecompilerLayeredPresentationState: Equatable, Sendable {
    let content: NativeDecompilerPresentedContent?
    let intent: NativeDecompilerPresentationIntent
    let attempt: NativeDecompilerPresentationAttempt
    let notice: NativeDecompilerPresentationNoticeLayer
    let refreshRetentionWitness: NativeDecompilerRefreshRetentionWitness?

    init(
        content: NativeDecompilerPresentedContent?,
        intent: NativeDecompilerPresentationIntent,
        attempt: NativeDecompilerPresentationAttempt,
        notice: NativeDecompilerPresentationNoticeLayer,
        refreshRetentionWitness: NativeDecompilerRefreshRetentionWitness?
    ) throws {
        let isActive = attempt != .none
        guard (intent != .none) == isActive else {
            throw NativeDecompilerPresentationStateValidationError.intentAttemptMismatch
        }
        if isActive {
            guard notice == .none else {
                throw NativeDecompilerPresentationStateValidationError.activeNotice
            }
            if content != nil, intent != .refresh {
                throw NativeDecompilerPresentationStateValidationError.activeContentWithoutRefresh
            }
            if intent == .refresh, content == nil {
                throw NativeDecompilerPresentationStateValidationError.refreshWithoutContent
            }
        }
        if case .unavailable = notice, content != nil {
            throw NativeDecompilerPresentationStateValidationError.unavailableRetainedContent
        }

        let retainedTerminal = content != nil && (notice.isCancelled || notice.isFailure)
        if retainedTerminal {
            if let failure = notice.failure, !failure.permitsRefreshRetention {
                throw NativeDecompilerPresentationStateValidationError.terminalContentNotRetainable
            }
            guard let content, refreshRetentionWitness?.identity == content.identity else {
                throw NativeDecompilerPresentationStateValidationError.missingOrMismatchedRetentionWitness
            }
        } else if refreshRetentionWitness != nil {
            throw NativeDecompilerPresentationStateValidationError.orphanedRetentionWitness
        }

        self.content = content
        self.intent = intent
        self.attempt = attempt
        self.notice = notice
        self.refreshRetentionWitness = refreshRetentionWitness
    }

    static func idle() throws -> Self {
        try Self(
            content: nil,
            intent: .none,
            attempt: .none,
            notice: .none,
            refreshRetentionWitness: nil
        )
    }
}

enum NativeDecompilerPresentationAdmissionPhase: Equatable, Sendable {
    case preparing, queued, running, cacheHit
}

enum NativeDecompilerPresentationReducerEvent: Equatable, Sendable {
    case begin(intent: NativeDecompilerPresentationIntent, generation: UInt64)
    case admission(NativeDecompilerPresentationAdmissionPhase, generation: UInt64)
    case cancelRequested(generation: UInt64)
    case ready(NativeDecompilerPresentedContent, generation: UInt64)
    case failure(
        NativeDecompilerFailurePresentation,
        retainedRefreshContent: NativeDecompilerPresentedContent?,
        generation: UInt64
    )
    case cancelled(retainedRefreshContent: NativeDecompilerPresentedContent?, generation: UInt64)
    case runtimeTransitioned(generation: UInt64)
    case clear(generation: UInt64)
}

struct NativeDecompilerPresentationReducer: Sendable {
    private(set) var state: NativeDecompilerLayeredPresentationState
    private(set) var publicationCount = 0
    private var generation: UInt64 = 0
    private var settledGeneration: UInt64?
    private var refreshOrigin: NativeDecompilerPresentedContent?

    init(content: NativeDecompilerPresentedContent? = nil) {
        state = try! NativeDecompilerLayeredPresentationState(
            content: content,
            intent: .none,
            attempt: .none,
            notice: .none,
            refreshRetentionWitness: nil
        )
    }

    @discardableResult
    mutating func apply(_ event: NativeDecompilerPresentationReducerEvent) -> Bool {
        switch event {
        case let .begin(intent, nextGeneration):
            guard intent != .none, nextGeneration > generation else { return false }
            let content = intent == .refresh ? state.content : nil
            guard intent != .refresh || content != nil else { return false }
            guard let next = try? NativeDecompilerLayeredPresentationState(
                content: content,
                intent: intent,
                attempt: .preparing,
                notice: .none,
                refreshRetentionWitness: nil
            ) else { return false }
            generation = nextGeneration
            settledGeneration = nil
            refreshOrigin = content
            state = next
            return true

        case let .admission(phase, eventGeneration):
            guard admitsActive(eventGeneration) else { return false }
            let attempt: NativeDecompilerPresentationAttempt
            switch phase {
            case .preparing, .cacheHit: attempt = .preparing
            case .queued: attempt = .queued
            case .running: attempt = .running
            }
            return replaceActiveAttempt(attempt)

        case let .cancelRequested(eventGeneration):
            guard admitsActive(eventGeneration), state.attempt != .cancelling else { return false }
            return replaceActiveAttempt(.cancelling)

        case let .ready(content, eventGeneration):
            guard admitsActive(eventGeneration) else { return false }
            guard let next = try? NativeDecompilerLayeredPresentationState(
                content: content,
                intent: .none,
                attempt: .none,
                notice: .none,
                refreshRetentionWitness: nil
            ) else { return false }
            state = next
            settledGeneration = eventGeneration
            refreshOrigin = nil
            publicationCount += 1
            return true

        case let .failure(presentation, retained, eventGeneration):
            guard admitsActive(eventGeneration) else { return false }
            return settleFailure(presentation, retained: retained, generation: eventGeneration)

        case let .cancelled(retained, eventGeneration):
            guard admitsActive(eventGeneration), state.attempt == .cancelling else { return false }
            return settleCancelled(retained: retained, generation: eventGeneration)

        case let .runtimeTransitioned(eventGeneration):
            guard admitsActive(eventGeneration),
                  let presentation = NativeDecompilerFailureCatalog.row(5)
            else { return false }
            return settleFailure(presentation, retained: nil, generation: eventGeneration)

        case let .clear(eventGeneration):
            guard eventGeneration > generation else { return false }
            state = try! .idle()
            generation = eventGeneration
            settledGeneration = eventGeneration
            refreshOrigin = nil
            return true
        }
    }

    private func admitsActive(_ candidate: UInt64) -> Bool {
        candidate == generation && settledGeneration != candidate && state.attempt != .none
    }

    private mutating func replaceActiveAttempt(_ attempt: NativeDecompilerPresentationAttempt) -> Bool {
        guard let next = try? NativeDecompilerLayeredPresentationState(
            content: state.content,
            intent: state.intent,
            attempt: attempt,
            notice: .none,
            refreshRetentionWitness: nil
        ) else { return false }
        state = next
        return true
    }

    private mutating func settleFailure(
        _ presentation: NativeDecompilerFailurePresentation,
        retained: NativeDecompilerPresentedContent?,
        generation: UInt64
    ) -> Bool {
        let exact = retained != nil && retained == refreshOrigin && presentation.permitsRefreshRetention
        let content = exact ? retained : nil
        let witness = content.map { NativeDecompilerRefreshRetentionWitness(identity: $0.identity) }
        guard let next = try? NativeDecompilerLayeredPresentationState(
            content: content,
            intent: .none,
            attempt: .none,
            notice: .failure(presentation),
            refreshRetentionWitness: witness
        ) else { return false }
        state = next
        settledGeneration = generation
        refreshOrigin = nil
        publicationCount += 1
        return true
    }

    private mutating func settleCancelled(
        retained: NativeDecompilerPresentedContent?,
        generation: UInt64
    ) -> Bool {
        let exact = retained != nil && retained == refreshOrigin
        let content = exact ? retained : nil
        let witness = content.map { NativeDecompilerRefreshRetentionWitness(identity: $0.identity) }
        guard let next = try? NativeDecompilerLayeredPresentationState(
            content: content,
            intent: .none,
            attempt: .none,
            notice: .cancelled,
            refreshRetentionWitness: witness
        ) else { return false }
        state = next
        settledGeneration = generation
        refreshOrigin = nil
        publicationCount += 1
        return true
    }
}

enum NativeDecompilerControlCommand: String, CaseIterable, Hashable, Sendable, Codable {
    case request, retry, refresh, cancel

    var title: String {
        switch self {
        case .request: "Request"
        case .retry: "Retry"
        case .refresh: "Refresh"
        case .cancel: "Cancel"
        }
    }

    var systemImage: String {
        switch self {
        case .request: "play.fill"
        case .retry: "arrow.clockwise"
        case .refresh: "arrow.triangle.2.circlepath"
        case .cancel: "xmark"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .request: "Requests native pseudocode for the current function."
        case .retry: "Retries the exact prior native request authority."
        case .refresh: "Reprojects current authority and bypasses validated cache lookup."
        case .cancel: "Cancels only this window’s current native request."
        }
    }
}

struct NativeDecompilerCommandContext: Equatable, Sendable {
    let exactTargetEligible: Bool
    let retryAuthorityEqual: Bool
    let terminalOwner: Bool
}

enum NativeDecompilerCommandAvailability {
    static func enabledCommands(
        for state: NativeDecompilerLayeredPresentationState,
        context: NativeDecompilerCommandContext
    ) -> Set<NativeDecompilerControlCommand> {
        guard context.exactTargetEligible, !context.terminalOwner else { return [] }
        if state.attempt == .cancelling { return [] }
        if state.attempt != .none { return [.cancel] }
        if state.content != nil, state.notice == .none { return [.refresh] }
        if let failure = state.notice.failure,
           failure.retryable,
           context.retryAuthorityEqual
        {
            return [.retry]
        }
        if state.content == nil, state.notice == .none { return [.request] }
        return []
    }

    static func enabledCommands(
        for presentation: NativePseudocodePresentation,
        exactTargetEligible: Bool
    ) -> Set<NativeDecompilerControlCommand> {
        guard exactTargetEligible else { return [] }
        switch presentation.status {
        case .idle:
            return [.request]
        case .analyzing:
            return [.cancel]
        case .ready:
            return [.refresh]
        case .failed, .unavailable:
            guard let failure = presentation.failurePresentation else { return [] }
            if failure.recovery == .terminalOwner { return [] }
            if failure.retryable { return [.retry] }
            if failure.primaryAction == .refresh { return [.refresh] }
            return []
        case .stale:
            return []
        }
    }
}
