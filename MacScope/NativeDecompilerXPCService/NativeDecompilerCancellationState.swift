import Foundation
import Darwin

/// Caller-lifetime cancellation state for one synchronous native decompile.
///
/// The scheduler retains this object for the complete active-request lifetime. Native bridge
/// callbacks may poll `isCancelled`, but no component may retain the state after it invokes the
/// scheduler's terminal callback.
final class NativeDecompilerCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private weak var cancellationRegistration: NativeDecompilerCancellationRegistration?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Returns `true` only for the transition from live to cancelled.
    @discardableResult
    func cancel() -> Bool {
        let registration: NativeDecompilerCancellationRegistration?

        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return false
        }
        cancelled = true
        registration = cancellationRegistration
        cancellationRegistration = nil
        lock.unlock()

        registration?.fire()
        return true
    }

    /// Installs the single request-scoped cancellation relay.
    ///
    /// Registration is race-safe with `cancel()`: a callback registered after cancellation fires
    /// synchronously before this method returns. The caller must retain the returned token for the
    /// complete synchronous native call and invalidate it before releasing native request state.
    func observeCancellation(
        _ observer: @escaping @Sendable () -> Void
    ) -> NativeDecompilerCancellationRegistration {
        let registration = NativeDecompilerCancellationRegistration(
            state: self,
            observer: observer
        )
        let fireImmediately: Bool

        lock.lock()
        if cancelled {
            fireImmediately = true
        } else {
            precondition(
                cancellationRegistration == nil,
                "one native cancellation relay is permitted per active request"
            )
            cancellationRegistration = registration
            fireImmediately = false
        }
        lock.unlock()

        if fireImmediately {
            registration.fire()
        }
        return registration
    }

    fileprivate func removeCancellationRegistration(
        _ registration: NativeDecompilerCancellationRegistration
    ) {
        lock.lock()
        if cancellationRegistration === registration {
            cancellationRegistration = nil
        }
        lock.unlock()
    }
}

/// Lifetime token for the request-scoped cancellation relay.
///
/// `invalidate()` is synchronous with an in-flight observer. Once it returns, the observer has
/// either completed or was prevented from starting, so native request state can be released.
final class NativeDecompilerCancellationRegistration: @unchecked Sendable {
    private enum Phase {
        case armed
        case firing
        case terminal
    }

    private let state: NativeDecompilerCancellationState
    private let condition = NSCondition()
    private var phase: Phase = .armed
    private var firingThread: pthread_t?
    private var observer: (@Sendable () -> Void)?

    fileprivate init(
        state: NativeDecompilerCancellationState,
        observer: @escaping @Sendable () -> Void
    ) {
        self.state = state
        self.observer = observer
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        state.removeCancellationRegistration(self)

        condition.lock()
        switch phase {
        case .armed:
            observer = nil
            phase = .terminal
        case .firing:
            observer = nil
            // A cancellation observer may synchronously tear down its own request token. It is
            // already the sole in-flight callback, so waiting here would deadlock on itself.
            if let firingThread, pthread_equal(firingThread, pthread_self()) != 0 {
                condition.unlock()
                return
            }
            while phase == .firing {
                condition.wait()
            }
        case .terminal:
            observer = nil
        }
        condition.unlock()
    }

    fileprivate func fire() {
        let callback: (@Sendable () -> Void)?

        condition.lock()
        if phase == .armed, let observer {
            callback = observer
            self.observer = nil
            phase = .firing
            firingThread = pthread_self()
        } else {
            callback = nil
        }
        condition.unlock()

        guard let callback else { return }
        callback()

        condition.lock()
        firingThread = nil
        phase = .terminal
        condition.broadcast()
        condition.unlock()
    }
}
