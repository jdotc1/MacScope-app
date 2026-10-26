import Foundation
import XCTest

@testable import MacScope

final class Phase2OpenAIToolCallAssemblerTests: XCTestCase {
    private let firstHandle = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let secondHandle = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    func testGroupedREAReadsAcceptEachOfferedUUIDAndRejectCrossFunctionOrUnknownUUID() throws {
        let get = "macscope_rea_results_get_v1"
        let list = "macscope_rea_results_list_v1"
        let listHandle = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let offered: [String: Set<UUID>] = [get: [firstHandle, secondHandle], list: [listHandle]]
        var accepted = Phase2OpenAIToolCallAssembler(allowedFunctionHandles: offered)
        for (index, handle) in [firstHandle, secondHandle].enumerated() {
            try accepted.append(completeFragment(index: index, id: "read-\(index)",
                function: get, handle: handle))
        }
        XCTAssertEqual(try accepted.finish().map(\.handleID), [firstHandle, secondHandle])
        for handle in [listHandle, UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!] {
            var rejected = Phase2OpenAIToolCallAssembler(allowedFunctionHandles: offered)
            try rejected.append(completeFragment(index: 0, id: "invalid", function: get, handle: handle))
            XCTAssertThrowsError(try rejected.finish()) {
                XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .unknownFunctionHandlePair)
            }
        }
    }

    func testDelayedAtomicMetadataAndInterleavedArgumentsProduceOrderedCalls() throws {
        var assembler = makeAssembler()

        try assembler.append(.init(index: 0, arguments: #"{"handle_"#))
        try assembler.append(.init(
            index: 1,
            id: "opaque-call-β",
            type: "function",
            name: "macscope_selection_explain_v1",
            arguments: #"{"handle_id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"}"#
        ))
        try assembler.append(.init(
            index: 0,
            id: "call/0:not-a-uuid",
            type: "function",
            name: "macscope_workspace_summary_v1",
            arguments: #"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}"#
        ))
        try assembler.append(.init(index: 0))

        XCTAssertEqual(try assembler.finish(), [
            .init(
                opaqueCallID: "call/0:not-a-uuid",
                functionName: "macscope_workspace_summary_v1",
                handleID: firstHandle
            ),
            .init(
                opaqueCallID: "opaque-call-β",
                functionName: "macscope_selection_explain_v1",
                handleID: secondHandle
            ),
        ])
    }

    func testAtomicMetadataMayRepeatExactlyButCannotMutate() throws {
        var exact = makeAssembler()
        let fragment = Phase2OpenAIToolCallFragment(
            index: 0,
            id: "call-1",
            type: "function",
            name: "macscope_workspace_summary_v1"
        )
        try exact.append(fragment)
        try exact.append(fragment)

        for mutation in [
            Phase2OpenAIToolCallFragment(index: 0, id: "call-2"),
            Phase2OpenAIToolCallFragment(index: 0, type: "not_function"),
            Phase2OpenAIToolCallFragment(index: 0, name: "macscope_selection_explain_v1"),
        ] {
            var assembler = makeAssembler()
            try assembler.append(fragment)
            XCTAssertThrowsError(try assembler.append(mutation)) {
                XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .atomicMetadataMismatch)
            }
        }
    }

    func testIndicesMustStartAtZeroRemainBoundedAndFinishContiguously() throws {
        for index in [-1, 3] {
            var assembler = makeAssembler()
            XCTAssertThrowsError(try assembler.append(.init(index: index))) {
                XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .invalidIndex)
            }
        }

        var sparse = makeAssembler()
        try sparse.append(completeFragment(index: 0, id: "call-0", handle: firstHandle))
        try sparse.append(.init(
            index: 2,
            id: "call-2",
            type: "function",
            name: "macscope_selection_explain_v1",
            arguments: arguments(secondHandle)
        ))
        XCTAssertThrowsError(try sparse.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .noncontiguousIndices)
        }
    }

    func testArgumentsAreStrictHandleOnlyObjects() throws {
        let invalidArguments = [
            #"{"handle_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","handle_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}"#,
            #"{"handle_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","extra":1}"#,
            #"{"handle_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"} trailing"#,
            #"[{"handle_id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"}]"#,
            #"{"handle_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}"#,
        ]

        for arguments in invalidArguments {
            var assembler = makeAssembler()
            try assembler.append(.init(
                index: 0,
                id: "call-0",
                type: "function",
                name: "macscope_workspace_summary_v1",
                arguments: arguments
            ))
            XCTAssertThrowsError(try assembler.finish(), arguments) {
                XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .invalidArguments)
            }
        }
    }

    func testFunctionHandlePairingAndPhaseUniquenessFailClosed() throws {
        var mismatch = makeAssembler()
        try mismatch.append(.init(
            index: 0,
            id: "call-0",
            type: "function",
            name: "macscope_workspace_summary_v1",
            arguments: arguments(secondHandle)
        ))
        XCTAssertThrowsError(try mismatch.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .unknownFunctionHandlePair)
        }

        var duplicateID = makeAssembler()
        try duplicateID.append(completeFragment(index: 0, id: "same", handle: firstHandle))
        try duplicateID.append(.init(
            index: 1,
            id: "same",
            type: "function",
            name: "macscope_selection_explain_v1",
            arguments: arguments(secondHandle)
        ))
        XCTAssertThrowsError(try duplicateID.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .duplicateCallID)
        }

        var duplicateHandle = makeAssembler()
        try duplicateHandle.append(completeFragment(index: 0, id: "first", handle: firstHandle))
        try duplicateHandle.append(completeFragment(index: 1, id: "second", handle: firstHandle))
        XCTAssertThrowsError(try duplicateHandle.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .duplicateHandle)
        }
    }

    func testOpaqueIDAndArgumentByteBoundsAreExactAndFailureIsSticky() throws {
        var maximumID = makeAssembler()
        try maximumID.append(completeFragment(
            index: 0,
            id: String(repeating: "x", count: 256),
            handle: firstHandle
        ))
        XCTAssertEqual(try maximumID.finish().first?.opaqueCallID.utf8.count, 256)

        for id in ["", "bad\u{7f}", String(repeating: "x", count: 257)] {
            var assembler = makeAssembler()
            XCTAssertThrowsError(try assembler.append(.init(index: 0, id: id))) {
                XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .invalidAtomicMetadata)
            }
            XCTAssertThrowsError(try assembler.append(.init(index: 0))) {
                XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .alreadyFailed)
            }
        }

        var arguments = makeAssembler(limits: .init(maximumArgumentBytesPerCall: 4))
        try arguments.append(.init(index: 0, arguments: "1234"))
        XCTAssertThrowsError(try arguments.append(.init(index: 0, arguments: "5"))) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .argumentLimitExceeded)
        }
    }

    func testOpaqueIDsCompareAndDeduplicateByExactUTF8Bytes() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift equality is canonically equivalent; this is the trap")

        var drift = makeAssembler()
        try drift.append(.init(index: 0, id: composed))
        XCTAssertThrowsError(try drift.append(.init(index: 0, id: decomposed))) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .atomicMetadataMismatch)
        }

        var distinct = makeAssembler()
        try distinct.append(completeFragment(index: 0, id: composed, handle: firstHandle))
        try distinct.append(.init(
            index: 1,
            id: decomposed,
            type: "function",
            name: "macscope_selection_explain_v1",
            arguments: arguments(secondHandle)
        ))
        XCTAssertEqual(try distinct.finish().count, 2)
    }

    func testToolArgumentJSONDepthTokenAndMemberLimitsAreExact() throws {
        let parser = Phase2StrictJSONParser()

        XCTAssertNoThrow(try parser.parse(Data("[[[[0]]]]".utf8), limits: .toolArguments))
        XCTAssertThrowsError(try parser.parse(Data("[[[[[0]]]]]".utf8), limits: .toolArguments)) {
            XCTAssertEqual($0 as? Phase2StrictJSONError, .depthLimitExceeded)
        }

        let tokenMaximum = flatNullObject(memberCount: 15, firstValue: "[[]]")
        XCTAssertNoThrow(try parser.parse(Data(tokenMaximum.utf8), limits: .toolArguments))
        let tokenMaximumPlusOne = flatNullObject(memberCount: 16)
        XCTAssertThrowsError(try parser.parse(Data(tokenMaximumPlusOne.utf8), limits: .toolArguments)) {
            XCTAssertEqual($0 as? Phase2StrictJSONError, .tokenLimitExceeded)
        }

        XCTAssertNoThrow(try parser.parse(Data(nullArray(elementCount: 16).utf8), limits: .toolArguments))
        XCTAssertThrowsError(try parser.parse(Data(nullArray(elementCount: 17).utf8), limits: .toolArguments)) {
            XCTAssertEqual($0 as? Phase2StrictJSONError, .memberLimitExceeded)
        }
    }

    func testCumulativeArgumentLimitAccepts8192Rejects8193AndFailureIsSticky() throws {
        var accepted = makeAssembler()
        try accepted.append(.init(index: 0, arguments: String(repeating: "a", count: 4_096)))
        try accepted.append(.init(index: 1, arguments: String(repeating: "b", count: 4_095)))
        try accepted.append(.init(index: 2, arguments: "c"))

        var rejected = makeAssembler()
        try rejected.append(.init(index: 0, arguments: String(repeating: "a", count: 4_096)))
        try rejected.append(.init(index: 1, arguments: String(repeating: "b", count: 4_095)))
        try rejected.append(.init(index: 2, arguments: "c"))
        XCTAssertThrowsError(try rejected.append(.init(index: 2, arguments: "d"))) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .argumentLimitExceeded)
        }
        XCTAssertThrowsError(try rejected.append(.init(index: 0))) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .alreadyFailed)
        }
        XCTAssertThrowsError(try rejected.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .alreadyFailed)
        }
    }

    func testExactlyThreeCallsSucceedAndFourthIndexFailsSticky() throws {
        let thirdHandle = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let offered = [
            "macscope_workspace_summary_v1": firstHandle,
            "macscope_selection_explain_v1": secondHandle,
            "macscope_function_review_v1": thirdHandle,
        ]
        var accepted = Phase2OpenAIToolCallAssembler(offeredFunctionHandles: offered)
        try accepted.append(completeFragment(index: 0, id: "call-0", function: "macscope_workspace_summary_v1", handle: firstHandle))
        try accepted.append(completeFragment(index: 1, id: "call-1", function: "macscope_selection_explain_v1", handle: secondHandle))
        try accepted.append(completeFragment(index: 2, id: "call-2", function: "macscope_function_review_v1", handle: thirdHandle))
        XCTAssertEqual(try accepted.finish().map(\.opaqueCallID), ["call-0", "call-1", "call-2"])

        var rejected = Phase2OpenAIToolCallAssembler(offeredFunctionHandles: offered)
        try rejected.append(.init(index: 0))
        try rejected.append(.init(index: 1))
        try rejected.append(.init(index: 2))
        XCTAssertThrowsError(try rejected.append(.init(index: 3))) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .invalidIndex)
        }
        XCTAssertThrowsError(try rejected.append(.init(index: 0))) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .alreadyFailed)
        }
        XCTAssertThrowsError(try rejected.finish()) {
            XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .alreadyFailed)
        }
    }

    func testShellProposalArgumentsMustSatisfyPublishedValueBounds() throws {
        let invalidArguments = [
            #"{"executable_path":"","arguments":[],"environment":[],"working_directory_path":"","timeout_milliseconds":1000,"maximum_output_bytes":1024,"execution_surface":"shellBrokerPTY","requested_effects":["A5"]}"#,
            #"{"executable_path":"/bin/echo","arguments":[],"environment":[],"working_directory_path":"","timeout_milliseconds":0,"maximum_output_bytes":1024,"execution_surface":"shellBrokerPTY","requested_effects":["A5"]}"#,
            #"{"executable_path":"/bin/echo","arguments":[],"environment":[],"working_directory_path":"","timeout_milliseconds":1000,"maximum_output_bytes":1048577,"execution_surface":"shellBrokerPTY","requested_effects":["A5"]}"#,
            #"{"executable_path":"/bin/echo","arguments":[],"environment":[],"working_directory_path":"","timeout_milliseconds":1000,"maximum_output_bytes":1024,"execution_surface":"unreviewed","requested_effects":["A5"]}"#,
            #"{"executable_path":"/bin/echo","arguments":[],"environment":[],"working_directory_path":"","timeout_milliseconds":1000,"maximum_output_bytes":1024,"execution_surface":"shellBrokerPTY","requested_effects":[]}"#,
        ]

        for arguments in invalidArguments {
            var assembler = Phase2OpenAIShellProposalToolCallAssembler()
            try assembler.append(.init(
                index: 0,
                id: "call-shell",
                type: "function",
                name: Phase2OpenAIShellProposalFunctionTool.functionName,
                arguments: arguments
            ))
            XCTAssertThrowsError(try assembler.finishIfPresent(), arguments) {
                XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .invalidArguments)
            }
        }
    }

    func testDebuggerProposalArgumentsMustSatisfyPublishedEnumsAndBounds() throws {
        let sessionID = "00000000-0000-0000-0000-000000000235"
        let invalidArguments = [
            #"{"action":"arbitrary","session_id":"\#(sessionID)","lifecycle_revision":2,"stop_revision":1,"event_sequence":3,"requested_authority":"controlledRuntimeActions"}"#,
            #"{"action":"stepOver","session_id":"\#(sessionID)","lifecycle_revision":0,"stop_revision":1,"event_sequence":3,"requested_authority":"controlledRuntimeActions"}"#,
            #"{"action":"stepOver","session_id":"\#(sessionID)","lifecycle_revision":2,"stop_revision":1,"event_sequence":0,"requested_authority":"controlledRuntimeActions"}"#,
            #"{"action":"stepOver","session_id":"\#(sessionID)","lifecycle_revision":2,"stop_revision":1,"event_sequence":3,"requested_authority":"unreviewed"}"#,
        ]

        for arguments in invalidArguments {
            var assembler = Phase2OpenAIDebuggerActionProposalToolCallAssembler()
            try assembler.append(.init(
                index: 0,
                id: "call-debugger",
                type: "function",
                name: Phase2OpenAIDebuggerActionProposalFunctionTool.functionName,
                arguments: arguments
            ))
            XCTAssertThrowsError(try assembler.finishIfPresent(), arguments) {
                XCTAssertEqual($0 as? Phase2OpenAIToolCallError, .invalidArguments)
            }
        }
    }

    private func makeAssembler(
        limits: Phase2OpenAIToolCallLimits = .init()
    ) -> Phase2OpenAIToolCallAssembler {
        .init(
            offeredFunctionHandles: [
                "macscope_workspace_summary_v1": firstHandle,
                "macscope_selection_explain_v1": secondHandle,
            ],
            limits: limits
        )
    }

    private func completeFragment(index: Int, id: String, handle: UUID) -> Phase2OpenAIToolCallFragment {
        completeFragment(
            index: index,
            id: id,
            function: "macscope_workspace_summary_v1",
            handle: handle
        )
    }

    private func completeFragment(
        index: Int,
        id: String,
        function: String,
        handle: UUID
    ) -> Phase2OpenAIToolCallFragment {
        .init(
            index: index,
            id: id,
            type: "function",
            name: function,
            arguments: arguments(handle)
        )
    }

    private func arguments(_ handle: UUID) -> String {
        #"{"handle_id":"\#(handle.uuidString)"}"#
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
}
