import Foundation
import XCTest
@testable import LumenTokens

/// Regressions in color math, fallback resolution, the validator and the system-accent derivation.
final class LumenColorMathTests: XCTestCase {
    let registry = LumenRegistry.core

    private var standardLight: LumenPalette { registry.theme(id: LumenThemes.standardID)!.light! }
    private var standardDark: LumenPalette { registry.theme(id: LumenThemes.standardID)!.dark! }

    // MARK: Display P3

    func testDisplayP3ComponentsAreMeasuredAsDisplayP3() {
        let red: LumenColor = "#ED0000", white: LumenColor = "#FFFFFF"
        XCTAssertEqual(red.contrastRatio(against: white), 4.5643, accuracy: 0.0005)
        XCTAssertEqual(red.contrastRatio(against: white, in: .displayP3), 4.3048, accuracy: 0.0005)
        // Neutrals are the same color in both spaces.
        let gray: LumenColor = "#777777"
        XCTAssertEqual(gray.relativeLuminance(in: .displayP3), gray.relativeLuminance, accuracy: 1e-6)
        XCTAssertEqual(gray.perceptualDistance(to: white, in: .displayP3), gray.perceptualDistance(to: white), accuracy: 1e-6)
        // P3 red is outside sRGB: farther from sRGB red than the same digits read as sRGB.
        XCTAssertGreaterThan(LumenColor("#FF0000").perceptualDistance(to: "#00FF00", in: .displayP3),
                             LumenColor("#FF0000").perceptualDistance(to: "#00FF00"))
    }

    func testTheValidatorMeasuresADisplayP3ThemeInDisplayP3() {
        var light = standardLight
        light[.bgCanvas] = "#FFFFFF"
        light[.fgLink] = "#ED0000"
        func linkOnCanvas(_ space: LumenColorSpace) -> [String] {
            LumenValidator.issues(for: LumenTheme(id: "test.p3", name: "P3", colorSpace: space, light: light, dark: nil), in: registry)
                .filter { $0.token == .fgLink && $0.message.hasPrefix("fg.link on bg.canvas") }.map(\.message)
        }
        XCTAssertEqual(linkOnCanvas(.sRGB), [])
        XCTAssertEqual(linkOnCanvas(.displayP3), ["fg.link on bg.canvas is 4.30:1; needs 4.50:1"])
    }

    // MARK: Fallback resolution

    func testASharedFallbackDependencyIsNotACycle() {
        let probe = LumenToken("test.probe")
        let pack = LumenPack(id: "test", tokens: [
            LumenTokenSpec(probe, group: "Test", fallback: .composite(.keycapBackground, alpha: 0.5, over: .keycapBackground)),
        ])
        let registry = LumenRegistry(packs: [.core, pack])
        let theme = registry.theme(id: LumenThemes.standardID)!
        XCTAssertEqual(theme.color(probe, for: .dark, in: registry).hexString, "#21242C")
    }

    // MARK: Compositing

    func testOverIsSourceOverOnATranslucentDestination() {
        let red = LumenColor(hex: "#FF000080")!
        let onClear = red.over(LumenColor(hex: "#0000FF00")!)
        XCTAssertEqual(onClear.alpha, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(onClear.red, 1, accuracy: 1e-9)
        XCTAssertEqual(onClear.blue, 0, accuracy: 1e-9)
        // Opaque destinations composite as before.
        let onBlue = red.over("#0000FF")
        XCTAssertEqual(onBlue.alpha, 1)
        XCTAssertEqual(onBlue.hexString, "#80007F")
        // No jump at full opacity: a nearly opaque source over a half-clear ground is nearly itself.
        let nearly = LumenColor(red: 1, green: 0, blue: 0, alpha: 0.999).over(LumenColor(red: 0, green: 0, blue: 1, alpha: 0.5))
        XCTAssertEqual(nearly.red, 1, accuracy: 0.002)
        XCTAssertEqual(nearly.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(LumenColor(hex: "#00000000")!.over(LumenColor(hex: "#FFFFFF00")!).alpha, 0)
    }

    // MARK: Validator

    func testForegroundContrastIsCheckedOnRaisedGroundsToo() {
        var dark = standardDark
        dark[.keycapForeground] = "#8B8B8B"
        let issues = LumenValidator.issues(for: LumenTheme(id: "test.keycap", name: "Keycap", light: nil, dark: dark), in: registry)
            .filter { $0.token == .keycapForeground }.map(\.message)
        XCTAssertEqual(issues, ["keycap.foreground on keycap.background on a raised ground is 3.92:1; needs 4.50:1"])
    }

    func testDistinctnessComparesTheColorsAsDrawn() {
        let first = LumenToken("test.first"), second = LumenToken("test.second")
        let rule = LumenDistinctRule([first, second], noun: "tests")
        let pack = LumenPack(id: "test", tokens: [LumenTokenSpec(first, group: "Test"), LumenTokenSpec(second, group: "Test")],
                             rules: [rule])
        let registry = LumenRegistry(packs: [.core, pack])
        var light = standardLight
        light[first] = "#FF0000"
        light[second] = "#0000FF"
        XCTAssertEqual(rule.issues(in: LumenTheme(id: "test.d", name: "D", light: light, dark: nil), appearance: .light, registry: registry), [])
        light[first] = LumenColor(hex: "#FF000000")!
        light[second] = LumenColor(hex: "#0000FF00")!
        XCTAssertEqual(rule.issues(in: LumenTheme(id: "test.d", name: "D", light: light, dark: nil), appearance: .light, registry: registry)
            .map(\.message), ["test.first and test.second are too alike to tell tests apart"])
    }

    func testATranslucentFloatingGroundIsMeasuredOverAnyBackdrop() {
        var dark = standardDark
        dark[.menuForeground] = "#FFFFFF"
        dark[.menuBackground] = LumenColor(hex: "#00000080")!
        dark[.bgCanvas] = "#000000"
        let issues = LumenValidator.issues(for: LumenTheme(id: "test.menu", name: "Menu", light: nil, dark: dark), in: registry)
            .filter { $0.token == .menuForeground }.map(\.message)
        XCTAssertEqual(issues, ["menu.foreground on menu.background is 4.00:1; needs 4.50:1"])
    }

    func testATranslucentGroundIsLaidOverTheGroundThatHoldsIt() {
        var dark = standardDark
        dark[.bgInsetRaised] = LumenColor(hex: "#FFFFFF1A")!
        let theme = LumenTheme(id: "test.well", name: "Well", light: nil, dark: dark)
        let well = LumenColor(hex: "#FFFFFF1A")!
        // A well on a card sits on the card, not the canvas.
        XCTAssertEqual(LumenValidator.opaqueGround(.bgInsetRaised, in: theme, appearance: .dark, registry: registry),
                       well.over(dark[.bgElevated]!))
        // An app token that falls back to a held ground sits where that ground does.
        let row = LumenToken("test.row")
        let pack = LumenPack(id: "test", tokens: [LumenTokenSpec(row, group: "Test", fallback: .token(.sidebarRowHover))])
        let registry = LumenRegistry(packs: [.core, pack])
        dark[row] = well
        let withRow = LumenTheme(id: "test.well", name: "Well", light: nil, dark: dark)
        XCTAssertEqual(LumenValidator.opaqueGround(row, in: withRow, appearance: .dark, registry: registry),
                       well.over(dark[.bgSidebar]!))
    }

    // MARK: System accent

    func testTheSystemAccentLightensOnADarkSurfaceOfALightTheme() {
        var light = standardLight
        light[.sidebarBackground] = "#505050"
        let theme = LumenTheme(id: "test.sidebar", name: "Sidebar", light: light, dark: nil)
        let accent = theme.color(.sidebarAccent, for: .light, in: registry, systemAccent: "#007AFF")
        XCTAssertGreaterThanOrEqual(accent.contrastRatio(against: "#505050"), 3)
        // On the light canvas the accent still darkens, as before.
        let onCanvas = theme.color(.accent, for: .light, in: registry, systemAccent: "#007AFF")
        XCTAssertLessThan(onCanvas.relativeLuminance, LumenColor("#007AFF").relativeLuminance + 1e-9)
    }

    /// A translucent ground is measured where it's drawn: a sidebar over the window's own white,
    /// not over a dark canvas, so the derived accent meets 3:1 on the sidebar as it appears.
    func testTheSystemAccentMeetsATranslucentGroundOverTheGroundThatHoldsIt() {
        var light = standardLight
        light[.bgCanvas] = "#202020"
        light[.sidebarBackground] = "#00000099"
        let theme = LumenTheme(id: "test.translucent", name: "Translucent", light: light, dark: nil)
        let sidebar = LumenValidator.opaqueGround(.sidebarBackground, in: theme, appearance: .light, registry: registry)
        XCTAssertLessThan(LumenColor("#007AFF").contrastRatio(against: sidebar), 3, "the stock accent fails where it's drawn")
        let accent = theme.color(.sidebarAccent, for: .light, in: registry, systemAccent: "#007AFF")
        XCTAssertGreaterThanOrEqual(accent.contrastRatio(against: sidebar), 3)
    }

    /// A sidebar that sets its own text needs its own inactive selection: the validator checks that
    /// text on `sidebar.rowSelectedInactive`, which otherwise falls back to the quiet canvas one.
    func testSidebarTextIsCheckedOnTheInactiveSidebarSelection() {
        var light = standardLight
        light[.sidebarBackground] = "#1F2430"
        light[.sidebarRowSelected] = "#313A4D"
        light[.sidebarForeground] = "#ECEFF4"
        light[.sidebarSecondaryForeground] = "#AEB6C4"
        let unset = LumenTheme(id: "test.slate", name: "Slate", light: light, dark: nil)
        XCTAssertTrue(LumenValidator.issues(for: unset, in: registry).contains { $0.message.contains("sidebar.foreground on sidebar.rowSelectedInactive") })
        light[.sidebarRowSelectedInactive] = "#353A45"
        let set = LumenTheme(id: "test.slate", name: "Slate", light: light, dark: nil)
        XCTAssertFalse(LumenValidator.issues(for: set, in: registry).contains { $0.message.contains("rowSelectedInactive") })
    }

    // MARK: Registry and themes

    func testSurfacesDeclaredByTwoPacksMerge() {
        let editor = LumenSurface("editor")
        let registry = LumenRegistry(packs: [.core, LumenPack(id: "a", surfaces: [editor]), LumenPack(id: "b", surfaces: [.window, editor])])
        XCTAssertEqual(registry.surfaces, [.window, editor])
    }

    func testSwiftAndJSONChildThemesInheritTheirColorSpaceAlike() throws {
        let lookup: (String) -> LumenTheme? = { self.registry.theme(id: $0) }
        let swift = LumenTheme(id: "test.child", name: "Child", inherits: LumenThemes.midnightID, light: nil, dark: nil)
        let json = try JSONDecoder().decode(LumenTheme.self, from: Data(#"{"id": "test.child", "name": "Child", "inherits": "lumen.midnight"}"#.utf8))
        XCTAssertEqual(try swift.flattened(lookup: lookup).colorSpace, .displayP3)
        XCTAssertEqual(try json.flattened(lookup: lookup).colorSpace, .displayP3)
        XCTAssertEqual(swift, json)
        // A root theme that doesn't say is sRGB, and saying so still overrides a parent.
        XCTAssertEqual(LumenTheme(id: "test.root", name: "Root", light: [:], dark: nil).colorSpace, .sRGB)
        let explicit = LumenTheme(id: "test.child", name: "Child", colorSpace: .sRGB, inherits: LumenThemes.midnightID, light: nil, dark: nil)
        XCTAssertEqual(try explicit.flattened(lookup: lookup).colorSpace, .sRGB)
    }
}

final class LumenRaisedResolutionTests: XCTestCase {
    func testARaisedRoleTheThemeLeavesOutIsItsPlainRoleOnARaisedGround() {
        // Standard light sets bg.inset but not bg.insetRaised: on a card the raised role is bg.inset,
        // not the black last resort it resolved to on ec8e145.
        let registry = LumenRegistry.core
        let theme = registry.theme(id: LumenThemes.standardID)!
        for (plain, raised) in LumenTheme.raisedSubstitutions {
            XCTAssertNil(theme.light?[raised])
            XCTAssertEqual(theme.raisedColor(raised, for: .light, in: registry), theme.color(plain, for: .light, in: registry), raised.rawValue)
            XCTAssertEqual(theme.raisedColor(plain, for: .light, in: registry), theme.color(plain, for: .light, in: registry), plain.rawValue)
        }
        // Where the theme sets the raised role, the plain role swaps to it.
        XCTAssertEqual(theme.raisedColor(.bgInset, for: .dark, in: registry).hexString, "#2B2F3A")
        XCTAssertEqual(theme.raisedColor(.keycapBackground, for: .dark, in: registry).hexString, "#2B2F3A")
    }
}
