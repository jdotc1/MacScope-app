import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceWireTests: XCTestCase {
    func testProfileDispatchRejectsDisabledUnknownAndWrongProtocolBeforeBundleSelection() throws {
        let scalar = try request(), codec = Phase2ReconstructionAIWorkerWireCodec()
        let original = try codec.encodeSourceRequest(scalar, requestID: uuid(8))
        XCTAssertEqual(try ReconstructionAIWorkerRequest.sourceRevision(scalar).protocolBundle,
            Phase2AIWorkerProductionProtocol.reconstructionSourceV10)
        guard case .sourceRevision(_, let decoded) = try codec.decodeRequest(original) else { return XCTFail("source channel") }
        XCTAssertEqual(try codec.encodeSourceRequest(decoded, requestID: uuid(8)), original)
        for profile in ["arm64-c-adler32-combine-record-v1", "unknown-profile"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(scalar)) as? [String: Any])
            object["profileID"] = profile
            let foreign = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try foreign.validate())
            XCTAssertThrowsError(try ReconstructionAIWorkerRequest.sourceRevision(foreign).protocolBundle)
            XCTAssertThrowsError(try codec.encodeSourceRequest(foreign, requestID: uuid(8)))
            object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(scalar)) as? [String: Any])
            var objective = try XCTUnwrap(object["objective"] as? [String: Any]); objective["sourceProfileID"] = profile
            object["objective"] = objective
            // Objective decoding itself rejects foreign profiles; no bundle/provider dispatch occurs.
            XCTAssertThrowsError(try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(scalar)) as? [String: Any])
        object["protocolVersion"] = 11
        let wrongVersion = try JSONDecoder().decode(ReconstructionSourceRevisionRequest.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try ReconstructionAIWorkerRequest.sourceRevision(wrongVersion).protocolBundle)
    }

    private func uuid(_ value: Int) -> UUID { UUID(uuidString: String(format: "ab000000-0000-0000-0000-%012d", value))! }
    private func sha(_ text: String) -> String { ReconstructionSourceInferenceContract.sha256(Data(text.utf8)) }
    private func request(parent: String? = nil) throws -> ReconstructionSourceRevisionRequest {
        let function = try ReconstructionFunctionCoordinate(artifact: .init(occurrenceID: .init(rawValue: uuid(1)),
            contentIdentity: .init(algorithm: .sha256, digest: sha("image"), byteCount: 32)),
            image: .init(binaryID: uuid(2), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sha("analysis"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let observation = Data("Observed uint32_t input/output evidence".utf8)
        let evidence = try ReconstructionEvidenceRecord(evidenceID: uuid(5), subject: .function(function),
            operationID: "reconstruction.function.review", payloadKind: .text, payload: observation,
            payloadByteCount: UInt64(observation.count), payloadSHA256: ReconstructionSourceInferenceContract.sha256(observation),
            facetDependencies: [], producer: .init(macScopeBuildIdentity: sha("build"), macScopeSourceIdentity: sha("source"),
                operationIdentity: "reconstruction.function.review", registryIdentity: sha("registry"), protocolIdentity: sha("protocol"), canonicalSHA256: sha("producer")),
            citations: [], creatingJobID: uuid(3), creatingTaskID: uuid(9), creatingCheckpointID: uuid(10),
            modelReceiptID: nil, toolReceiptID: uuid(11), classification: .acceptedCurrent,
            supersedesEvidenceID: nil, supersededByEvidenceID: nil, diagnostic: nil)
        let record = try JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(evidence))
        let packet = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "domain": "reconstruction.evidence-retrieval-packet.v1", "corpusManifestSHA256": sha("corpus"),
            "evidenceFrontierSHA256": sha("frontier"), "queryIdentitySHA256": sha("query"),
            "records": [["record": record, "classification": "acceptedCurrent", "checkpointRevision": 0]], "hasMore": false
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let context = try JSONSerialization.data(withJSONObject: ["schemaVersion": 8,
            "domain": "reconstruction.context.v8", "corpusManifestSHA256": sha("corpus"),
            "evidenceFrontierSHA256": sha("frontier"), "retrievalPacket": packet.base64EncodedString(),
            "retrievalPacketSHA256": ReconstructionSourceInferenceContract.sha256(packet), "evidenceIDs": [uuid(5).uuidString],
            "allowedGapIDs": [], "allowedGapSubjects": [], "allowedGapCategories": []
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        return try .init(protocolVersion: 10, objective: .init(jobID: uuid(3), text: "Propose bounded C", sha256: sha("Propose bounded C")),
            projectID: uuid(4), jobID: uuid(3), taskID: uuid(6), checkpointRevision: 1, roundID: uuid(7), function: function,
            corpusManifestSHA256: sha("corpus"), evidenceFrontierSHA256: sha("frontier"), oracleSuiteSHA256: sha("oracle"),
            profileID: ReconstructionSourceInferenceContract.profileID, parentRevisionSHA256: parent,
            context: .init(canonicalBytes: context, canonicalSHA256: ReconstructionSourceInferenceContract.sha256(context), evidenceIDs: [uuid(5)]))
    }
    private func candidate(_ source: String = "uint32_t reconstructed(uint32_t x) { return x; }") -> ReconstructionSourceRevisionCandidate {
        .init(profileID: ReconstructionSourceInferenceContract.profileID, parentRevisionSHA256: nil,
            sourceText: source, evidenceIDs: [uuid(5)])
    }
    private func output(_ candidate: ReconstructionSourceRevisionCandidate) throws -> String {
        let bytes = try JSONEncoder().encode(candidate)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["parentRevisionSHA256"] = candidate.parentRevisionSHA256 ?? "none"
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    func testDistinctBundleAndCanonicalWireRoundtrip() throws {
        let request = try request()
        let codec = Phase2ReconstructionAIWorkerWireCodec()
        let bytes = try codec.encodeSourceRequest(request, requestID: uuid(8))
        guard case .sourceRevision(let id, let decoded) = try codec.decodeRequest(bytes) else { return XCTFail("wrong channel") }
        XCTAssertEqual(id, uuid(8)); XCTAssertEqual(decoded, request)
        XCTAssertNotEqual(Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest,
                          Phase2AIWorkerProductionProtocol.reconstructionR2.manifestDigest)
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.reconstructionSourceV10.inferenceVersion, 10)
        XCTAssertEqual(Phase2AIWorkerProductionProtocol.reconstructionR2.inferenceVersion, 9)
        let event = ReconstructionAIWorkerEvent(requestID: uuid(8), sequence: 1, body: .sourceCandidate(candidate()))
        let eventBytes = try codec.encodeEvent(event, authority: .sourceRevision(request))
        XCTAssertEqual(try codec.decodeEvent(eventBytes, authority: .sourceRevision(request)), event)
        XCTAssertThrowsError(try codec.encodeEvent(.init(requestID: uuid(8), sequence: 1,
            body: .finalCandidate(.init(kind: .synthesis, text: "not source", evidenceIDs: [uuid(5)]))), authority: .sourceRevision(request)))
        XCTAssertThrowsError(try codec.decodeRequest(bytes + Data("\n".utf8)))
    }
    func testAccumulatorActualUTF8LimitAndClosedOutputShape() throws {
        let request = try request()
        var accumulator = Phase2ReconstructionSourceAccumulator()
        try accumulator.consume(.contentDelta(output(candidate())))
        try accumulator.consume(.usage(.init(promptTokens: 5, completionTokens: 8, totalTokens: 13)))
        try accumulator.consume(.done)
        XCTAssertEqual(try accumulator.finish(for: request).0, candidate())
        XCTAssertEqual(candidate().sourceSHA256, sha(candidate().sourceText))
        var oversized = Phase2ReconstructionSourceAccumulator()
        try oversized.consume(.contentDelta(output(candidate(String(repeating: "é", count: 32_769)))))
        try oversized.consume(.usage(.init(promptTokens: 5, completionTokens: 8, totalTokens: 13)))
        try oversized.consume(.done)
        XCTAssertThrowsError(try oversized.finish(for: request))
        var injected = Phase2ReconstructionSourceAccumulator()
        let text = try output(candidate())
        try injected.consume(.contentDelta("{\"command\":\"rm\"," + text.dropFirst()))
        try injected.consume(.usage(.init(promptTokens: 5, completionTokens: 8, totalTokens: 13)))
        try injected.consume(.done)
        XCTAssertThrowsError(try injected.finish(for: request))
    }
    func testActualWorkerHandlerUsesOnlySourceChannel() async throws {
        let request = try request()
        let response = try output(candidate())
        let candidate = candidate()
        let collector = SourceWireEventCollector()
        let handler = Phase2ReconstructionAIWorkerHandler(execute: { input, emit in
            XCTAssertEqual(input.phase, .sourceRevision)
            XCTAssertTrue(input.offeredHandles.isEmpty)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: input.requestBody) as? [String: Any])
            XCTAssertNil(body["tools"])
            XCTAssertTrue(String(decoding: input.requestBody, as: UTF8.self).contains("Observed uint32_t"))
            await emit(.contentDelta(response))
            await emit(.usage(.init(promptTokens: 5, completionTokens: 8, totalTokens: 13)))
            await emit(.done)
        })
        let configuration = Phase2AIWorkerConfigurationWire(schemaVersion: 1, profileID: uuid(20), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: "fixture-model",
            protocolManifestDigest: Phase2AIWorkerProductionProtocol.reconstructionSourceV10.manifestDigest,
            maximumTokens: 16_384, requestTimeoutMilliseconds: 300_000, resourceTimeoutMilliseconds: 1_800_000,
            inferencePolicy: .init())
        try await handler.run(requestID: uuid(8), request: .sourceRevision(request), configuration: configuration,
            emitControl: { _ in }, emit: { await collector.append($0) })
        let events = await collector.events
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(events.first?.body, .sourceCandidate(candidate))
        XCTAssertEqual(events.last?.body, .completed)
    }

    func testParentHashPathAndEvidenceCannotBeInvented() throws {
        let request = try request(parent: sha("parent"))
        XCTAssertThrowsError(try candidate().validate(for: request))
        let wrong = ReconstructionSourceRevisionCandidate(profileID: request.profileID,
            parentRevisionSHA256: request.parentRevisionSHA256, sourceText: "x", evidenceIDs: [uuid(99)])
        XCTAssertThrowsError(try wrong.validate(for: request))
        let mismatch = ReconstructionSourceRevisionCandidate(profileID: "unapproved-profile",
            parentRevisionSHA256: request.parentRevisionSHA256, sourceText: "x", evidenceIDs: [uuid(5)])
        XCTAssertThrowsError(try mismatch.validate(for: request))
        let schema = try Phase2ReconstructionSourceOutput.schema(for: request).canonicalJSONBytes()
        XCTAssertTrue(String(decoding: schema, as: UTF8.self).contains(request.parentRevisionSHA256 ?? ""))
    }
}

private actor SourceWireEventCollector {
    private(set) var events: [ReconstructionAIWorkerEvent] = []
    func append(_ event: ReconstructionAIWorkerEvent) { events.append(event) }
}
