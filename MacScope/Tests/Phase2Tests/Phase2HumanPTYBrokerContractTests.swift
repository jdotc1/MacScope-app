import XCTest
@testable import MacScope

final class Phase2HumanPTYBrokerContractTests: XCTestCase {
    func testLaunchPlanAcceptsExplicitAbsoluteExecutableAndBoundedTerminalContract() {
        let plan = launchPlan(
            executablePath: "/bin/zsh",
            arguments: ["-l"],
            environment: ["TERM": "xterm-256color"],
            workingDirectoryPath: "/Users/test/project"
        )

        let result = Phase2HumanPTYLaunchPlanValidator.validate(plan)

        XCTAssertTrue(result.isAccepted)
    }

    func testLaunchPlanRejectsRelativePathsNULsInvalidEnvironmentAndInvalidLimits() {
        let plan = launchPlan(
            executablePath: "bin/zsh\u{0}",
            arguments: ["-lc", "echo bad\u{0}"],
            environment: ["": "empty", "BAD=KEY": "value", "BAD_VALUE": "x\u{0}y"],
            workingDirectoryPath: "relative",
            initialSize: Phase2HumanPTYTerminalSize(columns: 0, rows: 24),
            transcriptLimits: Phase2HumanPTYTranscriptLimits(
                maximumEvents: 0,
                maximumEventBytes: 1,
                maximumCumulativeBytes: 1
            )
        )

        let result = Phase2HumanPTYLaunchPlanValidator.validate(plan)

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.issues.contains(.executablePathNotAbsolute("bin/zsh\u{0}")))
        XCTAssertTrue(result.issues.contains(.executablePathContainsNUL))
        XCTAssertTrue(result.issues.contains(.argumentContainsNUL(index: 1)))
        XCTAssertTrue(result.issues.contains(.environmentKeyEmpty))
        XCTAssertTrue(result.issues.contains(.environmentKeyContainsInvalidCharacter("BAD=KEY")))
        XCTAssertTrue(result.issues.contains(.environmentValueContainsNUL(key: "BAD_VALUE")))
        XCTAssertTrue(result.issues.contains(.workingDirectoryNotAbsolute("relative")))
        XCTAssertTrue(result.issues.contains(.invalidInitialTerminalSize(Phase2HumanPTYTerminalSize(columns: 0, rows: 24))))
        XCTAssertTrue(result.issues.contains(.invalidTranscriptLimits))
    }

    func testBrokerCommandAuthorityKeepsHumanInputHumanOwnedAndReconnectAppOwned() {
        let sessionID = brokerUUID(1)
        let brokerAuthoredInput = command(
            sessionID: sessionID,
            authority: .app,
            payload: .writeInput(bytes("whoami\n"))
        )
        let humanReconnect = command(
            sessionID: sessionID,
            authority: .human,
            payload: .reconnect(reconnectID: brokerUUID(2))
        )

        let inputResult = Phase2HumanPTYBrokerCommandValidator.validate(
            brokerAuthoredInput,
            expectedSessionID: sessionID
        )
        let reconnectResult = Phase2HumanPTYBrokerCommandValidator.validate(
            humanReconnect,
            expectedSessionID: sessionID
        )

        XCTAssertFalse(inputResult.isAccepted)
        XCTAssertTrue(inputResult.issues.contains(.disallowedAuthority(authority: .app, payload: .writeInput)))
        XCTAssertFalse(reconnectResult.isAccepted)
        XCTAssertTrue(reconnectResult.issues.contains(.disallowedAuthority(authority: .human, payload: .reconnect)))
    }

    func testLaunchCommandValidatesCommandSessionPlanSessionAndPlanShapeTogether() {
        let expectedSessionID = brokerUUID(3)
        let commandSessionID = brokerUUID(4)
        let plan = launchPlan(
            sessionID: brokerUUID(5),
            executablePath: "zsh",
            workingDirectoryPath: "/tmp"
        )
        let launch = command(
            sessionID: commandSessionID,
            authority: .human,
            payload: .launch(plan)
        )

        let result = Phase2HumanPTYBrokerCommandValidator.validate(
            launch,
            expectedSessionID: expectedSessionID
        )

        XCTAssertFalse(result.isAccepted)
        XCTAssertTrue(result.issues.contains(.sessionMismatch(expected: expectedSessionID, actual: commandSessionID)))
        XCTAssertTrue(result.issues.contains(.sessionMismatch(expected: commandSessionID, actual: plan.sessionID)))
        XCTAssertTrue(result.issues.contains(.invalidLaunchPlan([.executablePathNotAbsolute("zsh")])))
    }

    func testBrokerCommandRejectsEmptyInputAndInvalidResize() {
        let sessionID = brokerUUID(6)
        let emptyInput = command(
            sessionID: sessionID,
            authority: .human,
            payload: .writeInput([])
        )
        let invalidResize = command(
            sessionID: sessionID,
            authority: .human,
            payload: .resize(Phase2HumanPTYTerminalSize(columns: 80, rows: 0))
        )

        let emptyInputResult = Phase2HumanPTYBrokerCommandValidator.validate(
            emptyInput,
            expectedSessionID: sessionID
        )
        let invalidResizeResult = Phase2HumanPTYBrokerCommandValidator.validate(
            invalidResize,
            expectedSessionID: sessionID
        )

        XCTAssertFalse(emptyInputResult.isAccepted)
        XCTAssertTrue(emptyInputResult.issues.contains(.invalidInput))
        XCTAssertFalse(invalidResizeResult.isAccepted)
        XCTAssertTrue(invalidResizeResult.issues.contains(.invalidResize(Phase2HumanPTYTerminalSize(columns: 80, rows: 0))))
    }

    func testBrokerEventCanCarryTranscriptEventWithoutGrantingLaunchAuthority() {
        let sessionID = brokerUUID(7)
        let transcriptEvent = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes("ready\n"))
        )
        let brokerEvent = Phase2HumanPTYBrokerEvent(
            sessionID: sessionID,
            eventID: brokerUUID(8),
            payload: .transcript(transcriptEvent)
        )

        XCTAssertEqual(brokerEvent.sessionID, transcriptEvent.sessionID)
        XCTAssertEqual(brokerEvent.payload, .transcript(transcriptEvent))
    }
}

private func launchPlan(
    sessionID: UUID = brokerUUID(10),
    requestID: UUID = brokerUUID(11),
    executablePath: String,
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

private func command(
    commandID: UUID = brokerUUID(20),
    sessionID: UUID,
    authority: Phase2HumanPTYCommandAuthority,
    payload: Phase2HumanPTYBrokerCommandPayload
) -> Phase2HumanPTYBrokerCommand {
    Phase2HumanPTYBrokerCommand(
        commandID: commandID,
        sessionID: sessionID,
        authority: authority,
        payload: payload
    )
}

private func brokerUUID(_ value: UInt64) -> UUID {
    UUID(uuidString: String(format: "20000000-0000-0000-0000-%012llx", value))!
}

private func bytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
}
