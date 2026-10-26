import XCTest
@testable import MacScope

@MainActor
final class DebuggerPersistentLLDBOwnedProcessChannelLauncherTests: XCTestCase {
    func testLaunchRegistersExactOwnedProcessBeforeChannelEscapes() async throws {
        let evidence = try makeEvidence(processID: 601)
        let provider = OwnedLauncherEvidenceProvider(
            catalog: [.resolved(evidence), .resolved(evidence)],
            processIDs: [.resolved([]), .resolved([])]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let prepared = OwnedLauncherPreparedChannel(processID: 601)
        let launcher = PersistentLLDBOwnedProcessChannelLauncher(
            registry: registry,
            processPreparer: { _ in prepared }
        )

        let channel = try await launcher.launch(plan: makePlan())
        let snapshot = await registry.snapshot
        let launchCount = await prepared.launchCount
        let returnedBinding = try XCTUnwrap(
            channel as? any DebuggerOwnedInfrastructureRetainedProcessBinding
        )
        let returnedProcessID = await returnedBinding
            .retainedProcessIdentifierForInfrastructure()

        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.excludedInstances.count, 1)
        XCTAssertEqual(snapshot.excludedInstances.first?.processID, 601)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(returnedProcessID, 601)

        await channel.terminateRetainedAdapter()
        let didExit = await channel.waitForExit(maximumDuration: .zero)
        let didReap = await channel.reapAndClose()
        let retiredSnapshot = await registry.snapshot
        XCTAssertTrue(didExit)
        XCTAssertTrue(didReap)
        XCTAssertTrue(retiredSnapshot.isAuthoritative)
        XCTAssertTrue(retiredSnapshot.excludedInstances.isEmpty)
    }

    func testLaunchFailureSettlesExactNotLaunchedClaim() async throws {
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: OwnedLauncherEvidenceProvider(),
            hostProcessID: 9_999
        )
        let prepared = OwnedLauncherPreparedChannel(processID: 602, launchFails: true)
        let launcher = PersistentLLDBOwnedProcessChannelLauncher(
            registry: registry,
            processPreparer: { _ in prepared }
        )

        do {
            _ = try await launcher.launch(plan: makePlan())
            XCTFail("A failed Process.run must not publish a channel")
        } catch OwnedLauncherTestError.launchFailed {
            // Exact not-launched settlement completed before propagation.
        }

        let snapshot = await registry.snapshot
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.pendingSpawnCount, 0)
        XCTAssertEqual(snapshot.unresolvedSpawnCount, 0)
    }

    func testCancellationAfterClaimCompletesRegistrationAndProvenRetirement() async throws {
        let evidence = try makeEvidence(processID: 603)
        let provider = OwnedLauncherEvidenceProvider(
            catalog: [.resolved(evidence), .resolved(evidence)],
            processIDs: [.resolved([]), .resolved([])]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let gate = OwnedLauncherGate()
        let prepared = OwnedLauncherPreparedChannel(processID: 603, launchGate: gate)
        let launcher = PersistentLLDBOwnedProcessChannelLauncher(
            registry: registry,
            processPreparer: { _ in prepared }
        )
        let task = Task { try await launcher.launch(plan: makePlan()) }

        await gate.waitUntilEntered()
        task.cancel()
        await gate.resume()

        do {
            _ = try await task.value
            XCTFail("A cancelled construction must not publish the registered channel")
        } catch is CancellationError {
            // Cleanup is cancellation-shielded.
        }
        let snapshot = await registry.snapshot
        let launchCancellationStates = await prepared.launchCancellationStates
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertTrue(snapshot.excludedInstances.isEmpty)
        XCTAssertEqual(launchCancellationStates, [false])
    }

    func testRegistryRetirementFailureMakesReapProofFalse() async throws {
        let evidence = try makeEvidence(processID: 604)
        let provider = OwnedLauncherEvidenceProvider(
            catalog: [.resolved(evidence), .resolved(evidence)],
            processIDs: [.unknown(.unstableSnapshot)]
        )
        let registry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: provider,
            hostProcessID: 9_999
        )
        let prepared = OwnedLauncherPreparedChannel(processID: 604)
        let launcher = PersistentLLDBOwnedProcessChannelLauncher(
            registry: registry,
            processPreparer: { _ in prepared }
        )
        let channel = try await launcher.launch(plan: makePlan())

        await channel.terminateRetainedAdapter()
        let didExit = await channel.waitForExit(maximumDuration: .zero)
        let didReap = await channel.reapAndClose()
        XCTAssertTrue(didExit)
        XCTAssertFalse(didReap)

        let snapshot = await registry.snapshot
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertEqual(snapshot.excludedInstances.count, 1)
    }

    private func makePlan() throws -> PersistentLLDBCLIProcessLaunchPlan {
        let developer = "/Applications/Xcode.app/Contents/Developer"
        return try PersistentLLDBCLIProcessLaunchPlan.make(
            lldbExecutablePath: developer + "/usr/bin/lldb",
            developerDirectory: developer,
            environment: [:],
            workingDirectory: "/tmp"
        )
    }

    private func makeEvidence(processID: Int32) throws -> DebuggerLocalProcessCatalogEvidence {
        let start = try XCTUnwrap(
            DebuggerProcessStartIdentity(seconds: UInt64(processID), microseconds: 7)
        )
        let fingerprint = try XCTUnwrap(
            DebuggerLocalProcessCatalogFingerprint(
                processID: processID,
                startTime: start,
                realUserID: 501,
                effectiveUserID: 501,
                canonicalExecutablePath: "/tmp/MacScope-owned-launcher-\(processID)",
                executableDeviceID: 11,
                executableFileID: UInt64(processID) + 100,
                executableByteCount: 4_096,
                executableChangeTimeNanoseconds: 123,
                architecture: .arm64,
                machOUUID: nil,
                codeIdentity: nil
            )
        )
        return DebuggerLocalProcessCatalogEvidence(
            fingerprint: fingerprint,
            displayName: "Owned launcher helper",
            parentProcessID: 1,
            savedUserID: 501,
            dynamicState: DebuggerLocalProcessDynamicState()
        )
    }
}

private enum OwnedLauncherTestError: Error {
    case launchFailed
}

private actor OwnedLauncherPreparedChannel: PersistentLLDBOwnedPreparedProcessChannel {
    private let processID: Int32
    private let launchFails: Bool
    private let launchGate: OwnedLauncherGate?
    private var state: DebuggerOwnedInfrastructureRetainedProcessDisposition = .notLaunched
    private(set) var launchCount = 0
    private(set) var launchCancellationStates: [Bool] = []

    init(processID: Int32, launchFails: Bool = false, launchGate: OwnedLauncherGate? = nil) {
        self.processID = processID
        self.launchFails = launchFails
        self.launchGate = launchGate
    }

    func launchPreparedProcess() async throws {
        launchCount += 1
        launchCancellationStates.append(Task.isCancelled)
        if let launchGate { await launchGate.enter() }
        if launchFails { throw OwnedLauncherTestError.launchFailed }
        state = .running
    }

    func write(_: Data) async throws {}
    func nextBytes() async throws -> Data? { nil }
    func closeInput() async {}
    func closeHandles() async {}
    func waitForExit(maximumDuration _: Duration) async -> Bool { state != .running }
    func terminateRetainedAdapter() async {
        if state == .running { state = .unknown }
    }
    func killRetainedAdapterIfStillRunning() async -> Bool {
        if state == .running { state = .unknown; return true }
        return false
    }
    func reapAndClose() async -> Bool {
        guard state != .running, state != .notLaunched else { return false }
        state = .exitedAndReaped
        return true
    }
    func retainedProcessIdentifierForInfrastructure() async -> Int32 {
        state == .notLaunched ? 0 : processID
    }
    func retainedProcessIsRunningForInfrastructure() async -> Bool { state == .running }
    func retainedProcessDispositionForInfrastructure() async
        -> DebuggerOwnedInfrastructureRetainedProcessDisposition { state }
}

private actor OwnedLauncherEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private var catalogResults: [DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence>]
    private var processIDResults: [DebuggerLocalProcessResolution<[Int32]>]

    init(
        catalog: [DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence>] = [],
        processIDs: [DebuggerLocalProcessResolution<[Int32]>] = []
    ) {
        catalogResults = catalog
        processIDResults = processIDs
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        processIDResults.isEmpty ? .unknown(.unstableSnapshot) : processIDResults.removeFirst()
    }
    func catalogEvidence(
        processID _: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        catalogResults.isEmpty ? .unknown(.unstableSnapshot) : catalogResults.removeFirst()
    }
    func authorizationEvidence(
        processID _: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        .unknown(.unstableSnapshot)
    }
}

private actor OwnedLauncherGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
