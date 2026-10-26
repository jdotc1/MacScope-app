import XCTest
@testable import MacScope

/// Tier-3 DEBUGGER-DEPTH — live-PC highlight derivation.
///
/// These exercise the *pure* program-counter derivation that bridges the debugger
/// session into the disassembly listing's live-PC row flag:
///
///  * `DebuggerSessionSnapshot.liveProgramCounter` is the top stopped-frame address
///    while paused at a live process, and `nil` for every non-paused/non-live state
///    (running, batch-stopped, exited, detached, or paused-but-frameless),
///  * `DebuggerPanelViewModel.currentProgramCounter` forwards that derivation and
///    clears to `nil` the moment the session resumes.
///
/// Fixtures are self-contained so this file never collides with the shared test
/// doubles in the other debugger test files.
@MainActor
final class DebuggerLivePCTests: XCTestCase {

    // MARK: - Fixtures

    private func frame(_ address: UInt64, index: Int = 0) -> DebuggerFrameSummary {
        DebuggerFrameSummary(
            index: index,
            address: address,
            functionName: "_main",
            moduleName: "example",
            sourceLocation: nil
        )
    }

    private func snapshot(
        processState: DebuggerProcessState,
        frames: [DebuggerFrameSummary],
        backendState: DebuggerBackendSessionState
    ) -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: processState,
            breakpoints: [],
            frames: frames,
            registers: [],
            memoryRegions: [],
            statusMessage: "",
            backendState: backendState
        )
    }

    // MARK: - Snapshot derivation

    func testLiveProgramCounterIsTopFrameWhenPausedLive() {
        let snap = snapshot(
            processState: .paused(processID: 222, reason: .breakpoint(address: 0x1000_0010)),
            frames: [frame(0x1000_0010, index: 0), frame(0x1000_0040, index: 1)],
            backendState: .connected(processID: 222, adapterName: "Test LLDB")
        )
        // Top frame (index 0) is the innermost — the instruction the process halted on.
        XCTAssertEqual(snap.liveProgramCounter, 0x1000_0010)
    }

    func testLiveProgramCounterNilWhenRunning() {
        let snap = snapshot(
            processState: .running(processID: 222, executableName: "example"),
            frames: [frame(0x1000_0010)],
            backendState: .connected(processID: 222, adapterName: "Test LLDB")
        )
        XCTAssertNil(snap.liveProgramCounter, "a running process exposes no live PC")
    }

    func testLiveProgramCounterNilWhenBatchStopped() {
        // Batch-stopped is not a live-controlled process, so no live PC even though
        // a frame address is present.
        let snap = snapshot(
            processState: .batchStopped(processID: 222, reason: .breakpoint(address: 0x1000_0010)),
            frames: [frame(0x1000_0010)],
            backendState: .ready(adapterName: "Batch LLDB")
        )
        XCTAssertNil(snap.liveProgramCounter)
    }

    func testLiveProgramCounterNilWhenExited() {
        let snap = snapshot(
            processState: .exited(code: 0),
            frames: [],
            backendState: .disconnected
        )
        XCTAssertNil(snap.liveProgramCounter)
    }

    func testLiveProgramCounterNilWhenPausedButBackendDetached() {
        // Paused process state but the backend is not connected to it -> not a live
        // session, so no live PC (mirrors `hasLiveProcessSession`).
        let snap = snapshot(
            processState: .paused(processID: 222, reason: .userRequested),
            frames: [frame(0x1000_0010)],
            backendState: .connected(processID: 999, adapterName: "Test LLDB")
        )
        XCTAssertNil(snap.liveProgramCounter)
    }

    func testLiveProgramCounterNilWhenPausedWithoutFrames() {
        // Stopped at a live process but the backend supplied no frames -> report nil
        // rather than guessing an address.
        let snap = snapshot(
            processState: .paused(processID: 222, reason: .userRequested),
            frames: [],
            backendState: .connected(processID: 222, adapterName: "Test LLDB")
        )
        XCTAssertNil(snap.liveProgramCounter)
    }

    // MARK: - View-model forwarding

    func testViewModelCurrentProgramCounterMirrorsStoppedSession() {
        let stopped = snapshot(
            processState: .paused(processID: 222, reason: .breakpoint(address: 0x1000_0010)),
            frames: [frame(0x1000_0010)],
            backendState: .connected(processID: 222, adapterName: "Live PC LLDB")
        )
        let client = LivePCStubDebuggerClient(initialSnapshot: stopped)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertEqual(viewModel.currentProgramCounter, 0x1000_0010)
    }

    func testViewModelCurrentProgramCounterNilWhenResumed() {
        let running = snapshot(
            processState: .running(processID: 222, executableName: "example"),
            frames: [frame(0x1000_0010)],
            backendState: .connected(processID: 222, adapterName: "Live PC LLDB")
        )
        let client = LivePCStubDebuggerClient(initialSnapshot: running)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertNil(viewModel.currentProgramCounter, "a resumed (running) process clears the live PC")
    }

    func testWorkspaceProgramCountersUseCheckedMappingForCurrentAndSelectedFrames() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let client = LivePCStubDebuggerClient(initialSnapshot: stopped)
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceArtifactCatalog(try matchingCatalog(for: stopped))

        XCTAssertEqual(viewModel.currentProgramCounter, 0x9010, "debugger display stays runtime")
        XCTAssertEqual(
            viewModel.currentWorkspaceProgramCounter,
            ImageAddress(slot: .primary, address: 0x1010)
        )

        await viewModel.selectFrame(1)

        XCTAssertEqual(viewModel.selectedFrameProgramCounter, 0xA018, "frame display stays runtime")
        XCTAssertEqual(
            viewModel.selectedFrameWorkspaceProgramCounter,
            ImageAddress(slot: ImageSlot(rawValue: 7), address: 0x1018)
        )
    }

    func testRawRuntimeInventoryGainsMappingWhenWorkspaceCatalogArrives() throws {
        var rawSnapshot = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let catalog = try matchingCatalog(for: rawSnapshot)
        rawSnapshot.runtimeMappingProjection = nil
        let viewModel = DebuggerPanelViewModel(
            client: LivePCStubDebuggerClient(initialSnapshot: rawSnapshot)
        )

        XCTAssertNil(viewModel.runtimeMappingProjection)
        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)

        viewModel.reconcileWorkspaceArtifactCatalog(catalog)

        XCTAssertEqual(
            viewModel.currentWorkspaceProgramCounter,
            ImageAddress(slot: .primary, address: 0x1010)
        )
        XCTAssertEqual(viewModel.runtimeMappingProjection?.key.workspaceCatalogRevision, catalog.revision)
    }

    func testCatalogRevisionRecomputesRawMappingWithoutTransportRequest() throws {
        var rawSnapshot = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let initialCatalog = try matchingCatalog(for: rawSnapshot)
        rawSnapshot.runtimeMappingProjection = nil
        let client = LivePCStubDebuggerClient(initialSnapshot: rawSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceArtifactCatalog(initialCatalog)
        let requestCount = client.requestCount
        let advancedCatalog = DebuggerWorkspaceArtifactCatalog(
            revision: .init(rawValue: initialCatalog.revision.rawValue + 1),
            artifacts: initialCatalog.artifacts
        )

        viewModel.reconcileWorkspaceArtifactCatalog(advancedCatalog)

        XCTAssertEqual(
            viewModel.currentWorkspaceProgramCounter,
            ImageAddress(slot: .primary, address: 0x1010)
        )
        XCTAssertEqual(
            viewModel.runtimeMappingProjection?.key.workspaceCatalogRevision,
            advancedCatalog.revision
        )
        XCTAssertEqual(client.requestCount, requestCount)
    }

    func testExpressionRevocationSurvivesCatalogReconciliationUntilRefreshedAuthorityArrives() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let evaluationStarted = expectation(description: "expression evaluation suspended")
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: stopped,
            expressionStarted: evaluationStarted
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        let initialCatalog = try matchingCatalog(for: stopped)
        viewModel.reconcileWorkspaceArtifactCatalog(initialCatalog)
        viewModel.reconcileWorkspaceCandidate(
            workspaceInput(for: try XCTUnwrap(initialCatalog.artifacts.first { $0.slot == .primary }))
        )
        await viewModel.launchSelectedTarget()
        XCTAssertEqual(
            viewModel.currentWorkspaceProgramCounter,
            ImageAddress(slot: .primary, address: 0x1010)
        )

        viewModel.expressionText = "1"
        let evaluation = Task { @MainActor in
            await viewModel.evaluate()
        }
        await fulfillment(of: [evaluationStarted], timeout: 2)
        XCTAssertNil(viewModel.runtimeMappingProjection)

        let advancedCatalog = DebuggerWorkspaceArtifactCatalog(
            revision: .init(rawValue: initialCatalog.revision.rawValue + 1),
            artifacts: initialCatalog.artifacts
        )
        viewModel.reconcileWorkspaceArtifactCatalog(advancedCatalog)

        XCTAssertNil(viewModel.runtimeMappingProjection)
        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
        // `testRunToCursorWithoutCurrentMappingSendsNoRuntimeRequest` separately proves that this
        // exact nil projection cannot issue a backend request. Avoid authoring an expected UI error
        // here because that intentionally supersedes the in-flight expression acceptance ticket.

        var refreshed = stopped
        refreshed.transportRuntimeModuleAuthorityRevision = .init(rawValue: 8)
        refreshed.runtimeMappingProjection = nil
        client.resumeSuspendedExpression(
            with: .success(
                DebuggerExpressionResult(
                    value: "1",
                    type: "int",
                    refreshedSnapshot: refreshed
                )
            )
        )
        await evaluation.value

        XCTAssertEqual(
            viewModel.currentWorkspaceProgramCounter,
            ImageAddress(slot: .primary, address: 0x1010),
            "a distinct accepted post-expression authority may restore checked mapping"
        )
    }

    func testAmbiguousRuntimeMappingKeepsRawPCButAbstainsFromWorkspacePC() throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0x9000])
        let viewModel = DebuggerPanelViewModel(
            client: LivePCStubDebuggerClient(initialSnapshot: stopped)
        )
        viewModel.reconcileWorkspaceArtifactCatalog(try matchingCatalog(for: stopped))

        XCTAssertEqual(viewModel.currentProgramCounter, 0x9010)
        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
    }

    func testStaleSuppliedMappingIsRebuiltFromCurrentRawAuthority() throws {
        var stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        stopped.transportRuntimeModuleAuthorityRevision = .init(rawValue: 8)
        let viewModel = DebuggerPanelViewModel(
            client: LivePCStubDebuggerClient(initialSnapshot: stopped)
        )
        viewModel.reconcileWorkspaceArtifactCatalog(try matchingCatalog(for: stopped))

        XCTAssertEqual(viewModel.currentProgramCounter, 0x9010)
        XCTAssertEqual(
            viewModel.currentWorkspaceProgramCounter,
            ImageAddress(slot: .primary, address: 0x1010)
        )
        XCTAssertEqual(viewModel.runtimeMappingProjection?.key.authorityRevision.rawValue, 8)
    }

    func testCatalogReplacementWithoutTransportRequestRevokesWorkspacePCsButKeepsRuntimePCs() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let client = LivePCStubDebuggerClient(initialSnapshot: stopped)
        let viewModel = DebuggerPanelViewModel(client: client)
        var bridgedProgramCounter: ImageAddress?
        DebuggerWorkspaceCatalogBridge.reconcile(
            try matchingCatalog(for: stopped),
            viewModel: viewModel,
            updateLiveProgramCounter: { bridgedProgramCounter = $0 }
        )
        await viewModel.selectFrame(1)

        XCTAssertEqual(viewModel.currentWorkspaceProgramCounter, ImageAddress(slot: .primary, address: 0x1010))
        XCTAssertEqual(
            viewModel.selectedFrameWorkspaceProgramCounter,
            ImageAddress(slot: ImageSlot(rawValue: 7), address: 0x1018)
        )

        let requestCountBeforeCatalogReplacement = client.requestCount
        let replacement = try replacementCatalog(for: stopped)
        DebuggerWorkspaceCatalogBridge.reconcile(
            replacement,
            viewModel: viewModel,
            updateLiveProgramCounter: { bridgedProgramCounter = $0 }
        )

        XCTAssertEqual(viewModel.currentProgramCounter, 0x9010, "catalog reconciliation never rewrites transport display state")
        XCTAssertEqual(viewModel.selectedFrameProgramCounter, 0xA018, "the selected frame keeps its raw runtime PC")
        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
        XCTAssertNil(viewModel.selectedFrameWorkspaceProgramCounter)
        XCTAssertNil(bridgedProgramCounter, "the production bridge clears the workspace live-PC target synchronously")
        XCTAssertNil(viewModel.runtimeMappingProjection, "same-slot replacement immediately revokes the stale derived projection")
        XCTAssertEqual(
            client.requestCount,
            requestCountBeforeCatalogReplacement,
            "catalog reconciliation never issues a transport request"
        )
    }

    func testSameRevisionOwnerReplacementRevokesProjectionByCoordinateIdentity() throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let viewModel = DebuggerPanelViewModel(
            client: LivePCStubDebuggerClient(initialSnapshot: stopped)
        )
        viewModel.reconcileWorkspaceArtifactCatalog(try matchingCatalog(for: stopped))

        XCTAssertNotNil(viewModel.currentWorkspaceProgramCounter)

        viewModel.reconcileWorkspaceArtifactCatalog(
            try replacementCatalog(for: stopped, advancesRevision: false)
        )

        XCTAssertEqual(viewModel.currentProgramCounter, 0x9010)
        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
        XCTAssertNil(viewModel.runtimeMappingProjection)
    }

    func testRunToCursorTranslatesQualifiedStaticAddressThroughCurrentMapping() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: stopped
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        let catalog = try matchingCatalog(for: stopped)
        viewModel.reconcileWorkspaceArtifactCatalog(catalog)
        viewModel.reconcileWorkspaceCandidate(
            workspaceInput(for: try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary }))
        )
        await viewModel.launchSelectedTarget()

        await viewModel.runToCursor(to: ImageAddress(slot: .primary, address: 0x1010))

        XCTAssertEqual(
            client.runToCursorRequests.map(\.resolvedAddress.runtimeAddress),
            [0x9010]
        )
        XCTAssertEqual(client.runToCursorRequests.map(\.observedStopID), [9])
    }

    func testRunToCursorWithZeroObservedStopIDSendsNoRuntimeRequest() async throws {
        var stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        guard case .available(let inventory) = stopped.transportRuntimeModuleAuthority else {
            return XCTFail("Fixture requires available runtime-module authority.")
        }
        stopped.transportRuntimeModuleAuthority = .available(DebuggerRuntimeModuleInventory(
            revision: inventory.revision,
            stop: inventory.stop,
            processID: inventory.processID,
            observedStopID: 0,
            modules: inventory.modules
        ))
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: stopped
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        let catalog = try matchingCatalog(for: stopped)
        viewModel.reconcileWorkspaceArtifactCatalog(catalog)
        viewModel.reconcileWorkspaceCandidate(
            workspaceInput(for: try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary }))
        )
        await viewModel.launchSelectedTarget()

        await viewModel.runToCursor(to: ImageAddress(slot: .primary, address: 0x1010))

        XCTAssertTrue(client.runToCursorRequests.isEmpty)
        XCTAssertNotNil(viewModel.lastError)
    }

    func testRunToCursorWithoutCurrentMappingSendsNoRuntimeRequest() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: stopped
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        let catalog = try matchingCatalog(for: stopped)
        viewModel.reconcileWorkspaceCandidate(
            workspaceInput(for: try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary }))
        )
        await viewModel.launchSelectedTarget()

        await viewModel.runToCursor(to: ImageAddress(slot: .primary, address: 0x1010))

        XCTAssertTrue(client.runToCursorRequests.isEmpty)
        XCTAssertNotNil(viewModel.lastError)
    }

    func testRunToCursorAfterCatalogOwnerReplacementSendsNoRuntimeRequest() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: stopped
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        let catalog = try matchingCatalog(for: stopped)
        viewModel.reconcileWorkspaceArtifactCatalog(catalog)
        viewModel.reconcileWorkspaceCandidate(
            workspaceInput(for: try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary }))
        )
        await viewModel.launchSelectedTarget()
        viewModel.reconcileWorkspaceArtifactCatalog(
            try replacementCatalog(for: stopped, advancesRevision: false)
        )

        await viewModel.runToCursor(to: ImageAddress(slot: .primary, address: 0x1010))

        XCTAssertTrue(client.runToCursorRequests.isEmpty)
        XCTAssertNotNil(viewModel.lastError)
    }

    func testRunToCursorWithMultipleCurrentLoadInstancesSendsNoRuntimeRequest() async throws {
        let uniquelyMapped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let catalog = try matchingCatalog(for: uniquelyMapped)
        let stopped = try snapshotWithDuplicatePrimaryLoadInstance(
            uniquelyMapped,
            runtimeStart: 0xB000
        )
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: stopped
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceArtifactCatalog(catalog)
        viewModel.reconcileWorkspaceCandidate(
            workspaceInput(for: try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary }))
        )
        await viewModel.launchSelectedTarget()

        await viewModel.runToCursor(to: ImageAddress(slot: .primary, address: 0x1010))

        XCTAssertTrue(client.runToCursorRequests.isEmpty)
        XCTAssertNotNil(viewModel.lastError)
    }

    func testCompleteLogicalInputNeverUsesLegacyBreakpointReplacementPath() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let catalog = try matchingCatalog(for: stopped)
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: stopped
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceArtifactCatalog(catalog)
        let artifact = try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary })
        let workspaceID = UUID(uuidString: "23232323-2323-2323-2323-232323232323")!
        let logicalCatalog = DebuggerLogicalBreakpointCatalog.freshPristine(
            catalogID: UUID(uuidString: "24242424-2424-2424-2424-242424242424")!
        )
        let logicalCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: logicalCatalog.catalogID,
            revision: logicalCatalog.revision
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: workspaceID,
            revision: .init(rawValue: 1),
            workspaceArtifactCatalogRevision: catalog.revision
        )
        let input = DebuggerWorkspaceInput(
            imageSlot: artifact.slot,
            launchTarget: .importedWorkspaceBinary(
                BinaryImage(
                    id: artifact.binaryID,
                    name: "Mapped Fixture",
                    path: "/bin/ls",
                    kind: "Mach-O executable",
                    architecture: "arm64"
                )
            ),
            gutterBreakpointAddresses: [],
            breakpointRevision: logicalCatalog.revision,
            logicalBreakpointCatalogAvailability: .available,
            logicalBreakpointCatalog: logicalCatalog,
            logicalBreakpointCatalogCoordinate: logicalCoordinate,
            breakpointResolutionCatalog: .init(
                coordinate: resolutionCoordinate,
                owners: []
            ),
            breakpointResolutionCatalogCoordinate: resolutionCoordinate
        )
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: input, artifactCatalog: catalog)
        )
        viewModel.reconcileWorkspaceCandidate(input)

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 1)
        XCTAssertEqual(client.logicalBreakpointReconcileRequests.first?.catalog, logicalCatalog)
        XCTAssertEqual(
            client.logicalBreakpointReconcileRequests.first?
                .observation.expectedSpecifications,
            []
        )
        XCTAssertEqual(client.legacyReplaceBreakpointsCallCount, 0)

        // A repeated stop/catalog notification produces the same complete request. It must be
        // deduplicated as one value rather than re-forwarding catalog and observation fragments.
        viewModel.reconcileWorkspaceArtifactCatalog(catalog)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 1)
        XCTAssertEqual(client.legacyReplaceBreakpointsCallCount, 0)
    }

    func testAttachedSessionWithoutFocusedLaunchCandidateReconcilesDocumentAuthority() async throws {
        var stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        stopped.transportTargetAuthority = try attachedAuthority(processID: 222)
        let catalog = try matchingCatalog(for: stopped)
        let authority = try emptyLogicalWorkspaceAuthority(artifactCatalog: catalog)
        let client = LivePCStubDebuggerClient(initialSnapshot: stopped)
        let viewModel = DebuggerPanelViewModel(client: client)

        XCTAssertNil(viewModel.focusedLaunchCandidate)
        XCTAssertNil(viewModel.workspaceInput)

        viewModel.reconcileWorkspaceAuthority(authority)
        for _ in 0..<20 where client.logicalBreakpointReconcileRequests.isEmpty {
            await Task.yield()
        }

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 1)
        XCTAssertEqual(client.logicalBreakpointReconcileRequests.first?.catalog, authority.logicalBreakpointCatalog)
        XCTAssertEqual(
            client.logicalBreakpointReconcileRequests.first?.observation.expectedSpecifications,
            []
        )
        XCTAssertNil(viewModel.focusedLaunchCandidate)
        XCTAssertNil(viewModel.workspaceInput)
        XCTAssertEqual(client.legacyReplaceBreakpointsCallCount, 0)
    }

    func testAcceptedModuleReloadRemintsLogicalBreakpointBindingIdentity() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let catalog = try matchingCatalog(for: stopped)
        let artifact = try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary })
        var input = completeDebuggerWorkspaceInputFixture(
            imageSlot: artifact.slot,
            launchTarget: .importedWorkspaceBinary(
                BinaryImage(
                    id: artifact.binaryID,
                    name: "Mapped Fixture",
                    path: "/bin/ls",
                    kind: "Mach-O executable",
                    architecture: "arm64"
                )
            ),
            gutterBreakpointAddresses: [0x1010]
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: input.logicalBreakpointCatalogCoordinate.workspaceID,
            revision: input.breakpointResolutionCatalogCoordinate.revision,
            workspaceArtifactCatalogRevision: catalog.revision
        )
        let ownerCoordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: artifact.binaryID,
            slot: artifact.slot,
            artifactIdentity: try XCTUnwrap(artifact.artifactIdentity),
            ownerRevision: artifact.ownerRevision
        )
        input.breakpointResolutionCatalog = .init(
            coordinate: resolutionCoordinate,
            owners: [
                DebuggerBreakpointResolutionOwnerIndex(
                    coordinate: ownerCoordinate,
                    revision: 1,
                    segments: [try XCTUnwrap(DebuggerBreakpointResolutionSegment(
                        name: "__TEXT",
                        preferredStart: 0x1000,
                        byteCount: 0x100,
                        isExecutable: true
                    ))],
                    staticAddresses: [DebuggerBreakpointStaticAddressEvidence(
                        preferredVA: 0x1010,
                        segmentName: "__TEXT",
                        kind: .decodedExecutableInstruction
                    )],
                    functions: [],
                    hasCanonicalRawSymbolAuthority: false,
                    rawSymbols: [],
                    hasExactSourceAuthority: false,
                    sourceRows: []
                )
            ]
        )
        input.breakpointResolutionCatalogCoordinate = resolutionCoordinate
        let pendingStopped = try initialPendingLogicalSnapshot(from: stopped, input: input)

        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: pendingStopped,
            logicalReconcileResult: { request, source, callIndex in
                return try Self.boundSnapshot(
                    from: source,
                    observation: request.observation,
                    backendBreakpointID: UInt64(callIndex + 1)
                )
            }
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: input, artifactCatalog: catalog)
        )
        viewModel.reconcileWorkspaceCandidate(input)

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 1)
        XCTAssertEqual(
            client.logicalBreakpointReconcileSourceSnapshots[0]
                .transportBreakpointBindingState?.resolutions.first?.state,
            .pending(.awaitingRuntimeInventory)
        )
        guard case .bound = viewModel.session.transportBreakpointBindingState?.backendState else {
            return XCTFail("The first accepted reconciliation must bind the logical breakpoint.")
        }
        let firstBinding = try XCTUnwrap(
            client.logicalBreakpointReconcileRequests[0].observation.results
                .flatMap(Self.bindings).first
        )

        client.enqueueRefreshSnapshot(try reloadedPendingSnapshot(from: viewModel.session))
        await viewModel.refreshSnapshot()
        for _ in 0..<20 where client.logicalBreakpointReconcileRequests.count < 2 {
            await Task.yield()
        }

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 2)
        XCTAssertEqual(client.logicalBreakpointReconcileSourceSnapshots.count, 2)
        XCTAssertEqual(
            client.logicalBreakpointReconcileSourceSnapshots[1]
                .transportBreakpointBindingState?.resolutions.first?.state,
            .pending(.moduleUnloaded),
            "the fresh request must be scheduled from the accepted module-unloaded snapshot"
        )
        guard case .bound = viewModel.session.transportBreakpointBindingState?.backendState else {
            return XCTFail("The reload reconciliation must finish with a fresh bound snapshot.")
        }

        let freshBinding = try XCTUnwrap(
            client.logicalBreakpointReconcileRequests[1].observation.results
                .flatMap(Self.bindings).first
        )
        XCTAssertNotEqual(firstBinding.id, freshBinding.id)
        XCTAssertNotEqual(
            firstBinding.id.moduleInstanceID,
            freshBinding.id.moduleInstanceID,
            "a reload must remint the transient binding against the fresh module instance"
        )
        XCTAssertNotEqual(firstBinding.mappingKey, freshBinding.mappingKey)
        XCTAssertEqual(client.legacyReplaceBreakpointsCallCount, 0)
    }

    func testUnavailableLogicalCatalogNeverReconcilesOrUsesLegacyReplacement() async throws {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let catalog = try matchingCatalog(for: stopped)
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: stopped
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceArtifactCatalog(catalog)
        let artifact = try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary })
        var input = workspaceInput(for: artifact)
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: input.breakpointResolutionCatalogCoordinate.workspaceID,
            revision: input.breakpointResolutionCatalogCoordinate.revision,
            workspaceArtifactCatalogRevision: catalog.revision
        )
        input.breakpointResolutionCatalog = .init(
            coordinate: resolutionCoordinate,
            owners: input.breakpointResolutionCatalog.owners
        )
        input.breakpointResolutionCatalogCoordinate = resolutionCoordinate
        input.logicalBreakpointCatalogAvailability = .unavailable
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: input, artifactCatalog: catalog)
        )
        viewModel.reconcileWorkspaceCandidate(input)

        await viewModel.launchSelectedTarget()

        XCTAssertTrue(client.logicalBreakpointReconcileRequests.isEmpty)
        XCTAssertEqual(client.legacyReplaceBreakpointsCallCount, 0)
    }

    func testUnavailableLogicalCatalogQuarantinesWithoutAutomaticTargetCommand() async throws {
        let (viewModel, client, input) = try boundLogicalBreakpointFixture()

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 1)
        XCTAssertEqual(viewModel.session.transportBreakpointBindingState?.ownedLocations.count, 1)

        var unavailable = try logicalBreakpointDeletionInput(from: input)
        unavailable.logicalBreakpointCatalogAvailability = .unavailable
        let artifactCatalog = try XCTUnwrap(viewModel.workspaceAuthority?.artifactCatalog)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: unavailable, artifactCatalog: artifactCatalog)
        )
        for _ in 0..<20 where !viewModel.session.statusMessage
            .localizedCaseInsensitiveContains("origin-aware debugger recovery") {
            await Task.yield()
        }

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 1)
        XCTAssertEqual(client.terminateCallCount, 0)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
        XCTAssertFalse(viewModel.canContinue)
        XCTAssertEqual(viewModel.session.transportBreakpointBindingState?.ownedLocations.count, 1)
    }

    func testUnavailableLogicalCatalogQuarantinesEveryResumeControl() async throws {
        let (viewModel, client, input) = try boundLogicalBreakpointFixture()

        await viewModel.launchSelectedTarget()

        var unavailable = try logicalBreakpointDeletionInput(from: input)
        unavailable.logicalBreakpointCatalogAvailability = .unavailable
        let artifactCatalog = try XCTUnwrap(viewModel.workspaceAuthority?.artifactCatalog)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: unavailable, artifactCatalog: artifactCatalog)
        )
        for _ in 0..<20 where !viewModel.session.statusMessage
            .localizedCaseInsensitiveContains("origin-aware debugger recovery") {
            await Task.yield()
        }

        XCTAssertEqual(client.terminateCallCount, 0)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
        XCTAssertEqual(viewModel.session.transportBreakpointBindingState?.ownedLocations.count, 1)
        XCTAssertFalse(viewModel.canContinue)
        XCTAssertFalse(viewModel.canRunToCursor)
        XCTAssertFalse(viewModel.canStepOver)
        XCTAssertFalse(viewModel.canStepInto)
        XCTAssertFalse(viewModel.canStepOut)

        let requestCountAfterFailedTermination = client.requestCount
        await viewModel.continueExecution()
        await viewModel.runToCursor(to: ImageAddress(slot: .primary, address: 0x1010))
        await viewModel.stepOver()
        await viewModel.stepInto()
        await viewModel.stepOut()

        XCTAssertEqual(client.requestCount, requestCountAfterFailedTermination)
        XCTAssertEqual(client.continueCallCount, 0)
        XCTAssertTrue(client.runToCursorRequests.isEmpty)
        XCTAssertEqual(client.stepOverCallCount, 0)
        XCTAssertEqual(client.stepIntoCallCount, 0)
        XCTAssertEqual(client.stepOutCallCount, 0)
    }

    func testUnavailableLogicalCatalogIsDetectedWithoutFocusedLaunchCandidate() async throws {
        let (sourceViewModel, _, input) = try boundLogicalBreakpointFixture()
        await sourceViewModel.launchSelectedTarget()
        XCTAssertEqual(
            sourceViewModel.session.transportBreakpointBindingState?.ownedLocations.count,
            1
        )

        var attachedSnapshot = sourceViewModel.session
        attachedSnapshot.transportTargetAuthority = try attachedAuthority(processID: 222)
        let client = LivePCStubDebuggerClient(initialSnapshot: attachedSnapshot)
        let viewModel = DebuggerPanelViewModel(client: client)
        var unavailable = input
        unavailable.breakpointRevision += 1
        unavailable.logicalBreakpointCatalogAvailability = .unavailable
        let artifactCatalog = try XCTUnwrap(
            sourceViewModel.workspaceAuthority?.artifactCatalog
        )

        XCTAssertNil(viewModel.focusedLaunchCandidate)
        XCTAssertNil(viewModel.workspaceInput)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: unavailable, artifactCatalog: artifactCatalog)
        )
        for _ in 0..<20 where !viewModel.session.statusMessage
            .localizedCaseInsensitiveContains("attached") {
            await Task.yield()
        }

        XCTAssertEqual(client.terminateCallCount, 0)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
        XCTAssertFalse(viewModel.canContinue)
        XCTAssertTrue(viewModel.session.statusMessage.localizedCaseInsensitiveContains("attached"))
        XCTAssertTrue(
            viewModel.session.statusMessage.localizedCaseInsensitiveContains("will not terminate")
        )
        XCTAssertTrue(client.logicalBreakpointReconcileRequests.isEmpty)
        XCTAssertNil(viewModel.focusedLaunchCandidate)
        XCTAssertNil(viewModel.workspaceInput)
    }

    func testNewerLogicalCatalogQuarantinesImmediateContinueUntilExactReconciliation() async throws {
        let reconcileStarted = expectation(description: "newer logical catalog reconcile started")
        let (viewModel, client, input) = try boundLogicalBreakpointFixture(
            suspendedLogicalReconcileCallIndex: 1,
            logicalReconcileStarted: reconcileStarted
        )
        await viewModel.launchSelectedTarget()
        let deletion = try logicalBreakpointDeletionInput(from: input)

        let artifactCatalog = try XCTUnwrap(viewModel.workspaceAuthority?.artifactCatalog)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: deletion, artifactCatalog: artifactCatalog)
        )
        viewModel.reconcileWorkspaceCandidate(deletion)

        XCTAssertFalse(viewModel.canContinue)
        let requestCountBeforeActiveReconcile = client.requestCount
        await viewModel.continueExecution()
        XCTAssertEqual(client.requestCount, requestCountBeforeActiveReconcile)
        XCTAssertEqual(client.continueCallCount, 0)

        await fulfillment(of: [reconcileStarted], timeout: 1.0)

        XCTAssertFalse(viewModel.canContinue)
        let requestCountWhilePending = client.requestCount
        await viewModel.continueExecution()
        XCTAssertEqual(client.requestCount, requestCountWhilePending)
        XCTAssertEqual(client.continueCallCount, 0)

        client.resumeSuspendedLogicalReconcile()
        for _ in 0..<20 where !viewModel.canContinue {
            await Task.yield()
        }

        XCTAssertTrue(viewModel.canContinue)
        XCTAssertTrue(
            viewModel.session.transportBreakpointBindingState?.ownedLocations.isEmpty == true
        )
        await viewModel.continueExecution()
        XCTAssertEqual(client.continueCallCount, 1)
    }

    func testSupersededLogicalSettlementsCannotClearSuccessiveAuthorityQuarantine() async throws {
        let (viewModel, client, input) = try boundLogicalBreakpointFixture(
            suspendedLogicalReconcileCallIndex: 1
        )
        await viewModel.launchSelectedTarget()
        let artifactCatalog = try XCTUnwrap(viewModel.workspaceAuthority?.artifactCatalog)
        let superseded = try logicalBreakpointDeletionInput(from: input)

        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: superseded, artifactCatalog: artifactCatalog)
        )
        for _ in 0..<20 where client.logicalBreakpointReconcileRequests.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 2)

        let current = try logicalBreakpointDeletionInput(from: superseded)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: current, artifactCatalog: artifactCatalog)
        )
        client.suspendLogicalReconcile(callIndex: 2)
        client.resumeSuspendedLogicalReconcile()
        for _ in 0..<20 where client.logicalBreakpointReconcileRequests.count < 3 {
            await Task.yield()
        }

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 3)
        XCTAssertFalse(
            viewModel.canContinue,
            "settlement for superseded authority must not clear the current authority's quarantine"
        )

        let newest = try logicalBreakpointDeletionInput(from: current)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: newest, artifactCatalog: artifactCatalog)
        )
        client.suspendLogicalReconcile(callIndex: 3)
        client.resumeSuspendedLogicalReconcile()
        for _ in 0..<20 where client.logicalBreakpointReconcileRequests.count < 4 {
            await Task.yield()
        }

        XCTAssertEqual(client.logicalBreakpointReconcileRequests.count, 4)
        XCTAssertFalse(
            viewModel.canContinue,
            "settlement for an in-flight authority must not clear its pending successor's quarantine"
        )

        client.resumeSuspendedLogicalReconcile()
        for _ in 0..<20 where !viewModel.canContinue {
            await Task.yield()
        }
        XCTAssertTrue(viewModel.canContinue)
    }

    func testActiveOwnerPreflightQuarantinesImmediateContinueWhileDifferentImageIsFocused() async throws {
        let (viewModel, client, inputA) = try boundLogicalBreakpointFixture()
        await viewModel.launchSelectedTarget()
        let focusedInputB = completeDebuggerWorkspaceInputFixture(
            imageSlot: ImageSlot(rawValue: 1),
            launchTarget: .importedWorkspaceBinary(
                BinaryImage(
                    id: UUID(uuidString: "BA000000-0000-0000-0000-00000000000B")!,
                    name: "Focused Sibling",
                    path: "/bin/cat",
                    kind: "Mach-O executable",
                    architecture: "arm64"
                )
            ),
            gutterBreakpointAddresses: []
        )
        viewModel.reconcileWorkspaceCandidate(focusedInputB)
        XCTAssertTrue(viewModel.canContinue)

        let deletionA = try logicalBreakpointDeletionInput(from: inputA)
        let artifactCatalog = try XCTUnwrap(viewModel.workspaceAuthority?.artifactCatalog)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: deletionA, artifactCatalog: artifactCatalog)
        )
        XCTAssertFalse(viewModel.canContinue)

        let requestCountAfterPreflight = client.requestCount
        await viewModel.continueExecution()

        XCTAssertEqual(client.requestCount, requestCountAfterPreflight)
        XCTAssertEqual(client.continueCallCount, 0)
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertEqual(viewModel.workspaceInput?.imageSlot, ImageSlot(rawValue: 1))
    }

    func testLaunchStopWithUnavailableRuntimeAuthorityQuarantinesResumeAndReportsDiagnostic() async throws {
        // The launch entry stop carries an honest runtime-module collection failure, so the
        // enabled saved logical breakpoint cannot acquire a checked runtime mapping and no
        // reconcile request can form. A silent abstention here leaves LLDB owning zero
        // breakpoints while Continue stays enabled — the resume would silently miss the
        // user's enabled breakpoint. Resume must quarantine and a diagnostic must surface.
        let (viewModel, client, _) = try boundLogicalBreakpointFixture(
            mutateLaunchStop: { launchStop in
                launchStop.transportRuntimeModuleAuthority = .unavailable(.refreshFailed(
                    DebuggerRuntimeModuleFailureEvidence(
                        redacting: "runtime module collection failed at the launch stop"
                    )
                ))
                launchStop.runtimeMappingProjection = nil
            }
        )
        await viewModel.launchSelectedTarget()

        XCTAssertNil(viewModel.runtimeMappingProjection)
        XCTAssertFalse(
            viewModel.canContinue,
            "an enabled saved logical breakpoint with no proven backend binding must quarantine resume"
        )
        XCTAssertNotNil(
            viewModel.lastError,
            "the logical-breakpoint reconciliation abstention must surface a diagnostic"
        )
        await viewModel.continueExecution()
        XCTAssertEqual(
            client.continueCallCount,
            0,
            "quarantined resume must not issue a backend continue"
        )
    }

    private func logicalBreakpointDeletionInput(
        from input: DebuggerWorkspaceInput
    ) throws -> DebuggerWorkspaceInput {
        var deletion = input
        let nextLogicalRevision = input.logicalBreakpointCatalog.revision + 1
        deletion.breakpointRevision = nextLogicalRevision
        deletion.logicalBreakpointCatalog = try DebuggerLogicalBreakpointCatalog(
            catalogID: input.logicalBreakpointCatalog.catalogID,
            revision: nextLogicalRevision,
            specifications: []
        )
        deletion.logicalBreakpointCatalogCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: input.logicalBreakpointCatalogCoordinate.workspaceID,
            catalogID: input.logicalBreakpointCatalog.catalogID,
            revision: nextLogicalRevision
        )
        let nextResolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: input.breakpointResolutionCatalogCoordinate.workspaceID,
            revision: .init(
                rawValue: input.breakpointResolutionCatalogCoordinate.revision.rawValue + 1
            ),
            workspaceArtifactCatalogRevision: input.breakpointResolutionCatalogCoordinate
                .workspaceArtifactCatalogRevision
        )
        deletion.breakpointResolutionCatalog = .init(
            coordinate: nextResolutionCoordinate,
            owners: input.breakpointResolutionCatalog.owners
        )
        deletion.breakpointResolutionCatalogCoordinate = nextResolutionCoordinate
        deletion.gutterBreakpointAddresses = []
        return deletion
    }

    private func boundLogicalBreakpointFixture(
        suspendedLogicalReconcileCallIndex: Int? = nil,
        logicalReconcileStarted: XCTestExpectation? = nil,
        mutateLaunchStop: ((inout DebuggerSessionSnapshot) -> Void)? = nil
    ) throws -> (DebuggerPanelViewModel, LivePCStubDebuggerClient, DebuggerWorkspaceInput) {
        let stopped = try mappedSnapshot(runtimeStarts: [0x9000, 0xA000])
        let catalog = try matchingCatalog(for: stopped)
        let artifact = try XCTUnwrap(catalog.artifacts.first { $0.slot == .primary })
        var input = completeDebuggerWorkspaceInputFixture(
            imageSlot: artifact.slot,
            launchTarget: .importedWorkspaceBinary(
                BinaryImage(
                    id: artifact.binaryID,
                    name: "Mapped Fixture",
                    path: "/bin/ls",
                    kind: "Mach-O executable",
                    architecture: "arm64"
                )
            ),
            gutterBreakpointAddresses: [0x1010]
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: input.logicalBreakpointCatalogCoordinate.workspaceID,
            revision: .init(rawValue: 1),
            workspaceArtifactCatalogRevision: catalog.revision
        )
        let ownerCoordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: artifact.binaryID,
            slot: artifact.slot,
            artifactIdentity: try XCTUnwrap(artifact.artifactIdentity),
            ownerRevision: artifact.ownerRevision
        )
        input.breakpointResolutionCatalog = .init(
            coordinate: resolutionCoordinate,
            owners: [
                DebuggerBreakpointResolutionOwnerIndex(
                    coordinate: ownerCoordinate,
                    revision: 1,
                    segments: [try XCTUnwrap(DebuggerBreakpointResolutionSegment(
                        name: "__TEXT",
                        preferredStart: 0x1000,
                        byteCount: 0x100,
                        isExecutable: true
                    ))],
                    staticAddresses: [DebuggerBreakpointStaticAddressEvidence(
                        preferredVA: 0x1010,
                        segmentName: "__TEXT",
                        kind: .decodedExecutableInstruction
                    )],
                    functions: [],
                    hasCanonicalRawSymbolAuthority: false,
                    rawSymbols: [],
                    hasExactSourceAuthority: false,
                    sourceRows: []
                )
            ]
        )
        input.breakpointResolutionCatalogCoordinate = resolutionCoordinate
        var launchStop = stopped
        mutateLaunchStop?(&launchStop)
        let pendingStopped = try initialPendingLogicalSnapshot(from: launchStop, input: input)
        let client = LivePCStubDebuggerClient(
            initialSnapshot: readySnapshot(),
            launchSnapshot: pendingStopped,
            suspendedLogicalReconcileCallIndex: suspendedLogicalReconcileCallIndex,
            logicalReconcileStarted: logicalReconcileStarted,
            logicalReconcileResult: { request, source, _ in
                if request.catalog.specifications.isEmpty {
                    return try Self.unboundSnapshot(
                        from: source,
                        observation: request.observation
                    )
                }
                return try Self.boundSnapshot(
                    from: source,
                    observation: request.observation,
                    backendBreakpointID: 1
                )
            }
        )
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceAuthority(
            workspaceAuthority(for: input, artifactCatalog: catalog)
        )
        viewModel.reconcileWorkspaceCandidate(input)
        return (viewModel, client, input)
    }

    private func readySnapshot() -> DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready.",
            backendState: .ready(adapterName: "Live PC LLDB")
        )
    }

    private func workspaceInput(
        for artifact: DebuggerWorkspaceArtifactCatalogEntry
    ) -> DebuggerWorkspaceInput {
        completeDebuggerWorkspaceInputFixture(
            imageSlot: artifact.slot,
            launchTarget: .importedWorkspaceBinary(
                BinaryImage(
                    id: artifact.binaryID,
                    name: "Mapped Fixture",
                    path: "/bin/ls",
                    kind: "Mach-O executable",
                    architecture: "arm64"
                )
            ),
            gutterBreakpointAddresses: []
        )
    }

    private func workspaceAuthority(
        for input: DebuggerWorkspaceInput,
        artifactCatalog: DebuggerWorkspaceArtifactCatalog
    ) -> DebuggerWorkspaceAuthority {
        DebuggerWorkspaceAuthority(
            workspaceID: input.logicalBreakpointCatalogCoordinate.workspaceID,
            artifactCatalog: artifactCatalog,
            logicalBreakpointCatalogAvailability: input.logicalBreakpointCatalogAvailability,
            logicalBreakpointCatalog: input.logicalBreakpointCatalog,
            logicalBreakpointCatalogCoordinate: input.logicalBreakpointCatalogCoordinate,
            breakpointResolutionCatalog: input.breakpointResolutionCatalog,
            breakpointResolutionCatalogCoordinate: input.breakpointResolutionCatalogCoordinate
        )
    }

    private func emptyLogicalWorkspaceAuthority(
        artifactCatalog: DebuggerWorkspaceArtifactCatalog
    ) throws -> DebuggerWorkspaceAuthority {
        let workspaceID = UUID(uuidString: "25252525-2525-2525-2525-252525252525")!
        let logicalCatalog = DebuggerLogicalBreakpointCatalog.freshPristine(
            catalogID: UUID(uuidString: "26262626-2626-2626-2626-262626262626")!
        )
        let logicalCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: logicalCatalog.catalogID,
            revision: logicalCatalog.revision
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: workspaceID,
            revision: .init(rawValue: 1),
            workspaceArtifactCatalogRevision: artifactCatalog.revision
        )
        return DebuggerWorkspaceAuthority(
            workspaceID: workspaceID,
            artifactCatalog: artifactCatalog,
            logicalBreakpointCatalogAvailability: .available,
            logicalBreakpointCatalog: logicalCatalog,
            logicalBreakpointCatalogCoordinate: logicalCoordinate,
            breakpointResolutionCatalog: .init(
                coordinate: resolutionCoordinate,
                owners: []
            ),
            breakpointResolutionCatalogCoordinate: resolutionCoordinate
        )
    }

    private func attachedAuthority(processID: Int32) throws -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(
            origin: .attached(try processIdentity(processID: processID))
        )
    }

    private func processIdentity(processID: Int32) throws -> DebuggerLocalProcessIdentity {
        let startTime = try XCTUnwrap(
            DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)
        )
        return try XCTUnwrap(
            DebuggerLocalProcessIdentity(
                processID: processID,
                startTime: startTime,
                realUserID: 501,
                effectiveUserID: 501,
                canonicalExecutablePath: "/tmp/MacScopeCandidateFreeAttachFixture",
                executableDeviceID: 7,
                executableFileID: 7_001,
                executableByteCount: 4_096,
                executableSHA256: String(repeating: "a", count: 64),
                architecture: .arm64,
                machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
                codeIdentity: nil
            )
        )
    }

    private func matchingCatalog(
        for snapshot: DebuggerSessionSnapshot
    ) throws -> DebuggerWorkspaceArtifactCatalog {
        let projection = try XCTUnwrap(snapshot.runtimeMappingProjection)
        let layout = try MachOPreferredSegmentLayout(
            records: [
                .init(
                    name: "__TEXT",
                    preferredVMStart: 0x1000,
                    preferredVMSize: 0x100,
                    sliceRelativeFileOffset: 0,
                    fileSize: 0x100,
                    initialProtections: 5
                )
            ],
            selectedSliceByteCount: 0x20_000
        )
        return DebuggerWorkspaceArtifactCatalog(
            revision: projection.key.workspaceCatalogRevision,
            artifacts: projection.modules.map { module in
                DebuggerWorkspaceArtifactCatalogEntry(
                    binaryID: module.coordinate.binaryID,
                    slot: module.coordinate.slot,
                    ownerRevision: module.coordinate.ownerRevision,
                    artifactIdentity: module.coordinate.artifactIdentity,
                    preferredSegmentLayout: layout,
                    artifactIntegrityState: .verified,
                    sourcePathHint: nil,
                    executablePathHint: nil
                )
            }
        )
    }

    private func replacementCatalog(
        for snapshot: DebuggerSessionSnapshot,
        advancesRevision: Bool = true
    ) throws -> DebuggerWorkspaceArtifactCatalog {
        let matching = try matchingCatalog(for: snapshot)
        return DebuggerWorkspaceArtifactCatalog(
            revision: .init(rawValue: matching.revision.rawValue + (advancesRevision ? 1 : 0)),
            artifacts: try matching.artifacts.map { entry in
                let identity = try XCTUnwrap(entry.artifactIdentity)
                let replacementIdentity = try MachOSliceArtifactIdentity(
                    uuid: UUID(uuidString: "77777777-7777-7777-7777-777777777777"),
                    rawCPUType: identity.rawCPUType,
                    rawCPUSubtype: identity.rawCPUSubtype,
                    selectedSliceSHA256: String(repeating: "b", count: 64),
                    selectedSliceByteCount: identity.selectedSliceByteCount
                )
                return DebuggerWorkspaceArtifactCatalogEntry(
                    binaryID: entry.slot == .primary
                        ? UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
                        : entry.binaryID,
                    slot: entry.slot,
                    ownerRevision: .init(rawValue: entry.ownerRevision.rawValue + 1),
                    artifactIdentity: replacementIdentity,
                    preferredSegmentLayout: entry.preferredSegmentLayout,
                    artifactIntegrityState: .verified,
                    sourcePathHint: entry.sourcePathHint,
                    executablePathHint: entry.executablePathHint
                )
            }
        )
    }

    private func snapshotWithDuplicatePrimaryLoadInstance(
        _ snapshot: DebuggerSessionSnapshot,
        runtimeStart: UInt64
    ) throws -> DebuggerSessionSnapshot {
        guard case .available(let inventory) = snapshot.transportRuntimeModuleAuthority else {
            throw XCTSkip("Fixture requires available runtime-module authority.")
        }
        let primary = try XCTUnwrap(inventory.modules.first)
        let sourceRange = try XCTUnwrap(primary.observation.mappedRanges.first)
        let duplicateRange = try XCTUnwrap(DebuggerRuntimeModuleMappedRangeObservation(
            sectionOrdinal: sourceRange.sectionOrdinal,
            sectionName: sourceRange.sectionName,
            staticStart: sourceRange.staticStart,
            runtimeStart: runtimeStart,
            byteCount: sourceRange.byteCount,
            permissions: sourceRange.permissions
        ))
        let duplicateObservation = try XCTUnwrap(DebuggerRuntimeModuleObservation(
            uuid: primary.observation.uuid,
            processID: inventory.processID,
            observedStopID: inventory.observedStopID,
            mappedRanges: [duplicateRange],
            fullPath: "/tmp/module-primary-duplicate",
            normalizedArchitectureTriple: primary.observation.normalizedArchitectureTriple,
            displayIndex: 2,
            fingerprintSHA256: Data(repeating: 0xDD, count: 32)
        ))
        let duplicate = DebuggerRuntimeModuleInstance(
            id: DebuggerRuntimeModuleInstanceID(
                processID: inventory.processID,
                stop: inventory.stop,
                inventoryRevision: inventory.revision,
                ordinal: 2
            ),
            observation: duplicateObservation
        )
        let duplicatedInventory = DebuggerRuntimeModuleInventory(
            revision: inventory.revision,
            stop: inventory.stop,
            processID: inventory.processID,
            observedStopID: inventory.observedStopID,
            modules: inventory.modules + [duplicate]
        )
        var result = snapshot
        result.transportRuntimeModuleAuthority = .available(duplicatedInventory)
        result.runtimeMappingProjection = nil
        return result
    }

    private static func bindings(
        _ resolution: DebuggerLogicalBreakpointResolution
    ) -> [DebuggerDesiredBreakpointBinding] {
        switch resolution.state {
        case .resolved(_, let binding): [binding]
        case .resolvedMultiple(_, let bindings): bindings
        default: []
        }
    }

    private func initialPendingLogicalSnapshot(
        from source: DebuggerSessionSnapshot,
        input: DebuggerWorkspaceInput
    ) throws -> DebuggerSessionSnapshot {
        let prior = try XCTUnwrap(source.transportBreakpointBindingState)
        let resolutions = input.logicalBreakpointCatalog.specifications.map {
            DebuggerLogicalBreakpointResolution(
                logicalID: $0.id,
                specificationRevision: $0.revision,
                state: .pending(.awaitingRuntimeInventory)
            )
        }
        let state = DebuggerBreakpointBindingReducerSnapshot(
            sessionEpoch: prior.sessionEpoch,
            authorityRevision: .init(rawValue: prior.authorityRevision.rawValue + 1),
            backendInventoryRevision: prior.backendInventoryRevision,
            desiredCatalogCoordinate: input.logicalBreakpointCatalogCoordinate,
            resolutionObservation: nil,
            currentStop: prior.currentStop,
            lifecycleHighWater: prior.lifecycleHighWater,
            stopHighWater: prior.stopHighWater,
            adapterGeneration: prior.adapterGeneration,
            observedPID: prior.observedPID,
            observedStopID: prior.observedStopID,
            resolutions: resolutions,
            backendState: .unbound,
            ownedLocations: [],
            pendingPlan: nil,
            observedHitCounts: [:],
            lastCallbackSequence: 0,
            isTerminal: false,
            isInvalidated: false
        )
        var result = source
        result.transportEventSequence = .init(
            rawValue: (source.transportEventSequence?.rawValue ?? 0) + 1
        )
        result.transportBreakpointBindingAuthorityRevision = state.authorityRevision
        result.transportBreakpointBindingState = state
        return result
    }

    private static func boundSnapshot(
        from source: DebuggerSessionSnapshot,
        observation: DebuggerBreakpointResolutionObservation,
        backendBreakpointID: UInt64
    ) throws -> DebuggerSessionSnapshot {
        let binding = try XCTUnwrap(observation.results.flatMap(bindings).first)
        let prior = try XCTUnwrap(source.transportBreakpointBindingState)
        let owned = try XCTUnwrap(DebuggerOwnedBackendBreakpointLocation(
            bindingID: binding.id,
            backendBreakpointID: backendBreakpointID,
            backendLocationID: 1,
            runtimeAddress: binding.runtimeAddress,
            ownershipTagDigest: try XCTUnwrap(DebuggerBreakpointDigest(Data(repeating: 0xA5, count: 32))),
            policyActionDigest: binding.policyActionDigest,
            issuanceDigest: binding.issuanceDigest
        ))
        let state = DebuggerBreakpointBindingReducerSnapshot(
            sessionEpoch: prior.sessionEpoch,
            authorityRevision: .init(rawValue: prior.authorityRevision.rawValue + 1),
            backendInventoryRevision: .init(rawValue: prior.backendInventoryRevision.rawValue + 1),
            desiredCatalogCoordinate: observation.logicalCatalogCoordinate,
            resolutionObservation: observation,
            currentStop: observation.mappingKey.stopCoordinate,
            lifecycleHighWater: observation.mappingKey.stopCoordinate.session.lifecycleRevision,
            stopHighWater: observation.mappingKey.stopCoordinate.stopRevision,
            adapterGeneration: prior.adapterGeneration,
            observedPID: observation.mappingKey.observedPID,
            observedStopID: prior.observedStopID,
            resolutions: observation.results,
            backendState: .bound([owned]),
            ownedLocations: [owned],
            pendingPlan: nil,
            observedHitCounts: prior.observedHitCounts,
            lastCallbackSequence: prior.lastCallbackSequence,
            isTerminal: false,
            isInvalidated: false
        )
        var result = source
        result.transportEventSequence = .init(
            rawValue: (source.transportEventSequence?.rawValue ?? 0) + 1
        )
        result.transportBreakpointBindingAuthorityRevision = state.authorityRevision
        result.transportBreakpointBindingState = state
        return result
    }

    private static func unboundSnapshot(
        from source: DebuggerSessionSnapshot,
        observation: DebuggerBreakpointResolutionObservation
    ) throws -> DebuggerSessionSnapshot {
        let prior = try XCTUnwrap(source.transportBreakpointBindingState)
        let state = DebuggerBreakpointBindingReducerSnapshot(
            sessionEpoch: prior.sessionEpoch,
            authorityRevision: .init(rawValue: prior.authorityRevision.rawValue + 1),
            backendInventoryRevision: .init(rawValue: prior.backendInventoryRevision.rawValue + 1),
            desiredCatalogCoordinate: observation.logicalCatalogCoordinate,
            resolutionObservation: observation,
            currentStop: observation.mappingKey.stopCoordinate,
            lifecycleHighWater: observation.mappingKey.stopCoordinate.session.lifecycleRevision,
            stopHighWater: observation.mappingKey.stopCoordinate.stopRevision,
            adapterGeneration: prior.adapterGeneration,
            observedPID: observation.mappingKey.observedPID,
            observedStopID: prior.observedStopID,
            resolutions: observation.results,
            backendState: .unbound,
            ownedLocations: [],
            pendingPlan: nil,
            observedHitCounts: prior.observedHitCounts,
            lastCallbackSequence: prior.lastCallbackSequence,
            callbackRecords: prior.callbackRecords,
            callbackDropCount: prior.callbackDropCount,
            isTerminal: false,
            isInvalidated: false
        )
        var result = source
        result.transportEventSequence = .init(
            rawValue: (source.transportEventSequence?.rawValue ?? 0) + 1
        )
        result.transportBreakpointBindingAuthorityRevision = state.authorityRevision
        result.transportBreakpointBindingState = state
        return result
    }

    private func reloadedPendingSnapshot(
        from source: DebuggerSessionSnapshot
    ) throws -> DebuggerSessionSnapshot {
        guard case .available(let priorInventory) = source.transportRuntimeModuleAuthority else {
            throw XCTSkip("Fixture requires available runtime-module authority.")
        }
        let priorProjection = try XCTUnwrap(source.runtimeMappingProjection)
        let priorBindingState = try XCTUnwrap(source.transportBreakpointBindingState)
        let inventoryRevision = DebuggerRuntimeModuleInventoryRevision(
            rawValue: priorInventory.revision.rawValue + 1
        )
        let instances = priorInventory.modules.map { module in
            DebuggerRuntimeModuleInstance(
                id: DebuggerRuntimeModuleInstanceID(
                    processID: module.id.processID,
                    stop: module.id.stop,
                    inventoryRevision: inventoryRevision,
                    ordinal: module.id.ordinal
                ),
                observation: module.observation
            )
        }
        let inventory = DebuggerRuntimeModuleInventory(
            revision: inventoryRevision,
            stop: priorInventory.stop,
            processID: priorInventory.processID,
            observedStopID: priorInventory.observedStopID,
            modules: instances
        )
        let authorityRevision = DebuggerRuntimeModuleAuthorityRevision(
            rawValue: try XCTUnwrap(source.transportRuntimeModuleAuthorityRevision).rawValue + 1
        )
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: priorProjection.key.stopCoordinate,
            observedPID: priorProjection.key.observedPID,
            authorityRevision: authorityRevision,
            inventoryRevision: inventoryRevision,
            workspaceCatalogRevision: priorProjection.key.workspaceCatalogRevision
        )
        let projection = DebuggerRuntimeMappingProjection(
            key: mappingKey,
            modules: zip(priorProjection.modules, instances).map { module, instance in
                DebuggerCorrelatedRuntimeModule(
                    instanceID: instance.id,
                    coordinate: module.coordinate,
                    mappedRanges: module.mappedRanges.map { range in
                        try! XCTUnwrap(DebuggerRuntimeMappedRange(
                            moduleInstanceID: instance.id,
                            sourceSectionOrdinal: range.sourceSectionOrdinal,
                            segmentName: range.segmentName,
                            staticStart: range.staticStart,
                            runtimeStart: range.runtimeStart,
                            byteCount: range.byteCount,
                            permissions: range.permissions
                        ))
                    }
                )
            }
        )
        let pendingResolutions = priorBindingState.resolutions.map {
            DebuggerLogicalBreakpointResolution(
                logicalID: $0.logicalID,
                specificationRevision: $0.specificationRevision,
                state: .pending(.moduleUnloaded)
            )
        }
        let bindingState = DebuggerBreakpointBindingReducerSnapshot(
            sessionEpoch: priorBindingState.sessionEpoch,
            authorityRevision: .init(rawValue: priorBindingState.authorityRevision.rawValue + 1),
            backendInventoryRevision: priorBindingState.backendInventoryRevision,
            desiredCatalogCoordinate: priorBindingState.desiredCatalogCoordinate,
            resolutionObservation: nil,
            currentStop: priorBindingState.currentStop,
            lifecycleHighWater: priorBindingState.lifecycleHighWater,
            stopHighWater: priorBindingState.stopHighWater,
            adapterGeneration: priorBindingState.adapterGeneration,
            observedPID: priorBindingState.observedPID,
            observedStopID: priorBindingState.observedStopID,
            resolutions: pendingResolutions,
            backendState: .armedUnobserved(priorBindingState.ownedLocations),
            ownedLocations: priorBindingState.ownedLocations,
            pendingPlan: nil,
            observedHitCounts: priorBindingState.observedHitCounts,
            lastCallbackSequence: priorBindingState.lastCallbackSequence,
            isTerminal: false,
            isInvalidated: false
        )
        var result = source
        result.transportEventSequence = .init(
            rawValue: (source.transportEventSequence?.rawValue ?? 0) + 1
        )
        result.transportRuntimeModuleAuthorityRevision = authorityRevision
        result.transportRuntimeModuleAuthority = .available(inventory)
        result.transportBreakpointBindingAuthorityRevision = bindingState.authorityRevision
        result.transportBreakpointBindingState = bindingState
        result.runtimeMappingProjection = projection
        return result
    }

    private func mappedSnapshot(runtimeStarts: [UInt64]) throws -> DebuggerSessionSnapshot {
        XCTAssertEqual(runtimeStarts.count, 2)
        let processID: Int32 = 222
        let sessionCoordinate = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(
                rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
            ),
            lifecycleRevision: .init(rawValue: 2)
        )
        let stopCoordinate = DebuggerStopCoordinate(
            session: sessionCoordinate,
            stopRevision: .init(rawValue: 3)
        )
        let inventoryRevision = DebuggerRuntimeModuleInventoryRevision(rawValue: 5)
        let authorityRevision = DebuggerRuntimeModuleAuthorityRevision(rawValue: 7)
        let slots: [ImageSlot] = [.primary, ImageSlot(rawValue: 7)]
        let moduleUUIDs = [
            UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
        ]

        var instances: [DebuggerRuntimeModuleInstance] = []
        var correlated: [DebuggerCorrelatedRuntimeModule] = []
        for index in runtimeStarts.indices {
            let instanceID = DebuggerRuntimeModuleInstanceID(
                processID: processID,
                stop: stopCoordinate,
                inventoryRevision: inventoryRevision,
                ordinal: UInt32(index)
            )
            let observedRange = try XCTUnwrap(DebuggerRuntimeModuleMappedRangeObservation(
                sectionOrdinal: 0,
                sectionName: "__TEXT",
                staticStart: 0x1000,
                runtimeStart: runtimeStarts[index],
                byteCount: 0x100,
                permissions: 5
            ))
            let observation = try XCTUnwrap(DebuggerRuntimeModuleObservation(
                uuid: moduleUUIDs[index],
                processID: processID,
                observedStopID: 9,
                mappedRanges: [observedRange],
                fullPath: "/tmp/module-\(index)",
                normalizedArchitectureTriple: "arm64-apple-macosx",
                displayIndex: UInt32(index),
                fingerprintSHA256: Data(repeating: UInt8(index + 1), count: 32)
            ))
            instances.append(DebuggerRuntimeModuleInstance(
                id: instanceID,
                observation: observation
            ))
            let coordinate = DebuggerWorkspaceArtifactCoordinate(
                binaryID: index == 0
                    ? UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
                    : UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                slot: slots[index],
                artifactIdentity: try MachOSliceArtifactIdentity(
                    uuid: moduleUUIDs[index],
                    rawCPUType: MachOConstants.cpuTypeARM64,
                    rawCPUSubtype: 0,
                    selectedSliceSHA256: String(repeating: "a", count: 64),
                    selectedSliceByteCount: 0x20_000
                ),
                ownerRevision: .init(rawValue: 1)
            )
            correlated.append(DebuggerCorrelatedRuntimeModule(
                instanceID: instanceID,
                coordinate: coordinate,
                mappedRanges: [try XCTUnwrap(DebuggerRuntimeMappedRange(
                    moduleInstanceID: instanceID,
                    sourceSectionOrdinal: 0,
                    segmentName: "__TEXT",
                    staticStart: 0x1000,
                    runtimeStart: runtimeStarts[index],
                    byteCount: 0x100,
                    permissions: 5
                ))]
            ))
        }

        let inventory = DebuggerRuntimeModuleInventory(
            revision: inventoryRevision,
            stop: stopCoordinate,
            processID: processID,
            observedStopID: 9,
            modules: instances
        )
        let projection = DebuggerRuntimeMappingProjection(
            key: DebuggerRuntimeMappingProjectionKey(
                stopCoordinate: stopCoordinate,
                observedPID: processID,
                authorityRevision: authorityRevision,
                inventoryRevision: inventoryRevision,
                workspaceCatalogRevision: .init(rawValue: 11)
            ),
            modules: correlated
        )
        var bindingReducer = DebuggerBreakpointBindingReducer(
            sessionEpoch: sessionCoordinate.epoch
        )
        XCTAssertTrue(bindingReducer.beganNewStop(
            stopCoordinate,
            adapterGeneration: 1,
            observedPID: processID,
            observedStopID: 9
        ))
        return DebuggerSessionSnapshot(
            processState: .paused(processID: processID, reason: .step),
            breakpoints: [],
            frames: [frame(0x9010), frame(0xA018, index: 1)],
            registers: [],
            memoryRegions: [],
            statusMessage: "Stopped.",
            backendState: .connected(processID: processID, adapterName: "Live PC LLDB"),
            transportSessionCoordinate: sessionCoordinate,
            transportStopCoordinate: stopCoordinate,
            transportEventSequence: .init(rawValue: 10),
            transportTargetDisposition: .stopped(processID: processID),
            transportRuntimeModuleAuthorityRevision: authorityRevision,
            transportRuntimeModuleAuthority: .available(inventory),
            transportBreakpointBindingAuthorityRevision:
                bindingReducer.snapshot.authorityRevision,
            transportBreakpointBindingState: bindingReducer.snapshot,
            runtimeMappingProjection: projection
        )
    }

    // MARK: - Store bridge

    func testStoreUpdateLiveProgramCounterSetsAndClears() {
        let store = WorkspaceStore(
            workspaceName: "Live PC",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [
                    InstructionRow(address: 0x1000, bytes: "", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
                ],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine()
        )

        XCTAssertNil(store.liveProgramCounter)

        store.updateLiveProgramCounter(0x1000)
        XCTAssertEqual(store.liveProgramCounter, 0x1000)

        // Clearing on resume/exit removes the highlight.
        store.updateLiveProgramCounter(nil)
        XCTAssertNil(store.liveProgramCounter)
    }
}

// MARK: - Self-contained test double

@MainActor
private final class LivePCStubDebuggerClient: DebuggerClient {
    typealias LogicalReconcileResult = (
        DebuggerLogicalBreakpointReconcileRequest,
        DebuggerSessionSnapshot,
        Int
    ) throws -> DebuggerSessionSnapshot

    private let initialSnapshot: DebuggerSessionSnapshot
    private let launchSnapshot: DebuggerSessionSnapshot?
    private let expressionStarted: XCTestExpectation?
    private var suspendedLogicalReconcileCallIndex: Int?
    private let logicalReconcileStarted: XCTestExpectation?
    private let logicalReconcileResult: LogicalReconcileResult?
    private var refreshSnapshots: [DebuggerSessionSnapshot] = []
    private var suspendedExpressionContinuation:
        CheckedContinuation<DebuggerExpressionResult, Error>?
    private var suspendedLogicalReconcileContinuation: CheckedContinuation<Void, Never>?
    private(set) var requestCount = 0
    private(set) var runToCursorRequests: [DebuggerRunToCursorRequest] = []
    private(set) var legacyReplaceBreakpointsCallCount = 0
    private(set) var logicalBreakpointReconcileRequests:
        [DebuggerLogicalBreakpointReconcileRequest] = []
    private(set) var logicalBreakpointReconcileSourceSnapshots:
        [DebuggerSessionSnapshot] = []
    private(set) var terminateCallCount = 0
    private(set) var continueCallCount = 0
    private(set) var stepOverCallCount = 0
    private(set) var stepIntoCallCount = 0
    private(set) var stepOutCallCount = 0

    init(
        initialSnapshot: DebuggerSessionSnapshot,
        launchSnapshot: DebuggerSessionSnapshot? = nil,
        expressionStarted: XCTestExpectation? = nil,
        suspendedLogicalReconcileCallIndex: Int? = nil,
        logicalReconcileStarted: XCTestExpectation? = nil,
        logicalReconcileResult: LogicalReconcileResult? = nil
    ) {
        self.initialSnapshot = initialSnapshot
        self.launchSnapshot = launchSnapshot
        self.expressionStarted = expressionStarted
        self.suspendedLogicalReconcileCallIndex = suspendedLogicalReconcileCallIndex
        self.logicalReconcileStarted = logicalReconcileStarted
        self.logicalReconcileResult = logicalReconcileResult
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Live PC LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { initialSnapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { requestCount += 1; return launchSnapshot ?? initialSnapshot }
    func runToCursor(_ request: DebuggerRunToCursorRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        runToCursorRequests.append(request)
        return snapshot
    }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        continueCallCount += 1
        return snapshot
    }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        stepOverCallCount += 1
        return snapshot
    }
    func stepInto(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        stepIntoCallCount += 1
        return snapshot
    }
    func stepOut(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        stepOutCallCount += 1
        return snapshot
    }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { requestCount += 1; return snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        terminateCallCount += 1
        var result = snapshot
        result.processState = .exited(code: 0)
        result.backendState = .ready(adapterName: "Live PC LLDB")
        result.statusMessage = "Terminated."
        result.frames = []
        result.transportEventSequence = .init(
            rawValue: (snapshot.transportEventSequence?.rawValue ?? 0) + 1
        )
        result.transportTargetDisposition = .terminated
        if let runtimeAuthorityRevision = snapshot.transportRuntimeModuleAuthorityRevision {
            result.transportRuntimeModuleAuthorityRevision = .init(
                rawValue: runtimeAuthorityRevision.rawValue + 1
            )
            result.transportRuntimeModuleAuthority = .unavailable(.terminal)
            result.runtimeMappingProjection = nil
        }
        if let prior = snapshot.transportBreakpointBindingState {
            let terminal = DebuggerBreakpointBindingReducerSnapshot(
                sessionEpoch: prior.sessionEpoch,
                authorityRevision: .init(rawValue: prior.authorityRevision.rawValue + 1),
                backendInventoryRevision: prior.backendInventoryRevision,
                desiredCatalogCoordinate: prior.desiredCatalogCoordinate,
                resolutionObservation: prior.resolutionObservation,
                currentStop: prior.currentStop,
                lifecycleHighWater: prior.lifecycleHighWater,
                stopHighWater: prior.stopHighWater,
                adapterGeneration: prior.adapterGeneration,
                observedPID: prior.observedPID,
                observedStopID: prior.observedStopID,
                resolutions: prior.resolutions,
                backendState: .unbound,
                ownedLocations: [],
                pendingPlan: nil,
                observedHitCounts: prior.observedHitCounts,
                lastCallbackSequence: prior.lastCallbackSequence,
                callbackRecords: prior.callbackRecords,
                callbackDropCount: prior.callbackDropCount,
                isTerminal: true,
                isInvalidated: false
            )
            result.transportBreakpointBindingAuthorityRevision = terminal.authorityRevision
            result.transportBreakpointBindingState = terminal
        }
        return result
    }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        legacyReplaceBreakpointsCallCount += 1
        return snapshot
    }
    func reconcileLogicalBreakpoints(
        _ request: DebuggerLogicalBreakpointReconcileRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        logicalBreakpointReconcileRequests.append(request)
        logicalBreakpointReconcileSourceSnapshots.append(snapshot)
        let callIndex = logicalBreakpointReconcileRequests.count - 1
        if suspendedLogicalReconcileCallIndex == callIndex {
            logicalReconcileStarted?.fulfill()
            await withCheckedContinuation { continuation in
                suspendedLogicalReconcileContinuation = continuation
            }
        }
        return try logicalReconcileResult?(
            request,
            snapshot,
            callIndex
        ) ?? snapshot
    }

    func resumeSuspendedLogicalReconcile() {
        guard let continuation = suspendedLogicalReconcileContinuation else {
            XCTFail("No logical-breakpoint reconciliation is suspended.")
            return
        }
        suspendedLogicalReconcileContinuation = nil
        continuation.resume()
    }

    func suspendLogicalReconcile(callIndex: Int) {
        suspendedLogicalReconcileCallIndex = callIndex
    }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requestCount += 1
        return refreshSnapshots.isEmpty ? snapshot : refreshSnapshots.removeFirst()
    }

    func enqueueRefreshSnapshot(_ snapshot: DebuggerSessionSnapshot) {
        refreshSnapshots.append(snapshot)
    }
    func selectFrame(_ request: DebuggerFrameSelectionRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { requestCount += 1; return snapshot }
    func evaluateExpression(
        _ request: DebuggerExpressionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerExpressionResult {
        requestCount += 1
        guard let expressionStarted else {
            return DebuggerExpressionResult(value: "1", type: "int")
        }
        expressionStarted.fulfill()
        return try await withCheckedThrowingContinuation { continuation in
            suspendedExpressionContinuation = continuation
        }
    }

    func resumeSuspendedExpression(
        with result: Result<DebuggerExpressionResult, Error>
    ) {
        guard let continuation = suspendedExpressionContinuation else {
            XCTFail("No expression evaluation is suspended.")
            return
        }
        suspendedExpressionContinuation = nil
        continuation.resume(with: result)
    }
}
