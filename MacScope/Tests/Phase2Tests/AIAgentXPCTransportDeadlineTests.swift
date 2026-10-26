import XCTest

@testable import MacScope

#if DEBUG
// The injected transport constructor is deliberately excluded from Release products.
final class AIAgentXPCTransportDeadlineTests: XCTestCase {
    func testSilentHandshakeTimesOutAndAReplacementGenerationCanPrepare() async throws {
        let factory = TransportConnectionFactory([
            .init(mode: .silentHandshake),
            .init(mode: .ready),
        ])
        let transport = NSXPCAIAgentTransport(
            configuration: deadlineConfiguration(),
            testConnectionFactory: factory.makeConnection
        )

        await XCTAssertThrowsErrorAsync(try await transport.prepareWorkerProcessReceipt()) { error in
            XCTAssertEqual(error as? AIAgentXPCTransportError, .unavailable("AI worker handshake timed out"))
        }
        XCTAssertEqual(factory.connections[0].invalidationCount, 1)

        let receipt = try await transport.prepareWorkerProcessReceipt()
        XCTAssertEqual(receipt.processIdentifier, 4242)
        XCTAssertEqual(factory.connections[1].invalidationCount, 0)
    }

    func testMTPLXHandshakeUsesShorterEstablishmentTimeoutThanOverallGenerationDeadline() async throws {
        let connection = TransportConnection(mode: .silentHandshake)
        let configuration = try Phase2AIProviderConfiguration(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: "deadline-fixture",
            maximumTokens: 64, requestTimeoutMilliseconds: 1_000,
            resourceTimeoutMilliseconds: 5_000, inferencePolicy: .init())
        let transport = NSXPCAIAgentTransport(configuration: configuration,
            testConnectionFactory: { connection })
        let began = ContinuousClock.now
        await XCTAssertThrowsErrorAsync(try await transport.prepareWorkerProcessReceipt()) { error in
            XCTAssertEqual(error as? AIAgentXPCTransportError, .unavailable("AI worker handshake timed out"))
        }
        XCTAssertLessThan(began.duration(to: ContinuousClock.now), .seconds(2))
        XCTAssertEqual(connection.invalidationCount, 1)
    }

    func testSilentConfigurationTimesOutAndAReplacementGenerationCanPrepare() async throws {
        let factory = TransportConnectionFactory([
            .init(mode: .silentConfiguration),
            .init(mode: .ready),
        ])
        let transport = NSXPCAIAgentTransport(
            configuration: deadlineConfiguration(),
            testConnectionFactory: factory.makeConnection
        )

        await XCTAssertThrowsErrorAsync(try await transport.prepareWorkerProcessReceipt()) { error in
            XCTAssertEqual(error as? AIAgentXPCTransportError, .unavailable("AI worker configuration timed out"))
        }
        XCTAssertEqual(factory.connections[0].invalidationCount, 1)

        _ = try await transport.prepareWorkerProcessReceipt()
        XCTAssertEqual(factory.connections[1].invalidationCount, 0)
    }

    func testSilentTerminalTimesOutWithoutRetiringUnrelatedPreparedConnection() async throws {
        let connection = TransportConnection(mode: .silentFirstTerminal)
        let transport = NSXPCAIAgentTransport(
            configuration: deadlineConfiguration(),
            testConnectionFactory: { connection }
        )

        let timedOutRequestID = UUID()
        await XCTAssertThrowsErrorAsync(try await transport.run(
            requestID: timedOutRequestID,
            requestData: Data("first".utf8),
            receive: { _ in }
        )) { error in
            XCTAssertEqual(error as? AIAgentXPCTransportError, .unavailable("AI worker terminal timed out"))
        }
        XCTAssertEqual(connection.invalidationCount, 0)
        XCTAssertEqual(connection.proxy.cancelledRequestIDs, [timedOutRequestID])

        try await transport.run(
            requestID: UUID(),
            requestData: Data("second".utf8),
            receive: { _ in }
        )
        XCTAssertEqual(connection.proxy.runCallCount, 2)
    }

    func testCancellingOnePreparationWaitKeepsTheSharedConnectionAndSiblingRequestAlive()
        async throws
    {
        let connection = TransportConnection(mode: .blockedHandshake)
        let cancelledRequestID = UUID()
        let siblingRequestID = UUID()
        let cancelledRegistered = expectation(description: "cancelled waiter registered")
        let siblingRegistered = expectation(description: "sibling waiter registered")
        let transport = NSXPCAIAgentTransport(
            configuration: deadlineConfiguration(resourceTimeoutMilliseconds: 10_000),
            testConnectionFactory: { connection },
            testPreparationWaitRegistered: { requestID in
                if requestID == cancelledRequestID { cancelledRegistered.fulfill() }
                if requestID == siblingRequestID { siblingRegistered.fulfill() }
            }
        )
        let cancelled = Task {
            try await transport.run(
                requestID: cancelledRequestID,
                requestData: Data("cancelled".utf8),
                receive: { _ in }
            )
        }
        let sibling = Task {
            try await transport.run(
                requestID: siblingRequestID,
                requestData: Data("sibling".utf8),
                receive: { _ in }
            )
        }
        try await connection.proxy.waitForHandshake()
        // Task creation and the first handshake do not establish shared preparation:
        // cancellation is allowed to retire a genuinely lone waiter.
        await fulfillment(of: [cancelledRegistered, siblingRegistered], timeout: 5)

        await transport.cancel(requestID: cancelledRequestID)
        XCTAssertEqual(connection.invalidationCount, 0)
        connection.proxy.completeHandshake()

        await XCTAssertThrowsErrorAsync(try await cancelled.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        try await sibling.value
        XCTAssertEqual(connection.proxy.handshakeCallCount, 1)
        XCTAssertEqual(connection.proxy.runCallCount, 1)
        XCTAssertEqual(connection.proxy.cancelledRequestIDs, [cancelledRequestID])
    }

    func testResetSameIDRetryKeepsReplacementSinkWhenOldCleanupIsDelayed() async throws {
        let factory = TransportConnectionFactory([
            .init(mode: .silentTerminal),
            .init(mode: .silentTerminal),
        ])
        let finishGate = TransportFinishGate()
        let transport = NSXPCAIAgentTransport(
            configuration: deadlineConfiguration(),
            testConnectionFactory: factory.makeConnection,
            testBeforeRequestFinish: finishGate.blockFirstFinish
        )
        let requestID = UUID()
        let first = Task {
            try await transport.run(
                requestID: requestID,
                requestData: Data("first".utf8),
                receive: { _ in }
            )
        }
        try await factory.connections[0].proxy.waitForRunCall()

        await transport.reset()
        try await finishGate.waitUntilBlocked()
        let replacement = Task {
            try await transport.run(
                requestID: requestID,
                requestData: Data("replacement".utf8),
                receive: { _ in }
            )
        }
        try await factory.connections[1].proxy.waitForRunCall()
        finishGate.release()

        await XCTAssertThrowsErrorAsync(try await first.value) { error in
            XCTAssertEqual(error as? AIAgentXPCTransportError, .invalidated("AI worker connection reset"))
        }
        factory.connections[1].proxy.completeLastTerminal()
        try await replacement.value
        XCTAssertEqual(factory.connections[1].proxy.runCallCount, 1)
    }

    func testRepeatedUnknownAndPreRegistrationCancellationDoesNotTombstoneFutureRequest() async throws {
        let connection = TransportConnection(mode: .ready)
        let transport = NSXPCAIAgentTransport(
            configuration: deadlineConfiguration(),
            testConnectionFactory: { connection }
        )
        let requestID = UUID()

        for _ in 0..<32 {
            await transport.cancel(requestID: requestID)
            await transport.cancel(requestID: UUID())
        }

        try await transport.run(
            requestID: requestID,
            requestData: Data("request".utf8),
            receive: { _ in }
        )
        XCTAssertEqual(connection.proxy.runCallCount, 1)
        XCTAssertEqual(connection.proxy.cancelledRequestIDs.count, 0)
    }

    func testCancellationDuringLoneHandshakeResumesExactlyThatRequestAndReleasesNextGeneration() async throws {
        let factory = TransportConnectionFactory([
            .init(mode: .silentHandshake),
            .init(mode: .ready),
        ])
        let requestID = UUID()
        let waiterRegistered = expectation(description: "lone waiter registered")
        let transport = NSXPCAIAgentTransport(
            configuration: deadlineConfiguration(),
            testConnectionFactory: factory.makeConnection,
            testPreparationWaitRegistered: { registeredID in
                if registeredID == requestID { waiterRegistered.fulfill() }
            }
        )
        let operation = Task {
            try await transport.run(
                requestID: requestID,
                requestData: Data("cancelled".utf8),
                receive: { _ in }
            )
        }
        try await factory.connections[0].proxy.waitForHandshake()
        await fulfillment(of: [waiterRegistered], timeout: 5)

        await transport.cancel(requestID: requestID)
        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(factory.connections[0].invalidationCount, 1)

        try await transport.run(
            requestID: UUID(),
            requestData: Data("replacement".utf8),
            receive: { _ in }
        )
        XCTAssertEqual(factory.connections[1].proxy.runCallCount, 1)
    }
}

private func deadlineConfiguration(
    resourceTimeoutMilliseconds: Int = 1_000
) -> Phase2AIProviderConfiguration {
    try! Phase2AIProviderConfiguration(
        profileID: UUID(uuidString: "F810A2F6-9E8D-4B50-82C7-5C467B785D7F")!,
        generation: 1,
        endpointOrigin: "http://127.0.0.1:1234",
        model: "deadline-fixture",
        maximumTokens: 64,
        requestTimeoutMilliseconds: 1_000,
        resourceTimeoutMilliseconds: resourceTimeoutMilliseconds
    )
}

private final class TransportConnectionFactory: @unchecked Sendable {
    let connections: [TransportConnection]
    private let lock = NSLock()
    private var next = 0

    init(_ connections: [TransportConnection]) { self.connections = connections }

    func makeConnection() -> any AIAgentXPCConnecting {
        lock.withLock {
            let connection = connections[next]
            next += 1
            return connection
        }
    }
}

private final class TransportConnection: AIAgentXPCConnecting, @unchecked Sendable {
    let proxy: TransportProxy
    private let lock = NSLock()
    private var interruption: (@Sendable () -> Void)?
    private var invalidation: (@Sendable () -> Void)?
    private var invalidations = 0

    init(mode: TransportProxy.Mode) { proxy = .init(mode: mode) }

    var processIdentifier: Int32 { 4242 }
    var invalidationCount: Int { lock.withLock { invalidations } }

    var interruptionHandler: (@Sendable () -> Void)? {
        get { lock.withLock { interruption } }
        set { lock.withLock { interruption = newValue } }
    }

    var invalidationHandler: (@Sendable () -> Void)? {
        get { lock.withLock { invalidation } }
        set { lock.withLock { invalidation = newValue } }
    }

    func resume() {}
    func remoteProxy(errorHandler: @escaping @Sendable (Error) -> Void) -> Phase2AIWorkerXPCProtocol? {
        proxy
    }
    func invalidate() { lock.withLock { invalidations += 1 } }
}

private final class TransportProxy: NSObject, Phase2AIWorkerXPCProtocol, @unchecked Sendable {
    enum Mode {
        case silentHandshake
        case blockedHandshake
        case silentConfiguration
        case silentFirstTerminal
        case silentTerminal
        case ready
    }

    private let mode: Mode
    private let lock = NSLock()
    private var runs = 0
    private var handshakes = 0
    private var cancellations: [UUID] = []
    private var blockedHandshakeReply: ((Data) -> Void)?
    private var terminalSink: (UUID, Phase2AIWorkerEventSinkXPCProtocol)?

    init(mode: Mode) { self.mode = mode }

    var runCallCount: Int { lock.withLock { runs } }
    var handshakeCallCount: Int { lock.withLock { handshakes } }
    var cancelledRequestIDs: [UUID] { lock.withLock { cancellations } }

    func handshake(with reply: @escaping (Data) -> Void) {
        lock.withLock { handshakes += 1 }
        guard mode != .silentHandshake else { return }
        if mode == .blockedHandshake {
            lock.withLock { blockedHandshakeReply = reply }
            return
        }
        reply(try! Phase2AIWorkerWireCodec().encodeHandshake(.init(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity,
            inferenceProtocol: Phase2AIWorkerProductionProtocol.assistantR4.inferenceIdentity,
            manifestIdentity: Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
            status: .ready
        )))
    }

    func configure(configurationData: Data, with reply: @escaping (Data) -> Void) {
        guard mode != .silentConfiguration else { return }
        let configuration = try! Phase2AIWorkerConfigurationWireCodec().decodeConfiguration(configurationData)
        reply(try! Phase2AIWorkerConfigurationWireCodec().encodeAcknowledgement(.init(
            schemaVersion: Phase2AIWorkerConfigurationWireCodec.schemaVersion,
            profileID: configuration.profileID,
            generation: configuration.generation,
            protocolManifestDigest: configuration.protocolManifestDigest,
            status: .accepted
        )))
    }

    func run(requestData: Data, requestID: UUID, eventSink: Phase2AIWorkerEventSinkXPCProtocol) {
        lock.withLock { runs += 1 }
        if mode == .silentTerminal || (mode == .silentFirstTerminal && runCallCount == 1) {
            lock.withLock { terminalSink = (requestID, eventSink) }
            return
        }
        sendCompletedTerminal(requestID: requestID, sink: eventSink)
    }

    func completeHandshake() {
        let reply = lock.withLock { () -> ((Data) -> Void)? in
            defer { blockedHandshakeReply = nil }
            return blockedHandshakeReply
        }
        reply?(try! Phase2AIWorkerWireCodec().encodeHandshake(.init(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity,
            inferenceProtocol: Phase2AIWorkerProductionProtocol.assistantR4.inferenceIdentity,
            manifestIdentity: Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
            status: .ready
        )))
    }

    func completeLastTerminal() {
        let terminal = lock.withLock { () -> (UUID, Phase2AIWorkerEventSinkXPCProtocol)? in
            defer { terminalSink = nil }
            return terminalSink
        }
        guard let terminal else { return }
        sendCompletedTerminal(requestID: terminal.0, sink: terminal.1)
    }

    private func sendCompletedTerminal(
        requestID: UUID,
        sink: Phase2AIWorkerEventSinkXPCProtocol
    ) {
        sink.finish(resultData: try! Phase2AIWorkerWireCodec().encodeTerminal(.init(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion,
            phase: .finalization,
            requestID: requestID,
            status: .completed,
            reason: nil
        )))
    }

    func cancel(requestID: UUID) { lock.withLock { cancellations.append(requestID) } }

    func waitForHandshake() async throws {
        for _ in 0..<10_000 {
            if lock.withLock({
                handshakes == 1 && (mode != .blockedHandshake || blockedHandshakeReply != nil)
            }) { return }
            await Task.yield()
        }
        throw TransportProbeError.timedOut
    }

    func waitForRunCall() async throws {
        for _ in 0..<10_000 {
            if runCallCount > 0 { return }
            await Task.yield()
        }
        throw TransportProbeError.timedOut
    }

    func discoverModels(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) { reply(Data()) }
    func cancelModelDiscovery(requestID: UUID) {}
    func performModelLifecycle(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) { reply(Data()) }
    func cancelModelLifecycle(requestID: UUID) {}
}

private enum TransportProbeError: Error { case timedOut }

private final class TransportFinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var shouldBlock = true
    private var isBlocked = false

    func blockFirstFinish(_: UUID, _: UUID) {
        let blocks = lock.withLock { () -> Bool in
            guard shouldBlock else { return false }
            shouldBlock = false
            isBlocked = true
            return true
        }
        guard blocks else { return }
        releaseSemaphore.wait()
    }

    func waitUntilBlocked() async throws {
        for _ in 0..<10_000 {
            if lock.withLock({ isBlocked }) { return }
            await Task.yield()
        }
        throw TransportProbeError.timedOut
    }

    func release() { releaseSemaphore.signal() }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        handler(error)
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
