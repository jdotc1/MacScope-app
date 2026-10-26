import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceRequestBindingTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "ad000000-0000-0000-0000-%012d", n))! }
    private func sha(_ text: String) -> String { ReconstructionSourceRevisionAdmission.sourceSHA256(Data(text.utf8)) }
    private func authority(parent: ReconstructionSourceRevision? = nil, frontier: String? = nil,
                           binding: ReconstructionSourceRequestBinding? = nil) throws -> ReconstructionSourceRevisionAuthority {
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: id(1)),
            contentIdentity: try .init(algorithm: .sha256, digest: sha("binary"), byteCount: 32))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: id(2), imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: sha("analysis"), startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        return .init(projectID: id(3), jobID: id(4), function: function, objectiveSHA256: sha("objective"),
            evidenceFrontierSHA256: frontier ?? sha("frontier"), oracleSuiteSHA256: sha("oracle"),
            admissibleEvidenceIDs: [id(5), id(6)], currentRevision: parent, requestBinding: binding)
    }
    private func request(_ authority: ReconstructionSourceRevisionAuthority, contextBytes: Data = Data("{}".utf8),
                         evidenceIDs: [UUID]? = nil) throws -> Data {
        let request = ReconstructionSourceRevisionRequest(protocolVersion: 10,
            objective: try .init(jobID: authority.jobID, text: "objective", sha256: authority.objectiveSHA256),
            projectID: authority.projectID, jobID: authority.jobID, taskID: id(7), checkpointRevision: 1,
            roundID: id(8), function: authority.function, corpusManifestSHA256: sha("corpus"),
            evidenceFrontierSHA256: authority.evidenceFrontierSHA256, oracleSuiteSHA256: authority.oracleSuiteSHA256,
            profileID: ReconstructionSourceRevision.profileID, parentRevisionSHA256: authority.currentRevision?.revisionSHA256,
            context: .init(canonicalBytes: contextBytes,
                canonicalSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(contextBytes),
                evidenceIDs: evidenceIDs ?? [id(5)]))
        return try ReconstructionCanonicalJSON.encode(request)
    }
    private func bind(_ bytes: Data, authority: ReconstructionSourceRevisionAuthority) throws -> ReconstructionSourceRequestBinding {
        try ReconstructionSourceRevisionAdmission.makeRequestBinding(canonicalRequestBytes: bytes,
            requestSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes), authority: authority,
            expectedTaskID: id(7), expectedRoundID: id(8), expectedCheckpointRevision: 1)
    }
    private func proposal(parent: String? = nil, evidenceIDs: [UUID]? = nil, source: Data = Data("uint32_t reconstructed(uint32_t x) { return x; }".utf8)) -> ReconstructionSourceRevisionProposal {
        .init(parentRevisionSHA256: parent, sourceUTF8: source,
              claimedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source), evidenceIDs: evidenceIDs ?? [id(5)])
    }
    private func changed(_ bytes: Data, _ edit: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    func testExactTypedV10RequestSurvivesSourceRoundtripAndCommitsRevisionIdentity() throws {
        let base = try authority(), bytes = try request(base), binding = try bind(bytes, authority: base)
        let bound = try authority(binding: binding)
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: bound)
        XCTAssertEqual(revision.requestBinding?.canonicalRequestBytes, bytes)
        XCTAssertEqual(revision.requestBinding?.requestSHA256, ReconstructionSourceRevisionAdmission.sourceSHA256(bytes))
        let payload = try ReconstructionSourceRevisionAdmission.encode(revision)
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: payload, authority: bound), revision)
        let legacy = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: base)
        XCTAssertNil(legacy.requestBinding)
        XCTAssertNotEqual(legacy.revisionSHA256, revision.revisionSHA256)
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: payload, authority: base))
        let tampered = try changed(payload) {
            var stored = $0["requestBinding"] as! [String: Any]
            stored["requestSHA256"] = self.sha("invented request"); $0["requestBinding"] = stored
        }
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: tampered, authority: bound))
    }
    func testClosedCanonicalRequestAndOwnerFieldsRejectEvenWhenRehashed() throws {
        let base = try authority(), bytes = try request(base)
        let edits: [(inout [String: Any]) -> Void] = [
            { $0["projectID"] = self.id(90).uuidString }, { $0["jobID"] = self.id(90).uuidString },
            { $0["taskID"] = self.id(90).uuidString }, { $0["roundID"] = self.id(90).uuidString },
            { $0["checkpointRevision"] = 2 }, { $0["evidenceFrontierSHA256"] = self.sha("other") },
            { $0["oracleSuiteSHA256"] = self.sha("other") }, { $0["profileID"] = "other" },
            { $0["parentRevisionSHA256"] = self.sha("invented parent") }, { $0["protocolVersion"] = 9 },
            { $0["command"] = "do not execute" }
        ]
        for edit in edits { XCTAssertThrowsError(try bind(changed(bytes, edit), authority: base)) }
        let string = String(decoding: bytes, as: UTF8.self)
        XCTAssertThrowsError(try bind(Data(string.replacingOccurrences(of: "\"protocolVersion\":10", with: "\"protocolVersion\":10,\"protocolVersion\":10").utf8), authority: base))
        XCTAssertThrowsError(try bind(bytes + Data(" ".utf8), authority: base))
        let corrupt = ReconstructionSourceRequestBinding(canonicalRequestBytes: bytes, requestSHA256: sha("wrong"),
            taskID: id(7), roundID: id(8), checkpointRevision: 1)
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.validateRequestBinding(corrupt, authority: base))
    }
    func testContextExactHashCanonicalBytesBoundsAndEvidenceCutReject() throws {
        let base = try authority(), bytes = try request(base)
        for contextBytes in [Data("{\"a\":1,\"a\":1}".utf8), Data("{ \"a\":1}".utf8), Data(repeating: 32, count: ReconstructionSourceRequestBinding.maximumContextBytes + 1)] {
            XCTAssertThrowsError(try bind(request(base, contextBytes: contextBytes), authority: base))
        }
        XCTAssertThrowsError(try bind(request(base, evidenceIDs: [id(90)]), authority: base))
        XCTAssertThrowsError(try bind(request(base, evidenceIDs: [id(5), id(5)]), authority: base))
        let wrongContextHash = try changed(bytes) {
            var context = $0["context"] as! [String: Any]; context["canonicalSHA256"] = self.sha("wrong"); $0["context"] = context
        }
        XCTAssertThrowsError(try bind(wrongContextHash, authority: base))
        let bound = try authority(binding: bind(bytes, authority: base))
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(evidenceIDs: [id(6)]), authority: bound))
        XCTAssertThrowsError(try bind(Data(repeating: 32, count: ReconstructionSourceRequestBinding.maximumRequestBytes + 1), authority: base))
    }
    func testHistoricalParentBindingUsesItsOriginalFrontierAndContext() throws {
        let base = try authority(), parentAuthority = try authority(binding: bind(request(base), authority: base))
        let parent = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(), authority: parentAuthority)
        let next = try authority(parent: parent, frontier: sha("successor frontier"))
        let nextBound = try authority(parent: parent, frontier: next.evidenceFrontierSHA256, binding: bind(request(next), authority: next))
        let child = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(parent: parent.revisionSHA256), authority: nextBound)
        XCTAssertEqual(child.parentRevisionSHA256, parent.revisionSHA256)
        XCTAssertNotEqual(child.requestBinding, parent.requestBinding)
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: ReconstructionSourceRevisionAdmission.encode(child), authority: nextBound), child)
    }
    func testIndependentSourceAndContextBoundsRetainCombinedPayloadCeiling() throws {
        let base = try authority()
        let context = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "a",
            count: ReconstructionSourceRequestBinding.maximumContextBytes - 11)], options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertEqual(context.count, ReconstructionSourceRequestBinding.maximumContextBytes)
        let binding = try bind(request(base, contextBytes: context), authority: base)
        let bound = try authority(binding: binding)
        XCTAssertThrowsError(try ReconstructionSourceRevisionAdmission.admit(
            proposal: proposal(source: Data(repeating: 97, count: 65_536)), authority: bound)) { error in
            XCTAssertEqual(error as? ReconstructionSourceRevisionAdmission.Failure, .payloadBounds)
        }
    }

    func testMaximumSourceAndBoundedContextRemainInsideUnchangedPayloadCeiling() throws {
        let base = try authority()
        let context = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "a", count: 8_181)], options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertLessThanOrEqual(context.count, 8_192)
        let binding = try bind(request(base, contextBytes: context), authority: base)
        let bound = try authority(binding: binding)
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: proposal(source: Data(repeating: 97, count: 65_536)), authority: bound)
        let payload = try ReconstructionSourceRevisionAdmission.encode(revision)
        XCTAssertLessThanOrEqual(payload.count, 131_072)
        XCTAssertEqual(try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: payload, authority: bound), revision)
    }
}
