import Foundation

/// Pure lifecycle reducer for the future ShellBroker process boundary.
///
/// This model intentionally does not spawn, signal, reap, or observe a process. It freezes the
/// ownership and cleanup facts the real XPC service must prove before it can claim to own a human
/// terminal process.
struct Phase2ShellBrokerLifecycleSnapshot: Equatable, Sendable {
    let sessionID: UUID
    let state: Phase2ShellBrokerLifecycleState
    let launchPlan: Phase2HumanPTYLaunchPlan?
    let ownedProcess: Phase2ShellBrokerOwnedProcess?
    let cleanupProof: Phase2ShellBrokerCleanupProof?
    let issues: [Phase2ShellBrokerLifecycleIssue]

    static func initial(sessionID: UUID) -> Self {
        Self(
            sessionID: sessionID,
            state: .idle,
            launchPlan: nil,
            ownedProcess: nil,
            cleanupProof: nil,
            issues: []
        )
    }
}

enum Phase2ShellBrokerLifecycleState: Equatable, Sendable {
    case idle
    case prepared(requestID: UUID)
    case running(requestID: UUID, processIdentifier: Int32)
    case cleanupRequested(requestID: UUID, processIdentifier: Int32, reason: Phase2ShellBrokerCleanupReason)
    case cleanedUp(requestID: UUID, processIdentifier: Int32, outcome: Phase2HumanPTYTerminalOutcome)
    case launchRejected(requestID: UUID, reason: String)

    var isTerminal: Bool {
        switch self {
        case .cleanedUp, .launchRejected:
            true
        case .idle, .prepared, .running, .cleanupRequested:
            false
        }
    }
}

struct Phase2ShellBrokerOwnedProcess: Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let processIdentifier: Int32
    let executablePath: String
}

enum Phase2ShellBrokerCleanupReason: String, Equatable, Sendable {
    case userCancel
    case brokerTermination
    case appShutdown
    case launchFailure
}

struct Phase2ShellBrokerCleanupProof: Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let processIdentifier: Int32
    let observedProcessAbsent: Bool
    let outcome: Phase2HumanPTYTerminalOutcome
}

enum Phase2ShellBrokerLifecycleIssue: Equatable, Sendable {
    case invalidLaunchPlan([Phase2HumanPTYLaunchPlanValidationIssue])
    case transitionNotAllowed(state: Phase2ShellBrokerLifecycleState, attempted: Phase2ShellBrokerLifecycleAction)
    case sessionMismatch(expected: UUID, actual: UUID)
    case requestMismatch(expected: UUID, actual: UUID)
    case invalidProcessIdentifier(Int32)
    case executablePathMismatch(expected: String, actual: String)
    case cleanupProcessMismatch(expected: Int32, actual: Int32)
    case cleanupMissingAbsenceProof(processIdentifier: Int32)
}

enum Phase2ShellBrokerLifecycleAction: String, Equatable, Sendable {
    case prepareLaunch
    case rejectLaunch
    case publishRunningProcess
    case requestCleanup
    case completeCleanup
}

enum Phase2ShellBrokerLifecycleReducer {
    static func prepareLaunch(
        _ snapshot: Phase2ShellBrokerLifecycleSnapshot,
        plan: Phase2HumanPTYLaunchPlan
    ) -> Phase2ShellBrokerLifecycleSnapshot {
        guard case .idle = snapshot.state else {
            return snapshot.recording(.transitionNotAllowed(state: snapshot.state, attempted: .prepareLaunch))
        }
        guard plan.sessionID == snapshot.sessionID else {
            return snapshot.recording(.sessionMismatch(expected: snapshot.sessionID, actual: plan.sessionID))
        }

        let validation = Phase2HumanPTYLaunchPlanValidator.validate(plan)
        guard validation.isAccepted else {
            return snapshot.recording(.invalidLaunchPlan(validation.issues))
        }

        return snapshot.replacing(
            state: .prepared(requestID: plan.requestID),
            launchPlan: plan
        )
    }

    static func rejectLaunch(
        _ snapshot: Phase2ShellBrokerLifecycleSnapshot,
        requestID: UUID,
        reason: String
    ) -> Phase2ShellBrokerLifecycleSnapshot {
        guard case .prepared(let expectedRequestID) = snapshot.state else {
            return snapshot.recording(.transitionNotAllowed(state: snapshot.state, attempted: .rejectLaunch))
        }
        guard expectedRequestID == requestID else {
            return snapshot.recording(.requestMismatch(expected: expectedRequestID, actual: requestID))
        }

        return snapshot.replacing(state: .launchRejected(requestID: requestID, reason: reason))
    }

    static func publishRunningProcess(
        _ snapshot: Phase2ShellBrokerLifecycleSnapshot,
        process: Phase2ShellBrokerOwnedProcess
    ) -> Phase2ShellBrokerLifecycleSnapshot {
        guard case .prepared(let expectedRequestID) = snapshot.state else {
            return snapshot.recording(.transitionNotAllowed(state: snapshot.state, attempted: .publishRunningProcess))
        }
        guard process.sessionID == snapshot.sessionID else {
            return snapshot.recording(.sessionMismatch(expected: snapshot.sessionID, actual: process.sessionID))
        }
        guard expectedRequestID == process.requestID else {
            return snapshot.recording(.requestMismatch(expected: expectedRequestID, actual: process.requestID))
        }
        guard process.processIdentifier > 0 else {
            return snapshot.recording(.invalidProcessIdentifier(process.processIdentifier))
        }
        if let launchPlan = snapshot.launchPlan, process.executablePath != launchPlan.executablePath {
            return snapshot.recording(.executablePathMismatch(
                expected: launchPlan.executablePath,
                actual: process.executablePath
            ))
        }

        return snapshot.replacing(
            state: .running(requestID: process.requestID, processIdentifier: process.processIdentifier),
            ownedProcess: process
        )
    }

    static func requestCleanup(
        _ snapshot: Phase2ShellBrokerLifecycleSnapshot,
        reason: Phase2ShellBrokerCleanupReason
    ) -> Phase2ShellBrokerLifecycleSnapshot {
        guard case .running(let requestID, let processIdentifier) = snapshot.state else {
            return snapshot.recording(.transitionNotAllowed(state: snapshot.state, attempted: .requestCleanup))
        }

        return snapshot.replacing(state: .cleanupRequested(
            requestID: requestID,
            processIdentifier: processIdentifier,
            reason: reason
        ))
    }

    static func completeCleanup(
        _ snapshot: Phase2ShellBrokerLifecycleSnapshot,
        proof: Phase2ShellBrokerCleanupProof
    ) -> Phase2ShellBrokerLifecycleSnapshot {
        guard case .cleanupRequested(let expectedRequestID, let expectedProcessIdentifier, _) = snapshot.state else {
            return snapshot.recording(.transitionNotAllowed(state: snapshot.state, attempted: .completeCleanup))
        }
        guard proof.sessionID == snapshot.sessionID else {
            return snapshot.recording(.sessionMismatch(expected: snapshot.sessionID, actual: proof.sessionID))
        }
        guard expectedRequestID == proof.requestID else {
            return snapshot.recording(.requestMismatch(expected: expectedRequestID, actual: proof.requestID))
        }
        guard expectedProcessIdentifier == proof.processIdentifier else {
            return snapshot.recording(.cleanupProcessMismatch(
                expected: expectedProcessIdentifier,
                actual: proof.processIdentifier
            ))
        }
        guard proof.observedProcessAbsent else {
            return snapshot.recording(.cleanupMissingAbsenceProof(processIdentifier: proof.processIdentifier))
        }

        return snapshot.replacing(
            state: .cleanedUp(
                requestID: proof.requestID,
                processIdentifier: proof.processIdentifier,
                outcome: proof.outcome
            ),
            cleanupProof: proof
        )
    }
}

private extension Phase2ShellBrokerLifecycleSnapshot {
    func replacing(
        state: Phase2ShellBrokerLifecycleState? = nil,
        launchPlan: Phase2HumanPTYLaunchPlan? = nil,
        ownedProcess: Phase2ShellBrokerOwnedProcess? = nil,
        cleanupProof: Phase2ShellBrokerCleanupProof? = nil
    ) -> Self {
        Self(
            sessionID: sessionID,
            state: state ?? self.state,
            launchPlan: launchPlan ?? self.launchPlan,
            ownedProcess: ownedProcess ?? self.ownedProcess,
            cleanupProof: cleanupProof ?? self.cleanupProof,
            issues: issues
        )
    }

    func recording(_ issue: Phase2ShellBrokerLifecycleIssue) -> Self {
        Self(
            sessionID: sessionID,
            state: state,
            launchPlan: launchPlan,
            ownedProcess: ownedProcess,
            cleanupProof: cleanupProof,
            issues: issues + [issue]
        )
    }
}
