import Darwin
import Foundation
import XCTest
@testable import MacScope

/// Recovery fixtures use controlled broker responses and four-byte executable data. They prove
/// ownership/recovery behavior only, never Mach-O import or native original execution qualification.
/// Recovery never recompiles: it recovers the job's durably retained executable bytes.
@MainActor
final class ReconstructionSourceOriginalRecoveryTests: XCTestCase {
    func testOrdinaryJobDoesNotPrepareOrConsultMissingAttachment() async throws {
        let fixture = try fixture(intent: false); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try FileManager.default.removeItem(at: fixture.attachment)
        let recovery = ReconstructionSourceOriginalRecovery(workflowProvider: {
            throw ReconstructionSourceOriginalRecoveryFailure.unavailable("Provider must not be called")
        }, stageParent: fixture.parent, registry: fixture.registry)
        let session = try await recovery.session(for: fixture.basis)
        XCTAssertNil(session)
    }

    func testValidatedPublishedOracleDoesNotReprepareOriginal() async throws {
        let fixture = try fixture(oracle: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try FileManager.default.removeItem(at: fixture.attachment)
        let recovery = ReconstructionSourceOriginalRecovery(workflowProvider: {
            throw ReconstructionSourceOriginalRecoveryFailure.unavailable("Provider must not be called")
        }, stageParent: fixture.parent, registry: fixture.registry)
        let session = try await recovery.session(for: fixture.basis)
        XCTAssertNil(session)
    }

    func testExactReprepareBindsExistingImportAndReusesSameSession() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = RecoveryTransport(), workflow = workflow(transport)
        let recovery = ReconstructionSourceOriginalRecovery(workflowProvider: { workflow },
            stageParent: fixture.parent, registry: fixture.registry)
        let firstValue = try await recovery.session(for: fixture.basis)
        let secondValue = try await recovery.session(for: fixture.basis)
        let first = try XCTUnwrap(firstValue), second = try XCTUnwrap(secondValue)
        XCTAssertTrue(first === second)
        let registered = await fixture.registry.session(workspaceID: fixture.basis.workspaceID, jobID: fixture.basis.job.jobID)
        XCTAssertTrue(registered === first)
        let prepared = await recovery.preparationDiagnostic()
        XCTAssertEqual(prepared?.executable?.sha256, fixture.artifact.contentIdentity.digest)
        XCTAssertEqual(prepared?.executable?.byteCount, 4)
        XCTAssertEqual(try Data(contentsOf: fixture.attachment), Data("test".utf8))
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.operation), [.inspect])
        await recovery.retire()
        let removed = await fixture.registry.session(workspaceID: fixture.basis.workspaceID, jobID: fixture.basis.job.jobID)
        XCTAssertNil(removed)
    }

    /// Resume after executingReads in a fresh process: the original is recovered from the retained
    /// admitted bytes with no compile dispatch (a compile would yield different bytes here), the
    /// installed candidate equals the admitted SHA-256/bytes, and the original behavior observation
    /// runs against exactly those bytes as [inspect, behavior].
    func testResumeAfterExecutingReadsRecoversRetainedBytesWithoutRebuild() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = RecoveryTransport(executable: Data("different compiled bytes".utf8), behavior: true)
        let workflow = workflow(transport)
        let recovery = ReconstructionSourceOriginalRecovery(workflowProvider: { workflow },
            stageParent: fixture.parent, registry: fixture.registry)
        let value = try await recovery.session(for: fixture.basis)
        XCTAssertNotNil(value)
        let preparedValue = await recovery.preparationDiagnostic()
        let prepared = try XCTUnwrap(preparedValue)
        XCTAssertNil(prepared.failure)
        XCTAssertEqual(prepared.executableOrigin, .retained)
        XCTAssertEqual(prepared.phases.map(\.request.operation), [.inspect])
        let executable = try XCTUnwrap(prepared.executable)
        XCTAssertEqual(executable.sha256, fixture.artifact.contentIdentity.digest)
        XCTAssertEqual(UInt64(executable.byteCount), fixture.artifact.contentIdentity.byteCount)
        let installed = try Data(contentsOf: prepared.stage.root.appendingPathComponent("output/candidate"))
        XCTAssertEqual(installed, try Data(contentsOf: fixture.attachment))
        XCTAssertEqual(ReconstructionSourceRevisionAdmission.sourceSHA256(installed), fixture.artifact.contentIdentity.digest)

        let outcome = await workflow.observeOriginal(prepared: prepared, function: fixture.function)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.observedOriginal)
        XCTAssertEqual(outcome.executableOrigin, .retained)
        XCTAssertEqual(outcome.phases.map(\.request.operation), [.inspect, .behavior])
        XCTAssertEqual(outcome.executable?.sha256, fixture.artifact.contentIdentity.digest)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.operation == .compile }, "Resume recovery must not rebuild")
        XCTAssertEqual(Set(requests.map(\.sessionID)).count, 1)
        await recovery.retire()
    }

    func testRetainedInstallRejectsBytesThatDoNotMatchTheAdmittedHash() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let stage = try ReconstructionSourceExecutionStage.createOriginalAuthority(
            sourceUTF8: ReconstructionSourceOriginalSession.originalSourceUTF8,
            expectedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(ReconstructionSourceOriginalSession.originalSourceUTF8),
            harness: try ReconstructionSourceBehaviorHarness.saturatingIncrementV1(), parent: fixture.parent)
        XCTAssertThrowsError(try stage.installRetainedExecutable(Data("evil".utf8),
            expectedSHA256: fixture.artifact.contentIdentity.digest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.root.appendingPathComponent("output/candidate").path))
    }

    func testAttachmentDriftIsAuthorityFailureBeforeCompilerDispatch() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try Data("evil".utf8).write(to: fixture.attachment)
        let transport = RecoveryTransport(), workflow = workflow(transport)
        let recovery = ReconstructionSourceOriginalRecovery(workflowProvider: { workflow },
            stageParent: fixture.parent, registry: fixture.registry)
        do { _ = try await recovery.session(for: fixture.basis); XCTFail("Changed import was recovered") }
        catch { XCTAssertEqual(error as? ReconstructionSourceOriginalRecoveryFailure, .authorityMismatch) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testConcurrentLookupsCoalesceOnePreparation() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = RecoveryTransport(hold: true), workflow = workflow(transport)
        let recovery = ReconstructionSourceOriginalRecovery(workflowProvider: { workflow },
            stageParent: fixture.parent, registry: fixture.registry)
        let first = Task { try await recovery.session(for: fixture.basis) }
        await transport.waitForDispatch()
        let second = Task { try await recovery.session(for: fixture.basis) }
        await Task.yield(); await Task.yield()
        await transport.release()
        let a = try await first.value, b = try await second.value
        let sessionA = try XCTUnwrap(a), sessionB = try XCTUnwrap(b)
        XCTAssertTrue(sessionA === sessionB)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.operation), [.inspect])
        await recovery.retire()
    }

    func testRetirementWaitsForActualPreparationCleanup() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let transport = RecoveryTransport(hold: true), workflow = workflow(transport)
        let recovery = ReconstructionSourceOriginalRecovery(workflowProvider: { workflow },
            stageParent: fixture.parent, registry: fixture.registry)
        let preparation = Task { try await recovery.session(for: fixture.basis) }
        await transport.waitForDispatch()
        await recovery.retire()
        let cleanup = await transport.cleanupObserved
        XCTAssertTrue(cleanup)
        do { _ = try await preparation.value; XCTFail("Retired recovery returned a session") }
        catch { XCTAssertEqual(error as? ReconstructionSourceOriginalRecoveryFailure, .retired) }
        let actual = await recovery.preparationDiagnostic()
        XCTAssertEqual(actual?.failure, .cancelled)
        XCTAssertEqual(actual?.phases.first?.response?.cleanup?.observedProcessAbsent, true)
        let registered = await fixture.registry.session(workspaceID: fixture.basis.workspaceID, jobID: fixture.basis.job.jobID)
        XCTAssertNil(registered)
    }

    func testToolingUnavailabilityHasBoundedDiagnostic() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let recovery = ReconstructionSourceOriginalRecovery(workflowProvider: {
            throw RecoveryProviderError(message: String(repeating: "🔥", count: 2_000))
        }, stageParent: fixture.parent, registry: fixture.registry)
        do { _ = try await recovery.session(for: fixture.basis); XCTFail("Unavailable tools recovered an original") }
        catch {
            guard case .unavailable(let diagnostic)? = error as? ReconstructionSourceOriginalRecoveryFailure else {
                return XCTFail("Expected recoverable tool unavailability")
            }
            XCTAssertLessThanOrEqual(diagnostic.utf8.count, 1_024)
        }
        let actual = await recovery.preparationDiagnostic()
        XCTAssertNil(actual)
    }

    private struct Fixture {
        let parent: URL
        let attachment: URL
        let artifact: ReconstructionArtifactCoordinate
        let function: ReconstructionFunctionCoordinate
        let basis: ReconstructionProductionRoundBasis
        let registry: ReconstructionSourceOriginalSessionRegistry
    }
    private func fixture(intent: Bool = true, oracle: Bool = false) throws -> Fixture {
        let original = try ProductionSourceOwnerFixture.make()
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(workspaceBinaryID: ProductionSourceOwnerFixture.id(1))
        let basis: ReconstructionProductionRoundBasis
        if oracle { basis = original.basis }
        else {
            basis = try ProductionSourceOwnerFixture.rebuild(foundation: foundation, tasks: original.basis.tasks,
                records: [], modelReceipts: original.basis.modelReceipts, toolReceipts: [], history: original.basis.checkpointHistory,
                function: original.function, revision: original.basis.checkpoint.revision,
                checkpointID: original.basis.checkpoint.checkpointID, parent: original.basis.checkpointHistory.last)
        }
        let old = basis.job
        let job = try ReconstructionJobRecord(jobID: old.jobID, reconstructionProjectID: old.reconstructionProjectID,
            objective: old.objective, objectiveSHA256: old.objectiveSHA256,
            creationCorpusManifestSHA256: old.creationCorpusManifestSHA256, state: old.state,
            currentCheckpointID: old.currentCheckpointID, terminalReason: old.terminalReason, budget: old.budget,
            creationOrdinal: try XCTUnwrap(old.creationOrdinal), pauseContext: old.pauseContext,
            focus: intent ? .artifact(original.function.artifact) : old.focus,
            sourceProfileID: intent ? ReconstructionSourceExecutionTaskContract.profileID : nil)
        let parent = TestWorkRoot.authority.appendingPathComponent("source-recovery-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let attachment = parent.appendingPathComponent("imported-original.bin")
        try Data("test".utf8).write(to: attachment)
        let restored = try ReconstructionProductionRoundBasis(workspaceID: basis.workspaceID, project: basis.project,
            manifest: basis.manifest, job: job, checkpoint: basis.checkpoint, tasks: basis.tasks,
            toolReceipts: basis.toolReceipts, modelReceipts: basis.modelReceipts,
            taskCompletionAuthorities: basis.taskCompletionAuthorities,
            attachmentSources: [.init(contentIdentity: original.function.artifact.contentIdentity, verifiedURL: attachment)],
            evidenceCut: basis.evidenceCut, freshnessAuthority: basis.freshnessAuthority, snapshot: basis.snapshot,
            checkpointHistory: basis.checkpointHistory)
        return .init(parent: parent, attachment: attachment, artifact: original.function.artifact,
                     function: original.function, basis: restored, registry: .init())
    }
    private func workflow(_ transport: RecoveryTransport) -> ReconstructionSourceExecutionWorkflow {
        func hash(_ text: String) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(Data(text.utf8)) }
        return .init(transport: transport, toolAuthority: .init(
            compilerPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            sdkRootPath: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            toolchainRootPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
            runnerSHA256: hash("runner"), compilerSHA256: hash("compiler"), sdkSettingsSHA256: hash("sdk")))
    }
}

private struct RecoveryProviderError: Error { let message: String }
// CoreTests also compiles the broker wire DTOs; these witnesses must use the app module's types.
private actor RecoveryTransport: MacScope.ShellBrokerXPCTransport {
    let executable: Data
    let hold: Bool
    let behavior: Bool
    private var released = false
    var cleanupObserved = false
    var requests: [MacScope.Phase2SourceExecutionRequest] = []
    init(executable: Data = Data("test".utf8), hold: Bool = false, behavior: Bool = false) {
        self.executable = executable; self.hold = hold; self.behavior = behavior
    }
    func release() { released = true }
    func waitForDispatch() async {
        for _ in 0..<200 {
            if !requests.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func executeSource(_ request: MacScope.Phase2SourceExecutionRequest) async throws -> MacScope.Phase2SourceExecutionResponse {
        requests.append(request)
        if hold && request.operation == .inspect {
            while !released && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            if Task.isCancelled {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
                }
                cleanupObserved = true
                return response(request, cancelled: true)
            }
        }
        let root = URL(fileURLWithPath: request.stageRootPath)
        if request.operation == .inspect {
            let directory = root.appendingPathComponent("inspection")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data(Self.ast.utf8).write(to: directory.appendingPathComponent("candidate.ast.json"))
        } else if request.operation == .compile {
            let directory = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let binary = directory.appendingPathComponent("candidate")
            try executable.write(to: binary)
            guard chmod(binary.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else if behavior {
            let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
            let text = harness.inputs.map { "\($0):\($0 == UInt32.max ? $0 : $0 + 1)\n" }.joined()
            return response(request, diagnostics: Data(text.utf8))
        } else { throw MacScope.ShellBrokerXPCTransportError.unavailable("Recovery never executes behavior") }
        return response(request)
    }
    private func response(_ request: MacScope.Phase2SourceExecutionRequest, cancelled: Bool = false,
                          diagnostics: Data = Data()) -> MacScope.Phase2SourceExecutionResponse {
        let terminal = MacScope.Phase2SourceExecutionTerminal(kind: .exited, status: 0)
        return .init(requestID: request.requestID, sessionID: request.sessionID, operation: request.operation,
            status: .completed, failure: cancelled ? .cancelled : nil, terminal: terminal,
            diagnostics: diagnostics, peakGroupResidentBytes: 100, sampledProcessIDs: [123], elapsedSeconds: 0.1,
            cleanup: MacScope.Phase2SourceExecutionCleanup(sessionID: request.sessionID, requestID: request.requestID, processIdentifier: 123,
                observedProcessAbsent: true, outcome: terminal))
    }
    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake { .boundaryReady }
    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        throw MacScope.ShellBrokerXPCTransportError.unavailable("Generic execution prohibited")
    }
    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt { throw MacScope.ShellBrokerXPCTransportError.unavailable("Unused") }
    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool { false }
    func reset() async {}
    private static let ast = #"""
    {"kind":"TranslationUnitDecl","inner":[{"kind":"TypedefDecl","name":"uint32_t","type":{"qualType":"unsigned int"}},{"kind":"FunctionDecl","name":"reconstructed","mangledName":"_reconstructed","type":{"qualType":"uint32_t (uint32_t)"},"inner":[{"kind":"ParmVarDecl","id":"p","type":{"qualType":"unsigned int"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"DeclRefExpr","type":{"qualType":"unsigned int"},"referencedDecl":{"id":"p","kind":"ParmVarDecl"}}]}]}]}]}
    """#
}
