import XCTest

@testable import MacScope

final class ReconstructionAIProtocolBundleTests: XCTestCase {
    func testR2WorkflowPromptArtifactChangesOnlyVersionedObjectiveModule() {
        let r1 = Phase2ReconstructionProtocolArtifacts.make()
        let r2 = Phase2ReconstructionProtocolArtifacts.makeR2()
        XCTAssertEqual(Array(r2.promptModules.prefix(4)), r1.promptModules)
        XCTAssertEqual(r1.promptModules.map { $0.canonicalBytes.count }, [238, 214, 502, 229])
        XCTAssertEqual(r1.promptModules.map { $0.identity.sha256 }, [
            "32c981f514aff96f6fc60c7ad5eab4b214cb94ae2723e95afc922cf1a7021ee5",
            "9e4fee4bcea09ed0fc1d854da849676b193b73e11cecf31825a8b22734e5ebf1",
            "706c03520ba68adb0dd6ac21981e8f01e0bcd6118649aecfac9e29124e1ea143",
            "e0a3c6a12830971352c8d9b380c5e02634abe83790ace20e430d7e9996647094",
        ])
        let objectiveModule = r2.promptModules[4]
        XCTAssertEqual(objectiveModule.identity.id, "reconstruction.readable-objective-evidence.v11")
        XCTAssertEqual(objectiveModule.identity.version, 11)
        XCTAssertEqual(objectiveModule.canonicalBytes.count, 2460)
        XCTAssertEqual(objectiveModule.identity.sha256,
            "d598b777de5c0af617ee32e8a2d646fb991da02cbb2c41ea4d86935bc738beb8")
        let bundle = Phase2AIWorkerProductionProtocol.reconstructionR2
        XCTAssertEqual(bundle.inferenceVersion, 9)
        XCTAssertEqual(bundle.promptModules.map(\.sha256), r2.promptModules.map { $0.identity.sha256 })
        XCTAssertEqual(Phase2ModelProtocolManifest.productionReconstructionR2.promptModules,
            bundle.promptModules)
    }

    func testReconstructionR1FreezesIndependentV8BundleAlongsideAuthorizedAssistantR4() {
        let reconstruction = Phase2AIWorkerProductionProtocol.reconstructionR1
        let assistant = Phase2AIWorkerProductionProtocol.assistantR4

        XCTAssertEqual(reconstruction.manifestVersion, 8)
        XCTAssertEqual(reconstruction.wireIdentity, "phase2.ai-worker-wire.v8")
        XCTAssertEqual(reconstruction.inferenceIdentity, "phase2.inference.v8")
        XCTAssertEqual(reconstruction.inferenceVersion, 8)
        XCTAssertEqual(reconstruction.openAIChatIdentity, "phase2.openai-chat.v8")
        XCTAssertEqual(reconstruction.inferenceTransport.id, "phase2.inference-transport.v8")
        XCTAssertEqual(reconstruction.inferenceTransport.version, 8)
        XCTAssertEqual(reconstruction.readToolRegistry.id, "reconstruction.v1")
        XCTAssertEqual(reconstruction.readToolRegistry.version, 1)
        XCTAssertEqual(reconstruction.toolSchemaSet?.id, "reconstruction.v1.schemas")
        XCTAssertEqual(reconstruction.roundOutputSchema?.id, "reconstruction.round-output.v8")
        XCTAssertEqual(reconstruction.roundOutputSchema?.version, 8)
        XCTAssertEqual(reconstruction.finalOutputSchema.id, "reconstruction.final-synthesis.v1")
        XCTAssertEqual(reconstruction.groundedContext.id, "reconstruction.retrieved-context.v8")
        XCTAssertEqual(reconstruction.groundedContext.version, 8)
        XCTAssertEqual(reconstruction.generationPolicy.id, "reconstruction.generation-policy.v8")
        XCTAssertEqual(reconstruction.generationPolicy.version, 8)
        XCTAssertEqual(reconstruction.promptModules.map(\.id), [
            "reconstruction.authority.v1",
            "reconstruction.evidence.v1",
            "reconstruction.plan-read-observe.v8",
            "reconstruction.final-synthesis.v1",
        ])
        XCTAssertEqual(reconstruction.promptModules.map(\.version), [1, 1, 8, 1])
        XCTAssertEqual(reconstruction.finalOutputSchema.version, 1)
        XCTAssertNotEqual(reconstruction.manifestDigest, assistant.manifestDigest)

        XCTAssertEqual(assistant.manifestVersion, 5)
        XCTAssertEqual(assistant.wireIdentity, "phase2.ai-worker-wire.v6")
        // R4 inherits the authorized REA read-tool registry; its complete content identity
        // changes with that registry while reconstruction and historical R1 remain separate.
        XCTAssertEqual(
            assistant.manifestDigest,
            "8071a767b34b7aea0c68de8edf302553489b8d0671e691f05a2f18c47ff5eedd"
        )
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.standard.manifestDigest,
                       "2b98d08de9e06dfc7f13cd90611f40a698986d2ff94b5359de47ddac01830168")
    }

    func testReconstructionBundleUsesExecutableTask7ArtifactDigests() {
        let artifacts = Phase2ReconstructionProtocolArtifacts.make()
        let bundle = Phase2AIWorkerProductionProtocol.reconstructionR1
        let manifest = Phase2ModelProtocolManifest.productionReconstructionR1

        XCTAssertEqual(bundle.readToolRegistry.sha256, artifacts.toolRegistry.identity.sha256)
        XCTAssertEqual(bundle.toolSchemaSet?.sha256, artifacts.schemaBlueprints.identity.sha256)
        XCTAssertEqual(bundle.roundOutputSchema?.sha256, artifacts.roundOutputSchema.identity.sha256)
        XCTAssertEqual(bundle.finalOutputSchema.sha256, artifacts.finalSynthesisSchema.identity.sha256)
        XCTAssertEqual(bundle.promptModules.map(\.sha256), artifacts.promptModules.map { $0.identity.sha256 })
        XCTAssertEqual(manifest.manifestVersion, bundle.manifestVersion)
        XCTAssertEqual(manifest.promptModules, bundle.promptModules)
        XCTAssertEqual(manifest.toolSchemaSet, bundle.toolSchemaSet)
        XCTAssertEqual(manifest.roundOutputSchema, bundle.roundOutputSchema)
        XCTAssertEqual(manifest.finalOutputSchema, bundle.finalOutputSchema)
        XCTAssertEqual(manifest.groundedContext, bundle.groundedContext)
        XCTAssertEqual(manifest.readToolRegistry, bundle.readToolRegistry)
        XCTAssertEqual(manifest.inferenceTransport, bundle.inferenceTransport)
        XCTAssertEqual(manifest.generationPolicy, bundle.generationPolicy)
        XCTAssertEqual(manifest.manifestDigest, bundle.manifestDigest)
    }

    func testConfigurationAcceptsReconstructionManifestButCannotMixBundles() throws {
        let configuration = try Phase2AIProviderConfiguration(
            profileID: protocolID(1), generation: 1,
            endpointOrigin: "http://127.0.0.1:1234", model: "local-model",
            maximumTokens: 1_024, requestTimeoutMilliseconds: 10_000,
            resourceTimeoutMilliseconds: 60_000
        )
        let data = try Phase2AIWorkerConfigurationAppCodec().encodeConfiguration(
            configuration,
            protocolBundle: Phase2AIWorkerProductionProtocol.reconstructionR1
        )
        let wire = try Phase2AIWorkerConfigurationWireCodec().decodeConfiguration(data)
        XCTAssertEqual(wire.protocolManifestDigest,
                       Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest)

        let reconstruction = Phase2AIWorkerProductionProtocol.reconstructionR1
        let mixed = Phase2AIWorkerProductionProtocolBundle(
            manifestVersion: reconstruction.manifestVersion,
            wireIdentity: reconstruction.wireIdentity,
            inferenceIdentity: reconstruction.inferenceIdentity,
            inferenceVersion: reconstruction.inferenceVersion,
            openAIChatIdentity: reconstruction.openAIChatIdentity,
            promptModules: reconstruction.promptModules,
            toolSchemaSet: reconstruction.toolSchemaSet,
            roundOutputSchema: reconstruction.roundOutputSchema,
            finalOutputSchema: Phase2AIWorkerProductionProtocol.assistantR4.finalOutputSchema,
            groundedContext: reconstruction.groundedContext,
            readToolRegistry: reconstruction.readToolRegistry,
            inferenceTransport: reconstruction.inferenceTransport,
            generationPolicy: reconstruction.generationPolicy,
            protocolProbeCatalog: reconstruction.protocolProbeCatalog,
            liveQualificationCorpus: reconstruction.liveQualificationCorpus,
            qualificationPolicy: reconstruction.qualificationPolicy,
            workflowAuthorityPolicy: reconstruction.workflowAuthorityPolicy,
            manifestDigest: reconstruction.manifestDigest
        )
        XCTAssertThrowsError(try Phase2AIWorkerConfigurationAppCodec().encodeConfiguration(
            configuration,
            protocolBundle: mixed
        ))
    }
}

private func protocolID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", value))!
}
