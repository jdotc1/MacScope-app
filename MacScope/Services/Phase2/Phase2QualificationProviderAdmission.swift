import Foundation

/// Evidence is not dispatch authority. Only the collector can produce a live runtime session.
enum Phase2ProviderAdmissionObservation: Equatable, Sendable {
    case unavailable(Phase2ProviderAdmissionUnavailableReason)
    case observed(Phase2ProviderAdmissionEvidence)
}

enum Phase2ProviderAdmissionUnavailableReason: String, CaseIterable, Sendable {
    case listenerMissing = "listener-missing"
    case processIdentityUnavailable = "process-identity-unavailable"
    case executableMismatch = "executable-mismatch"
    case signatureMismatch = "signature-mismatch"
    case runtimeClosureUnreviewed = "runtime-closure-unreviewed"
    case runtimeClosureUnavailable = "runtime-closure-unavailable"
    case runtimeClosureMismatch = "runtime-closure-mismatch"
    case templateAuthorityUnavailable = "template-authority-unavailable"
    case templateAuthorityMismatch = "template-authority-mismatch"
    case loadedConfigurationUnavailable = "loaded-configuration-unavailable"
    case changedDuringCapture = "changed-during-capture"
}

struct Phase2ProviderAdmissionEvidence: Equatable, Sendable {
    let providerPolicyIdentity: Phase2ProtocolComponentIdentity
    let providerBuildIdentity: Phase2ProtocolComponentIdentity
    let runtimeClosureIdentity: Phase2ProtocolComponentIdentity
    let templateAuthorityIdentity: Phase2ProtocolComponentIdentity
    let runtimeIdentity: Phase2EndpointBoundProviderRuntimeIdentity

    init(
        providerPolicyIdentity: Phase2ProtocolComponentIdentity,
        providerBuildIdentity: Phase2ProtocolComponentIdentity,
        runtimeClosureIdentity: Phase2ProtocolComponentIdentity,
        templateAuthorityIdentity: Phase2ProtocolComponentIdentity,
        runtimeIdentity: Phase2EndpointBoundProviderRuntimeIdentity
    ) throws {
        let expected = [
            (providerPolicyIdentity, "phase2.local.llmster-private-provider-policy.v1"),
            (providerBuildIdentity, "phase2.local.llmster-provider-build.v1"),
            (runtimeClosureIdentity, "phase2.local.llmster-runtime-closure.v1"),
            (templateAuthorityIdentity, "phase2.local.llmster-template-authority.v1"),
        ]
        guard expected.allSatisfy({ value, id in
            value.id == id && value.version == 1 && value.availability == .available
                && value.sha256.map(phase2IsSHA256Hex) == true
        }) else { throw Phase2QualificationRuntimeProvenanceValidationError.invalidScope }
        self.providerPolicyIdentity = providerPolicyIdentity
        self.providerBuildIdentity = providerBuildIdentity
        self.runtimeClosureIdentity = runtimeClosureIdentity
        self.templateAuthorityIdentity = templateAuthorityIdentity
        self.runtimeIdentity = runtimeIdentity
    }

    var providerBuildToken: String { "sha256:\(providerBuildIdentity.sha256!)" }
}

/// Deliberately no public reviewed constructor. No observed or fixture digest may promote this
/// expectation. A reviewed closure requires a future source-bound policy revision and build.
enum Phase2QualificationProviderAdmissionPolicy {
    static let executableSHA256 =
        "dc23b7a19804b437010fcd67b2959b6005048525b4738a9e9a891c383e131953"
    static let executableRelativePath = ".lmstudio/llmster/0.0.21-2/llmster"
    static let identifier = "llmster"
    static let teamIdentifier = "D65G88RHWN"
    static let cdHash = "580f6e37798b6b7be98712a0c19e1851aac1741e"
    static let designatedRequirement =
        "identifier llmster and anchor apple generic and "
        + "certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
        + "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and "
        + "certificate leaf[subject.OU] = D65G88RHWN"

    static let identity: Phase2ProtocolComponentIdentity = try! Phase2QualificationV2Identity.make(
        id: "phase2.local.llmster-private-provider-policy.v1", version: 1,
        object: [
            "version": 1,
            "topology": "standalone-executable",
            "executable_relative_path": executableRelativePath,
            "executable_sha256": executableSHA256,
            "identifier": identifier,
            "team_identifier": teamIdentifier,
            "cdhash": cdHash,
            "designated_requirement": designatedRequirement,
            "requires_hardened_runtime": true,
            "allows_ad_hoc": false,
            "runtime_closure_expectation": "unreviewed",
            "template_authority_expectation": "unreviewed",
        ]
    )

    static func deficiency(
        for observation: Phase2ProviderAdmissionObservation?
    ) -> Phase2ProviderAdmissionUnavailableReason? {
        // Even a perfectly self-consistent observation is not a reviewed runtime expectation.
        .runtimeClosureUnreviewed
    }
}

/// Reporting vocabulary only. These cases cannot manufacture canary/live authorization.
enum Phase2QualificationProfileAdmissionState: String, Sendable {
    case unqualified
    case canaryPassed = "canary-passed"
    case qualified
    case failed
    case stale
}
