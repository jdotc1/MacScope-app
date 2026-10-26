#if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
import Darwin
import Foundation

/// Process-global controller for deterministic signed-XPC lifecycle qualification.
///
/// The controller never supplies native output. Its only production-path hook is a barrier entered
/// after the real cancellation relay is installed and immediately before the real native request.
final class NativeDecompilerLiveXPCTestControl: @unchecked Sendable {
    static let shared = NativeDecompilerLiveXPCTestControl()

    private final class EnteredWaiter: @unchecked Sendable {
        let reply: (NativeDecompilerLiveXPCTestReceipt?) -> Void

        init(_ reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void) {
            self.reply = reply
        }
    }

    private final class EventWaiter: @unchecked Sendable {
        let event: NativeDecompilerLiveXPCTestEvent
        let reply: (NativeDecompilerLiveXPCTestReceipt?) -> Void

        init(
            event: NativeDecompilerLiveXPCTestEvent,
            reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
        ) {
            self.event = event
            self.reply = reply
        }
    }

    private final class RequestState: @unchecked Sendable {
        let holdMode: NativeDecompilerLiveXPCTestHoldMode
        var entered = false
        var released = false
        var cancellationObserved = false
        var submissionWasQueued: Bool?
        var replyAttempted = false
        var enteredWaiters: [EnteredWaiter] = []
        var eventWaiters: [EventWaiter] = []

        init(holdMode: NativeDecompilerLiveXPCTestHoldMode) {
            self.holdMode = holdMode
        }
    }

    private let condition = NSCondition()
    private let processInstanceID = UUID()
    private let processID = Int32(Darwin.getpid())
    private var sessionID: UUID?
    private var requests: [UUID: RequestState] = [:]

    private init() {}

    func openSession(sessionID requestedSessionID: UUID) -> NativeDecompilerLiveXPCTestReceipt? {
        condition.lock()
        defer { condition.unlock() }
        if let sessionID {
            guard sessionID == requestedSessionID else { return nil }
        } else {
            sessionID = requestedSessionID
        }
        return makeReceiptLocked()
    }

    func configureRequest(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: UUID,
        holdMode: NativeDecompilerLiveXPCTestHoldMode
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard authenticatesLocked(receipt), requests[requestID] == nil else { return false }
        requests[requestID] = RequestState(holdMode: holdMode)
        return true
    }

    /// Registers an asynchronous entered receipt without polling or occupying an XPC control call.
    func waitUntilEntered(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: UUID,
        reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    ) {
        let immediate: NativeDecompilerLiveXPCTestReceipt??
        condition.lock()
        if !authenticatesLocked(receipt) {
            immediate = .some(nil)
        } else if let request = requests[requestID] {
            if request.entered {
                immediate = .some(makeReceiptLocked())
            } else {
                request.enteredWaiters.append(EnteredWaiter(reply))
                immediate = nil
            }
        } else {
            immediate = .some(nil)
        }
        condition.unlock()

        if let immediate {
            reply(immediate)
        }
    }

    /// Registers an authenticated asynchronous receipt for an exact scheduler/reply event.
    func waitUntilEvent(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: UUID,
        event: NativeDecompilerLiveXPCTestEvent,
        reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    ) {
        let immediate: NativeDecompilerLiveXPCTestReceipt??
        condition.lock()
        if !authenticatesLocked(receipt) {
            immediate = .some(nil)
        } else if let request = requests[requestID] {
            switch event {
            case .submittedQueued:
                if let submissionWasQueued = request.submissionWasQueued {
                    immediate = .some(submissionWasQueued ? makeReceiptLocked() : nil)
                } else {
                    request.eventWaiters.append(EventWaiter(event: event, reply: reply))
                    immediate = nil
                }
            case .replyAttempted:
                if request.replyAttempted {
                    immediate = .some(makeReceiptLocked())
                } else {
                    request.eventWaiters.append(EventWaiter(event: event, reply: reply))
                    immediate = nil
                }
            }
        } else {
            immediate = .some(nil)
        }
        condition.unlock()

        if let immediate {
            reply(immediate)
        }
    }

    /// Records the exact disposition returned by the real process-global scheduler.
    func observeSubmission(requestID: UUID, isQueued: Bool) {
        let waiters: [EventWaiter]
        let eventReceipt: NativeDecompilerLiveXPCTestReceipt?

        condition.lock()
        guard let request = requests[requestID], request.submissionWasQueued == nil else {
            condition.unlock()
            return
        }
        request.submissionWasQueued = isQueued
        waiters = request.eventWaiters.filter { $0.event == .submittedQueued }
        request.eventWaiters.removeAll { $0.event == .submittedQueued }
        eventReceipt = isQueued ? makeReceiptLocked() : nil
        condition.unlock()

        for waiter in waiters {
            waiter.reply(eventReceipt)
        }
    }

    /// Records invocation of the real XPC reply block, including replies stale to the client.
    func observeReplyAttempted(requestID: UUID) {
        let waiters: [EventWaiter]
        let eventReceipt: NativeDecompilerLiveXPCTestReceipt?

        condition.lock()
        guard let request = requests[requestID], !request.replyAttempted else {
            condition.unlock()
            return
        }
        request.replyAttempted = true
        waiters = request.eventWaiters.filter { $0.event == .replyAttempted }
        request.eventWaiters.removeAll { $0.event == .replyAttempted }
        eventReceipt = makeReceiptLocked()
        condition.unlock()

        for waiter in waiters {
            waiter.reply(eventReceipt)
        }
    }

    /// Enters the barrier immediately before the real native request/provider call.
    ///
    /// Returns `false` for an unconfigured or duplicate entry so the live build fails closed rather
    /// than silently exercising an uncontrolled native request.
    func enterNativeExecution(requestID: UUID) -> Bool {
        let request: RequestState
        let waiters: [EnteredWaiter]
        let enteredReceipt: NativeDecompilerLiveXPCTestReceipt

        condition.lock()
        guard sessionID != nil,
              let configured = requests[requestID],
              !configured.entered,
              let receipt = makeReceiptLocked()
        else {
            condition.unlock()
            return false
        }
        request = configured
        request.entered = true
        waiters = request.enteredWaiters
        request.enteredWaiters.removeAll(keepingCapacity: false)
        enteredReceipt = receipt
        condition.unlock()

        for waiter in waiters {
            waiter.reply(enteredReceipt)
        }

        switch request.holdMode {
        case .normal:
            return true
        case .manual:
            condition.lock()
            while !request.released {
                condition.wait()
            }
            condition.unlock()
            return true
        case .cooperativeCancellation:
            condition.lock()
            while !request.cancellationObserved {
                condition.wait()
            }
            condition.unlock()
            return true
        case .unresponsive:
            condition.lock()
            while true {
                condition.wait()
            }
        }
    }

    /// Called from the existing request-scoped cancellation observer after the native handle has
    /// received the same cancellation signal. Only cooperative mode is allowed to wake.
    func observeCancellation(requestID: UUID) {
        condition.lock()
        defer { condition.unlock() }
        guard let request = requests[requestID],
              request.holdMode == .cooperativeCancellation
        else {
            return
        }
        request.cancellationObserved = true
        condition.broadcast()
    }

    func releaseRequest(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: UUID
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard authenticatesLocked(receipt),
              let request = requests[requestID],
              request.holdMode == .manual,
              request.entered,
              !request.released
        else {
            return false
        }
        request.released = true
        condition.broadcast()
        return true
    }

    func ping(
        receipt: NativeDecompilerLiveXPCTestReceipt
    ) -> NativeDecompilerLiveXPCTestReceipt? {
        condition.lock()
        defer { condition.unlock() }
        guard authenticatesLocked(receipt) else { return nil }
        return makeReceiptLocked()
    }

    func authorizeSelfSIGKILL(receipt: NativeDecompilerLiveXPCTestReceipt) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return authenticatesLocked(receipt) && receipt.processID == Int32(Darwin.getpid())
    }

    private func authenticatesLocked(_ receipt: NativeDecompilerLiveXPCTestReceipt) -> Bool {
        guard let sessionID else { return false }
        return receipt.sessionID as UUID == sessionID
            && receipt.processInstanceID as UUID == processInstanceID
            && receipt.processID == processID
    }

    private func makeReceiptLocked() -> NativeDecompilerLiveXPCTestReceipt? {
        guard let sessionID else { return nil }
        return NativeDecompilerLiveXPCTestReceipt(
            sessionID: sessionID as NSUUID,
            processInstanceID: processInstanceID as NSUUID,
            processID: processID
        )
    }
}
#endif
