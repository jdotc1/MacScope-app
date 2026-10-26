import Foundation
import XCTest
@testable import MacScope

final class REAInspectionResultPresentationTests: XCTestCase {
    private func data(_ operation: REAInspectionOperation, _ result: [String: Any], ok: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["ok": ok, "operation": operation.rawValue, "requestID": "accepted-request", "implementationIdentity": "verified-resource", "result": result])
    }
    func testIncompleteComparisonDoesNotDisplayEquality() throws {
        let result: [String: Any] = ["status": "unknown", "dimensions": [["source": "stdout", "status": "equal"], ["source": "exit", "status": "unknown"]]]
        let presentation = try REAInspectionResultPresentation.make(operation: .processComparison, title: "Comparison", resultData: data(.processComparison, result))
        XCTAssertEqual(presentation.summary, "Comparison is incomplete")
        XCTAssertEqual(presentation.sections[0].rows[1].status, "Unknown")
        XCTAssertEqual(presentation.provenance.first?.detail, "accepted-request")
    }
    func testComparisonShowsActualFirstDivergence() throws {
        let result: [String: Any] = ["status": "different", "dimensions": [["source": "stdout", "status": "different", "comparison": ["first_divergence": ["status": "found", "index": 2, "left": "original output", "right": "changed output"]]]]]
        let presentation = try REAInspectionResultPresentation.make(operation: .processComparison, title: "Comparison", resultData: data(.processComparison, result))
        XCTAssertEqual(presentation.summary, "Captured behavior differs")
        XCTAssertTrue(presentation.sections[0].rows[0].detail.contains("original output"))
        XCTAssertTrue(presentation.sections[0].rows[0].detail.contains("changed output"))
    }
    func testUIResolvedJoinIsPresentedAsCandidateAndCoverageSurvives() throws {
        let result: [String: Any] = ["analysis": ["documents": [], "graph": ["nodes": [["id": "selector", "name": "perform:"]], "edges": [["relation": "objc_dispatch", "resolution": "resolved", "from": "selector", "to": "native:function:0xfffffffffffffff0"]], "coverage": []]], "coverage": [["facet": "objc_metadata", "status": "partial", "reason": "loader_metadata_projection_not_exhaustive", "examined": 1, "omitted": 0]], "dispatchCandidates": [], "assetCatalogs": NSNull()]
        let presentation = try REAInspectionResultPresentation.make(operation: .uiResources, title: "UI", resultData: data(.uiResources, result))
        XCTAssertEqual(presentation.sections.first { $0.id == "handlers" }?.rows.first?.status, "Candidate handler")
        XCTAssertTrue(presentation.explanation.contains("Runtime dispatch was not observed"))
        XCTAssertTrue(presentation.coverage.contains { $0.status == "partial" })
    }
    func testConditionalNativeLoadRemainsConditional() throws {
        let result: [String: Any] = ["bundles": [], "trace": ["edges": [["install_name": "@rpath/Helper.dylib", "loader": "Main", "root": "Main", "resolution": ["status": "conditional", "image": "Helper.dylib"], "loader_conditional": true]], "coverage": ["status": "partial", "unparsed_images": [], "roots_without_architecture": []]]]
        let presentation = try REAInspectionResultPresentation.make(operation: .nativeApplication, title: "Native", resultData: data(.nativeApplication, result))
        XCTAssertEqual(presentation.sections.first { $0.id == "loads" }?.rows.first?.status, "conditional")
        XCTAssertTrue(presentation.summary.contains("gaps"))
    }
    func testFailureAndWrongOperationEnvelopesReject() throws {
        let comparison: [String: Any] = ["status": "equal", "dimensions": []]
        XCTAssertThrowsError(try REAInspectionResultPresentation.make(operation: .processComparison, title: "Invalid", resultData: data(.processComparison, comparison, ok: false)))
        XCTAssertThrowsError(try REAInspectionResultPresentation.make(operation: .uiResources, title: "Wrong operation", resultData: data(.processComparison, comparison)))
    }
}
