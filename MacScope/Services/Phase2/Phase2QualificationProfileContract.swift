import Foundation

enum Phase2QualificationProfileSelector: String, CaseIterable, Sendable {
    case historicalF4C = "historical-f4c"
    case qwen38V2Q6K = "qwen38-v2-q6k"
}

/// Closed, compile-time qualification authority. No decoded input can create a contract.
/// Hash/equality use the selector because each selector resolves one immutable registry entry.
struct Phase2QualificationProfileContract: Hashable, Sendable {
    let selector: Phase2QualificationProfileSelector
    let production: Phase2ProductionQualificationPolicy
    let definitionIdentity: Phase2ProtocolComponentIdentity
    let modelRevisionIdentity: Phase2ProtocolComponentIdentity
    let providerPolicyIdentity: Phase2ProtocolComponentIdentity
    let generationAdmissionIdentity: Phase2ProtocolComponentIdentity
    let qualificationEventID: String
    let qualificationEventVersion: Int

    private init(
        selector: Phase2QualificationProfileSelector,
        production: Phase2ProductionQualificationPolicy,
        providerPolicyIdentity: Phase2ProtocolComponentIdentity,
        generationAdmissionIdentity: Phase2ProtocolComponentIdentity,
        qualificationEventID: String
    ) {
        self.selector = selector
        self.production = production
        definitionIdentity = production.definitionIdentity
        modelRevisionIdentity = production.modelRevision.identity
        self.providerPolicyIdentity = providerPolicyIdentity
        self.generationAdmissionIdentity = generationAdmissionIdentity
        self.qualificationEventID = qualificationEventID
        qualificationEventVersion = 1
    }

    static func resolve(_ selector: Phase2QualificationProfileSelector) -> Self {
        switch selector {
        case .historicalF4C: historical
        case .qwen38V2Q6K: candidate
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.selector == rhs.selector }
    func hash(into hasher: inout Hasher) { hasher.combine(selector) }

    var requiresProviderAdmission: Bool { selector == .qwen38V2Q6K }

    private static let historical = Self(
        selector: .historicalF4C,
        production: .standard,
        // Not serialized into historical definition/receipts; the old collector owns its policy.
        providerPolicyIdentity: Phase2ProductionQualificationPolicy.standard.definitionIdentity,
        generationAdmissionIdentity: Phase2ModelProtocolManifest.productionGroundedReadOnly.generationPolicy,
        qualificationEventID: "phase2.r1.f4c-b-delivery.v1"
    )

    private static let generationAdmission = try! Phase2QualificationV2Identity.make(
        id: "phase2.local.template-default-generation.v1", version: 1,
        object: [
            "version": 1,
            "reasoning_control": "no-request-override-template-default",
            "reasoning_output_policy": "discard",
            "request_generation_policy": componentObject(
                Phase2ModelProtocolManifest.productionGroundedReadOnly.generationPolicy
            ),
        ]
    )

    private static let candidate = Self(
        selector: .qwen38V2Q6K,
        production: try! .makeQwen38V2Candidate(
            providerAdmission: Phase2QualificationProviderAdmissionPolicy.identity,
            generationAdmission: generationAdmission
        ),
        providerPolicyIdentity: Phase2QualificationProviderAdmissionPolicy.identity,
        generationAdmissionIdentity: generationAdmission,
        qualificationEventID: "phase2.local.qwen38-v2-q6k-delivery.v1"
    )

    private static func componentObject(_ value: Phase2ProtocolComponentIdentity) -> [String: Any] {
        ["id": value.id, "version": value.version, "sha256": value.sha256!]
    }
}
