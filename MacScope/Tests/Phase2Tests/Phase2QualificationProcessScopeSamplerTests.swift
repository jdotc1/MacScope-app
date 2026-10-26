import XCTest
@testable import MacScope

final class Phase2QualificationProcessScopeSamplerTests: XCTestCase {
    func testScopeIdentityIsDeterministicAndAvailable() throws {
        let first = try XCTUnwrap(makeSampler(baselineObserver()))
        let second = try XCTUnwrap(makeSampler(baselineObserver()))

        XCTAssertEqual(first.scopeIdentity, second.scopeIdentity)
        XCTAssertEqual(
            first.scopeIdentity.id,
            "phase2.r1.qualification-process-scope.v1"
        )
        XCTAssertEqual(first.scopeIdentity.version, 1)
        XCTAssertEqual(first.scopeIdentity.availability, .available)
        XCTAssertNotNil(first.scopeIdentity.sha256)
    }

    func testScopeIdentityChangesWithRolePIDStartOrExecutableIdentity() throws {
        let baseline = try XCTUnwrap(makeSampler(baselineObserver())).scopeIdentity
        let roleChanged = try XCTUnwrap(Phase2QualificationProcessScopeSampler(
            appProcessID: 20,
            aiWorkerProcessID: 10,
            providerProcessID: 30,
            observer: baselineObserver()
        )).scopeIdentity

        let pidObserver = TestProcessObserver(
            observations: [
                11: process(11, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
            ],
            children: [30: []]
        )
        let pidChanged = try XCTUnwrap(Phase2QualificationProcessScopeSampler(
            appProcessID: 11,
            aiWorkerProcessID: 20,
            providerProcessID: 30,
            observer: pidObserver
        )).scopeIdentity

        let startObserver = baselineObserver()
        startObserver.set(process(10, parent: 1, startSeconds: 999, rss: 100))
        let startChanged = try XCTUnwrap(makeSampler(startObserver)).scopeIdentity

        let executableObserver = baselineObserver()
        executableObserver.set(process(10, parent: 1, digestByte: "f", rss: 100))
        let executableChanged = try XCTUnwrap(makeSampler(executableObserver)).scopeIdentity

        XCTAssertNotEqual(baseline, roleChanged)
        XCTAssertNotEqual(baseline, pidChanged)
        XCTAssertNotEqual(baseline, startChanged)
        XCTAssertNotEqual(baseline, executableChanged)
    }

    func testSamplerExposesExactCapturedBindingIdentity() throws {
        let app = process(10, parent: 1, rss: 100)
        let worker = process(20, parent: 1, rss: 200)
        let provider = process(30, parent: 20, rss: 300)
        let observer = TestProcessObserver(
            observations: [10: app, 20: worker, 30: provider],
            children: [30: []]
        )
        let binding = try Phase2QualificationProcessScopeBinding(
            app: app,
            aiWorker: worker,
            provider: provider
        )
        let sampler = try XCTUnwrap(makeSampler(observer))
        let boundSampler: any Phase2QualificationBoundResidentSetSampling = sampler

        XCTAssertEqual(boundSampler.scopeIdentity, binding.scopeIdentity)
    }

    func testStableLibprocRSSSamplerDeclaresContemporaneousSnapshots() throws {
        let sampler = try XCTUnwrap(makeSampler(baselineObserver()))

        XCTAssertEqual(sampler.measurementSemantics, .contemporaneousSnapshot)
    }

    func testBindingRejectsZeroExecutableDeviceIdentity() throws {
        let observer = TestProcessObserver(
            observations: [
                10: process(10, parent: 1, deviceID: 0, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
            ],
            children: [30: []]
        )

        XCTAssertNil(makeSampler(observer))
    }

    func testValidBoundRootsProduceExactThreeRootSum() throws {
        let observer = TestProcessObserver(
            observations: [
                10: process(10, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
            ],
            children: [30: []]
        )
        let sampler = try XCTUnwrap(makeSampler(observer))

        let snapshot = try XCTUnwrap(sampler.sample())

        XCTAssertEqual(snapshot.appBytes, 100)
        XCTAssertEqual(snapshot.aiWorkerBytes, 200)
        XCTAssertEqual(snapshot.providerBytes, 300)
    }

    func testProviderDescendantsAreEnumeratedRecursivelyAndSummedOnce() throws {
        let observer = TestProcessObserver(
            observations: [
                10: process(10, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
                31: process(31, parent: 30, rss: 400),
                32: process(32, parent: 30, rss: 500),
                33: process(33, parent: 31, rss: 600),
            ],
            children: [30: [31, 32], 31: [33], 32: [], 33: []]
        )
        let sampler = try XCTUnwrap(makeSampler(observer))

        let snapshot = try XCTUnwrap(sampler.sample())

        XCTAssertEqual(snapshot.providerBytes, 1_800)
    }

    func testRootOverlapAndDuplicateDescendantAreRejected() throws {
        let overlapObserver = TestProcessObserver(
            observations: [
                10: process(10, parent: 30, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
            ],
            children: [30: [10]]
        )
        let overlapSampler = try XCTUnwrap(makeSampler(overlapObserver))
        XCTAssertNil(try overlapSampler.sample())

        let duplicateObserver = TestProcessObserver(
            observations: [
                10: process(10, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
                31: process(31, parent: 30, rss: 400),
            ],
            children: [30: [31, 31], 31: []]
        )
        let duplicateSampler = try XCTUnwrap(makeSampler(duplicateObserver))
        XCTAssertNil(try duplicateSampler.sample())
    }

    func testMissingRootFailsClosed() throws {
        let observer = baselineObserver()
        let sampler = try XCTUnwrap(makeSampler(observer))
        observer.remove(processID: 20)

        XCTAssertNil(try sampler.sample())
    }

    func testRootPIDReuseOrStartTokenDriftFailsClosed() throws {
        let observer = baselineObserver()
        let sampler = try XCTUnwrap(makeSampler(observer))
        observer.set(process(10, parent: 1, startSeconds: 999, rss: 100))

        XCTAssertNil(try sampler.sample())
    }

    func testRootExecutableIdentityDriftFailsClosed() throws {
        let observer = baselineObserver()
        let sampler = try XCTUnwrap(makeSampler(observer))
        observer.set(process(20, parent: 1, digestByte: "f", rss: 200))

        XCTAssertNil(try sampler.sample())
    }

    func testParentDriftAndProviderTreeCycleFailClosed() throws {
        let rootDriftObserver = baselineObserver()
        let rootDriftSampler = try XCTUnwrap(makeSampler(rootDriftObserver))
        rootDriftObserver.set(process(30, parent: 99, rss: 300))
        XCTAssertNil(try rootDriftSampler.sample())

        let driftObserver = TestProcessObserver(
            observations: [
                10: process(10, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
                31: process(31, parent: 99, rss: 400),
            ],
            children: [30: [31], 31: []]
        )
        let driftSampler = try XCTUnwrap(makeSampler(driftObserver))
        XCTAssertNil(try driftSampler.sample())

        let cycleObserver = TestProcessObserver(
            observations: [
                10: process(10, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
                31: process(31, parent: 30, rss: 400),
            ],
            children: [30: [31], 31: [30]]
        )
        let cycleSampler = try XCTUnwrap(makeSampler(cycleObserver))
        XCTAssertNil(try cycleSampler.sample())
    }

    func testEnumerationFailureAndPartialDescendantScopeFailClosed() throws {
        let failureObserver = baselineObserver()
        let failureSampler = try XCTUnwrap(makeSampler(failureObserver))
        failureObserver.failEnumeration(processID: 30)
        XCTAssertNil(try failureSampler.sample())

        let partialObserver = TestProcessObserver(
            observations: [
                10: process(10, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
            ],
            children: [30: [31]]
        )
        let partialSampler = try XCTUnwrap(makeSampler(partialObserver))
        XCTAssertNil(try partialSampler.sample())
    }

    func testDescendantAppearingBetweenCompleteProviderTreesFailsClosed() throws {
        let observer = TestProcessObserver(
            observations: [
                10: process(10, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
                31: process(31, parent: 30, rss: 400),
            ],
            children: [30: [], 31: []]
        )
        observer.scriptChildren(processID: 30, snapshots: [[], [31]])
        let sampler = try XCTUnwrap(makeSampler(observer))

        XCTAssertNil(try sampler.sample())
    }

    func testResidentSetOverflowFailsClosed() throws {
        let observer = baselineObserver()
        let sampler = try XCTUnwrap(makeSampler(observer))
        observer.set(process(30, parent: 20, rss: UInt64.max))

        XCTAssertNil(try sampler.sample())
    }

    private func makeSampler(
        _ observer: TestProcessObserver
    ) -> Phase2QualificationProcessScopeSampler? {
        Phase2QualificationProcessScopeSampler(
            appProcessID: 10,
            aiWorkerProcessID: 20,
            providerProcessID: 30,
            observer: observer
        )
    }

    private func baselineObserver() -> TestProcessObserver {
        TestProcessObserver(
            observations: [
                10: process(10, parent: 1, rss: 100),
                20: process(20, parent: 1, rss: 200),
                30: process(30, parent: 20, rss: 300),
            ],
            children: [30: []]
        )
    }

    private func process(
        _ processID: Int32,
        parent: Int32,
        startSeconds: UInt64? = nil,
        deviceID: UInt64 = 1,
        digestByte: Character = "a",
        rss: UInt64
    ) -> Phase2QualificationProcessObservation {
        Phase2QualificationProcessObservation(
            processID: processID,
            parentProcessID: parent,
            startIdentity: .init(
                seconds: startSeconds ?? UInt64(processID), microseconds: 123
            ),
            executableIdentity: .init(
                deviceID: deviceID,
                fileID: UInt64(processID),
                sha256: String(repeating: digestByte, count: 64)
            ),
            residentBytes: rss
        )
    }
}

private final class TestProcessObserver: Phase2QualificationProcessObserving,
    @unchecked Sendable
{
    enum Failure: Error { case enumeration }

    private var observations: [Int32: Phase2QualificationProcessObservation]
    private var children: [Int32: [Int32]]
    private var scriptedChildren: [Int32: [[Int32]]] = [:]
    private var failedEnumerations: Set<Int32> = []
    private let lock = NSLock()

    init(
        observations: [Int32: Phase2QualificationProcessObservation],
        children: [Int32: [Int32]]
    ) {
        self.observations = observations
        self.children = children
    }

    func observation(
        processID: Int32
    ) throws -> Phase2QualificationProcessObservation? {
        lock.lock(); defer { lock.unlock() }
        return observations[processID]
    }

    func childProcessIDs(of processID: Int32) throws -> [Int32]? {
        lock.lock(); defer { lock.unlock() }
        if failedEnumerations.contains(processID) { throw Failure.enumeration }
        if var snapshots = scriptedChildren[processID], !snapshots.isEmpty {
            let next = snapshots.removeFirst()
            scriptedChildren[processID] = snapshots
            return next
        }
        return children[processID]
    }

    func set(_ observation: Phase2QualificationProcessObservation) {
        lock.lock(); defer { lock.unlock() }
        observations[observation.processID] = observation
    }

    func remove(processID: Int32) {
        lock.lock(); defer { lock.unlock() }
        observations.removeValue(forKey: processID)
    }

    func failEnumeration(processID: Int32) {
        lock.lock(); defer { lock.unlock() }
        failedEnumerations.insert(processID)
    }

    func scriptChildren(processID: Int32, snapshots: [[Int32]]) {
        lock.lock(); defer { lock.unlock() }
        scriptedChildren[processID] = snapshots
    }
}
