import Darwin
import Foundation
import XCTest
@testable import MacScope

/// Controlled transport tests prove app ordering and acceptance. They never execute candidate code.
@MainActor
final class ReconstructionSourceExecutionWorkflowTests: XCTestCase {
    func testOriginalObservationRunsInOrderAndCannotClaimModelAcceptance() async throws {
        let fixture = try fixture(original: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = WorkflowTransport()
        let outcome = await workflow(transport).run(stage: fixture.stage, purpose: fixture.purpose)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.observedOriginal)
        XCTAssertFalse(outcome.matchesOracle)
        XCTAssertNil(outcome.oracleSuiteSHA256)
        XCTAssertEqual(outcome.observations.map(\.output), Array(repeating: 7, count: 37))
        XCTAssertEqual(outcome.phases.map(\.request.operation), [.inspect, .compile, .behavior])
        XCTAssertNotNil(outcome.astAdmission)
        XCTAssertNotNil(outcome.inspection)
        XCTAssertNotNil(outcome.executable)
    }
    func testOriginalPreparationHasNoFunctionPlaceholderAndRequiresExactImportedArtifact() async throws {
        let fixture = try fixture(original: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = WorkflowTransport()
        let workflow = workflow(transport)
        let prepared = await workflow.prepareOriginal(stage: fixture.stage)
        XCTAssertNil(prepared.failure)
        XCTAssertEqual(prepared.phases.map(\.request.operation), [.inspect, .compile])
        XCTAssertEqual(prepared.executable?.sha256, fixture.purpose.function.artifact.contentIdentity.digest)
        let observed = await workflow.observeOriginal(prepared: prepared, function: fixture.purpose.function)
        XCTAssertNil(observed.failure)
        XCTAssertTrue(observed.observedOriginal)
        XCTAssertEqual(observed.phases.map(\.request.operation), [.inspect, .compile, .behavior])
    }
    func testOriginalCannotRunBehaviorForAnotherBinary() async throws {
        let fixture = try fixture(original: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let function = fixture.purpose.function
        let wrong = try ReconstructionFunctionCoordinate(artifact: .init(occurrenceID: function.artifact.occurrenceID,
            contentIdentity: .init(algorithm: .sha256, digest: sha("another binary"), byteCount: 32)),
            image: function.image, analysisFingerprintSHA256: function.analysisFingerprintSHA256,
            startAddress: function.startAddress, endAddressExclusive: function.endAddressExclusive,
            boundarySchemaVersion: function.boundarySchemaVersion, functionUUIDHint: nil, symbolHint: nil)
        let transport = WorkflowTransport(), workflow = workflow(transport)
        let prepared = await workflow.prepareOriginal(stage: fixture.stage)
        let refused = await workflow.observeOriginal(prepared: prepared, function: wrong)
        XCTAssertEqual(refused.failure, .invalidAuthority)
        XCTAssertEqual(refused.phases.map(\.request.operation), [.inspect, .compile])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }
    func testRevisionComparisonUsesAuthenticatedObservedOracleWithoutFormula() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let outcome = await workflow(WorkflowTransport()).run(stage: fixture.stage, purpose: fixture.purpose)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.matchesOracle)
        XCTAssertFalse(outcome.observedOriginal)
        XCTAssertTrue(outcome.mismatches.isEmpty)
        XCTAssertEqual(outcome.observations.count, 37)
    }
    func testASTSpoofIsRejectedBeforeCompile() async throws {
        let fixture = try fixture(original: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = WorkflowTransport(mode: .spoofAST)
        let outcome = await workflow(transport).run(stage: fixture.stage, purpose: fixture.purpose)
        guard case .astRejected = outcome.failure else { return XCTFail("Expected AST rejection") }
        XCTAssertEqual(outcome.phases.map(\.request.operation), [.inspect])
        XCTAssertNil(outcome.executable)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testSourceAndExecutableDriftStopLaterPhases() async throws {
        for mode in [WorkflowTransport.Mode.changeSource, .changeExecutable] {
            let fixture = try fixture(original: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let outcome = await workflow(WorkflowTransport(mode: mode)).run(stage: fixture.stage, purpose: fixture.purpose)
            XCTAssertNotNil(outcome.failure)
            XCTAssertFalse(outcome.observedOriginal)
            XCTAssertTrue(outcome.observations.isEmpty)
            XCTAssertEqual(outcome.phases.last?.request.operation, mode == .changeSource ? .inspect : .behavior)
            XCTAssertEqual(outcome.phases.last?.response?.cleanup?.observedProcessAbsent, true)
        }
    }
    func testBehaviorMismatchRetainsObservedRowsAndEveryActualResponse() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let outcome = await workflow(WorkflowTransport(mode: .mismatch)).run(stage: fixture.stage, purpose: fixture.purpose)
        XCTAssertEqual(outcome.failure, .behaviorMismatch)
        XCTAssertEqual(outcome.mismatches, [.init(index: 4, input: UInt32.max, expected: 7, actual: 9)])
        XCTAssertEqual(outcome.observations[4].output, 9)
        XCTAssertFalse(outcome.matchesOracle)
        XCTAssertEqual(outcome.phases.count, 3)
        XCTAssertTrue(outcome.phases.allSatisfy { $0.response?.cleanup?.observedProcessAbsent == true })
    }
    func testNonzeroCleanupFailureAndWrongResponseIdentityRefuseNextPhase() async throws {
        for mode in [WorkflowTransport.Mode.nonzero, .missingCleanup, .wrongResponse] {
            let fixture = try fixture(original: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
            let outcome = await workflow(WorkflowTransport(mode: mode)).run(stage: fixture.stage, purpose: fixture.purpose)
            XCTAssertEqual(outcome.failure, .phaseRejected(.inspect))
            XCTAssertEqual(outcome.phases.count, 1)
            XCTAssertEqual(outcome.phases[0].response?.diagnostics, Data("actual diagnostic".utf8))
            XCTAssertFalse(outcome.observedOriginal)
        }
    }
    func testCancellationBeforeLaunchDoesNotDispatchAndAfterLaunchRetainsCleanup() async throws {
        let fixture = try fixture(original: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = WorkflowTransport(mode: .waitForCancellation)
        let before = Task { await workflow(transport).run(stage: fixture.stage, purpose: fixture.purpose) }
        before.cancel()
        let beforeOutcome = await before.value
        XCTAssertEqual(beforeOutcome.failure, .cancelled)
        XCTAssertTrue(beforeOutcome.phases.isEmpty)
        let after = Task { await workflow(transport).run(stage: fixture.stage, purpose: fixture.purpose) }
        for _ in 0..<100 {
            if await transport.requests.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        after.cancel()
        let outcome = await after.value
        XCTAssertEqual(outcome.failure, .cancelled)
        XCTAssertEqual(outcome.phases.count, 1)
        XCTAssertEqual(outcome.phases[0].response?.cleanup?.observedProcessAbsent, true)
        XCTAssertEqual(outcome.phases[0].response?.diagnostics, Data("actual cancellation diagnostic".utf8))
    }

    private func workflow(_ transport: WorkflowTransport) -> ReconstructionSourceExecutionWorkflow {
        .init(transport: transport, toolAuthority: tools)
    }
    private var tools: ReconstructionSourceExecutionWorkflow.ToolAuthority {
        .init(compilerPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            sdkRootPath: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            toolchainRootPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
            runnerSHA256: sha("runner"), compilerSHA256: sha("compiler"), sdkSettingsSHA256: sha("sdk"))
    }
    private func sha(_ value: String) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(Data(value.utf8)) }
    private func fixture(original: Bool = false) throws -> (parent: URL, stage: ReconstructionSourceExecutionStage,
                                                          purpose: ReconstructionSourceExecutionWorkflow.Purpose) {
        let context = try oracleContext()
        let record = try ReconstructionSourceOracleEvidence.make(evidenceID: context.toolReceipt.outputEvidenceIDs[0], context: context)
        let oracle = try ReconstructionSourceExecutionWorkflow.ValidatedOracle(record: record, context: context)
        let authority = ReconstructionSourceRevisionAuthority(projectID: context.authority.projectID,
            jobID: context.authority.jobID, function: context.authority.function, objectiveSHA256: sha("objective"),
            evidenceFrontierSHA256: sha("frontier"), oracleSuiteSHA256: oracle.oracle.suiteSHA256,
            admissibleEvidenceIDs: [context.authority.evidenceIDs[0]], currentRevision: nil)
        let source = Data("#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x; }\n".utf8)
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: .init(sourceUTF8: source,
            claimedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source),
            evidenceIDs: context.authority.evidenceIDs), authority: authority)
        let parent = TestWorkRoot.authority
            .appendingPathComponent("source-workflow-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        if original {
            let stage = try ReconstructionSourceExecutionStage.createOriginalAuthority(sourceUTF8: source,
                expectedSourceSHA256: revision.sourceSHA256, harness: harness, parent: parent)
            return (parent, stage, .original(function: authority.function))
        }
        let stage = try ReconstructionSourceExecutionStage.create(revision: revision, authority: authority,
            harness: harness, parent: parent)
        return (parent, stage, .revision(revision: revision, authority: authority, oracle: oracle))
    }
    private func oracleContext() throws -> ReconstructionSourceOracleEvidence.Context {
        let project = UUID(), job = UUID(), baseEvidence = UUID(), taskID = UUID(), receiptID = UUID(), checkpointID = UUID()
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256, digest: sha("controlled executable"), byteCount: UInt64(Data("controlled executable".utf8).count)))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: UUID(), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sha("analysis"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let initial = try ReconstructionProducerIdentity(macScopeBuildIdentity: sha("build"), macScopeSourceIdentity: sha("source"),
            operationIdentity: ReconstructionSourceOracleEvidence.operationID, registryIdentity: sha("registry"),
            protocolIdentity: sha("protocol"), toolchainIdentity: sha("toolchain"), canonicalSHA256: sha("placeholder"))
        let producer = try ReconstructionProducerIdentity(macScopeBuildIdentity: initial.macScopeBuildIdentity,
            macScopeSourceIdentity: initial.macScopeSourceIdentity, operationIdentity: initial.operationIdentity,
            registryIdentity: initial.registryIdentity, protocolIdentity: initial.protocolIdentity,
            toolchainIdentity: initial.toolchainIdentity, canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(initial))
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let execution = ReconstructionSourceOracle.Execution(originalImageSHA256: artifact.contentIdentity.digest,
            originalExecutableSHA256: sha("executable"), originalSourceSHA256: sha("original source"),
            harnessSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
            compilerSHA256: tools.compilerSHA256, sdkIdentitySHA256: tools.sdkSettingsSHA256,
            compileProfileSHA256: sha("profile"), compileArgumentsSHA256: sha("compile arguments"),
            executionArgumentsSHA256: sha("execution arguments"), producerSHA256: producer.canonicalSHA256,
            standardOutput: Data(harness.inputs.map { "\($0):7\n" }.joined().utf8), sessionID: UUID(), requestID: UUID(),
            processIdentifier: 123, sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true)
        let authority = ReconstructionSourceOracleAuthority(projectID: project, jobID: job, function: function,
            execution: execution, evidenceIDs: [baseEvidence])
        // Controlled codec context only; production execution task ownership is supplied by the parent owner.
        let task = ReconstructionTaskRecord(identity: try .make(taskID: taskID, jobID: job, kind: .indexImage,
            subject: .function(function), dependencyTaskIDs: [], operationContractIdentity: ReconstructionSourceOracleEvidence.taskContract),
            state: .completed, diagnostic: nil)
        let outputID = UUID()
        // The record ID must be the receipt output. Capture it with the context for fixture creation.
        let receipt = try ReconstructionReceiptAuthority.makeToolReceipt(receiptID: receiptID, jobID: job, taskID: taskID,
            checkpointRevision: 1, requestIdentitySHA256: sha("request"), producer: producer,
            terminalState: .completed, outputEvidenceIDs: [outputID], diagnostic: nil)
        let checkpoint = try ReconstructionCheckpoint.make(checkpointID: checkpointID, jobID: job, revision: 1,
            parentCheckpointID: UUID(), parentCheckpointSHA256: sha("parent"), corpusManifestSHA256: sha("corpus"),
            evidenceFrontierSHA256: sha("frontier"), pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: [taskID],
            failedTaskIDs: [], blockedTaskIDs: [], unresolvedEvidenceGapSHA256: sha("gaps"), modelReceiptIDs: [],
            toolReceiptIDs: [receiptID], coordinatorState: .checkpointing, terminalReason: nil)
        let data = Data("retained original evidence".utf8)
        let evidence = try ReconstructionEvidenceRecord(evidenceID: baseEvidence, subject: .function(function),
            operationID: ReconstructionSourceOracleEvidence.operationID, payloadKind: .text, payload: data,
            payloadByteCount: UInt64(data.count), payloadSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(data),
            facetDependencies: [], producer: producer, citations: [], creatingJobID: job, creatingTaskID: UUID(),
            creatingCheckpointID: try XCTUnwrap(checkpoint.parentCheckpointID), modelReceiptID: nil, toolReceiptID: UUID(),
            classification: .acceptedCurrent, supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        return .init(authority: authority, task: task, checkpoint: checkpoint, toolReceipt: receipt,
            expectedRequestIdentitySHA256: sha("request"), expectedProducer: producer, committedEvidenceCut: [evidence])
    }
}

// CoreTests also compiles the broker wire DTOs; these witnesses must use the app module's types.
private actor WorkflowTransport: MacScope.ShellBrokerXPCTransport {
    enum Mode: Equatable, Sendable {
        case normal, spoofAST, changeSource, changeExecutable, mismatch, nonzero, missingCleanup, wrongResponse, waitForCancellation
    }
    let mode: Mode
    var requests: [MacScope.Phase2SourceExecutionRequest] = []
    init(mode: Mode = .normal) { self.mode = mode }
    func executeSource(_ request: MacScope.Phase2SourceExecutionRequest) async throws -> MacScope.Phase2SourceExecutionResponse {
        requests.append(request)
        let root = URL(fileURLWithPath: request.stageRootPath)
        if mode == .waitForCancellation {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            // Noncancellable delay models waiting for actual remote process-group cleanup.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
            }
            return response(request, failure: .cancelled, diagnostics: Data("actual cancellation diagnostic".utf8))
        }
        if [.nonzero, .missingCleanup, .wrongResponse].contains(mode) {
            return response(request, failure: mode == .missingCleanup ? .cleanupFailed : nil,
                diagnostics: Data("actual diagnostic".utf8), exitCode: mode == .nonzero ? 1 : 0,
                absent: mode != .missingCleanup, wrongID: mode == .wrongResponse)
        }
        if request.operation == .inspect {
            let inspection = root.appendingPathComponent("inspection")
            try FileManager.default.createDirectory(at: inspection, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            var ast = Self.validAST
            if mode == .spoofAST { ast = ast.replacingOccurrences(of: "\"ReturnStmt\"", with: "\"CallExpr\"") }
            try Data(ast.utf8).write(to: inspection.appendingPathComponent("candidate.ast.json"))
            if mode == .changeSource {
                let source = root.appendingPathComponent("candidate.c")
                try FileManager.default.removeItem(at: source); try Data("changed".utf8).write(to: source)
            }
        }
        if request.operation == .compile {
            let output = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let executable = output.appendingPathComponent("candidate")
            try Data("controlled executable".utf8).write(to: executable)
            guard chmod(executable.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        if request.operation == .behavior {
            if mode == .changeExecutable {
                try Data("changed executable".utf8).write(to: root.appendingPathComponent("output/candidate"))
            }
            let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
            let output = Data(harness.inputs.enumerated().map { index, input in
                "\(input):\(mode == .mismatch && index == 4 ? 9 : 7)\n"
            }.joined().utf8)
            return response(request, diagnostics: output)
        }
        return response(request)
    }
    private func response(_ request: MacScope.Phase2SourceExecutionRequest, failure: MacScope.Phase2SourceExecutionFailure? = nil,
                          diagnostics: Data = Data(), exitCode: Int32 = 0, absent: Bool = true, wrongID: Bool = false) -> MacScope.Phase2SourceExecutionResponse {
        let terminal = MacScope.Phase2SourceExecutionTerminal(kind: .exited, status: exitCode)
        return .init(requestID: wrongID ? UUID() : request.requestID, sessionID: request.sessionID,
            operation: request.operation, status: .completed, failure: failure, terminal: terminal,
            diagnostics: diagnostics, peakGroupResidentBytes: 100, sampledProcessIDs: [123], elapsedSeconds: 0.1,
            cleanup: MacScope.Phase2SourceExecutionCleanup(sessionID: request.sessionID, requestID: request.requestID,
                processIdentifier: 123, observedProcessAbsent: absent, outcome: terminal))
    }
    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake { .boundaryReady }
    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        throw MacScope.ShellBrokerXPCTransportError.unavailable("Generic execution prohibited by workflow fixture")
    }
    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        throw MacScope.ShellBrokerXPCTransportError.unavailable("Unused")
    }
    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool { false }
    func reset() async {}
    private static let validAST = #"""
{"kind":"TranslationUnitDecl","inner":[{"kind":"TypedefDecl","name":"uint32_t","type":{"qualType":"unsigned int"}},{"kind":"FunctionDecl","name":"reconstructed","mangledName":"_reconstructed","type":{"qualType":"uint32_t (uint32_t)"},"inner":[{"kind":"ParmVarDecl","id":"p","type":{"qualType":"unsigned int"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"DeclRefExpr","type":{"qualType":"unsigned int"},"referencedDecl":{"id":"p","kind":"ParmVarDecl"}}]}]}]}]}
"""#
}
