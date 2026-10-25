import Foundation
import XCTest
import LumenConformance
import LumenTokens
@testable import MacScopeTheme

/// MacScopeTheme resolves exactly the colors recorded in `macscope-expected.json` (every theme ×
/// appearance × token), and its built-ins pass every check.
final class MacScopeThemeTests: XCTestCase {
    struct Expected: Decodable {
        let colors: [String: [String: [String: String]]]
        let order: [String]
    }

    let registry = LumenRegistry.macScope

    private func expected() throws -> Expected {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "macscope-expected", withExtension: "json"))
        return try JSONDecoder().decode(Expected.self, from: Data(contentsOf: url))
    }

    func testEveryTokenResolvesExactlyAsMacScopeDoesToday() throws {
        let expected = try expected()
        XCTAssertTrue(Set(expected.order).isSubset(of: Set(registry.tokens.map(\.rawValue))),
                      "All 110 MacScope roles exist (Lumen's core adds chrome foregrounds and sidebar.accent)")
        var checked = 0, mismatches: [String] = []
        for (themeID, appearances) in expected.colors {
            let theme = try XCTUnwrap(registry.theme(id: themeID), themeID)
            for (key, tokens) in appearances {
                let appearance = LumenAppearance(isDark: key.hasPrefix("dark"), isHighContrast: key.hasSuffix("+contrast"))
                for (raw, hex) in tokens {
                    checked += 1
                    let actual = theme.color(LumenToken(raw), for: appearance, in: registry).hexString
                    if actual != hex { mismatches.append("\(themeID) \(key) \(raw): \(actual) ≠ \(hex)") }
                }
            }
        }
        XCTAssertEqual(checked, 110 * (4 + 2 + 4), "Scope and Contrast have four variants, Midnight two")
        XCTAssertEqual(mismatches, [])
    }

    func testMacScopeBuiltInsPassEveryCheck() {
        // The themes MacScope offers. (Lumen's own are hidden; MacScope's themes don't depend on
        // them.) MacScope's legacy colors are a bridge, not a constraint on Lumen: where a Lumen rule
        // flags one, it's listed here by name, so any new issue still fails. Lumen replaces these
        // themes eventually.
        // Visibility, lift and composite rules (wells in sidebars, raised hover and inactive
        // selection, separators, neutral tags, control edges, filled-accent text) and contrast on
        // raised grounds postdate MacScope's original values.
        let knownLegacyIssues: [String: [String]] = [
            "Scope": [
                "light: In the sidebar an inactive selection looks like a hovered row",
                "light+contrast: In the sidebar an inactive selection looks like a hovered row",
                "dark: In the sidebar an inactive selection looks like a hovered row",
                "dark+contrast: In the sidebar an inactive selection looks like a hovered row",
                "dark: status.danger on activity.background on a raised ground is 4.24:1; needs 4.50:1",
                "dark: bg.inset is darker than bg.canvas it sits on; in dark, nested grounds step lighter",
                "light: fg.disabled on bg.selected is 1.83:1; needs 2:1",
                "light: Wells (pills, counts, fields) are hard to see in the sidebar",
                "light: Wells (pills, counts, fields) are hard to see on the window ground",
                "light: An inactive selection looks like a hovered row",
                "light: On raised grounds an inactive selection looks like a hovered row",
                "light: Neutral tags are hard to see on the window ground",
                "light: Neutral tags are hard to see in wells on cards",
                "light: border.control on bg.canvas is 1.97:1; needs 3:1",
                "light: border.control on bg.window is 1.69:1; needs 3:1",
                "light: border.control on bg.elevated is 1.97:1; needs 3:1",
                "light: border.control on bg.inset is 1.72:1; needs 3:1",
                "light: border.control on bg.insetRaised is 1.72:1; needs 3:1",
                "light: The activity capsule is hard to see on the toolbar",
                "light: menu.highlightForeground at 82% on menu.highlight is 4.25:1; needs 4.5:1",
                "light: menu.highlightForeground on a keycap on menu.highlight is 3.81:1; needs 4.5:1",
                "light: accent.filledForeground at 82% on accent.filled is 4.25:1; needs 4.5:1",
                "light: accent.filledForeground on a keycap on accent.filled is 3.81:1; needs 4.5:1",
                "light+contrast: An inactive selection looks like a hovered row",
                "light+contrast: On raised grounds an inactive selection looks like a hovered row",
                "light+contrast: The selected tab's plate is hard to see on the tab strip",
                "dark: fg.disabled on bg.selected is 1.90:1; needs 2:1",
                "dark: fg.disabled on bg.insetRaised is 1.92:1; needs 2:1",
                "dark: bg.inset is darker than bg.sidebar it sits on; in dark, nested grounds step lighter",
                "dark: bg.inset is darker than inspector.background it sits on; in dark, nested grounds step lighter",
                "dark: bg.inset is darker than panel.background it sits on; in dark, nested grounds step lighter",
                "dark: Wells (pills, counts, fields) are hard to see on the window ground",
                "dark: Hover is hard to see on cards, popovers and sheets",
                "dark: An inactive selection is hard to see on cards, popovers and sheets",
                "dark: An inactive selection looks like a hovered row",
                "dark: On raised grounds an inactive selection looks like a hovered row",
                "dark: Menu separators are hard to see",
                "dark: Grouped card borders and row hairlines are hard to see",
                "dark: Neutral tags are hard to see in wells on cards",
                "dark: border.control on bg.canvas is 2.19:1; needs 3:1",
                "dark: border.control on bg.window is 2.29:1; needs 3:1",
                "dark: border.control on bg.elevated is 1.86:1; needs 3:1",
                "dark: border.control on bg.inset is 2.31:1; needs 3:1",
                "dark: border.control on bg.insetRaised is 1.65:1; needs 3:1",
                "dark: The selected tab's plate is hard to see on the tab strip",
                "dark: menu.highlightForeground on a keycap on menu.highlight is 4.22:1; needs 4.5:1",
                "dark: accent.filledForeground on a keycap on accent.filled is 4.22:1; needs 4.5:1",
                "dark+contrast: An inactive selection looks like a hovered row",
                "dark+contrast: On raised grounds an inactive selection looks like a hovered row",
                "dark+contrast: Neutral tags are hard to see in wells on cards",
                "dark+contrast: The selected tab's plate is hard to see on the tab strip",
            ],
            "Midnight": [
                "dark: In the sidebar an inactive selection looks like a hovered row",
                // A Display P3 theme: ratios are measured in Display P3.
                "dark: bg.inset is darker than bg.canvas it sits on; in dark, nested grounds step lighter",
                "dark: fg.disabled on bg.selected is 1.92:1; needs 2:1",
                "dark: bg.inset is darker than bg.sidebar it sits on; in dark, nested grounds step lighter",
                "dark: bg.inset is darker than inspector.background it sits on; in dark, nested grounds step lighter",
                "dark: bg.inset is darker than panel.background it sits on; in dark, nested grounds step lighter",
                "dark: Wells (pills, counts, fields) are hard to see on the window ground",
                "dark: Hover is hard to see on cards, popovers and sheets",
                "dark: An inactive selection looks like a hovered row",
                "dark: On raised grounds an inactive selection looks like a hovered row",
                "dark: Menu separators are hard to see",
                "dark: Grouped card borders and row hairlines are hard to see",
                "dark: border.control on bg.canvas is 1.74:1; needs 3:1",
                "dark: border.control on bg.window is 1.80:1; needs 3:1",
                "dark: border.control on bg.elevated is 1.55:1; needs 3:1",
                "dark: border.control on bg.inset is 1.82:1; needs 3:1",
                "dark: border.control on bg.insetRaised is 1.38:1; needs 3:1",
                "dark: The selected tab's plate is hard to see on the tab strip",
                "dark: menu.highlightForeground on a keycap on menu.highlight is 4.34:1; needs 4.5:1",
                "dark: accent.filledForeground on a keycap on accent.filled is 4.34:1; needs 4.5:1",
            ],
            "Contrast": [
                "light: In the sidebar an inactive selection looks like a hovered row",
                "dark: In the sidebar an inactive selection looks like a hovered row",
                "light: An inactive selection looks like a hovered row",
                "light: On raised grounds an inactive selection looks like a hovered row",
                "light: The selected tab's plate is hard to see on the tab strip",
                "dark: An inactive selection looks like a hovered row",
                "dark: On raised grounds an inactive selection looks like a hovered row",
                "dark: Neutral tags are hard to see in wells on cards",
                "dark: The selected tab's plate is hard to see on the tab strip",
            ],
        ]
        XCTAssertEqual(LumenConformance.themes(in: registry, themes: registry.galleryThemes, allowing: knownLegacyIssues)
            .map(\.description), [])
    }

    func testTheGalleryOffersMacScopesThemesUnderTheirExistingIDs() {
        XCTAssertEqual(registry.galleryThemes.map(\.id), [MacScopeThemes.scopeID, MacScopeThemes.midnightID, MacScopeThemes.contrastID])
        XCTAssertEqual(registry.galleryThemes.map(\.name), ["Scope", "Midnight", "Contrast"])
        XCTAssertEqual(registry.defaultThemeID, MacScopeThemes.scopeID)
    }

    func testEditorSurfaceCarriesTheCanvasRoles() {
        XCTAssertEqual(registry.surfaces, [.window, .editor])
        for token: LumenToken in [.bgCanvas, .bgGutter, .syntaxKeyword, .listingSelection, .graphEdgeCall, .terminalRed] {
            XCTAssertEqual(registry.surface(of: token), .editor, token.rawValue)
        }
        for token: LumenToken in [.bgSidebar, .fgPrimary, .kindFunction, .deckBackground, .accent] {
            XCTAssertEqual(registry.surface(of: token), .window, token.rawValue)
        }
    }

    func testMacScopesLookDoesNotDependOnLumensThemes() {
        for theme in registry.galleryThemes {
            XCTAssertNil(theme.inherits)
            XCTAssertTrue(theme.missingTokens(in: registry).isEmpty, "\(theme.name) defines every semantic role itself")
        }
        XCTAssertNotEqual(MacScopeThemes.scope.light?[.bgCanvas], nil)
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

    func testMacScopeRulesStillCatchWhatTheyCaughtBefore() throws {
        let broken = try LumenTheme(id: "user.broken", name: "Broken", inherits: MacScopeThemes.scopeID, light: [
            .listingPatchedRow: "#E2B9A4",          // listing text unreadable on patched rows
            .kindSegment: "#0064C3",                // same as kind.function
            .syntaxType: "#A0308A",                 // same as syntax.keyword (pseudocode)
            .graphEdgeSelected: "#6757D0",          // same as call edges (the accent)
        ], dark: nil).flattened { self.registry.theme(id: $0) }
        let messages = LumenValidator.issues(for: broken, in: registry)
            .filter { !$0.appearance.isDark && !$0.appearance.isHighContrast }.map(\.message)
        XCTAssertTrue(messages.contains { $0.hasPrefix("syntax.mnemonicMemory on listing.patchedRow") }, "\(messages)")
        XCTAssertTrue(messages.contains("kind.function and kind.segment are too alike to tell kinds apart"))
        XCTAssertTrue(messages.contains("syntax.keyword and syntax.type are too alike to tell pseudocode roles apart"))
        XCTAssertTrue(messages.contains("graph.edge.selected is too close to graph.edge.call to show the selection"))
    }

    /// Protections for listing secondary text on the
    /// plain canvas, no translucent listing text (imported themes included), and secondary text on
    /// the warning banner and on current-block chips.
    func testListingAndBannerProtectionsHold() throws {
        let faint = try LumenTheme(id: "user.faint", name: "Faint", inherits: MacScopeThemes.scopeID, light: [
            .listingSecondaryText: "#C9CCD3",       // opaque, but faint on the white canvas
        ], dark: nil).flattened { self.registry.theme(id: $0) }
        XCTAssertTrue(lightMessages(faint).contains { $0.hasPrefix("listing.secondaryText on bg.canvas") }, "\(lightMessages(faint))")

        let translucent = try JSONDecoder().decode(LumenTheme.self, from: Data(#"""
        {"schemaVersion": 1, "id": "user.ghost", "name": "Ghost", "inherits": "\#(MacScopeThemes.scopeID)",
         "light": {"listing.secondaryText": "#4A516280"}}
        """#.utf8)).flattened { self.registry.theme(id: $0) }
        XCTAssertTrue(lightMessages(translucent).contains { $0.hasPrefix("listing.secondaryText must be opaque") },
                      "\(lightMessages(translucent))")

        let grounds = try LumenTheme(id: "user.grounds", name: "Grounds", inherits: MacScopeThemes.scopeID, light: [
            .statusWarningBackground: "#8C6A1E", .bgElevated: "#5A5F6B",
        ], dark: nil).flattened { self.registry.theme(id: $0) }
        let messages = lightMessages(grounds)
        XCTAssertTrue(messages.contains { $0.hasPrefix("fg.secondary on status.warningBackground") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.hasPrefix("fg.secondary on bg.elevated") }, "\(messages)")
    }

    private func lightMessages(_ theme: LumenTheme) -> [String] {
        LumenValidator.issues(for: theme, in: registry).filter { !$0.appearance.isDark && !$0.appearance.isHighContrast }.map(\.message)
    }
}
