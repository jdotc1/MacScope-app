import XCTest

@testable import MacScope

final class Phase2AIAgentXPCModelLifecycleTransportTests: XCTestCase {
    func testStalledHandshakeTimesOutBeforeDispatchAndFreshRetrySurvivesLateCallbacks()
        async throws
    {
        let factory = LifecycleTransportConnectionFactoryProbe()
        let deadlines = LifecycleHandshakeDeadlineProbe()
        defer { deadlines.releaseAll() }
        let transport = NSXPCAIWorkerModelLifecycleTransport(
            handshakeTimeoutNanoseconds: 123,
            waitForHandshakeDeadline: { await deadlines.wait(nanoseconds: $0) },
            makeConnection: { factory.makeConnection() }
        )

        let firstFinished = expectation(description: "stalled handshake finishes")
        let firstCompletion = LifecycleTransportCompletionProbe()
        let first = Task {
            defer {
                firstCompletion.finish()
                firstFinished.fulfill()
            }
            return try await transport.perform(requestData: Data("stalled".utf8), requestID: UUID())
        }
        defer { first.cancel() }
        let firstConnection = try await factory.waitForConnection(at: 0)
        try await firstConnection.proxy.waitForHandshake()
        let retiredInterruption = firstConnection.interruptionHandler
        let retiredInvalidation = firstConnection.invalidationHandler
        let retiredProxyFailure = firstConnection.proxyErrorHandler
        try await deadlines.waitForRegistration(count: 1)
        XCTAssertEqual(deadlines.registeredTimeouts, [123])
        deadlines.release(at: 0)

        await fulfillment(of: [firstFinished], timeout: 2)
        XCTAssertTrue(firstCompletion.didFinish)
        XCTAssertEqual(firstConnection.proxy.lifecycleCallCount, 0)
        XCTAssertEqual(firstConnection.invalidationCount, 1)
        // Assert production retirement before any cleanup. On the passing path the retry
        // below must obtain a fresh connection without a reset supplied by this test.
        guard firstCompletion.didFinish, firstConnection.invalidationCount == 1 else {
            await transport.reset()
            return
        }
        await XCTAssertThrowsErrorAsync(try await first.value) { error in
            XCTAssertEqual(
                error as? Phase2AIWorkerModelLifecycleTransportError,
                .unavailableBeforeDispatch
            )
        }

        let secondFinished = expectation(description: "fresh retry finishes")
        let secondCompletion = LifecycleTransportCompletionProbe()
        let second = Task {
            defer {
                secondCompletion.finish()
                secondFinished.fulfill()
            }
            return try await transport.perform(requestData: Data("retry".utf8), requestID: UUID())
        }
        defer { second.cancel() }
        let secondConnection = try await factory.waitForConnection(at: 1)
        try await secondConnection.proxy.waitForHandshake()
        try await deadlines.waitForRegistration(count: 2)
        firstConnection.proxy.completeHandshake()
        retiredInterruption?()
        retiredInvalidation?()
        retiredProxyFailure?(LifecycleTransportProbeFailure.timedOut)
        XCTAssertEqual(secondConnection.invalidationCount, 0)

        secondConnection.proxy.completeHandshake()
        try await secondConnection.proxy.waitForLifecycleCall()
        // The manual waiter intentionally ignores cancellation until released.
        // A completed handshake must cancel its deadline even if the waiter
        // later returns while the model lifecycle operation is still pending.
        deadlines.release(at: 1)
        try await deadlines.waitForCompletion(at: 1)
        XCTAssertEqual(deadlines.wasCancelled(at: 1), true)
        XCTAssertEqual(secondConnection.invalidationCount, 0)
        secondConnection.proxy.completeLifecycle(with: Data("retry-reply".utf8))
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertTrue(secondCompletion.didFinish)
        XCTAssertEqual(secondConnection.invalidationCount, 1)
        guard secondCompletion.didFinish, secondConnection.invalidationCount == 1 else {
            await transport.reset()
            return
        }
        let secondReply = try await second.value
        XCTAssertEqual(secondReply, Data("retry-reply".utf8))
        XCTAssertEqual(factory.connectionCount, 2)
    }

    func testDriftedHandshakeFailsBeforeLifecycleDispatch() async throws {
        let connection = LifecycleTransportConnectionProbe(autoLifecycleReply: Data("reply".utf8))
        let transport = NSXPCAIWorkerModelLifecycleTransport(makeConnection: { connection })
        let operation = Task {
            try await transport.perform(requestData: Data("request".utf8), requestID: UUID())
        }
        try await connection.proxy.waitForHandshake()

        connection.proxy.completeHandshake(
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR1
        )

        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertEqual(
                error as? Phase2AIWorkerModelLifecycleTransportError,
                .unavailableBeforeDispatch
            )
        }
        XCTAssertEqual(connection.proxy.lifecycleCallCount, 0)
        XCTAssertEqual(connection.invalidationCount, 1)
    }

    func testExplicitCancellationDuringHandshakeIsCancelledBeforeDispatch() async throws {
        let connection = LifecycleTransportConnectionProbe()
        let transport = NSXPCAIWorkerModelLifecycleTransport(makeConnection: { connection })
        let requestID = UUID()

        let operation = Task {
            try await transport.perform(requestData: Data("request".utf8), requestID: requestID)
        }
        try await connection.proxy.waitForHandshake()

        await transport.cancel(requestID: requestID)

        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertEqual(
                error as? Phase2AIWorkerModelLifecycleTransportError,
                .cancelledBeforeDispatch
            )
        }
        XCTAssertEqual(connection.proxy.lifecycleCallCount, 0)
        XCTAssertEqual(connection.invalidationCount, 1)
    }

    func testExplicitCancellationAfterSelectorDispatchRequiresReconciliation() async throws {
        let connection = LifecycleTransportConnectionProbe()
        let transport = NSXPCAIWorkerModelLifecycleTransport(makeConnection: { connection })
        let requestID = UUID()
        let operation = Task {
            try await transport.perform(requestData: Data("request".utf8), requestID: requestID)
        }

        try await connection.proxy.waitForHandshake()
        connection.proxy.completeHandshake()
        try await connection.proxy.waitForLifecycleCall()
        await transport.cancel(requestID: requestID)

        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertEqual(
                error as? Phase2AIWorkerModelLifecycleTransportError,
                .reconciliationRequired
            )
        }
        XCTAssertEqual(connection.proxy.cancelledRequestIDs, [requestID])
        XCTAssertEqual(connection.invalidationCount, 1)

        connection.proxy.completeLifecycle(with: Data("late".utf8))
        await Task.yield()
        XCTAssertEqual(connection.invalidationCount, 1)
    }

    func testInterruptionAfterSelectorDispatchRequiresReconciliationAndSuppressesLateReply()
        async throws
    {
        let connection = LifecycleTransportConnectionProbe()
        let transport = NSXPCAIWorkerModelLifecycleTransport(makeConnection: { connection })
        let requestID = UUID()
        let operation = Task {
            try await transport.perform(requestData: Data("request".utf8), requestID: requestID)
        }

        try await connection.proxy.waitForHandshake()
        connection.proxy.completeHandshake()
        try await connection.proxy.waitForLifecycleCall()
        connection.interrupt()

        await XCTAssertThrowsErrorAsync(try await operation.value) { error in
            XCTAssertEqual(
                error as? Phase2AIWorkerModelLifecycleTransportError,
                .reconciliationRequired
            )
        }
        connection.proxy.completeLifecycle(with: Data("late".utf8))
        await Task.yield()
        XCTAssertEqual(connection.invalidationCount, 1)
    }

    func testTerminalReplyInvalidatesOneShotConnectionAndNextOperationUsesFreshConnection()
        async throws
    {
        let factory = LifecycleTransportConnectionFactoryProbe()
        let transport = NSXPCAIWorkerModelLifecycleTransport(
            makeConnection: { factory.makeConnection() }
        )

        let first = Task {
            try await transport.perform(requestData: Data("first".utf8), requestID: UUID())
        }
        let firstConnection = try await factory.waitForConnection(at: 0)
        try await firstConnection.proxy.waitForHandshake()
        firstConnection.proxy.completeHandshake()
        try await firstConnection.proxy.waitForLifecycleCall()
        firstConnection.proxy.completeLifecycle(with: Data("first-reply".utf8))
        let firstReply = try await first.value
        XCTAssertEqual(firstReply, Data("first-reply".utf8))
        XCTAssertEqual(firstConnection.invalidationCount, 1)

        let second = Task {
            try await transport.perform(requestData: Data("second".utf8), requestID: UUID())
        }
        let secondConnection = try await factory.waitForConnection(at: 1)
        try await secondConnection.proxy.waitForHandshake()
        secondConnection.proxy.completeHandshake()
        try await secondConnection.proxy.waitForLifecycleCall()
        secondConnection.proxy.completeLifecycle(with: Data("second-reply".utf8))
        let secondReply = try await second.value
        XCTAssertEqual(secondReply, Data("second-reply".utf8))

        XCTAssertFalse(firstConnection === secondConnection)
        XCTAssertEqual(factory.connectionCount, 2)
        XCTAssertEqual(firstConnection.proxy.lifecycleCallCount, 1)
        XCTAssertEqual(secondConnection.proxy.lifecycleCallCount, 1)
        XCTAssertEqual(secondConnection.invalidationCount, 1)
    }
}

private final class LifecycleTransportCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var didFinish: Bool { lock.withLock { finished } }

    func finish() {
        lock.withLock { finished = true }
    }
}

private final class LifecycleHandshakeDeadlineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [UInt64] = []
    private var continuations: [Int: CheckedContinuation<Int, Never>] = [:]
    private var cancellations: [Int: Bool] = [:]
    private var closed = false

    var registeredTimeouts: [UInt64] { lock.withLock { timeouts } }

    func wait(nanoseconds: UInt64) async {
        let index = await withCheckedContinuation { continuation in
            let releaseImmediately = lock.withLock { () -> Int? in
                let index = timeouts.count
                timeouts.append(nanoseconds)
                guard !closed else { return index }
                continuations[index] = continuation
                return nil
            }
            if let index = releaseImmediately { continuation.resume(returning: index) }
        }
        lock.withLock { cancellations[index] = Task.isCancelled }
    }

    func release(at index: Int) {
        let continuation = lock.withLock { continuations.removeValue(forKey: index) }
        continuation?.resume(returning: index)
    }

    func releaseAll() {
        let remaining = lock.withLock {
            closed = true
            let remaining = continuations
            continuations.removeAll()
            return remaining
        }
        for (index, continuation) in remaining { continuation.resume(returning: index) }
    }

    func wasCancelled(at index: Int) -> Bool? { lock.withLock { cancellations[index] } }

    func waitForRegistration(count: Int) async throws {
        try await waitUntil { self.lock.withLock { self.timeouts.count >= count } }
    }

    func waitForCompletion(at index: Int) async throws {
        try await waitUntil { self.wasCancelled(at: index) != nil }
    }
}

private final class LifecycleTransportConnectionFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [LifecycleTransportConnectionProbe] = []

    var connectionCount: Int { lock.withLock { connections.count } }

    func makeConnection() -> any Phase2AIWorkerModelLifecycleXPCConnection {
        let connection = LifecycleTransportConnectionProbe()
        lock.withLock { connections.append(connection) }
        return connection
    }

    func waitForConnection(at index: Int) async throws -> LifecycleTransportConnectionProbe {
        for _ in 0..<10_000 {
            if let connection = lock.withLock({ connections.indices.contains(index)
                ? connections[index]
                : nil
            }) {
                return connection
            }
            await Task.yield()
        }
        throw LifecycleTransportProbeFailure.timedOut
    }
}

private final class LifecycleTransportConnectionProbe:
    Phase2AIWorkerModelLifecycleXPCConnection, @unchecked Sendable
{
    let proxy: LifecycleTransportProxyProbe

    private let lock = NSLock()
    private var storedInterruptionHandler: (@Sendable () -> Void)?
    private var storedInvalidationHandler: (@Sendable () -> Void)?
    private var storedProxyErrorHandler: (@Sendable (Error) -> Void)?
    private var invalidations = 0

    init(autoLifecycleReply: Data? = nil) {
        proxy = LifecycleTransportProxyProbe(autoLifecycleReply: autoLifecycleReply)
    }

    var interruptionHandler: (@Sendable () -> Void)? {
        get { lock.withLock { storedInterruptionHandler } }
        set { lock.withLock { storedInterruptionHandler = newValue } }
    }

    var invalidationHandler: (@Sendable () -> Void)? {
        get { lock.withLock { storedInvalidationHandler } }
        set { lock.withLock { storedInvalidationHandler = newValue } }
    }

    var invalidationCount: Int { lock.withLock { invalidations } }
    var proxyErrorHandler: (@Sendable (Error) -> Void)? {
        lock.withLock { storedProxyErrorHandler }
    }

    func resume() {}

    func remoteObjectProxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> Phase2AIWorkerXPCProtocol? {
        lock.withLock { storedProxyErrorHandler = errorHandler }
        return proxy
    }

    func invalidate() {
        lock.withLock { invalidations += 1 }
    }

    func interrupt() {
        interruptionHandler?()
    }
}

private final class LifecycleTransportProxyProbe: NSObject, Phase2AIWorkerXPCProtocol,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let autoLifecycleReply: Data?
    private var handshakeReply: ((Data) -> Void)?
    private var lifecycleReply: ((Data) -> Void)?
    private var handshakeCalls = 0
    private var lifecycleCalls = 0
    private var cancellations: [UUID] = []

    var lifecycleCallCount: Int { lock.withLock { lifecycleCalls } }
    var cancelledRequestIDs: [UUID] { lock.withLock { cancellations } }

    init(autoLifecycleReply: Data? = nil) {
        self.autoLifecycleReply = autoLifecycleReply
    }

    func handshake(with reply: @escaping (Data) -> Void) {
        lock.withLock {
            handshakeCalls += 1
            handshakeReply = reply
        }
    }

    func completeHandshake(
        protocolBundle: Phase2AIWorkerProductionProtocolBundle =
            Phase2AIWorkerProductionProtocol.assistantR4
    ) {
        let data = try! Phase2AIWorkerWireCodec().encodeHandshake(
            .init(
                wireProtocol: protocolBundle.wireIdentity,
                inferenceProtocol: protocolBundle.inferenceIdentity,
                manifestIdentity: protocolBundle.manifestIdentity,
                status: .ready
            )
        )
        lock.withLock { handshakeReply }?(data)
    }

    func performModelLifecycle(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    ) {
        lock.withLock {
            lifecycleCalls += 1
            lifecycleReply = reply
        }
        if let autoLifecycleReply { reply(autoLifecycleReply) }
    }

    func completeLifecycle(with data: Data) {
        lock.withLock { lifecycleReply }?(data)
    }

    func cancelModelLifecycle(requestID: UUID) {
        lock.withLock { cancellations.append(requestID) }
    }

    func waitForHandshake() async throws {
        try await waitUntil { self.lock.withLock { self.handshakeCalls == 1 } }
    }

    func waitForLifecycleCall() async throws {
        try await waitUntil { self.lock.withLock { self.lifecycleCalls == 1 } }
    }

    func configure(configurationData: Data, with reply: @escaping (Data) -> Void) { reply(Data()) }
    func discoverModels(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) {
        reply(Data())
    }
    func cancelModelDiscovery(requestID: UUID) {}
    func run(
        requestData: Data,
        requestID: UUID,
        eventSink: Phase2AIWorkerEventSinkXPCProtocol
    ) {}
    func cancel(requestID: UUID) {}
}

private enum LifecycleTransportProbeFailure: Error {
    case timedOut
}

private func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<10_000 {
        if predicate() { return }
        await Task.yield()
    }
    throw LifecycleTransportProbeFailure.timedOut
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
