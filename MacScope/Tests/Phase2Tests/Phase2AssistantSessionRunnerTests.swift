import XCTest
@testable import MacScope

@MainActor
final class Phase2AssistantSessionRunnerTests: XCTestCase {
    func testAssistantToolSelectionPlanOffersOnlyRequiredR1ReadTools() throws {
        var ids = [
            assistantID(101),
            assistantID(102),
            assistantID(103),
        ].makeIterator()

        let plan = try Phase2AssistantToolSelectionPlan(
            operations: [
                .functionReview,
                .workspaceSummary,
                .selectionExplain,
            ],
            handleIDProvider: { ids.next()! }
        )

        XCTAssertEqual(plan.handles.map(\.operationID), [
            .workspaceSummary,
            .selectionExplain,
            .functionReview,
        ])
        XCTAssertEqual(plan.handles.map(\.handleID), [
            assistantID(102),
            assistantID(103),
            assistantID(101),
        ])
        XCTAssertEqual(plan.projectedTools.map(\.functionName), [
            "macscope_workspace_summary_v1",
            "macscope_selection_explain_v1",
            "macscope_function_review_v1",
        ])
        XCTAssertTrue(
            plan.projectedTools.allSatisfy {
                String(decoding: $0.parameters.canonicalJSONBytes(), as: UTF8.self)
                    .contains($0.handleID.uuidString)
            }
        )
    }

    func testAssistantProviderVisibleToolOperationsExcludeSupplementalApplicationGraph() {
        XCTAssertEqual(Phase2AssistantIntent.askMacScope.requiredOperations, [.workspaceSummary])
        XCTAssertEqual(Phase2AssistantIntent.askMacScope.supplementalOperations, [.applicationGraphSummary])
        XCTAssertEqual(Phase2AssistantIntent.askMacScope.providerVisibleToolOperations, [.workspaceSummary])
        XCTAssertEqual(Phase2AssistantIntent.explainSelection.providerVisibleToolOperations, [.selectionExplain])
        XCTAssertEqual(Phase2AssistantIntent.reviewFunction.providerVisibleToolOperations, [
            .functionReview,
            .decompilerNativeResult,
            .decompilerMacScopeResult,
            .decompilerCompare,
        ])
    }

    func testAssistantToolSelectionPlanOffersDecompilerReadsInFrozenOrder() throws {
        var ids = [assistantID(110), assistantID(111), assistantID(112)].makeIterator()
        let plan = try Phase2AssistantToolSelectionPlan(
            operations: [.decompilerCompare, .decompilerNativeResult, .decompilerMacScopeResult],
            handleIDProvider: { ids.next()! }
        )

        XCTAssertEqual(plan.handles.map(\.operationID), [
            .decompilerNativeResult,
            .decompilerMacScopeResult,
            .decompilerCompare,
        ])
        XCTAssertEqual(plan.projectedTools.map(\.functionName), [
            "macscope_native_decompilation_v1",
            "macscope_decompilation_v1",
            "macscope_decompiler_compare_v1",
        ])
    }

    func testAssistantToolSelectionPlanRejectsNonR1ToolAuthority() {
        XCTAssertThrowsError(try Phase2AssistantToolSelectionPlan(operations: [.applicationGraphSummary])) {
            XCTAssertEqual(
                $0 as? Phase2AssistantToolSelectionPlanError,
                .unsupportedOperation(.applicationGraphSummary)
            )
        }
        XCTAssertThrowsError(try Phase2AssistantToolSelectionPlan(operations: [
            .workspaceSummary,
            .workspaceSummary,
        ])) {
            XCTAssertEqual(
                $0 as? Phase2AssistantToolSelectionPlanError,
                .duplicateOperation(.workspaceSummary)
            )
        }
        let repeatedHandle = assistantID(104)
        XCTAssertThrowsError(try Phase2AssistantToolSelectionPlan(
            operations: [.workspaceSummary, .selectionExplain],
            handleIDProvider: { repeatedHandle }
        )) {
            XCTAssertEqual(
                $0 as? Phase2AssistantToolSelectionPlanError,
                .duplicateHandle(repeatedHandle)
            )
        }
    }

    func testAssistantToolSelectionPlanRejectsZeroHandleIdentity() {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        XCTAssertThrowsError(try Phase2AssistantToolSelectionPlan(
            operations: [.workspaceSummary],
            handleIDProvider: { zero }
        )) {
            XCTAssertEqual(
                $0 as? Phase2AssistantToolSelectionPlanError,
                .invalidHandle(zero)
            )
        }
    }

    func testAskMacScopeCompilesWorkspaceAndApplicationGraphEvidenceAndDispatchesFinalization() async throws {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator()
        let runner = Phase2AssistantSessionRunner(
            sessionIDProvider: { assistantID(50) },
            turnIDProvider: { assistantID(51) },
            requestIDProvider: { assistantID(52) }
        )

        let result = await runner.run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecution?.candidate.operationID, .workspaceSummary)
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [
            .workspaceSummary,
            .applicationGraphSummary,
        ])
        XCTAssertEqual(Set(result.groundedContext?.records.map(\.descriptor.id) ?? []), [
            .workspaceSummary,
            .applicationGraphSummary,
        ])
        XCTAssertEqual(coordinator.requests.count, 1)
        let request = try XCTUnwrap(coordinator.requests.first)
        XCTAssertEqual(request.phase, .finalization)
        XCTAssertEqual(request.toolHandles, [])
        XCTAssertEqual(request.userGoal, "Summarize the current workspace.")
        XCTAssertEqual(request.sessionID, assistantID(50))
        XCTAssertEqual(request.turnID, assistantID(51))
        XCTAssertEqual(request.requestID, assistantID(52))
        XCTAssertEqual(request.groundedContext.records, result.groundedContext?.records)
        XCTAssertEqual(Set(request.groundedContext.records.map(\.descriptor.id)), [
            .workspaceSummary,
            .applicationGraphSummary,
        ])
        XCTAssertTrue(
            request.groundedContext.records.contains {
                $0.descriptor.id == .applicationGraphSummary
                    && $0.data.field("declaredDependencyCount") == .unsignedInteger(1)
                    && $0.data.field("externalDependencyCount") == .unsignedInteger(1)
            }
        )
        XCTAssertEqual(result.inferenceOutcome?.finalCandidate?.text, "grounded answer")
        XCTAssertTrue(result.isAcceptedFinalAnswer)
    }

    func testAskMacScopeAddsApprovedOneShotShellEvidenceToFinalizationGoal() async throws {
        let store = makeAssistantStore()
        let proposalID = assistantID(230)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["approved shell evidence"],
            workingDirectoryPath: "/tmp",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(proposal)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)
        let shellResult = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: proposalID,
            executor: AssistantRunnerRecordingOneShotExecutor()
        )
        XCTAssertEqual(shellResult.disposition, .completed)

        let coordinator = RecordingAssistantCoordinator()
        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.phase, .finalization)
        XCTAssertEqual(request.toolHandles, [])
        XCTAssertTrue(
            request.userGoal.contains("[MacScope app-reviewed provider-visible shell execution evidence]"),
            request.userGoal
        )
        XCTAssertTrue(request.userGoal.contains("Command: \"/bin/echo\" \"approved shell evidence\""), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("Working directory: \"/tmp\""), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("Disposition: completed"), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("Standard output:\napproved shell evidence\n"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("shellBrokerSession"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("terminalSurfaceID"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("processIdentifier"), request.userGoal)
        XCTAssertTrue(request.userGoal.utf8.count <= request.limits.maximumGoalBytes)
    }

    func testShellResultContinuationIncludesOnlyTheSelectedExecution() async throws {
        let store = makeAssistantStore()
        let olderProposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(240),
            executablePath: "/bin/echo",
            arguments: ["selected older result"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(olderProposal)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: olderProposal.proposalID)
        let olderResult = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: olderProposal.proposalID,
            executor: AssistantRunnerRecordingOneShotExecutor()
        )

        let newerProposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(241),
            executablePath: "/bin/echo",
            arguments: ["unrelated newer result"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(newerProposal)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: newerProposal.proposalID)
        let newerResult = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: newerProposal.proposalID,
            executor: AssistantRunnerRecordingOneShotExecutor()
        )
        XCTAssertEqual(olderResult.disposition, .completed)
        XCTAssertEqual(newerResult.disposition, .completed)

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Explain this shell result.",
            store: store,
            coordinator: RecordingAssistantCoordinator(),
            contextOptions: Phase2AssistantContextOptions(
                shellExecutionID: olderResult.id
            )
        )

        let request = try XCTUnwrap(result.request)
        XCTAssertTrue(request.userGoal.contains(olderResult.id.uuidString), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("selected older result"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains(newerResult.id.uuidString), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("unrelated newer result"), request.userGoal)
    }

    func testUnknownShellResultContinuationDoesNotExposeOtherExecutionEvidence() async throws {
        let store = makeAssistantStore()
        let proposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(242),
            executablePath: "/bin/echo",
            arguments: ["must remain excluded"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(proposal)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposal.proposalID)
        _ = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: proposal.proposalID,
            executor: AssistantRunnerRecordingOneShotExecutor()
        )

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Explain this shell result.",
            store: store,
            coordinator: RecordingAssistantCoordinator(),
            contextOptions: Phase2AssistantContextOptions(
                shellExecutionID: assistantID(243)
            )
        )

        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.userGoal, "Explain this shell result.")
        XCTAssertFalse(request.userGoal.contains("must remain excluded"), request.userGoal)
    }

    func testCompletedShellExecutionCreatesExplicitContinuationDraft() throws {
        let result = Phase2AIShellOneShotExecutionResult(
            id: assistantID(244),
            proposalID: assistantID(245),
            executablePath: "/bin/echo",
            arguments: ["ready"],
            workingDirectoryPath: nil,
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            disposition: .completed,
            terminationStatus: 0,
            standardOutput: "ready\n",
            standardError: "",
            outputWasTruncated: false,
            startedAt: Date(timeIntervalSince1970: 8_000),
            completedAt: Date(timeIntervalSince1970: 8_001),
            failureMessage: nil
        )

        let draft = try XCTUnwrap(Phase2AssistantShellContinuationDraft(result: result))
        XCTAssertEqual(draft.executionID, result.id)
        XCTAssertEqual(draft.intent, .askMacScope)
        XCTAssertTrue(draft.userGoal.contains(result.id.uuidString))
    }

    func testUnsuccessfulShellExecutionDoesNotCreateContinuationDraft() {
        let unsuccessfulDispositions: [Phase2AIShellOneShotExecutionDisposition] = [
            .nonZeroExit,
            .timedOut,
            .launchFailed,
            .validationRejected,
            .authorizationRejected,
        ]
        for disposition in unsuccessfulDispositions {
            let result = Phase2AIShellOneShotExecutionResult(
                proposalID: assistantID(246),
                executablePath: "/bin/false",
                arguments: [],
                workingDirectoryPath: nil,
                timeoutMilliseconds: 1_000,
                maximumOutputBytes: 1_024,
                disposition: disposition,
                terminationStatus: disposition == .nonZeroExit ? 1 : nil,
                standardOutput: "",
                standardError: "failed",
                outputWasTruncated: false,
                startedAt: Date(timeIntervalSince1970: 8_000),
                completedAt: Date(timeIntervalSince1970: 8_001),
                failureMessage: "failed"
            )

            XCTAssertNil(Phase2AssistantShellContinuationDraft(result: result), "\(disposition)")
        }
    }

    func testAskMacScopeDoesNotExposeRejectedShellProposalEvidenceToProvider() async throws {
        let store = makeAssistantStore()
        let rejected = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: assistantID(231),
            executor: AssistantRunnerRecordingOneShotExecutor()
        )
        XCTAssertEqual(rejected.disposition, .authorizationRejected)

        let coordinator = RecordingAssistantCoordinator()
        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.userGoal, "Summarize the current workspace.")
        XCTAssertFalse(request.userGoal.contains("provider-visible shell execution evidence"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("authorizationRejected"), request.userGoal)
    }

    func testAskMacScopeStagesAcceptedProviderShellProposalForHumanReview() async throws {
        let store = makeAssistantStore()
        let proposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(233),
            executablePath: "/bin/echo",
            arguments: ["from provider"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )
        let coordinator = RecordingAssistantCoordinator(finalShellProposals: [proposal])

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        result.stageAcceptedProviderProposals(in: store)
        XCTAssertEqual(result.inferenceOutcome?.shellProposals, [proposal])
        XCTAssertEqual(store.phase2AIShellProposalReview.proposal, proposal)
        XCTAssertEqual(store.phase2AIShellProposalReview.disposition, .staged)
        XCTAssertEqual(store.phase2AIShellProposalReview.humanDecision, .pendingReview)
        XCTAssertTrue(store.phase2AIShellProposalReview.canApproveForFutureShellBrokerPTY)
        XCTAssertFalse(store.phase2AIShellProposalReview.canExecuteShellBrokerPTY)
    }

    func testAskMacScopeStagesAcceptedProviderDebuggerProposalForHumanReview() async throws {
        let store = makeAssistantStore()
        let proposal = Phase2AIDebuggerActionProposal(
            proposalID: assistantID(234),
            action: .stepOver,
            sessionID: assistantID(235),
            lifecycleRevision: 2,
            stopRevision: 1,
            eventSequence: 3,
            requestedAuthority: .controlledRuntimeActions
        )
        let coordinator = RecordingAssistantCoordinator(finalDebuggerActionProposals: [proposal])

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        result.stageAcceptedProviderProposals(in: store)
        XCTAssertEqual(result.inferenceOutcome?.debuggerActionProposals, [proposal])
        XCTAssertEqual(store.phase2AIDebuggerProposalReview.proposal, proposal)
        XCTAssertEqual(store.phase2AIDebuggerProposalReview.disposition, .staged)
        XCTAssertEqual(store.phase2AIDebuggerProposalReview.humanDecision, .pendingReview)
        XCTAssertTrue(store.phase2AIDebuggerProposalReview.canApproveForFutureDebuggerControl)
        XCTAssertFalse(store.phase2AIDebuggerProposalReview.canExecuteDebuggerControl)
    }

    func testAskMacScopeAddsReadOnlyDebuggerEvidenceToFinalizationGoal() async throws {
        let store = makeAssistantStore()
        let debuggerSessionID = assistantID(232)
        let sessionCoordinate = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(rawValue: debuggerSessionID),
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 2)
        )
        let stopCoordinate = DebuggerStopCoordinate(
            session: sessionCoordinate,
            stopRevision: DebuggerStopRevision(rawValue: 1)
        )
        let targetAuthority = try assistantDebuggerAuthority(processID: 4242)
        let selectedThread = DebuggerThreadSummary(
            index: 1,
            queueName: "main",
            stopReason: .breakpoint(address: 0x1000),
            isSelected: true,
            topFrameAddress: 0x1000,
            topFrameFunctionName: "review_me"
        )
        let selectedFrame = DebuggerFrameSummary(
            index: 0,
            address: 0x1000,
            functionName: "review_me",
            moduleName: "assistant-fixture",
            sourceLocation: nil
        )
        let threadIdentity = try XCTUnwrap(DebuggerThreadIdentity(summary: selectedThread))
        let frameIdentity = try XCTUnwrap(DebuggerFrameIdentity(
            thread: threadIdentity,
            summary: selectedFrame
        ))
        let inspectionCoordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
            stop: stopCoordinate,
            targetAuthority: targetAuthority,
            thread: threadIdentity,
            frame: frameIdentity
        ))
        let debuggerSnapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 4242, reason: .breakpoint(address: 0x1000)),
            breakpoints: [
                DebuggerBreakpoint(address: 0x1000, isEnabled: true),
            ],
            threads: [
                selectedThread,
            ],
            frames: [
                selectedFrame,
            ],
            registers: [
                DebuggerRegisterSummary(name: "pc", value: "0x1000", role: "program counter"),
            ],
            memoryRegions: [
                DebuggerMemorySummary(address: 0x1000, byteCount: 4, previewBytes: [0xff, 0x83, 0x00, 0xd1], label: "__TEXT"),
            ],
            statusMessage: "Paused at breakpoint.",
            backendState: .connected(processID: 4242, adapterName: "LLDB"),
            transportSessionCoordinate: sessionCoordinate,
            transportStopCoordinate: stopCoordinate,
            transportEventSequence: DebuggerEventSequence(rawValue: 3),
            transportTargetDisposition: .stopped(processID: 4242),
            transportTargetAuthority: targetAuthority
        )
        store.updatePhase2DebuggerReadOnlySnapshot(
            debuggerSnapshot,
            inspectionCoordinate: inspectionCoordinate
        )
        XCTAssertTrue(
            store.phase2RuntimeAuthorityRecords.isEmpty,
            "publishing available debugger evidence is not provider consumption"
        )

        let coordinator = RecordingAssistantCoordinator()
        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.phase, .finalization)
        XCTAssertEqual(request.toolHandles, [])
        XCTAssertFalse(request.userGoal.contains("[MacScope read-only debugger evidence]"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("Registers:"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("Memory regions:"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("provider-visible shell execution evidence"), request.userGoal)
        XCTAssertFalse(request.userGoal.contains("ShellBroker"), request.userGoal)
        XCTAssertTrue(request.userGoal.utf8.count <= request.limits.maximumGoalBytes)
        XCTAssertTrue(store.phase2RuntimeAuthorityRecords.isEmpty)
    }

    func testAskMacScopeAddsAppReviewedDebuggerControlEvidenceToFinalizationGoal() async throws {
        let store = makeAssistantStore()
        let debuggerSessionID = assistantID(236)
        let coordinate = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(rawValue: debuggerSessionID),
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 7)
        )
        let snapshot = DebuggerSessionSnapshot(
            processState: .paused(processID: 4242, reason: .step),
            breakpoints: [],
            frames: [
                DebuggerFrameSummary(
                    index: 0,
                    address: 0x1000,
                    functionName: "review_me",
                    moduleName: "assistant-fixture",
                    sourceLocation: nil
                ),
            ],
            registers: [],
            memoryRegions: [],
            statusMessage: "Step completed.",
            backendState: .connected(processID: 4242, adapterName: "LLDB"),
            transportSessionCoordinate: coordinate,
            transportStopCoordinate: DebuggerStopCoordinate(
                session: coordinate,
                stopRevision: DebuggerStopRevision(rawValue: 4)
            ),
            transportEventSequence: DebuggerEventSequence(rawValue: 9)
        )
        let event = try XCTUnwrap(DebuggerControlledRuntimeActionEvent(
            sequence: 1,
            action: .stepOver,
            snapshot: snapshot
        ))
        store.updatePhase2DebuggerControlledRuntimeAction(event)
        let executionResult = Phase2AIDebuggerProposalExecutionResult(
                id: assistantID(238),
                proposalID: assistantID(237),
                action: .stepOver,
                runtimeSessionID: event.sessionID,
                lifecycleRevision: event.lifecycleRevision,
                stopRevision: event.stopRevision,
                eventSequence: event.eventSequence,
                disposition: .dispatched,
                failureMessage: nil,
                createdAt: event.createdAt
        )
        store.recordPhase2AIDebuggerProposalExecutionResult(executionResult)

        let coordinator = RecordingAssistantCoordinator()
        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(debuggerExecutionID: executionResult.id)
        )

        XCTAssertNil(result.failure)
        let request = try XCTUnwrap(result.request)
        XCTAssertEqual(request.phase, .finalization)
        XCTAssertTrue(
            request.userGoal.contains("[MacScope app-reviewed debugger control evidence]"),
            request.userGoal
        )
        XCTAssertTrue(request.userGoal.contains("Debugger control execution 1:"), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("Action: Step Over"), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("Runtime session ID: \(debuggerSessionID.uuidString)"), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("Lifecycle revision: 7"), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("Stop revision: 4"), request.userGoal)
        XCTAssertTrue(request.userGoal.contains("Event sequence: 9"), request.userGoal)
    }

    func testProviderSelectedHistoricalREALaterPageReachesFinalizationWithoutCollectingOtherPages() async throws {
        let store = makeAssistantStore()
        let hash = String(repeating: "a", count: 64)
        let authority = REAResultAuthority(workspaceID: store.workspaceID, imageSHA256: hash,
            snapshotID: UUID(), sourceGeneration: 1, resourceSHA256: hash, implementationIdentity: hash)
        func record(_ value: String) throws -> REAResultEvidence {
            let id = UUID()
            let request = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
                "operation": "nativeApplication", "input": [:]])
            let response = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
                "operation": "nativeApplication", "implementationIdentity": hash, "ok": true, "result": ["value": value]])
            return try .init(requestID: id, operation: "nativeApplication", authority: authority,
                requestJSON: request, responseJSON: response)
        }
        let historical = try record(String(repeating: "🙂é漢字", count: 20_000))
        let latest = try record(String(repeating: "n", count: 200_000))
        store.reaResultEvidence = try REAResultEvidenceStore(records: [historical, latest])
        let coordinator = RecordingAssistantCoordinator(toolSelectionOutcome: { request in
            let pages = request.toolHandles.filter { $0.operationID == .reaResultsGet }
            // Round-robin: latest first, historical first, latest second, historical second.
            return assistantToolSelectionOutcome(request: request, proposals: [
                assistantToolProposal(callID: "historical-second-page", handle: pages[3]),
                assistantToolProposal(callID: "historical-third-page", handle: pages[5])
            ])
        })
        let result = await Phase2AssistantSessionRunner().run(intent: .askMacScope,
            userGoal: "Read the historical result continuation.", store: store, coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true))
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.toolSelectionRequest?.limits.maximumToolProposals, 2)
        XCTAssertTrue(result.toolSelectionRequest?.userGoal.contains("Select at most 2 additional reads") == true)
        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection, .finalization])
        let executions = result.readExecutions.filter { $0.candidate.operationID == .reaResultsGet }
        XCTAssertEqual(executions.count, 2)
        let execution = try XCTUnwrap(executions.first)
        guard case let .value(.object(fields)) = execution.candidate.data,
              case let .text(text)? = fields.first(where: { $0.name == "acceptedREAResult" })?.value else {
            return XCTFail("Selected REA page must be readable text")
        }
        let page = try JSONDecoder().decode(REAResultReadProjection.TextPage.self, from: Data(text.utf8))
        XCTAssertEqual(page.record.evidenceID, historical.evidenceID)
        XCTAssertGreaterThan(page.offset, 0)
        XCTAssertNotNil(page.nextOffset)
        XCTAssertEqual(result.request?.groundedContext.records.filter { $0.descriptor.id == .reaResultsGet }.count, 2)
        XCTAssertFalse(result.readExecutions.contains { $0.candidate.operationID == .applicationGraphSummary })
        XCTAssertLessThanOrEqual(result.request?.groundedContext.records.count ?? 99, 3)
    }

    func testThreeExactREAProposalsReportContextBudgetFailureWithoutDroppingEvidence() async throws {
        let store = makeAssistantStore()
        let hash = String(repeating: "a", count: 64)
        let authority = REAResultAuthority(workspaceID: store.workspaceID, imageSHA256: hash,
            snapshotID: UUID(), sourceGeneration: 1, resourceSHA256: hash, implementationIdentity: hash)
        func record(_ value: String) throws -> REAResultEvidence {
            let id = UUID()
            let request = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
                "operation": "nativeApplication", "input": [:]])
            let response = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
                "operation": "nativeApplication", "implementationIdentity": hash, "ok": true, "result": ["value": value]])
            return try .init(requestID: id, operation: "nativeApplication", authority: authority,
                requestJSON: request, responseJSON: response)
        }
        let historical = try record(String(repeating: "🙂é漢字", count: 20_000))
        let latest = try record(String(repeating: "n", count: 200_000))
        store.reaResultEvidence = try REAResultEvidenceStore(records: [historical, latest])
        let coordinator = RecordingAssistantCoordinator(toolSelectionOutcome: { request in
            let pages = request.toolHandles.filter { $0.operationID == .reaResultsGet }
            // Round-robin: latest first, historical first, latest second, historical second.
            return assistantToolSelectionOutcome(request: request, proposals: [
                assistantToolProposal(callID: "historical-second-page", handle: pages[3]),
                assistantToolProposal(callID: "historical-third-page", handle: pages[5]),
                assistantToolProposal(callID: "historical-first-page", handle: pages[1])
            ])
        })
        let result = await Phase2AssistantSessionRunner().run(intent: .askMacScope,
            userGoal: "Read the historical result continuation.", store: store, coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true))
        guard case let .groundedContextFailed(detail)? = result.failure else {
            return XCTFail("Over-budget exact selection must explain its context limit")
        }
        XCTAssertTrue(detail.contains("only 2 additional reads"))
        XCTAssertTrue(detail.contains("No selected evidence was dropped"))
        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection])
        XCTAssertEqual(result.toolSelectionOutcome?.toolProposals.count, 3)
        XCTAssertEqual(result.toolSelectionRequest?.limits.maximumToolProposals, 2)
        XCTAssertTrue(result.readExecutions.isEmpty)
        XCTAssertNil(result.request)
    }

    func testAskMacScopeCanDispatchProviderVisibleToolSelectionBeforeFinalization() async throws {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator()
        var requestIDs = [
            assistantID(52),
            assistantID(53),
        ].makeIterator()
        let runner = Phase2AssistantSessionRunner(
            sessionIDProvider: { assistantID(50) },
            turnIDProvider: { assistantID(51) },
            requestIDProvider: { requestIDs.next()! }
        )

        let result = await runner.run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(coordinator.requests.count, 2)
        let selectionRequest = try XCTUnwrap(result.toolSelectionRequest)
        let finalizationRequest = try XCTUnwrap(result.request)
        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection, .finalization])
        XCTAssertEqual(selectionRequest.sessionID, assistantID(50))
        XCTAssertEqual(finalizationRequest.sessionID, assistantID(50))
        XCTAssertEqual(selectionRequest.turnID, assistantID(51))
        XCTAssertEqual(finalizationRequest.turnID, assistantID(51))
        XCTAssertEqual(selectionRequest.requestID, assistantID(52))
        XCTAssertEqual(finalizationRequest.requestID, assistantID(53))
        XCTAssertEqual(selectionRequest.toolHandles.map(\.operationID), [.workspaceSummary])
        XCTAssertEqual(selectionRequest.groundedContext.records, [])
        XCTAssertEqual(result.toolSelectionOutcome?.disposition, .awaitingTools)
        XCTAssertEqual(result.toolSelectionOutcome?.toolProposals.map(\.operationID), [.workspaceSummary])
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [
            .workspaceSummary,
            .applicationGraphSummary,
        ])
        XCTAssertEqual(Set(finalizationRequest.groundedContext.records.map(\.descriptor.id)), [
            .workspaceSummary,
            .applicationGraphSummary,
        ])
        XCTAssertEqual(finalizationRequest.toolHandles, [])
        XCTAssertTrue(result.isAcceptedFinalAnswer)

        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected accepted assistant answer to render as completed.")
        }
        XCTAssertTrue(
            display.contextDisclosure?.authoritySummary.contains("read-only R1 MacScope handles") == true
        )
        XCTAssertEqual(display.activity?.summary, "2 native reads, 4 accepted provider events")
        XCTAssertEqual(
            display.activity?.facts.first { $0.id == "providerVisibleSelection" }?.value,
            "yes"
        )
        XCTAssertEqual(
            display.activity?.facts.first { $0.id == "readExecutions" }?.value,
            "2"
        )
        XCTAssertEqual(
            display.activity?.facts.first { $0.id == "toolProposals" }?.value,
            "1"
        )
        XCTAssertEqual(display.providerToolCount, 1)
        XCTAssertTrue(display.plainTextExport.contains("Provider tools: read-only R1 MacScope handles"))
        XCTAssertTrue(display.plainTextExport.contains("Activity"))
        XCTAssertTrue(display.plainTextExport.contains("Provider-visible read selection: yes"))
    }

    func testProviderRefreshRevisionChangeWithSameAuthorityAcceptsFinalizationOutcome() async {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator(
            toolSelectionProviderRevision: 7,
            finalizationProviderRevision: 8
        )

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection, .finalization])
        XCTAssertNil(result.failure)
        XCTAssertNotNil(result.inferenceOutcome)
        XCTAssertEqual(result.providerRevision, 8)
    }

    func testCrossPhaseInventoryOrConfigurationChangeRejectsFinalization() async throws {
        let original = makeAssistantConfiguration()
        let changed = try Phase2AIProviderConfiguration(profileID: original.profileID,
            generation: original.generation, endpointOrigin: original.endpointOrigin,
            model: original.model, maximumTokens: original.maximumTokens - 1,
            requestTimeoutMilliseconds: original.requestTimeoutMilliseconds,
            resourceTimeoutMilliseconds: original.resourceTimeoutMilliseconds,
            inferencePolicy: original.inferencePolicy)
        for coordinator in [
            RecordingAssistantCoordinator(finalizationInventorySHA256: String(repeating: "b", count: 64)),
            RecordingAssistantCoordinator(finalizationConfiguration: changed),
        ] {
            let result = await Phase2AssistantSessionRunner().run(intent: .askMacScope,
                userGoal: "Summarize the current workspace.", store: makeAssistantStore(), coordinator: coordinator,
                contextOptions: .init(useProviderVisibleToolSelection: true))
            XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection, .finalization])
            XCTAssertEqual(result.failure, .providerAuthorityChanged)
            XCTAssertNil(result.inferenceOutcome)
        }
    }

    func testToolSelectionAndFinalizationRequireDistinctRequestIdentities() async {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator()
        let repeatedRequestID = assistantID(254)
        let runner = Phase2AssistantSessionRunner(requestIDProvider: { repeatedRequestID })

        let result = await runner.run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection])
        XCTAssertEqual(result.failure, .inferenceInvalidRequest)
        XCTAssertNil(result.request)
    }

    func testAskMacScopeProviderCanSelectExactBoundedDebuggerMemoryForFinalization() async throws {
        let store = makeAssistantStore()
        try installAssistantDebuggerReadEvidence(in: store)
        let coordinator = RecordingAssistantCoordinator(toolSelectionOutcome: { request in
            let handle = request.toolHandles.first { $0.operationID == .debuggerMemory }!
            return assistantToolSelectionOutcome(
                request: request,
                proposals: [
                    assistantToolProposal(callID: "debugger-memory", handle: handle),
                ]
            )
        })

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Inspect the stopped process memory evidence.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertNil(result.failure)
        let selection = try XCTUnwrap(result.toolSelectionRequest)
        XCTAssertEqual(selection.toolHandles.map(\.operationID), [
            .workspaceSummary,
            .debuggerSummary,
            .debuggerFrames,
            .debuggerRegisters,
            .debuggerVariables,
            .debuggerMemory,
        ])
        let finalization = try XCTUnwrap(result.request)
        XCTAssertTrue(
            finalization.userGoal.contains("[MacScope provider-selected typed debugger evidence]"),
            finalization.userGoal
        )
        XCTAssertTrue(finalization.userGoal.contains("Debugger typed read: debugger.memory"))
        XCTAssertTrue(finalization.userGoal.contains("Target identity digest:"))
        XCTAssertTrue(finalization.userGoal.contains("Lifecycle revision: 4"))
        XCTAssertTrue(finalization.userGoal.contains("Stop revision: 2"))
        XCTAssertTrue(finalization.userGoal.contains("Selected thread: #1"))
        XCTAssertTrue(finalization.userGoal.contains("Selected frame: #0 0x0000000000001000"))
        XCTAssertTrue(finalization.userGoal.contains("aa bb cc"), finalization.userGoal)
        XCTAssertEqual(result.readExecutions.first?.candidate.operationID, .workspaceSummary)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, 1)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.surfaces, [.debuggerReadOnly])
    }

    func testReviewFunctionProviderExecutesExactMacScopeDecompilerReadForFinalization() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator(toolSelectionOutcome: { request in
            let handle = request.toolHandles.first {
                $0.operationID == .decompilerMacScopeResult
            }!
            return assistantToolSelectionOutcome(
                request: request,
                proposals: [
                    assistantToolProposal(callID: "decompiler-macscope", handle: handle),
                ]
            )
        })

        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction,
            userGoal: "Review the frozen MacScope render for this function.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertNil(result.failure)
        let selection = try XCTUnwrap(result.toolSelectionRequest)
        XCTAssertEqual(selection.toolHandles.map(\.operationID), [
            .functionReview,
            .decompilerNativeResult,
            .decompilerMacScopeResult,
            .decompilerCompare,
        ])
        XCTAssertEqual(result.toolSelectionOutcome?.toolProposals.map(\.operationID), [
            .decompilerMacScopeResult,
        ])
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [
            .functionReview,
            .decompilerMacScopeResult,
            .functionCallSites,
        ])

        let finalization = try XCTUnwrap(result.request)
        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection, .finalization])
        XCTAssertEqual(finalization.toolHandles, [])
        XCTAssertEqual(Set(finalization.groundedContext.records.map(\.descriptor.id)), [
            .functionReview,
            .decompilerMacScopeResult,
            .functionCallSites,
        ])
        XCTAssertTrue(result.isAcceptedFinalAnswer)
    }

    func testReviewFunctionRequestsCrossTheWorkerWireBeforeProviderDispatch() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator(toolSelectionOutcome: { request in
            let handle = request.toolHandles.first {
                $0.operationID == .decompilerMacScopeResult
            }!
            return assistantToolSelectionOutcome(
                request: request,
                proposals: [assistantToolProposal(callID: "decompiler-macscope", handle: handle)]
            )
        })

        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction,
            userGoal: "",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertNil(result.failure)
        // The production provider encodes every request through the app codec and the worker
        // decodes it with the same closed wire codec; a refused operation fails before dispatch.
        let selection = try XCTUnwrap(result.toolSelectionRequest)
        let decodedSelection = try Phase2AIWorkerWireCodec().decodeRequest(
            Phase2AIWorkerAppCodec().encodeRequest(selection)
        )
        XCTAssertEqual(decodedSelection.toolHandles.map(\.operationID), [
            "function.review",
            "decompiler.native.result",
            "decompiler.macscope.result",
            "decompiler.compare",
        ])
        XCTAssertEqual(selection.limits.maximumToolProposals, 2)
        XCTAssertTrue(selection.userGoal.contains("Select at most 2 additional reads."))
        let finalization = try XCTUnwrap(result.request)
        XCTAssertNoThrow(try Phase2AIWorkerWireCodec().decodeRequest(
            Phase2AIWorkerAppCodec().encodeRequest(finalization)
        ))
    }

    func testReviewFunctionOverBudgetDecompilerSelectionReportsContextLimitWithoutReads() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator(toolSelectionOutcome: { request in
            assistantToolSelectionOutcome(
                request: request,
                proposals: request.toolHandles
                    .filter { $0.operationID != .functionReview }
                    .enumerated()
                    .map { assistantToolProposal(callID: "decompiler-\($0.offset)", handle: $0.element) }
            )
        })

        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction,
            userGoal: "Review every decompiler view.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        guard case let .groundedContextFailed(detail)? = result.failure else {
            return XCTFail("An over-budget selection must explain its context limit, got \(String(describing: result.failure))")
        }
        XCTAssertTrue(detail.contains("only 2 additional reads"), detail)
        XCTAssertEqual(result.toolSelectionOutcome?.toolProposals.count, 3)
        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection])
        XCTAssertTrue(result.readExecutions.isEmpty)
        XCTAssertNil(result.request)
    }

    func testAskMacScopeProviderCanSelectExactDebuggerVariablesAndConsumesAuthorityOnlyWhenIncluded() async throws {
        let store = makeAssistantStore()
        try installAssistantDebuggerReadEvidence(in: store, includeVariables: true)
        let coordinator = RecordingAssistantCoordinator(toolSelectionOutcome: { request in
            let handle = request.toolHandles.first { $0.operationID == .debuggerVariables }!
            return assistantToolSelectionOutcome(
                request: request,
                proposals: [assistantToolProposal(callID: "debugger-variables", handle: handle)]
            )
        })

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Inspect variables in the selected stopped frame.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertNil(result.failure)
        let finalization = try XCTUnwrap(result.request)
        XCTAssertTrue(finalization.userGoal.contains("Debugger typed read: debugger.variables"))
        XCTAssertTrue(finalization.userGoal.contains("Arguments:"), finalization.userGoal)
        XCTAssertTrue(finalization.userGoal.contains("- argc: Int = 2"), finalization.userGoal)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, 1)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.surfaces, [.debuggerReadOnly])
    }

    func testDebuggerReadAuthorityIsNotRecordedWhenFinalizationProviderIsNotReady() async throws {
        let store = makeAssistantStore()
        try installAssistantDebuggerReadEvidence(in: store)
        let coordinator = RecordingAssistantCoordinator(
            result: .notReady(.inventoryRequired),
            toolSelectionOutcome: { request in
                let handle = request.toolHandles.first { $0.operationID == .debuggerMemory }!
                return assistantToolSelectionOutcome(
                    request: request,
                    proposals: [assistantToolProposal(callID: "debugger-memory-not-ready", handle: handle)]
                )
            }
        )

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Inspect memory.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertEqual(result.failure, .inferenceNotReady(.inventoryRequired))
        XCTAssertTrue(store.phase2RuntimeAuthorityRecords.isEmpty)
    }

    func testDebuggerReadAuthorityUsesConsumedProvenanceWhenSnapshotChangesDuringFinalization() async throws {
        let store = makeAssistantStore()
        let consumedSessionID = assistantID(245)
        try installAssistantDebuggerReadEvidence(in: store, sessionID: consumedSessionID)
        let coordinator = RecordingAssistantCoordinator(
            toolSelectionOutcome: { request in
                let handle = request.toolHandles.first { $0.operationID == .debuggerMemory }!
                return assistantToolSelectionOutcome(
                    request: request,
                    proposals: [assistantToolProposal(callID: "debugger-memory-race", handle: handle)]
                )
            },
            finalizationStarted: {
                try! installAssistantDebuggerReadEvidence(
                    in: store,
                    sessionID: assistantID(246),
                    stopRevision: 1
                )
            }
        )

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Inspect memory from the selected stopped frame.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, 1)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.sessionID, consumedSessionID)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.surfaces, [.debuggerReadOnly])
    }

    func testAskMacScopeRejectsDebuggerReadWhenStopChangesAfterProviderSelection() async throws {
        let store = makeAssistantStore()
        try installAssistantDebuggerReadEvidence(in: store)
        let coordinator = RecordingAssistantCoordinator(toolSelectionOutcome: { request in
            let handle = request.toolHandles.first { $0.operationID == .debuggerFrames }!
            try! installAssistantDebuggerReadEvidence(in: store, stopRevision: 3)
            return assistantToolSelectionOutcome(
                request: request,
                proposals: [assistantToolProposal(callID: "stale-frames", handle: handle)]
            )
        })

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Inspect frames.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertEqual(result.failure, .inferenceInvalidRequest)
        XCTAssertNil(result.request)
        XCTAssertEqual(coordinator.requests.map(\.phase), [.toolSelection])
    }

    func testAssistantToolSelectionRejectsDuplicateProviderProposalBeforeReadExecution() async throws {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator { request in
            let handle = request.toolHandles[0]
            return assistantToolSelectionOutcome(request: request, proposals: [
                assistantToolProposal(
                    callID: "call-duplicate-a",
                    handle: handle
                ),
                assistantToolProposal(
                    callID: "call-duplicate-b",
                    handle: handle
                ),
            ])
        }

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertEqual(result.failure, .inferenceInvalidRequest)
        XCTAssertEqual(coordinator.requests.count, 1)
        XCTAssertEqual(coordinator.requests.first?.phase, .toolSelection)
        XCTAssertEqual(result.toolSelectionOutcome?.disposition, .awaitingTools)
        XCTAssertTrue(result.readExecutions.isEmpty)
        XCTAssertNil(result.request)
        XCTAssertNil(result.groundedContext)
        XCTAssertNil(result.inferenceOutcome)
    }

    func testAssistantToolSelectionRejectsMismatchedProviderFunctionBeforeReadExecution() async throws {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator { request in
            let handle = request.toolHandles[0]
            return assistantToolSelectionOutcome(request: request, proposals: [
                assistantToolProposal(
                    callID: "call-mismatch",
                    handle: handle,
                    functionName: "macscope_function_review_v1",
                    operationID: .functionReview
                ),
            ])
        }

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(useProviderVisibleToolSelection: true)
        )

        XCTAssertEqual(result.failure, .inferenceInvalidRequest)
        XCTAssertEqual(coordinator.requests.count, 1)
        XCTAssertEqual(coordinator.requests.first?.phase, .toolSelection)
        XCTAssertTrue(result.readExecutions.isEmpty)
        XCTAssertNil(result.request)
        XCTAssertNil(result.groundedContext)
        XCTAssertNil(result.inferenceOutcome)
    }

    func testAskMacScopeFallsBackToWorkspaceEvidenceWhenApplicationGraphIsUnavailable() async throws {
        let store = makeAssistantStore(includeMachOMetadata: false)
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [.workspaceSummary])
        XCTAssertEqual(result.groundedContext?.records.map(\.descriptor.id), [.workspaceSummary])
        XCTAssertEqual(coordinator.requests.count, 1)
        XCTAssertEqual(coordinator.requests.first?.toolHandles, [])
        XCTAssertTrue(result.isAcceptedFinalAnswer)
    }

    func testAskMacScopeCanExcludeApplicationGraphSupplementalContext() async throws {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(includeApplicationGraphContext: false)
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [.workspaceSummary])
        XCTAssertEqual(result.groundedContext?.records.map(\.descriptor.id), [.workspaceSummary])
        XCTAssertEqual(coordinator.requests.count, 1)
        let request = try XCTUnwrap(coordinator.requests.first)
        XCTAssertEqual(request.groundedContext.records.map(\.descriptor.id), [.workspaceSummary])
        XCTAssertEqual(request.toolHandles, [])
        XCTAssertTrue(result.isAcceptedFinalAnswer)
    }

    func testNonAskAssistantIntentsIgnoreApplicationGraphContextOption() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction,
            userGoal: "Review this function.",
            store: store,
            coordinator: coordinator,
            contextOptions: .init(includeApplicationGraphContext: true)
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [.functionReview, .functionCallSites])
        XCTAssertEqual(Set(result.groundedContext?.records.map(\.descriptor.id) ?? []), [.functionReview, .functionCallSites])
        XCTAssertEqual(coordinator.requests.count, 1)
        XCTAssertEqual(coordinator.requests.first?.toolHandles, [])
    }

    func testContextPreviewShowsIncludedAndExcludedSupplementalOperations() {
        let defaultPreview = Phase2AssistantDisplayMapper.contextPreview(
            intent: .askMacScope
        )
        XCTAssertEqual(defaultPreview.plannedOperations.map(\.id), [
            "workspace.summary",
            "application.graph.summary",
        ])
        XCTAssertEqual(defaultPreview.excludedOperations, [])
        XCTAssertEqual(defaultPreview.actualOperations.map(\.id), [
            "workspace.summary",
            "application.graph.summary",
        ])
        XCTAssertTrue(defaultPreview.authoritySummary.contains("Provider tools: none"))
        XCTAssertTrue(defaultPreview.retentionSummary.contains("Terminal Assistant results are stored"))

        let excludedPreview = Phase2AssistantDisplayMapper.contextPreview(
            intent: .askMacScope,
            options: .init(includeApplicationGraphContext: false)
        )
        XCTAssertEqual(excludedPreview.plannedOperations.map(\.id), ["workspace.summary"])
        XCTAssertEqual(excludedPreview.excludedOperations.map(\.id), ["application.graph.summary"])
        XCTAssertEqual(excludedPreview.actualOperations.map(\.id), ["workspace.summary"])

        let selectionPreview = Phase2AssistantDisplayMapper.contextPreview(
            intent: .explainSelection,
            options: .init(includeApplicationGraphContext: false)
        )
        XCTAssertEqual(selectionPreview.plannedOperations.map(\.id), ["selection.explain"])
        XCTAssertEqual(selectionPreview.excludedOperations, [])
    }

    func testAssistantSheetPolicyEnablesProviderVisibleToolSelectionForUserRuns() {
        let options = Phase2AssistantRunPolicy.defaultContextOptions(
            includeApplicationGraphContext: false
        )

        XCTAssertFalse(options.includeApplicationGraphContext)
        XCTAssertTrue(options.useProviderVisibleToolSelection)

        let preview = Phase2AssistantDisplayMapper.contextPreview(
            intent: .askMacScope,
            options: options
        )
        XCTAssertTrue(preview.authoritySummary.contains("read-only R1 MacScope handles"))
        XCTAssertEqual(preview.plannedOperations.map(\.id), ["workspace.summary"])
        XCTAssertEqual(preview.excludedOperations.map(\.id), ["application.graph.summary"])
    }

    func testAssistantHistoryEntryExportsCompletedRunTranscript() async throws {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner(
            sessionIDProvider: { assistantID(50) },
            turnIDProvider: { assistantID(51) },
            requestIDProvider: { assistantID(52) }
        ).run(
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            store: store,
            coordinator: coordinator
        )

        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected accepted assistant answer to render as completed.")
        }

        let entry = Phase2AssistantHistoryEntry(
            id: assistantID(70),
            sequence: 3,
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            state: .completed(display),
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(entry.title, "Run 3 · Ask MacScope")
        XCTAssertEqual(entry.status, "Completed")
        XCTAssertTrue(entry.summary.contains("grounded answer"))
        XCTAssertTrue(entry.plainTextExport.contains("MacScope Assistant Session Entry"))
        XCTAssertTrue(entry.plainTextExport.contains("Run: 3"))
        XCTAssertTrue(entry.plainTextExport.contains("Action: Ask MacScope"))
        XCTAssertTrue(entry.plainTextExport.contains("Status: Completed"))
        XCTAssertTrue(entry.plainTextExport.contains("Prompt: Summarize the current workspace."))
        XCTAssertTrue(entry.plainTextExport.contains("MacScope Assistant Result"))
        XCTAssertTrue(entry.plainTextExport.contains("application.graph.summary"))
        XCTAssertTrue(entry.plainTextExport.contains("Activity"))
        XCTAssertTrue(entry.plainTextExport.contains("Provider-visible read selection: no"))
        XCTAssertTrue(entry.plainTextExport.contains("Provider tools: none"))
    }

    func testAssistantHistoryEntryDraftReusesIntentAndTrimmedPrompt() {
        let entry = Phase2AssistantHistoryEntry(
            id: assistantID(120),
            sequence: 1,
            intent: .reviewFunction,
            userGoal: "  Review the allocator edge cases.  ",
            state: .failed(title: "Not run", detail: "No provider."),
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            entry.draft,
            Phase2AssistantHistoryDraft(
                intent: .reviewFunction,
                userGoal: "Review the allocator edge cases."
            )
        )
    }

    func testAssistantHistoryEntryDraftUsesIntentDefaultWhenPromptWasEmpty() {
        let entry = Phase2AssistantHistoryEntry(
            id: assistantID(121),
            sequence: 2,
            intent: .explainSelection,
            userGoal: " \n\t ",
            state: .readinessBlocked(.unavailable),
            createdAt: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(
            entry.draft,
            Phase2AssistantHistoryDraft(
                intent: .explainSelection,
                userGoal: Phase2AssistantIntent.explainSelection.defaultGoal(userGoal: "")
            )
        )
    }

    func testAssistantHistoryRecordsTerminalStatesNewestFirstAndBoundsEntries() {
        var history = Phase2AssistantHistoryState(limit: 3)

        history.record(.idle, intent: .askMacScope, userGoal: "", id: assistantID(70))
        history.record(.running(.askMacScope), intent: .askMacScope, userGoal: "", id: assistantID(71))
        XCTAssertEqual(history.entries, [])
        XCTAssertEqual(history.nextSequence, 1)

        history.record(
            .failed(title: "First failure", detail: "No evidence."),
            intent: .askMacScope,
            userGoal: "first",
            id: assistantID(72),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        history.record(
            .readinessBlocked(.unavailable),
            intent: .explainSelection,
            userGoal: "second",
            id: assistantID(73),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        history.record(
            .failed(title: "Third failure", detail: "Still no evidence."),
            intent: .reviewFunction,
            userGoal: "third",
            id: assistantID(74),
            createdAt: Date(timeIntervalSince1970: 3)
        )
        history.record(
            .failed(title: "Fourth failure", detail: "Bounded."),
            intent: .askMacScope,
            userGoal: "fourth",
            id: assistantID(75),
            createdAt: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(history.nextSequence, 5)
        XCTAssertEqual(history.entries.map(\.sequence), [4, 3, 2])
        XCTAssertEqual(history.entries.map(\.status), [
            "Failed",
            "Failed",
            "Provider not ready",
        ])
        XCTAssertFalse(history.entries.contains { $0.summary.contains("First failure") })
        XCTAssertTrue(history.entries.first?.plainTextExport.contains("Fourth failure") == true)
    }

    func testAssistantHistoryHydratesPersistedRecordsNewestFirstAndPreservesTranscriptExport() {
        let workspaceID = assistantID(81)
        let documentID = assistantID(82)
        let records = [
            assistantPersistenceRecord(
                id: assistantID(83),
                workspaceUUID: workspaceID,
                documentID: documentID,
                sequence: 1,
                intent: .askMacScope,
                status: .completed,
                answerText: "older answer",
                transcriptText: "persisted transcript 1",
                createdAt: Date(timeIntervalSince1970: 1)
            ),
            assistantPersistenceRecord(
                id: assistantID(84),
                workspaceUUID: workspaceID,
                documentID: documentID,
                sequence: 3,
                intent: .reviewFunction,
                status: .failed,
                answerText: nil,
                transcriptText: "persisted failure transcript",
                createdAt: Date(timeIntervalSince1970: 3)
            ),
            assistantPersistenceRecord(
                id: assistantID(85),
                workspaceUUID: workspaceID,
                documentID: documentID,
                sequence: 2,
                intent: .explainSelection,
                status: .readinessBlocked,
                answerText: nil,
                transcriptText: "persisted readiness transcript",
                createdAt: Date(timeIntervalSince1970: 2)
            ),
        ]

        var history = Phase2AssistantHistoryState(
            persistenceRecords: records,
            limit: 2
        )

        XCTAssertEqual(history.entries.map(\.sequence), [3, 2])
        XCTAssertEqual(history.entries.map(\.status), ["Failed", "Provider not ready"])
        XCTAssertEqual(history.nextSequence, 4)
        XCTAssertEqual(history.entries.first?.plainTextExport, "persisted failure transcript")

        history.record(
            .failed(title: "new failure", detail: "new detail"),
            intent: .askMacScope,
            userGoal: "new",
            id: assistantID(86),
            createdAt: Date(timeIntervalSince1970: 4)
        )

        XCTAssertEqual(history.entries.map(\.sequence), [4, 3])
        XCTAssertEqual(history.nextSequence, 5)

        history.clear()
        XCTAssertEqual(history.entries, [])
        XCTAssertEqual(history.nextSequence, 1)
    }

    func testAssistantHistoryRemovesSingleEntryWithoutClearingRemainingRuns() {
        var history = Phase2AssistantHistoryState(limit: 4)
        history.record(
            .failed(title: "first", detail: "detail"),
            intent: .askMacScope,
            userGoal: "first",
            id: assistantID(110),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        history.record(
            .readinessBlocked(.unavailable),
            intent: .explainSelection,
            userGoal: "second",
            id: assistantID(111),
            createdAt: Date(timeIntervalSince1970: 2)
        )
        history.record(
            .failed(title: "third", detail: "detail"),
            intent: .reviewFunction,
            userGoal: "third",
            id: assistantID(112),
            createdAt: Date(timeIntervalSince1970: 3)
        )

        history.removeEntry(id: assistantID(111))

        XCTAssertEqual(history.entries.map(\.id), [assistantID(112), assistantID(110)])
        XCTAssertEqual(history.nextSequence, 4)

        history.removeEntry(id: assistantID(112))
        history.removeEntry(id: assistantID(110))

        XCTAssertEqual(history.entries, [])
        XCTAssertEqual(history.nextSequence, 1)
    }

    func testAssistantHistoryExportsAllVisibleEntriesNewestFirst() throws {
        var history = Phase2AssistantHistoryState(limit: 3)
        XCTAssertNil(history.plainTextExport)
        XCTAssertNil(Phase2AssistantHistoryExportSnapshot(entries: history.entries))

        history.record(
            .failed(title: "older failure", detail: "older detail"),
            intent: .askMacScope,
            userGoal: "older",
            id: assistantID(115),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        history.record(
            .failed(title: "newer failure", detail: "newer detail"),
            intent: .reviewFunction,
            userGoal: "newer",
            id: assistantID(116),
            createdAt: Date(timeIntervalSince1970: 2)
        )

        let export = try XCTUnwrap(history.plainTextExport)
        XCTAssertTrue(export.contains("Run: 2"))
        XCTAssertTrue(export.contains("Run: 1"))
        XCTAssertLessThan(
            try XCTUnwrap(export.range(of: "Run: 2")?.lowerBound),
            try XCTUnwrap(export.range(of: "Run: 1")?.lowerBound)
        )
        XCTAssertEqual(export.components(separatedBy: "\n\n---\n\n").count, 2)
        XCTAssertTrue(export.contains("newer failure"))
        XCTAssertTrue(export.contains("older failure"))

        let snapshot = try XCTUnwrap(Phase2AssistantHistoryExportSnapshot(entries: history.entries))
        XCTAssertEqual(snapshot.text, export)
        XCTAssertEqual(snapshot.entryCount, 2)
        XCTAssertFalse(snapshot.isFiltered)
        XCTAssertEqual(snapshot.suggestedFilename, "MacScope-Assistant-History")
    }

    func testAssistantHistoryFiltersEntriesAndExportsOnlyMatches() throws {
        var history = Phase2AssistantHistoryState(limit: 4)
        history.record(
            .failed(title: "Provider offline", detail: "Inventory is missing."),
            intent: .askMacScope,
            userGoal: "Summarize workspace",
            id: assistantID(210),
            createdAt: Date(timeIntervalSince1970: 7_100)
        )
        history.record(
            .completed(Phase2AssistantDisplayResult(
                answer: "Selected instruction subtracts the stack pointer.",
                citations: [],
                evidenceSummaries: [],
                activity: nil,
                contextDisclosure: nil
            )),
            intent: .explainSelection,
            userGoal: "Explain stack setup",
            id: assistantID(211),
            createdAt: Date(timeIntervalSince1970: 7_101)
        )
        history.record(
            .cancelled(title: "Assistant run cancelled", detail: "The user cancelled review."),
            intent: .reviewFunction,
            userGoal: "Review startup",
            id: assistantID(212),
            createdAt: Date(timeIntervalSince1970: 7_102)
        )

        XCTAssertEqual(history.filteredEntries(matching: "").map(\.id), [
            assistantID(212),
            assistantID(211),
            assistantID(210),
        ])
        XCTAssertEqual(history.filteredEntries(matching: "EXPLAIN stack").map(\.id), [assistantID(211)])
        XCTAssertEqual(history.filteredEntries(matching: "cancelled review").map(\.id), [assistantID(212)])
        XCTAssertEqual(history.filteredEntries(matching: "provider summarize").map(\.id), [assistantID(210)])
        XCTAssertEqual(history.filteredEntries(matching: "no-match"), [])

        let export = try XCTUnwrap(history.plainTextExport(matching: "stack"))
        XCTAssertTrue(export.contains("Run: 2"))
        XCTAssertTrue(export.contains("Selected instruction subtracts the stack pointer."))
        XCTAssertFalse(export.contains("Run: 1"))
        XCTAssertFalse(export.contains("Run: 3"))
        XCTAssertNil(history.plainTextExport(matching: "no-match"))

        let snapshot = try XCTUnwrap(
            Phase2AssistantHistoryExportSnapshot(
                entries: history.entries,
                filterText: " stack "
            )
        )
        XCTAssertEqual(snapshot.text, export)
        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertTrue(snapshot.isFiltered)
        XCTAssertEqual(snapshot.suggestedFilename, "MacScope-Assistant-History-Filtered")
        XCTAssertNil(Phase2AssistantHistoryExportSnapshot(entries: history.entries, filterText: "no-match"))
    }

    func testAssistantHistoryRecordsShellProposalReviewAuditWithoutReusableDraft() throws {
        var history = Phase2AssistantHistoryState(limit: 4)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(220),
            executablePath: "/usr/bin/file",
            arguments: ["/tmp/MacScope Fixture"],
            environment: ["LC_ALL": "C"],
            workingDirectoryPath: "/tmp",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 4_096,
            requestedEffects: [.a5]
        )
        let review = Phase2AIShellProposalReviewState
            .review(proposal: proposal)
            .approvingForFutureOneShot()

        history.recordShellProposalReview(
            review,
            event: .approvedForFutureOneShot,
            id: assistantID(221),
            createdAt: Date(timeIntervalSince1970: 7_200)
        )

        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.id, assistantID(221))
        XCTAssertEqual(entry.title, "Review 1 · Shell proposal")
        XCTAssertEqual(entry.status, "Review approved")
        XCTAssertEqual(
            entry.summary,
            "Approved shell proposal review: \"/usr/bin/file\" \"/tmp/MacScope Fixture\""
        )
        XCTAssertFalse(entry.canReuseDraft)
        XCTAssertNil(entry.citationPlainTextExport)
        XCTAssertNil(entry.evidencePlainTextExport)
        XCTAssertNil(entry.contextPlainTextExport)

        let export = entry.plainTextExport
        XCTAssertTrue(export.contains("MacScope AI Shell Proposal Review Audit"), export)
        XCTAssertTrue(export.contains("Review: 1"), export)
        XCTAssertTrue(export.contains("Event: Approved for future restricted one-shot"), export)
        XCTAssertTrue(export.contains("Proposal ID: \(assistantID(220).uuidString)"), export)
        XCTAssertTrue(export.contains("Disposition: staged"), export)
        XCTAssertTrue(export.contains("Human decision: approved for future restricted one-shot"), export)
        XCTAssertTrue(export.contains("Command: \"/usr/bin/file\" \"/tmp/MacScope Fixture\""), export)
        XCTAssertTrue(export.contains("Working directory: \"/tmp\""), export)
        XCTAssertTrue(export.contains("Can execute: yes"), export)
        XCTAssertTrue(export.contains("Validation issues: none"), export)
        XCTAssertEqual(history.filteredEntries(matching: "approved shell").map(\.id), [assistantID(221)])
        XCTAssertEqual(history.filteredEntries(matching: "MacScope Fixture").map(\.id), [assistantID(221)])
    }

    @MainActor
    func testShellProposalReviewAuditDoesNotPersistOrDirtyWorkspace() {
        let store = makeEmptyAssistantStore()
        var history = Phase2AssistantHistoryState(limit: 4)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(222),
            executablePath: "/bin/echo",
            arguments: ["inspect"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(proposal)

        let review = store.rejectPhase2AIShellProposalReviewByUser(proposalID: assistantID(222))
        history.recordShellProposalReview(
            review,
            event: .rejectedByUser,
            id: assistantID(223),
            createdAt: Date(timeIntervalSince1970: 7_201)
        )

        XCTAssertEqual(history.entries.first?.status, "Review rejected")
        XCTAssertTrue(history.entries.first?.plainTextExport.contains("Event: Rejected by user") == true)
        XCTAssertEqual(store.phase2AssistantSessionHistory, [])
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(review.canExecute)
    }

    func testAssistantHistoryRecordsShellBrokerPTYProposalApprovalAudit() throws {
        var history = Phase2AssistantHistoryState(limit: 4)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(224),
            executablePath: "/bin/echo",
            arguments: ["pty-ready"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )
        let review = Phase2AIShellProposalReviewState
            .review(proposal: proposal)
            .approvingForFutureShellBrokerPTY()

        history.recordShellProposalReview(
            review,
            event: .approvedForFutureShellBrokerPTY,
            id: assistantID(225),
            createdAt: Date(timeIntervalSince1970: 7_202)
        )

        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.status, "Review approved")
        XCTAssertEqual(entry.summary, "Approved ShellBroker PTY proposal review: \"/bin/echo\" \"pty-ready\"")
        XCTAssertFalse(entry.canReuseDraft)
        XCTAssertTrue(entry.plainTextExport.contains("Event: Approved for future ShellBroker PTY transport"))
        XCTAssertTrue(entry.plainTextExport.contains(
            "Human decision: approved for future ShellBroker PTY transport"
        ))
        XCTAssertTrue(entry.plainTextExport.contains(
            "Authority: exact .a5 app-mediated ShellBroker PTY transport request only"
        ))
        XCTAssertTrue(entry.plainTextExport.contains("Can execute: no"))
    }

    func testAssistantTerminalStatePersistsThroughWorkspacePackage() async throws {
        let store = makeEmptyAssistantStore()
        let display = Phase2AssistantDisplayResult(
            answer: "grounded answer",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: Phase2AssistantDisplayMapper.contextPreview(
                intent: .askMacScope,
                options: .default
            ),
            providerToolCount: 2
        )

        let record = try XCTUnwrap(store.recordPhase2AssistantTerminalState(
            .completed(display),
            intent: .askMacScope,
            userGoal: "Summarize the current workspace.",
            id: assistantID(80),
            createdAt: Date(timeIntervalSince1970: 5_000)
        ))
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(record.sequence, 1)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.answerText, "grounded answer")
        XCTAssertEqual(record.providerToolCount, 2)

        let (parent, packageURL) = try temporaryAssistantPackageURL("Assistant-Persisted.mscope")
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertTrue(
            store.writeDocumentPackage(to: packageURL, now: Date(timeIntervalSince1970: 5_001)),
            store.saveError ?? "Workspace package write failed without saveError"
        )
        XCTAssertFalse(store.isDirty)

        let package = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(package.manifest.assistantSessionRecords.map(\.id), [assistantID(80)])
        XCTAssertEqual(package.manifest.assistantSessionRecords.first?.sequence, 1)
        XCTAssertEqual(package.manifest.assistantSessionRecords.first?.status, "completed")
        XCTAssertEqual(package.manifest.assistantSessionRecords.first?.answerText, "grounded answer")
        XCTAssertEqual(package.manifest.assistantSessionRecords.first?.providerToolCount, 2)

        let reopened = try WorkspaceStore.restoredPackage(from: packageURL)
        XCTAssertEqual(reopened.phase2AssistantSessionHistory.map(\.id), [assistantID(80)])
        let reopenedRecord = try XCTUnwrap(reopened.phase2AssistantSessionHistory.first)
        XCTAssertEqual(reopenedRecord.workspaceUUID, reopened.workspaceID)
        XCTAssertEqual(reopenedRecord.documentID, reopened.documentID)
        XCTAssertEqual(reopenedRecord.providerToolCount, 2)

        let rewriteURL = parent.appendingPathComponent("Assistant-Rewritten.mscope", isDirectory: true)
        XCTAssertTrue(
            reopened.writeDocumentPackage(to: rewriteURL, now: Date(timeIntervalSince1970: 5_002)),
            reopened.saveError ?? "Rewritten workspace package write failed without saveError"
        )
        let rewritten = try MacScopeDocumentPackage.openPackage(from: rewriteURL)
        XCTAssertEqual(rewritten.manifest.assistantSessionRecords.map(\.id), [assistantID(80)])
        XCTAssertEqual(rewritten.manifest.assistantSessionRecords.first?.sequence, 1)
        XCTAssertEqual(rewritten.manifest.assistantSessionRecords.first?.contentSHA256, reopenedRecord.contentSHA256)
    }

    func testAssistantHistoryClearRemovesPersistedPackageRecords() async throws {
        let store = makeEmptyAssistantStore()
        let display = Phase2AssistantDisplayResult(
            answer: "history answer",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil
        )

        XCTAssertNotNil(store.recordPhase2AssistantTerminalState(
            .completed(display),
            intent: .askMacScope,
            userGoal: "history",
            id: assistantID(87),
            createdAt: Date(timeIntervalSince1970: 6_000)
        ))
        XCTAssertEqual(store.phase2AssistantSessionHistory.map(\.id), [assistantID(87)])
        XCTAssertTrue(store.isDirty)

        let (parent, packageURL) = try temporaryAssistantPackageURL("Assistant-Clear.mscope")
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: packageURL, now: Date(timeIntervalSince1970: 6_001)))
        XCTAssertFalse(store.isDirty)

        store.clearPhase2AssistantSessionHistory()
        XCTAssertEqual(store.phase2AssistantSessionHistory, [])
        XCTAssertTrue(store.isDirty)

        let clearedURL = parent.appendingPathComponent("Assistant-Cleared.mscope", isDirectory: true)
        XCTAssertTrue(store.writeDocumentPackage(to: clearedURL, now: Date(timeIntervalSince1970: 6_002)))
        let clearedPackage = try MacScopeDocumentPackage.openPackage(from: clearedURL)
        XCTAssertEqual(clearedPackage.manifest.assistantSessionRecords, [])
        let reopened = try WorkspaceStore.restoredPackage(from: clearedURL)
        XCTAssertEqual(reopened.phase2AssistantSessionHistory, [])
    }

    func testAssistantHistoryDeleteRemovesSinglePersistedPackageRecord() async throws {
        let store = makeEmptyAssistantStore()
        let display = Phase2AssistantDisplayResult(
            answer: "history answer",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil
        )

        XCTAssertNotNil(store.recordPhase2AssistantTerminalState(
            .completed(display),
            intent: .askMacScope,
            userGoal: "first",
            id: assistantID(113),
            createdAt: Date(timeIntervalSince1970: 6_100)
        ))
        XCTAssertNotNil(store.recordPhase2AssistantTerminalState(
            .completed(display),
            intent: .reviewFunction,
            userGoal: "second",
            id: assistantID(114),
            createdAt: Date(timeIntervalSince1970: 6_101)
        ))
        XCTAssertEqual(store.phase2AssistantSessionHistory.map(\.id), [assistantID(114), assistantID(113)])

        let (parent, packageURL) = try temporaryAssistantPackageURL("Assistant-Delete.mscope")
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: packageURL, now: Date(timeIntervalSince1970: 6_102)))
        XCTAssertFalse(store.isDirty)

        store.deletePhase2AssistantSessionHistoryEntry(id: assistantID(113))

        XCTAssertEqual(store.phase2AssistantSessionHistory.map(\.id), [assistantID(114)])
        XCTAssertTrue(store.isDirty)

        let deletedURL = parent.appendingPathComponent("Assistant-Deleted.mscope", isDirectory: true)
        XCTAssertTrue(store.writeDocumentPackage(to: deletedURL, now: Date(timeIntervalSince1970: 6_103)))
        XCTAssertFalse(store.isDirty)
        let deletedPackage = try MacScopeDocumentPackage.openPackage(from: deletedURL)
        XCTAssertEqual(deletedPackage.manifest.assistantSessionRecords.map(\.id), [assistantID(114)])
        let reopened = try WorkspaceStore.restoredPackage(from: deletedURL)
        XCTAssertEqual(reopened.phase2AssistantSessionHistory.map(\.id), [assistantID(114)])
    }

    func testExplainSelectionAbstainsBeforeInferenceWhenSelectionIsMissing() async {
        let store = makeEmptyAssistantStore()
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .explainSelection,
            userGoal: "Explain this.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertEqual(
            result.failure,
            .readUnavailable(operation: .selectionExplain, reason: .noSelection)
        )
        XCTAssertNil(result.readExecution)
        XCTAssertEqual(coordinator.requests.count, 0)
        XCTAssertNil(result.request)
        XCTAssertNil(result.inferenceOutcome)
    }

    func testReviewFunctionUsesSelectedFunctionEvidenceAndDefaultGoal() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction,
            userGoal: "",
            store: store,
            coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecution?.candidate.operationID, .functionReview)
        XCTAssertEqual(Set(result.groundedContext?.records.map(\.descriptor.id) ?? []), [.functionReview, .functionCallSites])
        let request = try XCTUnwrap(result.request)
        // The optional authoring-proposal protocol follows the default goal.
        XCTAssertTrue(
            request.userGoal.hasPrefix("Review the current function using only cited MacScope evidence.\n"),
            request.userGoal
        )
        XCTAssertEqual(request.groundedContext.records.first?.precondition.workspace, request.workspace)
        XCTAssertEqual(coordinator.requests.count, 1)
    }

    func testProposalEnvelopeIsOfferedToTheModelOnlyForSelectedCodeIntents() async throws {
        for intent in [Phase2AssistantIntent.explainSelection, .reviewFunction, .askMacScope] {
            let store = makeAssistantStore()
            XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
            let coordinator = RecordingAssistantCoordinator()
            let result = await Phase2AssistantSessionRunner().run(
                intent: intent,
                userGoal: "",
                store: store,
                coordinator: coordinator
            )
            XCTAssertNil(result.failure, "\(intent)")
            let request = try XCTUnwrap(coordinator.requests.last, "\(intent)")
            XCTAssertEqual(request.phase, .finalization)
            let evidenceIDs = request.groundedContext.records.map(\.evidenceID)
            let prompt = try Phase2ProductionPromptCompiler().compile(.init(
                phase: .finalization,
                userGoal: request.userGoal,
                canonicalContext: Data(#"{"records":[]}"#.utf8),
                evidenceIDs: evidenceIDs
            ))
            let user = try XCTUnwrap(
                JSONSerialization.jsonObject(with: prompt.userJSON) as? [String: Any]
            )
            let goal = try XCTUnwrap(user["goal"] as? String)
            XCTAssertLessThanOrEqual(request.userGoal.utf8.count, Phase2InferenceLimits.assistantMaximum.maximumGoalBytes)
            XCTAssertFalse(goal.contains("<macscope-authoring-proposal-v1>"), "\(intent)")

            // The compiled MTPLX request schema carries `proposal` exactly when a proposal is offered.
            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
                    model: "validated", systemPrompt: prompt.system, userPrompt: prompt.user,
                    maximumTokens: 8_192, phase: .finalization, generationVariant: .assistantR4,
                    inferencePolicy: Phase2LocalInferencePolicy()
                ))
            ) as? [String: Any])
            let format = try XCTUnwrap(body["response_format"] as? [String: Any])
            let schema = try XCTUnwrap((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let required = try XCTUnwrap(schema["required"] as? [String])
            let system = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
            guard intent != .askMacScope else {
                XCTAssertNil(properties["proposal"])
                XCTAssertFalse(required.contains("proposal"))
                XCTAssertTrue(system.contains("with only kind, text, evidence_ids, and reason."), system)
                XCTAssertNil(user["proposal_protocol"])
                XCTAssertFalse(request.userGoal.contains("<macscope-authoring-proposal-v1>"))
                XCTAssertFalse(prompt.system.contains("macscope.authoring-proposal.v1"))
                continue
            }
            let section = try XCTUnwrap(user["proposal_protocol"] as? String, "\(intent)")
            let anchor = try XCTUnwrap(evidenceIDs.first { id in
                section.contains(#"<macscope-authoring-proposal-v1>{"operation":"comment","value":"<concise comment>","evidence_id":"\#(id.uuidString)"}</macscope-authoring-proposal-v1>"#)
            }, "\(intent): \(section)")
            XCTAssertTrue(section.contains("selected instruction at 0x1004"), section)
            XCTAssertTrue(section.contains("Keep evidence_id \"\(anchor.uuidString)\""), section)
            XCTAssertEqual(section.contains(#""rename""#), intent == .reviewFunction, section)
            let expectedOperations = intent == .reviewFunction ? ["comment", "rename", "type"] : ["comment"]
            XCTAssertEqual(Phase2GroundedFinalProposal.operations(inSection: section), expectedOperations)
            XCTAssertTrue(section.contains("\nProposal evidence: \(anchor.uuidString)\n"), section)
            XCTAssertEqual(Phase2GroundedFinalProposal.offer(inSection: section),
                           .init(operations: expectedOperations, anchored: true))
            // The app has a proposal anchor, so the proposal is a required, non-null object.
            XCTAssertTrue(required.contains("proposal"), "\(intent)")
            let proposal = try XCTUnwrap(properties["proposal"] as? [String: Any])
            XCTAssertNil(proposal["anyOf"], "\(intent)")
            XCTAssertEqual(proposal["type"] as? String, "object")
            XCTAssertEqual(proposal["required"] as? [String], ["operation", "value", "evidence_id"])
            let proposalProperties = try XCTUnwrap(proposal["properties"] as? [String: Any])
            XCTAssertEqual((proposalProperties["operation"] as? [String: Any])?["enum"] as? [String], expectedOperations)
            XCTAssertEqual((proposalProperties["evidence_id"] as? [String: Any])?["maxLength"] as? Int, 36)
            XCTAssertEqual((proposalProperties["value"] as? [String: Any])?["maxLength"] as? Int,
                           Phase2GroundedFinalProposal.maximumValueBytes)
            XCTAssertTrue(system.contains("with only kind, text, evidence_ids, reason, and proposal."), system)
            XCTAssertTrue(system.contains("an allowed operation (\(expectedOperations.joined(separator: ", ")))"), system)
            XCTAssertTrue(system.contains("which is never null"), system)
            XCTAssertFalse(system.contains("Set proposal to null"), system)
            XCTAssertTrue(prompt.system.contains("final object's proposal field"), "\(intent)")
            XCTAssertTrue(prompt.system.contains("[macscope.authoring-proposal.v1]"), "\(intent)")
            // The template is the last user-content key the model reads.
            let text = String(decoding: prompt.userJSON, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("{") && text.range(of: #""proposal_protocol":"#)!.lowerBound
                > text.range(of: #""grounded_context":"#)!.lowerBound)
        }

        // Tool selection never moves or announces the section.
        let goal = "Review.\n\n" + Phase2GroundedPromptCatalog.authoringProposalSectionHeader
            + "\nx\n" + Phase2GroundedPromptCatalog.authoringProposalSectionEnd
        let selectionPrompt = try Phase2ProductionPromptCompiler().compile(.init(
            phase: .toolSelection,
            userGoal: goal,
            canonicalContext: Data(#"{"records":[]}"#.utf8),
            evidenceIDs: []
        ))
        XCTAssertFalse(selectionPrompt.system.contains("macscope.authoring-proposal.v1"))
        XCTAssertFalse(selectionPrompt.user.contains("proposal_protocol"))
    }

    func testGroundedContextShowsTheModelHexAddressesForSelectedCodeIntents() async throws {
        for intent in [Phase2AssistantIntent.explainSelection, .reviewFunction] {
            let store = makeAssistantStore()
            XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
            let coordinator = RecordingAssistantCoordinator()
            _ = await Phase2AssistantSessionRunner().run(
                intent: intent, userGoal: "", store: store, coordinator: coordinator
            )
            let request = try XCTUnwrap(coordinator.requests.last, "\(intent)")
            let canonical = String(decoding: request.groundedContext.canonicalBytes, as: UTF8.self)
            XCTAssertTrue(canonical.contains("4100"), "The app's canonical evidence keeps its typed integers")
            let prompt = try Phase2ProductionPromptCompiler().compile(.init(
                phase: .finalization,
                userGoal: request.userGoal,
                canonicalContext: request.groundedContext.canonicalBytes,
                evidenceIDs: request.groundedContext.records.map(\.evidenceID)
            ))
            let user = try XCTUnwrap(
                JSONSerialization.jsonObject(with: prompt.userJSON) as? [String: Any], "\(intent)"
            )
            let context = String(decoding: try JSONSerialization.data(
                withJSONObject: try XCTUnwrap(user["grounded_context"]), options: [.sortedKeys]
            ), as: UTF8.self)
            XCTAssertTrue(context.contains(#""address":"0x1004""#) || context.contains(#""hex":"0x1004""#),
                "\(intent): \(context)")
            XCTAssertTrue(context.contains(#""start":"0x"#) || context.contains(#""hex":"0x1000""#),
                "\(intent): \(context)")
            XCTAssertFalse(context.contains(#""_0":4100"#), "\(intent)")
            XCTAssertFalse(context.contains(#""address":4100"#), "\(intent)")
            XCTAssertTrue(prompt.system.contains("[macscope.hex-addresses.v1]"), "\(intent)")
        }
    }

    func testAnswerQuotingOnlyEvidenceAddressesIsFullyGroundedWithoutRepair() async {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator(
            finalTexts: ["The instruction at 0x1004 sits inside the function at 0x1000."]
        )

        let result = await Phase2AssistantSessionRunner().run(
            intent: .explainSelection, userGoal: "", store: store, coordinator: coordinator
        )

        XCTAssertEqual(coordinator.requests.filter { $0.phase == .finalization }.count, 1)
        XCTAssertTrue(result.isFullyGrounded)
        XCTAssertEqual(result.unverifiedAddresses, [])
        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected a completed answer")
        }
        XCTAssertNil(display.groundingWarning)
        XCTAssertFalse(display.answer.contains(Phase2AssistantAddressCheck.unverifiedMarker))
    }

    func testUnsupportedAnswerAddressGetsOneRepairTurnListingTheEvidenceAddresses() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator(finalTexts: [
            "It branches to 0x101012F8 and returns 4294968392.",
            "It continues at 0x1004.",
        ])

        let result = await Phase2AssistantSessionRunner().run(
            intent: .explainSelection, userGoal: "", store: store, coordinator: coordinator
        )

        let finalizations = coordinator.requests.filter { $0.phase == .finalization }
        XCTAssertEqual(finalizations.count, 2)
        let repair = try XCTUnwrap(finalizations.last)
        XCTAssertNotEqual(repair.requestID, finalizations[0].requestID)
        XCTAssertEqual(repair.groundedContext, finalizations[0].groundedContext)
        XCTAssertTrue(repair.userGoal.hasPrefix("Address check:"), repair.userGoal)
        XCTAssertTrue(repair.userGoal.contains("0x101012F8, 4294968392"), repair.userGoal)
        XCTAssertTrue(repair.userGoal.contains("0x1004"), repair.userGoal)
        XCTAssertTrue(repair.userGoal.contains(finalizations[0].userGoal), repair.userGoal)
        XCTAssertEqual(result.request?.requestID, repair.requestID)
        XCTAssertEqual(result.inferenceOutcome?.finalCandidate?.text, "It continues at 0x1004.")
        XCTAssertTrue(result.isFullyGrounded)
    }

    func testAddressStillUnsupportedAfterRepairIsFlaggedAndStagesNoProposal() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator(
            finalShellProposals: [Phase2AIShellCommandProposal(
                proposalID: assistantID(234),
                executablePath: "/bin/echo",
                arguments: ["from provider"],
                timeoutMilliseconds: 1_000,
                maximumOutputBytes: 1_024,
                executionSurface: .shellBrokerPTY,
                requestedEffects: [.a5]
            )],
            finalTexts: ["It branches to 0x101012F8.", "It branches to 0xFFFFFFFF008083A8 from 0x1004."]
        )

        let result = await Phase2AssistantSessionRunner().run(
            intent: .explainSelection, userGoal: "", store: store, coordinator: coordinator
        )

        XCTAssertEqual(coordinator.requests.filter { $0.phase == .finalization }.count, 2)
        XCTAssertTrue(result.isAcceptedFinalAnswer)
        XCTAssertFalse(result.isFullyGrounded)
        XCTAssertEqual(result.unverifiedAddresses, ["0xFFFFFFFF008083A8"])
        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected the answer to be shown with its flag")
        }
        XCTAssertEqual(
            display.answer,
            "It branches to 0xFFFFFFFF008083A8 (unverified address) from 0x1004."
        )
        XCTAssertFalse(display.isFullyGrounded)
        XCTAssertTrue(try XCTUnwrap(display.groundingWarning).hasPrefix("Not fully grounded: 0xFFFFFFFF008083A8"))
        XCTAssertTrue(display.plainTextExport.contains("Not fully grounded"))

        result.stageAcceptedProviderProposals(in: store)
        store.stagePhase2AssistantAuthoringProposal(from: result)
        XCTAssertNil(store.phase2AIShellProposalReview.proposal)
        XCTAssertEqual(store.phase2AssistantAuthoringProposalReview, .inactive)
    }

    func testTruncatedFinalizationShowsOutputLimitReached() async {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator(result: .finished(
            lease: Phase2ReadyInferenceLease(
                providerRevision: 1,
                configuration: makeAssistantConfiguration(),
                observedModelInventorySHA256: String(repeating: "a", count: 64)
            ),
            outcome: Phase2InferenceOutcome(
                disposition: .limitExceeded,
                previewDeltas: [],
                toolProposals: [],
                finalCandidate: nil,
                providerUsage: nil,
                violation: .providerOutputLimitReached,
                acceptedEventCount: 0,
                cumulativeEventBytes: 0
            )
        ))

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope, userGoal: "Summarize.", store: store, coordinator: coordinator
        )

        guard case .failed(let title, let detail) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected a failed state")
        }
        XCTAssertEqual(title, "Output limit reached")
        XCTAssertTrue(detail.contains("maximum output"), detail)
        XCTAssertFalse(detail.lowercased().contains("providerfailed"), detail)
    }

    func testProviderNotReadyPreservesGroundedContextAndDoesNotClaimAnswer() async {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator(result: .notReady(.inventoryRequired))

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertEqual(result.failure, .inferenceNotReady(.inventoryRequired))
        XCTAssertNotNil(result.request)
        XCTAssertNotNil(result.groundedContext)
        XCTAssertEqual(coordinator.requests.count, 1)
        XCTAssertNil(result.inferenceOutcome)
        XCTAssertFalse(result.isAcceptedFinalAnswer)
    }

    func testDisplayMapperRendersOnlyAcceptedCitedAnswer() async throws {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize.",
            store: store,
            coordinator: coordinator
        )

        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected accepted assistant answer to render as completed.")
        }
        XCTAssertEqual(display.answer, "grounded answer")
        XCTAssertEqual(Set(display.citations.map(\.title)), [
            "workspace.summary",
            "application.graph.summary",
        ])
        XCTAssertEqual(display.citations.count, 2)
        XCTAssertEqual(Set(display.evidenceSummaries.map(\.title)), [
            "workspace.summary",
            "application.graph.summary",
        ])
        let contextDisclosure = try XCTUnwrap(display.contextDisclosure)
        XCTAssertEqual(Set(contextDisclosure.actualOperations.map(\.id)), [
            "workspace.summary",
            "application.graph.summary",
        ])
        XCTAssertEqual(contextDisclosure.excludedOperations, [])
        XCTAssertEqual(contextDisclosure.omittedEvidence, [])
        XCTAssertEqual(contextDisclosure.canonicalByteCount, result.groundedContext?.canonicalBytes.count)
        XCTAssertEqual(contextDisclosure.digest, result.groundedContext?.digest)
        XCTAssertTrue(contextDisclosure.authoritySummary.contains("Provider tools: none"))
        XCTAssertTrue(contextDisclosure.retentionSummary.contains("Terminal Assistant results are stored"))
        XCTAssertTrue(
            display.evidenceSummaries.contains {
                $0.title == "workspace.summary"
                    && $0.summary.contains("Assistant session")
                    && $0.facts.contains { $0.label == "Workspace Name" && $0.value == "Assistant session" }
                    && $0.identityFacts.contains { $0.label == "Evidence ID" }
                    && $0.identityFacts.contains { $0.label == "Producer" && $0.value == "app" }
                    && !$0.citations.isEmpty
            }
        )
        let graphEvidence = try XCTUnwrap(display.evidenceSummaries.first {
            $0.title == "application.graph.summary"
        })
        XCTAssertTrue(graphEvidence.summary.contains("1 declared dependency"))
        XCTAssertTrue(graphEvidence.facts.contains { $0.label == "Declared Dependency Count" && $0.value == "1" })
        XCTAssertTrue(graphEvidence.allFacts.contains { $0.label == "External Dependency Count" && $0.value == "1" })
        XCTAssertGreaterThan(graphEvidence.hiddenFactCount, 0)
        XCTAssertGreaterThan(graphEvidence.allFacts.count, graphEvidence.facts.count)
        XCTAssertTrue(
            graphEvidence.allFacts.contains {
                $0.id == "focusedImage.path" && $0.value == "/ignored/assistant-fixture"
            },
            "Expected focused image path in \(graphEvidence.allFacts)"
        )
        XCTAssertTrue(
            graphEvidence.allFacts.contains {
                $0.id == "dependencyPage.items.0.rawPath" && $0.value == "/usr/lib/libSystem.B.dylib"
            },
            "Expected dependency raw path in \(graphEvidence.allFacts)"
        )
        XCTAssertTrue(graphEvidence.identityFacts.contains { $0.label == "Payload Digest" })
        XCTAssertEqual(graphEvidence.citations.count, 1)
        XCTAssertTrue(graphEvidence.citations.allSatisfy { !$0.isNavigable })
        XCTAssertTrue(display.citations.contains { $0.detail.contains("workspace") })
        XCTAssertTrue(display.plainTextExport.contains("MacScope Assistant Result"))
        XCTAssertTrue(display.plainTextExport.contains("grounded answer"))
        XCTAssertTrue(display.plainTextExport.contains("Evidence"))
        XCTAssertTrue(display.plainTextExport.contains("- workspace.summary: Assistant session, 1 loaded image"))
        XCTAssertTrue(display.plainTextExport.contains("- application.graph.summary: 1 declared dependency, 1 external, 0 unresolved"))
        XCTAssertTrue(display.plainTextExport.contains("  - Focused Image · Path: /ignored/assistant-fixture"))
        XCTAssertTrue(display.plainTextExport.contains("  - Dependency Page · Items · [0] · Raw Path: /usr/lib/libSystem.B.dylib"))
        XCTAssertTrue(display.plainTextExport.contains("Accepted record"))
        XCTAssertTrue(display.plainTextExport.contains("Payload Digest"))
        XCTAssertTrue(display.plainTextExport.contains("Citation targets"))
        XCTAssertTrue(display.plainTextExport.contains("Context"))
        XCTAssertTrue(display.plainTextExport.contains("- Sent:"))
        XCTAssertTrue(display.plainTextExport.contains("workspace.summary"))
        XCTAssertTrue(display.plainTextExport.contains("application.graph.summary"))
        XCTAssertTrue(display.plainTextExport.contains("- Provider tools: none"))
        XCTAssertTrue(display.plainTextExport.contains("- Retention: Terminal Assistant results are stored"))
        XCTAssertTrue(display.plainTextExport.contains("Citations"))
        XCTAssertTrue(display.plainTextExport.contains("- workspace.summary:"))
        XCTAssertTrue(display.plainTextExport.contains("- application.graph.summary:"))
        let citationExport = try XCTUnwrap(display.citationPlainTextExport)
        XCTAssertTrue(citationExport.hasPrefix("MacScope Assistant Citations"))
        XCTAssertTrue(citationExport.contains("- workspace.summary:"))
        XCTAssertTrue(citationExport.contains("- application.graph.summary:"))
        XCTAssertFalse(citationExport.contains("grounded answer"))
        XCTAssertFalse(citationExport.contains("Evidence"))
        let evidenceExport = try XCTUnwrap(display.evidencePlainTextExport)
        XCTAssertTrue(evidenceExport.hasPrefix("MacScope Assistant Evidence"))
        XCTAssertTrue(evidenceExport.contains("- workspace.summary: Assistant session, 1 loaded image"))
        XCTAssertTrue(evidenceExport.contains("- application.graph.summary: 1 declared dependency, 1 external, 0 unresolved"))
        XCTAssertTrue(evidenceExport.contains("  - Focused Image · Path: /ignored/assistant-fixture"))
        XCTAssertTrue(evidenceExport.contains("  - Accepted record:"))
        XCTAssertTrue(evidenceExport.contains("  - Citation targets:"))
        XCTAssertFalse(evidenceExport.contains("grounded answer"))
        XCTAssertFalse(evidenceExport.contains("Activity"))
        XCTAssertFalse(evidenceExport.contains("Context"))
        let contextExport = try XCTUnwrap(display.contextPlainTextExport)
        XCTAssertTrue(contextExport.hasPrefix("MacScope Assistant Context"))
        XCTAssertTrue(contextExport.contains("- Sent:"))
        XCTAssertTrue(contextExport.contains("workspace.summary"))
        XCTAssertTrue(contextExport.contains("application.graph.summary"))
        XCTAssertTrue(contextExport.contains("- Excluded: none"))
        XCTAssertTrue(contextExport.contains("- Omitted: none"))
        XCTAssertTrue(contextExport.contains("- Canonical bytes:"))
        XCTAssertTrue(contextExport.contains("- Digest:"))
        XCTAssertTrue(contextExport.contains("- Provider tools: none"))
        XCTAssertTrue(contextExport.contains("- Retention: Terminal Assistant results are stored"))
        XCTAssertFalse(contextExport.contains("grounded answer"))
        XCTAssertFalse(contextExport.contains("Evidence"))
        XCTAssertFalse(contextExport.contains("Activity"))

        let historyEntry = Phase2AssistantHistoryEntry(
            id: assistantID(240),
            sequence: 1,
            intent: .askMacScope,
            userGoal: "Summarize.",
            state: .completed(display),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(historyEntry.citationPlainTextExport, citationExport)
        XCTAssertEqual(historyEntry.evidencePlainTextExport, evidenceExport)
        XCTAssertEqual(historyEntry.contextPlainTextExport, contextExport)
    }

    func testAssistantFocusedExportsAreUnavailableWithoutAcceptedStructuredData() {
        let display = Phase2AssistantDisplayResult(
            answer: "answer without citations",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil
        )

        XCTAssertNil(display.citationPlainTextExport)
        XCTAssertNil(display.evidencePlainTextExport)
        XCTAssertNil(display.contextPlainTextExport)

        let failedEntry = Phase2AssistantHistoryEntry(
            id: assistantID(241),
            sequence: 1,
            intent: .askMacScope,
            userGoal: "Summarize.",
            state: .failed(title: "Failed", detail: "No cited answer."),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNil(failedEntry.citationPlainTextExport)
        XCTAssertNil(failedEntry.evidencePlainTextExport)
        XCTAssertNil(failedEntry.contextPlainTextExport)
    }

    func testDisplayMapperMarksStaticLocationCitationsNavigable() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .explainSelection,
            userGoal: "Explain this selection.",
            store: store,
            coordinator: coordinator
        )

        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected accepted assistant answer to render as completed.")
        }
        let citation = try XCTUnwrap(display.citations.first)
        XCTAssertTrue(citation.isNavigable)
        guard case .staticLocation(let location) = citation.target else {
            return XCTFail("Expected static-location citation target.")
        }
        XCTAssertEqual(location.domain, .imageVirtualAddress)
        XCTAssertEqual(location.address, 0x1004)
        XCTAssertEqual(location.image, store.phase2ReadCurrentState(for: .primary).image)
    }

    func testDisplayMapperMarksFunctionRangeCitationsNavigable() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction,
            userGoal: "Review this function.",
            store: store,
            coordinator: coordinator
        )

        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected accepted assistant answer to render as completed.")
        }
        let citation = try XCTUnwrap(display.citations.first)
        XCTAssertTrue(citation.isNavigable)
        guard case .functionRange(let range) = citation.target else {
            return XCTFail("Expected function-range citation target.")
        }
        XCTAssertEqual(range.start, 0x1000)
        XCTAssertEqual(range.endExclusive, 0x1010)
        XCTAssertEqual(range.image, store.phase2ReadCurrentState(for: .primary).image)
    }

    func testPhase2CitationNavigationSelectsStaticLocation() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let result = await Phase2AssistantSessionRunner().run(
            intent: .explainSelection,
            userGoal: "Explain this selection.",
            store: store,
            coordinator: RecordingAssistantCoordinator()
        )
        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected accepted assistant answer to render as completed.")
        }
        let citation = try XCTUnwrap(display.citations.first)

        XCTAssertTrue(store.goToAddress(0x1000, in: .primary))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: .primary, address: 0x1000))

        XCTAssertTrue(store.navigateToPhase2Citation(citation.target))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: .primary, address: 0x1004))
        XCTAssertEqual(store.editorMode, .disassembly)
    }

    func testPhase2CitationNavigationSelectsFunctionRangeStart() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction,
            userGoal: "Review this function.",
            store: store,
            coordinator: RecordingAssistantCoordinator()
        )
        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected accepted assistant answer to render as completed.")
        }
        let citation = try XCTUnwrap(display.citations.first)

        XCTAssertTrue(store.navigateToPhase2Citation(citation.target))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: .primary, address: 0x1000))
        XCTAssertEqual(store.editorMode, .disassembly)
    }

    func testPhase2CitationNavigationRejectsStaleFunctionRange() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction,
            userGoal: "Review this function.",
            store: store,
            coordinator: RecordingAssistantCoordinator()
        )
        guard case .completed(let display) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected accepted assistant answer to render as completed.")
        }
        let citation = try XCTUnwrap(display.citations.first)

        var changedSnapshot = store.snapshot
        var changedAnalysis = assistantAnalysis(fingerprintDigest: String(repeating: "7", count: 64))
        changedAnalysis.functions = [
            FunctionSummary(
                id: assistantID(12),
                name: "review_me_changed",
                startAddress: 0x1000,
                endAddress: 0x1008,
                confidence: 1
            ),
        ]
        changedSnapshot.replaceAnalysis(changedAnalysis, in: .primary)
        store.snapshot = changedSnapshot

        XCTAssertFalse(store.navigateToPhase2Citation(citation.target))
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: .primary, address: 0x1004))
    }

    func testDisplayMapperRejectsProviderAnswerWithUnknownEvidenceID() async {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator(finalEvidenceIDs: [assistantID(99)])

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize.",
            store: store,
            coordinator: coordinator
        )

        XCTAssertFalse(result.isAcceptedFinalAnswer)
        XCTAssertEqual(
            Phase2AssistantDisplayMapper.state(for: result),
            .failed(
                title: "No accepted final answer",
                detail: "The provider did not return a completed answer backed by the accepted evidence set. Finalization disposition: completed. Violation: none. Candidate kind: answer."
            )
        )
        let failedState = Phase2AssistantDisplayMapper.state(for: result)
        XCTAssertEqual(failedState.stopActivity?.summary, "Stopped: No accepted final answer")
        XCTAssertEqual(
            failedState.stopActivity?.facts.first { $0.id == "sideEffects" }?.value,
            "none from stop presentation"
        )
    }

    func testRejectedFinalizationTypedDetailsPersistWithoutProviderText() throws {
        let dispositions: [Phase2InferenceDisposition] = [
            .completed, .awaitingTools, .cancelled, .protocolViolation, .limitExceeded, .providerFailed, .interrupted,
        ]
        for disposition in dispositions {
            let outcome = Phase2InferenceOutcome(disposition: disposition, previewDeltas: ["PRIVATE PREVIEW"],
                toolProposals: [], finalCandidate: .init(kind: .insufficientEvidence,
                    text: "PRIVATE CANDIDATE", evidenceIDs: []), providerUsage: nil,
                violation: .unknownEvidenceID(assistantID(99)), acceptedEventCount: 1, cumulativeEventBytes: 256)
            let result = Phase2AssistantSessionResult(intent: .askMacScope, request: nil, groundedContext: nil,
                readExecution: nil, readExecutions: [], inferenceOutcome: outcome, failure: nil)
            let state = Phase2AssistantDisplayMapper.state(for: result)
            let store = makeEmptyAssistantStore()
            let record = try XCTUnwrap(store.recordPhase2AssistantTerminalState(state,
                intent: .askMacScope, userGoal: "Read accepted REA evidence."))
            XCTAssertEqual(record.status, .failed)
            XCTAssertTrue(record.transcriptText.contains("Finalization disposition: \(disposition)"))
            XCTAssertTrue(record.transcriptText.contains("unknownEvidenceID"))
            XCTAssertTrue(record.transcriptText.contains(assistantID(99).uuidString))
            XCTAssertTrue(record.transcriptText.contains("Candidate kind: insufficientEvidence"))
            XCTAssertFalse(record.transcriptText.contains("PRIVATE PREVIEW"))
            XCTAssertFalse(record.transcriptText.contains("PRIVATE CANDIDATE"))
            XCTAssertNil(record.answerText)
        }
    }

    func testRejectedFinalizationDetailBoundsAssociatedViolationAndMissingCandidate() {
        let outcome = Phase2InferenceOutcome(disposition: .protocolViolation, previewDeltas: [], toolProposals: [],
            finalCandidate: nil, providerUsage: nil,
            violation: .toolFunctionMismatch(String(repeating: "🙂", count: 10_000), .reaResultsGet),
            acceptedEventCount: 0, cumulativeEventBytes: 0)
        let result = Phase2AssistantSessionResult(intent: .askMacScope, request: nil, groundedContext: nil,
            readExecution: nil, readExecutions: [], inferenceOutcome: outcome, failure: nil)
        guard case let .failed(_, detail) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Expected a bounded failed finalization detail")
        }
        XCTAssertLessThan(detail.utf8.count, 2_400)
        XCTAssertTrue(detail.contains("Candidate kind: none"))
    }

    func testAssistantReadinessPresentationDisablesUntilReady() throws {
        XCTAssertFalse(Phase2LocalAIProviderReadiness.loadRequired(modelKey: "local/model").isReadyForAssistant)
        XCTAssertEqual(
            Phase2LocalAIProviderReadiness.loadRequired(modelKey: "local/model").assistantTitle,
            "Selected model must be loaded"
        )
        XCTAssertTrue(
            Phase2LocalAIProviderReadiness.loadRequired(modelKey: "local/model")
                .assistantDetail
                .contains("local/model")
        )
        let blockedState = Phase2AssistantSheetState.readinessBlocked(
            .loadRequired(modelKey: "local/model")
        )
        XCTAssertEqual(blockedState.stopActivity?.summary, "Blocked: Selected model must be loaded")
        XCTAssertEqual(
            blockedState.stopActivity?.facts.first { $0.id == "providerDispatch" }?.value,
            "not started"
        )

        let ready = Phase2LocalAIProviderReadiness.ready(makeAssistantConfiguration())
        XCTAssertTrue(ready.isReadyForAssistant)
        XCTAssertEqual(ready.assistantTitle, "Local model ready")
        XCTAssertTrue(ready.assistantDetail.contains("local/model"))
    }

    func testAssistantStoppedStatesAreRetryable() {
        XCTAssertTrue(
            Phase2AssistantSheetState.failed(
                title: "No accepted final answer",
                detail: "The provider did not return accepted evidence."
            )
            .isRetryableTerminalState
        )
        XCTAssertTrue(
            Phase2AssistantSheetState.readinessBlocked(
                .loadRequired(modelKey: "local/model")
            )
            .isRetryableTerminalState
        )
        XCTAssertTrue(
            Phase2AssistantSheetState.cancelled(
                title: "Assistant run cancelled",
                detail: "Cancelled before a final answer was accepted."
            )
            .isRetryableTerminalState
        )

        XCTAssertFalse(Phase2AssistantSheetState.idle.isRetryableTerminalState)
        XCTAssertFalse(
            Phase2AssistantSheetState.running(.askMacScope)
                .isRetryableTerminalState
        )
        XCTAssertFalse(
            Phase2AssistantSheetState.completed(
                Phase2AssistantDisplayResult(
                    answer: "Done.",
                    citations: [],
                    evidenceSummaries: [],
                    activity: nil,
                    contextDisclosure: nil
                )
            )
            .isRetryableTerminalState
        )
    }

    func testAssistantCancelledStateRecordsActivityAndPersistenceStatus() throws {
        let state = Phase2AssistantSheetState.cancelled(
            title: "Assistant run cancelled",
            detail: "The active Assistant run was cancelled before a final answer was accepted."
        )

        XCTAssertTrue(state.isHistoryRecordable)
        XCTAssertEqual(state.stopActivity?.summary, "Cancelled: Assistant run cancelled")
        XCTAssertEqual(
            state.stopActivity?.facts.first { $0.id == "finalAnswer" }?.value,
            "none accepted"
        )

        let entry = Phase2AssistantHistoryEntry(
            id: assistantID(136),
            sequence: 1,
            intent: .askMacScope,
            userGoal: "Summarize.",
            state: state,
            createdAt: Date(timeIntervalSince1970: 13_600)
        )
        XCTAssertEqual(entry.status, "Cancelled")
        XCTAssertTrue(entry.plainTextExport.contains("Cancellation"))
        XCTAssertTrue(entry.plainTextExport.contains("Final answer: none accepted"))

        let store = makeEmptyAssistantStore()
        let record = try XCTUnwrap(store.recordPhase2AssistantTerminalState(
            state,
            intent: .askMacScope,
            userGoal: "Summarize.",
            id: assistantID(137),
            createdAt: Date(timeIntervalSince1970: 13_601)
        ))
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertNil(record.answerText)
        XCTAssertTrue(record.transcriptText.contains("Status: Cancelled"))
    }

    func testAssistantCancelledRecordRoundTripsThroughPackage() throws {
        let store = makeEmptyAssistantStore()
        let state = Phase2AssistantSheetState.cancelled(
            title: "Assistant run cancelled",
            detail: "The active Assistant run was cancelled before a final answer was accepted."
        )
        XCTAssertNotNil(store.recordPhase2AssistantTerminalState(
            state,
            intent: .reviewFunction,
            userGoal: "Review cancellation.",
            id: assistantID(138),
            createdAt: Date(timeIntervalSince1970: 13_602)
        ))

        let (parent, packageURL) = try temporaryAssistantPackageURL("Assistant-Cancelled.mscope")
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertTrue(store.writeDocumentPackage(to: packageURL, now: Date(timeIntervalSince1970: 13_603)))

        let package = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(package.manifest.assistantSessionRecords.first?.status, "cancelled")

        let reopened = try WorkspaceStore.restoredPackage(from: packageURL)
        let reopenedRecord = try XCTUnwrap(reopened.phase2AssistantSessionHistory.first)
        XCTAssertEqual(reopenedRecord.status, .cancelled)

        let history = Phase2AssistantHistoryState(
            persistenceRecords: reopened.phase2AssistantSessionHistory
        )
        XCTAssertEqual(history.entries.first?.status, "Cancelled")
        XCTAssertTrue(history.entries.first?.summary.contains("Assistant run cancelled") == true)
    }

    func testPublicationTokenAcceptsUnchangedWorkspaceSelectionAndAnalysis() {
        let store = makeAssistantStore()
        let token = Phase2AssistantPublicationToken.capture(
            intent: .explainSelection,
            store: store
        )

        XCTAssertTrue(token.isCurrent(in: store))
    }

    func testPublicationTokenRejectsSelectionChangeBeforeResultPublish() {
        let store = makeAssistantStore()
        let token = Phase2AssistantPublicationToken.capture(
            intent: .explainSelection,
            store: store
        )

        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))

        XCTAssertFalse(token.isCurrent(in: store))
        XCTAssertEqual(
            Phase2AssistantDisplayMapper.staleResultState,
            .failed(
                title: "Assistant result stale",
                detail: "The workspace, focused image, selection, or analysis changed before the assistant finished. Run the request again for the current state."
            )
        )
    }

    func testPublicationTokenRejectsAnalysisFingerprintChangeBeforeResultPublish() {
        let store = makeAssistantStore()
        let token = Phase2AssistantPublicationToken.capture(
            intent: .explainSelection,
            store: store
        )

        var changed = store.snapshot
        changed.replaceAnalysis(
            assistantAnalysis(fingerprintDigest: String(repeating: "5", count: 64)),
            in: .primary
        )
        store.snapshot = changed

        XCTAssertFalse(token.isCurrent(in: store))
    }

    func testPublicationTokenRejectsGraphMetadataChangeBeforeAskResultPublish() {
        let store = makeAssistantStore()
        let token = Phase2AssistantPublicationToken.capture(
            intent: .askMacScope,
            store: store
        )

        var changed = store.snapshot
        var changedAnalysis = assistantAnalysis(fingerprintDigest: String(repeating: "6", count: 64))
        changedAnalysis.machOMetadata = assistantMetadata([
            assistantDependency(path: "/usr/lib/libobjc.A.dylib", ordinal: 1),
        ])
        changed.replaceAnalysis(changedAnalysis, in: .primary)
        store.snapshot = changed

        XCTAssertFalse(token.isCurrent(in: store))
    }

    func testStaleAssistantResultDoesNotStageProviderProposalBeforePublicationAcceptance() async throws {
        let store = makeAssistantStore()
        let token = Phase2AssistantPublicationToken.capture(intent: .explainSelection, store: store)
        let proposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(252),
            executablePath: "/bin/echo",
            arguments: ["stale"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )
        let result = await Phase2AssistantSessionRunner().run(
            intent: .explainSelection,
            userGoal: "Explain this.",
            store: store,
            coordinator: RecordingAssistantCoordinator(finalShellProposals: [proposal])
        )

        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        XCTAssertFalse(token.isCurrent(in: store))
        XCTAssertNil(store.phase2AIShellProposalReview.proposal)
        XCTAssertEqual(result.inferenceOutcome?.shellProposals, [proposal])
    }

    func testAcceptedResultCannotStageProviderProposalIntoForeignWorkspace() async {
        let origin = makeAssistantStore()
        let foreign = makeAssistantStore()
        let proposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(253),
            executablePath: "/bin/echo",
            arguments: ["origin"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )
        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize.",
            store: origin,
            coordinator: RecordingAssistantCoordinator(finalShellProposals: [proposal])
        )

        result.stageAcceptedProviderProposals(in: foreign)

        XCTAssertNil(foreign.phase2AIShellProposalReview.proposal)
        XCTAssertEqual(result.inferenceOutcome?.shellProposals, [proposal])
    }

    func testRestrictedContinuationProposalRequiresOriginalProviderSessionIdentity() async {
        let store = makeAssistantStore()
        let proposal = Phase2AIShellCommandProposal(
            proposalID: assistantID(247),
            executablePath: "/usr/bin/true",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .restrictedOneShotJob
        )
        let result = await Phase2AssistantSessionRunner(
            requestIDProvider: { assistantID(248) }
        ).run(
            intent: .askMacScope,
            userGoal: "Run the bounded check.",
            store: store,
            coordinator: RecordingAssistantCoordinator(finalShellProposals: [proposal]),
            conversationID: assistantID(249),
            sessionID: assistantID(250),
            inferenceTurnID: assistantID(251)
        )

        XCTAssertEqual(result.failure, .inferenceInvalidRequest)
        XCTAssertNil(result.inferenceOutcome)
        XCTAssertNil(result.providerRevision)
    }

    func testR4RunnerUsesStableConversationSessionAndFreshTurnWithCompletedHistory() async throws {
        let store = makeAssistantStore()
        let conversationID = assistantID(200)
        let sessionID = assistantID(201)
        let inferenceTurnID = assistantID(202)
        let priorTurnID = assistantID(203)
        let coordinator = RecordingAssistantCoordinator()
        let runner = Phase2AssistantSessionRunner(
            sessionIDProvider: { XCTFail("Explicit session must be retained"); return assistantID(204) },
            turnIDProvider: { inferenceTurnID },
            requestIDProvider: { assistantID(205) },
            conversationIDProvider: { XCTFail("Explicit conversation must be retained"); return assistantID(206) }
        )

        _ = await runner.run(
            intent: .askMacScope,
            userGoal: "What changed?",
            store: store,
            coordinator: coordinator,
            conversationID: conversationID,
            sessionID: sessionID,
            turnSequence: 2,
            priorTurns: [
                Phase2AssistantProviderVisiblePriorTurn(
                    inferenceTurnID: priorTurnID,
                    turnSequence: 1,
                    userMessage: "What is this binary?",
                    assistantMessage: "It is the current arm64 workspace."
                ),
            ]
        )

        let request = try XCTUnwrap(coordinator.requests.last)
        // The live assistant runner is bound to the assistantR4 production
        // protocol; the "R4" in this test's name is the R4 conversations
        // feature wave, which predates that binding and originally shipped
        // on v5.
        XCTAssertEqual(
            request.protocolVersion,
            .init(rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion)
        )
        XCTAssertEqual(request.sessionID, sessionID)
        XCTAssertEqual(request.turnID, inferenceTurnID)
        let history = try XCTUnwrap(request.conversationContext)
        XCTAssertEqual(history.omittedTurnCount, 0)
        XCTAssertEqual(history.turns, [
            Phase2InferenceConversationTurn(
                conversationID: sessionID,
                inferenceTurnID: priorTurnID,
                turnSequence: 1,
                user: "What is this binary?",
                assistant: "It is the current arm64 workspace."
            ),
        ])
        XCTAssertNoThrow(try Phase2AIWorkerAppCodec().encodeRequest(request))
    }

    func testRunnerRejectsCurrentOrFutureTurnInjectedIntoPriorHistoryBeforeDispatch() async {
        let store = makeAssistantStore()
        let coordinator = RecordingAssistantCoordinator()
        let currentTurnID = assistantID(255)

        let result = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "Summarize.",
            store: store,
            coordinator: coordinator,
            conversationID: assistantID(250),
            sessionID: assistantID(251),
            inferenceTurnID: currentTurnID,
            turnSequence: 2,
            priorTurns: [
                .init(
                    inferenceTurnID: currentTurnID,
                    turnSequence: 2,
                    userMessage: "Injected current turn",
                    assistantMessage: "Must not be retained"
                ),
            ]
        )

        XCTAssertEqual(result.failure, .inferenceInvalidRequest)
        XCTAssertTrue(coordinator.requests.isEmpty)
    }

    func testAssistantTerminalPersistenceRecordsV2ConversationLineage() throws {
        let store = makeEmptyAssistantStore()
        let conversationID = assistantID(210)
        let inferenceTurnID = assistantID(211)
        let display = Phase2AssistantDisplayResult(
            answer: "second answer",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil
        )

        let record = try XCTUnwrap(store.recordPhase2AssistantTerminalState(
            .completed(display),
            intent: .askMacScope,
            userGoal: "second question",
            conversationID: conversationID,
            turnSequence: 2,
            inferenceTurnID: inferenceTurnID,
            id: assistantID(212)
        ))

        XCTAssertEqual(record.recordSchemaVersion, 3)
        XCTAssertEqual(record.conversationID, conversationID)
        XCTAssertEqual(record.turnSequence, 2)
        XCTAssertEqual(record.inferenceTurnID, inferenceTurnID)
        XCTAssertFalse(record.isLegacy)
    }

    func testConversationAdmissionAllowsOnlyOneInFlightTurnPerConversation() {
        let store = makeEmptyAssistantStore()
        let conversationID = assistantID(220)
        let otherConversationID = assistantID(221)

        XCTAssertTrue(store.beginPhase2AssistantTurn(conversationID: conversationID))
        XCTAssertFalse(store.beginPhase2AssistantTurn(conversationID: conversationID))
        XCTAssertTrue(store.beginPhase2AssistantTurn(conversationID: otherConversationID))
        store.endPhase2AssistantTurn(conversationID: conversationID)
        XCTAssertTrue(store.beginPhase2AssistantTurn(conversationID: conversationID))
    }

    func testTerminalPersistenceRejectsLatePublicationAgainstChangedWorkspace() {
        let store = makeAssistantStore()
        let token = Phase2AssistantPublicationToken.capture(intent: .explainSelection, store: store)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))

        let record = store.recordPhase2AssistantTerminalState(
            .failed(title: "Late", detail: "Must not publish"),
            intent: .explainSelection,
            userGoal: "Explain this.",
            publicationToken: token
        )

        XCTAssertNil(record)
        XCTAssertTrue(store.phase2AssistantSessionHistory.isEmpty)
    }

    func testStorePreparesResumableTurnContextAndRunnerUsesItsExactIdentity() async throws {
        let store = makeEmptyAssistantStore()
        let conversationID = assistantID(230)
        let firstTurnID = assistantID(231)
        let first = Phase2AssistantDisplayResult(
            answer: "first answer",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil
        )
        XCTAssertNotNil(store.recordPhase2AssistantTerminalState(
            .completed(first),
            intent: .askMacScope,
            userGoal: "first question",
            conversationID: conversationID,
            turnSequence: 1,
            inferenceTurnID: firstTurnID
        ))

        let context = store.preparePhase2AssistantConversationTurn(
            conversationID: conversationID,
            inferenceTurnID: assistantID(232)
        )

        XCTAssertEqual(context.conversationID, conversationID)
        XCTAssertEqual(context.sessionID, conversationID)
        XCTAssertEqual(context.inferenceTurnID, assistantID(232))
        XCTAssertEqual(context.turnSequence, 2)
        XCTAssertEqual(context.priorTurns.map(\.inferenceTurnID), [firstTurnID])

        let coordinator = RecordingAssistantCoordinator()
        _ = await Phase2AssistantSessionRunner().run(
            intent: .askMacScope,
            userGoal: "second question",
            store: store,
            coordinator: coordinator,
            turnContext: context
        )
        let request = try XCTUnwrap(coordinator.requests.last)
        XCTAssertEqual(request.sessionID, conversationID)
        XCTAssertEqual(request.turnID, assistantID(232))
        XCTAssertEqual(request.conversationContext?.turns.map(\.turnSequence), [1])
    }

    func testDurableAssistantHistoryDoesNotApplyPresentationLimit() {
        let store = makeEmptyAssistantStore()
        let display = Phase2AssistantDisplayResult(
            answer: "answer",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil
        )

        for sequence in 1...13 {
            XCTAssertNotNil(store.recordPhase2AssistantTerminalState(
                .completed(display),
                intent: .askMacScope,
                userGoal: "question \(sequence)",
                conversationID: assistantID(240),
                turnSequence: sequence
            ))
        }

        XCTAssertEqual(store.phase2AssistantSessionHistory.count, 13)
        XCTAssertEqual(Set(store.phase2AssistantSessionHistory.map(\.turnSequence)), Set(1...13))
    }

    func testTerminalPersistenceStoresEffectiveDefaultGoalForRestoredConversationHistory() throws {
        let store = makeEmptyAssistantStore()
        let conversationID = assistantID(241)
        let display = Phase2AssistantDisplayResult(
            answer: "grounded answer",
            citations: [],
            evidenceSummaries: [],
            activity: nil,
            contextDisclosure: nil
        )

        let record = try XCTUnwrap(store.recordPhase2AssistantTerminalState(
            .completed(display),
            intent: .askMacScope,
            userGoal: "   ",
            conversationID: conversationID,
            turnSequence: 1
        ))
        let effectiveGoal = Phase2AssistantIntent.askMacScope.defaultGoal(userGoal: "")

        XCTAssertEqual(record.userGoal, effectiveGoal)
        XCTAssertEqual(record.promptText, effectiveGoal)
        XCTAssertTrue(record.transcriptText.contains(effectiveGoal))
        XCTAssertEqual(
            store.phase2AssistantCompletedPriorTurns(conversationID: conversationID).first?.userMessage,
            effectiveGoal
        )
    }
}

@MainActor
private final class RecordingAssistantCoordinator: Phase2AssistantInferenceCoordinating {
    private let result: Phase2ReadyInferenceExecutionResult?
    private let finalEvidenceIDs: [UUID]?
    private let finalShellProposals: [Phase2AIShellCommandProposal]
    private let finalDebuggerActionProposals: [Phase2AIDebuggerActionProposal]
    private let toolSelectionOutcome: ((Phase2InferenceRequest) -> Phase2InferenceOutcome)?
    private let finalizationStarted: (() -> Void)?
    private let toolSelectionProviderRevision: UInt64
    private let finalizationProviderRevision: UInt64
    private let finalizationInventorySHA256: String
    private let finalizationConfiguration: Phase2AIProviderConfiguration?
    private var finalTexts: [String]
    private(set) var requests: [Phase2InferenceRequest] = []

    init(
        result: Phase2ReadyInferenceExecutionResult? = nil,
        finalEvidenceIDs: [UUID]? = nil,
        finalShellProposals: [Phase2AIShellCommandProposal] = [],
        finalDebuggerActionProposals: [Phase2AIDebuggerActionProposal] = [],
        toolSelectionOutcome: ((Phase2InferenceRequest) -> Phase2InferenceOutcome)? = nil,
        finalizationStarted: (() -> Void)? = nil,
        toolSelectionProviderRevision: UInt64 = 1,
        finalizationProviderRevision: UInt64 = 1,
        finalizationInventorySHA256: String = String(repeating: "a", count: 64),
        finalizationConfiguration: Phase2AIProviderConfiguration? = nil,
        finalTexts: [String] = []
    ) {
        self.finalTexts = finalTexts
        self.result = result
        self.finalEvidenceIDs = finalEvidenceIDs
        self.finalShellProposals = finalShellProposals
        self.finalDebuggerActionProposals = finalDebuggerActionProposals
        self.toolSelectionOutcome = toolSelectionOutcome
        self.finalizationStarted = finalizationStarted
        self.toolSelectionProviderRevision = toolSelectionProviderRevision
        self.finalizationProviderRevision = finalizationProviderRevision
        self.finalizationInventorySHA256 = finalizationInventorySHA256
        self.finalizationConfiguration = finalizationConfiguration
    }

    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
        requests.append(request)
        if request.phase == .toolSelection {
            if let toolSelectionOutcome {
                return .finished(
                    lease: Phase2ReadyInferenceLease(
                        providerRevision: toolSelectionProviderRevision,
                        configuration: makeAssistantConfiguration(),
                        observedModelInventorySHA256: String(repeating: "a", count: 64)
                    ),
                    outcome: toolSelectionOutcome(request)
                )
            }
            guard let handle = request.toolHandles.first,
                  let callID = Phase2ProviderToolCallID(rawValue: "call-\(handle.operationID.rawValue)")
            else {
                return .invalidRequest
            }
            return .finished(
                lease: Phase2ReadyInferenceLease(
                    providerRevision: toolSelectionProviderRevision,
                    configuration: makeAssistantConfiguration(),
                    observedModelInventorySHA256: String(repeating: "a", count: 64)
                ),
                outcome: Phase2InferenceOutcome(
                    disposition: .awaitingTools,
                    previewDeltas: [],
                    toolProposals: [
                        Phase2InferenceToolProposal(
                            callID: callID,
                            handleID: handle.handleID,
                            functionName: Phase2ProductionToolRegistry(version: .assistantR2)
                                .entry(forOperationID: handle.operationID.rawValue)!
                                .functionName,
                            operationID: handle.operationID
                        ),
                    ],
                    finalCandidate: nil,
                    providerUsage: nil,
                    violation: nil,
                    acceptedEventCount: 2,
                    cumulativeEventBytes: 256
                )
            )
        }
        finalizationStarted?()
        if let result { return result }
        let evidenceIDs = finalEvidenceIDs ?? Array(request.groundedContext.records.map(\.evidenceID).prefix(1))
        return .finished(
            lease: Phase2ReadyInferenceLease(
                providerRevision: finalizationProviderRevision,
                configuration: finalizationConfiguration ?? makeAssistantConfiguration(),
                observedModelInventorySHA256: finalizationInventorySHA256
            ),
            outcome: Phase2InferenceOutcome(
                disposition: .completed,
                previewDeltas: [],
                toolProposals: [],
                shellProposals: finalShellProposals,
                debuggerActionProposals: finalDebuggerActionProposals,
                finalCandidate: .init(
                    text: finalTexts.isEmpty ? "grounded answer" : finalTexts.removeFirst(),
                    evidenceIDs: evidenceIDs
                ),
                providerUsage: nil,
                violation: nil,
                acceptedEventCount: 2,
                cumulativeEventBytes: 256
            )
        )
    }
}

private actor AssistantRunnerRecordingOneShotExecutor: Phase2AIShellOneShotExecuting {
    func run(_ proposal: Phase2AIShellCommandProposal) async -> Phase2AIShellOneShotExecutionResult {
        let now = Date(timeIntervalSince1970: 8_000)
        return Phase2AIShellOneShotExecutionResult(
            proposalID: proposal.proposalID,
            executablePath: proposal.executablePath,
            arguments: proposal.arguments,
            workingDirectoryPath: proposal.workingDirectoryPath,
            timeoutMilliseconds: proposal.timeoutMilliseconds,
            maximumOutputBytes: proposal.maximumOutputBytes,
            disposition: .completed,
            terminationStatus: 0,
            standardOutput: "approved shell evidence\n",
            standardError: "",
            outputWasTruncated: false,
            startedAt: now,
            completedAt: now,
            failureMessage: nil
        )
    }
}

private func assistantDebuggerAuthority(
    processID: Int32
) throws -> DebuggerSessionTargetAuthority {
    let start = try XCTUnwrap(DebuggerProcessStartIdentity(
        seconds: 1_700_000_000,
        microseconds: 42
    ))
    let identity = try XCTUnwrap(DebuggerLocalProcessIdentity(
        processID: processID,
        startTime: start,
        realUserID: 501,
        effectiveUserID: 501,
        canonicalExecutablePath: "/Applications/AssistantFixture.app/Contents/MacOS/AssistantFixture",
        executableDeviceID: 10,
        executableFileID: UInt64(processID) + 1_000,
        executableByteCount: 4_096,
        executableSHA256: String(repeating: "a", count: 64),
        architecture: .arm64,
        machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        codeIdentity: nil
    ))
    return DebuggerSessionTargetAuthority(origin: .attached(identity))
}

@MainActor
private func installAssistantDebuggerReadEvidence(
    in store: WorkspaceStore,
    sessionID: UUID = assistantID(245),
    stopRevision: UInt64 = 2,
    includeVariables: Bool = false
) throws {
    let session = DebuggerSessionCoordinate(
        epoch: DebuggerSessionEpoch(rawValue: sessionID),
        lifecycleRevision: DebuggerLifecycleRevision(rawValue: 4)
    )
    let stop = DebuggerStopCoordinate(
        session: session,
        stopRevision: DebuggerStopRevision(rawValue: stopRevision)
    )
    let authority = try assistantDebuggerAuthority(processID: 4242)
    let selectedThread = DebuggerThreadSummary(
        index: 1,
        queueName: "main",
        stopReason: .breakpoint(address: 0x1000),
        isSelected: true,
        topFrameAddress: 0x1000,
        topFrameFunctionName: "main"
    )
    let thread = try XCTUnwrap(DebuggerThreadIdentity(summary: selectedThread))
    let frame = DebuggerFrameSummary(index: 0, address: 0x1000, functionName: "main")
    let frameIdentity = try XCTUnwrap(DebuggerFrameIdentity(thread: thread, summary: frame))
    let coordinate = try XCTUnwrap(DebuggerInspectionCoordinate(
        stop: stop,
        targetAuthority: authority,
        thread: thread,
        frame: frameIdentity
    ))
    let variableScopes: [DebuggerVariableScopeSnapshot]
    if includeVariables {
        let token = try XCTUnwrap(DebuggerVariablePathToken(
            coordinate: coordinate,
            components: [DebuggerVariableScopeKind.arguments.rawValue, "argc"]
        ))
        let node = try XCTUnwrap(DebuggerVariableNode(
            id: token,
            name: "argc",
            typeName: "Int",
            value: .value("2"),
            childCount: 0
        ))
        variableScopes = [
            .init(coordinate: coordinate, scope: .arguments, nodes: [node], wasTruncated: false),
            .init(coordinate: coordinate, scope: .locals, nodes: [], wasTruncated: false),
            .init(coordinate: coordinate, scope: .statics, nodes: [], wasTruncated: false),
        ]
    } else {
        variableScopes = []
    }
    let snapshot = DebuggerSessionSnapshot(
        processState: .paused(processID: 4242, reason: .breakpoint(address: 0x1000)),
        breakpoints: [],
        threads: [selectedThread],
        frames: [frame],
        registers: [.init(name: "pc", value: "0x1000")],
        memoryRegions: [
            .init(
                address: 0x2000,
                byteCount: 3,
                previewBytes: [0xaa, 0xbb, 0xcc],
                label: "stack"
            ),
        ],
        variableScopes: variableScopes,
        statusMessage: "Stopped.",
        backendState: .connected(processID: 4242, adapterName: "LLDB"),
        transportSessionCoordinate: session,
        transportStopCoordinate: stop,
        transportEventSequence: .init(rawValue: 7),
        transportTargetDisposition: .stopped(processID: 4242),
        transportTargetAuthority: authority
    )
    store.updatePhase2DebuggerReadOnlySnapshot(snapshot, inspectionCoordinate: coordinate)
}

private func makeAssistantConfiguration() -> Phase2AIProviderConfiguration {
    try! Phase2AIProviderConfiguration(
        profileID: assistantID(60),
        generation: 1,
        endpointOrigin: "http://127.0.0.1:1234",
        model: "local/model",
        maximumTokens: 512,
        requestTimeoutMilliseconds: 1_000,
        resourceTimeoutMilliseconds: 1_000
    )
}

private func assistantToolSelectionOutcome(
    request: Phase2InferenceRequest,
    proposals: [Phase2InferenceToolProposal]
) -> Phase2InferenceOutcome {
    Phase2InferenceOutcome(
        disposition: .awaitingTools,
        previewDeltas: [],
        toolProposals: proposals,
        finalCandidate: nil,
        providerUsage: nil,
        violation: nil,
        acceptedEventCount: max(2, proposals.count + 1),
        cumulativeEventBytes: max(256, proposals.count * 128)
    )
}

private func assistantToolProposal(
    callID: String,
    handle: Phase2InferenceToolHandle,
    functionName: String? = nil,
    operationID: Phase2ReadOperationID? = nil
) -> Phase2InferenceToolProposal {
    let resolvedOperationID = operationID ?? handle.operationID
    return Phase2InferenceToolProposal(
        callID: Phase2ProviderToolCallID(rawValue: callID)!,
        handleID: handle.handleID,
        functionName: functionName ?? Phase2ProductionToolRegistry(version: .assistantR2)
            .entry(forOperationID: resolvedOperationID.rawValue)!
            .functionName,
        operationID: resolvedOperationID
    )
}

private func assistantPersistenceRecord(
    id: UUID,
    workspaceUUID: UUID,
    documentID: UUID,
    sequence: Int,
    intent: Phase2AssistantIntent,
    status: WorkspaceDatabase.Phase2AssistantPersistedSessionStatus,
    answerText: String?,
    transcriptText: String,
    createdAt: Date
) -> WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord {
    WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord(
        id: id,
        workspaceID: -1,
        workspaceUUID: workspaceUUID,
        documentID: documentID,
        sequence: sequence,
        intentID: intent.rawValue,
        userGoal: intent.defaultGoal(userGoal: ""),
        status: status,
        promptText: intent.defaultGoal(userGoal: ""),
        answerText: answerText,
        transcriptText: transcriptText,
        contextDigest: nil,
        canonicalByteCount: nil,
        providerToolCount: 0,
        createdAt: createdAt,
        completedAt: createdAt
    )
}

private func temporaryAssistantPackageURL(_ name: String) throws -> (parent: URL, url: URL) {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("mscope-assistant-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return (parent, parent.appendingPathComponent(name, isDirectory: true))
}

@MainActor
private func makeEmptyAssistantStore() -> WorkspaceStore {
    WorkspaceStore(
        workspaceName: "Empty assistant session",
        snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
        engine: AnalysisEngine(),
        autosaveScheduler: nil
    )
}

@MainActor
private func makeAssistantStore(includeMachOMetadata: Bool = true) -> WorkspaceStore {
    WorkspaceStore(
        workspaceName: "Assistant session",
        snapshot: WorkspaceSnapshot(
            binaries: [assistantBinary(id: assistantID(1))],
            analysisBySlot: [.primary: assistantAnalysis(includeMachOMetadata: includeMachOMetadata)]
        ),
        engine: AnalysisEngine(),
        autosaveScheduler: nil
    )
}

private func assistantBinary(id: UUID) -> BinaryImage {
    BinaryImage(
        id: id,
        name: "assistant-fixture",
        path: "/ignored/assistant-fixture",
        kind: "Mach-O",
        architecture: "arm64",
        selectedSliceIndex: 0,
        slot: .primary
    )
}

private func assistantAnalysis(
    fingerprintDigest: String = String(repeating: "4", count: 64),
    includeMachOMetadata: Bool = true
) -> ImageAnalysis {
    var analysis = ImageAnalysis(
        functions: [
            FunctionSummary(
                id: assistantID(10),
                name: "review_me",
                startAddress: 0x1000,
                endAddress: 0x1010,
                confidence: 1
            ),
        ],
        instructions: [
            InstructionRow(
                address: 0x1000,
                bytes: "ff 83 00 d1",
                mnemonic: "sub",
                operands: "sp, sp, #0x20",
                hasBreakpoint: false,
                comment: nil
            ),
            InstructionRow(
                address: 0x1004,
                bytes: "fd 7b 01 a9",
                mnemonic: "stp",
                operands: "x29, x30, [sp, #0x10]",
                hasBreakpoint: false,
                comment: "selected"
            ),
        ],
        sections: [
            SectionSummary(
                id: assistantID(11),
                name: "__text",
                address: 0x1000,
                size: 0x10,
                fileOffset: 0,
                isExecutable: true
            ),
        ]
    )
    if includeMachOMetadata {
        analysis.machOMetadata = assistantMetadata([
            assistantDependency(path: "/usr/lib/libSystem.B.dylib", ordinal: 1),
        ])
    }
    analysis.analysisInputFingerprint = assistantFingerprint(overallSHA256: fingerprintDigest)
    return analysis
}

private func assistantMetadata(
    _ dependencies: [MachOLoadMetadata.DependentDylib]
) -> MachOLoadMetadata {
    MachOLoadMetadata(
        codeSignature: nil,
        importedSymbols: [],
        dependentDylibs: dependencies
    )
}

private func assistantDependency(
    path: String,
    kind: String = "required",
    ordinal: Int
) -> MachOLoadMetadata.DependentDylib {
    MachOLoadMetadata.DependentDylib(
        path: path,
        kind: kind,
        currentVersion: "1.0.0",
        compatibilityVersion: "1.0.0",
        ordinal: ordinal
    )
}

private func assistantID(_ byte: UInt8) -> UUID {
    UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}

private extension Phase2ReadCandidateData {
    func field(_ name: String) -> Phase2ReadFactValue? {
        guard case let .value(value) = self else { return nil }
        return value.field(name)
    }
}

private extension Phase2ReadFactValue {
    func field(_ name: String) -> Phase2ReadFactValue? {
        guard case let .object(fields) = self else { return nil }
        return fields.first { $0.name == name }?.value
    }
}

private func assistantFingerprint(overallSHA256: String) -> AnalysisInputFingerprint {
    let facet = try! AnalysisFacetFingerprint(
        kind: .selectedSliceBytes,
        itemCount: 1,
        byteCount: 8,
        sha256: String(repeating: "0", count: 64)
    )
    return try! AnalysisInputFingerprint(
        imageSlot: .primary,
        binaryID: assistantID(1),
        binaryName: "assistant-fixture",
        binaryPath: "/ignored/assistant-fixture",
        selectedSliceIndex: 0,
        artifactIdentity: nil,
        imageByteCount: 8,
        imageBytesSHA256: String(repeating: "f", count: 64),
        facets: [facet],
        overallSHA256: overallSHA256
    )
}

// Reuse the existing private coordinator and selected-function fixtures.
extension Phase2AssistantSessionRunnerTests {
    func testReviewFunctionAddsCallSiteEvidenceWithoutAddingProviderTools() async throws {
        let store = makeAssistantStore()
        var snapshot = store.snapshot
        var analysis = try XCTUnwrap(snapshot.analysis(in: .primary))
        analysis.xrefs = [.init(id: UUID(), from: 0x1004, to: 0x2000, kind: XRefKind.call)]
        snapshot.replaceAnalysis(analysis, in: .primary)
        store.snapshot = snapshot
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let coordinator = RecordingAssistantCoordinator()

        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction, userGoal: "", store: store, coordinator: coordinator
        )

        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [.functionReview, .functionCallSites])
        let request = try XCTUnwrap(result.request)
        let record = try XCTUnwrap(request.groundedContext.records.first { $0.descriptor.id == .functionCallSites })
        XCTAssertEqual(record.data.field("uniqueCallPairCount"), .unsignedInteger(1))
        XCTAssertTrue(request.groundedContext.records.contains { $0.descriptor.id == .functionReview })
        XCTAssertEqual(request.toolHandles, [])
        XCTAssertLessThanOrEqual(request.groundedContext.records.count, 3)
        XCTAssertFalse(Phase2AssistantIntent.reviewFunction.providerVisibleToolOperations.contains(.functionCallSites))
        XCTAssertEqual(Phase2AssistantIntent.reviewFunction.requiredOperations, [.functionReview])
        XCTAssertEqual(Phase2AssistantIntent.reviewFunction.supplementalOperations, [.functionCallSites])
        // Context data uses the existing finalization wire shape, not a new tool handle.
        XCTAssertNoThrow(try Phase2AIWorkerWireCodec().decodeRequest(
            Phase2AIWorkerAppCodec().encodeRequest(request)
        ))
    }

    func testReviewFunctionOptionalRawCapacityRefusalKeepsRequiredEvidence() async throws {
        let store = makeAssistantStore()
        var snapshot = store.snapshot
        var analysis = try XCTUnwrap(snapshot.analysis(in: .primary))
        analysis.xrefs = Array(repeating: .init(id: UUID(), from: 0x1004, to: 0x2000, kind: XRefKind.data),
                               count: Phase2FunctionCallSitesProjector.maximumInputReferences + 1)
        snapshot.replaceAnalysis(analysis, in: .primary)
        store.snapshot = snapshot
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction, userGoal: "", store: store, coordinator: RecordingAssistantCoordinator()
        )
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [.functionReview])
        XCTAssertEqual(result.request?.groundedContext.records.map(\.descriptor.id), [.functionReview])
    }

    func testReviewFunctionOptionalEnvelopeRefusalKeepsRequiredEvidence() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        // function.review needs at most five fields per object in this fixture;
        // the call-site summary needs sixteen. Only the optional read refuses.
        let limits = Phase2ReadLimits(encodedRequestBytes: 65_536, encodedResultBytes: 1_048_576,
                                      structuralNesting: 12, objectMembers: 5, arrayItems: 1_024,
                                      stringBytes: 65_536, pageItems: 256)
        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction, userGoal: "", store: store,
            coordinator: RecordingAssistantCoordinator(), readLimits: limits
        )
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.request?.groundedContext.records.map(\.descriptor.id), [.functionReview])
    }

    func testReviewFunctionContextRecordCapSkipsOptionalCallSites() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction, userGoal: "", store: store,
            coordinator: RecordingAssistantCoordinator(),
            contextLimits: .init(maximumRecords: 1, maximumCanonicalBytes: 1_048_576)
        )
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [.functionReview])
        XCTAssertEqual(result.request?.groundedContext.records.map(\.descriptor.id), [.functionReview])
    }

    func testReviewFunctionNarrowerInferenceReferenceBudgetSkipsOptionalCallSites() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        let ceiling = Phase2InferenceLimits.assistantMaximum
        let limits = Phase2InferenceLimits(
            maximumGoalBytes: ceiling.maximumGoalBytes, maximumEventBytes: ceiling.maximumEventBytes,
            maximumCumulativeEventBytes: ceiling.maximumCumulativeEventBytes,
            maximumEvents: ceiling.maximumEvents, maximumToolHandles: ceiling.maximumToolHandles,
            maximumToolProposals: ceiling.maximumToolProposals,
            maximumFinalTextBytes: ceiling.maximumFinalTextBytes, maximumEvidenceReferences: 1
        )
        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction, userGoal: "", store: store,
            coordinator: RecordingAssistantCoordinator(), inferenceLimits: limits
        )
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.readExecutions.map(\.candidate.operationID), [.functionReview])
        XCTAssertEqual(result.request?.groundedContext.records.map(\.descriptor.id), [.functionReview])
    }

    func testReviewFunctionContextByteCapCannotDisplaceRequiredEvidence() async throws {
        let store = makeAssistantStore()
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        guard case .prepared(let baselineRead) = store.preparePhase2Read(
            operation: .functionReview, proposingPrincipal: .app
        ) else { return XCTFail("Expected the existing required read") }
        let baselineEvidence = try XCTUnwrap(store.executePhase2Read(baselineRead).acceptedEvidence)
        let baselineContext = try store.compilePhase2GroundedContext(invocationIDs: [baselineEvidence.invocationID])
        let limit = baselineContext.canonicalBytes.count + 128

        let result = await Phase2AssistantSessionRunner().run(
            intent: .reviewFunction, userGoal: "", store: store,
            coordinator: RecordingAssistantCoordinator(),
            contextLimits: .init(maximumRecords: 3, maximumCanonicalBytes: limit)
        )
        XCTAssertNil(result.failure)
        let context = try XCTUnwrap(result.request?.groundedContext)
        XCTAssertEqual(context.records.map(\.descriptor.id), [.functionReview])
        XCTAssertEqual(context.omissions, [])
        XCTAssertLessThanOrEqual(context.canonicalBytes.count, limit)
    }
}
