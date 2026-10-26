import Foundation
import XCTest
@testable import MacScope

@MainActor
final class DebuggerPersistentProductionProjectionTests: XCTestCase {
    func testSharedLeaseRegistryDoesNotAdvertiseProductionAttachCapability() {
        let registry = DebuggerSessionLeaseRegistry()
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            toolchain: DebuggerLLDBToolchain(
                executablePath: "/usr/bin/false",
                developerDirectory: nil,
                discoverySource: "test",
                candidatePaths: ["/usr/bin/false"]
            ),
            processRunner: LeaseAuthorityProjectionProcessRunner(),
            environment: [:],
            workingDirectory: "/tmp",
            usePersistentTransport: true,
            debuggerSessionLeaseRegistry: registry
        ))

        XCTAssertEqual(client.sessionLeaseAuthorityForTesting?.isAvailable, true)
        XCTAssertEqual(
            client.sessionLeaseAuthorityForTesting?.registryIdentity,
            ObjectIdentifier(registry)
        )
        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertEqual(
            client.capabilities.attachSupport,
            .unsupported(reason: XcodeLLDBCommandLineAdapter.attachUnsupportedReason)
        )
        XCTAssertEqual(
            client.persistentRuntimeAuthorityProjectionForTesting?
                .observationPolicyProviderIsAvailable,
            false
        )
        XCTAssertEqual(
            client.persistentRuntimeAuthorityProjectionForTesting?
                .isObservationPolicyAuthorityReady,
            false
        )
    }

    func testCompletePolicyAuthorityAdvertisesExactAttachOnly() async throws {
        let interlock = policyProjectionInterlock()
        let leaseRegistry = DebuggerSessionLeaseRegistry(
            attachWriteInterlock: interlock
        )
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            attachWriteInterlock: interlock
        )
        let policyProvider = DebuggerLocalProcessObservationPolicyProvider(
            ownedInfrastructureRegistry: ownedRegistry,
            sessionLeaseRegistry: leaseRegistry,
            attachWriteInterlock: interlock
        )
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            toolchain: DebuggerLLDBToolchain(
                executablePath: "/usr/bin/false",
                developerDirectory: nil,
                discoverySource: "test",
                candidatePaths: ["/usr/bin/false"]
            ),
            processRunner: LeaseAuthorityProjectionProcessRunner(),
            environment: [:],
            workingDirectory: "/tmp",
            usePersistentTransport: true,
            debuggerSessionLeaseRegistry: leaseRegistry,
            ownedInfrastructureRegistry: ownedRegistry,
            observationPolicyProvider: policyProvider
        ))

        let projection = try XCTUnwrap(
            client.persistentRuntimeAuthorityProjectionForTesting
        )
        XCTAssertTrue(projection.observationPolicyProviderIsAvailable)
        XCTAssertTrue(projection.isObservationPolicyAuthorityReady)
        let policySnapshot = await client.observationPolicySnapshotForTesting()
        XCTAssertNotNil(policySnapshot)
        XCTAssertTrue(client.capabilities.launchSupport.isSupported)
        XCTAssertTrue(client.capabilities.canAttach)
        XCTAssertTrue(client.capabilities.attachSupport.isSupported)
        XCTAssertTrue(
            client.capabilities.limitations.contains {
                $0.contains("Exact local-process attach")
            }
        )
    }

    func testSameGraphWrongHostPolicyProvidersRemainAttachUnready() async throws {
        let interlock = policyProjectionInterlock()
        let leaseRegistry = DebuggerSessionLeaseRegistry(
            attachWriteInterlock: interlock
        )
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            attachWriteInterlock: interlock
        )
        let current = DebuggerLocalProcessObservationPolicyHostIdentity.current
        let wrongIdentities = [
            DebuggerLocalProcessObservationPolicyHostIdentity(
                realUserID: different(current.realUserID),
                effectiveUserID: current.effectiveUserID,
                processID: current.processID
            ),
            DebuggerLocalProcessObservationPolicyHostIdentity(
                realUserID: current.realUserID,
                effectiveUserID: different(current.effectiveUserID),
                processID: current.processID
            ),
            DebuggerLocalProcessObservationPolicyHostIdentity(
                realUserID: current.realUserID,
                effectiveUserID: current.effectiveUserID,
                processID: different(current.processID)
            ),
        ]

        for identity in wrongIdentities {
            let forgedAuthorityProjection = PersistentLLDBRuntimeAuthorityProjection(
                sessionLeaseRegistryIdentity: ObjectIdentifier(leaseRegistry),
                sessionLeaseInterlockIdentity: interlock.identity,
                ownedProcessLauncherRegistryIdentity: ObjectIdentifier(ownedRegistry),
                targetlessTransportFactoryRegistryIdentity: ObjectIdentifier(ownedRegistry),
                ownedInfrastructureInterlockIdentity: interlock.identity,
                observationPolicyProviderIsAvailable: true,
                observationPolicyRegistryAuthority:
                    DebuggerLocalProcessObservationPolicyRegistryAuthority(
                        ownedInfrastructureRegistryID: ObjectIdentifier(ownedRegistry),
                        sessionLeaseRegistryID: ObjectIdentifier(leaseRegistry),
                        attachWriteInterlockIdentity: interlock.identity,
                        hostIdentity: identity
                    )
            )
            XCTAssertFalse(forgedAuthorityProjection.isObservationPolicyAuthorityReady)

            let provider = DebuggerLocalProcessObservationPolicyProvider(
                ownedInfrastructureRegistry: ownedRegistry,
                sessionLeaseRegistry: leaseRegistry,
                attachWriteInterlock: interlock,
                hostRealUserID: identity.realUserID,
                hostEffectiveUserID: identity.effectiveUserID,
                hostProcessID: identity.processID
            )
            let client = policyProjectionClient(
                leaseRegistry: leaseRegistry,
                ownedRegistry: ownedRegistry,
                provider: provider
            )

            let projection = try XCTUnwrap(
                client.persistentRuntimeAuthorityProjectionForTesting
            )
            XCTAssertTrue(projection.observationPolicyProviderIsAvailable)
            XCTAssertNil(projection.observationPolicyRegistryAuthority)
            XCTAssertFalse(projection.isObservationPolicyAuthorityReady)
            let policySnapshot = await client.observationPolicySnapshotForTesting()
            XCTAssertEqual(policySnapshot?.denial, .unstableSnapshot)
            XCTAssertTrue(client.capabilities.launchSupport.isSupported)
            XCTAssertFalse(client.capabilities.canAttach)
            XCTAssertFalse(client.capabilities.attachSupport.isSupported)
        }
    }

    func testMissingPolicyProviderKeepsLaunchAvailableButAttachUnready() throws {
        let interlock = policyProjectionInterlock()
        let leaseRegistry = DebuggerSessionLeaseRegistry(
            attachWriteInterlock: interlock
        )
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            attachWriteInterlock: interlock
        )
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            toolchain: DebuggerLLDBToolchain(
                executablePath: "/usr/bin/false",
                developerDirectory: nil,
                discoverySource: "test",
                candidatePaths: ["/usr/bin/false"]
            ),
            processRunner: LeaseAuthorityProjectionProcessRunner(),
            environment: [:],
            workingDirectory: "/tmp",
            usePersistentTransport: true,
            debuggerSessionLeaseRegistry: leaseRegistry,
            ownedInfrastructureRegistry: ownedRegistry
        ))

        let projection = try XCTUnwrap(
            client.persistentRuntimeAuthorityProjectionForTesting
        )
        XCTAssertFalse(projection.observationPolicyProviderIsAvailable)
        XCTAssertFalse(projection.isObservationPolicyAuthorityReady)
        XCTAssertTrue(client.capabilities.launchSupport.isSupported)
        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertFalse(client.capabilities.attachSupport.isSupported)
    }

    func testCrossedRegistryProviderFailsClosedWithoutBreakingLaunch() throws {
        let injectedInterlock = policyProjectionInterlock()
        let injectedLeaseRegistry = DebuggerSessionLeaseRegistry(
            attachWriteInterlock: injectedInterlock
        )
        let injectedOwnedRegistry = DebuggerOwnedInfrastructureRegistry(
            attachWriteInterlock: injectedInterlock
        )
        let foreignInterlock = policyProjectionInterlock()
        let foreignLeaseRegistry = DebuggerSessionLeaseRegistry(
            attachWriteInterlock: foreignInterlock
        )
        let foreignOwnedRegistry = DebuggerOwnedInfrastructureRegistry(
            attachWriteInterlock: foreignInterlock
        )
        let foreignProvider = DebuggerLocalProcessObservationPolicyProvider(
            ownedInfrastructureRegistry: foreignOwnedRegistry,
            sessionLeaseRegistry: foreignLeaseRegistry,
            attachWriteInterlock: foreignInterlock
        )
        let client = policyProjectionClient(
            leaseRegistry: injectedLeaseRegistry,
            ownedRegistry: injectedOwnedRegistry,
            provider: foreignProvider
        )

        let projection = try XCTUnwrap(
            client.persistentRuntimeAuthorityProjectionForTesting
        )
        XCTAssertTrue(projection.observationPolicyProviderIsAvailable)
        XCTAssertNotNil(projection.observationPolicyRegistryAuthority)
        XCTAssertFalse(projection.isObservationPolicyAuthorityReady)
        XCTAssertTrue(client.capabilities.launchSupport.isSupported)
        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertFalse(client.capabilities.attachSupport.isSupported)
    }

    func testScriptedProviderFailsClosedWithoutBreakingLaunch() throws {
        let interlock = policyProjectionInterlock()
        let leaseRegistry = DebuggerSessionLeaseRegistry(
            attachWriteInterlock: interlock
        )
        let ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            attachWriteInterlock: interlock
        )
        let scriptedProvider = DebuggerLocalProcessObservationPolicyProvider(
            source: ProjectionScriptedPolicySource(),
            attachWriteInterlock: interlock
        )
        let client = policyProjectionClient(
            leaseRegistry: leaseRegistry,
            ownedRegistry: ownedRegistry,
            provider: scriptedProvider
        )

        let projection = try XCTUnwrap(
            client.persistentRuntimeAuthorityProjectionForTesting
        )
        XCTAssertTrue(projection.observationPolicyProviderIsAvailable)
        XCTAssertNil(projection.observationPolicyRegistryAuthority)
        XCTAssertFalse(projection.isObservationPolicyAuthorityReady)
        XCTAssertTrue(client.capabilities.launchSupport.isSupported)
        XCTAssertFalse(client.capabilities.canAttach)
        XCTAssertFalse(client.capabilities.attachSupport.isSupported)
    }

    func testSharedLeaseRegistryIdentityAndStableControllerOwnerAreInjectedWithoutSynthesis() {
        let registry = DebuggerSessionLeaseRegistry()
        let toolchain = DebuggerLLDBToolchain(
            executablePath: "/usr/bin/false",
            developerDirectory: nil,
            discoverySource: "test",
            candidatePaths: ["/usr/bin/false"]
        )
        let firstClient = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            toolchain: toolchain,
            processRunner: LeaseAuthorityProjectionProcessRunner(),
            environment: [:],
            workingDirectory: "/tmp",
            usePersistentTransport: true,
            debuggerSessionLeaseRegistry: registry
        ))
        let secondClient = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            toolchain: toolchain,
            processRunner: LeaseAuthorityProjectionProcessRunner(),
            environment: [:],
            workingDirectory: "/tmp",
            usePersistentTransport: true,
            debuggerSessionLeaseRegistry: registry
        ))

        let first = firstClient.sessionLeaseAuthorityForTesting
        let repeatedFirst = firstClient.sessionLeaseAuthorityForTesting
        let second = secondClient.sessionLeaseAuthorityForTesting

        XCTAssertEqual(first?.registryIdentity, ObjectIdentifier(registry))
        XCTAssertEqual(repeatedFirst, first)
        XCTAssertEqual(second?.registryIdentity, ObjectIdentifier(registry))
        XCTAssertNotEqual(first?.ownerID, second?.ownerID)
        XCTAssertEqual(first?.isAvailable, true)

        let unavailable = XcodeLLDBCommandLineAdapter(
            toolchain: toolchain,
            processRunner: LeaseAuthorityProjectionProcessRunner(),
            environment: [:],
            workingDirectory: "/tmp",
            usePersistentTransport: true
        ).sessionLeaseAuthorityForTesting

        XCTAssertEqual(unavailable?.isAvailable, false)
        XCTAssertNil(unavailable?.registryIdentity)
        XCTAssertNotNil(unavailable?.ownerID)
    }

    func testSecondLaunchCannotEnterPreflightWhileFirstLaunchIsSuspended() async {
        let probe = SuspendedProductionLaunchGateProbe()
        let controller = PersistentLLDBProductionController(
            toolchain: DebuggerLLDBToolchain(
                executablePath: "/usr/bin/false",
                developerDirectory: nil,
                discoverySource: "test",
                candidatePaths: ["/usr/bin/false"]
            ),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            commandTimeoutSeconds: 1,
            launchGateProbe: { await probe.enter() }
        )
        let invalid = DebuggerLaunchConfiguration(executablePath: "")

        let first = Task { try? await controller.launch(invalid) }
        await probe.waitForEntryCount(1)
        let second = Task { try? await controller.launch(invalid) }
        for _ in 0..<20 { await Task.yield() }

        let entryCountWhileFirstIsSuspended = await probe.entryCount
        XCTAssertEqual(entryCountWhileFirstIsSuspended, 1)

        await probe.resumeNext()
        await probe.waitForEntryCount(2)
        await probe.resumeNext()
        _ = await first.value
        _ = await second.value
    }

    func testCancelledQueuedLaunchNeverEntersPreflightOrCreatesAnLLDBChild() async {
        let gate = SuspendedProductionLaunchGateProbe()
        let launcher = ProductionLaunchProcessLauncherProbe()
        let controller = PersistentLLDBProductionController(
            toolchain: productionLaunchTestToolchain(),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            commandTimeoutSeconds: 1,
            launchGateProbe: { await gate.enter() },
            processChannelLauncher: { plan in
                .acquired(await launcher.launch(plan))
            }
        )
        let invalid = DebuggerLaunchConfiguration(executablePath: "")

        let first = Task { try? await controller.launch(invalid) }
        await gate.waitForEntryCount(1)
        let queued = Task { try await controller.launch(invalid) }
        for _ in 0..<20 { await Task.yield() }
        queued.cancel()

        await gate.resumeNext()
        _ = await first.value

        do {
            _ = try await queued.value
            XCTFail("A cancelled queued launch must fail before preflight.")
        } catch is CancellationError {
            // Expected fail-closed cancellation after the operation gate is acquired.
        } catch {
            XCTFail("Unexpected queued-launch error: \(error)")
        }

        let finalEntryCount = await gate.entryCount
        let invocationCount = await launcher.invocationCount
        XCTAssertEqual(finalEntryCount, 1)
        XCTAssertEqual(invocationCount, 0)
    }

    func testShutdownFencesSuspendedLaunchAndCannotResurrectController() async {
        let gate = SuspendedProductionLaunchGateProbe()
        let launcher = ProductionLaunchProcessLauncherProbe()
        let controller = PersistentLLDBProductionController(
            toolchain: productionLaunchTestToolchain(),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            commandTimeoutSeconds: 1,
            launchGateProbe: { await gate.enter() },
            processChannelLauncher: { plan in
                .acquired(await launcher.launch(plan))
            }
        )
        let configuration = DebuggerLaunchConfiguration(executablePath: "/bin/echo")

        let launch = Task { try await controller.launch(configuration) }
        await gate.waitForEntryCount(1)
        let firstShutdown = Task { await controller.shutdown() }
        while !controller.isRetirementRequestedForTesting { await Task.yield() }
        let coalescedShutdown = Task { await controller.shutdown() }

        await gate.resumeNext()
        do {
            _ = try await launch.value
            XCTFail("A launch suspended across retirement must not publish or spawn.")
        } catch {
            // Retirement is an authority fence; its exact public error text is not authority.
        }
        await firstShutdown.value
        await coalescedShutdown.value

        do {
            _ = try await controller.launch(configuration)
            XCTFail("A retired controller must never admit a new launch.")
        } catch {
            // Expected permanent retirement fence.
        }

        let entryCount = await gate.entryCount
        let invocationCount = await launcher.invocationCount
        XCTAssertEqual(entryCount, 1)
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(controller.retirementDrainCountForTesting, 1)
    }

    func testCancellationAfterLLDBChildCreationPerformsAwaitedCommandFreeExitAndReap() async {
        // LLDB outlives the stdin-EOF grace period, so retirement escalates to SIGTERM.
        let channel = ProductionLaunchProcessChannel(
            waitForExitResults: [false, true],
            suspendFirstWaitForExit: true
        )
        let launcher = ProductionLaunchProcessLauncherProbe(
            channel: channel,
            suspendAfterCreation: true
        )
        let completion = ProductionLaunchCompletionProbe()
        let controller = PersistentLLDBProductionController(
            toolchain: productionLaunchTestToolchain(),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            commandTimeoutSeconds: 1,
            processChannelLauncher: { plan in
                .acquired(await launcher.launch(plan))
            }
        )
        let launch = Task {
            do {
                let snapshot = try await controller.launch(
                    DebuggerLaunchConfiguration(executablePath: "/bin/echo")
                )
                await completion.recordCompletion()
                return snapshot
            } catch {
                await completion.recordCompletion()
                throw error
            }
        }

        await launcher.waitUntilChildCreated()
        launch.cancel()
        await launcher.resumeAfterCreation()
        await channel.waitUntilWaitForExitStarts()
        for _ in 0..<20 { await Task.yield() }
        let completedBeforeCleanup = await completion.isComplete
        XCTAssertFalse(completedBeforeCleanup)
        await channel.resumeWaitForExit()

        do {
            _ = try await launch.value
            XCTFail("Cancellation after LLDB creation must not dispatch a debugger command.")
        } catch is CancellationError {
            // Expected only after awaited command-free exact-child retirement.
        } catch {
            XCTFail("Unexpected post-creation cancellation error: \(error)")
        }

        let writes = await channel.writes
        let waitCancellationStates = await channel.waitCancellationStates
        let lifecycleCalls = await channel.lifecycleCalls
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

    func testPostSpawnLauncherFailureReturnsOwnershipForCommandFreeRetirement() async {
        let channel = ProductionLaunchProcessChannel(waitForExitResults: [false, true])
        let controller = PersistentLLDBProductionController(
            toolchain: productionLaunchTestToolchain(),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            commandTimeoutSeconds: 1,
            processChannelLauncher: { _ in
                .failedAfterChild(
                    channel: channel,
                    reason: "synthetic post-spawn failure"
                )
            }
        )

        do {
            _ = try await controller.launch(
                DebuggerLaunchConfiguration(executablePath: "/bin/echo")
            )
            XCTFail("A post-spawn launcher failure must fail after exact-child retirement.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .backendFailure(
                    "Persistent Xcode LLDB could not start: synthetic post-spawn failure"
                )
            )
        } catch {
            XCTFail("Unexpected post-spawn launcher error: \(error)")
        }

        let writes = await channel.writes
        let lifecycleCalls = await channel.lifecycleCalls
        XCTAssertEqual(writes, [])
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

    func testUnprovenPostSpawnRetirementPinsAdapterAndBlocksRelaunch() async {
        let channel = ProductionLaunchProcessChannel(
            waitForExitResults: [false, false],
            reapResult: false
        )
        let launcher = ProductionLaunchProcessLauncherProbe(
            channel: channel,
            suspendAfterCreation: true
        )
        let controller = PersistentLLDBProductionController(
            toolchain: productionLaunchTestToolchain(),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            commandTimeoutSeconds: 1,
            processChannelLauncher: { plan in
                .acquired(await launcher.launch(plan))
            }
        )
        let first = Task {
            try await controller.launch(
                DebuggerLaunchConfiguration(executablePath: "/bin/echo")
            )
        }

        await launcher.waitUntilChildCreated()
        first.cancel()
        await launcher.resumeAfterCreation()

        do {
            _ = try await first.value
            XCTFail("Unproven command-free cleanup must fail closed.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .backendUnavailable(
                    "The cancelled LLDB child could not be proven exited and reaped; restart MacScope before launching another target."
                )
            )
        } catch {
            XCTFail("Unexpected unproven-retirement error: \(error)")
        }

        do {
            _ = try await controller.launch(
                DebuggerLaunchConfiguration(executablePath: "/bin/echo")
            )
            XCTFail("Pinned unproven adapter authority must block a later launch.")
        } catch let error as DebuggerClientError {
            XCTAssertEqual(
                error,
                .backendUnavailable(
                    "A prior LLDB child lacks proven command-free exit and reap; restart MacScope before launching another target."
                )
            )
        } catch {
            XCTFail("Unexpected blocked-relaunch error: \(error)")
        }

        let invocationCount = await launcher.invocationCount
        let writes = await channel.writes
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(writes, [])
    }

    /// Tier 2b regression: the final `process launch` exchange answered without an observable PID
    /// (Xcode 27 LLDB's pinned pre-launch `script` context) invalidated the adapter, and recovery
    /// then recorded an unresolved `adapterInterruption` blocker. Every later Launch Target was
    /// refused with "...left without exact terminal disposition proof." A launch that never
    /// accepted a target PID must settle on proven command-free LLDB retirement and admit a
    /// fresh launch.
    func testUnacceptedLaunchAdapterInvalidationSettlesAndAdmitsFreshLaunch() async {
        let firstChannel = ScriptedLaunchProcessChannel()
        let secondChannel = ScriptedLaunchProcessChannel()
        let channels = ScriptedLaunchChannelQueue([firstChannel, secondChannel])
        let controller = PersistentLLDBProductionController(
            toolchain: productionLaunchTestToolchain(),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            commandTimeoutSeconds: 5,
            processChannelLauncher: { _ in
                .acquired(await channels.next())
            }
        )
        let expected = DebuggerClientError.backendFailure(
            "Launch failed in the correlated LLDB session (adapterInvalidated: the LLDB "
                + "response failed transcript validation (missingObservedPID))."
        )

        for attempt in 0..<2 {
            do {
                _ = try await controller.launch(
                    DebuggerLaunchConfiguration(executablePath: "/bin/echo")
                )
                XCTFail("Attempt \(attempt): a PID-less launch readback must not succeed.")
            } catch let error as DebuggerClientError {
                XCTAssertEqual(error, expected, "attempt \(attempt)")
            } catch {
                XCTFail("Attempt \(attempt): unexpected launch error \(error)")
            }
        }

        let launched = await channels.launchedCount
        XCTAssertEqual(launched, 2, "The second launch must reach a fresh LLDB child.")
        for channel in [firstChannel, secondChannel] {
            let sawFinalLaunch = await channel.sawFinalLaunchCommand
            let lifecycle = await channel.lifecycleCalls
            XCTAssertTrue(sawFinalLaunch)
            // Command-free retirement: no graceful `quit` is written; stdin closes and LLDB's own
            // EOF exit is awaited and reaped, so LLDB is never signalled.
            XCTAssertFalse(lifecycle.contains(.terminate))
            XCTAssertTrue(lifecycle.contains(.closeInput))
            XCTAssertTrue(lifecycle.contains(.waitForExit))
            XCTAssertTrue(lifecycle.contains(.reap))
        }
    }

    func testCommandFreeRetirementRequiresExitAndReapWithoutGracefulQuit() {
        XCTAssertTrue(PersistentLLDBProductionController.isProvenCommandFreeAdapterRetirement(
            PersistentLLDBCLIShutdownReceipt(
                requestedGracefulQuit: false,
                sentTerminate: true,
                sentKill: true,
                didExit: true,
                didReap: true
            )
        ))
        XCTAssertFalse(PersistentLLDBProductionController.isProvenCommandFreeAdapterRetirement(
            PersistentLLDBCLIShutdownReceipt(
                requestedGracefulQuit: false,
                sentTerminate: true,
                sentKill: true,
                didExit: false,
                didReap: true
            )
        ))
        XCTAssertFalse(PersistentLLDBProductionController.isProvenCommandFreeAdapterRetirement(
            PersistentLLDBCLIShutdownReceipt(
                requestedGracefulQuit: false,
                sentTerminate: true,
                sentKill: true,
                didExit: true,
                didReap: false
            )
        ))
        XCTAssertFalse(PersistentLLDBProductionController.isProvenCommandFreeAdapterRetirement(
            PersistentLLDBCLIShutdownReceipt(
                requestedGracefulQuit: true,
                sentTerminate: false,
                sentKill: false,
                didExit: true,
                didReap: true
            )
        ))
    }

    func testRetirementFallbackKillsOnlyTheSurvivingLaunchedDebuggee() async {
        let identity = retirementFallbackIdentity(processID: 4_321)
        let launched = DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
        let recorder = RetirementFallbackRecorder(
            reobservations: [.resolved(identity), .ineligible(.disappeared)]
        )

        let final = await PersistentLLDBProductionController
            .reobserveAfterRetirementKillingSurvivingLaunchedDebuggee(
                authority: launched,
                reobserve: { await recorder.reobserve() },
                killLaunchedDebuggee: { await recorder.kill($0) }
            )

        let events = await recorder.events
        XCTAssertEqual(events, [.reobserve, .kill(4_321), .reobserve])
        guard case .ineligible(.disappeared)? = final else {
            return XCTFail("the post-kill reobservation must be returned")
        }
    }

    func testRetirementFallbackNeverKillsAttachedGoneOrDriftedTargets() async {
        let identity = retirementFallbackIdentity(processID: 4_321)
        let drifted = retirementFallbackIdentity(processID: 4_321, startSeconds: 20_000)
        let launched = DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
        let cases: [(DebuggerSessionTargetAuthority?, DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>?)] = [
            // LLDB cleaned up its inferior during the stdin-EOF grace period.
            (launched, .ineligible(.disappeared)),
            // The PID now names a different process instance.
            (launched, .resolved(drifted)),
            (launched, nil),
            // Attached targets belong to someone else and are never signalled.
            (DebuggerSessionTargetAuthority(origin: .attached(identity)), .resolved(identity)),
            // A launch whose PID was never accepted has no recorded debuggee.
            (nil, nil),
        ]
        for (authority, reobservation) in cases {
            let recorder = RetirementFallbackRecorder(reobservations: [reobservation])
            _ = await PersistentLLDBProductionController
                .reobserveAfterRetirementKillingSurvivingLaunchedDebuggee(
                    authority: authority,
                    reobserve: { await recorder.reobserve() },
                    killLaunchedDebuggee: { await recorder.kill($0) }
                )
            let events = await recorder.events
            XCTAssertEqual(events, [.reobserve])
        }
    }

    /// Tier 2e: a failed mutation's recovery retired LLDB and the launched PID was gone, yet the
    /// controller recorded an unresolved blocker and refused every relaunch. Only an exact
    /// launched-origin ESRCH reobservation counts as absence.
    func testLaunchedTargetAbsenceAfterRetirementSettlesRecovery() {
        let identity = retirementFallbackIdentity(processID: 4_321)
        let drifted = retirementFallbackIdentity(processID: 4_321, startSeconds: 20_000)
        let launched = DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
        let attached = DebuggerSessionTargetAuthority(origin: .attached(identity))
        typealias Resolution = DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>
        let gone: [Resolution?] = [.unknown(.disappeared), .ineligible(.disappeared)]
        for reobservation in gone {
            XCTAssertTrue(PersistentLLDBProductionController.isLaunchedTargetProvablyGone(
                authority: launched,
                reobservation: reobservation
            ))
            XCTAssertFalse(PersistentLLDBProductionController.isLaunchedTargetProvablyGone(
                authority: attached,
                reobservation: reobservation
            ))
            XCTAssertFalse(PersistentLLDBProductionController.isLaunchedTargetProvablyGone(
                authority: nil,
                reobservation: reobservation
            ))
        }
        let uncertain: [Resolution?] = [
            nil,
            .resolved(identity),
            .resolved(drifted),
            .unknown(.identityChanged),
            .unknown(.metadataAccessDenied),
            .unknown(.timeout),
            .ineligible(.exiting),
        ]
        for reobservation in uncertain {
            XCTAssertFalse(PersistentLLDBProductionController.isLaunchedTargetProvablyGone(
                authority: launched,
                reobservation: reobservation
            ))
        }
    }

    private func retirementFallbackIdentity(
        processID: Int32,
        startSeconds: UInt64 = 10_000
    ) -> DebuggerLocalProcessIdentity {
        DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: startSeconds, microseconds: 42)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/rx01_v1",
            executableDeviceID: 7,
            executableFileID: 20_000,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        )!
    }

    func testExactAttachedExternalExitSettlementRetiresBeforeAtomicRelease() async {
        let recorder = ExactAttachedExternalExitSettlementRecorder()

        let outcome = await PersistentLLDBProductionController
            .settleExactAttachedExternalExit(
                evidenceIsValid: true,
                prepareForRetirement: {
                    await recorder.record(.prepared)
                },
                retireExactAdapter: {
                    await recorder.record(.retired)
                    return 41
                },
                completeRelease: { proof in
                    await recorder.record(.completed(proof))
                },
                pinDisposition: {
                    await recorder.record(.pinned)
                }
            )

        XCTAssertEqual(outcome, .released)
        let events = await recorder.events
        XCTAssertEqual(events, [.prepared, .retired, .completed(41)])
    }

    func testExactAttachedExternalExitSettlementPinsUnprovenRetirementWithoutRelease() async {
        let recorder = ExactAttachedExternalExitSettlementRecorder()

        let outcome = await PersistentLLDBProductionController
            .settleExactAttachedExternalExit(
                evidenceIsValid: true,
                prepareForRetirement: {
                    await recorder.record(.prepared)
                },
                retireExactAdapter: {
                    await recorder.record(.retired)
                    return nil as Int?
                },
                completeRelease: { proof in
                    await recorder.record(.completed(proof))
                },
                pinDisposition: {
                    await recorder.record(.pinned)
                }
            )

        XCTAssertEqual(outcome, .unresolved)
        let events = await recorder.events
        XCTAssertEqual(events, [.prepared, .retired, .pinned])
    }

    func testInvalidExactAttachedExternalExitEvidenceStillRetiresThenPins() async {
        let recorder = ExactAttachedExternalExitSettlementRecorder()

        let outcome = await PersistentLLDBProductionController
            .settleExactAttachedExternalExit(
                evidenceIsValid: false,
                prepareForRetirement: {
                    await recorder.record(.prepared)
                },
                retireExactAdapter: {
                    await recorder.record(.retired)
                    return 73
                },
                completeRelease: { proof in
                    await recorder.record(.completed(proof))
                },
                pinDisposition: {
                    await recorder.record(.pinned)
                }
            )

        XCTAssertEqual(outcome, .unresolved)
        let events = await recorder.events
        XCTAssertEqual(events, [.prepared, .retired, .pinned])
    }

    func testExactAttachedExternalExitAbsenceFailurePinsAfterAttemptedRelease() async {
        let recorder = ExactAttachedExternalExitSettlementRecorder()

        let outcome = await PersistentLLDBProductionController
            .settleExactAttachedExternalExit(
                evidenceIsValid: true,
                prepareForRetirement: {
                    await recorder.record(.prepared)
                },
                retireExactAdapter: {
                    await recorder.record(.retired)
                    return 97
                },
                completeRelease: { proof in
                    await recorder.record(.completed(proof))
                    throw ExactAttachedExternalExitSettlementTestError.absenceUnproven
                },
                pinDisposition: {
                    await recorder.record(.pinned)
                }
            )

        XCTAssertEqual(outcome, .unresolved)
        let events = await recorder.events
        XCTAssertEqual(events, [.prepared, .retired, .completed(97), .pinned])
    }

    func testEveryExactLaunchFailureRetiresAdapterWithoutGracefulQuit() {
        XCTAssertEqual(
            PersistentLLDBProductionController.exactLaunchFailureAdapterRetirementPolicy(
                for: .invalidated
            ),
            .retainedAdapterOnly
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.exactLaunchFailureAdapterRetirementPolicy(
                for: .detaching(processID: 42)
            ),
            .retainedAdapterOnly
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.exactLaunchFailureAdapterRetirementPolicy(
                for: .noTarget
            ),
            .retainedAdapterOnly
        )
    }

    func testLogicalBreakpointOwnershipTagIsStableOnlyForExactSessionGeneration() {
        let epoch = DebuggerSessionEpoch()
        let first = PersistentLLDBProductionController.logicalBreakpointOwnershipTagDigest(
            epoch: epoch,
            adapterGeneration: 7
        )

        XCTAssertEqual(
            first,
            PersistentLLDBProductionController.logicalBreakpointOwnershipTagDigest(
                epoch: epoch,
                adapterGeneration: 7
            )
        )
        XCTAssertNotEqual(
            first,
            PersistentLLDBProductionController.logicalBreakpointOwnershipTagDigest(
                epoch: epoch,
                adapterGeneration: 8
            )
        )
        XCTAssertNotEqual(
            first,
            PersistentLLDBProductionController.logicalBreakpointOwnershipTagDigest(
                epoch: DebuggerSessionEpoch(),
                adapterGeneration: 7
            )
        )
    }

    func testLogicalBreakpointTransactionTokenIsPlanIndependentAndTransactionUnique() {
        let epoch = DebuggerSessionEpoch()
        let transaction = DebuggerBreakpointBindingTransactionID(rawValue: UUID())
        let first = PersistentLLDBProductionController.logicalBreakpointTransactionToken(
            transactionID: transaction,
            epoch: epoch,
            adapterGeneration: 3
        )

        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(
            first,
            PersistentLLDBProductionController.logicalBreakpointTransactionToken(
                transactionID: transaction,
                epoch: epoch,
                adapterGeneration: 3
            )
        )
        XCTAssertNotEqual(
            first,
            PersistentLLDBProductionController.logicalBreakpointTransactionToken(
                transactionID: DebuggerBreakpointBindingTransactionID(rawValue: UUID()),
                epoch: epoch,
                adapterGeneration: 3
            )
        )
    }

    func testLogicalBreakpointRecoverySeparatesTargetWritesFromSessionAuthorityLoss() {
        XCTAssertEqual(
            PersistentLLDBProductionController.logicalBreakpointFailureRecovery(
                classification: .cancelBeforeWrite(cleanup: .proven),
                sessionAuthorityLost: false
            ),
            .none
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.logicalBreakpointFailureRecovery(
                classification: .cancelBeforeWrite(cleanup: .failedOrUnproven),
                sessionAuthorityLost: true
            ),
            .invalidateSessionAndShutdownAdapter
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.logicalBreakpointFailureRecovery(
                classification: .rejectMalformedAfterPossibleWrite(
                    cleanup: .proven,
                    retainValidatedCompleteReceipt: true,
                    targetRecoveryRequired: false
                ),
                sessionAuthorityLost: true
            ),
            .invalidateSessionAndShutdownAdapter
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.logicalBreakpointFailureRecovery(
                classification: .rejectMalformedAfterPossibleWrite(
                    cleanup: .failedOrUnproven,
                    retainValidatedCompleteReceipt: false,
                    targetRecoveryRequired: true
                ),
                sessionAuthorityLost: true
            ),
            .boundedTargetRecovery
        )
    }

    func testRunToCursorFailureRecoveryRejectsAStillRunningReducerState() {
        var state = DebuggerReducerState(
            epoch: DebuggerSessionEpoch(),
            capabilities: .persistentCLI(
                attachPolicyReason: "Production attach remains policy denied during WS-19."
            )
        )
        state.lifecycleRevision = DebuggerLifecycleRevision(rawValue: 1)
        state.processPhase = .running(processID: 42)
        state.observedProcessID = 42
        state.targetDisposition = .running(processID: 42)

        XCTAssertThrowsError(
            try PersistentLLDBProductionController
                .requireObservedExitAfterRunToCursorFailureRecovery(state)
        ) { error in
            XCTAssertEqual(
                error as? DebuggerClientError,
                .backendFailure(
                    "Run to Cursor recovery could not prove target exit."
                )
            )
        }
    }

    func testRunToCursorFailureRecoveryAcceptsAnObservedExit() throws {
        var state = DebuggerReducerState(
            epoch: DebuggerSessionEpoch(),
            capabilities: .persistentCLI(
                attachPolicyReason: "Production attach remains policy denied during WS-19."
            )
        )
        state.lifecycleRevision = DebuggerLifecycleRevision(rawValue: 2)
        state.processPhase = .exited(processID: 42, code: 9)
        state.observedProcessID = 42
        state.targetDisposition = .exited(code: 9)
        state.isInvalidated = true

        XCTAssertNoThrow(
            try PersistentLLDBProductionController
                .requireObservedExitAfterRunToCursorFailureRecovery(state)
        )
    }

    func testAutomaticStoppedRefreshFailurePropagatesTerminalReducerInvalidation() {
        var state = DebuggerReducerState(
            epoch: DebuggerSessionEpoch(),
            capabilities: .persistentCLI(
                attachPolicyReason: "Production attach remains policy denied during WS-19."
            )
        )
        state.processPhase = .invalidated
        state.observedProcessID = 42
        state.targetDisposition = .unknown
        state.isInvalidated = true

        XCTAssertThrowsError(
            try PersistentLLDBProductionController
                .authoritativeStateAfterAutomaticStoppedRefreshFailure(state)
        ) { error in
            XCTAssertEqual(
                error as? DebuggerClientError,
                .backendFailure(
                    "Snapshot Refresh invalidated the correlated LLDB session."
                )
            )
        }
    }

    func testAutomaticStoppedRefreshFailurePreservesAuthoritativePausedState() throws {
        var state = DebuggerReducerState(
            epoch: DebuggerSessionEpoch(),
            capabilities: .persistentCLI(
                attachPolicyReason: "Production attach remains policy denied during WS-19."
            )
        )
        state.lifecycleRevision = DebuggerLifecycleRevision(rawValue: 1)
        state.stopRevision = DebuggerStopRevision(rawValue: 1)
        state.processPhase = .stopped(processID: 42, reason: .userRequested)
        state.observedProcessID = 42
        state.targetDisposition = .stopped(processID: 42)

        XCTAssertEqual(
            try PersistentLLDBProductionController
                .authoritativeStateAfterAutomaticStoppedRefreshFailure(state),
            state
        )
    }

    /// §4.86b: a run-control failure keeps the reducer's state only when a correlated response
    /// carried a status segment. An adapter that refused or lost the request proves nothing, so
    /// the failure must reach the fail-closed retirement instead of a stale "paused" snapshot.
    func testLifecycleFailureKeepsAuthoritativeStateOnlyWithACorrelatedResponse() {
        typealias Controller = PersistentLLDBProductionController
        for code: PersistentLLDBSessionCoordinatorFailureCode in [
            .adapterFailedBeforeWrite, .adapterInvalidated, .responseCorrelationMismatch,
        ] {
            XCTAssertFalse(
                Controller.failureCarriesAuthoritativeStatus(
                    PersistentLLDBSessionCoordinatorFailure(code: code)
                ),
                "\(code)"
            )
        }
        for code: PersistentLLDBSessionCoordinatorFailureCode in [
            .responseProjectionFailed, .adapterCancelled, .reducerRejected,
        ] {
            XCTAssertTrue(
                Controller.failureCarriesAuthoritativeStatus(
                    PersistentLLDBSessionCoordinatorFailure(code: code)
                ),
                "\(code)"
            )
        }
    }

    /// §4.88: a poll that races LLDB's async stop handling must not be invalidated by a deadline
    /// shorter than the ordinary exchange's; it stays bounded by the command timeout and 10 s.
    func testStatusPollTimeoutMatchesTheBoundedExchangeDeadline() {
        XCTAssertEqual(
            PersistentLLDBProductionController.resolvedPollTimeout(for: .seconds(30)),
            .seconds(10)
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.resolvedPollTimeout(for: .seconds(10)),
            .seconds(10)
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.resolvedPollTimeout(for: .milliseconds(250)),
            .milliseconds(250)
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.resolvedPollTimeout(
                for: .seconds(30),
                hasLogicalCallbackAuthority: true
            ),
            .seconds(10)
        )
        XCTAssertEqual(
            PersistentLLDBProductionController.resolvedPollTimeout(
                for: .milliseconds(250),
                hasLogicalCallbackAuthority: true
            ),
            .milliseconds(250)
        )
    }

    func testOldTerminalResultCannotClearNewRunToCursorAuthority() {
        let oldEpoch = DebuggerSessionEpoch()
        let newEpoch = DebuggerSessionEpoch()

        XCTAssertFalse(
            PersistentLLDBProductionController.shouldDiscardPendingRunToCursorBreakpoint(
                pendingEpoch: newEpoch,
                resultEpoch: oldEpoch,
                resultIsTerminal: true
            )
        )
        XCTAssertTrue(
            PersistentLLDBProductionController.shouldDiscardPendingRunToCursorBreakpoint(
                pendingEpoch: newEpoch,
                resultEpoch: newEpoch,
                resultIsTerminal: true
            )
        )
        XCTAssertFalse(
            PersistentLLDBProductionController.shouldDiscardPendingRunToCursorBreakpoint(
                pendingEpoch: newEpoch,
                resultEpoch: newEpoch,
                resultIsTerminal: false
            )
        )
    }

    func testExpressionSemanticModuleRefreshFailureReturnsValueWithPausedTombstoneSnapshot() throws {
        let state = makeStoppedRuntimeModuleRefreshFailureState()

        let result = try XCTUnwrap(
            PersistentLLDBProductionController
                .expressionResultAfterRuntimeModuleRefreshFailure(
                    value: "42",
                    type: "int",
                    authoritativeState: state,
                    executableName: "Fixture"
                )
        )

        XCTAssertEqual(result.value, "42")
        XCTAssertEqual(result.type, "int")
        let refreshedSnapshot = try XCTUnwrap(result.refreshedSnapshot)
        XCTAssertEqual(
            refreshedSnapshot.processState,
            .paused(processID: 88, reason: .unknown("entry"))
        )
        XCTAssertEqual(
            refreshedSnapshot.backendState,
            .connected(processID: 88, adapterName: "Xcode LLDB CLI")
        )
        guard case .unavailable(.refreshFailed) =
                refreshedSnapshot.transportRuntimeModuleAuthority else {
            return XCTFail("Expected the authoritative refresh-failed tombstone.")
        }
    }

    func testExpressionInvalidatedModuleRefreshFailureDoesNotPreserveExpressionResult() {
        var state = makeStoppedRuntimeModuleRefreshFailureState()
        state.processPhase = .invalidated
        state.targetDisposition = .unknown
        state.isInvalidated = true

        XCTAssertNil(
            PersistentLLDBProductionController
                .expressionResultAfterRuntimeModuleRefreshFailure(
                    value: "42",
                    type: "int",
                    authoritativeState: state,
                    executableName: "Fixture"
                )
        )
    }

    func testExpressionTranscriptBecomesTypedReducerPayloadWithoutRawPublication() async throws {
        let epoch = DebuggerSessionEpoch()
        let context = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: 1),
            operation: .evaluateExpression,
            expectedSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            requiredStop: DebuggerStopCoordinate(
                session: DebuggerSessionCoordinate(
                    epoch: epoch,
                    lifecycleRevision: .initial
                ),
                stopRevision: DebuggerStopRevision(rawValue: 1)
            )
        )
        let preparer = PersistentLLDBProductionRequestPreparer()
        try await preparer.install(
            operation: .evaluateExpression,
            commands: ["expression -- 6 * 7"],
            timeout: .seconds(1),
            responseProjection: .expression
        )
        _ = try await preparer.prepareRequest(for: context)

        let payloads = try await preparer.reducerPayloads(
            for: context,
            transcript: transcript("(int) $0 = 42")
        )

        XCTAssertEqual(
            payloads,
            [.expressionEvaluated(.init(displayValue: "42", typeName: "int"))]
        )
    }

    func testStoppedTranscriptBecomesCompleteTypedStoppedData() async throws {
        let epoch = DebuggerSessionEpoch()
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
        )
        let context = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: 2),
            operation: .refreshSnapshot,
            expectedSession: session,
            requiredStop: DebuggerStopCoordinate(
                session: session,
                stopRevision: DebuggerStopRevision(rawValue: 1)
            )
        )
        let preparer = PersistentLLDBProductionRequestPreparer()
        try await preparer.install(
            operation: .refreshSnapshot,
            commands: ["thread list"],
            timeout: .seconds(1),
            responseProjection: .stoppedData
        )
        _ = try await preparer.prepareRequest(for: context)

        let payloads = try await preparer.reducerPayloads(
            for: context,
            transcript: transcript(
                """
                * thread #1, stop reason = breakpoint 1.1
                  frame #0: 0x0000000100001000 Demo`main
                x0 = 0x000000000000002a
                0x000000016fdff000: 2a 00 ff 7f
                """
            )
        )

        guard case .stoppedDataRefreshed(let data) = try XCTUnwrap(payloads.first) else {
            return XCTFail("Expected typed stopped data.")
        }
        XCTAssertEqual(data.selectedThreadID, 1)
        XCTAssertEqual(data.selectedFrameID, 0)
        XCTAssertEqual(data.currentProgramCounter, 0x100001000)
        XCTAssertEqual(data.registers, .available([
            DebuggerStoppedRegister(
                name: "x0",
                value: "0x000000000000002a",
                role: nil,
                group: .generalPurpose
            )
        ]))
        XCTAssertEqual(data.memoryPreviews, .available([
            DebuggerStoppedMemoryPreview(
                address: 0x16fdff000,
                bytes: [0x2a, 0x00, 0xff, 0x7f],
                label: "stack near sp"
            )
        ]))
    }

    func testVariableReceiptPreservesItsExactSelectedFrameInsteadOfRebindingFrameZero() async throws {
        let epoch = DebuggerSessionEpoch()
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
        )
        let stop = DebuggerStopCoordinate(
            session: session,
            stopRevision: DebuggerStopRevision(rawValue: 1)
        )
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 99))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 2,
            programCounter: 0x1000_3000,
            canonicalFunctionName: "selected"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: variableFixtureAuthority(processID: 4242),
            thread: thread,
            frame: frame
        ))
        let token = Data(repeating: 0x5a, count: 32)
        let expectation = PersistentLLDBProductionRequestPreparer.VariableRefreshExpectation(
            token: token,
            coordinate: coordinate,
            processID: 4242,
            observedStopID: 7,
            threadID: 99,
            frameIndex: 2,
            programCounter: 0x1000_3000
        )
        let context = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: 2),
            operation: .refreshSnapshot,
            expectedSession: session,
            requiredStop: stop
        )
        let preparer = PersistentLLDBProductionRequestPreparer()
        try await preparer.install(
            operation: .refreshSnapshot,
            commands: ["thread list"],
            timeout: .seconds(1),
            responseProjection: .stoppedDataWithVariables(expectation)
        )
        _ = try await preparer.prepareRequest(for: context)
        let receipt: Phase2ProductionJSONValue = .object([
            "argument_omitted": .number("0"), "argument_truncated": .bool(false),
            "frame_index": .number("2"), "local_omitted": .number("0"),
            "local_truncated": .bool(false), "observed_pid": .number("4242"),
            "observed_state": .string("stopped"), "observed_stop_id": .number("7"),
            "ok": .bool(true), "omitted_count": .number("0"),
            "pc": .number("268447744"), "schema": .number("1"),
            "static_omitted": .number("0"), "static_truncated": .bool(false),
            "thread_id": .number("99"),
            "token": .string(token.map { String(format: "%02x", $0) }.joined()),
            "truncated": .bool(false), "variables": .array([]),
        ])
        let framed = "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "
            + String(decoding: receipt.canonicalJSONBytes(), as: UTF8.self)
        let payloads = try await preparer.reducerPayloads(
            for: context,
            transcript: transcript("""
            * thread #1, tid = 0x63, stop reason = breakpoint 1.1
              frame #0: 0x0000000100001000 Fixture`inner
              frame #2: 0x0000000100003000 Fixture`selected
            \(framed)
            """)
        )
        guard case .stoppedDataRefreshed(let data) = try XCTUnwrap(payloads.first),
              case .available(let scopes) = data.variables else {
            return XCTFail("Expected exact variable projection.")
        }
        XCTAssertEqual(data.selectedFrameID, 2)
        XCTAssertEqual(data.currentProgramCounter, 0x1000_3000)
        XCTAssertEqual(scopes.map(\.coordinate), [coordinate, coordinate, coordinate])
    }

    func testVariableChildReceiptProjectsExactChildrenForRequestedParent() async throws {
        let fixture = try variableChildFixture()
        let preparer = PersistentLLDBProductionRequestPreparer()
        try await preparer.install(
            operation: .expandVariableChildren,
            commands: ["script child snapshot"],
            timeout: .seconds(1),
            responseProjection: .variableChildren(fixture.expectation, fixture.request)
        )
        _ = try await preparer.prepareRequest(for: fixture.context)

        let payloads = try await preparer.reducerPayloads(
            for: fixture.context,
            transcript: transcript(fixture.framedReceipt(
                variables: [fixture.variable(
                    ordinal: 0,
                    name: "left",
                    type: "Int",
                    value: "1",
                    children: 0
                )]
            ))
        )

        guard case .variableChildrenRefreshed(let request, let snapshot) =
                try XCTUnwrap(payloads.first) else {
            return XCTFail("Expected exact child-variable projection.")
        }
        XCTAssertEqual(request, fixture.request)
        XCTAssertEqual(snapshot.coordinate, fixture.expectation.coordinate)
        XCTAssertEqual(snapshot.scope, .locals)
        XCTAssertEqual(snapshot.depth, 1)
        XCTAssertEqual(snapshot.nodes.map(\.name), ["left"])
        XCTAssertEqual(
            snapshot.nodes.first?.pathComponents,
            ["locals", "0", "aggregate", "0", "left"]
        )
    }

    func testVariableChildReceiptAndContextFailClosedOutsideExactScopeAndOperation() async throws {
        let fixture = try variableChildFixture()
        XCTAssertTrue(fixture.context.isInternallyConsistent)
        XCTAssertFalse(DebuggerRequestContext(
            id: fixture.context.id,
            operation: .refreshSnapshot,
            expectedSession: fixture.context.expectedSession,
            requiredStop: fixture.context.requiredStop,
            variableExpansionRequest: fixture.request
        ).isInternallyConsistent)
        XCTAssertFalse(DebuggerRequestContext(
            id: fixture.context.id,
            operation: .expandVariableChildren,
            expectedSession: fixture.context.expectedSession,
            requiredStop: fixture.context.requiredStop
        ).isInternallyConsistent)

        let preparer = PersistentLLDBProductionRequestPreparer()
        try await preparer.install(
            operation: .expandVariableChildren,
            commands: ["script child snapshot"],
            timeout: .seconds(1),
            responseProjection: .variableChildren(fixture.expectation, fixture.request)
        )
        _ = try await preparer.prepareRequest(for: fixture.context)
        do {
            _ = try await preparer.reducerPayloads(
                for: fixture.context,
                transcript: transcript(fixture.framedReceipt(
                    variables: [fixture.variable(
                        ordinal: 0,
                        name: "wrong",
                        type: "Int",
                        value: "1",
                        children: 0,
                        scope: .argument
                    )]
                ))
            )
            XCTFail("Expected a child receipt from the wrong scope to be rejected.")
        } catch {
            guard case PersistentLLDBProductionControllerError.unusableStoppedData = error else {
                return XCTFail("Unexpected wrong-scope rejection: \(error)")
            }
        }
    }

    private func variableChildFixture() throws -> VariableChildProjectionFixture {
        let epoch = DebuggerSessionEpoch()
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
        )
        let stop = DebuggerStopCoordinate(
            session: session,
            stopRevision: DebuggerStopRevision(rawValue: 1)
        )
        let thread = try XCTUnwrap(DebuggerThreadIdentity(index: 1, tid: 99))
        let frame = try XCTUnwrap(DebuggerFrameIdentity(
            thread: thread,
            frameIndex: 2,
            programCounter: 0x1000_3000,
            canonicalFunctionName: "selected"
        ))
        let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stop,
            targetAuthority: variableFixtureAuthority(processID: 4242),
            thread: thread,
            frame: frame
        ))
        let components = ["locals", "0", "aggregate"]
        let token = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: components
        ))
        let request = try XCTUnwrap(DebuggerVariableExpansionRequest(
            coordinate: coordinate,
            token: token,
            pathComponents: components,
            depth: 1
        ))
        let receiptToken = Data(repeating: 0x5a, count: 32)
        return VariableChildProjectionFixture(
            expectation: .init(
                token: receiptToken,
                coordinate: coordinate,
                processID: 4242,
                observedStopID: 7,
                threadID: 99,
                frameIndex: 2,
                programCounter: 0x1000_3000
            ),
            request: request,
            context: DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: 4),
                operation: .expandVariableChildren,
                expectedSession: session,
                requiredStop: stop,
                targetAuthority: variableFixtureAuthority(processID: 4242),
                variableExpansionRequest: request
            )
        )
    }

    private struct VariableChildProjectionFixture {
        let expectation: PersistentLLDBProductionRequestPreparer.VariableRefreshExpectation
        let request: DebuggerVariableExpansionRequest
        let context: DebuggerRequestContext

        func framedReceipt(variables: [Phase2ProductionJSONValue]) -> String {
            let receipt: Phase2ProductionJSONValue = .object([
                "argument_omitted": .number("0"), "argument_truncated": .bool(false),
                "frame_index": .number(String(expectation.frameIndex)),
                "local_omitted": .number("0"), "local_truncated": .bool(false),
                "observed_pid": .number(String(expectation.processID)),
                "observed_state": .string("stopped"),
                "observed_stop_id": .number(String(expectation.observedStopID)),
                "ok": .bool(true), "omitted_count": .number("0"),
                "pc": .number(String(expectation.programCounter)), "schema": .number("1"),
                "static_omitted": .number("0"), "static_truncated": .bool(false),
                "thread_id": .number(String(expectation.threadID)),
                "token": .string(expectation.token.map { String(format: "%02x", $0) }.joined()),
                "truncated": .bool(false), "variables": .array(variables),
            ])
            return "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "
                + String(decoding: receipt.canonicalJSONBytes(), as: UTF8.self)
        }

        func variable(
            ordinal: UInt32,
            name: String,
            type: String,
            value: String,
            children: UInt32,
            scope: LLDBVariableScope = .local
        ) -> Phase2ProductionJSONValue {
            .object([
                "child_count": .number(String(children)),
                "diagnostic": .null,
                "has_children": .bool(children > 0),
                "name": .string(name),
                "ordinal": .number(String(ordinal)),
                "scope": .string(scope.rawValue),
                "state": .string("available"),
                "summary": .null,
                "type": .string(type),
                "value": .string(value),
            ])
        }
    }

    private func variableFixtureAuthority(processID: Int32) -> DebuggerSessionTargetAuthority {
        let identity = DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 10_000, microseconds: 42)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeVariableFixture",
            executableDeviceID: 7,
            executableFileID: 20_000,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        )!
        return DebuggerSessionTargetAuthority(origin: .attached(identity))
    }

    func testTerminalCleanupDropsOutstandingProjectionMaterial() async throws {
        let epoch = DebuggerSessionEpoch()
        let session = DebuggerSessionCoordinate(epoch: epoch, lifecycleRevision: .initial)
        let context = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: 3),
            operation: .replaceBreakpoints,
            expectedSession: session
        )
        let preparer = PersistentLLDBProductionRequestPreparer()
        try await preparer.install(
            operation: .replaceBreakpoints,
            commands: ["breakpoint set --address 0x0000000000001000"],
            timeout: .seconds(1),
            responseProjection: .breakpoints([
                DebuggerTransportBreakpoint(
                    address: 0x1000,
                    isEnabled: true,
                    condition: "secret_condition",
                    hitCount: 0,
                    ignoreCount: 0,
                    backendIdentifier: nil
                )
            ], requireCreationProof: false)
        )
        _ = try await preparer.prepareRequest(for: context)
        await preparer.discardOutstandingResponses()

        let payloads = try await preparer.reducerPayloads(
            for: context,
            transcript: transcript("Breakpoint 1: address = 0x1000")
        )
        XCTAssertTrue(payloads.isEmpty)
    }

    func testMemoryWriteProjectionRequiresExactAddressAndBytesFromTrustedReadback() async throws {
        let epoch = DebuggerSessionEpoch()
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 1)
        )

        func context(sequence: UInt64) -> DebuggerRequestContext {
            DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: sequence),
                operation: .writeMemory,
                expectedSession: session,
                requiredStop: DebuggerStopCoordinate(
                    session: session,
                    stopRevision: DebuggerStopRevision(rawValue: 1)
                )
            )
        }

        let accepted = PersistentLLDBProductionRequestPreparer()
        try await accepted.install(
            operation: .writeMemory,
            commands: ["memory write", "memory read"],
            timeout: .seconds(1),
            responseProjection: .memoryWriteReadback(
                address: 0x1000,
                bytes: [0x2a, 0xff]
            )
        )
        let acceptedContext = context(sequence: 4)
        _ = try await accepted.prepareRequest(for: acceptedContext)
        let payloads = try await accepted.reducerPayloads(
            for: acceptedContext,
            transcript: transcript("0x0000000000001000: 2a ff")
        )
        XCTAssertEqual(payloads.count, 1)

        let rejected = PersistentLLDBProductionRequestPreparer()
        try await rejected.install(
            operation: .writeMemory,
            commands: ["memory write", "memory read"],
            timeout: .seconds(1),
            responseProjection: .memoryWriteReadback(
                address: 0x1000,
                bytes: [0x2a, 0xff]
            )
        )
        let rejectedContext = context(sequence: 5)
        _ = try await rejected.prepareRequest(for: rejectedContext)
        do {
            _ = try await rejected.reducerPayloads(
                for: rejectedContext,
                transcript: transcript("0x0000000000001000: 2a 00")
            )
            XCTFail("A mismatched memory readback must fail closed.")
        } catch is PersistentLLDBProductionControllerError {
            // Expected typed projection failure.
        }
    }

    private func transcript(_ text: String) -> LLDBCLITranscriptResult {
        LLDBCLITranscriptResult(
            transcript: text,
            authoritativeStatusTranscript: "Process 9 stopped",
            observedProcessID: 9,
            observedProcessState: .stopped(processID: 9),
            exchangeByteCount: text.utf8.count,
            exchangeSHA256: String(repeating: "a", count: 64),
            semanticCommandTranscripts: [text]
        )
    }

    private func productionLaunchTestToolchain() -> DebuggerLLDBToolchain {
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        return DebuggerLLDBToolchain(
            executablePath: developerDirectory + "/usr/bin/lldb",
            developerDirectory: developerDirectory,
            discoverySource: "test",
            candidatePaths: []
        )
    }

    private func policyProjectionInterlock()
        -> DebuggerLocalProcessAttachWriteInterlock
    {
        DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
    }

    private func different(_ value: UInt32) -> UInt32 {
        value == .max ? value - 1 : value + 1
    }

    private func different(_ value: Int32) -> Int32 {
        value == .max ? value - 1 : value + 1
    }

    private func policyProjectionClient(
        leaseRegistry: DebuggerSessionLeaseRegistry,
        ownedRegistry: DebuggerOwnedInfrastructureRegistry,
        provider: DebuggerLocalProcessObservationPolicyProvider
    ) -> LocalLLDBDebuggerClient {
        LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            toolchain: DebuggerLLDBToolchain(
                executablePath: "/usr/bin/false",
                developerDirectory: nil,
                discoverySource: "test",
                candidatePaths: ["/usr/bin/false"]
            ),
            processRunner: LeaseAuthorityProjectionProcessRunner(),
            environment: [:],
            workingDirectory: "/tmp",
            usePersistentTransport: true,
            debuggerSessionLeaseRegistry: leaseRegistry,
            ownedInfrastructureRegistry: ownedRegistry,
            observationPolicyProvider: provider
        ))
    }

    private func makeStoppedRuntimeModuleRefreshFailureState() -> DebuggerReducerState {
        let epoch = DebuggerSessionEpoch()
        var reducer = DebuggerSessionReducer(
            epoch: epoch,
            capabilities: .persistentCLI(
                attachPolicyReason: "Production attach remains policy denied during WS-19."
            )
        )
        let launch = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: 1),
            operation: .launch,
            expectedSession: reducer.state.sessionCoordinate
        )
        XCTAssertAccepted(reducer.admit(launch))
        XCTAssertAccepted(reducer.reduce(event(1, launch, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            2,
            launch,
            .processStopped(observedPID: 88, reason: .unknown("entry"))
        )))
        XCTAssertAccepted(reducer.reduce(event(
            3,
            launch,
            .requestCompleted(.completed(target: .stopped(processID: 88)))
        )))

        let refresh = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: 2),
            operation: .refreshRuntimeModules,
            expectedSession: reducer.state.sessionCoordinate,
            requiredStop: reducer.state.stopCoordinate
        )
        XCTAssertAccepted(reducer.admit(refresh))
        XCTAssertAccepted(reducer.reduce(event(4, refresh, .requestStarted)))
        XCTAssertAccepted(reducer.reduce(event(
            5,
            refresh,
            .requestFailed(DebuggerDiagnostic.make(
                code: .operationFailed,
                severity: .error,
                rawText: "module collection failed",
                operation: .refreshRuntimeModules,
                targetDisposition: .stopped(processID: 88)
            ))
        )))
        return reducer.state
    }

    private func event(
        _ sequence: UInt64,
        _ context: DebuggerRequestContext,
        _ payload: DebuggerEventPayload
    ) -> DebuggerEventEnvelope {
        DebuggerEventEnvelope(
            sessionEpoch: context.id.epoch,
            eventSequence: DebuggerEventSequence(rawValue: sequence),
            requestID: context.id,
            operation: context.operation,
            capturedLifecycleRevision: context.expectedSession.lifecycleRevision,
            boundStopRevision: context.requiredStop?.stopRevision,
            payload: payload
        )
    }

    private func XCTAssertAccepted(
        _ admission: DebuggerRequestAdmission,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .accepted = admission else {
            XCTFail("Expected accepted request, got \(admission)", file: file, line: line)
            return
        }
    }

    private func XCTAssertAccepted(
        _ reduction: DebuggerEventReduction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(reduction, .accepted, file: file, line: line)
    }
}

private struct ProjectionScriptedPolicySource:
    DebuggerLocalProcessObservationPolicySource
{
    private enum ScriptedError: Error { case unavailable }

    func ownedInfrastructureSnapshot() async throws
        -> DebuggerOwnedInfrastructureSnapshot
    {
        throw ScriptedError.unavailable
    }

    func leaseObservationSnapshot(
        scope: DebuggerLocalProcessObservationPolicyScope
    ) async throws -> DebuggerSessionLeaseObservationSnapshot {
        _ = scope
        throw ScriptedError.unavailable
    }
}

private struct LeaseAuthorityProjectionProcessRunner: DebuggerProcessRunning {
    func run(_ command: DebuggerExternalCommand) throws -> DebuggerSubprocessResult {
        _ = command
        return DebuggerSubprocessResult(
            terminationStatus: 0,
            standardOutput: """
            lldb-2103.0.23.6
            Platform: host
            Triple: arm64-apple-macosx
            __MACSCOPE_LLDB_PERSISTENT_READY__
            """,
            standardError: "",
            timedOut: false
        )
    }
}

private actor SuspendedProductionLaunchGateProbe {
    private(set) var entryCount = 0
    private var suspended: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func enter() async {
        entryCount += 1
        let ready = entryWaiters.filter { entryCount >= $0.0 }
        entryWaiters.removeAll { entryCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { suspended.append($0) }
    }

    func waitForEntryCount(_ expected: Int) async {
        guard entryCount < expected else { return }
        await withCheckedContinuation { entryWaiters.append((expected, $0)) }
    }

    func resumeNext() {
        guard !suspended.isEmpty else { return }
        suspended.removeFirst().resume()
    }
}

private actor ProductionLaunchProcessLauncherProbe {
    private let processChannel: ProductionLaunchProcessChannel
    private let suspendAfterCreation: Bool
    private var created = false
    private var creationWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private(set) var invocationCount = 0

    init(
        channel: ProductionLaunchProcessChannel = ProductionLaunchProcessChannel(),
        suspendAfterCreation: Bool = false
    ) {
        self.processChannel = channel
        self.suspendAfterCreation = suspendAfterCreation
    }

    var channel: ProductionLaunchProcessChannel {
        processChannel
    }

    func launch(
        _ plan: PersistentLLDBCLIProcessLaunchPlan
    ) async -> any PersistentLLDBTargetlessProcessChannel {
        _ = plan
        invocationCount += 1
        created = true
        let waiters = creationWaiters
        creationWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if suspendAfterCreation {
            await withCheckedContinuation { resumeContinuation = $0 }
        }
        return processChannel
    }

    func waitUntilChildCreated() async {
        guard !created else { return }
        await withCheckedContinuation { creationWaiters.append($0) }
    }

    func resumeAfterCreation() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor ProductionLaunchCompletionProbe {
    private(set) var isComplete = false

    func recordCompletion() {
        isComplete = true
    }
}

private actor ExactAttachedExternalExitSettlementRecorder {
    enum Event: Equatable, Sendable {
        case prepared
        case retired
        case completed(Int)
        case pinned
    }

    private(set) var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }
}

private enum ExactAttachedExternalExitSettlementTestError: Error {
    case absenceUnproven
}

private actor ProductionLaunchProcessChannel: PersistentLLDBTargetlessProcessChannel {
    enum LifecycleCall: Equatable {
        case closeInput
        case closeHandles
        case waitForExit(Duration)
        case terminate
        case kill
        case reap
    }

    private var waitForExitResults: [Bool]
    private let reapResult: Bool
    private let suspendFirstWaitForExit: Bool
    private var didSuspendWaitForExit = false
    private var waitForExitStarted = false
    private var waitForExitStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var waitForExitResumeContinuation: CheckedContinuation<Void, Never>?
    private(set) var writes: [Data] = []
    private(set) var lifecycleCalls: [LifecycleCall] = []
    private(set) var waitCancellationStates: [Bool] = []

    init(
        waitForExitResults: [Bool] = [true],
        reapResult: Bool = true,
        suspendFirstWaitForExit: Bool = false
    ) {
        self.waitForExitResults = waitForExitResults
        self.reapResult = reapResult
        self.suspendFirstWaitForExit = suspendFirstWaitForExit
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
        lifecycleCalls.append(.waitForExit(maximumDuration))
        waitCancellationStates.append(Task.isCancelled)
        if suspendFirstWaitForExit, !didSuspendWaitForExit {
            didSuspendWaitForExit = true
            waitForExitStarted = true
            let waiters = waitForExitStartWaiters
            waitForExitStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { waitForExitResumeContinuation = $0 }
        }
        guard !waitForExitResults.isEmpty else { return false }
        return waitForExitResults.removeFirst()
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

    func waitUntilWaitForExitStarts() async {
        guard !waitForExitStarted else { return }
        await withCheckedContinuation { waitForExitStartWaiters.append($0) }
    }

    func resumeWaitForExit() {
        waitForExitResumeContinuation?.resume()
        waitForExitResumeContinuation = nil
    }
}

/// Answers each framed exchange like Xcode 27 LLDB did before the status-context fix: staging
/// commands succeed, and the final `process launch` succeeds but the in-exchange `process status`
/// readback has no current process (so no PID).
private actor ScriptedLaunchProcessChannel: PersistentLLDBTargetlessProcessChannel {
    enum LifecycleCall: Equatable {
        case closeInput
        case closeHandles
        case waitForExit
        case terminate
        case kill
        case reap
    }

    private var pending: [Data] = []
    private var readers: [CheckedContinuation<Data?, Never>] = []
    private var closed = false
    private(set) var sawFinalLaunchCommand = false
    private(set) var lifecycleCalls: [LifecycleCall] = []

    func write(_ data: Data) async throws {
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard let token = Self.token(fromBeginLine: lines.first),
              let markers = try? LLDBCLIExchangeMarkers(token: token) else { return }
        let program = lines.count > 1 ? Self.decodedProgram(lines[1]) : ""
        if program.contains(Data(#"["process launch --stop-at-entry --no-stdio"]"#.utf8).base64EncodedString()) {
            sawFinalLaunchCommand = true
        }
        let transcript = sawFinalLaunchCommand ? "Process 4242 launched: '/bin/echo' (arm64)\n" : ""
        let status = "error: Command requires a current process.\n"
        let response = [
            markers.requestBeginLine,
            "\(markers.commandResultPrefix)0_\(Data(transcript.utf8).base64EncodedString())__",
            markers.commandsSucceededLine,
            markers.statusBeginLine,
            "\(markers.statusResultPrefix)\(Data(status.utf8).base64EncodedString())__",
            markers.statusEndLine,
            markers.requestEndLine,
        ].joined(separator: "\n") + "\n"
        deliver(Data(response.utf8))
    }

    func nextBytes() async throws -> Data? {
        if !pending.isEmpty { return pending.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { readers.append($0) }
    }

    func closeInput() async {
        lifecycleCalls.append(.closeInput)
    }

    func closeHandles() async {
        lifecycleCalls.append(.closeHandles)
        finishReads()
    }

    func waitForExit(maximumDuration: Duration) async -> Bool {
        lifecycleCalls.append(.waitForExit)
        return true
    }

    func terminateRetainedAdapter() async {
        lifecycleCalls.append(.terminate)
        finishReads()
    }

    func killRetainedAdapterIfStillRunning() async -> Bool {
        lifecycleCalls.append(.kill)
        return true
    }

    func reapAndClose() async -> Bool {
        lifecycleCalls.append(.reap)
        finishReads()
        return true
    }

    private func deliver(_ data: Data) {
        if readers.isEmpty {
            pending.append(data)
        } else {
            readers.removeFirst().resume(returning: data)
        }
    }

    private func finishReads() {
        closed = true
        let waiting = readers
        readers.removeAll()
        waiting.forEach { $0.resume(returning: nil) }
    }

    private static func token(fromBeginLine line: String?) -> String? {
        let prefix = "script print(__import__('base64').b64decode('"
        let suffix = "').decode('ascii'))"
        guard let line, line.hasPrefix(prefix), line.hasSuffix(suffix),
              let data = Data(base64Encoded: String(line.dropFirst(prefix.count).dropLast(suffix.count))),
              let marker = String(data: data, encoding: .ascii) else { return nil }
        let markerPrefix = "__MACSCOPE_LLDB_REQUEST_BEGIN_"
        guard marker.hasPrefix(markerPrefix), marker.hasSuffix("__") else { return nil }
        return String(marker.dropFirst(markerPrefix.count).dropLast(2))
    }

    private static func decodedProgram(_ line: String) -> String {
        let prefix = "script exec(__import__('base64').b64decode('"
        let suffix = "').decode('utf-8'))"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix),
              let data = Data(base64Encoded: String(line.dropFirst(prefix.count).dropLast(suffix.count))) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private actor ScriptedLaunchChannelQueue {
    private var channels: [ScriptedLaunchProcessChannel]
    private(set) var launchedCount = 0

    init(_ channels: [ScriptedLaunchProcessChannel]) {
        self.channels = channels
    }

    func next() -> any PersistentLLDBTargetlessProcessChannel {
        launchedCount += 1
        return channels.isEmpty ? ScriptedLaunchProcessChannel() : channels.removeFirst()
    }
}

private actor RetirementFallbackRecorder {
    enum Event: Equatable {
        case reobserve
        case kill(Int32)
    }

    private(set) var events: [Event] = []
    private var reobservations: [DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>?]

    init(reobservations: [DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>?]) {
        self.reobservations = reobservations
    }

    func reobserve() -> DebuggerLocalProcessResolution<DebuggerLocalProcessIdentity>? {
        events.append(.reobserve)
        return reobservations.isEmpty ? nil : reobservations.removeFirst()
    }

    func kill(_ identity: DebuggerLocalProcessIdentity) {
        events.append(.kill(identity.processID))
    }
}
