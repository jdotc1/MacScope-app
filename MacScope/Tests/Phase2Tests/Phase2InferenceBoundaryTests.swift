import CryptoKit
import XCTest
@testable import MacScope

final class Phase2InferenceBoundaryTests: XCTestCase {
    func testConversationContextRetainsNewestWholePairsDeterministically() {
        let turns = (1...10).map { ordinal in
            Phase2InferenceConversationTurn(
                conversationID: inferenceID(199),
                inferenceTurnID: inferenceID(200 + ordinal),
                turnSequence: UInt64(ordinal),
                user: "user-\(ordinal)",
                assistant: "assistant-\(ordinal)"
            )
        }

        let context = Phase2InferenceConversationContext.retainingNewest(from: turns)

        XCTAssertEqual(context.turns.map(\.turnSequence), Array(3...10).map(UInt64.init))
        XCTAssertEqual(context.omittedTurnCount, 2)
        XCTAssertEqual(context.turns.first?.user, "user-3")
        XCTAssertEqual(context.turns.first?.assistant, "assistant-3")
    }

    func testConversationContextTrimsWholeOldestPairsAtUTF8ByteCeiling() {
        let oversizedOldest = Phase2InferenceConversationTurn(
            conversationID: inferenceID(219),
            inferenceTurnID: inferenceID(220), turnSequence: 1,
            user: String(repeating: "a", count: 65_530), assistant: "old"
        )
        let newest = Phase2InferenceConversationTurn(
            conversationID: inferenceID(219),
            inferenceTurnID: inferenceID(221), turnSequence: 2, user: "new-user", assistant: "new-answer"
        )

        let context = Phase2InferenceConversationContext.retainingNewest(
            from: [oversizedOldest, newest]
        )

        XCTAssertEqual(context.turns, [newest])
        XCTAssertEqual(context.omittedTurnCount, 1)
    }

    func testShellContinuationV6ReusesFinalCandidateLimitsAndCompletesWithoutTools() async {
        let evidenceID = inferenceID(12)
        let request = makeShellContinuationRequest(evidenceID: evidenceID)
        let final = Phase2InferenceFinalCandidate(
            text: "bounded continuation",
            evidenceIDs: [evidenceID]
        )
        let outcome = await Phase2InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .finalCandidate(final)),
                inferenceEvent(
                    request,
                    sequence: 2,
                    body: .usage(phase2ProviderUsage(prompt: 7, completion: 3))
                ),
                inferenceEvent(request, sequence: 3, body: .completed),
            ])
        )

        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.finalCandidate, final)
        XCTAssertTrue(outcome.toolProposals.isEmpty)
        XCTAssertTrue(outcome.shellProposals.isEmpty)
        XCTAssertTrue(outcome.debuggerActionProposals.isEmpty)
    }

    func testShellContinuationV6RejectsOversizedInsufficientFinal() async {
        let request = makeShellContinuationRequest(evidenceID: inferenceID(12))
        let outcome = await Phase2InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(
                    request,
                    sequence: 1,
                    body: .finalCandidate(.init(
                        kind: .insufficientEvidence,
                        text: String(repeating: "x", count: 4_097),
                        evidenceIDs: []
                    ))
                ),
            ])
        )

        XCTAssertEqual(outcome.disposition, .protocolViolation)
        XCTAssertEqual(outcome.violation, .invalidFinalCandidate)
    }

    func testOrderedEventsProduceOneGroundedFinalCandidate() async {
        let evidenceID = inferenceID(12)
        let request = makeInferenceRequest(
            groundedContext: makeCanonicalGroundedContext(
                workspace: inferenceWorkspace(),
                evidenceID: evidenceID
            )
        )
        let final = Phase2InferenceFinalCandidate(
            text: "bounded answer",
            evidenceIDs: [evidenceID]
        )
        let provider = ScriptedInferenceProvider(events: [
            inferenceEvent(request, sequence: 1, body: .contentDelta("preview")),
            inferenceEvent(request, sequence: 2, body: .finalCandidate(final)),
            inferenceEvent(
                request,
                sequence: 3,
                body: .usage(phase2ProviderUsage(prompt: 7, completion: 3))
            ),
            inferenceEvent(request, sequence: 4, body: .completed),
        ])

        let outcome = await v3InferenceRunner().run(request: request, provider: provider)

        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.previewDeltas, ["preview"])
        XCTAssertEqual(outcome.toolProposals, [])
        XCTAssertEqual(outcome.finalCandidate, final)
        XCTAssertEqual(outcome.providerUsage, phase2ProviderUsage(prompt: 7, completion: 3))
        XCTAssertEqual(outcome.acceptedEventCount, 4)
        XCTAssertNil(outcome.violation)
    }

    func testToolSelectionCompletesAwaitingToolsWithOpaqueProviderCallID() async {
        let handle = Phase2InferenceToolHandle(
            handleID: inferenceID(10),
            operationID: .functionReview
        )
        let request = makeInferenceRequest(phase: .toolSelection, handles: [handle])
        let callID = Phase2ProviderToolCallID(rawValue: "provider-call/opaque-42")!
        let proposal = Phase2InferenceToolProposal(
            callID: callID,
            handleID: handle.handleID,
            functionName: "macscope_function_review_v1",
            operationID: handle.operationID
        )

        let outcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .toolProposal(proposal)),
                inferenceEvent(
                    request,
                    sequence: 2,
                    body: .usage(phase2ProviderUsage(prompt: 11, completion: 5))
                ),
                inferenceEvent(request, sequence: 3, body: .awaitingTools),
            ])
        )

        XCTAssertEqual(outcome.disposition, .awaitingTools)
        XCTAssertEqual(outcome.toolProposals, [proposal])
        XCTAssertEqual(outcome.providerUsage, phase2ProviderUsage(prompt: 11, completion: 5))
        XCTAssertNil(outcome.finalCandidate)
        XCTAssertNil(outcome.violation)
        XCTAssertEqual(
            inferenceEvent(request, sequence: 1, body: .toolProposal(proposal)).estimatedBytes,
            176 + callID.rawValue.utf8.count + 16
                + proposal.functionName.utf8.count + handle.operationID.rawValue.utf8.count
        )
    }

    func testREAAppReducerAcceptsExactListAndDistinctPageHandleProposals() async {
        let handles: [Phase2InferenceToolHandle] = [
            .init(handleID: inferenceID(61), operationID: .reaResultsList),
            .init(handleID: inferenceID(62), operationID: .reaResultsGet),
            .init(handleID: inferenceID(63), operationID: .reaResultsGet),
        ]
        let request = makeInferenceRequest(protocolVersion: .v6, phase: .toolSelection,
            handles: handles, limits: .assistantMaximum)
        let functions = ["macscope_rea_results_list_v1", "macscope_rea_results_get_v1", "macscope_rea_results_get_v1"]
        let proposals = handles.enumerated().map { index, handle in
            Phase2InferenceToolProposal(callID: Phase2ProviderToolCallID(rawValue: "rea-\(index)")!,
                handleID: handle.handleID, functionName: functions[index], operationID: handle.operationID)
        }
        var events = proposals.enumerated().map { index, proposal in
            inferenceEvent(request, sequence: UInt64(index + 1), body: .toolProposal(proposal))
        }
        // Current production protocol requires usage after semantic proposals and before completion.
        let usage = phase2ProviderUsage(prompt: 11, completion: 5)
        events.append(inferenceEvent(request, sequence: 4, body: .usage(usage)))
        events.append(inferenceEvent(request, sequence: 5, body: .awaitingTools))
        let outcome = await Phase2InferenceRunner().run(request: request,
            provider: ScriptedInferenceProvider(events: events))
        XCTAssertEqual(outcome.disposition, .awaitingTools)
        XCTAssertEqual(outcome.toolProposals, proposals)
        XCTAssertEqual(outcome.providerUsage, usage)
        XCTAssertNil(outcome.violation)
    }

    func testREAAppReducerRejectsListFunctionForGetHandle() async {
        let handle = Phase2InferenceToolHandle(handleID: inferenceID(64), operationID: .reaResultsGet)
        let request = makeInferenceRequest(protocolVersion: .v6, phase: .toolSelection,
            handles: [handle], limits: .assistantMaximum)
        let proposal = Phase2InferenceToolProposal(callID: Phase2ProviderToolCallID(rawValue: "rea-wrong-function")!,
            handleID: handle.handleID, functionName: "macscope_rea_results_list_v1", operationID: .reaResultsGet)
        let outcome = await Phase2InferenceRunner().run(request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .toolProposal(proposal))
            ]))
        XCTAssertEqual(outcome.disposition, .protocolViolation)
        XCTAssertEqual(outcome.violation, .toolFunctionMismatch("macscope_rea_results_list_v1", .reaResultsGet))
        XCTAssertTrue(outcome.toolProposals.isEmpty)
    }

    func testToolProposalMustPreserveTheExactOfferedHandleOperationPair() async {
        let handle = Phase2InferenceToolHandle(
            handleID: inferenceID(15),
            operationID: .functionReview
        )
        let request = makeInferenceRequest(phase: .toolSelection, handles: [handle])
        let proposal = Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(rawValue: "provider-call")!,
            handleID: handle.handleID,
            functionName: "macscope_selection_explain_v1",
            operationID: .selectionExplain
        )

        let outcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .toolProposal(proposal)),
                inferenceEvent(request, sequence: 2, body: .awaitingTools),
            ])
        )

        XCTAssertEqual(
            outcome.violation,
            .toolOperationMismatch(handle.handleID, .selectionExplain)
        )
        XCTAssertEqual(outcome.disposition, .protocolViolation)
    }

    func testToolProposalRejectsFunctionNameThatDoesNotMatchItsOperation() async {
        let handle = Phase2InferenceToolHandle(
            handleID: inferenceID(18),
            operationID: .functionReview
        )
        let request = makeInferenceRequest(phase: .toolSelection, handles: [handle])
        let proposal = Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(rawValue: "provider-call")!,
            handleID: handle.handleID,
            functionName: "macscope_workspace_summary_v1",
            operationID: .functionReview
        )

        let outcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .toolProposal(proposal)),
            ])
        )

        XCTAssertEqual(
            outcome.violation,
            .toolFunctionMismatch("macscope_workspace_summary_v1", .functionReview)
        )
    }

    func testRequestRejectsDuplicateOperationHandlesEvenWhenHandleIDsDiffer() async {
        let request = makeInferenceRequest(
            phase: .toolSelection,
            handles: [
                .init(handleID: inferenceID(16), operationID: .workspaceSummary),
                .init(handleID: inferenceID(17), operationID: .workspaceSummary),
            ]
        )
        let provider = RecordingInferenceProvider()

        let outcome = await v3InferenceRunner().run(request: request, provider: provider)

        XCTAssertEqual(outcome.violation, .invalidRequest)
        let runCount = await provider.runCount()
        XCTAssertEqual(runCount, 0)
    }

    func testAnswerRequiresEvidenceWhileInsufficientEvidenceRemainsDistinct() async {
        let request = makeInferenceRequest()
        let invalidAnswer = Phase2InferenceFinalCandidate(
            kind: .answer,
            text: "unsupported answer",
            evidenceIDs: []
        )
        let invalidOutcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .finalCandidate(invalidAnswer)),
            ])
        )
        XCTAssertEqual(invalidOutcome.violation, .invalidFinalCandidate)

        let abstention = Phase2InferenceFinalCandidate(
            kind: .insufficientEvidence,
            text: "No accepted evidence supports the claim.",
            evidenceIDs: []
        )
        let abstentionOutcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .finalCandidate(abstention)),
                inferenceEvent(
                    request,
                    sequence: 2,
                    body: .usage(phase2ProviderUsage(prompt: 7, completion: 3))
                ),
                inferenceEvent(request, sequence: 3, body: .completed),
            ])
        )
        XCTAssertEqual(abstentionOutcome.disposition, .completed)
        XCTAssertEqual(abstentionOutcome.finalCandidate, abstention)
    }

    func testFinalKindsEnforceIndependentUTF8ByteCeilings() async {
        let evidenceID = inferenceID(14)
        let request = makeInferenceRequest(
            groundedContext: makeCanonicalGroundedContext(
                workspace: inferenceWorkspace(),
                evidenceID: evidenceID
            )
        )

        for (kind, maximumBytes, evidenceIDs) in [
            (Phase2InferenceFinalKind.answer, 60_000, [evidenceID]),
            (.insufficientEvidence, 4_096, []),
        ] {
            let accepted = Phase2InferenceFinalCandidate(
                kind: kind,
                text: String(repeating: "x", count: maximumBytes),
                evidenceIDs: evidenceIDs
            )
            let acceptedOutcome = await v3InferenceRunner().run(
                request: request,
                provider: ScriptedInferenceProvider(events: [
                    inferenceEvent(request, sequence: 1, body: .finalCandidate(accepted)),
                    inferenceEvent(
                        request,
                        sequence: 2,
                        body: .usage(phase2ProviderUsage(prompt: 7, completion: 3))
                    ),
                    inferenceEvent(request, sequence: 3, body: .completed),
                ])
            )
            XCTAssertEqual(acceptedOutcome.disposition, .completed, "kind: \(kind)")

            let rejected = Phase2InferenceFinalCandidate(
                kind: kind,
                text: String(repeating: "x", count: maximumBytes + 1),
                evidenceIDs: evidenceIDs
            )
            let rejectedOutcome = await v3InferenceRunner().run(
                request: request,
                provider: ScriptedInferenceProvider(events: [
                    inferenceEvent(request, sequence: 1, body: .finalCandidate(rejected)),
                ])
            )
            XCTAssertEqual(
                rejectedOutcome.violation,
                .invalidFinalCandidate,
                "kind: \(kind)"
            )
        }
    }

    func testProviderCallIDIsOpaqueAndBounded() {
        XCTAssertEqual(
            Phase2ProviderToolCallID(rawValue: "not-a-uuid")?.rawValue,
            "not-a-uuid"
        )
        XCTAssertNil(Phase2ProviderToolCallID(rawValue: ""))
        XCTAssertNotNil(Phase2ProviderToolCallID(rawValue: String(repeating: "x", count: 256)))
        XCTAssertNil(Phase2ProviderToolCallID(rawValue: String(repeating: "x", count: 257)))
        XCTAssertNil(Phase2ProviderToolCallID(rawValue: "call\u{0}"))
        XCTAssertNil(Phase2ProviderToolCallID(rawValue: "call\u{7f}"))

        let composed = Phase2ProviderToolCallID(rawValue: "caf\u{00e9}")!
        let decomposed = Phase2ProviderToolCallID(rawValue: "cafe\u{0301}")!
        XCTAssertNotEqual(composed, decomposed, "opaque IDs must compare by exact UTF-8 bytes")
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
    }

    func testFinalizationAcceptsValidatedShellProposalBeforeUsageAndCompletion() async {
        for version in [Phase2InferenceProtocolVersion.v4, .v5, .v6] {
            let evidenceID = inferenceID(141)
            let request = makeInferenceRequest(
                protocolVersion: version,
                groundedContext: makeCanonicalGroundedContext(
                    workspace: inferenceWorkspace(),
                    evidenceID: evidenceID
                )
            )
            let proposal = Phase2AIShellCommandProposal(
                proposalID: inferenceID(142),
                executablePath: "/bin/echo",
                arguments: ["from provider"],
                timeoutMilliseconds: 1_000,
                maximumOutputBytes: 1_024,
                executionSurface: .shellBrokerPTY,
                requestedEffects: [.a5]
            )
            let final = Phase2InferenceFinalCandidate(
                text: "I staged a reviewed shell proposal.",
                evidenceIDs: [evidenceID]
            )

            let outcome = await Phase2InferenceRunner(acceptedProtocolVersion: version).run(
                request: request,
                provider: ScriptedInferenceProvider(events: [
                    inferenceEvent(request, sequence: 1, body: .shellProposal(proposal)),
                    inferenceEvent(request, sequence: 2, body: .finalCandidate(final)),
                    inferenceEvent(
                        request,
                        sequence: 3,
                        body: .usage(phase2ProviderUsage(prompt: 9, completion: 4))
                    ),
                    inferenceEvent(request, sequence: 4, body: .completed),
                ])
            )

            XCTAssertEqual(outcome.disposition, .completed)
            XCTAssertEqual(outcome.shellProposals, [proposal])
            XCTAssertEqual(outcome.finalCandidate, final)
            XCTAssertNil(outcome.violation)
        }
    }

    func testFinalizationAcceptsValidatedDebuggerActionProposalBeforeUsageAndCompletion() async {
        for version in [Phase2InferenceProtocolVersion.v4, .v5, .v6] {
            let evidenceID = inferenceID(146)
            let request = makeInferenceRequest(
                protocolVersion: version,
                groundedContext: makeCanonicalGroundedContext(
                    workspace: inferenceWorkspace(),
                    evidenceID: evidenceID
                )
            )
            let proposal = Phase2AIDebuggerActionProposal(
                proposalID: inferenceID(147),
                action: .stepOver,
                sessionID: inferenceID(148),
                lifecycleRevision: 2,
                stopRevision: 1,
                eventSequence: 3,
                requestedAuthority: .controlledRuntimeActions
            )
            let final = Phase2InferenceFinalCandidate(
                text: "I staged a reviewed debugger proposal.",
                evidenceIDs: [evidenceID]
            )

            let outcome = await Phase2InferenceRunner(acceptedProtocolVersion: version).run(
                request: request,
                provider: ScriptedInferenceProvider(events: [
                    inferenceEvent(request, sequence: 1, body: .debuggerActionProposal(proposal)),
                    inferenceEvent(request, sequence: 2, body: .finalCandidate(final)),
                    inferenceEvent(
                        request,
                        sequence: 3,
                        body: .usage(phase2ProviderUsage(prompt: 9, completion: 4))
                    ),
                    inferenceEvent(request, sequence: 4, body: .completed),
                ])
            )

            XCTAssertEqual(outcome.disposition, .completed)
            XCTAssertEqual(outcome.debuggerActionProposals, [proposal])
            XCTAssertEqual(outcome.finalCandidate, final)
            XCTAssertNil(outcome.violation)
        }
    }

    func testPreActionProtocolRejectsBothActionProposalKinds() async {
        let request = makeInferenceRequest(protocolVersion: .v3)
        let shell = Phase2AIShellCommandProposal(proposalID: inferenceID(142),
            executablePath: "/bin/echo", arguments: ["proposal only"],
            timeoutMilliseconds: 1_000, maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY, requestedEffects: [.a5])
        let debugger = Phase2AIDebuggerActionProposal(proposalID: inferenceID(147),
            action: .stepOver, sessionID: inferenceID(148), lifecycleRevision: 2,
            stopRevision: 1, eventSequence: 3, requestedAuthority: .controlledRuntimeActions)
        for body in [Phase2InferenceEventBody.shellProposal(shell), .debuggerActionProposal(debugger)] {
            let outcome = await v3InferenceRunner().run(request: request,
                provider: ScriptedInferenceProvider(events: [inferenceEvent(request, sequence: 1, body: body)]))
            XCTAssertEqual(outcome.violation, .eventNotAllowedInProtocolVersion(.v3))
            XCTAssertTrue(outcome.shellProposals.isEmpty)
            XCTAssertTrue(outcome.debuggerActionProposals.isEmpty)
        }
    }

    func testToolSelectionRejectsShellProposalAndFinalizationRejectsInvalidShellProposal() async {
        let toolHandle = Phase2InferenceToolHandle(
            handleID: inferenceID(143),
            operationID: .workspaceSummary
        )
        let toolRequest = makeInferenceRequest(phase: .toolSelection, handles: [toolHandle])
        let proposal = Phase2AIShellCommandProposal(
            proposalID: inferenceID(144),
            executablePath: "/bin/echo",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )
        let toolOutcome = await v3InferenceRunner().run(
            request: toolRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(toolRequest, sequence: 1, body: .shellProposal(proposal)),
            ])
        )
        XCTAssertEqual(toolOutcome.violation, .eventNotAllowedInPhase(.toolSelection))

        let finalRequest = makeInferenceRequest(protocolVersion: .v4, phase: .finalization)
        let invalid = Phase2AIShellCommandProposal(
            proposalID: inferenceID(145),
            executablePath: "relative-tool",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )
        let finalOutcome = await v4InferenceRunner().run(
            request: finalRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(finalRequest, sequence: 1, body: .shellProposal(invalid)),
            ])
        )
        XCTAssertEqual(finalOutcome.violation, .invalidShellProposal)
    }

    func testPhasesRejectMixedToolAndFinalContent() async {
        let handle = Phase2InferenceToolHandle(
            handleID: inferenceID(13),
            operationID: .functionReview
        )
        let toolRequest = makeInferenceRequest(phase: .toolSelection, handles: [handle])
        let toolOutcome = await v3InferenceRunner().run(
            request: toolRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(toolRequest, sequence: 1, body: .contentDelta("not allowed")),
            ])
        )
        XCTAssertEqual(toolOutcome.violation, .eventNotAllowedInPhase(.toolSelection))

        let finalRequest = makeInferenceRequest(phase: .finalization)
        let finalOutcome = await v3InferenceRunner().run(
            request: finalRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(
                    finalRequest,
                    sequence: 1,
                    body: .toolProposal(.init(
                        callID: Phase2ProviderToolCallID(rawValue: "call")!,
                        handleID: handle.handleID,
                        functionName: "macscope_function_review_v1",
                        operationID: handle.operationID
                    ))
                ),
            ])
        )
        XCTAssertEqual(finalOutcome.violation, .eventNotAllowedInPhase(.finalization))

        let forbiddenToolBodies: [Phase2InferenceEventBody] = [
            .finalCandidate(.init(text: "not allowed", evidenceIDs: [])),
            .completed,
        ]
        for body in forbiddenToolBodies {
            let outcome = await v3InferenceRunner().run(
                request: toolRequest,
                provider: ScriptedInferenceProvider(events: [
                    inferenceEvent(toolRequest, sequence: 1, body: body),
                ])
            )
            XCTAssertEqual(outcome.violation, .eventNotAllowedInPhase(.toolSelection))
        }

        let awaitingOutcome = await v3InferenceRunner().run(
            request: finalRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(finalRequest, sequence: 1, body: .awaitingTools),
            ])
        )
        XCTAssertEqual(awaitingOutcome.violation, .eventNotAllowedInPhase(.finalization))
    }

    func testEventPhaseMustMatchRequestAndToolCompletionRequiresProposal() async {
        let handle = Phase2InferenceToolHandle(
            handleID: inferenceID(14),
            operationID: .workspaceSummary
        )
        let request = makeInferenceRequest(phase: .toolSelection, handles: [handle])
        let mismatched = Phase2InferenceEvent(
            protocolVersion: request.protocolVersion,
            phase: .finalization,
            sessionID: request.sessionID,
            turnID: request.turnID,
            requestID: request.requestID,
            document: request.document,
            workspace: request.workspace,
            lifecycleRevision: request.lifecycleRevision,
            sequence: 1,
            body: .awaitingTools
        )
        let mismatchOutcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [mismatched])
        )
        XCTAssertEqual(mismatchOutcome.violation, .phaseMismatch)

        let emptyOutcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .awaitingTools),
            ])
        )
        XCTAssertEqual(emptyOutcome.violation, .completionBeforeToolProposal)
    }

    func testPhaseSpecificRequestHandleShapesFailBeforeProviderRun() async {
        let handle = Phase2InferenceToolHandle(
            handleID: inferenceID(15),
            operationID: .workspaceSummary
        )
        let invalidRequests = [
            makeInferenceRequest(phase: .toolSelection),
            makeInferenceRequest(phase: .finalization, handles: [handle]),
        ]

        for request in invalidRequests {
            let provider = RecordingInferenceProvider()
            let outcome = await v3InferenceRunner().run(request: request, provider: provider)
            XCTAssertEqual(outcome.violation, .invalidRequest)
            let runCount = await provider.runCount()
            XCTAssertEqual(runCount, 0)
        }
    }

    func testLegacyV1AndV2RequestsAreRejectedBeforeProviderRun() async {
        for version in [Phase2InferenceProtocolVersion.v1, .v2] {
            let request = makeInferenceRequest(protocolVersion: version)
            let provider = RecordingInferenceProvider()

            let outcome = await v3InferenceRunner().run(request: request, provider: provider)

            XCTAssertEqual(outcome.violation, .invalidRequest)
            let runCount = await provider.runCount()
            XCTAssertEqual(runCount, 0)
        }
    }

    func testProductionRunnerDefaultsToActiveAssistantProtocolAndRejectsAcceptedF4BV2AtRuntime() async {
        let productionRequest = makeInferenceRequest(protocolVersion: .v6)
        let final = Phase2InferenceFinalCandidate(
            kind: .insufficientEvidence,
            text: "No accepted evidence supports the claim.",
            evidenceIDs: []
        )
        let productionOutcome = await Phase2InferenceRunner().run(
            request: productionRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(productionRequest, sequence: 1, body: .finalCandidate(final)),
                inferenceEvent(
                    productionRequest,
                    sequence: 2,
                    body: .usage(phase2ProviderUsage(prompt: 7, completion: 3))
                ),
                inferenceEvent(productionRequest, sequence: 3, body: .completed),
            ])
        )
        XCTAssertEqual(productionOutcome.disposition, .completed)
        XCTAssertEqual(
            productionOutcome.providerUsage,
            phase2ProviderUsage(prompt: 7, completion: 3)
        )

        let acceptedF4BRequest = makeInferenceRequest(protocolVersion: .v2)
        let provider = RecordingInferenceProvider()
        let acceptedF4BOnProduction = await Phase2InferenceRunner().run(
            request: acceptedF4BRequest,
            provider: provider
        )
        XCTAssertEqual(acceptedF4BOnProduction.violation, .invalidRequest)
        let runCount = await provider.runCount()
        XCTAssertEqual(runCount, 0)
    }

    func testDuplicateProviderUsageFailsClosedWithoutOverwritingFirstRecord() async {
        let request = makeInferenceRequest()
        let first = phase2ProviderUsage(prompt: 7, completion: 3)
        let second = phase2ProviderUsage(prompt: 8, completion: 4)
        let final = Phase2InferenceFinalCandidate(
            kind: .insufficientEvidence,
            text: "No accepted evidence supports the claim.",
            evidenceIDs: []
        )
        let outcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 1, body: .finalCandidate(final)),
                inferenceEvent(request, sequence: 2, body: .usage(first)),
                inferenceEvent(request, sequence: 3, body: .usage(second)),
            ])
        )

        XCTAssertEqual(outcome.disposition, .protocolViolation)
        XCTAssertEqual(outcome.violation, .duplicateProviderUsage)
        XCTAssertEqual(outcome.providerUsage, first)
    }

    func testSuccessfulTerminalsRequireExactlyOneProviderUsageInBothPhases() async {
        let finalRequest = makeInferenceRequest()
        let final = Phase2InferenceFinalCandidate(
            kind: .insufficientEvidence,
            text: "No accepted evidence supports the claim.",
            evidenceIDs: []
        )
        let finalOutcome = await v3InferenceRunner().run(
            request: finalRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(finalRequest, sequence: 1, body: .finalCandidate(final)),
                inferenceEvent(finalRequest, sequence: 2, body: .completed),
            ])
        )
        XCTAssertEqual(finalOutcome.disposition, .protocolViolation)
        XCTAssertEqual(finalOutcome.violation, .completionBeforeProviderUsage)

        let handle = Phase2InferenceToolHandle(
            handleID: inferenceID(42),
            operationID: .workspaceSummary
        )
        let toolRequest = makeInferenceRequest(phase: .toolSelection, handles: [handle])
        let proposal = Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(rawValue: "provider-call")!,
            handleID: handle.handleID,
            functionName: "macscope_workspace_summary_v1",
            operationID: handle.operationID
        )
        let toolOutcome = await v3InferenceRunner().run(
            request: toolRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(toolRequest, sequence: 1, body: .toolProposal(proposal)),
                inferenceEvent(toolRequest, sequence: 2, body: .awaitingTools),
            ])
        )
        XCTAssertEqual(toolOutcome.disposition, .protocolViolation)
        XCTAssertEqual(toolOutcome.violation, .completionBeforeProviderUsage)
    }

    func testProviderUsageBeforeSemanticOutputFailsClosedInBothPhases() async {
        for request in [
            makeInferenceRequest(),
            makeInferenceRequest(
                phase: .toolSelection,
                handles: [.init(handleID: inferenceID(43), operationID: .functionReview)]
            ),
        ] {
            let outcome = await v3InferenceRunner().run(
                request: request,
                provider: ScriptedInferenceProvider(events: [
                    inferenceEvent(
                        request,
                        sequence: 1,
                        body: .usage(phase2ProviderUsage(prompt: 7, completion: 3))
                    ),
                ])
            )
            XCTAssertEqual(outcome.disposition, .protocolViolation)
            XCTAssertEqual(outcome.violation, .usageBeforeSemanticOutput)
            XCTAssertNil(outcome.providerUsage)
        }
    }

    func testSemanticOutputAfterProviderUsageFailsClosedInBothPhases() async {
        let finalRequest = makeInferenceRequest()
        let final = Phase2InferenceFinalCandidate(
            kind: .insufficientEvidence,
            text: "No accepted evidence supports the claim.",
            evidenceIDs: []
        )
        let finalOutcome = await v3InferenceRunner().run(
            request: finalRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(finalRequest, sequence: 1, body: .finalCandidate(final)),
                inferenceEvent(
                    finalRequest,
                    sequence: 2,
                    body: .usage(phase2ProviderUsage(prompt: 7, completion: 3))
                ),
                inferenceEvent(finalRequest, sequence: 3, body: .contentDelta("late")),
                inferenceEvent(finalRequest, sequence: 4, body: .completed),
            ])
        )
        XCTAssertEqual(finalOutcome.disposition, .protocolViolation)
        XCTAssertEqual(finalOutcome.violation, .semanticOutputAfterProviderUsage)
        XCTAssertEqual(finalOutcome.previewDeltas, [])
        XCTAssertEqual(finalOutcome.finalCandidate, final)

        let firstHandle = Phase2InferenceToolHandle(
            handleID: inferenceID(44),
            operationID: .workspaceSummary
        )
        let secondHandle = Phase2InferenceToolHandle(
            handleID: inferenceID(45),
            operationID: .functionReview
        )
        let toolRequest = makeInferenceRequest(
            phase: .toolSelection,
            handles: [firstHandle, secondHandle]
        )
        let firstProposal = Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(rawValue: "provider-call-1")!,
            handleID: firstHandle.handleID,
            functionName: "macscope_workspace_summary_v1",
            operationID: firstHandle.operationID
        )
        let secondProposal = Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(rawValue: "provider-call-2")!,
            handleID: secondHandle.handleID,
            functionName: "macscope_function_review_v1",
            operationID: secondHandle.operationID
        )
        let toolOutcome = await v3InferenceRunner().run(
            request: toolRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(toolRequest, sequence: 1, body: .toolProposal(firstProposal)),
                inferenceEvent(
                    toolRequest,
                    sequence: 2,
                    body: .usage(phase2ProviderUsage(prompt: 11, completion: 5))
                ),
                inferenceEvent(toolRequest, sequence: 3, body: .toolProposal(secondProposal)),
                inferenceEvent(toolRequest, sequence: 4, body: .awaitingTools),
            ])
        )
        XCTAssertEqual(toolOutcome.disposition, .protocolViolation)
        XCTAssertEqual(toolOutcome.violation, .semanticOutputAfterProviderUsage)
        XCTAssertEqual(toolOutcome.toolProposals, [firstProposal])
    }

    func testProviderUsageRejectsNegativeInconsistentAndOverflowedCounts() {
        XCTAssertNotNil(Phase2ProviderUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0))
        XCTAssertNil(Phase2ProviderUsage(promptTokens: -1, completionTokens: 1, totalTokens: 0))
        XCTAssertNil(Phase2ProviderUsage(promptTokens: 1, completionTokens: -1, totalTokens: 0))
        XCTAssertNil(Phase2ProviderUsage(promptTokens: 1, completionTokens: 1, totalTokens: -1))
        XCTAssertNil(Phase2ProviderUsage(promptTokens: 7, completionTokens: 3, totalTokens: 11))
        XCTAssertNil(Phase2ProviderUsage(
            promptTokens: Int.max,
            completionTokens: 1,
            totalTokens: Int.max
        ))
    }

    func testExactIdentityAndContiguousSequenceAreRequired() async {
        let request = makeInferenceRequest()
        var wrongIdentity = inferenceEvent(
            request,
            sequence: 1,
            body: .contentDelta("ignored")
        )
        wrongIdentity = Phase2InferenceEvent(
            protocolVersion: wrongIdentity.protocolVersion,
            sessionID: inferenceID(99),
            turnID: wrongIdentity.turnID,
            requestID: wrongIdentity.requestID,
            document: wrongIdentity.document,
            workspace: wrongIdentity.workspace,
            lifecycleRevision: wrongIdentity.lifecycleRevision,
            sequence: wrongIdentity.sequence,
            body: wrongIdentity.body
        )

        let identityOutcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [wrongIdentity])
        )
        XCTAssertEqual(identityOutcome.disposition, .protocolViolation)
        XCTAssertEqual(identityOutcome.violation, .identityMismatch)

        let sequenceOutcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(request, sequence: 2, body: .contentDelta("ignored")),
            ])
        )
        XCTAssertEqual(sequenceOutcome.disposition, .protocolViolation)
        XCTAssertEqual(sequenceOutcome.violation, .sequenceMismatch(expected: 1, actual: 2))
    }

    func testToolProposalsAreLimitedToFreshAppIssuedHandles() async {
        let handle = Phase2InferenceToolHandle(
            handleID: inferenceID(20),
            operationID: .selectionExplain
        )
        let first = Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(rawValue: "call-21")!,
            handleID: handle.handleID,
            functionName: "macscope_selection_explain_v1",
            operationID: handle.operationID
        )
        let repeated = Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(rawValue: "call-22")!,
            handleID: handle.handleID,
            functionName: "macscope_selection_explain_v1",
            operationID: handle.operationID
        )
        let toolRequest = makeInferenceRequest(phase: .toolSelection, handles: [handle])

        let repeatedOutcome = await v3InferenceRunner().run(
            request: toolRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(toolRequest, sequence: 1, body: .toolProposal(first)),
                inferenceEvent(toolRequest, sequence: 2, body: .toolProposal(repeated)),
            ])
        )
        XCTAssertEqual(repeatedOutcome.violation, .repeatedToolHandle(handle.handleID))

        let secondHandle = Phase2InferenceToolHandle(
            handleID: inferenceID(25),
            operationID: .workspaceSummary
        )
        let duplicateCallRequest = makeInferenceRequest(
            phase: .toolSelection,
            handles: [handle, secondHandle]
        )
        let duplicateCallOutcome = await v3InferenceRunner().run(
            request: duplicateCallRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(duplicateCallRequest, sequence: 1, body: .toolProposal(first)),
                inferenceEvent(
                    duplicateCallRequest,
                    sequence: 2,
                    body: .toolProposal(.init(
                        callID: first.callID,
                        handleID: secondHandle.handleID,
                        functionName: "macscope_workspace_summary_v1",
                        operationID: secondHandle.operationID
                    ))
                ),
            ])
        )
        XCTAssertEqual(duplicateCallOutcome.violation, .duplicateCallID)

        let unknownHandle = inferenceID(23)
        let unknownRequest = makeInferenceRequest(phase: .toolSelection, handles: [handle])
        let unknownOutcome = await v3InferenceRunner().run(
            request: unknownRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(
                    unknownRequest,
                    sequence: 1,
                    body: .toolProposal(.init(
                        callID: Phase2ProviderToolCallID(rawValue: "call-24")!,
                        handleID: unknownHandle,
                        functionName: "macscope_selection_explain_v1",
                        operationID: handle.operationID
                    ))
                ),
            ])
        )
        XCTAssertEqual(unknownOutcome.violation, .unknownToolHandle(unknownHandle))
    }

    func testInventedEvidenceAndOversizedEventsFailClosed() async {
        let request = makeInferenceRequest()
        let unknownEvidence = inferenceID(30)
        let evidenceOutcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(
                    request,
                    sequence: 1,
                    body: .finalCandidate(.init(text: "answer", evidenceIDs: [unknownEvidence]))
                ),
            ])
        )
        XCTAssertEqual(evidenceOutcome.disposition, .protocolViolation)
        XCTAssertEqual(evidenceOutcome.violation, .unknownEvidenceID(unknownEvidence))

        let smallLimits = Phase2InferenceLimits(
            maximumGoalBytes: 100,
            maximumEventBytes: 200,
            maximumCumulativeEventBytes: 1_000,
            maximumEvents: 10,
            maximumToolHandles: 1,
            maximumToolProposals: 1,
            maximumFinalTextBytes: 100,
            maximumEvidenceReferences: 1
        )
        let boundedRequest = makeInferenceRequest(limits: smallLimits)
        let limitOutcome = await v3InferenceRunner().run(
            request: boundedRequest,
            provider: ScriptedInferenceProvider(events: [
                inferenceEvent(
                    boundedRequest,
                    sequence: 1,
                    body: .contentDelta(String(repeating: "x", count: 41))
                ),
            ])
        )
        XCTAssertEqual(limitOutcome.disposition, .limitExceeded)
        XCTAssertEqual(limitOutcome.violation, .eventTooLarge)
    }

    func testCumulativeEventByteCeilingAcceptsExactMaximumAndRejectsMaximumPlusOne() async {
        let exactRequest = makeInferenceRequest()
        let maximumEventBytes = exactRequest.limits.maximumEventBytes
        let fixedEventBytes = inferenceEvent(
            exactRequest,
            sequence: 1,
            body: .contentDelta("")
        ).estimatedBytes
        let maximumTextBytes = maximumEventBytes - fixedEventBytes
        let exactEvents = (1...16).map { sequence in
            inferenceEvent(
                exactRequest,
                sequence: UInt64(sequence),
                body: .contentDelta(String(repeating: "x", count: maximumTextBytes))
            )
        }

        let exactOutcome = await v3InferenceRunner().run(
            request: exactRequest,
            provider: ScriptedInferenceProvider(events: exactEvents)
        )
        XCTAssertEqual(exactOutcome.acceptedEventCount, 16)
        XCTAssertEqual(
            exactOutcome.cumulativeEventBytes,
            exactRequest.limits.maximumCumulativeEventBytes
        )
        XCTAssertEqual(exactOutcome.disposition, .interrupted)

        let overflowRequest = makeInferenceRequest()
        var overflowEvents = (1...15).map { sequence in
            inferenceEvent(
                overflowRequest,
                sequence: UInt64(sequence),
                body: .contentDelta(String(repeating: "x", count: maximumTextBytes))
            )
        }
        let penultimateTotalBytes = maximumEventBytes - fixedEventBytes + 1
        overflowEvents.append(inferenceEvent(
            overflowRequest,
            sequence: 16,
            body: .contentDelta(String(repeating: "y", count: penultimateTotalBytes - fixedEventBytes))
        ))
        overflowEvents.append(inferenceEvent(
            overflowRequest,
            sequence: 17,
            body: .contentDelta("")
        ))

        XCTAssertEqual(
            overflowEvents.dropLast().reduce(0) { $0 + $1.estimatedBytes },
            overflowRequest.limits.maximumCumulativeEventBytes - fixedEventBytes + 1
        )
        XCTAssertEqual(
            overflowEvents.reduce(0) { $0 + $1.estimatedBytes },
            overflowRequest.limits.maximumCumulativeEventBytes + 1
        )
        let overflowOutcome = await v3InferenceRunner().run(
            request: overflowRequest,
            provider: ScriptedInferenceProvider(events: overflowEvents)
        )
        XCTAssertEqual(overflowOutcome.disposition, .limitExceeded)
        XCTAssertEqual(overflowOutcome.violation, .cumulativeEventLimitExceeded)
        XCTAssertEqual(overflowOutcome.acceptedEventCount, 16)
        XCTAssertEqual(
            overflowOutcome.cumulativeEventBytes,
            overflowRequest.limits.maximumCumulativeEventBytes - fixedEventBytes + 1
        )
    }

    func testProviderReturnWithoutCompletionIsInterrupted() async {
        let request = makeInferenceRequest()
        let outcome = await v3InferenceRunner().run(
            request: request,
            provider: ScriptedInferenceProvider(events: [])
        )

        XCTAssertEqual(outcome.disposition, .interrupted)
        XCTAssertEqual(outcome.violation, .providerReturnedWithoutCompletion)
    }

    func testInvalidContextNeverReachesProviderAndProviderErrorsRemainProviderFailures() async {
        let canonicalForAnotherWorkspace = makeCanonicalGroundedContext(
            workspace: .init(
                document: .init(instanceID: inferenceID(90)),
                instanceID: inferenceID(91)
            ),
            evidenceID: inferenceID(92)
        )
        let invalidRequest = makeInferenceRequest(
            groundedContext: canonicalForAnotherWorkspace
        )
        let recordingProvider = RecordingInferenceProvider()

        let invalidOutcome = await v3InferenceRunner().run(
            request: invalidRequest,
            provider: recordingProvider
        )
        XCTAssertEqual(invalidOutcome.disposition, .protocolViolation)
        XCTAssertEqual(invalidOutcome.violation, .invalidRequest)
        let runCount = await recordingProvider.runCount()
        XCTAssertEqual(runCount, 0)

        let validRequest = makeInferenceRequest()
        let failedOutcome = await v3InferenceRunner().run(
            request: validRequest,
            provider: BoundaryViolationThrowingProvider()
        )
        XCTAssertEqual(failedOutcome.disposition, .providerFailed)
        XCTAssertNil(failedOutcome.violation)
    }

    func testTruncatedProviderResultReportsTheOutputLimitInsteadOfProviderFailure() async {
        let outcome = await v3InferenceRunner().run(
            request: makeInferenceRequest(),
            provider: OutputLimitThrowingProvider()
        )

        XCTAssertEqual(outcome.disposition, .limitExceeded)
        XCTAssertEqual(outcome.violation, .providerOutputLimitReached)
        XCTAssertNil(outcome.finalCandidate)
    }

    func testCancellationIsRelayedOnceAndLateEventsAreRejected() async throws {
        let request = makeInferenceRequest()
        let provider = ControlledInferenceProvider()
        let task = Task {
            await v3InferenceRunner().run(request: request, provider: provider)
        }

        await provider.waitUntilStarted()
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome.disposition, .cancelled)
        let cancelledRequestIDs = await provider.waitForCancellation()
        XCTAssertEqual(cancelledRequestIDs, [request.requestID])

        do {
            try await provider.emitLate(
                inferenceEvent(request, sequence: 1, body: .contentDelta("late"))
            )
            XCTFail("Expected a late event to be rejected")
        } catch {
            XCTAssertEqual(error as? Phase2InferenceViolation, .postTerminalEvent)
        }
    }

    func testCancellationDoesNotReturnUntilProviderCancellationAndRunDrain() async {
        let request = makeInferenceRequest()
        let provider = DrainingCancellationInferenceProvider()
        let runTask = Task {
            await v3InferenceRunner().run(request: request, provider: provider)
        }
        let completion = InferenceOutcomeProbe()
        let observer = Task {
            await completion.store(await runTask.value)
        }

        await provider.waitUntilStarted()
        runTask.cancel()
        await provider.waitUntilCancellationBegan()
        await Task.yield()

        let prematureOutcome = await completion.value
        XCTAssertNil(prematureOutcome, "runner returned before provider cancellation drained")

        await provider.releaseCancellation()
        await observer.value

        let outcome = await completion.value
        XCTAssertEqual(outcome?.disposition, .cancelled)
        let state = await provider.state
        XCTAssertEqual(state.cancelledRequestIDs, [request.requestID])
        XCTAssertTrue(state.runExited)
    }
}

private struct ScriptedInferenceProvider: Phase2InferenceProviding {
    let events: [Phase2InferenceEvent]

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        for event in events {
            try await emit(event)
        }
    }

    func cancel(requestID: UUID) async {}
}

private actor RecordingInferenceProvider: Phase2InferenceProviding {
    private var runs = 0

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        runs += 1
    }

    func cancel(requestID: UUID) async {}

    func runCount() -> Int { runs }
}

private struct BoundaryViolationThrowingProvider: Phase2InferenceProviding {
    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        throw Phase2InferenceViolation.identityMismatch
    }

    func cancel(requestID: UUID) async {}
}

private struct OutputLimitThrowingProvider: Phase2InferenceProviding {
    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        throw Phase2ProviderOutputLimitReached()
    }

    func cancel(requestID: UUID) async {}
}

private actor ControlledInferenceProvider: Phase2InferenceProviding {
    typealias EventSink = @Sendable (Phase2InferenceEvent) async throws -> Void

    private var eventSink: EventSink?
    private var runContinuation: CheckedContinuation<Void, any Error>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<[UUID], Never>] = []
    private var started = false
    private var cancellations: [UUID] = []

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping EventSink
    ) async throws {
        eventSink = emit
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        try await withCheckedThrowingContinuation { continuation in
            runContinuation = continuation
        }
    }

    func cancel(requestID: UUID) async {
        cancellations.append(requestID)
        for waiter in cancellationWaiters {
            waiter.resume(returning: cancellations)
        }
        cancellationWaiters.removeAll()
        runContinuation?.resume(throwing: CancellationError())
        runContinuation = nil
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitForCancellation() async -> [UUID] {
        guard cancellations.isEmpty else { return cancellations }
        return await withCheckedContinuation { continuation in
            cancellationWaiters.append(continuation)
        }
    }

    func emitLate(_ event: Phase2InferenceEvent) async throws {
        guard let eventSink else {
            return XCTFail("Provider did not receive an event sink")
        }
        try await eventSink(event)
    }
}

private actor InferenceOutcomeProbe {
    private(set) var value: Phase2InferenceOutcome?

    func store(_ outcome: Phase2InferenceOutcome) {
        value = outcome
    }
}

private actor DrainingCancellationInferenceProvider: Phase2InferenceProviding {
    struct State: Equatable, Sendable {
        let cancelledRequestIDs: [UUID]
        let runExited: Bool
    }

    private var started = false
    private var runExited = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationBeganWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationBegan = false
    private var cancellationReleased = false
    private var runContinuation: CheckedContinuation<Void, Never>?
    private var cancellations: [UUID] = []

    var state: State {
        .init(cancelledRequestIDs: cancellations, runExited: runExited)
    }

    func run(
        request: Phase2InferenceRequest,
        emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void
    ) async throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            runContinuation = continuation
        }
        runExited = true
    }

    func cancel(requestID: UUID) async {
        cancellations.append(requestID)
        cancellationBegan = true
        let beganWaiters = cancellationBeganWaiters
        cancellationBeganWaiters.removeAll()
        beganWaiters.forEach { $0.resume() }

        if !cancellationReleased {
            await withCheckedContinuation { continuation in
                cancellationReleaseWaiters.append(continuation)
            }
        }
        runContinuation?.resume()
        runContinuation = nil
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func waitUntilCancellationBegan() async {
        guard !cancellationBegan else { return }
        await withCheckedContinuation { continuation in
            cancellationBeganWaiters.append(continuation)
        }
    }

    func releaseCancellation() {
        cancellationReleased = true
        let waiters = cancellationReleaseWaiters
        cancellationReleaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func makeInferenceRequest(
    protocolVersion: Phase2InferenceProtocolVersion = .v3,
    phase: Phase2InferencePhase = .finalization,
    handles: [Phase2InferenceToolHandle] = [],
    groundedContext: Phase2GroundedContext? = nil,
    shellContinuationCoordinate: Phase2AssistantShellContinuationCoordinate? = nil,
    limits: Phase2InferenceLimits = .maximum
) -> Phase2InferenceRequest {
    let workspace = inferenceWorkspace()
    return .init(
        protocolVersion: protocolVersion,
        phase: phase,
        sessionID: inferenceID(3),
        turnID: inferenceID(4),
        requestID: inferenceID(5),
        document: workspace.document,
        workspace: workspace,
        lifecycleRevision: 7,
        userGoal: "Explain the selected function",
        groundedContext: groundedContext ?? (try! Phase2GroundedContextCompiler().compile(
            records: [],
            currentStateByEvidenceID: [:]
        )),
        toolHandles: handles,
        shellContinuationCoordinate: shellContinuationCoordinate,
        limits: limits
    )
}

private func makeShellContinuationRequest(evidenceID: UUID) -> Phase2InferenceRequest {
    let workspace = inferenceWorkspace()
    let coordinate = Phase2AssistantShellContinuationCoordinate(
        workspaceID: workspace.instanceID,
        workspaceDocumentIdentityDigest: String(repeating: "d", count: 64),
        conversationID: inferenceID(3),
        inferenceTurnID: inferenceID(4),
        turnSequence: 1,
        originatingFinalizationRequestID: inferenceID(6),
        shellProposalID: inferenceID(7),
        shellExecutionID: inferenceID(8),
        runtimeAuthorityRecordID: inferenceID(9),
        shellProposalDigest: String(repeating: "a", count: 64),
        shellExecutionResultDigest: String(repeating: "b", count: 64),
        runtimeAuthorityRecordDigest: String(repeating: "c", count: 64),
        productionManifestIdentity:
            Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
        providerRevision: 7,
        continuationRequestID: inferenceID(5)
    )!
    return makeInferenceRequest(
        protocolVersion: .v6,
        phase: .shellContinuation,
        groundedContext: makeCanonicalGroundedContext(
            workspace: workspace,
            evidenceID: evidenceID
        ),
        shellContinuationCoordinate: coordinate,
        limits: .assistantMaximum
    )
}

private func v3InferenceRunner() -> Phase2InferenceRunner {
    Phase2InferenceRunner(acceptedProtocolVersion: .v3)
}

private func v4InferenceRunner() -> Phase2InferenceRunner {
    Phase2InferenceRunner(acceptedProtocolVersion: .v4)
}

private func phase2ProviderUsage(prompt: Int, completion: Int) -> Phase2ProviderUsage {
    Phase2ProviderUsage(
        promptTokens: prompt,
        completionTokens: completion,
        totalTokens: prompt + completion
    )!
}

private func inferenceWorkspace() -> Phase2ReadWorkspaceIdentity {
    .init(
        document: .init(instanceID: inferenceID(1)),
        instanceID: inferenceID(2)
    )
}

private func makeCanonicalGroundedContext(
    workspace: Phase2ReadWorkspaceIdentity,
    evidenceID: UUID
) -> Phase2GroundedContext {
    let record = Phase2GroundedContextRecord(
        evidenceID: evidenceID,
        candidateID: inferenceID(101),
        invocationID: inferenceID(102),
        sequence: 1,
        descriptor: .init(
            registryVersion: .v1,
            id: .workspaceSummary,
            operationVersion: .v1,
            effects: [.a1]
        ),
        producingPrincipal: .app,
        trustClass: .untrustedProjectData,
        precondition: .init(
            workspace: workspace,
            workspaceRevision: 1,
            strictWholeWorkspace: true,
            image: nil,
            dependencies: []
        ),
        citations: [],
        data: .value(.text("grounded")),
        payloadDigest: String(repeating: "a", count: 64)
    )
    let manifest = Phase2GroundedContextManifest(records: [record], omissions: [])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let canonicalBytes = try! encoder.encode(manifest)
    let digest = SHA256.hash(data: canonicalBytes)
        .map { String(format: "%02x", $0) }
        .joined()
    return .make(
        records: [record],
        omissions: [],
        canonicalBytes: canonicalBytes,
        digest: digest
    )
}

private func inferenceEvent(
    _ request: Phase2InferenceRequest,
    sequence: UInt64,
    body: Phase2InferenceEventBody
) -> Phase2InferenceEvent {
    .init(
        protocolVersion: request.protocolVersion,
        phase: request.phase,
        sessionID: request.sessionID,
        turnID: request.turnID,
        requestID: request.requestID,
        document: request.document,
        workspace: request.workspace,
        lifecycleRevision: request.lifecycleRevision,
        sequence: sequence,
        body: body
    )
}

private func inferenceID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}
