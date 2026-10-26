import CoreGraphics
import SwiftUI
import LumenUI
import XCTest
@testable import MacScope

func macScopeInfoDictionary() throws -> [String: Any] {
    let candidates = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
    if let appBundle = candidates.first(where: { $0.bundleIdentifier == "org.macscope.app" }),
       let info = appBundle.infoDictionary {
        return info
    }

    let plistURL = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("Info.plist", isDirectory: false)
    let data = try Data(contentsOf: plistURL)
    var format = PropertyListSerialization.PropertyListFormat.xml
    return try XCTUnwrap(
        PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any]
    )
}

final class CoreSmokeTests: XCTestCase {
    func testNativeDecompilerQualificationSnapshotMapsBoundedLookaheadOutsideFunction() throws {
        let snapshot = AnalysisEngine.nativeDecompilerQualificationSnapshot()
        let binary = try XCTUnwrap(snapshot.binaries.first)
        let analysis = try XCTUnwrap(snapshot.analysis(in: binary.slot))
        let function = try XCTUnwrap(analysis.functions.first)
        let section = try XCTUnwrap(analysis.sections.first)
        let artifact = try XCTUnwrap(binary.artifactIdentity)
        let attestation = try XCTUnwrap(analysis.identityEffectiveByteRanges.first)

        XCTAssertEqual(function.startAddress, 0x1000_00000)
        XCTAssertEqual(function.endAddress, 0x1000_00028)
        XCTAssertEqual(analysis.imageBytes.count, 40 + 64)
        XCTAssertEqual(section.address, function.startAddress)
        XCTAssertEqual(section.size, 104)
        XCTAssertEqual(section.fileSize, 104)
        XCTAssertEqual(artifact.selectedSliceByteCount, 104)
        XCTAssertEqual(attestation.endAddressExclusive, 0x1000_00068)
        XCTAssertEqual(
            Data(analysis.imageBytes.suffix(64)),
            Data(Array(repeating: [0x1f, 0x20, 0x03, 0xd5], count: 16).flatMap { $0 })
        )
        XCTAssertNotNil(analysis.analysisInputFingerprint)
    }

    func testNativeDecompilerCommandsHaveNoGlobalEscapeShortcut() throws {
        let root = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("App/AppCommands.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("keyboardShortcut(.escape"))
        XCTAssertFalse(source.contains("keyboardShortcut(\"\\u{1b}\""))
    }

    func testWorkspaceToolsExposeStableDockMetadata() {
        XCTAssertEqual(
            WorkspaceTool.allCases,
            [.project, .symbols, .strings, .xrefs, .debug, .extensions, .reconstruction, .types]
        )

        XCTAssertEqual(WorkspaceTool.allCases.map(\.rawValue), [
            "Project",
            "Symbols",
            "Strings",
            "Xrefs",
            "Debug",
            "Extensions",
            "Reconstruction",
            "Types"
        ])
        XCTAssertEqual(WorkspaceTool.allCases.map(\.systemImage), [
            "square.stack.3d.up",
            "function",
            "text.quote",
            "lumen.crossReference",
            "ladybug",
            "puzzlepiece.extension",
            "arrow.trianglehead.2.clockwise.rotate.90",
            "cube"
        ])
        XCTAssertEqual(Set(WorkspaceTool.allCases.map(\.id)).count, WorkspaceTool.allCases.count)
    }

    func testWorkbenchLayoutTokensAdaptSidebarWidth() {
        XCTAssertLessThanOrEqual(AppLayout.sidebarMinWidth, AppLayout.sidebarIdealWidth)
        XCTAssertLessThanOrEqual(AppLayout.sidebarIdealWidth, AppLayout.sidebarMaxWidth)
        XCTAssertEqual(AppLayout.sidebarWidth(for: 900), AppLayout.sidebarMinWidth)
        XCTAssertEqual(AppLayout.sidebarWidth(for: 1_280), 358.4, accuracy: 0.001)
        XCTAssertEqual(AppLayout.sidebarWidth(for: 1_800), AppLayout.sidebarMaxWidth)
        XCTAssertEqual(AppLayout.editorMinimumReadableWidth, 560)
        XCTAssertEqual(AppLayout.minimumSupportedWindowWidth, 1_080)
        XCTAssertEqual(
            AppLayout.minimumBalancedWindowWidth,
            AppLayout.sidebarMinWidth + AppLayout.editorMinimumReadableWidth
        )
        XCTAssertLessThanOrEqual(AppLayout.maximumSidebarWindowShare, 0.34)
        XCTAssertLessThanOrEqual(AppLayout.maximumInspectorWindowShare, 0.27)
        XCTAssertLessThanOrEqual(AppLayout.maximumSupportingPaneWindowShare, 0.56)
        XCTAssertLessThanOrEqual(AppLayout.inspectorMinWidth, AppLayout.inspectorIdealWidth)
        XCTAssertLessThanOrEqual(AppLayout.inspectorIdealWidth, AppLayout.inspectorMaxWidth)
        XCTAssertFalse(AppLayout.allowsInspector(for: AppLayout.inspectorPresentationMinWindowWidth - 1))
        XCTAssertTrue(AppLayout.allowsInspector(for: AppLayout.inspectorPresentationMinWindowWidth))
        XCTAssertEqual(AppLayout.inspectorMinimumWidth(for: 1_300), AppLayout.compactInspectorMinWidth)
        XCTAssertEqual(AppLayout.inspectorIdealWidth(for: 1_300), AppLayout.compactInspectorIdealWidth)
        XCTAssertEqual(AppLayout.inspectorMaximumWidth(for: 1_300), AppLayout.compactInspectorMaxWidth)
        XCTAssertEqual(AppLayout.inspectorMinimumWidth(for: 1_600), AppLayout.inspectorMinWidth)
        XCTAssertEqual(AppLayout.inspectorIdealWidth(for: 1_600), AppLayout.inspectorIdealWidth)
        XCTAssertEqual(AppLayout.inspectorMaximumWidth(for: 1_600), AppLayout.inspectorMaxWidth)
    }

    func testWorkspacePaneMetricsKeepEditorReadableWhenInspectorIsAllowed() {
        let narrow = AppLayout.workspacePaneMetrics(for: AppLayout.minimumBalancedWindowWidth)
        XCTAssertFalse(narrow.allowsInspector)
        XCTAssertEqual(narrow.sidebarWidth, AppLayout.sidebarMinWidth)
        XCTAssertEqual(narrow.editorFrameMinimumWidth, AppLayout.editorMinimumReadableWidth)
        XCTAssertTrue(narrow.preservesReadableEditor)

        let inspectorThreshold = AppLayout.workspacePaneMetrics(for: AppLayout.inspectorPresentationMinWindowWidth)
        XCTAssertTrue(inspectorThreshold.allowsInspector)
        XCTAssertEqual(inspectorThreshold.inspectorMinWidth, AppLayout.compactInspectorMinWidth)
        XCTAssertLessThanOrEqual(
            inspectorThreshold.minimumBalancedWidth,
            AppLayout.inspectorPresentationMinWindowWidth,
            "The inspector presentation threshold must leave the editor's readable width intact even at maximum inspector width."
        )
        XCTAssertTrue(inspectorThreshold.preservesReadableEditor)
        XCTAssertTrue(inspectorThreshold.preservesReadableEditorAtInspectorMaximum)

        for width in [1_280, 1_400, 1_600] as [CGFloat] {
            let metrics = AppLayout.workspacePaneMetrics(for: width)
            XCTAssertTrue(metrics.allowsInspector)
            XCTAssertLessThanOrEqual(metrics.inspectorMinWidth, metrics.inspectorIdealWidth)
            XCTAssertLessThanOrEqual(metrics.inspectorIdealWidth, metrics.inspectorMaxWidth)
            XCTAssertLessThanOrEqual(metrics.minimumBalancedWidth, width)
            XCTAssertTrue(metrics.preservesReadableEditor)
            XCTAssertTrue(metrics.preservesReadableEditorAtInspectorMaximum)
        }
    }

    func testInspectorMaximumWidthCannotStarveTheEditorPane() {
        for width in [
            AppLayout.inspectorPresentationMinWindowWidth,
            1_280,
            1_400,
            1_600
        ] as [CGFloat] {
            let metrics = AppLayout.workspacePaneMetrics(for: width)
            XCTAssertTrue(metrics.allowsInspector)
            XCTAssertGreaterThanOrEqual(metrics.editorReadableWidthAtInspectorMaximum, AppLayout.editorMinimumReadableWidth)
            XCTAssertLessThanOrEqual(
                metrics.sidebarWidth + metrics.inspectorMaxWidth + AppLayout.editorMinimumReadableWidth,
                width,
                "Sidebar plus maximum inspector width must not push the editor below its readable minimum at \(width) points."
            )
            XCTAssertLessThanOrEqual(
                metrics.inspectorMaxWidth,
                width * 0.27,
                "The inspector should remain a supporting pane, not become the dominant column."
            )
        }
    }

    func testPaneBudgetCoversMinimumThresholdAndWideWindows() {
        for width in [
            AppLayout.minimumSupportedWindowWidth,
            AppLayout.inspectorPresentationMinWindowWidth - 1,
            AppLayout.inspectorPresentationMinWindowWidth,
            1_280,
            1_600,
            2_400
        ] as [CGFloat] {
            let metrics = AppLayout.workspacePaneMetrics(for: width)
            XCTAssertTrue(metrics.respectsPaneBudget, "Pane budget regressed at \(width) points.")
            XCTAssertLessThanOrEqual(metrics.sidebarWindowShare, AppLayout.maximumSidebarWindowShare)
            XCTAssertLessThanOrEqual(metrics.inspectorWindowShare, AppLayout.maximumInspectorWindowShare)
            XCTAssertLessThanOrEqual(metrics.supportingPaneWindowShare, AppLayout.maximumSupportingPaneWindowShare)
            XCTAssertGreaterThanOrEqual(metrics.editorReadableWidth, AppLayout.editorMinimumReadableWidth)
        }
    }

    func testToolbarChromeTokensStayCompactForNativeToolbarGroups() {
        XCTAssertEqual(AppToolbarChrome.itemLineLimit, 1)
        XCTAssertLessThanOrEqual(AppToolbarChrome.statusLabelMinWidth, 72)
        XCTAssertGreaterThanOrEqual(AppToolbarChrome.metricMinWidth, 36)
        XCTAssertLessThanOrEqual(AppToolbarChrome.metricMinWidth, 48)
        XCTAssertEqual(
            AppToolbarChrome.statusClusterMinimumWidth,
            AppToolbarChrome.statusLabelMinWidth + AppToolbarChrome.metricMinWidth * 2
        )
        XCTAssertLessThanOrEqual(
            AppToolbarChrome.statusClusterMinimumWidth,
            160,
            "Toolbar status content should remain a compact native status group, not a wide custom capsule."
        )
        XCTAssertLessThanOrEqual(AppToolbarChrome.modePickerMinWidth, AppToolbarChrome.modePickerIdealWidth)
        XCTAssertLessThanOrEqual(AppToolbarChrome.modePickerIdealWidth, AppToolbarChrome.modePickerMaxWidth)
        XCTAssertLessThanOrEqual(AppToolbarChrome.modePickerMaxWidth, 260)
        XCTAssertLessThanOrEqual(
            AppToolbarChrome.statusClusterMinimumWidth + AppToolbarChrome.modePickerMaxWidth,
            AppLayout.editorMinimumReadableWidth,
            "Toolbar center/status affordances should not consume the editor readability budget."
        )

    }

    func testUnifiedWindowChromeTokensReserveTrafficLightsAndDragSpace() {
        XCTAssertEqual(AppWindowChrome.commandBarHeight, 46)
        XCTAssertGreaterThanOrEqual(AppWindowChrome.trafficLightClearance, 88)
        XCTAssertGreaterThan(AppWindowChrome.minimumDragRegionWidth, 0)
        XCTAssertLessThanOrEqual(
            AppWindowChrome.minimumDragRegionWidth,
            AppWindowChrome.commandBarHeight,
            "A drag-only region must stay compact rather than consuming command space."
        )
    }

    func testAdaptiveAppearanceTokensCoverNoLaunchGUIStates() {
        // Crisp solid panels: every pane is a defined MacScopeSurface, NOT translucent `.bar`
        // vibrancy. Definition comes from the surface value steps + hairlines, not blur (the
        // Nova-style "crisp panels" direction — replacing the muddy material that blurred panes).
        XCTAssertFalse(AppPaneRole.sidebar.usesMaterial)
        XCTAssertFalse(AppPaneRole.inspector.usesMaterial)
        XCTAssertFalse(AppPaneRole.debugger.usesMaterial)
        XCTAssertFalse(AppPaneRole.toolbar.usesMaterial)
        XCTAssertFalse(AppPaneRole.editor.usesMaterial)
        XCTAssertFalse(AppPaneRole.settings.usesMaterial)

        XCTAssertEqual(AppContrastChrome.hairlineWidth(for: .standard), AppContrastChrome.hairline)
        XCTAssertEqual(AppContrastChrome.hairlineWidth(for: .increased), AppContrastChrome.regularStroke)
        XCTAssertEqual(AppContrastChrome.strokeWidth(for: .standard), AppContrastChrome.regularStroke)
        XCTAssertEqual(AppContrastChrome.strokeWidth(for: .increased), AppContrastChrome.increasedStroke)
        XCTAssertEqual(AppFocusChrome.ringWidth(for: .standard), AppFocusChrome.ringWidth)
        XCTAssertEqual(AppFocusChrome.ringWidth(for: .increased), AppFocusChrome.increasedContrastRingWidth)
        XCTAssertEqual(AppStateChrome.separatorLineWidth(for: .standard), AppContrastChrome.hairline)
        XCTAssertEqual(AppStateChrome.separatorLineWidth(for: .increased), AppContrastChrome.regularStroke)

        XCTAssertNil(Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: true))
        XCTAssertNotNil(Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: false))
    }

    func testInteractionChromePrioritizesDisabledSelectionFocusAndHover() {
        XCTAssertEqual(
            AppInteractionChrome.sourceListState(
                isSelected: true,
                isFocused: true,
                isHovering: true,
                isEnabled: false,
                isActiveWindow: true
            ),
            .disabled
        )
        XCTAssertEqual(
            AppInteractionChrome.sourceListState(
                isSelected: true,
                isFocused: false,
                isHovering: false,
                isActiveWindow: true
            ),
            .selectedActive
        )
        XCTAssertEqual(
            AppInteractionChrome.sourceListState(
                isSelected: true,
                isFocused: false,
                isHovering: false,
                isActiveWindow: false
            ),
            .selectedInactive
        )
        XCTAssertEqual(
            AppInteractionChrome.sourceListState(
                isSelected: false,
                isFocused: true,
                isHovering: true,
                isActiveWindow: true
            ),
            .focused
        )
        XCTAssertEqual(
            AppInteractionChrome.sourceListState(
                isSelected: false,
                isFocused: false,
                isHovering: true,
                isActiveWindow: true
            ),
            .hovered
        )
        XCTAssertEqual(
            AppInteractionChrome.sourceListState(
                isSelected: false,
                isFocused: false,
                isHovering: false,
                isActiveWindow: true
            ),
            .normal
        )
        XCTAssertTrue(AppInteractionState.selectedActive.isSelected)
        XCTAssertTrue(AppInteractionState.selectedInactive.isSelected)
        XCTAssertFalse(AppInteractionState.focused.isSelected)
        XCTAssertEqual(
            AppInteractionChrome.rowStrokeWidth(isSelected: false, isFocused: false, contrast: .standard),
            AppContrastChrome.hairline
        )
        XCTAssertEqual(
            AppInteractionChrome.rowStrokeWidth(isSelected: true, isFocused: false, contrast: .standard),
            AppContrastChrome.regularStroke
        )
        XCTAssertEqual(
            AppInteractionChrome.rowStrokeWidth(isSelected: false, isFocused: true, contrast: .increased),
            AppContrastChrome.increasedStroke
        )
    }

    func testEditorInspectorAndStateChromeTokensKeepSurfacesReadable() {
        XCTAssertEqual(AppEditorChrome.contextBarHeight, 30)
        XCTAssertEqual(AppEditorChrome.disassemblyHeaderHeight, 26)
        XCTAssertEqual(AppEditorChrome.disassemblyRowHeight, 26)
        XCTAssertEqual(AppEditorChrome.disassemblyContinuationRowCount, 28)
        XCTAssertGreaterThanOrEqual(AppEditorChrome.disassemblyMinimumFlexibleWidth, 240)
        XCTAssertGreaterThan(AppEditorChrome.pseudocodeAddressWidth, AppEditorChrome.pseudocodeLineNumberWidth)
        XCTAssertGreaterThanOrEqual(AppEditorChrome.pseudocodeRowMinHeight, 24)
        XCTAssertEqual(AppEditorChrome.hexStatusBarHeight, 28)
        XCTAssertEqual(AppEditorChrome.hexBytesPerRow, 16)
        XCTAssertGreaterThanOrEqual(AppEditorChrome.hexMinimumReadableRows, 8)
        XCTAssertGreaterThanOrEqual(AppEditorChrome.hexOffsetColumnWidth, 112)

        XCTAssertEqual(AppInspectorChrome.headerIconWidth, 18)
        XCTAssertEqual(AppInspectorChrome.endpointLabelWidth, 42)
        XCTAssertEqual(AppInspectorChrome.metadataLabelWidth, 82)
        XCTAssertGreaterThanOrEqual(AppInspectorChrome.metadataRowMinHeight, 24)
        XCTAssertEqual(AppInspectorChrome.metadataDefaultValueLineLimit, 2)
        XCTAssertEqual(AppInspectorChrome.metadataExpandedValueLineLimit, 4)
        XCTAssertGreaterThanOrEqual(AppInspectorChrome.metadataLongValueCharacterThreshold, 44)
        XCTAssertEqual(AppInspectorChrome.metadataValueLineLimit(for: "arm64"), AppInspectorChrome.metadataDefaultValueLineLimit)
        XCTAssertEqual(
            AppInspectorChrome.metadataValueLineLimit(for: "/Applications/Example.app/Contents/MacOS/ExampleBinary"),
            AppInspectorChrome.metadataExpandedValueLineLimit
        )
        XCTAssertGreaterThanOrEqual(AppInspectorChrome.metadataValueMinimumScaleFactor, 0.86)
        XCTAssertGreaterThanOrEqual(AppInspectorChrome.endpointAddressMinimumScaleFactor, 0.84)

        XCTAssertGreaterThan(AppStateChrome.cardMaxWidth, AppStateChrome.copyMaxWidth)
        XCTAssertLessThanOrEqual(AppStateChrome.cardMaxWidth, 520)
        XCTAssertLessThanOrEqual(AppStateChrome.iconFrameSize, 56)
        XCTAssertEqual(AppStateChrome.iconCornerRadius, Lumen.Radius.lg)
        XCTAssertLessThanOrEqual(AppStateChrome.cardPadding, Lumen.Space.s7)
        XCTAssertGreaterThanOrEqual(AppStateChrome.minPanelWidth, 320)
        XCTAssertEqual(AppStateChrome.titleLineLimit, 2)
        XCTAssertGreaterThanOrEqual(AppStateChrome.detailLineLimit, 4)
        XCTAssertGreaterThanOrEqual(AppStateChrome.recoveryLineLimit, 3)
    }

    func testSettingsChromeKeepsNativePreferenceWindowBounded() {
        XCTAssertEqual(AppSettingsChrome.windowWidth, AppSettingsChrome.windowIdealWidth)
        XCTAssertEqual(
            AppSettingsChrome.windowMinWidth,
            AppSettingsChrome.categoryMinWidth + AppSettingsChrome.detailMinWidth
        )
        XCTAssertEqual(
            AppSettingsChrome.windowIdealWidth,
            AppSettingsChrome.categoryIdealWidth + AppSettingsChrome.detailIdealWidth
        )
        XCTAssertLessThanOrEqual(
            AppSettingsChrome.categoryMinWidth,
            AppSettingsChrome.categoryIdealWidth
        )
        XCTAssertLessThanOrEqual(
            AppSettingsChrome.categoryIdealWidth,
            AppSettingsChrome.categoryMaxWidth
        )
        XCTAssertEqual(AppSettingsChrome.contentPadding, Lumen.Space.s6)
        XCTAssertEqual(AppSettingsChrome.footnoteLineLimit, 3)
        XCTAssertGreaterThanOrEqual(AppSettingsChrome.detailMinWidth, AppStateChrome.cardMaxWidth)
        XCTAssertGreaterThanOrEqual(AppSettingsChrome.windowWidth, AppSettingsChrome.windowMinWidth)
        XCTAssertLessThanOrEqual(AppSettingsChrome.windowWidth, 800)
        // Sidebar Settings uses a stable laptop-safe height so asynchronous provider state and
        // category changes do not resize the window around the user's focus.
        XCTAssertEqual(AppSettingsChrome.windowMinHeight, AppSettingsChrome.stableContentHeight)
        XCTAssertGreaterThan(AppSettingsChrome.windowMaxHeight, AppSettingsChrome.windowMinHeight)
        XCTAssertGreaterThanOrEqual(AppSettingsChrome.windowMinHeight, 560)
        XCTAssertLessThanOrEqual(AppSettingsChrome.windowMaxHeight, 900)
    }

    func testDebuggerDeckHeightCannotStarveTheEditorSurface() {
        let presentation = WorkspaceBottomPanelPresentation()
        XCTAssertEqual(presentation.preferredHeight(debuggerExpanded: false), 48)
        XCTAssertEqual(presentation.preferredHeight(debuggerExpanded: true), 148)
        let geometry = DSBottomPanelGeometry(availableHeight: 840, dividerHeight: 1)
        let bottom = geometry.wholeBottomHeight(preferredHeight: 500, isPresented: true)
        XCTAssertLessThanOrEqual(bottom, 840 * DSBottomPanelGeometry.maximumBottomFraction)
        XCTAssertGreaterThanOrEqual(840 - bottom, DSBottomPanelGeometry.minimumEditorHeight)
        XCTAssertEqual(AppDebuggerChrome.targetPickerIconWidth, 16)
        XCTAssertEqual(AppDebuggerChrome.targetPickerRowVerticalPadding, 5)
        XCTAssertEqual(AppDebuggerChrome.consolePrefixWidth, 58)
        XCTAssertEqual(AppDebuggerChrome.deckKeyWidth, 116)
        XCTAssertEqual(AppDebuggerChrome.deckValueMinWidth, 180)
    }

    func testAccessibilityTextPoliciesRetainSelectionAndTableContext() {
        let item = SidebarItem(
            id: "function:main",
            title: "_render_listing",
            detail: "0x0000000100002000",
            systemImage: "curlybraces"
        )

        XCTAssertEqual(AppAccessibilityText.sidebarNavigatorLabel(tool: .symbols), "Symbols navigator")
        XCTAssertEqual(AppAccessibilityText.sourceListLabel(tool: .symbols), "Symbols source list")
        XCTAssertEqual(
            AppSidebarChrome.accessibilityLabel(for: item),
            "_render_listing, 0x0000000100002000"
        )
        XCTAssertEqual(
            AppSidebarChrome.accessibilityValue(for: item),
            "_render_listing, 0x0000000100002000"
        )
        XCTAssertEqual(AppSidebarChrome.accessibilityValue(for: nil), "No selection")
        XCTAssertGreaterThanOrEqual(
            AppSidebarChrome.accessibilityLabel(for: item).count,
            AppSidebarChrome.minimumAccessibilityLabelLength
        )

        let rowLabel = AppAccessibilityText.disassemblyRowLabel(
            address: "0x0000000100000004",
            mnemonic: "bl",
            operands: "_analyze_macho",
            hasBreakpoint: true,
            comment: "call analysis"
        )
        XCTAssertTrue(rowLabel.contains("0x0000000100000004"))
        XCTAssertTrue(rowLabel.contains("bl"))
        XCTAssertTrue(rowLabel.contains("_analyze_macho"))
        XCTAssertTrue(rowLabel.contains("breakpoint set"))
        XCTAssertTrue(rowLabel.contains("comment: call analysis"))
        XCTAssertEqual(AppAccessibilityText.breakpointButtonLabel(hasBreakpoint: false), "Set breakpoint")
        XCTAssertEqual(AppAccessibilityText.breakpointButtonLabel(hasBreakpoint: true), "Remove breakpoint")
        XCTAssertEqual(AppAccessibilityText.disassemblyTableLabel, "Disassembly table")
        XCTAssertEqual(
            AppAccessibilityText.inspectorLabel(selectionAddress: "0x0000000100000004"),
            "Inspector, selected instruction 0x0000000100000004"
        )
        XCTAssertEqual(
            AppAccessibilityText.xrefLabel(kind: "call", from: "0x1", to: "0x2"),
            "Call cross-reference, from 0x1, to 0x2"
        )
        XCTAssertEqual(
            AppAccessibilityText.debuggerTargetLabel(title: "Imported executable", status: "Ready", detail: "/tmp/tool"),
            "Imported executable, Ready. /tmp/tool"
        )
    }

    func testCommandPaletteCatalogExposesEditorTaxonomyAndReadiness() throws {
        XCTAssertEqual(
            CommandPaletteEntryKind.allCases,
            [.navigation, .workspace, .editor, .debug, .symbol, .address]
        )
        XCTAssertEqual(CommandPaletteEntryKind.allCases.map(\.sortRank), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(
            EditorScaffoldAffordance.allCases.map(\.title),
            ["Rename Symbol", "Add/Edit Comment", "Set Tag", "Mark as Data", "Mark as Code", "Edit Signature", "Define Type", "Define Switch Hint"]
        )

        let unavailableEntries = CommandPaletteCatalog.entries(
            functions: [],
            hasSelection: false,
            hasHexBytes: false
        )
        let breakpoint = try XCTUnwrap(unavailableEntries.first { $0.id == "command:toggle-breakpoint" })
        XCTAssertEqual(breakpoint.kind, .debug)
        XCTAssertFalse(breakpoint.availability.isAvailable)
        XCTAssertEqual(breakpoint.availability.unavailableReason, "Select an instruction before toggling a breakpoint.")
        XCTAssertEqual(breakpoint.trailingAccessoryTitle, "Control-Command-B")

        let hexSearch = try XCTUnwrap(unavailableEntries.first { $0.id == "command:search-hex-bytes" })
        XCTAssertEqual(hexSearch.kind, .navigation)
        XCTAssertFalse(hexSearch.availability.isAvailable)

        let commentScaffold = try XCTUnwrap(unavailableEntries.first { $0.id == "editor-scaffold:editComment" })
        XCTAssertEqual(commentScaffold.kind, .editor)
        XCTAssertFalse(commentScaffold.availability.isAvailable)
        XCTAssertEqual(commentScaffold.trailingAccessoryTitle, "Unavailable")
        XCTAssertTrue(commentScaffold.accessibilityLabel.contains("unavailable"))

        let availableEntries = CommandPaletteCatalog.entries(
            functions: [],
            hasSelection: true,
            hasHexBytes: true
        )
        XCTAssertTrue(try XCTUnwrap(availableEntries.first { $0.id == "command:toggle-breakpoint" }).availability.isAvailable)
        XCTAssertTrue(try XCTUnwrap(availableEntries.first { $0.id == "command:search-hex-bytes" }).availability.isAvailable)
    }

    @MainActor
    func testDocumentCommandPolicyModelsSaveAsAutosaveAndConflicts() throws {
        let untitledStore = WorkspaceStore.bootstrap()
        let untitled = untitledStore.documentCommandPolicy

        XCTAssertEqual(untitled.displayName, "Untitled Workspace")
        XCTAssertEqual(untitled.statusTitle, "Not saved as a MacScope package")
        XCTAssertEqual(untitled.primarySave.intent, .saveAs)
        XCTAssertEqual(untitled.primarySave.title, "Save...")
        XCTAssertEqual(untitled.primarySave.keyboardShortcutDescription, "Command-S")
        XCTAssertTrue(untitled.primarySave.isEnabled)
        XCTAssertTrue(untitled.saveAs.isEnabled)
        XCTAssertFalse(untitled.autosave.isEnabled)
        XCTAssertFalse(untitled.hasConflict)

        let cleanMetadata = workspaceDocumentMetadata(
            workspaceID: 42,
            workspaceName: "Clean Workspace",
            packagePath: "/tmp/Clean Workspace.mscope",
            isDirty: false
        )
        let clean = WorkspaceDocumentCommandPolicy.resolve(metadata: cleanMetadata)
        XCTAssertEqual(clean.displayName, "Clean Workspace")
        XCTAssertEqual(clean.statusTitle, "Saved")
        XCTAssertEqual(clean.primarySave.intent, .save)
        XCTAssertTrue(clean.primarySave.isEnabled)
        XCTAssertFalse(clean.autosave.isEnabled)
        XCTAssertEqual(clean.autosave.disabledReason, "No unsaved document changes are pending.")

        let dirtyMetadata = workspaceDocumentMetadata(
            workspaceID: 43,
            workspaceName: "Dirty Workspace",
            packagePath: "/tmp/Dirty Workspace.mscope",
            isDirty: true
        )
        let dirty = WorkspaceDocumentCommandPolicy.resolve(metadata: dirtyMetadata)
        XCTAssertEqual(dirty.statusTitle, "Unsaved Changes")
        XCTAssertEqual(dirty.primarySave.intent, .save)
        XCTAssertTrue(dirty.primarySave.isEnabled)
        XCTAssertTrue(dirty.autosave.isEnabled)
        XCTAssertNil(dirty.autosave.disabledReason)
        XCTAssertTrue(dirty.conflictActions.isEmpty)

        let conflictReason = "Package changed on disk after the workspace was opened."
        let conflictedMetadata = workspaceDocumentMetadata(
            workspaceID: 44,
            workspaceName: "Conflicted Workspace",
            packagePath: "/tmp/Conflicted Workspace.mscope",
            isDirty: true,
            conflictReason: conflictReason
        )
        let conflicted = WorkspaceDocumentCommandPolicy.resolve(metadata: conflictedMetadata)

        XCTAssertEqual(conflicted.statusTitle, conflictReason)
        XCTAssertEqual(conflicted.primarySave.intent, .save)
        XCTAssertFalse(conflicted.primarySave.isEnabled)
        XCTAssertEqual(conflicted.primarySave.disabledReason, "Resolve the package conflict or use Save As before overwriting.")
        XCTAssertTrue(conflicted.saveAs.isEnabled)
        XCTAssertFalse(conflicted.autosave.isEnabled)
        XCTAssertEqual(conflicted.autosave.disabledReason, "Autosave is paused until the package conflict is resolved.")
        XCTAssertEqual(conflicted.conflictActions.map(\.intent), [.saveAsCopy, .reloadFromDisk, .keepLocalVersion])
        XCTAssertEqual(conflicted.conflictActions.map(\.systemImage), ["doc.on.doc", "arrow.clockwise", "checkmark.circle"])
        XCTAssertEqual(conflicted.conflictActions.filter(\.isDestructive).map(\.intent), [.reloadFromDisk])
    }

    func testDocumentCommandPolicyProjectsEveryLiveSessionState() throws {
        let location = WorkspaceDocumentLocation(
            canonicalURL: URL(fileURLWithPath: "/tmp/Live Workspace.mscope"),
            fileObjectIdentity: nil
        )
        let observation = WorkspacePackageExternalVersion(
            location: location,
            condition: .valid,
            observationSHA256: "observation",
            manifestSHA256: "manifest",
            validatedContentSHA256: "content",
            boundedReason: nil
        )

        let untitled = WorkspaceDocumentCommandPolicy.resolve(
            snapshot: documentSessionSnapshot(location: nil)
        )
        XCTAssertEqual(untitled.displayName, "Untitled Workspace")
        XCTAssertEqual(untitled.statusTitle, "Untitled")
        XCTAssertEqual(untitled.primarySave.intent, .saveAs)

        let clean = WorkspaceDocumentCommandPolicy.resolve(
            snapshot: documentSessionSnapshot(
                location: location,
                expected: observation
            )
        )
        XCTAssertEqual(clean.displayName, "Live Workspace")
        XCTAssertEqual(clean.statusTitle, "Saved")
        XCTAssertFalse(clean.autosave.isEnabled)

        let dirty = WorkspaceDocumentCommandPolicy.resolve(
            snapshot: documentSessionSnapshot(
                location: location,
                expected: observation,
                dirty: true
            )
        )
        XCTAssertEqual(dirty.statusTitle, "Unsaved Changes")
        XCTAssertTrue(dirty.autosave.isEnabled)

        let saving = WorkspaceDocumentCommandPolicy.resolve(
            snapshot: documentSessionSnapshot(
                location: location,
                expected: observation,
                dirty: true,
                activeSave: WorkspaceDocumentActiveSave(
                    requestID: WorkspaceDocumentSaveRequestID(rawValue: UUID()),
                    saveGeneration: WorkspaceDocumentSaveGeneration(rawValue: 1),
                    capturedMutationGeneration: WorkspaceDocumentMutationGeneration(rawValue: 1),
                    intent: .save
                )
            )
        )
        XCTAssertEqual(saving.statusTitle, "Saving")
        XCTAssertFalse(saving.primarySave.isEnabled)

        let conflictCases: [(WorkspaceDocumentConflictReason, String, Bool)] = [
            (.externallyChanged, "Package Changed on Disk", true),
            (.destinationMissing, "Package Missing", true),
            (.destinationInvalid("invalid"), "Package Invalid", true),
            (.destinationUnverifiable("unverifiable"), "Package State Could Not Be Verified", false),
            (.destinationOwnedByAnotherWindow, "Package Changed on Disk", true),
        ]
        for (reason, title, keepLocalEnabled) in conflictCases {
            let conflict = WorkspaceDocumentConflict(
                expected: observation,
                observed: observation,
                reason: reason
            )
            let policy = WorkspaceDocumentCommandPolicy.resolve(
                snapshot: documentSessionSnapshot(
                    location: location,
                    expected: observation,
                    dirty: true,
                    conflict: conflict
                )
            )
            XCTAssertEqual(policy.statusTitle, title)
            XCTAssertFalse(policy.primarySave.isEnabled)
            XCTAssertFalse(policy.autosave.isEnabled)
            XCTAssertEqual(
                policy.conflictActions.first { $0.intent == .keepLocalVersion }?.isEnabled,
                keepLocalEnabled
            )
        }

        let failed = WorkspaceDocumentCommandPolicy.resolve(
            snapshot: documentSessionSnapshot(
                location: location,
                expected: observation,
                dirty: true,
                lastFailure: "document-write-failed"
            )
        )
        XCTAssertEqual(failed.statusTitle, "Save Failed")
    }

    private func documentSessionSnapshot(
        location: WorkspaceDocumentLocation?,
        expected: WorkspacePackageExternalVersion? = nil,
        dirty: Bool = false,
        activeSave: WorkspaceDocumentActiveSave? = nil,
        conflict: WorkspaceDocumentConflict? = nil,
        lastFailure: String? = nil
    ) -> WorkspaceDocumentSessionSnapshot {
        WorkspaceDocumentSessionSnapshot(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            documentID: UUID(),
            workspaceID: UUID(),
            location: location,
            expectedExternalVersion: expected,
            mutationGeneration: WorkspaceDocumentMutationGeneration(rawValue: dirty ? 1 : 0),
            savedMutationGeneration: WorkspaceDocumentMutationGeneration(rawValue: 0),
            hasUnsavedChanges: dirty,
            nextSaveGeneration: WorkspaceDocumentSaveGeneration(rawValue: 1),
            activeSave: activeSave,
            conflict: conflict,
            lastFailure: lastFailure
        )
    }

    func testRecentDocumentCommandModelsExposeLifecycleBadges() {
        let clean = workspaceDocumentMetadata(
            workspaceID: 1,
            workspaceName: "Clean Workspace",
            packagePath: "/tmp/Clean Workspace.mscope",
            isDirty: false
        )
        let dirty = workspaceDocumentMetadata(
            workspaceID: 2,
            workspaceName: "Dirty Workspace",
            packagePath: "/tmp/Dirty Workspace.mscope",
            isDirty: true
        )
        let conflicted = workspaceDocumentMetadata(
            workspaceID: 3,
            workspaceName: "Conflicted Workspace",
            packagePath: "/tmp/Conflicted Workspace.mscope",
            isDirty: true,
            conflictReason: "Package changed on disk after the workspace was opened."
        )

        let commands = RecentWorkspaceDocumentCommand.commands(from: [conflicted, dirty, clean])

        XCTAssertEqual(commands.map(\.id), ["recent-workspace:3", "recent-workspace:2", "recent-workspace:1"])
        XCTAssertEqual(commands.map(\.title), ["Conflicted Workspace", "Dirty Workspace", "Clean Workspace"])
        XCTAssertEqual(commands.map(\.subtitle), ["/tmp", "/tmp", "/tmp"])
        XCTAssertEqual(commands.map(\.packagePath), [
            "/tmp/Conflicted Workspace.mscope",
            "/tmp/Dirty Workspace.mscope",
            "/tmp/Clean Workspace.mscope"
        ])
        XCTAssertEqual(commands.map(\.statusTitle), ["Conflict", "Unsaved Changes", nil])
        XCTAssertEqual(commands.map(\.systemImage), ["exclamationmark.triangle", "pencil", "doc"])
        XCTAssertEqual(commands.map(\.allowsAutosave), [false, true, true])
    }

    @MainActor
    func testCommandPaletteRankingPreservesScoresCategoriesAndStableTies() {
        let rows: [(String, CommandPaletteEntryKind, String, String, [String])] = [
            ("keyword", .navigation, "Open", "Commands", ["render"]),
            ("tie-first", .symbol, "Render symbol", "Symbols", []),
            ("contains", .navigation, "Show render output", "Commands", []),
            ("exact", .symbol, "Render", "Symbols", []),
            ("subtitle", .navigation, "Show", "Render output", []),
            ("tie-second", .symbol, "Render symbol", "Symbols", []),
            ("category-first", .navigation, "Render address", "Commands", []),
            ("excluded", .navigation, "Save", "Commands", [])
        ]
        let entries = rows.map { id, kind, title, subtitle, keywords in
            CommandPaletteEntry(
                id: id, kind: kind, title: title, subtitle: subtitle,
                systemImage: "magnifyingglass", keywords: keywords,
                action: .showGoToAddress
            )
        }
        XCTAssertEqual(
            CommandPaletteCatalog.filteredEntries(
                query: "  RENDER  ", baseEntries: entries, indexedAddresses: []
            ).map(\.id),
            ["exact", "category-first", "tie-first", "tie-second", "subtitle", "contains", "keyword"]
        )
        XCTAssertEqual(
            CommandPaletteCatalog.filteredEntries(
                query: "", baseEntries: entries, indexedAddresses: []
            ).map(\.id),
            entries.map(\.id)
        )
    }

    @MainActor
    func testCommandPaletteFilteringPromotesAddressesAndSearchesEditorAffordances() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let entries = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: store.selectedInstruction != nil,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty
        )
        let indexedAddresses = Set(store.snapshot.instructions.map(\.address))

        let addressMatch = try XCTUnwrap(
            CommandPaletteCatalog.filteredEntries(
                query: "0x1000_00004",
                baseEntries: entries,
                indexedAddresses: indexedAddresses
            ).first
        )
        XCTAssertEqual(addressMatch.kind, .address)
        XCTAssertEqual(addressMatch.title, "Go to 0x0000000100000004")
        XCTAssertEqual(addressMatch.subtitle, "Indexed Instruction")

        let commentMatch = try XCTUnwrap(
            CommandPaletteCatalog.filteredEntries(
                query: "comment",
                baseEntries: entries,
                indexedAddresses: indexedAddresses
            ).first
        )
        XCTAssertEqual(commentMatch.id, "editor-scaffold:editComment")
        XCTAssertEqual(commentMatch.kind, .editor)
        // The comment affordance is now wired to the override store and available
        // when an instruction is selected (the preview fixture has a selection).
        XCTAssertTrue(commentMatch.availability.isAvailable)

        let symbolMatch = try XCTUnwrap(
            CommandPaletteCatalog.filteredEntries(
                query: "render",
                baseEntries: entries,
                indexedAddresses: indexedAddresses
            ).first
        )
        XCTAssertEqual(symbolMatch.kind, .symbol)
        XCTAssertEqual(symbolMatch.title, "_render_listing")

        XCTAssertEqual(parseHexAddress("0x1000_00004"), 0x1000_00004)
        XCTAssertNil(parseHexAddress("not hex"))
    }

    @MainActor
    func testCommandPaletteShowsAndSearchesRenamedFunctionsByCustomName() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let target = store.snapshot.functions.first { $0.name == "_render_listing" }!
        let overrides: [UInt64: AddressOverride] = [
            target.startAddress: AddressOverride(customName: "renderListing")
        ]
        let entries = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: store.selectedInstruction != nil,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty,
            addressOverrides: overrides
        )
        let indexed = Set(store.snapshot.instructions.map(\.address))
        let entryID = "symbol:\(target.id.uuidString)"

        // The symbol entry titles with the custom name.
        let symbolEntry = try XCTUnwrap(entries.first { $0.id == entryID })
        XCTAssertEqual(symbolEntry.title, "renderListing")

        // Searchable by the custom name…
        let byCustom = CommandPaletteCatalog.filteredEntries(
            query: "renderListing", baseEntries: entries, indexedAddresses: indexed
        )
        XCTAssertTrue(byCustom.contains { $0.id == entryID })

        // …and still by the original parsed symbol (muscle memory survives renames).
        let byParsed = CommandPaletteCatalog.filteredEntries(
            query: "_render_listing", baseEntries: entries, indexedAddresses: indexed
        )
        XCTAssertTrue(byParsed.contains { $0.id == entryID })
    }

    @MainActor
    func testTagAndColorOverridesAreUndoable() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00004 as UInt64

        store.setTag(address, tag: "parser")
        XCTAssertEqual(store.snapshot.tag(at: address), "parser")
        store.setColorTag(address, color: .blue)
        XCTAssertEqual(store.snapshot.colorTag(at: address), .blue)

        store.undoManager.undo() // reverse the color edit only
        XCTAssertNil(store.snapshot.colorTag(at: address))
        XCTAssertEqual(store.snapshot.tag(at: address), "parser")

        store.undoManager.undo() // reverse the tag -> entry removed
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        store.undoManager.redo() // re-apply the tag
        XCTAssertEqual(store.snapshot.tag(at: address), "parser")
    }

    @MainActor
    func testSetColorTagAtSelectionAppliesAndClears() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(0x1000_00000)

        store.setColorTagAtSelection(.orange)
        XCTAssertEqual(store.snapshot.colorTag(at: 0x1000_00000), .orange)

        store.setColorTagAtSelection(nil) // clearing prunes the (now empty) override
        XCTAssertNil(store.snapshot.colorTag(at: 0x1000_00000))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000_00000)])
    }

    func testDataDirectiveRendersLittleEndianLongAndByteFallback() {
        // The canonical 4-byte ARM64 width renders as a little-endian .long word.
        let long = WorkspaceSnapshot.dataDirective(forBytes: "ff 83 00 d1")
        XCTAssertEqual(long.mnemonic, ".long")
        XCTAssertEqual(long.operands, "0xd10083ff")
        // Other widths fall back to a .byte list (in source order).
        let bytes = WorkspaceSnapshot.dataDirective(forBytes: "de ad be")
        XCTAssertEqual(bytes.mnemonic, ".byte")
        XCTAssertEqual(bytes.operands, "0xde, 0xad, 0xbe")
    }

    @MainActor
    func testMarkAsDataIsUndoableAndBlendsIntoSnapshot() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00004 as UInt64
        XCTAssertFalse(store.snapshot.isData(at: address))

        store.setIsData(address, true)
        XCTAssertTrue(store.snapshot.isData(at: address))

        store.undoManager.undo() // un-mark -> override pruned (it carried only the data flag)
        XCTAssertFalse(store.snapshot.isData(at: address))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        store.undoManager.redo() // re-mark as data
        XCTAssertTrue(store.snapshot.isData(at: address))
    }

    @MainActor
    func testMarkSelectionAsDataAndCodeGuardsAndApplies() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(0x1000_00000)

        store.markSelectionAsData(true)
        XCTAssertTrue(store.snapshot.isData(at: 0x1000_00000))

        store.markSelectionAsData(false) // back to code prunes the (now empty) override
        XCTAssertFalse(store.snapshot.isData(at: 0x1000_00000))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000_00000)])
    }

    @MainActor
    func testCommandPaletteExposesMarkAsDataAndCode() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let entries = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: store.selectedInstruction != nil,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty
        )
        let data = try XCTUnwrap(entries.first { $0.id == "editor-scaffold:markAsData" })
        XCTAssertEqual(data.title, "Mark as Data")
        XCTAssertTrue(data.availability.isAvailable)
        let code = try XCTUnwrap(entries.first { $0.id == "editor-scaffold:markAsCode" })
        XCTAssertEqual(code.title, "Mark as Code")
        XCTAssertTrue(code.availability.isAvailable)
    }

    @MainActor
    func testCommandPaletteExposesTagAndColorCommands() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let entries = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: store.selectedInstruction != nil,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty
        )

        // The Set Tag affordance is wired to the override store, available with a selection.
        let tagEntry = try XCTUnwrap(entries.first { $0.id == "editor-scaffold:setTag" })
        XCTAssertEqual(tagEntry.title, "Set Tag")
        XCTAssertTrue(tagEntry.availability.isAvailable)

        // A "Set Color: Blue" command carries the matching action.
        let blueEntry = try XCTUnwrap(entries.first { $0.id == "color:blue" })
        XCTAssertEqual(blueEntry.title, "Set Color: Blue")
        XCTAssertTrue(blueEntry.availability.isAvailable)
        guard case .setColorTag(.blue) = blueEntry.action else {
            return XCTFail("Expected the blue entry to carry .setColorTag(.blue)")
        }

        // And a Clear Color command exists.
        let clearEntry = try XCTUnwrap(entries.first { $0.id == "color:clear" })
        guard case .setColorTag(.none) = clearEntry.action else {
            return XCTFail("Expected the clear entry to carry .setColorTag(nil)")
        }
    }

    @MainActor
    func testSignatureOverrideIsUndoableAndPrunesWhenCleared() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64
        XCTAssertNil(store.snapshot.signatureOverride(at: address))

        let signature = FunctionSignatureOverride(
            returnType: "void",
            args: [ArgOverride(index: 0, name: "ctx", type: "Context*")],
            isNoReturn: true
        )
        store.setSignature(address, signature)
        XCTAssertEqual(store.snapshot.signatureOverride(at: address), signature)

        store.undoManager.undo() // the override carried only the signature -> pruned
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.signatureOverride(at: address), signature)

        store.setSignature(address, FunctionSignatureOverride()) // empty clears + prunes
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
    }

    @MainActor
    func testSignatureEditorSeedsRecoveredSignatureAndCommitApplies() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(0x1000_00000) // inside _main

        store.beginSignatureEditAtSelection()
        let request = try XCTUnwrap(store.signatureEditorRequest)
        XCTAssertEqual(request.address, 0x1000_00000)
        XCTAssertEqual(request.functionName, "_main")
        XCTAssertFalse(request.returnType.isEmpty)   // recovered baseline
        XCTAssertTrue(request.args.isEmpty)          // _main(void)

        var draft = request
        draft.returnType = "MyResult"
        let authoredRow = ArgDraft(index: 0, name: "ctx", type: "Context*")
        draft.args = [authoredRow]
        draft.parameterListIntent = .authoritative
        draft.variadicState = .fixed
        draft.isNoReturn = true
        store.commitSignatureEditor(draft)

        XCTAssertNil(store.signatureEditorRequest)
        let applied = try XCTUnwrap(store.snapshot.signatureOverride(at: 0x1000_00000))
        XCTAssertEqual(applied.returnType, "MyResult")
        XCTAssertEqual(
            applied.args,
            [ArgOverride(rowToken: authoredRow.rowToken, name: "ctx", type: "Context*")]
        )
        XCTAssertTrue(applied.isNoReturn)
    }

    func testSignatureEditorEmptyDeclaredCopyDistinguishesVariadicOnlyFromVoid() {
        let unspecified = SignatureEditorPresentation.declaredEmptyState(for: .unspecified)
        let fixed = SignatureEditorPresentation.declaredEmptyState(for: .fixed)
        let variadic = SignatureEditorPresentation.declaredEmptyState(for: .variadic)

        XCTAssertEqual(unspecified, fixed)
        XCTAssertEqual(fixed.text, "void — explicitly declares no parameters")
        XCTAssertEqual(
            fixed.accessibilityLabel,
            "Void. This signature explicitly declares no parameters."
        )
        XCTAssertEqual(
            variadic.text,
            "… — no named parameters; accepts trailing arguments"
        )
        XCTAssertEqual(
            variadic.accessibilityLabel,
            "No named parameters. This signature accepts trailing variadic arguments."
        )
        XCTAssertFalse(variadic.text.localizedCaseInsensitiveContains("void"))
    }

    func testSignatureEditorParameterSourceHintExplainsBothModes() {
        XCTAssertEqual(
            SignatureEditorPresentation.parameterSourceAccessibilityHint,
            "Use Recovered keeps the named-parameter list analysis-owned. Declare Parameters saves the visible rows in source order."
        )
    }

    // MARK: - Type definitions (struct/union/enum/typedef catalog)

    func testStructTypeLayoutFollowsCAlignment() {
        // Field offsets follow the C ABI: uint32@0, uint16@4, then the pointer (align 8) is
        // padded from 6 to 8. An unknown aggregate type (no catalog) is unsized.
        let type = TypeDefinition(kind: .struct, name: "Header", fields: [
            FieldDef(name: "magic", type: "uint32_t"),
            FieldDef(name: "flags", type: "uint16_t"),
            FieldDef(name: "next", type: "Header*")
        ])
        XCTAssertEqual(type.memberLayout().map(\.offset), [0, 4, 8])
        XCTAssertEqual(TypeDefinition.size(ofType: "Header*"), 8)
        XCTAssertNil(TypeDefinition.size(ofType: "Header"))
    }

    func testUnionLayoutAtZeroAndEnumTypedefHaveNoMemberLayout() {
        let union = TypeDefinition(kind: .union, name: "Word", fields: [
            FieldDef(name: "asInt", type: "int32_t"),
            FieldDef(name: "asFloat", type: "float")
        ])
        XCTAssertEqual(union.memberLayout().map(\.offset), [0, 0])

        let enumType = TypeDefinition(kind: .enum, name: "Color", fields: [FieldDef(name: "red", type: "")])
        XCTAssertTrue(enumType.memberLayout().isEmpty)
        let typedef = TypeDefinition(kind: .typedef, name: "Handle", fields: [FieldDef(name: "raw", type: "void*")])
        XCTAssertTrue(typedef.memberLayout().isEmpty)
    }

    func testStructLayoutRespectsNaturalAlignment() {
        // C ABI: each field is aligned to its natural alignment. uint64 must land at 8, not 7.
        let type = TypeDefinition(kind: .struct, name: "H", fields: [
            FieldDef(name: "a", type: "uint32_t"),  // @0 (align 4)
            FieldDef(name: "b", type: "int16_t"),   // @4 (align 2)
            FieldDef(name: "c", type: "char"),       // @6 (align 1)
            FieldDef(name: "d", type: "uint64_t")    // @8 (align 8 — padded from 7)
        ])
        XCTAssertEqual(type.memberLayout().map(\.offset), [0, 4, 6, 8])
        // Size is padded up to the struct's own alignment (8): 8 + 8 = 16.
        XCTAssertEqual(TypeDefinition.size(ofType: "H", in: ["H": type]), 16)
    }

    func testStructLayoutHandlesArrayFields() {
        // int64_t arr[3] occupies 24 bytes with 8-byte alignment.
        let type = TypeDefinition(kind: .struct, name: "A", fields: [
            FieldDef(name: "n", type: "int32_t"),       // @0
            FieldDef(name: "arr", type: "int64_t[3]"),  // @8 (aligned), size 24
            FieldDef(name: "tail", type: "int32_t")     // @32
        ])
        XCTAssertEqual(type.memberLayout().map(\.offset), [0, 8, 32])
        XCTAssertEqual(TypeDefinition.size(ofType: "int64_t[3]", in: [:]), 24)
    }

    func testStructLayoutHandlesNestedStructsRecursively() {
        let inner = TypeDefinition(kind: .struct, name: "Inner", fields: [
            FieldDef(name: "a", type: "int32_t"),  // @0
            FieldDef(name: "b", type: "int64_t")   // @8 → Inner size 16, align 8
        ])
        let outer = TypeDefinition(kind: .struct, name: "Outer", fields: [
            FieldDef(name: "inner", type: "struct Inner"),  // @0, size 16
            FieldDef(name: "x", type: "int32_t")            // @16
        ])
        let catalog = ["Inner": inner, "Outer": outer]
        XCTAssertEqual(TypeDefinition.size(ofType: "Inner", in: catalog), 16)
        XCTAssertEqual(outer.memberLayout(in: catalog).map(\.offset), [0, 16])
    }

    func testRecursiveByValueStructIsUnsizedNotCrash() {
        // struct A { struct A a; } is illegal C but possible in a user catalog — it must
        // degrade to unsized (nil), never infinite-recurse into a stack overflow.
        let a = TypeDefinition(kind: .struct, name: "A", fields: [FieldDef(name: "a", type: "struct A")])
        XCTAssertNil(TypeDefinition.size(ofType: "A", in: ["A": a]))
        // A pointer-to-self is fine (8 bytes, recursion stops at the pointer).
        let b = TypeDefinition(kind: .struct, name: "B", fields: [FieldDef(name: "next", type: "struct B *")])
        XCTAssertEqual(TypeDefinition.size(ofType: "B", in: ["B": b]), 8)
    }

    func testStructMemberReadingDecodesLittleEndianPrimitives() {
        let type = TypeDefinition(kind: .struct, name: "Rec", fields: [
            FieldDef(name: "count", type: "int32_t"),
            FieldDef(name: "mask", type: "uint16_t"),
            FieldDef(name: "ptr", type: "void*")
        ])
        var bytes = Data()
        bytes.append(contentsOf: [0x01, 0x00, 0x00, 0x00])             // count = 1        @0
        bytes.append(contentsOf: [0xFF, 0xFF])                          // mask = 65535     @4
        bytes.append(contentsOf: [0x00, 0x00])                          // padding — ptr aligns to 8
        bytes.append(contentsOf: [0xEF, 0xBE, 0xAD, 0xDE, 0, 0, 0, 0])  // ptr = 0xdeadbeef @8

        let reading = StructMemberReading(type: type, bytes: bytes, baseOffset: 0)
        XCTAssertEqual(reading.rows.map(\.offset), [0, 4, 8])
        XCTAssertEqual(reading.rows.map(\.name), ["count", "mask", "ptr"])
        XCTAssertEqual(reading.rows.map(\.value), ["1", "65535", "0x00000000deadbeef"])
    }

    func testStructMemberReadingMarksFieldsPastLoadedTailAsDash() {
        let type = TypeDefinition(kind: .struct, name: "Rec", fields: [
            FieldDef(name: "head", type: "int32_t"),
            FieldDef(name: "tail", type: "int64_t") // 8 bytes at offset 4 -> past tail
        ])
        let bytes = Data([0x07, 0x00, 0x00, 0x00, 0x00]) // only 5 bytes loaded
        let reading = StructMemberReading(type: type, bytes: bytes, baseOffset: 0)
        XCTAssertEqual(reading.rows[0].value, "7")
        XCTAssertEqual(reading.rows[1].value, "—")

        // A nil baseOffset (selection not byte-mapped) reads every field as a dash.
        let unmapped = StructMemberReading(type: type, bytes: bytes, baseOffset: nil)
        XCTAssertEqual(unmapped.rows.map(\.value), ["—", "—"])
    }

    func testAppliedTypeResolvesByNameAndDegradesWhenTypeMissing() {
        var snapshot = AnalysisEngine.previewSnapshot()
        let header = TypeDefinition(kind: .struct, name: "Header", fields: [FieldDef(name: "magic", type: "uint32_t")])
        snapshot.typeDefinitions = [header]
        snapshot.addressOverrides = [
            .primary(0x1_0000_0000): AddressOverride(appliedTypeName: "Header"),
            .primary(0x1_0000_0008): AddressOverride(appliedTypeName: "Ghost") // not in catalog
        ]
        XCTAssertEqual(snapshot.appliedType(at: 0x1_0000_0000), header)
        XCTAssertNil(snapshot.appliedType(at: 0x1_0000_0008)) // dangling name -> no type
        XCTAssertNil(snapshot.appliedType(at: 0x1_0000_0010)) // no override at all
    }

    @MainActor
    func testAppliedTypeOverrideIsUndoableAndPrunesWhenCleared() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64
        store.upsertTypeDefinition(TypeDefinition(kind: .struct, name: "Header"))

        store.setAppliedType(address, name: "Header")
        XCTAssertEqual(store.snapshot.appliedType(at: address)?.name, "Header")

        store.undoManager.undo() // reverse apply -> override carried only the type, so pruned
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.appliedType(at: address)?.name, "Header")

        store.setAppliedType(address, name: nil) // clearing prunes the now-empty override
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
    }

    @MainActor
    func testTypeDefinitionCatalogUpsertAndDeleteAreUndoable() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty)
        let header = TypeDefinition(kind: .struct, name: "Header", fields: [FieldDef(name: "magic", type: "uint32_t")])

        store.upsertTypeDefinition(header)
        XCTAssertEqual(store.snapshot.typeDefinitions, [header])

        // Re-upserting the same id edits in place rather than appending a duplicate.
        var renamed = header
        renamed.name = "FileHeader"
        store.upsertTypeDefinition(renamed)
        XCTAssertEqual(store.snapshot.typeDefinitions, [renamed])

        store.deleteTypeDefinition(id: header.id)
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty)

        store.undoManager.undo() // restore the deleted type (in its renamed form)
        XCTAssertEqual(store.snapshot.typeDefinitions, [renamed])
        store.undoManager.undo() // reverse the rename
        XCTAssertEqual(store.snapshot.typeDefinitions, [header])
        store.undoManager.undo() // reverse the insert
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty)
    }

    @MainActor
    func testTypeEditorSeedsBlankStructAndCommitUpsertsDefinition() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.beginTypeDefinition()
        var draft = try XCTUnwrap(store.typeEditorRequest)
        XCTAssertEqual(draft.kind, .struct)
        XCTAssertTrue(draft.name.isEmpty)

        draft.name = "Header"
        draft.fields = [
            TypeFieldDraft(name: "magic", type: "uint32_t"),
            TypeFieldDraft(name: "", type: "") // blank row dropped on commit
        ]
        store.commitTypeEditor(draft)

        XCTAssertNil(store.typeEditorRequest)
        let defined = try XCTUnwrap(store.snapshot.typeDefinitions.first)
        XCTAssertEqual(defined.name, "Header")
        XCTAssertEqual(defined.fields, [
            FieldDef(name: "magic", type: "uint32_t", declaratorSemanticsV1: .ordinary),
        ])

        // Committing a blank name cancels without defining anything new.
        store.beginTypeDefinition()
        var blank = try XCTUnwrap(store.typeEditorRequest)
        blank.name = "   "
        store.commitTypeEditor(blank)
        XCTAssertNil(store.typeEditorRequest)
        XCTAssertEqual(store.snapshot.typeDefinitions.count, 1)
    }

    @MainActor
    func testApplyTypeAtSelectionAppliesAndClears() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.upsertTypeDefinition(TypeDefinition(kind: .struct, name: "Header"))
        store.selectInstruction(0x1000_00000)

        store.applyTypeAtSelection(name: "Header")
        XCTAssertEqual(store.snapshot.appliedType(at: 0x1000_00000)?.name, "Header")

        store.applyTypeAtSelection(name: nil) // clears + prunes the empty override
        XCTAssertNil(store.snapshot.appliedType(at: 0x1000_00000))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000_00000)])
    }

    @MainActor
    func testCommandPaletteExposesDefineTypeAndApplyTypeCommands() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let header = TypeDefinition(kind: .struct, name: "Header")
        store.upsertTypeDefinition(header)

        let entries = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: store.selectedInstruction != nil,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty,
            typeDefinitions: store.snapshot.typeDefinitions
        )

        // Define Type is workspace-global: available even with no selected instruction.
        let define = try XCTUnwrap(entries.first { $0.id == "editor-scaffold:defineType" })
        XCTAssertEqual(define.title, "Define Type")
        XCTAssertTrue(define.availability.isAvailable)

        // One "Apply Type: <name>" command per defined type, carrying the apply action.
        let apply = try XCTUnwrap(entries.first { $0.id == "type-apply:\(header.id.uuidString)" })
        XCTAssertEqual(apply.title, "Apply Type: Header")
        guard case .applyType("Header") = apply.action else {
            return XCTFail("Expected the apply entry to carry .applyType(\"Header\")")
        }

        // And a Clear Type command.
        let clear = try XCTUnwrap(entries.first { $0.id == "type-apply:clear" })
        guard case .applyType(.none) = clear.action else {
            return XCTFail("Expected the clear entry to carry .applyType(nil)")
        }
    }

    @MainActor
    func testCommandPaletteExposesEditAndDeleteTypeCommands() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let header = TypeDefinition(kind: .struct, name: "Header")
        store.upsertTypeDefinition(header)

        // No selection: Edit/Delete are workspace-global catalog ops, still available.
        let entries = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: false,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty,
            typeDefinitions: store.snapshot.typeDefinitions
        )

        let edit = try XCTUnwrap(entries.first { $0.id == "type-edit:\(header.id.uuidString)" })
        XCTAssertEqual(edit.title, "Edit Type: Header")
        XCTAssertTrue(edit.availability.isAvailable)
        guard case .editType(let editID) = edit.action, editID == header.id else {
            return XCTFail("Expected the edit entry to carry .editType(header.id)")
        }

        let delete = try XCTUnwrap(entries.first { $0.id == "type-delete:\(header.id.uuidString)" })
        XCTAssertEqual(delete.title, "Delete Type: Header")
        XCTAssertTrue(delete.availability.isAvailable)
        guard case .deleteType(let deleteID) = delete.action, deleteID == header.id else {
            return XCTFail("Expected the delete entry to carry .deleteType(header.id)")
        }

        // Apply, by contrast, stays gated on a selected instruction.
        let apply = try XCTUnwrap(entries.first { $0.id == "type-apply:\(header.id.uuidString)" })
        XCTAssertFalse(apply.availability.isAvailable)
    }

    @MainActor
    func testTypeEditorRejectsDuplicateNameAndKeepsEditorOpen() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.upsertTypeDefinition(TypeDefinition(kind: .struct, name: "Header"))

        // A NEW type (fresh id) named "Header" collides with the existing one.
        store.beginTypeDefinition()
        var draft = try XCTUnwrap(store.typeEditorRequest)
        draft.name = "Header"
        store.commitTypeEditor(draft)

        // Rejected: editor stays open, catalog unchanged, an issue is surfaced.
        XCTAssertNotNil(store.typeEditorRequest)
        XCTAssertEqual(store.snapshot.typeDefinitions.count, 1)
        XCTAssertEqual(store.lastIssue, "A type named “Header” already exists.")

        // Editing the SAME type (matching id) and keeping its name is allowed.
        let existing = try XCTUnwrap(store.snapshot.typeDefinitions.first)
        store.beginTypeDefinition(editing: existing)
        var sameNameDraft = try XCTUnwrap(store.typeEditorRequest)
        sameNameDraft.kind = .union // mutable UI state cannot change an existing definition's kind
        store.commitTypeEditor(sameNameDraft)
        XCTAssertNil(store.typeEditorRequest)
        XCTAssertEqual(store.snapshot.typeDefinitions.count, 1)
        XCTAssertEqual(store.snapshot.typeDefinitions.first?.kind, .struct)
    }

    func testStructMemberReadingEscapesQuoteAndBackslashChars() {
        let type = TypeDefinition(kind: .struct, name: "Chars", fields: [
            FieldDef(name: "quote", type: "char"),
            FieldDef(name: "slash", type: "char"),
            FieldDef(name: "letter", type: "char")
        ])
        let bytes = Data([0x27, 0x5C, 0x41]) // '  \  A
        let reading = StructMemberReading(type: type, bytes: bytes, baseOffset: 0)
        XCTAssertEqual(reading.rows.map(\.value), ["'\\''", "'\\\\'", "'A'"])
    }

    // MARK: - Switch/Case hints (manual jump-table override)

    func testSwitchHintResolvesBaseRelativeAndAbsoluteTargets() {
        // Base-relative: 4-byte signed offsets added to the table base.
        let relBytes: [UInt64: [UInt8]] = [
            0x1000: [0x40, 0x00, 0x00, 0x00], // +0x40 -> 0x1040
            0x1004: [0xF0, 0xFF, 0xFF, 0xFF]  // -0x10 -> 0x0FF0
        ]
        let relReader: (UInt64, Int) -> Data? = { va, n in
            guard let b = relBytes[va], b.count == n else { return nil }
            return Data(b)
        }
        let relHint = SwitchHintOverride(tableBase: 0x1000, entryCount: 2, entryStride: 4, isRelativeToBase: true)
        XCTAssertEqual(relHint.resolveTargets(readBytes: relReader), [0x1040, 0x0FF0])

        // Absolute: 8-byte target addresses read verbatim.
        let absBytes: [UInt64: [UInt8]] = [
            0x2000: [0x00, 0x20, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00], // 0x100002000
            0x2008: [0x10, 0x20, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]  // 0x100002010
        ]
        let absReader: (UInt64, Int) -> Data? = { va, n in
            guard let b = absBytes[va], b.count == n else { return nil }
            return Data(b)
        }
        let absHint = SwitchHintOverride(tableBase: 0x2000, entryCount: 2, entryStride: 8, isRelativeToBase: false)
        XCTAssertEqual(absHint.resolveTargets(readBytes: absReader), [0x1_0000_2000, 0x1_0000_2010])

        // A missing entry yields nil rather than a truncated table.
        let overrun = SwitchHintOverride(tableBase: 0x1000, entryCount: 3, entryStride: 4, isRelativeToBase: true)
        XCTAssertNil(overrun.resolveTargets(readBytes: relReader))
    }

    func testSwitchHintIsEmptyAndCodableRoundTripWithinOverride() throws {
        XCTAssertTrue(SwitchHintOverride(tableBase: 0x1000, entryCount: 0).isEmpty)
        XCTAssertFalse(SwitchHintOverride(tableBase: 0x1000, entryCount: 1).isEmpty)

        let override = AddressOverride(
            customName: "dispatch",
            switchHint: SwitchHintOverride(tableBase: 0x1_0000_2000, entryCount: 4, entryStride: 8, isRelativeToBase: false)
        )
        let decoded = try JSONDecoder().decode(AddressOverride.self, from: JSONEncoder().encode(override))
        XCTAssertEqual(decoded, override)
        XCTAssertEqual(decoded.switchHint?.entryStride, 8)

        // An override carrying only a switch hint is non-empty; a 0-case one prunes.
        XCTAssertFalse(AddressOverride(switchHint: SwitchHintOverride(tableBase: 0, entryCount: 2)).isEmpty)
        XCTAssertTrue(AddressOverride(switchHint: SwitchHintOverride(tableBase: 0, entryCount: 0)).isEmpty)
    }

    func testDataShapeIsEmptyAndCodableRoundTripWithinOverride() throws {
        // isEmpty pruning per kind.
        XCTAssertTrue(DataShapeOverride(kind: .array, elementCount: 0).isEmpty)
        XCTAssertFalse(DataShapeOverride(kind: .array, elementCount: 1).isEmpty)
        XCTAssertTrue(DataShapeOverride(kind: .alignment, alignment: 1).isEmpty)
        XCTAssertFalse(DataShapeOverride(kind: .alignment, alignment: 8).isEmpty)
        XCTAssertFalse(DataShapeOverride(kind: .string, isNullTerminated: true).isEmpty)
        XCTAssertTrue(DataShapeOverride(kind: .string, isNullTerminated: false, stringLength: 0).isEmpty)

        // Each kind survives a Codable (.mscope) round-trip embedded in an override.
        for shape in [
            DataShapeOverride(kind: .array, elementType: "int32_t", elementCount: 16),
            DataShapeOverride(kind: .alignment, alignment: 16),
            DataShapeOverride(kind: .string, isNullTerminated: true),
            DataShapeOverride(kind: .string, isNullTerminated: false, stringLength: 12),
        ] {
            let override = AddressOverride(customName: "blob", dataShape: shape)
            let decoded = try JSONDecoder().decode(AddressOverride.self, from: JSONEncoder().encode(override))
            XCTAssertEqual(decoded, override, "shape \(shape.kind) must round-trip through Codable")
        }

        // An override carrying only a (non-empty) shape is non-empty; an empty one prunes.
        XCTAssertFalse(AddressOverride(dataShape: DataShapeOverride(kind: .array, elementCount: 2)).isEmpty)
        XCTAssertTrue(AddressOverride(dataShape: DataShapeOverride(kind: .array, elementCount: 0)).isEmpty)

        // An unknown kind degrades to .array rather than throwing (forward-compat).
        let forward = try JSONDecoder().decode(
            DataShapeOverride.self,
            from: Data(#"{"kind":"matrix","elementCount":3}"#.utf8)
        )
        XCTAssertEqual(forward.kind, .array)

        // The Make-Array per-element display format round-trips inside the existing
        // data_shape_json column (no schema change) and survives the override package.
        let formatted = DataShapeOverride(kind: .array, elementType: "int32_t", elementCount: 4, elementDisplayFormat: .hex)
        let formattedOverride = AddressOverride(dataShape: formatted)
        let decodedFormatted = try JSONDecoder().decode(AddressOverride.self, from: JSONEncoder().encode(formattedOverride))
        XCTAssertEqual(decodedFormatted.dataShape?.elementDisplayFormat, .hex)
        XCTAssertEqual(decodedFormatted, formattedOverride)

        // An unknown/older format string degrades to nil (the array renders its
        // signature only) rather than throwing the whole package load.
        let staleFormat = try JSONDecoder().decode(
            DataShapeOverride.self,
            from: Data(#"{"kind":"array","elementCount":4,"elementDisplayFormat":"radix99"}"#.utf8)
        )
        XCTAssertNil(staleFormat.elementDisplayFormat)
    }

    func testArrayElementValuesAcrossFormatMatrix() {
        // The Make-Array per-element formatter reuses the OperandFormat matrix: the
        // same bytes render correctly in each chosen format. 2 × int32_t over [1, 256].
        let bytes = Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00])
        let reader: (UInt64, Int) -> Data? = { _, count in bytes.prefix(count) }
        func values(_ format: OperandFormat) -> [String] {
            WorkspaceSnapshot.arrayElementValues(
                forShape: DataShapeOverride(kind: .array, elementType: "int32_t", elementCount: 2, elementDisplayFormat: format),
                at: 0, count: 2, format: format, readBytes: reader
            )
        }
        XCTAssertEqual(values(.decimal), ["1", "256"])
        XCTAssertEqual(values(.hex), ["0x1", "0x100"])
        XCTAssertEqual(values(.octal), ["0o1", "0o400"])
        XCTAssertEqual(values(.binary), ["0b1", "0b100000000"])
        XCTAssertEqual(values(.unsignedDecimal), ["1", "256"])
        // 1 is non-printable as an int32 char-magnitude? 0x01 is non-printable -> hex.
        XCTAssertEqual(values(.character), ["0x1", "0x100"])

        // An unknown/oversized element width or a zero count yields no values (the
        // caller then falls back to the bare type signature).
        XCTAssertTrue(WorkspaceSnapshot.arrayElementValues(
            forShape: DataShapeOverride(kind: .array, elementType: "weirdtype", elementCount: 2, elementDisplayFormat: .hex),
            at: 0, count: 2, format: .hex, readBytes: reader).isEmpty == false,
            "unknown element type degrades to 1-byte width and still decodes")
    }

    @MainActor
    func testDataShapeIsUndoableAndPrunesWhenCleared() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let target = 0x1000_00004 as UInt64
        store.makeArray(target, elementType: "int32_t", count: 16)
        XCTAssertEqual(store.snapshot.dataShape(at: target)?.elementCount, 16)
        XCTAssertTrue(store.snapshot.isData(at: target))

        store.undoManager.undo()
        XCTAssertNil(store.snapshot.dataShape(at: target))
        XCTAssertFalse(store.snapshot.isData(at: target))

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.dataShape(at: target)?.kind, .array)

        // Clearing the shape prunes the override entirely.
        store.setDataShape(target, nil)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(target)])
    }

    func testResolvedJumpTablesMergesHintsOverAutoRecovery() {
        var snapshot = AnalysisEngine.previewSnapshot()
        let brA = 0x1_0000_0000 as UInt64 // first instruction; hexBytes[0..3] = ff 83 00 d1
        let brB = 0x1_0000_0004 as UInt64
        snapshot.jumpTables = [brA: [0xAAAA], brB: [0xBBBB]]

        // No hints -> byte-identical to the auto-recovered map.
        XCTAssertEqual(snapshot.resolvedJumpTables(in: .primary), [brA: [0xAAAA], brB: [0xBBBB]])

        // An absolute 1-entry hint at brA reads ff 83 00 d1 -> 0xd10083ff and OVERRIDES
        // the auto entry; the untouched brB auto entry survives.
        snapshot.addressOverrides[.primary(brA)] = AddressOverride(
            switchHint: SwitchHintOverride(tableBase: brA, entryCount: 1, entryStride: 4, isRelativeToBase: false)
        )
        let merged = snapshot.resolvedJumpTables(in: .primary)
        XCTAssertEqual(merged[brA], [0xd100_83ff])
        XCTAssertEqual(merged[brB], [0xBBBB])
    }

    @MainActor
    func testSwitchHintOverrideIsUndoableAndPrunesWhenCleared() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64
        XCTAssertNil(store.snapshot.switchHint(at: address))

        let hint = SwitchHintOverride(tableBase: 0x1_0000_2000, entryCount: 3, entryStride: 8, isRelativeToBase: false)
        store.setSwitchHint(address, hint)
        XCTAssertEqual(store.snapshot.switchHint(at: address), hint)

        store.undoManager.undo() // the override carried only the hint -> pruned
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.switchHint(at: address), hint)

        store.setSwitchHint(address, nil) // clearing prunes the empty override
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
    }

    @MainActor
    func testSwitchHintEditorSeedsAndCommitAppliesAndClears() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(0x1000_00000)

        store.beginSwitchHintEditAtSelection()
        var draft = try XCTUnwrap(store.switchHintEditorRequest)
        XCTAssertEqual(draft.address, 0x1000_00000)
        XCTAssertEqual(draft.entryStrideText, "4")  // default stride
        XCTAssertTrue(draft.isRelativeToBase)        // default form

        draft.tableBaseText = "0x100002000"
        draft.entryCountText = "5"
        draft.entryStrideText = "8"
        draft.isRelativeToBase = false
        store.commitSwitchHintEditor(draft)

        XCTAssertNil(store.switchHintEditorRequest)
        let applied = try XCTUnwrap(store.snapshot.switchHint(at: 0x1000_00000))
        XCTAssertEqual(applied.tableBase, 0x1_0000_2000)
        XCTAssertEqual(applied.entryCount, 5)
        XCTAssertEqual(applied.entryStride, 8)
        XCTAssertFalse(applied.isRelativeToBase)

        // A zero case count on commit clears the hint (an explicit remove).
        store.beginSwitchHintEditAtSelection()
        var clearDraft = try XCTUnwrap(store.switchHintEditorRequest)
        clearDraft.entryCountText = "0"
        store.commitSwitchHintEditor(clearDraft)
        XCTAssertNil(store.snapshot.switchHint(at: 0x1000_00000))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000_00000)])
    }

    @MainActor
    func testSwitchHintEditorRejectsOutOfRangeCountAndStrideWithoutCoercing() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(0x1000_00000)

        // An absurd case count is rejected: editor stays open, nothing persisted.
        store.beginSwitchHintEditAtSelection()
        var bigCount = try XCTUnwrap(store.switchHintEditorRequest)
        bigCount.tableBaseText = "0x100002000"
        bigCount.entryCountText = String(SwitchHintOverride.maxEntryCount + 1)
        store.commitSwitchHintEditor(bigCount)
        XCTAssertNotNil(store.switchHintEditorRequest)
        XCTAssertNil(store.snapshot.switchHint(at: 0x1000_00000))
        XCTAssertEqual(store.lastIssue, "Case count must be \(SwitchHintOverride.maxEntryCount) or fewer.")

        // An out-of-range entry size is REJECTED, not silently coerced to 4.
        var badStride = try XCTUnwrap(store.switchHintEditorRequest)
        badStride.entryCountText = "3"
        badStride.entryStrideText = "16"
        store.commitSwitchHintEditor(badStride)
        XCTAssertNotNil(store.switchHintEditorRequest)
        XCTAssertNil(store.snapshot.switchHint(at: 0x1000_00000))
        XCTAssertEqual(store.lastIssue, "Entry size must be 1–8 bytes.")

        // A blank entry size still defaults to 4 (the convenience path).
        var blankStride = try XCTUnwrap(store.switchHintEditorRequest)
        blankStride.tableBaseText = "0x100002000"
        blankStride.entryCountText = "3"
        blankStride.entryStrideText = ""
        store.commitSwitchHintEditor(blankStride)
        XCTAssertNil(store.switchHintEditorRequest)
        XCTAssertEqual(store.snapshot.switchHint(at: 0x1000_00000)?.entryStride, 4)
    }

    func testSwitchHintResolveRejectsAbsurdEntryCount() {
        // Defense-in-depth: a degenerate count (e.g. from a hand-edited .mscope)
        // resolves to nil rather than over-reserving, before any byte is read.
        let hint = SwitchHintOverride(tableBase: 0x1000, entryCount: SwitchHintOverride.maxEntryCount + 1, entryStride: 4)
        XCTAssertNil(hint.resolveTargets(readBytes: { _, _ in XCTFail("must not read bytes"); return nil }))
    }

    // MARK: - Operand display format

    func testOperandFormatRendersImmediateInEachFormat() {
        XCTAssertEqual(OperandFormat.apply(to: "sp, sp, #0x20", format: .decimal), "sp, sp, #32")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #65", format: .hex), "w0, #0x41")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #65", format: .character), "w0, 'A'")
        // The first immediate inside a memory operand reformats (a useful offset view).
        XCTAssertEqual(OperandFormat.apply(to: "x0, [sp, #0x10]", format: .decimal), "x0, [sp, #16]")
        // No immediate -> unchanged passthrough.
        XCTAssertEqual(OperandFormat.apply(to: "x0, x1", format: .hex), "x0, x1")
        XCTAssertEqual(OperandFormat.apply(to: "", format: .hex), "")
        // Non-printable character falls back to hex; quote/backslash are escaped.
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0x0", format: .character), "w0, #0x0")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0x27", format: .character), "w0, '\\''")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0x5c", format: .character), "w0, '\\\\'")
    }

    func testOperandFormatMatrixRendersSameImmediateAcrossAllFormats() {
        // Table-driven across the FULL operand-format matrix: the same immediate
        // (#65) renders correctly in every format. `apply` re-renders the first `#`
        // immediate in place.
        let cases: [(format: OperandFormat, expected: String)] = [
            (.decimal, "w0, #65"),
            (.unsignedDecimal, "w0, #65"),
            (.hex, "w0, #0x41"),
            (.octal, "w0, #0o101"),
            (.binary, "w0, #0b1000001"),
            (.character, "w0, 'A'"),
            (.negativeHex, "w0, #0x41"),
        ]
        for (format, expected) in cases {
            XCTAssertEqual(OperandFormat.apply(to: "w0, #65", format: format), expected,
                           "format \(format.rawValue) of #65")
        }
    }

    func testOperandFormatMatrixEdgeValues() {
        // Edge: zero renders identically (no sign, base prefix) in every numeric base.
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0", format: .decimal), "w0, #0")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0", format: .unsignedDecimal), "w0, #0")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0", format: .hex), "w0, #0x0")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0", format: .octal), "w0, #0o0")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0", format: .binary), "w0, #0b0")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0", format: .negativeHex), "w0, #0x0")
        // 0 is non-printable -> character falls back to hex.
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0", format: .character), "w0, #0x0")

        // Edge: the unsigned 64-bit max (all bits set).
        let max = "x0, #0xffffffffffffffff"
        XCTAssertEqual(OperandFormat.apply(to: max, format: .decimal), "x0, #18446744073709551615")
        XCTAssertEqual(OperandFormat.apply(to: max, format: .unsignedDecimal), "x0, #18446744073709551615")
        XCTAssertEqual(OperandFormat.apply(to: max, format: .octal), "x0, #0o1777777777777777777777")
        // All-bits-set is -1 under a two's-complement (signed) hex reading.
        XCTAssertEqual(OperandFormat.apply(to: max, format: .negativeHex), "x0, #-0x1")
    }

    func testOperandFormatNegativeAndTwosComplementReadings() {
        // An explicit negative: unsignedDecimal reinterprets it as its two's-complement
        // unsigned value; signed decimal keeps the negative.
        XCTAssertEqual(OperandFormat.apply(to: "w0, #-16", format: .decimal), "w0, #-16")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #-1", format: .unsignedDecimal), "w0, #18446744073709551615")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #-16", format: .octal), "w0, #-0o20")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #-2", format: .binary), "w0, #-0b10")
        // A top-bit-set magnitude reads as negative under two's-complement hex.
        XCTAssertEqual(OperandFormat.apply(to: "x0, #0xffffffffffffff00", format: .negativeHex), "x0, #-0x100")
        // A small positive value is positive under every signed reading.
        XCTAssertEqual(OperandFormat.apply(to: "w0, #0x10", format: .negativeHex), "w0, #0x10")
    }

    func testOperandFormatLeavesFractionalFPImmediatesUnchanged() {
        // A fractional FP immediate must NOT have its integer head reformatted into
        // a garbage token like "#0x1.00000000" — the whole operand passes through.
        XCTAssertEqual(OperandFormat.apply(to: "s0, #1.00000000", format: .hex), "s0, #1.00000000")
        XCTAssertEqual(OperandFormat.apply(to: "d0, #-2.50000000", format: .decimal), "d0, #-2.50000000")
        XCTAssertEqual(OperandFormat.apply(to: "s0, #0.0", format: .character), "s0, #0.0")
    }

    func testOperandFormatHandlesFull64BitUnsignedImmediates() {
        // 64-bit immediates with the high bit set exceed Int64.max; they must still
        // reformat (logical masks, high movz) rather than silently passing through.
        XCTAssertEqual(
            OperandFormat.apply(to: "x0, x0, #0xffffffffffffff00", format: .decimal),
            "x0, x0, #18446744073709551360"
        )
        XCTAssertEqual(
            OperandFormat.apply(to: "x8, #18446744073709551360", format: .hex),
            "x8, #0xffffffffffffff00"
        )
        // A negative immediate keeps its sign in both directions.
        XCTAssertEqual(OperandFormat.apply(to: "w0, #-0x10", format: .decimal), "w0, #-16")
        XCTAssertEqual(OperandFormat.apply(to: "w0, #-16", format: .hex), "w0, #-0x10")
    }

    func testOperandFormatOverrideCodableLockstepAndSnapshotAccessors() throws {
        let override = AddressOverride(operandFormat: .character)
        XCTAssertFalse(override.isEmpty)
        let decoded = try JSONDecoder().decode(AddressOverride.self, from: JSONEncoder().encode(override))
        XCTAssertEqual(decoded, override)
        XCTAssertEqual(decoded.operandFormat, .character)
        XCTAssertTrue(AddressOverride(operandFormat: nil).isEmpty)

        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.addressOverrides = [.primary(0x1_0000_0000): AddressOverride(operandFormat: .decimal)]
        XCTAssertEqual(snapshot.operandFormat(at: 0x1_0000_0000), .decimal)
        XCTAssertEqual(snapshot.displayOperands(at: 0x1_0000_0000, default: "sp, sp, #0x20"), "sp, sp, #32")
        // An address without an operand-format override is unchanged.
        XCTAssertEqual(snapshot.displayOperands(at: 0x1_0000_0008, default: "sp, sp, #0x20"), "sp, sp, #0x20")
    }

    @MainActor
    func testOperandFormatOverrideIsUndoableAndPrunesWhenCleared() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64
        XCTAssertNil(store.snapshot.operandFormat(at: address))

        store.setOperandFormat(address, .hex)
        XCTAssertEqual(store.snapshot.operandFormat(at: address), .hex)

        store.undoManager.undo() // override carried only the format -> pruned
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        store.undoManager.redo()
        XCTAssertEqual(store.snapshot.operandFormat(at: address), .hex)

        store.setOperandFormat(address, nil) // clearing prunes the empty override
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
    }

    @MainActor
    func testSetOperandFormatAtSelectionAppliesAndClears() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectInstruction(0x1000_00000)
        store.setOperandFormatAtSelection(.character)
        XCTAssertEqual(store.snapshot.operandFormat(at: 0x1000_00000), .character)
        store.setOperandFormatAtSelection(nil)
        XCTAssertNil(store.snapshot.operandFormat(at: 0x1000_00000))
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000_00000)])
    }

    // MARK: - Save / Save As (document package write)

    @MainActor
    func testWriteDocumentPackageRoundTripsAuthoringAndSetsDocumentURL() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        // Author overrides so we can confirm authoring persists through Save.
        store.setOperandFormat(0x1000_00000, .hex)
        store.setTag(0x1000_00004, tag: "parser")
        XCTAssertNil(store.documentURL)

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("Fixture.mscope", isDirectory: true)

        XCTAssertTrue(store.writeDocumentPackage(to: url))
        let canonicalURL = try WorkspaceDocumentLocation.canonicalized(from: url).canonicalURL
        XCTAssertEqual(store.documentURL, canonicalURL) // becomes the target for a plain Save
        XCTAssertNil(store.saveError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Reopening the written package restores the authored overrides + the URL.
        let reopened = try WorkspaceStore.restoredPackage(from: url)
        XCTAssertEqual(reopened.snapshot.operandFormat(at: 0x1000_00000), .hex)
        XCTAssertEqual(reopened.snapshot.tag(at: 0x1000_00004), "parser")
        XCTAssertEqual(reopened.documentURL, canonicalURL)
    }

    @MainActor
    func testWriteDocumentPackageReportsFailureWithoutSettingDocumentURL() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        // Use a regular file as the package's parent so the write cannot succeed.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        let url = blocker.appendingPathComponent("Nested.mscope", isDirectory: true)

        XCTAssertFalse(store.writeDocumentPackage(to: url))
        XCTAssertNotNil(store.saveError)       // surfaced via the save-specific alert channel
        XCTAssertNil(store.lastIssue)          // NOT routed through the import banner
        XCTAssertNil(store.documentURL)        // unchanged on failure
    }

    // MARK: - Cross-reference accessors

    func testXRefAccessorsSplitDirectionAndAggregateCallers() {
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.functions = [FunctionSummary(id: UUID(), name: "_target", startAddress: 0x2000, endAddress: 0x2100, confidence: 1)]
        snapshot.xrefs = [
            XRef(id: UUID(), from: 0x1000, to: 0x2000, kind: "call"),
            XRef(id: UUID(), from: 0x1000, to: 0x2000, kind: "call"),   // duplicate call site
            XRef(id: UUID(), from: 0x2050, to: 0x4000, kind: "string")  // data ref from inside _target
        ]
        XCTAssertEqual(snapshot.xrefs(to: 0x2000).count, 2)
        XCTAssertEqual(snapshot.xrefs(from: 0x2050).map(\.kind), ["string"])

        let target = snapshot.functions[0]
        XCTAssertEqual(snapshot.callers(of: target).count, 1)   // deduped by (from,to)
        XCTAssertTrue(snapshot.callees(of: target).isEmpty)     // the string ref is not a call
    }

    func testSymbolizedLabelResolvesAcrossReferenceKinds() {
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.functions = [FunctionSummary(id: UUID(), name: "_main", startAddress: 0x2000, endAddress: 0x2100, confidence: 1)]
        snapshot.stringLiterals = [StringLiteralSummary(id: UUID(), value: "hello", address: 0x4000, sourceSection: "__cstring", byteLength: 6)]
        snapshot.objcSelectors = [0x8000: "init"]
        snapshot.symbols = []
        snapshot.exports = []

        XCTAssertEqual(snapshot.symbolizedLabel(for: 0x2000), "_main")
        XCTAssertEqual(snapshot.symbolizedLabel(for: 0x4000), "\"hello\"")
        XCTAssertEqual(snapshot.symbolizedLabel(for: 0x8000), "@selector(init)")
        XCTAssertEqual(snapshot.symbolizedLabel(for: 0x2010), "_main+0x10") // strictly inside _main
        let unknown = snapshot.symbolizedLabel(for: 0x9999)
        XCTAssertTrue(unknown.hasPrefix("0x") && unknown.contains("9999")) // hex fallback, not "_main+huge"
    }

    // MARK: - Go-To raw addresses + symbols

    func testContainsLoadedAddressAndSymbolNameResolution() {
        let snapshot = AnalysisEngine.previewSnapshot()
        // The loaded byte window starts at the first instruction (0x100000000), 40 bytes.
        XCTAssertTrue(snapshot.containsLoadedAddress(0x1000_00000))
        XCTAssertTrue(snapshot.containsLoadedAddress(0x1000_00027))
        XCTAssertFalse(snapshot.containsLoadedAddress(0x1000_00028)) // one past the window
        XCTAssertFalse(snapshot.containsLoadedAddress(0x0FFF_FFFFF)) // before the base

        XCTAssertEqual(snapshot.address(forSymbolName: "_main"), 0x1000_00000)
        XCTAssertEqual(snapshot.address(forSymbolName: "main"), 0x1000_00000)        // underscore-tolerant
        XCTAssertEqual(snapshot.address(forSymbolName: "_ANALYZE_MACHO"), 0x1000_01000) // case-insensitive
        XCTAssertNil(snapshot.address(forSymbolName: "does_not_exist"))
        XCTAssertNil(snapshot.address(forSymbolName: ""))
    }

    @MainActor
    func testGoToAddressReachesInstructionsHexWindowAndRejectsOutOfRange() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()

        store.goToAddress(0x1000_00000) // an indexed instruction
        XCTAssertEqual(store.selectedAddress, 0x1000_00000)
        XCTAssertEqual(store.editorMode, .disassembly)

        store.goToAddress(0x1000_00002) // inside the loaded window, no instruction -> hex
        XCTAssertEqual(store.selectedAddress, 0x1000_00002)
        XCTAssertEqual(store.editorMode, .hex)

        store.lastIssue = nil
        store.goToAddress(0x1000_09999) // outside the loaded binary -> surfaced issue
        XCTAssertNotNil(store.lastIssue)
    }

    @MainActor
    func testGoToQueryResolvesHexAndSymbol() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()

        XCTAssertTrue(store.goTo(query: "0x100000000")) // 0x-prefixed hex
        XCTAssertEqual(store.selectedAddress, 0x1000_00000)
        XCTAssertEqual(store.editorMode, .disassembly)

        XCTAssertTrue(store.goTo(query: "main")) // symbol name (underscore-tolerant -> _main)
        XCTAssertEqual(store.selectedAddress, 0x1000_00000)

        XCTAssertTrue(store.goTo(query: "100000000")) // bare hex fallback
        XCTAssertEqual(store.selectedAddress, 0x1000_00000)

        store.lastIssue = nil
        XCTAssertFalse(store.goTo(query: "not a symbol")) // neither hex nor symbol
        XCTAssertNotNil(store.lastIssue)

        // A parseable hex that is OUT OF RANGE must return false (so the sheet stays
        // open) and surface the out-of-binary issue — not silently dismiss.
        store.lastIssue = nil
        XCTAssertFalse(store.goTo(query: "0x100090000"))
        XCTAssertNotNil(store.lastIssue)
        XCTAssertFalse(store.goTo(query: "100090000")) // same via the bare-hex path
    }

    @MainActor
    func testGoToPrefersSymbolOverBareHexForAmbiguousQuery() {
        var snapshot = AnalysisEngine.previewSnapshot()
        // A function whose name looks like a hex number.
        snapshot.functions = [FunctionSummary(id: UUID(), name: "deadbeef", startAddress: 0x1000_00010, endAddress: 0x1000_00014, confidence: 1)]
        let store = WorkspaceStore(workspaceName: "Ambiguous", snapshot: snapshot, engine: AnalysisEngine())

        XCTAssertTrue(store.goTo(query: "deadbeef"))
        XCTAssertEqual(store.selectedAddress, 0x1000_00010) // the symbol, NOT 0xdeadbeef
    }

    @MainActor
    func testCommandPaletteExposesOperandFormatCommands() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let entries = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: true,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty
        )
        let hex = try XCTUnwrap(entries.first { $0.id == "operand-format:hex" })
        XCTAssertEqual(hex.title, "Format Operand: Hexadecimal")
        XCTAssertTrue(hex.availability.isAvailable)
        guard case .setOperandFormat(.hex) = hex.action else {
            return XCTFail("Expected the hex entry to carry .setOperandFormat(.hex)")
        }
        let clear = try XCTUnwrap(entries.first { $0.id == "operand-format:clear" })
        guard case .setOperandFormat(.none) = clear.action else {
            return XCTFail("Expected the clear entry to carry .setOperandFormat(nil)")
        }

        // Gated on a selection (per-value family, like colors).
        let withoutSelection = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: false,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty
        )
        let gated = try XCTUnwrap(withoutSelection.first { $0.id == "operand-format:decimal" })
        XCTAssertFalse(gated.availability.isAvailable)
    }

    @MainActor
    func testCommandPaletteExposesDefineSwitchHint() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let entries = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: true,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty
        )
        let entry = try XCTUnwrap(entries.first { $0.id == "editor-scaffold:defineSwitchHint" })
        XCTAssertEqual(entry.title, "Define Switch Hint")
        XCTAssertTrue(entry.availability.isAvailable)

        // It is selection-gated (not workspace-global like Define Type).
        let withoutSelection = CommandPaletteCatalog.entries(
            functions: store.snapshot.functions,
            hasSelection: false,
            hasHexBytes: !store.snapshot.hexBytes.isEmpty
        )
        let gated = try XCTUnwrap(withoutSelection.first { $0.id == "editor-scaffold:defineSwitchHint" })
        XCTAssertFalse(gated.availability.isAvailable)
    }

    func testHexNavigationStateMapsSelectionIntoRows() {
        let state = HexNavigationState(
            byteCount: 64,
            baseAddress: 0x1000,
            selectedAddress: 0x1014
        )
        XCTAssertEqual(state.rowCount, 4)
        XCTAssertEqual(state.selectedByteOffset, 20)
        XCTAssertEqual(state.selectedRowIndex, 1)
        XCTAssertEqual(state.selectedOffsetDescription, "+0x0014")
        XCTAssertEqual(state.selectionSummary, "Selected +0x0014, row 2")
        XCTAssertEqual(state.byteSummary, "64 bytes, 4 rows")

        let partialRow = HexNavigationState(
            byteCount: 17,
            baseAddress: 0x1000,
            selectedAddress: 0x1000
        )
        XCTAssertEqual(partialRow.rowCount, 2)

        let outside = HexNavigationState(
            byteCount: 64,
            baseAddress: 0x1000,
            selectedAddress: 0x2000
        )
        XCTAssertNil(outside.selectedByteOffset)
        XCTAssertEqual(outside.selectionSummary, "Selection outside loaded bytes")
    }

    func testDataInspectorDecodesSelectionBytesAcrossPrimitiveTypes() {
        // (a) Little-endian 0x2A decodes to 42 across all integer widths.
        let fortyTwo = DataInspectorReading(
            bytes: Data([0x2A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            baseAddress: 0x1000,
            selectedAddress: 0x1000
        )
        XCTAssertTrue(fortyTwo.isResolvable)
        XCTAssertEqual(fortyTwo.uint8, "42")
        XCTAssertEqual(fortyTwo.int8, "42")
        XCTAssertEqual(fortyTwo.uint16, "42")
        XCTAssertEqual(fortyTwo.int16, "42")
        XCTAssertEqual(fortyTwo.uint32, "42")
        XCTAssertEqual(fortyTwo.uint64, "42")

        // (b) 0xFF is -1 signed, 255 unsigned.
        let highBit = DataInspectorReading(
            bytes: Data([0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            baseAddress: 0x1000,
            selectedAddress: 0x1000
        )
        XCTAssertEqual(highBit.int8, "-1")
        XCTAssertEqual(highBit.uint8, "255")

        // (c) Float 1.0 == 0x3F800000 little-endian.
        let floatOne = DataInspectorReading(
            bytes: Data([0x00, 0x00, 0x80, 0x3F]),
            baseAddress: 0x1000,
            selectedAddress: 0x1000
        )
        XCTAssertEqual(floatOne.float32.flatMap(Float.init), 1.0, "Float32 must decode 0x3F800000 LE to 1.0")

        // (d) Double 1.0 == 0x3FF0000000000000 little-endian.
        let doubleOne = DataInspectorReading(
            bytes: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F]),
            baseAddress: 0x1000,
            selectedAddress: 0x1000
        )
        XCTAssertEqual(doubleOne.double64.flatMap(Double.init), 1.0, "Double64 must decode 0x3FF0000000000000 LE to 1.0")

        // (e) Truncation: only two bytes available -> 32/64-bit and float/double rows are absent.
        let truncated = DataInspectorReading(
            bytes: Data([0x2A, 0x00]),
            baseAddress: 0x1000,
            selectedAddress: 0x1000
        )
        XCTAssertEqual(truncated.int16, "42")
        XCTAssertEqual(truncated.uint16, "42")
        XCTAssertEqual(truncated.int8, "42")
        XCTAssertNil(truncated.int32)
        XCTAssertNil(truncated.uint32)
        XCTAssertNil(truncated.int64)
        XCTAssertNil(truncated.uint64)
        XCTAssertNil(truncated.float32)
        XCTAssertNil(truncated.double64)
        let truncatedLabels = truncated.rows.map(\.label)
        XCTAssertFalse(truncatedLabels.contains("Int32"))
        XCTAssertFalse(truncatedLabels.contains("UInt32"))
        XCTAssertFalse(truncatedLabels.contains("Int64"))
        XCTAssertFalse(truncatedLabels.contains("UInt64"))
        XCTAssertFalse(truncatedLabels.contains("Float"))
        XCTAssertFalse(truncatedLabels.contains("Double"))
        XCTAssertTrue(truncatedLabels.contains("Int16"))

        // (f) Out-of-range selection -> not resolvable, no rows.
        let outOfRange = DataInspectorReading(
            bytes: Data(count: 8),
            baseAddress: 0x1000,
            selectedAddress: 0x2000
        )
        XCTAssertFalse(outOfRange.isResolvable)
        XCTAssertTrue(outOfRange.rows.isEmpty)
        XCTAssertEqual(outOfRange.availabilityNote, "Selection is outside the loaded bytes.")

        // (g) Printable run preview stops at the NUL terminator.
        let stringBytes = DataInspectorReading(
            bytes: Data([0x48, 0x69, 0x00]),
            baseAddress: 0x1000,
            selectedAddress: 0x1000
        )
        XCTAssertEqual(stringBytes.stringPreview, "Hi")
        XCTAssertEqual(stringBytes.character, "H")

        // (h) Nil selection and empty bytes are both unresolvable.
        let noSelection = DataInspectorReading(
            bytes: Data([0x2A]),
            baseAddress: 0x1000,
            selectedAddress: nil
        )
        XCTAssertFalse(noSelection.isResolvable)
        let empty = DataInspectorReading(
            bytes: Data(),
            baseAddress: 0x1000,
            selectedAddress: 0x1000
        )
        XCTAssertFalse(empty.isResolvable)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(empty.availabilityNote, "No bytes are loaded for the current target.")
    }

    func testGraphChromeAdaptsColumnCountsAndNodeSizing() {
        XCTAssertEqual(AppGraphChrome.visibleColumnCount(for: 640), 1)
        XCTAssertEqual(AppGraphChrome.visibleColumnCount(for: 900), 2)
        XCTAssertEqual(AppGraphChrome.visibleColumnCount(for: 1_200), 3)
        XCTAssertEqual(AppGraphChrome.laneWidth(for: 640), AppGraphChrome.laneMaxWidth)
        XCTAssertEqual(AppGraphChrome.laneWidth(for: 1_080), 312)
        XCTAssertEqual(
            AppGraphChrome.nodeSize(for: 312),
            CGSize(width: 312 - AppGraphChrome.nodeHorizontalInset, height: AppGraphChrome.nodeHeight)
        )
        XCTAssertGreaterThanOrEqual(AppGraphChrome.overviewMinHeight, 38)
        XCTAssertGreaterThanOrEqual(AppGraphChrome.minimumLaneHeight, 320)
    }

    func testSidebarChromeKeepsReadableTextColumnAtMinimumWidth() {
        XCTAssertEqual(AppSidebarChrome.listRowSpacing, 2)
        XCTAssertEqual(AppSidebarChrome.rowTitleLineLimit, 1)
        XCTAssertEqual(AppSidebarChrome.rowDetailLineLimit, 1)
        XCTAssertEqual(AppSidebarChrome.maximumDetailedRowTextLines, 2)
        XCTAssertEqual(AppSidebarChrome.rowTextVerticalSpacing, 2)
        XCTAssertEqual(AppSidebarChrome.sectionHeaderMinHeight, 20)
        XCTAssertLessThanOrEqual(AppSidebarChrome.rowContentSpacing, Lumen.Space.s4)
        XCTAssertLessThanOrEqual(AppSidebarChrome.rowIconWidth, 16)
        XCTAssertLessThanOrEqual(AppSidebarChrome.rowHorizontalPadding, Lumen.Space.s4)
        XCTAssertEqual(AppSidebarChrome.minimumReadableTextColumnWidth, 248)
        XCTAssertGreaterThanOrEqual(AppSidebarChrome.minimumAccessibilityLabelLength, 3)
        XCTAssertEqual(AppSidebarChrome.accessibilityHint(isSelected: true), "Selected navigator item")
        XCTAssertEqual(AppSidebarChrome.accessibilityHint(isSelected: false), "Selects this navigator item")
        XCTAssertGreaterThanOrEqual(
            AppSidebarChrome.readableTextColumnWidth(forSidebarWidth: AppLayout.sidebarMinWidth),
            AppSidebarChrome.minimumReadableTextColumnWidth,
            "The minimum sidebar must reserve enough text width to keep source-list labels readable."
        )
        XCTAssertTrue(
            AppSidebarChrome.reservesMinimumReadableTextColumn(forSidebarWidth: AppLayout.sidebarMinWidth),
            "The minimum sidebar width must preserve the design-system readable text-column floor."
        )

        let primaryNavigationTitles = WorkspaceTool.allCases.map(\.rawValue) + [
            "Breakpoints",
            "Instructions",
            "Plugin Automation"
        ]
        for title in primaryNavigationTitles {
            XCTAssertTrue(
                AppSidebarChrome.primaryNavigationTitleFits(title, forSidebarWidth: AppLayout.sidebarMinWidth),
                "Primary navigation title should not be clipped at the minimum sidebar width: \(title)"
            )
        }
    }

    @MainActor
    func testDefaultWorkspaceBootstrapStartsEmptyWithoutPreviewFixtureData() {
        let store = WorkspaceStore.bootstrap()

        XCTAssertEqual(store.workspaceName, "MacScope Workspace")
        XCTAssertTrue(store.snapshot.binaries.isEmpty)
        XCTAssertTrue(store.snapshot.functions.isEmpty)
        XCTAssertTrue(store.snapshot.symbols.isEmpty)
        XCTAssertTrue(store.snapshot.imports.isEmpty)
        XCTAssertTrue(store.snapshot.indirectSymbols.isEmpty)
        XCTAssertTrue(store.snapshot.exports.isEmpty)
        XCTAssertTrue(store.snapshot.stringLiterals.isEmpty)
        XCTAssertTrue(store.snapshot.basicBlocks.isEmpty)
        XCTAssertTrue(store.snapshot.instructions.isEmpty)
        XCTAssertTrue(store.snapshot.xrefs.isEmpty)
        XCTAssertTrue(store.snapshot.controlFlowEdges.isEmpty)
        XCTAssertTrue(store.snapshot.hexBytes.isEmpty)
        XCTAssertNil(store.selectedSidebarItemID)
        XCTAssertNil(store.selectedAddress)
        XCTAssertNil(store.selectedGraphElementID)
        XCTAssertFalse(store.isImporting)
        XCTAssertNil(store.lastIssue)
        XCTAssertEqual(store.sidebarItems.map(\.id), ["section:binaries", "section:functions"])
        XCTAssertTrue(store.selectableVisibleSidebarItems.isEmpty)
    }

    @MainActor
    func testExplicitPreviewFixtureBootstrapStillSeedsSampleAnalysis() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()

        XCTAssertEqual(store.workspaceName, "MacScope Workspace")
        XCTAssertEqual(store.snapshot.binaries.map(\.name), ["MacScope Sample Binary"])
        XCTAssertEqual(store.snapshot.functions.map(\.name), ["_main", "_analyze_macho", "_render_listing"])
        XCTAssertEqual(store.snapshot.instructions.count, 10)
        XCTAssertEqual(store.selectedAddress, 0x1000_00000)
        XCTAssertEqual(store.selectedGraphElementID, store.graphNodeSelectionTargets.first?.id)
        XCTAssertTrue(store.selectedSidebarItemID?.hasPrefix("binary:") == true)
    }

    @MainActor
    func testSidebarItemsReflectEachToolMode() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let snapshot = store.snapshot

        store.selectedTool = .project
        XCTAssertEqual(store.sidebarItems.count, snapshot.binaries.count + snapshot.functions.count + 2)
        XCTAssertEqual(store.sidebarItems.first?.id, "section:binaries")
        XCTAssertTrue(store.sidebarItems.contains { $0.id == "section:functions" })
        XCTAssertTrue(store.sidebarItems.contains { $0.id.hasPrefix("binary:") && $0.title == "MacScope Sample Binary" })
        XCTAssertTrue(store.sidebarItems.contains { $0.id.hasPrefix("function:") && $0.title == "_main" })

        store.selectedTool = .symbols
        XCTAssertEqual(store.sidebarItems.map(\.title), snapshot.functions.map(\.name))
        XCTAssertTrue(store.sidebarItems.allSatisfy { $0.id.hasPrefix("symbol:") })
        XCTAssertTrue(store.sidebarItems.allSatisfy { $0.systemImage == "curlybraces" })

        store.selectedTool = .xrefs
        XCTAssertEqual(store.sidebarItems.count, snapshot.xrefs.count)
        XCTAssertTrue(store.sidebarItems.allSatisfy { $0.id.hasPrefix("xref:") })
        XCTAssertTrue(store.sidebarItems.allSatisfy { $0.detail?.contains(" -> ") == true })
        XCTAssertTrue(store.sidebarItems.contains { $0.detail == "0x0000000100000014 -> 0x0000000100001000" })

        store.selectedTool = .debug
        XCTAssertEqual(store.sidebarItems.map(\.id), ["debug:session", "debug:breakpoints", "debug:console"])
        XCTAssertEqual(store.sidebarItems.map(\.title), ["Session", "Breakpoints", "Console"])
        XCTAssertEqual(
            store.sidebarItems.first { $0.id == "debug:breakpoints" }?.detail,
            "1 saved · 1 enabled"
        )

        store.selectedTool = .strings
        XCTAssertTrue(store.sidebarItems.allSatisfy { $0.id.hasPrefix("string:") })

        store.selectedTool = .extensions
        XCTAssertEqual(store.sidebarItems.map(\.id), ["extensions:none"])
        XCTAssertEqual(store.sidebarItems.map(\.systemImage), ["puzzlepiece.extension"])

        store.selectedTool = .reconstruction
        XCTAssertEqual(store.sidebarItems.map(\.id), ["section:reconstruction-jobs"])
    }

    @MainActor
    private func stringsFixtureStore() -> (store: WorkspaceStore, firstID: UUID, secondID: UUID) {
        let firstID = UUID()
        let secondID = UUID()
        let cstringBytes = Data(repeating: 0, count: 0x22)
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            symbols: [],
            imports: [],
            indirectSymbols: [],
            exports: [],
            stringLiterals: [
                StringLiteralSummary(
                    id: firstID,
                    value: "%s: %d",
                    address: 0x1000_03F00,
                    sourceSection: "__cstring",
                    byteLength: 7
                ),
                StringLiteralSummary(
                    id: secondID,
                    value: "line one\nline two",
                    address: 0x1000_03F10,
                    sourceSection: "__cstring",
                    byteLength: 18
                )
            ],
            basicBlocks: [],
            instructions: [],
            xrefs: [],
            controlFlowEdges: [],
            hexBytes: cstringBytes,
            sections: [
                SectionSummary(
                    id: UUID(),
                    name: "__TEXT,__cstring",
                    address: 0x1000_03F00,
                    size: UInt64(cstringBytes.count),
                    fileOffset: 0,
                    isExecutable: false
                )
            ],
            imageBytes: cstringBytes
        )

        let store = WorkspaceStore(
            workspaceName: "Strings Fixture",
            snapshot: snapshot,
            engine: AnalysisEngine()
        )
        return (store, firstID, secondID)
    }

    @MainActor
    func testStringsToolSurfacesStringLiterals() throws {
        let fixture = stringsFixtureStore()
        let store = fixture.store
        store.selectedTool = .strings

        let items = store.sidebarItems
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.id.hasPrefix("string:") })
        XCTAssertTrue(items.allSatisfy { $0.systemImage == "text.quote" })

        let first = try XCTUnwrap(items.first)
        let firstDetail = try XCTUnwrap(first.detail)
        XCTAssertEqual(firstDetail, "0x0000000100003f00 - __cstring")
        XCTAssertTrue(firstDetail.contains("0x0000000100003f00"))
        XCTAssertTrue(firstDetail.contains("__cstring"))

        let normalizedTitle = items[1].title
        XCTAssertFalse(normalizedTitle.contains("\n"))
        XCTAssertEqual(normalizedTitle, "line one line two")
    }

    @MainActor
    func testActivatingStringNavigatesHexEditor() {
        let fixture = stringsFixtureStore()
        let store = fixture.store
        store.selectedTool = .strings

        let itemID = "string:\(fixture.firstID.uuidString)"
        store.activateSidebarItem(itemID)

        XCTAssertEqual(store.selectedAddress, 0x1000_03F00)
        XCTAssertEqual(store.editorMode, .hex)
        XCTAssertEqual(store.selectedSidebarItemID, itemID)
    }

    @MainActor
    func testEmptyStringLiteralsShowsNoStringRows() {
        let store = WorkspaceStore(
            workspaceName: "Empty Strings Fixture",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine()
        )
        store.selectedTool = .strings

        XCTAssertTrue(store.snapshot.stringLiterals.isEmpty)
        XCTAssertTrue(store.sidebarItems.isEmpty)
    }

    @MainActor
    func testSelectedStringLiteralSurfacesInspectorDetails() throws {
        let fixture = stringsFixtureStore()
        let store = fixture.store
        store.selectedTool = .strings
        store.activateSidebarItem("string:\(fixture.firstID.uuidString)")

        let literal = try XCTUnwrap(store.selectedStringLiteral)
        XCTAssertEqual(literal.value, "%s: %d")
        XCTAssertEqual(literal.sourceSection, "__cstring")
        XCTAssertEqual(literal.byteLength, 7)

        store.selectedTool = .symbols
        XCTAssertNil(store.selectedStringLiteral)
    }

    @MainActor
    private func symbolTableFixtureStore(
        instructions: [InstructionRow] = []
    ) -> (store: WorkspaceStore, importID: UUID, exportID: UUID, symbolID: UUID) {
        let importID = UUID()
        let exportID = UUID()
        let symbolID = UUID()
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [],
            symbols: [
                SymbolSummary(id: symbolID, name: "_g_table", address: 0x1000_04000, kind: "data", libraryName: nil)
            ],
            imports: [
                ImportSummary(id: importID, name: "_printf", libraryName: "libSystem.B.dylib", libraryOrdinal: 1)
            ],
            indirectSymbols: [],
            exports: [
                ExportSummary(id: exportID, name: "_macscope_entry", address: 0x1000_00000, source: "trie")
            ],
            stringLiterals: [],
            basicBlocks: [],
            instructions: instructions,
            xrefs: [],
            controlFlowEdges: [],
            hexBytes: Data()
        )

        let store = WorkspaceStore(
            workspaceName: "Symbol Table Fixture",
            snapshot: snapshot,
            engine: AnalysisEngine()
        )
        return (store, importID, exportID, symbolID)
    }

    @MainActor
    func testSymbolsToolSurfacesImportsExportsAndSymbols() throws {
        let fixture = symbolTableFixtureStore()
        let store = fixture.store
        store.selectedTool = .symbols

        let items = store.sidebarItems

        let importsHeaderIndex = try XCTUnwrap(items.firstIndex { $0.id == "section:imports" })
        XCTAssertTrue(items[importsHeaderIndex].isSectionHeader)

        let importRow = try XCTUnwrap(items.first { $0.id == "import:\(fixture.importID.uuidString)" })
        XCTAssertEqual(importRow.title, "_printf")
        XCTAssertEqual(importRow.detail, "libSystem.B.dylib")
        XCTAssertEqual(importRow.systemImage, "arrow.down.circle")
        XCTAssertGreaterThan(try XCTUnwrap(items.firstIndex { $0.id == importRow.id }), importsHeaderIndex)

        XCTAssertTrue(items.contains { $0.id == "section:exports" && $0.isSectionHeader })
        let exportRow = try XCTUnwrap(items.first { $0.id == "export:\(fixture.exportID.uuidString)" })
        XCTAssertEqual(exportRow.title, "_macscope_entry")
        XCTAssertEqual(exportRow.detail, "0x0000000100000000")
        XCTAssertEqual(exportRow.systemImage, "arrow.up.circle")

        XCTAssertTrue(items.contains { $0.id == "section:symbols" && $0.isSectionHeader })
        let symbolRow = try XCTUnwrap(items.first { $0.id == "symbol:\(fixture.symbolID.uuidString)" })
        XCTAssertEqual(symbolRow.title, "_g_table")
        XCTAssertEqual(symbolRow.detail, "0x0000000100004000")
        XCTAssertEqual(symbolRow.systemImage, "curlybraces")
    }

    @MainActor
    func testSymbolsToolFallsBackToFunctionsWhenNoSymbolTable() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let snapshot = store.snapshot

        XCTAssertTrue(snapshot.imports.isEmpty)
        XCTAssertTrue(snapshot.exports.isEmpty)
        XCTAssertTrue(snapshot.symbols.isEmpty)

        store.selectedTool = .symbols
        XCTAssertEqual(store.sidebarItems.map(\.title), snapshot.functions.map(\.name))
        XCTAssertTrue(store.sidebarItems.allSatisfy { $0.id.hasPrefix("symbol:") })
        XCTAssertTrue(store.sidebarItems.allSatisfy { $0.systemImage == "curlybraces" })
    }

    @MainActor
    func testActivatingExportWithAddressNavigatesDisassembly() throws {
        let fixture = symbolTableFixtureStore(
            instructions: [
                InstructionRow(address: 0x1000_00000, bytes: "00 00 80 52", mnemonic: "mov", operands: "w0, #0", hasBreakpoint: false, comment: nil)
            ]
        )
        let store = fixture.store
        store.selectedTool = .symbols

        let itemID = "export:\(fixture.exportID.uuidString)"
        store.activateSidebarItem(itemID)

        XCTAssertEqual(store.selectedAddress, 0x1000_00000)
        XCTAssertEqual(store.editorMode, .disassembly)
        XCTAssertEqual(store.selectedSidebarItemID, itemID)
    }

    @MainActor
    func testActivatingImportWithoutInstructionDoesNotMoveEditor() {
        let fixture = symbolTableFixtureStore()
        let store = fixture.store
        store.selectedTool = .symbols
        let initialAddress = store.selectedAddress

        let itemID = "import:\(fixture.importID.uuidString)"
        store.activateSidebarItem(itemID)

        XCTAssertEqual(store.selectedSidebarItemID, itemID)
        XCTAssertEqual(store.selectedAddress, initialAddress)
    }

    func testWorkspaceSchemaVersionAndTableCoverage() {
        XCTAssertEqual(WorkspaceDatabase.schemaVersion, 44)

        // The fresh-install schema hardcodes `PRAGMA user_version = N` (the
        // migration paths interpolate schemaVersion). Guard the literal against
        // drift so a fresh install can't report a different version than a migration.
        let pragmaLiteral = WorkspaceDatabase.schemaSQL
            .components(separatedBy: "PRAGMA user_version = ").last?
            .prefix { $0.isNumber }
        XCTAssertEqual(pragmaLiteral.flatMap { Int($0) }, WorkspaceDatabase.schemaVersion)

        let schema = WorkspaceDatabase.schemaSQL
        XCTAssertEqual(schemaTableNames(in: schema), [
            "workspaces",
            "binaries",
            "functions",
            "symbols",
            "imports",
            "indirect_symbols",
            "exports",
            "string_literals",
            "constant_cfstrings",
            "instructions",
            "basic_blocks",
            "xrefs",
            "control_flow_edges",
            "workspace_sessions",
            "workspace_documents",
            "workspace_document_autosave_decisions",
            "plugin_trust_decisions",
            "plugin_external_runs",
            "address_overrides",
            "type_definitions",
            "manual_xrefs",
            "bookmarks",
            "segment_overrides",
            "source_lines",
            "logical_breakpoint_catalogs",
            "logical_breakpoints",
            "launch_profile_catalogs",
            "phase2_assistant_session_records",
            "phase2_runtime_authority_records",
            "phase2_shell_sessions",
            "reconstruction_projects",
            "reconstruction_artifact_contents",
            "reconstruction_artifact_occurrences",
            "reconstruction_artifact_roles",
            "reconstruction_artifact_relations",
            "reconstruction_evidence",
            "reconstruction_evidence_citations",
            "reconstruction_evidence_relations",
            "reconstruction_final_results",
            "reconstruction_tool_receipts",
            "reconstruction_model_receipts",
            "reconstruction_jobs",
            "reconstruction_tasks",
            "reconstruction_checkpoints",
            "reconstruction_checkpoint_tasks",
            "saved_watch_catalogs",
        ])

        assertTable("workspaces", in: schema, contains: [
            "uuid TEXT NOT NULL UNIQUE",
            "name TEXT NOT NULL",
            "created_at TEXT NOT NULL",
            "modified_at TEXT NOT NULL"
        ])
        assertTable("binaries", in: schema, contains: [
            "workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE",
            "path TEXT NOT NULL",
            "original_path_bookmark BLOB",
            "file_hash TEXT NOT NULL",
            "file_size INTEGER NOT NULL",
            "is_bundle INTEGER NOT NULL DEFAULT 0",
            "image_slot INTEGER NOT NULL DEFAULT 0"
        ])
        assertTable("functions", in: schema, contains: [
            "binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE",
            "start_address INTEGER NOT NULL",
            "end_address INTEGER",
            "confidence REAL NOT NULL DEFAULT 0.0"
        ])
        assertTable("symbols", in: schema, contains: [
            "binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE",
            "name TEXT NOT NULL",
            "address INTEGER",
            "kind TEXT NOT NULL",
            "library_name TEXT"
        ])
        assertTable("imports", in: schema, contains: [
            "binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE",
            "name TEXT NOT NULL",
            "library_name TEXT",
            "library_ordinal INTEGER"
        ])
        assertTable("indirect_symbols", in: schema, contains: [
            "binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE",
            "source_section TEXT NOT NULL",
            "address INTEGER NOT NULL",
            "entry_size INTEGER NOT NULL",
            "table_index INTEGER NOT NULL",
            "raw_symbol_index INTEGER NOT NULL",
            "symbol_index INTEGER",
            "symbol_name TEXT",
            "library_name TEXT"
        ])
        assertTable("exports", in: schema, contains: [
            "binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE",
            "name TEXT NOT NULL",
            "address INTEGER",
            "source TEXT NOT NULL"
        ])
        assertTable("string_literals", in: schema, contains: [
            "binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE",
            "value TEXT NOT NULL",
            "address INTEGER NOT NULL",
            "source_section TEXT NOT NULL",
            "byte_length INTEGER NOT NULL"
        ])
        assertTable("instructions", in: schema, contains: [
            "function_id INTEGER NOT NULL REFERENCES functions(id) ON DELETE CASCADE",
            "address INTEGER NOT NULL",
            "bytes BLOB NOT NULL",
            "mnemonic TEXT NOT NULL",
            "operands TEXT NOT NULL",
            "ir_json BLOB"
        ])
        assertTable("basic_blocks", in: schema, contains: [
            "function_id INTEGER NOT NULL REFERENCES functions(id) ON DELETE CASCADE",
            "start_address INTEGER NOT NULL",
            "end_address INTEGER NOT NULL",
            "instruction_count INTEGER NOT NULL DEFAULT 0"
        ])
        assertTable("xrefs", in: schema, contains: [
            "binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE",
            "from_address INTEGER NOT NULL",
            "to_address INTEGER NOT NULL",
            "kind TEXT NOT NULL"
        ])
        assertTable("control_flow_edges", in: schema, contains: [
            "binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE",
            "from_address INTEGER NOT NULL",
            "to_address INTEGER NOT NULL",
            "kind TEXT NOT NULL"
        ])
        assertTable("workspace_sessions", in: schema, contains: [
            "workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE",
            "selected_sidebar_item_id TEXT",
            "selected_address INTEGER",
            "selected_tool TEXT NOT NULL",
            "editor_mode TEXT NOT NULL",
            "is_inspector_presented INTEGER NOT NULL DEFAULT 1",
            "sidebar_search_text TEXT NOT NULL DEFAULT ''",
            "updated_at TEXT NOT NULL"
        ])
        assertTable("workspace_documents", in: schema, contains: [
            "workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE",
            "document_id TEXT NOT NULL",
            "package_path TEXT NOT NULL",
            "last_opened_at TEXT NOT NULL",
            "last_saved_at TEXT",
            "is_dirty INTEGER NOT NULL DEFAULT 0",
            "file_version_identifier TEXT",
            "conflict_detected_at TEXT",
            "conflict_reason TEXT",
            "input_copying_decision TEXT NOT NULL DEFAULT 'copy_inputs_into_package'",
            "bookmark_resolution_decision TEXT NOT NULL DEFAULT 'resolve_stored_bookmarks'",
            "bookmark_resolution_error TEXT",
            "recent_document_state TEXT NOT NULL DEFAULT 'available'",
            "recent_document_state_updated_at TEXT"
        ])
        assertTable("workspace_document_autosave_decisions", in: schema, contains: [
            "uuid TEXT NOT NULL UNIQUE",
            "workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE",
            "document_id TEXT NOT NULL",
            "package_path TEXT NOT NULL",
            "decision TEXT NOT NULL",
            "reason TEXT",
            "file_version_identifier TEXT",
            "decided_at TEXT NOT NULL",
            "completed_at TEXT",
            "error_message TEXT"
        ])
        assertTable("plugin_trust_decisions", in: schema, contains: [
            "plugin_identifier TEXT PRIMARY KEY",
            "decision TEXT NOT NULL",
            "manifest_hash TEXT",
            "updated_at TEXT NOT NULL"
        ])
        assertTable("plugin_external_runs", in: schema, contains: [
            "request_id TEXT NOT NULL UNIQUE",
            "plugin_identifier TEXT NOT NULL",
            "display_name TEXT NOT NULL",
            "executable_path TEXT NOT NULL",
            "status TEXT NOT NULL",
            "started_at TEXT NOT NULL",
            "stdout TEXT NOT NULL DEFAULT ''",
            "stderr TEXT NOT NULL DEFAULT ''",
            "log TEXT NOT NULL DEFAULT ''",
            "error_message TEXT"
        ])
    }

    func testInfoPlistRegistersMacScopeWorkspacePackages() throws {
        let info = try macScopeInfoDictionary()

        XCTAssertEqual(info["LSSupportsOpeningDocumentsInPlace"] as? Bool, true)

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let documentType = try XCTUnwrap(
            documentTypes.first { item in
                (item["LSItemContentTypes"] as? [String])?.contains(MacScopeDocumentPackage.formatIdentifier) == true
            }
        )
        XCTAssertEqual(documentType["CFBundleTypeName"] as? String, "MacScope Workspace")
        XCTAssertEqual(documentType["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(documentType["LSHandlerRank"] as? String, "Owner")
        XCTAssertEqual(documentType["LSTypeIsPackage"] as? Bool, true)

        let exportedTypes = try XCTUnwrap(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let workspaceType = try XCTUnwrap(
            exportedTypes.first { item in
                item["UTTypeIdentifier"] as? String == MacScopeDocumentPackage.formatIdentifier
            }
        )
        XCTAssertEqual(workspaceType["UTTypeDescription"] as? String, "MacScope Workspace Package")
        XCTAssertEqual(workspaceType["UTTypeConformsTo"] as? [String], ["com.apple.package"])

        let tags = try XCTUnwrap(workspaceType["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], [MacScopeDocumentPackage.fileExtension])
        XCTAssertEqual(tags["public.mime-type"] as? String, "application/x-macscope-workspace")
    }

    func testSettingsPluginPolicyUsesStablePreferenceKeysAndDefaults() {
        XCTAssertEqual(
            PluginRuntimePolicy.StorageKey.allowDevelopmentPlugins,
            "allowDevelopmentPlugins"
        )
        XCTAssertEqual(
            PluginRuntimePolicy.StorageKey.requireSignedPlugins,
            "requireSignedPlugins"
        )
        XCTAssertEqual(
            PluginRuntimePolicy.StorageKey.allowNetworkAccess,
            "allowPluginNetworkAccess"
        )
        XCTAssertEqual(
            PluginRuntimePolicy.StorageKey.allowProcessSpawn,
            "allowPluginProcessSpawn"
        )
        XCTAssertEqual(
            PluginRuntimePolicy.settingsDefault,
            PluginRuntimePolicy(
                allowDevelopmentPlugins: false,
                requireSignedPlugins: true,
                allowNetworkAccess: false,
                allowProcessSpawn: false
            )
        )
        XCTAssertEqual(
            PluginProvenancePolicy.settingsDefault,
            PluginProvenancePolicy(
                allowBundledUnsigned: true,
                allowDevelopmentUnsigned: false,
                requireSignedThirdParty: true
            )
        )
    }

    func testPreviewSnapshotHasConsistentScaffoldData() {
        let snapshot = AnalysisEngine.previewSnapshot()

        XCTAssertEqual(snapshot.binaries.map(\.name), ["MacScope Sample Binary"])
        XCTAssertEqual(snapshot.binaries.first?.kind, "synthetic arm64 fixture")
        XCTAssertEqual(snapshot.binaries.first?.architecture, "arm64")

        XCTAssertEqual(snapshot.functions.map(\.name), ["_main", "_analyze_macho", "_render_listing"])
        XCTAssertEqual(snapshot.functions.map(\.startAddress), [0x1000_00000, 0x1000_01000, 0x1000_02000])
        XCTAssertEqual(snapshot.basicBlocks.count, 3)
        XCTAssertEqual(snapshot.basicBlocks.map(\.startAddress), [0x1000_00000, 0x1000_01000, 0x1000_02000])
        // Control-flow edges start at saved instructions (HS-1); the 0x1000_02020 reference is an xref only.
        XCTAssertEqual(snapshot.controlFlowEdges.map(\.kind), ["call"])
        XCTAssertTrue(Set(snapshot.instructions.map(\.address)).isSuperset(of: snapshot.controlFlowEdges.map(\.from)))

        XCTAssertEqual(snapshot.instructions.count, 10)
        XCTAssertEqual(snapshot.instructions.first?.address, 0x1000_00000)
        XCTAssertEqual(snapshot.instructions.last?.address, 0x1000_00024)
        XCTAssertEqual(snapshot.instructions.map(\.address), stride(from: 0x1000_00000, through: 0x1000_00024, by: 4).map(UInt64.init))
        XCTAssertEqual(Set(snapshot.instructions.map(\.id)).count, snapshot.instructions.count)
        XCTAssertEqual(snapshot.instructions.first?.comment, "Stack frame")
        XCTAssertEqual(snapshot.instructions.filter(\.hasBreakpoint).map(\.address), [0x1000_00004])

        XCTAssertEqual(snapshot.xrefs.count, 2)
        XCTAssertTrue(snapshot.xrefs.contains { $0.kind == "call" && $0.from == 0x1000_00014 && $0.to == 0x1000_01000 })
        XCTAssertEqual(snapshot.hexBytes.count, snapshot.instructions.count * 4)
    }

    private func procedureReading(
        in snapshot: WorkspaceSnapshot,
        selectedAddress: UInt64?
    ) -> ProcedureInspectorReading {
        let callEdges =
            snapshot.controlFlowEdges.map { (from: $0.from, to: $0.to, kind: $0.kind) }
            + snapshot.xrefs.map { (from: $0.from, to: $0.to, kind: $0.kind) }
        return ProcedureInspectorReading(
            functions: snapshot.functions,
            basicBlocks: snapshot.basicBlocks,
            callEdges: callEdges,
            instructions: snapshot.instructions,
            selectedAddress: selectedAddress
        )
    }

    func testProcedureReadingResolvesEnclosingFunctionForInteriorAddress() {
        let snapshot = AnalysisEngine.previewSnapshot()
        let reading = procedureReading(in: snapshot, selectedAddress: 0x1000_00014)

        XCTAssertTrue(reading.isResolved)
        XCTAssertEqual(reading.function?.name, "_main")
        XCTAssertEqual(reading.entryText, UInt64(0x1000_00000).hexAddress)
        XCTAssertEqual(reading.endText, UInt64(0x1000_00028).hexAddress)
        XCTAssertEqual(reading.blockCount, 1)
        XCTAssertEqual(reading.instructionCount, 10)
        XCTAssertEqual(reading.confidenceText, "92%")
    }

    func testProcedureReadingAppliesNameOverrideToNameRow() {
        let snapshot = AnalysisEngine.previewSnapshot()
        let mainFunction = snapshot.functions.first { $0.name == "_main" }!
        let reading = ProcedureInspectorReading(
            functions: snapshot.functions,
            basicBlocks: snapshot.basicBlocks,
            callEdges: [],
            instructions: snapshot.instructions,
            selectedAddress: 0x1000_00014,
            addressOverrides: [mainFunction.startAddress: AddressOverride(customName: "decodeFrame")]
        )

        // The parsed identity is unchanged; only the displayed Name blends.
        XCTAssertEqual(reading.function?.name, "_main")
        XCTAssertEqual(reading.nameText, "decodeFrame")
        XCTAssertEqual(reading.rows.first { $0.label == "Name" }?.value, "decodeFrame")
    }

    @MainActor
    func testFunctionNameOverridesMapsRenamedFunctionsOnly() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        XCTAssertTrue(store.snapshot.functionNameOverrides().isEmpty)

        let analyze = store.snapshot.functions.first { $0.name == "_analyze_macho" }!
        store.setCustomName(analyze.startAddress, name: "decodeMachO")

        // Only the renamed function appears, keyed by its parsed name.
        XCTAssertEqual(store.snapshot.functionNameOverrides(), ["_analyze_macho": "decodeMachO"])
    }

    func testFunctionNameOverridesDropsAmbiguousDuplicateParsedNames() {
        var snapshot = AnalysisEngine.previewSnapshot()
        let mainFunction = snapshot.functions.first { $0.name == "_main" }!

        // A second, distinct function that happens to share the parsed name "_main".
        snapshot.functions.append(
            FunctionSummary(id: UUID(), name: "_main", startAddress: 0x9000_0000, endAddress: 0x9000_0010, confidence: 1)
        )
        // Rename only the original _main.
        snapshot.addressOverrides[.primary(mainFunction.startAddress)] = AddressOverride(customName: "decodeFrame")

        // "_main" is now ambiguous (two functions own it) so the rename is dropped:
        // without the address we can't attribute a call target to a single callee.
        XCTAssertNil(snapshot.functionNameOverrides()["_main"])
        XCTAssertTrue(snapshot.functionNameOverrides().isEmpty)
    }

    func testPseudocodeTargetResolvesEnclosingFunctionAndFiltersInstructions() {
        let alpha = FunctionSummary(id: UUID(), name: "alpha", startAddress: 0x1000, endAddress: 0x1008, confidence: 1)
        let beta = FunctionSummary(id: UUID(), name: "beta", startAddress: 0x2000, endAddress: 0x2008, confidence: 1)
        func row(_ address: UInt64, _ mnemonic: String) -> InstructionRow {
            InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: "", hasBreakpoint: false, comment: nil)
        }
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [alpha, beta],
            instructions: [row(0x1000, "nop"), row(0x1004, "ret"), row(0x2000, "mov"), row(0x2004, "ret")],
            xrefs: [],
            hexBytes: Data()
        )

        // A selection inside beta resolves beta and only beta's instructions.
        let inBeta = snapshot.pseudocodeTarget(selectedAddress: 0x2004)
        XCTAssertEqual(inBeta?.function.name, "beta")
        XCTAssertEqual(inBeta?.instructions.map(\.address), [0x2000, 0x2004])

        // A selection inside alpha resolves alpha and only alpha's instructions.
        let inAlpha = snapshot.pseudocodeTarget(selectedAddress: 0x1000)
        XCTAssertEqual(inAlpha?.function.name, "alpha")
        XCTAssertEqual(inAlpha?.instructions.map(\.address), [0x1000, 0x1004])

        // No selection falls back to the first function; no functions -> nil.
        XCTAssertEqual(snapshot.pseudocodeTarget(selectedAddress: nil)?.function.name, "alpha")
        let empty = WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data())
        XCTAssertNil(empty.pseudocodeTarget(selectedAddress: 0x1000))
    }

    func testProcedureReadingCountsCalleesAndCallers() {
        let snapshot = AnalysisEngine.previewSnapshot()

        // The lone call edge 0x100000014 -> 0x100001000 originates inside _main,
        // so _main has one callee and no callers. Deduping over (from, to) keeps
        // the duplicated controlFlowEdge + xref from inflating the count to two.
        let mainReading = procedureReading(in: snapshot, selectedAddress: 0x1000_00014)
        XCTAssertEqual(mainReading.calleeCount, 1)
        XCTAssertEqual(mainReading.callerCount, 0)

        // _analyze_macho is the call target, so it has one caller and no callees.
        let analyzeReading = procedureReading(in: snapshot, selectedAddress: 0x1000_01000)
        XCTAssertEqual(analyzeReading.function?.name, "_analyze_macho")
        XCTAssertEqual(analyzeReading.callerCount, 1)
        XCTAssertEqual(analyzeReading.calleeCount, 0)
    }

    func testProcedureReadingExposesStableRowOrder() {
        let snapshot = AnalysisEngine.previewSnapshot()
        let reading = procedureReading(in: snapshot, selectedAddress: 0x1000_00014)

        XCTAssertEqual(
            reading.rows.map(\.label),
            ["Name", "Entry", "End", "Instructions", "Confidence", "Callees"]
        )
    }

    func testProcedureReadingUnresolvedForAddressOutsideAnyFunction() {
        let snapshot = AnalysisEngine.previewSnapshot()

        let outside = procedureReading(in: snapshot, selectedAddress: 0x2000_00000)
        XCTAssertFalse(outside.isResolved)
        XCTAssertNil(outside.function)
        XCTAssertTrue(outside.rows.isEmpty)
        XCTAssertFalse(outside.availabilityNote.isEmpty)

        let noSelection = procedureReading(in: snapshot, selectedAddress: nil)
        XCTAssertFalse(noSelection.isResolved)
        XCTAssertTrue(noSelection.rows.isEmpty)
    }

    func testProcedureReadingOmitsZeroConfidence() {
        let zeroConfidence = FunctionSummary(
            id: UUID(),
            name: "_stub",
            startAddress: 0x3000_00000,
            endAddress: 0x3000_00040,
            confidence: 0
        )
        let reading = ProcedureInspectorReading(
            functions: [zeroConfidence],
            basicBlocks: [],
            callEdges: [],
            instructions: [],
            selectedAddress: 0x3000_00010
        )

        XCTAssertTrue(reading.isResolved)
        XCTAssertNil(reading.confidenceText)
        XCTAssertFalse(reading.rows.map(\.label).contains("Confidence"))
    }

    @MainActor
    func testProcessLaunchConfigurationCanSelectScreenshotEditorMode() {
        let parsedFromArguments = WorkspaceLaunchConfiguration.parse(
            arguments: [
                "/Applications/MacScope.app/Contents/MacOS/MacScope",
                "--macscope-screenshot-mode",
                "graph",
                "--macscope-window-frame",
                "-1920,48,1440,840"
            ],
            environment: [:]
        )
        XCTAssertEqual(parsedFromArguments.editorMode, .graph)
        XCTAssertTrue(parsedFromArguments.loadsPreviewFixture)
        XCTAssertEqual(
            parsedFromArguments.windowFrame,
            WorkspaceLaunchWindowFrame(x: -1920, y: 48, width: 1440, height: 840)
        )

        let parsedFromEnvironment = WorkspaceLaunchConfiguration.parse(
            arguments: [],
            environment: [
                "MACSCOPE_SCREENSHOT_EDITOR_MODE": "HEX",
                "MACSCOPE_WINDOW_FRAME": "0,60,1280,780"
            ]
        )
        XCTAssertEqual(parsedFromEnvironment.editorMode, .hex)
        XCTAssertTrue(parsedFromEnvironment.loadsPreviewFixture)
        XCTAssertEqual(
            parsedFromEnvironment.windowFrame,
            WorkspaceLaunchWindowFrame(x: 0, y: 60, width: 1280, height: 780)
        )

        let parsedFromExplicitFixtureFlag = WorkspaceLaunchConfiguration.parse(
            arguments: ["MacScope", "--macscope-preview-fixture"],
            environment: [:]
        )
        XCTAssertNil(parsedFromExplicitFixtureFlag.editorMode)
        XCTAssertTrue(parsedFromExplicitFixtureFlag.loadsPreviewFixture)

        let invalid = WorkspaceLaunchConfiguration.parse(
            arguments: ["MacScope", "--macscope-screenshot-mode", "not-a-mode", "--macscope-window-frame", "0,0,200,200"],
            environment: ["MACSCOPE_SCREENSHOT_EDITOR_MODE": "also-not-a-mode"]
        )
        XCTAssertNil(invalid.editorMode)
        XCTAssertNil(invalid.windowFrame)
        XCTAssertFalse(invalid.loadsPreviewFixture)

        let store = WorkspaceStore.bootstrap(launchConfiguration: parsedFromArguments)
        XCTAssertEqual(store.editorMode, .graph)
        XCTAssertEqual(store.snapshot.binaries.map(\.name), ["MacScope Sample Binary"])
    }

    @MainActor
    func testInstalledNativeQualificationLaunchRequiresExplicitOptInAndCarriesExactAuthority() throws {
        let incomplete = WorkspaceLaunchConfiguration.parse(
            arguments: ["MacScope", "--macscope-screenshot-mode", "pseudocode"],
            environment: ["MACSCOPE_F1A_INSTALLED_SCENARIO_ID": "INS-PAIRWISE-048"]
        )
        XCTAssertFalse(incomplete.usesNativeDecompilerQualificationFixture)

        let configuration = WorkspaceLaunchConfiguration.parse(
            arguments: ["MacScope", "--macscope-screenshot-mode", "pseudocode"],
            environment: [
                "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST": "1",
                "MACSCOPE_F1A_INSTALLED_SCENARIO_ID": "INS-PAIRWISE-048",
            ]
        )
        XCTAssertTrue(configuration.loadsPreviewFixture)
        XCTAssertTrue(configuration.usesNativeDecompilerQualificationFixture)

        let store = WorkspaceStore.bootstrap(launchConfiguration: configuration)
        let binary = try XCTUnwrap(store.snapshot.binaries.first)
        let analysis = try XCTUnwrap(store.snapshot.analysis(in: binary.slot))
        XCTAssertEqual(binary.artifactIntegrityState, .verified)
        XCTAssertNotNil(binary.artifactIdentity?.uuid)
        XCTAssertNotNil(binary.preferredSegmentLayout)
        XCTAssertNotNil(analysis.analysisInputFingerprint)
        XCTAssertFalse(analysis.identityEffectiveByteRanges.isEmpty)

        let function = try XCTUnwrap(analysis.functions.first)
        let projection = try NativeDecompilerSnapshotBuilder.build(
            from: store.snapshot,
            imageSlot: binary.slot,
            functionID: function.id,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue
        )
        XCTAssertEqual(projection.coordinate.ownerBinaryID, binary.id)
        XCTAssertEqual(
            projection.coordinate.analysisInputFingerprintSHA256,
            analysis.analysisInputFingerprint?.overallSHA256
        )
    }

    @MainActor
    func testBreakpointTogglingUpdatesSelectionAndDebugSidebarCount() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectedTool = .debug

        XCTAssertEqual(activeBreakpointCount(in: store), 1)
        XCTAssertEqual(debugBreakpointItem(in: store)?.detail, "1 saved · 1 enabled")

        let targetAddress = 0x1000_00000 as UInt64
        store.selectInstruction(targetAddress)
        XCTAssertEqual(store.selectedInstruction?.address, targetAddress)
        XCTAssertEqual(store.selectedInstruction?.hasBreakpoint, false)

        store.toggleBreakpointAtSelection()
        XCTAssertEqual(store.selectedInstruction?.hasBreakpoint, true)
        XCTAssertEqual(activeBreakpointCount(in: store), 2)
        XCTAssertEqual(debugBreakpointItem(in: store)?.detail, "2 saved · 2 enabled")

        store.toggleBreakpoint(targetAddress)
        XCTAssertEqual(store.selectedInstruction?.hasBreakpoint, false)
        XCTAssertEqual(activeBreakpointCount(in: store), 1)
        XCTAssertEqual(debugBreakpointItem(in: store)?.detail, "1 saved · 1 enabled")

        let unchangedInstructions = store.snapshot.instructions
        store.toggleBreakpoint(0xdead_beef)
        XCTAssertEqual(store.snapshot.instructions, unchangedInstructions)
    }

    @MainActor
    func testCustomNameAndCommentOverridesAreUndoableAndRedoable() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64

        store.setCustomName(address, name: "decodeHeader")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customName, "decodeHeader")

        store.setCustomComment(address, comment: "  entry point  ")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customComment, "entry point")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customName, "decodeHeader")

        XCTAssertTrue(store.undoManager.canUndo)
        store.undoManager.undo() // reverse the comment edit only
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)]?.customComment)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customName, "decodeHeader")

        store.undoManager.undo() // reverse the rename -> entry removed
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        XCTAssertTrue(store.undoManager.canRedo)
        store.undoManager.redo() // re-apply the rename
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customName, "decodeHeader")
    }

    @MainActor
    func testInjectedHostUndoManagerDrivesModelUndoWithMenuTitles() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00000 as UInt64

        // Before the root view injects a window manager, undo routes to the
        // in-memory fallback used by tests / headless launches.
        let fallback = store.undoManager

        // Simulate WorkspaceRootView injecting the window's @Environment(\.undoManager).
        // groupsByEvent is off here so a discrete edit is a closed step without a
        // run-loop turn, mirroring how the window manager closes its per-event group.
        let host = UndoManager()
        host.groupsByEvent = false
        store.hostUndoManager = host
        XCTAssertTrue(store.undoManager === host)

        store.setCustomName(address, name: "decodeHeader")
        // The reversible action registered on the *injected* manager — the one the
        // standard Edit ▸ Undo item and Cmd-Z drive through the responder chain.
        XCTAssertTrue(host.canUndo)
        XCTAssertFalse(fallback.canUndo)
        XCTAssertEqual(host.undoMenuItemTitle, "Undo Rename")

        host.undo()
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])
        XCTAssertTrue(host.canRedo)
        XCTAssertEqual(host.redoMenuItemTitle, "Redo Rename")

        // Detaching the window manager (window closed) falls back in-memory.
        store.hostUndoManager = nil
        XCTAssertTrue(store.undoManager === fallback)
    }

    @MainActor
    func testClearingOverrideRemovesEntryAndEmptyEditIsNoOp() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let address = 0x1000_00004 as UInt64

        store.setCustomName(address, name: "foo")
        XCTAssertNotNil(store.snapshot.addressOverrides[.primary(address)])

        store.setCustomName(address, name: "   ") // clears the only field -> entry pruned
        XCTAssertNil(store.snapshot.addressOverrides[.primary(address)])

        // An empty edit on an absent override changes nothing and registers no undo.
        store.undoManager.removeAllActions()
        store.setCustomComment(0x1000_99999, comment: "")
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000_99999)])
        XCTAssertFalse(store.undoManager.canUndo)
    }

    @MainActor
    func testCustomNameBlendsIntoSidebarAndDisplayHelpers() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectedTool = .project
        let function = store.snapshot.functions[0]

        XCTAssertTrue(store.sidebarItems.contains { $0.id == "function:\(function.id.uuidString)" && $0.title == function.name })

        store.setCustomName(function.startAddress, name: "renamedEntry")

        XCTAssertTrue(store.sidebarItems.contains { $0.id == "function:\(function.id.uuidString)" && $0.title == "renamedEntry" })
        XCTAssertEqual(store.snapshot.displayName(at: function.startAddress, default: function.name), "renamedEntry")

        // Use a later instruction (not the renamed function's start address).
        let address = store.snapshot.instructions[1].address
        XCTAssertFalse(store.snapshot.hasOverride(at: address))
        store.setCustomComment(address, comment: "user note")
        XCTAssertEqual(store.snapshot.displayComment(at: address, default: "decoded fallback"), "user note")
        XCTAssertTrue(store.snapshot.hasOverride(at: address))

        // Without an override, the helpers return the parsed/decoded value.
        XCTAssertEqual(store.snapshot.displayName(at: 0x9999_9999, default: "sub_x"), "sub_x")
        XCTAssertEqual(store.snapshot.displayComment(at: 0x9999_9999, default: "decoder note"), "decoder note")
    }

    @MainActor
    func testOverrideEditorRequestsSeedAndCommitApplyOverrides() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let function = store.snapshot.functions[0]

        // Without a selection the rename command surfaces guidance, no editor.
        store.selectedAddress = nil
        store.beginRenameAtSelection()
        XCTAssertNil(store.overrideEditorRequest)

        // Selecting within the function opens a Rename editor seeded with its name.
        store.selectInstruction(function.startAddress)
        store.beginRenameAtSelection()
        XCTAssertEqual(store.overrideEditorRequest?.kind, .rename)
        XCTAssertEqual(store.overrideEditorRequest?.address, function.startAddress)
        XCTAssertEqual(store.overrideEditorRequest?.initialValue, function.name)

        store.commitOverrideEditor("renamedViaCommand")
        XCTAssertNil(store.overrideEditorRequest)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(function.startAddress)]?.customName, "renamedViaCommand")

        // Comment editor on a later instruction; commit applies the comment.
        let address = store.snapshot.instructions[1].address
        store.selectInstruction(address)
        store.beginCommentEditAtSelection()
        XCTAssertEqual(store.overrideEditorRequest?.kind, .comment)
        store.commitOverrideEditor("note via command")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customComment, "note via command")

        // Cancel leaves the prior value untouched.
        store.beginCommentEditAtSelection()
        store.cancelOverrideEditor()
        XCTAssertNil(store.overrideEditorRequest)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(address)]?.customComment, "note via command")
    }

    @MainActor
    func testSidebarActivationDrivesEditorSelection() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()

        let initialAddress = try XCTUnwrap(store.snapshot.instructions.last?.address)
        let targetFunction = try XCTUnwrap(store.snapshot.functions.first)
        store.selectInstruction(initialAddress)
        XCTAssertNotEqual(initialAddress, targetFunction.startAddress)
        XCTAssertTrue(
            store.snapshot.containsLoadedAddress(
                targetFunction.startAddress,
                in: store.snapshot.primarySlot
            )
        )
        store.editorMode = .hex
        store.activateSidebarItem("function:\(targetFunction.id.uuidString)")
        XCTAssertEqual(store.selectedSidebarItemID, "function:\(targetFunction.id.uuidString)")
        XCTAssertEqual(store.selectedAddress, targetFunction.startAddress)
        XCTAssertEqual(store.editorMode, .disassembly)

        let targetXRef = try XCTUnwrap(store.snapshot.xrefs.first)
        store.editorMode = .graph
        store.activateSidebarItem("xref:\(targetXRef.id.uuidString)")
        XCTAssertEqual(store.selectedSidebarItemID, "xref:\(targetXRef.id.uuidString)")
        XCTAssertEqual(store.selectedAddress, targetXRef.from)
        XCTAssertEqual(store.editorMode, .disassembly)
    }

    @MainActor
    func testSidebarKeyboardNavigationSkipsHeadersAndWraps() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectedTool = .project

        let selectableItems = store.selectableVisibleSidebarItems
        XCTAssertEqual(selectableItems.count, store.snapshot.binaries.count + store.snapshot.functions.count)
        XCTAssertFalse(selectableItems.contains { $0.isSectionHeader })

        store.selectedSidebarItemID = selectableItems.first?.id
        store.selectAdjacentSidebarItem(.next)

        XCTAssertEqual(store.selectedSidebarItemID, selectableItems.dropFirst().first?.id)
        XCTAssertEqual(store.editorMode, .disassembly)

        store.selectAdjacentSidebarItem(.previous)
        XCTAssertEqual(store.selectedSidebarItemID, selectableItems.first?.id)

        store.selectedSidebarItemID = selectableItems.last?.id
        store.selectAdjacentSidebarItem(.next)
        XCTAssertEqual(store.selectedSidebarItemID, selectableItems.first?.id)

        store.sidebarSearchText = "render"
        XCTAssertEqual(store.selectableVisibleSidebarItems.map(\.title), ["_render_listing"])
        store.selectDefaultSidebarItemIfNeeded()
        store.selectAdjacentSidebarItem(.next)
        XCTAssertEqual(store.selectedSidebarItemID, store.selectableVisibleSidebarItems.first?.id)

        store.sidebarSearchText = "not-present"
        store.selectAdjacentSidebarItem(.next)
        XCTAssertNil(store.selectedSidebarItemID)
    }

    @MainActor
    func testDisassemblyKeyboardNavigationIsBoundedAndUpdatesGraphSelection() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let instructions = store.snapshot.instructions
        XCTAssertGreaterThan(instructions.count, 2)

        let firstAddress = try XCTUnwrap(instructions.first?.address)
        store.selectInstruction(firstAddress)
        let firstGraphElementID = store.selectedGraphElementID

        store.selectAdjacentInstruction(.previous)
        XCTAssertEqual(store.selectedAddress, firstAddress)
        XCTAssertEqual(store.selectedGraphElementID, firstGraphElementID)

        store.selectAdjacentInstruction(.next)
        XCTAssertEqual(store.selectedAddress, instructions[1].address)
        XCTAssertEqual(store.selectedGraphElementID, firstGraphElementID)

        let lastAddress = try XCTUnwrap(instructions.last?.address)
        store.selectInstruction(lastAddress)
        store.selectAdjacentInstruction(.next)
        XCTAssertEqual(store.selectedAddress, lastAddress)
    }

    @MainActor
    func testGraphNodeSelectionTargetsDriveKeyboardNavigation() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let function = try XCTUnwrap(store.snapshot.functions.first)
        store.snapshot.functions = [function]
        store.snapshot.basicBlocks = [
            BasicBlockSummary(
                id: UUID(),
                functionID: function.id,
                startAddress: 0x1000_00000,
                endAddress: 0x1000_00008,
                instructionCount: 2
            ),
            BasicBlockSummary(
                id: UUID(),
                functionID: function.id,
                startAddress: 0x1000_00008,
                endAddress: 0x1000_00018,
                instructionCount: 4
            ),
            BasicBlockSummary(
                id: UUID(),
                functionID: function.id,
                startAddress: 0x1000_00018,
                endAddress: 0x1000_00028,
                instructionCount: 4
            )
        ]
        store.snapshot.xrefs = []
        store.snapshot.controlFlowEdges = []
        store.selectInstruction(0x1000_00000)
        let targets = store.graphNodeSelectionTargets

        XCTAssertEqual(targets.count, 3)
        XCTAssertEqual(targets.map(\.startAddress), [0x1000_00000, 0x1000_00008, 0x1000_00018])
        XCTAssertEqual(store.selectedGraphElementID, targets.first?.id)

        store.selectedTool = .symbols
        let lastTarget = try XCTUnwrap(targets.last)
        store.selectGraphNode(lastTarget)

        XCTAssertEqual(store.selectedGraphElementID, lastTarget.id)
        XCTAssertEqual(store.selectedAddress, 0x1000_00018)
        let lastFunctionID = try XCTUnwrap(lastTarget.functionID)
        XCTAssertEqual(store.selectedSidebarItemID, "symbol:\(lastFunctionID.uuidString)")

        store.selectAdjacentGraphNode(.next)
        XCTAssertEqual(store.selectedGraphElementID, targets.first?.id)
        XCTAssertEqual(store.selectedAddress, 0x1000_00000)

        store.selectAdjacentGraphNode(.previous)
        XCTAssertEqual(store.selectedGraphElementID, lastTarget.id)
        XCTAssertEqual(store.selectedAddress, 0x1000_00018)
    }

    @MainActor
    func testGraphNavigationResolvesInstructionGapsWithinContainingFunction() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let mainFunction = try XCTUnwrap(store.snapshot.functions.first)
        let gapAddress = 0x1000_00014 as UInt64
        let firstBlockID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondBlockID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        store.snapshot.basicBlocks = [
            BasicBlockSummary(
                id: firstBlockID,
                functionID: mainFunction.id,
                startAddress: 0x1000_00000,
                endAddress: 0x1000_00008,
                instructionCount: 2
            ),
            BasicBlockSummary(
                id: secondBlockID,
                functionID: mainFunction.id,
                startAddress: 0x1000_00020,
                endAddress: 0x1000_00028,
                instructionCount: 2
            )
        ] + store.snapshot.basicBlocks.dropFirst()

        let targets = store.graphNodeSelectionTargets
        let firstTarget = try XCTUnwrap(targets.first { $0.startAddress == 0x1000_00000 })
        let secondTarget = try XCTUnwrap(targets.first { $0.startAddress == 0x1000_00020 })

        store.selectInstruction(gapAddress)
        XCTAssertEqual(store.selectedGraphElementID, firstTarget.id)

        store.selectAdjacentGraphNode(.next)
        XCTAssertEqual(store.selectedGraphElementID, secondTarget.id)
        XCTAssertEqual(store.selectedAddress, 0x1000_00020)

        let edge = try XCTUnwrap(store.snapshot.controlFlowEdges.first { $0.from == gapAddress })
        store.selectedTool = .project
        store.selectedSidebarItemID = store.snapshot.binaries.first.map { "binary:\($0.id.uuidString)" }
        store.selectGraphEdge(id: "cfg:\(edge.id.uuidString)", from: edge.from, to: edge.to, kind: edge.kind)

        XCTAssertEqual(store.selectedGraphElementID, "cfg:\(edge.id.uuidString)")
        XCTAssertEqual(store.selectedAddress, gapAddress)
        XCTAssertEqual(store.selectedSidebarItemID, "function:\(mainFunction.id.uuidString)")
    }

    @MainActor
    func testGraphEdgeSelectionTracksSourceAndXRefSidebarContext() throws {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let edge = try XCTUnwrap(store.snapshot.controlFlowEdges.first)
        let matchingXRef = try XCTUnwrap(store.snapshot.xrefs.first {
            $0.from == edge.from && $0.to == edge.to && $0.kind == edge.kind
        })
        let edgeID = "cfg:\(edge.id.uuidString)"
        let xrefSidebarID = "xref:\(matchingXRef.id.uuidString)"

        store.selectedTool = .xrefs
        store.selectGraphEdge(id: edgeID, from: edge.from, to: edge.to, kind: edge.kind)

        XCTAssertEqual(store.selectedGraphElementID, edgeID)
        XCTAssertEqual(store.selectedAddress, edge.from)
        XCTAssertEqual(store.selectedSidebarItemID, xrefSidebarID)

        store.selectInstruction(0x1000_00000)

        XCTAssertEqual(store.selectedAddress, 0x1000_00000)
        XCTAssertEqual(store.selectedGraphElementID, store.graphNodeSelectionTargets.first?.id)
    }

    @MainActor
    func testWorkspaceStorePersistsAndRestoresSessionState() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let targetFunction = try XCTUnwrap(store.snapshot.functions.first)
        let targetAddress = try XCTUnwrap(store.snapshot.instructions.last?.address)
        store.workspaceName = "Store Session"
        store.selectedTool = .symbols
        store.editorMode = .graph
        store.selectedSidebarItemID = "symbol:\(targetFunction.id.uuidString)"
        store.selectedAddress = targetAddress
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: store.snapshot.primarySlot, address: targetAddress)
        )
        store.isInspectorPresented = false
        store.sidebarSearchText = "render"

        let persisted = try store.saveWorkspace(
            to: database,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)

        let restoredStore = WorkspaceStore.bootstrap()
        restoredStore.workspaceName = "Temporary"
        restoredStore.selectedTool = .debug
        restoredStore.editorMode = .hex
        restoredStore.selectedSidebarItemID = "debug:session"
        restoredStore.selectedAddress = nil
        restoredStore.isInspectorPresented = true
        restoredStore.sidebarSearchText = "debug"

        XCTAssertTrue(try restoredStore.restoreWorkspace(workspaceID: workspaceID, from: database))
        XCTAssertEqual(restoredStore.workspaceName, "Store Session")
        XCTAssertEqual(restoredStore.selectedTool, .symbols)
        XCTAssertEqual(restoredStore.editorMode, .graph)
        XCTAssertEqual(restoredStore.selectedSidebarItemID, "symbol:\(targetFunction.id.uuidString)")
        XCTAssertEqual(restoredStore.selectedAddress, targetAddress)
        XCTAssertEqual(
            restoredStore.selectedImageAddress,
            ImageAddress(slot: restoredStore.snapshot.primarySlot, address: targetAddress)
        )
        XCTAssertEqual(restoredStore.isInspectorPresented, false)
        XCTAssertEqual(restoredStore.sidebarSearchText, "render")
        XCTAssertEqual(restoredStore.snapshot.instructions, store.snapshot.instructions)
        XCTAssertEqual(restoredStore.snapshot.controlFlowEdges, store.snapshot.controlFlowEdges)

        let reloadedStore = try XCTUnwrap(WorkspaceStore.restored(workspaceID: workspaceID, from: database))
        XCTAssertEqual(reloadedStore.workspaceName, "Store Session")
        XCTAssertEqual(reloadedStore.selectedSidebarItemID, "symbol:\(targetFunction.id.uuidString)")
        XCTAssertEqual(reloadedStore.selectedAddress, targetAddress)
        XCTAssertEqual(reloadedStore.editorMode, .graph)
    }

    @MainActor
    func testWorkspaceStoreSubsequentSaveUpdatesPersistedWorkspaceInPlace() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.workspaceName = "First Save"
        let firstPersisted = try store.saveWorkspace(
            to: database,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let workspaceID = try XCTUnwrap(firstPersisted.workspace.id)

        store.workspaceName = "Second Save"
        store.selectedTool = .debug
        store.editorMode = .hex
        store.sidebarSearchText = "breakpoints"
        store.toggleBreakpoint(0x1000_00000)

        let secondPersisted = try store.saveWorkspace(
            to: database,
            now: Date(timeIntervalSince1970: 1_800_000_120)
        )
        let reloaded = try XCTUnwrap(WorkspaceStore.restored(workspaceID: workspaceID, from: database))

        XCTAssertEqual(secondPersisted.workspace.id, workspaceID)
        XCTAssertEqual(store.persistedWorkspaceID, workspaceID)
        XCTAssertEqual(try database.workspaces().count, 1)
        XCTAssertEqual(reloaded.workspaceName, "Second Save")
        XCTAssertEqual(reloaded.selectedTool, .debug)
        XCTAssertEqual(reloaded.editorMode, .hex)
        XCTAssertEqual(reloaded.sidebarSearchText, "breakpoints")
        XCTAssertTrue(reloaded.snapshot.instructions.contains { $0.address == 0x1000_00000 && $0.hasBreakpoint })
    }

    @MainActor
    func testWorkspaceStoreSavesPortablePackageThroughDatabase() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let documentID = UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
        store.workspaceName = "Store Package"

        let manifest = try store.saveWorkspacePackage(
            to: packageURL,
            using: database,
            documentID: documentID,
            inputCopyingDecision: .referenceOriginalInputs,
            bookmarkResolutionDecision: .promptForMissingInputs,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let binary = try XCTUnwrap(manifest.binaries.first)
        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: packageURL,
            relativePath: binary.attachmentRelativePath
        )

        XCTAssertEqual(manifest.documentID, documentID)
        XCTAssertEqual(manifest.workspaceName, "Store Package")
        XCTAssertEqual(manifest.inputCopyingDecision, .referenceOriginalInputs)
        XCTAssertEqual(manifest.bookmarkResolutionDecision, .promptForMissingInputs)
        XCTAssertEqual(binary.fileHash, MacScopeDocumentPackage.fileHash(for: store.snapshot.hexBytes))
        XCTAssertEqual(try Data(contentsOf: attachmentURL), store.snapshot.hexBytes)
        let reopened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(reopened.manifest.formatVersion, 4)
        XCTAssertEqual(reopened.manifest.analysisFormatVersion, 1)
        XCTAssertEqual(
            WorkspacePackageAnalysis(snapshot: reopened.snapshot),
            try XCTUnwrap(manifest.analysis)
        )
        XCTAssertEqual(reopened.session, manifest.session)

        let metadata = try XCTUnwrap(store.documentMetadata)
        XCTAssertEqual(metadata.workspaceName, "Store Package")
        XCTAssertEqual(metadata.documentID, documentID)
        XCTAssertEqual(metadata.packageURL.path, packageURL.standardizedFileURL.path)
        XCTAssertEqual(metadata.lifecycleState, .clean)
        XCTAssertEqual(metadata.inputCopyingDecision, .referenceOriginalInputs)
        XCTAssertEqual(metadata.bookmarkResolutionDecision, .promptForMissingInputs)
        XCTAssertEqual(metadata.recentDocumentState, .available)
        XCTAssertTrue(metadata.allowsAutosave)

        let unavailableAt = Date(timeIntervalSince1970: 1_800_000_120)
        let unavailableMetadata = try XCTUnwrap(
            store.markDocumentRecentState(.unreadable, in: database, updatedAt: unavailableAt)
        )
        XCTAssertEqual(unavailableMetadata.recentDocumentState, .unreadable)
        XCTAssertFalse(unavailableMetadata.allowsAutosave)

        let bookmarkMetadata = try XCTUnwrap(
            store.markBookmarkResolution(
                .promptForMissingInputs,
                in: database,
                errorMessage: "Original input bookmark could not be resolved."
            )
        )
        XCTAssertEqual(bookmarkMetadata.bookmarkResolutionDecision, .promptForMissingInputs)
        XCTAssertEqual(bookmarkMetadata.bookmarkResolutionError, "Original input bookmark could not be resolved.")
    }

    @MainActor
    func testWorkspaceStoreRestoresPortablePackageWithSessionAndAnalysis() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let store = WorkspaceStore.bootstrapForPreviewFixture()
        let targetFunction = try XCTUnwrap(store.snapshot.functions.first)
        let targetAddress = try XCTUnwrap(store.snapshot.instructions.last?.address)
        store.workspaceName = "Store Package Restore"
        store.selectedTool = .symbols
        store.editorMode = .graph
        store.selectedSidebarItemID = "function:\(targetFunction.id.uuidString)"
        store.selectedAddress = targetAddress
        XCTAssertEqual(
            store.selectedImageAddress,
            ImageAddress(slot: store.snapshot.primarySlot, address: targetAddress)
        )
        store.isInspectorPresented = false
        store.sidebarSearchText = "render"

        _ = try store.saveWorkspacePackage(
            to: packageURL,
            using: database,
            documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let restoredStore = try WorkspaceStore.restoredPackage(from: packageURL)

        XCTAssertEqual(restoredStore.workspaceName, "Store Package Restore")
        XCTAssertEqual(restoredStore.selectedTool, .symbols)
        XCTAssertEqual(restoredStore.editorMode, .graph)
        XCTAssertEqual(restoredStore.selectedSidebarItemID, "function:\(targetFunction.id.uuidString)")
        XCTAssertEqual(restoredStore.selectedAddress, targetAddress)
        XCTAssertEqual(
            restoredStore.selectedImageAddress,
            ImageAddress(slot: restoredStore.snapshot.primarySlot, address: targetAddress)
        )
        XCTAssertEqual(restoredStore.isInspectorPresented, false)
        XCTAssertEqual(restoredStore.sidebarSearchText, "render")
        XCTAssertEqual(restoredStore.snapshot.binaries, store.snapshot.binaries)
        XCTAssertEqual(restoredStore.snapshot.functions, store.snapshot.functions)
        XCTAssertEqual(restoredStore.snapshot.indirectSymbols, store.snapshot.indirectSymbols)
        XCTAssertEqual(restoredStore.snapshot.basicBlocks, store.snapshot.basicBlocks)
        XCTAssertEqual(restoredStore.snapshot.instructions, store.snapshot.instructions)
        XCTAssertEqual(restoredStore.snapshot.xrefs, store.snapshot.xrefs)
        XCTAssertEqual(restoredStore.snapshot.controlFlowEdges, store.snapshot.controlFlowEdges)
        XCTAssertEqual(restoredStore.snapshot.hexBytes, store.snapshot.hexBytes)
    }

    @MainActor
    func testSidebarFilteringKeepsValidNavigatorRows() {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        store.selectedTool = .project
        store.sidebarSearchText = "render"

        XCTAssertEqual(store.visibleSidebarItems.map(\.title), ["_render_listing"])
        XCTAssertTrue(store.visibleSidebarItems.allSatisfy { !$0.isSectionHeader })

        store.selectDefaultSidebarItemIfNeeded()
        XCTAssertEqual(store.selectedSidebarItemID, store.visibleSidebarItems.first?.id)
    }

    private func schemaTableNames(in schema: String) -> Set<String> {
        Set(schema.split(separator: ";").compactMap { statement in
            let normalized = statement.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.hasPrefix("CREATE TABLE ") else { return nil }
            let declaration = normalized.dropFirst("CREATE TABLE ".count)
            let tableDeclaration = declaration.hasPrefix("IF NOT EXISTS ")
                ? declaration.dropFirst("IF NOT EXISTS ".count)
                : declaration[...]
            return tableDeclaration
                .split { $0 == " " || $0 == "(" }
                .first
                .map(String.init)
        })
    }

    private func assertTable(
        _ tableName: String,
        in schema: String,
        contains expectedFragments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let body = schemaBody(for: tableName, in: schema) else {
            XCTFail("Missing schema table \(tableName)", file: file, line: line)
            return
        }

        for fragment in expectedFragments {
            XCTAssertTrue(
                body.contains(fragment),
                "Expected \(tableName) schema to include \(fragment)",
                file: file,
                line: line
            )
        }
    }

    private func schemaBody(for tableName: String, in schema: String) -> String? {
        schema.split(separator: ";").first { statement in
            statement.contains("CREATE TABLE \(tableName)")
                || statement.contains("CREATE TABLE IF NOT EXISTS \(tableName)")
        }.map(String.init)
    }

    private func workspaceDocumentMetadata(
        workspaceID: Int64,
        workspaceName: String,
        packagePath: String,
        isDirty: Bool,
        conflictReason: String? = nil
    ) -> WorkspaceDatabase.WorkspaceDocumentMetadata {
        let now = Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(workspaceID))
        return WorkspaceDatabase.WorkspaceDocumentMetadata(
            workspace: WorkspaceDatabase.WorkspaceRecord(
                id: workspaceID,
                uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: workspaceName,
                createdAt: now,
                modifiedAt: now
            ),
            document: WorkspaceDatabase.WorkspaceDocumentRecord(
                workspaceID: workspaceID,
                documentID: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!,
                packagePath: packagePath,
                lastOpenedAt: now,
                lastSavedAt: isDirty ? nil : now,
                isDirty: isDirty,
                conflictDetectedAt: conflictReason.map { _ in now },
                conflictReason: conflictReason
            )
        )
    }

    @MainActor
    private func activeBreakpointCount(in store: WorkspaceStore) -> Int {
        store.snapshot.instructions.filter(\.hasBreakpoint).count
    }

    @MainActor
    private func debugBreakpointItem(in store: WorkspaceStore) -> SidebarItem? {
        store.sidebarItems.first { $0.id == "debug:breakpoints" }
    }
}
