import XCTest

@testable import MacScope

final class Phase2AIWorkerWireTests: XCTestCase {
    func testREAReadHandlesAndProposalPairsRoundTripOverR2Wire() throws {
        let codec = Phase2AIWorkerWireCodec()
        let operations = ["rea.results.list", "rea.results.get", "rea.results.get"]
        let request = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR2.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion,
            phase: .toolSelection,
            handles: operations.enumerated().map {
                .init(handleID: aiWorkerID(40 + $0.offset), operationID: $0.element)
            }
        )
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(request)), request)
        for (index, operation) in operations.enumerated() {
            let function = operation == "rea.results.list"
                ? "macscope_rea_results_list_v1" : "macscope_rea_results_get_v1"
            let event = aiWorkerWireEvent(request: request, body: .toolProposal(
                callID: "rea-\(index)", handleID: aiWorkerID(40 + index),
                functionName: function, operationID: operation))
            XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(event)), event)
        }
        for (function, operation) in [
            ("macscope_rea_results_list_v1", "rea.results.get"),
            ("macscope_rea_results_get_v1", "rea.results.unknown"),
        ] {
            XCTAssertThrowsError(try codec.encodeEvent(aiWorkerWireEvent(
                request: request, body: .toolProposal(callID: "invalid",
                    handleID: aiWorkerID(40), functionName: function, operationID: operation))))
        }
        let legacy = aiWorkerWireRequest(phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(40), operationID: "rea.results.list")])
        XCTAssertThrowsError(try codec.encodeRequest(legacy))
    }

    func testInferenceActivitySpansBlockedRequestsAndEndsAfterTerminalQueueing() async throws {
        let activity = Phase2InferenceActivityProbe()
        let handler = Phase2BlockingInferenceHandler()
        let principal = Phase2AIWorkerPrincipal(handler: handler,
            beginInferenceActivity: { activity.begin() }, endInferenceActivity: { activity.end() })
        try await configureActivityPrincipal(principal)
        let request = aiWorkerWireRequest()
        let data = try Phase2AIWorkerWireCodec().encodeRequest(request)
        let malformedSink = Phase2WirePrincipalSinkProbe()
        principal.run(requestData: Data("{}".utf8), requestID: request.requestID,
            eventSink: malformedSink)
        _ = await malformedSink.terminal()
        XCTAssertEqual(activity.counts.begun, 0)
        XCTAssertEqual(activity.counts.ended, 0)
        for ordinal in 1...2 {
            let sink = Phase2WirePrincipalSinkProbe(terminalObserver: {
                XCTAssertEqual(activity.counts.ended, ordinal - 1,
                    "The request activity must outlive terminal queueing")
            })
            principal.run(requestData: data, requestID: request.requestID, eventSink: sink)
            await handler.waitUntilRunning()
            XCTAssertEqual(activity.counts.begun, ordinal)
            XCTAssertEqual(activity.counts.ended, ordinal - 1)
            let duplicate = Phase2WirePrincipalSinkProbe()
            principal.run(requestData: data, requestID: request.requestID, eventSink: duplicate)
            let duplicateTerminal = try Phase2AIWorkerWireCodec().decodeTerminal(await duplicate.terminal())
            XCTAssertEqual(duplicateTerminal.reason, .duplicateRequest)
            XCTAssertEqual(activity.counts.begun, ordinal)
            await handler.release(failing: ordinal == 2)
            let terminal = try Phase2AIWorkerWireCodec().decodeTerminal(await sink.terminal())
            XCTAssertEqual(terminal.status, ordinal == 1 ? .completed : .failed)
            await activity.waitForEnds(ordinal)
            XCTAssertEqual(activity.counts.ended, ordinal)
        }
    }

    func testInferenceActivityCancellationAndInvalidationEndExactlyOnce() async throws {
        for invalidate in [false, true] {
            let activity = Phase2InferenceActivityProbe()
            let handler = Phase2BlockingInferenceHandler()
            let principal = Phase2AIWorkerPrincipal(handler: handler,
                beginInferenceActivity: { activity.begin() }, endInferenceActivity: { activity.end() })
            try await configureActivityPrincipal(principal)
            let request = aiWorkerWireRequest()
            let data = try Phase2AIWorkerWireCodec().encodeRequest(request)
            let sink = Phase2WirePrincipalSinkProbe()
            principal.run(requestData: data, requestID: request.requestID, eventSink: sink)
            await handler.waitUntilRunning()
            XCTAssertEqual(activity.counts.ended, 0)
            if invalidate { principal.cancelAllForConnectionInvalidation() }
            else { principal.cancel(requestID: request.requestID) }
            XCTAssertEqual(activity.counts.ended, 1)
            principal.cancel(requestID: request.requestID)
            principal.cancelAllForConnectionInvalidation()
            XCTAssertEqual(activity.counts.ended, 1)
            let rejected = Phase2WirePrincipalSinkProbe()
            principal.run(requestData: data, requestID: request.requestID, eventSink: rejected)
            _ = await rejected.terminal()
            await handler.release(failing: false)
            XCTAssertEqual(activity.counts.begun, 1)
        }
    }

    func testInferenceActivityDeinitBalancesLeaseAndExplicitFinishIsOneShot() {
        let activity = Phase2InferenceActivityProbe()
        var lease: Phase2InferenceXPCActivity? = .init(begin: { activity.begin() }, end: { activity.end() })
        XCTAssertEqual(activity.counts.ended, 0)
        lease?.finish()
        lease?.finish()
        lease = nil
        XCTAssertEqual(activity.counts.ended, 1)
        lease = .init(begin: { activity.begin() }, end: { activity.end() })
        lease = nil
        XCTAssertEqual(activity.counts.begun, 2)
        XCTAssertEqual(activity.counts.ended, 2)
    }

    private func configureActivityPrincipal(_ principal: Phase2AIWorkerPrincipal) async throws {
        let configuration = Phase2AIWorkerConfigurationWire(schemaVersion: 1,
            profileID: aiWorkerID(30), generation: 1, endpointOrigin: "http://127.0.0.1:1234",
            model: "model", protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest,
            maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000, inferencePolicy: .init())
        let data = try Phase2AIWorkerConfigurationWireCodec().encodeConfiguration(configuration)
        let reply: Data = await withCheckedContinuation { continuation in
            principal.configure(configurationData: data) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(try Phase2AIWorkerConfigurationWireCodec().decodeAcknowledgement(reply).status, .accepted)
    }

    func testLegacyNilPolicyConfigurationDecodesButCannotAcquireProductionAuthority() async throws {
        let principal = Phase2AIWorkerPrincipal(handler: Phase2WirePrincipalHandlerProbe())
        let legacy = Phase2AIWorkerConfigurationWire(
            schemaVersion: 1, profileID: aiWorkerID(30), generation: 1,
            endpointOrigin: "http://127.0.0.1:1234", model: "legacy-model",
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest,
            maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let codec = Phase2AIWorkerConfigurationWireCodec()
        let data = try codec.encodeConfiguration(legacy)
        XCTAssertNil(try codec.decodeConfiguration(data).inferencePolicy)
        let reply: Data = await withCheckedContinuation { continuation in
            principal.configure(configurationData: data) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(try codec.decodeAcknowledgement(reply).status, .rejected)
    }

    func testAssistantR4ShellContinuationRoundTripsExactCoordinateWithoutTools() throws {
        let appCoordinate = try XCTUnwrap(Phase2AssistantShellContinuationCoordinate(
            workspaceID: aiWorkerID(2),
            workspaceDocumentIdentityDigest: String(repeating: "d", count: 64),
            conversationID: aiWorkerID(3),
            inferenceTurnID: aiWorkerID(4),
            turnSequence: 7,
            originatingFinalizationRequestID: aiWorkerID(40),
            shellProposalID: aiWorkerID(41),
            shellExecutionID: aiWorkerID(42),
            runtimeAuthorityRecordID: aiWorkerID(43),
            shellProposalDigest: String(repeating: "a", count: 64),
            shellExecutionResultDigest: String(repeating: "b", count: 64),
            runtimeAuthorityRecordDigest: String(repeating: "c", count: 64),
            productionManifestIdentity: Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
            providerRevision: 9,
            continuationOrdinal: 1,
            continuationRequestID: aiWorkerID(5)
        ))
        let coordinate = Phase2AIWorkerWireShellContinuationCoordinate(appCoordinate)
        let request = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion,
            phase: .shellContinuation,
            conversationContext: .init(turns: [], omittedTurnCount: 0),
            shellContinuationCoordinate: coordinate
        )

        let codec = Phase2AIWorkerWireCodec()
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(request)), request)
        XCTAssertEqual(request.requestID, coordinate.continuationRequestID)
        XCTAssertEqual(coordinate.appCoordinate(), appCoordinate)
        XCTAssertTrue(request.toolHandles.isEmpty)
    }

    func testAssistantR4ShellContinuationRejectsCoordinateMutationAndTools() throws {
        let valid = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion,
            phase: .shellContinuation,
            conversationContext: .init(turns: [], omittedTurnCount: 0),
            shellContinuationCoordinate: aiWorkerWireContinuationCoordinate()
        )
        XCTAssertNoThrow(try Phase2AIWorkerWireCodec().encodeRequest(valid))

        let withTools = aiWorkerWireRequest(
            wireProtocol: valid.wireProtocol,
            protocolVersion: valid.protocolVersion,
            phase: .shellContinuation,
            handles: [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")],
            conversationContext: valid.conversationContext,
            shellContinuationCoordinate: valid.shellContinuationCoordinate
        )
        XCTAssertThrowsError(try Phase2AIWorkerWireCodec().encodeRequest(withTools))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        var coordinate = try XCTUnwrap(object["shellContinuationCoordinate"] as? [String: Any])
        coordinate["continuationOrdinal"] = 2
        object["shellContinuationCoordinate"] = coordinate
        XCTAssertThrowsError(try Phase2AIWorkerWireCodec().decodeRequest(
            JSONSerialization.data(withJSONObject: object)
        ))

        var integrityMutation = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        var mutatedCoordinate = try XCTUnwrap(
            integrityMutation["shellContinuationCoordinate"] as? [String: Any]
        )
        mutatedCoordinate["shellExecutionID"] = UUID().uuidString
        integrityMutation["shellContinuationCoordinate"] = mutatedCoordinate
        XCTAssertThrowsError(try Phase2AIWorkerWireCodec().decodeRequest(
            JSONSerialization.data(withJSONObject: integrityMutation)
        ))
    }

    func testAssistantR4ShellContinuationFinalCandidateReusesFinalizationLimits() throws {
        let request = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion,
            phase: .shellContinuation,
            conversationContext: .init(turns: [], omittedTurnCount: 0),
            shellContinuationCoordinate: aiWorkerWireContinuationCoordinate()
        )
        XCTAssertThrowsError(try Phase2AIWorkerWireCodec().encodeEvent(aiWorkerWireEvent(
            request: request,
            body: .finalCandidate(
                kind: .insufficientEvidence,
                text: String(repeating: "x", count: 4_097),
                evidenceIDs: []
            )
        )))
        XCTAssertThrowsError(try Phase2AIWorkerWireCodec().encodeEvent(aiWorkerWireEvent(
            request: request,
            body: .finalCandidate(
                kind: .answer,
                text: "answer",
                evidenceIDs: [aiWorkerID(61), aiWorkerID(62), aiWorkerID(63), aiWorkerID(64)]
            )
        )))
    }

    func testMutualPeerRequirementsPinIdentifiersAndApprovedCertificateChain() {
        XCTAssertEqual(
            Phase2AIWorkerPeerRequirement.app,
            "identifier \"org.macscope.app\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: MacScope Developer (CERT000000)\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        )
        XCTAssertEqual(
            Phase2AIWorkerPeerRequirement.worker,
            "identifier \"org.macscope.app.AIAgentWorker\" and anchor apple generic and certificate leaf[subject.CN] = \"Apple Development: MacScope Developer (CERT000000)\" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"
        )
    }

    func testHandshakeNegotiatesExactWireInferenceAndManifestIdentities() throws {
        let handshake = Phase2AIWorkerHandshake(
            wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
            inferenceProtocol: Phase2AIWorkerProductionProtocol.inferenceIdentity,
            manifestIdentity: Phase2AIWorkerProductionProtocol.manifestIdentity,
            status: .ready
        )

        XCTAssertEqual(
            try Phase2AIWorkerWireCodec().decodeHandshake(
                Phase2AIWorkerWireCodec().encodeHandshake(handshake)
            ),
            handshake
        )
        XCTAssertEqual(
            handshake.manifestIdentity,
            "sha256:\(Phase2AIWorkerProductionProtocol.manifestDigest)"
        )
    }

    func testPrincipalRejectsDriftedManifestConfigurationWithoutClaimingConnection() async throws {
        let principal = Phase2AIWorkerPrincipal(handler: Phase2WirePrincipalHandlerProbe())
        let valid = Phase2AIWorkerConfigurationWire(
            schemaVersion: Phase2AIWorkerConfigurationWireCodec.schemaVersion,
            profileID: aiWorkerID(31),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "model",
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest,
            maximumTokens: 1_024,
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000, inferencePolicy: .init()
        )
        let codec = Phase2AIWorkerConfigurationWireCodec()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: codec.encodeConfiguration(valid))
                as? [String: Any]
        )
        object["protocolManifestDigest"] = String(repeating: "0", count: 64)
        let drifted = try JSONSerialization.data(withJSONObject: object)

        let rejected: Data = await withCheckedContinuation { continuation in
            principal.configure(configurationData: drifted) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(rejected.isEmpty)

        let accepted: Data = await withCheckedContinuation { continuation in
            principal.configure(configurationData: try! codec.encodeConfiguration(valid)) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(try codec.decodeAcknowledgement(accepted).status, .accepted)
    }

    func testPrincipalPublishesExactHandshakeAndRejectsMalformedPhaseBeforeHandler() async throws {
        let handler = Phase2WirePrincipalHandlerProbe()
        let principal = Phase2AIWorkerPrincipal(handler: handler)
        let handshakeData: Data = await withCheckedContinuation { continuation in
            principal.handshake { continuation.resume(returning: $0) }
        }
        let handshake = try Phase2AIWorkerWireCodec().decodeHandshake(handshakeData)
        XCTAssertEqual(
            handshake.wireProtocol,
            Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity
        )
        XCTAssertEqual(
            handshake.manifestIdentity,
            Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity
        )

        let configuration = Phase2AIWorkerConfigurationWire(
            schemaVersion: Phase2AIWorkerConfigurationWireCodec.schemaVersion,
            profileID: aiWorkerID(30),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "model",
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.assistantR4.manifestDigest,
            maximumTokens: 1_024,
            requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000, inferencePolicy: .init()
        )
        let configurationData = try Phase2AIWorkerConfigurationWireCodec()
            .encodeConfiguration(configuration)
        _ = await withCheckedContinuation { continuation in
            principal.configure(configurationData: configurationData) {
                continuation.resume(returning: $0)
            }
        }

        let invalid = aiWorkerWireRequest(phase: .toolSelection, handles: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sink = Phase2WirePrincipalSinkProbe()
        principal.run(
            requestData: try encoder.encode(invalid),
            requestID: invalid.requestID,
            eventSink: sink
        )
        let terminal = try Phase2AIWorkerWireCodec().decodeTerminal(await sink.terminal())
        XCTAssertEqual(terminal.status, .failed)
        XCTAssertEqual(terminal.reason, .invalidRequest)
        let callCount = await handler.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testBothPhasesRoundTripAndPreserveOpaqueNonUUIDCallID() throws {
        let codec = Phase2AIWorkerWireCodec()
        let selection = aiWorkerWireRequest(
            phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")]
        )
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(selection)), selection)

        let proposal = aiWorkerWireEvent(
            request: selection,
            body: .toolProposal(
                callID: "Call_é/Not-A-UUID",
                handleID: aiWorkerID(9),
                functionName: "macscope_workspace_summary_v1",
                operationID: "workspace.summary"
            )
        )
        XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(proposal)), proposal)

        let awaiting = aiWorkerWireEvent(request: selection, sequence: 2, body: .awaitingTools)
        XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(awaiting)), awaiting)

        let finalization = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR2.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion,
            phase: .finalization
        )
        XCTAssertEqual(try codec.decodeRequest(codec.encodeRequest(finalization)), finalization)
        let shellProposal = aiWorkerWireEvent(
            request: finalization,
            body: .shellProposal(aiWorkerWireShellProposal())
        )
        XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(shellProposal)), shellProposal)
        let debuggerProposal = aiWorkerWireEvent(
            request: finalization,
            body: .debuggerActionProposal(aiWorkerWireDebuggerActionProposal())
        )
        XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(debuggerProposal)), debuggerProposal)
        let completed = aiWorkerWireEvent(request: finalization, body: .completed)
        XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(completed)), completed)
    }

    func testV5ToolSelectionRequiresExactlyEmptyConversationContext() throws {
        let empty = Phase2AIWorkerWireConversationContext(turns: [], omittedTurnCount: 0)
        let valid = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR3.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion,
            phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")],
            conversationContext: empty
        )
        XCTAssertEqual(
            try Phase2AIWorkerWireCodec().decodeRequest(
                Phase2AIWorkerWireCodec().encodeRequest(valid)
            ),
            valid
        )

        let disclosedOmission = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR3.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion,
            phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")],
            conversationContext: .init(turns: [], omittedTurnCount: 1)
        )
        XCTAssertThrowsError(try Phase2AIWorkerWireCodec().encodeRequest(disclosedOmission))
    }

    func testV5FinalizationRejectsHistoryOwnedByAnotherConversation() throws {
        func context(conversationID: UUID) -> Phase2AIWorkerWireConversationContext {
            .init(
                turns: [.init(
                    conversationID: conversationID,
                    inferenceTurnID: aiWorkerID(30),
                    turnSequence: 1,
                    user: "prior-user",
                    assistant: "prior-assistant",
                    isLegacy: false
                )],
                omittedTurnCount: 0
            )
        }
        let matching = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR3.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion,
            phase: .finalization,
            conversationContext: context(conversationID: aiWorkerID(3))
        )
        XCTAssertEqual(
            try Phase2AIWorkerWireCodec().decodeRequest(
                Phase2AIWorkerWireCodec().encodeRequest(matching)
            ),
            matching
        )

        let injected = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR3.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR3.inferenceVersion,
            phase: .finalization,
            conversationContext: context(conversationID: aiWorkerID(99))
        )
        XCTAssertThrowsError(try Phase2AIWorkerWireCodec().encodeRequest(injected))
    }

    func testProductionAliasAcceptsV3UsageForBothPhases() throws {
        let codec = Phase2AIWorkerWireCodec()
        let usage = Phase2AIWorkerWireUsage(
            promptTokens: 7,
            completionTokens: 3,
            totalTokens: 10
        )
        for phase in [Phase2AIWorkerWirePhase.toolSelection, .finalization] {
            let request = aiWorkerWireRequest(
                phase: phase,
                handles: phase == .toolSelection
                    ? [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")]
                    : []
            )
            let event = aiWorkerWireEvent(request: request, body: .usage(usage))
            XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(event)), event)
        }
    }

    func testUsageRejectsNegativeInconsistentOverflowedAndOpenPayloads() throws {
        let codec = Phase2AIWorkerWireCodec()
        let request = aiWorkerWireRequest(phase: .finalization)
        let invalidCounts: [(Int, Int, Int)] = [
            (-1, 1, 0),
            (1, -1, 0),
            (1, 1, -1),
            (7, 3, 11),
            (Int.max, 1, Int.max),
        ]
        for (prompt, completion, total) in invalidCounts {
            let event = aiWorkerWireEvent(
                request: request,
                body: .usage(.init(
                    promptTokens: prompt,
                    completionTokens: completion,
                    totalTokens: total
                ))
            )
            XCTAssertThrowsError(try codec.encodeEvent(event)) {
                XCTAssertEqual($0 as? Phase2AIWorkerWireError, .invalidEnvelope)
            }
        }

        let valid = aiWorkerWireEvent(
            request: request,
            body: .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10))
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(valid)) as? [String: Any]
        )
        var body = try XCTUnwrap(object["body"] as? [String: Any])
        var wrapper = try XCTUnwrap(body["usage"] as? [String: Any])
        var usage = try XCTUnwrap(wrapper["_0"] as? [String: Any])
        usage["providerPayload"] = "forbidden"
        wrapper["_0"] = usage
        body["usage"] = wrapper
        object["body"] = body
        let open = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try codec.decodeEvent(open)) {
            XCTAssertEqual($0 as? Phase2AIWorkerWireError, .invalidEnvelope)
        }
    }

    func testAppCodecMapsExactPhaseOpaqueCallIDAndAwaitingTerminal() throws {
        let request = aiWorkerWireRequest(
            phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")]
        )
        let proposal = try Phase2AIWorkerAppCodec().decodeEvent(
            Phase2AIWorkerWireCodec().encodeEvent(
                aiWorkerWireEvent(
                    request: request,
                    body: .toolProposal(
                        callID: "opaque/Call-é",
                        handleID: aiWorkerID(9),
                        functionName: "macscope_workspace_summary_v1",
                        operationID: "workspace.summary"
                    )
                )
            )
        )
        XCTAssertEqual(proposal.phase, .toolSelection)
        guard case .toolProposal(let value) = proposal.body else {
            return XCTFail("Expected a tool proposal")
        }
        XCTAssertEqual(value.callID.rawValue, "opaque/Call-é")
        XCTAssertEqual(value.functionName, "macscope_workspace_summary_v1")
        XCTAssertEqual(value.operationID, .workspaceSummary)

        let terminal = try Phase2AIWorkerAppCodec().decodeEvent(
            Phase2AIWorkerWireCodec().encodeEvent(
                aiWorkerWireEvent(request: request, sequence: 2, body: .awaitingTools)
            )
        )
        XCTAssertEqual(terminal.phase, .toolSelection)
        XCTAssertEqual(terminal.body, .awaitingTools)

        let usage = try Phase2AIWorkerAppCodec().decodeEvent(
            Phase2AIWorkerWireCodec().encodeEvent(
                aiWorkerWireEvent(
                    request: request,
                    sequence: 2,
                    body: .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10))
                )
            )
        )
        XCTAssertEqual(
            usage.body,
            .usage(Phase2ProviderUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10)!)
        )

        let finalization = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR2.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion,
            phase: .finalization
        )
        let shell = try Phase2AIWorkerAppCodec().decodeEvent(
            Phase2AIWorkerWireCodec().encodeEvent(
                aiWorkerWireEvent(
                    request: finalization,
                    body: .shellProposal(aiWorkerWireShellProposal())
                )
            )
        )
        XCTAssertEqual(shell.phase, .finalization)
        guard case .shellProposal(let shellProposal) = shell.body else {
            return XCTFail("Expected a shell proposal")
        }
        XCTAssertEqual(shellProposal.executablePath, "/bin/echo")
        XCTAssertEqual(shellProposal.executionSurface, .shellBrokerPTY)
        XCTAssertEqual(shellProposal.requestedEffects, [.a5])

        let debugger = try Phase2AIWorkerAppCodec().decodeEvent(
            Phase2AIWorkerWireCodec().encodeEvent(
                aiWorkerWireEvent(
                    request: finalization,
                    body: .debuggerActionProposal(aiWorkerWireDebuggerActionProposal())
                )
            )
        )
        XCTAssertEqual(debugger.phase, .finalization)
        guard case .debuggerActionProposal(let debuggerProposal) = debugger.body else {
            return XCTFail("Expected a debugger action proposal")
        }
        XCTAssertEqual(debuggerProposal.action, .stepOver)
        XCTAssertEqual(debuggerProposal.sessionID, aiWorkerID(46))
        XCTAssertEqual(debuggerProposal.lifecycleRevision, 2)
        XCTAssertEqual(debuggerProposal.stopRevision, 1)
        XCTAssertEqual(debuggerProposal.eventSequence, 3)
        XCTAssertEqual(debuggerProposal.requestedAuthority, .controlledRuntimeActions)
    }

    func testAppCodecRoundTripsSixR2ProviderVisibleHandlesAcrossWorkerWire() throws {
        let operations: [Phase2ReadOperationID] = [
            .workspaceSummary,
            .debuggerSummary,
            .debuggerFrames,
            .debuggerRegisters,
            .debuggerVariables,
            .debuggerMemory,
        ]
        let document = Phase2ReadDocumentIdentity(instanceID: aiWorkerID(1))
        let request = Phase2InferenceRequest(
            protocolVersion: .v4,
            phase: .toolSelection,
            sessionID: aiWorkerID(3),
            turnID: aiWorkerID(4),
            requestID: aiWorkerID(5),
            document: document,
            workspace: .init(document: document, instanceID: aiWorkerID(2)),
            lifecycleRevision: 6,
            userGoal: "Inspect the stopped debugger state",
            groundedContext: try Phase2GroundedContextCompiler().compile(
                records: [],
                currentStateByEvidenceID: [:]
            ),
            toolHandles: operations.enumerated().map { index, operation in
                .init(handleID: aiWorkerID(100 + index), operationID: operation)
            },
            limits: .assistantMaximum
        )

        let encoded = try Phase2AIWorkerAppCodec().encodeRequest(request)
        let decoded = try Phase2AIWorkerWireCodec().decodeRequest(encoded)

        XCTAssertEqual(decoded.limits.maximumToolHandles, 8)
        XCTAssertEqual(decoded.toolHandles.count, 6)
        XCTAssertEqual(decoded.toolHandles.map(\.operationID), operations.map(\.rawValue))
    }

    func testAppCodecDecodesEveryProviderVisibleDebuggerToolOperation() throws {
        let request = aiWorkerWireRequest(
            phase: .toolSelection,
            limits: .assistantMaximum,
            handles: [
                .init(handleID: aiWorkerID(101), operationID: "debugger.summary"),
                .init(handleID: aiWorkerID(102), operationID: "debugger.frames"),
                .init(handleID: aiWorkerID(103), operationID: "debugger.registers"),
                .init(handleID: aiWorkerID(104), operationID: "debugger.variables"),
                .init(handleID: aiWorkerID(105), operationID: "debugger.memory"),
            ]
        )
        let expected: [Phase2ReadOperationID] = [
            .debuggerSummary, .debuggerFrames, .debuggerRegisters,
            .debuggerVariables, .debuggerMemory,
        ]

        for (sequence, pair) in zip(request.toolHandles, expected).enumerated() {
            let (handle, operation) = pair
            let event = aiWorkerWireEvent(
                request: request,
                sequence: UInt64(sequence + 1),
                body: .toolProposal(
                    callID: "debugger-call-\(sequence)",
                    handleID: handle.handleID,
                    functionName: "macscope_\(handle.operationID.replacingOccurrences(of: ".", with: "_"))_v1",
                    operationID: handle.operationID
                )
            )

            let decoded = try Phase2AIWorkerAppCodec().decodeEvent(
                Phase2AIWorkerWireCodec().encodeEvent(event)
            )
            guard case .toolProposal(let proposal) = decoded.body else {
                return XCTFail("Expected debugger tool proposal")
            }
            XCTAssertEqual(proposal.operationID, operation)
            XCTAssertEqual(proposal.handleID, handle.handleID)
        }
    }

    func testAssistantWireCarriesEveryDecompilerToolHandleAndProposal() throws {
        let request = aiWorkerWireRequest(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR2.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.assistantR2.inferenceVersion,
            phase: .toolSelection,
            limits: .assistantMaximum,
            handles: [
                .init(handleID: aiWorkerID(111), operationID: "function.review"),
                .init(handleID: aiWorkerID(112), operationID: "decompiler.native.result"),
                .init(handleID: aiWorkerID(113), operationID: "decompiler.macscope.result"),
                .init(handleID: aiWorkerID(114), operationID: "decompiler.compare"),
            ]
        )
        let codec = Phase2AIWorkerWireCodec()
        XCTAssertEqual(
            try codec.decodeRequest(codec.encodeRequest(request)).toolHandles.map(\.operationID),
            request.toolHandles.map(\.operationID)
        )

        let expected: [(String, Phase2ReadOperationID)] = [
            ("macscope_native_decompilation_v1", .decompilerNativeResult),
            ("macscope_decompilation_v1", .decompilerMacScopeResult),
            ("macscope_decompiler_compare_v1", .decompilerCompare),
        ]
        for (sequence, pair) in zip(request.toolHandles.dropFirst(), expected).enumerated() {
            let (handle, (functionName, operation)) = pair
            let event = aiWorkerWireEvent(
                request: request,
                sequence: UInt64(sequence + 1),
                body: .toolProposal(
                    callID: "decompiler-call-\(sequence)",
                    handleID: handle.handleID,
                    functionName: functionName,
                    operationID: handle.operationID
                )
            )
            let decoded = try Phase2AIWorkerAppCodec().decodeEvent(codec.encodeEvent(event))
            guard case .toolProposal(let proposal) = decoded.body else {
                return XCTFail("Expected decompiler tool proposal")
            }
            XCTAssertEqual(proposal.operationID, operation)
            XCTAssertEqual(proposal.handleID, handle.handleID)
        }
        // The frozen R1 qualification vocabulary is unchanged.
        let legacy = aiWorkerWireRequest(phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(112), operationID: "decompiler.native.result")])
        XCTAssertThrowsError(try codec.encodeRequest(legacy))
    }

    func testProductionV3RejectsV1V2UnknownAndMixedWireInferenceVersions() throws {
        let codec = Phase2AIWorkerWireCodec()
        for wireIdentity in [
            "phase2.ai-worker-wire.v1",
            Phase2AIWorkerProductionProtocol.legacyV2WireIdentity,
            "phase2.ai-worker-wire.v999",
        ] {
            let value = aiWorkerWireRequest(wireProtocol: wireIdentity)
            XCTAssertThrowsError(try codec.decodeRequest(codec.encodeRequest(value))) {
                XCTAssertEqual(
                    $0 as? Phase2AIWorkerWireError,
                    .unsupportedWireProtocol(wireIdentity)
                )
            }
        }
        for inferenceVersion in [1, 2, 999] {
            let value = aiWorkerWireRequest(protocolVersion: inferenceVersion)
            XCTAssertThrowsError(try codec.decodeRequest(codec.encodeRequest(value))) {
                XCTAssertEqual(
                    $0 as? Phase2AIWorkerWireError,
                    .unsupportedProtocolVersion(inferenceVersion)
                )
            }
        }
    }

    func testRejectsMalformedPhaseBodyCombinations() throws {
        let codec = Phase2AIWorkerWireCodec()
        let selection = aiWorkerWireRequest(
            phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")]
        )
        for body in [
            Phase2AIWorkerWireEventBody.contentDelta("not allowed"),
            .shellProposal(aiWorkerWireShellProposal()),
            .finalCandidate(kind: .answer, text: "not allowed", evidenceIDs: []),
            .completed,
        ] {
            XCTAssertThrowsError(
                try codec.decodeEvent(codec.encodeEvent(aiWorkerWireEvent(request: selection, body: body)))
            )
        }

        let finalization = aiWorkerWireRequest(phase: .finalization)
        for body in [
            Phase2AIWorkerWireEventBody.toolProposal(
                callID: "opaque-call",
                handleID: aiWorkerID(9),
                functionName: "macscope_workspace_summary_v1",
                operationID: "workspace.summary"
            ),
            .awaitingTools,
        ] {
            XCTAssertThrowsError(
                try codec.decodeEvent(codec.encodeEvent(aiWorkerWireEvent(request: finalization, body: body)))
            )
        }

        XCTAssertThrowsError(try codec.decodeEvent(codec.encodeEvent(aiWorkerWireEvent(
            request: finalization,
            body: .shellProposal(aiWorkerWireShellProposal(executablePath: "relative-tool"))
        ))))
    }

    func testTerminalStatusIsBoundToExactPhase() throws {
        let codec = Phase2AIWorkerWireCodec()
        let selection = Phase2AIWorkerTerminal(
            wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion,
            phase: .toolSelection,
            requestID: aiWorkerID(5),
            status: .awaitingTools,
            reason: nil
        )
        XCTAssertEqual(try codec.decodeTerminal(codec.encodeTerminal(selection)), selection)

        let finalization = Phase2AIWorkerTerminal(
            wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion,
            phase: .finalization,
            requestID: aiWorkerID(5),
            status: .completed,
            reason: nil
        )
        XCTAssertEqual(try codec.decodeTerminal(codec.encodeTerminal(finalization)), finalization)

        for mismatch in [
            Phase2AIWorkerTerminal(
                wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
                protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion,
                phase: .toolSelection,
                requestID: aiWorkerID(5),
                status: .completed,
                reason: nil
            ),
            Phase2AIWorkerTerminal(
                wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
                protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion,
                phase: .finalization,
                requestID: aiWorkerID(5),
                status: .awaitingTools,
                reason: nil
            ),
        ] {
            XCTAssertThrowsError(try codec.decodeTerminal(codec.encodeTerminal(mismatch)))
        }
    }

    func testOpaqueCallIDAcceptsMaximumAndRejectsEmptyControlAndMaximumPlusOne() throws {
        let codec = Phase2AIWorkerWireCodec()
        let selection = aiWorkerWireRequest(
            phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")]
        )
        let maximum = String(repeating: "x", count: 256)
        XCTAssertNoThrow(
            try codec.decodeEvent(
                codec.encodeEvent(aiWorkerWireEvent(
                    request: selection,
                    body: .toolProposal(
                        callID: maximum,
                        handleID: aiWorkerID(9),
                        functionName: "macscope_workspace_summary_v1",
                        operationID: "workspace.summary"
                    )
                ))
            )
        )
        for callID in ["", "bad\u{001F}id", "bad\u{007F}id", String(repeating: "x", count: 257)] {
            XCTAssertThrowsError(
                try codec.decodeEvent(
                    codec.encodeEvent(aiWorkerWireEvent(
                        request: selection,
                        body: .toolProposal(
                            callID: callID,
                            handleID: aiWorkerID(9),
                            functionName: "macscope_workspace_summary_v1",
                            operationID: "workspace.summary"
                        )
                    ))
                )
            )
        }
    }

    func testStrictDecoderRejectsRecursiveDuplicateKeysAndTrailingBytes() throws {
        let codec = Phase2AIWorkerWireCodec()
        let data = try codec.encodeRequest(aiWorkerWireRequest())
        let validRequest = String(decoding: data, as: UTF8.self)
        XCTAssertThrowsError(try codec.decodeRequest(Data((validRequest + "x").utf8)))

        let duplicatedNested = Data(
            validRequest.replacingOccurrences(
                of: "\"maximumGoalBytes\":65536",
                with: "\"maximumGoalBytes\":65536,\"maximumGoalBytes\":65536"
            ).utf8
        )
        XCTAssertThrowsError(try codec.decodeRequest(duplicatedNested)) {
            XCTAssertEqual($0 as? Phase2AIWorkerWireError, .malformedEnvelope)
        }
    }

    func testRequestRejectsUnboundedLimitsAndUnknownOperations() throws {
        let codec = Phase2AIWorkerWireCodec()
        let invalidLimits = Phase2AIWorkerWireLimits(
            maximumGoalBytes: 65_537,
            maximumEventBytes: 65_536,
            maximumCumulativeEventBytes: 1_048_576,
            maximumEvents: 256,
            maximumToolHandles: 3,
            maximumToolProposals: 3,
            maximumFinalTextBytes: 65_536,
            maximumEvidenceReferences: 3
        )
        XCTAssertThrowsError(
            try codec.decodeRequest(try codec.encodeRequest(aiWorkerWireRequest(limits: invalidLimits)))
        )
        XCTAssertThrowsError(
            try codec.decodeRequest(
                try codec.encodeRequest(
                    aiWorkerWireRequest(
                        phase: .toolSelection,
                        handles: [.init(handleID: aiWorkerID(9), operationID: "unknown")]
                    )
                )
            )
        )
        XCTAssertThrowsError(
            try codec.decodeRequest(
                try codec.encodeRequest(
                    aiWorkerWireRequest(
                        phase: .toolSelection,
                        handles: [
                            .init(handleID: aiWorkerID(9), operationID: "workspace.summary"),
                            .init(handleID: aiWorkerID(10), operationID: "workspace.summary"),
                        ]
                    )
                )
            )
        )
    }

    func testMaximumContractRequestFitsFrozenEnvelopeAndMaximumPlusOneRejects() throws {
        let maximumGoal = String(repeating: "\u{001f}", count: 65_536)
        let maximumContext = Data(repeating: 0xff, count: 1_048_576)
        let request = aiWorkerWireRequest(
            phase: .toolSelection,
            userGoal: maximumGoal,
            canonicalContext: maximumContext,
            evidenceIDs: [aiWorkerID(20), aiWorkerID(21), aiWorkerID(22)],
            handles: [
                .init(handleID: aiWorkerID(9), operationID: "workspace.summary"),
                .init(handleID: aiWorkerID(10), operationID: "selection.explain"),
                .init(handleID: aiWorkerID(11), operationID: "function.review"),
            ]
        )
        let codec = Phase2AIWorkerWireCodec()

        let encoded = try codec.encodeRequest(request)

        XCTAssertEqual(try codec.decodeRequest(encoded), request)
        XCTAssertLessThanOrEqual(encoded.count, Phase2AIWorkerWireCodec.maximumRequestEnvelopeBytes)
        XCTAssertThrowsError(
            try Phase2AIWorkerWireCodec(maximumEnvelopeBytes: encoded.count - 1)
                .encodeRequest(request)
        ) { XCTAssertEqual($0 as? Phase2AIWorkerWireError, .envelopeTooLarge) }

        let maximumPlusOne = Data(
            repeating: 0x20,
            count: Phase2AIWorkerWireCodec.maximumRequestEnvelopeBytes + 1
        )
        XCTAssertThrowsError(try codec.decodeRequest(maximumPlusOne)) {
            XCTAssertEqual($0 as? Phase2AIWorkerWireError, .envelopeTooLarge)
        }
    }

    func testFinalCandidateKindIsClosedAndAnswerRequiresEvidence() throws {
        let codec = Phase2AIWorkerWireCodec()
        let request = aiWorkerWireRequest(phase: .finalization)
        let evidenceID = aiWorkerID(20)
        let answer = aiWorkerWireEvent(
            request: request,
            body: .finalCandidate(kind: .answer, text: "Grounded", evidenceIDs: [evidenceID])
        )
        XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(answer)), answer)

        let abstention = aiWorkerWireEvent(
            request: request,
            body: .finalCandidate(
                kind: .insufficientEvidence,
                text: "No evidence.",
                evidenceIDs: []
            )
        )
        XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(abstention)), abstention)

        XCTAssertThrowsError(try codec.encodeEvent(aiWorkerWireEvent(
            request: request,
            body: .finalCandidate(kind: .answer, text: "Unsupported", evidenceIDs: [])
        )))
        XCTAssertThrowsError(try codec.encodeEvent(aiWorkerWireEvent(
            request: request,
            body: .finalCandidate(
                kind: .insufficientEvidence,
                text: "No evidence.",
                evidenceIDs: [evidenceID]
            )
        )))
    }

    func testFinalKindsEnforceIndependentUTF8ByteCeilings() throws {
        let codec = Phase2AIWorkerWireCodec()
        let request = aiWorkerWireRequest(phase: .finalization)
        let evidenceID = aiWorkerID(20)

        for (kind, maximumBytes, evidenceIDs) in [
            (Phase2AIWorkerWireFinalKind.answer, 60_000, [evidenceID]),
            (.insufficientEvidence, 4_096, []),
        ] {
            let accepted = aiWorkerWireEvent(
                request: request,
                body: .finalCandidate(
                    kind: kind,
                    text: String(repeating: "x", count: maximumBytes),
                    evidenceIDs: evidenceIDs
                )
            )
            XCTAssertEqual(try codec.decodeEvent(codec.encodeEvent(accepted)), accepted)

            XCTAssertThrowsError(try codec.encodeEvent(aiWorkerWireEvent(
                request: request,
                body: .finalCandidate(
                    kind: kind,
                    text: String(repeating: "x", count: maximumBytes + 1),
                    evidenceIDs: evidenceIDs
                )
            )))
        }
    }

    func testTerminalReasonSemanticsAreStatusBound() throws {
        let codec = Phase2AIWorkerWireCodec()
        let valid: [(Phase2AIWorkerTerminal.Status, Phase2AIWorkerWirePhase?, Phase2AIWorkerTerminal.Reason?)] = [
            (.completed, .finalization, nil),
            (.awaitingTools, .toolSelection, nil),
            (.cancelled, nil, nil),
            (.failed, nil, .workerHandlerFailed),
        ]
        for (status, phase, reason) in valid {
            let terminal = Phase2AIWorkerTerminal(
                wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
                protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion,
                phase: phase,
                requestID: aiWorkerID(5),
                status: status,
                reason: reason
            )
            XCTAssertEqual(try codec.decodeTerminal(codec.encodeTerminal(terminal)), terminal)
        }

        for status in [
            Phase2AIWorkerTerminal.Status.completed,
            .awaitingTools,
            .cancelled,
        ] {
            let invalid = Phase2AIWorkerTerminal(
                wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
                protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion,
                phase: status == .completed ? .finalization : nil,
                requestID: aiWorkerID(5),
                status: status,
                reason: .workerHandlerFailed
            )
            XCTAssertThrowsError(try codec.encodeTerminal(invalid))
        }

        let failedWithoutReason = Phase2AIWorkerTerminal(
            wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion,
            phase: nil,
            requestID: aiWorkerID(5),
            status: .failed,
            reason: nil
        )
        XCTAssertThrowsError(try codec.encodeTerminal(failedWithoutReason))
    }

    func testStrictJSONStructuralBudgetsAcceptMaximumAndRejectFirstOver() {
        let limits = Phase2AIWorkerWireJSONLimits.productionEnvelope

        let maximumDepth = Data((String(repeating: "[", count: 16)
            + "null"
            + String(repeating: "]", count: 16)).utf8)
        let overDepth = Data((String(repeating: "[", count: 17)
            + "null"
            + String(repeating: "]", count: 17)).utf8)
        XCTAssertTrue(Phase2StrictJSONValidator.validate(maximumDepth, limits: limits))
        XCTAssertFalse(Phase2StrictJSONValidator.validate(overDepth, limits: limits))

        let maximumMembers = Data(("[" + Array(repeating: "null", count: 1_024).joined(separator: ",") + "]").utf8)
        let overMembers = Data(("[" + Array(repeating: "null", count: 1_025).joined(separator: ",") + "]").utf8)
        XCTAssertTrue(Phase2StrictJSONValidator.validate(maximumMembers, limits: limits))
        XCTAssertFalse(Phase2StrictJSONValidator.validate(overMembers, limits: limits))

        let maximumTokenValues = Array(repeating: "null", count: 2_046) + ["[]"]
        let maximumTokens = Data(("[" + maximumTokenValues.joined(separator: ",") + "]").utf8)
        let overTokens = Data(("[" + Array(repeating: "null", count: 2_048).joined(separator: ",") + "]").utf8)
        let tokenOnlyLimits = Phase2AIWorkerWireJSONLimits(
            maximumDepth: 16,
            maximumTokens: 4_096,
            maximumMembersAndElements: 4_096
        )
        XCTAssertTrue(Phase2StrictJSONValidator.validate(maximumTokens, limits: tokenOnlyLimits))
        XCTAssertFalse(Phase2StrictJSONValidator.validate(overTokens, limits: tokenOnlyLimits))
    }

    func testClosedEnvelopesRejectUnknownTopLevelAndNestedMembers() throws {
        let codec = Phase2AIWorkerWireCodec()
        let request = aiWorkerWireRequest(
            phase: .toolSelection,
            handles: [.init(handleID: aiWorkerID(9), operationID: "workspace.summary")]
        )
        let requestJSON = String(decoding: try codec.encodeRequest(request), as: UTF8.self)
        let unknownTopLevel = requestJSON.replacingOccurrences(
            of: "{\"canonicalContext\"",
            with: "{\"unexpected\":true,\"canonicalContext\""
        )
        XCTAssertThrowsError(try codec.decodeRequest(Data(unknownTopLevel.utf8)))

        let unknownHandleMember = requestJSON.replacingOccurrences(
            of: "\"handleID\":",
            with: "\"unexpected\":true,\"handleID\":"
        )
        XCTAssertThrowsError(try codec.decodeRequest(Data(unknownHandleMember.utf8)))

        let event = aiWorkerWireEvent(
            request: request,
            body: .toolProposal(
                callID: "call",
                handleID: aiWorkerID(9),
                functionName: "macscope_workspace_summary_v1",
                operationID: "workspace.summary"
            )
        )
        let eventJSON = String(decoding: try codec.encodeEvent(event), as: UTF8.self)
        let unknownBodyMember = eventJSON.replacingOccurrences(
            of: "\"callID\":",
            with: "\"unexpected\":true,\"callID\":"
        )
        XCTAssertThrowsError(try codec.decodeEvent(Data(unknownBodyMember.utf8)))

        let handshake = Phase2AIWorkerHandshake(
            wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
            inferenceProtocol: Phase2AIWorkerProductionProtocol.inferenceIdentity,
            manifestIdentity: Phase2AIWorkerProductionProtocol.manifestIdentity,
            status: .ready
        )
        let handshakeJSON = String(decoding: try codec.encodeHandshake(handshake), as: UTF8.self)
        XCTAssertThrowsError(try codec.decodeHandshake(Data(
            handshakeJSON.replacingOccurrences(
                of: "{\"inferenceProtocol\"",
                with: "{\"unexpected\":true,\"inferenceProtocol\""
            ).utf8
        )))

        let terminal = Phase2AIWorkerTerminal(
            wireProtocol: Phase2AIWorkerProductionProtocol.wireIdentity,
            protocolVersion: Phase2AIWorkerProductionProtocol.inferenceVersion,
            phase: .finalization,
            requestID: aiWorkerID(5),
            status: .completed,
            reason: nil
        )
        let terminalJSON = String(decoding: try codec.encodeTerminal(terminal), as: UTF8.self)
        XCTAssertThrowsError(try codec.decodeTerminal(Data(
            terminalJSON.replacingOccurrences(
                of: "{\"phase\"",
                with: "{\"unexpected\":true,\"phase\""
            ).utf8
        )))
    }
}

private func aiWorkerWireRequest(
    wireProtocol: String = Phase2AIWorkerProductionProtocol.wireIdentity,
    protocolVersion: Int = Phase2AIWorkerProductionProtocol.inferenceVersion,
    phase: Phase2AIWorkerWirePhase = .finalization,
    limits: Phase2AIWorkerWireLimits = .maximum,
    userGoal: String = "Explain the selected function",
    canonicalContext: Data = Data("{}".utf8),
    evidenceIDs: [UUID] = [],
    handles: [Phase2AIWorkerWireToolHandle] = [],
    conversationContext: Phase2AIWorkerWireConversationContext? = nil,
    shellContinuationCoordinate: Phase2AIWorkerWireShellContinuationCoordinate? = nil
) -> Phase2AIWorkerWireRequest {
    .init(
        wireProtocol: wireProtocol,
        protocolVersion: protocolVersion,
        phase: phase,
        sessionID: aiWorkerID(3),
        turnID: aiWorkerID(4),
        requestID: aiWorkerID(5),
        documentID: aiWorkerID(1),
        workspaceID: aiWorkerID(2),
        lifecycleRevision: 6,
        userGoal: userGoal,
        canonicalContext: canonicalContext,
        contextDigest: String(repeating: "a", count: 64),
        evidenceIDs: evidenceIDs,
        toolHandles: handles,
        conversationContext: conversationContext,
        shellContinuationCoordinate: shellContinuationCoordinate,
        limits: limits
    )
}

private func aiWorkerWireContinuationCoordinate() -> Phase2AIWorkerWireShellContinuationCoordinate {
    .init(Phase2AssistantShellContinuationCoordinate(
        workspaceID: aiWorkerID(2),
        workspaceDocumentIdentityDigest: String(repeating: "d", count: 64),
        conversationID: aiWorkerID(3), inferenceTurnID: aiWorkerID(4), turnSequence: 7,
        originatingFinalizationRequestID: aiWorkerID(40), shellProposalID: aiWorkerID(41),
        shellExecutionID: aiWorkerID(42), runtimeAuthorityRecordID: aiWorkerID(43),
        shellProposalDigest: String(repeating: "a", count: 64),
        shellExecutionResultDigest: String(repeating: "b", count: 64),
        runtimeAuthorityRecordDigest: String(repeating: "c", count: 64),
        productionManifestIdentity: Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
        providerRevision: 9, continuationOrdinal: 1, continuationRequestID: aiWorkerID(5)
    )!)
}

private func aiWorkerWireEvent(
    request: Phase2AIWorkerWireRequest,
    sequence: UInt64 = 1,
    body: Phase2AIWorkerWireEventBody
) -> Phase2AIWorkerWireEvent {
    .init(
        wireProtocol: request.wireProtocol,
        protocolVersion: request.protocolVersion,
        phase: request.phase,
        sessionID: request.sessionID,
        turnID: request.turnID,
        requestID: request.requestID,
        documentID: request.documentID,
        workspaceID: request.workspaceID,
        lifecycleRevision: request.lifecycleRevision,
        sequence: sequence,
        body: body
    )
}

private func aiWorkerWireShellProposal(
    proposalID: UUID = aiWorkerID(44),
    executablePath: String = "/bin/echo",
    arguments: [String] = ["from worker"],
    environment: [String: String] = [:],
    workingDirectoryPath: String? = nil,
    timeoutMilliseconds: Int = 1_000,
    maximumOutputBytes: Int = 1_024,
    executionSurface: String = "shellBrokerPTY",
    requestedEffects: [String] = ["A5"]
) -> Phase2AIWorkerWireShellProposal {
    .init(
        proposalID: proposalID,
        executablePath: executablePath,
        arguments: arguments,
        environment: environment,
        workingDirectoryPath: workingDirectoryPath,
        timeoutMilliseconds: timeoutMilliseconds,
        maximumOutputBytes: maximumOutputBytes,
        executionSurface: executionSurface,
        requestedEffects: requestedEffects
    )
}

private func aiWorkerWireDebuggerActionProposal(
    proposalID: UUID = aiWorkerID(45),
    action: String = "stepOver",
    sessionID: UUID = aiWorkerID(46),
    lifecycleRevision: UInt64 = 2,
    stopRevision: UInt64? = 1,
    eventSequence: UInt64? = 3,
    requestedAuthority: String = "controlledRuntimeActions"
) -> Phase2AIWorkerWireDebuggerActionProposal {
    .init(
        proposalID: proposalID,
        action: action,
        sessionID: sessionID,
        lifecycleRevision: lifecycleRevision,
        stopRevision: stopRevision,
        eventSequence: eventSequence,
        requestedAuthority: requestedAuthority
    )
}

private func aiWorkerID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private final class Phase2InferenceActivityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var begun = 0
    private var ended = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var counts: (begun: Int, ended: Int) { lock.withLock { (begun, ended) } }
    func begin() { lock.withLock { begun += 1 } }
    func end() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            ended += 1
            let ready = waiters.filter { $0.0 <= ended }.map { $0.1 }
            waiters.removeAll { $0.0 <= ended }
            return ready
        }
        ready.forEach { $0.resume() }
    }
    func waitForEnds(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                if ended >= count { return true }
                waiters.append((count, continuation))
                return false
            }
            if immediate { continuation.resume() }
        }
    }
}

private actor Phase2BlockingInferenceHandler: Phase2AIWorkerHandling {
    enum Failure: Error { case requested }
    private var gate: CheckedContinuation<Void, Error>?
    private var started: [CheckedContinuation<Void, Never>] = []
    func run(request: Phase2AIWorkerWireRequest, configuration: Phase2AIWorkerConfigurationWire,
        emit: @escaping @Sendable (Phase2AIWorkerWireEvent) async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            gate = continuation
            started.forEach { $0.resume() }
            started.removeAll()
        }
    }
    func waitUntilRunning() async {
        if gate != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func release(failing: Bool) {
        let continuation = gate
        gate = nil
        if failing { continuation?.resume(throwing: Failure.requested) }
        else { continuation?.resume() }
    }
}

private actor Phase2WirePrincipalHandlerProbe: Phase2AIWorkerHandling {
    private(set) var callCount = 0

    func run(
        request: Phase2AIWorkerWireRequest,
        configuration: Phase2AIWorkerConfigurationWire,
        emit: @escaping @Sendable (Phase2AIWorkerWireEvent) async throws -> Void
    ) async throws {
        callCount += 1
    }
}

private final class Phase2WirePrincipalSinkProbe: NSObject,
    Phase2AIWorkerEventSinkXPCProtocol, @unchecked Sendable
{
    private let lock = NSLock()
    private var terminalData: Data?
    private var continuation: CheckedContinuation<Data, Never>?
    private let terminalObserver: @Sendable () -> Void

    init(terminalObserver: @escaping @Sendable () -> Void = {}) {
        self.terminalObserver = terminalObserver
        super.init()
    }

    func receive(eventData: Data, with reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func finish(resultData: Data) {
        terminalObserver()
        let waiting = lock.withLock { () -> CheckedContinuation<Data, Never>? in
            terminalData = resultData
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: resultData)
    }

    func terminal() async -> Data {
        if let value = lock.withLock({ terminalData }) { return value }
        return await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Data? in
                if let terminalData { return terminalData }
                self.continuation = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}
