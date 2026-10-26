import Foundation
import XCTest

@testable import MacScope

final class Phase2OpenAIToolSelectionStreamTests: XCTestCase {
    private let firstHandle = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let secondHandle = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let thirdHandle = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testFragmentedInterleavedToolSelectionEmitsOnlyAfterCleanEOF() throws {
        let stream = canonicalToolStream()
        let expected: [Phase2OpenAIChatStreamEvent] = [
            .toolCall(.init(
                opaqueCallID: "call/0",
                functionName: "macscope_workspace_summary_v1",
                handleID: firstHandle
            )),
            .toolCall(.init(
                opaqueCallID: "opaque-β",
                functionName: "macscope_selection_explain_v1",
                handleID: secondHandle
            )),
            .awaitingTools,
        ]

        for split in 0...stream.count {
            var decoder = makeDecoder()
            var events = try decoder.append(stream.prefix(split))
            events += try decoder.append(stream.dropFirst(split))
            XCTAssertEqual(events, [.usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10))])
            events += try decoder.finish()
            XCTAssertEqual(Array(events.suffix(expected.count)), expected, "split at byte \(split)")
        }
    }

    func testEnvelopeParserRejectsRecursiveDuplicateKeysAndTrailingBytesBeforeAssembly() throws {
        let bodies = [
            chunk(delta: #"{"ignored":{"nested":{"same":1,"same":2}},"tool_calls":[]}"#),
            chunk(delta: #"{"tool_calls":[]}"#) + " trailing",
            usageChunk().replacingOccurrences(
                of: #""total_tokens":10"#,
                with: #""total_tokens":10,"ignored":{"x":1,"x":2}"#
            ),
        ]

        for body in bodies {
            var decoder = makeDecoder()
            XCTAssertThrowsError(try decoder.append(Data(sse(body).utf8)), body) {
                XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedJSON)
                XCTAssertFalse(String(describing: $0).contains("same"))
            }
        }
    }

    func testEnvelopeDepthLimitAcceptsSixteenAndRejectsSeventeen() throws {
        let depth16 = String(repeating: #"{"x":"#, count: 12) + "0" + String(repeating: "}", count: 12)
        var accepted = makeDecoder()
        XCTAssertNoThrow(try accepted.append(Data(sse(chunk(delta: #"{"ignored":\#(depth16),"tool_calls":[]}"#)).utf8)))

        let depth17 = String(repeating: #"{"x":"#, count: 13) + "0" + String(repeating: "}", count: 13)
        var rejected = makeDecoder()
        XCTAssertThrowsError(
            try rejected.append(Data(sse(chunk(delta: #"{"ignored":\#(depth17),"tool_calls":[]}"#)).utf8))
        ) { XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedJSON) }
    }

    func testContentLegacyFunctionAndUnsupportedOutputFailClosed() throws {
        let deltas = [
            #"{"content":"no","tool_calls":[]}"#,
            #"{"function_call":{"name":"legacy"}}"#,
            #"{"refusal":"no"}"#,
            #"{"audio":{"x":1}}"#,
        ]
        for delta in deltas {
            var decoder = makeDecoder()
            XCTAssertThrowsError(try decoder.append(Data(sse(chunk(delta: delta)).utf8))) {
                XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .unsupportedCapability)
            }
        }
    }

    func testToolSelectionRequiresExactFinishUsageDoneAndEOFOrder() throws {
        let invalidSequences = [
            sse(chunk(delta: #"{"tool_calls":[]}"#, finishReason: "\"stop\"")),
            sse(usageChunk()),
            sse("[DONE]"),
            sse(chunk(delta: #"{"tool_calls":[]}"#, finishReason: "\"tool_calls\"")) + sse("[DONE]"),
            sse(chunk(delta: #"{"tool_calls":[]}"#, finishReason: "\"tool_calls\"")) + sse(usageChunk()) + sse(usageChunk()),
        ]
        for sequence in invalidSequences {
            var decoder = makeDecoder()
            XCTAssertThrowsError(try decoder.append(Data(sequence.utf8)), sequence)
        }

        var incomplete = makeDecoder()
        _ = try incomplete.append(Data(sse(toolChunk0()).utf8))
        XCTAssertThrowsError(try incomplete.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .incompleteStream)
        }
    }

    func testChunkLimitAccepts256AndRejects257() throws {
        let empty = sse(chunk(delta: #"{"tool_calls":[]}"#))
        var accepted = makeDecoder()
        XCTAssertNoThrow(try accepted.append(Data(String(repeating: empty, count: 256).utf8)))

        var rejected = makeDecoder()
        XCTAssertThrowsError(try rejected.append(Data(String(repeating: empty, count: 257).utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .chunkLimitExceeded)
        }
    }

    func testOrdinaryEnvelopeTokenAndMemberLimitsAreExact() throws {
        let tokenMaximum = flatNullObject(memberCount: 1_013)
        var tokenAccepted = makeDecoder()
        XCTAssertNoThrow(try tokenAccepted.append(Data(sse(chunk(
            delta: #"{"tool_calls":[]}"#,
            extraRootMember: #""ignored":\#(tokenMaximum)"#
        )).utf8)))

        let tokenMaximumPlusOne = flatNullObject(memberCount: 1_013, firstValue: "[]")
        var tokenRejected = makeDecoder()
        XCTAssertThrowsError(try tokenRejected.append(Data(sse(chunk(
            delta: #"{"tool_calls":[]}"#,
            extraRootMember: #""ignored":\#(tokenMaximumPlusOne)"#
        )).utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedJSON)
        }

        var memberAccepted = makeDecoder()
        XCTAssertNoThrow(try memberAccepted.append(Data(sse(chunk(
            delta: #"{"tool_calls":[]}"#,
            extraRootMember: #""ignored":\#(nullArray(elementCount: 1_013))"#
        )).utf8)))

        var memberRejected = makeDecoder()
        XCTAssertThrowsError(try memberRejected.append(Data(sse(chunk(
            delta: #"{"tool_calls":[]}"#,
            extraRootMember: #""ignored":\#(nullArray(elementCount: 1_014))"#
        )).utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedJSON)
        }
    }

    func testUsageEnvelopeTokenAndMemberLimitsAreExact() throws {
        let tokenMaximum = flatNullObject(memberCount: 1_013, firstValue: "[null]")
        var tokenAccepted = makeDecoder()
        try appendToolFinish(to: &tokenAccepted)
        XCTAssertNoThrow(try tokenAccepted.append(Data(sse(usageChunk(
            extraRootMember: #""ignored":\#(tokenMaximum)"#
        )).utf8)))

        let tokenMaximumPlusOne = flatNullObject(memberCount: 1_013, firstValue: "[[]]")
        var tokenRejected = makeDecoder()
        try appendToolFinish(to: &tokenRejected)
        XCTAssertThrowsError(try tokenRejected.append(Data(sse(usageChunk(
            extraRootMember: #""ignored":\#(tokenMaximumPlusOne)"#
        )).utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedJSON)
        }

        var memberAccepted = makeDecoder()
        try appendToolFinish(to: &memberAccepted)
        XCTAssertNoThrow(try memberAccepted.append(Data(sse(usageChunk(
            extraRootMember: #""ignored":\#(nullArray(elementCount: 1_014))"#
        )).utf8)))

        var memberRejected = makeDecoder()
        try appendToolFinish(to: &memberRejected)
        XCTAssertThrowsError(try memberRejected.append(Data(sse(usageChunk(
            extraRootMember: #""ignored":\#(nullArray(elementCount: 1_015))"#
        )).utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .malformedJSON)
        }
    }

    func testExactlyThreeCallsReleaseOnlyAtCleanEOFAndFourthCallFailsSticky() throws {
        let threeCalls = #"{"tool_calls":[{"index":0,"id":"call-0","type":"function","function":{"name":"macscope_workspace_summary_v1","arguments":"{\"handle_id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\"}"}},{"index":1,"id":"call-1","type":"function","function":{"name":"macscope_selection_explain_v1","arguments":"{\"handle_id\":\"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB\"}"}},{"index":2,"id":"call-2","type":"function","function":{"name":"macscope_function_review_v1","arguments":"{\"handle_id\":\"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC\"}"}}]}"#
        var accepted = makeDecoder()
        XCTAssertEqual(try accepted.append(Data(sse(chunk(delta: threeCalls)).utf8)), [])
        XCTAssertEqual(try accepted.append(Data(sse(chunk(
            delta: #"{"tool_calls":[]}"#,
            finishReason: "\"tool_calls\""
        )).utf8)), [])
        XCTAssertEqual(try accepted.append(Data(sse(usageChunk()).utf8)), [
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
        ])
        XCTAssertEqual(try accepted.append(Data(sse("[DONE]").utf8)), [])
        XCTAssertEqual(try accepted.finish(), [
            .toolCall(.init(opaqueCallID: "call-0", functionName: "macscope_workspace_summary_v1", handleID: firstHandle)),
            .toolCall(.init(opaqueCallID: "call-1", functionName: "macscope_selection_explain_v1", handleID: secondHandle)),
            .toolCall(.init(opaqueCallID: "call-2", functionName: "macscope_function_review_v1", handleID: thirdHandle)),
            .awaitingTools,
        ])

        var rejected = makeDecoder()
        XCTAssertEqual(try rejected.append(Data(sse(chunk(delta: threeCalls)).utf8)), [])
        let fourthCall = #"{"tool_calls":[{"index":3,"id":"call-3","type":"function","function":{"name":"macscope_workspace_summary_v1","arguments":"{\"handle_id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\"}"}}]}"#
        XCTAssertThrowsError(try rejected.append(Data(sse(chunk(delta: fourthCall)).utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .invalidToolCall)
        }
        XCTAssertThrowsError(try rejected.append(Data(sse(chunk(delta: #"{"tool_calls":[]}"#)).utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .alreadyFailed)
        }
        XCTAssertThrowsError(try rejected.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .alreadyFailed)
        }
    }

    func testSixteenKReasoningChunksAllowHeadersToolsUsageAndDoneWithoutToolBudgetExhaustion() throws {
        var decoder = makeDecoder()
        _ = try decoder.append(Data(sse(chunk(delta: #"{"role":"assistant"}"#)).utf8))
        for _ in 0..<16_384 {
            XCTAssertEqual(try decoder.append(Data(sse(chunk(delta: #"{"reasoning_content":"x"}"#)).utf8)),
                [.reasoningProgress(byteCount: 1)])
        }
        var events = try decoder.append(canonicalToolStream())
        events += try decoder.finish()
        XCTAssertEqual(events.filter { if case .toolCall = $0 { return true }; return false }.count, 2)
        XCTAssertEqual(events.last, .awaitingTools)
    }

    func testLengthTerminationNeverPublishesPartialToolArguments() throws {
        var decoder = makeDecoder()
        XCTAssertEqual(try decoder.append(Data(sse(toolChunk0()).utf8)), [])
        XCTAssertThrowsError(try decoder.append(Data(sse(chunk(delta: "{}",
            finishReason: "\"length\"")).utf8))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .outputLimitExceeded)
        }
        XCTAssertThrowsError(try decoder.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIChatStreamError, .alreadyFailed)
        }
    }

    private func makeDecoder() -> Phase2OpenAIChatStreamDecoder {
        .init(
            expectedModel: "model-1",
            toolSelectionFunctionHandles: [
                "macscope_workspace_summary_v1": firstHandle,
                "macscope_selection_explain_v1": secondHandle,
                "macscope_function_review_v1": thirdHandle,
            ]
        )
    }

    private func appendToolFinish(to decoder: inout Phase2OpenAIChatStreamDecoder) throws {
        _ = try decoder.append(Data(sse(chunk(
            delta: #"{"tool_calls":[]}"#,
            finishReason: "\"tool_calls\""
        )).utf8)
        )
    }

    private func flatNullObject(memberCount: Int, firstValue: String = "null") -> String {
        let members = (0..<memberCount).map { index in
            #""p\#(index)":\#(index == 0 ? firstValue : "null")"#
        }
        return "{" + members.joined(separator: ",") + "}"
    }

    private func nullArray(elementCount: Int) -> String {
        "[" + Array(repeating: "null", count: elementCount).joined(separator: ",") + "]"
    }

    private func canonicalToolStream() -> Data {
        Data((
            sse(toolChunk0())
                + sse(chunk(delta: #"{"tool_calls":[{"index":1,"id":"opaque-β","type":"function","function":{"name":"macscope_selection_explain_v1","arguments":"{\"handle_id\":\"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB\"}"}}]}"#))
                + sse(chunk(delta: #"{"tool_calls":[{"index":0,"id":"call/0","type":"function","function":{"name":"macscope_workspace_summary_v1","arguments":"id\":\"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA\"}"}}]}"#))
                + sse(chunk(delta: #"{"tool_calls":[]}"#, finishReason: "\"tool_calls\""))
                + sse(usageChunk())
                + sse("[DONE]")
        ).utf8)
    }

    private func toolChunk0() -> String {
        chunk(delta: #"{"tool_calls":[{"index":0,"function":{"arguments":"{\"handle_"}}]}"#)
    }

    private func sse(_ data: String) -> String { "data: \(data)\n\n" }

    private func chunk(
        delta: String,
        finishReason: String = "null",
        extraRootMember: String? = nil
    ) -> String {
        let extra = extraRootMember.map { ",\($0)" } ?? ""
        return "{\"id\":\"chat-1\",\"object\":\"chat.completion.chunk\",\"created\":1,\"model\":\"model-1\",\"choices\":[{\"index\":0,\"delta\":\(delta),\"finish_reason\":\(finishReason)}]\(extra)}"
    }

    private func usageChunk(extraRootMember: String? = nil) -> String {
        let extra = extraRootMember.map { ",\($0)" } ?? ""
        return #"{"id":"chat-1","object":"chat.completion.chunk","created":1,"model":"model-1","choices":[],"usage":{"prompt_tokens":7,"completion_tokens":3,"total_tokens":10}\#(extra)}"#
    }
}
