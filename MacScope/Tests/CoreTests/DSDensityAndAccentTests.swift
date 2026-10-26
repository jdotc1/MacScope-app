import AppKit
import SwiftUI
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

final class DSDensityAndAccentTests: XCTestCase {
    func testRegularDensityReproducesTheShippedMetrics() {
        XCTAssertEqual(LumenDensity.regular.sidebarRowHeight, AppSidebarChrome.rowCompactMinHeight)
        XCTAssertEqual(LumenDensity.regular.sidebarDetailedRowHeight, AppSidebarChrome.rowDetailedMinHeight)
        XCTAssertEqual(LumenDensity.regular.sidebarVerticalPadding(detailed: false), AppSidebarChrome.rowCompactVerticalPadding)
        XCTAssertEqual(LumenDensity.regular.listingRowHeight, AppEditorChrome.disassemblyRowHeight)
        XCTAssertEqual(DS.Layout.rowHeightRegular, AppSidebarChrome.rowCompactMinHeight,
                       "The layout token and the shipped navigator row agree")
        XCTAssertEqual(DS.Layout.rowHeightRegular, AppEditorChrome.disassemblyRowHeight,
                       "The layout token and the shipped listing row agree")
        XCTAssertEqual(LumenDensity.resolve("nonsense"), .regular)
    }

    func testDensityOrdersFromCompactToComfortable() {
        let heights = LumenDensity.allCases.map(\.sidebarRowHeight)
        XCTAssertEqual(heights, heights.sorted())
        XCTAssertGreaterThanOrEqual(LumenDensity.compact.sidebarRowHeight, 22, "Rows stay at or above a usable hit target")
    }

    private func srgb(_ color: NSColor) -> NSColor? {
        var resolved: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        return resolved
    }

    func testSystemAccentMappingFollowsSystemSettings() {
        XCTAssertNil(LumenSystemAccent.color(forAppleAccentColor: nil), "Absent key is Multicolor")
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: -1), .systemGray)
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: 0), .systemRed)
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: 4), .systemBlue)
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: 6), .systemPink)
    }

    func testSystemAccentFollowsTheMacAndKeepsTextOnItReadable() throws {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.midnight.id, persistsSelection: false)
        let expectedThemeAccent = try XCTUnwrap(srgb(DSBuiltInThemes.midnight.nsColor(.accent, for: .light)))
        store.setUsesSystemAccent(true)
        let accent = try XCTUnwrap(srgb(store.nsColor(.accent)))
        if let system = LumenSystemAccent.current() {
            let expected = try XCTUnwrap(srgb(system))
            XCTAssertEqual(accent.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(accent.greenComponent, expected.greenComponent, accuracy: 0.01)
        } else {
            XCTAssertEqual(accent.redComponent, expectedThemeAccent.redComponent, accuracy: 0.01, "Multicolor keeps the theme accent")
            XCTAssertEqual(accent.greenComponent, expectedThemeAccent.greenComponent, accuracy: 0.01)
            XCTAssertEqual(accent.blueComponent, expectedThemeAccent.blueComponent, accuracy: 0.01)
        }

        let onAccent = try XCTUnwrap(srgb(store.nsColor(.fgOnAccent)))
        func hex(_ c: NSColor) -> LumenColor { LumenColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1) }
        XCTAssertGreaterThanOrEqual(hex(onAccent).contrastRatio(against: hex(accent)), 4.5)

        store.setUsesSystemAccent(false)
        let themed = try XCTUnwrap(srgb(store.nsColor(.accent)))
        XCTAssertEqual(themed.redComponent, expectedThemeAccent.redComponent, accuracy: 0.01, "Back to Midnight's own accent")
        XCTAssertEqual(themed.greenComponent, expectedThemeAccent.greenComponent, accuracy: 0.01)
        XCTAssertEqual(themed.blueComponent, expectedThemeAccent.blueComponent, accuracy: 0.01)
        XCTAssertFalse(LumenToken.bgCanvas.followsSystemAccent)
    }
}
