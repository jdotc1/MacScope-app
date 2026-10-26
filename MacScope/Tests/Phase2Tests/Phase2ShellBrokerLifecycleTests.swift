import XCTest
@testable import MacScope

final class Phase2ShellBrokerLifecycleTests: XCTestCase {
    func testLifecycleRequiresPrepareRunningCleanupAndAbsenceProof() {
        let sessionID = lifecycleUUID(1)
        let requestID = lifecycleUUID(2)
        let plan = launchPlan(sessionID: sessionID, requestID: requestID)
        let process = ownedProcess(sessionID: sessionID, requestID: requestID, processIdentifier: 2_001)
        let proof = cleanupProof(sessionID: sessionID, requestID: requestID, processIdentifier: 2_001)

        var snapshot = Phase2ShellBrokerLifecycleSnapshot.initial(sessionID: sessionID)
        snapshot = Phase2ShellBrokerLifecycleReducer.prepareLaunch(snapshot, plan: plan)
        snapshot = Phase2ShellBrokerLifecycleReducer.publishRunningProcess(snapshot, process: process)
        snapshot = Phase2ShellBrokerLifecycleReducer.requestCleanup(snapshot, reason: .userCancel)
        snapshot = Phase2ShellBrokerLifecycleReducer.completeCleanup(snapshot, proof: proof)

        XCTAssertEqual(snapshot.state, .cleanedUp(
            requestID: requestID,
            processIdentifier: 2_001,
            outcome: .canceled
        ))
        XCTAssertEqual(snapshot.launchPlan, plan)
        XCTAssertEqual(snapshot.ownedProcess, process)
        XCTAssertEqual(snapshot.cleanupProof, proof)
        XCTAssertEqual(snapshot.issues, [])
    }

    func testPrepareRejectsInvalidPlanAndWrongSessionWithoutMutatingState() {
        let sessionID = lifecycleUUID(3)
        let wrongSessionID = lifecycleUUID(4)
        var snapshot = Phase2ShellBrokerLifecycleSnapshot.initial(sessionID: sessionID)

        snapshot = Phase2ShellBrokerLifecycleReducer.prepareLaunch(
            snapshot,
            plan: launchPlan(sessionID: wrongSessionID, requestID: lifecycleUUID(5))
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.prepareLaunch(
            snapshot,
            plan: launchPlan(sessionID: sessionID, requestID: lifecycleUUID(6), executablePath: "zsh")
        )

        XCTAssertEqual(snapshot.state, .idle)
        XCTAssertEqual(snapshot.launchPlan, nil)
        XCTAssertEqual(snapshot.issues, [
            .sessionMismatch(expected: sessionID, actual: wrongSessionID),
            .invalidLaunchPlan([.executablePathNotAbsolute("zsh")]),
        ])
    }

    func testRunningProcessMustMatchPreparedRequestSessionPathAndPositivePID() {
        let sessionID = lifecycleUUID(7)
        let requestID = lifecycleUUID(8)
        let otherRequestID = lifecycleUUID(9)
        var snapshot = preparedSnapshot(sessionID: sessionID, requestID: requestID)

        snapshot = Phase2ShellBrokerLifecycleReducer.publishRunningProcess(
            snapshot,
            process: ownedProcess(sessionID: lifecycleUUID(10), requestID: requestID, processIdentifier: 1)
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.publishRunningProcess(
            snapshot,
            process: ownedProcess(sessionID: sessionID, requestID: otherRequestID, processIdentifier: 1)
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.publishRunningProcess(
            snapshot,
            process: ownedProcess(sessionID: sessionID, requestID: requestID, processIdentifier: 0)
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.publishRunningProcess(
            snapshot,
            process: ownedProcess(
                sessionID: sessionID,
                requestID: requestID,
                processIdentifier: 2,
                executablePath: "/usr/bin/env"
            )
        )

        XCTAssertEqual(snapshot.state, .prepared(requestID: requestID))
        XCTAssertEqual(snapshot.ownedProcess, nil)
        XCTAssertEqual(snapshot.issues, [
            .sessionMismatch(expected: sessionID, actual: lifecycleUUID(10)),
            .requestMismatch(expected: requestID, actual: otherRequestID),
            .invalidProcessIdentifier(0),
            .executablePathMismatch(expected: "/bin/zsh", actual: "/usr/bin/env"),
        ])
    }

    func testCleanupCannotCompleteWithoutExactPIDAndAbsenceProof() {
        let sessionID = lifecycleUUID(11)
        let requestID = lifecycleUUID(12)
        var snapshot = runningSnapshot(sessionID: sessionID, requestID: requestID, processIdentifier: 333)

        snapshot = Phase2ShellBrokerLifecycleReducer.completeCleanup(
            snapshot,
            proof: cleanupProof(sessionID: sessionID, requestID: requestID, processIdentifier: 333)
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.requestCleanup(snapshot, reason: .appShutdown)
        snapshot = Phase2ShellBrokerLifecycleReducer.completeCleanup(
            snapshot,
            proof: cleanupProof(sessionID: sessionID, requestID: requestID, processIdentifier: 444)
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.completeCleanup(
            snapshot,
            proof: cleanupProof(
                sessionID: sessionID,
                requestID: requestID,
                processIdentifier: 333,
                observedProcessAbsent: false
            )
        )

        XCTAssertEqual(snapshot.state, .cleanupRequested(
            requestID: requestID,
            processIdentifier: 333,
            reason: .appShutdown
        ))
        XCTAssertEqual(snapshot.cleanupProof, nil)
        XCTAssertEqual(snapshot.issues, [
            .transitionNotAllowed(
                state: .running(requestID: requestID, processIdentifier: 333),
                attempted: .completeCleanup
            ),
            .cleanupProcessMismatch(expected: 333, actual: 444),
            .cleanupMissingAbsenceProof(processIdentifier: 333),
        ])
    }

    func testTerminalStatesRejectFurtherMutation() {
        let sessionID = lifecycleUUID(13)
        let requestID = lifecycleUUID(14)
        var snapshot = preparedSnapshot(sessionID: sessionID, requestID: requestID)

        snapshot = Phase2ShellBrokerLifecycleReducer.rejectLaunch(
            snapshot,
            requestID: requestID,
            reason: "permission denied"
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.publishRunningProcess(
            snapshot,
            process: ownedProcess(sessionID: sessionID, requestID: requestID, processIdentifier: 55)
        )
        snapshot = Phase2ShellBrokerLifecycleReducer.requestCleanup(snapshot, reason: .launchFailure)

        XCTAssertEqual(snapshot.state, .launchRejected(requestID: requestID, reason: "permission denied"))
        XCTAssertEqual(snapshot.issues, [
            .transitionNotAllowed(
                state: .launchRejected(requestID: requestID, reason: "permission denied"),
                attempted: .publishRunningProcess
            ),
            .transitionNotAllowed(
                state: .launchRejected(requestID: requestID, reason: "permission denied"),
                attempted: .requestCleanup
            ),
        ])
    }
}

private func preparedSnapshot(
    sessionID: UUID,
    requestID: UUID
) -> Phase2ShellBrokerLifecycleSnapshot {
    Phase2ShellBrokerLifecycleReducer.prepareLaunch(
        .initial(sessionID: sessionID),
        plan: launchPlan(sessionID: sessionID, requestID: requestID)
    )
}

private func runningSnapshot(
    sessionID: UUID,
    requestID: UUID,
    processIdentifier: Int32
) -> Phase2ShellBrokerLifecycleSnapshot {
    Phase2ShellBrokerLifecycleReducer.publishRunningProcess(
        preparedSnapshot(sessionID: sessionID, requestID: requestID),
        process: ownedProcess(
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: processIdentifier
        )
    )
}

private func launchPlan(
    sessionID: UUID,
    requestID: UUID,
    executablePath: String = "/bin/zsh"
) -> Phase2HumanPTYLaunchPlan {
    Phase2HumanPTYLaunchPlan(
        sessionID: sessionID,
        requestID: requestID,
        executablePath: executablePath,
        workingDirectoryPath: "/tmp",
        initialSize: .defaultInteractive
    )
}

private func ownedProcess(
    sessionID: UUID,
    requestID: UUID,
    processIdentifier: Int32,
    executablePath: String = "/bin/zsh"
) -> Phase2ShellBrokerOwnedProcess {
    Phase2ShellBrokerOwnedProcess(
        sessionID: sessionID,
        requestID: requestID,
        processIdentifier: processIdentifier,
        executablePath: executablePath
    )
}

private func cleanupProof(
    sessionID: UUID,
    requestID: UUID,
    processIdentifier: Int32,
    observedProcessAbsent: Bool = true,
    outcome: Phase2HumanPTYTerminalOutcome = .canceled
) -> Phase2ShellBrokerCleanupProof {
    Phase2ShellBrokerCleanupProof(
        sessionID: sessionID,
        requestID: requestID,
        processIdentifier: processIdentifier,
        observedProcessAbsent: observedProcessAbsent,
        outcome: outcome
    )
}

private func lifecycleUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "21000000-0000-0000-0000-%012llx", value))!
}
