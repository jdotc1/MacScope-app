import Darwin
import Foundation

enum NativeDecompilerSchedulingFailure: String, Error, Equatable, Sendable {
    case busy
    case duplicateRequestID = "duplicate-request-id"
    case cancelled
    case internalFailure = "internal-failure"
}

enum NativeDecompilerScheduledResult: Equatable, Sendable {
    case success(Data)
    case failure(NativeDecompilerSchedulingFailure)
}

enum NativeDecompilerSchedulingDisposition: Equatable, Sendable {
    case started
    case queued
    case rejected(NativeDecompilerSchedulingFailure)
}

enum NativeDecompilerCancellationDisposition: Equatable, Sendable {
    case activeSignaled
    case activeAlreadySignaled
    case queuedCancelled
    case notFound
}

struct NativeDecompilerRequestSchedulerSnapshot: Equatable, Sendable {
    let activeCount: Int
    let queuedCount: Int
}

/// Idempotent ownership token for one service-side monotonic deadline.
final class NativeDecompilerHardDeadlineCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(_ cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let cancellation = lock.withLock {
            defer { self.cancellation = nil }
            return self.cancellation
        }
        cancellation?()
    }

    deinit {
        cancel()
    }
}

/// A bounded, schema-independent gate around the process-global native runtime.
///
/// The scheduler owns at most two payloads: one active and one queued. `Operation` is invoked on a
/// dedicated serial queue and must not detach native work. The callback form exists so an
/// Objective-C++ bridge can report a terminal outcome without exposing its result type here; the
/// scheduler defensively ignores duplicate and late callbacks.
final class NativeDecompilerRequestScheduler: @unchecked Sendable {
    typealias Completion = @Sendable (NativeDecompilerScheduledResult) -> Void
    typealias Operation = @Sendable (
        _ requestID: UUID,
        _ payload: Data,
        _ cancellationState: NativeDecompilerCancellationState,
        _ completion: @escaping Completion
    ) -> Void
    typealias HardDeadlineScheduler = @Sendable (
        _ delayMilliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> NativeDecompilerHardDeadlineCancellation
    typealias ProcessTerminator = @Sendable (_ exactProcessID: Int32) -> Void

    private final class Entry: @unchecked Sendable {
        let requestID: UUID
        let sequence: UInt64
        let payload: Data
        let hardDeadlineMilliseconds: UInt64?
        let cancellationState: NativeDecompilerCancellationState
        let operation: Operation
        let completion: Completion
        var hardDeadlineCancellation: NativeDecompilerHardDeadlineCancellation?

        init(
            requestID: UUID,
            sequence: UInt64,
            payload: Data,
            hardDeadlineMilliseconds: UInt64?,
            cancellationState: NativeDecompilerCancellationState,
            operation: @escaping Operation,
            completion: @escaping Completion
        ) {
            self.requestID = requestID
            self.sequence = sequence
            self.payload = payload
            self.hardDeadlineMilliseconds = hardDeadlineMilliseconds
            self.cancellationState = cancellationState
            self.operation = operation
            self.completion = completion
        }
    }

    private let stateLock = NSLock()
    private let executionQueue: DispatchQueue
    private let serviceProcessID: Int32
    private let scheduleHardDeadline: HardDeadlineScheduler
    private let terminateServiceProcess: ProcessTerminator
    private var nextSequence: UInt64 = 0
    private var active: Entry?
    private var queued: Entry?

    convenience init(label: String = "com.macscope.native-decompiler.scheduler") {
        self.init(
            label: label,
            serviceProcessID: getpid(),
            scheduleHardDeadline: Self.scheduleProductionHardDeadline,
            terminateServiceProcess: Self.terminateExactCurrentProcess
        )
    }

    init(
        label: String,
        serviceProcessID: Int32,
        scheduleHardDeadline: @escaping HardDeadlineScheduler,
        terminateServiceProcess: @escaping ProcessTerminator
    ) {
        executionQueue = DispatchQueue(label: label, qos: .userInitiated)
        self.serviceProcessID = serviceProcessID
        self.scheduleHardDeadline = scheduleHardDeadline
        self.terminateServiceProcess = terminateServiceProcess
    }

    var snapshot: NativeDecompilerRequestSchedulerSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return NativeDecompilerRequestSchedulerSnapshot(
            activeCount: active == nil ? 0 : 1,
            queuedCount: queued == nil ? 0 : 1
        )
    }

    @discardableResult
    func submit(
        requestID: UUID,
        payload: Data,
        hardDeadlineMilliseconds: UInt64? = nil,
        operation: @escaping Operation,
        completion: @escaping Completion
    ) -> NativeDecompilerSchedulingDisposition {
        var entryToStart: Entry?
        var rejection: NativeDecompilerSchedulingFailure?
        let disposition: NativeDecompilerSchedulingDisposition

        stateLock.lock()
        if active?.requestID == requestID || queued?.requestID == requestID {
            rejection = .duplicateRequestID
            disposition = .rejected(.duplicateRequestID)
        } else if active == nil {
            let entry = makeEntryLocked(
                requestID: requestID,
                payload: payload,
                hardDeadlineMilliseconds: hardDeadlineMilliseconds,
                operation: operation,
                completion: completion
            )
            active = entry
            entryToStart = entry
            disposition = .started
        } else if queued == nil {
            queued = makeEntryLocked(
                requestID: requestID,
                payload: payload,
                hardDeadlineMilliseconds: hardDeadlineMilliseconds,
                operation: operation,
                completion: completion
            )
            disposition = .queued
        } else {
            rejection = .busy
            disposition = .rejected(.busy)
        }
        stateLock.unlock()

        if let rejection {
            completion(.failure(rejection))
        }
        if let entryToStart {
            start(entryToStart)
        }
        return disposition
    }

    @discardableResult
    func cancel(requestID: UUID) -> NativeDecompilerCancellationDisposition {
        var activeCancellationState: NativeDecompilerCancellationState?
        var queuedCompletion: Completion?
        var disposition: NativeDecompilerCancellationDisposition = .notFound

        stateLock.lock()
        if let active, active.requestID == requestID {
            activeCancellationState = active.cancellationState
        } else if let queued, queued.requestID == requestID {
            self.queued = nil
            queuedCompletion = queued.completion
            disposition = .queuedCancelled
        } else {
            disposition = .notFound
        }
        stateLock.unlock()

        if let activeCancellationState {
            disposition = activeCancellationState.cancel()
                ? .activeSignaled
                : .activeAlreadySignaled
        }
        queuedCompletion?(.failure(.cancelled))
        return disposition
    }

    private func makeEntryLocked(
        requestID: UUID,
        payload: Data,
        hardDeadlineMilliseconds: UInt64?,
        operation: @escaping Operation,
        completion: @escaping Completion
    ) -> Entry {
        nextSequence &+= 1
        return Entry(
            requestID: requestID,
            sequence: nextSequence,
            payload: payload,
            hardDeadlineMilliseconds: hardDeadlineMilliseconds,
            cancellationState: NativeDecompilerCancellationState(),
            operation: operation,
            completion: completion
        )
    }

    private func start(_ entry: Entry) {
        let requestID = entry.requestID
        let sequence = entry.sequence
        if let delayMilliseconds = entry.hardDeadlineMilliseconds {
            precondition(delayMilliseconds > 0, "native hard deadline must be positive")
            let cancellation = scheduleHardDeadline(delayMilliseconds) { [weak self] in
                self?.hardDeadlineExpired(requestID: requestID, sequence: sequence)
            }
            stateLock.withLock {
                guard active?.requestID == requestID, active?.sequence == sequence else {
                    cancellation.cancel()
                    return
                }
                active?.hardDeadlineCancellation = cancellation
            }
        }
        executionQueue.async { [self] in
            entry.operation(entry.requestID, entry.payload, entry.cancellationState) { [weak self] result in
                self?.finish(requestID: requestID, sequence: sequence, result: result)
            }
        }
    }

    private func finish(
        requestID: UUID,
        sequence: UInt64,
        result: NativeDecompilerScheduledResult
    ) {
        var terminalCompletion: Completion?
        var terminalResult = result
        var entryToStart: Entry?
        var hardDeadlineCancellation: NativeDecompilerHardDeadlineCancellation?

        stateLock.lock()
        guard let active,
              active.requestID == requestID,
              active.sequence == sequence else {
            stateLock.unlock()
            return
        }

        self.active = nil
        hardDeadlineCancellation = active.hardDeadlineCancellation
        terminalCompletion = active.completion
        if active.cancellationState.isCancelled {
            terminalResult = .failure(.cancelled)
        }
        if let queued {
            self.queued = nil
            self.active = queued
            entryToStart = queued
        }
        stateLock.unlock()

        hardDeadlineCancellation?.cancel()
        terminalCompletion?(terminalResult)
        if let entryToStart {
            start(entryToStart)
        }
    }

    private func hardDeadlineExpired(requestID: UUID, sequence: UInt64) {
        let shouldTerminate = stateLock.withLock {
            active?.requestID == requestID && active?.sequence == sequence
        }
        guard shouldTerminate else { return }
        terminateServiceProcess(serviceProcessID)
    }

    private static func scheduleProductionHardDeadline(
        delayMilliseconds: UInt64,
        action: @escaping @Sendable () -> Void
    ) -> NativeDecompilerHardDeadlineCancellation {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        timer.schedule(
            deadline: .now() + .milliseconds(Int(clamping: delayMilliseconds)),
            leeway: .milliseconds(10)
        )
        timer.setEventHandler(handler: action)
        timer.resume()
        return NativeDecompilerHardDeadlineCancellation {
            timer.setEventHandler {}
            timer.cancel()
        }
    }

    private static func terminateExactCurrentProcess(_ expectedProcessID: Int32) {
        guard expectedProcessID > 1, getpid() == expectedProcessID else { return }
        _ = kill(expectedProcessID, SIGKILL)
    }
}
