import Foundation
import XCTest
@testable import MacScope

final class Phase2MTPLXIntegrationTests: XCTestCase {
    private let policy = Phase2LocalInferencePolicy()

    @MainActor
    func testProductionDefaultIsDesiredIntentAndStoredChoiceWins() throws {
        let quality = try Phase2LocalAIProviderPreference.mtplxQualityDefault()
        let defaults = Phase2LocalAIProviderController(defaultPreference: quality)
        XCTAssertEqual(defaults.snapshot.endpoint?.endpointOrigin, "http://127.0.0.1:8000")
        XCTAssertEqual(defaults.snapshot.desiredSelection?.maximumTokens, 16_384)
        XCTAssertEqual(defaults.snapshot.endpoint?.inferencePolicy, policy)
        XCTAssertNil(defaults.snapshot.selection)
        XCTAssertNil(defaults.captureReadyInferenceLease())
        let storedChoice = try Phase2LocalAIProviderPreference(endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 30_000,
            desiredSelection: nil, inferencePolicy: policy)
        let restored = Phase2LocalAIProviderController(preferenceStore:
            InMemoryPhase2LocalAIProviderPreferenceStore(initialPreference: storedChoice), defaultPreference: quality)
        XCTAssertEqual(restored.snapshot.endpoint?.endpointOrigin, "http://127.0.0.1:1234")
        XCTAssertEqual(restored.snapshot.endpoint?.inferencePolicy, policy)
        XCTAssertFalse(restored.hasUnsupportedProviderConfiguration)
        let explicit = try Phase2LocalProviderEndpoint(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:4321", requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 30_000, inferencePolicy: policy)
        let configured = Phase2LocalAIProviderController(endpoint: explicit, defaultPreference: quality)
        XCTAssertEqual(configured.snapshot.endpoint, explicit)
        XCTAssertNil(configured.snapshot.desiredSelection)
    }

    @MainActor
    func testLegacyStoredChoiceRemainsInertAndPreservedWithoutDefaultFallback() async throws {
        let suite = "MTPLX-legacy-inert-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPhase2LocalAIProviderPreferenceStore(defaults: defaults)
        let legacy = try Phase2LocalAIProviderPreference(endpointOrigin: "http://127.0.0.1:1234",
            requestTimeoutMilliseconds: 10_000, resourceTimeoutMilliseconds: 30_000,
            desiredSelection: nil)
        store.save(legacy)
        let key = UserDefaultsPhase2LocalAIProviderPreferenceStore.storageKey
        let originalBytes = try XCTUnwrap(defaults.data(forKey: key))
        let controller = Phase2LocalAIProviderController(preferenceStore: store,
            defaultPreference: try .mtplxQualityDefault())

        XCTAssertNil(controller.snapshot.endpoint, "Legacy presence must not silently select the MTPLX default")
        XCTAssertNil(controller.snapshot.desiredSelection)
        XCTAssertNil(controller.snapshot.selection)
        XCTAssertNil(controller.captureReadyInferenceLease())
        XCTAssertTrue(controller.hasUnsupportedProviderConfiguration)
        XCTAssertTrue(store.hasStoredPreference)
        XCTAssertEqual(defaults.data(forKey: key), originalBytes)
        do {
            _ = try await controller.refresh()
            XCTFail("An inert legacy profile must not probe a provider")
        } catch {
            XCTAssertEqual(error as? Phase2LocalAIProviderControllerError, .unsupportedProvider)
        }
        XCTAssertEqual(defaults.data(forKey: key), originalBytes, "Rejected activation must not convert or delete the stored profile")
    }

    func testPreferencesAndWorkerConfigurationCarryQualityControlsWithoutChangingLegacyCaps() throws {
        let endpoint = try makeEndpoint()
        let desired = try Phase2LocalAIDesiredSelection(
            modelKey: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
            maximumTokens: 16_384, inferencePolicy: policy)
        XCTAssertThrowsError(try Phase2LocalAIDesiredSelection(modelKey: desired.modelKey, maximumTokens: 16_384))
        let suite = "MTPLX-regression-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPhase2LocalAIProviderPreferenceStore(defaults: defaults)
        let preference = try Phase2LocalAIProviderPreference(
            endpointOrigin: endpoint.endpointOrigin, requestTimeoutMilliseconds: 300_000,
            resourceTimeoutMilliseconds: 1_800_000, desiredSelection: desired, inferencePolicy: policy)
        store.save(preference)
        XCTAssertEqual(store.load(), preference)
        let config = try Phase2AIProviderConfiguration(endpoint: endpoint, model: desired.modelKey,
                                                       maximumTokens: desired.maximumTokens)
        let wire = try Phase2AIWorkerConfigurationWireCodec().decodeConfiguration(
            Phase2AIWorkerConfigurationAppCodec().encodeConfiguration(config,
                protocolBundle: Phase2AIWorkerProductionProtocol.assistantR4))
        XCTAssertEqual(wire.inferencePolicy, policy)
        XCTAssertEqual(wire.maximumTokens, 16_384)
        XCTAssertEqual(wire.resourceTimeoutMilliseconds, 1_800_000)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Phase2AIWorkerConfigurationWireCodec().encodeConfiguration(wire)) as? [String: Any])
        var controls = try XCTUnwrap(object["inferencePolicy"] as? [String: Any])
        controls["arbitraryAuthority"] = true
        object["inferencePolicy"] = controls
        XCTAssertThrowsError(try Phase2AIWorkerConfigurationWireCodec().decodeConfiguration(
            JSONSerialization.data(withJSONObject: object)))
    }

    func testHTTPEncodingDefersSamplingToMTPLXAndSendsOneTokenLimit() throws {
        let body = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
            systemPrompt: "Explain only supplied evidence.", userPrompt: "Known disassembly fixture",
            maximumTokens: 16_384, phase: .finalization, generationVariant: .assistantR4,
            inferencePolicy: policy))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        for key in ["temperature", "top_p", "top_k", "presence_penalty", "frequency_penalty",
                    "reasoning_effort", "depth", "enable_thinking", "chat_template_kwargs"] {
            XCTAssertNil(json[key], "MTPLX mode must leave \(key) to the model's MTPLX settings")
        }
        XCTAssertEqual(json["generation_mode"] as? String, "mtp")
        XCTAssertEqual(json["max_tokens"] as? Int, 16_384)
        XCTAssertNil(json["max_completion_tokens"])
        XCTAssertNil(json["extra_body"])
        XCTAssertNil(json["chat_template_kwargs"])
        XCTAssertNotNil(json["response_format"])
    }

    func testMTPLXProjectsUnsupportedGrammarKeywordWithoutChangingCanonicalSchemaOrProposalTools() throws {
        func body(policy: Phase2LocalInferencePolicy?) throws -> [String: Any] {
            let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
                model: "validated", systemPrompt: "system", userPrompt: "user", maximumTokens: 128,
                phase: .finalization, generationVariant: .assistantR4, inferencePolicy: policy))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func evidenceArray(_ body: [String: Any]) throws -> [String: Any] {
            let format = try XCTUnwrap(body["response_format"] as? [String: Any])
            let wrapper = try XCTUnwrap(format["json_schema"] as? [String: Any])
            let schema = try XCTUnwrap(wrapper["schema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            return try XCTUnwrap(properties["evidence_ids"] as? [String: Any])
        }
        let legacy = try body(policy: nil)
        let mtplx = try body(policy: policy)
        XCTAssertEqual(try evidenceArray(legacy)["uniqueItems"] as? Bool, true)
        let projected = try evidenceArray(mtplx)
        XCTAssertNil(projected["uniqueItems"])
        XCTAssertEqual(projected["maxItems"] as? Int, 3)
        XCTAssertEqual(projected["type"] as? String, "array")
        XCTAssertEqual(mtplx["tool_choice"] as? String, "auto")
        XCTAssertEqual((mtplx["tools"] as? [Any])?.count, 2)
        // Re-encode legacy after projection: no mutation of the frozen app schema is allowed.
        XCTAssertEqual(try evidenceArray(body(policy: nil))["uniqueItems"] as? Bool, true)
    }

    func testMTPLXFinalContractPreservesLegacyPromptAndAppliesToContinuation() throws {
        let schema = String(decoding: Phase2GroundedFinalSchema.schema.canonicalJSONBytes(), as: UTF8.self)
        for phase: Phase2OpenAIProductionChatPhase in [.finalization, .shellContinuation] {
            for controls: Phase2LocalInferencePolicy? in [nil, policy] {
                let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
                    model: "validated", systemPrompt: "original system", userPrompt: "user", maximumTokens: 128,
                    phase: phase, generationVariant: .assistantR4,
                    allowsFinalizationProposalTools: false, inferencePolicy: controls))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                let system = try XCTUnwrap(messages.first?["content"] as? String)
                if controls == nil {
                    XCTAssertEqual(system, "original system")
                } else {
                    XCTAssertTrue(system.hasPrefix("original system"))
                    XCTAssertTrue(system.contains("reason must be the empty string"))
                    XCTAssertTrue(system.contains("evidence_ids must be []"))
                    XCTAssertTrue(system.contains("preserving uppercase letters"))
                    XCTAssertTrue(system.contains(schema))
                }
            }
        }
        let limited = Phase2OpenAIChatRequestEncoder(limits: .init(maximumSystemPromptBytes: 32))
        XCTAssertThrowsError(try limited.encodeProduction(.init(model: "validated",
            systemPrompt: "original system", userPrompt: "user", maximumTokens: 128,
            phase: .finalization, generationVariant: .assistantR4, inferencePolicy: policy))) { error in
            XCTAssertEqual(error as? Phase2OpenAIChatRequestEncodingError, .systemPromptByteLimitExceeded)
        }
    }

    func testProposalIsNonNullOnlyWhenTheProposalSectionNamesItsAnchor() throws {
        let anchor = UUID().uuidString
        func encoded(section: String) throws -> (proposal: [String: Any], required: [String], system: String) {
            let user = String(decoding: try JSONSerialization.data(
                withJSONObject: ["proposal_protocol": section], options: [.sortedKeys]), as: UTF8.self)
            let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
                model: "validated", systemPrompt: "system", userPrompt: user, maximumTokens: 128,
                phase: .finalization, generationVariant: .assistantR4, inferencePolicy: policy))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let format = try XCTUnwrap(body["response_format"] as? [String: Any])
            let schema = try XCTUnwrap((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
            let system = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
            return (try XCTUnwrap((schema["properties"] as? [String: Any])?["proposal"] as? [String: Any]),
                    try XCTUnwrap(schema["required"] as? [String]), system)
        }

        // Anchored: a required object with no null branch, and a contract that never offers null.
        let anchored = try encoded(section: "Propose.\nAllowed operations: comment\nProposal evidence: \(anchor)")
        XCTAssertTrue(anchored.required.contains("proposal"))
        XCTAssertNil(anchored.proposal["anyOf"])
        XCTAssertEqual(anchored.proposal["type"] as? String, "object")
        XCTAssertEqual(((anchored.proposal["properties"] as? [String: Any])?["operation"] as? [String: Any])?["enum"] as? [String], ["comment"])
        XCTAssertTrue(anchored.system.contains("which is never null"), anchored.system)
        XCTAssertFalse(anchored.system.contains("Set proposal to null"), anchored.system)

        // Unanchored: still required, but nullable.
        for section in ["Propose.\nAllowed operations: comment",
                        "Propose.\nAllowed operations: comment\nProposal evidence: \(anchor.lowercased())"] {
            let unanchored = try encoded(section: section)
            XCTAssertTrue(unanchored.required.contains("proposal"), section)
            let branches = try XCTUnwrap(unanchored.proposal["anyOf"] as? [[String: Any]], section)
            XCTAssertEqual(branches.map { $0["type"] as? String }, ["null", "object"], section)
            XCTAssertTrue(unanchored.system.contains("Set proposal to null only when"), unanchored.system)
            XCTAssertFalse(unanchored.system.contains("which is never null"), unanchored.system)
        }
    }

    func testMTPLXAddedFinalContractConsumesContextBudget() throws {
        let encoder = Phase2OpenAIChatRequestEncoder()
        let initial = try encoder.encodeProduction(.init(model: "validated", systemPrompt: "system",
            userPrompt: "u", maximumTokens: 16_384, phase: .finalization, generationVariant: .assistantR4, inferencePolicy: policy))
        var baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: initial) as? [String: Any])
        baseline["messages"] = [["role": "system", "content": "system"], ["role": "user", "content": "u"]]
        let prompt: [String: Any] = ["messages": baseline["messages"]!, "tools": baseline["tools"] ?? [],
                                    "response_format": baseline["response_format"]!]
        let baselineBytes = try JSONSerialization.data(withJSONObject: prompt, options: [.sortedKeys]).count
        let user = String(repeating: "u", count: 47_000 - baselineBytes + 1)
        baseline["messages"] = [["role": "system", "content": "system"], ["role": "user", "content": user]]
        XCTAssertNoThrow(try Phase2OpenAIChatRequestEncoder.admitContext(
            body: baseline, policy: policy, maximumTokens: 16_384))
        XCTAssertThrowsError(try encoder.encodeProduction(.init(model: "validated", systemPrompt: "system",
            userPrompt: user, maximumTokens: 16_384, phase: .finalization, generationVariant: .assistantR4, inferencePolicy: policy))) { error in
            guard case Phase2OpenAIChatRequestEncodingError.contextBudgetExceeded(let input, let available) = error else {
                return XCTFail("Expected added contract to consume budget, got \(error)")
            }
            XCTAssertGreaterThan(input, available)
            XCTAssertEqual(available, 47_104)
        }
    }

    func testContextAdmissionIncludesFullToolsAndSchemasAndDoesNotTruncate() throws {
        let body: [String: Any] = ["messages": [["role": "user", "content": "small evidence"]],
                                  "tools": [["description": String(repeating: "x", count: 50_000)]]]
        XCTAssertThrowsError(try Phase2OpenAIChatRequestEncoder.admitContext(
            body: body, policy: policy, maximumTokens: 16_384)) { error in
            guard case Phase2OpenAIChatRequestEncodingError.contextBudgetExceeded(let input, let available) = error else {
                return XCTFail("Expected explicit context outcome, got \(error)")
            }
            XCTAssertGreaterThan(input, available)
            XCTAssertEqual(available, 47_104)
        }
        XCTAssertEqual((body["tools"] as? [[String: String]])?.first?["description"]?.count, 50_000)
    }

    func testOverrideModeSendsTheMacScopeSamplingValuesButNeverADepth() throws {
        let override = policy.withSampling(.groundedDefault, reasoningEffort: .medium)
        XCTAssertTrue(override.isValid)
        let body = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
            model: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
            systemPrompt: "Explain only supplied evidence.", userPrompt: "Known disassembly fixture",
            maximumTokens: 8_192, phase: .finalization, generationVariant: .assistantR4,
            inferencePolicy: override))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["temperature"] as? Double, 0.6)
        XCTAssertEqual(json["top_p"] as? Double, 0.95)
        XCTAssertEqual(json["top_k"] as? Int, 20)
        XCTAssertEqual(json["reasoning_effort"] as? String, "medium")
        XCTAssertNil(json["depth"])
        XCTAssertEqual(json["max_tokens"] as? Int, 8_192)

        let endpoint = try Phase2LocalProviderEndpoint(
            profileID: UUID(), generation: 1, endpointOrigin: "http://127.0.0.1:8000",
            requestTimeoutMilliseconds: 300_000, resourceTimeoutMilliseconds: 1_800_000,
            inferencePolicy: override)
        let wire = try Phase2AIWorkerConfigurationWireCodec().decodeConfiguration(
            Phase2AIWorkerConfigurationAppCodec().encodeConfiguration(
                try Phase2AIProviderConfiguration(endpoint: endpoint,
                    model: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
                    maximumTokens: 8_192),
                protocolBundle: Phase2AIWorkerProductionProtocol.assistantR4))
        XCTAssertEqual(wire.inferencePolicy?.sampling, .groundedDefault)
        XCTAssertEqual(wire.maximumTokens, 8_192)
        XCTAssertFalse(Phase2LocalSamplingOverride(temperature: 3, topP: 0.95, topK: 20).isValid)
        XCTAssertEqual(Phase2LocalInferencePolicy.defaultMaximumOutputTokens, 8_192)
    }

    func testThinkingOffAndMediumAreIndependentExplicitControls() throws {
        let controls = Phase2LocalInferencePolicy(reasoningEffort: .medium, enableThinking: false,
                                                  sampling: .groundedDefault)
        let data = try Phase2OpenAIChatRequestEncoder().encode(.init(model: "validated", systemPrompt: "system",
            userPrompt: "user", maximumTokens: 16_384, inferencePolicy: controls))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["enable_thinking"] as? Bool, false)
        XCTAssertEqual(json["reasoning_effort"] as? String, "medium")
    }

    func testThinkingFlagIsSentOnlyWithAMacScopeOverride() throws {
        func body(_ policy: Phase2LocalInferencePolicy) throws -> [String: Any] {
            let data = try Phase2OpenAIChatRequestEncoder().encodeProduction(.init(
                model: "validated", systemPrompt: "system", userPrompt: "user", maximumTokens: 128,
                phase: .finalization, generationVariant: .assistantR4, inferencePolicy: policy))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        for enableThinking in [true, false] {
            let mtplx = try body(.init(enableThinking: enableThinking))
            XCTAssertNil(mtplx["enable_thinking"], "MTPLX's per-model setting decides thinking")
            XCTAssertNil(mtplx["chat_template_kwargs"])
            let override = try body(.init(enableThinking: enableThinking, sampling: .groundedDefault))
            XCTAssertEqual(override["enable_thinking"] as? Bool, enableThinking)
        }
    }

    func testInconsistentOrUnsupportedRuntimeCannotProduceCatalog() throws {
        let decoder = Phase2MTPLXModelCatalogDecoder()
        XCTAssertEqual(try decoder.decode(health: health(), models: models()).models.first?.key,
                       Phase2MTPLXQualityRuntimeExpectation.servedModelID)
        for mutation: (String, Any) in [
            ("ok", false), ("model", "a-requested-model-name"), ("model_path", "relative/pack"),
            ("generation_mode", "ar"), ("mtp_enabled", false), ("depth", 0),
            ("context_window", 262_144), ("context_window", 16_384),
            ("scheduler", ["config": ["mode": "batched", "max_active_requests": 4]]),
            ("startup", ["launch_id": "fixture-launch", "pid": 123, "model_id": "another-model"]),
            ("warmup", ["enabled": true, "ran": true, "error": "warmup failed"]),
        ] {
            XCTAssertThrowsError(try decoder.decode(health: health(replacing: mutation), models: models()),
                                 "\(mutation.0) must stay an integrity check")
        }
        var bad = try XCTUnwrap(JSONSerialization.jsonObject(with: models()) as? [String: Any])
        var entries = try XCTUnwrap(bad["data"] as? [[String: Any]])
        for (key, value) in [("id", "speed-model"), ("owned_by", "someone-else"), ("capability", "embedding")] as [(String, Any)] {
            var entry = entries[0]
            entry[key] = value
            bad["data"] = [entry]
            XCTAssertThrowsError(try decoder.decode(health: health(), models: JSONSerialization.data(withJSONObject: bad)),
                                 "models.\(key) must stay an integrity check")
        }
        entries.append(entries[0])
        bad["data"] = entries
        XCTAssertThrowsError(try decoder.decode(health: health(), models: JSONSerialization.data(withJSONObject: bad)),
                             "MTPLX must serve exactly one model")
    }

    func testAnySingleServedModelIsAcceptedWithIdentityFromTheServer() throws {
        let modelID = "mtplx-qwen38-9b-distill-q6g64"
        let folder = "xy10086--Qwen3.8-9B-Distill-Uncensored-Heretic-MTPLX-Q6G64"
        var health = try XCTUnwrap(JSONSerialization.jsonObject(with: health(
            modelID: modelID, modelPath: "/Users/fixture/.mtplx/models/" + folder, context: 131_072
        )) as? [String: Any])
        // A different architecture, draft depth and KV setting are the served model's business.
        health["depth"] = 2
        health["paged_kv_quantization"] = "q8"
        health["startup"] = ["launch_id": "fixture-launch", "pid": 123, "model_id": modelID]
        let catalog = try Phase2MTPLXModelCatalogDecoder().decode(
            health: JSONSerialization.data(withJSONObject: health),
            models: models(modelID: modelID, context: 131_072))

        let model = try XCTUnwrap(catalog.models.first)
        XCTAssertEqual(catalog.models.count, 1)
        XCTAssertEqual(model.key, modelID)
        XCTAssertEqual(model.publisher, "xy10086")
        XCTAssertEqual(model.displayName, "Qwen3.8-9B-Distill-Uncensored-Heretic-MTPLX-Q6G64")
        XCTAssertNil(model.architecture)
        XCTAssertNil(model.quantization)
        XCTAssertFalse(model.description?.contains("27B") ?? false)
        XCTAssertTrue(model.description?.contains("context 131072") ?? false, model.description ?? "")

        let unpublished = Phase2MTPLXModelCatalogDecoder.packIdentity(modelPath: "/models/plain-pack", modelID: modelID)
        XCTAssertEqual(unpublished.publisher, "MTPLX")
        XCTAssertEqual(unpublished.packName, "plain-pack")
        XCTAssertTrue(Phase2LocalInferencePolicy(effectiveContextTokens: 131_072).isValid)
        XCTAssertFalse(Phase2LocalInferencePolicy(effectiveContextTokens: 16_384).isValid)
    }

    func testMTPLXDiscoveryUsesHealthAndCatalogWithoutManagementRoutes() async throws {
        let loader = MTPLXFixtureLoader(health: try health(), models: try models())
        let catalog = try await Phase2NativeModelDiscoveryHTTPClient(loader: loader).discover(
            at: Phase2LoopbackEndpoint(validating: "http://127.0.0.1:8000"), provider: .mtplx)
        XCTAssertEqual(catalog.models.count, 1)
    }

    @MainActor
    func testUnsupportedModelManagementFailsBeforeIssuingLifecycle() async throws {
        let endpoint = try makeEndpoint()
        let controller = Phase2LocalAIProviderController(endpoint: endpoint)
        do {
            _ = try await controller.load(modelKey: "quality", requestedContextLength: 65_536)
            XCTFail("MTPLX management must not dispatch LM Studio calls")
        } catch {
            XCTAssertEqual(error as? Phase2LocalAIProviderControllerError, .managementUnavailable)
        }
    }

    private func makeEndpoint() throws -> Phase2LocalProviderEndpoint {
        try .init(profileID: UUID(), generation: 1, endpointOrigin: "http://127.0.0.1:8000",
                  requestTimeoutMilliseconds: 300_000, resourceTimeoutMilliseconds: 1_800_000,
                  inferencePolicy: policy)
    }

    private func models(
        modelID: String = Phase2MTPLXQualityRuntimeExpectation.servedModelID,
        context: Int = 65_536
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["object": "list", "data": [[
            "id": modelID, "object": "model", "owned_by": "mtplx",
            "capability": "chat", "context_length": context, "max_context_length": context, "max_model_len": context
        ]]])
    }

    private func health(
        replacing mutation: (String, Any)? = nil,
        modelID: String = Phase2MTPLXQualityRuntimeExpectation.servedModelID,
        modelPath: String = "/models/" + Phase2MTPLXQualityRuntimeExpectation.installedDirectoryName,
        context: Int = 65_536
    ) throws -> Data {
        var object: [String: Any] = [
            "ok": true, "model": modelID,
            "model_path": modelPath,
            "generation_mode": "mtp", "load_mtp": true, "mtp_enabled": true, "depth": 3,
            "context_window": context, "execution_window": ["tokens": context, "allow_swap": false],
            "paged_kv_quantization": "off",
            "memory_plan": ["model_fits": true, "context_overcommitted": false, "context_window_resolved": context],
            "scheduler": ["config": ["mode": "serial", "max_active_requests": 1]],
            "startup": ["launch_id": "fixture-launch", "pid": 123, "model_id": modelID,
                        "backend": ["architecture_id": "qwen3-next-mtp", "runtime_capabilities": ["native_draft_head"]]],
            "warmup": ["enabled": true, "ran": true, "error": NSNull()]
        ]
        if let mutation { object[mutation.0] = mutation.1 }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private struct MTPLXFixtureLoader: Phase2OpenAIChatURLLoading {
    let health: Data
    let models: Data
    func load(_ request: URLRequest) async throws -> Phase2OpenAIChatHTTPResponse {
        let url = try XCTUnwrap(request.url)
        XCTAssertTrue(["/health", "/v1/models"].contains(url.path))
        XCTAssertEqual(request.httpMethod, "GET")
        let data = url.path == "/health" ? health : models
        return .init(statusCode: 200, contentType: "application/json", finalURL: url,
                     body: AsyncThrowingStream { continuation in
                         continuation.yield(data); continuation.finish()
                     })
    }
}
