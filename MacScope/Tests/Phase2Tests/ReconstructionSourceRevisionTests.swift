import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceRevisionTests: XCTestCase {
    func testProfileDispatchBindsAuthorityWithoutChangingScalarRevisionBytes() throws {
        let base = try authority()
        let legacy = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: base)
        let explicit = ReconstructionSourceRevisionAuthority(projectID: base.projectID, jobID: base.jobID,
            function: base.function, objectiveSHA256: base.objectiveSHA256,
            evidenceFrontierSHA256: base.evidenceFrontierSHA256, oracleSuiteSHA256: base.oracleSuiteSHA256,
            admissibleEvidenceIDs: base.admissibleEvidenceIDs, currentRevision: nil,
            profileID: "arm64-c-u32-saturating-increment-v1")
        let bytes = try ReconstructionSourceRevisionAdmission.encode(legacy)
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.encode(
            ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: explicit)), bytes)
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.encode(
            ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: bytes, authority: explicit)), bytes)
        for profile in ["arm64-c-adler32-combine-record-v1", "unknown-profile"] {
            let foreign = ReconstructionSourceRevisionAuthority(projectID: base.projectID, jobID: base.jobID,
                function: base.function, objectiveSHA256: base.objectiveSHA256,
                evidenceFrontierSHA256: base.evidenceFrontierSHA256, oracleSuiteSHA256: base.oracleSuiteSHA256,
                admissibleEvidenceIDs: base.admissibleEvidenceIDs, currentRevision: nil, profileID: profile)
            XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: foreign))
            XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: bytes, authority: foreign))
            XCTAssertThrowsError(try ReconstructionSourceBehaviorHarness.forProfile(profile))
        }
        // Freeze the historical input algorithm independently of the new dispatch owner.
        var inputs: [UInt32] = [0, 1, 41, UInt32.max - 1, UInt32.max], state: UInt32 = 0x4d534331
        for _ in 0..<32 {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            if !inputs.contains(state) { inputs.append(state) }
        }
        XCTAssertEqual(try ReconstructionSourceBehaviorHarness.forProfile(legacy.profileID),
            try ReconstructionSourceBehaviorHarness(inputs: inputs))
    }

    private let project = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let job = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let evidence = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private var bytes: Data { Data("#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x == UINT32_MAX ? x : x + 1; }\n".utf8) }
    private func digest(_ character: Character) -> String { String(repeating: String(character), count: 64) }
    private func authority(current: ReconstructionSourceRevision? = nil, jobID: UUID? = nil) throws -> ReconstructionSourceRevisionAuthority {
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: project),
            contentIdentity: try .init(algorithm: .sha256, digest: digest("a"), byteCount: 100))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: project, imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: digest("b"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: UUID(), symbolHint: "reconstructed")
        return .init(projectID: project, jobID: jobID ?? job, function: function,
            objectiveSHA256: digest("c"), evidenceFrontierSHA256: digest("d"), oracleSuiteSHA256: digest("e"),
            admissibleEvidenceIDs: [evidence], currentRevision: current)
    }
    private func proposal(_ source: Data? = nil) -> ReconstructionSourceRevisionProposal {
        let source = source ?? bytes
        return .init(sourceUTF8: source, claimedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source), evidenceIDs: [evidence])
    }
    private func rejects(_ expected: ReconstructionSourceRevisionAdmission.Failure,
                         _ proposal: ReconstructionSourceRevisionProposal) throws {
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.admit(proposal: proposal, authority: authority())) {
            XCTAssertEqual($0 as? ReconstructionSourceRevisionAdmission.Failure, expected)
        }
    }
    func testCanonicalRoundtripAndHintIndependentIdentity() throws {
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: authority())
        let second = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: authority())
        XCTAssertEqual(revision, second) // changing incidental function UUID hints has no authority
        XCTAssertEqual(revision.status, .proposed)
        let payload = try ReconstructionSourceRevisionAdmission.encode(revision)
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: payload, authority: authority()), revision)
    }
    func testRejectsPathsProfilesHashesAndReferences() throws {
        for path in ["../candidate.c", "/candidate.c", "candidate.c/", "oracle.c", "Candidate.c", "candidate.c\u{0}"] {
            var p = proposal(); p.relativePath = path; try rejects(.unsafePath, p)
        }
        var p = proposal(); p.profileID = "arbitrary-shell"; try rejects(.unsupportedProfile, p)
        p = proposal(); p.version = 2; try rejects(.unsupportedVersion, p)
        p = proposal(); p.claimedSourceSHA256 = digest("f"); try rejects(.sourceHashMismatch, p)
        p = proposal(); p.evidenceIDs = []; try rejects(.invalidEvidenceReferences, p)
        p = proposal(); p.evidenceIDs = [evidence, evidence]; try rejects(.invalidEvidenceReferences, p)
        p = proposal(); p.evidenceIDs = [UUID()]; try rejects(.invalidEvidenceReferences, p)
    }
    func testSourceBoundsAndEncoding() throws {
        try rejects(.sourceBounds, proposal(Data()))
        try rejects(.sourceBounds, proposal(Data(repeating: 65, count: 65_537)))
        try rejects(.invalidUTF8, proposal(Data([0xff])))
        try rejects(.invalidUTF8, proposal(Data([65, 0])))
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(Data(repeating: 65, count: 65_536)), authority: authority()).sourceUTF8.count, 65_536)
    }
    func testExactParentAndOwnerAdmission() throws {
        let parent = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: authority())
        var child = proposal(Data("uint32_t reconstructed(uint32_t x) { return x; }".utf8))
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.admit(proposal: child, authority: authority(current: parent))) {
            XCTAssertEqual($0 as? ReconstructionSourceRevisionAdmission.Failure, .staleParent)
        }
        child.parentRevisionSHA256 = parent.revisionSHA256
        let admitted = try ReconstructionSourceRevisionAdmission.admit(proposal: child, authority: authority(current: parent))
        XCTAssertEqual(admitted.parentRevisionSHA256, parent.revisionSHA256)
        XCTAssertNotEqual(admitted.revisionSHA256, parent.revisionSHA256)
        var third = proposal(); third.parentRevisionSHA256 = admitted.revisionSHA256
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.admit(proposal: third, authority: authority(current: admitted))) {
            XCTAssertEqual($0 as? ReconstructionSourceRevisionAdmission.Failure, .revisionLimit)
        }
        let payload = try ReconstructionSourceRevisionAdmission.encode(admitted)
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: payload, authority: authority(current: parent)), admitted)
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.admit(proposal: child, authority: authority(current: parent, jobID: UUID())))
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: payload, authority: authority()))
    }
    func testHostileCanonicalPayloadRejection() throws {
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: authority())
        let payload = try ReconstructionSourceRevisionAdmission.encode(revision)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        object["extra"] = "ignored by ordinary Codable"
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: JSONSerialization.data(withJSONObject: object), authority: authority()))
        object.removeValue(forKey: "extra"); object["revisionSHA256"] = digest("f")
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: JSONSerialization.data(withJSONObject: object), authority: authority()))
        object["revisionSHA256"] = revision.revisionSHA256; object["status"] = "accepted"
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: JSONSerialization.data(withJSONObject: object), authority: authority()))
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))
        let duplicate = Data(("{\"version\":1," + text.dropFirst()).utf8)
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: duplicate, authority: authority()))
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: payload + Data("\n".utf8), authority: authority()))
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: Data(repeating: 32, count: 131_073), authority: authority()))
    }
    func testDisabledAndUnknownProfilesRejectProposalAndPersistedRevision() throws {
        let base = try authority()
        let legacy = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: base)
        let payload = try ReconstructionSourceRevisionAdmission.encode(legacy)
        for profile in ["arm64-c-adler32-combine-record-v1", "unrecognized-profile"] {
            var proposed = proposal(); proposed.profileID = profile
            try rejects(.unsupportedProfile, proposed)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            object["profileID"] = profile
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: changed, authority: base)) {
                XCTAssertEqual($0 as? ReconstructionSourceRevisionAdmission.Failure, .unsupportedProfile)
            }
        }
    }

    func testDisabledAndUnknownParentProfilesPreserveAuthorityFailure() throws {
        let parent = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: authority())
        let payload = try ReconstructionSourceRevisionAdmission.encode(parent)
        var validChild = proposal(); validChild.parentRevisionSHA256 = parent.revisionSHA256
        XCTAssertNoThrow(try ReconstructionSourceRevisionAdmission.admit(proposal: validChild, authority: authority(current: parent)))
        for profile in ["arm64-c-adler32-combine-record-v1", "unrecognized-profile"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
            object["profileID"] = profile
            let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            // Deliberately bypass admission to exercise hostile caller-supplied parent authority.
            let hostileParent = try JSONDecoder().decode(ReconstructionSourceRevision.self, from: changed)
            var child = proposal(); child.parentRevisionSHA256 = parent.revisionSHA256
            XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.admit(proposal: child, authority: authority(current: hostileParent))) {
                XCTAssertEqual($0 as? ReconstructionSourceRevisionAdmission.Failure, .authorityMismatch)
            }
        }
    }

    func testDisabledAndUnknownRequestProfilesPreserveBindingFailure() throws {
        let base = try authority(), text = "objective"
        let boundAuthority = ReconstructionSourceRevisionAuthority(projectID: base.projectID, jobID: base.jobID,
            function: base.function, objectiveSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(Data(text.utf8)),
            evidenceFrontierSHA256: base.evidenceFrontierSHA256, oracleSuiteSHA256: base.oracleSuiteSHA256,
            admissibleEvidenceIDs: base.admissibleEvidenceIDs, currentRevision: nil)
        let task = UUID(), round = UUID(), context = Data("{}".utf8)
        for profile in [ReconstructionSourceRevision.profileID, "arm64-c-adler32-combine-record-v1", "unrecognized-profile"] {
            let request = ReconstructionSourceRevisionRequest(protocolVersion: 10,
                objective: try .init(jobID: base.jobID, text: text, sha256: boundAuthority.objectiveSHA256),
                projectID: base.projectID, jobID: base.jobID, taskID: task, checkpointRevision: 1,
                roundID: round, function: base.function, corpusManifestSHA256: digest("a"),
                evidenceFrontierSHA256: base.evidenceFrontierSHA256, oracleSuiteSHA256: base.oracleSuiteSHA256,
                profileID: profile, parentRevisionSHA256: nil,
                context: .init(canonicalBytes: context,
                    canonicalSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(context), evidenceIDs: [evidence]))
            let bytes = try ReconstructionCanonicalJSON.encode(request)
            let binding = ReconstructionSourceRequestBinding(canonicalRequestBytes: bytes,
                requestSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes), taskID: task,
                roundID: round, checkpointRevision: 1)
            if profile == ReconstructionSourceRevision.profileID {
                XCTAssertEqual(try ReconstructionSourceRevisionAdmission.validateRequestBinding(binding, authority: boundAuthority), [evidence])
            } else {
                XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.validateRequestBinding(binding, authority: boundAuthority)) {
                    XCTAssertEqual($0 as? ReconstructionSourceRevisionAdmission.Failure, .invalidRequestBinding)
                }
            }
        }
    }

    func testLegacyProfileDispatchRetainsCanonicalPayload() throws {
        XCTAssertEqual(ReconstructionSourceRevision.profileDisposition(for: ReconstructionSourceRevision.profileID), .legacy)
        XCTAssertEqual(ReconstructionSourceRevision.profileDisposition(for: "arm64-c-adler32-combine-record-v1"), .disabled)
        XCTAssertEqual(ReconstructionSourceRevision.profileDisposition(for: "unrecognized-profile"), .unsupported)
        let base = try authority()
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: base)
        let payload = try ReconstructionSourceRevisionAdmission.encode(revision)
        let restored = try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: payload, authority: base)
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.encode(restored), payload)
        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.profileID, "arm64-c-u32-saturating-increment-v1")
        XCTAssertEqual(restored.relativePath, "candidate.c")
        XCTAssertNil(restored.requestBinding)
    }

}
