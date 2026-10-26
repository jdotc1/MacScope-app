import Foundation

protocol NativeDecompilerXPCClientScheduledAction: AnyObject, Sendable {
    func cancel()
}

protocol NativeDecompilerXPCClientTimerScheduling: Sendable {
    func schedule(
        after delay: Duration,
        action: @escaping @Sendable () -> Void
    ) -> any NativeDecompilerXPCClientScheduledAction
}

/// `DispatchTime` deadlines use system uptime, so wall-clock changes cannot shorten or extend the
/// watchdog. The returned token owns and cancels the one-shot source.
final class NativeDecompilerXPCClientMonotonicTimer: NativeDecompilerXPCClientTimerScheduling,
    @unchecked Sendable
{
    private let queue: DispatchQueue

    init(label: String = "com.macscope.native-decompiler.client-watchdog") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func schedule(
        after delay: Duration,
        action: @escaping @Sendable () -> Void
    ) -> any NativeDecompilerXPCClientScheduledAction {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + dispatchInterval(for: delay))
        source.setEventHandler(handler: action)
        let token = NativeDecompilerXPCClientDispatchTimerToken(source: source)
        source.resume()
        return token
    }
}

private final class NativeDecompilerXPCClientDispatchTimerToken:
    NativeDecompilerXPCClientScheduledAction, @unchecked Sendable
{
    private let lock = NSLock()
    private var source: DispatchSourceTimer?

    init(source: DispatchSourceTimer) {
        self.source = source
    }

    func cancel() {
        let source = lock.withLock { () -> DispatchSourceTimer? in
            defer { self.source = nil }
            return self.source
        }
        source?.setEventHandler {}
        source?.cancel()
    }

    deinit {
        cancel()
    }
}

private func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
    let components = duration.components
    guard components.seconds > 0 || components.attoseconds > 0 else {
        return .nanoseconds(0)
    }

    let seconds = UInt64(components.seconds)
    let fractional = UInt64(components.attoseconds / 1_000_000_000)
    let (wholeNanoseconds, multipliedOverflow) = seconds.multipliedReportingOverflow(
        by: 1_000_000_000
    )
    let (totalNanoseconds, addedOverflow) = wholeNanoseconds.addingReportingOverflow(fractional)
    let clamped: UInt64
    if multipliedOverflow || addedOverflow {
        clamped = UInt64(Int.max)
    } else {
        clamped = min(totalNanoseconds, UInt64(Int.max))
    }
    return .nanoseconds(Int(clamped))
}
