import XCTest

@testable import MacScope

@MainActor
final class WorkspaceStoreReconstructionIsolationTests: XCTestCase {
    func testBatchExecutionDoesNotMutateInteractiveWorkspaceOrNativePresentation() async throws {
        let initial = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        let store = WorkspaceStore(
            workspaceName: "interactive",
            snapshot: initial,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        let presentation = NativeDecompilerPresentationModel()
        let driveState = store.nativeDecompilerDriveContext.machine.state
        let executor = IsolationBatchExecutor()
        let jobID = isolationID(1)
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: jobID,
            executor: executor
        )
        let authority = try ReconstructionBatchAuthority(
            jobID: jobID,
            checkpointID: isolationID(2),
            checkpointRevision: 3,
            corpusManifestSHA256: String(repeating: "a", count: 64)
        )
        let task = ReconstructionTaskRecord(
            identity: try .init(
                taskID: isolationID(3),
                jobID: jobID,
                kind: .ingest,
                subject: nil,
                dependencyTaskIDs: [],
                operationContractIdentity: "reconstruction.ingest.v1",
                canonicalSHA256: String(repeating: "b", count: 64)
            ),
            state: .pending,
            diagnostic: nil
        )

        let results = try await scheduler.executeReadyTasks(
            [task], authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )
        XCTAssertEqual(results.map(\.outcome), [.completed])
        XCTAssertEqual(store.workspaceName, "interactive")
        XCTAssertTrue(store.snapshot.binaries.isEmpty)
        XCTAssertTrue(store.snapshot.analysisBySlot.isEmpty)
        XCTAssertEqual(store.nativeDecompilerDriveContext.machine.state, driveState)
        XCTAssertEqual(presentation.state, .idle)
    }
}

private actor IsolationBatchExecutor: ReconstructionBatchTaskExecuting {
    func execute(
        task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority,
        cancellation _: ReconstructionCancellation
    ) async -> ReconstructionTerminalTaskResult {
        .init(
            jobID: authority.jobID,
            taskID: task.identity.taskID,
            checkpointID: authority.checkpointID,
            checkpointRevision: authority.checkpointRevision,
            corpusManifestSHA256: authority.corpusManifestSHA256,
            outcome: .completed
        )
    }

    func pause() async {}
    func resume() async {}
    func retire() async {}
}

private func isolationID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "a0000000-0000-4000-8000-%012d", value))!
}
