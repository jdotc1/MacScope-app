import CoreFoundation
import Darwin
import Foundation
import XCTest

@testable import MacScope

/// Opt-in, serialized host proof for the real WS-19/WS-21 production transport.
///
/// The ordinary CoreTests run skips this test unless the caller supplies the absolute path to a
/// pre-verified, certificate-signed debugger fixture in `MACSCOPE_DEBUGGER_LIVE_FIXTURE`. The test
/// observes process identity through public libproc APIs, but delegates every termination action
/// to `LocalLLDBDebuggerClient`; it never signals an enumerated PID.
@MainActor
final class DebuggerPersistentProductionLiveSmokeTests: XCTestCase {
    private enum WS21CallbackScenario: String {
        case ordinaryStop = "ordinary callback stop"
        case ignoreFirst = "ignore-first callback policy"
        case falseCondition = "false-condition auto-continue"
        case logAndContinue = "typed log-and-continue drain"
        case targetExpression = "typed target-expression result"
        case expressionTimeout = "per-expression timeout enforcement"
        case totalDeadline = "total callback deadline enforcement"
        case exactCleanup = "exact breakpoint cleanup and zero process residue"
    }

    private struct WS21CallbackProof {
        let scenario: WS21CallbackScenario
        let condition: String?
        let hitPolicy: DebuggerBreakpointHitPolicy
        let actions: [DebuggerBreakpointAction]
        let disposition: DebuggerBreakpointDisposition
        let expectedOutcomes: [DebuggerBreakpointCallbackOutcome]
        let requiredCapabilities: Set<LLDBLogicalBreakpointCapability>
        let callbackStopsTarget: Bool
        let minimumCallbackDuration: Duration?
        let maximumCallbackDuration: Duration?

        var expectsPublicCallbackDrainFailure: Bool {
            switch scenario {
            case .expressionTimeout, .totalDeadline: true
            case .ordinaryStop, .ignoreFirst, .falseCondition, .logAndContinue,
                 .targetExpression, .exactCleanup: false
            }
        }
    }

    private struct WS21BreakpointAuthority {
        let workspaceID: UUID
        let catalogID: UUID
        let logicalID: DebuggerLogicalBreakpointID
        let artifactCatalog: DebuggerWorkspaceArtifactCatalog
        let resolutionOwner: DebuggerBreakpointResolutionOwnerIndex
    }

    private struct WS21F3BreakpointAuthority {
        let workspaceID: UUID
        let catalogID: UUID
        let artifactCatalog: DebuggerWorkspaceArtifactCatalog
        let resolutionOwners: [DebuggerBreakpointResolutionOwnerIndex]
        let mainOwner: DebuggerWorkspaceImageOwnerSeal
        let frameworkOwner: DebuggerWorkspaceImageOwnerSeal
        let mainLogicalID: DebuggerLogicalBreakpointID
        let frameworkLogicalID: DebuggerLogicalBreakpointID
    }

    private struct WS21F3ReconcileBundle {
        let request: DebuggerLogicalBreakpointReconcileRequest
        let resolutions: [DebuggerLogicalBreakpointResolution]
        let projection: DebuggerRuntimeMappingProjection
    }

    private enum WS21F3ExpectedResolution {
        case resolved
        case pendingModuleUnloaded
    }

    /// Test-only route to the real production controller. Normal app construction continues to
    /// reject legacy breakpoint replacement; this wrapper admits it only so the live gate can
    /// seed one genuinely foreign breakpoint inside the same retained LLDB adapter and prove that
    /// logical reconciliation and private Run to Cursor never delete it.
    @MainActor
    private final class WS21F3ProductionAdapter: LLDBDebuggerBackendAdapter {
        let capabilities: DebuggerCapabilityReport
        let initialBackendState: DebuggerBackendSessionState
        /// Retains the exact actors injected into both the capability adapter and controller.
        private let runtimeAuthorities: DebuggerRuntimeAuthorities
        private let controller: PersistentLLDBProductionController

        init(
            toolchain: DebuggerLLDBToolchain,
            environment: [String: String],
            workingDirectory: String
        ) {
            let runtimeAuthorities = DebuggerRuntimeAuthorities()
            self.runtimeAuthorities = runtimeAuthorities
            let capabilityAdapter = XcodeLLDBCommandLineAdapter(
                toolchain: toolchain,
                processRunner: FoundationDebuggerProcessRunner(),
                environment: environment,
                workingDirectory: workingDirectory,
                launchTimeoutSeconds: 10,
                usePersistentTransport: true,
                debuggerSessionLeaseRegistry:
                    runtimeAuthorities.sessionLeaseRegistry,
                ownedInfrastructureRegistry:
                    runtimeAuthorities.ownedInfrastructureRegistry,
                observationPolicyProvider:
                    runtimeAuthorities.observationPolicyProvider
            )
            capabilities = capabilityAdapter.capabilities
            initialBackendState = capabilityAdapter.initialBackendState
            controller = PersistentLLDBProductionController(
                toolchain: toolchain,
                environment: environment,
                fallbackWorkingDirectory: workingDirectory,
                commandTimeoutSeconds: 10,
                debuggerSessionLeaseRegistry:
                    runtimeAuthorities.sessionLeaseRegistry,
                ownedInfrastructureRegistry:
                    runtimeAuthorities.ownedInfrastructureRegistry,
                observationPolicyProvider:
                    runtimeAuthorities.observationPolicyProvider
            )
        }

        func launch(
            _ configuration: DebuggerLaunchConfiguration
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.launch(configuration)
        }

        func attach(
            _ request: DebuggerLocalAttachRequest,
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            _ = snapshot
            return try await controller.attach(request)
        }

        func continueExecution(
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.continueExecution(from: snapshot)
        }

        func runToCursor(
            _ request: DebuggerRunToCursorRequest,
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.runToCursor(request, from: snapshot)
        }

        func stepOver(
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.stepOver(from: snapshot)
        }

        func pause(
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.pause(from: snapshot)
        }

        func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
            try await controller.detach(from: snapshot)
        }

        func terminate(
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.terminate(from: snapshot)
        }

        func replaceBreakpoints(
            _ breakpoints: [DebuggerBreakpoint],
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.replaceBreakpoints(breakpoints, from: snapshot)
        }

        func reconcileLogicalBreakpoints(
            _ request: DebuggerLogicalBreakpointReconcileRequest,
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.reconcileLogicalBreakpoints(request, from: snapshot)
        }

        func refreshSnapshot(
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.refreshSnapshot(from: snapshot)
        }

        func pollProcessStatus(
            from snapshot: DebuggerSessionSnapshot
        ) async throws -> DebuggerSessionSnapshot {
            try await controller.pollProcessStatus(from: snapshot)
        }
    }

    private struct RecordedProcess {
        let observation: Phase2QualificationProcessObservation
        let executablePath: String

        var processID: Int32 { observation.processID }
    }

    private enum SmokeFailure: Error, CustomStringConvertible {
        case backendUnavailable(String)
        case invalidProcessState(String)
        case processObservation(String)
        case processResidue(String)

        var description: String {
            switch self {
            case .backendUnavailable(let detail):
                "Persistent LLDB backend unavailable: \(detail)"
            case .invalidProcessState(let detail):
                "Unexpected persistent LLDB state: \(detail)"
            case .processObservation(let detail):
                "Could not establish exact process ownership: \(detail)"
            case .processResidue(let detail):
                "Persistent LLDB live-smoke residue: \(detail)"
            }
        }
    }

    /// Swift counterpart of the checked fixture protocol in
    /// `Scripts/debugger-fixture/Sources/fixture_runtime.c`. The signed fixture creates the FIFO
    /// and event file; XCTest owns only this fresh 0700 directory, one retained FIFO descriptor,
    /// and exact nonce/sequence correlation. This is deliberately test-local and never becomes a
    /// debugger transport escape hatch.
    @MainActor
    private final class WS21FixtureControlChannel {
        private static let maximumEventBytes = 1 << 20

        let root: URL
        let nonce: String
        let startedAfterNanoseconds: UInt64
        private var commandDescriptor: Int32 = -1
        private var nextCommandSequence: UInt64 = 1
        private var lastEventSequence: UInt64 = 0

        var launchArguments: [String] {
            [
                "--control-dir", root.path,
                "--nonce", nonce,
                "--started-after-ns", String(startedAfterNanoseconds),
            ]
        }

        init() throws {
            var now = timespec()
            guard clock_gettime(CLOCK_REALTIME, &now) == 0,
                  now.tv_sec >= 0,
                  now.tv_nsec >= 0 else {
                throw SmokeFailure.processObservation(
                    "could not record the fixture control-root creation boundary"
                )
            }
            let seconds = UInt64(now.tv_sec).multipliedReportingOverflow(by: 1_000_000_000)
            let nanoseconds = seconds.partialValue.addingReportingOverflow(UInt64(now.tv_nsec))
            guard !seconds.overflow, !nanoseconds.overflow else {
                throw SmokeFailure.processObservation(
                    "fixture control-root creation boundary overflowed UInt64"
                )
            }
            startedAfterNanoseconds = nanoseconds.partialValue
            nonce = "ws21-\(UUID().uuidString.lowercased())"
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacScope-WS21-callback-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(root.path, 0o700) == 0 else {
                try? FileManager.default.removeItem(at: root)
                throw SmokeFailure.processObservation(
                    "could not enforce mode 0700 on the fixture control root"
                )
            }
        }

        deinit {
            if commandDescriptor >= 0 {
                Darwin.close(commandDescriptor)
            }
        }

        func open(forProcessID processID: Int32, timeout: Duration) async throws {
            guard processID > 0 else {
                throw SmokeFailure.processObservation(
                    "fixture control admission requires a positive target PID"
                )
            }
            if commandDescriptor >= 0 { return }
            let path = root.appendingPathComponent("main.commands").path
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            repeat {
                var pathMetadata = stat()
                if lstat(path, &pathMetadata) == 0 {
                    try Self.requireOwnedFIFO(pathMetadata, description: "fixture command path")
                    let descriptor = Darwin.open(
                        path,
                        O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
                    )
                    if descriptor >= 0 {
                        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
                            Darwin.close(descriptor)
                            throw SmokeFailure.processObservation(
                                "could not suppress SIGPIPE on the fixture command FIFO"
                            )
                        }
                        var descriptorMetadata = stat()
                        guard fstat(descriptor, &descriptorMetadata) == 0 else {
                            Darwin.close(descriptor)
                            throw SmokeFailure.processObservation(
                                "could not inspect the opened fixture command FIFO"
                            )
                        }
                        do {
                            try Self.requireOwnedFIFO(
                                descriptorMetadata,
                                description: "opened fixture command FIFO"
                            )
                            guard pathMetadata.st_dev == descriptorMetadata.st_dev,
                                  pathMetadata.st_ino == descriptorMetadata.st_ino else {
                                throw SmokeFailure.processObservation(
                                    "fixture command FIFO identity changed during admission"
                                )
                            }
                        } catch {
                            Darwin.close(descriptor)
                            throw error
                        }
                        commandDescriptor = descriptor
                        try await requireReadyEvent(processID: processID, timeout: timeout)
                        return
                    }
                    guard errno == ENXIO || errno == ENOENT else {
                        throw SmokeFailure.processObservation(
                            "could not open the fixture command FIFO (errno \(errno))"
                        )
                    }
                } else if errno != ENOENT {
                    throw SmokeFailure.processObservation(
                        "could not inspect the fixture command FIFO (errno \(errno))"
                    )
                }
                if clock.now < deadline {
                    try await clock.sleep(for: .milliseconds(10))
                }
            } while clock.now < deadline
            throw SmokeFailure.processObservation(
                "fixture command FIFO admission timed out after \(timeout)"
            )
        }

        @discardableResult
        func send(
            _ operation: String,
            processID: Int32,
            timeout: Duration
        ) async throws -> [String: Any] {
            guard ["load", "checkpoint", "unload", "exit"].contains(operation),
                  commandDescriptor >= 0 else {
                throw SmokeFailure.processObservation(
                    "fixture command requires an admitted FIFO and a supported operation"
                )
            }
            let sequence = nextCommandSequence
            var payload = try JSONSerialization.data(
                withJSONObject: [
                    "nonce": nonce,
                    "operation": operation,
                    "schema": 1,
                    "sequence": sequence,
                ],
                options: [.sortedKeys]
            )
            payload.append(0x0A)
            do {
                try writeAll(payload)
            } catch {
                throw SmokeFailure.processObservation(
                    "fixture \(operation) command \(sequence) write failed: \(error)"
                )
            }

            let event = try await waitForEvent(
                processID: processID,
                commandSequence: sequence,
                timeout: timeout
            )
            guard event["operation"] as? String == operation,
                  event["result"] as? String == "ok" else {
                throw SmokeFailure.processObservation(
                    "fixture rejected correlated \(operation) command \(sequence)"
                )
            }
            nextCommandSequence += 1
            return event
        }

        func cleanup() throws {
            closeCommandDescriptor()
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }

        private func requireReadyEvent(processID: Int32, timeout: Duration) async throws {
            _ = try await waitForEvent(
                processID: processID,
                commandSequence: nil,
                expectedOperation: "ready",
                timeout: timeout
            )
        }

        private func waitForEvent(
            processID: Int32,
            commandSequence: UInt64?,
            expectedOperation: String? = nil,
            timeout: Duration
        ) async throws -> [String: Any] {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            repeat {
                for event in try events(processID: processID) {
                    guard let sequence = Self.exactUInt64(event["sequence"]),
                          sequence > lastEventSequence else { continue }
                    lastEventSequence = sequence
                    let matchesCommand = commandSequence == nil
                        || Self.exactUInt64(event["commandSequence"]) == commandSequence
                    let matchesOperation = expectedOperation == nil
                        || event["operation"] as? String == expectedOperation
                    if matchesCommand && matchesOperation { return event }
                }
                if clock.now < deadline {
                    try await clock.sleep(for: .milliseconds(10))
                }
            } while clock.now < deadline
            throw SmokeFailure.processObservation(
                "fixture event correlation timed out after \(timeout)"
            )
        }

        private func events(processID: Int32) throws -> [[String: Any]] {
            let path = root.appendingPathComponent("main.events.jsonl")
            guard FileManager.default.fileExists(atPath: path.path) else { return [] }
            let data = try Data(contentsOf: path, options: [.mappedIfSafe])
            guard data.count <= Self.maximumEventBytes else {
                throw SmokeFailure.processObservation(
                    "fixture event stream exceeds the 1 MiB test bound"
                )
            }
            return try data.split(separator: 0x0A).map { line in
                guard let value = try JSONSerialization.jsonObject(with: Data(line))
                        as? [String: Any],
                      Self.exactUInt64(value["schema"]) == 1,
                      value["nonce"] as? String == nonce,
                      value["role"] as? String == "main",
                      Self.exactInt32(value["pid"]) == processID,
                      Self.exactUInt64(value["sequence"]) != nil else {
                    throw SmokeFailure.processObservation(
                        "fixture event stream contains an identity or schema mismatch"
                    )
                }
                return value
            }
        }

        private func writeAll(_ data: Data) throws {
            var offset = 0
            try data.withUnsafeBytes { rawBuffer in
                while offset < rawBuffer.count {
                    guard let baseAddress = rawBuffer.baseAddress else {
                        throw SmokeFailure.processObservation(
                            "fixture command payload has no storage"
                        )
                    }
                    let written = Darwin.write(
                        commandDescriptor,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    guard written > 0 else {
                        throw SmokeFailure.processObservation(
                            "fixture command FIFO write failed (errno \(errno))"
                        )
                    }
                    offset += written
                }
            }
        }

        private func closeCommandDescriptor() {
            if commandDescriptor >= 0 {
                Darwin.close(commandDescriptor)
                commandDescriptor = -1
            }
        }

        private static func requireOwnedFIFO(
            _ metadata: stat,
            description: String
        ) throws {
            guard metadata.st_mode & S_IFMT == S_IFIFO,
                  metadata.st_mode & 0o777 == 0o600,
                  metadata.st_uid == geteuid() else {
                throw SmokeFailure.processObservation(
                    "\(description) is not the exact current-user mode-0600 FIFO"
                )
            }
        }

        private static func exactUInt64(_ value: Any?) -> UInt64? {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let decimal = number.stringValue
            guard let parsed = UInt64(decimal), String(parsed) == decimal else { return nil }
            return parsed
        }

        private static func exactInt32(_ value: Any?) -> Int32? {
            guard let exact = exactUInt64(value), exact <= UInt64(Int32.max) else { return nil }
            return Int32(exact)
        }
    }

    // MARK: - WS-21 D4 callback proof matrix

    func testLogicalBreakpointCallbackStopsWithTypedRecordAndNoRawStdout() async throws {
        try await runWS21CallbackLiveProof(WS21CallbackProof(
            scenario: .ordinaryStop,
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop,
            expectedOutcomes: [.stopped],
            requiredCapabilities: [],
            callbackStopsTarget: true,
            minimumCallbackDuration: nil,
            maximumCallbackDuration: nil
        ))
    }

    func testLogicalBreakpointIgnoreFirstSkipsFirstHitThenStops() async throws {
        try await runWS21CallbackLiveProof(WS21CallbackProof(
            scenario: .ignoreFirst,
            condition: nil,
            hitPolicy: .ignoreFirst(1),
            actions: [],
            disposition: .stop,
            expectedOutcomes: [.ignored, .stopped],
            requiredCapabilities: [.ignoreFirst],
            callbackStopsTarget: true,
            minimumCallbackDuration: nil,
            maximumCallbackDuration: nil
        ))
    }

    func testLogicalBreakpointFalseConditionContinuesWithoutRunningActions() async throws {
        try await runWS21CallbackLiveProof(WS21CallbackProof(
            scenario: .falseCondition,
            condition: "0",
            hitPolicy: .always,
            actions: [.log(try DebuggerBreakpointLogTemplate(fragments: [
                .literal("MACSCOPE_WS21_FALSE_CONDITION_ACTION_MUST_NOT_RUN"),
            ]))],
            disposition: .stop,
            expectedOutcomes: [.conditionFalse],
            requiredCapabilities: [.condition, .actions],
            callbackStopsTarget: false,
            minimumCallbackDuration: nil,
            maximumCallbackDuration: nil
        ))
    }

    func testLogicalBreakpointLogAndContinueDrainsTypedRecordWithoutRawStdout() async throws {
        try await runWS21CallbackLiveProof(WS21CallbackProof(
            scenario: .logAndContinue,
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .continueAfterSuccessfulActions,
            expectedOutcomes: [.continued],
            requiredCapabilities: [
                .actions, .continueAfterSuccessfulActions,
            ],
            callbackStopsTarget: false,
            minimumCallbackDuration: nil,
            maximumCallbackDuration: nil
        ))
    }

    func testLogicalBreakpointTargetExpressionDrainsTypedResult() async throws {
        try await runWS21CallbackLiveProof(WS21CallbackProof(
            scenario: .targetExpression,
            condition: nil,
            hitPolicy: .always,
            actions: [.evaluateTargetExpression(try DebuggerBreakpointExpressionCapture(
                label: "counter",
                expression: "(unsigned long long)macscope_fixture_main_counter"
            ))],
            disposition: .continueAfterSuccessfulActions,
            expectedOutcomes: [.continued],
            requiredCapabilities: [
                .actions, .targetExpression, .continueAfterSuccessfulActions,
            ],
            callbackStopsTarget: false,
            minimumCallbackDuration: nil,
            maximumCallbackDuration: nil
        ))
    }

    func testLogicalBreakpointTargetExpressionTimeoutTerminatesAndReaps() async throws {
        try await runWS21CallbackLiveProof(WS21CallbackProof(
            scenario: .expressionTimeout,
            condition: nil,
            hitPolicy: .always,
            actions: [.evaluateTargetExpression(try DebuggerBreakpointExpressionCapture(
                label: "slow",
                expression: "({ volatile unsigned long long i = 0; "
                    + "while (i != 0xffffffffffffffffULL) { ++i; } i; })"
            ))],
            disposition: .continueAfterSuccessfulActions,
            expectedOutcomes: [.fault(code: "expression-timeout")],
            requiredCapabilities: [
                .actions, .targetExpression, .continueAfterSuccessfulActions,
            ],
            callbackStopsTarget: true,
            minimumCallbackDuration: .milliseconds(200),
            maximumCallbackDuration: .milliseconds(750)
        ))
    }

    func testLogicalBreakpointTotalCallbackDeadlineTerminatesAndReaps() async throws {
        let actions = try (0..<6).map { index in
            DebuggerBreakpointAction.evaluateTargetExpression(
                try DebuggerBreakpointExpressionCapture(
                    label: "delay-\(index)",
                    expression: "((int (*)(unsigned int))usleep)(180000)"
                )
            )
        }
        try await runWS21CallbackLiveProof(WS21CallbackProof(
            scenario: .totalDeadline,
            condition: nil,
            hitPolicy: .always,
            actions: actions,
            disposition: .continueAfterSuccessfulActions,
            expectedOutcomes: [.fault(code: "callback-deadline")],
            requiredCapabilities: [
                .actions, .targetExpression, .continueAfterSuccessfulActions,
            ],
            callbackStopsTarget: true,
            minimumCallbackDuration: .milliseconds(800),
            maximumCallbackDuration: .milliseconds(1_500)
        ))
    }

    func testLogicalBreakpointExactCleanupLeavesNoOwnedBreakpointsOrProcessResidue() async throws {
        try await runWS21CallbackLiveProof(WS21CallbackProof(
            scenario: .exactCleanup,
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop,
            expectedOutcomes: [.stopped],
            requiredCapabilities: [],
            callbackStopsTarget: true,
            minimumCallbackDuration: nil,
            maximumCallbackDuration: nil
        ))
    }

    // MARK: - Saved breakpoint across the entry stop (RX01, selected Xcode LLDB)

    /// Tier 2e regression: with one saved logical breakpoint, Launch Target stops at entry, the
    /// breakpoint is armed through the production reconcile path, and Continue must stop at that
    /// breakpoint instead of failing the callback drain into partial-mutation recovery and
    /// wedging the backend. Runs the production client against the RX01 fixture and real LLDB.
    func testSavedBreakpointLaunchAtEntryThenContinueStopsAtBreakpoint() async throws {
        try await runSavedBreakpointRX01Proof(hitPolicy: .always)
    }

    /// A saved breakpoint whose callback auto-continues (ignore-first) lets RX01 run to exit from
    /// the entry-stop Continue. The exited target must settle cleanly and admit a fresh launch.
    func testSavedAutoContinueBreakpointRunsToExitAndAdmitsRelaunch() async throws {
        try await runSavedBreakpointRX01Proof(hitPolicy: .ignoreFirst(1))
    }

    /// A failed fail-closed stopped mutation (thread select of an absent thread) recovers by
    /// terminating the launched target. Once that target is provably gone, Launch Target must be
    /// admitted again instead of reporting a wedged backend.
    func testFailedStoppedMutationRecoveryAdmitsRelaunch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let developerDirectory = environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        guard FileManager.default.isExecutableFile(atPath: developerDirectory + "/usr/bin/lldb") else {
            throw XCTSkip("Xcode LLDB is unavailable on this host.")
        }
        let fixtureURL = TestSourceRoot.url
            .appendingPathComponent("MacScope/Tests/Fixtures/RX01Versioned/rx01_v1")
            .standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: fixtureURL.path) else {
            throw XCTSkip("RX01 fixture is unavailable.")
        }
        let configuration = DebuggerLaunchConfiguration(
            executablePath: fixtureURL.path,
            workingDirectory: fixtureURL.deletingLastPathComponent().path
        )
        let client = LocalLLDBDebuggerClient(debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities())
        guard client.capabilities.isBackendAvailable, client.capabilities.canLaunch else {
            throw XCTSkip("The persistent LLDB backend is unavailable on this host.")
        }
        var launchedIDs: [Int32] = []
        defer {
            for processID in launchedIDs where processExists(processID) {
                _ = Darwin.kill(processID, SIGKILL)
            }
        }
        var snapshot = try await client.launch(configuration)
        guard case .paused(let firstID, _) = snapshot.processState else {
            return XCTFail("launch did not stop at entry: \(snapshot.processState.displayTitle)")
        }
        launchedIDs.append(firstID)
        do {
            _ = try await client.selectThread(
                DebuggerThreadSelectionRequest(index: 9_999),
                from: snapshot
            )
            XCTFail("Selecting an absent thread must fail.")
        } catch {
            // Expected: the absent thread index is rejected.
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        while processExists(firstID), clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(processExists(firstID), "the recovered launched target must be gone")

        do {
            snapshot = try await client.launch(configuration)
        } catch {
            return XCTFail("Relaunch after recovered mutation failure was refused: \(error)")
        }
        guard case .paused(let secondID, _) = snapshot.processState else {
            return XCTFail("relaunch did not stop at entry: \(snapshot.processState.displayTitle)")
        }
        launchedIDs.append(secondID)
        snapshot = try await client.terminate(from: snapshot)
    }

    // MARK: - Multi-thread selection (lane AQ, source-built 4-thread fixture, selected Xcode LLDB)

    /// Tier 2k C6 regression: stopped at `rendezvous` with four live threads, selecting each
    /// listed thread through the production client must commit that selection (not fail the
    /// coordinator and orphan LLDB), and Continue afterwards must run the fixture to exit with no
    /// LLDB, debugserver or debuggee residue once the client is released.
    func testMultiThreadStopSelectsEveryListedThreadThenContinues() async throws {
        let live = try await launchThreadsFixtureToRendezvous()
        var snapshot = live.snapshot
        var client: LocalLLDBDebuggerClient? = live.client
        var ownedProcesses = live.ownedProcesses
        defer { client = nil }
        do {
            XCTAssertEqual(snapshot.threads.count, 4, "\(snapshot.threads)")
            let stopThread = try XCTUnwrap(snapshot.threads.first(where: \.isSelected))
            let listed = snapshot.threads.map(\.index)
            for index in listed + [stopThread.index] {
                do {
                    snapshot = try await client!.selectThread(
                        DebuggerThreadSelectionRequest(index: index),
                        from: snapshot
                    )
                } catch {
                    throw SmokeFailure.invalidProcessState("select thread #\(index): \(error)")
                }
                XCTAssertEqual(
                    snapshot.threads.filter(\.isSelected).map(\.index), [index],
                    "thread #\(index) selection did not commit"
                )
                XCTAssertEqual(snapshot.threads.map(\.index), listed)
                XCTAssertFalse(snapshot.frames.isEmpty, "thread #\(index) has no frames")
                guard case .paused(let processID, _) = snapshot.processState,
                      processID == live.processID else {
                    throw SmokeFailure.invalidProcessState(
                        "thread #\(index) selection left \(snapshot.processState.displayTitle)"
                    )
                }
            }
            let resumed = try await client!.continueExecution(from: snapshot)
            snapshot = try await waitForProcessExit(
                client: client!,
                initialSnapshot: resumed,
                expectedProcessID: live.processID,
                timeout: .seconds(10)
            )
            if snapshot.canTerminateLiveProcess {
                snapshot = try await client!.terminate(from: snapshot)
            }
            client = nil
            try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            try requireNoNewLLDBChild(
                parentProcessID: Int32(Darwin.getpid()),
                baseline: live.baselineChildren,
                expectedLLDBPath: live.lldbPath,
                observer: Phase2QualificationLibprocProcessObserver()
            )
        } catch {
            if let cleanupClient = client, snapshot.canTerminateLiveProcess {
                _ = try? await cleanupClient.terminate(from: snapshot)
            }
            client = nil
            ownedProcesses.merge(live.ownedProcesses) { existing, _ in existing }
            try? await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            throw error
        }
    }

    /// Lane AU (§4.88, §4.86a): the panel's select-each sequence from the Tier 2l re-check (two
    /// runs that failed on a third selection with `adapterInvalidated`) plus more, at least ten
    /// selections on one stop. Every selection must commit and keep the same paused process.
    /// After each thread, frame #1 is selected: its registers must come from frame #1 (the `pc`
    /// equals frame #1's address), which fails if `frame select` shares the inspection exchange.
    func testSelectEachThreadSequenceKeepsTheStoppedSessionAndFramePC() async throws {
        let live = try await launchThreadsFixtureToRendezvous()
        var snapshot = live.snapshot
        var client: LocalLLDBDebuggerClient? = live.client
        var ownedProcesses = live.ownedProcesses
        defer { client = nil }
        do {
            let listed = snapshot.threads.map(\.index)
            XCTAssertEqual(listed.count, 4, "\(snapshot.threads)")
            let sequence = [1, 2, 3, 3, 1, 4, 2, 3, 2, 1, 4, 1, 2, 3, 4].filter(listed.contains)
            XCTAssertGreaterThanOrEqual(sequence.count, 10)
            var frameSelections = 0
            var rearms = 0
            for (step, index) in sequence.enumerated() {
                do {
                    snapshot = try await client!.selectThread(
                        DebuggerThreadSelectionRequest(index: index),
                        from: snapshot
                    )
                } catch {
                    throw SmokeFailure.invalidProcessState(
                        "selection \(step + 1) (thread #\(index)): \(error)"
                    )
                }
                XCTAssertEqual(snapshot.threads.filter(\.isSelected).map(\.index), [index])
                guard case .paused(let processID, _) = snapshot.processState,
                      processID == live.processID else {
                    throw SmokeFailure.invalidProcessState(
                        "selection \(step + 1) left \(snapshot.processState.displayTitle)"
                    )
                }
                // The panel re-arms the saved breakpoint whenever an accepted stopped snapshot
                // moves the runtime mapping key (every selection refreshes runtime modules).
                let rearm = try makeWS21ReconcileRequest(
                    authority: live.breakpointAuthority,
                    specifications: [live.breakpointSpecification],
                    catalogRevision: 1,
                    resolutionRevision: 1,
                    snapshot: snapshot
                )
                if snapshot.transportBreakpointBindingState?.resolutionObservation
                    != rearm.observation {
                    do {
                        snapshot = try await client!.reconcileLogicalBreakpoints(
                            rearm,
                            from: snapshot
                        )
                        rearms += 1
                    } catch {
                        throw SmokeFailure.invalidProcessState(
                            "re-arm after selection \(step + 1): \(error)"
                        )
                    }
                }
                guard step.isMultiple(of: 3), snapshot.frames.count > 1 else { continue }
                let target = snapshot.frames[1]
                do {
                    snapshot = try await client!.selectFrame(
                        DebuggerFrameSelectionRequest(index: target.index),
                        from: snapshot
                    )
                } catch {
                    throw SmokeFailure.invalidProcessState(
                        "frame #\(target.index) of thread #\(index): \(error)"
                    )
                }
                frameSelections += 1
                let pc = try XCTUnwrap(snapshot.registers.first { $0.name == "pc" }?.value)
                XCTAssertEqual(
                    UInt64(pc.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16),
                    target.address,
                    "thread #\(index) frame #\(target.index) registers came from another frame"
                )
                XCTAssertEqual(snapshot.liveProcessID, live.processID)
            }
            XCTAssertGreaterThan(frameSelections, 0)
            // The panel does not disable thread rows while a selection runs, so quick clicks
            // overlap. Three concurrent selections must all commit (in some order) without
            // losing the stopped session.
            let burst = [3, 1, 4].filter(listed.contains)
            let burstClient = client!
            let burstSnapshot = snapshot
            typealias BurstOutcome = (Int, Result<DebuggerSessionSnapshot, Error>)
            let outcomes = await withTaskGroup(of: BurstOutcome.self) { group in
                for (offset, index) in burst.enumerated() {
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(5 * offset))
                        do {
                            return (index, .success(try await burstClient.selectThread(
                                DebuggerThreadSelectionRequest(index: index),
                                from: burstSnapshot
                            )))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var collected: [BurstOutcome] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            for (index, outcome) in outcomes {
                switch outcome {
                case .success(let next):
                    XCTAssertEqual(next.liveProcessID, live.processID, "burst thread #\(index)")
                    snapshot = next
                case .failure(let error):
                    XCTFail("concurrent selection of thread #\(index) failed: \(error)")
                }
            }
            snapshot = try await client!.refreshSnapshot(from: snapshot)
            XCTAssertEqual(snapshot.liveProcessID, live.processID)
            print(
                "select-each sequence: \(sequence.count) selections, "
                    + "\(frameSelections) frame selections, \(rearms) re-arms"
            )
            snapshot = try await client!.terminate(from: snapshot)
            client = nil
            try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            try requireNoNewLLDBChild(
                parentProcessID: Int32(Darwin.getpid()),
                baseline: live.baselineChildren,
                expectedLLDBPath: live.lldbPath,
                observer: Phase2QualificationLibprocProcessObserver()
            )
        } catch {
            if let cleanupClient = client, snapshot.canTerminateLiveProcess {
                _ = try? await cleanupClient.terminate(from: snapshot)
            }
            client = nil
            ownedProcesses.merge(live.ownedProcesses) { existing, _ in existing }
            try? await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            throw error
        }
    }

    /// Lane AU (§4.88c), the Tier 2o UI sequence B: breakpoint stop on thread #4 → select a
    /// thread that did not stop → Continue → Pause about 1.5 s later. Pause must stop the same
    /// live process (the fixture's `--hold` keeps all four threads running) with the session
    /// intact, and termination leaves no LLDB, debugserver or debuggee behind.
    func testPauseAfterSelectingANonStoppingThreadAndContinuingKeepsTheSession() async throws {
        try await runPauseAfterBreakpointProof(selectThread2: true)
    }

    func testPauseAfterBreakpointWithoutThreadSelectionKeepsTheSession() async throws {
        try await runPauseAfterBreakpointProof(selectThread2: false)
    }

    private func runPauseAfterBreakpointProof(selectThread2: Bool) async throws {
        let live = try await launchThreadsFixtureToRendezvous(arguments: ["--hold"])
        var snapshot = live.snapshot
        var client: LocalLLDBDebuggerClient? = live.client
        var ownedProcesses = live.ownedProcesses
        defer { client = nil }
        do {
            if selectThread2 {
                let other = try XCTUnwrap(snapshot.threads.first { $0.index == 2 && !$0.isSelected })
                print("AU sequence B selected thread 2: \(other)")
                snapshot = try await client!.selectThread(
                    DebuggerThreadSelectionRequest(index: other.index),
                    from: snapshot
                )
                XCTAssertEqual(snapshot.threads.filter(\.isSelected).map(\.index), [2])
            }
            snapshot = try await client!.continueExecution(from: snapshot)
            // The panel keeps observing a running process; poll like it does until Pause.
            let clock = ContinuousClock()
            let pauseAt = clock.now.advanced(by: .milliseconds(1_500))
            while clock.now < pauseAt {
                if case .running = snapshot.processState {
                    snapshot = try await client!.pollProcessStatus(from: snapshot)
                }
                try await clock.sleep(for: .milliseconds(250))
            }
            guard case .running(let running) = snapshot.processState,
                  running.processID == live.processID else {
                throw SmokeFailure.invalidProcessState(
                    "continue left \(snapshot.processState.displayTitle)"
                )
            }
            do {
                snapshot = try await client!.pause(from: snapshot)
            } catch {
                throw SmokeFailure.invalidProcessState("pause after select + continue: \(error)")
            }
            guard case .paused(let pausedID, _) = snapshot.processState,
                  pausedID == live.processID else {
                throw SmokeFailure.invalidProcessState(
                    "pause left \(snapshot.processState.displayTitle)"
                )
            }
            XCTAssertEqual(snapshot.liveProcessID, live.processID)
            XCTAssertFalse(snapshot.threads.isEmpty)
            snapshot = try await client!.terminate(from: snapshot)
            client = nil
            try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            try requireNoNewLLDBChild(
                parentProcessID: Int32(Darwin.getpid()),
                baseline: live.baselineChildren,
                expectedLLDBPath: live.lldbPath,
                observer: Phase2QualificationLibprocProcessObserver()
            )
        } catch {
            if let cleanupClient = client, snapshot.canTerminateLiveProcess {
                _ = try? await cleanupClient.terminate(from: snapshot)
            }
            client = nil
            ownedProcesses.merge(live.ownedProcesses) { existing, _ in existing }
            try? await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            throw error
        }
    }

    /// Lane AU (§4.86b): a step whose correlated session fails (the retained LLDB adapter died
    /// underneath it) must retire the session like the stopped-state operations: LLDB,
    /// debugserver and the launched debuggee are gone (ESRCH) while the client is still alive,
    /// and Launch Target is admitted again.
    func testStepFailureRetiresAdapterLeavesNoOrphansAndAdmitsRelaunch() async throws {
        let live = try await launchThreadsFixtureToRendezvous()
        var client: LocalLLDBDebuggerClient? = live.client
        var snapshot = live.snapshot
        var ownedProcesses = live.ownedProcesses
        defer { client = nil }
        let adapterProcessID = try XCTUnwrap(ownedProcesses.values.first {
            $0.executablePath == live.lldbPath
        }?.processID)
        XCTAssertEqual(Darwin.kill(adapterProcessID, SIGKILL), 0)
        try await ContinuousClock().sleep(for: .milliseconds(300))
        do {
            _ = try await client!.stepOver(from: snapshot)
            return XCTFail("A step through a crashed adapter must not succeed.")
        } catch let error as DebuggerClientError {
            switch error {
            case .backendFailure, .backendUnavailable:
                break
            default:
                return XCTFail("expected a retired-session failure, got \(error)")
            }
        }
        // Retirement happens inside the failed step, before the client is released.
        try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))

        let observer = Phase2QualificationLibprocProcessObserver()
        do {
            snapshot = try await client!.launch(DebuggerLaunchConfiguration(
                executablePath: live.fixturePath,
                workingDirectory: URL(fileURLWithPath: live.fixturePath)
                    .deletingLastPathComponent().path
            ))
        } catch {
            return XCTFail("Relaunch after a failed step was refused: \(error)")
        }
        guard case .paused(let relaunchedID, _) = snapshot.processState else {
            return XCTFail("relaunch did not stop at entry: \(snapshot.processState.displayTitle)")
        }
        if let observation = try observer.observation(processID: relaunchedID) {
            ownedProcesses[relaunchedID] = RecordedProcess(
                observation: observation,
                executablePath: live.fixturePath
            )
        }
        snapshot = try await client!.terminate(from: snapshot)
        client = nil
        try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
        try requireNoNewLLDBChild(
            parentProcessID: Int32(Darwin.getpid()),
            baseline: live.baselineChildren,
            expectedLLDBPath: live.lldbPath,
            observer: observer
        )
    }

    /// Lane AQ: a request LLDB merely rejects (an unmapped memory read) keeps the exact stopped
    /// session live and selectable instead of hiding it from the panel. A coordinator failure
    /// that loses the backend (the retained LLDB adapter crashing underneath the session) must
    /// leave no LLDB, debugserver or launched debuggee behind while the client is still alive,
    /// then admit a fresh launch on the same client.
    func testCoordinatorFailureRetiresAdapterAndAdmitsRelaunch() async throws {
        let live = try await launchThreadsFixtureToRendezvous()
        var client: LocalLLDBDebuggerClient? = live.client
        var snapshot = live.snapshot
        var ownedProcesses = live.ownedProcesses
        defer { client = nil }
        XCTAssertGreaterThanOrEqual(ownedProcesses.count, 2, "LLDB adapter and debuggee recorded")
        let unmapped = DebuggerMemoryReadRequest(address: 0x10, byteCount: 16)
        do {
            _ = try await client!.readMemory(unmapped, from: snapshot)
            XCTFail("Reading an unmapped page must be rejected.")
        } catch let error as DebuggerClientError {
            guard case .invalidState = error else {
                return XCTFail("a correlated rejection must keep the session: \(error)")
            }
        }
        snapshot = try await client!.selectThread(
            DebuggerThreadSelectionRequest(index: 1),
            from: snapshot
        )
        XCTAssertEqual(snapshot.liveProcessID, live.processID)

        // Crash the retained LLDB adapter underneath the session (only the exact LLDB child this
        // test's client started). The next request fails in the coordinator; recovery must reap
        // LLDB, leave no debugserver behind and make sure the launched debuggee is gone.
        let adapterProcessID = try XCTUnwrap(ownedProcesses.values.first {
            $0.executablePath == live.lldbPath
        }?.processID)
        XCTAssertEqual(Darwin.kill(adapterProcessID, SIGKILL), 0)
        let clock = ContinuousClock()
        // The kill is asynchronous; a read that still reaches the live adapter is an ordinary
        // correlated rejection. Once the adapter is gone the coordinator fails and the session
        // must be retired.
        var lostTargetFailure: DebuggerClientError?
        let observeDeadline = clock.now.advanced(by: .seconds(5))
        while lostTargetFailure == nil, clock.now < observeDeadline {
            do {
                _ = try await client!.readMemory(unmapped, from: snapshot)
                return XCTFail("A memory read through a crashed adapter must not succeed.")
            } catch let error as DebuggerClientError {
                if case .invalidState(let reason) = error, reason.contains("rejected by LLDB") {
                    try await clock.sleep(for: .milliseconds(200))
                    continue
                }
                lostTargetFailure = error
            }
        }
        switch lostTargetFailure {
        case .backendFailure?, .backendUnavailable?:
            break
        case .invalidState(let reason)? where reason.contains("requires an established"):
            break // the controller had already retired the session on its own
        default:
            return XCTFail("expected the session to be retired, got \(String(describing: lostTargetFailure))")
        }
        // Retirement happens inside the failed call, before the client is released.
        try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))

        let observer = Phase2QualificationLibprocProcessObserver()
        do {
            snapshot = try await client!.launch(DebuggerLaunchConfiguration(
                executablePath: live.fixturePath,
                workingDirectory: URL(fileURLWithPath: live.fixturePath)
                    .deletingLastPathComponent().path
            ))
        } catch {
            return XCTFail("Relaunch after a retired coordinator failure was refused: \(error)")
        }
        guard case .paused(let relaunchedID, _) = snapshot.processState else {
            return XCTFail("relaunch did not stop at entry: \(snapshot.processState.displayTitle)")
        }
        if let observation = try observer.observation(processID: relaunchedID) {
            ownedProcesses[relaunchedID] = RecordedProcess(
                observation: observation,
                executablePath: live.fixturePath
            )
        }
        snapshot = try await client!.terminate(from: snapshot)
        client = nil
        try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
        try requireNoNewLLDBChild(
            parentProcessID: Int32(Darwin.getpid()),
            baseline: live.baselineChildren,
            expectedLLDBPath: live.lldbPath,
            observer: observer
        )
    }

    private struct ThreadsFixtureLaunch {
        let client: LocalLLDBDebuggerClient
        let snapshot: DebuggerSessionSnapshot
        let processID: Int32
        let ownedProcesses: [Int32: RecordedProcess]
        let baselineChildren: Set<Int32>
        let lldbPath: String
        let fixturePath: String
        let breakpointAuthority: WS21BreakpointAuthority
        let breakpointSpecification: DebuggerLogicalBreakpointSpecification
    }

    /// Builds the 4-thread fixture, launches it through the production client, arms one logical
    /// breakpoint at `_rendezvous`, and continues to that stop. Records the retained LLDB adapter
    /// tree (LLDB, debugserver) and the debuggee so callers can prove zero residue.
    private func launchThreadsFixtureToRendezvous(
        arguments: [String] = []
    ) async throws -> ThreadsFixtureLaunch {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let developerDirectory = environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let clang = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        let sdk = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
        guard fileManager.isExecutableFile(atPath: clang.path),
              fileManager.fileExists(atPath: sdk.path),
              let toolchain = XcodeLLDBCommandLineAdapter.discoverLLDBToolchain(
                  environment: environment
              ) else {
            throw XCTSkip("The selected Xcode clang/LLDB tools are unavailable.")
        }
        let source = TestSourceRoot.url
            .appendingPathComponent("MacScope/Tests/Fixtures/DebuggerThreadsLiveFixture.c")
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MacScopeThreadsLive-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fixtureURL = root.appendingPathComponent("threads-live-fixture")
        let build = Process()
        build.executableURL = clang
        build.arguments = [
            "-arch", "arm64", "-g", "-O0", "-fno-omit-frame-pointer", "-isysroot", sdk.path,
            source.path, "-o", fixtureURL.path,
        ]
        try build.run()
        build.waitUntilExit()
        guard build.terminationStatus == 0 else {
            throw SmokeFailure.processObservation("clang failed to build the threads fixture")
        }
        let fixturePath = fixtureURL.standardizedFileURL.path
        let loaded = try MachOBinaryLoader().load(at: fixtureURL)
        let breakpointAddress = try XCTUnwrap(
            loaded.symbols.first(where: { $0.name == "_rendezvous" })?.address
        )
        let reconstruction = try MachOSliceArtifactReconstructor.reconstruct(
            selectedSliceBytes: Data(contentsOf: fixtureURL)
        )
        let observer = Phase2QualificationLibprocProcessObserver()
        let testProcessID = Int32(Darwin.getpid())
        let baselineChildren = Set(try requireChildren(of: testProcessID, observer: observer))
        let client = LocalLLDBDebuggerClient(debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities())
        guard client.capabilities.isBackendAvailable, client.capabilities.canLaunch else {
            throw XCTSkip("The persistent LLDB backend is unavailable on this host.")
        }
        var ownedProcesses: [Int32: RecordedProcess] = [:]
        var breakpoint: (WS21BreakpointAuthority, DebuggerLogicalBreakpointSpecification)?
        var snapshot = try await client.launch(DebuggerLaunchConfiguration(
            executablePath: fixturePath,
            arguments: arguments,
            workingDirectory: root.path
        ))
        guard case .paused(let processID, _) = snapshot.processState, processID > 0 else {
            throw SmokeFailure.invalidProcessState(
                "launch did not stop at entry: \(snapshot.processState.displayTitle)"
            )
        }
        if let observation = try observer.observation(processID: processID) {
            ownedProcesses[processID] = RecordedProcess(
                observation: observation,
                executablePath: fixturePath
            )
        }
        do {
            let adapter = try await waitForNewDirectChild(
                parentProcessID: testProcessID,
                excluding: baselineChildren,
                executablePath: toolchain.executablePath,
                observer: observer,
                timeout: .seconds(2)
            )
            try mergeExactProcesses(
                try await waitForStableTree(
                    rootedAt: adapter.processID,
                    observer: observer,
                    timeout: .seconds(2)
                ),
                into: &ownedProcesses
            )
            let authority = try makeWS21BreakpointAuthority(
                snapshot: snapshot,
                reconstruction: reconstruction,
                fixturePath: fixturePath,
                checkpointAddress: breakpointAddress,
                checkpointSymbol: "_rendezvous"
            )
            let specification = try DebuggerLogicalBreakpointSpecification(
                id: authority.logicalID,
                revision: try .init(validating: 1),
                enabled: true,
                target: .preferredAddress(
                    owner: DebuggerWorkspaceImageOwnerSeal(
                        slot: authority.resolutionOwner.coordinate.slot,
                        binaryID: authority.resolutionOwner.coordinate.binaryID,
                        artifactIdentity: authority.resolutionOwner.coordinate.artifactIdentity
                    ),
                    preferredVA: breakpointAddress
                ),
                condition: nil,
                hitPolicy: .always,
                actions: [],
                disposition: .stop
            )
            breakpoint = (authority, specification)
            snapshot = try await client.reconcileLogicalBreakpoints(
                try makeWS21ReconcileRequest(
                    authority: authority,
                    specifications: [specification],
                    catalogRevision: 1,
                    resolutionRevision: 1,
                    snapshot: snapshot
                ),
                from: snapshot
            )
            XCTAssertEqual(snapshot.transportBreakpointBindingState?.ownedLocations.count, 1)
            let running = try await client.continueExecution(from: snapshot)
            snapshot = try await waitForRunToCursorStop(
                client: client,
                initialSnapshot: running,
                expectedProcessID: processID,
                timeout: .seconds(10)
            )
            // debugserver can appear late; capture the adapter tree again at the stop.
            if let tree = try? captureStableTree(rootedAt: adapter.processID, observer: observer) {
                try mergeExactProcesses(tree, into: &ownedProcesses)
            }
        } catch {
            if snapshot.canTerminateLiveProcess {
                _ = try? await client.terminate(from: snapshot)
            }
            throw error
        }
        return ThreadsFixtureLaunch(
            client: client,
            snapshot: snapshot,
            processID: processID,
            ownedProcesses: ownedProcesses,
            baselineChildren: baselineChildren,
            lldbPath: toolchain.executablePath,
            fixturePath: fixturePath,
            breakpointAuthority: try XCTUnwrap(breakpoint?.0),
            breakpointSpecification: try XCTUnwrap(breakpoint?.1)
        )
    }

    private func runSavedBreakpointRX01Proof(
        hitPolicy: DebuggerBreakpointHitPolicy
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        let developerDirectory = environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        guard FileManager.default.isExecutableFile(atPath: developerDirectory + "/usr/bin/lldb") else {
            throw XCTSkip("Xcode LLDB is unavailable on this host.")
        }
        let fixtureURL = TestSourceRoot.url
            .appendingPathComponent("MacScope/Tests/Fixtures/RX01Versioned/rx01_v1")
            .standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: fixtureURL.path) else {
            throw XCTSkip("RX01 fixture is unavailable.")
        }
        let fixturePath = fixtureURL.path
        let loaded = try MachOBinaryLoader().load(at: fixtureURL)
        let breakpointAddress = try XCTUnwrap(
            loaded.symbols.first(where: { $0.name == "_parse_header" })?.address
        )
        let reconstruction = try MachOSliceArtifactReconstructor.reconstruct(
            selectedSliceBytes: Data(contentsOf: fixtureURL)
        )
        let observer = Phase2QualificationLibprocProcessObserver()
        var client: LocalLLDBDebuggerClient? = LocalLLDBDebuggerClient(
            debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities()
        )
        guard let capabilities = client?.capabilities,
              capabilities.isBackendAvailable, capabilities.canLaunch else {
            throw XCTSkip("The persistent LLDB backend is unavailable on this host.")
        }
        var snapshot = client!.makeInitialSnapshot()
        var ownedProcesses: [Int32: RecordedProcess] = [:]
        defer { client = nil }
        do {
            snapshot = try await client!.launch(DebuggerLaunchConfiguration(
                executablePath: fixturePath,
                workingDirectory: fixtureURL.deletingLastPathComponent().path
            ))
            guard case .paused(let processID, _) = snapshot.processState, processID > 0 else {
                throw SmokeFailure.invalidProcessState(
                    "launch did not stop at entry: \(snapshot.processState.displayTitle)"
                )
            }
            if let observation = try observer.observation(processID: processID) {
                ownedProcesses[processID] = RecordedProcess(
                    observation: observation,
                    executablePath: fixturePath
                )
            }
            let authority = try makeWS21BreakpointAuthority(
                snapshot: snapshot,
                reconstruction: reconstruction,
                fixturePath: fixturePath,
                checkpointAddress: breakpointAddress,
                checkpointSymbol: "_parse_header"
            )
            let specification = try DebuggerLogicalBreakpointSpecification(
                id: authority.logicalID,
                revision: try .init(validating: 1),
                enabled: true,
                target: .preferredAddress(
                    owner: DebuggerWorkspaceImageOwnerSeal(
                        slot: authority.resolutionOwner.coordinate.slot,
                        binaryID: authority.resolutionOwner.coordinate.binaryID,
                        artifactIdentity: authority.resolutionOwner.coordinate.artifactIdentity
                    ),
                    preferredVA: breakpointAddress
                ),
                condition: nil,
                hitPolicy: hitPolicy,
                actions: [],
                disposition: .stop
            )
            snapshot = try await client!.reconcileLogicalBreakpoints(
                try makeWS21ReconcileRequest(
                    authority: authority,
                    specifications: [specification],
                    catalogRevision: 1,
                    resolutionRevision: 1,
                    snapshot: snapshot
                ),
                from: snapshot
            )
            XCTAssertEqual(snapshot.transportBreakpointBindingState?.ownedLocations.count, 1)
            // Inspecting the entry stop refreshes runtime modules; the panel then re-resolves the
            // same saved catalog against the moved mapping key at the same stop.
            snapshot = try await exerciseStoppedInspection(
                client: client!,
                snapshot: snapshot,
                label: "entry stop"
            )
            let entryRearm = try makeWS21ReconcileRequest(
                authority: authority,
                specifications: [specification],
                catalogRevision: 1,
                resolutionRevision: 1,
                snapshot: snapshot
            )
            let entryRearmed = snapshot.transportBreakpointBindingState?.resolutionObservation
                != entryRearm.observation
            if entryRearmed {
                do {
                    snapshot = try await client!.reconcileLogicalBreakpoints(entryRearm, from: snapshot)
                } catch {
                    throw SmokeFailure.invalidProcessState("entry re-arm reconcile: \(error)")
                }
                XCTAssertEqual(snapshot.transportBreakpointBindingState?.ownedLocations.count, 1)
            }

            let running: DebuggerSessionSnapshot
            do {
                running = try await client!.continueExecution(from: snapshot)
            } catch {
                throw SmokeFailure.invalidProcessState("continue from entry: \(error)")
            }
            if hitPolicy != .always {
                do {
                    snapshot = try await waitForProcessExit(
                        client: client!,
                        initialSnapshot: running,
                        expectedProcessID: processID,
                        timeout: .seconds(5)
                    )
                } catch {
                    throw SmokeFailure.invalidProcessState("run to exit from entry: \(error)")
                }
                let records = try XCTUnwrap(snapshot.transportBreakpointBindingState)
                    .callbackRecords.filter { $0.logicalID == authority.logicalID }
                XCTAssertEqual(records.map(\.outcome), [.ignored])
                if snapshot.canTerminateLiveProcess {
                    snapshot = try await client!.terminate(from: snapshot)
                }
                // Relaunch on the same client must be admitted.
                do {
                    snapshot = try await client!.launch(DebuggerLaunchConfiguration(
                        executablePath: fixturePath,
                        workingDirectory: fixtureURL.deletingLastPathComponent().path
                    ))
                } catch {
                    throw SmokeFailure.invalidProcessState("relaunch after exit: \(error)")
                }
                guard case .paused(let relaunchedID, _) = snapshot.processState else {
                    throw SmokeFailure.invalidProcessState(
                        "relaunch did not stop at entry: \(snapshot.processState.displayTitle)"
                    )
                }
                if let observation = try observer.observation(processID: relaunchedID) {
                    ownedProcesses[relaunchedID] = RecordedProcess(
                        observation: observation,
                        executablePath: fixturePath
                    )
                }
                snapshot = try await client!.terminate(from: snapshot)
                client = nil
                try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
                return
            }
            snapshot = try await waitForRunToCursorStop(
                client: client!,
                initialSnapshot: running,
                expectedProcessID: processID,
                timeout: .seconds(5)
            )
            let records = try XCTUnwrap(snapshot.transportBreakpointBindingState)
                .callbackRecords.filter { $0.logicalID == authority.logicalID }
            XCTAssertEqual(records.map(\.outcome), [.stopped])
            snapshot = try await exerciseStoppedInspection(
                client: client!,
                snapshot: snapshot,
                label: "breakpoint stop"
            )

            // The panel re-resolves saved breakpoints on every accepted stopped snapshot; dyld has
            // loaded more images since the entry stop, so the runtime mapping key moves and the
            // same catalog is re-armed through a second reconcile at the breakpoint stop.
            let rearm = try makeWS21ReconcileRequest(
                authority: authority,
                specifications: [specification],
                catalogRevision: 1,
                resolutionRevision: 1,
                snapshot: snapshot
            )
            let stopRearmed = snapshot.transportBreakpointBindingState?.resolutionObservation
                != rearm.observation
            if stopRearmed {
                do {
                    snapshot = try await client!.reconcileLogicalBreakpoints(rearm, from: snapshot)
                } catch {
                    throw SmokeFailure.invalidProcessState("breakpoint-stop re-arm reconcile: \(error)")
                }
                XCTAssertEqual(snapshot.transportBreakpointBindingState?.ownedLocations.count, 1)
            }
            let resumed = try await client!.continueExecution(from: snapshot)
            snapshot = try await waitForProcessExit(
                client: client!,
                initialSnapshot: resumed,
                expectedProcessID: processID,
                timeout: .seconds(5)
            )
            if snapshot.canTerminateLiveProcess {
                snapshot = try await client!.terminate(from: snapshot)
            }
            client = nil
            try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
        } catch {
            if let cleanupClient = client, snapshot.canTerminateLiveProcess {
                _ = try? await cleanupClient.terminate(from: snapshot)
            }
            client = nil
            for processID in ownedProcesses.keys where processExists(processID) {
                _ = Darwin.kill(processID, SIGKILL)
            }
            throw error
        }
    }

    /// What the debugger panel does at a stop when the user inspects it: select the listed
    /// thread, select frame 0, refresh. Each step names itself on failure.
    private func exerciseStoppedInspection(
        client: LocalLLDBDebuggerClient,
        snapshot: DebuggerSessionSnapshot,
        label: String
    ) async throws -> DebuggerSessionSnapshot {
        var snapshot = snapshot
        let thread = try XCTUnwrap(snapshot.threads.first, "\(label): no thread projected")
        do {
            snapshot = try await client.selectThread(
                DebuggerThreadSelectionRequest(index: thread.index),
                from: snapshot
            )
        } catch { throw SmokeFailure.invalidProcessState("\(label) selectThread: \(error)") }
        do {
            snapshot = try await client.selectFrame(
                DebuggerFrameSelectionRequest(index: 0),
                from: snapshot
            )
        } catch { throw SmokeFailure.invalidProcessState("\(label) selectFrame: \(error)") }
        do {
            snapshot = try await client.refreshSnapshot(from: snapshot)
        } catch { throw SmokeFailure.invalidProcessState("\(label) refresh: \(error)") }
        return snapshot
    }

    private func requireWS21CallbackLiveFixture(
        for scenario: WS21CallbackScenario
    ) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MACSCOPE_DEBUGGER_WS21_CALLBACK_LIVE_SMOKE"] == "1" else {
            throw XCTSkip(
                "Set MACSCOPE_DEBUGGER_WS21_CALLBACK_LIVE_SMOKE=1 to run the serialized "
                    + "WS-21 D4 callback proof matrix (requested scenario: \(scenario.rawValue))."
            )
        }
        guard let fixturePath = environment["MACSCOPE_DEBUGGER_LIVE_FIXTURE"],
              fixturePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: fixturePath) else {
            throw XCTSkip(
                "WS-21 D4 \(scenario.rawValue) requires MACSCOPE_DEBUGGER_LIVE_FIXTURE "
                    + "to name the absolute executable path of the pre-verified signed fixture."
            )
        }
        return URL(fileURLWithPath: fixturePath).standardizedFileURL.path
    }

    private func runWS21CallbackLiveProof(_ proof: WS21CallbackProof) async throws {
        let fixturePath = try requireWS21CallbackLiveFixture(for: proof.scenario)
        let inboundCanary = proof.scenario == .logAndContinue
            ? "MACSCOPE_WS21_RAW_"
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            : nil
        let actions: [DebuggerBreakpointAction]
        if let inboundCanary {
            actions = [.log(try DebuggerBreakpointLogTemplate(fragments: [
                .literal(inboundCanary),
            ]))]
        } else {
            actions = proof.actions
        }
        let inboundProbe = inboundCanary.map {
            PersistentLLDBCLIInboundNeedleProbe(needle: Data($0.utf8))
        }

        let environment = ProcessInfo.processInfo.environment
        let developerDirectory = environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let expectedLLDBPath = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("usr/bin/lldb")
            .standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: expectedLLDBPath) else {
            throw SmokeFailure.backendUnavailable(
                "the selected Xcode-bundled LLDB is not executable at \(expectedLLDBPath)"
            )
        }

        let fixtureURL = URL(fileURLWithPath: fixturePath)
        let fixtureRoot = fixtureURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL.path
        let loaded = try MachOBinaryLoader().load(at: fixtureURL)
        guard let checkpointAddress = loaded.symbols.first(where: {
            $0.name == "_macscope_fixture_main_checkpoint"
        })?.address else {
            throw SmokeFailure.processObservation(
                "the signed fixture has no exported _macscope_fixture_main_checkpoint"
            )
        }
        let reconstruction = try MachOSliceArtifactReconstructor.reconstruct(
            selectedSliceBytes: Data(contentsOf: fixtureURL)
        )
        let channel = try WS21FixtureControlChannel()
        let observer = Phase2QualificationLibprocProcessObserver()
        let testProcessID = Int32(Darwin.getpid())
        let baselineChildren = Set(try requireChildren(of: testProcessID, observer: observer))
        var client: LocalLLDBDebuggerClient? = LocalLLDBDebuggerClient(
            debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities(),
            inboundNeedleProbe: inboundProbe
        )
        var snapshot = client?.makeInitialSnapshot() ?? .empty
        var ownedProcesses: [Int32: RecordedProcess] = [:]
        var checkpointTask: Task<Void, Error>?

        do {
            guard let capabilities = client?.capabilities,
                  capabilities.isBackendAvailable,
                  capabilities.canLaunch,
                  capabilities.canControlExecution else {
                throw SmokeFailure.backendUnavailable(
                    client?.capabilities.summary ?? "the default client was not constructed"
                )
            }
            snapshot = try await client!.launch(DebuggerLaunchConfiguration(
                executablePath: fixturePath,
                arguments: channel.launchArguments,
                workingDirectory: fixtureRoot
            ))
            guard case .paused(let processID, _) = snapshot.processState,
                  processID > 0,
                  let targetObservation = try observer.observation(processID: processID),
                  executablePath(for: processID) == fixturePath else {
                throw SmokeFailure.processObservation(
                    "WS-21 fixture launch did not produce one exact paused target"
                )
            }
            ownedProcesses[processID] = RecordedProcess(
                observation: targetObservation,
                executablePath: fixturePath
            )
            let adapter = try await waitForNewDirectChild(
                parentProcessID: testProcessID,
                excluding: baselineChildren,
                executablePath: expectedLLDBPath,
                observer: observer,
                timeout: .seconds(2)
            )
            ownedProcesses.merge(
                try await waitForStableTree(
                    rootedAt: adapter.processID,
                    observer: observer,
                    timeout: .seconds(2)
                )
            ) { existing, _ in existing }
            ownedProcesses[processID] = RecordedProcess(
                observation: targetObservation,
                executablePath: fixturePath
            )

            let authority = try makeWS21BreakpointAuthority(
                snapshot: snapshot,
                reconstruction: reconstruction,
                fixturePath: fixturePath,
                checkpointAddress: checkpointAddress
            )
            let specification = try DebuggerLogicalBreakpointSpecification(
                id: authority.logicalID,
                revision: try .init(validating: 1),
                enabled: true,
                target: .preferredAddress(
                    owner: DebuggerWorkspaceImageOwnerSeal(
                        slot: authority.resolutionOwner.coordinate.slot,
                        binaryID: authority.resolutionOwner.coordinate.binaryID,
                        artifactIdentity: authority.resolutionOwner.coordinate.artifactIdentity
                    ),
                    preferredVA: checkpointAddress
                ),
                condition: proof.condition,
                hitPolicy: proof.hitPolicy,
                actions: actions,
                disposition: proof.disposition
            )
            let initialRequest = try makeWS21ReconcileRequest(
                authority: authority,
                specifications: [specification],
                catalogRevision: 1,
                resolutionRevision: 1,
                snapshot: snapshot
            )
            XCTAssertTrue(
                proof.requiredCapabilities.isSubset(
                    of: LLDBLogicalBreakpointProgram.liveProvenCapabilities
                )
            )
            snapshot = try await client!.reconcileLogicalBreakpoints(
                initialRequest,
                from: snapshot
            )
            XCTAssertEqual(snapshot.transportBreakpointBindingState?.ownedLocations.count, 1)
            let inboundBeforeCallback = inboundProbe?.snapshot
            XCTAssertEqual(inboundBeforeCallback?.matchCount, inboundProbe == nil ? nil : 0)
            if let inboundBeforeCallback {
                XCTAssertGreaterThan(inboundBeforeCallback.observedByteCount, 0)
            }

            var running = try await client!.continueExecution(from: snapshot)
            try await channel.open(forProcessID: processID, timeout: .seconds(3))
            if proof.expectedOutcomes.first == .ignored {
                _ = try await channel.send(
                    "checkpoint",
                    processID: processID,
                    timeout: .seconds(3)
                )
            }

            let clock = ContinuousClock()
            let callbackStart = clock.now
            checkpointTask = Task { @MainActor in
                _ = try await channel.send(
                    "checkpoint",
                    processID: processID,
                    timeout: .seconds(5)
                )
            }
            var publicCallbackDrainFailure: DebuggerClientError?
            if proof.callbackStopsTarget {
                do {
                    snapshot = try await waitForRunToCursorStop(
                        client: client!,
                        initialSnapshot: running,
                        expectedProcessID: processID,
                        timeout: .seconds(3)
                    )
                    if proof.expectsPublicCallbackDrainFailure {
                        throw SmokeFailure.invalidProcessState(
                            "\(proof.scenario.rawValue) unexpectedly published a paused snapshot"
                        )
                    }
                } catch {
                    guard proof.expectsPublicCallbackDrainFailure,
                          let clientError = error as? DebuggerClientError else {
                        throw error
                    }
                    assertWS21PublicCallbackDrainFailure(clientError)
                    publicCallbackDrainFailure = clientError
                }
            } else {
                try await checkpointTask?.value
                checkpointTask = nil
                snapshot = try await client!.pollProcessStatus(from: running)
                guard case .running(let observedProcessID, _) = snapshot.processState,
                      observedProcessID == processID else {
                    throw SmokeFailure.invalidProcessState(
                        "\(proof.scenario.rawValue) did not remain running after callback drain"
                    )
                }
            }
            let callbackDuration = callbackStart.duration(to: clock.now)
            if let minimum = proof.minimumCallbackDuration {
                XCTAssertGreaterThanOrEqual(callbackDuration, minimum)
            }
            if let maximum = proof.maximumCallbackDuration {
                XCTAssertLessThanOrEqual(callbackDuration, maximum)
            }
            if publicCallbackDrainFailure != nil {
                if let inboundBeforeCallback, let inboundAfterCallback = inboundProbe?.snapshot {
                    XCTAssertGreaterThan(
                        inboundAfterCallback.observedByteCount,
                        inboundBeforeCallback.observedByteCount
                    )
                    XCTAssertEqual(inboundAfterCallback.matchCount, 0)
                }
                await cancelAndAwaitWS21CheckpointTask(checkpointTask)
                checkpointTask = nil
                client = nil
                try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
                try requireNoNewLLDBChild(
                    parentProcessID: testProcessID,
                    baseline: baselineChildren,
                    expectedLLDBPath: expectedLLDBPath,
                    observer: observer
                )
                try channel.cleanup()
                XCTAssertFalse(FileManager.default.fileExists(atPath: channel.root.path))
                return
            }
            try assertWS21CallbackRecords(
                proof,
                snapshot: snapshot,
                logicalID: authority.logicalID,
                logCanary: inboundCanary
            )
            if let inboundBeforeCallback, let inboundAfterCallback = inboundProbe?.snapshot {
                XCTAssertGreaterThan(
                    inboundAfterCallback.observedByteCount,
                    inboundBeforeCallback.observedByteCount
                )
                XCTAssertEqual(inboundAfterCallback.matchCount, 0)
                try await ContinuousClock().sleep(for: .milliseconds(150))
                XCTAssertEqual(inboundProbe?.snapshot.matchCount, 0)
            }

            if !proof.callbackStopsTarget {
                snapshot = try await client!.pause(from: snapshot)
            }

            snapshot = try await client!.reconcileLogicalBreakpoints(
                try makeWS21ReconcileRequest(
                    authority: authority,
                    specifications: [],
                    catalogRevision: 2,
                    resolutionRevision: 2,
                    snapshot: snapshot
                ),
                from: snapshot
            )
            XCTAssertEqual(snapshot.transportBreakpointBindingState?.ownedLocations, [])
            running = try await client!.continueExecution(from: snapshot)
            if proof.callbackStopsTarget {
                try await checkpointTask?.value
                checkpointTask = nil
            }
            _ = try await channel.send(
                "exit",
                processID: processID,
                timeout: .seconds(3)
            )
            snapshot = try await waitForProcessExit(
                client: client!,
                initialSnapshot: running,
                expectedProcessID: processID,
                timeout: .seconds(3)
            )

            if snapshot.canTerminateLiveProcess {
                snapshot = try await client!.terminate(from: snapshot)
            }
            await cancelAndAwaitWS21CheckpointTask(checkpointTask)
            checkpointTask = nil
            client = nil
            try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            try requireNoNewLLDBChild(
                parentProcessID: testProcessID,
                baseline: baselineChildren,
                expectedLLDBPath: expectedLLDBPath,
                observer: observer
            )
            try channel.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: channel.root.path))
        } catch {
            await cancelAndAwaitWS21CheckpointTask(checkpointTask)
            checkpointTask = nil
            if let cleanupClient = client, snapshot.canTerminateLiveProcess {
                snapshot = (try? await cleanupClient.terminate(from: snapshot)) ?? snapshot
            }
            client = nil
            if !ownedProcesses.isEmpty {
                do {
                    try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
                } catch let cleanupError {
                    XCTFail("Cleanup after WS-21 live-smoke failure was incomplete: \(cleanupError)")
                }
            }
            do {
                try channel.cleanup()
                XCTAssertFalse(FileManager.default.fileExists(atPath: channel.root.path))
            } catch let cleanupError {
                XCTFail("WS-21 fixture control cleanup failed: \(cleanupError)")
            }
            throw error
        }
    }

    private func assertWS21PublicCallbackDrainFailure(_ error: DebuggerClientError) {
        XCTAssertEqual(
            error,
            .backendFailure(
                DebuggerOperation.pollProcessStatus.displayLabel
                    + " failed while draining correlated logical-breakpoint callbacks "
                    + "(reducerRejected); bounded fail-closed target recovery was attempted."
            )
        )
    }

    private func cancelAndAwaitWS21CheckpointTask(_ task: Task<Void, Error>?) async {
        guard let task else { return }
        task.cancel()
        _ = try? await task.value
    }

    private func makeWS21BreakpointAuthority(
        snapshot: DebuggerSessionSnapshot,
        reconstruction: MachOSliceArtifactReconstruction,
        fixturePath: String,
        checkpointAddress: UInt64,
        checkpointSymbol: String = "_macscope_fixture_main_checkpoint"
    ) throws -> WS21BreakpointAuthority {
        let runtime = try requireAvailableRuntimeModuleAuthority(
            in: snapshot,
            description: "WS-21 fixture launch"
        )
        let binaryID = UUID()
        let artifactCatalog = DebuggerWorkspaceArtifactCatalog(
            revision: .init(rawValue: 1),
            artifacts: [DebuggerWorkspaceArtifactCatalogEntry(
                binaryID: binaryID,
                slot: .primary,
                ownerRevision: .init(rawValue: 1),
                artifactIdentity: reconstruction.identity,
                preferredSegmentLayout: reconstruction.preferredSegmentLayout,
                artifactIntegrityState: .verified,
                sourcePathHint: fixturePath,
                executablePathHint: fixturePath
            )]
        )
        let projection = DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: runtime.inventory,
            authorityRevision: runtime.authorityRevision,
            catalog: artifactCatalog
        )
        guard projection.modules.count == 1,
              let module = projection.modules.first else {
            throw SmokeFailure.invalidProcessState(
                "WS-21 fixture launch did not correlate one exact runtime module"
            )
        }
        let segments = try reconstruction.preferredSegmentLayout.records.map { record in
            try XCTUnwrap(DebuggerBreakpointResolutionSegment(
                name: record.name,
                preferredStart: record.preferredVMStart,
                byteCount: record.preferredVMSize,
                isExecutable: record.initialProtections & VM_PROT_EXECUTE != 0
            ))
        }
        guard let checkpointSegment = segments.first(where: {
            $0.isExecutable && $0.contains(checkpointAddress)
        }) else {
            throw SmokeFailure.invalidProcessState(
                "the fixture checkpoint is not inside one executable preferred segment"
            )
        }
        return WS21BreakpointAuthority(
            workspaceID: UUID(),
            catalogID: UUID(),
            logicalID: DebuggerLogicalBreakpointID(rawValue: UUID()),
            artifactCatalog: artifactCatalog,
            resolutionOwner: DebuggerBreakpointResolutionOwnerIndex(
                coordinate: module.coordinate,
                revision: 1,
                segments: segments,
                staticAddresses: [.init(
                    preferredVA: checkpointAddress,
                    segmentName: checkpointSegment.name,
                    kind: .decodedExecutableInstruction
                )],
                functions: [.init(
                    entryPreferredVA: checkpointAddress,
                    rawLinkageName: checkpointSymbol
                )],
                hasCanonicalRawSymbolAuthority: true,
                rawSymbols: [.init(
                    exactRawLinkageName: checkpointSymbol,
                    kind: "function",
                    libraryName: nil,
                    preferredVA: checkpointAddress
                )],
                hasExactSourceAuthority: false,
                sourceRows: []
            )
        )
    }

    private func makeWS21ReconcileRequest(
        authority: WS21BreakpointAuthority,
        specifications: [DebuggerLogicalBreakpointSpecification],
        catalogRevision: UInt64,
        resolutionRevision: UInt64,
        snapshot: DebuggerSessionSnapshot
    ) throws -> DebuggerLogicalBreakpointReconcileRequest {
        let runtime = try requireAvailableRuntimeModuleAuthority(
            in: snapshot,
            description: "WS-21 reconciliation"
        )
        let projection = DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: runtime.inventory,
            authorityRevision: runtime.authorityRevision,
            catalog: authority.artifactCatalog
        )
        let catalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: authority.catalogID,
            revision: catalogRevision,
            specifications: specifications
        )
        let logicalCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: authority.workspaceID,
            catalogID: authority.catalogID,
            revision: catalogRevision
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: authority.workspaceID,
            revision: .init(rawValue: resolutionRevision),
            workspaceArtifactCatalogRevision: authority.artifactCatalog.revision
        )
        let resolutionCatalog = DebuggerBreakpointResolutionCatalog(
            coordinate: resolutionCoordinate,
            owners: [authority.resolutionOwner]
        )
        let results = DebuggerLogicalBreakpointResolver.resolve(
            catalog: catalog,
            coordinate: logicalCoordinate,
            resolutionCatalog: resolutionCatalog,
            requiringResolutionCoordinate: resolutionCoordinate,
            runtimeProjection: projection,
            requiringMappingKey: projection.key
        )
        let expectations = specifications.map {
            DebuggerLogicalBreakpointResolutionExpectation(
                logicalID: $0.id,
                specificationRevision: $0.revision
            )
        }
        guard let observation = DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: logicalCoordinate,
            resolutionCatalogCoordinate: resolutionCoordinate,
            mappingKey: projection.key,
            expectedSpecifications: expectations,
            results: results
        ) else {
            throw SmokeFailure.invalidProcessState(
                "could not construct the canonical WS-21 resolution observation"
            )
        }
        return try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: catalog,
            observation: observation
        )
    }

    private func assertWS21CallbackRecords(
        _ proof: WS21CallbackProof,
        snapshot: DebuggerSessionSnapshot,
        logicalID: DebuggerLogicalBreakpointID,
        logCanary: String?
    ) throws {
        let records = try XCTUnwrap(snapshot.transportBreakpointBindingState)
            .callbackRecords.filter { $0.logicalID == logicalID }
        XCTAssertEqual(records.map(\.outcome), proof.expectedOutcomes)
        XCTAssertEqual(records.map(\.observedLogicalHitCount),
                       records.indices.map { UInt64($0 + 1) })
        switch proof.scenario {
        case .logAndContinue:
            guard case .log(let text)? = records.last?.actionOutputs.first else {
                return XCTFail("log-and-continue did not publish one typed log output")
            }
            XCTAssertEqual(text, try XCTUnwrap(logCanary))
        case .targetExpression:
            guard case .targetExpression(let label, let value)? =
                    records.last?.actionOutputs.first else {
                return XCTFail("target-expression action did not publish one typed result")
            }
            XCTAssertEqual(label, "counter")
            XCTAssertFalse(value.isEmpty)
        case .falseCondition, .ignoreFirst:
            XCTAssertTrue(records.allSatisfy(\.actionOutputs.isEmpty))
        case .expressionTimeout, .totalDeadline:
            XCTFail("Fault callbacks must fail at the public callback-drain boundary.")
        case .ordinaryStop, .exactCleanup:
            XCTAssertTrue(records.last?.actionOutputs.isEmpty == true)
        }
    }

    private func waitForProcessExit(
        client: LocalLLDBDebuggerClient,
        initialSnapshot: DebuggerSessionSnapshot,
        expectedProcessID: Int32,
        timeout: Duration
    ) async throws -> DebuggerSessionSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var snapshot = initialSnapshot
        while snapshot.liveProcessID == expectedProcessID, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
            snapshot = try await client.pollProcessStatus(from: snapshot)
        }
        guard case .exited = snapshot.processState else {
            throw SmokeFailure.invalidProcessState(
                "fixture did not exit within \(timeout); last state was "
                    + snapshot.processState.displayTitle
            )
        }
        return snapshot
    }

    private func waitForProcessExit(_ process: Process, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while process.isRunning, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
        }
        guard !process.isRunning else {
            throw SmokeFailure.processResidue(
                "fixture process \(process.processIdentifier) did not exit within \(timeout)"
            )
        }
    }

    private func waitForStableAuthorizationEvidence(
        processID: Int32,
        provider: DarwinDebuggerLocalProcessEvidenceProvider,
        timeout: Duration
    ) async throws -> DebuggerLocalProcessAuthorizationEvidence {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastResult: DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> =
            .unknown(.unstableSnapshot)
        repeat {
            let result = await provider.authorizationEvidence(processID: processID)
            switch result {
            case .resolved(let evidence):
                return evidence
            case .unknown(.unstableSnapshot):
                lastResult = result
                try await clock.sleep(for: .milliseconds(25))
            case .unknown, .ineligible:
                throw SmokeFailure.processObservation(
                    "the WS-22 fixture did not produce attach authorization evidence: "
                    + "\(result)"
                )
            }
        } while clock.now < deadline
        throw SmokeFailure.processObservation(
            "the WS-22 fixture did not produce stable attach authorization evidence within "
            + "\(timeout): \(lastResult)"
        )
    }

    private func waitForStableCatalogEvidence(
        processID: Int32,
        provider: DarwinDebuggerLocalProcessEvidenceProvider,
        timeout: Duration
    ) async throws -> DebuggerLocalProcessCatalogEvidence {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastResult: DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> =
            .unknown(.unstableSnapshot)
        repeat {
            let result = await provider.catalogEvidence(processID: processID)
            switch result {
            case .resolved(let evidence):
                return evidence
            case .unknown(.unstableSnapshot):
                lastResult = result
                try await clock.sleep(for: .milliseconds(25))
            case .unknown, .ineligible:
                throw SmokeFailure.processObservation(
                    "the WS-22 fixture did not produce catalog evidence: \(result)"
                )
            }
        } while clock.now < deadline
        throw SmokeFailure.processObservation(
            "the WS-22 fixture did not produce stable catalog evidence within "
            + "\(timeout): \(lastResult)"
        )
    }

    func testLogicalBreakpointLifecycleRetainsForeignBreakpointAndAdapterWithoutResidue() async throws {
        try await runWS21F3IntegratedLiveProof()
    }

    func testExactAttachDetachRetainsExternalFixtureAndLeavesNoResidue() async throws {
        try await runWS22ExactAttachDetachLiveProof()
    }

    private func requireWS22AttachLiveFixture() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let sentinelPath = "/tmp/MacScope-WS22-LiveAttachProof.input"
        let rawFixturePath: String?
        if environment["MACSCOPE_DEBUGGER_WS22_ATTACH_LIVE_SMOKE"] == "1" {
            rawFixturePath = environment["MACSCOPE_DEBUGGER_LIVE_FIXTURE"]
        } else if FileManager.default.fileExists(atPath: sentinelPath) {
            rawFixturePath = try String(contentsOfFile: sentinelPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw XCTSkip(
                "Set MACSCOPE_DEBUGGER_WS22_ATTACH_LIVE_SMOKE=1 with "
                + "MACSCOPE_DEBUGGER_LIVE_FIXTURE, or write the fixture executable path to "
                + "\(sentinelPath), to run the serialized WS-22 external attach proof."
            )
        }
        guard let fixturePath = rawFixturePath,
              !fixturePath.isEmpty,
              fixturePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: fixturePath) else {
            throw SmokeFailure.processObservation(
                "the WS-22 fixture path is not an absolute executable: "
                + String(describing: rawFixturePath)
            )
        }
        return URL(fileURLWithPath: fixturePath).standardizedFileURL.path
    }

    private func runWS22ExactAttachDetachLiveProof() async throws {
        let fixturePath = try requireWS22AttachLiveFixture()
        let fixtureRoot = URL(fileURLWithPath: fixturePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL.path
        let environment = ProcessInfo.processInfo.environment
        let developerDirectory = environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let expectedLLDBPath = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("usr/bin/lldb")
            .standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: expectedLLDBPath) else {
            throw SmokeFailure.backendUnavailable(
                "the selected Xcode-bundled LLDB is not executable at \(expectedLLDBPath)"
            )
        }
        guard let toolchain = XcodeLLDBCommandLineAdapter.discoverLLDBToolchain(
            environment: environment
        ), toolchain.executablePath == expectedLLDBPath else {
            throw SmokeFailure.backendUnavailable(
                "could not construct the selected Xcode LLDB toolchain"
            )
        }

        let observer = Phase2QualificationLibprocProcessObserver()
        let evidenceProvider = DarwinDebuggerLocalProcessEvidenceProvider()
        let identityObserver = DebuggerLocalProcessIdentityObserver(provider: evidenceProvider)
        let testProcessID = Int32(Darwin.getpid())
        let baselineChildren = Set(try requireChildren(of: testProcessID, observer: observer))
        let channel = try WS21FixtureControlChannel()
        let fixtureProcess = Process()
        fixtureProcess.executableURL = URL(fileURLWithPath: fixturePath)
        fixtureProcess.arguments = channel.launchArguments
        fixtureProcess.currentDirectoryURL = URL(fileURLWithPath: fixtureRoot)

        var client: LocalLLDBDebuggerClient? = LocalLLDBDebuggerClient(
            adapter: WS21F3ProductionAdapter(
                toolchain: toolchain,
                environment: environment,
                workingDirectory: fixtureRoot
            )
        )
        var latestSnapshot = client?.makeInitialSnapshot() ?? .empty
        var ownedProcesses: [Int32: RecordedProcess] = [:]
        var fixtureIdentity: DebuggerLocalProcessIdentity?

        do {
            try fixtureProcess.run()
            let targetProcessID = Int32(fixtureProcess.processIdentifier)
            guard targetProcessID > 0,
                  let targetPath = executablePath(for: targetProcessID),
                  targetPath == fixturePath,
                  let targetObservation = try observer.observation(
                    processID: targetProcessID
                  ) else {
                throw SmokeFailure.processObservation(
                    "the spawned WS-22 fixture did not resolve to the authorized executable"
                )
            }
            let targetRecord = RecordedProcess(
                observation: targetObservation,
                executablePath: targetPath
            )
            ownedProcesses[targetProcessID] = targetRecord
            try await channel.open(forProcessID: targetProcessID, timeout: .seconds(3))

            let catalogEvidence = try await waitForStableCatalogEvidence(
                processID: targetProcessID,
                provider: evidenceProvider,
                timeout: .seconds(2)
            )
            guard catalogEvidence.fingerprint.canonicalExecutablePath == fixturePath,
                  let catalogMachOUUID = catalogEvidence.fingerprint.machOUUID else {
                throw SmokeFailure.processObservation(
                    "the selected WS-22 fixture catalog lacks exact path or Mach-O UUID"
                )
            }

            let authorizationEvidence = try await waitForStableAuthorizationEvidence(
                processID: targetProcessID,
                provider: evidenceProvider,
                timeout: .seconds(2)
            )
            let selectedIdentity = authorizationEvidence.identity
            fixtureIdentity = selectedIdentity
            guard selectedIdentity.processID == targetProcessID,
                  selectedIdentity.canonicalExecutablePath == fixturePath,
                  let selectedMachOUUID = selectedIdentity.machOUUID else {
                throw SmokeFailure.processObservation(
                    "the selected WS-22 fixture identity lacks exact path or Mach-O UUID"
                )
            }
            XCTAssertEqual(
                authorizationEvidence.catalogEvidence.fingerprint.machOUUID,
                selectedMachOUUID
            )
            XCTAssertEqual(catalogMachOUUID, selectedMachOUUID)

            guard let debuggerClient = client else {
                throw SmokeFailure.backendUnavailable("the production attach client was nil")
            }
            guard debuggerClient.capabilities.isBackendAvailable,
                  debuggerClient.capabilities.canAttach,
                  debuggerClient.capabilities.canControlExecution else {
                throw SmokeFailure.backendUnavailable(debuggerClient.capabilities.summary)
            }

            let attached = try await debuggerClient.attach(
                DebuggerLocalAttachRequest(selectedIdentity: selectedIdentity),
                from: latestSnapshot
            )
            latestSnapshot = attached
            guard case .paused(let attachedProcessID, _) = attached.processState,
                  attachedProcessID == targetProcessID,
                  attached.liveProcessID == targetProcessID else {
                throw SmokeFailure.invalidProcessState(
                    "exact attach returned \(attached.processState.displayTitle), expected "
                    + "paused fixture pid \(targetProcessID)"
                )
            }
            guard case .attached(let attachedIdentity) = attached.transportTargetAuthority?.origin,
                  attachedIdentity == selectedIdentity,
                  attachedIdentity.machOUUID == selectedMachOUUID else {
                throw SmokeFailure.invalidProcessState(
                    "exact attach did not retain the selected UUID-bearing identity"
                )
            }
            XCTAssertNil(
                attached.lastCommandRun,
                "The exact attach path must not expose a raw attach command transcript."
            )

            let adapter = try await waitForNewDirectChild(
                parentProcessID: testProcessID,
                excluding: baselineChildren,
                executablePath: expectedLLDBPath,
                observer: observer,
                timeout: .seconds(2)
            )
            try mergeExactProcesses(
                try await waitForStableTree(
                    rootedAt: adapter.processID,
                    observer: observer,
                    timeout: .seconds(2)
                ),
                into: &ownedProcesses
            )
            ownedProcesses[targetProcessID] = targetRecord

            let detached = try await debuggerClient.detach(from: attached)
            latestSnapshot = detached
            let survival = await identityObserver.reobserveIdentity(selectedIdentity)
            guard case .resolved(let survivingIdentity) = survival,
                  survivingIdentity == selectedIdentity,
                  fixtureProcess.isRunning else {
                throw SmokeFailure.processObservation(
                    "detach did not preserve the exact external fixture identity: \(survival)"
                )
            }

            _ = try await channel.send(
                "checkpoint",
                processID: targetProcessID,
                timeout: .seconds(2)
            )
            _ = try await channel.send("exit", processID: targetProcessID, timeout: .seconds(2))
            try await waitForProcessExit(fixtureProcess, timeout: .seconds(3))
            client = nil
            try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            try requireNoNewLLDBChild(
                parentProcessID: testProcessID,
                baseline: baselineChildren,
                expectedLLDBPath: expectedLLDBPath,
                observer: observer
            )
            try channel.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: channel.root.path))
        } catch {
            if let cleanupClient = client {
                switch latestSnapshot.processState {
                case .running, .paused:
                    latestSnapshot = (try? await cleanupClient.detach(from: latestSnapshot))
                        ?? latestSnapshot
                default:
                    break
                }
            }
            if fixtureProcess.isRunning,
               let identity = fixtureIdentity {
                _ = try? await channel.send(
                    "exit",
                    processID: identity.processID,
                    timeout: .milliseconds(500)
                )
                try? await waitForProcessExit(
                    fixtureProcess,
                    timeout: .milliseconds(750)
                )
            }
            if fixtureProcess.isRunning,
               let targetPath = executablePath(for: Int32(fixtureProcess.processIdentifier)),
               targetPath == fixturePath {
                fixtureProcess.terminate()
                try? await waitForProcessExit(fixtureProcess, timeout: .seconds(2))
            }
            client = nil
            if !ownedProcesses.isEmpty {
                do {
                    try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
                } catch let cleanupError {
                    XCTFail("Cleanup after WS-22 live attach failure was incomplete: \(cleanupError)")
                }
            }
            do {
                try channel.cleanup()
                XCTAssertFalse(FileManager.default.fileExists(atPath: channel.root.path))
            } catch let cleanupError {
                XCTFail("WS-22 fixture control cleanup failed: \(cleanupError)")
            }
            throw error
        }
    }

    private func runWS21F3IntegratedLiveProof() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtureInput = environment["MACSCOPE_DEBUGGER_LIVE_FIXTURE"],
              !fixtureInput.isEmpty else {
            throw XCTSkip(
                "Set MACSCOPE_DEBUGGER_LIVE_FIXTURE to a pre-verified signed fixture executable "
                + "to run the serialized production LLDB smoke."
            )
        }

        let fixturePath = URL(fileURLWithPath: fixtureInput).standardizedFileURL.path
        guard fixturePath.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: fixturePath) else {
            throw SmokeFailure.processObservation(
                "the fixture path is not an absolute executable: \(fixturePath)"
            )
        }
        let fixtureRoot = URL(fileURLWithPath: fixturePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL.path

        let developerDirectory = environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let expectedLLDBPath = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent("usr/bin/lldb")
            .standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: expectedLLDBPath) else {
            throw SmokeFailure.backendUnavailable(
                "the selected Xcode-bundled LLDB is not executable at \(expectedLLDBPath)"
            )
        }
        guard XcodeLLDBCommandLineAdapter.discoverLLDBExecutablePath(environment: environment)
                == expectedLLDBPath else {
            throw SmokeFailure.backendUnavailable(
                "default toolchain discovery did not select \(expectedLLDBPath)"
            )
        }
        guard let toolchain = XcodeLLDBCommandLineAdapter.discoverLLDBToolchain(
            environment: environment
        ), toolchain.executablePath == expectedLLDBPath else {
            throw SmokeFailure.backendUnavailable(
                "could not construct the selected Xcode LLDB toolchain"
            )
        }

        let observer = Phase2QualificationLibprocProcessObserver()
        let testProcessID = Int32(Darwin.getpid())
        let baselineChildren = Set(try requireChildren(of: testProcessID, observer: observer))
        let channel = try WS21FixtureControlChannel()

        var client: LocalLLDBDebuggerClient? = LocalLLDBDebuggerClient(
            adapter: WS21F3ProductionAdapter(
                toolchain: toolchain,
                environment: environment,
                workingDirectory: fixtureRoot
            )
        )
        var latestSnapshot = client?.makeInitialSnapshot() ?? .empty
        var ownedProcesses: [Int32: RecordedProcess] = [:]

        do {
            guard let capabilities = client?.capabilities,
                  capabilities.isBackendAvailable,
                  capabilities.canLaunch,
                  capabilities.canControlExecution else {
                throw SmokeFailure.backendUnavailable(
                    client?.capabilities.summary ?? "the default client was not constructed"
                )
            }

            let fixtureBinary = try MachOBinaryLoader().load(
                at: URL(fileURLWithPath: fixturePath)
            )
            guard let mainAddress = fixtureBinary.symbols.first(where: {
                $0.name == "_main"
            })?.address else {
                throw SmokeFailure.processObservation(
                    "the verified fixture has no _main symbol for its deterministic ready stop"
                )
            }
            let launched = try await client!.launch(
                DebuggerLaunchConfiguration(
                    executablePath: fixturePath,
                    arguments: channel.launchArguments,
                    workingDirectory: fixtureRoot,
                    initialBreakpoints: [DebuggerBreakpoint(address: UInt64.max - 0x21)]
                )
            )
            latestSnapshot = launched
            XCTAssertTrue(
                launched.breakpoints.isEmpty,
                "The persistent launch must strip the nonempty static-breakpoint canary."
            )

            let targetProcessID: Int32
            switch launched.processState {
            case .paused(let processID, _):
                targetProcessID = processID
            default:
                throw SmokeFailure.invalidProcessState(
                    "launch returned \(launched.processState.displayTitle), expected paused at entry"
                )
            }
            guard targetProcessID > 0 else {
                throw SmokeFailure.processObservation("launch returned a non-positive target PID")
            }
            guard case .connected(let backendProcessID, let adapterName) = launched.backendState,
                  backendProcessID == targetProcessID,
                  adapterName == "Xcode LLDB CLI" else {
                throw SmokeFailure.invalidProcessState(
                    "launch did not project the production CLI connection for pid \(targetProcessID)"
                )
            }
            XCTAssertNil(
                launched.lastCommandRun,
                "The WS-19 snapshot must not expose a raw command transcript."
            )
            guard let targetObservation = try observer.observation(
                processID: targetProcessID
            ), let targetPath = executablePath(for: targetProcessID),
                  targetPath == fixturePath else {
                throw SmokeFailure.processObservation(
                    "pid \(targetProcessID) does not resolve to the authorized fixture executable"
                )
            }
            let targetRecord = RecordedProcess(
                observation: targetObservation,
                executablePath: targetPath
            )
            ownedProcesses[targetProcessID] = targetRecord

            let adapter = try await waitForNewDirectChild(
                parentProcessID: testProcessID,
                excluding: baselineChildren,
                executablePath: expectedLLDBPath,
                observer: observer,
                timeout: .seconds(2)
            )
            let adapterTree = try await waitForStableTree(
                rootedAt: adapter.processID,
                observer: observer,
                timeout: .seconds(2)
            )
            guard adapterTree[adapter.processID]?.executablePath == expectedLLDBPath else {
                throw SmokeFailure.processObservation(
                    "the retained adapter path differs from the selected Xcode LLDB"
                )
            }
            if let descendantRecord = adapterTree[targetProcessID],
               !descendantRecord.observation.hasSameIdentity(as: targetObservation) {
                throw SmokeFailure.processObservation(
                    "the target pid changed identity after descendant capture"
                )
            }
            try mergeExactProcesses(adapterTree, into: &ownedProcesses)
            // LLDB/debugserver topology can vary across Xcode builds. Record the exact target even
            // if launchd reparents it outside the retained adapter's descendant tree.
            ownedProcesses[targetProcessID] = targetRecord

            latestSnapshot = try await proveWS21F3LogicalBreakpointLifecycle(
                client: client!,
                launched: launched,
                fixturePath: fixturePath,
                fixtureRoot: fixtureRoot,
                mainAddress: mainAddress,
                channel: channel
            )

            guard let retainedAdapterObservation = try observer.observation(
                processID: adapter.processID
            ), retainedAdapterObservation.hasSameIdentity(as: adapter.observation),
                  executablePath(for: adapter.processID) == expectedLLDBPath else {
                throw SmokeFailure.processObservation(
                    "the production lifecycle did not retain the original Xcode LLDB adapter"
                )
            }
            try mergeExactProcesses(
                try captureStableTree(
                    rootedAt: adapter.processID,
                    observer: observer
                ),
                into: &ownedProcesses
            )

            let terminated = try await client!.terminate(from: latestSnapshot)
            latestSnapshot = terminated
            guard case .exited = terminated.processState else {
                throw SmokeFailure.invalidProcessState(
                    "terminate returned \(terminated.processState.displayTitle), expected exited"
                )
            }

            // Releasing the default client exercises the production controller's retained-adapter
            // shutdown. The bounded residue proof below observes, but never signals, these PIDs.
            client = nil
            try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
            try requireNoNewLLDBChild(
                parentProcessID: testProcessID,
                baseline: baselineChildren,
                expectedLLDBPath: expectedLLDBPath,
                observer: observer
            )
            try channel.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: channel.root.path))
        } catch {
            // If launch reached a live state, ask only the production client to terminate its own
            // target. Then release the retained adapter and wait for every identity already
            // observed. No broad lookup or PID-derived signal is used as an emergency shortcut.
            if let cleanupClient = client {
                switch latestSnapshot.processState {
                case .running, .paused:
                    latestSnapshot = (try? await cleanupClient.terminate(from: latestSnapshot))
                        ?? latestSnapshot
                default:
                    break
                }
            }
            if !ownedProcesses.values.contains(where: {
                $0.executablePath == expectedLLDBPath
            }),
               let adapter = try? await waitForNewDirectChild(
                   parentProcessID: testProcessID,
                   excluding: baselineChildren,
                   executablePath: expectedLLDBPath,
                   observer: observer,
                   timeout: .milliseconds(250)
               ) {
                let recoveredAdapterTree = (try? captureStableTree(
                    rootedAt: adapter.processID,
                    observer: observer
                )) ?? [adapter.processID: adapter]
                ownedProcesses.merge(recoveredAdapterTree) { existing, _ in existing }
            }
            client = nil
            if !ownedProcesses.isEmpty {
                do {
                    try await requireExactProcessesAbsent(ownedProcesses, timeout: .seconds(6))
                } catch let cleanupError {
                    XCTFail("Cleanup after live-smoke failure was incomplete: \(cleanupError)")
                }
            }
            do {
                try channel.cleanup()
                XCTAssertFalse(FileManager.default.fileExists(atPath: channel.root.path))
            } catch let cleanupError {
                XCTFail("WS-21 F3 fixture control cleanup failed: \(cleanupError)")
            }
            throw error
        }
    }

    private func proveWS21F3LogicalBreakpointLifecycle(
        client: LocalLLDBDebuggerClient,
        launched: DebuggerSessionSnapshot,
        fixturePath: String,
        fixtureRoot: String,
        mainAddress: UInt64,
        channel: WS21FixtureControlChannel
    ) async throws -> DebuggerSessionSnapshot {
        let frameworkPath = URL(fileURLWithPath: fixtureRoot)
            .appendingPathComponent("MacScopeDebuggerFixture.app")
            .appendingPathComponent("Contents/Frameworks")
            .appendingPathComponent("MacScopeDebuggerFixtureRuntime.framework")
            .appendingPathComponent("MacScopeDebuggerFixtureRuntime")
            .standardizedFileURL.path
        guard FileManager.default.isExecutableFile(atPath: frameworkPath) else {
            throw SmokeFailure.processObservation(
                "the verified fixture framework is unavailable at \(frameworkPath)"
            )
        }

        let mainURL = URL(fileURLWithPath: fixturePath)
        let frameworkURL = URL(fileURLWithPath: frameworkPath)
        let mainBinary = try MachOBinaryLoader().load(at: mainURL)
        let frameworkBinary = try MachOBinaryLoader().load(at: frameworkURL)
        let mainArtifact = try MachOSliceArtifactReconstructor.reconstruct(
            selectedSliceBytes: Data(contentsOf: mainURL)
        )
        let frameworkArtifact = try MachOSliceArtifactReconstructor.reconstruct(
            selectedSliceBytes: Data(contentsOf: frameworkURL)
        )
        let mainUUID = try requireArtifactUUID(mainArtifact.identity, role: "main")
        let frameworkUUID = try requireArtifactUUID(frameworkArtifact.identity, role: "framework")
        guard mainUUID != frameworkUUID,
              let mainCheckpointAddress = mainBinary.symbols.first(where: {
                  $0.name == "_macscope_fixture_main_checkpoint"
              })?.address,
              let frameworkCheckpointAddress = frameworkBinary.symbols.first(where: {
                  $0.name == "_macscope_fixture_framework_checkpoint"
              })?.address else {
            throw SmokeFailure.processObservation(
                "the fixture identities or exported checkpoint functions are unavailable"
            )
        }

        let frameworkSlot = ImageSlot(rawValue: 7)
        let authority = try makeWS21F3BreakpointAuthority(
            fixturePath: fixturePath,
            frameworkPath: frameworkPath,
            mainArtifact: mainArtifact,
            frameworkArtifact: frameworkArtifact,
            mainAddress: mainAddress,
            mainCheckpointAddress: mainCheckpointAddress,
            frameworkCheckpointAddress: frameworkCheckpointAddress,
            frameworkSlot: frameworkSlot
        )
        let mainSpecification = try DebuggerLogicalBreakpointSpecification(
            id: authority.mainLogicalID,
            revision: .init(validating: 1),
            enabled: true,
            target: .preferredAddress(owner: authority.mainOwner, preferredVA: mainAddress),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
        let frameworkSpecification = try DebuggerLogicalBreakpointSpecification(
            id: authority.frameworkLogicalID,
            revision: .init(validating: 1),
            enabled: true,
            target: .function(
                owner: authority.frameworkOwner,
                entryPreferredVA: frameworkCheckpointAddress,
                rawLinkageNameHint: "_macscope_fixture_framework_checkpoint"
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
        let specifications = [mainSpecification, frameworkSpecification]

        let initial = try requireAvailableRuntimeModuleAuthority(
            in: launched,
            description: "initial stopped launch"
        )
        XCTAssertEqual(moduleCount(uuid: mainUUID, in: initial.inventory), 1)
        XCTAssertEqual(moduleCount(uuid: frameworkUUID, in: initial.inventory), 0)
        let initialBundle = try makeWS21F3ReconcileBundle(
            authority: authority,
            specifications: specifications,
            catalogRevision: 1,
            resolutionRevision: 1,
            snapshot: launched
        )
        let initialMainModule = try requireCorrelatedModule(
            slot: .primary,
            in: initialBundle.projection,
            description: "initial main executable"
        )
        let mainEntryRuntime = try requireRuntimeLocation(
            ImageAddress(slot: .primary, address: mainAddress),
            module: initialMainModule,
            projection: initialBundle.projection,
            description: "initial _main"
        )
        let initialRunToCursorSnapshot = try await client.runToCursor(
            DebuggerRunToCursorRequest(
                resolvedAddress: mainEntryRuntime,
                observedStopID: initial.inventory.observedStopID
            ),
            from: launched
        )
        var snapshot = try await waitForRunToCursorStop(
            client: client,
            initialSnapshot: initialRunToCursorSnapshot,
            expectedProcessID: try XCTUnwrap(launched.liveProcessID),
            timeout: .seconds(3)
        )

        snapshot = try await client.continueExecution(from: snapshot)
        try await channel.open(
            forProcessID: try XCTUnwrap(launched.liveProcessID),
            timeout: .seconds(3)
        )
        snapshot = try await client.pause(from: snapshot)

        let preLoadBundle = try makeWS21F3ReconcileBundle(
            authority: authority,
            specifications: specifications,
            catalogRevision: 2,
            resolutionRevision: 2,
            snapshot: snapshot
        )
        try assertWS21F3Resolution(
            authority.mainLogicalID,
            is: .resolved,
            in: preLoadBundle.resolutions
        )
        try assertWS21F3Resolution(
            authority.frameworkLogicalID,
            is: .pendingModuleUnloaded,
            in: preLoadBundle.resolutions
        )
        let preLoadMainModule = try requireCorrelatedModule(
            slot: .primary,
            in: preLoadBundle.projection,
            description: "pre-load main executable"
        )
        let foreignRuntime = try requireRuntimeLocation(
            ImageAddress(slot: .primary, address: mainCheckpointAddress),
            module: preLoadMainModule,
            projection: preLoadBundle.projection,
            description: "foreign main checkpoint"
        )
        let foreignBreakpoint = DebuggerBreakpoint(address: foreignRuntime.runtimeAddress)
        snapshot = try await client.replaceBreakpoints([foreignBreakpoint], from: snapshot)
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        snapshot = try await client.reconcileLogicalBreakpoints(
            preLoadBundle.request,
            from: snapshot
        )
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        XCTAssertEqual(
            snapshot.transportBreakpointBindingState?.ownedLocations.map(\.bindingID.logicalID),
            [authority.mainLogicalID]
        )

        snapshot = try await client.continueExecution(from: snapshot)
        _ = try await channel.send(
            "load",
            processID: try XCTUnwrap(launched.liveProcessID),
            timeout: .seconds(3)
        )
        snapshot = try await client.pause(from: snapshot)
        let loadedBundle = try makeWS21F3ReconcileBundle(
            authority: authority,
            specifications: specifications,
            catalogRevision: 3,
            resolutionRevision: 3,
            snapshot: snapshot
        )
        try assertWS21F3Resolution(
            authority.frameworkLogicalID,
            is: .resolved,
            in: loadedBundle.resolutions
        )
        snapshot = try await client.reconcileLogicalBreakpoints(
            loadedBundle.request,
            from: snapshot
        )
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        let firstFrameworkBinding = try requireWS21F3OwnedLocation(
            logicalID: authority.frameworkLogicalID,
            in: snapshot
        )

        let loadedMainModule = try requireCorrelatedModule(
            slot: .primary,
            in: loadedBundle.projection,
            description: "loaded main executable"
        )
        let loadedFrameworkModule = try requireCorrelatedModule(
            slot: frameworkSlot,
            in: loadedBundle.projection,
            description: "loaded framework"
        )
        let mainProbeRange = try requireProbeRange(
            in: loadedMainModule,
            description: "loaded main executable"
        )
        let frameworkProbeRange = try requireProbeRange(
            in: loadedFrameworkModule,
            description: "loaded framework"
        )
        XCTAssertEqual(mainProbeRange.staticStart, frameworkProbeRange.staticStart)
        XCTAssertNotEqual(mainProbeRange.runtimeStart, frameworkProbeRange.runtimeStart)
        try assertTranslation(
            runtimeAddress: mainProbeRange.runtimeStart,
            expected: ImageAddress(slot: .primary, address: mainProbeRange.staticStart),
            projection: loadedBundle.projection
        )
        try assertTranslation(
            runtimeAddress: frameworkProbeRange.runtimeStart,
            expected: ImageAddress(slot: frameworkSlot, address: frameworkProbeRange.staticStart),
            projection: loadedBundle.projection
        )

        let checkpointTask = Task { @MainActor in
            _ = try await channel.send(
                "checkpoint",
                processID: try XCTUnwrap(launched.liveProcessID),
                timeout: .seconds(5)
            )
            return ()
        }
        var running = try await client.continueExecution(from: snapshot)
        snapshot = try await waitForRunToCursorStop(
            client: client,
            initialSnapshot: running,
            expectedProcessID: try XCTUnwrap(launched.liveProcessID),
            timeout: .seconds(3)
        )
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        running = try await client.continueExecution(from: snapshot)
        snapshot = try await waitForRunToCursorStop(
            client: client,
            initialSnapshot: running,
            expectedProcessID: try XCTUnwrap(launched.liveProcessID),
            timeout: .seconds(3)
        )
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        XCTAssertEqual(
            snapshot.transportBreakpointBindingState?.callbackRecords.last(where: {
                $0.logicalID == authority.frameworkLogicalID
            })?.outcome,
            .stopped
        )

        let postHitBundle = try makeWS21F3ReconcileBundle(
            authority: authority,
            specifications: specifications,
            catalogRevision: 4,
            resolutionRevision: 4,
            snapshot: snapshot
        )
        snapshot = try await client.reconcileLogicalBreakpoints(
            postHitBundle.request,
            from: snapshot
        )
        let postHitFrameworkBinding = try requireWS21F3OwnedLocation(
            logicalID: authority.frameworkLogicalID,
            in: snapshot
        )
        XCTAssertNotEqual(postHitFrameworkBinding.bindingID, firstFrameworkBinding.bindingID)
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        running = try await client.continueExecution(from: snapshot)
        _ = try await checkpointTask.value

        _ = try await channel.send(
            "unload",
            processID: try XCTUnwrap(launched.liveProcessID),
            timeout: .seconds(3)
        )
        snapshot = try await client.pause(from: running)
        let unloadedBundle = try makeWS21F3ReconcileBundle(
            authority: authority,
            specifications: specifications,
            catalogRevision: 5,
            resolutionRevision: 5,
            snapshot: snapshot
        )
        try assertWS21F3Resolution(
            authority.frameworkLogicalID,
            is: .pendingModuleUnloaded,
            in: unloadedBundle.resolutions
        )
        snapshot = try await client.reconcileLogicalBreakpoints(
            unloadedBundle.request,
            from: snapshot
        )
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        XCTAssertFalse(
            try XCTUnwrap(snapshot.transportBreakpointBindingState).ownedLocations.contains {
                $0.bindingID == postHitFrameworkBinding.bindingID
            }
        )

        running = try await client.continueExecution(from: snapshot)
        _ = try await channel.send(
            "load",
            processID: try XCTUnwrap(launched.liveProcessID),
            timeout: .seconds(3)
        )
        snapshot = try await client.pause(from: running)
        let reloadedBundle = try makeWS21F3ReconcileBundle(
            authority: authority,
            specifications: specifications,
            catalogRevision: 6,
            resolutionRevision: 6,
            snapshot: snapshot
        )
        snapshot = try await client.reconcileLogicalBreakpoints(
            reloadedBundle.request,
            from: snapshot
        )
        let reloadedFrameworkBinding = try requireWS21F3OwnedLocation(
            logicalID: authority.frameworkLogicalID,
            in: snapshot
        )
        XCTAssertNotEqual(reloadedBundle.projection.key, loadedBundle.projection.key)
        XCTAssertNotEqual(
            reloadedFrameworkBinding.bindingID,
            postHitFrameworkBinding.bindingID
        )
        XCTAssertNotEqual(
            reloadedFrameworkBinding.backendBreakpointID,
            postHitFrameworkBinding.backendBreakpointID
        )
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)

        let reloadedMainModule = try requireCorrelatedModule(
            slot: .primary,
            in: reloadedBundle.projection,
            description: "reloaded main executable"
        )
        let runToForeignLocation = try requireRuntimeLocation(
            ImageAddress(slot: .primary, address: mainCheckpointAddress),
            module: reloadedMainModule,
            projection: reloadedBundle.projection,
            description: "reloaded main checkpoint"
        )
        let reloadedInventory = try requireAvailableRuntimeModuleAuthority(
            in: snapshot,
            description: "reloaded Run to Cursor stop"
        ).inventory
        let finalCheckpointTask = Task { @MainActor in
            _ = try await channel.send(
                "checkpoint",
                processID: try XCTUnwrap(launched.liveProcessID),
                timeout: .seconds(5)
            )
            return ()
        }
        let runToCursorTask = Task { @MainActor in
            try await client.runToCursor(
                DebuggerRunToCursorRequest(
                    resolvedAddress: runToForeignLocation,
                    observedStopID: reloadedInventory.observedStopID
                ),
                from: snapshot
            )
        }
        snapshot = try await runToCursorTask.value
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)

        let emptyBundle = try makeWS21F3ReconcileBundle(
            authority: authority,
            specifications: [],
            catalogRevision: 7,
            resolutionRevision: 7,
            snapshot: snapshot
        )
        snapshot = try await client.reconcileLogicalBreakpoints(
            emptyBundle.request,
            from: snapshot
        )
        XCTAssertEqual(snapshot.transportBreakpointBindingState?.ownedLocations, [])
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        running = try await client.continueExecution(from: snapshot)
        _ = try await finalCheckpointTask.value

        let foreignSurvivalTask = Task { @MainActor in
            _ = try await channel.send(
                "checkpoint",
                processID: try XCTUnwrap(launched.liveProcessID),
                timeout: .seconds(5)
            )
            return ()
        }
        snapshot = try await waitForRunToCursorStop(
            client: client,
            initialSnapshot: running,
            expectedProcessID: try XCTUnwrap(launched.liveProcessID),
            timeout: .seconds(3)
        )
        XCTAssertEqual(
            snapshot.liveProgramCounter,
            foreignRuntime.runtimeAddress,
            "The ordinary foreign breakpoint must physically stop the target after RTC and "
                + "logical cleanup, not merely survive in reducer presentation state."
        )
        assertWS21F3ForeignBreakpoint(foreignBreakpoint, in: snapshot)
        snapshot = try await client.replaceBreakpoints([], from: snapshot)
        XCTAssertTrue(snapshot.breakpoints.isEmpty)
        running = try await client.continueExecution(from: snapshot)
        _ = try await foreignSurvivalTask.value
        return running
    }

    private func makeWS21F3BreakpointAuthority(
        fixturePath: String,
        frameworkPath: String,
        mainArtifact: MachOSliceArtifactReconstruction,
        frameworkArtifact: MachOSliceArtifactReconstruction,
        mainAddress: UInt64,
        mainCheckpointAddress: UInt64,
        frameworkCheckpointAddress: UInt64,
        frameworkSlot: ImageSlot
    ) throws -> WS21F3BreakpointAuthority {
        let mainEntry = DebuggerWorkspaceArtifactCatalogEntry(
            binaryID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            slot: .primary,
            ownerRevision: .init(rawValue: 1),
            artifactIdentity: mainArtifact.identity,
            preferredSegmentLayout: mainArtifact.preferredSegmentLayout,
            artifactIntegrityState: .verified,
            sourcePathHint: fixturePath,
            executablePathHint: fixturePath
        )
        let frameworkEntry = DebuggerWorkspaceArtifactCatalogEntry(
            binaryID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            slot: frameworkSlot,
            ownerRevision: .init(rawValue: 1),
            artifactIdentity: frameworkArtifact.identity,
            preferredSegmentLayout: frameworkArtifact.preferredSegmentLayout,
            artifactIntegrityState: .verified,
            sourcePathHint: frameworkPath,
            executablePathHint: frameworkPath
        )
        let mainOwner = DebuggerWorkspaceImageOwnerSeal(
            slot: mainEntry.slot,
            binaryID: mainEntry.binaryID,
            artifactIdentity: mainArtifact.identity
        )
        let frameworkOwner = DebuggerWorkspaceImageOwnerSeal(
            slot: frameworkEntry.slot,
            binaryID: frameworkEntry.binaryID,
            artifactIdentity: frameworkArtifact.identity
        )
        return WS21F3BreakpointAuthority(
            workspaceID: UUID(),
            catalogID: UUID(),
            artifactCatalog: DebuggerWorkspaceArtifactCatalog(
                revision: .init(rawValue: 1),
                artifacts: [mainEntry, frameworkEntry]
            ),
            resolutionOwners: [
                try makeWS21F3ResolutionOwner(
                    entry: mainEntry,
                    artifact: mainArtifact,
                    functions: [
                        (mainAddress, "_main"),
                        (mainCheckpointAddress, "_macscope_fixture_main_checkpoint"),
                    ]
                ),
                try makeWS21F3ResolutionOwner(
                    entry: frameworkEntry,
                    artifact: frameworkArtifact,
                    functions: [
                        (
                            frameworkCheckpointAddress,
                            "_macscope_fixture_framework_checkpoint"
                        ),
                    ]
                ),
            ],
            mainOwner: mainOwner,
            frameworkOwner: frameworkOwner,
            mainLogicalID: DebuggerLogicalBreakpointID(rawValue: UUID()),
            frameworkLogicalID: DebuggerLogicalBreakpointID(rawValue: UUID())
        )
    }

    private func makeWS21F3ResolutionOwner(
        entry: DebuggerWorkspaceArtifactCatalogEntry,
        artifact: MachOSliceArtifactReconstruction,
        functions: [(address: UInt64, name: String)]
    ) throws -> DebuggerBreakpointResolutionOwnerIndex {
        let segments = try artifact.preferredSegmentLayout.records.map { record in
            try XCTUnwrap(DebuggerBreakpointResolutionSegment(
                name: record.name,
                preferredStart: record.preferredVMStart,
                byteCount: record.preferredVMSize,
                isExecutable: record.initialProtections & VM_PROT_EXECUTE != 0
            ))
        }
        let staticAddresses = try functions.map { function in
            let segment = try XCTUnwrap(segments.first {
                $0.isExecutable && $0.contains(function.address)
            })
            return DebuggerBreakpointStaticAddressEvidence(
                preferredVA: function.address,
                segmentName: segment.name,
                kind: .decodedExecutableInstruction
            )
        }
        return DebuggerBreakpointResolutionOwnerIndex(
            coordinate: DebuggerWorkspaceArtifactCoordinate(
                binaryID: entry.binaryID,
                slot: entry.slot,
                artifactIdentity: artifact.identity,
                ownerRevision: entry.ownerRevision
            ),
            revision: 1,
            segments: segments,
            staticAddresses: staticAddresses,
            functions: functions.map {
                DebuggerBreakpointFunctionEvidence(
                    entryPreferredVA: $0.address,
                    rawLinkageName: $0.name
                )
            },
            hasCanonicalRawSymbolAuthority: true,
            rawSymbols: functions.map {
                DebuggerBreakpointRawSymbolEvidence(
                    exactRawLinkageName: $0.name,
                    kind: "function",
                    libraryName: nil,
                    preferredVA: $0.address
                )
            },
            hasExactSourceAuthority: false,
            sourceRows: []
        )
    }

    private func makeWS21F3ReconcileBundle(
        authority: WS21F3BreakpointAuthority,
        specifications: [DebuggerLogicalBreakpointSpecification],
        catalogRevision: UInt64,
        resolutionRevision: UInt64,
        snapshot: DebuggerSessionSnapshot
    ) throws -> WS21F3ReconcileBundle {
        let runtime = try requireAvailableRuntimeModuleAuthority(
            in: snapshot,
            description: "WS-21 F3 reconciliation"
        )
        let projection = DebuggerWorkspaceArtifactCorrelator().correlate(
            inventory: runtime.inventory,
            authorityRevision: runtime.authorityRevision,
            catalog: authority.artifactCatalog
        )
        let catalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: authority.catalogID,
            revision: catalogRevision,
            specifications: specifications
        )
        let logicalCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: authority.workspaceID,
            catalogID: authority.catalogID,
            revision: catalogRevision
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: authority.workspaceID,
            revision: .init(rawValue: resolutionRevision),
            workspaceArtifactCatalogRevision: authority.artifactCatalog.revision
        )
        let resolutions = DebuggerLogicalBreakpointResolver.resolve(
            catalog: catalog,
            coordinate: logicalCoordinate,
            resolutionCatalog: DebuggerBreakpointResolutionCatalog(
                coordinate: resolutionCoordinate,
                owners: authority.resolutionOwners
            ),
            requiringResolutionCoordinate: resolutionCoordinate,
            runtimeProjection: projection,
            requiringMappingKey: projection.key
        )
        let expectations = specifications.map {
            DebuggerLogicalBreakpointResolutionExpectation(
                logicalID: $0.id,
                specificationRevision: $0.revision
            )
        }
        let observation = try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: logicalCoordinate,
            resolutionCatalogCoordinate: resolutionCoordinate,
            mappingKey: projection.key,
            expectedSpecifications: expectations,
            results: resolutions
        ))
        return WS21F3ReconcileBundle(
            request: try DebuggerLogicalBreakpointReconcileRequest(
                catalogAvailability: .available,
                catalog: catalog,
                observation: observation
            ),
            resolutions: resolutions,
            projection: projection
        )
    }

    private func assertWS21F3Resolution(
        _ logicalID: DebuggerLogicalBreakpointID,
        is expected: WS21F3ExpectedResolution,
        in resolutions: [DebuggerLogicalBreakpointResolution]
    ) throws {
        let resolution = try XCTUnwrap(resolutions.first { $0.logicalID == logicalID })
        switch (expected, resolution.state) {
        case (.resolved, .resolved), (.resolved, .resolvedMultiple):
            break
        case (.pendingModuleUnloaded, .pending(.moduleUnloaded)):
            break
        default:
            XCTFail("Unexpected WS-21 F3 resolution state: \(resolution.state)")
        }
    }

    private func requireRuntimeLocation(
        _ address: ImageAddress,
        module: DebuggerCorrelatedRuntimeModule,
        projection: DebuggerRuntimeMappingProjection,
        description: String
    ) throws -> DebuggerResolvedRuntimeAddress {
        guard case .resolved(let locations) =
                DebuggerRuntimeAddressTranslator.runtimeAddresses(
                    forStaticAddress: address,
                    coordinate: module.coordinate,
                    in: projection,
                    requiring: projection.key
                ),
              locations.count == 1,
              let location = locations.first else {
            throw SmokeFailure.invalidProcessState(
                "\(description) did not translate to one exact runtime address"
            )
        }
        return location
    }

    private func requireWS21F3OwnedLocation(
        logicalID: DebuggerLogicalBreakpointID,
        in snapshot: DebuggerSessionSnapshot
    ) throws -> DebuggerOwnedBackendBreakpointLocation {
        let matches = try XCTUnwrap(snapshot.transportBreakpointBindingState)
            .ownedLocations.filter { $0.bindingID.logicalID == logicalID }
        return try XCTUnwrap(matches.count == 1 ? matches.first : nil)
    }

    private func assertWS21F3ForeignBreakpoint(
        _ foreign: DebuggerBreakpoint,
        in snapshot: DebuggerSessionSnapshot
    ) {
        XCTAssertEqual(snapshot.breakpoints.map(\.address), [foreign.address])
        XCTAssertEqual(snapshot.breakpoints.map(\.isEnabled), [true])
    }

    private func requireArtifactUUID(
        _ identity: MachOSliceArtifactIdentity,
        role: String
    ) throws -> UUID {
        guard let uuid = identity.uuid else {
            throw SmokeFailure.processObservation(
                "the verified \(role) fixture artifact has no Mach-O UUID"
            )
        }
        return uuid
    }

    private func requireAvailableRuntimeModuleAuthority(
        in snapshot: DebuggerSessionSnapshot,
        description: String
    ) throws -> (
        authorityRevision: DebuggerRuntimeModuleAuthorityRevision,
        inventory: DebuggerRuntimeModuleInventory
    ) {
        guard let authorityRevision = snapshot.transportRuntimeModuleAuthorityRevision,
              case .available(let inventory) = snapshot.transportRuntimeModuleAuthority else {
            throw SmokeFailure.invalidProcessState(
                "\(description) did not publish available typed runtime-module authority "
                    + "(authority: \(String(describing: snapshot.transportRuntimeModuleAuthority)); "
                    + "status: \(snapshot.statusMessage))"
            )
        }
        guard inventory.stop == snapshot.transportStopCoordinate,
              inventory.processID == snapshot.liveProcessID else {
            throw SmokeFailure.invalidProcessState(
                "\(description) runtime-module authority does not match its exact stop and process"
            )
        }
        return (authorityRevision, inventory)
    }

    private func requireRefreshedExpressionSnapshot(
        _ result: DebuggerExpressionResult,
        operation: String
    ) throws -> DebuggerSessionSnapshot {
        guard let snapshot = result.refreshedSnapshot else {
            throw SmokeFailure.invalidProcessState(
                "\(operation) returned no authoritative post-expression refresh snapshot"
            )
        }
        guard case .paused = snapshot.processState else {
            throw SmokeFailure.invalidProcessState(
                "\(operation) refresh returned \(snapshot.processState.displayTitle), expected paused"
            )
        }
        return snapshot
    }

    private func waitForRunToCursorStop(
        client: LocalLLDBDebuggerClient,
        initialSnapshot: DebuggerSessionSnapshot,
        expectedProcessID: Int32,
        timeout: Duration
    ) async throws -> DebuggerSessionSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var snapshot = initialSnapshot

        while case .running(let processID, _) = snapshot.processState,
              processID == expectedProcessID,
              clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
            snapshot = try await client.pollProcessStatus(from: snapshot)
        }

        guard case .paused(let processID, _) = snapshot.processState,
              processID == expectedProcessID else {
            throw SmokeFailure.invalidProcessState(
                "Expected debugger stop did not arrive within \(timeout); "
                    + "last state was \(snapshot.processState.displayTitle)"
            )
        }
        return snapshot
    }

    private func requireNonzeroPointerValue(
        _ value: String,
        operation: String
    ) throws -> UInt64 {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix("0x"),
              let pointer = UInt64(normalized.dropFirst(2), radix: 16),
              pointer != 0 else {
            throw SmokeFailure.invalidProcessState(
                "\(operation) returned an invalid handle: \(String(reflecting: value))"
            )
        }
        return pointer
    }

    private func requireZeroIntegerValue(
        _ value: String,
        operation: String
    ) throws {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
            throw SmokeFailure.invalidProcessState(
                "\(operation) returned failure: \(String(reflecting: value))"
            )
        }
    }

    private func moduleCount(
        uuid: UUID,
        in inventory: DebuggerRuntimeModuleInventory
    ) -> Int {
        inventory.modules.filter { $0.observation.uuid == uuid }.count
    }

    private func requireCorrelatedModule(
        slot: ImageSlot,
        in projection: DebuggerRuntimeMappingProjection,
        description: String
    ) throws -> DebuggerCorrelatedRuntimeModule {
        let matches = projection.modules.filter { $0.coordinate.slot == slot }
        guard matches.count == 1, let module = matches.first else {
            throw SmokeFailure.invalidProcessState(
                "expected one exact \(description) correlation, observed \(matches.count)"
            )
        }
        return module
    }

    private func requireProbeRange(
        in module: DebuggerCorrelatedRuntimeModule,
        description: String
    ) throws -> DebuggerRuntimeMappedRange {
        let ranges = module.mappedRanges.filter { $0.segmentName == "__MACSCOPE" }
        guard ranges.count == 1, let range = ranges.first else {
            throw SmokeFailure.invalidProcessState(
                "expected one \(description) __MACSCOPE range, observed \(ranges.count)"
            )
        }
        return range
    }

    private func assertTranslation(
        runtimeAddress: UInt64,
        expected: ImageAddress,
        projection: DebuggerRuntimeMappingProjection
    ) throws {
        guard case .resolved(let resolved) = DebuggerRuntimeAddressTranslator.staticAddress(
            forRuntimeAddress: runtimeAddress,
            in: projection,
            requiring: projection.key
        ) else {
            throw SmokeFailure.invalidProcessState(
                "runtime address \(runtimeAddress.hexAddress) did not translate exactly"
            )
        }
        XCTAssertEqual(resolved.imageAddress, expected)
    }

    private func waitForNewDirectChild(
        parentProcessID: Int32,
        excluding baseline: Set<Int32>,
        executablePath expectedExecutablePath: String,
        observer: Phase2QualificationLibprocProcessObserver,
        timeout: Duration
    ) async throws -> RecordedProcess {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            let children = try requireChildren(of: parentProcessID, observer: observer)
            let matches = try children
                .filter { !baseline.contains($0) }
                .compactMap { processID -> RecordedProcess? in
                    guard let observation = try observer.observation(processID: processID),
                          let path = executablePath(for: processID) else { return nil }
                    return path == expectedExecutablePath
                        ? RecordedProcess(observation: observation, executablePath: path)
                        : nil
                }
            if matches.count == 1 {
                return matches[0]
            }
            if matches.count > 1 {
                throw SmokeFailure.processObservation(
                    "more than one new direct child resolved to \(expectedExecutablePath)"
                )
            }
            if clock.now < deadline {
                try await clock.sleep(for: .milliseconds(25))
            }
        } while clock.now < deadline
        throw SmokeFailure.processObservation(
            "no retained direct-child LLDB appeared within \(timeout)"
        )
    }

    private func waitForStableTree(
        rootedAt rootProcessID: Int32,
        observer: Phase2QualificationLibprocProcessObserver,
        timeout: Duration
    ) async throws -> [Int32: RecordedProcess] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var accumulated: [Int32: RecordedProcess] = [:]
        var successfulSampleCount = 0
        var lastFailureDescription = "no sample completed"
        repeat {
            do {
                let tree = try captureStableTree(
                    rootedAt: rootProcessID,
                    observer: observer
                )
                try mergeExactProcesses(
                    tree,
                    into: &accumulated,
                    allowingTransientIdentityChangesExcept: [rootProcessID]
                )
                successfulSampleCount += 1
                if successfulSampleCount >= 2 {
                    return accumulated
                }
            } catch {
                lastFailureDescription = String(describing: error)
            }
            if clock.now < deadline {
                try await clock.sleep(for: .milliseconds(25))
            }
        } while clock.now < deadline
        throw SmokeFailure.processObservation(
            "the retained-adapter root did not yield two exact descendant samples; "
            + "last failure: \(lastFailureDescription)"
        )
    }

    private func captureStableTree(
        rootedAt rootProcessID: Int32,
        observer: Phase2QualificationLibprocProcessObserver
    ) throws -> [Int32: RecordedProcess] {
        var pending = [rootProcessID]
        var visited: Set<Int32> = []
        var result: [Int32: RecordedProcess] = [:]

        while let processID = pending.popLast() {
            guard visited.insert(processID).inserted else { continue }
            guard let before = try observer.observation(processID: processID),
                  let path = executablePath(for: processID) else {
                if processID != rootProcessID {
                    // A transient helper that is already absent cannot become cleanup residue.
                    continue
                }
                throw SmokeFailure.processObservation(
                    "the retained adapter was unavailable during descendant capture"
                )
            }
            let beforeRecord = RecordedProcess(
                observation: before,
                executablePath: path
            )
            try mergeExactProcesses([processID: beforeRecord], into: &result)

            guard let children = try observer.childProcessIDs(of: processID) else {
                if processID == rootProcessID {
                    throw SmokeFailure.processObservation(
                        "the retained adapter child snapshot changed during capture"
                    )
                }
                continue
            }

            if let after = try observer.observation(processID: processID) {
                guard before.hasSameIdentity(as: after) else {
                    throw SmokeFailure.processObservation(
                        "pid \(processID) changed identity during descendant capture"
                    )
                }
            } else if processID == rootProcessID {
                throw SmokeFailure.processObservation(
                    "the retained adapter disappeared during descendant capture"
                )
            }

            for childProcessID in children {
                // Record an exact child immediately. It may legitimately reparent before its own
                // descendants are sampled; the recorded identity remains cleanup authority.
                if let child = try observer.observation(processID: childProcessID),
                   let childPath = executablePath(for: childProcessID) {
                    try mergeExactProcesses(
                        [childProcessID: RecordedProcess(
                            observation: child,
                            executablePath: childPath
                        )],
                        into: &result
                    )
                }
                pending.append(childProcessID)
            }
        }

        guard let finalRoot = try observer.observation(processID: rootProcessID),
              let capturedRoot = result[rootProcessID],
              capturedRoot.observation.hasSameIdentity(as: finalRoot) else {
            throw SmokeFailure.processObservation(
                "the retained adapter changed identity during descendant capture"
            )
        }
        return result
    }

    private func mergeExactProcesses(
        _ source: [Int32: RecordedProcess],
        into destination: inout [Int32: RecordedProcess],
        allowingTransientIdentityChangesExcept protectedProcessIDs: Set<Int32> = []
    ) throws {
        for (processID, candidate) in source {
            if let existing = destination[processID] {
                guard existing.executablePath == candidate.executablePath,
                      existing.observation.hasSameIdentity(as: candidate.observation) else {
                    if !protectedProcessIDs.contains(processID) {
                        destination.removeValue(forKey: processID)
                        continue
                    }
                    throw SmokeFailure.processObservation(
                        "pid \(processID) changed exact identity across ownership samples"
                    )
                }
            } else {
                destination[processID] = candidate
            }
        }
    }

    private func requireExactProcessesAbsent(
        _ processes: [Int32: RecordedProcess],
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var remaining = processes.values.filter { processExists($0.processID) }
        while !remaining.isEmpty, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(25))
            remaining = processes.values.filter { processExists($0.processID) }
        }
        guard remaining.isEmpty else {
            let detail = remaining
                .sorted { $0.processID < $1.processID }
                .map { "\($0.processID):\($0.executablePath)" }
                .joined(separator: ", ")
            throw SmokeFailure.processResidue(
                "recorded processes remained after \(timeout): \(detail)"
            )
        }

        // Require kernel absence rather than treating an identity change as successful cleanup.
        // A recycled PID is therefore reported rather than silently accepted as proof.
        for process in processes.values {
            errno = 0
            let result = Darwin.kill(process.processID, 0)
            let observedErrno = errno
            guard result == -1, observedErrno == ESRCH else {
                throw SmokeFailure.processResidue(
                    "pid \(process.processID) did not produce ESRCH after cleanup "
                    + "(result \(result), errno \(observedErrno))"
                )
            }
        }
    }

    private func requireNoNewLLDBChild(
        parentProcessID: Int32,
        baseline: Set<Int32>,
        expectedLLDBPath: String,
        observer: Phase2QualificationLibprocProcessObserver
    ) throws {
        let residue = try requireChildren(of: parentProcessID, observer: observer)
            .filter { !baseline.contains($0) }
            .filter { executablePath(for: $0) == expectedLLDBPath }
        guard residue.isEmpty else {
            throw SmokeFailure.processResidue(
                "new direct-child LLDB pids remain: \(residue.sorted())"
            )
        }
    }

    private func requireChildren(
        of processID: Int32,
        observer: Phase2QualificationLibprocProcessObserver
    ) throws -> [Int32] {
        guard let children = try observer.childProcessIDs(of: processID) else {
            throw SmokeFailure.processObservation(
                "could not obtain a stable child snapshot for pid \(processID)"
            )
        }
        return children
    }

    private func executablePath(for processID: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(processID, buffer.baseAddress, UInt32(buffer.count))
        }
        guard count > 0, Int(count) < bytes.count else { return nil }
        bytes[Int(count)] = 0
        return URL(fileURLWithPath: String(cString: bytes)).standardizedFileURL.path
    }

    private func processExists(_ processID: Int32) -> Bool {
        errno = 0
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno != ESRCH
    }
}
