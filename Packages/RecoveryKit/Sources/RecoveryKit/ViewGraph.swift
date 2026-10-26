import Foundation

public struct ViewNode: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let name: String
    public init(id: String, kind: String, name: String) { self.id = id; self.kind = kind; self.name = name }
}
public struct ViewEdge: Codable, Hashable, Sendable {
    public let source: String
    public let target: String
    public let relation: String
    public let order: Int
    public let evidence: [String]
    public init(source: String, target: String, relation: String, order: Int, evidence: [String]) {
        self.source = source; self.target = target; self.relation = relation; self.order = order; self.evidence = evidence
    }
}
public struct ViewGraph: Codable, Sendable {
    public let image: String
    public let root: String
    public let nodes: [ViewNode]
    public let edges: [ViewEdge]
    public init(image: String, root: String, nodes: [ViewNode], edges: [ViewEdge]) {
        self.image = image; self.root = root; self.nodes = nodes; self.edges = edges
    }
    public func validate(limits: RecoveryLimits = RecoveryLimits()) throws {
        try ImageKey.validate(image); try limits.validate()
        guard nodes.count <= limits.records, edges.count <= limits.records else { throw RecoveryError.budget("view graph records") }
        let ids = Set(nodes.map(\.id))
        guard ids.count == nodes.count, ids.contains(root), nodes.allSatisfy({ !$0.id.isEmpty }) else {
            throw RecoveryError.invalid("duplicate/missing view graph node")
        }
        var outgoing: [String: [String]] = [:]
        var edgeKeys: Set<String> = []
        for edge in edges {
            guard ids.contains(edge.source), ids.contains(edge.target), edge.order >= 0, !edge.evidence.isEmpty else {
                throw RecoveryError.invalid("view edge lacks identity/order/proof")
            }
            let key = "\(edge.source)\u{0}\(edge.relation)\u{0}\(edge.order)"
            guard edgeKeys.insert(key).inserted else { throw RecoveryError.invalid("ambiguous view edge order") }
            outgoing[edge.source, default: []].append(edge.target)
        }
        var color: [String: Int] = [:]
        for node in ids.sorted() {
            if color[node] == 2 { continue }
            var stack: [(String, Bool, Int)] = [(node, false, 0)]
            while let (current, leaving, depth) = stack.popLast() {
                guard depth <= limits.depth else { throw RecoveryError.budget("view graph depth") }
                if leaving { color[current] = 2; continue }
                if color[current] == 1 { throw RecoveryError.invalid("cyclic view graph") }
                if color[current] == 2 { continue }
                color[current] = 1
                stack.append((current, true, depth))
                for child in outgoing[current, default: []].reversed() { stack.append((child, false, depth + 1)) }
            }
        }
    }
}
