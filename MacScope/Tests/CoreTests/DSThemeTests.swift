import AppKit
import Observation
import SwiftUI
import LumenTokens
import LumenUI
import XCTest
@testable import MacScope

final class DSThemeTests: XCTestCase {
    /// Every appearance a theme declares, including its Increase Contrast variants.
    private func variants(of theme: LumenTheme) -> [LumenAppearance] {
        theme.supportedColorSchemes.flatMap { scheme in
            [false, true].map { LumenAppearance(isDark: scheme == .dark, isHighContrast: $0) }
        }
    }

    func testBuiltInThemesDefineEveryTokenInEveryDeclaredVariant() {
        for theme in DSBuiltInThemes.all {
            let missing = theme.missingTokens.map { "\($0.0 == .dark ? "dark" : "light").\($0.1.rawValue)" }
            XCTAssertEqual(missing, [], "\(theme.name) leaves tokens undefined")
        }
    }

    func testBuiltInThemeIdentifiersAreUnique() {
        let ids = DSBuiltInThemes.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testTextAndSyntaxRolesMeetWCAGAAOnTheCanvas() {
        let readable = LumenToken.allCases.filter(\.isReadableText)
        for theme in DSBuiltInThemes.all {
            for appearance in variants(of: theme) {
                let canvas = theme.hex(.bgCanvas, for: appearance)
                for token in readable {
                    let ratio = theme.hex(token, for: appearance).contrastRatio(against: canvas)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(theme.name) \(appearance) \(token.rawValue) is \(ratio):1 on bg.canvas"
                    )
                }
            }
        }
    }

    func testPseudocodeRolesStayDistinctInEveryThemeVariant() {
        let roles: [LumenToken] = [
            .syntaxComment, .syntaxVariable, .syntaxKeyword, .syntaxNumber,
            .syntaxOperator, .syntaxPunctuation, .syntaxType,
        ]
        for theme in DSBuiltInThemes.all {
            for appearance in variants(of: theme) {
                let colors = Set(roles.map { theme.hex($0, for: appearance) })
                XCTAssertEqual(colors.count, roles.count, "\(theme.name) \(appearance) reuses a pseudocode color")
            }
        }
    }

    func testThemeJSONRoundTripsAndToleratesUnknownTokens() throws {
        let data = try JSONEncoder().encode(DSBuiltInThemes.midnight)
        let decoded = try JSONDecoder().decode(LumenTheme.self, from: data)
        XCTAssertEqual(decoded, DSBuiltInThemes.midnight)

        let future = """
        {"schemaVersion":1,"id":"test.future","name":"Future","summary":"",
         "colorSpace":"srgb","dark":{"bg.canvas":"#101010","syntax.someNewRole":"#ABCDEF"}}
        """
        let theme = try JSONDecoder().decode(LumenTheme.self, from: Data(future.utf8))
        XCTAssertEqual(theme.forcedColorScheme, .dark)
        XCTAssertEqual(theme.hex(.bgCanvas, for: .dark).hexString, "#101010")
        // A role the theme omits falls back to Scope instead of failing.
        XCTAssertEqual(theme.hex(.fgPrimary, for: .dark), DSBuiltInThemes.scope.hex(.fgPrimary, for: .dark))
    }

    func testMalformedHexIsRejected() {
        XCTAssertNil(LumenColor(hex: "#12345"))
        XCTAssertNil(LumenColor(hex: "blue"))
        XCTAssertEqual(LumenColor(hex: "#80FF0080")?.alpha ?? 0, 128.0 / 255, accuracy: 0.001)
    }

    func testIncreaseContrastSelectsTheHighContrastVariant() {
        let scope = DSBuiltInThemes.scope
        XCTAssertEqual(
            scope.hex(.fgPrimary, for: LumenAppearance(isDark: false, isHighContrast: true)).hexString,
            "#000000"
        )
        XCTAssertNotEqual(
            scope.hex(.fgPrimary, for: .light),
            scope.hex(.fgPrimary, for: LumenAppearance(isDark: false, isHighContrast: true))
        )
    }

    func testStoreSelectsKnownThemesOnlyAndResolvesDynamicColors() throws {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: nil, persistsSelection: false)
        store.select(DSBuiltInThemes.midnight.id)
        XCTAssertEqual(store.theme.id, DSBuiltInThemes.midnight.id)
        store.select("not.a.theme")
        XCTAssertEqual(store.theme.id, DSBuiltInThemes.midnight.id)

        let canvas = store.nsColor(.bgCanvas)
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        var resolved: NSColor?
        dark.performAsCurrentDrawingAppearance {
            resolved = canvas.usingColorSpace(.displayP3)
        }
        let rgb = try XCTUnwrap(resolved)
        XCTAssertEqual(rgb.redComponent, 0x08 / 255, accuracy: 0.002)
        XCTAssertEqual(rgb.blueComponent, 0x24 / 255, accuracy: 0.002)
    }

    func testSelectingAThemeInvalidatesObservers() {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.scope.id, persistsSelection: false)
        let flag = ObservationFlag()
        withObservationTracking {
            _ = store.theme
        } onChange: {
            flag.fired = true
        }
        // Observation calls onChange synchronously, before the mutation completes.
        store.select(DSBuiltInThemes.contrast.id)
        XCTAssertTrue(flag.fired)
    }

    /// MacStories' Nova review singles out a theme whose selected-text background was too low in
    /// contrast. Every MacScope theme keeps selected text readable and the selection visible.
    func testSelectionKeepsTextReadableAndStaysVisibleOnTheCanvas() {
        for theme in DSBuiltInThemes.all {
            for appearance in variants(of: theme) {
                let selected = theme.hex(.bgSelected, for: appearance)
                let primary = theme.hex(.fgPrimary, for: appearance).contrastRatio(against: selected)
                let secondary = theme.hex(.fgSecondary, for: appearance).contrastRatio(against: selected)
                let visible = selected.contrastRatio(against: theme.hex(.bgCanvas, for: appearance))
                XCTAssertGreaterThanOrEqual(primary, 7, "\(theme.name) \(appearance) selected text \(primary):1")
                XCTAssertGreaterThanOrEqual(secondary, 4.5, "\(theme.name) \(appearance) selected secondary text \(secondary):1")
                XCTAssertGreaterThanOrEqual(visible, 1.25, "\(theme.name) \(appearance) selection barely visible (\(visible):1)")
            }
        }
    }

    func testEditorThemeOwnsCanvasAndSyntaxRolesOnly() throws {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.scope.id, persistsSelection: false)
        XCTAssertTrue(store.editorMatchesWindow)
        XCTAssertNil(store.editorColorScheme)

        store.selectEditorTheme(DSBuiltInThemes.midnight.id)
        XCTAssertEqual(store.editorTheme.id, DSBuiltInThemes.midnight.id)
        XCTAssertEqual(store.theme.id, DSBuiltInThemes.scope.id)
        XCTAssertEqual(store.editorColorScheme, .dark)

        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        func resolved(_ token: LumenToken) -> NSColor? {
            var color: NSColor?
            dark.performAsCurrentDrawingAppearance { color = store.nsColor(token).usingColorSpace(.sRGB) }
            return color
        }
        let canvas = try XCTUnwrap(resolved(.bgCanvas))
        let sidebar = try XCTUnwrap(resolved(.bgSidebar))
        // Canvas comes from Midnight's navy; the sidebar stays Scope's slate.
        XCTAssertGreaterThan(canvas.blueComponent - canvas.redComponent, 0.08)
        XCTAssertEqual(sidebar.redComponent, 0x1C / 255, accuracy: 0.01)

        // The native text consumer must use that same editor palette, not the window palette.
        // Retain the dynamic color across changes to exercise its draw-time resolution too.
        let keyword = try XCTUnwrap(AppNativePseudocodeTokenStyle.project(
            .keyword, contrast: .standard, themeStore: store
        ).foregroundColor)
        assertRGB(keyword, appearance: dark, space: .displayP3, expected: (0xE5, 0x32, 0xAD))

        store.selectEditorTheme(nil)
        XCTAssertTrue(store.editorMatchesWindow)
        XCTAssertTrue(LumenToken.syntaxRegister.isEditorOwned)
        XCTAssertFalse(LumenToken.bgSidebar.isEditorOwned)
        assertRGB(keyword, appearance: dark, expected: (0xF2, 0x8F, 0xD0))

        store.select(DSBuiltInThemes.midnight.id)
        store.selectEditorTheme(DSBuiltInThemes.scope.id)
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        assertRGB(keyword, appearance: light, expected: (0xA0, 0x30, 0x8A))
        let increasedKeyword = try XCTUnwrap(AppNativePseudocodeTokenStyle.project(
            .keyword, contrast: .increased, themeStore: store
        ).foregroundColor)
        // An explicit contrast override must still apply under a standard AppKit appearance.
        assertRGB(increasedKeyword, appearance: light, expected: (0x8A, 0x10, 0x6E))
    }

    @MainActor
    func testWelcomeRecentsDoNotImposeHeightOnTheEditorAllocation() {
        // An unscrollable welcome previously forced the editor beyond its split pane, clipping
        // the debugger at the window minimum. Exercise zero, observed, and maximum recent rows
        // without reading or modifying the user's recent-document history.
        for recentCount in [0, 2, 5] {
            let recents = (0..<recentCount).map { index in
                DSWelcomeView.Recent(
                    url: URL(fileURLWithPath: "/fixture/workspaces/Workspace-\(index).mscope"),
                    open: {}
                )
            }
            let welcome = DSWelcomeView(
                title: "No binary open",
                message: "Open a macOS executable, app bundle, framework, or dylib to begin analysis.",
                actionTitle: "Open Binary…",
                secondaryActionTitle: "Open Workspace…",
                secondaryAction: {},
                recents: recents,
                action: {}
            )
            let host = NSHostingController(rootView: welcome)
            for height in [300.0, 540.0] {
                let allocation = CGSize(width: 750, height: height)
                let required = host.sizeThatFits(in: allocation)
                XCTAssertTrue(required.width.isFinite && required.height.isFinite)
                XCTAssertGreaterThan(required.width, 0)
                XCTAssertGreaterThan(required.height, 0)
                XCTAssertLessThanOrEqual(required.width, allocation.width)
                XCTAssertLessThanOrEqual(
                    required.height, allocation.height,
                    "\(recentCount) recent rows must scroll rather than enlarge the editor allocation."
                )
            }
        }
    }

    @MainActor
    func testEditorThemeChangesPreserveMountedPseudocodeSelection() throws {
        let store = DSThemeStore(themes: DSBuiltInThemes.all, selectedID: DSBuiltInThemes.scope.id, persistsSelection: false)
        var observedScheme: ColorScheme?
        let document = NativeDecompilerDocumentProjection(
            text: "alpha beta", isComplete: true, isTruncated: false,
            mappingState: .verified, tokenRuns: []
        )
        let root = EditorThemeSelectionFixture(document: document) { observedScheme = $0 }
            .dsEditorSurface(themeStore: store)
            .environment(\.colorScheme, .light)
        let frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        let host = NSHostingView(rootView: root)
        host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            // Closing the last host window can terminate the app-hosted test process.
            window.orderOut(nil)
            window.contentView = nil
        }

        func settle(appearance: ColorScheme) {
            let deadline = Date(timeIntervalSinceNow: 2)
            repeat {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            } while observedScheme != appearance && Date() < deadline
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(observedScheme, appearance)
        }

        settle(appearance: .light)
        let original = try XCTUnwrap(nativeTextView(in: host))
        let selection = NSRange(location: 2, length: 3)
        original.setSelectedRange(selection)

        // Both nil-to-forced and forced-to-nil transitions used to replace the editor subtree.
        let transitions: [(String?, ColorScheme)] = [
            (DSBuiltInThemes.midnight.id, .dark), (nil, .light),
        ]
        for (editorID, expectedScheme) in transitions {
            store.selectEditorTheme(editorID)
            settle(appearance: expectedScheme)
            let current = try XCTUnwrap(nativeTextView(in: host))
            XCTAssertTrue(current === original, "Changing only a theme must not replace the native editor")
            XCTAssertEqual(current.selectedRange(), selection)
        }
    }

    private func assertRGB(
        _ color: NSColor,
        appearance: NSAppearance,
        space: NSColorSpace = .sRGB,
        expected: (Int, Int, Int),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(space) else {
                return XCTFail("Theme token did not resolve to RGB", file: file, line: line)
            }
            XCTAssertEqual(rgb.redComponent, Double(expected.0) / 255, accuracy: 0.002, file: file, line: line)
            XCTAssertEqual(rgb.greenComponent, Double(expected.1) / 255, accuracy: 0.002, file: file, line: line)
            XCTAssertEqual(rgb.blueComponent, Double(expected.2) / 255, accuracy: 0.002, file: file, line: line)
        }
    }

    @MainActor
    private func nativeTextView(in view: NSView) -> NativePseudocodeNSTextView? {
        if let textView = view as? NativePseudocodeNSTextView { return textView }
        return view.subviews.lazy.compactMap { self.nativeTextView(in: $0) }.first
    }
}

/// Reports the environment inside the production editor-surface modifier, while hosting the
/// production native text bridge. It does not replace or emulate the editor's selection behavior.
private struct EditorThemeSelectionFixture: View {
    let document: NativeDecompilerDocumentProjection
    let schemeChanged: (ColorScheme) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NativePseudocodeTextView(document: document)
            .onAppear { schemeChanged(colorScheme) }
            .onChange(of: colorScheme) { _, scheme in schemeChanged(scheme) }
    }
}

/// Records that an Observation onChange fired; the callback is @Sendable.
private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}
