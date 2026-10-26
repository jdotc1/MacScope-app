import Foundation

/// The protocol version the bundled service advertises in its handshake. The host
/// sends its own version in `handshake(withHostProtocolVersion:)`; the service
/// echoes the version it speaks so a drifted service can be rejected by the host.
/// Kept in lock-step with `PluginServiceMetadata.protocolVersion`'s default.
enum PluginXPCServiceProtocolVersion {
    static let current = "1"
}

/// The pure, connection-free plugin logic that the far-side principal runs behind
/// the XPC protocol. The bundled `.xpc` service injects a concrete handler that
/// drives the real plugin; tests inject a fake. This is the seam that makes the
/// service's message handling unit-testable without a live `NSXPCConnection`.
///
/// A handler receives the already-decoded, already-validated request body (the
/// exact shape `PluginXPCMessageTranslator` produces on the host) and returns the
/// response body the host will decode. Throwing surfaces as a structured error
/// over the wire (the reply's `errorMessage`), never a crash.
protocol PluginXPCServiceCommandHandling: AnyObject {
    /// The protocol version this handler implements. Defaults to the current
    /// service protocol version.
    var protocolVersion: String { get }

    /// The capability identifiers this handler can service (e.g. `"workspace.read"`).
    /// Returned to the host during the handshake so it can reconcile against the
    /// manifest's declared capabilities.
    var capabilities: [String] { get }

    /// Run one command. `request` is fully decoded and size-validated. Return the
    /// response body to encode, or throw to report a structured failure.
    func handle(
        _ request: PluginXPCMessageTranslator.RequestBody
    ) throws -> PluginXPCMessageTranslator.ResponseBody
}

extension PluginXPCServiceCommandHandling {
    var protocolVersion: String { PluginXPCServiceProtocolVersion.current }
}

/// The default plugin logic the bundled service vends until a real plugin is
/// loaded into the service process. It echoes the request back as a structured
/// response so an end-to-end smoke test of the live bundle has a deterministic
/// reply. A real deployment swaps this for a handler that drives the loaded
/// plugin's command implementation. Lives in the shared `Plugins/` module so both
/// the unit tests and the bundled service can use it.
final class EchoPluginXPCServiceHandler: PluginXPCServiceCommandHandling {
    var capabilities: [String]

    init(capabilities: [String] = [PluginCapability.workspaceRead.rawValue]) {
        self.capabilities = capabilities
    }

    func handle(
        _ request: PluginXPCMessageTranslator.RequestBody
    ) throws -> PluginXPCMessageTranslator.ResponseBody {
        var payload: [String: String] = [
            "plugin": request.pluginIdentifier,
            "command": request.commandIdentifier,
            "surface": request.surface
        ]
        for (key, value) in request.arguments {
            payload["arg.\(key)"] = value
        }
        return PluginXPCMessageTranslator.ResponseBody(
            requestID: request.requestID,
            commandIdentifier: request.commandIdentifier,
            payload: payload
        )
    }
}

/// Errors the far-side principal raises while validating an inbound request, before
/// it ever reaches the plugin handler. These map to the reply's `errorMessage` so a
/// hostile or buggy host cannot drive the service into undefined behavior.
enum PluginXPCServiceError: Error, Equatable, LocalizedError {
    /// The `commandIdentifier` on the XPC method did not match the one inside the
    /// decoded request body — a sign of a corrupted or spoofed message.
    case commandIdentifierMismatch(method: String, body: String)
    /// The handler does not advertise the capability this command requires.
    case unsupportedCommand(String)
    /// The decoded request failed translator validation (empty / oversized / malformed).
    case malformedRequest(String)

    var errorDescription: String? {
        switch self {
        case .commandIdentifierMismatch(let method, let body):
            "Plugin XPC request command identifier \(body) does not match the invoked method \(method)."
        case .unsupportedCommand(let identifier):
            "Plugin XPC service does not handle command \(identifier)."
        case .malformedRequest(let message):
            "Plugin XPC service rejected a malformed request: \(message)"
        }
    }
}

/// The in-service principal object: the far side of `PluginXPCServiceProtocol`.
///
/// It is the object a bundled `.xpc` service sets as its connection's
/// `exportedObject`. It owns no connection state — it is a pure message handler:
/// decode → validate → dispatch to the injected `PluginXPCServiceCommandHandling`
/// → encode → reply. Because every dependency (the handler, the translator, the
/// size limit) is injected, the whole request/reply behavior is driven directly in
/// tests with the same message types the host's translator produces, with no live
/// XPC at all.
///
/// Subclasses `NSObject` so it satisfies the `@objc` `PluginXPCServiceProtocol`
/// and can be vended as an `NSXPCConnection.exportedObject`.
final class PluginXPCServicePrincipal: NSObject, PluginXPCServiceProtocol {
    private let handler: PluginXPCServiceCommandHandling
    private let translator: PluginXPCMessageTranslator
    /// The maximum inbound request size accepted before JSON decoding. Mirrors the
    /// host-side response cap so neither direction can force unbounded work.
    private let maximumRequestBytes: Int

    init(
        handler: PluginXPCServiceCommandHandling,
        translator: PluginXPCMessageTranslator = PluginXPCMessageTranslator(),
        maximumRequestBytes: Int = 1_048_576
    ) {
        self.handler = handler
        self.translator = translator
        self.maximumRequestBytes = maximumRequestBytes
    }

    // MARK: PluginXPCServiceProtocol

    func handshake(
        withHostProtocolVersion hostVersion: String,
        reply: @escaping (String, [String]) -> Void
    ) {
        // The host decides whether to accept the version drift; the service simply
        // reports the version it speaks and the capabilities it can service.
        reply(handler.protocolVersion, handler.capabilities)
    }

    func invokeCommand(
        _ commandIdentifier: String,
        requestData: Data,
        reply: @escaping (Data?, String?) -> Void
    ) {
        switch makeResponseData(commandIdentifier: commandIdentifier, requestData: requestData) {
        case .success(let data):
            reply(data, nil)
        case .failure(let error):
            // Exactly one of (responseData, errorMessage) is non-nil, matching the
            // host's expectation in `PluginXPCHostConnection.invokeCommand`.
            reply(nil, error.localizedDescription)
        }
    }

    // MARK: Pure handling core

    /// The pure, synchronous core of `invokeCommand`. Extracted so tests can assert
    /// the produced bytes / error directly, and so `invokeCommand` is a thin
    /// reply-shaping wrapper. Never throws or crashes: every failure becomes a
    /// `.failure` carrying a human-readable message.
    func makeResponseData(
        commandIdentifier: String,
        requestData: Data
    ) -> Result<Data, Error> {
        let request: PluginXPCMessageTranslator.RequestBody
        do {
            request = try translator.decodeRequest(
                from: requestData,
                maximumBytes: maximumRequestBytes
            )
        } catch let error as PluginXPCTranslationError {
            return .failure(PluginXPCServiceError.malformedRequest(
                error.errorDescription ?? String(describing: error)
            ))
        } catch {
            return .failure(PluginXPCServiceError.malformedRequest(String(describing: error)))
        }

        // The command identifier travels both on the XPC method and inside the body.
        // They must agree; a mismatch means a corrupted or spoofed envelope.
        guard request.commandIdentifier == commandIdentifier else {
            return .failure(PluginXPCServiceError.commandIdentifierMismatch(
                method: commandIdentifier,
                body: request.commandIdentifier
            ))
        }

        let response: PluginXPCMessageTranslator.ResponseBody
        do {
            response = try handler.handle(request)
        } catch {
            return .failure(error)
        }

        do {
            let data = try translator.encodeResponse(response)
            return .success(data)
        } catch {
            return .failure(PluginXPCServiceError.malformedRequest(String(describing: error)))
        }
    }
}
