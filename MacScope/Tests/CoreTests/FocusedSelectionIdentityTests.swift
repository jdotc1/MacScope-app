import Combine
import XCTest
@testable import MacScope

/// WS-17 RED oracles for making an interactive selection belong to one exact image.
///
/// The fixture deliberately gives primary image A and sibling image B colliding virtual
/// addresses. A passing result may therefore never be explained by address equality alone: the
/// selected row must come from the analysis bucket owned by the focused image.
final class FocusedSelectionIdentityTests: XCTestCase {
    private let slotA = ImageSlot.primary
    private let slotB = ImageSlot(rawValue: 1)
    private let slotWithoutAnalysis = ImageSlot(rawValue: 2)
    private let remappedSlotB = ImageSlot(rawValue: 7)
    private let absentSlot = ImageSlot(rawValue: 99)

    private let collidingAddress: UInt64 = 0x1_0000_1000
    private let bOnlyAddress: UInt64 = 0x1_0000_1100
    private let mappedUndecodedAddress: UInt64 = 0x1_0000_1200
    private let collidingStringAddress: UInt64 = 0x1_0000_1280
    private let outOfRangeAddress: UInt64 = 0x2_0000_0000

    private let primaryFunctionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!
    private let primaryStringID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2")!
    private let primarySymbolID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA4")!
    private let primaryExportID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA5")!
    private let primaryXRefID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA6")!

    @MainActor
    func testCollidingSelectionResolvesFocusedSiblingInstruction() {
        let store = makeStore()
        store.focusImage(slotB)
        store.selectInstruction(collidingAddress)

        XCTAssertEqual(store.focusedImageSlot, slotB)
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: collidingAddress)
        )
        XCTAssertEqual(store.selectedAddress, collidingAddress)
        XCTAssertEqual(
            store.selectedInstruction?.comment,
            "B_COLLIDING_SENTINEL",
            "a B selection must never resolve A's decoded row at the same virtual address"
        )
        XCTAssertEqual(store.selectedInstruction?.mnemonic, "b_collision")
    }

    @MainActor
    func testBOnlySelectionResolvesBInstructionWithoutPrimaryEvidence() {
        let store = makeStore()
        XCTAssertFalse(store.snapshot.instructions.contains { $0.address == bOnlyAddress })

        store.focusImage(slotB)
        store.selectInstruction(bOnlyAddress)

        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: bOnlyAddress)
        )
        XCTAssertEqual(store.selectedAddress, bOnlyAddress)
        XCTAssertEqual(store.selectedInstruction?.comment, "B_ONLY_SENTINEL")
        XCTAssertEqual(store.selectedInstruction?.mnemonic, "b_only")
    }

    @MainActor
    func testMappedUndecodedBSelectionRetainsAddressWithoutBorrowingAInstruction() {
        let store = makeStore()
        XCTAssertTrue(store.snapshot.containsLoadedAddress(mappedUndecodedAddress, in: slotB))
        XCTAssertFalse(
            store.snapshot.analysis(in: slotB)?.instructions.contains {
                $0.address == mappedUndecodedAddress
            } ?? true,
            "the B control must be mapped but intentionally undecoded"
        )
        XCTAssertEqual(
            store.snapshot.instructions.first { $0.address == mappedUndecodedAddress }?.comment,
            "A_MAPPED_COLLISION_SENTINEL",
            "A deliberately has a decoded collision capable of exposing an unsafe fallback"
        )

        store.focusImage(slotB)
        store.selectInstruction(mappedUndecodedAddress)

        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: mappedUndecodedAddress)
        )
        XCTAssertEqual(
            store.selectedAddress,
            mappedUndecodedAddress,
            "mapped address-only selections remain valid without a decoded row"
        )
        XCTAssertNil(
            store.selectedInstruction,
            "instruction-only consumers must abstain instead of borrowing A's colliding row"
        )
    }

    @MainActor
    func testFocusChangeClearsOldSelectionBeforeSiblingSelection() {
        let store = makeStore()
        store.selectInstruction(collidingAddress)
        XCTAssertEqual(store.selectedInstruction?.comment, "A_COLLIDING_SENTINEL")
        store.xrefCursor = XRefStepCursor(anchor: collidingAddress, froms: [bOnlyAddress])
        var observedIdentity: [(ImageSlot, ImageAddress?)] = []
        let observation = Publishers.CombineLatest3(
            store.$snapshot,
            store.$focusedImageSlotStorage,
            store.$selectedImageAddress
        ).sink { value in
            let (snapshot, focusStorage, selection) = value
            let resolvedFocus = snapshot.binary(in: focusStorage) != nil
                ? focusStorage
                : snapshot.primarySlot
            observedIdentity.append((resolvedFocus, selection))
        }

        store.focusImage(slotB)

        XCTAssertEqual(store.focusedImageSlot, slotB)
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(store.selectedAddress)
        XCTAssertNil(store.selectedInstruction)
        XCTAssertNil(store.selectedGraphElementID)
        XCTAssertNil(store.xrefCursor)
        XCTAssertFalse(
            observedIdentity.contains { value in
                let (focus, selection) = value
                return selection.map { $0.slot != focus } ?? false
            },
            "focus publication must never pair B with A's still-live selection"
        )
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testRemovedSelectionOwnerClearsInsteadOfRebindingCollisionToPrimary() {
        let store = makeStore()
        store.focusImage(slotB)
        store.selectInstruction(collidingAddress)
        store.xrefCursor = XRefStepCursor(anchor: collidingAddress, froms: [bOnlyAddress])

        store.snapshot.removeImage(in: slotB)

        XCTAssertEqual(store.focusedImageSlot, slotA)
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(
            store.selectedAddress,
            "removing B must clear B's coordinate even though A contains the same virtual address"
        )
        XCTAssertNil(store.selectedInstruction)
        XCTAssertNil(store.xrefCursor)
    }

    @MainActor
    func testRemappedSelectionOwnerMovesFocusAndSelectionAtomically() {
        let store = makeStore()
        store.focusImage(slotB)
        store.selectInstruction(collidingAddress)
        store.xrefCursor = XRefStepCursor(anchor: collidingAddress, froms: [bOnlyAddress])
        var observedIdentity: [(ImageSlot, ImageAddress?)] = []
        let observation = Publishers.CombineLatest3(
            store.$snapshot,
            store.$focusedImageSlotStorage,
            store.$selectedImageAddress
        ).sink { value in
            let (snapshot, focusStorage, selection) = value
            let resolvedFocus = snapshot.binary(in: focusStorage) != nil
                ? focusStorage
                : snapshot.primarySlot
            observedIdentity.append((resolvedFocus, selection))
        }

        store.remapImageSlot(from: slotB, to: remappedSlotB)

        XCTAssertEqual(store.focusedImageSlot, remappedSlotB)
        XCTAssertNil(store.snapshot.binary(in: slotB))
        XCTAssertNotNil(store.snapshot.binary(in: remappedSlotB))
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: remappedSlotB, address: collidingAddress)
        )
        XCTAssertEqual(store.selectedAddress, collidingAddress)
        XCTAssertEqual(
            store.selectedInstruction?.comment,
            "B_COLLIDING_SENTINEL",
            "a slot remap must preserve the selected owner instead of falling back to primary"
        )
        XCTAssertNil(store.xrefCursor)
        XCTAssertFalse(
            observedIdentity.contains { value in
                let (focus, selection) = value
                return selection.map { $0.slot != focus } ?? false
            },
            "slot remap publication must never expose a selection owned by a different slot"
        )
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testValidPersistedSiblingFocusAndSelectionRoundTripExactly() throws {
        let restored = try restoredStore(
            snapshot: makeSnapshot(),
            focusedImageSlot: slotB,
            selectedAddress: collidingAddress
        )

        XCTAssertEqual(restored.focusedImageSlot, slotB)
        XCTAssertEqual(
            restored.selectedImageAddress,
            ImageAddress(slot: slotB, address: collidingAddress)
        )
        XCTAssertEqual(restored.selectedAddress, collidingAddress)
        XCTAssertEqual(restored.selectedInstruction?.comment, "B_COLLIDING_SENTINEL")
    }

    @MainActor
    func testOutOfRangePersistedSiblingAddressAbstainsWithoutPrimaryFallback() throws {
        let restored = try restoredStore(
            snapshot: makeSnapshot(),
            focusedImageSlot: slotB,
            selectedAddress: outOfRangeAddress
        )

        XCTAssertEqual(restored.focusedImageSlot, slotB)
        XCTAssertNil(restored.selectedImageAddress)
        XCTAssertNil(restored.selectedAddress)
        XCTAssertNil(restored.selectedInstruction)
    }

    @MainActor
    func testMissingPersistedSelectionOwnerClearsInsteadOfRebindingToPrimary() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        var snapshot = makeSnapshot()
        snapshot.removeImage(in: slotB)
        snapshot.removeImage(in: slotWithoutAnalysis)
        let persisted = try database.createWorkspaceState(
            workspaceName: "Missing persisted selection owner",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: collidingAddress,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            focusedImageSlot: absentSlot
        )

        let restored = try XCTUnwrap(WorkspaceStore.restored(
            workspaceID: try XCTUnwrap(persisted.workspace.id),
            from: database
        ))

        XCTAssertEqual(restored.focusedImageSlot, slotA)
        XCTAssertNil(restored.selectedImageAddress)
        XCTAssertNil(
            restored.selectedAddress,
            "a missing persisted owner may clamp focus, but its coordinate must not survive"
        )
        XCTAssertNil(restored.selectedInstruction)
    }

    @MainActor
    func testLoadedImageWithoutAnalysisRejectsSelectionWithoutPrimaryFallback() {
        let store = makeStore()
        store.focusImage(slotWithoutAnalysis)

        XCTAssertEqual(store.focusedImageSlot, slotWithoutAnalysis)
        XCTAssertNil(store.focusedAnalysis)

        store.selectedAddress = collidingAddress

        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(store.selectedAddress)
        XCTAssertNil(store.selectedInstruction)
    }

    @MainActor
    func testOutOfRangeBareAssignmentClearsSelection() {
        let store = makeStore()
        store.focusImage(slotB)
        store.selectInstruction(bOnlyAddress)
        XCTAssertEqual(store.selectedAddress, bOnlyAddress)

        store.selectedAddress = outOfRangeAddress

        XCTAssertNil(store.selectedImageAddress)
        XCTAssertNil(store.selectedAddress)
        XCTAssertNil(store.selectedInstruction)
        XCTAssertNil(store.selectedGraphElementID)
    }

    @MainActor
    func testUnrelatedQualifiedSelectionClearsLegacyXRefCursor() {
        let store = makeStore()
        store.focusImage(slotB)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: slotB, address: collidingAddress)))
        store.xrefCursor = XRefStepCursor(anchor: collidingAddress, froms: [bOnlyAddress])

        XCTAssertTrue(store.selectAddress(
            ImageAddress(slot: slotB, address: mappedUndecodedAddress)
        ))

        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: mappedUndecodedAddress)
        )
        XCTAssertNil(store.xrefCursor)
    }

    @MainActor
    func testCollidingStringSelectionResolvesFocusedSiblingLiteral() {
        let store = makeStore()
        store.selectedTool = .strings
        store.focusImage(slotB)
        store.selectInstruction(collidingStringAddress)

        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: collidingStringAddress)
        )
        XCTAssertEqual(store.selectedAddress, collidingStringAddress)
        XCTAssertEqual(store.selectedStringLiteral?.value, "B_STRING_SENTINEL")
    }

    @MainActor
    func testFlatSnapshotCompatibilityRemainsPrimaryAfterSiblingSelection() {
        let store = makeStore()
        let primaryInstructions = store.snapshot.instructions
        let primaryFunctions = store.snapshot.functions
        let primaryStrings = store.snapshot.stringLiterals

        store.focusImage(slotB)
        store.selectInstruction(collidingAddress)

        XCTAssertEqual(store.focusedImageSlot, slotB)
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: collidingAddress)
        )
        XCTAssertEqual(store.snapshot.primarySlot, slotA)
        XCTAssertEqual(store.snapshot.instructions, primaryInstructions)
        XCTAssertEqual(store.snapshot.functions, primaryFunctions)
        XCTAssertEqual(store.snapshot.stringLiterals, primaryStrings)
        XCTAssertEqual(store.snapshot.instructions.first?.comment, "A_COLLIDING_SENTINEL")
        XCTAssertEqual(store.snapshot.functions.first?.name, "AProcedure")
        XCTAssertEqual(store.snapshot.stringLiterals.first?.value, "A_STRING_SENTINEL")
    }

    @MainActor
    func testPrimaryCompatibilitySidebarRowsNeverRebindIntoFocusedSibling() {
        let cases: [(itemID: String, address: UInt64, instructionComment: String?)] = [
            ("function:\(primaryFunctionID.uuidString)", collidingAddress, "A_COLLIDING_SENTINEL"),
            ("string:\(primaryStringID.uuidString)", collidingStringAddress, nil),
            ("symbol:\(primarySymbolID.uuidString)", collidingAddress, "A_COLLIDING_SENTINEL"),
            ("export:\(primaryExportID.uuidString)", collidingAddress, "A_COLLIDING_SENTINEL"),
            ("xref:\(primaryXRefID.uuidString)", collidingAddress, "A_COLLIDING_SENTINEL"),
        ]

        for testCase in cases {
            let store = makeStore()
            store.focusImage(slotB)
            store.selectInstruction(bOnlyAddress)

            store.activateSidebarItem(testCase.itemID)

            XCTAssertEqual(store.focusedImageSlot, slotA, testCase.itemID)
            XCTAssertEqual(
                store.selectedImageAddress,
                ImageAddress(slot: slotA, address: testCase.address),
                testCase.itemID
            )
            XCTAssertEqual(
                store.selectedInstruction?.comment,
                testCase.instructionComment,
                testCase.itemID
            )
        }
    }

    @MainActor
    func testStaleSidebarCallbackRejectsSameSlotBinaryReplacement() throws {
        let store = makeStore()
        let initialSidebarItemID = store.selectedSidebarItemID
        store.selectedAddress = nil
        let target = try XCTUnwrap(
            store.sidebarNavigationTarget(for: "function:\(primaryFunctionID.uuidString)")
        )
        var replacement = makeSnapshot()
        replacement.binaries[0] = image(
            slot: slotA,
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDD0")!,
            name: "Replacement A",
            path: "/tmp/macscope-ws17-replacement-a",
            binaryUUID: "DDDDDDDD-0000-0000-0000-000000000000"
        )
        store.snapshot = replacement

        XCTAssertFalse(store.activateSidebarItem(target))
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertEqual(store.selectedSidebarItemID, initialSidebarItemID)
    }

    @MainActor
    func testStaleSidebarCallbackRejectsRemovedEntityWithoutSelectingItsID() throws {
        let store = makeStore()
        let initialSidebarItemID = store.selectedSidebarItemID
        store.selectedAddress = nil
        let target = try XCTUnwrap(
            store.sidebarNavigationTarget(for: "function:\(primaryFunctionID.uuidString)")
        )
        store.snapshot.mutateAnalysis(in: slotA) { $0.functions = [] }

        XCTAssertFalse(store.activateSidebarItem(target))
        XCTAssertNil(store.selectedImageAddress)
        XCTAssertEqual(store.selectedSidebarItemID, initialSidebarItemID)
    }

    @MainActor
    func testGoToSymbolNameResolvesOnlyInsideFocusedImage() {
        let store = makeStore()
        store.focusImage(slotB)

        XCTAssertTrue(store.goTo(query: "shared_symbol"))
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: bOnlyAddress)
        )
        XCTAssertEqual(store.selectedInstruction?.comment, "B_ONLY_SENTINEL")

        XCTAssertTrue(store.goTo(query: "BOnlySymbol"))
        XCTAssertEqual(store.selectedAddress, bOnlyAddress)
        XCTAssertFalse(
            store.goTo(query: "AOnlySymbol"),
            "a primary-only symbol must not be borrowed while B is focused"
        )
    }

    @MainActor
    func testStaleDiagnosticCallbackCannotCrossFocusOrSurviveReanalysis() throws {
        let store = makeStore()
        let diagnostic = try XCTUnwrap(store.snapshot.analysis(in: slotA)?.diagnostics.first)
        let crossFocusTarget = try XCTUnwrap(
            store.diagnosticNavigationTarget(id: diagnostic.id, in: slotA)
        )

        store.focusImage(slotB)
        XCTAssertFalse(store.navigateToDiagnostic(crossFocusTarget))
        XCTAssertNil(store.selectedImageAddress)

        store.focusImage(slotA)
        let reanalysisTarget = try XCTUnwrap(
            store.diagnosticNavigationTarget(id: diagnostic.id, in: slotA)
        )
        store.snapshot.mutateAnalysis(in: slotA) { analysis in
            analysis.diagnostics = [AnalysisDiagnostic(
                severity: .warning,
                address: collidingAddress,
                kind: .unresolvedBranchTarget,
                message: "A_REPLACEMENT_DIAGNOSTIC",
                sourceCoordinate: AnalysisDiagnostic.SourceCoordinate(address: bOnlyAddress)
            )]
        }
        XCTAssertFalse(store.navigateToDiagnostic(reanalysisTarget))
        XCTAssertNil(store.selectedImageAddress)
    }

    @MainActor
    func testStaleDiagnosticCallbackRejectsSameSlotBinaryReplacement() throws {
        let store = makeStore()
        store.selectedAddress = nil
        let diagnostic = try XCTUnwrap(store.snapshot.analysis(in: slotA)?.diagnostics.first)
        let target = try XCTUnwrap(
            store.diagnosticNavigationTarget(id: diagnostic.id, in: slotA)
        )
        var replacement = makeSnapshot()
        replacement.binaries[0] = image(
            slot: slotA,
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDD0")!,
            name: "Replacement A",
            path: "/tmp/macscope-ws17-replacement-a",
            binaryUUID: "DDDDDDDD-0000-0000-0000-000000000000"
        )
        store.snapshot = replacement
        store.showProblems = true

        XCTAssertFalse(store.navigateToDiagnostic(target))
        XCTAssertTrue(store.showProblems)
        XCTAssertNil(store.selectedImageAddress)
    }

    @MainActor
    func testDelayedBrowserCallbackKeepsCapturedOwnerAndPresentationOnRejection() throws {
        let store = makeStore()
        store.showBrowsers = true
        let aTarget = try XCTUnwrap(store.browserNavigationTarget(
            forExportID: primaryExportID,
            address: collidingAddress,
            in: slotA
        ))
        store.focusImage(slotB)

        XCTAssertFalse(store.navigateFromBrowser(aTarget))
        XCTAssertTrue(store.showBrowsers)
        XCTAssertNil(store.selectedImageAddress)

        let bSectionID = store.snapshot.analysis(in: slotB)?.sections.first?.id
        let bSectionAddress = store.snapshot.analysis(in: slotB)?.sections.first?.address
        let bTarget = try XCTUnwrap(bSectionID.flatMap { sectionID in
            bSectionAddress.flatMap { address in
                store.browserNavigationTarget(forSectionID: sectionID, address: address, in: slotB)
            }
        })
        XCTAssertTrue(store.navigateFromBrowser(bTarget))
        XCTAssertFalse(store.showBrowsers)
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: slotB, address: collidingAddress)
        )
        XCTAssertEqual(store.selectedInstruction?.comment, "B_COLLIDING_SENTINEL")
    }

    @MainActor
    func testStaleBrowserCallbackRejectsRemovedEntityAtStillMappedAddress() throws {
        let exportStore = makeStore()
        exportStore.selectedAddress = nil
        let exportTarget = try XCTUnwrap(exportStore.browserNavigationTarget(
            forExportID: primaryExportID,
            address: collidingAddress,
            in: slotA
        ))
        exportStore.snapshot.mutateAnalysis(in: slotA) { $0.exports = [] }
        exportStore.showBrowsers = true

        XCTAssertFalse(exportStore.navigateFromBrowser(exportTarget))
        XCTAssertTrue(exportStore.showBrowsers)
        XCTAssertNil(exportStore.selectedImageAddress)

        let sectionStore = makeStore()
        sectionStore.selectedAddress = nil
        let sectionID = try XCTUnwrap(sectionStore.snapshot.analysis(in: slotA)?.sections.first?.id)
        let sectionTarget = try XCTUnwrap(sectionStore.browserNavigationTarget(
            forSectionID: sectionID,
            address: collidingAddress,
            in: slotA
        ))
        sectionStore.snapshot.mutateAnalysis(in: slotA) { analysis in
            analysis.sections = [SectionSummary(
                id: UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEE3")!,
                name: "__TEXT,__replacement",
                address: collidingAddress,
                size: 0x400,
                fileOffset: 0,
                isExecutable: true
            )]
        }
        sectionStore.showBrowsers = true

        XCTAssertFalse(sectionStore.navigateFromBrowser(sectionTarget))
        XCTAssertTrue(sectionStore.showBrowsers)
        XCTAssertNil(sectionStore.selectedImageAddress)
    }

    @MainActor
    func testStaleBrowserCallbackRejectsSameSlotBinaryReplacement() throws {
        let store = makeStore()
        store.selectedAddress = nil
        let target = try XCTUnwrap(store.browserNavigationTarget(
            forExportID: primaryExportID,
            address: collidingAddress,
            in: slotA
        ))
        var replacement = makeSnapshot()
        replacement.binaries[0] = image(
            slot: slotA,
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDD0")!,
            name: "Replacement A",
            path: "/tmp/macscope-ws17-replacement-a",
            binaryUUID: "DDDDDDDD-0000-0000-0000-000000000000"
        )
        store.snapshot = replacement
        store.showBrowsers = true

        XCTAssertFalse(store.navigateFromBrowser(target))
        XCTAssertTrue(store.showBrowsers)
        XCTAssertNil(store.selectedImageAddress)
    }

    // MARK: - Fixture

    @MainActor
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "WS-17 focused selection",
            snapshot: makeSnapshot(),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    @MainActor
    private func restoredStore(
        snapshot: WorkspaceSnapshot,
        focusedImageSlot: ImageSlot,
        selectedAddress: UInt64?
    ) throws -> WorkspaceStore {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let persisted = try database.createWorkspaceState(
            workspaceName: "WS-17 focused selection restore",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: selectedAddress,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            focusedImageSlot: focusedImageSlot
        )
        return try XCTUnwrap(WorkspaceStore.restored(
            workspaceID: try XCTUnwrap(persisted.workspace.id),
            from: database
        ))
    }

    private func makeSnapshot() -> WorkspaceSnapshot {
        let functionAID = primaryFunctionID
        let functionBID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1")!

        var analysisA = ImageAnalysis()
        analysisA.functions = [FunctionSummary(
            id: functionAID,
            name: "AProcedure",
            startAddress: collidingAddress,
            endAddress: mappedUndecodedAddress + 4,
            confidence: 1
        )]
        analysisA.instructions = [
            instruction(
                collidingAddress,
                bytes: "aa aa aa aa",
                mnemonic: "a_collision",
                comment: "A_COLLIDING_SENTINEL"
            ),
            instruction(
                mappedUndecodedAddress,
                bytes: "ac ac ac ac",
                mnemonic: "a_mapped_collision",
                comment: "A_MAPPED_COLLISION_SENTINEL"
            ),
        ]
        analysisA.sections = [mappedSection(idSuffix: "A", slotName: "A")]
        analysisA.stringLiterals = [StringLiteralSummary(
            id: primaryStringID,
            value: "A_STRING_SENTINEL",
            address: collidingStringAddress,
            sourceSection: "__TEXT,__cstring",
            byteLength: 18
        )]
        analysisA.symbols = [
            SymbolSummary(
                id: primarySymbolID,
                name: "_shared_symbol",
                address: collidingAddress,
                kind: "function",
                libraryName: nil
            ),
            SymbolSummary(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA7")!,
                name: "_AOnlySymbol",
                address: collidingAddress,
                kind: "function",
                libraryName: nil
            ),
        ]
        analysisA.exports = [ExportSummary(
            id: primaryExportID,
            name: "_a_export",
            address: collidingAddress,
            source: "fixture"
        )]
        analysisA.xrefs = [XRef(
            id: primaryXRefID,
            from: collidingAddress,
            to: collidingStringAddress,
            kind: "data"
        )]
        analysisA.diagnostics = [AnalysisDiagnostic(
            severity: .warning,
            address: collidingAddress,
            kind: .unresolvedBranchTarget,
            message: "A_DIAGNOSTIC"
        )]
        analysisA.hexBytes = Data(repeating: 0xAA, count: 0x400)
        analysisA.imageBytes = analysisA.hexBytes

        var analysisB = ImageAnalysis()
        analysisB.functions = [FunctionSummary(
            id: functionBID,
            name: "BProcedure",
            startAddress: collidingAddress,
            endAddress: mappedUndecodedAddress + 4,
            confidence: 1
        )]
        analysisB.instructions = [
            instruction(
                collidingAddress,
                bytes: "bb bb bb bb",
                mnemonic: "b_collision",
                comment: "B_COLLIDING_SENTINEL"
            ),
            instruction(
                bOnlyAddress,
                bytes: "be be be be",
                mnemonic: "b_only",
                comment: "B_ONLY_SENTINEL"
            ),
        ]
        analysisB.sections = [mappedSection(idSuffix: "B", slotName: "B")]
        analysisB.stringLiterals = [StringLiteralSummary(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB2")!,
            value: "B_STRING_SENTINEL",
            address: collidingStringAddress,
            sourceSection: "__TEXT,__cstring",
            byteLength: 18
        )]
        analysisB.symbols = [
            SymbolSummary(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB4")!,
                name: "_shared_symbol",
                address: bOnlyAddress,
                kind: "function",
                libraryName: nil
            ),
            SymbolSummary(
                id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB5")!,
                name: "_BOnlySymbol",
                address: bOnlyAddress,
                kind: "function",
                libraryName: nil
            ),
        ]
        analysisB.diagnostics = [AnalysisDiagnostic(
            severity: .warning,
            address: collidingAddress,
            kind: .unresolvedBranchTarget,
            message: "B_DIAGNOSTIC"
        )]
        analysisB.hexBytes = Data(repeating: 0xBB, count: 0x400)
        analysisB.imageBytes = analysisB.hexBytes

        return WorkspaceSnapshot(
            binaries: [
                image(
                    slot: slotA,
                    id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA0")!,
                    name: "Image A",
                    path: "/tmp/macscope-ws17-image-a",
                    binaryUUID: "AAAAAAAA-0000-0000-0000-000000000000"
                ),
                image(
                    slot: slotB,
                    id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB0")!,
                    name: "Image B",
                    path: "/tmp/macscope-ws17-image-b",
                    binaryUUID: "BBBBBBBB-0000-0000-0000-000000000000"
                ),
                image(
                    slot: slotWithoutAnalysis,
                    id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCC0")!,
                    name: "Image without analysis",
                    path: "/tmp/macscope-ws17-image-without-analysis",
                    binaryUUID: "CCCCCCCC-0000-0000-0000-000000000000"
                ),
            ],
            analysisBySlot: [slotA: analysisA, slotB: analysisB]
        )
    }

    private func instruction(
        _ address: UInt64,
        bytes: String,
        mnemonic: String,
        comment: String
    ) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: bytes,
            mnemonic: mnemonic,
            operands: "",
            hasBreakpoint: false,
            comment: comment
        )
    }

    private func mappedSection(idSuffix: String, slotName: String) -> SectionSummary {
        let identifier = idSuffix == "A"
            ? UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA3")!
            : UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB3")!
        return SectionSummary(
            id: identifier,
            name: "__TEXT,__ws17_\(slotName.lowercased())",
            address: collidingAddress,
            size: 0x400,
            fileOffset: 0,
            isExecutable: true
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
}
