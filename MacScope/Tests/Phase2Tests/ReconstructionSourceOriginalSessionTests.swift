import Darwin
import Foundation
import XCTest
@testable import MacScope

/// Executes the session against a controlled broker transport; never launches candidate code.
@MainActor
final class ReconstructionSourceOriginalSessionTests: XCTestCase {
    func testPreparationExposesExactCapturedImportWithoutBehaviorAndReusesIt() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let first = try await fixture.session.prepare(), second = try await fixture.session.prepare()
        XCTAssertEqual(first.executableURL, second.executableURL)
        XCTAssertEqual(first.executable, second.executable)
        XCTAssertEqual(first.executableURL.lastPathComponent, "candidate")
        XCTAssertEqual(first.executableURL.deletingLastPathComponent().lastPathComponent, "output")
        XCTAssertEqual(try Data(contentsOf: first.executableURL), OriginalSessionTransport.executable)
        XCTAssertEqual(first.sourceSHA256, sha(ReconstructionSourceOriginalSession.originalSourceUTF8))
        XCTAssertEqual(first.harnessSHA256, sha(try ReconstructionSourceBehaviorHarness.saturatingIncrementV1().sourceUTF8))
        XCTAssertEqual(first.profileID, ReconstructionSourceRevision.profileID)
        let requests = await fixture.transport.requests
        XCTAssertEqual(requests.map(\.operation), [.inspect, .compile])
        let prepared = await fixture.session.preparationDiagnostic()
        XCTAssertEqual(prepared?.executable, first.executable)
        XCTAssertEqual(prepared?.stage.sourceAuthority, .trustedOriginal(sourceSHA256: first.sourceSHA256))
    }

    func testBindingRequiresImportedBytesAndFreezesOccurrenceAndJob() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        _ = try await fixture.session.prepare()
        let project = UUID(), job = UUID(), artifact = try artifact()
        for bad in [try self.artifact(digest: sha(Data("different".utf8))),
                    try self.artifact(byteCount: UInt64(OriginalSessionTransport.executable.count + 1))] {
            await assertFailure(.invalidBinding) { try await fixture.session.bind(projectID: project, jobID: job, importedArtifact: bad) }
        }
        try await fixture.session.bind(projectID: project, jobID: job, importedArtifact: artifact)
        try await fixture.session.bind(projectID: project, jobID: job, importedArtifact: artifact)
        await assertFailure(.invalidBinding) { try await fixture.session.bind(projectID: project, jobID: UUID(), importedArtifact: artifact) }
        await assertFailure(.invalidBinding) { try await fixture.session.bind(projectID: project, jobID: job, importedArtifact: self.artifact()) }
    }

    func testResolutionRequiresBoundOwnerCatalogAndRevalidatesExecutable() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let candidate = try await fixture.session.prepare(), project = UUID(), job = UUID()
        let artifact = try artifact(), function = try function(artifact)
        try await fixture.session.bind(projectID: project, jobID: job, importedArtifact: artifact)
        await assertFailure(.uncommittedFunction) {
            _ = try await fixture.session.preparedOriginal(projectID: project, jobID: job, function: function, committedFunctions: [])
        }
        await assertFailure(.invalidBinding) {
            _ = try await fixture.session.preparedOriginal(projectID: UUID(), jobID: job, function: function, committedFunctions: [function])
        }
        let prepared = try await fixture.session.preparedOriginal(projectID: project, jobID: job, function: function, committedFunctions: [function])
        XCTAssertEqual(prepared.executable, candidate.executable)
        XCTAssertEqual(prepared.phases.map(\.request.operation), [.inspect, .compile])
        try Data("changed executable".utf8).write(to: candidate.executableURL)
        do {
            _ = try await fixture.session.preparedOriginal(projectID: project, jobID: job, function: function, committedFunctions: [function])
            XCTFail("Changed executable was accepted")
        } catch { XCTAssertTrue(error is ReconstructionSourceExecutionStage.Failure) }
    }

    func testRetirementCancelsPreparationAndAwaitsObservedCleanup() async throws {
        let fixture = try fixture(wait: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let preparation = Task { try await fixture.session.prepare() }
        await fixture.transport.waitForRequest()
        await assertFailure(.busy) { _ = try await fixture.session.prepare() }
        await fixture.session.retire()
        let cleanupObserved = await fixture.transport.cleanupObserved
        XCTAssertTrue(cleanupObserved)
        do { _ = try await preparation.value; XCTFail("Retired preparation produced an import") }
        catch { XCTAssertEqual(error as? ReconstructionSourceOriginalSession.Failure, .retired) }
        let actual = await fixture.session.preparationDiagnostic()
        XCTAssertEqual(actual?.failure, .cancelled)
        XCTAssertEqual(actual?.phases.first?.response?.cleanup?.observedProcessAbsent, true)
        await assertFailure(.retired) { _ = try await fixture.session.prepare() }
    }

    func testCallerCancellationReachesExistingWorkflowAndCannotBindFailedPreparation() async throws {
        let fixture = try fixture(wait: true); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        let preparation = Task { try await fixture.session.prepare() }
        await fixture.transport.waitForRequest(); preparation.cancel()
        do { _ = try await preparation.value; XCTFail("Cancelled preparation produced an import") }
        catch { XCTAssertTrue(error is CancellationError) }
        let cleanupObserved = await fixture.transport.cleanupObserved
        XCTAssertTrue(cleanupObserved)
        await assertFailure(.preparationFailed(.cancelled)) {
            try await fixture.session.bind(projectID: UUID(), jobID: UUID(), importedArtifact: self.artifact())
        }
    }

    private func assertFailure(_ expected: ReconstructionSourceOriginalSession.Failure,
                               operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? ReconstructionSourceOriginalSession.Failure, expected) }
    }
    private func sha(_ bytes: Data) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(bytes) }
    private func artifact(digest: String? = nil, byteCount: UInt64? = nil) throws -> ReconstructionArtifactCoordinate {
        .init(occurrenceID: .init(rawValue: UUID()), contentIdentity: try .init(algorithm: .sha256,
            digest: digest ?? sha(OriginalSessionTransport.executable),
            byteCount: byteCount ?? UInt64(OriginalSessionTransport.executable.count)))
    }
    private func function(_ artifact: ReconstructionArtifactCoordinate) throws -> ReconstructionFunctionCoordinate {
        try .init(artifact: artifact, image: .init(binaryID: UUID(), imageSlot: .primary,
            selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sha(Data("committed analysis".utf8)), startAddress: 0x1000,
            endAddressExclusive: 0x1010, boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
    }
    private func fixture(wait: Bool = false) throws -> (parent: URL, transport: OriginalSessionTransport,
                                                        session: ReconstructionSourceOriginalSession) {
        let parent = TestWorkRoot.authority.appendingPathComponent("source-original-session-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let transport = OriginalSessionTransport(wait: wait)
        let workflow = ReconstructionSourceExecutionWorkflow(transport: transport, toolAuthority: .init(
            compilerPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
            sdkRootPath: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            toolchainRootPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
            runnerSHA256: sha(Data("runner".utf8)), compilerSHA256: sha(Data("compiler".utf8)),
            sdkSettingsSHA256: sha(Data("sdk".utf8))))
        return (parent, transport, .init(workflow: workflow, stageParent: parent))
    }
}

private actor OriginalSessionTransport: ShellBrokerXPCTransport {
    static let executable = Data("controlled original executable".utf8)
    let wait: Bool
    var requests: [MacScope.Phase2SourceExecutionRequest] = []
    var cleanupObserved = false
    init(wait: Bool) { self.wait = wait }
    func waitForRequest() async {
        for _ in 0..<200 {
            if !requests.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func executeSource(_ request: MacScope.Phase2SourceExecutionRequest) async throws -> MacScope.Phase2SourceExecutionResponse {
        requests.append(request)
        if wait {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            // Retirement must await a terminal reply after actual cleanup, even after cancellation.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
            }
            cleanupObserved = true
            return response(request, cancelled: true)
        }
        let root = URL(fileURLWithPath: request.stageRootPath)
        if request.operation == .inspect {
            let directory = root.appendingPathComponent("inspection")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data(Self.ast.utf8).write(to: directory.appendingPathComponent("candidate.ast.json"))
        } else if request.operation == .compile {
            let directory = root.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("candidate")
            try Self.executable.write(to: file)
            guard chmod(file.path, 0o700) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } else { throw ShellBrokerXPCTransportError.unavailable("No behavior during preparation") }
        return response(request)
    }
    private func response(_ request: MacScope.Phase2SourceExecutionRequest, cancelled: Bool = false) -> MacScope.Phase2SourceExecutionResponse {
        let terminal = MacScope.Phase2SourceExecutionTerminal(kind: .exited, status: 0)
        return .init(requestID: request.requestID, sessionID: request.sessionID, operation: request.operation,
            status: .completed, failure: cancelled ? .cancelled : nil, terminal: terminal,
            diagnostics: Data(), peakGroupResidentBytes: 100, sampledProcessIDs: [123], elapsedSeconds: 0.1,
            cleanup: .init(sessionID: request.sessionID, requestID: request.requestID, processIdentifier: 123,
                observedProcessAbsent: true, outcome: terminal))
    }
    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake { .boundaryReady }
    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        throw ShellBrokerXPCTransportError.unavailable("Generic process execution prohibited")
    }
    func prepareBrokerProcessReceipt() async throws -> ShellBrokerXPCProcessReceipt { throw ShellBrokerXPCTransportError.unavailable("Unused") }
    func revalidateBrokerProcessReceipt(_ receipt: ShellBrokerXPCProcessReceipt) async -> Bool { false }
    func reset() async {}
    private static let ast = #"""
    {"kind":"TranslationUnitDecl","inner":[{"kind":"TypedefDecl","name":"uint32_t","type":{"qualType":"unsigned int"}},{"kind":"FunctionDecl","name":"reconstructed","mangledName":"_reconstructed","type":{"qualType":"uint32_t (uint32_t)"},"inner":[{"kind":"ParmVarDecl","id":"p","type":{"qualType":"unsigned int"}},{"kind":"CompoundStmt","inner":[{"kind":"ReturnStmt","inner":[{"kind":"DeclRefExpr","type":{"qualType":"unsigned int"},"referencedDecl":{"id":"p","kind":"ParmVarDecl"}}]}]}]}]}
    """#
}
