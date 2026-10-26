@preconcurrency import Foundation

enum NativeDecompilerXPCConnectionEvent: Equatable, Sendable {
    case interrupted
    case invalidated
    case connectionFailure
}

/// Foundation reports both a normal remote-process exit and a crash through the same
/// `interruptionHandler`; it exposes no authenticated termination reason to this client. Keep the
/// production mapping honest instead of fabricating a distinct crash category.
enum NativeDecompilerXPCFoundationLifecycleClassifier {
    static var remoteProcessTermination: NativeDecompilerXPCConnectionEvent { .interrupted }
    static var permanentInvalidation: NativeDecompilerXPCConnectionEvent { .invalidated }
}

/// Maps only Foundation's documented XPC lifecycle errors to lifecycle categories. An arbitrary
/// proxy error is not evidence that the service crashed, so unknown values stay conservative.
enum NativeDecompilerXPCProxyErrorClassifier {
    static func classify(_ error: Error) -> NativeDecompilerXPCConnectionEvent {
        let error = error as NSError
        guard error.domain == NSCocoaErrorDomain else { return .connectionFailure }
        switch error.code {
        case NSXPCConnectionInterrupted:
            return .interrupted
        case NSXPCConnectionInvalid:
            return .invalidated
        default:
            return .connectionFailure
        }
    }
}

/// Foundation-only connection seam used by the supervised client. The client owns generation,
/// request correlation, timeout, and exactly-once completion; implementations only transport
/// opaque property-list bytes and lifecycle events.
protocol NativeDecompilerXPCConnecting: AnyObject, Sendable {
    func setEventHandler(
        _ handler: @escaping @Sendable (NativeDecompilerXPCConnectionEvent) -> Void
    )
    /// Must be idempotent. The client may call this before each first-generation dispatch so a
    /// synchronous lifecycle callback never needs to re-enter the client's state lock.
    func resume()
    func decompile(
        requestID: UUID,
        payload: Data,
        reply: @escaping @Sendable (Data) -> Void
    )
    func cancel(requestID: UUID)
    func invalidate()
}

@objc private protocol NativeDecompilerXPCRemoteCalling {
    func decompile(
        requestID: NSUUID,
        payload: NSData,
        withReply reply: @escaping (NSData) -> Void
    )
    func cancel(requestID: NSUUID)
}

/// Narrow live adapter. Its Objective-C protocol intentionally mirrors only the two frozen
/// Foundation selectors; no wire model, native object, path, or NSError crosses this boundary.
final class NativeDecompilerFoundationXPCConnection: NativeDecompilerXPCConnecting,
    @unchecked Sendable
{
    static let serviceName = "org.macscope.app.NativeDecompiler"

    private let lock = NSLock()
    private let admissionGate = NativeDecompilerXPCClientAdmissionGate()
    private let connection: NSXPCConnection
    private var eventHandler: (@Sendable (NativeDecompilerXPCConnectionEvent) -> Void)?

    init(serviceName: String = NativeDecompilerFoundationXPCConnection.serviceName) {
        connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(
            with: NativeDecompilerXPCRemoteCalling.self
        )
        admissionGate.installRequirement { [connection] requirement in
            connection.setCodeSigningRequirement(requirement)
        }
        connection.interruptionHandler = { [weak self] in
            self?.emit(NativeDecompilerXPCFoundationLifecycleClassifier.remoteProcessTermination)
        }
        connection.invalidationHandler = { [weak self] in
            self?.emit(NativeDecompilerXPCFoundationLifecycleClassifier.permanentInvalidation)
        }
    }

    deinit {
        connection.invalidate()
    }

    func setEventHandler(
        _ handler: @escaping @Sendable (NativeDecompilerXPCConnectionEvent) -> Void
    ) {
        lock.withLock { eventHandler = handler }
    }

    func resume() {
        admissionGate.resume { [connection] in
            connection.resume()
        }
    }

    func decompile(
        requestID: UUID,
        payload: Data,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.emitProxyError(error)
        }) as? NativeDecompilerXPCRemoteCalling else {
            emit(.connectionFailure)
            return
        }
        remote.decompile(
            requestID: requestID as NSUUID,
            payload: payload as NSData
        ) { data in
            reply(data as Data)
        }
    }

    func cancel(requestID: UUID) {
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.emitProxyError(error)
        }) as? NativeDecompilerXPCRemoteCalling else {
            emit(.connectionFailure)
            return
        }
        remote.cancel(requestID: requestID as NSUUID)
    }

    func invalidate() {
        connection.invalidate()
    }

    private func emit(_ event: NativeDecompilerXPCConnectionEvent) {
        let handler = lock.withLock { eventHandler }
        handler?(event)
    }

    private func emitProxyError(_ error: Error) {
        emit(NativeDecompilerXPCProxyErrorClassifier.classify(error))
    }
}
