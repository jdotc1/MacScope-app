import Foundation
import XCTest
@testable import MacScope

/// Dispatcher proofs use an injected lease result. Real signed-helper execution is tested separately.
@MainActor
final class ReconstructionSourceXPCBoundaryTests: XCTestCase {
    func testSourceWireRequiresExplicitAuthorityAndRejectsUnknownEnvelopeFields() throws {
        let original = request(authority: .original, revision: nil)
        XCTAssertEqual(try Phase2SourceExecutionWireCodec.decodeRequest(
            Phase2SourceExecutionWireCodec.encodeRequest(original)), original)
        XCTAssertThrowsError(try Phase2SourceExecutionWireCodec.encodeRequest(
            request(authority: .original, revision: digest)))
        XCTAssertThrowsError(try Phase2SourceExecutionWireCodec.encodeRequest(
            request(authority: .admittedRevision, revision: nil)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Phase2SourceExecutionWireCodec.encodeRequest(original)) as? [String: Any])
        object["executablePath"] = "/bin/sh"
        let arbitrary = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        XCTAssertThrowsError(try Phase2SourceExecutionWireCodec.decodeRequest(arbitrary))
        object.removeValue(forKey: "executablePath"); object["operation"] = "shell"
        XCTAssertThrowsError(try Phase2SourceExecutionWireCodec.decodeRequest(
            JSONSerialization.data(withJSONObject: object, options: .sortedKeys)))
    }

    func testSignedSourceCapabilityIsDistinctFromGenericShellCommands() throws {
        let handshake = Phase2ShellBrokerHandshake.boundaryReady
        XCTAssertEqual(handshake.sourceExecutionProtocol, Phase2SourceExecutionWireCodec.protocolIdentity)
        XCTAssertFalse(handshake.supportedCommands.contains("executeSource"))
        XCTAssertTrue(Phase2ShellBrokerPeerRequirement.sourceRunner.contains(
            "identifier \"org.macscope.app.SourceExecutionRunner\""))
        XCTAssertTrue(Phase2ShellBrokerPeerRequirement.sourceRunner.contains("Apple Development: MacScope Developer"))
    }

    func testSourceExecutionReplaysExactResultAndRejectsChangedIdentity() async throws {
        let state = ExecutionState()
        let principal = makePrincipal(state)
        let value = request()
        let bytes = try Phase2SourceExecutionWireCodec.encodeRequest(value)
        let first = await execute(principal, bytes: bytes)
        let second = await execute(principal, bytes: bytes)
        XCTAssertEqual(first, second)
        XCTAssertEqual(state.count, 1)
        var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        changed["sourceSHA256"] = String(repeating: "b", count: 64)
        let rejected = try Phase2SourceExecutionWireCodec.decodeResponse(await execute(principal,
            bytes: JSONSerialization.data(withJSONObject: changed, options: .sortedKeys)))
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(state.count, 1)
        let completed = try Phase2SourceExecutionWireCodec.decodeResponse(first)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.cleanup?.observedProcessAbsent, true)
        XCTAssertEqual(completed.terminal, .init(kind: .exited, status: 0))
    }

    func testConcurrentSecondOperationIsRejectedAndCancellationWaitsForCleanup() async throws {
        let state = ExecutionState(waitForCancellation: true)
        let principal = makePrincipal(state)
        let value = request()
        let bytes = try Phase2SourceExecutionWireCodec.encodeRequest(value)
        let pending = Task { await execute(principal, bytes: bytes) }
        try await waitUntilStarted(state)
        let other = try Phase2SourceExecutionWireCodec.decodeResponse(await execute(principal,
            bytes: Phase2SourceExecutionWireCodec.encodeRequest(request())))
        XCTAssertEqual(other.status, .rejected)
        let canceled = await cancel(principal, bytes: bytes)
        let completed = await pending.value
        XCTAssertEqual(canceled, completed)
        let response = try Phase2SourceExecutionWireCodec.decodeResponse(completed)
        XCTAssertEqual(response.failure, .cancelled)
        XCTAssertEqual(response.cleanup?.observedProcessAbsent, true)
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.count, 1)
    }

    func testSeparateConnectionsCannotExecuteSourceConcurrently() async throws {
        let firstState = ExecutionState(waitForCancellation: true)
        let secondState = ExecutionState()
        let first = makePrincipal(firstState)
        let second = makePrincipal(secondState)
        let bytes = try Phase2SourceExecutionWireCodec.encodeRequest(request())
        let pending = Task { await execute(first, bytes: bytes) }
        try await waitUntilStarted(firstState)
        let rejected = try Phase2SourceExecutionWireCodec.decodeResponse(await execute(second,
            bytes: Phase2SourceExecutionWireCodec.encodeRequest(request())))
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(secondState.count, 0)
        _ = await cancel(first, bytes: bytes)
        _ = await pending.value
        let afterCleanup = try Phase2SourceExecutionWireCodec.decodeResponse(await execute(second,
            bytes: Phase2SourceExecutionWireCodec.encodeRequest(request())))
        XCTAssertEqual(afterCleanup.status, .completed)
        XCTAssertEqual(secondState.count, 1)
    }

    func testCancellationBeforeExecuteIsBoundToExactRequestAndReturnsCleanup() async throws {
        let state = ExecutionState(waitForCancellation: true)
        let principal = makePrincipal(state)
        let bytes = try Phase2SourceExecutionWireCodec.encodeRequest(request())
        let cancellation = SourceReplyBox()
        principal.cancelSource(bytes) { cancellation.set($0) }
        let completed = await execute(principal, bytes: bytes)
        XCTAssertEqual(cancellation.value, completed)
        let response = try Phase2SourceExecutionWireCodec.decodeResponse(completed)
        XCTAssertEqual(response.failure, .cancelled)
        XCTAssertEqual(response.cleanup?.observedProcessAbsent, true)
    }

    func testConnectionInvalidationReachesActiveLeaseAndPreservesTerminalProof() async throws {
        let state = ExecutionState(waitForCancellation: true)
        let principal = makePrincipal(state)
        let bytes = try Phase2SourceExecutionWireCodec.encodeRequest(request())
        let pending = Task { await execute(principal, bytes: bytes) }
        try await waitUntilStarted(state)
        principal.invalidate()
        let response = try Phase2SourceExecutionWireCodec.decodeResponse(await pending.value)
        XCTAssertEqual(response.failure, .cancelled)
        XCTAssertEqual(response.cleanup?.observedProcessAbsent, true)
        XCTAssertTrue(state.finished)
    }

    func testChangedPostExecutionAuthorityRefusesSuccessfulToolResult() async throws {
        let state = ExecutionState()
        let principal = Phase2ShellBrokerPrincipal(sourcePlanAuthority: { value in
            if state.finished { throw CocoaError(.fileReadCorruptFile) }
            return Self.plan(value)
        }, sourceExecutor: { plan, cancelled in state.run(plan, cancelled: cancelled) })
        let response = try Phase2SourceExecutionWireCodec.decodeResponse(await execute(principal,
            bytes: Phase2SourceExecutionWireCodec.encodeRequest(request())))
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.failure, .authorityRejected)
        XCTAssertEqual(response.cleanup?.observedProcessAbsent, true)
        XCTAssertEqual(response.terminal, .init(kind: .exited, status: 0))
    }

    func testDefaultAuthorityRejectsForgedToolAndStageBeforeLaunch() async throws {
        let state = ExecutionState()
        let principal = Phase2ShellBrokerPrincipal(sourceExecutor: { plan, cancelled in
            state.run(plan, cancelled: cancelled)
        })
        let response = try Phase2SourceExecutionWireCodec.decodeResponse(await execute(principal,
            bytes: Phase2SourceExecutionWireCodec.encodeRequest(request())))
        XCTAssertEqual(response.status, .rejected)
        XCTAssertNil(response.cleanup)
        XCTAssertEqual(state.count, 0)
    }

    func testProfileDispatchKeepsSchemaOneBytesAndRejectsNewModesBeforeExecution() async throws {
        let scalar = request(), state = ExecutionState(), principal = makePrincipal(state)
        let bytes = try Phase2SourceExecutionWireCodec.encodeRequest(scalar)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["schemaVersion", "requestID", "sessionID", "operation", "sourceAuthority",
            "stageRootPath", "revisionSHA256", "sourceSHA256", "harnessSHA256", "compilerPath", "sdkRootPath",
            "toolchainRootPath", "runnerSHA256", "compilerSHA256", "sdkSettingsSHA256"]))
        XCTAssertEqual(scalar.sourceProfile?.rawValue, "arm64-c-u32-saturating-increment-v1")
        XCTAssertEqual(try Phase2SourceExecutionWireCodec.encodeRequest(
            Phase2SourceExecutionWireCodec.decodeRequest(bytes)), bytes)
        for profile in ["arm64-c-adler32-combine-record-v1", "unknown-profile"] {
            var changed = object; changed["profileID"] = profile
            let rejected = try Phase2SourceExecutionWireCodec.decodeResponse(await execute(principal,
                bytes: JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes])))
            XCTAssertEqual(rejected.status, .invalid)
            XCTAssertEqual(rejected.failure, .authorityRejected)
            XCTAssertNil(rejected.requestID)
        }
        var changed = object; changed["schemaVersion"] = 2
        let rejected = try Phase2SourceExecutionWireCodec.decodeResponse(await execute(principal,
            bytes: JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes])))
        XCTAssertEqual(rejected.status, .invalid)
        XCTAssertEqual(rejected.failure, .authorityRejected)
        XCTAssertNil(rejected.requestID)
        XCTAssertEqual(state.count, 0)
    }

    private var digest: String { String(repeating: "a", count: 64) }
    private func request(authority: Phase2SourceExecutionAuthorityKind = .admittedRevision,
                         revision: String? = String(repeating: "a", count: 64)) -> Phase2SourceExecutionRequest {
        .init(requestID: UUID(), sessionID: UUID(), operation: .inspect,
              sourceAuthority: authority, stageRootPath: TestWorkRoot.authorityPath("source-xpc-fixture"),
              revisionSHA256: revision, sourceSHA256: digest, harnessSHA256: digest,
              compilerPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang",
              sdkRootPath: "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
              toolchainRootPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain",
              runnerSHA256: digest, compilerSHA256: digest, sdkSettingsSHA256: digest)
    }
    private func makePrincipal(_ state: ExecutionState) -> Phase2ShellBrokerPrincipal {
        .init(sourcePlanAuthority: Self.plan, sourceExecutor: { plan, cancelled in
            state.run(plan, cancelled: cancelled)
        })
    }
    nonisolated private static func plan(_ request: Phase2SourceExecutionRequest) -> Phase2HumanPTYLaunchPlan {
        .init(sessionID: request.sessionID, requestID: request.requestID,
              executablePath: "/Applications/MacScope.app/Contents/MacOS/SourceExecutionRunner",
              arguments: [request.operation.rawValue, request.stageRootPath, request.compilerPath,
                          request.sdkRootPath, request.toolchainRootPath], initialSize: .defaultInteractive)
    }
    private func execute(_ principal: Phase2ShellBrokerPrincipal, bytes: Data) async -> Data {
        await withCheckedContinuation { continuation in
            principal.executeSource(bytes) { continuation.resume(returning: $0) }
        }
    }
    private func cancel(_ principal: Phase2ShellBrokerPrincipal, bytes: Data) async -> Data {
        await withCheckedContinuation { continuation in
            principal.cancelSource(bytes) { continuation.resume(returning: $0) }
        }
    }
    private func waitUntilStarted(_ state: ExecutionState) async throws {
        for _ in 0..<200 {
            if state.count > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Source execution did not start")
    }
}

private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var executionCount = 0
    private var didFinish = false
    private let waitForCancellation: Bool
    init(waitForCancellation: Bool = false) { self.waitForCancellation = waitForCancellation }
    var count: Int { lock.lock(); defer { lock.unlock() }; return executionCount }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return didFinish }
    func run(_ plan: Phase2HumanPTYLaunchPlan, cancelled: @Sendable () -> Bool) -> ReconstructionSourceExecutionResult {
        lock.lock(); executionCount += 1; lock.unlock()
        let deadline = Date().addingTimeInterval(3)
        if waitForCancellation {
            while !cancelled() && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        }
        let wasCancelled = cancelled()
        let outcome: Phase2HumanPTYTerminalOutcome = wasCancelled ? .canceled : .exited(status: 0)
        lock.lock(); didFinish = true; lock.unlock()
        return .init(failure: wasCancelled ? .cancelled : nil, terminalOutcome: outcome,
            diagnostics: Data(), peakGroupResidentBytes: 100, sampledProcessIDs: [12345], elapsedSeconds: 0.1,
            cleanupProof: .init(sessionID: plan.sessionID, requestID: plan.requestID,
                processIdentifier: 12345, observedProcessAbsent: true, outcome: outcome))
    }
}

private final class SourceReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var value: Data? { lock.lock(); defer { lock.unlock() }; return data }
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
}
