import Foundation
import XCTest
@testable import MacScope

final class ReconstructionJobSourceIntentTests: XCTestCase {
    func testSourceIntentSurvivesCanonicalRoundTripAndModelNormalization() throws {
        let original = try job(sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID)
        XCTAssertEqual(original.recordSchemaVersion, 5)
        let encoded = try ReconstructionCanonicalJSON.encode(original)
        let decoded = try JSONDecoder().decode(ReconstructionJobRecord.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(decoded), encoded)
        XCTAssertEqual(try decoded.normalizedToCurrentSchema().sourceProfileID, original.sourceProfileID)
        let upgraded = try decoded.upgraded(creationOrdinal: 9)
        XCTAssertEqual(upgraded.sourceProfileID, original.sourceProfileID)
        XCTAssertEqual(upgraded.creationOrdinal, 9)
        XCTAssertEqual(upgraded.focus, original.focus)
    }

    func testOrdinaryJobDoesNotInferSourceIntentFromObjective() throws {
        let ordinary = try job(objective: "Reconstruct source with saturating increment")
        let encoded = try ReconstructionCanonicalJSON.encode(ordinary)
        let object = try object(encoded)
        XCTAssertNil(object["sourceProfileID"])
        XCTAssertNil(try JSONDecoder().decode(ReconstructionJobRecord.self, from: encoded).sourceProfileID)
        XCTAssertEqual(ordinary.recordSchemaVersion, 5)
    }

    func testSchemasOneThroughFourDecodeWithoutIntentAndPreserveLegacyShape() throws {
        for version in 1...4 {
            let payload = try legacy(version)
            let decoded = try decode(payload)
            XCTAssertEqual(decoded.recordSchemaVersion, version)
            XCTAssertNil(decoded.sourceProfileID)
            let reencoded = try object(ReconstructionCanonicalJSON.encode(decoded))
            XCTAssertNil(reencoded["sourceProfileID"])
            if version == 1 {
                XCTAssertNil(reencoded["recordSchemaVersion"])
                XCTAssertNil(reencoded["creationOrdinal"])
                XCTAssertNil(try decoded.upgraded(creationOrdinal: 1).sourceProfileID)
            } else {
                XCTAssertEqual(reencoded["recordSchemaVersion"] as? Int, version)
                let normalized = try decoded.normalizedToCurrentSchema()
                XCTAssertEqual(normalized.recordSchemaVersion, 5)
                XCTAssertNil(normalized.sourceProfileID)
                XCTAssertEqual(normalized.objective, decoded.objective)
                XCTAssertEqual(normalized.creationOrdinal, decoded.creationOrdinal)
            }
        }
    }

    func testLegacySchemasRejectInjectedIntentIncludingNull() throws {
        for version in 1...4 {
            for profile in [ReconstructionSourceExecutionTaskContract.profileID, NSNull()] as [Any] {
                var payload = try legacy(version)
                payload["sourceProfileID"] = profile
                XCTAssertThrowsError(try decode(payload), "schema \(version) accepted an injected source profile")
            }
        }
    }

    func testCurrentSchemaRequiresKnownNonNullProfileAndRetainsVersionFence() throws {
        XCTAssertThrowsError(try job(sourceProfileID: "arbitrary-source-profile"))
        let source = try job(sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID)
        let valid = try object(ReconstructionCanonicalJSON.encode(source))
        for profile in ["", "arbitrary-source-profile", NSNull(), 42] as [Any] {
            var payload = valid; payload["sourceProfileID"] = profile
            XCTAssertThrowsError(try decode(payload))
        }
        var future = valid; future["recordSchemaVersion"] = 6
        XCTAssertThrowsError(try decode(future))
    }

    private func job(sourceProfileID: String? = nil, objective: String = "Reconstruct the selected artifact") throws -> ReconstructionJobRecord {
        try .init(jobID: UUID(), reconstructionProjectID: UUID(), objective: objective,
            objectiveSHA256: hash(objective), creationCorpusManifestSHA256: hash("manifest"),
            state: .created, currentCheckpointID: nil, terminalReason: nil,
            budget: .init(maxRounds: 2, maxTasks: 20, maxEvidenceRecords: 20, maxEncodedBytes: 65_536),
            sourceProfileID: sourceProfileID)
    }
    private func legacy(_ version: Int) throws -> [String: Any] {
        var payload = try object(ReconstructionCanonicalJSON.encode(job()))
        payload.removeValue(forKey: "sourceProfileID")
        if version == 1 {
            payload.removeValue(forKey: "recordSchemaVersion")
            payload.removeValue(forKey: "creationOrdinal")
        } else { payload["recordSchemaVersion"] = version }
        return payload
    }
    private func object(_ bytes: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    private func decode(_ value: [String: Any]) throws -> ReconstructionJobRecord {
        try JSONDecoder().decode(ReconstructionJobRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func hash(_ value: String) -> String {
        ReconstructionSourceRevisionAdmission.sourceSHA256(Data(value.utf8))
    }
}
