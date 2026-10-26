import Foundation
import os

/// The deliberately narrow coordinator surface available to one durable job session.
/// In particular, it excludes workspace-wide restoration APIs.
protocol ReconstructionJobSessionCoordinating: Sendable {
    func start(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool
    func pause(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool
    func resume(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool
    func cancel(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool
    func suspendWithoutDurableDisposition(jobID: UUID) async
}

extension ReconstructionJobCoordinator: ReconstructionJobSessionCoordinating {}

/// The bounded batch-runtime controls needed by a job session.
protocol ReconstructionJobSessionScheduling: Sendable {
    func pause(jobID: UUID) async
    func resume(jobID: UUID) async
    func retire(jobID: UUID) async
}

extension ReconstructionBatchScheduler: ReconstructionJobSessionScheduling {}

/// Proof that a job session has installed its running lifecycle and retained coordinator run.
/// The coordinator completion remains independently awaitable for explicit command outcomes and
/// terminal cleanup, but destination restoration need only wait for this admission to exist.
struct ReconstructionJobSessionAdmission: Sendable {
    let coordinatorCompletion: Task<Bool, Never>
}

/// Owns the live execution authority for exactly one durable Reconstruction job.
///
/// Callers never supply a job identity to a control method. That makes sibling-job dispatch
/// impossible at this boundary and keeps workspace-wide restoration out of a window session.
actor ReconstructionJobSession {
    private static let logger = Logger(
        subsystem: "org.macscope.MacScope",
        category: "ReconstructionJobSession"
    )

    nonisolated let durableJobID: UUID

    private enum Lifecycle: Equatable {
        case ready
        case running
        case pausing
        case paused
        case terminating
        case retired
    }

    private struct TerminalBarrier {
        enum Purpose {
            case cancel(priorLifecycle: Lifecycle)
            case retire
        }

        let token: UUID
        let purpose: Purpose
        let task: Task<Bool, Never>
    }

    private struct CoordinatorRun {
        let token: UUID
        let task: Task<Bool, Never>
        let authority: ReconstructionJobCommandAuthority
    }

    private let coordinator: any ReconstructionJobSessionCoordinating
    private let scheduler: any ReconstructionJobSessionScheduling
    private var lifecycle: Lifecycle = .ready
    private var coordinatorRun: CoordinatorRun?
    private var terminalBarrier: TerminalBarrier?
    private var lastSettledActivationAuthority: ReconstructionJobCommandAuthority?

    init(
        durableJobID: UUID,
        coordinator: any ReconstructionJobSessionCoordinating,
        scheduler: any ReconstructionJobSessionScheduling
    ) {
        self.durableJobID = durableJobID
        self.coordinator = coordinator
        self.scheduler = scheduler
    }

    @discardableResult
    func start(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard let admission = await enqueueStart(authority: authority) else { return false }
        return await admission.coordinatorCompletion.value
    }

    /// Installs the transient running lifecycle and retains the coordinator run before returning.
    /// The returned admission deliberately separates that installed boundary from the run's
    /// eventual completion.
    func enqueueStart(
        authority: ReconstructionJobCommandAuthority
    ) async -> ReconstructionJobSessionAdmission? {
        await awaitTerminalBarrierIfNeeded()
        guard lifecycle == .ready, authority.jobID == durableJobID,
              authority != lastSettledActivationAuthority else { return nil }
        lifecycle = .running
        let run = launchCoordinatorRun(authority: authority, resuming: false)
        return ReconstructionJobSessionAdmission(
            coordinatorCompletion: activationCompletionTask(
                run: run,
                priorLifecycle: .ready,
                requiesceSchedulerOnRejection: false
            )
        )
    }

    @discardableResult
    func pause(authority: ReconstructionJobCommandAuthority) async -> Bool {
        let lifecycleBeforeBarrier = lifecycle
        await awaitTerminalBarrierIfNeeded()
        guard (lifecycle == .ready || lifecycle == .running),
              authority.jobID == durableJobID else {
            Self.logger.error(
                "Pause rejected before coordinator: lifecycleBeforeBarrier=\(Self.lifecycleName(lifecycleBeforeBarrier), privacy: .public), lifecycleAfterBarrier=\(Self.lifecycleName(self.lifecycle), privacy: .public), jobMatches=\(authority.jobID == self.durableJobID, privacy: .public)"
            )
            return false
        }
        let priorLifecycle = lifecycle
        lifecycle = .pausing

        let applied = await coordinator.pause(
            jobID: durableJobID,
            authority: authority
        )
        if lifecycle != .pausing {
            let lifecycleBeforeBarrier = lifecycle
            await awaitTerminalBarrierIfNeeded()
            guard lifecycle == .pausing else {
                Self.logger.error(
                    "Pause lost pausing lifecycle after coordinator wait: prior=\(Self.lifecycleName(priorLifecycle), privacy: .public), observed=\(Self.lifecycleName(lifecycleBeforeBarrier), privacy: .public), afterBarrier=\(Self.lifecycleName(self.lifecycle), privacy: .public)"
                )
                return false
            }
        }
        if let run = coordinatorRun {
            _ = await run.task.value
            finishCoordinatorRun(ifTokenMatches: run.token)
        }
        guard applied, lifecycle == .pausing else {
            Self.logger.error(
                "Pause coordinator boundary rejected: applied=\(applied, privacy: .public), lifecycle=\(Self.lifecycleName(self.lifecycle), privacy: .public), prior=\(Self.lifecycleName(priorLifecycle), privacy: .public)"
            )
            if lifecycle == .pausing { lifecycle = priorLifecycle }
            await awaitTerminalBarrierIfNeeded()
            return false
        }

        // The coordinator run has now consumed and committed the durable pause request.
        // Only after that durable boundary may the batch executor release live authority.
        await scheduler.pause(jobID: durableJobID)
        if lifecycle != .pausing {
            let lifecycleBeforeBarrier = lifecycle
            await awaitTerminalBarrierIfNeeded()
            guard lifecycle == .pausing else {
                Self.logger.error(
                    "Pause lost pausing lifecycle after scheduler quiescence: observed=\(Self.lifecycleName(lifecycleBeforeBarrier), privacy: .public), afterBarrier=\(Self.lifecycleName(self.lifecycle), privacy: .public)"
                )
                return false
            }
        }
        lifecycle = .paused
        return true
    }

    @discardableResult
    func resume(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard let admission = await enqueueResume(authority: authority) else { return false }
        return await admission.coordinatorCompletion.value
    }

    /// Admits a durable resume before returning its installed-admission proof. A fresh reopened
    /// session may resume a paused durable job from `.ready`; an already-paused transient session
    /// resumes its scheduler child first and compensates with pause if the retained coordinator
    /// run eventually rejects.
    func enqueueResume(
        authority: ReconstructionJobCommandAuthority
    ) async -> ReconstructionJobSessionAdmission? {
        await awaitTerminalBarrierIfNeeded()
        guard (lifecycle == .ready || lifecycle == .paused),
              authority.jobID == durableJobID,
              authority != lastSettledActivationAuthority else { return nil }
        let priorLifecycle = lifecycle
        let resumesExistingTransientExecution = lifecycle == .paused
        lifecycle = .running
        if resumesExistingTransientExecution {
            await scheduler.resume(jobID: durableJobID)
            if lifecycle != .running {
                await awaitTerminalBarrierIfNeeded()
                guard lifecycle == .running else { return nil }
            }
        }
        let run = launchCoordinatorRun(authority: authority, resuming: true)
        return ReconstructionJobSessionAdmission(
            coordinatorCompletion: activationCompletionTask(
                run: run,
                priorLifecycle: priorLifecycle,
                requiesceSchedulerOnRejection: resumesExistingTransientExecution
            )
        )
    }

    @discardableResult
    func cancel(authority: ReconstructionJobCommandAuthority) async -> Bool {
        if let terminalBarrier {
            let completed = await terminalBarrier.task.value
            if completed {
                finishTerminalTransition(ifTokenMatches: terminalBarrier.token)
            } else if case let .cancel(priorLifecycle) = terminalBarrier.purpose {
                finishRejectedCancel(
                    ifTokenMatches: terminalBarrier.token,
                    priorLifecycle: priorLifecycle
                )
            }
            return false
        }
        guard lifecycle != .retired, lifecycle != .terminating,
              authority.jobID == durableJobID else { return false }
        let priorLifecycle = lifecycle
        lifecycle = .terminating
        let coordinatorRun = self.coordinatorRun?.task
        let coordinator = self.coordinator
        let scheduler = self.scheduler
        let jobID = durableJobID
        let barrier = TerminalBarrier(
            token: UUID(),
            purpose: .cancel(priorLifecycle: priorLifecycle),
            task: Task {
                let applied = await coordinator.cancel(jobID: jobID, authority: authority)
                _ = await coordinatorRun?.value
                guard applied else { return false }
                await scheduler.retire(jobID: jobID)
                return true
            }
        )
        terminalBarrier = barrier
        let applied = await barrier.task.value
        guard applied else {
            finishRejectedCancel(
                ifTokenMatches: barrier.token,
                priorLifecycle: priorLifecycle
            )
            return false
        }
        finishTerminalTransition(ifTokenMatches: barrier.token)
        return true
    }

    /// Releases transient runtime authority without writing a durable cancellation disposition.
    func retire() async {
        if let terminalBarrier {
            let completed = await terminalBarrier.task.value
            if completed {
                finishTerminalTransition(ifTokenMatches: terminalBarrier.token)
                return
            }
            if case let .cancel(priorLifecycle) = terminalBarrier.purpose {
                finishRejectedCancel(
                    ifTokenMatches: terminalBarrier.token,
                    priorLifecycle: priorLifecycle
                )
            }
        }
        guard lifecycle != .retired, lifecycle != .terminating else { return }
        lifecycle = .terminating
        let coordinatorRun = self.coordinatorRun?.task
        let coordinator = self.coordinator
        let scheduler = self.scheduler
        let jobID = durableJobID
        let barrier = TerminalBarrier(
            token: UUID(),
            purpose: .retire,
            task: Task {
                await coordinator.suspendWithoutDurableDisposition(jobID: jobID)
                _ = await coordinatorRun?.value
                await scheduler.retire(jobID: jobID)
                return true
            }
        )
        terminalBarrier = barrier
        _ = await barrier.task.value
        finishTerminalTransition(ifTokenMatches: barrier.token)
    }

    @discardableResult
    private func launchCoordinatorRun(
        authority: ReconstructionJobCommandAuthority,
        resuming: Bool
    ) -> CoordinatorRun {
        let coordinator = self.coordinator
        let jobID = durableJobID
        let run = CoordinatorRun(token: UUID(), task: Task {
            if resuming {
                return await coordinator.resume(jobID: jobID, authority: authority)
            } else {
                return await coordinator.start(jobID: jobID, authority: authority)
            }
        }, authority: authority)
        coordinatorRun = run
        return run
    }

    private func awaitTerminalBarrierIfNeeded() async {
        guard let terminalBarrier else { return }
        let completed = await terminalBarrier.task.value
        if completed {
            finishTerminalTransition(ifTokenMatches: terminalBarrier.token)
        } else if case let .cancel(priorLifecycle) = terminalBarrier.purpose {
            finishRejectedCancel(
                ifTokenMatches: terminalBarrier.token,
                priorLifecycle: priorLifecycle
            )
        }
    }

    private func activationCompletionTask(
        run: CoordinatorRun,
        priorLifecycle: Lifecycle,
        requiesceSchedulerOnRejection: Bool
    ) -> Task<Bool, Never> {
        Task { [weak self] in
            let accepted = await run.task.value
            guard let self else { return false }
            return await self.finishActivation(
                runToken: run.token,
                authority: run.authority,
                accepted: accepted,
                priorLifecycle: priorLifecycle,
                requiesceSchedulerOnRejection: requiesceSchedulerOnRejection
            )
        }
    }

    private func finishActivation(
        runToken: UUID,
        authority: ReconstructionJobCommandAuthority,
        accepted: Bool,
        priorLifecycle: Lifecycle,
        requiesceSchedulerOnRejection: Bool
    ) async -> Bool {
        finishCoordinatorRun(ifTokenMatches: runToken)
        guard accepted, lifecycle == .running else {
            if !accepted, requiesceSchedulerOnRejection, lifecycle == .running {
                await scheduler.pause(jobID: durableJobID)
            }
            if lifecycle == .running { lifecycle = priorLifecycle }
            return false
        }
        lastSettledActivationAuthority = authority
        // A completed coordinator run has relinquished execution authority. It may have
        // committed an automatic pause; durable command admission decides what is legal next.
        lifecycle = .ready
        return true
    }

    private func finishTerminalTransition(ifTokenMatches token: UUID) {
        guard terminalBarrier?.token == token else { return }
        coordinatorRun = nil
        terminalBarrier = nil
        lifecycle = .retired
    }

    private func finishRejectedCancel(
        ifTokenMatches token: UUID,
        priorLifecycle: Lifecycle
    ) {
        guard terminalBarrier?.token == token else { return }
        terminalBarrier = nil
        lifecycle = priorLifecycle
    }

    private func finishCoordinatorRun(ifTokenMatches token: UUID) {
        guard coordinatorRun?.token == token else { return }
        coordinatorRun = nil
    }

    private static func lifecycleName(_ lifecycle: Lifecycle) -> String {
        switch lifecycle {
        case .ready: "ready"
        case .running: "running"
        case .pausing: "pausing"
        case .paused: "paused"
        case .terminating: "terminating"
        case .retired: "retired"
        }
    }
}
