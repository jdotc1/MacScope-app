import Foundation
import LumenUI
import XCTest
import LumenTokens
@testable import MacScope

/// MacScope on Lumen: its built-ins inherit Lumen's themes, set only MacScope's own roles, and pass
/// every check; theme files written before U5e keep loading.
final class LumenPackCompatibilityTests: XCTestCase {

    func testLegacyTokenOrderAndRegistryCoverage() {
        XCTAssertEqual(LumenToken.allCases.count, 104)
        XCTAssertEqual(Set(LumenToken.allCases).count, 104)
        XCTAssertEqual(LumenToken.groups.flatMap(\.tokens).count, 104)
        XCTAssertTrue(LumenToken.allCases.allSatisfy { registry.contains($0) })
        XCTAssertEqual(DSBuiltInThemes.all, registry.galleryThemes)
        XCTAssertEqual(DSBuiltInThemes.all, [DSBuiltInThemes.scope, DSBuiltInThemes.midnight, DSBuiltInThemes.contrast])
    }

    func testFinalV5ListingTextAndWarningProtections() throws {
        for override: LumenPalette in [
            [.listingSecondaryText: "#00000080"],
            [.listingSecondaryText: "#FFFFFF"],
            [.statusWarningBackground: "#4A5162"],
            [.bgElevated: "#4A5162"],
        ] {
            let theme = try LumenTheme(id: "user.final-v5", name: "Final v5", inherits: MacScopeThemes.scopeID,
                                       light: override, dark: nil).flattened { self.registry.theme(id: $0) }
            let issues = LumenValidator.issues(for: theme, in: registry)
                .filter { $0.severity == .error && !$0.appearance.isDark && !$0.appearance.isHighContrast }
            XCTAssertFalse(issues.isEmpty, "\(override)")
            if override[.listingSecondaryText]?.alpha ?? 1 < 1 {
                let opacityIssues = issues.filter {
                    $0.token == .listingSecondaryText && $0.message.hasPrefix("listing.secondaryText must be opaque")
                }
                XCTAssertEqual(opacityIssues.count, 1, "Lumen's foreground rule provides the opacity guard without a duplicate custom rule")
            } else if override[.listingSecondaryText] != nil {
                XCTAssertTrue(issues.contains { $0.token == .listingSecondaryText && $0.message.contains("bg.canvas") })
            } else {
                XCTAssertTrue(issues.contains { $0.token == .fgSecondary })
            }
        }
    }
    let registry = LumenRegistry.macScope

    /// Each built-in's Lumen parent.
    let parents = [MacScopeThemes.scopeID: LumenThemes.standardID, MacScopeThemes.midnightID: LumenThemes.midnightID,
                   MacScopeThemes.contrastID: LumenThemes.contrastID]

    func testBuiltInsInheritLumenWithAppOwnedTitlebar() throws {
        let raw = [MacScopeThemes.scope, MacScopeThemes.midnight, MacScopeThemes.contrast]
            .map(MacScopeThemes.withWarmTitlebar)
        let own = Set(LumenPack.macScope.tokens.map(\.token))
        for theme in raw {
            XCTAssertEqual(theme.inherits, parents[theme.id])
            for palette in [theme.light, theme.dark, theme.lightHighContrast, theme.darkHighContrast].compactMap({ $0 }) {
                let shared = palette.colors.keys.filter { !own.contains(LumenToken($0)) && !$0.hasPrefix("syntax.") && $0 != LumenToken.Code.currentLine.rawValue
                    && $0 != LumenToken.titlebarActiveTop.rawValue && $0 != LumenToken.titlebarActiveBottom.rawValue }
                XCTAssertEqual(shared.sorted(), [], "\(theme.name) sets only MacScope's roles, syntax colors, current line and title bar")
            }
        }
        var checked = 0
        for theme in registry.galleryThemes {
            let parent = try XCTUnwrap(registry.theme(id: try XCTUnwrap(parents[theme.id])))
            let declared = try XCTUnwrap(raw.first { $0.id == theme.id })
            for appearance in LumenAppearance.all where theme.supportedAppearances.contains(appearance.isDark) {
                let palette = appearance.isHighContrast
                    ? (appearance.isDark ? declared.darkHighContrast ?? declared.dark : declared.lightHighContrast ?? declared.light)
                    : (appearance.isDark ? declared.dark : declared.light)
                for token in registry.tokens where !own.contains(token) && palette?[token] == nil {
                    checked += 1
                    XCTAssertEqual(theme.color(token, for: appearance, in: registry), parent.color(token, for: appearance, in: registry),
                                   "\(theme.name) \(appearance) \(token.rawValue) comes from \(parent.name)")
                }
                for (key, value) in palette?.colors ?? [:] {
                    XCTAssertEqual(theme.color(LumenToken(key), for: appearance, in: registry), value,
                                   "\(theme.name) \(appearance) \(key) keeps its declared value")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testMacScopeBuiltInsPassEveryCheck() {
        // The themes MacScope offers (Lumen's own are hidden but remain their parents). Midnight
        // takes Lumen Midnight's danger red since U5e, so its accent no longer doubles as a status.
        for theme in registry.galleryThemes {
            XCTAssertEqual(LumenValidator.issues(for: theme, in: registry).map { "\($0.appearance): \($0.message)" }, [], theme.name)
        }
    }

    func testTheGalleryOffersMacScopesThemesUnderTheirExistingIDs() {
        XCTAssertEqual(registry.galleryThemes.map(\.id), [MacScopeThemes.scopeID, MacScopeThemes.midnightID, MacScopeThemes.contrastID])
        XCTAssertEqual(registry.galleryThemes.map(\.name), ["Scope", "Midnight", "Contrast"])
        XCTAssertEqual(registry.defaultThemeID, MacScopeThemes.scopeID)
        let coreThemeIDs = Set(LumenPack.core.themes.map(\.id))
        XCTAssertTrue(coreThemeIDs.contains(LumenThemes.ultravioletID))
        XCTAssertEqual(Set(LumenPack.macScope.hidesThemes), coreThemeIDs)
        XCTAssertTrue(coreThemeIDs.isDisjoint(with: Set(registry.galleryThemes.map(\.id))))
        for id in coreThemeIDs {
            XCTAssertNotNil(registry.theme(id: id), "Hidden core themes remain available for inheritance")
        }
    }

    func testEditorSurfaceCarriesTheCanvasRoles() {
        XCTAssertEqual(registry.surfaces, [.window, .editor])
        for token: LumenToken in [.bgCanvas, .bgGutter, LumenToken.Code.currentLine, .syntaxKeyword, .listingSelection, .graphLaneBackground, .terminalRed] {
            XCTAssertEqual(registry.surface(of: token), .editor, token.rawValue)
        }
        for token: LumenToken in [.bgSidebar, .fgPrimary, .kindFunction, .deckBackground, .accent] {
            XCTAssertEqual(registry.surface(of: token), .window, token.rawValue)
        }
    }

    func testExistingUserThemesKeepWorking() throws {
        // A theme saved by today's MacScope theme editor.
        let saved = try JSONDecoder().decode(LumenTheme.self, from: Data(##"""
        {"id":"user.calm","name":"Calm","inherits":"com.macscope.theme.scope","light":{"accent.default":"#2F6FDE","syntax.keyword":"#8A1F6E"}}
        """##.utf8)).flattened { self.registry.theme(id: $0) }
        XCTAssertEqual(saved.color(.accent, for: .light, in: registry).hexString, "#2F6FDE")
        XCTAssertEqual(saved.color(.syntaxKeyword, for: .light, in: registry).hexString, "#8A1F6E")
        XCTAssertEqual(saved.color(.kindString, for: .dark, in: registry),
                       registry.theme(id: MacScopeThemes.scopeID)!.color(.kindString, for: .dark, in: registry))
    }

    func testThemeFilesWithRetiredKeysKeepLoading() throws {
        // Written before U5e: bg.currentLine is now Lumen's code.currentLine; graph.edge.* and
        // welcome.accent were retired without a successor and are ignored.
        let decoded = try JSONDecoder().decode(LumenTheme.self, from: Data(##"""
        {"id":"user.old","name":"Old","inherits":"com.macscope.theme.scope","light":{"bg.currentLine":"#EEF7F7","graph.edge.selected":"#6757D0","graph.edge.call":"#112233","welcome.accent":"#445566"}}
        """##.utf8))
        let theme = try registry.migratingRenamedKeys(in: decoded).flattened { self.registry.theme(id: $0) }
        let scope = try XCTUnwrap(registry.theme(id: MacScopeThemes.scopeID))
        XCTAssertEqual(theme.color(LumenToken.Code.currentLine, for: .light, in: registry).hexString, "#EEF7F7")
        XCTAssertEqual(theme.color(.listingCurrentLine, for: .light, in: registry).hexString, "#EEF7F7")
        for token: LumenToken in [.accent, .statusSuccess, .statusDanger, .fgTertiary, .fgPrimary] {
            XCTAssertEqual(theme.color(token, for: .light, in: registry), scope.color(token, for: .light, in: registry), token.rawValue)
        }
        XCTAssertEqual(LumenValidator.unknownKeyIssues(in: decoded, registry: registry).map(\.message),
                       ["“bg.currentLine” is now “code.currentLine”; it loads as that, but rename it in the file"],
                       "Retired keys load without a warning; a renamed one asks to be renamed")
    }

    func testMacScopeRulesStillCatchWhatTheyCaughtBefore() throws {
        let broken = try LumenTheme(id: "user.broken", name: "Broken", inherits: MacScopeThemes.scopeID, light: [
            .listingPatchedRow: "#E2B9A4",          // listing text unreadable on patched rows
            .kindSegment: "#0064C3",                // same as kind.function
            .syntaxType: "#A0308A",                 // same as syntax.keyword (pseudocode)
        ], dark: nil).flattened { self.registry.theme(id: $0) }
        let messages = LumenValidator.issues(for: broken, in: registry)
            .filter { !$0.appearance.isDark && !$0.appearance.isHighContrast }.map(\.message)
        XCTAssertTrue(messages.contains { $0.hasPrefix("syntax.mnemonicMemory on listing.patchedRow") }, "\(messages)")
        XCTAssertTrue(messages.contains("kind.function and kind.segment are too alike to tell kinds apart"))
        XCTAssertTrue(messages.contains("syntax.keyword and syntax.type are too alike to tell pseudocode roles apart"))
    }
}
