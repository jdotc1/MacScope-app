import XCTest
import LumenTokens
import LumenUI
@testable import MacScope

/// The published token files are generated from the Swift source of truth. If this fails, run
/// `Scripts/design/export_tokens.sh` and commit the regenerated `docs/design/tokens/*`.
final class DSTokenExportTests: XCTestCase {
    private var tokensDirectory: URL {
        TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()   // CoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MacScope
            .deletingLastPathComponent()   // repository root
            .appending(path: "docs/design/tokens", directoryHint: .isDirectory)
    }

    private func committed(_ name: String) throws -> String {
        try String(contentsOf: tokensDirectory.appending(path: name), encoding: .utf8)
    }

    func testBuiltInThemesJSONMatchesTheCode() throws {
        XCTAssertEqual(try committed(DSTokenExport.fileNames.themes), try DSTokenExport.builtInThemesJSON(),
                       "Run Scripts/design/export_tokens.sh")
    }

    func testThemeSchemaMatchesTheCode() throws {
        XCTAssertEqual(try committed(DSTokenExport.fileNames.schema), try DSTokenExport.themeSchemaJSON(),
                       "Run Scripts/design/export_tokens.sh")
    }

    func testTokenReferenceMatchesTheCode() throws {
        XCTAssertEqual(try committed(DSTokenExport.fileNames.reference), DSTokenExport.tokenReferenceMarkdown(),
                       "Run Scripts/design/export_tokens.sh")
    }

    func testPublishedThemesDecodeBackToTheBuiltIns() throws {
        let data = Data(try committed(DSTokenExport.fileNames.themes).utf8)
        XCTAssertEqual(try JSONDecoder().decode([LumenTheme].self, from: data), DSBuiltInThemes.all)
    }
}
