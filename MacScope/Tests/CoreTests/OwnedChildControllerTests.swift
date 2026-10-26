import Foundation
import XCTest
@testable import MacScope

final class OwnedChildControllerTests: XCTestCase {
    func testDispatchRequiresMatchingNoncePIDChannelRequestAndGeneration() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        XCTAssertEqual(fixture.ops.commands, ["initialize"])
        for bad in [fixture.changed(identity, nonce: UUID()), fixture.changed(identity, pid: 999),
                    fixture.changed(identity, channel: .decompiler),
                    fixture.changed(identity, request: UUID()), fixture.changed(identity, generation: UUID())] {
            fixture.controller.acceptHandshake(bad)
        }
        XCTAssertEqual(fixture.ops.commands, ["initialize"])
        fixture.controller.acceptHandshake(identity)
        fixture.controller.acceptHandshake(identity)
        XCTAssertEqual(fixture.ops.commands, ["initialize", "execute"])
        XCTAssertEqual(fixture.controller.phase, .running)
    }

    func testTimeoutAbortsKillsAndRetainsAdmissionUntilExactReap() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        fixture.controller.acceptHandshake(identity)
        fixture.clock.fire(0) // Work deadline, not the caller task.
        XCTAssertEqual(fixture.ops.commands, ["initialize", "execute", "abort"])
        XCTAssertEqual(fixture.ops.scheduledCountAtAbort, 4) // Grace armed before pipe write.
        XCTAssertEqual(fixture.events.failures, [.timedOut])
        XCTAssertFalse(fixture.controller.admissionAvailable)
        fixture.ops.signalResult = .failed(errno: 13) // EPERM is NOT exit proof.
        fixture.clock.fire(3)
        fixture.clock.fire(3)
        XCTAssertEqual(fixture.ops.signalled, [identity])
        XCTAssertFalse(fixture.controller.admissionAvailable)
        XCTAssertEqual(fixture.events.releases, 0)
        fixture.ops.waitResults = [.terminal(pid: identity.processID, rawStatus: 9,
                                             termination: .signalled(signal: 9, coreDumped: false))]
        fixture.clock.fire(2)
        XCTAssertTrue(fixture.controller.admissionAvailable)
        XCTAssertEqual(fixture.events.releases, 1)
        XCTAssertEqual(fixture.events.failures, [.timedOut])
        XCTAssertEqual(fixture.events.receipts.first?.rawWaitStatus, 9)
        fixture.clock.fire(3) // Stale grace cannot signal after reap.
        XCTAssertEqual(fixture.ops.signalled.count, 1)
    }

    func testFailedAbortWriteStillEscalatesAndDoesNotRelease() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        fixture.ops.failedCommands = ["abort"]
        fixture.controller.cancel(identity)
        XCTAssertEqual(fixture.ops.scheduledCountAtAbort, 4)
        fixture.clock.fire(3)
        XCTAssertEqual(fixture.ops.signalled, [identity])
        XCTAssertEqual(fixture.events.failures, [.cancelled])
        XCTAssertFalse(fixture.controller.admissionAvailable)
    }

    func testInitializeDeliveryFailureReturnsOwnedIdentityAndSettlesOnce() throws {
        let fixture = OwnedChildFixture()
        fixture.ops.failedCommands = ["initialize"]
        let identity = try fixture.start()
        XCTAssertEqual(fixture.events.failures, [.deliveryFailed])
        XCTAssertFalse(fixture.controller.admissionAvailable)
        fixture.controller.deliveryFailed(identity)
        fixture.clock.fire(3)
        XCTAssertEqual(fixture.ops.signalled, [identity])
        XCTAssertEqual(fixture.events.failures, [.deliveryFailed])
    }

    func testNativeReturnKeepsCleanupAdmissionAndNeverSettlesTwice() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        fixture.controller.acceptHandshake(identity)
        fixture.controller.nativeReturned(identity, payload: Data([42]))
        fixture.controller.nativeReturned(identity, payload: Data([43]))
        XCTAssertEqual(fixture.events.successes, [Data([42])])
        XCTAssertFalse(fixture.controller.admissionAvailable)
        fixture.clock.fire(0) // Native deadline no longer applies.
        XCTAssertEqual(fixture.events.failures, [])
        fixture.clock.fire(3) // Bounded cleanup still kills an unreaped child.
        fixture.ops.waitResults = [.terminal(pid: identity.processID, rawStatus: 7 << 8,
                                             termination: .exited(code: 7))]
        fixture.clock.fire(2)
        XCTAssertEqual(fixture.events.successes, [Data([42])])
        XCTAssertEqual(fixture.events.failures, [])
        XCTAssertEqual(fixture.events.receipts.first?.termination, .exited(code: 7))
        XCTAssertTrue(fixture.controller.admissionAvailable)
    }

    func testExitWithoutTerminalFramePreservesExactCodeOrSignal() throws {
        let cases: [(AnalysisWorkerOwnedChildTermination, Int32, OwnedChildController.Failure)] = [
            (.exited(code: 0), 0, .protocolFailure),
            (.exited(code: 17), 17 << 8, .childExited(17)),
            (.signalled(signal: 11, coreDumped: true), 139, .childSignalled(11))
        ]
        for (termination, status, expected) in cases {
            let fixture = OwnedChildFixture()
            let identity = try fixture.start()
            fixture.ops.waitResults = [.terminal(pid: identity.processID, rawStatus: status,
                                                 termination: termination)]
            fixture.clock.fire(2)
            XCTAssertEqual(fixture.events.failures, [expected])
            XCTAssertEqual(fixture.events.receipts.first?.termination, termination)
            XCTAssertEqual(fixture.events.receipts.first?.rawWaitStatus, status)
            XCTAssertEqual(fixture.events.releases, 1)
        }
    }

    func testECHILDQuarantinesWithoutAnyLaterSignalWaitOrRelease() throws {
        let fixture = OwnedChildFixture()
        _ = try fixture.start()
        fixture.ops.waitResults = [.failed(errno: 10)]
        fixture.clock.fire(2)
        fixture.clock.fire(0)
        fixture.clock.fire(2)
        XCTAssertEqual(fixture.events.failures, [.ownershipLost(10)])
        XCTAssertEqual(fixture.controller.phase, .exitUnconfirmed)
        XCTAssertFalse(fixture.controller.admissionAvailable)
        XCTAssertEqual(fixture.ops.waited.count, 1)
        XCTAssertEqual(fixture.ops.signalled, [])
        XCTAssertEqual(fixture.events.releases, 0)
    }

    func testSupervisorLossKeepsOrphanQuarantineAndRejectsReplacement() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        fixture.controller.supervisorLost()
        fixture.controller.acceptHandshake(identity)
        fixture.controller.nativeReturned(identity, payload: Data([42]))
        fixture.clock.fire(0)
        fixture.clock.fire(2)
        XCTAssertEqual(fixture.events.failures, [.supervisorLost])
        XCTAssertEqual(fixture.controller.phase, .exitUnconfirmed)
        XCTAssertFalse(fixture.controller.admissionAvailable)
        XCTAssertEqual(fixture.ops.commands, ["initialize"])
        XCTAssertEqual(fixture.ops.waited, [])
        XCTAssertEqual(fixture.ops.signalled, [])
        XCTAssertThrowsError(try fixture.start())
        XCTAssertEqual(fixture.ops.launches.count, 1)
    }

    func testPendingInterruptedAndNonterminalWaitsRetainOwnership() throws {
        let fixture = OwnedChildFixture()
        _ = try fixture.start()
        fixture.ops.waitResults = [.pending, .interrupted, .nonterminal]
        fixture.clock.fire(2)
        fixture.clock.fire(3)
        fixture.clock.fire(4)
        XCTAssertFalse(fixture.controller.admissionAvailable)
        XCTAssertEqual(fixture.events.releases, 0)
        XCTAssertEqual(fixture.ops.waited.count, 3)
    }

    func testReusedNumericPIDIsProtectedFromOldTimerAndControl() throws {
        let fixture = OwnedChildFixture()
        let old = try fixture.start()
        fixture.ops.waitResults = [.terminal(pid: old.processID, rawStatus: 0, termination: .exited(code: 0))]
        fixture.clock.fire(2)
        let next = try fixture.start()
        XCTAssertEqual(old.processID, next.processID)
        XCTAssertNotEqual(old.spawnNonce, next.spawnNonce)
        fixture.controller.cancel(old)
        fixture.controller.nativeReturned(old, payload: Data([1]))
        fixture.clock.fire(0)
        fixture.clock.fire(2)
        XCTAssertEqual(fixture.controller.phase, .awaitingHandshake)
        XCTAssertEqual(fixture.ops.waited.count, 1)
        XCTAssertEqual(fixture.ops.signalled, [])
        XCTAssertEqual(fixture.events.releases, 1)
    }

    func testRequestReplaySaturationAndCrossChannelIdentity() throws {
        let fixture = OwnedChildFixture(capacity: 2)
        let requestID = UUID()
        let first = try fixture.start(requestID: requestID)
        fixture.ops.waitResults = [.terminal(pid: first.processID, rawStatus: 0, termination: .exited(code: 0))]
        fixture.clock.fire(2)
        XCTAssertThrowsError(try fixture.start(requestID: requestID)) // New connection is still replay.
        let other = try fixture.start(requestID: requestID, channel: .decompiler)
        fixture.ops.waitResults = [.terminal(pid: other.processID, rawStatus: 0, termination: .exited(code: 0))]
        fixture.clock.fire(5)
        XCTAssertThrowsError(try fixture.start()) // No eviction at lifetime saturation.
        XCTAssertEqual(fixture.ops.launches.count, 2)
    }

    func testSpawnFailuresDistinguishNoChildFromUncertainOwnership() {
        let fixture = OwnedChildFixture()
        fixture.ops.spawnResult = .notCreated(errno: 2)
        XCTAssertThrowsError(try fixture.start())
        XCTAssertTrue(fixture.controller.admissionAvailable)
        fixture.ops.spawnResult = .ownershipUncertain(errno: 5)
        XCTAssertThrowsError(try fixture.start())
        XCTAssertFalse(fixture.controller.admissionAvailable)
        XCTAssertEqual(fixture.controller.phase, .exitUnconfirmed)
        XCTAssertThrowsError(try fixture.start())
        XCTAssertEqual(fixture.ops.launches.count, 2)
        XCTAssertEqual(fixture.ops.signalled, [])
    }

    func testSIGCHLDOrOtherWaiterConflictRefusesBeforeSpawn() {
        let fixture = OwnedChildFixture()
        fixture.ops.waitable = false
        XCTAssertThrowsError(try fixture.start())
        XCTAssertEqual(fixture.ops.launches.count, 0)
        XCTAssertFalse(fixture.controller.admissionAvailable)
    }

    func testHandshakeDeadlineRejectsLateReadyWithoutNativeDispatch() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        fixture.clock.fire(1)
        fixture.controller.acceptHandshake(identity)
        XCTAssertEqual(fixture.ops.commands, ["initialize", "abort"])
        XCTAssertEqual(fixture.events.failures, [.timedOut])
        XCTAssertFalse(fixture.controller.admissionAvailable)
    }

    func testWrongPIDReapResultCannotReleaseOrSignalAnotherProcess() throws {
        let fixture = OwnedChildFixture()
        _ = try fixture.start()
        fixture.ops.waitResults = [.terminal(pid: 999, rawStatus: 0, termination: .exited(code: 0))]
        fixture.clock.fire(2)
        fixture.clock.fire(0)
        XCTAssertEqual(fixture.events.failures, [.invalidReapIdentity])
        XCTAssertEqual(fixture.events.releases, 0)
        XCTAssertEqual(fixture.ops.signalled, [])
        XCTAssertFalse(fixture.controller.admissionAvailable)
    }

    func testReapCallbackCanReenterAfterSignalAuthorityIsRemoved() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        let controller = fixture.controller
        fixture.events.observe { [weak controller] event in
            if case .reaped = event {
                XCTAssertTrue(controller?.admissionAvailable == true)
                controller?.cancel(identity)
            }
        }
        fixture.ops.waitResults = [.terminal(pid: identity.processID, rawStatus: 0, termination: .exited(code: 0))]
        fixture.clock.fire(2)
        XCTAssertEqual(fixture.events.releases, 1)
        XCTAssertEqual(fixture.events.failures, [.protocolFailure])
        XCTAssertEqual(fixture.ops.signalled, [])
    }

    func testReapDrainsBufferedTerminalBeforeCallingMissingReplyFailure() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        fixture.controller.acceptHandshake(identity)
        fixture.ops.finalReply = Data([42])
        fixture.ops.waitResults = [.terminal(pid: identity.processID, rawStatus: 0, termination: .exited(code: 0))]
        fixture.clock.fire(2)
        fixture.controller.nativeReturned(identity, payload: Data([43]))
        XCTAssertEqual(fixture.events.successes, [Data([42])])
        XCTAssertEqual(fixture.events.failures, [])
        XCTAssertEqual(fixture.events.releases, 1)
    }

    func testBufferedTerminalBeforeHandshakeCannotPublishOrDispatchAndStillReleases() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        fixture.ops.finalReply = Data([42])
        fixture.ops.waitResults = [.terminal(pid: identity.processID, rawStatus: 0, termination: .exited(code: 0))]
        // The same-key buffered frame alone cannot prove the first handshake or execute.
        fixture.controller.nativeReturned(identity, payload: Data([41]))
        fixture.clock.fire(2)
        fixture.controller.acceptHandshake(identity)
        XCTAssertEqual(fixture.events.successes, [])
        XCTAssertEqual(fixture.events.failures, [.protocolFailure])
        XCTAssertEqual(fixture.ops.commands, ["initialize"])
        XCTAssertEqual(fixture.events.releases, 1)
        XCTAssertTrue(fixture.controller.admissionAvailable)
        XCTAssertEqual(fixture.ops.signalled, [])
    }

    func testOversizedTerminalCannotPublishAndStillNeedsReap() throws {
        let fixture = OwnedChildFixture()
        let identity = try fixture.start()
        fixture.controller.acceptHandshake(identity)
        fixture.controller.nativeReturned(identity, payload: Data(repeating: 0, count: 17))
        XCTAssertEqual(fixture.events.successes, [])
        XCTAssertEqual(fixture.events.failures, [.protocolFailure])
        XCTAssertFalse(fixture.controller.admissionAvailable)
    }
    func testChildModeAbsentKeepsDefaultPathWithOrdinaryEnvironment() {
        XCTAssertEqual(PosixOwnedChildMode.select(arguments: ["worker", "--ordinary-argument"],
            environment: ["PATH": "/usr/bin", "HOME": "/unchanged"], allowedChannels: ["pattern"]), .notRequested)
    }

    func testChildModeRequiresExactInvocationAndMinimalEnvironment() {
        let args = ["worker", PosixOwnedChildMode.flag, "--channel", "pattern"]
        XCTAssertEqual(PosixOwnedChildMode.select(arguments: args, environment: PosixOwnedChildMode.environment,
            allowedChannels: ["pattern"]), .child("pattern"))
        var inherited = PosixOwnedChildMode.environment
        inherited["PATH"] = "/usr/bin"
        XCTAssertEqual(PosixOwnedChildMode.select(arguments: args, environment: inherited,
            allowedChannels: ["pattern"]), .rejected)
        XCTAssertEqual(PosixOwnedChildMode.select(arguments: args + ["--extra"],
            environment: PosixOwnedChildMode.environment, allowedChannels: ["pattern"]), .rejected)
        XCTAssertEqual(PosixOwnedChildMode.select(arguments: ["worker", "--macscope-owned-native-child-v2"],
            environment: PosixOwnedChildMode.environment, allowedChannels: ["pattern"]), .rejected)
    }

    func testChildModeCannotRouteAnalysisChannelIntoDecompilerExecutable() {
        XCTAssertEqual(PosixOwnedChildMode.select(arguments: ["worker", PosixOwnedChildMode.flag, "--channel", "pattern"],
            environment: PosixOwnedChildMode.environment, allowedChannels: ["decompiler"]), .rejected)
        XCTAssertEqual(PosixOwnedChildMode.select(arguments: ["worker", PosixOwnedChildMode.flag, "--channel", "decompiler"],
            environment: PosixOwnedChildMode.environment, allowedChannels: ["pattern", "analysis", "dyld", "rea"]), .rejected)
    }

    func testCanonicalChildWireRejectsDuplicateUnknownAndOversizedFields() throws {
        let wire = makeWire()
        let encoded = try wire.encoded()
        let duplicate = Data("{\"kind\":\"initialize\",".utf8) + encoded.dropFirst()
        let unknown = Data("{\"unknown\":1,".utf8) + encoded.dropFirst()
        XCTAssertThrowsError(try OwnedChildWire.decode(duplicate, maximum: 1024))
        XCTAssertThrowsError(try OwnedChildWire.decode(unknown, maximum: 1024))
        XCTAssertThrowsError(try OwnedChildWire.decode(encoded, maximum: encoded.count - 1))
    }

    func testChildWireRoundTripPreservesActualPIDAndEveryIdentityField() throws {
        let wire = makeWire()
        let decoded = try OwnedChildWire.decode(wire.encoded(), maximum: 1024)
        XCTAssertEqual(decoded, wire)
        for field in ["parent", "spawn", "pid", "channel", "request", "generation"] {
            var changed = decoded
            switch field {
            case "parent": changed.parentStartupNonce = UUID()
            case "spawn": changed.spawnNonce = UUID()
            case "pid": changed.processID += 1
            case "channel": changed.channel = "decompiler"
            case "request": changed.requestID = UUID()
            default: changed.connectionGeneration = UUID()
            }
            XCTAssertFalse(changed.sameIdentity(as: wire), field)
        }
    }

    func testChildWireFrameHasExactBigEndianLengthAndUnchangedBody() throws {
        var wire = makeWire()
        wire.kind = "execute"; wire.payload = Data([0, 1, 255])
        let body = try wire.encoded()
        let framed = try wire.framed()
        let count = framed.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(Int(count), body.count)
        XCTAssertEqual(Data(framed.dropFirst(4)), body)
    }

    private func makeWire() -> OwnedChildWire {
        .init(kind: "initialize", parentStartupNonce: UUID(), spawnNonce: UUID(), processID: 200,
              channel: "pattern", requestID: UUID(), connectionGeneration: UUID())
    }

}

private final class OwnedChildFixture {
    let clock: OwnedChildTestClock
    let ops: OwnedChildTestOps
    let events: OwnedChildTestEvents
    let controller: OwnedChildController
    init(capacity: Int = 4096) {
        let clock = OwnedChildTestClock()
        let events = OwnedChildTestEvents()
        let ops = OwnedChildTestOps(clock: clock)
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

private final class OwnedChildTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int, @Sendable () -> Void)] = []
    var count: Int { lock.withLock { entries.count } }
    func add(_ delay: Int, _ action: @escaping @Sendable () -> Void) { lock.withLock { entries.append((delay, action)) } }
    func fire(_ index: Int) { let action = lock.withLock { entries[index].1 }; action() }
}

/// Only invoked on the controller's serial owner queue; test reads occur after synchronous API calls.
private final class OwnedChildTestOps: OwnedChildProcessOperations, @unchecked Sendable {
    let clock: OwnedChildTestClock
    var waitable = true
    var spawnResult = OwnedChildSpawnResult.created(pid: 200)
    var signalResult = OwnedChildSignalResult.sent
    var waitResults: [OwnedChildWaitResult] = []
    var finalReply: Data?
    var failedCommands: Set<String> = []
    var launches: [OwnedChildLaunch] = []
    var commands: [String] = []
    var signalled: [AnalysisWorkerOwnedChildIdentity] = []
    var waited: [AnalysisWorkerOwnedChildIdentity] = []
    var scheduledCountAtAbort: Int?
    init(clock: OwnedChildTestClock) { self.clock = clock }
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
        commands.append(name)
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

private final class OwnedChildTestEvents: @unchecked Sendable {
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
