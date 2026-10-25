import AppKit
import SwiftUI
import LumenTokens

// Rows in source lists and content lists, the way macOS draws them: a selection that goes quiet in
// an inactive window, a hover fill, a focus ring, and dimmed disabled rows, all from the theme. One
// place decides these, so every app's rows agree.

/// What a row is showing, in the order macOS resolves it.
public enum LumenRowState: Hashable, Sendable {
    case disabled, selected, selectedInactive, focused, hovered, normal

    /// The state for a row from its flags: disabled wins, then selection (quiet in an inactive
    /// window), then keyboard focus, then hover.
    public static func resolve(isSelected: Bool, isFocused: Bool = false, isHovered: Bool = false,
                               isEnabled: Bool = true, isActiveWindow: Bool = true) -> LumenRowState {
        guard isEnabled else { return .disabled }
        if isSelected { return isActiveWindow ? .selected : .selectedInactive }
        if isFocused { return .focused }
        return isHovered ? .hovered : .normal
    }

    public var isSelected: Bool { self == .selected || self == .selectedInactive }
}

/// Where a row lives: a sidebar or source list (the sidebar's roles) or a content list on the canvas.
public enum LumenRowContext: Hashable, Sendable {
    case sidebar, content
}

/// The row colors for a state and context, from a palette.
public struct LumenRowColors {
    public let fill: Color
    public let primary: Color
    public let secondary: Color

    /// How strongly a selected row's detail line shows its title's color: the title's quieter self.
    public static let selectedSecondaryOpacity: Double = 0.76

    public init(_ state: LumenRowState, context: LumenRowContext, palette: LumenResolvedPalette) {
        let sidebar = context == .sidebar
        switch state {
        case .selected:
            fill = palette[sidebar ? .sidebarRowSelected : .bgSelected]
        case .selectedInactive:
            fill = palette[sidebar ? .sidebarRowSelectedInactive : .bgSelectedInactive]
        case .hovered:
            fill = palette[sidebar ? .sidebarRowHover : .bgHover]
        case .focused, .disabled, .normal:
            // Keyboard focus is the ring alone (a ring on a gray fill read as two states at once).
            fill = .clear
        }
        let primaryToken: LumenToken = sidebar ? .sidebarForeground : .fgPrimary
        let secondaryToken: LumenToken = sidebar ? .sidebarSecondaryForeground : .fgSecondary
        switch state {
        case .disabled:
            primary = palette[.fgDisabled]
            secondary = palette[.fgDisabled]
        case .selected:
            // On the active selection the detail line reads as the title's quieter self (76%), as
            // macOS source lists do; inactive selections fall back to the plain secondary color.
            primary = palette[primaryToken]
            secondary = palette[primaryToken].opacity(Self.selectedSecondaryOpacity)
        default:
            primary = palette[primaryToken]
            secondary = palette[secondaryToken]
        }
    }
}

public extension View {
    /// A row's fill for `state`: the selection, quiet when the window is inactive; the hover fill;
    /// a focus ring for keyboard focus. Read the matching text colors from `LumenRowColors`.
    func lumenRowBackground(_ state: LumenRowState, context: LumenRowContext = .content) -> some View {
        modifier(LumenRowBackground(state: state, context: context))
    }
}

private struct LumenRowBackground: ViewModifier {
    let state: LumenRowState
    let context: LumenRowContext
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
        content
            .background(LumenRowColors(state, context: context, palette: palette).fill, in: shape)
            .overlay { shape.strokeBorder(palette[.borderFocus], lineWidth: metrics.stroke.focus).opacity(state == .focused ? 1 : 0) }
    }
}

/// A list row: an icon (a tile when it has a hue), a title, an optional detail, and an optional
/// trailing count or badge, at the density's height. It tracks hover and the window's active state
/// itself; the list owns selection.
public struct LumenListRow<Trailing: View>: View {
    private let title: String
    private let detail: String?
    private let systemImage: String?
    private let hue: LumenToken?
    private let isSelected: Bool
    private let isFocused: Bool
    private let context: LumenRowContext
    private let monospaced: Bool
    private let trailing: Trailing

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @Environment(\.lumenForcedHover) private var forcedHover   // hover states in tests

    /// - Parameters:
    ///   - monospaced: the title in the code font (symbols, addresses).
    ///   - trailing: a count, badge or keycap at the trailing edge.
    public init(_ title: String, detail: String? = nil, systemImage: String? = nil, hue: LumenToken? = nil,
                isSelected: Bool = false, isFocused: Bool = false, context: LumenRowContext = .content,
                monospaced: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.hue = hue
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.context = context
        self.monospaced = monospaced
        self.trailing = trailing()
    }

    public var body: some View {
        let state = LumenRowState.resolve(isSelected: isSelected, isFocused: isFocused, isHovered: isHovered || forcedHover,
                                          isEnabled: isEnabled, isActiveWindow: activeState != .inactive)
        let colors = LumenRowColors(state, context: context, palette: palette)
        HStack(spacing: metrics.spacing.s3) {
            if let systemImage {
                if let hue {
                    LumenIconTile(systemImage, hue: hue, size: detail == nil ? metrics.layout.tileMenu : metrics.layout.tileRowDetailed)
                } else {
                    LumenSymbol(systemImage)
                        .foregroundStyle(palette[context == .sidebar ? .sidebarAccent : .accent].opacity(isEnabled ? 1 : metrics.layout.disabledOpacity))
                        .frame(width: 18)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(monospaced ? (codeFont?.font() ?? metrics.typography.monoSmall) : metrics.typography.body)
                    .foregroundStyle(colors.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    // A monospaced row's detail is code too (an address), so its digits align row to row.
                    Text(detail)
                        .font(monospaced ? (codeFont?.font(sizeDelta: -1) ?? metrics.typography.monoCaption) : metrics.typography.caption)
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: metrics.spacing.s2)
            trailing.foregroundStyle(colors.secondary)
        }
        .padding(.horizontal, metrics.spacing.s3)
        .frame(minHeight: detail == nil ? density.rowHeight(in: metrics.layout) : density.detailedRowHeight(in: metrics.layout))
        .lumenRowBackground(state, context: context)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

public extension LumenListRow where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, systemImage: String? = nil, hue: LumenToken? = nil,
         isSelected: Bool = false, isFocused: Bool = false, context: LumenRowContext = .content, monospaced: Bool = false) {
        self.init(title, detail: detail, systemImage: systemImage, hue: hue, isSelected: isSelected, isFocused: isFocused,
                  context: context, monospaced: monospaced) { EmptyView() }
    }
}

/// A count at a row's trailing edge, in a quiet capsule.
public struct LumenCount: View {
    private let value: Int
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ value: Int) { self.value = value }

    public var body: some View {
        Text(value, format: .number)
            .font(metrics.typography.caption.monospacedDigit())
            .padding(.horizontal, metrics.spacing.s2)
            .padding(.vertical, 1)
            .background(palette[.bgInset], in: .capsule)
    }
}

// MARK: Code font

/// The font for code, addresses and other monospaced text, which people often choose for themselves
/// (SF Mono 12 by default). Store it as a string (`"Menlo:13"`, `"system:12"`) with `@AppStorage` and
/// provide it with `.lumenCodeFont(_:)`; Lumen's monospaced text (list rows, the log console,
/// property values) follows it.
public struct LumenCodeFont: Hashable, Sendable, RawRepresentable {
    /// A font family name, or `nil` for the system's monospaced font (SF Mono).
    public var family: String?
    public var size: CGFloat

    public static let sizeRange: ClosedRange<CGFloat> = 9...24
    public static let standard = LumenCodeFont(family: nil, size: 12)

    public init(family: String? = nil, size: CGFloat = 12) {
        self.family = family
        self.size = min(max(size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
    }

    /// `"<family>:<size>"`, with `system` for the system font.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let size = Double(parts[1]) else { return nil }
        self.init(family: parts[0] == "system" ? nil : String(parts[0]), size: CGFloat(size))
    }

    public var rawValue: String { "\(family ?? "system"):\(Int(size))" }

    /// The SwiftUI font, `sizeDelta` points larger or smaller (bytes one point smaller, say).
    public func font(sizeDelta: CGFloat = 0, weight: Font.Weight = .regular) -> Font {
        let size = min(max(size + sizeDelta, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        if let family { return .custom(family, fixedSize: size).weight(weight) }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    /// The AppKit font, for text views; the system monospaced font when the family is missing.
    public func nsFont(sizeDelta: CGFloat = 0, weight: NSFont.Weight = .regular) -> NSFont {
        let size = min(max(size + sizeDelta, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        if let family, let font = NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Installed fixed-pitch font families, for a picker.
    @MainActor
    public static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch == true
                || NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
        }
    }
}

extension EnvironmentValues {
    /// The person's code font, when the app provides one (`.lumenCodeFont(_:)`); `nil` uses the
    /// metrics' monospaced fonts.
    @Entry public var lumenCodeFont: LumenCodeFont? = nil
}

public extension View {
    /// Provides the person's code font to Lumen's monospaced text in this subtree.
    func lumenCodeFont(_ font: LumenCodeFont?) -> some View {
        environment(\.lumenCodeFont, font)
    }
}

/// A Settings control for the code font: family (the system font first) and size.
public struct LumenCodeFontPicker: View {
    @Binding private var selection: LumenCodeFont
    @State private var families: [String] = []

    public init(selection: Binding<LumenCodeFont>) {
        _selection = selection
    }

    public var body: some View {
        LabeledContent("Code font") {
            HStack(spacing: 8) {
                // Lumen's pop-up and number field, so the font row matches the rest of a settings pane.
                LumenMenuButton {
                    familyItem(nil, "System (SF Mono)")
                    Divider()
                    ForEach(families, id: \.self) { familyItem($0, $0) }
                } label: { LumenPopUpLabel(selection.family ?? "System (SF Mono)") }
                .accessibilityLabel("Family")
                .accessibilityValue(selection.family ?? "System (SF Mono)")
                LumenNumberField(value: Binding(get: { Double(selection.size) }, set: { selection.size = CGFloat($0) }),
                                 in: Double(LumenCodeFont.sizeRange.lowerBound)...Double(LumenCodeFont.sizeRange.upperBound),
                                 unit: "pt", width: 40)
            }
        }
        .task { families = LumenCodeFont.monospacedFamilies }
    }

    private func familyItem(_ family: String?, _ title: String) -> some View {
        Button { selection.family = family } label: {
            if selection.family == family { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

// MARK: Source list

/// One item in a source list.
public struct LumenSourceListItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let systemImage: String?
    public let hue: LumenToken?
    public let count: Int?

    /// - Parameter hue: draws the icon as a tile in this hue; `nil` draws it in `sidebar.accent`.
    public init(id: String, title: String, detail: String? = nil, systemImage: String? = nil, hue: LumenToken? = nil, count: Int? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.hue = hue
        self.count = count
    }
}

/// A titled group of source list items; an empty title draws no header.
public struct LumenSourceListSection: Identifiable, Sendable {
    public let title: String
    public let items: [LumenSourceListItem]
    public var id: String { title.isEmpty ? "untitled" : title }

    public init(_ title: String = "", items: [LumenSourceListItem]) {
        self.title = title
        self.items = items
    }
}

/// A sidebar source list drawn in the theme, as MacScope's is: the selection in `sidebar.rowSelected`
/// (quiet in an inactive window) rather than the system's blue highlight, hover fills, density-driven
/// rows. It's one keyboard stop: ↑/↓ move the selection, Home and End jump to the ends.
public struct LumenSourceList: View {
    private let sections: [LumenSourceListSection]
    @Binding private var selection: String?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @FocusState private var focused: Bool

    public init(sections: [LumenSourceListSection], selection: Binding<String?>) {
        self.sections = sections
        _selection = selection
    }

    public init(_ items: [LumenSourceListItem], selection: Binding<String?>) {
        self.init(sections: [LumenSourceListSection(items: items)], selection: selection)
    }

    private var ids: [String] { sections.flatMap { $0.items.map(\.id) } }

    public var body: some View {
        // As in LumenInspector: under a toolbar, the scroll view would inset its content by the
        // toolbar's height a second time. Extend it under the toolbar and pad by the measured inset.
        GeometryReader { geometry in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        if !section.title.isEmpty {
                            Text(section.title)
                                .lumenSectionLabel(.sidebarSecondaryForeground)
                                .padding(.horizontal, metrics.spacing.s3)
                                .padding(.top, metrics.spacing.s4)
                                .padding(.bottom, metrics.spacing.s1)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.items) { item in
                            LumenListRow(item.title, detail: item.detail, systemImage: item.systemImage, hue: item.hue,
                                         isSelected: item.id == selection, isFocused: focused && item.id == selection, context: .sidebar) {
                                if let count = item.count { LumenCount(count) }
                            }
                            .id(item.id)
                            .onTapGesture { selection = item.id }
                            .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                // Fills its column and never pushes it: rows truncate their titles instead, so a
                // narrow column can't center the list and cut its leading edge. A list
                // that still can't fit (a long section label) reports itself.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.spacing.s2)
                .padding(.vertical, metrics.spacing.s2)
                .padding(.top, geometry.safeAreaInsets.top)
                .lumenColumnWidthWatch("Source list", columnWidth: geometry.size.width)
            }
            .frame(width: geometry.size.width)
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
        }
        }
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.home) { selection = ids.first; return .handled }
        .onKeyPress(.end) { selection = ids.last; return .handled }
        .lumenSidebarBackground()
        .accessibilityElement(children: .contain)
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        selection = LumenSelectionStep.next(ids, from: selection, by: offset)
        return .handled
    }
}
