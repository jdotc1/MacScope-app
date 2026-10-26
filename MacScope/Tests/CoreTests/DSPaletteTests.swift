import AppKit
import SwiftUI
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

final class DSPaletteTests: XCTestCase {
    private func srgb(_ color: Color, in appearance: NSAppearance.Name) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return resolved
    }

    func testPaletteResolvesTheSameColorsAsTheStore() throws {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.scope.id, persistsSelection: false)
        store.selectEditorTheme(DSBuiltInThemes.midnight.id)
        let palette = store.resolvedPalette()
        for token in LumenToken.allCases {
            let fromPalette = try XCTUnwrap(srgb(palette[token], in: .darkAqua))
            let fromStore = try XCTUnwrap(srgb(store.color(token), in: .darkAqua))
            XCTAssertEqual(fromPalette.redComponent, fromStore.redComponent, accuracy: 0.002, token.rawValue)
            XCTAssertEqual(fromPalette.blueComponent, fromStore.blueComponent, accuracy: 0.002, token.rawValue)
        }
        let canvas = try XCTUnwrap(srgb(palette[.bgCanvas], in: .darkAqua))
        XCTAssertGreaterThan(canvas.blueComponent - canvas.redComponent, 0.08, "Editor-owned roles come from Midnight")
    }

    func testPaletteIdentityFollowsTheSelectionOnly() {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.scope.id, persistsSelection: false)
        let first = store.resolvedPalette()
        XCTAssertEqual(first, store.resolvedPalette(), "Same selection, same palette")
        store.select(DSBuiltInThemes.contrast.id)
        XCTAssertNotEqual(first, store.resolvedPalette())
        store.select(DSBuiltInThemes.scope.id)
        XCTAssertEqual(first, store.resolvedPalette())
        store.setUsesSystemAccent(true)
        XCTAssertNotEqual(first, store.resolvedPalette(), "System accent changes the palette")
    }

    func testSameThemeIDsInIndependentStoresDoNotShareResolvedColors() throws {
        var firstTheme = DSBuiltInThemes.scope
        firstTheme.id = "user.palette-isolation"
        firstTheme.light = firstTheme.light?.merging([.fgPrimary: "#123456"])
        var secondTheme = firstTheme
        secondTheme.light = secondTheme.light?.merging([.fgPrimary: "#ABCDEF"])
        let firstStore = DSThemeStore(themes: [firstTheme], selectedID: firstTheme.id, persistsSelection: false)
        let secondStore = DSThemeStore(themes: [secondTheme], selectedID: secondTheme.id, persistsSelection: false)

        // Prime the shared cache with identical IDs and revision zero, then ask another library.
        let first = firstStore.resolvedPalette()
        let second = secondStore.resolvedPalette()
        XCTAssertNotEqual(first, second, "Environment equality must also distinguish the stores")
        let firstColor = try XCTUnwrap(srgb(first[.fgPrimary], in: .aqua))
        let secondColor = try XCTUnwrap(srgb(second[.fgPrimary], in: .aqua))
        XCTAssertEqual(firstColor.redComponent, 0x12 / 255.0, accuracy: 0.002)
        XCTAssertEqual(secondColor.redComponent, 0xAB / 255.0, accuracy: 0.002)
        XCTAssertEqual(first, firstStore.resolvedPalette(), "One store still reuses its palette")
    }

    func testEditorSelectionUsesOneThemeWhenWindowAndEditorHaveOppositeAppearances() throws {
        var light = DSBuiltInThemes.scope
        light.id = "user.light-only"
        light.dark = nil
        light.darkHighContrast = nil
        let dark = DSBuiltInThemes.midnight
        let combinations: [(LumenTheme, LumenTheme, NSAppearance.Name)] = [
            (light, dark, .darkAqua),
            (dark, light, .aqua),
        ]
        for (window, editor, appearance) in combinations {
            let store = DSThemeStore(themes: [window, editor], selectedID: window.id, persistsSelection: false)
            store.selectEditorTheme(editor.id)
            try DSThemeStore.withActiveStore(store) {
                func hex(_ color: Color) throws -> LumenColor {
                    let resolved = try XCTUnwrap(srgb(color, in: appearance))
                    return LumenColor(red: resolved.redComponent, green: resolved.greenComponent,
                                      blue: resolved.blueComponent, alpha: resolved.alphaComponent)
                }
                let variant = LumenAppearance(isDark: appearance == .darkAqua, isHighContrast: false)
                // Midnight stores Display-P3 components. Compare the independent theme lookup
                // through the same sRGB conversion as the rendered Color, never raw theme hex.
                func expected(_ token: LumenToken, from theme: LumenTheme) throws -> LumenColor {
                    try hex(Color(nsColor: theme.nsColor(token, for: variant)))
                }
                let editorForeground = try expected(.fgPrimary, from: editor)
                let windowForeground = try expected(.fgPrimary, from: window)
                XCTAssertNotEqual(editorForeground.hexString, windowForeground.hexString,
                                  "These fixtures must distinguish editor routing from window routing")
                for active in [true, false] {
                    let text = try hex(AppInteractionChrome.selectedPrimaryForeground(
                        isActiveWindow: active, editorSurface: true))
                    let background = try hex(AppInteractionChrome.listingSelectionFill(isActiveWindow: active))
                    XCTAssertEqual(text.hexString, editorForeground.hexString)
                    XCTAssertEqual(background.hexString,
                                   try expected(active ? .listingSelection : .bgSelectedInactive, from: editor).hexString)
                    XCTAssertGreaterThanOrEqual(text.contrastRatio(against: background), 7,
                                                "\(window.id) window / \(editor.id) editor, active=\(active)")
                    if active {
                        XCTAssertLessThan(windowForeground.contrastRatio(against: background), 4.5,
                                          "The pre-fix window foreground must remain unreadable on this editor selection")
                    }
                }
                let addressText = try hex(DS.editorColor(.fgTertiary))
                XCTAssertEqual(addressText.hexString, try expected(.fgTertiary, from: editor).hexString)
                let canvas = try hex(Color.lumen(.bgCanvas))
                XCTAssertGreaterThanOrEqual(addressText.contrastRatio(against: canvas), 4.5)
                // Contextual resolution must not recolor window chrome or sidebar selections.
                let windowText = try hex(AppInteractionChrome.selectedPrimaryForeground(isActiveWindow: true))
                XCTAssertEqual(windowText.hexString, windowForeground.hexString)
                XCTAssertEqual(try hex(Color.lumen(.fgPrimary)).hexString, windowText.hexString)
                XCTAssertEqual(store.theme.id, window.id)
                XCTAssertEqual(store.editorTheme.id, editor.id)
            }
        }
    }
}
