import AppKit
import SwiftUI
import LumenTokens

// Data views: notification cards, outline depth, history rows with ref
// pills and avatars, comparison headers, a diff navigator, a floating status pill and a minimap.

// MARK: Notices

/// A notification an app raises over its window (an extension found a repository, an update is ready).
public struct LumenNotice: Identifiable {
    public let id: String
    /// Who raised it ("Extension: Linter"), in quiet text above the title.
    public let source: String?
    public let title: String
    public let message: String?
    public let systemImage: String
    public let hue: LumenToken
    /// The one accent action; running it dismisses the notice.
    public let primary: LumenBarAction?
    /// A quiet action beside it ("Not Now"); running it dismisses the notice.
    public let secondary: LumenBarAction?

    public init(id: String = UUID().uuidString, source: String? = nil, title: String, message: String? = nil,
                systemImage: String = "bell", hue: LumenToken = .hueGraphite, primary: LumenBarAction? = nil,
                secondary: LumenBarAction? = nil) {
        self.id = id
        self.source = source
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.hue = hue
        self.primary = primary
        self.secondary = secondary
    }
}

/// A notification card: a tile, its source, title and message, then a quiet action
/// and one accent action under the text, with × to dismiss.
public struct LumenNoticeCard: View {
    private let notice: LumenNotice
    private let onDismiss: () -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ notice: LumenNotice, onDismiss: @escaping () -> Void) {
        self.notice = notice
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s3) {
            HStack(alignment: .top, spacing: metrics.spacing.s3) {
                LumenIconTile(notice.systemImage, hue: notice.hue, size: metrics.layout.tileRowDetailed)
                VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                    if let source = notice.source {
                        Text(source).font(.caption2).foregroundStyle(palette[.fgTertiary]).lineLimit(1).truncationMode(.tail).help(source)
                    }
                    Text(notice.title).font(metrics.typography.callout.weight(.semibold)).foregroundStyle(palette[.fgPrimary])
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = notice.message {
                        Text(message).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary])
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // The text takes the card's width up to the dismiss button, not a share of it with a spacer.
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .font(.system(size: metrics.iconSize.micro, weight: .bold)).foregroundStyle(palette[.fgTertiary])
                    .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget).contentShape(.rect)
                    .lumenIconOnlyControl("Dismiss")
                    // The full hit area laid out in the old 18 pt slot: the glyph stays at the card's corner.
                    .padding(-(metrics.layout.minimumHitTarget - 18) / 2)
                    .help("Dismiss")
            }
            if notice.primary != nil || notice.secondary != nil {
                HStack(spacing: metrics.spacing.s2) {
                    Spacer(minLength: 0)
                    if let secondary = notice.secondary {
                        Button(secondary.title) { secondary.perform(); onDismiss() }.buttonStyle(.lumenQuiet).fixedSize()
                    }
                    if let primary = notice.primary {
                        Button(primary.title) { primary.perform(); onDismiss() }.buttonStyle(.lumenPrimary).fixedSize()
                    }
                }
            }
        }
        .padding(metrics.spacing.s4)
        .frame(width: 340, alignment: .leading)
        .background(palette[.bgElevated], in: .rect(cornerRadius: metrics.radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.xl, style: .continuous).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline)
        }
        .lumenElevation(.popover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([notice.source, notice.title, notice.message].compactMap(\.self).joined(separator: ", "))
    }
}

public extension View {
    /// Stacks notices at the window's top trailing corner, newest on top; each slides in and leaves
    /// when its action runs or it's dismissed.
    func lumenNotices(_ notices: Binding<[LumenNotice]>) -> some View {
        modifier(LumenNoticeStack(notices: notices))
    }
}

private struct LumenNoticeStack: ViewModifier {
    @Binding var notices: [LumenNotice]
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: metrics.spacing.s2) {
                ForEach(notices.reversed()) { notice in
                    LumenNoticeCard(notice) { notices.removeAll { $0.id == notice.id } }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(metrics.spacing.s4)
            .animation(metrics.motion.animation(metrics.motion.standardCurve, reduceMotion: reduceMotion), value: notices.map(\.id))
        }
    }
}

// MARK: Outline depth

/// How an outline lists its items.
public enum LumenOutlineMode: String, CaseIterable, Sendable {
    case tree, list
}

/// An outline's toolbar: tree or flat list, how deep the tree opens as level pills
/// 1 to `maximumDepth`, and alphabetical sorting.
public struct LumenOutlineControls: View {
    @Binding private var mode: LumenOutlineMode
    @Binding private var depth: Int
    @Binding private var sortsAlphabetically: Bool
    private let maximumDepth: Int

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(mode: Binding<LumenOutlineMode>, depth: Binding<Int>, sortsAlphabetically: Binding<Bool>, maximumDepth: Int = 4) {
        _mode = mode
        _depth = depth
        _sortsAlphabetically = sortsAlphabetically
        self.maximumDepth = max(maximumDepth, 1)
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            toggle("Show as a tree", "list.bullet.indent", isOn: mode == .tree) { mode = .tree }
            toggle("Show as a list", "list.bullet", isOn: mode == .list) { mode = .list }
            // The pill switcher's look (§10, one segmented selection): a well track with a control
            // edge, the chosen depth a filled accent capsule under white, 24 pt overall.
            HStack(spacing: metrics.spacing.s1) {
                ForEach(1...maximumDepth, id: \.self) { level in
                    let selected = level == depth
                    Button { depth = level } label: {
                        Text(verbatim: String(level))
                            .font(metrics.typography.body.weight(selected ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(palette[selected ? .accentFilledForeground : .fgSecondary])
                            .frame(minWidth: depthSegmentHeight, minHeight: depthSegmentHeight)
                            .background(selected ? palette[.accentFilled] : .clear, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.lumenBare)
                    .help("Open \(level) \(level == 1 ? "level" : "levels")")
                    .accessibilityLabel("Depth \(level)")
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(metrics.layout.pillRim)
            .background {
                Capsule().fill(palette[.bgInset])
                    .overlay { Capsule(style: .circular).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
            }
            // Depth means nothing in a flat list: the one disabled treatment, once (not `.plain`'s
            // own fade under a literal opacity, which compounded to about 26%).
            .disabled(mode == .list)
            .lumenDisabledFade(mode != .list)
            Spacer(minLength: 0)
            toggle(sortsAlphabetically ? "Sorted alphabetically" : "In document order", "textformat.abc", isOn: sortsAlphabetically) {
                sortsAlphabetically.toggle()
            }
        }
        .padding(.horizontal, metrics.spacing.s3)
        .frame(height: metrics.layout.subheaderHeight)
    }

    private var depthSegmentHeight: CGFloat { metrics.layout.controlHeight - 2 * metrics.layout.pillRim }

    private func toggle(_ title: String, _ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LumenSymbol(symbol)
        }
        .buttonStyle(.lumenPanelIcon(isOn: isOn))
        .lumenIconOnlyControl(title)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}

/// Opening an outline to a depth: which items to collapse.
public enum LumenOutlineDepth {
    /// The ids to collapse so a tree shows `depth` levels: every item at depth `depth - 1` or deeper
    /// (zero-based) that has children. Items are in document order with their depth.
    public static func collapsedIDs(_ items: [(id: String, depth: Int)], showing depth: Int) -> Set<String> {
        var collapsed = Set<String>()
        for (index, item) in items.enumerated() where item.depth >= depth - 1 {
            if index + 1 < items.count, items[index + 1].depth > item.depth { collapsed.insert(item.id) }
        }
        return collapsed
    }
}

// MARK: History

/// What a ref names, for its color.
public enum LumenRefKind: Sendable, Hashable {
    /// Where the working copy is: orange.
    case head
    /// A local branch: green.
    case branch
    /// A remote branch: violet.
    case remote
    case tag
    /// Any other color.
    case custom(LumenToken)

    public var token: LumenToken {
        switch self {
        case .head: .hueOrange
        case .branch: .hueGreen
        case .remote: .hueViolet
        case .tag: .hueYellow
        case .custom(let token): token
        }
    }
}

/// A branch, tag or HEAD as a tinted capsule in its kind's color.
public struct LumenRefPill: View {
    private let name: String
    private let kind: LumenRefKind
    private let onAccent: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// On an accent selection the pill is drawn in `fgOnAccent` (text and a faint fill at this alpha):
    /// a yellow or violet pill on the violet selection is unreadable.
    static let onAccentFillAlpha = 0.18
    /// The pill's tint off the selection.
    static let fillAlpha = 0.14

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lumenStore) private var store

    public init(_ name: String, kind: LumenRefKind) {
        self.init(name, kind: kind, onAccent: false)
    }

    init(_ name: String, kind: LumenRefKind, onAccent: Bool) {
        self.name = name
        self.kind = kind
        self.onAccent = onAccent
    }

    public var body: some View {
        let ink = onAccent ? LumenToken.menuHighlightForeground : kind.token
        // The label reads at 4.5:1 on its tinted fill in every theme (orange HEAD measured 2.5:1), and
        // at 7:1 under Increase Contrast or in a high-contrast theme (4.7:1 in Contrast dark).
        let text = onAccent ? palette[ink] : {
            let theme = store.theme(for: store.registry.surface(of: ink))
            let isHigh = palette.isHighContrastTheme || LumenTileContrast.isHigh(contrast, store: store)
            let appearance = LumenAppearance(isDark: colorScheme == .dark, isHighContrast: isHigh)
            let readable = LumenTileColors.pillText(ink, fillAlpha: Self.fillAlpha, over: .bgCanvas,
                                                     appearance: appearance, store: store)
            let color = isHigh ? Self.strengthened(readable.ink, on: readable.fill, isDark: appearance.isDark) : readable.ink
            return Color(nsColor: color.nsColor(in: theme.colorSpace))
        }()
        HStack(spacing: metrics.spacing.s2) {
            if kind == .tag { LumenSymbol("tag.fill").font(.system(size: metrics.iconSize.micro)) }
            Text(name).font(metrics.typography.captionEmphasized).lineLimit(1).lumenNeverTruncates(name)
        }
        .foregroundStyle(text)
        // The one chip spec: no capsule and no ring of its own, like every other chip.
        .lumenChip(palette[ink].opacity(onAccent ? Self.onAccentFillAlpha : Self.fillAlpha))
        .fixedSize()
        .accessibilityLabel(name)
    }

    /// The contrast a pill's text reaches in high contrast (WCAG AAA for small text).
    static let highContrastText = 7.0

    /// `ink` moved further toward white (dark) or black (light) until it reads at
    /// `highContrastText` on `fill`, or as far as it goes.
    static func strengthened(_ ink: LumenColor, on fill: LumenColor, isDark: Bool) -> LumenColor {
        let toward = isDark ? LumenColor(red: 1, green: 1, blue: 1) : LumenColor(red: 0, green: 0, blue: 0)
        var result = ink
        var amount = 0.0
        while result.contrastRatio(against: fill) < highContrastText, amount < 1 {
            amount = min(1, amount + 0.05)
            result = toward.composited(alpha: amount, over: ink)
        }
        return result
    }
}

/// A person as an initial on a rounded square in a hue picked from their name, so the same person
/// keeps the same color.
public struct LumenAvatar: View {
    private let name: String
    private let size: CGFloat
    private let onAccent: Bool
    @Environment(\.lumenPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lumenStore) private var store

    public init(_ name: String, size: CGFloat = 18) {
        self.init(name, size: size, onAccent: false)
    }

    /// - Parameter onAccent: on an accent selection: the initial in the accent on an `fgOnAccent`
    ///   square, since a hue square (violet on violet) can vanish into the selection.
    init(_ name: String, size: CGFloat = 18, onAccent: Bool) {
        self.name = name
        self.size = size
        self.onAccent = onAccent
    }

    static let hues: [LumenToken] = [.hueTeal, .hueBlue, .hueViolet, .huePink, .hueOrange, .hueGreen, .hueIndigo]

    /// A stable hue for `name` (the same on every launch, unlike `hashValue`).
    static func hue(for name: String) -> LumenToken {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return hues[sum % hues.count]
    }

    public var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?"))
            .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
            .foregroundStyle(onAccent ? palette[.menuHighlight]
                             : LumenTileColors.inkColor(on: Self.hue(for: name),
                                                        appearance: LumenAppearance(isDark: colorScheme == .dark, isHighContrast: contrast == .increased),
                                                        store: store))
            .frame(width: size, height: size)
            .background(palette[onAccent ? .menuHighlightForeground : Self.hue(for: name)], in: .rect(cornerRadius: size * 0.22, style: .continuous))
            .help(name)
            .accessibilityLabel(name)
    }
}

/// A commit as a row: a rail of nodes and lines down the leading edge, the
/// message with its short hash and ref pills under it, then the time and author.
public struct LumenHistoryRow: View {
    private let message: String
    private let hash: String
    private let refs: [(String, LumenRefKind)]
    private let time: String
    private let author: String
    private let isFirst: Bool
    private let isLast: Bool
    private let isSelected: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenCodeFont) private var codeFont

    /// - Parameters:
    ///   - isFirst, isLast: where the row sits, so the rail stops at the ends.
    public init(message: String, hash: String, refs: [(String, LumenRefKind)] = [], time: String, author: String,
                isFirst: Bool = false, isLast: Bool = false, isSelected: Bool = false) {
        self.message = message
        self.hash = hash
        self.refs = refs
        self.time = time
        self.author = author
        self.isFirst = isFirst
        self.isLast = isLast
        self.isSelected = isSelected
    }

    /// The rail above the node, and the node's diameter.
    private static let railTop: CGFloat = 8
    private static let node: CGFloat = 10

    public var body: some View {
        // On the selected row the lane yields to the selection: it takes the row's on-accent ink, so a
        // blue line never runs through the accent fill.
        let lane = palette[isSelected ? .menuHighlightForeground : .hueBlue]
        HStack(alignment: .top, spacing: metrics.spacing.s3) {
            // The rail down to the node; the rest of the lane is drawn behind the row (below), so it
            // runs to the row's bottom edge without making the row grow to fill its container.
            VStack(spacing: 0) {
                Rectangle().fill(lane).frame(width: 2, height: Self.railTop).opacity(isFirst ? 0 : 1)
                Circle().strokeBorder(lane, lineWidth: 2).background(Circle().fill(palette[isSelected ? .menuHighlight : .bgCanvas]))
                    .frame(width: Self.node, height: Self.node)
            }
            .frame(width: Self.node)
            VStack(alignment: .leading, spacing: metrics.spacing.s2) {
                Text(message).font(metrics.typography.callout).foregroundStyle(palette[isSelected ? .menuHighlightForeground : .fgPrimary])
                    .lineLimit(1).truncationMode(.tail).help(message)
                // Refs wrap under the hash in a narrow sidebar instead of running out of the row.
                LumenFlowLayout(spacing: metrics.spacing.s2, lineSpacing: metrics.spacing.s1) {
                    Text(hash).font((codeFont ?? .standard).font(sizeDelta: -2)).foregroundStyle(palette[isSelected ? .menuHighlightForeground : .fgTertiary])
                    ForEach(Array(refs.enumerated()), id: \.offset) { _, ref in LumenRefPill(ref.0, kind: ref.1, onAccent: isSelected) }
                }
            }
            .padding(.top, 2)
            .layoutPriority(-1)
            Spacer(minLength: metrics.spacing.s2)
            Text(time).font(metrics.typography.caption).foregroundStyle(palette[isSelected ? .menuHighlightForeground : .fgTertiary]).fixedSize().padding(.top, 4)
            LumenAvatar(author, onAccent: isSelected).padding(.top, 2)
        }
        .padding(.horizontal, metrics.spacing.s3)
        .frame(minHeight: density.detailedRowHeight(in: metrics.layout), alignment: .top)
        .background(alignment: .topLeading) {
            Rectangle().fill(lane).frame(width: 2)
                .padding(.top, Self.railTop + Self.node)
                .padding(.leading, metrics.spacing.s3 + (Self.node - 2) / 2)
                .opacity(isLast ? 0 : 1)
        }
        // The filled family's inset rounded selection, as menus, completion and master-detail lists
        // draw it (§10), not a full-bleed square band.
        .background(isSelected ? palette[.menuHighlight] : .clear, in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        .padding(.horizontal, metrics.spacing.s2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(message), \(hash), \(refs.map(\.0).joined(separator: ", ")), \(time), \(author)")
    }
}

// MARK: Comparison

/// One side of a comparison: what it shows ("Current Version", "Latest Commit") and its color.
public struct LumenComparisonSide {
    public let title: String
    public let tone: LumenToken
    /// Other versions to show on this side, as a menu.
    public let choices: [LumenBarAction]

    public init(_ title: String, tone: LumenToken, choices: [LumenBarAction] = []) {
        self.title = title
        self.tone = tone
        self.choices = choices
    }
}

/// The header over a side-by-side comparison: each side's version as a tinted capsule in its
/// color (a chevron when it opens a menu of others), each at the leading edge of its half, and a
/// detail (the commit's message) after the trailing one.
public struct LumenComparisonHeader: View {
    private let leading: LumenComparisonSide
    private let trailing: LumenComparisonSide
    private let detail: String?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lumenStore) private var store

    public init(leading: LumenComparisonSide, trailing: LumenComparisonSide, detail: String? = nil) {
        self.leading = leading
        self.trailing = trailing
        self.detail = detail
    }

    public var body: some View {
        // Halves start at their leading edges, so the leading capsule lines up with the column's content.
        HStack(spacing: metrics.spacing.s3) {
            capsule(leading).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: metrics.spacing.s2) {
                capsule(trailing)
                if let detail {
                    // Two caption lines fit the subheader, so a message wraps before it's cut.
                    Text(detail).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary]).lineLimit(2).truncationMode(.tail).help(detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: metrics.layout.subheaderHeight)
    }

    /// The tint behind a side's capsule.
    static let fillAlpha = 0.16

    /// The side's capsule: a tint of its color, with the color as text pushed just far enough to read
    /// at 4.5:1 on it (saturated color stays on small things: PRINCIPLES §2).
    private func capsuleColors(_ tone: LumenToken) -> (ink: Color, fill: Color) {
        let theme = store.theme(for: store.registry.surface(of: tone))
        let readable = LumenTileColors.pillText(tone, fillAlpha: Self.fillAlpha, over: .bgCanvas,
                                                 appearance: LumenAppearance(isDark: colorScheme == .dark, isHighContrast: contrast == .increased),
                                                 store: store)
        return (Color(nsColor: readable.ink.nsColor(in: theme.colorSpace)), palette[tone].opacity(Self.fillAlpha))
    }

    @ViewBuilder private func capsule(_ side: LumenComparisonSide) -> some View {
        let colors = capsuleColors(side.tone)
        let label = HStack(spacing: metrics.spacing.s2) {
            // A 24 pt pop-up: 13 pt text, as every one-line control (§10).
            Text(side.title).font(metrics.typography.body.weight(.semibold))
            if !side.choices.isEmpty { LumenSymbol("chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)) }
        }
        .foregroundStyle(colors.ink)
        .padding(.horizontal, metrics.spacing.s3)
        .frame(height: metrics.layout.controlHeight)
        .background(colors.fill, in: .capsule)
        .overlay { Capsule(style: .circular).strokeBorder(palette[side.tone].opacity(0.45), lineWidth: metrics.stroke.hairline) }
        .fixedSize()
        if side.choices.isEmpty {
            label
        } else {
            LumenMenuButton {
                ForEach(side.choices) { choice in Button(choice.title, action: choice.perform) }
            } label: { label }
        }
    }
}

/// Steps through a comparison's changes: ‹ "2 of 5" › with an ignore-whitespace toggle, in a
/// floating capsule.
public struct LumenDiffNavigator: View {
    private let status: String
    @Binding private var ignoresWhitespace: Bool
    private let onPrevious: () -> Void
    private let onNext: () -> Void
    private let hasChanges: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter status: "2 of 5", or "No changes".
    public init(status: String, hasChanges: Bool = true, ignoresWhitespace: Binding<Bool>, onPrevious: @escaping () -> Void,
                onNext: @escaping () -> Void) {
        self.status = status
        self.hasChanges = hasChanges
        _ignoresWhitespace = ignoresWhitespace
        self.onPrevious = onPrevious
        self.onNext = onNext
    }

    public var body: some View {
        HStack(spacing: metrics.spacing.s2) {
            Button("Previous Change", systemImage: "chevron.left", action: onPrevious).disabled(!hasChanges).lumenDisabledFade(hasChanges)
            Text(status).font(metrics.typography.caption.monospacedDigit()).foregroundStyle(palette[.fgSecondary]).fixedSize()
            Button("Next Change", systemImage: "chevron.right", action: onNext).disabled(!hasChanges).lumenDisabledFade(hasChanges)
            // The whitespace toggle is a setting, set apart from the pager, so its glyph doesn't read as part of "2 of 5".
            LumenInlineDivider()
            // A toggle named for what it does; its state is the value (and the lit glyph).
            Button("Ignore Whitespace", systemImage: "space") { ignoresWhitespace.toggle() }
                .foregroundStyle(palette[ignoresWhitespace ? .accent : .fgTertiary])
                .help(ignoresWhitespace ? "Ignoring whitespace changes; click to show them" : "Showing whitespace changes; click to ignore them")
                .accessibilityValue(ignoresWhitespace ? "On" : "Off")
                .accessibilityAddTraits(.isToggle)
        }
        .labelStyle(.iconOnly)
        // Bare, not `.plain`: `.plain` fades a disabled label itself, a second disabled look.
        .buttonStyle(.lumenBare)
        .font(.system(size: metrics.iconSize.xsmall, weight: .semibold))
        .foregroundStyle(palette[.fgSecondary])
        .padding(.horizontal, metrics.spacing.s3)
        .frame(height: metrics.layout.controlHeight)
        .background(palette[.bgElevated].opacity(0.92), in: .capsule)
        .overlay { Capsule(style: .circular).strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
    }
}

// MARK: Floating status

public extension View {
    /// Floats a status pill at the bottom trailing corner, over the content:
    /// `content` while it fits, `folded` (fewer items, an overflow menu) when the view is narrow.
    func lumenFloatingStatus<Content: View, Folded: View>(@ViewBuilder content: () -> Content,
                                                          @ViewBuilder folded: () -> Folded) -> some View {
        modifier(LumenFloatingStatus(content: content(), folded: folded()))
    }
}

private struct LumenFloatingStatus<Status: View, Folded: View>: ViewModifier {
    let content: Status
    let folded: Folded
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    func body(content view: Content) -> some View {
        view.overlay(alignment: .bottomTrailing) {
            ViewThatFits(in: .horizontal) {
                pill(content)
                pill(folded)
            }
            .padding(metrics.spacing.s2)
        }
    }

    private func pill(_ items: some View) -> some View {
        HStack(spacing: metrics.spacing.s4) { items }
            .font(metrics.typography.caption)
            .foregroundStyle(palette[.fgSecondary])
            .padding(.horizontal, metrics.spacing.s4)
            .frame(height: metrics.layout.controlHeight)
            .background(palette[.bgCanvas].opacity(0.88), in: .capsule)
            .overlay { Capsule(style: .circular).strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline) }
            .fixedSize()
    }
}

// MARK: Minimap

/// A document in miniature down the editor's trailing edge: one bar per line, as
/// long as the line and in its color, with the visible part highlighted. Drag or click to scroll.
public struct LumenMinimap: View {
    private let lineLengths: [Int]
    private let lineTokens: [LumenToken]?
    @Binding private var viewport: ClosedRange<Double>

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @State private var dragOffset: Double?

    /// - Parameters:
    ///   - lineLengths: each line's length in characters.
    ///   - lineTokens: each line's main syntax color; `nil` draws all in the secondary text color.
    ///   - viewport: the visible part, as fractions of the document (0…1).
    public init(lineLengths: [Int], lineTokens: [LumenToken]? = nil, viewport: Binding<ClosedRange<Double>>) {
        self.lineLengths = lineLengths
        self.lineTokens = lineTokens
        _viewport = viewport
    }

    /// The viewport moved to centre on `fraction`, keeping its size within 0…1.
    static func viewport(centredOn fraction: Double, size: Double) -> ClosedRange<Double> {
        let size = min(max(size, 0), 1)
        let lower = min(max(fraction - size / 2, 0), 1 - size)
        return lower...(lower + size)
    }

    public var body: some View {
        GeometryReader { proxy in
            let lineHeight = min(3, proxy.size.height / CGFloat(max(lineLengths.count, 1)))
            let documentHeight = lineHeight * CGFloat(lineLengths.count)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    for (index, length) in lineLengths.enumerated() where length > 0 {
                        let width = min(CGFloat(length) * 1.2, size.width - 6)
                        let rect = CGRect(x: 3, y: CGFloat(index) * lineHeight, width: width, height: max(lineHeight - 1, 1))
                        let token = lineTokens.flatMap { index < $0.count ? $0[index] : nil } ?? .fgSecondary
                        context.fill(Path(rect), with: .color(palette[token].opacity(0.55)))
                    }
                }
                Rectangle()
                    .fill(palette[.fgPrimary].opacity(0.08))
                    .overlay { Rectangle().strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline) }
                    .frame(height: max(documentHeight * CGFloat(viewport.upperBound - viewport.lowerBound), 8))
                    .offset(y: documentHeight * CGFloat(viewport.lowerBound))
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard documentHeight > 0 else { return }
                let size = viewport.upperBound - viewport.lowerBound
                viewport = Self.viewport(centredOn: Double(value.location.y / documentHeight), size: size)
            })
        }
        .frame(width: 80)
        .accessibilityElement()
        .accessibilityLabel("Minimap")
        .accessibilityValue("Showing \(Int(viewport.lowerBound * 100)) to \(Int(viewport.upperBound * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let size = viewport.upperBound - viewport.lowerBound
            let centre = (viewport.lowerBound + viewport.upperBound) / 2 + (direction == .increment ? size : -size)
            viewport = Self.viewport(centredOn: centre, size: size)
        }
    }
}
