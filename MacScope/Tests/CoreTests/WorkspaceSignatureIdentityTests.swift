import Foundation
import XCTest
@testable import MacScope

final class WorkspaceSignatureIdentityTests: XCTestCase {
    private let functionAddress = 0x1000_00000 as UInt64

    @MainActor
    func testUnchangedRecoveredDraftRemainsUnspecified() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(functionAddress)

        store.beginSignatureEditAtSelection()
        let draft = try XCTUnwrap(store.signatureEditorRequest)
        XCTAssertEqual(draft.parameterListIntent, .inherited)

        store.commitSignatureEditor(draft)

        XCTAssertNil(
            store.snapshot.addressOverrides[.primary(functionAddress)]?.signature,
            "merely opening and accepting recovered types must not author an override"
        )
    }

    @MainActor
    func testExplicitVoidSurvivesOpenAndCommit() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.setSignature(functionAddress, FunctionSignatureOverride(args: []))
        store.selectInstruction(functionAddress)

        store.beginSignatureEditAtSelection()
        let draft = try XCTUnwrap(store.signatureEditorRequest)
        XCTAssertEqual(draft.parameterListIntent, .authoritative)
        XCTAssertTrue(draft.args.isEmpty)

        store.commitSignatureEditor(draft)

        let committed = try XCTUnwrap(store.snapshot.addressOverrides[.primary(functionAddress)]?.signature)
        guard case let .authoritative(rows) = committed.parameterList else {
            return XCTFail("an explicit empty parameter list must not collapse to unspecified")
        }
        XCTAssertTrue(rows.isEmpty)
    }

    @MainActor
    func testRecoveredEmptyListCanBeExplicitlyPromotedToVoid() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(functionAddress)
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)
        XCTAssertTrue(draft.args.isEmpty)

        draft.parameterListIntent = .authoritative
        draft.variadicState = .fixed
        store.commitSignatureEditor(draft)

        let committed = try XCTUnwrap(store.snapshot.addressOverrides[.primary(functionAddress)]?.signature)
        guard case let .authoritative(rows) = committed.parameterList else {
            return XCTFail("the editor's explicit-void intent must author an empty list")
        }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(committed.variadicState, .fixed)
    }

    @MainActor
    func testEditorPersistsDeclaratorStateIndependentlyOfRecoveredRows() throws {
        let store = makeRecoveredParameterStore(address: functionAddress)
        store.selectInstruction(functionAddress)
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)

        XCTAssertEqual(draft.parameterListIntent, .inherited)
        XCTAssertEqual(draft.variadicState, .unspecified)
        draft.variadicState = .variadic
        store.commitSignatureEditor(draft)

        let committed = try XCTUnwrap(
            store.snapshot.addressOverrides[.primary(functionAddress)]?.signature
        )
        guard case .unspecified = committed.parameterList else {
            return XCTFail("declarator state must not promote recovered rows")
        }
        XCTAssertEqual(committed.variadicState, .variadic)
    }

    func testNoReturnSetAndClearHaveDistinctSemanticIdentity() throws {
        let signatures = [
            FunctionSignatureOverride(noReturnState: .unspecified),
            FunctionSignatureOverride(noReturnState: .returns),
            FunctionSignatureOverride(noReturnState: .noReturn),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let semanticEncodings = try signatures.map(encoder.encode)

        XCTAssertEqual(
            Set(semanticEncodings).count,
            3,
            "preserve, explicit clear, and explicit set must never collapse to one signature identity"
        )
        XCTAssertEqual(signatures.map(\.hasAnalysisEffect), [false, true, true])

        let quarantineOnlyEdit = FunctionSignatureOverride(
            quarantinedLegacyArgs: [
                LegacyArgOverride(
                    originalIndex: 4,
                    originalOrder: 0,
                    name: "ambiguous",
                    type: "double"
                ),
            ],
            noReturnState: .unspecified
        )
        XCTAssertFalse(
            quarantineOnlyEdit.hasAnalysisEffect,
            "changing quarantine evidence alone must remain semantically inert"
        )
    }

    @MainActor
    func testRecoveredSIMDRowTokenDoesNotMoveWhenAnUnrelatedGPRAppears() throws {
        let original = makeRecoveredParameterStore(
            address: functionAddress,
            instructions: [
                ("mov", "x8, x0"),
                ("fmov", "x9, d0"),
            ]
        )
        original.selectInstruction(functionAddress)
        original.beginSignatureEditAtSelection()
        let originalDraft = try XCTUnwrap(original.signatureEditorRequest)
        let originalSIMD = try XCTUnwrap(
            originalDraft.recoveredArgs.first { $0.name == "in_d0" }
        )

        let withUnrelatedGPR = makeRecoveredParameterStore(
            address: functionAddress,
            instructions: [
                ("add", "x8, x0, x1"),
                ("fmov", "x9, d0"),
            ]
        )
        withUnrelatedGPR.selectInstruction(functionAddress)
        withUnrelatedGPR.beginSignatureEditAtSelection()
        let expandedDraft = try XCTUnwrap(withUnrelatedGPR.signatureEditorRequest)
        let expandedSIMD = try XCTUnwrap(
            expandedDraft.recoveredArgs.first { $0.name == "in_d0" }
        )

        XCTAssertEqual(originalSIMD.rowToken, "recovered:simd:0")
        XCTAssertEqual(expandedSIMD.rowToken, "recovered:simd:0")
        XCTAssertEqual(
            originalSIMD.rowToken,
            expandedSIMD.rowToken,
            "editor recovery must preserve physical binding identity rather than the transitional compatibility index"
        )
    }

    @MainActor
    func testRowIdentityProvenanceAndSourceOrderSurviveEditing() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let first = ArgOverride(rowToken: "debug-row", name: "lhs", type: "int", provenance: .debug)
        let removed = ArgOverride(rowToken: "removed-row", name: "middle", type: "short", provenance: .script)
        let last = ArgOverride(rowToken: "user-row", name: "rhs", type: "long", provenance: .user)
        store.setSignature(
            functionAddress,
            FunctionSignatureOverride(parameterList: .authoritative([first, removed, last]), variadicState: .fixed)
        )
        store.selectInstruction(functionAddress)
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)

        XCTAssertEqual(draft.args.map(\.rowToken), ["debug-row", "removed-row", "user-row"])
        XCTAssertEqual(draft.args.map(\.provenance), [.debug, .script, .user])

        draft.args[0].name = "renamed_lhs"
        draft.args[0].type = "const int *"
        draft.args.remove(at: 1)
        draft.args.swapAt(0, 1)
        draft.args.append(ArgDraft(index: 2, name: "added", type: "double"))
        let addedToken = try XCTUnwrap(draft.args.last?.rowToken)
        store.commitSignatureEditor(draft)

        let committed = try XCTUnwrap(store.snapshot.addressOverrides[.primary(functionAddress)]?.signature)
        XCTAssertEqual(committed.args.map(\.rowToken), ["user-row", "debug-row", addedToken])
        XCTAssertEqual(
            committed.args.map(\.provenance),
            [.user, .user, .user],
            "explicitly editing or reordering a declaration makes the declaration user-authored"
        )
        XCTAssertEqual(committed.args.map(\.name), ["rhs", "renamed_lhs", "added"])
        XCTAssertEqual(committed.args.map(\.type), ["long", "const int *", "double"])
        XCTAssertEqual(committed.args.map(\.index), [0, 1, 2])
    }

    @MainActor
    func testRecreatedRowAtSameIndexMintsFreshIdentityAndPersistsSourceOrder() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let surviving = ArgOverride(
            rowToken: "surviving-row", name: "head", type: "int", provenance: .user
        )
        let deleted = ArgOverride(index: 1, name: "tail", type: "double")
        store.setSignature(
            functionAddress,
            FunctionSignatureOverride(parameterList: .authoritative([surviving, deleted]), variadicState: .fixed)
        )
        store.selectInstruction(functionAddress)
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)

        let deletedToken = draft.args.removeLast().rowToken
        draft.args.append(ArgDraft(index: 1, name: "tail", type: "double"))
        let recreatedToken = try XCTUnwrap(draft.args.last?.rowToken)

        XCTAssertNotEqual(
            recreatedToken,
            deletedToken,
            "a newly created row must not inherit a deleted row's compatibility identity"
        )

        store.commitSignatureEditor(draft)

        let committed = try XCTUnwrap(store.snapshot.addressOverrides[.primary(functionAddress)]?.signature)
        XCTAssertEqual(committed.args.map(\.name), ["head", "tail"])
        XCTAssertEqual(committed.args.map(\.index), [0, 1])
        XCTAssertEqual(committed.args.map(\.rowToken), ["surviving-row", recreatedToken])
    }

    @MainActor
    func testAuthoritativeVoidKeepsActualRecoveredPreviewSeparate() throws {
        let store = makeRecoveredParameterStore(address: functionAddress)
        store.setSignature(
            functionAddress,
            FunctionSignatureOverride(parameterList: .authoritative([]), variadicState: .fixed)
        )
        store.selectInstruction(functionAddress)

        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)

        XCTAssertEqual(draft.parameterListIntent, .authoritative)
        XCTAssertTrue(draft.args.isEmpty, "authored (void) must remain the active editable declaration")
        XCTAssertTrue(draft.baselineArgs.isEmpty, "the authored baseline must remain distinct from recovery")
        XCTAssertEqual(draft.recoveredArgs.map(\.index), [0])
        let recoveredPreview = draft.recoveredArgs

        draft.args.append(ArgDraft(index: 0, name: "authored", type: "uint64_t"))
        XCTAssertEqual(
            draft.recoveredArgs,
            recoveredPreview,
            "editing authored rows must not overwrite the actual recovered preview"
        )
    }

    @MainActor
    func testQuarantineStaysInactiveUntilExplicitAdoption() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let quarantined = [
            LegacyArgOverride(originalIndex: 4, originalOrder: 0, name: "tail", type: "double"),
            LegacyArgOverride(originalIndex: 0, originalOrder: 1, name: "head", type: "int"),
        ]
        store.setSignature(functionAddress, FunctionSignatureOverride(quarantinedLegacyArgs: quarantined))
        store.selectInstruction(functionAddress)
        store.beginSignatureEditAtSelection()
        let unchanged = try XCTUnwrap(store.signatureEditorRequest)

        XCTAssertEqual(unchanged.parameterListIntent, .inherited)
        XCTAssertEqual(unchanged.quarantinedLegacyArgs, quarantined)
        XCTAssertTrue(unchanged.args.isEmpty, "quarantined rows must not enter the active draft")
        store.commitSignatureEditor(unchanged)

        var persisted = try XCTUnwrap(store.snapshot.addressOverrides[.primary(functionAddress)]?.signature)
        guard case .unspecified = persisted.parameterList else {
            return XCTFail("quarantine alone must remain analysis-inactive")
        }
        XCTAssertEqual(persisted.quarantinedLegacyArgs, quarantined)

        store.selectInstruction(functionAddress)
        store.beginSignatureEditAtSelection()
        var adopting = try XCTUnwrap(store.signatureEditorRequest)
        adopting.adoptQuarantinedLegacyArguments()
        store.commitSignatureEditor(adopting)

        persisted = try XCTUnwrap(store.snapshot.addressOverrides[.primary(functionAddress)]?.signature)
        XCTAssertEqual(persisted.args.map(\.name), ["tail", "head"])
        XCTAssertEqual(persisted.args.map(\.provenance), [.user, .user])
        XCTAssertTrue(persisted.quarantinedLegacyArgs.isEmpty)
    }

    @MainActor
    func testEditorRecoveryExcludesEveryUserDeclaredNonCodeKind() throws {
        let exclusions = [
            AddressOverride(isData: true),
            AddressOverride(isUndefined: true),
            AddressOverride(dataShape: DataShapeOverride(
                kind: .array, elementType: "uint32_t", elementCount: 1
            )),
        ]

        for exclusion in exclusions {
            let store = makeRecoveredParameterStore(address: functionAddress)
            store.snapshot.addressOverrides[.primary(functionAddress)] = exclusion
            store.selectInstruction(functionAddress)
            store.beginSignatureEditAtSelection()

            let draft = try XCTUnwrap(store.signatureEditorRequest)
            XCTAssertTrue(
                draft.recoveredArgs.isEmpty,
                "data, undefined, and shaped-data rows must never seed recovered parameters"
            )
        }
    }

    @MainActor
    func testUnchangedDebugDeclarationPreservesDebugProvenanceButUserReorderDoesNot() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let imported = FunctionSignatureOverride.authoritative(
            args: [
                ArgOverride(rowToken: "debug-a", name: "lhs", type: "int", provenance: .debug),
                ArgOverride(rowToken: "debug-b", name: "rhs", type: "double", provenance: .debug),
            ]
        )
        store.setSignature(functionAddress, imported)
        store.selectInstruction(functionAddress)
        store.beginSignatureEditAtSelection()
        let unchanged = try XCTUnwrap(store.signatureEditorRequest)
        store.commitSignatureEditor(unchanged)

        var persisted = try XCTUnwrap(
            store.snapshot.addressOverrides[.primary(functionAddress)]?.signature
        )
        XCTAssertEqual(persisted.args.map(\.provenance), [.debug, .debug])

        store.selectInstruction(functionAddress)
        store.beginSignatureEditAtSelection()
        var edited = try XCTUnwrap(store.signatureEditorRequest)
        edited.args.swapAt(0, 1)
        edited.args[0].name = "renamed_rhs"
        store.commitSignatureEditor(edited)

        persisted = try XCTUnwrap(
            store.snapshot.addressOverrides[.primary(functionAddress)]?.signature
        )
        XCTAssertEqual(persisted.args.map(\.rowToken), ["debug-b", "debug-a"])
        XCTAssertEqual(persisted.args.map(\.provenance), [.user, .user])
    }

    @MainActor
    func testFocusedImageOwnsBothEditorReadAndDelayedCommit() throws {
        let sibling = ImageSlot(rawValue: 1)
        let address = 0x5000 as UInt64
        let primarySignature = FunctionSignatureOverride(args: [
            ArgOverride(rowToken: "primary", name: "from_a", type: "int", provenance: .user),
        ])
        let siblingSignature = FunctionSignatureOverride(args: [
            ArgOverride(rowToken: "sibling", name: "from_b", type: "double", provenance: .debug),
        ])
        let store = makeCollidingStore(
            address: address,
            primarySignature: primarySignature,
            siblingSignature: siblingSignature
        )

        store.focusImage(sibling)
        store.selectInstruction(address)
        store.beginSignatureEditAtSelection()
        var draft = try XCTUnwrap(store.signatureEditorRequest)
        XCTAssertEqual(draft.imageSlot, sibling)
        XCTAssertEqual(draft.args.map(\.rowToken), ["sibling"])

        draft.args[0].name = "edited_in_b"
        store.focusImage(.primary)
        store.commitSignatureEditor(draft)

        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.signature, primarySignature)
        XCTAssertEqual(
            store.snapshot.addressOverrides[ImageAddress(slot: sibling, address: address)]?.signature?.args.first?.name,
            "edited_in_b"
        )
    }

    @MainActor
    func testClearOverrideTargetsOpeningImageAndPreservesSiblingFields() throws {
        let sibling = ImageSlot(rawValue: 1)
        let address = 0x5000 as UInt64
        let primarySignature = FunctionSignatureOverride(args: [
            ArgOverride(rowToken: "primary", name: "from_a", type: "int", provenance: .user),
        ])
        let siblingSignature = FunctionSignatureOverride(args: [
            ArgOverride(rowToken: "sibling", name: "from_b", type: "double", provenance: .debug),
        ])
        let store = makeCollidingStore(
            address: address,
            primarySignature: primarySignature,
            siblingSignature: siblingSignature
        )

        store.focusImage(sibling)
        store.applyOverride(
            address,
            AddressOverride(customName: "keep_name", signature: siblingSignature),
            actionName: "Seed sibling fields"
        )
        store.selectInstruction(address)
        store.beginSignatureEditAtSelection()
        let draft = try XCTUnwrap(store.signatureEditorRequest)

        store.focusImage(.primary)
        store.clearSignatureEditorOverride(draft)

        XCTAssertNil(store.signatureEditorRequest)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.signature, primarySignature)
        let siblingOverride = try XCTUnwrap(
            store.snapshot.addressOverrides[ImageAddress(slot: sibling, address: address)]
        )
        XCTAssertNil(siblingOverride.signature)
        XCTAssertEqual(siblingOverride.customName, "keep_name")

        XCTAssertTrue(store.undoManager.canUndo)
        store.undoManager.undo()
        let restored = try XCTUnwrap(
            store.snapshot.addressOverrides[ImageAddress(slot: sibling, address: address)]
        )
        XCTAssertEqual(restored.signature, siblingSignature)
        XCTAssertEqual(restored.customName, "keep_name")
    }

    @MainActor
    func testExistingSignatureWinsOverLaterDebugSymbolImport() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let authored = FunctionSignatureOverride(args: [
            ArgOverride(rowToken: "authored", name: "context", type: "Context *", provenance: .user),
        ])
        let recovered = FunctionSignatureOverride(args: [
            ArgOverride(rowToken: "debug", name: "value", type: "int", provenance: .debug),
        ])
        store.setSignature(functionAddress, authored)

        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: functionAddress, name: "debug_name")],
            signatures: [functionAddress: recovered],
            matchedUUID: "test-uuid",
            dwarfURL: URL(fileURLWithPath: "/tmp/test.dSYM/Contents/Resources/DWARF/test")
        )
        XCTAssertEqual(store.injectDebugSymbols(result), 1)

        XCTAssertEqual(store.snapshot.addressOverrides[.primary(functionAddress)]?.signature, authored)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(functionAddress)]?.customName, "debug_name")
    }

    @MainActor
    func testQuarantineOnlyLegacyPayloadDoesNotBlockRecoveredDebugSignature() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let quarantine = [
            LegacyArgOverride(
                originalIndex: 4, originalOrder: 0, name: "ambiguous", type: "double"
            ),
        ]
        store.setSignature(
            functionAddress,
            FunctionSignatureOverride(quarantinedLegacyArgs: quarantine)
        )
        let recovered = FunctionSignatureOverride.authoritative(
            returnType: "int",
            args: [
                ArgOverride(
                    rowToken: "debug", name: "value", type: "int", provenance: .debug
                ),
            ]
        )
        let result = DSYMImportResult(
            functions: [DWARFFunctionSymbol(address: functionAddress, name: "debug_name")],
            signatures: [functionAddress: recovered],
            matchedUUID: "test-uuid",
            dwarfURL: URL(fileURLWithPath: "/tmp/test.dSYM/Contents/Resources/DWARF/test")
        )

        XCTAssertEqual(store.injectDebugSymbols(result), 1)

        let persisted = try XCTUnwrap(
            store.snapshot.addressOverrides[.primary(functionAddress)]?.signature
        )
        XCTAssertEqual(persisted.returnType, recovered.returnType)
        XCTAssertEqual(persisted.args, recovered.args)
        XCTAssertEqual(persisted.quarantinedLegacyArgs, quarantine)
        XCTAssertTrue(persisted.hasAnalysisEffect)
    }

    @MainActor
    private func makeCollidingStore(
        address: UInt64,
        primarySignature: FunctionSignatureOverride,
        siblingSignature: FunctionSignatureOverride
    ) -> WorkspaceStore {
        func image(slot: ImageSlot) -> BinaryImage {
            BinaryImage(
                id: UUID(), name: "image-\(slot.rawValue)", path: "/tmp/image-\(slot.rawValue)",
                kind: "executable", architecture: "arm64", slot: slot
            )
        }
        func analysis(name: String, jumpTarget: UInt64) -> ImageAnalysis {
            var result = ImageAnalysis()
            result.functions = [FunctionSummary(
                id: UUID(), name: name, startAddress: address, endAddress: address + 4, confidence: 1
            )]
            result.instructions = [InstructionRow(
                address: address, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "",
                hasBreakpoint: false, comment: name
            )]
            result.jumpTables = [address: [jumpTarget]]
            return result
        }

        let sibling = ImageSlot(rawValue: 1)
        let snapshot = WorkspaceSnapshot(
            binaries: [image(slot: .primary), image(slot: sibling)],
            analysisBySlot: [
                .primary: analysis(name: "primary", jumpTarget: 0x6000),
                sibling: analysis(name: "sibling", jumpTarget: 0x7000),
            ],
            addressOverrides: [
                .primary(address): AddressOverride(signature: primarySignature),
                ImageAddress(slot: sibling, address: address): AddressOverride(signature: siblingSignature),
            ]
        )
        return WorkspaceStore(
            workspaceName: "Signature Identity", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
    }

    @MainActor
    private func makeRecoveredParameterStore(address: UInt64) -> WorkspaceStore {
        makeRecoveredParameterStore(
            address: address,
            instructions: [("mov", "x2, x0")]
        )
    }

    @MainActor
    private func makeRecoveredParameterStore(
        address: UInt64,
        instructions: [(mnemonic: String, operands: String)]
    ) -> WorkspaceStore {
        let image = BinaryImage(
            id: UUID(), name: "recovered", path: "/tmp/recovered", kind: "executable",
            architecture: "arm64", slot: .primary
        )
        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(
            id: UUID(), name: "recovered", startAddress: address,
            endAddress: address + 8, confidence: 1
        )]
        analysis.instructions = instructions.enumerated().map { offset, instruction in
            InstructionRow(
                address: address + UInt64(offset * 4), bytes: "", mnemonic: instruction.mnemonic,
                operands: instruction.operands, hasBreakpoint: false,
                comment: "consume recovered input"
            )
        }
        analysis.instructions.append(
            InstructionRow(
                address: address + UInt64(instructions.count * 4), bytes: "c0 03 5f d6",
                mnemonic: "ret", operands: "", hasBreakpoint: false, comment: "return"
            )
        )
        analysis.functions[0].endAddress = address + UInt64((instructions.count + 1) * 4)
        return WorkspaceStore(
            workspaceName: "Recovered Signature Preview",
            snapshot: WorkspaceSnapshot(binaries: [image], analysisBySlot: [.primary: analysis]),
            engine: AnalysisEngine(), autosaveScheduler: nil
        )
    }
}
