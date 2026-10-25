import AppKit
import SwiftUI
import LumenTokens

// A control-flow graph's blocks and edges, chosen for MacScope: summary cards, and
// branch edges colored and lettered by direction.

/// How a block relates to the selection.
public enum LumenGraphNodeState: Sendable, Hashable {
    case normal
    /// It holds the selected instruction but doesn't start there: an accent hairline.
    case currentBlock
    /// It is the selection: an accent border and glow.
    case selected
}

/// A graph block as a summary card: its kind's tile (entry, exit; a
/// plain block has none), its name and instruction count, and its address range, centred in the
/// card, with the selection in the accent. Multi-selected blocks get a dashed outline, and a color tag
/// a stripe on the leading edge. The layout sets the frame; the card fills it and scales its address
/// before clipping.
public struct LumenGraphNode: View {
    private let title: String
    private let detail: String?
    private let systemImage: String?
    private let hue: LumenToken
    private let count: Int?
    private let state: LumenGraphNodeState
    private let isMultiSelected: Bool
    private let tag: LumenTagColor?

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenCodeFont) private var codeFont

    /// - Parameters:
    ///   - detail: the address range ("0x100003f50–3f64").
    ///   - systemImage: the block kind's glyph (entry, exit); `nil` for a plain block, which gets no tile.
    ///   - count: instructions in the block.
    public init(_ title: String, detail: String? = nil, systemImage: String? = nil, hue: LumenToken = .hueBlue,
                count: Int? = nil, state: LumenGraphNodeState = .normal, isMultiSelected: Bool = false, tag: LumenTagColor? = nil) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.hue = hue
        self.count = count
        self.state = state
        self.isMultiSelected = isMultiSelected
        self.tag = tag
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.radius.md, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let systemImage { LumenIconTile(systemImage, hue: hue, size: metrics.layout.tileCompact) }
                Text(title).font(metrics.typography.caption.weight(.semibold)).foregroundStyle(palette[.fgPrimary]).lineLimit(1)
                    .lumenNeverTruncates(title)
                Spacer(minLength: 0)
                if let count {
                    Text(verbatim: String(count)).font(.caption2.monospacedDigit()).foregroundStyle(palette[.fgTertiary])
                        .help("\(count) instructions")
                }
            }
            if let detail {
                Text(detail)
                    .font((codeFont ?? .standard).font(sizeDelta: -1.5))
                    .foregroundStyle(palette[.fgSecondary])
                    .lineLimit(1).minimumScaleFactor(0.75).truncationMode(.middle).help(detail)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(palette[.bgElevated], in: shape)
        .overlay(alignment: .leading) {
            if let tag {
                // A plain band: the node's own clip shape rounds its outer edge, so it follows the
                // corners instead of reading as a square inside them.
                Rectangle().fill(palette[tag.hue]).frame(width: 4)
            }
        }
        .clipShape(shape)
        .overlay { border(shape) }
        .lumenGlow(.selection, color: state == .selected ? palette[.accent] : .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, detail, count.map { "\($0) instructions" }, stateDescription, tag.map { "\($0.title) tag" }]
            .compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(state == .selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private func border(_ shape: RoundedRectangle) -> some View {
        if isMultiSelected {
            shape.strokeBorder(palette[.accent], style: StrokeStyle(lineWidth: metrics.stroke.regular, dash: [4, 3]))
        } else {
            switch state {
            case .selected: shape.strokeBorder(palette[.accent], lineWidth: metrics.stroke.regular)
            // Full strength: a faded accent fell below the default border in the contrast themes.
            case .currentBlock: shape.strokeBorder(palette[.accent], lineWidth: metrics.stroke.hairline)
            case .normal: shape.strokeBorder(palette[.borderDefault], lineWidth: metrics.stroke.hairline)
            }
        }
    }

    private var stateDescription: String? {
        if isMultiSelected { return "in selection" }
        switch state {
        case .selected: return "selected"
        case .currentBlock: return "current block"
        case .normal: return nil
        }
    }
}

/// What an edge means, for its color, letter and dash.
public enum LumenGraphEdgeKind: Sendable, Hashable, CaseIterable {
    /// The branch taken when its condition holds: green, "T".
    case taken
    /// The fall-through when it doesn't: red, "F".
    case notTaken
    /// An unconditional jump or fall-through: quiet gray.
    case unconditional
    /// A call or cross-reference: the accent, dashed.
    case call

    /// The edge's color.
    public var token: LumenToken {
        switch self {
        case .taken: .statusSuccess
        case .notTaken: .statusDanger
        case .unconditional: .fgTertiary
        case .call: .accent
        }
    }

    /// The letter in its badge, if it has one.
    public var letter: String? {
        switch self {
        case .taken: "T"
        case .notTaken: "F"
        case .unconditional, .call: nil
        }
    }

    /// The stroke dash; empty for solid.
    public var dash: [CGFloat] { self == .call ? [5, 4] : [] }

    /// The stroke width, heavier when the edge is selected.
    public func lineWidth(isSelected: Bool) -> CGFloat { isSelected ? 2.5 : 1.5 }

    public var title: String {
        switch self {
        case .taken: "Branch taken"
        case .notTaken: "Branch not taken"
        case .unconditional: "Unconditional"
        case .call: "Call"
        }
    }
}

/// The small lettered badge at an edge's midpoint (T or F), in the edge's color on the canvas. Kinds
/// without a letter draw nothing. Clickable when `onSelect` is given.
public struct LumenGraphEdgeBadge: View {
    private let kind: LumenGraphEdgeKind
    private let isSelected: Bool
    private let onSelect: (() -> Void)?
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    public init(_ kind: LumenGraphEdgeKind, isSelected: Bool = false, onSelect: (() -> Void)? = nil) {
        self.kind = kind
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        if let letter = kind.letter {
            let badge = Text(letter)
                .font(.system(size: metrics.iconSize.micro, weight: .bold, design: .rounded))
                .foregroundStyle(palette[isSelected ? .bgCanvas : kind.token])
                .frame(width: 14, height: 14)
                .background(isSelected ? palette[kind.token] : palette[.bgCanvas], in: .circle)
                .overlay { Circle().strokeBorder(palette[kind.token].opacity(0.6), lineWidth: metrics.stroke.hairline) }
                .help(kind.title)
                .accessibilityLabel(kind.title)
            if let onSelect {
                Button(action: onSelect) { badge }.buttonStyle(.plain)
            } else {
                badge
            }
        }
    }
}
