import AppKit
import LumenTokens
import SwiftUI

// Generic building blocks. Colors come from `@Environment(\.lumenPalette)` and sizes, type and
// corners from `@Environment(\.lumenMetrics)`, so each one follows the app's theme and metrics
// and any surface it sits in.

// MARK: Badge

/// The one chip spec (badges, pills, tags and every in-component chip): caption text in a 6 pt
/// continuous rounded rect, `s3` across and `s1` above and below, about 17 pt tall. Components
/// set their own font (captionEmphasized, or the code caption) and ink.
struct LumenChipBackground: ViewModifier {
    let fill: Color
    var edge: Color? = nil
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
        content
            .padding(.horizontal, metrics.spacing.s3)
            .padding(.vertical, metrics.spacing.s1)
            .background(fill, in: shape)
            .overlay { if let edge { shape.strokeBorder(edge, lineWidth: metrics.stroke.hairline) } }
    }
}

extension View {
    /// The one chip shape and padding (`LumenChipBackground`).
    func lumenChip(_ fill: Color, edge: Color? = nil) -> some View {
        modifier(LumenChipBackground(fill: fill, edge: edge))
    }
}

/// One badge for counts, states and metadata. Tone is meaning, not decoration. Tone text sits on
/// its own contrast-verified `status.*Background`; the accent tone uses the link color, the accent's
/// text-safe ink, on the accent tint, so it reads as an accent rather than a darker neutral.
/// Badges, tags and pills share one height and sentence case.
public struct LumenBadge: View {
    public enum Tone: Sendable, CaseIterable {
        case neutral, accent, success, warning, danger, info

        public var textToken: LumenToken {
            switch self {
            case .neutral: .statusNeutral
            case .accent: .fgLink
            case .success: .statusSuccess
            case .warning: .statusWarning
            case .danger: .statusDanger
            case .info: .statusInfo
            }
        }

        public var glyphToken: LumenToken { self == .accent ? .accent : textToken }

        public var backgroundToken: LumenToken {
            switch self {
            case .neutral: .statusNeutralBackground
            case .accent: .accentSubtle
            case .success: .statusSuccessBackground
            case .warning: .statusWarningBackground
            case .danger: .statusDangerBackground
            case .info: .statusInfoBackground
            }
        }
    }

    let text: String
    var systemImage: String?
    var tone: Tone
    var monospaced: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ text: String, systemImage: String? = nil, tone: Tone = .neutral, monospaced: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
        self.monospaced = monospaced
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            if let systemImage {
                LumenSymbol(systemImage)
                    .imageScale(.small)
                    .foregroundStyle(palette[tone.glyphToken])
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(monospaced ? metrics.typography.monoCaption : metrics.typography.captionEmphasized)
                .foregroundStyle(palette[tone.textToken])
                .lineLimit(1)
                .lumenNeverTruncates(text)
        }
        .fixedSize(horizontal: true, vertical: false)
        .lumenChip(palette[tone.backgroundToken])
        .accessibilityElement(children: .combine)
    }
}

// MARK: Pill

/// A label/value pill for metadata and metrics, on the neutral inset surface (fg.secondary on
/// bg.inset is verified >= 4.5:1). `.metadata` reads "label value" with a monospaced, selectable
/// value (identifiers, versions); `.metric` reads "value label" with the value emphasized (counts).
public struct LumenPill: View {
    public enum Style: Sendable { case metadata, metric }

    let label: String
    let value: String
    var systemImage: String?
    var style: Style
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(label: String, value: String, systemImage: String? = nil, style: Style = .metadata) {
        self.label = label
        self.value = value
        self.systemImage = systemImage
        self.style = style
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            if let systemImage {
                LumenSymbol(systemImage)
                    .font(metrics.typography.caption)
                    .foregroundStyle(palette[style == .metric ? .fgPrimary : .fgSecondary])
                    .accessibilityHidden(true)
            }
            switch style {
            case .metadata:
                Text(label)
                    .font(metrics.typography.captionEmphasized)
                    .foregroundStyle(palette[.fgSecondary])
                    .fixedSize()
                    .layoutPriority(1)
                // A long value (a hash, a path) gives way in the middle and shows in full as help;
                // the label never does.
                Text(value)
                    .font(metrics.typography.monoCaption)
                    .foregroundStyle(palette[.fgPrimary])
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(value)
            case .metric:
                Text(value)
                    .font(metrics.typography.captionEmphasized.monospacedDigit())
                    .foregroundStyle(palette[.fgPrimary])
                Text(label)
                    .font(metrics.typography.caption)
                    .foregroundStyle(palette[.fgSecondary])
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: style == .metric, vertical: false)
        .lumenChip(palette[.bgInset])
        // Own the spoken label: selectable text would otherwise have VoiceOver synthesize one
        // through its AppKit backing element, which can recurse.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style == .metric ? "\(value) \(label)" : "\(label) \(value)")
    }
}

// MARK: Tag

/// A text tag for a kind or category, in sentence case and the badges' shape and height: a dot in
/// the category's color beside primary text on the
/// neutral status fill (a chip, a step off every surface, so it reads as one in dark themes where
/// the inset well sits right beside the inspector's own background). Colored text on a wash of its
/// own color fails the contrast rules, so the color rides on the dot and the words stay readable in
/// every theme.
public struct LumenTag: View {
    let text: String
    let dotToken: LumenToken?
    let dotColor: Color?
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// A tag whose dot takes a themed token.
    public init(_ text: String, token: LumenToken) {
        self.text = text
        dotToken = token
        dotColor = nil
    }

    /// A tag whose dot takes any color (for example a user-chosen label color).
    public init(_ text: String, color: Color) {
        self.text = text
        dotToken = nil
        dotColor = color
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            Circle()
                .fill(dotColor ?? dotToken.map { palette[$0] } ?? palette[.fgTertiary])
                .frame(width: metrics.layout.statusDot, height: metrics.layout.statusDot)
                .accessibilityHidden(true)
            Text(text)
                .font(metrics.typography.captionEmphasized)
                .foregroundStyle(palette[.fgPrimary])
                .lineLimit(1)
                .lumenNeverTruncates(text)
        }
        .fixedSize(horizontal: true, vertical: false)
        .lumenChip(palette[.statusNeutralBackground])
    }
}

// MARK: Section label

extension View {
    /// The one section-label style: group labels in sidebars, inspectors, forms and menus,
    /// and table column headers. Uppercase `typography.sectionLabel` at `sectionLabelTracking`, in
    /// the surface's quiet ink (`fg.tertiary`; `sidebar.secondaryForeground` or
    /// `menu.secondaryForeground` on those surfaces).
    func lumenSectionLabel(_ ink: LumenToken = .fgTertiary) -> some View {
        modifier(LumenSectionLabelStyle(ink: ink))
    }
}

private struct LumenSectionLabelStyle: ViewModifier {
    let ink: LumenToken
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        content
            .font(metrics.typography.sectionLabel)
            .tracking(metrics.typography.sectionLabelTracking)
            .textCase(.uppercase)
            .foregroundStyle(palette[ink])
            .lineLimit(1)
    }
}

// MARK: Inspector building blocks

/// The one section-header style for sidebars and inspectors: the section label (uppercase, small,
/// tracked, tertiary), shared with table column headers.
public struct LumenSectionHeader<Accessory: View>: View {
    let title: String
    let accessory: Accessory
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(title: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s3) {
            Text(title)
                .lumenSectionLabel()
                .lumenNeverTruncates(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory
        }
        .frame(minHeight: metrics.layout.rowHeightCompact)
    }
}

extension LumenSectionHeader where Accessory == EmptyView {
    public init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A label and a value. The label column has a pinned width (the layout's
/// `propertyLabelWidth`, 82 pt by default); values that are identifiers render monospaced and
/// offer Copy on hover.
public struct LumenPropertyRow: View {
    let label: String
    let value: String
    var monospaced: Bool
    var labelWidth: CGFloat?
    @State private var isHovered = false
    @FocusState private var copyFocused: Bool
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter labelWidth: the label column; `nil` uses the metrics' `propertyLabelWidth`.
    public init(label: String, value: String, monospaced: Bool = true, labelWidth: CGFloat? = nil) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.labelWidth = labelWidth
    }

    /// A value is read, so it wraps (at dots and slashes for code) to as many lines as a real
    /// value takes in an inspector column; two cut "chevron.left.forwardslash.chevron.right" (LIVE-07).
    static let valueLineLimit = 4

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s4) {
            Text(label)
                .font(metrics.typography.caption)
                .foregroundStyle(palette[.fgSecondary])
                .frame(width: labelWidth ?? metrics.layout.propertyLabelWidth, alignment: .leading)
            Group {
                if monospaced {
                    LumenCodeValue(value: value,
                                   font: codeFont?.font(sizeDelta: -1) ?? metrics.typography.monoCaption,
                                   nativeFont: codeFont != nil || metrics.typography.monoCaption == LumenMetrics.standard.typography.monoCaption
                                       ? (codeFont?.nsFont(sizeDelta: -1)
                                          ?? NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)) : nil,
                                   color: palette[.fgPrimary],
                                    kind: LumenSemanticTextPolicy.labelKind(for: value),
                                    lineLimit: Self.valueLineLimit)
                } else {
                    Text(value)
                        .font(metrics.typography.caption)
                        .foregroundStyle(palette[.fgPrimary])
                        .textSelection(.enabled)
                        .lineLimit(Self.valueLineLimit)
                        .truncationMode(.middle)
                }
            }
            .help(value)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Shown on hover, and while it has keyboard focus so a Tab stop is never invisible.
            Button(action: copy) {
                // The glyph in a 24 pt hit area (PRINCIPLES §7).
                Label("Copy \(label)", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
                    .contentShape(.rect)
            }
                .buttonStyle(.lumenPlain)
                .lumenIconOnlyControl("Copy")
                .foregroundStyle(palette[.fgTertiary])
                .focused($copyFocused)
                .lumenGroupFocusRing(copyFocused, cornerRadius: metrics.radius.sm)
                .help("Copy \(label)")
                .opacity(isHovered || copyFocused ? 1 : 0)
                .accessibilityHidden(!isHovered)
        }
        .frame(minHeight: metrics.layout.minimumHitTarget)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        // Own the spoken label: letting VoiceOver synthesize it through selectable Text's AppKit
        // backing element can recurse. Copy stays reachable as a named action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
        .accessibilityAction(named: "Copy \(label)", copy)
    }
}

// MARK: Empty state

/// Lumen's one empty state, at the prominence its place asks for (one design
/// in three tiers, never on a card):
/// - `.inline`: one quiet sentence and no glyph, for lists, tables, sidebar sections, stacked panes,
///   debugger sections, palettes and search results.
/// - `.pane`: the panel's own symbol in the tertiary text color, a centered title, a short body and at
///   most one next step, shown as a link; for inspectors, details and no-matches.
/// - The hero tier is `LumenEmptyHero`, the workspace-level "nothing open" state.
///
/// `LumenLoadingState` and `LumenErrorState` share the pane layout, so the three swap in place.
public struct LumenEmptyState: View {
    /// How loud an empty state is; see `LumenEmptyState`.
    public enum Prominence: Sendable, Hashable {
        /// One quiet sentence (the title), no glyph and no action: an initializer's `message`,
        /// `systemImage` and action are ignored. Centered; `LumenEmptyState.inline(_:ink:leading:padding:)`
        /// also draws it leading-aligned, as sidebar sections do.
        case inline
        /// Glyph, title, body and an optional link action, centered in the pane.
        case pane
    }

    let systemImage: String?
    let title: String
    let message: String?
    let prominence: Prominence
    var actionTitle: String?
    var action: (() -> Void)?
    /// Inline only: the surface's quiet ink, leading alignment (sidebar sections) and vertical padding.
    var inlineInk: LumenToken = .fgTertiary
    var inlineLeading = false
    var inlinePadding: CGFloat?
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenStatePlacement) private var placement

    /// A pane empty state (the original initializer).
    public init(systemImage: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(title, message: message, systemImage: systemImage, prominence: .pane, actionTitle: actionTitle, action: action)
    }

    /// With `.inline`, `message`, `systemImage`, `actionTitle` and `action` are ignored: an inline
    /// state is one sentence. `LumenEmptyState.inline(_:ink:leading:padding:)` takes only what an
    /// inline state draws.
    /// - Parameters:
    ///   - title: the sentence an `.inline` state shows, or a `.pane` state's title. Sentence case.
    ///   - message: a `.pane` state's body (`.inline` shows the title alone).
    ///   - systemImage: a `.pane` state's glyph (`.inline` has none).
    ///   - actionTitle, action: a `.pane` state's single next step, shown as a link.
    public init(_ title: String, message: String? = nil, systemImage: String? = nil, prominence: Prominence = .pane,
                actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.prominence = prominence
        self.actionTitle = actionTitle
        self.action = action
    }

    /// An inline empty sentence in a surface's own quiet ink, centered or leading-aligned, with
    /// `padding` above and below (default s4). Leading is the sidebar form: `LumenSidebarCountSection`
    /// draws its empty sentence this way, and a `LumenSidebarSection`'s content matches it with
    /// `leading: true` and the section's s4 inset (`.padding(.horizontal, metrics.spacing.s4)`).
    /// - Parameters:
    ///   - sentence: the one sentence, sentence case.
    ///   - ink: the surface's quiet text role (`.menuSecondaryForeground` on a palette or menu).
    public static func inline(_ sentence: String, ink: LumenToken = .fgTertiary, leading: Bool = false,
                       padding: CGFloat? = nil) -> LumenEmptyState {
        var state = LumenEmptyState(sentence, prominence: .inline)
        state.inlineInk = ink
        state.inlineLeading = leading
        state.inlinePadding = padding
        return state
    }

    public var body: some View {
        switch prominence {
        case .inline: inlineBody
        case .pane: paneBody
        }
    }

    /// The narrowest width an inline sentence is measured at (see `inlineBody`).
    public static let inlineMeasureWidth: CGFloat = 120

    private var inlineBody: some View {
        Text(title)
            .font(metrics.typography.callout)
            .foregroundStyle(palette[inlineInk])
            .multilineTextAlignment(inlineLeading ? .leading : .center)
            // Measured at least this wide: a split view sizing its columns asks for the height at a
            // near-zero width, and the sentence wrapped a few letters per line became a minimum taller
            // than the window (three sidebar sections held the Workspace window at 1325 pt, live check). Real columns are wider, so nothing changes where it's drawn.
            .lumenWrapsWithoutTruncating()
            .padding(.vertical, inlinePadding ?? metrics.spacing.s4)
            .frame(maxWidth: .infinity, alignment: inlineLeading ? .leading : .center)
    }

    private var paneBody: some View {
        LumenStatePaneLayout {
            if let systemImage {
                LumenSymbol(systemImage)
                    .font(.system(size: metrics.iconSize.hero, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(palette[.fgTertiary])
                    // A 32 pt slot whatever the symbol's own height, the slot the loading ring and the
                    // error mark fill, so the three states swap in place.
                    .frame(height: metrics.iconSize.hero)
                    .accessibilityHidden(true)
            }
            LumenStateText(title: title, message: message)
            if let actionTitle, let action {
                LumenStateLink(actionTitle, action: action)
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var lumenEmptyMessage: String?
}

public extension View {
    /// The sentence the data views inside show when they have nothing to list, in place of their own
    /// default: `LumenLogConsole`, `LumenCollection`, `LumenSearchResults`, `LumenProcessList`,
    /// `LumenStackFrameList` and `LumenWatchList` ("No processes match", "Not stopped").
    func lumenEmptyMessage(_ sentence: String?) -> some View {
        environment(\.lumenEmptyMessage, sentence)
    }
}

/// A pane state's single next step: a link in the link color, its 24 pt hit area overhanging the
/// text rather than adding to the stack's height, so it sits as close under the body as a plain
/// button would. Shared by the empty, loading and error states.
struct LumenStateLink: View {
    let title: String
    let role: ButtonRole?
    let action: () -> Void
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(title, role: role, action: action)
            .buttonStyle(EmptyStateLinkStyle()).lumenFocusRing()
            .font(metrics.typography.callout)
            .foregroundStyle(palette[.fgLink])
            .lumenLinkPointer()
            .fixedSize()
    }
}

extension View {
    /// The pointing-hand pointer on macOS 15 and later; nothing on macOS 14, which lacks
    /// `pointerStyle`.
    func lumenLinkPointer() -> some View {
        modifier(LumenLinkPointer())
    }
}

/// Borderless, like `.lumenPlain`, but the minimum hit area is a background that overhangs the
/// label, so it doesn't change layout.
struct EmptyStateLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HitArea(configuration: configuration)
    }

    private struct HitArea: View {
        let configuration: Configuration
        @Environment(\.lumenMetrics) private var metrics

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? metrics.layout.pressedOpacity : 1)
                .background {
                    Color.clear
                        .frame(minWidth: metrics.layout.minimumHitTarget, minHeight: metrics.layout.minimumHitTarget)
                        .contentShape(.rect)
                }
        }
    }
}

private struct LumenLinkPointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.link)
        } else {
            content
        }
    }
}

// MARK: Toolbar button

/// A toolbar icon button drawn entirely in SwiftUI: a rounded tile (the layout's
/// `toolbarButton`, 28 pt by default) that appears on hover and deepens on press. One size for
/// every toolbar button. Glyphs are regular weight in `toolbar.foreground` at 75% (full on hover)
/// unless the label sets its own style. Add
/// `.lumenFocusRing()` to the button so keyboard focus shows.
public struct LumenToolbarIconButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration)
    }

    // Hover state lives in a view, not the style, so each button tracks its own.
    private struct Tile: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.lumenAncestorOpacity) private var ancestorOpacity
        @State private var isHovered = false
        @Environment(\.lumenForcedHover) private var forcedHover   // hover states in tests

        var body: some View {
            // Regular weight in the toolbar's secondary ink (its foreground at the panel toggles' off
            // strength), full strength on hover: the group reads as quiet tools, not headings.
            configuration.label
                .font(.system(size: metrics.layout.toolbarGlyphSize, weight: .regular))
                .foregroundStyle(palette[.toolbarForeground].opacity((isHovered || forcedHover) && isEnabled ? 1 : 0.75))
                .frame(width: metrics.layout.toolbarButton, height: metrics.layout.toolbarButton)
                .lumenIconOnlyControl()   // PRINCIPLES §7: every toolbar icon button keeps its hit area
                .background {
                    // The top bar's shared plate (toolbar ink at 0.10 hover / 0.16 pressed), so these
                    // tiles match the panel toggles and New Tab on any title bar glow.
                    LumenToolbarHoverPlate(isHovered: isEnabled && (isHovered || forcedHover),
                                           isPressed: isEnabled && configuration.isPressed)
                }
                .lumenDisabledOpacity(isEnabled, target: metrics.layout.disabledOpacity, ancestor: ancestorOpacity)
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: Symbol badge

/// A glyph in a token's color on a soft tint of the same color: object kinds, file types,
/// categories. Reads in light and dark themes alike and pairs color with shape, never color alone.
public struct LumenSymbolBadge: View {
    /// The tile's tint strength. An app pack that checks its badge colors composites them over
    /// their grounds at this alpha (see `LumenFallback.composite`).
    public static let tintOpacity = 0.16

    let systemImage: String
    let token: LumenToken
    let label: String
    var size: CGFloat
    @Environment(\.lumenPalette) private var palette

    /// - Parameter label: what the badge means, for VoiceOver.
    public init(systemImage: String, token: LumenToken, label: String, size: CGFloat = 16) {
        self.systemImage = systemImage
        self.token = token
        self.label = label
        self.size = size
    }

    public var body: some View {
        LumenSymbol(systemImage)
            .font(.system(size: size * 0.62, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(palette[token])
            .frame(width: size, height: size)
            .background(palette[token].opacity(Self.tintOpacity), in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(label)
    }
}

// MARK: Previews

#Preview("Components") {
    VStack(alignment: .leading, spacing: Lumen.Space.s6) {
        HStack(spacing: Lumen.Space.s3) {
            LumenBadge("12 links", systemImage: "link", tone: .accent)
            LumenBadge("v2.1", monospaced: true)
            LumenBadge("Signed", systemImage: "checkmark.seal.fill", tone: .success)
            LumenBadge("3 warnings", tone: .warning)
        }
        HStack(spacing: Lumen.Space.s3) {
            LumenPill(label: "version", value: "2.1.0")
            LumenPill(label: "files", value: "1,284", systemImage: "doc", style: .metric)
            LumenTag("draft", token: .statusWarning)
            LumenSymbolBadge(systemImage: "doc.text", token: .accent, label: "Document")
        }
        VStack(alignment: .leading, spacing: Lumen.Space.s1) {
            LumenSectionHeader("Details")
            LumenPropertyRow(label: "Path", value: "~/Documents/Draft.md")
            LumenPropertyRow(label: "Owner", value: "Alex", monospaced: false)
        }
        .frame(width: 260)
        LumenEmptyState(systemImage: "tray", title: "Nothing here yet",
                        message: "Items you add appear in this list.", actionTitle: "Add item", action: {})
            .frame(height: 220)
    }
    .padding(Lumen.Space.s8)
    .background(.lumen(.bgCanvas))
    .lumenPaletteRoot()
}

public extension ButtonStyle where Self == LumenToolbarIconButtonStyle {
    /// `LumenToolbarIconButtonStyle`: the rounded toolbar tile that appears on hover.
    static var lumenToolbarIcon: LumenToolbarIconButtonStyle { LumenToolbarIconButtonStyle() }
}
