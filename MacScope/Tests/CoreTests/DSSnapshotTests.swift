import Foundation
import XCTest
@testable import MacScope

/// Golden-image tests for design-system components in every built-in theme variant. Rendering
/// uses a throwaway store, so the user's theme selection is never touched. To re-record after an
/// intentional visual change: `DS_RECORD_SNAPSHOTS=1` (or `Scripts/design/record_snapshots.sh`).
@MainActor
final class DSSnapshotTests: XCTestCase {
    static var goldenDirectory: URL {
        TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent()   // CoreTests
            .deletingLastPathComponent()   // Tests
            .appending(path: "Fixtures/DSSnapshots", directoryHint: .isDirectory)
    }

    func testComponentsMatchTheirGoldenImagesInEveryTheme() throws {
        let record = ProcessInfo.processInfo.environment["DS_RECORD_SNAPSHOTS"] == "1"
        try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
        var recorded = 0
        for subject in DSSnapshot.subjects {
            for variant in subject.variants {
                let name = "\(subject.name)@\(variant.label).png"
                let url = Self.goldenDirectory.appending(path: name)
                let rendered = try XCTUnwrap(DSSnapshot.png(of: subject, in: variant), "render \(name)")
                if record {
                    try rendered.write(to: url)
                    recorded += 1
                    continue
                }
                guard let golden = try? Data(contentsOf: url) else {
                    XCTFail("Missing golden \(name); run with DS_RECORD_SNAPSHOTS=1")
                    continue
                }
                let difference = DSSnapshot.compare(rendered, golden)
                XCTAssertFalse(difference.sizeMismatch, "\(name): \(difference)")
                XCTAssertLessThanOrEqual(difference.differingPixelFraction, 0.005, "\(name): \(difference)")
            }
        }
        // Recording is never a pass: a run with DS_RECORD_SNAPSHOTS=1 left on in CI would
        // otherwise rewrite every golden and report green.
        if record {
            XCTFail("Recorded \(recorded) golden images; review them, then run again without DS_RECORD_SNAPSHOTS")
        }
    }

    func testSnapshotRenderingNeverChangesTheUsersSelection() throws {
        let appDomainBefore = NSDictionary(dictionary:
            UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:])
        defer {
            XCTAssertTrue(appDomainBefore.isEqual(to:
                UserDefaults.standard.persistentDomain(forName: "org.macscope.app") ?? [:]))
        }
        DSThemeStore.$sharedOverride.withValue(DSThemeStore(persistsSelection: false)) {
            let before = DSThemeStore.shared.theme.id
            _ = DSSnapshot.png(of: DSSnapshot.subjects[0], in: DSSnapshot.Variant.all[2])
            XCTAssertEqual(DSThemeStore.shared.theme.id, before)
            XCTAssertTrue(DSThemeStore.active === DSThemeStore.shared, "The scoped override is removed afterwards")
        }
    }

    func testListingRenderingDoesNotChangeWhenOnlyTheWindowThemeChanges() throws {
        let subject = try XCTUnwrap(DSSnapshot.subjects.first { $0.name == "listing-rows" })
        let editorOnly = DSSnapshot.Variant(themeID: DSBuiltInThemes.scope.id, colorScheme: .dark)
        let split = DSSnapshot.Variant(themeID: DSBuiltInThemes.midnight.id, colorScheme: .dark,
                                       editorThemeID: DSBuiltInThemes.scope.id)
        let expected = try XCTUnwrap(DSSnapshot.png(of: subject, in: editorOnly))
        let actual = try XCTUnwrap(DSSnapshot.png(of: subject, in: split))
        let difference = DSSnapshot.compare(actual, expected)
        XCTAssertFalse(difference.sizeMismatch, "\(difference)")
        XCTAssertEqual(difference.differingPixelFraction, 0,
                       "Every listing row, including selected text, belongs to the editor theme: \(difference)")
    }
}
