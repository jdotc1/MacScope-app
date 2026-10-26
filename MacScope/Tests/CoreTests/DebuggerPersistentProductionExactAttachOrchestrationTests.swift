import CryptoKit
import Foundation
import XCTest

@testable import MacScope

@MainActor
final class DebuggerPersistentProductionExactAttachOrchestrationTests: XCTestCase {
    func testFrameSelectionHelperFailureNeverRecoversAnUnperformedMutation() async throws {
        let program = LLDBVariableExtractorProgram.current
        let failingCommands = [
            try XCTUnwrap(program.installChunkCommands.first),
            program.installFinalizeCommand,
            program.installedProofCommand,
        ]
        for launched in [false, true] {
            for failingCommand in failingCommands {
                let fixture = try await ExactAttachControllerFixture(mode: .success, launched: launched)
                let snapshot = try await fixture.establish(launched: launched)
                await fixture.helper.armFailure(command: failingCommand)
                do {
                    _ = try await fixture.controller.selectFrame(
                        DebuggerFrameSelectionRequest(index: 0), from: snapshot
                    )
                    XCTFail("The helper failure must propagate.")
                } catch {
                    // A correlated helper rejection must not be classified as frame mutation.
                }
                let commands = await fixture.helper.commandsSinceFailureWasArmed
                XCTAssertTrue(commands.contains(failingCommand))
                XCTAssertFalse(commands.contains { $0.hasPrefix("frame select") })
                XCTAssertFalse(commands.contains("process kill"))
                XCTAssertFalse(commands.contains { Self.isExactDetachCommand($0) })
                XCTAssertFalse(commands.contains("thread list"))
                XCTAssertFalse(commands.contains("thread backtrace"))
                XCTAssertFalse(commands.contains { $0.hasPrefix("register read") })
                XCTAssertFalse(commands.contains { $0.hasPrefix("memory read") })
                // Prove the gate is released and a second operation still reaches the same
                // stopped target; keep the failure armed so no primary mutation can dispatch.
                await fixture.helper.armFailure(command: failingCommand)
                do {
                    _ = try await fixture.controller.selectFrame(
                        DebuggerFrameSelectionRequest(index: 0), from: snapshot
                    )
                    XCTFail("The second helper rejection must propagate.")
                } catch {}
                let secondCommands = await fixture.helper.commandsSinceFailureWasArmed
                XCTAssertTrue(secondCommands.contains(failingCommand))
                await fixture.controller.shutdown()
            }
        }
    }

    func testFrameSelectionPrimaryFailureRetainsExactlyOneOriginAwareRecovery() async throws {
        for launched in [false, true] {
            let fixture = try await ExactAttachControllerFixture(mode: .success, launched: launched)
            let snapshot = try await fixture.establish(launched: launched)
            // Reject the first inspection only after the frame-select command succeeded.
            await fixture.helper.armFailure(command: "thread list")
            do {
                _ = try await fixture.controller.selectFrame(
                    DebuggerFrameSelectionRequest(index: 0), from: snapshot
                )
                XCTFail("The primary failure must propagate.")
            } catch {}
            let commands = await fixture.helper.commandsSinceFailureWasArmed
            XCTAssertEqual(commands.filter { $0 == "frame select 0" }.count, 1)
            XCTAssertEqual(commands.filter { $0 == "process kill" }.count, launched ? 1 : 0)
            XCTAssertEqual(commands.filter { Self.isExactDetachCommand($0) }.count, launched ? 0 : 1)
            await fixture.controller.shutdown()
        }
    }

    /// §4.86a: `frame select` commits in its own exchange (LLDB pins the frame for the whole
    /// exchange), the inspection runs in the next one, and the variable helper is installed and
    /// proven before the selection with no reinstall between selection and inspection.
    func testFrameSelectionCommitsAloneThenInspectsWithTheRetainedHelper() async throws {
        let program = LLDBVariableExtractorProgram.current
        let installCommands = Set(
            PersistentLLDBProductionController.variableExtractorInstallationCommands(program: program)
        )
        for launched in [false, true] {
            let fixture = try await ExactAttachControllerFixture(mode: .success, launched: launched)
            let snapshot = try await fixture.establish(launched: launched)
            let before = await fixture.helper.exchanges.count
            do {
                _ = try await fixture.controller.selectFrame(
                    DebuggerFrameSelectionRequest(index: 0), from: snapshot
                )
            } catch DebuggerClientError.invalidState {
                // This scripted helper has no variable extractor, so the variable receipt in the
                // inspection is rejected; the stopped session survives. Only the exchange
                // structure is under test here (the live select-each test covers success).
            }
            let exchanges = Array(await fixture.helper.exchanges.dropFirst(before))
            let selectIndex = try XCTUnwrap(
                exchanges.firstIndex { $0.contains("frame select 0") },
                "\(exchanges)"
            )
            XCTAssertEqual(exchanges[selectIndex], ["frame select 0"])
            XCTAssertEqual(exchanges.filter { $0.contains("frame select 0") }.count, 1)
            let inspection = try XCTUnwrap(
                exchanges.indices.contains(selectIndex + 1) ? exchanges[selectIndex + 1] : nil
            )
            XCTAssertEqual(inspection.first, "thread list")
            XCTAssertFalse(inspection.contains("frame select 0"))
            // Retention: every helper install/proof precedes the selection; none follows it
            // before the inspection.
            let installIndices = exchanges.indices.filter {
                exchanges[$0].contains { installCommands.contains($0) }
            }
            XCTAssertTrue(installIndices.allSatisfy { $0 < selectIndex }, "\(installIndices)")
            if inspection.count > Self.stoppedRefreshCommandCount {
                // A variable snapshot rides in the inspection: the helper was proven first.
                XCTAssertTrue(
                    exchanges[..<selectIndex].contains { $0 == [program.installedProofCommand] }
                )
            }
            await fixture.controller.shutdown()
        }
    }

    private static let stoppedRefreshCommandCount = 4

    private static func isExactDetachCommand(_ command: String) -> Bool {
        guard let script = ExactAttachOwnedHelperChannel.decodedScript(from: command)
        else { return false }
        return script.contains("n['d'](")
    }

    func testRealTargetlessFactoryConfirmsAnAuthenticExactAttachSession() async throws {
        let fixture = try await ExactAttachControllerFixture(mode: .success)

        let snapshot = try await fixture.controller.performDormantExactAttachForTesting(
            fixture.request
        )

        let reservation = try XCTUnwrap(
            fixture.controller.lastExactAttachReservationProjectionForTesting
        )
        let leaseState = try await fixture.leaseRegistry.state(for: reservation)
        let evidence = try XCTUnwrap(fixture.controller.exactAttachedSessionEvidenceForTesting)
        let helperLaunchCount = await fixture.helper.launchCount
        let finalAttachWriteCount = await fixture.helper.finalAttachWriteCount
        let commands = await fixture.helper.semanticCommands

        guard case .paused(let processID, _) = snapshot.processState else {
            return XCTFail("Expected exact attach to leave the target paused.")
        }
        XCTAssertEqual(processID, fixture.identity.processID)
        XCTAssertEqual(leaseState, .confirmed)
        XCTAssertTrue(evidence.hasValidBinding())
        XCTAssertEqual(evidence.permit.authority.processID, fixture.identity.processID)
        XCTAssertEqual(helperLaunchCount, 1)
        XCTAssertEqual(finalAttachWriteCount, 1)
        XCTAssertTrue(commands.contains { $0.contains("__macscope_exact_attach") })
    }

    func testIncompleteAuthorityGraphAllocatesNeitherLeaseNorOwnedHelper() async throws {
        let fixture = try await ExactAttachControllerFixture(mode: .success, hasAuthority: false)

        do {
            _ = try await fixture.controller.performDormantExactAttachForTesting(fixture.request)
            XCTFail("An incomplete authority graph must fail closed before helper launch.")
        } catch {
            // Exact error wording is deliberately not an authorization surface.
        }

        let activeLeaseCount = await fixture.leaseRegistry.activeLeaseCount
        let owned = await fixture.ownedRegistry.snapshot
        let helperLaunchCount = await fixture.helper.launchCount

        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertEqual(helperLaunchCount, 0)
        XCTAssertEqual(owned.pendingSpawnCount, 0)
        XCTAssertEqual(owned.unresolvedSpawnCount, 0)
        XCTAssertTrue(owned.excludedInstances.isEmpty)
    }

    func testAuthorizationEvidenceRevisionDriftCleansTheLeaseAndHelperBeforeFinalWrite()
        async throws
    {
        let fixture = try await ExactAttachControllerFixture(mode: .success, revisionDrift: true)

        do {
            _ = try await fixture.controller.performDormantExactAttachForTesting(fixture.request)
            XCTFail("Post-revalidation revision drift must reject exact attach arming.")
        } catch {
            // The selected identity remains eligible; only the policy revision changes.
        }

        let activeLeaseCount = await fixture.leaseRegistry.activeLeaseCount
        let owned = await fixture.ownedRegistry.snapshot
        let finalAttachWriteCount = await fixture.helper.finalAttachWriteCount
        let helperLaunchCount = await fixture.helper.launchCount
        let hasBlocker = fixture.controller.hasUnresolvedExactAttachBlockerForTesting

        XCTAssertEqual(helperLaunchCount, 1)
        XCTAssertEqual(finalAttachWriteCount, 0)
        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertEqual(owned.pendingSpawnCount, 0)
        XCTAssertEqual(owned.unresolvedSpawnCount, 0)
        XCTAssertTrue(owned.excludedInstances.isEmpty)
        XCTAssertFalse(hasBlocker)
    }

    func testStagingEOFSettlesAsDefinitelyPrewriteAndRetiresTheHelper() async throws {
        let fixture = try await ExactAttachControllerFixture(mode: .firstStagingEOF)

        do {
            _ = try await fixture.controller.performDormantExactAttachForTesting(fixture.request)
            XCTFail("A staging EOF must fail the exact attach transaction.")
        } catch {
            // The adapter's EOF disposition is deliberately conservative for the staging write,
            // while the final attach command is still definitely not written.
        }

        let reservation = try XCTUnwrap(
            fixture.controller.lastExactAttachReservationProjectionForTesting
        )
        let activeLeaseCount = await fixture.leaseRegistry.activeLeaseCount
        let reservationStillExists: Bool
        do {
            _ = try await fixture.leaseRegistry.state(for: reservation)
            reservationStillExists = true
        } catch {
            reservationStillExists = false
        }
        let owned = await fixture.ownedRegistry.snapshot
        let finalAttachWriteCount = await fixture.helper.finalAttachWriteCount
        let hasBlocker = fixture.controller.hasUnresolvedExactAttachBlockerForTesting

        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertFalse(reservationStillExists)
        XCTAssertEqual(finalAttachWriteCount, 0)
        XCTAssertTrue(owned.excludedInstances.isEmpty)
        XCTAssertFalse(hasBlocker)
    }

    func testFinalEOFPinsUnknownWithoutDetachKillOrQuitRecovery() async throws {
        let fixture = try await ExactAttachControllerFixture(mode: .finalEOF)

        do {
            _ = try await fixture.controller.performDormantExactAttachForTesting(fixture.request)
            XCTFail("A final-write EOF must preserve unknown target disposition.")
        } catch {
            // The final adapter write can have partially succeeded, so the lease remains pinned.
        }

        let reservation = try XCTUnwrap(
            fixture.controller.lastExactAttachReservationProjectionForTesting
        )
        let reservationState = try await fixture.leaseRegistry.state(for: reservation)
        let activeLeaseCount = await fixture.leaseRegistry.activeLeaseCount
        let owned = await fixture.ownedRegistry.snapshot
        let commands = await fixture.helper.semanticCommands
        let hasBlocker = fixture.controller.hasUnresolvedExactAttachBlockerForTesting
        let evidence = fixture.controller.exactAttachedSessionEvidenceForTesting

        XCTAssertEqual(reservationState, .dispositionUnknown)
        XCTAssertEqual(activeLeaseCount, 1)
        XCTAssertTrue(owned.excludedInstances.isEmpty)
        XCTAssertTrue(hasBlocker)
        XCTAssertNil(evidence)
        XCTAssertFalse(commands.contains { command in
            let lowered = command.lowercased()
            return lowered.contains("process detach")
                || lowered.contains("process kill")
                || lowered == "quit"
        })
    }

    func testIdentityBoundAttachCapabilitiesAreAdvertisedWhenAuthorityGraphIsComplete()
        async throws
    {
        let fixture = try await ExactAttachControllerFixture(mode: .success)
        let client = LocalLLDBDebuggerClient(adapter: XcodeLLDBCommandLineAdapter(
            toolchain: fixture.toolchain,
            processRunner: ExactAttachCapabilityProcessRunner(),
            environment: [:],
            workingDirectory: "/tmp",
            usePersistentTransport: true,
            debuggerSessionLeaseRegistry: fixture.leaseRegistry,
            ownedInfrastructureRegistry: fixture.ownedRegistry,
            observationPolicyProvider: fixture.policyProvider
        ))

        XCTAssertTrue(client.capabilities.canAttach)
        XCTAssertTrue(client.capabilities.attachSupport.isSupported)

        let activeLeaseCount = await fixture.leaseRegistry.activeLeaseCount
        let helperLaunchCount = await fixture.helper.launchCount
        XCTAssertEqual(activeLeaseCount, 0)
        XCTAssertEqual(helperLaunchCount, 0)
    }
}

@MainActor
private final class ExactAttachControllerFixture {
    let identity: DebuggerLocalProcessIdentity
    let request: DebuggerLocalAttachRequest
    let toolchain: DebuggerLLDBToolchain
    let interlock: DebuggerLocalProcessAttachWriteInterlock
    let evidenceProvider: ExactAttachFixtureEvidenceProvider
    let leaseRegistry: DebuggerSessionLeaseRegistry
    let ownedRegistry: DebuggerOwnedInfrastructureRegistry
    let policyProvider: DebuggerLocalProcessObservationPolicyProvider
    let helper: ExactAttachOwnedHelperChannel
    let controller: PersistentLLDBProductionController

    init(
        mode: ExactAttachOwnedHelperChannel.Mode,
        revisionDrift: Bool = false,
        hasAuthority: Bool = true,
        launched: Bool = false
    ) async throws {
        if launched {
            identity = try await Self.makeLaunchIdentity()
        } else {
            identity = try Self.makeIdentity()
        }
        request = DebuggerLocalAttachRequest(selectedIdentity: identity)
        toolchain = Self.makeToolchain()
        interlock = Self.makeInterlock()
        evidenceProvider = try ExactAttachFixtureEvidenceProvider(
            targetIdentity: identity,
            helperProcessID: 8_812
        )
        leaseRegistry = DebuggerSessionLeaseRegistry(
            processEvidenceProvider: evidenceProvider,
            attachWriteInterlock: interlock
        )
        ownedRegistry = DebuggerOwnedInfrastructureRegistry(
            processEvidenceProvider: evidenceProvider,
            attachWriteInterlock: interlock
        )
        policyProvider = DebuggerLocalProcessObservationPolicyProvider(
            ownedInfrastructureRegistry: ownedRegistry,
            sessionLeaseRegistry: leaseRegistry,
            attachWriteInterlock: interlock
        )
        let preparedHelper = ExactAttachOwnedHelperChannel(
            mode: mode,
            processID: evidenceProvider.helperProcessID,
            targetIdentity: identity,
            evidenceProvider: evidenceProvider
        )
        helper = preparedHelper
        if revisionDrift {
            await evidenceProvider.enableRevisionDrift(using: leaseRegistry)
        }
        let processChannelLauncher: PersistentLLDBProductionController.ProcessChannelLauncher?
        if launched {
            processChannelLauncher = { _ in
                do {
                    try await preparedHelper.launchPreparedProcess()
                    return .acquired(preparedHelper)
                } catch {
                    return .failedAfterChild(
                        channel: preparedHelper, reason: "fixture launch failure"
                    )
                }
            }
        } else {
            processChannelLauncher = nil
        }
        controller = PersistentLLDBProductionController(
            toolchain: toolchain,
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            commandTimeoutSeconds: 1,
            launchedProcessEvidenceProvider: evidenceProvider,
            processChannelLauncher: processChannelLauncher,
            targetlessProcessPreparerForTesting: { _ in preparedHelper },
            debuggerSessionLeaseRegistry: leaseRegistry,
            ownedInfrastructureRegistry: ownedRegistry,
            observationPolicyProvider: hasAuthority ? policyProvider : nil
        )
    }

    func establish(launched: Bool) async throws -> DebuggerSessionSnapshot {
        if launched {
            return try await controller.launch(DebuggerLaunchConfiguration(executablePath: "/bin/echo"))
        }
        return try await controller.performDormantExactAttachForTesting(request)
    }

    private static func makeLaunchIdentity() async throws -> DebuggerLocalProcessIdentity {
        let grant = try await DebuggerExecutableSealer.seal(
            canonicalExecutablePath: "/bin/echo", timeout: .seconds(3)
        )
        let seal = try DebuggerLLDBSealedLaunchPlan.make(
            configuration: DebuggerLaunchConfiguration(executablePath: "/bin/echo"),
            executableSealingGrant: grant,
            toolchain: makeToolchain(), environment: [:],
            fallbackWorkingDirectory: "/tmp", timeout: .seconds(3)
        ).executableSeal
        let host = DebuggerLocalProcessObservationPolicyHostIdentity.current
        return try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 7_777,
            startTime: DebuggerProcessStartIdentity(seconds: 9_007_777, microseconds: 17)!,
            realUserID: host.realUserID, effectiveUserID: host.effectiveUserID,
            canonicalExecutablePath: seal.canonicalPath,
            executableDeviceID: seal.deviceID, executableFileID: seal.fileID,
            executableByteCount: seal.byteCount, executableSHA256: seal.sha256,
            architecture: seal.architecture == .arm64 ? .arm64 : .arm64e,
            machOUUID: seal.machOUUID, codeIdentity: nil
        ))
    }

    static func makeInterlock() -> DebuggerLocalProcessAttachWriteInterlock {
        DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
    }

    static func makeToolchain() -> DebuggerLLDBToolchain {
        let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? "/Applications/Xcode-beta.app/Contents/Developer"
        return DebuggerLLDBToolchain(
            executablePath: developerDirectory + "/usr/bin/lldb",
            developerDirectory: developerDirectory,
            discoverySource: "test",
            candidatePaths: []
        )
    }

    nonisolated static func makeIdentity(processID: Int32 = 7_777) throws
        -> DebuggerLocalProcessIdentity
    {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(
                seconds: UInt64(9_000_000 + processID),
                microseconds: 17
            )!,
            realUserID: DebuggerLocalProcessObservationPolicyHostIdentity.current.realUserID,
            effectiveUserID:
                DebuggerLocalProcessObservationPolicyHostIdentity.current.effectiveUserID,
            canonicalExecutablePath: "/tmp/MacScopeExactAttachFixture-\(processID)",
            executableDeviceID: 7,
            executableFileID: UInt64(processID),
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
    }
}

private actor ExactAttachFixtureEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    let targetIdentity: DebuggerLocalProcessIdentity
    let helperProcessID: Int32
    let helperFingerprint: DebuggerLocalProcessCatalogFingerprint
    private var helperIsPresent = false
    private var revisionDriftRegistry: DebuggerSessionLeaseRegistry?
    private var didAdvanceRevision = false

    init(targetIdentity: DebuggerLocalProcessIdentity, helperProcessID: Int32) throws {
        self.targetIdentity = targetIdentity
        self.helperProcessID = helperProcessID
        let start = DebuggerProcessStartIdentity(
            seconds: UInt64(10_000_000 + helperProcessID),
            microseconds: 31
        )!
        helperFingerprint = try XCTUnwrap(DebuggerLocalProcessCatalogFingerprint(
            processID: helperProcessID,
            startTime: start,
            realUserID: DebuggerLocalProcessObservationPolicyHostIdentity.current.realUserID,
            effectiveUserID:
                DebuggerLocalProcessObservationPolicyHostIdentity.current.effectiveUserID,
            canonicalExecutablePath: "/tmp/MacScopeExactAttachHelper-\(helperProcessID)",
            executableDeviceID: 8,
            executableFileID: UInt64(helperProcessID),
            executableByteCount: 8_192,
            executableChangeTimeNanoseconds: 42,
            architecture: .arm64,
            machOUUID: UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"),
            codeIdentity: nil
        ))
    }

    func enableRevisionDrift(using registry: DebuggerSessionLeaseRegistry) {
        revisionDriftRegistry = registry
    }

    func setHelperPresent(_ present: Bool) { helperIsPresent = present }

    func processIDs() -> DebuggerLocalProcessResolution<[Int32]> {
        .resolved(helperIsPresent
            ? [targetIdentity.processID, helperProcessID]
            : [targetIdentity.processID])
    }

    func catalogEvidence(
        processID: Int32
    ) -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        guard processID == helperProcessID, helperIsPresent else {
            return .unknown(.disappeared)
        }
        return .resolved(DebuggerLocalProcessCatalogEvidence(
            fingerprint: helperFingerprint,
            displayName: "lldb helper",
            parentProcessID: Int32(ProcessInfo.processInfo.processIdentifier),
            savedUserID: helperFingerprint.realUserID,
            dynamicState: DebuggerLocalProcessDynamicState()
        ))
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        guard processID == targetIdentity.processID,
              let fingerprint = DebuggerLocalProcessCatalogFingerprint(
                processID: targetIdentity.processID,
                startTime: targetIdentity.startTime,
                realUserID: targetIdentity.realUserID,
                effectiveUserID: targetIdentity.effectiveUserID,
                canonicalExecutablePath: targetIdentity.canonicalExecutablePath,
                executableDeviceID: targetIdentity.executableDeviceID,
                executableFileID: targetIdentity.executableFileID,
                executableByteCount: targetIdentity.executableByteCount,
                executableChangeTimeNanoseconds: 19,
                architecture: targetIdentity.architecture,
                machOUUID: targetIdentity.machOUUID,
                codeIdentity: targetIdentity.codeIdentity
              ) else {
            return .unknown(.disappeared)
        }
        if let registry = revisionDriftRegistry, !didAdvanceRevision {
            didAdvanceRevision = true
            let bystander = try? ExactAttachControllerFixture.makeIdentity(processID: 7_778)
            if let bystander,
               let reservation = try? await registry.reserve(
                ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
                sessionEpoch: DebuggerSessionEpoch(),
                authority: DebuggerSessionTargetAuthority(origin: .attached(bystander))
               ) {
                try? await registry.cancelBeforeTransportWrite(reservation)
            }
        }
        return .resolved(DebuggerLocalProcessAuthorizationEvidence(
            catalogEvidence: DebuggerLocalProcessCatalogEvidence(
                fingerprint: fingerprint,
                displayName: "target",
                parentProcessID: 1,
                savedUserID: targetIdentity.realUserID,
                dynamicState: DebuggerLocalProcessDynamicState()
            ),
            identity: targetIdentity
        ))
    }
}

private actor ExactAttachOwnedHelperChannel: PersistentLLDBOwnedPreparedProcessChannel {
    enum Mode: Sendable { case success, firstStagingEOF, finalEOF }

    private let mode: Mode
    private let processID: Int32
    private let targetIdentity: DebuggerLocalProcessIdentity
    private let evidenceProvider: ExactAttachFixtureEvidenceProvider
    private var reads: [Data?] = []
    private var readWaiters: [CheckedContinuation<Data?, Error>] = []
    private var didLaunch = false
    private var isRunning = false
    private var didReap = false
    private(set) var launchCount = 0
    private(set) var finalAttachWriteCount = 0
    private(set) var semanticCommands: [String] = []
    /// Semantic commands grouped by physical exchange, in write order.
    private(set) var exchanges: [[String]] = []
    private var failingCommand: String?
    private var armedCommandOffset = 0

    var commandsSinceFailureWasArmed: [String] {
        Array(semanticCommands.dropFirst(armedCommandOffset))
    }

    func armFailure(command: String) {
        failingCommand = command
        armedCommandOffset = semanticCommands.count
    }

    init(
        mode: Mode,
        processID: Int32,
        targetIdentity: DebuggerLocalProcessIdentity,
        evidenceProvider: ExactAttachFixtureEvidenceProvider
    ) {
        self.mode = mode
        self.processID = processID
        self.targetIdentity = targetIdentity
        self.evidenceProvider = evidenceProvider
    }

    func launchPreparedProcess() async throws {
        didLaunch = true
        isRunning = true
        launchCount += 1
        await evidenceProvider.setHelperPresent(true)
    }

    func write(_ data: Data) async throws {
        let exchange = try ExactAttachWireExchange.decode(data)
        semanticCommands.append(contentsOf: exchange.semanticCommands)
        exchanges.append(exchange.semanticCommands)
        if let failingCommand,
           let index = exchange.semanticCommands.firstIndex(of: failingCommand) {
            enqueue(ExactAttachWireExchange.framedResponse(
                markers: exchange.markers,
                commandTranscripts: Array(repeating: "", count: index)
                    + ["error: scripted semantic rejection"],
                status: "Process \(targetIdentity.processID) stopped",
                firstFailedCommandIndex: index
            ))
            return
        }
        if exchange.semanticCommands.contains(where: { command in
            Self.decodedScript(from: command)?.contains("n['d'](") == true
        }) {
            // The recovery request reaches the real adapter. A transport EOF then exercises
            // fail-closed retirement without pretending this fixture executed a real detach.
            isRunning = false
            enqueue(nil)
            return
        }
        if let command = exchange.semanticCommands.first(where: { command in
            (try? ExactAttachFinalAttachArguments(command: command)) != nil
        }),
           let arguments = try ExactAttachFinalAttachArguments(command: command) {
            finalAttachWriteCount += 1
            switch mode {
            case .success:
                enqueue(ExactAttachWireExchange.framedResponse(
                    markers: exchange.markers,
                    commandTranscripts: [try ExactAttachReceipt.make(
                        arguments: arguments,
                        identity: targetIdentity
                    )],
                    status: "Process \(targetIdentity.processID) stopped"
                ))
            case .firstStagingEOF:
                throw ExactAttachFixtureFailure.invalidWire
            case .finalEOF:
                isRunning = false
                enqueue(nil)
            }
        } else if mode == .firstStagingEOF {
            isRunning = false
            enqueue(nil)
        } else {
            enqueue(ExactAttachWireExchange.framedResponse(
                markers: exchange.markers,
                commandTranscripts: exchange.semanticCommands.map {
                    Self.transcript(for: $0, targetIdentity: targetIdentity)
                },
                status: Self.status(for: exchange.semanticCommands, targetIdentity: targetIdentity)
            ))
        }
    }

    func nextBytes() async throws -> Data? {
        if !reads.isEmpty { return reads.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            readWaiters.append(continuation)
        }
    }

    func closeInput() async {}
    func closeHandles() async {}
    func waitForExit(maximumDuration _: Duration) async -> Bool { didLaunch && !isRunning }
    func terminateRetainedAdapter() async { isRunning = false }
    func killRetainedAdapterIfStillRunning() async -> Bool {
        isRunning = false
        return true
    }

    func reapAndClose() async -> Bool {
        guard didLaunch, !isRunning else { return false }
        didReap = true
        await evidenceProvider.setHelperPresent(false)
        return true
    }

    func retainedProcessIdentifierForInfrastructure() async -> Int32 { processID }
    func retainedProcessIsRunningForInfrastructure() async -> Bool { isRunning }
    func retainedProcessDispositionForInfrastructure() async
        -> DebuggerOwnedInfrastructureRetainedProcessDisposition
    {
        if !didLaunch { return .notLaunched }
        if isRunning { return .running }
        return didReap ? .exitedAndReaped : .unknown
    }

    private func enqueue(_ response: Data?) {
        if readWaiters.isEmpty {
            reads.append(response)
        } else {
            readWaiters.removeFirst().resume(returning: response)
        }
    }

    private static func transcript(
        for command: String,
        targetIdentity: DebuggerLocalProcessIdentity
    ) -> String {
        switch command {
        case "thread list":
            return """
            * thread #1: tid = 0x2c, 0x0000000100001000 MacScopeFixture`main + 4, queue = 'com.apple.main-thread', stop reason = signal SIGSTOP
              frame #0: 0x0000000100001000 MacScopeFixture`main + 4
            """
        case "thread backtrace":
            return "frame #0: 0x0000000100001000 MacScopeFixture`main + 4"
        case let registerRead where registerRead.hasPrefix("register read --format x "):
            return """
            pc = 0x0000000100001000
            sp = 0x000000016fdfef00
            fp = 0x000000016fdfef20
            lr = 0x0000000100000ffc
            """
        case "memory read --format x --size 1 --count 64 $sp":
            return "0x000000016fdfef00: 00 01 02 03 04 05 06 07"
        default:
            if command == "process kill" { return "Process \(targetIdentity.processID) exited" }
            if let runtimeModuleTranscript = runtimeModuleTranscript(
                for: command,
                targetIdentity: targetIdentity
            ) {
                return runtimeModuleTranscript
            }
            return ""
        }
    }

    private static func status(
        for commands: [String],
        targetIdentity: DebuggerLocalProcessIdentity
    ) -> String {
        let stoppedRefreshCommands: Set<String> = [
            "thread list",
            "thread backtrace",
            "memory read --format x --size 1 --count 64 $sp",
        ]
        if commands.contains("process kill") { return "Process \(targetIdentity.processID) exited" }
        if commands.contains("process launch --stop-at-entry --no-stdio") {
            return "Process \(targetIdentity.processID) stopped"
        }
        if commands.contains(where: { LLDBVariableExtractorProgram.current.installChunkCommands.contains($0)
            || $0 == LLDBVariableExtractorProgram.current.installFinalizeCommand
            || $0 == LLDBVariableExtractorProgram.current.installedProofCommand }) {
            return "Process \(targetIdentity.processID) stopped"
        }
        if commands.contains(where: { command in
            command.contains("__macscope_exact_detach_install_v1")
                || (decodedScript(from: command)?.contains("__macscope_exact_detach_program_v1") == true)
        }) {
            // Exact detach staging inspects the existing target with a required PID. Installing
            // the helper does not remove that target's stopped process authority.
            return "Process \(targetIdentity.processID) stopped"
        }
        guard commands.contains(where: { command in
            stoppedRefreshCommands.contains(command)
                // LLDB reports process status after every exchange; a selection now commits
                // alone (#486 thread select, §4.86a frame select) and must still see it.
                || command.hasPrefix("frame select ")
                || command.hasPrefix("thread select ")
                || command.hasPrefix("register read --format x ")
                || isRuntimeModuleCommand(command)
        }) else { return "" }
        return "Process \(targetIdentity.processID) stopped"
    }

    private static func isRuntimeModuleCommand(_ command: String) -> Bool {
        command.contains("__macscope_lldb_module_install_v1")
            || (decodedScript(from: command)?.contains("__macscope_lldb_module_extractor_v1") ?? false)
    }

    private static func runtimeModuleTranscript(
        for command: String,
        targetIdentity: DebuggerLocalProcessIdentity
    ) -> String? {
        if let script = decodedScript(from: command) {
            if script.contains("MACSCOPE_LLDB_MODULE_INSTALL_V1") {
                return "MACSCOPE_LLDB_MODULE_INSTALL_V1 {\"ok\":true,\"schema\":1,\"sha256\":\"\(LLDBRuntimeModuleExtractorProgram.expectedSourceSHA256Hex)\"}\n"
            }
            if let token = embeddedRuntimeToken(
                in: script,
                prefix: "namespace['page']('",
                suffix: "',"
            ) {
                let digest = Data(SHA256.hash(data: Data("[]".utf8)))
                    .map { String(format: "%02x", $0) }
                    .joined()
                return "MACSCOPE_LLDB_MODULE_PAGE_V1 {\"digest\":\"\(digest)\",\"end\":0,\"final\":true,\"module_count\":0,\"modules\":[],\"observed_pid\":\(targetIdentity.processID),\"observed_state\":\"stopped\",\"observed_stop_id\":19,\"ok\":true,\"schema\":1,\"start\":0,\"token\":\"\(token)\"}\n"
            }
            if let token = embeddedRuntimeToken(
                in: script,
                prefix: "s.get('token')!='",
                suffix: "'"
            ) {
                return "MACSCOPE_LLDB_MODULE_CLEANUP_V1 {\"ok\":true,\"schema\":1,\"token\":\"\(token)\"}\n"
            }
        }
        if command.hasPrefix("script import builtins;"),
           command.contains("__macscope_lldb_module_install_v1")
        {
            return ""
        }
        return nil
    }

    fileprivate static func decodedScript(from command: String) -> String? {
        if let script = try? ExactAttachWireExchange.decodedBase64Argument(
            from: command,
            prefix: "script exec(__import__('base64').b64decode('",
            suffix: "').decode('utf-8'))"
        ) {
            return script
        }
        let prefix = "script exec("
        guard command.hasPrefix(prefix), command.hasSuffix(")") else { return nil }
        let literal = String(command.dropFirst(prefix.count).dropLast())
        return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }

    private static func embeddedRuntimeToken(
        in script: String,
        prefix: String,
        suffix: String
    ) -> String? {
        guard let prefixRange = script.range(of: prefix) else { return nil }
        let remainder = script[prefixRange.upperBound...]
        guard let suffixRange = remainder.range(of: suffix) else { return nil }
        let token = String(remainder[..<suffixRange.lowerBound])
        guard token.count == 64,
              token.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              }) else { return nil }
        return token
    }
}

private struct ExactAttachWireExchange {
    let markers: LLDBCLIExchangeMarkers
    let semanticCommands: [String]

    static func decode(_ wire: Data) throws -> ExactAttachWireExchange {
        let lines = String(data: wire, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        guard let markerLine = lines.first,
              lines.count == 2,
              let marker = try decodedBase64Argument(
                from: markerLine,
                prefix: "script print(__import__('base64').b64decode('",
                suffix: "').decode('ascii'))"
              ),
              marker.hasPrefix("__MACSCOPE_LLDB_REQUEST_BEGIN_"),
              marker.hasSuffix("__"),
              let program = try decodedBase64Argument(
                from: lines[1],
                prefix: "script exec(__import__('base64').b64decode('",
                suffix: "').decode('utf-8'))"
              ) else {
            throw ExactAttachFixtureFailure.invalidWire
        }
        let tokenStart = marker.index(marker.startIndex, offsetBy: "__MACSCOPE_LLDB_REQUEST_BEGIN_".count)
        let tokenEnd = marker.index(marker.endIndex, offsetBy: -2)
        let commandPrefix = "q=json.loads(b.b64decode('"
        let commandSuffix = "').decode())"
        guard let encodedCommands = embeddedArgument(
            in: program,
            prefix: commandPrefix,
            suffix: commandSuffix
        ),
              let commandBytes = Data(base64Encoded: encodedCommands),
              let commands = try? JSONDecoder().decode([String].self, from: commandBytes) else {
            throw ExactAttachFixtureFailure.invalidWire
        }
        return ExactAttachWireExchange(
            markers: try LLDBCLIExchangeMarkers(token: String(marker[tokenStart..<tokenEnd])),
            semanticCommands: commands
        )
    }

    static func framedResponse(
        markers: LLDBCLIExchangeMarkers,
        commandTranscripts: [String],
        status: String,
        firstFailedCommandIndex: Int? = nil
    ) -> Data {
        let resultLines = commandTranscripts.enumerated().map { index, transcript in
            "\(markers.commandResultPrefix)\(index)_\(Data(transcript.utf8).base64EncodedString())__"
        }
        let statusResult = "\(markers.statusResultPrefix)\(Data(status.utf8).base64EncodedString())__"
        return Data(([
            markers.requestBeginLine,
        ] + resultLines + [
            firstFailedCommandIndex.map { markers.commandsFailedLine(firstFailedCommandIndex: $0) }
                ?? markers.commandsSucceededLine,
            markers.statusBeginLine,
            statusResult,
            markers.statusEndLine,
            markers.requestEndLine,
        ]).joined(separator: "\n").appending("\n").utf8)
    }

    fileprivate static func decodedBase64Argument(
        from line: String,
        prefix: String,
        suffix: String
    ) throws -> String? {
        guard let encoded = argument(in: line, prefix: prefix, suffix: suffix),
              let bytes = Data(base64Encoded: encoded) else {
            return nil
        }
        return String(data: bytes, encoding: .utf8)
    }

    fileprivate static func argument(in string: String, prefix: String, suffix: String) -> String? {
        guard string.hasPrefix(prefix), string.hasSuffix(suffix) else { return nil }
        return String(string.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static func embeddedArgument(
        in string: String,
        prefix: String,
        suffix: String
    ) -> String? {
        guard let prefixRange = string.range(of: prefix) else { return nil }
        let remainder = string[prefixRange.upperBound...]
        guard let suffixRange = remainder.range(of: suffix) else { return nil }
        return String(remainder[..<suffixRange.lowerBound])
    }
}

private struct ExactAttachFinalAttachArguments {
    let correlationToken: Data
    let sessionEpoch: String
    let requestSequence: String
    let adapterGeneration: String
    let processID: String

    init?(command: String) throws {
        guard let script = try Self.decodedScript(from: command),
              let range = script.range(of: "n['attach'](") else {
            return nil
        }
        let argumentText = script[range.upperBound...]
        guard let closing = argumentText.firstIndex(of: ")") else {
            throw ExactAttachFixtureFailure.invalidWire
        }
        let fields = argumentText[..<closing].split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 7 else { throw ExactAttachFixtureFailure.invalidWire }
        let values = fields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
        guard let token = Self.hexData(values[0]), token.count == 32,
              Int32(values[4]) != nil else {
            throw ExactAttachFixtureFailure.invalidWire
        }
        correlationToken = token
        sessionEpoch = values[1]
        requestSequence = values[2]
        adapterGeneration = values[3]
        processID = values[4]
    }

    private static func decodedScript(from command: String) throws -> String? {
        if let script = try ExactAttachWireExchange.decodedBase64Argument(
            from: command,
            prefix: "script exec(__import__('base64').b64decode('",
            suffix: "').decode('utf-8'))"
        ) {
            return script
        }
        let prefix = "script exec("
        guard command.hasPrefix(prefix), command.hasSuffix(")") else { return nil }
        let literal = String(command.dropFirst(prefix.count).dropLast())
        return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }

    private static func hexData(_ text: String) -> Data? {
        guard text.count == 64 else { return nil }
        var result = Data()
        for offset in stride(from: 0, to: text.count, by: 2) {
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: 2)
            guard let byte = UInt8(text[start..<end], radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }
}

private enum ExactAttachReceipt {
    static func make(
        arguments: ExactAttachFinalAttachArguments,
        identity: DebuggerLocalProcessIdentity
    ) throws -> String {
        guard arguments.processID == String(identity.processID),
              let targetUUID = identity.machOUUID else {
            throw ExactAttachFixtureFailure.invalidWire
        }
        let payload = Phase2ProductionJSONValue.object([
            "adapter_generation": .number(arguments.adapterGeneration),
            "correlation_token": .string(arguments.correlationToken.map {
                String(format: "%02x", $0)
            }.joined()),
            "error": .object([
                "code": .number("0"), "kind": .number("0"),
                "message_b64": .string(""), "message_truncated": .bool(false),
            ]),
            "lldb_unique_id": .number("8811"),
            "observed_pid": .number(arguments.processID),
            "request_sequence": .number(arguments.requestSequence),
            "requested_pid": .number(arguments.processID),
            "schema": .number("1"), "selected_thread_id": .number("44"),
            "session_epoch": .string(arguments.sessionEpoch),
            "state": .string("stopped"), "stop_id": .number("19"),
            "stop_reason": .object([
                "data": .array([.number("5")]), "data_truncated": .bool(false),
                "kind": .string("signal"),
            ]),
            "target_path_b64": .string(
                Data(identity.canonicalExecutablePath.utf8).base64EncodedString()
            ),
            "target_uuid": .string(targetUUID.uuidString.lowercased()),
        ])
        let payloadBytes = payload.canonicalJSONBytes()
        let receipt = Phase2ProductionJSONValue.object([
            "payload": payload,
            "payload_sha256": .string(
                SHA256.hash(data: payloadBytes).map { String(format: "%02x", $0) }.joined()
            ),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
        return PersistentLLDBAttachProgram.receiptSentinel + receipt.base64EncodedString() + "\n"
    }
}

private struct ExactAttachCapabilityProcessRunner: DebuggerProcessRunning {
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

private enum ExactAttachFixtureFailure: Error {
    case invalidWire
}
