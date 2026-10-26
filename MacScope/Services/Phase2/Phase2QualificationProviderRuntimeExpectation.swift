import Foundation

enum Phase2QualificationProviderExecutableRole: String, CaseIterable, Hashable, Sendable {
    case daemon, engine, node
}

/// Source-bound pins, not a claim that a process has been authenticated.
struct Phase2QualificationProviderExecutableExpectation: Equatable, Sendable {
    let role: Phase2QualificationProviderExecutableRole
    let homeRelativePath: String
    let sha256: String
    let identifier: String
    let teamIdentifier: String
    let cdHash: String
}

/// Immutable discovery checkpoint. Deliberately not wired into the admission policy: matching
/// observations cannot establish dynamic process authority or construct a runtime session.
struct Phase2QualificationProviderRuntimeExpectation: Sendable {
    static let candidate = Self()
    private init() {}

    let daemonClosureSHA256 = "76f77e5b4a7c0e6123c53708dca660cb039c6191d94dbb05a1d8fa7c8c9f82fe"
    let engineClosureSHA256 = "3bf46d193a1a84da256a5bf527a6f7bab4bd3661703b75a61bc5c6b5b9adec74"
    let embeddedTemplateSHA256 = "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"
    let effectiveTemplateSHA256 = "701ba13a085c0c1b5e05414dec1aa3069904f962beee36f0899e441720b83974"
    let effectiveTemplateObjectSHA256 = "e61ce277448a0dd9f4662d43f075d2444c53e00ad937f39612ee5f46e6991a52"
    let templateTransformSourceSHA256 = "483619d52e0e07ad4c3ff3195525fefe5d5f2e4dfc6c91aad34d8e79315f61bf"
    // Reviewed compatibility rewrite, not whitespace normalization. No vendor source is copied.
    let templateTransformID = "llmster-0.0.21-2.fix-jinja.args-value-string-remove-safe.v1"
    let embeddedTemplateBytes = 8_952
    let effectiveTemplateBytes = 8_945
    let contextLength = 32_768
    let parallelPredictions = 1

    // CPU-only discovery settings (offload ratio, thread count, full raw-load digest) are
    // intentionally absent: the observation did not establish a performance configuration.
    func executable(for role: Phase2QualificationProviderExecutableRole)
        -> Phase2QualificationProviderExecutableExpectation
    {
        switch role {
        case .daemon:
            .init(role: role, homeRelativePath: ".lmstudio/llmster/0.0.21-2/llmster",
                  sha256: "dc23b7a19804b437010fcd67b2959b6005048525b4738a9e9a891c383e131953",
                  identifier: "llmster", teamIdentifier: "D65G88RHWN",
                  cdHash: "580f6e37798b6b7be98712a0c19e1851aac1741e")
        case .engine:
            .init(role: role,
                  homeRelativePath: ".lmstudio/extensions/backends/llama.cpp-mac-arm64-apple-metal-advsimd-2.41.0/llama-server",
                  sha256: "c42b69b23eb308c4bf8144d2b875a1f1e6b529db9b06439338308224a9717431",
                  identifier: "llama-server", teamIdentifier: "D65G88RHWN",
                  cdHash: "740fe7c4fe303f32227bb1b171b30998219f1802")
        case .node:
            .init(role: role, homeRelativePath: ".lmstudio/.internal/utils/node",
                  sha256: "9bc64e922cba152eedf55cd4528ac0b5b7e0f4cd9d671d77bb0830c9796ea188",
                  identifier: "node", teamIdentifier: "HX7739G8FX",
                  cdHash: "a9fa506276e3e9169d157fa67f0358b671a53e32")
        }
    }
}

/// Caller-provided observations are useful for deterministic diagnostics only. No supplied
/// Boolean can assert secure ancestry, a trusted path, a signature, or dispatch authority.
struct Phase2QualificationProviderRuntimePinObservation: Sendable {
    var executables: [Phase2QualificationProviderExecutableExpectation]
    var daemonClosureSHA256: String
    var engineClosureSHA256: String
    var embeddedTemplateSHA256: String
    var effectiveTemplateSHA256: String
    var effectiveTemplateObjectSHA256: String
    var templateTransformSourceSHA256: String
    var templateTransformID: String
    var embeddedTemplateBytes: Int
    var effectiveTemplateBytes: Int
    var contextLength: Int?
    var parallelPredictions: Int?
    /// nil means absent/unavailable, never an inferred provider default.
    var providerBaseEnableThinking: Bool?
}

enum Phase2QualificationProviderRuntimePinMismatch: Equatable, Sendable {
    case executableRoles
    case executable(Phase2QualificationProviderExecutableRole)
    case daemonClosure, engineClosure, embeddedTemplate, effectiveTemplate
    case effectiveTemplateObject, templateTransform, loadedConfiguration, reasoningOverride
}

enum Phase2QualificationProviderRuntimePinValidator {
    /// An empty result means only that these observations match compiled pins. The existing
    /// provider-admission policy still rejects every candidate until live authority is complete.
    static func mismatches(in value: Phase2QualificationProviderRuntimePinObservation)
        -> [Phase2QualificationProviderRuntimePinMismatch]
    {
        let expected = Phase2QualificationProviderRuntimeExpectation.candidate
        var result: [Phase2QualificationProviderRuntimePinMismatch] = []
        let roles = value.executables.map(\.role)
        if roles.count != Phase2QualificationProviderExecutableRole.allCases.count
            || Set(roles) != Set(Phase2QualificationProviderExecutableRole.allCases) {
            result.append(.executableRoles)
        }
        for role in Phase2QualificationProviderExecutableRole.allCases {
            let observations = value.executables.filter { $0.role == role }
            if observations.count != 1 || observations.first != expected.executable(for: role) {
                result.append(.executable(role))
            }
        }
        if value.daemonClosureSHA256 != expected.daemonClosureSHA256 { result.append(.daemonClosure) }
        if value.engineClosureSHA256 != expected.engineClosureSHA256 { result.append(.engineClosure) }
        if value.embeddedTemplateSHA256 != expected.embeddedTemplateSHA256
            || value.embeddedTemplateBytes != expected.embeddedTemplateBytes { result.append(.embeddedTemplate) }
        if value.effectiveTemplateSHA256 != expected.effectiveTemplateSHA256
            || value.effectiveTemplateBytes != expected.effectiveTemplateBytes { result.append(.effectiveTemplate) }
        if value.effectiveTemplateObjectSHA256 != expected.effectiveTemplateObjectSHA256 {
            result.append(.effectiveTemplateObject)
        }
        if value.templateTransformSourceSHA256 != expected.templateTransformSourceSHA256
            || value.templateTransformID != expected.templateTransformID { result.append(.templateTransform) }
        if value.contextLength != expected.contextLength || value.parallelPredictions != expected.parallelPredictions {
            result.append(.loadedConfiguration)
        }
        if value.providerBaseEnableThinking != false { result.append(.reasoningOverride) }
        return result
    }
}
