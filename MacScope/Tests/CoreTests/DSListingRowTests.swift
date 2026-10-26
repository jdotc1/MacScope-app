import AppKit
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

/// Listing row backgrounds (alternate, program counter, patched) are opaque component tokens
/// that default to the translucent tints they replaced.
final class DSListingRowTests: XCTestCase {
    private let rows: [LumenToken] = [.listingAlternateRow, .listingProgramCounterRow, .listingPatchedRow]

    func testThemesWithoutTheTokensKeepTheTintedLook() {
        let bare = LumenTheme(id: "user.bare", name: "Bare", summary: "", light: [
            .bgCanvas: "#FFFFFF", .bgHover: "#E9EBF0",
            .debugProgramCounter: "#8A6200", .debugPatched: "#A9480F",
        ], dark: nil)
        XCTAssertEqual(bare.hex(.listingAlternateRow, for: .light).hexString, "#F7F8FA", "bg.hover at 35% over the canvas")
        XCTAssertEqual(bare.hex(.listingProgramCounterRow, for: .light).hexString, "#ECE6D6", "debug.programCounter at 16%")
        XCTAssertEqual(bare.hex(.listingPatchedRow, for: .light).hexString, "#F0DED4", "debug.patched at 18%")
    }

    func testBuiltInRowsMatchTheTintsTheyReplaced() {
        for theme in DSBuiltInThemes.all {
            for scheme in theme.supportedColorSchemes {
                for isHighContrast in [false, true] {
                    let appearance = LumenAppearance(isDark: scheme == .dark, isHighContrast: isHighContrast)
                    for row in rows {
                        let (alpha, over) = row.derivedFallback!
                        let tint = theme.hex(row.fallback!, for: appearance)
                            .composited(alpha: alpha, over: theme.hex(over, for: appearance))
                        XCTAssertEqual(theme.hex(row, for: appearance).hexString, tint.hexString,
                                       "\(theme.name) \(appearance) \(row.rawValue)")
                    }
                }
            }
        }
    }

    func testValidatorChecksListingTextOnEveryRow() throws {
        let heavy = try DSThemeStore.partialTheme(
            name: "Heavy patch", inheriting: DSBuiltInThemes.scope,
            overrides: [false: [.listingPatchedRow: "#E2B9A4"]], existingIDs: []
        ).flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        let issues = DSThemeValidator.issues(for: heavy).filter { !$0.appearance.isDark && !$0.appearance.isHighContrast }
        XCTAssertTrue(issues.contains { $0.message.hasPrefix("syntax.mnemonicMemory on listing.patchedRow") && $0.severity == .error })
    }

    func testListingAddressesComeFromTheEditorTheme() {
        // Addresses and bytes sit on editor-owned rows, so they must come from the same theme.
        XCTAssertTrue(LumenToken.listingSecondaryText.isEditorOwned)
        XCTAssertEqual(LumenToken.listingSecondaryText.fallback, .fgTertiary)
        XCTAssertTrue(DSThemeValidator.listingTextTokens.contains(.listingSecondaryText))
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.midnight.id, persistsSelection: false)
        store.selectEditorTheme(DSBuiltInThemes.scope.id)
        XCTAssertEqual(store.paletteKey().editorThemeID, DSBuiltInThemes.scope.id)
        // Resolved in dark (Midnight forces the app dark), it is Scope's value, not Midnight's.
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            resolved = store.nsColor(.listingSecondaryText).usingColorSpace(.sRGB)
        }
        let expected = DSBuiltInThemes.scope.hex(.fgTertiary, for: .dark)
        XCTAssertEqual(resolved.map { LumenColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent, alpha: 1).hexString },
                       expected.hexString)
        XCTAssertNotEqual(expected, DSBuiltInThemes.midnight.hex(.fgTertiary, for: .dark))
    }

    func testDocsDescribeTheDerivedDefault() {
        XCTAssertEqual(LumenToken.listingPatchedRow.fallbackDescription, "debug.patched at 18% over bg.canvas")
        XCTAssertEqual(LumenToken.sidebarRowHover.fallbackDescription, "bg.hover")
        XCTAssertNil(LumenToken.bgCanvas.fallbackDescription)
    }

    func testValidatorChecksListingSecondaryTextOnPlainCanvas() throws {
        let theme = try DSThemeStore.partialTheme(
            name: "Unreadable plain row", inheriting: DSBuiltInThemes.scope,
            overrides: [false: [.listingSecondaryText: "#FFFFFF"]], existingIDs: []
        ).flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        XCTAssertTrue(DSThemeValidator.issues(for: theme).contains {
            $0.token == .listingSecondaryText && $0.appearance == .light
                && $0.severity == .error && $0.message.contains("canvas")
        })
    }

    func testValidatorRejectsTransparentListingTextImportedFromJSON() throws {
        let theme = try DSThemeStore.decodeTheme(Data(##"{"id":"user.invisible","name":"Invisible","inherits":"com.macscope.theme.scope","light":{"listing.secondaryText":"#00000000"}}"##.utf8))
            .flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        XCTAssertTrue(DSThemeValidator.issues(for: theme).contains {
            $0.token == .listingSecondaryText && $0.appearance == .light && $0.severity == .error
        }, "Transparent black has high RGB contrast but renders no readable text")
    }
}
