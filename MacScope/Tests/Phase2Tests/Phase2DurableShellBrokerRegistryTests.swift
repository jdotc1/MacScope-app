import Darwin
import Foundation
import XCTest
@testable import MacScope

final class Phase2DurableShellBrokerRegistryTests: XCTestCase {
    func testDetachedDurableSessionContinuouslyDrainsOutputBeyondPTYCapacity() throws {
        let brokerID = UUID()
        let sessionID = UUID()
        let requestID = UUID()
        let capabilityID = UUID()
        let clientID = UUID()
        let now = Date()
        let outputByteCount = 2 * 1_024 * 1_024
        let limits = Phase2HumanPTYTranscriptLimits(
            maximumEvents: 16,
            maximumEventBytes: 16 * 1_024,
            maximumCumulativeBytes: 64 * 1_024
        )
        let lease = try Phase2ShellBrokerProcessAdapter().launch(Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sh",
            arguments: ["-c", "yes x | head -c \(outputByteCount); printf MACSCOPE_DRAIN_COMPLETE"],
            initialSize: .defaultInteractive,
            transcriptLimits: limits
        ))
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            startExpirySweeper: false
        )
        defer { registry.cleanupAllForTesting() }
        _ = try registry.register(
            launchRequest: Phase2DurableShellBrokerLaunchRequest(
                brokerIncarnationID: brokerID,
                sessionID: sessionID,
                capabilityID: capabilityID,
                requestID: requestID,
                executablePath: "/bin/sh",
                arguments: ["-c", "yes x | head -c \(outputByteCount); printf MACSCOPE_DRAIN_COMPLETE"],
                workingDirectoryPath: nil,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            capabilitySecretBytes: secretBytes,
            lease: lease,
            clientID: clientID,
            now: now
        )
        let authentication = try self.authentication(
            brokerID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID
        )
        _ = try registry.commit(authentication: authentication, clientID: clientID, now: now)
        _ = try registry.detach(authentication: authentication, clientID: clientID, now: now)

        // The drain reads at most 16 KiB per queue hop (transcript-event
        // sizing), so 2 MiB takes 128+ asyncAfter hops — a few seconds on an
        // idle machine and appreciably longer while the parallel CoreTests
        // fleet shares the cores. The deadline is deliberately generous: a
        // child that is truly blocked on a full PTY buffer never exits, so any
        // finite bound still catches the regression this test exists for,
        // while the healthy path leaves the loop the moment the child exits.
        let exitDeadline = Date().addingTimeInterval(30)
        while lease.isRunning, Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(lease.isRunning, "detached child must not block on a full PTY buffer")

        let terminalDeadline = Date().addingTimeInterval(10)
        var snapshot = try registry.transcriptSnapshot(
            sessionID: sessionID,
            afterSequence: 0,
            maximumEvents: 64,
            maximumBytes: 128 * 1_024
        )
        while !snapshot.events.contains(where: { if case .terminal = $0.payload { true } else { false } }),
              Date() < terminalDeadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = try registry.transcriptSnapshot(
                sessionID: sessionID,
                afterSequence: 0,
                maximumEvents: 64,
                maximumBytes: 128 * 1_024
            )
        }

        XCTAssertTrue(snapshot.events.contains(where: {
            if case .gap(reason: .spoolLimitExceeded, let lostByteCount) = $0.payload {
                return lostByteCount > 0
            }
            return false
        }), "bounded spooling must leave explicit compaction evidence")
        XCTAssertTrue(snapshot.events.contains(where: {
            if case .output(_, let bytes) = $0.payload {
                return String(decoding: bytes, as: UTF8.self).contains("MACSCOPE_DRAIN_COMPLETE")
            }
            return false
        }), "the transcript must retain the final detached output")
        XCTAssertTrue(snapshot.events.contains(where: {
            if case .terminal(.exited(status: 0)) = $0.payload { return true }
            return false
        }), "the broker drain must observe and spool the terminal outcome")
    }

    func testCommittedDetachedSessionSurvivesProvisionalGraceUntilHardExpiry() throws {
        let fixture = try makeRegisteredFixture(requestedLifetime: 60, detachedGrace: 5)
        defer { fixture.registry.cleanupAllForTesting() }
        let authentication = try authentication(
            brokerID: fixture.brokerID,
            sessionID: fixture.sessionID,
            capabilityID: fixture.capabilityID
        )

        _ = try fixture.registry.commit(
            authentication: authentication,
            clientID: fixture.clientID,
            now: fixture.now.addingTimeInterval(1)
        )
        _ = try fixture.registry.detach(
            authentication: authentication,
            clientID: fixture.clientID,
            now: fixture.now.addingTimeInterval(2)
        )

        XCTAssertEqual(fixture.registry.cleanupExpired(now: fixture.now.addingTimeInterval(7)).count, 0)
        XCTAssertNoThrow(try fixture.registry.status(
            authentication: authentication,
            clientID: UUID(),
            now: fixture.now.addingTimeInterval(8)
        ))
        XCTAssertEqual(fixture.registry.cleanupExpired(now: fixture.now.addingTimeInterval(60)).count, 1)
    }

    func testRegistryOwnsMonotonicTranscriptAcrossPrincipalAttachments() throws {
        let fixture = try makeRegisteredFixture()
        defer { fixture.registry.cleanupAllForTesting() }

        let first = try fixture.registry.appendTranscriptEvent(
            sessionID: fixture.sessionID,
            source: .human,
            payload: .input([0x61])
        )
        let second = try fixture.registry.appendTranscriptEvent(
            sessionID: fixture.sessionID,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [0x62])
        )
        let snapshot = try fixture.registry.transcriptSnapshot(
            sessionID: fixture.sessionID,
            afterSequence: 0,
            maximumEvents: 10,
            maximumBytes: 1_024
        )

        XCTAssertEqual([first.sequence, second.sequence], [1, 2])
        XCTAssertEqual(snapshot.events.map(\.sequence), [1, 2])
        XCTAssertEqual(snapshot.nextSequence, 3)
    }

    func testSecondPrincipalPollsExactDurableHistoryAfterFirstInvalidates() throws {
        let brokerID = UUID()
        let registry = Phase2DurableShellBrokerRegistry(brokerIncarnationID: brokerID, startExpirySweeper: false)
        let first = Phase2ShellBrokerPrincipal(durableRegistry: registry)
        let second = Phase2ShellBrokerPrincipal(durableRegistry: registry)
        let sessionID = UUID()
        let requestID = UUID()
        let capabilityID = UUID()
        let now = Date()
        let authenticationWire = Phase2ShellBrokerDurableAuthenticationWire(
            brokerIncarnationID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID,
            capabilitySecretBytes: secretBytes
        )
        let authentication = try authenticationWire.makeAuthenticationRequest()
        defer { _ = try? registry.cleanup(authentication: authentication) }

        let launch = try commandResponse(
            from: first,
            command: .launchDurableProcess,
            payload: Phase2ShellBrokerWireCodec.encodeLaunchDurableProcessRequest(
                Phase2ShellBrokerLaunchDurableProcessRequest(
                    launch: Phase2ShellBrokerLaunchProcessRequest(
                        sessionID: sessionID,
                        requestID: requestID,
                        executablePath: "/bin/cat",
                        arguments: []
                    ),
                    durableLaunch: Phase2DurableShellBrokerLaunchRequest(
                        brokerIncarnationID: brokerID,
                        sessionID: sessionID,
                        capabilityID: capabilityID,
                        requestID: requestID,
                        executablePath: "/bin/cat",
                        arguments: [],
                        workingDirectoryPath: nil,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(60)
                    ),
                    capabilitySecretBytes: secretBytes
                )
            )
        )
        XCTAssertEqual(launch.status, .accepted)
        let write = try commandResponse(
            from: first,
            command: .writeInput,
            payload: Phase2ShellBrokerWireCodec.encodeWriteInputRequest(
                Phase2ShellBrokerWriteInputRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    bytes: Array("durable\n".utf8)
                )
            )
        )
        let writtenSequence = try XCTUnwrap(write.transcriptEvents.first?.sequence)
        first.invalidate()

        XCTAssertEqual(try commandResponse(
            from: second,
            command: .attachDurableSession,
            payload: Phase2ShellBrokerWireCodec.encodeDurableSessionRequest(
                Phase2ShellBrokerDurableSessionRequest(authentication: authenticationWire)
            )
        ).status, .accepted)
        let poll = try commandResponse(
            from: second,
            command: .pollTranscript,
            payload: Phase2ShellBrokerWireCodec.encodePollTranscriptRequest(
                Phase2ShellBrokerPollTranscriptRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    afterSequence: 0,
                    maximumEvents: 32,
                    maximumBytes: 4_096,
                    timeoutMilliseconds: 0
                )
            )
        )

        XCTAssertEqual(poll.status, .accepted)
        XCTAssertTrue(poll.transcriptEvents.contains(where: { $0.sequence == writtenSequence }))
        XCTAssertEqual(poll.nextTranscriptSequence, poll.transcriptEvents.map(\.sequence).max().map { $0 + 1 })
    }

    func testDurablePollReadsSpoolWithoutDuplicatingDrainedPTYBytes() throws {
        let brokerID = UUID()
        let registry = Phase2DurableShellBrokerRegistry(brokerIncarnationID: brokerID, startExpirySweeper: false)
        let principal = Phase2ShellBrokerPrincipal(durableRegistry: registry)
        let sessionID = UUID()
        let requestID = UUID()
        let capabilityID = UUID()
        let now = Date()
        let marker = "MACSCOPE_SINGLE_DRAIN_MARKER"
        let authentication = try self.authentication(
            brokerID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID
        )
        defer { _ = try? registry.cleanup(authentication: authentication) }

        let launch = try commandResponse(
            from: principal,
            command: .launchDurableProcess,
            payload: Phase2ShellBrokerWireCodec.encodeLaunchDurableProcessRequest(
                Phase2ShellBrokerLaunchDurableProcessRequest(
                    launch: Phase2ShellBrokerLaunchProcessRequest(
                        sessionID: sessionID,
                        requestID: requestID,
                        executablePath: "/bin/sh",
                        arguments: ["-c", "printf \(marker); sleep 30"]
                    ),
                    durableLaunch: Phase2DurableShellBrokerLaunchRequest(
                        brokerIncarnationID: brokerID,
                        sessionID: sessionID,
                        capabilityID: capabilityID,
                        requestID: requestID,
                        executablePath: "/bin/sh",
                        arguments: ["-c", "printf \(marker); sleep 30"],
                        workingDirectoryPath: nil,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(60)
                    ),
                    capabilitySecretBytes: secretBytes
                )
            )
        )
        XCTAssertEqual(launch.status, .accepted)

        let markerDeadline = Date().addingTimeInterval(2)
        var snapshot = try registry.transcriptSnapshot(
            sessionID: sessionID,
            afterSequence: 0,
            maximumEvents: 64,
            maximumBytes: 64 * 1_024
        )
        while !snapshot.events.contains(where: {
            if case .output(_, let bytes) = $0.payload {
                return String(decoding: bytes, as: UTF8.self).contains(marker)
            }
            return false
        }), Date() < markerDeadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = try registry.transcriptSnapshot(
                sessionID: sessionID,
                afterSequence: 0,
                maximumEvents: 64,
                maximumBytes: 64 * 1_024
            )
        }

        for _ in 0..<5 {
            let poll = try commandResponse(
                from: principal,
                command: .pollTranscript,
                payload: Phase2ShellBrokerWireCodec.encodePollTranscriptRequest(
                    Phase2ShellBrokerPollTranscriptRequest(
                        sessionID: sessionID,
                        requestID: requestID,
                        afterSequence: 0,
                        maximumEvents: 64,
                        maximumBytes: 64 * 1_024,
                        timeoutMilliseconds: 25
                    )
                )
            )
            XCTAssertEqual(poll.status, .accepted)
        }

        snapshot = try registry.transcriptSnapshot(
            sessionID: sessionID,
            afterSequence: 0,
            maximumEvents: 64,
            maximumBytes: 64 * 1_024
        )
        let output = snapshot.events.reduce(into: "") { result, event in
            if case .output(_, let bytes) = event.payload {
                result += String(decoding: bytes, as: UTF8.self)
            }
        }
        XCTAssertEqual(output.components(separatedBy: marker).count - 1, 1)
    }

    func testDurableRegistrationTransferIsAtomicAgainstConcurrentInvalidation() throws {
        let brokerID = UUID()
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            startExpirySweeper: false
        )
        let principal = Phase2ShellBrokerPrincipal(durableRegistry: registry)
        let sessionID = UUID()
        let requestID = UUID()
        let capabilityID = UUID()
        let now = Date()
        let publishReached = DispatchSemaphore(value: 0)
        let allowPublish = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        let responseFinished = DispatchSemaphore(value: 0)
        registry.registrationWillPublish = {
            publishReached.signal()
            _ = allowPublish.wait(timeout: .now() + 5)
        }
        let wireRequest = Phase2ShellBrokerCommandRequest(
            commandID: UUID(),
            command: .launchDurableProcess,
            payload: try Phase2ShellBrokerWireCodec.encodeLaunchDurableProcessRequest(
                Phase2ShellBrokerLaunchDurableProcessRequest(
                    launch: Phase2ShellBrokerLaunchProcessRequest(
                        sessionID: sessionID,
                        requestID: requestID,
                        executablePath: "/bin/sleep",
                        arguments: ["30"]
                    ),
                    durableLaunch: Phase2DurableShellBrokerLaunchRequest(
                        brokerIncarnationID: brokerID,
                        sessionID: sessionID,
                        capabilityID: capabilityID,
                        requestID: requestID,
                        executablePath: "/bin/sleep",
                        arguments: ["30"],
                        workingDirectoryPath: nil,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(60)
                    ),
                    capabilitySecretBytes: secretBytes
                )
            )
        )
        let requestData = try Phase2ShellBrokerWireCodec.encodeCommandRequest(wireRequest)
        let responseBox = RegistryDataBox()

        DispatchQueue.global().async {
            principal.performCommand(requestData) { data in
                responseBox.set(data)
                responseFinished.signal()
            }
        }
        XCTAssertEqual(publishReached.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            principal.invalidate()
            invalidationFinished.signal()
        }
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 0.05), .timedOut)
        allowPublish.signal()
        XCTAssertEqual(responseFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(invalidationFinished.wait(timeout: .now() + 5), .success)

        let response = try Phase2ShellBrokerWireCodec.decodeCommandResponse(responseBox.get())
        let pid = try XCTUnwrap(response.processIdentifier)
        let authentication = try self.authentication(
            brokerID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID
        )
        defer {
            if processExists(pid) {
                _ = try? registry.cleanup(authentication: authentication, now: now.addingTimeInterval(1))
            }
        }
        XCTAssertEqual(response.status, .accepted)
        XCTAssertTrue(processExists(pid))
        let proof = try registry.cleanup(authentication: authentication, now: now.addingTimeInterval(1))
        XCTAssertTrue(proof.observedProcessAbsent)
    }

    func testDurableRegistrationTransferPreventsOrdinaryPollFromConsumingPTYOutput() throws {
        let brokerID = UUID()
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            startExpirySweeper: false
        )
        let principal = Phase2ShellBrokerPrincipal(durableRegistry: registry)
        let sessionID = UUID()
        let requestID = UUID()
        let capabilityID = UUID()
        let now = Date()
        let marker = "MACSCOPE_TRANSFER_OWNERSHIP_MARKER"
        let publishReached = DispatchSemaphore(value: 0)
        let allowPublish = DispatchSemaphore(value: 0)
        let responseFinished = DispatchSemaphore(value: 0)
        let responseBox = RegistryDataBox()
        let pollStarted = DispatchSemaphore(value: 0)
        let pollFinished = DispatchSemaphore(value: 0)
        let pollBox = RegistryDataBox()
        registry.registrationWillPublish = {
            publishReached.signal()
            allowPublish.wait()
        }
        // Always release the launch if an earlier assertion or decode fails.
        defer {
            allowPublish.signal()
            principal.invalidate()
            registry.cleanupAllForTesting()
        }
        let wireRequest = Phase2ShellBrokerCommandRequest(
            commandID: UUID(),
            command: .launchDurableProcess,
            payload: try Phase2ShellBrokerWireCodec.encodeLaunchDurableProcessRequest(
                Phase2ShellBrokerLaunchDurableProcessRequest(
                    launch: Phase2ShellBrokerLaunchProcessRequest(
                        sessionID: sessionID,
                        requestID: requestID,
                        executablePath: "/bin/sh",
                        arguments: ["-c", "printf \(marker); sleep 30"]
                    ),
                    durableLaunch: Phase2DurableShellBrokerLaunchRequest(
                        brokerIncarnationID: brokerID,
                        sessionID: sessionID,
                        capabilityID: capabilityID,
                        requestID: requestID,
                        executablePath: "/bin/sh",
                        arguments: ["-c", "printf \(marker); sleep 30"],
                        workingDirectoryPath: nil,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(60)
                    ),
                    capabilitySecretBytes: secretBytes
                )
            )
        )
        let requestData = try Phase2ShellBrokerWireCodec.encodeCommandRequest(wireRequest)

        DispatchQueue.global().async {
            principal.performCommand(requestData) { data in
                responseBox.set(data)
                responseFinished.signal()
            }
        }
        guard publishReached.wait(timeout: .now() + 5) == .success else {
            XCTFail("durable launch did not reach the publication barrier")
            return
        }

        let pollData = try Phase2ShellBrokerWireCodec.encodeCommandRequest(.init(
            commandID: UUID(),
            command: .pollTranscript,
            payload: Phase2ShellBrokerWireCodec.encodePollTranscriptRequest(
                Phase2ShellBrokerPollTranscriptRequest(
                    sessionID: sessionID,
                    requestID: requestID,
                    afterSequence: 0,
                    maximumEvents: 32,
                    maximumBytes: 4_096,
                    timeoutMilliseconds: 500
                )
            )
        ))
        // Commands on one principal are serialized. Poll concurrently: a synchronous poll
        // here deadlocks until a timed publication hook expires, then legitimately returns
        // the registry's output. Returned output alone is not evidence of a competing reader.
        DispatchQueue.global().async {
            pollStarted.signal()
            principal.performCommand(pollData) { data in
                pollBox.set(data)
                pollFinished.signal()
            }
        }
        XCTAssertEqual(pollStarted.wait(timeout: .now() + 5), .success)
        XCTAssertThrowsError(try registry.transcriptSnapshot(
            sessionID: sessionID,
            afterSequence: 0,
            maximumEvents: 32,
            maximumBytes: 4_096
        )) { error in
            XCTAssertEqual(error as? Phase2DurableShellBrokerRegistry.RegistryError, .sessionNotFound)
        }

        allowPublish.signal()
        XCTAssertEqual(responseFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(pollFinished.wait(timeout: .now() + 5), .success)
        let response = try Phase2ShellBrokerWireCodec.decodeCommandResponse(responseBox.get())
        XCTAssertEqual(response.status, .accepted)
        let poll = try Phase2ShellBrokerWireCodec.decodeCommandResponse(pollBox.get())
        XCTAssertEqual(poll.status, .accepted)

        let deadline = Date().addingTimeInterval(2)
        var snapshot = try registry.transcriptSnapshot(
            sessionID: sessionID,
            afterSequence: 0,
            maximumEvents: 32,
            maximumBytes: 4_096
        )
        while !snapshot.events.contains(where: {
            if case .output(_, let bytes) = $0.payload {
                return String(decoding: bytes, as: UTF8.self).contains(marker)
            }
            return false
        }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            snapshot = try registry.transcriptSnapshot(
                sessionID: sessionID,
                afterSequence: 0,
                maximumEvents: 32,
                maximumBytes: 4_096
            )
        }
        XCTAssertTrue(snapshot.events.contains(where: {
            if case .output(_, let bytes) = $0.payload {
                return String(decoding: bytes, as: UTF8.self).contains(marker)
            }
            return false
        }), "registry drain must retain the output emitted during ownership transfer")
        let retainedEvents = snapshot.events.map(Phase2ShellBrokerTranscriptEventWire.init(event:))
        XCTAssertTrue(poll.transcriptEvents.allSatisfy { retainedEvents.contains($0) },
                      "ordinary polling may only return output retained by the durable owner")
    }

    func testMaximumLifetimeIsCappedAndDetachedGraceIsSwept() throws {
        let fixture = try makeRegisteredFixture(
            requestedLifetime: Phase2DurableShellBrokerRegistry.maximumDurableLifetime * 2,
            maximumLifetime: 60,
            detachedGrace: 5
        )
        defer { fixture.registry.cleanupAllForTesting() }
        let authentication = try authentication(
            brokerID: fixture.brokerID,
            sessionID: fixture.sessionID,
            capabilityID: fixture.capabilityID
        )
        let status = try fixture.registry.status(
            authentication: authentication,
            clientID: fixture.clientID,
            now: fixture.now
        )
        XCTAssertEqual(status.identity.expiresAt, fixture.now.addingTimeInterval(60))

        _ = try fixture.registry.detach(
            authentication: authentication,
            clientID: fixture.clientID,
            now: fixture.now
        )
        XCTAssertEqual(fixture.registry.cleanupExpired(now: fixture.now.addingTimeInterval(4)).count, 0)
        let proofs = fixture.registry.cleanupExpired(now: fixture.now.addingTimeInterval(5))
        XCTAssertEqual(proofs.count, 1)
        XCTAssertTrue(proofs[0].observedProcessAbsent)
    }

    func testFutureClientTimestampCannotMoveMaximumLifetimeWindow() throws {
        let brokerID = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = UUID()
        let requestID = UUID()
        let lease = try Phase2ShellBrokerProcessAdapter().launch(Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            initialSize: .defaultInteractive
        ))
        defer { _ = lease.cleanup(timeout: 1) }
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            maximumDurableLifetime: 60,
            startExpirySweeper: false
        )
        let futureCreatedAt = now.addingTimeInterval(365 * 24 * 60 * 60)

        XCTAssertThrowsError(try registry.register(
            launchRequest: Phase2DurableShellBrokerLaunchRequest(
                brokerIncarnationID: brokerID,
                sessionID: sessionID,
                capabilityID: UUID(),
                requestID: requestID,
                executablePath: "/bin/sleep",
                arguments: ["30"],
                workingDirectoryPath: nil,
                createdAt: futureCreatedAt,
                expiresAt: futureCreatedAt.addingTimeInterval(30)
            ),
            capabilitySecretBytes: secretBytes,
            lease: lease,
            clientID: UUID(),
            now: now
        )) { error in
            XCTAssertEqual(error as? Phase2DurableShellBrokerRegistry.RegistryError, .invalidLaunchRequest)
        }
    }

    func testRegistrationPublishesTransferredTranscriptCursor() throws {
        let brokerID = UUID()
        let sessionID = UUID()
        let requestID = UUID()
        let now = Date()
        let lease = try Phase2ShellBrokerProcessAdapter().launch(Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            initialSize: .defaultInteractive
        ))
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            startExpirySweeper: false
        )
        defer { registry.cleanupAllForTesting() }
        let initialEvent = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 7,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [0x41])
        )

        let identity = try registry.register(
            launchRequest: Phase2DurableShellBrokerLaunchRequest(
                brokerIncarnationID: brokerID,
                sessionID: sessionID,
                capabilityID: UUID(),
                requestID: requestID,
                executablePath: "/bin/sleep",
                arguments: ["30"],
                workingDirectoryPath: nil,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            capabilitySecretBytes: secretBytes,
            lease: lease,
            clientID: UUID(),
            initialTranscriptEvents: [initialEvent],
            nextTranscriptSequence: 8,
            now: now
        )

        XCTAssertEqual(identity.nextTranscriptSequence, 8)
        XCTAssertEqual(
            try registry.transcriptSnapshot(
                sessionID: sessionID,
                afterSequence: 0,
                maximumEvents: 8,
                maximumBytes: 1_024
            ).nextSequence,
            8
        )
    }

    func testRegistryRejectsCapabilityIdentifierSharedByDifferentLiveSessions() throws {
        let brokerID = UUID()
        let capabilityID = UUID()
        let now = Date()
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            startExpirySweeper: false
        )
        let first = try makeRegistryLease(command: "sleep 30")
        let second = try makeRegistryLease(command: "sleep 30")
        defer {
            registry.cleanupAllForTesting()
            _ = second.lease.cleanup(timeout: 1)
        }
        _ = try registry.register(
            launchRequest: Phase2DurableShellBrokerLaunchRequest(
                brokerIncarnationID: brokerID,
                sessionID: first.sessionID,
                capabilityID: capabilityID,
                requestID: first.requestID,
                executablePath: "/bin/sh",
                arguments: ["-c", first.command],
                workingDirectoryPath: nil,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            capabilitySecretBytes: secretBytes,
            lease: first.lease,
            clientID: UUID(),
            now: now
        )

        XCTAssertThrowsError(try registry.register(
            launchRequest: Phase2DurableShellBrokerLaunchRequest(
                brokerIncarnationID: brokerID,
                sessionID: second.sessionID,
                capabilityID: capabilityID,
                requestID: second.requestID,
                executablePath: "/bin/sh",
                arguments: ["-c", second.command],
                workingDirectoryPath: nil,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            capabilitySecretBytes: secretBytes,
            lease: second.lease,
            clientID: UUID(),
            now: now
        )) { error in
            XCTAssertEqual(error as? Phase2DurableShellBrokerRegistry.RegistryError, .duplicateCapability)
        }
    }

    func testHeartbeatRenewsAttachmentBeforeDetachedGraceBegins() throws {
        let brokerID = UUID()
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            heartbeatTimeout: 300,
            detachedGrace: 120,
            startExpirySweeper: false
        )
        let fixture = try makeRegisteredFixture(
            registry: registry,
            requestedLifetime: 3_600
        )
        defer { registry.cleanupAllForTesting() }
        let authentication = try self.authentication(
            brokerID: fixture.brokerID,
            sessionID: fixture.sessionID,
            capabilityID: fixture.capabilityID
        )

        _ = try registry.heartbeat(
            authentication: authentication,
            clientID: fixture.clientID,
            now: fixture.now.addingTimeInterval(290)
        )
        XCTAssertEqual(registry.cleanupExpired(now: fixture.now.addingTimeInterval(301)).count, 0)
        XCTAssertTrue(try registry.status(
            authentication: authentication,
            clientID: fixture.clientID,
            now: fixture.now.addingTimeInterval(301)
        ).clientAttached)

        XCTAssertEqual(registry.cleanupExpired(now: fixture.now.addingTimeInterval(590)).count, 0)
        XCTAssertFalse(try registry.status(
            authentication: authentication,
            clientID: fixture.clientID,
            now: fixture.now.addingTimeInterval(590)
        ).clientAttached)
        XCTAssertEqual(registry.cleanupExpired(now: fixture.now.addingTimeInterval(709)).count, 0)
        let proofs = registry.cleanupExpired(now: fixture.now.addingTimeInterval(710))
        XCTAssertEqual(proofs.count, 1)
        XCTAssertTrue(proofs[0].observedProcessAbsent)
    }

    func testProcessExitDuringObservationRejectsRegistrationAndCannotPublishReusedPID() throws {
        let sessionID = UUID()
        let requestID = UUID()
        let lease = try Phase2ShellBrokerProcessAdapter().launch(Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            initialSize: .defaultInteractive
        ))
        let observer = RegistryIdentityObserver { pid, path in
            _ = lease.cleanup(outcome: .canceled, timeout: 1.0)
            return Phase2DurableShellBrokerProcessIdentity(
                processIdentifier: pid,
                processStartTimeUnixNanoseconds: 1,
                executablePath: path,
                processGroupIdentifier: pid
            )
        }
        let brokerID = UUID()
        let now = Date()
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            processIdentityObserver: observer,
            startExpirySweeper: false
        )

        XCTAssertThrowsError(try registry.register(
            launchRequest: Phase2DurableShellBrokerLaunchRequest(
                brokerIncarnationID: brokerID,
                sessionID: sessionID,
                capabilityID: UUID(),
                requestID: requestID,
                executablePath: "/bin/sleep",
                arguments: ["30"],
                workingDirectoryPath: nil,
                createdAt: now,
                expiresAt: now.addingTimeInterval(60)
            ),
            capabilitySecretBytes: secretBytes,
            lease: lease,
            clientID: UUID(),
            now: now
        )) { error in
            XCTAssertEqual(error as? Phase2DurableShellBrokerRegistry.RegistryError, .processIdentityUnavailable)
        }
        XCTAssertFalse(processExists(lease.ownedProcess.processIdentifier))
    }

    func testDurableAuthenticationFailuresAreWireIdentical() throws {
        let brokerID = UUID()
        let registry = Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            startExpirySweeper: false
        )
        let fixture = try makeRegisteredFixture(registry: registry, requestedLifetime: 0.05)
        defer { registry.cleanupAllForTesting() }
        let expiresAt = fixture.now.addingTimeInterval(0.05)
        while Date() < expiresAt {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertGreaterThanOrEqual(Date(), expiresAt)
        let commandID = UUID()
        let variants = [
            Phase2ShellBrokerDurableAuthenticationWire(
                brokerIncarnationID: brokerID,
                sessionID: UUID(),
                capabilityID: fixture.capabilityID,
                capabilitySecretBytes: secretBytes
            ),
            Phase2ShellBrokerDurableAuthenticationWire(
                brokerIncarnationID: UUID(),
                sessionID: fixture.sessionID,
                capabilityID: fixture.capabilityID,
                capabilitySecretBytes: secretBytes
            ),
            Phase2ShellBrokerDurableAuthenticationWire(
                brokerIncarnationID: brokerID,
                sessionID: fixture.sessionID,
                capabilityID: fixture.capabilityID,
                capabilitySecretBytes: Array(repeating: 0x99, count: 32)
            ),
            Phase2ShellBrokerDurableAuthenticationWire(
                brokerIncarnationID: brokerID,
                sessionID: fixture.sessionID,
                capabilityID: fixture.capabilityID,
                capabilitySecretBytes: [1]
            ),
            Phase2ShellBrokerDurableAuthenticationWire(
                brokerIncarnationID: brokerID,
                sessionID: fixture.sessionID,
                capabilityID: fixture.capabilityID,
                capabilitySecretBytes: secretBytes
            ),
        ]
        let responses = try variants.map { wire in
            try commandResponse(
                from: Phase2ShellBrokerPrincipal(durableRegistry: registry),
                commandID: commandID,
                command: .durableSessionStatus,
                payload: Phase2ShellBrokerWireCodec.encodeDurableSessionRequest(
                    Phase2ShellBrokerDurableSessionRequest(authentication: wire)
                )
            )
        }

        XCTAssertTrue(responses.dropFirst().allSatisfy { $0 == responses[0] })
        XCTAssertEqual(responses[0].status, .rejected)
        XCTAssertNil(responses[0].sessionID)
        XCTAssertEqual(responses[0].issues, ["durableAuthenticationRejected"])
    }
    func testSharedRegistryLetsSecondPrincipalAttachAfterFirstConnectionInvalidates() throws {
        let brokerID = UUID()
        let registry = Phase2DurableShellBrokerRegistry(brokerIncarnationID: brokerID)
        let first = Phase2ShellBrokerPrincipal(durableRegistry: registry, clientID: UUID())
        let second = Phase2ShellBrokerPrincipal(durableRegistry: registry, clientID: UUID())
        let sessionID = UUID()
        let requestID = UUID()
        let capabilityID = UUID()
        let secretBytes = Array(repeating: UInt8(0x47), count: 32)
        let now = Date()
        let launch = Phase2ShellBrokerLaunchProcessRequest(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"]
        )
        let durableLaunch = Phase2DurableShellBrokerLaunchRequest(
            brokerIncarnationID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            workingDirectoryPath: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let launchResponse = try commandResponse(
            from: first,
            command: .launchDurableProcess,
            payload: Phase2ShellBrokerWireCodec.encodeLaunchDurableProcessRequest(
                Phase2ShellBrokerLaunchDurableProcessRequest(
                    launch: launch,
                    durableLaunch: durableLaunch,
                    capabilitySecretBytes: secretBytes
                )
            )
        )
        let pid = try XCTUnwrap(launchResponse.processIdentifier)
        let authenticationWire = Phase2ShellBrokerDurableAuthenticationWire(
            brokerIncarnationID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID,
            capabilitySecretBytes: secretBytes
        )
        let authentication = try authenticationWire.makeAuthenticationRequest()
        defer {
            if processExists(pid) {
                _ = try? registry.cleanup(authentication: authentication, now: now.addingTimeInterval(5))
            }
        }

        XCTAssertEqual(launchResponse.status, .accepted)
        XCTAssertEqual(launchResponse.durableIdentity?.sessionID, sessionID)
        first.invalidate()
        XCTAssertTrue(processExists(pid), "durable registry, not the invalidated connection, must retain the lease")

        let attachResponse = try commandResponse(
            from: second,
            command: .attachDurableSession,
            payload: Phase2ShellBrokerWireCodec.encodeDurableSessionRequest(
                Phase2ShellBrokerDurableSessionRequest(authentication: authenticationWire)
            )
        )
        XCTAssertEqual(attachResponse.status, .accepted)
        XCTAssertEqual(attachResponse.processIdentifier, pid)
        XCTAssertEqual(attachResponse.durableClientAttached, true)

        let proof = try registry.cleanup(authentication: authentication, now: now.addingTimeInterval(5))
        XCTAssertTrue(proof.observedProcessAbsent)
        XCTAssertFalse(processExists(pid))
    }

    func testDurableLeaseSurvivesFirstClientDetachAndAuthenticatesSecondClient() throws {
        let brokerID = UUID()
        let sessionID = UUID()
        let requestID = UUID()
        let capabilityID = UUID()
        let firstClientID = UUID()
        let secondClientID = UUID()
        let secretBytes = self.secretBytes
        let now = Date()
        let plan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            initialSize: .defaultInteractive
        )
        let lease = try Phase2ShellBrokerProcessAdapter().launch(plan)
        let registry = Phase2DurableShellBrokerRegistry(brokerIncarnationID: brokerID)
        var needsDirectCleanup = true
        defer {
            if needsDirectCleanup {
                _ = lease.cleanup(outcome: .canceled, timeout: 1.0)
            }
        }
        let launch = Phase2DurableShellBrokerLaunchRequest(
            brokerIncarnationID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            workingDirectoryPath: nil,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )

        let identity = try registry.register(
            launchRequest: launch,
            capabilitySecretBytes: secretBytes,
            lease: lease,
            clientID: firstClientID,
            now: now
        )
        let authentication = try Phase2ShellBrokerDurableAuthenticationWire(
            brokerIncarnationID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID,
            capabilitySecretBytes: secretBytes
        ).makeAuthenticationRequest()

        registry.detachClient(firstClientID)
        XCTAssertTrue(lease.isRunning)
        XCTAssertFalse(try registry.status(
            authentication: authentication,
            clientID: firstClientID,
            now: now.addingTimeInterval(1)
        ).clientAttached)

        let attached = try registry.attach(
            authentication: authentication,
            clientID: secondClientID,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(attached.identity, identity)
        XCTAssertTrue(attached.lease.isRunning)
        XCTAssertTrue(try registry.status(
            authentication: authentication,
            clientID: secondClientID,
            now: now.addingTimeInterval(3)
        ).clientAttached)

        let proof = try registry.cleanup(authentication: authentication, now: now.addingTimeInterval(4))
        needsDirectCleanup = false
        XCTAssertEqual(proof.processIdentifier, lease.ownedProcess.processIdentifier)
        XCTAssertTrue(proof.observedProcessAbsent)
        XCTAssertFalse(processExists(proof.processIdentifier))
    }

    func testRegistryRejectsWrongCapabilityWithoutDisclosingStatus() throws {
        let fixture = try makeRegisteredFixture()
        defer { fixture.registry.cleanupAllForTesting() }
        let wrong = try Phase2ShellBrokerDurableAuthenticationWire(
            brokerIncarnationID: fixture.brokerID,
            sessionID: fixture.sessionID,
            capabilityID: fixture.capabilityID,
            capabilitySecretBytes: Array(repeating: 0x99, count: 32)
        ).makeAuthenticationRequest()

        XCTAssertThrowsError(try fixture.registry.status(
            authentication: wrong,
            clientID: UUID(),
            now: fixture.now.addingTimeInterval(1)
        )) { error in
            guard case Phase2DurableShellBrokerRegistry.RegistryError.authenticationFailed(let issues) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(issues, [.capabilityVerifierMismatch])
        }

        let expiredProofs = fixture.registry.cleanupExpired(now: fixture.now.addingTimeInterval(61))
        XCTAssertEqual(expiredProofs.count, 1)
        XCTAssertTrue(expiredProofs[0].observedProcessAbsent)
    }

    private var secretBytes: [UInt8] { Array(repeating: 0x35, count: 32) }

    private func authentication(
        brokerID: UUID,
        sessionID: UUID,
        capabilityID: UUID
    ) throws -> Phase2DurableShellBrokerAuthenticationRequest {
        try Phase2ShellBrokerDurableAuthenticationWire(
            brokerIncarnationID: brokerID,
            sessionID: sessionID,
            capabilityID: capabilityID,
            capabilitySecretBytes: secretBytes
        ).makeAuthenticationRequest()
    }

    private func makeRegisteredFixture(
        registry suppliedRegistry: Phase2DurableShellBrokerRegistry? = nil,
        requestedLifetime: TimeInterval = 60,
        maximumLifetime: TimeInterval = Phase2DurableShellBrokerRegistry.maximumDurableLifetime,
        detachedGrace: TimeInterval = Phase2DurableShellBrokerRegistry.detachedGrace
    ) throws -> (
        registry: Phase2DurableShellBrokerRegistry,
        brokerID: UUID,
        sessionID: UUID,
        capabilityID: UUID,
        clientID: UUID,
        now: Date
    ) {
        let brokerID = suppliedRegistry?.brokerIncarnationID ?? UUID()
        let sessionID = UUID()
        let requestID = UUID()
        let capabilityID = UUID()
        let now = Date()
        let lease = try Phase2ShellBrokerProcessAdapter().launch(Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sleep",
            arguments: ["30"],
            initialSize: .defaultInteractive
        ))
        let clientID = UUID()
        let registry = suppliedRegistry ?? Phase2DurableShellBrokerRegistry(
            brokerIncarnationID: brokerID,
            maximumDurableLifetime: maximumLifetime,
            detachedGrace: detachedGrace,
            startExpirySweeper: false
        )
        _ = try registry.register(
            launchRequest: Phase2DurableShellBrokerLaunchRequest(
                brokerIncarnationID: brokerID,
                sessionID: sessionID,
                capabilityID: capabilityID,
                requestID: requestID,
                executablePath: "/bin/sleep",
                arguments: ["30"],
                workingDirectoryPath: nil,
                createdAt: now,
                expiresAt: now.addingTimeInterval(requestedLifetime)
            ),
            capabilitySecretBytes: secretBytes,
            lease: lease,
            clientID: clientID,
            now: now
        )
        return (registry, brokerID, sessionID, capabilityID, clientID, now)
    }

    private func makeRegistryLease(command: String) throws -> (
        lease: Phase2ShellBrokerProcessLease,
        sessionID: UUID,
        requestID: UUID,
        command: String
    ) {
        let sessionID = UUID()
        let requestID = UUID()
        return (
            try Phase2ShellBrokerProcessAdapter().launch(Phase2HumanPTYLaunchPlan(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/sh",
                arguments: ["-c", command],
                initialSize: .defaultInteractive
            )),
            sessionID,
            requestID,
            command
        )
    }

    private func processExists(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func commandResponse(
        from principal: Phase2ShellBrokerPrincipal,
        commandID: UUID = UUID(),
        command: Phase2ShellBrokerCommandKind,
        payload: Data
    ) throws -> Phase2ShellBrokerCommandResponse {
        let request = Phase2ShellBrokerCommandRequest(commandID: commandID, command: command, payload: payload)
        let requestData = try Phase2ShellBrokerWireCodec.encodeCommandRequest(request)
        let semaphore = DispatchSemaphore(value: 0)
        var responseData = Data()
        principal.performCommand(requestData) { data in
            responseData = data
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 5), .success)
        return try Phase2ShellBrokerWireCodec.decodeCommandResponse(responseData)
    }
}

private struct RegistryIdentityObserver: Phase2DurableShellBrokerProcessIdentityObserving, @unchecked Sendable {
    let body: (Int32, String) -> Phase2DurableShellBrokerProcessIdentity?

    func observe(
        processIdentifier: Int32,
        expectedExecutablePath: String
    ) -> Phase2DurableShellBrokerProcessIdentity? {
        body(processIdentifier, expectedExecutablePath)
    }
}

private final class RegistryDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
