import XCTest
@testable import MacScope

/// The example themes in docs/design/themes/examples are what theme authors copy, so each must
/// load and pass the validator with no errors or warnings.
final class DSThemeExamplesTests: XCTestCase {
    static var examplesDirectory: URL {
        TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "../docs/design/themes/examples", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    func testEveryExampleLoadsAndPassesTheValidator() throws {
        let library = DSThemeStore.loadUserThemeLibrary(from: Self.examplesDirectory)
        XCTAssertEqual(library.problems, [], "Every example loads")
        XCTAssertGreaterThanOrEqual(library.themes.count, 2)
        for theme in library.themes {
            XCTAssertEqual(DSThemeValidator.issues(for: theme).map(\.message), [], theme.name)
        }
    }
}
