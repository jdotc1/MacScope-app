import XCTest
@testable import MacScope

/// WS-16 acceptance oracles for keeping every pseudocode input inside the focused image.
final class FocusedImagePseudocodeTests: XCTestCase {
    private let slotA = ImageSlot.primary
    private let slotB = ImageSlot(rawValue: 1)
    private let collidingAddress: UInt64 = 0x1_0000_1000
    private let helperAddress: UInt64 = 0x1_0000_1100
    private let dispatchAddress: UInt64 = 0x1_0000_1014
    private let callAddress: UInt64 = 0x1_0000_1018
    private let automaticDispatchAddress: UInt64 = 0x1_0000_1200
    private let selectorReference: UInt64 = 0x1_0000_1300
    private let tableBase: UInt64 = 0x1_0000_1400
    private let primaryLiteralAddress: UInt64 = 0x1_0000_1500
    private let siblingLiteralAddress: UInt64 = 0x1_0000_1504
    private let primaryOnlyFunctionAddress: UInt64 = 0x1_0000_2000
    private let siblingOnlyFunctionAddress: UInt64 = 0x1_0000_3000

    private var signatureA: FunctionSignatureOverride {
        FunctionSignatureOverride(returnType: "int32_t")
    }

    private var signatureB: FunctionSignatureOverride {
        FunctionSignatureOverride(returnType: "uint64_t")
    }

    private var workspaceType: TypeDefinition {
        TypeDefinition(
            id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            kind: .struct,
            name: "SharedWorkspaceType"
        )
    }

    func testResolvedJumpTablesUseRequestedImageRecoveredTables() {
        let primaryTargets: [UInt64] = [0xA000, 0xA100]
        let siblingTargets: [UInt64] = [0xB000, 0xB100]

        var analysisA = ImageAnalysis()
        analysisA.jumpTables = [collidingAddress: primaryTargets]

        var analysisB = ImageAnalysis()
        analysisB.jumpTables = [collidingAddress: siblingTargets]

        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: slotA), image(slot: slotB)],
            analysisBySlot: [slotA: analysisA, slotB: analysisB]
        )

        XCTAssertEqual(
            snapshot.resolvedJumpTables(in: slotB),
            [collidingAddress: siblingTargets],
            "slot-qualified jump-table resolution must not borrow the primary image's recovered table"
        )
    }

    func testRequestedImageManualSwitchHintReadsRequestedImageBytes() {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: true)

        XCTAssertEqual(
            snapshot.resolvedJumpTables(in: slotB),
            [
                dispatchAddress: [0xB010, 0xB020],
                automaticDispatchAddress: [0xB900],
            ],
            "B's authored hint must resolve through B's bytes and merge over B's recovered tables"
        )
    }

    func testFocusedRenderInputContainsOnlyRequestedImageEvidence() throws {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: true)

        let input = snapshot.pseudocodeRenderInput(
            selectedAddress: collidingAddress,
            in: slotB
        )

        XCTAssertEqual(input.imageSlot, slotB)
        XCTAssertEqual(input.functionName, "BProcedure")
        XCTAssertEqual(input.startAddress, collidingAddress)
        XCTAssertEqual(
            input.instructions.map(\.address),
            [collidingAddress, collidingAddress + 4, dispatchAddress, callAddress],
            "A's colliding data mark must not remove B code, while all three B exclusions must"
        )
        XCTAssertEqual(input.instructions.first?.comment, "B_SENTINEL")
        XCTAssertEqual(input.instructions.dropFirst().first?.comment, "B_ONLY_STEP")
        XCTAssertEqual(input.jumpTables, [
            dispatchAddress: [0xB010, 0xB020],
            automaticDispatchAddress: [0xB900],
        ])
        XCTAssertEqual(input.objcSelectors, [selectorReference: "bSelector:"])
        XCTAssertEqual(input.nameOverrides, [
            "_shared_entry": "BProcedure",
            "_shared_helper": "BHelper",
        ])
        XCTAssertEqual(input.signatureOverrides, [collidingAddress: signatureB])
        XCTAssertEqual(input.registerNameOverrides, ["x19": "b_counter"])
        XCTAssertEqual(input.types, [workspaceType])

        XCTAssertFalse(input.instructions.contains { $0.comment?.hasPrefix("A_") == true })
        XCTAssertFalse(input.objcSelectors.values.contains("aSelector:"))
        XCTAssertFalse(input.nameOverrides.values.contains("AProcedure"))
        XCTAssertFalse(input.signatureOverrides.values.contains(signatureA))
        XCTAssertFalse(input.registerNameOverrides.values.contains("a_counter"))
    }

    func testSlotQualifiedPseudocodeTargetUsesCanonicalRequestedImageExclusions() throws {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: false)

        let target = try XCTUnwrap(snapshot.pseudocodeTarget(
            selectedAddress: collidingAddress,
            in: slotB
        ))

        XCTAssertEqual(target.function.name, "_shared_entry")
        XCTAssertEqual(
            target.function.id,
            UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1")!
        )
        XCTAssertEqual(
            target.instructions.map(\.address),
            [collidingAddress, collidingAddress + 4, dispatchAddress, callAddress]
        )
        XCTAssertTrue(
            target.instructions.contains { $0.address == collidingAddress + 4 },
            "A's isData mark at the colliding VA must not remove B's instruction"
        )
        XCTAssertFalse(target.instructions.contains { $0.address == collidingAddress + 8 })
        XCTAssertFalse(target.instructions.contains { $0.address == collidingAddress + 12 })
        XCTAssertFalse(target.instructions.contains { $0.address == collidingAddress + 16 })
    }

    func testSlotQualifiedDataAddressesUseRequestedImageLiterals() {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: false)

        let marked = snapshot.dataMarkedAddresses(in: slotB)

        XCTAssertTrue(marked.contains(collidingAddress + 8))
        XCTAssertTrue(marked.contains(collidingAddress + 12))
        XCTAssertTrue(marked.contains(collidingAddress + 16))
        XCTAssertTrue(marked.contains(siblingLiteralAddress))
        XCTAssertFalse(
            marked.contains(primaryLiteralAddress),
            "a slot-qualified helper must not append the primary image's string literals"
        )
    }

    func testNoFunctionFocusedRenderInputFallsBackOnlyToRequestedImageInstructions() {
        var snapshot = collisionSnapshot(includeSiblingSwitchHint: false)
        let fallbackRows = [instruction(
            collidingAddress + 0x800,
            mnemonic: "udf",
            operands: "#7",
            comment: "B_FALLBACK_SENTINEL"
        )]
        snapshot.mutateAnalysis(in: slotB) { analysis in
            analysis.functions = []
            analysis.instructions = fallbackRows
        }

        let input = snapshot.pseudocodeRenderInput(selectedAddress: nil, in: slotB)

        XCTAssertEqual(input.imageSlot, slotB)
        XCTAssertEqual(input.functionName, "_main")
        XCTAssertNil(input.startAddress)
        XCTAssertEqual(input.instructions, fallbackRows)
        XCTAssertEqual(input.instructions.first?.comment, "B_FALLBACK_SENTINEL")
        XCTAssertFalse(input.instructions.contains { $0.comment == "A_SENTINEL" })

        let service = DocumentExportService()
        XCTAssertEqual(
            service.renderPseudocode(snapshot: snapshot, selectedAddress: nil, in: slotB),
            ""
        )
        XCTAssertEqual(service.renderAllPseudocode(snapshot: snapshot, in: slotB), "")
        XCTAssertFalse(
            service.renderPseudocode(
                snapshot: snapshot,
                selectedAddress: collidingAddress
            ).isEmpty,
            "the primary image still has functions, so B's empty export cannot be a workspace-wide fallback"
        )
    }

    @MainActor
    func testPrimaryCompatibilityWrappersRemainPrimaryAfterSiblingReceivesFocus() throws {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: false)
        let store = WorkspaceStore(
            workspaceName: "Focused pseudocode",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)

        let primaryTarget = try XCTUnwrap(store.snapshot.pseudocodeTarget(
            selectedAddress: collidingAddress
        ))

        XCTAssertEqual(store.focusedImageSlot, slotB)
        XCTAssertEqual(primaryTarget.function.name, "_shared_entry")
        XCTAssertEqual(primaryTarget.instructions.first?.comment, "A_SENTINEL")
        XCTAssertEqual(
            store.snapshot.enclosingFunction(for: collidingAddress)?.id,
            UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!
        )
        XCTAssertEqual(store.snapshot.functionNameOverrides(), [
            "_shared_entry": "AProcedure",
            "_shared_helper": "AHelper",
        ])
        XCTAssertEqual(
            store.snapshot.registerNameOverrides(forProcedureAt: collidingAddress),
            ["x19": "a_counter"]
        )

        let result = try WorkspaceScriptingAPI(store: store).execute(
            "decompile",
            arguments: .object(["address": .hex(collidingAddress)])
        )
        let text = try XCTUnwrap(result["pseudocode"]?.stringValue)
        XCTAssertTrue(text.contains("AProcedure"), text)
        XCTAssertTrue(text.contains("A_SENTINEL"), text)
        XCTAssertFalse(text.contains("BProcedure"), text)
        XCTAssertFalse(text.contains("B_SENTINEL"), text)
    }

    @MainActor
    func testStoreFocusedRenderInputTracksFocusedImageAndSelection() {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: true)
        let store = WorkspaceStore(
            workspaceName: "Focused pseudocode",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)
        store.selectInstruction(collidingAddress)

        let input = store.focusedPseudocodeRenderInput

        XCTAssertEqual(input.imageSlot, slotB)
        XCTAssertEqual(input.functionName, "BProcedure")
        XCTAssertEqual(input.startAddress, collidingAddress)
        XCTAssertEqual(input.instructions.first?.comment, "B_SENTINEL")
    }

    @MainActor
    func testAdjacentInstructionSelectionStepsThroughFocusedImageOnly() {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: false)
        let store = WorkspaceStore(
            workspaceName: "Focused pseudocode",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)
        store.selectInstruction(collidingAddress)

        store.selectAdjacentInstruction(.next)

        XCTAssertEqual(
            store.selectedAddress,
            collidingAddress + 4,
            "the next B instruction is absent from A and proves arrow stepping did not use primary rows"
        )

        store.selectInstruction(dispatchAddress)
        store.selectAdjacentInstruction(.previous)

        XCTAssertEqual(
            store.selectedAddress,
            collidingAddress + 16,
            "previous must use B's decoded sequence rather than primary A"
        )
    }

    @MainActor
    func testAdjacentInstructionSelectionAbstainsWhenFocusedImageHasNoRows() {
        var missingAnalysis = collisionSnapshot(includeSiblingSwitchHint: false)
        missingAnalysis.analysisBySlot.removeValue(forKey: slotB)

        var emptyAnalysis = collisionSnapshot(includeSiblingSwitchHint: false)
        emptyAnalysis.analysisBySlot[slotB] = ImageAnalysis()

        for (fixture, snapshot) in [
            ("missing analysis", missingAnalysis),
            ("empty analysis", emptyAnalysis),
        ] {
            for (direction, directionName) in [
                (InstructionNavigationDirection.previous, "previous"),
                (InstructionNavigationDirection.next, "next"),
            ] {
                // A fresh store per direction prevents the first abstention from making the
                // second assertion pass merely because selection was already nil.
                let store = WorkspaceStore(
                    workspaceName: "Focused pseudocode",
                    snapshot: snapshot,
                    engine: AnalysisEngine(),
                    autosaveScheduler: nil
                )
                store.focusImage(slotB)
                store.selectInstruction(collidingAddress)

                store.selectAdjacentInstruction(direction)

                XCTAssertNil(
                    store.selectedAddress,
                    "\(directionName) must abstain for B's \(fixture), not borrow A's rows"
                )
            }
        }
    }

    func testExplicitSlotPseudocodeExportUsesRequestedImageWhileDefaultsRemainPrimary() {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: true)
        let service = DocumentExportService()

        let focused = service.renderPseudocode(
            snapshot: snapshot,
            selectedAddress: collidingAddress,
            in: slotB
        )
        let focusedAll = service.renderAllPseudocode(snapshot: snapshot, in: slotB)
        let primary = service.renderPseudocode(
            snapshot: snapshot,
            selectedAddress: collidingAddress
        )
        let primaryAll = service.renderAllPseudocode(snapshot: snapshot)

        for text in [focused, focusedAll] {
            XCTAssertTrue(text.contains("BProcedure"), text)
            XCTAssertTrue(text.contains("B_SENTINEL"), text)
            XCTAssertTrue(text.contains("b_counter"), text)
            XCTAssertTrue(text.contains("BHelper"), text)
            XCTAssertFalse(text.contains("AProcedure"), text)
            XCTAssertFalse(text.contains("A_SENTINEL"), text)
            XCTAssertFalse(text.contains("a_counter"), text)
            XCTAssertFalse(text.contains("AHelper"), text)
        }
        for text in [primary, primaryAll] {
            XCTAssertTrue(text.contains("AProcedure"), text)
            XCTAssertTrue(text.contains("A_SENTINEL"), text)
            XCTAssertFalse(text.contains("BProcedure"), text)
            XCTAssertFalse(text.contains("B_SENTINEL"), text)
            XCTAssertFalse(text.contains("b_counter"), text)
            XCTAssertFalse(text.contains("BHelper"), text)
        }
        XCTAssertTrue(focused.contains("uint64_t BProcedure("), focused)
        XCTAssertTrue(primary.contains("int32_t AProcedure("), primary)
        XCTAssertTrue(focusedAll.contains("_b_only_function"), focusedAll)
        XCTAssertTrue(focusedAll.contains("B_ONLY_ALL_SENTINEL"), focusedAll)
        XCTAssertFalse(focusedAll.contains("_a_only_function"), focusedAll)
        XCTAssertFalse(focusedAll.contains("A_ONLY_ALL_SENTINEL"), focusedAll)
        XCTAssertTrue(primaryAll.contains("_a_only_function"), primaryAll)
        XCTAssertTrue(primaryAll.contains("A_ONLY_ALL_SENTINEL"), primaryAll)
        XCTAssertFalse(primaryAll.contains("_b_only_function"), primaryAll)
        XCTAssertFalse(primaryAll.contains("B_ONLY_ALL_SENTINEL"), primaryAll)
    }

    @MainActor
    func testRegisterRenameRequestCommitsToOpeningImageAfterFocusChanges() throws {
        let snapshot = collisionSnapshot(includeSiblingSwitchHint: false)
        let store = WorkspaceStore(
            workspaceName: "Focused pseudocode",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)
        store.selectInstruction(collidingAddress)
        store.beginRegisterRenameAtSelection(register: "X19")

        let request = try XCTUnwrap(store.registerRenameRequest)
        XCTAssertEqual(request.imageSlot, slotB)
        XCTAssertEqual(request.target, ImageAddress(slot: slotB, address: collidingAddress))
        XCTAssertEqual(request.ownerBinaryID, try XCTUnwrap(snapshot.binary(in: slotB)).id)
        XCTAssertEqual(request.prefilledName(in: store.snapshot), "b_counter")

        store.focusImage(slotA)
        XCTAssertEqual(store.registerRenameRequest?.id, request.id)
        XCTAssertEqual(store.registerRenameRequest?.imageSlot, slotB)
        XCTAssertTrue(store.commitRegisterRename(
            request,
            register: "x19",
            name: "b_after_focus_change"
        ))
        XCTAssertNil(store.registerRenameRequest)

        XCTAssertEqual(
            store.snapshot.registerNameOverrides(forProcedureAt: collidingAddress, in: slotB)["x19"],
            "b_after_focus_change"
        )
        XCTAssertEqual(
            store.snapshot.registerNameOverrides(forProcedureAt: collidingAddress, in: slotA)["x19"],
            "a_counter",
            "a delayed B sheet must never commit into the now-focused A image"
        )
    }

    func testBinarylessPatchRequestPrefillsExactLegacyOverride() {
        var analysis = ImageAnalysis()
        analysis.instructions = [instruction(
            collidingAddress,
            mnemonic: "nop",
            operands: "",
            comment: "LEGACY_PATCH_SENTINEL"
        )]
        let patch = BytePatch(bytes: [0x1f, 0x20, 0x03, 0xd5])
        let target = ImageAddress.primary(collidingAddress)
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            analysisBySlot: [.primary: analysis],
            addressOverrides: [target: AddressOverride(patch: patch)]
        )
        let request = PatchBytesRequest(address: collidingAddress)

        XCTAssertTrue(request.hasCurrentInstruction(in: snapshot))
        XCTAssertEqual(request.existingPatch(in: snapshot), patch)
    }

    @MainActor
    func testRegisterRenameOpenerResolvesFocusedImagesDistinctProcedureStart() throws {
        let selectedAddress = collidingAddress + 8
        let siblingStart = collidingAddress - 0x10
        var analysisA = ImageAnalysis()
        analysisA.functions = [function(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1",
            name: "_a_enclosing",
            start: collidingAddress,
            end: collidingAddress + 0x20
        )]
        analysisA.instructions = [instruction(
            selectedAddress,
            mnemonic: "udf",
            operands: "#1",
            comment: "A_COLLISION"
        )]

        var analysisB = ImageAnalysis()
        analysisB.functions = [function(
            id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1",
            name: "_b_enclosing",
            start: siblingStart,
            end: collidingAddress + 0x20
        )]
        analysisB.instructions = [instruction(
            selectedAddress,
            mnemonic: "udf",
            operands: "#2",
            comment: "B_COLLISION"
        )]

        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: slotA), image(slot: slotB)],
            analysisBySlot: [slotA: analysisA, slotB: analysisB],
            addressOverrides: [
                ImageAddress(slot: slotA, address: collidingAddress): AddressOverride(
                    registerNames: ["x19": "a_distinct_start"]
                ),
                ImageAddress(slot: slotB, address: siblingStart): AddressOverride(
                    registerNames: ["x19": "b_distinct_start"]
                ),
            ]
        )
        let store = WorkspaceStore(
            workspaceName: "Focused pseudocode",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)
        store.selectInstruction(selectedAddress)
        store.beginRegisterRenameAtSelection(register: "x19")

        let request = try XCTUnwrap(store.registerRenameRequest)
        XCTAssertEqual(request.imageSlot, slotB)
        XCTAssertEqual(request.procedureStart, siblingStart)
        XCTAssertEqual(request.prefilledName(in: store.snapshot), "b_distinct_start")

        store.focusImage(slotA)
        XCTAssertTrue(store.commitRegisterRename(
            request,
            register: "x19",
            name: "b_after_distinct_start"
        ))
        XCTAssertNil(store.registerRenameRequest)
        XCTAssertEqual(
            store.snapshot.registerNameOverrides(
                forProcedureAt: siblingStart,
                in: slotB
            )["x19"],
            "b_after_distinct_start"
        )
        XCTAssertEqual(
            store.snapshot.registerNameOverrides(
                forProcedureAt: collidingAddress,
                in: slotA
            )["x19"],
            "a_distinct_start"
        )
    }

    @MainActor
    func testInvalidRegisterCommitKeepsCapturedSheetRequestOpen() throws {
        let store = WorkspaceStore(
            workspaceName: "Focused pseudocode",
            snapshot: collisionSnapshot(includeSiblingSwitchHint: false),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        store.focusImage(slotB)
        store.selectInstruction(collidingAddress)
        store.beginRegisterRenameAtSelection()

        let request = try XCTUnwrap(store.registerRenameRequest)
        XCTAssertFalse(store.commitRegisterRename(request, register: "   ", name: "draft"))
        XCTAssertEqual(store.registerRenameRequest, request)
        XCTAssertEqual(store.lastIssue, "Provide a register identifier (e.g. x19).")
        XCTAssertEqual(
            store.snapshot.registerNameOverrides(forProcedureAt: collidingAddress, in: slotB),
            ["x19": "b_counter"]
        )
    }

    func testSlotQualifiedResolverPreservesRangeZeroWidthAndNearestPrecedingRules() {
        let normalID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEE1")!
        let zeroWidthID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEE2")!
        var analysis = ImageAnalysis()
        analysis.functions = [
            function(id: normalID.uuidString, name: "_normal", start: 0x4000, end: 0x4010),
            function(id: zeroWidthID.uuidString, name: "_zero", start: 0x5000, end: 0x5000),
        ]
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: slotB)],
            analysisBySlot: [slotB: analysis]
        )

        XCTAssertEqual(snapshot.enclosingFunction(for: 0x4004, in: slotB)?.id, normalID)
        XCTAssertEqual(snapshot.enclosingFunction(for: 0x5000, in: slotB)?.id, zeroWidthID)
        XCTAssertEqual(snapshot.enclosingFunction(for: 0x5004, in: slotB)?.id, zeroWidthID)
    }

    func testPrimaryWrappersHonorANonzeroDurablePrimarySlot() throws {
        let slot = ImageSlot(rawValue: 7)
        let address: UInt64 = 0x7000
        let functionID = UUID(uuidString: "77777777-7777-7777-7777-777777777771")!
        var analysis = ImageAnalysis()
        analysis.functions = [function(
            id: functionID.uuidString,
            name: "_entry",
            start: address,
            end: address + 4
        )]
        analysis.instructions = [instruction(
            address,
            mnemonic: "udf",
            operands: "#7",
            comment: "NONZERO_PRIMARY_SENTINEL"
        )]
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: slot)],
            analysisBySlot: [slot: analysis],
            addressOverrides: [
                ImageAddress(slot: slot, address: address): AddressOverride(
                    customName: "SlotSevenEntry",
                    registerNames: ["x19": "slot7_counter"]
                ),
            ]
        )

        XCTAssertEqual(snapshot.primarySlot, slot)
        XCTAssertEqual(
            snapshot.pseudocodeTarget(selectedAddress: address)?.instructions.first?.comment,
            "NONZERO_PRIMARY_SENTINEL"
        )
        XCTAssertEqual(snapshot.enclosingFunction(for: address)?.id, functionID)
        XCTAssertEqual(snapshot.functionNameOverrides(), ["_entry": "SlotSevenEntry"])
        XCTAssertEqual(
            snapshot.registerNameOverrides(forProcedureAt: address),
            ["x19": "slot7_counter"]
        )
        let exported = DocumentExportService().renderPseudocode(
            snapshot: snapshot,
            selectedAddress: address
        )
        let allExported = DocumentExportService().renderAllPseudocode(snapshot: snapshot)
        XCTAssertTrue(exported.contains("SlotSevenEntry"), exported)
        XCTAssertTrue(exported.contains("NONZERO_PRIMARY_SENTINEL"), exported)
        XCTAssertTrue(allExported.contains("SlotSevenEntry"), allExported)
        XCTAssertTrue(allExported.contains("NONZERO_PRIMARY_SENTINEL"), allExported)
    }

    func testRequestedImageWithoutAnalysisAbstainsInsteadOfBorrowingPrimary() {
        var analysisA = ImageAnalysis()
        analysisA.functions = [function(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1",
            name: "_shared_entry",
            start: collidingAddress,
            end: collidingAddress + 4
        )]
        analysisA.instructions = [instruction(
            collidingAddress,
            mnemonic: "udf",
            operands: "#1",
            comment: "A_SENTINEL"
        )]
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: slotA), image(slot: slotB)],
            analysisBySlot: [slotA: analysisA],
            typeDefinitions: [workspaceType]
        )

        let input = snapshot.pseudocodeRenderInput(selectedAddress: collidingAddress, in: slotB)
        XCTAssertEqual(input.imageSlot, slotB)
        XCTAssertEqual(input.functionName, "_main")
        XCTAssertNil(input.startAddress)
        XCTAssertTrue(input.jumpTables.isEmpty)
        XCTAssertTrue(input.objcSelectors.isEmpty)
        XCTAssertTrue(input.nameOverrides.isEmpty)
        XCTAssertTrue(input.signatureOverrides.isEmpty)
        XCTAssertTrue(input.registerNameOverrides.isEmpty)
        XCTAssertEqual(input.types, [workspaceType])
        XCTAssertTrue(input.instructions.isEmpty)
        XCTAssertEqual(
            DocumentExportService().renderPseudocode(
                snapshot: snapshot,
                selectedAddress: collidingAddress,
                in: slotB
            ),
            ""
        )
        XCTAssertEqual(
            DocumentExportService().renderAllPseudocode(snapshot: snapshot, in: slotB),
            ""
        )
    }

    private func collisionSnapshot(includeSiblingSwitchHint: Bool) -> WorkspaceSnapshot {
        var analysisA = ImageAnalysis()
        analysisA.functions = [
            function(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1",
                name: "_shared_entry",
                start: collidingAddress,
                end: collidingAddress + 0x18
            ),
            function(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2",
                name: "_shared_helper",
                start: helperAddress,
                end: helperAddress + 4
            ),
            function(
                id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA4",
                name: "_a_only_function",
                start: primaryOnlyFunctionAddress,
                end: primaryOnlyFunctionAddress + 4
            ),
        ]
        // A deliberately has no row at +4, making B's +4 row an unambiguous navigation oracle.
        analysisA.instructions = [
            instruction(collidingAddress, mnemonic: "udf", operands: "#1", comment: "A_SENTINEL"),
            instruction(
                primaryOnlyFunctionAddress,
                mnemonic: "udf",
                operands: "#8",
                comment: "A_ONLY_ALL_SENTINEL"
            ),
        ]
        analysisA.jumpTables = [
            dispatchAddress: [0xA800],
            automaticDispatchAddress: [0xA900],
        ]
        analysisA.objcSelectors = [selectorReference: "aSelector:"]
        analysisA.stringLiterals = [StringLiteralSummary(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA3")!,
            value: "A_LITERAL",
            address: primaryLiteralAddress,
            sourceSection: "__cstring",
            byteLength: 10
        )]
        analysisA.sections = [tableSection()]
        analysisA.imageBytes = littleEndianAbsoluteTargets([0xA010, 0xA020])

        var analysisB = ImageAnalysis()
        analysisB.functions = [
            function(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1",
                name: "_shared_entry",
                start: collidingAddress,
                end: collidingAddress + 0x1c
            ),
            function(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB2",
                name: "_shared_helper",
                start: helperAddress,
                end: helperAddress + 4
            ),
            function(
                id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB4",
                name: "_b_only_function",
                start: siblingOnlyFunctionAddress,
                end: siblingOnlyFunctionAddress + 4
            ),
        ]
        analysisB.instructions = [
            instruction(collidingAddress, mnemonic: "udf", operands: "#2", comment: "B_SENTINEL"),
            instruction(
                collidingAddress + 4,
                mnemonic: "add",
                operands: "x19, x19, #1",
                comment: "B_ONLY_STEP"
            ),
            instruction(collidingAddress + 8, mnemonic: "udf", operands: "#4", comment: "B_IS_DATA"),
            instruction(collidingAddress + 12, mnemonic: "udf", operands: "#5", comment: "B_DATA_SHAPE"),
            instruction(collidingAddress + 16, mnemonic: "udf", operands: "#6", comment: "B_UNDEFINED"),
            instruction(dispatchAddress, mnemonic: "br", operands: "x9", comment: "B_SWITCH"),
            instruction(
                callAddress,
                mnemonic: "bl",
                operands: "_shared_helper",
                comment: "B_HELPER_CALL"
            ),
            instruction(
                siblingOnlyFunctionAddress,
                mnemonic: "udf",
                operands: "#9",
                comment: "B_ONLY_ALL_SENTINEL"
            ),
        ]
        analysisB.jumpTables = [
            dispatchAddress: [0xB800],
            automaticDispatchAddress: [0xB900],
        ]
        analysisB.objcSelectors = [selectorReference: "bSelector:"]
        analysisB.stringLiterals = [StringLiteralSummary(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB3")!,
            value: "B_LITERAL",
            address: siblingLiteralAddress,
            sourceSection: "__cstring",
            byteLength: 10
        )]
        analysisB.sections = [tableSection()]
        analysisB.imageBytes = littleEndianAbsoluteTargets([0xB010, 0xB020])

        var overrides: [ImageAddress: AddressOverride] = [
            ImageAddress(slot: slotA, address: collidingAddress): AddressOverride(
                customName: "AProcedure",
                signature: signatureA,
                registerNames: ["x19": "a_counter"]
            ),
            ImageAddress(slot: slotA, address: helperAddress): AddressOverride(customName: "AHelper"),
            ImageAddress(slot: slotA, address: collidingAddress + 4): AddressOverride(isData: true),
            ImageAddress(slot: slotB, address: collidingAddress): AddressOverride(
                customName: "BProcedure",
                signature: signatureB,
                registerNames: ["x19": "b_counter"]
            ),
            ImageAddress(slot: slotB, address: helperAddress): AddressOverride(customName: "BHelper"),
            ImageAddress(slot: slotB, address: collidingAddress + 8): AddressOverride(isData: true),
            ImageAddress(slot: slotB, address: collidingAddress + 12): AddressOverride(
                dataShape: DataShapeOverride(
                    kind: .string,
                    isNullTerminated: false,
                    stringLength: 4
                )
            ),
            ImageAddress(slot: slotB, address: collidingAddress + 16): AddressOverride(isUndefined: true),
        ]
        if includeSiblingSwitchHint {
            overrides[ImageAddress(slot: slotB, address: dispatchAddress)] = AddressOverride(
                switchHint: SwitchHintOverride(
                    tableBase: tableBase,
                    entryCount: 2,
                    entryStride: 8,
                    isRelativeToBase: false
                )
            )
        }

        return WorkspaceSnapshot(
            binaries: [image(slot: slotA), image(slot: slotB)],
            analysisBySlot: [slotA: analysisA, slotB: analysisB],
            addressOverrides: overrides,
            typeDefinitions: [workspaceType]
        )
    }

    private func function(
        id: String,
        name: String,
        start: UInt64,
        end: UInt64
    ) -> FunctionSummary {
        FunctionSummary(
            id: UUID(uuidString: id)!,
            name: name,
            startAddress: start,
            endAddress: end,
            confidence: 1
        )
    }

    private func instruction(
        _ address: UInt64,
        mnemonic: String,
        operands: String,
        comment: String
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: operands,
            hasBreakpoint: false,
            comment: comment
        )
    }

    private func tableSection() -> SectionSummary {
        SectionSummary(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            name: "__DATA,__const",
            address: tableBase,
            size: 16,
            fileOffset: 0,
            isExecutable: false
        )
    }

    private func littleEndianAbsoluteTargets(_ targets: [UInt64]) -> Data {
        Data(targets.flatMap { target in
            (0..<8).map { byteIndex in
                UInt8(truncatingIfNeeded: target >> (byteIndex * 8))
            }
        })
    }

    private func image(slot: ImageSlot) -> BinaryImage {
        BinaryImage(
            id: slot == slotA
                ? UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
                : UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            name: "image\(slot.rawValue)",
            path: "/tmp/image\(slot.rawValue)",
            kind: "executable",
            architecture: "arm64",
            slot: slot
        )
    }
}
