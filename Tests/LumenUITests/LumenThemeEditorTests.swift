import AppKit
import XCTest
import LumenTokens
@testable import LumenUI

final class LumenThemeEditorTests: XCTestCase {
    let registry = TestPack.registry

    func testEditorGroupsCoverEveryTokenExactlyOnceInRegistryOrder() {
        let groups = LumenThemeEditor.groups(in: registry, matching: "")
        XCTAssertEqual(groups.map(\.title), registry.groups.map(\.title))
        let grouped = groups.flatMap(\.tokens)
        XCTAssertEqual(grouped.count, registry.tokens.count)
        XCTAssertEqual(Set(grouped), Set(registry.tokens))
    }

    func testEditorFilterMatchesNamesAndGroupTitles() {
        XCTAssertEqual(LumenThemeEditor.groups(in: registry, matching: "CODE").map(\.title), ["Code"], "Case-insensitive; group title matches")
        XCTAssertEqual(LumenThemeEditor.groups(in: registry, matching: " accent.default ").flatMap(\.tokens), [.accent])
        XCTAssertEqual(LumenThemeEditor.groups(in: registry, matching: "sidebar.").flatMap(\.tokens),
                       registry.tokens.filter { $0.rawValue.hasPrefix("sidebar.") })
        XCTAssertTrue(LumenThemeEditor.groups(in: registry, matching: "no such color").isEmpty)
        XCTAssertEqual(LumenThemeEditor.groups(in: registry, matching: "", within: [TestPack.keyword, .statusInfo, .bgCanvas]).flatMap(\.tokens),
                       [.bgCanvas, .statusInfo, TestPack.keyword], "Changed only keeps registry order")
        XCTAssertEqual(LumenThemeEditor.groups(in: registry, matching: "status", within: [.statusInfo, .bgCanvas]).flatMap(\.tokens),
                       [.statusInfo], "Filter and changed-only combine")
    }

    func testOpacityIsOfferedForGroundsAndComponentRolesOnly() {
        XCTAssertTrue(LumenThemeEditor.supportsOpacity(.bgHover, in: registry))
        XCTAssertTrue(LumenThemeEditor.supportsOpacity(.sidebarRowSelected, in: registry))
        XCTAssertFalse(LumenThemeEditor.supportsOpacity(.fgPrimary, in: registry))
        XCTAssertFalse(LumenThemeEditor.supportsOpacity(.bgCanvas, in: registry), "Grounds stay opaque")
        XCTAssertFalse(LumenThemeEditor.supportsOpacity(TestPack.keyword, in: registry))
        XCTAssertFalse(LumenThemeEditor.supportsOpacity(.sidebarForeground, in: registry),
                       "A component that is text (it has contrast requirements) stays opaque")
    }

    func testEditorPreviewMatchesSavedInheritanceInEveryAppearance() throws {
        let overrides: [Bool: [LumenToken: LumenColor]] = [
            false: [.accent: "#2F6FDE", .fgSecondary: "#425570", TestPack.keyword: "#7A1F6A"],
            true: [.accent: "#7FD1FF", .bgCanvas: "#050505"],
        ]
        for base in registry.builtInThemes {
            let preview = LumenThemeLibrary.editorPreview(name: "Custom", inheriting: base, overrides: overrides)
            let saved = try LumenThemeLibrary.partialTheme(name: "Custom", inheriting: base, overrides: overrides, existingIDs: [])
                .flattened { self.registry.theme(id: $0) }
            for appearance in LumenAppearance.all {
                for token in registry.tokens {
                    XCTAssertEqual(preview.color(token, for: appearance, in: registry), saved.color(token, for: appearance, in: registry),
                                   "\(base.id): \(token.rawValue), \(appearance)")
                }
            }
            XCTAssertEqual(LumenValidator.issues(for: preview, in: registry), LumenValidator.issues(for: saved, in: registry),
                           "Save enablement must validate the colors that will actually be loaded")
        }
    }

    func testEditorSavesOnlyOverridesOnTopOfTheBase() throws {
        let midnight = try XCTUnwrap(registry.theme(id: LumenThemes.midnightID))
        let theme = LumenThemeLibrary.partialTheme(name: "Midnight Calm!", inheriting: midnight,
                                                   overrides: [true: [.accent: "#7FD1FF"]], existingIDs: ["user.midnight-calm-"])
        XCTAssertEqual(theme.id, "user.midnight-calm--2", "Collision gets a numeric suffix")
        XCTAssertEqual(theme.inherits, LumenThemes.midnightID)
        XCTAssertEqual(theme.colorSpace, .displayP3, "The base's color space is kept")
        XCTAssertNil(theme.light)
        XCTAssertEqual(theme.dark?.colors.count, 1, "Only the override is written")
        let resolved = try theme.flattened { self.registry.theme(id: $0) }
        XCTAssertEqual(resolved.color(.accent, for: .dark, in: registry).hexString, "#7FD1FF")
        XCTAssertEqual(resolved.forcedAppearanceIsDark, true)
    }

    func testEditorValidationCatchesUnreadableText() throws {
        let standard = try XCTUnwrap(registry.theme(id: LumenThemes.standardID))
        let bad = try LumenThemeLibrary.partialTheme(name: "Bad", inheriting: standard,
                                                     overrides: [false: [.fgSecondary: "#F0F0F0"]], existingIDs: [])
            .flattened { self.registry.theme(id: $0) }
        let issues = LumenValidator.issues(for: bad, in: registry).filter { !$0.appearance.isDark }
        XCTAssertTrue(issues.contains { $0.token == .fgSecondary && $0.severity == .error })
    }

    func testPickedColorsAreStoredInTheThemesColorSpace() throws {
        let picked = NSColor(displayP3Red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
        XCTAssertEqual(LumenColor(picked, in: .displayP3)?.hexString, "#CC4D33", "A P3 theme keeps the P3 components")
        let asSRGB = try XCTUnwrap(LumenColor(picked, in: .sRGB))
        XCTAssertNotEqual(asSRGB.hexString, "#CC4D33", "The same color has other components in sRGB")
        XCTAssertEqual(asSRGB.nsColor(in: .sRGB).usingColorSpace(.displayP3)?.redComponent ?? 0, 0.8, accuracy: 0.01,
                       "Each space round-trips to the same color")
    }

    func testSurfaceTitlesReadAsWords() {
        XCTAssertEqual(LumenThemeGallery.title(for: LumenSurface("editor")), "Editor")
        XCTAssertEqual(LumenThemeGallery.title(for: LumenSurface("documentCanvas")), "Document canvas")
        XCTAssertEqual(LumenThemeGallery.title(for: LumenSurface("code-editor")), "Code editor")
    }
}
