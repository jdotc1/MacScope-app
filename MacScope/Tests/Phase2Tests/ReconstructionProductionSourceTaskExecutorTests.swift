import Darwin
import Foundation
import XCTest
@testable import MacScope

/// Executor/lifecycle tests use the existing transport protocol with controlled responses only.
@MainActor
final class ReconstructionProductionSourceTaskExecutorTests: XCTestCase {
    func testMissingOracleAssemblerFailsClosedBeforeBrokerDispatch() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport()
        let executor = makeExecutor(fixture, transport: transport)
        let result = await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(result.sourceExecution)
        let diagnostic = await executor.diagnostic(for: fixture.task.identity.taskID)
        XCTAssertEqual(diagnostic?.reason, .oracleAssemblyUnavailable)
        XCTAssertNil(diagnostic?.actualOutcome)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testExactOriginalObservationAndOwnerAssemblerProduceCanonicalOracle() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let executor = makeExecutor(fixture, transport: TaskSourceTransport(), assembler: TaskOracleAssembler())
        let result = await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(result.outcome, .completed)
        guard case .oracle(let oracle)? = result.sourceExecution else { return XCTFail("Expected actual oracle payload") }
        XCTAssertEqual(oracle.function, fixture.function)
        XCTAssertEqual(oracle.outputs, Array(repeating: 7, count: 37))
        XCTAssertEqual(oracle.execution.originalExecutableSHA256, fixture.function.artifact.contentIdentity.digest)
        XCTAssertEqual(try ReconstructionSourceOracleEvidence.decodeAndValidateCanonical(
            payload: ReconstructionSourceOracleEvidence.encode(oracle)), oracle)
        let diagnostic = await executor.diagnostic(for: fixture.task.identity.taskID)
        XCTAssertNil(diagnostic)
    }
    func testAssemblerCannotReplaceActualObservedOutputOrToolIdentity() async throws {
        for edit in [TaskOracleAssembler.Edit.stdout, .compiler] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let executor = makeExecutor(fixture, transport: TaskSourceTransport(), assembler: TaskOracleAssembler(edit: edit))
            let result = await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
            XCTAssertEqual(result.outcome, .failed)
            let diagnostic = await executor.diagnostic(for: fixture.task.identity.taskID)
            XCTAssertEqual(diagnostic?.reason, .invalidOracle)
            XCTAssertEqual(diagnostic?.actualOutcome?.phases.count, 3)
            XCTAssertEqual(diagnostic?.actualOutcome?.observations.map(\.output), Array(repeating: 7, count: 37))
        }
    }
    func testEvaluationMatchAndMismatchRemainActualCompletedEvaluations() async throws {
        for mismatch in [false, true] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let oracle = try validatedOracle(fixture)
            let revisionAuthority = ReconstructionSourceRevisionAuthority(projectID: fixture.project,
                jobID: fixture.batch.jobID, function: fixture.function, objectiveSHA256: hash("objective"),
                evidenceFrontierSHA256: hash("frontier"), oracleSuiteSHA256: oracle.oracle.suiteSHA256,
                admissibleEvidenceIDs: Set(oracle.oracle.evidenceIDs), currentRevision: nil)
            let source = Data("#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x; }\n".utf8)
            let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: .init(sourceUTF8: source,
                claimedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source),
                evidenceIDs: oracle.oracle.evidenceIDs), authority: revisionAuthority)
            let stage = try ReconstructionSourceExecutionStage.create(revision: revision, authority: revisionAuthority,
                harness: ReconstructionSourceBehaviorHarness.saturatingIncrementV1(), parent: fixture.parent)
            let task = ReconstructionTaskRecord(identity: try .make(taskID: UUID(), jobID: fixture.batch.jobID,
                kind: .executeSource, subject: .function(fixture.function), dependencyTaskIDs: [],
                operationContractIdentity: ReconstructionSourceExecutionTaskContract.evaluate), state: .pending, diagnostic: nil)
            let resolver = TaskSourceResolver(resolution: .init(projectID: fixture.project, taskID: task.identity.taskID,
                authority: fixture.batch, work: .evaluation(.init(stage: stage, revision: revision,
                    authority: revisionAuthority, oracle: oracle))))
            let executor = ReconstructionProductionSourceTaskExecutor(resolver: resolver,
                workflow: .init(transport: TaskSourceTransport(mismatch: mismatch), toolAuthority: tools))
            let result = await executor.execute(task: task, authority: fixture.batch, cancellation: .init())
            XCTAssertEqual(result.outcome, .completed)
            guard case .evaluation(let actual)? = result.sourceExecution else { return XCTFail("Expected actual evaluation") }
            XCTAssertEqual(actual.phases.count, 3)
            XCTAssertEqual(actual.matchesOracle, !mismatch)
            XCTAssertEqual(actual.failure, mismatch ? .behaviorMismatch : nil)
            XCTAssertEqual(actual.mismatches.count, mismatch ? 1 : 0)
        }
    }

    func testCompileExitOneIsCompletedNegativeEvaluationWithoutAcceptance() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport(compileFailure: true)
        let (task, executor) = try evaluationExecutor(fixture, transport: transport)
        let result = await executor.execute(task: task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(result.outcome, .completed)
        guard case .evaluation(let outcome)? = result.sourceExecution else { return XCTFail("Expected observed compile rejection") }
        XCTAssertEqual(outcome.failure, .phaseRejected(.compile))
        XCTAssertFalse(outcome.matchesOracle)
        XCTAssertTrue(outcome.observations.isEmpty)
        XCTAssertEqual(outcome.phases.map(\.request.operation), [.inspect, .compile])
        XCTAssertEqual(outcome.phases.last?.response?.terminal, .init(kind: .exited, status: 1))
        XCTAssertEqual(outcome.phases.last?.response?.diagnostics, Data("controlled clang rejection".utf8))
        XCTAssertTrue(try XCTUnwrap(result.sourceExecution).isValid(for: task, authority: fixture.batch))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.operation), [.inspect, .compile])
    }

    func testASTRejectionIsCompletedNegativeEvaluationBeforeCompilation() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport(rejectAST: true)
        let (task, executor) = try evaluationExecutor(fixture, transport: transport)
        let result = await executor.execute(task: task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(result.outcome, .completed)
        guard case .evaluation(let outcome)? = result.sourceExecution else { return XCTFail("Expected observed AST rejection") }
        guard case .astRejected? = outcome.failure else { return XCTFail("Expected exact typed AST failure") }
        XCTAssertFalse(outcome.matchesOracle)
        XCTAssertNotNil(outcome.inspection)
        XCTAssertNil(outcome.astAdmission)
        XCTAssertNil(outcome.executable)
        XCTAssertTrue(outcome.observations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(result.sourceExecution).isValid(for: task, authority: fixture.batch))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.operation), [.inspect])
    }

    func testUnknownCleanupCannotBecomeCompletedNegativeEvaluation() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport(compileFailure: true, unknownCleanup: true)
        let (task, executor) = try evaluationExecutor(fixture, transport: transport)
        let result = await executor.execute(task: task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(result.sourceExecution)
        let diagnostic = await executor.diagnostic(for: task.identity.taskID)
        XCTAssertEqual(diagnostic?.actualOutcome?.failure, .phaseRejected(.compile))
        XCTAssertEqual(diagnostic?.actualOutcome?.phases.last?.response?.cleanup?.outcome.kind, .outcomeUnknown)
    }

    /// F2b: a failed source task carries its concrete failure (reason kind, failing broker phase,
    /// error/cleanup kind) into the terminal result, which becomes the durable task diagnostic and
    /// the job's terminal reason, instead of "Deterministic reconstruction task failed".
    func testFailedSourceTaskRecordsConcreteFailureDiagnostic() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport(compileFailure: true, unknownCleanup: true)
        let (task, executor) = try evaluationExecutor(fixture, transport: transport)
        let result = await executor.execute(task: task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(result.outcome, .failed)
        let text = try XCTUnwrap(result.failureDiagnostic?.text)
        XCTAssertTrue(text.hasPrefix("compile phase rejected"), text)
        XCTAssertTrue(text.contains("phase=compile"), text)
        XCTAssertTrue(text.contains("brokerError=cleanupFailed"), text)
        XCTAssertTrue(text.contains("cleanup=outcomeUnknown"), text)
        XCTAssertTrue(text.contains("diagnostics: controlled clang rejection"), text)
        XCTAssertNotEqual(text, "Deterministic reconstruction task failed.")
        // Completed results never carry a failure diagnostic.
        let completed = await makeExecutor(fixture, transport: TaskSourceTransport(), assembler: TaskOracleAssembler())
            .execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(completed.outcome, .completed)
        XCTAssertNil(completed.failureDiagnostic)
        XCTAssertEqual(ReconstructionProductionSourceTaskExecutor.failureText(
            reason: .resolutionFailed("missing oracle"), actualOutcome: nil), "source resolution failed: missing oracle")
    }

    func testStaleResolverCutAndJobMismatchNeverDispatch() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport()
        let stale = try ReconstructionBatchAuthority(jobID: fixture.batch.jobID, checkpointID: UUID(),
            checkpointRevision: fixture.batch.checkpointRevision, corpusManifestSHA256: fixture.batch.corpusManifestSHA256)
        let resolver = TaskSourceResolver(resolution: .init(projectID: fixture.project, taskID: fixture.task.identity.taskID,
            authority: stale, work: .oracle(.qualified(stage: fixture.stage, function: fixture.function))))
        let executor = ReconstructionProductionSourceTaskExecutor(resolver: resolver,
            workflow: .init(transport: transport, toolAuthority: tools), oracleAssembler: TaskOracleAssembler())
        let result = await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(result.outcome, .staleAuthority)
        let wrongJob = try ReconstructionBatchAuthority(jobID: UUID(), checkpointID: fixture.batch.checkpointID,
            checkpointRevision: fixture.batch.checkpointRevision, corpusManifestSHA256: fixture.batch.corpusManifestSHA256)
        let wrong = await executor.execute(task: fixture.task, authority: wrongJob, cancellation: .init())
        XCTAssertEqual(wrong.outcome, .staleAuthority)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
    func testPauseAndRetireAwaitActualCleanupAndRefuseNewAdmissions() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport(waitForCancellation: true)
        let executor = makeExecutor(fixture, transport: transport, assembler: TaskOracleAssembler())
        let pending = Task { await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init()) }
        try await waitForDispatch(transport)
        await executor.pause()
        let result = await pending.value
        XCTAssertEqual(result.outcome, .cancelled)
        let diagnostic = await executor.diagnostic(for: fixture.task.identity.taskID)
        XCTAssertEqual(diagnostic?.actualOutcome?.phases.first?.response?.cleanup?.observedProcessAbsent, true)
        XCTAssertEqual(diagnostic?.actualOutcome?.phases.first?.response?.diagnostics, Data("actual cleanup diagnostic".utf8))
        let paused = await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(paused.outcome, .cancelled)
        await executor.resume()
        await executor.retire()
        await executor.resume()
        let retired = await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(retired.outcome, .failed)
        let retiredDiagnostic = await executor.diagnostic(for: fixture.task.identity.taskID)
        XCTAssertEqual(retiredDiagnostic?.reason, .retired)
    }
    func testCleanupFailureRetainsActualOutcomeWithoutCompletedPayload() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let executor = makeExecutor(fixture, transport: TaskSourceTransport(failCleanup: true), assembler: TaskOracleAssembler())
        let result = await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(result.sourceExecution)
        let diagnostic = await executor.takeDiagnostic(for: fixture.task.identity.taskID)
        XCTAssertEqual(diagnostic?.actualOutcome?.phases.first?.response?.cleanup?.observedProcessAbsent, false)
        XCTAssertEqual(diagnostic?.reason, .workflowFailed(.phaseRejected(.inspect)))
        let consumed = await executor.diagnostic(for: fixture.task.identity.taskID)
        XCTAssertNil(consumed)
    }
    func testOnlyOneActiveTaskIsAdmittedAndParentCancellationWaitsForCleanup() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport(waitForCancellation: true)
        let executor = makeExecutor(fixture, transport: transport, assembler: TaskOracleAssembler())
        let pending = Task { await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init()) }
        try await waitForDispatch(transport)
        let duplicate = await executor.execute(task: fixture.task, authority: fixture.batch, cancellation: .init())
        XCTAssertEqual(duplicate.outcome, .failed)
        let busy = await executor.diagnostic(for: fixture.task.identity.taskID)
        XCTAssertEqual(busy?.reason, .busy)
        pending.cancel()
        let result = await pending.value
        XCTAssertEqual(result.outcome, .cancelled)
        let diagnostic = await executor.diagnostic(for: fixture.task.identity.taskID)
        XCTAssertEqual(diagnostic?.reason, .cancelled)
        XCTAssertEqual(diagnostic?.actualOutcome?.phases.first?.response?.cleanup?.observedProcessAbsent, true)
    }
    func testDiagnosticRetentionIsBoundedAndCancelledAdmissionDoesNotResolve() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = TaskSourceTransport(), executor = makeExecutor(fixture, transport: transport)
        await executor.retire()
        var ids: [UUID] = []
        for _ in 0..<65 {
            let task = try task(function: fixture.function, job: fixture.batch.jobID)
            ids.append(task.identity.taskID)
            _ = await executor.execute(task: task, authority: fixture.batch, cancellation: .init())
        }
        let first = await executor.diagnostic(for: ids[0]), last = await executor.diagnostic(for: ids[64])
        XCTAssertNil(first)
        XCTAssertEqual(last?.reason, .retired)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private struct Fixture {
        let parent: URL
        let stage: ReconstructionSourceExecutionStage
        let function: ReconstructionFunctionCoordinate
        let task: ReconstructionTaskRecord
        let batch: ReconstructionBatchAuthority
        let project: UUID
    }
    private func evaluationExecutor(_ fixture: Fixture, transport: TaskSourceTransport) throws
        -> (ReconstructionTaskRecord, ReconstructionProductionSourceTaskExecutor) {
        let oracle = try validatedOracle(fixture)
        let authority = ReconstructionSourceRevisionAuthority(projectID: fixture.project,
            jobID: fixture.batch.jobID, function: fixture.function, objectiveSHA256: hash("objective"),
            evidenceFrontierSHA256: hash("frontier"), oracleSuiteSHA256: oracle.oracle.suiteSHA256,
            admissibleEvidenceIDs: Set(oracle.oracle.evidenceIDs), currentRevision: nil)
        let source = Data("#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x; }\n".utf8)
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: .init(sourceUTF8: source,
            claimedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source),
            evidenceIDs: oracle.oracle.evidenceIDs), authority: authority)
        let stage = try ReconstructionSourceExecutionStage.create(revision: revision, authority: authority,
            harness: ReconstructionSourceBehaviorHarness.saturatingIncrementV1(), parent: fixture.parent)
        let task = ReconstructionTaskRecord(identity: try .make(taskID: UUID(), jobID: fixture.batch.jobID,
            kind: .executeSource, subject: .function(fixture.function), dependencyTaskIDs: [],
            operationContractIdentity: ReconstructionSourceExecutionTaskContract.evaluate), state: .pending, diagnostic: nil)
        let resolver = TaskSourceResolver(resolution: .init(projectID: fixture.project, taskID: task.identity.taskID,
            authority: fixture.batch, work: .evaluation(.init(stage: stage, revision: revision,
                authority: authority, oracle: oracle))))
        return (task, .init(resolver: resolver, workflow: .init(transport: transport, toolAuthority: tools)))
    }

    private func makeExecutor(_ fixture: Fixture, transport: TaskSourceTransport,
                              assembler: TaskOracleAssembler? = nil) -> ReconstructionProductionSourceTaskExecutor {
        .init(resolver: TaskSourceResolver(resolution: .init(projectID: fixture.project, taskID: fixture.task.identity.taskID,
            authority: fixture.batch, work: .oracle(.qualified(stage: fixture.stage, function: fixture.function)))),
            workflow: .init(transport: transport, toolAuthority: tools), oracleAssembler: assembler)
    }
    private var tools: ReconstructionSourceExecutionWorkflow.ToolAuthority {
        .init(compilerPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            sdkRootPath: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            toolchainRootPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
            runnerSHA256: hash("runner"), compilerSHA256: hash("compiler"), sdkSettingsSHA256: hash("sdk"))
    }
    private func hash(_ value: String) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(Data(value.utf8)) }
    private func task(function: ReconstructionFunctionCoordinate, job: UUID) throws -> ReconstructionTaskRecord {
        .init(identity: try .make(taskID: UUID(), jobID: job, kind: .executeSource, subject: .function(function),
            dependencyTaskIDs: [], operationContractIdentity: ReconstructionSourceExecutionTaskContract.oracle),
            state: .pending, diagnostic: nil)
    }
    private func fixture() throws -> Fixture {
        let binary = Data("controlled task executable".utf8)
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256, digest: ReconstructionSourceRevisionAdmission.sourceSHA256(binary),
                                     byteCount: UInt64(binary.count)))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: UUID(), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: hash("analysis"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let source = Data("#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x; }\n".utf8)
        let parent = TestWorkRoot.authority.appendingPathComponent("source-task-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stage = try ReconstructionSourceExecutionStage.createOriginalAuthority(sourceUTF8: source,
            expectedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source),
            harness: ReconstructionSourceBehaviorHarness.saturatingIncrementV1(), parent: parent)
        let job = UUID(), batch = try ReconstructionBatchAuthority(jobID: job, checkpointID: UUID(),
            checkpointRevision: 1, corpusManifestSHA256: hash("manifest"))
        return .init(parent: parent, stage: stage, function: function, task: try task(function: function, job: job),
                     batch: batch, project: UUID())
    }
    private func validatedOracle(_ fixture: Fixture) throws -> ReconstructionSourceExecutionWorkflow.ValidatedOracle {
        let taskID = UUID(), receiptID = UUID(), outputID = UUID(), baseID = UUID()
        let initial = try ReconstructionProducerIdentity(macScopeBuildIdentity: hash("build"), macScopeSourceIdentity: hash("source"),
            operationIdentity: ReconstructionSourceOracleEvidence.operationID, registryIdentity: hash("registry"),
            protocolIdentity: hash("protocol"), toolchainIdentity: hash("toolchain"), canonicalSHA256: hash("placeholder"))
        let producer = try ReconstructionProducerIdentity(macScopeBuildIdentity: initial.macScopeBuildIdentity,
            macScopeSourceIdentity: initial.macScopeSourceIdentity, operationIdentity: initial.operationIdentity,
            registryIdentity: initial.registryIdentity, protocolIdentity: initial.protocolIdentity,
            toolchainIdentity: initial.toolchainIdentity, canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(initial))
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let authority = ReconstructionSourceOracleAuthority(projectID: fixture.project, jobID: fixture.batch.jobID,
            function: fixture.function, execution: .init(originalImageSHA256: fixture.function.artifact.contentIdentity.digest,
                originalExecutableSHA256: fixture.function.artifact.contentIdentity.digest, originalSourceSHA256: fixture.stage.source.sha256,
                harnessSHA256: fixture.stage.harness.sha256, compilerSHA256: tools.compilerSHA256,
                sdkIdentitySHA256: tools.sdkSettingsSHA256, compileProfileSHA256: hash("profile"),
                compileArgumentsSHA256: hash("compile arguments"), executionArgumentsSHA256: hash("execution arguments"),
                producerSHA256: producer.canonicalSHA256, standardOutput: Data(harness.inputs.map { "\($0):7\n" }.joined().utf8),
                sessionID: UUID(), requestID: UUID(), processIdentifier: 123, sampledProcessIDs: [123],
                exitCode: 0, observedProcessAbsent: true), evidenceIDs: [baseID])
        let task = ReconstructionTaskRecord(identity: try .make(taskID: taskID, jobID: fixture.batch.jobID,
            kind: .executeSource, subject: .function(fixture.function), dependencyTaskIDs: [],
            operationContractIdentity: ReconstructionSourceOracleEvidence.taskContract), state: .completed, diagnostic: nil)
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: receiptID, jobID: fixture.batch.jobID,
            taskID: taskID, checkpointRevision: 1, requestIdentitySHA256: hash("request"), producer: producer,
            terminalState: .completed, outputEvidenceIDs: [outputID], diagnostic: nil)
        let parentID = UUID()
        let checkpoint = try ReconstructionCheckpoint.make(checkpointID: UUID(), jobID: fixture.batch.jobID,
            revision: 1, parentCheckpointID: parentID, parentCheckpointSHA256: hash("parent"),
            corpusManifestSHA256: fixture.batch.corpusManifestSHA256, evidenceFrontierSHA256: hash("frontier"),
            pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: [taskID], failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: hash("gaps"), modelReceiptIDs: [], toolReceiptIDs: [receiptID],
            coordinatorState: .checkpointing, terminalReason: nil)
        let data = Data("retained original observation".utf8)
        let base = try ReconstructionEvidenceRecord(evidenceID: baseID, subject: .function(fixture.function),
            operationID: ReconstructionSourceOracleEvidence.operationID, payloadKind: .text, payload: data,
            payloadByteCount: UInt64(data.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(data),
            facetDependencies: [], producer: producer, citations: [], creatingJobID: fixture.batch.jobID,
            creatingTaskID: UUID(), creatingCheckpointID: parentID, modelReceiptID: nil, toolReceiptID: UUID(),
            classification: .acceptedCurrent, supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let context = ReconstructionSourceOracleEvidence.Context(authority: authority, task: task, checkpoint: checkpoint,
            toolReceipt: receipt, expectedRequestIdentitySHA256: hash("request"), expectedProducer: producer, committedEvidenceCut: [base])
        return try .init(record: ReconstructionSourceOracleEvidence.make(evidenceID: outputID, context: context), context: context)
    }

    private func waitForDispatch(_ transport: TaskSourceTransport) async throws {
        for _ in 0..<200 {
            if await !transport.requests.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected source dispatch")
    }
}

private struct TaskSourceResolver: ReconstructionProductionSourceTaskResolving {
    let resolution: ReconstructionProductionSourceTaskResolution
    func resolve(task: ReconstructionTaskRecord, authority: ReconstructionBatchAuthority,
                 cancellation: ReconstructionCancellation) async throws -> ReconstructionProductionSourceTaskResolution {
        try cancellation.check(); return resolution
    }
}
private struct TaskOracleAssembler: ReconstructionProductionSourceOracleAssembling {
    enum Edit: Sendable { case none, stdout, compiler }
    var edit: Edit = .none
    func authority(projectID: UUID, task: ReconstructionTaskRecord, batchAuthority: ReconstructionBatchAuthority,
                   outcome: ReconstructionSourceExecutionWorkflow.Outcome) async throws -> ReconstructionSourceOracleAuthority {
        let behavior = try XCTUnwrap(outcome.phases.last), response = try XCTUnwrap(behavior.response)
        let cleanup = try XCTUnwrap(response.cleanup), executable = try XCTUnwrap(outcome.executable)
        func hash(_ value: String) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(Data(value.utf8)) }
        return .init(projectID: projectID, jobID: batchAuthority.jobID, function: outcome.function,
            execution: .init(originalImageSHA256: outcome.function.artifact.contentIdentity.digest,
                originalExecutableSHA256: executable.sha256, originalSourceSHA256: outcome.sourceSHA256,
                harnessSHA256: outcome.harnessSHA256,
                compilerSHA256: edit == .compiler ? hash("replacement compiler") : outcome.toolAuthority.compilerSHA256,
                sdkIdentitySHA256: outcome.toolAuthority.sdkSettingsSHA256, compileProfileSHA256: hash("fixed profile"),
                compileArgumentsSHA256: hash("fixed compile arguments"), executionArgumentsSHA256: hash("fixed execution arguments"),
                producerSHA256: hash("owner producer"), standardOutput: edit == .stdout ? Data("0:99\n".utf8) : response.diagnostics,
                sessionID: behavior.request.sessionID, requestID: behavior.request.requestID,
                processIdentifier: cleanup.processIdentifier, sampledProcessIDs: response.sampledProcessIDs,
                exitCode: 0, observedProcessAbsent: cleanup.observedProcessAbsent), evidenceIDs: [UUID()])
    }
}
// CoreTests also compiles the broker wire DTOs; these witnesses must use the app module's types.
private actor TaskSourceTransport: MacScope.ShellBrokerXPCTransport {
    let waitForCancellation: Bool
    let failCleanup: Bool
    let mismatch: Bool
    let rejectAST: Bool
    let compileFailure: Bool
    let unknownCleanup: Bool
    var requests: [MacScope.Phase2SourceExecutionRequest] = []
    init(waitForCancellation: Bool = false, failCleanup: Bool = false, mismatch: Bool = false,
         rejectAST: Bool = false, compileFailure: Bool = false, unknownCleanup: Bool = false) {
        self.waitForCancellation = waitForCancellation; self.failCleanup = failCleanup; self.mismatch = mismatch
        self.rejectAST = rejectAST; self.compileFailure = compileFailure; self.unknownCleanup = unknownCleanup
    }
    func executeSource(_ request: MacScope.Phase2SourceExecutionRequest) async throws -> MacScope.Phase2SourceExecutionResponse {
        requests.append(request)
        if waitForCancellation {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
            return response(request, failure: .cancelled, diagnostics: Data("actual cleanup diagnostic".utf8))
        }
        if failCleanup { return response(request, failure: .cleanupFailed, absent: false) }
        let root = URL(fileURLWithPath: request.stageRootPath)
        if request.operation == .inspect {
            let directory = root.appendingPathComponent("inspection")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let ast = rejectAST ? Self.ast.replacingOccurrences(of: "reconstructed", with: "unadmitted") : Self.ast
            try Data(ast.utf8).write(to: directory.appendingPathComponent("candidate.ast.json"))
        }
        if request.operation == .compile {
            if compileFailure {
                return response(request, failure: unknownCleanup ? .cleanupFailed : nil,
                    diagnostics: Data("controlled clang rejection".utf8), exitCode: 1, unknownCleanup: unknownCleanup)
            }
            let directory = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("candidate")
            try Data("controlled task executable".utf8).write(to: file)
            guard chmod(file.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let output = request.operation == .behavior
            ? Data(try ReconstructionSourceBehaviorHarness.saturatingIncrementV1().inputs.enumerated().map {
                "\($0.element):\(mismatch && $0.offset == 4 ? 9 : 7)\n"
            }.joined().utf8) : Data()
        return response(request, diagnostics: output)
    }
    private func response(_ request: MacScope.Phase2SourceExecutionRequest, failure: MacScope.Phase2SourceExecutionFailure? = nil,
                          diagnostics: Data = Data(), absent: Bool = true, exitCode: Int32 = 0,
                          unknownCleanup: Bool = false) -> MacScope.Phase2SourceExecutionResponse {
        let terminal = MacScope.Phase2SourceExecutionTerminal(kind: failure == .cancelled ? .canceled : .exited,
                                                    status: failure == .cancelled ? nil : exitCode)
        return .init(requestID: request.requestID, sessionID: request.sessionID, operation: request.operation,
            status: .completed, failure: failure, terminal: terminal, diagnostics: diagnostics,
            peakGroupResidentBytes: 100, sampledProcessIDs: [123], elapsedSeconds: 0.1,
            cleanup: MacScope.Phase2SourceExecutionCleanup(sessionID: request.sessionID, requestID: request.requestID, processIdentifier: 123,
                           observedProcessAbsent: absent, outcome: unknownCleanup ? MacScope.Phase2SourceExecutionTerminal(kind: .outcomeUnknown, status: nil) : terminal))
    }
    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake { .boundaryReady }
    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        throw MacScope.ShellBrokerXPCTransportError.unavailable("Generic execution is prohibited")
    }
    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        throw MacScope.ShellBrokerXPCTransportError.unavailable("Unused")
    }
    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool { false }
    func reset() async {}
    private static let ast = #"""
{"kind":"TranslationUnitDecl","inner":[{"kind":"TypedefDecl","name":"uint32_t","type":{"qualType":"unsigned int"}},{"kind":"FunctionDecl","name":"reconstructed","mangledName":"_reconstructed","type":{"qualType":"uint32_t (uint32_t)"},"inner":[{"kind":"ParmVarDecl","id":"p","type":{"qualType":"unsigned int"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"DeclRefExpr","type":{"qualType":"unsigned int"},"referencedDecl":{"id":"p","kind":"ParmVarDecl"}}]}]}]}]}
"""#
}
