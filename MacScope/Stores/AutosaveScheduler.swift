import Foundation

/// Drives the debounce between a persisted mutation and an autosave write.
///
/// The store calls `scheduleAutosave()` on every mutation; after the implementor's
/// quiet period elapses it invokes `onFire`, which the store wires to consult the
/// pure `AutosavePolicy` and write if still dirty. Factoring the timing behind a
/// protocol keeps the store's autosave *decision* (pure, in `AutosavePolicy`)
/// separate from the *trigger* (real timer in production, manual in tests) — so
/// the "fires after a mutation, not on a no-op" behavior is unit-testable with no
/// wall-clock sleep: a test injects `ManualAutosaveTrigger` and fires it directly.
@MainActor
protocol AutosaveScheduling: AnyObject {
    /// Invoked when the debounce elapses. The store sets this to run the autosave.
    var onFire: (() -> Void)? { get set }

    /// (Re)arms the debounce after a mutation. Repeated calls coalesce into one fire.
    func scheduleAutosave()

    /// Cancels any pending fire (e.g. after an explicit save already persisted).
    func cancelPendingAutosave()
}

/// Production scheduler: coalesces mutations into a single delayed write using a
/// main-run-loop `Timer`. Each `scheduleAutosave()` resets the countdown, so a
/// burst of edits saves once, `interval` seconds after the last edit.
@MainActor
final class DebouncedAutosaveScheduler: AutosaveScheduling {
    var onFire: (() -> Void)?
    private let interval: TimeInterval
    private var timer: Timer?
    /// Monotonic token gating the deferred fire. The `Timer` fires synchronously but
    /// hops to the main actor via a `Task`, so between the Timer firing and the Task
    /// running, `invalidate()` is a no-op — `cancelPendingAutosave()` (and a fresh
    /// `scheduleAutosave()`) bump this so a stale in-flight Task is suppressed.
    private var generation = 0

    init(interval: TimeInterval = 2.0) {
        self.interval = interval
    }

    func scheduleAutosave() {
        timer?.invalidate()
        generation &+= 1
        let scheduledGeneration = generation
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            // Timer fires on the main run loop; hop onto the main actor to call back.
            Task { @MainActor in
                guard let self, self.generation == scheduledGeneration else { return }
                self.timer = nil
                self.onFire?()
            }
        }
    }

    func cancelPendingAutosave() {
        timer?.invalidate()
        timer = nil
        generation &+= 1
    }
}

/// Test/headless scheduler with no real clock. `scheduleAutosave()` just records
/// that a fire is pending; the test drives `fire()` (or `firePending()`)
/// explicitly, so autosave behavior is exercised deterministically.
@MainActor
final class ManualAutosaveTrigger: AutosaveScheduling {
    var onFire: (() -> Void)?
    private(set) var isPending = false
    private(set) var scheduleCount = 0

    func scheduleAutosave() {
        isPending = true
        scheduleCount += 1
    }

    func cancelPendingAutosave() {
        isPending = false
    }

    /// Fires the callback unconditionally (simulates the debounce elapsing).
    func fire() {
        isPending = false
        onFire?()
    }

    /// Fires only if a save was actually scheduled. Returns whether it fired —
    /// lets a test assert "a mutation scheduled an autosave" vs. "a no-op didn't".
    @discardableResult
    func firePending() -> Bool {
        guard isPending else { return false }
        fire()
        return true
    }
}
