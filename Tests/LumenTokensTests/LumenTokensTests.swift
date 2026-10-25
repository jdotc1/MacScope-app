import Foundation
import XCTest
@testable import LumenTokens

final class LumenCoreTests: XCTestCase {
    let registry = LumenRegistry.core

    func testBuiltInThemesAreCompleteAndPassEveryCheck() {
        XCTAssertEqual(registry.builtInThemes.map(\.id), [LumenThemes.standardID, LumenThemes.midnightID, LumenThemes.ultravioletID, LumenThemes.contrastID])
        for theme in registry.builtInThemes {
            XCTAssertTrue(theme.missingTokens(in: registry).isEmpty, "\(theme.name) defines every semantic role")
            XCTAssertEqual(LumenValidator.issues(for: theme, in: registry).map(\.message), [], theme.name)
        }
    }

    func testComponentTokensFallBackWithinTheSameTheme() {
        let theme = LumenThemes.midnight
        XCTAssertEqual(theme.color(.sidebarBackground, for: .dark, in: registry), theme.color(.bgSidebar, for: .dark, in: registry))
        XCTAssertEqual(theme.color(.tabAccentBar, for: .dark, in: registry), theme.color(.accent, for: .dark, in: registry))
    }

    func testAppsCanInvertChromeWithItsOwnForegrounds() throws {
        // A dark sidebar in a light app: the sidebar text, its hover and inactive selection fills are set with it, and the
        // validator checks those pairs instead of canvas text on the sidebar.
        let leather = try LumenTheme(id: "user.leather", name: "Leather", inherits: LumenThemes.standardID,
                                     light: [.sidebarBackground: "#2F4A3A", .sidebarRowSelected: "#3E5E4B", .sidebarRowSelectedInactive: "#30483B", .sidebarRowHover: "#38564A",
                                             .sidebarForeground: "#F3EBDD", .sidebarSecondaryForeground: "#CFC4B0"], dark: nil)
            .flattened { self.registry.theme(id: $0) }
        let light = LumenValidator.issues(for: leather, in: registry).filter { !$0.appearance.isDark && !$0.appearance.isHighContrast }
        XCTAssertEqual(light.map(\.message).filter { $0.contains("sidebar") && !$0.contains("accent") && !$0.contains("border.focus") }, [])
        let unreadable = try LumenTheme(id: "user.bad", name: "Bad", inherits: LumenThemes.standardID,
                                        light: [.sidebarBackground: "#2F4A3A"], dark: nil)
            .flattened { self.registry.theme(id: $0) }
        XCTAssertTrue(LumenValidator.issues(for: unreadable, in: registry).contains { $0.token == .sidebarForeground && $0.severity == .error },
                      "Dark sidebar without light text is caught")
    }

    func testIncreaseContrastUsesTheContrastPalettes() {
        let standard = registry.theme(id: LumenThemes.standardID)!
        let contrast = registry.theme(id: LumenThemes.contrastID)!
        let highContrastLight = LumenAppearance(isDark: false, isHighContrast: true)
        XCTAssertEqual(standard.color(.fgPrimary, for: highContrastLight, in: registry), contrast.color(.fgPrimary, for: .light, in: registry))
    }

    func testGroupsCoverEveryTokenOnceInRegistrationOrder() {
        let grouped = registry.groups.flatMap(\.tokens)
        XCTAssertEqual(grouped.count, registry.tokens.count)
        XCTAssertEqual(Set(grouped), Set(registry.tokens))
        XCTAssertEqual(registry.groups.map(\.title), ["Surfaces", "Text and Lines", "Accent", "Status", "Hues", "Window Chrome", "Menus", "Panels", "Welcome", "Workspace"])
    }
}

/// An app extends Lumen with its own pack: tokens, a surface, values for the built-in themes,
/// and rules. This stands in for MacScope or any other app.
final class LumenAppPackTests: XCTestCase {
    static let editor = LumenSurface("editor")
    static let keyword: LumenToken = "syntax.keyword"
    static let comment: LumenToken = "syntax.comment"
    static let currentLine: LumenToken = "editor.currentLine"
    static let seriesA: LumenToken = "chart.seriesA"
    static let seriesB: LumenToken = "chart.seriesB"

    static let pack = LumenPack(
        id: "example.app",
        tokens: [
            LumenTokenSpec(keyword, group: "Code", surface: editor, contrast: [.text(on: .bgCanvas)]),
            LumenTokenSpec(comment, group: "Code", surface: editor, contrast: [.text(on: .bgCanvas)]),
            LumenTokenSpec(currentLine, group: "Code", fallback: .composite(.accent, alpha: 0.08, over: .bgCanvas), surface: editor),
            LumenTokenSpec(seriesA, group: "Charts", fallback: .token(.accent)),
            LumenTokenSpec(seriesB, group: "Charts", fallback: .token(.statusInfo)),
        ],
        surfaces: [editor],
        themes: [LumenTheme(id: "example.brand", name: "Brand", inherits: LumenThemes.standardID,
                            light: [.accent: "#0B6E73", .accentSubtle: "#E2F1F1", .borderFocus: "#0B6E73"], dark: nil)],
        themeValues: [
            LumenThemes.standardID: LumenThemeValues(light: [keyword: "#A0308A", comment: "#5C6476"],
                                                     dark: [keyword: "#F28FD0", comment: "#959FAF"]),
            LumenThemes.midnightID: LumenThemeValues(dark: [keyword: "#E532AD", comment: "#8C94AD"]),
            LumenThemes.contrastID: LumenThemeValues(light: [keyword: "#8A106E", comment: "#4D4D4D"],
                                                     dark: [keyword: "#FFB0E6", comment: "#C8C8C8"]),
        ],
        rules: [LumenDistinctRule([seriesA, seriesB], noun: "chart series")]
    )

    let registry = LumenRegistry(packs: [.core, LumenAppPackTests.pack])

    func testAppTokensJoinTheRegistryWithTheirSurface() {
        XCTAssertEqual(registry.surfaces, [.window, Self.editor])
        XCTAssertEqual(registry.surface(of: Self.keyword), Self.editor)
        XCTAssertEqual(registry.surface(of: .bgCanvas), .window)
        XCTAssertEqual(registry.groups.map(\.title).suffix(2), ["Code", "Charts"])
    }

    func testPackValuesMergeIntoBuiltInThemesWithoutTouchingCoreValues() {
        let standard = registry.theme(id: LumenThemes.standardID)!
        XCTAssertEqual(standard.color(Self.keyword, for: .dark, in: registry).hexString, "#F28FD0")
        XCTAssertEqual(standard.color(.bgCanvas, for: .light, in: registry), LumenRegistry.core.theme(id: LumenThemes.standardID)!.color(.bgCanvas, for: .light, in: .core))
        XCTAssertEqual(registry.theme(id: LumenThemes.midnightID)!.light, nil, "Values for undeclared variants are ignored")
    }

    func testCompositeFallbackResolvesToTheTintedLook() {
        let standard = registry.theme(id: LumenThemes.standardID)!
        let expected = standard.color(.accent, for: .light, in: registry).composited(alpha: 0.08, over: standard.color(.bgCanvas, for: .light, in: registry))
        XCTAssertEqual(standard.color(Self.currentLine, for: .light, in: registry), expected)
    }

    func testAppThemesInheritCoreThemesAndAllPassTheValidator() {
        let brand = registry.theme(id: "example.brand")!
        XCTAssertNil(brand.inherits, "Built-ins are flattened")
        XCTAssertEqual(brand.color(.accent, for: .light, in: registry).hexString, "#0B6E73")
        XCTAssertEqual(brand.color(Self.keyword, for: .light, in: registry).hexString, "#A0308A", "Inherited from the core theme's pack values")
        for theme in registry.builtInThemes {
            XCTAssertEqual(LumenValidator.issues(for: theme, in: registry).map(\.message), [], theme.name)
        }
    }

    func testAppRulesAndRequirementsRunInTheValidator() throws {
        let alike = try LumenTheme(id: "user.alike", name: "Alike", inherits: LumenThemes.standardID,
                                   light: [Self.seriesB: "#6757D0", Self.keyword: "#F4F4F6"], dark: nil)
            .flattened { self.registry.theme(id: $0) }
        let messages = LumenValidator.issues(for: alike, in: registry).filter { !$0.appearance.isDark && !$0.appearance.isHighContrast }.map(\.message)
        XCTAssertTrue(messages.contains("chart.seriesA and chart.seriesB are too alike to tell chart series apart"), "\(messages)")
        XCTAssertTrue(messages.contains { $0.hasPrefix("syntax.keyword on bg.canvas is") })
    }

    func testAnAppCanMoveACoreTokenOntoItsSurface() {
        var editorCanvas = Self.pack
        editorCanvas.surfaceOverrides = [.bgCanvas: Self.editor]
        let registry = LumenRegistry(packs: [.core, editorCanvas])
        XCTAssertEqual(registry.surface(of: .bgCanvas), Self.editor)
        XCTAssertEqual(LumenRegistry.core.surface(of: .bgCanvas), .window, "Only that app's registry changes")
    }

    func testAnAppCanBrandAndHideCoreThemes() {
        var branded = Self.pack
        branded.hidesThemes = [LumenThemes.standardID]
        let registry = LumenRegistry(packs: [.core, branded])
        XCTAssertEqual(registry.galleryThemes.map(\.id), [LumenThemes.midnightID, LumenThemes.ultravioletID, LumenThemes.contrastID, "example.brand"])
        XCTAssertNotNil(registry.theme(id: LumenThemes.standardID), "Hidden themes still resolve as parents")
        XCTAssertEqual(registry.theme(id: "example.brand")?.color(.bgCanvas, for: .light, in: registry).hexString, "#FFFFFF")
    }

    func testTheSameThemeFileWorksInAnAppWithoutThePack() throws {
        // A theme with another app's keys loads everywhere; an app without that pack just flags
        // the keys it doesn't know.
        let theme = try JSONDecoder().decode(LumenTheme.self, from: Data(##"{"id":"user.x","name":"X","inherits":"lumen.standard","light":{"syntax.keyword":"#A0308A"}}"##.utf8))
        let flat = try theme.flattened { LumenRegistry.core.theme(id: $0) }
        XCTAssertEqual(LumenValidator.issues(for: flat, in: .core).map(\.message), ["“syntax.keyword” is not a color this app knows"])
        XCTAssertEqual(LumenValidator.issues(for: try theme.flattened { self.registry.theme(id: $0) }, in: registry).map(\.message), [])
    }
}

final class LumenThemeFormatTests: XCTestCase {
    private func decode(_ json: String) throws -> LumenTheme { try JSONDecoder().decode(LumenTheme.self, from: Data(json.utf8)) }

    func testDecoderEnforcesTheSchema() {
        let cases = [
            ##"{"id": "", "name": "A", "inherits": "lumen.standard"}"##,
            ##"{"id": "a", "name": " ", "inherits": "lumen.standard"}"##,
            ##"{"id": "a", "name": "No colors"}"##,
            ##"{"id": "a", "name": "Bare", "light": {"accent.default": "2F6FDE"}}"##,
            ##"{"id": "a", "name": "Zero", "schemaVersion": 0, "inherits": "lumen.standard"}"##,
        ]
        for json in cases { XCTAssertThrowsError(try decode(json), json) }
        XCTAssertNoThrow(try decode(##"{"id": "a", "name": "Future", "schemaVersion": 9}"##), "Newer schemas decode so the loader can say so")
    }

    func testInheritanceDetectsCyclesAndMissingParents() throws {
        let a = try decode(##"{"id":"a","name":"A","inherits":"b"}"##)
        let b = try decode(##"{"id":"b","name":"B","inherits":"a"}"##)
        XCTAssertThrowsError(try a.flattened { ["a": a, "b": b][$0] }) { XCTAssertEqual($0 as? LumenTheme.InheritanceError, .cycle(["a", "b", "a"])) }
        XCTAssertThrowsError(try a.flattened { _ in nil }) { XCTAssertEqual($0 as? LumenTheme.InheritanceError, .unknownParent("b")) }
    }

    func testOverridesSurviveInheritedIncreaseContrast() throws {
        let child = try decode(##"{"id":"c","name":"C","inherits":"lumen.standard","light":{"accent.default":"#2F6FDE"}}"##)
            .flattened { LumenRegistry.core.theme(id: $0) }
        XCTAssertEqual(child.color(.accent, for: LumenAppearance(isDark: false, isHighContrast: true), in: .core).hexString, "#2F6FDE")
    }

    func testColorMath() {
        XCTAssertEqual(LumenColor(hex: "#000000")!.contrastRatio(against: "#FFFFFF"), 21, accuracy: 1e-9)
        XCTAssertEqual(LumenColor(hex: "#000000")!.perceptualDistance(to: "#FFFFFF"), 1, accuracy: 1e-4)
        XCTAssertEqual(LumenColor(hex: "#0064C3")!.composited(alpha: 0.16, over: "#F6F6F8").hexString, "#CFDFF0")
        XCTAssertNil(LumenColor(hex: "#12345"))
    }

    func testExportDescribesEveryRegisteredToken() throws {
        let registry = LumenRegistry(packs: [.core, LumenAppPackTests.pack])
        let schema = try JSONSerialization.jsonObject(with: Data(LumenExport.themeSchemaJSON(registry).utf8)) as! [String: Any]
        let palette = (schema["$defs"] as! [String: Any])["palette"] as! [String: Any]
        XCTAssertEqual(Set((palette["properties"] as! [String: Any]).keys), Set(registry.tokens.map(\.rawValue)))
        let reference = LumenExport.tokenReferenceMarkdown(registry)
        XCTAssertTrue(reference.contains("| `editor.currentLine` | component | `accent.default at 8% over bg.canvas` | editor |"))
        let themes = try JSONDecoder().decode([LumenTheme].self, from: Data(LumenExport.builtInThemesJSON(registry).utf8))
        XCTAssertEqual(themes.map(\.id), registry.builtInThemes.map(\.id))
    }
}

/// The example themes in Docs/examples show Lumen adapting to apps with their own identity; each
/// must load and pass every core check.
final class LumenExampleThemeTests: XCTestCase {
    static var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Docs/examples", directoryHint: .isDirectory)
    }

    func testExamplesPassTheCoreValidator() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.examples, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let theme = try JSONDecoder().decode(LumenTheme.self, from: Data(contentsOf: file))
                .flattened { LumenRegistry.core.theme(id: $0) }
            XCTAssertEqual(LumenValidator.issues(for: theme, in: .core).map { "\($0.appearance): \($0.message)" }, [], file.lastPathComponent)
        }
    }
}

/// Docs/reference is generated (`swift run lumen-theme export Docs/reference`); fail when it drifts.
final class LumenReferenceDriftTests: XCTestCase {
    func testCommittedReferenceMatchesTheCode() throws {
        let directory = LumenExampleThemeTests.examples.deletingLastPathComponent().appending(path: "reference")
        let registry = LumenRegistry.core
        let expected = [
            LumenExport.fileNames.themes: try LumenExport.builtInThemesJSON(registry),
            LumenExport.fileNames.schema: try LumenExport.themeSchemaJSON(registry),
            LumenExport.fileNames.reference: LumenExport.tokenReferenceMarkdown(registry),
        ]
        for (name, content) in expected {
            let committed = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
            XCTAssertEqual(committed, content, "\(name) is stale: run `swift run lumen-theme export Docs/reference`")
        }
    }
}

final class LumenReviewRegressionTests: XCTestCase {
    private func registry(_ specs: [LumenTokenSpec], themes: [LumenTheme] = [], values: [String: LumenThemeValues] = [:]) -> LumenRegistry {
        LumenRegistry(packs: [.core, LumenPack(id: "test", tokens: specs, themes: themes, themeValues: values)])
    }

    func testCoreMidnightAccentIsNotItsDangerColor() {
        let registry = LumenRegistry.core
        let midnight = registry.theme(id: LumenThemes.midnightID)!
        let accent = midnight.color(.accent, for: .dark, in: registry)
        let danger = midnight.color(.statusDanger, for: .dark, in: registry)
        XCTAssertGreaterThan(accent.perceptualDistance(to: danger), 0.06)
    }

    func testAnAccentThatMatchesAStatusIsFlagged() {
        let registry = LumenRegistry.core
        var midnight = registry.theme(id: LumenThemes.midnightID)!
        let accent = midnight.dark?[.accent]
        midnight.dark?[.statusDanger] = accent
        XCTAssertTrue(LumenValidator.issues(for: midnight, in: registry).contains { $0.message.contains("the accent from a status") })
    }

    func testDarkOnlyThemesAnswerInDarkWhateverTheAppearance() {
        let registry = registry([LumenTokenSpec("app.text", group: "App", contrast: [])],
                                values: [LumenThemes.standardID: LumenThemeValues(light: ["app.text": "#202020"], dark: ["app.text": "#EEEEEE"])])
        let ultraviolet = registry.theme(id: LumenThemes.ultravioletID)!
        XCTAssertEqual(ultraviolet.color("app.text", for: .light, in: registry), ultraviolet.color("app.text", for: .dark, in: registry))
        XCTAssertEqual(ultraviolet.color("app.text", for: .light, in: registry), "#EEEEEE")
    }

    func testThemeValuesReachAnInheritedVariant() {
        let child = LumenTheme(id: "app.child", name: "Child", inherits: LumenThemes.standardID, light: ["bg.canvas": "#FAFAFA"], dark: nil)
        let registry = registry([LumenTokenSpec("app.text", group: "App", contrast: [])], themes: [child],
                                values: ["app.child": LumenThemeValues(dark: ["app.text": "#EEEEEE"])])
        XCTAssertEqual(registry.theme(id: "app.child")!.color("app.text", for: .dark, in: registry), "#EEEEEE")
    }

    func testAChildThemeFileInheritsItsParentsColorSpace() throws {
        let data = Data(##"{"id":"c","name":"C","inherits":"lumen.midnight","dark":{"bg.canvas":"#000000"}}"##.utf8)
        let theme = try JSONDecoder().decode(LumenTheme.self, from: data)
        XCTAssertEqual(try theme.flattened { LumenRegistry.core.theme(id: $0) }.colorSpace, .displayP3)
        // Re-encoding keeps it unstated, so it keeps inheriting.
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(theme), as: UTF8.self).contains("colorSpace"))
    }

    func testAPartialThemeTakesTheDefaultThemesTunedComponentValues() throws {
        let data = Data(##"{"id":"a","name":"A","light":{"bg.canvas":"#FFFFFF"}}"##.utf8)
        let theme = try JSONDecoder().decode(LumenTheme.self, from: data)
        let registry = LumenRegistry.core
        let standard = registry.theme(id: LumenThemes.standardID)!
        XCTAssertEqual(theme.color(.activityBackground, for: .light, in: registry),
                       standard.color(.activityBackground, for: .light, in: registry))
        XCTAssertEqual(LumenValidator.issues(for: theme, in: registry).filter { $0.severity == .error }.map(\.message), [])
    }

    func testTranslucentGroundsAreMeasuredAsTheyAppear() {
        let registry = LumenRegistry.core
        var theme = registry.theme(id: LumenThemes.standardID)!
        theme.dark?[.bgSelected] = "#FFFFFF1A"
        let issues = LumenValidator.issues(for: theme, in: registry).filter { $0.message.contains("on bg.selected") }
        XCTAssertEqual(issues.map(\.message), [])
    }

    func testCompositingRespectsTheBasesOwnOpacity() {
        let tint: LumenColor = "#FFFFFF14"
        let result = tint.composited(alpha: 0.35, over: "#000000")
        XCTAssertLessThan(result.red, 0.03)
    }

    func testStrictHexAndSuggestions() {
        XCTAssertNil(LumenColor(hex: "#+12345"))
        XCTAssertNil(LumenColor(hex: "#-00000"))
        XCTAssertEqual(LumenValidator.suggestion(for: "bg.canvs", in: .core), .bgCanvas)
        XCTAssertNil(LumenValidator.suggestion(for: "totally.unrelated.name", in: .core))
    }

    func testThemesWithoutContrastPalettesReportEachIssueOnce() {
        let registry = LumenRegistry.core
        var theme = registry.theme(id: LumenThemes.midnightID)!
        theme.dark?[.fgTertiary] = "#20283F"
        let messages = LumenValidator.issues(for: theme, in: registry).map(\.message)
        XCTAssertEqual(messages.count, Set(messages).count)
    }

    func testUnknownTopLevelKeysAreFound() {
        let data = Data(##"{"id":"a","name":"A","darkHighcontrast":{},"$schema":"x","light":{}}"##.utf8)
        XCTAssertEqual(LumenTheme.unknownTopLevelKeys(in: data), ["darkHighcontrast"])
    }
}

final class LumenRenamedKeyTests: XCTestCase {
    private let registry = LumenRegistry(packs: [.core, LumenPack(id: "legacy", renamedKeys: ["background.canvas": .bgCanvas,
                                                                                                "text.primary": .fgPrimary])])

    func testLegacyKeysLoadAsTheirNewRoles() {
        let legacy = LumenTheme(id: "user.old", name: "Old", inherits: LumenThemes.standardID,
                                light: LumenPalette(colors: ["background.canvas": "#FAF8F0", "text.primary": "#101010", "fg.primary": "#202020"]),
                                dark: nil)
        let migrated = registry.migratingRenamedKeys(in: legacy)
        XCTAssertEqual(migrated.light?[.bgCanvas], "#FAF8F0")
        XCTAssertEqual(migrated.light?[.fgPrimary], "#202020", "A value under the new name wins")
        XCTAssertNil(migrated.light?.colors["background.canvas"])
    }

    func testTheValidatorPointsAtTheNewName() {
        let legacy = LumenTheme(id: "user.old", name: "Old", light: LumenPalette(colors: ["background.canvas": "#FAF8F0"]), dark: nil)
        let messages = LumenValidator.unknownKeyIssues(in: legacy, registry: registry).map(\.message)
        XCTAssertEqual(messages, ["“background.canvas” is now “bg.canvas”; it loads as that, but rename it in the file"])
    }
}

final class LumenSharedPackTests: XCTestCase {
    private let registry = LumenRegistry(packs: [.core, .code, .chart])

    func testEveryBuiltInThemePassesWithTheCodeAndChartPacks() {
        for theme in registry.builtInThemes {
            let issues = LumenValidator.issues(for: theme, in: registry).map { "\($0.appearance): \($0.message)" }
            XCTAssertEqual(issues, [], theme.name)
        }
    }

    func testPacksResolveForAThemeThatOnlySetsCoreColors() throws {
        let data = Data(##"{"id":"a","name":"A","inherits":"lumen.standard","dark":{"bg.canvas":"#101010"}}"##.utf8)
        let theme = try JSONDecoder().decode(LumenTheme.self, from: data).flattened { self.registry.theme(id: $0) }
        XCTAssertNotEqual(theme.color(LumenToken.Code.keyword, for: .dark, in: registry), "#FFFFFF")
        XCTAssertEqual(theme.color(LumenToken.Code.selection, for: .dark, in: registry), theme.color(.bgSelected, for: .dark, in: registry))
    }

    func testTheCodePackUsesTheKeysAppsAlreadyUse() {
        XCTAssertEqual(LumenToken.Code.keyword.rawValue, "syntax.keyword")
        XCTAssertEqual(LumenToken.Chart.series.map(\.rawValue).first, "chart.series1")
    }
}

final class LumenBrandedExportTests: XCTestCase {
    func testAnAppBrandNamesItsFilesAndExportsItsGalleryThemes() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "lumen-brand-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = LumenRegistry(packs: [.core, LumenPack(id: "app", hidesThemes: [LumenThemes.contrastID])])
        try LumenExport.write(registry, to: folder, brand: .app("MacScope"))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["builtin-themes.json", "macscope-theme.schema.json", "token-reference.md"])
        let schema = try String(contentsOf: folder.appending(path: "macscope-theme.schema.json"), encoding: .utf8)
        XCTAssertTrue(schema.contains("\"title\" : \"MacScope theme\""))
        let themes = try JSONDecoder().decode([LumenTheme].self, from: Data(contentsOf: folder.appending(path: "builtin-themes.json")))
        XCTAssertFalse(themes.contains { $0.id == LumenThemes.contrastID }, "Only the themes the app offers")
        XCTAssertTrue(try String(contentsOf: folder.appending(path: "token-reference.md"), encoding: .utf8).hasPrefix("# MacScope colors"))
    }
}

final class LumenRetiredKeyTests: XCTestCase {
    private var registry: LumenRegistry {
        var pack = LumenPack(id: "legacy", renamedKeys: ["text.primary": .fgPrimary])
        pack.retiredKeys = ["graph.edge.call", "welcome.accent"]
        return LumenRegistry(packs: [.core, pack])
    }

    func testRetiredKeysLoadQuietly() {
        let old = LumenTheme(id: "user.old", name: "Old", inherits: LumenThemes.standardID,
                             light: LumenPalette(colors: ["graph.edge.call": "#123456", "welcome.accent": "#654321", "grpah.edge": "#000000"]),
                             dark: nil)
        let messages = LumenValidator.unknownKeyIssues(in: old, registry: registry).map(\.message)
        XCTAssertEqual(messages.count, 1, "Only the typo is reported: \(messages)")
        XCTAssertTrue(messages.first?.contains("grpah.edge") == true)
    }

    func testSchemaListsRetiredAndRenamedKeysAsDeprecated() throws {
        let json = try LumenExport.themeSchemaJSON(registry)
        XCTAssertTrue(json.contains("\"graph.edge.call\""))
        XCTAssertTrue(json.contains("Retired; ignored when loading."))
        XCTAssertTrue(json.contains("Renamed; loads as fg.primary."))
    }
}

/// The store's system-accent mode, checked like any theme: every macOS accent, in every built-in
/// theme, keeps each accent-following pair readable (CODE-02, CODE-21, T-19).
final class LumenSystemAccentTests: XCTestCase {
    private let registry = LumenRegistry(packs: [.core, .code])
    /// macOS accent colors, light and dark (Apple's published system colors; Multicolor keeps the theme's).
    private let accents: [(name: String, light: LumenColor, dark: LumenColor)] = [
        ("blue", "#007AFF", "#0A84FF"), ("purple", "#AF52DE", "#BF5AF2"), ("pink", "#FF2D55", "#FF375F"),
        ("red", "#FF3B30", "#FF453A"), ("orange", "#FF9500", "#FF9F0A"), ("yellow", "#FFCC00", "#FFD60A"),
        ("green", "#28CD41", "#32D74B"), ("graphite", "#8E8E93", "#98989D"),
    ]

    func testEveryAccentKeepsAccentFollowingPairsReadable() {
        for theme in registry.builtInThemes {
            for accent in accents {
                let derived = theme.withSystemAccent(light: accent.light, dark: accent.dark, in: registry)
                // Errors are contrast failures; a green accent near the success color is a warning the
                // user chose, not a legibility problem.
                let errors = LumenValidator.issues(for: derived, in: registry).filter { $0.severity == .error }
                    .map { "\($0.appearance): \($0.message)" }
                XCTAssertEqual(errors, [], "\(theme.name) with the \(accent.name) accent")
            }
        }
    }

    func testFilledShapesAreDeepUnderWhiteTextAndChipLabelsRead() {
        let standard = registry.theme(id: LumenThemes.standardID)!
        let blue: LumenColor = "#0A84FF"
        for token in [LumenToken.menuHighlight, .accentFilled, .chipSelectedBackground] {
            let fill = standard.color(token, for: .dark, in: registry, systemAccent: blue)
            XCTAssertLessThan(fill.relativeLuminance, blue.relativeLuminance, "\(token) is a deep tone, not the bright accent")
        }
        for (text, ground) in [(LumenToken.menuHighlightForeground, LumenToken.menuHighlight), (.accentFilledForeground, .accentFilled),
                               (.chipSelectedForeground, .chipSelectedBackground)] {
            let ink = standard.color(text, for: .dark, in: registry, systemAccent: blue)
            XCTAssertEqual(ink, "#FFFFFF", "\(text)")
            XCTAssertGreaterThanOrEqual(ink.contrastRatio(against: standard.color(ground, for: .dark, in: registry, systemAccent: blue)), 4.5)
        }
        // The selection and a field's tint follow the accent too, not the theme's violet.
        let selected = standard.color(.bgSelected, for: .light, in: registry, systemAccent: "#007AFF")
        XCTAssertGreaterThan(selected.blue, selected.red)
        let field = standard.color(.fieldBackground, for: .light, in: registry, systemAccent: "#28CD41")
        XCTAssertGreaterThan(field.green, field.red)
        XCTAssertGreaterThan(field.green, field.blue)
    }
}

/// Raised grounds swap by where a value comes from, never by comparing colors (CODE-03, L5).
final class LumenRaisedTests: XCTestCase {
    private let registry = LumenRegistry.core

    func testKeycapsHoverAndInactiveSelectionTakeTheRaisedRoles() {
        let standard = registry.theme(id: LumenThemes.standardID)!
        let raised = { standard.raisedColor($0, for: .dark, in: self.registry) }
        let plain = { standard.color($0, for: .dark, in: self.registry) }
        XCTAssertEqual(raised(.bgInset), plain(.bgInsetRaised))
        XCTAssertEqual(raised(.keycapBackground), plain(.bgInsetRaised), "the keycap follows bg.inset, so it swaps with it")
        XCTAssertEqual(raised(.bgHover), plain(.bgHoverRaised))
        XCTAssertEqual(raised(.sidebarRowHover), plain(.bgHoverRaised))
        XCTAssertEqual(raised(.bgSelectedInactive), plain(.bgSelectedInactiveRaised))
        XCTAssertEqual(raised(.bgInsetRaised), plain(.bgInsetRaised))
        XCTAssertEqual(raised(.bgCanvas), plain(.bgCanvas))
        // A theme that sets its own keycap keeps it on raised grounds, even when it equals bg.inset.
        var custom = standard
        custom.dark?[.keycapBackground] = standard.dark?[.bgInset]
        XCTAssertEqual(custom.raisedColor(.keycapBackground, for: .dark, in: registry), plain(.bgInset))
        XCTAssertTrue(registry.raisedTokens.contains(.keycapBackground))
        XCTAssertFalse(registry.raisedTokens.contains(.fgPrimary))
    }
}

/// The visibility, lift and composite rules catch the values they were written for.
final class LumenVisibilityRuleTests: XCTestCase {
    private let registry = LumenRegistry(packs: [.core, .code])

    private func messages(_ theme: LumenTheme, dark: Bool = true) -> [String] {
        LumenValidator.issues(for: theme, in: registry).filter { $0.appearance.isDark == dark && !$0.appearance.isHighContrast }.map(\.message)
    }

    func testVisibilityRulesCatchTheReviewedValues() {
        var ultraviolet = registry.theme(id: LumenThemes.ultravioletID)!
        ultraviolet.dark?[.bgInset] = "#22182F"                 // a hole in the sidebar (T-03)
        ultraviolet.dark?[.accentSubtle] = "#3B2559"            // find highlight = selection (T-11)
        ultraviolet.dark?[.bgSelectedInactive] = "#2D2340"      // inactive selection = hover (T-08)
        let uv = messages(ultraviolet)
        XCTAssertTrue(uv.contains("bg.inset is darker than bg.sidebar it sits on; in dark, nested grounds step lighter"), "\(uv)")
        XCTAssertTrue(uv.contains { $0.contains("accent.subtle and bg.selected are too alike") }, "\(uv)")
        XCTAssertTrue(uv.contains("An inactive selection looks like a hovered row"), "\(uv)")

        var midnight = registry.theme(id: LumenThemes.midnightID)!
        midnight.dark?[.borderSubtle] = "#141D3A"               // invisible separators (T-04)
        midnight.dark?[.bgHoverRaised] = "#16213F"              // hover invisible on cards (T-01)
        midnight.dark?[.borderControl] = "#2E3B63"              // unchecked boxes vanish (A-07)
        let mid = messages(midnight)
        XCTAssertTrue(mid.contains("Menu separators are hard to see"), "\(mid)")
        XCTAssertTrue(mid.contains("Hover is hard to see on cards, popovers and sheets"), "\(mid)")
        XCTAssertTrue(mid.contains { $0.hasPrefix("border.control on bg.insetRaised") }, "\(mid)")

        var standard = registry.theme(id: LumenThemes.standardID)!
        standard.light?[.menuHighlight] = "#6757D0"             // 82% letters and keycaps under 4.5 (T-09)
        standard.light?[.statusNeutralBackground] = "#EDEEEF"  // tags vanish on the window (T-06)
        let light = messages(standard, dark: false)
        XCTAssertTrue(light.contains { $0.hasPrefix("menu.highlightForeground at 82% on menu.highlight") }, "\(light)")
        XCTAssertTrue(light.contains { $0.hasPrefix("accent.filledForeground on a keycap on accent.filled") }, "\(light)")
        XCTAssertTrue(light.contains("Neutral tags are hard to see on the window ground"), "\(light)")
    }

    func testTheCurrentLineMustShowAndMoreSoInContrastThemes() {
        var contrast = registry.theme(id: LumenThemes.contrastID)!
        contrast.dark?[LumenToken.Code.currentLine] = "#0D0C12"   // 7% accent over black (A-04)
        XCTAssertTrue(messages(contrast).contains { $0.hasPrefix("The current line on bg.canvas") })
        contrast.dark?[LumenToken.Code.currentLine] = "#161616"   // about 1.15:1: enough for a plain theme only
        XCTAssertTrue(messages(contrast).contains { $0.hasPrefix("The current line") })
        contrast.isHighContrast = false
        XCTAssertFalse(messages(contrast).contains { $0.hasPrefix("The current line") })
    }

    func testHighContrastIsDeclaredInheritedAndRoundTrips() throws {
        XCTAssertTrue(registry.theme(id: LumenThemes.contrastID)!.isHighContrast)
        XCTAssertFalse(registry.theme(id: LumenThemes.standardID)!.isHighContrast)
        let child = try JSONDecoder().decode(LumenTheme.self, from: Data(#"{"id":"c","name":"C","inherits":"lumen.contrast","dark":{}}"#.utf8))
        XCTAssertTrue(try child.flattened { self.registry.theme(id: $0) }.isHighContrast, "inherited from Contrast")
        let optOut = try JSONDecoder().decode(LumenTheme.self, from: Data(#"{"id":"c","name":"C","inherits":"lumen.contrast","highContrast":false}"#.utf8))
        XCTAssertFalse(try optOut.flattened { self.registry.theme(id: $0) }.isHighContrast)
        let encoded = String(decoding: try JSONEncoder().encode(registry.theme(id: LumenThemes.contrastID)!), as: UTF8.self)
        XCTAssertTrue(encoded.contains("\"highContrast\":true"), encoded)
        XCTAssertTrue(LumenTheme.unknownTopLevelKeys(in: Data(#"{"id":"a","name":"A","highContrast":true}"#.utf8)).isEmpty)
    }

    /// D35: an imported theme file can carry an alpha byte on any key; a translucent foreground is
    /// an error (contrast can't be established for it), whatever its ratio would be.
    func testAnImportedThemeWithTranslucentTextIsRejected() throws {
        let data = Data(##"{"schemaVersion":1,"id":"user.ghost","name":"Ghost","inherits":"lumen.standard","light":{"fg.secondary":"#4A516280"}}"##.utf8)
        let theme = try JSONDecoder().decode(LumenTheme.self, from: data).flattened { self.registry.theme(id: $0) }
        let errors = LumenValidator.issues(for: theme, in: registry).filter { $0.severity == .error && !$0.appearance.isDark }
        XCTAssertTrue(errors.contains { $0.message == "fg.secondary must be opaque (it is 50%): contrast can't be established for translucent text" },
                      "\(errors.map(\.message))")
    }

    /// ARCHITECTURE: a translucent color in a pack's pair rule is measured composited over its ground
    /// (D16). 50% white over black is about 5.3:1, so a 7:1 pair rule must report exactly that ratio.
    func testATranslucentForegroundInAPairRuleIsMeasuredComposited() {
        let pack = LumenPack(id: "test", tokens: [LumenTokenSpec("app.ghost", group: "App", fallback: .token(.fgPrimary))],
                             themeValues: [LumenThemes.contrastID: LumenThemeValues(dark: ["app.ghost": "#FFFFFF80"])],
                             rules: [LumenContrastPairsRule(["app.ghost"], on: [.bgCanvas], minimum: 7)])
        let registry = LumenRegistry(packs: [.core, pack])
        let contrast = registry.theme(id: LumenThemes.contrastID)!
        let ghost = LumenValidator.issues(for: contrast, in: registry).filter { $0.token == "app.ghost" && $0.appearance.isDark }.map(\.message)
        let composited = LumenColor("#FFFFFF80").over("#000000").contrastRatio(against: "#000000")
        XCTAssertLessThan(composited, 7)
        XCTAssertEqual(ghost, ["app.ghost on bg.canvas is \(LumenValidator.format(composited)):1; needs 7:1"])
    }
}
