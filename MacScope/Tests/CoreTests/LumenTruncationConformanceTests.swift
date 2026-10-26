import AppKit
import LumenConformance
import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

/// U8-1, App-wide rule for every pane, window and subpanel: no primary label is cut short.
/// Lumen's components mark their primary labels (`.lumenNeverTruncates`), as MacScope marks its own;
/// `LumenConformance.truncation` lays each surface out in a real offscreen window at its minimum size
/// and reports any that is. Sheets are opened through the store's own `begin…` paths where they have
/// one; U8-2 adds every Settings page, the debugger's sheets, Version Compare, the native-pseudocode
/// action sheet, the assistant and the REA workbench (over a real host-compiled binary).
@MainActor
final class LumenTruncationConformanceTests: XCTestCase {
    private static let base: UInt64 = 0x1_0000_3f00

    private func store() -> WorkspaceStore {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "Truncation Fixture", path: "", kind: "fixture", architecture: "arm64e")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: Self.base, endAddress: Self.base + 8, confidence: 1)],
            instructions: [
                InstructionRow(address: Self.base, bytes: "1f2003d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
                InstructionRow(address: Self.base + 4, bytes: "c0035fd6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data(repeating: 0, count: 64),
            sections: [SectionSummary(id: UUID(), name: "__text", address: Self.base, size: 64, fileOffset: 0, isExecutable: true)],
            imageBytes: Data(repeating: 0, count: 64)
        )
        let store = WorkspaceStore(workspaceName: "Truncation", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: Self.base)))
        return store
    }

    private func assertNothingCutShort<Content: View>(_ name: String, _ sizes: [CGSize], file: StaticString = #filePath,
                                                     line: UInt = #line, _ content: () -> Content) {
        let findings = LumenConformance.truncation(sizes: sizes, of: { content().dsPaletteRoot().dsDensityRoot() })
        XCTAssertEqual(findings.map(\.description), [], name, file: file, line: line)
    }

    private static func size(_ width: CGFloat, _ height: CGFloat = 640) -> [CGSize] { [CGSize(width: width, height: height)] }

    func testTheSidebarAndInspectorPanesAtTheirMinimumWidths() {
        for tool in WorkspaceTool.allCases {
            let store = store()
            store.selectedTool = tool
            assertNothingCutShort("sidebar · \(tool.rawValue)", Self.size(AppLayout.sidebarMinWidth, 720)) { SidebarView(store: store) }
        }
        let store = store()
        for width in [AppLayout.compactInspectorMinWidth, AppLayout.inspectorMinWidth] {
            assertNothingCutShort("inspector", Self.size(width, 720)) { InspectorView(store: store) }
        }
    }

    /// U8-3: the Symbols and Strings rule editors at the popover's width, with two rows each.
    func testTheRuleFilterEditorsAtThePopoversWidth() {
        let store = store()
        for tool in [WorkspaceTool.symbols, .strings] {
            var rules = NavigatorFilterRules(tool: tool)
            let fields = NavigatorFilterField.fields(for: tool)
            rules.conditions = [LumenRuleCondition(field: fields[0], comparison: NavigatorFilterField.comparisons(for: fields[0]).last!, value: "abc"),
                                LumenRuleCondition(field: fields[3], comparison: NavigatorFilterField.greaterThan, value: "0x100000000")]
            store.navigatorFilterRules[tool] = rules
            assertNothingCutShort("Rule filter · \(tool.rawValue)", Self.size(SidebarRuleFilterEditor.width, 260)) {
                SidebarRuleFilterEditor(store: store, tool: tool)
            }
        }
    }

    /// The Types inspector with a class selected, at both inspector minimum widths: the members
    /// table's headers must not be cut short (Tier 2c showed Name/Type squeezed to "N…"/"T…").
    func testTheTypeInspectorAtTheInspectorsMinimumWidths() throws {
        var analysis = ImageAnalysis()
        analysis.objcClasses = [ObjCClass(
            name: "WidgetController", superclassName: "NSObject", adoptedProtocols: ["Pinger"], classMethods: [],
            instanceMethods: [ObjCMethod(selector: "computeValue", typeEncoding: nil, isClassMethod: false, implementation: Self.base)],
            ivars: [ObjCIvar(name: "_count", typeEncoding: "i", offset: 8, size: 4),
                    ObjCIvar(name: "_ratio", typeEncoding: "d", offset: 16, size: 8),
                    ObjCIvar(name: "_delegate", typeEncoding: nil, offset: nil, size: nil),
                    // U10-4: the Stickies names Lumen saw cut mid-word ("_mig…roller", "SNMi…er *").
                    ObjCIvar(name: "_migrationController", typeEncoding: "@\"SNMinimizer\"", offset: 32, size: 8)],
            properties: [], address: 0x1_0000_8000, instanceSize: 24)]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "w", path: "/tmp/w", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis]
        )
        let store = WorkspaceStore(workspaceName: "Types", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectedTool = .types
        let row = try XCTUnwrap(store.sidebarItems.first { $0.title == "WidgetController" })
        store.activateSidebarItem(row.id)
        XCTAssertNotNil(store.selectedTypeAtlasEntry)
        // U10-4: with the long Stickies-like member, the headers still fit at 248 and 260 pt.
        for width in [AppLayout.compactInspectorMinWidth, AppLayout.inspectorMinWidth] {
            assertNothingCutShort("Types inspector", Self.size(width, 900)) { InspectorView(store: store) }
        }
    }

    /// §4.93 (Lumen F1): a class whose image records no member offsets. The Offset and Evidence
    /// columns leave the row and every name and type keeps 8+ characters at both inspector minimum
    /// widths; names sharing a stem and types sharing a module prefix end in the middle.
    func testTheTypeInspectorWithAnUnknownLayoutAtTheInspectorsMinimumWidths() throws {
        var analysis = ImageAnalysis()
        analysis.objcClasses = [ObjCClass(
            name: "CalculatorViewModel", superclassName: "NSObject", adoptedProtocols: [], classMethods: [],
            instanceMethods: [],
            ivars: [ObjCIvar(name: "triggerAnalysisOnAppear", typeEncoding: "@\"CalculatorViewModelMode\"", offset: nil, size: nil),
                    ObjCIvar(name: "triggerAnalysisOnChange", typeEncoding: "@\"CalculatorViewModelOperation\"", offset: nil, size: nil),
                    ObjCIvar(name: "_showShiftedKeys", typeEncoding: "B", offset: nil, size: nil)],
            properties: [], address: 0x1_0000_8000, instanceSize: nil)]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "c", path: "/tmp/c", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis]
        )
        let store = WorkspaceStore(workspaceName: "Types", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectedTool = .types
        let row = try XCTUnwrap(store.sidebarItems.first { $0.title == "CalculatorViewModel" })
        store.activateSidebarItem(row.id)
        let entry = try XCTUnwrap(store.selectedTypeAtlasEntry)
        let reading = TypeAtlasInspectorReading(entry)
        let table = DSTypeMembersTable(rows: reading.members, note: reading.layoutNote)
        XCTAssertFalse(table.showsOffset)
        XCTAssertFalse(table.evidenceVaries)
        for width in [AppLayout.compactInspectorMinWidth, AppLayout.inspectorMinWidth] {
            assertNothingCutShort("Types inspector, unknown layout", Self.size(width, 900)) { InspectorView(store: store) }
        }
    }

    func testMiddleTruncatedTableTextKeepsFourCharactersEachSide() {
        XCTAssertEqual(DSTableMiddleText.shortestForm("CalculatorViewModel.Mode"), "Calc…Mode")
        XCTAssertEqual(DSTableMiddleText.shortestForm("Calculator"), "Calculator")
        XCTAssertTrue(DSTypeMembersTable(rows: [DSTypeMemberRow(id: 0, offset: "+0x8", name: "a", type: "—", evidence: "")], note: nil).showsOffset)
    }

    /// U8-5a: a struct applied at the selected address, its members in a Lumen table, at both
    /// inspector minimum widths: the table's headers must not be cut short.
    func testTheAppliedTypeTableAtTheInspectorsMinimumWidths() {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "Applied Type Fixture", path: "", kind: "fixture", architecture: "arm64e")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: Self.base, endAddress: Self.base + 8, confidence: 1)],
            instructions: [InstructionRow(address: Self.base, bytes: "1f2003d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)],
            xrefs: [],
            hexBytes: Data((0..<64).map { UInt8($0) }),
            sections: [SectionSummary(id: UUID(), name: "__data", address: Self.base, size: 64, fileOffset: 0, isExecutable: false)],
            imageBytes: Data((0..<64).map { UInt8($0) })
        )
        var withType = snapshot
        withType.typeDefinitions = [TypeDefinition(kind: .struct, name: "connection_state", fields: [
            FieldDef(name: "retry_count", type: "uint32_t"), FieldDef(name: "flags", type: "uint16_t"),
            FieldDef(name: "timeout_ms", type: "uint64_t"), FieldDef(name: "owner", type: "void *"),
        ])]
        withType.addressOverrides[ImageAddress(slot: .primary, address: Self.base)] = AddressOverride(appliedTypeName: "connection_state")
        let store = WorkspaceStore(workspaceName: "Applied Type", snapshot: withType, engine: AnalysisEngine(), autosaveScheduler: nil)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: Self.base)))
        // U10-6 / 0.42.2 floor: narrow widths drop Type and Value into the name's help; at 400 every
        // column shows. Each layout keeps every cell at 8+ characters.
        for width in [AppLayout.compactInspectorMinWidth, AppLayout.inspectorMinWidth, 320, 400] {
            assertNothingCutShort("Applied type", Self.size(width, 900)) { InspectorView(store: store) }
        }
    }

    /// U8-5b: the Imports browser as a Lumen table with real-looking rows at the Browsers sheet's
    /// minimum size.
    func testTheImportsTableAtTheBrowsersMinimumSize() {
        var analysis = ImageAnalysis()
        analysis.imports = [
            ImportSummary(id: UUID(), name: "_objc_msgSend", libraryName: "/usr/lib/libobjc.A.dylib", libraryOrdinal: 2),
            ImportSummary(id: UUID(), name: "_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF",
                          libraryName: "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation", libraryOrdinal: 1),
            ImportSummary(id: UUID(), name: "_printf", libraryName: nil, libraryOrdinal: nil),
        ]
        let store = WorkspaceStore(workspaceName: "Imports", snapshot: WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "i", path: "/tmp/i", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis]
        ), engine: AnalysisEngine(), autosaveScheduler: nil)
        assertNothingCutShort("Imports", Self.size(520, 420)) { ImportsBrowserView(store: store) }
    }

    /// U8-5c: the signature editor's recovered-parameter preview as a Lumen table at the sheet's
    /// minimum width.
    func testTheRecoveredParameterPreviewAtTheSignatureEditorsMinimumWidth() throws {
        let store = store()
        store.beginSignatureEditAtSelection()
        var request = try XCTUnwrap(store.signatureEditorRequest, store.lastIssue ?? "signature")
        request.parameterListIntent = .inherited
        request.originalParameterListIntent = .inherited
        request.recoveredArgs = [
            ArgDraft(index: 0, name: "connection", type: "struct connection_state *"),
            ArgDraft(index: 1, name: "timeout_ms", type: "uint64_t"),
            ArgDraft(index: 2, name: "completion_handler", type: "void (^)(NSError *)"),
        ]
        assertNothingCutShort("Signature · recovered", Self.size(520)) { SignatureEditorSheet(request: request, store: store) }
    }

    private func machOStore(imports: Int, dylibs: Int) -> WorkspaceStore {
        let symbols = (0..<imports).map { index in
            MachOLoadMetadata.ImportedSymbol(
                name: index == 0 ? "_$s10Foundation4DataV15_RepresentationO22withUnsafeMutableBytesyxxSwyKXEKlFyt_Tg5" : "_symbol_\(index)",
                libraryOrdinal: 1, libraryName: "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
                isWeak: index % 7 == 0, addend: nil, source: "chained-fixups")
        }
        let libraries = (0..<dylibs).map { index in
            MachOLoadMetadata.DependentDylib(
                path: "/System/Library/PrivateFrameworks/LongFrameworkName\(index).framework/Versions/A/LongFrameworkName\(index)",
                kind: "LC_LOAD_DYLIB", currentVersion: "1.2.3", compatibilityVersion: "1.0.0", ordinal: index + 1)
        }
        var snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "m", path: "/tmp/m", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: ImageAnalysis()]
        )
        snapshot.machOMetadata = MachOLoadMetadata(codeSignature: nil, importedSymbols: symbols, dependentDylibs: libraries)
        return WorkspaceStore(workspaceName: "Mach-O", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    /// §4.38: thousands of imported symbols and dependencies, with long names, at the sheet's
    /// minimum size; the section titles (with their counts) must not be cut short.
    func testTheMachOListsWithThousandsOfRowsAtTheSheetsMinimumSize() {
        let store = machOStore(imports: 3_000, dylibs: 1_500)
        assertNothingCutShort("Signature & Dependencies", Self.size(460, 360)) { MachOMetadataSheet(store: store) }
    }

    /// §4.38: the lists are lazy. Laying out 4,000 rows costs about what 40 do; a non-lazy stack
    /// builds every row, roughly 100x the work. A relative bound keeps this stable under load.
    func testTheMachOListsLayOutLazily() {
        func layoutSeconds(_ count: Int) -> Double {
            let store = machOStore(imports: count, dylibs: count / 2)
            let start = Date()
            _ = LumenConformance.truncation(sizes: Self.size(460, 360)) { MachOMetadataSheet(store: store) }
            return Date().timeIntervalSince(start)
        }
        _ = layoutSeconds(40) // warm-up
        let small = layoutSeconds(40)
        let large = layoutSeconds(4_000)
        XCTAssertLessThan(large, max(2.0, small * 20), "4,000 rows took \(large)s vs \(small)s for 40")
    }

    /// U9-4a: the type editor's fields as a Lumen table, editing a type with fields, at the sheet's
    /// 500 pt minimum.
    func testTheTypeEditorFieldsTableAtTheSheetsMinimumWidth() throws {
        let store = store()
        store.beginTypeDefinition(editing: TypeDefinition(kind: .struct, name: "connection_state", fields: [
            FieldDef(name: "retry_count", type: "uint32_t"),
            FieldDef(name: "completion_handler", type: "void (^)(struct connection_state *)"),
            FieldDef(name: "owner", type: "void *"),
        ]))
        let request = try XCTUnwrap(store.typeEditorRequest)
        XCTAssertEqual(request.fields.count, 3)
        assertNothingCutShort("Edit Type", Self.size(500)) { TypeEditorSheet(request: request, store: store) }
    }

    func testEverySettingsPageAtTheWindowsMinimumSize() {
        let controller = Phase2LocalAIProviderController(endpoint: nil)
        for category in SettingsCategory.allCases {
            assertNothingCutShort("Settings · \(category.rawValue)", Self.size(AppSettingsChrome.windowMinWidth, 620)) {
                SettingsView(providerController: controller, initialCategory: category)
            }
        }
    }

    func testTheDebuggerSheetsAtTheirMinimumSizes() throws {
        let store = store()
        let binary = try XCTUnwrap(store.focusedBinary)
        let owner = DebuggerWorkspaceImageOwnerSeal(slot: binary.slot, binaryID: binary.id, artifactIdentity: binary.artifactIdentity)
        let everyRow = LogicalBreakpointEditorCapabilities(canAuthorConditions: true, canAuthorIgnoreFirst: true, canAuthorActions: true,
                                                           canAuthorTargetExpressions: true, canAuthorContinueAfterActions: true)
        // U9-4d: a symbol locator shows the Matching Sites radio group with its explanations.
        var symbolDraft = LogicalBreakpointEditorDraft(owner: owner, preferredAddress: Self.base)
        symbolDraft.locatorKind = .symbol
        symbolDraft.symbolRawLinkageName = "_objc_msgSend"
        for capabilities in [LogicalBreakpointEditorCapabilities.unavailable, everyRow] {
            for draft in [LogicalBreakpointEditorDraft(owner: owner, preferredAddress: Self.base), symbolDraft] {
                assertNothingCutShort("Logical Breakpoint", Self.size(560, 560)) {
                    LogicalBreakpointEditorSheet(
                        title: "Add Logical Breakpoint",
                        draft: draft,
                        ownerChoices: [LogicalBreakpointOwnerChoice(owner: owner, title: binary.name,
                                                                    detail: "Slot \(binary.slot.rawValue) · \(binary.architecture)")],
                        sourceChoices: [], capabilities: capabilities, onSave: { _ in }, onCancel: {}
                    )
                }
            }
        }
        // An unavailable backend: the catalog refresh only records "unavailable", no process enumeration.
        let viewModel = DebuggerPanelViewModel(client: UnavailableDebuggerClient())
        assertNothingCutShort("Attach to Process", Self.size(760, 520)) {
            LocalProcessAttachSheet(viewModel: viewModel, onDismiss: {})
        }
    }

    func testCompareActionsAndAssistantSheetsAtTheirMinimumSizes() throws {
        let store = store()
        let binary = try XCTUnwrap(store.focusedBinary)
        let compare = VersionCompareViewModel()
        assertNothingCutShort("Version Compare", Self.size(640, 440)) { VersionCompareSheet(store: store, model: compare) {} }

        let coordinate = NativeDecompilerPresentationCoordinate(
            imageSlot: store.focusedImageSlot, ownerBinaryID: binary.id, artifactUUID: UUID(), imageID: "image.fixture",
            functionID: "function.fixture", requestSHA256: String(repeating: "a", count: 64),
            analysisInputFingerprintSHA256: String(repeating: "b", count: 64))
        let identity = NativePseudocodeActionIdentity(workspaceID: store.workspaceID,
            publication: .init(ownerToken: UUID(), generation: 1, coordinate: coordinate, requestID: UUID()))
        let ranges = [
            NativeDecompilerWireSourceRange(imageID: "image.fixture", startAddress: .init(Self.base), endAddressExclusive: .init(Self.base + 4)),
            NativeDecompilerWireSourceRange(imageID: "image.fixture", startAddress: .init(Self.base + 4), endAddressExclusive: .init(Self.base + 8)),
        ]
        let sheets = [
            NativePseudocodeActionSheet(identity: identity, content: .sources(
                NativePseudocodeSourceRequest(tokenID: "t0", action: .navigate(ranges[0])), ranges)),
            NativePseudocodeActionSheet(identity: identity, content: .entity(
                NativePseudocodeEntityInspection(title: "Native variable", fields: [.init(label: "Type", value: "int32_t")]))),
        ]
        for sheet in sheets {
            assertNothingCutShort("Native Pseudocode Action", Self.size(440, 300)) {
                NativePseudocodeActionSheetView(sheet: sheet, onChoose: { _, _ in }, onDismiss: {})
            }
        }

        assertNothingCutShort("Assistant", Self.size(900, 760)) {
            Phase2AssistantSheet(store: store, coordinator: nil, readiness: .endpointMissing)
        }
    }

    /// U9-4e: an accepted REA result on the Lumen tab strip at the result pane's 460 pt minimum.
    func testTheREAResultTabsAtTheResultPanesMinimumWidth() {
        typealias Presentation = REAInspectionResultPresentation
        let row = Presentation.Row(id: "r0", title: "NSWindow", detail: "Main window, titled “Untitled Workspace”",
                                   status: "Observed", tone: .positive)
        let presentation = Presentation(
            title: "widget", operationTitle: "Inspect Application", summary: "1 window, 12 controls",
            explanation: "Captured from a bounded UI tree.",
            sections: [Presentation.Section(id: "windows", title: "Windows", rows: [row], total: 1)],
            coverage: [Presentation.Row(id: "c0", title: "Coverage", detail: "Accessibility tree", status: "", tone: .neutral)],
            provenance: []
        )
        assertNothingCutShort("REA Result", Self.size(460, 520)) {
            REAInspectionResultView(presentation: presentation)
        }
    }

    /// The REA workbench over a real host-compiled Mach-O, as the workspace presents it.
    func testTheREAWorkbenchAtItsMinimumSize() throws {
        let url = try HostCompilerFixture.objc("int main(void) { return 0; }")
        let store = WorkspaceStore(workspaceName: "REA", snapshot: try AnalysisEngine().analyze(url: url),
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let binary = try XCTUnwrap(store.focusedBinary)
        let bytes = try XCTUnwrap(store.focusedAnalysis?.imageBytes)
        assertNothingCutShort("REA Workbench", Self.size(840, 620)) {
            REAWorkbenchView(selectedBinaryURL: URL(fileURLWithPath: binary.resolvedExecutablePath ?? binary.path),
                             expectedSelectedSHA256: REACaptureCommitment.digest(bytes),
                             requestedSliceIndex: binary.selectedSliceIndex, workspaceID: store.workspaceID,
                             history: store.reaResultEvidence.records,
                             makeAuthority: { hash, snapshot in store.reaAuthority(imageSHA256: hash, snapshotID: snapshot) },
                             onAccepted: { candidate in try store.publishREAResult(candidate) })
        }
    }

    func testEverySheetWithoutARequestAtItsMinimumSize() {
        let store = store()
        assertNothingCutShort("Go To", Self.size(420)) { GoToSheet(store: store) }
        let find = RetainedFindModel()
        assertNothingCutShort("Find", Self.size(480)) { FindSheet(store: store, model: find) }
        assertNothingCutShort("Browsers", Self.size(520, 420)) { BrowsersSheet(store: store) }
        assertNothingCutShort("Navigation History", Self.size(420, 360)) { NavigationHistorySheet(store: store) }
        assertNothingCutShort("Problems", Self.size(460, 360)) { ProblemsSheet(store: store) }
        assertNothingCutShort("Mach-O Metadata", Self.size(460, 360)) { MachOMetadataSheet(store: store) }
        assertNothingCutShort("Reconstruction Job", Self.size(560, 560)) {
            ReconstructionJobCreationSheet(
                availableItems: ReconstructionJobCreationItem.committedItems(in: store.reconstructionState),
                availableFunctions: ReconstructionJobCreationRequest.committedFunctions(in: store.reconstructionState),
                submissionAvailable: true, onCancel: {}, onCreate: { _ in }
            )
        }
    }

    func testEveryRequestDrivenSheetAtItsMinimumSize() throws {
        let store = store()
        store.beginRenameAtSelection()
        let rename = try XCTUnwrap(store.overrideEditorRequest, store.lastIssue ?? "rename")
        assertNothingCutShort("Rename", Self.size(360)) { OverrideEditorSheet(request: rename, store: store) }

        store.beginSignatureEditAtSelection()
        let signature = try XCTUnwrap(store.signatureEditorRequest, store.lastIssue ?? "signature")
        assertNothingCutShort("Signature", Self.size(520)) { SignatureEditorSheet(request: signature, store: store) }

        store.beginTypeDefinition()
        let type = try XCTUnwrap(store.typeEditorRequest)
        assertNothingCutShort("Define Type", Self.size(500)) { TypeEditorSheet(request: type, store: store) }

        store.beginSwitchHintEditAtSelection()
        let switchHint = try XCTUnwrap(store.switchHintEditorRequest, store.lastIssue ?? "switch hint")
        assertNothingCutShort("Switch Hint", Self.size(460)) { SwitchHintEditorSheet(request: switchHint, store: store) }

        let loader = LoaderOptionsRequest(url: URL(fileURLWithPath: "/tmp/Universal Fixture"), model: LoaderOptionsModel(
            fileName: "Universal Fixture", formatDescription: "Mach-O universal binary",
            slices: [LoaderSliceOption(index: 0, architectureName: "arm64e", offset: 0x4000, size: 0x10000),
                     LoaderSliceOption(index: 1, architectureName: "x86_64", offset: 0x14000, size: 0x10000)]
        ))
        assertNothingCutShort("Loader Options", Self.size(460)) { LoaderOptionsSheet(request: loader, store: store) }

        store.perform(.patchBytes)
        let patch = try XCTUnwrap(store.pendingPatchBytesRequest, store.lastIssue ?? "patch")
        assertNothingCutShort("Patch Bytes", Self.size(360)) { PatchBytesSheet(store: store, request: patch) }

        store.perform(.assembleInstruction)
        let assemble = try XCTUnwrap(store.pendingAssembleRequest, store.lastIssue ?? "assemble")
        assertNothingCutShort("Assemble", Self.size(360)) { AssembleSheet(store: store, request: assemble) }

        store.beginMakeDataAtSelection()
        let makeData = try XCTUnwrap(store.dataShapeEditorRequest, store.lastIssue ?? "make data")
        assertNothingCutShort("Make Data", Self.size(380)) { MakeDataSheet(request: makeData, store: store) }

        store.beginRegisterRenameAtSelection()
        let register = try XCTUnwrap(store.registerRenameRequest, store.lastIssue ?? "register rename")
        assertNothingCutShort("Rename Register", Self.size(360)) { RegisterRenameSheet(request: register, store: store) }

        assertNothingCutShort("Define Types from C", Self.size(500)) {
            CHeaderImportSheet(request: CHeaderImportRequest(), store: store)
        }
    }
}

/// A debugger backend that isn't available (no LLDB), so nothing touches the system.
@MainActor
private final class UnavailableDebuggerClient: DebuggerClient {
    let capabilities = DebuggerCapabilityReport(
        backendName: "Xcode LLDB",
        isBackendAvailable: false,
        canLaunch: false,
        canAttach: false,
        canControlExecution: false,
        limitations: ["No LLDB executable."],
        entitlementNotes: [],
        backendAvailability: .unavailable(reason: "No LLDB executable."),
        launchSupport: .unsupported(reason: "No LLDB executable."),
        attachSupport: .unsupported(reason: "No LLDB executable."),
        executionControlSupport: .unsupported(reason: "No LLDB executable.")
    )

    func makeInitialSnapshot() -> DebuggerSessionSnapshot { .empty }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { .empty }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws
        -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
}
