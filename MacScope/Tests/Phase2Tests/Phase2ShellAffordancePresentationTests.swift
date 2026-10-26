import XCTest

@testable import MacScope

final class Phase2ShellAffordancePresentationTests: XCTestCase {
    func testRetainedDurableRecoveryShowsFailureBeforeCwdAndPreventsReplacementLaunch() throws {
        let sessionID = shellAffordanceUUID(201)
        let requestID = shellAffordanceUUID(202)
        let created = Date(timeIntervalSince1970: 100)
        let expires = Date(timeIntervalSince1970: 300)
        let launch = Phase2DurableShellBrokerLaunchRequest(
            brokerIncarnationID: shellAffordanceUUID(203), sessionID: sessionID,
            capabilityID: shellAffordanceUUID(204), requestID: requestID,
            executablePath: "/bin/sh", arguments: ["-i"], workingDirectoryPath: "/tmp",
            createdAt: created, expiresAt: expires
        )
        let process = Phase2DurableShellBrokerProcessIdentity(
            processIdentifier: 901, processStartTimeUnixNanoseconds: 123,
            executablePath: "/bin/sh", processGroupIdentifier: 901
        )
        let secret = try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(repeating: 7, count: 32))
        let identity = Phase2DurableShellBrokerIdentity(
            launchRequest: launch, processIdentity: process, createdAt: created,
            expiresAt: expires, nextTranscriptSequence: 1,
            capabilityVerifierSHA256: secret.verifier(launchRequest: launch, processIdentity: process)
        )
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID, state: .terminal(outcome: .outcomeUnknown),
            launchPlan: .init(sessionID: sessionID, requestID: requestID,
                executablePath: "/bin/sh", arguments: ["-i"], workingDirectoryPath: "/tmp", initialSize: .defaultInteractive),
            transcriptEvents: [], issues: []
        )
        let error = "Durable shell recovery could not be authenticated. Retry recovery."
        let retained = Phase2ShellAffordancePresentation.project(.init(
            snapshot: snapshot, inFlightCommand: nil, lastError: error,
            lastAcceptedTranscriptEvents: [], lastBytesWritten: nil,
            durableRecoveryIdentity: identity
        ))
        XCTAssertEqual(retained.statusDetail(launchMessage: "Session cwd /tmp"), error)
        XCTAssertFalse(retained.canLaunch)
        XCTAssertFalse(retained.canRelaunch)
        XCTAssertTrue(retained.canRetrySessionRecovery)
        XCTAssertFalse(retained.canForgetRestoredContext)

        let cleared = Phase2ShellAffordancePresentation.project(.init(
            snapshot: snapshot, inFlightCommand: nil, lastError: nil,
            lastAcceptedTranscriptEvents: [], lastBytesWritten: nil
        ))
        XCTAssertEqual(cleared.statusDetail(launchMessage: "Session cwd /tmp"), "Session cwd /tmp")
        XCTAssertTrue(cleared.canLaunch)
        XCTAssertTrue(cleared.canRelaunch)
        XCTAssertFalse(cleared.canRetrySessionRecovery)
    }

    func testInactiveProjectionCanLaunchButCannotSendOrStop() {
        let presentation = Phase2ShellAffordancePresentation.project(.inactive)

        XCTAssertEqual(presentation.statusTitle, "Not started")
        XCTAssertTrue(presentation.canLaunch)
        XCTAssertFalse(presentation.canRelaunch)
        XCTAssertFalse(presentation.canForgetRestoredContext)
        XCTAssertFalse(presentation.canSendInput)
        XCTAssertFalse(presentation.canPoll)
        XCTAssertFalse(presentation.canResize)
        XCTAssertFalse(presentation.canInterrupt)
        XCTAssertFalse(presentation.canReconnect)
        XCTAssertFalse(presentation.canCleanup)
        XCTAssertEqual(presentation.transcriptPreview, "No transcript yet")
        XCTAssertFalse(presentation.canCopyLastTurn)
        XCTAssertFalse(presentation.canCopyVisibleTranscript)
        XCTAssertFalse(presentation.canClearVisibleTranscript)
        XCTAssertNil(presentation.latestVisibleTranscriptSequence)
        XCTAssertNil(presentation.latestSourceTranscriptSequence)
        XCTAssertNil(presentation.lastTurnClipboardText)
        XCTAssertNil(presentation.visibleTranscriptClipboardText)
        XCTAssertNil(presentation.fullTranscriptClipboardText)
        XCTAssertFalse(presentation.canSaveFullTranscript)
        XCTAssertNil(presentation.fullTranscriptExportFilename)
        XCTAssertNil(presentation.terminalSessionID)
        XCTAssertTrue(presentation.terminalTranscriptEvents.isEmpty)
        XCTAssertNil(presentation.error)
    }

    func testRunningProjectionEnablesHumanInputPollAndCleanup() {
        let sessionID = shellAffordanceUUID(1)
        let requestID = shellAffordanceUUID(2)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 321),
            launchPlan: Phase2HumanPTYLaunchPlan(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/zsh",
                initialSize: .defaultInteractive
            ),
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(Array("pwd\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("/tmp\n".utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: 4
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.statusTitle, "Running")
        XCTAssertEqual(presentation.detail, "PID 321 · 2 transcript events · wrote 4 bytes")
        XCTAssertFalse(presentation.canLaunch)
        XCTAssertFalse(presentation.canRelaunch)
        XCTAssertFalse(presentation.canForgetRestoredContext)
        XCTAssertTrue(presentation.canSendInput)
        XCTAssertTrue(presentation.canPoll)
        XCTAssertTrue(presentation.canResize)
        XCTAssertTrue(presentation.canInterrupt)
        XCTAssertTrue(presentation.canReconnect)
        XCTAssertTrue(presentation.canCleanup)
        XCTAssertEqual(presentation.transcriptPreview, "in: pwd↵ · out: /tmp↵")
        XCTAssertEqual(presentation.autoPollSessionID, sessionID)
        XCTAssertEqual(presentation.transcriptLines.map(\.source), ["in", "out"])
        XCTAssertEqual(presentation.transcriptLines.map(\.text), ["pwd↵", "/tmp↵"])
        XCTAssertEqual(presentation.transcriptLines.map(\.tone), [.human, .standardOutput])
        XCTAssertEqual(presentation.transcriptTurns.count, 1)
        XCTAssertEqual(presentation.transcriptTurns.first?.startSequence, 1)
        XCTAssertEqual(presentation.transcriptTurns.first?.commandText, "pwd")
        XCTAssertEqual(presentation.transcriptTurns.first?.responseLines.map(\.source), ["out"])
        XCTAssertEqual(presentation.transcriptTurns.first?.responseLines.map(\.text), ["/tmp↵"])
        XCTAssertTrue(presentation.canCopyLastTurn)
        XCTAssertTrue(presentation.canCopyVisibleTranscript)
        XCTAssertTrue(presentation.canClearVisibleTranscript)
        XCTAssertEqual(presentation.latestVisibleTranscriptSequence, 2)
        XCTAssertEqual(presentation.latestSourceTranscriptSequence, 2)
        XCTAssertEqual(presentation.lastTurnClipboardText, "$ pwd\nout: /tmp↵")
        XCTAssertEqual(presentation.visibleTranscriptClipboardText, "$ pwd\nout: /tmp↵")
        XCTAssertEqual(presentation.fullTranscriptClipboardText, "$ pwd\nout: /tmp↵")
        XCTAssertTrue(presentation.canSaveFullTranscript)
        XCTAssertEqual(presentation.fullTranscriptExportFilename, "MacScope-Shell-Transcript-01010101")
        XCTAssertEqual(presentation.terminalSessionID, sessionID)
        XCTAssertEqual(presentation.terminalTranscriptEvents, snapshot.transcriptEvents)
        XCTAssertTrue(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: presentation.terminalSessionID,
            events: presentation.terminalTranscriptEvents
        ))
    }

    func testTerminalSurfaceRequiresStableIdentityAndStrictlyOrderedEvents() {
        let sessionID = shellAffordanceUUID(45)
        let foreignSessionID = shellAffordanceUUID(46)
        let first = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: Array("one".utf8))
        )
        let second = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 2,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: Array("two".utf8))
        )
        let foreign = Phase2HumanPTYTranscriptEvent(
            sessionID: foreignSessionID,
            sequence: 2,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: Array("foreign".utf8))
        )
        let gap = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 3,
            source: .broker,
            payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 128)
        )

        XCTAssertTrue(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: sessionID,
            events: [first, second]
        ))
        XCTAssertEqual(
            Phase2TerminalSurfacePresentation.renderingPath(
                sessionID: sessionID,
                events: [first, second]
            ),
            .ghostty(sessionID)
        )
        XCTAssertFalse(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: nil,
            events: [first, second]
        ))
        XCTAssertFalse(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: sessionID,
            events: []
        ))
        XCTAssertFalse(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: sessionID,
            events: [second, first]
        ))
        XCTAssertFalse(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: sessionID,
            events: [first, foreign]
        ))
        XCTAssertFalse(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: sessionID,
            events: [first, second, gap]
        ))
        let numericGap = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 3,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: Array("gap".utf8))
        )
        XCTAssertFalse(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: sessionID,
            events: [first, numericGap]
        ))
        XCTAssertEqual(
            Phase2TerminalSurfacePresentation.renderingPath(
                sessionID: sessionID,
                events: [first, numericGap]
            ),
            .transcriptFallback
        )
        XCTAssertFalse(Phase2TerminalSurfacePresentation.canRenderGhosttySurface(
            sessionID: sessionID,
            events: [second]
        ))
        let zeroSequence = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 0,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: Array("zero".utf8))
        )
        XCTAssertEqual(
            Phase2TerminalSurfacePresentation.renderingPath(
                sessionID: sessionID,
                events: [zeroSequence, first, second]
            ),
            .transcriptFallback
        )
    }

    func testTerminalSurfaceRetainsFullSourceEventsWhenTextLensIsFiltered() {
        let sessionID = shellAffordanceUUID(47)
        let requestID = shellAffordanceUUID(48)
        let events = [
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: 1,
                source: .human,
                payload: .input(Array("printf hidden\\n".utf8))
            ),
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: 2,
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: Array("hidden\\n".utf8))
            ),
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: 3,
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: Array("visible\\n".utf8))
            ),
        ]
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 900),
            launchPlan: Phase2HumanPTYLaunchPlan(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/zsh",
                initialSize: .defaultInteractive
            ),
            transcriptEvents: events,
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(
            projection,
            visibleAfterSequence: 2,
            transcriptSearchQuery: "visible"
        )

        XCTAssertEqual(presentation.transcriptLines.map(\.sequence), [3])
        XCTAssertEqual(presentation.terminalSessionID, sessionID)
        XCTAssertEqual(presentation.terminalTranscriptEvents, events)
    }

    func testRunningProjectionShowsLaunchWorkingDirectoryWhenModeled() {
        let sessionID = shellAffordanceUUID(29)
        let requestID = shellAffordanceUUID(30)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 884),
            launchPlan: Phase2HumanPTYLaunchPlan(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/zsh",
                workingDirectoryPath: "/tmp",
                initialSize: .defaultInteractive
            ),
            transcriptEvents: [],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.sessionWorkingDirectoryPath, "/tmp")
        XCTAssertEqual(presentation.currentTerminalSize, .defaultInteractive)
        XCTAssertEqual(presentation.detail, "PID 884 · cwd /tmp · 0 transcript events")
    }

    func testRunningProjectionUsesLatestResizeForTerminalRendererSize() {
        let sessionID = shellAffordanceUUID(35)
        let requestID = shellAffordanceUUID(36)
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .running(requestID: requestID, processIdentifier: 885),
                launchPlan: Phase2HumanPTYLaunchPlan(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/zsh",
                    initialSize: Phase2HumanPTYTerminalSize(columns: 80, rows: 24)
                ),
                transcriptEvents: [
                    Phase2HumanPTYTranscriptEvent(
                        sessionID: sessionID,
                        sequence: 1,
                        source: .app,
                        payload: .resize(columns: 132, rows: 44)
                    ),
                    Phase2HumanPTYTranscriptEvent(
                        sessionID: sessionID,
                        sequence: 2,
                        source: .human,
                        payload: .input(Array("printf '%s\\n' hi\n".utf8))
                    ),
                ],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.currentTerminalSize, Phase2HumanPTYTerminalSize(columns: 132, rows: 44))
    }

    func testRestoredInactiveProjectionShowsHistoricalContextWithoutLiveAuthority() {
        let sessionID = shellAffordanceUUID(31)
        let requestID = shellAffordanceUUID(32)
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .terminal(outcome: .outcomeUnknown),
                launchPlan: Phase2HumanPTYLaunchPlan(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/zsh",
                    arguments: ["-lc", "pwd"],
                    environment: ["TERM": "xterm-256color"],
                    workingDirectoryPath: "/tmp",
                    initialSize: Phase2HumanPTYTerminalSize(columns: 132, rows: 44)
                ),
                transcriptEvents: [
                    Phase2HumanPTYTranscriptEvent(
                        sessionID: sessionID,
                        sequence: 1,
                        source: .human,
                        payload: .input(Array("pwd\n".utf8))
                    ),
                    Phase2HumanPTYTranscriptEvent(
                        sessionID: sessionID,
                        sequence: 2,
                        source: .broker,
                        payload: .output(stream: .standardOutput, bytes: Array("/tmp\n".utf8))
                    ),
                ],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: Phase2WorkspaceShellSessionProjection.restoredInactiveMessage,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.statusTitle, "Restored")
        XCTAssertEqual(presentation.statusSystemImage, "clock.arrow.circlepath")
        XCTAssertTrue(presentation.isRestoredContext)
        XCTAssertEqual(presentation.detail, Phase2WorkspaceShellSessionProjection.restoredInactiveMessage)
        XCTAssertEqual(presentation.error, Phase2WorkspaceShellSessionProjection.restoredInactiveMessage)
        XCTAssertEqual(presentation.sessionWorkingDirectoryPath, "/tmp")
        XCTAssertEqual(presentation.restoredLaunchSessionID, sessionID)
        XCTAssertEqual(presentation.restoredLaunchDraft?.executablePathText, "/bin/zsh")
        XCTAssertEqual(presentation.restoredLaunchDraft?.normalizedArguments, ["-lc", "pwd"])
        XCTAssertEqual(presentation.restoredLaunchDraft?.normalizedEnvironment, ["TERM": "xterm-256color"])
        XCTAssertEqual(presentation.restoredLaunchDraft?.workingDirectoryPathText, "/tmp")
        XCTAssertEqual(presentation.restoredTerminalSizeDraft?.columnsText, "132")
        XCTAssertEqual(presentation.restoredTerminalSizeDraft?.rowsText, "44")
        XCTAssertEqual(presentation.transcriptPreview, "in: pwd↵ · out: /tmp↵")
        XCTAssertTrue(presentation.canLaunch)
        XCTAssertTrue(presentation.canRelaunch)
        XCTAssertTrue(presentation.canForgetRestoredContext)
        XCTAssertFalse(presentation.canSendInput)
        XCTAssertFalse(presentation.canPoll)
        XCTAssertFalse(presentation.canResize)
        XCTAssertFalse(presentation.canInterrupt)
        XCTAssertFalse(presentation.canReconnect)
        XCTAssertFalse(presentation.canCleanup)
        XCTAssertNil(presentation.autoPollSessionID)
        XCTAssertEqual(presentation.lastTurnClipboardText, "$ pwd\nout: /tmp↵")
        XCTAssertTrue(presentation.canCopyLastTurn)
        XCTAssertTrue(presentation.canCopyVisibleTranscript)
    }

    func testBackgroundPollPreservesRunningPresentationAndControls() {
        let sessionID = shellAffordanceUUID(3)
        let requestID = shellAffordanceUUID(4)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 777),
            launchPlan: nil,
            transcriptEvents: [],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: .pollTranscript,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.statusTitle, "Running")
        XCTAssertFalse(presentation.isBusy)
        XCTAssertFalse(presentation.canLaunch)
        XCTAssertFalse(presentation.canForgetRestoredContext)
        XCTAssertTrue(presentation.canSendInput)
        XCTAssertFalse(presentation.canPoll)
        XCTAssertFalse(presentation.canResize)
        XCTAssertTrue(presentation.canInterrupt)
        XCTAssertFalse(presentation.canReconnect)
        XCTAssertTrue(presentation.canCleanup)
        XCTAssertEqual(presentation.autoPollSessionID, sessionID)
    }

    func testRunningInputCaptureRemainsEnabledDuringWriteAndSignal() {
        for command in [Phase2WorkspaceShellSessionCommand.writeInput, .signal] {
            let snapshot = Phase2HumanPTYSessionSnapshot(sessionID: shellAffordanceUUID(203),
                state: .running(requestID: shellAffordanceUUID(204), processIdentifier: 777),
                launchPlan: nil, transcriptEvents: [], issues: [])
            let projection = Phase2WorkspaceShellSessionProjection(snapshot: snapshot,
                inFlightCommand: command, lastError: nil, lastAcceptedTranscriptEvents: [], lastBytesWritten: nil)
            let presentation = Phase2ShellAffordancePresentation.project(projection)
            XCTAssertTrue(presentation.canSendInput, "A key write must not disable capture and discard queued keys")
            XCTAssertTrue(presentation.canInterrupt)
            XCTAssertTrue(presentation.isBusy)
        }
    }

    func testLastErrorOverridesDetailWithoutGrantingAuthority() {
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: nil,
            inFlightCommand: nil,
            lastError: "No active Phase 2 shell session.",
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.detail, "No active Phase 2 shell session.")
        XCTAssertEqual(presentation.error, "No active Phase 2 shell session.")
        XCTAssertTrue(presentation.canLaunch)
        XCTAssertFalse(presentation.canSendInput)
        XCTAssertFalse(presentation.canPoll)
        XCTAssertFalse(presentation.canResize)
        XCTAssertFalse(presentation.canInterrupt)
        XCTAssertFalse(presentation.canReconnect)
        XCTAssertFalse(presentation.canCleanup)
    }

    func testTranscriptProjectionRendersControlWarningAndErrorLines() {
        let sessionID = shellAffordanceUUID(5)
        let requestID = shellAffordanceUUID(6)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 412),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .app,
                    payload: .resize(columns: 100, rows: 40)
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardError, bytes: Array("permission denied\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 3,
                    source: .app,
                    payload: .signal(.interrupt)
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 4,
                    source: .broker,
                    payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 128)
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.transcriptLines.map(\.source), ["ctl", "err", "sig", "gap"])
        XCTAssertEqual(presentation.transcriptLines.map(\.text), [
            "resize 100×40",
            "permission denied↵",
            "interrupt",
            "spoolLimitExceeded, 128 bytes lost",
        ])
        XCTAssertEqual(presentation.transcriptLines.map(\.tone), [
            .control,
            .standardError,
            .warning,
            .warning,
        ])
        XCTAssertEqual(presentation.transcriptPreview, "err: permission denied↵ · sig: interrupt · gap: spoolLimitExceeded, 128 bytes lost")
        XCTAssertEqual(presentation.transcriptTurns.count, 1)
        XCTAssertEqual(presentation.transcriptTurns.first?.startSequence, 1)
        XCTAssertEqual(presentation.transcriptTurns.first?.commandText, "Session")
        XCTAssertEqual(presentation.transcriptTurns.first?.responseLines, presentation.transcriptLines)
        XCTAssertEqual(
            presentation.lastTurnClipboardText,
            "# Session\nctl: resize 100×40\nerr: permission denied↵\nsig: interrupt\ngap: spoolLimitExceeded, 128 bytes lost"
        )
    }

    func testTranscriptProjectionGroupsRecentEventsIntoCommandTurns() {
        let sessionID = shellAffordanceUUID(13)
        let requestID = shellAffordanceUUID(14)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 908),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(Array("pwd\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("/tmp/project\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 3,
                    source: .human,
                    payload: .input(Array("git status\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 4,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("On branch main\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 5,
                    source: .broker,
                    payload: .output(stream: .standardError, bytes: Array("nothing to commit\n".utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.transcriptTurns.count, 2)
        XCTAssertEqual(presentation.transcriptTurns[0].commandText, "pwd")
        XCTAssertEqual(presentation.transcriptTurns[0].responseLines.map(\.text), ["/tmp/project↵"])
        XCTAssertEqual(presentation.transcriptTurns[1].commandText, "git status")
        XCTAssertEqual(presentation.transcriptTurns[1].responseLines.map(\.source), ["out", "err"])
        XCTAssertEqual(presentation.transcriptTurns[1].responseLines.map(\.text), [
            "On branch main↵",
            "nothing to commit↵",
        ])
        XCTAssertTrue(presentation.canCopyLastTurn)
        XCTAssertTrue(presentation.canCopyVisibleTranscript)
        XCTAssertEqual(
            presentation.lastTurnClipboardText,
            "$ git status\nout: On branch main↵\nerr: nothing to commit↵"
        )
        XCTAssertEqual(
            presentation.visibleTranscriptClipboardText,
            "$ pwd\nout: /tmp/project↵\n\n$ git status\nout: On branch main↵\nerr: nothing to commit↵"
        )
    }

    func testTranscriptSearchFiltersVisibleCommandTurnsWithoutDeletingSourceTranscript() {
        let sessionID = shellAffordanceUUID(41)
        let requestID = shellAffordanceUUID(42)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 912),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(Array("pwd\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("/tmp/project\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 3,
                    source: .human,
                    payload: .input(Array("git status\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 4,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("On branch main\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 5,
                    source: .broker,
                    payload: .output(stream: .standardError, bytes: Array("nothing to commit\n".utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(
            projection,
            transcriptSearchQuery: "MAIN"
        )

        XCTAssertTrue(presentation.isTranscriptSearchActive)
        XCTAssertEqual(presentation.transcriptSearchQuery, "MAIN")
        XCTAssertEqual(presentation.transcriptSearchMatchCount, 1)
        XCTAssertNil(presentation.transcriptSearchEmptyMessage)
        XCTAssertEqual(presentation.transcriptPreview, "1 transcript match for “MAIN”")
        XCTAssertEqual(presentation.latestSourceTranscriptSequence, 5)
        XCTAssertEqual(presentation.latestVisibleTranscriptSequence, 5)
        XCTAssertEqual(presentation.transcriptTurns.count, 1)
        XCTAssertEqual(presentation.transcriptTurns.first?.commandText, "git status")
        XCTAssertEqual(presentation.transcriptTurns.first?.responseLines.map(\.text), [
            "On branch main↵",
            "nothing to commit↵",
        ])
        XCTAssertEqual(presentation.transcriptLines.map(\.sequence), [4])
        XCTAssertEqual(
            presentation.visibleTranscriptClipboardText,
            "$ git status\nout: On branch main↵\nerr: nothing to commit↵"
        )
        XCTAssertEqual(
            presentation.fullTranscriptClipboardText,
            "$ pwd\nout: /tmp/project↵\n\n$ git status\nout: On branch main↵\nerr: nothing to commit↵"
        )
    }

    func testTranscriptSearchShowsNoMatchWithoutClearingSourceTranscript() {
        let sessionID = shellAffordanceUUID(43)
        let requestID = shellAffordanceUUID(44)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 913),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(Array("pwd\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("/tmp/project\n".utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(
            projection,
            transcriptSearchQuery: "missing"
        )

        XCTAssertTrue(presentation.isTranscriptSearchActive)
        XCTAssertEqual(presentation.transcriptSearchMatchCount, 0)
        XCTAssertEqual(presentation.transcriptSearchEmptyMessage, "No transcript matches “missing”")
        XCTAssertEqual(presentation.transcriptPreview, "No transcript matches “missing”")
        XCTAssertTrue(presentation.transcriptTurns.isEmpty)
        XCTAssertTrue(presentation.transcriptLines.isEmpty)
        XCTAssertEqual(presentation.latestSourceTranscriptSequence, 2)
        XCTAssertEqual(presentation.latestVisibleTranscriptSequence, 2)
        XCTAssertFalse(presentation.canCopyLastTurn)
        XCTAssertFalse(presentation.canCopyVisibleTranscript)
        XCTAssertTrue(presentation.canCopyFullTranscript)
        XCTAssertEqual(presentation.fullTranscriptClipboardText, "$ pwd\nout: /tmp/project↵")
        XCTAssertTrue(presentation.canClearVisibleTranscript)
    }

    func testTranscriptProjectionCanHidePreviouslyVisibleEventsWithoutDeletingSourceTranscript() {
        let sessionID = shellAffordanceUUID(17)
        let requestID = shellAffordanceUUID(18)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 910),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(Array("pwd\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("/tmp/project\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 3,
                    source: .human,
                    payload: .input(Array("git status\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 4,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("On branch main\n".utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(
            projection,
            visibleAfterSequence: 2
        )

        XCTAssertEqual(presentation.detail, "PID 910 · 4 transcript events")
        XCTAssertEqual(presentation.latestSourceTranscriptSequence, 4)
        XCTAssertEqual(presentation.latestVisibleTranscriptSequence, 4)
        XCTAssertTrue(presentation.canClearVisibleTranscript)
        XCTAssertEqual(presentation.transcriptLines.map(\.sequence), [3, 4])
        XCTAssertEqual(presentation.transcriptTurns.count, 1)
        XCTAssertEqual(presentation.transcriptTurns.first?.commandText, "git status")
        XCTAssertEqual(presentation.lastTurnClipboardText, "$ git status\nout: On branch main↵")
        XCTAssertEqual(presentation.visibleTranscriptClipboardText, "$ git status\nout: On branch main↵")
        XCTAssertEqual(
            presentation.fullTranscriptClipboardText,
            "$ pwd\nout: /tmp/project↵\n\n$ git status\nout: On branch main↵"
        )
    }

    func testTranscriptProjectionShowsClearedPlaceholderUntilNewerEventsArrive() {
        let sessionID = shellAffordanceUUID(19)
        let requestID = shellAffordanceUUID(20)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 911),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(Array("pwd\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("/tmp/project\n".utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let cleared = Phase2ShellAffordancePresentation.project(
            projection,
            visibleAfterSequence: 2
        )

        XCTAssertEqual(cleared.detail, "PID 911 · 2 transcript events")
        XCTAssertEqual(cleared.transcriptPreview, "Visible transcript cleared")
        XCTAssertTrue(cleared.transcriptLines.isEmpty)
        XCTAssertTrue(cleared.transcriptTurns.isEmpty)
        XCTAssertFalse(cleared.canCopyLastTurn)
        XCTAssertFalse(cleared.canCopyVisibleTranscript)
        XCTAssertTrue(cleared.canCopyFullTranscript)
        XCTAssertFalse(cleared.canClearVisibleTranscript)
        XCTAssertEqual(cleared.latestSourceTranscriptSequence, 2)
        XCTAssertNil(cleared.latestVisibleTranscriptSequence)
        XCTAssertNil(cleared.visibleTranscriptClipboardText)
        XCTAssertEqual(cleared.fullTranscriptClipboardText, "$ pwd\nout: /tmp/project↵")

        let updatedSnapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 911),
            launchPlan: nil,
            transcriptEvents: snapshot.transcriptEvents + [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 3,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("after clear\n".utf8))
                ),
            ],
            issues: []
        )
        let updated = Phase2ShellAffordancePresentation.project(
            Phase2WorkspaceShellSessionProjection(
                snapshot: updatedSnapshot,
                inFlightCommand: nil,
                lastError: nil,
                lastAcceptedTranscriptEvents: [],
                lastBytesWritten: nil
            ),
            visibleAfterSequence: 2
        )

        XCTAssertEqual(updated.transcriptPreview, "out: after clear↵")
        XCTAssertEqual(updated.transcriptLines.map(\.sequence), [3])
        XCTAssertEqual(updated.transcriptTurns.first?.commandText, "Session")
        XCTAssertEqual(updated.lastTurnClipboardText, "# Session\nout: after clear↵")
        XCTAssertEqual(updated.visibleTranscriptClipboardText, "# Session\nout: after clear↵")
        XCTAssertTrue(updated.canCopyVisibleTranscript)
        XCTAssertTrue(updated.canClearVisibleTranscript)
    }

    func testTranscriptProjectionBoundsRenderedCommandTurns() {
        let sessionID = shellAffordanceUUID(15)
        let requestID = shellAffordanceUUID(16)
        var events: [Phase2HumanPTYTranscriptEvent] = []
        for index in 1...20 {
            let commandBytes = Array("cmd-\(index)\n".utf8)
            let resultBytes = Array("result-\(index)\n".utf8)
            events.append(Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: UInt64(index * 2 - 1),
                source: .human,
                payload: .input(commandBytes)
            ))
            events.append(Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: UInt64(index * 2),
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: resultBytes)
            ))
        }
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 909),
            launchPlan: nil,
            transcriptEvents: events,
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.transcriptTurns.count, AppShellChrome.maximumRenderedTranscriptTurns)
        XCTAssertEqual(presentation.transcriptTurns.first?.commandText, "cmd-9")
        XCTAssertEqual(presentation.transcriptTurns.last?.commandText, "cmd-20")
        XCTAssertEqual(presentation.lastTurnClipboardText, "$ cmd-20\nout: result-20↵")
    }

    func testVisibleTranscriptClipboardUsesSameBoundedTurnLensAsRenderedScrollback() {
        let sessionID = shellAffordanceUUID(23)
        let requestID = shellAffordanceUUID(24)
        var events: [Phase2HumanPTYTranscriptEvent] = []
        for index in 1...20 {
            events.append(Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: UInt64(index * 2 - 1),
                source: .human,
                payload: .input(Array("cmd-\(index)\n".utf8))
            ))
            events.append(Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: UInt64(index * 2),
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: Array("result-\(index)\n".utf8))
            ))
        }
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 912),
            launchPlan: nil,
            transcriptEvents: events,
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.transcriptTurns.count, AppShellChrome.maximumRenderedTranscriptTurns)
        XCTAssertTrue(presentation.visibleTranscriptClipboardText?.hasPrefix("$ cmd-9") == true)
        XCTAssertTrue(presentation.visibleTranscriptClipboardText?.contains("\n\n$ cmd-10") == true)
        XCTAssertTrue(presentation.visibleTranscriptClipboardText?.contains("$ cmd-20\nout: result-20↵") == true)
        XCTAssertFalse(presentation.visibleTranscriptClipboardText?.contains("$ cmd-8") == true)
        XCTAssertTrue(presentation.canCopyFullTranscript)
        XCTAssertTrue(presentation.fullTranscriptClipboardText?.hasPrefix("$ cmd-1\nout: result-1↵") == true)
        XCTAssertTrue(presentation.fullTranscriptClipboardText?.contains("\n\n$ cmd-8\nout: result-8↵") == true)
        XCTAssertTrue(presentation.fullTranscriptClipboardText?.contains("$ cmd-20\nout: result-20↵") == true)
    }

    func testVisibleTranscriptClipboardDoesNotLeakHiddenCommandAnchorAfterClear() {
        let sessionID = shellAffordanceUUID(25)
        let requestID = shellAffordanceUUID(26)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 913),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(Array("pwd\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("/tmp\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 3,
                    source: .human,
                    payload: .input(Array("sleep 1\n".utf8))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 4,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("done\n".utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(
            projection,
            visibleAfterSequence: 3
        )

        XCTAssertEqual(presentation.transcriptTurns.first?.commandText, "Session")
        XCTAssertEqual(presentation.lastTurnClipboardText, "# Session\nout: done↵")
        XCTAssertEqual(presentation.visibleTranscriptClipboardText, "# Session\nout: done↵")
        XCTAssertFalse(presentation.visibleTranscriptClipboardText?.contains("sleep 1") == true)
        XCTAssertEqual(
            presentation.fullTranscriptClipboardText,
            "$ pwd\nout: /tmp↵\n\n$ sleep 1\nout: done↵"
        )
    }

    func testVisibleTranscriptClipboardCopiesVisibleCommandWithoutResponse() {
        let sessionID = shellAffordanceUUID(27)
        let requestID = shellAffordanceUUID(28)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 914),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(Array("long-running\n".utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.transcriptTurns.count, 1)
        XCTAssertEqual(presentation.transcriptTurns.first?.commandText, "long-running")
        XCTAssertTrue(presentation.transcriptTurns.first?.responseLines.isEmpty == true)
        XCTAssertEqual(presentation.lastTurnClipboardText, "$ long-running")
        XCTAssertEqual(presentation.visibleTranscriptClipboardText, "$ long-running")
        XCTAssertEqual(presentation.fullTranscriptClipboardText, "$ long-running")
        XCTAssertTrue(presentation.canCopyLastTurn)
        XCTAssertTrue(presentation.canCopyVisibleTranscript)
        XCTAssertTrue(presentation.canCopyFullTranscript)
    }

    func testTranscriptProjectionKeepsOnlyBoundedRecentLines() {
        let sessionID = shellAffordanceUUID(7)
        let requestID = shellAffordanceUUID(8)
        let events = (1...100).map { sequence in
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: UInt64(sequence),
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: Array("line-\(sequence)\n".utf8))
            )
        }
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 905),
            launchPlan: nil,
            transcriptEvents: events,
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.transcriptLines.count, AppShellChrome.maximumRenderedTranscriptLines)
        XCTAssertEqual(presentation.transcriptLines.first?.sequence, 21)
        XCTAssertEqual(presentation.transcriptLines.last?.sequence, 100)
        XCTAssertEqual(presentation.transcriptLines.last?.text, "line-100↵")
    }

    func testTranscriptProjectionCapsLongRenderedLines() throws {
        let sessionID = shellAffordanceUUID(9)
        let requestID = shellAffordanceUUID(10)
        let longText = String(repeating: "A", count: AppShellChrome.transcriptLineCharacterLimit + 20)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 906),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array(longText.utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)
        let renderedText = try XCTUnwrap(presentation.transcriptLines.first?.text)

        XCTAssertLessThanOrEqual(renderedText.count, AppShellChrome.transcriptLineCharacterLimit)
        XCTAssertTrue(renderedText.hasSuffix("…"))
    }

    func testTranscriptProjectionSanitizesTerminalControlSequences() throws {
        let sessionID = shellAffordanceUUID(11)
        let requestID = shellAffordanceUUID(12)
        let terminalText = "\u{1B}[31merror\u{1B}[0m\tready\u{0007}\n\u{1B}]0;ignored-title\u{0007}done"
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 907),
            launchPlan: nil,
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .broker,
                    payload: .output(stream: .standardError, bytes: Array(terminalText.utf8))
                ),
            ],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)

        XCTAssertEqual(presentation.transcriptLines.first?.text, "error⇥ready␇↵done")
        XCTAssertEqual(presentation.transcriptPreview, "err: error⇥ready␇↵done")
    }

    func testRendererWiringCarriesOneExactCoordinateAndFencesRapidReplacement() throws {
        let sessionID = shellAffordanceUUID(51)
        let requestID = shellAffordanceUUID(52)
        let replacementRequestID = shellAffordanceUUID(53)
        let coordinate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: 7
        )
        let selection = Phase2TerminalRendererSelection(
            backend: .ghosttyFullSurface,
            fallback: nil
        )
        let events = [
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: 1,
                source: .broker,
                payload: .output(stream: .standardOutput, bytes: Array("ready\n".utf8))
            ),
        ]
        let wiring = Phase2ShellAffordanceRendererWiring.project(
            isTerminalPresented: true,
            rendererSelection: selection,
            terminalSessionID: sessionID,
            terminalRequestID: requestID,
            terminalLifecycleState: .running(
                requestID: requestID,
                processIdentifier: 5_001
            ),
            transcriptEvents: events,
            bindingCoordinate: coordinate,
            mediatedCoordinate: coordinate
        )

        XCTAssertEqual(wiring.rendererSelection, selection)
        XCTAssertEqual(wiring.terminalSessionID, sessionID)
        XCTAssertEqual(wiring.terminalRequestID, requestID)
        XCTAssertEqual(wiring.terminalRendererGeneration, 7)
        XCTAssertEqual(wiring.fullSurfaceCoordinate, coordinate)
        XCTAssertEqual(wiring.renderingResolution?.path, .ghosttyFullSurface)
        XCTAssertEqual(wiring.pollingOwner, .continuousSurface(coordinate))
        XCTAssertEqual(wiring.terminalCallbackAuthority, .surface(coordinate))

        guard case let .complete(transcript) = Phase2GhosttyTranscriptAdmissionState.replay(
            coordinate: coordinate.rendererCoordinate,
            events: events
        ) else {
            return XCTFail("expected a complete exact-coordinate transcript")
        }
        XCTAssertTrue(wiring.acceptsFullSurfaceTranscript(transcript))

        let presentationID = shellAffordanceUUID(54)
        let fence = Phase2ShellAffordanceTerminalCallbackFence(
            presentationID: presentationID,
            wiring: wiring
        )
        XCTAssertTrue(fence.permits(
            currentPresentationID: presentationID,
            currentWiring: wiring
        ))

        let replacement = Phase2ShellAffordanceRendererWiring.project(
            isTerminalPresented: true,
            rendererSelection: selection,
            terminalSessionID: sessionID,
            terminalRequestID: replacementRequestID,
            terminalLifecycleState: .running(
                requestID: replacementRequestID,
                processIdentifier: 5_002
            ),
            transcriptEvents: events,
            bindingCoordinate: coordinate,
            mediatedCoordinate: coordinate
        )

        XCTAssertNil(replacement.fullSurfaceCoordinate)
        XCTAssertNil(replacement.terminalRendererGeneration)
        XCTAssertEqual(replacement.pollingOwner, .unselected)
        XCTAssertEqual(replacement.terminalCallbackAuthority, .unavailable)
        XCTAssertFalse(fence.permits(
            currentPresentationID: presentationID,
            currentWiring: replacement
        ))
        XCTAssertFalse(fence.permits(
            currentPresentationID: shellAffordanceUUID(55),
            currentWiring: wiring
        ))
    }

    func testFatalFullSurfaceRetirementStagesLegacyAndTranscriptFallbackHasNoAuthority() {
        let sessionID = shellAffordanceUUID(56)
        let requestID = shellAffordanceUUID(57)
        let coordinate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: 8
        )
        let fullSelection = Phase2TerminalRendererSelection(
            backend: .ghosttyFullSurface,
            fallback: nil
        )
        let fatalLegacySelection = Phase2TerminalRendererSelection(
            backend: .macScopeGhosttyVTGrid,
            fallback: .runtimeFailure
        )
        let transitionID = shellAffordanceUUID(58)
        var rendererState = Phase2ShellAffordanceRendererState()

        XCTAssertEqual(rendererState.activate(fullSelection), .present(fullSelection))
        XCTAssertEqual(
            rendererState.update(
                to: fatalLegacySelection,
                retiringCoordinate: coordinate,
                transitionID: transitionID
            ),
            .retireSurface(coordinate, transitionID: transitionID)
        )
        XCTAssertFalse(rendererState.presentsTerminal)
        XCTAssertNil(rendererState.presentedSelection)
        XCTAssertEqual(rendererState.pendingTransitionID, transitionID)
        XCTAssertNil(rendererState.completeRetirement(
            transitionID: shellAffordanceUUID(59)
        ))
        XCTAssertFalse(rendererState.presentsTerminal)
        XCTAssertEqual(
            rendererState.completeRetirement(transitionID: transitionID),
            fatalLegacySelection
        )
        XCTAssertEqual(rendererState.presentedSelection, fatalLegacySelection)

        var rapidRecoveryState = Phase2ShellAffordanceRendererState()
        _ = rapidRecoveryState.activate(fullSelection)
        _ = rapidRecoveryState.update(
            to: fatalLegacySelection,
            retiringCoordinate: coordinate,
            transitionID: transitionID
        )
        XCTAssertEqual(
            rapidRecoveryState.update(
                to: fullSelection,
                retiringCoordinate: nil,
                transitionID: shellAffordanceUUID(60)
            ),
            .unchanged
        )
        XCTAssertFalse(rapidRecoveryState.presentsTerminal)
        XCTAssertEqual(rapidRecoveryState.pendingTransitionID, transitionID)
        XCTAssertEqual(
            rapidRecoveryState.completeRetirement(transitionID: transitionID),
            fullSelection
        )

        var duplicateAppearanceState = Phase2ShellAffordanceRendererState()
        _ = duplicateAppearanceState.activate(fullSelection)
        _ = duplicateAppearanceState.update(
            to: fatalLegacySelection,
            retiringCoordinate: coordinate,
            transitionID: transitionID
        )
        XCTAssertEqual(
            duplicateAppearanceState.activate(fatalLegacySelection),
            .unchanged
        )
        XCTAssertFalse(duplicateAppearanceState.presentsTerminal)
        XCTAssertEqual(duplicateAppearanceState.pendingTransitionID, transitionID)

        let rejectedEvents = [
            Phase2HumanPTYTranscriptEvent(
                sessionID: sessionID,
                sequence: 1,
                source: .broker,
                payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 64)
            ),
        ]
        let fallback = Phase2ShellAffordanceRendererWiring.project(
            isTerminalPresented: true,
            rendererSelection: fatalLegacySelection,
            terminalSessionID: sessionID,
            terminalRequestID: requestID,
            terminalLifecycleState: .running(
                requestID: requestID,
                processIdentifier: 5_003
            ),
            transcriptEvents: rejectedEvents,
            bindingCoordinate: nil,
            mediatedCoordinate: nil
        )

        XCTAssertEqual(fallback.renderingResolution?.path, .transcriptFallback)
        XCTAssertEqual(fallback.pollingOwner, .legacyManual)
        XCTAssertNil(fallback.terminalRendererGeneration)
        XCTAssertEqual(fallback.terminalCallbackAuthority, .unavailable)
    }

    func testRendererAuthorityNeverUsesCachedDisplayFallback() {
        let sessionID = shellAffordanceUUID(61)
        let requestID = shellAffordanceUUID(62)
        let cachedEvent = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [0x41])
        )
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 5_101),
            launchPlan: nil,
            transcriptEvents: [],
            issues: []
        )
        let presentation = Phase2ShellAffordancePresentation.project(
            Phase2WorkspaceShellSessionProjection(
                snapshot: snapshot,
                inFlightCommand: nil,
                lastError: nil,
                lastAcceptedTranscriptEvents: [cachedEvent],
                lastBytesWritten: nil
            )
        )
        XCTAssertEqual(presentation.transcriptPreview, "out: A")
        XCTAssertEqual(presentation.terminalTranscriptEvents, [])

        let coordinate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: 9
        )
        let wiring = Phase2ShellAffordanceRendererWiring.project(
            isTerminalPresented: true,
            rendererSelection: .init(backend: .ghosttyFullSurface, fallback: nil),
            terminalSessionID: presentation.terminalSessionID,
            terminalRequestID: presentation.terminalRequestID,
            terminalLifecycleState: presentation.terminalLifecycleState,
            transcriptEvents: presentation.terminalTranscriptEvents,
            bindingCoordinate: coordinate,
            mediatedCoordinate: coordinate
        )
        XCTAssertEqual(wiring.renderingResolution?.path, .transcriptFallback)
        XCTAssertNotEqual(wiring.pollingOwner, .continuousSurface(coordinate))
        XCTAssertEqual(wiring.terminalCallbackAuthority, .unavailable)
    }

    func testRendererWiringBlocksResidualAndInvalidSurfaceAuthority() {
        let sessionID = shellAffordanceUUID(63)
        let requestID = shellAffordanceUUID(64)
        let event = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [0x42])
        )
        let legacySelection = Phase2TerminalRendererSelection(
            backend: .macScopeGhosttyVTGrid,
            fallback: .runtimeFailure
        )
        let coordinate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: 10
        )
        for residual in [
            (binding: coordinate as Phase2ShellSurfaceCommandCoordinate?, mediated: nil),
            (binding: nil, mediated: coordinate as Phase2ShellSurfaceCommandCoordinate?),
            (binding: coordinate as Phase2ShellSurfaceCommandCoordinate?, mediated: coordinate as Phase2ShellSurfaceCommandCoordinate?),
        ] {
            let wiring = Phase2ShellAffordanceRendererWiring.project(
                isTerminalPresented: true,
                rendererSelection: legacySelection,
                terminalSessionID: sessionID,
                terminalRequestID: requestID,
                terminalLifecycleState: .running(
                    requestID: requestID,
                    processIdentifier: 5_102
                ),
                transcriptEvents: [event],
                bindingCoordinate: residual.binding,
                mediatedCoordinate: residual.mediated
            )
            XCTAssertEqual(wiring.pollingOwner, .unselected)
            XCTAssertEqual(wiring.terminalCallbackAuthority, .unavailable)
        }

        let zeroGeneration = Phase2ShellSurfaceCommandCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: 0
        )
        let invalid = Phase2ShellAffordanceRendererWiring.project(
            isTerminalPresented: true,
            rendererSelection: .init(backend: .ghosttyFullSurface, fallback: nil),
            terminalSessionID: sessionID,
            terminalRequestID: requestID,
            terminalLifecycleState: .running(
                requestID: requestID,
                processIdentifier: 5_103
            ),
            transcriptEvents: [event],
            bindingCoordinate: zeroGeneration,
            mediatedCoordinate: zeroGeneration
        )
        XCTAssertNil(invalid.fullSurfaceCoordinate)
        XCTAssertNil(invalid.terminalRendererGeneration)
        XCTAssertEqual(invalid.pollingOwner, .unselected)
        XCTAssertEqual(invalid.terminalCallbackAuthority, .unavailable)

        let mismatchedLifecycle = Phase2ShellAffordanceRendererWiring.project(
            isTerminalPresented: true,
            rendererSelection: .init(backend: .ghosttyFullSurface, fallback: nil),
            terminalSessionID: sessionID,
            terminalRequestID: requestID,
            terminalLifecycleState: .running(
                requestID: shellAffordanceUUID(65),
                processIdentifier: 5_104
            ),
            transcriptEvents: [event],
            bindingCoordinate: coordinate,
            mediatedCoordinate: coordinate
        )
        XCTAssertNil(mismatchedLifecycle.fullSurfaceCoordinate)
        XCTAssertEqual(mismatchedLifecycle.pollingOwner, .unselected)
        XCTAssertEqual(mismatchedLifecycle.terminalCallbackAuthority, .unavailable)

        for invalidLifecycle in [
            Phase2HumanPTYSessionState.running(
                requestID: requestID,
                processIdentifier: 0
            ),
            .prepared(requestID: requestID),
        ] {
            let invalidAuthority = Phase2ShellAffordanceRendererWiring.project(
                isTerminalPresented: true,
                rendererSelection: .init(backend: .ghosttyFullSurface, fallback: nil),
                terminalSessionID: sessionID,
                terminalRequestID: requestID,
                terminalLifecycleState: invalidLifecycle,
                transcriptEvents: [event],
                bindingCoordinate: coordinate,
                mediatedCoordinate: coordinate
            )
            XCTAssertNil(invalidAuthority.fullSurfaceCoordinate)
            XCTAssertEqual(invalidAuthority.pollingOwner, .unselected)
            XCTAssertEqual(invalidAuthority.terminalCallbackAuthority, .unavailable)
        }
    }

    func testGhosttyVTRendererConsumesRawBytesWhenModuleIsAvailable() throws {
        let terminalBytes = Array("prompt\u{0000}keep-nul\r\u{1B}[Kresult\n\u{1B}[31mred\u{1B}[0m\n".utf8)
        let rendered = Phase2GhosttyVTTranscriptRenderer.renderPlainText(
            bytes: terminalBytes,
            columns: 80,
            rows: 8
        )

        #if canImport(GhosttyVt)
        let text = try XCTUnwrap(rendered)
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertTrue(text.contains("result"))
        XCTAssertTrue(text.contains("red"))
        #else
        XCTAssertNil(rendered)
        #endif
    }
}

private func shellAffordanceUUID(_ value: UInt8) -> UUID {
    UUID(uuid: (value, value, value, value, value, value, value, value, value, value, value, value, value, value, value, value))
}
