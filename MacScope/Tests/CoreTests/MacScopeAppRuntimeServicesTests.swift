import SwiftUI
import XCTest
@testable import MacScope

@MainActor
final class MacScopeAppRuntimeServicesTests: XCTestCase {
    func testApplicationDelegateWithoutInstalledShutdownFailsClosed() {
        let replies = MacScopeAppTerminationReplyRecorder()
        let delegate = MacScopeApplicationDelegate()

        let terminationReply = delegate.requestTermination { decision in
            replies.record(decision)
        }

        XCTAssertEqual(terminationReply, .terminateCancel)
        XCTAssertTrue(replies.values.isEmpty)
    }

    func testApplicationDelegateCoalescesShutdownAndDeferredReply() async {
        let probe = MacScopeAppTerminationDecisionProbe(decisions: [true, true])
        let replies = MacScopeAppTerminationReplyRecorder()
        let delegate = MacScopeApplicationDelegate()
        delegate.install {
            await probe.nextDecision()
        }

        let firstReply = delegate.requestTermination { decision in
            replies.record(decision)
        }
        let repeatedReply = delegate.requestTermination { decision in
            replies.record(decision)
        }

        XCTAssertEqual(firstReply, .terminateLater)
        XCTAssertEqual(repeatedReply, .terminateLater)
        await waitForReplyCount(1, replies: replies)
        // Let every waiter on the completed shutdown actor resume so a duplicate reply cannot
        // escape observation merely because the assertion won a scheduling race.
        for _ in 0..<100 { await Task.yield() }
        let shutdownCount = await probe.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(replies.values, [true])
    }

    func testApplicationDelegateRepeatedRequestAfterSuccessfulShutdownTerminatesNow() async {
        let probe = MacScopeAppTerminationDecisionProbe(decisions: [true, true])
        let replies = MacScopeAppTerminationReplyRecorder()
        let delegate = MacScopeApplicationDelegate()
        delegate.install {
            await probe.nextDecision()
        }

        XCTAssertEqual(
            delegate.requestTermination { decision in
                replies.record(decision)
            },
            .terminateLater
        )
        await waitForReplyCount(1, replies: replies)
        XCTAssertEqual(replies.values, [true])

        let repeatedReply = delegate.requestTermination { decision in
            replies.record(decision)
        }

        XCTAssertEqual(repeatedReply, .terminateNow)
        for _ in 0..<100 { await Task.yield() }
        let shutdownCount = await probe.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
        XCTAssertEqual(
            replies.values,
            [true],
            "a synchronous post-shutdown reply must not emit a second deferred callback"
        )
    }

    func testApplicationDelegateFalseDecisionPermitsFreshRetry() async {
        let probe = MacScopeAppTerminationDecisionProbe(decisions: [false, true])
        let replies = MacScopeAppTerminationReplyRecorder()
        let delegate = MacScopeApplicationDelegate()
        delegate.install {
            await probe.nextDecision()
        }

        XCTAssertEqual(
            delegate.requestTermination { decision in
                replies.record(decision)
            },
            .terminateLater
        )
        await waitForReplyCount(1, replies: replies)
        let firstShutdownCount = await probe.shutdownCount
        XCTAssertEqual(firstShutdownCount, 1)
        XCTAssertEqual(replies.values, [false])

        XCTAssertEqual(
            delegate.requestTermination { decision in
                replies.record(decision)
            },
            .terminateLater
        )
        await waitForReplyCount(2, replies: replies)
        let retryShutdownCount = await probe.shutdownCount
        XCTAssertEqual(retryShutdownCount, 2)
        XCTAssertEqual(replies.values, [false, true])
    }

    func testTerminationCoordinatorCoalescesConcurrentShutdownRequests() async {
        let probe = MacScopeAppShutdownProbe()
        let coordinator = MacScopeAppTerminationCoordinator {
            await probe.recordShutdown()
            await Task.yield()
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    await coordinator.terminate()
                }
            }
        }

        let shutdownCount = await probe.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
    }

    func testRuntimeServicesRetainsOneAuthorityGraphAcrossCompositionCopies() {
        let authorities = DebuggerRuntimeAuthorities()
        let services = MacScopeAppRuntimeServices.testing(
            debuggerRuntimeAuthorities: authorities,
            nativeDecompilerRuntime: .productionShared
        )
        let copiedServices = services

        XCTAssertTrue(
            services.debuggerRuntimeAuthorities.sessionLeaseRegistry
                === authorities.sessionLeaseRegistry
        )
        XCTAssertTrue(
            services.debuggerRuntimeAuthorities.ownedInfrastructureRegistry
                === authorities.ownedInfrastructureRegistry
        )
        XCTAssertTrue(
            copiedServices.debuggerRuntimeAuthorities.sessionLeaseRegistry
                === services.debuggerRuntimeAuthorities.sessionLeaseRegistry
        )
        XCTAssertTrue(
            copiedServices.debuggerRuntimeAuthorities.ownedInfrastructureRegistry
                === services.debuggerRuntimeAuthorities.ownedInfrastructureRegistry
        )
        XCTAssertTrue(
            copiedServices.nativeDecompilerRuntime === services.nativeDecompilerRuntime,
            "composition copies must retain one process-owned native decompiler runtime"
        )
        XCTAssertTrue(
            copiedServices.nativeDecompilerMemoryPressureMonitor
                === services.nativeDecompilerMemoryPressureMonitor,
            "composition copies must retain one process-owned memory-pressure monitor"
        )
        XCTAssertTrue(
            authorities.attachWriteInterlock
                === authorities.sessionLeaseRegistry.attachWriteInterlock
        )
        XCTAssertTrue(
            authorities.attachWriteInterlock
                === authorities.ownedInfrastructureRegistry.attachWriteInterlock
        )
    }

    func testSeparateWindowRootEnvironmentsReceiveIdenticalActorReferences() throws {
        let services = MacScopeAppRuntimeServices.productionShared
        var firstWindowRoot = EnvironmentValues()
        var secondWindowRoot = EnvironmentValues()

        firstWindowRoot.debuggerRuntimeAuthorities =
            services.debuggerRuntimeAuthorities
        secondWindowRoot.debuggerRuntimeAuthorities =
            services.debuggerRuntimeAuthorities

        let first = try XCTUnwrap(firstWindowRoot.debuggerRuntimeAuthorities)
        let second = try XCTUnwrap(secondWindowRoot.debuggerRuntimeAuthorities)
        XCTAssertTrue(
            first.sessionLeaseRegistry
                === services.debuggerRuntimeAuthorities.sessionLeaseRegistry
        )
        XCTAssertTrue(first.sessionLeaseRegistry === second.sessionLeaseRegistry)
        XCTAssertTrue(
            first.ownedInfrastructureRegistry
                === services.debuggerRuntimeAuthorities.ownedInfrastructureRegistry
        )
        XCTAssertTrue(
            first.ownedInfrastructureRegistry === second.ownedInfrastructureRegistry
        )
    }

    func testMissingEnvironmentInjectionBuildsNoFallbackAuthorities() {
        let isolatedRoot = EnvironmentValues()

        XCTAssertNil(isolatedRoot.debuggerRuntimeAuthorities)
        XCTAssertNil(
            WorkspaceRootView.makeDebuggerClient(runtimeAuthorities: nil)
                .runtimeAuthoritiesForTesting
        )
    }

    func testWindowClientsRetainTheExactInjectedAuthorityActors() throws {
        let authorities = DebuggerRuntimeAuthorities()
        let first = WorkspaceRootView.makeDebuggerClient(
            runtimeAuthorities: authorities
        )
        let second = WorkspaceRootView.makeDebuggerClient(
            runtimeAuthorities: authorities
        )

        let firstGraph = try XCTUnwrap(first.runtimeAuthoritiesForTesting)
        let secondGraph = try XCTUnwrap(second.runtimeAuthoritiesForTesting)
        XCTAssertTrue(
            firstGraph.sessionLeaseRegistry === authorities.sessionLeaseRegistry
        )
        XCTAssertTrue(
            secondGraph.sessionLeaseRegistry === authorities.sessionLeaseRegistry
        )
        XCTAssertTrue(
            firstGraph.ownedInfrastructureRegistry
                === authorities.ownedInfrastructureRegistry
        )
        XCTAssertTrue(
            secondGraph.ownedInfrastructureRegistry
                === authorities.ownedInfrastructureRegistry
        )
        XCTAssertTrue(first.capabilities.attachSupport.isSupported)
        XCTAssertTrue(second.capabilities.attachSupport.isSupported)
    }

    func testWindowClientThreadsExactOwnedRegistryIntoEveryPersistentLLDBConstructionPath() throws {
        let authorities = DebuggerRuntimeAuthorities()
        let client = WorkspaceRootView.makeDebuggerClient(
            runtimeAuthorities: authorities
        )

        let projection = try XCTUnwrap(
            client.persistentRuntimeAuthorityProjectionForTesting
        )
        let expectedOwnedIdentity = ObjectIdentifier(
            authorities.ownedInfrastructureRegistry
        )
        XCTAssertEqual(
            projection.ownedProcessLauncherRegistryIdentity,
            expectedOwnedIdentity
        )
        XCTAssertEqual(
            projection.targetlessTransportFactoryRegistryIdentity,
            expectedOwnedIdentity
        )
        XCTAssertEqual(
            projection.sessionLeaseRegistryIdentity,
            ObjectIdentifier(authorities.sessionLeaseRegistry)
        )
        XCTAssertTrue(projection.observationPolicyProviderIsAvailable)
        XCTAssertTrue(projection.isObservationPolicyAuthorityReady)
        XCTAssertEqual(
            projection.observationPolicyRegistryAuthority,
            authorities.observationPolicyProvider.registryAuthority
        )
        XCTAssertEqual(
            projection.sessionLeaseInterlockIdentity,
            authorities.attachWriteInterlock.identity
        )
        XCTAssertEqual(
            projection.ownedInfrastructureInterlockIdentity,
            authorities.attachWriteInterlock.identity
        )
        XCTAssertTrue(client.capabilities.launchSupport.isSupported)
        XCTAssertTrue(client.capabilities.attachSupport.isSupported)
    }

    func testInboundProbeClientRetainsAndInjectsOneExactAuthorityGraph() throws {
        let authorities = DebuggerRuntimeAuthorities()
        let client = LocalLLDBDebuggerClient(
            debuggerRuntimeAuthorities: authorities,
            inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe(
                needle: Data("owned-authority-smoke".utf8)
            )
        )

        let retained = try XCTUnwrap(client.runtimeAuthoritiesForTesting)
        XCTAssertTrue(
            retained.sessionLeaseRegistry === authorities.sessionLeaseRegistry
        )
        XCTAssertTrue(
            retained.ownedInfrastructureRegistry
                === authorities.ownedInfrastructureRegistry
        )
        let projection = try XCTUnwrap(
            client.persistentRuntimeAuthorityProjectionForTesting
        )
        let expectedOwnedIdentity = ObjectIdentifier(
            authorities.ownedInfrastructureRegistry
        )
        XCTAssertEqual(
            projection.ownedProcessLauncherRegistryIdentity,
            expectedOwnedIdentity
        )
        XCTAssertEqual(
            projection.targetlessTransportFactoryRegistryIdentity,
            expectedOwnedIdentity
        )
        XCTAssertTrue(projection.observationPolicyProviderIsAvailable)
        XCTAssertTrue(projection.isObservationPolicyAuthorityReady)
        XCTAssertEqual(
            projection.observationPolicyRegistryAuthority,
            authorities.observationPolicyProvider.registryAuthority
        )
        XCTAssertTrue(client.capabilities.launchSupport.isSupported)
        XCTAssertTrue(client.capabilities.attachSupport.isSupported)
    }

    func testIsolatedClientCreatesNoPersistentRuntimeAuthorityFallbacks() async throws {
        let client = LocalLLDBDebuggerClient()
        let projection = try XCTUnwrap(
            client.persistentRuntimeAuthorityProjectionForTesting
        )

        XCTAssertNil(projection.sessionLeaseRegistryIdentity)
        XCTAssertNil(projection.ownedProcessLauncherRegistryIdentity)
        XCTAssertNil(projection.targetlessTransportFactoryRegistryIdentity)
        XCTAssertNil(projection.sessionLeaseInterlockIdentity)
        XCTAssertNil(projection.ownedInfrastructureInterlockIdentity)
        XCTAssertFalse(projection.observationPolicyProviderIsAvailable)
        XCTAssertNil(projection.observationPolicyRegistryAuthority)
        XCTAssertFalse(projection.isObservationPolicyAuthorityReady)
        XCTAssertFalse(client.capabilities.attachSupport.isSupported)
        XCTAssertFalse(client.capabilities.launchSupport.isSupported)
        let missingAuthorityReason = try XCTUnwrap(
            client.capabilities.launchSupport.unavailableReason
        )
        XCTAssertEqual(
            missingAuthorityReason,
            PersistentLLDBProductionController.missingOwnedInfrastructureAuthorityReason
        )

        do {
            _ = try await client.launch(
                DebuggerLaunchConfiguration(executablePath: "/bin/echo")
            )
            XCTFail("An isolated client must not launch an unregistered LLDB child.")
        } catch let error as DebuggerClientError {
            guard case .backendUnavailable(let reason) = error else {
                return XCTFail("Expected missing-authority refusal, got \(error).")
            }
            XCTAssertTrue(reason.contains(missingAuthorityReason))
        }
    }

    func testPolicyProviderReadsTheExactOwnedRegistry() async throws {
        let authorities = DebuggerRuntimeAuthorities()
        guard case .resolved = await authorities.observationPolicyProvider.snapshot() else {
            return XCTFail("A fresh complete authority graph must produce a policy.")
        }

        _ = try await authorities.ownedInfrastructureRegistry.beginSpawn()

        let pendingResult = await authorities.observationPolicyProvider.snapshot()
        XCTAssertEqual(pendingResult.denial, .unstableSnapshot)
    }

    func testPolicyProviderReadsTheExactLeaseRegistry() async throws {
        let authorities = DebuggerRuntimeAuthorities()
        let identity = try runtimeAuthorityIdentity()
        _ = try await authorities.sessionLeaseRegistry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: DebuggerSessionTargetAuthority(origin: .attached(identity))
        )

        let result = await authorities.observationPolicyProvider.snapshot()
        guard case let .resolved(snapshot) = result else {
            return XCTFail("The provider must observe the injected lease registry.")
        }
        XCTAssertEqual(snapshot.revision.leaseMembership.rawValue, 1)
        XCTAssertEqual(
            snapshot.policy.excludedInfrastructure,
            [DebuggerLocalProcessInstanceKey(identity: identity)]
        )
    }

    func testWindowClientControllerReadsTheExactAppGlobalPolicyProvider() async throws {
        let authorities = DebuggerRuntimeAuthorities()
        let client = WorkspaceRootView.makeDebuggerClient(
            runtimeAuthorities: authorities
        )
        let identity = try runtimeAuthorityIdentity()
        _ = try await authorities.sessionLeaseRegistry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: DebuggerSessionEpoch(),
            authority: DebuggerSessionTargetAuthority(origin: .attached(identity))
        )

        let expected = await authorities.observationPolicyProvider.snapshot()
        let injectedSnapshot = await client.observationPolicySnapshotForTesting()
        let injected = try XCTUnwrap(injectedSnapshot)

        XCTAssertEqual(injected, expected)
        guard case let .resolved(snapshot) = injected else {
            return XCTFail("The controller must retain the complete app-global policy provider.")
        }
        XCTAssertEqual(snapshot.revision.leaseMembership.rawValue, 1)
        XCTAssertEqual(
            snapshot.policy.excludedInfrastructure,
            [DebuggerLocalProcessInstanceKey(identity: identity)]
        )
        XCTAssertTrue(client.capabilities.canAttach)
        XCTAssertTrue(client.capabilities.attachSupport.isSupported)
    }

    private func runtimeAuthorityIdentity() throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 91_001,
            startTime: try XCTUnwrap(
                DebuggerProcessStartIdentity(seconds: 8_100_001, microseconds: 17)
            ),
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeRuntimeAuthorityFixture",
            executableDeviceID: 7,
            executableFileID: 91_007,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: nil,
            codeIdentity: nil
        ))
    }

    private func waitForReplyCount(
        _ expectedCount: Int,
        replies: MacScopeAppTerminationReplyRecorder
    ) async {
        for _ in 0..<1_000 where replies.values.count < expectedCount {
            await Task.yield()
        }
    }
}

private actor MacScopeAppShutdownProbe {
    private(set) var shutdownCount = 0

    func recordShutdown() {
        shutdownCount += 1
    }
}

private actor MacScopeAppTerminationDecisionProbe {
    private var decisions: [Bool]
    private(set) var shutdownCount = 0

    init(decisions: [Bool]) {
        self.decisions = decisions
    }

    func nextDecision() -> Bool {
        shutdownCount += 1
        return decisions.removeFirst()
    }
}

@MainActor
private final class MacScopeAppTerminationReplyRecorder {
    private(set) var values: [Bool] = []

    func record(_ decision: Bool) {
        values.append(decision)
    }
}
