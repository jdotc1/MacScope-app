import XCTest
import SwiftUI
import LumenTokens
@testable import LumenUI

@MainActor final class LumenIdentifierTests: XCTestCase {
    func testSidebarItemCarriesItsIdentifier() {
        let item = LumenSidebarItem(id: "project", title: "Project", systemImage: "folder", accessibilityIdentifier: "workspace.tool.project")
        XCTAssertEqual(item.accessibilityIdentifier, "workspace.tool.project")
        XCTAssertNil(LumenSidebarItem(id: "project", title: "Project", systemImage: "folder").accessibilityIdentifier)
    }

    func testBarActionCarriesItsIdentifier() {
        let action = LumenBarAction("Open Binary…", accessibilityIdentifier: "workspace.empty.open-binary") {}
        XCTAssertEqual(action.accessibilityIdentifier, "workspace.empty.open-binary")
        XCTAssertNil(LumenBarAction("Open") {}.accessibilityIdentifier)
    }

    func testHeroRendersWithIdentifiersAndNoDefaultAction() throws {
        let hero = LumenEmptyHero("No binary open", systemImage: "cpu",
                                  primary: LumenBarAction("Open Binary…", accessibilityIdentifier: "workspace.empty.open-binary") {},
                                  recents: [], primaryIsDefault: false,
                                  identifiers: (container: "workspace.empty.scroll", recents: "workspace.empty.recents"))
        let variant = LumenSnapshot.Variant.all(for: LumenRegistry.core.galleryThemes)[0]
        XCTAssertNotNil(LumenSnapshot.png(of: hero, size: CGSize(width: 480, height: 360), variant: variant, registry: .core))
    }

    func testActionHelpAndStatusSpeech() {
        let action = LumenBarAction("Refresh", systemImage: "arrow.clockwise", help: "Decompile again", accessibilityIdentifier: "native.refresh") {}
        XCTAssertEqual(action.help, "Decompile again")
        XCTAssertEqual(action.accessibilityIdentifier, "native.refresh")
        let status = LumenStripStatus("Ready", tone: .statusSuccess, spokenLabel: "Decompiler ready", spokenValue: "12 functions",
                                      accessibilityIdentifier: "native.status")
        XCTAssertEqual(status.spokenLabel, "Decompiler ready")
        XCTAssertEqual(status.accessibilityIdentifier, "native.status")
        XCTAssertNil(LumenStripStatus("Ready", tone: .statusSuccess).accessibilityIdentifier)
    }

    func testSheetAndReadOnlyConsoleRender() {
        let variant = LumenSnapshot.Variant.all(for: LumenRegistry.core.galleryThemes)[0]
        let sheet = LumenSheet("Edit Breakpoint", systemImage: "pause.circle", cancelAccessibilityIdentifier: "editor.cancel", onCancel: {},
                               primary: LumenBarAction("Save", accessibilityIdentifier: "editor.save") {}) { Text("Body") }
        XCTAssertNotNil(LumenSnapshot.png(of: sheet, size: CGSize(width: 420, height: 240), variant: variant, registry: .core))
        let console = LumenConsole(lines: [LumenConsoleLine(.stop, "Stopped at main")])
        XCTAssertNotNil(LumenSnapshot.png(of: console, size: CGSize(width: 420, height: 160), variant: variant, registry: .core))
    }
}
