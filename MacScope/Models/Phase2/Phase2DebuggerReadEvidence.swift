import CryptoKit
import Foundation

enum Phase2DebuggerVariableEvidenceAvailability: Equatable, Sendable {
    case available(scopes: [Phase2DebuggerVariableScopeEvidence], wasTruncated: Bool)
    case unavailable(reason: DebuggerInspectionUnavailableReason)
}

struct Phase2DebuggerVariableScopeEvidence: Equatable, Sendable {
    let kind: DebuggerVariableScopeKind
    let variables: [Phase2DebuggerVariableEvidence]
    let wasTruncated: Bool
}

struct Phase2DebuggerVariableEvidence: Equatable, Sendable {
    let pathDigest: String
    let name: String
    let typeName: String?
    let value: DebuggerVariableValueState
    let childCount: Int
    let depth: Int
    let loadedChildCount: Int
    let childExpansion: DebuggerVariableChildExpansionState
    let descendantsWereTruncated: Bool
}

struct Phase2DebuggerFrameEvidence: Equatable, Sendable {
    let index: Int
    let address: UInt64
    let functionName: String
    let moduleName: String?
    let sourceLocation: String?
}

struct Phase2DebuggerRegisterEvidence: Equatable, Sendable {
    let name: String
    let value: String
    let role: String?
}

struct Phase2DebuggerMemoryEvidence: Equatable, Sendable {
    let address: UInt64
    let byteCount: Int
    let previewBytes: [UInt8]
    let label: String?
}

struct Phase2DebuggerReadEvidenceSnapshot: Equatable, Sendable {
    let coordinate: DebuggerInspectionCoordinate
    let processID: Int32
    let processStateDetail: String
    let statusMessage: String
    let frames: [Phase2DebuggerFrameEvidence]
    let framesWereTruncated: Bool
    let registers: [Phase2DebuggerRegisterEvidence]
    let registersWereTruncated: Bool
    let memoryRegions: [Phase2DebuggerMemoryEvidence]
    let memoryRegionsWereTruncated: Bool
    let variables: Phase2DebuggerVariableEvidenceAvailability
    let evidenceDigest: String

    init?(
        session: DebuggerSessionSnapshot,
        coordinate: DebuggerInspectionCoordinate?,
        maximumFrames: Int = 5,
        maximumRegisters: Int = 16,
        maximumMemoryRegions: Int = 5,
        maximumMemoryPreviewBytes: Int = 12,
        maximumVariables: Int = 64
    ) {
        guard case .paused(let processID, _) = session.processState,
              let coordinate,
              let stop = session.transportStopCoordinate,
              let authority = session.transportTargetAuthority,
              authority.processID == processID,
              let selectedThreadSummary = session.threads.first(where: \.isSelected),
              let selectedThread = DebuggerThreadIdentity(summary: selectedThreadSummary),
              let selectedFrameSummary = session.frames.first(where: {
                  $0.index == coordinate.frame.frameIndex
              }),
              let selectedFrame = DebuggerFrameIdentity(
                  thread: selectedThread,
                  summary: selectedFrameSummary
              ),
              coordinate.matches(
                  stop: stop,
                  targetAuthority: authority,
                  selectedThread: selectedThread,
                  selectedFrame: selectedFrame
              ),
              maximumFrames >= 0,
              maximumRegisters >= 0,
              maximumMemoryRegions >= 0,
              maximumMemoryPreviewBytes >= 0,
              maximumVariables >= 0
        else { return nil }

        self.coordinate = coordinate
        self.processID = processID
        processStateDetail = session.processState.detail
        statusMessage = session.statusMessage
        frames = session.frames.prefix(maximumFrames).map {
            Phase2DebuggerFrameEvidence(
                index: $0.index,
                address: $0.address,
                functionName: $0.functionName,
                moduleName: $0.moduleName,
                sourceLocation: $0.sourceLocation
            )
        }
        framesWereTruncated = session.frames.count > maximumFrames
        registers = session.registers.prefix(maximumRegisters).map {
            Phase2DebuggerRegisterEvidence(name: $0.name, value: $0.value, role: $0.role)
        }
        registersWereTruncated = session.registers.count > maximumRegisters
        memoryRegions = session.memoryRegions.prefix(maximumMemoryRegions).map {
            Phase2DebuggerMemoryEvidence(
                address: $0.address,
                byteCount: $0.byteCount,
                previewBytes: Array($0.previewBytes.prefix(maximumMemoryPreviewBytes)),
                label: $0.label
            )
        }
        memoryRegionsWereTruncated = session.memoryRegions.count > maximumMemoryRegions
        variables = Self.variableEvidence(
            from: session,
            coordinate: coordinate,
            maximumVariables: maximumVariables
        )
        evidenceDigest = Self.digest(
            coordinate: coordinate,
            processID: processID,
            processStateDetail: processStateDetail,
            statusMessage: statusMessage,
            frames: frames,
            framesWereTruncated: framesWereTruncated,
            registers: registers,
            registersWereTruncated: registersWereTruncated,
            memoryRegions: memoryRegions,
            memoryRegionsWereTruncated: memoryRegionsWereTruncated,
            variables: variables
        )
    }

    func matches(_ currentCoordinate: DebuggerInspectionCoordinate?) -> Bool {
        coordinate == currentCoordinate
    }

    func freshness(
        currentCoordinate: DebuggerInspectionCoordinate?,
        processState: DebuggerProcessState
    ) -> DebuggerInspectionFreshness {
        switch processState {
        case .running, .launching, .batchStopped:
            return .stale(reason: .processRunning)
        case .detaching:
            return .stale(reason: .processDetached)
        case .exited:
            return .stale(reason: .processExited)
        case .unavailable(let reason):
            return .failed(reason: reason)
        case .notAttached:
            return .unavailable(reason: .noLiveSession)
        case .paused:
            break
        }
        guard let currentCoordinate else {
            return .unavailable(reason: .noSelectedFrame)
        }
        if coordinate.stop != currentCoordinate.stop {
            return .stale(reason: .stopChanged)
        }
        if coordinate.targetDigest != currentCoordinate.targetDigest {
            return .stale(reason: .targetAuthorityChanged)
        }
        if coordinate.thread != currentCoordinate.thread {
            return .stale(reason: .threadChanged)
        }
        if coordinate.frame != currentCoordinate.frame {
            return .stale(reason: .frameChanged)
        }
        return .fresh(coordinate)
    }

    func providerVisibleEvidenceText(maximumUTF8Bytes: Int = 4_096) -> String? {
        guard maximumUTF8Bytes > 0 else { return nil }
        let maximumUntrustedFieldBytes = 512
        var lines = [
            "Target process ID: \(processID)",
            "Target identity digest: \(coordinate.targetDigest.lowercaseHex)",
            "Session epoch: \(coordinate.stop.session.epoch.rawValue.uuidString)",
            "Lifecycle revision: \(coordinate.stop.session.lifecycleRevision.rawValue)",
            "Stop revision: \(coordinate.stop.stopRevision.rawValue)",
            "Selected thread: #\(coordinate.thread.index)",
            "Selected frame: #\(coordinate.frame.frameIndex) \(coordinate.frame.programCounter.hexAddress)",
            "Debugger state: Paused",
            "Debugger detail: \(Self.boundedUntrustedField(processStateDetail, maximumBytes: maximumUntrustedFieldBytes))",
            "Status: \(Self.boundedUntrustedField(statusMessage, maximumBytes: maximumUntrustedFieldBytes))",
        ]
        if !frames.isEmpty {
            lines.append("Frames:")
            lines += frames.map {
                let module = $0.moduleName.map { " [\($0)]" } ?? ""
                let source = $0.sourceLocation.map { " · \($0)" } ?? ""
                return "- #\($0.index) \($0.address.hexAddress) \($0.functionName)\(module)\(source)"
            }
        }
        if !registers.isEmpty {
            lines.append("Registers:")
            lines += registers.map {
                let role = $0.role.map { " (\($0))" } ?? ""
                return "- \($0.name)\(role): \($0.value)"
            }
        }
        if !memoryRegions.isEmpty {
            lines.append("Memory regions:")
            lines += memoryRegions.map {
                let label = $0.label.map { " \($0)" } ?? ""
                let preview = $0.previewBytes.isEmpty
                    ? "No bytes"
                    : $0.previewBytes.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
                return "- \($0.address.hexAddress) \($0.byteCount) bytes\(label): \(preview)"
            }
        }
        switch variables {
        case .available(let scopes, let wasTruncated):
            return Self.completeVariableLineBoundedText(
                prefixLines: lines,
                scopes: scopes,
                evidenceWasTruncated: wasTruncated,
                maximumUTF8Bytes: maximumUTF8Bytes
            )
        case .unavailable(let reason):
            lines.append("Variables: unavailable — \(reason.rawValue)")
        }
        return Self.completeLineBoundedText(lines, maximumUTF8Bytes: maximumUTF8Bytes)
    }

    private static func boundedUntrustedField(_ value: String, maximumBytes: Int) -> String {
        Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            value,
            maximumBytes: maximumBytes
        )
    }

    /// Keeps every emitted evidence row complete. In particular, a provider never receives a
    /// syntactically plausible prefix of a variable value when the total evidence budget expires.
    static func completeLineBoundedText(
        _ lines: [String],
        maximumUTF8Bytes: Int,
        truncationMarker: String = "[Evidence truncated at a complete-row boundary.]"
    ) -> String? {
        guard maximumUTF8Bytes > 0 else { return nil }
        var accepted: [String] = []
        var usedBytes = 0
        var omitted = false
        for line in lines {
            let separatorBytes = accepted.isEmpty ? 0 : 1
            let required = separatorBytes + line.utf8.count
            if usedBytes + required <= maximumUTF8Bytes {
                accepted.append(line)
                usedBytes += required
            } else {
                omitted = true
                break
            }
        }
        if omitted {
            let separatorBytes = accepted.isEmpty ? 0 : 1
            let markerBytes = truncationMarker.utf8.count
            while !accepted.isEmpty && usedBytes + separatorBytes + markerBytes > maximumUTF8Bytes {
                let removed = accepted.removeLast()
                usedBytes -= removed.utf8.count
                if !accepted.isEmpty { usedBytes -= 1 }
            }
            if markerBytes <= maximumUTF8Bytes {
                accepted.append(truncationMarker)
            }
        }
        guard !accepted.isEmpty else { return nil }
        return accepted.joined(separator: "\n")
    }

    static func completeVariableLineBoundedText(
        prefixLines: [String],
        scopes: [Phase2DebuggerVariableScopeEvidence],
        evidenceWasTruncated: Bool,
        maximumUTF8Bytes: Int
    ) -> String? {
        enum LineKind: Equatable {
            case ordinary
            case scope
            case row
        }
        struct Line {
            let text: String
            let kind: LineKind
        }

        guard maximumUTF8Bytes > 0 else { return nil }
        var lines = prefixLines.map { Line(text: $0, kind: .ordinary) }
        lines.append(.init(
            text: "Variables\(evidenceWasTruncated ? " (source truncated)" : ""):",
            kind: .ordinary
        ))
        for scope in scopes {
            lines.append(.init(
                text: "\(scope.kind.rawValue.capitalized)\(scope.wasTruncated ? " (source truncated)" : ""):",
                kind: .scope
            ))
            lines += scope.variables.map {
                .init(text: providerVisibleVariableRow($0), kind: .row)
            }
        }

        let totalBytes = lines.enumerated().reduce(0) { partial, element in
            partial + (element.offset == 0 ? 0 : 1) + element.element.text.utf8.count
        }
        if totalBytes <= maximumUTF8Bytes {
            return lines.map(\.text).joined(separator: "\n")
        }

        func marker(after acceptedCount: Int) -> String {
            let remainder = lines.dropFirst(acceptedCount)
            let rows = remainder.reduce(0) { $0 + ($1.kind == .row ? 1 : 0) }
            let omittedScopes = remainder.reduce(0) { $0 + ($1.kind == .scope ? 1 : 0) }
            return "[Evidence truncated: omitted \(rows) variable rows and \(omittedScopes) variable scopes.]"
        }

        var acceptedCount = 0
        var acceptedBytes = 0
        for index in lines.indices {
            let lineBytes = (index == 0 ? 0 : 1) + lines[index].text.utf8.count
            let candidateCount = index + 1
            let candidateMarker = marker(after: candidateCount)
            let markerBytes = 1 + candidateMarker.utf8.count
            if acceptedBytes + lineBytes + markerBytes <= maximumUTF8Bytes {
                acceptedBytes += lineBytes
                acceptedCount = candidateCount
            } else {
                break
            }
        }

        let finalMarker = marker(after: acceptedCount)
        guard finalMarker.utf8.count <= maximumUTF8Bytes else { return nil }
        var accepted = lines.prefix(acceptedCount).map(\.text)
        accepted.append(finalMarker)
        return accepted.joined(separator: "\n")
    }

    private static func providerVisibleVariableRow(_ variable: Phase2DebuggerVariableEvidence) -> String {
        let indent = String(repeating: "  ", count: variable.depth)
        let type = variable.typeName.map { ": \($0)" } ?? ""
        let children: String
        if variable.childCount > 0 {
            let expansion: String
            switch variable.childExpansion {
            case .notLoaded:
                expansion = "not loaded"
            case .loading:
                expansion = "loading"
            case .loaded:
                expansion = "loaded \(variable.loadedChildCount)/\(variable.childCount) children"
            case .failed(let reason):
                expansion = "expansion failed: \(reason)"
            }
            children = " [\(expansion)\(variable.descendantsWereTruncated ? "; projection truncated" : "")]"
        } else {
            children = ""
        }
        let renderedValue: String
        switch variable.value {
        case .value(let value):
            renderedValue = value
        case .optimizedOut:
            renderedValue = "<optimized out>"
        case .unavailable(let reason):
            renderedValue = "<unavailable: \(reason)>"
        case .failed(let reason):
            renderedValue = "<failed: \(reason)>"
        }
        return "\(indent)- \(variable.name)\(type) = \(renderedValue)\(children)"
    }

    private static func variableEvidence(
        from session: DebuggerSessionSnapshot,
        coordinate: DebuggerInspectionCoordinate,
        maximumVariables: Int
    ) -> Phase2DebuggerVariableEvidenceAvailability {
        let supportedKinds: Set<DebuggerVariableScopeKind> = [.arguments, .locals, .statics]
        let sourceScopes = session.variableScopes.filter { supportedKinds.contains($0.scope) }
        guard !sourceScopes.isEmpty else {
            // Legacy and batch sessions do not publish scope snapshots. An empty collection must
            // therefore remain an honest capability tombstone rather than fabricated evidence.
            return .unavailable(reason: .unsupportedCapability)
        }
        guard sourceScopes.allSatisfy({ $0.coordinate == coordinate }) else {
            return .unavailable(reason: .ambiguousSourceEvidence)
        }

        var remaining = maximumVariables
        var projected: [Phase2DebuggerVariableScopeEvidence] = []
        var allRowsFit = true
        for source in sourceScopes {
            var nodes: [Phase2DebuggerVariableEvidence] = []
            var sourceProjectionWasTruncated = false
            for node in source.nodes {
                let result = projectVariableNode(node, depth: 0, remaining: &remaining)
                nodes += result.rows
                sourceProjectionWasTruncated = sourceProjectionWasTruncated || result.wasTruncated
            }
            let scopeWasTruncated = source.wasTruncated || sourceProjectionWasTruncated
            allRowsFit = allRowsFit && !scopeWasTruncated
            projected.append(.init(
                kind: source.scope,
                variables: nodes,
                wasTruncated: scopeWasTruncated
            ))
        }
        return .available(scopes: projected, wasTruncated: !allRowsFit)
    }

    private static func projectVariableNode(
        _ node: DebuggerVariableNode,
        depth: Int,
        remaining: inout Int
    ) -> (rows: [Phase2DebuggerVariableEvidence], wasTruncated: Bool) {
        guard remaining > 0 else { return ([], true) }
        remaining -= 1

        var descendants: [Phase2DebuggerVariableEvidence] = []
        var descendantsWereTruncated = false
        for child in node.children {
            let result = projectVariableNode(child, depth: depth + 1, remaining: &remaining)
            descendants += result.rows
            descendantsWereTruncated = descendantsWereTruncated || result.wasTruncated
        }
        let row = Phase2DebuggerVariableEvidence(
            pathDigest: node.id.lowercaseHex,
            name: node.name,
            typeName: node.typeName,
            value: node.value,
            childCount: node.childCount,
            depth: depth,
            loadedChildCount: node.children.count,
            childExpansion: node.childExpansion,
            descendantsWereTruncated: descendantsWereTruncated
        )
        return ([row] + descendants, descendantsWereTruncated)
    }

    private static func digest(
        coordinate: DebuggerInspectionCoordinate,
        processID: Int32,
        processStateDetail: String,
        statusMessage: String,
        frames: [Phase2DebuggerFrameEvidence],
        framesWereTruncated: Bool,
        registers: [Phase2DebuggerRegisterEvidence],
        registersWereTruncated: Bool,
        memoryRegions: [Phase2DebuggerMemoryEvidence],
        memoryRegionsWereTruncated: Bool,
        variables: Phase2DebuggerVariableEvidenceAvailability
    ) -> String {
        var fields = [
            "phase2-debugger-read-evidence-v3",
            "coordinate",
            coordinate.targetDigest.lowercaseHex,
            coordinate.stop.session.epoch.rawValue.uuidString,
            String(coordinate.stop.session.lifecycleRevision.rawValue),
            String(coordinate.stop.stopRevision.rawValue),
            String(coordinate.thread.index),
            String(coordinate.frame.frameIndex),
            String(coordinate.frame.programCounter),
            String(processID),
            processStateDetail,
            statusMessage,
            "truncation",
            framesWereTruncated ? "1" : "0",
            registersWereTruncated ? "1" : "0",
            memoryRegionsWereTruncated ? "1" : "0",
            "frames",
            String(frames.count),
        ]
        fields += frames.flatMap {
            [String($0.index), String($0.address), $0.functionName, $0.moduleName ?? "", $0.sourceLocation ?? ""]
        }
        fields += ["registers", String(registers.count)]
        fields += registers.flatMap { [$0.name, $0.value, $0.role ?? ""] }
        fields += ["memoryRegions", String(memoryRegions.count)]
        fields += memoryRegions.flatMap {
            [String($0.address), String($0.byteCount), Data($0.previewBytes).base64EncodedString(), $0.label ?? ""]
        }
        switch variables {
        case .available(let scopes, let wasTruncated):
            fields += ["variables", "available", wasTruncated ? "1" : "0", String(scopes.count)]
            for scope in scopes {
                fields += [
                    scope.kind.rawValue,
                    scope.wasTruncated ? "1" : "0",
                    String(scope.variables.count),
                ]
                for variable in scope.variables {
                    fields += [
                        variable.pathDigest,
                        variable.name,
                        variable.typeName ?? "",
                        String(variable.childCount),
                        String(variable.depth),
                        String(variable.loadedChildCount),
                        variable.descendantsWereTruncated ? "1" : "0",
                    ]
                    switch variable.childExpansion {
                    case .notLoaded:
                        fields += ["childrenNotLoaded"]
                    case .loading:
                        fields += ["childrenLoading"]
                    case .loaded:
                        fields += ["childrenLoaded"]
                    case .failed(let reason):
                        fields += ["childrenFailed", reason]
                    }
                    switch variable.value {
                    case .value(let value):
                        fields += ["value", value]
                    case .optimizedOut:
                        fields += ["optimizedOut"]
                    case .unavailable(let reason):
                        fields += ["unavailable", reason]
                    case .failed(let reason):
                        fields += ["failed", reason]
                    }
                }
            }
        case .unavailable(let reason):
            fields += ["variables", "unavailable", reason.rawValue]
        }
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
            canonical.append(bytes)
        }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }
}
