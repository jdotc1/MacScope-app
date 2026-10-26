import XCTest
@testable import MacScope

/// File › Export All Pseudocode with the Native or Compare source asks which provider to export
/// (native first, MacScope second); MacScope runs directly without asking.
final class AllPseudocodeExportPromptTests: XCTestCase {
    func testMacScopeSourceExportsWithoutAsking() {
        XCTAssertNil(AllPseudocodeExportPrompt.prompt(for: .macScope))
    }

    func testNativeAndCompareSourcesOfferNativeFirstThenMacScope() throws {
        for source in [PseudocodeSource.native, .compare] {
            let prompt = try XCTUnwrap(AllPseudocodeExportPrompt.prompt(for: source), source.rawValue)
            XCTAssertEqual(prompt.nativeTitle, "Export Native Pseudocode")
            XCTAssertEqual(prompt.macScopeTitle, "Export MacScope Pseudocode")
            XCTAssertTrue(prompt.message.contains("not filled in with MacScope pseudocode"), prompt.message)
            XCTAssertEqual(prompt.message.contains("File › Export Pseudocode"), source == .compare, prompt.message)
            XCTAssertFalse(prompt.title.contains("Failed"))
        }
    }
}
