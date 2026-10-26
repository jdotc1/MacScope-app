import AppKit
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

final class TerminalThemePaletteTests: XCTestCase {
    private func store(_ id: String) -> DSThemeStore {
        DSThemeStore(themes: DSBuiltInThemes.all, selectedID: id, persistsSelection: false)
    }

    func testPaletteExpandsToTheStandard256ColorTable() {
        let palette = TerminalThemePalette(store: store(DSBuiltInThemes.scope.id), appearance: .dark)
        let table = palette.palette256
        XCTAssertEqual(table.count, 256)
        XCTAssertEqual(Array(table.prefix(16)), palette.ansi)
        XCTAssertEqual(table[16], .init(r: 0, g: 0, b: 0))
        XCTAssertEqual(table[231], .init(r: 255, g: 255, b: 255))
        XCTAssertEqual(table[232], .init(r: 8, g: 8, b: 8))
        XCTAssertEqual(table[255], .init(r: 238, g: 238, b: 238))
    }

    func testTerminalTextIsReadableInEveryBuiltInTheme() {
        for theme in DSBuiltInThemes.all {
            for appearance in theme.supportedColorSchemes.map({ LumenAppearance(isDark: $0 == .dark, isHighContrast: false) }) {
                let p = TerminalThemePalette(store: store(theme.id), appearance: appearance)
                let fg = LumenColor(hex: p.foreground.hex)!, bg = LumenColor(hex: p.background.hex)!
                XCTAssertGreaterThanOrEqual(fg.contrastRatio(against: bg), 7, "\(theme.name) \(appearance)")
            }
        }
    }

    func testGhosttyConfigurationIsColorOnly() {
        let config = TerminalThemePalette(store: store(DSBuiltInThemes.midnight.id), appearance: .dark).ghosttyConfiguration
        let keys = Set(config.split(separator: "\n").map { $0.split(separator: "=")[0].trimmingCharacters(in: .whitespaces) })
        XCTAssertEqual(keys, ["foreground", "background", "cursor-color", "palette"])
        XCTAssertEqual(config.split(separator: "\n").count, 19)
    }

    func testInheritedCanvasFlowsIntoTheTerminal() throws {
        let child = try JSONDecoder().decode(LumenTheme.self, from: Data(##"{"id":"u","name":"U","inherits":"com.macscope.theme.scope","dark":{"bg.canvas":"#101010"}}"##.utf8))
        let flat = try child.flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        let s = DSThemeStore(themes: DSBuiltInThemes.all + [flat], selectedID: "u", persistsSelection: false)
        XCTAssertEqual(TerminalThemePalette(store: s, appearance: .dark).background.hex, "#101010")
    }

    func testTerminalRolesBelongToTheEditorTheme() {
        XCTAssertTrue(LumenToken.terminalBackground.isEditorOwned)
        XCTAssertTrue(LumenToken.terminalANSI.allSatisfy { $0.isEditorOwned && $0.fallback != nil })
        XCTAssertEqual(LumenToken.terminalANSI.count, 16)
    }
}
