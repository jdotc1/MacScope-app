import AppKit
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

final class PluginThemeSnapshotTests: XCTestCase {
    private func store(window: String, editor: String? = nil) -> DSThemeStore {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: window, persistsSelection: false)
        store.selectEditorTheme(editor)
        return store
    }

    func testSnapshotCarriesEveryRoleAndTheScales() {
        let snapshot = PluginThemeSnapshot(store: store(window: DSBuiltInThemes.scope.id), appearance: .dark)
        XCTAssertEqual(snapshot.colors.count, 110, "Plugins keep every key they had before U5e")
        XCTAssertEqual(Set(snapshot.colors.keys), Set(PluginThemeSnapshot.roleKeys.map(\.key)))
        XCTAssertFalse(snapshot.colors.keys.contains(LumenToken.Code.currentLine.rawValue))
        // Retired roles carry what the app draws in their place.
        XCTAssertEqual(snapshot.colors["graph.edge.call"], snapshot.colors["accent.default"])
        XCTAssertEqual(snapshot.colors["graph.edge.branch"], snapshot.colors["status.success"])
        XCTAssertEqual(snapshot.colors["graph.edge.fallthrough"], snapshot.colors["status.danger"])
        XCTAssertEqual(snapshot.colors["graph.edge.selected"], snapshot.colors["fg.primary"])
        XCTAssertNotNil(snapshot.colors["bg.currentLine"])
        XCTAssertEqual(snapshot.appearance, "dark")
        XCTAssertEqual(snapshot.spacing["s6"], 16)
        XCTAssertEqual(snapshot.radii["lg"], 10)
        XCTAssertEqual(snapshot.schemaVersion, PluginThemeSnapshot.currentSchemaVersion)
    }

    func testEditorRolesComeFromTheEditorTheme() {
        let snapshot = PluginThemeSnapshot(
            store: store(window: DSBuiltInThemes.scope.id, editor: DSBuiltInThemes.midnight.id),
            appearance: .dark
        )
        XCTAssertEqual(snapshot.editorThemeID, DSBuiltInThemes.midnight.id)
        // Midnight is authored in Display P3; snapshots carry sRGB, so #080F24 (P3) arrives
        // converted.
        let midnightCanvas = DSBuiltInThemes.midnight.nsColor(.bgCanvas, for: .dark).usingColorSpace(.sRGB)!
        XCTAssertEqual(snapshot.color("bg.canvas"), Self.hex(midnightCanvas))
        XCTAssertNotEqual(snapshot.color("bg.canvas"), DSBuiltInThemes.scope.hex(.bgCanvas, for: .dark).hexString)
        XCTAssertEqual(snapshot.color("bg.sidebar"), DSBuiltInThemes.scope.hex(.bgSidebar, for: .dark).hexString)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        let snapshot = PluginThemeSnapshot(store: store(window: DSBuiltInThemes.contrast.id), appearance: .light)
        let decoded = try JSONDecoder().decode(PluginThemeSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.color("fg.primary"), "#000000")
    }

    private static func hex(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
