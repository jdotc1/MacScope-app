import Foundation
import Darwin
import ServiceManagement
import XCTest

@testable import MacScope

final class Phase2ShellBrokerXPCBoundaryTests: XCTestCase {
    func testHandshakeIsBoundaryReadyAndAdvertisesShellBrokerCommands() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let data = try awaitHandshake(from: principal)
        let handshake = try Phase2ShellBrokerWireCodec.decodeHandshake(data)

        XCTAssertEqual(handshake.schemaVersion, 4)
        XCTAssertEqual(handshake.serviceIdentifier, "terminal.human_pty.shell_broker")
        XCTAssertEqual(handshake.wireProtocol, "macscope.phase2.shell_broker.xpc.v4")
        XCTAssertEqual(handshake.status, .boundaryReady)
        XCTAssertEqual(handshake.supportedCommands, Phase2ShellBrokerCommandKind.allCases.map(\.rawValue))
        XCTAssertEqual(handshake.maximumMessageBytes, 64 * 1024)
    }

    func testInvalidatedPrincipalReturnsNoHandshake() throws {
        let principal = Phase2ShellBrokerPrincipal()
        principal.invalidate()

        let data = try awaitHandshake(from: principal)

        XCTAssertTrue(data.isEmpty)
    }

    func testInvalidatedPrincipalReturnsNoCommandResponse() throws {
        let principal = Phase2ShellBrokerPrincipal()
        principal.invalidate()

        let commandID = UUID()
        let sessionID = UUID()
        let requestID = UUID()
        let responseData = try awaitCommandResponseData(
            from: principal,
            request: launchCommand(commandID: commandID, sessionID: sessionID, requestID: requestID)
        )

        XCTAssertTrue(responseData.isEmpty)
    }

    func testMalformedCommandEnvelopeFailsClosedWithoutSideEffects() throws {
        let principal = Phase2ShellBrokerPrincipal()

        let responseData = try awaitCommandResponseData(from: principal, data: Data("not-json".utf8))
        let response = try Phase2ShellBrokerWireCodec.decodeCommandResponse(responseData)

        XCTAssertEqual(response.status, .invalid)
        XCTAssertNil(response.commandID)
        XCTAssertTrue(response.issues.first?.contains("invalidCommandEnvelope") == true)
    }

    func testCleanupBeforeLaunchIsRejected() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let commandID = UUID()
        let sessionID = UUID()
        let requestID = UUID()

        let response = try awaitCommandResponse(
            from: principal,
            request: cleanupCommand(commandID: commandID, sessionID: sessionID, requestID: requestID)
        )

        XCTAssertEqual(response.commandID, commandID)
        XCTAssertEqual(response.command, .cleanupProcess)
        XCTAssertEqual(response.status, .rejected)
        XCTAssertEqual(response.sessionID, sessionID)
        XCTAssertEqual(response.requestID, requestID)
        XCTAssertTrue(response.issues.contains("noRunningLease"))
    }

    func testInvalidLaunchRequestIsRejectedBeforeProcessSpawn() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let commandID = UUID()
        let sessionID = UUID()
        let requestID = UUID()
        let launchRequest = Phase2ShellBrokerLaunchProcessRequest(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "relative",
            columns: 0
        )

        let response = try awaitCommandResponse(
            from: principal,
            request: launchCommand(commandID: commandID, launchRequest: launchRequest)
        )

        XCTAssertEqual(response.commandID, commandID)
        XCTAssertEqual(response.command, .launchProcess)
        XCTAssertEqual(response.status, .rejected)
        XCTAssertEqual(response.sessionID, sessionID)
        XCTAssertEqual(response.requestID, requestID)
        XCTAssertNil(response.processIdentifier)
        XCTAssertTrue(response.issues.contains { $0.contains("invalidLaunchPlan") })
        XCTAssertTrue(response.issues.contains { $0.contains("executablePathNotAbsolute") })
        XCTAssertTrue(response.issues.contains { $0.contains("invalidInitialTerminalSize") })
    }

    func testLaunchAndCleanupCommandSurfaceOwnsAndRemovesExactProcess() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let launchCommandID = UUID()
        let cleanupCommandID = UUID()
        let sessionID = UUID()
        let requestID = UUID()

        let launchResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(commandID: launchCommandID, sessionID: sessionID, requestID: requestID)
        )
        var launchedProcessIdentifier = launchResponse.processIdentifier
        defer {
            if let launchedProcessIdentifier, processExists(launchedProcessIdentifier) {
                if let cleanup = try? cleanupCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID) {
                    _ = try? awaitCommandResponse(from: principal, request: cleanup)
                }
            }
        }

        XCTAssertEqual(launchResponse.commandID, launchCommandID)
        XCTAssertEqual(launchResponse.command, .launchProcess)
        XCTAssertEqual(launchResponse.status, .accepted)
        XCTAssertEqual(launchResponse.sessionID, sessionID)
        XCTAssertEqual(launchResponse.requestID, requestID)
        let processIdentifier = try XCTUnwrap(launchResponse.processIdentifier)
        XCTAssertGreaterThan(processIdentifier, 0)
        XCTAssertEqual(launchResponse.executablePath, "/bin/sleep")
        XCTAssertTrue(processExists(processIdentifier))

        let cleanupResponse = try awaitCommandResponse(
            from: principal,
            request: cleanupCommand(commandID: cleanupCommandID, sessionID: sessionID, requestID: requestID)
        )
        launchedProcessIdentifier = nil

        XCTAssertEqual(cleanupResponse.commandID, cleanupCommandID)
        XCTAssertEqual(cleanupResponse.command, .cleanupProcess)
        XCTAssertEqual(cleanupResponse.status, .accepted)
        XCTAssertEqual(cleanupResponse.sessionID, sessionID)
        XCTAssertEqual(cleanupResponse.requestID, requestID)
        XCTAssertEqual(cleanupResponse.processIdentifier, processIdentifier)
        XCTAssertEqual(cleanupResponse.observedProcessAbsent, true)
        XCTAssertEqual(cleanupResponse.outcome, "canceled")
        XCTAssertFalse(processExists(processIdentifier))
    }

    func testDirectPrincipalForwardsInputAndPollsTranscriptInOrder() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()
        let marker = "macscope-direct-xpc-input"

        let launchResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(
                commandID: UUID(),
                launchRequest: Phase2ShellBrokerLaunchProcessRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/sh",
                    arguments: ["-c", "IFS= read -r line; printf 'reply:%s\\n' \"$line\"; sleep 30"]
                )
            )
        )
        defer {
            if let cleanup = try? cleanupCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID) {
                _ = try? awaitCommandResponse(from: principal, request: cleanup)
            }
        }
        XCTAssertEqual(launchResponse.status, .accepted)

        let writeResponse = try awaitCommandResponse(
            from: principal,
            request: writeInputCommand(
                commandID: UUID(),
                sessionID: sessionID,
                requestID: requestID,
                bytes: Array("\(marker)\n".utf8)
            )
        )
        XCTAssertEqual(writeResponse.status, .accepted)
        XCTAssertEqual(writeResponse.command, .writeInput)
        XCTAssertEqual(writeResponse.bytesWritten, marker.utf8.count + 1)
        let inputEvent = try XCTUnwrap(writeResponse.transcriptEvents.first?.makeEvent())
        XCTAssertEqual(inputEvent.sequence, 1)
        XCTAssertEqual(inputEvent.source, .human)
        XCTAssertEqual(inputEvent.payload, .input(Array("\(marker)\n".utf8)))

        let events = try waitForTranscriptEvents(
            from: principal,
            sessionID: sessionID,
            requestID: requestID,
            containing: "reply:\(marker)"
        )

        XCTAssertTrue(events.contains { $0.sequence == 1 && $0.source == .human })
        XCTAssertTrue(events.contains { event in
            guard case .output(_, let bytes) = event.payload else { return false }
            return String(decoding: bytes, as: UTF8.self).contains("reply:\(marker)")
        })
        XCTAssertEqual(events.map(\.sequence), Array(1...UInt64(events.count)))
    }

    func testDirectPrincipalPollObservesNaturalExitAfterFinalOutput() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()

        let launchResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(
                commandID: UUID(),
                launchRequest: Phase2ShellBrokerLaunchProcessRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/sh",
                    arguments: ["-c", "printf macscope-natural-exit; exit 7"]
                )
            )
        )
        XCTAssertEqual(launchResponse.status, .accepted)

        let events = try waitForTerminalTranscriptEvents(
            from: principal,
            sessionID: sessionID,
            requestID: requestID
        )

        XCTAssertTrue(events.contains { event in
            guard case .output(_, let bytes) = event.payload else { return false }
            return String(decoding: bytes, as: UTF8.self).contains("macscope-natural-exit")
        })
        XCTAssertEqual(events.last?.payload, .terminal(.exited(status: 7)))
        XCTAssertEqual(events.filter { event in
            if case .terminal = event.payload {
                return true
            }
            return false
        }.count, 1)
        XCTAssertEqual(events.map(\.sequence), Array(1...UInt64(events.count)))

        let secondPoll = try awaitCommandResponse(
            from: principal,
            request: pollCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
        )
        XCTAssertEqual(secondPoll.status, .rejected)
        XCTAssertTrue(secondPoll.issues.contains("noRunningLease"))
    }

    func testDirectPrincipalReconnectObservesNaturalExitInsteadOfStaleRunningRejection() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()
        let reconnectID = UUID()

        let launchResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(
                commandID: UUID(),
                launchRequest: Phase2ShellBrokerLaunchProcessRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/sh",
                    arguments: ["-c", "exit 7"]
                )
            )
        )
        XCTAssertEqual(launchResponse.status, .accepted)

        Thread.sleep(forTimeInterval: 0.2)

        let reconnectResponse = try awaitCommandResponse(
            from: principal,
            request: reconnectCommand(
                commandID: UUID(),
                sessionID: sessionID,
                requestID: requestID,
                reconnectID: reconnectID
            )
        )
        let events = reconnectResponse.transcriptEvents.compactMap { $0.makeEvent() }

        XCTAssertEqual(reconnectResponse.status, .accepted)
        XCTAssertEqual(reconnectResponse.command, .reconnectSession)
        XCTAssertEqual(reconnectResponse.sessionID, sessionID)
        XCTAssertEqual(reconnectResponse.requestID, requestID)
        XCTAssertEqual(events.map(\.payload), [.terminal(.exited(status: 7))])
        XCTAssertFalse(events.contains { event in
            if case .reconnect = event.payload {
                return true
            }
            return false
        })

        let secondReconnect = try awaitCommandResponse(
            from: principal,
            request: reconnectCommand(
                commandID: UUID(),
                sessionID: sessionID,
                requestID: requestID,
                reconnectID: UUID()
            )
        )
        XCTAssertEqual(secondReconnect.status, .rejected)
        XCTAssertTrue(secondReconnect.issues.contains("noRunningLease"))
    }

    func testDirectPrincipalCompactsOversizedTranscriptOutputIntoBrokerGapEvidence() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()
        let oversizedOutput = "macscope-spool-gap-output"

        let launchResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(
                commandID: UUID(),
                launchRequest: Phase2ShellBrokerLaunchProcessRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/sh",
                    arguments: ["-c", "printf '\(oversizedOutput)'; sleep 30"],
                    maximumTranscriptEvents: 4,
                    maximumTranscriptEventBytes: 128,
                    maximumTranscriptCumulativeBytes: 8
                )
            )
        )
        defer {
            if let cleanup = try? cleanupCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID) {
                _ = try? awaitCommandResponse(from: principal, request: cleanup)
            }
        }
        XCTAssertEqual(launchResponse.status, .accepted)

        let deadline = Date().addingTimeInterval(3)
        var gapEvent: Phase2HumanPTYTranscriptEvent?
        while Date() < deadline {
            let response = try awaitCommandResponse(
                from: principal,
                request: pollCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
            )
            let events = response.transcriptEvents.compactMap { $0.makeEvent() }
            gapEvent = events.first { event in
                if case .gap(reason: .spoolLimitExceeded, lostByteCount: _) = event.payload {
                    return event.source == .broker
                }
                return false
            }
            if gapEvent != nil {
                XCTAssertFalse(events.contains { event in
                    if case .output = event.payload {
                        return true
                    }
                    return false
                })
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let event = try XCTUnwrap(gapEvent)
        XCTAssertEqual(event.sequence, 1)
        XCTAssertEqual(event.source, .broker)
        if case .gap(let reason, let lostByteCount) = event.payload {
            XCTAssertEqual(reason, .spoolLimitExceeded)
            XCTAssertGreaterThanOrEqual(lostByteCount, oversizedOutput.utf8.count)
        } else {
            XCTFail("Expected broker gap evidence.")
        }
    }

    func testDirectPrincipalRejectsForwardingCommandsBeforeLaunch() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()

        let responses = try [
            awaitCommandResponse(
                from: principal,
                request: writeInputCommand(
                    commandID: UUID(),
                    sessionID: sessionID,
                    requestID: requestID,
                    bytes: Array("input\n".utf8)
                )
            ),
            awaitCommandResponse(
                from: principal,
                request: resizeCommand(
                    commandID: UUID(),
                    sessionID: sessionID,
                    requestID: requestID,
                    columns: 120,
                    rows: 40
                )
            ),
            awaitCommandResponse(
                from: principal,
                request: signalCommand(
                    commandID: UUID(),
                    sessionID: sessionID,
                    requestID: requestID,
                    signal: .interrupt
                )
            ),
            awaitCommandResponse(
                from: principal,
                request: pollCommand(
                    commandID: UUID(),
                    sessionID: sessionID,
                    requestID: requestID
                )
            ),
            awaitCommandResponse(
                from: principal,
                request: reconnectCommand(
                    commandID: UUID(),
                    sessionID: sessionID,
                    requestID: requestID,
                    reconnectID: UUID()
                )
            )
        ]

        for response in responses {
            XCTAssertEqual(response.status, .rejected)
            XCTAssertTrue(response.issues.contains("noRunningLease"))
        }
    }

    func testDirectPrincipalForwardsResizeAndSignalEvents() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()

        let launchResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
        )
        defer {
            if let cleanup = try? cleanupCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID) {
                _ = try? awaitCommandResponse(from: principal, request: cleanup)
            }
        }
        XCTAssertEqual(launchResponse.status, .accepted)

        let resizeResponse = try awaitCommandResponse(
            from: principal,
            request: resizeCommand(
                commandID: UUID(),
                sessionID: sessionID,
                requestID: requestID,
                columns: 132,
                rows: 43
            )
        )
        XCTAssertEqual(resizeResponse.status, .accepted)
        XCTAssertEqual(resizeResponse.transcriptEvents.first?.makeEvent()?.payload, .resize(columns: 132, rows: 43))

        let signalResponse = try awaitCommandResponse(
            from: principal,
            request: signalCommand(
                commandID: UUID(),
                sessionID: sessionID,
                requestID: requestID,
                signal: .terminate
            )
        )
        XCTAssertEqual(signalResponse.status, .accepted)
        XCTAssertEqual(signalResponse.transcriptEvents.first?.makeEvent()?.payload, .signal(.terminate))
    }

    func testDirectPrincipalReconnectsRunningSessionThroughTranscriptSpool() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()
        let reconnectID = UUID()

        let launchResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
        )
        defer {
            if let cleanup = try? cleanupCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID) {
                _ = try? awaitCommandResponse(from: principal, request: cleanup)
            }
        }
        XCTAssertEqual(launchResponse.status, .accepted)

        let resizeResponse = try awaitCommandResponse(
            from: principal,
            request: resizeCommand(
                commandID: UUID(),
                sessionID: sessionID,
                requestID: requestID,
                columns: 101,
                rows: 33
            )
        )
        XCTAssertEqual(resizeResponse.status, .accepted)

        let reconnectResponse = try awaitCommandResponse(
            from: principal,
            request: reconnectCommand(
                commandID: UUID(),
                sessionID: sessionID,
                requestID: requestID,
                reconnectID: reconnectID,
                afterSequence: 1
            )
        )

        XCTAssertEqual(reconnectResponse.status, .accepted)
        let events = reconnectResponse.transcriptEvents.compactMap { $0.makeEvent() }
        XCTAssertEqual(events.map(\.payload), [.reconnect(reconnectID: reconnectID)])
        XCTAssertEqual(events.map(\.source), [.app])
        XCTAssertEqual(events.map(\.sequence), [2])
    }

    func testDuplicateLaunchForSessionIsRejectedUntilCleanup() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let firstRequestID = UUID()
        let secondRequestID = UUID()

        let launchResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(commandID: UUID(), sessionID: sessionID, requestID: firstRequestID)
        )
        defer {
            if let cleanup = try? cleanupCommand(commandID: UUID(), sessionID: sessionID, requestID: firstRequestID) {
                _ = try? awaitCommandResponse(from: principal, request: cleanup)
            }
        }
        XCTAssertEqual(launchResponse.status, .accepted)

        let duplicateResponse = try awaitCommandResponse(
            from: principal,
            request: launchCommand(commandID: UUID(), sessionID: sessionID, requestID: secondRequestID)
        )

        XCTAssertEqual(duplicateResponse.status, .rejected)
        XCTAssertTrue(duplicateResponse.issues.contains { $0.contains("transitionNotAllowed") })
    }

    func testPollCacheConflictsAndEvictionPreserveMutationReplayProtection() throws {
        let principal = Phase2ShellBrokerPrincipal(maximumSeenCommandIDs: 4)
        let sessionID = UUID()
        let requestID = UUID()
        defer { principal.invalidate() }
        XCTAssertEqual(try awaitCommandResponse(from: principal,
            request: launchCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)).status, .accepted)
        let pollID = UUID()
        let poll = try pollCommand(commandID: pollID, sessionID: sessionID, requestID: requestID)
        let first = try awaitCommandResponse(from: principal, request: poll)
        XCTAssertEqual(try awaitCommandResponse(from: principal, request: poll), first)
        let conflict = try pollCommand(commandID: pollID, sessionID: sessionID,
            requestID: requestID, afterSequence: 1)
        XCTAssertEqual(try awaitCommandResponse(from: principal, request: conflict).status, .rejected)
        let collidingMutation = try writeInputCommand(commandID: pollID, sessionID: sessionID,
            requestID: requestID, bytes: Array("not-written\n".utf8))
        XCTAssertEqual(try awaitCommandResponse(from: principal, request: collidingMutation).status, .rejected)
        let input = try writeInputCommand(commandID: UUID(), sessionID: sessionID,
            requestID: requestID, bytes: Array("once\n".utf8))
        let written = try awaitCommandResponse(from: principal, request: input)
        XCTAssertEqual(written.status, .accepted)
        XCTAssertEqual(try awaitCommandResponse(from: principal, request: input), written)
        for _ in 0..<70 {
            XCTAssertEqual(try awaitCommandResponse(from: principal,
                request: pollCommand(commandID: UUID(), sessionID: sessionID,
                    requestID: requestID, afterSequence: 1)).status, .accepted)
        }
        // Evicted reads can safely run again; evicted mutations must never execute again.
        XCTAssertEqual(try awaitCommandResponse(from: principal, request: poll).status, .accepted)
        let replay = try awaitCommandResponse(from: principal, request: input)
        XCTAssertEqual(replay.status, .rejected)
        XCTAssertTrue(replay.issues.contains("duplicateCommandIdentifier"))
        let cleanup = try awaitCommandResponse(from: principal,
            request: cleanupCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID))
        XCTAssertEqual(cleanup.status, .accepted)
        XCTAssertEqual(cleanup.observedProcessAbsent, true)
    }

    func testPartialAndFailedInputRecordDeliveredPrefixAndReplayWithoutWritingAgain() throws {
        for failure in [EAGAIN, EIO] {
            let principal = Phase2ShellBrokerPrincipal()
            let sessionID = UUID()
            let requestID = UUID()
            defer { principal.invalidate() }
            XCTAssertEqual(try awaitCommandResponse(from: principal,
                request: launchCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)).status, .accepted)
            var writes = 0
            principal.writeInputForTesting = { lease, bytes in
                writes += 1
                let count = try lease.writeInput(Array(bytes.prefix(3)))
                throw Phase2ShellBrokerPTYAllocation.IOError.writeFailed(errno: failure, bytesWritten: count)
            }
            let command = try writeInputCommand(commandID: UUID(), sessionID: sessionID,
                requestID: requestID, bytes: Array("prefix-rest".utf8))
            let first = try awaitCommandResponse(from: principal, request: command)
            let replay = try awaitCommandResponse(from: principal, request: command)
            XCTAssertEqual(first.status, failure == EAGAIN ? .partial : .failed)
            XCTAssertEqual(first.bytesWritten, 3)
            XCTAssertEqual(first.transcriptEvents.compactMap { $0.makeEvent()?.payload }, [.input(Array("pre".utf8))])
            XCTAssertEqual(replay, first)
            XCTAssertEqual(writes, 1)
            let poll = try awaitCommandResponse(from: principal,
                request: pollCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID))
            XCTAssertEqual(poll.transcriptEvents.compactMap { event -> [UInt8]? in
                guard case .input(let bytes) = event.makeEvent()?.payload else { return nil }
                return bytes
            }, [Array("pre".utf8)])
        }
    }

    func testDuplicateCommandIdentifierReplaysResponseWithoutRepeatingInput() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()
        let commandID = UUID()
        defer { principal.invalidate() }
        XCTAssertEqual(try awaitCommandResponse(
            from: principal,
            request: launchCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
        ).status, .accepted)
        let command = try writeInputCommand(
            commandID: commandID,
            sessionID: sessionID,
            requestID: requestID,
            bytes: Array("once\n".utf8)
        )

        let first = try awaitCommandResponse(from: principal, request: command)
        let replay = try awaitCommandResponse(from: principal, request: command)
        let poll = try awaitCommandResponse(
            from: principal,
            request: pollCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
        )

        XCTAssertEqual(replay, first)
        XCTAssertEqual(poll.transcriptEvents.compactMap { event -> [UInt8]? in
            guard case .input(let bytes) = event.makeEvent()?.payload else { return nil }
            return bytes
        }, [Array("once\n".utf8)])
    }

    func testPrincipalNeverEmitsReplyLargerThanWireMaximum() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()
        defer { principal.invalidate() }
        XCTAssertEqual(try awaitCommandResponse(
            from: principal,
            request: launchCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
        ).status, .accepted)
        for index in 0..<1_024 {
            XCTAssertEqual(try awaitCommandResponse(
                from: principal,
                request: resizeCommand(
                    commandID: UUID(),
                    sessionID: sessionID,
                    requestID: requestID,
                    columns: 80 + (index % 20),
                    rows: 24
                )
            ).status, .accepted)
        }
        let poll = Phase2ShellBrokerCommandRequest(
            commandID: UUID(),
            command: .pollTranscript,
            payload: try Phase2ShellBrokerWireCodec.encodePollTranscriptRequest(
                Phase2ShellBrokerPollTranscriptRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    maximumEvents: 1_024,
                    maximumBytes: Phase2ShellBrokerProtocolIdentity.maximumMessageBytes,
                    timeoutMilliseconds: 0
                )
            )
        )

        let reply = try awaitCommandResponseData(from: principal, request: poll)

        XCTAssertLessThanOrEqual(reply.count, Phase2ShellBrokerProtocolIdentity.maximumMessageBytes)
    }

    func testConcurrentDuplicateSessionLaunchHasExactlyOneProcessOwner() throws {
        let principal = Phase2ShellBrokerPrincipal()
        let sessionID = UUID()
        let requestID = UUID()
        let requests = try (0..<8).map { _ in
            try Phase2ShellBrokerWireCodec.encodeCommandRequest(
                launchCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
            )
        }
        let responses = ShellBrokerResponseDataBox()
        let start = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()
        defer {
            for response in responses.values().compactMap({ try? Phase2ShellBrokerWireCodec.decodeCommandResponse($0) }) {
                if let processIdentifier = response.processIdentifier {
                    _ = Darwin.kill(-processIdentifier, SIGKILL)
                }
            }
            principal.invalidate()
        }

        for request in requests {
            finished.enter()
            DispatchQueue.global().async {
                start.wait()
                principal.performCommand(request) { data in
                    responses.append(data)
                    finished.leave()
                }
            }
        }
        for _ in requests { start.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)

        let decoded = try responses.values().map(Phase2ShellBrokerWireCodec.decodeCommandResponse)
        XCTAssertEqual(decoded.filter { $0.status == .accepted }.count, 1)
    }

    func testPeerRequirementsBindAppAndBrokerToStableDevelopmentCertificate() {
        XCTAssertTrue(Phase2ShellBrokerPeerRequirement.app.contains("identifier \"org.macscope.app\""))
        XCTAssertTrue(
            Phase2ShellBrokerPeerRequirement.broker.contains(
                "identifier \"org.macscope.app.ShellBroker\""
            )
        )
        XCTAssertTrue(
            Phase2ShellBrokerPeerRequirement.app.contains(
                "Apple Development: MacScope Developer (CERT000000)"
            )
        )
        XCTAssertTrue(
            Phase2ShellBrokerPeerRequirement.broker.contains(
                "Apple Development: MacScope Developer (CERT000000)"
            )
        )
    }

    func testShellBrokerInfoPlistIsApplicationXPCService() throws {
        let plistURL = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShellBrokerService/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "XPC!")
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)")
        let service = try XCTUnwrap(plist["XPCService"] as? [String: Any])
        XCTAssertEqual(service["ServiceType"] as? String, "Application")
    }

    func testShellBrokerLaunchAgentReusesSignedBrokerAndPublishesDistinctMachService() throws {
        let plistURL = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShellBrokerService/LaunchAgent.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["Label"] as? String, Phase2ShellBrokerProtocolIdentity.persistentMachServiceName)
        XCTAssertEqual(
            plist["BundleProgram"] as? String,
            "Contents/MacOS/ShellBrokerLaunchAgent"
        )
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["ShellBrokerLaunchAgent", "--launch-agent"]
        )
        let machServices = try XCTUnwrap(plist["MachServices"] as? [String: Any])
        XCTAssertEqual(machServices[Phase2ShellBrokerProtocolIdentity.persistentMachServiceName] as? Bool, true)
        XCTAssertNil(plist["Program"])
        XCTAssertNil(plist["KeepAlive"])
    }

    func testShellBrokerEntrypointKeepsEmbeddedAndLaunchAgentListenersAlive() throws {
        let mainURL = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShellBrokerService/main.swift")
        let source = try String(contentsOf: mainURL, encoding: .utf8)

        XCTAssertTrue(source.contains("listener.resume()\ndispatchMain()"))
        XCTAssertFalse(source.contains("if CommandLine.arguments.contains(\"--launch-agent\") {\n    dispatchMain()\n}"))
    }

    func testLaunchAgentRegistrationIsInstalledPathOnly() {
        XCTAssertTrue(
            Phase2ShellBrokerLaunchAgentRegistration.isCanonicalInstalledApplication(
                URL(fileURLWithPath: "/Applications/MacScope.app")
            )
        )
        XCTAssertFalse(
            Phase2ShellBrokerLaunchAgentRegistration.isCanonicalInstalledApplication(
                URL(fileURLWithPath: "/tmp/DerivedData/Build/Products/Debug/MacScope.app")
            )
        )
    }

    func testLaunchAgentRegistrationAttemptsInitialNotFoundAndNotRegisteredStates() {
        XCTAssertTrue(
            Phase2ShellBrokerLaunchAgentRegistration.shouldAttemptRegistration(status: .notFound)
        )
        XCTAssertTrue(
            Phase2ShellBrokerLaunchAgentRegistration.shouldAttemptRegistration(status: .notRegistered)
        )
        XCTAssertFalse(
            Phase2ShellBrokerLaunchAgentRegistration.shouldAttemptRegistration(status: .enabled)
        )
        XCTAssertFalse(
            Phase2ShellBrokerLaunchAgentRegistration.shouldAttemptRegistration(status: .requiresApproval)
        )
    }

    func testConcurrentLaunchAgentPreparationRegistersOnce() {
        let service = ConcurrentLaunchAgentService()
        let finished = DispatchGroup()
        let start = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            finished.enter()
            DispatchQueue.global().async {
                start.wait()
                Phase2ShellBrokerLaunchAgentRegistration.prepareForApplicationLaunch(
                    bundleURL: URL(fileURLWithPath: "/Applications/MacScope.app"),
                    service: service
                )
                finished.leave()
            }
        }
        start.signal()
        start.signal()

        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(Phase2ShellBrokerLaunchAgentRegistration.state, .enabled)
    }

    func testLaunchAgentFailureDiagnosticAndLoggingStayPrivateAndBounded() throws {
        let service = ConcurrentLaunchAgentService(
            registrationError: NSError(
                domain: String(repeating: "/private/sensitive/path/", count: 100),
                code: 9
            )
        )
        Phase2ShellBrokerLaunchAgentRegistration.prepareForApplicationLaunch(
            bundleURL: URL(fileURLWithPath: "/Applications/MacScope.app"),
            service: service
        )
        XCTAssertLessThanOrEqual(
            Phase2ShellBrokerLaunchAgentRegistration.diagnostic.utf8.count,
            Phase2ShellBrokerLaunchAgentRegistration.maximumDiagnosticBytes
        )

        let registrationURL = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Services/Phase2/Phase2ShellBrokerLaunchAgentRegistration.swift")
        let source = try String(contentsOf: registrationURL, encoding: .utf8)
        XCTAssertTrue(source.contains("diagnostic, privacy: .private(mask: .hash)"))
        XCTAssertFalse(source.contains("diagnostic, privacy: .public"))
    }

    func testTransportCancellationAndReplyUseSinglePendingClaim() throws {
        let transportURL = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Services/Phase2/ShellBrokerXPCTransport.swift")
        let source = try String(contentsOf: transportURL, encoding: .utf8)

        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "withTaskCancellationHandler").count - 1, 2)
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: "claimPendingOperation").count - 1, 2)
        XCTAssertFalse(source.contains("pending.removeValue(forKey: operationID) }\n                guard operation.complete()"))
        XCTAssertFalse(source.contains("pending.removeValue(forKey: handshakeID) }\n                guard operation.complete()"))
    }

    func testProjectEmbedsAndKeepsClosedShellBrokerTarget() throws {
        let projectURL = TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL, encoding: .utf8)

        XCTAssertTrue(project.contains("  ShellBrokerXPCService:\n"))
        XCTAssertTrue(project.contains("    type: xpc-service\n"))
        XCTAssertTrue(project.contains("        PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.ShellBroker\n"))
        XCTAssertTrue(project.contains("        INFOPLIST_FILE: ShellBrokerService/Info.plist\n"))

        let appBody = try targetBody("MacScopeApp", in: project)
        XCTAssertTrue(appBody.contains("      - target: ShellBrokerXPCService\n"))
        XCTAssertTrue(appBody.contains("      - target: ShellBrokerLaunchAgent\n"))
        XCTAssertTrue(appBody.contains("        embed: true\n"))
        XCTAssertTrue(appBody.contains("        codeSign: true\n"))
        XCTAssertTrue(appBody.contains("      - name: Stage ShellBroker LaunchAgent property list\n"))
        XCTAssertTrue(
            appBody.contains(
                "$(CONTENTS_FOLDER_PATH)/Library/LaunchAgents/org.macscope.app.ShellBroker.agent.plist"
            )
        )

        let brokerTargetBody = try targetBody("ShellBrokerXPCService", in: project)
        XCTAssertTrue(brokerTargetBody.contains("      - name: Verify certificate-backed signing environment\n"))
        XCTAssertTrue(brokerTargetBody.contains("      - path: Models/Phase2/Phase2HumanPTYTranscript.swift\n"))
        XCTAssertTrue(brokerTargetBody.contains("      - path: Models/Phase2/Phase2HumanPTYBroker.swift\n"))
        XCTAssertTrue(brokerTargetBody.contains("      - path: Models/Phase2/Phase2ShellBrokerXPCProtocol.swift\n"))
        XCTAssertTrue(brokerTargetBody.contains("      - path: Models/Phase2/Phase2ShellBrokerLifecycle.swift\n"))
        XCTAssertTrue(brokerTargetBody.contains("      - path: ShellBrokerService/Phase2ShellBrokerProcessAdapter.swift\n"))
        XCTAssertTrue(brokerTargetBody.contains("      - path: ShellBrokerService/main.swift\n"))
        XCTAssertTrue(brokerTargetBody.contains("      - path: ShellBrokerService/Phase2ShellBrokerPrincipal.swift\n"))
        XCTAssertFalse(brokerTargetBody.contains("      - path: Models\n"))
        XCTAssertFalse(brokerTargetBody.contains("      - path: Services\n"))
        XCTAssertFalse(brokerTargetBody.contains("      - path: Stores\n"))
        XCTAssertFalse(brokerTargetBody.contains("      - path: Features\n"))
        XCTAssertFalse(brokerTargetBody.contains("      - path: AIAgentWorkerCore\n"))

        let agentBody = try targetBody("ShellBrokerLaunchAgent", in: project)
        XCTAssertTrue(agentBody.contains("    type: tool\n"))
        XCTAssertTrue(agentBody.contains("        PRODUCT_BUNDLE_IDENTIFIER: org.macscope.app.ShellBrokerLaunchAgent\n"))
        XCTAssertTrue(agentBody.contains("      - path: ShellBrokerService/main.swift\n"))
    }

    func testLiveEmbeddedShellBrokerHandshakeMatchesDirectBoundary() async throws {
        let transport = NSXPCShellBrokerTransport()
        defer {
            Task { await transport.reset() }
        }

        let handshake = try await transport.handshake()
        let receipt = try await transport.prepareBrokerProcessReceipt()

        XCTAssertEqual(handshake.schemaVersion, 4)
        XCTAssertEqual(handshake.serviceIdentifier, "terminal.human_pty.shell_broker")
        XCTAssertEqual(handshake.wireProtocol, "macscope.phase2.shell_broker.xpc.v4")
        XCTAssertEqual(handshake.status, .boundaryReady)
        XCTAssertEqual(handshake.supportedCommands, MacScope.Phase2ShellBrokerCommandKind.allCases.map(\.rawValue))
        XCTAssertEqual(handshake.maximumMessageBytes, 64 * 1024)
        XCTAssertGreaterThan(receipt.processIdentifier, 1)
        XCTAssertEqual(receipt.wireProtocol, handshake.wireProtocol)
        XCTAssertEqual(
            receipt.supportedCommands.map(\.rawValue),
            MacScope.Phase2ShellBrokerCommandKind.allCases.map(\.rawValue)
        )
        let receiptStillValid = await transport.revalidateBrokerProcessReceipt(receipt)
        XCTAssertTrue(receiptStillValid)

        await transport.reset()
    }

    func testLiveEmbeddedShellBrokerForwardsInputAndPollsTranscript() async throws {
        let transport = NSXPCShellBrokerTransport()
        defer {
            Task { await transport.reset() }
        }
        let sessionID = UUID()
        let requestID = UUID()
        let marker = "macscope-live-xpc-input"

        let launchPayload = try MacScope.Phase2ShellBrokerWireCodec.encodeLaunchProcessRequest(
            MacScope.Phase2ShellBrokerLaunchProcessRequest(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/sh",
                arguments: ["-c", "IFS= read -r line; printf 'reply:%s\\n' \"$line\"; sleep 30"]
            )
        )
        let launchResponse = try await transport.perform(MacScope.Phase2ShellBrokerCommandRequest(
            commandID: UUID(),
            command: .launchProcess,
            payload: launchPayload
        ))
        defer {
            Task {
                let cleanupPayload = try? MacScope.Phase2ShellBrokerWireCodec.encodeCleanupProcessRequest(
                    MacScope.Phase2ShellBrokerCleanupProcessRequest(sessionID: sessionID, requestID: requestID)
                )
                if let cleanupPayload {
                    _ = try? await transport.perform(MacScope.Phase2ShellBrokerCommandRequest(
                        commandID: UUID(),
                        command: .cleanupProcess,
                        payload: cleanupPayload
                    ))
                }
                await transport.reset()
            }
        }
        XCTAssertEqual(launchResponse.status, .accepted)

        let writePayload = try MacScope.Phase2ShellBrokerWireCodec.encodeWriteInputRequest(
            MacScope.Phase2ShellBrokerWriteInputRequest(
                sessionID: sessionID,
                requestID: requestID,
                bytes: Array("\(marker)\n".utf8)
            )
        )
        let writeResponse = try await transport.perform(MacScope.Phase2ShellBrokerCommandRequest(
            commandID: UUID(),
            command: .writeInput,
            payload: writePayload
        ))
        XCTAssertEqual(writeResponse.status, .accepted)

        let deadline = Date().addingTimeInterval(3)
        var observedEvents: [MacScope.Phase2HumanPTYTranscriptEvent] = []
        while Date() < deadline {
            let pollPayload = try MacScope.Phase2ShellBrokerWireCodec.encodePollTranscriptRequest(
                MacScope.Phase2ShellBrokerPollTranscriptRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    maximumEvents: 16,
                    maximumBytes: 4_096,
                    timeoutMilliseconds: 50
                )
            )
            let pollResponse = try await transport.perform(MacScope.Phase2ShellBrokerCommandRequest(
                commandID: UUID(),
                command: .pollTranscript,
                payload: pollPayload
            ))
            observedEvents = pollResponse.transcriptEvents.compactMap { $0.makeEvent() }
            if observedEvents.contains(where: { event in
                guard case .output(_, let bytes) = event.payload else { return false }
                return String(decoding: bytes, as: UTF8.self).contains("reply:\(marker)")
            }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(observedEvents.contains { event in
            guard case .output(_, let bytes) = event.payload else { return false }
            return String(decoding: bytes, as: UTF8.self).contains("reply:\(marker)")
        })

        await transport.reset()
    }

    func testLiveEmbeddedShellBrokerRejectsCleanupBeforeLaunch() async throws {
        let transport = NSXPCShellBrokerTransport()
        defer {
            Task { await transport.reset() }
        }
        let commandID = UUID()
        let sessionID = UUID()
        let requestID = UUID()

        let cleanupPayload = try MacScope.Phase2ShellBrokerWireCodec.encodeCleanupProcessRequest(
            MacScope.Phase2ShellBrokerCleanupProcessRequest(
                sessionID: sessionID,
                requestID: requestID
            )
        )
        let response = try await transport.perform(
            MacScope.Phase2ShellBrokerCommandRequest(
                commandID: commandID,
                command: .cleanupProcess,
                payload: cleanupPayload
            )
        )

        XCTAssertEqual(response.commandID, commandID)
        XCTAssertEqual(response.command, MacScope.Phase2ShellBrokerCommandKind.cleanupProcess)
        XCTAssertEqual(response.status, MacScope.Phase2ShellBrokerCommandResponse.Status.rejected)
        XCTAssertEqual(response.sessionID, sessionID)
        XCTAssertEqual(response.requestID, requestID)
        XCTAssertTrue(response.issues.contains("noRunningLease"))

        await transport.reset()
    }

    private func awaitHandshake(from principal: Phase2ShellBrokerPrincipal) throws -> Data {
        let expectation = expectation(description: "handshake reply")
        var result: Data?
        principal.handshake { data in
            result = data
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        return try XCTUnwrap(result)
    }

    private func awaitCommandResponse(
        from principal: Phase2ShellBrokerPrincipal,
        request: Phase2ShellBrokerCommandRequest
    ) throws -> Phase2ShellBrokerCommandResponse {
        let data = try awaitCommandResponseData(from: principal, request: request)
        return try Phase2ShellBrokerWireCodec.decodeCommandResponse(data)
    }

    private func awaitCommandResponseData(
        from principal: Phase2ShellBrokerPrincipal,
        request: Phase2ShellBrokerCommandRequest
    ) throws -> Data {
        try awaitCommandResponseData(
            from: principal,
            data: Phase2ShellBrokerWireCodec.encodeCommandRequest(request)
        )
    }

    private func awaitCommandResponseData(
        from principal: Phase2ShellBrokerPrincipal,
        data: Data
    ) throws -> Data {
        let expectation = expectation(description: "command reply")
        var result: Data?
        principal.performCommand(data) { data in
            result = data
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3)
        return try XCTUnwrap(result)
    }

    private func launchCommand(
        commandID: UUID,
        sessionID: UUID,
        requestID: UUID
    ) throws -> Phase2ShellBrokerCommandRequest {
        try launchCommand(
            commandID: commandID,
            launchRequest: Phase2ShellBrokerLaunchProcessRequest(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/sleep",
                arguments: ["30"]
            )
        )
    }

    private func launchCommand(
        commandID: UUID,
        launchRequest: Phase2ShellBrokerLaunchProcessRequest
    ) throws -> Phase2ShellBrokerCommandRequest {
        Phase2ShellBrokerCommandRequest(
            commandID: commandID,
            command: .launchProcess,
            payload: try Phase2ShellBrokerWireCodec.encodeLaunchProcessRequest(launchRequest)
        )
    }

    private func cleanupCommand(
        commandID: UUID,
        sessionID: UUID,
        requestID: UUID
    ) throws -> Phase2ShellBrokerCommandRequest {
        Phase2ShellBrokerCommandRequest(
            commandID: commandID,
            command: .cleanupProcess,
            payload: try Phase2ShellBrokerWireCodec.encodeCleanupProcessRequest(
                Phase2ShellBrokerCleanupProcessRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    reason: "userCancel"
                )
            )
        )
    }

    private func writeInputCommand(
        commandID: UUID,
        sessionID: UUID,
        requestID: UUID,
        bytes: [UInt8]
    ) throws -> Phase2ShellBrokerCommandRequest {
        Phase2ShellBrokerCommandRequest(
            commandID: commandID,
            command: .writeInput,
            payload: try Phase2ShellBrokerWireCodec.encodeWriteInputRequest(
                Phase2ShellBrokerWriteInputRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    bytes: bytes
                )
            )
        )
    }

    private func resizeCommand(
        commandID: UUID,
        sessionID: UUID,
        requestID: UUID,
        columns: Int,
        rows: Int
    ) throws -> Phase2ShellBrokerCommandRequest {
        Phase2ShellBrokerCommandRequest(
            commandID: commandID,
            command: .resizeTerminal,
            payload: try Phase2ShellBrokerWireCodec.encodeResizeTerminalRequest(
                Phase2ShellBrokerResizeTerminalRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    columns: columns,
                    rows: rows
                )
            )
        )
    }

    private func signalCommand(
        commandID: UUID,
        sessionID: UUID,
        requestID: UUID,
        signal: Phase2HumanPTYSignal
    ) throws -> Phase2ShellBrokerCommandRequest {
        Phase2ShellBrokerCommandRequest(
            commandID: commandID,
            command: .sendSignal,
            payload: try Phase2ShellBrokerWireCodec.encodeSendSignalRequest(
                Phase2ShellBrokerSendSignalRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    signal: signal
                )
            )
        )
    }

    private func pollCommand(
        commandID: UUID,
        sessionID: UUID,
        requestID: UUID,
        afterSequence: UInt64 = 0
    ) throws -> Phase2ShellBrokerCommandRequest {
        Phase2ShellBrokerCommandRequest(
            commandID: commandID,
            command: .pollTranscript,
            payload: try Phase2ShellBrokerWireCodec.encodePollTranscriptRequest(
                Phase2ShellBrokerPollTranscriptRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    afterSequence: afterSequence,
                    maximumEvents: 16,
                    maximumBytes: 4_096,
                    timeoutMilliseconds: 50
                )
            )
        )
    }

    private func reconnectCommand(
        commandID: UUID,
        sessionID: UUID,
        requestID: UUID,
        reconnectID: UUID,
        afterSequence: UInt64 = 0
    ) throws -> Phase2ShellBrokerCommandRequest {
        Phase2ShellBrokerCommandRequest(
            commandID: commandID,
            command: .reconnectSession,
            payload: try Phase2ShellBrokerWireCodec.encodeReconnectSessionRequest(
                Phase2ShellBrokerReconnectSessionRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    reconnectID: reconnectID,
                    afterSequence: afterSequence,
                    maximumEvents: 16,
                    maximumBytes: 4_096
                )
            )
        )
    }

    private func waitForTranscriptEvents(
        from principal: Phase2ShellBrokerPrincipal,
        sessionID: UUID,
        requestID: UUID,
        containing fragment: String
    ) throws -> [Phase2HumanPTYTranscriptEvent] {
        let deadline = Date().addingTimeInterval(3)
        var events: [Phase2HumanPTYTranscriptEvent] = []
        while Date() < deadline {
            let response = try awaitCommandResponse(
                from: principal,
                request: pollCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
            )
            events = response.transcriptEvents.compactMap { $0.makeEvent() }
            if events.contains(where: { event in
                guard case .output(_, let bytes) = event.payload else { return false }
                return String(decoding: bytes, as: UTF8.self).contains(fragment)
            }) {
                return events
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return events
    }

    private func waitForTerminalTranscriptEvents(
        from principal: Phase2ShellBrokerPrincipal,
        sessionID: UUID,
        requestID: UUID
    ) throws -> [Phase2HumanPTYTranscriptEvent] {
        let deadline = Date().addingTimeInterval(3)
        var events: [Phase2HumanPTYTranscriptEvent] = []
        while Date() < deadline {
            let response = try awaitCommandResponse(
                from: principal,
                request: pollCommand(commandID: UUID(), sessionID: sessionID, requestID: requestID)
            )
            events = response.transcriptEvents.compactMap { $0.makeEvent() }
            if events.contains(where: { event in
                if case .terminal = event.payload {
                    return true
                }
                return false
            }) {
                return events
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return events
    }

    private func processExists(_ processIdentifier: Int32) -> Bool {
        Darwin.kill(processIdentifier, 0) == 0
    }

    private func targetBody(_ target: String, in project: String) throws -> String {
        let pattern = #"(?ms)^  \#(target):\n(?<body>.*?)(?=^  [A-Za-z0-9_]+:|^schemes:|\z)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(project.startIndex..<project.endIndex, in: project)
        let match = try XCTUnwrap(regex.firstMatch(in: project, range: range))
        let bodyRange = try XCTUnwrap(Range(match.range(withName: "body"), in: project))
        return String(project[bodyRange])
    }
}

private final class ShellBrokerResponseDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func values() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class ConcurrentLaunchAgentService: Phase2ShellBrokerLaunchAgentServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: SMAppService.Status = .notRegistered
    private var storedRegisterCallCount = 0
    private let registrationError: Error?

    init(registrationError: Error? = nil) {
        self.registrationError = registrationError
    }

    var status: SMAppService.Status {
        lock.lock()
        defer { lock.unlock() }
        return storedStatus
    }

    var registerCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRegisterCallCount
    }

    func register() throws {
        lock.lock()
        storedRegisterCallCount += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.1)
        if let registrationError { throw registrationError }
        lock.lock()
        storedStatus = .enabled
        lock.unlock()
    }
}
