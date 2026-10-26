import Foundation
import XCTest
@testable import MacScope

final class DSLumenPreferencesTests: XCTestCase {
    func testLegacyChoicesAreCopiedOnceWithoutReplacingExistingLumenValues() throws {
        let suite = "MacScope.LumenMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("com.macscope.theme.midnight", forKey: "dsThemeIdentifier")
        defaults.set("com.macscope.theme.contrast", forKey: "dsEditorThemeIdentifier")
        defaults.set(true, forKey: "dsUsesSystemAccent")
        defaults.set("compact", forKey: "dsDensity")
        defaults.set(false, forKey: "MacScope.lumen.usesSystemAccent")
        defaults.set("comfortable", forKey: "MacScope.lumen.density")

        DSLumenPreferences.migrate(defaults)

        XCTAssertEqual(defaults.string(forKey: "MacScope.lumen.theme"), "com.macscope.theme.midnight")
        XCTAssertEqual(defaults.string(forKey: "MacScope.lumen.theme.editor"), "com.macscope.theme.contrast")
        XCTAssertFalse(defaults.bool(forKey: "MacScope.lumen.usesSystemAccent"))
        XCTAssertEqual(defaults.string(forKey: "MacScope.lumen.density"), "comfortable")
        XCTAssertEqual(defaults.string(forKey: "dsThemeIdentifier"), "com.macscope.theme.midnight")
        XCTAssertTrue(defaults.bool(forKey: "dsUsesSystemAccent"))

        defaults.removeObject(forKey: "MacScope.lumen.theme.editor")
        defaults.set("com.macscope.theme.scope", forKey: "dsThemeIdentifier")
        DSLumenPreferences.migrate(defaults)
        XCTAssertNil(defaults.object(forKey: "MacScope.lumen.theme.editor"), "Follow-window selection must stay cleared")
        XCTAssertEqual(defaults.string(forKey: "MacScope.lumen.theme"), "com.macscope.theme.midnight")
    }

    func testMissingLegacyPreferencesDoNotCreateSelections() throws {
        let suite = "MacScope.LumenMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DSLumenPreferences.migrate(defaults)
        for key in ["MacScope.lumen.theme", "MacScope.lumen.theme.editor", "MacScope.lumen.usesSystemAccent", "MacScope.lumen.density"] {
            XCTAssertNil(defaults.object(forKey: key))
        }
    }
}
