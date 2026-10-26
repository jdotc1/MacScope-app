import Foundation
import XCTest
@testable import MacScope

final class AnalysisWorkerSupervisionTests: XCTestCase {
    private let identity = AnalysisWorkerProcessIdentity(startupNonce: UUID(), processID: 123)

    func testWrongNonceCannotArmWatchdog() {
        let clock = SupervisionTestClock()
        let watchdog = makeWatchdog(clock: clock)
        XCTAssertFalse(watchdog.arm(requestID: UUID(), expectedNonce: UUID(), timeoutMS: 2, abort: {}))
        XCTAssertEqual(clock.count, 0)
    }

    func testDeadlineAbortsThenEscalatesWithoutReleasingAdmission() {
        let clock = SupervisionTestClock()
        let admission = PatternWorkerAdmission()
        let requestID = UUID()
        let actions = SupervisionTestActions()
        let watchdog = makeWatchdog(clock: clock, kill: { actions.add("kill") })
        XCTAssertTrue(admission.tryAcquire(requestID: requestID))
        admission.installCancellation(requestID: requestID) {
            XCTAssertEqual(clock.count, 2, "escalation must already be armed if abort stalls")
            actions.add("abort")
        }
        XCTAssertTrue(watchdog.arm(requestID: requestID, expectedNonce: identity.startupNonce,
                                   timeoutMS: 100, abort: { admission.cancel(requestID: requestID) }))
        XCTAssertEqual(clock.delays, [100])
        clock.fire(0)
        XCTAssertEqual(actions.values, ["abort"])
        XCTAssertEqual(clock.delays, [100, 25])
        XCTAssertFalse(admission.tryAcquire(requestID: UUID()))
        clock.fire(1)
        clock.fire(1) // Duplicate timer delivery cannot repeat the termination action.
        XCTAssertEqual(actions.values, ["abort", "kill"])
        // Fake kill returning is NOT exit. The native lease must still be held.
        XCTAssertFalse(admission.tryAcquire(requestID: UUID()))
        admission.releaseAfterNativeReturn(requestID: requestID)
        XCTAssertTrue(admission.tryAcquire(requestID: UUID()))
    }

    func testNativeReturnBeforeDeadlineSuppressesAbortAndKill() {
        let clock = SupervisionTestClock()
        let actions = SupervisionTestActions()
        let watchdog = makeWatchdog(clock: clock, kill: { actions.add("kill") })
        let id = UUID()
        XCTAssertTrue(watchdog.arm(requestID: id, expectedNonce: identity.startupNonce,
                                   timeoutMS: 100, abort: { actions.add("abort") }))
        watchdog.nativeReturned(requestID: id)
        clock.fire(0)
        XCTAssertEqual(actions.values, [])
        XCTAssertEqual(clock.count, 1)
    }

    func testLateNativeReturnSuppressesKillButNeverReopensQuarantinedWatchdog() {
        let clock = SupervisionTestClock()
        let actions = SupervisionTestActions()
        let watchdog = makeWatchdog(clock: clock, kill: { actions.add("kill") })
        let id = UUID()
        XCTAssertTrue(watchdog.arm(requestID: id, expectedNonce: identity.startupNonce,
                                   timeoutMS: 100, abort: { actions.add("abort") }))
        clock.fire(0)
        watchdog.nativeReturned(requestID: id)
        clock.fire(1)
        XCTAssertEqual(actions.values, ["abort"])
        XCTAssertFalse(watchdog.arm(requestID: UUID(), expectedNonce: identity.startupNonce,
                                    timeoutMS: 100, abort: {}))
    }

    func testWatchdogRejectsReplayAndSaturationWithoutEvictingTombstones() {
        let clock = SupervisionTestClock()
        let watchdog = AnalysisWorkerDeadlineWatchdog(identity: identity, capacity: 1,
            schedule: { clock.schedule($0, $1) }, terminateSelf: {})
        let id = UUID()
        XCTAssertTrue(watchdog.arm(requestID: id, expectedNonce: identity.startupNonce,
                                   timeoutMS: 100, abort: {}))
        watchdog.nativeReturned(requestID: id)
        XCTAssertFalse(watchdog.arm(requestID: id, expectedNonce: identity.startupNonce,
                                    timeoutMS: 100, abort: {}))
        XCTAssertFalse(watchdog.arm(requestID: UUID(), expectedNonce: identity.startupNonce,
                                    timeoutMS: 100, abort: {}))
    }

    func testHostRetainsFlightUntilMatchingObserverProvesExit() {
        let observerID = UUID()
        let host = AnalysisWorkerSupervision(identity: identity, observerID: observerID)
        let id = UUID()
        XCTAssertTrue(host.register(requestID: id, expectedNonce: identity.startupNonce))
        host.deadlineExpired(requestID: id)
        XCTAssertEqual(host.currentPhase, .quarantined)
        XCTAssertEqual(host.unresolvedCount, 1)
        XCTAssertFalse(host.register(requestID: UUID(), expectedNonce: identity.startupNonce))
        host.observedExit(identity: identity, observerID: UUID())
        let replacement = AnalysisWorkerProcessIdentity(startupNonce: UUID(), processID: identity.processID)
        host.observedExit(identity: replacement, observerID: observerID)
        host.nativeReturned(requestID: id, producingNonce: replacement.startupNonce)
        XCTAssertEqual(host.unresolvedCount, 1)
        XCTAssertEqual(host.currentPhase, .quarantined)
        host.observedExit(identity: identity, observerID: observerID)
        XCTAssertEqual(host.unresolvedCount, 0)
        XCTAssertEqual(host.currentPhase, .exitObserved)
        XCTAssertFalse(host.register(requestID: UUID(), expectedNonce: identity.startupNonce))
    }

    func testHostLateReturnEndsFlightWithoutReopeningQuarantinedIncarnation() {
        let host = AnalysisWorkerSupervision(identity: identity, observerID: UUID())
        let id = UUID()
        XCTAssertTrue(host.register(requestID: id, expectedNonce: identity.startupNonce))
        host.deadlineExpired(requestID: id)
        host.nativeReturned(requestID: id, producingNonce: identity.startupNonce)
        XCTAssertEqual(host.unresolvedCount, 0)
        XCTAssertEqual(host.currentPhase, .quarantined)
        XCTAssertFalse(host.register(requestID: UUID(), expectedNonce: identity.startupNonce))
    }

    func testHostNormalReturnAllowsFreshRequestButRejectsReplayAndWrongNonce() {
        let host = AnalysisWorkerSupervision(identity: identity, observerID: UUID())
        let id = UUID()
        XCTAssertFalse(host.register(requestID: id, expectedNonce: UUID()))
        XCTAssertTrue(host.register(requestID: id, expectedNonce: identity.startupNonce))
        host.nativeReturned(requestID: id, producingNonce: identity.startupNonce)
        XCTAssertEqual(host.currentPhase, .idle)
        XCTAssertFalse(host.register(requestID: id, expectedNonce: identity.startupNonce))
        XCTAssertTrue(host.register(requestID: UUID(), expectedNonce: identity.startupNonce))
    }

    func testPrincipalChallengeUsesActualProcessIdentityAndRefusesStaleTerminationNonce() throws {
        let control = SupervisionTestControl(identity: identity)
        let principal = AnalysisWorkerXPCPrincipal(
            service: AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec()),
            processControl: control)
        let challenge = UUID()
        var response: Data?
        principal.workerControlChallenge(challenge: challenge) { response = $0 }
        let reply = try JSONDecoder().decode(AnalysisWorkerControlReply.self, from: XCTUnwrap(response))
        XCTAssertEqual(reply.schemaVersion, 1)
        XCTAssertEqual(reply.challenge, challenge)
        XCTAssertEqual(reply.identity, identity)
        principal.workerControlTerminate(expectedNonce: UUID(), challenge: challenge) { response = $0 }
        let refused = try JSONDecoder().decode(AnalysisWorkerControlReply.self, from: XCTUnwrap(response))
        XCTAssertFalse(refused.accepted)
        XCTAssertEqual(refused.identity, identity)
        XCTAssertEqual(control.terminationCount, 0)
        principal.workerControlTerminate(expectedNonce: identity.startupNonce, challenge: challenge) { response = $0 }
        XCTAssertEqual(control.terminationCount, 1)
    }

    func testWatchdogNonceRefusalNeverConstructsNativeJobOrRetainsLease() throws {
        let request = PatternInterpretationRequest(requestID: UUID(), key: .init(imageIdentity: "image",
            byteSnapshotID: UUID(), patternIdentity: "pattern", selectionImageOffset: 0,
            selectionByteCount: 1), bytes: Data([0]), source: "u8 x @ 0;")
        let clock = SupervisionTestClock()
        let admission = PatternWorkerAdmission()
        let service = PatternInterpretationService(makeJob: { _ in
            XCTFail("wrong incarnation must not construct a native job")
            throw PatternServiceFailure.unavailable
        }, watchdog: makeWatchdog(clock: clock), admission: admission)
        let response = SupervisionTestResponse()
        service.handle(requestData: try JSONEncoder().encode(request), requestID: request.requestID,
                       expectedNonce: UUID()) { response.set($0) }
        XCTAssertNotNil(response.value)
        XCTAssertEqual(clock.count, 0)
        XCTAssertTrue(admission.tryAcquire(requestID: UUID()))
    }

    private func makeWatchdog(clock: SupervisionTestClock,
                              kill: @escaping @Sendable () -> Void = {}) -> AnalysisWorkerDeadlineWatchdog {
        AnalysisWorkerDeadlineWatchdog(identity: identity, graceMS: 25,
            schedule: { clock.schedule($0, $1) }, terminateSelf: kill)
    }
}

private final class SupervisionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [(Int, @Sendable () -> Void)] = []
    func schedule(_ milliseconds: Int, _ action: @escaping @Sendable () -> Void) {
        lock.withLock { work.append((milliseconds, action)) }
    }
    var count: Int { lock.withLock { work.count } }
    var delays: [Int] { lock.withLock { work.map(\.0) } }
    func fire(_ index: Int) {
        let action = lock.withLock { work[index].1 }
        action()
    }
}

private final class SupervisionTestActions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func add(_ action: String) { lock.withLock { stored.append(action) } }
}

private final class SupervisionTestControl: AnalysisWorkerProcessControlling, @unchecked Sendable {
    let identity: AnalysisWorkerProcessIdentity
    private let lock = NSLock()
    private var count = 0
    var terminationCount: Int { lock.withLock { count } }
    init(identity: AnalysisWorkerProcessIdentity) { self.identity = identity }
    func requestTermination(expectedNonce: UUID) -> Bool {
        lock.withLock {
            guard expectedNonce == identity.startupNonce else { return false }
            count += 1
            return true
        }
    }
}

private final class SupervisionTestResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    var value: Data? { lock.withLock { stored } }
    func set(_ data: Data) { lock.withLock { stored = data } }
}
