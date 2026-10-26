import Foundation
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

struct Phase2OpenAIChatRequestInput: Equatable, Sendable {
    let model: String
    let systemPrompt: String
    let userPrompt: String
    let maximumTokens: Int
    let inferencePolicy: Phase2LocalInferencePolicy?

    init(model: String, systemPrompt: String, userPrompt: String, maximumTokens: Int,
         inferencePolicy: Phase2LocalInferencePolicy? = nil) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maximumTokens = maximumTokens
        self.inferencePolicy = inferencePolicy
    }
}

enum Phase2OpenAIProductionChatPhase: Equatable, Sendable {
    case toolSelection(handles: [Phase2ProductionToolHandle])
    case finalization
    case shellContinuation
}

enum Phase2OpenAIShellProposalFunctionTool {
    static let functionName = "macscope_stage_shell_proposal_v1"

    static let openAIJSONValue: Phase2ProductionJSONValue = .object([
        "function": .object([
            "description": .string(
                "Stage one inert shell command proposal for MacScope human review. "
                    + "This does not execute the command."
            ),
            "name": .string(functionName),
            "parameters": .object([
                "additionalProperties": .bool(false),
                "properties": .object([
                    "arguments": .object([
                        "items": .object(["maxLength": .integer(4096), "type": .string("string")]),
                        "maxItems": .integer(64),
                        "type": .string("array"),
                    ]),
                    "environment": .object([
                        "items": .object([
                            "additionalProperties": .bool(false),
                            "properties": .object([
                                "key": .object([
                                    "maxLength": .integer(256),
                                    "minLength": .integer(1),
                                    "type": .string("string"),
                                ]),
                                "value": .object([
                                    "maxLength": .integer(4096),
                                    "type": .string("string"),
                                ]),
                            ]),
                            "required": .array([.string("key"), .string("value")]),
                            "type": .string("object"),
                        ]),
                        "maxItems": .integer(64),
                        "type": .string("array"),
                    ]),
                    "executable_path": .object([
                        "maxLength": .integer(4096),
                        "minLength": .integer(1),
                        "type": .string("string"),
                    ]),
                    "execution_surface": .object([
                        "enum": .array([
                            .string("restrictedOneShotJob"),
                            .string("shellBrokerPTY"),
                        ]),
                        "type": .string("string"),
                    ]),
                    "maximum_output_bytes": .object([
                        "maximum": .integer(1_048_576),
                        "minimum": .integer(1),
                        "type": .string("integer"),
                    ]),
                    "requested_effects": .object([
                        "items": .object([
                            "enum": .array([.string("A5")]),
                            "type": .string("string"),
                        ]),
                        "maxItems": .integer(1),
                        "minItems": .integer(1),
                        "type": .string("array"),
                        "uniqueItems": .bool(true),
                    ]),
                    "timeout_milliseconds": .object([
                        "maximum": .integer(120_000),
                        "minimum": .integer(1),
                        "type": .string("integer"),
                    ]),
                    "working_directory_path": .object([
                        "maxLength": .integer(4096),
                        "type": .string("string"),
                    ]),
                ]),
                "required": .array([
                    .string("executable_path"),
                    .string("arguments"),
                    .string("environment"),
                    .string("working_directory_path"),
                    .string("timeout_milliseconds"),
                    .string("maximum_output_bytes"),
                    .string("execution_surface"),
                    .string("requested_effects"),
                ]),
                "type": .string("object"),
            ]),
            "strict": .bool(true),
        ]),
        "type": .string("function"),
    ])
}

enum Phase2OpenAIDebuggerActionProposalFunctionTool {
    static let functionName = "macscope_stage_debugger_action_proposal_v1"

    static let openAIJSONValue: Phase2ProductionJSONValue = .object([
        "function": .object([
            "description": .string(
                "Stage one inert debugger run-control proposal for MacScope human review. "
                    + "This does not execute a debugger action."
            ),
            "name": .string(functionName),
            "parameters": .object([
                "additionalProperties": .bool(false),
                "properties": .object([
                    "action": .object([
                        "enum": .array([
                            .string("continueExecution"),
                            .string("stepOver"),
                            .string("stepInto"),
                            .string("stepOut"),
                            .string("pause"),
                            .string("refreshSnapshot"),
                        ]),
                        "type": .string("string"),
                    ]),
                    "event_sequence": .object([
                        "maximum": .integer(Int(Int32.max)),
                        "minimum": .integer(1),
                        "type": .string("integer"),
                    ]),
                    "lifecycle_revision": .object([
                        "maximum": .integer(Int(Int32.max)),
                        "minimum": .integer(1),
                        "type": .string("integer"),
                    ]),
                    "requested_authority": .object([
                        "enum": .array([.string("controlledRuntimeActions")]),
                        "type": .string("string"),
                    ]),
                    "session_id": .object([
                        "maxLength": .integer(36),
                        "minLength": .integer(36),
                        "type": .string("string"),
                    ]),
                    "stop_revision": .object([
                        "maximum": .integer(Int(Int32.max)),
                        "minimum": .integer(0),
                        "type": .string("integer"),
                    ]),
                ]),
                "required": .array([
                    .string("action"),
                    .string("session_id"),
                    .string("lifecycle_revision"),
                    .string("stop_revision"),
                    .string("event_sequence"),
                    .string("requested_authority"),
                ]),
                "type": .string("object"),
            ]),
            "strict": .bool(true),
        ]),
        "type": .string("function"),
    ])
}

/// Closed request controls selected by the already-accepted inference protocol version.
enum Phase2OpenAIRequestGenerationVariant: Equatable, Sendable {
    case productionV1
    case stagedV2
    case assistantR4
}

struct Phase2OpenAIProductionChatRequestInput: Equatable, Sendable {
    let model: String
    let systemPrompt: String
    let userPrompt: String
    let maximumTokens: Int
    let inferencePolicy: Phase2LocalInferencePolicy?
    let phase: Phase2OpenAIProductionChatPhase
    let generationVariant: Phase2OpenAIRequestGenerationVariant
    /// Live Assistant finalization may stage inert human-review proposals. Frozen
    /// qualification fixtures predate that additive surface and remain tool-free.
    let allowsFinalizationProposalTools: Bool
    let conversationContext: Phase2ProductionConversationContext?

    init(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        maximumTokens: Int,
        phase: Phase2OpenAIProductionChatPhase,
        generationVariant: Phase2OpenAIRequestGenerationVariant,
        allowsFinalizationProposalTools: Bool = true,
        conversationContext: Phase2ProductionConversationContext? = nil,
        inferencePolicy: Phase2LocalInferencePolicy? = nil
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maximumTokens = maximumTokens
        self.inferencePolicy = inferencePolicy
        self.phase = phase
        self.generationVariant = generationVariant
        self.allowsFinalizationProposalTools = allowsFinalizationProposalTools
        self.conversationContext = conversationContext
    }
}

struct Phase2OpenAIChatRequestLimits: Equatable, Sendable {
    let maximumSystemPromptBytes: Int
    let maximumUserPromptBytes: Int
    let maximumEncodedBodyBytes: Int

    init(
        maximumSystemPromptBytes: Int = 65_536,
        maximumUserPromptBytes: Int = Phase2ProductionPromptLimits.maximumEncodedUserPromptBytes,
        maximumEncodedBodyBytes: Int = Phase2ProductionPromptLimits.maximumEncodedRequestBodyBytes
    ) {
        precondition(maximumSystemPromptBytes >= 0)
        precondition(maximumUserPromptBytes >= 0)
        precondition(maximumEncodedBodyBytes >= 0)
        self.maximumSystemPromptBytes = maximumSystemPromptBytes
        self.maximumUserPromptBytes = maximumUserPromptBytes
        self.maximumEncodedBodyBytes = maximumEncodedBodyBytes
    }
}

enum Phase2OpenAIChatRequestEncodingError: Error, Equatable, Sendable {
    case invalidModel
    case emptySystemPrompt
    case systemPromptByteLimitExceeded
    case emptyUserPrompt
    case userPromptByteLimitExceeded
    case invalidMaximumTokens
    case invalidToolHandles
    case invalidConversationContext
    case encodedBodyByteLimitExceeded
    case encodingFailed
    case contextBudgetExceeded(estimatedInputTokens: Int, availableInputTokens: Int)
}

struct Phase2OpenAIChatRequestEncoder: Sendable {
    private let limits: Phase2OpenAIChatRequestLimits

    init(limits: Phase2OpenAIChatRequestLimits = .init()) {
        self.limits = limits
    }

    func encode(_ input: Phase2OpenAIChatRequestInput) throws -> Data {
        try validate(input)

        var object: [String: Any] = [
            "max_tokens": input.maximumTokens,
            "messages": [
                ["content": input.systemPrompt, "role": "system"],
                ["content": input.userPrompt, "role": "user"]
            ],
            "model": input.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": 0
        ]

        if let policy = input.inferencePolicy {
            try applyPolicy(policy, to: &object, maximumTokens: input.maximumTokens)
        }
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw Phase2OpenAIChatRequestEncodingError.encodingFailed
        }
        guard data.count <= limits.maximumEncodedBodyBytes else {
            throw Phase2OpenAIChatRequestEncodingError.encodedBodyByteLimitExceeded
        }
        return data
    }

    /// Encodes one closed request variant. The phase and accepted protocol variant own every
    /// optional provider field; callers cannot inject arbitrary generation controls.
    func encodeProduction(_ input: Phase2OpenAIProductionChatRequestInput) throws -> Data {
        try validate(.init(
            model: input.model,
            systemPrompt: input.systemPrompt,
            userPrompt: input.userPrompt,
            maximumTokens: input.maximumTokens,
            inferencePolicy: input.inferencePolicy
        ))

        var messages: [Phase2ProductionJSONValue] = [
            .object(["content": .string(input.systemPrompt), "role": .string("system")]),
        ]
        if let history = input.conversationContext {
            guard input.phase == .finalization || input.phase == .shellContinuation,
                  history.isValid else {
                throw Phase2OpenAIChatRequestEncodingError.invalidConversationContext
            }
            if history.omittedTurnCount > 0 {
                messages.append(.object([
                    "content": .string("\(history.omittedTurnCount) earlier completed conversation turns were omitted by the bounded retention policy."),
                    "role": .string("system"),
                ]))
            }
            for turn in history.turns {
                messages.append(.object(["content": .string(turn.user), "role": .string("user")]))
                messages.append(.object(["content": .string(turn.assistant), "role": .string("assistant")]))
            }
        }
        messages.append(.object(["content": .string(input.userPrompt), "role": .string("user")]))

        var object: [String: Phase2ProductionJSONValue] = [
            "max_tokens": .integer(input.maximumTokens),
            "messages": .array(messages),
            "model": .string(input.model),
            "stream": .bool(true),
            "stream_options": .object(["include_usage": .bool(true)]),
            "temperature": .integer(0),
        ]

        switch input.generationVariant {
        case .productionV1:
            break
        case .stagedV2:
            object["top_p"] = .integer(1)
        case .assistantR4:
            object["top_p"] = .integer(1)
        }

        switch input.phase {
        case .toolSelection(let handles):
            let tools: [Phase2ProductionProjectedTool]
            do {
                let version: Phase2ProductionToolRegistry.Version = handles.contains {
                    $0.operationID.hasPrefix("debugger.") || $0.operationID.hasPrefix("rea.")
                } ? .assistantR2 : .qualificationR1
                tools = try Phase2ProductionToolRegistry(version: version).project(handles)
            } catch {
                throw Phase2OpenAIChatRequestEncodingError.invalidToolHandles
            }
            object["parallel_tool_calls"] = .bool(true)
            object["tool_choice"] = .string("required")
            object["tools"] = .array(tools.map(\.openAIJSONValue))
        case .finalization:
            let proposalOffer = Phase2GroundedFinalProposal.offer(inUserPrompt: input.userPrompt)
            object["response_format"] = .object([
                "json_schema": .object([
                    "name": .string(Phase2GroundedFinalSchema.providerName),
                    "schema": Phase2GroundedFinalSchema.schema(
                        proposalOperations: proposalOffer.operations,
                        anchored: proposalOffer.anchored
                    ).canonicalJSONValue(),
                    "strict": .bool(true),
                ]),
                "type": .string("json_schema"),
            ])
            if input.allowsFinalizationProposalTools {
                object["parallel_tool_calls"] = .bool(false)
                object["tool_choice"] = .string("auto")
                object["tools"] = .array([
                    Phase2OpenAIShellProposalFunctionTool.openAIJSONValue,
                    Phase2OpenAIDebuggerActionProposalFunctionTool.openAIJSONValue,
                ])
            }
        case .shellContinuation:
            guard !input.allowsFinalizationProposalTools else {
                throw Phase2OpenAIChatRequestEncodingError.invalidToolHandles
            }
            object["response_format"] = .object([
                "json_schema": .object([
                    "name": .string(Phase2GroundedFinalSchema.providerName),
                    "schema": Phase2GroundedFinalSchema.schema.canonicalJSONValue(),
                    "strict": .bool(true),
                ]),
                "type": .string("json_schema"),
            ])
        }

        let data: Data
        if let policy = input.inferencePolicy {
            guard var plain = try JSONSerialization.jsonObject(with: Phase2ProductionJSONValue.object(object).canonicalJSONBytes()) as? [String: Any] else {
                throw Phase2OpenAIChatRequestEncodingError.encodingFailed
            }
            try applyPolicy(policy, to: &plain, maximumTokens: input.maximumTokens)
            if let messages = plain["messages"] as? [[String: Any]],
               let system = messages.first?["content"] as? String,
               system.utf8.count > limits.maximumSystemPromptBytes {
                throw Phase2OpenAIChatRequestEncodingError.systemPromptByteLimitExceeded
            }
            data = try JSONSerialization.data(withJSONObject: plain, options: [.sortedKeys, .withoutEscapingSlashes])
        } else {
            data = Phase2ProductionJSONValue.object(object).canonicalJSONBytes()
        }
        guard data.count <= limits.maximumEncodedBodyBytes else {
            throw Phase2OpenAIChatRequestEncodingError.encodedBodyByteLimitExceeded
        }
        return data
    }

    /// Conservative upper bound: UTF-8 bytes, including rendered tool/schema/history text,
    /// never undercounts ordinary tokenizer input. This is explicitly an estimate, not tokenizer evidence.
    static func admitContext(body: [String: Any], policy: Phase2LocalInferencePolicy,
                             maximumTokens: Int) throws {
        guard policy.isValid else { throw Phase2OpenAIChatRequestEncodingError.invalidMaximumTokens }
        let prompt: [String: Any] = ["messages": body["messages"] ?? [],
                                     "tools": body["tools"] ?? [],
                                     "response_format": body["response_format"] ?? [:]]
        let estimated = try JSONSerialization.data(withJSONObject: prompt, options: [.sortedKeys]).count
        let available = max(0, policy.effectiveContextTokens - maximumTokens - 2_048)
        guard estimated <= available else {
            throw Phase2OpenAIChatRequestEncodingError.contextBudgetExceeded(
                estimatedInputTokens: estimated, availableInputTokens: available)
        }
    }

    static func applyMTPLXPolicy(_ policy: Phase2LocalInferencePolicy,
                                to object: inout [String: Any], maximumTokens: Int) throws {
        // Sampling, reasoning and thinking defer to the MTPLX app's per-model settings unless
        // the user chose a MacScope override. MTP depth is never fixed here; MTPLX uses its tuned depth.
        for key in ["temperature", "top_p", "top_k", "presence_penalty", "frequency_penalty",
                    "reasoning_effort", "depth", "enable_thinking", "chat_template_kwargs"] {
            object.removeValue(forKey: key)
        }
        if let sampling = policy.sampling {
            object["temperature"] = sampling.temperature
            object["top_p"] = sampling.topP
            object["top_k"] = sampling.topK
            object["reasoning_effort"] = policy.reasoningEffort.rawValue
            object["enable_thinking"] = policy.enableThinking
        }
        object["generation_mode"] = "mtp"
        if var format = object["response_format"] as? [String: Any],
           var wrapper = format["json_schema"] as? [String: Any],
           let schema = wrapper["schema"] {
            // MTPLX 2.12.2's llguidance rejects uniqueItems before inference. Project only
            // that unsupported grammar keyword; the canonical MacScope schema, prompt,
            // duplicate-citation checks, and final evidence validation remain authoritative.
            if wrapper["name"] as? String == Phase2GroundedFinalSchema.providerName {
                try appendMTPLXGroundedFinalContract(
                    to: &object,
                    proposalOffer: groundedFinalProposalOffer(in: schema)
                )
            }
            wrapper["schema"] = mtplxGrammarProjection(schema)
            format["json_schema"] = wrapper
            object["response_format"] = format
        }
        try admitContext(body: object, policy: policy, maximumTokens: maximumTokens)
    }

    /// The provider grammar describes field types, while the app decoder also enforces
    /// conditional field semantics. Make those existing requirements explicit for MTPLX.
    private static func appendMTPLXGroundedFinalContract(
        to object: inout [String: Any],
        proposalOffer: Phase2GroundedFinalProposal.Offer
    ) throws {
        guard var messages = object["messages"] as? [[String: Any]],
              !messages.isEmpty, messages[0]["role"] as? String == "system",
              let system = messages[0]["content"] as? String else {
            throw Phase2OpenAIChatRequestEncodingError.encodingFailed
        }
        let proposalOperations = proposalOffer.operations
        let finalSchema = Phase2GroundedFinalSchema.schema(
            proposalOperations: proposalOperations,
            anchored: proposalOffer.anchored
        )
        let schema = String(decoding: finalSchema.canonicalJSONBytes(), as: UTF8.self)
        let fields = proposalOperations.isEmpty
            ? "kind, text, evidence_ids, and reason"
            : "kind, text, evidence_ids, reason, and proposal"
        let proposalShape = """
        {"operation","value","evidence_id"} with an allowed operation (\(proposalOperations.joined(separator: ", "))), a concrete nonempty value, and the evidence_id from proposal_protocol copied exactly; also list that evidence_id in evidence_ids
        """
        let proposalRules: String
        if proposalOperations.isEmpty {
            proposalRules = ""
        } else if proposalOffer.anchored {
            proposalRules = """

            proposal_protocol requires one inert authoring proposal, carried only in the proposal field, which is never null. For kind answer: set proposal to \(proposalShape). Never write a proposal envelope into text. For kind insufficient_evidence: the app ignores proposal.
            """
        } else {
            proposalRules = """

            proposal_protocol allows one inert authoring proposal, carried only in the proposal field. For kind answer: set proposal to \(proposalShape). Set proposal to null only when the evidence supports no allowed proposal. Never write a proposal envelope into text. For kind insufficient_evidence: proposal must be null.
            """
        }
        let contract = """


        [macscope.mtplx-grounded-final-contract.v1]
        Return exactly one JSON object with only \(fields).
        For kind answer: text must be nonempty, reason must be the empty string "", and evidence_ids must contain one to three distinct exact allowed app-issued evidence IDs. Copy each ID exactly as provided in allowed_evidence_ids, preserving uppercase letters; never invent, escape, or transform an ID.
        For kind insufficient_evidence: text must be the empty string "", evidence_ids must be [], and reason must be nonempty.
        The reason field is reserved for insufficient_evidence. An answer must never include an explanation in reason; put its grounded explanation only in text.\(proposalRules)
        Canonical application schema (including application-enforced uniqueness):
        \(schema)
        """
        messages[0]["content"] = system + contract
        object["messages"] = messages
    }

    /// The proposal offer a grounded final schema encodes, read from the schema itself: a
    /// `proposal` that is directly an object is anchored, one under `anyOf` with null is not.
    private static func groundedFinalProposalOffer(in schema: Any) -> Phase2GroundedFinalProposal.Offer {
        guard let properties = (schema as? [String: Any])?["properties"] as? [String: Any],
              let property = properties["proposal"] as? [String: Any]
        else { return .none }
        let anchored = property["type"] as? String == "object"
        let branches = anchored ? [property] : (property["anyOf"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        guard let proposal = branches.first(where: { $0["type"] as? String == "object" }),
              let operation = (proposal["properties"] as? [String: Any])?["operation"] as? [String: Any],
              let operations = operation["enum"] as? [String]
        else { return .none }
        return .init(operations: operations, anchored: anchored)
    }

    private static func mtplxGrammarProjection(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            if object["type"] as? String == "array" { object.removeValue(forKey: "uniqueItems") }
            for (key, child) in object { object[key] = mtplxGrammarProjection(child) }
            return object
        }
        if let array = value as? [Any] { return array.map(mtplxGrammarProjection) }
        return value
    }

    private func applyPolicy(_ policy: Phase2LocalInferencePolicy,
                             to object: inout [String: Any], maximumTokens: Int) throws {
        try Self.applyMTPLXPolicy(policy, to: &object, maximumTokens: maximumTokens)
    }

    private func validate(_ input: Phase2OpenAIChatRequestInput) throws {
        let modelBytes = input.model.utf8
        guard !modelBytes.isEmpty,
              modelBytes.count <= 512,
              !modelBytes.contains(where: { $0 <= 0x1F || $0 == 0x7F }) else {
            throw Phase2OpenAIChatRequestEncodingError.invalidModel
        }

        guard !input.systemPrompt.isEmpty else {
            throw Phase2OpenAIChatRequestEncodingError.emptySystemPrompt
        }
        guard input.systemPrompt.utf8.count <= limits.maximumSystemPromptBytes else {
            throw Phase2OpenAIChatRequestEncodingError.systemPromptByteLimitExceeded
        }
        guard !input.userPrompt.isEmpty else {
            throw Phase2OpenAIChatRequestEncodingError.emptyUserPrompt
        }
        guard input.userPrompt.utf8.count <= limits.maximumUserPromptBytes else {
            throw Phase2OpenAIChatRequestEncodingError.userPromptByteLimitExceeded
        }
        guard (1...(input.inferencePolicy == nil ? 8_192 : 16_384)).contains(input.maximumTokens) else {
            throw Phase2OpenAIChatRequestEncodingError.invalidMaximumTokens
        }
    }
}
