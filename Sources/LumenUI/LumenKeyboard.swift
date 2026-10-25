import AppKit
import SwiftUI
import LumenTokens

// Keyboard: Lumen's shortcuts in one place, the View and Window menu commands that make the panel
// toggles and document tabs discoverable from the menu bar, and the arrow-key behavior shared by
// selection groups (tabs, chips, the sidebar switcher, swatches).

/// Every keyboard shortcut Lumen's components register, so apps can see them in one place and tests
/// can check them against macOS's own.
public enum LumenShortcuts {
    /// Show or hide the navigator (leading sidebar): macOS's sidebar shortcut.
    public static let navigator = KeyboardShortcut("s", modifiers: [.control, .command])
    /// Show or hide the bottom panel, as a debug area does.
    public static let panel = KeyboardShortcut("y", modifiers: [.shift, .command])
    /// Show or hide the inspector, as in Pages, Keynote and Numbers.
    public static let inspector = KeyboardShortcut("i", modifiers: [.option, .command])
    /// The previous and next document tab, as in Safari.
    public static let previousTab = KeyboardShortcut("[", modifiers: [.shift, .command])
    public static let nextTab = KeyboardShortcut("]", modifiers: [.shift, .command])
    /// The command palette. Text editors where ⌘K adds a link (Pages, Mail, Notes) choose another.
    public static let commandPalette = KeyboardShortcut("k", modifiers: .command)

    /// Sidebar panes 1…9 (⌘1…⌘9), as in a navigator sidebar.
    public static func pane(_ number: Int) -> KeyboardShortcut? {
        (1...9).contains(number) ? KeyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command) : nil
    }

    /// Lumen's fixed shortcuts with what they do.
    public static let all: [(title: String, shortcut: KeyboardShortcut)] =
        [("Show/Hide Navigator", navigator), ("Show/Hide Panel", panel), ("Show/Hide Inspector", inspector),
         ("Select Previous Tab", previousTab), ("Select Next Tab", nextTab), ("Command Palette", commandPalette)]
        + (1...9).map { ("Sidebar Pane \($0)", pane($0)!) }

    /// Shortcuts macOS takes before any app sees them (screenshots, app switching, Spotlight, Force
    /// Quit…). An app must never assign these. (Quit, Close, Hide, Minimize and Settings are the app's
    /// own menu items: they're in `standardCommands`, allowed for exactly those commands.)
    public static let systemReserved: [(title: String, shortcut: KeyboardShortcut)] = [
        ("Cycle Windows", .init("`")), ("App Switcher", .init(.tab)),
        ("Spotlight", .init(.space)), ("Emoji & Symbols", .init(.space, modifiers: [.control, .command])),
        ("Full Screen", .init("f", modifiers: [.control, .command])), ("Lock Screen", .init("q", modifiers: [.control, .command])),
        ("Log Out", .init("q", modifiers: [.shift, .command])), ("Screenshot", .init("3", modifiers: [.shift, .command])),
        ("Screenshot Selection", .init("4", modifiers: [.shift, .command])), ("Screenshot Tools", .init("5", modifiers: [.shift, .command])),
        ("Help Search", .init("?", modifiers: [.shift, .command])), ("Show/Hide Dock", .init("d", modifiers: [.option, .command])),
        ("Force Quit", .init(.escape, modifiers: [.option, .command])),
    ]

    /// Shortcuts every Mac app uses for the same commands. An app may use them, but only for that
    /// command (⌘F is Find, never something else).
    public static let standardCommands: [(title: String, shortcut: KeyboardShortcut)] = [
        ("Quit", .init("q")), ("Close", .init("w")), ("Hide", .init("h")), ("Hide Others", .init("h", modifiers: [.option, .command])),
        ("Minimize", .init("m")), ("Settings", .init(",")),
        ("New", .init("n")), ("Open", .init("o")), ("Save", .init("s")), ("Save As", .init("s", modifiers: [.shift, .command])),
        ("Print", .init("p")), ("Undo", .init("z")), ("Redo", .init("z", modifiers: [.shift, .command])), ("Cut", .init("x")),
        ("Copy", .init("c")), ("Paste", .init("v")), ("Select All", .init("a")), ("Find", .init("f")), ("Find Next", .init("g")),
        ("Find Previous", .init("g", modifiers: [.shift, .command])), ("Show Fonts", .init("t")),
    ]
}

/// The shortcuts Lumen's view commands and toolbar toggles use. Start from `.standard` and change
/// what clashes with the app's own (MacScope, say, keeps ⇧⌘Y for Navigation History); `nil` leaves a
/// command without a shortcut.
public struct LumenViewShortcuts: Sendable {
    public var navigator: KeyboardShortcut?
    public var panel: KeyboardShortcut?
    public var inspector: KeyboardShortcut?
    public var previousTab: KeyboardShortcut?
    public var nextTab: KeyboardShortcut?
    public var commandPalette: KeyboardShortcut?

    public init(navigator: KeyboardShortcut? = LumenShortcuts.navigator, panel: KeyboardShortcut? = LumenShortcuts.panel,
                inspector: KeyboardShortcut? = LumenShortcuts.inspector, previousTab: KeyboardShortcut? = LumenShortcuts.previousTab,
                nextTab: KeyboardShortcut? = LumenShortcuts.nextTab, commandPalette: KeyboardShortcut? = LumenShortcuts.commandPalette) {
        self.navigator = navigator
        self.panel = panel
        self.inspector = inspector
        self.previousTab = previousTab
        self.nextTab = nextTab
        self.commandPalette = commandPalette
    }

    public static let standard = LumenViewShortcuts()

    func shortcut(for edge: LumenPanelEdge) -> KeyboardShortcut? {
        switch edge {
        case .leading: navigator
        case .bottom: panel
        case .trailing: inspector
        }
    }
}

// MARK: Menu commands

/// The regions the View menu can show and hide, published by the focused window.
public struct LumenPanelCommandTarget {
    public var leading: Binding<Bool>?
    public var bottom: Binding<Bool>?
    public var trailing: Binding<Bool>?
}

/// Previous and next for the focused window's document tabs.
public struct LumenTabNavigation {
    let previous: () -> Void
    let next: () -> Void
}

/// The focused window's sidebar panes, for View › Show <pane> (⌘1…⌘9).
public struct LumenPaneCommandTarget {
    public var panes: [(id: String, title: String)]
    public var select: (String) -> Void
}

public extension FocusedValues {
    @Entry var lumenPanels: LumenPanelCommandTarget?
    @Entry var lumenTabs: LumenTabNavigation?
    @Entry var lumenPanes: LumenPaneCommandTarget?
}

extension EnvironmentValues {
    /// Whether the menu bar (`LumenViewCommands`) owns Lumen's shortcuts in this window, so the
    /// toolbar toggles, sidebar switcher and command palette register none of their own.
    @Entry public var lumenMenuOwnsShortcuts: Bool = false
}

public extension View {
    /// Publishes this window's panels to `LumenViewCommands`, so View › Show/Hide Navigator, Panel and
    /// Inspector act on it. Pair it with `.lumenMenuOwnsShortcuts()` so each shortcut has one owner.
    func lumenPanelCommands(leading: Binding<Bool>? = nil, bottom: Binding<Bool>? = nil, trailing: Binding<Bool>? = nil) -> some View {
        focusedSceneValue(\.lumenPanels, LumenPanelCommandTarget(leading: leading, bottom: bottom, trailing: trailing))
    }

    /// Publishes this window's sidebar panes to `LumenViewCommands`: View › Show <pane> (⌘1…⌘9) selects
    /// one and, with `showsNavigator`, reveals a collapsed navigator first. Put it where it
    /// stays mounted while the navigator is hidden (the window's root, not the sidebar).
    ///
    /// Pass the switcher's `arrangement` too, so the numbers follow the person's order and skip hidden panes.
    func lumenPaneCommands(_ panes: [LumenSidebarItem], selection: Binding<String>, showsNavigator: Binding<Bool>? = nil,
                           arrangement: String = "") -> some View {
        let visible = LumenToolLayout(encoded: arrangement, all: panes.map(\.id)).visible
        let ordered = visible.compactMap { id in panes.first { $0.id == id } }
        return focusedSceneValue(\.lumenPanes, LumenPaneCommandTarget(panes: ordered.map { ($0.id, $0.title) }) { id in
            showsNavigator?.wrappedValue = true
            selection.wrappedValue = id
        })
    }

    /// The menu bar owns Lumen's shortcuts in this window: the toolbar toggles, inspector toggle,
    /// sidebar switcher and command palette register none, so each shortcut has exactly one owner.
    /// Apply once at the window's root when the scene has `LumenViewCommands`.
    func lumenMenuOwnsShortcuts(_ owns: Bool = true) -> some View {
        environment(\.lumenMenuOwnsShortcuts, owns)
    }
}

/// Menu bar commands for Lumen's workspace pieces: View › Command Palette… and Show/Hide Navigator,
/// Panel and Inspector, and Window › Select Previous/Next Tab (named apart from macOS's own
/// window-tab items). Every
/// toolbar command is also in the menu bar, as Mac convention expects. Add it to your scene:
/// `.commands { LumenViewCommands() }`.
///
/// It replaces the system's sidebar item. Without a published navigator binding it falls back to the
/// standard Toggle Sidebar action, so NavigationSplitView sidebars keep working.
public struct LumenViewCommands: Commands {
    @FocusedValue(\.lumenPanels) private var panels
    @FocusedValue(\.lumenTabs) private var tabs
    @FocusedValue(\.lumenCommandPalette) private var commandPalette
    @FocusedValue(\.lumenPanes) private var panes
    private let shortcuts: LumenViewShortcuts
    private let includesCommandPalette: Bool
    private let includesTabNavigation: Bool
    private let sidebarFallback: Bool

    /// - Parameters:
    ///   - shortcuts: the shortcuts to show and handle; change any that clash with the app's own.
    ///   - commandPalette: include View › Command Palette… (leave it out when the app has its own).
    ///   - tabNavigation: include Window › Select Previous/Next Tab.
    ///   - sidebarFallback: without a published navigator binding, offer the standard Toggle Sidebar
    ///     (for NavigationSplitView). Pass `false` in an app whose sidebar doesn't collapse.
    public init(shortcuts: LumenViewShortcuts = .standard, commandPalette: Bool = true, tabNavigation: Bool = true,
                sidebarFallback: Bool = true) {
        self.shortcuts = shortcuts
        includesCommandPalette = commandPalette
        includesTabNavigation = tabNavigation
        self.sidebarFallback = sidebarFallback
    }

    public var body: some Commands {
        CommandGroup(before: .toolbar) {
            if includesCommandPalette {
                Button("Command Palette…") { commandPalette?.wrappedValue.toggle() }
                    .keyboardShortcut(shortcuts.commandPalette)
                    .disabled(commandPalette == nil)
                Divider()
            }
        }
        CommandGroup(replacing: .sidebar) {
            if let leading = panels?.leading {
                toggle(leading, "Navigator", shortcuts.navigator)
            } else if sidebarFallback {
                Button("Toggle Sidebar") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut(shortcuts.navigator)
            }
            if let bottom = panels?.bottom { toggle(bottom, "Panel", shortcuts.panel) }
            if let trailing = panels?.trailing { toggle(trailing, "Inspector", shortcuts.inspector) }
            if let panes, !panes.panes.isEmpty {
                Divider()
                ForEach(Array(panes.panes.enumerated()), id: \.offset) { index, pane in
                    Button("Show \(pane.title)") { withAnimation(Self.animation) { panes.select(pane.id) } }
                        .keyboardShortcut(LumenShortcuts.pane(index + 1))
                }
            }
        }
        CommandGroup(before: .windowArrangement) {
            if includesTabNavigation {
                Button("Select Previous Tab") { tabs?.previous() }
                    .keyboardShortcut(shortcuts.previousTab)
                    .disabled(tabs == nil)
                Button("Select Next Tab") { tabs?.next() }
                    .keyboardShortcut(shortcuts.nextTab)
                    .disabled(tabs == nil)
                Divider()
            }
        }
    }

    private func toggle(_ binding: Binding<Bool>, _ title: String, _ shortcut: KeyboardShortcut?) -> some View {
        Button(binding.wrappedValue ? "Hide \(title)" : "Show \(title)") {
            withAnimation(Self.animation) { binding.wrappedValue.toggle() }
        }
        .keyboardShortcut(shortcut)
    }

    /// Commands live outside the view tree, so they read Reduce Motion from the system: none then.
    @MainActor private static var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy
    }
}

// MARK: Selection groups

/// Arrow-key movement through a selection group. Groups stop at their ends, as segmented controls
/// do; tab navigation commands wrap, as Safari's do.
enum LumenSelectionStep {
    /// - Parameter staysInRange: for a step between grid rows: past the first or last row, stay put
    ///   rather than slide sideways to the end.
    static func next<ID: Equatable>(_ ids: [ID], from current: ID?, by step: Int, wraps: Bool = false,
                                    staysInRange: Bool = false) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids[step > 0 ? 0 : ids.count - 1] }
        let target = index + step
        if wraps { return ids[(target % ids.count + ids.count) % ids.count] }
        if staysInRange, !ids.indices.contains(target) { return current }
        return ids[min(max(target, 0), ids.count - 1)]
    }
}

extension View {
    /// Makes a row of items one keyboard stop, as a segmented control is: Tab reaches it with Full
    /// Keyboard Access on, ←/→ (and ↑/↓ for grids, by `columns`) move the selection. The group draws
    /// its own focus ring on the selected item, so the system ring is off.
    func lumenSelectionGroup<ID: Hashable>(_ ids: [ID], selection: Binding<ID>, columns: Int? = nil,
                                           focused: FocusState<Bool>.Binding) -> some View {
        let move = { (step: Int, betweenRows: Bool) -> KeyPress.Result in
            if let next = LumenSelectionStep.next(ids, from: selection.wrappedValue, by: step, staysInRange: betweenRows),
               next != selection.wrappedValue {
                selection.wrappedValue = next
            }
            return .handled
        }
        return self
            .focusable(interactions: .activate)
            .focused(focused)
            .focusEffectDisabled()
            .modifier(LumenUnselectedGroupRing(visible: focused.wrappedValue && !ids.contains(selection.wrappedValue)))
            .onKeyPress(.leftArrow) { move(-1, false) }
            .onKeyPress(.rightArrow) { move(1, false) }
            .onKeyPress(.upArrow) { columns.map { move(-$0, true) } ?? .ignored }
            .onKeyPress(.downArrow) { columns.map { move($0, true) } ?? .ignored }
    }

    /// The focus ring a selection group draws around its selected item.
    func lumenGroupFocusRing(_ visible: Bool, cornerRadius: CGFloat) -> some View {
        modifier(LumenGroupFocusRing(visible: visible, cornerRadius: cornerRadius))
    }
}

/// Rings the whole group while it has focus but its selection isn't one of its items (a closed
/// tab, a custom color), so focus never goes unseen; the first arrow key selects an item.
private struct LumenUnselectedGroupRing: ViewModifier {
    let visible: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: metrics.radius.md, style: .continuous)
                .strokeBorder(palette[.borderFocus], lineWidth: metrics.stroke.focus)
                .padding(-metrics.stroke.focus)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

private struct LumenGroupFocusRing: ViewModifier {
    let visible: Bool
    let cornerRadius: CGFloat
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(palette[.borderFocus], lineWidth: metrics.stroke.focus)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Focus rings for Lumen-drawn buttons

/// A borderless button with at least a 24 pt hit area that dims while pressed. The plain style draws no
/// focus ring, and a button style can't see keyboard focus on macOS, so pair it with
/// `.lumenFocusRing()` on the button when it's a Tab stop: `.buttonStyle(.lumenPlain).lumenFocusRing()`.
public struct LumenPlainButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HitArea(configuration: configuration)
    }

    private struct HitArea: View {
        let configuration: Configuration
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? metrics.layout.pressedOpacity : 1)
                // Disabled reads as disabled, as every other Lumen control.
                .lumenDisabledFade(isEnabled)
                .frame(minWidth: metrics.layout.minimumHitTarget, minHeight: metrics.layout.minimumHitTarget)
                .contentShape(.rect)
        }
    }
}

public extension ButtonStyle where Self == LumenPlainButtonStyle {
    /// `LumenPlainButtonStyle`: borderless, with a 24 pt hit area.
    static var lumenPlain: LumenPlainButtonStyle { LumenPlainButtonStyle() }
}

public extension View {
    /// Shows keyboard focus on a Lumen-drawn control: a ring in `border.focus` while it has focus (Tab
    /// with Keyboard Navigation on). Apply it to the button or menu itself, after its style.
    func lumenFocusRing(cornerRadius: CGFloat? = nil, inset: CGFloat = 0) -> some View {
        modifier(LumenFocusRingModifier(cornerRadius: cornerRadius, inset: inset))
    }
}

private struct LumenFocusRingModifier: ViewModifier {
    let cornerRadius: CGFloat?
    let inset: CGFloat
    @FocusState private var isFocused: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius ?? metrics.radius.sm, style: .continuous)
                    .strokeBorder(palette[.borderFocus], lineWidth: metrics.stroke.focus)
                    .padding(inset)
                    .opacity(isFocused ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}
