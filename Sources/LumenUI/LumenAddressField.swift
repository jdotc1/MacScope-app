import AppKit
import SwiftUI
import LumenTokens

// An address field and an empty-workspace hero, chosen for MacScope.

/// A field for a memory address: monospaced, with the `0x` prefix fixed in the accent so only hex digits
/// are typed, and an accent Go button (Return works too). Anything that isn't hex is refused as it's
/// typed; an address that doesn't parse shows a red hint instead of going.
public struct LumenAddressField: View {
    @Binding private var text: String
    private let prompt: String
    private let prefix: String
    private let hint: String?
    private let onGo: (UInt64) -> Void
    private let drawsStatic: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen
    @FocusState private var focused: Bool
    @State private var invalid = false

    /// - Parameters:
    ///   - text: the hex digits after the prefix (a pasted `0x…` loses its prefix).
    ///   - hint: the line under the field ("Hex address, or select an instruction.").
    ///   - onGo: the parsed address, on Go or Return.
    public init(text: Binding<String>, prompt: String = "100000f50", prefix: String = "0x", hint: String? = nil,
                onGo: @escaping (UInt64) -> Void) {
        self.init(text: text, prompt: prompt, prefix: prefix, hint: hint, drawsStatic: false, onGo: onGo)
    }

    /// For golden images, where text fields can't draw: the text as plain text.
    init(text: Binding<String>, prompt: String, prefix: String, hint: String?, drawsStatic: Bool, onGo: @escaping (UInt64) -> Void) {
        _text = text
        self.prompt = prompt
        self.prefix = prefix
        self.hint = hint
        self.onGo = onGo
        self.drawsStatic = drawsStatic
    }

    /// The address `digits` names, or `nil`: hex only, at most 16 digits.
    static func parse(_ digits: String) -> UInt64? {
        let trimmed = digits.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 16 else { return nil }
        return UInt64(trimmed, radix: 16)
    }

    /// `input` as the field keeps it: a leading `0x` dropped, only hex digits, at most 16.
    static func sanitize(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("0x") { value.removeFirst(2) }
        return String(value.filter(\.isHexDigit).prefix(16))
    }

    public var body: some View {
        // What the field shows: the digits as the field keeps them, even when an app set `text` to
        // "0x…" itself (the prefix showed twice).
        let digits = Self.sanitize(text)
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            HStack(spacing: metrics.spacing.s2) {
                HStack(spacing: 0) {
                    // The prefix dims with the prompt while the field is empty, so an empty field
                    // never reads as a typed address.
                    Text(prefix).foregroundStyle(digits.isEmpty ? palette[.fgTertiary] : palette[.accent])
                    // Lumen's field input: the prompt drawn by Lumen, the digits in the code face.
                    LumenFieldInput(text: drawsStatic ? .constant(digits) : $text, prompt: prompt,
                                    font: (codeFont ?? .standard).font(weight: .medium), focus: $focused, onSubmit: go)
                        .environment(\.lumenRendersOffscreen, drawsStatic || rendersOffscreen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onAppear { if !drawsStatic, digits != text { text = digits } }
                        .onChange(of: text) { _, value in
                            let clean = Self.sanitize(value)
                            if clean != value { text = clean }
                            invalid = false
                        }
                }
                .font((codeFont ?? .standard).font(weight: .medium))
                .padding(.horizontal, metrics.spacing.s3)
                // Lumen's field chrome at the one-line control height, so the field
                // takes the raised well on a sheet in dark and meets Go's edges.
                .frame(height: metrics.layout.controlHeight)
                .lumenChrome(.field, focused: focused && !invalid)
                .overlay {
                    if invalid {
                        RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous)
                            .strokeBorder(palette[.statusDanger], lineWidth: metrics.stroke.regular)
                    }
                }
                Button("Go", action: go)
                    .buttonStyle(.lumenPrimary)
                    .lumenFocusRing(cornerRadius: metrics.radius.pill)
                    .disabled(digits.isEmpty)
                    .fixedSize()
            }
            if invalid {
                Text("That isn’t a hex address.").font(metrics.typography.caption).foregroundStyle(palette[.statusDanger])
            } else if let hint {
                Text(hint).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary])
                    .lumenWrapsWithoutTruncating()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address")
    }

    private func go() {
        let digits = Self.sanitize(text)
        guard let address = Self.parse(digits) else {
            invalid = !digits.isEmpty
            return
        }
        onGo(address)
    }
}

// MARK: Empty hero

/// What an empty workspace shows (MacScope's "No binary open"): the app's mark glowing over a quiet
/// starfield, a title and one sentence, one accent primary action with quiet secondary ones, and a
/// few recent items. Scrolls only when the pane is too short; the starfield stays still under Reduce
/// Motion.
public struct LumenEmptyHero: View {
    private let title: String
    private let message: String?
    private let systemImage: String
    private let hue: LumenToken
    private let primary: LumenBarAction
    private let secondary: [LumenBarAction]
    private let recents: [LumenRecentItem]
    private let recentsTitle: String
    private let onOpenRecent: (LumenRecentItem) -> Void
    private let showsStarfield: Bool
    private var primaryIsDefault = true
    @State private var pointer: CGPoint?
    @State private var surging = false
    private var identifiers: (container: String?, recents: String?) = (nil, nil)

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String, message: String? = nil, systemImage: String, hue: LumenToken = .accent,
                primary: LumenBarAction, secondary: [LumenBarAction] = [],
                recents: [LumenRecentItem] = [], recentsTitle: String = "Recent",
                onOpenRecent: @escaping (LumenRecentItem) -> Void = { _ in }, showsStarfield: Bool = true) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.hue = hue
        self.primary = primary
        self.secondary = secondary
        self.recents = recents
        self.recentsTitle = recentsTitle
        self.onOpenRecent = onOpenRecent
        self.showsStarfield = showsStarfield
    }

    /// - Parameters:
    ///   - primaryIsDefault: whether Return runs the primary action. Turn it off when the window has
    ///     other fields Return belongs to.
    ///   - identifiers: accessibility identifiers for the hero (stable at every size, scrolling or
    ///     not) and the recents card, for UI tests. Actions take theirs from `LumenBarAction`.
    public init(_ title: String, message: String? = nil, systemImage: String, hue: LumenToken = .accent,
                primary: LumenBarAction, secondary: [LumenBarAction] = [],
                recents: [LumenRecentItem] = [], recentsTitle: String = "Recent",
                onOpenRecent: @escaping (LumenRecentItem) -> Void = { _ in }, showsStarfield: Bool = true,
                primaryIsDefault: Bool, identifiers: (container: String?, recents: String?) = (nil, nil)) {
        self.init(title, message: message, systemImage: systemImage, hue: hue, primary: primary, secondary: secondary,
                  recents: recents, recentsTitle: recentsTitle, onOpenRecent: onOpenRecent, showsStarfield: showsStarfield)
        self.primaryIsDefault = primaryIsDefault
        self.identifiers = identifiers
    }

    public var body: some View {
        ViewThatFits(in: .vertical) {
            column.frame(maxHeight: .infinity)
            ScrollView { column }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The stars keep clear of the title, message, actions and recents, fading out around them,
        // so no dot sits on text, as on the welcome window.
        .backgroundPreferenceValue(HeroClearings.self) { anchors in
            if showsStarfield {
                GeometryReader { proxy in
                    // Leans toward the pointer anywhere over the hero; surges while the primary action is hovered.
                    LumenStarfield(isSurging: surging, pointer: pointer, starCount: 140)
                        .opacity(0.7)
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
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .background(palette[.bgCanvas])
        .onContinuousHover { phase in
            if case .active(let location) = phase { pointer = location } else { pointer = nil }
        }
        .accessibilityElement(children: .contain)
        .lumenAccessibilityIdentifier(identifiers.container)
    }

    private var column: some View {
        VStack(spacing: metrics.spacing.s4) {
            LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileHero)
                .lumenGlow(.hero, color: palette[.welcomeGlow])   // the welcome glow token, as LumenWelcome
                .accessibilityHidden(true)
            Text(title)
                .font(metrics.typography.title2)
                .foregroundStyle(palette[.fgPrimary])
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .anchorPreference(key: HeroClearings.self, value: .bounds) { [$0] }
            if let message {
                Text(message)
                    .font(metrics.typography.callout)
                    .foregroundStyle(palette[.fgSecondary])
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: metrics.layout.heroRecentMaxWidth)
                    .lumenWrapsWithoutTruncating()
                    .anchorPreference(key: HeroClearings.self, value: .bounds) { [$0] }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics.spacing.s4) { buttons }
                VStack(spacing: metrics.spacing.s2) { buttons }
            }
            .anchorPreference(key: HeroClearings.self, value: .bounds) { [$0] }
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                    LumenSectionHeader(recentsTitle).padding(.horizontal, metrics.spacing.s3)   // at the rows' tiles
                    ForEach(recents.prefix(5)) { item in
                        Button { onOpenRecent(item) } label: {
                            LumenListRow(item.title, detail: item.detail, systemImage: item.systemImage, hue: item.hue)
                        }
                        .buttonStyle(.plain)
                        .help(item.detail)
                    }
                }
                .padding(metrics.spacing.s3)
                .background(palette[.bgElevated].opacity(0.55), in: .rect(cornerRadius: metrics.radius.lg, style: .continuous))
                // The hairline keeps the group a group in light, where the card's white matched the
                // white canvas and "Recent" floated.
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous)
                        .strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline)
                }
                .lumenRaisedGround()
                .frame(maxWidth: metrics.layout.heroMessageMaxWidth)
                .accessibilityElement(children: .contain)
                .lumenAccessibilityIdentifier(identifiers.recents)
                .anchorPreference(key: HeroClearings.self, value: .bounds) { [$0] }
                .padding(.top, metrics.spacing.s2)
            }
        }
        .padding(metrics.spacing.s6)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var buttons: some View {
        Button(primary.title, action: primary.perform)
            .buttonStyle(.lumenPrimary)
            .lumenFocusRing(cornerRadius: metrics.radius.pill)
            .disabled(!primary.isEnabled)
            .keyboardShortcut(primaryIsDefault ? .defaultAction : nil)
            .onHover { surging = $0 }
            .lumenAccessibilityIdentifier(primary.accessibilityIdentifier)
            .fixedSize()
        ForEach(secondary) { action in
            Button(action: action.perform) {
                HStack(spacing: metrics.spacing.s2) {
                    if let symbol = action.systemImage { LumenSymbol(symbol) }
                    Text(action.title)
                }
            }
            .buttonStyle(.lumenQuiet)
            .lumenFocusRing()
            .disabled(!action.isEnabled)
            .lumenAccessibilityIdentifier(action.accessibilityIdentifier)
            .fixedSize()
        }
    }
}

/// The hero's text blocks, which its starfield fades out around (as `LumenWelcome` clears its own).
private struct HeroClearings: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}
