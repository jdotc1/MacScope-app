import AppKit
import LumenUI
import SwiftUI
import LumenTokens

struct SidebarView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                SidebarHeader(store: store)

                Divider()

                SidebarNavigatorList(store: store)
            }
            // NavigationSplitView can propose a column narrower than a child's ideal width while
            // it is being resized. Bind the sidebar content to that actual proposal so SwiftUI
            // cannot center an oversized subtree and clip its leading edge outside the window.
            .frame(
                width: max(0, proxy.size.width),
                height: max(0, proxy.size.height),
                alignment: .topLeading
            )
            .clipped()
        }
        .workbenchPaneBackground(.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppAccessibilityText.sidebarNavigatorLabel(tool: store.selectedTool))
        .accessibilityIdentifier("workspace.pane.sidebar")
    }
}

private struct SidebarNavigatorList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reduce Motion: navigation and layout changes happen at once.
    private var motion: Animation? { Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: reduceMotion) }

    @ObservedObject var store: WorkspaceStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSidebarChrome.listRowSpacing) {
                    ForEach(sidebarSections) { section in
                        if section.title.isEmpty {
                            sidebarRows(section.items)
                        } else {
                            // Lumen count section: tiled title and count, or one quiet
                            // line while it's empty. Rows stay siblings so long lists stay lazy.
                            SidebarSectionHeader(section: section, searchText: store.sidebarSearchText)
                                .padding(.top, AppSidebarChrome.sectionTopPadding)
                            if !section.items.isEmpty {
                                sidebarRows(section.items)
                            }
                        }
                    }
                }
                .padding(.leading, AppSidebarChrome.contentLeadingPadding)
                .padding(.trailing, AppSidebarChrome.contentTrailingPadding)
                .padding(.vertical, Lumen.Space.s5)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
            .animation(motion, value: store.visibleSidebarItems)
            .onChange(of: store.selectedSidebarItemID) { _, itemID in
                guard let itemID else { return }
                withAnimation(motion) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
            .onChange(of: store.visibleSidebarItems) { _, _ in
                store.selectDefaultSidebarItemIfNeeded()
            }
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    withAnimation(motion) {
                        store.selectAdjacentSidebarItem(.previous)
                    }
                case .down:
                    withAnimation(motion) {
                        store.selectAdjacentSidebarItem(.next)
                    }
                default:
                    break
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AppAccessibilityText.sourceListLabel(tool: store.selectedTool))
            .accessibilityValue(selectedItemAccessibilityValue)
        }
    }

    private var selectedItemAccessibilityValue: String {
        guard let selectedID = store.selectedSidebarItemID,
              let item = store.selectableVisibleSidebarItems.first(where: { $0.id == selectedID }) else {
            return "No selection"
        }

        return AppSidebarChrome.accessibilityValue(for: item)
    }

    private var sidebarSections: [SidebarSectionModel] {
        var sections: [SidebarSectionModel] = []
        var currentHeader: SidebarItem?
        var currentItems: [SidebarItem] = []

        func close() {
            guard !currentItems.isEmpty || currentHeader != nil else { return }
            sections.append(SidebarSectionModel(
                headerID: currentHeader?.id,
                title: currentHeader?.title ?? "",
                detail: currentHeader?.detail,
                systemImage: currentHeader?.systemImage ?? "",
                items: currentItems
            ))
        }

        for item in store.visibleSidebarItems {
            if item.isSectionHeader {
                close()
                currentHeader = item
                currentItems = []
            } else {
                currentItems.append(item)
            }
        }
        close()

        if sections.isEmpty {
            return [SidebarSectionModel(headerID: nil, title: "", detail: nil, systemImage: "", items: [])]
        }

        return sections
    }

    @ViewBuilder
    private func sidebarRows(_ items: [SidebarItem]) -> some View {
        if items.isEmpty {
            let tool = store.selectedTool
            SidebarEmptyRow(
                searchText: store.sidebarSearchText,
                onClearRules: store.navigatorFilterRules[tool]?.isActive == true
                    ? { store.navigatorFilterRules[tool] = nil } : nil
            )
        } else {
            ForEach(items) { item in
                let navigationTarget = store.sidebarNavigationTarget(for: item.id)
                SidebarItemButton(
                    item: item,
                    isSelected: store.selectedSidebarItemID == item.id,
                    keyboardFocusRequestID: store.sidebarKeyboardFocusRequestID,
                    acknowledgeKeyboardFocusRequest: {
                        store.acknowledgeSidebarKeyboardFocusRequest(for: $0)
                    }
                ) {
                    withAnimation(motion) {
                        if let navigationTarget {
                            store.activateSidebarItem(navigationTarget)
                        }
                    }
                }
                    .id(item.id)
                    .contextMenu {
                        Button("Copy Name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.title, forType: .string)
                        }

                        if TypeAtlasNavigator.kind(forItemID: item.id) == .userType {
                            Button("Edit Type…") { store.editTypeAtlasItem(item.id) }
                        }

                        if let detail = item.detail {
                            Button("Copy Detail") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(detail, forType: .string)
                            }
                        }
                    }
            }
        }
    }
}

private struct SidebarHeader: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            LumenSidebarHeader(store.selectedTool.rawValue, subtitle: subtitle, systemImage: store.selectedTool.systemImage, hue: store.selectedTool.toolHue)
            .help(subtitle)

            SidebarToolStrip(store: store)

            SidebarSearchField(store: store)

            SidebarSummaryStrip(store: store)
        }
        .padding(.leading, AppSidebarChrome.contentLeadingPadding)
        .padding(.trailing, Lumen.Space.s6)
        .padding(.top, AppSidebarChrome.headerTopPadding)
        .padding(.bottom, AppSidebarChrome.headerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        switch store.selectedTool {
        case .project:
            return store.workspaceName
        case .symbols:
            return "Imports, exports, and defined symbols"
        case .strings:
            return "C-string and literal pool"
        case .xrefs:
            return "Cross-reference browser"
        case .debug:
            return "Launch, breakpoints, frames"
        case .extensions:
            return "Plugin and automation surfaces"
        case .reconstruction:
            return "Bounded jobs from committed corpus evidence"
        case .types:
            return "Classes, structs, protocols and your types"
        }
    }
}

private struct SidebarSearchField: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        HStack(spacing: Lumen.Space.s4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)

            TextField("Filter \(store.selectedTool.rawValue.lowercased())", text: $store.sidebarSearchText)
                .textFieldStyle(.plain)
                .font(.caption)

            if !store.sidebarSearchText.isEmpty {
                Button {
                    store.sidebarSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }

            if NavigatorFilterField.supports(store.selectedTool) {
                SidebarRuleFilterButton(store: store, tool: store.selectedTool)
            }
        }
        .padding(.horizontal, Lumen.Space.s4)
        .frame(height: AppSidebarChrome.searchFieldHeight)
        .compactControlBackground()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter \(store.selectedTool.rawValue.lowercased())")
    }
}

/// U8-3: the Symbols and Strings rule filter: a glyph at the search field's trailing edge (filled
/// while rules filter) that opens `LumenRuleEditor` in a popover.
private struct SidebarRuleFilterButton: View {
    @ObservedObject var store: WorkspaceStore
    let tool: WorkspaceTool
    @State private var isPresented = false

    var body: some View {
        let count = store.navigatorFilterRules[tool]?.effectiveConditions.count ?? 0
        let summary = count == 1 ? "1 rule" : "\(count) rules"
        Button { isPresented.toggle() } label: {
            HStack(spacing: Lumen.Space.s1) {
                Image(systemName: count > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                // The count keeps an active filter visible when the list just looks short.
                if count > 0 {
                    Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(count > 0 ? Color.lumen(.accent) : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(count > 0 ? "\(summary) filter this list" : "Filter by rules")
        .accessibilityLabel("Filter rules")
        .accessibilityValue(count > 0 ? summary : "Off")
        .accessibilityIdentifier("sidebar.filterRules")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SidebarRuleFilterEditor(store: store, tool: tool)
        }
    }
}

struct SidebarRuleFilterEditor: View {
    /// LumenRuleEditor's natural width plus padding (Lumen: about 520 pt).
    static let width: CGFloat = 520

    @ObservedObject var store: WorkspaceStore
    let tool: WorkspaceTool

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            LumenRuleEditor(match: rules.match, conditions: rules.conditions,
                            fields: NavigatorFilterField.fields(for: tool),
                            comparisons: NavigatorFilterField.comparisons(for:))
            HStack {
                Spacer()
                Button("Clear Rules") { store.navigatorFilterRules[tool] = nil }
                    .controlSize(.small)
                    .disabled(store.navigatorFilterRules[tool] == nil)
                    .accessibilityIdentifier("sidebar.filterRules.clear")
            }
        }
        .padding(Lumen.Space.s6)
        .frame(width: Self.width)
        .accessibilityIdentifier("sidebar.filterRules.editor")
    }

    private var rules: Binding<NavigatorFilterRules> {
        Binding(
            get: { store.navigatorFilterRules[tool] ?? NavigatorFilterRules(tool: tool) },
            set: { store.navigatorFilterRules[tool] = $0 }
        )
    }
}

private struct SidebarSummaryStrip: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        // Lumen stats card: values large, labels small, equal columns.
        LumenStatsCard(summaries.map { LumenStat($0.label.capitalized, count: $0.count) })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            summaries.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
        )
    }

    private struct Summary {
        let count: Int
        let label: String
    }

    private var summaries: [Summary] {
        if store.selectedTool == .reconstruction {
            let jobCount = store.reconstructionState.jobs.count
            let occurrenceCount = ReconstructionJobCreationItem.committedItems(
                in: store.reconstructionState
            ).count
            let checkpointCount = store.reconstructionState.checkpoints.count
            return [
                Summary(count: jobCount, label: Self.pluralized(jobCount, "job", "jobs")),
                Summary(
                    count: occurrenceCount,
                    label: Self.pluralized(occurrenceCount, "artifact", "artifacts")
                ),
                Summary(
                    count: checkpointCount,
                    label: Self.pluralized(checkpointCount, "checkpoint", "checkpoints")
                ),
            ]
        }

        if store.selectedTool == .types {
            let entries = store.typeAtlasCatalog.entries
            let methodCount = entries.reduce(0) { $0 + $1.methods.count }
            let userCount = entries.reduce(0) { $0 + $1.users.count }
            return [
                Summary(count: entries.count, label: Self.pluralized(entries.count, "type", "types")),
                Summary(count: methodCount, label: Self.pluralized(methodCount, "method", "methods")),
                Summary(count: userCount, label: Self.pluralized(userCount, "user", "users")),
            ]
        }

        let binaryCount = store.snapshot.binaries.count
        let functionCount = store.focusedAnalysis?.functions.count ?? 0
        let xrefCount = store.focusedAnalysis?.xrefs.count ?? 0
        return [
            Summary(count: binaryCount, label: Self.pluralized(binaryCount, "target", "targets")),
            Summary(
                count: functionCount,
                label: Self.pluralized(functionCount, "function", "functions")
            ),
            Summary(count: xrefCount, label: Self.pluralized(xrefCount, "xref", "xrefs")),
        ]
    }

    private static func pluralized(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? singular : plural
    }
}

private struct SidebarToolStrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reduce Motion: navigation and layout changes happen at once.
    private var motion: Animation? { Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: reduceMotion) }

    @ObservedObject var store: WorkspaceStore
    /// Nova-style customizable tabs: order and hidden tools, per user. Lumen's tool layout reads
    /// and writes the same string, so saved arrangements carry over.
    @AppStorage("navigatorToolLayout") private var layoutRaw = ""

    var body: some View {
        // Lumen sidebar switcher, tiles style.
        LumenSidebarSwitcher(selection: selection, items: WorkspaceTool.allCases.map { tool in
                LumenSidebarItem(
                    id: tool.rawValue,
                    title: tool.rawValue,
                    systemImage: tool.systemImage,
                    hue: tool.toolHue,
                    accessibilityIdentifier: tool.accessibilityIdentifier
                )
            }, shortcuts: false, arrangement: $layoutRaw, style: .tiles)
        .accessibilityLabel("Navigator tools")
    }

    private var selection: Binding<String> {
        Binding(
            get: { store.selectedTool.rawValue },
            set: { raw in
                guard let tool = WorkspaceTool(rawValue: raw) else { return }
                withAnimation(motion) {
                    store.selectedTool = tool
                    store.sidebarSearchText = ""
                    store.selectDefaultSidebarItemIfNeeded()
                }
            }
        )
    }
}

private struct SidebarSectionModel: Identifiable {
    var id: String { headerID ?? "root" }
    let headerID: String?
    let title: String
    let detail: String?
    let systemImage: String
    let items: [SidebarItem]
}

/// A navigator section's header as a Lumen count section: the section's glyph in a tile, its title
/// and the number of rows shown, or one quiet line saying what will appear there.
private struct SidebarSectionHeader: View {
    let section: SidebarSectionModel
    let searchText: String

    var body: some View {
        LumenSidebarCountSection(section.title, systemImage: section.systemImage, hue: hue, count: section.items.count, emptyMessage: emptyMessage) { EmptyView() }
        .padding(.horizontal, AppSidebarChrome.rowHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(section.detail ?? section.title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(AppSidebarChrome.accessibilityLabel(title: section.title, detail: section.detail))
    }

    private var hue: LumenToken {
        switch section.headerID {
        case "section:binaries": .hueIndigo
        case "section:functions": .hueBlue
        case "section:imports": .hueTeal
        case "section:exports": .hueGreen
        case "section:symbols": .hueYellow
        case "section:reconstruction-jobs": .hueViolet
        case let id? where TypeAtlasNavigator.kind(forItemID: id) != nil: .kindType
        default: .accent
        }
    }

    private var emptyMessage: String {
        if !searchText.isEmpty { return "No matching items." }
        switch section.headerID {
        case "section:binaries": return "Open a binary to list it here."
        case "section:functions": return "Functions appear here after analysis."
        case "section:imports": return "Nothing imported."
        case "section:exports": return "Nothing exported."
        case "section:symbols": return "No defined symbols."
        case let id? where TypeAtlasNavigator.kind(forItemID: id) != nil: return "No types of this kind."
        default: return "Nothing here yet."
        }
    }
}

/// A compact pill rendering a user tag at the trailing edge of a sidebar row.
private struct SidebarTagChip: View {
    let text: String
    let isSelected: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, Lumen.Space.s4)
            .padding(.vertical, Lumen.Space.s1)
            // On a selected row the chip sits on the elevated surface with primary text: white on
            // the soft selection tint was 1.29:1 in Scope Light.
            .background(Capsule().fill(isSelected ? Color.lumen(.bgElevated) : Color.lumen(.accentSubtle)))
            .foregroundStyle(isSelected ? Color.lumen(.fgPrimary) : Color.lumen(.accent))
            .frame(maxWidth: AppSidebarChrome.tagChipMaxWidth)
            .accessibilityHidden(true)
    }
}

private struct SidebarItemButton: View {
    let item: SidebarItem
    let isSelected: Bool
    let keyboardFocusRequestID: SidebarItem.ID?
    let acknowledgeKeyboardFocusRequest: (SidebarItem.ID) -> Void
    let action: () -> Void
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.dsDensity) private var density

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: AppSidebarChrome.rowContentSpacing) {
                if let kind = rowKind {
                    // Nova-style kind badge: one glyph and one color per object kind.
                    DSKindBadge(kind: kind, size: AppSidebarChrome.rowIconWidth)
                        .frame(width: AppSidebarChrome.rowIconWidth)
                } else {
                    DSSymbol(item.systemImage)
                        .font(.system(size: AppSidebarChrome.rowIconSize, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(iconForeground)
                        .frame(width: AppSidebarChrome.rowIconWidth)
                }

                VStack(alignment: .leading, spacing: AppSidebarChrome.rowTextVerticalSpacing) {
                    Text(item.title)
                        .font(AppTypography.sidebarTitle)
                        .foregroundStyle(titleForeground)
                        .sidebarSingleLineText(
                            lineLimit: AppSidebarChrome.rowTitleLineLimit,
                            allowsWrapping: TypeAtlasNavigator.kind(forItemID: item.id) == .importedType
                        )
                        .help(item.title)

                    if let detail = item.detail {
                        Text(detail)
                            .font(AppTypography.sidebarDetail)
                            .foregroundStyle(detailForeground)
                            .sidebarSingleLineText(
                                lineLimit: AppSidebarChrome.rowDetailLineLimit,
                                allowsWrapping: TypeAtlasNavigator.kind(forItemID: item.id) == .importedType
                            )
                            .help(detail)
                    }
                }
                .frame(minWidth: AppSidebarChrome.minimumReadableTextColumnWidth, alignment: .leading)
                .layoutPriority(1)

                if item.tag != nil || item.colorTag != nil {
                    Spacer(minLength: Lumen.Space.s4)
                    if let tag = item.tag, !tag.isEmpty {
                        SidebarTagChip(text: tag, isSelected: isSelected)
                    }
                    if let colorTag = item.colorTag {
                        Circle()
                            .fill(colorTag.color)
                            .frame(width: AppSidebarChrome.rowIconSize * 0.6, height: AppSidebarChrome.rowIconSize * 0.6)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, AppSidebarChrome.rowHorizontalPadding)
            .padding(.vertical, density.sidebarVerticalPadding(detailed: item.detail != nil))
            .frame(
                maxWidth: .infinity,
                minHeight: item.detail == nil ? density.sidebarRowHeight : density.sidebarDetailedRowHeight,
                alignment: .leading
            )
            .background(rowBackground)
            .workbenchFocusRing(isVisible: isFocused, radius: AppSidebarChrome.focusCornerRadius)
            .contentShape(RoundedRectangle(cornerRadius: AppSidebarChrome.focusCornerRadius))
        }
        .buttonStyle(.plain)
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled() // violet workbenchFocusRing is the sole focus affordance (no system blue)
        .onAppear { acceptKeyboardFocusRequest(keyboardFocusRequestID) }
        .onChange(of: keyboardFocusRequestID) { _, requestID in
            acceptKeyboardFocusRequest(requestID)
        }
        .onHover { isHovering = $0 }
        .animation(Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: reduceMotion), value: isHovering)
        .animation(Lumen.Motion.animation(Lumen.Motion.fastCurve, reduceMotion: reduceMotion), value: isSelected)
        .accessibilityIdentifier(item.id)
        .accessibilityLabel(AppSidebarChrome.accessibilityLabel(for: item))
        .accessibilityHint(AppSidebarChrome.accessibilityHint(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The row's kind badge: by id prefix, with an Xrefs row's glyph naming its reference kind
    /// (a class reference wears the class badge) and Type Atlas rows badged by their type kind.
    private var rowKind: DSObjectKind? {
        if let kind = DSObjectKind.forSidebarItemID(item.id) {
            return kind == .xref ? XRefKindPresentation.badgeKind(forRowSymbol: item.systemImage) : kind
        }
        return TypeAtlasNavigator.kind(forItemID: item.id)?.objectKind
    }

    private func acceptKeyboardFocusRequest(_ requestID: SidebarItem.ID?) {
        guard requestID == item.id, isSelected else { return }
        isFocused = true
        acknowledgeKeyboardFocusRequest(item.id)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if interactionState != .normal && interactionState != .disabled {
            RoundedRectangle(cornerRadius: Lumen.Radius.xs)
                .fill(AppInteractionChrome.sourceListRowFill(for: interactionState))
        }
    }

    private var interactionState: AppInteractionState {
        AppInteractionChrome.sourceListState(
            isSelected: isSelected,
            isFocused: isFocused,
            isHovering: isHovering,
            isActiveWindow: isActiveWindow
        )
    }

    private var isActiveWindow: Bool {
        controlActiveState != .inactive
    }

    private var iconForeground: Color {
        if isSelected {
            return AppInteractionChrome.selectedSecondaryForeground(isActiveWindow: isActiveWindow, opacity: 0.9)
        }
        return isSelected ? .primary : .secondary
    }

    private var titleForeground: Color {
        if isSelected {
            return AppInteractionChrome.selectedPrimaryForeground(isActiveWindow: isActiveWindow)
        }
        return .primary
    }

    private var detailForeground: Color {
        if isSelected {
            return AppInteractionChrome.selectedSecondaryForeground(isActiveWindow: isActiveWindow, opacity: 0.76)
        }
        return .secondary
    }
}

private extension WorkspaceTool {
    /// Each tool's tile color in the tool rail and the sidebar header.
    var toolHue: LumenToken {
        switch self {
        case .project: .huePink
        case .symbols: .hueYellow
        case .strings: .hueOrange
        case .xrefs: .hueTeal
        case .debug: .hueRed
        case .extensions: .hueGreen
        case .reconstruction: .hueViolet
        case .types: .hueBlue
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .reconstruction:
            "reconstruction.navigation"
        case .types:
            "typeAtlas.navigation"
        default:
            "workspace.tool."
                + rawValue
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-")
        }
    }
}

private struct SidebarEmptyRow: View {
    let searchText: String
    /// U8-3: present while rule filters are on, so rules that hide everything never strand the user.
    var onClearRules: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s3) {
            Label {
                Text(onClearRules != nil ? "No items match the rules" : searchText.isEmpty ? "No items" : "No matching items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
            }
            if let onClearRules {
                Button("Clear Rules", action: onClearRules)
                    .controlSize(.small)
                    .accessibilityIdentifier("sidebar.filterRules.emptyClear")
            }
        }
        .padding(.vertical, Lumen.Space.s4)
    }
}
