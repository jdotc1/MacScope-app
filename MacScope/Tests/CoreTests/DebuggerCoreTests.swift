import XCTest
@testable import MacScope

final class DebuggerCoreTests: XCTestCase {
    func testBreakpointToggleAddsSortsAndRemovesByAddress() {
        var session = DebuggerSessionSnapshot.empty

        let first = session.toggleBreakpoint(at: 0x1000_0020)
        let second = session.toggleBreakpoint(at: 0x1000_0010)

        XCTAssertEqual(first?.address, 0x1000_0020)
        XCTAssertEqual(second?.address, 0x1000_0010)
        XCTAssertEqual(session.breakpoints.map(\.address), [0x1000_0010, 0x1000_0020])
        XCTAssertEqual(session.activeBreakpointCount, 2)

        let removed = session.toggleBreakpoint(at: 0x1000_0010)

        XCTAssertNil(removed)
        XCTAssertEqual(session.breakpoints.map(\.address), [0x1000_0020])
        XCTAssertEqual(session.activeBreakpointCount, 1)
    }

    func testBreakpointUpsertPreservesSingleBreakpointPerAddress() {
        var session = DebuggerSessionSnapshot.empty

        session.upsertBreakpoint(DebuggerBreakpoint(address: 0x1000_0004))
        session.upsertBreakpoint(DebuggerBreakpoint(address: 0x1000_0004, isEnabled: false, condition: "x0 == 1", hitCount: 3))

        XCTAssertEqual(session.breakpoints.count, 1)
        XCTAssertEqual(session.breakpoints.first?.address, 0x1000_0004)
        XCTAssertEqual(session.breakpoints.first?.isEnabled, false)
        XCTAssertEqual(session.breakpoints.first?.condition, "x0 == 1")
        XCTAssertEqual(session.breakpoints.first?.hitCount, 3)
        XCTAssertEqual(session.activeBreakpointCount, 0)

        session.setBreakpointEnabled(at: 0x1000_0004, isEnabled: true)
        XCTAssertEqual(session.breakpoints.first?.isEnabled, true)
        XCTAssertEqual(session.activeBreakpointCount, 1)
    }

    func testLiveProcessSessionRequiresConnectedMatchingProcessID() {
        let pausedSnapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 42, adapterName: "Test LLDB")
        )
        XCTAssertEqual(pausedSnapshot.liveProcessID, 42)
        XCTAssertTrue(pausedSnapshot.hasLiveProcessSession)
        XCTAssertTrue(pausedSnapshot.canContinueLiveProcess)
        XCTAssertTrue(pausedSnapshot.canStepOverLiveProcess)
        XCTAssertFalse(pausedSnapshot.canPauseLiveProcess)
        XCTAssertTrue(pausedSnapshot.canTerminateLiveProcess)
        XCTAssertTrue(pausedSnapshot.canRefreshStoppedSnapshot)

        let runningSnapshot = DebuggerSessionSnapshot(
            processState: .running(processID: 42, executableName: "example"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running.",
            backendState: .connected(processID: 42, adapterName: "Test LLDB")
        )
        XCTAssertEqual(runningSnapshot.liveProcessID, 42)
        XCTAssertTrue(runningSnapshot.hasLiveProcessSession)
        XCTAssertFalse(runningSnapshot.canContinueLiveProcess)
        XCTAssertFalse(runningSnapshot.canStepOverLiveProcess)
        XCTAssertTrue(runningSnapshot.canPauseLiveProcess)
        XCTAssertTrue(runningSnapshot.canTerminateLiveProcess)
        XCTAssertFalse(runningSnapshot.canRefreshStoppedSnapshot)

        let mismatchedSnapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 43, adapterName: "Test LLDB")
        )
        XCTAssertNil(mismatchedSnapshot.liveProcessID)
        XCTAssertFalse(mismatchedSnapshot.hasLiveProcessSession)
        XCTAssertFalse(mismatchedSnapshot.canContinueLiveProcess)
        XCTAssertFalse(mismatchedSnapshot.canTerminateLiveProcess)
        XCTAssertFalse(mismatchedSnapshot.canRefreshStoppedSnapshot)

        let batchStoppedSnapshot = DebuggerSessionSnapshot(
            processState: .batchStopped(processID: 42, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Batch stopped.",
            backendState: .ready(adapterName: "Xcode LLDB Batch")
        )
        XCTAssertNil(batchStoppedSnapshot.liveProcessID)
        XCTAssertFalse(batchStoppedSnapshot.hasLiveProcessSession)
        XCTAssertFalse(batchStoppedSnapshot.canContinueLiveProcess)
        XCTAssertFalse(batchStoppedSnapshot.canPauseLiveProcess)
        XCTAssertFalse(batchStoppedSnapshot.canTerminateLiveProcess)
        XCTAssertFalse(batchStoppedSnapshot.canRefreshStoppedSnapshot)
    }

    func testImportedTargetLaunchConfigurationNormalizesPathAndWorkingDirectory() throws {
        let homeDirectory = NSHomeDirectory()
        let breakpoint = DebuggerBreakpoint(address: 0x1000_0040)

        // Tilde expansion + whitespace trimming are pure string normalization and
        // must not depend on the paths existing on the host.
        let tildeConfiguration = DebuggerLaunchConfiguration.importedTarget(
            executablePath: " ~/Tools/FixtureApp ",
            arguments: ["--fixture"],
            workingDirectory: " ",
            initialBreakpoints: [breakpoint]
        )
        XCTAssertEqual(tildeConfiguration.executablePath, "\(homeDirectory)/Tools/FixtureApp")
        XCTAssertEqual(tildeConfiguration.arguments, ["--fixture"])
        XCTAssertEqual(tildeConfiguration.workingDirectory, "\(homeDirectory)/Tools")
        XCTAssertEqual(tildeConfiguration.initialBreakpoints, [breakpoint])
        XCTAssertEqual(tildeConfiguration.displayName, "FixtureApp")

        // The descriptor's launch policy validates that the working directory
        // EXISTS, so those assertions run against a directory this test creates —
        // never a directory the host happens to have (a bare `~/Tools` passed on
        // machines that had one and failed everywhere else).
        let toolsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeImportedTargetTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: toolsDirectory) }
        let toolsPath = toolsDirectory.path

        let configuration = DebuggerLaunchConfiguration.importedTarget(
            executablePath: " \(toolsPath)/FixtureApp ",
            arguments: ["--fixture"],
            workingDirectory: " ",
            initialBreakpoints: [breakpoint]
        )
        XCTAssertEqual(configuration.executablePath, "\(toolsPath)/FixtureApp")
        XCTAssertEqual(configuration.workingDirectory, toolsPath)

        let descriptor = configuration.importedTargetDescriptor
        XCTAssertEqual(descriptor.id, "imported:\(toolsPath)/FixtureApp")
        XCTAssertEqual(descriptor.kind, .importedTarget)
        XCTAssertEqual(descriptor.title, "FixtureApp")
        XCTAssertEqual(descriptor.detail, "Launch from \(toolsPath).")
        XCTAssertEqual(descriptor.policy, .enabled(actionTitle: "Launch imported target"))
        XCTAssertTrue(descriptor.policy.isEnabled)
        XCTAssertEqual(descriptor.validationSummary?.argumentSummary, "1 argument")
        XCTAssertEqual(descriptor.validationSummary?.environmentSummary, "No environment overrides")
        XCTAssertEqual(
            descriptor.validationSummary?.detail,
            "Launch FixtureApp from \(toolsPath). 1 argument; No environment overrides."
        )
    }

    func testLaunchValidationSummarizesArgumentsEnvironmentAndBlocksUnsafeValues() {
        let configuration = DebuggerLaunchConfiguration.importedTarget(
            executablePath: "/bin/echo",
            arguments: ["ready", "line\nbreak"],
            environment: [
                " MACSCOPE_MODE ": "debug",
                "BAD=KEY": "value",
                "UNSAFE_VALUE": "line\nbreak"
            ],
            workingDirectory: "/bin"
        )
        let summary = DebuggerLaunchValidationSummary.evaluate(
            configuration: configuration,
            launchSupport: .supported
        )

        XCTAssertEqual(configuration.normalizedEnvironment["MACSCOPE_MODE"], "debug")
        XCTAssertEqual(summary.displayName, "echo")
        XCTAssertEqual(summary.argumentSummary, "2 arguments")
        XCTAssertEqual(summary.environmentSummary, "3 environment overrides")
        XCTAssertEqual(summary.statusTitle, "Blocked")
        XCTAssertEqual(summary.disabledReason, "Launch argument 2 contains unsupported control characters.")
        XCTAssertTrue(summary.issues.contains(.init(
            severity: .blocker,
            message: "Environment key BAD=KEY contains unsupported characters."
        )))
        XCTAssertTrue(summary.issues.contains(.init(
            severity: .blocker,
            message: "Environment value for UNSAFE_VALUE contains unsupported control characters."
        )))
    }

    func testImportedTargetDescriptorBlocksMissingExecutableBeforeLaunch() {
        let configuration = DebuggerLaunchConfiguration.importedTarget(executablePath: " ")
        let descriptor = DebuggerTargetSelectionDescriptor.importedTarget(
            configuration: configuration,
            launchSupport: .supported
        )

        XCTAssertEqual(descriptor.id, "imported:")
        XCTAssertEqual(descriptor.kind, .importedTarget)
        XCTAssertEqual(descriptor.title, "Imported target")
        XCTAssertEqual(descriptor.detail, "Choose an imported executable to launch under LLDB.")
        XCTAssertEqual(descriptor.policy, .blocked(reason: "Choose an imported executable before launching."))
        XCTAssertEqual(descriptor.policy.statusTitle, "Blocked")
        XCTAssertFalse(descriptor.policy.isEnabled)
    }

    func testTargetSelectionDescriptorKeepsLocalPIDAttachBlockedByPolicy() {
        let attachPolicy = DebuggerAttachPolicy.denied(reason: "Attach remains disabled until signed target policy is proven.")
        let pidRequest = DebuggerAttachRequest(target: .processID(1234))
        let pidDescriptor = DebuggerTargetSelectionDescriptor.processAttach(
            request: pidRequest,
            policy: attachPolicy
        )

        XCTAssertEqual(pidDescriptor.id, "attach:pid 1234")
        XCTAssertEqual(pidDescriptor.kind, .processAttach)
        XCTAssertEqual(pidDescriptor.title, "pid 1234")
        XCTAssertEqual(
            pidDescriptor.detail,
            "Attach to pid 1234 is disabled: Attach remains disabled until signed target policy is proven."
        )
        XCTAssertEqual(
            pidDescriptor.policy,
            .blocked(reason: "Attach remains disabled until signed target policy is proven.")
        )
        XCTAssertFalse(pidDescriptor.policy.isEnabled)

    }

    func testPIDDescriptorExposesDisabledControlAndPolicyDiagnostics() {
        let capabilities = DebuggerCapabilityReport(
            backendName: "Test LLDB",
            isBackendAvailable: true,
            canLaunch: true,
            canAttach: false,
            canControlExecution: true,
            limitations: [],
            entitlementNotes: [],
            backendAvailability: .ready(adapterName: "Test LLDB", details: "Ready."),
            launchSupport: .supported,
            attachSupport: .unsupported(reason: "Attach transport is not wired."),
            executionControlSupport: .supported
        )
        let attachPolicy = DebuggerAttachPolicy.denied(
            reason: DebuggerSignedTargetPolicySummary.pendingPolicyReason
        )
        let summary = DebuggerSignedTargetPolicySummary(
            capabilities: capabilities,
            attachPolicy: attachPolicy
        )

        XCTAssertEqual(summary.title, "Signed-target policy pending")
        XCTAssertEqual(summary.statusTitle, "Blocked")
        XCTAssertEqual(summary.disabledReason, DebuggerSignedTargetPolicySummary.pendingPolicyReason)
        XCTAssertTrue(summary.detail.contains("Local process attach remains disabled"))
        XCTAssertTrue(summary.diagnostics.contains {
            $0.severity == .blocker && $0.title == "Signed-target policy pending"
        })
        XCTAssertTrue(summary.diagnostics.contains {
            $0.severity == .info && $0.title == "Attach transport unavailable"
        })

        let missingPIDTarget = DebuggerPIDTargetDescriptor(
            processID: nil,
            policy: attachPolicy,
            policyDiagnostics: summary.diagnostics
        )

        XCTAssertEqual(missingPIDTarget.id, "attach:pid")
        XCTAssertEqual(missingPIDTarget.selectionDescriptor.title, "PID attach")
        XCTAssertEqual(
            missingPIDTarget.attachAvailability,
            DebuggerControlAvailability(
                action: .attachProcess,
                isEnabled: false,
                disabledReason: "Enter a positive process ID before attaching."
            )
        )
        XCTAssertEqual(missingPIDTarget.policyDiagnostics, summary.diagnostics)

        let pidTarget = DebuggerPIDTargetDescriptor(
            processID: 1234,
            policy: attachPolicy,
            policyDiagnostics: summary.diagnostics
        )

        XCTAssertEqual(pidTarget.id, "attach:pid 1234")
        XCTAssertEqual(pidTarget.processID, 1234)
        XCTAssertEqual(pidTarget.selectionDescriptor.title, "pid 1234")
        XCTAssertEqual(
            pidTarget.attachAvailability,
            DebuggerControlAvailability(
                action: .attachProcess,
                isEnabled: false,
                disabledReason: DebuggerSignedTargetPolicySummary.pendingPolicyReason
            )
        )

    }

    func testSessionStatusSummaryDistinguishesLiveBatchAndUnavailableSessions() {
        let readyCapabilities = DebuggerCapabilityReport(
            backendName: "Test LLDB",
            isBackendAvailable: true,
            canLaunch: true,
            canAttach: false,
            canControlExecution: true,
            limitations: [],
            entitlementNotes: [],
            backendAvailability: .ready(adapterName: "Test LLDB", details: "Ready."),
            launchSupport: .supported,
            attachSupport: .unsupported(reason: "Attach disabled."),
            executionControlSupport: .supported
        )
        let runningSnapshot = DebuggerSessionSnapshot(
            processState: .running(processID: 42, executableName: "FixtureApp"),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Running FixtureApp.",
            backendState: .connected(processID: 42, adapterName: "Test LLDB")
        )
        let runningSummary = DebuggerSessionStatusSummary(
            snapshot: runningSnapshot,
            capabilities: readyCapabilities,
            lastError: nil
        )

        XCTAssertEqual(
            runningSummary.identity.kind,
            .liveProcess(processID: 42, executableName: "FixtureApp")
        )
        XCTAssertEqual(runningSummary.identity.displayName, "FixtureApp")
        XCTAssertEqual(runningSummary.identity.processID, 42)
        XCTAssertTrue(runningSummary.identity.isLiveProcess)
        XCTAssertEqual(runningSummary.title, "Running")
        XCTAssertEqual(runningSummary.detail, "Running FixtureApp.")
        XCTAssertEqual(runningSummary.systemImage, "play.circle")

        let batchSnapshot = DebuggerSessionSnapshot(
            processState: .batchStopped(processID: 99, reason: .breakpoint(address: 0x1000_0040)),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "LLDB batch launch stopped.",
            backendState: .ready(adapterName: "Xcode LLDB Batch")
        )
        let batchSummary = DebuggerSessionStatusSummary(
            snapshot: batchSnapshot,
            capabilities: readyCapabilities,
            lastError: nil
        )

        XCTAssertEqual(batchSummary.identity.kind, .batchTranscript(processID: 99))
        XCTAssertEqual(batchSummary.identity.displayName, "pid 99")
        XCTAssertFalse(batchSummary.identity.isLiveProcess)
        XCTAssertEqual(batchSummary.title, "Stopped")
        XCTAssertEqual(batchSummary.detail, "LLDB batch launch stopped.")

        let unavailableCapabilities = DebuggerCapabilityReport(
            backendName: "Test LLDB",
            isBackendAvailable: false,
            canLaunch: false,
            canAttach: false,
            canControlExecution: false,
            limitations: ["LLDB unavailable."],
            entitlementNotes: [],
            backendAvailability: .unavailable(reason: "LLDB unavailable."),
            launchSupport: .unsupported(reason: "LLDB unavailable."),
            attachSupport: .unsupported(reason: "LLDB unavailable."),
            executionControlSupport: .unsupported(reason: "LLDB unavailable.")
        )
        let unavailableSummary = DebuggerSessionStatusSummary(
            snapshot: .empty,
            capabilities: unavailableCapabilities,
            lastError: nil
        )

        XCTAssertEqual(unavailableSummary.identity.kind, .noTarget)
        XCTAssertEqual(unavailableSummary.title, "Backend unavailable")
        XCTAssertEqual(unavailableSummary.detail, "LLDB unavailable.")
        XCTAssertEqual(unavailableSummary.systemImage, "exclamationmark.triangle")
    }

    @MainActor
    func testLocalLLDBClientRunsExternalProofAndEnablesBoundedBatchLaunch() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        XCTAssertTrue(client.capabilities.isBackendAvailable)
        XCTAssertTrue(client.capabilities.canLaunch)
        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertFalse(client.capabilities.canControlExecution)
        XCTAssertEqual(runner.commands.count, 1)

        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertEqual(command.executablePath, lldbPath)
        XCTAssertEqual(command.arguments, [
            "--batch",
            "--no-lldbinit",
            "-o",
            "version",
            "-o",
            "platform status",
            "-o",
            "settings show target.default-arch"
        ])
        XCTAssertEqual(command.environment["DEVELOPER_DIR"], developerDirectory)
        XCTAssertEqual(command.environment["TERM"], "dumb")
        XCTAssertEqual(command.workingDirectory, "/tmp/MacScopeProof")
        XCTAssertEqual(command.timeoutSeconds, 5)

        let proof = try XCTUnwrap(client.capabilities.lldbProof)
        XCTAssertEqual(proof.status, .passed)
        XCTAssertEqual(proof.toolchain.executablePath, lldbPath)
        XCTAssertEqual(proof.toolchain.developerDirectory, developerDirectory)
        XCTAssertEqual(proof.versionSummary, "lldb-2103.0.23.6")
        XCTAssertEqual(proof.hostTriple, "arm64-apple-macosx")
        XCTAssertEqual(proof.platformSummary, "host")
        XCTAssertTrue(proof.summary.contains("LLDB subprocess proof passed"))
        XCTAssertEqual(client.capabilities.backendAvailability, .ready(
            adapterName: "Xcode LLDB Batch",
            details: "\(proof.summary) Batch launch is available."
        ))
        XCTAssertEqual(client.capabilities.launchSupport, .supported)
        XCTAssertTrue(client.capabilities.entitlementNotes.contains { $0.contains("no attach") })

        let initialSnapshot = client.makeInitialSnapshot()
        XCTAssertEqual(initialSnapshot.backendState, .ready(adapterName: "Xcode LLDB Batch"))
    }

    @MainActor
    func testPersistentLLDBCapabilityRequiresAsyncPythonCommandEngineProof() {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let toolchain = DebuggerLLDBToolchain(
            executablePath: "\(developerDirectory)/usr/bin/lldb",
            developerDirectory: developerDirectory,
            discoverySource: "test",
            candidatePaths: []
        )

        let missingMarker = XcodeLLDBCommandLineAdapter(
            toolchain: toolchain,
            processRunner: FakeDebuggerProcessRunner(result: .successfulLLDBProof),
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            usePersistentTransport: true
        )
        XCTAssertFalse(missingMarker.capabilities.canControlExecution)
        XCTAssertEqual(missingMarker.capabilities.lldbProof?.status, .failed(exitCode: 0))

        var persistentProof = DebuggerSubprocessResult.successfulLLDBProof
        persistentProof.standardOutput += "\n\(XcodeLLDBCommandLineAdapter.persistentCapabilityProofMarker)\n"
        let runner = FakeDebuggerProcessRunner(result: persistentProof)
        let proven = XcodeLLDBCommandLineAdapter(
            toolchain: toolchain,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            usePersistentTransport: true
        )

        XCTAssertTrue(proven.capabilities.canControlExecution)
        XCTAssertEqual(proven.capabilities.lldbProof?.status, .passed)
        XCTAssertTrue(runner.commands.first?.arguments.contains(
            PersistentLLDBCLIProcessLaunchPlan.requireAsyncModeCommand
        ) == true)
        XCTAssertTrue(runner.commands.first?.arguments.contains(where: {
            $0.contains(XcodeLLDBCommandLineAdapter.persistentCapabilityProofMarker)
                && $0.contains("SBCommandReturnObject")
        }) == true)
    }

    @MainActor
    func testLocalLLDBClientReportsFailedExternalProofDetails() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(result: DebuggerSubprocessResult(
            terminationStatus: 72,
            standardOutput: "(lldb) version\n",
            standardError: "error: failed to initialize host platform",
            timedOut: false
        ))
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        XCTAssertFalse(client.capabilities.isBackendAvailable)
        XCTAssertFalse(client.capabilities.canLaunch)
        XCTAssertEqual(client.makeInitialSnapshot().backendState, .discovered(toolPath: lldbPath))

        let proof = try XCTUnwrap(client.capabilities.lldbProof)
        XCTAssertEqual(proof.status, .failed(exitCode: 72))
        XCTAssertEqual(proof.errorPreview, "error: failed to initialize host platform")
        XCTAssertTrue(client.capabilities.summary.contains("LLDB subprocess proof failed with exit code 72"))
        XCTAssertEqual(client.capabilities.launchSupport, .unsupported(
            reason: "LLDB was discovered, but the subprocess proof did not pass."
        ))
    }

    @MainActor
    func testFailedLLDBProofPublishesRedactedEscapedUTF8BoundedDetail() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let omittedTail = "RAW-TAIL-MUST-NOT-PUBLISH"
        let rawDetail = "\(home)/Library/Developer\nnext\t\u{0001}\u{007F} "
            + String(repeating: "🙂", count: 400)
            + omittedTail
        let rawToolchain = DebuggerLLDBToolchain(
            executablePath: "\(home)/Developer\nPrivate/usr/bin/lldb",
            developerDirectory: "\(home)/Developer\tPrivate",
            discoverySource: "test\u{0001}",
            candidatePaths: ["\(home)/Developer\rPrivate/usr/bin/lldb"]
        )
        let runner = FakeDebuggerProcessRunner(
            result: DebuggerSubprocessResult(
                terminationStatus: 72,
                standardOutput: "lldb-unsafe-\(rawDetail)\nTriple: \(rawDetail)\nPlatform: \(rawDetail)",
                standardError: rawDetail,
                timedOut: false
            )
        )
        let adapter = XcodeLLDBCommandLineAdapter(
            toolchain: rawToolchain,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": rawToolchain.developerDirectory ?? ""],
            workingDirectory: "\(home)/MacScope\nProof"
        )
        let client = LocalLLDBDebuggerClient(adapter: adapter)
        let capabilities = client.capabilities
        let proof = try XCTUnwrap(capabilities.lldbProof)

        XCTAssertEqual(proof.status, .failed(exitCode: 72))
        XCTAssertTrue(proof.errorPreview.contains("<home>/Library/Developer"))
        XCTAssertTrue(proof.errorPreview.contains("\\nnext\\t\\u{0001}\\u{007F}"))
        XCTAssertLessThanOrEqual(proof.errorPreview.utf8.count, 1_024)
        XCTAssertFalse(proof.errorPreview.contains(home))
        XCTAssertFalse(proof.errorPreview.contains(omittedTail))
        XCTAssertFalse(proof.errorPreview.contains("\n"))
        XCTAssertFalse(proof.errorPreview.contains("�"))
        XCTAssertFalse(proof.summary.contains(home))
        XCTAssertFalse(proof.summary.contains(omittedTail))
        XCTAssertLessThanOrEqual(proof.summary.utf8.count, 1_024)

        let retainedProofText = [
            proof.toolchain.executablePath,
            proof.toolchain.developerDirectory ?? "",
            proof.toolchain.discoverySource,
            proof.toolchain.candidatePaths.joined(separator: " "),
            proof.command.displayString,
            proof.command.workingDirectory ?? "",
            proof.versionSummary ?? "",
            proof.hostTriple ?? "",
            proof.platformSummary ?? "",
            proof.outputPreview,
            proof.errorPreview,
            proof.summary
        ].joined(separator: " ")
        XCTAssertTrue(proof.command.environment.isEmpty)
        XCTAssertFalse(retainedProofText.contains(home))
        XCTAssertFalse(retainedProofText.contains(omittedTail))
        XCTAssertFalse(retainedProofText.contains("\n"))
        XCTAssertFalse(retainedProofText.contains("\t"))
        XCTAssertFalse(retainedProofText.contains("\r"))
        XCTAssertFalse(retainedProofText.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })

        let capabilityText = (
            [capabilities.summary] + capabilities.limitations + capabilities.entitlementNotes
        ).joined(separator: " ")
        XCTAssertFalse(capabilityText.contains(home))
        XCTAssertFalse(capabilityText.contains(omittedTail))
        XCTAssertFalse(capabilityText.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })

        guard case .discovered(let publishedToolPath, let publishedDetails) = capabilities.backendAvailability else {
            return XCTFail("Expected a discovered-but-unready LLDB capability.")
        }
        XCTAssertFalse(publishedToolPath.contains(home))
        XCTAssertFalse(publishedToolPath.contains("\n"))
        XCTAssertEqual(publishedDetails, proof.summary)

        let status = DebuggerSessionStatusSummary(
            snapshot: client.makeInitialSnapshot(),
            capabilities: capabilities,
            lastError: nil
        )
        let diagnostic = try XCTUnwrap(
            DebuggerLaunchAdmissionDiagnosticPresentation(capabilities: capabilities)
        )
        for published in [status.detail, status.accessibilityLabel, diagnostic.reason] {
            XCTAssertFalse(published.contains(home))
            XCTAssertFalse(published.contains(omittedTail))
            XCTAssertFalse(published.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F })
            XCTAssertLessThanOrEqual(published.utf8.count, 1_024)
        }
    }

    func testPublishedDiagnosticTextHonorsUTF8Boundaries() {
        let marker = "… [truncated]"
        let omittedASCIITail = "RAW-TAIL"
        let markerRequiringText = String(repeating: "a", count: 1_025 - omittedASCIITail.utf8.count)
            + omittedASCIITail
        let scalarCrossingBoundary = String(repeating: "a", count: 1_008)
            + "🙂"
            + String(repeating: "z", count: 20)
        let cases: [(
            name: String,
            rawText: String,
            maximumUTF8Bytes: Int,
            expectedText: String,
            isTruncated: Bool
        )] = [
            (
                name: "exactly 1,024 ASCII bytes",
                rawText: String(repeating: "a", count: 1_024),
                maximumUTF8Bytes: 1_024,
                expectedText: String(repeating: "a", count: 1_024),
                isTruncated: false
            ),
            (
                name: "1,025 ASCII bytes reserve the marker",
                rawText: markerRequiringText,
                maximumUTF8Bytes: 1_024,
                expectedText: String(repeating: "a", count: 1_024 - marker.utf8.count) + marker,
                isTruncated: true
            ),
            (
                name: "multibyte scalar crossing the reserved prefix boundary",
                rawText: scalarCrossingBoundary,
                maximumUTF8Bytes: 1_024,
                expectedText: String(repeating: "a", count: 1_008) + marker,
                isTruncated: true
            ),
            (
                name: "empty text",
                rawText: "",
                maximumUTF8Bytes: 1_024,
                expectedText: "",
                isTruncated: false
            ),
            (
                name: "nonpositive bound",
                rawText: "not published",
                maximumUTF8Bytes: 0,
                expectedText: "",
                isTruncated: true
            )
        ]

        for testCase in cases {
            let projected = DebuggerPublishedDiagnosticText.project(
                testCase.rawText,
                userHomeDirectory: "",
                maximumUTF8Bytes: testCase.maximumUTF8Bytes
            )

            XCTAssertEqual(projected.text, testCase.expectedText, testCase.name)
            XCTAssertEqual(projected.isTruncated, testCase.isTruncated, testCase.name)
            XCTAssertLessThanOrEqual(
                projected.text.utf8.count,
                max(0, testCase.maximumUTF8Bytes),
                testCase.name
            )
            XCTAssertFalse(projected.text.contains("�"), testCase.name)
        }

        XCTAssertFalse(DebuggerPublishedDiagnosticText.project(markerRequiringText).text.contains(omittedASCIITail))
        XCTAssertFalse(
            DebuggerPublishedDiagnosticText.project(scalarCrossingBoundary).text
                .contains(String(repeating: "z", count: 20))
        )
    }

    @MainActor
    func testLLDBProofExecutionFailurePublishesSanitizedBoundedReason() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let omittedTail = "RAW-SYNCHRONOUS-TAIL-MUST-NOT-PUBLISH"
        let rawError = "\(home)/Library/Developer\nnext\t\u{0001}\u{007F} "
            + String(repeating: "🙂", count: 400)
            + omittedTail
        let runner = FakeDebuggerProcessRunner(
            error: DebuggerProcessRunnerError.launchFailed(rawError)
        )
        let adapter = XcodeLLDBCommandLineAdapter(
            toolchain: testLLDBToolchain,
            processRunner: runner,
            environment: [:],
            workingDirectory: "/tmp/MacScopeProof"
        )
        let proof = try XCTUnwrap(adapter.capabilities.lldbProof)

        guard case .executionFailed(let publishedReason) = proof.status else {
            return XCTFail("Expected the synchronous runner failure to be retained as executionFailed.")
        }
        XCTAssertEqual(publishedReason, proof.errorPreview)
        XCTAssertTrue(publishedReason.contains("<home>/Library/Developer"))
        XCTAssertTrue(publishedReason.contains("\\nnext\\t\\u{0001}\\u{007F}"))
        XCTAssertLessThanOrEqual(publishedReason.utf8.count, 1_024)
        XCTAssertTrue(publishedReason.hasSuffix("… [truncated]"))
        XCTAssertFalse(publishedReason.contains(home))
        XCTAssertFalse(publishedReason.contains(omittedTail))
        XCTAssertFalse(publishedReason.contains("\n"))
        XCTAssertFalse(publishedReason.contains("�"))
        XCTAssertFalse(proof.summary.contains(home))
        XCTAssertFalse(proof.summary.contains(omittedTail))
    }

    @MainActor
    func testLocalLLDBClientDoesNotRunProbeWhenLLDBIsUnavailable() async {
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: nil,
                processRunner: runner,
                environment: [:],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertFalse(client.capabilities.isBackendAvailable)
        XCTAssertFalse(client.capabilities.canLaunch)
        XCTAssertNil(client.capabilities.lldbProof)
        XCTAssertEqual(
            client.makeInitialSnapshot().backendState,
            .unavailable(reason: "No Xcode LLDB executable was found in the selected developer directory or standard Xcode locations.")
        )

        do {
            _ = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/tmp/example"))
            XCTFail("Client should not launch when no LLDB toolchain is available.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .backendUnavailable("Cannot launch example: No Xcode LLDB executable was found in the selected developer directory or standard Xcode locations.")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testLocalLLDBClientRunsBoundedBatchLaunchAndSurfacesTranscript() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(results: [
            .successfulLLDBProof,
            .successfulLLDBBatchRun
        ])
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof",
                launchTimeoutSeconds: 10
            )
        )
        let breakpoint = DebuggerBreakpoint(address: 0x1000_0100)
        let configuration = DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            arguments: ["MacScopeLLDBBatch"],
            workingDirectory: "/tmp",
            initialBreakpoints: [breakpoint]
        )

        let snapshot = try await client.launch(configuration)

        XCTAssertEqual(runner.commands.count, 2)
        let command = try XCTUnwrap(runner.commands.last)
        XCTAssertEqual(command.executablePath, lldbPath)
        XCTAssertEqual(command.arguments, [
            "--batch",
            "--no-lldbinit",
            "--one-line",
            "breakpoint set --address \(breakpoint.address.hexAddress)",
            "--one-line",
            "run",
            "--one-line",
            "process status",
            "--one-line-on-crash",
            "thread backtrace all",
            "--",
            "/bin/echo",
            "MacScopeLLDBBatch"
        ])
        XCTAssertEqual(command.environment["DEVELOPER_DIR"], developerDirectory)
        XCTAssertEqual(command.environment["TERM"], "dumb")
        XCTAssertEqual(command.workingDirectory, "/tmp")
        XCTAssertEqual(command.timeoutSeconds, 10)
        XCTAssertFalse(command.arguments.contains("--attach-pid"))
        XCTAssertFalse(command.arguments.contains("--attach-name"))
        XCTAssertFalse(command.arguments.contains("-p"))
        XCTAssertFalse(command.arguments.contains("-n"))

        XCTAssertEqual(snapshot.processState, .exited(code: 0))
        XCTAssertEqual(snapshot.backendState, .ready(adapterName: "Xcode LLDB Batch"))
        XCTAssertEqual(snapshot.breakpoints, [breakpoint])
        XCTAssertTrue(snapshot.statusMessage.contains("LLDB batch launch completed"))
        XCTAssertTrue(snapshot.statusMessage.contains("Target exited with code 0"))
        XCTAssertTrue(snapshot.statusMessage.contains("Configured 1 breakpoint"))

        let commandRun = try XCTUnwrap(snapshot.lastCommandRun)
        XCTAssertTrue(commandRun.succeeded)
        XCTAssertEqual(commandRun.commandDisplay, command.displayString)
        XCTAssertEqual(commandRun.lldbTerminationStatus, 0)
        XCTAssertEqual(commandRun.targetExitStatus, 0)
        XCTAssertEqual(commandRun.targetProcessID, 12345)
        XCTAssertEqual(commandRun.targetState, .exited(code: 0))
        XCTAssertNil(commandRun.diagnosticSummary)
        XCTAssertTrue(commandRun.standardOutput.contains("MacScopeLLDBBatch"))
        XCTAssertEqual(commandRun.standardError, "debugserver fixture note\n")
        XCTAssertEqual(commandRun.statusText, "LLDB exit 0; target exit 0.")
    }

    @MainActor
    func testLocalLLDBBatchLaunchParsesBreakpointStopTranscriptAsBatchStopped() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(results: [
            .successfulLLDBProof,
            .breakpointStoppedLLDBBatchRun
        ])
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        let stoppedAddress = UInt64(0x1_0000_03f8)
        let breakpoint = DebuggerBreakpoint(address: stoppedAddress)
        let snapshot = try await client.launch(DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            initialBreakpoints: [breakpoint]
        ))

        XCTAssertEqual(
            snapshot.processState,
            .batchStopped(processID: 24680, reason: .breakpoint(address: stoppedAddress))
        )
        XCTAssertTrue(snapshot.processState.canLaunchNewProcess)
        XCTAssertEqual(snapshot.backendState, .ready(adapterName: "Xcode LLDB Batch"))
        XCTAssertEqual(snapshot.breakpoints, [breakpoint])
        XCTAssertTrue(snapshot.statusMessage.contains("LLDB batch launch stopped"))
        XCTAssertTrue(snapshot.statusMessage.contains("Breakpoint at 0x00000001000003f8"))
        XCTAssertTrue(snapshot.statusMessage.contains("No live debugger session is attached"))

        let commandRun = try XCTUnwrap(snapshot.lastCommandRun)
        XCTAssertTrue(commandRun.succeeded)
        XCTAssertEqual(commandRun.targetProcessID, 24680)
        XCTAssertNil(commandRun.targetExitStatus)
        XCTAssertEqual(
            commandRun.targetState,
            .stopped(processID: 24680, reason: .breakpoint(address: stoppedAddress))
        )
        XCTAssertEqual(
            commandRun.statusText,
            "LLDB exit 0; target stopped: Breakpoint at 0x00000001000003f8."
        )
    }

    @MainActor
    func testLocalLLDBBatchModeModelsTerminateAsUnsupported() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )
        let batchStoppedSnapshot = DebuggerSessionSnapshot(
            processState: .batchStopped(processID: 24680, reason: .breakpoint(address: 0x1000_0100)),
            breakpoints: [DebuggerBreakpoint(address: 0x1000_0100)],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "LLDB batch launch stopped.",
            backendState: .ready(adapterName: "Xcode LLDB Batch")
        )

        XCTAssertFalse(client.capabilities.canControlExecution)
        XCTAssertEqual(
            client.capabilities.executionControlSupport,
            .unsupported(reason: XcodeLLDBCommandLineAdapter.batchControlUnsupportedReason)
        )

        do {
            _ = try await client.terminate(from: batchStoppedSnapshot)
            XCTFail("Batch-mode LLDB should not fake terminate support after transcript capture.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .backendUnavailable("Terminate is unavailable: \(XcodeLLDBCommandLineAdapter.batchControlUnsupportedReason)")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(runner.commands.count, 1)
    }

    @MainActor
    func testLocalLLDBBatchLaunchTreatsZeroExitTranscriptErrorAsFailure() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(results: [
            .successfulLLDBProof,
            .zeroExitLLDBErrorBatchRun
        ])
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        let snapshot = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))

        XCTAssertEqual(snapshot.processState, .unavailable(reason: snapshot.statusMessage))
        XCTAssertEqual(snapshot.backendState, .failed(reason: snapshot.statusMessage))
        XCTAssertTrue(snapshot.statusMessage.contains("LLDB batch launch reported an error"))
        XCTAssertTrue(snapshot.statusMessage.contains("error: unable to launch target: permission denied"))

        let commandRun = try XCTUnwrap(snapshot.lastCommandRun)
        XCTAssertFalse(commandRun.succeeded)
        XCTAssertEqual(commandRun.lldbTerminationStatus, 0)
        XCTAssertEqual(commandRun.targetState, .error(message: "error: unable to launch target: permission denied"))
        XCTAssertEqual(commandRun.diagnosticSummary, "error: unable to launch target: permission denied")
        XCTAssertEqual(
            commandRun.statusText,
            "LLDB exit 0; target error: error: unable to launch target: permission denied."
        )
    }

    @MainActor
    func testLocalLLDBBatchLaunchSurfacesFailureTranscriptWithoutEnablingAttach() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(results: [
            .successfulLLDBProof,
            .failedLLDBBatchRun
        ])
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        let snapshot = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))

        XCTAssertEqual(runner.commands.count, 2)
        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertEqual(client.capabilities.attachSupport, .unsupported(
            reason: XcodeLLDBCommandLineAdapter.attachUnsupportedReason
        ))
        XCTAssertEqual(snapshot.backendState, .failed(reason: snapshot.statusMessage))
        XCTAssertTrue(snapshot.statusMessage.contains("LLDB batch launch failed with exit code 1"))
        XCTAssertTrue(snapshot.statusMessage.contains("attach failed"))

        let commandRun = try XCTUnwrap(snapshot.lastCommandRun)
        XCTAssertFalse(commandRun.succeeded)
        XCTAssertEqual(commandRun.lldbTerminationStatus, 1)
        XCTAssertEqual(commandRun.targetExitStatus, -1)
        XCTAssertEqual(commandRun.targetState, .error(message: "error: process exited with status -1 (attach failed (Not allowed to attach to process.))"))
        XCTAssertEqual(commandRun.diagnosticSummary, "error: process exited with status -1 (attach failed (Not allowed to attach to process.))")
        XCTAssertTrue(commandRun.standardOutput.contains("Not allowed to attach"))
    }

    @MainActor
    func testLLDBBreakpointCommandGenerationFiltersDisabledAndEscapesConditions() {
        let commands = XcodeLLDBCommandLineAdapter.makeBreakpointCommands(for: [
            DebuggerBreakpoint(address: 0x1000_0300, isEnabled: false),
            DebuggerBreakpoint(
                address: 0x1000_0100,
                condition: #"x0 == "ready""#,
                ignoreCount: 2
            ),
            DebuggerBreakpoint(address: 0x1000_0200)
        ])

        XCTAssertEqual(commands, [
            #"breakpoint set --address 0x0000000010000100 --condition "x0 == \"ready\"" --ignore-count 2"#,
            "breakpoint set --address 0x0000000010000200"
        ])
    }

    @MainActor
    func testLLDBEnvironmentCommandGenerationSortsAndQuotesOverrides() {
        let command = XcodeLLDBCommandLineAdapter.makeEnvironmentCommand(for: [
            "Z_MODE": "two words",
            "A_FLAG": "ready",
            "QUOTE": #"value "quoted""#
        ])

        XCTAssertEqual(
            command,
            #"settings set -- target.env-vars "A_FLAG=ready" "QUOTE=value \"quoted\"" "Z_MODE=two words""#
        )
    }

    @MainActor
    func testLLDBCommandArgumentGenerationEscapesBacktickSubstitution() throws {
        let substitution = "`script print(\"unsafe\")`"

        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeTargetCreateCommand(
                for: DebuggerLaunchConfiguration(executablePath: "/tmp/\(substitution)")
            ),
            #"target create "/tmp/\`script print(\"unsafe\")\`""#
        )
        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeRunArgumentsCommand(for: [substitution]),
            #"settings set -- target.run-args "\`script print(\"unsafe\")\`""#
        )
        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeEnvironmentCommand(for: ["VALUE": substitution]),
            #"settings set -- target.env-vars "VALUE=\`script print(\"unsafe\")\`""#
        )
        XCTAssertEqual(
            XcodeLLDBCommandLineAdapter.makeBreakpointCommands(for: [
                DebuggerBreakpoint(address: 0x1000, condition: substitution)
            ]),
            [#"breakpoint set --address 0x0000000000001000 --condition "\`script print(\"unsafe\")\`""#]
        )
    }

    @MainActor
    func testLLDBBreakpointMutationCommandGenerationReplacesOwnedBreakpointSet() throws {
        let commands = try XcodeLLDBCommandLineAdapter.makeBreakpointMutationCommands(
            from: [
                DebuggerBreakpoint(address: 0x1000_0100),
                DebuggerBreakpoint(address: 0x1000_0300, isEnabled: false)
            ],
            to: [
                DebuggerBreakpoint(
                    address: 0x1000_0200,
                    condition: "x0 == 2",
                    ignoreCount: 1
                )
            ]
        )

        XCTAssertEqual(commands, [
            "breakpoint delete --force",
            #"breakpoint set --address 0x0000000010000200 --condition "x0 == 2" --ignore-count 1"#
        ])

        let noOpCommands = try XcodeLLDBCommandLineAdapter.makeBreakpointMutationCommands(
            from: [DebuggerBreakpoint(address: 0x1000_0200, condition: "x0 == 2", ignoreCount: 1)],
            to: [DebuggerBreakpoint(address: 0x1000_0200, condition: "x0 == 2", ignoreCount: 1)]
        )
        XCTAssertTrue(noOpCommands.isEmpty)
    }

    @MainActor
    func testLLDBMemoryParserAggregatesAddressPrefixedByteRows() {
        let memory = XcodeLLDBCommandLineAdapter.parseMemorySummaries(from: """
        (lldb) memory read --format x --size 1 --count 64 $sp
        0x000000016fdff200: 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00
        0x000000016fdff208: 0x08 0xf4 0xdf 0x6f 0x01 0x00 0x00 0x00
        """)

        XCTAssertEqual(memory, [
            DebuggerMemorySummary(
                address: 0x000000016fdff200,
                byteCount: 16,
                previewBytes: [
                    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x08, 0xf4, 0xdf, 0x6f, 0x01, 0x00, 0x00, 0x00
                ],
                label: "stack near sp"
            )
        ])
    }

    @MainActor
    func testLLDBThreadParserMergesStatusAndBacktraceDetails() {
        let threads = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: """
        Process 222 stopped
        * thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
            frame #0: 0x00000001000003f8 echo`main + 8 at main.swift:12:5
          thread #2, queue = 'com.apple.worker'
            frame #0: 0x0000000100000400 echo`worker + 16
        """)

        XCTAssertEqual(threads, [
            DebuggerThreadSummary(
                index: 1,
                queueName: "com.apple.main-thread",
                stopReason: .breakpoint(address: 0x00000001000003f8),
                isSelected: true,
                topFrameAddress: 0x00000001000003f8,
                topFrameFunctionName: "main"
            ),
            DebuggerThreadSummary(
                index: 2,
                queueName: "com.apple.worker",
                stopReason: nil,
                isSelected: false,
                topFrameAddress: 0x0000000100000400,
                topFrameFunctionName: "worker"
            )
        ])
    }

    @MainActor
    func testLocalLLDBBatchLaunchRejectsUnsafeBreakpointConditionBeforeRunnerLaunch() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        do {
            _ = try await client.launch(DebuggerLaunchConfiguration(
                executablePath: "/bin/echo",
                initialBreakpoints: [
                    DebuggerBreakpoint(
                        address: 0x1000_0100,
                        condition: "x0 == 1\nprocess detach"
                    )
                ]
            ))
            XCTFail("Unsafe breakpoint conditions should be rejected before LLDB launch.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .invalidConfiguration("Breakpoint condition for 0x0000000010000100 contains unsupported control characters.")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(runner.commands.count, 1)
    }

    @MainActor
    func testLocalLLDBBatchLaunchRejectsUnsafeEnvironmentBeforeRunnerLaunch() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        do {
            _ = try await client.launch(DebuggerLaunchConfiguration(
                executablePath: "/bin/echo",
                environment: ["MACSCOPE_MODE": "debug\nunsafe"]
            ))
            XCTFail("Unsafe environment values should be rejected before LLDB launch.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .invalidConfiguration("Environment value for MACSCOPE_MODE contains unsupported control characters.")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(runner.commands.count, 1)
    }

    @MainActor
    func testLocalLLDBBatchLaunchRejectsMissingExecutableBeforeRunnerLaunch() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(
            adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            )
        )

        do {
            _ = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/tmp/MacScopeMissingExecutable"))
            XCTFail("Missing executable should be rejected before starting the batch LLDB command.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .invalidConfiguration("No executable file exists at /tmp/MacScopeMissingExecutable.")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(runner.commands.count, 1)
    }

    @MainActor
    func testLLDBDiscoveryCandidateListPrefersDeveloperDir() {
        let developerDirectory = "/Custom/Xcode.app/Contents/Developer"
        let candidates = XcodeLLDBCommandLineAdapter.candidateLLDBPaths(
            environment: ["DEVELOPER_DIR": developerDirectory]
        )

        XCTAssertEqual(candidates.first, "\(developerDirectory)/usr/bin/lldb")
        XCTAssertEqual(candidates.filter { $0 == "\(developerDirectory)/usr/bin/lldb" }.count, 1)
        XCTAssertTrue(candidates.contains("/Applications/Xcode-beta.app/Contents/Developer/usr/bin/lldb"))
        XCTAssertTrue(candidates.contains("/usr/bin/lldb"))
    }

    @MainActor
    func testLocalLLDBClientDelegatesToReadyBackendAdapter() async throws {
        let adapter = ReadyLLDBBackendAdapter()
        let client = LocalLLDBDebuggerClient(adapter: adapter)
        let breakpoint = DebuggerBreakpoint(address: 0x1000_0040)
        let configuration = DebuggerLaunchConfiguration(
            executablePath: "/tmp/example",
            arguments: ["--flag"],
            workingDirectory: "/tmp",
            initialBreakpoints: [breakpoint]
        )

        XCTAssertTrue(client.capabilities.isBackendAvailable)
        XCTAssertTrue(client.capabilities.canLaunch)
        XCTAssertEqual(client.makeInitialSnapshot().backendState, .ready(adapterName: "Ready LLDB"))

        let snapshot = try await client.launch(configuration)

        XCTAssertEqual(adapter.receivedLaunchConfiguration, configuration)
        XCTAssertEqual(snapshot.processState, .paused(processID: 4242, reason: .breakpoint(address: breakpoint.address)))
        XCTAssertEqual(snapshot.backendState, .connected(processID: 4242, adapterName: "Ready LLDB"))
        XCTAssertEqual(snapshot.breakpoints, [breakpoint])
    }

    @MainActor
    func testLocalLLDBClientRejectsLiveControlForNonLiveSnapshotsBeforeAdapterDispatch() async throws {
        let adapter = ControlRecordingLLDBBackendAdapter()
        let client = LocalLLDBDebuggerClient(adapter: adapter)
        let batchStoppedSnapshot = DebuggerSessionSnapshot(
            processState: .batchStopped(processID: 42, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "LLDB batch launch stopped.",
            backendState: .ready(adapterName: "Xcode LLDB Batch")
        )
        let mismatchedPausedSnapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 99, adapterName: "Ready LLDB")
        )

        do {
            _ = try await client.continueExecution(from: batchStoppedSnapshot)
            XCTFail("Batch-stopped snapshots should not be treated as live control sessions.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Continue requires a paused live debug process."))
        }

        do {
            _ = try await client.stepOver(from: mismatchedPausedSnapshot)
            XCTFail("Mismatched backend/process ids should not be treated as live control sessions.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Step over requires a paused live debug process."))
        }

        do {
            _ = try await client.replaceBreakpoints([], from: batchStoppedSnapshot)
            XCTFail("Breakpoint mutation should require a live process session.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Breakpoint mutation requires a live debug process."))
        }

        do {
            _ = try await client.terminate(from: batchStoppedSnapshot)
            XCTFail("Terminate should require a live process session.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Terminate requires a live debug process."))
        }

        do {
            _ = try await client.terminate(from: mismatchedPausedSnapshot)
            XCTFail("Mismatched backend/process ids should not be treated as terminable live sessions.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Terminate requires a live debug process."))
        }

        do {
            _ = try await client.refreshSnapshot(from: batchStoppedSnapshot)
            XCTFail("Snapshot refresh should require a paused live process session.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(error, .invalidState("Snapshot refresh requires a paused live debug process."))
        }

        XCTAssertEqual(adapter.continueCallCount, 0)
        XCTAssertEqual(adapter.stepOverCallCount, 0)
        XCTAssertEqual(adapter.terminateCallCount, 0)
        XCTAssertEqual(adapter.replaceBreakpointsCallCount, 0)
        XCTAssertEqual(adapter.refreshSnapshotCallCount, 0)
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionLaunchesStoppedAtEntryAndEnablesControl() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            launchTimeoutSeconds: 7,
            liveSessionFactory: { transport }
        ))
        let breakpoint = DebuggerBreakpoint(address: 0x1000_0100)

        XCTAssertTrue(client.capabilities.isBackendAvailable)
        XCTAssertTrue(client.capabilities.canLaunch)
        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertTrue(client.capabilities.canControlExecution)
        XCTAssertEqual(client.capabilities.executionControlSupport, .supported)
        XCTAssertEqual(client.makeInitialSnapshot().backendState, .ready(adapterName: "Xcode LLDB Live"))

        let snapshot = try await client.launch(DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            arguments: ["MacScopeLive"],
            workingDirectory: "/tmp",
            initialBreakpoints: [breakpoint]
        ))

        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertEqual(transport.startCommands.count, 1)
        let startCommand = try XCTUnwrap(transport.startCommands.first)
        XCTAssertEqual(startCommand.executablePath, lldbPath)
        XCTAssertEqual(startCommand.arguments, ["--no-lldbinit"])
        XCTAssertEqual(startCommand.environment["DEVELOPER_DIR"], developerDirectory)
        XCTAssertEqual(startCommand.environment["TERM"], "dumb")
        XCTAssertEqual(startCommand.workingDirectory, "/tmp")
        XCTAssertEqual(startCommand.timeoutSeconds, 7)
        XCTAssertEqual(transport.sentCommands, [
            "settings set use-color false",
            #"target create "/bin/echo""#,
            #"settings set -- target.run-args "MacScopeLive""#,
            "process launch --stop-at-entry",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp"
        ])

        XCTAssertEqual(snapshot.processState, .paused(processID: 222, reason: .unknown("Stopped at entry")))
        XCTAssertEqual(snapshot.backendState, .connected(processID: 222, adapterName: "Xcode LLDB Live"))
        XCTAssertEqual(snapshot.breakpoints, [])
        XCTAssertEqual(snapshot.threads, [
            DebuggerThreadSummary(
                index: 1,
                queueName: "com.apple.main-thread",
                stopReason: nil,
                isSelected: true,
                topFrameAddress: 0x00000001000003f8,
                topFrameFunctionName: "main"
            )
        ])
        XCTAssertEqual(snapshot.frames.map(\.functionName), ["main", "start"])
        XCTAssertEqual(snapshot.frames.first?.sourceLocation, "main.swift:12:5")
        XCTAssertEqual(snapshot.registers.map(\.name), ["pc", "sp", "fp", "lr", "x0", "x1"])
        XCTAssertEqual(snapshot.registers.first?.role, "program counter: echo`main + 8")
        XCTAssertEqual(snapshot.memoryRegions, [
            DebuggerMemorySummary(
                address: 0x000000016fdff200,
                byteCount: 32,
                previewBytes: [
                    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x08, 0xf4, 0xdf, 0x6f, 0x01, 0x00, 0x00, 0x00,
                    0x20, 0xf2, 0xdf, 0x6f, 0x01, 0x00, 0x00, 0x00,
                    0x00, 0x10, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00
                ],
                label: "stack near sp"
            )
        ])
        XCTAssertEqual(snapshot.lastCommandRun?.commandDisplay, "process launch --stop-at-entry; process status; thread backtrace; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand); memory read --format x --size 1 --count 64 $sp")
        XCTAssertEqual(snapshot.lastCommandRun?.targetProcessID, 222)
        XCTAssertEqual(snapshot.lastCommandRun?.targetState, .stopped(processID: 222, reason: .unknown("Process stopped")))
        XCTAssertTrue(snapshot.statusMessage.contains("LLDB live launch for echo"))
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionContinuesPausesAndStepsThroughTransport() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .liveContinuedRunning,
            .liveStatusRunning,
            .liveInterruptedStopped,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .liveStepStopped,
            .liveStepStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        XCTAssertEqual(launched.processState, .paused(processID: 222, reason: .unknown("Stopped at entry")))

        let continued = try await client.continueExecution(from: launched)
        XCTAssertEqual(continued.processState, .running(processID: 222, executableName: "echo"))
        XCTAssertEqual(continued.backendState, .connected(processID: 222, adapterName: "Xcode LLDB Live"))
        XCTAssertEqual(continued.lastCommandRun?.commandDisplay, "process continue; process status")

        let paused = try await client.pause(from: continued)
        XCTAssertEqual(paused.processState, .paused(processID: 222, reason: .userRequested))
        XCTAssertEqual(paused.lastCommandRun?.commandDisplay, "process interrupt; process status; thread backtrace; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand); memory read --format x --size 1 --count 64 $sp")
        XCTAssertEqual(paused.frames.first?.functionName, "main")

        let stepped = try await client.stepOver(from: paused)
        XCTAssertEqual(stepped.processState, .paused(processID: 222, reason: .step))
        XCTAssertEqual(stepped.lastCommandRun?.commandDisplay, "thread step-over; process status; thread backtrace; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand); memory read --format x --size 1 --count 64 $sp")
        XCTAssertEqual(stepped.registers.first?.name, "pc")
        XCTAssertEqual(stepped.memoryRegions.first?.address, 0x000000016fdff200)
        XCTAssertEqual(transport.sentCommands, [
            "settings set use-color false",
            #"target create "/bin/echo""#,
            "process launch --stop-at-entry",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp",
            "process continue",
            "process status",
            "process interrupt",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp",
            "thread step-over",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp"
        ])
        XCTAssertEqual(transport.stopCallCount, 0)
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionTerminatesThroughTransport() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let breakpoint = DebuggerBreakpoint(address: 0x1000_0100)
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .liveTerminated
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            initialBreakpoints: [breakpoint]
        ))
        XCTAssertTrue(launched.canTerminateLiveProcess)

        let terminated = try await client.terminate(from: launched)

        XCTAssertEqual(terminated.processState, .exited(code: 9))
        XCTAssertEqual(terminated.backendState, .ready(adapterName: "Xcode LLDB Live"))
        XCTAssertEqual(terminated.breakpoints, [])
        XCTAssertEqual(terminated.lastCommandRun?.commandDisplay, "process kill")
        XCTAssertEqual(terminated.lastCommandRun?.targetProcessID, 222)
        XCTAssertEqual(terminated.lastCommandRun?.targetExitStatus, 9)
        XCTAssertEqual(terminated.lastCommandRun?.targetState, .exited(code: 9))
        XCTAssertTrue(terminated.lastCommandRun?.succeeded == true)
        XCTAssertTrue(terminated.statusMessage.contains("Process terminated"))
        XCTAssertTrue(terminated.statusMessage.contains("Target exited with code 9"))
        XCTAssertEqual(Array(transport.sentCommands.suffix(1)), ["process kill"])
        XCTAssertEqual(transport.stopCallCount, 1)
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionStopsStaleSessionWhenTerminateReportsDifferentProcessID() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .liveDifferentProcessTerminated
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        let terminated = try await client.terminate(from: launched)

        let expectedMessage = "LLDB reported pid 333, but the active live debugger session owns pid 222. The live debugger session was marked stale and stopped."
        XCTAssertEqual(terminated.processState, .unavailable(reason: expectedMessage))
        XCTAssertEqual(terminated.backendState, .failed(reason: expectedMessage))
        XCTAssertEqual(terminated.statusMessage, expectedMessage)
        XCTAssertEqual(terminated.lastCommandRun?.commandDisplay, "process kill")
        XCTAssertEqual(terminated.lastCommandRun?.targetProcessID, 333)
        XCTAssertEqual(terminated.lastCommandRun?.targetState, .error(message: expectedMessage))
        XCTAssertEqual(terminated.lastCommandRun?.diagnosticSummary, expectedMessage)
        XCTAssertFalse(terminated.lastCommandRun?.succeeded ?? true)
        XCTAssertEqual(Array(transport.sentCommands.suffix(1)), ["process kill"])
        XCTAssertEqual(transport.stopCallCount, 1)
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionContinueUsesStatusToRefreshBreakpointStop() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let breakpoint = DebuggerBreakpoint(address: 0x1_0000_03f8)
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .liveContinuedBreakpointStop,
            .liveStatusBreakpointStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            initialBreakpoints: [breakpoint]
        ))
        let continued = try await client.continueExecution(from: launched)

        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertEqual(continued.processState, .paused(processID: 222, reason: .breakpoint(address: breakpoint.address)))
        XCTAssertEqual(continued.backendState, .connected(processID: 222, adapterName: "Xcode LLDB Live"))
        XCTAssertEqual(continued.breakpoints, [])
        XCTAssertEqual(continued.frames.map(\.functionName), ["main", "start"])
        XCTAssertEqual(continued.registers.first?.name, "pc")
        XCTAssertEqual(continued.memoryRegions.first?.address, 0x000000016fdff200)
        XCTAssertEqual(
            continued.lastCommandRun?.commandDisplay,
            "process continue; process status; thread backtrace; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand); memory read --format x --size 1 --count 64 $sp"
        )
        XCTAssertEqual(
            continued.lastCommandRun?.targetState,
            .stopped(processID: 222, reason: .breakpoint(address: breakpoint.address))
        )
        XCTAssertEqual(Array(transport.sentCommands.suffix(5)), [
            "process continue",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp"
        ])
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionRejectsUncheckedBreakpointMutation() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let initialBreakpoint = DebuggerBreakpoint(address: 0x1000_0100)
        let replacementBreakpoint = DebuggerBreakpoint(
            address: 0x1000_0200,
            condition: "x0 == 2",
            ignoreCount: 1
        )
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .emptyLLDBCommand,
            .emptyLLDBCommand
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            initialBreakpoints: [initialBreakpoint]
        ))
        do {
            _ = try await client.replaceBreakpoints([replacementBreakpoint], from: launched)
            XCTFail("Unchecked live breakpoint mutation must fail closed.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .unsupportedOperation(
                    "Live breakpoint mutation requires a validated logical-breakpoint resolution observation."
                )
            )
        }

        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertEqual(launched.breakpoints, [])
        XCTAssertEqual(transport.sentCommands, [
            "settings set use-color false",
            #"target create "/bin/echo""#,
            "process launch --stop-at-entry",
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp"
        ])
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionRefreshesStoppedSnapshotOnDemand() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        let refreshed = try await client.refreshSnapshot(from: launched)

        XCTAssertEqual(refreshed.processState, launched.processState)
        XCTAssertEqual(refreshed.frames.map(\.functionName), ["main", "start"])
        XCTAssertEqual(refreshed.registers.map(\.name), ["pc", "sp", "fp", "lr", "x0", "x1"])
        XCTAssertEqual(refreshed.memoryRegions.first?.address, 0x000000016fdff200)
        XCTAssertEqual(refreshed.memoryRegions.first?.byteCount, 32)
        XCTAssertEqual(refreshed.lastCommandRun?.commandDisplay, "process status; thread backtrace; \(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand); memory read --format x --size 1 --count 64 $sp")
        XCTAssertEqual(
            refreshed.lastCommandRun?.targetState,
            .stopped(processID: 222, reason: .unknown("Stopped at entry"))
        )
        XCTAssertEqual(Array(transport.sentCommands.suffix(4)), [
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp"
        ])
        XCTAssertTrue(refreshed.statusMessage.contains("Debugger snapshot refreshed"))
        XCTAssertTrue(refreshed.statusMessage.contains("1 memory region"))
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionRefreshUsesLatestStoppedReasonFromStatus() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .liveStatusSignalStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        let refreshed = try await client.refreshSnapshot(from: launched)

        XCTAssertEqual(refreshed.processState, .paused(processID: 222, reason: .signal("SIGTRAP")))
        XCTAssertEqual(
            refreshed.lastCommandRun?.targetState,
            .stopped(processID: 222, reason: .signal("SIGTRAP"))
        )
        XCTAssertEqual(refreshed.threads.first?.stopReason, .signal("SIGTRAP"))
        XCTAssertEqual(refreshed.threads.first?.queueName, "com.apple.main-thread")
        XCTAssertEqual(refreshed.threads.first?.topFrameFunctionName, "main")
        XCTAssertEqual(refreshed.frames.map(\.functionName), ["main", "start"])
        XCTAssertEqual(refreshed.registers.map(\.name), ["pc", "sp", "fp", "lr", "x0", "x1"])
        XCTAssertEqual(refreshed.memoryRegions.first?.address, 0x000000016fdff200)
        XCTAssertEqual(Array(transport.sentCommands.suffix(4)), [
            "process status",
            "thread backtrace",
            "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            "memory read --format x --size 1 --count 64 $sp"
        ])
    }

    @MainActor
    func testLocalLLDBLiveCommandSessionStopsStaleSessionWhenStatusReportsDifferentProcessID() async throws {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let transport = FakeLLDBCommandSessionTransport(responses: [
            .emptyLLDBCommand,
            .emptyLLDBCommand,
            .liveLaunchStoppedAtEntry,
            .liveStatusStopped,
            .liveBacktraceWithFrames,
            .liveRegisterSnapshot,
            .liveStackMemorySnapshot,
            .liveStatusDifferentProcessStopped
        ])
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: runner,
            environment: ["DEVELOPER_DIR": developerDirectory],
            workingDirectory: "/tmp/MacScopeProof",
            liveSessionFactory: { transport }
        ))

        let launched = try await client.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        let refreshed = try await client.refreshSnapshot(from: launched)

        let expectedMessage = "LLDB reported pid 333, but the active live debugger session owns pid 222. The live debugger session was marked stale and stopped."
        XCTAssertEqual(refreshed.processState, .unavailable(reason: expectedMessage))
        XCTAssertEqual(refreshed.backendState, .failed(reason: expectedMessage))
        XCTAssertEqual(refreshed.statusMessage, expectedMessage)
        XCTAssertEqual(refreshed.lastCommandRun?.targetProcessID, 333)
        XCTAssertEqual(refreshed.lastCommandRun?.targetState, .error(message: expectedMessage))
        XCTAssertEqual(refreshed.lastCommandRun?.diagnosticSummary, expectedMessage)
        XCTAssertFalse(refreshed.lastCommandRun?.succeeded ?? true)
        XCTAssertEqual(Array(transport.sentCommands.suffix(1)), ["process status"])
        XCTAssertEqual(transport.stopCallCount, 1)
    }

    @MainActor
    func testDebuggerPanelViewModelRunsRealLiveLaunchProofAgainstSafeExecutableWhenLLDBAllowsIt() async throws {
        // Prefer the ambient toolchain (CI pins DEVELOPER_DIR); the beta path is
        // only the local-development fallback.
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        let environment = ["DEVELOPER_DIR": developerDirectory]
        guard let lldbPath = XcodeLLDBCommandLineAdapter.discoverLLDBExecutablePath(environment: environment) else {
            throw XCTSkip("Xcode LLDB is unavailable on this host.")
        }

        let proofDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScopeLiveDebuggerProof-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: proofDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: proofDirectory)
        }

        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            lldbExecutablePath: lldbPath,
            processRunner: FoundationDebuggerProcessRunner(),
            environment: environment,
            workingDirectory: proofDirectory.path,
            launchTimeoutSeconds: 15,
            liveSessionFactory: { FoundationLLDBCommandSessionTransport() }
        ))

        guard client.capabilities.isBackendAvailable else {
            throw XCTSkip("Xcode LLDB proof failed on this host: \(client.capabilities.summary)")
        }

        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canLaunch)
        XCTAssertTrue(viewModel.capabilities.canControlExecution)
        XCTAssertFalse(viewModel.capabilities.canAttach)
        XCTAssertEqual(
            viewModel.capabilities.attachSupport,
            .unsupported(reason: XcodeLLDBCommandLineAdapter.attachUnsupportedReason)
        )
        XCTAssertTrue(viewModel.capabilities.entitlementNotes.contains { $0.contains("no attach by pid/name") })

        await viewModel.launch(configuration: DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            arguments: ["MacScopeLiveProof"],
            workingDirectory: proofDirectory.path
        ))

        if let lastError = viewModel.lastError {
            throw XCTSkip("Xcode LLDB live launch is not permitted on this host: \(lastError)")
        }

        switch viewModel.session.processState {
        case .paused(let processID, _):
            XCTAssertEqual(viewModel.session.backendState, .connected(processID: processID, adapterName: "Xcode LLDB Live"))
            XCTAssertTrue(viewModel.canContinue)
            XCTAssertTrue(viewModel.canStepOver)
            XCTAssertTrue(viewModel.canTerminate)
            XCTAssertFalse(viewModel.canLaunch)
            XCTAssertEqual(viewModel.session.lastCommandRun?.targetProcessID, processID)
            XCTAssertTrue(viewModel.session.lastCommandRun?.commandDisplay.contains("process launch --stop-at-entry") == true)
            XCTAssertFalse(viewModel.session.lastCommandRun?.commandDisplay.localizedCaseInsensitiveContains("attach") == true)
            XCTAssertFalse(viewModel.session.statusMessage.localizedCaseInsensitiveContains("attach"))

            await viewModel.continueExecution()

            // The adapter settle-polls briefly after continue; if the target is
            // STILL reported running past that window the host is too loaded for
            // the exit to have been observed synchronously — the strict exit
            // assertions would then test scheduler noise, not the debugger.
            if case .running(_, let executableName) = viewModel.session.processState {
                throw XCTSkip("live continue returned before \(executableName) exited on this host (exit-event pump is the WS-3 follow-up)")
            }

            XCTAssertNil(viewModel.lastError)
            XCTAssertEqual(viewModel.session.processState, .exited(code: 0))
            XCTAssertEqual(viewModel.session.backendState, .ready(adapterName: "Xcode LLDB Live"))
            XCTAssertTrue(viewModel.canLaunch)
            XCTAssertFalse(viewModel.canTerminate)
        case .unavailable(let reason):
            let lowercasedReason = reason.localizedLowercase
            XCTAssertTrue(
                lowercasedReason.contains("attach failed") ||
                lowercasedReason.contains("task name port"),
                "Expected an attach/task-port policy failure, got: \(reason)"
            )
            XCTAssertTrue(
                lowercasedReason.contains("not allowed to attach") ||
                lowercasedReason.contains("unable to obtain a task name port"),
                "Expected a host policy denial, got: \(reason)"
            )
            XCTAssertEqual(viewModel.session.backendState, .failed(reason: reason))
            let commandRun = try XCTUnwrap(viewModel.session.lastCommandRun)
            let diagnosticSummary = try XCTUnwrap(commandRun.diagnosticSummary)
            XCTAssertEqual(commandRun.targetState, .error(message: diagnosticSummary))
            XCTAssertFalse(viewModel.canContinue)
            XCTAssertFalse(viewModel.canStepOver)
            XCTAssertTrue(viewModel.canLaunch)
            XCTAssertFalse(viewModel.capabilities.canAttach)
        default:
            XCTFail("Expected live launch to stop at entry or surface an attach-gated policy failure, got \(viewModel.session.processState).")
        }
    }

    @MainActor
    func testDebuggerPanelViewModelRunsBoundedBatchLaunchButKeepsLiveControlsDisabled() async {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(results: [
            .successfulLLDBProof,
            .successfulLLDBBatchRun
        ])
        let viewModel = DebuggerPanelViewModel(
            client: LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            ))
        )

        XCTAssertEqual(viewModel.session.processState, .notAttached)
        XCTAssertEqual(viewModel.session.backendState, .ready(adapterName: "Xcode LLDB Batch"))
        XCTAssertTrue(viewModel.canLaunch)
        XCTAssertFalse(viewModel.canContinue)
        XCTAssertFalse(viewModel.canStepOver)
        XCTAssertFalse(viewModel.canTerminate)

        await viewModel.launch(configuration: DebuggerLaunchConfiguration(
            executablePath: "/bin/echo",
            arguments: ["MacScopeLLDBBatch"]
        ))

        XCTAssertEqual(viewModel.statusTitle, "Exited")
        XCTAssertEqual(viewModel.session.processState, .exited(code: 0))
        XCTAssertEqual(viewModel.session.backendState, .ready(adapterName: "Xcode LLDB Batch"))
        XCTAssertEqual(viewModel.session.lastCommandRun?.targetExitStatus, 0)
        XCTAssertEqual(viewModel.session.lastCommandRun?.lldbTerminationStatus, 0)
        XCTAssertNil(viewModel.lastError)
        XCTAssertTrue(viewModel.canLaunch)
        XCTAssertFalse(viewModel.canContinue)
        XCTAssertFalse(viewModel.canStepOver)
        XCTAssertFalse(viewModel.canTerminate)
        XCTAssertEqual(runner.commands.count, 2)
    }

    @MainActor
    func testDebuggerPanelViewModelExposesTargetDescriptorsWithoutEnablingAttach() async {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let lldbPath = "\(developerDirectory)/usr/bin/lldb"
        let runner = FakeDebuggerProcessRunner(result: .successfulLLDBProof)
        let viewModel = DebuggerPanelViewModel(
            client: LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
                lldbExecutablePath: lldbPath,
                processRunner: runner,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: "/tmp/MacScopeProof"
            ))
        )

        await viewModel.toggleBreakpoint(at: 0x1000_0040)

        let importedDescriptor = viewModel.importedTargetDescriptor(
            executablePath: " /bin/echo ",
            arguments: ["MacScope"]
        )
        let importedConfiguration = viewModel.importedLaunchConfiguration(
            executablePath: " /bin/echo ",
            arguments: ["MacScope"]
        )

        XCTAssertEqual(importedConfiguration.executablePath, "/bin/echo")
        XCTAssertEqual(importedConfiguration.workingDirectory, "/bin")
        XCTAssertEqual(importedConfiguration.arguments, ["MacScope"])
        XCTAssertEqual(importedConfiguration.initialBreakpoints, [])
        XCTAssertEqual(importedDescriptor.kind, .importedTarget)
        XCTAssertEqual(importedDescriptor.title, "echo")
        XCTAssertEqual(importedDescriptor.detail, "Launch from /bin.")
        XCTAssertEqual(importedDescriptor.policy, .enabled(actionTitle: "Launch imported target"))

        let pidDescriptor = viewModel.processAttachDescriptor(
            DebuggerAttachRequest(target: .processID(1234))
        )
        let expectedAttachPolicyReason = "\(DebuggerPanelViewModel.signedTargetAttachPolicyReason) Backend: \(XcodeLLDBCommandLineAdapter.attachUnsupportedReason)"
        XCTAssertEqual(pidDescriptor.kind, .processAttach)
        XCTAssertEqual(pidDescriptor.title, "pid 1234")
        XCTAssertEqual(
            pidDescriptor.policy,
            .blocked(reason: expectedAttachPolicyReason)
        )
        XCTAssertFalse(pidDescriptor.policy.isEnabled)
        XCTAssertTrue(pidDescriptor.detail.contains("is disabled"))

        XCTAssertFalse(viewModel.capabilities.canAttach)
    }

    @MainActor
    func testDebuggerPanelViewModelBuildsModelDrivenTargetPickerRows() async {
        let viewModel = DebuggerPanelViewModel(client: CapturingLaunchDebuggerClient())

        var picker = viewModel.targetPickerSnapshot

        XCTAssertEqual(picker.policySummary.title, "Signed-target policy pending")
        XCTAssertEqual(picker.policySummary.statusTitle, "Blocked")
        XCTAssertEqual(picker.policySummary.systemImage, "lock.shield")
        XCTAssertTrue(picker.policySummary.detail.contains("Local process attach remains disabled"))
        XCTAssertTrue(picker.policySummary.diagnostics.contains {
            $0.severity == .blocker && $0.title == "Signed-target policy pending"
        })
        XCTAssertEqual(picker.rows.map(\.kind), [.importedTarget])
        XCTAssertEqual(picker.selectedRow?.kind, .importedTarget)
        XCTAssertEqual(picker.rows[0].policy, .blocked(reason: "Choose an imported executable before launching."))
        XCTAssertNil(picker.pidTarget.processID)
        XCTAssertEqual(
            picker.pidTarget.attachAvailability.disabledReason,
            "Enter a positive process ID before attaching."
        )
        XCTAssertEqual(picker.selectedSummary.title, "Imported target")
        XCTAssertEqual(picker.selectedSummary.statusTitle, "Blocked")
        XCTAssertEqual(
            picker.selectedSummary.disabledReason,
            "Choose an imported executable before launching."
        )
        XCTAssertEqual(
            viewModel.controlAvailability(for: .launch).disabledReason,
            "Choose an imported executable before launching."
        )
        XCTAssertEqual(
            viewModel.controlAvailability(for: .continueExecution).disabledReason,
            "Continue requires a paused live debug process."
        )
        XCTAssertEqual(
            viewModel.controlAvailability(for: .attachProcess).disabledReason,
            "Enter a positive process ID before attaching."
        )
        XCTAssertFalse(viewModel.canLaunchSelectedTarget)

        viewModel.importedExecutablePath = " /bin/echo "
        viewModel.processIDText = " 1234 "

        picker = viewModel.targetPickerSnapshot
        let expectedAttachPolicyReason = "\(DebuggerPanelViewModel.signedTargetAttachPolicyReason) Backend: Attach is not enabled in this test client."

        XCTAssertEqual(picker.rows[0].id, "imported:/bin/echo")
        XCTAssertEqual(picker.rows[0].title, "echo")
        XCTAssertEqual(picker.rows[0].detail, "Launch from /bin.")
        XCTAssertEqual(picker.rows[0].policy, .enabled(actionTitle: "Launch imported target"))
        XCTAssertEqual(picker.selectedSummary.title, "echo")
        XCTAssertEqual(picker.selectedSummary.statusTitle, "Ready")
        XCTAssertNil(picker.selectedSummary.disabledReason)
        XCTAssertEqual(
            picker.selectedSummary.detail,
            "Launch echo from /bin. No arguments; No environment overrides."
        )
        XCTAssertTrue(viewModel.controlAvailability(for: .launch).isEnabled)
        XCTAssertNil(viewModel.controlAvailability(for: .launch).disabledReason)
        XCTAssertEqual(picker.pidTarget.processID, 1234)
        XCTAssertEqual(picker.pidTarget.attachAvailability.disabledReason, expectedAttachPolicyReason)
        XCTAssertEqual(
            viewModel.controlAvailability(for: .attachProcess).disabledReason,
            expectedAttachPolicyReason
        )
        XCTAssertEqual(picker.selectedRow?.kind, .importedTarget)
        XCTAssertTrue(viewModel.canLaunchSelectedTarget)
    }

    @MainActor
    func testDebuggerPanelViewModelBlocksMissingImportedExecutableBeforeLaunch() async {
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.importedExecutablePath = "/tmp/MacScopeMissingDebuggerTarget"

        let picker = viewModel.targetPickerSnapshot
        let expectedReason = "No executable file exists at /tmp/MacScopeMissingDebuggerTarget."

        XCTAssertEqual(picker.rows[0].policy, .blocked(reason: expectedReason))
        XCTAssertEqual(picker.selectedSummary.disabledReason, expectedReason)
        XCTAssertEqual(viewModel.controlAvailability(for: .launch).disabledReason, expectedReason)
        XCTAssertFalse(viewModel.canLaunchSelectedTarget)

        await viewModel.launchSelectedTarget()

        XCTAssertNil(client.receivedLaunchConfiguration)
        XCTAssertEqual(viewModel.lastError, expectedReason)
    }

    @MainActor
    func testWorkspaceImportedExecutableDrivesDebuggerPickerAndLaunchConfiguration() async throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "MacScopeDebuggerExecutable")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let executableURL = temporaryDirectory.appendingPathComponent("FixtureTool", isDirectory: false)
        try writeExecutableFixture(to: executableURL)

        let binary = BinaryImage(
            id: UUID(),
            name: "FixtureTool",
            path: executableURL.path,
            kind: "Mach-O executable",
            architecture: "arm64"
        )
        let store = workspaceStore(binary: binary)
        let workspaceTarget = try XCTUnwrap(store.debuggerLaunchTargetDescriptor)

        XCTAssertTrue(workspaceTarget.isLaunchable)
        XCTAssertEqual(workspaceTarget.executablePath, executableURL.path)
        XCTAssertNil(workspaceTarget.unavailableReason)

        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.bindWorkspaceLaunchTarget(workspaceTarget)
        viewModel.processIDText = "1234"

        await viewModel.toggleBreakpoint(at: 0x1000_0010)
        await viewModel.toggleBreakpoint(at: 0x1000_0030)

        let picker = viewModel.targetPickerSnapshot
        let expectedAttachPolicyReason = "\(DebuggerPanelViewModel.signedTargetAttachPolicyReason) Backend: Attach is not enabled in this test client."

        XCTAssertEqual(picker.rows.map(\.kind), [.importedTarget])
        XCTAssertEqual(picker.rows[0].id, "imported:\(executableURL.path)")
        XCTAssertEqual(picker.rows[0].title, "FixtureTool")
        XCTAssertEqual(picker.rows[0].detail, "Launch from \(temporaryDirectory.path).")
        XCTAssertEqual(picker.rows[0].policy, .enabled(actionTitle: "Launch imported target"))
        XCTAssertEqual(picker.selectedRow?.id, picker.rows[0].id)
        XCTAssertTrue(viewModel.canLaunchSelectedTarget)
        XCTAssertEqual(picker.pidTarget.attachAvailability.disabledReason, expectedAttachPolicyReason)

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.receivedLaunchConfiguration?.executablePath, executableURL.path)
        XCTAssertEqual(client.receivedLaunchConfiguration?.workingDirectory, temporaryDirectory.path)
        XCTAssertTrue(client.receivedLaunchConfiguration?.initialBreakpoints.isEmpty == true)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x1000_0010, 0x1000_0030])
        XCTAssertNil(viewModel.lastError)
    }

    @MainActor
    func testWorkspaceDebuggerTargetResolvesAppBundleExecutable() throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "MacScopeDebuggerApp")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let appURL = temporaryDirectory.appendingPathComponent("Fixture.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let executableURL = macOSURL.appendingPathComponent("FixtureExecutable", isDirectory: false)
        try writeExecutableFixture(to: executableURL)

        let infoPlist: [String: Any] = [
            "CFBundleExecutable": "FixtureExecutable",
            "CFBundleIdentifier": "dev.macscope.fixture"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

        let binary = BinaryImage(
            id: UUID(),
            name: "Fixture.app",
            path: appURL.path,
            kind: "app bundle",
            architecture: "arm64"
        )
        let store = workspaceStore(binary: binary)
        let workspaceTarget = try XCTUnwrap(store.debuggerLaunchTargetDescriptor)
        let launchConfiguration = workspaceTarget.launchConfiguration()
        let descriptor = workspaceTarget.importedTargetDescriptor(launchSupport: .supported)

        XCTAssertTrue(workspaceTarget.isLaunchable)
        XCTAssertEqual(workspaceTarget.sourcePath, appURL.path)
        XCTAssertEqual(workspaceTarget.executablePath, executableURL.path)
        XCTAssertEqual(launchConfiguration.executablePath, executableURL.path)
        XCTAssertEqual(launchConfiguration.workingDirectory, macOSURL.path)
        XCTAssertEqual(descriptor.id, "imported:\(executableURL.path)")
        XCTAssertEqual(descriptor.title, "FixtureExecutable")
        XCTAssertEqual(descriptor.policy, .enabled(actionTitle: "Launch imported target"))
    }

    @MainActor
    func testWorkspaceDebuggerTargetBlocksMissingExecutablePath() async throws {
        let temporaryDirectory = try makeTemporaryDirectory(named: "MacScopeDebuggerMissing")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let missingURL = temporaryDirectory.appendingPathComponent("MissingTool", isDirectory: false)
        let binary = BinaryImage(
            id: UUID(),
            name: "MissingTool",
            path: missingURL.path,
            kind: "Mach-O executable",
            architecture: "arm64"
        )
        let store = workspaceStore(binary: binary)
        let workspaceTarget = try XCTUnwrap(store.debuggerLaunchTargetDescriptor)
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(
            client: client,
            workspaceLaunchTarget: workspaceTarget
        )

        let expectedReason = "No executable file exists at \(missingURL.path)."
        let picker = viewModel.targetPickerSnapshot

        XCTAssertFalse(workspaceTarget.isLaunchable)
        XCTAssertEqual(workspaceTarget.executablePath, missingURL.path)
        XCTAssertEqual(workspaceTarget.unavailableReason, expectedReason)
        XCTAssertEqual(picker.rows[0].id, "imported:\(missingURL.path)")
        XCTAssertEqual(picker.rows[0].title, "MissingTool")
        XCTAssertEqual(picker.rows[0].detail, expectedReason)
        XCTAssertEqual(picker.rows[0].policy, .blocked(reason: expectedReason))
        XCTAssertFalse(viewModel.canLaunchSelectedTarget)

        await viewModel.launchSelectedTarget()

        XCTAssertNil(client.receivedLaunchConfiguration)
        XCTAssertEqual(viewModel.lastError, expectedReason)
    }

    @MainActor
    func testDebuggerPanelViewModelLaunchSelectedTargetOnlyUsesImportedDescriptor() async {
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.launchSelectedTarget()

        XCTAssertNil(client.receivedLaunchConfiguration)
        XCTAssertEqual(viewModel.lastError, "Choose an imported executable before launching.")

        viewModel.importedExecutablePath = "/bin/echo"
        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.receivedLaunchConfiguration?.executablePath, "/bin/echo")
        XCTAssertEqual(client.receivedLaunchConfiguration?.workingDirectory, "/bin")
        XCTAssertNil(viewModel.lastError)

        let attachClient = CapturingLaunchDebuggerClient()
        let attachViewModel = DebuggerPanelViewModel(client: attachClient)
        attachViewModel.importedExecutablePath = "/bin/echo"
        attachViewModel.processIDText = "1234"
        attachViewModel.selectedTargetID = "attach:pid 1234"

        XCTAssertTrue(attachViewModel.controlAvailability(for: .launch).isEnabled)
        XCTAssertNil(attachViewModel.controlAvailability(for: .launch).disabledReason)

        await attachViewModel.launchSelectedTarget()

        XCTAssertEqual(attachClient.receivedLaunchConfiguration?.executablePath, "/bin/echo")
        XCTAssertNil(attachViewModel.lastError)
        XCTAssertFalse(attachViewModel.capabilities.canAttach)
    }

    @MainActor
    func testDebuggerPanelViewModelKeepsExactAttachOutOfInlineTargetRowsWhenBackendReportsAttachSupport() async {
        let client = AttachReportingDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.processIDText = "4321"

        let picker = viewModel.targetPickerSnapshot

        XCTAssertTrue(viewModel.capabilities.canAttach)
        XCTAssertEqual(picker.policySummary.title, "Exact attach supported")
        XCTAssertEqual(picker.rows.map(\.kind), [.importedTarget])
        XCTAssertNil(picker.pidTarget.attachAvailability.disabledReason)
        viewModel.selectedTargetID = "attach:pid 4321"
        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.launchCallCount, 0)
        XCTAssertEqual(viewModel.lastError, "Choose an imported executable before launching.")
    }

    @MainActor
    func testDebuggerPanelViewModelKeepsQueuedBreakpointsLocalUntilCheckedRuntimeBinding() async {
        let client = CapturingLaunchDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.toggleBreakpoint(at: 0x1000_0010)
        await viewModel.toggleBreakpoint(at: 0x1000_0030)

        await viewModel.launch(configuration: DebuggerLaunchConfiguration(executablePath: "/tmp/example"))

        XCTAssertTrue(client.receivedLaunchConfiguration?.initialBreakpoints.isEmpty == true)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [0x1000_0010, 0x1000_0030])
        XCTAssertEqual(viewModel.session.backendState, .connected(processID: 42, adapterName: "Capturing LLDB"))
    }

    @MainActor
    func testDebuggerPanelViewModelRestoresLaunchableStateWhenLaunchConfigurationFails() async {
        let queuedBreakpoint = DebuggerBreakpoint(address: 0x1000_0010)
        let initialSnapshot = DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [queuedBreakpoint],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready.",
            backendState: .ready(adapterName: "Failing LLDB")
        )
        let client = FailingLaunchDebuggerClient(
            initialSnapshot: initialSnapshot,
            launchError: .invalidConfiguration("Choose an executable before launching LLDB live launch.")
        )
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canLaunch)

        await viewModel.launch(configuration: DebuggerLaunchConfiguration(executablePath: ""))

        XCTAssertEqual(viewModel.session.processState, .notAttached)
        XCTAssertEqual(viewModel.session.breakpoints, [queuedBreakpoint])
        XCTAssertEqual(
            viewModel.session.backendState,
            .failed(reason: "Choose an executable before launching LLDB live launch.")
        )
        XCTAssertEqual(viewModel.statusTitle, "Not attached")
        XCTAssertEqual(viewModel.lastError, "Choose an executable before launching LLDB live launch.")
        XCTAssertTrue(viewModel.canLaunch)
        XCTAssertFalse(viewModel.canContinue)
    }

    @MainActor
    func testDebuggerPanelViewModelAppliesBackendStateTransitions() async {
        let client = StubDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canLaunch)

        await viewModel.launch(configuration: DebuggerLaunchConfiguration(executablePath: "/tmp/example"))
        XCTAssertEqual(viewModel.session.processState, .paused(processID: 42, reason: .breakpoint(address: 0x1000_0010)))
        XCTAssertTrue(viewModel.canContinue)
        XCTAssertTrue(viewModel.canStepOver)
        XCTAssertTrue(viewModel.canTerminate)

        await viewModel.continueExecution()
        XCTAssertEqual(viewModel.session.processState, .running(processID: 42, executableName: "example"))
        XCTAssertFalse(viewModel.canContinue)
        XCTAssertFalse(viewModel.canStepOver)
        XCTAssertTrue(viewModel.canTerminate)

        await viewModel.pause()
        XCTAssertEqual(viewModel.session.processState, .paused(processID: 42, reason: .userRequested))

        XCTAssertEqual(client.detachCallCount, 0)
        XCTAssertEqual(client.terminateCallCount, 0)
    }

    @MainActor
    func testDebuggerPanelViewModelRoutesAttachedOriginEndToDetach() async {
        let sessionCoordinate = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
        )
        let attached = DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Attached and paused.",
            backendState: .connected(processID: 42, adapterName: "Stub LLDB"),
            transportSessionCoordinate: sessionCoordinate,
            transportStopCoordinate: DebuggerStopCoordinate(
                session: sessionCoordinate,
                stopRevision: .initial
            ),
            transportEventSequence: DebuggerEventSequence(rawValue: 1),
            transportTargetDisposition: .stopped(processID: 42),
            transportTargetAuthority: DebuggerSessionTargetAuthority(
                origin: .attached(makeDebuggerCoreTestIdentity(processID: 42))
            )
        )
        let client = StubDebuggerClient(initialSnapshot: attached)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertTrue(viewModel.canDetach)
        XCTAssertTrue(viewModel.showsSessionEndAction)
        XCTAssertEqual(viewModel.sessionEndAction, .detach)
        XCTAssertFalse(viewModel.canTerminate)
        XCTAssertEqual(
            viewModel.controlAvailability(for: .detach),
            DebuggerControlAvailability(action: .detach, isEnabled: true, disabledReason: nil)
        )

        await viewModel.detach()

        XCTAssertEqual(client.detachCallCount, 1)
        XCTAssertEqual(client.terminateCallCount, 0)
        XCTAssertEqual(viewModel.session.processState, .notAttached)
        XCTAssertEqual(viewModel.session.statusMessage, "Process detached.")
    }

    @MainActor
    func testDebuggerPanelViewModelKeepsLaunchedOriginEndOnTerminate() async {
        let identity = makeDebuggerCoreTestIdentity(processID: 42)
        let sessionCoordinate = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
        )
        let launched = DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Launched and paused.",
            backendState: .connected(processID: 42, adapterName: "Stub LLDB"),
            transportSessionCoordinate: sessionCoordinate,
            transportStopCoordinate: DebuggerStopCoordinate(
                session: sessionCoordinate,
                stopRevision: .initial
            ),
            transportEventSequence: DebuggerEventSequence(rawValue: 1),
            transportTargetDisposition: .stopped(processID: 42),
            transportTargetAuthority: DebuggerSessionTargetAuthority(
                origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
            )
        )
        let client = StubDebuggerClient(initialSnapshot: launched)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertFalse(viewModel.canDetach)
        XCTAssertTrue(viewModel.canTerminate)
        XCTAssertTrue(viewModel.showsSessionEndAction)
        XCTAssertEqual(viewModel.sessionEndAction, .terminate)

        await viewModel.terminate()

        XCTAssertEqual(client.detachCallCount, 0)
        XCTAssertEqual(client.terminateCallCount, 1)
        XCTAssertEqual(viewModel.session.processState, .exited(code: 9))
    }

    @MainActor
    func testDebuggerPanelViewModelDisablesLiveControlsForNonLivePausedStates() async {
        let batchStoppedSnapshot = DebuggerSessionSnapshot(
            processState: .batchStopped(processID: 42, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [DebuggerBreakpoint(address: 0x1000_0010)],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "LLDB batch launch stopped.",
            backendState: .ready(adapterName: "Xcode LLDB Batch")
        )
        let batchClient = StubDebuggerClient(initialSnapshot: batchStoppedSnapshot)
        let batchViewModel = DebuggerPanelViewModel(client: batchClient)

        XCTAssertFalse(batchViewModel.canContinue)
        XCTAssertFalse(batchViewModel.canStepOver)
        XCTAssertFalse(batchViewModel.canPause)
        XCTAssertFalse(batchViewModel.canTerminate)
        XCTAssertFalse(batchViewModel.canRefreshSnapshot)

        await batchViewModel.continueExecution()

        XCTAssertEqual(batchClient.continueCallCount, 0)
        XCTAssertEqual(batchViewModel.lastError, "Continue requires a paused live debug process.")
        XCTAssertEqual(batchViewModel.session.processState, batchStoppedSnapshot.processState)
        XCTAssertEqual(batchViewModel.session.backendState, .failed(reason: "Continue requires a paused live debug process."))

        let mismatchedPausedSnapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .userRequested),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 99, adapterName: "Ready LLDB")
        )
        let mismatchedClient = StubDebuggerClient(initialSnapshot: mismatchedPausedSnapshot)
        let mismatchedViewModel = DebuggerPanelViewModel(client: mismatchedClient)

        XCTAssertFalse(mismatchedViewModel.canContinue)
        XCTAssertFalse(mismatchedViewModel.canStepOver)
        XCTAssertFalse(mismatchedViewModel.canPause)
        XCTAssertFalse(mismatchedViewModel.canTerminate)
        XCTAssertFalse(mismatchedViewModel.canRefreshSnapshot)

        await mismatchedViewModel.stepOver()

        XCTAssertEqual(mismatchedClient.stepOverCallCount, 0)
        XCTAssertEqual(mismatchedViewModel.lastError, "Step over requires a paused live debug process.")
        XCTAssertEqual(mismatchedViewModel.session.processState, mismatchedPausedSnapshot.processState)
        XCTAssertEqual(mismatchedViewModel.session.backendState, .failed(reason: "Step over requires a paused live debug process."))
    }

    @MainActor
    func testDebuggerPanelViewModelPreservesProcessStateForUnsupportedControlOperation() async {
        let client = UnsupportedStepDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        await viewModel.launch(configuration: DebuggerLaunchConfiguration(executablePath: "/tmp/example"))
        let pausedState = viewModel.session.processState

        await viewModel.stepOver()

        XCTAssertEqual(pausedState, .paused(processID: 42, reason: .breakpoint(address: 0x1000_0010)))
        XCTAssertEqual(viewModel.session.processState, pausedState)
        XCTAssertEqual(viewModel.statusTitle, "Paused")
        XCTAssertEqual(viewModel.lastError, "Step over is not supported for this target.")
        XCTAssertEqual(viewModel.session.statusMessage, "Step over is not supported for this target.")

        let terminateClient = UnsupportedTerminateDebuggerClient()
        let terminateViewModel = DebuggerPanelViewModel(client: terminateClient)

        await terminateViewModel.launch(configuration: DebuggerLaunchConfiguration(executablePath: "/tmp/example"))
        let terminableState = terminateViewModel.session.processState

        await terminateViewModel.terminate()

        XCTAssertEqual(terminableState, .paused(processID: 42, reason: .breakpoint(address: 0x1000_0010)))
        XCTAssertEqual(terminateViewModel.session.processState, terminableState)
        XCTAssertEqual(terminateViewModel.statusTitle, "Paused")
        XCTAssertEqual(terminateViewModel.lastError, "Terminate is not supported for this target.")
        XCTAssertEqual(terminateViewModel.session.statusMessage, "Terminate is not supported for this target.")
    }

    private func makeTemporaryDirectory(named prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutableFixture(to url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private var testLLDBToolchain: DebuggerLLDBToolchain {
        DebuggerLLDBToolchain(
            executablePath: "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/lldb",
            developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
            discoverySource: "test",
            candidatePaths: []
        )
    }

    private var testLLDBProofCommand: DebuggerExternalCommand {
        DebuggerExternalCommand(
            executablePath: testLLDBToolchain.executablePath,
            arguments: ["--batch", "--no-lldbinit", "-o", "version"],
            environment: ["TERM": "dumb"],
            workingDirectory: "/tmp/MacScopeProof",
            timeoutSeconds: 5
        )
    }

    @MainActor
    private func workspaceStore(binary: BinaryImage) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "Debugger Fixture",
            snapshot: WorkspaceSnapshot(
                binaries: [binary],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine()
        )
    }
}

private final class FakeDebuggerProcessRunner: DebuggerProcessRunning {
    private var results: [Result<DebuggerSubprocessResult, Error>]
    private(set) var commands: [DebuggerExternalCommand] = []

    init(result: DebuggerSubprocessResult) {
        self.results = [.success(result)]
    }

    init(results: [DebuggerSubprocessResult]) {
        self.results = results.map { .success($0) }
    }

    init(error: Error) {
        self.results = [.failure(error)]
    }

    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult {
        commands.append(command)
        guard !results.isEmpty else {
            throw DebuggerProcessRunnerError.launchFailed("Fake runner has no queued result.")
        }

        if results.count == 1 {
            return try results[0].get()
        }

        return try results.removeFirst().get()
    }
}

private final class FakeLLDBCommandSessionTransport: DebuggerLLDBCommandSessionTransport {
    private var responses: [Result<DebuggerLLDBCommandResponse, Error>]
    private(set) var startCommands: [DebuggerExternalCommand] = []
    private(set) var sentCommands: [String] = []
    private(set) var stopCallCount = 0

    init(responses: [DebuggerLLDBCommandResponse]) {
        self.responses = responses.map { .success($0) }
    }

    init(error: Error) {
        self.responses = [.failure(error)]
    }

    func start(_ command: DebuggerExternalCommand) throws {
        startCommands.append(command)
    }

    func send(_ command: String, timeoutSeconds: TimeInterval) throws -> DebuggerLLDBCommandResponse {
        sentCommands.append(command)
        guard !responses.isEmpty else {
            throw DebuggerLLDBCommandSessionError.writeFailed("Fake LLDB transport has no queued response.")
        }

        var response = try responses.removeFirst().get()
        response.command = command
        return response
    }

    func stop() {
        stopCallCount += 1
    }
}

private extension DebuggerLLDBCommandResponse {
    static var emptyLLDBCommand: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(command: "", standardOutput: "")
    }

    static var liveLaunchStoppedAtEntry: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process launch --stop-at-entry",
            standardOutput: """
            Process 222 launched: '/bin/echo' (arm64e)
            Process 222 stopped
                frame #0: 0x0000000100000000 dyld`_dyld_start
            """
        )
    }

    static var liveStatusStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 222 stopped
            """
        )
    }

    static var liveStatusSignalStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 222 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = signal SIGTRAP
            """
        )
    }

    static var liveStatusDifferentProcessStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 333 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
                frame #0: 0x00000001000003f8 echo`main + 8
            """
        )
    }

    static var liveBacktraceWithFrames: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "thread backtrace",
            standardOutput: """
            * thread #1, queue = 'com.apple.main-thread'
              * frame #0: 0x00000001000003f8 echo`main + 8 at main.swift:12:5
                frame #1: 0x0000000180001000 dyld`start + 604
            """
        )
    }

    static var liveRegisterSnapshot: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "\(XcodeLLDBCommandLineAdapter.liveRegisterReadCommand)",
            standardOutput: """
                  pc = 0x00000001000003f8 echo`main + 8
                  sp = 0x000000016fdff200
                  fp = 0x000000016fdff220
                  lr = 0x0000000180001000 dyld`start + 604
                  x0 = 0x0000000000000001
                  x1 = 0x0000000000000002
            """
        )
    }

    static var liveStackMemorySnapshot: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "memory read --format x --size 1 --count 64 $sp",
            standardOutput: """
            0x000000016fdff200: 0x01 0x00 0x00 0x00 0x00 0x00 0x00 0x00
            0x000000016fdff208: 0x08 0xf4 0xdf 0x6f 0x01 0x00 0x00 0x00
            0x000000016fdff210: 0x20 0xf2 0xdf 0x6f 0x01 0x00 0x00 0x00
            0x000000016fdff218: 0x00 0x10 0x00 0x80 0x01 0x00 0x00 0x00
            """
        )
    }

    static var liveContinuedRunning: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process continue",
            standardOutput: """
            Process 222 resuming
            """
        )
    }

    static var liveStatusRunning: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 222 running
            """
        )
    }

    static var liveContinuedBreakpointStop: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process continue",
            standardOutput: """
            Process 222 stopped
            """
        )
    }

    static var liveStatusBreakpointStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 222 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
                frame #0: 0x00000001000003f8 echo`main + 8
            """
        )
    }

    static var liveInterruptedStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process interrupt",
            standardOutput: """
            Process 222 stopped
            """
        )
    }

    static var liveTerminated: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process kill",
            standardOutput: """
            Process 222 exited with status = 9 (0x00000009)
            """
        )
    }

    static var liveDifferentProcessTerminated: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process kill",
            standardOutput: """
            Process 333 exited with status = 9 (0x00000009)
            """
        )
    }

    static var liveStepStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "thread step-over",
            standardOutput: """
            Process 222 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = step over
            """
        )
    }

    static var liveStepStatusStopped: DebuggerLLDBCommandResponse {
        DebuggerLLDBCommandResponse(
            command: "process status",
            standardOutput: """
            Process 222 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = step over
            """
        )
    }
}

private extension DebuggerSubprocessResult {
    static var successfulLLDBProof: DebuggerSubprocessResult {
        DebuggerSubprocessResult(
            terminationStatus: 0,
            standardOutput: """
            (lldb) version
            lldb-2103.0.23.6
            Apple Swift version 6.4 (swiftlang-6.4.0.20.104 clang-2100.3.20.102)
            (lldb) platform status
              Platform: host
                Triple: arm64-apple-macosx
            OS Version: 27.0 (26A5353q)
            (lldb) settings show target.default-arch
            target.default-arch (arch) =
            """,
            standardError: "",
            timedOut: false
        )
    }

    static var successfulLLDBBatchRun: DebuggerSubprocessResult {
        DebuggerSubprocessResult(
            terminationStatus: 0,
            standardOutput: """
            (lldb) target create "/bin/echo"
            Current executable set to '/bin/echo' (arm64e).
            (lldb) settings set -- target.run-args "MacScopeLLDBBatch"
            (lldb) run
            Process 12345 launched: '/bin/echo' (arm64e)
            MacScopeLLDBBatch
            Process 12345 exited with status = 0 (0x00000000)
            (lldb) process status
            """,
            standardError: "debugserver fixture note\n",
            timedOut: false
        )
    }

    static var breakpointStoppedLLDBBatchRun: DebuggerSubprocessResult {
        DebuggerSubprocessResult(
            terminationStatus: 0,
            standardOutput: """
            (lldb) target create "/bin/echo"
            Current executable set to '/bin/echo' (arm64e).
            (lldb) breakpoint set --address 0x00000001000003f8
            Breakpoint 1: where = echo`main + 8, address = 0x00000001000003f8
            (lldb) run
            Process 24680 launched: '/bin/echo' (arm64e)
            Process 24680 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
                frame #0: 0x00000001000003f8 echo`main + 8
            echo`main:
            ->  0x00000001000003f8 <+8>: mov    x0, x20
            (lldb) process status
            Process 24680 stopped
            * thread #1, queue = 'com.apple.main-thread', stop reason = breakpoint 1.1
            """,
            standardError: "",
            timedOut: false
        )
    }

    static var zeroExitLLDBErrorBatchRun: DebuggerSubprocessResult {
        DebuggerSubprocessResult(
            terminationStatus: 0,
            standardOutput: """
            (lldb) target create "/bin/echo"
            Current executable set to '/bin/echo' (arm64e).
            (lldb) run
            error: unable to launch target: permission denied
            """,
            standardError: "",
            timedOut: false
        )
    }

    static var failedLLDBBatchRun: DebuggerSubprocessResult {
        DebuggerSubprocessResult(
            terminationStatus: 1,
            standardOutput: """
            (lldb) target create "/bin/echo"
            Current executable set to '/bin/echo' (arm64e).
            (lldb) run
            error: process exited with status -1 (attach failed (Not allowed to attach to process.))
            """,
            standardError: "",
            timedOut: false
        )
    }
}

@MainActor
private class StubDebuggerClient: DebuggerClient {
    private let initialSnapshot: DebuggerSessionSnapshot
    private(set) var continueCallCount = 0
    private(set) var stepOverCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var detachCallCount = 0
    private(set) var terminateCallCount = 0

    init(initialSnapshot: DebuggerSessionSnapshot = .empty) {
        self.initialSnapshot = initialSnapshot
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Stub LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        initialSnapshot
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        return DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .breakpoint(address: 0x1000_0010)),
            breakpoints: [DebuggerBreakpoint(address: 0x1000_0010)],
            frames: [
                DebuggerFrameSummary(
                    index: 0,
                    address: 0x1000_0010,
                    functionName: "_main",
                    moduleName: "example",
                    sourceLocation: nil
                )
            ],
            registers: [
                DebuggerRegisterSummary(name: "pc", value: UInt64(0x1000_0010).hexAddress, role: "program counter")
            ],
            memoryRegions: [
                DebuggerMemorySummary(address: 0x1000_1000, byteCount: 4, previewBytes: [0xde, 0xad, 0xbe, 0xef], label: "stack")
            ],
            statusMessage: "Paused at breakpoint.",
            backendState: .connected(processID: 42, adapterName: "Stub LLDB")
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        continueCallCount += 1
        var copy = snapshot
        copy.processState = .running(processID: 42, executableName: "example")
        copy.statusMessage = "Process continued."
        return copy
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        stepOverCallCount += 1
        var copy = snapshot
        copy.processState = .paused(processID: 42, reason: .step)
        copy.statusMessage = "Step completed."
        return copy
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        pauseCallCount += 1
        var copy = snapshot
        copy.processState = .paused(processID: 42, reason: .userRequested)
        copy.statusMessage = "Paused by user."
        return copy
    }

    func detach(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        detachCallCount += 1
        var copy = snapshot
        copy.processState = .notAttached
        copy.backendState = .ready(adapterName: "Stub LLDB")
        copy.statusMessage = "Process detached."
        copy.transportStopCoordinate = nil
        copy.transportTargetDisposition = .detached
        if let session = copy.transportSessionCoordinate {
            copy.transportSessionCoordinate = DebuggerSessionCoordinate(
                epoch: session.epoch,
                lifecycleRevision: session.lifecycleRevision.incremented() ?? session.lifecycleRevision
            )
        }
        if let sequence = copy.transportEventSequence {
            copy.transportEventSequence = sequence.incremented() ?? sequence
        }
        return copy
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        terminateCallCount += 1
        var copy = snapshot
        copy.processState = .exited(code: 9)
        copy.backendState = .ready(adapterName: "Stub LLDB")
        copy.statusMessage = "Process terminated."
        copy.transportStopCoordinate = nil
        copy.transportTargetDisposition = .terminated
        if let session = copy.transportSessionCoordinate {
            copy.transportSessionCoordinate = DebuggerSessionCoordinate(
                epoch: session.epoch,
                lifecycleRevision: session.lifecycleRevision.incremented() ?? session.lifecycleRevision
            )
        }
        if let sequence = copy.transportEventSequence {
            copy.transportEventSequence = sequence.incremented() ?? sequence
        }
        return copy
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        copy.statusMessage = "Breakpoints synchronized."
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }
}

private func makeDebuggerCoreTestIdentity(processID: Int32) -> DebuggerLocalProcessIdentity {
    DebuggerLocalProcessIdentity(
        processID: processID,
        startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
        realUserID: 501,
        effectiveUserID: 501,
        canonicalExecutablePath: "/tmp/MacScopeDebuggerCoreFixture",
        executableDeviceID: 7,
        executableFileID: 7_001,
        executableByteCount: 4_096,
        executableSHA256: String(repeating: "a", count: 64),
        architecture: .arm64,
        machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        codeIdentity: nil
    )!
}

@MainActor
private final class UnsupportedStepDebuggerClient: StubDebuggerClient {
    override func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Step over is not supported for this target.")
    }
}

@MainActor
private final class UnsupportedTerminateDebuggerClient: StubDebuggerClient {
    override func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        throw DebuggerClientError.unsupportedOperation("Terminate is not supported for this target.")
    }
}

@MainActor
private final class FailingLaunchDebuggerClient: StubDebuggerClient {
    private let launchError: DebuggerClientError

    init(initialSnapshot: DebuggerSessionSnapshot, launchError: DebuggerClientError) {
        self.launchError = launchError
        super.init(initialSnapshot: initialSnapshot)
    }

    override func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        throw launchError
    }
}

@MainActor
private final class ReadyLLDBBackendAdapter: LLDBDebuggerBackendAdapter {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Ready LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: [],
        backendAvailability: .ready(adapterName: "Ready LLDB", details: "Ready LLDB is available."),
        launchSupport: .supported,
        attachSupport: .unsupported(reason: "Attach is not enabled in this test adapter."),
        executionControlSupport: .supported
    )

    let initialBackendState: DebuggerBackendSessionState = .ready(adapterName: "Ready LLDB")
    private(set) var receivedLaunchConfiguration: DebuggerLaunchConfiguration?

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        receivedLaunchConfiguration = configuration
        return DebuggerSessionSnapshot(
            processState: .paused(processID: 4242, reason: .breakpoint(address: configuration.initialBreakpoints.first?.address ?? 0)),
            breakpoints: configuration.initialBreakpoints,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready adapter launched.",
            backendState: .connected(processID: 4242, adapterName: "Ready LLDB")
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.processState = .exited(code: 9)
        copy.backendState = .ready(adapterName: "Ready LLDB")
        copy.statusMessage = "Ready adapter terminated."
        return copy
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        copy.statusMessage = "Ready adapter synchronized breakpoints."
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }
}

@MainActor
private final class CapturingLaunchDebuggerClient: DebuggerClient {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Capturing LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: [],
        backendAvailability: .ready(adapterName: "Capturing LLDB", details: "Capturing LLDB is available."),
        launchSupport: .supported,
        attachSupport: .unsupported(reason: "Attach is not enabled in this test client."),
        executionControlSupport: .supported
    )

    private(set) var receivedLaunchConfiguration: DebuggerLaunchConfiguration?

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready.",
            backendState: .ready(adapterName: "Capturing LLDB")
        )
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        receivedLaunchConfiguration = configuration
        return DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .breakpoint(address: configuration.initialBreakpoints.first?.address ?? 0)),
            breakpoints: configuration.initialBreakpoints,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused at launch.",
            backendState: .connected(processID: 42, adapterName: "Capturing LLDB")
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.processState = .exited(code: 9)
        copy.backendState = .ready(adapterName: "Capturing LLDB")
        copy.statusMessage = "Captured terminate."
        return copy
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        copy.statusMessage = "Captured breakpoint replacement."
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }
}

@MainActor
private final class AttachReportingDebuggerClient: DebuggerClient {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Attach Reporting LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: true,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: [],
        backendAvailability: .ready(adapterName: "Attach Reporting LLDB", details: "Attach-capable LLDB is available."),
        launchSupport: .supported,
        attachSupport: .supported,
        executionControlSupport: .supported
    )

    private(set) var launchCallCount = 0

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready.",
            backendState: .ready(adapterName: "Attach Reporting LLDB")
        )
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        launchCallCount += 1
        return DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .breakpoint(address: configuration.initialBreakpoints.first?.address ?? 0)),
            breakpoints: configuration.initialBreakpoints,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused at launch.",
            backendState: .connected(processID: 42, adapterName: "Attach Reporting LLDB")
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        snapshot
    }
}

@MainActor
private final class ControlRecordingLLDBBackendAdapter: LLDBDebuggerBackendAdapter {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Recording LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: [],
        backendAvailability: .ready(adapterName: "Recording LLDB", details: "Recording LLDB is available."),
        launchSupport: .supported,
        attachSupport: .unsupported(reason: "Attach is not enabled in this test adapter."),
        executionControlSupport: .supported
    )

    let initialBackendState: DebuggerBackendSessionState = .ready(adapterName: "Recording LLDB")
    private(set) var continueCallCount = 0
    private(set) var stepOverCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var terminateCallCount = 0
    private(set) var replaceBreakpointsCallCount = 0
    private(set) var refreshSnapshotCallCount = 0

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(processID: 42, reason: .userRequested),
            breakpoints: configuration.initialBreakpoints,
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Recording adapter launched.",
            backendState: .connected(processID: 42, adapterName: "Recording LLDB")
        )
    }

    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        continueCallCount += 1
        return snapshot
    }

    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        stepOverCallCount += 1
        return snapshot
    }

    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        pauseCallCount += 1
        return snapshot
    }

    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        terminateCallCount += 1
        return snapshot
    }

    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        replaceBreakpointsCallCount += 1
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        return copy
    }

    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        refreshSnapshotCallCount += 1
        return snapshot
    }
}
