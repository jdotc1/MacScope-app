import Foundation
import XCTest

@testable import MacScope

final class Phase2OpenAIChatStreamDecoderTests: XCTestCase {
    func testShellContinuationAcceptsOnlyCanonicalFinalStream() throws {
        var decoder = Phase2OpenAIChatStreamDecoder(
            expectedModel: "model-1", shellContinuation: true
        )
        XCTAssertEqual(try decoder.append(canonicalStream()), [
            .contentDelta("café 🚀"), .finished,
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)), .done,
        ])
        XCTAssertNoThrow(try decoder.finish())

        var rejected = Phase2OpenAIChatCompletionDecoder(
            expectedModel: "model-1", shellContinuation: true
        )
        XCTAssertThrowsError(try rejected.append(record: message(chunk(
            delta: "{\"tool_calls\":[]}", finishReason: "\"tool_calls\""
        ))))
    }

    func testCanonicalDataOnlyStreamDecodesAtEveryByteSplit() throws {
        let stream = canonicalStream()
        let expected: [Phase2OpenAIChatStreamEvent] = [
            .contentDelta("café 🚀"),
            .finished,
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .done
        ]

        for split in 0...stream.count {
            var decoder = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1")
            var events = try decoder.append(stream.prefix(split))
            events += try decoder.append(stream.dropFirst(split))
            XCTAssertEqual(events, expected, "split at byte \(split)")
            try decoder.finish()
        }
    }

    func testMTPLXInlineTerminalUsageAtEveryBoundaryAndLegacyRemainsStrict() throws {
        let usage = #","usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}"#
        let terminal = chunk(delta: "{}", finishReason: "\"stop\"", extraRoot: usage)
        let stream = Data((sse(roleChunk()) + sse(chunk(delta: #"{"content":"café 🚀"}"#))
            + sse(terminal) + sse("[DONE]")).utf8)
        for split in 0...stream.count {
            var decoder = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1", acceptsInlineFinishUsage: true)
            var events = try decoder.append(stream.prefix(split))
            events += try decoder.append(stream.dropFirst(split))
            events += try decoder.finish()
            XCTAssertEqual(events, [.contentDelta("café 🚀"), .finished,
                .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)), .done])
        }
        var legacy = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        XCTAssertThrowsError(try legacy.append(record: message(terminal))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidChunk)
        }
        var early = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1", acceptsInlineFinishUsage: true)
        XCTAssertThrowsError(try early.append(record: message(chunk(delta: "{}", extraRoot: usage)))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidChunk)
        }
        var duplicate = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1", acceptsInlineFinishUsage: true)
        _ = try duplicate.append(record: message(terminal))
        XCTAssertThrowsError(try duplicate.append(record: message(usageChunk()))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidUsage)
        }
        var invalid = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1", acceptsInlineFinishUsage: true)
        XCTAssertThrowsError(try invalid.append(record: message(terminal.replacingOccurrences(
            of: #""total_tokens":10"#, with: #""total_tokens":11"#)))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidUsage)
        }
    }

    func testMTPLXInlineTerminalTelemetryUsesProviderScopedLineBudget() throws {
        let telemetry = (0..<400).map {
            "\"metric_\($0)\":\"" + String(repeating: "x", count: 40) + "\""
        }.joined(separator: ",")
        let extra = #","usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10},"mtplx_stats":{\#(telemetry)}"#
        let terminal = Data((sse(chunk(delta: "{}", finishReason: "\"stop\"", extraRoot: extra)) + sse("[DONE]")).utf8)
        XCTAssertGreaterThan(terminal.count, 20_000)
        var mtplx = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1", acceptsInlineFinishUsage: true,
            sseLimits: Phase2OpenAIChatStreamDecoder.mtplxProductionSSELimits)
        var events: [Phase2OpenAIChatStreamEvent] = []
        for position in stride(from: 0, to: terminal.count, by: 137) {
            events += try mtplx.append(terminal[position..<min(position + 137, terminal.count)])
        }
        events += try mtplx.finish()
        XCTAssertEqual(events, [.finished, .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)), .done])
        var legacy = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1")
        XCTAssertThrowsError(try legacy.append(terminal)) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedStream)
        }
        var custom = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1", acceptsInlineFinishUsage: true,
            sseLimits: .init(maximumLineBytes: 16_384))
        XCTAssertThrowsError(try custom.append(terminal)) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedStream)
        }
        var oversized = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1", acceptsInlineFinishUsage: true,
            sseLimits: Phase2OpenAIChatStreamDecoder.mtplxProductionSSELimits)
        XCTAssertThrowsError(try oversized.append(Data(("data: " + String(repeating: "x", count: 65_536) + "\n\n").utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedStream)
        }
        XCTAssertEqual(Phase2OpenAIChatStreamDecoder.productionSSELimits.maximumLineBytes, 16_384)
        XCTAssertEqual(Phase2OpenAIChatStreamDecoder.mtplxProductionSSELimits.maximumLineBytes, 65_536)
        XCTAssertEqual(Phase2OpenAIChatStreamDecoder.mtplxProductionSSELimits.maximumPendingBytes, 65_536)
    }

    func testRequiresMessageEventAndExactRequestedModel() throws {
        var eventDecoder = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        XCTAssertThrowsError(
            try eventDecoder.append(record: .init(event: "delta", data: roleChunk()))
        ) { XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .unsupportedEvent) }

        var modelDecoder = Phase2OpenAIChatCompletionDecoder(expectedModel: "other-model")
        XCTAssertThrowsError(try modelDecoder.append(record: message(roleChunk()))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .inconsistentStream)
        }
    }

    func testToolFunctionRefusalAndAudioSideChannelsFailClosed() throws {
        for field in ["tool_calls", "function_call", "refusal", "audio"] {
            var decoder = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
            let json = chunk(delta: "{\"\(field)\":{\"secret\":\"DO_NOT_ECHO\"}}")
            XCTAssertThrowsError(try decoder.append(record: message(json)), field) {
                XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .unsupportedCapability)
                XCTAssertFalse(String(describing: $0).contains("DO_NOT_ECHO"))
            }
        }
    }

    func testReasoningReportsProgressWithoutExposingPrivateText() throws {
        var decoder = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        let json = chunk(
            delta: "{\"role\":\"assistant\",\"reasoning\":\"private\",\"reasoning_content\":\"private\"}",
            extraRoot: ",\"system_fingerprint\":\"fp\",\"stats\":{\"x\":1}"
        )
        XCTAssertEqual(try decoder.append(record: message(json)), [.reasoningProgress(byteCount: 14)])
    }

    func testOnlyStopCanFinishAndUsageMustFollowStop() throws {
        var lengthDecoder = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        _ = try lengthDecoder.append(record: message(roleChunk()))
        XCTAssertThrowsError(
            try lengthDecoder.append(record: message(chunk(delta: "{}", finishReason: "\"length\"")))
        ) { XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .outputLimitExceeded) }

        var usageDecoder = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        _ = try usageDecoder.append(record: message(roleChunk()))
        XCTAssertThrowsError(try usageDecoder.append(record: message(usageChunk()))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidUsage)
        }
    }

    func testDoneIsExactOrderedUniqueAndEOFIsRequired() throws {
        var early = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        XCTAssertThrowsError(try early.append(record: message("[DONE]"))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .unexpectedDone)
        }

        var incomplete = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1")
        _ = try incomplete.append(Data(sse(roleChunk()).utf8))
        XCTAssertThrowsError(try incomplete.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .incompleteStream)
        }

        var exact = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        _ = try exact.append(record: message(roleChunk()))
        _ = try exact.append(record: message(chunk(delta: "{}", finishReason: "\"stop\"")))
        _ = try exact.append(record: message(usageChunk()))
        XCTAssertThrowsError(try exact.append(record: message(" [DONE]"))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedJSON)
        }
    }

    func testContentAndUsageBoundsFailClosed() throws {
        var content = Phase2OpenAIChatCompletionDecoder(
            expectedModel: "model-1",
            limits: .init(maximumContentDeltaBytes: 2, maximumCumulativeContentBytes: 4)
        )
        XCTAssertThrowsError(
            try content.append(record: message(chunk(delta: "{\"content\":\"abc\"}")))
        ) { XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .contentLimitExceeded) }

        var usage = Phase2OpenAIChatCompletionDecoder(
            expectedModel: "model-1",
            limits: .init(maximumReportedTokens: 9)
        )
        _ = try usage.append(record: message(roleChunk()))
        _ = try usage.append(record: message(chunk(delta: "{}", finishReason: "\"stop\"")))
        XCTAssertThrowsError(try usage.append(record: message(usageChunk()))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidUsage)
        }
    }

    func testDefaultContentDeltaCeilingAcceptsExactMaximumAndRejectsMaximumPlusOne() throws {
        let limits = Phase2OpenAIChatStreamLimits()
        XCTAssertEqual(limits.maximumContentDeltaBytes, 16_384)
        XCTAssertEqual(limits.maximumCumulativeContentBytes, 65_536)

        let maximumDelta = String(repeating: "x", count: 16_384)
        var cumulative = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        for _ in 0..<4 {
            XCTAssertEqual(
                try cumulative.append(
                    record: message(chunk(delta: #"{"content":"\#(maximumDelta)"}"#))
                ),
                [.contentDelta(maximumDelta)]
            )
        }
        XCTAssertThrowsError(
            try cumulative.append(record: message(chunk(delta: #"{"content":"x"}"#)))
        ) { XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .contentLimitExceeded) }

        let overMaximumDelta = maximumDelta + "x"
        var overMaximum = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        XCTAssertThrowsError(
            try overMaximum.append(
                record: message(chunk(delta: #"{"content":"\#(overMaximumDelta)"}"#))
            )
        ) { XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .contentLimitExceeded) }
    }

    func testProviderErrorsAreTypedRedactedAndFailureIsSticky() throws {
        var decoder = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        let body = #"{"error":{"message":"BEARER_SECRET /Users/private/context","type":"server_error"}}"#
        XCTAssertThrowsError(try decoder.append(record: message(body))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .providerError)
            XCTAssertFalse(String(describing: $0).contains("BEARER_SECRET"))
            XCTAssertFalse(String(describing: $0).contains("/Users/private"))
        }
        XCTAssertThrowsError(try decoder.append(record: message(roleChunk()))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .alreadyFailed)
        }
    }

    func testChatSpecificSSEBudgetAcceptsMoreThanGenericRecordLimit() throws {
        let deltas = (0..<300).map { _ in sse(chunk(delta: #"{"content":"x"}"#)) }.joined()
        let stream = Data((
            sse(roleChunk())
                + deltas
                + sse(chunk(delta: "{}", finishReason: "\"stop\""))
                + sse(usageChunk())
                + sse("[DONE]")
        ).utf8)
        var decoder = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1")

        let events = try decoder.append(stream)

        XCTAssertEqual(events.filter { if case .contentDelta = $0 { true } else { false } }.count, 300)
        XCTAssertEqual(Array(events.suffix(3)), [
            .finished,
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .done
        ])
        try decoder.finish()
    }

    func testJSONIntegerValidationRejectsPrecisionLossAndOutOfRangeValues() throws {
        var created = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        let badCreated = roleChunk().replacingOccurrences(
            of: "\"created\":1",
            with: "\"created\":-9223372036854775809"
        )
        XCTAssertThrowsError(try created.append(record: message(badCreated))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidChunk)
        }

        var usage = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        _ = try usage.append(record: message(roleChunk()))
        _ = try usage.append(record: message(chunk(delta: "{}", finishReason: "\"stop\"")))
        let fractional = usageChunk().replacingOccurrences(
            of: "\"prompt_tokens\":7",
            with: "\"prompt_tokens\":1.0000000000000000000001"
        )
        XCTAssertThrowsError(try usage.append(record: message(fractional))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidUsage)
        }
    }

    func testFinalizationShellProposalToolCallDecodesAtEOF() throws {
        let finalJSON = #"{"kind":"answer","text":"Grounded.","evidence_ids":["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"],"reason":""}"#
        let arguments = #"{"executable_path":"/bin/echo","arguments":["hello"],"environment":[],"working_directory_path":"","timeout_milliseconds":1000,"maximum_output_bytes":1024,"execution_surface":"shellBrokerPTY","requested_effects":["A5"]}"#
        let delta = try jsonString([
            "content": finalJSON,
            "tool_calls": [[
                "index": 0,
                "id": "call-shell-1",
                "type": "function",
                "function": [
                    "name": "macscope_stage_shell_proposal_v1",
                    "arguments": arguments,
                ],
            ]],
        ])
        let stream = Data((
            sse(roleChunk())
                + sse(chunk(delta: delta, finishReason: "\"tool_calls\""))
                + sse(usageChunk())
                + sse("[DONE]")
        ).utf8)
        var decoder = Phase2OpenAIChatStreamDecoder(
            expectedModel: "model-1",
            acceptsShellProposalTool: true
        )

        var events = try decoder.append(stream)
        events += try decoder.finish()

        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[0], .contentDelta(finalJSON))
        XCTAssertEqual(events[1], .finished)
        XCTAssertEqual(events[3], .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
        guard case .shellProposal(let proposal) = events[2] else {
            return XCTFail("Expected shell proposal event, got \(events[2])")
        }
        XCTAssertEqual(proposal.executablePath, "/bin/echo")
        XCTAssertEqual(proposal.arguments, ["hello"])
        XCTAssertEqual(proposal.environment, [:])
        XCTAssertEqual(proposal.workingDirectoryPath, nil)
        XCTAssertEqual(proposal.timeoutMilliseconds, 1_000)
        XCTAssertEqual(proposal.maximumOutputBytes, 1_024)
        XCTAssertEqual(proposal.executionSurface, "shellBrokerPTY")
        XCTAssertEqual(proposal.requestedEffects, ["A5"])
        XCTAssertEqual(events[4], .done)
    }

    func testProposalEnabledFinalizationHoldsUsageUntilValidatedEOF() throws {
        var decoder = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1", acceptsShellProposalTool: true)
        XCTAssertEqual(try decoder.append(Data((sse(roleChunk())
            + sse(chunk(delta: "{}", finishReason: "\"stop\""))
            + sse(usageChunk()) + sse("[DONE]")).utf8)), [.finished])
        XCTAssertEqual(try decoder.finish(), [
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)), .done])
    }

    func testFinalizationDebuggerProposalToolCallDecodesAtEOF() throws {
        let finalJSON = #"{"kind":"answer","text":"Grounded.","evidence_ids":["AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"],"reason":""}"#
        let sessionID = "00000000-0000-0000-0000-000000000235"
        let arguments = #"{"action":"stepOver","session_id":"\#(sessionID)","lifecycle_revision":2,"stop_revision":1,"event_sequence":3,"requested_authority":"controlledRuntimeActions"}"#
        let delta = try jsonString([
            "content": finalJSON,
            "tool_calls": [[
                "index": 0,
                "id": "call-debugger-1",
                "type": "function",
                "function": [
                    "name": "macscope_stage_debugger_action_proposal_v1",
                    "arguments": arguments,
                ],
            ]],
        ])
        let stream = Data((
            sse(roleChunk())
                + sse(chunk(delta: delta, finishReason: "\"tool_calls\""))
                + sse(usageChunk())
                + sse("[DONE]")
        ).utf8)
        var decoder = Phase2OpenAIChatStreamDecoder(
            expectedModel: "model-1",
            acceptsShellProposalTool: true
        )

        var events = try decoder.append(stream)
        events += try decoder.finish()

        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[0], .contentDelta(finalJSON))
        XCTAssertEqual(events[1], .finished)
        XCTAssertEqual(events[3], .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)))
        guard case .debuggerActionProposal(let proposal) = events[2] else {
            return XCTFail("Expected debugger proposal event, got \(events[2])")
        }
        XCTAssertEqual(proposal.action, "stepOver")
        XCTAssertEqual(proposal.sessionID.uuidString, sessionID)
        XCTAssertEqual(proposal.lifecycleRevision, 2)
        XCTAssertEqual(proposal.stopRevision, 1)
        XCTAssertEqual(proposal.eventSequence, 3)
        XCTAssertEqual(proposal.requestedAuthority, "controlledRuntimeActions")
        XCTAssertEqual(events[4], .done)
    }

    func testFinalizationRejectsProposalFragmentsWhenFinishReasonIsStop() throws {
        let arguments = #"{"executable_path":"/bin/echo","arguments":[],"environment":[],"working_directory_path":"","timeout_milliseconds":1000,"maximum_output_bytes":1024,"execution_surface":"shellBrokerPTY","requested_effects":["A5"]}"#
        let delta = try jsonString([
            "tool_calls": [[
                "index": 0,
                "id": "call-shell-1",
                "type": "function",
                "function": [
                    "name": "macscope_stage_shell_proposal_v1",
                    "arguments": arguments,
                ],
            ]],
        ])
        let stream = Data((
            sse(chunk(delta: delta, finishReason: "\"stop\""))
                + sse(usageChunk())
                + sse("[DONE]")
        ).utf8)
        var decoder = Phase2OpenAIChatStreamDecoder(
            expectedModel: "model-1",
            acceptsShellProposalTool: true
        )

        _ = try decoder.append(stream)
        XCTAssertThrowsError(try decoder.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidToolCall)
        }
    }

    func testSSEFramingErrorsAreRedactedAtChatBoundary() throws {
        var decoder = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1")

        XCTAssertThrowsError(try decoder.append(Data("BEARER_SECRET: x\n\n".utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedStream)
            XCTAssertFalse(String(describing: $0).contains("BEARER_SECRET"))
        }
    }

    func testReasoningUnicodeSurvivesEveryNetworkBoundarySeparatelyFromFinalJSON() throws {
        let privateText = "思考 café 🚀"
        let finalText = #"{"kind":"answer"}"#
        let stream = Data((sse(chunk(delta: try jsonString(["reasoning_content": privateText])))
            + sse(chunk(delta: try jsonString(["content": finalText])))
            + sse(chunk(delta: "{}", finishReason: "\"stop\""))
            + sse(usageChunk()) + sse("[DONE]")).utf8)
        for split in 0...stream.count {
            var decoder = Phase2OpenAIChatStreamDecoder(expectedModel: "model-1")
            var events = try decoder.append(stream.prefix(split))
            events += try decoder.append(stream.dropFirst(split))
            events += try decoder.finish()
            XCTAssertEqual(events, [.reasoningProgress(byteCount: privateText.utf8.count),
                .contentDelta(finalText), .finished,
                .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)), .done])
        }
    }

    func testReasoningIsBoundedAndMustBeAString() throws {
        var bounded = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1",
            limits: .init(maximumCumulativeReasoningBytes: 3))
        XCTAssertEqual(try bounded.append(record: message(chunk(delta: #"{"reasoning":"abc"}"#))),
            [.reasoningProgress(byteCount: 3)])
        XCTAssertThrowsError(try bounded.append(record: message(chunk(delta: #"{"reasoning":"d"}"#)))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .contentLimitExceeded)
        }
        var malformed = Phase2OpenAIChatCompletionDecoder(expectedModel: "model-1")
        XCTAssertThrowsError(try malformed.append(record: message(chunk(delta: #"{"reasoning":{}}"#)))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidChunk)
        }
    }

    func testMTPLXSelectionPreambleRequiresValidatedToolsAndNeverEmitsContent() throws {
        let handle = UUID()
        let function = "macscope_rea_results_get_v1"
        let preamble = chunk(delta: #"{"content":"I will inspect the selected evidence."}"#)
        let calls = try jsonString(["tool_calls": [[
            "index": 0, "id": "call-1", "type": "function",
            "function": ["name": function, "arguments": try jsonString(["handle_id": handle.uuidString])]
        ]]])
        var decoder = Phase2OpenAIChatStreamDecoder(
            expectedModel: "model-1", toolSelectionAllowedHandles: [function: [handle]],
            acceptsMTPLXToolSelectionPreamble: true
        )
        let bytes = Data((sse(preamble) + sse(chunk(delta: calls))
            + sse(chunk(delta: "{}", finishReason: "\"tool_calls\""))
            + sse(usageChunk()) + sse("[DONE]")).utf8)
        let events = try decoder.append(bytes) + decoder.finish()
        XCTAssertEqual(events.filter { if case .toolCall = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(events.contains(.awaitingTools))
        XCTAssertFalse(events.contains { if case .contentDelta = $0 { return true }; return false })

        var strict = Phase2OpenAIChatCompletionDecoder(
            expectedModel: "model-1", toolSelectionAllowedHandles: [function: [handle]]
        )
        XCTAssertThrowsError(try strict.append(record: message(preamble))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .unsupportedCapability)
        }
        var proseOnly = Phase2OpenAIChatStreamDecoder(
            expectedModel: "model-1", toolSelectionAllowedHandles: [function: [handle]],
            acceptsMTPLXToolSelectionPreamble: true
        )
        _ = try proseOnly.append(Data((sse(preamble)
            + sse(chunk(delta: "{}", finishReason: "\"tool_calls\""))
            + sse(usageChunk()) + sse("[DONE]")).utf8))
        XCTAssertThrowsError(try proseOnly.finish())

        var unoffered = Phase2OpenAIChatStreamDecoder(
            expectedModel: "model-1", toolSelectionAllowedHandles: [function: [UUID()]],
            acceptsMTPLXToolSelectionPreamble: true
        )
        _ = try unoffered.append(bytes)
        XCTAssertThrowsError(try unoffered.finish())
    }

    func testMTPLXSelectionPreambleEnforcesByteBoundsAndUnsupportedCapabilities() throws {
        let handles: [String: Set<UUID>] = ["read": [UUID()]]
        for limits in [
            Phase2OpenAIChatStreamLimits(maximumContentDeltaBytes: 2),
            Phase2OpenAIChatStreamLimits(maximumCumulativeContentBytes: 3)
        ] {
            var decoder = Phase2OpenAIChatCompletionDecoder(
                expectedModel: "model-1", toolSelectionAllowedHandles: handles,
                acceptsMTPLXToolSelectionPreamble: true, limits: limits
            )
            if limits.maximumContentDeltaBytes == 2 {
                XCTAssertThrowsError(try decoder.append(record: message(chunk(delta: #"{"content":"🚀"}"#))))
            } else {
                _ = try decoder.append(record: message(chunk(delta: #"{"content":"ab"}"#)))
                XCTAssertThrowsError(try decoder.append(record: message(chunk(delta: #"{"content":"cd"}"#))))
            }
        }
        for delta in [#"{"content":{}}"#, #"{"refusal":"no"}"#,
                      #"{"audio":{}}"#, #"{"function_call":{}}"#] {
            var decoder = Phase2OpenAIChatCompletionDecoder(
                expectedModel: "model-1", toolSelectionAllowedHandles: handles,
                acceptsMTPLXToolSelectionPreamble: true
            )
            XCTAssertThrowsError(try decoder.append(record: message(chunk(delta: delta))))
        }
    }

    private func canonicalStream() -> Data {
        Data((
            sse(roleChunk())
                + sse(chunk(delta: #"{"content":"café 🚀"}"#))
                + sse(chunk(delta: "{}", finishReason: "\"stop\""))
                + sse(usageChunk())
                + sse("[DONE]")
        ).utf8)
    }

    private func message(_ data: String) -> Phase2SSERecord {
        .init(event: "message", data: data)
    }

    private func sse(_ data: String) -> String {
        "data: \(data)\n\n"
    }

    private func roleChunk() -> String {
        chunk(delta: #"{"role":"assistant"}"#)
    }

    private func chunk(
        delta: String,
        finishReason: String = "null",
        extraRoot: String = ""
    ) -> String {
        "{\"id\":\"chat-1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"model-1\",\"choices\":[{\"index\":0,\"delta\":\(delta),\"finish_reason\":\(finishReason)}]\(extraRoot)}"
    }

    private func usageChunk() -> String {
        #"{"id":"chat-1","object":"chat.completion.chunk","created":1,"model":"model-1","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}}"#
    }

    private func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }
}
