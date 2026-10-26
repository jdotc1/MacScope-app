import Foundation

enum Phase2DurableShellProductionError: Error, Equatable, Sendable {
    case storeReleased
    case workspaceNotDurable
    case publicLedgerWriteFailed
    case capabilityMissing
}

enum Phase2WorkspaceShellSessionCommand: String, Equatable, Sendable {
    case launch
    case writeInput
    case resize
    case signal
    case reconnect
    case pollTranscript
    case cleanup
}

/// Exact app-side admission token for one ShellBroker operation.
///
/// `commandID` is forwarded unchanged through the broker envelope. Session, request, and optional
/// surface identity fence the completion again when it returns to the store.
struct Phase2WorkspaceShellSessionOperation: Equatable, Sendable {
    let commandID: UUID
    let command: Phase2WorkspaceShellSessionCommand
    let sessionID: UUID
    let requestID: UUID
    let surface: Phase2ShellSurfaceCommandCoordinate?
}

private struct Phase2WorkspaceShellSessionAdmission: Sendable {
    let snapshot: Phase2HumanPTYSessionSnapshot
    let operation: Phase2WorkspaceShellSessionOperation
}

/// Ephemeral authority coordinate for one full-surface presentation.
///
/// The generation is deliberately not persisted. Session and request identity remain broker
/// authority; the generation only prevents a retired presentation from issuing or accepting work
/// after a replacement surface has bound to the same broker session.
struct Phase2ShellSurfaceCommandCoordinate: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let generation: UInt64

    var isStructurallyValid: Bool { generation > 0 }
}

struct Phase2ShellSurfacePixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    var isStructurallyValid: Bool {
        width > 0 && height > 0 && width <= 1_048_576 && height <= 1_048_576
    }
}

struct Phase2ShellSurfaceResizeProposal: Equatable, Sendable {
    let terminalSize: Phase2HumanPTYTerminalSize
    let pixelSize: Phase2ShellSurfacePixelSize

    var isStructurallyValid: Bool {
        terminalSize.isValid && pixelSize.isStructurallyValid
    }
}

enum Phase2ShellSurfaceResizeDisposition: Equatable, Sendable {
    case brokerResizeRequired(Phase2HumanPTYTerminalSize)
    case presentationOnly
    case coalesced
    case rejectedInvalid
    case rejectedStaleCoordinate
    case brokerAccepted
    case brokerRejected
}

enum Phase2ShellSurfaceLifecycle: Equatable, Sendable {
    case running
    case terminal(Phase2HumanPTYTerminalOutcome)
}

/// Non-persisted renderer mediation state. It carries no process handle, PTY, transport, or XPC
/// authority; those remain exclusively in ShellBroker and `Phase2HumanPTYShellSessionClient`.
struct Phase2ShellSurfaceMediationState: Equatable, Sendable {
    let coordinate: Phase2ShellSurfaceCommandCoordinate
    private(set) var proposedTerminalSize: Phase2HumanPTYTerminalSize
    private(set) var acceptedTerminalSize: Phase2HumanPTYTerminalSize
    private(set) var pixelSize: Phase2ShellSurfacePixelSize?
    private(set) var lifecycle: Phase2ShellSurfaceLifecycle

    init(
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        acceptedTerminalSize: Phase2HumanPTYTerminalSize,
        lifecycle: Phase2ShellSurfaceLifecycle
    ) {
        self.coordinate = coordinate
        proposedTerminalSize = acceptedTerminalSize
        self.acceptedTerminalSize = acceptedTerminalSize
        pixelSize = nil
        self.lifecycle = lifecycle
    }

    mutating func proposeResize(
        _ proposal: Phase2ShellSurfaceResizeProposal,
        from candidate: Phase2ShellSurfaceCommandCoordinate
    ) -> Phase2ShellSurfaceResizeDisposition {
        guard candidate == coordinate else { return .rejectedStaleCoordinate }
        guard proposal.isStructurallyValid else { return .rejectedInvalid }

        let pixelsChanged = pixelSize != proposal.pixelSize
        pixelSize = proposal.pixelSize

        if proposal.terminalSize == proposedTerminalSize {
            return pixelsChanged ? .presentationOnly : .coalesced
        }
        if proposal.terminalSize == acceptedTerminalSize {
            proposedTerminalSize = proposal.terminalSize
            return pixelsChanged ? .presentationOnly : .coalesced
        }

        proposedTerminalSize = proposal.terminalSize
        return .brokerResizeRequired(proposal.terminalSize)
    }

    mutating func acceptBrokerTerminalSize(
        _ size: Phase2HumanPTYTerminalSize,
        from candidate: Phase2ShellSurfaceCommandCoordinate
    ) -> Bool {
        guard candidate == coordinate else { return false }
        acceptedTerminalSize = size
        if proposedTerminalSize == size {
            proposedTerminalSize = size
        }
        return true
    }

    mutating func rejectProposedResize(
        from candidate: Phase2ShellSurfaceCommandCoordinate
    ) -> Bool {
        guard candidate == coordinate else { return false }
        proposedTerminalSize = acceptedTerminalSize
        return true
    }

    mutating func acceptLifecycle(
        _ lifecycle: Phase2ShellSurfaceLifecycle,
        from candidate: Phase2ShellSurfaceCommandCoordinate
    ) -> Bool {
        guard candidate == coordinate else { return false }
        self.lifecycle = lifecycle
        return true
    }
}

struct Phase2WorkspaceShellSessionProjection: Equatable, Sendable {
    static let restoredInactiveMessage = "Previous Phase 2 shell history was restored. Its process and PTY closed when the prior app connection ended; relaunch to start a new session."
    static let recoveryPendingMessage = "A durable Phase 2 shell session is available for secure broker recovery."

    let snapshot: Phase2HumanPTYSessionSnapshot?
    let inFlightCommand: Phase2WorkspaceShellSessionCommand?
    let lastError: String?
    let lastAcceptedTranscriptEvents: [Phase2HumanPTYTranscriptEvent]
    let lastBytesWritten: Int?
    let durableRecoveryIdentity: Phase2DurableShellBrokerIdentity?
    let surfaceMediation: Phase2ShellSurfaceMediationState?
    let inFlightOperation: Phase2WorkspaceShellSessionOperation?
    let surfaceGenerationHighWater: Phase2ShellSurfaceCommandCoordinate?

    init(
        snapshot: Phase2HumanPTYSessionSnapshot?,
        inFlightCommand: Phase2WorkspaceShellSessionCommand?,
        lastError: String?,
        lastAcceptedTranscriptEvents: [Phase2HumanPTYTranscriptEvent],
        lastBytesWritten: Int?,
        durableRecoveryIdentity: Phase2DurableShellBrokerIdentity? = nil,
        surfaceMediation: Phase2ShellSurfaceMediationState? = nil,
        inFlightOperation: Phase2WorkspaceShellSessionOperation? = nil,
        surfaceGenerationHighWater: Phase2ShellSurfaceCommandCoordinate? = nil
    ) {
        self.snapshot = snapshot
        self.inFlightCommand = inFlightCommand
        self.lastError = lastError
        self.lastAcceptedTranscriptEvents = lastAcceptedTranscriptEvents
        self.lastBytesWritten = lastBytesWritten
        self.durableRecoveryIdentity = durableRecoveryIdentity
        self.surfaceMediation = surfaceMediation
        self.inFlightOperation = inFlightOperation
        self.surfaceGenerationHighWater = surfaceGenerationHighWater
    }

    static let inactive = Self(
        snapshot: nil,
        inFlightCommand: nil,
        lastError: nil,
        lastAcceptedTranscriptEvents: [],
        lastBytesWritten: nil,
        durableRecoveryIdentity: nil
    )

    var isCommandInFlight: Bool {
        inFlightCommand != nil || inFlightOperation != nil
    }

    var isRunning: Bool {
        guard case .running = snapshot?.state else { return false }
        return true
    }

    var isTerminal: Bool {
        snapshot?.state.isTerminal == true
    }

    var isRestoredInactiveContext: Bool {
        isTerminal && lastError == Self.restoredInactiveMessage
    }

    var isDurableRecoveryPending: Bool {
        durableRecoveryIdentity != nil && lastError == Self.recoveryPendingMessage
    }

    /// Poll admission remains exact store authority, while an idle observation has no new UI state.
    var publicationProjection: Self {
        guard inFlightCommand == .pollTranscript || inFlightOperation?.command == .pollTranscript else { return self }
        return Self(snapshot: snapshot, inFlightCommand: nil, lastError: lastError,
            lastAcceptedTranscriptEvents: lastAcceptedTranscriptEvents, lastBytesWritten: lastBytesWritten,
            durableRecoveryIdentity: durableRecoveryIdentity, surfaceMediation: surfaceMediation,
            inFlightOperation: nil, surfaceGenerationHighWater: surfaceGenerationHighWater)
    }

    func starting(
        _ operation: Phase2WorkspaceShellSessionOperation,
        snapshot commandSnapshot: Phase2HumanPTYSessionSnapshot
    ) -> Self {
        Self(
            snapshot: commandSnapshot,
            inFlightCommand: operation.command,
            lastError: operation.command == .pollTranscript ? lastError : nil,
            lastAcceptedTranscriptEvents: operation.command == .pollTranscript ? lastAcceptedTranscriptEvents : [],
            lastBytesWritten: operation.command == .pollTranscript ? lastBytesWritten : nil,
            durableRecoveryIdentity: durableRecoveryIdentity,
            surfaceMediation: operation.command == .launch ? nil : surfaceMediation,
            inFlightOperation: operation,
            surfaceGenerationHighWater: surfaceGenerationHighWater
        )
    }

    /// Produces an intermediate accepted projection while retaining an admitted operation. Durable
    /// launch coordination persists this projection before its final broker commit, so clearing the
    /// operation here would reopen the store to overlapping work before that commit completes.
    func accepted(_ outcome: Phase2HumanPTYShellSessionCommandOutcome) -> Self {
        Self(
            snapshot: outcome.snapshot,
            inFlightCommand: inFlightCommand,
            lastError: nil,
            lastAcceptedTranscriptEvents: outcome.acceptedTranscriptEvents,
            lastBytesWritten: outcome.bytesWritten,
            durableRecoveryIdentity: outcome.brokerResponse?.durableIdentity ?? durableRecoveryIdentity,
            surfaceMediation: surfaceMediation?.accepting(outcome),
            inFlightOperation: inFlightOperation,
            surfaceGenerationHighWater: surfaceGenerationHighWater
        )
    }

    func completing(
        _ operation: Phase2WorkspaceShellSessionOperation,
        with outcome: Phase2HumanPTYShellSessionCommandOutcome
    ) -> Self? {
        guard inFlightOperation == operation else { return nil }
        let unchangedPoll = operation.command == .pollTranscript && outcome.snapshot == snapshot
            && outcome.acceptedTranscriptEvents.isEmpty && outcome.transcriptReadbackIssue == nil
        return Self(
            snapshot: outcome.snapshot,
            inFlightCommand: nil,
            lastError: unchangedPoll ? lastError : outcome.transcriptReadbackIssue,
            lastAcceptedTranscriptEvents: unchangedPoll ? lastAcceptedTranscriptEvents : outcome.acceptedTranscriptEvents,
            lastBytesWritten: operation.command == .pollTranscript ? lastBytesWritten : outcome.bytesWritten,
            durableRecoveryIdentity: outcome.brokerResponse?.durableIdentity ?? durableRecoveryIdentity,
            surfaceMediation: surfaceMediation?.accepting(outcome),
            inFlightOperation: nil,
            surfaceGenerationHighWater: surfaceGenerationHighWater
        )
    }

    func completing(_ operation: Phase2WorkspaceShellSessionOperation) -> Self? {
        guard inFlightOperation == operation else { return nil }
        return Self(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: lastError,
            lastAcceptedTranscriptEvents: lastAcceptedTranscriptEvents,
            lastBytesWritten: lastBytesWritten,
            durableRecoveryIdentity: durableRecoveryIdentity,
            surfaceMediation: surfaceMediation,
            inFlightOperation: nil,
            surfaceGenerationHighWater: surfaceGenerationHighWater
        )
    }

    func rejected(
        snapshot commandSnapshot: Phase2HumanPTYSessionSnapshot?,
        message: String
    ) -> Self {
        Self(
            snapshot: commandSnapshot ?? snapshot,
            inFlightCommand: nil,
            lastError: message,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil,
            durableRecoveryIdentity: durableRecoveryIdentity,
            surfaceMediation: surfaceMediation,
            inFlightOperation: nil,
            surfaceGenerationHighWater: surfaceGenerationHighWater
        )
    }

    func reportingRejection(message: String) -> Self {
        Self(
            snapshot: snapshot,
            inFlightCommand: inFlightCommand,
            lastError: message,
            lastAcceptedTranscriptEvents: lastAcceptedTranscriptEvents,
            lastBytesWritten: lastBytesWritten,
            durableRecoveryIdentity: durableRecoveryIdentity,
            surfaceMediation: surfaceMediation,
            inFlightOperation: inFlightOperation,
            surfaceGenerationHighWater: surfaceGenerationHighWater
        )
    }

    func bindingSurface(_ state: Phase2ShellSurfaceMediationState?) -> Self {
        Self(
            snapshot: snapshot,
            inFlightCommand: inFlightCommand,
            lastError: lastError,
            lastAcceptedTranscriptEvents: lastAcceptedTranscriptEvents,
            lastBytesWritten: lastBytesWritten,
            durableRecoveryIdentity: durableRecoveryIdentity,
            surfaceMediation: state,
            inFlightOperation: inFlightOperation,
            surfaceGenerationHighWater: state?.coordinate ?? surfaceGenerationHighWater
        )
    }

    func abandoning(_ operation: Phase2WorkspaceShellSessionOperation) -> Self? {
        guard inFlightOperation == operation else { return nil }
        return Self(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: lastError,
            lastAcceptedTranscriptEvents: lastAcceptedTranscriptEvents,
            lastBytesWritten: lastBytesWritten,
            durableRecoveryIdentity: durableRecoveryIdentity,
            surfaceMediation: surfaceMediation,
            inFlightOperation: nil,
            surfaceGenerationHighWater: surfaceGenerationHighWater
        )
    }

    var packagePhase2ShellSession: WorkspacePackagePhase2ShellSession? {
        guard let snapshot else { return nil }
        return WorkspacePackagePhase2ShellSession(
            snapshot: snapshot,
            durableBrokerIdentity: durableRecoveryIdentity
        )
    }
}

private extension Phase2WorkspaceShellSessionProjection {
    /// Renderer binding is presentation state and may change while authenticated recovery awaits
    /// the broker or document writer. Every nonpresentation field remains part of the fence.
    func hasSameDurableRecoveryState(as other: Self) -> Bool {
        snapshot == other.snapshot
            && inFlightCommand == other.inFlightCommand
            && lastError == other.lastError
            && lastAcceptedTranscriptEvents == other.lastAcceptedTranscriptEvents
            && lastBytesWritten == other.lastBytesWritten
            && durableRecoveryIdentity == other.durableRecoveryIdentity
            && inFlightOperation == other.inFlightOperation
    }

    func preservingSurfacePresentation(from current: Self) -> Self {
        var surface = current.surfaceMediation
        if let coordinate = surface?.coordinate,
           let snapshot,
           coordinate.sessionID == snapshot.sessionID,
           coordinate.requestID == snapshot.phase2ShellRequestID {
            switch snapshot.state {
            case .running:
                _ = surface?.acceptLifecycle(.running, from: coordinate)
            case .terminal(let outcome):
                _ = surface?.acceptLifecycle(.terminal(outcome), from: coordinate)
            case .idle, .launchRequested, .prepared, .launchRejected:
                surface = nil
            }
        } else {
            surface = nil
        }
        return Self(
            snapshot: snapshot,
            inFlightCommand: inFlightCommand,
            lastError: lastError,
            lastAcceptedTranscriptEvents: lastAcceptedTranscriptEvents,
            lastBytesWritten: lastBytesWritten,
            durableRecoveryIdentity: durableRecoveryIdentity,
            surfaceMediation: surface,
            inFlightOperation: inFlightOperation,
            surfaceGenerationHighWater: current.surfaceGenerationHighWater
        )
    }
}

private extension Phase2ShellSurfaceMediationState {
    func accepting(_ outcome: Phase2HumanPTYShellSessionCommandOutcome) -> Self? {
        guard outcome.snapshot.sessionID == coordinate.sessionID,
              outcome.snapshot.phase2ShellRequestID == coordinate.requestID
        else { return nil }

        var copy = self
        if let size = outcome.snapshot.currentTerminalSize {
            _ = copy.acceptBrokerTerminalSize(size, from: coordinate)
        }
        if case .terminal(let terminalOutcome) = outcome.snapshot.state {
            _ = copy.acceptLifecycle(.terminal(terminalOutcome), from: coordinate)
        }
        return copy
    }
}

enum Phase2ShellChildProcessOwner: Equatable, Sendable {
    case shellBrokerLaunchAgent
}

enum Phase2ShellPTYOwner: Equatable, Sendable {
    case shellBrokerLaunchAgent
}

struct Phase2ShellBrokerPTYBinding: Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let bindingID: UUID
    let terminalSurfaceID: UUID
    let sessionID: UUID
    let requestID: UUID
    let processIdentifier: Int32
    let terminalSize: Phase2HumanPTYTerminalSize
    let terminalBackend: Phase2TerminalEmulationBackend
    let ptyReusePolicy: Phase2TerminalPTYReusePolicy
    let debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy
    let nextTranscriptSequence: UInt64
    let boundAt: Date
    let updatedAt: Date

    /// Explicit ownership evidence: the renderer has neither a child process nor a PTY handle.
    let childProcessOwner: Phase2ShellChildProcessOwner
    let ptyOwner: Phase2ShellPTYOwner

    init(
        schemaVersion: Int = Self.schemaVersion,
        bindingID: UUID = UUID(),
        terminalSurfaceID: UUID,
        sessionID: UUID,
        requestID: UUID,
        processIdentifier: Int32,
        terminalSize: Phase2HumanPTYTerminalSize,
        terminalBackend: Phase2TerminalEmulationBackend = .ghosttyLib,
        ptyReusePolicy: Phase2TerminalPTYReusePolicy = .shellBrokerSession,
        debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy = .disabled,
        nextTranscriptSequence: UInt64,
        boundAt: Date = Date(),
        updatedAt: Date = Date(),
        childProcessOwner: Phase2ShellChildProcessOwner = .shellBrokerLaunchAgent,
        ptyOwner: Phase2ShellPTYOwner = .shellBrokerLaunchAgent
    ) {
        self.schemaVersion = schemaVersion
        self.bindingID = bindingID
        self.terminalSurfaceID = terminalSurfaceID
        self.sessionID = sessionID
        self.requestID = requestID
        self.processIdentifier = processIdentifier
        self.terminalSize = terminalSize
        self.terminalBackend = terminalBackend
        self.ptyReusePolicy = ptyReusePolicy
        self.debuggerAuthorityPolicy = debuggerAuthorityPolicy
        self.nextTranscriptSequence = nextTranscriptSequence
        self.boundAt = boundAt
        self.updatedAt = updatedAt
        self.childProcessOwner = childProcessOwner
        self.ptyOwner = ptyOwner
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.schemaVersion
            && processIdentifier > 0
            && terminalSize.isValid
            && terminalBackend == .ghosttyLib
            && ptyReusePolicy == .shellBrokerSession
            && debuggerAuthorityPolicy.isStructurallyValid
            && debuggerAuthorityPolicy.authority == .none
            && childProcessOwner == .shellBrokerLaunchAgent
            && ptyOwner == .shellBrokerLaunchAgent
    }

    var rendererChildProcessIdentifier: Int32? { nil }
    var rendererOwnsPTY: Bool { false }
}

extension WorkspaceStore {
    func makePhase2ShellLaunchPlan(
        sessionID: UUID = UUID(),
        requestID: UUID = UUID(),
        executablePath: String = "/bin/zsh",
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectoryPath: String? = nil,
        initialSize: Phase2HumanPTYTerminalSize = .defaultInteractive,
        transcriptLimits: Phase2HumanPTYTranscriptLimits = .productionMaximum
    ) -> Phase2HumanPTYLaunchPlan {
        Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectoryPath: workingDirectoryPath,
            initialSize: initialSize,
            transcriptLimits: transcriptLimits
        )
    }

    func launchPhase2ShellSession(plan: Phase2HumanPTYLaunchPlan) async {
        guard validatePhase2ShellLaunchPlanBeforeDispatch(plan) else { return }
        guard phase2ShellSession.durableRecoveryIdentity == nil else {
            rejectPhase2ShellCommand(
                snapshot: phase2ShellSession.snapshot,
                message: "The existing durable shell session must be recovered or explicitly cleaned up before launching a replacement."
            )
            return
        }
        let initial = Phase2HumanPTYSessionSnapshot.initial(sessionID: plan.sessionID)
        guard let operation = beginPhase2ShellCommand(
            .launch,
            snapshot: initial,
            requestID: plan.requestID,
            surface: nil
        ) else { return }
        if phase2ShellBrokerEndpoint == .persistentLaunchAgent {
            await launchDurablePhase2ShellSession(plan: plan, operation: operation)
            return
        }
        do {
            let outcome = try await phase2ShellSessionClient.launch(
                snapshot: initial,
                plan: plan,
                commandID: operation.commandID
            )
            _ = acceptPhase2ShellOutcome(outcome, operation: operation)
        } catch {
            rejectPhase2ShellCommand(snapshot: initial, error: error, operation: operation)
        }
    }

    private func launchDurablePhase2ShellSession(
        plan: Phase2HumanPTYLaunchPlan,
        operation: Phase2WorkspaceShellSessionOperation
    ) async {
        phase2ShellRecoveryGeneration = UUID()
        phase2ShellRecoveryTask?.cancel()
        let transactionGeneration = phase2ShellRecoveryGeneration
        let transactionWorkspaceID = workspaceID
        let transactionDocumentID = documentID
        let transactionDocumentURL = documentURL
        let initial = Phase2HumanPTYSessionSnapshot.initial(sessionID: plan.sessionID)
        let previousProjection = phase2ShellSession
        let capabilityID = UUID()
        let secret: Phase2DurableShellBrokerCapabilitySecret
        do {
            secret = try phase2DurableShellCapabilityStore.generateSecret()
        } catch {
            rejectPhase2ShellCommand(snapshot: initial, error: error, operation: operation)
            return
        }

        do {
            // Workspace package dates use a durable textual representation. Canonicalize before
            // the broker identity is minted so exact identity equality survives save/reopen.
            let createdAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let provisional = try await phase2ShellSessionClient.launchDurableProvisional(
                snapshot: initial,
                plan: plan,
                capabilityID: capabilityID,
                capabilitySecret: secret,
                createdAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(24 * 60 * 60),
                commandID: operation.commandID
            )
            let coordinator = Phase2DurableShellSessionCoordinator()
            let result = await coordinator.commitProvisionalLaunch(
                previousProjection: previousProjection,
                provisionalOutcome: provisional,
                persistCapability: { [phase2DurableShellCapabilityStore] identity in
                    try phase2DurableShellCapabilityStore.save(secret, for: identity.capabilityID)
                },
                persistPublicLedger: { [weak self] projection in
                    guard let self else { throw Phase2DurableShellProductionError.storeReleased }
                    try await self.persistPhase2DurableShellLedger(
                        projection,
                        capturedURL: transactionDocumentURL,
                        generation: transactionGeneration,
                        workspaceID: transactionWorkspaceID,
                        documentID: transactionDocumentID,
                        sessionID: plan.sessionID,
                        operation: operation
                    )
                },
                commitBrokerSession: { [phase2ShellSessionClient] identity in
                    _ = try await phase2ShellSessionClient.commitDurableSession(
                        authentication: phase2ShellSessionClient.authenticationWire(
                            identity: identity,
                            secret: secret
                        ),
                        requestID: identity.launchRequest.requestID
                    )
                },
                validateTransaction: { [weak self] in
                    guard !Task.isCancelled, let self else { return false }
                    return await self.phase2DurableTransactionMatches(
                        generation: transactionGeneration,
                        workspaceID: transactionWorkspaceID,
                        documentID: transactionDocumentID,
                        documentURL: transactionDocumentURL,
                        sessionID: plan.sessionID,
                        operation: operation
                    )
                },
                discardPublicLedger: { @MainActor [weak self] in
                    guard let self, let transactionDocumentURL else {
                        return .clearanceUnproven
                    }
                    return await self.rollbackPhase2DurableShellLedger(
                        at: transactionDocumentURL,
                        to: previousProjection,
                        generation: transactionGeneration,
                        workspaceID: transactionWorkspaceID,
                        documentID: transactionDocumentID,
                        sessionID: plan.sessionID,
                        operation: operation
                    )
                },
                discardCapability: { [phase2DurableShellCapabilityStore] capabilityID in
                    _ = try? phase2DurableShellCapabilityStore.delete(for: capabilityID)
                },
                cleanupProvisionalBrokerSession: { [phase2ShellSessionClient] identity in
                    _ = try? await phase2ShellSessionClient.cleanup(
                        snapshot: provisional.snapshot,
                        requestID: identity.launchRequest.requestID,
                        reason: "durablePrecommitFailure"
                    )
                }
            )
            guard phase2DurableTransactionMatches(
                generation: transactionGeneration,
                workspaceID: transactionWorkspaceID,
                documentID: transactionDocumentID,
                documentURL: transactionDocumentURL,
                sessionID: plan.sessionID,
                operation: operation
            ) else {
                if result.issue == .transactionSuperseded {
                    // The coordinator already ordered provisional broker cleanup before its
                    // compensating ledger write. Its explicit rollback outcome also owns whether
                    // capability deletion is safe, so do not repeat or bypass that decision here.
                    rejectPhase2ShellCommand(
                        snapshot: initial,
                        message: "Durable Phase 2 shell launch transaction was superseded.",
                        operation: operation
                    )
                    return
                }
                if let identity = provisional.brokerResponse?.durableIdentity {
                    let cleanupProven = (try? await phase2ShellSessionClient.cleanupDurableSession(
                        snapshot: provisional.snapshot,
                        identity: identity,
                        capabilitySecret: secret,
                        reason: "durableTransactionSuperseded"
                    )) != nil
                    if cleanupProven {
                        let rollbackOutcome: Phase2DurableShellPublicLedgerRollbackOutcome
                        if let transactionDocumentURL {
                            rollbackOutcome = await rollbackPhase2DurableShellLedger(
                                at: transactionDocumentURL,
                                to: previousProjection,
                                generation: transactionGeneration,
                                workspaceID: transactionWorkspaceID,
                                documentID: transactionDocumentID,
                                sessionID: plan.sessionID,
                                operation: operation
                            )
                        } else {
                            rollbackOutcome = .clearanceUnproven
                        }
                        if rollbackOutcome == .cleared {
                            _ = try? phase2DurableShellCapabilityStore.delete(
                                for: identity.capabilityID
                            )
                        }
                    }
                }
                rejectPhase2ShellCommand(
                    snapshot: initial,
                    message: "Durable Phase 2 shell launch transaction was superseded.",
                    operation: operation
                )
                return
            }
            switch result.issue {
            case nil:
                guard phase2ShellSession.inFlightOperation == operation,
                      let completed = result.projection.completing(operation)
                else { return }
                installPhase2ShellSessionProjection(completed)
            case .brokerCommitFailed:
                guard phase2ShellSession.inFlightOperation == operation else { return }
                installPhase2ShellSessionProjection(result.projection.rejected(
                    snapshot: result.projection.snapshot,
                    message: "Durable shell commit status is uncertain; recovery will verify the existing broker session before any replacement launch."
                ))
            case let issue?:
                rejectPhase2ShellCommand(
                    snapshot: initial,
                    message: "Durable Phase 2 shell launch failed before commit (\(issue.rawValue)).",
                    operation: operation
                )
            }
        } catch {
            rejectPhase2ShellCommand(snapshot: initial, error: error, operation: operation)
        }
    }

    private func phase2DurableTransactionMatches(
        generation: UUID,
        workspaceID: UUID,
        documentID: UUID,
        documentURL: URL?,
        sessionID: UUID,
        operation: Phase2WorkspaceShellSessionOperation
    ) -> Bool {
        phase2DurableContextMatches(
            generation: generation,
            workspaceID: workspaceID,
            documentID: documentID,
            documentURL: documentURL
        )
            && phase2ShellSession.snapshot?.sessionID == sessionID
            && phase2ShellSession.inFlightOperation == operation
    }

    private func phase2DurableContextMatches(
        generation: UUID,
        workspaceID: UUID,
        documentID: UUID,
        documentURL: URL?
    ) -> Bool {
        phase2ShellRecoveryGeneration == generation
            && self.workspaceID == workspaceID
            && self.documentID == documentID
            && self.documentURL == documentURL
    }

    private func rollbackPhase2DurableShellLedger(
        at url: URL,
        to projection: Phase2WorkspaceShellSessionProjection,
        generation: UUID,
        workspaceID: UUID,
        documentID: UUID,
        sessionID: UUID,
        operation: Phase2WorkspaceShellSessionOperation
    ) async -> Phase2DurableShellPublicLedgerRollbackOutcome {
        // Production rollback is deliberately refused once the launch transaction has lost any
        // part of its store authority. The bound document session is the only writer, so a moved or
        // replaced document cannot be repaired by temporarily installing stale shell state.
        guard phase2DurableTransactionMatches(
            generation: generation,
            workspaceID: workspaceID,
            documentID: documentID,
            documentURL: url,
            sessionID: sessionID,
            operation: operation
        ) else { return .clearanceUnproven }
        let persistedProjection = phase2ShellSession
        installPhase2ShellSessionProjection(projection)
        let priorDirtyToken = markDocumentMutated()
        let stagedMutationGeneration = mutationGeneration
        let outcome = await savePhase2DurableLedgerThroughBoundDocumentSession(at: url)
        let transactionStillMatches = phase2DurableTransactionMatches(
            generation: generation,
            workspaceID: workspaceID,
            documentID: documentID,
            documentURL: url,
            sessionID: sessionID,
            operation: operation
        )
        guard transactionStillMatches else {
            if phase2ShellSession.inFlightOperation == operation {
                installPhase2ShellSessionProjection(persistedProjection)
                if case .failed = outcome,
                   mutationGeneration == stagedMutationGeneration {
                    restoreDocumentDirtyToken(priorDirtyToken)
                }
            }
            return .clearanceUnproven
        }
        guard case .saved = outcome else {
            installPhase2ShellSessionProjection(persistedProjection)
            if mutationGeneration == stagedMutationGeneration {
                restoreDocumentDirtyToken(priorDirtyToken)
            }
            return .clearanceUnproven
        }
        return .cleared
    }

    private func persistPhase2DurableShellLedger(
        _ projection: Phase2WorkspaceShellSessionProjection,
        capturedURL: URL?,
        generation: UUID,
        workspaceID: UUID,
        documentID: UUID,
        sessionID: UUID,
        operation: Phase2WorkspaceShellSessionOperation
    ) async throws {
        guard projection.durableRecoveryIdentity != nil,
              let capturedURL,
              phase2DurableTransactionMatches(
                generation: generation,
                workspaceID: workspaceID,
                documentID: documentID,
                documentURL: capturedURL,
                sessionID: sessionID,
                operation: operation
              ) else {
            throw Phase2DurableShellProductionError.workspaceNotDurable
        }
        let previous = phase2ShellSession
        installPhase2ShellSessionProjection(projection)
        let priorDirtyToken = markDocumentMutated()
        let stagedMutationGeneration = mutationGeneration
        let outcome = await savePhase2DurableLedgerThroughBoundDocumentSession(at: capturedURL)
        guard phase2DurableTransactionMatches(
            generation: generation,
            workspaceID: workspaceID,
            documentID: documentID,
            documentURL: capturedURL,
            sessionID: sessionID,
            operation: operation
        ) else {
            guard case .saved = outcome else {
                throw Phase2DurableShellProductionError.publicLedgerWriteFailed
            }
            return
        }
        guard case .saved = outcome else {
            installPhase2ShellSessionProjection(previous)
            if mutationGeneration == stagedMutationGeneration {
                restoreDocumentDirtyToken(priorDirtyToken)
            }
            throw Phase2DurableShellProductionError.publicLedgerWriteFailed
        }
    }

    func schedulePhase2DurableShellRecoveryIfNeeded() {
        phase2ShellRecoveryGeneration = UUID()
        phase2ShellRecoveryTask?.cancel()
        guard phase2ShellBrokerEndpoint == .persistentLaunchAgent,
              let identity = phase2ShellSession.durableRecoveryIdentity,
              let snapshot = phase2ShellSession.snapshot else { return }

        let generation = phase2ShellRecoveryGeneration
        let expectedWorkspaceID = workspaceID
        let expectedDocumentID = documentID
        let expectedDocumentURL = documentURL
        let expectedProjection = phase2ShellSession
        phase2ShellRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Phase2DurableShellSessionCoordinator().recover(
                self.phase2ShellSession
            ) { [phase2DurableShellCapabilityStore, phase2ShellSessionClient] recoveredIdentity, _ in
                guard let secret = try phase2DurableShellCapabilityStore.load(
                    for: recoveredIdentity.capabilityID
                ) else {
                    throw Phase2DurableShellProductionError.capabilityMissing
                }
                return try await phase2ShellSessionClient.recoverDurableSession(
                    snapshot: snapshot,
                    identity: recoveredIdentity,
                    capabilitySecret: secret
                )
            }
            guard !Task.isCancelled,
                  self.phase2ShellRecoveryGeneration == generation,
                  self.workspaceID == expectedWorkspaceID,
                  self.documentID == expectedDocumentID,
                  self.documentURL == expectedDocumentURL,
                  self.phase2ShellSession.hasSameDurableRecoveryState(as: expectedProjection),
                  self.phase2ShellSession.durableRecoveryIdentity == identity else { return }
            switch result.issue {
            case nil, .invalidRecoveryIdentity, .noRecoveryIdentity:
                self.installPhase2ShellSessionProjection(
                    result.projection.preservingSurfacePresentation(from: self.phase2ShellSession)
                )
            case .expiredRecoveryIdentity, .definitiveBrokerAbsence:
                await self.clearPhase2DurableLedgerThenDeleteCapability(
                    clearedProjection: result.projection,
                    previousProjection: self.phase2ShellSession,
                    identity: identity,
                    capturedURL: expectedDocumentURL,
                    generation: generation,
                    workspaceID: expectedWorkspaceID,
                    documentID: expectedDocumentID
                )
            case .secureAttachRejected:
                // Keychain locked/unavailable and a lost broker reply are ambiguous: retain the
                // public identity so a replacement process cannot be launched over a live session.
                self.installPhase2ShellSessionProjection(
                    self.phase2ShellSession.rejected(
                        snapshot: self.phase2ShellSession.snapshot,
                        message: "Durable shell recovery could not be authenticated. Retry recovery or explicitly clean up before launching a replacement."
                    )
                )
            }
        }
    }

    @discardableResult
    private func clearPhase2DurableLedgerThenDeleteCapability(
        clearedProjection: Phase2WorkspaceShellSessionProjection,
        previousProjection: Phase2WorkspaceShellSessionProjection,
        identity: Phase2DurableShellBrokerIdentity,
        capturedURL: URL?,
        generation: UUID,
        workspaceID: UUID,
        documentID: UUID,
        operation: Phase2WorkspaceShellSessionOperation? = nil
    ) async -> Bool {
        let contextMatches = phase2DurableContextMatches(
            generation: generation,
            workspaceID: workspaceID,
            documentID: documentID,
            documentURL: capturedURL
        )
        guard contextMatches,
              phase2ShellSession.durableRecoveryIdentity == identity else {
            if let operation, phase2ShellSession.inFlightOperation == operation {
                rejectPhase2ShellCommand(
                    snapshot: previousProjection.snapshot,
                    message: "Durable shell cleanup lost its admitted workspace context; capability and session evidence were retained.",
                    operation: operation
                )
            }
            return false
        }
        if let operation {
            guard phase2ShellSession.inFlightOperation == operation else { return false }
            installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
                snapshot: clearedProjection.snapshot,
                inFlightCommand: operation.command,
                lastError: clearedProjection.lastError,
                lastAcceptedTranscriptEvents: clearedProjection.lastAcceptedTranscriptEvents,
                lastBytesWritten: clearedProjection.lastBytesWritten,
                durableRecoveryIdentity: clearedProjection.durableRecoveryIdentity,
                surfaceMediation: clearedProjection.preservingSurfacePresentation(from: phase2ShellSession).surfaceMediation,
                inFlightOperation: operation,
                surfaceGenerationHighWater: phase2ShellSession.surfaceGenerationHighWater
            ))
        } else {
            guard phase2ShellSession.hasSameDurableRecoveryState(as: previousProjection) else { return false }
            installPhase2ShellSessionProjection(
                clearedProjection.preservingSurfacePresentation(from: phase2ShellSession)
            )
        }
        let stagedProjection = phase2ShellSession
        let priorDirtyToken = markDocumentMutated()
        let stagedMutationGeneration = mutationGeneration
        guard let capturedURL else {
            if let operation, phase2ShellSession.inFlightOperation != operation { return false }
            installPhase2ShellSessionProjection(previousProjection.rejected(
                snapshot: previousProjection.snapshot,
                message: "Durable shell cleanup was proven, but clearing its workspace ledger failed; capability and identity were retained for recoverability."
            ).preservingSurfacePresentation(from: phase2ShellSession))
            if mutationGeneration == stagedMutationGeneration {
                restoreDocumentDirtyToken(priorDirtyToken)
            }
            return false
        }
        let outcome = await savePhase2DurableLedgerThroughBoundDocumentSession(at: capturedURL)
        let stillOwnsStagedState: Bool
        if let operation {
            stillOwnsStagedState = phase2ShellSession.inFlightOperation == operation
        } else {
            stillOwnsStagedState = phase2ShellSession.hasSameDurableRecoveryState(as: stagedProjection)
        }
        let completionContextMatches = phase2DurableContextMatches(
            generation: generation,
            workspaceID: workspaceID,
            documentID: documentID,
            documentURL: capturedURL
        )
        guard completionContextMatches, stillOwnsStagedState else {
            if let operation, phase2ShellSession.inFlightOperation == operation {
                installPhase2ShellSessionProjection(previousProjection.rejected(
                    snapshot: previousProjection.snapshot,
                    message: "Durable shell cleanup lost its admitted workspace context; capability and session evidence were retained."
                ).preservingSurfacePresentation(from: phase2ShellSession))
                if case .failed = outcome,
                   mutationGeneration == stagedMutationGeneration {
                    restoreDocumentDirtyToken(priorDirtyToken)
                }
            } else if operation == nil, phase2ShellSession.hasSameDurableRecoveryState(as: stagedProjection) {
                installPhase2ShellSessionProjection(previousProjection.rejected(
                    snapshot: previousProjection.snapshot,
                    message: "Durable shell recovery lost its admitted workspace context; capability and session evidence were retained."
                ).preservingSurfacePresentation(from: phase2ShellSession))
                if case .failed = outcome,
                   mutationGeneration == stagedMutationGeneration {
                    restoreDocumentDirtyToken(priorDirtyToken)
                }
            }
            return false
        }
        guard case .saved = outcome else {
            if let operation, phase2ShellSession.inFlightOperation != operation { return false }
            installPhase2ShellSessionProjection(previousProjection.rejected(
                snapshot: previousProjection.snapshot,
                message: "Durable shell cleanup was proven, but clearing its workspace ledger failed; capability and identity were retained for recoverability."
            ).preservingSurfacePresentation(from: phase2ShellSession))
            if mutationGeneration == stagedMutationGeneration {
                restoreDocumentDirtyToken(priorDirtyToken)
            }
            return false
        }
        if let operation {
            guard phase2ShellSession.inFlightOperation == operation else { return false }
            installPhase2ShellSessionProjection(
                clearedProjection.preservingSurfacePresentation(from: phase2ShellSession)
            )
        }
        do {
            _ = try phase2DurableShellCapabilityStore.delete(for: identity.capabilityID)
            return true
        } catch {
            // The ledger is definitively clear. Retaining an orphaned Keychain item is safer than
            // resurrecting public session authority; a later hygiene pass may retry deletion.
            lastIssue = "Durable shell ledger cleared, but Keychain capability deletion failed."
            return false
        }
    }

    func relaunchPhase2ShellSession(
        sessionID: UUID = UUID(),
        requestID: UUID = UUID()
    ) async {
        guard let savedPlan = phase2ShellSession.snapshot?.launchPlan else {
            rejectPhase2ShellCommand(
                snapshot: phase2ShellSession.snapshot,
                message: "No Phase 2 shell launch plan is available to relaunch."
            )
            return
        }

        let plan = makePhase2ShellLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: savedPlan.executablePath,
            arguments: savedPlan.arguments,
            environment: savedPlan.environment,
            workingDirectoryPath: savedPlan.workingDirectoryPath,
            initialSize: savedPlan.initialSize,
            transcriptLimits: savedPlan.transcriptLimits
        )
        await launchPhase2ShellSession(plan: plan)
    }

    func forgetRestoredPhase2ShellSessionContext() {
        guard phase2ShellSession.isRestoredInactiveContext else { return }
        installPhase2ShellSessionProjection(.inactive)
        markDocumentMutated()
    }

    private func validatePhase2ShellLaunchPlanBeforeDispatch(_ plan: Phase2HumanPTYLaunchPlan) -> Bool {
        let validation = Phase2HumanPTYLaunchPlanValidator.validate(plan)
        guard validation.isAccepted else {
            rejectPhase2ShellCommand(
                snapshot: .initial(sessionID: plan.sessionID),
                message: Phase2ShellLaunchDraft.invalidLaunchPlanMessage(for: validation.issues)
            )
            return false
        }

        if let workingDirectoryPath = plan.workingDirectoryPath,
           let message = Phase2ShellLaunchDraft.validateWorkingDirectoryPath(workingDirectoryPath) {
            rejectPhase2ShellCommand(snapshot: .initial(sessionID: plan.sessionID), message: message)
            return false
        }

        return true
    }

    @discardableResult
    func bindPhase2ShellSurface(
        generation: UInt64
    ) -> Phase2ShellSurfaceCommandCoordinate? {
        guard generation > 0,
              let snapshot = phase2ShellSession.snapshot,
              let requestID = snapshot.phase2ShellRequestID,
              let terminalSize = snapshot.currentTerminalSize
        else { return nil }

        let lifecycle: Phase2ShellSurfaceLifecycle
        switch snapshot.state {
        case .running:
            lifecycle = .running
        case .terminal(let outcome):
            lifecycle = .terminal(outcome)
        case .idle, .launchRequested, .prepared, .launchRejected:
            return nil
        }

        let coordinate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: snapshot.sessionID,
            requestID: requestID,
            generation: generation
        )
        if let current = phase2ShellSession.surfaceMediation?.coordinate {
            if current == coordinate { return coordinate }
        }
        if let highWater = phase2ShellSession.surfaceGenerationHighWater,
           highWater.sessionID == coordinate.sessionID,
           highWater.requestID == coordinate.requestID,
           coordinate.generation <= highWater.generation {
            return nil
        }
        let state = Phase2ShellSurfaceMediationState(
            coordinate: coordinate,
            acceptedTerminalSize: terminalSize,
            lifecycle: lifecycle
        )
        installPhase2ShellSessionProjection(phase2ShellSession.bindingSurface(state))
        return coordinate
    }

    func retirePhase2ShellSurface(_ coordinate: Phase2ShellSurfaceCommandCoordinate) {
        guard phase2ShellSession.surfaceMediation?.coordinate == coordinate else { return }
        installPhase2ShellSessionProjection(phase2ShellSession.bindingSurface(nil))
    }

    @discardableResult
    func writePhase2ShellInput(_ bytes: [UInt8]) async -> Bool {
        await performPhase2ShellInput(bytes, surface: nil)
    }

    @discardableResult
    func writePhase2ShellInput(
        _ bytes: [UInt8],
        from surface: Phase2ShellSurfaceCommandCoordinate
    ) async -> Bool {
        await performPhase2ShellInput(bytes, surface: surface)
    }

    /// Raw PTY bytes offered per writeInput command. 4 KiB of worst-case bytes
    /// (three-digit JSON array elements) encodes well under the 64 KiB broker cap.
    static let phase2ShellInputChunkBytes = 4_096

    private func performPhase2ShellInput(
        _ bytes: [UInt8],
        surface: Phase2ShellSurfaceCommandCoordinate?
    ) async -> Bool {
        guard phase2ShellSession.isRunning else {
            _ = runningPhase2ShellAdmission(for: .writeInput, surface: surface)
            return false
        }
        guard phase2ShellPendingControls.count < 64 else { return false }
        let controlToken = UUID()
        phase2ShellPendingControls.append(controlToken)
        defer {
            phase2ShellPendingControls.removeAll { $0 == controlToken }
            if phase2ShellActiveControl == controlToken { phase2ShellActiveControl = nil }
        }
        let initialSession = phase2ShellSession.snapshot?.sessionID
        let initialRequest = phase2ShellSession.snapshot?.phase2ShellRequestID
        let initialGeneration = phase2ShellRecoveryGeneration
        var offset = 0
        repeat {
            // Keep this input's FIFO ticket until its entire byte sequence is delivered.
            // Signal/Stop tickets can pass it between bounded nonblocking writes; another
            // input cannot interleave with a partially delivered paste.
            guard !Task.isCancelled,
                  phase2ShellSession.isRunning,
                  phase2ShellRecoveryGeneration == initialGeneration,
                  phase2ShellSession.snapshot?.sessionID == initialSession,
                  phase2ShellSession.snapshot?.phase2ShellRequestID == initialRequest,
                  let admission = await waitForPhase2ShellControl(
                    .writeInput, surface: surface, token: controlToken
                  ) else { return false }
            // The broker 64 KiB cap applies to the encoded JSON request, not raw
            // PTY bytes; offer at most 4 KiB per write. The loop keeps FIFO order
            // and advances only by the broker-acknowledged prefix.
            let chunk = Array(bytes.dropFirst(offset).prefix(Self.phase2ShellInputChunkBytes))
            do {
                let outcome = try await phase2ShellSessionClient.writeInput(
                    snapshot: admission.snapshot,
                    requestID: admission.operation.requestID,
                    bytes: chunk,
                    commandID: admission.operation.commandID,
                    allowPartial: true
                )
                // Publish the accepted prefix even if the same write subsequently failed.
                guard acceptPhase2ShellOutcome(outcome, operation: admission.operation) else { return false }
                offset += outcome.bytesWritten ?? 0
                if phase2ShellActiveControl == controlToken { phase2ShellActiveControl = nil }
                guard outcome.brokerResponse?.status != .failed else { return false }
                if offset == bytes.count { return true }
                // No replay of the original buffer or command ID. A fully accepted chunk
                // continues after a yield (Signal/Stop tickets queue ahead of this one);
                // while a child is not reading, back off and allow control commands through.
                if (outcome.bytesWritten ?? 0) >= chunk.count {
                    await Task.yield()
                } else {
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
            } catch {
                rejectPhase2ShellCommand(
                    snapshot: phase2ShellSession.snapshot ?? admission.snapshot,
                    error: error,
                    operation: admission.operation
                )
                return false
            }
        } while true
    }

    @discardableResult
    func executeApprovedPhase2AIShellProposalShellBrokerPTY(
        proposalID: UUID? = nil
    ) async -> Phase2AIShellBrokerPTYExecutionResult {
        let review = phase2AIShellProposalReview
        let proposal = review.proposal
        let commandText = proposal.map { Self.phase2ShellBrokerPTYCommandText(proposal: $0) } ?? ""

        guard let proposal,
              review.disposition == .staged,
              review.humanDecision == .approvedForFutureShellBrokerPTY,
              proposal.executionSurface == .shellBrokerPTY,
              Phase2AIShellProposalValidator.validate(proposal).isAccepted
        else {
            return recordPhase2AIShellBrokerPTYExecutionResult(
                proposalID: proposal?.proposalID ?? proposalID ?? UUID(),
                sessionID: phase2ShellSession.snapshot?.sessionID,
                requestID: phase2ShellSession.snapshot?.phase2ShellRequestID,
                disposition: .authorizationRejected,
                commandText: commandText,
                bytesWritten: nil,
                failureMessage: "No currently approved ShellBroker PTY shell proposal is available."
            )
        }

        if let proposalID, proposal.proposalID != proposalID {
            return recordPhase2AIShellBrokerPTYExecutionResult(
                proposalID: proposal.proposalID,
                sessionID: phase2ShellSession.snapshot?.sessionID,
                requestID: phase2ShellSession.snapshot?.phase2ShellRequestID,
                disposition: .authorizationRejected,
                commandText: commandText,
                bytesWritten: nil,
                failureMessage: "Requested proposal ID does not match the approved ShellBroker PTY shell proposal."
            )
        }

        guard beginPhase2AIShellBrokerPTYExecution(proposalID: proposal.proposalID) != nil else {
            return recordPhase2AIShellBrokerPTYExecutionResult(
                proposalID: proposal.proposalID,
                sessionID: phase2ShellSession.snapshot?.sessionID,
                requestID: phase2ShellSession.snapshot?.phase2ShellRequestID,
                disposition: .authorizationRejected,
                commandText: commandText,
                bytesWritten: nil,
                failureMessage: "The approved ShellBroker PTY shell proposal was already consumed."
            )
        }
        defer {
            consumePhase2AIShellExecutionApproval(proposalID: proposal.proposalID)
        }

        guard let admission = runningPhase2ShellAdmission(for: .writeInput)
        else {
            return recordPhase2AIShellBrokerPTYExecutionResult(
                proposalID: proposal.proposalID,
                sessionID: phase2ShellSession.snapshot?.sessionID,
                requestID: phase2ShellSession.snapshot?.phase2ShellRequestID,
                disposition: .authorizationRejected,
                commandText: commandText,
                bytesWritten: nil,
                failureMessage: "No running ShellBroker PTY session is available for app-mediated input."
            )
        }

        let commandBytes = Array((commandText + "\n").utf8)
        do {
            let outcome = try await phase2ShellSessionClient.writeInput(
                snapshot: admission.snapshot,
                requestID: admission.operation.requestID,
                bytes: commandBytes,
                commandID: admission.operation.commandID
            )
            guard let bytesWritten = outcome.bytesWritten,
                  bytesWritten == commandBytes.count else {
                let message = "ShellBroker did not prove that it accepted the complete reviewed command."
                rejectPhase2ShellCommand(
                    snapshot: admission.snapshot,
                    message: message,
                    operation: admission.operation
                )
                return recordPhase2AIShellBrokerPTYExecutionResult(
                    proposalID: proposal.proposalID,
                    sessionID: admission.operation.sessionID,
                    requestID: admission.operation.requestID,
                    disposition: .brokerRejected,
                    commandText: commandText,
                    bytesWritten: nil,
                    failureMessage: message
                )
            }
            guard acceptPhase2ShellOutcome(outcome, operation: admission.operation) else {
                return recordPhase2AIShellBrokerPTYExecutionResult(
                    proposalID: proposal.proposalID,
                    sessionID: admission.operation.sessionID,
                    requestID: admission.operation.requestID,
                    disposition: .brokerRejected,
                    commandText: commandText,
                    bytesWritten: nil,
                    failureMessage: "The ShellBroker completion no longer matched the admitted operation."
                )
            }
            return recordPhase2AIShellBrokerPTYExecutionResult(
                proposalID: proposal.proposalID,
                sessionID: admission.operation.sessionID,
                requestID: admission.operation.requestID,
                disposition: .dispatched,
                commandText: commandText,
                bytesWritten: bytesWritten,
                failureMessage: nil
            )
        } catch {
            rejectPhase2ShellCommand(
                snapshot: admission.snapshot,
                error: error,
                operation: admission.operation
            )
            return recordPhase2AIShellBrokerPTYExecutionResult(
                proposalID: proposal.proposalID,
                sessionID: admission.operation.sessionID,
                requestID: admission.operation.requestID,
                disposition: .brokerRejected,
                commandText: commandText,
                bytesWritten: nil,
                failureMessage: Self.phase2ShellExecutionFailureMessage(for: error)
            )
        }
    }

    private static func phase2ShellExecutionFailureMessage(for error: Error) -> String {
        guard let failure = error as? Phase2HumanPTYShellSessionClientError else {
            return "shellSessionOperationFailed"
        }
        return switch failure {
        case .commandRejectedLocally:
            "commandRejectedLocally"
        case .malformedBrokerResponse:
            "malformedBrokerResponse"
        case .brokerRejected:
            "brokerRejected"
        case .brokerFailed:
            "brokerFailed"
        case .commandRejectedForState:
            "commandRejectedForState"
        case .requestMismatch:
            "requestMismatch"
        case .writeByteCountMismatch:
            "writeByteCountMismatch"
        case .durableSessionAbsent:
            "durableSessionAbsent"
        }
    }

    func resizePhase2ShellSession(to size: Phase2HumanPTYTerminalSize) async {
        _ = await performPhase2ShellResize(to: size, surface: nil)
    }

    func resizePhase2ShellSession(
        _ proposal: Phase2ShellSurfaceResizeProposal,
        from surface: Phase2ShellSurfaceCommandCoordinate
    ) async -> Phase2ShellSurfaceResizeDisposition {
        guard var mediation = phase2ShellSession.surfaceMediation else {
            return .rejectedStaleCoordinate
        }
        let disposition = mediation.proposeResize(proposal, from: surface)
        switch disposition {
        case .brokerResizeRequired(let size):
            installPhase2ShellSessionProjection(phase2ShellSession.bindingSurface(mediation))
            let accepted = await performPhase2ShellResize(to: size, surface: surface)
            if accepted { return .brokerAccepted }
            guard var current = phase2ShellSession.surfaceMediation,
                  current.coordinate == surface
            else { return .rejectedStaleCoordinate }
            _ = current.rejectProposedResize(from: surface)
            installPhase2ShellSessionProjection(phase2ShellSession.bindingSurface(current))
            return .brokerRejected
        case .presentationOnly, .coalesced:
            installPhase2ShellSessionProjection(phase2ShellSession.bindingSurface(mediation))
            return disposition
        case .rejectedInvalid, .rejectedStaleCoordinate:
            return disposition
        case .brokerAccepted, .brokerRejected:
            return disposition
        }
    }

    private func performPhase2ShellResize(
        to size: Phase2HumanPTYTerminalSize,
        surface: Phase2ShellSurfaceCommandCoordinate?
    ) async -> Bool {
        if let message = Phase2ShellTerminalSizeDraft.validateTerminalSize(size) {
            rejectPhase2ShellCommand(snapshot: phase2ShellSession.snapshot, message: message)
            return false
        }
        guard let admission = runningPhase2ShellAdmission(for: .resize, surface: surface)
        else { return false }
        do {
            let outcome = try await phase2ShellSessionClient.resize(
                snapshot: admission.snapshot,
                requestID: admission.operation.requestID,
                size: size,
                commandID: admission.operation.commandID
            )
            return acceptPhase2ShellOutcome(outcome, operation: admission.operation)
        } catch {
            rejectPhase2ShellCommand(
                snapshot: admission.snapshot,
                error: error,
                operation: admission.operation
            )
            return false
        }
    }

    func signalPhase2ShellSession(_ signal: Phase2HumanPTYSignal) async {
        guard phase2ShellPendingControls.count < 64 else { return }
        let controlToken = UUID()
        phase2ShellPendingControls.insert(controlToken, at: 0)
        defer {
            phase2ShellPendingControls.removeAll { $0 == controlToken }
            if phase2ShellActiveControl == controlToken { phase2ShellActiveControl = nil }
        }
        guard let admission = await waitForPhase2ShellControl(
            .signal, surface: nil, token: controlToken
        ) else { return }
        do {
            let outcome = try await phase2ShellSessionClient.sendSignal(
                snapshot: admission.snapshot,
                requestID: admission.operation.requestID,
                signal: signal,
                commandID: admission.operation.commandID
            )
            _ = acceptPhase2ShellOutcome(outcome, operation: admission.operation)
        } catch {
            rejectPhase2ShellCommand(
                snapshot: admission.snapshot,
                error: error,
                operation: admission.operation
            )
        }
    }

    @discardableResult
    func pollPhase2ShellTranscript(
        maximumEvents: Int = 32,
        maximumBytes: Int = 4_096,
        timeoutMilliseconds: Int = 50,
        commandID: UUID = UUID(),
        surface: Phase2ShellSurfaceCommandCoordinate? = nil
    ) async -> Phase2HumanPTYShellSessionCommandOutcome? {
        // A backpressured paste keeps its input FIFO ticket, but must not stop
        // output drain: an echoing child can otherwise fill both PTY directions.
        let hasPendingControls = !phase2ShellPendingControls.isEmpty
        guard !hasPendingControls || (phase2ShellActiveControl == nil && !phase2ShellSession.isCommandInFlight)
        else { return nil }
        guard let admission = runningPhase2ShellAdmission(
            for: .pollTranscript,
            surface: surface,
            commandID: commandID
        ) else { return nil }
        do {
            let outcome = try await phase2ShellSessionClient.pollTranscript(
                snapshot: admission.snapshot,
                requestID: admission.operation.requestID,
                maximumEvents: maximumEvents,
                maximumBytes: maximumBytes,
                timeoutMilliseconds: hasPendingControls ? 0 : timeoutMilliseconds,
                commandID: admission.operation.commandID
            )
            guard acceptPhase2ShellOutcome(outcome, operation: admission.operation) else {
                return nil
            }
            return outcome
        } catch {
            rejectPhase2ShellCommand(
                snapshot: admission.snapshot,
                error: error,
                operation: admission.operation
            )
            return nil
        }
    }

    func reconnectPhase2ShellSession(
        reconnectID: UUID = UUID(),
        maximumEvents: Int = 64,
        maximumBytes: Int = 8_192
    ) async {
        guard let admission = runningPhase2ShellAdmission(for: .reconnect)
        else { return }
        do {
            let outcome = try await phase2ShellSessionClient.reconnect(
                snapshot: admission.snapshot,
                requestID: admission.operation.requestID,
                reconnectID: reconnectID,
                maximumEvents: maximumEvents,
                maximumBytes: maximumBytes,
                commandID: admission.operation.commandID
            )
            _ = acceptPhase2ShellOutcome(outcome, operation: admission.operation)
        } catch {
            rejectPhase2ShellCommand(
                snapshot: admission.snapshot,
                error: error,
                operation: admission.operation
            )
        }
    }

    func cleanupPhase2ShellSession(reason: String = "userCancel") async {
        _ = await performPhase2ShellCleanup(reason: reason, surface: nil)
    }

    @discardableResult
    func cleanupPhase2ShellSession(
        reason: String,
        from surface: Phase2ShellSurfaceCommandCoordinate
    ) async -> Bool {
        await performPhase2ShellCleanup(reason: reason, surface: surface)
    }

    private func performPhase2ShellCleanup(
        reason: String,
        surface: Phase2ShellSurfaceCommandCoordinate?
    ) async -> Bool {
        var controlToken: UUID?
        defer {
            if let controlToken {
                phase2ShellPendingControls.removeAll { $0 == controlToken }
                if phase2ShellActiveControl == controlToken { phase2ShellActiveControl = nil }
            }
        }
        let candidate: Phase2WorkspaceShellSessionAdmission?
        if phase2ShellSession.isRunning {
            guard phase2ShellPendingControls.count < 64 else { return false }
            let token = UUID()
            controlToken = token
            phase2ShellPendingControls.insert(token, at: 0)
            candidate = await waitForPhase2ShellControl(.cleanup, surface: surface, token: token)
        } else {
            candidate = cancellablePhase2ShellAdmission(for: .cleanup, surface: surface)
        }
        guard let admission = candidate else { return false }
        if let identity = phase2ShellSession.durableRecoveryIdentity {
            return await cleanupRetainedDurablePhase2ShellSession(
                snapshot: admission.snapshot,
                identity: identity,
                reason: reason,
                operation: admission.operation
            )
        }
        let durableCapabilityID = phase2ShellSession.durableRecoveryIdentity?.capabilityID
        do {
            let outcome = try await phase2ShellSessionClient.cleanup(
                snapshot: admission.snapshot,
                requestID: admission.operation.requestID,
                reason: reason,
                commandID: admission.operation.commandID
            )
            let accepted = acceptPhase2ShellOutcome(outcome, operation: admission.operation)
            if let durableCapabilityID {
                _ = try? phase2DurableShellCapabilityStore.delete(for: durableCapabilityID)
            }
            return accepted
        } catch {
            rejectPhase2ShellCommand(
                snapshot: admission.snapshot,
                error: error,
                operation: admission.operation
            )
            return false
        }
    }

    private func cleanupRetainedDurablePhase2ShellSession(
        snapshot: Phase2HumanPTYSessionSnapshot,
        identity: Phase2DurableShellBrokerIdentity,
        reason: String,
        operation: Phase2WorkspaceShellSessionOperation
    ) async -> Bool {
        let capturedGeneration = phase2ShellRecoveryGeneration
        let capturedWorkspaceID = workspaceID
        let capturedDocumentID = documentID
        let capturedURL = documentURL
        let secret: Phase2DurableShellBrokerCapabilitySecret
        do {
            guard let loaded = try phase2DurableShellCapabilityStore.load(for: identity.capabilityID) else {
                rejectPhase2ShellCommand(
                    snapshot: snapshot,
                    message: "The durable shell capability is unavailable; session evidence was retained.",
                    operation: operation
                )
                return false
            }
            secret = loaded
        } catch {
            rejectPhase2ShellCommand(
                snapshot: snapshot,
                message: "The durable shell capability could not be unlocked; session evidence was retained.",
                operation: operation
            )
            return false
        }

        do {
            let cleanup = try await phase2ShellSessionClient.cleanupDurableSession(
                snapshot: snapshot,
                identity: identity,
                capabilitySecret: secret,
                reason: reason,
                commandID: operation.commandID
            )
            let transactionStillMatches = phase2DurableTransactionMatches(
                generation: capturedGeneration,
                workspaceID: capturedWorkspaceID,
                documentID: capturedDocumentID,
                documentURL: capturedURL,
                sessionID: snapshot.sessionID,
                operation: operation
            )
            guard transactionStillMatches else {
                rejectPhase2ShellCommand(
                    snapshot: snapshot,
                    message: "Durable shell cleanup lost its admitted workspace context; capability and session evidence were retained.",
                    operation: operation
                )
                return false
            }
            if let surface = operation.surface,
               !phase2ShellSurfaceMatches(surface, snapshot: phase2ShellSession.snapshot) {
                abandonPhase2ShellOperation(operation)
                return false
            }
            return await clearPhase2DurableLedgerThenDeleteCapability(
                clearedProjection: Phase2WorkspaceShellSessionProjection(
                    snapshot: cleanup.snapshot, inFlightCommand: nil,
                    lastError: cleanup.transcriptReadbackIssue,
                    lastAcceptedTranscriptEvents: cleanup.acceptedTranscriptEvents,
                    lastBytesWritten: cleanup.bytesWritten,
                    durableRecoveryIdentity: nil,
                    surfaceGenerationHighWater: phase2ShellSession.surfaceGenerationHighWater
                ),
                previousProjection: phase2ShellSession,
                identity: identity,
                capturedURL: capturedURL,
                generation: capturedGeneration,
                workspaceID: capturedWorkspaceID,
                documentID: capturedDocumentID,
                operation: operation
            )
        } catch {
            rejectPhase2ShellCommand(
                snapshot: snapshot,
                message: "Durable shell cleanup could not be proven; capability and workspace evidence were retained.",
                operation: operation
            )
            return false
        }
    }

    /// Reserves control priority without admitting a second broker operation.
    /// The wait cannot transfer bytes or signals to a replacement session or renderer.
    private func waitForPhase2ShellControl(
        _ command: Phase2WorkspaceShellSessionCommand,
        surface: Phase2ShellSurfaceCommandCoordinate?,
        token: UUID
    ) async -> Phase2WorkspaceShellSessionAdmission? {
        guard let snapshot = phase2ShellSession.snapshot,
              let requestID = snapshot.phase2ShellRequestID,
              case .running = snapshot.state
        else { return runningPhase2ShellAdmission(for: command, surface: surface) }
        let sessionID = snapshot.sessionID
        let generation = phase2ShellRecoveryGeneration
        for _ in 0..<200 {
            guard !Task.isCancelled,
                  phase2ShellRecoveryGeneration == generation,
                  let current = phase2ShellSession.snapshot,
                  current.sessionID == sessionID,
                  current.phase2ShellRequestID == requestID,
                  case .running = current.state
            else { return nil }
            if let surface, !phase2ShellSurfaceMatches(surface, snapshot: current) { return nil }
            if !phase2ShellSession.isCommandInFlight,
               phase2ShellActiveControl == nil,
               phase2ShellPendingControls.first == token {
                phase2ShellActiveControl = token
                // Fence and install the operation together, without another suspension.
                return runningPhase2ShellAdmission(for: command, surface: surface)
            }
            do { try await Task.sleep(nanoseconds: 5_000_000) }
            catch { return nil }
        }
        return nil
    }

    private func runningPhase2ShellAdmission(
        for command: Phase2WorkspaceShellSessionCommand
    ) -> Phase2WorkspaceShellSessionAdmission? {
        runningPhase2ShellAdmission(for: command, surface: nil)
    }

    private func runningPhase2ShellAdmission(
        for command: Phase2WorkspaceShellSessionCommand,
        surface: Phase2ShellSurfaceCommandCoordinate?,
        commandID: UUID = UUID()
    ) -> Phase2WorkspaceShellSessionAdmission? {
        guard let snapshot = phase2ShellSession.snapshot else {
            if surface == nil {
                rejectPhase2ShellCommand(snapshot: nil, message: "No active Phase 2 shell session.")
            }
            return nil
        }
        if let surface, !phase2ShellSurfaceMatches(surface, snapshot: snapshot) {
            return nil
        }
        guard case .running = snapshot.state else {
            if surface == nil {
                rejectPhase2ShellCommand(
                    snapshot: snapshot,
                    message: "Phase 2 shell command \(command.rawValue) requires a running session."
                )
            }
            return nil
        }
        guard let requestID = snapshot.phase2ShellRequestID else {
            if surface == nil {
                rejectPhase2ShellCommand(
                    snapshot: snapshot,
                    message: "The active Phase 2 shell session has no request identity."
                )
            }
            return nil
        }
        guard let operation = beginPhase2ShellCommand(
            command,
            snapshot: snapshot,
            requestID: requestID,
            surface: surface,
            commandID: commandID
        ) else { return nil }
        return Phase2WorkspaceShellSessionAdmission(snapshot: snapshot, operation: operation)
    }

    private func cancellablePhase2ShellAdmission(
        for command: Phase2WorkspaceShellSessionCommand
    ) -> Phase2WorkspaceShellSessionAdmission? {
        cancellablePhase2ShellAdmission(for: command, surface: nil)
    }

    private func cancellablePhase2ShellAdmission(
        for command: Phase2WorkspaceShellSessionCommand,
        surface: Phase2ShellSurfaceCommandCoordinate?
    ) -> Phase2WorkspaceShellSessionAdmission? {
        guard let snapshot = phase2ShellSession.snapshot else {
            if surface == nil {
                rejectPhase2ShellCommand(snapshot: nil, message: "No active Phase 2 shell session.")
            }
            return nil
        }
        if let surface, !phase2ShellSurfaceMatches(surface, snapshot: snapshot) {
            return nil
        }
        switch snapshot.state {
        case .launchRequested, .prepared, .running:
            guard let requestID = snapshot.phase2ShellRequestID else {
                if surface == nil {
                    rejectPhase2ShellCommand(
                        snapshot: snapshot,
                        message: "The active Phase 2 shell session has no request identity."
                    )
                }
                return nil
            }
            guard let operation = beginPhase2ShellCommand(
                command,
                snapshot: snapshot,
                requestID: requestID,
                surface: surface
            ) else { return nil }
            return Phase2WorkspaceShellSessionAdmission(snapshot: snapshot, operation: operation)
        case .idle, .launchRejected, .terminal:
            if surface == nil {
                rejectPhase2ShellCommand(
                    snapshot: snapshot,
                    message: "Phase 2 shell command \(command.rawValue) requires a cancellable session."
                )
            }
            return nil
        }
    }

    private func phase2ShellSurfaceMatches(
        _ candidate: Phase2ShellSurfaceCommandCoordinate,
        snapshot: Phase2HumanPTYSessionSnapshot?
    ) -> Bool {
        guard candidate.isStructurallyValid,
              phase2ShellSession.surfaceMediation?.coordinate == candidate,
              let snapshot,
              snapshot.sessionID == candidate.sessionID,
              snapshot.phase2ShellRequestID == candidate.requestID
        else { return false }
        return true
    }

    private func beginPhase2ShellCommand(
        _ command: Phase2WorkspaceShellSessionCommand,
        snapshot commandSnapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        surface: Phase2ShellSurfaceCommandCoordinate?,
        commandID: UUID = UUID()
    ) -> Phase2WorkspaceShellSessionOperation? {
        guard !phase2ShellSession.isCommandInFlight else {
            rejectPhase2ShellCommand(
                snapshot: phase2ShellSession.snapshot,
                message: "Phase 2 shell command \(phase2ShellSession.inFlightCommand?.rawValue ?? "unknown") is already running."
            )
            return nil
        }

        if command == .launch,
           let activeSnapshot = phase2ShellSession.snapshot,
           !activeSnapshot.state.isTerminal {
            rejectPhase2ShellCommand(
                snapshot: activeSnapshot,
                message: "A Phase 2 shell session is already active."
            )
            return nil
        }

        let operation = Phase2WorkspaceShellSessionOperation(
            commandID: commandID,
            command: command,
            sessionID: commandSnapshot.sessionID,
            requestID: requestID,
            surface: surface
        )
        installPhase2ShellSessionProjection(
            phase2ShellSession.starting(operation, snapshot: commandSnapshot)
        )
        return operation
    }

    @discardableResult
    private func acceptPhase2ShellOutcome(
        _ outcome: Phase2HumanPTYShellSessionCommandOutcome,
        operation: Phase2WorkspaceShellSessionOperation
    ) -> Bool {
        guard phase2ShellSession.inFlightOperation == operation else { return false }
        if let surface = operation.surface,
           !phase2ShellSurfaceMatches(surface, snapshot: phase2ShellSession.snapshot) {
            abandonPhase2ShellOperation(operation)
            return false
        }
        guard outcome.snapshot.sessionID == operation.sessionID,
              outcome.snapshot.phase2ShellRequestID == operation.requestID,
              let completed = phase2ShellSession.completing(operation, with: outcome)
        else {
            rejectPhase2ShellCommand(
                snapshot: phase2ShellSession.snapshot,
                message: "The ShellBroker completion did not match its admitted session and request.",
                operation: operation
            )
            return false
        }
        let unchangedPoll = operation.command == .pollTranscript
            && outcome.snapshot == phase2ShellSession.snapshot
            && outcome.acceptedTranscriptEvents.isEmpty && outcome.transcriptReadbackIssue == nil
        installPhase2ShellSessionProjection(completed)
        if !unchangedPoll {
            recordPhase2RuntimeAuthorityUse(
                sessionID: outcome.snapshot.sessionID,
                surfaces: [.terminalEmulation, .shellBrokerPTYReuse],
                ptyReusePolicy: .shellBrokerSession,
                providerVisibleShellExecutionEnabled: false
            )
        }
        return true
    }

    private func rejectPhase2ShellCommand(
        snapshot commandSnapshot: Phase2HumanPTYSessionSnapshot?,
        error: Error,
        operation: Phase2WorkspaceShellSessionOperation
    ) {
        rejectPhase2ShellCommand(
            snapshot: commandSnapshot,
            message: String(describing: error),
            operation: operation
        )
    }

    private func rejectPhase2ShellCommand(
        snapshot commandSnapshot: Phase2HumanPTYSessionSnapshot?,
        message: String,
        operation: Phase2WorkspaceShellSessionOperation
    ) {
        guard phase2ShellSession.inFlightOperation == operation else { return }
        if let surface = operation.surface,
           !phase2ShellSurfaceMatches(surface, snapshot: phase2ShellSession.snapshot) {
            abandonPhase2ShellOperation(operation)
            return
        }
        installPhase2ShellSessionProjection(phase2ShellSession.rejected(
            snapshot: commandSnapshot,
            message: message
        ))
    }

    private func abandonPhase2ShellOperation(_ operation: Phase2WorkspaceShellSessionOperation) {
        guard let abandoned = phase2ShellSession.abandoning(operation) else { return }
        installPhase2ShellSessionProjection(abandoned)
    }

    private func rejectPhase2ShellCommand(
        snapshot commandSnapshot: Phase2HumanPTYSessionSnapshot?,
        message: String
    ) {
        if phase2ShellSession.isCommandInFlight {
            installPhase2ShellSessionProjection(
                phase2ShellSession.reportingRejection(message: message)
            )
            return
        }
        installPhase2ShellSessionProjection(phase2ShellSession.rejected(
            snapshot: commandSnapshot,
            message: message
        ))
    }

    private func recordPhase2AIShellBrokerPTYExecutionResult(
        proposalID: UUID,
        sessionID: UUID?,
        requestID: UUID?,
        disposition: Phase2AIShellBrokerPTYExecutionDisposition,
        commandText: String,
        bytesWritten: Int?,
        failureMessage: String?
    ) -> Phase2AIShellBrokerPTYExecutionResult {
        let result = Phase2AIShellBrokerPTYExecutionResult(
            proposalID: proposalID,
            sessionID: sessionID,
            requestID: requestID,
            disposition: disposition,
            commandText: commandText,
            bytesWritten: bytesWritten,
            failureMessage: failureMessage
        )
        phase2AIShellBrokerPTYExecutionResults.insert(result, at: 0)
        if phase2AIShellBrokerPTYExecutionResults.count
            > Phase2AIShellExecutionResultRetention.maximumResults {
            phase2AIShellBrokerPTYExecutionResults.removeLast(
                phase2AIShellBrokerPTYExecutionResults.count
                    - Phase2AIShellExecutionResultRetention.maximumResults
            )
        }
        if disposition == .dispatched {
            recordPhase2RuntimeAuthorityUse(
                sessionID: result.id,
                surfaces: [.terminalEmulation, .shellBrokerPTYReuse, .providerVisibleShellExecution],
                ptyReusePolicy: .shellBrokerSession,
                providerVisibleShellExecutionEnabled: true
            )
        } else {
            recordPhase2RuntimeAuthorityUse(
                sessionID: result.id,
                surfaces: [.providerVisibleShellExecution],
                providerVisibleShellExecutionEnabled: false
            )
        }
        return result
    }

    private static func phase2ShellBrokerPTYCommandText(
        proposal: Phase2AIShellCommandProposal
    ) -> String {
        ([proposal.executablePath] + proposal.arguments)
            .map(phase2ShellSingleQuotedArgument)
            .joined(separator: " ")
    }

    private static func phase2ShellSingleQuotedArgument(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

extension Phase2WorkspaceShellSessionProjection {
    func shellBrokerPTYBinding(
        terminalSurfaceID: UUID,
        now: Date = Date()
    ) -> Phase2ShellBrokerPTYBinding? {
        guard let snapshot,
              case .running(let requestID, let processIdentifier) = snapshot.state,
              let terminalSize = snapshot.currentTerminalSize
        else { return nil }

        return Phase2ShellBrokerPTYBinding(
            terminalSurfaceID: terminalSurfaceID,
            sessionID: snapshot.sessionID,
            requestID: requestID,
            processIdentifier: processIdentifier,
            terminalSize: terminalSize,
            nextTranscriptSequence: snapshot.nextTranscriptSequence,
            boundAt: now,
            updatedAt: now
        )
    }
}

private extension Phase2HumanPTYSessionSnapshot {
    var phase2ShellRequestID: UUID? {
        switch state {
        case .launchRequested(let requestID),
             .prepared(let requestID),
             .launchRejected(let requestID, _),
             .running(let requestID, _):
            requestID
        case .idle, .terminal:
            launchPlan?.requestID
        }
    }
}

extension WorkspacePackagePhase2ShellSession {
    init(
        snapshot: Phase2HumanPTYSessionSnapshot,
        durableBrokerIdentity: Phase2DurableShellBrokerIdentity? = nil
    ) {
        let terminalOutcome: Phase2HumanPTYTerminalOutcome
        let runningRequestID: UUID?
        let runningProcessIdentifier: Int32?
        if case .terminal(let outcome) = snapshot.state {
            terminalOutcome = outcome
        } else {
            terminalOutcome = .outcomeUnknown
        }
        if case .running(let requestID, let processIdentifier) = snapshot.state {
            runningRequestID = requestID
            runningProcessIdentifier = processIdentifier
        } else if let identity = durableBrokerIdentity,
                  identity.isStructurallyValid,
                  identity.sessionID == snapshot.sessionID {
            // Restored snapshots are intentionally terminal until authenticated attach.
            // Pending recovery still owns the original process envelope, even after a
            // terminal event. Only proven cleanup may clear durableRecoveryIdentity.
            runningRequestID = identity.launchRequest.requestID
            runningProcessIdentifier = identity.processIdentity.processIdentifier
        } else {
            runningRequestID = nil
            runningProcessIdentifier = nil
        }

        self.init(
            sessionID: snapshot.sessionID,
            launchPlan: snapshot.launchPlan.map(WorkspacePackagePhase2ShellLaunchPlan.init),
            terminalOutcome: WorkspacePackagePhase2ShellTerminalOutcome(terminalOutcome),
            transcriptEvents: snapshot.transcriptEvents.map(
                WorkspacePackagePhase2ShellTranscriptEvent.init
            ),
            terminalBackend: .ghosttyLib,
            ptyReusePolicy: .shellBrokerSession,
            debuggerAuthorityPolicy: .disabled,
            runningRequestID: runningRequestID,
            runningProcessIdentifier: runningProcessIdentifier,
            nextTranscriptSequence: snapshot.nextTranscriptSequence,
            durableBrokerIdentity: durableBrokerIdentity.flatMap { identity in
                // Recovery authority belongs only to this exact process envelope.
                // A terminal projection alone does not prove durable cleanup.
                guard identity.isStructurallyValid,
                      identity.sessionID == snapshot.sessionID,
                      identity.launchRequest.requestID == runningRequestID,
                      identity.processIdentity.processIdentifier == runningProcessIdentifier
                else { return nil }
                return WorkspacePackagePhase2DurableShellBrokerIdentity(identity)
            }
        )
    }

    var restoredProjection: Phase2WorkspaceShellSessionProjection {
        let pendingIdentity = durableBrokerIdentity?.phase2Identity.flatMap { identity in
            identity.isStructurallyValid && identity.sessionID == sessionID ? identity : nil
        }
        return Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .terminal(outcome: terminalOutcome.phase2Outcome),
                launchPlan: launchPlan?.phase2LaunchPlan,
                transcriptEvents: transcriptEvents.compactMap(\.phase2Event),
                issues: []
            ),
            inFlightCommand: nil,
            lastError: pendingIdentity == nil
                ? Phase2WorkspaceShellSessionProjection.restoredInactiveMessage
                : Phase2WorkspaceShellSessionProjection.recoveryPendingMessage,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil,
            durableRecoveryIdentity: pendingIdentity
        )
    }

    var restoredInactiveProjection: Phase2WorkspaceShellSessionProjection {
        var projection = restoredProjection
        guard projection.isDurableRecoveryPending else { return projection }
        projection = Phase2WorkspaceShellSessionProjection(
            snapshot: projection.snapshot,
            inFlightCommand: nil,
            lastError: Phase2WorkspaceShellSessionProjection.restoredInactiveMessage,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil,
            durableRecoveryIdentity: nil
        )
        return projection
    }
}

extension WorkspacePackagePhase2DurableShellBrokerIdentity {
    init(_ identity: Phase2DurableShellBrokerIdentity) {
        self.init(
            schemaVersion: Self.schemaVersion,
            brokerIncarnationID: identity.brokerIncarnationID,
            sessionID: identity.sessionID,
            capabilityID: identity.capabilityID,
            requestID: identity.launchRequest.requestID,
            executablePath: identity.launchRequest.executablePath,
            arguments: identity.launchRequest.arguments,
            workingDirectoryPath: identity.launchRequest.workingDirectoryPath,
            launchRequestCreatedAt: identity.launchRequest.createdAt,
            processIdentifier: identity.processIdentity.processIdentifier,
            processStartTimeUnixNanoseconds: identity.processIdentity.processStartTimeUnixNanoseconds,
            processGroupIdentifier: identity.processIdentity.processGroupIdentifier,
            createdAt: identity.createdAt,
            expiresAt: identity.expiresAt,
            nextTranscriptSequence: identity.nextTranscriptSequence,
            capabilityVerifierSHA256: identity.capabilityVerifierSHA256
        )
    }

    var phase2Identity: Phase2DurableShellBrokerIdentity? {
        guard isStructurallyValid else { return nil }
        let launchRequest = Phase2DurableShellBrokerLaunchRequest(
            brokerIncarnationID: brokerIncarnationID,
            sessionID: sessionID,
            capabilityID: capabilityID,
            requestID: requestID,
            executablePath: executablePath,
            arguments: arguments,
            workingDirectoryPath: workingDirectoryPath,
            createdAt: launchRequestCreatedAt,
            expiresAt: expiresAt
        )
        return Phase2DurableShellBrokerIdentity(
            launchRequest: launchRequest,
            processIdentity: Phase2DurableShellBrokerProcessIdentity(
                processIdentifier: processIdentifier,
                processStartTimeUnixNanoseconds: processStartTimeUnixNanoseconds,
                executablePath: executablePath,
                processGroupIdentifier: processGroupIdentifier
            ),
            createdAt: createdAt,
            expiresAt: expiresAt,
            nextTranscriptSequence: nextTranscriptSequence,
            capabilityVerifierSHA256: capabilityVerifierSHA256
        )
    }
}

extension WorkspacePackagePhase2ShellLaunchPlan {
    init(_ plan: Phase2HumanPTYLaunchPlan) {
        self.init(
            sessionID: plan.sessionID,
            requestID: plan.requestID,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            environment: plan.environment,
            workingDirectoryPath: plan.workingDirectoryPath,
            columns: plan.initialSize.columns,
            rows: plan.initialSize.rows,
            transcriptMaximumEvents: plan.transcriptLimits.maximumEvents,
            transcriptMaximumEventBytes: plan.transcriptLimits.maximumEventBytes,
            transcriptMaximumCumulativeBytes: plan.transcriptLimits.maximumCumulativeBytes
        )
    }

    var phase2LaunchPlan: Phase2HumanPTYLaunchPlan {
        Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectoryPath: workingDirectoryPath,
            initialSize: .init(columns: columns, rows: rows),
            transcriptLimits: .init(
                maximumEvents: transcriptMaximumEvents,
                maximumEventBytes: transcriptMaximumEventBytes,
                maximumCumulativeBytes: transcriptMaximumCumulativeBytes
            )
        )
    }
}

extension WorkspacePackagePhase2ShellTerminalOutcome {
    init(_ outcome: Phase2HumanPTYTerminalOutcome) {
        switch outcome {
        case .exited(let status):
            self = .exited(status: status)
        case .signaled(let signal):
            self = .signaled(signal.rawValue)
        case .canceled:
            self = .canceled
        case .interrupted:
            self = .interrupted
        case .brokerCrashed:
            self = .brokerCrashed
        case .outcomeUnknown:
            self = .outcomeUnknown
        }
    }

    var phase2Outcome: Phase2HumanPTYTerminalOutcome {
        switch self {
        case .exited(let status):
            .exited(status: status)
        case .signaled(let signal):
            .signaled(Phase2HumanPTYSignal(rawValue: signal) ?? .terminate)
        case .canceled:
            .canceled
        case .interrupted:
            .interrupted
        case .brokerCrashed:
            .brokerCrashed
        case .outcomeUnknown:
            .outcomeUnknown
        }
    }
}

extension WorkspacePackagePhase2ShellTranscriptEvent {
    init(_ event: Phase2HumanPTYTranscriptEvent) {
        self.init(
            sessionID: event.sessionID,
            sequence: event.sequence,
            source: event.source.rawValue,
            payload: WorkspacePackagePhase2ShellTranscriptPayload(event.payload)
        )
    }

    var phase2Event: Phase2HumanPTYTranscriptEvent? {
        guard let source = Phase2HumanPTYEventSource(rawValue: source),
              let payload = payload.phase2Payload
        else { return nil }
        return Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: sequence,
            source: source,
            payload: payload
        )
    }
}

extension WorkspacePackagePhase2ShellTranscriptPayload {
    init(_ payload: Phase2HumanPTYEventPayload) {
        switch payload {
        case .input(let bytes):
            self = .input(Data(bytes))
        case .output(let stream, let bytes):
            self = .output(stream: stream.rawValue, bytes: Data(bytes))
        case .resize(let columns, let rows):
            self = .resize(columns: columns, rows: rows)
        case .signal(let signal):
            self = .signal(signal.rawValue)
        case .reconnect(let reconnectID):
            self = .reconnect(reconnectID: reconnectID)
        case .gap(let reason, let lostByteCount):
            self = .gap(reason: reason.rawValue, lostByteCount: lostByteCount)
        case .terminal(let outcome):
            self = .terminal(WorkspacePackagePhase2ShellTerminalOutcome(outcome))
        }
    }

    var phase2Payload: Phase2HumanPTYEventPayload? {
        switch self {
        case .input(let bytes):
            return .input(Array(bytes))
        case .output(let stream, let bytes):
            guard let value = Phase2HumanPTYOutputStream(rawValue: stream) else { return nil }
            return .output(stream: value, bytes: Array(bytes))
        case .resize(let columns, let rows):
            return .resize(columns: columns, rows: rows)
        case .signal(let signal):
            guard let value = Phase2HumanPTYSignal(rawValue: signal) else { return nil }
            return .signal(value)
        case .reconnect(let reconnectID):
            return .reconnect(reconnectID: reconnectID)
        case .gap(let reason, let lostByteCount):
            guard let value = Phase2HumanPTYGapReason(rawValue: reason) else { return nil }
            return .gap(reason: value, lostByteCount: lostByteCount)
        case .terminal(let outcome):
            return .terminal(outcome.phase2Outcome)
        }
    }
}
