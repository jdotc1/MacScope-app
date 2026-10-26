import Foundation
import XCTest

@testable import MacScope

@MainActor
final class WorkspaceStoreReconstructionNavigationTests: XCTestCase {
    func testExactCurrentFunctionRevealsProjectSource() throws {
        let fixture = try makeNavigationFixture()
        defer { fixture.remove() }
        fixture.store.selectedTool = .reconstruction
        fixture.store.selectedSidebarItemID = WorkspaceStore.reconstructionSidebarItemID(UUID())

        let target = try fixture.store.revealReconstructionSource(fixture.request)

        XCTAssertEqual(target.imageSlot, fixture.function.image.imageSlot)
        XCTAssertEqual(target.binaryID, fixture.function.image.binaryID)
        XCTAssertEqual(
            target.functionID,
            ReconstructionReboundFunctionAuthority.expectedFunctionID(for: fixture.function)
        )
        XCTAssertEqual(fixture.store.selectedTool, .project)
        XCTAssertEqual(fixture.store.focusedImageSlot, fixture.function.image.imageSlot)
        XCTAssertEqual(fixture.store.selectedAddress, fixture.function.startAddress)
        XCTAssertEqual(
            fixture.store.selectedSidebarItemID,
            "function:\(target.functionID.uuidString)"
        )
        XCTAssertEqual(
            fixture.store.sidebarKeyboardFocusRequestID,
            "function:\(target.functionID.uuidString)",
            "programmatic source reveal must request focus for the exact selected function row"
        )
        fixture.store.acknowledgeSidebarKeyboardFocusRequest(for: "function:\(target.functionID.uuidString)")
        XCTAssertNil(
            fixture.store.sidebarKeyboardFocusRequestID,
            "only the exact row may consume the one-shot keyboard focus transfer"
        )
    }

    func testCrossWorkspaceRequestFailsWithoutMutatingNavigation() throws {
        let fixture = try makeNavigationFixture()
        defer { fixture.remove() }
        fixture.store.selectedTool = .reconstruction
        let sidebarID = WorkspaceStore.reconstructionSidebarItemID(UUID())
        fixture.store.selectedSidebarItemID = sidebarID
        let initialAddress = fixture.store.selectedAddress
        let request = ReconstructionSourceNavigationRequest(
            workspaceID: UUID(),
            projectID: fixture.request.projectID,
            function: fixture.function
        )

        XCTAssertThrowsError(try fixture.store.revealReconstructionSource(request)) { error in
            XCTAssertEqual(error as? ReconstructionSourceNavigationError, .workspaceMismatch)
        }
        XCTAssertEqual(fixture.store.selectedTool, .reconstruction)
        XCTAssertEqual(fixture.store.selectedSidebarItemID, sidebarID)
        XCTAssertEqual(fixture.store.selectedAddress, initialAddress)
    }

    func testHistoricalArtifactAndStaleFunctionAuthorityFailClosed() throws {
        let fixture = try makeNavigationFixture()
        defer { fixture.remove() }
        fixture.store.selectedTool = .reconstruction
        let sidebarID = WorkspaceStore.reconstructionSidebarItemID(UUID())
        fixture.store.selectedSidebarItemID = sidebarID
        let initialImageSlot = fixture.store.focusedImageSlot
        let initialAddress = fixture.store.selectedAddress

        let foreignArtifact = ReconstructionArtifactCoordinate(
            occurrenceID: .init(rawValue: UUID()),
            contentIdentity: fixture.function.artifact.contentIdentity
        )
        let historicalFunction = try replacing(
            fixture.function,
            artifact: foreignArtifact,
            fingerprint: fixture.function.analysisFingerprintSHA256
        )
        XCTAssertThrowsError(try fixture.store.revealReconstructionSource(.init(
            workspaceID: fixture.request.workspaceID,
            projectID: fixture.request.projectID,
            function: historicalFunction
        ))) { error in
            XCTAssertEqual(
                error as? ReconstructionSourceNavigationError,
                .artifactOutsideCurrentManifest
            )
        }
        XCTAssertEqual(fixture.store.selectedTool, .reconstruction)
        XCTAssertEqual(fixture.store.selectedSidebarItemID, sidebarID)
        XCTAssertEqual(fixture.store.focusedImageSlot, initialImageSlot)
        XCTAssertEqual(fixture.store.selectedAddress, initialAddress)

        let staleFunction = try replacing(
            fixture.function,
            artifact: fixture.function.artifact,
            fingerprint: String(repeating: "f", count: 64)
        )
        XCTAssertThrowsError(try fixture.store.revealReconstructionSource(.init(
            workspaceID: fixture.request.workspaceID,
            projectID: fixture.request.projectID,
            function: staleFunction
        ))) { error in
            XCTAssertEqual(
                error as? ReconstructionSourceNavigationError,
                .functionAuthorityMismatch
            )
        }
        XCTAssertEqual(fixture.store.selectedTool, .reconstruction)
        XCTAssertEqual(fixture.store.selectedSidebarItemID, sidebarID)
        XCTAssertEqual(fixture.store.focusedImageSlot, initialImageSlot)
        XCTAssertEqual(fixture.store.selectedAddress, initialAddress)

        // Mutation RED: move any navigation mutation ahead of authority resolution. At least one
        // exact before/after equality fails for both historical and stale TOCTOU refusals.
    }

    func testOnceCurrentRevealRefusesAfterLiveFunctionAuthorityRetiresBeforeDispatch() throws {
        let seed = try Task10InstalledScenarioSeedPackage.make(.navigationCurrent)
        defer { seed.remove() }
        let store = try WorkspaceStore.restoredPackage(from: seed.packageURL)
        store.selectedTool = .reconstruction
        let sidebarID = WorkspaceStore.reconstructionSidebarItemID(UUID())
        store.selectedSidebarItemID = sidebarID

        let state = store.reconstructionState
        let evidence = try XCTUnwrap(state.evidence.first(where: {
            $0.evidenceID == Task10InstalledScenarioSeedPackage.navigableEvidenceID
        }))
        let selectedJobID = try XCTUnwrap(state.jobs.first?.jobID)
        let projectID = try XCTUnwrap(state.jobs.first?.reconstructionProjectID)
        var liveSnapshot = store.snapshot

        let requestAtRender = WorkspaceRootView.reconstructionSourceNavigationRequest(
            evidence: evidence,
            selectedJobID: selectedJobID,
            projectID: projectID,
            workspaceID: store.workspaceID,
            workspace: state,
            snapshot: liveSnapshot
        )
        XCTAssertNotNil(requestAtRender, "The rendered action must begin with current authority.")

        // Retire the exact function authority after the control was rendered but before dispatch.
        liveSnapshot.mutateAnalysis(in: evidence.functionImageSlot) { analysis in
            analysis.functions = []
        }
        XCTAssertNil(WorkspaceRootView.reconstructionSourceNavigationRequest(
            evidence: evidence,
            selectedJobID: selectedJobID,
            projectID: projectID,
            workspaceID: store.workspaceID,
            workspace: state,
            snapshot: liveSnapshot
        ))

        let navigationBefore = NavigationObservation(store: store)
        let durableStateBefore = store.reconstructionState
        let packageBytesBefore = try ordinaryFileBytes(in: seed.packageURL)
        var revealInvocationCount = 0

        let notice = WorkspaceRootView.dispatchReconstructionSourceReveal(
            currentRequest: {
                WorkspaceRootView.reconstructionSourceNavigationRequest(
                    evidence: evidence,
                    selectedJobID: selectedJobID,
                    projectID: projectID,
                    workspaceID: store.workspaceID,
                    workspace: store.reconstructionState,
                    snapshot: liveSnapshot
                )
            },
            reveal: { request in
                revealInvocationCount += 1
                try store.revealReconstructionSource(request)
            }
        )

        XCTAssertEqual(revealInvocationCount, 0)
        XCTAssertEqual(
            notice,
            ReconstructionDashboardTransientNotice(
                title: "Source reveal refused",
                detail: "Workspace, corpus, image, analysis, or function authority changed. "
                    + "No source navigation was performed.",
                tone: .warning
            )
        )
        XCTAssertEqual(NavigationObservation(store: store), navigationBefore)
        XCTAssertEqual(store.reconstructionState, durableStateBefore)
        XCTAssertEqual(try ordinaryFileBytes(in: seed.packageURL), packageBytesBefore)

        // Mutation RED: return nil from the dispatcher's missing-request branch. The exact notice
        // assertion fails while the zero-invocation and immutable-state checks remain independent.
    }

    func testInstalledQualificationRetirementRestoresBeforeDirtySaveAutosaveAndReopen() throws {
        let seed = try Task10InstalledScenarioSeedPackage.make(.navigationCurrent)
        defer { seed.remove() }
        let store = try WorkspaceStore.restoredPackage(from: seed.packageURL)
        let autosave = ManualAutosaveTrigger()
        autosave.onFire = { [weak store] in
            store?.performAutosaveIfNeeded()
        }
        store.autosaveScheduler = autosave
        let request = try currentNavigationRequest(in: store)
        let functionID = try XCTUnwrap(
            ReconstructionReboundFunctionAuthority.expectedFunctionID(for: request.function)
        )

        // The schema-3 qualification fixture deliberately persists focus on the starting image,
        // while the current reconstruction source belongs to the second image. Bare authoring
        // edits are focus-scoped, so select the request's authoritative image before proving that
        // retirement restoration preserves those edits across Save, autosave, and reopen.
        store.focusImage(request.function.image.imageSlot)
        XCTAssertEqual(store.focusedImageSlot, request.function.image.imageSlot)

        // Establish an ordinary dirty authoring edit before the qualification-only mutation. The
        // scoped snapshot replacement must not lose this edit or leak its retired analysis into
        // either explicit Save or the pending autosave.
        store.setCustomName(request.function.startAddress, name: "retirement-save-canary")
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(autosave.isPending)
        XCTAssertTrue(store.retireReconstructionSourceAuthorityForInstalledQualification(request))
        XCTAssertTrue(
            store.snapshot.analysis(in: request.function.image.imageSlot)?.functions.contains {
                $0.id == functionID
            } == true,
            "temporary retirement must be restored before any persistence boundary"
        )

        XCTAssertTrue(store.writeDocumentPackage(to: seed.packageURL))
        let afterExplicitSave = try WorkspaceStore.restoredPackage(from: seed.packageURL)
        try assertFunctionAuthority(functionID, request: request, survivesIn: afterExplicitSave)
        XCTAssertEqual(
            afterExplicitSave.snapshot.addressOverrides[
                ImageAddress(slot: request.function.image.imageSlot, address: request.function.startAddress)
            ]?.customName,
            "retirement-save-canary"
        )

        // Save As restores the package's persisted starting-image focus. Select the evidence
        // owner again so the second focus-scoped edit tests autosave of the intended image.
        store.focusImage(request.function.image.imageSlot)
        XCTAssertEqual(store.focusedImageSlot, request.function.image.imageSlot)
        store.setCustomComment(request.function.startAddress, comment: "retirement-autosave-canary")
        XCTAssertEqual(
            store.snapshot.addressOverrides[
                ImageAddress(slot: request.function.image.imageSlot, address: request.function.startAddress)
            ]?.customComment,
            "retirement-autosave-canary"
        )
        XCTAssertTrue(store.isDirty)
        XCTAssertTrue(autosave.firePending(), "the dirty autosave must fire deterministically")
        XCTAssertNil(store.saveError)
        XCTAssertFalse(store.isDirty)
        let afterAutosave = try WorkspaceStore.restoredPackage(from: seed.packageURL)
        try assertFunctionAuthority(functionID, request: request, survivesIn: afterAutosave)
        XCTAssertEqual(
            afterAutosave.snapshot.addressOverrides[
                ImageAddress(slot: request.function.image.imageSlot, address: request.function.startAddress)
            ]?.customComment,
            "retirement-autosave-canary"
        )

        // Mutation RED: remove `defer { snapshot = priorSnapshot }` from the Store helper. The
        // exact function-authority equality after the synthetic retirement fails before Save or
        // autosave can silently serialize a retired snapshot.
    }
}

private struct NavigationObservation: Equatable {
    let selectedTool: WorkspaceTool
    let selectedSidebarItemID: SidebarItem.ID?
    let focusedImageSlot: ImageSlot
    let selectedAddress: UInt64?

    @MainActor
    init(store: WorkspaceStore) {
        selectedTool = store.selectedTool
        selectedSidebarItemID = store.selectedSidebarItemID
        focusedImageSlot = store.focusedImageSlot
        selectedAddress = store.selectedAddress
    }
}

private struct ReconstructionNavigationFixture {
    let headless: ReconstructionHeadlessTestFixture
    let store: WorkspaceStore
    let request: ReconstructionSourceNavigationRequest
    let function: ReconstructionFunctionCoordinate

    func remove() { headless.remove() }
}

@MainActor
private func makeNavigationFixture() throws -> ReconstructionNavigationFixture {
    let headless = try ReconstructionHeadlessTestFixture.make()
    let fingerprint = try XCTUnwrap(
        headless.workspace.analysis(in: headless.image.imageSlot)?.analysisInputFingerprint
    ).overallSHA256
    let function = try ReconstructionFunctionCoordinate(
        artifact: headless.artifact,
        image: headless.image,
        analysisFingerprintSHA256: fingerprint,
        startAddress: 0x1000,
        endAddressExclusive: 0x1008,
        boundarySchemaVersion: ReconstructionFunctionCoordinate.schemaVersion,
        functionUUIDHint: nil,
        symbolHint: "entry"
    )
    let stableFunctionID = try XCTUnwrap(
        ReconstructionReboundFunctionAuthority.expectedFunctionID(for: function)
    )
    var snapshot = headless.workspace
    snapshot.mutateAnalysis(in: headless.image.imageSlot) { analysis in
        analysis.functions = [FunctionSummary(
            id: stableFunctionID,
            name: "entry",
            startAddress: function.startAddress,
            endAddress: function.endAddressExclusive,
            confidence: 1
        )]
        analysis.instructions = [InstructionRow(
            address: function.startAddress,
            bytes: "c0 03 5f d6",
            mnemonic: "ret",
            operands: "",
            hasBreakpoint: false,
            comment: nil
        )]
    }

    let projectID = UUID()
    let occurrence = try ReconstructionArtifactOccurrenceRecord(
        occurrenceID: headless.artifact.occurrenceID,
        contentIdentity: headless.artifact.contentIdentity,
        kind: .machOImage,
        roles: [.primaryTarget],
        executableMode: true,
        originalName: "fixture",
        diagnostic: nil
    )
    let draft = try ReconstructionCorpusManifest(
        reconstructionProjectID: projectID,
        artifacts: [occurrence],
        relations: [],
        canonicalSHA256: String(repeating: "0", count: 64)
    )
    let manifest = try ReconstructionCorpusManifest(
        reconstructionProjectID: projectID,
        artifacts: draft.artifacts,
        relations: draft.relations,
        canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft)
    )
    let project = try ReconstructionProjectRecord(
        projectID: projectID,
        name: "Navigation fixture",
        currentCorpusManifestSHA256: manifest.canonicalSHA256
    )
    let state = try ReconstructionWorkspaceState(
        projects: [project],
        corpusManifests: [manifest],
        evidence: [],
        evidenceRelations: [],
        evidenceGaps: [],
        jobs: [],
        tasks: [],
        checkpoints: [],
        toolReceipts: [],
        modelReceipts: []
    )
    let workspaceID = UUID()
    let store = WorkspaceStore(
        workspaceName: "Reconstruction navigation",
        snapshot: snapshot,
        engine: ReconstructionFixedAnalysisProvider(result: snapshot),
        autosaveScheduler: nil,
        workspaceID: workspaceID
    )
    store.publishCommittedReconstructionCorpus(.init(
        state: state,
        attachmentSources: [headless.source]
    ))
    return ReconstructionNavigationFixture(
        headless: headless,
        store: store,
        request: ReconstructionSourceNavigationRequest(
            workspaceID: workspaceID,
            projectID: projectID,
            function: function
        ),
        function: function
    )
}

private func replacing(
    _ coordinate: ReconstructionFunctionCoordinate,
    artifact: ReconstructionArtifactCoordinate,
    fingerprint: String
) throws -> ReconstructionFunctionCoordinate {
    try ReconstructionFunctionCoordinate(
        artifact: artifact,
        image: coordinate.image,
        analysisFingerprintSHA256: fingerprint,
        startAddress: coordinate.startAddress,
        endAddressExclusive: coordinate.endAddressExclusive,
        boundarySchemaVersion: coordinate.boundarySchemaVersion,
        functionUUIDHint: coordinate.functionUUIDHint,
        symbolHint: coordinate.symbolHint
    )
}

private extension ReconstructionEvidenceRecord {
    var functionImageSlot: ImageSlot {
        guard case let .function(function) = subject else {
            preconditionFailure("The navigation fixture must carry function evidence.")
        }
        return function.image.imageSlot
    }
}

@MainActor
private func currentNavigationRequest(
    in store: WorkspaceStore
) throws -> ReconstructionSourceNavigationRequest {
    let state = store.reconstructionState
    let evidence = try XCTUnwrap(state.evidence.first(where: {
        $0.evidenceID == Task10InstalledScenarioSeedPackage.navigableEvidenceID
    }))
    let selectedJobID = try XCTUnwrap(state.jobs.first?.jobID)
    let projectID = try XCTUnwrap(state.jobs.first?.reconstructionProjectID)
    return try XCTUnwrap(WorkspaceRootView.reconstructionSourceNavigationRequest(
        evidence: evidence,
        selectedJobID: selectedJobID,
        projectID: projectID,
        workspaceID: store.workspaceID,
        workspace: state,
        snapshot: store.snapshot
    ))
}

@MainActor
private func assertFunctionAuthority(
    _ expectedFunctionID: UUID,
    request: ReconstructionSourceNavigationRequest,
    survivesIn store: WorkspaceStore
) throws {
    let target = try ReconstructionSourceNavigationAuthority.resolve(
        request: request,
        currentWorkspaceID: store.workspaceID,
        state: store.reconstructionState,
        snapshot: store.snapshot
    )
    XCTAssertEqual(target.functionID, expectedFunctionID)
}

private func ordinaryFileBytes(in root: URL) throws -> [String: Data] {
    let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
    ]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: Array(resourceKeys),
        options: [.skipsHiddenFiles]
    ) else { return [:] }
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: resourceKeys)
        if values.isDirectory == true { continue }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let relativePath = String(url.path.dropFirst(root.path.count + 1))
        result[relativePath] = try Data(contentsOf: url, options: .mappedIfSafe)
    }
    return result
}
