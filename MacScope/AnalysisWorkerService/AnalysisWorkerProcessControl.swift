import Darwin
import Foundation

/// Construct once in this executable, never in the app or shared analysis target.
/// Self-SIGKILL avoids a saved-PID race. This watchdog does NOT cover a fully frozen process;
/// host observation/all-channel admission is a later slice and production remains unavailable.
final class AnalysisWorkerProcessControl: AnalysisWorkerProcessControlling, PatternWorkerWatchdog,
                                          @unchecked Sendable {
    let identity: AnalysisWorkerProcessIdentity
    private let controlQueue: DispatchQueue
    private let watchdog: AnalysisWorkerDeadlineWatchdog

    init() {
        let identity = AnalysisWorkerProcessIdentity(startupNonce: UUID(), processID: getpid())
        let queue = DispatchQueue(label: "org.macscope.app.worker-deadlines", attributes: .concurrent)
        self.identity = identity
        controlQueue = queue
        watchdog = AnalysisWorkerDeadlineWatchdog(identity: identity, schedule: { delayMS, action in
            // A concurrent queue prevents a stalled abort callback from blocking escalation.
            queue.asyncAfter(deadline: .now() + .milliseconds(delayMS), execute: action)
        }, terminateSelf: { _ = Darwin.kill(Darwin.getpid(), SIGKILL) })
    }

    func requestTermination(expectedNonce: UUID) -> Bool {
        guard expectedNonce == identity.startupNonce else { return false }
        controlQueue.async { _ = Darwin.kill(Darwin.getpid(), SIGKILL) }
        return true // Advisory acceptance only; never proof of exit.
    }

    func arm(requestID: UUID, expectedNonce: UUID, timeoutMS: Int,
             abort: @escaping @Sendable () -> Void) -> Bool {
        watchdog.arm(requestID: requestID, expectedNonce: expectedNonce,
                     timeoutMS: timeoutMS, abort: abort)
    }

    func nativeReturned(requestID: UUID) { watchdog.nativeReturned(requestID: requestID) }
}
