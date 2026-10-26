import LumenUI
import SwiftUI

/// The Graph editor's call-graph scope: the selected function's callers (above) and callees
/// (below) to a chosen depth, from the image's existing call xrefs. Clicking a function selects
/// its entry, which also re-roots the call graph on it.
struct CallGraphPanel: View {
    @ObservedObject var store: WorkspaceStore
    let projection: FocusedGraphProjection
    @Binding var depth: Int
    let focusedBinaryName: String?

    static let nodeSize = CGSize(width: 220, height: 64)
    static let metrics = LayeredGraphLayout.Metrics(nodeSize: nodeSize, horizontalGap: 28, layerGap: 56, margin: 24)

    var body: some View {
        let root = Self.rootFunction(in: projection, selection: store.selectedImageAddress)
        let model = root.flatMap {
            CallGraphModel.build(projection: projection, rootFunctionID: $0.id, depth: depth, metrics: Self.metrics)
        }
        VStack(spacing: 0) {
            HStack(spacing: Lumen.Space.s4) {
                Text("Depth").font(.caption).foregroundStyle(.secondary)
                LumenModeSwitcher(selection: $depth, options: Array(1...CallGraphModel.maximumDepth), style: .pill) {
                    "\($0)"
                }
                .accessibilityLabel("Call graph depth")
                .accessibilityIdentifier("graph.callDepth")
                Spacer(minLength: Lumen.Space.s4)
                if let model {
                    Text(Self.summary(model))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("graph.callSummary")
                }
            }
            .padding(.horizontal, Lumen.Space.s5)
            .padding(.vertical, Lumen.Space.s3)
            Divider()
            if let model, model.layoutRefusal == nil {
                ScrollView([.horizontal, .vertical]) {
                    CallGraphCanvas(model: model, focusedBinaryName: focusedBinaryName) { node in
                        if store.selectAddress(ImageAddress(slot: projection.imageSlot, address: node.startAddress)) {
                            // Keep the navigator on the function the call graph moved to.
                            store.syncSidebarSelection(functionID: node.functionID)
                        }
                    }
                }
                .workbenchPaneBackground(.editor)
            } else {
                EmptyStateView(
                    title: "Call graph unavailable",
                    detail: model?.layoutRefusal
                        ?? "Select an address inside exactly one discovered function in the focused image.",
                    systemImage: "lumen.callGraph"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The single function whose range contains the selection, else none (never a guess).
    static func rootFunction(in projection: FocusedGraphProjection, selection: ImageAddress?) -> FunctionSummary? {
        guard let selection, selection.slot == projection.imageSlot else { return nil }
        let owners = projection.functions.filter {
            $0.endAddress > $0.startAddress && selection.address >= $0.startAddress && selection.address < $0.endAddress
        }
        return owners.count == 1 ? owners[0] : nil
    }

    static func summary(_ model: CallGraphModel) -> String {
        let callers = model.nodes.filter { $0.depth < 0 }.count
        let callees = model.nodes.filter { $0.depth > 0 }.count
        var text = "\(callers) caller\(callers == 1 ? "" : "s") · \(callees) callee\(callees == 1 ? "" : "s")"
        if let cap = model.truncatedAt { text += " · first \(cap) functions shown" }
        return text
    }
}

/// Draws a laid-out `CallGraphModel`: rounded function cards (the root accented) and routed
/// call edges; upward (recursive or back) calls are dotted.
struct CallGraphCanvas: View {
    let model: CallGraphModel
    let focusedBinaryName: String?
    let onSelect: (CallGraphModel.Node) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.edges) { edge in
                CallGraphEdgeShape(points: edge.points)
                    .stroke(Color.lumen(.fgTertiary),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round,
                                               dash: edge.isBackEdge ? [2, 4] : []))
                    .accessibilityHidden(true)
                if edge.points.count >= 2 {
                    let tip = edge.points[edge.points.count - 1]
                    let before = edge.points[edge.points.count - 2]
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: AppGraphChrome.arrowHeadSize + 2))
                        .foregroundStyle(Color.lumen(.fgTertiary))
                        .rotationEffect(.radians(atan2(tip.y - before.y, tip.x - before.x)))
                        .position(tip)
                        .accessibilityHidden(true)
                }
            }
            ForEach(model.nodes) { node in
                CallGraphNodeCard(node: node, focusedBinaryName: focusedBinaryName) { onSelect(node) }
                    .frame(width: CallGraphPanel.nodeSize.width, height: CallGraphPanel.nodeSize.height)
                    .position(node.center)
            }
        }
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
    }
}

private struct CallGraphEdgeShape: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])
        for i in 1..<(points.count - 1) {
            path.addArc(tangent1End: points[i], tangent2End: points[i + 1], radius: 14)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

private struct CallGraphNodeCard: View {
    let node: CallGraphModel.Node
    let focusedBinaryName: String?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            DSGraphNode(
                title: node.name,
                detail: node.startAddress.hexAddress,
                systemImage: node.isRoot ? "lumen.entryPoint" : "function",
                hue: node.isRoot ? .hueGreen : (node.depth < 0 ? .hueIndigo : .hueBlue),
                state: node.isRoot ? .selected : .normal
            )
            .contentShape(RoundedRectangle(cornerRadius: Lumen.Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(node.isRoot ? "Selected function" : "Selects this function")
        .accessibilityIdentifier("graph.call.\(node.startAddress.hexAddress)")
    }

    private var accessibilityLabel: String {
        let role = node.depth < 0 ? "caller" : node.depth > 0 ? "callee" : "selected function"
        let image = focusedBinaryName.map { ", \($0)" } ?? ""
        return "\(node.name), \(role) at depth \(abs(node.depth)), \(node.startAddress.hexAddress)\(image)"
    }
}
