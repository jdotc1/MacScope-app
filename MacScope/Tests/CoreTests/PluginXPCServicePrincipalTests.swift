import XCTest
@testable import MacScope

/// A configurable in-service handler driven directly in tests — the same seam the
/// bundled `.xpc` service injects. Records what it received and returns / throws on
/// command.
private final class StubPluginXPCServiceHandler: PluginXPCServiceCommandHandling {
    var capabilities: [String]
    var versionToReport: String
    var responder: (PluginXPCMessageTranslator.RequestBody) throws -> PluginXPCMessageTranslator.ResponseBody
    private(set) var received: [PluginXPCMessageTranslator.RequestBody] = []

    init(
        capabilities: [String] = ["workspace.read"],
        versionToReport: String = PluginXPCServiceProtocolVersion.current,
        responder: @escaping (PluginXPCMessageTranslator.RequestBody) throws -> PluginXPCMessageTranslator.ResponseBody
    ) {
        self.capabilities = capabilities
        self.versionToReport = versionToReport
        self.responder = responder
    }

    var protocolVersion: String { versionToReport }

    func handle(
        _ request: PluginXPCMessageTranslator.RequestBody
    ) throws -> PluginXPCMessageTranslator.ResponseBody {
        received.append(request)
        return try responder(request)
    }
}

/// An error a stub handler can throw to assert structured error propagation.
private struct StubHandlerError: LocalizedError {
    var errorDescription: String? { "stub handler refused the command" }
}

final class PluginXPCServicePrincipalTests: XCTestCase {

    private let translator = PluginXPCMessageTranslator()

    private func makeRequestData(
        requestID: String = UUID().uuidString,
        pluginIdentifier: String = "com.example.plugin",
        commandIdentifier: String = "workspace.read",
        surface: String = "automation",
        serviceMode: String = "xpc-service",
        manifestHash: String? = "deadbeef",
        arguments: [String: String] = ["query": "main"]
    ) throws -> Data {
        let body = PluginXPCMessageTranslator.RequestBody(
            requestID: requestID,
            pluginIdentifier: pluginIdentifier,
            commandIdentifier: commandIdentifier,
            surface: surface,
            serviceMode: serviceMode,
            manifestHash: manifestHash,
            arguments: arguments
        )
        return try PluginXPCMessageTranslator.makeEncoder().encode(body)
    }

    // MARK: Handshake

    func testHandshakeReportsHandlerVersionAndCapabilities() {
        let handler = StubPluginXPCServiceHandler(
            capabilities: ["workspace.read", "analysis.symbols"],
            versionToReport: "1"
        ) { req in
            PluginXPCMessageTranslator.ResponseBody(
                requestID: req.requestID,
                commandIdentifier: req.commandIdentifier,
                payload: [:]
            )
        }
        let principal = PluginXPCServicePrincipal(handler: handler)

        var observed: (version: String, caps: [String])?
        principal.handshake(withHostProtocolVersion: "1") { version, caps in
            observed = (version, caps)
        }
        XCTAssertEqual(observed?.version, "1")
        XCTAssertEqual(observed?.caps, ["workspace.read", "analysis.symbols"])
    }

    // MARK: invokeCommand — happy path

    func testInvokeCommandDispatchesToHandlerAndEncodesReply() throws {
        let handler = StubPluginXPCServiceHandler { req in
            PluginXPCMessageTranslator.ResponseBody(
                requestID: req.requestID,
                commandIdentifier: req.commandIdentifier,
                payload: ["echo": req.arguments["query"] ?? ""]
            )
        }
        let principal = PluginXPCServicePrincipal(handler: handler)
        let data = try makeRequestData(arguments: ["query": "symbols"])

        var reply: (data: Data?, error: String?)?
        principal.invokeCommand("workspace.read", requestData: data) { responseData, errorMessage in
            reply = (responseData, errorMessage)
        }

        XCTAssertNil(reply?.error)
        let decoded = try translator.decodeResponse(from: XCTUnwrap(reply?.data))
        XCTAssertEqual(decoded.commandIdentifier, "workspace.read")
        XCTAssertEqual(decoded.payload["echo"], "symbols")
        XCTAssertEqual(handler.received.count, 1)
        XCTAssertEqual(handler.received.first?.pluginIdentifier, "com.example.plugin")
    }

    func testMakeResponseDataIsPureCoreUsableWithoutReplyClosure() throws {
        let handler = StubPluginXPCServiceHandler { req in
            PluginXPCMessageTranslator.ResponseBody(
                requestID: req.requestID,
                commandIdentifier: req.commandIdentifier,
                payload: ["ok": "true"]
            )
        }
        let principal = PluginXPCServicePrincipal(handler: handler)
        let data = try makeRequestData()

        let result = principal.makeResponseData(commandIdentifier: "workspace.read", requestData: data)
        switch result {
        case .success(let out):
            let decoded = try translator.decodeResponse(from: out)
            XCTAssertEqual(decoded.payload["ok"], "true")
        case .failure(let error):
            XCTFail("unexpected failure: \(error)")
        }
    }

    // MARK: invokeCommand — error / hardening paths

    func testHandlerThrownErrorBecomesErrorMessageReply() throws {
        let handler = StubPluginXPCServiceHandler { _ in throw StubHandlerError() }
        let principal = PluginXPCServicePrincipal(handler: handler)
        let data = try makeRequestData()

        var reply: (data: Data?, error: String?)?
        principal.invokeCommand("workspace.read", requestData: data) { d, e in reply = (d, e) }

        XCTAssertNil(reply?.data)
        XCTAssertEqual(reply?.error, "stub handler refused the command")
    }

    func testCommandIdentifierMismatchIsRejected() throws {
        let handler = StubPluginXPCServiceHandler { req in
            PluginXPCMessageTranslator.ResponseBody(
                requestID: req.requestID,
                commandIdentifier: req.commandIdentifier,
                payload: [:]
            )
        }
        let principal = PluginXPCServicePrincipal(handler: handler)
        // Body says workspace.read; the method says something else.
        let data = try makeRequestData(commandIdentifier: "workspace.read")

        let result = principal.makeResponseData(commandIdentifier: "workspace.write", requestData: data)
        guard case .failure(let error) = result else {
            return XCTFail("expected mismatch failure")
        }
        XCTAssertEqual(
            error as? PluginXPCServiceError,
            .commandIdentifierMismatch(method: "workspace.write", body: "workspace.read")
        )
        XCTAssertTrue(handler.received.isEmpty, "handler must not run on a mismatched request")
    }

    func testMalformedRequestIsRejectedBeforeHandler() throws {
        let handler = StubPluginXPCServiceHandler { req in
            PluginXPCMessageTranslator.ResponseBody(
                requestID: req.requestID,
                commandIdentifier: req.commandIdentifier,
                payload: [:]
            )
        }
        let principal = PluginXPCServicePrincipal(handler: handler)

        let result = principal.makeResponseData(
            commandIdentifier: "workspace.read",
            requestData: Data("not json".utf8)
        )
        guard case .failure(let error) = result else {
            return XCTFail("expected malformed failure")
        }
        guard case .malformedRequest? = error as? PluginXPCServiceError else {
            return XCTFail("expected malformedRequest, got \(error)")
        }
        XCTAssertTrue(handler.received.isEmpty)
    }

    func testEmptyRequestIsRejected() {
        let handler = StubPluginXPCServiceHandler { req in
            PluginXPCMessageTranslator.ResponseBody(requestID: req.requestID, commandIdentifier: req.commandIdentifier, payload: [:])
        }
        let principal = PluginXPCServicePrincipal(handler: handler)

        let result = principal.makeResponseData(commandIdentifier: "c", requestData: Data())
        guard case .failure(let error) = result,
              case .malformedRequest? = error as? PluginXPCServiceError else {
            return XCTFail("expected malformedRequest for empty data")
        }
    }

    func testOversizedRequestIsRejectedBeforeDecoding() throws {
        let handler = StubPluginXPCServiceHandler { req in
            PluginXPCMessageTranslator.ResponseBody(requestID: req.requestID, commandIdentifier: req.commandIdentifier, payload: [:])
        }
        // A tiny cap so a normal request trips the size guard.
        let principal = PluginXPCServicePrincipal(handler: handler, maximumRequestBytes: 8)
        let data = try makeRequestData()
        XCTAssertGreaterThan(data.count, 8)

        let result = principal.makeResponseData(commandIdentifier: "workspace.read", requestData: data)
        guard case .failure(let error) = result,
              case .malformedRequest? = error as? PluginXPCServiceError else {
            return XCTFail("expected malformedRequest for oversized data")
        }
        XCTAssertTrue(handler.received.isEmpty)
    }

    // MARK: Default echo handler (the bundled-service default logic)

    func testEchoHandlerEchoesRequestShape() throws {
        let handler = EchoPluginXPCServiceHandler()
        let request = PluginXPCMessageTranslator.RequestBody(
            requestID: "R1",
            pluginIdentifier: "com.example.plugin",
            commandIdentifier: "workspace.read",
            surface: "automation",
            serviceMode: "xpc-service",
            manifestHash: nil,
            arguments: ["query": "main"]
        )
        let response = try handler.handle(request)
        XCTAssertEqual(response.requestID, "R1")
        XCTAssertEqual(response.commandIdentifier, "workspace.read")
        XCTAssertEqual(response.payload["plugin"], "com.example.plugin")
        XCTAssertEqual(response.payload["surface"], "automation")
        XCTAssertEqual(response.payload["arg.query"], "main")
    }
}
