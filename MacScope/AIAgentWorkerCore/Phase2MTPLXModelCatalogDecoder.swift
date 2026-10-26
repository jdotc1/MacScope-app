import Foundation
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

struct Phase2MTPLXModelCatalogDecoder: Sendable {
    func decode(health: Data, models: Data) throws -> Phase2NativeModelCatalog {
        let limits = Phase2AIWorkerWireJSONLimits(maximumDepth: 32, maximumTokens: 100_000,
                                                maximumMembersAndElements: 50_000)
        guard health.count <= Phase2NativeModelDiscoveryHTTPClient.maximumResponseBytes,
              models.count <= Phase2NativeModelDiscoveryHTTPClient.maximumResponseBytes,
              Phase2StrictJSONValidator.validate(health, limits: limits),
              Phase2StrictJSONValidator.validate(models, limits: limits) else {
            throw Phase2NativeModelDiscoveryHTTPClientError.incompatible
        }
        let health = try JSONDecoder().decode(Health.self, from: health)
        let models = try JSONDecoder().decode(Models.self, from: models)
        // Any single model MTPLX serves is accepted. Only the properties MacScope's request
        // path depends on are required: one consistent chat model, the MTP generation mode the
        // request asks for, a resolved context window that fits, and serial one-request scheduling.
        guard health.ok,
              !health.model.isEmpty,
              health.model_path.hasPrefix("/"),
              health.generation_mode == "mtp", health.load_mtp, health.mtp_enabled,
              health.depth >= 1,
              Phase2LocalInferencePolicy.supportedContextTokens.contains(health.context_window),
              health.execution_window.tokens == health.context_window,
              health.memory_plan.model_fits,
              !health.memory_plan.context_overcommitted,
              health.memory_plan.context_window_resolved == health.context_window,
              health.scheduler.config.mode == "serial",
              health.scheduler.config.max_active_requests == 1,
              health.startup.model_id == health.model,
              health.warmup.error == nil,
              !health.warmup.enabled || health.warmup.ran,
              models.object == "list", models.data.count == 1,
              let model = models.data.first,
              model.id == health.model, model.object == "model", model.owned_by == "mtplx",
              model.capability == "chat", model.context_length == health.context_window,
              model.max_context_length == health.context_window,
              model.max_model_len == health.context_window else {
            throw Phase2NativeModelDiscoveryHTTPClientError.incompatible
        }
        let identity = Self.packIdentity(modelPath: health.model_path, modelID: model.id)
        let architecture = health.startup.backend?.architecture_id.flatMap { $0.isEmpty ? nil : $0 }
        // The summary is bounded stable observed provenance included in inventory identity.
        // A revision is not asserted here: this API does not return a pack hash or revision.
        let summary = "MTPLX loaded \(identity.packName); MTP D\(health.depth); "
            + "serial; context \(health.context_window); pack revision unavailable from API."
        return .init(models: [.init(
            kind: .llm, publisher: identity.publisher, key: model.id,
            displayName: identity.packName, architecture: architecture,
            quantization: nil, sizeBytes: 0,
            parameters: nil, loadedInstances: [.init(
                id: health.startup.launch_id ?? "mtplx-pid-\(health.startup.pid)",
                configuration: .init(contextLength: health.context_window,
                                     evaluationBatchSize: nil, parallelPredictions: 1,
                                     flashAttention: nil, expertCount: nil, offloadsKVCacheToGPU: nil)
            )], maximumContextLength: health.context_window, format: .mlx,
            capabilities: nil, description: summary, variants: [], selectedVariant: nil
        )])
    }

    /// Names come only from what MTPLX reports. An installed pack folder follows the
    /// `publisher--repository` convention; anything else keeps a neutral publisher.
    static func packIdentity(modelPath: String, modelID: String) -> (publisher: String, packName: String) {
        let folder = URL(fileURLWithPath: modelPath).lastPathComponent
        let parts = folder.components(separatedBy: "--")
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            return (parts[0], parts[1])
        }
        return ("MTPLX", folder.isEmpty || folder == "/" ? modelID : folder)
    }

    private struct Models: Decodable {
        let object: String
        let data: [Model]
        struct Model: Decodable {
            let id: String; let object: String; let owned_by: String; let capability: String
            let context_length: Int; let max_context_length: Int; let max_model_len: Int
        }
    }
    private struct Health: Decodable {
        let ok: Bool; let model: String; let model_path: String
        let generation_mode: String; let load_mtp: Bool; let mtp_enabled: Bool; let depth: Int
        let context_window: Int; let execution_window: ExecutionWindow
        let memory_plan: MemoryPlan; let scheduler: Scheduler; let startup: Startup; let warmup: Warmup
        struct ExecutionWindow: Decodable { let tokens: Int }
        struct MemoryPlan: Decodable {
            let model_fits: Bool; let context_overcommitted: Bool; let context_window_resolved: Int
        }
        struct Scheduler: Decodable {
            let config: Config
            struct Config: Decodable { let mode: String; let max_active_requests: Int }
        }
        struct Startup: Decodable {
            let launch_id: String?; let pid: Int; let model_id: String; let backend: Backend?
            struct Backend: Decodable { let architecture_id: String? }
        }
        struct Warmup: Decodable { let enabled: Bool; let ran: Bool; let error: String? }
    }
}
