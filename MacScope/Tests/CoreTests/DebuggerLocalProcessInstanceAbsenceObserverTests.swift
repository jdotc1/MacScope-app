import XCTest
@testable import MacScope

final class DebuggerLocalProcessInstanceAbsenceObserverTests: XCTestCase {
    func testTwoDisappearedPassesProveInstanceAbsent() async throws {
        let expected = try instanceKey(processID: 81, seconds: 8_001)
        let provider = ScriptedProcessInstanceAnchorProvider(
            observations: [.unknown(.disappeared), .unknown(.disappeared)]
        )
        let prover: any DebuggerLocalProcessInstanceAbsenceProving =
            DebuggerLocalProcessInstanceAbsenceObserver(anchorProvider: provider)

        let result = await prover.proveProcessInstanceAbsent(expected)

        XCTAssertEqual(result, .resolved(.absent))
        let requestedProcessIDs = await provider.requestedProcessIDs
        XCTAssertEqual(requestedProcessIDs, [expected.processID, expected.processID])
    }

    func testStablePIDReplacementProvesExpectedInstanceAbsent() async throws {
        let expected = try instanceKey(processID: 82, seconds: 8_002)
        let replacementStart = try start(seconds: 8_003)
        let replacement = DebuggerLocalProcessInstanceKey(
            processID: expected.processID,
            startTime: replacementStart
        )
        let provider = ScriptedProcessInstanceAnchorProvider(
            observations: [.resolved(replacement), .resolved(replacement)]
        )
        let prover = DebuggerLocalProcessInstanceAbsenceObserver(anchorProvider: provider)

        let result = await prover.proveProcessInstanceAbsent(expected)

        XCTAssertEqual(result, .resolved(.absent))
        let requestedProcessIDs = await provider.requestedProcessIDs
        XCTAssertEqual(requestedProcessIDs, [expected.processID, expected.processID])
    }

    func testSamePIDAndStartTimeRemainPresentWithoutExecutableMetadata() async throws {
        let expected = try instanceKey(processID: 83, seconds: 8_004)
        let provider = ScriptedProcessInstanceAnchorProvider(
            observations: [.resolved(expected), .resolved(expected)]
        )
        let prover = DebuggerLocalProcessInstanceAbsenceObserver(anchorProvider: provider)

        let result = await prover.proveProcessInstanceAbsent(expected)

        XCTAssertEqual(result, .resolved(.stillPresent))
        let requestedProcessIDs = await provider.requestedProcessIDs
        XCTAssertEqual(requestedProcessIDs, [expected.processID, expected.processID])
    }

    func testExecutableCatalogDisappearanceCannotMasqueradeAsKernelInstanceAbsence() async throws {
        let expected = try instanceKey(processID: 86, seconds: 8_007)
        let provider = StableAnchorDisappearedCatalogProvider(anchor: expected)
        let prover = DebuggerLocalProcessInstanceAbsenceObserver(anchorProvider: provider)

        let result = await prover.proveProcessInstanceAbsent(expected)

        XCTAssertEqual(result, .resolved(.stillPresent))
        let snapshot = await provider.snapshot
        XCTAssertEqual(snapshot.anchorProcessIDs, [expected.processID, expected.processID])
        XCTAssertEqual(snapshot.catalogCallCount, 0)
    }

    func testUnknownPassRemainsUnknownAfterSecondCompletePass() async throws {
        let expected = try instanceKey(processID: 84, seconds: 8_005)
        let provider = ScriptedProcessInstanceAnchorProvider(
            observations: [.unknown(.metadataAccessDenied), .unknown(.disappeared)]
        )
        let prover = DebuggerLocalProcessInstanceAbsenceObserver(anchorProvider: provider)

        let result = await prover.proveProcessInstanceAbsent(expected)

        XCTAssertEqual(result, .unknown(.metadataAccessDenied))
        let requestedProcessIDs = await provider.requestedProcessIDs
        XCTAssertEqual(requestedProcessIDs, [expected.processID, expected.processID])
    }

    func testAnchorForDifferentPIDRemainsUnknownAndCannotReleaseExpectedInstance() async throws {
        let expected = try instanceKey(processID: 87, seconds: 8_008)
        let wrongPIDAnchor = try instanceKey(processID: 88, seconds: 8_008)
        let provider = ScriptedProcessInstanceAnchorProvider(
            observations: [.resolved(wrongPIDAnchor), .resolved(wrongPIDAnchor)]
        )
        let prover = DebuggerLocalProcessInstanceAbsenceObserver(anchorProvider: provider)

        let result = await prover.proveProcessInstanceAbsent(expected)

        XCTAssertEqual(result, .unknown(.identityChanged))
        let requestedProcessIDs = await provider.requestedProcessIDs
        XCTAssertEqual(requestedProcessIDs, [expected.processID, expected.processID])
    }

    func testCallerCancellationCannotTruncateSecondPassAfterProofBegins() async throws {
        let expected = try instanceKey(processID: 85, seconds: 8_006)
        let provider = CancellationShieldedProcessInstanceAnchorProvider()
        let prover = DebuggerLocalProcessInstanceAbsenceObserver(anchorProvider: provider)

        let proofTask = Task {
            await prover.proveProcessInstanceAbsent(expected)
        }
        await provider.waitUntilSecondPassBegins()
        proofTask.cancel()
        await provider.releaseSecondPass()

        let result = await proofTask.value
        XCTAssertEqual(result, .resolved(.absent))
        let snapshot = await provider.snapshot
        XCTAssertEqual(snapshot.callCount, 2)
        XCTAssertEqual(snapshot.cancellationStates, [false, false])
    }

    private func instanceKey(
        processID: Int32,
        seconds: UInt64
    ) throws -> DebuggerLocalProcessInstanceKey {
        DebuggerLocalProcessInstanceKey(
            processID: processID,
            startTime: try start(seconds: seconds)
        )
    }

    private func start(seconds: UInt64) throws -> DebuggerProcessStartIdentity {
        try XCTUnwrap(DebuggerProcessStartIdentity(seconds: seconds, microseconds: 17))
    }

}

private actor ScriptedProcessInstanceAnchorProvider:
    DebuggerLocalProcessInstanceAnchorProviding {
    private var observations: [DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceKey>]
    private(set) var requestedProcessIDs: [Int32] = []

    init(observations: [DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceKey>]) {
        self.observations = observations
    }

    func processInstanceAnchor(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceKey> {
        requestedProcessIDs.append(processID)
        guard !observations.isEmpty else { return .unknown(.unstableSnapshot) }
        return observations.removeFirst()
    }
}

private actor StableAnchorDisappearedCatalogProvider:
    DebuggerLocalProcessInstanceAnchorProviding,
    DebuggerLocalProcessEvidenceProviding {
    struct Snapshot: Equatable, Sendable {
        let anchorProcessIDs: [Int32]
        let catalogCallCount: Int
    }

    private let anchor: DebuggerLocalProcessInstanceKey
    private var anchorProcessIDs: [Int32] = []
    private var catalogCallCount = 0

    init(anchor: DebuggerLocalProcessInstanceKey) {
        self.anchor = anchor
    }

    var snapshot: Snapshot {
        Snapshot(anchorProcessIDs: anchorProcessIDs, catalogCallCount: catalogCallCount)
    }

    func processInstanceAnchor(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceKey> {
        anchorProcessIDs.append(processID)
        return .resolved(anchor)
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        .resolved([anchor.processID])
    }

    func catalogEvidence(
        processID _: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        catalogCallCount += 1
        return .unknown(.disappeared)
    }

    func authorizationEvidence(
        processID _: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        .unknown(.unstableSnapshot)
    }
}

private actor CancellationShieldedProcessInstanceAnchorProvider:
    DebuggerLocalProcessInstanceAnchorProviding {
    struct Snapshot: Equatable, Sendable {
        let callCount: Int
        let cancellationStates: [Bool]
    }

    private var callCount = 0
    private var cancellationStates: [Bool] = []
    private var secondPassBegan = false
    private var secondPassWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondPassReleased = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    var snapshot: Snapshot {
        Snapshot(callCount: callCount, cancellationStates: cancellationStates)
    }

    func waitUntilSecondPassBegins() async {
        guard !secondPassBegan else { return }
        await withCheckedContinuation { continuation in
            secondPassWaiters.append(continuation)
        }
    }

    func releaseSecondPass() {
        secondPassReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func processInstanceAnchor(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessInstanceKey> {
        callCount += 1
        if callCount == 2 {
            secondPassBegan = true
            let waiters = secondPassWaiters
            secondPassWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            if !secondPassReleased {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
        }
        cancellationStates.append(Task.isCancelled)
        return .unknown(.disappeared)
    }
}
