import AppKit
import SwiftUI
import LumenTokens

// The welcome window: the one place a Lumen app spends its personality. Working surfaces stay quiet; this is the edge.

// MARK: Starfield

/// A quiet field of light drifting toward you from a vanishing point that leans toward the pointer.
/// It surges into streaks while `isSurging` (the primary action hovered), and holds a still frame
/// under Reduce Motion. Each app passes its own seed, so its field is its own.
public struct LumenStarfield: View {
    public var isSurging: Bool
    public var pointer: CGPoint?
    public var seed: UInt64
    public var starCount: Int
    /// Most stars are quiet text roles; one in eleven takes a color from `accents`.
    public var accents: [LumenToken]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lumenPalette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @State private var state = LumenStarfieldState()

    public init(isSurging: Bool = false, pointer: CGPoint? = nil, seed: UInt64 = 0x6C75_6D65_6E00_0001, starCount: Int = 240,
                accents: [LumenToken] = [.accent, .hueTeal, .huePink, .hueBlue]) {
        self.isSurging = isSurging
        self.pointer = pointer
        self.seed = seed
        self.starCount = starCount
        self.accents = accents
    }

    public var body: some View {
        // In light, quiet stars on white read as gray dust: they take the accent, softly, instead.
        let quiet = colorScheme == .dark
            ? [palette[.fgTertiary], palette[.fgTertiary], palette[.fgSecondary]]
            : [palette[.accent].opacity(0.35), palette[.accent].opacity(0.35), palette[.accent].opacity(0.55)]
        let colors = quiet + accents.map { palette[$0] }
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                state.advance(to: timeline.date.timeIntervalSinceReferenceDate, surging: isSurging && !reduceMotion)
                state.draw(in: &context, size: size, pointer: pointer, seed: seed, starCount: starCount,
                           streaks: !reduceMotion, colors: colors)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Frame-to-frame motion, kept in a reference type so easing the speed doesn't invalidate the view.
final class LumenStarfieldState {
    private var travel = 0.0
    private var speed = LumenStarfieldState.cruise
    private var lastTime: TimeInterval?

    static let cruise = 0.035
    static let surge = 0.55

    func advance(to time: TimeInterval, surging: Bool) {
        defer { lastTime = time }
        guard let lastTime else { return }
        let dt = min(max(time - lastTime, 0), 0.1)
        let target = surging ? Self.surge : Self.cruise
        speed += (target - speed) * min(1, (surging ? 5.0 : 2.2) * dt)   // quick to surge, gentle to settle
        travel += speed * dt
    }

    func draw(in context: inout GraphicsContext, size: CGSize, pointer: CGPoint?, seed: UInt64, starCount: Int,
              streaks: Bool, colors: [Color]) {
        guard size.width > 0, size.height > 0, colors.count > 3 else { return }
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let center = pointer.map { CGPoint(x: middle.x + ($0.x - middle.x) * 0.2, y: middle.y + ($0.y - middle.y) * 0.2) } ?? middle
        let reach = max(size.width, size.height) * 0.55
        var generator = LumenSeededGenerator(seed: seed)
        let surgeAmount = streaks ? max(0, min(1, (speed - Self.cruise) / (Self.surge - Self.cruise))) : 0
        for index in 0..<starCount {
            let x = Double.random(in: -1...1, using: &generator)
            let y = Double.random(in: -1...1, using: &generator)
            let phase = Double.random(in: 0..<1, using: &generator)
            let colorIndex = index % 11 == 0 ? Int.random(in: 3..<colors.count, using: &generator) : index % 3
            var depth = (phase - travel).truncatingRemainder(dividingBy: 1)
            if depth <= 0 { depth += 1 }
            depth = max(depth, 0.02)
            func project(_ z: Double) -> CGPoint { CGPoint(x: center.x + x / z * reach * 0.12, y: center.y + y / z * reach * 0.12) }
            let head = project(depth)
            guard head.x > -20, head.x < size.width + 20, head.y > -20, head.y < size.height + 20 else { continue }
            let nearness = 1 - depth
            // A calm zone around the middle keeps the app mark and title clean.
            let offset = hypot(head.x - middle.x, head.y - middle.y) / reach
            let calm = min(1, max(0, (offset - 0.12) / 0.33))
            let opacity = (0.12 + 0.6 * nearness * nearness) * (0.25 + 0.75 * calm * calm)
            let radius = 0.35 + 1.1 * nearness
            let color = colors[colorIndex].opacity(opacity)
            if surgeAmount > 0.02 {
                var path = Path()
                path.move(to: project(min(depth * (1 + 0.6 * surgeAmount), 1)))
                path.addLine(to: head)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: radius * 0.9, lineCap: .round))
            } else {
                context.fill(Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(color))
            }
        }
    }
}

/// SplitMix64: the same star layout on every launch and in every render.
public struct LumenSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: Welcome window

/// One action on the welcome window: New Project, Open…, Clone…
public struct LumenWelcomeAction: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let hue: LumenToken
    public let shortcut: KeyboardShortcut?
    /// Hovering the primary action makes the starfield surge.
    public let isPrimary: Bool
    public let perform: @MainActor () -> Void

    public init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken, shortcut: KeyboardShortcut? = nil,
                isPrimary: Bool = false, perform: @escaping @MainActor () -> Void) {
        id = title
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hue = hue
        self.shortcut = shortcut
        self.isPrimary = isPrimary
        self.perform = perform
    }
}

/// A recent document or project.
public struct LumenRecentItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Usually the abbreviated path (`~/Projects/Sample`).
    public let detail: String
    public let date: Date?
    public let systemImage: String
    public let hue: LumenToken

    public init(id: String? = nil, title: String, detail: String, date: Date? = nil, systemImage: String = "folder.fill",
                hue: LumenToken = .hueBlue) {
        self.id = id ?? detail + "/" + title
        self.title = title
        self.detail = detail
        self.date = date
        self.systemImage = systemImage
        self.hue = hue
    }
}

/// The welcome window's content: the app's mark over a starfield, its actions, and recent items.
/// Put it in a `Window` scene with a hidden title bar (see the README). Actions and recents are the
/// app's; Lumen supplies the look, motion, keyboard behavior and accessibility.
public struct LumenWelcomeView: View {
    private let appName: String
    private let version: String?
    private let tagline: String
    private let markSymbol: String
    private let markHue: LumenToken
    private let actions: [LumenWelcomeAction]
    private let recents: [LumenRecentItem]
    private let onOpenRecent: @MainActor (LumenRecentItem) -> Void
    private let showAtLaunch: Binding<Bool>?
    private let seed: UInt64

    @State private var surging = false
    @State private var pointer: CGPoint?
    @State private var hoveredRecent: LumenRecentItem.ID?
    @State private var keyboardRecent: LumenRecentItem.ID?
    @FocusState private var recentsFocused: Bool
    @State private var query = ""

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(appName: String, version: String? = nil, tagline: String, markSymbol: String, markHue: LumenToken = .accent,
                actions: [LumenWelcomeAction], recents: [LumenRecentItem] = [], showAtLaunch: Binding<Bool>? = nil,
                seed: UInt64? = nil, onOpenRecent: @escaping @MainActor (LumenRecentItem) -> Void = { _ in }) {
        self.appName = appName
        self.version = version
        self.tagline = tagline
        self.markSymbol = markSymbol
        self.markHue = markHue
        self.actions = actions
        self.recents = recents
        self.showAtLaunch = showAtLaunch
        // Each app's field differs: the seed comes from its name unless given.
        self.seed = seed ?? appName.unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        self.onOpenRecent = onOpenRecent
    }

    public var body: some View {
        HStack(spacing: 0) {
            hero.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            recentsPanel.frame(width: 300).frame(maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 440)
    }

    private var hero: some View {
        ZStack {
            VStack(spacing: metrics.spacing.s6) {
                VStack(spacing: metrics.spacing.s4) {
                    LumenIconTile(markSymbol, hue: markHue, size: metrics.layout.tileWelcome, label: "\(appName) icon")
                        .lumenGlow(.hero, color: palette[.welcomeGlow])
                    VStack(spacing: metrics.spacing.s1) {
                        Text(appName).font(metrics.typography.display).foregroundStyle(palette[.fgPrimary])
                        if let version {
                            Text("Version \(version)").font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                        }
                    }
                    .anchorPreference(key: WelcomeClearings.self, value: .bounds) { [$0] }
                    Text(tagline).font(metrics.typography.callout).foregroundStyle(palette[.fgSecondary])
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                        .anchorPreference(key: WelcomeClearings.self, value: .bounds) { [$0] }
                }
                VStack(spacing: metrics.spacing.s1) {
                    ForEach(actions) { action in actionRow(action) }
                }
                .frame(width: 300)
                .anchorPreference(key: WelcomeClearings.self, value: .bounds) { [$0] }
                if let showAtLaunch {
                    Toggle("Show this window when the app opens", isOn: showAtLaunch)
                        .toggleStyle(.lumenCheckbox)
                        .font(metrics.typography.caption)
                        .foregroundStyle(palette[.fgTertiary])
                }
            }
            .padding(metrics.spacing.s8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The stars keep clear of the tagline and the actions, fading out around them, so no dot
        // sits on text or shows through a card.
        .backgroundPreferenceValue(WelcomeClearings.self) { anchors in
            // The field runs under a hidden title bar, edge to edge, as the recents panel does.
            GeometryReader { proxy in
                palette[.welcomeBackground]
                // A soft glow behind the mark: light, the system's namesake.
                RadialGradient(colors: [palette[.welcomeGlow].opacity(0.22), palette[.welcomeGlow].opacity(0)],
                               center: .init(x: 0.5, y: 0.34), startRadius: 0, endRadius: 220)
                LumenStarfield(isSurging: surging, pointer: pointer, seed: seed)
                    .mask {
                        ZStack {
                            Rectangle()
                            ForEach(anchors.indices, id: \.self) { index in
                                let rect = proxy[anchors[index]].insetBy(dx: -metrics.spacing.s5, dy: -metrics.spacing.s4)
                                RoundedRectangle(cornerRadius: metrics.spacing.s6, style: .continuous)
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .blur(radius: metrics.spacing.s4)
                                    .blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    }
            }
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            if case .active(let location) = phase { pointer = location } else { pointer = nil }
        }
    }

    private func actionRow(_ action: LumenWelcomeAction) -> some View {
        WelcomeActionRow(action: action) { hovering in
            if action.isPrimary { surging = hovering }
        }
    }

    private var recentsPanel: some View {
        let shown = recents.filter { query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RECENT").font(metrics.typography.sectionLabel).tracking(0.5).foregroundStyle(palette[.fgSecondary])
                Spacer()
            }
            .padding(.horizontal, metrics.spacing.s5)
            .padding(.top, metrics.spacing.s8)
            .padding(.bottom, metrics.spacing.s3)
            if recents.count > 6 {
                LumenFilterField(text: $query, prompt: "Search recents")
                    .padding(.horizontal, metrics.spacing.s4)
                    .padding(.bottom, metrics.spacing.s3)
            }
            if shown.isEmpty {
                LumenEmptyState(systemImage: "clock", title: recents.isEmpty ? "Nothing recent yet" : "No matches",
                                message: recents.isEmpty ? "Projects you open appear here." : "Try a different name.")
            } else if shown.count <= 8 {
                // A short list needs no scroll view.
                VStack(spacing: metrics.spacing.s1) {
                    ForEach(shown) { item in recentRow(item) }
                }
                .modifier(RecentsKeyboard(ids: shown.map(\.id), cursor: $keyboardRecent, focused: $recentsFocused) { id in
                    shown.first { $0.id == id }.map(onOpenRecent)
                })
                .padding(.horizontal, metrics.spacing.s3)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: metrics.spacing.s1) {
                            ForEach(shown) { item in recentRow(item) }
                        }
                        .modifier(RecentsKeyboard(ids: shown.map(\.id), cursor: $keyboardRecent, focused: $recentsFocused) { id in
                            shown.first { $0.id == id }.map(onOpenRecent)
                        })
                        .padding(.horizontal, metrics.spacing.s3)
                    }
                    .onChange(of: keyboardRecent) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
        .background(palette[.welcomePanel])
        // Full height like the panel's ground (a background runs under the hidden title bar; an
        // overlay doesn't unless told), so the divider doesn't start below the title bar.
        .overlay(alignment: .leading) {
            Rectangle().fill(palette[.borderSubtle]).frame(width: metrics.stroke.hairline).ignoresSafeArea(edges: .top)
        }
    }

    private func recentRow(_ item: LumenRecentItem) -> some View {
        let hovered = hoveredRecent == item.id || (recentsFocused && keyboardRecent == item.id)
        return Button { onOpenRecent(item) } label: {
            LumenWelcomeRecentRow(item: item)
            .background(hovered ? palette[.bgHover] : .clear, in: .rect(cornerRadius: metrics.radius.md, style: .continuous))
            .lumenGroupFocusRing(recentsFocused && keyboardRecent == item.id, cornerRadius: metrics.radius.md)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hoveredRecent = $0 ? item.id : (hoveredRecent == item.id ? nil : hoveredRecent) }
        .help(item.detail)
        .accessibilityLabel("\(item.title), \(item.detail)")
    }
}

/// The welcome's text and actions, which the starfield keeps clear of.
private struct WelcomeClearings: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

/// The recents list as one keyboard stop: ↑/↓ move, Return opens.
private struct RecentsKeyboard: ViewModifier {
    let ids: [String]
    @Binding var cursor: String?
    var focused: FocusState<Bool>.Binding
    let open: (String) -> Void

    func body(content: Content) -> some View {
        content
            .lumenSelectionGroup(ids.map { Optional($0) }, selection: $cursor, columns: 1, focused: focused)
            .onKeyPress(.return) {
                guard let cursor, ids.contains(cursor) else { return .ignored }
                open(cursor)
                return .handled
            }
            .onChange(of: focused.wrappedValue) { _, isFocused in
                // A search can hide the item the cursor was on; start again at the top.
                if isFocused && !ids.contains(where: { $0 == cursor }) { cursor = ids.first }
            }
            .onChange(of: ids) { _, ids in
                if focused.wrappedValue && !ids.contains(where: { $0 == cursor }) { cursor = ids.first }
            }
    }
}

/// A welcome action: a tile, a title and subtitle, and its shortcut, on a carrier shape that
/// lights up on hover.
private struct WelcomeActionRow: View {
    let action: LumenWelcomeAction
    let onHover: (Bool) -> Void
    @State private var hovered = false
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action.perform) {
            HStack(spacing: metrics.spacing.s4) {
                LumenIconTile(action.systemImage, hue: action.hue, size: metrics.layout.tileHeader)
                // Every card is two lines tall, so a card without a subtitle matches its neighbors.
                ZStack(alignment: .leading) {
                    VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                        Text(verbatim: " ").font(metrics.typography.bodyEmphasized)
                        Text(verbatim: " ").font(metrics.typography.caption)
                    }
                    .hidden()
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                        Text(action.title).font(metrics.typography.bodyEmphasized).foregroundStyle(palette[.fgPrimary])
                        if let subtitle = action.subtitle {
                            Text(subtitle).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary])
                        }
                    }
                }
                Spacer(minLength: 0)
                if let shortcut = action.shortcut { LumenKeycap(shortcut) }
            }
            .padding(.horizontal, metrics.spacing.s4)
            .padding(.vertical, metrics.spacing.s3)
            // Opaque, so the fill doesn't drift down the column over the wash, and a raised
            // ground, so keycaps on it aren't holes. The primary action keeps an accent rim at
            // rest, not only on hover.
            .background(palette[hovered ? .bgHoverRaised : .bgElevated],
                        in: .rect(cornerRadius: metrics.radius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous)
                    // In Contrast the secondary rims are strong greys, so the primary takes the full accent
                    // to stay the most emphatic card (GB-36).
                    .strokeBorder(hovered ? palette[.borderFocus].opacity(0.6)
                                  : action.isPrimary ? palette[.accent].opacity(palette.isHighContrastTheme ? 1 : 0.45) : palette[.borderSubtle],
                                  lineWidth: metrics.stroke.hairline)
            }
            .lumenRaisedGround()
            .contentShape(.rect)
        }
        .buttonStyle(.lumenPlain).lumenFocusRing()
        .keyboardShortcut(action.shortcut)
        .onHover { hovering in
            withAnimation(metrics.motion.animation(metrics.motion.fastCurve, reduceMotion: reduceMotion)) { hovered = hovering }
            onHover(hovering)
        }
        .accessibilityLabel([action.title, action.subtitle].compactMap(\.self).joined(separator: ", "))
    }
}

// MARK: Inline welcome

/// The welcome as part of a window rather than a window of its own: what an empty workspace pane
/// shows before anything is open. The app's mark, a line about it, its actions and a few recent
/// items, in one centered column that scrolls when the pane is short and narrows with it. No
/// starfield: working windows stay quiet.
public struct LumenWelcomePanel: View {
    private let appName: String
    private let tagline: String?
    private let markSymbol: String
    private let markHue: LumenToken
    private let actions: [LumenWelcomeAction]
    private let recents: [LumenRecentItem]
    private let onOpenRecent: (LumenRecentItem) -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter recents: the first five are shown.
    public init(appName: String, tagline: String? = nil, markSymbol: String, markHue: LumenToken = .accent,
                actions: [LumenWelcomeAction], recents: [LumenRecentItem] = [],
                onOpenRecent: @escaping (LumenRecentItem) -> Void = { _ in }) {
        self.appName = appName
        self.tagline = tagline
        self.markSymbol = markSymbol
        self.markHue = markHue
        self.actions = actions
        self.recents = recents
        self.onOpenRecent = onOpenRecent
    }

    public var body: some View {
        // Scrolls only when the pane is too short to show it all.
        ViewThatFits(in: .vertical) {
            column.frame(maxHeight: .infinity)
            ScrollView { column }
        }
        .background(palette[.bgCanvas])
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to \(appName)")
    }

    private var column: some View {
            VStack(spacing: metrics.spacing.s6) {
                VStack(spacing: metrics.spacing.s3) {
                    LumenIconTile(markSymbol, hue: markHue, size: metrics.layout.tileHeroCompact)
                    Text(appName)
                        .font(metrics.typography.title2)
                        .foregroundStyle(palette[.fgPrimary])
                    if let tagline {
                        Text(tagline)
                            .font(metrics.typography.callout)
                            .foregroundStyle(palette[.fgSecondary])
                            .multilineTextAlignment(.center)
                    }
                }
                VStack(spacing: metrics.spacing.s2) {
                    ForEach(actions) { action in WelcomeActionRow(action: action, onHover: { _ in }) }
                }
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                        // Header, tiles and titles on the action cards' columns: the cards pad by `s4`.
                        LumenSectionHeader("Recent").padding(.horizontal, metrics.spacing.s4)
                        ForEach(recents.prefix(5)) { item in
                            Button { onOpenRecent(item) } label: {
                                LumenWelcomeRecentRow(item: item, inset: metrics.spacing.s4)
                            }
                            .buttonStyle(.plain)
                            .help(item.detail)
                        }
                    }
                }
            }
            .frame(maxWidth: 440)
            .padding(metrics.spacing.s6)
            .frame(maxWidth: .infinity)
    }
}

/// The same recent-document row in both welcome presentations.
private struct LumenWelcomeRecentRow: View {
    let item: LumenRecentItem
    /// The row's leading and trailing padding; `nil` is `s3`.
    var inset: CGFloat? = nil
    @State private var hovered = false
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.spacing.s4) {
            LumenIconTile(item.systemImage, hue: item.hue, size: metrics.layout.tileHeader)
            VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                Text(item.title).font(metrics.typography.body).foregroundStyle(palette[.fgPrimary])
                    .lineLimit(1).lumenNeverTruncates(item.title)
                Text(item.detail).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let date = item.date {
                Text(date, format: .relative(presentation: .named)).font(metrics.typography.caption)
                    .foregroundStyle(palette[.fgTertiary]).lineLimit(1).truncationMode(.tail)
                    .help(date.formatted(date: .long, time: .shortened))
            }
        }
        .padding(.horizontal, inset ?? metrics.spacing.s3)
        .padding(.vertical, metrics.spacing.s2)
        .background(hovered ? palette.hoverFill(metrics) : .clear, in: .rect(cornerRadius: metrics.radius.md, style: .continuous))
        .contentShape(.rect)
        .onHover { hovered = $0 }
    }
}
