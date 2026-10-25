import AppKit
import SwiftUI
import LumenTokens

// Settings, the Mac way: a separate window (⌘,), tabbed categories for a few panes or a sidebar
// with search for many, native grouped forms and native controls, and every change applied at once
// (no Save button). Lumen's part is the visual language: colored category tiles, pane headers, and
// panel colors from the theme.

/// A settings pane: a header (tile, title, one-sentence summary) above a native grouped form.
public struct LumenSettingsPane<Content: View>: View {
    private let title: String
    private let summary: String?
    private let systemImage: String
    private let hue: LumenToken
    private let content: Content

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    private let style: LumenSettingsPaneStyle

    public init(_ title: String, systemImage: String, hue: LumenToken, summary: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, systemImage: systemImage, hue: hue, summary: summary, style: .grouped, content: content)
    }

    /// - Parameter style: `.rich` for `LumenSettingsRow`s in `LumenFormSection`s under the header
    ///  , `.grouped` for a native grouped form.
    public init(_ title: String, systemImage: String, hue: LumenToken, summary: String? = nil,
                style: LumenSettingsPaneStyle, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.hue = hue
        self.style = style
        self.content = content()
    }

    public var body: some View {
        switch style {
        case .grouped: grouped
        case .rich: rich
        }
    }

    private var rich: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.spacing.s5) {
                LumenSettingsHeader(title, systemImage: systemImage, hue: hue, summary: summary)
                content
            }
            .padding(metrics.spacing.s6)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette[.panelBackground])
    }

    private var grouped: some View {
        Form {
            Section {
                content
            } header: {
                LumenSettingsHeader(title, systemImage: systemImage, hue: hue, summary: summary)
                    .padding(.bottom, metrics.spacing.s3)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(palette[.panelBackground])
    }
}

/// How a `LumenSettingsPane` lays out its settings.
public enum LumenSettingsPaneStyle: Sendable, CaseIterable {
    /// A native grouped form, as System Settings draws one.
    case grouped
    /// Rows with a one-line explanation under each name and the control at the trailing edge, in
    /// titled sections.
    case rich
}

/// One setting in a rich pane: its name, a one-line explanation under
/// it, and the control at the trailing edge (a native `Toggle`, a pop-up `Picker`, or a
/// `LumenModeSwitcher(style: .pill)` for two to four choices). When the pane is narrow, the control
/// moves under the text rather than clipping.
public struct LumenSettingsRow<Control: View>: View {
    private let title: String
    private let description: String?
    private let control: Control
    private var badge: (systemImage: String, help: String)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenSettingsQuery) private var query

    public init(_ title: String, description: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.description = description
        self.control = control()
    }

    /// - Parameter badge: a small glyph after the title saying where the value comes from, with its
    ///   help ("checkmark.seal", "Set by .editorconfig").
    public init(_ title: String, description: String? = nil, badge: (systemImage: String, help: String),
                @ViewBuilder control: () -> Control) {
        self.init(title, description: description, control: control)
        self.badge = badge
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: metrics.spacing.s4) {
                text
                Spacer(minLength: metrics.spacing.s3)
                control.labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: metrics.spacing.s2) {
                text
                control.labelsHidden()
            }
        }
        .padding(.vertical, metrics.spacing.s1)
        // The match band reaches out past the row, so the title keeps the column's leading edge.
        .background {
            RoundedRectangle(cornerRadius: metrics.radius.sm).fill(matchesSearch ? palette[.accentSubtle] : .clear)
                .padding(.horizontal, -metrics.spacing.s2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityHint(description ?? "")
    }

    private var matchesSearch: Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return !needle.isEmpty && title.localizedCaseInsensitiveContains(needle)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s1) {
            HStack(spacing: metrics.spacing.s2) {
                // Inside the match band the letters are marked by emphasis, not a second accent tint
                // (the marker's own tint vanished into the band).
                LumenHighlightedText(title, matching: matchesSearch ? query.trimmingCharacters(in: .whitespaces) : "", style: .emphasis)
                    .font(metrics.typography.body.weight(.medium)).foregroundStyle(palette[.fgPrimary])
                if let badge {
                    LumenSymbol(badge.systemImage).font(.system(size: metrics.iconSize.small, weight: .semibold)).foregroundStyle(palette[.accent])
                        .help(badge.help)
                        .accessibilityLabel(badge.help)
                }
            }
            if let description {
                Text(description).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                    .lumenWrapsWithoutTruncating()
            }
        }
    }
}

/// The header at the top of a settings pane, also usable on its own.
public struct LumenSettingsHeader: View {
    private let title: String
    private let summary: String?
    private let systemImage: String
    private let hue: LumenToken

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String, systemImage: String, hue: LumenToken, summary: String? = nil) {
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.hue = hue
    }

    public var body: some View {
        HStack(alignment: .top, spacing: metrics.spacing.s5) {
            LumenIconTile(systemImage, hue: hue, size: metrics.layout.tilePaneHeader)
            VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                Text(title).font(metrics.typography.title3).foregroundStyle(palette[.fgPrimary])
                if let summary {
                    Text(summary).font(metrics.typography.callout).foregroundStyle(palette[.fgSecondary])
                        .lumenWrapsWithoutTruncating()
                }
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

public extension View {
    /// Makes this view a tab of a Settings `TabView` with a colored category tile, as in System
    /// Settings' old preference panes. Use it inside `Settings { TabView { … } }`.
    func lumenSettingsTab(_ title: String, systemImage: String, hue: LumenToken) -> some View {
        modifier(LumenSettingsTabModifier(title: title, systemImage: systemImage, hue: hue))
    }
}

private struct LumenSettingsTabModifier: ViewModifier {
    let title: String
    let systemImage: String
    let hue: LumenToken
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tabItem {
            Label {
                Text(title)
            } icon: {
                if let image = LumenIconTile.image(systemImage, hue: hue, size: 22, colorScheme: colorScheme) {
                    Image(nsImage: image)
                } else {
                    LumenSymbol(systemImage)
                }
            }
        }
    }
}

// MARK: Sidebar layout

/// One category in a sidebar-style settings window.
public struct LumenSettingsCategory: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let hue: LumenToken
    /// Extra words the search field matches, such as the names of the settings inside.
    public let keywords: [String]
    /// The names of the settings in the pane, as their rows title them. A search lists the ones that
    /// match under the category, and the pane marks those rows.
    public var settings: [String] = []
    public let content: () -> AnyView

    public init<Content: View>(id: String, title: String, systemImage: String, hue: LumenToken, keywords: [String] = [],
                               @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        self.keywords = keywords
        self.content = { AnyView(content()) }
    }

    public init<Content: View>(id: String, title: String, systemImage: String, hue: LumenToken, keywords: [String] = [],
                               settings: [String], @ViewBuilder content: @escaping () -> Content) {
        self.init(id: id, title: title, systemImage: systemImage, hue: hue, keywords: keywords, content: content)
        self.settings = settings
    }

    /// Whether `query` matches the title, a keyword or a setting (case-insensitive; empty matches all).
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || ([title] + keywords + settings).contains { $0.lowercased().contains(needle) }
    }

    /// The settings whose names contain `query`, in order.
    public func matchingSettings(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return settings.filter { $0.lowercased().contains(needle) }
    }
}

extension EnvironmentValues {
    /// The Settings search, so rows whose titles match can mark themselves.
    @Entry var lumenSettingsQuery = ""
}

/// System Settings' shape for apps with many categories: a searchable sidebar of tiled categories
/// and the selected pane beside it.
public struct LumenSettingsSidebarView: View {
    private let categories: [LumenSettingsCategory]
    @State private var selection: String?
    @State private var query = ""

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// The sidebar column's minimum width.
    public static let sidebarMinWidth: CGFloat = 200
    /// The selected pane's minimum width, so a narrow window never squeezes its rows into
    /// truncated values ("W…", live LIVE-05). The settings window's minimum is the two summed.
    public static let detailMinWidth: CGFloat = 360

    public init(_ categories: [LumenSettingsCategory], selection: String? = nil) {
        self.categories = categories
        _selection = State(initialValue: selection ?? categories.first?.id)
    }

    public var body: some View {
        let shown = categories.filter { $0.matches(query) }
        NavigationSplitView {
            List(shown, selection: $selection) { category in
                Label {
                    VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                        Text(category.title).font(metrics.typography.body)
                        let found = category.matchingSettings(query)
                        if !found.isEmpty {
                            // Each matching setting under its pane, so the result says what matched.
                            Text(found.joined(separator: " · ")).font(metrics.typography.caption)
                                .foregroundStyle(palette[.sidebarSecondaryForeground]).lineLimit(2)
                                .help(found.joined(separator: " · "))
                        }
                    }
                } icon: {
                    LumenIconTile(category.systemImage, hue: category.hue, size: metrics.layout.tileRow)
                }
                .tag(category.id)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .onChange(of: query) { _, text in
                // Keep a matching pane showing as the search narrows.
                let matching = categories.filter { $0.matches(text) }
                if !matching.contains(where: { $0.id == selection }) { selection = matching.first?.id }
            }
            .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: 220, max: 280)
        } detail: {
            // Within the filtered list: a search that hides the selected pane shows the empty state.
            Group {
                if let category = shown.first(where: { $0.id == selection }) {
                    category.content()
                        .environment(\.lumenSettingsQuery, query)
                        .navigationTitle(category.title)
                } else {
                    LumenEmptyState(systemImage: "magnifyingglass", title: "No matching settings",
                                    message: "Try a different word, or clear the search.", actionTitle: "Clear search") { query = "" }
                }
            }
            .navigationSplitViewColumnWidth(min: Self.detailMinWidth, ideal: Self.detailMinWidth + 120)
        }
    }
}

/// A ready-made Appearance pane: row density, the system accent switch and the theme gallery,
/// each applied at once and saved through `store` (density and accent persist only in a store that
/// persists its selection). Pair it with `.lumenDensityRoot(store:)` on the app's windows.
public struct LumenAppearanceSettings: View {
    private let store: LumenThemeStore
    private let showsGallery: Bool
    @AppStorage private var densityRaw: String

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter showsGallery: `false` for apps that show the gallery in a pane of its own.
    public init(store: LumenThemeStore = .active, showsGallery: Bool = true) {
        self.store = store
        self.showsGallery = showsGallery
        _densityRaw = AppStorage(wrappedValue: LumenDensity.regular.rawValue, store.configuration.densityDefaultsKey,
                                 store: store.configuration.defaults)
    }

    public var body: some View {
        Form {
            Section {
                // Lumen's own controls in Lumen's own settings: the pill switcher and the themed checkbox.
                LabeledContent("Density") {
                    LumenModeSwitcher(selection: $densityRaw, options: LumenDensity.allCases.map(\.rawValue), style: .pill,
                                      title: { LumenDensity(rawValue: $0)?.label ?? $0 })
                        .lumenModeSwitcherPlacement(.content)
                }
                .disabled(!store.persistsSelection)
                Toggle("Use the system accent color", isOn: Binding(get: { store.usesSystemAccent }, set: { store.setUsesSystemAccent($0) }))
                    .toggleStyle(.lumenCheckbox)
            } header: {
                LumenSettingsHeader("Appearance", systemImage: "paintpalette.fill", hue: .hueViolet,
                                    summary: "Theme, accent and how tightly rows are packed.")
                    .padding(.bottom, metrics.spacing.s3)
            }
            if showsGallery {
                Section("Theme") { LumenThemeGallery(store: store) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(palette[.panelBackground])
    }
}
