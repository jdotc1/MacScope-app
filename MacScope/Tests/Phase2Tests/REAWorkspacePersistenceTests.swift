import Foundation
import XCTest
@testable import MacScope

@MainActor
final class REAWorkspacePersistenceTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let binary = BinaryImage(id: UUID(), name: "captured", path: "/captured", kind: "Mach-O", architecture: "arm64")
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data([1, 2, 3, 4])
        return WorkspaceStore(workspaceName: "REA fixture",
            snapshot: WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis]),
            engine: AnalysisEngine(), autosaveScheduler: nil)
    }
    private func candidate(_ store: WorkspaceStore) throws -> REAResultEvidence {
        let digest = REACaptureCommitment.digest(try XCTUnwrap(store.focusedAnalysis?.imageBytes))
        let authority = try XCTUnwrap(store.reaAuthority(imageSHA256: digest, snapshotID: UUID()))
        let id = UUID()
        let request = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "requestID": id.uuidString, "operation": "nativeApplication", "input": [:]])
        let response = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
            "requestID": id.uuidString, "operation": "nativeApplication", "ok": true,
            "implementationIdentity": authority.implementationIdentity, "result": ["fixture": true]])
        return try REAResultEvidence(requestID: id, operation: "nativeApplication", authority: authority,
            requestJSON: request, responseJSON: response)
    }
    func testPublicationDoesNotInvalidateItsOwnSourceAndChangedBytesRejectLateResult() throws {
        let store = makeStore(), evidence = try candidate(store)
        try store.publishREAResult(evidence)
        let active = try XCTUnwrap(store.reaAuthority(imageSHA256: evidence.authority.imageSHA256,
                                                     snapshotID: evidence.authority.snapshotID))
        XCTAssertTrue(store.reaResultEvidence.isCurrent(evidence, activeAuthority: active))
        XCTAssertTrue(store.hasUnsavedChanges)
        var changed = try XCTUnwrap(store.snapshot.analysisBySlot[.primary])
        changed.imageBytes = Data([9, 9, 9])
        store.snapshot.analysisBySlot[.primary] = changed
        XCTAssertThrowsError(try store.publishREAResult(evidence))
        XCTAssertEqual(store.reaResultEvidence.records, [evidence])
    }
    func testManifestRetainsExactREAHistoryAndLegacyManifestOmitsIt() throws {
        let store = makeStore(), evidence = try candidate(store)
        try store.publishREAResult(evidence)
        var manifest = WorkspacePackageManifest(documentID: UUID(), workspaceUUID: store.workspaceID,
            workspaceName: "REA", createdAt: Date(timeIntervalSince1970: 0), modifiedAt: Date(timeIntervalSince1970: 0),
            binaries: [], session: nil)
        let legacy = try JSONEncoder().encode(manifest)
        XCTAssertNil((try JSONSerialization.jsonObject(with: legacy) as? [String: Any])?["reaEvidence"])
        manifest.reaEvidence = try JSONEncoder().encode(store.reaResultEvidence)
        let reopened = try JSONDecoder().decode(WorkspacePackageManifest.self, from: JSONEncoder().encode(manifest))
        let history = try JSONDecoder().decode(REAResultEvidenceStore.self, from: XCTUnwrap(reopened.reaEvidence))
        XCTAssertEqual(history.records, [evidence])
        XCTAssertEqual(history.records.first?.responseJSON, evidence.responseJSON)
    }

    func testWorkspacePublicationContinuesAfter128ResultsAndPackageRetainsNewest() throws {
        let store = makeStore()
        var published: [REAResultEvidence] = []
        for _ in 0...REAResultEvidenceStore.maximumRecords {
            let evidence = try candidate(store)
            try store.publishREAResult(evidence)
            published.append(evidence)
        }
        XCTAssertEqual(store.reaResultEvidence.records, Array(published.dropFirst()))
        XCTAssertTrue(store.hasUnsavedChanges)
        let saved = try JSONEncoder().encode(store.reaResultEvidence)
        XCTAssertLessThanOrEqual(saved.count, REAResultEvidenceStore.maximumEncodedBytes)
        XCTAssertEqual(try JSONDecoder().decode(REAResultEvidenceStore.self, from: saved), store.reaResultEvidence)
    }
}
