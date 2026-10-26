import Foundation
import XCTest
@testable import MacScope

final class Phase2DurableShellSessionCoordinatorTests: XCTestCase {
    func testV4RoundTripPersistsOnlyPublicRecoveryIdentityAndMutableCursor() throws {
        let identity = try makeIdentity()
        let package = makePackage(identity: identity, nextSequence: 9)

        let data = try JSONEncoder().encode(package)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("capabilitySecret"))
        XCTAssertFalse(text.contains("bindingID"))
        XCTAssertFalse(text.contains("terminalSurfaceID"))

        let decoded = try JSONDecoder().decode(WorkspacePackagePhase2ShellSession.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 4)
        XCTAssertEqual(decoded.nextTranscriptSequence, 9)
        XCTAssertEqual(decoded.durableBrokerIdentity?.phase2Identity, identity)
        XCTAssertTrue(decoded.restoredProjection.isDurableRecoveryPending)
    }

    func testTerminalSnapshotWithoutRecoveryIdentitySavesAfterProvenCleanup() throws {
        let identity = try makeIdentity()
        let running = runningSnapshot(identity: identity, transcriptSequence: 4)
        let stopped = Phase2HumanPTYSessionSnapshot(
            sessionID: running.sessionID, state: .terminal(outcome: .canceled),
            launchPlan: running.launchPlan, transcriptEvents: running.transcriptEvents, issues: [])
        let projection = Phase2WorkspaceShellSessionProjection(snapshot: stopped,
            inFlightCommand: nil, lastError: nil, lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil, durableRecoveryIdentity: nil)
        let package = try XCTUnwrap(projection.packagePhase2ShellSession)
        XCTAssertNil(package.durableBrokerIdentity)
        XCTAssertNil(package.runningRequestID)
        XCTAssertNil(package.runningProcessIdentifier)
        let decoded = try JSONDecoder().decode(WorkspacePackagePhase2ShellSession.self,
            from: JSONEncoder().encode(package))
        XCTAssertEqual(decoded, package)
        XCTAssertEqual(decoded.restoredProjection.snapshot?.transcriptEvents, stopped.transcriptEvents)
        XCTAssertEqual(decoded.restoredProjection.snapshot?.state, stopped.state)
        XCTAssertFalse(decoded.restoredProjection.isDurableRecoveryPending)
    }

    func testPendingRecoveryRoundTripPreservesOriginalProcessEnvelope() throws {
        let identity = try makeIdentity()
        let running = runningSnapshot(identity: identity, transcriptSequence: 4)
        let pending = WorkspacePackagePhase2ShellSession(snapshot: running,
            durableBrokerIdentity: identity).restoredProjection
        XCTAssertTrue(pending.isDurableRecoveryPending)
        let saved = try XCTUnwrap(pending.packagePhase2ShellSession)
        XCTAssertEqual(saved.runningRequestID, identity.launchRequest.requestID)
        XCTAssertEqual(saved.runningProcessIdentifier, identity.processIdentity.processIdentifier)
        XCTAssertEqual(saved.durableBrokerIdentity?.phase2Identity, identity)
        let reopened = try JSONDecoder().decode(WorkspacePackagePhase2ShellSession.self,
            from: JSONEncoder().encode(saved)).restoredProjection
        XCTAssertEqual(reopened.durableRecoveryIdentity, identity)
        XCTAssertEqual(reopened.snapshot?.transcriptEvents, running.transcriptEvents)
        XCTAssertTrue(reopened.isDurableRecoveryPending)
    }

    func testSnapshotProducerRetainsOnlyMatchingRunningDurableIdentity() throws {
        let identity = try makeIdentity()
        let running = runningSnapshot(identity: identity, transcriptSequence: 4)
        let matching = WorkspacePackagePhase2ShellSession(snapshot: running, durableBrokerIdentity: identity)
        XCTAssertEqual(matching.durableBrokerIdentity?.phase2Identity, identity)
        XCTAssertEqual(try JSONDecoder().decode(WorkspacePackagePhase2ShellSession.self,
            from: JSONEncoder().encode(matching)), matching)
        let replacements = [
            Phase2HumanPTYSessionSnapshot(sessionID: UUID(), state: running.state,
                launchPlan: nil, transcriptEvents: [], issues: []),
            Phase2HumanPTYSessionSnapshot(sessionID: identity.sessionID,
                state: .running(requestID: UUID(), processIdentifier: identity.processIdentity.processIdentifier),
                launchPlan: nil, transcriptEvents: [], issues: []),
            Phase2HumanPTYSessionSnapshot(sessionID: identity.sessionID,
                state: .running(requestID: identity.launchRequest.requestID, processIdentifier: 902),
                launchPlan: nil, transcriptEvents: [], issues: [])
        ]
        for replacement in replacements {
            let mismatched = WorkspacePackagePhase2ShellSession(snapshot: replacement, durableBrokerIdentity: identity)
            XCTAssertNil(mismatched.durableBrokerIdentity)
            XCTAssertEqual(try JSONDecoder().decode(WorkspacePackagePhase2ShellSession.self,
                from: JSONEncoder().encode(mismatched)), mismatched)
        }
    }

    func testV3DecodeIgnoresInjectedRecoveryIdentityAndRestoresInactive() throws {
        let package = makePackage(identity: try makeIdentity(), nextSequence: 9)
        let encoded = try JSONEncoder().encode(package)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["schemaVersion"] = 3
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WorkspacePackagePhase2ShellSession.self, from: legacy)
        XCTAssertNil(decoded.durableBrokerIdentity)
        XCTAssertTrue(decoded.restoredProjection.isRestoredInactiveContext)
    }

    func testExpiredRecoveryFailsClosedWithoutCallingAttach() async throws {
        let identity = try makeIdentity(expiresAt: Date(timeIntervalSince1970: 200))
        let projection = makePackage(identity: identity, nextSequence: 9).restoredProjection
        let calls = RecoveryCallCounter()
        let result = await Phase2DurableShellSessionCoordinator(
            now: { Date(timeIntervalSince1970: 201) }
        ).recover(projection) { _, _ in
            await calls.increment()
            throw TestFailure.expected
        }

        XCTAssertEqual(result.issue, .expiredRecoveryIdentity)
        XCTAssertTrue(result.projection.isRestoredInactiveContext)
        XCTAssertNil(result.projection.durableRecoveryIdentity)
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testRecoveryAcceptsOnlyMatchingBrokerConfirmedAttachment() async throws {
        let identity = try makeIdentity()
        let package = makePackage(identity: identity, nextSequence: 9)
        let projection = package.restoredProjection
        let snapshot = runningSnapshot(identity: identity, transcriptSequence: 9)
        let response = MacScope.Phase2ShellBrokerCommandResponse(
            commandID: UUID(),
            command: .attachDurableSession,
            status: .accepted,
            sessionID: identity.sessionID,
            requestID: identity.launchRequest.requestID,
            lifecycleState: "running",
            processIdentifier: identity.processIdentity.processIdentifier,
            nextTranscriptSequence: 10,
            durableIdentity: identity,
            durableClientAttached: true
        )

        let result = await Phase2DurableShellSessionCoordinator(
            now: { Date(timeIntervalSince1970: 150) }
        ).recover(projection) { _, _ in
            Phase2HumanPTYShellSessionCommandOutcome(snapshot: snapshot, brokerResponse: response)
        }

        XCTAssertTrue(result.recovered)
        XCTAssertEqual(result.projection.durableRecoveryIdentity, identity)
    }

    func testProvisionalCommitOrdersCapabilityLedgerThenBroker() async throws {
        let identity = try makeIdentity()
        let journal = RecoveryJournal()
        let outcome = provisionalOutcome(identity: identity)
        let result = await Phase2DurableShellSessionCoordinator().commitProvisionalLaunch(
            previousProjection: .inactive,
            provisionalOutcome: outcome,
            persistCapability: { _ in await journal.record("capability") },
            persistPublicLedger: { _ in await journal.record("ledger") },
            commitBrokerSession: { _ in await journal.record("commit") },
            discardCapability: { _ in await journal.record("discard") },
            cleanupProvisionalBrokerSession: { _ in await journal.record("cleanup") }
        )

        XCTAssertTrue(result.committed)
        let entries = await journal.entries
        XCTAssertEqual(entries, ["capability", "ledger", "commit"])
    }

    func testAmbiguousCommitFailureRetainsRecoveryLedgerAndDoesNotCleanup() async throws {
        let identity = try makeIdentity()
        let journal = RecoveryJournal()
        let result = await Phase2DurableShellSessionCoordinator().commitProvisionalLaunch(
            previousProjection: .inactive,
            provisionalOutcome: provisionalOutcome(identity: identity),
            persistCapability: { _ in await journal.record("capability") },
            persistPublicLedger: { _ in await journal.record("ledger") },
            commitBrokerSession: { _ in
                await journal.record("commit")
                throw TestFailure.expected
            },
            discardCapability: { _ in await journal.record("discard") },
            cleanupProvisionalBrokerSession: { _ in await journal.record("cleanup") }
        )

        XCTAssertEqual(result.issue, .brokerCommitFailed)
        XCTAssertNotNil(result.projection.durableRecoveryIdentity)
        let entries = await journal.entries
        XCTAssertEqual(entries, ["capability", "ledger", "commit"])
    }

    func testTransactionFenceFailureAfterLedgerCompensatesBeforeCommit() async throws {
        let identity = try makeIdentity()
        let journal = RecoveryJournal()
        let validations = RecoveryCallCounter()
        let result = await Phase2DurableShellSessionCoordinator().commitProvisionalLaunch(
            previousProjection: .inactive,
            provisionalOutcome: provisionalOutcome(identity: identity),
            persistCapability: { _ in await journal.record("capability") },
            persistPublicLedger: { _ in await journal.record("ledger") },
            commitBrokerSession: { _ in await journal.record("commit") },
            validateTransaction: {
                await validations.increment()
                return await validations.value == 1
            },
            discardPublicLedger: {
                await journal.record("discardLedger")
                return .cleared
            },
            discardCapability: { _ in await journal.record("discardCapability") },
            cleanupProvisionalBrokerSession: { _ in await journal.record("cleanup") }
        )

        XCTAssertEqual(result.issue, .transactionSuperseded)
        XCTAssertEqual(result.publicLedgerRollbackOutcome, .cleared)
        let entries = await journal.entries
        XCTAssertEqual(entries, ["capability", "ledger", "cleanup", "discardLedger", "discardCapability"])
    }

    func testUnprovenPostPublicationRollbackRetainsCapabilityAndRecoveryProjection() async throws {
        let identity = try makeIdentity()
        let journal = RecoveryJournal()
        let validations = RecoveryCallCounter()
        let result = await Phase2DurableShellSessionCoordinator().commitProvisionalLaunch(
            previousProjection: .inactive,
            provisionalOutcome: provisionalOutcome(identity: identity),
            persistCapability: { _ in await journal.record("capability") },
            persistPublicLedger: { _ in await journal.record("ledger") },
            commitBrokerSession: { _ in await journal.record("commit") },
            validateTransaction: {
                await validations.increment()
                return await validations.value == 1
            },
            discardPublicLedger: {
                await journal.record("discardLedger")
                return .clearanceUnproven
            },
            discardCapability: { _ in await journal.record("discardCapability") },
            cleanupProvisionalBrokerSession: { _ in await journal.record("cleanup") }
        )

        XCTAssertEqual(result.issue, .transactionSuperseded)
        XCTAssertEqual(result.publicLedgerRollbackOutcome, .clearanceUnproven)
        XCTAssertEqual(result.projection.durableRecoveryIdentity, identity)
        let entries = await journal.entries
        XCTAssertEqual(entries, ["capability", "ledger", "cleanup", "discardLedger"])
    }

    func testDefinitiveBrokerAbsenceProducesDiscardableInactiveProjection() async throws {
        let identity = try makeIdentity()
        let projection = makePackage(identity: identity, nextSequence: 9).restoredProjection
        let result = await Phase2DurableShellSessionCoordinator(
            now: { Date(timeIntervalSince1970: 150) }
        ).recover(projection) { _, _ in
            throw Phase2HumanPTYShellSessionClientError.durableSessionAbsent
        }

        XCTAssertEqual(result.issue, .definitiveBrokerAbsence)
        XCTAssertNil(result.projection.durableRecoveryIdentity)
        XCTAssertTrue(result.projection.isRestoredInactiveContext)
    }
}

private enum TestFailure: Error { case expected }

private actor RecoveryCallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor RecoveryJournal {
    private(set) var entries: [String] = []
    func record(_ entry: String) { entries.append(entry) }
}

private func makeIdentity(
    expiresAt: Date = Date(timeIntervalSince1970: 300)
) throws -> Phase2DurableShellBrokerIdentity {
    let launch = Phase2DurableShellBrokerLaunchRequest(
        brokerIncarnationID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        capabilityID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        executablePath: "/bin/zsh",
        arguments: ["-l"],
        workingDirectoryPath: "/tmp",
        createdAt: Date(timeIntervalSince1970: 100),
        expiresAt: expiresAt
    )
    let process = Phase2DurableShellBrokerProcessIdentity(
        processIdentifier: 901,
        processStartTimeUnixNanoseconds: 123,
        executablePath: "/bin/zsh",
        processGroupIdentifier: 901
    )
    let secret = try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 7, count: 32))
    return Phase2DurableShellBrokerIdentity(
        launchRequest: launch,
        processIdentity: process,
        createdAt: Date(timeIntervalSince1970: 101),
        expiresAt: expiresAt,
        nextTranscriptSequence: 1,
        capabilityVerifierSHA256: secret.verifier(launchRequest: launch, processIdentity: process)
    )
}

private func makePackage(
    identity: Phase2DurableShellBrokerIdentity,
    nextSequence: UInt64
) -> WorkspacePackagePhase2ShellSession {
    WorkspacePackagePhase2ShellSession(
        sessionID: identity.sessionID,
        launchPlan: nil,
        terminalOutcome: .outcomeUnknown,
        transcriptEvents: [],
        terminalBackend: .ghosttyLib,
        ptyReusePolicy: .shellBrokerSession,
        debuggerAuthorityPolicy: .disabled,
        runningRequestID: identity.launchRequest.requestID,
        runningProcessIdentifier: identity.processIdentity.processIdentifier,
        nextTranscriptSequence: nextSequence,
        durableBrokerIdentity: .init(identity)
    )
}

private func runningSnapshot(
    identity: Phase2DurableShellBrokerIdentity,
    transcriptSequence: UInt64
) -> Phase2HumanPTYSessionSnapshot {
    let events = (1..<transcriptSequence).map { sequence in
        Phase2HumanPTYTranscriptEvent(
            sessionID: identity.sessionID,
            sequence: sequence,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [65])
        )
    }
    return Phase2HumanPTYSessionSnapshot(
        sessionID: identity.sessionID,
        state: .running(
            requestID: identity.launchRequest.requestID,
            processIdentifier: identity.processIdentity.processIdentifier
        ),
        launchPlan: nil,
        transcriptEvents: events,
        issues: []
    )
}

private func provisionalOutcome(
    identity: Phase2DurableShellBrokerIdentity
) -> Phase2HumanPTYShellSessionCommandOutcome {
    Phase2HumanPTYShellSessionCommandOutcome(
        snapshot: runningSnapshot(identity: identity, transcriptSequence: 1),
        brokerResponse: MacScope.Phase2ShellBrokerCommandResponse(
            commandID: UUID(),
            command: .launchProcess,
            status: .accepted,
            sessionID: identity.sessionID,
            requestID: identity.launchRequest.requestID,
            lifecycleState: "provisional",
            processIdentifier: identity.processIdentity.processIdentifier,
            nextTranscriptSequence: 1,
            durableIdentity: identity,
            durableClientAttached: true
        )
    )
}
