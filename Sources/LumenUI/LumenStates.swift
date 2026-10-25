import AppKit
import SwiftUI
import LumenTokens

// What a pane says when it isn't simply showing content: an inline banner above it, loading, an
// error with a way forward (empty is `LumenEmptyState`), and the pane layout the three share. Quiet, in the
// status colors the validator checks, and never wider than the pane they're in.

/// A status's look: its color, its tint, and its symbol.
public enum LumenTone: Sendable, CaseIterable {
    case info, success, warning, danger

    var foreground: LumenToken {
        switch self {
        case .info: .statusInfo
        case .success: .statusSuccess
        case .warning: .statusWarning
        case .danger: .statusDanger
        }
    }

    var background: LumenToken {
        switch self {
        case .info: .statusInfoBackground
        case .success: .statusSuccessBackground
        case .warning: .statusWarningBackground
        case .danger: .statusDangerBackground
        }
    }

    var systemImage: String {
        switch self {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }

    var spokenName: String {
        switch self {
        case .info: "Note"
        case .success: "Done"
        case .warning: "Warning"
        case .danger: "Error"
        }
    }
}

// MARK: Card

public extension View {
    /// A card: this content on `panel.group` with a `panel.groupBorder` hairline, for grouped
    /// content and state panels. With `padding: 0` the content is clipped to the card's corners,
    /// so edge-to-edge strips, bands and selections end inside its hairline instead of past it.
    func lumenCard(padding: CGFloat? = nil, cornerRadius: CGFloat? = nil) -> some View {
        modifier(LumenCardModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

private struct LumenCardModifier: ViewModifier {
    let padding: CGFloat?
    let cornerRadius: CGFloat?
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? metrics.radius.md
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            // Only flush content reaches the corners; padded content keeps its focus rings whole.
            if padding == 0 {
                content.lumenRaisedGround().background(palette[.panelGroup], in: shape).clipShape(shape)
            } else {
                content.lumenRaisedGround().padding(padding ?? metrics.spacing.s5).background(palette[.panelGroup], in: shape)
            }
        }
        .overlay { shape.strokeBorder(palette[.panelGroupBorder], lineWidth: metrics.stroke.hairline) }
    }
}

// MARK: Compact control

public extension View {
    /// The quiet chrome behind small inline controls (a scope menu, a segmented filter, a count) in a
    /// bar or header: an opaque fill with a hairline. `prominent` sets it on the inset tone.
    func lumenCompactControl(prominent: Bool = false) -> some View {
        modifier(LumenCompactControlModifier(prominent: prominent))
    }
}

private struct LumenCompactControlModifier: ViewModifier {
    let prominent: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.xs, style: .continuous)
        content
            // Opaque themed fills, so nothing tints Midnight's navy (and Reduce Transparency has nothing to undo).
            .background(palette[prominent ? .bgInset : .bgElevated], in: shape)
            .overlay { shape.strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline) }
    }
}

// MARK: Tag colors

/// The color labels people put on things (Finder's tags, MacScope's row colors), drawn from the hue
/// family so they follow the theme instead of fixed system colors.
public enum LumenTagColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, blue, purple, gray

    public var id: Self { self }
    public var title: String { rawValue.capitalized }

    /// The hue the tag draws with.
    public var hue: LumenToken {
        switch self {
        case .red: .hueRed
        case .orange: .hueOrange
        case .yellow: .hueYellow
        case .green: .hueGreen
        case .blue: .hueBlue
        case .purple: .hueViolet
        case .gray: .hueGraphite
        }
    }

    /// How strongly a tag tints a whole row.
    public static let rowTintOpacity = 0.18
}

public extension View {
    /// Tints a row with a tag's color (18%), under its selection and hover fills.
    func lumenTagTint(_ tag: LumenTagColor?) -> some View {
        modifier(LumenTagTintModifier(tag: tag))
    }
}

private struct LumenTagTintModifier: ViewModifier {
    let tag: LumenTagColor?
    @Environment(\.lumenPalette) private var palette
    func body(content: Content) -> some View {
        content.background(tag.map { palette[$0.hue].opacity(LumenTagColor.rowTintOpacity) } ?? .clear)
    }
}

// MARK: Banner

/// A one- or two-line notice across the top of a pane: what happened, in a status tone, with an
/// optional action and a close button. The action moves under the message when the pane is narrow.
public struct LumenBanner: View {
    private let tone: LumenTone
    private let title: String?
    private let message: String
    private let systemImage: String?
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let onDismiss: (() -> Void)?
    private let spokenPrefix: String?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameters:
    ///   - title: a bold lead-in ("Analysis stopped"), or `nil` for the message alone.
    ///   - systemImage: replaces the tone's symbol (a glyph name works too).
    ///   - onDismiss: shows a close button.
    ///   - spokenPrefix: what VoiceOver says first; the tone's name ("Warning") by default. An app
    ///     keeping its existing wording passes it ("Issue").
    public init(_ message: String, title: String? = nil, tone: LumenTone = .warning, systemImage: String? = nil,
                actionTitle: String? = nil, action: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil,
                spokenPrefix: String? = nil) {
        self.spokenPrefix = spokenPrefix
        self.tone = tone
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s3) {
                symbol
                text.layoutPriority(1)
                Spacer(minLength: metrics.spacing.s2)
                actionButton
                closeButton
            }
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s3) {
                symbol
                VStack(alignment: .leading, spacing: metrics.spacing.s2) {
                    text
                    actionButton
                }
                Spacer(minLength: 0)
                closeButton
            }
        }
        // One height for every one-line banner, with or without an action or close button.
        .frame(minHeight: metrics.layout.minimumHitTarget)
        .padding(.horizontal, metrics.spacing.s4)
        .padding(.vertical, metrics.spacing.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette[tone.background], in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                .strokeBorder(palette[tone.foreground].opacity(0.36), lineWidth: metrics.stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(spokenPrefix ?? tone.spokenName): \([title, message].compactMap(\.self).joined(separator: ". "))")
    }

    private var symbol: some View {
        LumenSymbol(systemImage ?? tone.systemImage)
            .font(metrics.typography.callout.weight(.semibold))
            .foregroundStyle(palette[tone.foreground])
            .accessibilityHidden(true)
    }

    private var text: some View {
        ((title.map { Text("\($0)  ").fontWeight(.semibold) } ?? Text("")) + Text(message))
            .font(metrics.typography.callout)
            .foregroundStyle(palette[.fgPrimary])
            .lumenWrapsWithoutTruncating()
    }

    @ViewBuilder private var actionButton: some View {
        if let actionTitle, let action {
            Button(actionTitle, action: action)
                .buttonStyle(BannerActionStyle(edge: palette[tone.foreground].opacity(0.36)))
                .lumenFocusRing()
                .fixedSize()
        }
    }

    @ViewBuilder private var closeButton: some View {
        if let onDismiss {
            Button(action: onDismiss) {
                // The glyph in a 24 pt hit area (PRINCIPLES §7).
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .font(.system(size: metrics.iconSize.xsmall, weight: .bold))
                    .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
                    .contentShape(.rect)
            }
                .foregroundStyle(palette[.fgSecondary])
                .buttonStyle(.lumenPlain)
                .lumenIconOnlyControl("Close")
                .lumenFocusRing()
                .help("Close")
        }
    }
}

/// A banner's action: neutral, so it never brings the accent onto a status color (an accent-tinted
/// Reanalyze clashed with the amber warning). The raised surface with the banner's own edge color.
private struct BannerActionStyle: ButtonStyle {
    let edge: Color

    func makeBody(configuration: Configuration) -> some View { ActionLabel(configuration: configuration, edge: edge) }

    private struct ActionLabel: View {
        let configuration: Configuration
        let edge: Color
        @Environment(\.lumenPalette) private var palette
        @Environment(\.lumenMetrics) private var metrics
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(metrics.typography.body.weight(.medium))
                .foregroundStyle(palette[.fgPrimary])
                .padding(.horizontal, metrics.spacing.s4)
                .frame(height: metrics.layout.controlHeight)   // a push button: one control height
                .background(palette[configuration.isPressed ? .bgSelected : .bgElevated],
                            in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                        .strokeBorder(edge, lineWidth: metrics.stroke.hairline)
                }
                .lumenDisabledFade(isEnabled)
        }
    }
}

// MARK: Loading and error

/// A pane that's working on something: a spinner (or a progress bar when the amount done is known),
/// what it's doing, and an optional Cancel that Escape also triggers.
public struct LumenLoadingState: View {
    private let title: String
    private let message: String?
    private let progress: Double?
    private let cancelTitle: String
    private let onCancel: (() -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameters:
    ///   - progress: 0…1 when the amount done is known; `nil` shows a spinner.
    ///   - onCancel: shows Cancel, which Escape also triggers, for work that can stop. Leave it out for
    ///     work that can't: no Cancel appears and Escape does nothing here.
    public init(_ title: String, message: String? = nil, progress: Double? = nil, cancelTitle: String = "Cancel",
                onCancel: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.progress = progress
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
    }

    public var body: some View {
        // The pane empty state's layout (no card), so empty, loading and error swap in place.
        LumenStatePaneLayout {
            if let progress {
                // Centered in the 32 pt mark slot, so the title sits where the spinner's, the empty
                // glyph's and the error mark's titles do: the states swap in place.
                LumenProgressBar(progress).frame(maxWidth: metrics.layout.progressMaxWidth).frame(height: metrics.iconSize.hero)
            } else {
                // Lumen's ring, which draws offscreen too (the native spinner was blank in goldens),
                // in the empty state's 32 pt glyph slot.
                LumenProgressRing(progress: nil)
                    .frame(width: metrics.iconSize.hero, height: metrics.iconSize.hero)
                    .accessibilityLabel("Loading")
            }
            LumenStateText(title: title, message: message)
            if let onCancel {
                // The pane states' one action look: a link. Escape still cancels.
                LumenStateLink(cancelTitle, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(progress.map { "\(title), \(Int(($0 * 100).rounded())) percent" } ?? "\(title), loading")
    }
}

/// A pane that couldn't do its job: what failed, why, what to try, and a way to try again.
public struct LumenErrorState: View {
    private let title: String
    private let message: String
    private let recovery: String?
    private let retryTitle: String
    private let onRetry: (() -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameters:
    ///   - recovery: what the person can do ("Check the file still exists, then try again").
    ///   - onRetry: shows Try again, as the pane states' one link.
    public init(_ title: String, message: String, recovery: String? = nil, retryTitle: String = "Try again",
                onRetry: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.recovery = recovery
        self.retryTitle = retryTitle
        self.onRetry = onRetry
    }

    public var body: some View {
        // The pane empty state's layout (no card): its 32 pt glyph slot holds the danger mark, the
        // recovery joins the body, and Try again is the one link (Return still triggers it).
        LumenStatePaneLayout {
            LumenSymbol("xmark.octagon.fill")
                .font(.system(size: metrics.iconSize.hero, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(palette[.statusDanger])
                .frame(height: metrics.iconSize.hero)
                .accessibilityHidden(true)
            LumenStateText(title: title, message: message, recovery: recovery)
            if let onRetry {
                LumenStateLink(retryTitle, action: onRetry)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(title). \(message)")
    }
}

/// Where loading, error and empty states sit in their pane.
public enum LumenStatePlacement: Sendable {
    /// Centered (the default): a state alone in its pane.
    case center
    /// At the top: states side by side (a dashboard row) share a top edge whatever their heights.
    case top
}

extension EnvironmentValues {
    @Entry var lumenStatePlacement: LumenStatePlacement = .center
}

public extension View {
    /// Where the loading, error and empty states inside sit in their panes.
    func lumenStatePlacement(_ placement: LumenStatePlacement) -> some View {
        environment(\.lumenStatePlacement, placement)
    }
}

/// The pane layout empty, loading and error states share (no card: one surface per pane, §8): a
/// 32 pt mark, the text block and at most one link, s4 apart, inset s8, centered or at the top of the
/// pane (`lumenStatePlacement`).
struct LumenStatePaneLayout<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenStatePlacement) private var placement

    var body: some View {
        VStack(spacing: metrics.spacing.s4) { content }
            .padding(metrics.spacing.s8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: placement == .top ? .top : .center)
    }
}

// MARK: Status label

/// A state at the end of a row or bar ("Ready", "Running", "Backend unavailable"): its mark in the
/// tone (a dot; a cross for an error, a triangle for a warning) and its word. It never truncates:
/// it keeps its width and reports itself to the truncation checks if squeezed, so a status is never
/// cut to "R". The text takes the surrounding font; set one to match the row.
public struct LumenStatusLabel: View {
    private let status: LumenStripStatus
    private var truncates = false

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter tone: `.statusSuccess`, `.statusWarning`, `.statusDanger`, `.statusInfo` or
    ///   `.fgTertiary` (neutral).
    public init(_ title: String, tone: LumenToken = .fgTertiary) {
        status = LumenStripStatus(title, tone: tone)
    }

    public init(_ status: LumenStripStatus) {
        self.status = status
    }

    /// For a bar whose state gives way first: the words may end in an ellipsis; the mark stays.
    init(_ status: LumenStripStatus, truncates: Bool) {
        self.status = status
        self.truncates = truncates
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            mark
            text
        }
        .help(status.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spokenLabel ?? status.title)
        .accessibilityValue(status.spokenValue ?? "")
        .lumenAccessibilityIdentifier(status.accessibilityIdentifier)
    }

    @ViewBuilder private var text: some View {
        let label = Text(status.title).foregroundStyle(palette[ink]).lineLimit(1)
        if truncates {
            label.truncationMode(.tail)
        } else {
            label.fixedSize().lumenNeverTruncates(status.title)
        }
    }

    /// Error and warning words take their tone; the rest stay quiet beside a colored mark.
    private var ink: LumenToken {
        switch status.tone {
        case .statusDanger, .statusWarning: status.tone
        default: .fgSecondary
        }
    }

    @ViewBuilder private var mark: some View {
        switch status.tone {
        case .statusDanger:
            LumenSymbol("xmark.octagon.fill").font(.system(size: metrics.iconSize.small, weight: .semibold))
                .foregroundStyle(palette[status.tone]).accessibilityHidden(true)
        case .statusWarning:
            LumenSymbol("exclamationmark.triangle.fill").font(.system(size: metrics.iconSize.small, weight: .semibold))
                .foregroundStyle(palette[status.tone]).accessibilityHidden(true)
        default:
            Circle().fill(palette[status.tone]).frame(width: metrics.layout.statusDot, height: metrics.layout.statusDot).accessibilityHidden(true)
        }
    }
}

/// The pane states' text block: a centered headline title and a callout body at most 320 pt wide
/// that wraps and never truncates (an error's recovery is a second paragraph of the body).
struct LumenStateText: View {
    let title: String
    let message: String?
    var recovery: String?
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.spacing.s2) {
            Text(title)
                .font(metrics.typography.headline)
                .foregroundStyle(palette[.fgPrimary])
                .multilineTextAlignment(.center)
                .lumenWrapsWithoutTruncating()
            ForEach(Array([message, recovery].compactMap(\.self).enumerated()), id: \.offset) { _, paragraph in
                // Even lines, so a message never ends on one orphaned word.
                LumenBalancedWrapLayout {
                    Text(paragraph)
                        .font(metrics.typography.callout)
                        .foregroundStyle(palette[.fgSecondary])
                        .multilineTextAlignment(.center)
                }
                    .frame(maxWidth: metrics.layout.stateMessageMaxWidth)
                    .lumenWrapsWithoutTruncating()
            }
        }
    }
}

// MARK: Progress

/// A thin progress line in the accent on a quiet track, for panes, rows and cards: the same line the
/// toolbar's activity status draws. `nil` shows a short segment sliding across (still under Reduce
/// Motion).
public struct LumenProgressBar: View {
    private let value: Double?
    private let height: CGFloat

    @Environment(\.lumenPalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    /// - Parameter value: 0…1, or `nil` when the amount done isn't known.
    public init(_ value: Double?, height: CGFloat = 4) {
        self.value = value
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette[.bgInset])
                if let value {
                    Capsule().fill(palette[.accent])
                        .frame(width: max(height, proxy.size.width * min(max(value, 0), 1)))
                } else {
                    Capsule().fill(palette[.accent])
                        .frame(width: proxy.size.width * 0.3)
                        .offset(x: (proxy.size.width * 0.7) * (reduceMotion ? 0.5 : phase))
                }
            }
        }
        .frame(height: height)
        .clipShape(.capsule)
        // Keyed on whether the amount is known, not on appearing: a bar that turns indeterminate
        // after it appeared starts sliding, and one that becomes determinate stops.
        .task(id: value == nil && !reduceMotion) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { phase = 0 }
            guard value == nil, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 1 }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(value.map { "\(Int(($0 * 100).rounded())) percent" } ?? "In progress")
    }
}

