import Foundation

/// The Objective-C-visible protocol an out-of-process plugin XPC service vends.
///
/// This is the wire contract between MacScope (the host) and a bundled `.xpc`
/// service. It must be `@objc` so `NSXPCInterface(with:)` can reflect over it.
/// All parameters and return values are property-list / NSSecureCoding types so
/// they cross the XPC boundary; the host translates its rich Swift envelopes
/// to/from these primitive shapes in `PluginXPCMessageTranslator`.
@objc protocol PluginXPCServiceProtocol {
    /// Handshake: the host asks the service for its advertised protocol version
    /// and capability identifiers. Lets the host reject a service whose protocol
    /// drifted from the manifest.
    func handshake(
        withHostProtocolVersion hostVersion: String,
        reply: @escaping (_ serviceProtocolVersion: String, _ capabilities: [String]) -> Void
    )

    /// Dispatch a single automation command invocation. `requestData` is the
    /// JSON-encoded request envelope; the service replies with JSON response
    /// data or an error message (exactly one is non-nil).
    func invokeCommand(
        _ commandIdentifier: String,
        requestData: Data,
        reply: @escaping (_ responseData: Data?, _ errorMessage: String?) -> Void
    )
}

/// Abstraction over `NSXPCConnection` so the connection manager's lifecycle
/// logic is unit-testable with a fake. The real adapter forwards to a live
/// `NSXPCConnection`; the fake records the lifecycle calls and can synthesize
/// interruption / invalidation.
protocol PluginXPCConnecting: AnyObject {
    /// Sets the remote object interface (`NSXPCConnection.remoteObjectInterface`).
    func setRemoteObjectInterface(_ interface: NSXPCInterface)
    /// Installs the peer code-signing requirement (`NSXPCConnection.setCodeSigningRequirement`).
    func setCodeSigningRequirement(_ requirement: String)
    /// Installs the interruption handler (called when the service crashes).
    func setInterruptionHandler(_ handler: @escaping () -> Void)
    /// Installs the invalidation handler (called when the connection is torn down).
    func setInvalidationHandler(_ handler: @escaping () -> Void)
    /// Activates the connection (`NSXPCConnection.resume()`).
    func resume()
    /// Tears the connection down (`NSXPCConnection.invalidate()`).
    func invalidate()
    /// Returns the remote proxy, configured with an error handler that fires when
    /// a message cannot be delivered.
    func remoteObjectProxy(
        withErrorHandler handler: @escaping (Error) -> Void
    ) -> Any?
}

/// The lifecycle phase of a managed plugin XPC connection. The connection
/// manager is a small explicit state machine so we can assert the exact
/// transition order under test (the audit's "stdio-only, no real host" finding).
enum PluginXPCConnectionState: Equatable {
    case idle
    case configured
    case active
    case interrupted
    case invalidated
}

/// Errors surfaced by the XPC host connection manager.
enum PluginXPCHostError: Error, Equatable, LocalizedError {
    case connectionNotActive(state: PluginXPCConnectionState)
    case proxyUnavailable
    case messageDeliveryFailed(String)
    case serviceReturnedError(String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .connectionNotActive(let state):
            "Plugin XPC connection is not active (state: \(state))."
        case .proxyUnavailable:
            "Plugin XPC connection did not vend a remote proxy."
        case .messageDeliveryFailed(let message):
            "Plugin XPC message could not be delivered: \(message)."
        case .serviceReturnedError(let message):
            "Plugin XPC service returned an error: \(message)."
        case .emptyReply:
            "Plugin XPC service returned neither a response nor an error."
        }
    }
}

/// Manages the `NSXPCConnection` lifecycle for one plugin service: create the
/// connection, set the interface, resume, handle interruption/invalidation, and
/// invalidate. The Security boundary and the actual connection are injected via
/// `PluginXPCConnecting`, so the state machine is exercised by a fake.
///
/// This is the host-side replacement for / augmentation of the stdio host. The
/// bundled `.xpc` service target (the build-system-heavy part) still has to be
/// produced separately — see `integrationRisks` in the task report.
final class PluginXPCHostConnection {
    private(set) var state: PluginXPCConnectionState = .idle

    let serviceName: String
    let interface: NSXPCInterface
    private let connection: PluginXPCConnecting

    /// Called when the underlying connection is interrupted (service crashed but
    /// the connection object is still usable) — observers may attempt a reconnect.
    var onInterruption: (() -> Void)?
    /// Called when the connection is invalidated (terminal: it can never be used
    /// again and must be recreated).
    var onInvalidation: (() -> Void)?

    init(
        serviceName: String,
        connection: PluginXPCConnecting,
        interface: NSXPCInterface = NSXPCInterface(with: PluginXPCServiceProtocol.self)
    ) {
        self.serviceName = serviceName
        self.connection = connection
        self.interface = interface
    }

    /// Drives create→configure→resume. Sets the remote interface, installs the
    /// interruption/invalidation handlers that advance the state machine, and
    /// resumes the connection. Idempotent transitions are rejected: activating an
    /// already-invalidated connection throws.
    func activate() throws {
        guard state == .idle else {
            // A connection object is single-use; re-activation after a terminal
            // state must go through a freshly-created connection.
            throw PluginXPCHostError.connectionNotActive(state: state)
        }

        // Peer authentication before any configuration the service could observe:
        // the host accepts replies only from the signed plugin service.
        connection.setCodeSigningRequirement(PluginXPCPeerRequirement.service)
        connection.setRemoteObjectInterface(interface)
        connection.setInterruptionHandler { [weak self] in
            self?.handleInterruption()
        }
        connection.setInvalidationHandler { [weak self] in
            self?.handleInvalidation()
        }
        state = .configured

        connection.resume()
        state = .active
    }

    /// Dispatch a command through the live proxy. Translates the proxy's
    /// reply (responseData | errorMessage) into a `Result`. Errors in delivery
    /// (proxy error handler) are surfaced as `.messageDeliveryFailed`.
    func invokeCommand(
        _ commandIdentifier: String,
        requestData: Data,
        completion: @escaping (Result<Data, PluginXPCHostError>) -> Void
    ) {
        guard state == .active else {
            completion(.failure(.connectionNotActive(state: state)))
            return
        }

        var deliveryFailed = false
        let proxy = connection.remoteObjectProxy { error in
            deliveryFailed = true
            completion(.failure(.messageDeliveryFailed(error.localizedDescription)))
        }

        // If the proxy error handler already fired synchronously (e.g. the
        // connection could not vend a proxy), it has reported the failure; do not
        // report a second completion.
        if deliveryFailed {
            return
        }

        guard let service = proxy as? PluginXPCServiceProtocol else {
            completion(.failure(.proxyUnavailable))
            return
        }

        service.invokeCommand(commandIdentifier, requestData: requestData) { responseData, errorMessage in
            if deliveryFailed {
                // The proxy error handler already reported the failure.
                return
            }
            if let errorMessage {
                completion(.failure(.serviceReturnedError(errorMessage)))
                return
            }
            guard let responseData else {
                completion(.failure(.emptyReply))
                return
            }
            completion(.success(responseData))
        }
    }

    /// Vend the live remote proxy for the active connection, configured with the
    /// supplied delivery-error handler. Returns `nil` if there is no active
    /// connection. Exposed so higher-level routers (e.g. the handshake path) can
    /// issue proxy calls other than `invokeCommand` through the same injected
    /// transport, without reaching into the connection's private state.
    func remoteProxy(
        withErrorHandler handler: @escaping (Error) -> Void
    ) -> Any? {
        guard state == .active else { return nil }
        return connection.remoteObjectProxy(withErrorHandler: handler)
    }

    /// Terminate the connection. Safe to call multiple times; only the first
    /// transition to `.invalidated` fires `onInvalidation`.
    func shutdown() {
        guard state != .invalidated else { return }
        connection.invalidate()
        // The fake/real invalidation handler advances the state; if the handler
        // is not wired (defensive), advance here too.
        if state != .invalidated {
            handleInvalidation()
        }
    }

    private func handleInterruption() {
        // Interruption is recoverable: the connection object stays alive. We only
        // record the interrupted state if we were active.
        if state == .active {
            state = .interrupted
        }
        onInterruption?()
    }

    private func handleInvalidation() {
        state = .invalidated
        onInvalidation?()
    }
}

/// Live adapter forwarding `PluginXPCConnecting` to a real `NSXPCConnection`.
/// Untested by unit tests (touches the live runtime); the state machine that
/// uses it is fully covered via the fake.
final class LiveNSXPCConnectionAdapter: PluginXPCConnecting {
    private let connection: NSXPCConnection

    init(serviceName: String) {
        self.connection = NSXPCConnection(serviceName: serviceName)
    }

    func setRemoteObjectInterface(_ interface: NSXPCInterface) {
        connection.remoteObjectInterface = interface
    }

    func setCodeSigningRequirement(_ requirement: String) {
        connection.setCodeSigningRequirement(requirement)
    }

    func setInterruptionHandler(_ handler: @escaping () -> Void) {
        connection.interruptionHandler = handler
    }

    func setInvalidationHandler(_ handler: @escaping () -> Void) {
        connection.invalidationHandler = handler
    }

    func resume() {
        connection.resume()
    }

    func invalidate() {
        connection.invalidate()
    }

    func remoteObjectProxy(
        withErrorHandler handler: @escaping (Error) -> Void
    ) -> Any? {
        connection.remoteObjectProxyWithErrorHandler(handler)
    }
}
