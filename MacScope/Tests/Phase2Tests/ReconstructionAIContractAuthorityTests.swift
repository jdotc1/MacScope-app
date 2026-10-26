#if MACSCOPE_RECONSTRUCTION_AI_CONTRACT_STANDALONE
import Foundation

struct Phase2ProductionArtifactIdentity: Equatable, Sendable {
    let id: String
    let version: Int
    let sha256: String
}

struct Phase2ProductionLengthFramedEncoder: Sendable {
    func encode(_ value: Phase2ProductionJSONValue) -> Data {
        value.canonicalJSONBytes()
    }
}

struct Phase2GroundedPromptModule: Equatable, Sendable {
    let id: String
    let content: String
}

enum ReconstructionAIWorkerPhase: String, Codable, Sendable {
    case round
    case finalSynthesis
}

struct Phase2AIWorkerConfigurationWire: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let profileID: UUID
    let generation: UInt64
    let endpointOrigin: String
    let model: String
    let protocolManifestDigest: String
    let maximumTokens: Int
    let requestTimeoutMilliseconds: Int
    let resourceTimeoutMilliseconds: Int
    let inferencePolicy: Phase2LocalInferencePolicy?
}

struct Phase2AIWorkerWireUsage: Codable, Equatable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

struct Phase2StrictJSONValidator {
    static func validate(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}
#else
import XCTest

@testable import MacScope
#endif

#if !MACSCOPE_RECONSTRUCTION_AI_CONTRACT_STANDALONE
final class ReconstructionAIContractAuthorityTests: XCTestCase {
    func testProjectedFunctionToolsRequireStrictClosedArguments() throws {
        try ReconstructionAIContractProof.projectedFunctionToolsRequireStrictClosedArguments()
    }

    func testRequestsUseProviderSafeNamesAndDisableProviderToolCalls() throws {
        try ReconstructionAIContractProof.requestsUseProviderSafeNamesAndDisableProviderToolCalls()
    }

    func testSchemasRejectEvidenceAuthorityBeyondFrozenBounds() throws {
        try ReconstructionAIContractProof.schemasRejectEvidenceAuthorityBeyondFrozenBounds()
    }

    func testAccumulatorRejectsNormalizedAuthorityIdentitySpellings() throws {
        try ReconstructionAIContractProof.accumulatorRejectsNormalizedAuthorityIdentitySpellings()
    }

    func testAccumulatorRetiresAfterOutputBoundFailure() throws {
        try ReconstructionAIContractProof.accumulatorRetiresAfterOutputBoundFailure()
    }

    func testAccumulatorRejectsCompletionUsageAboveProtocolCeiling() throws {
        try ReconstructionAIContractProof.accumulatorRejectsCompletionUsageAboveProtocolCeiling()
    }

    func testAccumulatorPreservesSchemaValidHighCardinalityOutput() throws {
        try ReconstructionAIContractProof.accumulatorPreservesSchemaValidHighCardinalityOutput()
    }
}
#endif

private enum ReconstructionAIContractProof {
    static func projectedFunctionToolsRequireStrictClosedArguments() throws {
        let handleID = contractID(10)
        let tool = try requireValue(
            Phase2ReconstructionProductionToolRegistry().project([
                .init(handleID: handleID, operationID: .corpusSummary),
            ]).first,
            "projected tool"
        )
        let root = try requireValue(tool.openAIJSONValue.objectValue, "tool object")
        let function = try requireValue(root["function"]?.objectValue, "function object")
        try require(function["strict"] == .bool(true), "projected function omitted strict=true")
        let parameters = try requireValue(function["parameters"]?.objectValue, "parameters")
        try require(
            parameters["additionalProperties"] == .bool(false),
            "projected parameters were not closed"
        )
    }

    static func requestsUseProviderSafeNamesAndDisableProviderToolCalls() throws {
        let encoder = Phase2ReconstructionOpenAIChatRequestEncoder()
        let round = try encoder.encode(
            request: .round(contractRoundRequest()),
            configuration: contractConfiguration()
        )
        let roundBody = try requestObject(round.requestBody)
        let roundSchemaName = try responseSchemaName(roundBody)
        try require(
            roundSchemaName == "reconstruction_round_output_v8",
            "round response schema used a non-provider-safe name"
        )
        try require(
            roundBody["tool_choice"] as? String == "none",
            "round request allowed the provider to emit unsupported tool calls"
        )
        try require(
            roundBody["parallel_tool_calls"] as? Bool == false,
            "round request did not explicitly disable parallel provider tool calls"
        )

        let final = try encoder.encode(
            request: .finalSynthesis(contractFinalRequest()),
            configuration: contractConfiguration()
        )
        let finalBody = try requestObject(final.requestBody)
        let finalSchemaName = try responseSchemaName(finalBody)
        try require(
            finalSchemaName == "reconstruction_final_synthesis_v1",
            "final response schema used a non-provider-safe name"
        )
        try require(finalBody["tools"] == nil, "final synthesis exposed tools")
        try require(finalBody["tool_choice"] == nil, "final synthesis exposed tool choice")
        try require(
            finalBody["parallel_tool_calls"] == nil,
            "final synthesis exposed parallel tool controls"
        )
    }

    static func schemasRejectEvidenceAuthorityBeyondFrozenBounds() throws {
        let evidenceIDs = (0...4_096).map { contractID(1_000 + $0) }
        try requireThrows(
            "final schema accepted more than 4,096 evidence IDs"
        ) {
            _ = try Phase2ReconstructionOutputSchemas.finalSynthesisProviderSchema(
                evidenceIDs: evidenceIDs
            )
        }
        try requireThrows(
            "round schema accepted more than 4,096 retrieved evidence IDs"
        ) {
            _ = try Phase2ReconstructionOutputSchemas.roundProviderSchema(
                jobID: contractID(1),
                checkpointRevision: 7,
                roundID: contractID(2),
                offeredHandles: [
                    .init(handleID: contractID(10), operationID: .corpusSummary),
                ],
                allowedGapSubjects: [],
                allowedGapCategories: [],
                allowedGapIDs: [],
                retrievedEvidenceIDs: evidenceIDs
            )
        }
    }

    static func accumulatorRejectsNormalizedAuthorityIdentitySpellings() throws {
        try requireMalformedRound(
            #"{"job_id":"30000000-0000-4000-8000-000000000001","checkpoint_revision":3,"round_id":"30000000-0000-4000-8000-000000000002","selected_handle_ids":["30000000-0000-4000-8000-000000000010"],"disposition":"continue","unresolved_gaps":[],"resolved_gaps":[]}"#
                .replacingOccurrences(
                    of: "30000000-0000-4000-8000-000000000001",
                    with: "30000000-0000-4000-8000-00000000000a"
                ),
            "round output accepted a lowercase authority UUID"
        )
        try requireMalformedFinal(
            #"{"kind":"synthesis","text":"Grounded.","evidence_ids":["30000000-0000-4000-8000-00000000002\u0030"]}"#,
            "final output accepted an escaped authority UUID"
        )
    }

    static func accumulatorRetiresAfterOutputBoundFailure() throws {
        var accumulator = Phase2ReconstructionRoundAccumulator()
        do {
            try accumulator.consume(.contentDelta(String(repeating: "x", count: 65_537)))
            throw ReconstructionAIContractProofError.failed(
                "accumulator accepted output above 65,536 bytes"
            )
        } catch let error as Phase2ReconstructionRoundAccumulatorError {
            try require(error == .outputTooLarge, "oversized output returned the wrong error")
        }

        do {
            try accumulator.consume(.usage(.init(
                promptTokens: 1,
                completionTokens: 1,
                totalTokens: 2
            )))
            throw ReconstructionAIContractProofError.failed(
                "accumulator remained live after its output bound failed"
            )
        } catch let error as Phase2ReconstructionRoundAccumulatorError {
            try require(error == .invalidSequence, "retired accumulator returned the wrong error")
        }
    }

    static func accumulatorRejectsCompletionUsageAboveProtocolCeiling() throws {
        var accumulator = Phase2ReconstructionRoundAccumulator()
        try accumulator.consume(.usage(.init(
            promptTokens: 1,
            completionTokens: 16_384,
            totalTokens: 16_385
        )))
        accumulator = Phase2ReconstructionRoundAccumulator()
        do {
            try accumulator.consume(.usage(.init(
                promptTokens: 1,
                completionTokens: 16_385,
                totalTokens: 16_386
            )))
            throw ReconstructionAIContractProofError.failed(
                "accumulator accepted completion usage above 16,384 tokens"
            )
        } catch let error as Phase2ReconstructionRoundAccumulatorError {
            try require(error == .invalidSequence, "over-limit usage returned the wrong error")
        }
    }

    static func accumulatorPreservesSchemaValidHighCardinalityOutput() throws {
        let evidenceIDs = (0...1_024).map { contractID(10_000 + $0).uuidString }
        let data = try JSONSerialization.data(
            withJSONObject: [
                "kind": "synthesis",
                "text": "Grounded.",
                "evidence_ids": evidenceIDs,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let content = try requireValue(String(data: data, encoding: .utf8), "final output")
        try require(data.count <= 65_536, "high-cardinality fixture exceeded output bytes")
        var accumulator = Phase2ReconstructionRoundAccumulator()
        try accumulator.consume(.contentDelta(content))
        try accumulator.consume(.usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)))
        try accumulator.consume(.done)
        let (candidate, _) = try accumulator.finishFinal()
        try require(
            candidate.evidenceIDs.count == evidenceIDs.count,
            "accumulator rejected schema-valid identity cardinality below the byte bound"
        )
    }

    private static func requireMalformedRound(_ content: String, _ message: String) throws {
        var accumulator = Phase2ReconstructionRoundAccumulator()
        try accumulator.consume(.contentDelta(content))
        try accumulator.consume(.usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)))
        try accumulator.consume(.done)
        do {
            _ = try accumulator.finishRound()
            throw ReconstructionAIContractProofError.failed(message)
        } catch let error as Phase2ReconstructionRoundAccumulatorError {
            try require(error == .malformedOutput, "malformed round returned the wrong error")
        }
    }

    private static func requireMalformedFinal(_ content: String, _ message: String) throws {
        var accumulator = Phase2ReconstructionRoundAccumulator()
        try accumulator.consume(.contentDelta(content))
        try accumulator.consume(.usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)))
        try accumulator.consume(.done)
        do {
            _ = try accumulator.finishFinal()
            throw ReconstructionAIContractProofError.failed(message)
        } catch let error as Phase2ReconstructionRoundAccumulatorError {
            try require(error == .malformedOutput, "malformed final returned the wrong error")
        }
    }

    private static func requestObject(_ data: Data) throws -> [String: Any] {
        try requireValue(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "request object"
        )
    }

    private static func responseSchemaName(_ body: [String: Any]) throws -> String {
        let responseFormat = try requireValue(
            body["response_format"] as? [String: Any],
            "response format"
        )
        let jsonSchema = try requireValue(
            responseFormat["json_schema"] as? [String: Any],
            "JSON schema"
        )
        return try requireValue(jsonSchema["name"] as? String, "provider schema name")
    }
}

private enum ReconstructionAIContractProofError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw ReconstructionAIContractProofError.failed(message) }
}

private func requireValue<Value>(_ value: Value?, _ name: String) throws -> Value {
    guard let value else {
        throw ReconstructionAIContractProofError.failed("missing \(name)")
    }
    return value
}

private func requireThrows(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
        throw ReconstructionAIContractProofError.failed(message)
    } catch is ReconstructionAIContractProofError {
        throw ReconstructionAIContractProofError.failed(message)
    } catch {}
}

private func contractRoundRequest() -> ReconstructionInferenceRoundRequest {
    .init(
        protocolVersion: 8,
        jobID: contractID(1),
        checkpointRevision: 3,
        roundID: contractID(2),
        corpusManifestSHA256: String(repeating: "1", count: 64),
        evidenceFrontierSHA256: String(repeating: "2", count: 64),
        registryManifestSHA256: String(repeating: "3", count: 64),
        context: .init(
            canonicalBytes: Data(#"{"records":[]}"#.utf8),
            canonicalSHA256: String(repeating: "4", count: 64),
            evidenceIDs: [],
            allowedGapSubjects: [],
            allowedGapCategories: [],
            allowedGapIDs: []
        ),
        handles: [.init(handleID: contractID(10), operationID: .corpusSummary)]
    )
}

private func contractFinalRequest() -> ReconstructionFinalSynthesisRequest {
    .init(
        jobID: contractID(1),
        checkpointRevision: 3,
        corpusManifestSHA256: String(repeating: "1", count: 64),
        evidenceFrontierSHA256: String(repeating: "2", count: 64),
        acceptedEvidenceIDs: [contractID(20)],
        context: .init(
            canonicalBytes: Data(#"{"records":[]}"#.utf8),
            canonicalSHA256: String(repeating: "4", count: 64),
            evidenceIDs: [contractID(20)]
        )
    )
}

private func contractConfiguration() -> Phase2AIWorkerConfigurationWire {
    .init(
        schemaVersion: 1,
        profileID: contractID(80),
        generation: 1,
        endpointOrigin: "http://127.0.0.1:1234",
        model: "local-model",
        protocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest,
        maximumTokens: 1_024,
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000, inferencePolicy: .init()
    )
}

private func contractID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "30000000-0000-4000-8000-%012X", value))!
}

#if MACSCOPE_RECONSTRUCTION_AI_CONTRACT_STANDALONE
@main
private enum ReconstructionAIContractStandaloneProof {
    static func main() throws {
        let checks: [(String, () throws -> Void)] = [
            ("strict projected tools", ReconstructionAIContractProof.projectedFunctionToolsRequireStrictClosedArguments),
            ("provider-safe closed requests", ReconstructionAIContractProof.requestsUseProviderSafeNamesAndDisableProviderToolCalls),
            ("bounded schema authority", ReconstructionAIContractProof.schemasRejectEvidenceAuthorityBeyondFrozenBounds),
            ("canonical output identities", ReconstructionAIContractProof.accumulatorRejectsNormalizedAuthorityIdentitySpellings),
            ("accumulator retirement", ReconstructionAIContractProof.accumulatorRetiresAfterOutputBoundFailure),
            ("completion token ceiling", ReconstructionAIContractProof.accumulatorRejectsCompletionUsageAboveProtocolCeiling),
            ("schema-valid output cardinality", ReconstructionAIContractProof.accumulatorPreservesSchemaValidHighCardinalityOutput),
        ]
        var failures: [String] = []
        for (name, check) in checks {
            do {
                try check()
            } catch {
                failures.append("\(name): \(error)")
            }
        }
        guard failures.isEmpty else {
            failures.forEach {
                FileHandle.standardError.write(Data("RED \($0)\n".utf8))
            }
            throw ReconstructionAIContractProofError.failed(
                "\(failures.count) reconstruction AI contract checks failed"
            )
        }
        print("reconstruction AI contract standalone proof: passed")
    }
}
#endif
