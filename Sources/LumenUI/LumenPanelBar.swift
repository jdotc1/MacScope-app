import AppKit
import SwiftUI
import LumenTokens

// Headers for panels and sidebars, chosen for MacScope: a panel bar with one accent
// action and the rest quiet, a sidebar identity row, and a card of counts.

// MARK: Button styles

/// The one action a bar or pane leads with: a filled-accent capsule (`accent.filled`, deep in dark)
/// with its white foreground, control height, 13 pt semibold. Use at most one per bar; the rest are
/// `LumenQuietButtonStyle`. Disabled, it drops the accent for a neutral capsule (faded like every
/// disabled control), so its label stays legible rather than white on a pale accent.
public struct LumenPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlActiveState) private var activeState
        @State private var isHovered = false
        @Environment(\.lumenForcedHover) private var forcedHover   // hover states in tests

        var body: some View {
            configuration.label
                .font(metrics.typography.body.weight(.semibold))
                .foregroundStyle(palette[isEnabled ? .accentFilledForeground : .fgPrimary])
                .padding(.horizontal, metrics.spacing.s4)
                .frame(minHeight: max(metrics.layout.controlHeight, metrics.layout.minimumHitTarget))
                .background {
                    if isEnabled {
                        Capsule().fill(palette[.accentFilled].opacity(configuration.isPressed ? metrics.layout.pressedOpacity : (isHovered || forcedHover) ? 0.92 : 1))
                    } else {
                        Capsule().fill(palette[.bgInset])
                            .overlay { Capsule(style: .circular).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
                    }
                }
                .saturation(activeState == .inactive ? 0.4 : 1)
                .lumenDisabledFade(isEnabled)
                .contentShape(.capsule)
                .onHover { isHovered = $0 }
        }
    }
}

/// A secondary action beside a primary one: glyph and label in the secondary text color, brightening
/// on hover, with no fill, so the primary action stands alone.
public struct LumenQuietButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { Chrome(configuration: configuration) }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false
        @Environment(\.lumenForcedHover) private var forcedHover   // hover states in tests

        var body: some View {
            configuration.label
                .font(metrics.typography.body)
                .foregroundStyle(palette[(isHovered || forcedHover) && isEnabled ? .fgPrimary : .fgSecondary])
                .padding(.horizontal, metrics.spacing.s2)
                .frame(minWidth: metrics.layout.minimumHitTarget,
                       minHeight: max(metrics.layout.controlHeight, metrics.layout.minimumHitTarget))
                // The hover plate every Lumen button shows (as the icon buttons beside it do), the
                // one hover fill; pressed darkens it.
                .background(configuration.isPressed ? palette[.bgSelected]
                            : (isHovered || forcedHover) && isEnabled ? palette.hoverFill(metrics) : .clear,
                            in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
                .lumenDisabledFade(isEnabled)
                .contentShape(.rect)
                .onHover { isHovered = $0 }
        }
    }
}

public extension ButtonStyle where Self == LumenPrimaryButtonStyle {
    static var lumenPrimary: LumenPrimaryButtonStyle { LumenPrimaryButtonStyle() }
}

public extension ButtonStyle where Self == LumenQuietButtonStyle {
    static var lumenQuiet: LumenQuietButtonStyle { LumenQuietButtonStyle() }
}

// MARK: Panel bar

/// An action in a panel bar.
public struct LumenBarAction: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let isEnabled: Bool
    public let perform: () -> Void
    /// Set on the action's button, for UI tests.
    public var accessibilityIdentifier: String?

    public init(_ title: String, systemImage: String? = nil, isEnabled: Bool = true, perform: @escaping () -> Void) {
        id = title
        self.title = title
        self.systemImage = systemImage
        self.isEnabled = isEnabled
        self.perform = perform
    }

    /// The button's help tag, when it should say more than the title.
    public var help: String?

    /// - Parameter accessibilityIdentifier: set on the action's button, for UI tests.
    public init(_ title: String, systemImage: String? = nil, isEnabled: Bool = true, accessibilityIdentifier: String?,
                perform: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, isEnabled: isEnabled, perform: perform)
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    /// - Parameters:
    ///   - help: the button's help tag, when it should say more than the title.
    ///   - accessibilityIdentifier: set on the action's button, for UI tests.
    public init(_ title: String, systemImage: String? = nil, isEnabled: Bool = true, help: String?,
                accessibilityIdentifier: String? = nil, perform: @escaping () -> Void) {
        self.init(title, systemImage: systemImage, isEnabled: isEnabled, perform: perform)
        self.help = help
        self.accessibilityIdentifier = accessibilityIdentifier
    }
}

extension View {
    /// Sets an accessibility identifier only when there is one.
    @ViewBuilder func lumenAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier { accessibilityIdentifier(identifier) } else { self }
    }
}

/// The header of a panel or deck (MacScope's debugger): its tile and title, its state, then quiet
/// secondary actions, an optional accessory (transport controls, a scope pop-up) and at most one
/// primary action at the trailing edge. A state with a tone shows its mark (a dot; a cross for an
/// error, a triangle for a warning). When the bar is narrow the secondary actions drop to glyphs
/// first; only then do the state's words truncate (its mark stays); nothing is clipped.
public struct LumenPanelBar: View {
    private let title: String
    private let systemImage: String
    private let hue: LumenToken
    private let status: LumenStripStatus?
    private let secondary: [LumenBarAction]
    private let primary: LumenBarAction?
    private let accessory: AnyView?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String, systemImage: String, hue: LumenToken = .accent, status: String? = nil,
                secondary: [LumenBarAction] = [], primary: LumenBarAction? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        self.status = status.map { LumenStripStatus($0, tone: .fgTertiary) }
        self.secondary = secondary
        self.primary = primary
        accessory = nil
    }

    /// - Parameters:
    ///   - statusLabel: the panel's state with its tone (`.statusDanger` for "Backend unavailable").
    ///   - accessory: controls between the secondary actions and the primary one, such as a
    ///     debugger's transport buttons (`LumenToolbarIconButtonStyle`, spaced, not separated by pipes).
    public init<Accessory: View>(_ title: String, systemImage: String, hue: LumenToken = .accent,
                                 statusLabel: LumenStripStatus?, secondary: [LumenBarAction] = [],
                                 primary: LumenBarAction? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        status = statusLabel
        self.secondary = secondary
        self.primary = primary
        self.accessory = Accessory.self == EmptyView.self ? nil : AnyView(accessory())
    }

    /// A state with its tone, and no accessory.
    public init(_ title: String, systemImage: String, hue: LumenToken = .accent, statusLabel: LumenStripStatus?,
                secondary: [LumenBarAction] = [], primary: LumenBarAction? = nil) {
        self.init(title, systemImage: systemImage, hue: hue, statusLabel: statusLabel, secondary: secondary,
                  primary: primary) { EmptyView() }
    }

    public var body: some View {
        // The state is a value people read: the secondary actions drop to glyphs before its words
        // shorten, and they shorten only when even the glyphs leave no room.
        ViewThatFits(in: .horizontal) {
            bar(labels: true, statusTruncates: false)
            bar(labels: false, statusTruncates: false)
            bar(labels: false, statusTruncates: true)
        }
        .padding(.horizontal, metrics.spacing.s4)
        .frame(minHeight: metrics.layout.paneHeaderHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([title, status?.spokenLabel ?? status?.title].compactMap(\.self).joined(separator: ", "))
    }

    private func bar(labels: Bool, statusTruncates: Bool) -> some View {
        HStack(spacing: metrics.spacing.s3) {
            LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileHeader)
            Text(title).font(metrics.typography.headline).foregroundStyle(palette[.fgPrimary]).fixedSize()
            if let status {
                LumenStatusLabel(status, truncates: statusTruncates)
                    .font(metrics.typography.callout.weight(.medium))
                    .layoutPriority(-1)
            }
            Spacer(minLength: metrics.spacing.s3)
            actions(labels: labels)
        }
    }

    private func actions(labels: Bool) -> some View {
        HStack(spacing: metrics.spacing.s2) {
            ForEach(secondary) { action in
                Button(action: action.perform) {
                    HStack(spacing: metrics.spacing.s2) {
                        if let symbol = action.systemImage { LumenSymbol(symbol) }
                        if labels || action.systemImage == nil { Text(action.title).lineLimit(1).lumenNeverTruncates(action.title) }
                    }
                }
                .buttonStyle(.lumenQuiet)
                .lumenIconOnlyControl(action.title, isActive: !labels && action.systemImage != nil)
                .lumenFocusRing()
                .disabled(!action.isEnabled)
                .help(action.help ?? action.title)
                .accessibilityLabel(action.title)
                .lumenAccessibilityIdentifier(action.accessibilityIdentifier)
            }
            if let accessory {
                accessory
            }
            if let primary {
                Button(primary.title, action: primary.perform)
                    .buttonStyle(.lumenPrimary)
                    .lumenFocusRing(cornerRadius: metrics.radius.pill)
                    .disabled(!primary.isEnabled)
                    .lumenAccessibilityIdentifier(primary.accessibilityIdentifier)
                    .fixedSize()
            }
        }
        .fixedSize()
    }
}

// MARK: Sidebar header and stats

/// The identity at the top of a sidebar: a tile, a title and a subtitle (MacScope's Project /
/// MacScope Workspace).
public struct LumenSidebarHeader: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let hue: LumenToken

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken = .accent) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hue = hue
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s3) {
            LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileHeader)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(metrics.typography.headline).foregroundStyle(palette[.sidebarForeground]).lineLimit(1)
                    .lumenNeverTruncates(title)
                if let subtitle {
                    Text(subtitle).font(metrics.typography.caption).foregroundStyle(palette[.sidebarSecondaryForeground])
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One count in a stats card.
public struct LumenStat: Identifiable, Hashable, Sendable {
    public let label: String
    public let value: String
    /// The exact value, shown as help and spoken, when `value` is abbreviated ("98.8M").
    public var fullValue: String?
    public var id: String { label }

    public init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    /// A count: in full up to six digits, then in compact notation ("98.8M") with the exact count as
    /// help, so a large count never cuts off (a cut number is wrong data, not short text).
    public init(_ label: String, count: Int) {
        if abs(count) >= Self.compactThreshold {
            self.init(label, value: count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3))))
            fullValue = count.formatted()
        } else {
            self.init(label, value: count.formatted())
        }
    }

    /// Counts from here up are shown in compact notation.
    public static let compactThreshold = 1_000_000
}

/// A few counts side by side in a card (MacScope's targets, functions, cross-references): each value
/// large, its label small beneath, in equal columns. Values shrink rather than clip in a narrow sidebar.
public struct LumenStatsCard: View {
    private let stats: [LumenStat]

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ stats: [LumenStat]) {
        self.stats = stats
    }


    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            ForEach(stats) { stat in
                LumenStatCell(stat).frame(maxWidth: .infinity)
            }
        }
        .lumenCard(padding: metrics.spacing.s3)
        // Values shrink for width only: a short container doesn't scale them down.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One count: its value large (`typography.stat`), its label small beneath. The cell of
/// `LumenStatsCard`, and of any summary that shows counts (the inspector summary), so they agree.
/// Values shrink rather than clip in a narrow column; an abbreviated value shows in full as help.
public struct LumenStatCell: View {
    private let stat: LumenStat
    /// The value's font; `nil` uses `typography.stat`. A denser summary passes a smaller role.
    private let valueFont: Font?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ stat: LumenStat, valueFont: Font? = nil) {
        self.stat = stat
        self.valueFont = valueFont
    }

    /// How far values and labels may shrink to fit a narrow sidebar (the truncation checks allow it).
    static let valueScale: CGFloat = 0.6
    static let labelScale: CGFloat = 0.8

    public var body: some View {
        VStack(spacing: 1) {
            Text(stat.value)
                .font(valueFont ?? metrics.typography.stat)
                .foregroundStyle(palette[.fgPrimary])
                .lineLimit(1)
                .minimumScaleFactor(Self.valueScale)
                .lumenNeverTruncates(stat.value, minimumScale: Self.valueScale)
            Text(stat.label)
                .font(metrics.typography.caption)
                .foregroundStyle(palette[.fgTertiary])
                .lineLimit(1)
                .minimumScaleFactor(Self.labelScale)
                .lumenNeverTruncates(stat.label, minimumScale: Self.labelScale)
        }
        .modifier(LumenOptionalHelp(stat.fullValue.map { "\($0) \(stat.label)" }))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stat.fullValue ?? stat.value) \(stat.label)")
    }
}

// MARK: Toolbar groups

/// Toolbar buttons that belong together (back and forward; Open, Ask, Go to, Browsers) in one quiet
/// capsule, so a bar of icons reads as a few clear groups. Put
/// `LumenToolbarIconButtonStyle` buttons inside; give each a help tag naming it.
public struct LumenToolbarGroup<Content: View>: View {
    private let content: Content
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 2) { content }
            .padding(2)
            .background(palette[.bgHover].opacity(metrics.layout.hoverOpacity), in: .rect(cornerRadius: metrics.radius.md, style: .continuous))
            .modifier(LumenToolbarDimming())
            .accessibilityElement(children: .contain)
    }
}

/// Back and forward, as a toolbar group: chevrons with help tags, dimmed when there's nowhere to go.
/// Shortcuts stay with the menu bar (Go › Back ⌘[, Forward ⌘]).
public struct LumenNavigationButtons: View {
    private let canGoBack: Bool
    private let canGoForward: Bool
    private let back: () -> Void
    private let forward: () -> Void

    public init(canGoBack: Bool, canGoForward: Bool, back: @escaping () -> Void, forward: @escaping () -> Void) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.back = back
        self.forward = forward
    }

    public var body: some View {
        LumenToolbarGroup {
            Button("Back", systemImage: "chevron.left", action: back)
                .labelStyle(.iconOnly).buttonStyle(LumenToolbarIconButtonStyle()).lumenIconOnlyControl("Back").lumenFocusRing()
                .disabled(!canGoBack).help("Back")
            Button("Forward", systemImage: "chevron.right", action: forward)
                .labelStyle(.iconOnly).buttonStyle(LumenToolbarIconButtonStyle()).lumenIconOnlyControl("Forward").lumenFocusRing()
                .disabled(!canGoForward).help("Forward")
        }
    }
}

// MARK: Empty inspector

public extension View {
    /// While `isEmpty`, an inspector shows one centered message in place of its sections (no
    /// paragraph repeated in every section). The sections return with a selection.
    func lumenInspectorEmptyState(_ isEmpty: Bool, title: String = "Nothing selected", message: String,
                                  systemImage: String = "cursorarrow.rays") -> some View {
        modifier(LumenInspectorEmptyModifier(isEmpty: isEmpty, title: title, message: message, systemImage: systemImage))
    }

    /// The same, with one next step under the message, shown as a link ("Open a Binary…").
    func lumenInspectorEmptyState(_ isEmpty: Bool, title: String = "Nothing selected", message: String,
                                  systemImage: String = "cursorarrow.rays", actionTitle: String,
                                  action: @escaping () -> Void) -> some View {
        modifier(LumenInspectorEmptyModifier(isEmpty: isEmpty, title: title, message: message, systemImage: systemImage,
                                             actionTitle: actionTitle, action: action))
    }
}

private struct LumenInspectorEmptyModifier: ViewModifier {
    let isEmpty: Bool
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(\.lumenPalette) private var palette

    func body(content: Content) -> some View {
        if isEmpty {
            // The pane empty state as is: it already insets itself s8 (no second padding).
            LumenEmptyState(title, message: message, systemImage: systemImage, actionTitle: actionTitle, action: action)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette[.inspectorBackground])
        } else {
            content
        }
    }
}
