import CryptoKit
import Foundation

/// Content-addressed identity shared by the app control plane and the isolated AI worker.
struct Phase2AIWorkerProtocolComponentIdentity: Equatable, Hashable, Sendable {
    let id: String
    let version: Int
    let sha256: String
}

/// One indivisible production-protocol selection. Every connection-facing alias below is derived
/// from one of these bundles so a wire, inference, generation, qualification, or manifest identity
/// cannot be activated independently of the others.
struct Phase2AIWorkerProductionProtocolBundle: Equatable, Sendable {
    let manifestVersion: Int
    let wireIdentity: String
    let inferenceIdentity: String
    let inferenceVersion: Int
    let openAIChatIdentity: String
    let promptModules: [Phase2AIWorkerProtocolComponentIdentity]
    let toolSchemaSet: Phase2AIWorkerProtocolComponentIdentity?
    let roundOutputSchema: Phase2AIWorkerProtocolComponentIdentity?
    let finalOutputSchema: Phase2AIWorkerProtocolComponentIdentity
    let groundedContext: Phase2AIWorkerProtocolComponentIdentity
    let readToolRegistry: Phase2AIWorkerProtocolComponentIdentity
    let inferenceTransport: Phase2AIWorkerProtocolComponentIdentity
    let generationPolicy: Phase2AIWorkerProtocolComponentIdentity
    let protocolProbeCatalog: Phase2AIWorkerProtocolComponentIdentity?
    let liveQualificationCorpus: Phase2AIWorkerProtocolComponentIdentity?
    let qualificationPolicy: Phase2AIWorkerProtocolComponentIdentity
    let workflowAuthorityPolicy: Phase2AIWorkerProtocolComponentIdentity
    let manifestDigest: String

    var manifestIdentity: String { "sha256:\(manifestDigest)" }
}

/// Frozen production identities negotiated by the inference transport. Configuration, discovery,
/// and lifecycle retain their independent schema versions, while every inference connection binds
/// the exact production prompt/tool/schema/probe manifest defined here.
enum Phase2AIWorkerProductionProtocol {
    /// Frozen audit identities for the accepted F4B production transport.
    static let legacyV2WireIdentity = "phase2.ai-worker-wire.v2"
    static let legacyV2InferenceIdentity = "phase2.inference.v2"
    static let legacyV2OpenAIChatIdentity = "phase2.openai-chat.v2"

    /// F4C identities retained under their staging names for source compatibility. The canonical
    /// `standard` bundle below activates all of them together.
    static let stagedV3WireIdentity = "phase2.ai-worker-wire.v3"
    static let stagedV3InferenceIdentity = "phase2.inference.v3"
    static let stagedV3InferenceVersion = 3
    static let stagedV3OpenAIChatIdentity = "phase2.openai-chat.v3"

    /// Live Assistant R2 has a distinct transport identity because it exposes debugger reads and
    /// finalization proposal tools that are intentionally absent from the frozen R1 qualification
    /// corpus. A peer must negotiate this bundle explicitly; R1 evidence cannot authorize it.
    static let assistantR2WireIdentity = "phase2.ai-worker-wire.v4"
    static let assistantR2InferenceIdentity = "phase2.inference.v4"
    static let assistantR2InferenceVersion = 4
    static let assistantR2OpenAIChatIdentity = "phase2.openai-chat.v4"
    static let assistantR3WireIdentity = "phase2.ai-worker-wire.v5"
    static let assistantR3InferenceIdentity = "phase2.inference.v5"
    static let assistantR3InferenceVersion = 5
    static let assistantR3OpenAIChatIdentity = "phase2.openai-chat.v5"
    static let assistantR4WireIdentity = "phase2.ai-worker-wire.v6"
    static let assistantR4InferenceIdentity = "phase2.inference.v6"
    static let assistantR4InferenceVersion = 6
    static let assistantR4OpenAIChatIdentity = "phase2.openai-chat.v6"
    static let reconstructionR1WireIdentity = "phase2.ai-worker-wire.v8"
    static let reconstructionR1InferenceIdentity = "phase2.inference.v8"
    static let reconstructionR1InferenceVersion = 8
    static let reconstructionR1OpenAIChatIdentity = "phase2.openai-chat.v8"
    static let reconstructionR2WireIdentity = "phase2.ai-worker-wire.v9"
    static let reconstructionR2InferenceIdentity = "phase2.inference.v9"
    static let reconstructionR2InferenceVersion = 9
    static let reconstructionR2OpenAIChatIdentity = "phase2.openai-chat.v9"

    static let promptModules: [Phase2AIWorkerProtocolComponentIdentity] = [
        .init(
            id: "macscope.authority.v1",
            version: 1,
            sha256: "32757c0ee797e5b2c76e55bdf62dc59124a973caa7d562f595f9f4310e9652f7"
        ),
        .init(
            id: "macscope.grounded-evidence.v1",
            version: 1,
            sha256: "a96739aa3f11055b77213b4572891f7fc854da0e6e15c2d61773b3bf10f7c947"
        ),
        .init(
            id: "macscope.tool-selection.v1",
            version: 1,
            sha256: "435edf290f2e036c876963b2d7cffcba27c9a62c56325a0fd82395607ff232f7"
        ),
        .init(
            id: "macscope.finalization.v1",
            version: 1,
            sha256: "1f524d349ef8e1cfac66d6a2dd13a156cd866f59017161e647d8c5cd5381a370"
        ),
    ]
    static let assistantR3PromptModules = promptModules + [component(
        id: "macscope.conversation-history.v1",
        version: 1,
        value: .object([
            "authority": .string("none"),
            "evidentiary": .bool(false),
            "maximum_completed_turns": .integer(8),
            "maximum_utf8_bytes": .integer(65_536),
        ])
    )]
    static let assistantR4PromptModules = assistantR3PromptModules + [component(
        id: "macscope.shell-continuation.v1",
        version: 1,
        value: .object([
            "authority": .string("runtime-authority-audited"),
            "shell_output": .string("untrusted-non-authoritative-data"),
            "tool_policy": .string("none"),
        ])
    )]
    private static let acceptedF4BReadToolRegistry = Phase2AIWorkerProtocolComponentIdentity(
        id: "phase2.r1.read-tools.v1",
        version: 1,
        sha256: "661e234078dd7c05c84149cdb7d539168120d31cf02f4c53e6849e6fce5e8a6b"
    )
    static let readToolRegistry = Phase2AIWorkerProtocolComponentIdentity(
        id: "phase2.r1.read-tools.v1",
        version: 1,
        sha256: "988d8904bb03e556f13c12ad12365f2fc7b2ca06e4618a30216be82b644ed72b"
    )
    // Authorized REA read-tool extension; the historical R1 registry remains frozen.
    static let assistantR2ReadToolRegistry = Phase2AIWorkerProtocolComponentIdentity(
        id: "phase2.r2.read-tools.v2",
        version: 2,
        sha256: "d1d1050c9624f4ede203f7a362b40432f06f08d2ef41d356bfc809fc2c0a8387"
    )
    static let finalOutputSchema = Phase2AIWorkerProtocolComponentIdentity(
        id: "phase2.r1.grounded-final.v1",
        version: 1,
        sha256: "e4717ea2bf4850a82bd44f0c9fa96787aa64e3e4448d5a981ba9a34726e4d2e9"
    )
    private static let acceptedF4BQualificationPolicy = Phase2AIWorkerProtocolComponentIdentity(
        id: "phase2.r1.qualification-policy.v1",
        version: 1,
        sha256: "7632aaeceb8a3b6946443f6d102233ad7abd95689a203115407ba27d6aaf33d5"
    )
    private static let standardProtocolProbeCatalog = Phase2AIWorkerProtocolComponentIdentity(
        id: "phase2.r1.protocol-probes.v1",
        version: 1,
        sha256: "7632aaeceb8a3b6946443f6d102233ad7abd95689a203115407ba27d6aaf33d5"
    )
    private static let standardLiveQualificationCorpus = Phase2AIWorkerProtocolComponentIdentity(
        id: "phase2.r1.live-qualification-corpus.v1",
        version: 1,
        sha256: "606e41c5f2d486baea7b67e30b3ea5d2d5900dd22f64c3f50c211f967900914c"
    )
    private static let standardQualificationPolicy = Phase2AIWorkerProtocolComponentIdentity(
        id: "phase2.r1.qualification-policy.v2",
        version: 2,
        sha256: "f4e0d43b2b975840686c302740fe946578619eab309896e183225c65e1747559"
    )

    static let groundedContext = component(
        id: "phase2.grounded-context.v1",
        version: 1,
        value: .object([
            "maximum_canonical_bytes": .integer(1_048_576),
            "maximum_records": .integer(3),
            "schema_version": .integer(1),
        ])
    )
    private static let acceptedF4BInferenceTransport = component(
        id: "phase2.inference-transport.v2",
        version: 2,
        value: .object([
            "ai_worker_wire": .string(legacyV2WireIdentity),
            "inference_envelope": .string(legacyV2InferenceIdentity),
            "openai_chat": .string(legacyV2OpenAIChatIdentity),
        ])
    )
    static let stagedV3InferenceTransport = component(
        id: "phase2.inference-transport.v3",
        version: 3,
        value: .object([
            "ai_worker_wire": .string(stagedV3WireIdentity),
            "inference_envelope": .string(stagedV3InferenceIdentity),
            "openai_chat": .string(stagedV3OpenAIChatIdentity),
        ])
    )
    static let assistantR2InferenceTransport = component(
        id: "phase2.inference-transport.v4",
        version: 4,
        value: .object([
            "ai_worker_wire": .string(assistantR2WireIdentity),
            "inference_envelope": .string(assistantR2InferenceIdentity),
            "openai_chat": .string(assistantR2OpenAIChatIdentity),
        ])
    )
    static let assistantR3InferenceTransport = component(
        id: "phase2.inference-transport.v5",
        version: 5,
        value: .object([
            "ai_worker_wire": .string(assistantR3WireIdentity),
            "inference_envelope": .string(assistantR3InferenceIdentity),
            "openai_chat": .string(assistantR3OpenAIChatIdentity),
        ])
    )
    static let assistantR4InferenceTransport = component(
        id: "phase2.inference-transport.v6",
        version: 6,
        value: .object([
            "ai_worker_wire": .string(assistantR4WireIdentity),
            "inference_envelope": .string(assistantR4InferenceIdentity),
            "openai_chat": .string(assistantR4OpenAIChatIdentity),
        ])
    )
    private static let acceptedF4BGenerationPolicy = component(
        id: "phase2.production-generation-policy.v1",
        version: 1,
        value: .object([
            "finalization_output": .string(finalOutputSchema.id),
            "reasoning_output": .string("discard"),
            "tool_selection": .string("required-read-only"),
            "version": .integer(1),
        ])
    )
    static let stagedV3GenerationPolicy = component(
        id: "phase2.production-generation-policy.v2",
        version: 2,
        value: .object([
            "finalization_output": .string(finalOutputSchema.id),
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
    static let assistantR2GenerationPolicy = component(
        id: "phase2.production-generation-policy.v3",
        version: 3,
        value: .object([
            "finalization_output": .string(finalOutputSchema.id),
            "finalization_proposal_tools": .array([
                .string("macscope_stage_shell_proposal_v1"),
                .string("macscope_stage_debugger_action_proposal_v1"),
            ]),
            "maximum_output_tokens": .string("configured-exact"),
            "reasoning_output": .string("discard"),
            "read_tool_registry": .string(assistantR2ReadToolRegistry.id),
            "seed": .string("absent"),
            "stop_sequences": .array([]),
            "temperature_millionths": .integer(0),
            "tool_selection": .string("required-read-only"),
            "top_p_millionths": .integer(1_000_000),
            "version": .integer(3),
        ])
    )
    static let assistantR3GenerationPolicy = component(
        id: "phase2.production-generation-policy.v4",
        version: 4,
        value: .object([
            "conversation_history": .string("completed-pairs-non-evidentiary"),
            "finalization_output": .string(finalOutputSchema.id),
            "finalization_proposal_tools": .array([
                .string("macscope_stage_shell_proposal_v1"),
                .string("macscope_stage_debugger_action_proposal_v1"),
            ]),
            "maximum_output_tokens": .string("configured-exact"),
            "reasoning_output": .string("discard"),
            "read_tool_registry": .string(assistantR2ReadToolRegistry.id),
            "seed": .string("absent"),
            "stop_sequences": .array([]),
            "temperature_millionths": .integer(0),
            "tool_selection": .string("required-read-only"),
            "top_p_millionths": .integer(1_000_000),
            "version": .integer(4),
        ])
    )
    static let assistantR4GenerationPolicy = component(
        id: "phase2.production-generation-policy.v5",
        version: 5,
        value: .object([
            "conversation_history": .string("completed-pairs-non-evidentiary"),
            "finalization_output": .string(finalOutputSchema.id),
            "maximum_output_tokens": .string("configured-exact"),
            "reasoning_output": .string("discard"),
            "shell_continuation": .string("single-final-candidate-then-completed"),
            "temperature_millionths": .integer(0),
            "tool_selection": .string("none-during-shell-continuation"),
            "top_p_millionths": .integer(1_000_000),
            "version": .integer(5),
        ])
    )
    static let reconstructionR1InferenceTransport = component(
        id: "phase2.inference-transport.v8",
        version: 8,
        value: .object([
            "ai_worker_wire": .string(reconstructionR1WireIdentity),
            "inference_envelope": .string(reconstructionR1InferenceIdentity),
            "openai_chat": .string(reconstructionR1OpenAIChatIdentity),
        ])
    )
    static let reconstructionR1GroundedContext = component(
        id: "reconstruction.retrieved-context.v8",
        version: 8,
        value: .object([
            "maximum_gap_ids": .integer(64),
            "maximum_canonical_bytes": .integer(1_048_576),
            "maximum_evidence_ids": .integer(4_096),
            "schema_version": .integer(8),
        ])
    )
    static let reconstructionR1GenerationPolicy = component(
        id: "reconstruction.generation-policy.v8",
        version: 8,
        value: .object([
            "final_tools": .bool(false),
            "gap_resolution": .string(
                "exact-gap-id-plus-selected-handle-id-plus-retrieved-evidence-id"
            ),
            "reasoning_output": .string("discard"),
            "round_selection": .string("opaque-app-offered-handle-ids"),
            "temperature_millionths": .integer(0),
            "worker_executes_tools": .bool(false),
        ])
    )
    private static let assistantR2UnqualifiedPolicy = component(
        id: "phase2.r2.live-assistant-unqualified.v1",
        version: 1,
        value: .object([
            "authorized_by_r1_qualification": .bool(false),
            "requires_independent_qualification": .bool(true),
        ])
    )
    static let workflowAuthorityPolicy = component(
        id: "phase2.grounded-read-only-authority.v1",
        version: 1,
        value: .object([
            "app_executes_reads": .bool(true),
            "mutation_authority": .bool(false),
            "network_authority": .string("literal-loopback-only"),
            "worker_executes_reads": .bool(false),
        ])
    )

    /// Accepted F4B evidence is immutable and audit-only. Runtime negotiation never selects it.
    static let acceptedF4BAudit = makeBundle(
        manifestVersion: 1,
        wireIdentity: legacyV2WireIdentity,
        inferenceIdentity: legacyV2InferenceIdentity,
        inferenceVersion: 2,
        openAIChatIdentity: legacyV2OpenAIChatIdentity,
        readToolRegistry: acceptedF4BReadToolRegistry,
        inferenceTransport: acceptedF4BInferenceTransport,
        generationPolicy: acceptedF4BGenerationPolicy,
        protocolProbeCatalog: nil,
        liveQualificationCorpus: nil,
        qualificationPolicy: acceptedF4BQualificationPolicy
    )

    /// The sole active F4C standard. Adding another production protocol requires constructing one
    /// complete bundle and then changing this single selection point.
    static let standard = makeBundle(
        manifestVersion: 2,
        wireIdentity: stagedV3WireIdentity,
        inferenceIdentity: stagedV3InferenceIdentity,
        inferenceVersion: stagedV3InferenceVersion,
        openAIChatIdentity: stagedV3OpenAIChatIdentity,
        readToolRegistry: readToolRegistry,
        inferenceTransport: stagedV3InferenceTransport,
        generationPolicy: stagedV3GenerationPolicy,
        protocolProbeCatalog: standardProtocolProbeCatalog,
        liveQualificationCorpus: standardLiveQualificationCorpus,
        qualificationPolicy: standardQualificationPolicy
    )

    /// Active live-Assistant protocol. It is separately content-bound and explicitly unqualified
    /// by the historical R1 corpus until an R2 qualification corpus is accepted.
    static let assistantR2 = makeBundle(
        manifestVersion: 3,
        wireIdentity: assistantR2WireIdentity,
        inferenceIdentity: assistantR2InferenceIdentity,
        inferenceVersion: assistantR2InferenceVersion,
        openAIChatIdentity: assistantR2OpenAIChatIdentity,
        readToolRegistry: assistantR2ReadToolRegistry,
        inferenceTransport: assistantR2InferenceTransport,
        generationPolicy: assistantR2GenerationPolicy,
        protocolProbeCatalog: nil,
        liveQualificationCorpus: nil,
        qualificationPolicy: assistantR2UnqualifiedPolicy
    )

    static let assistantR3 = makeBundle(
        manifestVersion: 4,
        wireIdentity: assistantR3WireIdentity,
        inferenceIdentity: assistantR3InferenceIdentity,
        inferenceVersion: assistantR3InferenceVersion,
        openAIChatIdentity: assistantR3OpenAIChatIdentity,
        promptModules: assistantR3PromptModules,
        readToolRegistry: assistantR2ReadToolRegistry,
        inferenceTransport: assistantR3InferenceTransport,
        generationPolicy: assistantR3GenerationPolicy,
        protocolProbeCatalog: nil,
        liveQualificationCorpus: nil,
        qualificationPolicy: assistantR2UnqualifiedPolicy
    )

    static let assistantR4 = makeBundle(
        manifestVersion: 5,
        wireIdentity: assistantR4WireIdentity,
        inferenceIdentity: assistantR4InferenceIdentity,
        inferenceVersion: assistantR4InferenceVersion,
        openAIChatIdentity: assistantR4OpenAIChatIdentity,
        promptModules: assistantR4PromptModules,
        readToolRegistry: assistantR2ReadToolRegistry,
        inferenceTransport: assistantR4InferenceTransport,
        generationPolicy: assistantR4GenerationPolicy,
        protocolProbeCatalog: nil,
        liveQualificationCorpus: nil,
        qualificationPolicy: assistantR2UnqualifiedPolicy
    )

    static let reconstructionR1: Phase2AIWorkerProductionProtocolBundle = {
        let artifacts = Phase2ReconstructionProtocolArtifacts.make()
        func identity(_ artifact: Phase2ReconstructionArtifact)
            -> Phase2AIWorkerProtocolComponentIdentity
        {
            .init(
                id: artifact.identity.id,
                version: artifact.identity.version,
                sha256: artifact.identity.sha256
            )
        }
        return makeBundle(
            manifestVersion: 8,
            wireIdentity: reconstructionR1WireIdentity,
            inferenceIdentity: reconstructionR1InferenceIdentity,
            inferenceVersion: reconstructionR1InferenceVersion,
            openAIChatIdentity: reconstructionR1OpenAIChatIdentity,
            promptModules: artifacts.promptModules.map(identity),
            toolSchemaSet: identity(artifacts.schemaBlueprints),
            roundOutputSchema: identity(artifacts.roundOutputSchema),
            finalOutputSchema: identity(artifacts.finalSynthesisSchema),
            groundedContext: reconstructionR1GroundedContext,
            readToolRegistry: identity(artifacts.toolRegistry),
            inferenceTransport: reconstructionR1InferenceTransport,
            generationPolicy: reconstructionR1GenerationPolicy,
            protocolProbeCatalog: nil,
            liveQualificationCorpus: nil,
            qualificationPolicy: assistantR2UnqualifiedPolicy
        )
    }()

    static let reconstructionR2: Phase2AIWorkerProductionProtocolBundle = {
        let artifacts = Phase2ReconstructionProtocolArtifacts.makeR2()
        func identity(_ artifact: Phase2ReconstructionArtifact) -> Phase2AIWorkerProtocolComponentIdentity {
            .init(id: artifact.identity.id, version: artifact.identity.version, sha256: artifact.identity.sha256)
        }
        return makeBundle(
            manifestVersion: 9, wireIdentity: reconstructionR2WireIdentity,
            inferenceIdentity: reconstructionR2InferenceIdentity, inferenceVersion: reconstructionR2InferenceVersion,
            openAIChatIdentity: reconstructionR2OpenAIChatIdentity,
            promptModules: artifacts.promptModules.map(identity), toolSchemaSet: identity(artifacts.schemaBlueprints),
            roundOutputSchema: identity(artifacts.roundOutputSchema), finalOutputSchema: identity(artifacts.finalSynthesisSchema),
            groundedContext: component(id: "reconstruction.readable-context.v9", version: 9, value: .object([
                "semantic_context": .string(reconstructionR1GroundedContext.id),
                "objective": .string("required-job-id-exact-utf8-sha256"),
                "presentation": .string("bounded-readable-evidence-v1"),
                "projection_identity": .string("reconstruction.readable-prompt.r2.v1"),
                "projection_schema_version": .integer(1),
                "context_domain": .string("reconstruction.context.v8"),
                "json_payload_kinds": .array([.string("structuredJSON"), .string("comparison"), .string("index")]),
                "text_payload_kinds": .array([.string("text"), .string("diagnostic")]),
                "binary_representation": .string("binary-omitted"),
                "maximum_context_bytes": .integer(1_048_576),
                "maximum_authority_request_bytes": .integer(1_500_000),
                "maximum_encoded_user_prompt_bytes": .integer(1_572_864),
                "maximum_encoded_provider_body_bytes": .integer(4_194_304),
            ])),
            readToolRegistry: identity(artifacts.toolRegistry),
            inferenceTransport: component(id: "phase2.inference-transport.v9", version: 9, value: .object([
                "ai_worker_wire": .string(reconstructionR2WireIdentity),
                "inference_envelope": .string(reconstructionR2InferenceIdentity),
                "openai_chat": .string(reconstructionR2OpenAIChatIdentity),
            ])),
            generationPolicy: component(id: "reconstruction.generation-policy.v9", version: 9, value: .object([
                "semantic_policy": .string(reconstructionR1GenerationPolicy.sha256),
                "request_commitment": .string("complete-r2-envelope-including-objective"),
                "objective_maximum_utf8_bytes": .integer(4_096),
                "worker_executes_tools": .bool(false),
            ])),
            protocolProbeCatalog: nil, liveQualificationCorpus: nil, qualificationPolicy: assistantR2UnqualifiedPolicy
        )
    }()

    /// Source authoring has its own immutable protocol; R1/R2 remain byte-identical.
    static let reconstructionSourceV10: Phase2AIWorkerProductionProtocolBundle = {
        let schema = CanonicalValue(Phase2ReconstructionSourceOutput.schemaBlueprint)
        return makeBundle(manifestVersion: 10, wireIdentity: "phase2.ai-worker-wire.v10",
            inferenceIdentity: "phase2.inference.v10", inferenceVersion: 10,
            openAIChatIdentity: "phase2.openai-chat.v10",
            promptModules: [component(id: "reconstruction.source-prompt.v10", version: 10,
                value: .string(ReconstructionSourceInferenceContract.systemPrompt))],
            toolSchemaSet: component(id: "reconstruction.source-tools.v10", version: 10, value: .array([])),
            roundOutputSchema: component(id: "reconstruction.source-output.v10", version: 10, value: schema),
            finalOutputSchema: component(id: "reconstruction.source-output.v10", version: 10, value: schema),
            groundedContext: component(id: "reconstruction.source-context.v10", version: 10,
                value: .object(["authority": .string("exact-source-request-v10"), "maximum_source_bytes": .integer(65_536)])),
            readToolRegistry: component(id: "reconstruction.source-registry.v10", version: 10, value: .array([])),
            inferenceTransport: component(id: "reconstruction.source-transport.v10", version: 10,
                value: .object(["wire": .string("phase2.ai-worker-wire.v10"), "channel": .string("sourceRevision")])),
            generationPolicy: component(id: "reconstruction.source-policy.v10", version: 10,
                value: .object(["worker_executes_tools": .bool(false), "candidate_status": .string("proposed"), "profile": .string(ReconstructionSourceInferenceContract.profileID)])),
            protocolProbeCatalog: nil, liveQualificationCorpus: nil, qualificationPolicy: assistantR2UnqualifiedPolicy)
    }()

    // Connection-facing aliases intentionally all derive from the one active standard bundle.
    static let wireIdentity = standard.wireIdentity
    static let inferenceIdentity = standard.inferenceIdentity
    static let inferenceVersion = standard.inferenceVersion
    static let openAIChatIdentity = standard.openAIChatIdentity
    static let inferenceTransport = standard.inferenceTransport
    static let generationPolicy = standard.generationPolicy
    static let protocolProbeCatalog = standard.protocolProbeCatalog!
    static let liveQualificationCorpus = standard.liveQualificationCorpus!
    static let qualificationPolicy = standard.qualificationPolicy
    static let manifestDigest = standard.manifestDigest
    static let manifestIdentity = standard.manifestIdentity

    /// Test seam proving that constituent drift cannot retain the authorized standard manifest.
    static func manifestDigest(
        readToolRegistry: Phase2AIWorkerProtocolComponentIdentity
    ) -> String {
        manifestDigest(
            manifestVersion: standard.manifestVersion,
            promptModules: standard.promptModules,
            finalOutputSchema: standard.finalOutputSchema,
            groundedContext: standard.groundedContext,
            readToolRegistry: readToolRegistry,
            inferenceTransport: standard.inferenceTransport,
            generationPolicy: standard.generationPolicy,
            protocolProbeCatalog: standard.protocolProbeCatalog,
            liveQualificationCorpus: standard.liveQualificationCorpus,
            qualificationPolicy: standard.qualificationPolicy,
            workflowAuthorityPolicy: standard.workflowAuthorityPolicy
        )
    }

    private static func makeBundle(
        manifestVersion: Int,
        wireIdentity: String,
        inferenceIdentity: String,
        inferenceVersion: Int,
        openAIChatIdentity: String,
        promptModules: [Phase2AIWorkerProtocolComponentIdentity] = Phase2AIWorkerProductionProtocol.promptModules,
        toolSchemaSet: Phase2AIWorkerProtocolComponentIdentity? = nil,
        roundOutputSchema: Phase2AIWorkerProtocolComponentIdentity? = nil,
        finalOutputSchema: Phase2AIWorkerProtocolComponentIdentity = Phase2AIWorkerProductionProtocol.finalOutputSchema,
        groundedContext: Phase2AIWorkerProtocolComponentIdentity = Phase2AIWorkerProductionProtocol.groundedContext,
        readToolRegistry: Phase2AIWorkerProtocolComponentIdentity,
        inferenceTransport: Phase2AIWorkerProtocolComponentIdentity,
        generationPolicy: Phase2AIWorkerProtocolComponentIdentity,
        protocolProbeCatalog: Phase2AIWorkerProtocolComponentIdentity?,
        liveQualificationCorpus: Phase2AIWorkerProtocolComponentIdentity?,
        qualificationPolicy: Phase2AIWorkerProtocolComponentIdentity
    ) -> Phase2AIWorkerProductionProtocolBundle {
        let manifestDigest = manifestDigest(
            manifestVersion: manifestVersion,
            promptModules: promptModules,
            toolSchemaSet: toolSchemaSet,
            roundOutputSchema: roundOutputSchema,
            finalOutputSchema: finalOutputSchema,
            groundedContext: groundedContext,
            readToolRegistry: readToolRegistry,
            inferenceTransport: inferenceTransport,
            generationPolicy: generationPolicy,
            protocolProbeCatalog: protocolProbeCatalog,
            liveQualificationCorpus: liveQualificationCorpus,
            qualificationPolicy: qualificationPolicy,
            workflowAuthorityPolicy: workflowAuthorityPolicy
        )
        return .init(
            manifestVersion: manifestVersion,
            wireIdentity: wireIdentity,
            inferenceIdentity: inferenceIdentity,
            inferenceVersion: inferenceVersion,
            openAIChatIdentity: openAIChatIdentity,
            promptModules: promptModules,
            toolSchemaSet: toolSchemaSet,
            roundOutputSchema: roundOutputSchema,
            finalOutputSchema: finalOutputSchema,
            groundedContext: groundedContext,
            readToolRegistry: readToolRegistry,
            inferenceTransport: inferenceTransport,
            generationPolicy: generationPolicy,
            protocolProbeCatalog: protocolProbeCatalog,
            liveQualificationCorpus: liveQualificationCorpus,
            qualificationPolicy: qualificationPolicy,
            workflowAuthorityPolicy: workflowAuthorityPolicy,
            manifestDigest: manifestDigest
        )
    }

    private static func manifestDigest(
        manifestVersion: Int,
        promptModules: [Phase2AIWorkerProtocolComponentIdentity],
        toolSchemaSet: Phase2AIWorkerProtocolComponentIdentity? = nil,
        roundOutputSchema: Phase2AIWorkerProtocolComponentIdentity? = nil,
        finalOutputSchema: Phase2AIWorkerProtocolComponentIdentity,
        groundedContext: Phase2AIWorkerProtocolComponentIdentity,
        readToolRegistry: Phase2AIWorkerProtocolComponentIdentity,
        inferenceTransport: Phase2AIWorkerProtocolComponentIdentity,
        generationPolicy: Phase2AIWorkerProtocolComponentIdentity,
        protocolProbeCatalog: Phase2AIWorkerProtocolComponentIdentity?,
        liveQualificationCorpus: Phase2AIWorkerProtocolComponentIdentity?,
        qualificationPolicy: Phase2AIWorkerProtocolComponentIdentity,
        workflowAuthorityPolicy: Phase2AIWorkerProtocolComponentIdentity
    ) -> String {
        var object: [String: CanonicalValue] = [
            "final_output_schema": componentValue(finalOutputSchema),
            "generation_policy": componentValue(generationPolicy),
            "grounded_context": componentValue(groundedContext),
            "inference_transport": componentValue(inferenceTransport),
            "prompt_modules": .array(promptModules.map(componentValue)),
            "qualification_policy": componentValue(qualificationPolicy),
            "read_tool_registry": componentValue(readToolRegistry),
            "workflow_authority_policy": componentValue(workflowAuthorityPolicy),
        ]
        if manifestVersion >= 2 {
            object["version"] = .integer(manifestVersion)
        }
        if manifestVersion == 2 {
            precondition(protocolProbeCatalog != nil && liveQualificationCorpus != nil)
            object["protocol_probe_catalog"] = componentValue(protocolProbeCatalog!)
            object["live_qualification_corpus"] = componentValue(liveQualificationCorpus!)
        }
        if manifestVersion >= 6 {
            precondition(toolSchemaSet != nil && roundOutputSchema != nil)
            object["tool_schema_set"] = componentValue(toolSchemaSet!)
            object["round_output_schema"] = componentValue(roundOutputSchema!)
        }
        return digest(.object(object))
    }

    private static func component(
        id: String,
        version: Int,
        value: CanonicalValue
    ) -> Phase2AIWorkerProtocolComponentIdentity {
        .init(id: id, version: version, sha256: digest(value))
    }

    private static func componentValue(
        _ identity: Phase2AIWorkerProtocolComponentIdentity
    ) -> CanonicalValue {
        .object([
            "availability": .string("available"),
            "id": .string(identity.id),
            "sha256": .string(identity.sha256),
            "version": .integer(identity.version),
        ])
    }

    private static func digest(_ value: CanonicalValue) -> String {
        SHA256.hash(data: CanonicalEncoder().encode(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum Phase2AIWorkerWirePhase: String, Codable, Equatable, Sendable {
    case toolSelection
    case finalization
    case shellContinuation
}

private indirect enum CanonicalValue {
    case null
    case number(String)
    case bool(Bool)
    case integer(Int)
    case string(String)
    case array([CanonicalValue])
    case object([String: CanonicalValue])

    /// Keep schema structure in the protocol's existing framed canonical representation.
    /// Integer JSON values share the same encoding as existing protocol integers.
    init(_ value: Phase2ProductionJSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .number(let value):
            if let integer = Int(value), String(integer) == value { self = .integer(integer) }
            else { self = .number(value) }
        case .string(let value): self = .string(value)
        case .array(let values): self = .array(values.map(Self.init))
        case .object(let values): self = .object(values.mapValues(Self.init))
        }
    }
}

private struct CanonicalEncoder {
    func encode(_ value: CanonicalValue) -> Data {
        switch value {
        case .null:
            frame("n", Data())
        case .number(let value):
            frame("d", Data(value.utf8))
        case .bool(let value):
            frame("b", Data((value ? "1" : "0").utf8))
        case .integer(let value):
            frame("i", Data(String(value).utf8))
        case .string(let value):
            frame("s", Data(value.utf8))
        case .array(let values):
            frame("a", values.reduce(into: Data()) { $0.append(encode($1)) })
        case .object(let object):
            frame("o", object.keys.sorted(by: utf8Precedes).reduce(into: Data()) { data, key in
                data.append(encode(.string(key)))
                data.append(encode(object[key]!))
            })
        }
    }

    private func frame(_ type: Character, _ payload: Data) -> Data {
        var data = Data("\(type)\(payload.count):".utf8)
        data.append(payload)
        return data
    }

    private func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
