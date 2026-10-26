import CryptoKit
import Foundation

struct Phase2ReconstructionArtifact: Equatable, Sendable {
    let identity: Phase2ProductionArtifactIdentity
    let canonicalBytes: Data
}

struct Phase2ReconstructionProtocolArtifacts: Equatable, Sendable {
    let toolRegistry: Phase2ReconstructionArtifact
    let schemaBlueprints: Phase2ReconstructionArtifact
    let roundOutputSchema: Phase2ReconstructionArtifact
    let finalSynthesisSchema: Phase2ReconstructionArtifact
    let promptModules: [Phase2ReconstructionArtifact]

    var all: [Phase2ReconstructionArtifact] {
        [toolRegistry, schemaBlueprints, roundOutputSchema, finalSynthesisSchema] + promptModules
    }

    static func make() -> Self {
        let registry = Phase2ReconstructionProductionToolRegistry()
        let registryEntries = registry.entries.map { entry in
            Phase2ProductionJSONValue.object([
                "description": .string(entry.description),
                "function_name": .string(entry.functionName),
                "operation_id": .string(entry.operationID.rawValue),
            ])
        }
        let schemas = registry.entries.map { entry in
            Phase2ProductionJSONValue.object([
                "function_name": .string(entry.functionName),
                "parameters": .object([
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "handle_id": .object([
                            "enum_source": .string("exact-app-offered-handle-id"),
                            "format": .string("uppercase-canonical-uuid"),
                            "type": .string("string"),
                        ]),
                    ]),
                    "required": .array([.string("handle_id")]),
                    "type": .string("object"),
                ]),
            ])
        }
        let modules = Phase2ReconstructionPromptCatalog().modules.map { module in
            let version = module.id == "reconstruction.plan-read-observe.v8" ? 8 : 1
            return artifact(
                id: module.id,
                version: version,
                value: .object([
                    "content": .string(module.content),
                    "id": .string(module.id),
                    "version": .integer(version),
                ])
            )
        }
        return .init(
            toolRegistry: artifact(
                id: Phase2ReconstructionProductionToolRegistry.registryID,
                value: .object([
                    "entries": .array(registryEntries),
                    "registry_id": .string(Phase2ReconstructionProductionToolRegistry.registryID),
                    "registry_version": .integer(
                        Phase2ReconstructionProductionToolRegistry.registryVersion
                    ),
                ])
            ),
            schemaBlueprints: artifact(
                id: Phase2ReconstructionProductionToolRegistry.schemaSetID,
                value: .object([
                    "schema_set_id": .string(
                        Phase2ReconstructionProductionToolRegistry.schemaSetID
                    ),
                    "schema_set_version": .integer(
                        Phase2ReconstructionProductionToolRegistry.schemaSetVersion
                    ),
                    "schemas": .array(schemas),
                ])
            ),
            roundOutputSchema: artifact(
                id: Phase2ReconstructionOutputSchemas.roundArtifactID,
                version: 8,
                value: Phase2ReconstructionOutputSchemas.roundBlueprint
            ),
            finalSynthesisSchema: artifact(
                id: Phase2ReconstructionOutputSchemas.finalArtifactID,
                value: Phase2ReconstructionOutputSchemas.finalBlueprint
            ),
            promptModules: modules
        )
    }

    static func makeR2() -> Self {
        let legacy = make()
        let module = Phase2ReconstructionR2PromptCatalog().modules[4]
        let objectiveModule = artifact(id: module.id, version: 11, value: .object([
            "content": .string(module.content), "id": .string(module.id), "version": .integer(11),
        ]))
        let source = Phase2ReconstructionR2PromptCatalog.sourceEntryModule
        let sourceModule = artifact(id: source.id, value: .object([
            "content": .string(source.content), "id": .string(source.id), "version": .integer(1),
        ]))
        return .init(toolRegistry: legacy.toolRegistry, schemaBlueprints: legacy.schemaBlueprints,
                     roundOutputSchema: legacy.roundOutputSchema, finalSynthesisSchema: legacy.finalSynthesisSchema,
                     promptModules: legacy.promptModules + [objectiveModule, sourceModule])
    }

    private static func artifact(
        id: String,
        version: Int = 1,
        value: Phase2ProductionJSONValue
    ) -> Phase2ReconstructionArtifact {
        let bytes = Phase2ProductionLengthFramedEncoder().encode(value)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(
            identity: .init(id: id, version: version, sha256: digest),
            canonicalBytes: bytes
        )
    }
}

enum Phase2ReconstructionOutputSchemas {
    static let roundArtifactID = "reconstruction.round-output.v8"
    static let finalArtifactID = "reconstruction.final-synthesis.v1"
    static let roundProviderName = "reconstruction_round_output_v8"
    static let finalProviderName = "reconstruction_final_synthesis_v1"
    private static let maximumEvidenceIDs = 4_096
    private static let maximumGapDeclarations = 64
    private static let maximumGapReasonLength = 1_024

    static let roundBlueprint: Phase2ProductionJSONValue = .object([
        "additionalProperties": .bool(false),
        "properties": .object([
            "checkpoint_revision": .object([
                "enum_source": .string("exact-supplied-checkpoint-revision"),
                "type": .string("integer"),
            ]),
            "disposition": .object([
                "enum": .array([
                    .string("continue"), .string("sufficientEvidence"), .string("blocked"),
                ]),
                "type": .string("string"),
            ]),
            "job_id": symbolicUUID("exact-supplied-job-id"),
            "round_id": symbolicUUID("exact-supplied-round-id"),
            "selected_handle_ids": .object([
                "items": symbolicUUID("exact-offered-handle-ids"),
                "maxItems": .integer(15),
                "type": .string("array"),
                "uniqueItems": .bool(true),
            ]),
            "resolved_gaps": .object([
                "items": .object([
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "evidence_id": symbolicUUID("exact-retrieved-evidence-ids"),
                        "gap_id": symbolicUUID("exact-supplied-gap-ids"),
                        "handle_id": symbolicUUID("exact-selected-handle-ids"),
                    ]),
                    "required": .array([
                        .string("gap_id"), .string("handle_id"), .string("evidence_id"),
                    ]),
                    "type": .string("object"),
                ]),
                "maxItems": .integer(maximumGapDeclarations),
                "type": .string("array"),
                "uniqueItems": .bool(true),
            ]),
            "unresolved_gaps": .object([
                "items": .object([
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "category": symbolicString("exact-supplied-gap-categories"),
                        "reason": .object([
                            "maxLength": .integer(maximumGapReasonLength),
                            "minLength": .integer(1),
                            "type": .string("string"),
                        ]),
                        "subject": symbolicString("exact-supplied-gap-subjects"),
                    ]),
                    "required": .array([
                        .string("subject"), .string("category"), .string("reason"),
                    ]),
                    "type": .string("object"),
                ]),
                "maxItems": .integer(maximumGapDeclarations),
                "type": .string("array"),
                "uniqueItems": .bool(true),
            ]),
        ]),
        "required": .array([
            .string("job_id"), .string("checkpoint_revision"), .string("round_id"),
            .string("disposition"), .string("selected_handle_ids"),
            .string("unresolved_gaps"), .string("resolved_gaps"),
        ]),
        "type": .string("object"),
    ])

    static let finalBlueprint: Phase2ProductionJSONValue = .object([
        "additionalProperties": .bool(false),
        "anyOf": .array([
            finalBlueprintBranch(
                kind: "synthesis",
                maximumTextLength: 60_000,
                minimumEvidenceCount: 1,
                maximumEvidenceCount: 4_096
            ),
            finalBlueprintBranch(
                kind: "insufficientEvidence",
                maximumTextLength: 4_096,
                minimumEvidenceCount: nil,
                maximumEvidenceCount: 0
            ),
        ]),
        "properties": .object([
            "evidence_ids": .object([
                "items": symbolicUUID("exact-accepted-evidence-ids"),
                "maxItems": .integer(4_096),
                "type": .string("array"),
                "uniqueItems": .bool(true),
            ]),
            "kind": .object([
                "enum": .array([.string("synthesis"), .string("insufficientEvidence")]),
                "type": .string("string"),
            ]),
            "text": .object([
                "maxLength": .integer(60_000),
                "minLength": .integer(1),
                "type": .string("string"),
            ]),
        ]),
        "required": .array([
            .string("kind"), .string("text"), .string("evidence_ids"),
        ]),
        "type": .string("object"),
    ])

    static func roundProviderSchema(
        jobID: UUID,
        checkpointRevision: UInt64,
        roundID: UUID,
        offeredHandles: [ReconstructionOfferedToolHandle],
        allowedGapSubjects: [String],
        allowedGapCategories: [String],
        allowedGapIDs: [UUID],
        retrievedEvidenceIDs: [UUID]
    ) throws -> Phase2ProductionJSONSchema {
        try requireUnique(offeredHandles.map(\.handleID))
        try requireUnique(offeredHandles.map(\.operationID))
        try requireBoundedEnumeration(allowedGapSubjects)
        try requireBoundedEnumeration(allowedGapCategories)
        guard allowedGapIDs.count <= maximumGapDeclarations,
              Set(allowedGapIDs).count == allowedGapIDs.count,
              retrievedEvidenceIDs.count <= maximumEvidenceIDs,
              Set(retrievedEvidenceIDs).count == retrievedEvidenceIDs.count else {
            throw Phase2ProductionJSONSchemaError.invalidEnumeration
        }
        let maximumRoundGapDeclarations = allowedGapSubjects.isEmpty
            || allowedGapCategories.isEmpty ? 0 : maximumGapDeclarations
        let gapDeclaration = try Phase2ProductionJSONSchema.object(
            properties: [
                .init(
                    name: "subject",
                    schema: try gapEnumerationSchema(allowedGapSubjects)
                ),
                .init(
                    name: "category",
                    schema: try gapEnumerationSchema(allowedGapCategories)
                ),
                .init(
                    name: "reason",
                    schema: try .string(
                        minLength: 1,
                        maxLength: maximumGapReasonLength
                    )
                ),
            ],
            required: ["subject", "category", "reason"]
        )
        let gapResolutionClaim = try Phase2ProductionJSONSchema.object(
            properties: [
                .init(
                    name: "gap_id",
                    schema: allowedGapIDs.isEmpty
                        ? try .string(minLength: 36, maxLength: 36)
                        : try .string(enumeration: allowedGapIDs.map { $0.uuidString }.sorted())
                ),
                .init(
                    name: "handle_id",
                    schema: offeredHandles.isEmpty
                        ? try .string(minLength: 36, maxLength: 36)
                        : try .string(
                            enumeration: offeredHandles.map { $0.handleID.uuidString }.sorted()
                        )
                ),
                .init(
                    name: "evidence_id",
                    schema: retrievedEvidenceIDs.isEmpty
                        ? try .string(minLength: 36, maxLength: 36)
                        : try .string(
                            enumeration: retrievedEvidenceIDs.map { $0.uuidString }.sorted()
                        )
                ),
            ],
            required: ["gap_id", "handle_id", "evidence_id"]
        )
        return try .object(
            properties: [
                .init(name: "job_id", schema: try .string(enumeration: [jobID.uuidString])),
                .init(
                    name: "checkpoint_revision",
                    schema: try .exactUInt64(checkpointRevision)
                ),
                .init(name: "round_id", schema: try .string(enumeration: [roundID.uuidString])),
                .init(
                    name: "disposition",
                    schema: try .string(
                        enumeration: ["continue", "sufficientEvidence", "blocked"]
                    )
                ),
                .init(
                    name: "selected_handle_ids",
                    schema: try uuidArray(offeredHandles.map(\.handleID))
                ),
                .init(
                    name: "unresolved_gaps",
                    schema: try .array(
                        items: gapDeclaration,
                        maxItems: maximumRoundGapDeclarations,
                        uniqueItems: true
                    )
                ),
                .init(
                    name: "resolved_gaps",
                    schema: try .array(
                        items: gapResolutionClaim,
                        maxItems: min(allowedGapIDs.count, retrievedEvidenceIDs.count),
                        uniqueItems: true
                    )
                ),
            ],
            required: [
                "job_id", "checkpoint_revision", "round_id", "disposition",
                "selected_handle_ids", "unresolved_gaps", "resolved_gaps",
            ]
        )
    }

    static func finalSynthesisProviderSchema(
        evidenceIDs: [UUID]
    ) throws -> Phase2ProductionJSONSchema {
        guard evidenceIDs.count <= maximumEvidenceIDs else {
            throw Phase2ProductionJSONSchemaError.invalidEnumeration
        }
        try requireUnique(evidenceIDs)
        let insufficientEvidence = try Phase2ProductionJSONSchema.object(
            properties: [
                .init(
                    name: "kind",
                    schema: try .string(enumeration: ["insufficientEvidence"])
                ),
                .init(
                    name: "text",
                    schema: try .string(minLength: 1, maxLength: 4_096)
                ),
                .init(name: "evidence_ids", schema: try uuidArray([])),
            ],
            required: ["kind", "text", "evidence_ids"]
        )
        guard !evidenceIDs.isEmpty else { return insufficientEvidence }
        let synthesis = try Phase2ProductionJSONSchema.object(
            properties: [
                .init(
                    name: "kind",
                    schema: try .string(enumeration: ["synthesis"])
                ),
                .init(
                    name: "text",
                    schema: try .string(minLength: 1, maxLength: 60_000)
                ),
                .init(
                    name: "evidence_ids",
                    schema: try uuidArray(evidenceIDs, minimumItems: 1)
                ),
            ],
            required: ["kind", "text", "evidence_ids"]
        )
        return try .discriminatedObject(
            properties: [
                .init(
                    name: "kind",
                    schema: try .string(
                        enumeration: ["synthesis", "insufficientEvidence"]
                    )
                ),
                .init(
                    name: "text",
                    schema: try .string(minLength: 1, maxLength: 60_000)
                ),
                .init(name: "evidence_ids", schema: try uuidArray(evidenceIDs)),
            ],
            required: ["kind", "text", "evidence_ids"],
            alternatives: [synthesis, insufficientEvidence]
        )
    }

    private static func uuidArray(
        _ values: [UUID],
        minimumItems: Int? = nil
    ) throws -> Phase2ProductionJSONSchema {
        let strings = values.map(\.uuidString).sorted()
        let item = strings.isEmpty
            ? try Phase2ProductionJSONSchema.string(minLength: 36, maxLength: 36)
            : try Phase2ProductionJSONSchema.string(enumeration: strings)
        return try .array(
            items: item,
            minItems: minimumItems,
            maxItems: strings.count,
            uniqueItems: true
        )
    }

    private static func finalBlueprintBranch(
        kind: String,
        maximumTextLength: Int,
        minimumEvidenceCount: Int?,
        maximumEvidenceCount: Int
    ) -> Phase2ProductionJSONValue {
        var evidenceSchema: [String: Phase2ProductionJSONValue] = [
            "items": symbolicUUID("exact-accepted-evidence-ids"),
            "maxItems": .integer(maximumEvidenceCount),
            "type": .string("array"),
            "uniqueItems": .bool(true),
        ]
        if let minimumEvidenceCount {
            evidenceSchema["minItems"] = .integer(minimumEvidenceCount)
        }
        return .object([
            "additionalProperties": .bool(false),
            "properties": .object([
                "evidence_ids": .object(evidenceSchema),
                "kind": .object([
                    "enum": .array([.string(kind)]),
                    "type": .string("string"),
                ]),
                "text": .object([
                    "maxLength": .integer(maximumTextLength),
                    "minLength": .integer(1),
                    "type": .string("string"),
                ]),
            ]),
            "required": .array([
                .string("kind"), .string("text"), .string("evidence_ids"),
            ]),
            "type": .string("object"),
        ])
    }

    private static func symbolicUUID(_ source: String) -> Phase2ProductionJSONValue {
        .object([
            "enum_source": .string(source),
            "format": .string("uppercase-canonical-uuid"),
            "type": .string("string"),
        ])
    }

    private static func symbolicString(_ source: String) -> Phase2ProductionJSONValue {
        .object([
            "enum_source": .string(source),
            "type": .string("string"),
        ])
    }

    private static func requireUnique<T: Hashable>(_ values: [T]) throws {
        guard Set(values).count == values.count else {
            throw Phase2ReconstructionToolRegistryError.invalidHandleSet
        }
    }

    private static func requireBoundedEnumeration(_ values: [String]) throws {
        guard (0...maximumGapDeclarations).contains(values.count),
              Set(values).count == values.count,
              values.allSatisfy({ value in
                  (1...512).contains(value.utf8.count)
                      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else {
            throw Phase2ReconstructionToolRegistryError.invalidHandleSet
        }
    }

    private static func gapEnumerationSchema(
        _ values: [String]
    ) throws -> Phase2ProductionJSONSchema {
        if values.isEmpty {
            return try .string(minLength: 1, maxLength: 1)
        }
        return try .string(enumeration: values.sorted())
    }
}
