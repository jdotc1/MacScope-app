import Foundation
import XCTest
@testable import MacScope

final class Phase2QualificationGateProviderAdmissionTests: XCTestCase {
    func testCandidateKeepsOpaqueInstanceAndOptionalQuantizationObservation() throws {
        let model = candidate(bits: nil)
        let inventory = try Phase2LocalModelInventory(profileID: UUID(), generation: 1, models: [model])
        XCTAssertEqual(Phase2QualificationGateCandidateModelPolicy.exactModel(inventory), model)
        XCTAssertEqual(Phase2QualificationGateCandidateModelPolicy.exactLoadedInstance(in: model)?.id, "opaque-instance-7")
        XCTAssertNil(Phase2QualificationGateCandidateModelPolicy.exactModel(inventory)?.quantization?.bitsPerWeight)
        let observed = candidate(bits: 6.57)
        XCTAssertEqual(Phase2QualificationGateCandidateModelPolicy.exactModel(
            try .init(profileID: UUID(), generation: 1, models: [observed])
        )?.quantization?.bitsPerWeight, 6.57)
    }

    func testCandidateRequiresObservedSinglePredictionAndExactContext() throws {
        for model in [candidate(parallel: nil), candidate(parallel: 4), candidate(context: 262_144)] {
            XCTAssertNil(Phase2QualificationGateCandidateModelPolicy.exactModel(
                try .init(profileID: UUID(), generation: 1, models: [model])
            ))
        }
    }

    func testCandidateRejectsAbsentAmbiguousAndMalformedInstanceIDs() throws {
        for instances in [[], [instance("one"), instance("two")], [instance("")], [instance(" bad ")], [instance("bad\0id")]] {
            XCTAssertNil(Phase2QualificationGateCandidateModelPolicy.exactModel(
                try .init(profileID: UUID(), generation: 1, models: [candidate(instances: instances)])
            ))
        }
        XCTAssertThrowsError(try Phase2LocalModelInventory(
            profileID: UUID(), generation: 1,
            models: [candidate(instances: [instance("same"), instance("same")])]
        ))
    }

    func testCandidateRejectsNearbyModelOrArtifactMetadata() throws {
        for model in [candidate(key: "Qwen3.8-27b-obliterated"), candidate(publisher: "other"),
                      candidate(format: .mlx), candidate(quantization: "Q8_0"),
                      candidate(bytes: 22_430_991_392), candidate(maximumContext: 32_768)] {
            XCTAssertNil(Phase2QualificationGateCandidateModelPolicy.exactModel(
                try .init(profileID: UUID(), generation: 1, models: [model])
            ))
        }
    }

    func testStandaloneSignatureHasSeparateExactAuthority() {
        let home = URL(fileURLWithPath: "/Users/test")
        XCTAssertTrue(Phase2QualificationGateProviderCodeIdentityPolicy.acceptsStandalone(codeIdentity(), homeDirectory: home))
        XCTAssertFalse(Phase2QualificationGateProviderCodeIdentityPolicy.accepts(codeIdentity()))
        for identity in [codeIdentity(identifier: "ai.elementlabs.lmstudio"),
                         codeIdentity(flags: 0x10002), codeIdentity(flags: 0),
                         codeIdentity(cdHash: String(repeating: "0", count: 40)),
                         codeIdentity(digest: String(repeating: "0", count: 64)),
                         codeIdentity(path: "/tmp/llmster"), codeIdentity(team: "OTHER")] {
            XCTAssertFalse(Phase2QualificationGateProviderCodeIdentityPolicy.acceptsStandalone(identity, homeDirectory: home))
        }
        XCTAssertFalse(Phase2QualificationGateProviderCodeIdentityPolicy.acceptsStandalone(
            codeIdentity(), homeDirectory: URL(fileURLWithPath: "/Users/other")
        ))
    }

    private func instance(_ id: String) -> Phase2LocalModelLoadedInstance {
        .init(id: id, configuration: .init(effectiveContextLength: 32_768, parallelPredictions: 1))
    }

    private func candidate(
        key: String = "qwen3.8-27b-obliterated", publisher: String = "OBLITERATUS",
        format: Phase2LocalModelFormat = .gguf, quantization: String = "Q6_K", bits: Double? = nil,
        bytes: UInt64 = 22_431_004_152, maximumContext: Int = 262_144,
        context: Int = 32_768, parallel: Int? = 1,
        instances: [Phase2LocalModelLoadedInstance]? = nil
    ) -> Phase2LocalModelDescriptor {
        .init(type: .language, publisher: publisher, key: key, displayName: "candidate",
              architecture: nil, quantization: .init(name: quantization, bitsPerWeight: bits),
              sizeBytesOnDisk: bytes, parameterCountDescription: nil,
              maximumContextLength: maximumContext, format: format, capabilities: nil,
              variants: [], providerSelectedVariant: nil,
              loadedInstances: instances ?? [.init(id: "opaque-instance-7", configuration: .init(
                effectiveContextLength: context, parallelPredictions: parallel
              ))])
    }

    private func codeIdentity(
        identifier: String = "llmster", flags: UInt32 = 0x10000,
        cdHash: String = Phase2QualificationProviderAdmissionPolicy.cdHash,
        digest: String = Phase2QualificationProviderAdmissionPolicy.executableSHA256,
        path: String = "/Users/test/.lmstudio/llmster/0.0.21-2/llmster",
        team: String = "D65G88RHWN"
    ) -> Phase2QualificationGateProviderCodeIdentity {
        .init(identifier: identifier, teamIdentifier: team, signatureFlags: flags,
              runtimeVersion: 1, leafCertificateCommonName: "Developer ID Application: Element Labs Inc (D65G88RHWN)",
              certificateCount: 3, cdHash: cdHash, canonicalBundlePath: path, executableSHA256: digest)
    }
}
