import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import MacScope

/// WS-17 RED oracles for the focused graph's image-qualified input, production canvas model,
/// and callback ownership. Every collision is intentional: a bare virtual address is not a
/// workspace identity.
final class FocusedGraphIdentityTests: XCTestCase {
    private let slotA = ImageSlot.primary
    private let slotB = ImageSlot(rawValue: 1)
    private let slotC = ImageSlot(rawValue: 7)

    private let entry: UInt64 = 0x1_0000_1000
    private let secondBlock: UInt64 = 0x1_0000_1008
    private let end: UInt64 = 0x1_0000_1010

    private let functionAID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!
    private let functionBID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1")!
    private let firstBlockAID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2")!
    private let secondBlockAID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA3")!
    private let firstBlockBID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB2")!
    private let secondBlockBID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB3")!
    private let cfgAID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA4")!
    private let cfgBID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB4")!
    private let xrefAID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA5")!
    private let xrefBID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB5")!

    // MARK: - Slot-owned aggregate

    func testSelectedFunctionScopePreservesImageOwnerAndGraphIdentity() throws {
        let source = collisionSnapshot().graphProjection(in: slotB)
        let scoped = try XCTUnwrap(GraphFunctionScope.project(source,
            selection: ImageAddress(slot: slotB, address: secondBlock)))
        XCTAssertEqual(scoped.imageSlot, slotB)
        XCTAssertEqual(scoped.ownerBinaryID, source.ownerBinaryID)
        XCTAssertEqual(scoped.functions.map(\.id), [functionBID])
        XCTAssertEqual(scoped.basicBlocks.map(\.id), source.basicBlocks.map(\.id))
        XCTAssertEqual(scoped.instructions.map(\.address), source.instructions.map(\.address))
        XCTAssertEqual(scoped.controlFlowEdges.map(\.id), source.controlFlowEdges.map(\.id))
        XCTAssertEqual(scoped.xrefs.map(\.id), source.xrefs.map(\.id))
    }

    func testSelectedFunctionScopeRejectsUnqualifiedAndUncoveredSelection() {
        var source = collisionSnapshot().graphProjection(in: slotB)
        XCTAssertNil(GraphFunctionScope.project(source, selection: nil))
        XCTAssertNil(GraphFunctionScope.project(source, selection: ImageAddress(slot: slotA, address: entry)))
        XCTAssertNil(GraphFunctionScope.project(source, selection: ImageAddress(slot: slotB, address: end)))
        source.basicBlocks.removeAll()
        XCTAssertNil(GraphFunctionScope.project(source, selection: ImageAddress(slot: slotB, address: entry)))
        source = collisionSnapshot().graphProjection(in: slotB)
        source.ownerBinaryID = nil
        XCTAssertNil(GraphFunctionScope.project(source, selection: ImageAddress(slot: slotB, address: entry)))
    }

    func testSelectedFunctionScopeRejectsAmbiguousFunctionAndBlockOwnership() {
        var source = collisionSnapshot().graphProjection(in: slotB)
        let selection = ImageAddress(slot: slotB, address: entry)
        source.functions.append(FunctionSummary(id: functionAID, name: "overlap",
            startAddress: entry, endAddress: end, confidence: 1))
        XCTAssertNil(GraphFunctionScope.project(source, selection: selection))
        source = collisionSnapshot().graphProjection(in: slotB)
        source.basicBlocks.append(BasicBlockSummary(id: firstBlockAID, functionID: functionAID,
            startAddress: entry, endAddress: secondBlock, instructionCount: 2))
        XCTAssertNil(GraphFunctionScope.project(source, selection: selection))
        source = collisionSnapshot().graphProjection(in: slotB)
        source.basicBlocks[0].endAddress = end + 4
        XCTAssertNil(GraphFunctionScope.project(source, selection: selection))
    }

    func testSelectedFunctionScopeExcludesDisjointOtherFunctionEvidence() throws {
        var source = collisionSnapshot().graphProjection(in: slotB)
        source.functions.append(FunctionSummary(id: functionAID, name: "other",
            startAddress: end, endAddress: end + 8, confidence: 1))
        source.basicBlocks.append(BasicBlockSummary(id: firstBlockAID, functionID: functionAID,
            startAddress: end, endAddress: end + 8, instructionCount: 2))
        let scoped = try XCTUnwrap(GraphFunctionScope.project(source,
            selection: ImageAddress(slot: slotB, address: entry)))
        XCTAssertEqual(scoped.functions.map(\.id), [functionBID])
        XCTAssertFalse(scoped.basicBlocks.contains { $0.functionID == functionAID })
    }

    func testGraphProjectionUsesOnlyRequestedImageEvidenceAtCollidingAddresses() {
        let snapshot = collisionSnapshot()

        let projection = snapshot.graphProjection(in: slotB)

        XCTAssertEqual(projection.imageSlot, slotB)
        XCTAssertEqual(projection.functions.map(\.id), [functionBID])
        XCTAssertEqual(projection.functions.map(\.name), ["B_PARSED_SENTINEL"])
        XCTAssertEqual(projection.basicBlocks.map(\.id), [firstBlockBID, secondBlockBID])
        XCTAssertEqual(projection.instructions.compactMap(\.comment), ["B_ENTRY_SENTINEL", "B_STEP", "B_TARGET", "B_RET"])
        XCTAssertEqual(projection.controlFlowEdges.map(\.id), [cfgBID])
        XCTAssertEqual(projection.xrefs.map(\.id), [xrefBID])
        XCTAssertEqual(projection.presentationByAddress[entry]?.customName, "B_CUSTOM_SENTINEL")
        XCTAssertEqual(projection.presentationByAddress[entry]?.tag, "B_TAG_SENTINEL")
        XCTAssertEqual(projection.presentationByAddress[entry]?.colorTag, .blue)

        XCTAssertFalse(projection.functions.contains { $0.id == functionAID || $0.name.contains("A_") })
        XCTAssertFalse(projection.basicBlocks.contains { $0.id == firstBlockAID || $0.id == secondBlockAID })
        XCTAssertFalse(projection.instructions.contains { $0.comment?.contains("A_") == true })
        XCTAssertFalse(projection.controlFlowEdges.contains { $0.id == cfgAID })
        XCTAssertFalse(projection.xrefs.contains { $0.id == xrefAID })
    }

    func testGraphProjectionKeepsRawRecoveredXRefsAndExcludesManualAndCrossImageXRefs() {
        var snapshot = collisionSnapshot()
        snapshot.manualXRefs = [
            ManualXRef(
                from: secondBlock,
                to: entry,
                kind: XRefKind.call,
                isSuppression: true,
                imageSlot: slotB
            ),
            ManualXRef(
                from: entry,
                to: secondBlock,
                kind: "B_MANUAL_SENTINEL",
                isSuppression: false,
                imageSlot: slotB
            ),
        ]
        snapshot.crossImageXrefs = [CrossImageXRef(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCC1")!,
            fromSlot: slotA,
            from: entry,
            toSlot: slotB,
            to: secondBlock,
            symbol: "B_CROSS_IMAGE_SENTINEL",
            kind: XRefKind.call
        )]

        let projection = snapshot.graphProjection(in: slotB)

        XCTAssertEqual(projection.xrefs.map(\.id), [xrefBID], "raw recovered xrefs survive a manual suppression in the graph input")
        XCTAssertEqual(projection.xrefs.map(\.kind), [XRefKind.call])
        XCTAssertFalse(projection.xrefs.contains { $0.kind == "B_MANUAL_SENTINEL" })
        XCTAssertFalse(projection.xrefs.contains { $0.from == entry && $0.to == secondBlock })
    }

    func testMissingAnalysisProducesAnEmptyProjectionOwnedByRequestedSlot() {
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: slotA, name: "A"), image(slot: slotB, name: "B")],
            analysisBySlot: [slotA: analysis(for: slotA)]
        )

        let projection = snapshot.graphProjection(in: slotB)

        XCTAssertEqual(projection.imageSlot, slotB)
        XCTAssertTrue(projection.functions.isEmpty)
        XCTAssertTrue(projection.basicBlocks.isEmpty)
        XCTAssertTrue(projection.instructions.isEmpty)
        XCTAssertTrue(projection.controlFlowEdges.isEmpty)
        XCTAssertTrue(projection.xrefs.isEmpty)
        XCTAssertTrue(projection.presentationByAddress.isEmpty)
    }

    // MARK: - Exact production canvas builder

    func testProductionBuilderBuildsOnlySiblingGraphAndPresentation() {
        let model = FocusedGraphBuilder.build(
            collisionSnapshot().graphProjection(in: slotB),
            viewport: CGSize(width: 1_280, height: 800)
        )

        XCTAssertEqual(model.imageSlot, slotB)
        XCTAssertEqual(model.sections.map(\.title), ["B_CUSTOM_SENTINEL"])
        XCTAssertEqual(model.nodes.map(\.startAddress), [entry, secondBlock])
        XCTAssertEqual(model.nodes.map(\.instructionCount), [2, 2])
        XCTAssertEqual(model.nodes.first?.tag, "B_TAG_SENTINEL")
        XCTAssertEqual(model.nodes.first?.colorTag, .blue)
        XCTAssertEqual(Set(model.edges.map(\.selectionTarget.imageSlot)), [slotB])

        XCTAssertFalse(model.sections.contains { $0.title.contains("A_") })
        XCTAssertFalse(model.nodes.contains { $0.title.contains("A_") || $0.functionName.contains("A_") })
        XCTAssertFalse(model.edges.contains { $0.selectionTarget.elementID.contains(cfgAID.uuidString) })
        XCTAssertFalse(model.edges.contains { $0.selectionTarget.elementID.contains(xrefAID.uuidString) })
    }

    func testProductionBuilderUsesRecoveredBlockSummaryCountsWhenRowsAreIncomplete() {
        var projection = collisionSnapshot().graphProjection(in: slotB)
        projection.instructions = [instruction(entry, comment: "PARTIAL_ROW_SENTINEL")]

        let model = FocusedGraphBuilder.build(
            projection,
            viewport: CGSize(width: 1_280, height: 800)
        )

        XCTAssertEqual(model.nodes.map(\.instructionCount), [2, 2])
    }

    func testProductionBuilderEmitsSlotQualifiedCFGAndRawXRefTargets() {
        let model = FocusedGraphBuilder.build(
            collisionSnapshot().graphProjection(in: slotB),
            viewport: CGSize(width: 1_280, height: 800)
        )

        let cfg = model.edges.first { $0.selectionTarget.elementID == "cfg:\(cfgBID.uuidString)" }
        XCTAssertEqual(cfg?.selectionTarget.imageSlot, slotB)
        XCTAssertEqual(cfg?.selectionTarget.fromAddress, entry)
        XCTAssertEqual(cfg?.selectionTarget.toAddress, secondBlock)
        XCTAssertEqual(cfg?.selectionTarget.kind, "branch")
        XCTAssertEqual(cfg?.selectionTarget.id, "image:\(slotB.rawValue):cfg:\(cfgBID.uuidString)")

        let xref = model.edges.first { $0.selectionTarget.elementID == "xref:\(xrefBID.uuidString)" }
        XCTAssertEqual(xref?.selectionTarget.imageSlot, slotB)
        XCTAssertEqual(xref?.selectionTarget.fromAddress, secondBlock)
        XCTAssertEqual(xref?.selectionTarget.toAddress, entry)
        XCTAssertEqual(xref?.selectionTarget.kind, XRefKind.call)
    }

    func testSparseFallbackUsesActualLastInstructionByteWidth() throws {
        var sparse = ImageAnalysis()
        sparse.instructions = [
            instruction(0x2_0000_0000, bytes: "90", comment: "B_SPARSE_FIRST"),
            instruction(0x2_0000_0009, bytes: "01 02 03 04 05 06", comment: "B_SPARSE_LAST"),
        ]
        let projection = FocusedGraphProjection(
            imageSlot: slotB,
            functions: [],
            basicBlocks: [],
            instructions: sparse.instructions,
            controlFlowEdges: [],
            xrefs: [],
            presentationByAddress: [:]
        )

        let model = FocusedGraphBuilder.build(projection, viewport: CGSize(width: 900, height: 700))
        let node = try XCTUnwrap(model.nodes.first)

        XCTAssertEqual(model.nodes.count, 1)
        XCTAssertEqual(node.startAddress, 0x2_0000_0000)
        XCTAssertEqual(node.endAddress, 0x2_0000_000F, "0x200000009 + the row's six encoded bytes")
        XCTAssertTrue(node.selectionTarget.contains(ImageAddress(slot: slotB, address: 0x2_0000_000E)))
        XCTAssertFalse(node.selectionTarget.contains(ImageAddress(slot: slotB, address: 0x2_0000_000F)))
    }

    func testSparseFallbackAbstainsWhenHalfOpenEndWouldOverflow() {
        let projection = FocusedGraphProjection(
            imageSlot: slotB,
            functions: [],
            basicBlocks: [],
            instructions: [instruction(.max, bytes: "ff", comment: "OVERFLOW_SENTINEL")],
            controlFlowEdges: [],
            xrefs: [],
            presentationByAddress: [:]
        )

        let model = FocusedGraphBuilder.build(projection, viewport: CGSize(width: 900, height: 700))

        XCTAssertTrue(model.nodes.isEmpty)
        XCTAssertTrue(model.edges.isEmpty)
        XCTAssertTrue(model.sections.isEmpty)
    }

    func testGraphSelectionTargetRejectsSameAddressFromAnotherSlot() {
        let target = GraphSelectionTarget(
            id: "image:\(slotB.rawValue):block:\(firstBlockBID.uuidString)",
            imageSlot: slotB,
            title: "Entry block",
            startAddress: entry,
            endAddress: secondBlock,
            functionID: functionBID
        )

        XCTAssertTrue(target.contains(ImageAddress(slot: slotB, address: entry + 4)))
        XCTAssertFalse(target.contains(ImageAddress(slot: slotA, address: entry + 4)))
        XCTAssertFalse(target.contains(nil))
    }

    // MARK: - Callback ownership and lifecycle

    @MainActor
    func testDelayedSiblingNodeCallbackRejectsAfterFocusChangesToPrimary() throws {
        let store = focusedSiblingStore()
        let captured = try XCTUnwrap(focusedModel(from: store).nodes.first?.selectionTarget)
        XCTAssertTrue(store.selectGraphNode(captured))
        XCTAssertEqual(store.selectedGraphElementID, captured.id)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: entry))
        let graphGroup = Set([ImageAddress(slot: slotB, address: entry)])
        XCTAssertTrue(store.setGraphNodeMultiSelection(graphGroup))
        XCTAssertEqual(store.graphNodeMultiSelection, graphGroup)
        XCTAssertFalse(store.graphNodeMultiSelection.isEmpty)

        store.focusImage(slotA)

        XCTAssertFalse(store.selectGraphNode(captured))
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(store.selectedGraphElementID)
        XCTAssertTrue(store.graphNodeMultiSelection.isEmpty)
    }

    @MainActor
    func testSameSlotNodeCallbackRejectsAfterReanalysisRemintsIdentity() throws {
        let store = focusedSiblingStore()
        let captured = try XCTUnwrap(focusedModel(from: store).nodes.first?.selectionTarget)
        XCTAssertTrue(store.selectGraphNode(captured))
        XCTAssertEqual(store.selectedGraphElementID, captured.id)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: entry))
        let graphGroup = Set([ImageAddress(slot: slotB, address: entry)])
        XCTAssertTrue(store.setGraphNodeMultiSelection(graphGroup))
        XCTAssertEqual(store.graphNodeMultiSelection, graphGroup)
        XCTAssertFalse(store.graphNodeMultiSelection.isEmpty)
        var replacement = store.snapshot
        replacement.replaceAnalysis(remintedAnalysis(for: slotB), in: slotB)
        store.snapshot = replacement

        XCTAssertFalse(store.selectGraphNode(captured))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: entry))
        XCTAssertNil(store.selectedGraphElementID)
        XCTAssertTrue(store.graphNodeMultiSelection.isEmpty)
    }

    @MainActor
    func testSameSlotEdgeCallbackRejectsAfterReanalysisRemintsIdentity() throws {
        let store = focusedSiblingStore()
        let captured = try XCTUnwrap(focusedModel(from: store).edges.first?.selectionTarget)
        XCTAssertTrue(store.selectGraphEdge(captured))
        XCTAssertEqual(store.selectedGraphElementID, captured.id)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: entry))
        let graphGroup = Set([ImageAddress(slot: slotB, address: entry)])
        XCTAssertTrue(store.setGraphNodeMultiSelection(graphGroup))
        XCTAssertEqual(store.graphNodeMultiSelection, graphGroup)
        XCTAssertFalse(store.graphNodeMultiSelection.isEmpty)
        var replacement = store.snapshot
        replacement.replaceAnalysis(remintedAnalysis(for: slotB), in: slotB)
        store.snapshot = replacement

        XCTAssertFalse(store.selectGraphEdge(captured))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: entry))
        XCTAssertNil(store.selectedGraphElementID)
        XCTAssertTrue(store.graphNodeMultiSelection.isEmpty)
    }

    @MainActor
    func testSameSlotGraphCallbacksRejectAfterBinaryOwnerReplacementPreservesStructuralIdentity() throws {
        let store = focusedSiblingStore()
        let model = focusedModel(from: store)
        let capturedNode = try XCTUnwrap(model.nodes.first?.selectionTarget)
        let capturedEdge = try XCTUnwrap(model.edges.first?.selectionTarget)

        replaceBinary(in: slotB, store: store)

        XCTAssertFalse(
            store.selectGraphNode(capturedNode),
            "a node rendered by the displaced binary must not bind to a replacement owner"
        )
        XCTAssertFalse(
            store.selectGraphEdge(capturedEdge),
            "an edge rendered by the displaced binary must not bind to a replacement owner"
        )
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(store.selectedGraphElementID)
    }

    @MainActor
    func testMixedSlotGraphColorSelectionRejectsWholeMutation() {
        let store = focusedSiblingStore()
        let graphGroup = Set([ImageAddress(slot: slotB, address: entry)])
        XCTAssertTrue(store.setGraphNodeMultiSelection(graphGroup))
        XCTAssertEqual(store.graphNodeMultiSelection, graphGroup)
        XCTAssertFalse(store.graphNodeMultiSelection.isEmpty)
        XCTAssertEqual(store.snapshot.colorTag(at: entry, in: slotB), .blue)
        XCTAssertNil(store.snapshot.colorTag(at: secondBlock, in: slotB))
        XCTAssertNil(store.snapshot.colorTag(at: secondBlock, in: slotA))

        XCTAssertFalse(store.setGraphColorTag(at: [
            ImageAddress(slot: slotB, address: entry),
            ImageAddress(slot: slotA, address: secondBlock),
        ], color: .red))

        XCTAssertEqual(store.snapshot.colorTag(at: entry, in: slotB), .blue)
        XCTAssertNil(store.snapshot.colorTag(at: secondBlock, in: slotB))
        XCTAssertNil(store.snapshot.colorTag(at: secondBlock, in: slotA))
        XCTAssertEqual(store.graphNodeMultiSelection, graphGroup)
        XCTAssertFalse(store.undoManager.canUndo)
    }

    @MainActor
    func testFocusedSiblingGraphColorSelectionMutatesOnlySiblingInOneUndoStep() {
        let store = focusedSiblingStore()
        let graphGroup = Set([
            ImageAddress(slot: slotB, address: entry),
            ImageAddress(slot: slotB, address: secondBlock),
        ])
        let before = store.snapshot.addressOverrides
        XCTAssertTrue(store.setGraphNodeMultiSelection(graphGroup))

        XCTAssertTrue(store.setGraphColorTag(
            at: graphGroup.sorted { $0.address < $1.address },
            color: .purple
        ))

        XCTAssertEqual(store.snapshot.colorTag(at: entry, in: slotB), .purple)
        XCTAssertEqual(store.snapshot.colorTag(at: secondBlock, in: slotB), .purple)
        XCTAssertEqual(store.snapshot.colorTag(at: entry, in: slotA), .red)
        XCTAssertNil(store.snapshot.colorTag(at: secondBlock, in: slotA))
        XCTAssertTrue(store.undoManager.canUndo)

        store.focusImage(slotA)
        store.undoManager.undo()

        XCTAssertEqual(store.snapshot.addressOverrides, before)
        XCTAssertFalse(store.undoManager.canUndo, "both B colors must be restored by one undo step")
        XCTAssertTrue(store.undoManager.canRedo)
    }

    @MainActor
    func testSameSlotReanalysisRejectsCapturedGraphColorGroupAfterIdentityRemint() {
        let store = focusedSiblingStore()
        let capturedGroup = Set([
            ImageAddress(slot: slotB, address: entry),
            ImageAddress(slot: slotB, address: secondBlock),
        ])
        XCTAssertTrue(store.setGraphNodeMultiSelection(capturedGroup))
        let before = store.snapshot.addressOverrides

        var replacement = store.snapshot
        replacement.replaceAnalysis(remintedAnalysis(for: slotB), in: slotB)
        store.snapshot = replacement

        XCTAssertTrue(store.graphNodeMultiSelection.isEmpty)
        XCTAssertFalse(store.setGraphColorTag(
            at: capturedGroup.sorted { $0.address < $1.address },
            color: .red
        ))
        XCTAssertEqual(store.snapshot.addressOverrides, before)
        XCTAssertFalse(store.undoManager.canUndo)
    }

    @MainActor
    func testSecondaryGraphSelectionLeavesPrimaryCompatibleSidebarSelectionUntouched() throws {
        let store = focusedSiblingStore()
        store.selectedTool = .project
        let primarySidebarID = "function:\(functionAID.uuidString)"
        store.selectedSidebarItemID = primarySidebarID
        let target = try XCTUnwrap(focusedModel(from: store).nodes.first?.selectionTarget)

        XCTAssertTrue(store.selectGraphNode(target))

        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: entry))
        XCTAssertEqual(store.selectedGraphElementID, target.id)
        XCTAssertEqual(store.selectedSidebarItemID, primarySidebarID)
    }

    /// The live GraphView's move-command seam must route through the store's history-neutral
    /// adjacent-node operation. Keyboard movement changes graph selection in focused-model order
    /// without manufacturing Back/Forward jumps.
    @MainActor
    func testGraphKeyboardNavigationStepsWithoutWritingNavigationHistory() throws {
        let store = focusedSiblingStore()
        let nodes = focusedModel(from: store).nodes
        let first = try XCTUnwrap(nodes.first?.selectionTarget)
        let second = try XCTUnwrap(nodes.dropFirst().first?.selectionTarget)
        XCTAssertTrue(store.selectGraphNode(first))
        let historyBeforeStepping = store.navigationHistoryRows

        GraphKeyboardNavigation.move(.right, in: store)

        XCTAssertEqual(store.selectedGraphElementID, second.id)
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: second.imageSlot, address: second.startAddress)
        )
        XCTAssertEqual(store.navigationHistoryRows, historyBeforeStepping)

        GraphKeyboardNavigation.move(.up, in: store)

        XCTAssertEqual(store.selectedGraphElementID, first.id)
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: first.imageSlot, address: first.startAddress)
        )
        XCTAssertEqual(store.navigationHistoryRows, historyBeforeStepping)
    }

    @MainActor
    func testScopedGraphKeyboardNavigationCannotLeaveAdmittedNodesOrChangeImageOwner() throws {
        let store = focusedSiblingStore()
        let first = try XCTUnwrap(focusedModel(from: store).nodes.first?.selectionTarget)
        XCTAssertTrue(store.selectGraphNode(first))
        GraphKeyboardNavigation.move(.right, in: store, targets: [first])
        XCTAssertEqual(store.selectedGraphElementID, first.id)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: first.startAddress))
        store.focusImage(slotA)
        let selection = store.selectedImageAddress
        GraphKeyboardNavigation.move(.right, in: store, targets: [first])
        XCTAssertEqual(store.focusedImageSlot, slotA)
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    /// A mapped address can be a valid selection even when no instruction starts there. The
    /// editor context still exposes its exact address visually and to VoiceOver instead of
    /// collapsing the non-nil selection into an absent-selection state.
    @MainActor
    func testEditorContextPreservesMappedUndecodedSelectionAddress() throws {
        let store = focusedSiblingStore()
        let mappedUndecoded = ImageAddress(slot: slotB, address: entry + 2)
        XCTAssertTrue(store.selectAddress(mappedUndecoded))
        XCTAssertNil(store.selectedInstruction)

        let selection = try XCTUnwrap(EditorContextResolution.selection(
            target: store.selectedImageAddress,
            instruction: store.selectedInstruction
        ))

        XCTAssertEqual(selection.address, mappedUndecoded.address.hexAddress)
        XCTAssertNil(selection.mnemonic)
        XCTAssertEqual(selection.accessibilitySummary, ", selected address \(mappedUndecoded.address.hexAddress)")
    }

    /// An explicit mapped selection outside every recovered function has no function context.
    /// Only the genuinely absent-selection state may retain the legacy first-function overview.
    @MainActor
    func testEditorContextDoesNotFallBackToFirstFunctionForUnownedSelection() {
        let store = focusedSiblingStore()
        let functions = store.focusedAnalysis?.functions ?? []
        let mappedOutsideFunctions = entry + 0x80

        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: mappedOutsideFunctions)))
        XCTAssertNil(EditorContextResolution.function(
            in: functions,
            selectedAddress: store.selectedAddress
        ))
        XCTAssertEqual(
            EditorContextResolution.function(in: functions, selectedAddress: nil)?.id,
            functions.first?.id
        )
    }

    /// A pseudocode row callback owns the image that supplied its rendered line. If that callback
    /// fires after focus moves from A to B at the same VA, exact selection rejects A instead of
    /// rebinding the bare address to B or disturbing B's current selection.
    @MainActor
    func testDelayedPseudocodeRowCallbackRejectsAfterFocusChangesImages() {
        let store = focusedSiblingStore()
        store.focusImage(slotA)
        let callback = PseudocodeSourceSelection(
            imageSlot: store.focusedPseudocodeRenderInput.imageSlot,
            ownerBinaryID: store.focusedBinary?.id,
            sourceAddress: entry
        )

        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: secondBlock)))

        XCTAssertFalse(callback.select(in: store))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: secondBlock))
    }

    /// A disassembly row callback owns the binary UUID that supplied the row, not only its slot
    /// and virtual address. Reusing slot B with a replacement binary must not let the delayed row
    /// selection bind to the replacement's colliding instruction.
    @MainActor
    func testDelayedDisassemblySelectionCallbackRejectsSameSlotBinaryReplacement() throws {
        let store = focusedSiblingStore()
        let callback = try XCTUnwrap(DisassemblyRowCallbackContext.capture(
            imageSlot: slotB,
            ownerBinaryID: store.focusedBinary?.id,
            address: entry
        ))

        replaceBinary(in: slotB, store: store)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: secondBlock)))

        XCTAssertFalse(callback.select(in: store))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: secondBlock))
    }

    /// The breakpoint gutter shares the rendered disassembly row's opening owner. A delayed
    /// gutter callback must abstain after same-slot replacement rather than toggling the new
    /// binary's colliding instruction or creating Undo state for that replacement.
    @MainActor
    func testDelayedDisassemblyBreakpointCallbackRejectsSameSlotBinaryReplacement() throws {
        let store = focusedSiblingStore()
        let callback = try XCTUnwrap(DisassemblyRowCallbackContext.capture(
            imageSlot: slotB,
            ownerBinaryID: store.focusedBinary?.id,
            address: entry
        ))

        replaceBinary(in: slotB, store: store)

        XCTAssertFalse(callback.toggleBreakpoint(in: store))
        XCTAssertEqual(
            store.snapshot.analysis(in: slotB)?.instructions.first { $0.address == entry }?.hasBreakpoint,
            false
        )
        XCTAssertFalse(store.undoManager.canUndo)
    }

    /// A rendered row belongs to the image that was focused when SwiftUI created it. Moving focus
    /// to A must permanently stale B's retained selection and gutter closures even while B remains
    /// loaded with the same binary UUID and colliding instruction addresses.
    @MainActor
    func testDelayedDisassemblyCallbacksRejectAfterFocusChangesImages() throws {
        let store = focusedSiblingStore()
        let callback = try XCTUnwrap(DisassemblyRowCallbackContext.capture(
            imageSlot: slotB,
            ownerBinaryID: store.focusedBinary?.id,
            address: entry
        ))

        store.focusImage(slotA)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotA, address: secondBlock)))

        XCTAssertFalse(callback.select(in: store))
        XCTAssertFalse(callback.toggleBreakpoint(in: store))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotA, address: secondBlock))
        XCTAssertEqual(
            store.snapshot.analysis(in: slotB)?.instructions.first { $0.address == entry }?.hasBreakpoint,
            false
        )
        XCTAssertFalse(store.undoManager.canUndo)
    }

    /// Selection-keyed authoring must not execute when a rendered row can no longer prove that it
    /// owns the current focus. The production gate covers every disassembly context-menu command.
    @MainActor
    func testRejectedDisassemblyRowSelectionSuppressesFollowOnAction() {
        var actionCount = 0

        XCTAssertFalse(DisassemblyRowActionGate.perform(select: { false }) {
            actionCount += 1
        })
        XCTAssertEqual(actionCount, 0)

        XCTAssertTrue(DisassemblyRowActionGate.perform(select: { true }) {
            actionCount += 1
        })
        XCTAssertEqual(actionCount, 1)
    }

    /// A local XRef inspector row owns the focused binary and exact edge generation that rendered
    /// it. A delayed callback must abstain after focus changes even when the destination VA collides.
    @MainActor
    func testDelayedXRefRowRejectsAfterFocusChangesImages() throws {
        let store = focusedSiblingStore()
        let xref = try XCTUnwrap(store.focusedAnalysis?.xrefs.first)
        let target = try XCTUnwrap(store.xrefNavigationTarget(
            for: xref,
            endpoint: xref.from,
            in: slotB
        ))

        store.focusImage(slotA)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotA, address: entry)))

        XCTAssertFalse(store.navigateToReference(target))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotA, address: entry))
    }

    /// Reanalysis can remint an edge while preserving its numeric coordinates. The old inspector
    /// row must not bind to that replacement edge merely because its endpoint still exists.
    @MainActor
    func testDelayedXRefRowRejectsAfterSameOwnerReanalysisRemintsEdge() throws {
        let store = focusedSiblingStore()
        let xref = try XCTUnwrap(store.focusedAnalysis?.xrefs.first)
        let target = try XCTUnwrap(store.xrefNavigationTarget(
            for: xref,
            endpoint: xref.from,
            in: slotB
        ))
        var replacement = store.snapshot
        replacement.analysisBySlot[slotB] = remintedAnalysis(for: slotB)
        store.snapshot = replacement

        XCTAssertFalse(store.navigateToReference(target))
        XCTAssertNil(store.selectedImageAddress)
    }

    /// Pseudocode rows and their context-menu actions retain the binary owner used to render the
    /// source line. Replacing B in place permanently stales the row: neither selection nor the
    /// follow-on Rename Register presentation may target the replacement at the colliding VA.
    @MainActor
    func testDelayedPseudocodeRowAndContextMenuRejectSameSlotBinaryReplacement() throws {
        let store = focusedSiblingStore()
        let callback = PseudocodeSourceSelection(
            imageSlot: store.focusedPseudocodeRenderInput.imageSlot,
            ownerBinaryID: store.focusedBinary?.id,
            sourceAddress: entry
        )

        replaceBinary(in: slotB, store: store)

        let accepted = callback.select(in: store)
        if accepted {
            store.beginRegisterRenameAtSelection(register: "x19")
        }

        XCTAssertFalse(accepted)
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(store.registerRenameRequest)
    }

    /// The AppKit hex callback captures the opening slot, binary owner, and exact offset mapping.
    /// A delayed A callback after B receives focus is rejected before the focused compatibility
    /// write path can reinterpret offset zero using B's colliding mapping.
    @MainActor
    func testDelayedHexEditCallbackCannotPatchNewlyFocusedImage() throws {
        let store = focusedSiblingStore()
        store.focusImage(slotA)
        let context = try XCTUnwrap(HexEditCallbackContext.capture(
            imageSlot: store.focusedImageSlot,
            ownerBinaryID: store.focusedBinary?.id,
            bytes: store.patchedHexWindow().bytes,
            mappings: store.hexWindowMappings
        ))
        XCTAssertEqual(context.target(at: 0), ImageAddress(slot: slotA, address: entry))

        store.focusImage(slotB)

        XCTAssertFalse(context.apply(offset: 0, value: 0xFF, to: store))
        XCTAssertNil(store.snapshot.addressOverrides[ImageAddress(slot: slotA, address: entry)]?.patch)
        XCTAssertNil(store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: entry)]?.patch)
    }

    /// Slot reuse does not revive an old NSTextView callback: the replacement image's UUID must
    /// still equal the owner captured when the editor opened, even when slot and mapping collide.
    @MainActor
    func testDelayedHexEditCallbackRejectsSameSlotBinaryReplacement() throws {
        let store = focusedSiblingStore()
        let context = try XCTUnwrap(HexEditCallbackContext.capture(
            imageSlot: store.focusedImageSlot,
            ownerBinaryID: store.focusedBinary?.id,
            bytes: store.patchedHexWindow().bytes,
            mappings: store.hexWindowMappings
        ))
        replaceBinary(in: slotB, store: store)

        XCTAssertFalse(context.apply(offset: 0, value: 0xEE, to: store))
        XCTAssertNil(store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: entry)]?.patch)
    }

    @MainActor
    func testHexCaretSelectionKeepsSiblingIdentityAndRejectsDelayedOwner() throws {
        let store = focusedSiblingStore()
        let context = try XCTUnwrap(HexCaretCallbackContext.capture(store: store,
            bytes: store.patchedHexWindow().bytes, mappings: store.hexWindowMappings))
        let target = ImageAddress(slot: slotB, address: entry + 2)
        XCTAssertTrue(context.publish(offset: 2, target: target, to: store))
        XCTAssertEqual(store.selectedImageAddress, target)
        XCTAssertNil(store.selectedInstruction)
        XCTAssertEqual(EditorStatusBar.selectedAddressText(for: store), store.displayAddressString(target.address))
        XCTAssertFalse(context.publish(offset: 2, target: ImageAddress(slot: slotA, address: entry + 2), to: store))
        XCTAssertEqual(store.selectedImageAddress, target)
        store.focusImage(slotA)
        let selection = store.selectedImageAddress
        XCTAssertFalse(context.publish(offset: 2, target: target, to: store))
        XCTAssertEqual(store.focusedImageSlot, slotA)
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    @MainActor
    func testHexCaretRejectsReplacedOwnerAndChangedMappingWithoutRetargeting() throws {
        for replaceOwner in [true, false] {
            let store = focusedSiblingStore()
            let context = try XCTUnwrap(HexCaretCallbackContext.capture(store: store,
                bytes: store.patchedHexWindow().bytes, mappings: store.hexWindowMappings))
            let target = ImageAddress(slot: slotB, address: entry + 2)
            if replaceOwner {
                replaceBinary(in: slotB, store: store)
            } else {
                var snapshot = store.snapshot
                var replacement = try XCTUnwrap(snapshot.analysisBySlot[slotB])
                replacement.sections = [SectionSummary(id: UUID(), name: "__TEXT,__text",
                    address: entry + 0x1000, size: 16, fileOffset: 0, isExecutable: true)]
                snapshot.analysisBySlot[slotB] = replacement
                store.snapshot = snapshot
            }
            let selection = store.selectedImageAddress
            XCTAssertFalse(context.publish(offset: 2, target: target, to: store))
            XCTAssertEqual(store.selectedImageAddress, selection)
        }
    }

    @MainActor
    func testHexCaretRejectsOutOfWindowAndForgedMappedTarget() throws {
        let store = focusedSiblingStore()
        let context = try XCTUnwrap(HexCaretCallbackContext.capture(store: store,
            bytes: store.patchedHexWindow().bytes, mappings: store.hexWindowMappings))
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: entry + 4)))
        let selection = store.selectedImageAddress
        for offset in [-1, store.patchedHexWindow().bytes.count] {
            XCTAssertNil(context.target(at: offset))
            XCTAssertFalse(context.publish(offset: offset, target: ImageAddress(slot: slotB, address: entry), to: store))
        }
        XCTAssertFalse(context.publish(offset: 2, target: ImageAddress(slot: slotB, address: entry + 3), to: store))
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    @MainActor
    func testHexCaretRejectsWindowReplacementAndUnmappedCell() throws {
        let store = focusedSiblingStore()
        let context = try XCTUnwrap(HexCaretCallbackContext.capture(store: store,
            bytes: store.patchedHexWindow().bytes, mappings: store.hexWindowMappings))
        var snapshot = store.snapshot
        var replacement = try XCTUnwrap(snapshot.analysisBySlot[slotB])
        // MS-10: the hex window is cut from the full slice (`imageBytes`), so replacing the
        // window means replacing the slice; the legacy prefix follows it.
        replacement.imageBytes = Data(repeating: 0xbb, count: 8)
        replacement.hexBytes = Data(repeating: 0xbb, count: 8)
        snapshot.analysisBySlot[slotB] = replacement
        store.snapshot = snapshot
        let selection = store.selectedImageAddress
        XCTAssertFalse(context.publish(offset: 2, target: ImageAddress(slot: slotB, address: entry + 2), to: store))
        XCTAssertEqual(store.selectedImageAddress, selection)

        replacement.sections = [SectionSummary(id: UUID(), name: "__TEXT,__text",
            address: entry + 3, size: 5, fileOffset: 3, isExecutable: true)]
        snapshot.analysisBySlot[slotB] = replacement
        store.snapshot = snapshot
        let unmapped = try XCTUnwrap(HexCaretCallbackContext.capture(store: store,
            bytes: store.patchedHexWindow().bytes, mappings: store.hexWindowMappings))
        XCTAssertNil(unmapped.target(at: 2))
        XCTAssertFalse(unmapped.publish(offset: 2, target: ImageAddress(slot: slotB, address: entry + 2), to: store))
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    /// Capturing an immutable callback must retain one projection per mapping, not one target per
    /// byte. The million-byte payload deliberately dwarfs its single verified mapping; boundary
    /// resolution proves the compact representation remains behaviorally complete.
    @MainActor
    func testHexEditCallbackCaptureScalesWithMappingsRatherThanPayloadBytes() throws {
        let byteCount = 1_048_576
        let mapping = FileAddressMapping(
            fileOffset: 0,
            size: UInt64(byteCount),
            virtualAddress: entry,
            sectionName: "__TEXT,__text"
        )

        let context = try XCTUnwrap(HexEditCallbackContext.capture(
            imageSlot: slotB,
            ownerBinaryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBB10"),
            bytes: Data(repeating: 0xCC, count: byteCount),
            mappings: [mapping]
        ))

        XCTAssertEqual(context.captureProjectionVisitCount, 1)
        XCTAssertEqual(context.retainedAddressProjectionCount, 1)
        XCTAssertEqual(context.target(at: 0), ImageAddress(slot: slotB, address: entry))
        XCTAssertEqual(
            context.target(at: byteCount - 1),
            ImageAddress(slot: slotB, address: entry + UInt64(byteCount - 1))
        )
        XCTAssertNil(context.target(at: byteCount))
    }

    @MainActor
    func testResetGraphLayoutClearsQualifiedGraphSelection() throws {
        let store = focusedSiblingStore()
        let target = try XCTUnwrap(focusedModel(from: store).nodes.first?.selectionTarget)
        XCTAssertTrue(store.selectGraphNode(target))
        let graphGroup = Set([
            ImageAddress(slot: slotB, address: entry),
            ImageAddress(slot: slotB, address: secondBlock),
        ])
        XCTAssertTrue(store.setGraphNodeMultiSelection(graphGroup))
        XCTAssertEqual(store.selectedGraphElementID, target.id)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: entry))
        XCTAssertEqual(store.graphNodeMultiSelection, graphGroup)
        XCTAssertFalse(store.graphNodeMultiSelection.isEmpty)

        store.resetGraphLayoutSelection()

        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: entry))
        XCTAssertNil(store.selectedGraphElementID)
        XCTAssertTrue(store.graphNodeMultiSelection.isEmpty)
    }

    @MainActor
    func testSlotRemapMovesSelectionButInvalidatesCapturedGraphIdentity() throws {
        let store = focusedSiblingStore()
        let target = try XCTUnwrap(focusedModel(from: store).nodes.first?.selectionTarget)
        XCTAssertTrue(store.selectGraphNode(target))
        let graphGroup = Set([ImageAddress(slot: slotB, address: entry)])
        XCTAssertTrue(store.setGraphNodeMultiSelection(graphGroup))
        XCTAssertEqual(store.selectedGraphElementID, target.id)
        XCTAssertEqual(store.graphNodeMultiSelection, graphGroup)
        XCTAssertFalse(store.graphNodeMultiSelection.isEmpty)

        store.remapImageSlot(from: slotB, to: slotC)

        XCTAssertEqual(store.focusedImageSlot, slotC)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotC, address: entry))
        XCTAssertNil(store.selectedGraphElementID)
        XCTAssertTrue(store.graphNodeMultiSelection.isEmpty)
        XCTAssertFalse(store.selectGraphNode(target), "the pre-remap slot-B callback is permanently stale")
    }

    @MainActor
    func testRemovingFocusedImageClearsSelectionAndGraphIdentityWithoutPrimaryFallback() throws {
        let store = focusedSiblingStore()
        let target = try XCTUnwrap(focusedModel(from: store).nodes.first?.selectionTarget)
        XCTAssertTrue(store.selectGraphNode(target))
        let graphGroup = Set([ImageAddress(slot: slotB, address: entry)])
        XCTAssertTrue(store.setGraphNodeMultiSelection(graphGroup))
        XCTAssertEqual(store.selectedGraphElementID, target.id)
        XCTAssertEqual(store.graphNodeMultiSelection, graphGroup)
        XCTAssertFalse(store.graphNodeMultiSelection.isEmpty)
        var replacement = store.snapshot
        replacement.removeImage(in: slotB)

        store.snapshot = replacement

        XCTAssertEqual(store.focusedImageSlot, slotA)
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(store.selectedGraphElementID)
        XCTAssertTrue(store.graphNodeMultiSelection.isEmpty)
        XCTAssertFalse(store.selectGraphNode(target))
    }

    // MARK: - Fixtures

    @MainActor
    private func focusedSiblingStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            workspaceName: "Focused graph identity",
            snapshot: collisionSnapshot(),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)
        return store
    }

    @MainActor
    private func focusedModel(from store: WorkspaceStore) -> FocusedGraphModel {
        FocusedGraphBuilder.build(store.focusedGraphProjection, viewport: CGSize(width: 1_280, height: 800))
    }

    @MainActor
    private func replaceBinary(in slot: ImageSlot, store: WorkspaceStore) {
        var replacement = store.snapshot
        replacement.binaries = replacement.binaries.map { binary in
            guard binary.slot == slot else { return binary }
            return BinaryImage(
                id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCC10")!,
                name: binary.name,
                path: binary.path,
                kind: binary.kind,
                architecture: binary.architecture,
                originalPathBookmark: binary.originalPathBookmark,
                metadata: binary.metadata,
                selectedSliceIndex: binary.selectedSliceIndex,
                slot: binary.slot
            )
        }
        store.snapshot = replacement
    }

    private func collisionSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [image(slot: slotA, name: "A"), image(slot: slotB, name: "B")],
            analysisBySlot: [slotA: analysis(for: slotA), slotB: analysis(for: slotB)],
            addressOverrides: [
                ImageAddress(slot: slotA, address: entry): AddressOverride(
                    customName: "A_CUSTOM_SENTINEL",
                    tag: "A_TAG_SENTINEL",
                    colorTag: .red
                ),
                ImageAddress(slot: slotB, address: entry): AddressOverride(
                    customName: "B_CUSTOM_SENTINEL",
                    tag: "B_TAG_SENTINEL",
                    colorTag: .blue
                ),
            ]
        )
    }

    private func analysis(for slot: ImageSlot) -> ImageAnalysis {
        let isPrimary = slot == slotA
        let functionID = isPrimary ? functionAID : functionBID
        let firstBlockID = isPrimary ? firstBlockAID : firstBlockBID
        let secondBlockID = isPrimary ? secondBlockAID : secondBlockBID
        let cfgID = isPrimary ? cfgAID : cfgBID
        let xrefID = isPrimary ? xrefAID : xrefBID
        let sentinel = isPrimary ? "A" : "B"

        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(
            id: functionID,
            name: "\(sentinel)_PARSED_SENTINEL",
            startAddress: entry,
            endAddress: end,
            confidence: 1
        )]
        analysis.basicBlocks = [
            BasicBlockSummary(
                id: firstBlockID,
                functionID: functionID,
                startAddress: entry,
                endAddress: secondBlock,
                instructionCount: 2
            ),
            BasicBlockSummary(
                id: secondBlockID,
                functionID: functionID,
                startAddress: secondBlock,
                endAddress: end,
                instructionCount: 2
            ),
        ]
        analysis.instructions = [
            instruction(entry, comment: "\(sentinel)_ENTRY_SENTINEL"),
            instruction(entry + 4, comment: "\(sentinel)_STEP"),
            instruction(secondBlock, comment: "\(sentinel)_TARGET"),
            instruction(secondBlock + 4, comment: "\(sentinel)_RET"),
        ]
        analysis.controlFlowEdges = [ControlFlowEdge(
            id: cfgID,
            from: entry,
            to: secondBlock,
            kind: "branch"
        )]
        analysis.xrefs = [XRef(
            id: xrefID,
            from: secondBlock,
            to: entry,
            kind: XRefKind.call
        )]
        analysis.sections = [SectionSummary(
            id: UUID(),
            name: "__TEXT,__text",
            address: entry,
            size: 0x100,
            fileOffset: 0,
            isExecutable: true
        )]
        analysis.hexBytes = Data(repeating: isPrimary ? 0xAA : 0xBB, count: 16)
        analysis.imageBytes = analysis.hexBytes
        return analysis
    }

    private func remintedAnalysis(for slot: ImageSlot) -> ImageAnalysis {
        var result = analysis(for: slot)
        let remintedFunctionID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDD1")!
        result.functions = result.functions.map {
            FunctionSummary(
                id: remintedFunctionID,
                name: $0.name,
                startAddress: $0.startAddress,
                endAddress: $0.endAddress,
                confidence: $0.confidence
            )
        }
        result.basicBlocks = result.basicBlocks.enumerated().map { index, block in
            BasicBlockSummary(
                id: UUID(),
                functionID: remintedFunctionID,
                startAddress: block.startAddress,
                endAddress: block.endAddress,
                instructionCount: block.instructionCount
            )
        }
        result.controlFlowEdges = result.controlFlowEdges.map {
            ControlFlowEdge(id: UUID(), from: $0.from, to: $0.to, kind: $0.kind)
        }
        result.xrefs = result.xrefs.map {
            XRef(id: UUID(), from: $0.from, to: $0.to, kind: $0.kind)
        }
        return result
    }

    private func instruction(
        _ address: UInt64,
        bytes: String = "1f 20 03 d5",
        comment: String
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: bytes,
            mnemonic: "nop",
            operands: "",
            hasBreakpoint: false,
            comment: comment
        )
    }

    private func image(slot: ImageSlot, name: String) -> BinaryImage {
        BinaryImage(
            id: slot == slotA
                ? UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAA10")!
                : UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBB10")!,
            name: name,
            path: "/tmp/FocusedGraphIdentity-\(name)",
            kind: "Mach-O",
            architecture: "arm64",
            slot: slot
        )
    }
}
