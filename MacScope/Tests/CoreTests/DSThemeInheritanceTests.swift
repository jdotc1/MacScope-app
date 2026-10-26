import XCTest
import LumenTokens
import LumenUI
@testable import MacScope

final class DSThemeInheritanceTests: XCTestCase {
    private func decode(_ json: String) throws -> LumenTheme {
        try JSONDecoder().decode(LumenTheme.self, from: Data(json.utf8))
    }

    func testPartialThemeInheritsEverythingItLeavesOut() throws {
        let child = try decode(##"{"id":"user.calm","name":"Calm","inherits":"com.macscope.theme.midnight","dark":{"accent.default":"#7FD1FF"}}"##)
        XCTAssertEqual(child.colorSpace, .sRGB, "colorSpace is optional and defaults to sRGB")
        let resolved = try child.flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        XCTAssertNil(resolved.inherits)
        XCTAssertEqual(resolved.forcedColorScheme, .dark, "Inherits Midnight's dark-only shape")
        XCTAssertEqual(resolved.hex(.accent, for: .dark).hexString, "#7FD1FF")
        XCTAssertEqual(resolved.hex(.bgCanvas, for: .dark), DSBuiltInThemes.midnight.hex(.bgCanvas, for: .dark))
        XCTAssertTrue(resolved.missingTokens.isEmpty)
    }

    func testOverridesSurviveIncreaseContrastFromTheParent() throws {
        // Scope ships complete contrast palettes; they must not hide a child's own colors.
        let child = try decode(##"{"id":"user.calm","name":"Calm","inherits":"com.macscope.theme.scope","light":{"accent.default":"#2F6FDE"},"darkHighContrast":{"bg.canvas":"#050505"}}"##)
        let resolved = try child.flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        let lightContrast = LumenAppearance(isDark: false, isHighContrast: true)
        let darkContrast = LumenAppearance(isDark: true, isHighContrast: true)
        XCTAssertEqual(resolved.hex(.accent, for: lightContrast).hexString, "#2F6FDE", "the child's override wins")
        XCTAssertEqual(resolved.hex(.fgPrimary, for: lightContrast), DSBuiltInThemes.scope.hex(.fgPrimary, for: lightContrast),
                       "everything the child leaves out keeps Scope's contrast value")
        XCTAssertEqual(resolved.hex(.bgCanvas, for: darkContrast).hexString, "#050505", "the child's own contrast value wins")
        XCTAssertEqual(resolved.hex(.accent, for: darkContrast), DSBuiltInThemes.scope.hex(.accent, for: darkContrast))
    }

    func testInheritanceChainsAndDetectsCyclesAndMissingParents() throws {
        let a = try decode(##"{"id":"a","name":"A","inherits":"b","dark":{"bg.canvas":"#000001"}}"##)
        let b = try decode(##"{"id":"b","name":"B","inherits":"com.macscope.theme.scope","dark":{"bg.canvas":"#000002","fg.primary":"#EEEEEE"}}"##)
        let all = DSBuiltInThemes.all + [a, b]
        let lookup: (String) -> LumenTheme? = { id in all.first { $0.id == id } }
        let resolved = try a.flattened(lookup: lookup)
        XCTAssertEqual(resolved.hex(.bgCanvas, for: .dark).hexString, "#000001", "child wins")
        XCTAssertEqual(resolved.hex(.fgPrimary, for: .dark).hexString, "#EEEEEE", "parent fills in")
        XCTAssertEqual(resolved.hex(.syntaxRegister, for: .light), DSBuiltInThemes.scope.hex(.syntaxRegister, for: .light),
                       "grandparent's light variant is inherited whole")

        let loopA = try decode(##"{"id":"loopA","name":"A","inherits":"loopB"}"##)
        let loopB = try decode(##"{"id":"loopB","name":"B","inherits":"loopA"}"##)
        XCTAssertThrowsError(try loopA.flattened { id in [loopA, loopB].first { $0.id == id } }) {
            XCTAssertEqual($0 as? LumenTheme.InheritanceError, .cycle(["loopA", "loopB", "loopA"]))
        }
        let orphan = try decode(##"{"id":"orphan","name":"O","inherits":"nope"}"##)
        XCTAssertThrowsError(try orphan.flattened { _ in nil }) {
            XCTAssertEqual($0 as? LumenTheme.InheritanceError, .unknownParent("nope"))
        }
        XCTAssertEqual(DSThemeStore.resolvingInheritance([loopA, loopB, orphan]).count, 0,
                       "Unresolvable themes are skipped, not loaded half resolved")
    }

    func testComponentTokensFallBackWithinTheSameTheme() throws {
        for theme in DSBuiltInThemes.all {
            for appearance in [LumenAppearance.light, .dark] {
                // Only tokens the theme leaves out must fall back; a built-in may tune a component
                // token on purpose (the terminal ANSI colors, for example).
                for token in LumenToken.allCases where token.isComponent && theme.palette(for: appearance)[token] == nil {
                    XCTAssertEqual(theme.hex(token, for: appearance), theme.hex(token.fallback!, for: appearance),
                                   "\(theme.name) \(token.rawValue)")
                }
            }
        }
        let tuned = try decode(##"{"id":"t","name":"T","inherits":"com.macscope.theme.scope","light":{"sidebar.rowSelected":"#FF00FF"}}"##)
            .flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        XCTAssertEqual(tuned.hex(.sidebarRowSelected, for: .light).hexString, "#FF00FF")
        XCTAssertEqual(tuned.hex(.listingSelection, for: .light), DSBuiltInThemes.scope.hex(.bgSelected, for: .light),
                       "Overriding one component leaves the others on their fallbacks")
    }

    func testComponentTokensFollowTheirOwner() {
        XCTAssertTrue(LumenToken.listingSelection.isEditorOwned)
        XCTAssertTrue(LumenToken.statusbarBackground.isEditorOwned)
        XCTAssertFalse(LumenToken.sidebarRowSelected.isEditorOwned)
        XCTAssertFalse(LumenToken.semantic.contains(.tabAccentBar))
    }
}
