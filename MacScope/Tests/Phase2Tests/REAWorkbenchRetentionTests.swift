import Foundation
import XCTest
@testable import MacScope

@MainActor
final class REAWorkbenchRetentionTests: XCTestCase {
    private func fixture() throws -> (REAResultEvidence, REAInspectionResultPresentation) {
        let id = UUID(), hash = String(repeating: "a", count: 64)
        let authority = REAResultAuthority(workspaceID: UUID(), imageSHA256: hash, snapshotID: UUID(),
            sourceGeneration: 1, resourceSHA256: hash, implementationIdentity: hash)
        let request = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
            "operation": "nativeApplication", "input": [:]])
        let response = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
            "operation": "nativeApplication", "implementationIdentity": hash, "ok": true,
            "result": ["bundles": [], "trace": ["edges": [], "coverage": ["status": "complete"]]]])
        let evidence = try REAResultEvidence(requestID: id, operation: "nativeApplication", authority: authority,
            requestJSON: request, responseJSON: response)
        let presentation = try REAInspectionResultPresentation.make(operation: .nativeApplication,
            title: "Captured fixture", resultData: response)
        return (evidence, presentation)
    }

    func testPersistenceFailureLeavesAcceptedResultVisibleButOutsideSavedHistory() throws {
        let (evidence, presentation) = try fixture()
        var publicationCount = 0
        let controller = REAWorkbenchController(selectedBinaryURL: URL(fileURLWithPath: "/not/opened"),
            expectedSelectedSHA256: evidence.authority.imageSHA256, workspaceID: evidence.authority.workspaceID,
            makeAuthority: { _, _ in evidence.authority }, onAccepted: { _ in
                publicationCount += 1
                throw REAResultEvidenceError.bounds
            })
        controller.acceptForPresentation(evidence, presentation: presentation)
        XCTAssertEqual(publicationCount, 1)
        XCTAssertEqual(controller.presentation?.title, presentation.title)
        XCTAssertTrue(controller.history.isEmpty)
        XCTAssertTrue(controller.status.contains("not added to saved evidence"))
        XCTAssertTrue(controller.errorMessage?.contains("not available to workspace evidence citations") == true)
    }

    func testLaterSuccessfulPublicationClearsUnsavedWarning() throws {
        let (evidence, presentation) = try fixture()
        var reject = true
        let controller = REAWorkbenchController(selectedBinaryURL: URL(fileURLWithPath: "/not/opened"),
            expectedSelectedSHA256: evidence.authority.imageSHA256, workspaceID: evidence.authority.workspaceID,
            makeAuthority: { _, _ in evidence.authority }, onAccepted: { _ in
                if reject { throw REAResultEvidenceError.bounds }
            })
        controller.acceptForPresentation(evidence, presentation: presentation)
        reject = false
        controller.acceptForPresentation(evidence, presentation: presentation)
        XCTAssertEqual(controller.history, [evidence])
        XCTAssertNil(controller.errorMessage)
    }

    func testFifthAndLaterCatalogsAreCountedAsOmitted() throws {
        let root = TestWorkRoot.authority
            .appendingPathComponent("rea-catalog-retention-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Sorted traversal retains four actual regular files, then omits the remainder.
        for index in 0..<6 {
            try Data([UInt8(index)]).write(to: root.appendingPathComponent("\(index).car"))
        }
        let captured = try REAWorkbenchController.captureCatalogInputs(root)
        XCTAssertEqual(captured.captured.map(\.path), ["0.car", "1.car", "2.car", "3.car"])
        XCTAssertEqual(captured.captured.map(\.bytes), (0..<4).map { Data([UInt8($0)]) })
        XCTAssertEqual(captured.omitted, 2)
    }
}
