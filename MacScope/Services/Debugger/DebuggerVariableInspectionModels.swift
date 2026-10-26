import CryptoKit
import Foundation

// MARK: - WS-23 lazy scope, variable, and watch inspection models

enum DebuggerVariableScopeKind: String, CaseIterable, Hashable, Sendable {
    case arguments
    case locals
    case statics
    case registers
    case globals
}

struct DebuggerVariablePathToken: Hashable, Sendable {
    static let maximumComponentCount = 32
    static let maximumComponentUTF8Bytes = 256

    let lowercaseHex: String

    init?(
        coordinate: DebuggerInspectionCoordinate,
        components: [String]
    ) {
        guard !components.isEmpty,
              components.count <= Self.maximumComponentCount,
              components.allSatisfy(Self.isValidComponent) else {
            return nil
        }

        var material = Data()
        material.appendLengthFramed(coordinate.targetDigest.lowercaseHex)
        material.appendLengthFramed(coordinate.stop.session.epoch.rawValue.uuidString.lowercased())
        material.appendFixedWidth(coordinate.stop.session.lifecycleRevision.rawValue)
        material.appendFixedWidth(coordinate.stop.stopRevision.rawValue)
        material.appendFixedWidth(UInt64(coordinate.thread.index))
        material.appendOptionalFixedWidth(coordinate.thread.tid)
        material.appendLengthFramed(coordinate.thread.uniqueNameDigest ?? "")
        material.appendFixedWidth(UInt64(coordinate.frame.frameIndex))
        material.appendFixedWidth(coordinate.frame.programCounter)
        material.appendLengthFramed(coordinate.frame.canonicalFunctionName ?? "")
        components.forEach { material.appendLengthFramed($0) }

        lowercaseHex = material.sha256LowercaseHex
    }

    static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumComponentUTF8Bytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

struct DebuggerVariableScopeRequest: Hashable, Sendable {
    let coordinate: DebuggerInspectionCoordinate
    let kind: DebuggerVariableScopeKind

    init(
        coordinate: DebuggerInspectionCoordinate,
        kind: DebuggerVariableScopeKind
    ) {
        self.coordinate = coordinate
        self.kind = kind
    }
}

struct DebuggerVariableExpansionRequest: Hashable, Sendable {
    let coordinate: DebuggerInspectionCoordinate
    let token: DebuggerVariablePathToken
    let pathComponents: [String]
    let depth: Int

    init?(
        coordinate: DebuggerInspectionCoordinate,
        token: DebuggerVariablePathToken,
        pathComponents: [String],
        depth: Int
    ) {
        let derivedDepth = (pathComponents.count - 1) / 2
        guard pathComponents.count >= 3,
              !pathComponents.count.isMultiple(of: 2),
              pathComponents.count + 2 <= DebuggerVariablePathToken.maximumComponentCount,
              [
                DebuggerVariableScopeKind.arguments.rawValue,
                DebuggerVariableScopeKind.locals.rawValue,
                DebuggerVariableScopeKind.statics.rawValue,
              ].contains(pathComponents[0]),
              depth == derivedDepth,
              depth >= 1,
              depth <= DebuggerVariableSnapshot.maximumDepth,
              pathComponents.count <= DebuggerVariablePathToken.maximumComponentCount,
              pathComponents.allSatisfy(DebuggerVariablePathToken.isValidComponent),
              DebuggerVariablePathToken(
                coordinate: coordinate,
                components: pathComponents
              ) == token else {
            return nil
        }
        self.coordinate = coordinate
        self.token = token
        self.pathComponents = pathComponents
        self.depth = depth
    }
}

enum DebuggerVariableValueState: Hashable, Sendable {
    case value(String)
    case optimizedOut
    case unavailable(reason: String)
    case failed(reason: String)

    var isDisplayable: Bool {
        if case .value = self { return true }
        return false
    }
}

struct DebuggerVariableNode: Hashable, Identifiable, Sendable {
    static let maximumDisplayUTF8Bytes = 4_096
    static let maximumChildCount = 512

    let id: DebuggerVariablePathToken
    let name: String
    let typeName: String?
    let value: DebuggerVariableValueState
    let childCount: Int
    let pathComponents: [String]
    let children: [DebuggerVariableNode]
    let childExpansion: DebuggerVariableChildExpansionState

    init?(
        id: DebuggerVariablePathToken,
        name: String,
        typeName: String? = nil,
        value: DebuggerVariableValueState,
        childCount: Int,
        pathComponents: [String]? = nil,
        children: [DebuggerVariableNode] = [],
        childExpansion: DebuggerVariableChildExpansionState? = nil
    ) {
        let resolvedPathComponents = pathComponents ?? [name]
        let resolvedChildExpansion = childExpansion ?? (
            children.isEmpty ? .notLoaded : .loaded
        )
        guard Self.isValidDisplay(name),
              typeName.map(Self.isValidDisplay) ?? true,
              childCount >= 0,
              !resolvedPathComponents.isEmpty,
              resolvedPathComponents.count <= DebuggerVariablePathToken.maximumComponentCount,
              resolvedPathComponents.allSatisfy(DebuggerVariablePathToken.isValidComponent),
              children.count <= Self.maximumChildCount,
              children.allSatisfy({ $0.pathComponents.starts(with: resolvedPathComponents) }),
              Self.isValidChildExpansion(resolvedChildExpansion, childCount: childCount, children: children),
              Self.isValid(value: value) else {
            return nil
        }
        self.id = id
        self.name = name
        self.typeName = typeName
        self.value = value
        self.childCount = childCount
        self.pathComponents = resolvedPathComponents
        self.children = children
        self.childExpansion = resolvedChildExpansion
    }

    var isExpandable: Bool {
        childCount > 0
    }

    func replacingChildren(
        _ children: [DebuggerVariableNode],
        expansion: DebuggerVariableChildExpansionState = .loaded
    ) -> DebuggerVariableNode? {
        guard children.allSatisfy({
            $0.pathComponents.count == pathComponents.count + 2
                && $0.pathComponents.starts(with: pathComponents)
        }) else { return nil }
        return DebuggerVariableNode(
            id: id,
            name: name,
            typeName: typeName,
            value: value,
            childCount: childCount,
            pathComponents: pathComponents,
            children: children,
            childExpansion: expansion
        )
    }

    private static func isValid(value: DebuggerVariableValueState) -> Bool {
        switch value {
        case .value(let text), .unavailable(let text), .failed(let text):
            return isValidDisplay(text)
        case .optimizedOut:
            return true
        }
    }

    private static func isValidDisplay(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumDisplayUTF8Bytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isValidChildExpansion(
        _ state: DebuggerVariableChildExpansionState,
        childCount: Int,
        children: [DebuggerVariableNode]
    ) -> Bool {
        switch state {
        case .notLoaded:
            return children.isEmpty
        case .loading:
            return childCount > 0 && children.isEmpty
        case .loaded:
            return children.count <= childCount
        case .failed(let reason):
            return childCount > 0
                && children.isEmpty
                && isValidDisplay(reason)
        }
    }
}

enum DebuggerVariableChildExpansionState: Hashable, Sendable {
    case notLoaded
    case loading
    case loaded
    case failed(reason: String)
}

struct DebuggerVariableSnapshot: Hashable, Sendable {
    static let maximumNodeCount = 512
    static let maximumDepth = 64

    let coordinate: DebuggerInspectionCoordinate
    let scope: DebuggerVariableScopeKind
    let nodes: [DebuggerVariableNode]
    let depth: Int
    let wasTruncated: Bool

    init?(
        coordinate: DebuggerInspectionCoordinate,
        scope: DebuggerVariableScopeKind,
        nodes: [DebuggerVariableNode],
        depth: Int,
        wasTruncated: Bool
    ) {
        guard depth >= 0,
              depth <= Self.maximumDepth,
              nodes.count <= Self.maximumNodeCount else {
            return nil
        }
        self.coordinate = coordinate
        self.scope = scope
        self.nodes = nodes
        self.depth = depth
        self.wasTruncated = wasTruncated
    }

    func freshness(
        currentStop: DebuggerStopCoordinate?,
        currentAuthority: DebuggerSessionTargetAuthority?,
        currentThread: DebuggerThreadIdentity?,
        currentFrame: DebuggerFrameIdentity?,
        processState: DebuggerProcessState
    ) -> DebuggerInspectionFreshness {
        DebuggerInspectionFreshnessPolicy.evaluate(
            cached: coordinate,
            currentStop: currentStop,
            currentAuthority: currentAuthority,
            currentThread: currentThread,
            currentFrame: currentFrame,
            processState: processState
        )
    }

    func replacingChildren(
        matching request: DebuggerVariableExpansionRequest,
        with children: [DebuggerVariableNode],
        wasTruncated: Bool
    ) -> DebuggerVariableSnapshot? {
        guard coordinate == request.coordinate,
              scope.rawValue == request.pathComponents.first,
              depth == 0 else { return nil }
        guard let replacementNodes = Self.replacingChildren(
            in: nodes,
            matching: request,
            with: children
        ) else { return nil }
        return DebuggerVariableSnapshot(
            coordinate: coordinate,
            scope: scope,
            nodes: replacementNodes,
            depth: depth,
            wasTruncated: self.wasTruncated || wasTruncated
        )
    }

    func transitioningChildren(
        matching request: DebuggerVariableExpansionRequest,
        to expansion: DebuggerVariableChildExpansionState
    ) -> DebuggerVariableSnapshot? {
        guard coordinate == request.coordinate,
              scope.rawValue == request.pathComponents.first,
              depth == 0,
              let replacementNodes = Self.transitioningChildren(
                in: nodes,
                matching: request,
                to: expansion
              ) else { return nil }
        return DebuggerVariableSnapshot(
            coordinate: coordinate,
            scope: scope,
            nodes: replacementNodes,
            depth: depth,
            wasTruncated: wasTruncated
        )
    }

    func childExpansion(
        matching request: DebuggerVariableExpansionRequest
    ) -> DebuggerVariableChildExpansionState? {
        guard coordinate == request.coordinate,
              scope.rawValue == request.pathComponents.first else { return nil }
        return Self.childExpansion(in: nodes, matching: request)
    }

    private static func replacingChildren(
        in nodes: [DebuggerVariableNode],
        matching request: DebuggerVariableExpansionRequest,
        with children: [DebuggerVariableNode]
    ) -> [DebuggerVariableNode]? {
        for index in nodes.indices {
            let node = nodes[index]
            if node.id == request.token,
               node.pathComponents == request.pathComponents {
                guard let replacement = node.replacingChildren(children) else { return nil }
                var copy = nodes
                copy[index] = replacement
                return copy
            }
            if let childReplacement = replacingChildren(
                in: node.children,
                matching: request,
                with: children
            ) {
                guard let replacement = node.replacingChildren(
                    childReplacement,
                    expansion: node.childExpansion
                ) else { return nil }
                var copy = nodes
                copy[index] = replacement
                return copy
            }
        }
        return nil
    }

    private static func transitioningChildren(
        in nodes: [DebuggerVariableNode],
        matching request: DebuggerVariableExpansionRequest,
        to expansion: DebuggerVariableChildExpansionState
    ) -> [DebuggerVariableNode]? {
        for index in nodes.indices {
            let node = nodes[index]
            if node.id == request.token,
               node.pathComponents == request.pathComponents {
                guard let replacement = node.replacingChildren([], expansion: expansion) else {
                    return nil
                }
                var copy = nodes
                copy[index] = replacement
                return copy
            }
            if let childReplacement = transitioningChildren(
                in: node.children,
                matching: request,
                to: expansion
            ) {
                guard let replacement = node.replacingChildren(
                    childReplacement,
                    expansion: node.childExpansion
                ) else { return nil }
                var copy = nodes
                copy[index] = replacement
                return copy
            }
        }
        return nil
    }

    private static func childExpansion(
        in nodes: [DebuggerVariableNode],
        matching request: DebuggerVariableExpansionRequest
    ) -> DebuggerVariableChildExpansionState? {
        for node in nodes {
            if node.id == request.token,
               node.pathComponents == request.pathComponents {
                return node.childExpansion
            }
            if let nested = childExpansion(in: node.children, matching: request) {
                return nested
            }
        }
        return nil
    }
}

struct DebuggerWatchExpressionRequest: Hashable, Sendable {
    static let maximumExpressionUTF8Bytes = 1_024

    let coordinate: DebuggerInspectionCoordinate
    let expression: String

    init?(
        coordinate: DebuggerInspectionCoordinate,
        expression: String
    ) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= Self.maximumExpressionUTF8Bytes,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        self.coordinate = coordinate
        self.expression = trimmed
    }
}

struct DebuggerWatchExpressionResult: Hashable, Sendable {
    let request: DebuggerWatchExpressionRequest
    let value: DebuggerVariableValueState

    init?(
        request: DebuggerWatchExpressionRequest,
        value: DebuggerVariableValueState
    ) {
        guard DebuggerVariableNode.isValidWatch(value: value) else { return nil }
        self.request = request
        self.value = value
    }

    func freshness(
        currentStop: DebuggerStopCoordinate?,
        currentAuthority: DebuggerSessionTargetAuthority?,
        currentThread: DebuggerThreadIdentity?,
        currentFrame: DebuggerFrameIdentity?,
        processState: DebuggerProcessState
    ) -> DebuggerInspectionFreshness {
        DebuggerInspectionFreshnessPolicy.evaluate(
            cached: request.coordinate,
            currentStop: currentStop,
            currentAuthority: currentAuthority,
            currentThread: currentThread,
            currentFrame: currentFrame,
            processState: processState
        )
    }
}

private extension DebuggerVariableNode {
    static func isValidWatch(value: DebuggerVariableValueState) -> Bool {
        switch value {
        case .value(let text), .unavailable(let text), .failed(let text):
            return !text.isEmpty
                && text.utf8.count <= maximumDisplayUTF8Bytes
                && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        case .optimizedOut:
            return true
        }
    }
}

private extension Data {
    mutating func appendLengthFramed(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(bytes)
    }

    mutating func appendFixedWidth(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendOptionalFixedWidth(_ value: UInt64?) {
        guard let value else {
            append(0)
            return
        }
        append(1)
        appendFixedWidth(value)
    }

    var sha256LowercaseHex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
