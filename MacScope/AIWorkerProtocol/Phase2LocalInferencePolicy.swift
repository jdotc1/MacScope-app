import Foundation

/// The reviewed Speed FP16 pack, used only as the first-launch desired selection. Discovery
/// accepts whichever single model MTPLX serves; selecting a different served model is ordinary.
enum Phase2MTPLXQualityRuntimeExpectation {
    static let servedModelID = "mtplx-qwen38-27b-optimized-speed-fp16"
    static let installedDirectoryName = "Youssofal--Qwen3.8-27B-MTPLX-Optimized-Speed-FP16"
    static let repositoryRevision = "d4ac53cd03467030431e799e8805ceccf10530fc"
}


/// Explicit production controls. The legacy LM Studio case remains decodable only
/// for inert historical preferences/wires; nil never authorizes a production provider.
enum Phase2LocalAIProviderKind: String, Codable, Hashable, Sendable {
    case lmStudio
    case mtplx
}

enum Phase2LocalReasoningEffort: String, Codable, Hashable, Sendable {
    case auto
    case medium
    case xhigh
}

/// MacScope's own sampler values, used only when the user chooses to override the
/// per-model settings configured in the MTPLX app.
struct Phase2LocalSamplingOverride: Codable, Equatable, Hashable, Sendable {
    let temperature: Double
    let topP: Double
    let topK: Int

    /// Defaults for grounded reverse-engineering work.
    static let groundedDefault = Self(temperature: 0.6, topP: 0.95, topK: 20)

    var isValid: Bool {
        temperature.isFinite && (0...2).contains(temperature)
            && topP.isFinite && topP > 0 && topP <= 1
            && (1...1_000).contains(topK)
    }
}

struct Phase2LocalInferencePolicy: Codable, Equatable, Hashable, Sendable {
    let provider: Phase2LocalAIProviderKind
    /// Sent only with a sampling override; otherwise MTPLX's per-model setting applies.
    let reasoningEffort: Phase2LocalReasoningEffort
    /// Sent only with a sampling override; otherwise MTPLX's per-model setting applies.
    let enableThinking: Bool
    /// Desired capacity on an endpoint; selection replaces this with the observed loaded capacity.
    let effectiveContextTokens: Int
    /// nil uses the MTPLX app's per-model sampling and reasoning settings (the default).
    let sampling: Phase2LocalSamplingOverride?

    init(provider: Phase2LocalAIProviderKind = .mtplx,
         reasoningEffort: Phase2LocalReasoningEffort = .xhigh,
         enableThinking: Bool = true,
         effectiveContextTokens: Int = 65_536,
         sampling: Phase2LocalSamplingOverride? = nil) {
        self.provider = provider
        self.reasoningEffort = reasoningEffort
        self.enableThinking = enableThinking
        self.effectiveContextTokens = effectiveContextTokens
        self.sampling = sampling
    }

    /// Any context MTPLX resolves for the served model, from the smallest window that leaves a
    /// useful prompt budget beside a 16K response up to the catalog's maximum context length.
    static let supportedContextTokens = 32_768...4_194_304

    /// Default output budget: room for reasoning plus the answer, clamped by the caller to context.
    static let defaultMaximumOutputTokens = 8_192

    var isValid: Bool {
        provider == .mtplx && Self.supportedContextTokens.contains(effectiveContextTokens)
            && sampling?.isValid != false
    }

    func observingContext(_ tokens: Int) -> Self {
        .init(provider: provider, reasoningEffort: reasoningEffort,
              enableThinking: enableThinking, effectiveContextTokens: tokens, sampling: sampling)
    }

    func withSampling(_ sampling: Phase2LocalSamplingOverride?,
                      reasoningEffort: Phase2LocalReasoningEffort? = nil) -> Self {
        .init(provider: provider, reasoningEffort: reasoningEffort ?? self.reasoningEffort,
              enableThinking: enableThinking, effectiveContextTokens: effectiveContextTokens,
              sampling: sampling)
    }
}
