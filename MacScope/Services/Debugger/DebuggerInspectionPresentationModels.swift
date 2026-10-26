import Foundation

// MARK: - WS-23 debugger inspection presentation

enum DebuggerSourceInspectionPresentation: Hashable, Sendable {
    case fresh(String)
    case unavailable(String)

    var title: String {
        switch self {
        case .fresh: "Source fresh"
        case .unavailable: "Source unavailable"
        }
    }

    var detail: String {
        switch self {
        case .fresh(let location), .unavailable(let location):
            location
        }
    }

    var isFresh: Bool {
        if case .fresh = self { return true }
        return false
    }

    static func resolve(
        hasLiveProcessSession: Bool,
        coordinate: DebuggerInspectionCoordinate?,
        selectedFrameResolvedStaticAddress: DebuggerResolvedStaticAddress?,
        sourceLines: [SourceLineEntry],
        focusedImageSlot: ImageSlot?
    ) -> Self {
        guard hasLiveProcessSession else {
            return .unavailable("No live debug process")
        }
        guard let coordinate else {
            return .unavailable("No exact stopped-frame identity")
        }
        guard let selectedFrameResolvedStaticAddress else {
            return .unavailable("Runtime PC is not mapped to the workspace")
        }

        switch DebuggerSourceInspectionResolver.resolve(
            coordinate: coordinate,
            resolvedAddress: selectedFrameResolvedStaticAddress,
            sourceLines: sourceLines,
            focusedImageSlot: focusedImageSlot
        ) {
        case .resolved(let context):
            return .fresh(context.source.presentationLocation)
        case .unavailable(let reason):
            return .unavailable(reason.presentationDetail)
        case .ambiguous:
            return .unavailable("Ambiguous source rows for selected frame")
        case .stale(let reason):
            return .unavailable(reason.presentationDetail)
        }
    }
}

struct DebuggerInspectionStatusPresentation: Hashable, Sendable {
    let hasInspectionCoordinate: Bool
    let sourceStatus: DebuggerSourceInspectionPresentation
    let selectedThreadSummary: String
    let selectedFrameSummary: String

    var coordinateTitle: String {
        hasInspectionCoordinate ? "Frame identity exact" : "Frame identity unavailable"
    }

    var summary: String {
        [
            selectedThreadSummary,
            selectedFrameSummary,
            sourceStatus.detail
        ].joined(separator: " · ")
    }

    var accessibilitySummary: String {
        "\(coordinateTitle). \(sourceStatus.title): \(sourceStatus.detail). \(selectedThreadSummary). \(selectedFrameSummary)."
    }

    init(
        hasInspectionCoordinate: Bool,
        sourceStatus: DebuggerSourceInspectionPresentation,
        selectedThread: DebuggerThreadSummary?,
        selectedFrame: DebuggerFrameSummary?
    ) {
        self.hasInspectionCoordinate = hasInspectionCoordinate
        self.sourceStatus = sourceStatus
        selectedThreadSummary = Self.threadSummary(selectedThread)
        selectedFrameSummary = Self.frameSummary(selectedFrame)
    }

    private static func threadSummary(_ thread: DebuggerThreadSummary?) -> String {
        guard let thread else { return "No selected thread" }
        var parts = ["thread #\(thread.index)"]
        if let queueName = thread.queueName {
            parts.append(queueName)
        }
        return parts.joined(separator: " ")
    }

    private static func frameSummary(_ frame: DebuggerFrameSummary?) -> String {
        guard let frame else { return "No selected frame" }
        return "frame #\(frame.index) \(frame.functionName) \(frame.address.hexAddress)"
    }
}

struct DebuggerVariablesInspectionPresentation: Hashable, Sendable {
    enum ExpansionState: Hashable, Sendable {
        case idle
        case loading
        case failed(String)
    }

    struct Group: Hashable, Sendable, Identifiable {
        let scope: DebuggerVariableScopeKind
        let rows: [Row]
        let wasTruncated: Bool

        var id: DebuggerVariableScopeKind { scope }

        var title: String {
            switch scope {
            case .arguments: "Arguments"
            case .locals: "Locals"
            case .statics: "Statics"
            case .registers: "Registers"
            case .globals: "Globals"
            }
        }

        var emptyText: String { "No \(title.lowercased()) in this frame." }
        var truncationText: String { "Additional \(title.lowercased()) were omitted by the bounded debugger snapshot." }
    }

    struct Row: Hashable, Sendable, Identifiable {
        enum ValueTone: Hashable, Sendable {
            case value
            case optimizedOut
            case unavailable
            case failed
        }

        let id: DebuggerVariablePathToken
        let pathComponents: [String]
        let name: String
        let typeName: String
        let value: String
        let valueTone: ValueTone
        let childCount: Int
        let childAvailabilityText: String?
        let childExpansionText: String?
        let detailText: String
        let depth: Int
        let isExpandable: Bool
        let isExpanded: Bool
        /// The value differs from the same variable's at the previous stop.
        var isChanged = false
        let isCollapsed: Bool
        let expansionState: ExpansionState
        let canRequestExpansion: Bool

        init(
            node: DebuggerVariableNode,
            depth: Int = 0,
            isCollapsed: Bool = false,
            expansionState: ExpansionState = .idle,
            anotherExpansionIsActive: Bool = false
        ) {
            id = node.id
            pathComponents = node.pathComponents
            name = node.name
            typeName = node.typeName ?? "Type unavailable"
            childCount = node.childCount
            self.depth = depth
            isExpandable = node.isExpandable
            self.isCollapsed = isCollapsed && !node.children.isEmpty
            isExpanded = !node.children.isEmpty && !self.isCollapsed
            self.expansionState = expansionState
            let modelPermitsExpansion: Bool
            switch node.childExpansion {
            case .notLoaded, .failed:
                modelPermitsExpansion = true
            case .loading, .loaded:
                modelPermitsExpansion = false
            }
            canRequestExpansion = node.isExpandable
                && node.children.isEmpty
                && modelPermitsExpansion
                && expansionState != .loading
                && !anotherExpansionIsActive
            childAvailabilityText = node.childCount > 0
                ? "\(node.childCount) child\(node.childCount == 1 ? "" : "ren") available"
                : nil
            childExpansionText = Self.childExpansionText(
                for: node,
                presentationState: expansionState
            )
            switch node.value {
            case .value(let text):
                value = text
                valueTone = .value
            case .optimizedOut:
                value = "Optimized out"
                valueTone = .optimizedOut
            case .unavailable(let reason):
                value = "Unavailable: \(reason)"
                valueTone = .unavailable
            case .failed(let reason):
                value = "Failed: \(reason)"
                valueTone = .failed
            }
            detailText = [typeName, childAvailabilityText, childExpansionText].compactMap(\.self).joined(separator: " · ")
        }

        private static func childExpansionText(
            for node: DebuggerVariableNode,
            presentationState: ExpansionState
        ) -> String? {
            guard node.isExpandable else { return nil }
            switch presentationState {
            case .loading:
                return "Loading children…"
            case .failed(let reason):
                return "Child load failed: \(reason)"
            case .idle:
                break
            }
            switch node.childExpansion {
            case .notLoaded:
                return node.children.isEmpty ? "Children not loaded" : nil
            case .loading:
                return "Loading children…"
            case .loaded:
                return node.children.isEmpty ? "No loaded children" : "\(node.children.count) loaded"
            case .failed(let reason):
                return "Child load failed: \(reason)"
            }
        }
    }

    let selectedFrameValue: String
    let frameDetail: String
    let variableStatusText: String
    let groups: [Group]

    init(
        inspectionCoordinate: DebuggerInspectionCoordinate?,
        selectedFrame: DebuggerFrameSummary?,
        variableScopes: [DebuggerVariableScopeSnapshot],
        collapsedTokens: Set<DebuggerVariablePathToken> = [],
        expansionStates: [DebuggerVariablePathToken: ExpansionState] = [:],
        activeExpansionToken: DebuggerVariablePathToken? = nil,
        changedVariableKeys: Set<String> = []
    ) {
        if let selectedFrame {
            selectedFrameValue = "#\(selectedFrame.index) \(selectedFrame.functionName) \(selectedFrame.address.hexAddress)"
        } else {
            selectedFrameValue = "No selected frame"
        }
        frameDetail = inspectionCoordinate != nil
            ? "exact stopped-frame identity"
            : "exact stopped-frame identity unavailable"

        guard let inspectionCoordinate else {
            groups = []
            variableStatusText = "Variables unavailable until the process is paused with exact thread and frame identity."
            return
        }

        guard variableScopes.allSatisfy({ $0.coordinate == inspectionCoordinate }) else {
            groups = []
            variableStatusText = "Variables are refreshing for the current stopped frame."
            return
        }

        groups = variableScopes
            .filter { [.arguments, .locals, .statics].contains($0.scope) }
            .map { scope in
                Group(
                    scope: scope.scope,
                    rows: scope.nodes.flatMap {
                        Self.flattenRows(
                            for: $0,
                            collapsedTokens: collapsedTokens,
                            expansionStates: expansionStates,
                            activeExpansionToken: activeExpansionToken
                        )
                    }.map { row in
                        var row = row
                        row.isChanged = changedVariableKeys.contains(DebuggerVariableChanges.key(
                            frame: inspectionCoordinate.frame, scope: scope.scope, pathComponents: row.pathComponents))
                        return row
                    },
                    wasTruncated: scope.wasTruncated
                )
            }
        variableStatusText = groups.isEmpty
            ? "Variable projection is unavailable for this exact stopped frame."
            : "Variables are bound to the current exact stopped frame."
    }

    private static func flattenRows(
        for node: DebuggerVariableNode,
        depth: Int = 0,
        collapsedTokens: Set<DebuggerVariablePathToken>,
        expansionStates: [DebuggerVariablePathToken: ExpansionState],
        activeExpansionToken: DebuggerVariablePathToken?
    ) -> [Row] {
        let isCollapsed = collapsedTokens.contains(node.id)
        let state = expansionStates[node.id]
            ?? (activeExpansionToken == node.id ? .loading : .idle)
        let row = Row(
            node: node,
            depth: depth,
            isCollapsed: isCollapsed,
            expansionState: state,
            anotherExpansionIsActive: activeExpansionToken != nil
                && activeExpansionToken != node.id
        )
        guard !isCollapsed else { return [row] }
        return [row] + node.children.flatMap {
            flattenRows(
                for: $0,
                depth: depth + 1,
                collapsedTokens: collapsedTokens,
                expansionStates: expansionStates,
                activeExpansionToken: activeExpansionToken
            )
        }
    }
}

/// "Changed since the last stop" for variables, as registers have it. A variable is matched across
/// stops by its frame (thread, frame index and function, not the program counter), scope and path;
/// node ids carry the stop, so they never match. Values seen at the current stop accumulate across
/// re-installs (expanding a child, switching frames) and are compared with the previous stop's.
/// A variable seen for the first time is not marked; a new debug session starts over.
struct DebuggerVariableChanges: Equatable, Sendable {
    private var stop: DebuggerStopCoordinate?
    private var previous: [String: DebuggerVariableValueState] = [:]
    private var current: [String: DebuggerVariableValueState] = [:]
    private(set) var changedKeys: Set<String> = []

    static func key(frame: DebuggerFrameIdentity, scope: DebuggerVariableScopeKind, pathComponents: [String]) -> String {
        ([String(frame.thread.index), frame.thread.tid.map(String.init) ?? "-", String(frame.frameIndex),
          frame.canonicalFunctionName ?? "-", scope.rawValue] + pathComponents).joined(separator: "\u{1F}")
    }

    /// Records the scopes of an accepted snapshot. Empty scopes (running, no frame) change nothing.
    mutating func record(_ scopes: [DebuggerVariableScopeSnapshot]) {
        guard let nextStop = scopes.first?.coordinate.stop else { return }
        if nextStop != stop {
            previous = nextStop.session.epoch == stop?.session.epoch ? current : [:]
            current = [:]
            stop = nextStop
        }
        for scope in scopes {
            func visit(_ node: DebuggerVariableNode) {
                current[Self.key(frame: scope.coordinate.frame, scope: scope.scope, pathComponents: node.pathComponents)] = node.value
                node.children.forEach(visit)
            }
            scope.nodes.forEach(visit)
        }
        changedKeys = Set(current.compactMap { key, value in
            guard let old = previous[key], old != value else { return nil }
            return key
        })
    }
}

struct DebuggerMemoryInspectionPresentation: Hashable, Sendable {
    let hasInspectionCoordinate: Bool
    let regionCount: Int

    var coordinateTitle: String {
        hasInspectionCoordinate
            ? "Memory preview frame-bound"
            : "Memory preview stale-gated"
    }

    var detail: String {
        if regionCount == 0 {
            return "No VM regions recovered for this stopped snapshot."
        }
        return "\(regionCount) VM region\(regionCount == 1 ? "" : "s") recovered; read/write controls remain gated by paused live-process freshness."
    }

    var accessibilitySummary: String {
        "\(coordinateTitle). \(detail)"
    }
}

private extension DebuggerSourceFileInspectionIdentity {
    var presentationLocation: String {
        "\(file.tablePath.presentationPath):\(line)"
    }
}

private extension DebuggerCanonicalSourceTablePath {
    var presentationPath: String {
        switch self {
        case .absoluteUTF8(let value), .compilationDirectoryRelativeUTF8(let value):
            return value
        }
    }
}

private extension DebuggerSourceInspectionUnavailableReason {
    var presentationDetail: String {
        switch self {
        case .noSourceEvidence:
            return "No source row for selected frame"
        case .noDebugArtifactSeal:
            return "Source row is missing exact debug-artifact seal"
        case .debugArtifactMismatch:
            return "Source debug artifact does not match selected binary"
        case .focusDebuggedImageMismatch:
            return "Focused image differs from debugged image"
        case .unmappedRuntimeAddress:
            return "Runtime PC is not mapped to the workspace"
        }
    }
}

private extension DebuggerInspectionStaleReason {
    var presentationDetail: String {
        switch self {
        case .missingCurrentStop:
            return "Current stop coordinate is missing"
        case .missingTargetAuthority:
            return "Current target authority is missing"
        case .targetAuthorityChanged:
            return "Debug target authority changed"
        case .stopChanged:
            return "Stop coordinate changed"
        case .threadChanged:
            return "Selected thread changed"
        case .frameChanged:
            return "Selected frame changed"
        case .frameThreadMismatch:
            return "Selected frame does not belong to selected thread"
        case .processRunning:
            return "Process is running"
        case .processDetached:
            return "Process is detaching"
        case .processExited:
            return "Process exited"
        case .processCrashed:
            return "Process crashed"
        case .runtimeModuleEvidenceChanged:
            return "Runtime module evidence changed"
        case .debugArtifactEvidenceChanged:
            return "Debug artifact evidence changed"
        }
    }
}
