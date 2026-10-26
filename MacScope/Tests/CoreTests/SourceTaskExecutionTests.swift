import Foundation
import XCTest
@testable import MacScope

final class SourceTaskExecutionTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private func fixture(contract: String = ReconstructionSourceExecutionTaskContract.oracle,
        state: ReconstructionTaskState = .pending, scoped: Bool = true) throws
        -> (ReconstructionTaskRecord, ReconstructionBatchAuthority, ReconstructionFunctionCoordinate) {
        let job = UUID()
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256, digest: digest, byteCount: 32))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: UUID(), imageSlot: .primary, selectedSliceIndex: nil,
                architecture: .arm64, machOIdentity: nil), analysisFingerprintSHA256: digest,
            startAddress: 0x1000, endAddressExclusive: 0x1010, boundarySchemaVersion: 1,
            functionUUIDHint: nil, symbolHint: nil)
        let task = ReconstructionTaskRecord(identity: try .make(taskID: UUID(), jobID: job,
            kind: .executeSource, subject: scoped ? .function(function) : nil, dependencyTaskIDs: [],
            operationContractIdentity: contract), state: state, diagnostic: nil)
        let authority = try ReconstructionBatchAuthority(jobID: job, checkpointID: UUID(),
            checkpointRevision: 1, corpusManifestSHA256: digest)
        return (task, authority, function)
    }
    private func oracle(function: ReconstructionFunctionCoordinate, jobID: UUID) throws -> ReconstructionSourceOracle {
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        // Synthetic captured output exercises task admission; it is not native execution evidence.
        let transcript = Data(harness.inputs.map { "\($0):7\n" }.joined().utf8)
        return try ReconstructionSourceOracleEvidence.admit(authority: .init(projectID: UUID(), jobID: jobID,
            function: function, execution: .init(originalImageSHA256: function.artifact.contentIdentity.digest,
                originalExecutableSHA256: digest, originalSourceSHA256: nil,
                harnessSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
                compilerSHA256: digest, sdkIdentitySHA256: digest, compileProfileSHA256: digest,
                compileArgumentsSHA256: digest, executionArgumentsSHA256: digest, producerSHA256: digest,
                standardOutput: transcript, sessionID: UUID(), requestID: UUID(), processIdentifier: 123,
                sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true), evidenceIDs: [UUID()]))
    }
    private func executor(source: (any ReconstructionSourceTaskExecuting)? = nil)
        -> (ReconstructionBatchTaskExecutor, SourceForbiddenAnalysisLane) {
        let forbidden = SourceForbiddenAnalysisLane()
        return (.init(resolver: forbidden, headless: forbidden, native: forbidden, sourceExecutor: source), forbidden)
    }

    func testTaskKindCodingKeepsExistingKindsAndSourceContractsOutsideOrdinaryModelContract() throws {
        for kind in ReconstructionTaskKind.allCases {
            XCTAssertEqual(try JSONDecoder().decode(ReconstructionTaskKind.self,
                from: JSONEncoder().encode(kind)), kind)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(ReconstructionTaskKind.self, from: Data("\"compile\"".utf8)))
        XCTAssertNotEqual(ReconstructionSourceExecutionTaskContract.oracle, ReconstructionProductionTaskContract.modelRound)
        XCTAssertNotEqual(ReconstructionSourceExecutionTaskContract.evaluate, ReconstructionProductionTaskContract.modelRound)
        XCTAssertEqual(ReconstructionSourceExecutionTaskContract.profileID, ReconstructionSourceOracle.profileID)
    }

    func testMissingExecutorFailsBeforeAnyAnalysisResolution() async throws {
        let (task, authority, _) = try fixture(), (executor, forbidden) = self.executor()
        let result = await executor.execute(task: task, authority: authority, cancellation: .init())
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(result.sourceExecution)
        let analysisCalls = await forbidden.calls
        XCTAssertEqual(analysisCalls, 0)
        let cancellation = ReconstructionCancellation(); cancellation.cancel()
        let cancelled = await executor.execute(task: task, authority: authority, cancellation: cancellation)
        XCTAssertEqual(cancelled.outcome, .cancelled)
    }

    func testInvalidContractMissingFunctionAndTerminalTaskDoNotReachInjectedExecutor() async throws {
        let source = SourceInjectedExecutor(), (executor, forbidden) = self.executor(source: source)
        for (contract, state, scoped) in [("model-selected-shell-command", ReconstructionTaskState.pending, true),
            (ReconstructionSourceExecutionTaskContract.oracle, .completed, true),
            (ReconstructionSourceExecutionTaskContract.evaluate, .pending, false)] {
            let (task, authority, _) = try fixture(contract: contract, state: state, scoped: scoped)
            let result = await executor.execute(task: task, authority: authority, cancellation: .init())
            XCTAssertEqual(result.outcome, .failed)
        }
        let sourceCalls = await source.calls, analysisCalls = await forbidden.calls
        XCTAssertEqual(sourceCalls, 0); XCTAssertEqual(analysisCalls, 0)
    }

    func testInjectedOracleIsRetainedOnlyUnderExactTaskJobAndCheckpointAuthority() async throws {
        let (task, authority, function) = try fixture()
        let value = try oracle(function: function, jobID: authority.jobID)
        let source = SourceInjectedExecutor(payload: .oracle(value)), (executor, forbidden) = self.executor(source: source)
        let result = await executor.execute(task: task, authority: authority, cancellation: .init())
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.sourceExecution, .oracle(value))
        XCTAssertNil(result.analysisProjection); XCTAssertNil(result.nativeResult); XCTAssertNil(result.loadedImageAdmission)
        let analysisCalls = await forbidden.calls
        XCTAssertEqual(analysisCalls, 0)
        let staleSource = SourceInjectedExecutor(payload: .oracle(value), wrongCheckpoint: true)
        let (staleExecutor, _) = self.executor(source: staleSource)
        let stale = await staleExecutor.execute(task: task, authority: authority, cancellation: .init())
        XCTAssertEqual(stale.outcome, .staleAuthority); XCTAssertNil(stale.sourceExecution)
        let wrongJob = try ReconstructionBatchAuthority(jobID: UUID(), checkpointID: authority.checkpointID,
            checkpointRevision: authority.checkpointRevision, corpusManifestSHA256: authority.corpusManifestSHA256)
        let wrong = await executor.execute(task: task, authority: wrongJob, cancellation: .init())
        XCTAssertEqual(wrong.outcome, .staleAuthority)
    }

    func testSchedulerRejectsCompletedSourceWithoutPayloadAndKeepsUnconfiguredFailure() async throws {
        let (task, authority, _) = try fixture()
        let forged = ReconstructionBatchScheduler(durableJobID: authority.jobID,
            executor: SourceInjectedExecutor(outcome: .completed))
        let forgedResults = try await forged.executeReadyTasks([task], authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1))
        XCTAssertEqual(forgedResults.first?.outcome, .staleAuthority)
        let (unconfigured, _) = self.executor()
        let scheduler = ReconstructionBatchScheduler(durableJobID: authority.jobID, executor: unconfigured)
        let failed = try await scheduler.executeReadyTasks([task], authority: authority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1))
        XCTAssertEqual(failed.first?.outcome, .failed)
    }

    func testCancellationAfterInjectedExecutionDiscardsPayloadAndLifecycleReachesSourceOwner() async throws {
        let (task, authority, function) = try fixture()
        let source = SourceInjectedExecutor(payload: .oracle(try oracle(function: function, jobID: authority.jobID)),
            cancelBeforeReturning: true)
        let (executor, _) = self.executor(source: source)
        let result = await executor.execute(task: task, authority: authority, cancellation: .init())
        XCTAssertEqual(result.outcome, .cancelled); XCTAssertNil(result.sourceExecution)
        await executor.pause(); await executor.resume(); await executor.retire()
        let counts = await source.lifecycle
        XCTAssertEqual(counts, [1, 1, 1])
    }

    func testSourceProgressAppearsOnlyWhenSourceTasksExist() throws {
        XCTAssertEqual(ReconstructionStatusProjection.emptyPhases.count, 5)
        XCTAssertEqual(ReconstructionStatusProjection.progressPhases(tasks: []).count, 5)
        let (task, _, _) = try fixture()
        let phases = ReconstructionStatusProjection.progressPhases(tasks: [task])
        let source = try XCTUnwrap(phases.first { $0.kind == .sourceExecution })
        XCTAssertEqual(phases.count, 6); XCTAssertEqual(source.total, 1); XCTAssertEqual(source.pending, 1)
        XCTAssertEqual(phases.first { $0.kind == .decompilation }?.total, 0)
    }

    func testEvaluationCannotCompleteWithoutLaunchedPhaseCleanup() throws {
        let (task, authority, function) = try fixture(contract: ReconstructionSourceExecutionTaskContract.evaluate)
        let outcome = ReconstructionSourceExecutionWorkflow.Outcome(
            sourceAuthority: .admittedRevision(revisionSHA256: digest), function: function,
            sourceSHA256: digest, harnessSHA256: digest,
            toolAuthority: .init(compilerPath: "/Applications/Xcode-beta.app/clang",
                sdkRootPath: "/Applications/Xcode-beta.app/sdk", toolchainRootPath: "/Applications/Xcode-beta.app/toolchain",
                runnerSHA256: digest, compilerSHA256: digest, sdkSettingsSHA256: digest),
            oracleSuiteSHA256: digest, phases: [], inspection: nil, astAdmission: nil, executable: nil,
            observations: [], mismatches: [], failure: .invalidAuthority)
        XCTAssertFalse(ReconstructionSourceTaskExecutionPayload.evaluation(outcome).isValid(for: task, authority: authority))
    }
}

private actor SourceForbiddenAnalysisLane: ReconstructionHeadlessAnalysisRequestResolving,
    ReconstructionHeadlessAnalysisExecuting, ReconstructionNativeTaskDecompiling {
    private(set) var calls = 0
    func request(for task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority) async throws
        -> ReconstructionHeadlessAnalysisRequest { calls += 1; throw CancellationError() }
    func execute(_ request: ReconstructionHeadlessAnalysisRequest, cancellation: ReconstructionCancellation) async throws
        -> ReconstructionHeadlessAnalysisResult { calls += 1; throw CancellationError() }
    func decompile(_ request: ReconstructionNativeDecompilationRequest, cancellation: ReconstructionCancellation) async
        -> ReconstructionNativeTaskResult { calls += 1; return .failed(.providerUnavailable) }
    func pause() async {}
    func resume() async {}
    func retire() async {}
    func cancelOutstanding() async {}
}

private actor SourceInjectedExecutor: ReconstructionSourceTaskExecuting, ReconstructionBatchTaskExecuting {
    private let payload: ReconstructionSourceTaskExecutionPayload?
    private let outcome: ReconstructionTerminalTaskOutcome
    private let wrongCheckpoint: Bool
    private let cancelBeforeReturning: Bool
    private(set) var calls = 0
    private(set) var lifecycle = [0, 0, 0]
    init(payload: ReconstructionSourceTaskExecutionPayload? = nil, outcome: ReconstructionTerminalTaskOutcome = .completed,
        wrongCheckpoint: Bool = false, cancelBeforeReturning: Bool = false) {
        self.payload = payload; self.outcome = outcome; self.wrongCheckpoint = wrongCheckpoint
        self.cancelBeforeReturning = cancelBeforeReturning
    }
    func execute(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
        cancellation: ReconstructionCancellation) async -> ReconstructionTerminalTaskResult {
        calls += 1
        if cancelBeforeReturning { cancellation.cancel() }
        return .init(jobID: authority.jobID, taskID: task.identity.taskID,
            checkpointID: wrongCheckpoint ? UUID() : authority.checkpointID,
            checkpointRevision: authority.checkpointRevision, corpusManifestSHA256: authority.corpusManifestSHA256,
            outcome: outcome, sourceExecution: payload)
    }
    func pause() async { lifecycle[0] += 1 }
    func resume() async { lifecycle[1] += 1 }
    func retire() async { lifecycle[2] += 1 }
}
