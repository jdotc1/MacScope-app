import AppKit
import SwiftUI
import LumenTokens

// Inspectors, the Mac way: a trailing column (SwiftUI's `.inspector`, macOS 14) that shows and hides
// with ⌥⌘I and a toolbar button, holding the selection's properties in collapsible sections with
// native controls. Lumen's part is the visual language: the selection's tile in the header, colored
// section tiles, a quiet label column, and hue swatches for anything that picks a category color.

/// The inspector's content column: sections stacked top to bottom on `inspector.background`.
///
/// Put it inside `.lumenInspector(isPresented:)`, or SwiftUI's own `.inspector(isPresented:)`.
public struct LumenInspector<Content: View>: View {
    private let scrolls: Bool
    private let content: Content

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenRendersOffscreen) private var rendersOffscreen

    public init(@ViewBuilder content: () -> Content) {
        self.init(scrolls: true, content: content)
    }

    /// `scrolls: false` lays the sections out without a scroll view, for previews and snapshots.
    init(scrolls: Bool, @ViewBuilder content: () -> Content) {
        self.scrolls = scrolls
        self.content = content()
    }

    public var body: some View {
        let stack = VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            // Offscreen (golden images, an app's own snapshots) the sections lay out without the
            // scroll view, which can't render there.
            if scrolls && !rendersOffscreen {
                // SwiftUI places the inspector's scroll view below the toolbar, and the scroll view
                // then insets its content by the toolbar's height again. Extend it under the
                // toolbar and pad by the measured inset instead: one inset, and content scrolls
                // under the toolbar as in other Mac scroll views.
                GeometryReader { proxy in
                    // PRINCIPLES §6: the sections are never wider than the column.
                    ScrollView { stack.lumenColumnWidthWatch("Inspector", columnWidth: proxy.size.width).padding(.top, proxy.safeAreaInsets.top) }
                        .ignoresSafeArea(.container, edges: .top)
                }
            } else {
                // Each section at its ideal height, as in the scroll view. Offered the pane's
                // height, the stack squeezed the header and first section (selectable values ask
                // for more than they use) and the first tile rode up onto the header's hairline.
                stack.lumenWrapsAtIdealHeight()
                    .lumenColumnWidthWatch("Inspector", isActive: true).frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(palette[.inspectorBackground])
    }
}

/// What the inspector is showing: the selection's tile, name and kind, above the sections.
public struct LumenInspectorHeader: View {
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
        HStack(spacing: metrics.spacing.s4) {
            LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileInspectorHeader)
            VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                // A long file name wraps to a second line, and past that loses its middle, so its
                // distinguishing end (".arm64e.dylib") stays, as list rows shorten it. The object's
                // title is a step above its section titles (`headline`), as a settings pane's is.
                Text(title).font(metrics.typography.title3).foregroundStyle(palette[.fgPrimary])
                    .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true).help(title)
                if let subtitle {
                    Text(subtitle).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary]).lineLimit(1).truncationMode(.middle).help(subtitle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(metrics.spacing.s5)
        .overlay(alignment: .bottom) { InspectorRule() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A collapsible inspector section: a header with an optional colored tile and a disclosure
/// chevron, then its rows. Pass `isExpanded` (from `@SceneStorage`, say) to remember collapsing
/// across launches; otherwise view state holds it.
public struct LumenInspectorSection<Content: View>: View {
    private let title: String
    private let systemImage: String?
    private let hue: LumenToken
    private let externalExpanded: Binding<Bool>?
    private let content: Content

    @State private var localExpanded = true
    @State private var isHovered = false
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ title: String, systemImage: String? = nil, hue: LumenToken = .accent, isExpanded: Binding<Bool>? = nil,
                @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.hue = hue
        externalExpanded = isExpanded
        self.content = content()
    }

    private var isExpanded: Binding<Bool> { externalExpanded ?? $localExpanded }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(metrics.motion.animation(metrics.motion.standardCurve, reduceMotion: reduceMotion)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: metrics.spacing.s3) {
                    if let systemImage { LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileSection).lumenIconRole(.section) }
                    Text(title).font(metrics.typography.headline).foregroundStyle(palette[.fgPrimary])
                    Spacer(minLength: 0)
                    LumenSymbol("chevron.right")
                        .font(.system(size: metrics.layout.disclosureGlyph, weight: .bold))
                        .foregroundStyle(palette[isHovered ? .fgSecondary : .fgTertiary])
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .padding(.horizontal, metrics.spacing.s5)
                // One rhythm per section: `s5` from the hairline above to the tile, `s3`
                // from the tile to the first row, and `s5` from the last row to the next hairline
                // (the rows' own hit-area slack counts toward it). Collapsed, the tile sits `s5`
                // from both hairlines.
                .padding(.top, metrics.spacing.s5)
                .padding(.bottom, isExpanded.wrappedValue ? metrics.spacing.s3 : metrics.spacing.s5)
                .contentShape(.rect)
            }
            .buttonStyle(.lumenPlain).lumenFocusRing()
            .onHover { isHovered = $0 }
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded.wrappedValue ? "Collapses the section" : "Expands the section")
            .accessibilityAddTraits(.isHeader)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: metrics.spacing.s2) { content }
                    .padding(.horizontal, metrics.spacing.s5)
                    .padding(.bottom, metrics.spacing.s4)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { InspectorRule() }
    }
}

/// One labeled control in an inspector section: a quiet label column and a small native control.
public struct LumenInspectorRow<Control: View>: View {
    private let label: String
    private let labelWidth: CGFloat?
    private let control: Control

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    /// - Parameter labelWidth: the label column; `nil` uses the metrics' `propertyLabelWidth`, so
    ///   inspector rows line up with `LumenPropertyRow`.
    public init(_ label: String, labelWidth: CGFloat? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.labelWidth = labelWidth
        self.control = control()
    }

    public var body: some View {
        // Beside its label where the value fits the value column; under it in a column too narrow
        // for the value (two badges need about 130 pt; the inspector's minimum leaves 94: LIVE-04).
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: metrics.spacing.s4) {
                labelText.frame(width: labelWidth ?? metrics.layout.propertyLabelWidth, alignment: .leading)
                value
            }
            VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                labelText
                value
            }
        }
        .frame(minHeight: metrics.layout.minimumHitTarget)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var labelText: some View {
        Text(label)
            .font(metrics.typography.caption)
            .foregroundStyle(palette[.fgSecondary])
    }

    private var value: some View {
        control
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The toolbar button that shows and hides the inspector, with the standard ⌥⌘I shortcut. Mac
/// convention puts it at the trailing end of the toolbar.
public struct LumenInspectorToggle: View {
    @Binding private var isPresented: Bool
    private let shortcut: KeyboardShortcut?
    private let registersShortcut: Bool
    @Environment(\.lumenMenuOwnsShortcuts) private var menuOwnsShortcuts

    /// - Parameters:
    ///   - shortcut: the shortcut, ⌥⌘I by default; shown in the help tag.
    ///   - registersShortcut: register it here; pass `false` when `LumenViewCommands` owns it.
    public init(isPresented: Binding<Bool>, shortcut: KeyboardShortcut? = LumenShortcuts.inspector, registersShortcut: Bool = true) {
        _isPresented = isPresented
        self.shortcut = shortcut
        self.registersShortcut = registersShortcut
    }

    public var body: some View {
        Button(isPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing") { isPresented.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(LumenToolbarIconButtonStyle())
            .lumenIconOnlyControl(isPresented ? "Hide Inspector" : "Show Inspector")
            .lumenFocusRing()
            .keyboardShortcut(registersShortcut && !menuOwnsShortcuts ? shortcut : nil)
            .help((isPresented ? "Hide Inspector" : "Show Inspector") + (shortcut.map { " (\(LumenKeycap.text(for: $0)))" } ?? ""))
    }
}

public extension View {
    /// A native inspector column (SwiftUI `.inspector`) with Lumen's width range and background.
    /// Pair it with `LumenInspectorToggle` in the toolbar.
    func lumenInspector<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        inspector(isPresented: isPresented) {
            LumenInspector(content: content)
                .inspectorColumnWidth(min: LumenLayout.inspectorColumn.min, ideal: LumenLayout.inspectorColumn.ideal,
                                      max: LumenLayout.inspectorColumn.max)
        }
    }
}

/// The hairline between inspector sections.
private struct InspectorRule: View {
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    var body: some View {
        Rectangle().fill(palette[.borderSubtle]).frame(height: metrics.stroke.hairline)
    }
}

// MARK: Hue swatches

/// A row of hue swatches for picking a category color, as Reminders and Finder tags do. The chosen
/// swatch carries a ring and a check, so the choice never rests on color alone.
public struct LumenHueSwatchPicker: View {
    @Binding private var selection: LumenToken
    private let hues: [LumenToken]
    private let size: CGFloat

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @FocusState private var focused: Bool

    public init(selection: Binding<LumenToken>, hues: [LumenToken] = LumenToken.hues, size: CGFloat = 18) {
        _selection = selection
        self.hues = hues
        self.size = size
    }

    public var body: some View {
        // One row when it fits; otherwise two or three even rows (↑/↓ then move between rows).
        // Never clipped by a narrow inspector.
        ViewThatFits(in: .horizontal) {
            swatches(perRow: hues.count)
            swatches(perRow: (hues.count + 1) / 2)
            swatches(perRow: (hues.count + 2) / 3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Color")
    }

    private func swatches(perRow: Int) -> some View {
        let perRow = max(1, perRow)
        let rows = stride(from: 0, to: hues.count, by: perRow).map { Array(hues[$0..<min($0 + perRow, hues.count)]) }
        return Grid(horizontalSpacing: metrics.spacing.s2, verticalSpacing: metrics.spacing.s2) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { hue in
                        LumenHueSwatch(hue: hue, size: size, isSelected: hue == selection, showsFocus: focused) { selection = hue }
                    }
                }
            }
        }
        .lumenSelectionGroup(hues, selection: $selection, columns: rows.count > 1 ? perRow : nil, focused: $focused)
        // The first circle starts at the value column, as text values do: the ring room inside each
        // swatch overhangs into the gap before it. No extra vertical room: a swatch's 24 pt hit
        // area already holds its ring, so a row of swatches is as tall as any other inspector row
        // (a 30 pt swatch row broke the 28 pt row pitch).
        .padding(.trailing, 3)
        .padding(.leading, -3)
    }
}

/// One swatch: a hue circle with the tile's gradient; a ring and a check when selected.
struct LumenHueSwatch: View {
    let hue: LumenToken
    let size: CGFloat
    let isSelected: Bool
    var showsFocus = false
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenStore) private var store
    @Environment(\.lumenMetrics) private var metrics
    @State private var isHovered = false

    var body: some View {
        let colors = LumenTileColors(hue: hue, appearance: LumenAppearance(isDark: colorScheme == .dark, isHighContrast: contrast == .increased),
                                     store: store, hueGround: true)
        Button(action: action) {
            Circle()
                .fill(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom))
                // A sub-hairline rim on a small swatch (deliberate).
                .overlay { Circle().strokeBorder(.black.opacity(colorScheme == .dark ? 0.35 : 0.12), lineWidth: 0.5) }
                .overlay {
                    if isSelected {
                        LumenSymbol("checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(colors.glyph)
                    }
                }
                .frame(width: size, height: size)
                .padding(3)
                .overlay {
                    Circle().strokeBorder(palette[hue].opacity(isSelected ? 1 : isHovered ? 0.45 : 0), lineWidth: metrics.stroke.focus)
                }
                .overlay {
                    Circle().strokeBorder(palette[.borderFocus], lineWidth: metrics.stroke.focus).padding(-3).opacity(showsFocus && isSelected ? 1 : 0)
                }
                .frame(minWidth: metrics.layout.minimumHitTarget, minHeight: metrics.layout.minimumHitTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .lumenIconOnlyControl(LumenHueSwatch.name(of: hue))
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(LumenHueSwatch.name(of: hue))
        .accessibilityLabel(LumenHueSwatch.name(of: hue))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// "hue.violet" → "Violet"; an app's own hue "hue.lab-blue" → "Lab Blue".
    static func name(of hue: LumenToken) -> String {
        let last = hue.rawValue.split(separator: ".").last.map(String.init) ?? hue.rawValue
        return last.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: Summary card

/// The card at the top of an inspector that says what the selection is:
/// a kind chip, the identity large with a copy button (an address), what it belongs to as a link (its
/// symbol), a quiet detail line, and a few counts. The sections that follow hold the rest.
public struct LumenInspectorSummary: View {
    private let kind: String
    private let hue: LumenToken
    private let title: String
    private let link: String?
    private let detail: String?
    private let stats: [LumenStat]
    private let onOpenLink: (() -> Void)?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @Environment(\.lumenStore) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var copied = false

    static let kindFillAlpha = 0.16
    /// How long the copy button shows its check.
    static let copiedDuration = 1.5

    /// The kind chip's text: the hue, moved toward black (light) or white (dark) until it reads at
    /// 4.5:1 on its wash over the card.
    private var kindInk: Color {
        let theme = store.theme(for: store.registry.surface(of: hue))
        let readable = LumenTileColors.pillText(hue, fillAlpha: Self.kindFillAlpha, over: .bgElevated,
                                                appearance: LumenAppearance(isDark: colorScheme == .dark, isHighContrast: contrast == .increased),
                                                store: store)
        return Color(nsColor: readable.ink.nsColor(in: theme.colorSpace))
    }

    /// - Parameters:
    ///   - kind: what it is ("Instruction", "String", "Function").
    ///   - title: its identity, copied by the copy button ("0x100003f60").
    ///   - link: what it belongs to ("compute(_:)"), opened by `onOpenLink`.
    ///   - detail: quiet context after the link ("+16 · __TEXT,__text").
    public init(kind: String, hue: LumenToken = .hueBlue, title: String, link: String? = nil, detail: String? = nil,
                stats: [LumenStat] = [], onOpenLink: (() -> Void)? = nil) {
        self.kind = kind
        self.hue = hue
        self.title = title
        self.link = link
        self.detail = detail
        self.stats = stats
        self.onOpenLink = onOpenLink
    }

    @ViewBuilder private var linkView: some View {
        if let link {
            Button { onOpenLink?() } label: {
                LumenSemanticText(link, kind: LumenSemanticTextPolicy.labelKind(for: link))
                    .font((codeFont ?? .standard).font(sizeDelta: -1, weight: .semibold))
                    .foregroundStyle(palette[onOpenLink == nil ? .fgPrimary : .fgLink])
                    
            }
            // Bare: without a handler the link is plain text in fg.primary, not a faded control.
            .buttonStyle(.lumenBare)
            .disabled(onOpenLink == nil)
            .help(onOpenLink == nil ? link : "Go to \(link)")
        }
    }

    @ViewBuilder private var detailView: some View {
        if let detail {
            Text(detail).font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                .lineLimit(1).truncationMode(.middle).help(detail)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            HStack(spacing: metrics.spacing.s2) {
                // The hue's ink deepened (light) or lifted (dark) until it reads at 4.5:1 on its own
                // wash, as `LumenRefPill` does: plain hue on a 16% wash measured 1.6–3.2:1.
                Text(kind).font(metrics.typography.captionEmphasized).foregroundStyle(kindInk)
                    .lumenChip(palette[hue].opacity(Self.kindFillAlpha))   // the one chip spec
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(title, forType: .string)
                    copied = true
                } label: {
                    LumenSymbol(copied ? "checkmark" : "doc.on.doc").font(.caption)
                        .foregroundStyle(palette[copied ? .statusSuccess : .fgTertiary])
                        .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .lumenIconOnlyControl("Copy \(title)")
                .help("Copy \(title)")
                .accessibilityLabel("Copy \(title)")
            }
            Text(title)
                .font((codeFont ?? .standard).font(sizeDelta: 5, weight: .semibold))
                .foregroundStyle(palette[.fgPrimary])
                .lineLimit(1).minimumScaleFactor(0.7).lumenNeverTruncates(title, minimumScale: 0.7)
                .textSelection(.enabled)
            if link != nil || detail != nil {
                // Link and detail share a line when they fit; otherwise the detail drops to its own
                // line rather than truncating a segment name mid-word.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.s1) {
                        linkView
                        detailView.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: metrics.spacing.s1) {
                        linkView
                        detailView
                    }
                }
            }
            if !stats.isEmpty {
                HStack(spacing: metrics.spacing.s2) {
                    ForEach(stats) { stat in
                        VStack(spacing: 0) {
                            Text(stat.value).font(metrics.typography.stat)
                                .foregroundStyle(palette[.fgPrimary]).lineLimit(1).minimumScaleFactor(0.7).lumenNeverTruncates(stat.value, minimumScale: 0.7)
                            Text(stat.label).font(.caption2).foregroundStyle(palette[.fgTertiary]).lineLimit(1).minimumScaleFactor(0.8).lumenNeverTruncates(stat.label, minimumScale: 0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, metrics.spacing.s2)
                        .background(palette[.bgInsetRaised], in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, metrics.spacing.s1)
            }
        }
        .padding(metrics.spacing.s4)
        .background(palette[.bgElevated], in: .rect(cornerRadius: metrics.radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius.lg, style: .continuous)
                .strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline)
        }
        .padding(metrics.spacing.s3)
        .onChange(of: title) { _, _ in copied = false }
        .task(id: copied) {
            // The check says "copied" for a moment, then the button is a copy button again.
            guard copied else { return }
            try? await Task.sleep(for: .seconds(Self.copiedDuration))
            if !Task.isCancelled { copied = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(kind) \(title)")
    }
}

/// A reference to somewhere else (a cross-reference, a caller): the location as a link in code type,
/// shortened in the middle rather than wrapped, and its kind ("call", "data", "jump") as a quiet tag.
public struct LumenReferenceRow: View {
    private let location: String
    private let kind: String?
    private let onOpen: () -> Void

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont
    @State private var hovered = false

    public init(_ location: String, kind: String? = nil, onOpen: @escaping () -> Void) {
        self.location = location
        self.kind = kind
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(spacing: metrics.spacing.s2) {
                LumenSemanticText(location, kind: LumenSemanticTextPolicy.labelKind(for: location))
                    .font((codeFont ?? .standard).font(sizeDelta: -1))
                    .foregroundStyle(palette[.fgLink])
                    .underline(hovered)
                    
                    .help(location)
                Spacer(minLength: metrics.spacing.s2)
                if let kind {
                    Text(kind).font(metrics.typography.captionEmphasized).foregroundStyle(palette[.fgTertiary])
                        .lumenChip(palette[.bgInset])   // the one chip spec
                        .fixedSize()
                }
            }
            // The sidebar row inset, so a reference sits at the same text edge as the string rows
            // and list rows beside it.
            .padding(.horizontal, metrics.spacing.s2)
            .frame(minHeight: 20)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Go to \(location)")
        .accessibilityLabel([location, kind].compactMap(\.self).joined(separator: ", "))
        .accessibilityHint("Goes to this location")
    }
}
