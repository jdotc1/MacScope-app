import Foundation
#if TESTING_WORKER_PRINCIPAL
@testable import MacScope
#endif

struct Phase2ReconstructionOpenAIChatInput: Equatable, Sendable {
    let phase: ReconstructionAIWorkerPhase
    let systemPrompt: String
    let offeredHandles: [ReconstructionOfferedToolHandle]
    let requestBody: Data
    let endpoint: Phase2LoopbackEndpoint
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
    let model: String
    let maximumTokens: Int
    let inferencePolicy: Phase2LocalInferencePolicy?
}

enum Phase2ReconstructionOpenAIChatRequestEncodingError: Error, Equatable {
    case protocolMismatch
    case unsupportedProvider
    case providerBodyLimitExceeded
}

struct Phase2ReconstructionOpenAIChatRequestEncoder: Sendable {
    private let maximumProviderBodyBytes: Int

    init(maximumProviderBodyBytes: Int = ReconstructionReadablePromptProjection.maximumEncodedProviderBodyBytes) {
        self.maximumProviderBodyBytes = maximumProviderBodyBytes
    }

    func encode(
        request: ReconstructionAIWorkerRequest,
        configuration: Phase2AIWorkerConfigurationWire
    ) throws -> Phase2ReconstructionOpenAIChatInput {
        guard configuration.inferencePolicy?.isValid == true else {
            throw Phase2ReconstructionOpenAIChatRequestEncodingError.unsupportedProvider
        }
        guard configuration.protocolManifestDigest == (try request.protocolBundle).manifestDigest else {
            throw Phase2ReconstructionOpenAIChatRequestEncodingError.protocolMismatch
        }
        let readable: ReconstructionReadablePrompt?
        switch request {
        case .roundR2, .finalSynthesisR2:
            readable = try ReconstructionReadablePromptProjection().projectR2(request)
        case .round, .finalSynthesis, .sourceRevision: readable = nil
        }
        let sourceProfileID: String?
        if case .roundR2(let round) = request { sourceProfileID = round.objective.sourceProfileID }
        else { sourceProfileID = nil }
        let catalog = Phase2ReconstructionPromptCatalog()
        let phase: ReconstructionAIWorkerPhase
        let systemPrompt: String
        let handles: [ReconstructionOfferedToolHandle]
        let userData: Data
        let outputSchema: Phase2ProductionJSONSchema
        var tools: [Any]?

        switch request.semanticRequest {
        case .sourceRevision(let source):
            try source.validate()
            phase = .sourceRevision
            systemPrompt = ReconstructionSourceInferenceContract.systemPrompt
            handles = []
            let renderedContext = try sourceReadableContext(source, bundle: (try request.protocolBundle))
            let authorityBytes = try canonicalEncode(source)
            guard var sourceAuthority = try jsonObject(authorityBytes) as? [String: Any] else {
                throw ReconstructionAIWorkerWireError.invalidAuthority
            }
            sourceAuthority.removeValue(forKey: "context")
            userData = try JSONSerialization.data(withJSONObject: [
                "sourceAuthority": sourceAuthority,
                "canonicalSourceRequestSHA256": ReconstructionSourceInferenceContract.sha256(authorityBytes),
                "readableEvidence": renderedContext
            ], options: [.sortedKeys, .withoutEscapingSlashes])
            outputSchema = try Phase2ReconstructionSourceOutput.schema(for: source)
            tools = nil
        case .round(let round):
            #if TESTING_WORKER_PRINCIPAL
            let projectedHandles = round.handles.map {
                ReconstructionOfferedToolHandle(
                    handleID: $0.handleID,
                    operationID: ReconstructionOperationID(rawValue: $0.operationID.rawValue)!
                )
            }
            #else
            let projectedHandles = round.handles
            #endif
            phase = .round
            systemPrompt = readable == nil ? catalog.systemPrompt(for: .planReadObserve)
                : Phase2ReconstructionR2PromptCatalog().systemPrompt(for: .planReadObserve, sourceProfileID: sourceProfileID)
            handles = projectedHandles
            userData = try readable?.userJSON ?? canonicalEncode(round)
            outputSchema = try Phase2ReconstructionOutputSchemas.roundProviderSchema(
                jobID: round.jobID,
                checkpointRevision: round.checkpointRevision,
                roundID: round.roundID,
                offeredHandles: projectedHandles,
                allowedGapSubjects: round.context.allowedGapSubjects,
                allowedGapCategories: round.context.allowedGapCategories,
                allowedGapIDs: round.context.allowedGapIDs,
                retrievedEvidenceIDs: round.context.evidenceIDs
            )
            // R2 requests actions in the strict JSON response, never through
            // native OpenAI function calling. Keep the legacy R1 channel intact.
            if readable == nil {
                tools = try Phase2ReconstructionProductionToolRegistry().project(projectedHandles).map {
                    try jsonObject($0.openAIJSONValue.canonicalJSONBytes())
                }
            }
        case .finalSynthesis(let final):
            phase = .finalSynthesis
            systemPrompt = readable == nil ? catalog.systemPrompt(for: .finalSynthesis)
                : Phase2ReconstructionR2PromptCatalog().systemPrompt(for: .finalSynthesis)
            handles = []
            userData = try readable?.userJSON ?? canonicalEncode(final)
            outputSchema = try Phase2ReconstructionOutputSchemas.finalSynthesisProviderSchema(
                evidenceIDs: final.acceptedEvidenceIDs
            )
            tools = nil
        case .roundR2, .finalSynthesisR2:
            throw Phase2ReconstructionOpenAIChatRequestEncodingError.protocolMismatch
        }

        var body: [String: Any] = [
            "max_tokens": configuration.maximumTokens,
            "messages": [
                ["content": systemPrompt, "role": "system"],
                ["content": String(decoding: userData, as: UTF8.self), "role": "user"],
            ],
            "model": configuration.model,
            "response_format": [
                "json_schema": [
                    "name": phase == .sourceRevision ? ReconstructionSourceInferenceContract.outputName : phase == .round
                        ? Phase2ReconstructionOutputSchemas.roundProviderName
                        : Phase2ReconstructionOutputSchemas.finalProviderName,
                    "schema": try jsonObject(outputSchema.canonicalJSONBytes()),
                    "strict": true,
                ],
                "type": "json_schema",
            ],
            "stream": false,
            "temperature": 0,
        ]
        if let tools {
            body["parallel_tool_calls"] = false
            body["tool_choice"] = "none"
            body["tools"] = tools
        }
        if readable != nil || phase == .sourceRevision {
            // Each reconstruction cut contains its complete app-owned evidence.
            // Retaining the previous, largely non-reusable cut duplicates KV
            // memory during the next prefill on a desktop-sized local model.
            // MTPLX's supported stateless mode changes caching, not precision
            // or the request's authority, reasoning, or output constraints.
            body["metadata"] = ["cache_mode": "stateless"]
        }
        if let policy = configuration.inferencePolicy {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
            try Phase2OpenAIChatRequestEncoder.applyMTPLXPolicy(
                policy, to: &body, maximumTokens: configuration.maximumTokens
            )
        }
        let requestBody = try JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard maximumProviderBodyBytes > 0,
              maximumProviderBodyBytes <= ReconstructionReadablePromptProjection.maximumEncodedProviderBodyBytes,
              requestBody.count <= maximumProviderBodyBytes else {
            throw Phase2ReconstructionOpenAIChatRequestEncodingError.providerBodyLimitExceeded
        }
        return .init(
            phase: phase,
            systemPrompt: systemPrompt,
            offeredHandles: handles,
            requestBody: requestBody,
            endpoint: try Phase2LoopbackEndpoint(validating: configuration.endpointOrigin),
            // The owner enforces warm/cold reconstruction-round budgets. Permit the cold
            // first token to use the configured total ceiling; ordinary AI encoding is unchanged.
            requestTimeoutMilliseconds: configuration.resourceTimeoutMilliseconds,
            resourceTimeoutMilliseconds: configuration.resourceTimeoutMilliseconds,
            model: configuration.model,
            maximumTokens: configuration.maximumTokens,
            inferencePolicy: configuration.inferencePolicy
        )
    }

    /// Source-only envelope. Private wire-shaped DTOs keep oracle/execution/persistence owners out
    /// of the AI worker closure. All supplied text is serialized as evidence in the user message.
    private struct SourceContext: Codable {
        let schemaVersion: Int
        let domain: String
        let corpusManifestSHA256: String
        let evidenceFrontierSHA256: String
        let evidenceIDs: [UUID]
        let baseContext: Data
        let baseContextSHA256: String
        let oracle: OracleSummary
        let parent: ParentSummary?
        let diagnostics: [DiagnosticSummary]
    }
    private struct OracleSummary: Codable {
        let evidenceID: UUID
        let payloadSHA256: String
        let suiteSHA256: String
        let function: ReconstructionFunctionCoordinate
        let profileID: String
        let inputs: [UInt32]
        let outputs: [UInt32]
    }
    private struct ParentSummary: Codable {
        let evidenceID: UUID
        let payloadSHA256: String
        let revisionSHA256: String
        let sourceSHA256: String
        let sourceText: String
    }
    private struct DiagnosticSummary: Codable {
        let evidenceID: UUID
        let payloadSHA256: String
        let operationID: String
        let checkpointRevision: UInt64
        let revisionSHA256: String
        let sourceSHA256: String
        let diagnostic: String
    }

    private func sourceReadableContext(_ source: ReconstructionSourceRevisionRequest,
        bundle: Phase2AIWorkerProductionProtocolBundle) throws -> Any {
        let parsed = try Phase2StrictJSONParser().parse(source.context.canonicalBytes, limits: .init(
            maximumBytes: 1_048_576, maximumDepth: 32, maximumTokens: 65_536,
            maximumMembersAndElements: 32_768))
        guard let object = parsed.objectValue else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        if object["domain"]?.stringValue == "reconstruction.context.v8" {
            // Retained source fixtures only. The production owner selects the v10 envelope.
            return try projectSourceBase(source, context: source.context, bundle: bundle)
        }
        guard object["domain"]?.stringValue == "reconstruction.source-context.v10",
              source.context.canonicalBytes.count <= 32_768 else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        let envelope = try JSONDecoder().decode(SourceContext.self, from: source.context.canonicalBytes)
        guard try canonicalEncode(envelope) == source.context.canonicalBytes,
              envelope.schemaVersion == 10,
              envelope.corpusManifestSHA256 == source.corpusManifestSHA256,
              envelope.evidenceFrontierSHA256 == source.evidenceFrontierSHA256,
              envelope.evidenceIDs == source.context.evidenceIDs,
              envelope.evidenceIDs == envelope.evidenceIDs.sorted(by: { $0.uuidString < $1.uuidString }),
              Set(envelope.evidenceIDs).count == envelope.evidenceIDs.count,
              !envelope.baseContext.isEmpty, envelope.baseContext.count <= 16_384,
              ReconstructionSourceInferenceContract.sha256(envelope.baseContext) == envelope.baseContextSHA256,
              envelope.oracle.suiteSHA256 == source.oracleSuiteSHA256,
              envelope.oracle.profileID == source.profileID,
              envelope.oracle.function == source.function,
              envelope.oracle.inputs == (try ReconstructionSourceProfile.enabled(source.profileID).scalarInputs()),
              envelope.oracle.outputs.count == envelope.oracle.inputs.count,
              envelope.diagnostics.count <= 2 else { throw ReconstructionAIWorkerWireError.invalidAuthority }
        let base = try Phase2StrictJSONParser().parse(envelope.baseContext, limits: .init(
            maximumBytes: 16_384, maximumDepth: 32, maximumTokens: 8_192,
            maximumMembersAndElements: 4_096))
        guard base.canonicalJSONBytes() == envelope.baseContext,
              let baseObject = base.objectValue, let baseValues = baseObject["evidenceIDs"]?.arrayValue else {
            throw ReconstructionAIWorkerWireError.invalidAuthority
        }
        let baseIDs = try baseValues.map { value -> UUID in
            guard let text = value.stringValue, let id = UUID(uuidString: text) else { throw ReconstructionAIWorkerWireError.invalidAuthority }
            return id
        }
        var union = Set(baseIDs)
        union.insert(envelope.oracle.evidenceID)
        var supplementIDs: Set<UUID> = [envelope.oracle.evidenceID]
        var hashes = [envelope.baseContextSHA256, envelope.oracle.payloadSHA256, envelope.oracle.suiteSHA256]
        if let parent = envelope.parent {
            guard source.parentRevisionSHA256 == parent.revisionSHA256,
                  !parent.sourceText.isEmpty, parent.sourceText.utf8.count <= 4_096,
                  !parent.sourceText.utf8.contains(0),
                  ReconstructionSourceInferenceContract.sha256(Data(parent.sourceText.utf8)) == parent.sourceSHA256,
                  supplementIDs.insert(parent.evidenceID).inserted else { throw ReconstructionAIWorkerWireError.invalidAuthority }
            union.insert(parent.evidenceID)
            hashes += [parent.payloadSHA256, parent.revisionSHA256, parent.sourceSHA256]
        } else if source.parentRevisionSHA256 != nil { throw ReconstructionAIWorkerWireError.invalidAuthority }
        let operationOrder = ["reconstruction.source.build", "reconstruction.source.behavior"]
        let aggregateOperation = "reconstruction.source.evaluate"
        let diagnosticOperations = envelope.diagnostics.map(\.operationID)
        // One committed evaluation has one actual evidence ID. Never split it into synthetic
        // build/behavior records or combine it with legacy summaries of the same attempt.
        guard Set(diagnosticOperations).count == diagnosticOperations.count,
              diagnosticOperations == [aggregateOperation]
                || diagnosticOperations == operationOrder.filter({ diagnosticOperations.contains($0) }) else {
            throw ReconstructionAIWorkerWireError.invalidAuthority
        }
        for diagnostic in envelope.diagnostics {
            guard let parent = envelope.parent,
                  diagnostic.revisionSHA256 == parent.revisionSHA256,
                  diagnostic.sourceSHA256 == parent.sourceSHA256,
                  diagnostic.checkpointRevision <= source.checkpointRevision,
                  !diagnostic.diagnostic.isEmpty, diagnostic.diagnostic.utf8.count <= 2_048,
                  !diagnostic.diagnostic.utf8.contains(0),
                  (operationOrder + [aggregateOperation]).contains(diagnostic.operationID),
                  supplementIDs.insert(diagnostic.evidenceID).inserted else { throw ReconstructionAIWorkerWireError.invalidAuthority }
            union.insert(diagnostic.evidenceID)
            hashes += [diagnostic.payloadSHA256, diagnostic.revisionSHA256, diagnostic.sourceSHA256]
        }
        guard union == Set(envelope.evidenceIDs), hashes.allSatisfy(ReconstructionSourceInferenceContract.isSHA256) else {
            throw ReconstructionAIWorkerWireError.invalidAuthority
        }
        let baseContext = ReconstructionRetrievedContext(canonicalBytes: envelope.baseContext,
            canonicalSHA256: envelope.baseContextSHA256, evidenceIDs: baseIDs)
        let readableBase = try projectSourceBase(source, context: baseContext, bundle: bundle)
        var visible: [String: Any] = ["schemaVersion": 10, "domain": envelope.domain,
            "baseEvidence": readableBase,
            "oracle": try jsonObject(canonicalEncode(envelope.oracle)),
            "diagnostics": try jsonObject(canonicalEncode(envelope.diagnostics)),
            "evidenceIDs": envelope.evidenceIDs.map(\.uuidString)]
        if let parent = envelope.parent { visible["parent"] = try jsonObject(canonicalEncode(parent)) }
        return visible
    }

    private func projectSourceBase(_ source: ReconstructionSourceRevisionRequest,
        context: ReconstructionRetrievedContext, bundle: Phase2AIWorkerProductionProtocolBundle) throws -> Any {
        let legacy = ReconstructionInferenceRoundRequest(protocolVersion: 8, jobID: source.jobID,
            checkpointRevision: source.checkpointRevision, roundID: source.roundID,
            corpusManifestSHA256: source.corpusManifestSHA256, evidenceFrontierSHA256: source.evidenceFrontierSHA256,
            registryManifestSHA256: bundle.readToolRegistry.sha256, context: context, handles: [])
        let projected = try ReconstructionReadablePromptProjection().project(.round(legacy),
            objective: .init(jobID: source.jobID, text: source.objective.text, sha256: source.objective.sha256))
        return try jsonObject(projected.userJSON)
    }

    private func canonicalEncode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }
}
