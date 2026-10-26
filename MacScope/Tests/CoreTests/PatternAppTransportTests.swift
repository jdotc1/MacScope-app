import Foundation
import XCTest
@testable import MacScope

// Rebased lifecycle assertions use the retained worker-owned child controller.
// Injected operations are inert; no worker, XPC session or native fixture is launched.
final class PatternAppTransportTests: XCTestCase {
    func testDeadlinePositive() throws {
        let f = PatternOwnedChildFixture()
        let identity = try f.start()
        f.controller.acceptHandshake(identity)
        f.controller.nativeReturned(identity, payload: Data([42]))
        f.clock.fire(0)
        f.controller.nativeReturned(identity, payload: Data([43]))
        XCTAssertEqual(f.events.successes, [Data([42])])
        XCTAssertTrue(f.events.failures.isEmpty)
        XCTAssertFalse(f.controller.admissionAvailable, "Return is not reap")
    }
    func testDeadlineNegative() throws {
        let f = PatternOwnedChildFixture()
        let identity = try f.start()
        f.controller.acceptHandshake(identity)
        f.clock.fire(0)
        f.controller.nativeReturned(identity, payload: Data([42]))
        XCTAssertEqual(f.events.failures, [.timedOut])
        XCTAssertTrue(f.events.successes.isEmpty)
        XCTAssertFalse(f.controller.admissionAvailable)
        XCTAssertThrowsError(try f.start())
        f.ops.waitResults = [.terminal(pid: identity.processID, rawStatus: 0, termination: .exited(code: 0))]
        f.clock.fire(2)
        XCTAssertTrue(f.controller.admissionAvailable)
        let replacement = try f.start()
        XCTAssertNotEqual(replacement.spawnNonce, identity.spawnNonce)
        XCTAssertEqual(f.events.failures, [.timedOut])
    }
    func testSupervisorPositive() throws {
        let f = PatternOwnedChildFixture()
        let identity = try f.start()
        XCTAssertEqual(identity.channel, .pattern)
        XCTAssertEqual(f.ops.commands, ["initialize"])
        f.controller.acceptHandshake(identity)
        f.controller.acceptHandshake(identity)
        XCTAssertEqual(f.ops.commands, ["initialize", "execute"])
        XCTAssertEqual(f.ops.commandIdentities, [identity, identity])
    }
    @MainActor
    func testSupervisorNegative() throws {
        XCTAssertFalse(UnavailablePatternAppTransport().available)
        XCTAssertFalse(UnavailablePatternInterpretationTransport().patternAvailable)
        let f = PatternOwnedChildFixture()
        let identity = try f.start()
        f.controller.acceptHandshake(identity)
        f.clock.fire(0)
        f.clock.fire(3)
        XCTAssertEqual(f.ops.signalled, [identity])
        XCTAssertFalse(f.controller.admissionAvailable)
        XCTAssertThrowsError(try f.start())
        XCTAssertEqual(f.ops.launches.count, 1)
        XCTAssertEqual(f.events.releases, 0)
    }
    @MainActor
    func testSupervisedTerminalAdmits() throws {
        let app = PatternAppTestFixture()
        let capture = try app.begin()
        let payload = try JSONEncoder().encode(PatternAppTestFixture.reply(capture.request))
        let f = PatternOwnedChildFixture()
        let identity = try f.controller.start(key: .init(channel: .pattern,
            requestID: capture.request.requestID, connectionGeneration: UUID()), payload: Data([1]),
            policy: .init(timeoutMS: 100, abortGraceMS: 25, cleanupGraceMS: 20,
                          maximumRequestBytes: 16, maximumReplyBytes: 4_194_304)).get()
        f.controller.acceptHandshake(identity)
        f.controller.nativeReturned(identity, payload: payload)
        f.controller.nativeReturned(identity, payload: payload)
        XCTAssertEqual(f.events.successes, [payload])
        let admitted = try XCTUnwrap(f.events.successes.first)
        app.owner.accept(data: admitted, requestID: identity.requestID, generation: app.owner.generation)
        XCTAssertEqual(app.nodes.count, 1)
        XCTAssertFalse(f.controller.admissionAvailable)
    }
    func testReplacementTerminalRejected() throws {
        let f = PatternOwnedChildFixture()
        let identity = try f.start()
        f.controller.acceptHandshake(identity)
        let replacement = f.changed(identity, nonce: UUID())
        f.controller.nativeReturned(replacement, payload: Data([42]))
        XCTAssertTrue(f.events.successes.isEmpty)
        XCTAssertEqual(f.controller.phase, .running)
        XCTAssertFalse(f.controller.admissionAvailable)
        f.controller.rejectProtocol(identity)
        f.clock.fire(0)
        XCTAssertEqual(f.events.failures, [.protocolFailure])
        XCTAssertEqual(f.events.releases, 0)
        XCTAssertFalse(f.controller.admissionAvailable)
    }
    @MainActor
    func testCapturedCancelIdentity() async throws {
        let capturedChannel = PatternChannelTestDouble()
        var currentChannel = capturedChannel
        let facade = PatternAppChannelTransport(channel: currentChannel)
        let requestID = UUID()
        let payload = Data([1, 2, 3])
        let reply = try await facade.send(requestID: requestID, payload: payload)
        XCTAssertEqual(reply, payload)
        currentChannel = PatternChannelTestDouble()
        facade.cancel(requestID: requestID)
        XCTAssertEqual(capturedChannel.cancellations, [requestID])
        XCTAssertTrue(currentChannel.cancellations.isEmpty)
        XCTAssertEqual(capturedChannel.requests, [requestID])
        do {
            _ = try await facade.send(requestID: UUID(), payload: Data(count: 2_097_153))
            XCTFail("Oversized input must be refused before channel dispatch")
        } catch PatternInterpretationError.invalidRequest {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(capturedChannel.requests, [requestID])
        let f = PatternOwnedChildFixture()
        let identity = try f.start()
        f.controller.acceptHandshake(identity)
        let reconnected = f.changed(identity, generation: UUID())
        f.controller.cancel(reconnected)
        XCTAssertEqual(f.ops.commands, ["initialize", "execute"])
        f.controller.cancel(identity)
        XCTAssertEqual(f.ops.commands.last, "abort")
        XCTAssertEqual(f.ops.commandIdentities.last, identity)
        XCTAssertEqual(f.events.failures, [.cancelled])
        XCTAssertFalse(f.controller.admissionAvailable)
        XCTAssertEqual(f.events.releases, 0)
    }
    func testDeliveryErrorIsNotReturn() throws {
        let f = PatternOwnedChildFixture()
        let identity = try f.start()
        f.controller.acceptHandshake(identity)
        f.controller.deliveryFailed(identity)
        f.controller.cancel(identity)
        f.clock.fire(0)
        XCTAssertEqual(f.events.failures, [.deliveryFailed])
        XCTAssertTrue(f.events.successes.isEmpty)
        XCTAssertEqual(f.ops.commands, ["initialize", "execute", "abort"])
        XCTAssertEqual(f.events.releases, 0)
        XCTAssertFalse(f.controller.admissionAvailable)
        f.clock.fire(3)
        XCTAssertEqual(f.ops.signalled, [identity])
        XCTAssertFalse(f.controller.admissionAvailable)
    }
}

private final class PatternOwnedChildFixture {
    let clock: PatternOwnedChildTestClock
    let ops: PatternOwnedChildTestOps
    let events: PatternOwnedChildTestEvents
    let controller: OwnedChildController
    init(capacity: Int = 4096) {
        let clock = PatternOwnedChildTestClock()
        let events = PatternOwnedChildTestEvents()
        let ops = PatternOwnedChildTestOps(clock: clock)
        self.clock = clock; self.events = events; self.ops = ops
        controller = OwnedChildController(parent: .init(startupNonce: UUID(), processID: 100),
            operations: ops, capacity: capacity, schedule: { clock.add($0, $1) }, events: { events.add($0) })
    }
    func start(requestID: UUID = UUID(), channel: AnalysisWorkerOwnedChildChannel = .pattern)
        throws -> AnalysisWorkerOwnedChildIdentity {
        try controller.start(key: .init(channel: channel, requestID: requestID, connectionGeneration: UUID()),
            payload: Data([1]), policy: .init(timeoutMS: 100, abortGraceMS: 25, cleanupGraceMS: 20,
                maximumRequestBytes: 16, maximumReplyBytes: 16)).get()
    }
    func changed(_ value: AnalysisWorkerOwnedChildIdentity, nonce: UUID? = nil, pid: Int32? = nil,
                 channel: AnalysisWorkerOwnedChildChannel? = nil, request: UUID? = nil,
                 generation: UUID? = nil) -> AnalysisWorkerOwnedChildIdentity {
        .init(parentStartupNonce: value.parentStartupNonce, spawnNonce: nonce ?? value.spawnNonce,
              processID: pid ?? value.processID, channel: channel ?? value.channel,
              requestID: request ?? value.requestID, connectionGeneration: generation ?? value.connectionGeneration)
    }
}

private final class PatternOwnedChildTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int, @Sendable () -> Void)] = []
    var count: Int { lock.withLock { entries.count } }
    func add(_ delay: Int, _ action: @escaping @Sendable () -> Void) { lock.withLock { entries.append((delay, action)) } }
    func fire(_ index: Int) { let action = lock.withLock { entries[index].1 }; action() }
}

/// Only invoked on the controller's serial owner queue; test reads occur after synchronous API calls.
private final class PatternOwnedChildTestOps: OwnedChildProcessOperations, @unchecked Sendable {
    let clock: PatternOwnedChildTestClock
    var waitable = true
    var spawnResult = OwnedChildSpawnResult.created(pid: 200)
    var signalResult = OwnedChildSignalResult.sent
    var waitResults: [OwnedChildWaitResult] = []
    var finalReply: Data?
    var failedCommands: Set<String> = []
    var launches: [OwnedChildLaunch] = []
    var commands: [String] = []
    var commandIdentities: [AnalysisWorkerOwnedChildIdentity] = []
    var signalled: [AnalysisWorkerOwnedChildIdentity] = []
    var waited: [AnalysisWorkerOwnedChildIdentity] = []
    var scheduledCountAtAbort: Int?
    init(clock: PatternOwnedChildTestClock) { self.clock = clock }
    func preservesWaitableChildren() -> Bool { waitable }
    func spawn(_ launch: OwnedChildLaunch) -> OwnedChildSpawnResult { launches.append(launch); return spawnResult }
    func send(_ command: OwnedChildCommand, to identity: AnalysisWorkerOwnedChildIdentity) -> Bool {
        let name: String
        switch command {
        case .initialize: name = "initialize"
        case .execute: name = "execute"
        case .abort: name = "abort"; scheduledCountAtAbort = clock.count
        case .shutdown: name = "shutdown"
        }
        commands.append(name); commandIdentities.append(identity)
        return !failedCommands.contains(name)
    }
    func signalKill(_ identity: AnalysisWorkerOwnedChildIdentity) -> OwnedChildSignalResult {
        signalled.append(identity); return signalResult
    }
    func waitNoHang(_ identity: AnalysisWorkerOwnedChildIdentity) -> OwnedChildWaitResult {
        waited.append(identity)
        return waitResults.isEmpty ? .pending : waitResults.removeFirst()
    }
    func finalReplyAfterExit(_ identity: AnalysisWorkerOwnedChildIdentity) -> Data? { finalReply }
}

private final class PatternOwnedChildTestEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OwnedChildController.Event] = []
    private var observer: (@Sendable (OwnedChildController.Event) -> Void)?
    func observe(_ body: @escaping @Sendable (OwnedChildController.Event) -> Void) {
        lock.withLock { observer = body }
    }
    func add(_ event: OwnedChildController.Event) {
        let body = lock.withLock { entries.append(event); return observer }
        body?(event)
    }
    var releases: Int { lock.withLock { entries.filter { if case .admissionReleased = $0 { return true }; return false }.count } }
    var failures: [OwnedChildController.Failure] { lock.withLock { entries.compactMap {
        if case .settled(_, .failure(let failure)) = $0 { return failure }; return nil
    } } }
    var successes: [Data] { lock.withLock { entries.compactMap {
        if case .settled(_, .success(let data)) = $0 { return data }; return nil
    } } }
    var receipts: [AnalysisWorkerOwnedChildExitReceipt] { lock.withLock { entries.compactMap {
        if case .reaped(let receipt) = $0 { return receipt }; return nil
    } } }
}

private final class PatternChannelTestDouble: PatternInterpretationTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [UUID] = []
    private var cancelled: [UUID] = []
    var patternAvailable: Bool { true }
    var requests: [UUID] { lock.withLock { sent } }
    var cancellations: [UUID] { lock.withLock { cancelled } }
    func sendPatternInterpretation(requestID: UUID, payload: Data) async throws -> Data {
        lock.withLock { sent.append(requestID) }
        return payload
    }
    func cancelPatternInterpretation(requestID: UUID) { lock.withLock { cancelled.append(requestID) } }
}
