import Foundation

enum Phase2TerminalEmulationBackend: String, CaseIterable, Codable, Equatable, Sendable {
    /// Ghostty's reusable VT core, consumed through the local ghostty-vt.xcframework artifact.
    case ghosttyLib
    /// Conservative text renderer used when no VT renderer is linked or an older package decodes.
    case transcriptFallback
}

enum Phase2TerminalPTYReusePolicy: String, CaseIterable, Codable, Equatable, Sendable {
    case disabled
    case shellBrokerSession

    var canReuseShellBrokerPTY: Bool {
        self == .shellBrokerSession
    }
}

enum Phase2RuntimeAuthoritySurface: String, CaseIterable, Codable, Equatable, Sendable {
    case terminalEmulation
    case shellBrokerPTYReuse
    case debuggerReadOnly
    case debuggerControl
    case providerVisibleShellExecution
}

struct Phase2TerminalRuntimeAuthorityRecord: Codable, Equatable, Sendable, Identifiable {
    static let schemaVersion = 1

    let id: UUID
    let schemaVersion: Int
    let sessionID: UUID
    let surfaces: Set<Phase2RuntimeAuthoritySurface>
    let terminalBackend: Phase2TerminalEmulationBackend
    let ptyReusePolicy: Phase2TerminalPTYReusePolicy
    let debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy
    let providerVisibleShellExecutionEnabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        schemaVersion: Int = Self.schemaVersion,
        sessionID: UUID,
        surfaces: Set<Phase2RuntimeAuthoritySurface>,
        terminalBackend: Phase2TerminalEmulationBackend,
        ptyReusePolicy: Phase2TerminalPTYReusePolicy,
        debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy,
        providerVisibleShellExecutionEnabled: Bool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.surfaces = surfaces
        self.terminalBackend = terminalBackend
        self.ptyReusePolicy = ptyReusePolicy
        self.debuggerAuthorityPolicy = debuggerAuthorityPolicy
        self.providerVisibleShellExecutionEnabled = providerVisibleShellExecutionEnabled
        self.createdAt = createdAt
    }

    var debuggerAuthorityEnabled: Bool {
        debuggerAuthorityPolicy.authority != .none
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.schemaVersion
            && !surfaces.isEmpty
            && (!ptyReusePolicy.canReuseShellBrokerPTY || surfaces.contains(.shellBrokerPTYReuse))
            && debuggerAuthorityPolicy.isStructurallyValid
            && (!debuggerAuthorityEnabled || surfaces.contains(.debuggerReadOnly) || surfaces.contains(.debuggerControl))
            && (!providerVisibleShellExecutionEnabled || surfaces.contains(.providerVisibleShellExecution))
    }
}

enum Phase2DebuggerToolAuthority: String, CaseIterable, Codable, Equatable, Sendable {
    case none
    case readOnlyInspection
    case controlledRuntimeActions
}

struct Phase2DebuggerAuthorityToolPolicy: Codable, Equatable, Sendable {
    let authority: Phase2DebuggerToolAuthority
    let allowFrames: Bool
    let allowRegisters: Bool
    let allowVariables: Bool
    let allowMemoryRead: Bool
    let allowRunControl: Bool
    let allowBreakpointMutation: Bool

    static let disabled = Self(
        authority: .none,
        allowFrames: false,
        allowRegisters: false,
        allowVariables: false,
        allowMemoryRead: false,
        allowRunControl: false,
        allowBreakpointMutation: false
    )

    static let readOnlyInspection = Self(
        authority: .readOnlyInspection,
        allowFrames: true,
        allowRegisters: true,
        allowVariables: true,
        allowMemoryRead: true,
        allowRunControl: false,
        allowBreakpointMutation: false
    )

    static let controlledRuntimeActions = Self(
        authority: .controlledRuntimeActions,
        allowFrames: true,
        allowRegisters: true,
        allowVariables: true,
        allowMemoryRead: true,
        allowRunControl: true,
        allowBreakpointMutation: false
    )

    var isStructurallyValid: Bool {
        switch authority {
        case .none:
            return !allowFrames && !allowRegisters && !allowVariables && !allowMemoryRead
                && !allowRunControl && !allowBreakpointMutation
        case .readOnlyInspection:
            return !allowRunControl && !allowBreakpointMutation
        case .controlledRuntimeActions:
            return allowFrames && allowRegisters && allowVariables && allowMemoryRead
                && allowRunControl && !allowBreakpointMutation
        }
    }
}
