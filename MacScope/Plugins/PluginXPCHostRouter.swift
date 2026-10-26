import Foundation

/// High-level host-side driver that wires the low-level `PluginXPCHostConnection`
/// state machine to the `PluginXPCMessageTranslator` so callers work in terms of
/// rich automation envelopes, not raw `(commandIdentifier, Data)` pairs.
///
/// Responsibilities:
///   * activate / shut down the underlying connection;
///   * perform the handshake and surface the service's protocol version + caps;
///   * encode an automation envelope, dispatch it through the connection, and
///     decode the reply into a typed `ResponseBody` (rejecting empty / oversized /
///     malformed replies via the translator's hardening).
///
/// The connection it drives is injected (`PluginXPCConnecting`), so a full
/// host→principal round trip is exercised in tests with an in-process fake
/// transport that vends a `PluginXPCServicePrincipal` as its remote object — no
/// live `.xpc` service required.
final class PluginXPCHostRouter {
    let connection: PluginXPCHostConnection
    private let translator: PluginXPCMessageTranslator
    /// The protocol version the host advertises to the service during the handshake.
    let hostProtocolVersion: String

    init(
        serviceName: String,
        connection: PluginXPCConnecting,
        translator: PluginXPCMessageTranslator = PluginXPCMessageTranslator(),
        hostProtocolVersion: String = PluginXPCServiceProtocolVersion.current
    ) {
        self.connection = PluginXPCHostConnection(
            serviceName: serviceName,
            connection: connection
        )
        self.translator = translator
        self.hostProtocolVersion = hostProtocolVersion
    }

    var state: PluginXPCConnectionState { connection.state }

    /// Activate the underlying connection (configure → resume). Throws if the
    /// connection has already been used (terminal state).
    func activate() throws {
        try connection.activate()
    }

    /// Tear the connection down. Safe to call multiple times.
    func shutdown() {
        connection.shutdown()
    }

    /// Result of a handshake: the protocol version the service speaks and the
    /// capability identifiers it can service.
    struct HandshakeResult: Equatable {
        var serviceProtocolVersion: String
        var capabilities: [String]
    }

    /// Perform the handshake with the service. The host's own protocol version is
    /// sent; the service's reply is returned for the caller to reconcile against
    /// the manifest. Surfaces connection-level failures through the completion.
    func performHandshake(
        completion: @escaping (Result<HandshakeResult, PluginXPCHostError>) -> Void
    ) {
        guard state == .active else {
            completion(.failure(.connectionNotActive(state: state)))
            return
        }

        var deliveryFailed = false
        let proxy = connection.remoteProxy { error in
            deliveryFailed = true
            completion(.failure(.messageDeliveryFailed(error.localizedDescription)))
        }
        if deliveryFailed { return }

        guard let service = proxy as? PluginXPCServiceProtocol else {
            completion(.failure(.proxyUnavailable))
            return
        }

        service.handshake(withHostProtocolVersion: hostProtocolVersion) { version, capabilities in
            if deliveryFailed { return }
            completion(.success(HandshakeResult(
                serviceProtocolVersion: version,
                capabilities: capabilities
            )))
        }
    }

    /// Push the host theme to a plugin that declared `PluginThemeSnapshot.capability` in its
    /// handshake. Call after the handshake and again on every theme, appearance or contrast
    /// change. A plugin's reply body is ignored; delivery failures are reported.
    func pushTheme(
        _ snapshot: PluginThemeSnapshot,
        serviceCapabilities: [String],
        completion: @escaping (Result<Void, PluginXPCHostError>) -> Void
    ) {
        guard serviceCapabilities.contains(PluginThemeSnapshot.capability) else {
            completion(.success(()))
            return
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(snapshot)
        } catch {
            completion(.failure(.messageDeliveryFailed(String(describing: error))))
            return
        }
        connection.invokeCommand(PluginThemeSnapshot.commandIdentifier, requestData: data) { result in
            completion(result.map { _ in () })
        }
    }

    /// Encode an automation envelope, dispatch it through the connection, and
    /// decode the service's reply into a typed `ResponseBody`. This is the full
    /// host-side round trip: envelope → wire → principal → wire → response.
    func dispatch(
        _ envelope: PluginAutomationInvocationEnvelope,
        completion: @escaping (Result<PluginXPCMessageTranslator.ResponseBody, PluginXPCHostError>) -> Void
    ) {
        let request: (commandIdentifier: String, requestData: Data)
        do {
            request = try translator.encodeRequest(from: envelope)
        } catch {
            completion(.failure(.messageDeliveryFailed(String(describing: error))))
            return
        }

        connection.invokeCommand(
            request.commandIdentifier,
            requestData: request.requestData
        ) { [translator] result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                do {
                    let body = try translator.decodeResponse(from: data)
                    completion(.success(body))
                } catch {
                    // A reply that decodes to nothing usable is an empty-reply-class
                    // failure from the host's point of view.
                    completion(.failure(.serviceReturnedError(String(describing: error))))
                }
            }
        }
    }
}
