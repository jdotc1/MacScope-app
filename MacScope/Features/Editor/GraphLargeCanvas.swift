import LumenUI
import SwiftUI

/// When the graph editor stops building one SwiftUI view per node, edge and label. A 914-function
/// image overview (libjpeg) made thousands of node, edge-label and border views and aborted in
/// AttributeGraph (`grow_region`, attribute table exhausted). Above the per-view budget the
/// canvas draws everything in one `Canvas`; above `maximumDrawnNodes` it is not drawn at all.
enum GraphRenderBudget {
    static let maximumViewNodes = 300
    static let maximumViewEdges = 600
    static let maximumDrawnNodes = 20_000

    static func drawsAsCanvas(_ layout: FocusedGraphModel) -> Bool {
        layout.nodes.count > maximumViewNodes || layout.edges.count > maximumViewEdges
    }
}

/// A large graph drawn in one `Canvas`: function lanes with their titles, edges in their Lumen
/// kind colors and dashes with arrowheads, and node cards with title and address. A click selects
/// the node under it (same `selectGraphNode` path as a node view). Edge labels are omitted at this
/// size; selection and the current block are drawn with the accent.
struct GraphLargeCanvas: View {
    let layout: FocusedGraphModel
    let selectedAddress: ImageAddress?
    let selectedEdgeID: String?
    let onSelect: (GraphNodeModel) -> Void

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            drawLanes(&context)
            drawEdges(&context)
            drawNodes(&context)
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            if let node = Self.node(at: value.location, in: layout) { onSelect(node) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Graph of \(layout.nodes.count) blocks in \(layout.sections.count) functions")
        .accessibilityHint("Choose Selected function for a graph you can move through with the keyboard.")
    }

    /// The node whose card contains `point`, if any.
    static func node(at point: CGPoint, in layout: FocusedGraphModel) -> GraphNodeModel? {
        layout.nodes.first { node in
            CGRect(x: node.center.x - node.size.width / 2, y: node.center.y - node.size.height / 2,
                   width: node.size.width, height: node.size.height).contains(point)
        }
    }

    private func drawLanes(_ context: inout GraphicsContext) {
        let fill = Color.lumen(.graphLaneBackground), border = Color.lumen(.borderSubtle)
        for section in layout.sections {
            let rect = CGRect(origin: section.origin, size: CGSize(width: section.width, height: section.height))
            let shape = Path(roundedRect: rect, cornerRadius: Lumen.Radius.md)
            context.fill(shape, with: .color(fill))
            context.stroke(shape, with: .color(border), lineWidth: 1)
            context.draw(Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.primary),
                         at: CGPoint(x: rect.minX + Lumen.Space.s5, y: rect.minY + 18), anchor: .leading)
            context.draw(Text(section.subtitle).font(AppTypography.lineNumber).foregroundStyle(.secondary),
                         at: CGPoint(x: rect.minX + Lumen.Space.s5, y: rect.minY + 36), anchor: .leading)
        }
    }

    private func drawEdges(_ context: inout GraphicsContext) {
        for edge in layout.edges {
            let isSelected = edge.id == selectedEdgeID
            let color = edge.strokeColor(isSelected: isSelected)
            var path = Path()
            if edge.waypoints.count >= 2 {
                path.addLines(edge.waypoints)
            } else {
                path.move(to: edge.fromPoint)
                path.addCurve(to: edge.toPoint, control1: edge.control1, control2: edge.control2)
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(
                lineWidth: edge.strokeWidth(isSelected: isSelected), lineCap: .round, lineJoin: .round,
                dash: isSelected ? [] : edge.dash))
            let size = AppGraphChrome.arrowHeadSize
            var head = Path()
            head.move(to: CGPoint(x: 0, y: 0))
            head.addLine(to: CGPoint(x: -size, y: -size / 2))
            head.addLine(to: CGPoint(x: -size, y: size / 2))
            head.closeSubpath()
            let transform = CGAffineTransform(translationX: edge.toPoint.x, y: edge.toPoint.y).rotated(by: edge.arrowAngle)
            context.fill(head.applying(transform), with: .color(color))
        }
    }

    private func drawNodes(_ context: inout GraphicsContext) {
        let fill = DS.editorColor(.bgElevated), border = Color.lumen(.borderSubtle), accent = Color.lumen(.accent)
        for node in layout.nodes {
            let rect = CGRect(x: node.center.x - node.size.width / 2, y: node.center.y - node.size.height / 2,
                              width: node.size.width, height: node.size.height)
            let shape = Path(roundedRect: rect, cornerRadius: Lumen.Radius.md)
            context.fill(shape, with: .color(fill))
            let selected = selectedAddress.map { node.contains($0) } ?? false
            context.stroke(shape, with: .color(selected ? accent : border), lineWidth: selected ? 2 : 1)
            context.draw(Text(node.title).font(.caption.weight(.semibold)).foregroundStyle(.primary),
                         at: CGPoint(x: rect.minX + Lumen.Space.s4, y: rect.minY + 16), anchor: .leading)
            context.draw(Text(node.subtitle).font(AppTypography.lineNumber).foregroundStyle(.secondary),
                         at: CGPoint(x: rect.minX + Lumen.Space.s4, y: rect.minY + 34), anchor: .leading)
        }
    }
}

/// Graph zoom: − / percentage (resets) / +, bound to ⌘−, ⌘0 and ⌘= while the graph is shown.
struct GraphZoomControls: View {
    @Binding var zoom: CGFloat
    static let steps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.8, 1, 1.25, 1.5, 2]

    static func step(_ zoom: CGFloat, by direction: Int) -> CGFloat {
        if direction > 0 { return steps.first { $0 > zoom + 0.001 } ?? steps[steps.count - 1] }
        return steps.last { $0 < zoom - 0.001 } ?? steps[0]
    }

    var body: some View {
        HStack(spacing: Lumen.Space.s1) {
            Button { zoom = Self.step(zoom, by: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom Out (⌘−)")
                .accessibilityLabel("Zoom out")
                .disabled(zoom <= Self.steps[0])
            Button { zoom = GraphZoomState.openingZoom } label: {
                // Fixed size: "100%" was truncated to "10…" in the live check.
                Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().lineLimit(1).fixedSize()
                    .frame(minWidth: AppLayout.graphZoomLabelMinimumWidth)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Actual Size (⌘0)")
            .accessibilityLabel("Zoom \(Int((zoom * 100).rounded())) percent, reset to actual size")
            Button { zoom = Self.step(zoom, by: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom In (⌘=)")
                .accessibilityLabel("Zoom in")
                .disabled(zoom >= Self.steps[Self.steps.count - 1])
        }
        .buttonStyle(LumenToolbarIconButtonStyle())
        .accessibilityIdentifier("graph.zoom")
    }
}

/// Graph zoom kept per scope (Selected function, Call graph, Image overview): switching scopes
/// keeps each one's zoom, every scope opens at `openingZoom`, and ⌘0 returns the current scope to it.
struct GraphZoomState: Equatable {
    static let openingZoom: CGFloat = 1
    private var byScope: [GraphScope: CGFloat] = [:]

    func zoom(for scope: GraphScope) -> CGFloat { byScope[scope] ?? Self.openingZoom }

    mutating func set(_ zoom: CGFloat, for scope: GraphScope) {
        byScope[scope] = zoom == Self.openingZoom ? nil : zoom
    }
}
