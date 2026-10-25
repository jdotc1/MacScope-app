import AppKit
import Observation
import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

final class LumenThemeStoreTests: XCTestCase {
    func testStoreSelectsKnownThemesOnlyAndResolvesDynamicColors() throws {
        let store = TestPack.store()
        XCTAssertEqual(store.theme().id, LumenThemes.standardID, "The registry's default theme")
        store.select(LumenThemes.midnightID)
        XCTAssertEqual(store.theme().id, LumenThemes.midnightID)
        store.select("not.a.theme")
        store.select(nil)
        XCTAssertEqual(store.theme().id, LumenThemes.midnightID, "Unknown ids and nil leave the window theme alone")

        // Midnight is Display P3: its hex digits are P3 components.
        let canvas = try resolve(store.nsColor(.bgCanvas), in: .darkAqua, space: .displayP3)
        XCTAssertEqual(canvas.redComponent, 0x08 / 255, accuracy: 0.002)
        XCTAssertEqual(canvas.blueComponent, 0x24 / 255, accuracy: 0.002)
    }

    func testColorsFollowLightAndDarkAtDrawTime() throws {
        let store = TestPack.store()
        let primary = store.nsColor(.fgPrimary)
        XCTAssertEqual(try hex(primary, in: .aqua), "#1B1E26")
        XCTAssertEqual(try hex(primary, in: .darkAqua), "#DDE3EC")
        // Increase Contrast can't be exercised here: AppKit returns plain Aqua for
        // `NSAppearance(named: .accessibilityHighContrastAqua)` and applies the high-contrast
        // variant only when the system setting is on. LumenTokens tests cover the palette choice.
    }

    func testSelectingAThemeInvalidatesObservers() {
        let store = TestPack.store()
        let flag = Flag()
        withObservationTracking {
            _ = store.color(.bgCanvas)
        } onChange: {
            flag.fire()
        }
        store.select(LumenThemes.contrastID)
        XCTAssertEqual(flag.count, 1)
    }

    func testTokensResolveThroughTheirSurfacesTheme() throws {
        let store = TestPack.store()
        XCTAssertTrue(store.surfaceFollowsWindow(TestPack.editor))
        XCTAssertNil(store.forcedAppearance(for: TestPack.editor))
        XCTAssertEqual(store.theme(for: TestPack.editor).id, LumenThemes.standardID)

        store.select(LumenThemes.midnightID, for: TestPack.editor)
        XCTAssertFalse(store.surfaceFollowsWindow(TestPack.editor))
        XCTAssertEqual(store.theme(for: TestPack.editor).id, LumenThemes.midnightID)
        XCTAssertEqual(store.theme().id, LumenThemes.standardID, "The window keeps its own theme")
        XCTAssertEqual(store.forcedAppearance(for: TestPack.editor), .dark, "Midnight is dark only")
        XCTAssertNil(store.forcedAppearance(for: .window))

        // The editor's token comes from Midnight; window roles stay with the standard theme.
        XCTAssertEqual(try hex(store.nsColor(TestPack.keyword), in: .darkAqua, space: .displayP3), "#E532AD")
        XCTAssertEqual(try hex(store.nsColor(.bgSidebar), in: .darkAqua), "#1C1F26")

        store.select(nil, for: TestPack.editor)
        XCTAssertTrue(store.surfaceFollowsWindow(TestPack.editor))
        XCTAssertEqual(try hex(store.nsColor(TestPack.keyword), in: .darkAqua), "#F28FD0", "Back to the window theme's value")

        store.select(LumenThemes.midnightID, for: LumenSurface("not-declared"))
        XCTAssertEqual(store.paletteKey.themeIDs.count, 2, "Surfaces the registry doesn't declare are ignored")
    }

    func testAForcedWindowThemeIsReported() {
        let store = TestPack.store()
        store.select(LumenThemes.midnightID)
        XCTAssertEqual(store.forcedAppearance(for: .window), .dark)
        XCTAssertNil(store.forcedAppearance(for: TestPack.editor), "A following surface inherits the window's appearance")
    }

    func testStoresThatDoNotPersistNeverReadOrWriteSavedChoices() throws {
        let suite = "lumen-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let configuration = LumenStoreConfiguration(appName: "LumenTests", themesDirectory: URL(fileURLWithPath: "/dev/null/x"),
                                                    defaultsSuiteName: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(LumenThemes.midnightID, forKey: configuration.selectionDefaultsKey(for: .window))
        defaults.set(true, forKey: configuration.systemAccentDefaultsKey)

        let ephemeral = LumenThemeStore(registry: TestPack.registry, configuration: configuration,
                                        themes: TestPack.registry.galleryThemes, persistsSelection: false)
        XCTAssertEqual(ephemeral.theme().id, LumenThemes.standardID, "Tests and previews start from the default on every Mac")
        XCTAssertFalse(ephemeral.usesSystemAccent)
        ephemeral.select(LumenThemes.contrastID)
        XCTAssertEqual(defaults.string(forKey: configuration.selectionDefaultsKey(for: .window)), LumenThemes.midnightID)

        let persisting = LumenThemeStore(registry: TestPack.registry, configuration: configuration,
                                         themes: TestPack.registry.galleryThemes)
        XCTAssertEqual(persisting.theme().id, LumenThemes.midnightID, "A persisting store restores the saved choice")
        XCTAssertTrue(persisting.usesSystemAccent)
    }

    func testPersistingStoresSaveUnderTheAppsPrefix() throws {
        let suite = "lumen-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let configuration = LumenStoreConfiguration(appName: "TestApp", themesDirectory: URL(fileURLWithPath: "/dev/null/x"),
                                                    defaultsSuiteName: suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = LumenThemeStore(registry: TestPack.registry, configuration: configuration, themes: TestPack.registry.galleryThemes)

        store.select(LumenThemes.contrastID)
        store.select(LumenThemes.midnightID, for: TestPack.editor)
        store.setUsesSystemAccent(true)
        XCTAssertEqual(defaults.string(forKey: "TestApp.lumen.theme"), LumenThemes.contrastID)
        XCTAssertEqual(defaults.string(forKey: "TestApp.lumen.theme.editor"), LumenThemes.midnightID)
        XCTAssertTrue(defaults.bool(forKey: "TestApp.lumen.usesSystemAccent"))
        XCTAssertEqual(configuration.densityDefaultsKey, "TestApp.lumen.density")

        store.select(nil, for: TestPack.editor)
        XCTAssertNil(defaults.string(forKey: "TestApp.lumen.theme.editor"), "Following the window clears the saved choice")
        XCTAssertEqual(configuration.resolvedThemesDirectory.path, "/dev/null/x")
        XCTAssertTrue(LumenStoreConfiguration(appName: "TestApp").resolvedThemesDirectory.path
            .hasSuffix("Library/Application Support/TestApp/Themes"))
    }

    func testHiddenBuiltInsLeaveTheListButStillResolveAsParents() throws {
        let branded = LumenPack(id: "test.brand",
                                themes: [LumenTheme(id: "test.brand.scope", name: "Scope", inherits: LumenThemes.standardID,
                                                    light: [.accent: "#0B6E73"], dark: nil)],
                                hidesThemes: [LumenThemes.standardID])
        let registry = LumenRegistry(packs: [.core, branded])
        let folder = try temporaryFolder()
        try write(##"{"id": "user.calm", "name": "Calm", "inherits": "lumen.standard", "light": {"accent.default": "#2F6FDE"}}"##,
                  "calm.json", in: folder)
        let store = TestPack.store(registry: registry, folder: folder)

        XCTAssertEqual(store.themes.map(\.id), [LumenThemes.midnightID, LumenThemes.ultravioletID, LumenThemes.contrastID, "test.brand.scope", "user.calm"])
        XCTAssertEqual(store.defaultThemeID, LumenThemes.midnightID, "A hidden default falls back to the first offered theme")
        XCTAssertEqual(store.theme().id, LumenThemes.midnightID)
        store.select(LumenThemes.standardID)
        XCTAssertEqual(store.theme().id, LumenThemes.midnightID, "Hidden themes can't be chosen")
        XCTAssertEqual(store.themes.first { $0.id == "user.calm" }?.color(.bgCanvas, for: .light, in: registry).hexString, "#FFFFFF",
                       "User themes may still inherit a hidden built-in")
    }

    func testTheConfiguredDefaultThemeIsUsedWhenOffered() {
        let store = LumenThemeStore(registry: TestPack.registry,
                                    configuration: LumenStoreConfiguration(appName: "LumenTests", defaultThemeID: LumenThemes.contrastID),
                                    themes: TestPack.registry.galleryThemes, persistsSelection: false)
        XCTAssertEqual(store.theme().id, LumenThemes.contrastID)
    }

    func testScopedActiveStoreIsRestoredAfterwards() throws {
        let before = LumenThemeStore.active
        let store = TestPack.store()
        store.select(LumenThemes.midnightID)
        let inside = LumenThemeStore.withActiveStore(store) { () -> String in
            XCTAssertTrue(LumenThemeStore.active === store)
            return Lumen.theme().id
        }
        XCTAssertEqual(inside, LumenThemes.midnightID)
        XCTAssertTrue(LumenThemeStore.active === before, "The scoped override is removed")
        XCTAssertTrue(LumenThemeStore.shared === before, "Without install, shared is the core fallback store")
        XCTAssertFalse(LumenThemeStore.shared.persistsSelection, "The fallback never touches user defaults")
    }

    @MainActor
    func testChangesPostTheNotificationOnTheMainActor() {
        let store = TestPack.store()
        let posted = expectation(forNotification: LumenThemeStore.didChangeNotification, object: store)
        store.select(LumenThemes.contrastID)
        wait(for: [posted], timeout: 2)
    }

    @MainActor
    func testASurfaceKeepsTheStoreInjectedAboveIt() {
        let injected = TestPack.store()
        injected.select(LumenThemes.midnightID)
        let seen = LumenLock<(store: UUID?, theme: String?)>((nil, nil))
        struct Probe: View {
            let seen: LumenLock<(store: UUID?, theme: String?)>
            @Environment(\.lumenStore) private var store
            @Environment(\.lumenPalette) private var palette
            var body: some View {
                seen.withLock { $0 = (store.identity, palette.key.themeIDs[.window]) }
                return Color.clear.frame(width: 4, height: 4)
            }
        }
        let view = LumenThemeStore.withActiveStore(TestPack.store()) {
            Probe(seen: seen).lumenSurface(TestPack.editor).lumenPaletteRoot(store: injected, windowChrome: false)
        }
        _ = ImageRenderer(content: view).cgImage
        XCTAssertEqual(seen.withLock { $0.store }, injected.identity, "A surface inside a root resolves through that root's store")
        XCTAssertEqual(seen.withLock { $0.theme }, LumenThemes.midnightID)
    }

    func testAPersistedSelectionBrokenAtLaunchComesBackWhenItsFileIsFixed() throws {
        let folder = try temporaryFolder()
        let suite = "lumen-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let configuration = LumenStoreConfiguration(appName: "LumenTests", themesDirectory: folder, defaultsSuiteName: suite)
        let calm = ##"{"id": "user.calm", "name": "Calm", "inherits": "lumen.standard"}"##
        try write(calm, "calm.json", in: folder)
        LumenThemeStore(registry: TestPack.registry, configuration: configuration).select("user.calm")

        try write("{ broken", "calm.json", in: folder)   // mid-edit when the app launches
        let relaunched = LumenThemeStore(registry: TestPack.registry, configuration: configuration)
        XCTAssertEqual(relaunched.theme().id, relaunched.defaultThemeID, "Draws the default while the file is broken")
        XCTAssertEqual(configuration.defaults.string(forKey: configuration.selectionDefaultsKey(for: .window)), "user.calm",
                       "The saved choice is not overwritten")
        try write(calm, "calm.json", in: folder)
        relaunched.reloadUserThemes()
        XCTAssertEqual(relaunched.theme().id, "user.calm", "And resumes when it's fixed, as a reload does")
    }

    func testConcurrentChoicesPersistTheChoiceTheStoreShows() throws {
        let suite = "lumen-tests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let configuration = LumenStoreConfiguration(appName: "LumenTests", themesDirectory: URL(fileURLWithPath: "/dev/null/x"),
                                                    defaultsSuiteName: suite)
        let store = LumenThemeStore(registry: TestPack.registry, configuration: configuration, themes: TestPack.registry.galleryThemes)
        let ids = [LumenThemes.midnightID, LumenThemes.contrastID, LumenThemes.standardID]
        let key = configuration.selectionDefaultsKey(for: .window)
        var mismatches = 0
        for round in 0..<300 {
            DispatchQueue.concurrentPerform(iterations: 3) { lane in
                store.select(ids[(round + lane) % ids.count])
                store.setUsesSystemAccent(lane % 2 == round % 2)
            }
            if configuration.defaults.string(forKey: key) != store.theme().id
                || configuration.defaults.bool(forKey: configuration.systemAccentDefaultsKey) != store.usesSystemAccent {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0, "What relaunch restores is what the store shows")
    }

    func testAnUnknownTokenReadFromAPaletteIsReported() {
        let store = TestPack.store()
        let typo = LumenToken("typo.canvas")
        _ = store.resolvedPalette()[typo]
        XCTAssertTrue(store.unknownTokens.contains(typo), "Checks see palette reads, not only store reads")
        _ = store.resolvedPalette().raised()[LumenToken("typo.raised")]
        XCTAssertTrue(store.unknownTokens.contains(LumenToken("typo.raised")))
    }
}

final class LumenSystemAccentTests: XCTestCase {
    func testSystemAccentMappingFollowsSystemSettings() {
        XCTAssertNil(LumenSystemAccent.color(forAppleAccentColor: nil), "Absent key is Multicolor")
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: -1), .systemGray)
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: 0), .systemRed)
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: 3), .systemGreen)
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: 4), .systemBlue)
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: 6), .systemPink)
        XCTAssertEqual(LumenSystemAccent.color(forAppleAccentColor: 42), .systemBlue)
        XCTAssertEqual(LumenSystemAccent.textColor(on: "#FFD321"), "#000000")
        XCTAssertEqual(LumenSystemAccent.textColor(on: "#1E3A8A"), "#FFFFFF")
    }

    func testSystemAccentFollowsTheMacOnlyForAccentRolesAndKeepsTextReadable() throws {
        let store = TestPack.store()
        store.select(LumenThemes.midnightID)
        // Midnight's own accent, as the store draws it (in the theme's color space).
        let own = try resolve(store.nsColor(.accent), in: .aqua)
        store.setUsesSystemAccent(true)
        let accent = try resolve(store.nsColor(.accent), in: .aqua)
        if let system = LumenSystemAccent.current() {
            let expected = try resolve(system, in: .aqua)
            XCTAssertEqual(accent.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(accent.greenComponent, expected.greenComponent, accuracy: 0.01)
        } else {
            XCTAssertEqual(accent.redComponent, own.redComponent, accuracy: 0.01, "Multicolor keeps the theme accent")
            XCTAssertEqual(accent.blueComponent, own.blueComponent, accuracy: 0.01, "Multicolor keeps the theme accent")
        }
        let onAccent = try resolve(store.nsColor(.fgOnAccent), in: .aqua)
        func lumen(_ c: NSColor) -> LumenColor { LumenColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent) }
        XCTAssertGreaterThanOrEqual(lumen(onAccent).contrastRatio(against: lumen(accent)), 4.5)
        XCTAssertEqual(try hex(store.nsColor(.bgCanvas), in: .darkAqua, space: .displayP3), "#080F24",
                       "Roles that don't follow the accent keep the theme's color")
        XCTAssertTrue(TestPack.registry.spec(for: .sidebarAccent)?.followsSystemAccent == true)

        store.setUsesSystemAccent(false)
        let themed = try resolve(store.nsColor(.accent), in: .aqua)
        XCTAssertEqual(themed.redComponent, own.redComponent, accuracy: 0.01, "Back to Midnight's own accent")
        XCTAssertEqual(themed.blueComponent, own.blueComponent, accuracy: 0.01, "Back to Midnight's own accent")
    }
}
