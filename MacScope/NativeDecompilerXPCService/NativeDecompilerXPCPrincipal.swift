import Foundation
#if TESTING_NATIVE_DECOMPILER_SERVICE_COMPOSITION
@testable import MacScope
#endif
#if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
import Darwin
#endif

/// Objective-C exported object for one accepted native-decompiler XPC connection.
final class NativeDecompilerXPCPrincipal: NSObject, NativeDecompilerXPCProtocol,
    @unchecked Sendable
{
    private let host: NativeDecompilerServiceHost
    private let requests = NativeDecompilerXPCPrincipalRequestRegistry()

    init(host: NativeDecompilerServiceHost) {
        self.host = host
        super.init()
    }

    deinit {
        invalidateConnection()
    }

    func decompile(
        requestID: NSUUID,
        payload: NSData,
        withReply reply: @escaping (NSData) -> Void
    ) {
        let swiftRequestID = requestID as UUID
        let replySender = NativeDecompilerXPCReplySender(reply)
        switch requests.begin(requestID: swiftRequestID) {
        case .accepted:
            break
        case .duplicate:
            replySender.send(
                NativeDecompilerServiceFailureReplyEncoder.encode(
                    requestID: swiftRequestID,
                    failure: .invalidRequest
                ) as NSData
            )
            return
        case .invalidated:
            replySender.send(
                NativeDecompilerServiceFailureReplyEncoder.encode(
                    requestID: swiftRequestID,
                    failure: .unavailable
                ) as NSData
            )
            return
        }
        let requests = requests
        host.decompile(
            requestID: swiftRequestID,
            payload: payload as Data
        ) { data in
            requests.finish(requestID: swiftRequestID)
            replySender.send(data as NSData)
            #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
            NativeDecompilerLiveXPCTestControl.shared.observeReplyAttempted(
                requestID: swiftRequestID
            )
            #endif
        }
    }

    func cancel(requestID: NSUUID) {
        let requestID = requestID as UUID
        guard requests.claimCancellation(requestID: requestID) else { return }
        host.cancel(requestID: requestID)
    }

    /// Retires this connection's request authority and cooperatively cancels only work submitted
    /// through this principal. The request registry arbitrates concurrent reply, cancel, and
    /// invalidation paths so each request reaches the shared host's cancellation seam at most once.
    func invalidateConnection() {
        for requestID in requests.invalidate() {
            host.cancel(requestID: requestID)
        }
    }
}

private final class NativeDecompilerXPCPrincipalRequestRegistry: @unchecked Sendable {
    enum BeginDisposition {
        case accepted
        case duplicate
        case invalidated
    }

    private struct RequestState {
        var cancellationClaimed = false
    }

    private let lock = NSLock()
    private var requestStates: [UUID: RequestState] = [:]
    private var isInvalidated = false

    func begin(requestID: UUID) -> BeginDisposition {
        lock.withLock {
            guard !isInvalidated else { return .invalidated }
            guard requestStates[requestID] == nil else { return .duplicate }
            requestStates[requestID] = RequestState()
            return .accepted
        }
    }

    func finish(requestID: UUID) {
        _ = lock.withLock { requestStates.removeValue(forKey: requestID) }
    }

    func claimCancellation(requestID: UUID) -> Bool {
        lock.withLock {
            guard var state = requestStates[requestID], !state.cancellationClaimed else {
                return false
            }
            state.cancellationClaimed = true
            requestStates[requestID] = state
            return true
        }
    }

    func invalidate() -> [UUID] {
        lock.withLock {
            guard !isInvalidated else { return [] }
            isInvalidated = true
            var requestIDs: [UUID] = []
            for (requestID, var state) in requestStates where !state.cancellationClaimed {
                state.cancellationClaimed = true
                requestStates[requestID] = state
                requestIDs.append(requestID)
            }
            return requestIDs
        }
    }
}

#if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
extension NativeDecompilerXPCPrincipal: NativeDecompilerLiveXPCTestProtocol {
    func openLiveTestSession(
        sessionID: NSUUID,
        withReply reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    ) {
        reply(NativeDecompilerLiveXPCTestControl.shared.openSession(sessionID: sessionID as UUID))
    }

    func configureLiveTestRequest(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: NSUUID,
        holdMode: Int,
        withReply reply: @escaping (Bool) -> Void
    ) {
        guard let mode = NativeDecompilerLiveXPCTestHoldMode(rawValue: holdMode) else {
            reply(false)
            return
        }
        reply(
            NativeDecompilerLiveXPCTestControl.shared.configureRequest(
                receipt: receipt,
                requestID: requestID as UUID,
                holdMode: mode
            )
        )
    }

    func waitUntilLiveTestRequestEntered(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: NSUUID,
        withReply reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    ) {
        NativeDecompilerLiveXPCTestControl.shared.waitUntilEntered(
            receipt: receipt,
            requestID: requestID as UUID,
            reply: reply
        )
    }

    func waitUntilLiveTestRequestEvent(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: NSUUID,
        event: Int,
        withReply reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    ) {
        guard let event = NativeDecompilerLiveXPCTestEvent(rawValue: event) else {
            reply(nil)
            return
        }
        NativeDecompilerLiveXPCTestControl.shared.waitUntilEvent(
            receipt: receipt,
            requestID: requestID as UUID,
            event: event,
            reply: reply
        )
    }

    func releaseLiveTestRequest(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        requestID: NSUUID,
        withReply reply: @escaping (Bool) -> Void
    ) {
        reply(
            NativeDecompilerLiveXPCTestControl.shared.releaseRequest(
                receipt: receipt,
                requestID: requestID as UUID
            )
        )
    }

    func pingLiveTestSession(
        receipt: NativeDecompilerLiveXPCTestReceipt,
        withReply reply: @escaping (NativeDecompilerLiveXPCTestReceipt?) -> Void
    ) {
        reply(NativeDecompilerLiveXPCTestControl.shared.ping(receipt: receipt))
    }

    func selfSIGKILLLiveTestService(receipt: NativeDecompilerLiveXPCTestReceipt) {
        guard NativeDecompilerLiveXPCTestControl.shared.authorizeSelfSIGKILL(receipt: receipt) else {
            return
        }
        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
    }
}
#endif

/// Foundation reply blocks are safe to invoke asynchronously but cannot express Swift's
/// `@Sendable` contract. This wrapper makes that single crossing explicit.
private final class NativeDecompilerXPCReplySender: @unchecked Sendable {
    private let reply: (NSData) -> Void

    init(_ reply: @escaping (NSData) -> Void) {
        self.reply = reply
    }

    func send(_ data: NSData) {
        reply(data)
    }
}
