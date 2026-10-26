import SwiftUI
import XCTest
@testable import MacScope

@MainActor
final class DSCommandPaletteTests: XCTestCase {
    private let address: UInt64 = 0x1000
    private let sibling = ImageSlot(rawValue: 1)

    func testAdapterPreservesStableCatalogMetadataAndRenamedSymbolSearch() throws {
        let store = makeStore()
        store.setCustomName(address, name: "renamed_entry")
        let entries = store.commandPaletteEntries
        let commands = DSCommandPaletteAdapter.commands(bindings: .defaults, store: store)
        XCTAssertEqual(commands.map(\.id), entries.map(\.id))
        for (entry, command) in zip(entries, commands) {
            XCTAssertEqual(command.title, entry.title)
            XCTAssertEqual(command.category, entry.kind.rawValue)
            XCTAssertEqual(command.systemImage, entry.systemImage)
            XCTAssertEqual(command.isEnabled, entry.availability.isAvailable)
            XCTAssertTrue(Set(command.keywords).isSuperset(of: entry.keywords))
            XCTAssertTrue(command.subtitle?.contains(entry.subtitle) == true)
        }
        let symbol = try XCTUnwrap(commands.first { $0.category == "Symbol" })
        XCTAssertEqual(symbol.title, "renamed_entry")
        XCTAssertTrue(symbol.keywords.contains("entry_primary"))
        XCTAssertTrue(symbol.keywords.contains(address.hexAddress))
        XCTAssertEqual(DSCommandPaletteAdapter.recentsKey, "MacScope.lumen.commandPalette.recents")
    }

    func testShortcutsUseResolvedOverridesAndFixedEditorModeAuthority() throws {
        let store = makeStore()
        var bindings = KeyBindingSet.defaults
        bindings.setChord(KeyChord(key: "j", modifiers: [.command, .option]), for: .goToAddress)
        bindings.setChord(KeyChord(key: "i", modifiers: [.control, .command]), for: .toggleInspector)
        bindings.setChord(KeyChord(key: "b", modifiers: [.shift, .command]), for: .toggleBreakpoint)
        bindings.setChord(KeyChord(key: "p", modifiers: [.command, .option]), for: .openQuickly)
        let decoded = KeyBindingSet.resolvingOverrides(bindings.encodedOverrides())
        for (id, bindable) in [
            ("command:go-to-address", BindableCommand.goToAddress),
            ("command:toggle-inspector", .toggleInspector),
            ("command:toggle-breakpoint", .toggleBreakpoint),
        ] {
            let command = DSCommandPaletteAdapter.command(for: try entry(id, in: store), bindings: decoded, store: store)
            let expected = decoded.chord(for: bindable).keyboardShortcut
            XCTAssertEqual(command.shortcut?.key, expected.key)
            XCTAssertEqual(command.shortcut?.modifiers, expected.modifiers)
        }
        let hex = DSCommandPaletteAdapter.command(for: try entry("command:search-hex-bytes", in: store), bindings: decoded, store: store)
        XCTAssertEqual(hex.shortcut?.key, KeyEquivalent("4"))
        XCTAssertEqual(hex.shortcut?.modifiers, .command)
        XCTAssertEqual(decoded.chord(for: .openQuickly), KeyChord(key: "p", modifiers: [.command, .option]))
        XCTAssertEqual(KeyBindingSet.defaults.chord(for: .openQuickly), KeyChord(key: "o", modifiers: [.command, .shift]))
    }

    func testDisabledReasonSurvivesSubtitleAccessibilityHintAndCannotPerform() throws {
        let store = makeStore()
        store.selectedAddress = nil
        let unavailable = try entry("command:toggle-breakpoint", in: store)
        let reason = try XCTUnwrap(unavailable.availability.unavailableReason)
        let command = DSCommandPaletteAdapter.command(for: unavailable, bindings: .defaults, store: store)
        XCTAssertFalse(command.isEnabled)
        XCTAssertTrue(command.subtitle?.contains(reason) == true)
        XCTAssertTrue(command.keywords.contains(reason))
        command.perform()
        XCTAssertEqual(store.lastIssue, reason)
        XCTAssertTrue(store.snapshot.logicalBreakpointCatalog.specifications.isEmpty)
    }

    func testPaletteDismissalThenGoToAddressExplicitlyReopensOnlyAddressPresentation() throws {
        let store = makeStore()
        let observer = ObservedObject(wrappedValue: store)
        let palette = observer.projectedValue.isCommandPalettePresented
        let addressSheet = observer.projectedValue.isGoToAddressPresented
        palette.wrappedValue = true
        XCTAssertTrue(palette.wrappedValue)
        XCTAssertFalse(addressSheet.wrappedValue)
        let command = DSCommandPaletteAdapter.command(for: try entry("command:go-to-address", in: store), bindings: .defaults, store: store)
        XCTAssertTrue(command.subtitle?.contains(DSCommandPaletteAdapter.addressHelp) == true)
        // Pinned Lumen dismisses first, then invokes the app action synchronously.
        palette.wrappedValue = false
        command.perform()
        XCTAssertFalse(palette.wrappedValue)
        XCTAssertTrue(addressSheet.wrappedValue)
        XCTAssertTrue(store.showGoTo)
        palette.wrappedValue = false // delayed palette dismissal must not close the new sheet
        XCTAssertTrue(addressSheet.wrappedValue)
    }

    func testProjectedVisibilityRequiresFlagAndDismissalCannotCrossModes() {
        let store = makeStore()
        store.searchSheetPresentation = .commandPalette
        store.showGoTo = false
        XCTAssertFalse(store.isCommandPalettePresented)
        XCTAssertFalse(store.isGoToAddressPresented)
        store.isGoToAddressPresented = true
        XCTAssertFalse(store.isCommandPalettePresented)
        XCTAssertTrue(store.isGoToAddressPresented)
        store.isCommandPalettePresented = true
        store.isGoToAddressPresented = false // stale sheet dismissal
        XCTAssertTrue(store.isCommandPalettePresented)
        XCTAssertFalse(store.isGoToAddressPresented)
        store.isCommandPalettePresented = false
        XCTAssertFalse(store.showGoTo)
    }

    func testPaletteAuthoringDismissesBeforePublishingExactCommentTarget() throws {
        let store = makeStore()
        store.selectInstruction(address)
        store.isCommandPalettePresented = true
        let invocation = DSCommandPaletteInvocation(entry: try entry("editor-scaffold:editComment", in: store), store: store)
        XCTAssertTrue(invocation.perform(in: store))
        XCTAssertFalse(store.isCommandPalettePresented)
        XCTAssertFalse(store.isGoToAddressPresented)
        let request = try XCTUnwrap(store.overrideEditorRequest)
        XCTAssertEqual(request.address, address)
        XCTAssertEqual(request.imageSlot, .primary)
        XCTAssertEqual(request.ownerBinaryID, store.snapshot.binary(in: .primary)?.id)
    }

    func testRenameAndWorkspaceGlobalTypeAuthoringKeepExistingRequests() throws {
        let store = makeStore()
        store.selectInstruction(address)
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("editor-scaffold:renameSymbol", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.overrideEditorRequest?.initialValue, "entry_primary")
        store.overrideEditorRequest = nil
        store.selectedAddress = nil
        store.isCommandPalettePresented = true
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("editor-scaffold:defineType", in: store), store: store).perform(in: store))
        XCTAssertNotNil(store.typeEditorRequest)
        XCTAssertFalse(store.showGoTo)
    }

    func testToolModeAndInspectorActionsKeepRealStoreEffects() throws {
        let store = makeStore()
        for tool in WorkspaceTool.allCases {
            store.isCommandPalettePresented = true
            XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("tool:\(tool.id)", in: store), store: store).perform(in: store))
            XCTAssertEqual(store.selectedTool, tool)
            XCTAssertEqual(store.selectedSidebarItemID, store.sidebarItems.first { !$0.id.hasPrefix("section:") }?.id ?? store.sidebarItems.first?.id)
            XCTAssertFalse(store.showGoTo)
        }
        for mode in EditorMode.allCases {
            XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("mode:\(mode.id)", in: store), store: store).perform(in: store))
            XCTAssertEqual(store.editorMode, mode)
        }
        let before = store.isInspectorPresented
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("command:toggle-inspector", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.isInspectorPresented, !before)
    }

    func testColorOperandAndTypeActionsUseExistingOverridePersistence() throws {
        let store = makeStore()
        store.selectInstruction(address)
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("color:orange", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.snapshot.colorTag(at: address), .orange)
        let format = try XCTUnwrap(OperandFormat.allCases.first)
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("operand-format:\(format.rawValue)", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.operandFormat, format)
        let type = TypeDefinition(kind: .struct, name: "Header")
        store.snapshot.typeDefinitions = [type]
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("type-apply:\(type.id.uuidString)", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.appliedTypeName, "Header")
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("type-edit:\(type.id.uuidString)", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.typeEditorRequest?.typeID, type.id)
        store.typeEditorRequest = nil
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("type-delete:\(type.id.uuidString)", in: store), store: store).perform(in: store))
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty)
    }

    func testBreakpointActionMutatesTheLogicalCatalog() throws {
        let store = makeStore()
        store.selectInstruction(address)
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("command:toggle-breakpoint", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.specifications.count, 1)
        XCTAssertTrue(store.selectedInstruction?.hasBreakpoint == true)
    }

    func testTagSignatureSwitchAndDataActionsRetainTheirExistingStoreOperations() throws {
        let store = makeStore()
        store.selectInstruction(address)
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("editor-scaffold:setTag", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.overrideEditorRequest?.imageSlot, .primary)
        XCTAssertEqual(store.overrideEditorRequest?.address, address)
        store.overrideEditorRequest = nil
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("editor-scaffold:editFunctionSignature", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.signatureEditorRequest?.imageSlot, .primary)
        XCTAssertEqual(store.signatureEditorRequest?.address, address)
        store.signatureEditorRequest = nil
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("editor-scaffold:defineSwitchHint", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.switchHintEditorRequest?.imageSlot, .primary)
        XCTAssertEqual(store.switchHintEditorRequest?.address, address)
        store.switchHintEditorRequest = nil
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("editor-scaffold:markAsData", in: store), store: store).perform(in: store))
        XCTAssertTrue(store.snapshot.isData(at: address))
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("editor-scaffold:markAsCode", in: store), store: store).perform(in: store))
        XCTAssertFalse(store.snapshot.isData(at: address))
    }

    func testCatalogSymbolActionSelectsTheExactFunctionAndAddress() throws {
        let store = makeStore()
        let function = try XCTUnwrap(store.focusedAnalysis?.functions.first)
        XCTAssertTrue(DSCommandPaletteInvocation(entry: try entry("symbol:\(function.id.uuidString)", in: store), store: store).perform(in: store))
        XCTAssertEqual(store.selectedTool, .symbols)
        XCTAssertEqual(store.selectedSidebarItemID, "symbol:\(function.id.uuidString)")
        XCTAssertEqual(store.selectedImageAddress, .primary(address))
        XCTAssertEqual(store.editorMode, .disassembly)
    }

    func testChangedSelectionAndFocusRefuseRetainedAuthoringCommands() throws {
        let store = makeStore(twoImages: true)
        store.selectInstruction(address)
        let original = DSCommandPaletteInvocation(entry: try entry("editor-scaffold:editComment", in: store), store: store)
        store.selectInstruction(address + 4)
        XCTAssertFalse(original.perform(in: store))
        XCTAssertNil(store.overrideEditorRequest)
        store.selectInstruction(address)
        let focused = DSCommandPaletteInvocation(entry: try entry("color:orange", in: store), store: store)
        store.focusImage(sibling)
        store.selectInstruction(address)
        XCTAssertFalse(focused.perform(in: store))
        XCTAssertNil(store.snapshot.addressOverrides[ImageAddress(slot: sibling, address: address)])
    }

    func testReplacedImageAndRemovedFunctionRefuseRetainedNavigation() throws {
        let store = makeStore()
        let function = try XCTUnwrap(store.focusedAnalysis?.functions.first)
        let invocation = DSCommandPaletteInvocation(entry: try entry("symbol:\(function.id.uuidString)", in: store), store: store)
        store.snapshot.binaries[0] = image(.primary)
        XCTAssertFalse(invocation.perform(in: store))
        let current = try XCTUnwrap(store.commandPaletteEntries.first { $0.kind == .symbol })
        let removed = DSCommandPaletteInvocation(entry: current, store: store)
        store.snapshot.analysisBySlot[.primary]?.functions = []
        XCTAssertFalse(removed.perform(in: store))
    }

    func testAmbiguousAddressOffersBothImagesAndRoutesChosenSibling() throws {
        let store = makeStore(twoImages: true)
        store.isGoToAddressPresented = true
        let choices = try XCTUnwrap(DSGoToAddressRouting.entries(for: address.hexAddress, in: store))
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices[0].title.contains("primary"))
        XCTAssertTrue(choices[1].title.contains("sibling"))
        XCTAssertTrue(DSCommandPaletteInvocation(entry: choices[1], store: store).perform(in: store))
        XCTAssertEqual(store.focusedImageSlot, sibling)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: sibling, address: address))
        XCTAssertEqual(store.editorMode, .disassembly)
        // The sheet's successful-navigation callback owns sheet dismissal.
        XCTAssertTrue(store.isGoToAddressPresented)
    }

    func testSingleRawAndUnmappedAddressesRetainNavigationAndFailureSemantics() throws {
        let store = makeStore()
        let raw = address + 12
        let choices = try XCTUnwrap(DSGoToAddressRouting.entries(for: raw.hexAddress, in: store))
        XCTAssertEqual(choices.count, 1)
        XCTAssertTrue(DSCommandPaletteInvocation(entry: choices[0], store: store).perform(in: store))
        XCTAssertEqual(store.selectedAddress, raw)
        XCTAssertEqual(store.editorMode, .hex)
        let unmapped = try XCTUnwrap(DSGoToAddressRouting.entries(for: "0xffff", in: store)?.first)
        XCTAssertFalse(DSCommandPaletteInvocation(entry: unmapped, store: store).perform(in: store))
        XCTAssertTrue(store.lastIssue?.contains("outside") == true)
    }

    func testAddressSymbolPrecedenceAndRuntimeResolutionMatchStoreAuthority() throws {
        let store = makeStore(twoImages: true)
        store.snapshot.analysisBySlot[.primary]?.functions[0].name = "dead"
        XCTAssertNil(DSGoToAddressRouting.entries(for: "dead", in: store))
        XCTAssertTrue(store.goTo(query: "dead"))
        // Direct store construction does not run the image-set restore/import seam.
        // Derive its runtime layout exactly as those production paths do.
        store.recomputeCrossImageXrefs()
        store.addressDisplayMode = .runtime
        let target = ImageAddress(slot: sibling, address: address)
        let runtime = store.imageLayout.runtimeVA(target)
        XCTAssertNotEqual(runtime, address, "The sibling's runtime address must distinguish the overlapping images.")
        XCTAssertEqual(store.imageLayout.resolve(runtimeVA: runtime), target)
        let choices = try XCTUnwrap(DSGoToAddressRouting.entries(for: runtime.hexAddress, in: store))
        XCTAssertEqual(choices.count, 1)
        XCTAssertTrue(DSCommandPaletteInvocation(entry: choices[0], store: store).perform(in: store))
        XCTAssertEqual(store.selectedImageAddress, target)
        XCTAssertEqual(store.focusedImageSlot, sibling)
    }

    func testAddressSubmissionReturnsAuthoritativeUnmappedAndInvalidIssuesWithoutNavigating() throws {
        let store = makeStore()
        store.isGoToAddressPresented = true
        store.selectInstruction(address)
        let selection = store.selectedImageAddress
        store.lastIssue = "Unrelated older issue"
        let unmapped = DSGoToAddressRouting.submit("0x123", in: store)
        let issue = try XCTUnwrap(store.lastIssue)
        XCTAssertEqual(unmapped, .failed(issue))
        XCTAssertEqual(issue, "Address \(UInt64(0x123).hexAddress) is outside primary.")
        XCTAssertEqual(store.selectedImageAddress, selection)
        XCTAssertTrue(store.isGoToAddressPresented)

        let invalid = DSGoToAddressRouting.submit("unknown symbol", in: store)
        XCTAssertEqual(invalid, .failed("Enter a hex address or a known symbol name."))
        XCTAssertEqual(store.lastIssue, "Enter a hex address or a known symbol name.")
        XCTAssertEqual(store.selectedImageAddress, selection)
        XCTAssertTrue(store.isGoToAddressPresented)
    }

    func testAddressSubmissionDistinguishesSuccessAndImageChoiceFromStaleIssues() {
        let single = makeStore()
        single.lastIssue = "Unrelated older issue"
        XCTAssertEqual(DSGoToAddressRouting.submit((address + 12).hexAddress, in: single), .navigated)
        XCTAssertEqual(single.selectedAddress, address + 12)
        XCTAssertEqual(single.editorMode, .hex)

        let multiple = makeStore(twoImages: true)
        multiple.lastIssue = "Unrelated older issue"
        let selection = multiple.selectedImageAddress
        XCTAssertEqual(DSGoToAddressRouting.submit(address.hexAddress, in: multiple), .chooseImage)
        XCTAssertEqual(multiple.selectedImageAddress, selection)
        XCTAssertEqual(multiple.focusedImageSlot, .primary)
    }

    func testAddressChoiceSubmissionSurfacesStaleOwnerIssueWithoutNavigating() throws {
        let store = makeStore(twoImages: true)
        store.isGoToAddressPresented = true
        let choice = try XCTUnwrap(DSGoToAddressRouting.entries(for: address.hexAddress, in: store)?.last)
        let invocation = DSCommandPaletteInvocation(entry: choice, store: store)
        store.snapshot.binaries[1] = image(sibling)
        let outcome = DSGoToAddressRouting.perform(invocation, in: store)
        XCTAssertEqual(outcome, .failed(try XCTUnwrap(store.lastIssue)))
        XCTAssertTrue(store.lastIssue?.contains("target changed") == true)
        XCTAssertEqual(store.focusedImageSlot, .primary)
        XCTAssertTrue(store.isGoToAddressPresented)
    }

    func testRetainedImageChoiceRefusesReplacedOwnerAtSameSlotAndAddress() throws {
        let store = makeStore(twoImages: true)
        let choice = try XCTUnwrap(DSGoToAddressRouting.entries(for: address.hexAddress, in: store)?.last)
        let invocation = DSCommandPaletteInvocation(entry: choice, store: store)
        store.snapshot.binaries[1] = image(sibling)
        XCTAssertFalse(invocation.perform(in: store))
        XCTAssertEqual(store.focusedImageSlot, .primary)
    }

    private func entry(_ id: String, in store: WorkspaceStore) throws -> CommandPaletteEntry {
        try XCTUnwrap(store.commandPaletteEntries.first { $0.id == id }, "Missing catalog entry \(id)")
    }

    private func image(_ slot: ImageSlot) -> BinaryImage {
        BinaryImage(id: UUID(), name: slot == .primary ? "primary" : "sibling", path: "/tmp/palette-\(slot.rawValue)", kind: "executable", architecture: "arm64", slot: slot)
    }

    private func makeStore(twoImages: Bool = false) -> WorkspaceStore {
        let slots: [ImageSlot] = twoImages ? [.primary, sibling] : [.primary]
        var analyses: [ImageSlot: ImageAnalysis] = [:]
        for slot in slots {
            var analysis = ImageAnalysis()
            analysis.functions = [FunctionSummary(id: UUID(), name: slot == .primary ? "entry_primary" : "entry_sibling", startAddress: address, endAddress: address + 8, confidence: 1)]
            analysis.instructions = [address, address + 4].map {
                InstructionRow(address: $0, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
            }
            analysis.sections = [SectionSummary(id: UUID(), name: "__TEXT,__text", address: address, size: 16, fileOffset: 0, isExecutable: true)]
            analysis.hexBytes = Data(repeating: 0, count: 16)
            analyses[slot] = analysis
        }
        return WorkspaceStore(workspaceName: "Palette", snapshot: WorkspaceSnapshot(binaries: slots.map(image), analysisBySlot: analyses), engine: AnalysisEngine(), autosaveScheduler: nil)
    }
}
