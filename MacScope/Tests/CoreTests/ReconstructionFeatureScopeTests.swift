import Foundation
import XCTest
@testable import MacScope

final class ReconstructionFeatureScopeTests: XCTestCase {
    private let digest = String(repeating: "c", count: 64)

    private func function() throws -> (ReconstructionDatabaseTestFixtures.StateFixture, ReconstructionFunctionCoordinate) {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID(), evidenceSubjectUsesFunction: true)
        let function = try XCTUnwrap({ () -> ReconstructionFunctionCoordinate? in
            if case .function(let coordinate)? = foundation.task.identity.subject { return coordinate }
            return nil
        }(), "required synthetic fixture task must be function-scoped")
        return (foundation, function)
    }

    private func scope(
        _ foundation: ReconstructionDatabaseTestFixtures.StateFixture,
        _ function: ReconstructionFunctionCoordinate,
        evidence: [UUID],
        scenarios: [ReconstructionFeatureScenario]? = nil,
        dependencies: [ReconstructionFeatureDependency] = [],
        basis: [UUID]? = nil,
        contract: ReconstructionObservationContract = .scalarU32ReturnV1
    ) throws -> ReconstructionFeatureScope {
        try .make(projectID: foundation.project.projectID, jobID: foundation.job.jobID, feature: function,
            acceptedEvidenceIDs: evidence,
            scenarios: scenarios ?? [.init(oracleEvidenceID: evidence[0], suiteSHA256: digest, caseCount: 37,
                                           role: .development)],
            dependencies: dependencies, dependencyBasisEvidenceIDs: basis ?? [evidence[0]],
            observationContract: contract, admittedAtCheckpointID: foundation.checkpoint.checkpointID,
            admittedAtCheckpointRevision: foundation.checkpoint.revision,
            admittedAtCheckpointSHA256: foundation.checkpoint.canonicalSHA256,
            evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256)
    }

    func testScalarContractReusesExistingOracleAndHarnessLimits() {
        let contract = ReconstructionObservationContract.scalarU32ReturnV1
        XCTAssertEqual(contract.sourceProfileID, ReconstructionSourceExecutionTaskContract.profileID)
        XCTAssertEqual(contract.oracleVersion, ReconstructionSourceOracle.version)
        XCTAssertEqual(contract.harnessVersion, ReconstructionSourceBehaviorHarness.version)
        XCTAssertEqual(contract.maximumCases, ReconstructionSourceBehaviorHarness.maximumCases)
        XCTAssertEqual(ReconstructionObservationContract.admittedContracts, [contract])
    }

    func testCanonicalOrderingDigestAndRoundTrip() throws {
        let (foundation, function) = try function()
        let a = UUID(), b = UUID()
        let dependency = ReconstructionFeatureDependency(kind: .callee, subject: nil, symbol: "_helper",
            disposition: .modeledExternal, evidenceIDs: [b, a])
        let scenario = [ReconstructionFeatureScenario(oracleEvidenceID: a, suiteSHA256: digest, caseCount: 37,
                                                      role: .development)]
        let first = try scope(foundation, function, evidence: [a, b], scenarios: scenario,
                              dependencies: [dependency], basis: [b, a])
        let second = try scope(foundation, function, evidence: [b, a], scenarios: scenario,
                               dependencies: [dependency], basis: [a, b])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.acceptedEvidenceIDs, ReconstructionValidation.sortedUUIDs([a, b]))
        let decoded = try JSONDecoder().decode(ReconstructionFeatureScope.self,
                                               from: ReconstructionCanonicalJSON.encode(first))
        XCTAssertEqual(decoded, first)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(first))
            as? [String: Any])
        object["canonicalSHA256"] = digest
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(ReconstructionFeatureScope.self, from: tampered))
    }

    func testShapeRejectsUncitedOrUndeclaredClaims() throws {
        let (foundation, function) = try function()
        let a = UUID()
        XCTAssertThrowsError(try scope(foundation, function, evidence: [a], scenarios: []))
        XCTAssertThrowsError(try scope(foundation, function, evidence: [a], scenarios: [
            .init(oracleEvidenceID: UUID(), suiteSHA256: digest, caseCount: 37, role: .development)]))
        XCTAssertThrowsError(try scope(foundation, function, evidence: [a], scenarios: [
            .init(oracleEvidenceID: a, suiteSHA256: digest, caseCount: 257, role: .development)]))
        XCTAssertThrowsError(try scope(foundation, function, evidence: [a], basis: []))
        XCTAssertThrowsError(try scope(foundation, function, evidence: [a], dependencies: [
            .init(kind: .global, subject: nil, symbol: "_g", disposition: .inScope, evidenceIDs: [])]))
        XCTAssertThrowsError(try scope(foundation, function, evidence: [a], dependencies: [
            .init(kind: .global, subject: nil, symbol: nil, disposition: .inScope, evidenceIDs: [a])]))
        let widened = ReconstructionObservationContract(contractID: "reconstruction.observation.scalar-u32-return.v1",
            version: 1, sourceProfileID: ReconstructionSourceOracle.profileID,
            oracleVersion: ReconstructionSourceOracle.version, harnessVersion: ReconstructionSourceBehaviorHarness.version,
            maximumCases: 1_024, channels: [.returnValueU32], completeness: .everyValueComplete)
        XCTAssertThrowsError(try scope(foundation, function, evidence: [a], contract: widened)) {
            XCTAssertEqual($0 as? ReconstructionFeatureScopeError, .unadmittedContract)
        }
    }

    func testCurrencyReportsEveryCitedRecordThatIsNotAcceptedCurrent() throws {
        let (foundation, function) = try function()
        let a = UUID(), b = UUID()
        let admitted = try scope(foundation, function, evidence: [a, b])
        XCTAssertEqual(ReconstructionFeatureScopeCurrency.of(admitted,
            classifications: [a: .acceptedCurrent, b: .acceptedCurrent]), .current)
        XCTAssertEqual(ReconstructionFeatureScopeCurrency.of(admitted,
            classifications: [a: .acceptedCurrent, b: .staleAnalysis]), .stale([b]))
        XCTAssertEqual(ReconstructionFeatureScopeCurrency.of(admitted, classifications: [:]),
                       .stale(admitted.acceptedEvidenceIDs))
    }

    func testScopeLessJobKeepsSchemaFiveBytesAndScopedJobIsSchemaSix() throws {
        let (foundation, function) = try function()
        let job = try ReconstructionJobRecord(jobID: foundation.job.jobID,
            reconstructionProjectID: foundation.job.reconstructionProjectID, objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.job.creationCorpusManifestSHA256, state: foundation.job.state,
            currentCheckpointID: foundation.job.currentCheckpointID, terminalReason: nil, budget: foundation.job.budget,
            sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID)
        XCTAssertEqual(job.recordSchemaVersion, ReconstructionJobRecord.schemaVersion)
        let v5 = try ReconstructionCanonicalJSON.encode(job)
        XCTAssertFalse(String(decoding: v5, as: UTF8.self).contains("featureScope"))
        XCTAssertEqual(try job.normalizedToCurrentSchema(), job)

        let admitted = try scope(foundation, function, evidence: [UUID()])
        let scoped = try job.admitting(admitted)
        XCTAssertEqual(scoped.recordSchemaVersion, ReconstructionJobRecord.featureScopeSchemaVersion)
        XCTAssertEqual(try JSONDecoder().decode(ReconstructionJobRecord.self,
                                                from: ReconstructionCanonicalJSON.encode(scoped)), scoped)
        XCTAssertEqual(try scoped.admitting(admitted), scoped)
        XCTAssertThrowsError(try scoped.admitting(try scope(foundation, function, evidence: [UUID()])))
        XCTAssertEqual(try scoped.removingFeatureScope(), job)
        XCTAssertEqual(try scoped.normalizedToCurrentSchema(), scoped)

        // A schema-5 record can never smuggle a scope, and a scope needs the job's source profile.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(scoped))
            as? [String: Any])
        object["recordSchemaVersion"] = ReconstructionJobRecord.schemaVersion
        XCTAssertThrowsError(try JSONDecoder().decode(ReconstructionJobRecord.self,
                                                      from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try foundation.job.admitting(admitted), "fixture job has no source profile")
    }
    func testSchemaFiveBytesAndSchemaSixPresenceRemainExact() throws {
        // Literal pre-scope schema-5 bytes, independent of the current encoder's output.
        let bytes = Data(#"{"budget":{"maxEncodedBytes":1024,"maxEvidenceRecords":4,"maxRounds":2,"maxTasks":3},"creationCorpusManifestSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","creationOrdinal":1,"jobID":"00000000-0000-0000-0000-000000000001","objective":"x","objectiveSHA256":"2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881","reconstructionProjectID":"00000000-0000-0000-0000-000000000002","recordSchemaVersion":5,"state":"created"}"#.utf8)
        let decoded = try JSONDecoder().decode(ReconstructionJobRecord.self, from: bytes)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(decoded), bytes)
        XCTAssertEqual(try ReconstructionCanonicalJSON.encode(decoded.normalizedToCurrentSchema()), bytes)
        let (foundation, function) = try function()
        let admitted = try scope(foundation, function, evidence: [UUID()])
        let job = try ReconstructionJobRecord(jobID: foundation.job.jobID,
            reconstructionProjectID: foundation.job.reconstructionProjectID, objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.job.creationCorpusManifestSHA256, state: foundation.job.state,
            currentCheckpointID: foundation.job.currentCheckpointID, terminalReason: nil, budget: foundation.job.budget,
            sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID, featureScope: admitted)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(job))
            as? [String: Any])
        for version in [5, 6] {
            for presence in ["missing", "null", "present"] {
                var object = original
                object["recordSchemaVersion"] = version
                if presence == "missing" { object.removeValue(forKey: "featureScope") }
                if presence == "null" { object["featureScope"] = NSNull() }
                let data = try JSONSerialization.data(withJSONObject: object)
                if (version == 5 && presence == "missing") || (version == 6 && presence == "present") {
                    let roundtrip = try JSONDecoder().decode(ReconstructionJobRecord.self, from: data)
                    XCTAssertEqual(try roundtrip.normalizedToCurrentSchema().recordSchemaVersion, version)
                } else {
                    XCTAssertThrowsError(try JSONDecoder().decode(ReconstructionJobRecord.self, from: data))
                }
            }
        }
    }

}
