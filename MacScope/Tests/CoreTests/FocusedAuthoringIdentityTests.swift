import XCTest
@testable import MacScope

/// WS-17 RED oracles for the complete selection-driven authoring closure.
///
/// Every control deliberately gives primary image A and sibling image B colliding virtual
/// addresses and distinct authored state. Address equality can therefore never explain a pass:
/// presentation, validation, commit, Undo, and Redo must retain one exact `ImageAddress` owner.
final class FocusedAuthoringIdentityTests: XCTestCase {
    private let slotA = ImageSlot.primary
    private let slotB = ImageSlot(rawValue: 1)
    private let slotWithoutAnalysis = ImageSlot(rawValue: 2)
    private let remappedSlotB = ImageSlot(rawValue: 7)

    private let baseAddress: UInt64 = 0x1_0000_1000
    private var aFunctionStart: UInt64 { baseAddress }
    private var bFunctionStart: UInt64 { baseAddress + 0x20 }
    private var collidingAddress: UInt64 { baseAddress + 0x40 }
    private var bOnlyAddress: UInt64 { baseAddress + 0x80 }
    private var mappedUndecodedAddress: UInt64 { baseAddress + 0xC0 }
    private var xrefTargetAddress: UInt64 { baseAddress + 0x100 }
    private var bMappedOnlyAddress: UInt64 { baseAddress + 0x300 }

    // MARK: - Text-backed authoring

    @MainActor
    func testTextEditorsSeedBAndCommitBOnlyAfterFocusSwitch() throws {
        try assertTextEditor(
            kind: .rename,
            selectedAddress: collidingAddress,
            targetAddress: bFunctionStart,
            initialValue: "B_CUSTOM_FUNCTION",
            committedValue: "B_RENAMED_AFTER_FOCUS",
            begin: { $0.beginRenameAtSelection() },
            value: { $0?.customName }
        )
        try assertTextEditor(
            kind: .comment,
            selectedAddress: collidingAddress,
            targetAddress: collidingAddress,
            initialValue: "B_CUSTOM_COMMENT",
            committedValue: "B_COMMENT_AFTER_FOCUS",
            begin: { $0.beginCommentEditAtSelection() },
            value: { $0?.customComment }
        )
        try assertTextEditor(
            kind: .tag,
            selectedAddress: collidingAddress,
            targetAddress: collidingAddress,
            initialValue: "B_TAG",
            committedValue: "B_TAG_AFTER_FOCUS",
            begin: { $0.beginTagEditAtSelection() },
            value: { $0?.tag }
        )
        try assertTextEditor(
            kind: .localLabel,
            selectedAddress: collidingAddress,
            targetAddress: collidingAddress,
            initialValue: "B_LOCAL_LABEL",
            committedValue: "B_LOCAL_AFTER_FOCUS",
            begin: { $0.beginLocalLabelEditAtSelection() },
            value: { $0?.localLabel }
        )
    }

    @MainActor
    func testSignatureEditorSeedsBAndCommitsBOnlyAfterFocusSwitch() throws {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        let before = store.snapshot.addressOverrides

        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)
        XCTAssertEqual(draft.imageSlot, slotB)
        XCTAssertEqual(draft.address, bFunctionStart)
        XCTAssertEqual(draft.functionName, "B_CUSTOM_FUNCTION")
        XCTAssertEqual(draft.returnType, "int32_t")
        XCTAssertEqual(draft.args.map(\.name), ["b_arg"])

        draft.returnType = "uint64_t"
        draft.parameterListIntent = .authoritative
        draft.args = [ArgDraft(index: 0, name: "focused_arg", type: "uint64_t")]
        store.focusImage(slotA)
        store.commitSignatureEditor(draft)

        let signature = store.snapshot.addressOverrides[bFunctionKey]?.signature
        XCTAssertEqual(signature?.returnType, "uint64_t")
        XCTAssertEqual(signature?.args.map(\.name), ["focused_arg"])
        XCTAssertEqual(store.snapshot.addressOverrides[aFunctionCollisionKey], before[aFunctionCollisionKey])

        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides, before)
    }

    @MainActor
    func testRegisterRenameSeedsBAndCommitsBOnlyAfterFocusSwitch() throws {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        let before = store.snapshot.addressOverrides

        store.beginRegisterRenameAtSelection(register: "x19")
        let request = try XCTUnwrap(store.registerRenameRequest)
        XCTAssertEqual(request.imageSlot, slotB)
        XCTAssertEqual(request.procedureStart, bFunctionStart)
        XCTAssertEqual(request.prefilledName(in: store.snapshot), "b_counter")

        store.focusImage(slotA)
        XCTAssertTrue(store.commitRegisterRename(request, register: "x19", name: "focused_counter"))
        XCTAssertEqual(
            store.snapshot.addressOverrides[bFunctionKey]?.registerNames?["x19"],
            "focused_counter"
        )
        XCTAssertEqual(store.snapshot.addressOverrides[aFunctionCollisionKey], before[aFunctionCollisionKey])

        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides, before)
    }

    @MainActor
    func testRegisterRenameRequestIdentityIncludesImageAndOpeningBinaryOwner() throws {
        let store = makeStore()
        select(collidingAddress, in: slotA, store: store)
        store.beginRegisterRenameAtSelection(register: "x19")
        let requestA = try XCTUnwrap(store.registerRenameRequest)

        store.registerRenameRequest = nil
        select(collidingAddress, in: slotB, store: store)
        store.beginRegisterRenameAtSelection(register: "x19")
        let requestB = try XCTUnwrap(store.registerRenameRequest)

        XCTAssertNotEqual(requestA.target, requestB.target)
        XCTAssertNotEqual(requestA.ownerBinaryID, requestB.ownerBinaryID)
        XCTAssertNotEqual(requestA.id, requestB.id)

        let replacementOwner = UUID()
        let sameTargetAfterReplacement = RegisterRenameRequest(
            imageSlot: requestB.imageSlot,
            procedureStart: requestB.procedureStart,
            register: requestB.register,
            ownerBinaryID: replacementOwner,
            presentationID: requestB.presentationID
        )
        XCTAssertEqual(requestB.target, sameTargetAfterReplacement.target)
        XCTAssertNotEqual(requestB.id, sameTargetAfterReplacement.id)

        let reopenedSameRequest = RegisterRenameRequest(
            imageSlot: requestB.imageSlot,
            procedureStart: requestB.procedureStart,
            register: requestB.register,
            ownerBinaryID: requestB.ownerBinaryID
        )
        XCTAssertEqual(requestB.target, reopenedSameRequest.target)
        XCTAssertEqual(requestB.ownerBinaryID, reopenedSameRequest.ownerBinaryID)
        XCTAssertNotEqual(requestB.id, reopenedSameRequest.id)
    }

    @MainActor
    func testRegisterRenameCancellationRejectsSameTokenWithTamperedOpeningOwner() throws {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        store.beginRegisterRenameAtSelection(register: "x19")
        let openingRequest = try XCTUnwrap(store.registerRenameRequest)

        let tamperedRequest = RegisterRenameRequest(
            imageSlot: slotA,
            procedureStart: aFunctionStart,
            register: openingRequest.register,
            ownerBinaryID: try binaryID(in: slotA, store: store),
            presentationID: openingRequest.presentationID
        )
        XCTAssertNotEqual(tamperedRequest.id, openingRequest.id)

        store.cancelRegisterRename(tamperedRequest)

        XCTAssertEqual(store.registerRenameRequest, openingRequest)
    }

    @MainActor
    func testFixedRegisterRenameRequestCannotRedirectToAnotherRegister() throws {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        store.beginRegisterRenameAtSelection(register: "x19")
        let request = try XCTUnwrap(store.registerRenameRequest)
        let before = store.snapshot.addressOverrides

        XCTAssertFalse(
            store.commitRegisterRename(
                request,
                register: "x20",
                name: "redirected_counter"
            )
        )

        XCTAssertEqual(store.snapshot.addressOverrides, before)
        XCTAssertEqual(store.registerRenameRequest, request)
        XCTAssertNotNil(store.lastIssue)
    }

    @MainActor
    func testEmptyRegisterRenameRequestAcceptsTypedRegister() throws {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        store.beginRegisterRenameAtSelection()
        let request = try XCTUnwrap(store.registerRenameRequest)
        XCTAssertTrue(request.register.isEmpty)

        XCTAssertTrue(
            store.commitRegisterRename(
                request,
                register: "x20",
                name: "typed_counter"
            )
        )

        XCTAssertNil(store.registerRenameRequest)
        XCTAssertEqual(
            store.snapshot.addressOverrides[bFunctionKey]?.registerNames?["x20"],
            "typed_counter"
        )
        XCTAssertEqual(
            store.snapshot.addressOverrides[bFunctionKey]?.registerNames?["x19"],
            "b_counter"
        )
    }

    @MainActor
    func testBOnlyEvidenceAuthorizesEverySheetBackedAuthoringFamily() throws {
        try assertTextEditor(
            kind: .rename,
            selectedAddress: bOnlyAddress,
            targetAddress: bFunctionStart,
            initialValue: "B_CUSTOM_FUNCTION",
            committedValue: "B_ONLY_RENAMED",
            begin: { $0.beginRenameAtSelection() },
            value: { $0?.customName }
        )
        try assertTextEditor(
            kind: .comment,
            selectedAddress: bOnlyAddress,
            targetAddress: bOnlyAddress,
            initialValue: "B_ONLY",
            committedValue: "B_ONLY_COMMENT",
            begin: { $0.beginCommentEditAtSelection() },
            value: { $0?.customComment }
        )
        try assertTextEditor(
            kind: .tag,
            selectedAddress: bOnlyAddress,
            targetAddress: bOnlyAddress,
            initialValue: "",
            committedValue: "B_ONLY_TAG",
            begin: { $0.beginTagEditAtSelection() },
            value: { $0?.tag }
        )
        try assertTextEditor(
            kind: .localLabel,
            selectedAddress: bMappedOnlyAddress,
            targetAddress: bMappedOnlyAddress,
            initialValue: "",
            committedValue: "B_ONLY_LOCAL_LABEL",
            begin: { $0.beginLocalLabelEditAtSelection() },
            value: { $0?.localLabel }
        )

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            store.beginSignatureEditAtSelection()
            let request = try XCTUnwrap(store.signatureEditorRequest)
            XCTAssertEqual(request.imageSlot, slotB)
            XCTAssertEqual(request.address, bFunctionStart)
            XCTAssertEqual(request.ownerBinaryID, try binaryID(in: slotB, store: store))
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            store.beginRegisterRenameAtSelection(register: "x19")
            let request = try XCTUnwrap(store.registerRenameRequest)
            XCTAssertEqual(request.imageSlot, slotB)
            XCTAssertEqual(request.procedureStart, bFunctionStart)
            XCTAssertEqual(request.prefilledName(in: store.snapshot), "b_counter")
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            store.beginSwitchHintEditAtSelection()
            let request = try XCTUnwrap(store.switchHintEditorRequest)
            XCTAssertEqual(request.imageSlot, slotB)
            XCTAssertEqual(request.address, bOnlyAddress)
            XCTAssertEqual(request.ownerBinaryID, try binaryID(in: slotB, store: store))
        }

        do {
            let store = makeStore()
            select(bMappedOnlyAddress, in: slotB, store: store)
            store.beginMakeDataAtSelection()
            let request = try XCTUnwrap(store.dataShapeEditorRequest)
            XCTAssertEqual(request.imageSlot, slotB)
            XCTAssertEqual(request.address, bMappedOnlyAddress)
            XCTAssertEqual(request.ownerBinaryID, try binaryID(in: slotB, store: store))
        }
    }

    // MARK: - Immediate address authoring

    @MainActor
    func testDirectInstructionAuthoringMutatesBOnlyAndUndoRetainsBIdentity() {
        assertDirectMutation("color") {
            $0.setColorTagAtSelection(.red)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.colorTag == .red
        }
        assertDirectMutation("operand format") {
            $0.setOperandFormatAtSelection(.binary)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.operandFormat == .binary
        }
        assertDirectMutation("applied type") {
            $0.applyTypeAtSelection(name: "FocusedType")
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.appliedTypeName == "FocusedType"
        }
        assertDirectMutation("mark as data") {
            $0.markSelectionAsData(true)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.isData == true
        }
        assertDirectMutation(
            "mark as code",
            prepare: { store, key in
                var value = store.snapshot.addressOverrides[key] ?? AddressOverride()
                value.isData = true
                store.snapshot.addressOverrides[key] = value
            },
            mutate: { $0.markSelectionAsData(false) },
            validate: { $0.store.snapshot.addressOverrides[$0.key]?.isData == false }
        )
        assertDirectMutation("mark as procedure") {
            $0.markSelectionAsProcedure(true)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.markAsProcedure == true
        }
        assertDirectMutation(
            "clear procedure mark",
            prepare: { store, key in
                var value = store.snapshot.addressOverrides[key] ?? AddressOverride()
                value.markAsProcedure = true
                store.snapshot.addressOverrides[key] = value
            },
            mutate: { $0.markSelectionAsProcedure(false) },
            validate: { $0.store.snapshot.addressOverrides[$0.key]?.markAsProcedure == false }
        )
        assertDirectMutation("mark as undefined") {
            $0.markSelectionAsUndefined(true)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.isUndefined == true
        }
        assertDirectMutation(
            "clear undefined mark",
            prepare: { store, key in
                var value = store.snapshot.addressOverrides[key] ?? AddressOverride()
                value.isUndefined = true
                store.snapshot.addressOverrides[key] = value
            },
            mutate: { $0.markSelectionAsUndefined(false) },
            validate: { $0.store.snapshot.addressOverrides[$0.key]?.isUndefined == false }
        )
    }

    @MainActor
    func testBookmarkAtSelectionMutatesBOnlyAndUndoRedoRetainBIdentity() {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        let before = store.snapshot.bookmarks

        store.addBookmarkAtSelection(name: "B_BOOKMARK_EDITED")
        XCTAssertEqual(bookmarkName(in: slotA, store: store), "A_BOOKMARK")
        XCTAssertEqual(bookmarkName(in: slotB, store: store), "B_BOOKMARK_EDITED")

        store.focusImage(slotA)
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.bookmarks, before)

        store.undoManager.redo()
        XCTAssertEqual(bookmarkName(in: slotA, store: store), "A_BOOKMARK")
        XCTAssertEqual(bookmarkName(in: slotB, store: store), "B_BOOKMARK_EDITED")
    }

    @MainActor
    func testBreakpointToggleMutatesBOnlyAndUndoRedoRetainBIdentity() {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        let aBefore = breakpoint(in: slotA, at: collidingAddress, store: store)
        let bBefore = breakpoint(in: slotB, at: collidingAddress, store: store)

        store.toggleBreakpointAtSelection()
        XCTAssertEqual(breakpoint(in: slotA, at: collidingAddress, store: store), aBefore)
        XCTAssertEqual(breakpoint(in: slotB, at: collidingAddress, store: store), !bBefore)

        store.focusImage(slotA)
        store.undoManager.undo()
        XCTAssertEqual(breakpoint(in: slotA, at: collidingAddress, store: store), aBefore)
        XCTAssertEqual(breakpoint(in: slotB, at: collidingAddress, store: store), bBefore)

        store.undoManager.redo()
        XCTAssertEqual(breakpoint(in: slotA, at: collidingAddress, store: store), aBefore)
        XCTAssertEqual(breakpoint(in: slotB, at: collidingAddress, store: store), !bBefore)
    }

    // MARK: - Structural requests and patching

    @MainActor
    func testSwitchAndMakeDataRequestsSeedBAndCommitBOnlyAfterFocusSwitch() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            let before = store.snapshot.addressOverrides

            store.beginSwitchHintEditAtSelection()
            var draft = try XCTUnwrap(store.switchHintEditorRequest)
            XCTAssertEqual(draft.imageSlot, slotB)
            XCTAssertEqual(WorkspaceStore.parseAddressText(draft.tableBaseText), xrefTargetAddress)
            XCTAssertEqual(draft.entryCountText, "3")
            XCTAssertEqual(draft.entryStrideText, "8")
            XCTAssertFalse(draft.isRelativeToBase)

            draft.entryCountText = "9"
            store.focusImage(slotA)
            store.commitSwitchHintEditor(draft)
            XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.switchHint?.entryCount, 9)
            XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey], before[collidingAKey])

            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.addressOverrides, before)
        }

        do {
            let store = makeStore()
            select(mappedUndecodedAddress, in: slotB, store: store)
            let before = store.snapshot.addressOverrides

            store.beginMakeDataAtSelection()
            var draft = try XCTUnwrap(store.dataShapeEditorRequest)
            XCTAssertEqual(draft.imageSlot, slotB)
            XCTAssertEqual(draft.address, mappedUndecodedAddress)
            XCTAssertEqual(draft.shape, .alignment)
            XCTAssertEqual(draft.boundaryText, "16")

            draft.boundaryText = "32"
            store.focusImage(slotA)
            XCTAssertTrue(store.commitDataShapeEditor(draft))
            XCTAssertEqual(store.snapshot.addressOverrides[mappedUndecodedBKey]?.dataShape?.alignment, 32)
            XCTAssertEqual(store.snapshot.addressOverrides[mappedUndecodedAKey], before[mappedUndecodedAKey])

            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.addressOverrides, before)
        }
    }

    @MainActor
    func testBOnlyInstructionEvidenceAuthorizesEveryDirectOverrideFamily() {
        assertBOnlyDirectMutation("color") {
            $0.setColorTagAtSelection(.red)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.colorTag == .red
        }
        assertBOnlyDirectMutation("operand format") {
            $0.setOperandFormatAtSelection(.binary)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.operandFormat == .binary
        }
        assertBOnlyDirectMutation("applied type") {
            $0.applyTypeAtSelection(name: "BOnlyType")
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.appliedTypeName == "BOnlyType"
        }
        assertBOnlyDirectMutation("mark as data") {
            $0.markSelectionAsData(true)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.isData == true
        }
        assertBOnlyDirectMutation(
            "mark as code",
            prepare: { store, key in
                var value = store.snapshot.addressOverrides[key] ?? AddressOverride()
                value.isData = true
                store.snapshot.addressOverrides[key] = value
            },
            mutate: { $0.markSelectionAsData(false) },
            validate: { ($0.store.snapshot.addressOverrides[$0.key]?.isData ?? false) == false }
        )
        assertBOnlyDirectMutation("mark as procedure") {
            $0.markSelectionAsProcedure(true)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.markAsProcedure == true
        }
        assertBOnlyDirectMutation("mark as undefined") {
            $0.markSelectionAsUndefined(true)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.isUndefined == true
        }
        assertBOnlyDirectMutation("replace with NOP") {
            $0.perform(.replaceWithNOP)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.patch == .arm64NOP
        }
    }

    @MainActor
    func testBOnlyBookmarkBreakpointClearPatchAndProcedureFamiliesRequireNoPrimaryProxy() throws {
        do {
            let store = makeStore()
            select(bMappedOnlyAddress, in: slotB, store: store)
            store.addBookmarkAtSelection(name: "B_ONLY_BOOKMARK")
            XCTAssertEqual(
                store.snapshot.bookmark(at: ImageAddress(slot: slotB, address: bMappedOnlyAddress))?.name,
                "B_ONLY_BOOKMARK"
            )
            XCTAssertNil(store.snapshot.bookmark(at: ImageAddress(slot: slotA, address: bMappedOnlyAddress)))
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            store.toggleBreakpointAtSelection()
            XCTAssertTrue(breakpoint(in: slotB, at: bOnlyAddress, store: store))
            XCTAssertFalse(breakpoint(in: slotA, at: bOnlyAddress, store: store))
        }

        do {
            let store = makeStore()
            var value = AddressOverride()
            value.patch = .arm64NOP
            store.snapshot.addressOverrides[bOnlyBKey] = value
            select(bOnlyAddress, in: slotB, store: store)
            XCTAssertTrue(store.isEnabled(.clearPatch))
            store.perform(.clearPatch)
            XCTAssertNil(store.snapshot.addressOverrides[bOnlyBKey]?.patch)
            XCTAssertNil(store.snapshot.addressOverrides[bOnlyAKey])
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            XCTAssertTrue(store.isEnabled(.topOfProcedure))
            store.perform(.topOfProcedure)
            XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: bFunctionStart))
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            let range = try XCTUnwrap(store.selectProcedureAtSelection())
            XCTAssertEqual(range.start, bFunctionStart)
            XCTAssertEqual(range.end, xrefTargetAddress + 4)
            XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: bFunctionStart))
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            let before = store.snapshot.addressOverrides
            store.truncateProcedureAtSelection()
            XCTAssertEqual(store.snapshot.addressOverrides[bOnlyBKey]?.markAsProcedure, true)
            XCTAssertEqual(store.snapshot.addressOverrides[bOnlyAKey], before[bOnlyAKey])
        }
    }

    @MainActor
    func testPatchAndAssemblyRequestsCaptureQualifiedOwnerAndCommitBOnlyAfterFocusSwitch() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            let before = store.snapshot.addressOverrides

            store.perform(.patchBytes)
            let request = try XCTUnwrap(store.pendingPatchBytesRequest)
            XCTAssertEqual(request.target, collidingBKey)
            XCTAssertEqual(request.ownerBinaryID, try binaryID(in: slotB, store: store))
            store.focusImage(slotA)
            XCTAssertTrue(store.patchBytes(request, hex: "11 22 33 44"))
            XCTAssertNil(store.pendingPatchBytesRequest)
            XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.patch?.bytes, [0x11, 0x22, 0x33, 0x44])
            XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey], before[collidingAKey])

            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.addressOverrides, before)
            store.undoManager.redo()
            XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.patch?.bytes, [0x11, 0x22, 0x33, 0x44])
            XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey], before[collidingAKey])
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            let before = store.snapshot.addressOverrides

            store.perform(.assembleInstruction)
            let request = try XCTUnwrap(store.pendingAssembleRequest)
            XCTAssertEqual(request.target, collidingBKey)
            XCTAssertEqual(request.ownerBinaryID, try binaryID(in: slotB, store: store))
            store.focusImage(slotA)
            XCTAssertTrue(store.assemble(request, text: "nop"))
            XCTAssertNil(store.pendingAssembleRequest)
            XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.patch, .arm64NOP)
            XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey], before[collidingAKey])

            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.addressOverrides, before)
            store.undoManager.redo()
            XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.patch, .arm64NOP)
            XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey], before[collidingAKey])
        }
    }

    @MainActor
    func testPatchAndAssemblyRequestsWithSameVAHaveDistinctImageAndBinaryIdentity() throws {
        let patchStore = makeStore()
        select(collidingAddress, in: slotA, store: patchStore)
        patchStore.perform(.patchBytes)
        let patchA = try XCTUnwrap(patchStore.pendingPatchBytesRequest)
        patchStore.pendingPatchBytesRequest = nil
        select(collidingAddress, in: slotB, store: patchStore)
        patchStore.perform(.patchBytes)
        let patchB = try XCTUnwrap(patchStore.pendingPatchBytesRequest)

        XCTAssertEqual(patchA.target.address, patchB.target.address)
        XCTAssertEqual(patchA.target, collidingAKey)
        XCTAssertEqual(patchB.target, collidingBKey)
        XCTAssertNotEqual(patchA.id, patchB.id)
        XCTAssertNotEqual(patchA.ownerBinaryID, patchB.ownerBinaryID)

        let reopenedPatchB = PatchBytesRequest(
            target: patchB.target,
            ownerBinaryID: patchB.ownerBinaryID
        )
        XCTAssertEqual(reopenedPatchB.target, patchB.target)
        XCTAssertEqual(reopenedPatchB.ownerBinaryID, patchB.ownerBinaryID)
        XCTAssertNotEqual(reopenedPatchB.id, patchB.id)

        let assembleStore = makeStore()
        select(collidingAddress, in: slotA, store: assembleStore)
        assembleStore.perform(.assembleInstruction)
        let assembleA = try XCTUnwrap(assembleStore.pendingAssembleRequest)
        assembleStore.pendingAssembleRequest = nil
        select(collidingAddress, in: slotB, store: assembleStore)
        assembleStore.perform(.assembleInstruction)
        let assembleB = try XCTUnwrap(assembleStore.pendingAssembleRequest)

        XCTAssertEqual(assembleA.target.address, assembleB.target.address)
        XCTAssertEqual(assembleA.target, collidingAKey)
        XCTAssertEqual(assembleB.target, collidingBKey)
        XCTAssertNotEqual(assembleA.id, assembleB.id)
        XCTAssertNotEqual(assembleA.ownerBinaryID, assembleB.ownerBinaryID)

        let reopenedAssembleB = AssembleRequest(
            target: assembleB.target,
            ownerBinaryID: assembleB.ownerBinaryID
        )
        XCTAssertEqual(reopenedAssembleB.target, assembleB.target)
        XCTAssertEqual(reopenedAssembleB.ownerBinaryID, assembleB.ownerBinaryID)
        XCTAssertNotEqual(reopenedAssembleB.id, assembleB.id)
    }

    @MainActor
    func testBOnlyPatchAndAssemblyRequestsNeedNoPrimaryInstruction() throws {
        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            store.perform(.patchBytes)
            let request = try XCTUnwrap(store.pendingPatchBytesRequest)
            XCTAssertEqual(request.target, bOnlyBKey)
            XCTAssertEqual(request.ownerBinaryID, try binaryID(in: slotB, store: store))
            XCTAssertTrue(store.patchBytes(request, hex: "11 22 33 44"))
            XCTAssertNil(store.pendingPatchBytesRequest)
            XCTAssertEqual(store.snapshot.addressOverrides[bOnlyBKey]?.patch?.bytes, [0x11, 0x22, 0x33, 0x44])
            XCTAssertNil(store.snapshot.addressOverrides[bOnlyAKey])
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            store.perform(.assembleInstruction)
            let request = try XCTUnwrap(store.pendingAssembleRequest)
            XCTAssertEqual(request.target, bOnlyBKey)
            XCTAssertEqual(request.ownerBinaryID, try binaryID(in: slotB, store: store))
            XCTAssertTrue(store.assemble(request, text: "nop"))
            XCTAssertNil(store.pendingAssembleRequest)
            XCTAssertEqual(store.snapshot.addressOverrides[bOnlyBKey]?.patch, .arm64NOP)
            XCTAssertNil(store.snapshot.addressOverrides[bOnlyAKey])
        }
    }

    @MainActor
    func testInvalidPatchAndAssemblyInputPreservesExactPendingRequestAndAllState() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.perform(.patchBytes)
            let request = try XCTUnwrap(store.pendingPatchBytesRequest)
            let before = guardedAuthoringState(store)

            XCTAssertFalse(store.patchBytes(request, hex: "not hex"))

            XCTAssertEqual(store.pendingPatchBytesRequest, request)
            XCTAssertEqual(guardedAuthoringState(store), before)
            XCTAssertEqual(
                store.lastIssue,
                "Invalid hex bytes — enter an even number of hex digits (e.g. 1f 20 03 d5)."
            )
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.perform(.assembleInstruction)
            let request = try XCTUnwrap(store.pendingAssembleRequest)
            let before = guardedAuthoringState(store)

            XCTAssertFalse(store.assemble(request, text: "not-an-instruction"))

            XCTAssertEqual(store.pendingAssembleRequest, request)
            XCTAssertEqual(guardedAuthoringState(store), before)
            XCTAssertTrue(store.lastIssue?.hasPrefix("Couldn’t assemble:") == true)
        }
    }

    @MainActor
    func testReplaceWithNOPAndClearPatchUseFocusedOwner() {
        assertDirectMutation("replace with NOP") {
            $0.perform(.replaceWithNOP)
        } validate: {
            $0.store.snapshot.addressOverrides[$0.key]?.patch == .arm64NOP
        }

        do {
            let store = makeStore()
            var aOverride = store.snapshot.addressOverrides[collidingAKey] ?? AddressOverride()
            aOverride.patch = nil
            store.snapshot.addressOverrides[collidingAKey] = aOverride
            select(collidingAddress, in: slotB, store: store)
            let before = store.snapshot.addressOverrides

            XCTAssertTrue(store.isEnabled(.clearPatch), "B's patch authorizes Clear Patch even when A has none")
            store.perform(.clearPatch)
            XCTAssertNil(store.snapshot.addressOverrides[collidingBKey]?.patch)
            XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey], before[collidingAKey])

            store.focusImage(slotA)
            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.addressOverrides, before)
        }

        do {
            let store = makeStore()
            var bOverride = store.snapshot.addressOverrides[collidingBKey] ?? AddressOverride()
            bOverride.patch = nil
            store.snapshot.addressOverrides[collidingBKey] = bOverride
            select(collidingAddress, in: slotB, store: store)
            let before = store.snapshot.addressOverrides

            XCTAssertFalse(store.isEnabled(.clearPatch), "A's colliding patch must not authorize Clear Patch in B")
            store.perform(.clearPatch)
            XCTAssertEqual(store.snapshot.addressOverrides, before)
        }
    }

    // MARK: - Mapped but undecoded boundary

    @MainActor
    func testMappedUndecodedAddressAllowsAddressOnlyAuthoringInB() throws {
        do {
            let store = makeStore()
            select(mappedUndecodedAddress, in: slotB, store: store)
            XCTAssertNil(store.selectedInstruction)
            let before = store.snapshot.addressOverrides

            store.beginLocalLabelEditAtSelection()
            let request = try XCTUnwrap(store.overrideEditorRequest)
            XCTAssertEqual(request.imageSlot, slotB)
            XCTAssertEqual(request.initialValue, "B_MAPPED_LABEL")
            store.focusImage(slotA)
            store.commitOverrideEditor(request, text: "B_MAPPED_LABEL_EDITED")

            XCTAssertEqual(store.snapshot.addressOverrides[mappedUndecodedBKey]?.localLabel, "B_MAPPED_LABEL_EDITED")
            XCTAssertEqual(store.snapshot.addressOverrides[mappedUndecodedAKey], before[mappedUndecodedAKey])
            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.addressOverrides, before)
        }

        do {
            let store = makeStore()
            select(mappedUndecodedAddress, in: slotB, store: store)
            let before = store.snapshot.bookmarks
            store.addBookmarkAtSelection(name: "B_MAPPED_BOOKMARK")

            XCTAssertNil(store.snapshot.bookmark(at: mappedUndecodedAKey))
            XCTAssertEqual(store.snapshot.bookmark(at: mappedUndecodedBKey)?.name, "B_MAPPED_BOOKMARK")
            store.focusImage(slotA)
            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.bookmarks, before)
        }
    }

    @MainActor
    func testMappedUndecodedAddressDeniesEveryInstructionOnlyAuthoringFamily() {
        assertMappedUndecodedInstructionMutationDenied("comment") { $0.beginCommentEditAtSelection() }
        assertMappedUndecodedInstructionMutationDenied("tag") { $0.beginTagEditAtSelection() }
        assertMappedUndecodedInstructionMutationDenied("color") { $0.setColorTagAtSelection(.red) }
        assertMappedUndecodedInstructionMutationDenied("operand format") { $0.setOperandFormatAtSelection(.binary) }
        assertMappedUndecodedInstructionMutationDenied("type") { $0.applyTypeAtSelection(name: "FocusedType") }
        assertMappedUndecodedInstructionMutationDenied("mark data") { $0.markSelectionAsData(true) }
        assertMappedUndecodedInstructionMutationDenied("mark procedure") { $0.markSelectionAsProcedure(true) }
        assertMappedUndecodedInstructionMutationDenied("mark undefined") { $0.markSelectionAsUndefined(true) }
        assertMappedUndecodedInstructionMutationDenied("switch hint") { $0.beginSwitchHintEditAtSelection() }
        assertMappedUndecodedInstructionMutationDenied("breakpoint") { $0.toggleBreakpointAtSelection() }
        assertMappedUndecodedInstructionMutationDenied("patch bytes") { $0.perform(.patchBytes) }
        assertMappedUndecodedInstructionMutationDenied("assemble") { $0.perform(.assembleInstruction) }
        assertMappedUndecodedInstructionMutationDenied("replace with NOP") { $0.perform(.replaceWithNOP) }
    }

    @MainActor
    func testLoadedImageWithoutAnalysisAbstainsAcrossEveryFrozenAuthoringFamily() {
        assertLoadedWithoutAnalysisAbstains("rename") { $0.beginRenameAtSelection() }
        assertLoadedWithoutAnalysisAbstains("signature") { $0.beginSignatureEditAtSelection() }
        assertLoadedWithoutAnalysisAbstains("comment") { $0.beginCommentEditAtSelection() }
        assertLoadedWithoutAnalysisAbstains("tag") { $0.beginTagEditAtSelection() }
        assertLoadedWithoutAnalysisAbstains("local label") { $0.beginLocalLabelEditAtSelection() }
        assertLoadedWithoutAnalysisAbstains("register rename") { $0.beginRegisterRenameAtSelection(register: "x19") }
        assertLoadedWithoutAnalysisAbstains("switch hint") { $0.beginSwitchHintEditAtSelection() }
        assertLoadedWithoutAnalysisAbstains("Make Data") { $0.beginMakeDataAtSelection() }
        assertLoadedWithoutAnalysisAbstains("color") { $0.setColorTagAtSelection(.red) }
        assertLoadedWithoutAnalysisAbstains("operand format") { $0.setOperandFormatAtSelection(.binary) }
        assertLoadedWithoutAnalysisAbstains("applied type") { $0.applyTypeAtSelection(name: "NoAnalysisType") }
        assertLoadedWithoutAnalysisAbstains("mark data") { $0.markSelectionAsData(true) }
        assertLoadedWithoutAnalysisAbstains("mark code") { $0.markSelectionAsData(false) }
        assertLoadedWithoutAnalysisAbstains("mark procedure") { $0.markSelectionAsProcedure(true) }
        assertLoadedWithoutAnalysisAbstains("mark undefined") { $0.markSelectionAsUndefined(true) }
        assertLoadedWithoutAnalysisAbstains("bookmark") { $0.addBookmarkAtSelection(name: "NO_ANALYSIS") }
        assertLoadedWithoutAnalysisAbstains("breakpoint") { $0.toggleBreakpointAtSelection() }
        assertLoadedWithoutAnalysisAbstains("patch bytes") { $0.perform(.patchBytes) }
        assertLoadedWithoutAnalysisAbstains("assembly") { $0.perform(.assembleInstruction) }
        assertLoadedWithoutAnalysisAbstains("replace with NOP") { $0.perform(.replaceWithNOP) }
        assertLoadedWithoutAnalysisAbstains("clear patch") { $0.perform(.clearPatch) }
        assertLoadedWithoutAnalysisAbstains("top of procedure") { $0.perform(.topOfProcedure) }
        assertLoadedWithoutAnalysisAbstains("select procedure") { _ = $0.selectProcedureAtSelection() }
        assertLoadedWithoutAnalysisAbstains("truncate procedure") { $0.truncateProcedureAtSelection() }
    }

    // MARK: - Procedure operations

    @MainActor
    func testTopSelectAndTruncateProcedureResolveFocusedBFunction() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            XCTAssertTrue(store.isEnabled(.topOfProcedure))
            store.perform(.topOfProcedure)
            XCTAssertEqual(store.selectedAddress, bFunctionStart)
            XCTAssertEqual(store.selectedInstruction?.comment, "B_FUNCTION_START")
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            let range = try XCTUnwrap(store.selectProcedureAtSelection())
            XCTAssertEqual(range.start, bFunctionStart)
            XCTAssertEqual(range.end, xrefTargetAddress + 4)
            XCTAssertEqual(store.selectedAddress, bFunctionStart)
        }

        do {
            let store = makeStore()
            select(bOnlyAddress, in: slotB, store: store)
            let before = store.snapshot.addressOverrides
            store.truncateProcedureAtSelection()

            XCTAssertEqual(store.snapshot.addressOverrides[bOnlyBKey]?.markAsProcedure, true)
            XCTAssertEqual(store.snapshot.addressOverrides[bOnlyAKey], before[bOnlyAKey])
            store.focusImage(slotA)
            store.undoManager.undo()
            XCTAssertEqual(store.snapshot.addressOverrides, before)
        }
    }

    // MARK: - Delayed request invalidation

    @MainActor
    func testRemovedAndRemappedOwnersRejectEveryDelayedRequestWithoutSecondaryEffects() throws {
        for invalidation in OwnerInvalidation.allCases {
            for family in DelayedRequestFamily.allCases {
                try assertInvalidatedOwnerRejects(family, invalidation: invalidation)
            }
        }
    }

    @MainActor
    func testReplacedOldCallbackIsRejectedForEveryDelayedRequestFamily() throws {
        for family in DelayedRequestFamily.allCases {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            let oldCallback = try delayedCommit(for: family, in: store, file: #filePath, line: #line)

            select(collidingAddress, in: slotA, store: store)
            let currentRequest = try delayedCommit(for: family, in: store, file: #filePath, line: #line)
            store.lastIssue = nil
            let beforeOldCallback = guardedAuthoringState(store)

            oldCallback.commit()

            XCTAssertEqual(
                guardedAuthoringState(store),
                beforeOldCallback,
                "replaced callback: \(family.rawValue)"
            )
            XCTAssertEqual(
                store.lastIssue,
                family.expectedStaleIssue,
                "replaced callback: \(family.rawValue)"
            )
            currentRequest.assertRequestPreserved()
        }
    }

    @MainActor
    func testSameSlotBinaryReplacementRejectsEveryDelayedRequestFamily() throws {
        for family in DelayedRequestFamily.allCases {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            let staleCallback = try delayedCommit(for: family, in: store, file: #filePath, line: #line)

            let ownerIndex = try XCTUnwrap(store.snapshot.binaries.firstIndex { $0.slot == slotB })
            let oldOwner = store.snapshot.binaries[ownerIndex]
            store.snapshot.binaries[ownerIndex] = BinaryImage(
                id: UUID(),
                name: oldOwner.name,
                path: oldOwner.path,
                kind: oldOwner.kind,
                architecture: oldOwner.architecture,
                originalPathBookmark: oldOwner.originalPathBookmark,
                metadata: oldOwner.metadata,
                selectedSliceIndex: oldOwner.selectedSliceIndex,
                slot: oldOwner.slot
            )

            store.lastIssue = nil
            let beforeCommit = guardedAuthoringState(store)
            staleCallback.commit()

            let label = "same-slot binary replacement: \(family.rawValue)"
            XCTAssertEqual(guardedAuthoringState(store), beforeCommit, label)
            XCTAssertEqual(store.lastIssue, family.expectedStaleIssue, label)
            staleCallback.assertRequestPreserved()
        }
    }

    @MainActor
    func testRemapAwayAndBackCannotResurrectAnyDelayedRequestFamily() throws {
        for family in DelayedRequestFamily.allCases {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            let staleCallback = try delayedCommit(
                for: family,
                in: store,
                file: #filePath,
                line: #line
            )

            store.remapImageSlot(from: slotB, to: remappedSlotB)
            store.remapImageSlot(from: remappedSlotB, to: slotB)
            XCTAssertNotNil(store.snapshot.binary(in: slotB))
            XCTAssertNil(store.snapshot.binary(in: remappedSlotB))

            store.lastIssue = nil
            let beforeCommit = guardedAuthoringState(store)
            staleCallback.commit()

            let label = "remap-away/remap-back: \(family.rawValue)"
            XCTAssertEqual(guardedAuthoringState(store), beforeCommit, label)
            XCTAssertEqual(store.lastIssue, family.expectedStaleIssue, label)
            staleCallback.assertRequestPreserved()
        }
    }

    @MainActor
    func testSignatureDraftCannotRebindOpeningOwnerForSaveOrClear() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSignatureEditAtSelection()
            let openingRequest = try XCTUnwrap(store.signatureEditorRequest)
            var tamperedDraft = openingRequest
            tamperedDraft.imageSlot = slotA
            tamperedDraft.address = aFunctionStart
            tamperedDraft.ownerBinaryID = try binaryID(in: slotA, store: store)
            tamperedDraft.returnType = "tampered_result_t"

            store.lastIssue = nil
            let before = store.snapshot.addressOverrides
            store.commitSignatureEditor(tamperedDraft)

            XCTAssertEqual(store.snapshot.addressOverrides, before)
            XCTAssertEqual(store.signatureEditorRequest, openingRequest)
            XCTAssertNotNil(store.lastIssue)
        }

        do {
            let store = makeStore()
            let aKey = ImageAddress(slot: slotA, address: aFunctionStart)
            store.snapshot.addressOverrides[aKey] = AddressOverride(
                signature: FunctionSignatureOverride(
                    returnType: "a_preserved_t",
                    args: [ArgOverride(index: 0, name: "a_preserved", type: "uint64_t")]
                )
            )
            select(collidingAddress, in: slotB, store: store)
            store.beginSignatureEditAtSelection()
            let openingRequest = try XCTUnwrap(store.signatureEditorRequest)
            var tamperedDraft = openingRequest
            tamperedDraft.imageSlot = slotA
            tamperedDraft.address = aFunctionStart
            tamperedDraft.ownerBinaryID = try binaryID(in: slotA, store: store)

            store.lastIssue = nil
            let before = store.snapshot.addressOverrides
            store.clearSignatureEditorOverride(tamperedDraft)

            XCTAssertEqual(store.snapshot.addressOverrides, before)
            XCTAssertEqual(store.signatureEditorRequest, openingRequest)
            XCTAssertNotNil(store.lastIssue)
        }
    }

    @MainActor
    func testSwitchDraftCannotRebindOpeningOwnerForSaveOrRemove() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSwitchHintEditAtSelection()
            let openingRequest = try XCTUnwrap(store.switchHintEditorRequest)
            var tamperedDraft = openingRequest
            tamperedDraft.imageSlot = slotA
            tamperedDraft.address = collidingAddress
            tamperedDraft.ownerBinaryID = try binaryID(in: slotA, store: store)
            tamperedDraft.tableBaseText = "0x" + String(aFunctionStart, radix: 16)
            tamperedDraft.entryCountText = "11"

            store.lastIssue = nil
            let before = store.snapshot.addressOverrides
            store.commitSwitchHintEditor(tamperedDraft)

            XCTAssertEqual(store.snapshot.addressOverrides, before)
            XCTAssertEqual(store.switchHintEditorRequest, openingRequest)
            XCTAssertNotNil(store.lastIssue)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSwitchHintEditAtSelection()
            let openingRequest = try XCTUnwrap(store.switchHintEditorRequest)
            var tamperedRequest = openingRequest
            tamperedRequest.imageSlot = slotA
            tamperedRequest.address = collidingAddress
            tamperedRequest.ownerBinaryID = try binaryID(in: slotA, store: store)

            store.lastIssue = nil
            let before = store.snapshot.addressOverrides
            XCTAssertFalse(store.removeSwitchHint(tamperedRequest))

            XCTAssertEqual(store.snapshot.addressOverrides, before)
            XCTAssertEqual(store.switchHintEditorRequest, openingRequest)
            XCTAssertNotNil(store.lastIssue)
        }
    }

    @MainActor
    func testMakeDataDraftCannotRebindOpeningOwner() throws {
        let store = makeStore()
        select(mappedUndecodedAddress, in: slotB, store: store)
        store.beginMakeDataAtSelection()
        let openingRequest = try XCTUnwrap(store.dataShapeEditorRequest)
        var tamperedDraft = openingRequest
        tamperedDraft.imageSlot = slotA
        tamperedDraft.address = mappedUndecodedAddress
        tamperedDraft.ownerBinaryID = try binaryID(in: slotA, store: store)
        tamperedDraft.shape = .array
        tamperedDraft.elementType = "tampered_element_t"
        tamperedDraft.countText = "13"

        store.lastIssue = nil
        let before = store.snapshot.addressOverrides
        XCTAssertFalse(store.commitDataShapeEditor(tamperedDraft))

        XCTAssertEqual(store.snapshot.addressOverrides, before)
        XCTAssertEqual(store.dataShapeEditorRequest, openingRequest)
        XCTAssertNotNil(store.lastIssue)
    }

    @MainActor
    func testOldCancellationCannotDismissReplacementRequestsWithStoreCancellationAPIs() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginCommentEditAtSelection()
            let oldRequest = try XCTUnwrap(store.overrideEditorRequest)
            let oldCancellation: @MainActor () -> Void = {
                store.cancelOverrideEditor(oldRequest)
            }

            select(collidingAddress, in: slotA, store: store)
            store.beginCommentEditAtSelection()
            let replacement = try XCTUnwrap(store.overrideEditorRequest)
            oldCancellation()
            XCTAssertEqual(store.overrideEditorRequest, replacement)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSignatureEditAtSelection()
            let oldRequest = try XCTUnwrap(store.signatureEditorRequest)
            let oldCancellation: @MainActor () -> Void = {
                store.cancelSignatureEditor(oldRequest)
            }

            select(collidingAddress, in: slotA, store: store)
            store.beginSignatureEditAtSelection()
            let replacement = try XCTUnwrap(store.signatureEditorRequest)
            oldCancellation()
            XCTAssertEqual(store.signatureEditorRequest, replacement)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginRegisterRenameAtSelection(register: "x19")
            let oldRequest = try XCTUnwrap(store.registerRenameRequest)
            let oldCancellation: @MainActor () -> Void = {
                store.cancelRegisterRename(oldRequest)
            }

            select(collidingAddress, in: slotA, store: store)
            store.beginRegisterRenameAtSelection(register: "x19")
            let replacement = try XCTUnwrap(store.registerRenameRequest)
            oldCancellation()
            XCTAssertEqual(store.registerRenameRequest, replacement)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSwitchHintEditAtSelection()
            let oldRequest = try XCTUnwrap(store.switchHintEditorRequest)
            let oldCancellation: @MainActor () -> Void = {
                store.cancelSwitchHintEditor(oldRequest)
            }

            select(collidingAddress, in: slotA, store: store)
            store.beginSwitchHintEditAtSelection()
            let replacement = try XCTUnwrap(store.switchHintEditorRequest)
            oldCancellation()
            XCTAssertEqual(store.switchHintEditorRequest, replacement)
        }

        do {
            let store = makeStore()
            select(mappedUndecodedAddress, in: slotB, store: store)
            store.beginMakeDataAtSelection()
            let oldRequest = try XCTUnwrap(store.dataShapeEditorRequest)
            let oldCancellation: @MainActor () -> Void = {
                store.cancelDataShapeEditor(oldRequest)
            }

            select(mappedUndecodedAddress, in: slotA, store: store)
            store.beginMakeDataAtSelection()
            let replacement = try XCTUnwrap(store.dataShapeEditorRequest)
            oldCancellation()
            XCTAssertEqual(store.dataShapeEditorRequest, replacement)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.perform(.patchBytes)
            let oldRequest = try XCTUnwrap(store.pendingPatchBytesRequest)
            let oldCancellation: @MainActor () -> Void = {
                store.cancelPatchBytes(oldRequest)
            }

            select(collidingAddress, in: slotA, store: store)
            store.perform(.patchBytes)
            let replacement = try XCTUnwrap(store.pendingPatchBytesRequest)
            oldCancellation()
            XCTAssertEqual(store.pendingPatchBytesRequest, replacement)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.perform(.assembleInstruction)
            let oldRequest = try XCTUnwrap(store.pendingAssembleRequest)
            let oldCancellation: @MainActor () -> Void = {
                store.cancelAssemble(oldRequest)
            }

            select(collidingAddress, in: slotA, store: store)
            store.perform(.assembleInstruction)
            let replacement = try XCTUnwrap(store.pendingAssembleRequest)
            oldCancellation()
            XCTAssertEqual(store.pendingAssembleRequest, replacement)
        }
    }

    @MainActor
    func testTokenlessPatchAndAssembleCallbacksCannotCommitReplacementAtCollidingVA() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.perform(.patchBytes)
            let oldRequest = try XCTUnwrap(store.pendingPatchBytesRequest)
            let staleCommit: @MainActor () -> Bool = {
                store.patchBytes(oldRequest.address, hex: "de ad be ef")
            }

            select(collidingAddress, in: slotA, store: store)
            store.perform(.patchBytes)
            let replacement = try XCTUnwrap(store.pendingPatchBytesRequest)
            let before = store.snapshot.addressOverrides

            XCTAssertFalse(staleCommit())
            XCTAssertEqual(store.pendingPatchBytesRequest, replacement)
            XCTAssertEqual(store.snapshot.addressOverrides, before)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.perform(.assembleInstruction)
            let oldRequest = try XCTUnwrap(store.pendingAssembleRequest)
            let staleCommit: @MainActor () -> Bool = {
                store.assemble(at: oldRequest.address, text: "nop")
            }

            select(collidingAddress, in: slotA, store: store)
            store.perform(.assembleInstruction)
            let replacement = try XCTUnwrap(store.pendingAssembleRequest)
            let before = store.snapshot.addressOverrides

            XCTAssertFalse(staleCommit())
            XCTAssertEqual(store.pendingAssembleRequest, replacement)
            XCTAssertEqual(store.snapshot.addressOverrides, before)
        }
    }

    @MainActor
    func testMalformedNonemptySwitchTextPreservesHintAndDraft() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSwitchHintEditAtSelection()
            let openingRequest = try XCTUnwrap(store.switchHintEditorRequest)
            var malformedDraft = openingRequest
            malformedDraft.tableBaseText = "0xNOT_HEX"

            store.lastIssue = nil
            let before = store.snapshot.addressOverrides
            store.commitSwitchHintEditor(malformedDraft)

            XCTAssertEqual(store.snapshot.addressOverrides, before)
            XCTAssertEqual(store.switchHintEditorRequest, openingRequest)
            XCTAssertNotNil(store.lastIssue)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSwitchHintEditAtSelection()
            let openingRequest = try XCTUnwrap(store.switchHintEditorRequest)
            var malformedDraft = openingRequest
            malformedDraft.entryCountText = "not-a-count"

            store.lastIssue = nil
            let before = store.snapshot.addressOverrides
            store.commitSwitchHintEditor(malformedDraft)

            XCTAssertEqual(store.snapshot.addressOverrides, before)
            XCTAssertEqual(store.switchHintEditorRequest, openingRequest)
            XCTAssertNotNil(store.lastIssue)
        }
    }

    @MainActor
    func testCorrectedOrRemovedSwitchHintClearsPriorValidationIssue() throws {
        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSwitchHintEditAtSelection()
            let openingRequest = try XCTUnwrap(store.switchHintEditorRequest)
            var malformedDraft = openingRequest
            malformedDraft.tableBaseText = "0xNOT_HEX"

            store.commitSwitchHintEditor(malformedDraft)
            XCTAssertNotNil(store.lastIssue)

            var correctedDraft = openingRequest
            correctedDraft.tableBaseText = "0x" + String(xrefTargetAddress, radix: 16)
            correctedDraft.entryCountText = "5"
            correctedDraft.entryStrideText = "4"
            store.commitSwitchHintEditor(correctedDraft)

            XCTAssertNil(store.switchHintEditorRequest)
            XCTAssertNil(store.lastIssue)
            XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.switchHint?.entryCount, 5)
        }

        do {
            let store = makeStore()
            select(collidingAddress, in: slotB, store: store)
            store.beginSwitchHintEditAtSelection()
            let openingRequest = try XCTUnwrap(store.switchHintEditorRequest)
            var malformedDraft = openingRequest
            malformedDraft.entryCountText = "not-a-count"

            store.commitSwitchHintEditor(malformedDraft)
            XCTAssertNotNil(store.lastIssue)
            XCTAssertTrue(store.removeSwitchHint(openingRequest))

            XCTAssertNil(store.switchHintEditorRequest)
            XCTAssertNil(store.lastIssue)
            XCTAssertNil(store.snapshot.addressOverrides[collidingBKey]?.switchHint)
        }
    }

    @MainActor
    func testCorrectedRegisterRenameClearsPriorValidationIssue() throws {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        store.beginRegisterRenameAtSelection()
        let request = try XCTUnwrap(store.registerRenameRequest)

        XCTAssertFalse(store.commitRegisterRename(request, register: "   ", name: "counter"))
        XCTAssertNotNil(store.lastIssue)
        XCTAssertEqual(store.registerRenameRequest, request)

        XCTAssertTrue(store.commitRegisterRename(request, register: "x20", name: "counter"))

        XCTAssertNil(store.registerRenameRequest)
        XCTAssertNil(store.lastIssue)
        XCTAssertEqual(
            store.snapshot.addressOverrides[bFunctionKey]?.registerNames?["x20"],
            "counter"
        )
    }

    @MainActor
    func testCorrectedMakeDataClearsPriorValidationIssue() throws {
        let store = makeStore()
        store.focusImage(slotB)
        store.selectedAddress = mappedUndecodedAddress
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: mappedUndecodedAddress)
        )
        store.beginMakeDataAtSelection()
        let request = try XCTUnwrap(store.dataShapeEditorRequest)

        var invalidDraft = request
        invalidDraft.shape = .array
        invalidDraft.countText = "0"
        XCTAssertFalse(store.commitDataShapeEditor(invalidDraft))
        XCTAssertNotNil(store.lastIssue)
        XCTAssertEqual(store.dataShapeEditorRequest, request)

        var correctedDraft = request
        correctedDraft.shape = .array
        correctedDraft.elementType = "uint32_t"
        correctedDraft.countText = "3"
        XCTAssertTrue(store.commitDataShapeEditor(correctedDraft))

        XCTAssertNil(store.dataShapeEditorRequest)
        XCTAssertNil(store.lastIssue)
        XCTAssertEqual(
            store.snapshot.addressOverrides[mappedUndecodedBKey]?.dataShape,
            DataShapeOverride(kind: .array, elementType: "uint32_t", elementCount: 3)
        )
    }

    @MainActor
    func testCanceledBinarylessMakeDataRequestCannotLateCommit() throws {
        let store = makeBinarylessStore()
        store.selectedAddress = collidingAddress
        XCTAssertEqual(store.selectedImageAddress, .primary(collidingAddress))
        store.beginMakeDataAtSelection()
        var staleDraft = try XCTUnwrap(store.dataShapeEditorRequest)
        staleDraft.shape = .array
        staleDraft.elementType = "uint16_t"
        staleDraft.countText = "4"

        store.cancelDataShapeEditor(staleDraft)
        XCTAssertNil(store.dataShapeEditorRequest)
        let before = store.snapshot.addressOverrides

        XCTAssertFalse(store.commitDataShapeEditor(staleDraft))

        XCTAssertEqual(store.snapshot.addressOverrides, before)
        XCTAssertNil(store.dataShapeEditorRequest)
        XCTAssertNotNil(store.lastIssue)
    }

    @MainActor
    func testUndoAfterSlotRemapCannotRecreateOldSlotAuthoring() {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        store.setColorTagAtSelection(.green)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.colorTag, .green)
        XCTAssertTrue(store.undoManager.canUndo)

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedKey = ImageAddress(slot: remappedSlotB, address: collidingAddress)
        XCTAssertNil(store.snapshot.binary(in: slotB))
        XCTAssertNotNil(store.snapshot.binary(in: remappedSlotB))
        XCTAssertEqual(store.snapshot.addressOverrides[remappedKey]?.colorTag, .green)
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertFalse(store.undoManager.canRedo)

        store.undoManager.undo()
        store.undoManager.redo()

        XCTAssertNil(store.snapshot.binary(in: slotB))
        XCTAssertTrue(overrides(in: slotB, store: store).isEmpty)
        XCTAssertEqual(store.snapshot.addressOverrides[remappedKey]?.colorTag, .green)
        XCTAssertTrue(store.snapshot.bookmarks.allSatisfy { $0.imageSlot != slotB })
    }

    @MainActor
    func testRedoAfterSlotRemapCannotReplayVacatedSlotAuthoring() {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        store.setColorTagAtSelection(.green)
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.colorTag, .blue)
        XCTAssertTrue(store.undoManager.canRedo)

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedKey = ImageAddress(slot: remappedSlotB, address: collidingAddress)
        XCTAssertEqual(store.snapshot.addressOverrides[remappedKey]?.colorTag, .blue)
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertFalse(store.undoManager.canRedo)

        store.undoManager.redo()

        XCTAssertTrue(overrides(in: slotB, store: store).isEmpty)
        XCTAssertEqual(store.snapshot.addressOverrides[remappedKey]?.colorTag, .blue)
    }

    @MainActor
    func testDirectSnapshotOwnerReplacementRetiresVacatedSlotUndoGeneration() throws {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        store.setColorTagAtSelection(.green)
        XCTAssertTrue(store.undoManager.canUndo)

        let replacementID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBC0")!
        var replacement = store.snapshot
        let binaryIndex = try XCTUnwrap(replacement.binaries.firstIndex { $0.slot == slotB })
        replacement.binaries[binaryIndex] = image(
            slot: slotB,
            id: replacementID.uuidString,
            name: "Replacement B",
            path: "/tmp/macscope-ws17-authoring-replacement-b",
            binaryUUID: "BBBBBBBB-0000-0000-0000-0000000000C0"
        )
        store.snapshot = replacement

        XCTAssertEqual(store.snapshot.binary(in: slotB)?.id, replacementID)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.colorTag, .green)
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertFalse(store.undoManager.canRedo)

        store.undoManager.undo()
        store.undoManager.redo()

        XCTAssertEqual(store.snapshot.binary(in: slotB)?.id, replacementID)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.colorTag, .green)
    }

    @MainActor
    func testSnapshotRemovalAndSlotReuseRetireOnlyVacatedOwnerUndo() throws {
        let store = makeStore()
        let priorBAnalysis = try XCTUnwrap(store.snapshot.analysis(in: slotB))

        select(collidingAddress, in: slotB, store: store)
        store.setColorTagAtSelection(.green)
        select(collidingAddress, in: slotA, store: store)
        store.setColorTagAtSelection(.green)

        var removed = store.snapshot
        removed.removeImage(in: slotB)
        store.snapshot = removed

        XCTAssertNil(store.snapshot.binary(in: slotB))
        XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.colorTag, .green)
        XCTAssertTrue(store.undoManager.canUndo, "the still-owned slot A edit must survive B removal")

        var reused = store.snapshot
        let replacementID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBD0")!
        reused.insertImage(
            binary: image(
                slot: slotB,
                id: replacementID.uuidString,
                name: "Reused B",
                path: "/tmp/macscope-ws17-authoring-reused-b",
                binaryUUID: "BBBBBBBB-0000-0000-0000-0000000000D0"
            ),
            analysis: priorBAnalysis
        )
        store.snapshot = reused

        store.undoManager.undo()

        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .orange)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.colorTag, .green)
        XCTAssertEqual(store.snapshot.binary(in: slotB)?.id, replacementID)
        XCTAssertTrue(store.undoManager.canRedo)

        store.undoManager.redo()

        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .green)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingBKey]?.colorTag, .green)
        XCTAssertEqual(store.snapshot.binary(in: slotB)?.id, replacementID)
    }

    @MainActor
    func testSlotRemapRetiresStoreActionsFromHostUndoManagerButPreservesOtherTargets() {
        final class UnrelatedUndoTarget {
            var value = 0
        }

        let store = makeStore()
        let hostUndoManager = UndoManager()
        hostUndoManager.groupsByEvent = false
        store.hostUndoManager = hostUndoManager

        let unrelatedTarget = UnrelatedUndoTarget()
        unrelatedTarget.value = 1
        hostUndoManager.beginUndoGrouping()
        hostUndoManager.registerUndo(withTarget: unrelatedTarget) { target in
            target.value = 0
        }
        hostUndoManager.setActionName("Unrelated Test Action")
        hostUndoManager.endUndoGrouping()

        select(collidingAddress, in: slotB, store: store)
        store.setColorTagAtSelection(.green)
        XCTAssertTrue(hostUndoManager.canUndo)

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedKey = ImageAddress(slot: remappedSlotB, address: collidingAddress)
        XCTAssertTrue(hostUndoManager.canUndo, "the unrelated target's action must survive")
        XCTAssertEqual(store.snapshot.addressOverrides[remappedKey]?.colorTag, .green)

        hostUndoManager.undo()

        XCTAssertEqual(unrelatedTarget.value, 0)
        XCTAssertEqual(store.snapshot.addressOverrides[remappedKey]?.colorTag, .green)
        XCTAssertTrue(overrides(in: slotB, store: store).isEmpty)
    }

    @MainActor
    func testSlotRemapPreservesUnaffectedSiblingStoreUndo() {
        let store = makeStore()
        select(collidingAddress, in: slotA, store: store)
        let originalAColor = store.snapshot.addressOverrides[collidingAKey]?.colorTag
        let originalBColor = store.snapshot.addressOverrides[collidingBKey]?.colorTag
        store.setColorTagAtSelection(.green)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .green)
        XCTAssertTrue(store.undoManager.canUndo)

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedBKey = ImageAddress(slot: remappedSlotB, address: collidingAddress)

        XCTAssertTrue(store.undoManager.canUndo, "slot A authoring remains valid after remapping B")
        store.undoManager.undo()

        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, originalAColor)
        XCTAssertEqual(store.snapshot.addressOverrides[remappedBKey]?.colorTag, originalBColor)
        XCTAssertTrue(overrides(in: slotB, store: store).isEmpty)
    }

    @MainActor
    func testSlotRemapPreservesUnaffectedSiblingBreakpointUndoAndRedo() {
        let store = makeStore()
        select(collidingAddress, in: slotA, store: store)
        XCTAssertTrue(breakpoint(in: slotA, at: collidingAddress, store: store))

        store.toggleBreakpointAtSelection()
        XCTAssertFalse(breakpoint(in: slotA, at: collidingAddress, store: store))

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedBInstructions = store.snapshot.analysis(in: remappedSlotB)?.instructions
        XCTAssertTrue(store.undoManager.canUndo, "slot A breakpoint history must survive remapping B")

        store.undoManager.undo()
        XCTAssertTrue(breakpoint(in: slotA, at: collidingAddress, store: store))
        XCTAssertEqual(store.snapshot.analysis(in: remappedSlotB)?.instructions, remappedBInstructions)
        assertVacatedSlotBHasNoPersistedState(store)

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertFalse(breakpoint(in: slotA, at: collidingAddress, store: store))
        XCTAssertEqual(store.snapshot.analysis(in: remappedSlotB)?.instructions, remappedBInstructions)
        assertVacatedSlotBHasNoPersistedState(store)
    }

    @MainActor
    func testSlotRemapPreservesUnaffectedSiblingIndividualOverrideUndoAndRedo() {
        let store = makeStore()
        select(collidingAddress, in: slotA, store: store)
        let originalAColor = store.snapshot.addressOverrides[collidingAKey]?.colorTag

        store.setColorTagAtSelection(.green)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .green)

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedBOverrides = overrides(in: remappedSlotB, store: store)
        XCTAssertTrue(store.undoManager.canUndo, "slot A override history must survive remapping B")

        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, originalAColor)
        XCTAssertEqual(overrides(in: remappedSlotB, store: store), remappedBOverrides)
        assertVacatedSlotBHasNoPersistedState(store)

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .green)
        XCTAssertEqual(overrides(in: remappedSlotB, store: store), remappedBOverrides)
        assertVacatedSlotBHasNoPersistedState(store)
    }

    @MainActor
    func testSlotRemapPreservesUnaffectedSiblingBulkOverrideUndoAndRedoWithoutRestoringOldBMap() {
        let store = makeStore()
        store.focusImage(slotA)
        let originalAOverrides = overrides(in: slotA, store: store)

        store.setColorTag(at: [collidingAddress, mappedUndecodedAddress], color: .green)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .green)
        XCTAssertEqual(store.snapshot.addressOverrides[mappedUndecodedAKey]?.colorTag, .green)

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedBOverrides = overrides(in: remappedSlotB, store: store)
        XCTAssertFalse(remappedBOverrides.isEmpty, "fixture must carry B override payload through the remap")
        XCTAssertTrue(store.undoManager.canUndo, "slot A bulk-override history must survive remapping B")

        store.undoManager.undo()
        XCTAssertEqual(overrides(in: slotA, store: store), originalAOverrides)
        XCTAssertEqual(overrides(in: remappedSlotB, store: store), remappedBOverrides)
        assertVacatedSlotBHasNoPersistedState(store)

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .green)
        XCTAssertEqual(store.snapshot.addressOverrides[mappedUndecodedAKey]?.colorTag, .green)
        XCTAssertEqual(overrides(in: remappedSlotB, store: store), remappedBOverrides)
        assertVacatedSlotBHasNoPersistedState(store)
    }

    @MainActor
    func testSlotRemapPreservesUnaffectedSiblingBookmarkUndoAndRedoWithoutRestoringOldBList() {
        let store = makeStore()
        store.focusImage(slotA)

        store.addBookmark(at: collidingAddress, name: "A_BOOKMARK_EDITED")
        XCTAssertEqual(bookmarkName(in: slotA, store: store), "A_BOOKMARK_EDITED")

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedBBookmarks = bookmarks(in: remappedSlotB, store: store)
        XCTAssertFalse(remappedBBookmarks.isEmpty, "fixture must carry B bookmarks through the remap")
        XCTAssertTrue(store.undoManager.canUndo, "slot A bookmark history must survive remapping B")

        store.undoManager.undo()
        XCTAssertEqual(bookmarkName(in: slotA, store: store), "A_BOOKMARK")
        XCTAssertEqual(bookmarks(in: remappedSlotB, store: store), remappedBBookmarks)
        assertVacatedSlotBHasNoPersistedState(store)

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertEqual(bookmarkName(in: slotA, store: store), "A_BOOKMARK_EDITED")
        XCTAssertEqual(bookmarks(in: remappedSlotB, store: store), remappedBBookmarks)
        assertVacatedSlotBHasNoPersistedState(store)
    }

    @MainActor
    func testSlotRemapPreservesUnaffectedSiblingManualXRefUndoAndRedoWithoutRestoringOldBList() {
        let store = makeStore()
        let bXRef = ManualXRef(
            from: collidingAddress,
            to: xrefTargetAddress,
            kind: XRefKind.call,
            isSuppression: false,
            imageSlot: slotB
        )
        store.snapshot.manualXRefs = [bXRef]
        store.focusImage(slotA)

        store.addManualXRef(from: collidingAddress, to: xrefTargetAddress, kind: XRefKind.call)
        XCTAssertEqual(manualXRefs(in: slotA, store: store).count, 1)

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedBXRefs = manualXRefs(in: remappedSlotB, store: store)
        XCTAssertEqual(remappedBXRefs.count, 1, "fixture must carry B manual xrefs through the remap")
        XCTAssertTrue(store.undoManager.canUndo, "slot A manual-xref history must survive remapping B")

        store.undoManager.undo()
        XCTAssertTrue(manualXRefs(in: slotA, store: store).isEmpty)
        XCTAssertEqual(manualXRefs(in: remappedSlotB, store: store), remappedBXRefs)
        assertVacatedSlotBHasNoPersistedState(store)

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertEqual(manualXRefs(in: slotA, store: store).count, 1)
        XCTAssertEqual(manualXRefs(in: remappedSlotB, store: store), remappedBXRefs)
        assertVacatedSlotBHasNoPersistedState(store)
    }

    @MainActor
    func testSlotRemapPreservesUnaffectedSiblingSegmentUndoAndRedoWithoutRestoringOldBList() {
        let store = makeStore()
        let bSegment = SegmentOverride(
            originalName: "__TEXT,__b",
            imageSlot: slotB,
            displayName: "B Display Name"
        )
        store.snapshot.segmentOverrides = [bSegment]
        store.focusImage(slotA)

        store.renameSegment(sectionName: "__TEXT,__a", displayName: "A Display Name")
        XCTAssertEqual(
            store.snapshot.segmentOverride(for: "__TEXT,__a", in: slotA)?.displayName,
            "A Display Name"
        )

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        let remappedBSegments = segmentOverrides(in: remappedSlotB, store: store)
        XCTAssertEqual(remappedBSegments.count, 1, "fixture must carry B segment state through the remap")
        XCTAssertTrue(store.undoManager.canUndo, "slot A segment history must survive remapping B")

        store.undoManager.undo()
        XCTAssertNil(store.snapshot.segmentOverride(for: "__TEXT,__a", in: slotA))
        XCTAssertEqual(segmentOverrides(in: remappedSlotB, store: store), remappedBSegments)
        assertVacatedSlotBHasNoPersistedState(store)

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertEqual(
            store.snapshot.segmentOverride(for: "__TEXT,__a", in: slotA)?.displayName,
            "A Display Name"
        )
        XCTAssertEqual(segmentOverrides(in: remappedSlotB, store: store), remappedBSegments)
        assertVacatedSlotBHasNoPersistedState(store)
    }

    @MainActor
    func testSlotRemapPreservesWorkspaceGlobalTypeDefinitionUndoAndRedo() {
        let store = makeStore()
        let summary = store.defineTypesFromCHeader("struct WS17GlobalType { int value; };")
        XCTAssertEqual(summary.addedNames, ["WS17GlobalType"])
        XCTAssertTrue(store.snapshot.typeDefinitions.contains { $0.name == "WS17GlobalType" })

        store.remapImageSlot(from: slotB, to: remappedSlotB)
        XCTAssertTrue(store.undoManager.canUndo, "workspace-global type history must survive an unrelated slot remap")

        store.undoManager.undo()
        XCTAssertFalse(store.snapshot.typeDefinitions.contains { $0.name == "WS17GlobalType" })
        assertVacatedSlotBHasNoPersistedState(store)

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertTrue(store.snapshot.typeDefinitions.contains { $0.name == "WS17GlobalType" })
        assertVacatedSlotBHasNoPersistedState(store)
    }

    @MainActor
    func testUndoingUnaffectedSiblingActionAfterSlotRemapRetainsUnsavedRemap() {
        let store = makeStore()
        XCTAssertFalse(store.isDirty)
        select(collidingAddress, in: slotA, store: store)

        store.setColorTagAtSelection(.green)
        XCTAssertTrue(store.isDirty)
        store.remapImageSlot(from: slotB, to: remappedSlotB)

        store.undoManager.undo()

        // The slot remap is a separate persisted mutation, so undoing A cannot restore
        // the pre-remap clean token even though A's authoring history remains usable.
        XCTAssertTrue(store.isDirty, "undoing A must not hide the unsaved slot-B remap")
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .orange)
        assertVacatedSlotBHasNoPersistedState(store)
        XCTAssertNotNil(store.snapshot.binary(in: remappedSlotB))

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertTrue(store.isDirty, "redoing A does not save either persisted change")
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .green)
        assertVacatedSlotBHasNoPersistedState(store)
        XCTAssertNotNil(store.snapshot.binary(in: remappedSlotB))
    }

    @MainActor
    func testUndoingUnaffectedSiblingActionAfterSlotRemapAndSaveRedirtiesThenRedoCleans() throws {
        let store = makeStore()
        select(collidingAddress, in: slotA, store: store)
        store.setColorTagAtSelection(.green)
        store.remapImageSlot(from: slotB, to: remappedSlotB)

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WS17-SlotUndo-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        _ = try store.saveWorkspacePackage(
            to: packageURL,
            using: database,
            inputCopyingDecision: .referenceOriginalInputs,
            bookmarkResolutionDecision: .promptForMissingInputs
        )
        XCTAssertFalse(store.isDirty, "saving the remapped workspace establishes the applied A edit as baseline")

        store.undoManager.undo()
        XCTAssertTrue(store.isDirty, "undoing past the saved A edit must differ from the package on disk")
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .orange)
        assertVacatedSlotBHasNoPersistedState(store)

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo()
        XCTAssertFalse(store.isDirty, "redoing to the saved A edit must restore the package baseline")
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey]?.colorTag, .green)
        assertVacatedSlotBHasNoPersistedState(store)
    }

    // MARK: - Assertions

    @MainActor
    private func assertTextEditor(
        kind: OverrideEditorRequest.Kind,
        selectedAddress: UInt64,
        targetAddress: UInt64,
        initialValue: String,
        committedValue: String,
        begin: @MainActor (WorkspaceStore) -> Void,
        value: @MainActor (AddressOverride?) -> String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let store = makeStore()
        select(selectedAddress, in: slotB, store: store)
        let before = store.snapshot.addressOverrides
        begin(store)

        let request = try XCTUnwrap(store.overrideEditorRequest, file: file, line: line)
        XCTAssertEqual(request.kind, kind, file: file, line: line)
        XCTAssertEqual(request.imageSlot, slotB, file: file, line: line)
        XCTAssertEqual(request.address, targetAddress, file: file, line: line)
        XCTAssertEqual(request.initialValue, initialValue, file: file, line: line)

        store.focusImage(slotA)
        store.commitOverrideEditor(request, text: committedValue)
        let target = ImageAddress(slot: slotB, address: targetAddress)
        let collidingA = ImageAddress(slot: slotA, address: targetAddress)
        XCTAssertEqual(value(store.snapshot.addressOverrides[target]), committedValue, file: file, line: line)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingA], before[collidingA], file: file, line: line)

        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides, before, file: file, line: line)
    }

    private struct DirectMutationContext {
        let store: WorkspaceStore
        let key: ImageAddress
    }

    private enum OwnerInvalidation: String, CaseIterable {
        case removal
        case remap
    }

    private enum DelayedRequestFamily: String, CaseIterable {
        case rename
        case comment
        case tag
        case localLabel
        case signature
        case registerRename
        case switchHint
        case makeData
        case patchBytes
        case assembly

        var expectedStaleIssue: String {
            switch self {
            case .rename, .comment, .tag, .localLabel:
                return "The entity that owned this editor request is no longer available."
            case .signature:
                return "The function that owned this signature request is no longer available."
            case .registerRename:
                return "The function that owned this register request is no longer available."
            case .switchHint:
                return "The instruction that owned this switch request is no longer available."
            case .makeData:
                return "The address that owned this data-shape request is no longer available."
            case .patchBytes:
                return "The instruction that owned this patch request is no longer available."
            case .assembly:
                return "The instruction that owned this assembly request is no longer available."
            }
        }
    }

    private struct SnapshotOwnerIdentity: Equatable {
        var slot: ImageSlot
        var id: UUID
    }

    private struct GuardedAuthoringState: Equatable {
        var owners: [SnapshotOwnerIdentity]
        var addressOverrides: [ImageAddress: AddressOverride]
        var bookmarks: [Bookmark]
        var segmentOverrides: [SegmentOverride]
        var instructionsBySlot: [ImageSlot: [InstructionRow]]
        var selectedImageAddress: ImageAddress?
        var focusedImageSlot: ImageSlot
        var isDirty: Bool
        var canUndo: Bool
        var canRedo: Bool
        var breakpointRevisions: [ImageSlot: UInt64]
        var breakpointRevisionGeneration: UInt64
    }

    private struct DelayedCommitProbe {
        var commit: @MainActor () -> Void
        var assertRequestPreserved: @MainActor () -> Void
    }

    @MainActor
    private func assertDirectMutation(
        _ label: String,
        prepare: @MainActor (WorkspaceStore, ImageAddress) -> Void = { _, _ in },
        mutate: @MainActor (WorkspaceStore) -> Void,
        validate: @MainActor (DirectMutationContext) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let store = makeStore()
        let key = collidingBKey
        prepare(store, key)
        select(collidingAddress, in: slotB, store: store)
        let before = store.snapshot.addressOverrides

        mutate(store)
        XCTAssertTrue(validate(DirectMutationContext(store: store, key: key)), label, file: file, line: line)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey], before[collidingAKey], label, file: file, line: line)
        let afterMutation = store.snapshot.addressOverrides

        store.focusImage(slotA)
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides, before, "Undo changed a non-target owner for \(label)", file: file, line: line)

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.addressOverrides, afterMutation, "Redo changed a non-target owner for \(label)", file: file, line: line)
        XCTAssertTrue(validate(DirectMutationContext(store: store, key: key)), "Redo lost B ownership for \(label)", file: file, line: line)
        XCTAssertEqual(store.snapshot.addressOverrides[collidingAKey], before[collidingAKey], label, file: file, line: line)
    }

    @MainActor
    private func assertBOnlyDirectMutation(
        _ label: String,
        prepare: @MainActor (WorkspaceStore, ImageAddress) -> Void = { _, _ in },
        mutate: @MainActor (WorkspaceStore) -> Void,
        validate: @MainActor (DirectMutationContext) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let store = makeStore()
        let key = bOnlyBKey
        prepare(store, key)
        select(bOnlyAddress, in: slotB, store: store)
        let aBefore = store.snapshot.addressOverrides[bOnlyAKey]

        mutate(store)

        XCTAssertTrue(validate(DirectMutationContext(store: store, key: key)), label, file: file, line: line)
        XCTAssertEqual(store.snapshot.addressOverrides[bOnlyAKey], aBefore, label, file: file, line: line)
    }

    @MainActor
    private func assertMappedUndecodedInstructionMutationDenied(
        _ label: String,
        action: @MainActor (WorkspaceStore) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let store = makeStore()
        select(mappedUndecodedAddress, in: slotB, store: store)
        XCTAssertNil(store.selectedInstruction, file: file, line: line)
        let overridesBefore = store.snapshot.addressOverrides
        let aInstructionsBefore = store.snapshot.analysis(in: slotA)?.instructions
        let bInstructionsBefore = store.snapshot.analysis(in: slotB)?.instructions

        action(store)

        XCTAssertEqual(store.snapshot.addressOverrides, overridesBefore, label, file: file, line: line)
        XCTAssertEqual(store.snapshot.analysis(in: slotA)?.instructions, aInstructionsBefore, label, file: file, line: line)
        XCTAssertEqual(store.snapshot.analysis(in: slotB)?.instructions, bInstructionsBefore, label, file: file, line: line)
        XCTAssertNil(store.overrideEditorRequest, label, file: file, line: line)
        XCTAssertNil(store.switchHintEditorRequest, label, file: file, line: line)
        XCTAssertNil(store.pendingPatchBytesRequest, label, file: file, line: line)
        XCTAssertNil(store.pendingAssembleRequest, label, file: file, line: line)
    }

    @MainActor
    private func assertLoadedWithoutAnalysisAbstains(
        _ label: String,
        action: @MainActor (WorkspaceStore) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let store = makeStore()
        store.focusImage(slotWithoutAnalysis)
        store.selectInstruction(collidingAddress)
        XCTAssertNil(store.selectedImageAddress, label, file: file, line: line)
        XCTAssertNil(store.selectedInstruction, label, file: file, line: line)
        let before = guardedAuthoringState(store)

        action(store)

        XCTAssertEqual(guardedAuthoringState(store), before, label, file: file, line: line)
        XCTAssertNil(store.overrideEditorRequest, label, file: file, line: line)
        XCTAssertNil(store.signatureEditorRequest, label, file: file, line: line)
        XCTAssertNil(store.registerRenameRequest, label, file: file, line: line)
        XCTAssertNil(store.switchHintEditorRequest, label, file: file, line: line)
        XCTAssertNil(store.dataShapeEditorRequest, label, file: file, line: line)
        XCTAssertNil(store.pendingPatchBytesRequest, label, file: file, line: line)
        XCTAssertNil(store.pendingAssembleRequest, label, file: file, line: line)
    }

    @MainActor
    private func assertInvalidatedOwnerRejects(
        _ family: DelayedRequestFamily,
        invalidation: OwnerInvalidation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let store = makeStore()
        select(collidingAddress, in: slotB, store: store)
        let probe = try delayedCommit(for: family, in: store, file: file, line: line)

        switch invalidation {
        case .removal:
            store.snapshot.removeImage(in: slotB)
        case .remap:
            store.remapImageSlot(from: slotB, to: remappedSlotB)
        }

        store.lastIssue = nil
        let beforeCommit = guardedAuthoringState(store)
        probe.commit()

        let label = "\(invalidation.rawValue): \(family.rawValue)"
        XCTAssertEqual(guardedAuthoringState(store), beforeCommit, label, file: file, line: line)
        XCTAssertEqual(store.lastIssue, family.expectedStaleIssue, label, file: file, line: line)
        XCTAssertNil(store.snapshot.binary(in: slotB), label, file: file, line: line)
        probe.assertRequestPreserved()
        if invalidation == .remap {
            XCTAssertTrue(overrides(in: slotB, store: store).isEmpty, label, file: file, line: line)
            XCTAssertNotNil(store.snapshot.binary(in: remappedSlotB), label, file: file, line: line)
        } else {
            XCTAssertFalse(
                overrides(in: slotB, store: store).isEmpty,
                "removed-image authoring is intentionally retained for caller policy: \(label)",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func delayedCommit(
        for family: DelayedRequestFamily,
        in store: WorkspaceStore,
        file: StaticString,
        line: UInt
    ) throws -> DelayedCommitProbe {
        switch family {
        case .rename:
            store.beginRenameAtSelection()
            let request = try XCTUnwrap(store.overrideEditorRequest, file: file, line: line)
            return DelayedCommitProbe(
                commit: { store.commitOverrideEditor(request, text: "STALE_RENAME") },
                assertRequestPreserved: { XCTAssertEqual(store.overrideEditorRequest, request, file: file, line: line) }
            )
        case .comment:
            store.beginCommentEditAtSelection()
            let request = try XCTUnwrap(store.overrideEditorRequest, file: file, line: line)
            return DelayedCommitProbe(
                commit: { store.commitOverrideEditor(request, text: "STALE_COMMENT") },
                assertRequestPreserved: { XCTAssertEqual(store.overrideEditorRequest, request, file: file, line: line) }
            )
        case .tag:
            store.beginTagEditAtSelection()
            let request = try XCTUnwrap(store.overrideEditorRequest, file: file, line: line)
            return DelayedCommitProbe(
                commit: { store.commitOverrideEditor(request, text: "STALE_TAG") },
                assertRequestPreserved: { XCTAssertEqual(store.overrideEditorRequest, request, file: file, line: line) }
            )
        case .localLabel:
            store.beginLocalLabelEditAtSelection()
            let request = try XCTUnwrap(store.overrideEditorRequest, file: file, line: line)
            return DelayedCommitProbe(
                commit: { store.commitOverrideEditor(request, text: "STALE_LOCAL_LABEL") },
                assertRequestPreserved: { XCTAssertEqual(store.overrideEditorRequest, request, file: file, line: line) }
            )
        case .signature:
            store.beginSignatureEditAtSelection()
            var request = try XCTUnwrap(store.signatureEditorRequest, file: file, line: line)
            request.returnType = "stale_t"
            store.signatureEditorRequest = request
            return DelayedCommitProbe(
                commit: { store.commitSignatureEditor(request) },
                assertRequestPreserved: { XCTAssertEqual(store.signatureEditorRequest, request, file: file, line: line) }
            )
        case .registerRename:
            store.beginRegisterRenameAtSelection(register: "x19")
            let request = try XCTUnwrap(store.registerRenameRequest, file: file, line: line)
            return DelayedCommitProbe(
                commit: { _ = store.commitRegisterRename(request, register: "x19", name: "stale_register") },
                assertRequestPreserved: { XCTAssertEqual(store.registerRenameRequest, request, file: file, line: line) }
            )
        case .switchHint:
            store.beginSwitchHintEditAtSelection()
            var request = try XCTUnwrap(store.switchHintEditorRequest, file: file, line: line)
            request.entryCountText = "11"
            store.switchHintEditorRequest = request
            return DelayedCommitProbe(
                commit: { store.commitSwitchHintEditor(request) },
                assertRequestPreserved: { XCTAssertEqual(store.switchHintEditorRequest, request, file: file, line: line) }
            )
        case .makeData:
            store.beginMakeDataAtSelection()
            var request = try XCTUnwrap(store.dataShapeEditorRequest, file: file, line: line)
            request.shape = .array
            request.countText = "11"
            store.dataShapeEditorRequest = request
            return DelayedCommitProbe(
                commit: { _ = store.commitDataShapeEditor(request) },
                assertRequestPreserved: { XCTAssertEqual(store.dataShapeEditorRequest, request, file: file, line: line) }
            )
        case .patchBytes:
            store.perform(.patchBytes)
            let request = try XCTUnwrap(store.pendingPatchBytesRequest, file: file, line: line)
            return DelayedCommitProbe(
                commit: { _ = store.patchBytes(request, hex: "de ad be ef") },
                assertRequestPreserved: { XCTAssertEqual(store.pendingPatchBytesRequest, request, file: file, line: line) }
            )
        case .assembly:
            store.perform(.assembleInstruction)
            let request = try XCTUnwrap(store.pendingAssembleRequest, file: file, line: line)
            return DelayedCommitProbe(
                commit: { _ = store.assemble(request, text: "nop") },
                assertRequestPreserved: { XCTAssertEqual(store.pendingAssembleRequest, request, file: file, line: line) }
            )
        }
    }

    @MainActor
    private func guardedAuthoringState(_ store: WorkspaceStore) -> GuardedAuthoringState {
        GuardedAuthoringState(
            owners: store.snapshot.binaries
                .map { SnapshotOwnerIdentity(slot: $0.slot, id: $0.id) }
                .sorted { $0.slot.rawValue < $1.slot.rawValue },
            addressOverrides: store.snapshot.addressOverrides,
            bookmarks: store.snapshot.bookmarks,
            segmentOverrides: store.snapshot.segmentOverrides,
            instructionsBySlot: store.snapshot.analysisBySlot.mapValues(\.instructions),
            selectedImageAddress: store.selectedImageAddress,
            focusedImageSlot: store.focusedImageSlot,
            isDirty: store.isDirty,
            canUndo: store.undoManager.canUndo,
            canRedo: store.undoManager.canRedo,
            breakpointRevisions: store.debuggerBreakpointRevisions,
            breakpointRevisionGeneration: store.debuggerBreakpointRevisionGeneration
        )
    }

    @MainActor
    private func select(_ address: UInt64, in slot: ImageSlot, store: WorkspaceStore) {
        store.focusImage(slot)
        store.selectInstruction(address)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slot, address: address))
    }

    @MainActor
    private func binaryID(
        in slot: ImageSlot,
        store: WorkspaceStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UUID {
        try XCTUnwrap(store.snapshot.binary(in: slot)?.id, file: file, line: line)
    }

    @MainActor
    private func overrides(in slot: ImageSlot, store: WorkspaceStore) -> [ImageAddress: AddressOverride] {
        Dictionary(uniqueKeysWithValues: store.snapshot.addressOverrides.compactMap { key, value in
            key.slot == slot ? (key, value) : nil
        })
    }

    @MainActor
    private func bookmarkName(in slot: ImageSlot, store: WorkspaceStore) -> String? {
        store.snapshot.bookmark(at: ImageAddress(slot: slot, address: collidingAddress))?.name
    }

    @MainActor
    private func bookmarks(in slot: ImageSlot, store: WorkspaceStore) -> [Bookmark] {
        store.snapshot.bookmarks.filter { $0.imageSlot == slot }
    }

    @MainActor
    private func manualXRefs(in slot: ImageSlot, store: WorkspaceStore) -> [ManualXRef] {
        store.snapshot.manualXRefs.filter { $0.imageSlot == slot }
    }

    @MainActor
    private func segmentOverrides(in slot: ImageSlot, store: WorkspaceStore) -> [SegmentOverride] {
        store.snapshot.segmentOverrides.filter { $0.imageSlot == slot }
    }

    @MainActor
    private func breakpoint(in slot: ImageSlot, at address: UInt64, store: WorkspaceStore) -> Bool {
        store.snapshot.analysis(in: slot)?.instructions.first { $0.address == address }?.hasBreakpoint ?? false
    }

    @MainActor
    private func assertVacatedSlotBHasNoPersistedState(
        _ store: WorkspaceStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(store.snapshot.binary(in: slotB), file: file, line: line)
        XCTAssertNil(store.snapshot.analysis(in: slotB), file: file, line: line)
        XCTAssertTrue(overrides(in: slotB, store: store).isEmpty, file: file, line: line)
        XCTAssertTrue(bookmarks(in: slotB, store: store).isEmpty, file: file, line: line)
        XCTAssertTrue(manualXRefs(in: slotB, store: store).isEmpty, file: file, line: line)
        XCTAssertTrue(segmentOverrides(in: slotB, store: store).isEmpty, file: file, line: line)
    }

    // MARK: - Fixture

    @MainActor
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "WS-17 focused authoring",
            snapshot: makeSnapshot(),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    @MainActor
    private func makeBinarylessStore() -> WorkspaceStore {
        var analysis = ImageAnalysis()
        analysis.instructions = [
            instruction(collidingAddress, mnemonic: "legacy_collision", comment: "LEGACY"),
        ]
        analysis.sections = [
            mappedSection(
                id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDD1",
                name: "__TEXT,__legacy"
            ),
        ]
        analysis.hexBytes = Data(repeating: 0xDD, count: 0x400)
        analysis.imageBytes = Data()

        return WorkspaceStore(
            workspaceName: "WS-17 binary-less authoring",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                analysisBySlot: [.primary: analysis]
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    private func makeSnapshot() -> WorkspaceSnapshot {
        var analysisA = ImageAnalysis()
        analysisA.functions = [FunctionSummary(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!,
            name: "AProcedure",
            startAddress: aFunctionStart,
            endAddress: collidingAddress + 4,
            confidence: 1
        )]
        analysisA.instructions = [
            instruction(aFunctionStart, mnemonic: "a_start", comment: "A_FUNCTION_START"),
            instruction(collidingAddress, mnemonic: "a_collision", comment: "A_DECODED_COMMENT", breakpoint: true),
            instruction(mappedUndecodedAddress, mnemonic: "a_mapped", comment: "A_MAPPED_DECODED"),
        ]
        analysisA.sections = [mappedSection(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2",
            name: "__TEXT,__a",
            size: 0x200
        )]
        analysisA.hexBytes = Data(repeating: 0xAA, count: 0x400)
        analysisA.imageBytes = Data()

        var analysisB = ImageAnalysis()
        analysisB.functions = [FunctionSummary(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1")!,
            name: "BProcedure",
            startAddress: bFunctionStart,
            endAddress: xrefTargetAddress + 4,
            confidence: 1
        )]
        analysisB.instructions = [
            instruction(bFunctionStart, mnemonic: "b_start", comment: "B_FUNCTION_START"),
            instruction(collidingAddress, mnemonic: "b_collision", comment: "B_DECODED_COMMENT"),
            instruction(bOnlyAddress, mnemonic: "b_only", comment: "B_ONLY"),
            instruction(xrefTargetAddress, mnemonic: "b_target", comment: "B_TARGET"),
        ]
        analysisB.sections = [mappedSection(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB2", name: "__TEXT,__b")]
        analysisB.hexBytes = Data(repeating: 0xBB, count: 0x400)
        analysisB.imageBytes = Data()

        var snapshot = WorkspaceSnapshot(
            binaries: [
                image(
                    slot: slotA,
                    id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA0",
                    name: "Image A",
                    path: "/tmp/macscope-ws17-authoring-a",
                    binaryUUID: "AAAAAAAA-0000-0000-0000-000000000000"
                ),
                image(
                    slot: slotB,
                    id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB0",
                    name: "Image B",
                    path: "/tmp/macscope-ws17-authoring-b",
                    binaryUUID: "BBBBBBBB-0000-0000-0000-000000000000"
                ),
                image(
                    slot: slotWithoutAnalysis,
                    id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCC0",
                    name: "Image C (loaded, no analysis)",
                    path: "/tmp/macscope-ws17-authoring-c",
                    binaryUUID: "CCCCCCCC-0000-0000-0000-000000000000"
                ),
            ],
            analysisBySlot: [slotA: analysisA, slotB: analysisB]
        )

        snapshot.addressOverrides = [
            collidingAKey: AddressOverride(
                customComment: "A_CUSTOM_COMMENT",
                tag: "A_TAG",
                colorTag: .orange,
                isData: true,
                appliedTypeName: "AType",
                switchHint: SwitchHintOverride(
                    tableBase: collidingAddress,
                    entryCount: 2,
                    entryStride: 4,
                    isRelativeToBase: true
                ),
                operandFormat: .hex,
                markAsProcedure: true,
                isUndefined: true,
                patch: BytePatch(bytes: [0xAA, 0xAA, 0xAA, 0xAA]),
                localLabel: "A_LOCAL_LABEL"
            ),
            collidingBKey: AddressOverride(
                customComment: "B_CUSTOM_COMMENT",
                tag: "B_TAG",
                colorTag: .blue,
                isData: false,
                appliedTypeName: "BType",
                switchHint: SwitchHintOverride(
                    tableBase: xrefTargetAddress,
                    entryCount: 3,
                    entryStride: 8,
                    isRelativeToBase: false
                ),
                operandFormat: .decimal,
                markAsProcedure: false,
                isUndefined: false,
                patch: BytePatch(bytes: [0xBB, 0xBB, 0xBB, 0xBB]),
                localLabel: "B_LOCAL_LABEL"
            ),
            aFunctionCollisionKey: AddressOverride(
                customName: "A_DECOY_FUNCTION",
                signature: FunctionSignatureOverride(
                    returnType: "a_result_t",
                    args: [ArgOverride(index: 0, name: "a_arg", type: "int64_t")]
                ),
                registerNames: ["x19": "a_counter"]
            ),
            bFunctionKey: AddressOverride(
                customName: "B_CUSTOM_FUNCTION",
                signature: FunctionSignatureOverride(
                    returnType: "int32_t",
                    args: [ArgOverride(index: 0, name: "b_arg", type: "int32_t")]
                ),
                registerNames: ["x19": "b_counter"]
            ),
            mappedUndecodedAKey: AddressOverride(
                dataShape: DataShapeOverride(kind: .array, elementType: "uint8_t", elementCount: 7),
                localLabel: "A_MAPPED_LABEL"
            ),
            mappedUndecodedBKey: AddressOverride(
                dataShape: DataShapeOverride(kind: .alignment, alignment: 16),
                localLabel: "B_MAPPED_LABEL"
            ),
        ]
        snapshot.bookmarks = [
            Bookmark(address: collidingAddress, imageSlot: slotA, name: "A_BOOKMARK"),
            Bookmark(address: collidingAddress, imageSlot: slotB, name: "B_BOOKMARK"),
        ]
        return snapshot
    }

    private func instruction(
        _ address: UInt64,
        mnemonic: String,
        comment: String,
        breakpoint: Bool = false
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: "#1",
            hasBreakpoint: breakpoint,
            comment: comment
        )
    }

    private func mappedSection(id: String, name: String, size: UInt64 = 0x400) -> SectionSummary {
        SectionSummary(
            id: UUID(uuidString: id)!,
            name: name,
            address: baseAddress,
            size: size,
            fileOffset: 0,
            isExecutable: true
        )
    }

    private func image(
        slot: ImageSlot,
        id: String,
        name: String,
        path: String,
        binaryUUID: String
    ) -> BinaryImage {
        var result = BinaryImage(
            id: UUID(uuidString: id)!,
            name: name,
            path: path,
            kind: "executable",
            architecture: "arm64",
            slot: slot
        )
        result.metadata.uuid = binaryUUID
        return result
    }

    private var collidingAKey: ImageAddress { ImageAddress(slot: slotA, address: collidingAddress) }
    private var collidingBKey: ImageAddress { ImageAddress(slot: slotB, address: collidingAddress) }
    private var aFunctionCollisionKey: ImageAddress { ImageAddress(slot: slotA, address: bFunctionStart) }
    private var bFunctionKey: ImageAddress { ImageAddress(slot: slotB, address: bFunctionStart) }
    private var bOnlyAKey: ImageAddress { ImageAddress(slot: slotA, address: bOnlyAddress) }
    private var bOnlyBKey: ImageAddress { ImageAddress(slot: slotB, address: bOnlyAddress) }
    private var mappedUndecodedAKey: ImageAddress { ImageAddress(slot: slotA, address: mappedUndecodedAddress) }
    private var mappedUndecodedBKey: ImageAddress { ImageAddress(slot: slotB, address: mappedUndecodedAddress) }
}
