import Foundation

struct Phase2ReconstructionToolRegistryEntry: Equatable, Sendable {
    let operationID: ReconstructionOperationID
    let functionName: String
    let description: String
}

struct Phase2ReconstructionProjectedTool: Equatable, Sendable {
    let operationID: ReconstructionOperationID
    let functionName: String
    let description: String
    let handleID: UUID
    let parameters: Phase2ProductionJSONSchema

    var openAIJSONValue: Phase2ProductionJSONValue {
        .object([
            "function": .object([
                "description": .string(description),
                "name": .string(functionName),
                "parameters": parameters.canonicalJSONValue(),
                "strict": .bool(true),
            ]),
            "type": .string("function"),
        ])
    }
}

enum Phase2ReconstructionToolRegistryError: Error, Equatable, Sendable {
    case invalidHandleSet
    case unknownOperation
    case duplicateHandle
    case duplicateOperation
    case schemaConstructionFailed
    case invalidArguments
}

struct Phase2ReconstructionProductionToolRegistry: Sendable {
    static let registryID = "reconstruction.v1"
    static let registryVersion = 1
    static let schemaSetID = "reconstruction.v1.schemas"
    static let schemaSetVersion = 1

    static let orderedMetadata: [Phase2ReconstructionToolRegistryEntry] = [
        entry(.corpusSummary, "Read the immutable reconstruction corpus summary."),
        entry(.corpusArtifactsPage, "Read an app-bounded page of corpus artifacts."),
        entry(.corpusArtifactDescribe, "Describe one app-selected corpus artifact."),
        entry(.corpusRelationsPage, "Read an app-bounded page of corpus relations."),
        entry(.corpusSearch, "Read app-compiled corpus search results."),
        entry(.imagesPage, "Read an app-bounded page of analyzed images."),
        entry(.functionsPage, "Read an app-bounded page of analyzed functions."),
        entry(.functionReview, "Review one app-selected function."),
        entry(.decompilerNative, "Read one app-selected native decompilation."),
        entry(.decompilerMacScope, "Read one app-selected MacScope decompilation."),
        entry(.decompilerCompare, "Compare app-selected decompiler results."),
        entry(.evidenceQuery, "Read app-compiled deterministic evidence results."),
        entry(.evidenceGet, "Read one app-selected durable evidence record."),
        entry(.gapsPage, "Read an app-bounded page of unresolved evidence gaps."),
        entry(.checkpointStatus, "Read the immutable reconstruction checkpoint status."),
        entry(.analysisMacScopeRefresh, "Request one fresh MacScope analysis of the app-selected committed function. Select with continue; analysis runs after the selection commits, before the next model round."),
    ]

    let entries = Self.orderedMetadata

    func project(
        _ handles: [ReconstructionOfferedToolHandle]
    ) throws -> [Phase2ReconstructionProjectedTool] {
        guard (1...entries.count).contains(handles.count) else {
            throw Phase2ReconstructionToolRegistryError.invalidHandleSet
        }
        var byOperation: [ReconstructionOperationID: ReconstructionOfferedToolHandle] = [:]
        var handleIDs: Set<UUID> = []
        for handle in handles {
            guard entries.contains(where: { $0.operationID == handle.operationID }) else {
                throw Phase2ReconstructionToolRegistryError.unknownOperation
            }
            guard handleIDs.insert(handle.handleID).inserted else {
                throw Phase2ReconstructionToolRegistryError.duplicateHandle
            }
            guard byOperation.updateValue(handle, forKey: handle.operationID) == nil else {
                throw Phase2ReconstructionToolRegistryError.duplicateOperation
            }
        }
        return try entries.compactMap { entry in
            guard let handle = byOperation[entry.operationID] else { return nil }
            do {
                return .init(
                    operationID: entry.operationID,
                    functionName: entry.functionName,
                    description: entry.description,
                    handleID: handle.handleID,
                    parameters: try .object(
                        properties: [.init(
                            name: "handle_id",
                            schema: try .string(enumeration: [handle.handleID.uuidString])
                        )],
                        required: ["handle_id"]
                    )
                )
            } catch {
                throw Phase2ReconstructionToolRegistryError.schemaConstructionFailed
            }
        }
    }

    func validateArguments(
        _ data: Data,
        for tool: Phase2ReconstructionProjectedTool
    ) throws {
        do {
            let value = try Phase2StrictJSONParser().parse(
                data,
                limits: .toolArguments,
                requiringUnescapedStringValuesForObjectKeys: ["handle_id"]
            )
            guard let object = value.objectValue,
                  object.count == 1,
                  object["handle_id"]?.stringValue == tool.handleID.uuidString else {
                throw Phase2ReconstructionToolRegistryError.invalidArguments
            }
        } catch let error as Phase2ReconstructionToolRegistryError {
            throw error
        } catch {
            throw Phase2ReconstructionToolRegistryError.invalidArguments
        }
    }

    private static func entry(
        _ operationID: ReconstructionOperationID,
        _ description: String
    ) -> Phase2ReconstructionToolRegistryEntry {
        .init(
            operationID: operationID,
            functionName: "macscope_\(operationID.rawValue.replacingOccurrences(of: ".", with: "_"))_v1",
            description: description
        )
    }
}
