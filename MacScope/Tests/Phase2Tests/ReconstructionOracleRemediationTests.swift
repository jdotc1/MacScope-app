import Foundation
import XCTest

@testable import MacScope

@MainActor
final class ReconstructionAppAuthorityBindingTests: XCTestCase {
    func testReconstructionSchedulerRetainsAndRejectsAgainstExactDurableJobID() async throws {
        let boundJobID = remediationID("a1", 1)
        let foreignJobID = remediationID("b1", 1)
        let durable = RemediationDurableValidator(expectedJobID: boundJobID)
        let resolver = RemediationResolverProbe()
        let providerFactory = RemediationProviderFactory()
        let services = MacScopeAppRuntimeServices.testing(
            debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities(),
            nativeDecompilerRuntime: .productionShared
        )
        let scheduler = try await services.reconstructionBatchScheduler(
            durableJobID: boundJobID,
            durable: durable,
            resolver: resolver,
            providerFactory: providerFactory,
            analysisBudget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            )
        )
        let foreignTask = try remediationTask(
            jobID: foreignJobID,
            taskID: remediationID("b2", 1)
        )
        let foreignAuthority = try remediationAuthority(
            jobID: foreignJobID,
            checkpointID: remediationID("b3", 1)
        )

        do {
            _ = try await scheduler.executeReadyTasks(
                [foreignTask],
                authority: foreignAuthority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
            XCTFail("The scheduler must reject authority from a different durable job.")
        } catch let error as ReconstructionBatchSchedulerError {
            XCTAssertEqual(
                error,
                .jobAuthorityMismatch(
                    expected: boundJobID,
                    actual: foreignJobID
                )
            )
        }

        let validatedJobIDs = await durable.validatedJobIDs
        let resolverRequestCount = await resolver.requestCount
        XCTAssertEqual(validatedJobIDs, [boundJobID])
        XCTAssertEqual(resolverRequestCount, 0)
        XCTAssertEqual(providerFactory.makeProviderCount, 0)

        await scheduler.retire(jobID: boundJobID)
    }
}

final class ReconstructionProviderPoolRemediationTests: XCTestCase {
    func testBudgetFailsClosedWithoutUsableMemoryAndAvoidsIntegerConversionTrap() throws {
        let budget = ReconstructionAnalysisProviderPoolBudget(
            maximumActiveAnalyses: 6,
            estimatedResidentBytesPerAnalysis: 2_000,
            reservedHostBytes: 4_000
        )

        XCTAssertThrowsError(
            try budget.width(processorCount: 8, physicalMemory: 4_000)
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionAnalysisProviderPoolBudgetError,
                .insufficientHostMemory
            )
        }
        XCTAssertThrowsError(
            try budget.width(processorCount: 8, physicalMemory: 5_000)
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionAnalysisProviderPoolBudgetError,
                .insufficientHostMemory
            )
        }
        XCTAssertEqual(
            try budget.width(
                processorCount: Int.max,
                physicalMemory: UInt64.max
            ),
            6
        )
    }

    func testCancellingQueuedWaiterRemovesItBeforeProviderRelease() async throws {
        let factory = RemediationProviderFactory()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: factory,
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 8
        )
        let leaseGate = RemediationAsyncGate()
        let queuedOperation = RemediationCounter()

        let active = Task {
            try await pool.withProvider { _ in
                await leaseGate.wait()
                return "active"
            }
        }
        await waitUntilRemediation { await leaseGate.waiterCount == 1 }

        let queued = Task {
            try await pool.withProvider { _ in
                await queuedOperation.increment()
                return "queued"
            }
        }
        await waitUntilRemediation {
            await pool.snapshot().queuedWaiterCount == 1
        }

        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("A cancelled queued waiter must not receive a provider.")
        } catch is CancellationError {
            // Expected.
        }

        let cancelledSnapshot = await pool.snapshot()
        let queuedOperationCount = await queuedOperation.value
        XCTAssertEqual(cancelledSnapshot.queuedWaiterCount, 0)
        XCTAssertEqual(queuedOperationCount, 0)

        await leaseGate.open()
        let activeValue = try await active.value
        XCTAssertEqual(activeValue, "active")
        XCTAssertEqual(factory.makeProviderCount, 1)
    }

    func testCancellationBetweenPrecheckAndWaiterEnqueueCannotBeLost() async throws {
        let factory = RemediationProviderFactory()
        let leaseGate = RemediationAsyncGate()
        let enqueueGate = RemediationAsyncGate()
        let queuedOperation = RemediationCounter()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: factory,
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 8,
            hooks: .init(beforeWaiterEnqueue: { _ in
                await enqueueGate.wait()
            })
        )

        let active = Task {
            try await pool.withProvider { _ in
                await leaseGate.wait()
                return "active"
            }
        }
        await waitUntilRemediation { await leaseGate.waiterCount == 1 }

        let queued = Task {
            try await pool.withProvider { _ in
                await queuedOperation.increment()
                return "queued"
            }
        }
        await waitUntilRemediation { await enqueueGate.waiterCount == 1 }
        queued.cancel()
        await enqueueGate.open()

        do {
            _ = try await queued.value
            XCTFail("Cancellation before enqueue must fail instead of suspending the waiter.")
        } catch is CancellationError {
            // Expected.
        }

        let cancelledSnapshot = await pool.snapshot()
        let queuedOperationCount = await queuedOperation.value
        XCTAssertEqual(cancelledSnapshot.queuedWaiterCount, 0)
        XCTAssertEqual(queuedOperationCount, 0)

        await leaseGate.open()
        let activeValue = try await active.value
        XCTAssertEqual(activeValue, "active")
        XCTAssertEqual(factory.makeProviderCount, 1)
    }
}

final class ReconstructionSchedulerRemediationTests: XCTestCase {
    func testBoundSchedulerRejectsDifferentJobBeforeExecutorAdmission() async throws {
        let boundJobID = remediationID("c1", 1)
        let foreignJobID = remediationID("d1", 1)
        let executor = RemediationBatchExecutor()
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: boundJobID,
            executor: executor
        )
        let authority = try remediationAuthority(
            jobID: foreignJobID,
            checkpointID: remediationID("d3", 1)
        )
        let task = try remediationTask(
            jobID: foreignJobID,
            taskID: remediationID("d2", 1)
        )

        do {
            _ = try await scheduler.executeReadyTasks(
                [task],
                authority: authority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
            XCTFail("A scheduler bound to one durable job must reject foreign authority.")
        } catch let error as ReconstructionBatchSchedulerError {
            XCTAssertEqual(
                error,
                .jobAuthorityMismatch(expected: boundJobID, actual: foreignJobID)
            )
        }

        let executedTaskIDs = await executor.executedTaskIDs
        XCTAssertTrue(executedTaskIDs.isEmpty)
    }

    func testPauseRequiresExplicitResumeAndRetireFailsClosed() async throws {
        let jobID = remediationID("e1", 1)
        let authority = try remediationAuthority(
            jobID: jobID,
            checkpointID: remediationID("e3", 1)
        )
        let task = try remediationTask(
            jobID: jobID,
            taskID: remediationID("e2", 1)
        )
        let gate = RemediationAsyncGate()
        let executor = RemediationBatchExecutor(gate: gate)
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: executor
        )

        let active = Task {
            try await scheduler.executeReadyTasks(
                [task],
                authority: authority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
        }
        await waitUntilRemediation { await executor.executedTaskIDs.count == 1 }
        await scheduler.pause(jobID: jobID)
        await gate.open()
        let stale = try await active.value
        XCTAssertEqual(stale.map(\.outcome), [.staleAuthority])

        do {
            _ = try await scheduler.executeReadyTasks(
                [task],
                authority: authority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
            XCTFail("Paused work must not restart until explicit resume.")
        } catch let error as ReconstructionBatchSchedulerError {
            XCTAssertEqual(error, .jobPaused(jobID))
        }

        await scheduler.resume(jobID: jobID)
        let resumed = try await scheduler.executeReadyTasks(
            [task],
            authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )
        XCTAssertEqual(resumed.map(\.outcome), [.completed])

        await scheduler.retire(jobID: jobID)
        await scheduler.retire(jobID: jobID)
        do {
            _ = try await scheduler.executeReadyTasks(
                [task],
                authority: authority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
            XCTFail("A retired scheduler must fail closed, not return an empty result.")
        } catch let error as ReconstructionBatchSchedulerError {
            XCTAssertEqual(error, .jobRetired(jobID))
        }

        let cancelCount = await executor.cancelCount
        let retireCount = await executor.retireCount
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(retireCount, 1)
    }

    func testForeignLifecycleCommandsCannotAffectBoundJob() async throws {
        let jobID = remediationID("f1", 1)
        let foreignJobID = remediationID("f1", 2)
        let authority = try remediationAuthority(
            jobID: jobID,
            checkpointID: remediationID("f3", 1)
        )
        let task = try remediationTask(
            jobID: jobID,
            taskID: remediationID("f2", 1)
        )
        let executor = RemediationBatchExecutor()
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: executor
        )

        await scheduler.pause(jobID: foreignJobID)
        await scheduler.resume(jobID: foreignJobID)
        await scheduler.retire(jobID: foreignJobID)

        let results = try await scheduler.executeReadyTasks(
            [task],
            authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )
        let cancelCount = await executor.cancelCount
        let retireCount = await executor.retireCount
        XCTAssertEqual(results.map(\.outcome), [.completed])
        XCTAssertEqual(cancelCount, 0)
        XCTAssertEqual(retireCount, 0)
    }
}

private actor RemediationDurableValidator:
    ReconstructionNativeDecompilerDurableJobValidating
{
    enum ValidationError: Error {
        case unexpectedJobID
    }

    private let expectedJobID: UUID
    private(set) var validatedJobIDs: [UUID] = []

    init(expectedJobID: UUID) {
        self.expectedJobID = expectedJobID
    }

    func validateActiveDurableJobID(_ jobID: UUID) async throws {
        validatedJobIDs.append(jobID)
        guard jobID == expectedJobID else {
            throw ValidationError.unexpectedJobID
        }
    }
}

private actor RemediationResolverProbe:
    ReconstructionHeadlessAnalysisRequestResolving
{
    enum ProbeError: Error {
        case unexpectedRequest
    }

    private(set) var requestCount = 0

    func request(
        for task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority
    ) async throws -> ReconstructionHeadlessAnalysisRequest {
        requestCount += 1
        throw ProbeError.unexpectedRequest
    }
}

private final class RemediationProviderFactory:
    ReconstructionAnalysisProviderFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedMakeProviderCount = 0

    var makeProviderCount: Int {
        lock.withLock { storedMakeProviderCount }
    }

    func makeProvider() -> any AnalysisProviding {
        lock.withLock { storedMakeProviderCount += 1 }
        return RemediationUnusedAnalysisProvider()
    }
}

private struct RemediationUnusedAnalysisProvider: AnalysisProviding {
    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("remediation tests do not execute provider analysis")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        fatalError("remediation tests do not execute provider analysis")
    }
}

private actor RemediationBatchExecutor: ReconstructionBatchTaskExecuting {
    private let gate: RemediationAsyncGate?
    private(set) var executedTaskIDs: [UUID] = []
    private(set) var cancelCount = 0
    private(set) var retireCount = 0

    init(gate: RemediationAsyncGate? = nil) {
        self.gate = gate
    }

    func execute(
        task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionTerminalTaskResult {
        executedTaskIDs.append(task.identity.taskID)
        if let gate {
            await gate.wait()
        }
        return .init(
            jobID: authority.jobID,
            taskID: task.identity.taskID,
            checkpointID: authority.checkpointID,
            checkpointRevision: authority.checkpointRevision,
            corpusManifestSHA256: authority.corpusManifestSHA256,
            outcome: .completed
        )
    }

    func pause() async {
        cancelCount += 1
    }

    func resume() async {}

    func retire() async {
        retireCount += 1
    }
}

private actor RemediationAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int {
        waiters.count
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor RemediationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func waitUntilRemediation(
    _ predicate: @Sendable @escaping () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200_000 {
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("remediation condition did not settle", file: file, line: line)
}

private func remediationTask(jobID: UUID, taskID: UUID) throws -> ReconstructionTaskRecord {
    .init(
        identity: try .init(
            taskID: taskID,
            jobID: jobID,
            kind: .ingest,
            subject: nil,
            dependencyTaskIDs: [],
            operationContractIdentity: "reconstruction.ingest.v1",
            canonicalSHA256: String(repeating: "3", count: 64)
        ),
        state: .pending,
        diagnostic: nil
    )
}

private func remediationAuthority(
    jobID: UUID,
    checkpointID: UUID
) throws -> ReconstructionBatchAuthority {
    try .init(
        jobID: jobID,
        checkpointID: checkpointID,
        checkpointRevision: 1,
        corpusManifestSHA256: String(repeating: "4", count: 64)
    )
}

private func remediationID(_ prefix: String, _ value: Int) -> UUID {
    UUID(
        uuidString: String(
            format: "%@000000-0000-4000-8000-%012d",
            prefix,
            value
        )
    )!
}
