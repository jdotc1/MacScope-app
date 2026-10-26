import XCTest

@testable import MacScope

final class Phase2ProductionProtocolManifestTests: XCTestCase {
    func testAssistantR4HasExactV6ProtocolBundle() {
        let assistant = Phase2AIWorkerProductionProtocol.assistantR4
        XCTAssertEqual(assistant.manifestVersion, 5)
        XCTAssertEqual(assistant.wireIdentity, "phase2.ai-worker-wire.v6")
        XCTAssertEqual(assistant.inferenceIdentity, "phase2.inference.v6")
        XCTAssertEqual(assistant.inferenceVersion, 6)
        XCTAssertEqual(assistant.openAIChatIdentity, "phase2.openai-chat.v6")
        XCTAssertNotEqual(assistant.manifestDigest, Phase2AIWorkerProductionProtocol.assistantR3.manifestDigest)
    }

    func testProductionArtifactsPopulateExactF4CManifestAndDigest() throws {
        let artifacts = Phase2ProductionProtocolArtifacts.make()
        let qualification = Phase2ProductionQualificationPolicy.standard
        let manifest = Phase2ModelProtocolManifest.productionGroundedReadOnly

        XCTAssertEqual(
            manifest.promptModules,
            try artifacts.promptModules.map(Phase2ProtocolComponentIdentity.init)
        )
        XCTAssertEqual(
            manifest.readToolRegistry,
            try Phase2ProtocolComponentIdentity(artifacts.readToolRegistry)
        )
        XCTAssertEqual(
            manifest.finalOutputSchema,
            try Phase2ProtocolComponentIdentity(artifacts.finalOutputSchema)
        )
        XCTAssertEqual(
            manifest.qualificationPolicy,
            qualification.policyIdentity
        )
        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(
            manifest.protocolProbeCatalog,
            qualification.protocolProbeCatalogIdentity
        )
        XCTAssertEqual(
            manifest.liveQualificationCorpus,
            qualification.liveScenarioCatalog.identity
        )

        let digest = Phase2ModelProfileCanonicalizer().protocolManifestDigest(for: manifest)
        XCTAssertEqual(digest, "2b98d08de9e06dfc7f13cd90611f40a698986d2ff94b5359de47ddac01830168")
        XCTAssertEqual(digest, Phase2AIWorkerProductionProtocol.manifestDigest)
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.manifestIdentity,
            "sha256:\(digest)"
        )
    }

    func testEveryWorkerArtifactIdentityMatchesSharedConnectionAuthority() {
        let artifacts = Phase2ProductionProtocolArtifacts.make()
        let standard = Phase2AIWorkerProductionProtocol.standard
        let acceptedF4B = Phase2AIWorkerProductionProtocol.acceptedF4BAudit

        XCTAssertEqual(
            artifacts.promptModules.map(Phase2AIWorkerProtocolComponentIdentity.init),
            Phase2AIWorkerProductionProtocol.promptModules
        )
        XCTAssertEqual(
            Phase2AIWorkerProtocolComponentIdentity(artifacts.readToolRegistry),
            Phase2AIWorkerProductionProtocol.readToolRegistry
        )
        XCTAssertEqual(
            Phase2AIWorkerProtocolComponentIdentity(artifacts.finalOutputSchema),
            Phase2AIWorkerProductionProtocol.finalOutputSchema
        )
        XCTAssertEqual(
            Phase2AIWorkerProtocolComponentIdentity(artifacts.qualificationPolicy),
            acceptedF4B.qualificationPolicy
        )
        XCTAssertEqual(
            standard.qualificationPolicy,
            Phase2AIWorkerProtocolComponentIdentity(
                Phase2ProductionQualificationPolicy.standard.policyIdentity
            )
        )
    }

    func testOneStandardBundleAtomicallyActivatesEveryF4CProtocolSelection() {
        let standard = Phase2AIWorkerProductionProtocol.standard

        XCTAssertEqual(standard.manifestVersion, 2)
        XCTAssertEqual(standard.wireIdentity, "phase2.ai-worker-wire.v3")
        XCTAssertEqual(standard.inferenceIdentity, "phase2.inference.v3")
        XCTAssertEqual(standard.inferenceVersion, 3)
        XCTAssertEqual(standard.openAIChatIdentity, "phase2.openai-chat.v3")
        XCTAssertEqual(standard.inferenceTransport.id, "phase2.inference-transport.v3")
        XCTAssertEqual(standard.inferenceTransport.version, 3)
        XCTAssertEqual(standard.generationPolicy.id, "phase2.production-generation-policy.v2")
        XCTAssertEqual(standard.generationPolicy.version, 2)
        XCTAssertEqual(standard.protocolProbeCatalog!.id, "phase2.r1.protocol-probes.v1")
        XCTAssertEqual(
            standard.liveQualificationCorpus!.id,
            "phase2.r1.live-qualification-corpus.v1"
        )
        XCTAssertEqual(standard.qualificationPolicy.id, "phase2.r1.qualification-policy.v2")
        XCTAssertEqual(standard.qualificationPolicy.version, 2)
        XCTAssertEqual(
            standard.manifestDigest,
            "2b98d08de9e06dfc7f13cd90611f40a698986d2ff94b5359de47ddac01830168"
        )
        XCTAssertEqual(standard.manifestIdentity, "sha256:\(standard.manifestDigest)")

        XCTAssertEqual(Phase2AIWorkerProductionProtocol.wireIdentity, standard.wireIdentity)
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.inferenceIdentity,
            standard.inferenceIdentity
        )
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.inferenceVersion,
            standard.inferenceVersion
        )
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.openAIChatIdentity,
            standard.openAIChatIdentity
        )
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.inferenceTransport,
            standard.inferenceTransport
        )
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.generationPolicy,
            standard.generationPolicy
        )
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.protocolProbeCatalog,
            standard.protocolProbeCatalog
        )
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.liveQualificationCorpus,
            standard.liveQualificationCorpus
        )
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.qualificationPolicy,
            standard.qualificationPolicy
        )
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.manifestDigest, standard.manifestDigest)
        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.manifestIdentity,
            standard.manifestIdentity
        )
    }

    func testAcceptedF4BManifestRemainsAvailableOnlyAsAuditEvidence() {
        let acceptedF4B = Phase2AIWorkerProductionProtocol.acceptedF4BAudit
        let manifest = Phase2ModelProtocolManifest.acceptedF4BGroundedReadOnly

        XCTAssertEqual(acceptedF4B.manifestVersion, 1)
        XCTAssertEqual(acceptedF4B.wireIdentity, "phase2.ai-worker-wire.v2")
        XCTAssertEqual(acceptedF4B.inferenceIdentity, "phase2.inference.v2")
        XCTAssertEqual(acceptedF4B.inferenceVersion, 2)
        XCTAssertEqual(acceptedF4B.openAIChatIdentity, "phase2.openai-chat.v2")
        XCTAssertEqual(acceptedF4B.protocolProbeCatalog, nil)
        XCTAssertEqual(acceptedF4B.liveQualificationCorpus, nil)
        XCTAssertEqual(
            acceptedF4B.manifestDigest,
            "36f90d2b446a692f642c71ed2d89f748b7d987a97f491b928dfbcd005c80d502"
        )
        XCTAssertEqual(
            Phase2ModelProfileCanonicalizer().protocolManifestDigest(for: manifest),
            acceptedF4B.manifestDigest
        )
        XCTAssertNotEqual(acceptedF4B.manifestDigest, Phase2AIWorkerProductionProtocol.manifestDigest)
    }

    func testConstituentDriftCannotRetainAuthorizedManifestIdentity() {
        let drifted = Phase2ProductionProtocolArtifacts.make(
            registryDescriptionSuffixForTesting: " drift"
        )

        XCTAssertNotEqual(
            Phase2AIWorkerProtocolComponentIdentity(drifted.readToolRegistry),
            Phase2AIWorkerProductionProtocol.readToolRegistry
        )
        XCTAssertNotEqual(
            Phase2AIWorkerProductionProtocol.manifestDigest(
                readToolRegistry: .init(drifted.readToolRegistry)
            ),
            Phase2AIWorkerProductionProtocol.manifestDigest
        )
    }

    func testPromptFinalSchemaRegistryAndProbeDriftChangeF4CManifestDigest() throws {
        let baseline = Phase2ModelProtocolManifest.productionGroundedReadOnly
        let baselineDigest = Phase2ModelProfileCanonicalizer().protocolManifestDigest(for: baseline)
        let driftedProbeDigest = Phase2ProductionProtocolArtifacts.make(
            probeMutationForTesting: .swap(0, 1)
        ).qualificationPolicy.sha256
        let mutations = [
            try replacing(
                baseline,
                promptModules: Phase2ProductionProtocolArtifacts.make(
                    promptModuleSuffixForTesting: " drift"
                ).promptModules.map(Phase2ProtocolComponentIdentity.init)
            ),
            try replacing(
                baseline,
                finalOutputSchema: Phase2ProtocolComponentIdentity(
                    Phase2ProductionProtocolArtifacts.make(
                        finalSchemaForTesting: .object(["type": .string("string")])
                    ).finalOutputSchema
                )
            ),
            try replacing(
                baseline,
                readToolRegistry: Phase2ProtocolComponentIdentity(
                    Phase2ProductionProtocolArtifacts.make(
                        registryOrderForTesting: [1, 0, 2]
                    ).readToolRegistry
                )
            ),
            try replacing(
                baseline,
                protocolProbeCatalog: Phase2ProtocolComponentIdentity(
                    id: baseline.protocolProbeCatalog!.id,
                    version: baseline.protocolProbeCatalog!.version,
                    sha256: driftedProbeDigest
                )
            ),
        ]
        for mutation in mutations {
            XCTAssertNotEqual(
                baselineDigest,
                Phase2ModelProfileCanonicalizer().protocolManifestDigest(for: mutation)
            )
        }
    }

    func testAcceptedF4BIdentitiesRemainAuditableAfterV3Activation() throws {
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.legacyV2WireIdentity, "phase2.ai-worker-wire.v2")
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.legacyV2InferenceIdentity, "phase2.inference.v2")
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.legacyV2OpenAIChatIdentity, "phase2.openai-chat.v2")
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.stagedV3WireIdentity, "phase2.ai-worker-wire.v3")
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.stagedV3InferenceIdentity, "phase2.inference.v3")
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.stagedV3InferenceVersion, 3)
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.stagedV3OpenAIChatIdentity, "phase2.openai-chat.v3")
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.stagedV3InferenceTransport.id, "phase2.inference-transport.v3")
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.stagedV3InferenceTransport.version, 3)

        let baselineTransport = Phase2AIWorkerProductionProtocol.stagedV3InferenceTransport
        let driftedTransports = [
            inferenceTransportIdentity(wire: "phase2.ai-worker-wire.v4"),
            inferenceTransportIdentity(inference: "phase2.inference.v4"),
            inferenceTransportIdentity(openAI: "phase2.openai-chat.v4"),
        ]
        let manifest = Phase2ModelProtocolManifest.productionGroundedReadOnly
        let baselineDigest = Phase2ModelProfileCanonicalizer().protocolManifestDigest(for: manifest)
        for transport in driftedTransports {
            XCTAssertNotEqual(baselineTransport.sha256, transport.sha256)
            let changed = try replacing(
                manifest,
                inferenceTransport: Phase2ProtocolComponentIdentity(transport)
            )
            XCTAssertNotEqual(
                baselineDigest,
                Phase2ModelProfileCanonicalizer().protocolManifestDigest(for: changed)
            )
        }
    }

    func testGenerationPolicyV2BindsEverySerializedProductionControl() {
        let expected = Phase2ProductionProtocolArtifacts.artifactIdentity(
            id: "phase2.production-generation-policy.v2",
            version: 2,
            value: .object([
                "finalization_output": .string(
                    Phase2AIWorkerProductionProtocol.finalOutputSchema.id
                ),
                "maximum_output_tokens": .string("configured-exact"),
                "reasoning_output": .string("discard"),
                "seed": .string("absent"),
                "stop_sequences": .array([]),
                "temperature_millionths": .integer(0),
                "tool_selection": .string("required-read-only"),
                "top_p_millionths": .integer(1_000_000),
                "version": .integer(2),
            ])
        )

        XCTAssertEqual(
            Phase2AIWorkerProductionProtocol.stagedV3GenerationPolicy,
            Phase2AIWorkerProtocolComponentIdentity(expected)
        )
    }

    func testLiveAssistantR2HasIndependentProtocolAndRegistryIdentity() {
        let historical = Phase2AIWorkerProductionProtocol.standard
        let assistant = Phase2AIWorkerProductionProtocol.assistantR2
        let assistantArtifacts = Phase2ProductionProtocolArtifacts.make(
            registryVersion: .assistantR2
        )

        XCTAssertEqual(assistant.manifestVersion, 3)
        XCTAssertEqual(assistant.wireIdentity, "phase2.ai-worker-wire.v4")
        XCTAssertEqual(assistant.inferenceIdentity, "phase2.inference.v4")
        XCTAssertEqual(assistant.inferenceVersion, 4)
        XCTAssertEqual(assistant.openAIChatIdentity, "phase2.openai-chat.v4")
        XCTAssertEqual(assistant.protocolProbeCatalog, nil)
        XCTAssertEqual(assistant.liveQualificationCorpus, nil)
        XCTAssertEqual(
            assistant.readToolRegistry,
            Phase2AIWorkerProtocolComponentIdentity(assistantArtifacts.readToolRegistry)
        )
        XCTAssertEqual(assistant.readToolRegistry.id, "phase2.r2.read-tools.v2")
        XCTAssertEqual(assistant.readToolRegistry.version, 2)
        XCTAssertEqual(assistant.qualificationPolicy.id, "phase2.r2.live-assistant-unqualified.v1")
        XCTAssertNotEqual(assistant.manifestDigest, historical.manifestDigest)
        XCTAssertNotEqual(assistant.readToolRegistry, historical.readToolRegistry)
        XCTAssertNotEqual(assistant.generationPolicy, historical.generationPolicy)

        XCTAssertEqual(historical.readToolRegistry.id, "phase2.r1.read-tools.v1")
        XCTAssertEqual(historical.protocolProbeCatalog?.id, "phase2.r1.protocol-probes.v1")
        XCTAssertEqual(
            historical.liveQualificationCorpus?.id,
            "phase2.r1.live-qualification-corpus.v1"
        )
    }
}

private func inferenceTransportIdentity(
    wire: String = Phase2AIWorkerProductionProtocol.stagedV3WireIdentity,
    inference: String = Phase2AIWorkerProductionProtocol.stagedV3InferenceIdentity,
    openAI: String = Phase2AIWorkerProductionProtocol.stagedV3OpenAIChatIdentity
) -> Phase2ProductionArtifactIdentity {
    Phase2ProductionProtocolArtifacts.artifactIdentity(
        id: "phase2.inference-transport.v3",
        version: 3,
        value: .object([
            "ai_worker_wire": .string(wire),
            "inference_envelope": .string(inference),
            "openai_chat": .string(openAI),
        ])
    )
}

private func replacing(
    _ manifest: Phase2ModelProtocolManifest,
    promptModules: [Phase2ProtocolComponentIdentity]? = nil,
    finalOutputSchema: Phase2ProtocolComponentIdentity? = nil,
    readToolRegistry: Phase2ProtocolComponentIdentity? = nil,
    inferenceTransport: Phase2ProtocolComponentIdentity? = nil,
    protocolProbeCatalog: Phase2ProtocolComponentIdentity? = nil,
    qualificationPolicy: Phase2ProtocolComponentIdentity? = nil
) throws -> Phase2ModelProtocolManifest {
    if manifest.version == 2 {
        return try .init(
            version: 2,
            promptModules: promptModules ?? manifest.promptModules,
            finalOutputSchema: finalOutputSchema ?? manifest.finalOutputSchema,
            groundedContext: manifest.groundedContext,
            readToolRegistry: readToolRegistry ?? manifest.readToolRegistry,
            inferenceTransport: inferenceTransport ?? manifest.inferenceTransport,
            generationPolicy: manifest.generationPolicy,
            protocolProbeCatalog: protocolProbeCatalog ?? manifest.protocolProbeCatalog!,
            liveQualificationCorpus: manifest.liveQualificationCorpus!,
            qualificationPolicy: qualificationPolicy ?? manifest.qualificationPolicy,
            workflowAuthorityPolicy: manifest.workflowAuthorityPolicy
        )
    }
    return try .init(
        promptModules: promptModules ?? manifest.promptModules,
        finalOutputSchema: finalOutputSchema ?? manifest.finalOutputSchema,
        groundedContext: manifest.groundedContext,
        readToolRegistry: readToolRegistry ?? manifest.readToolRegistry,
        inferenceTransport: inferenceTransport ?? manifest.inferenceTransport,
        generationPolicy: manifest.generationPolicy,
        qualificationPolicy: qualificationPolicy ?? manifest.qualificationPolicy,
        workflowAuthorityPolicy: manifest.workflowAuthorityPolicy
    )
}

private extension Phase2AIWorkerProtocolComponentIdentity {
    init(_ identity: Phase2ProductionArtifactIdentity) {
        self.init(id: identity.id, version: identity.version, sha256: identity.sha256)
    }

    init(_ identity: Phase2ProtocolComponentIdentity) {
        self.init(
            id: identity.id,
            version: identity.version,
            sha256: identity.sha256!
        )
    }
}

private extension Phase2ProtocolComponentIdentity {
    init(_ identity: Phase2ProductionArtifactIdentity) throws {
        try self.init(id: identity.id, version: identity.version, sha256: identity.sha256)
    }
}
