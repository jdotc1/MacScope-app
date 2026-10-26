import Combine
import XCTest
import Security

@testable import MacScope

@MainActor
final class WorkspaceStorePhase2ShellSessionTests: XCTestCase {
    func testPendingPastePermitsNonblockingOutputDrainBetweenWrites() async throws {
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let sessionID = UUID(), requestID = UUID()
        store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
        let pasteTicket = UUID()
        store.phase2ShellPendingControls.append(pasteTicket)
        defer { store.phase2ShellPendingControls.removeAll { $0 == pasteTicket } }
        await transport.enqueue(storeShellAcceptedResponse(commandID: nil, command: .pollTranscript,
            sessionID: sessionID, requestID: requestID,
            transcriptEvents: [storeShellWireEvent(sessionID: sessionID, sequence: 1, source: .broker,
                payload: .output(stream: .standardOutput, bytes: Array("echo".utf8)))], nextTranscriptSequence: 2))
        let outcome = await store.pollPhase2ShellTranscript(timeoutMilliseconds: 500)
        XCTAssertNotNil(outcome)
        let request = try await transport.lastPollPayload()
        XCTAssertEqual(request?.timeoutMilliseconds, 0)
        XCTAssertEqual(store.phase2ShellPendingControls, [pasteTicket])
    }

    func testPartialPasteRetriesOnlyRemainderAndAllowsInterruptBetweenChunks() async throws {
        let transport = GatedStoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let sessionID = UUID(), requestID = UUID()
        store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
        let paste = Task { @MainActor in await store.writePhase2ShellInput(Array("abcdef".utf8)) }
        let first = await transport.nextRequest()
        let interrupt = Task { @MainActor in await store.signalPhase2ShellSession(.interrupt) }
        await Task.yield()
        await transport.complete(.init(commandID: first.commandID, command: .writeInput, status: .partial,
            sessionID: sessionID, requestID: requestID, bytesWritten: 2,
            transcriptEvents: [storeShellWireEvent(sessionID: sessionID, sequence: 1, source: .human,
                payload: .input(Array("ab".utf8)))], nextTranscriptSequence: 2), for: first.commandID)
        let signal = await transport.nextRequest()
        XCTAssertEqual(signal.command, .sendSignal)
        await transport.complete(.init(commandID: signal.commandID, command: .sendSignal, status: .accepted,
            sessionID: sessionID, requestID: requestID), for: signal.commandID)
        await interrupt.value
        let second = await transport.nextRequest()
        XCTAssertEqual(try MacScope.Phase2ShellBrokerWireCodec.decodeWriteInputRequest(second.payload).bytes, Array("cdef".utf8))
        XCTAssertNotEqual(first.commandID, second.commandID)
        await transport.complete(.init(commandID: second.commandID, command: .writeInput, status: .accepted,
            sessionID: sessionID, requestID: requestID, bytesWritten: 4,
            transcriptEvents: [storeShellWireEvent(sessionID: sessionID, sequence: 2, source: .human,
                payload: .input(Array("cdef".utf8)))], nextTranscriptSequence: 3), for: second.commandID)
        let completed = await paste.value
        XCTAssertTrue(completed)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload),
                       [.input(Array("ab".utf8)), .input(Array("cdef".utf8))])
        XCTAssertNil(store.phase2ShellSession.lastError)
    }

    func testFatalWritePublishesDeliveredPrefixWithoutRetry() async throws {
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let sessionID = UUID(), requestID = UUID()
        store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
        await transport.enqueue(.init(commandID: nil, command: .writeInput, status: .failed,
            sessionID: sessionID, requestID: requestID, bytesWritten: 2,
            transcriptEvents: [storeShellWireEvent(sessionID: sessionID, sequence: 1, source: .human,
                payload: .input(Array("ab".utf8)))], nextTranscriptSequence: 2, issues: ["EIO"]))
        let completed = await store.writePhase2ShellInput(Array("abcdef".utf8))
        XCTAssertFalse(completed)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload), [.input(Array("ab".utf8))])
        XCTAssertEqual(store.phase2ShellSession.lastBytesWritten, 2)
        XCTAssertTrue(store.phase2ShellSession.lastError?.contains("EIO") == true)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testZeroProgressPasteYieldsToStopWithoutResendingPrefix() async throws {
        let transport = GatedStoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let sessionID = UUID(), requestID = UUID()
        store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
        let paste = Task { @MainActor in await store.writePhase2ShellInput(Array("abc".utf8)) }
        let first = await transport.nextRequest()
        let stop = Task { @MainActor in await store.cleanupPhase2ShellSession(reason: "userCancel") }
        await Task.yield()
        await transport.complete(.init(commandID: first.commandID, command: .writeInput, status: .partial,
            sessionID: sessionID, requestID: requestID, bytesWritten: 0), for: first.commandID)
        let cleanup = await transport.nextRequest()
        XCTAssertEqual(cleanup.command, .cleanupProcess)
        await transport.complete(.init(commandID: cleanup.commandID, command: .cleanupProcess, status: .accepted,
            sessionID: sessionID, requestID: requestID, processIdentifier: 901,
            observedProcessAbsent: true, outcome: "canceled"), for: cleanup.commandID)
        await stop.value
        XCTAssertFalse(store.phase2ShellSession.isRunning)
        let completed = await paste.value
        XCTAssertFalse(completed)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 2)
    }

    func testStoreLaunchWritePollAndCleanupOwnBrokerBackedSessionState() async throws {
        let sessionID = storeShellUUID(1)
        let requestID = storeShellUUID(2)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let plan = store.makePhase2ShellLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/zsh"
        )

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .launchProcess,
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: 64
        ))
        await store.launchPhase2ShellSession(plan: plan)

        XCTAssertEqual(store.phase2ShellSession.snapshot?.state, .running(requestID: requestID, processIdentifier: 64))
        XCTAssertNil(store.phase2ShellSession.lastError)
        XCTAssertFalse(store.phase2ShellSession.isCommandInFlight)

        let inputBytes = storeShellBytes("pwd\n")
        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .writeInput,
            sessionID: sessionID,
            requestID: requestID,
            bytesWritten: inputBytes.count,
            transcriptEvents: [
                storeShellWireEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(inputBytes)
                ),
            ],
            nextTranscriptSequence: 2
        ))
        await store.writePhase2ShellInput(inputBytes)

        XCTAssertEqual(store.phase2ShellSession.lastBytesWritten, inputBytes.count)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.sequence), [1])

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .pollTranscript,
            sessionID: sessionID,
            requestID: requestID,
            transcriptEvents: [
                storeShellWireEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: storeShellBytes("/tmp\n"))
                ),
            ],
            nextTranscriptSequence: 3
        ))
        await store.pollPhase2ShellTranscript(maximumEvents: 8, maximumBytes: 256, timeoutMilliseconds: 5)

        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.sequence), [1, 2])
        let maybePollPayload = try await transport.lastPollPayload()
        let pollPayload = try XCTUnwrap(maybePollPayload)
        XCTAssertEqual(pollPayload.afterSequence, 1)
        XCTAssertEqual(pollPayload.maximumEvents, 8)
        XCTAssertEqual(pollPayload.maximumBytes, 256)
        XCTAssertEqual(pollPayload.timeoutMilliseconds, 5)

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .cleanupProcess,
            sessionID: sessionID,
            requestID: requestID,
            observedProcessAbsent: true,
            outcome: "canceled"
        ))
        await store.cleanupPhase2ShellSession()

        XCTAssertEqual(store.phase2ShellSession.snapshot?.state, .terminal(outcome: .canceled))
        XCTAssertTrue(store.phase2ShellSession.isTerminal)
        XCTAssertNil(store.phase2ShellSession.lastError)
    }

    func testApprovedShellBrokerPTYProposalWritesExactReviewedCommandIntoActiveBrokerSession() async throws {
        let sessionID = storeShellUUID(11)
        let requestID = storeShellUUID(12)
        let proposalID = storeShellUUID(13)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["hello world", "it's ok"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )

        store.stagePhase2AIShellProposalForReview(proposal)
        let rejected = await store.executeApprovedPhase2AIShellProposalShellBrokerPTY(proposalID: proposalID)

        XCTAssertEqual(rejected.disposition, .authorizationRejected)
        let requestsAfterRejectedExecution = await transport.recordedRequests()
        XCTAssertEqual(requestsAfterRejectedExecution.count, 0)

        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .running(requestID: requestID, processIdentifier: 777),
                launchPlan: Phase2HumanPTYLaunchPlan(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/zsh",
                    initialSize: Phase2HumanPTYTerminalSize(columns: 80, rows: 24)
                ),
                transcriptEvents: [],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        let approved = store.approvePhase2AIShellProposalForFutureShellBrokerPTY(proposalID: proposalID)
        XCTAssertTrue(approved.canExecuteShellBrokerPTY)

        let commandText = "'/bin/echo' 'hello world' 'it'\\''s ok'"
        let commandBytes = storeShellBytes("\(commandText)\n")
        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .writeInput,
            sessionID: sessionID,
            requestID: requestID,
            lifecycleState: "running",
            processIdentifier: 777,
            bytesWritten: commandBytes.count,
            transcriptEvents: [
                storeShellWireEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(commandBytes)
                ),
            ],
            nextTranscriptSequence: 2
        ))

        let dispatched = await store.executeApprovedPhase2AIShellProposalShellBrokerPTY(proposalID: proposalID)

        XCTAssertEqual(dispatched.disposition, .dispatched)
        XCTAssertEqual(dispatched.proposalID, proposalID)
        XCTAssertEqual(dispatched.sessionID, sessionID)
        XCTAssertEqual(dispatched.requestID, requestID)
        XCTAssertEqual(dispatched.commandText, commandText)
        XCTAssertEqual(dispatched.bytesWritten, commandBytes.count)
        XCTAssertNil(dispatched.failureMessage)
        let maybeWritePayload = try await transport.lastWriteInputPayload()
        let writePayload = try XCTUnwrap(maybeWritePayload)
        XCTAssertEqual(writePayload.sessionID, sessionID)
        XCTAssertEqual(writePayload.requestID, requestID)
        XCTAssertEqual(writePayload.bytes, commandBytes)
        XCTAssertEqual(store.phase2ShellSession.lastBytesWritten, commandBytes.count)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload), [.input(commandBytes)])
        XCTAssertEqual(store.phase2AIShellBrokerPTYExecutionResults.map(\.disposition), [.dispatched, .authorizationRejected])
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, 3)
        let providerVisibleRecord = try XCTUnwrap(store.phase2RuntimeAuthorityRecords.first)
        XCTAssertEqual(providerVisibleRecord.sessionID, dispatched.id)
        XCTAssertEqual(
            providerVisibleRecord.surfaces,
            [.terminalEmulation, .shellBrokerPTYReuse, .providerVisibleShellExecution]
        )
        XCTAssertEqual(providerVisibleRecord.ptyReusePolicy, .shellBrokerSession)
        XCTAssertTrue(providerVisibleRecord.providerVisibleShellExecutionEnabled)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords[1].surfaces, [.terminalEmulation, .shellBrokerPTYReuse])
        XCTAssertFalse(store.phase2RuntimeAuthorityRecords[1].providerVisibleShellExecutionEnabled)
        XCTAssertFalse(store.phase2RuntimeAuthorityRecords[2].providerVisibleShellExecutionEnabled)
        let providerVisibleEvidence = try XCTUnwrap(store.phase2ProviderVisibleShellExecutionEvidenceText())
        XCTAssertTrue(providerVisibleEvidence.contains("Execution surface: ShellBroker PTY"), providerVisibleEvidence)
        XCTAssertTrue(providerVisibleEvidence.contains("Disposition: dispatched"), providerVisibleEvidence)
        XCTAssertTrue(providerVisibleEvidence.contains("Command written to PTY: \(commandText)"), providerVisibleEvidence)
        XCTAssertTrue(
            providerVisibleEvidence.contains("Bytes accepted by ShellBroker: \(commandBytes.count)"),
            providerVisibleEvidence
        )

        let replay = await store.executeApprovedPhase2AIShellProposalShellBrokerPTY(
            proposalID: proposalID
        )
        XCTAssertEqual(replay.disposition, .authorizationRejected)
        let requestsAfterReplay = await transport.recordedRequests()
        XCTAssertEqual(requestsAfterReplay.count, 1)
        XCTAssertEqual(store.phase2AIShellProposalReview.humanDecision, .consumed)

        let reapproved = store.approvePhase2AIShellProposalForFutureShellBrokerPTY(
            proposalID: proposalID
        )
        XCTAssertEqual(reapproved.humanDecision, .approvedForFutureShellBrokerPTY)
        XCTAssertFalse(providerVisibleEvidence.contains("authorizationRejected"), providerVisibleEvidence)
        XCTAssertFalse(providerVisibleEvidence.contains("processIdentifier"), providerVisibleEvidence)
    }

    func testApprovedShellBrokerPTYProposalRejectsPartialBrokerWriteEvidence() async throws {
        let sessionID = storeShellUUID(14)
        let requestID = storeShellUUID(15)
        let proposalID = storeShellUUID(16)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["must be exact"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )
        store.installPhase2ShellSessionProjection(
            storeRunningProjection(sessionID: sessionID, requestID: requestID)
        )
        store.stagePhase2AIShellProposalForReview(proposal)
        _ = store.approvePhase2AIShellProposalForFutureShellBrokerPTY(proposalID: proposalID)

        let commandBytes = storeShellBytes("'/bin/echo' 'must be exact'\n")
        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .writeInput,
            sessionID: sessionID,
            requestID: requestID,
            bytesWritten: commandBytes.count - 1
        ))

        let result = await store.executeApprovedPhase2AIShellProposalShellBrokerPTY(
            proposalID: proposalID
        )

        XCTAssertEqual(result.disposition, .brokerRejected)
        XCTAssertNil(result.bytesWritten)
        XCTAssertEqual(result.failureMessage, "writeByteCountMismatch")
        XCTAssertNil(store.phase2ShellSession.lastBytesWritten)
        XCTAssertEqual(store.phase2AIShellProposalReview.humanDecision, .consumed)
        XCTAssertFalse(
            store.phase2RuntimeAuthorityRecords.contains(
                where: \.providerVisibleShellExecutionEnabled
            )
        )
        let maybePayload = try await transport.lastWriteInputPayload()
        let payload = try XCTUnwrap(maybePayload)
        XCTAssertEqual(payload.bytes, commandBytes)
    }

    func testApprovedShellBrokerPTYProposalSanitizesBrokerRejectionDetails() async throws {
        let sessionID = storeShellUUID(17)
        let requestID = storeShellUUID(18)
        let proposalID = storeShellUUID(19)
        let injectedUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let injectedIssue = "broker-private-detail id=\(injectedUUID) path=/private/tmp/sentinel"
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["safe"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )
        store.installPhase2ShellSessionProjection(
            storeRunningProjection(sessionID: sessionID, requestID: requestID)
        )
        store.stagePhase2AIShellProposalForReview(proposal)
        _ = store.approvePhase2AIShellProposalForFutureShellBrokerPTY(proposalID: proposalID)
        await transport.enqueue(MacScope.Phase2ShellBrokerCommandResponse(
            commandID: nil,
            command: .writeInput,
            status: .rejected,
            sessionID: sessionID,
            requestID: requestID,
            issues: [injectedIssue]
        ))

        let result = await store.executeApprovedPhase2AIShellProposalShellBrokerPTY(
            proposalID: proposalID
        )

        XCTAssertEqual(result.disposition, .brokerRejected)
        XCTAssertEqual(result.failureMessage, "brokerRejected")
        let publicFailure = try XCTUnwrap(result.failureMessage)
        XCTAssertFalse(publicFailure.contains(injectedUUID.uuidString))
        XCTAssertFalse(publicFailure.contains(injectedIssue))
        XCTAssertFalse(publicFailure.contains("/private/tmp/sentinel"))
        XCTAssertEqual(
            store.phase2AIShellBrokerPTYExecutionResults.first?.failureMessage,
            "brokerRejected"
        )
    }

    func testStoreMaintainsShellBrokerPTYBindingAndPersistsRuntimeAuthorityEvidence() async throws {
        let sessionID = storeShellUUID(100)
        let requestID = storeShellUUID(101)
        let terminalSurfaceID = storeShellUUID(102)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport, terminalSurfaceID: terminalSurfaceID)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let plan = store.makePhase2ShellLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/zsh",
            initialSize: Phase2HumanPTYTerminalSize(columns: 120, rows: 32)
        )

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .launchProcess,
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: 64
        ))
        await store.launchPhase2ShellSession(plan: plan)

        var binding = try XCTUnwrap(store.phase2ShellBrokerPTYBinding)
        XCTAssertTrue(binding.isStructurallyValid)
        XCTAssertEqual(binding.terminalSurfaceID, terminalSurfaceID)
        XCTAssertEqual(binding.sessionID, sessionID)
        XCTAssertEqual(binding.requestID, requestID)
        XCTAssertEqual(binding.processIdentifier, 64)
        XCTAssertEqual(binding.terminalSize, Phase2HumanPTYTerminalSize(columns: 120, rows: 32))
        XCTAssertEqual(binding.terminalBackend, .ghosttyLib)
        XCTAssertEqual(binding.ptyReusePolicy, .shellBrokerSession)
        XCTAssertEqual(binding.debuggerAuthorityPolicy, .disabled)
        XCTAssertEqual(binding.nextTranscriptSequence, 1)

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .resizeTerminal,
            sessionID: sessionID,
            requestID: requestID,
            lifecycleState: "running",
            processIdentifier: 64,
            transcriptEvents: [
                storeShellWireEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .resize(columns: 132, rows: 44)
                ),
            ],
            nextTranscriptSequence: 2
        ))
        await store.resizePhase2ShellSession(to: Phase2HumanPTYTerminalSize(columns: 132, rows: 44))

        binding = try XCTUnwrap(store.phase2ShellBrokerPTYBinding)
        XCTAssertEqual(binding.terminalSize, Phase2HumanPTYTerminalSize(columns: 132, rows: 44))
        XCTAssertEqual(binding.nextTranscriptSequence, 2)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload), [
            .resize(columns: 132, rows: 44),
        ])

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .cleanupProcess,
            sessionID: sessionID,
            requestID: requestID,
            observedProcessAbsent: true,
            outcome: "canceled"
        ))
        await store.cleanupPhase2ShellSession()

        XCTAssertNil(store.phase2ShellBrokerPTYBinding)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.state, .terminal(outcome: .canceled))
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, 3)
        XCTAssertTrue(store.phase2RuntimeAuthorityRecords.allSatisfy {
            $0.surfaces == [.terminalEmulation, .shellBrokerPTYReuse]
                && $0.terminalBackend == .ghosttyLib
                && $0.ptyReusePolicy == .shellBrokerSession
                && $0.debuggerAuthorityPolicy == .disabled
                && !$0.providerVisibleShellExecutionEnabled
        })

        let persisted = try store.saveWorkspace(
            to: database,
            now: Date(timeIntervalSince1970: 7_000),
            documentID: storeShellUUID(103)
        )
        let persistedWorkspaceID = try XCTUnwrap(persisted.workspace.id)
        let reopened = try XCTUnwrap(WorkspaceStore.restored(workspaceID: persistedWorkspaceID, from: database))
        XCTAssertNil(reopened.phase2ShellBrokerPTYBinding)
        XCTAssertEqual(reopened.phase2RuntimeAuthorityRecords.count, 3)
        XCTAssertEqual(Set(reopened.phase2RuntimeAuthorityRecords.map(\.sessionID)), [sessionID])
    }

    func testStorePersistsRunningShellSessionToDatabaseAsHistoricalInactiveContext() async throws {
        let sessionID = storeShellUUID(104)
        let requestID = storeShellUUID(105)
        let terminalSurfaceID = storeShellUUID(106)
        let documentID = storeShellUUID(107)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport, terminalSurfaceID: terminalSurfaceID)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let plan = store.makePhase2ShellLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/zsh",
            arguments: ["-l"],
            environment: ["TERM": "xterm-256color"],
            workingDirectoryPath: "/tmp",
            initialSize: Phase2HumanPTYTerminalSize(columns: 132, rows: 44)
        )

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .launchProcess,
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: 910
        ))
        await store.launchPhase2ShellSession(plan: plan)

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .writeInput,
            sessionID: sessionID,
            requestID: requestID,
            lifecycleState: "running",
            processIdentifier: 910,
            bytesWritten: storeShellBytes("pwd\n").count,
            transcriptEvents: [
                storeShellWireEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(storeShellBytes("pwd\n"))
                ),
            ],
            nextTranscriptSequence: 2
        ))
        await store.writePhase2ShellInput(storeShellBytes("pwd\n"))

        XCTAssertEqual(store.phase2ShellBrokerPTYBinding?.sessionID, sessionID)
        let persisted = try store.saveWorkspace(
            to: database,
            now: Date(timeIntervalSince1970: 7_100),
            documentID: documentID
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)
        let persistedShell = try XCTUnwrap(try database.phase2ShellSessionRecord(workspaceID: workspaceID))
        XCTAssertEqual(persistedShell.documentID, documentID)
        XCTAssertEqual(persistedShell.shellSession.sessionID, sessionID)
        XCTAssertEqual(persistedShell.shellSession.runningRequestID, requestID)
        XCTAssertEqual(persistedShell.shellSession.runningProcessIdentifier, 910)
        XCTAssertEqual(persistedShell.shellSession.nextTranscriptSequence, 2)

        let reopened = try XCTUnwrap(WorkspaceStore.restored(workspaceID: workspaceID, from: database))
        let reopenedSnapshot = try XCTUnwrap(reopened.phase2ShellSession.snapshot)
        XCTAssertEqual(reopenedSnapshot.sessionID, sessionID)
        XCTAssertEqual(reopenedSnapshot.state, .terminal(outcome: .outcomeUnknown))
        XCTAssertEqual(reopenedSnapshot.launchPlan?.arguments, ["-l"])
        XCTAssertEqual(reopenedSnapshot.launchPlan?.environment, ["TERM": "xterm-256color"])
        XCTAssertEqual(reopenedSnapshot.launchPlan?.workingDirectoryPath, "/tmp")
        XCTAssertEqual(reopenedSnapshot.launchPlan?.initialSize, Phase2HumanPTYTerminalSize(columns: 132, rows: 44))
        XCTAssertEqual(reopenedSnapshot.transcriptEvents.map(\.payload), [.input(storeShellBytes("pwd\n"))])
        XCTAssertEqual(reopened.phase2ShellSession.lastError, Phase2WorkspaceShellSessionProjection.restoredInactiveMessage)
        XCTAssertTrue(reopened.phase2ShellSession.isRestoredInactiveContext)
        XCTAssertNil(reopened.phase2ShellBrokerPTYBinding)
        XCTAssertTrue(reopened.phase2ShellSession.lastError?.contains("process and PTY closed") == true)
    }

    func testStoreLaunchCarriesExplicitWorkingDirectoryIntoBrokerPayload() async throws {
        let sessionID = storeShellUUID(60)
        let requestID = storeShellUUID(61)
        let workingDirectoryPath = FileManager.default.temporaryDirectory.path
        let initialSize = Phase2HumanPTYTerminalSize(columns: 132, rows: 44)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let plan = store.makePhase2ShellLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/sh",
            arguments: ["-lc", "printf macscope"],
            environment: ["MACSCOPE_SHELL_MODE": "test"],
            workingDirectoryPath: workingDirectoryPath,
            initialSize: initialSize
        )

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .launchProcess,
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: 81
        ))
        await store.launchPhase2ShellSession(plan: plan)

        let maybeLaunchPayload = try await transport.lastLaunchPayload()
        let launchPayload = try XCTUnwrap(maybeLaunchPayload)
        XCTAssertEqual(launchPayload.executablePath, "/bin/sh")
        XCTAssertEqual(launchPayload.arguments, ["-lc", "printf macscope"])
        XCTAssertEqual(launchPayload.environment, ["MACSCOPE_SHELL_MODE": "test"])
        XCTAssertEqual(launchPayload.workingDirectoryPath, workingDirectoryPath)
        XCTAssertEqual(launchPayload.columns, 132)
        XCTAssertEqual(launchPayload.rows, 44)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.launchPlan?.workingDirectoryPath, workingDirectoryPath)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.launchPlan?.arguments, ["-lc", "printf macscope"])
        XCTAssertEqual(store.phase2ShellSession.snapshot?.launchPlan?.environment, ["MACSCOPE_SHELL_MODE": "test"])
        XCTAssertEqual(store.phase2ShellSession.snapshot?.launchPlan?.initialSize, initialSize)
        XCTAssertNil(store.phase2ShellSession.lastError)
    }

    func testStoreRelaunchUsesSavedPlanWithFreshSessionAndRequestIDs() async throws {
        let restoredSessionID = storeShellUUID(80)
        let restoredRequestID = storeShellUUID(81)
        let relaunchedSessionID = storeShellUUID(82)
        let relaunchedRequestID = storeShellUUID(83)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let transcriptLimits = Phase2HumanPTYTranscriptLimits(
            maximumEvents: 128,
            maximumEventBytes: 4_096,
            maximumCumulativeBytes: 65_536
        )

        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: restoredSessionID,
                state: .terminal(outcome: .outcomeUnknown),
                launchPlan: Phase2HumanPTYLaunchPlan(
                    sessionID: restoredSessionID,
                    requestID: restoredRequestID,
                    executablePath: "/bin/zsh",
                    arguments: ["-lc", "pwd"],
                    environment: ["TERM": "xterm-256color"],
                    workingDirectoryPath: "/tmp",
                    initialSize: Phase2HumanPTYTerminalSize(columns: 132, rows: 44),
                    transcriptLimits: transcriptLimits
                ),
                transcriptEvents: [],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: Phase2WorkspaceShellSessionProjection.restoredInactiveMessage,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .launchProcess,
            sessionID: relaunchedSessionID,
            requestID: relaunchedRequestID,
            processIdentifier: 902
        ))
        await store.relaunchPhase2ShellSession(
            sessionID: relaunchedSessionID,
            requestID: relaunchedRequestID
        )

        let maybeLaunchPayload = try await transport.lastLaunchPayload()
        let launchPayload = try XCTUnwrap(maybeLaunchPayload)
        XCTAssertEqual(launchPayload.sessionID, relaunchedSessionID)
        XCTAssertEqual(launchPayload.requestID, relaunchedRequestID)
        XCTAssertNotEqual(launchPayload.sessionID, restoredSessionID)
        XCTAssertNotEqual(launchPayload.requestID, restoredRequestID)
        XCTAssertEqual(launchPayload.executablePath, "/bin/zsh")
        XCTAssertEqual(launchPayload.arguments, ["-lc", "pwd"])
        XCTAssertEqual(launchPayload.environment, ["TERM": "xterm-256color"])
        XCTAssertEqual(launchPayload.workingDirectoryPath, "/tmp")
        XCTAssertEqual(launchPayload.columns, 132)
        XCTAssertEqual(launchPayload.rows, 44)
        XCTAssertEqual(launchPayload.maximumTranscriptEvents, transcriptLimits.maximumEvents)
        XCTAssertEqual(launchPayload.maximumTranscriptEventBytes, transcriptLimits.maximumEventBytes)
        XCTAssertEqual(launchPayload.maximumTranscriptCumulativeBytes, transcriptLimits.maximumCumulativeBytes)

        let snapshot = try XCTUnwrap(store.phase2ShellSession.snapshot)
        XCTAssertEqual(snapshot.sessionID, relaunchedSessionID)
        XCTAssertEqual(snapshot.state, .running(requestID: relaunchedRequestID, processIdentifier: 902))
        XCTAssertEqual(snapshot.launchPlan?.sessionID, relaunchedSessionID)
        XCTAssertEqual(snapshot.launchPlan?.requestID, relaunchedRequestID)
        XCTAssertEqual(snapshot.launchPlan?.executablePath, "/bin/zsh")
        XCTAssertEqual(snapshot.launchPlan?.arguments, ["-lc", "pwd"])
        XCTAssertEqual(snapshot.launchPlan?.environment, ["TERM": "xterm-256color"])
        XCTAssertEqual(snapshot.launchPlan?.workingDirectoryPath, "/tmp")
        XCTAssertEqual(snapshot.launchPlan?.initialSize, Phase2HumanPTYTerminalSize(columns: 132, rows: 44))
        XCTAssertEqual(snapshot.launchPlan?.transcriptLimits, transcriptLimits)
        XCTAssertNil(store.phase2ShellSession.lastError)
    }

    func testStoreRelaunchWithoutSavedPlanRejectsBeforeBrokerDispatch() async throws {
        let relaunchedSessionID = storeShellUUID(84)
        let relaunchedRequestID = storeShellUUID(85)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)

        await store.relaunchPhase2ShellSession(
            sessionID: relaunchedSessionID,
            requestID: relaunchedRequestID
        )

        let recordedRequests = await transport.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 0)
        XCTAssertEqual(
            store.phase2ShellSession.lastError,
            "No Phase 2 shell launch plan is available to relaunch."
        )
    }

    func testStoreForgetRestoredShellContextClearsPackageStateWithoutBrokerDispatch() async throws {
        let sessionID = storeShellUUID(86)
        let requestID = storeShellUUID(87)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
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
                        payload: .input(storeShellBytes("pwd\n"))
                    ),
                ],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: Phase2WorkspaceShellSessionProjection.restoredInactiveMessage,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        let (parent, packageURL) = try temporaryShellPackageURL("Shell-Forget.mscope")
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: packageURL, now: Date(timeIntervalSince1970: 5_200)))
        XCTAssertFalse(store.isDirty)
        XCTAssertNotNil(try MacScopeDocumentPackage.openPackage(from: packageURL).manifest.session?.phase2ShellSession)

        store.forgetRestoredPhase2ShellSessionContext()

        XCTAssertEqual(store.phase2ShellSession, .inactive)
        XCTAssertTrue(store.isDirty)
        let recordedRequests = await transport.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 0)
        XCTAssertTrue(store.writeDocumentPackage(to: packageURL, now: Date(timeIntervalSince1970: 5_201)))
        XCTAssertFalse(store.isDirty)
        XCTAssertNil(try MacScopeDocumentPackage.openPackage(from: packageURL).manifest.session?.phase2ShellSession)
        XCTAssertEqual(try WorkspaceStore.restoredPackage(from: packageURL).phase2ShellSession, .inactive)
    }

    func testStoreForgetRestoredShellContextIgnoresLiveSessions() async {
        let sessionID = storeShellUUID(88)
        let requestID = storeShellUUID(89)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let runningProjection = Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .running(requestID: requestID, processIdentifier: 1201),
                launchPlan: Phase2HumanPTYLaunchPlan(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/zsh",
                    initialSize: .defaultInteractive
                ),
                transcriptEvents: [],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )
        store.installPhase2ShellSessionProjection(runningProjection)

        store.forgetRestoredPhase2ShellSessionContext()

        XCTAssertEqual(store.phase2ShellSession, runningProjection)
        XCTAssertFalse(store.isDirty)
        let recordedRequests = await transport.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 0)
    }

    func testStoreRejectsInvalidWorkingDirectoryBeforeBrokerDispatch() async throws {
        let sessionID = storeShellUUID(62)
        let requestID = storeShellUUID(63)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let plan = store.makePhase2ShellLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/zsh",
            workingDirectoryPath: "relative"
        )

        await store.launchPhase2ShellSession(plan: plan)

        let recordedRequests = await transport.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 0)
        XCTAssertEqual(
            store.phase2ShellSession.lastError,
            "Invalid Phase 2 shell launch plan: working directory must be absolute (relative)"
        )
    }

    func testStoreRejectsShellInputWithoutActiveSessionBeforeBrokerDispatch() async throws {
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)

        await store.writePhase2ShellInput(storeShellBytes("unsafe\n"))

        let requestCount = await transport.recordedRequests().count
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(store.phase2ShellSession.lastError, "No active Phase 2 shell session.")
        XCTAssertNil(store.phase2ShellSession.snapshot)
    }

    func testStoreRejectsTranscriptPollWithoutActiveSessionBeforeBrokerDispatch() async throws {
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)

        await store.pollPhase2ShellTranscript()

        let requestCount = await transport.recordedRequests().count
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(store.phase2ShellSession.lastError, "No active Phase 2 shell session.")
        XCTAssertNil(store.phase2ShellSession.snapshot)
    }

    func testStoreRejectsTranscriptPollAfterTerminalStateBeforeBrokerDispatch() async throws {
        let sessionID = storeShellUUID(30)
        let requestID = storeShellUUID(31)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .terminal(outcome: .exited(status: 0)),
                launchPlan: Phase2HumanPTYLaunchPlan(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/zsh",
                    initialSize: .defaultInteractive
                ),
                transcriptEvents: [],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        await store.pollPhase2ShellTranscript()

        let requestCount = await transport.recordedRequests().count
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(store.phase2ShellSession.lastError, "Phase 2 shell command pollTranscript requires a running session.")
        XCTAssertTrue(store.phase2ShellSession.isTerminal)
    }

    func testStoreRejectsSecondLaunchWhileSessionIsRunningBeforeBrokerDispatch() async throws {
        let sessionID = storeShellUUID(20)
        let requestID = storeShellUUID(21)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let plan = store.makePhase2ShellLaunchPlan(sessionID: sessionID, requestID: requestID)

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .launchProcess,
            sessionID: sessionID,
            requestID: requestID,
            processIdentifier: 72
        ))
        await store.launchPhase2ShellSession(plan: plan)

        let requestCountAfterFirstLaunch = await transport.recordedRequests().count
        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(22),
            requestID: storeShellUUID(23)
        ))

        let finalRequestCount = await transport.recordedRequests().count
        XCTAssertEqual(finalRequestCount, requestCountAfterFirstLaunch)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.state, .running(requestID: requestID, processIdentifier: 72))
        XCTAssertEqual(store.phase2ShellSession.lastError, "A Phase 2 shell session is already active.")
    }

    func testStoreResizeAndInterruptDispatchThroughActiveBrokerSession() async throws {
        let sessionID = storeShellUUID(40)
        let requestID = storeShellUUID(41)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .running(requestID: requestID, processIdentifier: 512),
                launchPlan: Phase2HumanPTYLaunchPlan(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/zsh",
                    initialSize: .defaultInteractive
                ),
                transcriptEvents: [],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .resizeTerminal,
            sessionID: sessionID,
            requestID: requestID,
            lifecycleState: "running",
            processIdentifier: 512
        ))
        await store.resizePhase2ShellSession(to: Phase2HumanPTYTerminalSize(columns: 100, rows: 32))

        let maybeResizePayload = try await transport.lastResizePayload()
        let resizePayload = try XCTUnwrap(maybeResizePayload)
        XCTAssertEqual(resizePayload.sessionID, sessionID)
        XCTAssertEqual(resizePayload.requestID, requestID)
        XCTAssertEqual(resizePayload.columns, 100)
        XCTAssertEqual(resizePayload.rows, 32)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload), [])

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .sendSignal,
            sessionID: sessionID,
            requestID: requestID,
            lifecycleState: "running",
            processIdentifier: 512
        ))
        await store.signalPhase2ShellSession(.interrupt)

        let maybeSignalPayload = try await transport.lastSignalPayload()
        let signalPayload = try XCTUnwrap(maybeSignalPayload)
        XCTAssertEqual(signalPayload.sessionID, sessionID)
        XCTAssertEqual(signalPayload.requestID, requestID)
        XCTAssertEqual(signalPayload.signal, .interrupt)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload), [])
        XCTAssertNil(store.phase2ShellSession.lastError)
    }

    func testStoreRejectsInvalidResizeBeforeBrokerDispatch() async throws {
        let sessionID = storeShellUUID(70)
        let requestID = storeShellUUID(71)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .running(requestID: requestID, processIdentifier: 901),
                launchPlan: Phase2HumanPTYLaunchPlan(
                    sessionID: sessionID,
                    requestID: requestID,
                    executablePath: "/bin/zsh",
                    initialSize: .defaultInteractive
                ),
                transcriptEvents: [],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        await store.resizePhase2ShellSession(to: Phase2HumanPTYTerminalSize(columns: 0, rows: 32))

        let recordedRequests = await transport.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 0)
        XCTAssertEqual(store.phase2ShellSession.lastError, "Terminal size must be between 1×1 and 1000×1000.")
        XCTAssertEqual(store.phase2ShellSession.snapshot?.state, .running(requestID: requestID, processIdentifier: 901))
    }

    func testStoreReconnectDispatchesAppOwnedResyncAndAcceptsReconnectTranscriptEvent() async throws {
        let sessionID = storeShellUUID(50)
        let requestID = storeShellUUID(51)
        let reconnectID = storeShellUUID(52)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .running(requestID: requestID, processIdentifier: 613),
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
                        source: .broker,
                        payload: .output(stream: .standardOutput, bytes: storeShellBytes("ready\n"))
                    ),
                ],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .reconnectSession,
            sessionID: sessionID,
            requestID: requestID,
            lifecycleState: "running",
            processIdentifier: 613,
            transcriptEvents: [
                storeShellWireEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .app,
                    payload: .reconnect(reconnectID: reconnectID)
                ),
            ],
            nextTranscriptSequence: 3
        ))
        await store.reconnectPhase2ShellSession(
            reconnectID: reconnectID,
            maximumEvents: 12,
            maximumBytes: 512
        )

        let maybeReconnectPayload = try await transport.lastReconnectPayload()
        let reconnectPayload = try XCTUnwrap(maybeReconnectPayload)
        XCTAssertEqual(reconnectPayload.sessionID, sessionID)
        XCTAssertEqual(reconnectPayload.requestID, requestID)
        XCTAssertEqual(reconnectPayload.reconnectID, reconnectID)
        XCTAssertEqual(reconnectPayload.afterSequence, 1)
        XCTAssertEqual(reconnectPayload.maximumEvents, 12)
        XCTAssertEqual(reconnectPayload.maximumBytes, 512)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload), [
            .output(stream: .standardOutput, bytes: storeShellBytes("ready\n")),
            .reconnect(reconnectID: reconnectID),
        ])
        XCTAssertEqual(store.phase2ShellSession.lastAcceptedTranscriptEvents.map(\.payload), [
            .reconnect(reconnectID: reconnectID),
        ])
        XCTAssertNil(store.phase2ShellSession.lastError)
    }

    func testStoreReconnectAcceptsTerminalEvidenceWhenBrokerObservedNaturalExit() async throws {
        let sessionID = storeShellUUID(54)
        let requestID = storeShellUUID(55)
        let reconnectID = storeShellUUID(56)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .running(requestID: requestID, processIdentifier: 613),
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
                        source: .broker,
                        payload: .output(stream: .standardOutput, bytes: storeShellBytes("done\n"))
                    ),
                ],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        await transport.enqueue(storeShellAcceptedResponse(
            commandID: nil,
            command: .reconnectSession,
            sessionID: sessionID,
            requestID: requestID,
            lifecycleState: "terminal",
            processIdentifier: 613,
            transcriptEvents: [
                storeShellWireEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .terminal(.exited(status: 7))
                ),
            ],
            nextTranscriptSequence: 3
        ))
        await store.reconnectPhase2ShellSession(
            reconnectID: reconnectID,
            maximumEvents: 12,
            maximumBytes: 512
        )

        let maybeReconnectPayload = try await transport.lastReconnectPayload()
        let reconnectPayload = try XCTUnwrap(maybeReconnectPayload)
        XCTAssertEqual(reconnectPayload.sessionID, sessionID)
        XCTAssertEqual(reconnectPayload.requestID, requestID)
        XCTAssertEqual(reconnectPayload.reconnectID, reconnectID)
        XCTAssertEqual(reconnectPayload.afterSequence, 1)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.state, .terminal(outcome: .exited(status: 7)))
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload), [
            .output(stream: .standardOutput, bytes: storeShellBytes("done\n")),
            .terminal(.exited(status: 7)),
        ])
        XCTAssertEqual(store.phase2ShellSession.lastAcceptedTranscriptEvents.map(\.payload), [
            .terminal(.exited(status: 7)),
        ])
        XCTAssertNil(store.phase2ShellSession.lastError)
    }

    func testSurfaceGenerationHighWaterSurvivesRetirementAndViewRecreation() throws {
        let sessionID = storeShellUUID(60)
        let requestID = storeShellUUID(61)
        let store = makeStore(transport: StoreShellBrokerTransport())
        store.installPhase2ShellSessionProjection(
            storeRunningProjection(sessionID: sessionID, requestID: requestID)
        )

        let first = try XCTUnwrap(store.bindPhase2ShellSurface(generation: 4))
        store.retirePhase2ShellSurface(first)

        XCTAssertNil(store.bindPhase2ShellSurface(generation: 1))
        XCTAssertNil(store.bindPhase2ShellSurface(generation: 4))
        let replacement = try XCTUnwrap(store.bindPhase2ShellSurface(generation: 5))
        XCTAssertEqual(replacement.sessionID, sessionID)
        XCTAssertEqual(replacement.requestID, requestID)
        XCTAssertEqual(replacement.generation, 5)
        XCTAssertEqual(store.phase2ShellSession.surfaceGenerationHighWater, replacement)
    }

    func testInputWaitsForPollAndReservesPriorityWithoutRetryingBytes() async throws {
        let sessionID = storeShellUUID(860)
        let requestID = storeShellUUID(861)
        let transport = GatedStoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
        let poll = Task { await store.pollPhase2ShellTranscript() }
        let pollRequest = await transport.nextRequest()
        let bytes = storeShellBytes("exact-once\n")
        let input = Task { await store.writePhase2ShellInput(bytes) }
        while store.phase2ShellPendingControls.isEmpty { await Task.yield() }
        let nextPoll = await store.pollPhase2ShellTranscript()
        XCTAssertNil(nextPoll)
        await transport.complete(storeShellAcceptedResponse(commandID: pollRequest.commandID,
            command: .pollTranscript, sessionID: sessionID, requestID: requestID), for: pollRequest.commandID)
        _ = await poll.value
        let write = await transport.nextRequest()
        XCTAssertEqual(write.command, .writeInput)
        let payload = try MacScope.Phase2ShellBrokerWireCodec.decodeWriteInputRequest(write.payload)
        XCTAssertEqual(payload.bytes, bytes)
        await transport.complete(storeShellAcceptedResponse(commandID: write.commandID,
            command: .writeInput, sessionID: sessionID, requestID: requestID,
            bytesWritten: bytes.count), for: write.commandID)
        let accepted = await input.value
        XCTAssertTrue(accepted)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 2)
        XCTAssertTrue(store.phase2ShellPendingControls.isEmpty)
    }

    func testCancelledOrReplacedWaitingInputNeverDispatches() async throws {
        for replace in [false, true] {
            let sessionID = storeShellUUID(870)
            let requestID = storeShellUUID(871)
            let transport = GatedStoreShellBrokerTransport()
            let store = makeStore(transport: transport)
            store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
            let poll = Task { await store.pollPhase2ShellTranscript() }
            let request = await transport.nextRequest()
            let input = Task { await store.writePhase2ShellInput(storeShellBytes("retained-draft\n")) }
            while store.phase2ShellPendingControls.isEmpty { await Task.yield() }
            if replace {
                store.installPhase2ShellSessionProjection(storeRunningProjection(
                    sessionID: storeShellUUID(872), requestID: storeShellUUID(873)))
            } else { input.cancel() }
            let accepted = await input.value
            XCTAssertFalse(accepted)
            let count = await transport.requestCount()
            XCTAssertEqual(count, 1)
            XCTAssertTrue(store.phase2ShellPendingControls.isEmpty)
            await transport.complete(storeShellAcceptedResponse(commandID: request.commandID,
                command: .pollTranscript, sessionID: sessionID, requestID: requestID), for: request.commandID)
            _ = await poll.value
        }
    }

    func testEmptyPollRetainsAdmissionWithoutPublishingOrMutatingDocument() async throws {
        let sessionID = storeShellUUID(920)
        let requestID = storeShellUUID(921)
        let transport = GatedStoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
        let initialGeneration = store.mutationGeneration
        let initialAuthorityCount = store.phase2RuntimeAuthorityRecords.count
        let initialBinding = store.phase2ShellBrokerPTYBinding
        var notifications = 0
        let subscription = store.objectWillChange.sink { notifications += 1 }
        defer { withExtendedLifetime(subscription) {} }
        let first = Task { await store.pollPhase2ShellTranscript() }
        let request = await transport.nextRequest()
        XCTAssertTrue(store.phase2ShellSession.isCommandInFlight)
        XCTAssertEqual(store.phase2ShellSession.inFlightOperation?.commandID, request.commandID)
        XCTAssertEqual(notifications, 0)
        await transport.complete(storeShellAcceptedResponse(commandID: request.commandID,
            command: .pollTranscript, sessionID: sessionID, requestID: requestID), for: request.commandID)
        _ = await first.value
        XCTAssertFalse(store.phase2ShellSession.isCommandInFlight)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(store.mutationGeneration, initialGeneration)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, initialAuthorityCount)
        XCTAssertEqual(store.phase2ShellBrokerPTYBinding, initialBinding)
        let second = Task { await store.pollPhase2ShellTranscript() }
        let outputRequest = await transport.nextRequest()
        await transport.complete(storeShellAcceptedResponse(commandID: outputRequest.commandID,
            command: .pollTranscript, sessionID: sessionID, requestID: requestID,
            transcriptEvents: [storeShellWireEvent(sessionID: sessionID, sequence: 1, source: .broker,
                payload: .output(stream: .standardOutput, bytes: storeShellBytes("later\n")))],
            nextTranscriptSequence: 2), for: outputRequest.commandID)
        _ = await second.value
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertGreaterThan(store.mutationGeneration, initialGeneration)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.last?.payload,
            .output(stream: .standardOutput, bytes: storeShellBytes("later\n")))
    }

    func testBusyRejectionPreservesExactActiveOperationUntilItsReplyCompletes() async throws {
        let sessionID = storeShellUUID(62)
        let requestID = storeShellUUID(63)
        let transport = GatedStoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(
            storeRunningProjection(sessionID: sessionID, requestID: requestID)
        )
        let pollCommandID = storeShellUUID(630)

        let pollTask = Task { @MainActor in
            await store.pollPhase2ShellTranscript(
                maximumEvents: 2,
                maximumBytes: 64,
                timeoutMilliseconds: 1,
                commandID: pollCommandID
            )
        }
        let pollRequest = await transport.nextRequest()
        XCTAssertEqual(pollRequest.command, .pollTranscript)
        XCTAssertEqual(pollRequest.commandID, pollCommandID)
        XCTAssertEqual(store.phase2ShellSession.inFlightCommand, .pollTranscript)
        XCTAssertEqual(store.phase2ShellSession.inFlightOperation?.commandID, pollRequest.commandID)

        let overlappingOutcome = await store.pollPhase2ShellTranscript()

        XCTAssertNil(overlappingOutcome)
        XCTAssertEqual(store.phase2ShellSession.inFlightCommand, .pollTranscript)
        XCTAssertEqual(store.phase2ShellSession.inFlightOperation?.commandID, pollRequest.commandID)
        XCTAssertTrue((store.phase2ShellSession.lastError ?? "").contains("pollTranscript is already running"))
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)

        await transport.complete(
            storeShellAcceptedResponse(
                commandID: pollRequest.commandID,
                command: .pollTranscript,
                sessionID: sessionID,
                requestID: requestID,
                transcriptEvents: [
                    storeShellWireEvent(
                        sessionID: sessionID,
                        sequence: 1,
                        source: .broker,
                        payload: .output(stream: .standardOutput, bytes: storeShellBytes("ready\n"))
                    ),
                ],
                nextTranscriptSequence: 2
            ),
            for: pollRequest.commandID
        )
        let pollOutcome = await pollTask.value

        XCTAssertNotNil(pollOutcome)
        XCTAssertEqual(pollOutcome?.acceptedTranscriptEvents.map(\.payload), [
            .output(stream: .standardOutput, bytes: storeShellBytes("ready\n")),
        ])
        XCTAssertNil(store.phase2ShellSession.inFlightCommand)
        XCTAssertNil(store.phase2ShellSession.inFlightOperation)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents.map(\.payload), [
            .output(stream: .standardOutput, bytes: storeShellBytes("ready\n")),
        ])
    }

    func testRetiredGenerationPollReplyCannotMutateReplacementSurface() async throws {
        let sessionID = storeShellUUID(64)
        let requestID = storeShellUUID(65)
        let transport = GatedStoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        store.installPhase2ShellSessionProjection(
            storeRunningProjection(sessionID: sessionID, requestID: requestID)
        )
        let retired = try XCTUnwrap(store.bindPhase2ShellSurface(generation: 1))
        let pollCommandID = storeShellUUID(650)

        let pollTask = Task { @MainActor in
            await store.pollPhase2ShellTranscript(
                maximumEvents: 2,
                maximumBytes: 64,
                timeoutMilliseconds: 1,
                commandID: pollCommandID,
                surface: retired
            )
        }
        let pollRequest = await transport.nextRequest()
        XCTAssertEqual(pollRequest.command, .pollTranscript)
        XCTAssertEqual(pollRequest.commandID, pollCommandID)
        XCTAssertEqual(store.phase2ShellSession.inFlightOperation?.commandID, pollCommandID)

        store.retirePhase2ShellSurface(retired)
        XCTAssertNil(store.bindPhase2ShellSurface(generation: 1))
        let replacement = try XCTUnwrap(store.bindPhase2ShellSurface(generation: 2))
        await transport.complete(
            storeShellAcceptedResponse(
                commandID: pollCommandID,
                command: .pollTranscript,
                sessionID: sessionID,
                requestID: requestID,
                transcriptEvents: [
                    storeShellWireEvent(
                        sessionID: sessionID,
                        sequence: 1,
                        source: .broker,
                        payload: .output(stream: .standardOutput, bytes: storeShellBytes("old\n"))
                    ),
                ],
                nextTranscriptSequence: 2
            ),
            for: pollCommandID
        )

        let outcome = await pollTask.value
        XCTAssertNil(outcome)
        XCTAssertEqual(store.phase2ShellSession.surfaceMediation?.coordinate, replacement)
        XCTAssertEqual(store.phase2ShellSession.snapshot?.transcriptEvents, [])
        XCTAssertNil(store.phase2ShellSession.inFlightOperation)
    }

    func testPackageShellSessionRoundTripsAndRestoresRunningSessionAsInactiveTerminal() throws {
        let sessionID = storeShellUUID(70)
        let requestID = storeShellUUID(71)
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: 888),
            launchPlan: Phase2HumanPTYLaunchPlan(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/zsh",
                arguments: ["-l"],
                environment: ["MACSCOPE_TEST": "1"],
                workingDirectoryPath: "/tmp",
                initialSize: Phase2HumanPTYTerminalSize(columns: 132, rows: 44),
                transcriptLimits: Phase2HumanPTYTranscriptLimits(
                    maximumEvents: 128,
                    maximumEventBytes: 4_096,
                    maximumCumulativeBytes: 65_536
                )
            ),
            transcriptEvents: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .human,
                    payload: .input(storeShellBytes("pwd\n"))
                ),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: storeShellBytes("/tmp\n"))
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
        let packageRecord = try XCTUnwrap(projection.packagePhase2ShellSession)
        XCTAssertEqual(packageRecord.schemaVersion, WorkspacePackagePhase2ShellSession.schemaVersion)
        XCTAssertEqual(packageRecord.runningRequestID, requestID)
        XCTAssertEqual(packageRecord.runningProcessIdentifier, 888)
        XCTAssertEqual(packageRecord.nextTranscriptSequence, 3)

        let data = try JSONEncoder().encode(packageRecord)
        let decoded = try JSONDecoder().decode(
            WorkspacePackagePhase2ShellSession.self,
            from: data
        )
        XCTAssertEqual(decoded, packageRecord)

        let restored = decoded.restoredInactiveProjection
        XCTAssertEqual(restored.snapshot?.sessionID, sessionID)
        XCTAssertEqual(restored.snapshot?.state, .terminal(outcome: .outcomeUnknown))
        XCTAssertEqual(restored.snapshot?.launchPlan?.executablePath, "/bin/zsh")
        XCTAssertEqual(restored.snapshot?.launchPlan?.arguments, ["-l"])
        XCTAssertEqual(restored.snapshot?.launchPlan?.environment, ["MACSCOPE_TEST": "1"])
        XCTAssertEqual(restored.snapshot?.launchPlan?.workingDirectoryPath, "/tmp")
        XCTAssertEqual(restored.snapshot?.launchPlan?.initialSize, .init(columns: 132, rows: 44))
        XCTAssertEqual(restored.snapshot?.transcriptEvents.map(\.payload), [
            .input(storeShellBytes("pwd\n")),
            .output(stream: .standardOutput, bytes: storeShellBytes("/tmp\n")),
        ])
        XCTAssertEqual(
            restored.lastError,
            Phase2WorkspaceShellSessionProjection.restoredInactiveMessage
        )
        XCTAssertTrue(restored.lastError?.contains("process and PTY closed") == true)
        XCTAssertTrue(restored.isTerminal)
        XCTAssertFalse(restored.isRunning)
    }

    func testDocumentPackageSaveAndReopenRestoresShellSessionContextInactive() throws {
        let sessionID = storeShellUUID(80)
        let requestID = storeShellUUID(81)
        let transport = StoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let launchPlan = Phase2HumanPTYLaunchPlan(
            sessionID: sessionID,
            requestID: requestID,
            executablePath: "/bin/zsh",
            arguments: ["-l"],
            environment: ["MACSCOPE_PACKAGE_SHELL": "1"],
            workingDirectoryPath: "/tmp",
            initialSize: Phase2HumanPTYTerminalSize(columns: 132, rows: 44),
            transcriptLimits: Phase2HumanPTYTranscriptLimits(
                maximumEvents: 128,
                maximumEventBytes: 4_096,
                maximumCumulativeBytes: 65_536
            )
        )
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(
            snapshot: Phase2HumanPTYSessionSnapshot(
                sessionID: sessionID,
                state: .running(requestID: requestID, processIdentifier: 812),
                launchPlan: launchPlan,
                transcriptEvents: [
                    Phase2HumanPTYTranscriptEvent(
                        sessionID: sessionID,
                        sequence: 1,
                        source: .human,
                        payload: .input(storeShellBytes("pwd\n"))
                    ),
                    Phase2HumanPTYTranscriptEvent(
                        sessionID: sessionID,
                        sequence: 2,
                        source: .broker,
                        payload: .output(stream: .standardOutput, bytes: storeShellBytes("/tmp\n"))
                    ),
                ],
                issues: []
            ),
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        ))

        let (parent, packageURL) = try temporaryShellPackageURL("Shell-Persisted.mscope")
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: packageURL, now: Date(timeIntervalSince1970: 5_100)))

        let package = try MacScopeDocumentPackage.openPackage(from: packageURL)
        let packageShell = try XCTUnwrap(package.manifest.session?.phase2ShellSession)
        XCTAssertEqual(packageShell.sessionID, sessionID)
        XCTAssertEqual(packageShell.launchPlan?.executablePath, "/bin/zsh")
        XCTAssertEqual(packageShell.launchPlan?.arguments, ["-l"])
        XCTAssertEqual(packageShell.launchPlan?.environment, ["MACSCOPE_PACKAGE_SHELL": "1"])
        XCTAssertEqual(packageShell.launchPlan?.workingDirectoryPath, "/tmp")
        XCTAssertEqual(packageShell.launchPlan?.columns, 132)
        XCTAssertEqual(packageShell.launchPlan?.rows, 44)
        XCTAssertEqual(packageShell.terminalOutcome, .outcomeUnknown)
        XCTAssertEqual(packageShell.transcriptEvents.map(\.sequence), [1, 2])
        XCTAssertEqual(packageShell.runningRequestID, requestID)
        XCTAssertEqual(packageShell.runningProcessIdentifier, 812)
        XCTAssertEqual(packageShell.nextTranscriptSequence, 3)

        let reopened = try WorkspaceStore.restoredPackage(from: packageURL)
        let reopenedSnapshot = try XCTUnwrap(reopened.phase2ShellSession.snapshot)
        XCTAssertEqual(reopenedSnapshot.sessionID, sessionID)
        XCTAssertEqual(reopenedSnapshot.state, .terminal(outcome: .outcomeUnknown))
        XCTAssertEqual(reopenedSnapshot.launchPlan?.executablePath, "/bin/zsh")
        XCTAssertEqual(reopenedSnapshot.launchPlan?.arguments, ["-l"])
        XCTAssertEqual(reopenedSnapshot.launchPlan?.environment, ["MACSCOPE_PACKAGE_SHELL": "1"])
        XCTAssertEqual(reopenedSnapshot.launchPlan?.workingDirectoryPath, "/tmp")
        XCTAssertEqual(reopenedSnapshot.launchPlan?.initialSize, .init(columns: 132, rows: 44))
        XCTAssertEqual(reopenedSnapshot.transcriptEvents.map(\.payload), [
            .input(storeShellBytes("pwd\n")),
            .output(stream: .standardOutput, bytes: storeShellBytes("/tmp\n")),
        ])
        XCTAssertEqual(
            reopened.phase2ShellSession.lastError,
            Phase2WorkspaceShellSessionProjection.restoredInactiveMessage
        )
        XCTAssertTrue(reopened.phase2ShellSession.lastError?.contains("process and PTY closed") == true)
        XCTAssertTrue(reopened.phase2ShellSession.isTerminal)
        XCTAssertFalse(reopened.phase2ShellSession.isRunning)
    }

    func testPersistentEndpointLaunchUsesDurableTwoPhaseCommitAndPublicPackageLedger() async throws {
        let brokerID = storeShellUUID(201)
        let transport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let store = makeStore(transport: transport, endpoint: .persistentLaunchAgent, capabilityStore: capabilityStore)
        let location = try temporaryShellPackageURL("Durable.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }

        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(202), requestID: storeShellUUID(203), executablePath: "/bin/zsh"
        ))

        XCTAssertTrue(store.phase2ShellSession.isRunning)
        let identity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
        let commands = await transport.recordedRequests().map(\.command)
        XCTAssertEqual(commands, [.launchDurableProcess, .commitDurableSession])
        let package = try MacScopeDocumentPackage.openPackage(from: location.url)
        let persisted = try XCTUnwrap(package.session?.phase2ShellSession)
        XCTAssertEqual(persisted.durableBrokerIdentity?.phase2Identity, identity)
    }

    func testDurableLedgerRefusesExternalPackageMutationWithoutCommittingBrokerOrChangingDestination() async throws {
        let brokerID = storeShellUUID(204)
        let transport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let store = makeStore(
            transport: transport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let location = try temporaryShellPackageURL("ExternallyChanged.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }

        let externalStore = makeStore(transport: StoreShellBrokerTransport())
        XCTAssertTrue(externalStore.writeDocumentPackage(to: location.url))
        let externallyWrittenManifest = try Data(
            contentsOf: MacScopeDocumentPackage.manifestURL(in: location.url)
        )

        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(205),
            requestID: storeShellUUID(206),
            executablePath: "/bin/zsh"
        ))

        let commands = await transport.recordedRequests().map(\.command)
        XCTAssertEqual(commands.first, .launchDurableProcess)
        XCTAssertFalse(commands.contains(.commitDurableSession))
        XCTAssertNil(store.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertNotNil(documentBinding.session.snapshot.conflict)
        XCTAssertEqual(
            try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: location.url)),
            externallyWrittenManifest,
            "a refused durable-ledger transaction must not replace externally changed bytes"
        )
        XCTAssertNil(
            try MacScopeDocumentPackage.openPackage(from: location.url)
                .session?.phase2ShellSession?.durableBrokerIdentity
        )
    }

    func testPostPublicationSaveAsRollbackFailureRetainsDurableCapabilityAndPublicIdentity() async throws {
        let brokerID = storeShellUUID(207)
        let transport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let store = makeStore(
            transport: transport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let original = try temporaryShellPackageURL("PostPublicationOriginal.mscope")
        defer { try? FileManager.default.removeItem(at: original.parent) }
        let saveAs = try temporaryShellPackageURL("PostPublicationSaveAs.mscope")
        defer { try? FileManager.default.removeItem(at: saveAs.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: original.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: original.url)
        defer { withExtendedLifetime(documentBinding) {} }

        var publicationCount = 0
        store.phase2DurableLedgerSaverForTesting = { session in
            publicationCount += 1
            let outcome = await session.save()
            if publicationCount == 1 {
                guard case .saved = outcome else { return outcome }
                _ = await session.saveAs(to: saveAs.url)
            }
            return outcome
        }

        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(208),
            requestID: storeShellUUID(209),
            executablePath: "/bin/zsh"
        ))

        let identity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertEqual(
            publicationCount,
            1,
            "rollback must be refused before writing through the moved session"
        )
        XCTAssertEqual(
            store.documentURL?.resolvingSymlinksInPath().standardizedFileURL.path,
            saveAs.url.resolvingSymlinksInPath().standardizedFileURL.path
        )
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: original.url)
                .session?.phase2ShellSession?.durableBrokerIdentity?.phase2Identity,
            identity
        )
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: saveAs.url)
                .session?.phase2ShellSession?.durableBrokerIdentity?.phase2Identity,
            identity
        )
        let commands = await transport.recordedRequests().map(\.command)
        XCTAssertEqual(commands, [.launchDurableProcess, .cleanupProcess])
        XCTAssertFalse(commands.contains(.commitDurableSession))
    }

    func testV4RestorePreservesReplacementSurfaceDuringAuthenticatedAttach() async throws {
        let brokerID = storeShellUUID(211)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let launchTransport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let source = makeStore(transport: launchTransport, endpoint: .persistentLaunchAgent, capabilityStore: capabilityStore)
        let location = try temporaryShellPackageURL("Recover.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: location.url))
        let sourceDocumentBinding = try await bindStoreDocumentSession(source, at: location.url)
        defer { withExtendedLifetime(sourceDocumentBinding) {} }
        await source.launchPhase2ShellSession(plan: source.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(212), requestID: storeShellUUID(213), executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(source.phase2ShellSession.durableRecoveryIdentity)

        let recoveryTransport = GatedStoreShellBrokerTransport(brokerIncarnationID: brokerID)
        let reopened = makeStore(
            transport: recoveryTransport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let reopenedDocumentBinding = try await bindStoreDocumentSession(reopened, at: location.url)
        defer { withExtendedLifetime(reopenedDocumentBinding) {} }
        XCTAssertTrue(reopened.openDocumentPackage(at: location.url))
        let recoveryTask = try XCTUnwrap(reopened.phase2ShellRecoveryTask)
        let statusRequest = await recoveryTransport.nextRequest()
        XCTAssertEqual(statusRequest.command, .durableSessionStatus)
        await recoveryTransport.complete(storeShellDurableReply(
            to: statusRequest, identity: identity, lifecycle: "running", attached: false
        ), for: statusRequest.commandID)
        let attachRequest = await recoveryTransport.nextRequest()
        XCTAssertEqual(attachRequest.command, .attachDurableSession)
        let retiredSurface = try XCTUnwrap(reopened.bindPhase2ShellSurface(generation: 1))
        let currentSurface = try XCTUnwrap(reopened.bindPhase2ShellSurface(generation: 2))
        reopened.retirePhase2ShellSurface(retiredSurface)
        await recoveryTransport.complete(storeShellDurableReply(
            to: attachRequest, identity: identity, lifecycle: "running", attached: true
        ), for: attachRequest.commandID)
        await recoveryTask.value

        XCTAssertTrue(reopened.phase2ShellSession.isRunning)
        XCTAssertEqual(reopened.phase2ShellSession.durableRecoveryIdentity, identity)
        XCTAssertEqual(reopened.phase2ShellSession.surfaceMediation?.coordinate, currentSurface)
        XCTAssertEqual(reopened.phase2ShellSession.surfaceMediation?.lifecycle, .running)
        XCTAssertEqual(reopened.phase2ShellSession.surfaceGenerationHighWater, currentSurface)
        XCTAssertNil(reopened.bindPhase2ShellSurface(generation: retiredSurface.generation))
        let requestCount = await recoveryTransport.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testV4RestoreCannotOverwriteReplacementSessionDuringAuthenticatedAttach() async throws {
        let brokerID = storeShellUUID(211)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let launchTransport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let source = makeStore(transport: launchTransport, endpoint: .persistentLaunchAgent, capabilityStore: capabilityStore)
        let location = try temporaryShellPackageURL("RecoverReplacement.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: location.url))
        let sourceDocumentBinding = try await bindStoreDocumentSession(source, at: location.url)
        defer { withExtendedLifetime(sourceDocumentBinding) {} }
        await source.launchPhase2ShellSession(plan: source.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(212), requestID: storeShellUUID(213), executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(source.phase2ShellSession.durableRecoveryIdentity)

        let recoveryTransport = GatedStoreShellBrokerTransport(brokerIncarnationID: brokerID)
        let reopened = makeStore(
            transport: recoveryTransport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let reopenedDocumentBinding = try await bindStoreDocumentSession(reopened, at: location.url)
        defer { withExtendedLifetime(reopenedDocumentBinding) {} }
        XCTAssertTrue(reopened.openDocumentPackage(at: location.url))
        let recoveryTask = try XCTUnwrap(reopened.phase2ShellRecoveryTask)
        let statusRequest = await recoveryTransport.nextRequest()
        XCTAssertEqual(statusRequest.command, .durableSessionStatus)
        await recoveryTransport.complete(storeShellDurableReply(
            to: statusRequest, identity: identity, lifecycle: "running", attached: false
        ), for: statusRequest.commandID)
        let attachRequest = await recoveryTransport.nextRequest()
        XCTAssertEqual(attachRequest.command, .attachDurableSession)
        let replacement = storeRunningProjection(
            sessionID: storeShellUUID(214), requestID: storeShellUUID(215), processIdentifier: 1_215
        )
        reopened.installPhase2ShellSessionProjection(replacement)
        await recoveryTransport.complete(storeShellDurableReply(
            to: attachRequest, identity: identity, lifecycle: "running", attached: true
        ), for: attachRequest.commandID)
        await recoveryTask.value

        XCTAssertEqual(reopened.phase2ShellSession, replacement)
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
        let requestCount = await recoveryTransport.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testTerminalRecoveryPreservesSurfaceBindingAcrossStatusAndLedgerSave() async throws {
        let brokerID = storeShellUUID(221)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let sourceTransport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let source = makeStore(transport: sourceTransport, endpoint: .persistentLaunchAgent, capabilityStore: capabilityStore)
        let location = try temporaryShellPackageURL("Terminal.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: location.url))
        let sourceDocumentBinding = try await bindStoreDocumentSession(source, at: location.url)
        defer { withExtendedLifetime(sourceDocumentBinding) {} }
        await source.launchPhase2ShellSession(plan: source.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(222), requestID: storeShellUUID(223), executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(source.phase2ShellSession.durableRecoveryIdentity)

        let terminalTransport = GatedStoreShellBrokerTransport(brokerIncarnationID: brokerID)
        let reopened = makeStore(
            transport: terminalTransport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let reopenedDocumentBinding = try await bindStoreDocumentSession(reopened, at: location.url)
        defer { withExtendedLifetime(reopenedDocumentBinding) {} }
        let saveGate = StoreShellLedgerSaveGate()
        reopened.phase2DurableLedgerSaverForTesting = { session in
            await saveGate.arriveAndWait()
            return await session.save()
        }
        XCTAssertTrue(reopened.openDocumentPackage(at: location.url))
        let recoveryTask = try XCTUnwrap(reopened.phase2ShellRecoveryTask)
        let statusRequest = await terminalTransport.nextRequest()
        XCTAssertEqual(statusRequest.command, .durableSessionStatus)
        let retiredSurface = try XCTUnwrap(reopened.bindPhase2ShellSurface(generation: 1))
        await terminalTransport.complete(storeShellDurableReply(
            to: statusRequest, identity: identity, lifecycle: "terminal", attached: false
        ), for: statusRequest.commandID)
        await saveGate.waitUntilArrived()
        let currentSurface = try XCTUnwrap(reopened.bindPhase2ShellSurface(generation: 2))
        reopened.retirePhase2ShellSurface(retiredSurface)
        await saveGate.open()
        await recoveryTask.value

        XCTAssertNil(reopened.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertNil(try capabilityStore.load(for: identity.capabilityID))
        XCTAssertEqual(reopened.phase2ShellSession.surfaceMediation?.coordinate, currentSurface)
        XCTAssertEqual(reopened.phase2ShellSession.surfaceMediation?.lifecycle, .terminal(.outcomeUnknown))
        XCTAssertEqual(reopened.phase2ShellSession.surfaceGenerationHighWater, currentSurface)
        XCTAssertNil(reopened.bindPhase2ShellSurface(generation: retiredSurface.generation))
        let requestCount = await terminalTransport.requestCount()
        XCTAssertEqual(requestCount, 1)
        let persisted = try MacScopeDocumentPackage.openPackage(from: location.url)
        XCTAssertNil(persisted.session?.phase2ShellSession?.durableBrokerIdentity)
    }

    func testRetainedDurableCleanupWithMissingOrLockedCapabilityKeepsEvidenceAndSendsNoXPC() async throws {
        let brokerID = storeShellUUID(231)
        let sourceTransport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let sourceSecurity = MemoryCapabilitySecurityClient()
        let sourceStore = makeStore(
            transport: sourceTransport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: .init(securityClient: sourceSecurity)
        )
        let location = try temporaryShellPackageURL("CleanupEvidence.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(sourceStore.writeDocumentPackage(to: location.url))
        let sourceDocumentBinding = try await bindStoreDocumentSession(sourceStore, at: location.url)
        defer { withExtendedLifetime(sourceDocumentBinding) {} }
        await sourceStore.launchPhase2ShellSession(plan: sourceStore.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(232), requestID: storeShellUUID(233), executablePath: "/bin/zsh"
        ))
        let projection = sourceStore.phase2ShellSession
        XCTAssertNotNil(projection.durableRecoveryIdentity)

        for securityClient in [
            MissingCapabilitySecurityClient(status: errSecItemNotFound),
            MissingCapabilitySecurityClient(status: errSecInteractionNotAllowed),
        ] {
            let transport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
            let store = makeStore(
                transport: transport,
                endpoint: .persistentLaunchAgent,
                capabilityStore: .init(securityClient: securityClient)
            )
            store.installPhase2ShellSessionProjection(projection)
            await store.cleanupPhase2ShellSession()
            XCTAssertEqual(store.phase2ShellSession.durableRecoveryIdentity, projection.durableRecoveryIdentity)
            XCTAssertTrue((store.phase2ShellSession.lastError ?? "").contains("retained"))
            let requests = await transport.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testPendingRecoveryPayloadAndVerificationCopyPreserveDurableIdentity() async throws {
        let transport = StoreShellBrokerTransport(brokerIncarnationID: storeShellUUID(901), autoDurable: true)
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: MemoryCapabilitySecurityClient())
        let source = makeStore(transport: transport, endpoint: .persistentLaunchAgent, capabilityStore: capabilityStore)
        let location = try temporaryShellPackageURL("PendingRecovery.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: location.url))
        let binding = try await bindStoreDocumentSession(source, at: location.url)
        defer { withExtendedLifetime(binding) {} }
        await source.launchPhase2ShellSession(plan: source.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(902), requestID: storeShellUUID(903), executablePath: "/bin/zsh"))
        let original = try MacScopeDocumentPackage.openPackage(from: location.url)
        let shell = try XCTUnwrap(original.session?.phase2ShellSession)
        let identity = try XCTUnwrap(shell.durableBrokerIdentity?.phase2Identity)
        let store = try WorkspaceStore.restoredPackage(from: location.url, scheduleDurableRecovery: false)
        XCTAssertTrue(store.phase2ShellSession.isDurableRecoveryPending)
        let pendingPayload = try store.makePackagePayload()
        let pendingContents = try MacScopeDocumentPackage.validatedContents(manifestData: pendingPayload.manifestData,
            attachmentsByBinaryID: pendingPayload.attachmentsByBinaryID,
            reconstructionState: pendingPayload.reconstructionState,
            instructionSidecarData: pendingPayload.instructionSidecarData)
        XCTAssertEqual(pendingContents.session?.phase2ShellSession?.durableBrokerIdentity?.phase2Identity, identity)
        var events: [Phase2HumanPTYTranscriptEvent] = []
        func append(_ source: Phase2HumanPTYEventSource, _ payload: Phase2HumanPTYEventPayload) {
            events.append(.init(sessionID: identity.sessionID, sequence: UInt64(events.count + 1),
                source: source, payload: payload))
        }
        append(.broker, .output(stream: .standardOutput, bytes: storeShellBytes("sh-3.2$ ")))
        append(.human, .resize(columns: 101, rows: 4))
        for character in "echo MS03_INPUT_OK\n" {
            let value = storeShellBytes(String(character))
            append(.human, .input(value))
            append(.broker, .output(stream: .standardOutput, bytes: value))
        }
        append(.broker, .output(stream: .standardOutput, bytes: storeShellBytes("MS03_INPUT_OK\r\nsh-3.2$ ")))
        append(.human, .input(storeShellBytes("sleep 2; echo MS03_LATE_A; sleep 2; echo MS03_LATE_B\n")))
        append(.broker, .output(stream: .standardOutput, bytes: storeShellBytes("MS03_LATE_A\r\nMS03_LATE_B\r\nsh-3.2$ ")))
        append(.human, .input(storeShellBytes("exit\n")))
        append(.broker, .output(stream: .standardOutput, bytes: storeShellBytes("exit\r\n")))
        append(.broker, .terminal(.exited(status: 0)))
        let terminal = Phase2HumanPTYSessionSnapshot(sessionID: identity.sessionID,
            state: .terminal(outcome: .exited(status: 0)), launchPlan: shell.launchPlan?.phase2LaunchPlan,
            transcriptEvents: events, issues: [])
        store.installPhase2ShellSessionProjection(.init(snapshot: terminal, inFlightCommand: nil,
            lastError: nil, lastAcceptedTranscriptEvents: [], lastBytesWritten: nil,
            durableRecoveryIdentity: identity))
        let payload: WorkspaceDocumentPackagePayload
        do { payload = try store.makePackagePayload() }
        catch { XCTFail("Actual restored-workspace payload failed: \(String(reflecting: error))"); throw error }
        let contents = try MacScopeDocumentPackage.validatedContents(manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID, reconstructionState: payload.reconstructionState,
            instructionSidecarData: payload.instructionSidecarData)
        let savedShell = try XCTUnwrap(contents.session?.phase2ShellSession)
        XCTAssertEqual(savedShell.durableBrokerIdentity?.phase2Identity, identity)
        XCTAssertEqual(savedShell.runningRequestID, identity.launchRequest.requestID)
        XCTAssertEqual(savedShell.runningProcessIdentifier, identity.processIdentity.processIdentifier)
        XCTAssertEqual(savedShell.restoredProjection.snapshot?.transcriptEvents, events)
        XCTAssertEqual(savedShell.restoredProjection.snapshot?.state, terminal.state)
        XCTAssertEqual(contents.manifest.reaEvidence, original.manifest.reaEvidence)
        let verification = try temporaryShellPackageURL("NativeSaveVerification.mscope")
        defer { try? FileManager.default.removeItem(at: verification.parent) }
        try MacScopeDocumentPackage.writePackage(contents.manifest,
            attachmentsByBinaryID: payload.attachmentsByBinaryID,
            reconstructionState: payload.reconstructionState,
            reconstructionAttachmentSources: payload.reconstructionAttachmentSources, to: verification.url,
            instructionSidecarData: payload.instructionSidecarData)
        let reopened = try MacScopeDocumentPackage.openPackage(from: verification.url)
        XCTAssertEqual(reopened.session?.phase2ShellSession, savedShell)
        XCTAssertEqual(reopened.manifest.reaEvidence, original.manifest.reaEvidence)
    }

    func testPackagePayloadAfterDurableCleanupRetainsInterleavedTranscriptWithoutRecoveryAuthority() async throws {
        let transport = StoreShellBrokerTransport(brokerIncarnationID: storeShellUUID(910), autoDurable: true)
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: MemoryCapabilitySecurityClient())
        let store = makeStore(transport: transport, endpoint: .persistentLaunchAgent, capabilityStore: capabilityStore)
        let location = try temporaryShellPackageURL("StoppedPayload.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let binding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(binding) {} }
        let sessionID = storeShellUUID(911)
        let requestID = storeShellUUID(912)
        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: sessionID, requestID: requestID, executablePath: "/bin/zsh"))
        let identity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)
        let initial = Phase2HumanPTYTranscriptEvent(sessionID: sessionID, sequence: 1, source: .human,
            payload: .input(storeShellBytes("echo saved\n")))
        let snapshot = Phase2HumanPTYSessionSnapshot(sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: identity.processIdentity.processIdentifier),
            launchPlan: store.phase2ShellSession.snapshot?.launchPlan, transcriptEvents: [initial], issues: [])
        store.installPhase2ShellSessionProjection(Phase2WorkspaceShellSessionProjection(snapshot: snapshot,
            inFlightCommand: nil, lastError: nil, lastAcceptedTranscriptEvents: [], lastBytesWritten: nil,
            durableRecoveryIdentity: identity))
        for command in [MacScope.Phase2ShellBrokerCommandKind.durableSessionStatus, .attachDurableSession] {
            await transport.enqueue(.init(commandID: nil, command: command, status: .accepted,
                sessionID: sessionID, requestID: requestID, lifecycleState: "running",
                processIdentifier: identity.processIdentity.processIdentifier, durableIdentity: identity,
                durableClientAttached: command == .attachDurableSession))
        }
        let output = storeShellWireEvent(sessionID: sessionID, sequence: 2, source: .broker,
            payload: .output(stream: .standardOutput, bytes: storeShellBytes("saved\n")))
        let terminal = storeShellWireEvent(sessionID: sessionID, sequence: 3, source: .broker,
            payload: .terminal(.canceled))
        await transport.enqueue(.init(commandID: nil, command: .cleanupProcess, status: .accepted,
            sessionID: sessionID, requestID: requestID, observedProcessAbsent: true, outcome: "canceled",
            transcriptEvents: [terminal], nextTranscriptSequence: 4))
        await transport.enqueue(.init(commandID: nil, command: .pollTranscript, status: .accepted,
            sessionID: sessionID, requestID: requestID, transcriptEvents: [output, terminal], nextTranscriptSequence: 4))
        await store.cleanupPhase2ShellSession(reason: "payloadAcceptance")
        XCTAssertEqual(store.phase2ShellSession.snapshot?.state, .terminal(outcome: .canceled))
        XCTAssertNil(store.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertNil(try capabilityStore.load(for: identity.capabilityID))
        let payload = try store.makePackagePayload()
        let contents = try MacScopeDocumentPackage.validatedContents(manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID, reconstructionState: payload.reconstructionState,
            instructionSidecarData: payload.instructionSidecarData)
        let persisted = try XCTUnwrap(contents.session?.phase2ShellSession)
        XCTAssertNil(persisted.durableBrokerIdentity)
        XCTAssertNil(persisted.runningRequestID)
        XCTAssertNil(persisted.runningProcessIdentifier)
        XCTAssertEqual(persisted.restoredProjection.snapshot?.transcriptEvents.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(persisted.restoredProjection.snapshot?.transcriptEvents.map(\.payload),
            [.input(storeShellBytes("echo saved\n")),
             .output(stream: .standardOutput, bytes: storeShellBytes("saved\n")), .terminal(.canceled)])
        XCTAssertEqual(persisted.restoredProjection.snapshot?.state, .terminal(outcome: .canceled))
        XCTAssertEqual(contents.manifest.documentID, store.documentID)
        XCTAssertEqual(contents.manifest.workspaceUUID, store.workspaceID)
    }

    func testProvenDurableCleanupWriteFailureRetainsCapabilityAndIdentity() async throws {
        let brokerID = storeShellUUID(241)
        let transport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let store = makeStore(transport: transport, endpoint: .persistentLaunchAgent, capabilityStore: capabilityStore)
        let location = try temporaryShellPackageURL("WriteFailure.mscope")
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }
        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(242), requestID: storeShellUUID(243), executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)
        store.phase2DurableLedgerSaverForTesting = { _ in .failed("synthetic-ledger-write-failure") }

        await store.cleanupPhase2ShellSession(reason: "testWriteFailure")

        XCTAssertEqual(store.phase2ShellSession.durableRecoveryIdentity, identity)
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
        XCTAssertTrue((store.phase2ShellSession.lastError ?? "").contains("ledger failed"))
    }

    func testBusyRejectionDuringDurableCleanupDoesNotStrandOperation() async throws {
        let brokerID = storeShellUUID(244)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let store = makeStore(
            transport: StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true),
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let location = try temporaryShellPackageURL("BusyCleanup.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }
        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(245),
            requestID: storeShellUUID(246),
            executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)
        let saveGate = StoreShellLedgerSaveGate()
        store.phase2DurableLedgerSaverForTesting = { _ in
            await saveGate.arriveAndWait()
            return .saved(clean: true, adopted: nil)
        }

        let cleanupTask = Task { @MainActor in
            await store.cleanupPhase2ShellSession(reason: "primaryCleanup")
        }
        await saveGate.waitUntilArrived()
        await store.cleanupPhase2ShellSession(reason: "overlappingCleanup")

        XCTAssertEqual(store.phase2ShellSession.inFlightCommand, .cleanup)
        XCTAssertNotNil(store.phase2ShellSession.inFlightOperation)
        XCTAssertNotNil(store.phase2ShellSession.lastError)

        await saveGate.open()
        await cleanupTask.value

        XCTAssertEqual(store.phase2ShellSession.snapshot?.state, .terminal(outcome: .canceled))
        XCTAssertNil(store.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertNil(try capabilityStore.load(for: identity.capabilityID))
    }

    func testContextChangeDuringDurableCleanupRetiresOperationAndRetainsEvidence() async throws {
        let brokerID = storeShellUUID(247)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let store = makeStore(
            transport: StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true),
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let location = try temporaryShellPackageURL("ReenteredCleanup.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }
        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(248),
            requestID: storeShellUUID(249),
            executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)
        let saveGate = StoreShellLedgerSaveGate()
        store.phase2DurableLedgerSaverForTesting = { _ in
            await saveGate.arriveAndWait()
            return .saved(clean: true, adopted: nil)
        }

        let cleanupTask = Task { @MainActor in
            await store.cleanupPhase2ShellSession(reason: "contextReplacement")
        }
        await saveGate.waitUntilArrived()
        store.schedulePhase2DurableShellRecoveryIfNeeded()
        await saveGate.open()
        await cleanupTask.value

        XCTAssertNil(store.phase2ShellSession.inFlightOperation)
        XCTAssertEqual(store.phase2ShellSession.durableRecoveryIdentity, identity)
        XCTAssertTrue((store.phase2ShellSession.lastError ?? "").contains("workspace context"))
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
    }

    func testTerminalRecoveryLedgerWriteFailureRetainsCapabilityIdentityAndLatestSurface() async throws {
        let brokerID = storeShellUUID(251)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let sourceTransport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let source = makeStore(transport: sourceTransport, endpoint: .persistentLaunchAgent, capabilityStore: capabilityStore)
        let location = try temporaryShellPackageURL("TerminalWriteFailure.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: location.url))
        let sourceDocumentBinding = try await bindStoreDocumentSession(source, at: location.url)
        defer { withExtendedLifetime(sourceDocumentBinding) {} }
        await source.launchPhase2ShellSession(plan: source.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(252), requestID: storeShellUUID(253), executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(source.phase2ShellSession.durableRecoveryIdentity)

        let terminalTransport = StoreShellBrokerTransport(
            brokerIncarnationID: brokerID, autoDurable: true,
            durableIdentity: identity, durableLifecycleState: "terminal"
        )
        let reopened = makeStore(
            transport: terminalTransport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let reopenedDocumentBinding = try await bindStoreDocumentSession(reopened, at: location.url)
        defer { withExtendedLifetime(reopenedDocumentBinding) {} }
        let saveGate = StoreShellLedgerSaveGate()
        reopened.phase2DurableLedgerSaverForTesting = { _ in
            await saveGate.arriveAndWait()
            return .failed("synthetic-ledger-write-failure")
        }
        XCTAssertTrue(reopened.openDocumentPackage(at: location.url))
        let recoveryTask = try XCTUnwrap(reopened.phase2ShellRecoveryTask)
        await saveGate.waitUntilArrived()
        let retiredSurface = try XCTUnwrap(reopened.bindPhase2ShellSurface(generation: 1))
        let currentSurface = try XCTUnwrap(reopened.bindPhase2ShellSurface(generation: 2))
        reopened.retirePhase2ShellSurface(retiredSurface)
        await saveGate.open()
        await recoveryTask.value

        XCTAssertEqual(reopened.phase2ShellSession.durableRecoveryIdentity, identity)
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
        XCTAssertEqual(reopened.phase2ShellSession.surfaceMediation?.coordinate, currentSurface)
        XCTAssertEqual(reopened.phase2ShellSession.surfaceMediation?.lifecycle, .terminal(.outcomeUnknown))
        XCTAssertEqual(reopened.phase2ShellSession.surfaceGenerationHighWater, currentSurface)
        XCTAssertNil(reopened.bindPhase2ShellSurface(generation: retiredSurface.generation))
        XCTAssertTrue((reopened.phase2ShellSession.lastError ?? "").contains("ledger failed"))
    }

    func testDurableLedgerFailureAfterReentryPreservesReplacementProjectionAndDirtyState() async throws {
        let brokerID = storeShellUUID(254)
        let transport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let store = makeStore(
            transport: transport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: .init(securityClient: MemoryCapabilitySecurityClient())
        )
        let location = try temporaryShellPackageURL("ReentrantLedgerFailure.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }
        let saveGate = StoreShellLedgerSaveGate()
        store.phase2DurableLedgerSaverForTesting = { _ in
            await saveGate.arriveAndWait()
            return .failed("synthetic-reentrant-ledger-failure")
        }

        let launchTask = Task { @MainActor in
            await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
                sessionID: storeShellUUID(255),
                requestID: storeShellUUID(256),
                executablePath: "/bin/zsh"
            ))
        }
        await saveGate.waitUntilArrived()

        let replacement = storeRunningProjection(
            sessionID: storeShellUUID(257),
            requestID: storeShellUUID(258),
            processIdentifier: 1_258
        )
        store.installPhase2ShellSessionProjection(replacement)
        store.schedulePhase2DurableShellRecoveryIfNeeded()
        store.markDocumentMutated()
        await saveGate.open()
        await launchTask.value

        XCTAssertEqual(store.phase2ShellSession, replacement)
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    func testDurableLedgerFailureAfterBusyRejectionRestoresPrepublicationProjection() async throws {
        let brokerID = storeShellUUID(264)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let store = makeStore(
            transport: StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true),
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let location = try temporaryShellPackageURL("BusyLedgerFailure.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }
        let saveGate = StoreShellLedgerSaveGate()
        store.phase2DurableLedgerSaverForTesting = { _ in
            await saveGate.arriveAndWait()
            return .failed("synthetic-busy-ledger-failure")
        }

        let launchTask = Task { @MainActor in
            await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
                sessionID: storeShellUUID(265),
                requestID: storeShellUUID(266),
                executablePath: "/bin/zsh"
            ))
        }
        await saveGate.waitUntilArrived()
        let stagedIdentity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)

        await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(267),
            requestID: storeShellUUID(268),
            executablePath: "/bin/zsh"
        ))
        XCTAssertEqual(store.phase2ShellSession.inFlightCommand, .launch)
        XCTAssertNotNil(store.phase2ShellSession.lastError)

        await saveGate.open()
        await launchTask.value

        XCTAssertNil(store.phase2ShellSession.inFlightOperation)
        XCTAssertNil(store.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertNil(try capabilityStore.load(for: stagedIdentity.capabilityID))
    }

    func testCanceledDurableLaunchRollsBackPublishedLedgerBeforeCapabilityDeletion() async throws {
        let brokerID = storeShellUUID(269)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let transport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let store = makeStore(
            transport: transport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let location = try temporaryShellPackageURL("CanceledDurableLaunch.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }
        let saveGate = StoreShellLedgerSaveGate()
        store.phase2DurableLedgerSaverForTesting = { _ in
            await saveGate.arriveAndWait()
            return .saved(clean: true, adopted: nil)
        }

        let launchTask = Task { @MainActor in
            await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
                sessionID: storeShellUUID(270),
                requestID: storeShellUUID(271),
                executablePath: "/bin/zsh"
            ))
        }
        await saveGate.waitUntilArrived()
        let stagedIdentity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)
        launchTask.cancel()
        await saveGate.open()
        await launchTask.value

        let arrivalCount = await saveGate.arrivalCount()
        XCTAssertEqual(arrivalCount, 2)
        XCTAssertNil(store.phase2ShellSession.inFlightOperation)
        XCTAssertNil(store.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertNil(try capabilityStore.load(for: stagedIdentity.capabilityID))
        let commands = await transport.recordedRequests().map(\.command)
        XCTAssertEqual(commands, [.launchDurableProcess, .cleanupProcess])
    }

    func testContextChangeDuringCanceledLaunchRollbackRestoresDurableIdentity() async throws {
        let brokerID = storeShellUUID(272)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let store = makeStore(
            transport: StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true),
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let location = try temporaryShellPackageURL("ReenteredDurableRollback.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: location.url))
        let documentBinding = try await bindStoreDocumentSession(store, at: location.url)
        defer { withExtendedLifetime(documentBinding) {} }
        let saveGate = StoreShellLedgerSaveSequenceGate()
        store.phase2DurableLedgerSaverForTesting = { _ in await saveGate.save() }

        let launchTask = Task { @MainActor in
            await store.launchPhase2ShellSession(plan: store.makePhase2ShellLaunchPlan(
                sessionID: storeShellUUID(273),
                requestID: storeShellUUID(274),
                executablePath: "/bin/zsh"
            ))
        }
        await saveGate.waitUntilArrival(1)
        let identity = try XCTUnwrap(store.phase2ShellSession.durableRecoveryIdentity)
        launchTask.cancel()
        await saveGate.completeNext(with: .saved(clean: true, adopted: nil))
        await saveGate.waitUntilArrival(2)

        store.schedulePhase2DurableShellRecoveryIfNeeded()
        await saveGate.completeNext(with: .failed("synthetic-reentered-rollback-failure"))
        await launchTask.value

        XCTAssertNil(store.phase2ShellSession.inFlightOperation)
        XCTAssertEqual(store.phase2ShellSession.durableRecoveryIdentity, identity)
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
    }

    func testContextChangeDuringTerminalRecoveryClearRestoresDurableIdentity() async throws {
        let brokerID = storeShellUUID(275)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let source = makeStore(
            transport: StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true),
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let location = try temporaryShellPackageURL("ReenteredTerminalClear.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: location.url))
        let sourceBinding = try await bindStoreDocumentSession(source, at: location.url)
        defer { withExtendedLifetime(sourceBinding) {} }
        await source.launchPhase2ShellSession(plan: source.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(276),
            requestID: storeShellUUID(277),
            executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(source.phase2ShellSession.durableRecoveryIdentity)

        let reopened = makeStore(
            transport: StoreShellBrokerTransport(
                brokerIncarnationID: brokerID,
                autoDurable: true,
                durableIdentity: identity,
                durableLifecycleState: "terminal"
            ),
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let reopenedBinding = try await bindStoreDocumentSession(reopened, at: location.url)
        defer { withExtendedLifetime(reopenedBinding) {} }
        let saveGate = StoreShellLedgerSaveSequenceGate()
        reopened.phase2DurableLedgerSaverForTesting = { _ in await saveGate.save() }
        XCTAssertTrue(reopened.openDocumentPackage(at: location.url))
        let recoveryTask = try XCTUnwrap(reopened.phase2ShellRecoveryTask)
        await saveGate.waitUntilArrival(1)

        reopened.schedulePhase2DurableShellRecoveryIfNeeded()
        await saveGate.completeNext(with: .failed("synthetic-reentered-recovery-failure"))
        await recoveryTask.value

        XCTAssertNil(reopened.phase2ShellSession.inFlightOperation)
        XCTAssertEqual(reopened.phase2ShellSession.durableRecoveryIdentity, identity)
        XCTAssertTrue((reopened.phase2ShellSession.lastError ?? "").contains("workspace context"))
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
    }

    func testTerminalRecoveryLedgerFailureCannotReinstallIdentityAfterReplacement() async throws {
        let brokerID = storeShellUUID(259)
        let security = MemoryCapabilitySecurityClient()
        let capabilityStore = Phase2DurableShellBrokerCapabilityStore(securityClient: security)
        let source = makeStore(
            transport: StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true),
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let location = try temporaryShellPackageURL("TerminalRecoveryReentry.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: location.url))
        let sourceBinding = try await bindStoreDocumentSession(source, at: location.url)
        defer { withExtendedLifetime(sourceBinding) {} }
        await source.launchPhase2ShellSession(plan: source.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(260),
            requestID: storeShellUUID(261),
            executablePath: "/bin/zsh"
        ))
        let identity = try XCTUnwrap(source.phase2ShellSession.durableRecoveryIdentity)

        let reopened = makeStore(
            transport: StoreShellBrokerTransport(
                brokerIncarnationID: brokerID,
                autoDurable: true,
                durableIdentity: identity,
                durableLifecycleState: "terminal"
            ),
            endpoint: .persistentLaunchAgent,
            capabilityStore: capabilityStore
        )
        let reopenedBinding = try await bindStoreDocumentSession(reopened, at: location.url)
        defer { withExtendedLifetime(reopenedBinding) {} }
        let saveGate = StoreShellLedgerSaveGate()
        reopened.phase2DurableLedgerSaverForTesting = { _ in
            await saveGate.arriveAndWait()
            return .failed("synthetic-terminal-recovery-reentry")
        }
        XCTAssertTrue(reopened.openDocumentPackage(at: location.url))
        let recoveryTask = try XCTUnwrap(reopened.phase2ShellRecoveryTask)
        await saveGate.waitUntilArrived()

        let replacement = storeRunningProjection(
            sessionID: storeShellUUID(262),
            requestID: storeShellUUID(263),
            processIdentifier: 1_263
        )
        reopened.installPhase2ShellSessionProjection(replacement)
        reopened.schedulePhase2DurableShellRecoveryIfNeeded()
        reopened.markDocumentMutated()
        await saveGate.open()
        await recoveryTask.value

        XCTAssertEqual(reopened.phase2ShellSession, replacement)
        XCTAssertTrue(reopened.hasUnsavedChanges)
        XCTAssertNotNil(try capabilityStore.load(for: identity.capabilityID))
    }

    func testRecoverySuppressedPackageRestoreCreatesNoRecoveryTaskOrXPCSideEffect() async throws {
        let brokerID = storeShellUUID(161)
        let transport = StoreShellBrokerTransport(brokerIncarnationID: brokerID, autoDurable: true)
        let security = MemoryCapabilitySecurityClient()
        let source = makeStore(
            transport: transport,
            endpoint: .persistentLaunchAgent,
            capabilityStore: .init(securityClient: security)
        )
        let location = try temporaryShellPackageURL("SuppressedRestore.mscope")
        defer { try? FileManager.default.removeItem(at: location.parent) }
        XCTAssertTrue(source.writeDocumentPackage(to: location.url))
        let sourceDocumentBinding = try await bindStoreDocumentSession(source, at: location.url)
        defer { withExtendedLifetime(sourceDocumentBinding) {} }
        await source.launchPhase2ShellSession(plan: source.makePhase2ShellLaunchPlan(
            sessionID: storeShellUUID(162), requestID: storeShellUUID(163), executablePath: "/bin/zsh"
        ))

        let restored = try WorkspaceStore.restoredPackage(
            from: location.url,
            scheduleDurableRecovery: false
        )
        XCTAssertNotNil(restored.phase2ShellSession.durableRecoveryIdentity)
        XCTAssertNil(restored.phase2ShellRecoveryTask)
        let commandsBeforeYield = await transport.recordedRequests()
        await Task.yield()
        let commandsAfterYield = await transport.recordedRequests()
        XCTAssertEqual(commandsAfterYield.count, commandsBeforeYield.count)
    }
}

@MainActor
private func makeStore(
    transport: any MacScope.ShellBrokerXPCTransport,
    endpoint: Phase2ShellBrokerEndpoint = .embeddedApplicationService,
    capabilityStore: Phase2DurableShellBrokerCapabilityStore = .init(),
    terminalSurfaceID: UUID = UUID()
) -> WorkspaceStore {
    WorkspaceStore(
        workspaceName: "Shell Store",
        snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()),
        engine: AnalysisEngine(),
        autosaveScheduler: nil,
        phase2ShellSessionClient: Phase2HumanPTYShellSessionClient(transport: transport),
        phase2ShellBrokerEndpoint: endpoint,
        phase2DurableShellCapabilityStore: capabilityStore,
        phase2ShellTerminalSurfaceID: terminalSurfaceID
    )
}

private func storeRunningProjection(
    sessionID: UUID,
    requestID: UUID,
    processIdentifier: Int32 = 901
) -> Phase2WorkspaceShellSessionProjection {
    Phase2WorkspaceShellSessionProjection(
        snapshot: Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: processIdentifier),
            launchPlan: Phase2HumanPTYLaunchPlan(
                sessionID: sessionID,
                requestID: requestID,
                executablePath: "/bin/zsh",
                initialSize: .defaultInteractive
            ),
            transcriptEvents: [],
            issues: []
        ),
        inFlightCommand: nil,
        lastError: nil,
        lastAcceptedTranscriptEvents: [],
        lastBytesWritten: nil
    )
}

@MainActor
private struct StoreShellDocumentBinding {
    let session: WorkspaceDocumentSession
    let reservations: StoreShellDocumentReservations
}

@MainActor
private func bindStoreDocumentSession(
    _ store: WorkspaceStore,
    at packageURL: URL
) async throws -> StoreShellDocumentBinding {
    let io = WorkspaceDocumentIO()
    let location = try WorkspaceDocumentLocation.canonicalized(from: packageURL)
    let package = try await io.readValidated(from: location)
    let reservations = StoreShellDocumentReservations()
    let session = WorkspaceDocumentSession(
        sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
        windowID: .fresh(),
        source: store,
        io: io,
        reservations: reservations
    )
    try session.bindOpenedPackage(package, at: location)
    return StoreShellDocumentBinding(session: session, reservations: reservations)
}

@MainActor
private final class StoreShellDocumentReservations: WorkspaceDocumentLocationReserving {
    func owner(of location: WorkspaceDocumentLocation) -> WorkspaceWindowID? { nil }

    func reserve(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentLocationReservationResult { .reserved }

    func release(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID
    ) {}

    func releaseAll(for sessionID: WorkspaceDocumentSessionID) {}

    func beginPhysicalPublication(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        retainingPublishedOwnership: Bool,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentPublicationReservationResult {
        .reserved(WorkspaceDocumentPublicationReservation())
    }

    func completePhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation,
        at publishedLocation: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentPublicationCompletionResult { .completed }

    func cancelPhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation
    ) {}
}

private actor StoreShellBrokerTransport: MacScope.ShellBrokerXPCTransport {
    private var requests: [MacScope.Phase2ShellBrokerCommandRequest] = []
    private var responses: [MacScope.Phase2ShellBrokerCommandResponse] = []
    private let brokerIncarnationID: UUID?
    private let autoDurable: Bool
    private var durableIdentity: Phase2DurableShellBrokerIdentity?
    private let durableLifecycleState: String

    init(
        brokerIncarnationID: UUID? = nil,
        autoDurable: Bool = false,
        durableIdentity: Phase2DurableShellBrokerIdentity? = nil,
        durableLifecycleState: String = "running"
    ) {
        self.brokerIncarnationID = brokerIncarnationID
        self.autoDurable = autoDurable
        self.durableIdentity = durableIdentity
        self.durableLifecycleState = durableLifecycleState
    }

    func enqueue(_ response: MacScope.Phase2ShellBrokerCommandResponse) {
        responses.append(response)
    }

    func recordedRequests() -> [MacScope.Phase2ShellBrokerCommandRequest] {
        requests
    }

    func lastLaunchPayload() throws -> MacScope.Phase2ShellBrokerLaunchProcessRequest? {
        guard let request = requests.last(where: { $0.command == .launchProcess }) else { return nil }
        return try MacScope.Phase2ShellBrokerWireCodec.decodeLaunchProcessRequest(request.payload)
    }

    func lastWriteInputPayload() throws -> MacScope.Phase2ShellBrokerWriteInputRequest? {
        guard let request = requests.last(where: { $0.command == .writeInput }) else { return nil }
        return try MacScope.Phase2ShellBrokerWireCodec.decodeWriteInputRequest(request.payload)
    }

    func lastPollPayload() throws -> MacScope.Phase2ShellBrokerPollTranscriptRequest? {
        guard let request = requests.last(where: { $0.command == .pollTranscript }) else { return nil }
        return try MacScope.Phase2ShellBrokerWireCodec.decodePollTranscriptRequest(request.payload)
    }

    func lastResizePayload() throws -> MacScope.Phase2ShellBrokerResizeTerminalRequest? {
        guard let request = requests.last(where: { $0.command == .resizeTerminal }) else { return nil }
        return try MacScope.Phase2ShellBrokerWireCodec.decodeResizeTerminalRequest(request.payload)
    }

    func lastSignalPayload() throws -> MacScope.Phase2ShellBrokerSendSignalRequest? {
        guard let request = requests.last(where: { $0.command == .sendSignal }) else { return nil }
        return try MacScope.Phase2ShellBrokerWireCodec.decodeSendSignalRequest(request.payload)
    }

    func lastReconnectPayload() throws -> MacScope.Phase2ShellBrokerReconnectSessionRequest? {
        guard let request = requests.last(where: { $0.command == .reconnectSession }) else { return nil }
        return try MacScope.Phase2ShellBrokerWireCodec.decodeReconnectSessionRequest(request.payload)
    }

    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake {
        .boundaryReady(brokerIncarnationID: brokerIncarnationID)
    }

    func perform(
        _ request: MacScope.Phase2ShellBrokerCommandRequest
    ) async throws -> MacScope.Phase2ShellBrokerCommandResponse {
        requests.append(request)
        if responses.isEmpty, autoDurable { return try automaticDurableResponse(for: request) }
        guard !responses.isEmpty else {
            return MacScope.Phase2ShellBrokerCommandResponse(
                commandID: request.commandID,
                command: request.command,
                status: .failed,
                issues: ["missingFakeResponse"]
            )
        }
        var response = responses.removeFirst()
        if response.commandID == nil || response.command == nil {
            response = MacScope.Phase2ShellBrokerCommandResponse(
                commandID: response.commandID ?? request.commandID,
                command: response.command ?? request.command,
                status: response.status,
                sessionID: response.sessionID,
                requestID: response.requestID,
                lifecycleState: response.lifecycleState,
                processIdentifier: response.processIdentifier,
                executablePath: response.executablePath,
                observedProcessAbsent: response.observedProcessAbsent,
                outcome: response.outcome,
                bytesWritten: response.bytesWritten,
                transcriptEvents: response.transcriptEvents,
                nextTranscriptSequence: response.nextTranscriptSequence,
                issues: response.issues,
                durableIdentity: response.durableIdentity,
                durableClientAttached: response.durableClientAttached
            )
        }
        return response
    }

    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        MacScope.ShellBrokerXPCProcessReceipt(
            processIdentifier: 42,
            connectionIdentity: storeShellUUID(99),
            wireProtocol: MacScope.Phase2ShellBrokerProtocolIdentity.wireProtocol,
            supportedCommands: MacScope.Phase2ShellBrokerCommandKind.allCases
        )
    }

    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool {
        receipt.processIdentifier == 42
    }

    func reset() async {}

    private func automaticDurableResponse(for request: MacScope.Phase2ShellBrokerCommandRequest) throws -> MacScope.Phase2ShellBrokerCommandResponse {
        switch request.command {
        case .launchDurableProcess:
            let payload = try MacScope.Phase2ShellBrokerWireCodec.decodeLaunchDurableProcessRequest(request.payload)
            let secret = try Phase2DurableShellBrokerCapabilitySecret(bytes: Data(payload.capabilitySecretBytes))
            let process = Phase2DurableShellBrokerProcessIdentity(
                processIdentifier: 910, processStartTimeUnixNanoseconds: 123_456,
                executablePath: payload.durableLaunch.executablePath, processGroupIdentifier: 910
            )
            let identity = Phase2DurableShellBrokerIdentity(
                launchRequest: payload.durableLaunch, processIdentity: process,
                createdAt: payload.durableLaunch.createdAt, expiresAt: payload.durableLaunch.expiresAt,
                nextTranscriptSequence: 1,
                capabilityVerifierSHA256: secret.verifier(launchRequest: payload.durableLaunch, processIdentity: process)
            )
            durableIdentity = identity
            return durableResponse(request, identity: identity, attached: true)
        case .commitDurableSession:
            return durableResponse(request, identity: try requiredDurableIdentity(), attached: true)
        case .durableSessionStatus:
            return durableResponse(request, identity: try requiredDurableIdentity(), attached: false)
        case .attachDurableSession:
            return durableResponse(request, identity: try requiredDurableIdentity(), attached: true)
        case .cleanupProcess:
            let identity = try requiredDurableIdentity()
            return .init(
                commandID: request.commandID, command: request.command, status: .accepted,
                sessionID: identity.sessionID, requestID: identity.launchRequest.requestID,
                lifecycleState: "terminal", processIdentifier: identity.processIdentity.processIdentifier,
                observedProcessAbsent: true, outcome: "canceled", nextTranscriptSequence: 1,
                durableIdentity: identity, durableClientAttached: false
            )
        default:
            return .init(commandID: request.commandID, command: request.command, status: .failed, issues: ["unsupportedAutoDurableCommand"])
        }
    }

    private func requiredDurableIdentity() throws -> Phase2DurableShellBrokerIdentity {
        guard let durableIdentity else { throw StoreShellTransportError.missingDurableIdentity }
        return durableIdentity
    }

    private func durableResponse(
        _ request: MacScope.Phase2ShellBrokerCommandRequest,
        identity: Phase2DurableShellBrokerIdentity,
        attached: Bool
    ) -> MacScope.Phase2ShellBrokerCommandResponse {
        .init(
            commandID: request.commandID, command: request.command, status: .accepted,
            sessionID: identity.sessionID, requestID: identity.launchRequest.requestID,
            lifecycleState: durableLifecycleState, processIdentifier: identity.processIdentity.processIdentifier,
            executablePath: identity.processIdentity.executablePath, nextTranscriptSequence: 1,
            durableIdentity: identity, durableClientAttached: attached
        )
    }
}

private func storeShellDurableReply(
    to request: MacScope.Phase2ShellBrokerCommandRequest,
    identity: Phase2DurableShellBrokerIdentity,
    lifecycle: String,
    attached: Bool
) -> MacScope.Phase2ShellBrokerCommandResponse {
    .init(
        commandID: request.commandID, command: request.command, status: .accepted,
        sessionID: identity.sessionID, requestID: identity.launchRequest.requestID,
        lifecycleState: lifecycle, processIdentifier: identity.processIdentity.processIdentifier,
        executablePath: identity.processIdentity.executablePath, nextTranscriptSequence: 1,
        durableIdentity: identity, durableClientAttached: attached
    )
}

private actor GatedStoreShellBrokerTransport: MacScope.ShellBrokerXPCTransport {
    typealias Request = MacScope.Phase2ShellBrokerCommandRequest
    typealias Response = MacScope.Phase2ShellBrokerCommandResponse

    private let brokerIncarnationID: UUID?

    init(brokerIncarnationID: UUID? = nil) {
        self.brokerIncarnationID = brokerIncarnationID
    }

    private var requests: [Request] = []
    private var unobservedRequests: [Request] = []
    private var requestWaiters: [CheckedContinuation<Request, Never>] = []
    private var responseWaiters: [UUID: CheckedContinuation<Response, Never>] = [:]

    func nextRequest() async -> Request {
        if !unobservedRequests.isEmpty {
            return unobservedRequests.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func complete(_ response: Response, for commandID: UUID) {
        guard let continuation = responseWaiters.removeValue(forKey: commandID) else {
            preconditionFailure("No pending ShellBroker command for \(commandID)")
        }
        continuation.resume(returning: response)
    }

    func handshake() async throws -> MacScope.Phase2ShellBrokerHandshake {
        .boundaryReady(brokerIncarnationID: brokerIncarnationID)
    }

    func perform(_ request: Request) async throws -> Response {
        requests.append(request)
        if requestWaiters.isEmpty {
            unobservedRequests.append(request)
        } else {
            requestWaiters.removeFirst().resume(returning: request)
        }
        return await withCheckedContinuation { continuation in
            responseWaiters[request.commandID] = continuation
        }
    }

    func prepareBrokerProcessReceipt() async throws -> MacScope.ShellBrokerXPCProcessReceipt {
        MacScope.ShellBrokerXPCProcessReceipt(
            processIdentifier: 43,
            connectionIdentity: storeShellUUID(98),
            wireProtocol: MacScope.Phase2ShellBrokerProtocolIdentity.wireProtocol,
            supportedCommands: MacScope.Phase2ShellBrokerCommandKind.allCases
        )
    }

    func revalidateBrokerProcessReceipt(_ receipt: MacScope.ShellBrokerXPCProcessReceipt) async -> Bool {
        receipt.processIdentifier == 43
    }

    func reset() async {}
}

private enum StoreShellTransportError: Error { case missingDurableIdentity }

private actor StoreShellLedgerSaveGate {
    private var didArrive = false
    private var arrivals = 0
    private var isOpen = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        didArrive = true
        arrivals += 1
        arrivalWaiter?.resume()
        arrivalWaiter = nil
        guard !isOpen else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilArrived() async {
        guard !didArrive else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func open() {
        isOpen = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func arrivalCount() -> Int {
        arrivals
    }
}

private actor StoreShellLedgerSaveSequenceGate {
    private var arrivals = 0
    private var arrivalWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completionWaiters: [CheckedContinuation<WorkspaceDocumentWriteOutcome, Never>] = []
    private var queuedOutcomes: [WorkspaceDocumentWriteOutcome] = []

    func save() async -> WorkspaceDocumentWriteOutcome {
        arrivals += 1
        let readyWaiters = arrivalWaiters.filter { arrivals >= $0.0 }
        arrivalWaiters.removeAll { arrivals >= $0.0 }
        readyWaiters.forEach { $0.1.resume() }
        if !queuedOutcomes.isEmpty {
            return queuedOutcomes.removeFirst()
        }
        return await withCheckedContinuation { completionWaiters.append($0) }
    }

    func waitUntilArrival(_ expectedCount: Int) async {
        guard arrivals < expectedCount else { return }
        await withCheckedContinuation { arrivalWaiters.append((expectedCount, $0)) }
    }

    func completeNext(with outcome: WorkspaceDocumentWriteOutcome) {
        guard !completionWaiters.isEmpty else {
            queuedOutcomes.append(outcome)
            return
        }
        completionWaiters.removeFirst().resume(returning: outcome)
    }
}

private final class MemoryCapabilitySecurityClient: Phase2DurableShellBrokerSecurityClient, @unchecked Sendable {
    private let lock = NSLock()
    private var bytesByAccount: [String: Data] = [:]

    func add(_ attributes: CFDictionary) -> OSStatus {
        let values = attributes as NSDictionary
        guard let account = values[kSecAttrAccount] as? String,
              let data = values[kSecValueData] as? Data else { return errSecParam }
        return lock.withLock {
            guard bytesByAccount[account] == nil else { return errSecDuplicateItem }
            bytesByAccount[account] = data
            return errSecSuccess
        }
    }

    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let values = query as NSDictionary
        guard let account = values[kSecAttrAccount] as? String else { return errSecParam }
        return lock.withLock {
            guard let data = bytesByAccount[account] else { return errSecItemNotFound }
            result?.pointee = data as CFData
            return errSecSuccess
        }
    }

    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus {
        let queryValues = query as NSDictionary
        let updates = attributesToUpdate as NSDictionary
        guard let account = queryValues[kSecAttrAccount] as? String,
              let data = updates[kSecValueData] as? Data else { return errSecParam }
        return lock.withLock {
            guard bytesByAccount[account] != nil else { return errSecItemNotFound }
            bytesByAccount[account] = data
            return errSecSuccess
        }
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        let values = query as NSDictionary
        guard let account = values[kSecAttrAccount] as? String else { return errSecParam }
        return lock.withLock {
            bytesByAccount.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

private final class MissingCapabilitySecurityClient: Phase2DurableShellBrokerSecurityClient, @unchecked Sendable {
    let status: OSStatus
    init(status: OSStatus) { self.status = status }
    func add(_ attributes: CFDictionary) -> OSStatus { status }
    func copyMatching(_ query: CFDictionary, result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { status }
    func update(_ query: CFDictionary, attributesToUpdate: CFDictionary) -> OSStatus { status }
    func delete(_ query: CFDictionary) -> OSStatus { status }
}

private func storeShellUUID(_ value: UInt16) -> UUID {
    let low = UInt8(truncatingIfNeeded: value)
    let high = UInt8(truncatingIfNeeded: value >> 8)
    guard high != 0 else {
        return UUID(uuid: (low, low, low, low, low, low, low, low, low, low, low, low, low, low, low, low))
    }
    return UUID(uuid: (high, low, high, low, high, low, high, low, high, low, high, low, high, low, high, low))
}

private func storeShellBytes(_ string: String) -> [UInt8] {
    Array(string.utf8)
}

private func temporaryShellPackageURL(_ name: String) throws -> (parent: URL, url: URL) {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("mscope-shell-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return (parent, parent.appendingPathComponent(name, isDirectory: true))
}

private func storeShellWireEvent(
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

private func storeShellAcceptedResponse(
    commandID: UUID?,
    command: MacScope.Phase2ShellBrokerCommandKind?,
    sessionID: UUID,
    requestID: UUID,
    lifecycleState: String? = nil,
    processIdentifier: Int32? = nil,
    executablePath: String? = nil,
    observedProcessAbsent: Bool? = nil,
    outcome: String? = nil,
    bytesWritten: Int? = nil,
    transcriptEvents: [MacScope.Phase2ShellBrokerTranscriptEventWire] = [],
    nextTranscriptSequence: UInt64? = nil,
    issues: [String] = []
) -> MacScope.Phase2ShellBrokerCommandResponse {
    MacScope.Phase2ShellBrokerCommandResponse(
        commandID: commandID,
        command: command,
        status: .accepted,
        sessionID: sessionID,
        requestID: requestID,
        lifecycleState: lifecycleState,
        processIdentifier: processIdentifier,
        executablePath: executablePath,
        observedProcessAbsent: observedProcessAbsent,
        outcome: outcome,
        bytesWritten: bytesWritten,
        transcriptEvents: transcriptEvents,
        nextTranscriptSequence: nextTranscriptSequence,
        issues: issues
    )
}

// MS-17 (audit patch 0002): interactive pastes are offered to the broker in bounded
// chunks so every encoded writeInput command stays under the 64 KiB message cap.
// Lives in this file to reuse its private broker transport and projection helpers.
@MainActor
final class InteractiveShellInputWireBudgetTests: XCTestCase {
    private func encodedSize(count: Int, byte: UInt8) throws -> Int {
        let payload = try MacScope.Phase2ShellBrokerWireCodec.encodeWriteInputRequest(
            MacScope.Phase2ShellBrokerWriteInputRequest(
                sessionID: UUID(), requestID: UUID(),
                bytes: Array(repeating: byte, count: count)
            )
        )
        return try MacScope.Phase2ShellBrokerWireCodec.encodeCommandRequest(
            MacScope.Phase2ShellBrokerCommandRequest(
                commandID: UUID(), command: .writeInput, payload: payload
            )
        ).count
    }

    func testInteractiveChunkFitsWorstDigitWidth() throws {
        XCTAssertEqual(WorkspaceStore.phase2ShellInputChunkBytes, 4_096)
        for byte in [UInt8(0), UInt8(65), UInt8(255)] {
            XCTAssertLessThanOrEqual(
                try encodedSize(count: WorkspaceStore.phase2ShellInputChunkBytes, byte: byte),
                MacScope.Phase2ShellBrokerProtocolIdentity.maximumMessageBytes
            )
        }
    }

    func testUnchunkedSixteenKiBAsciiDoesNotFit() throws {
        XCTAssertGreaterThan(
            try encodedSize(count: 16_384, byte: 65),
            MacScope.Phase2ShellBrokerProtocolIdentity.maximumMessageBytes
        )
    }

    func testSixteenKiBAsciiPasteArrivesByteExact() async throws {
        try await assertPasteArrivesByteExact(Self.asciiPaste(count: 16 * 1024))
    }

    func testTwoHundredFiftySixKiBAsciiPasteArrivesByteExact() async throws {
        try await assertPasteArrivesByteExact(Self.asciiPaste(count: 256 * 1024))
    }

    func testOneMiBAsciiPasteArrivesByteExact() async throws {
        try await assertPasteArrivesByteExact(Self.asciiPaste(count: 1024 * 1024))
    }

    func testSixteenKiBMultibytePasteArrivesByteExact() async throws {
        try await assertPasteArrivesByteExact(Self.multibytePaste(count: 16 * 1024))
    }

    func testTwoHundredFiftySixKiBMultibytePasteArrivesByteExact() async throws {
        try await assertPasteArrivesByteExact(Self.multibytePaste(count: 256 * 1024))
    }

    func testOneMiBMultibytePasteArrivesByteExact() async throws {
        try await assertPasteArrivesByteExact(Self.multibytePaste(count: 1024 * 1024))
    }

    func testStopStaysResponsiveDuringLargePaste() async throws {
        let transport = GatedStoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let sessionID = UUID(), requestID = UUID()
        store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
        let bytes = Self.asciiPaste(count: 1024 * 1024)
        let paste = Task { @MainActor in await store.writePhase2ShellInput(bytes) }
        var sequence: UInt64 = 1
        for _ in 0..<3 {
            let write = await transport.nextRequest()
            XCTAssertEqual(write.command, .writeInput)
            let offered = try MacScope.Phase2ShellBrokerWireCodec.decodeWriteInputRequest(write.payload).bytes
            await transport.complete(.init(commandID: write.commandID, command: .writeInput, status: .accepted,
                sessionID: sessionID, requestID: requestID, bytesWritten: offered.count,
                transcriptEvents: [storeShellWireEvent(sessionID: sessionID, sequence: sequence, source: .human,
                    payload: .input(offered))], nextTranscriptSequence: sequence + 1), for: write.commandID)
            sequence += 1
        }
        let fourth = await transport.nextRequest()
        XCTAssertEqual(fourth.command, .writeInput)
        let stop = Task { @MainActor in await store.cleanupPhase2ShellSession(reason: "userCancel") }
        await Task.yield()
        let fourthOffered = try MacScope.Phase2ShellBrokerWireCodec.decodeWriteInputRequest(fourth.payload).bytes
        await transport.complete(.init(commandID: fourth.commandID, command: .writeInput, status: .accepted,
            sessionID: sessionID, requestID: requestID, bytesWritten: fourthOffered.count,
            transcriptEvents: [storeShellWireEvent(sessionID: sessionID, sequence: sequence, source: .human,
                payload: .input(fourthOffered))], nextTranscriptSequence: sequence + 1), for: fourth.commandID)
        let cleanup = await transport.nextRequest()
        XCTAssertEqual(cleanup.command, .cleanupProcess)
        await transport.complete(.init(commandID: cleanup.commandID, command: .cleanupProcess, status: .accepted,
            sessionID: sessionID, requestID: requestID, processIdentifier: 901,
            observedProcessAbsent: true, outcome: "canceled"), for: cleanup.commandID)
        await stop.value
        XCTAssertFalse(store.phase2ShellSession.isRunning)
        let completed = await paste.value
        XCTAssertFalse(completed)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 5)
    }

    private func assertPasteArrivesByteExact(
        _ bytes: [UInt8],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let transport = GatedStoreShellBrokerTransport()
        let store = makeStore(transport: transport)
        let sessionID = UUID(), requestID = UUID()
        store.installPhase2ShellSessionProjection(storeRunningProjection(sessionID: sessionID, requestID: requestID))
        let paste = Task { @MainActor in await store.writePhase2ShellInput(bytes) }
        var delivered: [UInt8] = []
        delivered.reserveCapacity(bytes.count)
        var sequence: UInt64 = 1
        var writes = 0
        while delivered.count < bytes.count {
            let request = await transport.nextRequest()
            XCTAssertEqual(request.command, .writeInput, file: file, line: line)
            let encoded = try MacScope.Phase2ShellBrokerWireCodec.encodeCommandRequest(request)
            XCTAssertLessThanOrEqual(encoded.count, MacScope.Phase2ShellBrokerProtocolIdentity.maximumMessageBytes,
                                     file: file, line: line)
            let offered = try MacScope.Phase2ShellBrokerWireCodec.decodeWriteInputRequest(request.payload).bytes
            XCTAssertFalse(offered.isEmpty, file: file, line: line)
            XCTAssertLessThanOrEqual(offered.count, WorkspaceStore.phase2ShellInputChunkBytes, file: file, line: line)
            // Every offer resumes exactly at the broker-acknowledged offset.
            XCTAssertEqual(offered, Array(bytes[delivered.count..<(delivered.count + offered.count)]),
                           file: file, line: line)
            writes += 1
            // Simulate an occasional short write by a child that is not keeping up.
            let accepted = writes % 16 == 0 ? max(1, offered.count / 3) : offered.count
            let prefix = Array(offered.prefix(accepted))
            await transport.complete(.init(commandID: request.commandID, command: .writeInput,
                status: accepted == offered.count ? .accepted : .partial,
                sessionID: sessionID, requestID: requestID, bytesWritten: accepted,
                transcriptEvents: [storeShellWireEvent(sessionID: sessionID, sequence: sequence, source: .human,
                    payload: .input(prefix))], nextTranscriptSequence: sequence + 1), for: request.commandID)
            sequence += 1
            delivered += prefix
        }
        let completed = await paste.value
        XCTAssertTrue(completed, file: file, line: line)
        XCTAssertEqual(delivered, bytes, file: file, line: line)
        XCTAssertNil(store.phase2ShellSession.lastError, file: file, line: line)
        let count = await transport.requestCount()
        XCTAssertEqual(count, writes, file: file, line: line)
    }

    private static func asciiPaste(count: Int) -> [UInt8] {
        let line = Array("echo the quick brown fox jumps over the lazy dog 0123456789\n".utf8)
        return (0..<count).map { line[$0 % line.count] }
    }

    private static func multibytePaste(count: Int) -> [UInt8] {
        let unit = Array("héllo wörld 世界 \u{1F642} ✓ — ".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count + unit.count)
        while bytes.count < count { bytes += unit }
        return bytes
    }
}
