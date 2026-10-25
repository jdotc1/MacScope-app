import AppKit
import SwiftUI
import LumenTokens

// A disassembly listing's rows and branch lanes, chosen for MacScope: calm rows with a
// tinted selection, the current block banded, and jump arrows in the gutter.

// MARK: Row state

/// Everything that can mark a listing row, resolved in one order so states never fight: the
/// selection, then the program counter, then a patch, then a color tag, then the current block.
public struct LumenListingRowState: Hashable, Sendable {
    public var isSelected: Bool
    /// The debugger is stopped here.
    public var isProgramCounter: Bool
    /// Its bytes were patched.
    public var isPatched: Bool
    public var tag: LumenTagColor?
    /// It's in the selection's basic block.
    public var isInCurrentBlock: Bool

    public init(isSelected: Bool = false, isProgramCounter: Bool = false, isPatched: Bool = false,
                tag: LumenTagColor? = nil, isInCurrentBlock: Bool = false) {
        self.isSelected = isSelected
        self.isProgramCounter = isProgramCounter
        self.isPatched = isPatched
        self.tag = tag
        self.isInCurrentBlock = isInCurrentBlock
    }

    /// The row's fill, strongest first: the selection is `bg.selected`, a clear step above the
    /// current-block band (`code.currentLine`) so a selection inside the highlighted block still reads
    /// as the selection; a patch is `diff.changedBackground` with a dashed mark (`patchMark`).
    public func background(_ palette: LumenResolvedPalette, isActiveWindow: Bool = true) -> Color {
        if isSelected { return palette[isActiveWindow ? .bgSelected : .bgSelectedInactive] }
        // Bands are the selection, the current line and a patch; the program counter and a tag
        // show as their bar (and the marker), not as tinted washes of amber or the tag's hue.
        if isProgramCounter { return palette[LumenToken.Code.currentLine] }
        if isPatched { return palette[LumenToken.Code.changedBackground] }
        if isInCurrentBlock { return palette[LumenToken.Code.currentLine] }
        return .clear
    }

    /// The patch's own mark, so a patch is never color alone: a dashed bar in `status.info` (the
    /// changed-line hue) on the leading edge, beside any solid bar. Its dashes tell it from a tag.
    public func patchMark(_ palette: LumenResolvedPalette) -> Color? {
        isPatched ? palette[.statusInfo] : nil
    }

    /// The bar on the row's leading edge, if any: the program counter's `code.programCounter` wins
    /// (where the debugger is matters most), then the tag's color, then the accent for the selection.
    public func leadingBar(_ palette: LumenResolvedPalette, isActiveWindow: Bool = true) -> Color? {
        if isProgramCounter { return palette[LumenToken.Code.programCounter] }
        if let tag { return palette[tag.hue] }
        if isSelected { return isActiveWindow ? palette[.accent] : palette[.fgTertiary] }
        return nil
    }

    /// What VoiceOver adds to the row's label.
    public var accessibilityDescription: String? {
        let parts = [isProgramCounter ? "program counter" : nil, isPatched ? "patched" : nil,
                     tag.map { "\($0.title) tag" }, isInCurrentBlock && !isSelected ? "current block" : nil]
            .compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

public extension View {
    /// Fills a listing row for `state` and draws its leading bar. Text keeps its syntax colors.
    func lumenListingRow(_ state: LumenListingRowState, isActiveWindow: Bool = true) -> some View {
        modifier(LumenListingRowModifier(state: state, isActiveWindow: isActiveWindow, drawsLeadingMarks: true))
    }

    /// Set `drawsLeadingMarks` to false when branch lanes draw the marks at the pane edge. Then the
    /// program-counter bar, the tag bar and the dashed patch mark come only from
    /// `LumenBranchLanes(rowStates:)`: pass the same row states there, or a patch shows by color alone.
    func lumenListingRow(_ state: LumenListingRowState, isActiveWindow: Bool = true, drawsLeadingMarks: Bool) -> some View {
        modifier(LumenListingRowModifier(state: state, isActiveWindow: isActiveWindow, drawsLeadingMarks: drawsLeadingMarks))
    }

}

/// A vertical line down the middle of its frame, dashed by its stroke style.
private struct LumenPatchMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.midX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)) }
    }
}

private struct LumenListingRowModifier: ViewModifier {
    static let barWidth: CGFloat = 3
    let state: LumenListingRowState
    let isActiveWindow: Bool
    let drawsLeadingMarks: Bool
    @Environment(\.lumenPalette) private var palette

    func body(content: Content) -> some View {
        content
            .background(state.background(palette, isActiveWindow: isActiveWindow))
            .overlay(alignment: .leading) {
                let bar = drawsLeadingMarks ? state.leadingBar(palette, isActiveWindow: isActiveWindow) : nil
                HStack(spacing: 0) {
                    if let bar { Rectangle().fill(bar).frame(width: Self.barWidth) }
                    if drawsLeadingMarks, let mark = state.patchMark(palette) {
                        LumenPatchMark().stroke(mark, style: StrokeStyle(lineWidth: Self.barWidth, dash: [3, 2]))
                            .frame(width: Self.barWidth)
                            .padding(.leading, bar == nil ? 0 : 1)
                    }
                }
            }
    }
}

/// The debugger's position in a listing gutter: an arrow in `code.programCounter`.
public struct LumenProgramCounterMarker: View {
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    public init() {}
    public var body: some View {
        LumenSymbol("arrowtriangle.right.fill")
            .font(.system(size: metrics.iconSize.micro))
            .foregroundStyle(palette[LumenToken.Code.programCounter])
            .help("Program counter")
            .accessibilityLabel("Program counter")
    }
}

// MARK: Branch lanes

/// A jump between two rows of a listing.
public struct LumenBranchLane: Hashable, Sendable {
    /// The row of the branch instruction.
    public let fromRow: Int
    /// The row it jumps to.
    public let toRow: Int
    /// Its color: `.taken` (green) for conditional, `.unconditional` (gray) for plain jumps.
    public let kind: LumenGraphEdgeKind
    /// Drawn in the accent and heavier, for jumps touching the selection.
    public let isHighlighted: Bool

    public init(fromRow: Int, toRow: Int, kind: LumenGraphEdgeKind = .taken, isHighlighted: Bool = false) {
        self.fromRow = fromRow
        self.toRow = toRow
        self.kind = kind
        self.isHighlighted = isHighlighted
    }

    var span: ClosedRange<Int> { min(fromRow, toRow)...max(fromRow, toRow) }
}

/// Jump arrows in a listing's gutter: each branch a bracket from its row to
/// its target, short jumps nearest the text and longer ones further out so nested jumps never cross,
/// with an arrowhead at the target. It draws a window of rows (`firstRow`, `rowCount`) of fixed
/// height, so it overlays a lazily scrolled listing; jumps that leave the window run off its edge.
/// Pass the window's `rowStates` and the rows' bands (selection, current block, patch) run on under
/// the lanes to the pane's leading edge, so the gutter never steps against them (PRINCIPLES §8).
public struct LumenBranchLanes: View {
    private let lanes: [LumenBranchLane]
    private let rowStates: [LumenListingRowState]
    private let isActiveWindow: Bool
    private let rowHeight: CGFloat
    private let firstRow: Int
    private let rowCount: Int
    private let maximumColumns: Int

    @Environment(\.lumenPalette) private var palette

    /// The gutter width this many columns needs.
    public static func width(columns: Int) -> CGFloat { CGFloat(max(columns, 1)) * spacing + 10 }
    static let spacing: CGFloat = 7
    /// The clear space between a lane's end (or arrowhead) and the row's leading bar.
    static let barGap: CGFloat = 1

    /// - Parameter rowStates: the states of the rows in the window (`rowStates[0]` is `firstRow`); their
    ///   bands are drawn under the lanes. Empty draws no bands.
    public init(_ lanes: [LumenBranchLane], rowHeight: CGFloat, firstRow: Int = 0, rowCount: Int, maximumColumns: Int = 4,
                rowStates: [LumenListingRowState] = [], isActiveWindow: Bool = true) {
        self.lanes = lanes
        self.rowStates = rowStates
        self.isActiveWindow = isActiveWindow
        self.rowHeight = rowHeight
        self.firstRow = firstRow
        self.rowCount = rowCount
        self.maximumColumns = maximumColumns
    }

    /// The column for each lane (0 nearest the text): shortest spans first, each in the first column
    /// where it overlaps nothing already placed; past `maximumColumns`, the outermost column.
    static func columns(for lanes: [LumenBranchLane], maximum: Int) -> [Int] {
        var result = Array(repeating: 0, count: lanes.count)
        var placed: [[ClosedRange<Int>]] = []
        for index in lanes.indices.sorted(by: { lanes[$0].span.count < lanes[$1].span.count }) {
            let span = lanes[index].span
            var column = placed.firstIndex { $0.allSatisfy { !$0.overlaps(span) } } ?? placed.count
            if column >= maximum { column = max(maximum - 1, 0) }
            if column == placed.count { placed.append([]) }
            placed[column].append(span)
            result[index] = column
        }
        return result
    }

    public var body: some View {
        let columns = Self.columns(for: lanes, maximum: maximumColumns)
        let width = Self.width(columns: min((columns.max() ?? 0) + 1, maximumColumns))
        Canvas { context, size in
            let window = firstRow..<(firstRow + rowCount)
            // The rows' bands first, edge to edge, so they continue the listing's bands under the lanes.
            for (offset, state) in rowStates.prefix(rowCount).enumerated() {
                let band = state.background(palette, isActiveWindow: isActiveWindow)
                context.fill(Path(CGRect(x: 0, y: CGFloat(offset) * rowHeight, width: size.width, height: rowHeight)), with: .color(band))
                let bar = state.leadingBar(palette, isActiveWindow: isActiveWindow)
                if let bar {
                    context.fill(Path(CGRect(x: 0, y: CGFloat(offset) * rowHeight, width: LumenListingRowModifier.barWidth, height: rowHeight)), with: .color(bar))
                }
                if let mark = state.patchMark(palette) {
                    let x = bar == nil ? LumenListingRowModifier.barWidth / 2 : LumenListingRowModifier.barWidth * 1.5 + 1
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: CGFloat(offset) * rowHeight))
                    path.addLine(to: CGPoint(x: x, y: CGFloat(offset + 1) * rowHeight))
                    context.stroke(path, with: .color(mark), style: StrokeStyle(lineWidth: LumenListingRowModifier.barWidth, dash: [3, 2]))
                }
            }
            // Highlighted lanes last, so they sit on top.
            for index in lanes.indices.sorted(by: { !lanes[$0].isHighlighted && lanes[$1].isHighlighted }) {
                let lane = lanes[index]
                guard lane.span.overlaps(window.lowerBound...max(window.upperBound - 1, window.lowerBound)) else { continue }
                let x = size.width - 6 - CGFloat(columns[index]) * Self.spacing
                let y = { (row: Int) in (CGFloat(row - firstRow) + 0.5) * rowHeight }
                let color = palette[lane.isHighlighted ? .accent : lane.kind.token]
                // Stop a point short of the row, so lanes never touch a row's 3 pt leading bar.
                let edge = size.width - Self.barGap
                var path = Path()
                path.move(to: CGPoint(x: edge, y: y(lane.fromRow)))
                path.addLine(to: CGPoint(x: x, y: y(lane.fromRow)))
                path.addLine(to: CGPoint(x: x, y: y(lane.toRow)))
                path.addLine(to: CGPoint(x: edge - 3, y: y(lane.toRow)))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: lane.isHighlighted ? 1.8 : 1.2, lineJoin: .round, dash: lane.kind.dash))
                var head = Path()
                let tip = CGPoint(x: edge, y: y(lane.toRow))
                head.move(to: tip)
                head.addLine(to: CGPoint(x: tip.x - 4, y: tip.y - 3))
                head.addLine(to: CGPoint(x: tip.x - 4, y: tip.y + 3))
                head.closeSubpath()
                context.fill(head, with: .color(color))
            }
        }
        .frame(width: width, height: CGFloat(rowCount) * rowHeight)
        .accessibilityHidden(true)
    }
}

// MARK: Strings

/// A string literal as code shows it: the text in `syntax.string`, escapes (`\n`, `\t`, `\x1b`) in
/// `syntax.keyword` and format specifiers (`%d`, `%02x`, `%@`) in `syntax.number`, so the parts a
/// reverse engineer looks for stand out. Needs the code pack in the registry.
public struct LumenStringLiteral: View {
    private let text: String
    /// The literal runs' color: `syntax.string` in code, plain text in a navigator row.
    private let literalToken: LumenToken
    @Environment(\.lumenPalette) private var palette

    /// - Parameter text: the literal as displayed, with escapes already written out (`"line\\n"`).
    public init(_ text: String) {
        self.init(text, literalToken: LumenToken.Code.string)
    }

    init(_ text: String, literalToken: LumenToken) {
        self.text = text
        self.literalToken = literalToken
    }

    enum Part: Equatable {
        case literal(String)
        case escape(String)
        case format(String)
    }

    /// `text` split into literal runs, escapes and format specifiers.
    static func parts(_ text: String) -> [Part] {
        var parts: [Part] = []
        var literal = ""
        let chars = Array(text)
        var i = 0
        func flush() { if !literal.isEmpty { parts.append(.literal(literal)); literal = "" } }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                flush()
                var end = i + 2
                if chars[i + 1] == "x" { while end < chars.count, end < i + 4, chars[end].isHexDigit { end += 1 } }
                else if chars[i + 1].isNumber { while end < chars.count, end < i + 4, chars[end].isNumber { end += 1 } }
                parts.append(.escape(String(chars[i..<end])))
                i = end
            } else if c == "%", i + 1 < chars.count {
                var end = i + 1
                if chars[end] == "%" {
                    flush(); parts.append(.format("%%")); i = end + 1; continue
                }
                while end < chars.count, "0123456789.-+#*'".contains(chars[end]) { end += 1 }
                while end < chars.count, "hlqjztL".contains(chars[end]) { end += 1 }
                if end < chars.count, "diouxXeEfFgGaAcspn@".contains(chars[end]) {
                    flush()
                    parts.append(.format(String(chars[i...end])))
                    i = end + 1
                } else {
                    literal.append(c); i += 1
                }
            } else {
                literal.append(c); i += 1
            }
        }
        flush()
        return parts
    }

    public var body: some View {
        Self.parts(text).reduce(Text(verbatim: "")) { result, part in
            switch part {
            case .literal(let s): result + Text(verbatim: s).foregroundColor(palette[literalToken])
            case .escape(let s): result + Text(verbatim: s).foregroundColor(palette[LumenToken.Code.keyword])
            case .format(let s): result + Text(verbatim: s).foregroundColor(palette[LumenToken.Code.number])
            }
        }
        .accessibilityLabel(text)
    }
}

/// `LumenStringLiteral.parts` remembered per text, for a row whose chunks repeat across layouts.
@MainActor final class LumenStringPartsCache {
    private var known: [String: [LumenStringLiteral.Part]] = [:]

    func parts(_ text: String) -> [LumenStringLiteral.Part] {
        if let parts = known[text] { return parts }
        let parts = LumenStringLiteral.parts(text)
        known[text] = parts
        return parts
    }
}

/// A string in a strings navigator (chosen for MacScope): the literal on top in the row's text color
/// (a column of `syntax.string` red reads as errors outside the editor), its escapes and format
/// specifiers highlighted, wrapped or shortened at semantic boundaries when long, and its address, section and length
/// below. Selection uses the sidebar's selected-row fill.
public struct LumenStringRow: View {
    private let text: String
    private let address: UInt64
    private let section: String?
    private let length: Int?
    private let isSelected: Bool

    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics
    @Environment(\.lumenDensity) private var density
    @Environment(\.lumenCodeFont) private var codeFont
    /// Each chunk's escapes and specifiers, parsed once: the semantic text renders the same chunks
    /// for every candidate and every layout (PERF-10).
    @State private var parsed = LumenStringPartsCache()

    public init(_ text: String, address: UInt64, section: String? = nil, length: Int? = nil, isSelected: Bool = false) {
        self.text = text
        self.address = address
        self.section = section
        self.length = length
        self.isSelected = isSelected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s1) {
            LumenSemanticText(text, kind: text.hasPrefix("/") || text.hasPrefix("~/") ? .path : .expression,
                              lineLimit: 2, renderChunk: { chunk, _ in
                    var attributed = AttributedString()
                    for part in parsed.parts(chunk) {
                        var run: AttributedString
                        switch part {
                        case .literal(let value): run = AttributedString(value); run.foregroundColor = palette[.sidebarForeground]
                        case .escape(let value): run = AttributedString(value); run.foregroundColor = palette[LumenToken.Code.keyword]
                        case .format(let value): run = AttributedString(value); run.foregroundColor = palette[LumenToken.Code.number]
                        }
                        attributed.append(run)
                    }
                    return Text(attributed)
                })
                .font(metrics.typography.callout)
            HStack(spacing: metrics.spacing.s1) {
                Text(verbatim: "0x" + String(address, radix: 16))
                    .font((codeFont ?? .standard).font(sizeDelta: -2))
                Text(verbatim: [section, length.map { $0 == 1 ? "1 char" : "\($0) chars" }].compactMap(\.self)
                    .map { "· " + $0 }.joined(separator: " "))
                    .font(.caption2)
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(palette[.sidebarSecondaryForeground])
        }
        .padding(.horizontal, metrics.spacing.s2)
        .frame(minHeight: density.detailedRowHeight(in: metrics.layout))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? palette[.sidebarRowSelected] : .clear,
                    in: .rect(cornerRadius: metrics.radius.sm, style: .continuous))
        .help(text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([text, "at 0x" + String(address, radix: 16), section].compactMap(\.self).joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
