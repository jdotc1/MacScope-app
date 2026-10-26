import Foundation
import XCTest
@testable import MacScope

final class DebuggerLocalProcessDiscoveryTests: XCTestCase {
    func testRefreshPublishesStaleThenIncrementalBatchesWithinBounds() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [1, 2, 3, 4, 5],
            perProcessDelayNanoseconds: 1_000_000
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(
            observer: observer,
            limits: .init(
                maximumCandidateCount: 8,
                maximumRetainedRows: 4,
                maximumConcurrentObservers: 2,
                publicationBatchSize: 2
            )
        )
        let updates = DiscoveryUpdateRecorder()

        let final = await service.refresh(policy: .discoveryFixture) { snapshot in
            await updates.append(snapshot)
        }

        let snapshots = await updates.values
        XCTAssertTrue(snapshots.first?.isStale == true)
        XCTAssertTrue(snapshots.first?.isRefreshing == true)
        XCTAssertGreaterThanOrEqual(snapshots.count, 3)
        XCTAssertEqual(final.entries.count, 4)
        XCTAssertFalse(final.isRefreshing)
        XCTAssertFalse(final.isStale)
        XCTAssertEqual(final.metrics?.candidateCount, 5)
        XCTAssertEqual(final.metrics?.retainedCount, 4)
        XCTAssertEqual(final.metrics?.droppedCount, 1)
        let maximumConcurrentCatalogCalls = await provider.maximumConcurrentCatalogCalls
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertLessThanOrEqual(maximumConcurrentCatalogCalls, 2)
        XCTAssertEqual(authorizationPassCount, 0)
    }

    func testSupersededGenerationDropsLateResults() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [10, 11, 12],
            perProcessDelayNanoseconds: 80_000_000
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(
            observer: observer,
            limits: .init(
                maximumCandidateCount: 8,
                maximumRetainedRows: 8,
                maximumConcurrentObservers: 1,
                publicationBatchSize: 1
            )
        )
        let oldUpdates = DiscoveryUpdateRecorder()
        let newUpdates = DiscoveryUpdateRecorder()

        let oldTask = Task {
            await service.refresh(policy: .discoveryFixture) { snapshot in
                await oldUpdates.append(snapshot)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        await provider.replaceProcessIDs([20])
        let newest = await service.refresh(policy: .discoveryFixture) { snapshot in
            await newUpdates.append(snapshot)
        }
        _ = await oldTask.value

        XCTAssertEqual(newest.entries.map(\.fingerprint.processID), [20])
        let recordedNewUpdates = await newUpdates.values
        XCTAssertEqual(Set(recordedNewUpdates.map(\.generation)), [newest.generation])
        let current = await service.currentSnapshot
        XCTAssertEqual(current.generation, newest.generation)
        XCTAssertEqual(current.entries.map(\.fingerprint.processID), [20])
    }

    func testRefreshDeduplicatesAndCapsCandidatePIDs() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [0, 4, 4, 3, 2, 1, -1],
            perProcessDelayNanoseconds: 0
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(
            observer: observer,
            limits: .init(
                maximumCandidateCount: 3,
                maximumRetainedRows: 3,
                maximumConcurrentObservers: 2,
                publicationBatchSize: 2
            )
        )

        let final = await service.refresh(policy: .discoveryFixture) { _ in }

        XCTAssertEqual(final.entries.map(\.fingerprint.processID), [1, 2, 3])
        XCTAssertEqual(final.metrics?.candidateCount, 3)
    }

    func testCallerCancellationStopsPublicationAndLeavesCatalogStale() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [21, 22, 23],
            perProcessDelayNanoseconds: 100_000_000
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(observer: observer)
        let updates = DiscoveryUpdateRecorder()
        let task = Task {
            await service.refresh(policy: .discoveryFixture) { snapshot in
                await updates.append(snapshot)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        task.cancel()
        let final = await task.value

        XCTAssertFalse(final.isRefreshing)
        XCTAssertTrue(final.isStale)
        XCTAssertEqual(final.aggregateDenials[.timeout], 1)
        let recordedGeneration = await updates.values.last?.generation
        XCTAssertEqual(recordedGeneration, final.generation)
    }

    func testCancellationDuringSuspendedProcessIDEnumerationRetainsPriorCatalogAsStale() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [24],
            perProcessDelayNanoseconds: 0
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(observer: observer)
        let prior = await service.refresh(policy: .discoveryFixture) { _ in }
        let priorSelection = try XCTUnwrap(prior.entries.first?.selection)
        let gate = DiscoverySuspensionGate()
        await provider.replaceProcessIDs([25])
        await provider.setProcessIDEnumerationGate(gate)

        let task = Task {
            await service.refresh(policy: .discoveryFixture) { _ in }
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        let final = await task.value

        XCTAssertEqual(final.entries.map(\.fingerprint.processID), [24])
        XCTAssertFalse(final.isRefreshing)
        XCTAssertTrue(final.isStale)
        XCTAssertEqual(final.aggregateDenials[.timeout], 1)
        let authorization = await service.authorize(
            selection: priorSelection,
            policy: .discoveryFixture
        )
        XCTAssertEqual(authorization.denial, .identityChanged)
        let passCount = await provider.authorizationPassCount
        XCTAssertEqual(passCount, 0)
    }

    func testProcessIDEnumerationFailureRetainsPriorCatalogAsStaleWithTypedDenial() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [26],
            perProcessDelayNanoseconds: 0
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(observer: observer)
        let prior = await service.refresh(policy: .discoveryFixture) { _ in }
        let priorSelection = try XCTUnwrap(prior.entries.first?.selection)
        await provider.failProcessIDEnumeration(with: .metadataAccessDenied)

        let final = await service.refresh(policy: .discoveryFixture) { _ in }

        XCTAssertEqual(final.entries.map(\.fingerprint.processID), [26])
        XCTAssertFalse(final.isRefreshing)
        XCTAssertTrue(final.isStale)
        XCTAssertEqual(final.aggregateDenials[.metadataAccessDenied], 1)
        let authorization = await service.authorize(
            selection: priorSelection,
            policy: .discoveryFixture
        )
        XCTAssertEqual(authorization.denial, .identityChanged)
        let passCount = await provider.authorizationPassCount
        XCTAssertEqual(passCount, 0)
    }

    func testAuthorizationRejectsStaleGenerationWithoutAuthorizationObservation() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [30],
            perProcessDelayNanoseconds: 0
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(observer: observer)
        let first = await service.refresh(policy: .discoveryFixture) { _ in }
        let staleSelection = try XCTUnwrap(first.entries.first?.selection)
        _ = await service.refresh(policy: .discoveryFixture) { _ in }

        let result = await service.authorize(
            selection: staleSelection,
            policy: .discoveryFixture
        )

        XCTAssertEqual(result.denial, .identityChanged)
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertEqual(authorizationPassCount, 0)
    }

    func testSupersessionDuringAuthorizationPassOnePreventsSecondObservation() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [32],
            perProcessDelayNanoseconds: 0
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(observer: observer)
        let initial = await service.refresh(policy: .discoveryFixture) { _ in }
        let selection = try XCTUnwrap(initial.entries.first?.selection)
        let gate = DiscoverySuspensionGate()
        await provider.setAuthorizationGate(gate)

        let authorizationTask = Task {
            await service.authorize(
                selection: selection,
                policy: .discoveryFixture
            )
        }
        await gate.waitUntilEntered()
        await provider.replaceProcessIDs([33])
        let replacement = await service.refresh(policy: .discoveryFixture) { _ in }
        await gate.open()
        let result = await authorizationTask.value

        XCTAssertGreaterThan(replacement.generation, selection.discoveryGeneration)
        XCTAssertEqual(result.denial, .identityChanged)
        let passCount = await provider.authorizationPassCount
        XCTAssertEqual(passCount, 1)
    }

    func testManualPIDBeforeRefreshCreatesFreshGenerationAndAuthorizes() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [],
            perProcessDelayNanoseconds: 0
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(observer: observer)

        let result = await service.resolveManualProcessID(
            31,
            policy: .discoveryFixture
        )

        guard case let .resolved(grant) = result else {
            return XCTFail("Expected manual PID authorization")
        }
        XCTAssertEqual(grant.discoveryGeneration, 1)
        let passCount = await provider.authorizationPassCount
        XCTAssertEqual(passCount, 2)
    }

    func testSupersededManualPIDPerformsZeroAuthorizationPasses() async throws {
        let provider = DiscoveryEvidenceProvider(
            processIDs: [41],
            perProcessDelayNanoseconds: 80_000_000
        )
        let observer = DebuggerLocalProcessIdentityObserver(provider: provider)
        let service = DebuggerLocalProcessDiscoveryService(observer: observer)
        let manual = Task {
            await service.resolveManualProcessID(40, policy: .discoveryFixture)
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        _ = await service.refresh(policy: .discoveryFixture) { _ in }
        let result = await manual.value

        XCTAssertEqual(result.denial, .identityChanged)
        let passCount = await provider.authorizationPassCount
        XCTAssertEqual(passCount, 0)
    }
}

private actor DiscoveryUpdateRecorder {
    private(set) var values: [DebuggerLocalProcessDiscoverySnapshot] = []

    func append(_ snapshot: DebuggerLocalProcessDiscoverySnapshot) {
        values.append(snapshot)
    }
}

private actor DiscoverySuspensionGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor DiscoveryEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private var processIDsValue: [Int32]
    private var processIDEnumerationDenial: DebuggerLocalAttachDenial?
    private var processIDEnumerationGate: DiscoverySuspensionGate?
    private var authorizationGate: DiscoverySuspensionGate?
    private let delay: UInt64
    private var activeCatalogCalls = 0
    private(set) var maximumConcurrentCatalogCalls = 0
    private(set) var authorizationPassCount = 0

    init(processIDs: [Int32], perProcessDelayNanoseconds: UInt64) {
        processIDsValue = processIDs
        delay = perProcessDelayNanoseconds
    }

    func replaceProcessIDs(_ processIDs: [Int32]) {
        processIDsValue = processIDs
    }

    func failProcessIDEnumeration(with denial: DebuggerLocalAttachDenial) {
        processIDEnumerationDenial = denial
    }

    func setProcessIDEnumerationGate(_ gate: DiscoverySuspensionGate) {
        processIDEnumerationGate = gate
    }

    func setAuthorizationGate(_ gate: DiscoverySuspensionGate) {
        authorizationGate = gate
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        if let processIDEnumerationGate {
            await processIDEnumerationGate.wait()
        }
        if let processIDEnumerationDenial {
            return .unknown(processIDEnumerationDenial)
        }
        return .resolved(processIDsValue)
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        activeCatalogCalls += 1
        maximumConcurrentCatalogCalls = max(maximumConcurrentCatalogCalls, activeCatalogCalls)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        activeCatalogCalls -= 1
        guard let evidence = try? discoveryCatalogEvidence(processID: processID) else {
            return .unknown(.unstableSnapshot)
        }
        return .resolved(evidence)
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        authorizationPassCount += 1
        if authorizationPassCount == 1, let authorizationGate {
            await authorizationGate.wait()
        }
        guard let catalog = try? discoveryCatalogEvidence(processID: processID),
              let identity = DebuggerLocalProcessIdentity(
                  processID: processID,
                  startTime: catalog.fingerprint.startTime,
                  realUserID: 501,
                  effectiveUserID: 501,
                  canonicalExecutablePath: catalog.fingerprint.canonicalExecutablePath,
                  executableDeviceID: 16,
                  executableFileID: UInt64(processID) + 100,
                  executableByteCount: 4_096,
                  executableSHA256: String(repeating: "a", count: 64),
                  architecture: .arm64,
                  machOUUID: nil,
                  codeIdentity: nil
              ) else {
            return .unknown(.unstableSnapshot)
        }
        return .resolved(.init(catalogEvidence: catalog, identity: identity))
    }
}

private extension DebuggerLocalProcessObservationPolicy {
    static let discoveryFixture = DebuggerLocalProcessObservationPolicy(
        hostRealUserID: 501,
        hostEffectiveUserID: 501,
        selfProcessID: 9_999,
        excludedInfrastructure: []
    )
}

private func discoveryCatalogEvidence(
    processID: Int32
) throws -> DebuggerLocalProcessCatalogEvidence {
    let start = try XCTUnwrap(
        DebuggerProcessStartIdentity(seconds: UInt64(processID) + 100, microseconds: 0)
    )
    let fingerprint = try XCTUnwrap(
        DebuggerLocalProcessCatalogFingerprint(
            processID: processID,
            startTime: start,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/Fixture-\(processID)",
            executableDeviceID: 16,
            executableFileID: UInt64(processID) + 100,
            executableByteCount: 4_096,
            executableChangeTimeNanoseconds: 1_000,
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        )
    )
    return .init(
        fingerprint: fingerprint,
        displayName: "Fixture \(processID)",
        parentProcessID: 1,
        savedUserID: 501,
        dynamicState: .init()
    )
}
