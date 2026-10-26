import Foundation

/// Gives synchronous recursive rendering more stack than a cooperative executor provides.
/// The caller retains its cancellation and publication checkpoints; the current render always
/// finishes before its continuation resumes, including when the requesting task is cancelled.
enum PseudocodeRenderingThread {
    static func run<Value: Sendable>(
        _ render: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try autoreleasepool { try render() } })
            }
            thread.name = "Pseudocode rendering"
            thread.stackSize = 16 * 1_024 * 1_024
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Task-local cancellation is unavailable on a plain Thread. Requests with in-render
    /// checkpoints forward cancellation through this state before cancelling their task.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() { lock.withLock { cancelled = true } }

        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }
}
