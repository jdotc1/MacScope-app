import Foundation

enum Phase2HumanPTYShellSessionClientError: Error, Equatable, Sendable {
    case commandRejectedLocally([Phase2HumanPTYSessionReducerIssue])
    case malformedBrokerResponse(String)
    case brokerRejected(command: Phase2ShellBrokerCommandKind, issues: [String])
    case brokerFailed(command: Phase2ShellBrokerCommandKind, issues: [String])
    case commandRejectedForState(
        command: Phase2ShellBrokerCommandKind,
        state: Phase2HumanPTYSessionState
    )
    case requestMismatch(
        command: Phase2ShellBrokerCommandKind,
        expected: UUID,
        actual: UUID
    )
    case writeByteCountMismatch(expected: Int, actual: Int?)
    case durableSessionAbsent
}

struct Phase2HumanPTYShellSessionCommandOutcome: Equatable, Sendable {
    let snapshot: Phase2HumanPTYSessionSnapshot
    let brokerResponse: Phase2ShellBrokerCommandResponse?
    let acceptedTranscriptEvents: [Phase2HumanPTYTranscriptEvent]
    let bytesWritten: Int?
    let transcriptReadbackIssue: String?

    init(
        snapshot: Phase2HumanPTYSessionSnapshot,
        brokerResponse: Phase2ShellBrokerCommandResponse? = nil,
        acceptedTranscriptEvents: [Phase2HumanPTYTranscriptEvent] = [],
        bytesWritten: Int? = nil,
        transcriptReadbackIssue: String? = nil
    ) {
        self.snapshot = snapshot
        self.brokerResponse = brokerResponse
        self.acceptedTranscriptEvents = acceptedTranscriptEvents
        self.bytesWritten = bytesWritten
        self.transcriptReadbackIssue = transcriptReadbackIssue
    }
}

/// App-side R2 HumanPTY command client.
///
/// This type is intentionally above the raw `ShellBrokerXPCTransport` and below any
/// future terminal UI/store layer. It is the first app-owned seam that converts
/// validated HumanPTY session intent into ShellBroker XPC commands and folds the
/// accepted broker evidence back through `Phase2HumanPTYSessionReducer`.
struct Phase2HumanPTYShellSessionClient: Sendable {
    private let transport: ShellBrokerXPCTransport
    init(transport: ShellBrokerXPCTransport) {
        self.transport = transport
    }

    func launchDurableProvisional(
        snapshot: Phase2HumanPTYSessionSnapshot,
        plan: Phase2HumanPTYLaunchPlan,
        capabilityID: UUID,
        capabilitySecret: Phase2DurableShellBrokerCapabilitySecret,
        createdAt: Date,
        expiresAt: Date,
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let handshake = try await transport.handshake()
        guard let brokerIncarnationID = handshake.brokerIncarnationID else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("missing broker incarnation")
        }
        let requested = try locallyAccepted(
            snapshot,
            command: Phase2HumanPTYBrokerCommand(
                commandID: commandID,
                sessionID: snapshot.sessionID,
                authority: .human,
                payload: .launch(plan)
            )
        )
        let durableLaunch = Phase2DurableShellBrokerLaunchRequest(
            brokerIncarnationID: brokerIncarnationID,
            sessionID: plan.sessionID,
            capabilityID: capabilityID,
            requestID: plan.requestID,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            workingDirectoryPath: plan.workingDirectoryPath,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        let capabilityBytes = capabilitySecret.withKeychainBytes(Array.init)
        let request = try shellCommand(
            commandID: commandID,
            command: .launchDurableProcess,
            payload: Phase2ShellBrokerWireCodec.encodeLaunchDurableProcessRequest(
                Phase2ShellBrokerLaunchDurableProcessRequest(
                    launch: Phase2ShellBrokerLaunchProcessRequest(plan: plan),
                    durableLaunch: durableLaunch,
                    capabilitySecretBytes: capabilityBytes
                )
            )
        )
        let response = try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .launchDurableProcess,
            sessionID: plan.sessionID,
            requestID: plan.requestID
        )
        guard let identity = response.durableIdentity,
              identity.isStructurallyValid,
              identity.launchRequest == durableLaunch,
              response.durableClientAttached == true,
              response.processIdentifier == identity.processIdentity.processIdentifier else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("invalid durable launch identity")
        }
        var reduced = Phase2HumanPTYSessionReducer.reduce(
            requested,
            event: .init(sessionID: plan.sessionID, eventID: UUID(), payload: .prepared(requestID: plan.requestID))
        )
        reduced = Phase2HumanPTYSessionReducer.reduce(
            reduced,
            event: .init(
                sessionID: plan.sessionID,
                eventID: UUID(),
                payload: .running(processIdentifier: identity.processIdentity.processIdentifier)
            )
        )
        return .init(snapshot: reduced, brokerResponse: response)
    }

    /// Commits a durable session only after the app has persisted both its public identity and
    /// Keychain capability. The broker must not treat launch alone as permission to survive the
    /// originating app connection.
    func commitDurableSession(
        authentication: Phase2ShellBrokerDurableAuthenticationWire,
        requestID: UUID,
        commandID: UUID = UUID()
    ) async throws -> Phase2ShellBrokerCommandResponse {
        let request = try shellCommand(
            commandID: commandID,
            command: .commitDurableSession,
            payload: Phase2ShellBrokerWireCodec.encodeDurableSessionRequest(
                Phase2ShellBrokerDurableSessionRequest(authentication: authentication)
            )
        )
        return try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .commitDurableSession,
            sessionID: authentication.sessionID,
            requestID: requestID
        )
    }

    func recoverDurableSession(
        snapshot: Phase2HumanPTYSessionSnapshot,
        identity: Phase2DurableShellBrokerIdentity,
        capabilitySecret: Phase2DurableShellBrokerCapabilitySecret,
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let handshake = try await transport.handshake()
        guard handshake.brokerIncarnationID == identity.brokerIncarnationID else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("broker incarnation mismatch")
        }
        let authentication = authenticationWire(identity: identity, secret: capabilitySecret)
        let status = try await durableResponse(
            command: .durableSessionStatus,
            authentication: authentication,
            requestID: identity.launchRequest.requestID,
            commandID: commandID
        )
        guard status.lifecycleState != "terminal" else {
            throw Phase2HumanPTYShellSessionClientError.durableSessionAbsent
        }
        guard status.durableIdentity == identity,
              status.processIdentifier == identity.processIdentity.processIdentifier,
              status.executablePath == identity.processIdentity.executablePath,
              status.lifecycleState == "running",
              let brokerCursor = status.nextTranscriptSequence,
              brokerCursor >= snapshot.nextTranscriptSequence else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("durable status mismatch")
        }
        let attached = try await durableResponse(
            command: .attachDurableSession,
            authentication: authentication,
            requestID: identity.launchRequest.requestID,
            commandID: UUID()
        )
        guard attached.durableIdentity == identity,
              attached.durableClientAttached == true,
              attached.processIdentifier == identity.processIdentity.processIdentifier,
              attached.nextTranscriptSequence == brokerCursor else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("durable attach mismatch")
        }
        let recovered = Phase2HumanPTYSessionSnapshot(
            sessionID: identity.sessionID,
            state: .running(
                requestID: identity.launchRequest.requestID,
                processIdentifier: identity.processIdentity.processIdentifier
            ),
            launchPlan: snapshot.launchPlan,
            transcriptEvents: snapshot.transcriptEvents,
            issues: snapshot.issues
        )
        return .init(snapshot: recovered, brokerResponse: attached)
    }

    @discardableResult
    func cleanupDurableSession(
        snapshot: Phase2HumanPTYSessionSnapshot,
        identity: Phase2DurableShellBrokerIdentity,
        capabilitySecret: Phase2DurableShellBrokerCapabilitySecret,
        reason: String,
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let authentication = authenticationWire(identity: identity, secret: capabilitySecret)
        let status = try await durableResponse(
            command: .durableSessionStatus,
            authentication: authentication,
            requestID: identity.launchRequest.requestID,
            commandID: UUID()
        )
        guard status.durableIdentity == identity else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("durable cleanup status mismatch")
        }
        if status.lifecycleState == "terminal" {
            let outcome: Phase2HumanPTYTerminalOutcome
            if case .terminal(let priorOutcome) = snapshot.state {
                outcome = priorOutcome
            } else {
                outcome = .outcomeUnknown
            }
            return .init(snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: snapshot.sessionID, state: .terminal(outcome: outcome),
                launchPlan: snapshot.launchPlan, transcriptEvents: snapshot.transcriptEvents,
                issues: snapshot.issues), brokerResponse: status)
        }
        _ = try await durableResponse(
            command: .attachDurableSession,
            authentication: authentication,
            requestID: identity.launchRequest.requestID,
            commandID: UUID()
        )
        let outcome = try await cleanup(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: identity.sessionID,
                state: .running(
                    requestID: identity.launchRequest.requestID,
                    processIdentifier: identity.processIdentity.processIdentifier
                ),
                launchPlan: snapshot.launchPlan,
                transcriptEvents: snapshot.transcriptEvents,
                issues: snapshot.issues
            ),
            requestID: identity.launchRequest.requestID,
            reason: reason,
            commandID: commandID
        )
        guard outcome.snapshot.state.isTerminal else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("durable cleanup lacked terminal proof")
        }
        return outcome
    }

    private func durableResponse(
        command: Phase2ShellBrokerCommandKind,
        authentication: Phase2ShellBrokerDurableAuthenticationWire,
        requestID: UUID,
        commandID: UUID
    ) async throws -> Phase2ShellBrokerCommandResponse {
        let request = try shellCommand(
            commandID: commandID,
            command: command,
            payload: Phase2ShellBrokerWireCodec.encodeDurableSessionRequest(
                .init(authentication: authentication)
            )
        )
        return try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: command,
            sessionID: authentication.sessionID,
            requestID: requestID
        )
    }

    func authenticationWire(
        identity: Phase2DurableShellBrokerIdentity,
        secret: Phase2DurableShellBrokerCapabilitySecret
    ) -> Phase2ShellBrokerDurableAuthenticationWire {
        Phase2ShellBrokerDurableAuthenticationWire(
            brokerIncarnationID: identity.brokerIncarnationID,
            sessionID: identity.sessionID,
            capabilityID: identity.capabilityID,
            capabilitySecretBytes: secret.withKeychainBytes(Array.init)
        )
    }

    func launch(
        snapshot: Phase2HumanPTYSessionSnapshot,
        plan: Phase2HumanPTYLaunchPlan,
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let command = Phase2HumanPTYBrokerCommand(
            commandID: commandID,
            sessionID: snapshot.sessionID,
            authority: .human,
            payload: .launch(plan)
        )
        let requested = try locallyAccepted(snapshot, command: command)
        let request = try shellCommand(
            commandID: commandID,
            command: .launchProcess,
            payload: Phase2ShellBrokerWireCodec.encodeLaunchProcessRequest(
                Phase2ShellBrokerLaunchProcessRequest(plan: plan)
            )
        )
        let response = try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .launchProcess,
            sessionID: snapshot.sessionID,
            requestID: plan.requestID
        )
        guard let processIdentifier = response.processIdentifier, processIdentifier > 0 else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("accepted launch missing processIdentifier")
        }

        var reduced = Phase2HumanPTYSessionReducer.reduce(
            requested,
            event: Phase2HumanPTYBrokerEvent(
                sessionID: snapshot.sessionID,
                eventID: UUID(),
                payload: .prepared(requestID: plan.requestID)
            )
        )
        reduced = Phase2HumanPTYSessionReducer.reduce(
            reduced,
            event: Phase2HumanPTYBrokerEvent(
                sessionID: snapshot.sessionID,
                eventID: UUID(),
                payload: .running(processIdentifier: processIdentifier)
            )
        )
        return Phase2HumanPTYShellSessionCommandOutcome(snapshot: reduced, brokerResponse: response)
    }

    func writeInput(
        snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        bytes: [UInt8],
        commandID: UUID = UUID(),
        allowPartial: Bool = false
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let command = Phase2HumanPTYBrokerCommand(
            commandID: commandID,
            sessionID: snapshot.sessionID,
            authority: .human,
            payload: .writeInput(bytes)
        )
        _ = try locallyAccepted(snapshot, command: command)
        try admitRequest(
            requestID,
            snapshot: snapshot,
            command: .writeInput,
            requirement: .running
        )
        let request = try shellCommand(
            commandID: commandID,
            command: .writeInput,
            payload: Phase2ShellBrokerWireCodec.encodeWriteInputRequest(
                Phase2ShellBrokerWriteInputRequest(
                    sessionID: snapshot.sessionID,
                    requestID: requestID,
                    bytes: bytes
                )
            )
        )
        let response = try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .writeInput,
            sessionID: snapshot.sessionID,
            requestID: requestID,
            allowInputProgress: allowPartial
        )
        let countIsValid = response.bytesWritten.map { count in
            count >= 0 && count <= bytes.count
                && (response.status != .accepted || count == bytes.count)
                && (response.status != .partial || count < bytes.count)
        } ?? false
        guard allowPartial ? countIsValid : response.bytesWritten == bytes.count else {
            throw Phase2HumanPTYShellSessionClientError.writeByteCountMismatch(
                expected: bytes.count,
                actual: response.bytesWritten
            )
        }
        let reduced = await reduceMutationTranscript(from: response, into: snapshot, requestID: requestID)
        return Phase2HumanPTYShellSessionCommandOutcome(
            snapshot: reduced.snapshot,
            brokerResponse: response,
            acceptedTranscriptEvents: reduced.events,
            bytesWritten: response.bytesWritten,
            transcriptReadbackIssue: response.status == .failed
                ? "Input stopped after \(response.bytesWritten ?? 0) bytes: \(response.issues.joined(separator: "; "))"
                : reduced.issue
        )
    }

    func resize(
        snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        size: Phase2HumanPTYTerminalSize,
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let command = Phase2HumanPTYBrokerCommand(
            commandID: commandID,
            sessionID: snapshot.sessionID,
            authority: .human,
            payload: .resize(size)
        )
        _ = try locallyAccepted(snapshot, command: command)
        try admitRequest(
            requestID,
            snapshot: snapshot,
            command: .resizeTerminal,
            requirement: .running
        )
        let request = try shellCommand(
            commandID: commandID,
            command: .resizeTerminal,
            payload: Phase2ShellBrokerWireCodec.encodeResizeTerminalRequest(
                Phase2ShellBrokerResizeTerminalRequest(
                    sessionID: snapshot.sessionID,
                    requestID: requestID,
                    columns: size.columns,
                    rows: size.rows
                )
            )
        )
        let response = try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .resizeTerminal,
            sessionID: snapshot.sessionID,
            requestID: requestID
        )
        let reduced = await reduceMutationTranscript(from: response, into: snapshot, requestID: requestID)
        return Phase2HumanPTYShellSessionCommandOutcome(
            snapshot: reduced.snapshot,
            brokerResponse: response,
            acceptedTranscriptEvents: reduced.events,
            transcriptReadbackIssue: reduced.issue
        )
    }

    func sendSignal(
        snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        signal: Phase2HumanPTYSignal,
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let command = Phase2HumanPTYBrokerCommand(
            commandID: commandID,
            sessionID: snapshot.sessionID,
            authority: .human,
            payload: .signal(signal)
        )
        _ = try locallyAccepted(snapshot, command: command)
        try admitRequest(
            requestID,
            snapshot: snapshot,
            command: .sendSignal,
            requirement: .running
        )
        let request = try shellCommand(
            commandID: commandID,
            command: .sendSignal,
            payload: Phase2ShellBrokerWireCodec.encodeSendSignalRequest(
                Phase2ShellBrokerSendSignalRequest(
                    sessionID: snapshot.sessionID,
                    requestID: requestID,
                    signal: signal
                )
            )
        )
        let response = try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .sendSignal,
            sessionID: snapshot.sessionID,
            requestID: requestID
        )
        let reduced = await reduceMutationTranscript(from: response, into: snapshot, requestID: requestID)
        return Phase2HumanPTYShellSessionCommandOutcome(
            snapshot: reduced.snapshot,
            brokerResponse: response,
            acceptedTranscriptEvents: reduced.events,
            transcriptReadbackIssue: reduced.issue
        )
    }

    func pollTranscript(
        snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        maximumEvents: Int = 32,
        maximumBytes: Int = 4_096,
        timeoutMilliseconds: Int = 50,
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        try admitRequest(
            requestID,
            snapshot: snapshot,
            command: .pollTranscript,
            requirement: .running
        )
        let request = try shellCommand(
            commandID: commandID,
            command: .pollTranscript,
            payload: Phase2ShellBrokerWireCodec.encodePollTranscriptRequest(
                Phase2ShellBrokerPollTranscriptRequest(
                    sessionID: snapshot.sessionID,
                    requestID: requestID,
                    afterSequence: snapshot.transcriptEvents.last?.sequence ?? 0,
                    maximumEvents: maximumEvents,
                    maximumBytes: maximumBytes,
                    timeoutMilliseconds: timeoutMilliseconds
                )
            )
        )
        let response = try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .pollTranscript,
            sessionID: snapshot.sessionID,
            requestID: requestID
        )
        let reduced = try reduceTranscriptEvents(from: response, into: snapshot)
        return Phase2HumanPTYShellSessionCommandOutcome(
            snapshot: reduced.snapshot,
            brokerResponse: response,
            acceptedTranscriptEvents: reduced.events
        )
    }

    func reconnect(
        snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        reconnectID: UUID,
        maximumEvents: Int = 64,
        maximumBytes: Int = 8_192,
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let command = Phase2HumanPTYBrokerCommand(
            commandID: commandID,
            sessionID: snapshot.sessionID,
            authority: .app,
            payload: .reconnect(reconnectID: reconnectID)
        )
        _ = try locallyAccepted(snapshot, command: command)
        try admitRequest(
            requestID,
            snapshot: snapshot,
            command: .reconnectSession,
            requirement: .reconnectable
        )
        let request = try shellCommand(
            commandID: commandID,
            command: .reconnectSession,
            payload: Phase2ShellBrokerWireCodec.encodeReconnectSessionRequest(
                Phase2ShellBrokerReconnectSessionRequest(
                    sessionID: snapshot.sessionID,
                    requestID: requestID,
                    reconnectID: reconnectID,
                    afterSequence: snapshot.transcriptEvents.last?.sequence ?? 0,
                    maximumEvents: maximumEvents,
                    maximumBytes: maximumBytes
                )
            )
        )
        let response = try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .reconnectSession,
            sessionID: snapshot.sessionID,
            requestID: requestID
        )
        let reduced = try reduceTranscriptEvents(from: response, into: snapshot)
        return Phase2HumanPTYShellSessionCommandOutcome(
            snapshot: reduced.snapshot,
            brokerResponse: response,
            acceptedTranscriptEvents: reduced.events
        )
    }

    func cleanup(
        snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID,
        reason: String = "userCancel",
        commandID: UUID = UUID()
    ) async throws -> Phase2HumanPTYShellSessionCommandOutcome {
        let command = Phase2HumanPTYBrokerCommand(
            commandID: commandID,
            sessionID: snapshot.sessionID,
            authority: .human,
            payload: .cancel
        )
        _ = try locallyAccepted(snapshot, command: command)
        try admitRequest(
            requestID,
            snapshot: snapshot,
            command: .cleanupProcess,
            requirement: .cancellable
        )
        let request = try shellCommand(
            commandID: commandID,
            command: .cleanupProcess,
            payload: Phase2ShellBrokerWireCodec.encodeCleanupProcessRequest(
                Phase2ShellBrokerCleanupProcessRequest(
                    sessionID: snapshot.sessionID,
                    requestID: requestID,
                    reason: reason
                )
            )
        )
        let response = try await acceptedResponse(
            try await transport.perform(request),
            commandID: commandID,
            command: .cleanupProcess,
            sessionID: snapshot.sessionID,
            requestID: requestID
        )
        guard response.observedProcessAbsent == true else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse(
                "cleanup lacked process-absence proof"
            )
        }
        let outcome = try terminalOutcome(from: response.outcome)
        let reply = await reduceMutationTranscript(from: response, into: snapshot, requestID: requestID)
        let reduced: Phase2HumanPTYSessionSnapshot
        switch reply.snapshot.state {
        case .terminal(let replyOutcome):
            guard replyOutcome == outcome else {
                throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse(
                    "cleanup terminal reply disagreed with exit outcome"
                )
            }
            reduced = reply.snapshot
        case .running:
            let next = Phase2HumanPTYSessionReducer.reduce(
                reply.snapshot,
                event: Phase2HumanPTYBrokerEvent(
                    sessionID: snapshot.sessionID,
                    eventID: UUID(),
                    payload: .brokerTerminated(outcome)
                )
            )
            let newIssues = Array(next.issues.dropFirst(reply.snapshot.issues.count))
            guard newIssues.isEmpty, next.state == .terminal(outcome: outcome) else {
                throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse(
                    "cleanup terminal evidence was rejected"
                )
            }
            reduced = next
        case .idle, .launchRequested, .prepared, .launchRejected:
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse(
                "cleanup did not produce a terminal session"
            )
        }
        return Phase2HumanPTYShellSessionCommandOutcome(
            snapshot: reduced,
            brokerResponse: response,
            acceptedTranscriptEvents: reply.events,
            transcriptReadbackIssue: reply.issue
        )
    }

    private func locallyAccepted(
        _ snapshot: Phase2HumanPTYSessionSnapshot,
        command: Phase2HumanPTYBrokerCommand
    ) throws -> Phase2HumanPTYSessionSnapshot {
        let reduced = Phase2HumanPTYSessionReducer.reduce(snapshot, command: command)
        let newIssues = Array(reduced.issues.dropFirst(snapshot.issues.count))
        guard newIssues.isEmpty else {
            throw Phase2HumanPTYShellSessionClientError.commandRejectedLocally(newIssues)
        }
        return reduced
    }

    private func admitRequest(
        _ requestID: UUID,
        snapshot: Phase2HumanPTYSessionSnapshot,
        command: Phase2ShellBrokerCommandKind,
        requirement: Phase2HumanPTYRequestStateRequirement
    ) throws {
        let expectedRequestID: UUID
        switch (requirement, snapshot.state) {
        case let (.running, .running(requestID, _)),
             let (.reconnectable, .prepared(requestID)),
             let (.reconnectable, .running(requestID, _)),
             let (.cancellable, .launchRequested(requestID)),
             let (.cancellable, .prepared(requestID)),
             let (.cancellable, .running(requestID, _)):
            expectedRequestID = requestID
        default:
            throw Phase2HumanPTYShellSessionClientError.commandRejectedForState(
                command: command,
                state: snapshot.state
            )
        }
        guard requestID == expectedRequestID else {
            throw Phase2HumanPTYShellSessionClientError.requestMismatch(
                command: command,
                expected: expectedRequestID,
                actual: requestID
            )
        }
    }

    private func acceptedResponse(
        _ response: Phase2ShellBrokerCommandResponse,
        commandID: UUID,
        command: Phase2ShellBrokerCommandKind,
        sessionID: UUID,
        requestID: UUID,
        allowInputProgress: Bool = false
    ) throws -> Phase2ShellBrokerCommandResponse {
        guard response.commandID == commandID else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("command ID mismatch")
        }
        guard response.command == command else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("command mismatch")
        }
        guard response.sessionID == sessionID else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("session mismatch")
        }
        guard response.requestID == requestID else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("request mismatch")
        }

        switch response.status {
        case .accepted:
            return response
        case .partial:
            guard allowInputProgress, command == .writeInput else {
                throw Phase2HumanPTYShellSessionClientError.brokerFailed(command: command, issues: ["partial input delivery"])
            }
            return response
        case .rejected, .invalid:
            throw Phase2HumanPTYShellSessionClientError.brokerRejected(command: command, issues: response.issues)
        case .failed:
            if allowInputProgress, command == .writeInput, response.bytesWritten != nil { return response }
            throw Phase2HumanPTYShellSessionClientError.brokerFailed(command: command, issues: response.issues)
        }
    }

    /// A successful mutation may follow output captured by the durable broker's independent
    /// drain. Read that ordered prefix instead of rejecting or replaying an already-applied action.
    private func reduceMutationTranscript(
        from response: Phase2ShellBrokerCommandResponse,
        into snapshot: Phase2HumanPTYSessionSnapshot,
        requestID: UUID
    ) async -> (snapshot: Phase2HumanPTYSessionSnapshot, events: [Phase2HumanPTYTranscriptEvent], issue: String?) {
        do {
            let reduced = try reduceTranscriptEvents(from: response, into: snapshot)
            return (reduced.snapshot, reduced.events, nil)
        } catch {
            // The mutation receipt remains authoritative even if its transcript needs readback.
        }
        let targetSequence = response.transcriptEvents.map(\.sequence).max() ?? 0
        var current = snapshot
        var events: [Phase2HumanPTYTranscriptEvent] = []
        for _ in 0..<8 {
            do {
                try Task.checkCancellation()
                let next = try await pollTranscript(snapshot: current, requestID: requestID,
                    maximumEvents: 64, maximumBytes: 16_384, timeoutMilliseconds: 0)
                current = next.snapshot
                events.append(contentsOf: next.acceptedTranscriptEvents)
                if (current.transcriptEvents.last?.sequence ?? 0) >= targetSequence {
                    return (current, events, nil)
                }
                if next.acceptedTranscriptEvents.isEmpty { break }
            } catch {
                return (current, events, "Mutation accepted; transcript readback deferred: \(error)")
            }
        }
        return (current, events, "Mutation accepted; transcript readback deferred after bounded catch-up.")
    }

    private func reduceTranscriptEvents(
        from response: Phase2ShellBrokerCommandResponse,
        into snapshot: Phase2HumanPTYSessionSnapshot
    ) throws -> (snapshot: Phase2HumanPTYSessionSnapshot, events: [Phase2HumanPTYTranscriptEvent]) {
        var reduced = snapshot
        var acceptedEvents: [Phase2HumanPTYTranscriptEvent] = []
        for wireEvent in response.transcriptEvents {
            guard let event = wireEvent.makeEvent() else {
                throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("malformed transcript event")
            }
            let next = Phase2HumanPTYSessionReducer.reduce(
                reduced,
                event: Phase2HumanPTYBrokerEvent(
                    sessionID: snapshot.sessionID,
                    eventID: UUID(),
                    payload: .transcript(event)
                )
            )
            let newIssues = Array(next.issues.dropFirst(reduced.issues.count))
            guard newIssues.isEmpty else {
                throw Phase2HumanPTYShellSessionClientError.commandRejectedLocally(newIssues)
            }
            reduced = next
            acceptedEvents.append(event)
        }
        return (reduced, acceptedEvents)
    }

    private func shellCommand(
        commandID: UUID,
        command: Phase2ShellBrokerCommandKind,
        payload: Data
    ) throws -> Phase2ShellBrokerCommandRequest {
        let request = Phase2ShellBrokerCommandRequest(
            commandID: commandID,
            command: command,
            payload: payload
        )
        let encoded = try Phase2ShellBrokerWireCodec.encodeCommandRequest(request)
        guard encoded.count <= Phase2ShellBrokerProtocolIdentity.maximumMessageBytes else {
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse("command envelope too large")
        }
        return request
    }

    private func terminalOutcome(from rawOutcome: String?) throws -> Phase2HumanPTYTerminalOutcome {
        switch rawOutcome {
        case "canceled":
            return .canceled
        case "interrupted":
            return .interrupted
        case "brokerCrashed":
            return .brokerCrashed
        case "outcomeUnknown":
            return .outcomeUnknown
        case let value? where value.hasPrefix("exited:"):
            let encodedStatus = String(value.dropFirst("exited:".count))
            guard !encodedStatus.isEmpty, let status = Int32(encodedStatus) else {
                throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse(
                    "invalid cleanup exit status"
                )
            }
            return .exited(status: status)
        case let value? where value.hasPrefix("signaled:"):
            let encodedSignal = String(value.dropFirst("signaled:".count))
            guard let signal = Phase2HumanPTYSignal(rawValue: encodedSignal) else {
                throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse(
                    "invalid cleanup signal"
                )
            }
            return .signaled(signal)
        default:
            throw Phase2HumanPTYShellSessionClientError.malformedBrokerResponse(
                "missing or invalid cleanup outcome"
            )
        }
    }
}

private enum Phase2HumanPTYRequestStateRequirement {
    case running
    case reconnectable
    case cancellable
}

private extension Phase2ShellBrokerLaunchProcessRequest {
    init(plan: Phase2HumanPTYLaunchPlan) {
        self.init(
            sessionID: plan.sessionID,
            requestID: plan.requestID,
            executablePath: plan.executablePath,
            arguments: plan.arguments,
            environment: plan.environment,
            workingDirectoryPath: plan.workingDirectoryPath,
            columns: plan.initialSize.columns,
            rows: plan.initialSize.rows,
            maximumTranscriptEvents: plan.transcriptLimits.maximumEvents,
            maximumTranscriptEventBytes: plan.transcriptLimits.maximumEventBytes,
            maximumTranscriptCumulativeBytes: plan.transcriptLimits.maximumCumulativeBytes
        )
    }
}
