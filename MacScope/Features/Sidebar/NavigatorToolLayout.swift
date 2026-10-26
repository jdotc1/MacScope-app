import Foundation

/// The user's arrangement of the navigator tool tabs: their order and which are hidden, as in
/// Nova's customizable sidebar tabs.
///
/// Stored as one string, e.g. `"Symbols,Project,-Strings,Xrefs"`: raw values in order, hidden ones
/// prefixed with `-`. Unknown entries are dropped, and tools added in a later version appear at the
/// end, visible, so an old preference never hides new features. An empty string is the default.
struct NavigatorToolLayout<Tool: Hashable & RawRepresentable>: Equatable where Tool.RawValue == String {
    private(set) var order: [Tool]
    private(set) var hidden: Set<Tool>
    private let defaultOrder: [Tool]

    init(all: [Tool]) {
        order = all
        hidden = []
        defaultOrder = all
    }

    init(encoded: String, all: [Tool]) {
        self.init(all: all)
        var seen = Set<Tool>()
        var parsedOrder: [Tool] = []
        var parsedHidden = Set<Tool>()
        for entry in encoded.split(separator: ",") {
            let isHidden = entry.hasPrefix("-")
            let raw = String(isHidden ? entry.dropFirst() : entry[...])
            guard let tool = Tool(rawValue: raw), all.contains(tool), seen.insert(tool).inserted else { continue }
            parsedOrder.append(tool)
            if isHidden { parsedHidden.insert(tool) }
        }
        order = parsedOrder + all.filter { !seen.contains($0) }
        hidden = parsedHidden
        if visible.isEmpty { hidden.removeAll() }
    }

    var visible: [Tool] { order.filter { !hidden.contains($0) } }

    var isDefault: Bool { order == defaultOrder && hidden.isEmpty }

    /// The stored form; empty for the default arrangement.
    var encoded: String {
        isDefault ? "" : order.map { hidden.contains($0) ? "-" + $0.rawValue : $0.rawValue }.joined(separator: ",")
    }

    /// Whether `tool` can move `offset` places among the visible tools.
    func canMove(_ tool: Tool, by offset: Int) -> Bool {
        guard let index = visible.firstIndex(of: tool) else { return false }
        return visible.indices.contains(index + offset)
    }

    /// Moves `tool` to just past the visible tool `offset` places away; hidden tools keep their
    /// relative place.
    mutating func move(_ tool: Tool, by offset: Int) {
        guard offset != 0, canMove(tool, by: offset), let from = visible.firstIndex(of: tool) else { return }
        let neighbor = visible[from + offset]
        order.removeAll { $0 == tool }
        guard let anchor = order.firstIndex(of: neighbor) else { return }
        order.insert(tool, at: offset > 0 ? anchor + 1 : anchor)
    }

    /// Hides `tool`, refusing to hide the last visible one. Returns whether it was hidden.
    @discardableResult
    mutating func hide(_ tool: Tool) -> Bool {
        guard !hidden.contains(tool), visible.count > 1 else { return false }
        hidden.insert(tool)
        return true
    }

    mutating func showAll() {
        hidden.removeAll()
    }

    mutating func reset() {
        order = defaultOrder
        hidden.removeAll()
    }
}
