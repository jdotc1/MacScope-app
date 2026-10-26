import XCTest
@testable import MacScope

/// An in-process fake transport that vends a real `PluginXPCServicePrincipal` as
/// its remote object. This wires the full host path (router → connection →
/// principal) end to end with no live `NSXPCConnection`: the host's encoded bytes
/// are handed straight to the principal's `invokeCommand`, and the principal's
/// reply bytes flow back through the host's decoder.
private final class InProcessPrincipalConnection: PluginXPCConnecting {
    let principal: PluginXPCServiceProtocol
    var proxyDeliveryError: Error?

    private var interruptionHandler: (() -> Void)?
    private var invalidationHandler: (() -> Void)?

    init(principal: PluginXPCServiceProtocol) {
        self.principal = principal
    }

    func setRemoteObjectInterface(_ interface: NSXPCInterface) {}
    func setCodeSigningRequirement(_ requirement: String) {}
    func setInterruptionHandler(_ handler: @escaping () -> Void) { interruptionHandler = handler }
    func setInvalidationHandler(_ handler: @escaping () -> Void) { invalidationHandler = handler }
    func resume() {}
    func invalidate() { invalidationHandler?() }

    func remoteObjectProxy(
        withErrorHandler handler: @escaping (Error) -> Void
    ) -> Any? {
        if let proxyDeliveryError {
            handler(proxyDeliveryError)
            return nil
        }
        return principal
    }
}

/// A handler that records and echoes, used to prove the request crossed the full
/// host→principal boundary intact.
private final class RecordingHandler: PluginXPCServiceCommandHandling {
    var capabilities: [String] = ["workspace.read"]
    private(set) var received: [PluginXPCMessageTranslator.RequestBody] = []

    func handle(
        _ request: PluginXPCMessageTranslator.RequestBody
    ) throws -> PluginXPCMessageTranslator.ResponseBody {
        received.append(request)
        return PluginXPCMessageTranslator.ResponseBody(
            requestID: request.requestID,
            commandIdentifier: request.commandIdentifier,
            payload: ["echoedQuery": request.arguments["query"] ?? "<none>"]
        )
    }
}

final class PluginXPCHostRouterTests: XCTestCase {

    private func makeEnvelope(
        arguments: [String: String] = ["query": "main"]
    ) throws -> PluginAutomationInvocationEnvelope {
        let manifest = PluginManifest(
            identifier: "com.example.plugin",
            displayName: "Example",
            version: "1.0.0",
            sdkVersion: "0.1",
            minHostVersion: "0.1.0",
            execution: .xpc,
            entryPoint: "Example.xpc",
            principalClass: nil,
            architectures: ["arm64"],
            capabilities: [.workspaceRead],
            permissions: .restricted,
            provenance: PluginProvenance(
                distribution: .bundled,
                signatureState: .signed,
                teamIdentifier: "TEAM12345",
                signingIdentifier: "sign.id",
                source: "bundle"
            ),
            commands: [
                PluginCommandDescriptor(
                    identifier: "workspace.read",
                    displayName: "Read",
                    capability: .workspaceRead,
                    surfaces: [.automation]
                )
            ],
            service: PluginServiceMetadata(mode: .xpcService, identifier: "com.example.plugin.xpc")
        )
        let descriptor = try PluginRegistry().validate(
            manifest,
            trustDecision: .allowExternal,
            manifestHash: "deadbeef"
        )
        let planner = PluginAutomationFacadePlanner(
            policy: PluginRuntimePolicy(
                allowDevelopmentPlugins: true,
                requireSignedPlugins: false,
                allowNetworkAccess: true,
                allowProcessSpawn: true
            )
        )
        return try planner.invocationEnvelope(
            for: descriptor,
            commandIdentifier: "workspace.read",
            surface: .automation,
            arguments: arguments
        )
    }

    func testFullRoundTripHostToPrincipal() throws {
        let handler = RecordingHandler()
        let principal = PluginXPCServicePrincipal(handler: handler)
        let connection = InProcessPrincipalConnection(principal: principal)
        let router = PluginXPCHostRouter(serviceName: "com.example.plugin.xpc", connection: connection)
        try router.activate()
        XCTAssertEqual(router.state, .active)

        let envelope = try makeEnvelope(arguments: ["query": "symbols"])
        let expectation = expectation(description: "round trip")
        router.dispatch(envelope) { result in
            switch result {
            case .success(let body):
                XCTAssertEqual(body.commandIdentifier, "workspace.read")
                XCTAssertEqual(body.payload["echoedQuery"], "symbols")
            case .failure(let error):
                XCTFail("unexpected failure: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(handler.received.count, 1)
        XCTAssertEqual(handler.received.first?.pluginIdentifier, "com.example.plugin")
        XCTAssertEqual(handler.received.first?.manifestHash, "deadbeef")
    }

    func testHandshakeRoundTrip() throws {
        let handler = RecordingHandler()
        handler.capabilities = ["workspace.read", "analysis.symbols"]
        let principal = PluginXPCServicePrincipal(handler: handler)
        let connection = InProcessPrincipalConnection(principal: principal)
        let router = PluginXPCHostRouter(serviceName: "svc", connection: connection)
        try router.activate()

        let expectation = expectation(description: "handshake")
        router.performHandshake { result in
            switch result {
            case .success(let handshake):
                XCTAssertEqual(handshake.serviceProtocolVersion, PluginXPCServiceProtocolVersion.current)
                XCTAssertEqual(handshake.capabilities, ["workspace.read", "analysis.symbols"])
            case .failure(let error):
                XCTFail("unexpected failure: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testDispatchSurfacesHandlerErrorAsServiceError() throws {
        // A principal whose handler rejects everything: the host must see a
        // serviceReturnedError, not a crash or empty reply.
        final class RejectingHandler: PluginXPCServiceCommandHandling {
            var capabilities: [String] = []
            struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
            func handle(_ request: PluginXPCMessageTranslator.RequestBody) throws -> PluginXPCMessageTranslator.ResponseBody {
                throw Boom()
            }
        }
        let principal = PluginXPCServicePrincipal(handler: RejectingHandler())
        let connection = InProcessPrincipalConnection(principal: principal)
        let router = PluginXPCHostRouter(serviceName: "svc", connection: connection)
        try router.activate()

        let envelope = try makeEnvelope()
        let expectation = expectation(description: "error")
        router.dispatch(envelope) { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error, .serviceReturnedError("boom"))
            } else {
                XCTFail("expected failure")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testDispatchFailsWhenConnectionNotActive() throws {
        let principal = PluginXPCServicePrincipal(handler: RecordingHandler())
        let connection = InProcessPrincipalConnection(principal: principal)
        let router = PluginXPCHostRouter(serviceName: "svc", connection: connection)
        // Not activated.

        let envelope = try makeEnvelope()
        var observed: PluginXPCHostError?
        router.dispatch(envelope) { result in
            if case .failure(let error) = result { observed = error }
        }
        XCTAssertEqual(observed, .connectionNotActive(state: .idle))
    }

    func testHandshakeSurfacesDeliveryFailure() throws {
        let principal = PluginXPCServicePrincipal(handler: RecordingHandler())
        let connection = InProcessPrincipalConnection(principal: principal)
        connection.proxyDeliveryError = PluginXPCHostError.proxyUnavailable
        let router = PluginXPCHostRouter(serviceName: "svc", connection: connection)
        try router.activate()

        let expectation = expectation(description: "delivery failure")
        router.performHandshake { result in
            if case .failure(let error) = result {
                if case .messageDeliveryFailed = error {
                    // expected
                } else {
                    XCTFail("expected messageDeliveryFailed, got \(error)")
                }
            } else {
                XCTFail("expected failure")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }
}
