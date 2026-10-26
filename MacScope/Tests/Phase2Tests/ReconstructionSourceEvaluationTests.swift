import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceEvaluationTests: XCTestCase {
    private let fixtureSHA256 = String(repeating: "a", count: 64)
    private func fixture() throws -> ReconstructionSourceEvaluation {
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()),
            contentIdentity: try .init(algorithm: .sha256, digest: fixtureSHA256, byteCount: 32))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: UUID(), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: fixtureSHA256, startAddress: 4096, endAddressExclusive: 4112,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let session = UUID(), terminal = ReconstructionSourceEvaluation.Terminal(kind: .exited, status: 0)
        let phases = [ReconstructionSourceEvaluation.Operation.inspect, .compile, .behavior].map { op in
            let request = UUID()
            return ReconstructionSourceEvaluation.Phase(operation: op, requestID: request, sessionID: session,
                requestIdentitySHA256: fixtureSHA256, status: .completed, terminal: terminal, failure: nil, diagnostics: Data(),
                cleanup: .init(sessionID: session, requestID: request, processIdentifier: 123,
                    observedProcessAbsent: true, outcome: terminal), sampledProcessIDs: [123],
                peakGroupResidentBytes: 1024, elapsedMilliseconds: 10)
        }
        // Synthetic observations exercise the codec only; these are not an execution receipt.
        let observations = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1().inputs.map {
            ReconstructionSourceEvaluation.Observation(input: $0, output: 7)
        }
        let outcome = ReconstructionSourceEvaluation.CapturedOutcome(status: .accepted, failureDetail: nil,
            runnerSHA256: fixtureSHA256, compilerSHA256: fixtureSHA256, sdkSettingsSHA256: fixtureSHA256, harnessSHA256: fixtureSHA256,
            inspectionSHA256: fixtureSHA256, astSHA256: fixtureSHA256, executableSHA256: fixtureSHA256,
            phases: phases, observations: observations, mismatches: [])
        let value = ReconstructionSourceEvaluation(version: 1, profileID: ReconstructionSourceEvaluation.profileID,
            projectID: UUID(), jobID: UUID(), taskID: UUID(), checkpointRevision: 3, evaluationRequestSHA256: fixtureSHA256,
            function: function, sourceEvidenceID: UUID(), sourcePayloadSHA256: fixtureSHA256, revisionSHA256: fixtureSHA256,
            sourceSHA256: fixtureSHA256, sourceRequestSHA256: fixtureSHA256, oracleEvidenceID: UUID(), oraclePayloadSHA256: fixtureSHA256,
            oracleSuiteSHA256: fixtureSHA256, producerSHA256: fixtureSHA256, capturedOutcome: outcome, evaluationSHA256: fixtureSHA256)
        return try altered(value) { _ in }
    }
    private func altered(_ value: ReconstructionSourceEvaluation, seal: Bool = true,
                         _ edit: (inout [String: Any]) -> Void) throws -> ReconstructionSourceEvaluation {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionSourceEvaluationCodec.encode(value)) as? [String: Any])
        edit(&object)
        let changed = try JSONDecoder().decode(ReconstructionSourceEvaluation.self, from: JSONSerialization.data(withJSONObject: object))
        if seal { object["evaluationSHA256"] = try ReconstructionSourceEvaluationCodec.canonicalIdentity(changed) }
        return try JSONDecoder().decode(ReconstructionSourceEvaluation.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func reject(_ edit: (inout [String: Any]) -> Void) throws {
        let value = try altered(fixture(), edit)
        XCTAssertThrowsError(try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: ReconstructionSourceEvaluationCodec.encode(value)))
    }
    func testCanonical37ObservationAggregateRoundtrip() throws {
        let value = try fixture(), bytes = try ReconstructionSourceEvaluationCodec.encode(value)
        XCTAssertEqual(try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: bytes), value)
        XCTAssertEqual(value.capturedOutcome.observations.count, 37)
        XCTAssertEqual(value.capturedOutcome.phases.map(\.operation), [.inspect, .compile, .behavior])
        XCTAssertTrue(value.capturedOutcome.observations.allSatisfy { $0.output == 7 })
    }
    func testHashUnknownKeyDuplicateAndOversizeRejection() throws {
        let value = try altered(fixture(), seal: false) { $0["checkpointRevision"] = 4 }
        XCTAssertThrowsError(try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: ReconstructionSourceEvaluationCodec.encode(value)))
        let bytes = try ReconstructionSourceEvaluationCodec.encode(fixture())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["command"] = "printf spoof"
        XCTAssertThrowsError(try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])))
        let duplicate = Data(("{\"version\":1," + String(decoding: bytes.dropFirst(), as: UTF8.self)).utf8)
        XCTAssertThrowsError(try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: duplicate))
        XCTAssertThrowsError(try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: Data(repeating: 32, count: 131_073)))
    }
    func testReorderedPhasesMissingCleanupAndWrongInputRejected() throws {
        try reject { object in
            var outcome = object["capturedOutcome"] as! [String: Any]
            var phases = outcome["phases"] as! [[String: Any]]; phases.swapAt(0, 1)
            outcome["phases"] = phases; object["capturedOutcome"] = outcome
        }
        try reject { object in
            var outcome = object["capturedOutcome"] as! [String: Any]
            var phases = outcome["phases"] as! [[String: Any]]; phases[2].removeValue(forKey: "cleanup")
            outcome["phases"] = phases; object["capturedOutcome"] = outcome
        }
        try reject { object in
            var outcome = object["capturedOutcome"] as! [String: Any]
            var observations = outcome["observations"] as! [[String: Any]]; observations[0]["input"] = 9
            outcome["observations"] = observations; object["capturedOutcome"] = outcome
        }
    }
    func testAcceptedCannotCarryMismatchAndDiagnosticsBounded() throws {
        try reject { object in
            var outcome = object["capturedOutcome"] as! [String: Any]
            outcome["mismatches"] = [["index": 0, "input": 0, "expected": 1, "actual": 7]]
            object["capturedOutcome"] = outcome
        }
        try reject { object in
            var outcome = object["capturedOutcome"] as! [String: Any]
            var phases = outcome["phases"] as! [[String: Any]]
            phases[0]["diagnostics"] = Data(repeating: 65, count: 16_385).base64EncodedString()
            outcome["phases"] = phases; object["capturedOutcome"] = outcome
        }
    }
}
