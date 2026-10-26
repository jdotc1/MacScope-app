import Foundation
import XCTest
@testable import MacScope

/// Synthetic value-comparison fixtures only; no real capture or authenticated custody is claimed.
final class ReconstructionObservationComparatorTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let contract = ReconstructionObservationContract.scalarU32ReturnV1

    private struct Fixture {
        let oracle: ReconstructionSourceOracle
        let oracleEvidenceID: UUID
        let candidateEvidenceID = UUID()
        let scope: ReconstructionFeatureScope
        let original: ReconstructionObservationSet
    }

    private func fixture() throws -> Fixture {
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: UUID(), evidenceSubjectUsesFunction: true)
        let function = try XCTUnwrap({ () -> ReconstructionFunctionCoordinate? in
            if case .function(let coordinate)? = foundation.task.identity.subject { return coordinate }
            return nil
        }(), "required synthetic fixture task must be function-scoped")
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let oracle = try ReconstructionSourceOracleEvidence.admit(authority: .init(
            projectID: foundation.project.projectID, jobID: foundation.job.jobID, function: function,
            execution: .init(originalImageSHA256: function.artifact.contentIdentity.digest, originalExecutableSHA256: digest, originalSourceSHA256: nil,
                harnessSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
                compilerSHA256: digest, sdkIdentitySHA256: digest, compileProfileSHA256: digest,
                compileArgumentsSHA256: digest, executionArgumentsSHA256: digest, producerSHA256: digest,
                standardOutput: Data(harness.inputs.map { "\($0):\($0 == UInt32.max ? $0 : $0 + 1)\n" }.joined().utf8),
                sessionID: UUID(), requestID: UUID(), processIdentifier: 123,
                sampledProcessIDs: [123], exitCode: 0, observedProcessAbsent: true),
            evidenceIDs: [UUID()]))
        let oracleEvidenceID = UUID()
        let scope = try ReconstructionFeatureScope.make(projectID: foundation.project.projectID,
            jobID: foundation.job.jobID, feature: function, acceptedEvidenceIDs: [oracleEvidenceID] + oracle.evidenceIDs,
            scenarios: [.init(oracleEvidenceID: oracleEvidenceID, suiteSHA256: oracle.suiteSHA256,
                              caseCount: oracle.inputs.count, role: .development)],
            dependencies: [], dependencyBasisEvidenceIDs: [oracleEvidenceID], observationContract: contract,
            admittedAtCheckpointID: foundation.checkpoint.checkpointID,
            admittedAtCheckpointRevision: foundation.checkpoint.revision,
            admittedAtCheckpointSHA256: foundation.checkpoint.canonicalSHA256,
            evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256)
        let original = try ReconstructionObservationAdapter.original(oracle, evidenceID: oracleEvidenceID,
                                                                       contract: contract)
        return Fixture(oracle: oracle, oracleEvidenceID: oracleEvidenceID, scope: scope, original: original)
    }

    private func evaluation(
        _ fixture: Fixture,
        status: ReconstructionSourceEvaluation.Status = .accepted,
        outputs: [UInt32]? = nil,
        compiler: String? = nil
    ) -> ReconstructionSourceEvaluation {
        let oracle = fixture.oracle
        let actual = outputs ?? oracle.outputs
        let observed = status == .accepted || status == .behaviorMismatch
        let observations = observed ? zip(oracle.inputs, actual).map {
            ReconstructionSourceEvaluation.Observation(input: $0.0, output: $0.1)
        } : []
        let mismatches = observed ? actual.enumerated().compactMap { index, output -> ReconstructionSourceEvaluation.Mismatch? in
            output == oracle.outputs[index] ? nil
                : ReconstructionSourceEvaluation.Mismatch(index: index, input: oracle.inputs[index],
                                                          expected: oracle.outputs[index], actual: output)
        } : []
        return ReconstructionSourceEvaluation(version: 1, profileID: ReconstructionSourceEvaluation.profileID,
            projectID: oracle.projectID, jobID: oracle.jobID, taskID: UUID(), checkpointRevision: 1,
            evaluationRequestSHA256: digest, function: oracle.function, sourceEvidenceID: UUID(),
            sourcePayloadSHA256: digest, revisionSHA256: digest, sourceSHA256: digest, sourceRequestSHA256: digest,
            oracleEvidenceID: fixture.oracleEvidenceID, oraclePayloadSHA256: fixture.original.binding.oraclePayloadSHA256,
            oracleSuiteSHA256: oracle.suiteSHA256, producerSHA256: digest,
            capturedOutcome: .init(status: status, failureDetail: nil, runnerSHA256: digest,
                compilerSHA256: compiler ?? oracle.execution.compilerSHA256,
                sdkSettingsSHA256: oracle.execution.sdkIdentitySHA256,
                harnessSHA256: oracle.execution.harnessSHA256, inspectionSHA256: nil, astSHA256: nil,
                executableSHA256: nil, phases: [], observations: observations, mismatches: mismatches),
            evaluationSHA256: digest)
    }

    private func compare(_ fixture: Fixture, _ evaluation: ReconstructionSourceEvaluation,
                         currency: ReconstructionFeatureScopeCurrency = .current) throws -> ReconstructionObservationComparison {
        let candidate = try ReconstructionObservationAdapter.candidate(evaluation,
            evidenceID: fixture.candidateEvidenceID, original: fixture.original, contract: contract)
        return try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: currency,
            original: fixture.original, candidate: candidate)
    }

    func testOracleAdapterPreservesOrderInputsEnvironmentAndCompleteness() throws {
        let fixture = try fixture()
        let set = fixture.original
        XCTAssertEqual(set.cases.map(\.ordinal), Array(0..<fixture.oracle.inputs.count))
        XCTAssertEqual(set.cases.map(\.input), fixture.oracle.inputs)
        XCTAssertEqual(set.cases.map(\.effects),
                       fixture.oracle.outputs.map { [ReconstructionObservationEffect.returnValueU32($0)] })
        XCTAssertTrue(set.cases.allSatisfy { $0.completeness == .complete })
        XCTAssertEqual(set.environment.compilerSHA256, fixture.oracle.execution.compilerSHA256)
        XCTAssertEqual(set.environment.executionArgumentsSHA256, fixture.oracle.execution.executionArgumentsSHA256)
        XCTAssertNil(set.environment.runnerSHA256, "the oracle records no runner identity; none is invented")
        XCTAssertEqual(set.state, .freshProcess(executableSHA256: digest, casesShareProcess: true))
    }

    func testEqualSetsYieldAllEqual() throws {
        let fixture = try fixture()
        let comparison = try compare(fixture, evaluation(fixture))
        XCTAssertTrue(comparison.isEquivalent)
        XCTAssertEqual(comparison.cases.count, fixture.oracle.inputs.count)
        XCTAssertEqual(comparison.scenarioRole, .development)
    }

    func testDiffersVerdictsMatchExistingMismatchesExactly() throws {
        let fixture = try fixture()
        var outputs = fixture.oracle.outputs
        for index in [0, 5, 36] { outputs[index] &+= 7 }
        let value = evaluation(fixture, status: .behaviorMismatch, outputs: outputs)
        let before = try ReconstructionSourceEvaluationCodec.encode(value)
        let comparison = try compare(fixture, value)
        let differing = comparison.cases.compactMap { item -> ReconstructionSourceEvaluation.Mismatch? in
            guard case .differs(let expected, let actual) = item.verdict,
                  case .returnValueU32(let e)? = expected.first, case .returnValueU32(let a)? = actual.first else { return nil }
            return ReconstructionSourceEvaluation.Mismatch(index: item.ordinal, input: item.input, expected: e, actual: a)
        }
        XCTAssertEqual(differing, value.capturedOutcome.mismatches)
        XCTAssertEqual(try ReconstructionSourceEvaluationCodec.encode(value), before, "adaptation never alters evaluation bytes")
    }

    func testAbsentBehaviorOutputIsIncompleteNeverFabricated() throws {
        let fixture = try fixture()
        let comparison = try compare(fixture, evaluation(fixture, status: .invalidBehaviorOutput))
        XCTAssertTrue(comparison.cases.allSatisfy { $0.verdict == .incomplete(.candidate) })
        let unbuilt = try ReconstructionObservationAdapter.candidate(evaluation(fixture, status: .buildRejected),
            evidenceID: UUID(), original: fixture.original, contract: contract)
        XCTAssertTrue(unbuilt.cases.allSatisfy { $0.completeness == .absent(.notExecuted) && $0.effects.isEmpty })
    }

    func testCancelledEvaluationHasNoObservationSet() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try compare(fixture, evaluation(fixture, status: .cancelled))) {
            XCTAssertEqual($0 as? ReconstructionObservationAdapterError, .noObservation(.cancelled))
        }
    }

    func testEnvironmentMismatchMakesEveryCaseIncomparable() throws {
        let fixture = try fixture()
        let comparison = try compare(fixture, evaluation(fixture, compiler: String(repeating: "e", count: 64)))
        XCTAssertTrue(comparison.cases.allSatisfy { $0.verdict == .incomparable(.environment) })
        XCTAssertFalse(comparison.isEquivalent)
    }

    func testInputIdentityMismatchIsPerCaseIncomparable() throws {
        let fixture = try fixture()
        var candidate = try ReconstructionObservationAdapter.candidate(evaluation(fixture), evidenceID: UUID(),
            original: fixture.original, contract: contract)
        var cases = candidate.cases
        cases[3] = ReconstructionObservedCase(ordinal: 3, input: cases[3].input &+ 1, completeness: .complete,
                                              effects: cases[3].effects)
        candidate = ReconstructionObservationSet(version: candidate.version, side: .candidate,
            contractID: candidate.contractID, contractVersion: candidate.contractVersion,
            suiteSHA256: candidate.suiteSHA256, sourceEvidenceID: candidate.sourceEvidenceID,
            binding: candidate.binding, environment: candidate.environment, state: candidate.state, cases: cases)
        let comparison = try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: fixture.original, candidate: candidate)
        XCTAssertEqual(comparison.cases[3].verdict, .incomparable(.inputIdentity))
        XCTAssertEqual(comparison.cases.filter { $0.verdict != .equal }.map(\.ordinal), [3])
    }

    func testCaseIndependence() throws {
        let fixture = try fixture()
        var outputs = fixture.oracle.outputs
        outputs[10] &+= 1
        let one = try compare(fixture, evaluation(fixture, status: .behaviorMismatch, outputs: outputs))
        XCTAssertEqual(one.cases.filter { $0.verdict != .equal }.map(\.ordinal), [10])
        var more = outputs
        more[2] &+= 3
        more[30] &+= 3
        let three = try compare(fixture, evaluation(fixture, status: .behaviorMismatch, outputs: more))
        XCTAssertEqual(three.cases[10], one.cases[10], "verdict k depends only on case k")
    }

    func testStaleScopeUnscopedScenarioAndForeignContractAreRefused() throws {
        let fixture = try fixture()
        let stale = [UUID()]
        XCTAssertThrowsError(try compare(fixture, evaluation(fixture), currency: .stale(stale))) {
            XCTAssertEqual($0 as? ReconstructionObservationComparator.Failure, .staleScope(stale))
        }
        let unscoped = try ReconstructionObservationAdapter.original(fixture.oracle, evidenceID: UUID(),
                                                                       contract: contract)
        let candidate = try ReconstructionObservationAdapter.candidate(evaluation(fixture), evidenceID: UUID(),
            original: fixture.original, contract: contract)
        XCTAssertThrowsError(try ReconstructionObservationAdapter.candidate(evaluation(fixture), evidenceID: UUID(),
            original: unscoped, contract: contract)) {
            XCTAssertEqual($0 as? ReconstructionObservationAdapterError, .suiteMismatch,
                           "a candidate binds to its own oracle evidence")
        }
        XCTAssertThrowsError(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: unscoped, candidate: candidate)) {
            XCTAssertEqual($0 as? ReconstructionObservationComparator.Failure, .scenarioNotScoped)
        }
        XCTAssertThrowsError(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: candidate, candidate: fixture.original)) {
            XCTAssertEqual($0 as? ReconstructionObservationComparator.Failure, .sideMismatch)
        }
        let widened = ReconstructionObservationContract(contractID: contract.contractID, version: contract.version,
            sourceProfileID: contract.sourceProfileID, oracleVersion: contract.oracleVersion,
            harnessVersion: contract.harnessVersion, maximumCases: 1_024, channels: contract.channels,
            completeness: contract.completeness)
        XCTAssertThrowsError(try ReconstructionObservationAdapter.original(fixture.oracle,
            evidenceID: fixture.oracleEvidenceID, contract: widened)) {
            XCTAssertEqual($0 as? ReconstructionObservationAdapterError, .unadmittedContract)
        }
    }

    func testComparisonDigestBindsScopeAndSetDigests() throws {
        let fixture = try fixture()
        let comparison = try compare(fixture, evaluation(fixture))
        let decoded = try JSONDecoder().decode(ReconstructionObservationComparison.self,
                                               from: ReconstructionCanonicalJSON.encode(comparison))
        XCTAssertEqual(decoded, comparison)
        XCTAssertEqual(comparison.scopeSHA256, fixture.scope.canonicalSHA256)
        XCTAssertEqual(comparison.originalSetSHA256, try fixture.original.canonicalSHA256)
        var outputs = fixture.oracle.outputs
        outputs[0] &+= 1
        let other = try compare(fixture, evaluation(fixture, status: .behaviorMismatch, outputs: outputs))
        XCTAssertNotEqual(other.cases, comparison.cases)
        XCTAssertNotEqual(try other.canonicalSHA256, try comparison.canonicalSHA256)
        XCTAssertEqual(try compare(fixture, evaluation(fixture)).canonicalSHA256, try comparison.canonicalSHA256,
                       "same inputs give the same digest")
    }
    private func replacing<Value: Codable>(_ value: Value, _ edit: (inout [String: Any]) throws -> Void) throws -> Value {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(value))
            as? [String: Any])
        try edit(&object)
        return try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func copy(_ set: ReconstructionObservationSet,
                      cases: [ReconstructionObservedCase]? = nil,
                      state: ReconstructionObservationState? = nil,
                      binding: ReconstructionObservationSet.SourceBinding? = nil,
                      side: ReconstructionObservationSet.Side? = nil,
                      version: Int? = nil, contractVersion: Int? = nil) -> ReconstructionObservationSet {
        .init(version: version ?? set.version, side: side ?? set.side, contractID: set.contractID,
            contractVersion: contractVersion ?? set.contractVersion, suiteSHA256: set.suiteSHA256,
            sourceEvidenceID: set.sourceEvidenceID, binding: binding ?? set.binding,
            environment: set.environment, state: state ?? set.state, cases: cases ?? set.cases)
    }

    func testCompleteAndAbsentEffectsMustMatchScalarContract() throws {
        let fixture = try fixture()
        let candidate = try ReconstructionObservationAdapter.candidate(evaluation(fixture),
            evidenceID: fixture.candidateEvidenceID, original: fixture.original, contract: contract)
        let emptyComplete = fixture.original.cases.map {
            ReconstructionObservedCase(ordinal: $0.ordinal, input: $0.input, completeness: .complete, effects: [])
        }
        // Equal empty arrays used to look equivalent on both sides of every complete case.
        XCTAssertThrowsError(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: copy(fixture.original, cases: emptyComplete), candidate: copy(candidate, cases: emptyComplete))) {
            XCTAssertEqual($0 as? ReconstructionObservationComparator.Failure, .malformedObservations)
        }
        var extraEffects = candidate.cases
        extraEffects[0] = .init(ordinal: 0, input: extraEffects[0].input, completeness: .complete,
            effects: [.returnValueU32(1), .returnValueU32(2)])
        var absentWithEffect = candidate.cases
        absentWithEffect[0] = .init(ordinal: 0, input: absentWithEffect[0].input,
            completeness: .absent(.notExecuted), effects: [.returnValueU32(1)])
        var badOrdinal = candidate.cases
        badOrdinal[1] = .init(ordinal: 0, input: badOrdinal[1].input, completeness: .complete, effects: badOrdinal[1].effects)
        let oversized = (0...contract.maximumCases).map {
            ReconstructionObservedCase(ordinal: $0, input: UInt32($0), completeness: .complete, effects: [.returnValueU32(1)])
        }
        for malformed in [[], extraEffects, absentWithEffect, badOrdinal, oversized] {
            XCTAssertThrowsError(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
                original: fixture.original, candidate: copy(candidate, cases: malformed))) {
                XCTAssertEqual($0 as? ReconstructionObservationComparator.Failure, .malformedObservations)
            }
        }
        let absent = candidate.cases.map {
            ReconstructionObservedCase(ordinal: $0.ordinal, input: $0.input,
                completeness: .absent(.behaviorOutputUnavailable), effects: [])
        }
        let incomplete = try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: fixture.original, candidate: copy(candidate, cases: absent))
        XCTAssertFalse(incomplete.isEquivalent)
        XCTAssertTrue(incomplete.cases.allSatisfy { $0.verdict == .incomplete(.candidate) })
        XCTAssertTrue(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: fixture.original, candidate: candidate).isEquivalent)
    }

    func testStateAssumptionMismatchCannotCompareEqual() throws {
        let fixture = try fixture()
        let candidate = try ReconstructionObservationAdapter.candidate(evaluation(fixture),
            evidenceID: fixture.candidateEvidenceID, original: fixture.original, contract: contract)
        let independent = copy(candidate, state: .freshProcess(executableSHA256: nil, casesShareProcess: false))
        for original in [fixture.original,
                         copy(fixture.original, state: .freshProcess(executableSHA256: digest, casesShareProcess: false))] {
            let result = try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
                original: original, candidate: independent)
            XCTAssertFalse(result.isEquivalent)
            XCTAssertTrue(result.cases.allSatisfy { $0.verdict == .incomparable(.state) })
        }
        // The candidate is another executable; that difference is expected, not a state mismatch.
        let differentExecutable = copy(candidate,
            state: .freshProcess(executableSHA256: String(repeating: "b", count: 64), casesShareProcess: true))
        XCTAssertTrue(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: fixture.original, candidate: differentExecutable).isEquivalent)
        XCTAssertNil(fixture.original.environment.runnerSHA256)
        XCTAssertNil(candidate.environment.executionArgumentsSHA256)
    }

    func testAdapterRejectsForeignOracleAndEvaluationBindings() throws {
        let fixture = try fixture()
        let evaluation = evaluation(fixture)
        for original in [copy(fixture.original, side: .candidate), copy(fixture.original, version: 2),
                         copy(fixture.original, contractVersion: 2)] {
            XCTAssertThrowsError(try ReconstructionObservationAdapter.candidate(evaluation,
                evidenceID: fixture.candidateEvidenceID, original: original, contract: contract))
        }
        for (key, value) in [("projectID", UUID().uuidString), ("jobID", UUID().uuidString),
                             ("oracleEvidenceID", UUID().uuidString), ("oracleSuiteSHA256", String(repeating: "b", count: 64)),
                             ("oraclePayloadSHA256", String(repeating: "b", count: 64)), ("profileID", "unknown-profile")] {
            let foreign = try replacing(evaluation) { $0[key] = value }
            XCTAssertThrowsError(try ReconstructionObservationAdapter.candidate(foreign,
                evidenceID: fixture.candidateEvidenceID, original: fixture.original, contract: contract))
        }
        let wrongVersion = try replacing(evaluation) { $0["version"] = 2 }
        XCTAssertThrowsError(try ReconstructionObservationAdapter.candidate(wrongVersion,
            evidenceID: fixture.candidateEvidenceID, original: fixture.original, contract: contract))
        let foreignFunction = try replacing(fixture.oracle.function) { $0["startAddress"] = fixture.oracle.function.startAddress + 1 }
        let foreignEvaluation = try replacing(evaluation) {
            $0["function"] = try JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(foreignFunction))
        }
        XCTAssertThrowsError(try ReconstructionObservationAdapter.candidate(foreignEvaluation,
            evidenceID: fixture.candidateEvidenceID, original: fixture.original, contract: contract))
        let wrongOracle = try replacing(fixture.oracle) { $0["version"] = 2 }
        XCTAssertThrowsError(try ReconstructionObservationAdapter.original(wrongOracle,
            evidenceID: fixture.oracleEvidenceID, contract: contract))
        XCTAssertThrowsError(try ReconstructionObservationAdapter.candidate(evaluation,
            evidenceID: fixture.oracleEvidenceID, original: fixture.original, contract: contract))
        let candidate = try ReconstructionObservationAdapter.candidate(evaluation,
            evidenceID: fixture.candidateEvidenceID, original: fixture.original, contract: contract)
        let originalBinding = fixture.original.binding
        XCTAssertEqual(originalBinding.oraclePayloadSHA256,
            try ReconstructionSourceRevisionAdmission.sourceSHA256(ReconstructionCanonicalJSON.encode(fixture.oracle)))
        let foreignBinding = ReconstructionObservationSet.SourceBinding(projectID: UUID(), jobID: originalBinding.jobID,
            function: originalBinding.function, oracleEvidenceID: originalBinding.oracleEvidenceID,
            oraclePayloadSHA256: originalBinding.oraclePayloadSHA256)
        XCTAssertThrowsError(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: fixture.original, candidate: copy(candidate, binding: foreignBinding)))
        // Both directly constructed sets can agree with each other yet disagree with the scope.
        XCTAssertThrowsError(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: copy(fixture.original, binding: foreignBinding), candidate: copy(candidate, binding: foreignBinding))) {
            XCTAssertEqual($0 as? ReconstructionObservationComparator.Failure, .sourceBindingMismatch)
        }
        let changedPayload = ReconstructionObservationSet.SourceBinding(projectID: originalBinding.projectID,
            jobID: originalBinding.jobID, function: originalBinding.function,
            oracleEvidenceID: originalBinding.oracleEvidenceID, oraclePayloadSHA256: String(repeating: "c", count: 64))
        XCTAssertThrowsError(try ReconstructionObservationComparator.compare(scope: fixture.scope, currency: .current,
            original: fixture.original, candidate: copy(candidate, binding: changedPayload)))
        // These remain value-consistency tests. A matching forged record/currency supplied by a
        // caller is not authenticated by these pure adapters or the comparator.
    }

}
