import AppKit
import SwiftUI
import LumenTokens

// Toolbar pieces. The toolbar stays native (`.toolbar { ToolbarItem … }`, customization, overflow,
// full-screen behavior); these are what go inside its items. A constant set of actions, as Mac
// convention expects: the cluster disables what doesn't apply rather than hiding it.

/// What the app is doing, for the activity status and the task cluster.
public enum LumenActivity: Equatable, Sendable {
    case idle(String = "Ready")
    /// `progress` from 0 to 1, or `nil` for indeterminate.
    case working(String, progress: Double? = nil)
    case succeeded(String)
    case failed(String)

    public var isBusy: Bool { if case .working = self { true } else { false } }

    var label: String {
        switch self {
        case .idle(let text), .working(let text, _), .succeeded(let text), .failed(let text): text
        }
    }
}

/// The project's identity at the leading edge of the toolbar: its tile, name and location. It
/// answers "what am I working on?" at a glance, as the project title does.
public struct LumenToolbarIdentity: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let hue: LumenToken

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenToolbarCompact) private var compact

    public init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken = .accent) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hue = hue
    }

    public var body: some View {
        // In the window toolbar: a 20 pt tile, a 13 pt semibold name over an
        // 11 pt subtitle, as the project title is.
        // No backlight in the toolbar (PRINCIPLES §7): the item's bounds can only clip it.
        HStack(spacing: metrics.spacing.s3) {
            LumenIconTile(systemImage, hue: hue, size: compact ? Self.compactTileSize : metrics.layout.tileMode)
                .lumenTileBacklight(false)
            VStack(alignment: .leading, spacing: compact ? -1 : 0) {
                Text(title).font(compact ? .system(size: Self.compactTitleSize, weight: .semibold) : metrics.typography.headline)
                    .foregroundStyle(palette[.toolbarForeground]).lineLimit(1)
                    .fixedSize()
                    .lumenNeverTruncates(title)
                if let subtitle {
                    // Capped, so a long location (a DerivedData path) shortens in the middle instead
                    // of widening the toolbar item and starving the status.
                    LumenCappedWidth(maxWidth: Self.subtitleMaxWidth) {
                        Text(subtitle).font(compact ? .system(size: Self.compactSubtitleSize) : metrics.typography.caption)
                            .foregroundStyle(palette[.toolbarSecondaryForeground])
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        // Its ideal width on both axes: a toolbar item proposes less than that (the system's item
        // capsule takes its own inset), which clipped the trailing text. The subtitle keeps its
        // own cap. A trailing inset to match the tile's leading one inside the item's capsule.
        .padding(.trailing, compact ? 0 : metrics.spacing.s2)
        .fixedSize()
        .modifier(LumenToolbarDimming())
        .accessibilityElement(children: .combine)
        .help([title, subtitle].compactMap(\.self).joined(separator: " — "))
    }

    /// The compact project title in the unified band: a 20 pt tile, a 13 pt semibold name over an
    /// 11 pt location (named here until `LumenMetrics` carries toolbar roles).
    static let compactTileSize: CGFloat = 20
    static let compactTitleSize: CGFloat = 13
    static let compactSubtitleSize: CGFloat = 11

    /// The widest the location subtitle gets before it shortens in the middle.
    static let subtitleMaxWidth: CGFloat = 240
}

/// Lays its one child out at most `maxWidth` wide, even under `.fixedSize()` (a toolbar item), where
/// a flexible frame would pass the unlimited proposal on and let the child run past it.
struct LumenCappedWidth<Content: View>: View {
    let maxWidth: CGFloat
    @ViewBuilder let content: Content

    var body: some View { CapLayout(maxWidth: maxWidth) { content } }

    private struct CapLayout: Layout {
        let maxWidth: CGFloat
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            return child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height))
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

/// The activity status in the middle of the toolbar: a capsule that says what's happening, with a
/// thin progress line while working. Status colors carry meaning; the capsule stays calm.
public struct LumenActivityStatus: View {
    private let activity: LumenActivity
    private let width: CGFloat

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ activity: LumenActivity, width: CGFloat = 300) {
        self.activity = activity
        self.width = width
    }

    private var tone: LumenToken {
        switch activity {
        case .idle: .fgSecondary
        case .working: .fgPrimary
        case .succeeded: .statusSuccess
        case .failed: .statusDanger
        }
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s3) {
            // A fixed leading slot, so the label starts at one x whichever mark leads it.
            ZStack { statusMark }.frame(width: metrics.iconSize.regular)
            Text(activity.label).font(metrics.typography.callout).foregroundStyle(palette[tone]).lineLimit(1).lumenNeverTruncates(activity.label)
            Spacer(minLength: 0)
            if case .working(_, let progress?) = activity {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(metrics.typography.caption.monospacedDigit()).foregroundStyle(palette[.fgSecondary])
            }
        }
        .padding(.horizontal, metrics.spacing.s4)
        // While a progress line shows, the text sits 1 pt higher so its descenders clear the line.
        .padding(.bottom, hasProgressLine ? 2 : 0)
        // `width` when there's room; narrower (its label truncating) in a tight bar, never clipped.
        .frame(minWidth: min(width, Self.minimumWidth), idealWidth: width, maxWidth: width, minHeight: 24, maxHeight: 24)
        .background(palette[.activityBackground], in: .capsule)
        .overlay(alignment: .bottom) {
            if case .working(_, let progress?) = activity {
                // An inset rounded track inside the capsule's bottom, not a stroke along its edge
                // (which read as a stray underline).
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette[.accent].opacity(0.18))
                        Capsule().fill(palette[.accent])
                            .frame(width: max(2, proxy.size.width * min(max(progress, 0), 1)))
                            .animation(metrics.motion.animation(metrics.motion.regularCurve, reduceMotion: reduceMotion), value: progress)
                    }
                    .frame(height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, metrics.spacing.s5)
                .padding(.bottom, 2)
            }
        }
        .overlay { Capsule(style: .circular).strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline) }
        // Grey and quiet in an inactive window, with the other toolbar pieces.
        .modifier(LumenToolbarDimming())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.label)
        .accessibilityValue({ if case .working(_, let p?) = activity { return "\(Int(p * 100)) percent" } else { return "" } }())
    }

    /// The narrowest the capsule gets (and, in the unified top bar, the narrowest it shows at).
    static let minimumWidth: CGFloat = 140

    private var hasProgressLine: Bool {
        if case .working(_, _?) = activity { true } else { false }
    }

    @ViewBuilder private var statusMark: some View {
            switch activity {
            case .idle:
                LumenSymbol("circle.fill").font(.system(size: metrics.layout.statusDot)).foregroundStyle(palette[.fgTertiary])
            case .working:
                // A pulsing accent dot: work in progress, without a spinner competing for attention.
                LumenSymbol("circle.fill")
                    .font(.system(size: metrics.layout.statusDot))
                    .foregroundStyle(palette[.accent])
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                    .accessibilityHidden(true)
            case .succeeded:
                LumenSymbol("checkmark.circle.fill").foregroundStyle(palette[.statusSuccess])
            case .failed:
                // Error = xmark, warning = triangle (PRINCIPLES §2: the shape carries the meaning); the
                // octagon is Lumen's one danger glyph (`xmark.circle` is clear and stop).
                LumenSymbol("xmark.octagon.fill").foregroundStyle(palette[.statusDanger])
            }
    }
}

/// One action in a task cluster.
public struct LumenTaskAction: Identifiable {
    public enum Role: Sendable { case normal, start, stop }
    public let id: String
    public let title: String
    public let systemImage: String
    public let role: Role
    public let shortcut: KeyboardShortcut?
    public let perform: @MainActor () -> Void
    /// The action's own color, as the build hammer has one; `nil` uses its role's (start green,
    /// stop red, others the toolbar's foreground).
    public private(set) var hue: LumenToken?

    public init(_ title: String, systemImage: String, role: Role = .normal, shortcut: KeyboardShortcut? = nil,
                perform: @escaping @MainActor () -> Void) {
        id = title
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.shortcut = shortcut
        self.perform = perform
    }

    /// An action in its own color.
    public init(_ title: String, systemImage: String, role: Role = .normal, hue: LumenToken, shortcut: KeyboardShortcut? = nil,
                perform: @escaping @MainActor () -> Void) {
        self.init(title, systemImage: systemImage, role: role, shortcut: shortcut, perform: perform)
        self.hue = hue
    }
}

/// The Tasks idea: the actions that start and stop work sit together with the live state, so
/// what is running and how to stop it are always one glance away. The set stays constant; actions
/// that don't apply are disabled, not hidden. In full color: build in its own hue, run
/// green, stop red. A disabled build or run keeps its color, dimmed (`disabledOpacity`); stop turns
/// gray while nothing runs, as is usual.
public struct LumenTaskCluster: View {
    private let actions: [LumenTaskAction]
    private let activity: LumenActivity

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ actions: [LumenTaskAction], activity: LumenActivity) {
        self.actions = actions
        self.activity = activity
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s1) {
            ForEach(actions) { action in
                let enabled = action.role == .stop ? activity.isBusy : !activity.isBusy || action.role == .normal
                // The color goes on the label: the button style's own foreground yields to it.
                Button(action: action.perform) {
                    Label { Text(action.title) } icon: {
                        LumenSymbol(action.systemImage)
                            .font(.system(size: metrics.layout.toolbarGlyphSize * Self.opticalScale(action.systemImage), weight: .regular))
                    }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(color(for: action, enabled: enabled))
                }
                .disabled(!enabled)
                .lumenFocusRing()
                .keyboardShortcut(action.shortcut)
                .help(action.title + (action.shortcut.map { " (\(LumenKeycap.text(for: $0)))" } ?? ""))
            }
        }
        .buttonStyle(LumenToolbarIconButtonStyle())
        // Build and run lose their color in an inactive window, as the panel toggles beside them do.
        .modifier(LumenToolbarDimming())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks")
    }

    /// A build (hammer) action's hue when it has none of its own, as the build hammer.
    static let buildHue: LumenToken = .hueOrange

    /// Per-glyph scale so build, run and stop read at one visual size: the hammer's diagonal fills a
    /// much larger box than the play triangle or the stop square at the same point size.
    static func opticalScale(_ systemImage: String) -> CGFloat {
        switch systemImage {
        case "hammer", "hammer.fill": 0.85
        case "play", "play.fill": 1.08
        default: 1
        }
    }

    private func color(for action: LumenTaskAction, enabled: Bool) -> Color {
        // Disabled buttons keep their color, as is usual do, except stop, which is gray while nothing
        // runs; the button style dims them once (not twice).
        if !enabled && action.role == .stop { return palette[.toolbarForeground] }
        if let hue = action.hue { return palette[hue] }
        switch action.role {
        case .start: return palette[.statusSuccess]
        case .stop: return palette[.statusDanger]
        // Build draws in its own hue even when the app passes none (§9: build, run and stop all in color).
        case .normal: return palette[action.systemImage.hasPrefix("hammer") ? Self.buildHue : .toolbarForeground]
        }
    }
}

// MARK: Hover plates and the panel icon button

/// The hover (and press) plate every top-bar button shares: the toolbar's own foreground at a low
/// alpha, so it reads the same on any title bar glow, lighter or darker, and at one strength
/// for the panel toggles, New Tab and the toolbar icon buttons.
struct LumenToolbarHoverPlate: View {
    let isHovered: Bool
    var isPressed = false

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// The plate's strength on hover and while pressed.
    static let hoverOpacity = 0.10
    static let pressedOpacity = 0.16

    var body: some View {
        RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
            .fill(palette[.toolbarForeground].opacity(isPressed ? Self.pressedOpacity : isHovered ? Self.hoverOpacity : 0))
    }
}

/// An icon button inside a pane, not the toolbar: pane headers, tab strips, status strips, cards,
/// settings rows. Its ink is the content's (`fg.secondary`, `fg.primary` on hover; `.accent` while
/// `isOn`), validated on the grounds panes use, where `.lumenToolbarIcon`'s `toolbar.foreground` is only checked against the
/// title bar. A `minimumHitTarget` (24 pt) square, a `bg.hover` plate at `hoverOpacity`, faded to
/// `disabledOpacity` when disabled. Add `.lumenFocusRing()` when it's a Tab stop.
public struct LumenPanelIconButtonStyle: ButtonStyle {
    private let isOn: Bool
    public init() { self.isOn = false }
    /// A pane-local toggle: `isOn` draws the glyph in `.accent`, with the same hit target and hover.
    public init(isOn: Bool) { self.isOn = isOn }

    public func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, isOn: isOn)
    }

    private struct Tile: View {
        let configuration: Configuration
        let isOn: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @State private var isHovered = false

        var body: some View {
            let lit = isEnabled && (isHovered || configuration.isPressed)
            configuration.label
                .font(.system(size: metrics.layout.paneActionGlyph))
                .foregroundStyle(palette[isOn ? .accent : lit ? .fgPrimary : .fgSecondary])
                .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
                .lumenIconOnlyControl()
                .background {
                    RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                        .fill(palette[configuration.isPressed ? .bgSelected : .bgHover])
                        .opacity(lit ? metrics.layout.hoverOpacity : 0)
                }
                .opacity(isEnabled ? 1 : metrics.layout.disabledOpacity)
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}

public extension ButtonStyle where Self == LumenPanelIconButtonStyle {
    /// A pane-local toggle (`LumenPanelIconButtonStyle(isOn:)`): the glyph draws in `.accent` while
    /// `isOn`, with the same hit target and hover treatment.
    static func lumenPanelIcon(isOn: Bool) -> LumenPanelIconButtonStyle { LumenPanelIconButtonStyle(isOn: isOn) }
    /// An icon button inside a pane (`LumenPanelIconButtonStyle`); `.lumenToolbarIcon` is for the toolbar.
    static var lumenPanelIcon: LumenPanelIconButtonStyle { LumenPanelIconButtonStyle() }
}
