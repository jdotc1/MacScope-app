import AppKit
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

final class DSIconTests: XCTestCase {
    func testEveryKindSymbolExistsOnThisSystem() {
        for kind in DSObjectKind.allCases {
            XCTAssertTrue(
                LumenGlyph.named(kind.symbol) != nil
                    || NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil,
                "\(kind): \(kind.symbol)"
            )
        }
    }

    func testEditorAndWorkspaceSymbolsExist() {
        let names = EditorMode.allCases.map(\.systemImage) + WorkspaceTool.allCases.map(\.systemImage)
        for name in names {
            XCTAssertTrue(
                LumenGlyph.named(name) != nil
                    || NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                name
            )
        }
    }

    @MainActor
    func testNativeGlyphsProduceTemplateImages() throws {
        let names = Set(DSObjectKind.allCases.map(\.symbol) + EditorMode.allCases.map(\.systemImage))
            .filter { $0.hasPrefix("lumen.") }
            .union(["lumen.entryPoint", "lumen.patchedBytes"])
        for name in names {
            let glyph = try XCTUnwrap(LumenGlyph.named(name), name)
            let image = try XCTUnwrap(glyph.templateImage(size: 16), name)
            XCTAssertTrue(image.isTemplate, name)
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16), name)
        }
    }

    func testKindColorsAreLegibleGraphicsInEveryTheme() {
        // WCAG 2.x non-text contrast: icons need 3:1 against what they sit on.
        for theme in DSBuiltInThemes.all {
            for scheme in theme.supportedColorSchemes {
                let appearance = LumenAppearance(isDark: scheme == .dark, isHighContrast: false)
                for sidebar in [LumenToken.bgSidebar, .bgCanvas] {
                    let ground = theme.hex(sidebar, for: appearance)
                    for kind in DSObjectKind.allCases {
                        let ratio = theme.hex(kind.token, for: appearance).contrastRatio(against: ground)
                        XCTAssertGreaterThanOrEqual(ratio, 3, "\(theme.name) \(scheme) \(kind) on \(sidebar.rawValue): \(ratio)")
                    }
                }
            }
        }
    }

    func testKindColorsAreDistinctInEveryTheme() {
        // Kinds sit side by side in the navigator, so no two may read as the same color.
        for theme in DSBuiltInThemes.all {
            for scheme in theme.supportedColorSchemes {
                for isHighContrast in [false, true] {
                    let appearance = LumenAppearance(isDark: scheme == .dark, isHighContrast: isHighContrast)
                    let kinds = DSThemeValidator.kindTokens
                    for (i, a) in kinds.enumerated() {
                        for b in kinds[(i + 1)...] {
                            let distance = theme.hex(a, for: appearance).perceptualDistance(to: theme.hex(b, for: appearance))
                            XCTAssertGreaterThanOrEqual(distance, DSThemeValidator.kindSeparation,
                                                        "\(theme.name) \(appearance) \(a.rawValue) vs \(b.rawValue)")
                        }
                    }
                }
            }
        }
    }

    func testPerceptualDistanceMatchesOKLabReference() {
        // Pure white is L = 1 in OKLab; black is 0; identical colors are 0 apart.
        XCTAssertEqual(LumenColor(hex: "#FFFFFF")!.oklab.l, 1, accuracy: 1e-4)
        XCTAssertEqual(LumenColor(hex: "#000000")!.perceptualDistance(to: "#FFFFFF"), 1, accuracy: 1e-4)
        XCTAssertEqual(LumenColor(hex: "#6E5DDD")!.perceptualDistance(to: "#6E5DDD"), 0)
    }

    func testCompositingMatchesAlphaBlending() {
        let tile = LumenColor(hex: "#0064C3")!.composited(alpha: 0.16, over: "#F6F6F8")
        XCTAssertEqual(tile.hexString, "#CFDFF0", "kind.function's badge tile over the Scope Light sidebar")
        XCTAssertEqual(LumenColor(hex: "#123456")!.composited(alpha: 1, over: "#FFFFFF").hexString, "#123456")
    }

    func testBadgeGlyphsStayLegibleOnTheirTilesInEveryTheme() {
        for theme in DSBuiltInThemes.all {
            let messages = DSThemeValidator.issues(for: theme).map(\.message).filter { $0.contains("badge glyph") }
            XCTAssertEqual(messages, [], theme.name)
        }
    }

    func testSidebarItemKindsComeFromTheirIDPrefix() {
        XCTAssertEqual(DSObjectKind.forSidebarItemID("function:1234"), .function)
        XCTAssertEqual(DSObjectKind.forSidebarItemID("xref:abc"), .xref)
        XCTAssertEqual(DSObjectKind.forSidebarItemID("binary:x"), .image)
        XCTAssertNil(DSObjectKind.forSidebarItemID("section:Functions"), "section: marks headers, not Mach-O sections")
        XCTAssertNil(DSObjectKind.forSidebarItemID("debug:threads"))
        XCTAssertNil(DSObjectKind.forSidebarItemID("no-prefix"))
    }
}
