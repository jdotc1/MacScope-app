import CryptoKit
import Foundation

struct Phase2ProductionToolHandle: Equatable, Hashable, Sendable {
    let handleID: UUID
    let operationID: String
}

struct Phase2ProductionToolRegistryEntry: Equatable, Sendable {
    let operationID: String
    let functionName: String
    let description: String
}

struct Phase2ProductionProjectedTool: Equatable, Sendable {
    let operationID: String
    let functionName: String
    let description: String
    let handleID: UUID
    let parameters: Phase2ProductionJSONSchema
    var allowedHandleIDs: [UUID] = []

    var acceptedHandleIDs: [UUID] { allowedHandleIDs.isEmpty ? [handleID] : allowedHandleIDs }

    var openAIJSONValue: Phase2ProductionJSONValue {
        .object([
            "function": .object([
                "description": .string(description),
                "name": .string(functionName),
                "parameters": parameters.canonicalJSONValue(),
            ]),
            "type": .string("function"),
        ])
    }
}

enum Phase2ProductionToolRegistryError: Error, Equatable, Sendable {
    case invalidHandleSet
    case unknownOperation
    case duplicateHandle
    case duplicateOperation
    case schemaConstructionFailed
}

struct Phase2ProductionToolRegistry: Sendable {
    enum Version: Equatable, Sendable {
        case qualificationR1
        case assistantR2
    }

    static let registryID = "phase2.r1.read-tools.v1"
    static let schemaSetID = "phase2.r1.read-tool-schemas.v1"
    static let assistantRegistryID = "phase2.r2.read-tools.v2"
    static let assistantSchemaSetID = "phase2.r2.read-tool-schemas.v2"

    let entries: [Phase2ProductionToolRegistryEntry]
    let version: Version

    init(
        version: Version = .qualificationR1,
        descriptionSuffixForTesting: String = ""
    ) {
        self.version = version
        let workspaceEntries: [Phase2ProductionToolRegistryEntry] = [
            .init(
                operationID: "workspace.summary",
                functionName: "macscope_workspace_summary_v1",
                description: "Summarize the current MacScope workspace using only the app-issued read handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "selection.explain",
                functionName: "macscope_selection_explain_v1",
                description: "Explain the current MacScope selection using only the app-issued read handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "function.review",
                functionName: "macscope_function_review_v1",
                description: "Review the current MacScope function using only the app-issued read handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "decompiler.native.result",
                functionName: "macscope_native_decompilation_v1",
                description: "Read the bounded native-decompiler result for the current function using only the app-issued handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "decompiler.macscope.result",
                functionName: "macscope_decompilation_v1",
                description: "Read the bounded MacScope pseudocode result for the current function using only the app-issued handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "decompiler.compare",
                functionName: "macscope_decompiler_compare_v1",
                description: "Compare the bounded native and MacScope decompiler results for the current function using only the app-issued handle."
                    + descriptionSuffixForTesting
            ),
        ]
        let debuggerEntries: [Phase2ProductionToolRegistryEntry] = [
            .init(
                operationID: "debugger.summary",
                functionName: "macscope_debugger_summary_v1",
                description: "Read the exact current stopped-debugger summary using only the app-issued handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "debugger.frames",
                functionName: "macscope_debugger_frames_v1",
                description: "Read bounded stack frames from the exact current debugger stop using only the app-issued handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "debugger.registers",
                functionName: "macscope_debugger_registers_v1",
                description: "Read bounded registers from the exact current debugger stop using only the app-issued handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "debugger.variables",
                functionName: "macscope_debugger_variables_v1",
                description: "Read the typed variable availability for the exact current debugger frame using only the app-issued handle."
                    + descriptionSuffixForTesting
            ),
            .init(
                operationID: "debugger.memory",
                functionName: "macscope_debugger_memory_v1",
                description: "Read only bounded memory previews already captured for the exact current debugger stop using the app-issued handle."
                    + descriptionSuffixForTesting
            ),
        ]
        let reaEntries: [Phase2ProductionToolRegistryEntry] = [
            .init(operationID: "rea.results.list", functionName: "macscope_rea_results_list_v1",
                description: "List bounded accepted REA evidence summaries with source freshness using only the app-issued handle." + descriptionSuffixForTesting),
            .init(operationID: "rea.results.get", functionName: "macscope_rea_results_get_v1",
                description: "Read a bounded UTF-8 page of the app-selected accepted REA result, bound to its exact response digest." + descriptionSuffixForTesting),
        ]
        entries = workspaceEntries + (version == .assistantR2 ? debuggerEntries + reaEntries : [])
    }

    func entry(forOperationID operationID: String) -> Phase2ProductionToolRegistryEntry? {
        entries.first { $0.operationID == operationID }
    }

    func entry(forFunctionName functionName: String) -> Phase2ProductionToolRegistryEntry? {
        entries.first { $0.functionName == functionName }
    }

    func project(_ handles: [Phase2ProductionToolHandle]) throws -> [Phase2ProductionProjectedTool] {
        guard (1...entries.count).contains(handles.count) else {
            throw Phase2ProductionToolRegistryError.invalidHandleSet
        }
        var byOperation: [String: [Phase2ProductionToolHandle]] = [:]
        var handleIDs: Set<UUID> = []
        for handle in handles {
            guard entry(forOperationID: handle.operationID) != nil else {
                throw Phase2ProductionToolRegistryError.unknownOperation
            }
            guard handleIDs.insert(handle.handleID).inserted else {
                throw Phase2ProductionToolRegistryError.duplicateHandle
            }
            guard byOperation[handle.operationID] == nil || (version == .assistantR2 && handle.operationID == "rea.results.get") else {
                throw Phase2ProductionToolRegistryError.duplicateOperation
            }
            byOperation[handle.operationID, default: []].append(handle)
        }

        return try entries.compactMap { entry in
            guard let group = byOperation[entry.operationID], let handle = group.first else { return nil }
            do {
                let handleSchema = try Phase2ProductionJSONSchema.string(
                    enumeration: group.map { $0.handleID.uuidString }
                )
                let parameters = try Phase2ProductionJSONSchema.object(
                    properties: [.init(name: "handle_id", schema: handleSchema)],
                    required: ["handle_id"]
                )
                return .init(
                    operationID: entry.operationID,
                    functionName: entry.functionName,
                    description: entry.description,
                    handleID: handle.handleID,
                    parameters: parameters,
                    allowedHandleIDs: group.map(\.handleID)
                )
            } catch {
                throw Phase2ProductionToolRegistryError.schemaConstructionFailed
            }
        }
    }
}

struct Phase2ProductionProtocolArtifacts: Equatable, Sendable {
    let promptModules: [Phase2ProductionArtifactIdentity]
    let readToolRegistry: Phase2ProductionArtifactIdentity
    let finalOutputSchema: Phase2ProductionArtifactIdentity
    let qualificationPolicy: Phase2ProductionArtifactIdentity

    var allIdentities: [Phase2ProductionArtifactIdentity] {
        promptModules + [readToolRegistry, finalOutputSchema, qualificationPolicy]
    }

    static func make(
        registryVersion: Phase2ProductionToolRegistry.Version = .qualificationR1,
        registryDescriptionSuffixForTesting suffix: String = "",
        promptModuleSuffixForTesting promptSuffix: String = "",
        promptModuleOrderForTesting promptOrder: [Int] = [0, 1, 2, 3],
        registryOrderForTesting order: [Int]? = nil,
        schemaSetVersionForTesting schemaSetVersion: String? = nil,
        schemaEnumSourceForTesting schemaEnumSource: String = "exact-app-issued-handle-id",
        finalSchemaForTesting finalSchema: Phase2ProductionJSONValue? = nil,
        probeMutationForTesting probeMutation: Phase2ProductionProtocolProbeCatalog.TestMutation? = nil
    ) -> Self {
        let catalog = Phase2GroundedPromptCatalog()
        let orderedModules = promptOrder.compactMap {
            catalog.modules.indices.contains($0) ? catalog.modules[$0] : nil
        }
        let moduleIdentities = orderedModules.map { module in
            artifactIdentity(
                id: module.id,
                version: 1,
                value: .object([
                    "content": .string(module.content + promptSuffix),
                    "id": .string(module.id),
                    "version": .integer(1),
                ])
            )
        }

        let registry = Phase2ProductionToolRegistry(
            version: registryVersion,
            descriptionSuffixForTesting: suffix
        )
        let registryID: String
        let schemaSetID: String
        switch registryVersion {
        case .qualificationR1:
            registryID = Phase2ProductionToolRegistry.registryID
            schemaSetID = Phase2ProductionToolRegistry.schemaSetID
        case .assistantR2:
            registryID = Phase2ProductionToolRegistry.assistantRegistryID
            schemaSetID = Phase2ProductionToolRegistry.assistantSchemaSetID
        }
        let order = order ?? Array(registry.entries.indices)
        let orderedEntries = order.compactMap { registry.entries.indices.contains($0) ? registry.entries[$0] : nil }
        let registryEntries: [Phase2ProductionJSONValue] = orderedEntries.map { entry in
            .object([
                "description": .string(entry.description),
                "function_name": .string(entry.functionName),
                "operation_id": .string(entry.operationID),
            ])
        }
        let schemaTemplates: [Phase2ProductionJSONValue] = orderedEntries.map { entry in
            // Artifact identity binds the single-handle schema grammar without binding a turn UUID.
            .object([
                "function_name": .string(entry.functionName),
                "parameters": .object([
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "handle_id": .object([
                            "enum_source": .string(schemaEnumSource),
                            "type": .string("string"),
                        ]),
                    ]),
                    "required": .array([.string("handle_id")]),
                    "type": .string("object"),
                ]),
            ])
        }
        let registryIdentity = artifactIdentity(
            id: registryID,
            version: registryVersion == .qualificationR1 ? 1 : 2,
            value: .object([
                "registry_entries": .array(registryEntries),
                "registry_version": .string(registryID),
                "schema_set": .array(schemaTemplates),
                "schema_set_version": .string(schemaSetVersion ?? schemaSetID),
            ])
        )
        let finalSchemaIdentity = artifactIdentity(
            id: Phase2GroundedFinalSchema.artifactID,
            version: 1,
            value: finalSchema ?? Phase2GroundedFinalSchema.schema.canonicalJSONValue()
        )
        return .init(
            promptModules: moduleIdentities,
            readToolRegistry: registryIdentity,
            finalOutputSchema: finalSchemaIdentity,
            qualificationPolicy: Phase2ProductionProtocolProbeCatalog(
                mutationForTesting: probeMutation
            )
                .qualificationPolicyIdentity
        )
    }

    static func artifactIdentity(
        id: String,
        version: Int,
        value: Phase2ProductionJSONValue
    ) -> Phase2ProductionArtifactIdentity {
        let framed = Phase2ProductionLengthFramedEncoder().encode(value)
        let hex = Array("0123456789abcdef".utf8)
        let digestBytes = SHA256.hash(data: framed).flatMap { byte in
            [hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
        }
        let digest = String(decoding: digestBytes, as: UTF8.self)
        return .init(id: id, version: version, sha256: digest)
    }
}

struct Phase2ProductionLengthFramedEncoder: Sendable {
    func encode(_ value: Phase2ProductionJSONValue) -> Data {
        switch value {
        case .null:
            return frame("n", Data())
        case .bool(let value):
            return frame("b", Data((value ? "1" : "0").utf8))
        case .number(let value):
            return frame("i", Data(value.utf8))
        case .string(let value):
            return frame("s", Data(value.utf8))
        case .array(let values):
            return frame("a", values.reduce(into: Data()) { $0.append(encode($1)) })
        case .object(let object):
            var payload = Data()
            for key in object.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                payload.append(encode(.string(key)))
                payload.append(encode(object[key]!))
            }
            return frame("o", payload)
        }
    }

    private func frame(_ type: Character, _ payload: Data) -> Data {
        var data = Data("\(type)\(payload.count):".utf8)
        data.append(payload)
        return data
    }
}

enum Phase2GroundedFinalSchema {
    static let artifactID = "phase2.r1.grounded-final.v1"
    static let providerName = "macscope_grounded_final_v1"

    static let schema: Phase2ProductionJSONSchema = Phase2GroundedFinalSchema.schema(proposalOperations: [])

    /// The grounded final schema. Explain Selection and Review Function requests carry an
    /// app-authored proposal section; for those the schema also requires `proposal`, one inert
    /// authoring proposal limited to the operations that section allows. When the section
    /// names the app's proposal anchor (`anchored`), the proposal is a required object;
    /// otherwise it may be null.
    static func schema(proposalOperations: [String], anchored: Bool = false) -> Phase2ProductionJSONSchema {
        let kind = try! Phase2ProductionJSONSchema.string(
            enumeration: ["answer", "insufficient_evidence"]
        )
        let text = try! Phase2ProductionJSONSchema.string(maxLength: 60_000)
        let evidenceID = try! Phase2ProductionJSONSchema.string(minLength: 36, maxLength: 36)
        let evidenceIDs = try! Phase2ProductionJSONSchema.array(
            items: evidenceID,
            maxItems: 3,
            uniqueItems: true
        )
        let reason = try! Phase2ProductionJSONSchema.string(maxLength: 4_096)
        var properties: [Phase2ProductionJSONSchema.Property] = [
            .init(name: "kind", schema: kind),
            .init(name: "text", schema: text),
            .init(name: "evidence_ids", schema: evidenceIDs),
            .init(name: "reason", schema: reason),
        ]
        var required = ["kind", "text", "evidence_ids", "reason"]
        if !proposalOperations.isEmpty {
            let proposal = try! Phase2ProductionJSONSchema.object(
                properties: [
                    .init(name: "operation", schema: try! .string(enumeration: proposalOperations)),
                    .init(name: "value", schema: try! .string(
                        minLength: 1,
                        maxLength: Phase2GroundedFinalProposal.maximumValueBytes
                    )),
                    .init(name: "evidence_id", schema: evidenceID),
                ],
                required: ["operation", "value", "evidence_id"]
            )
            properties.append(.init(name: "proposal", schema: anchored ? proposal : .nullable(proposal)))
            required.append("proposal")
        }
        return try! Phase2ProductionJSONSchema.object(properties: properties, required: required)
    }
}
