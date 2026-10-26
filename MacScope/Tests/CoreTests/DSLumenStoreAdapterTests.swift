import AppKit
import LumenTokens
import LumenUI
import Observation
import SwiftUI
import Synchronization
import XCTest
@testable import MacScope

final class DSLumenStoreAdapterTests: XCTestCase {
    func testLaunchInstallationSharesTheExactStoreWithLumen() {
        let previous = LumenThemeStore.shared
        defer { LumenThemeStore.install(previous, watchesThemesFolder: false) }
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.midnight.id, persistsSelection: false)
        DSThemeStore.installLumen(store, watchesThemesFolder: false)
        XCTAssertTrue(LumenThemeStore.shared === store.lumen)
        XCTAssertEqual(Lumen.theme().id, "com.macscope.theme.midnight")
        store.select(DSBuiltInThemes.contrast.id)
        XCTAssertEqual(Lumen.theme().id, "com.macscope.theme.contrast")
    }

    func testScopedStoreOverridesBothNamespacesAndRestoresThemAfterThrowing() {
        enum Sentinel: Error { case expected }
        let previousDS = DSThemeStore.active
        let previousLumen = LumenThemeStore.active
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.midnight.id, persistsSelection: false)
        XCTAssertThrowsError(try DSThemeStore.withActiveStore(store) {
            XCTAssertTrue(DSThemeStore.active === store)
            XCTAssertTrue(LumenThemeStore.active === store.lumen)
            XCTAssertEqual(DS.theme.id, Lumen.theme().id)
            throw Sentinel.expected
        })
        XCTAssertTrue(DSThemeStore.active === previousDS)
        XCTAssertTrue(LumenThemeStore.active === previousLumen)
    }

    func testCompatibilityEnvironmentNamesShareLumenKeys() {
        let store = DSThemeStore(persistsSelection: false)
        var values = EnvironmentValues()
        values.dsPalette = store.resolvedPalette()
        XCTAssertEqual(values.lumenPalette, store.resolvedPalette())
        values.dsDensity = .compact
        XCTAssertEqual(values.lumenDensity, .compact)
        values.lumenDensity = .comfortable
        XCTAssertEqual(values.dsDensity, .comfortable)
    }

    func testEditorContextRoutesSharedForegroundWithoutRecoloringWindowChrome() throws {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.scope.id, persistsSelection: false)
        store.selectEditorTheme(DSBuiltInThemes.midnight.id)
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        func components(_ color: NSColor) throws -> [CGFloat] {
            var resolved: NSColor?
            dark.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
            let rgb = try XCTUnwrap(resolved)
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        }
        let editor = try components(store.nsColor(.fgPrimary, editorSurface: true))
        XCTAssertEqual(editor, try components(DSBuiltInThemes.midnight.nsColor(.fgPrimary, for: .dark)))
        XCTAssertNotEqual(editor, try components(store.nsColor(.fgPrimary)))
        XCTAssertEqual(try components(store.nsColor(.bgCanvas)),
                       try components(DSBuiltInThemes.midnight.nsColor(.bgCanvas, for: .dark)))
        XCTAssertEqual(store.theme.id, "com.macscope.theme.scope")
        store.selectEditorTheme(nil)
        XCTAssertEqual(try components(store.nsColor(.fgPrimary, editorSurface: true)),
                       try components(store.nsColor(.fgPrimary)))
    }

    func testCompatibilityReadsKeepLumenObservationDependencies() {
        let store = DSThemeStore(persistsSelection: false)
        let fired = Mutex(false)
        withObservationTracking {
            _ = store.theme
        } onChange: {
            fired.withLock { $0 = true }
        }
        store.select(DSBuiltInThemes.midnight.id)
        XCTAssertTrue(fired.withLock { $0 })
    }
}
