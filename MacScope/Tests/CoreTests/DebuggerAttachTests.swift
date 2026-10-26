import XCTest
@testable import MacScope
#if canImport(Darwin)
import Darwin
#endif

/// Coverage for the legacy attach UI boundary and the exact local-process attach
/// client seam:
///
///  * attach-request validation accepts a positive numeric PID and rejects
///    pid <= 0 / self / non-numeric / out-of-range,
///  * the process-list provider is exercised through a fake,
///  * the view-model's legacy raw-PID action remains policy-gated,
///  * the typed identity-bound API exists and fails closed by default, and
///  * neither production nor injected-session adapters forward raw PIDs to LLDB.
///
/// Fixtures are self-contained so this file never collides with the shared test
/// doubles in the other debugger test files.
@MainActor
final class DebuggerAttachTests: XCTestCase {

    // MARK: - Attach-request validation

    func testAttachRequestParseAcceptsPositiveNumericPID() {
        guard case .success(let request) = DebuggerAttachPIDRequest.parse("4242", selfProcessID: 1) else {
            return XCTFail("A positive numeric PID should parse.")
        }
        XCTAssertEqual(request.processID, 4242)
        XCTAssertEqual(request.displayName, "pid 4242")
    }

    func testAttachRequestParseTrimsWhitespace() {
        guard case .success(let request) = DebuggerAttachPIDRequest.parse("  77  ", selfProcessID: 1) else {
            return XCTFail("Surrounding whitespace should be trimmed.")
        }
        XCTAssertEqual(request.processID, 77)
    }

    func testAttachRequestParseRejectsNonPositiveAndNonNumeric() {
        if case .success = DebuggerAttachPIDRequest.parse("0", selfProcessID: 1) {
            XCTFail("PID 0 should be rejected.")
        }
        if case .success = DebuggerAttachPIDRequest.parse("-5", selfProcessID: 1) {
            XCTFail("A negative PID should be rejected.")
        }
        if case .success = DebuggerAttachPIDRequest.parse("", selfProcessID: 1) {
            XCTFail("An empty PID should be rejected.")
        }
        if case .success = DebuggerAttachPIDRequest.parse("12a", selfProcessID: 1) {
            XCTFail("A non-numeric PID should be rejected.")
        }
        // Outside the pid_t (Int32) range -> Int32(_:) returns nil -> rejected.
        if case .success = DebuggerAttachPIDRequest.parse("99999999999", selfProcessID: 1) {
            XCTFail("An out-of-range PID should be rejected.")
        }
    }

    func testAttachRequestParseRejectsSelfPID() {
        if case .success = DebuggerAttachPIDRequest.parse("321", selfProcessID: 321) {
            XCTFail("Attaching MacScope's own PID should be rejected.")
        }
        // A different PID with the same injected self is fine.
        guard case .success = DebuggerAttachPIDRequest.parse("322", selfProcessID: 321) else {
            return XCTFail("A non-self PID should be accepted.")
        }
    }

    func testAttachRequestValidateMirrorsParse() {
        if case .success = DebuggerAttachPIDRequest.validate(processID: -1, selfProcessID: 9) {
            XCTFail("validate(processID:) should reject a non-positive PID.")
        }
        guard case .success(let request) = DebuggerAttachPIDRequest.validate(processID: 555, selfProcessID: 9) else {
            return XCTFail("validate(processID:) should accept a valid PID.")
        }
        XCTAssertEqual(request.processID, 555)
    }

    // MARK: - Process-list provider (fake)

    func testProcessListerFakeSurfacesEntries() throws {
        let lister = FakeProcessLister(entries: [
            DebuggerProcessListEntry(processID: 10, name: "alpha"),
            DebuggerProcessListEntry(processID: 20, name: "beta")
        ])
        let entries = try lister.listProcesses()
        XCTAssertEqual(entries.map(\.processID), [10, 20])
        XCTAssertEqual(entries.first?.displayName, "alpha")
        XCTAssertEqual(entries.first?.detail, "pid 10")
    }

    func testProcessListEntryDisplayNameFallsBackToPID() {
        let entry = DebuggerProcessListEntry(processID: 99, name: "   ")
        XCTAssertEqual(entry.displayName, "pid 99")
    }

    func testViewModelRefreshAttachProcessListPopulatesAndClearsError() {
        let lister = FakeProcessLister(entries: [
            DebuggerProcessListEntry(processID: 33, name: "gamma")
        ])
        let client = AttachRecordingDebuggerClient(initialSnapshot: Self.idleAttachableSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client, processLister: lister, selfProcessID: 1)

        viewModel.refreshAttachProcessList()
        XCTAssertEqual(viewModel.attachProcessList.map(\.processID), [33])

        viewModel.selectAttachProcess(viewModel.attachProcessList[0])
        XCTAssertEqual(viewModel.attachProcessIDText, "33")
    }

    func testViewModelRefreshAttachProcessListSurfacesListerError() {
        let lister = FakeProcessLister(error: .enumerationFailed("table unavailable"))
        let client = AttachRecordingDebuggerClient(initialSnapshot: Self.idleAttachableSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client, processLister: lister, selfProcessID: 1)

        viewModel.refreshAttachProcessList()
        XCTAssertTrue(viewModel.attachProcessList.isEmpty)
        XCTAssertEqual(viewModel.lastError, "table unavailable")
    }

    // MARK: - View-model attach action (gated to idle + policy, validates input)

    func testViewModelAttachIsPolicyBlockedEvenWhenBackendReportsAttachSupport() async {
        // The honest signed-target posture: even a backend that reports an attach
        // transport keeps attach blocked until the policy is proven. The action
        // surfaces the policy reason as a typed error and never reaches the client.
        let client = AttachRecordingDebuggerClient(initialSnapshot: Self.idleAttachableSnapshot)
        let viewModel = DebuggerPanelViewModel(
            client: client,
            attachPolicyOverride: .denied(reason: DebuggerPanelViewModel.signedTargetAttachPolicyReason),
            selfProcessID: 1
        )

        viewModel.attachProcessIDText = "4242"

        // The PID is valid, but the policy gate keeps the action blocked.
        XCTAssertNil(viewModel.attachValidationMessage)
        XCTAssertFalse(viewModel.canAttachToProcess)
        XCTAssertTrue(viewModel.attachDisabledReason?.contains(DebuggerPanelViewModel.signedTargetAttachPolicyReason) ?? false)

        await viewModel.attachToProcess()

        XCTAssertEqual(client.attachCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.contains(DebuggerPanelViewModel.signedTargetAttachPolicyReason) ?? false)
        XCTAssertFalse(viewModel.session.processState.isPaused)
    }

    func testViewModelAttachRejectsInvalidPIDWithoutClientCall() async {
        let client = AttachRecordingDebuggerClient(initialSnapshot: Self.idleAttachableSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client, selfProcessID: 1)

        viewModel.attachProcessIDText = "not-a-pid"
        XCTAssertFalse(viewModel.canAttachToProcess)

        await viewModel.attachToProcess()

        XCTAssertEqual(client.attachCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.contains("not a valid pid") ?? false)
    }

    func testViewModelAttachGatedOffWhenAlreadyAttached() async {
        // A live (paused) session is not idle -> attach is gated off and the
        // action never reaches the client. (The policy gate also blocks it; both
        // are honest reasons to keep the control disabled.)
        let client = AttachRecordingDebuggerClient(initialSnapshot: Self.liveAttachedSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client, selfProcessID: 1)

        viewModel.attachProcessIDText = "4242"
        XCTAssertFalse(viewModel.canAttachToProcess)

        await viewModel.attachToProcess()
        XCTAssertEqual(client.attachCallCount, 0)
    }

    func testTypedLocalClientAttachRejectsNonIdleSessionBeforeBackend() async throws {
        let adapter = TypedAttachRecordingAdapter()
        let client = LocalLLDBDebuggerClient(adapter: adapter)
        let request = try Self.makeExactAttachRequest(processID: 222)
        let paused = DebuggerSessionSnapshot(
            processState: .paused(processID: 999, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 999, adapterName: "Xcode LLDB Live")
        )

        do {
            _ = try await client.attach(request, from: paused)
            XCTFail("Attach should be rejected from a non-idle session.")
        } catch let error as DebuggerClientError {
            guard case .invalidState(let reason) = error else {
                return XCTFail("Expected invalidState, got \(error).")
            }
            XCTAssertTrue(reason.contains("Cannot attach"))
        } catch {
            XCTFail("Expected a DebuggerClientError, got \(error).")
        }
        XCTAssertEqual(adapter.attachCallCount, 0)
    }

    func testViewModelAttachGatedOffWhenBackendDisallowsAttach() async {
        // When the backend itself reports the attach transport unsupported, the
        // attach control is honestly blocked and the action surfaces the
        // unavailable reason without reaching the client.
        let client = AttachPolicyBlockedDebuggerClient(initialSnapshot: Self.idleAttachableSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client, selfProcessID: 1)

        viewModel.attachProcessIDText = "4242"
        XCTAssertFalse(viewModel.canAttachToProcess)

        await viewModel.attachToProcess()
        XCTAssertEqual(client.attachCallCount, 0)
        XCTAssertTrue(viewModel.lastError?.hasPrefix("Attach unavailable:") ?? false)
    }

    func testViewModelAuthorizesCatalogSelectionBeforeTypedAttach() async throws {
        let provider = AttachDiscoveryEvidenceProvider(processIDs: [4242])
        let discoveryService = DebuggerLocalProcessDiscoveryService(
            observer: DebuggerLocalProcessIdentityObserver(provider: provider),
            limits: .init(
                maximumCandidateCount: 4,
                maximumRetainedRows: 4,
                maximumConcurrentObservers: 1,
                publicationBatchSize: 1
            )
        )
        let client = ExactAttachRecordingDebuggerClient(initialSnapshot: Self.idleAttachableSnapshot)
        let viewModel = DebuggerPanelViewModel(
            client: client,
            localProcessDiscoveryService: discoveryService,
            attachPolicyOverride: .supported,
            selfProcessID: 1
        )

        await viewModel.refreshLocalProcessCatalog()
        let entry = try XCTUnwrap(viewModel.localProcessDiscoverySnapshot.entries.first)
        viewModel.selectLocalProcess(entry)

        XCTAssertNil(viewModel.selectedLocalProcessAttachDisabledReason)
        XCTAssertTrue(viewModel.canAttachSelectedLocalProcess)

        await viewModel.attachSelectedLocalProcess()

        XCTAssertEqual(client.exactAttachCallCount, 1)
        XCTAssertEqual(client.rawPIDAttachCallCount, 0)
        XCTAssertEqual(client.lastExactAttachRequest?.selectedIdentity.processID, 4242)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
        let authorizationPassCount = await provider.authorizationPassCount
        XCTAssertEqual(authorizationPassCount, 2)
    }

    // MARK: - Exact API and retired raw-PID transport

    func testLegacyRawPIDAttachCannotReachInjectedLiveTransport() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = AttachFakeLLDBCommandSessionTransport(responses: [])
        let runner = AttachFakeDebuggerProcessRunner(result: .successfulProof)
        let adapter = XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeAttachProof",
            liveSessionFactory: { transport }
        )
        let client = LocalLLDBDebuggerClient(adapter: adapter)

        let idle = client.makeInitialSnapshot()
        guard case .success(let request) = DebuggerAttachPIDRequest.parse("222", selfProcessID: 1) else {
            return XCTFail("PID should parse.")
        }

        do {
            _ = try await client.attach(toPID: request, from: idle)
            XCTFail("The raw-PID compatibility seam must fail closed.")
        } catch let error as DebuggerClientError {
            guard case .unsupportedOperation(let reason) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error).")
            }
            XCTAssertTrue(reason.contains("Raw PID attach is disabled"))
        }

        do {
            _ = try await adapter.attach(toPID: request, from: idle)
            XCTFail("The command-line adapter must also reject raw-PID attach directly.")
        } catch let error as DebuggerClientError {
            guard case .unsupportedOperation(let reason) = error else {
                return XCTFail("Expected adapter unsupportedOperation, got \(error).")
            }
            XCTAssertTrue(reason.contains("Raw PID attach is disabled"))
        }

        XCTAssertTrue(transport.sentCommands.isEmpty)
        XCTAssertEqual(transport.stopCallCount, 0)
    }

    func testTypedLocalAttachExistsAndFailsClosedAtDefaultAdapterBoundary() async throws {
        let adapter = TypedAttachDefaultUnsupportedAdapter()
        let client = LocalLLDBDebuggerClient(adapter: adapter)
        let request = try Self.makeExactAttachRequest(processID: 222)

        do {
            _ = try await client.attach(request, from: client.makeInitialSnapshot())
            XCTFail("An adapter without an exact attach transaction must fail closed.")
        } catch let error as DebuggerClientError {
            guard case .unsupportedOperation(let reason) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error).")
            }
            XCTAssertTrue(reason.contains("Exact local-process attach"))
        }
    }

    func testDebuggerClientTypedAttachDefaultDoesNotFallBackToRawPID() async throws {
        let client = AttachRecordingDebuggerClient(initialSnapshot: Self.idleAttachableSnapshot)
        let request = try Self.makeExactAttachRequest(processID: 222)

        do {
            _ = try await client.attach(request, from: client.makeInitialSnapshot())
            XCTFail("A client without exact attach must fail closed.")
        } catch let error as DebuggerClientError {
            guard case .unsupportedOperation(let reason) = error else {
                return XCTFail("Expected unsupportedOperation, got \(error).")
            }
            XCTAssertTrue(reason.contains("Exact local-process attach"))
        }

        XCTAssertEqual(client.attachCallCount, 0)
    }

    func testTypedLocalClientAttachThrowsHonestPolicyErrorWhenUnsupported() async throws {
        // A backend whose attachSupport is unsupported (the default posture) must
        // surface a typed, honest error rather than attempt the attach.
        let adapter = AttachUnsupportedAdapter()
        let client = LocalLLDBDebuggerClient(adapter: adapter)
        let request = try Self.makeExactAttachRequest(processID: 222)

        do {
            _ = try await client.attach(request, from: client.makeInitialSnapshot())
            XCTFail("Attach should be rejected under the default policy.")
        } catch let error as DebuggerClientError {
            guard case .backendUnavailable(let reason) = error else {
                return XCTFail("Expected backendUnavailable, got \(error).")
            }
            XCTAssertTrue(reason.contains("attach"))
        } catch {
            XCTFail("Expected a DebuggerClientError, got \(error).")
        }
    }

    // MARK: - Shared snapshot fixtures

    /// An idle (not-attached) snapshot whose backend can attach (test fixtures
    /// force the policy on); attach is reachable and gated only by session state.
    private static var idleAttachableSnapshot: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready to attach.",
            backendState: .ready(adapterName: "Attach Recording LLDB")
        )
    }

    private static var liveAttachedSnapshot: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 222, adapterName: "Attach Recording LLDB")
        )
    }

    private static func makeExactAttachRequest(processID: Int32) throws -> DebuggerLocalAttachRequest {
        let startTime = try XCTUnwrap(DebuggerProcessStartIdentity(seconds: 123, microseconds: 456))
        let identity = try XCTUnwrap(
            DebuggerLocalProcessIdentity(
                processID: processID,
                startTime: startTime,
                realUserID: 501,
                effectiveUserID: 501,
                canonicalExecutablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture",
                executableDeviceID: 16,
                executableFileID: 32,
                executableByteCount: 4_096,
                executableSHA256: String(repeating: "a", count: 64),
                architecture: .arm64,
                machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
                codeIdentity: nil
            )
        )
        return DebuggerLocalAttachRequest(selectedIdentity: identity)
    }
}

// MARK: - Self-contained test doubles

private struct FakeProcessLister: DebuggerProcessLister {
    var entries: [DebuggerProcessListEntry] = []
    var error: DebuggerProcessListError?

    func listProcesses() throws -> [DebuggerProcessListEntry] {
        if let error { throw error }
        return entries
    }
}

private actor AttachDiscoveryEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private let processIDsValue: [Int32]
    private(set) var authorizationPassCount = 0

    init(processIDs: [Int32]) {
        self.processIDsValue = processIDs
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        .resolved(processIDsValue)
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        guard let evidence = Self.catalogEvidenceFixture(processID: processID) else {
            return .unknown(.unstableSnapshot)
        }
        return .resolved(evidence)
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        authorizationPassCount += 1
        guard let catalog = Self.catalogEvidenceFixture(processID: processID),
              let identity = DebuggerLocalProcessIdentity(
                  processID: processID,
                  startTime: catalog.fingerprint.startTime,
                  realUserID: Self.currentUserID,
                  effectiveUserID: Self.currentEffectiveUserID,
                  canonicalExecutablePath: catalog.fingerprint.canonicalExecutablePath,
                  executableDeviceID: catalog.fingerprint.executableDeviceID,
                  executableFileID: catalog.fingerprint.executableFileID,
                  executableByteCount: catalog.fingerprint.executableByteCount,
                  executableSHA256: String(repeating: "a", count: 64),
                  architecture: catalog.fingerprint.architecture,
                  machOUUID: catalog.fingerprint.machOUUID,
                  codeIdentity: nil
              ) else {
            return .unknown(.unstableSnapshot)
        }
        return .resolved(
            DebuggerLocalProcessAuthorizationEvidence(
                catalogEvidence: catalog,
                identity: identity
            )
        )
    }

    private static func catalogEvidenceFixture(
        processID: Int32
    ) -> DebuggerLocalProcessCatalogEvidence? {
        guard let startTime = DebuggerProcessStartIdentity(seconds: UInt64(processID) + 10, microseconds: 12),
              let fingerprint = DebuggerLocalProcessCatalogFingerprint(
                  processID: processID,
                  startTime: startTime,
                  realUserID: currentUserID,
                  effectiveUserID: currentEffectiveUserID,
                  canonicalExecutablePath: "/tmp/MacScopeAttachFixture\(processID)",
                  executableDeviceID: 16,
                  executableFileID: UInt64(processID) + 100,
                  executableByteCount: 4_096,
                  executableChangeTimeNanoseconds: UInt64(processID) + 200,
                  architecture: .arm64,
                  machOUUID: nil,
                  codeIdentity: nil
              ) else {
            return nil
        }
        return DebuggerLocalProcessCatalogEvidence(
            fingerprint: fingerprint,
            displayName: "AttachFixture\(processID)",
            parentProcessID: 2,
            savedUserID: currentUserID,
            dynamicState: DebuggerLocalProcessDynamicState()
        )
    }

    private static var currentUserID: UInt32 {
        #if canImport(Darwin)
        getuid()
        #else
        0
        #endif
    }

    private static var currentEffectiveUserID: UInt32 {
        #if canImport(Darwin)
        geteuid()
        #else
        0
        #endif
    }
}

@MainActor
private final class ExactAttachRecordingDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var exactAttachCallCount = 0
    private(set) var rawPIDAttachCallCount = 0
    private(set) var lastExactAttachRequest: DebuggerLocalAttachRequest?

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Exact Attach Recording LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: true,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { initialSnapshot }

    func attach(
        _ request: DebuggerLocalAttachRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        exactAttachCallCount += 1
        lastExactAttachRequest = request
        var copy = snapshot
        copy.processState = .paused(
            processID: request.selectedIdentity.processID,
            reason: .unknown("Attached to exact local process")
        )
        copy.backendState = .connected(
            processID: request.selectedIdentity.processID,
            adapterName: "Exact Attach Recording LLDB"
        )
        copy.statusMessage = "Attached to exact local process."
        let sessionCoordinate = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(),
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
        )
        let stopCoordinate = DebuggerStopCoordinate(
            session: sessionCoordinate,
            stopRevision: DebuggerStopRevision(rawValue: 1)
        )
        copy.transportSessionCoordinate = sessionCoordinate
        copy.transportStopCoordinate = stopCoordinate
        copy.transportEventSequence = DebuggerEventSequence(rawValue: 1)
        copy.transportTargetDisposition = .stopped(processID: request.selectedIdentity.processID)
        copy.transportTargetAuthority = DebuggerSessionTargetAuthority(
            origin: .attached(request.selectedIdentity)
        )
        return copy
    }

    func attach(
        toPID request: DebuggerAttachPIDRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        rawPIDAttachCallCount += 1
        return snapshot
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

/// Legacy compatibility double. The view-model policy intentionally prevents its
/// raw-PID method from being reached even when this double advertises support.
@MainActor
private final class AttachRecordingDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var attachCallCount = 0
    private(set) var lastAttachRequest: DebuggerAttachPIDRequest?

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Attach Recording LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: true,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { initialSnapshot }

    func attach(toPID request: DebuggerAttachPIDRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        attachCallCount += 1
        lastAttachRequest = request
        var copy = snapshot
        copy.processState = .paused(processID: request.processID, reason: .unknown("Attached to \(request.displayName)"))
        copy.backendState = .connected(processID: request.processID, adapterName: "Attach Recording LLDB")
        copy.statusMessage = "Attached to \(request.displayName)."
        return copy
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

/// A backend that keeps attach disabled (the default signed-target posture).
@MainActor
private final class AttachPolicyBlockedDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var attachCallCount = 0

    init(initialSnapshot: DebuggerSessionSnapshot) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Attach Blocked LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: [],
        attachSupport: .unsupported(reason: "Attach remains disabled until signed-target policy is proven.")
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { initialSnapshot }

    func attach(toPID request: DebuggerAttachPIDRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        attachCallCount += 1
        return snapshot
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

@MainActor
private final class TypedAttachRecordingAdapter: LLDBDebuggerBackendAdapter {
    private(set) var attachCallCount = 0

    let capabilities = DebuggerCapabilityReport(
        backendName: "Typed Attach Recording LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: true,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )
    let initialBackendState: DebuggerBackendSessionState = .ready(adapterName: "Typed Attach Recording LLDB")

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { .empty }
    func attach(_ request: DebuggerLocalAttachRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        attachCallCount += 1
        return snapshot
    }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

/// Reports attach capability so the client reaches the adapter, then relies on
/// the protocol default to prove that exact attach remains opt-in and fail-closed.
@MainActor
private struct TypedAttachDefaultUnsupportedAdapter: LLDBDebuggerBackendAdapter {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Typed Attach Default LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: true,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )
    let initialBackendState: DebuggerBackendSessionState = .ready(adapterName: "Typed Attach Default LLDB")

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { .empty }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

/// A minimal adapter whose attach support is unsupported (the default policy
/// posture), used to prove the honest typed-error gate in `LocalLLDBDebuggerClient`.
@MainActor
private struct AttachUnsupportedAdapter: LLDBDebuggerBackendAdapter {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Attach Unsupported LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: [],
        attachSupport: .unsupported(reason: "Attach by pid is disabled until signed-target policy is proven.")
    )
    let initialBackendState: DebuggerBackendSessionState = .ready(adapterName: "Attach Unsupported LLDB")

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("launch")
    }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}

private final class AttachFakeDebuggerProcessRunner: DebuggerProcessRunning {
    private let result: DebuggerSubprocessResult
    init(result: DebuggerSubprocessResult) { self.result = result }
    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult { result }
}

private final class AttachFakeLLDBCommandSessionTransport: DebuggerLLDBCommandSessionTransport {
    private var responses: [DebuggerLLDBCommandResponse]
    private(set) var sentCommands: [String] = []
    private(set) var stopCallCount = 0

    init(responses: [DebuggerLLDBCommandResponse]) {
        self.responses = responses
    }

    func start(_ command: DebuggerExternalCommand) throws {}

    func send(_ command: String, timeoutSeconds: TimeInterval) throws -> DebuggerLLDBCommandResponse {
        sentCommands.append(command)
        guard !responses.isEmpty else {
            throw DebuggerLLDBCommandSessionError.writeFailed("Attach fake transport has no queued response.")
        }
        var response = responses.removeFirst()
        response.command = command
        return response
    }

    func stop() { stopCallCount += 1 }
}

private extension DebuggerSubprocessResult {
    static var successfulProof: DebuggerSubprocessResult {
        DebuggerSubprocessResult(
            terminationStatus: 0,
            standardOutput: """
            (lldb) version
            lldb-2103.0.23.6
            (lldb) platform status
              Platform: host
                Triple: arm64-apple-macosx
            (lldb) settings show target.default-arch
            target.default-arch (arch) =
            """,
            standardError: "",
            timedOut: false
        )
    }
}

// MARK: - Stuck "launching" regression (round 4 lane X)

/// A launch/attach must never leave the session in `.launching` once no start is actually in
/// flight. Before the fix, a second Attach fired in the same run-loop turn as the first (sheet
/// button plus Return/row double-click) re-captured `.launching` as its "previous" state and
/// superseded the first start's acceptance ticket, so the session stayed `.launching` forever and
/// every later attach was refused with "Cannot attach while the debugger is launching".
@MainActor
final class DebuggerAttachStartLifecycleTests: XCTestCase {

    func testDoubleFiredAttachIsRefusedVisiblyAndFirstAttachCompletes() async throws {
        let client = ScriptedStartDebuggerClient()
        client.holdsAttach = true
        let viewModel = try await makeViewModel(client: client)

        let first = Task { await viewModel.attachSelectedLocalProcess() }
        let second = Task { await viewModel.attachSelectedLocalProcess() }
        await second.value
        XCTAssertEqual(viewModel.localProcessAttachRefusal, DebuggerPanelViewModel.sessionStartInFlightReason)
        XCTAssertTrue(viewModel.localProcessAttachSheetStatus.isWarning)

        try await waitUntil { client.attachCallCount == 1 && client.hasHeldAttach }
        XCTAssertFalse(viewModel.canAttachSelectedLocalProcess)
        client.releaseHeldAttach()
        await first.value

        XCTAssertEqual(client.attachCallCount, 1)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
        XCTAssertFalse(viewModel.isSessionStartInFlight)
        XCTAssertNil(viewModel.localProcessAttachRefusal)
    }

    func testUnacceptedAttachResultReturnsToIdleAndAdmitsNextAttach() async throws {
        let client = ScriptedStartDebuggerClient()
        client.nextAttachIsMalformed = true
        let viewModel = try await makeViewModel(client: client)

        await viewModel.attachSelectedLocalProcess()

        XCTAssertEqual(viewModel.session.processState, .notAttached)
        XCTAssertFalse(viewModel.isSessionStartInFlight)
        let refusal = try XCTUnwrap(viewModel.localProcessAttachRefusal)
        XCTAssertTrue(refusal.contains("did not complete"), refusal)
        XCTAssertEqual(viewModel.localProcessAttachSheetStatus.message, refusal)
        XCTAssertTrue(viewModel.localProcessAttachSheetStatus.isWarning)

        // The refusal does not disable Attach; the retry is admitted and attaches.
        XCTAssertTrue(viewModel.canAttachSelectedLocalProcess)
        await viewModel.attachSelectedLocalProcess()
        XCTAssertEqual(client.attachCallCount, 2)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
    }

    func testFailedLaunchReturnsToIdleThenAttachIsAdmitted() async throws {
        let client = ScriptedStartDebuggerClient()
        client.launchError = DebuggerClientError.invalidState("debugserver refused the launch")
        let viewModel = try await makeViewModel(client: client)

        await viewModel.launch(configuration: DebuggerLaunchConfiguration(executablePath: "/bin/sleep"))

        XCTAssertEqual(viewModel.session.processState, .notAttached)
        XCTAssertFalse(viewModel.isSessionStartInFlight)
        XCTAssertNil(viewModel.selectedLocalProcessAttachDisabledReason)

        await viewModel.attachSelectedLocalProcess()
        XCTAssertEqual(client.attachCallCount, 1)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
    }

    func testTransportRefusedAttachShowsItsReasonInTheSheet() async throws {
        let client = ScriptedStartDebuggerClient()
        client.attachError = DebuggerClientError.backendFailure("debugserver could not attach: denied")
        let viewModel = try await makeViewModel(client: client)

        await viewModel.attachSelectedLocalProcess()

        XCTAssertFalse(viewModel.session.hasLiveProcessSession)
        if case .launching = viewModel.session.processState {
            XCTFail("A refused attach must not leave the session launching.")
        }
        let status = viewModel.localProcessAttachSheetStatus
        XCTAssertTrue(status.isWarning)
        XCTAssertTrue(status.message.contains("debugserver could not attach"), status.message)
    }

    // MARK: Helpers

    private func makeViewModel(client: ScriptedStartDebuggerClient) async throws -> DebuggerPanelViewModel {
        let provider = AttachDiscoveryEvidenceProvider(processIDs: [4242])
        let discoveryService = DebuggerLocalProcessDiscoveryService(
            observer: DebuggerLocalProcessIdentityObserver(provider: provider),
            limits: .init(
                maximumCandidateCount: 4,
                maximumRetainedRows: 4,
                maximumConcurrentObservers: 1,
                publicationBatchSize: 1
            )
        )
        let viewModel = DebuggerPanelViewModel(
            client: client,
            localProcessDiscoveryService: discoveryService,
            attachPolicyOverride: .supported,
            selfProcessID: 1
        )
        await viewModel.refreshLocalProcessCatalog()
        let entry = try XCTUnwrap(viewModel.localProcessDiscoverySnapshot.entries.first)
        viewModel.selectLocalProcess(entry)
        XCTAssertTrue(viewModel.canAttachSelectedLocalProcess)
        return viewModel
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "Condition not reached.")
    }
}

@MainActor
private final class ScriptedStartDebuggerClient: DebuggerClient {
    var holdsAttach = false
    var nextAttachIsMalformed = false
    var attachError: Error?
    var launchError: Error?
    private(set) var attachCallCount = 0
    private var heldAttach: CheckedContinuation<Void, Never>?
    var hasHeldAttach: Bool { heldAttach != nil }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Scripted Start LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: true,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func releaseHeldAttach() {
        heldAttach?.resume()
        heldAttach = nil
    }

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready to attach.",
            backendState: .ready(adapterName: "Scripted Start LLDB")
        )
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        if let launchError { throw launchError }
        return makeInitialSnapshot()
    }

    func attach(
        _ request: DebuggerLocalAttachRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        attachCallCount += 1
        // Mirrors LocalLLDBDebuggerClient: the transport refuses to attach from a non-idle
        // snapshot. The view model used to pass its own `.launching` placeholder here.
        guard snapshot.processState.canLaunchNewProcess else {
            throw DebuggerClientError.invalidState(
                "Cannot attach while the debugger is \(snapshot.processState.displayTitle.lowercased())."
            )
        }
        if holdsAttach {
            await withCheckedContinuation { heldAttach = $0 }
        }
        if let attachError { throw attachError }
        let processID = request.selectedIdentity.processID
        var copy = snapshot
        copy.processState = .paused(processID: processID, reason: .unknown("Attached"))
        copy.backendState = .connected(processID: processID, adapterName: "Scripted Start LLDB")
        copy.statusMessage = "Attached."
        let sessionCoordinate = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(),
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
        )
        copy.transportSessionCoordinate = sessionCoordinate
        if nextAttachIsMalformed {
            // Typed transport metadata without an event sequence/disposition is invalid
            // authority; the acceptance gate must refuse it.
            nextAttachIsMalformed = false
            return copy
        }
        copy.transportStopCoordinate = DebuggerStopCoordinate(
            session: sessionCoordinate,
            stopRevision: DebuggerStopRevision(rawValue: 1)
        )
        copy.transportEventSequence = DebuggerEventSequence(rawValue: 1)
        copy.transportTargetDisposition = .stopped(processID: processID)
        copy.transportTargetAuthority = DebuggerSessionTargetAuthority(
            origin: .attached(request.selectedIdentity)
        )
        return copy
    }

    func attach(
        toPID request: DebuggerAttachPIDRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot { snapshot }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func writeRegister(_ request: DebuggerRegisterWriteRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func readMemory(_ request: DebuggerMemoryReadRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}
