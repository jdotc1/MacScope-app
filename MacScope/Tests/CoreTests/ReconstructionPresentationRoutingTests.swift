import XCTest
import AppKit
import SwiftUI
@testable import MacScope

final class ReconstructionPresentationRoutingTests: XCTestCase {
    @MainActor
    func testHidingRetainedEditorResignsNativeKeyboardOwnership() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let editor = NSTextView(frame: root.bounds)
        let boundary = WorkspaceEditorFocusBoundary.BoundaryView()
        root.addSubview(editor)
        root.addSubview(boundary)
        window.contentView = root
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        boundary.setEditorVisible(false)
        XCTAssertFalse(window.firstResponder === editor)
        boundary.setEditorVisible(true)
        XCTAssertFalse(window.firstResponder === editor, "Showing a tool must not steal keyboard focus.")
    }
    @MainActor
    func testCentralHostRetainsEditorStateAcrossReconstructionAndReleasesOnRemoval() {
        var observed: [EditorLifetimeProbe] = []
        func content(_ destination: WorkspaceCentralDestination) -> AnyView {
            AnyView(WorkspaceCentralHost(destination: destination) {
                EditorLifetimeProbeView(onRender: { probe in
                    if observed.last !== probe { observed.append(probe) }
                })
            } reconstruction: { Text("Reconstruction") })
        }
        let host = NSHostingView(rootView: content(.editor))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.rootView = content(.reconstruction)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.rootView = content(.editor)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(observed.count, 1, "Tool switches must retain the same editor state owner.")
        weak var retained = observed.first
        observed.removeAll()
        XCTAssertNotNil(retained)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertNil(retained, "Removing the workspace host must release its editor owner.")
    }
    func testReconstructionToolAppendsAStablePersistedRawValue() throws {
        // Types (U7a) was appended after Reconstruction for the same reason.
        XCTAssertEqual(Array(WorkspaceTool.allCases.dropLast(2)), [
            .project, .symbols, .strings, .xrefs, .debug, .extensions,
        ])
        XCTAssertEqual(WorkspaceTool.allCases.suffix(2), [.reconstruction, .types])
        XCTAssertEqual(WorkspaceTool.reconstruction.rawValue, "Reconstruction")
        XCTAssertEqual(
            WorkspaceTool.reconstruction.systemImage,
            "arrow.trianglehead.2.clockwise.rotate.90"
        )

        let encoded = try JSONEncoder().encode(WorkspaceTool.reconstruction)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""Reconstruction""#)
        XCTAssertEqual(
            try JSONDecoder().decode(WorkspaceTool.self, from: encoded),
            .reconstruction
        )
        XCTAssertEqual(
            AppAccessibilityText.sidebarNavigatorLabel(tool: .reconstruction),
            "Reconstruction navigator"
        )
        XCTAssertEqual(
            AppAccessibilityText.sourceListLabel(tool: .reconstruction),
            "Reconstruction source list"
        )

        let session = WorkspacePackageSession(
            selectedSidebarItemID: "reconstruction:job:fixture",
            selectedAddress: 0x1000,
            selectedTool: .reconstruction,
            editorMode: .pseudocode,
            isInspectorPresented: true,
            sidebarSearchText: "recover",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let sessionData = try JSONEncoder().encode(session)
        XCTAssertEqual(
            try JSONDecoder().decode(WorkspacePackageSession.self, from: sessionData),
            session
        )
    }

    @MainActor
    func testCentralRouteAndInspectorPolicyAreReconstructionSpecific() {
        for tool in WorkspaceTool.allCases where tool != .reconstruction {
            XCTAssertEqual(WorkspaceRootView.centralDestination(for: tool), .editor)
            XCTAssertEqual(
                WorkspaceRootView.centralAccessibilityIdentifier(for: tool),
                "workspace.pane.editor"
            )
            XCTAssertTrue(
                WorkspaceRootView.shouldPresentInspector(
                    for: tool,
                    requested: true,
                    layoutAllowsInspector: true
                )
            )
        }

        XCTAssertEqual(
            WorkspaceRootView.centralDestination(for: .reconstruction),
            .reconstruction
        )
        XCTAssertEqual(
            WorkspaceRootView.centralAccessibilityIdentifier(for: .reconstruction),
            "reconstruction.destination"
        )
        XCTAssertFalse(
            WorkspaceRootView.shouldPresentInspector(
                for: .reconstruction,
                requested: true,
                layoutAllowsInspector: true
            )
        )
    }

    func testMainWindowUsesUnifiedTitlebarWhilePreservingLogicalDocumentTitle() throws {
        let appSource = try macScopeAppSource()
        let mainWindowStart = try XCTUnwrap(
            appSource.range(of: "WindowGroup(\"MacScope\", for: WorkspaceWindowID.self)")
        ).lowerBound
        let settingsStart = try XCTUnwrap(
            appSource.range(of: "        Settings {", range: mainWindowStart..<appSource.endIndex)
        ).lowerBound
        let mainWindow = appSource[mainWindowStart..<settingsStart]

        XCTAssertTrue(mainWindow.contains(".windowStyle(.hiddenTitleBar)"))
        XCTAssertFalse(mainWindow.contains(".windowStyle(.plain)"))

        let workspaceSource = try workspaceRootSource()
        XCTAssertTrue(workspaceSource.contains(".navigationTitle("))
        XCTAssertTrue(workspaceSource.contains("WorkspaceDocumentCommandPolicy.resolve("))
        XCTAssertTrue(workspaceSource.contains("documentDisplayName: documentDisplayName"))
        XCTAssertTrue(workspaceSource.contains("LumenToolbarIdentity(store.focusedBinary?.name ?? documentDisplayName,"))
    }

    /// U8-0: the workspace window is Lumen's, whose top bar owns the glow, the window-button band,
    /// dragging and the panel toggles; MacScope's own drag regions and inspector toggle are gone.
    func testTheTopBarIsLumensPinnedWindowBar() throws {
        let source = try workspaceRootSource()
        XCTAssertTrue(source.contains("LumenWorkspaceWindow(panels: workspacePanels(layout: layout))"))
        XCTAssertFalse(source.contains("WindowDragGesture()"), "Lumen's top bar owns window dragging")
        XCTAssertFalse(source.contains("DSToolbarInspectorToggle"), "the window's panel toggles replace the hand-made one")
        XCTAssertFalse(source.contains("HSplitView {"), "the window lays out the columns")
    }

    @MainActor
    func testChangingOnlyTheDestinationPreservesEditorFocusAndPresentationState() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let nativePresentation = NativeDecompilerPresentationModel()
        store.editorMode = .graph
        store.isInspectorPresented = true

        let originalTool = store.selectedTool
        let imageAddress = store.selectedImageAddress
        let address = store.selectedAddress
        let graphElementID = store.selectedGraphElementID
        let focusedSlot = store.focusedImageSlot
        let editorMode = store.editorMode
        let inspectorRequested = store.isInspectorPresented
        let snapshotBinaryIDs = store.snapshot.binaries.map(\.id)
        let debuggerCatalog = store.debuggerWorkspaceArtifactCatalog
        let assistantHistory = store.phase2AssistantSessionHistory
        let nativeState = nativePresentation.state

        for destination in [WorkspaceTool.reconstruction, originalTool] {
            store.selectedTool = destination

            XCTAssertEqual(store.selectedTool, destination)
            XCTAssertEqual(store.selectedImageAddress, imageAddress)
            XCTAssertEqual(store.selectedAddress, address)
            XCTAssertEqual(store.selectedGraphElementID, graphElementID)
            XCTAssertEqual(store.focusedImageSlot, focusedSlot)
            XCTAssertEqual(store.editorMode, editorMode)
            XCTAssertEqual(store.isInspectorPresented, inspectorRequested)
            XCTAssertEqual(store.snapshot.binaries.map(\.id), snapshotBinaryIDs)
            XCTAssertEqual(store.debuggerWorkspaceArtifactCatalog, debuggerCatalog)
            XCTAssertEqual(store.phase2AssistantSessionHistory, assistantHistory)
            XCTAssertEqual(nativePresentation.state, nativeState)
        }
    }

    func testCreationItemsComeOnlyFromCommittedCurrentCorpusCoordinates() throws {
        let fixture = try creationWorkspace()
        let items = ReconstructionJobCreationItem.committedItems(in: fixture.workspace)

        XCTAssertEqual(items.map(\.displayName), ["Alpha", "Zulu"])
        XCTAssertEqual(Set(items.map(\.projectID)).count, 1)
        XCTAssertEqual(Set(items.map(\.occurrenceID)), Set(fixture.currentOccurrenceIDs))
        XCTAssertFalse(items.contains { $0.occurrenceID == fixture.historicalOccurrenceID })
        XCTAssertEqual(
            items.map(\.artifactCoordinate),
            items.map {
                ReconstructionArtifactCoordinate(
                    occurrenceID: $0.occurrenceID,
                    contentIdentity: $0.contentIdentity
                )
            }
        )
    }

    func testCreationRequestPreservesExactArtifactFocusAndRejectsRemovedOwner() throws {
        let fixture = try creationWorkspace()
        let items = ReconstructionJobCreationItem.committedItems(in: fixture.workspace)
        let first = try XCTUnwrap(items.first)
        let budget = try ReconstructionJobBudget(
            maxRounds: 8, maxTasks: 1_024, maxEvidenceRecords: 4_096,
            maxEncodedBytes: 64 * 1_024 * 1_024
        )
        let focus = ReconstructionSubjectCoordinate.artifact(first.artifactCoordinate)
        let request = ReconstructionJobCreationRequest(
            selectedItems: items, committedItems: items, objective: "Recover artifact",
            budget: budget, focus: focus
        )
        XCTAssertEqual(request?.focus, focus)
        XCTAssertNil(ReconstructionJobCreationRequest(
            selectedItems: items.filter { $0.id != first.id }, committedItems: items,
            objective: "Recover artifact", budget: budget, focus: focus
        ))
        XCTAssertNil(ReconstructionJobCreationRequest(
            selectedItems: items, committedItems: items, objective: "Recover artifact",
            budget: budget, focus: .artifact(ReconstructionArtifactCoordinate(
                occurrenceID: first.occurrenceID,
                contentIdentity: try ReconstructionContentIdentity(
                    algorithm: .sha256, digest: String(repeating: "f", count: 64),
                    byteCount: first.contentIdentity.byteCount
                )
            ))
        ))
        XCTAssertNil(ReconstructionJobCreationRequest(
            selectedItems: items, committedItems: items, objective: "Recover corpus", budget: budget
        )?.focus)
    }

    func testCreationRequestRequiresCommittedFunctionFocus() throws {
        let fixture = try creationWorkspace()
        let items = ReconstructionJobCreationItem.committedItems(in: fixture.workspace)
        let first = try XCTUnwrap(items.first)
        let function = try ReconstructionFunctionCoordinate(
            artifact: first.artifactCoordinate,
            image: ReconstructionImageBinding(binaryID: UUID(), imageSlot: .primary,
                selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: String(repeating: "a", count: 64),
            startAddress: 0x1000, endAddressExclusive: 0x1020,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: "known"
        )
        let budget = try ReconstructionJobBudget(
            maxRounds: 8, maxTasks: 1_024, maxEvidenceRecords: 4_096,
            maxEncodedBytes: 64 * 1_024 * 1_024
        )
        XCTAssertNil(ReconstructionJobCreationRequest(
            selectedItems: items, committedItems: items, objective: "Recover function",
            budget: budget, focus: .function(function)
        ))
        XCTAssertEqual(ReconstructionJobCreationRequest(
            selectedItems: items, committedItems: items, objective: "Recover function",
            budget: budget, focus: .function(function), committedFunctions: [function]
        )?.focus, .function(function))
        XCTAssertFalse(ReconstructionJobCreationRequest.acceptsFocus(
            .function(function), selectedItems: items.filter { $0.id != first.id },
            committedFunctions: [function]
        ))

        let producer = try ReconstructionProducerIdentity(
            macScopeBuildIdentity: "test", macScopeSourceIdentity: "test",
            operationIdentity: "test.function", registryIdentity: "test",
            protocolIdentity: "test", canonicalSHA256: String(repeating: "a", count: 64)
        )
        func workspace(
            classification: ReconstructionEvidenceClassification,
            supersededBy: UUID? = nil
        ) throws -> ReconstructionWorkspaceState {
            let evidence = try ReconstructionEvidenceRecord(
                evidenceID: UUID(), subject: .function(function), operationID: "test.function",
                payloadKind: .text, payload: Data("x".utf8), payloadByteCount: 1,
                payloadSHA256: String(repeating: "b", count: 64), facetDependencies: [],
                producer: producer, citations: [], creatingJobID: UUID(),
                creatingTaskID: UUID(), creatingCheckpointID: UUID(), modelReceiptID: nil,
                toolReceiptID: nil, classification: classification, supersedesEvidenceID: nil,
                supersededByEvidenceID: supersededBy, diagnostic: nil
            )
            return try ReconstructionWorkspaceState(
                projects: fixture.workspace.projects, corpusManifests: fixture.workspace.corpusManifests,
                evidence: [evidence], evidenceRelations: [], evidenceGaps: [], jobs: [],
                tasks: [], checkpoints: [], toolReceipts: [], modelReceipts: [], finalResults: []
            )
        }
        XCTAssertEqual(ReconstructionJobCreationRequest.committedFunctions(
            in: try workspace(classification: .acceptedCurrent)
        ), [function])
        for classification in ReconstructionEvidenceClassification.allCases where classification != .acceptedCurrent {
            XCTAssertTrue(ReconstructionJobCreationRequest.committedFunctions(
                in: try workspace(classification: classification)
            ).isEmpty, "Ineligible classification: \(classification)")
        }
        XCTAssertTrue(ReconstructionJobCreationRequest.committedFunctions(
            in: try workspace(classification: .acceptedCurrent, supersededBy: UUID())
        ).isEmpty)
    }

    func testCreationRequestRejectsCrossProjectSelection() throws {
        let fixture = try creationWorkspace()
        let items = ReconstructionJobCreationItem.committedItems(in: fixture.workspace)
        let first = try XCTUnwrap(items.first)
        let foreign = ReconstructionJobCreationItem(
            projectID: UUID(uuidString: "84000000-0000-0000-0000-000000000001")!,
            occurrenceID: first.occurrenceID,
            contentIdentity: first.contentIdentity,
            displayName: first.displayName,
            detail: first.detail
        )
        let budget = try ReconstructionJobBudget(
            maxRounds: ReconstructionNewJobBudgetPolicy.maxRounds.lowerBound,
            maxTasks: ReconstructionNewJobBudgetPolicy.maxTasks.lowerBound,
            maxEvidenceRecords: ReconstructionNewJobBudgetPolicy.maxEvidenceRecords.lowerBound,
            maxEncodedBytes: ReconstructionNewJobBudgetPolicy.maxEncodedBytes.lowerBound
        )

        XCTAssertNil(
            ReconstructionJobCreationRequest(
                selectedItems: [first, foreign],
                committedItems: items,
                objective: "Recover one committed project",
                budget: budget
            )
        )
        XCTAssertEqual(
            ReconstructionJobCreationRequest(
                selectedItems: items,
                committedItems: items,
                objective: "Recover one committed project",
                budget: budget
            )?.projectID,
            first.projectID
        )

        let driftedContent = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: String(repeating: "f", count: 64),
            byteCount: first.contentIdentity.byteCount
        )
        let drifted = ReconstructionJobCreationItem(
            projectID: first.projectID,
            occurrenceID: first.occurrenceID,
            contentIdentity: driftedContent,
            displayName: first.displayName,
            detail: first.detail
        )
        XCTAssertNil(
            ReconstructionJobCreationRequest(
                selectedItems: [drifted],
                committedItems: items,
                objective: "Reject stale content authority",
                budget: budget
            )
        )
    }

    func testCreationRequestRejectsEmptySelectionAndPreservesTwoSelectedRoots() throws {
        let fixture = try creationWorkspace()
        let items = ReconstructionJobCreationItem.committedItems(in: fixture.workspace)
        XCTAssertEqual(items.count, 2)
        let budget = try ReconstructionJobBudget(
            maxRounds: ReconstructionNewJobBudgetPolicy.maxRounds.lowerBound,
            maxTasks: ReconstructionNewJobBudgetPolicy.maxTasks.lowerBound,
            maxEvidenceRecords: ReconstructionNewJobBudgetPolicy.maxEvidenceRecords.lowerBound,
            maxEncodedBytes: ReconstructionNewJobBudgetPolicy.maxEncodedBytes.lowerBound
        )

        XCTAssertNil(
            ReconstructionJobCreationRequest(
                selectedItems: [],
                committedItems: items,
                objective: "An empty selection cannot create a job",
                budget: budget
            )
        )

        let request = try XCTUnwrap(
            ReconstructionJobCreationRequest(
                selectedItems: Array(items.reversed()),
                committedItems: items,
                objective: "Preserve both selected roots",
                budget: budget
            )
        )
        XCTAssertEqual(request.selectedItems.map(\.occurrenceID), items.map(\.occurrenceID))
        XCTAssertEqual(request.selectedArtifacts, items.map(\.artifactCoordinate))
    }

    func testCreationRequestRejectsWhitespaceOnlyAndCanonicalizesObjectiveAtTheBoundary()
        throws {
        let fixture = try creationWorkspace()
        let items = ReconstructionJobCreationItem.committedItems(in: fixture.workspace)
        let budget = try ReconstructionJobBudget(
            maxRounds: 2,
            maxTasks: 32,
            maxEvidenceRecords: 64,
            maxEncodedBytes: 1_048_576
        )

        XCTAssertNil(
            ReconstructionJobCreationRequest(
                selectedItems: items,
                committedItems: items,
                objective: " \n\t  ",
                budget: budget
            )
        )
        let normalized = try XCTUnwrap(
            ReconstructionJobCreationRequest(
                selectedItems: items,
                committedItems: items,
                objective: "  Recover\n the\tselected   corpus.  ",
                budget: budget
            )
        )
        XCTAssertEqual(normalized.objective, "Recover the selected corpus.")
        XCTAssertEqual(normalized.budget.maxRounds, 2)

        let exactUTF8Bound = String(repeating: "é", count: 2_048)
        XCTAssertEqual(exactUTF8Bound.utf8.count, 4_096)
        XCTAssertEqual(
            ReconstructionJobCreationRequest(
                selectedItems: items,
                committedItems: items,
                objective: exactUTF8Bound,
                budget: budget
            )?.objective,
            exactUTF8Bound
        )
        XCTAssertNil(
            ReconstructionJobCreationRequest(
                selectedItems: items,
                committedItems: items,
                objective: exactUTF8Bound + "é",
                budget: budget
            )
        )
    }

    func testNewJobBudgetPolicyAcceptsExactBoundsAndRejectsEveryOutsideValue() throws {
        XCTAssertEqual(ReconstructionNewJobBudgetPolicy.maxRounds, 1...64)
        XCTAssertEqual(ReconstructionNewJobBudgetPolicy.maxTasks, 32...16_384)
        XCTAssertEqual(ReconstructionNewJobBudgetPolicy.maxEvidenceRecords, 64...65_536)
        XCTAssertEqual(ReconstructionNewJobBudgetPolicy.maxEncodedMiB, 1...1_024)
        XCTAssertEqual(
            ReconstructionNewJobBudgetPolicy.maxEncodedBytes,
            UInt64(1_048_576)...UInt64(1_073_741_824)
        )

        let fixture = try creationWorkspace()
        let items = ReconstructionJobCreationItem.committedItems(in: fixture.workspace)
        func request(
            _ budget: ReconstructionJobBudget
        ) -> ReconstructionJobCreationRequest? {
            ReconstructionJobCreationRequest(
                selectedItems: items,
                committedItems: items,
                objective: "Recover the exact committed corpus",
                budget: budget
            )
        }
        func budget(
            maxRounds: Int = 1,
            maxTasks: Int = 32,
            maxEvidenceRecords: Int = 64,
            maxEncodedBytes: UInt64 = 1_048_576
        ) throws -> ReconstructionJobBudget {
            try ReconstructionJobBudget(
                maxRounds: maxRounds,
                maxTasks: maxTasks,
                maxEvidenceRecords: maxEvidenceRecords,
                maxEncodedBytes: maxEncodedBytes
            )
        }

        let minimum = try budget()
        let maximum = try budget(
            maxRounds: 64,
            maxTasks: 16_384,
            maxEvidenceRecords: 65_536,
            maxEncodedBytes: 1_073_741_824
        )
        XCTAssertTrue(ReconstructionNewJobBudgetPolicy.accepts(minimum))
        XCTAssertTrue(ReconstructionNewJobBudgetPolicy.accepts(maximum))
        XCTAssertNotNil(request(minimum))
        XCTAssertNotNil(request(maximum))

        // The new-job policy must revalidate decoded historical input too. Decoding provides the
        // only value below maxRounds == 1 without tightening the durable budget initializer.
        let belowRounds = try JSONDecoder().decode(
            ReconstructionJobBudget.self,
            from: Data(
                #"{"maxRounds":0,"maxTasks":32,"maxEvidenceRecords":64,"maxEncodedBytes":1048576}"#
                    .utf8
            )
        )
        let belowBounds: [(String, ReconstructionJobBudget)] = [
            ("maxRounds", belowRounds),
            ("maxTasks", try budget(maxTasks: 31)),
            ("maxEvidenceRecords", try budget(maxEvidenceRecords: 63)),
            ("maxEncodedBytes", try budget(maxEncodedBytes: 1_048_575)),
        ]
        let aboveBounds: [(String, ReconstructionJobBudget)] = [
            ("maxRounds", try budget(maxRounds: 65)),
            ("maxTasks", try budget(maxTasks: 16_385)),
            ("maxEvidenceRecords", try budget(maxEvidenceRecords: 65_537)),
            ("maxEncodedBytes", try budget(maxEncodedBytes: 1_073_741_825)),
        ]
        for (field, outsideBudget) in belowBounds + aboveBounds {
            XCTAssertFalse(
                ReconstructionNewJobBudgetPolicy.accepts(outsideBudget),
                "Policy accepted out-of-range \(field)"
            )
            XCTAssertNil(request(outsideBudget), "Request accepted out-of-range \(field)")
        }
    }

    func testCreationFormAndRequestShareOnlyTheCentralNewJobBudgetPolicy() throws {
        let source = try reconstructionJobCreationSource()
        XCTAssertTrue(source.contains("ReconstructionNewJobBudgetPolicy.accepts(budget)"))
        XCTAssertTrue(source.contains("in: ReconstructionNewJobBudgetPolicy.maxRounds"))
        XCTAssertTrue(source.contains("in: ReconstructionNewJobBudgetPolicy.maxTasks"))
        XCTAssertTrue(source.contains(
            "in: ReconstructionNewJobBudgetPolicy.maxEvidenceRecords"
        ))
        XCTAssertTrue(source.contains("in: ReconstructionNewJobBudgetPolicy.maxEncodedMiB"))
        XCTAssertTrue(source.contains(
            "ReconstructionNewJobBudgetPolicy.encodedBytes("
        ))
    }

    func testCreationSheetLabelsMaxRoundsAsTheEvidenceStallBudget() throws {
        let source = try reconstructionJobCreationSource()
        XCTAssertTrue(source.contains(
            "Consecutive model rounds without new evidence: \\(maxRounds)"
        ))
        XCTAssertFalse(source.contains("Stepper(\"Model rounds:"))
    }

    func testProjectionSelectsExactJobThenHighestCreationOrdinalNeverUUIDOrder() throws {
        let olderID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let newestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let workspace = try jobWorkspace(olderID: olderID, newestID: newestID)

        XCTAssertEqual(
            ReconstructionStatusProjection.selectedJob(
                in: workspace,
                selectedJobID: olderID
            )?.jobID,
            olderID,
            "An exact valid selection must outrank fallback."
        )
        XCTAssertEqual(
            ReconstructionStatusProjection.selectedJob(
                in: workspace,
                selectedJobID: UUID()
            )?.jobID,
            newestID,
            "The newest durable ordinal must win even when its UUID sorts first."
        )
        XCTAssertEqual(
            ReconstructionStatusProjection.selectedJob(
                in: workspace,
                selectedJobID: nil
            )?.jobID,
            newestID
        )
    }

    func testOppositeUUIDCreationOrderAndProjectionSurvivePackageSaveAndReopen() throws {
        let olderID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let newestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let workspace = try jobWorkspace(olderID: olderID, newestID: newestID)
        let windowState = ReconstructionWindowPresentationState(
            windowID: UUID(uuidString: "82000000-0000-0000-0000-000000000099")!,
            selectedJobID: nil
        )
        let before = ReconstructionStatusProjection.project(
            workspace: workspace,
            selectedJobID: nil,
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete,
            windowState: windowState
        )
        XCTAssertEqual(before.jobID, newestID)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReconstructionPresentationCreationOrder-\(UUID().uuidString)",
            isDirectory: true
        )
        // The isolated Xcode test session owns and removes this temporary root. Deleting it here
        // makes the session perform a second removal and report a post-test fixture failure.
        let packageURL = root.appendingPathComponent("CreationOrder.mscope", isDirectory: true)
        let workspaceUUID = UUID(uuidString: "82000000-0000-0000-0000-000000000098")!
        let manifest = WorkspacePackageManifest(
            documentID: UUID(uuidString: "82000000-0000-0000-0000-000000000097")!,
            workspaceUUID: workspaceUUID,
            workspaceName: "Creation order persistence",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2),
            binaries: [],
            analysis: WorkspacePackageAnalysis(),
            session: nil
        )
        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: [:],
            reconstructionState: workspace,
            to: packageURL
        )

        let reopened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(
            reopened.reconstructionState.jobs.map(\.jobID),
            [olderID, newestID]
        )
        XCTAssertEqual(
            reopened.reconstructionState.jobs.map(\.creationOrdinal),
            [1, 2]
        )
        let after = ReconstructionStatusProjection.project(
            workspace: reopened.reconstructionState,
            selectedJobID: nil,
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete,
            windowState: windowState
        )
        XCTAssertEqual(after.jobID, newestID)
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testReconstructionSidebarIdentityRoundTripsWithoutAddressAuthority() {
        let jobID = UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
        let itemID = WorkspaceStore.reconstructionSidebarItemID(jobID)

        XCTAssertEqual(itemID, "reconstruction:job:\(jobID.uuidString)")
        XCTAssertEqual(
            WorkspaceStore.reconstructionJobID(fromSidebarItemID: itemID),
            jobID
        )
        XCTAssertNil(
            WorkspaceStore.reconstructionJobID(fromSidebarItemID: "function:\(jobID)")
        )
    }

    @MainActor
    func testReconstructionSidebarFiltersAndSelectsExactDurableJob() throws {
        let olderID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let newestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let workspace = try jobWorkspace(olderID: olderID, newestID: newestID)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReconstructionSidebarRouting-\(UUID().uuidString)",
            isDirectory: true
        )
        // The isolated Xcode test session owns and removes this temporary root. Deleting it here
        // makes the session perform a second removal and report a post-test fixture failure.
        let packageURL = root.appendingPathComponent("Sidebar.mscope", isDirectory: true)
        try MacScopeDocumentPackage.writePackage(
            WorkspacePackageManifest(
                documentID: UUID(),
                workspaceUUID: UUID(),
                workspaceName: "Reconstruction sidebar",
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2),
                binaries: [],
                analysis: WorkspacePackageAnalysis(),
                session: nil
            ),
            attachmentsByBinaryID: [:],
            reconstructionState: workspace,
            to: packageURL
        )
        let store = try WorkspaceStore.restoredPackage(
            from: packageURL,
            scheduleDurableRecovery: false
        )
        store.selectedTool = .reconstruction
        store.selectDefaultSidebarItemIfNeeded()

        XCTAssertEqual(
            store.selectableVisibleSidebarItems.map(\.id),
            [
                WorkspaceStore.reconstructionSidebarItemID(newestID),
                WorkspaceStore.reconstructionSidebarItemID(olderID),
            ]
        )
        XCTAssertEqual(store.selectedReconstructionJobID, newestID)

        store.sidebarSearchText = "Older objective"
        XCTAssertEqual(store.selectableVisibleSidebarItems.count, 1)
        let filtered = try XCTUnwrap(store.selectableVisibleSidebarItems.first)
        XCTAssertEqual(filtered.id, WorkspaceStore.reconstructionSidebarItemID(olderID))
        let target = try XCTUnwrap(store.sidebarNavigationTarget(for: filtered.id))
        XCTAssertTrue(store.activateSidebarItem(target))
        XCTAssertEqual(store.selectedReconstructionJobID, olderID)
        XCTAssertEqual(store.selectedSidebarItemID, filtered.id)

        store.sidebarSearchText = "created"
        XCTAssertEqual(store.selectableVisibleSidebarItems.count, 2)
        store.sidebarSearchText = ""
        XCTAssertTrue(store.selectableVisibleSidebarItems.contains { $0.id == filtered.id })
        XCTAssertEqual(store.selectedReconstructionJobID, olderID)
    }

    func testWorkspaceRootOwnsAndProjectsOneWindowKeyedPresentationValue() throws {
        let source = try workspaceRootSource()

        XCTAssertTrue(source.contains(
            "@State private var reconstructionPresentationState: "
                + "ReconstructionWindowPresentationState"
        ))
        XCTAssertTrue(source.contains("windowID: windowID.raw"))
        XCTAssertTrue(source.contains("windowState: effectiveWindow"))
        XCTAssertTrue(source.contains(
            ".onChange(of: store.selectedReconstructionJobID, initial: true)"
        ))
        XCTAssertTrue(source.contains("onSelectJob: selectReconstructionJob"))
        XCTAssertTrue(source.contains("onSelectTask: selectReconstructionTask"))
        XCTAssertTrue(source.contains("onSelectEvidence: selectReconstructionEvidence"))

        let localSelectionStart = try XCTUnwrap(
            source.range(of: "private func selectReconstructionJob")
        ).lowerBound
        let reconciliationStart = try XCTUnwrap(
            source.range(
                of: "private func reconcileReconstructionPendingIntent",
                range: localSelectionStart..<source.endIndex
            )
        ).lowerBound
        let localSelection = source[localSelectionStart..<reconciliationStart]
        XCTAssertFalse(localSelection.contains("store.reconstructionState ="))
        XCTAssertFalse(localSelection.contains("publishCommittedReconstruction"))
        XCTAssertFalse(localSelection.contains("selectedReconstructionJobID ="))
    }

    func testPendingStateIsWrittenBeforeDispatchAndReconciledOnlyFromDurableCuts() throws {
        let source = try workspaceRootSource()
        let beginStart = try XCTUnwrap(
            source.range(of: "private func beginReconstructionCommand")
        ).lowerBound
        let expectedStateStart = try XCTUnwrap(
            source.range(
                of: "private func expectedCommittedState",
                range: beginStart..<source.endIndex
            )
        ).lowerBound
        let begin = source[beginStart..<expectedStateStart]
        let stateWrite = try XCTUnwrap(begin.range(of: "reconstructionPresentationState ="))
        let asyncBoundary = try XCTUnwrap(begin.range(of: "Task { @MainActor in"))
        let dispatch = try XCTUnwrap(begin.range(of: "await dispatch(context)"))

        XCTAssertLessThan(stateWrite.lowerBound, asyncBoundary.lowerBound)
        XCTAssertLessThan(stateWrite.lowerBound, dispatch.lowerBound)
        XCTAssertTrue(begin.contains("windowID: pendingWindow.windowID"))
        XCTAssertTrue(begin.contains(
            "commandScopeID: reconstructionCommands.commandScopeID"
        ))
        XCTAssertTrue(begin.contains(
            "commandGeneration: pendingWindow.pendingIntent.generation"
        ))
        XCTAssertTrue(begin.contains("baseProjectionRevision: baseProjectionRevision"))
        XCTAssertTrue(begin.contains("jobID: pendingWindow.pendingIntent.jobID"))
        XCTAssertTrue(source.contains(
            ".onChange(of: reconstructionDurableIdentity, initial: true)"
        ))
        XCTAssertTrue(source.contains(
            ".onChange(of: reconstructionCommands.commandScopeID, initial: true)"
        ))
        XCTAssertTrue(source.contains(".reconcilingPending("))
        XCTAssertTrue(source.contains("resolveReconstructionCommandOutcome(outcome)"))
        XCTAssertTrue(source.contains("reconstructionPresentationState.accepting("))
        XCTAssertTrue(source.contains(
            ".fencingPendingForUnavailableCommandBoundary()"
        ))
        XCTAssertFalse(begin.contains("Task.detached"))
        XCTAssertFalse(begin.contains("DispatchQueue"))
    }

    func testAllSixCommandActionsReturnExactAsynchronousOutcomes() throws {
        let source = try workspaceRootSource()
        let actionsStart = try XCTUnwrap(
            source.range(of: "struct ReconstructionWorkspaceCommandActions")
        ).lowerBound
        let destinationStart = try XCTUnwrap(
            source.range(
                of: "enum WorkspaceCentralDestination",
                range: actionsStart..<source.endIndex
            )
        ).lowerBound
        let actions = source[actionsStart..<destinationStart]

        // Count the six exact-outcome command declarations and initializer arguments: the five
        // job-control commands plus the explicit source-example create command, which is
        // dispatched through the same create-kind command resolver. Import progress is an
        // independent async Void callback, not a seventh exact-outcome command.
        XCTAssertEqual(
            actions.components(separatedBy: ") async -> ReconstructionWorkspaceCommandOutcome")
                .count - 1,
            12
        )
        for command in [
            "createJob", "startSourceExample", "startJob", "pauseJob", "resumeJob", "cancelJob",
        ] {
            XCTAssertTrue(actions.contains("let \(command):"), command)
            XCTAssertTrue(actions.contains("self.\(command) = \(command)"), command)
        }
        XCTAssertTrue(actions.contains("ReconstructionWorkspaceCommandContext"))
        XCTAssertTrue(actions.contains("ReconstructionWorkspaceCommandOutcome"))
        XCTAssertTrue(actions.contains("let commandScopeID: UUID"))
        XCTAssertTrue(actions.contains("self.commandScopeID = commandScopeID"))
        XCTAssertFalse(actions.contains("let retryJob:"))
        XCTAssertFalse(actions.contains("self.retryJob"))
        XCTAssertFalse(actions.contains("let retireJob:"))
        XCTAssertFalse(actions.contains("self.retireJob"))

        let resolverStart = try XCTUnwrap(
            source.range(of: "private func resolveReconstructionCommandOutcome")
        ).lowerBound
        let expectedStateStart = try XCTUnwrap(
            source.range(
                of: "private func expectedCommittedState",
                range: resolverStart..<source.endIndex
            )
        ).lowerBound
        let resolver = source[resolverStart..<expectedStateStart]
        XCTAssertTrue(resolver.contains("windowID: outcome.context.windowID"))
        XCTAssertTrue(resolver.contains("commandScopeID: outcome.context.commandScopeID"))
        XCTAssertTrue(resolver.contains(
            "commandGeneration: outcome.context.commandGeneration"
        ))
        XCTAssertTrue(resolver.contains(
            "baseProjectionRevision: outcome.context.baseProjectionRevision"
        ))
        XCTAssertTrue(resolver.contains("jobID: outcome.context.jobID"))
        XCTAssertTrue(resolver.contains("guard result.accepted else { return }"))
        XCTAssertTrue(resolver.contains("outcome.disposition == .completed"))
        XCTAssertTrue(resolver.contains("store.reconstructionState.jobs.contains"))
    }

    func testWorkspaceRootProjectsOneExactProviderControllerSnapshot() throws {
        let source = try workspaceRootSource()
        let appSource = try macScopeAppSource()

        XCTAssertTrue(source.contains(
            "var assistantProviderSnapshot: Phase2LocalAIProviderSnapshot?"
        ))
        XCTAssertTrue(source.contains(
            "assistantProviderSnapshot?.readiness ?? .unavailable"
        ))
        XCTAssertTrue(source.contains(
            "assistantProviderSnapshot?.activity ?? .idle"
        ))
        XCTAssertTrue(source.contains(
            "assistantProviderSnapshot?.revision ?? 0"
        ))
        XCTAssertTrue(source.contains("activity: assistantProviderActivity"))
        XCTAssertTrue(source.contains("providerRevision: assistantProviderRevision"))
        XCTAssertTrue(appSource.contains(
            "assistantProviderSnapshot: localAIProviderController.snapshot"
        ))
        XCTAssertFalse(appSource.contains(
            "assistantReadiness: localAIProviderController.snapshot.readiness"
        ))
    }

    func testWorkspaceRootObservesLiveRuntimeActivationAndReevaluatesCommands() throws {
        let source = try workspaceRootSource()
        let appSource = try macScopeAppSource()

        XCTAssertTrue(source.contains(
            "@ObservedObject private var reconstructionActivationModel:"
        ))
        XCTAssertTrue(source.contains(
            "wrappedValue: reconstructionActivationModel ?? .unavailable"
        ))
        XCTAssertTrue(source.contains(
            ".onChange(of: reconstructionActivationModel.snapshot, initial: true)"
        ))
        XCTAssertTrue(source.contains(
            "private let reconstructionCommandActions:"
        ))
        XCTAssertTrue(source.contains("reconstructionCommandActions()"))
        XCTAssertTrue(source.contains("case .inactive, .activating, .restoring:"))
        XCTAssertTrue(source.contains("case .ready:"))
        XCTAssertTrue(source.contains("case .failed(let failure):"))
        XCTAssertTrue(source.contains("restoreStatus: reconstructionRestoreStatus"))

        XCTAssertTrue(appSource.contains(
            "reconstructionActivationModel: reconstructionRuntime?.activationModel"
        ))
        XCTAssertTrue(appSource.contains(
            "struct ReconstructionWorkspaceRootHost: View"
        ))
        XCTAssertTrue(appSource.contains(
            "@ObservedObject var registry: WorkspaceSessionRegistry"
        ), "already-open windows must observe late validated factory installation")
        XCTAssertTrue(appSource.contains(
            "documentRuntime.registry.installReconstructionRuntimeFactoryIfNeeded {"
        ))
        XCTAssertTrue(appSource.contains(
            "await runtimeServices.reconstructionWorkspaceRuntimeFactory("
        ), "production startup must await validation outside its synchronous initializer")
        XCTAssertFalse(appSource.contains(
            "reconstructionRuntimeFactory:\n                runtimeServices.reconstructionWorkspaceRuntimeFactory("
        ), "initial document composition must remain unavailable while validation is pending")
        XCTAssertTrue(appSource.contains("@ObservedObject var store: WorkspaceStore"))
        XCTAssertTrue(appSource.contains(
            "@ObservedObject var documentSession: WorkspaceDocumentSession"
        ))
        XCTAssertTrue(appSource.contains(
            "selectedTool: store.selectedTool"
        ))
        XCTAssertTrue(appSource.contains(
            "canonicalDocumentPath: documentSession.snapshot.location?.canonicalURL.path"
        ))
        XCTAssertTrue(appSource.contains("reconstructionCommandActions: {"))
        XCTAssertTrue(appSource.contains(
            "reconstructionRuntime?.commandActions ?? .unavailable"
        ))
    }

    func testFocusedReconstructionMenuRoutesExactlyFiveCommandsWithoutStealingSheetEscape()
        throws
    {
        let commandsSource = try appCommandsSource()
        let menuStart = try XCTUnwrap(
            commandsSource.range(of: "CommandMenu(\"Reconstruction\")")
        ).lowerBound
        let nextMenu = try XCTUnwrap(
            commandsSource.range(
                of: "CommandMenu(\"Patch\")",
                range: menuStart..<commandsSource.endIndex
            )
        ).lowerBound
        let menu = commandsSource[menuStart..<nextMenu]

        XCTAssertEqual(menu.components(separatedBy: "Button(").count - 1, 5)
        for command in ReconstructionCommandKind.allCases {
            XCTAssertTrue(menu.contains("Button(\"\(command.label)\""), command.label)
            XCTAssertTrue(
                menu.contains("performReconstructionCommand(.\(command.rawValue))"),
                command.label
            )
            XCTAssertTrue(
                menu.contains(".disabled(!reconstructionCommandIsEnabled(.\(command.rawValue)))"),
                command.label
            )
        }
        XCTAssertFalse(menu.lowercased().contains("retry"))
        XCTAssertFalse(menu.lowercased().contains("retire"))
        for shortcut in [
            #".keyboardShortcut("n", modifiers: [.command, .option])"#,
            #".keyboardShortcut(.return, modifiers: .command)"#,
            #".keyboardShortcut("p", modifiers: [.command, .option])"#,
            #".keyboardShortcut("r", modifiers: [.command, .option])"#,
        ] {
            XCTAssertTrue(menu.contains(shortcut), shortcut)
        }
        XCTAssertFalse(menu.contains(#".keyboardShortcut(.cancelAction)"#))
        XCTAssertTrue(
            try reconstructionJobCreationSource().contains(
                #".keyboardShortcut(.cancelAction)"#
            )
        )

        let rootSource = try workspaceRootSource()
        XCTAssertTrue(rootSource.contains("\\.reconstructionWindowCommands"))
        XCTAssertTrue(rootSource.contains("reconstructionFocusedCommandRouting"))
        XCTAssertTrue(rootSource.contains(
            "dispatcher = reconstructionDashboardCommandDispatcher"
        ))
        XCTAssertTrue(rootSource.contains("onStart: dispatcher.action(for: .start)"))

        let dashboard = try reconstructionDashboardSource()
        XCTAssertFalse(dashboard.contains(".keyboardShortcut("))
    }

    func testEvidenceNavigationRequiresCurrentFunctionEvidenceAndDoubleAuthorityCheck()
        throws {
        let source = try workspaceRootSource()
        let helperStart = try XCTUnwrap(
            source.range(of: "static func reconstructionSourceNavigationRequest")
        ).lowerBound
        let debuggerStart = try XCTUnwrap(
            source.range(
                of: "static func makeDebuggerClient",
                range: helperStart..<source.endIndex
            )
        ).lowerBound
        let helper = source[helperStart..<debuggerStart]

        XCTAssertTrue(helper.contains("$0.sourceNavigationEligible"))
        XCTAssertTrue(helper.contains("$0.creatingJobID == jobID"))
        XCTAssertTrue(helper.contains("evidence.creatingJobID == selectedJobID"))
        XCTAssertTrue(helper.contains("evidence.classification == .acceptedCurrent"))
        XCTAssertTrue(helper.contains("case let .function(function) = evidence.subject"))
        XCTAssertTrue(helper.contains("ReconstructionSourceNavigationAuthority.resolve("))
        XCTAssertTrue(source.contains("Self.dispatchReconstructionSourceReveal("))
        XCTAssertTrue(source.contains(
            "reveal: { try store.revealReconstructionSource($0) }"
        ))
        XCTAssertTrue(source.contains("reconstructionSourceNavigationRefusal("))
        XCTAssertTrue(source.contains("transientNotice: reconstructionTransientNotice"))
        XCTAssertFalse(source.contains("try? store.revealReconstructionSource(request)"))
        XCTAssertFalse(helper.contains("selectedAddress ="))
        XCTAssertFalse(helper.contains("selectedTool ="))

        // Mutation RED: restore the prior `try?` call. The explicit refusal and `try?` assertions
        // both fail even though the Store authority resolver itself remains unchanged.
    }

    func testWorkspaceRootProjectsTheRuntimeOwnedFrontierAndRevision() throws {
        let source = try workspaceRootSource()
        let projectionStart = try XCTUnwrap(
            source.range(of: "private var reconstructionProjection: ReconstructionStatusProjection")
        ).lowerBound
        let creationStart = try XCTUnwrap(
            source.range(
                of: "private var reconstructionCreationValidation",
                range: projectionStart..<source.endIndex
            )
        ).lowerBound
        let projection = source[projectionStart..<creationStart]

        XCTAssertTrue(projection.contains(
            "reconstructionActivationModel.snapshot"
        ))
        XCTAssertTrue(projection.contains(
            ".presentationAuthority.job(exactJobID)"
        ))
        XCTAssertTrue(projection.contains(
            "currentEvidenceFrontierSHA256: runtimeAuthority?.evidenceFrontierSHA256"
        ))
        XCTAssertTrue(projection.contains(
            "durableProjectionRevision: runtimeAuthority?.projectionRevision"
        ))

        // Mutation RED: remove either explicit project argument. The corresponding assertion
        // fails and prevents the live root from reverting to a self-current projection.
    }

    func testWorkspaceRootRequiresDurableDocumentLocationForCreation() throws {
        let source = try workspaceRootSource()
        XCTAssertTrue(source.contains(
            "documentSession.snapshot.location == nil"
        ))
        XCTAssertTrue(source.contains(
            "? .durableDocumentLocationMissing"
        ))
        XCTAssertTrue(source.contains(
            "creationValidation: reconstructionCreationValidation"
        ))
        XCTAssertTrue(source.contains(
            "submissionAvailable: reconstructionCreationSubmissionAvailable"
        ))
        XCTAssertTrue(source.contains(
            "guard reconstructionCreationSubmissionAvailable,"
        ))
    }

    func testReconstructionIntegrationAddsNoSecondTitlebarOrDetachedInspectorBand() throws {
        let source = try workspaceRootSource()
        let centralStart = try XCTUnwrap(
            source.range(of: "private var centralContent: some View")
        ).lowerBound
        let projectionStart = try XCTUnwrap(
            source.range(
                of: "private var reconstructionProjection",
                range: centralStart..<source.endIndex
            )
        ).lowerBound
        let central = source[centralStart..<projectionStart]

        XCTAssertTrue(central.contains("ReconstructionDashboardView("))
        XCTAssertFalse(central.contains("NavigationStack"))
        XCTAssertFalse(central.contains("NavigationSplitView"))
        XCTAssertFalse(central.contains(".inspector("))
        XCTAssertFalse(central.contains("WorkspaceTopBar("))
    }

    private func jobWorkspace(
        olderID: UUID,
        newestID: UUID
    ) throws -> ReconstructionWorkspaceState {
        let projectID = UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
        let digest = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            reconstructionProjectID: projectID,
            artifacts: [],
            relations: []
        )
        let budget = try ReconstructionJobBudget(
            maxRounds: 2,
            maxTasks: 4,
            maxEvidenceRecords: 8,
            maxEncodedBytes: 1_024
        )
        let olderObjective = "Older objective"
        let newestObjective = "Newest objective"
        let older = try ReconstructionJobRecord(
            jobID: olderID,
            reconstructionProjectID: projectID,
            objective: olderObjective,
            objectiveSHA256: MacScopeDocumentPackage.fileHash(
                for: Data(olderObjective.utf8)
            ),
            creationCorpusManifestSHA256: digest,
            state: .created,
            currentCheckpointID: nil,
            terminalReason: nil,
            budget: budget,
            creationOrdinal: 1
        )
        let newest = try ReconstructionJobRecord(
            jobID: newestID,
            reconstructionProjectID: projectID,
            objective: newestObjective,
            objectiveSHA256: MacScopeDocumentPackage.fileHash(
                for: Data(newestObjective.utf8)
            ),
            creationCorpusManifestSHA256: digest,
            state: .created,
            currentCheckpointID: nil,
            terminalReason: nil,
            budget: budget,
            creationOrdinal: 2
        )
        return try ReconstructionWorkspaceState(
            projects: [
                try ReconstructionProjectRecord(
                    projectID: projectID,
                    name: "Routing Fixture",
                    currentCorpusManifestSHA256: digest
                ),
            ],
            corpusManifests: [
                try ReconstructionCorpusManifest(
                    reconstructionProjectID: projectID,
                    artifacts: [],
                    relations: [],
                    canonicalSHA256: digest
                ),
            ],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [older, newest],
            tasks: [],
            checkpoints: [],
            toolReceipts: [],
            modelReceipts: []
        )
    }

    private func creationWorkspace() throws -> (
        workspace: ReconstructionWorkspaceState,
        currentOccurrenceIDs: [ReconstructionArtifactOccurrenceID],
        historicalOccurrenceID: ReconstructionArtifactOccurrenceID
    ) {
        let projectID = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
        let currentDigest = String(repeating: "a", count: 64)
        let historicalDigest = String(repeating: "b", count: 64)
        let alphaID = ReconstructionArtifactOccurrenceID(
            rawValue: UUID(uuidString: "83000000-0000-0000-0000-000000000002")!
        )
        let zuluID = ReconstructionArtifactOccurrenceID(
            rawValue: UUID(uuidString: "83000000-0000-0000-0000-000000000003")!
        )
        let historicalID = ReconstructionArtifactOccurrenceID(
            rawValue: UUID(uuidString: "83000000-0000-0000-0000-000000000004")!
        )

        func occurrence(
            id: ReconstructionArtifactOccurrenceID,
            name: String,
            digestCharacter: Character
        ) throws -> ReconstructionArtifactOccurrenceRecord {
            try ReconstructionArtifactOccurrenceRecord(
                occurrenceID: id,
                contentIdentity: ReconstructionContentIdentity(
                    algorithm: .sha256,
                    digest: String(repeating: digestCharacter, count: 64),
                    byteCount: 128
                ),
                kind: .machOImage,
                roles: [.primaryTarget],
                executableMode: true,
                originalName: name,
                diagnostic: nil
            )
        }

        let currentManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [
                occurrence(id: zuluID, name: "Zulu", digestCharacter: "c"),
                occurrence(id: alphaID, name: "Alpha", digestCharacter: "d"),
            ],
            relations: [],
            canonicalSHA256: currentDigest
        )
        let historicalManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [
                occurrence(id: historicalID, name: "Historical", digestCharacter: "e"),
            ],
            relations: [],
            canonicalSHA256: historicalDigest
        )
        let workspace = try ReconstructionWorkspaceState(
            projects: [
                try ReconstructionProjectRecord(
                    projectID: projectID,
                    name: "Creation Fixture",
                    currentCorpusManifestSHA256: currentDigest
                ),
            ],
            corpusManifests: [historicalManifest, currentManifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [],
            toolReceipts: [],
            modelReceipts: []
        )
        return (workspace, [alphaID, zuluID], historicalID)
    }

    private func workspaceRootSource() throws -> String {
        let coreTests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let macScope = coreTests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: macScope
                .appendingPathComponent("Features")
                .appendingPathComponent("Workspace")
                .appendingPathComponent("WorkspaceRootView.swift"),
            encoding: .utf8
        )
    }

    private func macScopeAppSource() throws -> String {
        let coreTests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let macScope = coreTests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: macScope
                .appendingPathComponent("App")
                .appendingPathComponent("MacScopeApp.swift"),
            encoding: .utf8
        )
    }

    private func appCommandsSource() throws -> String {
        let coreTests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let macScope = coreTests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: macScope
                .appendingPathComponent("App")
                .appendingPathComponent("AppCommands.swift"),
            encoding: .utf8
        )
    }

    private func reconstructionDashboardSource() throws -> String {
        let coreTests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let macScope = coreTests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: macScope
                .appendingPathComponent("Features")
                .appendingPathComponent("Reconstruction")
                .appendingPathComponent("ReconstructionDashboardView.swift"),
            encoding: .utf8
        )
    }

    private func reconstructionJobCreationSource() throws -> String {
        let coreTests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let macScope = coreTests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: macScope
                .appendingPathComponent("Features")
                .appendingPathComponent("Reconstruction")
                .appendingPathComponent("ReconstructionJobCreationSheet.swift"),
            encoding: .utf8
        )
    }
}

private final class EditorLifetimeProbe: ObservableObject {}

private struct EditorLifetimeProbeView: View {
    @StateObject private var owner = EditorLifetimeProbe()
    let onRender: (EditorLifetimeProbe) -> Void
    var body: some View {
        onRender(owner)
        return Text("Editor")
    }
}
