import Foundation

// Shared logic, independent of the C module. One instance PER WORKER PROCESS,
// not one per XPC principal/connection. Dedicated pattern lane; it does not
// consume or reset NativeDecompiler state. Integration retains the lease until
// the synchronous native job has actually returned or the process exits.
final class PatternWorkerAdmission: @unchecked Sendable {
    static let shared = PatternWorkerAdmission()
    private let lock = NSLock()
    private var active: UUID?
    private var cancellation: (@Sendable () -> Void)?
    private var cancelled = false
    // Bounded early-cancel tombstones. Exhaustion fails closed until this worker
    // process retires; it never drops a cancellation and starts that job later.
    private var pendingCancellation: Set<UUID> = []
    private var recentlyFinished: [UUID] = []
    private var admissionExhausted = false

    func tryAcquire(requestID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active == nil, !admissionExhausted,
              !recentlyFinished.contains(requestID) else { return false }
        active = requestID
        cancellation = nil
        cancelled = pendingCancellation.remove(requestID) != nil
        return true
    }

    // Install only after creating the native job, before enqueueing evaluation.
    // An accepted request can be cancelled before this handler is installed.
    func installCancellation(requestID: UUID, _ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        guard active == requestID else { lock.unlock(); return }
        cancellation = handler
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { handler() }
    }

    func cancel(requestID: UUID) {
        lock.lock()
        guard active == requestID else {
            if !recentlyFinished.contains(requestID) {
                if pendingCancellation.count < 64 || pendingCancellation.contains(requestID) {
                    pendingCancellation.insert(requestID)
                } else {
                    admissionExhausted = true
                }
            }
            lock.unlock()
            return
        }
        cancelled = true
        let handler = cancellation
        lock.unlock()
        handler?()
    }

    func releaseAfterNativeReturn(requestID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard active == requestID else { return }
        active = nil
        cancellation = nil
        cancelled = false
        recentlyFinished.append(requestID)
        if recentlyFinished.count > 64 { recentlyFinished.removeFirst() }
    }
}

