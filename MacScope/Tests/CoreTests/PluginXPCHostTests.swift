import XCTest
@testable import MacScope

/// A fake remote proxy implementing the XPC service protocol in-process so the
/// connection manager can be driven without a live `.xpc` service.
private final class FakePluginXPCService: NSObject, PluginXPCServiceProtocol {
    var handshakeReply: (version: String, capabilities: [String]) = ("1", ["workspace.read"])
    var invokeReply: (responseData: Data?, errorMessage: String?) = (Data("{}".utf8), nil)
    private(set) var invokedCommands: [(identifier: String, requestData: Data)] = []

    func handshake(
        withHostProtocolVersion hostVersion: String,
        reply: @escaping (String, [String]) -> Void
    ) {
        reply(handshakeReply.version, handshakeReply.capabilities)
    }

    func invokeCommand(
        _ commandIdentifier: String,
        requestData: Data,
        reply: @escaping (Data?, String?) -> Void
    ) {
        invokedCommands.append((commandIdentifier, requestData))
        reply(invokeReply.responseData, invokeReply.errorMessage)
    }
}

/// A fake connection recording lifecycle calls and able to synthesize
/// interruption/invalidation and proxy delivery failure.
private final class FakeXPCConnection: PluginXPCConnecting {
    enum Event: Equatable {
        case setInterface
        case setCodeSigningRequirement(String)
        case setInterruptionHandler
        case setInvalidationHandler
        case resume
        case invalidate
        case requestProxy
    }

    private(set) var events: [Event] = []
    var service: FakePluginXPCService?
    /// When set, the proxy error handler fires instead of returning a proxy.
    var proxyDeliveryError: Error?

    private var interruptionHandler: (() -> Void)?
    private var invalidationHandler: (() -> Void)?

    func setRemoteObjectInterface(_ interface: NSXPCInterface) {
        events.append(.setInterface)
    }

    func setCodeSigningRequirement(_ requirement: String) {
        events.append(.setCodeSigningRequirement(requirement))
    }

    func setInterruptionHandler(_ handler: @escaping () -> Void) {
        events.append(.setInterruptionHandler)
        interruptionHandler = handler
    }

    func setInvalidationHandler(_ handler: @escaping () -> Void) {
        events.append(.setInvalidationHandler)
        invalidationHandler = handler
    }

    func resume() {
        events.append(.resume)
    }

    func invalidate() {
        events.append(.invalidate)
        invalidationHandler?()
    }

    func remoteObjectProxy(
        withErrorHandler handler: @escaping (Error) -> Void
    ) -> Any? {
        events.append(.requestProxy)
        if let proxyDeliveryError {
            handler(proxyDeliveryError)
            return nil
        }
        return service
    }

    func fireInterruption() {
        interruptionHandler?()
    }
}

final class PluginXPCHostTests: XCTestCase {

    // MARK: Lifecycle

    func testActivateDrivesConfigureThenResume() throws {
        let connection = FakeXPCConnection()
        let host = PluginXPCHostConnection(
            serviceName: "com.example.plugin.xpc",
            connection: connection
        )
        XCTAssertEqual(host.state, .idle)

        try host.activate()

        XCTAssertEqual(host.state, .active)
        XCTAssertEqual(
            connection.events,
            [
                .setCodeSigningRequirement(PluginXPCPeerRequirement.service),
                .setInterface,
                .setInterruptionHandler,
                .setInvalidationHandler,
                .resume,
            ],
            "the peer requirement must be installed before any other configuration"
        )
    }

    func testActivateRejectsReuseAfterInvalidation() throws {
        let connection = FakeXPCConnection()
        let host = PluginXPCHostConnection(
            serviceName: "svc",
            connection: connection
        )
        try host.activate()
        host.shutdown()
        XCTAssertEqual(host.state, .invalidated)

        XCTAssertThrowsError(try host.activate()) { error in
            XCTAssertEqual(
                error as? PluginXPCHostError,
                .connectionNotActive(state: .invalidated)
            )
        }
    }

    func testInterruptionAdvancesStateAndNotifiesObserver() throws {
        let connection = FakeXPCConnection()
        let host = PluginXPCHostConnection(serviceName: "svc", connection: connection)
        var interruptionObserved = false
        host.onInterruption = { interruptionObserved = true }

        try host.activate()
        connection.fireInterruption()

        XCTAssertEqual(host.state, .interrupted)
        XCTAssertTrue(interruptionObserved)
    }

    func testInvalidationIsTerminalAndFiresOnce() throws {
        let connection = FakeXPCConnection()
        let host = PluginXPCHostConnection(serviceName: "svc", connection: connection)
        var invalidationCount = 0
        host.onInvalidation = { invalidationCount += 1 }

        try host.activate()
        host.shutdown()
        host.shutdown() // second call is a no-op

        XCTAssertEqual(host.state, .invalidated)
        XCTAssertEqual(invalidationCount, 1)
        XCTAssertEqual(connection.events.filter { $0 == .invalidate }.count, 1)
    }

    // MARK: Dispatch

    func testInvokeCommandReturnsServiceResponse() throws {
        let service = FakePluginXPCService()
        service.invokeReply = (Data("{\"ok\":true}".utf8), nil)
        let connection = FakeXPCConnection()
        connection.service = service
        let host = PluginXPCHostConnection(serviceName: "svc", connection: connection)
        try host.activate()

        let expectation = expectation(description: "reply")
        host.invokeCommand("workspace.read", requestData: Data("{}".utf8)) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(data, Data("{\"ok\":true}".utf8))
            case .failure(let error):
                XCTFail("unexpected failure: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(service.invokedCommands.first?.identifier, "workspace.read")
    }

    func testInvokeCommandSurfacesServiceError() throws {
        let service = FakePluginXPCService()
        service.invokeReply = (nil, "command failed")
        let connection = FakeXPCConnection()
        connection.service = service
        let host = PluginXPCHostConnection(serviceName: "svc", connection: connection)
        try host.activate()

        let expectation = expectation(description: "reply")
        host.invokeCommand("c", requestData: Data()) { result in
            if case .failure(let error) = result {
                XCTAssertEqual(error, .serviceReturnedError("command failed"))
            } else {
                XCTFail("expected failure")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
    }

    func testInvokeCommandSurfacesDeliveryFailure() throws {
        let connection = FakeXPCConnection()
        connection.service = FakePluginXPCService()
        connection.proxyDeliveryError = PluginXPCHostError.proxyUnavailable
        let host = PluginXPCHostConnection(serviceName: "svc", connection: connection)
        try host.activate()

        let expectation = expectation(description: "reply")
        host.invokeCommand("c", requestData: Data()) { result in
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

    func testInvokeCommandFailsWhenNotActive() {
        let connection = FakeXPCConnection()
        connection.service = FakePluginXPCService()
        let host = PluginXPCHostConnection(serviceName: "svc", connection: connection)

        var observed: PluginXPCHostError?
        host.invokeCommand("c", requestData: Data()) { result in
            if case .failure(let error) = result { observed = error }
        }
        XCTAssertEqual(observed, .connectionNotActive(state: .idle))
    }

    // MARK: Translator

    private func makeEnvelope() throws -> PluginAutomationInvocationEnvelope {
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
            service: PluginServiceMetadata(
                mode: .xpcService,
                identifier: "com.example.plugin.xpc"
            )
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
            arguments: ["query": "main"]
        )
    }

    func testTranslatorRoundTripsRequest() throws {
        let translator = PluginXPCMessageTranslator()
        let envelope = try makeEnvelope()

        let (commandIdentifier, requestData) = try translator.encodeRequest(from: envelope)
        XCTAssertEqual(commandIdentifier, "workspace.read")

        let decoded = try translator.decodeRequest(from: requestData)
        XCTAssertEqual(decoded.commandIdentifier, "workspace.read")
        XCTAssertEqual(decoded.pluginIdentifier, "com.example.plugin")
        XCTAssertEqual(decoded.manifestHash, "deadbeef")
        XCTAssertEqual(decoded.arguments["query"], "main")
        XCTAssertEqual(decoded.surface, "automation")
        XCTAssertEqual(decoded.serviceMode, "xpc-service")
    }

    func testTranslatorRoundTripsResponse() throws {
        let translator = PluginXPCMessageTranslator()
        let body = PluginXPCMessageTranslator.ResponseBody(
            requestID: UUID().uuidString,
            commandIdentifier: "workspace.read",
            payload: ["result": "ok"]
        )
        let data = try translator.encodeResponse(body)
        let decoded = try translator.decodeResponse(from: data)
        XCTAssertEqual(decoded, body)
    }

    func testTranslatorRejectsEmptyAndOversizedPayloads() {
        let translator = PluginXPCMessageTranslator()

        XCTAssertThrowsError(try translator.decodeResponse(from: Data())) { error in
            XCTAssertEqual(error as? PluginXPCTranslationError, .emptyResponse)
        }

        let big = Data(count: 16)
        XCTAssertThrowsError(
            try translator.decodeResponse(from: big, maximumBytes: 8)
        ) { error in
            XCTAssertEqual(
                error as? PluginXPCTranslationError,
                .responseTooLarge(byteCount: 16, limit: 8)
            )
        }
    }

    func testTranslatorRejectsMalformedPayload() {
        let translator = PluginXPCMessageTranslator()
        XCTAssertThrowsError(
            try translator.decodeResponse(from: Data("not json".utf8))
        ) { error in
            guard case .malformedResponse? = error as? PluginXPCTranslationError else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }
}
