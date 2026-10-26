import Foundation

/// A conservative, derived graph of statically declared Mach-O image dependencies.
///
/// This v0 graph is intentionally read-only and in-memory. It uses only images already loaded in
/// the workspace plus each image's existing `MachOLoadMetadata.dependentDylibs` projection. It does
/// not crawl app bundles, resolve `@rpath`, import new images, persist graph state, or participate
/// in debugger/runtime authority.
struct ApplicationImageGraph: Equatable, Sendable {
    struct Node: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case workspaceImage(slot: ImageSlot)
            case externalSystemImage
            case externalAbsoluteImage
            case unresolvedDependency
        }

        let id: String
        let kind: Kind
        let displayName: String
        let path: String?
    }

    struct Edge: Identifiable, Equatable, Sendable {
        enum Resolution: Equatable, Sendable {
            case resolvedWorkspaceImage(ImageSlot)
            case external(String)
            case unresolved(String)
        }

        let id: String
        let fromSlot: ImageSlot
        let toNodeID: String
        let rawPath: String
        let loadKind: String
        let ordinal: Int
        let resolution: Resolution
    }

    let nodes: [Node]
    let edges: [Edge]
}

struct ApplicationImageGraphBuilder: Sendable {
    func build(from snapshot: WorkspaceSnapshot) -> ApplicationImageGraph {
        var nodesByID: [String: ApplicationImageGraph.Node] = [:]
        var edges: [ApplicationImageGraph.Edge] = []

        let binaries = snapshot.binaries.sorted {
            if $0.slot != $1.slot { return $0.slot < $1.slot }
            return $0.name < $1.name
        }
        let pathIndex = Self.loadedImagePathIndex(for: binaries)

        for binary in binaries {
            let workspaceNode = Self.workspaceNode(for: binary)
            nodesByID[workspaceNode.id] = workspaceNode
        }

        for binary in binaries {
            guard let dependencies = snapshot.analysis(in: binary.slot)?.machOMetadata?.dependentDylibs,
                  !dependencies.isEmpty
            else { continue }

            for dependency in dependencies.sorted(by: Self.dependencySort) {
                let target = Self.resolve(dependency.path, pathIndex: pathIndex)
                let targetNode = Self.node(
                    for: target,
                    sourceSlot: binary.slot,
                    dependency: dependency
                )
                nodesByID[targetNode.id] = targetNode

                edges.append(ApplicationImageGraph.Edge(
                    id: "edge:\(binary.slot.rawValue):\(dependency.ordinal):\(dependency.path)",
                    fromSlot: binary.slot,
                    toNodeID: targetNode.id,
                    rawPath: dependency.path,
                    loadKind: dependency.kind,
                    ordinal: dependency.ordinal,
                    resolution: target.resolution
                ))
            }
        }

        return ApplicationImageGraph(
            nodes: nodesByID.values.sorted(by: Self.nodeSort),
            edges: edges.sorted(by: Self.edgeSort)
        )
    }

    private struct ResolvedTarget {
        let nodeID: String
        let kind: ApplicationImageGraph.Node.Kind
        let displayName: String
        let path: String?
        let resolution: ApplicationImageGraph.Edge.Resolution
    }

    private static func loadedImagePathIndex(for binaries: [BinaryImage]) -> [String: [ImageSlot]] {
        var result: [String: Set<ImageSlot>] = [:]
        for binary in binaries {
            result[binary.path, default: []].insert(binary.slot)
            if let resolvedExecutablePath = binary.resolvedExecutablePath, !resolvedExecutablePath.isEmpty {
                result[resolvedExecutablePath, default: []].insert(binary.slot)
            }
        }
        return result.mapValues { $0.sorted() }
    }

    private static func resolve(
        _ rawPath: String,
        pathIndex: [String: [ImageSlot]]
    ) -> ResolvedTarget {
        if let slots = pathIndex[rawPath], slots.count == 1, let slot = slots.first {
            return ResolvedTarget(
                nodeID: "workspace:\(slot.rawValue)",
                kind: .workspaceImage(slot: slot),
                displayName: displayName(for: rawPath),
                path: rawPath,
                resolution: .resolvedWorkspaceImage(slot)
            )
        }
        if pathIndex[rawPath]?.isEmpty == false {
            return unresolvedTarget(for: rawPath)
        }

        if isSystemAbsolutePath(rawPath) {
            return ResolvedTarget(
                nodeID: "external-system:\(rawPath)",
                kind: .externalSystemImage,
                displayName: displayName(for: rawPath),
                path: rawPath,
                resolution: .external(rawPath)
            )
        }

        if rawPath.hasPrefix("/") {
            return ResolvedTarget(
                nodeID: "external-absolute:\(rawPath)",
                kind: .externalAbsoluteImage,
                displayName: displayName(for: rawPath),
                path: rawPath,
                resolution: .external(rawPath)
            )
        }

        return unresolvedTarget(for: rawPath)
    }

    private static func unresolvedTarget(for rawPath: String) -> ResolvedTarget {
        ResolvedTarget(
            nodeID: "unresolved:\(rawPath)",
            kind: .unresolvedDependency,
            displayName: rawPath.isEmpty ? "Unresolved dependency" : rawPath,
            path: nil,
            resolution: .unresolved(rawPath)
        )
    }

    private static func workspaceNode(for binary: BinaryImage) -> ApplicationImageGraph.Node {
        ApplicationImageGraph.Node(
            id: "workspace:\(binary.slot.rawValue)",
            kind: .workspaceImage(slot: binary.slot),
            displayName: binary.name.isEmpty ? displayName(for: binary.path) : binary.name,
            path: binary.resolvedExecutablePath ?? binary.path
        )
    }

    private static func node(
        for target: ResolvedTarget,
        sourceSlot: ImageSlot,
        dependency: MachOLoadMetadata.DependentDylib
    ) -> ApplicationImageGraph.Node {
        if case .unresolvedDependency = target.kind {
            return ApplicationImageGraph.Node(
                id: "unresolved:\(sourceSlot.rawValue):\(dependency.ordinal):\(dependency.path)",
                kind: target.kind,
                displayName: target.displayName,
                path: target.path
            )
        }

        return ApplicationImageGraph.Node(
            id: target.nodeID,
            kind: target.kind,
            displayName: target.displayName,
            path: target.path
        )
    }

    private static func displayName(for path: String) -> String {
        let component = URL(fileURLWithPath: path).lastPathComponent
        return component.isEmpty ? path : component
    }

    private static func isSystemAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/")
    }

    private static func dependencySort(
        _ lhs: MachOLoadMetadata.DependentDylib,
        _ rhs: MachOLoadMetadata.DependentDylib
    ) -> Bool {
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        return lhs.path < rhs.path
    }

    private static func nodeSort(
        _ lhs: ApplicationImageGraph.Node,
        _ rhs: ApplicationImageGraph.Node
    ) -> Bool {
        func rank(_ kind: ApplicationImageGraph.Node.Kind) -> Int {
            switch kind {
            case .workspaceImage: 0
            case .externalSystemImage: 1
            case .externalAbsoluteImage: 2
            case .unresolvedDependency: 3
            }
        }

        let lhsRank = rank(lhs.kind)
        let rhsRank = rank(rhs.kind)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.id < rhs.id
    }

    private static func edgeSort(
        _ lhs: ApplicationImageGraph.Edge,
        _ rhs: ApplicationImageGraph.Edge
    ) -> Bool {
        if lhs.fromSlot != rhs.fromSlot { return lhs.fromSlot < rhs.fromSlot }
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        return lhs.id < rhs.id
    }
}
