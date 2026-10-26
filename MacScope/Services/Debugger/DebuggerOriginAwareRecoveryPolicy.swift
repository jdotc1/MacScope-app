import Foundation

/// Product reasons that can require automatic debugger-session recovery. They deliberately share
/// one origin-aware decision boundary so a newly added recovery call site cannot choose its own
/// target disposition behavior.
enum DebuggerRecoveryReason: String, CaseIterable, Hashable, Sendable {
    case partialBreakpointMutation
    case partialThreadSelection
    case partialFrameSelection
    case partialRegisterWrite
    case partialMemoryWrite
    case partialLaunch
    case callbackOrHelperAuthorityLoss
    case runToCursorCleanup
    case unavailableLogicalCatalog
    case sessionReplacement
    case adapterInterruption
    case userRequestedSessionEnd
    case windowClose
    case appTermination

    static func partialMutation(operation: DebuggerOperation) -> Self {
        switch operation {
        case .selectThread: .partialThreadSelection
        case .selectFrame: .partialFrameSelection
        case .writeRegister: .partialRegisterWrite
        case .writeMemory: .partialMemoryWrite
        case .launch: .partialLaunch
        case .replaceBreakpoints, .reconcileLogicalBreakpoints, .updateWatchpoints: .partialBreakpointMutation
        case .runToCursor: .runToCursorCleanup
        default: .callbackOrHelperAuthorityLoss
        }
    }
}

/// A semantic recovery instruction. Only the two exact-authority cases permit a target command;
/// uncertain evidence can retire MacScope-owned transport and reobserve, but cannot signal or
/// otherwise mutate the target.
enum DebuggerOriginAwareRecoveryDecision: Equatable, Sendable {
    case terminateLaunched(DebuggerSessionTargetAuthority)
    case detachAttached(DebuggerSessionTargetAuthority)
    case retireOwnedTransportAndReobserve(DebuggerSessionTargetAuthority?)
    case retireIdleTransport

    var authorizesTargetCommand: Bool {
        switch self {
        case .terminateLaunched, .detachAttached:
            true
        case .retireOwnedTransportAndReobserve, .retireIdleTransport:
            false
        }
    }

    var authorizesAutomaticTermination: Bool {
        if case .terminateLaunched = self { return true }
        return false
    }
}

/// Pure, fail-closed origin-aware policy over reducer-owned evidence.
///
/// A target command is authorized only when process phase, observed PID, disposition, and exact
/// accepted target authority form one coherent live state. Any invalidation, missing authority, or
/// mismatch retains at most the previously accepted authority as a reobservation hint.
struct DebuggerOriginAwareRecoveryPolicy: Equatable, Sendable {
    let reason: DebuggerRecoveryReason

    func decision(for state: DebuggerReducerState) -> DebuggerOriginAwareRecoveryDecision {
        if isProvenIdleOrTerminal(state) {
            return .retireIdleTransport
        }

        guard let authority = exactLiveAuthority(in: state) else {
            return .retireOwnedTransportAndReobserve(state.acceptedTargetAuthority)
        }

        switch authority.origin {
        case .launched:
            return .terminateLaunched(authority)
        case .attached:
            return .detachAttached(authority)
        }
    }

    private func exactLiveAuthority(
        in state: DebuggerReducerState
    ) -> DebuggerSessionTargetAuthority? {
        guard !state.isInvalidated,
              state.pendingRequest == nil,
              let authority = state.acceptedTargetAuthority,
              state.observedProcessID == authority.processID else {
            return nil
        }

        switch (state.processPhase, state.targetDisposition) {
        case let (.running(phasePID), .running(dispositionPID)):
            guard phasePID == authority.processID,
                  dispositionPID == authority.processID,
                  state.stopRevision == nil else { return nil }
        case let (.stopped(phasePID, _), .stopped(dispositionPID)):
            guard phasePID == authority.processID,
                  dispositionPID == authority.processID,
                  state.stopCoordinate?.session == state.sessionCoordinate else { return nil }
        default:
            return nil
        }

        return authority
    }

    private func isProvenIdleOrTerminal(_ state: DebuggerReducerState) -> Bool {
        switch (state.processPhase, state.targetDisposition) {
        case (.noTarget, .notStarted), (.noTarget, .notApplicable):
            return !state.isInvalidated
                && state.pendingRequest == nil
                && state.observedProcessID == nil
                && state.acceptedTargetAuthority == nil
                && state.stopRevision == nil

        case let (.exited(processID, phaseCode), .exited(dispositionCode)):
            return phaseCode == dispositionCode
                && terminalIdentityIsCoherent(processID: processID, state: state)

        case let (.detached(processID), .detached),
             let (.terminated(processID), .terminated):
            return terminalIdentityIsCoherent(processID: processID, state: state)

        default:
            return false
        }
    }

    private func terminalIdentityIsCoherent(
        processID: Int32,
        state: DebuggerReducerState
    ) -> Bool {
        guard processID > 0,
              state.observedProcessID == processID,
              state.stopRevision == nil else {
            return false
        }
        if let authority = state.acceptedTargetAuthority {
            return authority.processID == processID
        }
        return true
    }
}
