import SwiftUI
import LumenTokens

// Shared chrome, so the same kind of control looks the same in every component (0.38 polish):
// fields, pop-ups, cards, small glyph buttons and Lumen-labelled menus.

/// What a piece of chrome is.
enum LumenChromeKind {
    /// A text field or value well: `bg.elevated` with a `border.default` hairline, `border.focus`
    /// when focused. On a raised ground in dark (a card, sheet or popover) it takes the raised well
    /// (`bg.inset`, drawn there as `bg.insetRaised`), which is lighter than that ground.
    case field
    /// A pop-up, pull-down or other menu button: `bg.elevated` with a `border.default` hairline, and
    /// the raised well on a raised ground in dark, as fields.
    case popUp
    /// A card or bordered box: `bg.elevated`, the large radius, a `border.subtle` hairline.
    case card
}

private struct LumenChromeModifier: ViewModifier {
    let kind: LumenChromeKind
    let isFocused: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let radius = kind == .card ? metrics.radius.lg : metrics.radius.sm
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Fields too: white in light, a step up in dark, as native fields; the hairline marks them.
        // On a raised ground in dark (a sheet, a card) that step would be no step at all: they take
        // the raised well instead, which is lighter than the ground.
        let fill: LumenToken = palette.key.raised && colorScheme == .dark && kind != .card ? .bgInset : .bgElevated
        content
            .background(palette[fill], in: shape)
            .lumenRaisedGround()
            .overlay {
                shape.strokeBorder(palette[isFocused ? .borderFocus : (kind == .card ? .borderSubtle : .borderDefault)],
                                   lineWidth: isFocused ? metrics.stroke.regular : metrics.stroke.hairline)
            }
            // A disabled field or pop-up fades as every Lumen control does (a card holds controls
            // that fade themselves). The fade doesn't compound with an enclosing one.
            .lumenDisabledFade(kind == .card || isEnabled)
    }
}

extension LumenResolvedPalette {
    /// A hover fill: `bg.hover` at the layout's `hoverOpacity` on the canvas; on a raised ground
    /// (a palette from `raised()`: cards, popovers, sheets, menus) `bg.hoverRaised` at full strength,
    /// the strength its visibility rules check it at against `bg.elevated`.
    func hoverFill(_ metrics: LumenMetrics) -> Color {
        key.raised ? self[.bgHover] : self[.bgHover].opacity(metrics.layout.hoverOpacity)
    }
}

extension View {
    /// Lumen's chrome for a kind of control. Fields show focus in `border.focus`.
    func lumenChrome(_ kind: LumenChromeKind, focused: Bool = false) -> some View {
        modifier(LumenChromeModifier(kind: kind, isFocused: focused))
    }

    /// Fades a disabled control by the layout's `disabledOpacity`.
    func lumenDisabledFade(_ isEnabled: Bool) -> some View {
        modifier(LumenDisabledFade(isEnabled: isEnabled))
    }
}

/// The one disabled treatment: `disabledOpacity` overall. An enclosing fade (a disabled dependent
/// group, an off sentence row, an inactive toolbar) counts toward it, so a disabled control inside
/// one isn't dimmed twice; the opacity this applies is passed down for the same reason.
private struct LumenDisabledFade: ViewModifier {
    let isEnabled: Bool
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenAncestorOpacity) private var ancestor
    func body(content: Content) -> some View {
        let applied = isEnabled ? 1 : min(1, metrics.layout.disabledOpacity / max(ancestor, 0.01))
        // Composited first, so a control's overlapping parts (a box's fill and its edge) fade as one
        // rather than each to 45%, which stacked to about 70% where they overlap.
        content
            .environment(\.lumenAncestorOpacity, ancestor * applied)
            .compositingGroup()
            .opacity(applied)
    }
}

/// A borderless button that never dims itself: SwiftUI's `.plain` style fades a disabled label on
/// its own (to about 57%), which stacked on Lumen's fade. Lumen controls fade with
/// `lumenDisabledFade` instead, so every disabled control reads the same.
struct LumenBareButtonStyle: ButtonStyle {
    @Environment(\.lumenMetrics) private var metrics
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? metrics.layout.pressedOpacity : 1)
    }
}

extension ButtonStyle where Self == LumenBareButtonStyle {
    static var lumenBare: LumenBareButtonStyle { LumenBareButtonStyle() }
}

/// A plain glyph button with help (table footers, rule rows, steppers).
struct LumenGlyphButton: View {
    let systemImage: String
    let title: String
    var enabled = true
    /// The hit height; `nil` uses the layout's `minimumHitTarget`.
    var size: CGFloat? = nil
    let action: () -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let size = size ?? metrics.layout.minimumHitTarget
        Button(action: action) {
            LumenSymbol(systemImage).font(.system(size: metrics.iconSize.small, weight: .semibold))
                .foregroundStyle(palette[.fgSecondary])
                .frame(width: size + 4, height: size)
                .contentShape(.rect)
        }
        .buttonStyle(.lumenBare)
        .lumenIconOnlyControl(title)
        .lumenDisabledFade(enabled && isEnabled)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A menu whose label Lumen draws. Offscreen renders (golden images) draw just the label, since
/// AppKit menus can't render there.
struct LumenMenuButton<Label: View, Items: View>: View {
    let help: String?
    let label: Label
    let items: Items

    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.isEnabled) private var isEnabled

    init(help: String? = nil, @ViewBuilder items: () -> Items, @ViewBuilder label: () -> Label) {
        self.help = help
        self.items = items()
        self.label = label()
    }

    var body: some View {
        // The label is sized and faded the same way offscreen and live, so golden images show what
        // the window does: only the `Menu` around it is swapped.
        if rendersOffscreen {
            label.fixedSize().lumenDisabledFade(isEnabled)
        } else {
            // One element per menu: a label's text and its decorative chevron would otherwise each
            // become a menu button. The bare style: `.plain` would dim a disabled label on its own.
            Menu { items } label: { label.accessibilityElement(children: .combine) }
                .menuStyle(.button)
                .buttonStyle(.lumenBare)
                .menuIndicator(.hidden)
                .fixedSize()
                .lumenDisabledFade(isEnabled)
                .modifier(LumenOptionalHelp(help))
        }
    }
}

/// A help tag only when there is one (an empty `.help("")` still registers a tooltip).
struct LumenOptionalHelp: ViewModifier {
    let help: String?
    init(_ help: String?) { self.help = help }
    func body(content: Content) -> some View {
        if let help { content.help(help) } else { content }
    }
}

/// The rounded square of a Lumen checkbox (the layout's `toggleIndicator`), shared by
/// `.lumenCheckbox` and the checklist tree: the filled accent (`accent.filled`, white mark) when
/// on, a `border.control` edge when off so it reads as a control.
struct LumenCheckboxBox: View {
    /// `true` checked, `false` unchecked, `nil` mixed.
    let state: Bool?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    var body: some View {
        let on = state != false
        let size = metrics.layout.toggleIndicator
        RoundedRectangle(cornerRadius: metrics.radius.xs - 0.5, style: .continuous)
            .fill(on ? palette[.accentFilled] : palette[.bgInset])
            .overlay {
                RoundedRectangle(cornerRadius: metrics.radius.xs - 0.5, style: .continuous)
                    .strokeBorder(palette[on ? .accentFilled : .borderControl], lineWidth: metrics.stroke.hairline)
            }
            .overlay {
                if state != false {
                    LumenSymbol(state == nil ? "minus" : "checkmark").font(.system(size: (size * 0.6).rounded(), weight: .bold))
                        .foregroundStyle(palette[.accentFilledForeground])
                }
            }
            .frame(width: size, height: size)
    }
}

/// Its content in a vertical scroll view in a window; bare offscreen, where golden images draw
/// every row (a scroll view renders blank there).
struct LumenScrollsLive<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    var body: some View {
        if rendersOffscreen { content } else { ScrollView { content } }
    }
}

/// A hairline separator in a one-line control bar, proportioned to its control height.
struct LumenInlineDivider: View {
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    var body: some View {
        Rectangle().fill(palette[.borderSubtle])
            .frame(width: metrics.stroke.hairline, height: metrics.layout.controlHeight * 0.6)
            .accessibilityHidden(true)
    }
}
