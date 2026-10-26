import Foundation

enum Phase2ShellTranscriptPollingOwner: Equatable, Sendable {
    case unselected
    case legacyManual
    case continuousSurface(Phase2ShellSurfaceCommandCoordinate)

    var permitsManualReduction: Bool {
        self == .legacyManual
    }
}

/// Runs one bounded broker transcript poll loop for one exact renderer coordinate.
///
/// Each new wire poll carries a fresh invocation ID. A separate operation token stays stable
/// for the coordinate's lifetime alongside
/// the complete session/request/generation fence. Store admission and reduction remain the sole
/// authority for accepting broker outcomes.
final class Phase2ContinuousShellTranscriptController: @unchecked Sendable {
    enum PollDisposition: Equatable, Sendable {
        case accepted
        case acceptedEmpty
        case deferred
        case retired
        case failed
    }

    typealias Poll = @MainActor @Sendable (
        _ commandID: UUID,
        _ coordinate: Phase2ShellSurfaceCommandCoordinate,
        _ maximumEvents: Int,
        _ maximumBytes: Int,
        _ timeoutMilliseconds: Int
    ) async -> PollDisposition

    typealias HealthFailure = @MainActor @Sendable (
        _ coordinate: Phase2ShellSurfaceCommandCoordinate
    ) -> Void

    typealias DispositionHandled = @MainActor @Sendable (
        _ disposition: PollDisposition,
        _ retainedOwnership: Bool
    ) -> Void

    struct Configuration: Equatable, Sendable {
        let maximumEvents: Int
        let maximumBytes: Int
        let timeoutMilliseconds: Int
        let idleDelayNanoseconds: UInt64
        let contentionDelayNanoseconds: UInt64

        init(
            maximumEvents: Int = 32,
            maximumBytes: Int = 4_096,
            timeoutMilliseconds: Int = 50,
            idleDelayNanoseconds: UInt64 = 50_000_000,
            contentionDelayNanoseconds: UInt64 = 5_000_000
        ) {
            self.maximumEvents = min(max(maximumEvents, 1), 64)
            self.maximumBytes = min(max(maximumBytes, 1), 16_384)
            self.timeoutMilliseconds = min(max(timeoutMilliseconds, 0), 250)
            self.idleDelayNanoseconds = min(max(idleDelayNanoseconds, 1_000_000), 250_000_000)
            self.contentionDelayNanoseconds = min(
                max(contentionDelayNanoseconds, 1_000_000),
                50_000_000
            )
        }
    }

    private struct State {
        var coordinate: Phase2ShellSurfaceCommandCoordinate?
        var commandID: UUID?
        var taskLeaseID: UUID?
        var poll: Poll?
        var healthFailure: HealthFailure?
        var task: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var state = State()
    private let configuration: Configuration
    private let idleWait: @Sendable (UInt64) async throws -> Void
    private let dispositionHandled: DispositionHandled?

    init(
        configuration: Configuration = Configuration(),
        idleWait: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        dispositionHandled: DispositionHandled? = nil
    ) {
        self.idleWait = idleWait
        self.configuration = configuration
        self.dispositionHandled = dispositionHandled
    }

    deinit {
        stop()
    }

    /// Reconciliation of one coordinate is idempotent. Replacement fences the prior generation
    /// before the new task is installed.
    func start(
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        commandID: UUID,
        poll: @escaping Poll,
        healthFailure: @escaping HealthFailure
    ) {
        precondition(coordinate.generation > 0, "continuous transcript generations are one-based")
        lock.withLock {
            if state.coordinate == coordinate,
               state.commandID == commandID,
               state.task != nil {
                return
            }
            state.task?.cancel()
            let taskLeaseID = UUID()
            state.coordinate = coordinate
            state.commandID = commandID
            state.taskLeaseID = taskLeaseID
            state.poll = poll
            state.healthFailure = healthFailure
            state.task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.run(
                    coordinate: coordinate,
                    commandID: commandID,
                    taskLeaseID: taskLeaseID
                )
            }
        }
    }

    /// A stale owner cannot stop a replacement that reused the same broker session.
    @discardableResult
    func stop(coordinate candidate: Phase2ShellSurfaceCommandCoordinate) -> Bool {
        lock.withLock {
            guard state.coordinate == candidate else { return false }
            retireLocked()
            return true
        }
    }

    func stop() {
        lock.withLock {
            retireLocked()
        }
    }

    private func run(
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        commandID: UUID,
        taskLeaseID: UUID
    ) async {
        while !Task.isCancelled {
            guard let poll = activePoll(
                coordinate: coordinate,
                commandID: commandID,
                taskLeaseID: taskLeaseID
            ) else { return }
            let disposition = await poll(
                UUID(),
                coordinate,
                configuration.maximumEvents,
                configuration.maximumBytes,
                configuration.timeoutMilliseconds
            )

            switch disposition {
            case .accepted, .acceptedEmpty:
                let retainedOwnership = isActive(
                    coordinate: coordinate,
                    commandID: commandID,
                    taskLeaseID: taskLeaseID
                )
                await reportDispositionHandled(disposition, retainedOwnership: retainedOwnership)
                guard retainedOwnership else { return }
                // The store has finished accepting the outcome and released its operation.
                // Only the polling loop waits, leaving Send and Interrupt admissible.
                if disposition == .acceptedEmpty {
                    do {
                        try await idleWait(configuration.idleDelayNanoseconds)
                    } catch {
                        return
                    }
                } else {
                    await Task.yield()
                }
            case .deferred:
                let retainedOwnership = isActive(
                    coordinate: coordinate,
                    commandID: commandID,
                    taskLeaseID: taskLeaseID
                )
                await reportDispositionHandled(disposition, retainedOwnership: retainedOwnership)
                guard retainedOwnership else { return }
                do {
                    try await Task.sleep(nanoseconds: configuration.contentionDelayNanoseconds)
                } catch {
                    return
                }
            case .retired:
                let retainedOwnership = stop(
                    coordinate: coordinate,
                    commandID: commandID,
                    taskLeaseID: taskLeaseID
                )
                await reportDispositionHandled(disposition, retainedOwnership: retainedOwnership)
                return
            case .failed:
                let healthFailure = retireForFailure(
                    coordinate: coordinate,
                    commandID: commandID,
                    taskLeaseID: taskLeaseID
                )
                await reportDispositionHandled(
                    disposition,
                    retainedOwnership: healthFailure != nil
                )
                guard let healthFailure else { return }
                await healthFailure(coordinate)
                return
            }
        }
    }

    private func reportDispositionHandled(
        _ disposition: PollDisposition,
        retainedOwnership: Bool
    ) async {
        guard let dispositionHandled else { return }
        await dispositionHandled(disposition, retainedOwnership)
    }

    private func activePoll(
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        commandID: UUID,
        taskLeaseID: UUID
    ) -> Poll? {
        lock.withLock {
            guard state.coordinate == coordinate,
                  state.commandID == commandID,
                  state.taskLeaseID == taskLeaseID,
                  state.task != nil
            else { return nil }
            return state.poll
        }
    }

    private func isActive(
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        commandID: UUID,
        taskLeaseID: UUID
    ) -> Bool {
        lock.withLock {
            state.coordinate == coordinate
                && state.commandID == commandID
                && state.taskLeaseID == taskLeaseID
                && state.task != nil
        }
    }

    @discardableResult
    private func stop(
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        commandID: UUID,
        taskLeaseID: UUID
    ) -> Bool {
        lock.withLock {
            guard state.coordinate == coordinate,
                  state.commandID == commandID,
                  state.taskLeaseID == taskLeaseID
            else { return false }
            retireLocked()
            return true
        }
    }

    private func retireForFailure(
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        commandID: UUID,
        taskLeaseID: UUID
    ) -> HealthFailure? {
        lock.withLock {
            guard state.coordinate == coordinate,
                  state.commandID == commandID,
                  state.taskLeaseID == taskLeaseID,
                  let healthFailure = state.healthFailure
            else { return nil }
            retireLocked()
            return healthFailure
        }
    }

    private func retireLocked() {
        state.task?.cancel()
        state.task = nil
        state.coordinate = nil
        state.commandID = nil
        state.taskLeaseID = nil
        state.poll = nil
        state.healthFailure = nil
    }
}
