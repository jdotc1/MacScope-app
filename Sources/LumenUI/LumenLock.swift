import os

/// A small lock-protected box. Lumen supports macOS 14, so it cannot use `Mutex`
/// (Synchronization, macOS 15); this wraps `OSAllocatedUnfairLock` instead.
///
/// The box is `@unchecked Sendable` because it holds values that are not `Sendable` (caches of
/// `NSColor`, dispatch sources) and reaches them only while holding the lock.
final class LumenLock<State>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<State>

    init(_ initialState: State) {
        lock = OSAllocatedUnfairLock(uncheckedState: initialState)
    }

    /// Runs `body` with exclusive access to the state. Keep it short and never call back into
    /// code that takes the same lock: unfair locks are not reentrant.
    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try lock.withLockUnchecked(body)
    }
}
