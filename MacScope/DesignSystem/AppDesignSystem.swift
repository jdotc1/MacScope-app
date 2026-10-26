import AppKit
import SwiftUI
import LumenTokens
import LumenUI




enum AppToolbarChrome {
    static let controlSize = ControlSize.small
    static let itemLineLimit = 1
    static let statusLabelMinWidth: CGFloat = 60
    static let metricMinWidth: CGFloat = 38
    static let modePickerMinWidth: CGFloat = 180
    static let modePickerIdealWidth: CGFloat = 208
    static let modePickerMaxWidth: CGFloat = 236

    static var statusClusterMinimumWidth: CGFloat {
        statusLabelMinWidth + metricMinWidth * 2
    }
}

enum AppSidebarChrome {
    static let listRowSpacing: CGFloat = 2
    static let sectionTopPadding: CGFloat = 10
    static let sectionHeaderMinHeight: CGFloat = 20
    static let headerSpacing: CGFloat = 10
    static let headerTopPadding: CGFloat = Lumen.Space.s5
    static let headerBottomPadding: CGFloat = Lumen.Space.s4
    static let contentLeadingPadding: CGFloat = Lumen.Space.s6
    static let contentTrailingPadding: CGFloat = Lumen.Space.s5
    static let rowHorizontalPadding: CGFloat = Lumen.Space.s4
    static let rowCompactVerticalPadding: CGFloat = 4
    static let rowDetailedVerticalPadding: CGFloat = 5
    static let rowCompactMinHeight: CGFloat = 26
    static let rowDetailedMinHeight: CGFloat = 36
    static let rowTextVerticalSpacing: CGFloat = 2
    static let rowTitleLineLimit = 1
    static let rowDetailLineLimit = 1
    static let minimumReadableTextColumnWidth: CGFloat = 248
    static let primaryNavigationMinimumTitleWidth: CGFloat = 96
    static let estimatedPrimaryTitleCharacterWidth: CGFloat = 7.4
    static let rowIconSize: CGFloat = 12
    static let rowIconWidth: CGFloat = 16
    /// Upper bound for a user tag chip on a sidebar row so a long tag truncates
    /// instead of squeezing the title/detail column.
    static let tagChipMaxWidth: CGFloat = 96
    static let rowContentSpacing: CGFloat = Lumen.Space.s4
    static let selectionCornerRadius: CGFloat = Lumen.Radius.xs
    static let focusCornerRadius: CGFloat = Lumen.Radius.sm
    static let minimumAccessibilityLabelLength = 3
    static let stringPreviewMaxLength = 96
    static let searchFieldHeight: CGFloat = 24
    static let toolButtonSize: CGFloat = 28
    static let toolIconSize: CGFloat = 15
    static let summaryDividerHeight: CGFloat = 18
    static let importRowIcon = "arrow.down.circle"
    static let exportRowIcon = "arrow.up.circle"

    static func readableTextColumnWidth(forSidebarWidth sidebarWidth: CGFloat) -> CGFloat {
        sidebarWidth
            - contentLeadingPadding
            - contentTrailingPadding
            - rowHorizontalPadding * 2
            - rowIconWidth
            - rowContentSpacing
    }

    static func estimatedPrimaryNavigationTitleWidth(_ title: String) -> CGFloat {
        max(primaryNavigationMinimumTitleWidth, CGFloat(title.count) * estimatedPrimaryTitleCharacterWidth)
    }

    static func primaryNavigationTitleFits(_ title: String, forSidebarWidth sidebarWidth: CGFloat) -> Bool {
        estimatedPrimaryNavigationTitleWidth(title) <= readableTextColumnWidth(forSidebarWidth: sidebarWidth)
    }

    static var maximumDetailedRowTextLines: Int {
        rowTitleLineLimit + rowDetailLineLimit
    }

    static func reservesMinimumReadableTextColumn(forSidebarWidth sidebarWidth: CGFloat) -> Bool {
        readableTextColumnWidth(forSidebarWidth: sidebarWidth) >= minimumReadableTextColumnWidth
    }

    static func accessibilityLabel(title: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else {
            return title
        }
        return "\(title), \(detail)"
    }

    static func accessibilityLabel(for item: SidebarItem) -> String {
        var label = accessibilityLabel(title: item.title, detail: item.detail)
        if let tag = item.tag, !tag.isEmpty {
            label += ", tag \(tag)"
        }
        if let colorTag = item.colorTag {
            label += ", \(colorTag.displayName) highlight"
        }
        return label
    }

    static func accessibilityValue(for selectedItem: SidebarItem?) -> String {
        guard let selectedItem else {
            return "No selection"
        }
        return accessibilityLabel(for: selectedItem)
    }

    static func accessibilityHint(isSelected: Bool) -> String {
        isSelected ? "Selected navigator item" : "Selects this navigator item"
    }
}

enum AppEditorChrome {
    static let contextBarHeight: CGFloat = 30
    static let disassemblyHeaderHeight: CGFloat = 26
    static let disassemblyRowHeight: CGFloat = 26
    static let disassemblyContinuationRowCount = 28
    static let disassemblySelectedIndicatorWidth: CGFloat = 3
    static let disassemblySelectedIndicatorCornerRadius: CGFloat = 1.5
    /// Upper bound for a user tag chip in the listing comment column so a long
    /// tag truncates instead of overflowing the comment.
    static let listingTagChipMaxWidth: CGFloat = 140
    static let disassemblyCompactWidthThreshold: CGFloat = 700
    static let disassemblyMinimumFlexibleWidth: CGFloat = 240
    static let pseudocodeLineNumberWidth: CGFloat = 44
    static let pseudocodeAddressWidth: CGFloat = 136
    static let pseudocodeRowMinHeight: CGFloat = 24
    static let hexStatusBarHeight: CGFloat = 28
    static let hexBytesPerRow = 16
    static let hexMinimumReadableRows = 8
    static let hexOffsetColumnWidth: CGFloat = 116
}

enum AppInspectorChrome {
    static let headerIconWidth: CGFloat = 18
    static let contentHorizontalPadding: CGFloat = Lumen.Space.s6
    static let contentVerticalPadding: CGFloat = Lumen.Space.s5
    static let sectionSpacing: CGFloat = Lumen.Space.s5
    static let sectionHeaderMinHeight: CGFloat = 22
    static let sectionIconWidth: CGFloat = 16
    static let valueGroupVerticalPadding: CGFloat = Lumen.Space.s2
    static let metadataLabelWidth: CGFloat = 82
    static let endpointLabelWidth: CGFloat = 42
    static let metadataRowMinHeight: CGFloat = 24
    static let metadataDefaultValueLineLimit = 2
    static let metadataExpandedValueLineLimit = 4
    static let metadataLongValueCharacterThreshold = 48
    static let metadataValueMinimumScaleFactor: CGFloat = 0.88
    static let endpointAddressMinimumScaleFactor: CGFloat = 0.86
    static let dataInspectorStringPreviewMaxLength = 24

    static func metadataValueLineLimit(for value: String) -> Int {
        isLongMetadataValue(value) ? metadataExpandedValueLineLimit : metadataDefaultValueLineLimit
    }

    static func isLongMetadataValue(_ value: String) -> Bool {
        value.count > metadataLongValueCharacterThreshold
            || value.contains("/")
            || value.contains("::")
            || value.contains(".")
    }

    static func metadataAccessibilityLabel(label: String, value: String) -> String {
        "\(label), \(value)"
    }

    /// Renders a 0...1 confidence as an integer-percent label (e.g. 0.92 -> "92%").
    /// Returns nil for non-positive confidence so callers can omit the row.
    static func confidencePercentText(for confidence: Double) -> String? {
        guard confidence > 0 else { return nil }
        return "\(Int((confidence * 100).rounded()))%"
    }
}

enum AppDebuggerChrome {
    static let headerVerticalPadding: CGFloat = 6
    static let compactVerticalPadding: CGFloat = 6
    static let deckHorizontalPadding: CGFloat = Lumen.Space.s6
    static let statusDetailMinWidth: CGFloat = 160
    static let tabPickerMinWidth: CGFloat = 184
    static let tabPickerIdealWidth: CGFloat = 220
    static let tabPickerMaxWidth: CGFloat = 260
    static let targetPickerIconWidth: CGFloat = 16
    static let targetPickerRowVerticalPadding: CGFloat = 5
    static let consolePrefixWidth: CGFloat = 58
    static let deckKeyWidth: CGFloat = 116
    static let deckValueMinWidth: CGFloat = 180
    static let compactTransportOpacity: Double = 0.72
    static let disabledTransportOpacity: Double = 0.46
}

enum AppShellChrome {
    static let horizontalPadding: CGFloat = Lumen.Space.s6
    static let verticalPadding: CGFloat = Lumen.Space.s4
    static let configurationLabelWidth: CGFloat = 108
    static let executableFieldMinWidth: CGFloat = 180
    static let argumentsFieldMinWidth: CGFloat = 180
    static let environmentFieldMinWidth: CGFloat = 210
    static let workingDirectoryFieldMinWidth: CGFloat = 210
    static let compactConfigurationSummaryMinWidth: CGFloat = 220
    static let launchSettingsPopoverWidth: CGFloat = 520
    static let launchSettingsPopoverFieldMinWidth: CGFloat = 340
    static let terminalDimensionFieldWidth: CGFloat = 54
    static let transcriptPreviewMinWidth: CGFloat = 220
    static let transcriptScrollbackMinHeight: CGFloat = 54
    static let transcriptScrollbackIdealHeight: CGFloat = 72
    static let transcriptLinePrefixWidth: CGFloat = 42
    static let maximumRenderedTranscriptLines = 80
    static let maximumRenderedTranscriptTurns = 12
    static let transcriptLineCharacterLimit = 96
    static let maximumInputHistoryEntries = 50
    static let inputMinWidth: CGFloat = 180
    static let inputIdealWidth: CGFloat = 280
    static let transcriptSearchMinWidth: CGFloat = 132
    static let transcriptSearchIdealWidth: CGFloat = 168
    static let statusDetailMinWidth: CGFloat = 140
    static let autoPollIntervalNanoseconds: UInt64 = 750_000_000
    static let autoPollMaximumEvents = 32
    static let autoPollMaximumBytes = 8_192
    static let autoPollTimeoutMilliseconds = 25
}

enum AppGraphChrome {
    static let compactColumnThreshold: CGFloat = 720
    static let regularColumnThreshold: CGFloat = 1080
    static let outerMargin: CGFloat = 20
    static let laneGap: CGFloat = 52
    static let headerHeight: CGFloat = 54
    static let nodeTopPadding: CGFloat = 20
    static let nodeVerticalGap: CGFloat = 34
    static let minimumAvailableWidth: CGFloat = 320
    static let laneMinWidth: CGFloat = 300
    static let laneMaxWidth: CGFloat = 360
    static let nodeHorizontalInset: CGFloat = 32
    static let nodeHeight: CGFloat = 108
    static let minimumLaneHeight: CGFloat = 320
    static let overviewMinHeight: CGFloat = 38
    static let arrowHeadSize: CGFloat = 9
    /// Upper bound for a graph node metadata pill (e.g. a user tag) so a long
    /// value truncates instead of overflowing the fixed-width node card.
    static let metadataPillMaxWidth: CGFloat = 120

    /// Spatial minimap (bird's-eye overlay) tunables. The minimap is a small, fixed-size
    /// card pinned to the canvas's bottom-trailing corner that draws the whole graph
    /// scaled-to-fit with a movable viewport rectangle showing what the scroll view shows.
    static let minimapMaxWidth: CGFloat = 180
    static let minimapMaxHeight: CGFloat = 150
    static let minimapPadding: CGFloat = 6
    static let minimapCornerRadius: CGFloat = Lumen.Radius.sm
    /// The canvas must be at least this much larger than the viewport (in either axis)
    /// before the minimap appears — there is nothing to overview when everything fits.
    static let minimapActivationSlack: CGFloat = 24

    static func visibleColumnCount(for viewportWidth: CGFloat) -> CGFloat {
        if viewportWidth < compactColumnThreshold {
            return 1
        }
        if viewportWidth < regularColumnThreshold {
            return 2
        }
        return 3
    }

    static func laneWidth(for viewportWidth: CGFloat) -> CGFloat {
        let visibleColumns = visibleColumnCount(for: viewportWidth)
        let availableWidth = max(
            minimumAvailableWidth,
            viewportWidth - outerMargin * 2 - (visibleColumns - 1) * laneGap
        )
        return min(laneMaxWidth, max(laneMinWidth, availableWidth / visibleColumns))
    }

    static func nodeSize(for laneWidth: CGFloat) -> CGSize {
        CGSize(width: laneWidth - nodeHorizontalInset, height: nodeHeight)
    }
}

enum AppStateChrome {
    static let cardMaxWidth: CGFloat = 520
    static let copyMaxWidth: CGFloat = 420
    static let iconFrameSize: CGFloat = 52
    static let iconSymbolSize: CGFloat = 26
    static let iconCornerRadius: CGFloat = Lumen.Radius.lg
    static let cardPadding: CGFloat = Lumen.Space.s7
    static let outerPadding: CGFloat = Lumen.Space.s8
    static let minPanelWidth: CGFloat = 320
    static let actionTopPadding: CGFloat = Lumen.Space.s4
    static let titleLineLimit = 2
    static let detailLineLimit = 4
    static let recoveryLineLimit = 3

    static func separatorLineWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        AppContrastChrome.hairlineWidth(for: contrast)
    }
}


enum AppFocusChrome {
    static let ringWidth: CGFloat = 1
    static let increasedContrastRingWidth: CGFloat = 1.5

    static func ringWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? increasedContrastRingWidth : ringWidth
    }
}

enum AppContrastChrome {
    static let hairline: CGFloat = 0.5
    static let regularStroke: CGFloat = 1
    static let increasedStroke: CGFloat = 1.5

    static func hairlineWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? regularStroke : hairline
    }

    static func strokeWidth(for contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? increasedStroke : regularStroke
    }
}

enum AppSettingsChrome {
    // Eight settings categories no longer fit a legible horizontal tab strip. The native
    // source-list sidebar remains stable while the selected detail pane owns scrolling.
    static let categoryMinWidth: CGFloat = 168
    static let categoryIdealWidth: CGFloat = 184
    static let categoryMaxWidth: CGFloat = 208
    static let detailMinWidth: CGFloat = 520
    static let detailIdealWidth: CGFloat = 560
    static let stableContentHeight: CGFloat = 620
    static let windowMinWidth: CGFloat = categoryMinWidth + detailMinWidth
    static let windowIdealWidth: CGFloat = categoryIdealWidth + detailIdealWidth
    static let windowWidth: CGFloat = windowIdealWidth
    static let windowMinHeight: CGFloat = stableContentHeight
    static let windowMaxHeight: CGFloat = 720
    // Compatibility token for the outgoing horizontal-tab implementation. Remove it with
    // SettingsTabSizing after the sidebar migration is complete.
    static let tabBarChromeHeight: CGFloat = 62
    static let contentPadding: CGFloat = Lumen.Space.s6
    static let footnoteLineLimit = 3
    static let keyBindingTableHeight: CGFloat = 320
    static let keyChordRecorderWidth: CGFloat = 96
    static let keyChordRecorderHeight: CGFloat = 22
    static let keyShortcutMinWidth: CGFloat = 70
}

/// Floating progress overlay for whole-image pseudocode export (bottom-trailing in the workspace).
enum AppExportProgressChrome {
    static let progressWidth: CGFloat = 120
    static let padding: CGFloat = Lumen.Space.s4
    static let cornerRadius: CGFloat = Lumen.Radius.md
    static let material: Material = .regularMaterial
}

enum AppLocalAISettingsChrome {
    static let sectionSpacing: CGFloat = Lumen.Space.s6
    static let controlRowSpacing: CGFloat = Lumen.Space.s5
    static let fieldLabelWidth: CGFloat = 124
    static let endpointFieldMinWidth: CGFloat = 320
    static let timeoutFieldWidth: CGFloat = 92
    static let statusSymbolWidth: CGFloat = 18
    static let modelRowMinHeight: CGFloat = 38
    static let modelRowTextSpacing: CGFloat = 2
    static let modelKeyLineLimit = 1

    static let categorySymbol = "server.rack"
    static let refreshSymbol = "arrow.clockwise"
    static let languageModelSymbol = "text.bubble"
    static let embeddingModelSymbol = "square.stack.3d.up"
    static let loadedModelSymbol = "checkmark.circle.fill"
    static let unloadedModelSymbol = "circle"

    static func statusSymbol(for tone: AppLocalAIStatusTone) -> String {
        switch tone {
        case .neutral:
            "circle"
        case .inProgress:
            "arrow.clockwise"
        case .warning:
            "exclamationmark.triangle.fill"
        case .error:
            "xmark.octagon.fill"
        case .ready:
            "checkmark.circle.fill"
        }
    }

    static func statusColor(for tone: AppLocalAIStatusTone) -> Color {
        switch tone {
        case .neutral, .inProgress:
            .secondary
        case .warning:
            Color.lumen(.statusWarning)
        case .error:
            Color.lumen(.statusDanger)
        case .ready:
            Color.lumen(.statusSuccess)
        }
    }
}

enum AppLocalAIStatusTone: Equatable {
    case neutral
    case inProgress
    case warning
    case error
    case ready
}

enum AppPaneRole {
    case sidebar
    case editor
    case inspector
    case debugger
    case toolbar
    case settings

    var baseFill: Color {
        switch self {
        case .sidebar, .inspector, .debugger, .toolbar:
            Color.lumen(.bgSidebar)
        case .editor, .settings:
            Color.lumen(.bgCanvas)
        }
    }

    /// Crisp solid surfaces — no translucent vibrancy. Definition comes from the value step
    /// between `panel` and `editor` plus the hairline between panes, not from blur.
    var usesMaterial: Bool { false }
}

enum AppInteractionState: Equatable {
    case disabled
    case selectedActive
    case selectedInactive
    case focused
    case hovered
    case normal

    var isSelected: Bool {
        self == .selectedActive || self == .selectedInactive
    }
}

enum AppInteractionChrome {
    static func sourceListState(
        isSelected: Bool,
        isFocused: Bool,
        isHovering: Bool,
        isEnabled: Bool = true,
        isActiveWindow: Bool
    ) -> AppInteractionState {
        guard isEnabled else { return .disabled }
        if isSelected {
            return isActiveWindow ? .selectedActive : .selectedInactive
        }
        if isFocused {
            return .focused
        }
        if isHovering {
            return .hovered
        }
        return .normal
    }

    static func selectedPrimaryForeground(isActiveWindow: Bool, editorSurface: Bool = false) -> Color {
        if editorSurface { return DS.editorColor(.fgPrimary) }
        return isActiveWindow ? Color.lumen(.fgPrimary) : .primary
    }

    static func selectedSecondaryForeground(isActiveWindow: Bool, opacity: Double = 0.76,
                                           editorSurface: Bool = false) -> Color {
        if editorSurface { return DS.editorColor(.fgPrimary).opacity(opacity) }
        return isActiveWindow ? Color.lumen(.fgPrimary).opacity(opacity) : .secondary
    }

    static func sourceListRowFill(for state: AppInteractionState) -> Color {
        switch state {
        case .selectedActive:
            Color.lumen(.sidebarRowSelected)
        case .selectedInactive:
            Color.lumen(.bgSelectedInactive)
        case .focused, .hovered:
            Color.lumen(.sidebarRowHover)
        case .disabled, .normal:
            .clear
        }
    }

    static func toolFill(for state: AppInteractionState) -> Color {
        switch state {
        case .selectedActive, .selectedInactive:
            Color.lumen(.accentSubtle)
        case .focused, .hovered:
            Color.lumen(.sidebarRowHover)
        case .disabled, .normal:
            .clear
        }
    }

    static func listingSelectionFill(isActiveWindow: Bool) -> Color {
        DS.editorColor(isActiveWindow ? .listingSelection : .bgSelectedInactive)
    }

    static func selectedTokenFill(isActiveWindow: Bool, editorSurface: Bool = false) -> Color {
        if editorSurface { return DS.editorColor(isActiveWindow ? .accentSubtle : .bgSelectedInactive) }
        return isActiveWindow ? Color.lumen(.accentSubtle) : Color.lumen(.bgSelectedInactive)
    }

    static func rowStrokeWidth(isSelected: Bool, isFocused: Bool, contrast: ColorSchemeContrast) -> CGFloat {
        isSelected || isFocused ? AppContrastChrome.strokeWidth(for: contrast) : AppContrastChrome.hairlineWidth(for: contrast)
    }
}

enum AppAccessibilityText {
    static let disassemblyTableLabel = "Disassembly table"

    static func sidebarNavigatorLabel(tool: WorkspaceTool) -> String {
        "\(tool.rawValue) navigator"
    }

    static func sourceListLabel(tool: WorkspaceTool) -> String {
        "\(tool.rawValue) source list"
    }

    static func breakpointButtonLabel(hasBreakpoint: Bool) -> String {
        hasBreakpoint ? "Remove breakpoint" : "Set breakpoint"
    }

    static func disassemblyRowLabel(
        address: String,
        mnemonic: String,
        operands: String,
        hasBreakpoint: Bool,
        comment: String?
    ) -> String {
        var components = [
            address,
            mnemonic,
            operands.isEmpty ? "no operands" : operands
        ]

        if hasBreakpoint {
            components.append("breakpoint set")
        }

        if let comment, !comment.isEmpty {
            components.append("comment: \(comment)")
        }

        return components.joined(separator: ", ")
    }

    static func disassemblyRowHint(isSelected: Bool) -> String {
        isSelected ? "Selected instruction row" : "Selects this instruction row"
    }

    static func inspectorLabel(selectionAddress: String?) -> String {
        selectionAddress.map { "Inspector, selected instruction \($0)" } ?? "Inspector, no selection"
    }

    /// Owner-aware inspector container label for multi-image workspaces. A mapped address can be
    /// selected without decoding to an instruction, so the caller supplies that distinction rather
    /// than letting accessibility invent an instruction that analysis did not recover.
    static func inspectorLabel(
        selectionAddress: String?,
        imageName: String?,
        isInstruction: Bool
    ) -> String {
        guard let selectionAddress else {
            return imageName.map { "Inspector, no selection, \($0)" } ?? "Inspector, no selection"
        }
        let selectionKind = isInstruction ? "selected instruction" : "selected address"
        if let imageName {
            return "Inspector, \(imageName), \(selectionKind) \(selectionAddress)"
        }
        return "Inspector, \(selectionKind) \(selectionAddress)"
    }

    static func xrefLabel(kind: String, from: String, to: String) -> String {
        "\(kind.capitalized) cross-reference, from \(from), to \(to)"
    }

    static func debuggerTargetLabel(title: String, status: String, detail: String) -> String {
        "\(title), \(status). \(detail)"
    }
}

enum AppTypography {
    static let sidebarTitle = Font.system(.body, design: .default).weight(.medium)
    static let sidebarDetail = Font.system(.caption, design: .default)
    static let tableHeader = Font.system(.caption, design: .default).weight(.semibold)

    /// The user's code font (`MacScopeCodeFont`, a `LumenCodeFont`), read fresh from
    /// `UserDefaults` so a Settings change takes effect on the next render. Defaults match the
    /// previous faces (the system monospaced font at 12 pt; bytes one point smaller).
    private static var codeFont: LumenCodeFont { MacScopeCodeFont.current() }
    static var address: Font { codeFont.font() }
    static var bytes: Font { codeFont.font(sizeDelta: -1) }
    static var mnemonic: Font { codeFont.font(weight: .semibold) }
    static var pseudocode: Font { codeFont.font() }
    static var pseudocodeAppKit: NSFont { codeFont.nsFont() }
    static let lineNumber = Font.system(.caption, design: .monospaced)
    static let metadata = Font.caption
    static let toolbarStatus = Font.caption
    static let toolbarMetric = Font.caption.monospacedDigit()
    static let settingsIdentifier = Font.system(.caption, design: .monospaced)
}

/// Closed semantic styling for structured native-decompiler pseudocode tokens.
///
/// The native document supplies token kinds and scalar ranges. This projection never lexes the
/// rendered text, and whitespace intentionally carries no foreground style so the enclosing text
/// view's adaptive label color remains authoritative.
struct AppNativePseudocodeTokenStyle {
    enum Role: String, CaseIterable, Hashable, Sendable {
        case comment
        case identifier
        case keyword
        case literal
        case operation
        case punctuation
        case type
        case whitespace
    }

    let role: Role
    let font: Font
    let appKitFont: NSFont
    let foregroundColor: NSColor?

    static func project(
        _ kind: NativeDecompilerWireTokenKind,
        contrast: ColorSchemeContrast,
        themeStore: DSThemeStore = .active
    ) -> Self {
        let role: Role
        switch kind {
        case .comment: role = .comment
        case .identifier: role = .identifier
        case .keyword: role = .keyword
        case .literal: role = .literal
        case .operation: role = .operation
        case .punctuation: role = .punctuation
        case .type: role = .type
        case .whitespace: role = .whitespace
        }
        return Self(
            role: role,
            font: AppTypography.pseudocode,
            appKitFont: AppTypography.pseudocodeAppKit,
            foregroundColor: foregroundColor(for: role, contrast: contrast, themeStore: themeStore)
        )
    }

    /// Pseudocode colors come from the editor theme's syntax roles and resolve at draw time, so a
    /// theme switch or appearance change repaints with the new palette. An explicit `.increased`
    /// contrast request selects the theme's high-contrast variant even under a standard
    /// appearance.
    private static func foregroundColor(
        for role: Role,
        contrast: ColorSchemeContrast,
        themeStore: DSThemeStore
    ) -> NSColor? {
        let token: LumenToken
        switch role {
        case .whitespace: return nil
        case .comment: token = .syntaxComment
        case .identifier: token = .syntaxVariable
        case .keyword: token = .syntaxKeyword
        case .literal: token = .syntaxNumber
        case .operation: token = .syntaxOperator
        case .punctuation: token = .syntaxPunctuation
        case .type: token = .syntaxType
        }
        let forcesHighContrast = contrast == .increased
        return NSColor(name: nil) { appearance in
            var resolved = LumenAppearance(appearance)
            if forcesHighContrast { resolved.isHighContrast = true }
            return themeStore.editorTheme.nsColor(token, for: resolved)
        }
    }
}

extension Color {
    /// A light/dark adaptive color resolved by the active appearance — for crisp, brand-tuned
    /// surfaces that don't rely on the muddy system materials.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        }))
    }
}

/// Semantic syntax colors for the disassembly listing — the "gentle pops of color" that turn the
/// monochrome wall into a legible, Nova-like editor. Mnemonics are tinted by CATEGORY (control flow,
/// memory, arithmetic, general); operands are TOKENIZED so registers, immediates, addresses, and
/// labels each carry meaning through hue. Every color is adaptive so it reads on both the dark slate
/// editor and the light surface.
enum SyntaxPalette {
    static var controlFlow: Color { Color.lumen(.syntaxMnemonicBranch) }
    static var arithmetic: Color { Color.lumen(.syntaxMnemonicArithmetic) }
    static var memory: Color { Color.lumen(.syntaxMnemonicMemory) }
    static var general: Color { Color.lumen(.syntaxMnemonicGeneral) }

    static var register: Color { Color.lumen(.syntaxRegister) }
    static var immediate: Color { Color.lumen(.syntaxImmediate) }
    static var address: Color { Color.lumen(.syntaxAddress) }
    static var label: Color { address }
    static var modifier: Color { Color.lumen(.syntaxModifier) }

    private static let controlFlowMnemonics: Set<String> = [
        "b", "bl", "br", "blr", "ret", "retaa", "retab", "retaasppc", "retabsppc", "retaasppcr", "retabsppcr", "braa", "brab", "blraa", "blrab",
        "cbz", "cbnz", "tbz", "tbnz", "svc", "brk", "hlt",
        "jmp", "je", "jne", "jz", "jnz", "jg", "jge", "jl", "jle", "ja", "jae", "jb", "jbe",
        "jo", "jno", "js", "jns", "jc", "jnc", "jp", "jnp", "call", "callq", "retq", "leave",
        "loop", "loopne", "loope", "syscall", "int", "int3", "iret"]
    private static let memoryMnemonics: Set<String> = [
        "ldr", "ldrb", "ldrh", "ldrsb", "ldrsh", "ldrsw", "ldp", "ldpsw", "ldur", "ldursw",
        "str", "strb", "strh", "stp", "stur", "ldar", "ldarb", "ldarh", "stlr", "stlrb", "stlrh",
        "ldxr", "stxr", "ldaxr", "stlxr", "adr", "adrp", "prfm",
        "lea", "leaq", "push", "pushq", "pop", "popq"]
    private static let arithmeticMnemonics: Set<String> = [
        "add", "adds", "sub", "subs", "mul", "madd", "msub", "mneg", "smull", "umull", "smaddl",
        "umaddl", "sdiv", "udiv", "and", "ands", "orr", "orn", "eor", "eon", "bic", "bics",
        "lsl", "lsr", "asr", "ror", "neg", "negs", "cmp", "cmn", "tst", "adc", "sbc", "clz",
        "rbit", "rev", "rev16", "sxtw", "sxtb", "sxth", "uxtw", "uxtb", "uxth", "asrv", "lslv",
        "imul", "idiv", "inc", "dec", "xor", "sal", "sar", "shl", "shr", "test", "not", "or",
        "addq", "subq", "andq", "orq", "xorq", "cmpq", "incq", "decq", "sete", "setne"]
    private static let shiftExtendKeywords: Set<String> = [
        "lsl", "lsr", "asr", "ror", "uxtw", "uxtb", "uxth", "uxtx", "sxtw", "sxtb", "sxth", "sxtx", "msl"]
    private static let x86Registers: Set<String> = [
        "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "rip",
        "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp",
        "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
        "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d",
        "al", "bl", "cl", "dl", "ax", "bx", "cx", "dx", "sil", "dil", "bpl", "spl"]

    /// Category tint for a mnemonic (lowercased, prefix-aware for `b.<cond>` and short `j<cc>`).
    static func mnemonicColor(for mnemonic: String) -> Color {
        let m = mnemonic.lowercased()
        if controlFlowMnemonics.contains(m) || m.hasPrefix("b.") || (m.hasPrefix("j") && m.count >= 2 && m.count <= 4) { return controlFlow }
        if memoryMnemonics.contains(m) { return memory }
        if arithmeticMnemonics.contains(m) { return arithmetic }
        return general
    }

    static func isRegister(_ word: String) -> Bool {
        let base = String(word.lowercased().split(separator: ".").first ?? "")
        if ["sp", "lr", "pc", "fp", "wsp", "wzr", "xzr"].contains(base) { return true }
        if let first = base.first, "xwvdsqbh".contains(first) {
            let rest = base.dropFirst()
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return true }
        }
        return x86Registers.contains(base)
    }

    /// Tokenizes an operand string into a colored `AttributedString`: registers (amber), immediates
    /// (cyan), addresses (violet), labels/symbols (violet), shift keywords (muted), punctuation
    /// (secondary). A data row keeps the fallback color (its directive isn't an instruction operand).
    static func highlightedOperands(_ operands: String, isData: Bool, fallback: Color) -> AttributedString {
        highlightedOperands(operands, isData: isData, fallback: fallback, palette: DS.palette)
    }

    /// Category tint for a mnemonic, read from an already-resolved palette (for dense rows that
    /// hold `@Environment(\.dsPalette)`).
    static func mnemonicColor(for mnemonic: String, in palette: LumenResolvedPalette) -> Color {
        let m = mnemonic.lowercased()
        if controlFlowMnemonics.contains(m) || m.hasPrefix("b.") || (m.hasPrefix("j") && m.count >= 2 && m.count <= 4) { return palette[.syntaxMnemonicBranch] }
        if memoryMnemonics.contains(m) { return palette[.syntaxMnemonicMemory] }
        if arithmeticMnemonics.contains(m) { return palette[.syntaxMnemonicArithmetic] }
        return palette[.syntaxMnemonicGeneral]
    }

    /// Operand tokenizer reading every color from one palette snapshot: six dictionary reads per
    /// row instead of a locked store lookup per token.
    static func highlightedOperands(_ operands: String, isData: Bool, fallback: Color, palette: LumenResolvedPalette) -> AttributedString {
        let register = palette[.syntaxRegister]
        let label = palette[.syntaxAddress]
        let address = palette[.syntaxAddress]
        let modifier = palette[.syntaxModifier]
        let immediate = palette[.syntaxImmediate]
        let punctuationColor = palette[.syntaxPunctuation]
        if isData {
            var attributed = AttributedString(operands)
            attributed.foregroundColor = fallback
            return attributed
        }
        var result = AttributedString()
        func emit(_ string: String, _ color: Color) {
            var run = AttributedString(string)
            run.foregroundColor = color
            result.append(run)
        }
        let chars = Array(operands)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$" || chars[j] == "." {
                    j += 1
                }
                let word = String(chars[i..<j])
                let color: Color = isRegister(word) ? register
                    : (shiftExtendKeywords.contains(word.lowercased()) ? modifier : label)
                emit(word, color)
                i = j
            } else if c == "#" {
                var j = i + 1
                if j < chars.count, chars[j] == "-" { j += 1 }
                if j + 1 < chars.count, chars[j] == "0", chars[j + 1] == "x" || chars[j + 1] == "X" {
                    j += 2
                    while j < chars.count, chars[j].isHexDigit { j += 1 }
                } else {
                    while j < chars.count, chars[j].isNumber { j += 1 }
                }
                emit(String(chars[i..<j]), immediate)
                i = j
            } else if c == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
                var j = i + 2
                while j < chars.count, chars[j].isHexDigit { j += 1 }
                emit(String(chars[i..<j]), address)
                i = j
            } else if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = c == "-" ? i + 1 : i
                while j < chars.count, chars[j].isNumber { j += 1 }
                emit(String(chars[i..<j]), immediate)
                i = j
            } else {
                emit(String(c), c.isWhitespace ? fallback : punctuationColor)
                i += 1
            }
        }
        return result
    }

    private static var punctuationColor: Color { Color.lumen(.syntaxPunctuation) }
}

private struct AppPaneBackgroundLayer: View {
    let role: AppPaneRole
    let reduceTransparency: Bool

    var body: some View {
        role.baseFill

        if role.usesMaterial && !reduceTransparency {
            Rectangle()
                .fill(.bar)
        }
    }
}

struct WorkbenchFocusRing: ViewModifier {
    let isVisible: Bool
    var radius: CGFloat = Lumen.Radius.xs
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        content
            .overlay {
                if isVisible {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(
                            Color.lumen(.borderFocus),
                            lineWidth: AppFocusChrome.ringWidth(for: colorSchemeContrast)
                        )
                }
            }
    }
}

struct AdaptiveWorkbenchSurface: ViewModifier {
    /// `nil` (the default) draws an opaque surface on the theme's elevated color, so cards take
    /// the theme's tint; system materials are neutral gray and wash it out.
    var material: Material?
    var radius: CGFloat = Lumen.Radius.md
    var fill: Color = Color.lumen(.bgElevated)
    var stroke: Color = Color.lumen(.borderSubtle)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content
            .background {
                if material == nil {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.lumen(.bgElevated))
                }
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)

                if let material, !reduceTransparency {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(material)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(stroke, lineWidth: AppContrastChrome.hairlineWidth(for: colorSchemeContrast))
            }
    }
}

struct CompactControlBackground: ViewModifier {
    var isProminent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content
            .background(
                compactFill,
                in: RoundedRectangle(cornerRadius: Lumen.Radius.xs, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Lumen.Radius.xs, style: .continuous)
                    .stroke(
                        Color.lumen(.borderSubtle),
                        lineWidth: AppContrastChrome.hairlineWidth(for: colorSchemeContrast)
                    )
            }
    }

    private var compactFill: Color {
        if reduceTransparency {
            // Opaque themed fills: no blending with a system gray that would tint Midnight's navy.
            return Color.lumen(isProminent ? .bgInsetRaised : .bgElevated)
        }
        return isProminent ? Color.lumen(.bgInsetRaised) : Color.lumen(.bgElevated)
    }
}

struct WorkbenchPaneBackground: ViewModifier {
    let role: AppPaneRole
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                AppPaneBackgroundLayer(role: role, reduceTransparency: reduceTransparency)
            }
    }
}

struct SidebarSingleLineText: ViewModifier {
    let lineLimit: Int
    var fillsAvailableWidth = true
    var allowsWrapping = false

    var effectiveLineLimit: Int? { allowsWrapping ? nil : lineLimit }
    var truncationMode: Text.TruncationMode { .tail }

    @ViewBuilder
    func body(content: Content) -> some View {
        let styledContent = content
            .lineLimit(effectiveLineLimit)
            .truncationMode(truncationMode)
            .allowsTightening(!allowsWrapping)
            .fixedSize(horizontal: false, vertical: allowsWrapping)

        if fillsAvailableWidth {
            styledContent
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            styledContent
        }
    }
}

extension View {
    func compactControlBackground(isProminent: Bool = false) -> some View {
        modifier(CompactControlBackground(isProminent: isProminent))
    }

    func sidebarSingleLineText(
        lineLimit: Int = AppSidebarChrome.rowTitleLineLimit,
        fillsAvailableWidth: Bool = true,
        allowsWrapping: Bool = false
    ) -> some View {
        modifier(SidebarSingleLineText(
            lineLimit: lineLimit,
            fillsAvailableWidth: fillsAvailableWidth,
            allowsWrapping: allowsWrapping
        ))
    }

    func workbenchSurface(
        _ material: Material? = nil,
        radius: CGFloat = Lumen.Radius.md,
        fill: Color = Color.lumen(.bgElevated),
        stroke: Color = Color.lumen(.borderSubtle)
    ) -> some View {
        modifier(AdaptiveWorkbenchSurface(material: material, radius: radius, fill: fill, stroke: stroke))
    }

    func workbenchFocusRing(isVisible: Bool, radius: CGFloat = Lumen.Radius.xs) -> some View {
        modifier(WorkbenchFocusRing(isVisible: isVisible, radius: radius))
    }

    func workbenchPaneBackground(_ role: AppPaneRole) -> some View {
        modifier(WorkbenchPaneBackground(role: role))
    }
}

struct InspectorSection<Content: View>: View {
    let id: DSInspectorSectionID
    let title: String
    let systemImage: String?
    private let expansionOverride: Binding<Bool>?
    private let content: Content
    @SceneStorage private var sceneExpanded: Bool

    init(
        id: DSInspectorSectionID,
        title: String,
        systemImage: String? = nil,
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        expansionOverride = isExpanded
        self.content = content()
        // SceneStorage outlives conditional section mounting and inspector hide/show,
        // while a second workspace window keeps its own expansion choices.
        _sceneExpanded = SceneStorage(
            wrappedValue: DSInspectorExpansionPolicy.defaultExpanded,
            id.sceneStorageKey
        )
    }

    var body: some View {
        DSInspectorSection(
            id: id,
            title: title,
            systemImage: systemImage,
            isExpanded: DSInspectorExpansionPolicy.binding(
                restored: $sceneExpanded,
                override: expansionOverride
            )
        ) {
            content
        }
    }
}

struct WorkbenchPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Lumen.Space.s6)
            .workbenchSurface(.regularMaterial, radius: Lumen.Radius.lg)
    }
}

/// A notice across the top of the editor: Lumen's banner (0.8.0) in the warning tone, spoken
/// "Issue: …" as before.
struct IssueBanner: View {
    let message: String

    var body: some View {
        LumenBanner(message, tone: .warning, spokenPrefix: "Issue")
            .padding(.horizontal, Lumen.Space.s6)
            .padding(.vertical, Lumen.Space.s4)
    }
}

/// A pane that's working: Lumen's loading state (0.8.0), a spinner, what it's doing and, for an
/// interruptible operation, Cancel (Escape too).
struct LoadingStateView: View {
    let title: String
    let detail: String
    /// Optional cancel affordance for an interruptible operation (e.g. a large import). When
    /// supplied, a Cancel button appears below the copy; `.cancelAction` also binds the Escape key,
    /// so the button and the Esc accelerator are one affordance. Omitted for uncancellable loads.
    var cancel: CancelAction? = nil
    /// HOP-3: 0...1 for a determinate bar, nil for indeterminate.
    var progress: Double? = nil

    struct CancelAction {
        var title: String = "Cancel"
        let handler: () -> Void
    }

    var body: some View {
        LumenLoadingState(title, message: detail, progress: progress, cancelTitle: cancel?.title ?? "Cancel",
                          onCancel: cancel?.handler)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(AppStateChrome.outerPadding)
    }
}

struct EmptyStateView: View {
    let title: String
    let detail: String
    let systemImage: String

    /// Calm, Nova-style: the panel's own symbol in the tertiary text color and one sentence,
    /// directly on the pane. Working panels stay quiet; only the welcome screen uses the accent tile.
    var body: some View {
        VStack(spacing: Lumen.Space.s4) {
            DSSymbol(systemImage)
                .font(.system(size: 32, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.lumen(.fgTertiary))
                .accessibilityHidden(true)

            VStack(spacing: Lumen.Space.s2) {
                Text(title)
                    .font(Lumen.Font.headline)
                    .foregroundStyle(.lumen(.fgPrimary))
                    .lineLimit(AppStateChrome.titleLineLimit)

                Text(detail)
                    .font(Lumen.Font.callout)
                    .foregroundStyle(.lumen(.fgSecondary))
                    .multilineTextAlignment(.center)
                    .lineLimit(AppStateChrome.detailLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: AppStateChrome.copyMaxWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AppStateChrome.outerPadding)
        .accessibilityElement(children: .combine)
    }
}

/// A pane that couldn't do its job: Lumen's error state (0.8.0), what failed, why and what to try.
struct ErrorStateView: View {
    let title: String
    let detail: String
    var recovery: String?

    var body: some View {
        LumenErrorState(title, message: detail, recovery: recovery)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(AppStateChrome.outerPadding)
    }
}

/// View-layer mapping of the pure `ColorTag` model to concrete colors for the
/// listing row tint, sidebar swatch, and graph node accent.
extension ColorTag {
    /// The accent color for this tag (sidebar dot, graph node accent, swatches).
    var color: Color {
        switch self {
        case .red: Color(nsColor: .systemRed)
        case .orange: Color(nsColor: .systemOrange)
        case .yellow: Color(nsColor: .systemYellow)
        case .green: Color(nsColor: .systemGreen)
        case .blue: Color(nsColor: .systemBlue)
        case .purple: Color(nsColor: .systemPurple)
        case .gray: Color(nsColor: .systemGray)
        }
    }

    /// Low-opacity fill used to tint a whole disassembly row by its color.
    var listingRowFill: Color { color.opacity(0.18) }
}
