import XCTest
@testable import MacScope

@MainActor
final class DebuggerWorkspaceAuthorityTests: XCTestCase {
    func testEmptyDocumentRetainsAuthorityWithoutFocusedLaunchCandidate() throws {
        let store = WorkspaceStore(
            workspaceName: "Authority",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )

        let authority = try XCTUnwrap(store.debuggerWorkspaceAuthority)

        XCTAssertTrue(authority.isStructurallyValid)
        XCTAssertTrue(authority.artifactCatalog.artifacts.isEmpty)
        XCTAssertTrue(authority.breakpointResolutionCatalog.owners.isEmpty)
        XCTAssertNil(store.debuggerFocusedLaunchCandidate)
    }

    func testNilCandidateAndFocusChurnCannotMutateInstalledAuthority() throws {
        let store = WorkspaceStore(
            workspaceName: "Authority",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        let authority = try XCTUnwrap(store.debuggerWorkspaceAuthority)
        let viewModel = DebuggerPanelViewModel()
        viewModel.reconcileWorkspaceAuthority(authority)

        viewModel.reconcileFocusedLaunchCandidate(nil)
        XCTAssertEqual(viewModel.workspaceAuthority, authority)
        XCTAssertNil(viewModel.focusedLaunchCandidate)

        let primary = candidate(slot: .primary, binaryID: UUID(), path: "/bin/ls")
        let sibling = candidate(
            slot: ImageSlot(rawValue: 7),
            binaryID: UUID(),
            path: "/usr/bin/true"
        )
        viewModel.reconcileFocusedLaunchCandidate(primary)
        viewModel.reconcileFocusedLaunchCandidate(sibling)

        XCTAssertEqual(viewModel.workspaceAuthority, authority)
        XCTAssertEqual(viewModel.focusedLaunchCandidate, sibling)
    }

    func testExactEmptyRuntimeMappingIsRetainedAsZeroModuleProjection() throws {
        let processID: Int32 = 42
        let session = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(rawValue: UUID()),
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 2)
        )
        let stop = DebuggerStopCoordinate(
            session: session,
            stopRevision: DebuggerStopRevision(rawValue: 3)
        )
        let inventory = DebuggerRuntimeModuleInventory(
            revision: DebuggerRuntimeModuleInventoryRevision(rawValue: 4),
            stop: stop,
            processID: processID,
            observedStopID: 5,
            modules: []
        )
        let snapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: processID, reason: .step),
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Stopped.",
            backendState: .connected(processID: processID, adapterName: "Test"),
            transportSessionCoordinate: session,
            transportStopCoordinate: stop,
            transportEventSequence: DebuggerEventSequence(rawValue: 6),
            transportTargetDisposition: .stopped(processID: processID),
            transportRuntimeModuleAuthorityRevision:
                DebuggerRuntimeModuleAuthorityRevision(rawValue: 7),
            transportRuntimeModuleAuthority: .available(inventory)
        )
        let catalog = DebuggerWorkspaceArtifactCatalog(
            revision: DebuggerWorkspaceArtifactCatalogRevision(rawValue: 8),
            artifacts: []
        )

        let projection = try XCTUnwrap(
            DebuggerPanelViewModel.derivedRuntimeMappingProjection(
                for: snapshot,
                catalog: catalog
            )
        )

        XCTAssertEqual(projection.key.workspaceCatalogRevision, catalog.revision)
        XCTAssertTrue(projection.modules.isEmpty)
    }

    private func candidate(
        slot: ImageSlot,
        binaryID: UUID,
        path: String
    ) -> DebuggerFocusedLaunchCandidate {
        DebuggerFocusedLaunchCandidate(
            imageSlot: slot,
            launchTarget: .importedWorkspaceBinary(
                BinaryImage(
                    id: binaryID,
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    kind: "Mach-O executable",
                    architecture: "arm64",
                    slot: slot
                )
            ),
            gutterBreakpointAddresses: [],
            breakpointRevision: 1
        )
    }
}
