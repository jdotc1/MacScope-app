import Foundation
import XCTest

@testable import MacScope

@MainActor
final class DebuggerPersistentLLDBTargetlessTransportPlanTests: XCTestCase {
    private let selectedDeveloperDirectory = "/Applications/Xcode.app/Contents/Developer"

    func testPlanFreezesTargetlessAsyncInterpreterStartup() throws {
        let plan = try makePlan(timeout: .seconds(9))

        XCTAssertEqual(plan.timeout, .seconds(9))
        XCTAssertEqual(
            plan.processLaunchPlan.arguments,
            [
                "--no-lldbinit",
                "--one-line",
                "settings set interpreter.echo-commands false",
                "--one-line",
                PersistentLLDBCLIProcessLaunchPlan.requireAsyncModeCommand,
            ]
        )
        XCTAssertTrue(plan.processLaunchPlan.usesMergedOrderedOutput)

        let startupText = plan.processLaunchPlan.arguments.joined(separator: "\n").lowercased()
        for targetCommand in [
            "target create",
            "process attach",
            "process launch",
            "process detach",
            "process kill",
            "quit",
        ] {
            XCTAssertFalse(
                startupText.contains(targetCommand),
                "Targetless process startup must not contain \(targetCommand)."
            )
        }
    }

    func testPlanUsesSelectedXcodeAndCarriesOnlyReviewedEnvironment() throws {
        let plan = try makePlan(
            environment: [
                "HOME": "/Users/tester",
                "USER": "tester",
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "DEVELOPER_DIR": "/Applications/Unselected.app/Contents/Developer",
                "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
                "SSH_AUTH_SOCK": "/tmp/private-agent",
                "API_SECRET": "must-not-cross",
                "TERM": "xterm-secret",
                "NSUnbufferedIO": "NO",
            ]
        )

        XCTAssertEqual(
            plan.processLaunchPlan.executablePath,
            selectedDeveloperDirectory + "/usr/bin/lldb"
        )
        XCTAssertEqual(
            plan.processLaunchPlan.environment["DEVELOPER_DIR"],
            selectedDeveloperDirectory
        )
        XCTAssertEqual(plan.processLaunchPlan.environment["HOME"], "/Users/tester")
        XCTAssertEqual(plan.processLaunchPlan.environment["USER"], "tester")
        XCTAssertEqual(plan.processLaunchPlan.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(plan.processLaunchPlan.environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(plan.processLaunchPlan.environment["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(plan.processLaunchPlan.environment["TERM"], "dumb")
        XCTAssertEqual(plan.processLaunchPlan.environment["NSUnbufferedIO"], "YES")
        XCTAssertNil(plan.processLaunchPlan.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(plan.processLaunchPlan.environment["SSH_AUTH_SOCK"])
        XCTAssertNil(plan.processLaunchPlan.environment["API_SECRET"])
    }

    func testPlanRejectsNonpositiveTimeoutAndInvalidWorkingDirectories() {
        XCTAssertThrowsError(try makePlan(timeout: .zero))
        XCTAssertThrowsError(try makePlan(timeout: .milliseconds(-1)))
        XCTAssertThrowsError(try makePlan(fallbackWorkingDirectory: "relative/path"))
        XCTAssertThrowsError(try makePlan(
            fallbackWorkingDirectory: "/tmp/MacScopeMissingTargetlessWorkingDirectory"
        ))
    }

    func testFactoryCreatesInitialNoTargetTransportWithoutWriting() async throws {
        let epoch = DebuggerSessionEpoch(
            rawValue: UUID(uuidString: "92929292-9292-9292-9292-929292929292")!
        )
        let channel = TargetlessTransportProcessChannel()
        let factory = PersistentLLDBTargetlessTransportFactory { processPlan in
            XCTAssertEqual(
                processPlan.arguments,
                [
                    "--no-lldbinit",
                    "--one-line",
                    "settings set interpreter.echo-commands false",
                    "--one-line",
                    PersistentLLDBCLIProcessLaunchPlan.requireAsyncModeCommand,
                ]
            )
            return channel
        }

        let transport = try await acquiredTransport(
            from: factory,
            plan: makePlan(timeout: .seconds(11)),
            epoch: epoch
        )
        let binding = await transport.adapter.adapterInstanceBinding()
        let adapterState = await transport.adapter.state
        let reducerState = await transport.coordinator.reducerState
        let writes = await channel.writes
        let lifecycleCalls = await channel.lifecycleCalls

        XCTAssertEqual(transport.epoch, epoch)
        XCTAssertEqual(transport.adapterGeneration, 1)
        XCTAssertEqual(transport.timeout, .seconds(11))
        XCTAssertEqual(binding.sessionEpoch, epoch)
        XCTAssertEqual(binding.adapterGeneration, transport.adapterGeneration)
        XCTAssertEqual(adapterState, .active(generation: 1))
        XCTAssertEqual(reducerState.epoch, epoch)
        XCTAssertEqual(reducerState.processPhase, .noTarget)
        XCTAssertNil(reducerState.observedProcessID)
        XCTAssertNil(reducerState.acceptedTargetAuthority)
        XCTAssertNil(reducerState.pendingRequest)
        XCTAssertEqual(reducerState.targetDisposition, .notStarted)
        XCTAssertEqual(
            reducerState.capabilities.capability(for: .launch),
            .policyDenied(reason: "A targetless exact-attach transport cannot launch a process.")
        )
        XCTAssertEqual(
            reducerState.capabilities.capability(for: .attach),
            .supportedAndObserved
        )
        guard case .policyDenied = reducerState.capabilities.capability(for: .terminate) else {
            return XCTFail("A targetless exact-attach transport must not terminate a target.")
        }
        XCTAssertEqual(writes, [])
        XCTAssertEqual(lifecycleCalls, [])
    }

    func testFactoryInjectsExactAttachDependenciesOrRemainsExplicitlyFailClosed() async throws {
        let interlock = makeInterlock()
        let evidenceProvider = TargetlessTransportEvidenceProvider()
        let exactChannel = TargetlessTransportProcessChannel()
        let exactFactory = PersistentLLDBTargetlessTransportFactory(
            attachWriteInterlock: interlock,
            localProcessEvidenceProvider: evidenceProvider
        ) { _ in exactChannel }
        let exactTransport = try await acquiredTransport(
            from: exactFactory,
            plan: makePlan(),
            epoch: DebuggerSessionEpoch()
        )

        XCTAssertTrue(exactTransport.attachWriteInterlock === interlock)
        guard let retainedEvidenceProvider = exactTransport.localProcessEvidenceProvider else {
            return XCTFail("Exact construction must retain the injected evidence provider.")
        }
        XCTAssertEqual(
            ObjectIdentifier(retainedEvidenceProvider as AnyObject),
            ObjectIdentifier(evidenceProvider)
        )

        let failClosedChannel = TargetlessTransportProcessChannel()
        let failClosedFactory = PersistentLLDBTargetlessTransportFactory { _ in
            failClosedChannel
        }
        let failClosedTransport = try await acquiredTransport(
            from: failClosedFactory,
            plan: makePlan(),
            epoch: DebuggerSessionEpoch()
        )

        XCTAssertNil(failClosedTransport.attachWriteInterlock)
        XCTAssertNil(failClosedTransport.localProcessEvidenceProvider)
    }

    func testProductionFactoryRetainsExactOwnedRegistryInterlockAndEvidenceProvider() {
        let interlock = makeInterlock()
        let registry = DebuggerOwnedInfrastructureRegistry(
            attachWriteInterlock: interlock
        )
        let evidenceProvider = TargetlessTransportEvidenceProvider()
        let factory = PersistentLLDBTargetlessTransportFactory(
            ownedInfrastructureRegistry: registry,
            localProcessEvidenceProvider: evidenceProvider
        )

        XCTAssertEqual(
            factory.ownedInfrastructureRegistryIdentityForTesting,
            ObjectIdentifier(registry)
        )
        XCTAssertEqual(factory.attachWriteInterlockIdentityForTesting, interlock.identity)
        XCTAssertTrue(factory.localProcessEvidenceProviderIsAvailableForTesting)
    }

    func testAlreadyCancelledFactoryDoesNotInvokeProcessLauncher() async throws {
        let startGate = TargetlessTransportSuspensionGate()
        let launcherProbe = TargetlessTransportLauncherProbe()
        let channel = TargetlessTransportProcessChannel()
        let factory = PersistentLLDBTargetlessTransportFactory { _ in
            await launcherProbe.recordInvocation()
            return channel
        }
        let plan = try makePlan()
        let epoch = DebuggerSessionEpoch()
        let construction = Task {
            await startGate.suspend()
            return try await factory.make(plan: plan, epoch: epoch)
        }

        await startGate.waitUntilSuspended()
        construction.cancel()
        await startGate.resume()

        do {
            _ = try await construction.value
            XCTFail("An already-cancelled factory task must fail before process launch.")
        } catch is CancellationError {
            // Expected fail-closed cancellation.
        }

        let invocationCount = await launcherProbe.invocationCount
        let writes = await channel.writes
        let lifecycleCalls = await channel.lifecycleCalls
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(writes, [])
        XCTAssertEqual(lifecycleCalls, [])
    }

    func testCancellationAfterChannelAcquisitionRetiresAdapterWithoutDebuggerCommand() async throws {
        let launcherGate = TargetlessTransportSuspensionGate()
        let channel = TargetlessTransportProcessChannel(exitResults: [false, true])
        let factory = PersistentLLDBTargetlessTransportFactory { _ in
            await launcherGate.suspend()
            return channel
        }
        let plan = try makePlan()
        let epoch = DebuggerSessionEpoch()
        let construction = Task {
            try await factory.make(plan: plan, epoch: epoch)
        }

        await launcherGate.waitUntilSuspended()
        construction.cancel()
        await launcherGate.resume()

        do {
            _ = try await construction.value
            XCTFail("Cancellation after acquisition must not publish a targetless transport.")
        } catch is CancellationError {
            // Expected after command-free retained-adapter retirement.
        }

        let writes = await channel.writes
        let lifecycleCalls = await channel.lifecycleCalls
        let waitCancellationStates = await channel.waitCancellationStates
        XCTAssertEqual(writes, [])
        XCTAssertEqual(waitCancellationStates, [false, false])
        XCTAssertEqual(
            lifecycleCalls,
            [
                .closeInput,
                .waitForExit(PersistentLLDBCLIAdapter.defaultRetirementStdinEOFGracePeriod),
                .terminate,
                .waitForExit(.seconds(1)),
                .reap,
                .closeHandles,
            ]
        )
    }

    func testUnprovenCancellationRetirementReturnsExactRetainedAdapterOwnership() async throws {
        let launcherGate = TargetlessTransportSuspensionGate()
        let channel = TargetlessTransportProcessChannel(
            exitResults: [false, false, false, false],
            reapResult: false
        )
        let factory = PersistentLLDBTargetlessTransportFactory { _ in
            await launcherGate.suspend()
            return channel
        }
        let construction = Task {
            try await factory.make(plan: makePlan(), epoch: DebuggerSessionEpoch())
        }

        await launcherGate.waitUntilSuspended()
        construction.cancel()
        await launcherGate.resume()

        let outcome = try await construction.value
        guard case let .unresolved(failure, retainedAdapter) = outcome else {
            return XCTFail("Unproven retirement must return exact retained adapter ownership.")
        }
        XCTAssertEqual(failure, .cancelled)
        let binding = await retainedAdapter.adapterInstanceBinding()
        let writes = await channel.writes
        let lifecycleCalls = await channel.lifecycleCalls
        XCTAssertEqual(binding.adapterGeneration, 1)
        XCTAssertEqual(writes, [])
        XCTAssertEqual(
            lifecycleCalls,
            [
                .closeInput,
                .waitForExit(PersistentLLDBCLIAdapter.defaultRetirementStdinEOFGracePeriod),
                .terminate,
                .waitForExit(.seconds(1)),
                .kill,
                .waitForExit(.seconds(1)),
                .reap,
                .closeHandles,
            ]
        )
    }

    func testConstructedTargetlessTransportSupportsCommandFreeRetirement() async throws {
        // LLDB outlives the stdin-EOF grace period, so retirement escalates to SIGTERM.
        let channel = TargetlessTransportProcessChannel(exitResults: [false, true])
        let factory = PersistentLLDBTargetlessTransportFactory { _ in channel }
        let transport = try await acquiredTransport(
            from: factory,
            plan: makePlan(),
            epoch: DebuggerSessionEpoch()
        )

        let receipt = await transport.adapter.retireRetainedAdapterWithoutDebuggerCommand()
        let writes = await channel.writes
        let lifecycleCalls = await channel.lifecycleCalls
        let waitCancellationStates = await channel.waitCancellationStates

        XCTAssertFalse(receipt.requestedGracefulQuit)
        XCTAssertTrue(receipt.sentTerminate)
        XCTAssertFalse(receipt.sentKill)
        XCTAssertTrue(receipt.didExit)
        XCTAssertTrue(receipt.didReap)
        XCTAssertEqual(writes, [])
        XCTAssertEqual(waitCancellationStates, [false, false])
        XCTAssertEqual(
            lifecycleCalls,
            [
                .closeInput,
                .waitForExit(PersistentLLDBCLIAdapter.defaultRetirementStdinEOFGracePeriod),
                .terminate,
                .waitForExit(.seconds(1)),
                .reap,
                .closeHandles,
            ]
        )
    }

    private func makePlan(
        environment: [String: String] = [:],
        fallbackWorkingDirectory: String = "/tmp",
        timeout: Duration = .seconds(7)
    ) throws -> PersistentLLDBTargetlessTransportPlan {
        try PersistentLLDBTargetlessTransportPlan.make(
            toolchain: DebuggerLLDBToolchain(
                executablePath: selectedDeveloperDirectory + "/usr/bin/lldb",
                developerDirectory: selectedDeveloperDirectory,
                discoverySource: "test",
                candidatePaths: []
            ),
            environment: environment,
            fallbackWorkingDirectory: fallbackWorkingDirectory,
            timeout: timeout
        )
    }

    private func acquiredTransport(
        from factory: PersistentLLDBTargetlessTransportFactory,
        plan: PersistentLLDBTargetlessTransportPlan,
        epoch: DebuggerSessionEpoch
    ) async throws -> PersistentLLDBTargetlessTransport {
        let outcome = try await factory.make(plan: plan, epoch: epoch)
        guard case let .acquired(transport) = outcome else {
            throw DebuggerClientError.backendFailure(
                "Expected targetless test transport construction to acquire ownership."
            )
        }
        return transport
    }

    private func makeInterlock() -> DebuggerLocalProcessAttachWriteInterlock {
        DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
    }
}

private actor TargetlessTransportProcessChannel: PersistentLLDBTargetlessProcessChannel {
    enum LifecycleCall: Equatable {
        case closeInput
        case closeHandles
        case waitForExit(Duration)
        case terminate
        case kill
        case reap
    }

    private(set) var writes: [Data] = []
    private(set) var lifecycleCalls: [LifecycleCall] = []
    private(set) var waitCancellationStates: [Bool] = []
    private var exitResults: [Bool]
    private let reapResult: Bool

    init(exitResults: [Bool] = [true], reapResult: Bool = true) {
        self.exitResults = exitResults
        self.reapResult = reapResult
    }

    func write(_ data: Data) async throws {
        writes.append(data)
    }

    func nextBytes() async throws -> Data? {
        nil
    }

    func closeInput() async {
        lifecycleCalls.append(.closeInput)
    }

    func closeHandles() async {
        lifecycleCalls.append(.closeHandles)
    }

    func waitForExit(maximumDuration: Duration) async -> Bool {
        let wasCancelled = Task.isCancelled
        lifecycleCalls.append(.waitForExit(maximumDuration))
        waitCancellationStates.append(wasCancelled)
        guard !wasCancelled else { return false }
        return exitResults.isEmpty ? false : exitResults.removeFirst()
    }

    func terminateRetainedAdapter() async {
        lifecycleCalls.append(.terminate)
    }

    func killRetainedAdapterIfStillRunning() async -> Bool {
        lifecycleCalls.append(.kill)
        return true
    }

    func reapAndClose() async -> Bool {
        lifecycleCalls.append(.reap)
        return reapResult
    }
}

private actor TargetlessTransportEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        .unknown(.unstableSnapshot)
    }

    func catalogEvidence(
        processID _: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        .unknown(.unstableSnapshot)
    }

    func authorizationEvidence(
        processID _: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        .unknown(.unstableSnapshot)
    }
}

private actor TargetlessTransportLauncherProbe {
    private(set) var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }
}

private actor TargetlessTransportSuspensionGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
            isSuspended = true
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        isSuspended = false
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}
