import Foundation

struct NativeDecompilerDriveStateMachine: Sendable {
    private(set) var state: NativeDriveState = .idle
    private var context: NativeDriveContext?
    private var targetSeed: NativeDriveTargetSeed?
    private var resolvedTarget: NativeDriveResolvedTarget?
    private var handlerBindingID: NativeDriveHandlerBindingID?
    private var handlerBindingGeneration: UInt64 = 0
    private var semanticInputState: NativeDecompilerSemanticInputState?
    private var semanticInputGeneration: UInt64 = 0
    private var manualIntentGeneration: UInt64 = 0
    private var lastSubmittedTicket: NativeDriveSubmissionTicket?
    private var cancellationFence: UInt64 = 0
    private var latchedRefresh = false
    private var lastPublishedInvalidIdentity: NativeDecompilerSemanticInputIdentity?

    init(
        handlerBindingGeneration: UInt64 = 0,
        semanticInputGeneration: UInt64 = 0,
        manualIntentGeneration: UInt64 = 0,
        cancellationFence: UInt64 = 0
    ) {
        self.handlerBindingGeneration = handlerBindingGeneration
        self.semanticInputGeneration = semanticInputGeneration
        self.manualIntentGeneration = manualIntentGeneration
        self.cancellationFence = cancellationFence
    }

    mutating func handle(_ event: NativeDriveEvent) throws -> [NativeDriveEffect] {
        if case .exhausted = state { return [] }
        switch event {
        case let .establish(newContext):
            context = newContext
            targetSeed = nil
            resolvedTarget = nil
            semanticInputState = nil
            lastSubmittedTicket = nil
            latchedRefresh = false
            lastPublishedInvalidIdentity = nil
            state = .installing(newContext)
            return []

        case let .installTarget(seed, resolved, waitReason):
            return try install(seed: seed, resolved: resolved, waitReason: waitReason)

        case let .bind(binding):
            guard handlerBindingID != binding else { return [] }
            guard Self.advance(&handlerBindingGeneration) else {
                return counterExhausted(.handlerBinding)
            }
            handlerBindingID = binding
            return try reconcile(reason: .handlerBound, policy: .allowValidatedCache)

        case let .selectedOwnerReady(target):
            resolvedTarget = target
            targetSeed = nil
            state = .ready(target.context, target)
            return try reconcile(reason: .selectedOwnerReady, policy: refreshPolicy())

        case let .selectedOwnerFailed(failure):
            guard let context else { return [] }
            state = .retired(context, .readinessFailed)
            return [.invalidateOutstanding, .publishReadinessFailure(failure)]

        case let .targetChanged(seed, resolved):
            if case let .waitingForReadiness(context, pendingSeed, .structuralReanalysisPending) = state,
               let seed, seed.owner == pendingSeed.owner {
                // A selection change can arrive before patched analysis lands. Keep the
                // owner fenced instead of submitting the prior analysis fingerprint.
                targetSeed = seed
                state = .waitingForReadiness(context, seed, .structuralReanalysisPending)
                return []
            }
            if resolvedTarget == resolved, resolved != nil || targetSeed == seed {
                // Selection can move within one exact resolved function without changing native
                // work authority. Retain the current submission while remembering the latest seed.
                targetSeed = seed
                return []
            }
            let fence: [NativeDriveEffect] = state.isSubmitted ? [.invalidateOutstanding] : []
            semanticInputState = nil
            lastPublishedInvalidIdentity = nil
            return fence + (try install(seed: seed, resolved: resolved, waitReason: nil))

        case let .semanticInputChanged(input, deferUntilStructuralLanding):
            if semanticInputState?.identity == input.identity { return [] }
            let displacedSubmission = state.isSubmitted
            guard advanceSemanticGeneration() else {
                return counterExhausted(.semanticInput)
            }
            semanticInputState = input
            switch input {
            case let .invalid(diagnostic):
                if displacedSubmission, let context, let resolvedTarget {
                    state = .ready(context, resolvedTarget)
                }
                let fence: [NativeDriveEffect] = displacedSubmission ? [.invalidateOutstanding] : []
                return fence + projectionFailureEffects(
                    diagnostic: diagnostic,
                    identity: input.identity
                )
            case .valid:
                lastPublishedInvalidIdentity = nil
                if deferUntilStructuralLanding, let context, let targetSeed {
                    state = .waitingForReadiness(
                        context, targetSeed, .structuralReanalysisPending
                    )
                    return displacedSubmission ? [.invalidateOutstanding] : []
                }
                let fence: [NativeDriveEffect] = displacedSubmission ? [.invalidateOutstanding] : []
                return fence
                    + (try reconcile(reason: .semanticAuthoring, policy: refreshPolicy()))
            }

        case .patchedBytesChanged:
            guard let target = resolvedTarget else { return [] }
            let displacedSubmission = state.isSubmitted
            guard advanceSemanticGeneration() else {
                return counterExhausted(.semanticInput)
            }
            let pendingSeed = NativeDriveTargetSeed(
                context: target.context, owner: target.owner,
                selectedAddress: target.functionStart
            )
            targetSeed = pendingSeed
            resolvedTarget = nil
            state = .waitingForReadiness(target.context, pendingSeed, .structuralReanalysisPending)
            return displacedSubmission ? [.invalidateOutstanding] : []

        case let .acceptedStructuralLanding(target):
            guard let target else {
                return retire(.noExactFunction)
            }
            resolvedTarget = target
            state = .ready(target.context, target)
            return try reconcile(reason: .acceptedStructuralAnalysis, policy: refreshPolicy())

        case let .terminal(_, ticket):
            guard case let .submitted(currentTicket) = state,
                  currentTicket == ticket else { return [] }
            // Terminal observations never consume the frozen ticket or auto-retry.
            return []

        case .request:
            return try reconcile(reason: .manualRequest, policy: .allowValidatedCache)

        case .retry:
            guard case let .submitted(lastSubmittedTicket) = state,
                  case .valid? = semanticInputState else { return [] }
            return [.retry(frozenTicket: lastSubmittedTicket)]

        case .refresh:
            let displacedSubmission = state.isSubmitted
            guard Self.advance(&manualIntentGeneration) else {
                return counterExhausted(.manualIntent)
            }
            latchedRefresh = true
            guard resolvedTarget != nil else {
                if let context, let targetSeed {
                    // A pending patch keeps its structural fence: the latched refresh
                    // runs once patched analysis lands, never against the old analysis.
                    let reason: NativeDriveWaitReason
                    if case .waitingForReadiness(_, _, .structuralReanalysisPending) = state {
                        reason = .structuralReanalysisPending
                    } else {
                        reason = .refreshLatchedUntilReadiness
                    }
                    state = .waitingForReadiness(context, targetSeed, reason)
                }
                return []
            }
            let fence: [NativeDriveEffect] =
                displacedSubmission ? [.invalidateOutstanding] : []
            return fence
                + (try reconcile(reason: .manualRefresh, policy: .bypassCacheLookup))

        case .cancel:
            guard Self.advance(&cancellationFence) else {
                return counterExhausted(.cancellationFence)
            }
            latchedRefresh = false
            return [.cancelOutstanding]

        case let .counterExhausted(axis):
            return counterExhausted(axis)

        case let .retire(reason):
            return retire(reason)
        }
    }

    private mutating func install(
        seed: NativeDriveTargetSeed?,
        resolved: NativeDriveResolvedTarget?,
        waitReason: NativeDriveWaitReason?
    ) throws -> [NativeDriveEffect] {
        targetSeed = seed
        resolvedTarget = resolved
        guard let context else { return [] }
        if let resolved {
            state = .ready(context, resolved)
            return try reconcile(reason: .installationCompleted, policy: refreshPolicy())
        }
        if let seed {
            state = .waitingForReadiness(
                context,
                seed,
                waitReason ?? .selectedOwnerNeedsRehydration
            )
            return []
        }
        return retire(.noSelection)
    }

    private mutating func reconcile(
        reason: NativeDriveReconcileReason,
        policy: NativeDecompilerCacheLookupPolicy
    ) throws -> [NativeDriveEffect] {
        _ = reason
        guard handlerBindingID != nil,
              let target = resolvedTarget,
              let semanticInputState else { return [] }
        let ticket = NativeDriveSubmissionTicket(
            driveGeneration: target.context.driveGeneration,
            handlerBindingGeneration: handlerBindingGeneration,
            semanticInputGeneration: semanticInputGeneration,
            manualIntentGeneration: manualIntentGeneration,
            target: target
        )
        if case let .invalid(diagnostic) = semanticInputState {
            return projectionFailureEffects(
                diagnostic: diagnostic,
                identity: semanticInputState.identity,
                ticket: ticket
            )
        }
        guard ticket != lastSubmittedTicket || policy == .bypassCacheLookup else { return [] }
        lastSubmittedTicket = ticket
        state = .submitted(ticket)
        latchedRefresh = false
        return [.submit(ticket: ticket, cacheLookupPolicy: policy)]
    }

    private func currentTicket() -> NativeDriveSubmissionTicket? {
        guard let target = resolvedTarget else { return nil }
        return NativeDriveSubmissionTicket(
            driveGeneration: target.context.driveGeneration,
            handlerBindingGeneration: handlerBindingGeneration,
            semanticInputGeneration: semanticInputGeneration,
            manualIntentGeneration: manualIntentGeneration,
            target: target
        )
    }

    private mutating func projectionFailureEffects(
        diagnostic: NativeAuthoredProjectionDiagnostic,
        identity: NativeDecompilerSemanticInputIdentity,
        ticket: NativeDriveSubmissionTicket? = nil
    ) -> [NativeDriveEffect] {
        guard lastPublishedInvalidIdentity != identity,
              let ticket = ticket ?? currentTicket() else { return [] }
        lastPublishedInvalidIdentity = identity
        return [.publishProjectionFailure(diagnostic, ticket: ticket)]
    }

    private mutating func retire(_ reason: NativeDriveRetirementReason) -> [NativeDriveEffect] {
        guard let context else { return [] }
        state = .retired(context, reason)
        resolvedTarget = nil
        latchedRefresh = false
        return [.invalidateOutstanding]
    }

    private mutating func counterExhausted(
        _ axis: NativeDriveCounterAxis
    ) -> [NativeDriveEffect] {
        state = .exhausted(axis)
        resolvedTarget = nil
        latchedRefresh = false
        return [.publishReadinessFailure(.counterExhausted(axis))]
    }

    private mutating func advanceSemanticGeneration() -> Bool {
        Self.advance(&semanticInputGeneration)
    }

    private func refreshPolicy() -> NativeDecompilerCacheLookupPolicy {
        latchedRefresh ? .bypassCacheLookup : .allowValidatedCache
    }

    private static func advance(_ value: inout UInt64) -> Bool {
        let result = value.addingReportingOverflow(1)
        guard !result.overflow, result.partialValue != 0 else { return false }
        value = result.partialValue
        return true
    }
}

private extension NativeDriveState {
    var isSubmitted: Bool {
        if case .submitted = self { return true }
        return false
    }
}
