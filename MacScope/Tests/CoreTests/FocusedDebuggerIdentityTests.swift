import XCTest
@testable import MacScope

/// Frozen WS-17 debugger identity oracles. Every workspace/debugger crossing below is either one
/// complete `DebuggerWorkspaceInput` or one `ImageAddress`; the legacy bare target, gutter, PC, and
/// Run to Cursor projections are deliberately not acceptance seams for multi-image behavior.
@MainActor
final class FocusedDebuggerIdentityTests: XCTestCase {
    private let sibling = ImageSlot(rawValue: 7)
    private let noAnalysis = ImageSlot(rawValue: 9)
    private let unloadable = ImageSlot(rawValue: 11)
    private let collision: UInt64 = 0x1_0000_0000
    private let siblingEarlier: UInt64 = 0x1_0000_0008
    private let primaryOnly: UInt64 = 0x1_0000_0010
    private let siblingOnly: UInt64 = 0x1_0000_0020
    private let missing: UInt64 = 0x1_0000_00f0

    func testExactSiblingWorkspaceInputIsAtomicSortedAndFocused() throws {
        let store = makeStore()
        let binary = try XCTUnwrap(store.snapshot.binary(in: sibling))
        store.focusImage(sibling)
        let authority = try XCTUnwrap(store.debuggerWorkspaceInput(in: sibling))

        XCTAssertEqual(
            authority,
            DebuggerWorkspaceInput(
                imageSlot: sibling,
                launchTarget: .importedWorkspaceBinary(binary),
                gutterBreakpointAddresses: [siblingEarlier, siblingOnly],
                breakpointRevision: authority.breakpointRevision,
                logicalBreakpointCatalogAvailability: authority.logicalBreakpointCatalogAvailability,
                logicalBreakpointCatalog: authority.logicalBreakpointCatalog,
                logicalBreakpointCatalogCoordinate: authority.logicalBreakpointCatalogCoordinate,
                breakpointResolutionCatalog: authority.breakpointResolutionCatalog,
                breakpointResolutionCatalogCoordinate: authority.breakpointResolutionCatalogCoordinate
            )
        )
        XCTAssertEqual(store.debuggerWorkspaceInput, store.debuggerWorkspaceInput(in: sibling))
    }

    func testLoadedNoAnalysisAndBlockedInputsAreExactWhileAbsentAndRemovedSlotsFailClosed() throws {
        let store = makeStore()
        let binary = try XCTUnwrap(store.snapshot.binary(in: noAnalysis))
        let blockedBinary = try XCTUnwrap(store.snapshot.binary(in: unloadable))
        let authority = try XCTUnwrap(store.debuggerWorkspaceInput(in: noAnalysis))

        XCTAssertEqual(
            authority,
            DebuggerWorkspaceInput(
                imageSlot: noAnalysis,
                launchTarget: .importedWorkspaceBinary(binary),
                gutterBreakpointAddresses: [],
                breakpointRevision: authority.breakpointRevision,
                logicalBreakpointCatalogAvailability: authority.logicalBreakpointCatalogAvailability,
                logicalBreakpointCatalog: authority.logicalBreakpointCatalog,
                logicalBreakpointCatalogCoordinate: authority.logicalBreakpointCatalogCoordinate,
                breakpointResolutionCatalog: authority.breakpointResolutionCatalog,
                breakpointResolutionCatalogCoordinate: authority.breakpointResolutionCatalogCoordinate
            )
        )
        let blockedInput = try XCTUnwrap(store.debuggerWorkspaceInput(in: unloadable))
        XCTAssertEqual(blockedInput.imageSlot, unloadable)
        XCTAssertEqual(blockedInput.launchTarget, .importedWorkspaceBinary(blockedBinary))
        XCTAssertFalse(blockedInput.launchTarget.isLaunchable)
        XCTAssertNotNil(blockedInput.launchTarget.unavailableReason)
        XCTAssertEqual(blockedInput.gutterBreakpointAddresses, [])
        XCTAssertEqual(blockedInput.breakpointRevision, authority.breakpointRevision)
        XCTAssertNil(store.debuggerWorkspaceInput(in: ImageSlot(rawValue: 404)))

        var removed = store.snapshot
        removed.removeImage(in: sibling)
        store.snapshot = removed

        XCTAssertNil(store.debuggerWorkspaceInput(in: sibling))
    }

    func testCatalogRevisionAdvancesGloballyForEffectiveAddRemoveUndoAndRedo() throws {
        let store = makeStore()
        let initialPrimaryRevision = store.debuggerWorkspaceInput(in: .primary)?.breakpointRevision

        store.toggleBreakpoint(ImageAddress(slot: sibling, address: collision))
        XCTAssertEqual(store.debuggerWorkspaceInput(in: sibling)?.breakpointRevision, 2)
        XCTAssertEqual(
            store.debuggerWorkspaceInput(in: sibling)?.gutterBreakpointAddresses,
            [collision, siblingEarlier, siblingOnly]
        )
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.breakpointRevision, 2)

        store.toggleBreakpoint(ImageAddress(slot: sibling, address: missing))
        var sameSnapshot = store.snapshot
        let unchangedSiblingAnalysis = try XCTUnwrap(sameSnapshot.analysis(in: sibling))
        sameSnapshot.replaceAnalysis(unchangedSiblingAnalysis, in: sibling)
        store.snapshot = sameSnapshot

        XCTAssertEqual(store.debuggerWorkspaceInput(in: sibling)?.breakpointRevision, 2)

        store.focusImage(.primary)
        store.undoManager.undo()
        XCTAssertEqual(store.debuggerWorkspaceInput(in: sibling)?.breakpointRevision, 3)
        XCTAssertFalse(try breakpoint(in: sibling, at: collision, store: store))

        store.undoManager.redo()
        XCTAssertEqual(store.debuggerWorkspaceInput(in: sibling)?.breakpointRevision, 4)
        XCTAssertTrue(try breakpoint(in: sibling, at: collision, store: store))

        store.toggleBreakpoint(ImageAddress(slot: sibling, address: collision))
        XCTAssertEqual(store.debuggerWorkspaceInput(in: sibling)?.breakpointRevision, 5)
        XCTAssertFalse(try breakpoint(in: sibling, at: collision, store: store))
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.breakpointRevision, 5)
        XCTAssertEqual(initialPrimaryRevision, 1)
    }

    func testLegacyInstructionBitsAndMetadataDoNotAdvanceDurableCatalogRevision() throws {
        let store = makeStore()

        var changed = store.snapshot
        changed.mutateAnalysis(in: sibling) { analysis in
            analysis.instructions = analysis.instructions.map { row in
                guard row.address == collision else { return row }
                var copy = row
                copy.hasBreakpoint = true
                return copy
            }
        }
        store.snapshot = changed

        XCTAssertEqual(store.debuggerWorkspaceInput(in: sibling)?.breakpointRevision, 1)
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.breakpointRevision, 1)
        XCTAssertFalse(try breakpoint(in: sibling, at: collision, store: store))

        var metadataOnly = store.snapshot
        metadataOnly.mutateAnalysis(in: sibling) { analysis in
            analysis.instructions = analysis.instructions.map { row in
                guard row.address == collision else { return row }
                var copy = row
                copy.comment = "same breakpoint set"
                return copy
            }
        }
        store.snapshot = metadataOnly

        XCTAssertEqual(store.debuggerWorkspaceInput(in: sibling)?.breakpointRevision, 1)
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.breakpointRevision, 1)
    }

    func testSnapshotCompatibilityNormalizationTerminatesAndConvergesToCatalogAuthority() throws {
        let store = makeStore()
        let normalized = store.snapshot

        store.snapshot = normalized
        XCTAssertEqual(
            store.snapshot.logicalBreakpointCatalog,
            normalized.logicalBreakpointCatalog
        )
        XCTAssertEqual(
            store.snapshot.binaries.map(\.id),
            normalized.binaries.map(\.id)
        )
        XCTAssertEqual(
            store.snapshot.analysis(in: .primary)?.instructions,
            normalized.analysis(in: .primary)?.instructions
        )
        XCTAssertEqual(
            store.snapshot.analysis(in: sibling)?.instructions,
            normalized.analysis(in: sibling)?.instructions
        )

        var stale = normalized
        stale.mutateAnalysis(in: sibling) { analysis in
            analysis.instructions = analysis.instructions.map { row in
                guard row.address == collision else { return row }
                var copy = row
                copy.hasBreakpoint = true
                return copy
            }
        }
        store.snapshot = stale

        XCTAssertEqual(
            store.snapshot.logicalBreakpointCatalog,
            normalized.logicalBreakpointCatalog
        )
        XCTAssertEqual(
            store.snapshot.analysis(in: .primary)?.instructions,
            normalized.analysis(in: .primary)?.instructions
        )
        XCTAssertEqual(
            store.snapshot.analysis(in: sibling)?.instructions,
            normalized.analysis(in: sibling)?.instructions
        )
        XCTAssertFalse(try breakpoint(in: sibling, at: collision, store: store))
        XCTAssertEqual(
            store.debuggerWorkspaceInput(in: sibling)?.gutterBreakpointAddresses,
            [siblingEarlier, siblingOnly]
        )
    }

    func testSameSlotBinaryReplacementAdvancesDebuggerGenerationBeforeCandidateReuse() throws {
        let store = makeStore()
        let priorGeneration = store.debuggerBreakpointRevisionGeneration
        var replacement = store.snapshot
        let primaryIndex = try XCTUnwrap(
            replacement.binaries.firstIndex { $0.slot == .primary }
        )
        replacement.binaries[primaryIndex] = binary(
            name: "Replacement",
            path: "/bin/printf",
            slot: .primary
        )

        store.snapshot = replacement

        XCTAssertNotEqual(store.debuggerBreakpointRevisionGeneration, priorGeneration)
    }

    func testSynchronousCandidateOrderingCommitsLatestDirectCandidateWithoutDeferredSeam() async throws {
        let store = makeStore()
        let primaryInput = try workspaceInput(in: .primary, store: store)
        let siblingInput = try workspaceInput(in: sibling, store: store)
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.reconcileWorkspaceCandidate(primaryInput)
        XCTAssertEqual(viewModel.workspaceInput, primaryInput)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision])

        viewModel.reconcileWorkspaceCandidate(siblingInput)

        XCTAssertEqual(viewModel.workspaceInput, siblingInput)
        XCTAssertEqual(
            viewModel.session.breakpoints.map(\.address),
            siblingInput.gutterBreakpointAddresses
        )
        XCTAssertEqual(client.replaceBreakpointCalls, [])
        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.launchCalls.count, 1)
        XCTAssertEqual(client.launchCalls.first?.executablePath, siblingInput.launchTarget.executablePath)
        XCTAssertEqual(client.launchCalls.first?.initialBreakpoints, [])
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, sibling)
    }

    func testIdleDifferentTargetCandidateDoesNotReuseCollidingBreakpointMetadata() async throws {
        let store = makeStore()
        let viewModel = DebuggerPanelViewModel(client: FocusedIdentityDebuggerClient())
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        viewModel.breakpointEditAddressText = collision.hexAddress
        viewModel.breakpointConditionText = "x0 == 42"
        viewModel.breakpointIgnoreCountText = "3"
        await viewModel.applyBreakpointEdit()

        var siblingInput = try workspaceInput(in: sibling, store: store)
        siblingInput.gutterBreakpointAddresses = [collision]
        viewModel.reconcileWorkspaceCandidate(siblingInput)

        let rebound = try XCTUnwrap(viewModel.session.breakpoints.first)
        XCTAssertEqual(rebound.address, collision)
        XCTAssertTrue(rebound.isEnabled)
        XCTAssertNil(rebound.condition)
        XCTAssertEqual(rebound.hitCount, 0)
        XCTAssertEqual(rebound.ignoreCount, 0)
    }

    func testIdleSameTargetCandidatePreservesCollidingBreakpointMetadata() async throws {
        let store = makeStore()
        let viewModel = DebuggerPanelViewModel(client: FocusedIdentityDebuggerClient())
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        viewModel.breakpointEditAddressText = collision.hexAddress
        viewModel.breakpointConditionText = "x0 == 42"
        viewModel.breakpointIgnoreCountText = "3"
        await viewModel.applyBreakpointEdit()
        let updatedInput = try replacingInput(
            in: .primary,
            store: store,
            gutter: [collision, primaryOnly],
            revision: 2
        )

        viewModel.reconcileWorkspaceCandidate(updatedInput)

        let preserved = try XCTUnwrap(
            viewModel.session.breakpoints.first { $0.address == collision }
        )
        XCTAssertEqual(preserved.condition, "x0 == 42")
        XCTAssertEqual(preserved.ignoreCount, 3)
    }

    func testOlderSameSlotCandidateRevisionCannotReplaceNewerCandidate() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        let newer = try replacingInput(
            in: sibling,
            store: store,
            gutter: [collision, siblingOnly],
            revision: 2
        )
        let older = try replacingInput(
            in: sibling,
            store: store,
            gutter: [siblingOnly],
            revision: 1
        )

        viewModel.reconcileWorkspaceCandidate(newer)
        viewModel.reconcileWorkspaceCandidate(older)

        XCTAssertEqual(viewModel.workspaceInput, newer)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision, siblingOnly])
        await viewModel.launchSelectedTarget()
        XCTAssertEqual(client.launchCalls.count, 1)
        XCTAssertEqual(client.launchCalls.first?.initialBreakpoints, [])
    }

    func testSameRevisionSameOriginLaunchabilityRefreshReplacesFocusedCandidate() throws {
        let store = makeStore()
        let viewModel = DebuggerPanelViewModel(client: FocusedIdentityDebuggerClient())
        var blocked = try workspaceInput(in: .primary, store: store)
        blocked.launchTarget.unavailableReason = "Fixture target is temporarily unavailable."
        viewModel.reconcileWorkspaceCandidate(blocked)
        XCTAssertFalse(viewModel.canLaunchSelectedTarget)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: sibling, store: store))
        var refreshed = blocked
        refreshed.launchTarget.unavailableReason = nil

        viewModel.reconcileWorkspaceCandidate(refreshed)

        XCTAssertEqual(viewModel.workspaceInput, refreshed)
        XCTAssertEqual(viewModel.workspaceLaunchTarget, refreshed.launchTarget)
        XCTAssertTrue(viewModel.canLaunchSelectedTarget)
    }

    func testSameRevisionCandidateStillRejectsBreakpointAndOwnerDrift() throws {
        let store = makeStore()
        let original = try workspaceInput(in: .primary, store: store)

        let breakpointDriftViewModel = DebuggerPanelViewModel(
            client: FocusedIdentityDebuggerClient()
        )
        breakpointDriftViewModel.reconcileWorkspaceCandidate(original)
        var breakpointDrift = original
        breakpointDrift.gutterBreakpointAddresses.append(primaryOnly)
        breakpointDriftViewModel.reconcileWorkspaceCandidate(breakpointDrift)
        XCTAssertEqual(breakpointDriftViewModel.workspaceInput, original)

        let ownerDriftViewModel = DebuggerPanelViewModel(
            client: FocusedIdentityDebuggerClient()
        )
        ownerDriftViewModel.reconcileWorkspaceCandidate(original)
        var ownerDrift = original
        ownerDrift.launchTarget = .importedWorkspaceBinary(
            binary(name: "Replacement", path: "/bin/printf", slot: .primary)
        )
        ownerDriftViewModel.reconcileWorkspaceCandidate(ownerDrift)
        XCTAssertEqual(ownerDriftViewModel.workspaceInput, original)
    }

    func testActiveOwnerIsImmutableAndExplicitPrimaryUpdatesSurviveSiblingFocus() async throws {
        let store = makeStore()
        let primaryInput = try workspaceInput(in: .primary, store: store)
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)

        viewModel.reconcileWorkspaceCandidate(primaryInput)
        await viewModel.launchSelectedTarget()

        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision])

        store.focusImage(sibling)
        store.toggleBreakpoint(ImageAddress(slot: sibling, address: collision))
        let siblingCandidate = try workspaceInput(in: sibling, store: store)
        viewModel.reconcileWorkspaceCandidate(siblingCandidate)

        XCTAssertEqual(viewModel.workspaceInput, siblingCandidate)
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision])
        XCTAssertEqual(client.replaceBreakpointCalls, [])

        store.toggleBreakpoint(ImageAddress(slot: .primary, address: primaryOnly))
        await viewModel.reconcileActiveWorkspaceInput(
            try workspaceInput(in: .primary, store: store)
        )
        store.undoManager.undo()
        await viewModel.reconcileActiveWorkspaceInput(
            try workspaceInput(in: .primary, store: store)
        )
        store.undoManager.redo()
        await viewModel.reconcileActiveWorkspaceInput(
            try workspaceInput(in: .primary, store: store)
        )

        XCTAssertEqual(client.replaceBreakpointCalls, [])
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision, primaryOnly])
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertEqual(viewModel.workspaceInput, siblingCandidate)
    }

    func testRemovedActiveSlotReadAbstainsWithoutSubstitutingSiblingCandidate() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()

        store.focusImage(sibling)
        let siblingCandidate = try workspaceInput(in: sibling, store: store)
        viewModel.reconcileWorkspaceCandidate(siblingCandidate)
        var withoutActiveOwner = store.snapshot
        withoutActiveOwner.removeImage(in: .primary)
        store.snapshot = withoutActiveOwner

        XCTAssertNil(store.debuggerWorkspaceInput(in: .primary))
        await viewModel.reconcileActiveWorkspaceInput(store.debuggerWorkspaceInput(in: .primary))

        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertEqual(viewModel.workspaceInput, siblingCandidate)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision])
        XCTAssertEqual(client.replaceBreakpointCalls, [])
    }

    func testActiveRevisionsAcceptNewestAndRejectOlderOrReusedRevisionLocally() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()

        let older = try replacingInput(
            in: .primary,
            store: store,
            gutter: [primaryOnly],
            revision: 2
        )
        let newer = try replacingInput(
            in: .primary,
            store: store,
            gutter: [collision, primaryOnly],
            revision: 3
        )
        await viewModel.reconcileActiveWorkspaceInput(older)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [primaryOnly])

        await viewModel.reconcileActiveWorkspaceInput(newer)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision, primaryOnly])
        XCTAssertEqual(client.replaceBreakpointCalls, [])

        await viewModel.reconcileActiveWorkspaceInput(older)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision, primaryOnly])

        var reusedRevision = newer
        reusedRevision.gutterBreakpointAddresses = [collision]
        await viewModel.reconcileActiveWorkspaceInput(reusedRevision)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision, primaryOnly])
        XCTAssertEqual(client.replaceBreakpointCalls, [])
        XCTAssertNotNil(viewModel.lastError)
    }

    func testNewestActiveRevisionCanReturnToLocalBaselineWithoutBackendCall() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()

        let older = try replacingInput(
            in: .primary,
            store: store,
            gutter: [primaryOnly],
            revision: 2
        )
        let newest = try replacingInput(
            in: .primary,
            store: store,
            gutter: [collision],
            revision: 3
        )
        await viewModel.reconcileActiveWorkspaceInput(older)
        await viewModel.reconcileActiveWorkspaceInput(newest)

        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision])
        XCTAssertEqual(client.replaceBreakpointCalls, [])
    }

    func testOlderActiveRevisionCannotSupersedeAcceptedNewerRevision() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()

        let older = try replacingInput(
            in: .primary,
            store: store,
            gutter: [primaryOnly],
            revision: 2
        )
        let newer = try replacingInput(
            in: .primary,
            store: store,
            gutter: [collision, primaryOnly],
            revision: 3
        )
        await viewModel.reconcileActiveWorkspaceInput(newer)
        await viewModel.reconcileActiveWorkspaceInput(older)

        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision, primaryOnly])
        XCTAssertEqual(client.replaceBreakpointCalls, [])
    }

    func testActiveRevisionChangesLocalStateWithoutBackendFailureSurface() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()
        let update = try replacingInput(
            in: .primary,
            store: store,
            gutter: [primaryOnly],
            revision: 2
        )

        await viewModel.reconcileActiveWorkspaceInput(update)

        XCTAssertEqual(client.replaceBreakpointCalls, [])
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [primaryOnly])
        XCTAssertEqual(
            viewModel.session.processState,
            .paused(processID: 71, reason: .breakpoint(address: collision))
        )
        XCTAssertEqual(
            viewModel.session.backendState,
            .connected(processID: 71, adapterName: "Focused Identity LLDB")
        )
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertNil(viewModel.lastError)

        await viewModel.reconcileActiveWorkspaceInput(update)

        XCTAssertEqual(client.replaceBreakpointCalls, [])
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [primaryOnly])
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertNil(viewModel.lastError)
    }

    func testRevisionGenerationRolloverAcceptsFreshLocalRevisionWithoutBackendCall() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()

        let preRollover = try replacingInput(
            in: .primary,
            store: store,
            gutter: [primaryOnly],
            revision: UInt64.max
        )
        let postRollover = try replacingInput(
            in: .primary,
            store: store,
            gutter: [collision],
            revision: 1
        )
        await viewModel.reconcileActiveWorkspaceInput(preRollover)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [primaryOnly])
        viewModel.invalidateWorkspaceReconciliationEpochs()
        await viewModel.reconcileActiveWorkspaceInput(postRollover)

        XCTAssertEqual(client.replaceBreakpointCalls, [])
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision])
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
    }

    func testLaunchPublishesNoStaticBackendBreakpointsAndRestoresLocalOwnerState() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()

        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision])
        XCTAssertEqual(client.launchCalls.first?.initialBreakpoints, [])
        XCTAssertEqual(client.replaceBreakpointCalls, [])
        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
    }

    func testSameOwnerRevisionAfterLaunchUpdatesBreakpointsLocallyWithoutBackendBinding() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()
        let latest = try replacingInput(
            in: .primary,
            store: store,
            gutter: [collision, primaryOnly],
            revision: 2
        )

        await viewModel.reconcileActiveWorkspaceInput(latest)

        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision, primaryOnly])
        XCTAssertEqual(client.launchCalls.first?.initialBreakpoints, [])
        XCTAssertEqual(client.replaceBreakpointCalls, [])
    }

    func testLegacyProgramCountersAndUnmappedRunToCursorAbstain() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()

        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
        XCTAssertNil(viewModel.selectedFrameWorkspaceProgramCounter)

        await viewModel.selectFrame(1)
        XCTAssertNil(viewModel.selectedFrameWorkspaceProgramCounter)

        store.focusImage(sibling)
        store.updateLiveProgramCounterTarget(viewModel.currentWorkspaceProgramCounter)
        XCTAssertNil(store.liveProgramCounterTarget)
        XCTAssertNil(store.liveProgramCounter)

        await viewModel.runToCursor(to: ImageAddress(slot: sibling, address: collision))
        XCTAssertEqual(client.runToCursorCalls, [])
        XCTAssertNotNil(viewModel.lastError)

        await viewModel.runToCursor(to: ImageAddress(slot: .primary, address: primaryOnly))
        XCTAssertEqual(client.runToCursorCalls, [])
        XCTAssertNotNil(viewModel.lastError)
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
    }

    func testSameSlotBinaryReplacementMakesActiveProgramCountersAndRunToCursorAbstain() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()

        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
        XCTAssertNil(viewModel.selectedFrameWorkspaceProgramCounter)

        let replacementBinary = binary(
            name: "Replacement",
            path: "/bin/printf",
            slot: .primary
        )
        let replacementInput = completeDebuggerWorkspaceInputFixture(
            imageSlot: .primary,
            launchTarget: .importedWorkspaceBinary(replacementBinary),
            gutterBreakpointAddresses: [collision]
        )
        viewModel.invalidateWorkspaceReconciliationEpochs()
        viewModel.reconcileWorkspaceCandidate(replacementInput)

        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
        XCTAssertNil(viewModel.selectedFrameWorkspaceProgramCounter)
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)

        await viewModel.runToCursor(to: ImageAddress(slot: .primary, address: collision))

        XCTAssertEqual(client.runToCursorCalls, [])
        XCTAssertNotNil(viewModel.lastError)
    }

    func testClearingIdleWorkspaceCandidateDropsItsStaleTargetAndGutterBreakpoints() throws {
        let store = makeStore()
        let input = try workspaceInput(in: .primary, store: store)
        let viewModel = DebuggerPanelViewModel(client: FocusedIdentityDebuggerClient())
        viewModel.reconcileWorkspaceCandidate(input)

        XCTAssertEqual(viewModel.importedExecutablePath, input.launchTarget.executablePath)
        XCTAssertEqual(viewModel.session.breakpoints.map(\.address), [collision])

        viewModel.reconcileWorkspaceCandidate(nil)

        XCTAssertNil(viewModel.workspaceInput)
        XCTAssertNil(viewModel.workspaceLaunchTarget)
        XCTAssertEqual(viewModel.importedExecutablePath, "")
        XCTAssertTrue(viewModel.session.breakpoints.isEmpty)
        XCTAssertFalse(viewModel.canLaunchSelectedTarget)
    }

    func testClearingCandidateWhileLiveClearsOnlyNextLaunchAndPreservesActiveSession() async throws {
        let store = makeStore()
        let input = try workspaceInput(in: .primary, store: store)
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(input)
        await viewModel.launchSelectedTarget()
        let activeBreakpoints = viewModel.session.breakpoints

        viewModel.reconcileWorkspaceCandidate(nil)

        XCTAssertNil(viewModel.workspaceInput)
        XCTAssertNil(viewModel.workspaceLaunchTarget)
        XCTAssertEqual(viewModel.importedExecutablePath, "")
        XCTAssertEqual(viewModel.session.breakpoints, activeBreakpoints)
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, .primary)
        XCTAssertTrue(viewModel.session.hasLiveProcessSession)
        XCTAssertNil(viewModel.currentWorkspaceProgramCounter)
    }

    func testFailedWorkspaceLaunchClearsOwnerAndMakesLatestCandidateLaunchable() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        client.launchError = DebuggerClientError.backendFailure("fixture launch failed")
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))

        await viewModel.launchSelectedTarget()

        XCTAssertNil(viewModel.activeWorkspaceImageSlot)
        XCTAssertEqual(client.launchCalls.count, 1)
        XCTAssertNotNil(viewModel.lastError)

        client.launchError = nil
        let siblingInput = try workspaceInput(in: sibling, store: store)
        viewModel.reconcileWorkspaceCandidate(siblingInput)
        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.launchCalls.count, 2)
        XCTAssertEqual(viewModel.activeWorkspaceImageSlot, sibling)
    }

    func testProcessExitClearsOwnerAndPreservesNextCandidate() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()
        let siblingInput = try workspaceInput(in: sibling, store: store)
        viewModel.reconcileWorkspaceCandidate(siblingInput)
        client.continueResult = .exited

        await viewModel.continueExecution()

        XCTAssertEqual(client.continueCallCount, 1)
        XCTAssertNil(viewModel.activeWorkspaceImageSlot)
        XCTAssertEqual(viewModel.workspaceInput, siblingInput)
        XCTAssertEqual(
            viewModel.session.breakpoints.map(\.address),
            siblingInput.gutterBreakpointAddresses
        )

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.launchCalls.last?.executablePath, siblingInput.launchTarget.executablePath)
        XCTAssertEqual(client.launchCalls.last?.initialBreakpoints, [])
    }

    func testDetachedRefreshClearsOwnerAndPreservesNextCandidate() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()
        let siblingInput = try workspaceInput(in: sibling, store: store)
        viewModel.reconcileWorkspaceCandidate(siblingInput)
        client.refreshResult = .detached

        await viewModel.refreshSnapshot()

        XCTAssertEqual(client.refreshCallCount, 1)
        XCTAssertNil(viewModel.activeWorkspaceImageSlot)
        XCTAssertEqual(viewModel.workspaceInput, siblingInput)
        XCTAssertEqual(
            viewModel.session.breakpoints.map(\.address),
            siblingInput.gutterBreakpointAddresses
        )

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.launchCalls.last?.executablePath, siblingInput.launchTarget.executablePath)
        XCTAssertEqual(client.launchCalls.last?.initialBreakpoints, [])
    }

    func testTerminationClearsOwnerAndPreservesNextCandidate() async throws {
        let store = makeStore()
        let client = FocusedIdentityDebuggerClient()
        let viewModel = DebuggerPanelViewModel(client: client)
        viewModel.reconcileWorkspaceCandidate(try workspaceInput(in: .primary, store: store))
        await viewModel.launchSelectedTarget()
        let siblingInput = try workspaceInput(in: sibling, store: store)
        viewModel.reconcileWorkspaceCandidate(siblingInput)

        await viewModel.terminate()

        XCTAssertEqual(client.terminateCallCount, 1)
        XCTAssertNil(viewModel.activeWorkspaceImageSlot)
        XCTAssertEqual(viewModel.workspaceInput, siblingInput)
        XCTAssertEqual(
            viewModel.session.breakpoints.map(\.address),
            siblingInput.gutterBreakpointAddresses
        )

        await viewModel.launchSelectedTarget()

        XCTAssertEqual(client.launchCalls.last?.executablePath, siblingInput.launchTarget.executablePath)
        XCTAssertEqual(client.launchCalls.last?.initialBreakpoints, [])
    }

    private func makeStore() -> WorkspaceStore {
        var primaryAnalysis = ImageAnalysis()
        primaryAnalysis.instructions = [
            instruction(at: collision, hasBreakpoint: true),
            instruction(at: primaryOnly, hasBreakpoint: false),
        ]

        var siblingAnalysis = ImageAnalysis()
        siblingAnalysis.instructions = [
            instruction(at: siblingOnly, hasBreakpoint: true),
            instruction(at: collision, hasBreakpoint: false),
            instruction(at: siblingEarlier, hasBreakpoint: true),
        ]

        let snapshot = WorkspaceSnapshot(
            binaries: [
                binary(name: "Primary", path: "/bin/echo", slot: .primary),
                binary(name: "Sibling", path: "/bin/date", slot: sibling),
                binary(name: "NoAnalysis", path: "/bin/ls", slot: noAnalysis),
                binary(
                    name: "Unloadable",
                    path: "/definitely/missing/MacScope-unloadable-fixture",
                    slot: unloadable
                ),
            ],
            analysisBySlot: [
                .primary: primaryAnalysis,
                sibling: siblingAnalysis,
            ]
        )
        return WorkspaceStore(
            workspaceName: "Focused debugger identity",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    private func binary(name: String, path: String, slot: ImageSlot) -> BinaryImage {
        BinaryImage(
            id: UUID(),
            name: name,
            path: path,
            kind: "Mach-O executable",
            architecture: "arm64",
            slot: slot
        )
    }

    private func instruction(at address: UInt64, hasBreakpoint: Bool) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "1f 20 03 d5",
            mnemonic: "nop",
            operands: "",
            hasBreakpoint: hasBreakpoint,
            comment: nil
        )
    }

    private func workspaceInput(
        in slot: ImageSlot,
        store: WorkspaceStore
    ) throws -> DebuggerWorkspaceInput {
        try XCTUnwrap(store.debuggerWorkspaceInput(in: slot))
    }

    private func replacingInput(
        in slot: ImageSlot,
        store: WorkspaceStore,
        gutter: [UInt64],
        revision: UInt64
    ) throws -> DebuggerWorkspaceInput {
        var input = try workspaceInput(in: slot, store: store)
        input.gutterBreakpointAddresses = gutter.sorted()
        input.breakpointRevision = revision
        return input
    }

    private func breakpoint(
        in slot: ImageSlot,
        at address: UInt64,
        store: WorkspaceStore
    ) throws -> Bool {
        try XCTUnwrap(
            store.snapshot.analysis(in: slot)?.instructions.first { $0.address == address }
        ).hasBreakpoint
    }
}

@MainActor
private final class FocusedIdentityDebuggerClient: DebuggerClient {
    enum NonLiveResult {
        case exited
        case detached
    }

    let capabilities = DebuggerCapabilityReport(
        backendName: "Focused Identity LLDB",
        isBackendAvailable: true,
        canLaunch: true,
        canAttach: false,
        canControlExecution: true,
        limitations: [],
        entitlementNotes: []
    )

    private let suspendedReplacementCall: Int?
    private let replacementStarted: XCTestExpectation?
    private var suspendedReplacementContinuation: CheckedContinuation<Void, Never>?
    private let suspendLaunch: Bool
    private let launchStarted: XCTestExpectation?
    private var suspendedLaunchContinuation: CheckedContinuation<Void, Never>?
    var launchError: Error?
    var continueResult: NonLiveResult?
    var refreshResult: NonLiveResult?
    var replacementErrors: [Int: Error] = [:]
    private(set) var launchCalls: [DebuggerLaunchConfiguration] = []
    private(set) var replaceBreakpointCalls: [[UInt64]] = []
    private(set) var backendBreakpointAddresses: [UInt64] = []
    private(set) var runToCursorCalls: [UInt64] = []
    private(set) var continueCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var terminateCallCount = 0
    private(set) var selectFrameCalls: [Int] = []

    init(
        suspendedReplacementCall: Int? = nil,
        replacementStarted: XCTestExpectation? = nil,
        suspendLaunch: Bool = false,
        launchStarted: XCTestExpectation? = nil
    ) {
        self.suspendedReplacementCall = suspendedReplacementCall
        self.replacementStarted = replacementStarted
        self.suspendLaunch = suspendLaunch
        self.launchStarted = launchStarted
    }

    func makeInitialSnapshot() -> DebuggerSessionSnapshot {
        return DebuggerSessionSnapshot(
            processState: .notAttached,
            breakpoints: [],
            frames: [],
            registers: [],
            memoryRegions: [],
            statusMessage: "Ready.",
            backendState: .ready(adapterName: "Focused Identity LLDB")
        )
    }

    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot {
        launchCalls.append(configuration)
        launchStarted?.fulfill()
        if suspendLaunch {
            await withCheckedContinuation { continuation in
                suspendedLaunchContinuation = continuation
            }
        }
        if let launchError {
            throw launchError
        }
        backendBreakpointAddresses = configuration.initialBreakpoints.map(\.address)
        return DebuggerSessionSnapshot(
            processState: .paused(processID: 71, reason: .breakpoint(address: 0x1_0000_0000)),
            breakpoints: configuration.initialBreakpoints,
            frames: [
                DebuggerFrameSummary(
                    index: 0,
                    address: 0x1_0000_0000,
                    functionName: "_main",
                    moduleName: "Fixture",
                    sourceLocation: nil
                ),
                DebuggerFrameSummary(
                    index: 1,
                    address: 0x1_0000_0010,
                    functionName: "_caller",
                    moduleName: "Fixture",
                    sourceLocation: nil
                ),
            ],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 71, adapterName: "Focused Identity LLDB")
        )
    }

    func continueExecution(
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        continueCallCount += 1
        return continueResult.map { nonLiveSnapshot($0, from: snapshot) } ?? snapshot
    }

    func runToCursor(
        _ request: DebuggerRunToCursorRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        runToCursorCalls.append(request.resolvedAddress.runtimeAddress)
        return snapshot
    }

    func stepOver(
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot { snapshot }

    func pause(
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot { snapshot }

    func terminate(
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        terminateCallCount += 1
        return nonLiveSnapshot(.exited, from: snapshot)
    }

    func replaceBreakpoints(
        _ breakpoints: [DebuggerBreakpoint],
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        replaceBreakpointCalls.append(breakpoints.map(\.address))
        if let suspendedReplacementCall,
           replaceBreakpointCalls.count == suspendedReplacementCall {
            replacementStarted?.fulfill()
            await withCheckedContinuation { continuation in
                suspendedReplacementContinuation = continuation
            }
        }
        if let error = replacementErrors[replaceBreakpointCalls.count] {
            throw error
        }
        backendBreakpointAddresses = breakpoints.map(\.address)
        var copy = snapshot
        copy.replaceBreakpoints(breakpoints)
        return copy
    }

    func refreshSnapshot(
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        refreshCallCount += 1
        return refreshResult.map { nonLiveSnapshot($0, from: snapshot) } ?? snapshot
    }

    func selectFrame(
        _ request: DebuggerFrameSelectionRequest,
        from snapshot: DebuggerSessionSnapshot
    ) async throws -> DebuggerSessionSnapshot {
        selectFrameCalls.append(request.index)
        return snapshot
    }

    func resumeSuspendedReplacement() {
        suspendedReplacementContinuation?.resume()
        suspendedReplacementContinuation = nil
    }

    func resumeSuspendedLaunch() {
        suspendedLaunchContinuation?.resume()
        suspendedLaunchContinuation = nil
    }

    private func nonLiveSnapshot(
        _ result: NonLiveResult,
        from snapshot: DebuggerSessionSnapshot
    ) -> DebuggerSessionSnapshot {
        var copy = snapshot
        switch result {
        case .exited:
            copy.processState = .exited(code: 0)
            copy.statusMessage = "Exited."
        case .detached:
            copy.processState = .notAttached
            copy.statusMessage = "Detached."
        }
        copy.frames = []
        copy.backendState = .ready(adapterName: "Focused Identity LLDB")
        return copy
    }
}

/// Test-only construction seam: unlike the production store, isolated debugger tests do not own a
/// workspace document. They must still provide a complete, internally consistent authority bundle.
func completeDebuggerWorkspaceInputFixture(
    imageSlot: ImageSlot,
    launchTarget: DebuggerLaunchTargetDescriptor,
    gutterBreakpointAddresses: [UInt64]
) -> DebuggerWorkspaceInput {
    let workspaceID = UUID(uuidString: "71000000-0000-0000-0000-000000000071")!
    let catalogID = UUID(uuidString: "72000000-0000-0000-0000-000000000072")!
    let binaryID: UUID
    switch launchTarget.origin {
    case .importedWorkspaceBinary(let value, _):
        binaryID = value
    }
    let specifications = try! gutterBreakpointAddresses.enumerated().map { index, address in
        try DebuggerLogicalBreakpointSpecification(
            id: DebuggerLogicalBreakpointID(
                rawValue: UUID(uuidString: String(
                    format: "73000000-0000-0000-0000-%012llx",
                    UInt64(index + 1)
                ))!
            ),
            revision: DebuggerLogicalBreakpointRevision(validating: 1),
            enabled: true,
            target: .preferredAddress(
                owner: DebuggerWorkspaceImageOwnerSeal(
                    slot: imageSlot,
                    binaryID: binaryID,
                    artifactIdentity: nil
                ),
                preferredVA: address
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
    }
    let logicalCatalog = try! DebuggerLogicalBreakpointCatalog(
        catalogID: catalogID,
        revision: 1,
        specifications: specifications
    )
    let logicalCoordinate = try! DebuggerLogicalBreakpointCatalogCoordinate(
        workspaceID: workspaceID,
        catalogID: catalogID,
        revision: logicalCatalog.revision
    )
    let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
        workspaceID: workspaceID,
        revision: .init(rawValue: 1),
        workspaceArtifactCatalogRevision: .init(rawValue: 1)
    )
    let resolutionCatalog = DebuggerBreakpointResolutionCatalog(
        coordinate: resolutionCoordinate,
        owners: []
    )
    return DebuggerWorkspaceInput(
        imageSlot: imageSlot,
        launchTarget: launchTarget,
        gutterBreakpointAddresses: gutterBreakpointAddresses,
        breakpointRevision: logicalCatalog.revision,
        logicalBreakpointCatalogAvailability: .available,
        logicalBreakpointCatalog: logicalCatalog,
        logicalBreakpointCatalogCoordinate: logicalCoordinate,
        breakpointResolutionCatalog: resolutionCatalog,
        breakpointResolutionCatalogCoordinate: resolutionCoordinate
    )
}
