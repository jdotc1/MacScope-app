import Foundation
import XCTest

final class Phase2OpenAIProtocolRequestEncoderTests: XCTestCase {
    func testShellContinuationPreservesOriginalRequestAndOffersNoTools() throws {
        let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: "model",
            systemPrompt: "system untrusted shell evidence",
            userPrompt: #"{"goal":"original request","shell_execution_evidence":{"stdout":"data"}}"#,
            maximumTokens: 128,
            phase: .shellContinuation,
            generationVariant: .assistantR4,
            allowsFinalizationProposalTools: false,
            conversationContext: .init(turns: [], omittedTurnCount: 0)
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["tools"])
        XCTAssertNil(object["tool_choice"])
        XCTAssertNil(object["parallel_tool_calls"])
        XCTAssertNotNil(object["response_format"])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["content"] as? String,
                       #"{"goal":"original request","shell_execution_evidence":{"stdout":"data"}}"#)
    }

    private let handle = Phase2ProductionToolHandle(
        handleID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        operationID: "workspace.summary"
    )

    func testConversationFinalizationOrdersSystemPriorPairsAndCurrentGroundedUser() throws {
        let turns = [
            Phase2ProductionConversationTurn(
                conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                inferenceTurnID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
                turnSequence: 7,
                user: "prior-user",
                assistant: "prior-assistant",
                isLegacy: false
            ),
        ]
        let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: "model", systemPrompt: "system", userPrompt: #"{"goal":"current"}"#,
            maximumTokens: 1, phase: .finalization, generationVariant: .stagedV2,
            conversationContext: Phase2ProductionConversationContext(
                turns: turns, omittedTurnCount: 3
            )
        ))
        let root = try Phase2StrictJSONParser().parse(data)
        let messages = try XCTUnwrap(root.objectValue?["messages"]?.arrayValue)

        XCTAssertEqual(messages.compactMap { $0.objectValue?["role"]?.stringValue }, [
            "system", "system", "user", "assistant", "user",
        ])
        XCTAssertEqual(messages[1].objectValue?["content"]?.stringValue,
                       "3 earlier completed conversation turns were omitted by the bounded retention policy.")
        XCTAssertEqual(messages[2].objectValue?["content"]?.stringValue, "prior-user")
        XCTAssertEqual(messages[3].objectValue?["content"]?.stringValue, "prior-assistant")
        XCTAssertEqual(messages[4].objectValue?["content"]?.stringValue, #"{"goal":"current"}"#)
    }

    func testToolSelectionBodyMatchesFrozenCanonicalBytesAndKeyInventory() throws {
        let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: "local/model",
            systemPrompt: "system",
            userPrompt: #"{"phase":"toolSelection"}"#,
            maximumTokens: 512,
            phase: .toolSelection(handles: [handle]),
            generationVariant: .productionV1
        ))
        let expected = #"""
        {"max_tokens":512,"messages":[{"content":"system","role":"system"},{"content":"{\"phase\":\"toolSelection\"}","role":"user"}],"model":"local/model","parallel_tool_calls":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0,"tool_choice":"required","tools":[{"function":{"description":"Summarize the current MacScope workspace using only the app-issued read handle.","name":"macscope_workspace_summary_v1","parameters":{"additionalProperties":false,"properties":{"handle_id":{"enum":["00000000-0000-0000-0000-000000000001"],"type":"string"}},"required":["handle_id"],"type":"object"}},"type":"function"}]}
        """#
        XCTAssertEqual(data, Data(expected.utf8))

        let object = try Phase2StrictJSONParser().parse(data)
        assertKeys(object, [
            "max_tokens", "messages", "model", "parallel_tool_calls", "stream",
            "stream_options", "temperature", "tool_choice", "tools",
        ])
        let messages = try XCTUnwrap(object.objectValue?["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 2)
        assertKeys(messages[0], ["content", "role"])
        assertKeys(messages[1], ["content", "role"])
        assertKeys(try XCTUnwrap(object.objectValue?["stream_options"]), ["include_usage"])

        XCTAssertEqual(object.objectValue?["tool_choice"]?.stringValue, "required")
        XCTAssertEqual(object.objectValue?["parallel_tool_calls"]?.boolValue, true)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["temperature"] as? NSNumber, 0)
        XCTAssertNil(json["top_p"])
        XCTAssertNil(object.objectValue?["seed"])
        XCTAssertNil(object.objectValue?["stop"])
        XCTAssertNil(object.objectValue?["response_format"])
        let tools = try XCTUnwrap(object.objectValue?["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 1)
        assertKeys(tools[0], ["function", "type"])
        let function = try XCTUnwrap(tools[0].objectValue?["function"])
        assertKeys(function, ["description", "name", "parameters"])
        XCTAssertEqual(function.objectValue?["name"]?.stringValue, "macscope_workspace_summary_v1")
        let parameters = try XCTUnwrap(function.objectValue?["parameters"])
        assertKeys(parameters, ["additionalProperties", "properties", "required", "type"])
        let properties = try XCTUnwrap(parameters.objectValue?["properties"])
        assertKeys(properties, ["handle_id"])
        let handleID = try XCTUnwrap(properties.objectValue?["handle_id"])
        assertKeys(handleID, ["enum", "type"])
    }

    func testStagedV2ToolSelectionBodyMatchesFrozenCanonicalBytes() throws {
        let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: "local/model",
            systemPrompt: "system",
            userPrompt: #"{"phase":"toolSelection"}"#,
            maximumTokens: 512,
            phase: .toolSelection(handles: [handle]),
            generationVariant: .stagedV2
        ))
        let expected = #"""
        {"max_tokens":512,"messages":[{"content":"system","role":"system"},{"content":"{\"phase\":\"toolSelection\"}","role":"user"}],"model":"local/model","parallel_tool_calls":true,"stream":true,"stream_options":{"include_usage":true},"temperature":0,"tool_choice":"required","tools":[{"function":{"description":"Summarize the current MacScope workspace using only the app-issued read handle.","name":"macscope_workspace_summary_v1","parameters":{"additionalProperties":false,"properties":{"handle_id":{"enum":["00000000-0000-0000-0000-000000000001"],"type":"string"}},"required":["handle_id"],"type":"object"}},"type":"function"}],"top_p":1}
        """#

        XCTAssertEqual(data, Data(expected.utf8))
    }

    func testFinalizationBodyMatchesFrozenCanonicalBytesAndKeyInventory() throws {
        let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: "local/model",
            systemPrompt: "system",
            userPrompt: #"{"phase":"finalization"}"#,
            maximumTokens: 512,
            phase: .finalization,
            generationVariant: .productionV1
        ))
        XCTAssertEqual(data, try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: "local/model",
            systemPrompt: "system",
            userPrompt: #"{"phase":"finalization"}"#,
            maximumTokens: 512,
            phase: .finalization,
            generationVariant: .productionV1
        )))

        let object = try Phase2StrictJSONParser().parse(data)
        assertKeys(object, [
            "max_tokens", "messages", "model", "parallel_tool_calls", "response_format",
            "stream", "stream_options", "temperature", "tool_choice", "tools",
        ])
        let messages = try XCTUnwrap(object.objectValue?["messages"]?.arrayValue)
        XCTAssertEqual(messages.count, 2)
        assertKeys(messages[0], ["content", "role"])
        assertKeys(messages[1], ["content", "role"])
        assertKeys(try XCTUnwrap(object.objectValue?["stream_options"]), ["include_usage"])
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["temperature"] as? NSNumber, 0)
        XCTAssertNil(json["top_p"])
        XCTAssertNil(object.objectValue?["seed"])
        XCTAssertNil(object.objectValue?["stop"])

        XCTAssertEqual(object.objectValue?["parallel_tool_calls"]?.boolValue, false)
        XCTAssertEqual(object.objectValue?["tool_choice"]?.stringValue, "auto")
        let tools = try XCTUnwrap(object.objectValue?["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 2)
        assertKeys(tools[0], ["function", "type"])
        assertKeys(tools[1], ["function", "type"])
        let toolFunctions = try tools.map {
            try XCTUnwrap($0.objectValue?["function"])
        }
        for toolFunction in toolFunctions {
            assertKeys(toolFunction, ["description", "name", "parameters", "strict"])
        }
        let toolNames = toolFunctions.compactMap { $0.objectValue?["name"]?.stringValue }
        XCTAssertEqual(
            toolNames,
            [
                "macscope_stage_shell_proposal_v1",
                "macscope_stage_debugger_action_proposal_v1",
            ]
        )
        XCTAssertTrue(toolFunctions.allSatisfy { $0.objectValue?["strict"]?.boolValue == true })
        let shellFunction = toolFunctions[0]
        let debuggerFunction = toolFunctions[1]
        let toolParameters = try XCTUnwrap(shellFunction.objectValue?["parameters"])
        assertKeys(toolParameters, ["additionalProperties", "properties", "required", "type"])
        let toolProperties = try XCTUnwrap(toolParameters.objectValue?["properties"])
        assertKeys(toolProperties, [
            "arguments", "environment", "executable_path", "execution_surface",
            "maximum_output_bytes", "requested_effects", "timeout_milliseconds",
            "working_directory_path",
        ])
        let debuggerParameters = try XCTUnwrap(debuggerFunction.objectValue?["parameters"])
        assertKeys(debuggerParameters, ["additionalProperties", "properties", "required", "type"])
        let debuggerProperties = try XCTUnwrap(debuggerParameters.objectValue?["properties"])
        assertKeys(debuggerProperties, [
            "action", "event_sequence", "lifecycle_revision", "requested_authority",
            "session_id", "stop_revision",
        ])
        let responseFormat = try XCTUnwrap(object.objectValue?["response_format"])
        assertKeys(responseFormat, ["json_schema", "type"])
        let jsonSchema = try XCTUnwrap(responseFormat.objectValue?["json_schema"])
        assertKeys(jsonSchema, ["name", "schema", "strict"])
        XCTAssertEqual(jsonSchema.objectValue?["name"]?.stringValue, "macscope_grounded_final_v1")
        XCTAssertEqual(jsonSchema.objectValue?["strict"]?.boolValue, true)
        let schema = try XCTUnwrap(jsonSchema.objectValue?["schema"])
        assertKeys(schema, ["additionalProperties", "properties", "required", "type"])
        let properties = try XCTUnwrap(schema.objectValue?["properties"])
        assertKeys(properties, ["evidence_ids", "kind", "reason", "text"])
        let evidenceIDs = try XCTUnwrap(properties.objectValue?["evidence_ids"])
        assertKeys(evidenceIDs, ["items", "maxItems", "type", "uniqueItems"])
        assertKeys(try XCTUnwrap(evidenceIDs.objectValue?["items"]), ["maxLength", "minLength", "type"])
        assertKeys(try XCTUnwrap(properties.objectValue?["kind"]), ["enum", "type"])
        assertKeys(try XCTUnwrap(properties.objectValue?["reason"]), ["maxLength", "type"])
        assertKeys(try XCTUnwrap(properties.objectValue?["text"]), ["maxLength", "type"])
    }

    func testProductionBodiesAreByteStableAndInjectionSafe() throws {
        let input = Phase2OpenAIProductionChatRequestInput(
            model: "model",
            systemPrompt: #"sys\"},\"tools\":[]"#,
            userPrompt: "user\n\"}],\"stream\":false",
            maximumTokens: 1,
            phase: .toolSelection(handles: [handle]),
            generationVariant: .productionV1
        )
        let first = try Phase2OpenAIChatRequestEncoder().encodeProduction(input)
        let second = try Phase2OpenAIChatRequestEncoder().encodeProduction(input)
        XCTAssertEqual(first, second)
        let object = try Phase2StrictJSONParser().parse(first)
        let messages = object.objectValue?["messages"]?.arrayValue
        XCTAssertEqual(messages?[0].objectValue?["content"]?.stringValue, input.systemPrompt)
        XCTAssertEqual(messages?[1].objectValue?["content"]?.stringValue, input.userPrompt)
        XCTAssertEqual(object.objectValue?["stream"]?.boolValue, true)
    }

    func testRejectsInvalidSelectionHandleSetsBeforeEncoding() throws {
        let encoder = Phase2OpenAIChatRequestEncoder()
        XCTAssertThrowsError(try encoder.encodeProduction(.init(
            model: "model", systemPrompt: "sys", userPrompt: "usr", maximumTokens: 1,
            phase: .toolSelection(handles: []), generationVariant: .productionV1
        ))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatRequestEncodingError, .invalidToolHandles)
        }
        XCTAssertThrowsError(try encoder.encodeProduction(.init(
            model: "model", systemPrompt: "sys", userPrompt: "usr", maximumTokens: 1,
            phase: .toolSelection(handles: [.init(handleID: handle.handleID, operationID: "bad")]),
            generationVariant: .productionV1
        ))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatRequestEncodingError, .invalidToolHandles)
        }
    }

    func testDefaultRequestLimitsAcceptMaximumEscapedUserPromptAndRejectMaximumPlusOne() throws {
        let maximum = String(
            repeating: "\"",
            count: Phase2ProductionPromptLimits.maximumEncodedUserPromptBytes
        )
        XCTAssertNoThrow(try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: "model",
            systemPrompt: "system",
            userPrompt: maximum,
            maximumTokens: 1,
            phase: .finalization,
            generationVariant: .productionV1
        )))

        let maximumPlusOne = maximum + "\""
        XCTAssertThrowsError(try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: "model",
            systemPrompt: "system",
            userPrompt: maximumPlusOne,
            maximumTokens: 1,
            phase: .finalization,
            generationVariant: .productionV1
        ))) {
            XCTAssertEqual($0 as? Phase2OpenAIChatRequestEncodingError, .userPromptByteLimitExceeded)
        }
    }

    private func assertKeys(
        _ value: Phase2ProductionJSONValue,
        _ expected: Set<String>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let object = value.objectValue else {
            XCTFail("Expected an object", file: file, line: line)
            return
        }
        XCTAssertEqual(Set(object.keys), expected, file: file, line: line)
    }
}
