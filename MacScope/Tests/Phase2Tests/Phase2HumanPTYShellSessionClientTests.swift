import XCTest

@testable import MacScope

final class Phase2HumanPTYShellSessionClientTests: XCTestCase {
    func testInterleavedDurableEchoBetweenKeysReadsOrderedDeltaWithoutRewritingInput() async throws {
        let sessionID = clientUUID(900)
        let requestID = clientUUID(901)
        let transport = InterleavedEchoTransport(sessionID: sessionID, requestID: requestID)
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        var snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)
        for text in ["e", "c"] {
            let outcome = try await client.writeInput(snapshot: snapshot, requestID: requestID, bytes: bytes(text))
            XCTAssertNil(outcome.transcriptReadbackIssue)
            XCTAssertEqual(outcome.bytesWritten, 1)
            snapshot = outcome.snapshot
        }
        XCTAssertEqual(snapshot.transcriptEvents.map(\.sequence), [1, 2, 3, 4])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.command), [.writeInput, .pollTranscript, .writeInput, .pollTranscript])
        XCTAssertEqual(Set(requests.map(\.commandID)).count, 4)
        let inputs = try requests.filter { $0.command == .writeInput }.map {
            try MacScope.Phase2ShellBrokerWireCodec.decodeWriteInputRequest($0.payload).bytes
        }
        XCTAssertEqual(inputs, [bytes("e"), bytes("c")])
    }

    func testResizeAndSignalReadInterleavedOutputInOrder() async throws {
        for command in [MacScope.Phase2ShellBrokerCommandKind.resizeTerminal, .sendSignal] {
            let sessionID = clientUUID(902)
            let requestID = clientUUID(903)
            let transport = InterleavedEchoTransport(sessionID: sessionID, requestID: requestID)
            let client = Phase2HumanPTYShellSessionClient(transport: transport)
            let snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)
            let outcome: Phase2HumanPTYShellSessionCommandOutcome
            if command == .resizeTerminal {
                outcome = try await client.resize(snapshot: snapshot, requestID: requestID,
                    size: .init(columns: 100, rows: 30))
            } else {
                outcome = try await client.sendSignal(snapshot: snapshot, requestID: requestID, signal: .interrupt)
            }
            XCTAssertNil(outcome.transcriptReadbackIssue)
            XCTAssertEqual(outcome.snapshot.transcriptEvents.map(\.sequence), [1, 2])
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.map(\.command), [command, .pollTranscript])
        }
    }

    func testCleanupAbsenceProofSurvivesInterleavedTranscriptReadbackFailure() async throws {
        let sessionID = clientUUID(906)
        let requestID = clientUUID(907)
        let transport = InterleavedEchoTransport(sessionID: sessionID, requestID: requestID, failReadback: true)
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let outcome = try await client.cleanup(snapshot: runningSnapshot(sessionID: sessionID, requestID: requestID),
            requestID: requestID)
        XCTAssertEqual(outcome.brokerResponse?.observedProcessAbsent, true)
        XCTAssertEqual(outcome.snapshot.state, .terminal(outcome: .canceled))
        XCTAssertNotNil(outcome.transcriptReadbackIssue)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.command), [.cleanupProcess, .pollTranscript])
    }

    func testSuccessfulWriteReceiptSurvivesReadbackFailureWithoutRetry() async throws {
        let sessionID = clientUUID(904)
        let requestID = clientUUID(905)
        let transport = InterleavedEchoTransport(sessionID: sessionID, requestID: requestID, failReadback: true)
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)
        let outcome = try await client.writeInput(snapshot: snapshot, requestID: requestID, bytes: bytes("x"))
        XCTAssertEqual(outcome.brokerResponse?.status, .accepted)
        XCTAssertEqual(outcome.bytesWritten, 1)
        XCTAssertEqual(outcome.snapshot, snapshot)
        XCTAssertNotNil(outcome.transcriptReadbackIssue)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.command), [.writeInput, .pollTranscript])
    }

    func testRealBrokerEmptyThenOutputAndAdvancingCursorKeepInputAndCleanupAvailable() async throws {
        let principal = Phase2ShellBrokerPrincipal(maximumSeenCommandIDs: 4)
        defer { principal.invalidate() }
        let transport = DirectPollingBrokerTransport(principal: principal)
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let sessionID = UUID()
        let requestID = UUID()
        // Keep the owned shell waiting in a builtin: an unrelated sleep child can race
        // group termination and reaping. Descendant cleanup has its own adapter test.
        let plan = Phase2HumanPTYLaunchPlan(sessionID: sessionID, requestID: requestID,
            executablePath: "/bin/sh",
            arguments: ["-c", "IFS= read -r line; printf 'reply:%s\\n' $line; IFS= read -r line; printf 'reply:%s\\n' $line; IFS= read -r line"],
            environment: [:], workingDirectoryPath: "/tmp", initialSize: .defaultInteractive)
        var snapshot = try await client.launch(snapshot: .initial(sessionID: sessionID), plan: plan).snapshot
        // More than both the injected permanent budget and bounded response-cache capacity.
        for _ in 0..<70 {
            let empty = try await client.pollTranscript(snapshot: snapshot, requestID: requestID,
                timeoutMilliseconds: 0)
            XCTAssertTrue(empty.acceptedTranscriptEvents.isEmpty)
            snapshot = empty.snapshot
        }
        let inputID = UUID()
        let input = try await client.writeInput(snapshot: snapshot, requestID: requestID,
            bytes: Array("first-marker\n".utf8), commandID: inputID)
        snapshot = input.snapshot
        let recordedInput = await transport.lastRequest()
        let rawInput = try XCTUnwrap(recordedInput)
        let replay = try await transport.perform(rawInput)
        XCTAssertEqual(replay, input.brokerResponse)
        var sawFirst = false
        for _ in 0..<60 where !sawFirst {
            let output = try await client.pollTranscript(snapshot: snapshot, requestID: requestID)
            snapshot = output.snapshot
            sawFirst = snapshot.transcriptEvents.contains { event in
                guard case .output(_, let bytes) = event.payload else { return false }
                return String(decoding: bytes, as: UTF8.self).contains("reply:first-marker")
            }
        }
        XCTAssertTrue(sawFirst)
        let advanced = try await client.pollTranscript(snapshot: snapshot, requestID: requestID,
            timeoutMilliseconds: 0)
        XCTAssertTrue(advanced.acceptedTranscriptEvents.isEmpty)
        snapshot = try await client.writeInput(snapshot: advanced.snapshot, requestID: requestID,
            bytes: Array("second-marker\n".utf8)).snapshot
        XCTAssertEqual(snapshot.transcriptEvents.filter {
            if case .input = $0.payload { return true }; return false
        }.count, 2, "Replayed input must not add a second input event")
        let cleanup = try await client.cleanup(snapshot: snapshot, requestID: requestID)
        XCTAssertEqual(cleanup.brokerResponse?.observedProcessAbsent, true)
    }

    func testLaunchEncodesBrokerRequestAndReducesPreparedRunningState() async throws {
        let sessionID = clientUUID(1)
        let requestID = clientUUID(2)
        let commandID = clientUUID(3)
        let plan = launchPlan(sessionID: sessionID, requestID: requestID)
        let transport = FakeShellBrokerTransport()
        await transport.enqueue(.accepted(
            commandID: commandID,
            command: .launchProcess,
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: 44
        ))
        let client = Phase2HumanPTYShellSessionClient(transport: transport)

        let outcome = try await client.launch(
            snapshot: .initial(sessionID: sessionID),
            plan: plan,
            commandID: commandID
        )

        XCTAssertEqual(outcome.snapshot.state, .running(requestID: requestID, processIdentifier: 44))
        XCTAssertEqual(outcome.snapshot.launchPlan, plan)
        XCTAssertEqual(outcome.snapshot.issues, [])
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.commandID, commandID)
        XCTAssertEqual(request.command, .launchProcess)
        let payload = try MacScope.Phase2ShellBrokerWireCodec.decodeLaunchProcessRequest(request.payload)
        XCTAssertEqual(payload.sessionID, sessionID)
        XCTAssertEqual(payload.requestID, requestID)
        XCTAssertEqual(payload.executablePath, "/bin/zsh")
        XCTAssertEqual(payload.arguments, ["-l"])
        XCTAssertEqual(payload.environment["TERM"], "xterm-256color")
        XCTAssertEqual(payload.workingDirectoryPath, "/tmp")
        XCTAssertEqual(payload.columns, Phase2HumanPTYTerminalSize.defaultInteractive.columns)
        XCTAssertEqual(payload.rows, Phase2HumanPTYTerminalSize.defaultInteractive.rows)
    }

    func testWriteResizeSignalAndPollReduceReturnedTranscriptEventsInOrder() async throws {
        let sessionID = clientUUID(10)
        let requestID = clientUUID(11)
        let transport = FakeShellBrokerTransport()
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        var snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)

        await transport.enqueue(.accepted(
            commandID: clientUUID(12),
            command: .writeInput,
            sessionID: sessionID,
            requestID: requestID,
            bytesWritten: 6,
            transcriptEvents: [
                wireEvent(sessionID: sessionID, sequence: 1, source: .human, payload: .input(bytes("hello\n"))),
            ],
            nextTranscriptSequence: 2
        ))
        var outcome = try await client.writeInput(
            snapshot: snapshot,
            requestID: requestID,
            bytes: bytes("hello\n"),
            commandID: clientUUID(12)
        )
        snapshot = outcome.snapshot

        XCTAssertEqual(outcome.bytesWritten, 6)
        XCTAssertEqual(outcome.acceptedTranscriptEvents.map(\.sequence), [1])
        XCTAssertEqual(snapshot.transcriptEvents.count, 1)

        await transport.enqueue(.accepted(
            commandID: clientUUID(13),
            command: .resizeTerminal,
            sessionID: sessionID,
            requestID: requestID,
            transcriptEvents: [
                wireEvent(sessionID: sessionID, sequence: 2, source: .human, payload: .resize(columns: 132, rows: 43)),
            ],
            nextTranscriptSequence: 3
        ))
        outcome = try await client.resize(
            snapshot: snapshot,
            requestID: requestID,
            size: Phase2HumanPTYTerminalSize(columns: 132, rows: 43),
            commandID: clientUUID(13)
        )
        snapshot = outcome.snapshot
        XCTAssertEqual(outcome.acceptedTranscriptEvents.map(\.sequence), [2])

        await transport.enqueue(.accepted(
            commandID: clientUUID(14),
            command: .sendSignal,
            sessionID: sessionID,
            requestID: requestID,
            transcriptEvents: [
                wireEvent(sessionID: sessionID, sequence: 3, source: .human, payload: .signal(.interrupt)),
            ],
            nextTranscriptSequence: 4
        ))
        outcome = try await client.sendSignal(
            snapshot: snapshot,
            requestID: requestID,
            signal: .interrupt,
            commandID: clientUUID(14)
        )
        snapshot = outcome.snapshot
        XCTAssertEqual(outcome.acceptedTranscriptEvents.map(\.sequence), [3])

        await transport.enqueue(.accepted(
            commandID: clientUUID(15),
            command: .pollTranscript,
            sessionID: sessionID,
            requestID: requestID,
            transcriptEvents: [
                wireEvent(
                    sessionID: sessionID,
                    sequence: 4,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: bytes("world\n"))
                ),
            ],
            nextTranscriptSequence: 5
        ))
        outcome = try await client.pollTranscript(
            snapshot: snapshot,
            requestID: requestID,
            maximumEvents: 4,
            maximumBytes: 128,
            timeoutMilliseconds: 10,
            commandID: clientUUID(15)
        )
        snapshot = outcome.snapshot

        XCTAssertEqual(snapshot.transcriptEvents.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(snapshot.issues, [])
        let requests = await transport.recordedRequests()
        let pollRequest = try XCTUnwrap(requests.last)
        let pollPayload = try MacScope.Phase2ShellBrokerWireCodec.decodePollTranscriptRequest(pollRequest.payload)
        XCTAssertEqual(pollPayload.afterSequence, 3)
        XCTAssertEqual(pollPayload.maximumEvents, 4)
        XCTAssertEqual(pollPayload.maximumBytes, 128)
        XCTAssertEqual(pollPayload.timeoutMilliseconds, 10)
    }

    func testClientRejectsLocalInvalidStateBeforeDispatchingBrokerCommand() async throws {
        let sessionID = clientUUID(20)
        let requestID = clientUUID(21)
        let transport = FakeShellBrokerTransport()
        let client = Phase2HumanPTYShellSessionClient(transport: transport)

        do {
            _ = try await client.writeInput(
                snapshot: .initial(sessionID: sessionID),
                requestID: requestID,
                bytes: bytes("not running\n"),
                commandID: clientUUID(22)
            )
            XCTFail("Expected local rejection")
        } catch let error as Phase2HumanPTYShellSessionClientError {
            XCTAssertEqual(error, .commandRejectedLocally([
                .commandNotAllowedInState(command: .writeInput, state: .idle),
            ]))
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests, [])
    }

    func testClientRejectsMismatchedRequestGenerationBeforeDispatch() async throws {
        let sessionID = clientUUID(23)
        let expectedRequestID = clientUUID(24)
        let staleRequestID = clientUUID(25)
        let transport = FakeShellBrokerTransport()
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let snapshot = runningSnapshot(sessionID: sessionID, requestID: expectedRequestID)

        await assertRequestMismatch(
            command: .writeInput,
            expected: expectedRequestID,
            actual: staleRequestID
        ) {
            _ = try await client.writeInput(
                snapshot: snapshot,
                requestID: staleRequestID,
                bytes: bytes("blocked\n")
            )
        }
        await assertRequestMismatch(
            command: .resizeTerminal,
            expected: expectedRequestID,
            actual: staleRequestID
        ) {
            _ = try await client.resize(
                snapshot: snapshot,
                requestID: staleRequestID,
                size: .init(columns: 100, rows: 30)
            )
        }
        await assertRequestMismatch(
            command: .sendSignal,
            expected: expectedRequestID,
            actual: staleRequestID
        ) {
            _ = try await client.sendSignal(
                snapshot: snapshot,
                requestID: staleRequestID,
                signal: .interrupt
            )
        }
        await assertRequestMismatch(
            command: .pollTranscript,
            expected: expectedRequestID,
            actual: staleRequestID
        ) {
            _ = try await client.pollTranscript(
                snapshot: snapshot,
                requestID: staleRequestID
            )
        }
        await assertRequestMismatch(
            command: .reconnectSession,
            expected: expectedRequestID,
            actual: staleRequestID
        ) {
            _ = try await client.reconnect(
                snapshot: snapshot,
                requestID: staleRequestID,
                reconnectID: clientUUID(26)
            )
        }
        await assertRequestMismatch(
            command: .cleanupProcess,
            expected: expectedRequestID,
            actual: staleRequestID
        ) {
            _ = try await client.cleanup(
                snapshot: snapshot,
                requestID: staleRequestID
            )
        }

        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testPartialInputRequiresExplicitOptInAndValidPrefixCount() async throws {
        let sessionID = UUID(), requestID = UUID()
        let snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)
        for count in [-1, 3, 4] {
            let transport = FakeShellBrokerTransport()
            let commandID = UUID()
            await transport.enqueue(.init(commandID: commandID, command: .writeInput, status: .partial,
                sessionID: sessionID, requestID: requestID, bytesWritten: count))
            let client = Phase2HumanPTYShellSessionClient(transport: transport)
            await assertClientError(.writeByteCountMismatch(expected: 3, actual: count)) {
                _ = try await client.writeInput(snapshot: snapshot, requestID: requestID,
                    bytes: Array("abc".utf8), commandID: commandID, allowPartial: true)
            }
        }
        let transport = FakeShellBrokerTransport()
        let commandID = UUID()
        await transport.enqueue(.init(commandID: commandID, command: .writeInput, status: .partial,
            sessionID: sessionID, requestID: requestID, bytesWritten: 0))
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        await assertClientError(.brokerFailed(command: .writeInput, issues: ["partial input delivery"])) {
            _ = try await client.writeInput(snapshot: snapshot, requestID: requestID,
                bytes: Array("abc".utf8), commandID: commandID)
        }
    }

    func testWriteRequiresExactBrokerByteCount() async throws {
        let sessionID = clientUUID(27)
        let requestID = clientUUID(28)
        let payload = bytes("exact\n")
        let transport = FakeShellBrokerTransport()
        await transport.enqueue(.accepted(
            commandID: clientUUID(29),
            command: .writeInput,
            sessionID: sessionID,
            requestID: requestID,
            bytesWritten: nil
        ))
        await transport.enqueue(.accepted(
            commandID: clientUUID(30),
            command: .writeInput,
            sessionID: sessionID,
            requestID: requestID,
            bytesWritten: payload.count - 1
        ))
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)

        await assertClientError(.writeByteCountMismatch(expected: payload.count, actual: nil)) {
            _ = try await client.writeInput(
                snapshot: snapshot,
                requestID: requestID,
                bytes: payload,
                commandID: clientUUID(29)
            )
        }
        await assertClientError(
            .writeByteCountMismatch(expected: payload.count, actual: payload.count - 1)
        ) {
            _ = try await client.writeInput(
                snapshot: snapshot,
                requestID: requestID,
                bytes: payload,
                commandID: clientUUID(30)
            )
        }
    }

    func testClientFailsClosedOnBrokerRejectedResponse() async throws {
        let sessionID = clientUUID(30)
        let requestID = clientUUID(31)
        let commandID = clientUUID(32)
        let transport = FakeShellBrokerTransport()
        await transport.enqueue(.rejected(
            commandID: commandID,
            command: .pollTranscript,
            sessionID: sessionID,
            requestID: requestID,
            issues: ["noRunningLease"]
        ))
        let client = Phase2HumanPTYShellSessionClient(transport: transport)

        do {
            _ = try await client.pollTranscript(
                snapshot: runningSnapshot(sessionID: sessionID, requestID: requestID),
                requestID: requestID,
                commandID: commandID
            )
            XCTFail("Expected broker rejection")
        } catch let error as Phase2HumanPTYShellSessionClientError {
            XCTAssertEqual(error, .brokerRejected(command: .pollTranscript, issues: ["noRunningLease"]))
        }
    }

    func testClientRejectsReplyForDifferentOperationToken() async throws {
        let sessionID = clientUUID(34)
        let requestID = clientUUID(35)
        let commandID = clientUUID(36)
        let transport = FakeShellBrokerTransport()
        await transport.enqueue(.accepted(
            commandID: clientUUID(37),
            command: .pollTranscript,
            sessionID: sessionID,
            requestID: requestID
        ))
        let client = Phase2HumanPTYShellSessionClient(transport: transport)

        do {
            _ = try await client.pollTranscript(
                snapshot: runningSnapshot(sessionID: sessionID, requestID: requestID),
                requestID: requestID,
                commandID: commandID
            )
            XCTFail("Expected operation-token rejection")
        } catch let error as Phase2HumanPTYShellSessionClientError {
            XCTAssertEqual(error, .malformedBrokerResponse("command ID mismatch"))
        }
    }

    func testCleanupReducesBrokerTerminationWithoutTerminalUIAuthority() async throws {
        let sessionID = clientUUID(40)
        let requestID = clientUUID(41)
        let commandID = clientUUID(42)
        let transport = FakeShellBrokerTransport()
        await transport.enqueue(.accepted(
            commandID: commandID,
            command: .cleanupProcess,
            sessionID: sessionID,
            requestID: requestID,
            observedProcessAbsent: true,
            outcome: "canceled",
            transcriptEvents: [
                wireEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: bytes("final frame\n"))
                ),
            ],
            nextTranscriptSequence: 2
        ))
        let client = Phase2HumanPTYShellSessionClient(transport: transport)

        let outcome = try await client.cleanup(
            snapshot: runningSnapshot(sessionID: sessionID, requestID: requestID),
            requestID: requestID,
            commandID: commandID
        )

        XCTAssertEqual(outcome.snapshot.state, .terminal(outcome: .canceled))
        XCTAssertEqual(outcome.snapshot.transcriptEvents, [
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: 1,
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: bytes("final frame\n"))
            ),
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: 2,
                source: .broker,
                payload: .terminal(.canceled)
            ),
        ])
        XCTAssertEqual(outcome.acceptedTranscriptEvents.map(\.payload), [
            .output(stream: .standardOutput, bytes: bytes("final frame\n")),
        ])
        XCTAssertEqual(outcome.snapshot.issues, [])
    }

    func testCleanupRequiresProcessAbsenceAndStrictExitStatus() async throws {
        let sessionID = clientUUID(44)
        let requestID = clientUUID(45)
        let transport = FakeShellBrokerTransport()
        let client = Phase2HumanPTYShellSessionClient(transport: transport)
        let snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID)

        await transport.enqueue(.accepted(
            commandID: clientUUID(46),
            command: .cleanupProcess,
            sessionID: sessionID,
            requestID: requestID,
            observedProcessAbsent: false,
            outcome: "canceled"
        ))
        do {
            _ = try await client.cleanup(
                snapshot: snapshot,
                requestID: requestID,
                commandID: clientUUID(46)
            )
            XCTFail("Expected missing process-absence proof rejection")
        } catch let error as Phase2HumanPTYShellSessionClientError {
            XCTAssertEqual(error, .malformedBrokerResponse("cleanup lacked process-absence proof"))
        }

        await transport.enqueue(.accepted(
            commandID: clientUUID(47),
            command: .cleanupProcess,
            sessionID: sessionID,
            requestID: requestID,
            observedProcessAbsent: true,
            outcome: "exited:not-an-int32"
        ))
        do {
            _ = try await client.cleanup(
                snapshot: snapshot,
                requestID: requestID,
                commandID: clientUUID(47)
            )
            XCTFail("Expected malformed exit status rejection")
        } catch let error as Phase2HumanPTYShellSessionClientError {
            XCTAssertEqual(error, .malformedBrokerResponse("invalid cleanup exit status"))
        }
    }

    func testCleanupAcceptsMatchingTerminalReplyWithoutDuplicatingExitEvent() async throws {
        let sessionID = clientUUID(48)
        let requestID = clientUUID(49)
        let commandID = clientUUID(50)
        let transport = FakeShellBrokerTransport()
        await transport.enqueue(.accepted(
            commandID: commandID,
            command: .cleanupProcess,
            sessionID: sessionID,
            requestID: requestID,
            observedProcessAbsent: true,
            outcome: "exited:7",
            transcriptEvents: [
                wireEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .broker,
                    payload: .terminal(.exited(status: 7))
                ),
            ],
            nextTranscriptSequence: 2
        ))
        let client = Phase2HumanPTYShellSessionClient(transport: transport)

        let outcome = try await client.cleanup(
            snapshot: runningSnapshot(sessionID: sessionID, requestID: requestID),
            requestID: requestID,
            commandID: commandID
        )

        XCTAssertEqual(outcome.snapshot.state, .terminal(outcome: .exited(status: 7)))
        XCTAssertEqual(outcome.snapshot.transcriptEvents.map(\.payload), [
            .terminal(.exited(status: 7)),
        ])
        XCTAssertEqual(outcome.acceptedTranscriptEvents.map(\.payload), [
            .terminal(.exited(status: 7)),
        ])
        XCTAssertEqual(outcome.snapshot.issues, [])
    }

    func testReconnectReducesBrokerTerminalEvidenceWhenSessionExitedBeforeResync() async throws {
        let sessionID = clientUUID(50)
        let requestID = clientUUID(51)
        let reconnectID = clientUUID(52)
        let commandID = clientUUID(53)
        let transport = FakeShellBrokerTransport()
        await transport.enqueue(.accepted(
            commandID: commandID,
            command: .reconnectSession,
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: 77,
            transcriptEvents: [
                wireEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .broker,
                    payload: .terminal(.exited(status: 7))
                ),
            ],
            nextTranscriptSequence: 2
        ))
        let client = Phase2HumanPTYShellSessionClient(transport: transport)

        let outcome = try await client.reconnect(
            snapshot: runningSnapshot(sessionID: sessionID, requestID: requestID),
            requestID: requestID,
            reconnectID: reconnectID,
            maximumEvents: 6,
            maximumBytes: 512,
            commandID: commandID
        )

        XCTAssertEqual(outcome.snapshot.state, .terminal(outcome: .exited(status: 7)))
        XCTAssertEqual(outcome.snapshot.transcriptEvents.map(\.payload), [
            .terminal(.exited(status: 7)),
        ])
        XCTAssertEqual(outcome.acceptedTranscriptEvents.map(\.payload), [
            .terminal(.exited(status: 7)),
        ])
        XCTAssertEqual(outcome.snapshot.issues, [])

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.command, .reconnectSession)
        let payload = try MacScope.Phase2ShellBrokerWireCodec.decodeReconnectSessionRequest(request.payload)
        XCTAssertEqual(payload.reconnectID, reconnectID)
        XCTAssertEqual(payload.maximumEvents, 6)
        XCTAssertEqual(payload.maximumBytes, 512)
    }

    private func assertRequestMismatch(
        command: MacScope.Phase2ShellBrokerCommandKind,
        expected: UUID,
        actual: UUID,
        operation: () async throws -> Void
    ) async {
        await assertClientError(
            .requestMismatch(command: command, expected: expected, actual: actual),
            operation: operation
        )
    }

    private func assertClientError(
        _ expected: Phase2HumanPTYShellSessionClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected local client rejection")
        } catch let error as Phase2HumanPTYShellSessionClientError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor FakeShellBrokerTransport: MacScope.ShellBrokerXPCTransport {
    private var requests: [MacScope.Phase2ShellBrokerCommandRequest] = []
    private var responses: [MacScope.Phase2ShellBrokerCommandResponse] = []

    func enqueue(_ response: MacScope.Phase2ShellBrokerCommandResponse) {
        responses.append(response)
    }

    func recordedRequests() -> [MacScope.Phase2ShellBrokerCommandRequest] {
        requests
    }

    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake {
        .boundaryReady
    }

    func perform(
        _ request: MacScope.Phase2ShellBrokerCommandRequest
    ) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return MacScope.Phase2ShellBrokerCommandResponse(
                commandID: request.commandID,
                command: request.command,
                status: .failed,
                issues: ["missingFakeResponse"]
            )
        }
        return responses.removeFirst()
    }

    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        MacScope.ShellBrokerXPCProcessReceipt(
            processIdentifier: 99,
            connectionIdentity: clientUUID(900),
            wireProtocol: MacScope.Phase2ShellBrokerProtocolIdentity.wireProtocol,
            supportedCommands: MacScope.Phase2ShellBrokerCommandKind.allCases
        )
    }

    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool {
        receipt.processIdentifier == 99
    }

    func reset() async {}
}

private extension MacScope.Phase2ShellBrokerCommandResponse {
    static func accepted(
        commandID: UUID,
        command: MacScope.Phase2ShellBrokerCommandKind,
        sessionID: UUID,
        requestID: UUID,
        processIdentifier: Int32? = nil,
        observedProcessAbsent: Bool? = nil,
        outcome: String? = nil,
        bytesWritten: Int? = nil,
        transcriptEvents: [MacScope.Phase2ShellBrokerTranscriptEventWire] = [],
        nextTranscriptSequence: UInt64? = nil
    ) -> Self {
        Self(
            commandID: commandID,
            command: command,
            status: .accepted,
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: processIdentifier,
            observedProcessAbsent: observedProcessAbsent,
            outcome: outcome,
            bytesWritten: bytesWritten,
            transcriptEvents: transcriptEvents,
            nextTranscriptSequence: nextTranscriptSequence
        )
    }

    static func rejected(
        commandID: UUID,
        command: MacScope.Phase2ShellBrokerCommandKind,
        sessionID: UUID,
        requestID: UUID,
        issues: [String]
    ) -> Self {
        Self(
            commandID: commandID,
            command: command,
            status: .rejected,
            sessionID: sessionID,
            requestID: requestID,
            issues: issues
        )
    }
}

private func launchPlan(
    sessionID: UUID,
    requestID: UUID
) -> Phase2HumanPTYLaunchPlan {
    Phase2HumanPTYLaunchPlan(
        sessionID: sessionID,
        requestID: requestID,
        executablePath: "/bin/zsh",
        arguments: ["-l"],
        environment: ["TERM": "xterm-256color"],
        workingDirectoryPath: "/tmp",
        initialSize: .defaultInteractive
    )
}

private func runningSnapshot(
    sessionID: UUID,
    requestID: UUID
) -> Phase2HumanPTYSessionSnapshot {
    var snapshot = Phase2HumanPTYSessionSnapshot.initial(sessionID: sessionID)
    let plan = launchPlan(sessionID: sessionID, requestID: requestID)
    snapshot = Phase2HumanPTYSessionReducer.reduce(
        snapshot,
        command: Phase2HumanPTYBrokerCommand(
            commandID: clientUUID(700),
            sessionID: sessionID,
            authority: .human,
            payload: .launch(plan)
        )
    )
    snapshot = Phase2HumanPTYSessionReducer.reduce(
        snapshot,
        event: Phase2HumanPTYBrokerEvent(
            sessionID: sessionID,
            eventID: clientUUID(701),
            payload: .prepared(requestID: requestID)
        )
    )
    snapshot = Phase2HumanPTYSessionReducer.reduce(
        snapshot,
        event: Phase2HumanPTYBrokerEvent(
            sessionID: sessionID,
            eventID: clientUUID(702),
            payload: .running(processIdentifier: 77)
        )
    )
    return snapshot
}

private func wireEvent(
    sessionID: UUID,
    sequence: UInt64,
    source: Phase2HumanPTYEventSource,
    payload: Phase2HumanPTYEventPayload
) -> MacScope.Phase2ShellBrokerTranscriptEventWire {
    MacScope.Phase2ShellBrokerTranscriptEventWire(event: Phase2HumanPTYTranscriptEvent(
        sessionID: sessionID,
        sequence: sequence,
        source: source,
        payload: payload
    ))
}

private func bytes(_ value: String) -> [UInt8] {
    Array(value.utf8)
}

private func clientUUID(_ value: UInt32) -> UUID {
    UUID(uuid: (
        0x25, 0x0C, 0x00, 0x00,
        0x00, 0x00,
        0x40, 0x00,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x00,
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ))
}

private actor DirectPollingBrokerTransport: MacScope.ShellBrokerXPCTransport {
    let principal: Phase2ShellBrokerPrincipal
    private var last: MacScope.Phase2ShellBrokerCommandRequest?
    init(principal: Phase2ShellBrokerPrincipal) { self.principal = principal }
    func lastRequest() -> MacScope.Phase2ShellBrokerCommandRequest? { last }
    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake { .boundaryReady }
    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        last = request
        let bytes = try MacScope.Phase2ShellBrokerWireCodec.encodeCommandRequest(request)
        let response: Data = await withCheckedContinuation { continuation in
            principal.performCommand(bytes) { continuation.resume(returning: $0) }
        }
        return try MacScope.Phase2ShellBrokerWireCodec.decodeCommandResponse(response)
    }
    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        throw ShellBrokerXPCTransportError.unavailable("Not used by direct polling regression")
    }
    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool { false }
    func reset() async { principal.invalidate() }
}

private actor InterleavedEchoTransport: MacScope.ShellBrokerXPCTransport {
    let sessionID: UUID
    let requestID: UUID
    let failReadback: Bool
    private var requests: [MacScope.Phase2ShellBrokerCommandRequest] = []
    private var events: [MacScope.Phase2ShellBrokerTranscriptEventWire] = []
    init(sessionID: UUID, requestID: UUID, failReadback: Bool = false) {
        self.sessionID = sessionID; self.requestID = requestID; self.failReadback = failReadback
    }
    func recordedRequests() -> [MacScope.Phase2ShellBrokerCommandRequest] { requests }
    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake { .boundaryReady }
    func perform(_ request: MacScope.Phase2ShellBrokerCommandRequest) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        requests.append(request)
        if request.command == .pollTranscript {
            if failReadback { throw ShellBrokerXPCTransportError.unavailable("Readback unavailable") }
            let poll = try MacScope.Phase2ShellBrokerWireCodec.decodePollTranscriptRequest(request.payload)
            return .init(commandID: request.commandID, command: request.command, status: .accepted,
                sessionID: sessionID, requestID: requestID,
                transcriptEvents: events.filter { $0.sequence > poll.afterSequence },
                nextTranscriptSequence: UInt64(events.count + 1))
        }
        // Models the independent durable PTY drain appending an echo before this mutation.
        events.append(wireEvent(sessionID: sessionID, sequence: UInt64(events.count + 1),
            source: .broker, payload: .output(stream: .standardOutput, bytes: [65])))
        let payload: Phase2HumanPTYEventPayload
        var count: Int?
        switch request.command {
        case .writeInput:
            let input = try MacScope.Phase2ShellBrokerWireCodec.decodeWriteInputRequest(request.payload)
            payload = .input(input.bytes); count = input.bytes.count
        case .resizeTerminal:
            let size = try MacScope.Phase2ShellBrokerWireCodec.decodeResizeTerminalRequest(request.payload)
            payload = .resize(columns: size.columns, rows: size.rows)
        case .sendSignal:
            let signal = try MacScope.Phase2ShellBrokerWireCodec.decodeSendSignalRequest(request.payload)
            payload = .signal(signal.signal)
        case .cleanupProcess:
            payload = .terminal(.canceled)
        default:
            throw ShellBrokerXPCTransportError.unavailable("Unexpected mutation")
        }
        let event = wireEvent(sessionID: sessionID, sequence: UInt64(events.count + 1), source: request.command == .cleanupProcess ? .broker : .human, payload: payload)
        events.append(event)
        return .init(commandID: request.commandID, command: request.command, status: .accepted,
            sessionID: sessionID, requestID: requestID,
            observedProcessAbsent: request.command == .cleanupProcess ? true : nil,
            outcome: request.command == .cleanupProcess ? "canceled" : nil, bytesWritten: count,
            transcriptEvents: [event], nextTranscriptSequence: event.sequence + 1)
    }
    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        throw ShellBrokerXPCTransportError.unavailable("Not used")
    }
    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool { false }
    func reset() async {}
}
