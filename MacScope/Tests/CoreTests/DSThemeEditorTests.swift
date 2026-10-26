import XCTest
import LumenTokens
import LumenUI
@testable import MacScope

final class DSThemeEditorTests: XCTestCase {
    func testListingSecondaryTextDoesNotOfferOpacityWhileRowGroundsDo() {
        XCTAssertFalse(DSThemeEditor.supportsOpacity(.listingSecondaryText))
        XCTAssertTrue(DSThemeEditor.supportsOpacity(.listingAlternateRow))
        XCTAssertFalse(DSThemeEditor.supportsOpacity(.fgPrimary))
    }

    func testValidatorChecksWarningBodyForegroundAgainstItsBackground() throws {
        let theme = try DSThemeStore.partialTheme(
            name: "Unreadable warning", inheriting: DSBuiltInThemes.scope,
            overrides: [false: [.statusWarningBackground: "#4A5162"]], existingIDs: []
        ).flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        XCTAssertTrue(DSThemeValidator.issues(for: theme).contains {
            $0.appearance == .light && $0.severity == .error
                && $0.message.hasPrefix("fg.secondary on status.warningBackground")
        })
    }

    func testValidatorChecksGraphChipForegroundAgainstElevatedBackground() throws {
        let theme = try DSThemeStore.partialTheme(
            name: "Unreadable graph chip", inheriting: DSBuiltInThemes.scope,
            overrides: [false: [.bgElevated: "#4A5162"]], existingIDs: []
        ).flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        XCTAssertTrue(DSThemeValidator.issues(for: theme).contains {
            $0.appearance == .light && $0.severity == .error
                && $0.message.hasPrefix("fg.secondary on bg.elevated")
        })
    }

    func testBuiltInThemesPassTheValidator() {
        // Midnight takes Lumen Midnight's danger red since U5e, so no built-in has a known issue.
        for theme in DSBuiltInThemes.all {
            XCTAssertEqual(DSThemeValidator.issues(for: theme).map(\.message), [], theme.name)
        }
    }

    func testValidatorCatchesUnreadableTextAndDuplicatePseudocodeColors() throws {
        let bad = try DSThemeStore.partialTheme(
            name: "Bad", inheriting: DSBuiltInThemes.scope,
            overrides: [false: [.fgSecondary: "#F0F0F0", .syntaxType: DSBuiltInThemes.scope.hex(.syntaxKeyword, for: .light)]],
            existingIDs: []
        ).flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        let issues = DSThemeValidator.issues(for: bad).filter { !$0.appearance.isDark }
        XCTAssertTrue(issues.contains { $0.token == .fgSecondary && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.message.contains("pseudocode") })
    }

    func testValidatorWarnsWhenTwoKindsLookAlike() throws {
        let scopeLight = DSBuiltInThemes.scope.hex(.kindFunction, for: .light)
        let alike = try DSThemeStore.partialTheme(
            name: "Alike", inheriting: DSBuiltInThemes.scope,
            overrides: [false: [.kindSegment: scopeLight]],
            existingIDs: []
        ).flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        let issues = DSThemeValidator.issues(for: alike).filter { !$0.appearance.isDark && !$0.appearance.isHighContrast }
        XCTAssertEqual(issues.map(\.token), [.kindSegment])
        XCTAssertEqual(issues.first?.severity, .warning, "A theme can still be saved; kinds also differ by glyph")
    }

    func testValidatorNamesUnknownKeysAndSuggestsTheToken() throws {
        let typo = try DSThemeStore.decodeTheme(Data(##"{"id": "user.typo", "name": "Typo", "inherits": "com.macscope.theme.scope", "light": {"accent": "#2F6FDE", "future.role": "#000000"}}"##.utf8))
            .flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        let messages = DSThemeValidator.unknownKeyIssues(in: typo).map(\.message)
        XCTAssertEqual(messages, ["“accent” is not a MacScope color; did you mean “accent.default”?",
                                  "“future.role” is not a MacScope color"])
        XCTAssertTrue(DSThemeValidator.issues(for: typo).contains { $0.message.hasPrefix("“accent”") && $0.severity == .warning })
    }

    func testValidatorChecksFocusRingAndAccentAsGraphics() throws {
        let faint = try DSThemeStore.partialTheme(
            name: "Faint", inheriting: DSBuiltInThemes.scope,
            overrides: [false: [.borderFocus: "#E6E8EE", .accent: "#D9D4FF"]], existingIDs: []
        ).flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        let issues = DSThemeValidator.issues(for: faint).filter { !$0.appearance.isDark && !$0.appearance.isHighContrast }
        XCTAssertTrue(issues.contains { $0.token == .borderFocus && $0.message.contains("bg.canvas") && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.token == .accent && $0.message.contains("sidebar.background") })
    }

    func testEditorPreviewMatchesSavedInheritanceInEveryAppearance() throws {
        let overrides: [Bool: [LumenToken: LumenColor]] = [
            false: [.accent: "#2F6FDE", .fgSecondary: "#425570"],
            true: [.accent: "#7FD1FF", .bgCanvas: "#050505"],
        ]
        for base in DSBuiltInThemes.all {
            let preview = DSThemeStore.editorPreview(name: "Custom", inheriting: base, overrides: overrides)
            let saved = try DSThemeStore.partialTheme(
                name: "Custom", inheriting: base, overrides: overrides, existingIDs: []
            ).flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
            for dark in [false, true] {
                for contrast in [false, true] {
                    let appearance = LumenAppearance(isDark: dark, isHighContrast: contrast)
                    for token in LumenToken.allCases {
                        XCTAssertEqual(preview.hex(token, for: appearance), saved.hex(token, for: appearance),
                                       "\(base.id): \(token.rawValue), dark=\(dark), contrast=\(contrast)")
                    }
                }
            }
            XCTAssertEqual(DSThemeValidator.issues(for: preview), DSThemeValidator.issues(for: saved),
                           "Save enablement must validate the colors that will actually be loaded")
        }
    }

    func testEditorGroupsCoverEveryTokenExactlyOnce() {
        let grouped = DSThemeEditor.groups.flatMap(\.1)
        XCTAssertEqual(grouped.count, LumenToken.allCases.count)
        XCTAssertEqual(Set(grouped), Set(LumenToken.allCases))
    }

    func testEditorFilterMatchesNamesAndGroupTitles() {
        XCTAssertEqual(DSThemeEditor.groups(matching: "LISTING").map(\.0), ["Listing"], "Case-insensitive; group title matches")
        XCTAssertEqual(DSThemeEditor.groups(matching: "accent.default").flatMap(\.1), [.accent])
        XCTAssertEqual(DSThemeEditor.groups(matching: "").count, DSThemeEditor.groups.count)
        XCTAssertTrue(DSThemeEditor.groups(matching: "no such color").isEmpty)
        XCTAssertEqual(DSThemeEditor.groups(matching: "", within: [.kindString, .bgCanvas]).flatMap(\.1), [.bgCanvas, .kindString],
                       "Changed only keeps group order")
    }

    func testEditorSavesOnlyOverridesOnTopOfTheBase() throws {
        let theme = DSThemeStore.partialTheme(
            name: "Midnight Calm!", inheriting: DSBuiltInThemes.midnight,
            overrides: [true: [.accent: "#7FD1FF"]],
            existingIDs: ["user.midnight-calm-"]
        )
        XCTAssertEqual(theme.id, "user.midnight-calm--2", "Collision gets a numeric suffix")
        XCTAssertEqual(theme.inherits, DSBuiltInThemes.midnight.id)
        XCTAssertNil(theme.light)
        XCTAssertEqual(theme.dark?.colors.count, 1, "Only the override is written")
        let resolved = try theme.flattened { id in DSBuiltInThemes.all.first { $0.id == id } }
        XCTAssertEqual(resolved.hex(.accent, for: .dark).hexString, "#7FD1FF")
        XCTAssertEqual(resolved.forcedColorScheme, .dark)
    }
}
