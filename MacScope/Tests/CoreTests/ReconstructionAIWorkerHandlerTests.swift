import XCTest

@testable import MacScope

final class ReconstructionAIWorkerHandlerTests: XCTestCase {
    func testLegacyNilPolicyCannotDispatchReconstructionProvider() async throws {
        let calls = ReconstructionProviderCallProbe()
        let handler = Phase2ReconstructionAIWorkerHandler(execute: { _, _ in await calls.record() })
        do {
            try await handler.run(requestID: reconstructionHandlerID(90),
                request: .round(handlerRoundRequest()), configuration: handlerConfiguration(inferencePolicy: nil),
                emitControl: { _ in }, emit: { _ in })
            XCTFail("Legacy nil policy must not authorize a provider")
        } catch {
            XCTAssertEqual(error as? Phase2ReconstructionAIWorkerHandlerError, .unsupportedProvider)
        }
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try Phase2ReconstructionOpenAIChatRequestEncoder().encode(
            request: .round(handlerRoundRequest()), configuration: handlerConfiguration(inferencePolicy: nil))) {
            XCTAssertEqual($0 as? Phase2ReconstructionOpenAIChatRequestEncodingError, .unsupportedProvider)
        }
    }

    func testRoundHandlerEmitsCandidateUsageAndCompletionInOrder() async throws {
        let request = handlerRoundRequest()
        let handler = Phase2ReconstructionAIWorkerHandler { input, emit in
            XCTAssertEqual(input.phase, .round)
            XCTAssertTrue(input.systemPrompt.contains("reconstruction.authority.v1"))
            XCTAssertEqual(
                input.offeredHandles.map(\.handleID),
                request.handles.map(\.handleID)
            )
            XCTAssertEqual(
                input.offeredHandles.map { $0.operationID.rawValue },
                request.handles.map { $0.operationID.rawValue }
            )
            await emit(.contentDelta(#"{"job_id":"30000000-0000-4000-8000-000000000001","checkpoint_revision":3,"round_id":"30000000-0000-4000-8000-000000000002","selected_handle_ids":["30000000-0000-4000-8000-000000000010"],"disposition":"continue","unresolved_gaps":[],"resolved_gaps":[]}"#))
            await emit(.usage(.init(promptTokens: 9, completionTokens: 4, totalTokens: 13)))
            await emit(.done)
        }
        let probe = ReconstructionHandlerProbe()
        try await handler.run(
            requestID: reconstructionHandlerID(90), request: .round(request),
            configuration: handlerConfiguration(), emitControl: { _ in },
            emit: { await probe.append($0) }
        )

        let bodies = await probe.events.map(\.body)
        XCTAssertEqual(bodies, [
            .roundCandidate(.init(
                jobID: request.jobID, checkpointRevision: request.checkpointRevision,
                roundID: request.roundID, selectedHandleIDs: [reconstructionHandlerID(10)],
                disposition: .continue, unresolvedGaps: []
            )),
            .usage(.init(promptTokens: 9, completionTokens: 4, totalTokens: 13)),
            .completed,
        ])
    }

    func testFinalSynthesisUsesDistinctNoToolsSchema() async throws {
        let request = handlerFinalRequest()
        let handler = Phase2ReconstructionAIWorkerHandler { input, emit in
            XCTAssertEqual(input.phase, .finalSynthesis)
            XCTAssertTrue(input.offeredHandles.isEmpty)
            XCTAssertTrue(input.systemPrompt.contains("reconstruction.final-synthesis.v1"))
            let body = try? JSONSerialization.jsonObject(with: input.requestBody)
                as? [String: Any]
            XCTAssertNil(body?["tools"])
            await emit(.contentDelta(
                #"{"kind":"synthesis","text":"Grounded result.","evidence_ids":["30000000-0000-4000-8000-000000000020"]}"#
            ))
            await emit(.usage(.init(promptTokens: 3, completionTokens: 2, totalTokens: 5)))
            await emit(.done)
        }
        let probe = ReconstructionHandlerProbe()
        try await handler.run(
            requestID: reconstructionHandlerID(91), request: .finalSynthesis(request),
            configuration: handlerConfiguration(), emitControl: { _ in },
            emit: { await probe.append($0) }
        )
        let emittedBodies = await probe.events.map(\.body)
        XCTAssertEqual(emittedBodies, [
            .finalCandidate(.init(
                kind: .synthesis, text: "Grounded result.",
                evidenceIDs: [reconstructionHandlerID(20)]
            )),
            .usage(.init(promptTokens: 3, completionTokens: 2, totalTokens: 5)),
            .completed,
        ])
    }

    func testHandlerRejectsMismatchedConfigurationBeforeProviderDispatch() async {
        let probe = ReconstructionProviderCallProbe()
        let controlProbe = ReconstructionControlProbe()
        let handler = Phase2ReconstructionAIWorkerHandler { _, _ in await probe.record() }
        do {
            try await handler.run(
                requestID: reconstructionHandlerID(90), request: .round(handlerRoundRequest()),
                configuration: handlerConfiguration(
                    manifestDigest: Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest
                ), emitControl: { await controlProbe.append($0) }, emit: { _ in }
            )
            XCTFail("Expected configuration rejection")
        } catch {}
        let dispatchCount = await probe.count
        XCTAssertEqual(dispatchCount, 0)
        let controls = await controlProbe.events
        XCTAssertTrue(controls.isEmpty)
    }

    func testHandlerRejectsUnknownProviderOutputKeysWithoutPublishingEvents() async {
        let handler = Phase2ReconstructionAIWorkerHandler { _, emit in
            await emit(.contentDelta(#"{"job_id":"30000000-0000-4000-8000-000000000001","checkpoint_revision":3,"round_id":"30000000-0000-4000-8000-000000000002","selected_handle_ids":[],"disposition":"sufficientEvidence","unresolved_gaps":[],"path":"/private/tmp/leak"}"#))
            await emit(.usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)))
            await emit(.done)
        }
        let probe = ReconstructionHandlerProbe()
        do {
            try await handler.run(
                requestID: reconstructionHandlerID(90),
                request: .round(handlerRoundRequest()),
                configuration: handlerConfiguration(),
                emitControl: { _ in },
                emit: { await probe.append($0) }
            )
            XCTFail("Expected strict provider-output rejection")
        } catch {}
        let events = await probe.events
        XCTAssertTrue(events.isEmpty)
    }

    func testHandlerRejectsOverflowingProviderUsageWithoutPublishingEvents() async {
        let handler = Phase2ReconstructionAIWorkerHandler { _, emit in
            await emit(.contentDelta(#"{"job_id":"30000000-0000-4000-8000-000000000001","checkpoint_revision":3,"round_id":"30000000-0000-4000-8000-000000000002","selected_handle_ids":[],"disposition":"sufficientEvidence","unresolved_gaps":[],"resolved_gaps":[]}"#))
            await emit(.usage(.init(
                promptTokens: Int.max,
                completionTokens: 1,
                totalTokens: Int.max
            )))
            await emit(.done)
        }
        let probe = ReconstructionHandlerProbe()
        do {
            try await handler.run(
                requestID: reconstructionHandlerID(90),
                request: .round(handlerRoundRequest()),
                configuration: handlerConfiguration(),
                emitControl: { _ in },
                emit: { await probe.append($0) }
            )
            XCTFail("Expected overflowing usage rejection")
        } catch {
            XCTAssertEqual(
                error as? Phase2ReconstructionRoundAccumulatorError,
                .invalidSequence
            )
        }
        let events = await probe.events
        XCTAssertTrue(events.isEmpty)
    }

    func testLiveHandlerRejectsNonLoopbackConnectionReceiptBeforeCompletion() async {
        await assertLiveHandlerRejectsConnectionReceipt(.init(
            localAddress: "192.0.2.10",
            localPort: 50_000,
            remoteAddress: "127.0.0.1",
            remotePort: 1_234
        ))
    }

    func testLiveHandlerRejectsWrongRemotePortConnectionReceiptBeforeCompletion() async {
        await assertLiveHandlerRejectsConnectionReceipt(.init(
            localAddress: "127.0.0.1",
            localPort: 50_000,
            remoteAddress: "127.0.0.1",
            remotePort: 1_235
        ))
    }

    func testLiveHandlerRejectsWrongContentTypeBeforePublishingEvents() async {
        await assertLiveHandlerRejectsProviderResponse(
            reconstructionProviderResponse(contentType: "text/plain")
        )
    }

    func testLiveHandlerReportsProviderRefusalWithoutMalformedOutputOrSemanticEvents() async {
        let body = #"data: {"error":{"message":"BEARER_SECRET /Users/private/context","type":"memory_refusal","code":507},"choices":[{"index":0,"delta":{},"finish_reason":"error"}]}"#
            + "\n\ndata: [DONE]\n\n"
        await assertLiveHandlerRejectsProviderResponse(
            reconstructionProviderResponse(body: Data(body.utf8)),
            expectedError: .providerFailure
        )
    }

    func testLiveHandlerRejectsResponseFromAnotherModelBeforePublishingEvents() async {
        await assertLiveHandlerRejectsProviderResponse(
            reconstructionProviderResponse(model: "other-model")
        )
    }

    func testLiveHandlerAcceptsOptionalProviderMetadataWithoutRelaxingCandidateSchema() async throws {
        let handler = Phase2ReconstructionAIWorkerHandler(load: { request in
            reconstructionProviderResponse(finalURL: request.url,
                extraRootMember: ("system_fingerprint", "local"),
                extraUsageMember: ("prompt_tokens_details", ["cached_tokens": 0]))
        })
        let probe = ReconstructionHandlerProbe()
        try await handler.run(requestID: reconstructionHandlerID(93), request: .round(handlerRoundRequest()),
            configuration: handlerConfiguration(), emitControl: { _ in },
            emit: { await probe.append($0) })
        let events = await probe.events
        XCTAssertEqual(events.count, 3)
    }

    func testLiveHandlerRejectsOversizedStreamBeforePublishingEvents() async {
        await assertLiveHandlerRejectsProviderResponse(
            reconstructionProviderResponse(candidate: String(repeating: "x", count: 65_537))
        )
    }

    func testLiveHandlerEmitsExactProviderControlsForRoundAndFinalRequests() async throws {
        let cases: [(ReconstructionAIWorkerRequest, String)] = [
            (.round(handlerRoundRequest()), reconstructionRoundProviderCandidate()),
            (.finalSynthesis(handlerFinalRequest()), reconstructionFinalProviderCandidate()),
        ]
        for (offset, testCase) in cases.enumerated() {
            let requestID = reconstructionHandlerID(94 + offset)
            let handler = Phase2ReconstructionAIWorkerHandler(load: { request in
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(object["stream"] as? Bool, true)
                XCTAssertEqual((object["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
                XCTAssertEqual(object["generation_mode"] as? String, "mtp")
                XCTAssertNil(object["enable_thinking"], "MTPLX applies the model's own thinking setting")
                // A cold first token may use the whole resource ceiling (1fbba3c3f).
                XCTAssertEqual(request.timeoutInterval, 1_800)
                return reconstructionProviderResponse(finalURL: request.url, candidate: testCase.1)
            })
            let controlProbe = ReconstructionControlProbe()
            let eventProbe = ReconstructionHandlerProbe()
            let timeline = ReconstructionEmissionTimeline()
            try await handler.run(
                requestID: requestID,
                request: testCase.0,
                configuration: handlerConfiguration(),
                emitControl: {
                    await controlProbe.append($0)
                    await timeline.append(.control($0.body))
                },
                emit: {
                    await eventProbe.append($0)
                    await timeline.append(.semantic($0.body))
                }
            )

            let controls = await controlProbe.events
            XCTAssertEqual(controls.count, 2)
            guard controls.count == 2 else { continue }
            try assertExactReconstructionControl(
                controls[0],
                requestID: requestID,
                expectedBody: .providerDispatch,
                expectedSequence: UInt64.max - 1
            )
            try assertExactReconstructionControl(
                controls[1],
                requestID: requestID,
                expectedBody: .providerConnection(.init(
                    localAddress: "127.0.0.1",
                    localPort: 50_000,
                    remoteAddress: "127.0.0.1",
                    remotePort: 1_234
                )),
                expectedSequence: UInt64.max
            )
            let events = await eventProbe.events
            XCTAssertEqual(events.count, 3)
            let ordered = await timeline.events
            XCTAssertEqual(Array(ordered.prefix(2)), [
                .control(.providerDispatch),
                .control(.providerConnection(.init(
                    localAddress: "127.0.0.1",
                    localPort: 50_000,
                    remoteAddress: "127.0.0.1",
                    remotePort: 1_234
                ))),
            ])
            XCTAssertEqual(ordered.count, 5)
        }
    }

    func testLiveHandlerPropagatesWrongRequestAndControlRejectionBeforeSemanticEvents() async {
        for mutation in ReconstructionControlMutation.allCases {
            let requestID = reconstructionHandlerID(97 + mutation.rawValue)
            let handler = Phase2ReconstructionAIWorkerHandler(load: { request in
                reconstructionProviderResponse(finalURL: request.url)
            })
            let eventProbe = ReconstructionHandlerProbe()
            do {
                try await handler.run(
                    requestID: requestID,
                    request: .round(handlerRoundRequest()),
                    configuration: handlerConfiguration(),
                    emitControl: { event in
                        let mutated = mutateReconstructionControl(event, mutation: mutation)
                        try assertExactReconstructionControl(
                            mutated,
                            requestID: requestID,
                            expectedBody: .providerDispatch,
                            expectedSequence: UInt64.max - 1
                        )
                    },
                    emit: { await eventProbe.append($0) }
                )
                XCTFail("Expected mutated control rejection")
            } catch {
                XCTAssertTrue(error is ReconstructionControlValidationError)
            }
            let events = await eventProbe.events
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testMTPLXReconstructionStreamsReasoningSeparatelyThroughExistingSchemaValidation() async throws {
        let cases: [(ReconstructionAIWorkerRequest, String)] = [
            (.round(handlerRoundRequest()), reconstructionRoundProviderCandidate()),
            (.finalSynthesis(handlerFinalRequest()), reconstructionFinalProviderCandidate())
        ]
        for testCase in cases {
            let handler = Phase2ReconstructionAIWorkerHandler(load: { request in
                let body = try XCTUnwrap(request.httpBody)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(object["stream"] as? Bool, true)
                XCTAssertEqual(object["max_tokens"] as? Int, 16_384)
                XCTAssertNil(object["enable_thinking"], "MTPLX applies the model's own thinking setting")
                XCTAssertNil(object["reasoning_effort"], "MTPLX applies the model's own reasoning effort")
                XCTAssertNil(object["depth"], "MTPLX applies its own MTP depth")
                XCTAssertNil(object["temperature"])
                XCTAssertNotNil(object["response_format"])
                // A cold first token may use the whole resource ceiling (1fbba3c3f).
                XCTAssertEqual(request.timeoutInterval, 1_800)
                return try reconstructionMTPLXStreamResponse(url: request.url, candidate: testCase.1, inlineUsage: true)
            })
            let probe = ReconstructionHandlerProbe()
            try await handler.run(requestID: reconstructionHandlerID(991), request: testCase.0,
                configuration: handlerConfiguration(inferencePolicy: .init()),
                emitControl: { _ in }, emit: { await probe.append($0) })
            let events = await probe.events
            XCTAssertEqual(events.count, 3)
            XCTAssertFalse(String(describing: events).contains("private reasoning"))
        }
    }

    func testMTPLXReconstructionLengthTerminationCannotPublishCompletedSchema() async throws {
        let handler = Phase2ReconstructionAIWorkerHandler(load: { request in
            try reconstructionMTPLXStreamResponse(url: request.url,
                candidate: reconstructionRoundProviderCandidate(), finishReason: "length")
        })
        let probe = ReconstructionHandlerProbe()
        do {
            try await handler.run(requestID: reconstructionHandlerID(992), request: .round(handlerRoundRequest()),
                configuration: handlerConfiguration(inferencePolicy: .init()),
                emitControl: { _ in }, emit: { await probe.append($0) })
            XCTFail("Length termination must remain incomplete, even with plausible JSON")
        } catch {
            XCTAssertEqual(error as? Phase2OpenAIChatHTTPClientError, .outputLimitExceeded)
        }
        let events = await probe.events
        XCTAssertTrue(events.isEmpty)
    }

    func testMTPLXReconstructionStillRejectsInvalidFinalSchemaAfterCleanStream() async throws {
        let handler = Phase2ReconstructionAIWorkerHandler(load: { request in
            try reconstructionMTPLXStreamResponse(url: request.url, candidate: "{}")
        })
        let probe = ReconstructionHandlerProbe()
        do {
            try await handler.run(requestID: reconstructionHandlerID(993), request: .round(handlerRoundRequest()),
                configuration: handlerConfiguration(inferencePolicy: .init()),
                emitControl: { _ in }, emit: { await probe.append($0) })
            XCTFail("Clean transport must not bypass the reconstruction schema")
        } catch { }
        let events = await probe.events
        XCTAssertTrue(events.isEmpty)
    }

    private func assertLiveHandlerRejectsProviderResponse(
        _ response: Phase2OpenAIChatHTTPResponse,
        expectedError: Phase2ReconstructionAIWorkerHandlerError? = .malformedProviderResponse
    ) async {
        let handler = Phase2ReconstructionAIWorkerHandler(load: { _ in response })
        let probe = ReconstructionHandlerProbe()
        do {
            try await handler.run(
                requestID: reconstructionHandlerID(93),
                request: .round(handlerRoundRequest()),
                configuration: handlerConfiguration(),
                emitControl: { _ in },
                emit: { await probe.append($0) }
            )
            XCTFail("Expected provider response rejection")
        } catch {
            if let expectedError {
                XCTAssertEqual(error as? Phase2ReconstructionAIWorkerHandlerError, expectedError)
            } else {
                XCTAssertEqual(
                    error as? Phase2ReconstructionRoundAccumulatorError,
                    .outputTooLarge
                )
            }
        }
        let events = await probe.events
        XCTAssertTrue(events.isEmpty)
    }

    private func assertLiveHandlerRejectsConnectionReceipt(
        _ receipt: Phase2OpenAIChatConnectionReceipt
    ) async {
        let handler = Phase2ReconstructionAIWorkerHandler(load: { request in
            reconstructionProviderResponse(finalURL: request.url, receipt: receipt)
        })
        let probe = ReconstructionHandlerProbe()
        do {
            try await handler.run(
                requestID: reconstructionHandlerID(92),
                request: .round(handlerRoundRequest()),
                configuration: handlerConfiguration(),
                emitControl: { _ in },
                emit: { await probe.append($0) }
            )
            XCTFail("Expected the physical provider connection to be rejected")
        } catch {
            XCTAssertEqual(
                error as? Phase2ReconstructionAIWorkerHandlerError,
                .providerFailure
            )
        }
        let events = await probe.events
        XCTAssertTrue(events.isEmpty)
    }
}

private actor ReconstructionHandlerProbe {
    private(set) var events: [ReconstructionAIWorkerEvent] = []
    func append(_ event: ReconstructionAIWorkerEvent) { events.append(event) }
}

private actor ReconstructionProviderCallProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor ReconstructionControlProbe {
    private(set) var events: [Phase2AIWorkerWireEvent] = []
    func append(_ event: Phase2AIWorkerWireEvent) { events.append(event) }
}

private enum ReconstructionEmission: Equatable {
    case control(Phase2AIWorkerWireEventBody)
    case semantic(ReconstructionAIWorkerEventBody)
}

private actor ReconstructionEmissionTimeline {
    private(set) var events: [ReconstructionEmission] = []
    func append(_ event: ReconstructionEmission) { events.append(event) }
}

private enum ReconstructionControlMutation: Int, CaseIterable {
    case wrongRequest
    case wrongControl
}

private enum ReconstructionControlValidationError: Error {
    case rejected
}

private func assertExactReconstructionControl(
    _ event: Phase2AIWorkerWireEvent,
    requestID: UUID,
    expectedBody: Phase2AIWorkerWireEventBody,
    expectedSequence: UInt64
) throws {
    let bundle = Phase2AIWorkerProductionProtocol.reconstructionR1
    guard event.wireProtocol == bundle.wireIdentity,
          event.protocolVersion == bundle.inferenceVersion,
          event.phase == .finalization,
          event.requestID == requestID,
          event.sequence == expectedSequence,
          event.body == expectedBody
    else { throw ReconstructionControlValidationError.rejected }
    let encoded = try Phase2AIWorkerWireCodec().encodeEvent(event)
    switch try Phase2AIWorkerAppCodec().decodeWorkerEvent(encoded) {
    case .providerDispatch(let decodedRequestID, let phase):
        guard case .providerDispatch = expectedBody,
              decodedRequestID == requestID,
              phase == .finalization
        else { throw ReconstructionControlValidationError.rejected }
    case .providerConnection(let decodedRequestID, let phase, let receipt):
        guard case .providerConnection(let expectedReceipt) = expectedBody,
              decodedRequestID == requestID,
              phase == .finalization,
              receipt.localAddress == expectedReceipt.localAddress,
              Int(receipt.localPort) == expectedReceipt.localPort,
              receipt.remoteAddress == expectedReceipt.remoteAddress,
              Int(receipt.remotePort) == expectedReceipt.remotePort
        else { throw ReconstructionControlValidationError.rejected }
    case .inference:
        throw ReconstructionControlValidationError.rejected
    }
}

private func mutateReconstructionControl(
    _ event: Phase2AIWorkerWireEvent,
    mutation: ReconstructionControlMutation
) -> Phase2AIWorkerWireEvent {
    .init(
        wireProtocol: event.wireProtocol,
        protocolVersion: event.protocolVersion,
        phase: event.phase,
        sessionID: event.sessionID,
        turnID: event.turnID,
        requestID: mutation == .wrongRequest ? reconstructionHandlerID(999) : event.requestID,
        documentID: event.documentID,
        workspaceID: event.workspaceID,
        lifecycleRevision: event.lifecycleRevision,
        sequence: event.sequence,
        body: mutation == .wrongControl ? .completed : event.body
    )
}

private func handlerRoundRequest() -> ReconstructionInferenceRoundRequest {
    .init(
        protocolVersion: 8, jobID: reconstructionHandlerID(1), checkpointRevision: 3,
        roundID: reconstructionHandlerID(2), corpusManifestSHA256: handlerDigest(1),
        evidenceFrontierSHA256: handlerDigest(2),
        registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
        context: .init(canonicalBytes: Data(#"{"records":[]}"#.utf8), canonicalSHA256: "1b8b4c0b6f6ad1d32565952720bc004eeb1f188f62045e4d5525ae2af8c78432", evidenceIDs: [], allowedGapSubjects: [], allowedGapCategories: [], allowedGapIDs: []),
        handles: [.init(handleID: reconstructionHandlerID(10), operationID: .corpusSummary)]
    )
}

private func handlerFinalRequest() -> ReconstructionFinalSynthesisRequest {
    .init(
        jobID: reconstructionHandlerID(1), checkpointRevision: 3,
        corpusManifestSHA256: handlerDigest(1), evidenceFrontierSHA256: handlerDigest(2),
        acceptedEvidenceIDs: [reconstructionHandlerID(20)],
        context: .init(canonicalBytes: Data(#"{"records":[]}"#.utf8), canonicalSHA256: "1b8b4c0b6f6ad1d32565952720bc004eeb1f188f62045e4d5525ae2af8c78432", evidenceIDs: [reconstructionHandlerID(20)], allowedGapSubjects: [], allowedGapCategories: [])
    )
}

private func handlerConfiguration(
    manifestDigest: String = Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest,
    inferencePolicy: Phase2LocalInferencePolicy? = .init()
) -> Phase2AIWorkerConfigurationWire {
    .init(
        schemaVersion: 1, profileID: reconstructionHandlerID(80), generation: 1,
        endpointOrigin: "http://127.0.0.1:1234", model: "local-model",
        protocolManifestDigest: manifestDigest, maximumTokens: inferencePolicy == nil ? 1_024 : 16_384,
        requestTimeoutMilliseconds: inferencePolicy == nil ? 10_000 : 300_000,
        resourceTimeoutMilliseconds: inferencePolicy == nil ? 60_000 : 1_800_000,
        inferencePolicy: inferencePolicy
    )
}

private func reconstructionHandlerID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "30000000-0000-4000-8000-%012d", value))!
}

private func handlerDigest(_ value: Int) -> String { String(format: "%064x", value) }

private func reconstructionProviderResponse(
    finalURL: URL? = URL(string: "http://127.0.0.1:1234/v1/chat/completions"),
    receipt: Phase2OpenAIChatConnectionReceipt = .init(
        localAddress: "127.0.0.1",
        localPort: 50_000,
        remoteAddress: "127.0.0.1",
        remotePort: 1_234
    ),
    contentType: String = "text/event-stream",
    model: String = "local-model",
    extraRootMember: (String, Any)? = nil,
    extraUsageMember: (String, Any)? = nil,
    candidate explicitCandidate: String? = nil,
    body explicitBody: Data? = nil
) -> Phase2OpenAIChatHTTPResponse {
    let candidate = explicitCandidate ?? reconstructionRoundProviderCandidate()
    var usage: [String: Any] = [
        "prompt_tokens": 1,
        "completion_tokens": 1,
        "total_tokens": 2,
    ]
    if let extraUsageMember { usage[extraUsageMember.0] = extraUsageMember.1 }
    func frame(choices: [[String: Any]], usage: [String: Any]? = nil) -> Data {
        var object: [String: Any] = [
            "id": "reconstruction-test", "object": "chat.completion.chunk", "created": 1,
            "model": model, "choices": choices,
        ]
        if let usage { object["usage"] = usage }
        if let extraRootMember { object[extraRootMember.0] = extraRootMember.1 }
        return Data("data: ".utf8) + (try! JSONSerialization.data(withJSONObject: object))
            + Data("\n\n".utf8)
    }
    var stream = frame(choices: [["index": 0, "delta": ["role": "assistant"], "finish_reason": NSNull()]])
    stream.append(frame(choices: [["index": 0, "delta": ["content": candidate], "finish_reason": NSNull()]]))
    stream.append(frame(choices: [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]]))
    stream.append(frame(choices: [], usage: usage))
    stream.append(Data("data: [DONE]\n\n".utf8))
    let body = explicitBody ?? stream
    return .init(
        statusCode: 200,
        contentType: contentType,
        finalURL: finalURL,
        body: AsyncThrowingStream { continuation in
            continuation.yield(body)
            continuation.finish()
        },
        connectionReceipt: { receipt }
    )
}

private func reconstructionRoundProviderCandidate() -> String {
    #"{"job_id":"30000000-0000-4000-8000-000000000001","checkpoint_revision":3,"round_id":"30000000-0000-4000-8000-000000000002","selected_handle_ids":[],"disposition":"sufficientEvidence","unresolved_gaps":[],"resolved_gaps":[]}"#
}

private func reconstructionFinalProviderCandidate() -> String {
    #"{"kind":"synthesis","text":"Grounded result.","evidence_ids":["30000000-0000-4000-8000-000000000020"]}"#
}

private func reconstructionMTPLXStreamResponse(url: URL?, candidate: String,
                                               finishReason: String = "stop", inlineUsage: Bool = false) throws -> Phase2OpenAIChatHTTPResponse {
    func frame(delta: [String: Any], reason: Any = NSNull()) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": "reconstruction-stream", "object": "chat.completion.chunk", "created": 1,
            "model": "local-model", "choices": [["index": 0, "delta": delta, "finish_reason": reason]]
        ])
        return Data("data: ".utf8) + data + Data("\n\n".utf8)
    }
    var data = try frame(delta: ["role": "assistant", "reasoning_content": "private reasoning λ"])
    data.append(try frame(delta: ["content": candidate]))
    if !inlineUsage { data.append(try frame(delta: [:], reason: finishReason)) }
    let terminalChoices: [[String: Any]] = inlineUsage
        ? [["index": 0, "delta": [String: Any](), "finish_reason": finishReason]] : []
    let usage = try JSONSerialization.data(withJSONObject: [
        "id": "reconstruction-stream", "object": "chat.completion.chunk", "created": 1,
        "model": "local-model", "choices": terminalChoices,
        "usage": ["prompt_tokens": 100, "completion_tokens": 200, "total_tokens": 300],
        "mtplx_stats": ["diagnostic_notes": String(repeating: "x", count: 20_000)]
    ])
    data.append(Data("data: ".utf8) + usage + Data("\n\ndata: [DONE]\n\n".utf8))
    let chunks = stride(from: 0, to: data.count, by: 13).map {
        data.subdata(in: $0..<min($0 + 13, data.count))
    }
    return .init(statusCode: 200, contentType: "text/event-stream", finalURL: url,
        body: AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }, connectionReceipt: { .init(localAddress: "127.0.0.1", localPort: 50_000,
                                      remoteAddress: "127.0.0.1", remotePort: 1_234) })
}
