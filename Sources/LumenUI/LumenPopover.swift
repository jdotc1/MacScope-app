import AppKit
import SwiftUI
import LumenTokens

// Popovers stay native: SwiftUI's `.popover` keeps the system material, the arrow, dismissal on
// click-away and Escape, and accessibility. Lumen lays out what goes inside: a small tile header
// that says what the popover is about, the content, and an optional footer of actions. The inside
// is a raised ground (PRINCIPLES §8): wells, keycaps and fields in it take the raised well, and its
// text takes the theme's foreground tokens, so themed popovers read like the rest of the window.

/// The inside of a popover: a header (tile, title, optional subtitle), the content, and an
/// optional footer separated by a hairline.
public struct LumenPopoverContent<Content: View, Footer: View>: View {
    private let title: String
    private let subtitle: String?
    private let systemImage: String
    private let hue: LumenToken
    private let width: CGFloat
    private let content: Content
    private let footer: Footer
    private let hasFooter: Bool

    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenPalette) private var palette

    public init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken = .accent, width: CGFloat = 280,
                @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hue = hue
        self.width = width
        self.content = content()
        self.footer = footer()
        hasFooter = true
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.spacing.s3) {
                LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileRowDetailed)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(metrics.typography.headline).foregroundStyle(palette[.fgPrimary])
                    if let subtitle {
                        Text(subtitle).font(metrics.typography.caption).foregroundStyle(palette[.fgSecondary])
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding([.horizontal, .top], metrics.spacing.s5)
            .padding(.bottom, metrics.spacing.s4)

            VStack(alignment: .leading, spacing: metrics.spacing.s3) { content }
                .font(metrics.typography.callout)
                .foregroundStyle(palette[.fgSecondary])
                .padding(.horizontal, metrics.spacing.s5)
                .padding(.bottom, metrics.spacing.s5)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasFooter {
                Divider()
                HStack(spacing: metrics.spacing.s3) {
                    Spacer(minLength: 0)
                    footer
                }
                .controlSize(.small)
                .padding(.horizontal, metrics.spacing.s5)
                .padding(.vertical, metrics.spacing.s4)
            }
        }
        .frame(width: width)
        .lumenRaisedGround()
    }
}

public extension LumenPopoverContent where Footer == EmptyView {
    init(_ title: String, subtitle: String? = nil, systemImage: String, hue: LumenToken = .accent, width: CGFloat = 280,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hue = hue
        self.width = width
        self.content = content()
        footer = EmptyView()
        hasFooter = false
    }
}

public extension View {
    /// A native popover laid out by `LumenPopoverContent`.
    func lumenPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .bottom, title: String, subtitle: String? = nil,
                                     systemImage: String, hue: LumenToken = .accent, width: CGFloat = 280,
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            LumenPopoverContent(title, subtitle: subtitle, systemImage: systemImage, hue: hue, width: width, content: content)
        }
    }
}

// MARK: Info button

/// A small ⓘ button that explains something in a popover, beside a setting, a status or a column
/// header. The explanation stays one click away instead of crowding the panel.
public struct LumenInfoButton: View {
    private let title: String
    private let message: String
    private let systemImage: String
    private let hue: LumenToken

    @State private var isPresented = false
    @State private var isHovered = false
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenPalette) private var palette

    public init(_ title: String, message: String, systemImage: String = "info", hue: LumenToken = .hueBlue) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.hue = hue
    }

    public var body: some View {
        Button("About \(title)", systemImage: "info.circle") { isPresented.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.lumenPlain).lumenFocusRing()
            .frame(width: metrics.layout.minimumHitTarget, height: metrics.layout.minimumHitTarget)
            .contentShape(.rect)
            .lumenIconOnlyControl("About \(title)")
            .foregroundStyle(palette[isHovered || isPresented ? .accent : .fgTertiary])
            .onHover { isHovered = $0 }
            .help("About \(title)")
            .lumenPopover(isPresented: $isPresented, arrowEdge: .trailing, title: title, systemImage: systemImage, hue: hue, width: 260) {
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
    }
}

// MARK: Hue picker

/// A compact color control for inspector rows: the current hue and its name; clicking opens a
/// popover of swatches. Choosing applies at once, and the popover stays open for comparison.
public struct LumenHuePickerButton: View {
    @Binding private var selection: LumenToken
    private let title: String
    private let hues: [LumenToken]

    @State private var isPresented = false
    @State private var isHovered = false
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ title: String = "Color", selection: Binding<LumenToken>, hues: [LumenToken] = LumenToken.hues) {
        self.title = title
        _selection = selection
        self.hues = hues
    }

    public var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: metrics.spacing.s2) {
                Circle().fill(palette[selection]).frame(width: 12, height: 12)
                    // A sub-hairline rim on a 12 pt swatch (deliberate).
                    .overlay { Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5) }
                Text(LumenHueSwatch.name(of: selection)).font(metrics.typography.caption).foregroundStyle(palette[.fgPrimary])
                LumenSymbol("chevron.up.chevron.down").font(.system(size: metrics.layout.disclosureGlyph, weight: .bold)).foregroundStyle(palette[.fgTertiary])
            }
            .padding(.horizontal, metrics.spacing.s3)
            .frame(height: metrics.layout.minimumHitTarget)
            .background(palette[isHovered || isPresented ? .bgHover : .bgElevated], in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: metrics.radius.sm, style: .continuous).strokeBorder(palette[.borderSubtle], lineWidth: metrics.stroke.hairline) }
            .contentShape(.rect)
        }
        .buttonStyle(.lumenPlain).lumenFocusRing()
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(LumenHueSwatch.name(of: selection))
        .lumenPopover(isPresented: $isPresented, title: title, subtitle: LumenHueSwatch.name(of: selection),
                      systemImage: "paintpalette.fill", hue: selection, width: hues.count > 6 ? 260 : 220) {
            LumenHueSwatchGrid(selection: $selection, hues: hues)
        }
    }
}

/// Swatches in rows of five, for popovers.
struct LumenHueSwatchGrid: View {
    @Binding var selection: LumenToken
    let hues: [LumenToken]
    @Environment(\.lumenMetrics) private var metrics
    @FocusState private var focused: Bool

    static let columns = 5
    static let swatchSize: CGFloat = 26
    /// The ring room inside each swatch (`LumenHueSwatch` pads its circle by 3 pt).
    static let ringRoom: CGFloat = 3

    var body: some View {
        let rows = stride(from: 0, to: hues.count, by: Self.columns).map { Array(hues[$0..<min($0 + Self.columns, hues.count)]) }
        VStack(alignment: .leading, spacing: metrics.spacing.s2) {
            ForEach(rows, id: \.self) { row in
                // Columns spread across the popover's width, so the grid is balanced, not left-heavy.
                // A short last row keeps the columns above (7 hues: 5 + 2 at the first two
                // columns), so nothing jumps to the far edge.
                HStack(spacing: 0) {
                    ForEach(0..<Self.columns, id: \.self) { index in
                        if index > 0 { Spacer(minLength: metrics.spacing.s3) }
                        if let hue = row[safe: index] {
                            LumenHueSwatch(hue: hue, size: Self.swatchSize, isSelected: hue == selection, showsFocus: focused) { selection = hue }
                        } else {
                            Color.clear.frame(width: Self.swatchSize + Self.ringRoom * 2, height: Self.swatchSize + Self.ringRoom * 2)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        // The circles, not their ring room, meet the content edges, so the grid lines up with the
        // header tile and the footer's trailing edge.
        .padding(.horizontal, -Self.ringRoom)
        .lumenSelectionGroup(hues, selection: $selection, columns: Self.columns, focused: $focused)
        .onAppear { focused = true }   // the popover opens ready for arrow keys
        .accessibilityElement(children: .contain)
    }
}
