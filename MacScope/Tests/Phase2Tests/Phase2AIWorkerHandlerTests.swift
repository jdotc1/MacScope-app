import XCTest

@testable import MacScope

final class Phase2AIWorkerHandlerTests: XCTestCase {
    func testV6ShellContinuationEmitsOneFinalUsageAndCompletionWithoutTools() async throws {
        let evidenceID = handlerID(20)
        let request = handlerRequest(
            phase: .shellContinuation,
            evidenceIDs: [evidenceID],
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
        )
        let handler = Phase2LiveInferenceHandler { _, prompt, phase, variant, onEvent in
            XCTAssertEqual(phase, .shellContinuation)
            XCTAssertEqual(variant, .assistantR4)
            XCTAssertTrue(prompt.system.contains("macscope.shell-continuation.v1"))
            XCTAssertTrue(prompt.system.contains("untrusted"))
            XCTAssertTrue(prompt.user.contains("shell_execution_evidence"))
            await onEvent(.contentDelta(
                "{\"kind\":\"answer\",\"text\":\"Result.\",\"evidence_ids\":[\"\(evidenceID.uuidString)\"],\"reason\":\"\"}"
            ))
            await onEvent(.finished)
            await onEvent(.usage(.init(promptTokens: 2, completionTokens: 1, totalTokens: 3)))
            await onEvent(.done)
        }
        let probe = Phase2HandlerEventProbe()
        try await handler.run(
            request: request,
            configuration: handlerConfiguration(
                manifestDigest: Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest
            ),
            emit: { await probe.append($0) }
        )
        let bodies = await probe.values.map(\.body)
        XCTAssertEqual(bodies, [
            .finalCandidate(kind: .answer, text: "Result.", evidenceIDs: [evidenceID]),
            .usage(.init(promptTokens: 2, completionTokens: 1, totalTokens: 3)),
            .completed,
        ])
    }

    func testV5SelectionStripsEmptyHistoryWhileFinalizationForwardsCompletedHistory() async throws {
        let conversationID = handlerID(80)
        let priorTurn = Phase2AIWorkerWireConversationTurn(
            conversationID: conversationID,
            inferenceTurnID: handlerID(81),
            turnSequence: 1,
            user: "prior-user",
            assistant: "prior-assistant",
            isLegacy: false
        )
        let empty = Phase2AIWorkerWireConversationContext(turns: [], omittedTurnCount: 0)
        let completed = Phase2AIWorkerWireConversationContext(
            turns: [priorTurn], omittedTurnCount: 0
        )
        let selectionProbe = Phase2HandlerInputProbe()
        let selection = Phase2LiveInferenceHandler {
            configuration, prompt, phase, generationVariant, onEvent in
            await selectionProbe.record(
                configuration: configuration, prompt: prompt,
                phase: phase, generationVariant: generationVariant
            )
            await onEvent(.toolCall(.init(
                opaqueCallID: "call", functionName: "macscope_workspace_summary_v1",
                handleID: handlerID(82)
            )))
            await onEvent(.usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)))
            await onEvent(.awaitingTools)
        }
        try await selection.run(
            request: handlerRequest(
                phase: .toolSelection,
                handles: [.init(handleID: handlerID(82), operationID: "workspace.summary")],
                protocolVersion: Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion,
                conversationContext: empty
            ),
            configuration: handlerConfiguration(
                manifestDigest: Phase2AIWorkerProductionProtocol.assistantR3.manifestDigest
            ),
            emit: { _ in }
        )
        let selectionInput = await selectionProbe.value
        XCTAssertNil(selectionInput?.prompt.conversationContext)

        let finalization = Phase2LiveInferenceHandler { _, prompt, _, _, onEvent in
            XCTAssertEqual(prompt.conversationContext?.turns.map(\.user), ["prior-user"])
            await onEvent(.contentDelta(
                #"{"kind":"insufficient_evidence","text":"","evidence_ids":[],"reason":"No current evidence."}"#
            ))
            await onEvent(.finished)
            await onEvent(.usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)))
            await onEvent(.done)
        }
        try await finalization.run(
            request: handlerRequest(
                phase: .finalization,
                protocolVersion: Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion,
                conversationContext: completed
            ),
            configuration: handlerConfiguration(
                manifestDigest: Phase2AIWorkerProductionProtocol.assistantR3.manifestDigest
            ),
            emit: { _ in }
        )
    }

    func testToolSelectionEmitsProviderOrderedProposalsThenAwaitingTools() async throws {
        let firstHandle = handlerID(9)
        let secondHandle = handlerID(10)
        let request = handlerRequest(
            phase: .toolSelection,
            handles: [
                .init(handleID: firstHandle, operationID: "workspace.summary"),
                .init(handleID: secondHandle, operationID: "function.review"),
            ]
        )
        let inputProbe = Phase2HandlerInputProbe()
        let handler = Phase2LiveInferenceHandler {
            configuration, prompt, phase, generationVariant, onEvent in
            await inputProbe.record(
                configuration: configuration,
                prompt: prompt,
                phase: phase,
                generationVariant: generationVariant
            )
            await onEvent(.usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
            await onEvent(.toolCall(.init(
                opaqueCallID: "Call_é/first",
                functionName: "macscope_workspace_summary_v1",
                handleID: firstHandle
            )))
            await onEvent(.toolCall(.init(
                opaqueCallID: "second-call",
                functionName: "macscope_function_review_v1",
                handleID: secondHandle
            )))
            await onEvent(.awaitingTools)
        }
        let eventProbe = Phase2HandlerEventProbe()

        try await handler.run(
            request: request,
            configuration: handlerConfiguration(),
            emit: { await eventProbe.append($0) }
        )

        let recordedInput = await inputProbe.value
        let input = try XCTUnwrap(recordedInput)
        XCTAssertEqual(input.configuration, handlerConfiguration())
        XCTAssertEqual(input.generationVariant, .stagedV2)
        XCTAssertTrue(input.prompt.user.contains("\"phase\":\"toolSelection\""))
        XCTAssertTrue(input.prompt.user.contains("\"goal\":\"Explain the selected function\""))
        guard case .toolSelection(let handles) = input.phase else {
            return XCTFail("Expected tool selection")
        }
        XCTAssertEqual(handles, [
            .init(handleID: firstHandle, operationID: "workspace.summary"),
            .init(handleID: secondHandle, operationID: "function.review"),
        ])

        let events = await eventProbe.values
        XCTAssertEqual(events.map(\.body), [
            .toolProposal(
                callID: "Call_é/first",
                handleID: firstHandle,
                functionName: "macscope_workspace_summary_v1",
                operationID: "workspace.summary"
            ),
            .toolProposal(
                callID: "second-call",
                handleID: secondHandle,
                functionName: "macscope_function_review_v1",
                operationID: "function.review"
            ),
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .awaitingTools,
        ])
        assertExactIdentity(events, request: request)
    }

    func testFinalizationDecodesAnswerAndEmitsCandidateThenCompleted() async throws {
        let evidenceID = handlerID(20)
        let request = handlerRequest(phase: .finalization, evidenceIDs: [evidenceID])
        let handler = Phase2LiveInferenceHandler { _, prompt, phase, _, onEvent in
            XCTAssertTrue(prompt.system.contains("macscope.finalization.v1"))
            XCTAssertEqual(phase, .finalization)
            await onEvent(.contentDelta(
                "{\"kind\":\"answer\",\"text\":\"Grounded answer.\",\"evidence_ids\":[\"\(evidenceID.uuidString)\"],\"reason\":\"\"}"
            ))
            await onEvent(.finished)
            await onEvent(.usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)))
            await onEvent(.done)
        }
        let eventProbe = Phase2HandlerEventProbe()

        try await handler.run(
            request: request,
            configuration: handlerConfiguration(),
            emit: { await eventProbe.append($0) }
        )

        let events = await eventProbe.values
        XCTAssertEqual(events.map(\.body), [
            .finalCandidate(kind: .answer, text: "Grounded answer.", evidenceIDs: [evidenceID]),
            .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)),
            .completed,
        ])
        assertExactIdentity(events, request: request)
    }

    func testFinalizationPreservesInsufficientEvidenceAsUncitedCandidate() async throws {
        let request = handlerRequest(phase: .finalization)
        let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
            await onEvent(.contentDelta(
                "{\"kind\":\"insufficient_evidence\",\"text\":\"\",\"evidence_ids\":[],\"reason\":\"No accepted evidence supports the claim.\"}"
            ))
            await onEvent(.finished)
            await onEvent(.usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)))
            await onEvent(.done)
        }
        let eventProbe = Phase2HandlerEventProbe()

        try await handler.run(
            request: request,
            configuration: handlerConfiguration(),
            emit: { await eventProbe.append($0) }
        )

        let events = await eventProbe.values
        XCTAssertEqual(events.map(\.body), [
            .finalCandidate(
                kind: .insufficientEvidence,
                text: "No accepted evidence supports the claim.",
                evidenceIDs: []
            ),
            .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)),
            .completed,
        ])
    }

    func testProductionAliasSelectsGenerationV2AndEmitsUsageEvent() async throws {
        let request = handlerRequest(
            phase: .finalization,
            protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion
        )
        let inputProbe = Phase2HandlerInputProbe()
        let handler = Phase2LiveInferenceHandler {
            configuration, prompt, phase, generationVariant, onEvent in
            await inputProbe.record(
                configuration: configuration,
                prompt: prompt,
                phase: phase,
                generationVariant: generationVariant
            )
            await onEvent(.contentDelta(
                #"{"kind":"insufficient_evidence","text":"","evidence_ids":[],"reason":"No accepted evidence supports the claim."}"#
            ))
            await onEvent(.finished)
            await onEvent(.usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
            await onEvent(.done)
        }
        let eventProbe = Phase2HandlerEventProbe()

        try await handler.run(
            request: request,
            configuration: handlerConfiguration(),
            emit: { await eventProbe.append($0) }
        )

        let recordedInput = await inputProbe.value
        let input = try XCTUnwrap(recordedInput)
        XCTAssertEqual(input.generationVariant, .stagedV2)
        let events = await eventProbe.values
        XCTAssertEqual(events.map(\.body), [
            .finalCandidate(
                kind: .insufficientEvidence,
                text: "No accepted evidence supports the claim.",
                evidenceIDs: []
            ),
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .completed,
        ])
    }

    func testToolSelectionRejectsFunctionWhoseOperationDoesNotMatchOfferedHandle() async {
        let handleID = handlerID(40)
        let request = handlerRequest(
            phase: .toolSelection,
            handles: [.init(handleID: handleID, operationID: "workspace.summary")]
        )
        let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
            await onEvent(.toolCall(.init(
                opaqueCallID: "call",
                functionName: "macscope_function_review_v1",
                handleID: handleID
            )))
            await onEvent(.awaitingTools)
        }

        do {
            try await handler.run(
                request: request,
                configuration: handlerConfiguration(),
                emit: { _ in }
            )
            XCTFail("Expected mismatched function/operation to fail closed")
        } catch {
            XCTAssertEqual(error as? Phase2LiveInferenceHandlerError, .invalidToolSelection)
        }
    }

    func testToolSelectionTreatsCanonicallyEquivalentCallIDsAsDistinctOpaqueBytes() async throws {
        let firstHandle = handlerID(45)
        let secondHandle = handlerID(46)
        let composed = "caf\u{00e9}"
        let decomposed = "cafe\u{0301}"
        let request = handlerRequest(
            phase: .toolSelection,
            handles: [
                .init(handleID: firstHandle, operationID: "workspace.summary"),
                .init(handleID: secondHandle, operationID: "function.review"),
            ]
        )
        let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
            await onEvent(.usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
            await onEvent(.toolCall(.init(
                opaqueCallID: composed,
                functionName: "macscope_workspace_summary_v1",
                handleID: firstHandle
            )))
            await onEvent(.toolCall(.init(
                opaqueCallID: decomposed,
                functionName: "macscope_function_review_v1",
                handleID: secondHandle
            )))
            await onEvent(.awaitingTools)
        }
        let events = Phase2HandlerEventProbe()

        try await handler.run(
            request: request,
            configuration: handlerConfiguration(),
            emit: { await events.append($0) }
        )

        let proposals = await events.values
        XCTAssertEqual(proposals.count, 4)
        guard case .toolProposal(let firstID, _, _, _) = proposals[0].body,
              case .toolProposal(let secondID, _, _, _) = proposals[1].body else {
            return XCTFail("Expected two tool proposals")
        }
        XCTAssertTrue(firstID.utf8.elementsEqual(composed.utf8))
        XCTAssertTrue(secondID.utf8.elementsEqual(decomposed.utf8))
        XCTAssertFalse(firstID.utf8.elementsEqual(secondID.utf8))
        XCTAssertEqual(
            proposals[2].body,
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10))
        )
        XCTAssertEqual(proposals[3].body, .awaitingTools)
    }

    func testToolSelectionRejectsMissingOrDuplicateUsageAndForbiddenEvents() async {
        let handleID = handlerID(42)
        let request = handlerRequest(
            phase: .toolSelection,
            handles: [.init(handleID: handleID, operationID: "workspace.summary")]
        )
        let validCall = Phase2OpenAIChatStreamEvent.toolCall(.init(
            opaqueCallID: "call",
            functionName: "macscope_workspace_summary_v1",
            handleID: handleID
        ))
        let usage = Phase2OpenAIChatStreamEvent.usage(.init(
            promptTokens: 7,
            completionTokens: 3,
            totalTokens: 10
        ))
        let invalidSequences: [[Phase2OpenAIChatStreamEvent]] = [
            [validCall, .awaitingTools],
            [usage, usage, validCall, .awaitingTools],
            [usage, .contentDelta("forbidden"), validCall, .awaitingTools],
            [usage, .done, validCall, .awaitingTools],
        ]

        for sequence in invalidSequences {
            let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
                for event in sequence { await onEvent(event) }
            }
            do {
                try await handler.run(
                    request: request,
                    configuration: handlerConfiguration(),
                    emit: { _ in }
                )
                XCTFail("Expected selection sequence to fail closed: \(sequence)")
            } catch {
                XCTAssertEqual(error as? Phase2LiveInferenceHandlerError, .invalidToolSelection)
            }
        }
    }

    func testFinalizationRejectsMissingOrDuplicateUsage() async {
        let evidenceID = handlerID(48)
        let request = handlerRequest(phase: .finalization, evidenceIDs: [evidenceID])
        let content = Phase2OpenAIChatStreamEvent.contentDelta(
            "{\"kind\":\"answer\",\"text\":\"Grounded.\",\"evidence_ids\":[\"\(evidenceID.uuidString)\"],\"reason\":\"\"}"
        )
        let usage = Phase2OpenAIChatStreamEvent.usage(.init(
            promptTokens: 7,
            completionTokens: 3,
            totalTokens: 10
        ))
        let invalidSequences: [[Phase2OpenAIChatStreamEvent]] = [
            [content, .finished, .done],
            [content, .finished, usage, usage, .done],
        ]

        for sequence in invalidSequences {
            let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
                for event in sequence { await onEvent(event) }
            }
            do {
                try await handler.run(
                    request: request,
                    configuration: handlerConfiguration(),
                    emit: { _ in }
                )
                XCTFail("Expected finalization sequence to fail closed: \(sequence)")
            } catch {
                XCTAssertEqual(error as? Phase2LiveInferenceHandlerError, .invalidFinalization)
            }
        }
    }

    func testR1FinalizationRejectsUnsolicitedProposalToolEvent() async {
        let request = handlerRequest(phase: .finalization)
        let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
            await onEvent(.shellProposal(handlerShellProposal()))
            await onEvent(.usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
            await onEvent(.done)
        }

        do {
            try await handler.run(
                request: request,
                configuration: handlerConfiguration(),
                emit: { _ in }
            )
            XCTFail("Expected R1 proposal authority to fail closed")
        } catch {
            XCTAssertEqual(error as? Phase2LiveInferenceHandlerError, .invalidFinalization)
        }
    }

    func testR2ProposalOnlyFinalizationProducesSafeTerminalCandidateAndProposal() async throws {
        let request = handlerRequest(
            phase: .finalization,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion
        )
        let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
            await onEvent(.shellProposal(handlerShellProposal()))
            await onEvent(.usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
            await onEvent(.done)
        }
        let events = Phase2HandlerEventProbe()

        try await handler.run(
            request: request,
            configuration: handlerConfiguration(
                manifestDigest: Phase2AIWorkerProductionProtocol.assistantR2.manifestDigest
            ),
            emit: { await events.append($0) }
        )

        let bodies = await events.values.map(\.body)
        XCTAssertEqual(bodies.count, 4)
        guard case .shellProposal = bodies[0] else { return XCTFail("Expected proposal") }
        XCTAssertEqual(
            bodies[1],
            .finalCandidate(
                kind: .insufficientEvidence,
                text: "The provider returned an action proposal without a grounded final answer.",
                evidenceIDs: []
            )
        )
        XCTAssertEqual(bodies[2], .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
        XCTAssertEqual(bodies[3], .completed)
    }

    func testR2FinalizationRejectsProposalAfterUsageWithoutReordering() async {
        let request = handlerRequest(
            phase: .finalization,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion
        )
        let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
            await onEvent(.usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
            await onEvent(.shellProposal(handlerShellProposal()))
            await onEvent(.done)
        }

        do {
            try await handler.run(
                request: request,
                configuration: handlerConfiguration(
                    manifestDigest: Phase2AIWorkerProductionProtocol.assistantR2.manifestDigest
                ),
                emit: { _ in }
            )
            XCTFail("Expected a proposal after usage to fail closed")
        } catch {
            XCTAssertEqual(error as? Phase2LiveInferenceHandlerError, .invalidFinalization)
        }
    }

    func testRealHTTPClientDrivesIndependentTwoPhaseHandlerWithoutContinuation() async throws {
        let handleID = handlerID(43)
        let evidenceID = handlerID(44)
        let selectionRequest = handlerRequest(
            phase: .toolSelection,
            handles: [.init(handleID: handleID, operationID: "workspace.summary")]
        )
        let finalizationRequest = handlerRequest(
            phase: .finalization,
            evidenceIDs: [evidenceID]
        )
        let configuration = handlerConfiguration()
        let loader = Phase2TwoPhaseHandlerLoader(
            selectionChunks: fragmentedHandlerStream(handlerToolSelectionStream(handleID: handleID)),
            finalizationChunks: fragmentedHandlerStream(handlerFinalizationStream(evidenceID: evidenceID))
        )
        let handler = Phase2LiveInferenceHandler {
            configuration, prompt, phase, generationVariant, onEvent in
            let client = Phase2OpenAIChatHTTPClient(loader: loader)
            try await client.execute(.init(
                endpoint: try Phase2LoopbackEndpoint(validating: configuration.endpointOrigin),
                model: configuration.model,
                systemPrompt: prompt.system,
                userPrompt: prompt.user,
                maximumTokens: configuration.maximumTokens,
                phase: phase,
                generationVariant: generationVariant
            ), onEvent: onEvent)
        }
        let selectionEvents = Phase2HandlerEventProbe()
        let finalizationEvents = Phase2HandlerEventProbe()

        try await handler.run(
            request: selectionRequest,
            configuration: configuration,
            emit: { await selectionEvents.append($0) }
        )
        // The app supplies a new, independently grounded request. The handler never reads tools,
        // retries, or auto-continues the provider conversation.
        try await handler.run(
            request: finalizationRequest,
            configuration: configuration,
            emit: { await finalizationEvents.append($0) }
        )

        let emittedSelectionEvents = await selectionEvents.values
        let emittedFinalizationEvents = await finalizationEvents.values
        XCTAssertEqual(emittedSelectionEvents.map(\.body), [
            .toolProposal(
                callID: "opaque-call-1",
                handleID: handleID,
                functionName: "macscope_workspace_summary_v1",
                operationID: "workspace.summary"
            ),
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .awaitingTools,
        ])
        XCTAssertEqual(emittedFinalizationEvents.map(\.body), [
            .finalCandidate(kind: .answer, text: "Grounded.", evidenceIDs: [evidenceID]),
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .completed,
        ])

        let captured = await loader.requests
        XCTAssertEqual(captured.count, 2, "One provider call per independently supplied phase")
        XCTAssertEqual(captured.map(\.method), ["POST", "POST"])
        XCTAssertEqual(captured.map(\.url), [
            "http://127.0.0.1:1234/v1/chat/completions",
            "http://127.0.0.1:1234/v1/chat/completions",
        ])

        let compiler = Phase2ProductionPromptCompiler()
        let encoder = Phase2OpenAIChatRequestEncoder()
        let expectedSelectionPrompt = try compiler.compile(.init(
            phase: .toolSelection,
            userGoal: selectionRequest.userGoal,
            canonicalContext: selectionRequest.canonicalContext,
            evidenceIDs: selectionRequest.evidenceIDs
        ))
        let expectedFinalizationPrompt = try compiler.compile(.init(
            phase: .finalization,
            userGoal: finalizationRequest.userGoal,
            canonicalContext: finalizationRequest.canonicalContext,
            evidenceIDs: finalizationRequest.evidenceIDs
        ))
        XCTAssertEqual(captured[0].body, try encoder.encodeProduction(.init(
            model: configuration.model,
            systemPrompt: expectedSelectionPrompt.system,
            userPrompt: expectedSelectionPrompt.user,
            maximumTokens: configuration.maximumTokens,
            phase: .toolSelection(handles: [
                .init(handleID: handleID, operationID: "workspace.summary"),
            ]),
            generationVariant: .stagedV2
        )))
        XCTAssertEqual(captured[1].body, try encoder.encodeProduction(.init(
            model: configuration.model,
            systemPrompt: expectedFinalizationPrompt.system,
            userPrompt: expectedFinalizationPrompt.user,
            maximumTokens: configuration.maximumTokens,
            phase: .finalization,
            generationVariant: .stagedV2,
            allowsFinalizationProposalTools: false
        )))
    }

    func testRealHTTPDecoderPublishesShellAndDebuggerProposalsBeforeUsageAtValidatedEOF() async throws {
        let evidenceID = handlerID(44)
        for (debugger, inlineUsage) in [(false, false), (true, false), (false, true), (true, true)] {
            let stream = try handlerFinalizationProposalStream(evidenceID: evidenceID, debugger: debugger, inlineUsage: inlineUsage)
            let loader = Phase2TwoPhaseHandlerLoader(selectionChunks: fragmentedHandlerStream(stream),
                finalizationChunks: [])
            let handler = Phase2LiveInferenceHandler { configuration, prompt, phase, variant, onEvent in
                let client = Phase2OpenAIChatHTTPClient(loader: loader)
                try await client.execute(.init(
                    endpoint: try Phase2LoopbackEndpoint(validating: configuration.endpointOrigin),
                    model: configuration.model, systemPrompt: prompt.system, userPrompt: prompt.user,
                    maximumTokens: configuration.maximumTokens, phase: phase,
                    generationVariant: variant, acceptsFinalizationProposalTools: true,
                    inferencePolicy: inlineUsage ? .init() : nil
                ), onEvent: onEvent)
            }
            let probe = Phase2HandlerEventProbe()
            try await handler.run(request: handlerRequest(phase: .finalization,
                evidenceIDs: [evidenceID], protocolVersion: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion),
                configuration: handlerConfiguration(manifestDigest: Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest),
                emit: { await probe.append($0) })
            let bodies = await probe.values.map(\.body)
            XCTAssertEqual(bodies.count, 4)
            if debugger {
                guard case .debuggerActionProposal = bodies[0] else { return XCTFail("Expected debugger proposal") }
            } else {
                guard case .shellProposal = bodies[0] else { return XCTFail("Expected shell proposal") }
            }
            XCTAssertEqual(bodies[1], .finalCandidate(kind: .answer, text: "Grounded.", evidenceIDs: [evidenceID]))
            XCTAssertEqual(bodies[2], .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
            XCTAssertEqual(bodies[3], .completed)
        }
    }

    func testMaximumFinalAnswerEmitsWithoutOversizedPreviewEvent() async throws {
        let evidenceID = handlerID(41)
        let text = String(repeating: "x", count: Phase2GroundedFinalDecoder.maximumTextBytes)
        let request = handlerRequest(phase: .finalization, evidenceIDs: [evidenceID])
        let handler = Phase2LiveInferenceHandler { _, _, _, _, onEvent in
            await onEvent(.contentDelta(
                "{\"kind\":\"answer\",\"text\":\"\(text)\",\"evidence_ids\":[\"\(evidenceID.uuidString)\"],\"reason\":\"\"}"
            ))
            await onEvent(.finished)
            await onEvent(.usage(.init(promptTokens: 9, completionTokens: 5, totalTokens: 14)))
            await onEvent(.done)
        }
        let eventProbe = Phase2HandlerEventProbe()

        try await handler.run(
            request: request,
            configuration: handlerConfiguration(),
            emit: { await eventProbe.append($0) }
        )

        let events = await eventProbe.values
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.last?.body, .completed)
        XCTAssertEqual(
            events.dropLast().last?.body,
            .usage(.init(promptTokens: 9, completionTokens: 5, totalTokens: 14))
        )
        guard case .finalCandidate(let kind, let candidateText, let evidenceIDs) = events.first?.body else {
            return XCTFail("Expected a final candidate")
        }
        XCTAssertEqual(kind, .answer)
        XCTAssertEqual(candidateText.utf8.count, Phase2GroundedFinalDecoder.maximumTextBytes)
        XCTAssertEqual(evidenceIDs, [evidenceID])
    }

    private func assertExactIdentity(
        _ events: [Phase2AIWorkerWireEvent],
        request: Phase2AIWorkerWireRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(events.map(\.sequence), Array(1...UInt64(events.count)), file: file, line: line)
        for event in events {
            XCTAssertEqual(event.wireProtocol, request.wireProtocol, file: file, line: line)
            XCTAssertEqual(event.protocolVersion, request.protocolVersion, file: file, line: line)
            XCTAssertEqual(event.phase, request.phase, file: file, line: line)
            XCTAssertEqual(event.sessionID, request.sessionID, file: file, line: line)
            XCTAssertEqual(event.turnID, request.turnID, file: file, line: line)
            XCTAssertEqual(event.requestID, request.requestID, file: file, line: line)
            XCTAssertEqual(event.documentID, request.documentID, file: file, line: line)
            XCTAssertEqual(event.workspaceID, request.workspaceID, file: file, line: line)
            XCTAssertEqual(event.lifecycleRevision, request.lifecycleRevision, file: file, line: line)
        }
    }
}

private struct Phase2HandlerRecordedInput: Sendable {
    let configuration: Phase2AIWorkerConfigurationWire
    let prompt: Phase2ProductionPrompt
    let phase: Phase2OpenAIProductionChatPhase
    let generationVariant: Phase2OpenAIRequestGenerationVariant
}

private actor Phase2HandlerInputProbe {
    private(set) var value: Phase2HandlerRecordedInput?

    func record(
        configuration: Phase2AIWorkerConfigurationWire,
        prompt: Phase2ProductionPrompt,
        phase: Phase2OpenAIProductionChatPhase,
        generationVariant: Phase2OpenAIRequestGenerationVariant
    ) {
        value = .init(
            configuration: configuration,
            prompt: prompt,
            phase: phase,
            generationVariant: generationVariant
        )
    }
}

private actor Phase2HandlerEventProbe {
    private(set) var values: [Phase2AIWorkerWireEvent] = []

    func append(_ event: Phase2AIWorkerWireEvent) {
        values.append(event)
    }
}

private actor Phase2TwoPhaseHandlerLoader: Phase2OpenAIChatURLLoading {
    struct CapturedRequest: Sendable {
        let method: String?
        let url: String?
        let body: Data?
    }

    private let selectionChunks: [Data]
    private let finalizationChunks: [Data]
    private(set) var requests: [CapturedRequest] = []

    init(selectionChunks: [Data], finalizationChunks: [Data]) {
        self.selectionChunks = selectionChunks
        self.finalizationChunks = finalizationChunks
    }

    func load(_ request: URLRequest) async throws -> Phase2OpenAIChatHTTPResponse {
        requests.append(.init(
            method: request.httpMethod,
            url: request.url?.absoluteString,
            body: request.httpBody
        ))
        switch requests.count {
        case 1:
            return handlerResponse(chunks: selectionChunks)
        case 2:
            return handlerResponse(chunks: finalizationChunks)
        default:
            throw Phase2OpenAIChatHTTPClientError.transportFailed
        }
    }
}

private func handlerResponse(chunks: [Data]) -> Phase2OpenAIChatHTTPResponse {
    return .init(
        statusCode: 200,
        contentType: "text/event-stream",
        finalURL: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
        body: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    )
}

private func handlerToolSelectionStream(handleID: UUID) -> Data {
    let first = """
    {"id":"chat-handler","object":"chat.completion.chunk","created":1,"model":"model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"opaque-call-1","type":"function","function":{"name":"macscope_workspace_summary_v1","arguments":"{\\\"handle_id\\\":\\\""}}]},"finish_reason":null}]}
    """
    let second = """
    {"id":"chat-handler","object":"chat.completion.chunk","created":1,"model":"model","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\(handleID.uuidString)\\\"}"}}]},"finish_reason":"tool_calls"}]}
    """
    return Data((
        handlerSSE(first)
            + handlerSSE(second)
            + handlerSSE(handlerUsageChunk())
            + handlerSSE("[DONE]")
    ).utf8)
}

private func handlerFinalizationStream(evidenceID: UUID) -> Data {
    let envelope = """
    {"kind":"answer","text":"Grounded.","evidence_ids":["\(evidenceID.uuidString)"],"reason":""}
    """
    let escapedEnvelope = String(data: try! JSONSerialization.data(
        withJSONObject: envelope,
        options: [.fragmentsAllowed, .withoutEscapingSlashes]
    ), encoding: .utf8)!
    let content = """
    {"id":"chat-handler","object":"chat.completion.chunk","created":1,"model":"model","choices":[{"index":0,"delta":{"content":\(escapedEnvelope)},"finish_reason":null}]}
    """
    let stop = """
    {"id":"chat-handler","object":"chat.completion.chunk","created":1,"model":"model","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
    """
    return Data((
        handlerSSE(content)
            + handlerSSE(stop)
            + handlerSSE(handlerUsageChunk())
            + handlerSSE("[DONE]")
    ).utf8)
}

private func handlerUsageChunk() -> String {
    #"{"id":"chat-handler","object":"chat.completion.chunk","created":1,"model":"model","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}"#
}

private func handlerSSE(_ data: String) -> String { "data: \(data)\n\n" }

private func fragmentedHandlerStream(_ data: Data) -> [Data] {
    let cuts = [1, 7, 31, 89, 144, max(145, data.count / 2), max(146, data.count - 3)]
        .filter { $0 > 0 && $0 < data.count }
    var chunks: [Data] = []
    var start = 0
    for cut in cuts where cut > start {
        chunks.append(data.subdata(in: start..<cut))
        start = cut
    }
    chunks.append(data.subdata(in: start..<data.count))
    return chunks
}

private func handlerRequest(
    phase: Phase2AIWorkerWirePhase,
    evidenceIDs: [UUID] = [],
    handles: [Phase2AIWorkerWireToolHandle] = [],
    protocolVersion: Int = Phase2AIWorkerProductionProtocol.stagedV3InferenceVersion,
    conversationContext: Phase2AIWorkerWireConversationContext? = nil
) -> Phase2AIWorkerWireRequest {
    let bundle = switch protocolVersion {
    case Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion:
        Phase2AIWorkerProductionProtocol.assistantR2
    case Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion:
        Phase2AIWorkerProductionProtocol.assistantR3
    case Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion:
        Phase2AIWorkerProductionProtocol.assistantR4
    default:
        Phase2AIWorkerProductionProtocol.standard
    }
    let coordinate: Phase2AIWorkerWireShellContinuationCoordinate? = phase == .shellContinuation
        ? .init(
            workspaceID: handlerID(2),
            workspaceDocumentIdentityDigest: String(repeating: "d", count: 64),
            conversationID: handlerID(3), inferenceTurnID: handlerID(4), turnSequence: 1,
            originatingFinalizationRequestID: handlerID(40), shellProposalID: handlerID(41),
            shellExecutionID: handlerID(42), runtimeAuthorityRecordID: handlerID(43),
            shellProposalDigest: String(repeating: "a", count: 64),
            shellExecutionResultDigest: String(repeating: "b", count: 64),
            runtimeAuthorityRecordDigest: String(repeating: "c", count: 64),
            productionManifestIdentity: bundle.manifestIdentity, providerRevision: 1,
            continuationOrdinal: 1, continuationRequestID: handlerID(5),
            integrityDigest: String(repeating: "e", count: 64)
        ) : nil
    return .init(
        wireProtocol: bundle.wireIdentity,
        protocolVersion: protocolVersion,
        phase: phase,
        sessionID: handlerID(3),
        turnID: handlerID(4),
        requestID: handlerID(5),
        documentID: handlerID(1),
        workspaceID: handlerID(2),
        lifecycleRevision: 6,
        userGoal: "Explain the selected function",
        canonicalContext: Data("{\"selection\":\"function\"}".utf8),
        contextDigest: String(repeating: "a", count: 64),
        evidenceIDs: evidenceIDs,
        toolHandles: handles,
        conversationContext: conversationContext,
        shellContinuationCoordinate: coordinate,
        limits: .maximum
    )
}

private func handlerConfiguration(
    manifestDigest: String = Phase2AIWorkerProductionProtocol.manifestDigest
) -> Phase2AIWorkerConfigurationWire {
    .init(
        schemaVersion: Phase2AIWorkerConfigurationWireCodec.schemaVersion,
        profileID: handlerID(30),
        generation: 1,
        endpointOrigin: "http://127.0.0.1:1234",
        model: "model",
        protocolManifestDigest: manifestDigest,
        maximumTokens: 1_024,
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000
    )
}

private func handlerShellProposal() -> Phase2OpenAIShellProposalToolCall {
    .init(
        proposalID: handlerID(70),
        executablePath: "/bin/echo",
        arguments: ["review"],
        environment: [:],
        workingDirectoryPath: nil,
        timeoutMilliseconds: 1_000,
        maximumOutputBytes: 1_024,
        executionSurface: "shellBrokerPTY",
        requestedEffects: ["A5"]
    )
}

private func handlerID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private func handlerFinalizationProposalStream(evidenceID: UUID, debugger: Bool, inlineUsage: Bool = false) throws -> Data {
    let arguments: [String: Any] = debugger ? [
        "action": "stepOver", "session_id": handlerID(70).uuidString,
        "lifecycle_revision": 2, "stop_revision": 1, "event_sequence": 3,
        "requested_authority": "controlledRuntimeActions",
    ] : [
        "executable_path": "/bin/echo", "arguments": ["review"], "environment": [],
        "working_directory_path": "", "timeout_milliseconds": 1_000,
        "maximum_output_bytes": 1_024, "execution_surface": "shellBrokerPTY", "requested_effects": ["A5"],
    ]
    let encodedArguments = String(decoding: try JSONSerialization.data(withJSONObject: arguments,
        options: [.sortedKeys]), as: UTF8.self)
    let final = String(decoding: try JSONSerialization.data(withJSONObject: [
        "kind": "answer", "text": "Grounded.", "evidence_ids": [evidenceID.uuidString], "reason": "",
    ], options: [.sortedKeys]), as: UTF8.self)
    var chunk: [String: Any] = [
        "id": "chat-handler", "object": "chat.completion.chunk", "created": 1, "model": "model",
        "choices": [["index": 0, "finish_reason": "tool_calls", "delta": [
            "content": final, "tool_calls": [["index": 0, "id": "opaque-final-proposal", "type": "function",
                "function": ["name": debugger ? "macscope_stage_debugger_action_proposal_v1" : "macscope_stage_shell_proposal_v1",
                             "arguments": encodedArguments]]],
        ]]],
    ]
    if inlineUsage {
        chunk["usage"] = ["prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10]
    }
    let encodedChunk = String(decoding: try JSONSerialization.data(withJSONObject: chunk,
        options: [.sortedKeys]), as: UTF8.self)
    return Data((handlerSSE(encodedChunk) + (inlineUsage ? "" : handlerSSE(handlerUsageChunk())) + handlerSSE("[DONE]")).utf8)
}
