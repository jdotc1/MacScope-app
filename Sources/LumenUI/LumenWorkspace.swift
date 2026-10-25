import AppKit
import SwiftUI
import LumenTokens

// The workspace window: a title bar that glows while the window is active, panel toggles
// that show which regions are open and slide them in and out, a bottom panel, a "new" button with a
// menu of large tiles, and a dock zone. Structure stays native (the toolbar, NavigationSplitView,
// `.inspector`, menus, shortcuts); these pieces are the visual language.

// MARK: Title bar glow

public extension View {
    /// The window's title bar glows (`titlebar.activeTop` → `titlebar.activeBottom`) while the
    /// window is active and goes flat (`toolbar.background`) when it isn't, so the frontmost window is
    /// obvious at a glance. Lumen's toolbar pieces dim with it. Apply to the window's root view.
    func lumenWindowChrome() -> some View { modifier(LumenWindowChromeModifier()) }
}

private struct LumenWindowChromeModifier: ViewModifier {
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.lumenPalette) private var palette

    func body(content: Content) -> some View {
        let active = activeState != .inactive
        let style: AnyShapeStyle = active
            ? AnyShapeStyle(LinearGradient(colors: [palette[.titlebarActiveTop], palette[.titlebarActiveBottom]],
                                           startPoint: .top, endPoint: .bottom))
            : AnyShapeStyle(palette[.toolbarBackground])
        content
            .toolbarBackground(style, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
    }
}

/// The title bar glow as a view, for apps that draw their own top bar under a hidden title bar
/// (where `.lumenWindowChrome()` has no native toolbar to paint): the gradient while the window is
/// active, flat `toolbar.background` when it isn't.
public struct LumenTitlebarBackground: View {
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.lumenPalette) private var palette

    public init() {}

    public var body: some View {
        if activeState != .inactive {
            LinearGradient(colors: [palette[.titlebarActiveTop], palette[.titlebarActiveBottom]], startPoint: .top, endPoint: .bottom)
        } else {
            palette[.toolbarBackground]
        }
    }
}

public extension View {
    /// Greys out and quiets toolbar content in an inactive window, as native toolbar items do. Lumen's
    /// toolbar pieces do this already; use it on an app's own top bar items.
    func lumenToolbarDimming() -> some View { modifier(LumenToolbarDimming()) }
}

/// Toolbar pieces go grey and quiet in an inactive window, as native toolbar items do. The dimming
/// doesn't compound with a disabled control's own: disabled toolbar buttons inside it keep their
/// 45% overall (the 2:1 floor the validator checks), not 45% of 55%.
struct LumenToolbarDimming: ViewModifier {
    static let inactiveOpacity = 0.55
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.lumenAncestorOpacity) private var ancestorOpacity
    @Environment(\.lumenInsideToolbarDimming) private var insideDimming
    func body(content: Content) -> some View {
        // Once: a piece inside an already dimmed group (an app's `.lumenToolbarDimming()` around
        // Lumen's own pieces) doesn't dim again.
        let active = activeState != .inactive || insideDimming
        let opacity = active ? 1 : Self.inactiveOpacity
        content
            .environment(\.lumenAncestorOpacity, ancestorOpacity * opacity)
            .environment(\.lumenInsideToolbarDimming, true)
            .saturation(active ? 1 : 0)
            .opacity(opacity)
    }
}

extension EnvironmentValues {
    /// The opacity an enclosing dimming already applies, so a disabled control can make up the rest
    /// rather than dim twice.
    @Entry var lumenAncestorOpacity: Double = 1
    /// Set inside `LumenToolbarDimming`, so nested toolbar pieces dim once.
    @Entry var lumenInsideToolbarDimming = false
}

extension View {
    /// A disabled control's opacity, `target` overall, given what an enclosing dimming applies.
    func lumenDisabledOpacity(_ isEnabled: Bool, target: Double, ancestor: Double) -> some View {
        opacity(isEnabled ? 1 : min(1, target / max(ancestor, 0.01)))
    }
}

// MARK: Breadcrumb

/// The project's place at the leading edge of the toolbar: its tile, then each level after a
/// slanted divider, as in the title bar.
public struct LumenToolbarBreadcrumb: View {
    private let segments: [String]
    private let systemImage: String
    private let hue: LumenToken
    private let activity: LumenActivity?
    private let onCancel: (() -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ segments: [String], systemImage: String, hue: LumenToken = .accent) {
        self.init(segments, systemImage: systemImage, hue: hue, activity: nil, onCancel: nil)
    }

    /// - Parameters:
    ///   - activity: a live segment after the path while it's working ("Indexing Files… 16 of 92"),
    ///     with a progress ring; nothing while idle.
    ///   - onCancel: an inline ⓧ in that segment that stops the work.
    public init(_ segments: [String], systemImage: String, hue: LumenToken = .accent, activity: LumenActivity?,
                onCancel: (() -> Void)? = nil) {
        self.segments = segments
        self.systemImage = systemImage
        self.hue = hue
        self.activity = activity
        self.onCancel = onCancel
    }

    public var body: some View {
        // The whole path when it fits, then the last level, then the last level truncated: never
        // wider than the space it's given (it used to draw past its frame).
        ViewThatFits(in: .horizontal) {
            trail(segments).fixedSize()
            trail(Array(segments.suffix(1))).fixedSize()
            trail(Array(segments.suffix(1)))
        }
        .modifier(LumenToolbarDimming())
        .accessibilityElement(children: .contain)
        .accessibilityLabel((segments + [activity.flatMap { $0.isBusy ? $0.label : nil }].compactMap(\.self)).joined(separator: ", "))
    }

    private func trail(_ shown: [String]) -> some View {
        HStack(spacing: metrics.spacing.s3) {
            // No backlight in the toolbar: the item's bounds would clip it.
            LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileMode)
                .lumenTileBacklight(false)
            ForEach(Array(shown.enumerated()), id: \.offset) { index, segment in
                SlantDivider().stroke(palette[.borderStrong], lineWidth: metrics.stroke.hairline).frame(width: 7, height: 20)
                Text(segment)
                    .font(index == shown.count - 1 ? metrics.typography.headline : metrics.typography.body)
                    .foregroundStyle(palette[index == shown.count - 1 ? .toolbarForeground : .fgSecondary])
                    .lineLimit(1)
                    .lumenNeverTruncates(segment)
                    .truncationMode(.middle)
            }
            // Dividers go between levels only: one before the activity, none trailing the path.
            if case .working(let text, let progress) = activity {
                SlantDivider().stroke(palette[.borderStrong], lineWidth: metrics.stroke.hairline).frame(width: 7, height: 20)
                HStack(spacing: metrics.spacing.s2) {
                    LumenProgressRing(progress: progress).frame(width: 14, height: 14)
                    Text(text).font(metrics.typography.callout).foregroundStyle(palette[.fgSecondary]).lineLimit(1).fixedSize().lumenNeverTruncates(text)
                    if let onCancel {
                        Button("Stop", systemImage: "xmark.circle.fill", action: onCancel)
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(palette[.fgTertiary]).help("Stop")
                            .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
                            .contentShape(.rect)
                            .lumenIconOnlyControl("Stop")
                    }
                }
            }
        }
    }
}

private struct SlantDivider: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

// MARK: Panel toggles

/// A region of the workspace window a panel toggle controls.
public enum LumenPanelEdge: Sendable, CaseIterable {
    case leading, bottom, trailing

    var title: String {
        switch self {
        case .leading: "Navigator"
        case .bottom: "Panel"
        case .trailing: "Inspector"
        }
    }


}

/// The layout switcher: one toggle per region, each drawn as the window with that region filled
/// in `layoutToggle.on` while it shows. Pass bindings only for the regions your window has.
public struct LumenPanelToggles: View {
    private let toggles: [(LumenPanelEdge, Binding<Bool>)]
    private let shortcuts: LumenViewShortcuts
    private let registersShortcuts: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameters:
    ///   - shortcuts: the shortcuts shown in help tags (and registered, below); ⌃⌘S, ⇧⌘Y, ⌥⌘I by default.
    ///   - registersShortcuts: register them here. Pass `false` when the window publishes
    ///     `.lumenPanelCommands` and the app installs `LumenViewCommands`: the menu owns them then.
    public init(leading: Binding<Bool>? = nil, bottom: Binding<Bool>? = nil, trailing: Binding<Bool>? = nil,
                shortcuts: LumenViewShortcuts = .standard, registersShortcuts: Bool = true) {
        toggles = [(LumenPanelEdge.leading, leading), (.bottom, bottom), (.trailing, trailing)]
            .compactMap { edge, binding in binding.map { (edge, $0) } }
        self.shortcuts = shortcuts
        self.registersShortcuts = registersShortcuts
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(toggles, id: \.0) { edge, isOn in
                LumenPanelToggle(edge: edge, isOn: isOn, shortcut: shortcuts.shortcut(for: edge), registersShortcut: registersShortcuts)
            }
        }
        .padding(2)
        .background(palette[.bgHover].opacity(metrics.layout.hoverOpacity), in: .rect(cornerRadius: metrics.radius.md, style: .continuous))
        .modifier(LumenToolbarDimming())
    }
}

/// One region toggle.
public struct LumenPanelToggle: View {
    private let edge: LumenPanelEdge
    @Binding private var isOn: Bool
    private let shortcut: KeyboardShortcut?
    private let registersShortcut: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenMenuOwnsShortcuts) private var menuOwnsShortcuts
    @State private var isHovered = false

    /// A toggle with the region's standard shortcut (`LumenViewShortcuts.standard`).
    public init(edge: LumenPanelEdge, isOn: Binding<Bool>, registersShortcut: Bool = true) {
        self.init(edge: edge, isOn: isOn, shortcut: LumenViewShortcuts.standard.shortcut(for: edge), registersShortcut: registersShortcut)
    }

    /// A toggle with this shortcut; `nil` means none.
    public init(edge: LumenPanelEdge, isOn: Binding<Bool>, shortcut: KeyboardShortcut?, registersShortcut: Bool = true) {
        self.edge = edge
        _isOn = isOn
        self.shortcut = shortcut
        self.registersShortcut = registersShortcut
    }

    public var body: some View {
        Button {
            withAnimation(metrics.motion.animation(metrics.motion.standardCurve, reduceMotion: reduceMotion)) { isOn.toggle() }
        } label: {
            PanelGlyph(edge: edge, isOn: isOn, on: palette[.layoutToggleOn], off: palette[.toolbarForeground].opacity(0.75))
                .frame(width: 20, height: 16)
                // One size with every toolbar icon button (`toolbarButton`, 28 pt).
                .frame(width: metrics.layout.toolbarButton, height: metrics.layout.toolbarButton)
                // The filled glyph is the "on" state (shape, not only color); a plate shows only on
                // hover, the same plate as every top-bar button.
                .background { LumenToolbarHoverPlate(isHovered: isHovered) }
                .contentShape(.rect)
        }
        .buttonStyle(.lumenPlain).lumenFocusRing()
        .lumenIconOnlyControl(edge.title)
        .onHover { isHovered = $0 }
        .keyboardShortcut(registersShortcut && !menuOwnsShortcuts ? shortcut : nil)
        .help("\(isOn ? "Hide" : "Show") \(edge.title)" + (shortcut.map { " (\(LumenKeycap.text(for: $0)))" } ?? ""))
        .accessibilityLabel(edge.title)
        .accessibilityValue(isOn ? "Shown" : "Hidden")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The window outline with one region: filled while it shows, outlined while it's hidden.
private struct PanelGlyph: View {
    let edge: LumenPanelEdge
    let isOn: Bool
    let on: Color
    let off: Color

    var body: some View {
        let ink = isOn ? on : off
        GeometryReader { proxy in
            let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 0.75, dy: 0.75)
            let region: CGRect = switch edge {
            case .leading: CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.36, height: rect.height)
            case .bottom: CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.4, width: rect.width, height: rect.height * 0.4)
            case .trailing: CGRect(x: rect.maxX - rect.width * 0.36, y: rect.minY, width: rect.width * 0.36, height: rect.height)
            }
            let outline = RoundedRectangle(cornerRadius: 3, style: .continuous)
            ZStack(alignment: .topLeading) {
                outline.path(in: rect).stroke(ink, lineWidth: 1.5)
                if isOn {
                    outline.path(in: rect).intersection(Path(region)).fill(ink)
                } else {
                    divider(region: region, in: rect).stroke(ink, lineWidth: 1.2)
                }
            }
        }
    }

    private func divider(region: CGRect, in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .leading: path.move(to: CGPoint(x: region.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: region.maxX, y: rect.maxY))
        case .bottom: path.move(to: CGPoint(x: rect.minX, y: region.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: region.minY))
        case .trailing: path.move(to: CGPoint(x: region.minX, y: rect.minY)); path.addLine(to: CGPoint(x: region.minX, y: rect.maxY))
        }
        return path
    }
}

// MARK: Bottom panel

public extension View {
    /// A bottom panel under this view: it slides in and out with `isPresented` (pair it with a
    /// `LumenPanelToggles` bottom binding) and resizes by dragging its top edge. The content above
    /// always keeps `contentMinHeight`; in a window too short to also fit the panel's `minHeight`,
    /// the panel steps aside until there's room (`isPresented` stays as it is).
    ///
    /// - Parameters:
    ///   - contentMinHeight: the least height the content above keeps (MacScope's editor keeps 360).
    ///   - maxFraction: the most of the total height the panel may take (MacScope's debugger: 0.25).
    ///   - maximumHeight: an optional absolute cap, combined with the fractional cap. The content
    ///     above always keeps its minimum; the panel's `minHeight` wins over a smaller absolute cap.
    func lumenBottomPanel<Panel: View>(isPresented: Binding<Bool>, height: Binding<CGFloat>? = nil, minHeight: CGFloat = 120,
                                       contentMinHeight: CGFloat = 120, maxFraction: CGFloat = 1,
                                       @ViewBuilder panel: @escaping () -> Panel) -> some View {
        LumenBottomPanelContainer(content: self, isPresented: isPresented, externalHeight: height, minHeight: minHeight,
                                  contentMinHeight: contentMinHeight, maxFraction: maxFraction, maximumHeight: nil, panel: panel)
    }

    /// As above, with an absolute cap: the panel stays within both `maxFraction` and `maximumHeight`.
    func lumenBottomPanel<Panel: View>(isPresented: Binding<Bool>, height: Binding<CGFloat>? = nil, minHeight: CGFloat = 120,
                                       contentMinHeight: CGFloat = 120, maxFraction: CGFloat = 1, maximumHeight: CGFloat?,
                                       @ViewBuilder panel: @escaping () -> Panel) -> some View {
        LumenBottomPanelContainer(content: self, isPresented: isPresented, externalHeight: height, minHeight: minHeight,
                                  contentMinHeight: contentMinHeight, maxFraction: maxFraction, maximumHeight: maximumHeight, panel: panel)
    }
}

struct LumenBottomPanelContainer<Content: View, Panel: View>: View {
    let content: Content
    @Binding var isPresented: Bool
    let externalHeight: Binding<CGFloat>?
    let minHeight: CGFloat
    let contentMinHeight: CGFloat
    let maxFraction: CGFloat
    let maximumHeight: CGFloat?
    let panel: () -> Panel

    @State private var localHeight: CGFloat = 240
    @State private var dragStart: CGFloat?
    @State private var isHoveringGrip = false
    @State private var cursorPushed = false
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: Binding<CGFloat> { externalHeight ?? $localHeight }

    /// The tallest the panel may be: what the content above can spare and the fraction allows. The
    /// content's minimum always wins; when that leaves less than the panel's own minimum, the panel
    /// steps aside (`nil`) rather than starve the content or shrink below usable.
    static func maxPanelHeight(total: CGFloat, minHeight: CGFloat, contentMinHeight: CGFloat, maxFraction: CGFloat,
                               maximumHeight: CGFloat? = nil) -> CGFloat? {
        let cap = min(total * maxFraction, max(minHeight, maximumHeight ?? .infinity))
        let available = min(total - contentMinHeight, cap)
        return available >= minHeight ? available : nil
    }

    var body: some View {
        GeometryReader { proxy in
            let maxHeight = Self.maxPanelHeight(total: proxy.size.height, minHeight: minHeight,
                                                contentMinHeight: contentMinHeight, maxFraction: maxFraction,
                                                maximumHeight: maximumHeight)
            VStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if isPresented, let maxHeight {
                    VStack(spacing: 0) {
                        // Above the panel, so the grip's lower half (it overhangs the hairline) gets
                        // its hits rather than the panel body drawn after it.
                        resizeHandle(maxHeight: maxHeight).zIndex(1)
                        panel()
                            .frame(maxWidth: .infinity)
                            .frame(height: min(max(height.wrappedValue, minHeight), maxHeight))
                            .background(palette[.bgWindow])
                    }
                    .transition(.move(edge: .bottom))
                }
            }
            .clipped()
            .animation(metrics.motion.animation(metrics.motion.standardCurve, reduceMotion: reduceMotion), value: isPresented)
        }
    }

    private func resizeHandle(maxHeight: CGFloat) -> some View {
        Rectangle()
            .fill(palette[.borderSubtle])
            .frame(height: metrics.stroke.hairline)
            .frame(maxWidth: .infinity)
            .overlay {
                // A taller invisible grip than the hairline it draws.
                Color.clear.frame(height: 7).contentShape(.rect)
                    .onHover { isHoveringGrip = $0; updateCursor() }
                    .onDisappear { isHoveringGrip = false; dragStart = nil; updateCursor() }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            // Start from the height on screen, which a smaller window may have clamped.
                            let start = dragStart ?? min(max(height.wrappedValue, minHeight), maxHeight)
                            dragStart = start
                            height.wrappedValue = min(max(start - value.translation.height, minHeight), maxHeight)
                            updateCursor()
                        }
                        .onEnded { _ in dragStart = nil; updateCursor() })
            }
            .accessibilityHidden(true)
    }

    /// The resize cursor shows while the pointer is on the grip or dragging it, with pushes and pops
    /// kept balanced (a drag can leave the grip, and hiding the panel skips the hover exit).
    private func updateCursor() {
        let wanted = isHoveringGrip || dragStart != nil
        if wanted, !cursorPushed { NSCursor.resizeUpDown.push(); cursorPushed = true }
        if !wanted, cursorPushed { NSCursor.pop(); cursorPushed = false }
    }
}

// MARK: Panel deck controls

/// One thing a bottom panel can show (a debugger, a shell, problems).
public struct LumenPanelDeck: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String

    public init(id: String, title: String, systemImage: String) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

/// Controls for a bottom panel that holds several decks: a menu of decks (choosing one shows the
/// panel with it) and a show/hide toggle. Mount it where it stays visible while the panel is hidden,
/// such as a context or status bar. It registers no shortcuts: the View menu owns ⇧⌘Y
/// (`LumenViewCommands`).
public struct LumenPanelDeckControls: View {
    private let decks: [LumenPanelDeck]
    @Binding private var selection: String
    @Binding private var isPresented: Bool
    private let identifiers: (selector: String, toggle: String)

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter identifiers: accessibility identifiers for the deck menu and the toggle, for an
    ///   app's UI tests (MacScope keeps `workspace.bottomPanel.selector` and `.toggle`).
    public init(decks: [LumenPanelDeck], selection: Binding<String>, isPresented: Binding<Bool>,
                identifiers: (selector: String, toggle: String) = ("lumen.panelDeck.selector", "lumen.panelDeck.toggle")) {
        self.decks = decks
        _selection = selection
        _isPresented = isPresented
        self.identifiers = identifiers
    }

    public var body: some View {
        let current = decks.first { $0.id == selection } ?? decks.first
        HStack(spacing: 2) {
            Menu {
                ForEach(decks) { deck in
                    Button {
                        selection = deck.id
                        isPresented = true
                    } label: {
                        Label { Text(deck.title) } icon: { LumenSymbol(deck.systemImage) }
                    }
                }
            } label: {
                LumenSymbol(current?.systemImage ?? "rectangle.bottomthird.inset.filled")
                    .foregroundStyle(palette[.fgSecondary])
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
            .lumenFocusRing()
            .help("Choose \(decks.map(\.title).joined(separator: " or "))")
            .accessibilityLabel("Choose bottom panel")
            .accessibilityIdentifier(identifiers.selector)
            LumenPanelToggle(edge: .bottom, isOn: $isPresented, shortcut: nil, registersShortcut: false)
                .accessibilityIdentifier(identifiers.toggle)
        }
        .fixedSize()
    }
}

// MARK: New-item button and launch menu

/// The New button: a plus in one color (the accent), drawn at the panel toggles' size and stroke,
/// placed right beside them. the spark is optional: pass `sparkHue` for a
/// small second plus at the same stroke.
///
/// `title` (the help tag and spoken label) defaults to the generic "New"; name what the button
/// creates ("New Tab", "New Document"). `LumenWorkspaceWindow.newItemButton` defaults to "New Tab"
/// because there the button always opens a tab.
public struct LumenNewItemButton: View {
    private let title: String
    private let hue: LumenToken
    private let sparkHue: LumenToken?
    private let action: () -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var isHovered = false

    public init(_ title: String = "New", hue: LumenToken = .accent, sparkHue: LumenToken? = nil, action: @escaping () -> Void) {
        self.title = title
        self.hue = hue
        self.sparkHue = sparkHue
        self.action = action
    }

    /// The plus's box and stroke: the panel toggles' glyph height (16 pt) and outline (1.5 pt).
    static let glyphSize: CGFloat = 16
    static let lineWidth: CGFloat = 1.5

    public var body: some View {
        Button(action: action) {
            ZStack {
                if let sparkHue {
                    PlusShape(center: CGPoint(x: 10, y: 14), arm: 7)
                        .stroke(palette[hue], style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    PlusShape(center: CGPoint(x: 20, y: 4), arm: 3)
                        .stroke(palette[sparkHue], style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                } else {
                    PlusShape(center: CGPoint(x: 12, y: 12), arm: 10.5)
                        .stroke(palette[hue], style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                }
            }
            .frame(width: Self.glyphSize, height: Self.glyphSize)
            // One size with every toolbar icon button (`toolbarButton`, 28 pt), as the toggles.
            .frame(width: metrics.layout.toolbarButton, height: metrics.layout.toolbarButton)
            .background { LumenToolbarHoverPlate(isHovered: isHovered) }
            .contentShape(.rect)
        }
        .buttonStyle(.lumenPlain).lumenFocusRing()
        .lumenIconOnlyControl(title)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .modifier(LumenToolbarDimming())
    }
}

/// A plus in the 24-unit grid, scaled to the frame (the stroke is in points).
private struct PlusShape: Shape {
    let center: CGPoint
    let arm: CGFloat
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 24
        var path = Path()
        path.move(to: CGPoint(x: center.x - arm, y: center.y)); path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - arm)); path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        return path.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// One thing the launch menu can create.
public struct LumenLaunchItem: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let hue: LumenToken
    public let shortcut: KeyboardShortcut?
    public let perform: () -> Void

    public init(_ title: String, systemImage: String, hue: LumenToken, shortcut: KeyboardShortcut? = nil, perform: @escaping () -> Void) {
        id = title
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        self.shortcut = shortcut
        self.perform = perform
    }
}

/// The "new" menu: what you can create, each with a large tile, as in a launcher. Arrow keys move,
/// Return chooses, Escape closes.
public struct LumenLaunchMenu: View {
    private let items: [LumenLaunchItem]
    private let onDismiss: () -> Void

    @State private var highlighted: Int?
    @FocusState private var focused: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ items: [LumenLaunchItem], onDismiss: @escaping () -> Void = {}) {
        self.items = items
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { choose(item) } label: {
                    HStack(spacing: metrics.spacing.s4) {
                        LumenRowTile(systemImage: item.systemImage, hue: item.hue, size: metrics.layout.tileProminent,
                                     isHighlighted: highlighted == index)
                        Text(item.title).font(metrics.typography.body)
                            .foregroundStyle(palette[highlighted == index ? .menuHighlightForeground : .menuForeground])
                        Spacer(minLength: metrics.spacing.s6)
                        if let shortcut = item.shortcut {
                            LumenKeycap(shortcut, onHighlight: highlighted == index)
                        }
                    }
                    .padding(.horizontal, metrics.spacing.s3)
                    .padding(.vertical, metrics.spacing.s2)
                    .background(palette[.menuHighlight].opacity(highlighted == index ? 1 : 0),
                                in: .rect(cornerRadius: metrics.radius.md, style: .continuous))
                    .contentShape(.rect)
                }
                .buttonStyle(.lumenPlain)
                .focusable(false)   // the menu owns the keyboard and its highlight, as the command menu does
                // The highlight follows the pointer and clears when it leaves the row.
                .onHover { inside in if inside { highlighted = index } else if highlighted == index { highlighted = nil } }
            }
        }
        .padding(metrics.spacing.s2)
        .frame(minWidth: 240)
        // A popover is a raised ground: keycaps and hovers resolve against it.
        .lumenRaisedGround()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { highlighted.flatMap { items[safe: $0] }.map(choose); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onChange(of: items.map(\.id)) { highlighted = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New")
    }

    private func move(_ step: Int) {
        guard !items.isEmpty else { return }
        highlighted = ((highlighted ?? (step > 0 ? -1 : 0)) + step + items.count) % items.count
    }

    private func choose(_ item: LumenLaunchItem) {
        onDismiss()
        item.perform()
    }
}

public extension View {
    /// Presents `LumenLaunchMenu` in a popover from this view (the new-item button, say).
    func lumenLaunchMenu(isPresented: Binding<Bool>, items: [LumenLaunchItem]) -> some View {
        popover(isPresented: isPresented, arrowEdge: .bottom) {
            LumenLaunchMenu(items) { isPresented.wrappedValue = false }
        }
    }
}

// MARK: Dock zone

/// Where something can be docked or dropped: a dashed square and one line of instruction, lit in
/// the accent while a drag is over it.
public struct LumenDropZone: View {
    private let message: String
    private let isTargeted: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ message: String = "Drag a sidebar icon here to dock.", isTargeted: Bool = false) {
        self.message = message
        self.isTargeted = isTargeted
    }

    public var body: some View {
        VStack(spacing: metrics.spacing.s3) {
            RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: metrics.stroke.regular, dash: [4, 3]))
                .foregroundStyle(palette[isTargeted ? .accent : .fgTertiary])
                .frame(width: 26, height: 26)
            Text(message)
                .font(metrics.typography.caption)
                .foregroundStyle(palette[isTargeted ? .fgPrimary : .fgTertiary])
                .multilineTextAlignment(.center)
                .frame(maxWidth: 160)
        }
        .padding(metrics.spacing.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // One plate in both states, edge to edge, so zones line up with the cards beside them; a
        // drag over it fills it with the accent.
        .background {
            RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous)
                .fill(palette[.accentSubtle].opacity(isTargeted ? 0.6 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous)
                .strokeBorder(isTargeted ? palette[.accent].opacity(0.5) : palette[.borderSubtle], lineWidth: metrics.stroke.hairline)
        }
        .animation(metrics.motion.animation(metrics.motion.fastCurve, reduceMotion: reduceMotion), value: isTargeted)
        .accessibilityElement(children: .combine)
    }
}

/// A progress ring: an arc filling clockwise, or a spinning quarter arc when indeterminate.
public struct LumenProgressRing: View {
    private let progress: Double?
    @Environment(\.lumenPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    /// - Parameter progress: 0 to 1, or `nil` for indeterminate.
    public init(progress: Double?) { self.progress = progress }

    public var body: some View {
        ZStack {
            Circle().stroke(palette[.borderDefault], lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress.map { min(max($0, 0), 1) } ?? 0.25)
                .stroke(palette[.accent], style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90 + (progress == nil && spinning ? 360 : 0)))
                // Reduce Motion: a still quarter arc, no spin (not even one turn on appear).
                .animation(progress == nil && !reduceMotion ? .linear(duration: 1).repeatForever(autoreverses: false) : nil, value: spinning)
        }
        // Keyed on indeterminate, so a ring that starts determinate and later loses its value spins.
        .onAppear { spinning = progress == nil && !reduceMotion }
        .onChange(of: progress == nil) { _, indeterminate in spinning = indeterminate && !reduceMotion }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}
