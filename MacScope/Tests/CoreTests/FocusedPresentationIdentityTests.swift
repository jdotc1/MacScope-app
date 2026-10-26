import AppKit
import SwiftUI
import XCTest
@testable import MacScope

/// WS-17 E4 RED oracles for the visible and spoken identity of one focused selection.
///
/// The fixture deliberately gives primary image A and sibling image B the same virtual
/// addresses while making every presentation fact distinguishable. A test can therefore
/// pass only when instruction, string, function, source-line, override, row-state, inspector,
/// context, and accessibility consumers all preserve B's owner.
///
/// Compile-boundary note: at RED capture there is no single pure production aggregate for the
/// context bar, listing-selection summary, inspector header, or their multi-image accessibility
/// text. The available pure seams (`ProcedureInspectorReading`, `AddressDetailReading`,
/// `DisassemblyListingBuilder`, and exact-slot snapshot helpers) are exercised directly below.
/// The otherwise-private SwiftUI composition is exercised through its real AppKit accessibility
/// tree rather than reimplemented in this test. If a smaller pure test boundary becomes useful,
/// E4 may optionally extract a slot-qualified presentation/formatter input carrying
/// `ImageAddress`, optional decoded instruction, focused binary name/count, context function/name,
/// source location, row flags, and resolved comment/tag/operands. That aggregate is a testing seam,
/// not required architecture; either route must keep missing evidence nil instead of borrowing A.
final class FocusedPresentationIdentityTests: XCTestCase {
    private let slotA = ImageSlot.primary
    private let slotB = ImageSlot(rawValue: 1)
    private let slotWithoutAnalysis = ImageSlot(rawValue: 2)

    private let collidingAddress: UInt64 = 0x1_0000_1000
    private let bOnlyAddress: UInt64 = 0x1_0000_1100
    private let mappedUndecodedAddress: UInt64 = 0x1_0000_1200
    private let aCallXRefSourceAddress: UInt64 = 0x1_0000_1024
    private let aDataXRefSourceAddress: UInt64 = 0x1_0000_1028

    // MARK: - Pure production presentation inputs

    @MainActor
    func testBinExportCaptureRejectsChangedFocusAndSameSlotBinaryOwner() throws {
        let store = makeStore()
        store.focusImage(slotB)
        let capture = try XCTUnwrap(BinExportUICapture.capture(store: store))
        XCTAssertEqual(capture.binaryID, store.snapshot.binary(in: slotB)?.id)
        XCTAssertTrue(capture.isCurrent(store: store))
        store.focusImage(slotA)
        XCTAssertFalse(capture.isCurrent(store: store))
        store.focusImage(slotB)
        XCTAssertTrue(capture.isCurrent(store: store), "Unchanged same-document authority remains usable")
        var replacement = try XCTUnwrap(store.snapshot.binary(in: slotA))
        replacement.slot = slotB
        store.snapshot.binaries.removeAll { $0.slot == slotB }
        store.snapshot.binaries.append(replacement)
        store.focusImage(slotB)
        XCTAssertFalse(capture.isCurrent(store: store), "Slot reuse cannot authorize the prior binary")
    }

    @MainActor
    func testBinExportCaptureRejectsDocumentMutationAndOtherLogicalWorkspace() throws {
        let store = makeStore()
        store.focusImage(slotB)
        let capture = try XCTUnwrap(BinExportUICapture.capture(store: store))
        let other = makeStore()
        other.focusImage(slotB)
        XCTAssertFalse(capture.isCurrent(store: other))
        let otherDocument = WorkspaceStore(workspaceName: store.workspaceName,
            snapshot: store.snapshot, engine: AnalysisEngine(), autosaveScheduler: nil,
            documentID: UUID(), workspaceID: store.workspaceID)
        otherDocument.focusImage(slotB)
        XCTAssertFalse(capture.isCurrent(store: otherDocument), "Same workspace UUID cannot replace document authority")
        store.setCustomComment(collidingAddress, comment: "changed during export")
        XCTAssertFalse(capture.isCurrent(store: store))
        let refreshed = try XCTUnwrap(BinExportUICapture.capture(store: store))
        XCTAssertTrue(refreshed.isCurrent(store: store))
    }

    @MainActor
    func testPopulatedEditorExposesStoredInstructionLeafAndSelectionAction() throws {
        let store = makeStore()
        store.focusImage(slotB)
        let host = NSHostingView(rootView: EditorSurfaceView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 1_440, height: 1_000)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        // Inspect the physical bridge, not arbitrary SwiftUI AX labels: the regression
        // otherwise exhausts the host stack while synthesizing the populated row label.
        func instructionLeaves(in view: NSView) -> [DisassemblyRowAccessibilityElement] {
            if let leaf = view as? DisassemblyRowAccessibilityElement { return [leaf] }
            return view.subviews.flatMap { instructionLeaves(in: $0) }
        }
        let leaves = instructionLeaves(in: host)
        let leaf = try XCTUnwrap(leaves.first {
            $0.accessibilityLabel()?.contains("B_COLLIDING_MNEMONIC") == true
        }, "The real populated editor must publish its bounded instruction semantics.")
        XCTAssertFalse(leaf.accessibilityLabel()?.contains("A_COLLIDING_MNEMONIC") == true)
        XCTAssertEqual(leaf.accessibilityChildren()?.count, 0)
        XCTAssertGreaterThan(leaf.frame.width, 0)
        XCTAssertTrue(leaf.accessibilityPerformPress())
        XCTAssertEqual(store.selectedInstruction?.mnemonic, "B_COLLIDING_MNEMONIC")
        XCTAssertEqual(store.focusedImageSlot, slotB)
    }

    @MainActor
    func testCollidingInspectorInputsResolveOnlyFocusedB() throws {
        let store = makeStore()
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))

        let instruction = try XCTUnwrap(store.selectedInstruction)
        XCTAssertEqual(instruction.mnemonic, "B_COLLIDING_MNEMONIC")
        XCTAssertEqual(instruction.bytes, "bb bb bb bb")
        XCTAssertFalse(instruction.hasBreakpoint)

        store.selectedTool = .strings
        XCTAssertEqual(store.selectedStringLiteral?.value, "B_COLLIDING_STRING")

        let source = try XCTUnwrap(
            store.snapshot.sourceLine(at: collidingAddress, in: slotB)
        )
        XCTAssertEqual(source.file, "B_COLLIDING_SOURCE.c")
        XCTAssertEqual(source.line, 210)

        let analysis = try XCTUnwrap(store.focusedAnalysis)
        let procedure = ProcedureInspectorReading(
            functions: analysis.functions,
            basicBlocks: analysis.basicBlocks,
            callEdges: analysis.xrefs.map { (from: $0.from, to: $0.to, kind: $0.kind) },
            instructions: analysis.instructions,
            selectedAddress: collidingAddress,
            addressOverrides: store.snapshot.overrides(in: slotB)
        )
        XCTAssertEqual(procedure.function?.name, "BFunction")
        XCTAssertEqual(procedure.nameText, "B_CONTEXT_NAME")

        let detail = AddressDetailReading(
            address: collidingAddress,
            snapshot: store.snapshot,
            imageSlot: slotB
        )
        XCTAssertEqual(detail.section?.name, "__TEXT,__b_text")
        XCTAssertEqual(detail.nearestSymbolName, "B_CONTEXT_NAME")
        XCTAssertEqual(detail.appliedName, "B_CONTEXT_NAME")
        XCTAssertEqual(detail.appliedComment, "B_OVERRIDE_COMMENT")
        XCTAssertEqual(detail.appliedTag, "B_TAG")
        XCTAssertEqual(detail.referencesToCount, 1)
        XCTAssertEqual(detail.referencesFromCount, 0)

        let focusedReferences = store.snapshot.effectiveXRefs(
            to: collidingAddress,
            in: slotB
        )
        XCTAssertEqual(focusedReferences.map(\.from), [bOnlyAddress])
        XCTAssertEqual(focusedReferences.map(\.to), [collidingAddress])
        XCTAssertEqual(focusedReferences.map(\.kind), [XRefKind.string])

        let primaryReferences = store.snapshot.effectiveXRefs(
            to: collidingAddress,
            in: slotA
        )
        XCTAssertEqual(primaryReferences.count, 2)
        XCTAssertEqual(
            Set(primaryReferences.map(\.from)),
            Set([aCallXRefSourceAddress, aDataXRefSourceAddress])
        )
        XCTAssertEqual(Set(primaryReferences.map(\.kind)), Set([XRefKind.call, XRefKind.data]))

        let data = DataInspectorReading(
            bytes: analysis.hexBytes,
            baseAddress: analysis.instructions.first?.address,
            selectedAddress: collidingAddress
        )
        XCTAssertEqual(data.uint8, "187")

        let listing = DisassemblyListingBuilder.buildResolved(
            snapshot: store.snapshot,
            slot: slotB
        )
        let resolved = try XCTUnwrap(listing.resolved[collidingAddress])
        XCTAssertEqual(resolved.row.mnemonic, "B_COLLIDING_MNEMONIC")
        XCTAssertEqual(resolved.inlineComment, "B_OVERRIDE_COMMENT")
        XCTAssertEqual(resolved.tag, "B_TAG")
        XCTAssertTrue(resolved.isPatched)
        XCTAssertFalse(resolved.row.hasBreakpoint)
        XCTAssertFalse(resolved.isLiveProgramCounter)

        let visibleB = [
            instruction.mnemonic,
            instruction.bytes,
            source.file ?? "",
            procedure.nameText ?? "",
            detail.section?.name ?? "",
            detail.appliedComment ?? "",
            detail.appliedTag ?? "",
        ].joined(separator: " | ")
        assertNoPrimaryLeak(in: visibleB)
    }

    @MainActor
    func testQualifiedProgramCounterRejectsCollidingAOwnerAndAcceptsFocusedB() throws {
        let store = makeStore()
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))

        let primaryTarget = ImageAddress(slot: slotA, address: collidingAddress)
        store.updateLiveProgramCounterTarget(primaryTarget)

        XCTAssertEqual(store.liveProgramCounterTarget, primaryTarget)
        XCTAssertNil(store.liveProgramCounter)
        XCTAssertFalse(
            try XCTUnwrap(
                DisassemblyListingBuilder.buildResolved(
                    snapshot: store.snapshot,
                    liveProgramCounter: store.liveProgramCounter,
                    slot: slotB
                ).resolved[collidingAddress]
            ).isLiveProgramCounter
        )

        let focusedTarget = ImageAddress(slot: slotB, address: collidingAddress)
        store.updateLiveProgramCounterTarget(focusedTarget)

        XCTAssertEqual(store.liveProgramCounterTarget, focusedTarget)
        XCTAssertEqual(store.liveProgramCounter, collidingAddress)
        XCTAssertTrue(
            try XCTUnwrap(
                DisassemblyListingBuilder.buildResolved(
                    snapshot: store.snapshot,
                    liveProgramCounter: store.liveProgramCounter,
                    slot: slotB
                ).resolved[collidingAddress]
            ).isLiveProgramCounter
        )
    }

    @MainActor
    func testBOnlyInspectorAndSourceInputsRemainAvailableWithoutPrimaryEvidence() throws {
        let store = makeStore()
        XCTAssertNil(
            store.snapshot.analysis(in: slotA)?.instructions.first {
                $0.address == bOnlyAddress
            }
        )

        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: bOnlyAddress)))

        XCTAssertEqual(store.selectedInstruction?.mnemonic, "B_ONLY_MNEMONIC")
        XCTAssertEqual(
            store.snapshot.sourceLine(at: bOnlyAddress, in: slotB)?.file,
            "B_ONLY_SOURCE.c"
        )

        let detail = AddressDetailReading(
            address: bOnlyAddress,
            snapshot: store.snapshot,
            imageSlot: slotB
        )
        XCTAssertEqual(detail.section?.name, "__TEXT,__b_text")
        XCTAssertEqual(detail.nearestSymbolName, "B_CONTEXT_NAME")

        let listing = DisassemblyListingBuilder.buildResolved(
            snapshot: store.snapshot,
            slot: slotB
        )
        XCTAssertEqual(listing.resolved[bOnlyAddress]?.row.mnemonic, "B_ONLY_MNEMONIC")
        XCTAssertFalse((listing.resolved[collidingAddress]?.inlineComment ?? "").contains("A_"))
    }

    @MainActor
    func testMappedUndecodedBRetainsAddressButHasNoInstructionPresentation() {
        let store = makeStore()
        XCTAssertEqual(
            store.snapshot.analysis(in: slotA)?.instructions.first {
                $0.address == mappedUndecodedAddress
            }?.mnemonic,
            "A_MAPPED_COLLISION_MNEMONIC"
        )

        store.focusImage(slotB)
        XCTAssertTrue(
            store.selectAddress(ImageAddress(slot: slotB, address: mappedUndecodedAddress))
        )

        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: mappedUndecodedAddress)
        )
        XCTAssertNil(store.selectedInstruction)
        XCTAssertNil(store.selectedStringLiteral)
        XCTAssertNil(store.snapshot.sourceLine(at: mappedUndecodedAddress, in: slotB))

        let detail = AddressDetailReading(
            address: mappedUndecodedAddress,
            snapshot: store.snapshot,
            imageSlot: slotB
        )
        XCTAssertEqual(detail.section?.name, "__TEXT,__b_text")
        XCTAssertFalse(detail.rows.map(\.value).contains("A_MAPPED_COLLISION_MNEMONIC"))
    }

    func testSegmentInspectorReloadsDraftForSameNamedSectionInDifferentImageOwner() {
        let sectionName = "__TEXT,__text"
        let ownerA = SegmentInspectorOwner(
            imageSlot: slotA,
            binaryID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA0")!,
            originalSectionName: sectionName
        )
        let ownerB = SegmentInspectorOwner(
            imageSlot: slotB,
            binaryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB0")!,
            originalSectionName: sectionName
        )
        var identity = SegmentInspectorDraftIdentity()

        XCTAssertTrue(identity.needsReload(for: ownerA))
        identity.markLoaded(ownerA)
        XCTAssertFalse(identity.needsReload(for: ownerA))
        XCTAssertTrue(
            identity.needsReload(for: ownerB),
            "the original section name is not sufficient owner identity across Mach-O images"
        )
    }

    func testSegmentInspectorRejectsStaleDraftApplyAfterOwnerChanges() {
        let sectionName = "__TEXT,__text"
        let ownerA = SegmentInspectorOwner(
            imageSlot: slotA,
            binaryID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA0")!,
            originalSectionName: sectionName
        )
        let ownerB = SegmentInspectorOwner(
            imageSlot: slotB,
            binaryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB0")!,
            originalSectionName: sectionName
        )
        var identity = SegmentInspectorDraftIdentity()
        identity.markLoaded(ownerA)

        XCTAssertFalse(
            identity.permitsApply(capturedOwner: ownerA, currentOwner: ownerB),
            "an A-owned control delivered after B focus must abstain"
        )
        XCTAssertFalse(
            identity.permitsApply(capturedOwner: ownerB, currentOwner: ownerB),
            "B cannot apply until its own fields have replaced A's draft"
        )

        identity.markLoaded(ownerB)
        XCTAssertTrue(identity.permitsApply(capturedOwner: ownerB, currentOwner: ownerB))
    }

    func testDataMarkedEditorAccessibilityUsesDisplayedDirectiveNotDecodedCode() {
        var snapshot = makeSnapshot()
        let target = ImageAddress(slot: slotB, address: collidingAddress)
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.isData = true
        snapshot.addressOverrides[target] = override

        let text = FocusedPresentationAccessibility.editorSelection(
            snapshot: snapshot,
            target: target,
            liveProgramCounter: nil
        )

        XCTAssertTrue(text.contains(".long"), text)
        XCTAssertTrue(text.contains("0xbbbbbbbb"), text)
        XCTAssertFalse(text.contains("B_COLLIDING_MNEMONIC"), text)
        XCTAssertFalse(text.contains("B_OPERANDS"), text)
    }

    func testMappedUndecodedEditorAccessibilityPreservesAddressOwner() {
        let snapshot = makeSnapshot()
        let target = ImageAddress(slot: slotB, address: mappedUndecodedAddress)

        let text = FocusedPresentationAccessibility.editorSelection(
            snapshot: snapshot,
            target: target,
            liveProgramCounter: nil
        )

        XCTAssertEqual(
            text,
            "Image B, selected address \(mappedUndecodedAddress.hexAddress)"
        )
        XCTAssertFalse(text.contains("A_MAPPED_COLLISION_MNEMONIC"), text)
    }

    func testShapedDataEditorAccessibilityUsesDisplayedShapeDirective() {
        var snapshot = makeSnapshot()
        let target = ImageAddress(slot: slotB, address: collidingAddress)
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.dataShape = DataShapeOverride(
            kind: .array,
            elementType: "int32_t",
            elementCount: 4
        )
        snapshot.addressOverrides[target] = override

        let text = FocusedPresentationAccessibility.editorSelection(
            snapshot: snapshot,
            target: target,
            liveProgramCounter: nil
        )

        XCTAssertTrue(text.contains(".array"), text)
        XCTAssertTrue(text.contains("int32_t[4]"), text)
        XCTAssertFalse(text.contains("B_COLLIDING_MNEMONIC"), text)
        XCTAssertFalse(text.contains("B_OPERANDS"), text)
    }

    func testUndefinedEditorAccessibilityUsesDisplayedDirectiveExactly() {
        let snapshot = makeUndefinedSnapshot()
        let target = ImageAddress(slot: slotB, address: collidingAddress)

        let text = FocusedPresentationAccessibility.editorSelection(
            snapshot: snapshot,
            target: target,
            liveProgramCounter: nil
        )

        XCTAssertEqual(
            text,
            "Image B, \(collidingAddress.hexAddress), .byte, "
                + "0xbb, 0xcc, 0xdd  ; undefined, comment: B_OVERRIDE_COMMENT, "
                + "tag B_TAG, source B_COLLIDING_SOURCE.c:210"
        )
        XCTAssertFalse(text.contains("B_COLLIDING_MNEMONIC"), text)
        XCTAssertFalse(text.contains("B_OPERANDS"), text)
    }

    func testEditorAccessibilityRequiresProgramCounterOwnerMatch() {
        let snapshot = makeSnapshot()
        let target = ImageAddress(slot: slotB, address: collidingAddress)

        let collidingPrimaryPC = FocusedPresentationAccessibility.editorSelection(
            snapshot: snapshot,
            target: target,
            liveProgramCounter: ImageAddress(slot: slotA, address: collidingAddress)
        )
        let focusedPC = FocusedPresentationAccessibility.editorSelection(
            snapshot: snapshot,
            target: target,
            liveProgramCounter: ImageAddress(slot: slotB, address: collidingAddress)
        )

        XCTAssertFalse(collidingPrimaryPC.contains("current program counter"), collidingPrimaryPC)
        XCTAssertTrue(focusedPC.contains("current program counter"), focusedPC)
    }

    func testInspectorAccessibilityPresentationIsConciseAndHasNoDuplicateValue() {
        let snapshot = makeSnapshot()
        let target = ImageAddress(slot: slotB, address: collidingAddress)

        let presentation = FocusedPresentationAccessibility.inspector(
            snapshot: snapshot,
            focusedSlot: slotB,
            target: target
        )

        XCTAssertEqual(
            presentation.label,
            "Inspector, Image B, selected instruction \(collidingAddress.hexAddress)"
        )
        XCTAssertNil(presentation.value)
        XCTAssertFalse(presentation.label.contains("B_COLLIDING_MNEMONIC"))
        XCTAssertFalse(presentation.label.contains("bb bb bb bb"))
        XCTAssertFalse(presentation.label.contains("B_COLLIDING_STRING"))
        XCTAssertFalse(presentation.label.contains("B_COLLIDING_SOURCE.c"))
    }

    @MainActor
    func testMissingFocusedAnalysisProducesEmptyPresentationWithoutPrimaryFallback() throws {
        let store = makeStore()
        store.focusImage(slotWithoutAnalysis)

        XCTAssertEqual(store.focusedImageSlot, slotWithoutAnalysis)
        XCTAssertNil(store.focusedAnalysis)
        XCTAssertFalse(
            store.selectAddress(
                ImageAddress(slot: slotWithoutAnalysis, address: collidingAddress)
            )
        )
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(store.selectedInstruction)
        XCTAssertNil(store.selectedStringLiteral)
        XCTAssertNil(store.snapshot.sourceLine(at: collidingAddress, in: slotWithoutAnalysis))
        XCTAssertTrue(
            DisassemblyListingBuilder.buildResolved(
                snapshot: store.snapshot,
                slot: slotWithoutAnalysis
            ).rows.isEmpty
        )

        let detail = AddressDetailReading(
            address: collidingAddress,
            snapshot: store.snapshot,
            imageSlot: slotWithoutAnalysis
        )
        XCTAssertNil(detail.section)
        XCTAssertNil(detail.nearestSymbolName)
        XCTAssertEqual(detail.referencesToCount, 0)
        XCTAssertEqual(detail.referencesFromCount, 0)

        let presentation = FocusedPresentationAccessibility.inspector(
            snapshot: store.snapshot,
            focusedSlot: store.focusedImageSlot,
            target: store.selectedImageAddress
        )
        XCTAssertEqual(
            presentation.label,
            "Inspector, no selection, Image C without analysis"
        )

        let text = try focusedInspectorMountedPresentationText(store)
        XCTAssertTrue(text.contains("No selection"), text)
        assertNoPrimaryLeak(in: text)
    }

    // MARK: - Mounted presentation + production accessibility projection

    @MainActor
    func testCollidingEditorContextListingAndAccessibilityNameOnlyB() throws {
        let store = makeStore()
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))

        let text = try focusedEditorMountedPresentationText(store)
        XCTAssertTrue(text.contains("Image B"), text)
        XCTAssertTrue(text.contains("B_CONTEXT_NAME"), text)
        XCTAssertTrue(text.contains("B_COLLIDING_MNEMONIC"), text)
        XCTAssertTrue(text.contains("B_OVERRIDE_COMMENT"), text)
        XCTAssertTrue(text.contains("B_COLLIDING_SOURCE.c:210"), text)
        assertNoPrimaryLeak(in: text)

        let accessibility = FocusedPresentationAccessibility.editorSelection(
            snapshot: store.snapshot,
            target: store.selectedImageAddress,
            liveProgramCounter: store.liveProgramCounterTarget
        )
        XCTAssertTrue(accessibility.contains("tag B_TAG"), accessibility)
        XCTAssertTrue(accessibility.contains("patched"), accessibility)
        assertNoPrimaryLeak(in: accessibility)
    }

    @MainActor
    func testCollidingRowAccessibilityProjectsOnlyFocusedPatchBreakpointAndProgramCounter() throws {
        let patchedStore = makeStore(rowState: .focusedPatchedPrimaryBreakpoint)
        patchedStore.focusImage(slotB)
        XCTAssertTrue(
            patchedStore.selectAddress(ImageAddress(slot: slotB, address: collidingAddress))
        )

        patchedStore.updateLiveProgramCounterTarget(
            ImageAddress(slot: slotA, address: collidingAddress)
        )
        let primaryPCText = FocusedPresentationAccessibility.editorSelection(
            snapshot: patchedStore.snapshot,
            target: patchedStore.selectedImageAddress,
            liveProgramCounter: patchedStore.liveProgramCounterTarget
        )
        XCTAssertTrue(primaryPCText.contains("patched"), primaryPCText)
        XCTAssertFalse(primaryPCText.contains("breakpoint set"), primaryPCText)
        XCTAssertFalse(primaryPCText.contains("current program counter"), primaryPCText)
        assertNoPrimaryLeak(in: primaryPCText)

        patchedStore.updateLiveProgramCounterTarget(
            ImageAddress(slot: slotB, address: collidingAddress)
        )
        let focusedPCText = FocusedPresentationAccessibility.editorSelection(
            snapshot: patchedStore.snapshot,
            target: patchedStore.selectedImageAddress,
            liveProgramCounter: patchedStore.liveProgramCounterTarget
        )
        XCTAssertTrue(focusedPCText.contains("patched"), focusedPCText)
        XCTAssertFalse(focusedPCText.contains("breakpoint set"), focusedPCText)
        XCTAssertTrue(focusedPCText.contains("current program counter"), focusedPCText)
        assertNoPrimaryLeak(in: focusedPCText)

        let breakpointStore = makeStore(rowState: .focusedBreakpointPrimaryPatched)
        breakpointStore.focusImage(slotB)
        XCTAssertTrue(
            breakpointStore.selectAddress(ImageAddress(slot: slotB, address: collidingAddress))
        )

        let breakpointText = FocusedPresentationAccessibility.editorSelection(
            snapshot: breakpointStore.snapshot,
            target: breakpointStore.selectedImageAddress,
            liveProgramCounter: breakpointStore.liveProgramCounterTarget
        )
        XCTAssertTrue(breakpointText.contains("breakpoint set"), breakpointText)
        XCTAssertFalse(breakpointText.contains("patched"), breakpointText)
        XCTAssertFalse(breakpointText.contains("current program counter"), breakpointText)
        assertNoPrimaryLeak(in: breakpointText)
    }

    @MainActor
    func testBOnlyEditorAccessibilityIncludesBSourceAndNoPrimaryCollision() throws {
        let store = makeStore()
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: bOnlyAddress)))

        let text = try focusedEditorMountedPresentationText(store)
        XCTAssertTrue(text.contains("Image B"), text)
        XCTAssertTrue(text.contains("B_ONLY_MNEMONIC"), text)
        XCTAssertTrue(text.contains("B_ONLY_SOURCE.c:220"), text)
        assertNoPrimaryLeak(in: text)
    }

    @MainActor
    func testFocusedGraphAccessibilityNamesBOnEveryIdentityBearingSurface() throws {
        let store = makeGraphStore()
        let binaryName = try XCTUnwrap(
            store.snapshot.binary(in: store.focusedImageSlot)?.name
        )
        let layout = FocusedGraphBuilder.build(
            store.focusedGraphProjection,
            viewport: CGSize(width: 420, height: 220)
        )
        let node = try XCTUnwrap(layout.nodes.first { $0.startAddress == collidingAddress })
        let edge = try XCTUnwrap(layout.edges.first)
        let canvas = FocusedPresentationAccessibility.graphCanvasLabel(binaryName: binaryName)
        let overview = FocusedPresentationAccessibility.graphOverviewLabel(
            binaryName: binaryName,
            layout: layout,
            selectedAddress: store.selectedImageAddress,
            selectedGraphElementID: store.selectedGraphElementID
        )
        let minimap = FocusedPresentationAccessibility.graphMinimapLabel(binaryName: binaryName)
        let minimapValue = FocusedPresentationAccessibility.graphMinimapValue(
            binaryName: binaryName,
            visibleWidthPercent: 40
        )
        let overviewValue = FocusedPresentationAccessibility.graphOverviewValue(
            binaryName: binaryName,
            layout: layout
        )
        let nodeHelp = FocusedPresentationAccessibility.graphNodeHelp(
            binaryName: binaryName,
            node: node
        )
        let nodeLabel = FocusedPresentationAccessibility.graphNodeLabel(
            binaryName: binaryName,
            node: node
        )
        let edgeLabel = FocusedPresentationAccessibility.graphEdgeLabel(
            binaryName: binaryName,
            edge: edge
        )
        let groupTools = FocusedPresentationAccessibility.graphGroupToolsLabel(
            binaryName: binaryName
        )
        let groupSelection = FocusedPresentationAccessibility.graphGroupSelectionLabel(
            binaryName: binaryName,
            selectionCount: 2
        )
        let groupedValue = FocusedPresentationAccessibility.graphNodeValue(
            binaryName: binaryName,
            isMultiSelected: true
        )
        let groupAction = FocusedPresentationAccessibility.graphNodeGroupActionLabel(
            isMultiSelected: true
        )

        XCTAssertEqual(canvas, "Control-flow graph, Image B")
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphCanvasHint,
            "Use arrow keys to move between graph nodes. Command-click nodes to multi-select, "
                + "then apply a color. Select an edge label to inspect that connection."
        )
        XCTAssertEqual(
            overview,
            "Image B, \(collidingAddress.hexAddress) in B_CONTEXT_NAME Entry block"
        )
        XCTAssertEqual(minimap, "Graph minimap, Image B")
        XCTAssertEqual(minimapValue, "Showing 40 percent of the Image B graph width")
        XCTAssertEqual(overviewValue, "Image B graph, 1 functions, 2 nodes, 1 edges")
        XCTAssertEqual(
            nodeHelp,
            "Image B, Basic Block B_CONTEXT_NAME Entry block, "
                + "\(collidingAddress.hexAddress) - \(bOnlyAddress.hexAddress)"
        )
        XCTAssertEqual(
            nodeLabel,
            "Image B, basic block, B_CONTEXT_NAME Entry block, "
                + "\(collidingAddress.hexAddress) - \(bOnlyAddress.hexAddress), tag B_TAG"
        )
        XCTAssertEqual(
            edgeLabel,
            "Image B, branch, B_CONTEXT_NAME Entry block \(collidingAddress.hexAddress) "
                + "to B_CONTEXT_NAME Block 2 \(bOnlyAddress.hexAddress)"
        )
        XCTAssertEqual(groupTools, "Node group color tools, Image B")
        XCTAssertEqual(groupSelection, "2 nodes selected in Image B")
        XCTAssertEqual(groupedValue, "Grouped in Image B")
        XCTAssertEqual(groupAction, "Remove from color group")

        let allText = [
            canvas,
            overview,
            minimap,
            minimapValue,
            overviewValue,
            nodeHelp,
            nodeLabel,
            edgeLabel,
            groupTools,
            groupSelection,
            groupedValue,
            groupAction,
        ].joined(separator: "\n")
        assertNoPrimaryLeak(in: allText)
    }

    /// Owner qualification is a multi-image disambiguator, not a wording change for the original
    /// one-image graph. Every legacy graph surface keeps its concise pre-WS-17 presentation.
    @MainActor
    func testSingleImageGraphAccessibilityWordingRemainsCompatible() throws {
        let store = makeGraphStore()
        let layout = FocusedGraphBuilder.build(
            store.focusedGraphProjection,
            viewport: CGSize(width: 420, height: 220)
        )
        let node = try XCTUnwrap(layout.nodes.first { $0.startAddress == collidingAddress })
        let edge = try XCTUnwrap(layout.edges.first)

        XCTAssertEqual(
            FocusedPresentationAccessibility.graphCanvasLabel(binaryName: nil),
            "Control-flow graph"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphMinimapLabel(binaryName: nil),
            "Graph minimap"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphMinimapValue(
                binaryName: nil,
                visibleWidthPercent: 40
            ),
            "Showing 40 percent of the graph width"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphOverviewLabel(
                binaryName: nil,
                layout: layout,
                selectedAddress: store.selectedImageAddress,
                selectedGraphElementID: store.selectedGraphElementID
            ),
            "\(collidingAddress.hexAddress) in B_CONTEXT_NAME Entry block"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphOverviewValue(
                binaryName: nil,
                layout: layout
            ),
            "1 functions, 2 nodes, 1 edges"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphNodeHelp(binaryName: nil, node: node),
            "Basic Block B_CONTEXT_NAME Entry block, "
                + "\(collidingAddress.hexAddress) - \(bOnlyAddress.hexAddress)"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphNodeLabel(binaryName: nil, node: node),
            "basic block, B_CONTEXT_NAME Entry block, "
                + "\(collidingAddress.hexAddress) - \(bOnlyAddress.hexAddress), tag B_TAG"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphEdgeLabel(binaryName: nil, edge: edge),
            "branch, B_CONTEXT_NAME Entry block \(collidingAddress.hexAddress) "
                + "to B_CONTEXT_NAME Block 2 \(bOnlyAddress.hexAddress)"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphNodeValue(
                binaryName: nil,
                isMultiSelected: true
            ),
            "Grouped"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphGroupSelectionLabel(
                binaryName: nil,
                selectionCount: 2
            ),
            "2 nodes selected"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.graphGroupToolsLabel(binaryName: nil),
            "Node group color tools"
        )
    }

    @MainActor
    func testUndefinedEditorAndInspectorMountTheSameVisibleAndSpokenDirective() throws {
        let store = makeUndefinedStore()

        let editorText = try focusedEditorMountedPresentationText(store)
        XCTAssertTrue(editorText.contains("Image B"), editorText)
        XCTAssertTrue(editorText.contains(".byte"), editorText)
        XCTAssertTrue(editorText.contains("0xbb, 0xcc, 0xdd  ; undefined"), editorText)
        XCTAssertTrue(editorText.contains("B_OVERRIDE_COMMENT"), editorText)
        XCTAssertTrue(editorText.contains("B_COLLIDING_SOURCE.c:210"), editorText)
        XCTAssertFalse(editorText.contains("B_COLLIDING_MNEMONIC"), editorText)
        XCTAssertFalse(editorText.contains("B_OPERANDS"), editorText)

        let spoken = FocusedPresentationAccessibility.editorSelection(
            snapshot: store.snapshot,
            target: store.selectedImageAddress,
            liveProgramCounter: store.liveProgramCounterTarget
        )
        XCTAssertEqual(
            spoken,
            "Image B, \(collidingAddress.hexAddress), .byte, "
                + "0xbb, 0xcc, 0xdd  ; undefined, comment: B_OVERRIDE_COMMENT, "
                + "tag B_TAG, source B_COLLIDING_SOURCE.c:210"
        )

        let inspectorText = try focusedInspectorMountedPresentationText(store)
        XCTAssertTrue(inspectorText.contains(".byte"), inspectorText)
        XCTAssertTrue(inspectorText.contains("0xbb, 0xcc, 0xdd  ; undefined"), inspectorText)
        XCTAssertTrue(inspectorText.contains("Undefined"), inspectorText)
        XCTAssertFalse(inspectorText.contains("B_COLLIDING_MNEMONIC"), inspectorText)
        XCTAssertFalse(inspectorText.contains("B_OPERANDS"), inspectorText)
        assertNoPrimaryLeak(in: inspectorText)
    }

    @MainActor
    func testMappedUndecodedInspectorAccessibilityNamesAddressOwnerWithoutInventingInstruction() throws {
        let store = makeStore()
        store.focusImage(slotB)
        XCTAssertTrue(
            store.selectAddress(ImageAddress(slot: slotB, address: mappedUndecodedAddress))
        )

        let presentation = FocusedPresentationAccessibility.inspector(
            snapshot: store.snapshot,
            focusedSlot: store.focusedImageSlot,
            target: store.selectedImageAddress
        )
        XCTAssertEqual(
            presentation.label,
            "Inspector, Image B, selected address \(mappedUndecodedAddress.hexAddress)"
        )
        XCTAssertEqual(
            FocusedPresentationAccessibility.inspectorEmptySelectionDetail(
                hasSelectedAddress: true
            ),
            "Selected address has no decoded instruction. Address details remain available below."
        )

        let text = try focusedInspectorMountedPresentationText(store)
        XCTAssertTrue(text.contains(mappedUndecodedAddress.hexAddress), text)
        XCTAssertFalse(text.contains("Inspector, no selection"), text)
        XCTAssertFalse(text.contains("Select an instruction to inspect"), text)
        XCTAssertFalse(text.contains("A_MAPPED_COLLISION_MNEMONIC"), text)
        assertNoPrimaryLeak(in: text)
    }

    @MainActor
    func testCollidingInspectorAccessibilityNamesBInstructionStringSourceAndContext() throws {
        let store = makeStore()
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))

        let presentation = FocusedPresentationAccessibility.inspector(
            snapshot: store.snapshot,
            focusedSlot: store.focusedImageSlot,
            target: store.selectedImageAddress
        )
        XCTAssertEqual(
            presentation.label,
            "Inspector, Image B, selected instruction \(collidingAddress.hexAddress)"
        )

        let instructionText = try focusedInspectorMountedPresentationText(store)
        XCTAssertTrue(instructionText.contains("B_COLLIDING_MNEMONIC"), instructionText)
        XCTAssertTrue(instructionText.contains("bb bb bb bb"), instructionText)
        XCTAssertTrue(instructionText.contains("__TEXT,__b_text"), instructionText)
        XCTAssertTrue(instructionText.contains("B_OVERRIDE_COMMENT"), instructionText)
        XCTAssertTrue(instructionText.contains("B_COLLIDING_SOURCE.c:210"), instructionText)
        XCTAssertTrue(instructionText.contains("B_CONTEXT_NAME"), instructionText)
        assertNoPrimaryLeak(in: instructionText)

        store.selectedTool = .strings
        let stringText = try focusedInspectorMountedPresentationText(store)
        XCTAssertTrue(stringText.contains("B_COLLIDING_STRING"), stringText)
        assertNoPrimaryLeak(in: stringText)
    }

    @MainActor
    func testAnalysisInspectorShowsFocusedImageProvenanceWithoutPrimaryFallback() throws {
        let store = makeStore()
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))

        let reading = AnalysisProvenanceInspectorReading(
            fingerprint: store.focusedAnalysis?.analysisInputFingerprint
        )
        XCTAssertTrue(reading.isAvailable)
        XCTAssertEqual(
            reading.rows.map(\.label),
            ["Provenance", "Image bytes", "Fingerprint facets", "Instructions facet"]
        )
        XCTAssertEqual(reading.rows[0].value, "bbbbbbbbbbbb…bbbbbbbb")
        XCTAssertEqual(reading.rows[1].value, "cccccccccccc…cccccccc")
        XCTAssertEqual(reading.rows[3].value, "dddddddddddd…dddddddd · 2 items · 16 bytes")

        let text = try focusedInspectorMountedPresentationText(store)
        XCTAssertTrue(text.contains("bbbbbbbbbbbb…bbbbbbbb"), text)
        XCTAssertTrue(text.contains("cccccccccccc…cccccccc"), text)
        XCTAssertTrue(text.contains("dddddddddddd…dddddddd · 2 items · 16 bytes"), text)
        XCTAssertFalse(text.contains("aaaaaaaaaaaa…aaaaaaaa"), text)
        assertNoPrimaryLeak(in: text)
    }

    // MARK: - Compatibility

    @MainActor
    func testPrimaryNoSlotPresentationRemainsAAfterBFocus() throws {
        let store = makeStore()
        let primaryListingBefore = DisassemblyListingBuilder.buildResolved(
            snapshot: store.snapshot
        )

        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))

        XCTAssertEqual(store.snapshot.instructions.first?.mnemonic, "A_COLLIDING_MNEMONIC")
        XCTAssertEqual(store.snapshot.stringLiterals.first?.value, "A_COLLIDING_STRING")
        XCTAssertEqual(
            store.snapshot.sourceLine(at: collidingAddress)?.file,
            "A_COLLIDING_SOURCE.c"
        )
        XCTAssertEqual(
            store.snapshot.displayName(
                at: collidingAddress,
                default: try XCTUnwrap(store.snapshot.functions.first).name
            ),
            "A_CONTEXT_NAME"
        )
        XCTAssertEqual(
            AddressDetailReading(
                address: collidingAddress,
                snapshot: store.snapshot
            ).section?.name,
            "__TEXT,__a_text"
        )
        let primaryListingAfter = DisassemblyListingBuilder.buildResolved(snapshot: store.snapshot)
        XCTAssertEqual(primaryListingAfter.rows, primaryListingBefore.rows)
        XCTAssertEqual(primaryListingAfter.resolved, primaryListingBefore.resolved)

        XCTAssertEqual(
            AppAccessibilityText.inspectorLabel(
                selectionAddress: collidingAddress.hexAddress
            ),
            "Inspector, selected instruction \(collidingAddress.hexAddress)",
            "the concise single-image/default formatter wording remains compatible"
        )
    }

    // MARK: - Fixture

    @MainActor
    private func makeStore(
        rowState: CollisionRowState = .focusedPatchedPrimaryBreakpoint
    ) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "WS-17 focused presentation",
            snapshot: makeSnapshot(rowState: rowState),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    @MainActor
    private func makeGraphStore() -> WorkspaceStore {
        var snapshot = makeSnapshot()
        var analysis = snapshot.analysisBySlot[slotB]!
        let functionID = analysis.functions[0].id
        analysis.basicBlocks = [
            BasicBlockSummary(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB5")!,
                functionID: functionID,
                startAddress: collidingAddress,
                endAddress: bOnlyAddress,
                instructionCount: 1
            ),
            BasicBlockSummary(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB6")!,
                functionID: functionID,
                startAddress: bOnlyAddress,
                endAddress: mappedUndecodedAddress,
                instructionCount: 1
            ),
        ]
        analysis.controlFlowEdges = [ControlFlowEdge(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB7")!,
            from: collidingAddress,
            to: bOnlyAddress,
            kind: "branch"
        )]
        analysis.xrefs = []
        snapshot.analysisBySlot[slotB] = analysis

        let store = WorkspaceStore(
            workspaceName: "WS-17 focused graph presentation",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))
        XCTAssertTrue(store.setGraphNodeMultiSelection(Set([
            ImageAddress(slot: slotB, address: collidingAddress),
            ImageAddress(slot: slotB, address: bOnlyAddress),
        ])))
        return store
    }

    @MainActor
    private func makeUndefinedStore() -> WorkspaceStore {
        let store = WorkspaceStore(
            workspaceName: "WS-17 undefined presentation",
            snapshot: makeUndefinedSnapshot(),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))
        return store
    }

    private func makeUndefinedSnapshot() -> WorkspaceSnapshot {
        var snapshot = makeSnapshot()
        var analysis = snapshot.analysisBySlot[slotB]!
        analysis.instructions[0].bytes = "bb cc dd"
        snapshot.analysisBySlot[slotB] = analysis

        let target = ImageAddress(slot: slotB, address: collidingAddress)
        var override = snapshot.addressOverrides[target] ?? AddressOverride()
        override.isUndefined = true
        override.patch = nil
        snapshot.addressOverrides[target] = override
        return snapshot
    }

    private func makeSnapshot(
        rowState: CollisionRowState = .focusedPatchedPrimaryBreakpoint
    ) -> WorkspaceSnapshot {
        let binaryIDA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA0")!
        let binaryIDB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB0")!
        let functionA = FunctionSummary(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!,
            name: "AFunction",
            startAddress: collidingAddress,
            endAddress: mappedUndecodedAddress + 4,
            confidence: 0.91
        )
        let functionB = FunctionSummary(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1")!,
            name: "BFunction",
            startAddress: collidingAddress,
            endAddress: mappedUndecodedAddress + 4,
            confidence: 0.92
        )

        var analysisA = ImageAnalysis()
        analysisA.functions = [functionA]
        analysisA.instructions = [
            instruction(
                collidingAddress,
                bytes: "aa aa aa aa",
                mnemonic: "A_COLLIDING_MNEMONIC",
                operands: "A_OPERANDS",
                hasBreakpoint: rowState.primaryHasBreakpoint,
                comment: "A_DECODER_COMMENT"
            ),
            instruction(
                mappedUndecodedAddress,
                bytes: "ac ac ac ac",
                mnemonic: "A_MAPPED_COLLISION_MNEMONIC",
                operands: "A_MAPPED_OPERANDS",
                hasBreakpoint: true,
                comment: "A_MAPPED_COMMENT"
            ),
        ]
        analysisA.sections = [section(slotName: "a")]
        analysisA.stringLiterals = [stringLiteral(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2")!,
            value: "A_COLLIDING_STRING",
            address: collidingAddress
        )]
        analysisA.sourceLines = [
            sourceLine(collidingAddress, file: "A_COLLIDING_SOURCE.c", line: 110),
            sourceLine(bOnlyAddress, file: "A_B_ONLY_COLLISION_SOURCE.c", line: 120),
            sourceLine(mappedUndecodedAddress, file: "A_MAPPED_SOURCE.c", line: 130),
        ]
        analysisA.xrefs = [
            XRef(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA4")!,
                from: aCallXRefSourceAddress,
                to: collidingAddress,
                kind: XRefKind.call
            ),
            XRef(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA5")!,
                from: aDataXRefSourceAddress,
                to: collidingAddress,
                kind: XRefKind.data
            ),
        ]
        analysisA.hexBytes = Data(repeating: 0xAA, count: 0x400)
        analysisA.imageBytes = analysisA.hexBytes
        analysisA.analysisInputFingerprint = analysisFingerprint(
            slot: slotA,
            binaryID: binaryIDA,
            binaryName: "Image A",
            binaryPath: "/tmp/macscope-ws17-presentation-a",
            overallSHA256: String(repeating: "a", count: 64),
            imageBytesSHA256: String(repeating: "e", count: 64),
            facetSHA256: String(repeating: "f", count: 64),
            instructionCount: analysisA.instructions.count
        )

        var analysisB = ImageAnalysis()
        analysisB.functions = [functionB]
        analysisB.instructions = [
            instruction(
                collidingAddress,
                bytes: "bb bb bb bb",
                mnemonic: "B_COLLIDING_MNEMONIC",
                operands: "B_OPERANDS",
                hasBreakpoint: rowState.focusedHasBreakpoint,
                comment: "B_DECODER_COMMENT"
            ),
            instruction(
                bOnlyAddress,
                bytes: "be be be be",
                mnemonic: "B_ONLY_MNEMONIC",
                operands: "B_ONLY_OPERANDS",
                hasBreakpoint: false,
                comment: "B_ONLY_COMMENT"
            ),
        ]
        analysisB.sections = [section(slotName: "b")]
        analysisB.stringLiterals = [stringLiteral(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB2")!,
            value: "B_COLLIDING_STRING",
            address: collidingAddress
        )]
        analysisB.sourceLines = [
            sourceLine(collidingAddress, file: "B_COLLIDING_SOURCE.c", line: 210),
            sourceLine(bOnlyAddress, file: "B_ONLY_SOURCE.c", line: 220),
            SourceLineEntry(
                address: bOnlyAddress + 4,
                file: nil,
                line: 0,
                column: 0,
                endSequence: true
            ),
        ]
        analysisB.xrefs = [XRef(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB4")!,
            from: bOnlyAddress,
            to: collidingAddress,
            kind: XRefKind.string
        )]
        analysisB.hexBytes = Data(repeating: 0xBB, count: 0x400)
        analysisB.imageBytes = analysisB.hexBytes
        analysisB.analysisInputFingerprint = analysisFingerprint(
            slot: slotB,
            binaryID: binaryIDB,
            binaryName: "Image B",
            binaryPath: "/tmp/macscope-ws17-presentation-b",
            overallSHA256: String(repeating: "b", count: 64),
            imageBytesSHA256: String(repeating: "c", count: 64),
            facetSHA256: String(repeating: "d", count: 64),
            instructionCount: analysisB.instructions.count
        )

        return WorkspaceSnapshot(
            binaries: [
                image(
                    slot: slotA,
                    id: binaryIDA,
                    name: "Image A",
                    path: "/tmp/macscope-ws17-presentation-a",
                    binaryUUID: "AAAAAAAA-0000-0000-0000-000000000000"
                ),
                image(
                    slot: slotB,
                    id: binaryIDB,
                    name: "Image B",
                    path: "/tmp/macscope-ws17-presentation-b",
                    binaryUUID: "BBBBBBBB-0000-0000-0000-000000000000"
                ),
                image(
                    slot: slotWithoutAnalysis,
                    id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCC0")!,
                    name: "Image C without analysis",
                    path: "/tmp/macscope-ws17-presentation-c",
                    binaryUUID: "CCCCCCCC-0000-0000-0000-000000000000"
                ),
            ],
            analysisBySlot: [slotA: analysisA, slotB: analysisB],
            addressOverrides: [
                ImageAddress(slot: slotA, address: collidingAddress): AddressOverride(
                    customName: "A_CONTEXT_NAME",
                    customComment: "A_OVERRIDE_COMMENT",
                    tag: "A_TAG",
                    patch: rowState.primaryIsPatched
                        ? BytePatch(bytes: [0xAA, 0xAA, 0xAA, 0xAA])
                        : nil
                ),
                ImageAddress(slot: slotB, address: collidingAddress): AddressOverride(
                    customName: "B_CONTEXT_NAME",
                    customComment: "B_OVERRIDE_COMMENT",
                    tag: "B_TAG",
                    patch: rowState.focusedIsPatched
                        ? BytePatch(bytes: [0xBB, 0xBB, 0xBB, 0xBB])
                        : nil
                ),
            ]
        )
    }

    private func analysisFingerprint(
        slot: ImageSlot,
        binaryID: UUID,
        binaryName: String,
        binaryPath: String,
        overallSHA256: String,
        imageBytesSHA256: String,
        facetSHA256: String,
        instructionCount: Int
    ) -> AnalysisInputFingerprint {
        let facet = try! AnalysisFacetFingerprint(
            kind: .decodedInstructions,
            itemCount: instructionCount,
            byteCount: UInt64(instructionCount * 8),
            sha256: facetSHA256
        )
        return try! AnalysisInputFingerprint(
            imageSlot: slot,
            binaryID: binaryID,
            binaryName: binaryName,
            binaryPath: binaryPath,
            selectedSliceIndex: nil,
            artifactIdentity: nil,
            imageByteCount: 0x400,
            imageBytesSHA256: imageBytesSHA256,
            facets: [facet],
            overallSHA256: overallSHA256
        )
    }

    private func instruction(
        _ address: UInt64,
        bytes: String,
        mnemonic: String,
        operands: String,
        hasBreakpoint: Bool,
        comment: String
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: bytes,
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: hasBreakpoint,
            comment: comment
        )
    }

    private func section(slotName: String) -> SectionSummary {
        SectionSummary(
            id: slotName == "a"
                ? UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA3")!
                : UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB3")!,
            name: "__TEXT,__\(slotName)_text",
            address: collidingAddress,
            size: 0x400,
            fileOffset: 0,
            isExecutable: true
        )
    }

    private func stringLiteral(
        id: UUID,
        value: String,
        address: UInt64
    ) -> StringLiteralSummary {
        StringLiteralSummary(
            id: id,
            value: value,
            address: address,
            sourceSection: "__TEXT,__cstring",
            byteLength: value.utf8.count + 1
        )
    }

    private func sourceLine(
        _ address: UInt64,
        file: String,
        line: Int
    ) -> SourceLineEntry {
        SourceLineEntry(
            address: address,
            file: file,
            line: line,
            column: 1,
            endSequence: false
        )
    }

    private func image(
        slot: ImageSlot,
        id: UUID,
        name: String,
        path: String,
        binaryUUID: String
    ) -> BinaryImage {
        var result = BinaryImage(
            id: id,
            name: name,
            path: path,
            kind: "executable",
            architecture: "arm64",
            slot: slot
        )
        result.metadata.uuid = binaryUUID
        return result
    }

    // MARK: - Mounted physical presentation host

    /// Reads the mounted editor's physical AppKit backing tree. These assertions prove rendered
    /// production content, not logical accessibility exposure; exact spoken values are tested
    /// separately through the production projection consumed by the SwiftUI modifiers.
    @MainActor
    private func focusedEditorMountedPresentationText(
        _ store: WorkspaceStore
    ) throws -> String {
        try mountedPresentationText(EditorSurfaceView(store: store))
    }

    /// Reads the mounted inspector's physical AppKit backing tree. It intentionally does not append
    /// the pure inspector projection, which has independent exact-value tests above.
    @MainActor
    private func focusedInspectorMountedPresentationText(_ store: WorkspaceStore) throws -> String {
        try mountedPresentationText(InspectorView(store: store))
    }

    /// Returns labels and values discoverable across the mounted physical view hierarchy. Ignored
    /// or accessibility-hidden backing views may appear here, so this helper must never serve as a
    /// logical AX oracle. Production accessibility wording has a separate formatter-level oracle.
    @MainActor
    private func mountedPresentationText<Content: View>(
        _ rootView: Content,
        afterMount: @MainActor () -> Void = {}
    ) throws -> String {
        let frame = NSRect(x: 0, y: 0, width: 1_440, height: 1_000)
        let host = NSHostingView(rootView: rootView)
        host.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        afterMount()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Give SwiftUI one bounded main-run-loop turn to publish and lay out its backing AppKit
        // descendants before the mounted-view assertions inspect physically rendered content.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.10))
        defer {
            // Do not close the test host's last window: MacScope's normal app lifecycle may
            // terminate after the last window closes, which would make XCTest report a crash and
            // relaunch between otherwise independent accessibility assertions.
            window.orderOut(nil)
            window.contentView = nil
        }

        var fragments: [String] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ candidate: Any) {
            let object = candidate as AnyObject
            let identity = ObjectIdentifier(object)
            guard visited.insert(identity).inserted else { return }

            // AppKit descendants can implement standard AX getters without formally bridging to
            // Swift's NSAccessibilityProtocol existential. Query only this fixed getter allowlist
            // as a way to read physical backing content; ignored nodes remain intentionally visible
            // to this mounted-rendering check.
            if let accessible = candidate as? NSObject {
                let label: String? = accessibilityGetter(.label, from: accessible)
                let value: String? = accessibilityGetter(.value, from: accessible)
                if let label, !label.isEmpty {
                    fragments.append(label)
                }
                if let value, !value.isEmpty {
                    fragments.append(value)
                }
                for getter in AccessibilityGetter.childGetters {
                    let children: [Any] = accessibilityGetter(getter, from: accessible) ?? []
                    for child in children {
                        visit(child)
                    }
                }
            }

            // Hosting/AppKit subviews are not necessarily present in the logical accessibility
            // child list, so retain the physical view-tree walk as a separate integration check.
            if let view = candidate as? NSView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }

        // The direct window/host visits are deliberate physical-tree roots, not simulations of an
        // assistive client. Unignored children are included only to cover detached proxy content.
        visit(window)
        visit(host)
        for child in NSAccessibility.unignoredChildren(from: [window, host]) {
            visit(child)
        }
        let text = fragments.joined(separator: "\n")
        if text.isEmpty {
            throw PresentationTestError.emptyAccessibilityTree
        }
        return text
    }

    /// Fixed, zero-argument Objective-C AX getters used by the mounted-view integration harness.
    /// Keeping the selector vocabulary closed avoids arbitrary runtime invocation while still
    /// supporting SwiftUI's private proxy classes on current macOS/Xcode toolchains.
    private enum AccessibilityGetter: String {
        case label = "accessibilityLabel"
        case value = "accessibilityValue"
        case children = "accessibilityChildren"
        case childrenInNavigationOrder = "accessibilityChildrenInNavigationOrder"
        case visibleChildren = "accessibilityVisibleChildren"
        case contents = "accessibilityContents"

        static let childGetters: [AccessibilityGetter] = [
            .children,
            .childrenInNavigationOrder,
            .visibleChildren,
            .contents,
        ]

        var selector: Selector { NSSelectorFromString(rawValue) }
    }

    @MainActor
    private func accessibilityGetter<Value>(
        _ getter: AccessibilityGetter,
        from object: NSObject
    ) -> Value? {
        let selector = getter.selector
        guard object.responds(to: selector),
              let result = object.perform(selector)?.takeUnretainedValue()
        else { return nil }
        return result as? Value
    }

    private func assertNoPrimaryLeak(
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for sentinel in [
            "Image A",
            "AFunction",
            "A_CONTEXT_NAME",
            "A_COLLIDING_MNEMONIC",
            "A_MAPPED_COLLISION_MNEMONIC",
            "aa aa aa aa",
            "ac ac ac ac",
            "AA AA AA AA",
            "AC AC AC AC",
            "A_OPERANDS",
            "A_MAPPED_OPERANDS",
            "A_OVERRIDE_COMMENT",
            "A_DECODER_COMMENT",
            "A_MAPPED_COMMENT",
            "A_TAG",
            "A_COLLIDING_SOURCE.c",
            "A_B_ONLY_COLLISION_SOURCE.c",
            "A_MAPPED_SOURCE.c",
            "A_COLLIDING_STRING",
            "__TEXT,__a_text",
            aCallXRefSourceAddress.hexAddress,
            aDataXRefSourceAddress.hexAddress,
            "call reference",
            "data reference",
        ] {
            XCTAssertFalse(
                text.contains(sentinel),
                "focused B presentation leaked primary sentinel \(sentinel):\n\(text)",
                file: file,
                line: line
            )
        }
    }
}

private enum PresentationTestError: Error {
    case emptyAccessibilityTree
}

private enum CollisionRowState: Equatable {
    case focusedPatchedPrimaryBreakpoint
    case focusedBreakpointPrimaryPatched

    var primaryHasBreakpoint: Bool {
        self == .focusedPatchedPrimaryBreakpoint
    }

    var focusedHasBreakpoint: Bool {
        self == .focusedBreakpointPrimaryPatched
    }

    var primaryIsPatched: Bool {
        self == .focusedBreakpointPrimaryPatched
    }

    var focusedIsPatched: Bool {
        self == .focusedPatchedPrimaryBreakpoint
    }
}
