import CryptoKit
import XCTest
@testable import MacScope

final class Phase2QualificationProfileContractTests: XCTestCase {
    @MainActor
    func testLegacyLiveAndCanaryCollectorsRejectBeforeRuntimeCollection() async {
        for selector in Phase2QualificationProfileSelector.allCases {
            do {
                _ = try await Phase2QualificationGateRuntimeCollector.collectCurrent(selector: selector)
                XCTFail("Historical profile cannot qualify the current MTPLX runtime")
            } catch {
                XCTAssertEqual(error as? Phase2QualificationGateRuntimeCollectorError, .unsupportedProviderProfile)
            }
            do {
                _ = try await Phase2QualificationGateRuntimeCollector.collectInstalledCanaryCurrent(selector: selector)
                XCTFail("Historical profile cannot authorize an installed MTPLX canary")
            } catch {
                XCTAssertEqual(error as? Phase2QualificationGateRuntimeCollectorError, .unsupportedProviderProfile)
            }
        }
    }

    func testSelectorIsExactClosedAllowlist() {
        XCTAssertEqual(Phase2QualificationProfileSelector.allCases.map(\.rawValue), [
            "historical-f4c", "qwen38-v2-q6k",
        ])
        for value in ["", "QWEN38-V2-Q6K", " qwen38-v2-q6k", "qwen38-v2-q6k\n", "main"] {
            XCTAssertNil(Phase2QualificationProfileSelector(rawValue: value))
        }
    }

    func testHistoricalDefinitionAndPolicyDigestsRemainByteIdentical() {
        let value = Phase2QualificationProfileContract.resolve(.historicalF4C)
        XCTAssertEqual(value.definitionIdentity, Phase2ProductionQualificationPolicy.standard.definitionIdentity)
        XCTAssertEqual(value.definitionIdentity.sha256,
                       "8f17c3acd8e42c50d942108e26ae3342953196d6c910a33b0aa06a0821b05523")
        XCTAssertEqual(value.production.policyIdentity.sha256,
                       "f4e0d43b2b975840686c302740fe946578619eab309896e183225c65e1747559")
        XCTAssertEqual(value.qualificationEventID, "phase2.r1.f4c-b-delivery.v1")
        XCTAssertFalse(value.requiresProviderAdmission)
    }

    func testCandidateChangesAdmissionButNotProtocolPolicyThresholdsOrTrials() {
        let old = Phase2QualificationProfileContract.resolve(.historicalF4C)
        let new = Phase2QualificationProfileContract.resolve(.qwen38V2Q6K)
        XCTAssertNotEqual(new.definitionIdentity, old.definitionIdentity)
        XCTAssertNotEqual(new.modelRevisionIdentity, old.modelRevisionIdentity)
        XCTAssertNotEqual(new.qualificationEventID, old.qualificationEventID)
        XCTAssertEqual(new.production.policy, old.production.policy)
        XCTAssertEqual(new.production.policyIdentity, old.production.policyIdentity)
        XCTAssertEqual(new.production.thresholdSet, old.production.thresholdSet)
        XCTAssertEqual(new.production.liveRequirements, old.production.liveRequirements)
        XCTAssertEqual(new.production.deterministicRequirements, old.production.deterministicRequirements)
        XCTAssertEqual(new.production.protocolProbeCatalogIdentity, old.production.protocolProbeCatalogIdentity)
        XCTAssertEqual(new.production.liveScenarioCatalog.identity, old.production.liveScenarioCatalog.identity)
        XCTAssertEqual(new.production.policy.declaredTrialCount, 163)
        XCTAssertTrue(new.requiresProviderAdmission)
    }

    func testCandidateArtifactManifestUsesTwoExactFilesAndExistingAlgorithm() {
        let aggregate = "Qwen3.8-27B-OBLITERATED-Q6_K.gguf\t22430999840\t"
            + "d8de48c8de37c6238c24a719238e377f94ff1b51c8192029dbfba0a778debcd4\n"
            + "config.json\t4312\t"
            + "191e0af232104ed8b65258cf3fb2b842e288008baca7633c11b82a1ac7203aab\n"
        let digest = SHA256.hash(data: Data(aggregate.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let value = Phase2QualificationProfileContract.resolve(.qwen38V2Q6K)
        XCTAssertEqual(digest, value.production.modelRevision.localArtifactManifestSHA256)
        XCTAssertEqual(digest, "d4ab1fe8f27e4f6c8544198d5971f43e6c98801d5b2a24654ab2c1bdb9c4c717")
        XCTAssertEqual(value.production.modelRevision.upstreamRevisionSHA1,
                       "7ef7657167b8c795077c14a09c84769659fcc0f5")
    }

    func testTemplateDefaultIdentityDoesNotClaimReasoningOff() throws {
        let value = Phase2QualificationProfileContract.resolve(.qwen38V2Q6K)
        let generation = Phase2ModelProtocolManifest.productionGroundedReadOnly.generationPolicy
        XCTAssertEqual(value.generationAdmissionIdentity, try Phase2QualificationV2Identity.make(
            id: "phase2.local.template-default-generation.v1", version: 1,
            object: [
                "version": 1,
                "reasoning_control": "no-request-override-template-default",
                "reasoning_output_policy": "discard",
                "request_generation_policy": [
                    "id": generation.id, "version": generation.version,
                    "sha256": generation.sha256!,
                ] as [String: Any],
            ]
        ))
    }

    func testUnreviewedProviderCannotBeAdmitted() {
        XCTAssertEqual(Phase2QualificationProviderAdmissionPolicy.deficiency(for: nil),
                       .runtimeClosureUnreviewed)
        for reason in Phase2ProviderAdmissionUnavailableReason.allCases {
            XCTAssertEqual(Phase2QualificationProviderAdmissionPolicy.deficiency(for: .unavailable(reason)),
                           .runtimeClosureUnreviewed)
        }
    }
}
