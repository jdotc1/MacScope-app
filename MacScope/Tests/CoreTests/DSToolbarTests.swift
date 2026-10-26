import AppKit
import LumenTokens
import SwiftUI
import LumenUI
import XCTest
@testable import MacScope

final class DSToolbarTests: XCTestCase {
    @MainActor
    func testToolbarDimmingPreservesEnabledTreatmentAndDoesNotCompoundDisabledOpacity() throws {
        let black: LumenColor = "#000000"
        let white: LumenColor = "#FFFFFF"
        for (enabled, state, styleAlpha, dimmingAlpha): (Bool, ControlActiveState, Double, Double) in [
            (true, .active, 1, 1), (true, .inactive, 1, 0.55),
            (false, .active, 0.45, 1), (false, .inactive, 0.45, 1),
        ] {
            let rendered = try toolbarPixel(foreground: black, background: white,
                                            isEnabled: enabled, activeState: state)
            // ImageRenderer's compositing/filter pipeline does not yield the same sRGB
            // components as hand compositing encoded RGB numbers. Compare to a reference
            // swatch rendered through the same pipeline at the specified opacity factors.
            let reference = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
                .frame(width: DS.Layout.toolbarButton, height: DS.Layout.toolbarButton)
                .opacity(styleAlpha)
                .saturation(state == .inactive ? 0 : 1)
                .opacity(dimmingAlpha)
                .background(Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1))
            let expected = try renderedPixel(reference)
            XCTAssertEqual(rendered.red, expected.red, accuracy: 0.01)
            XCTAssertEqual(rendered.green, expected.green, accuracy: 0.01)
            XCTAssertEqual(rendered.blue, expected.blue, accuracy: 0.01)
        }
    }

    @MainActor
    func testDisabledToolbarButtonsMaintainContrastOnActiveAndInactiveChrome() throws {
        let registry = LumenRegistry.macScope
        for theme in registry.galleryThemes {
            for appearance in LumenAppearance.all where theme.supportedAppearances.contains(appearance.isDark) {
                let foreground = theme.color(.toolbarForeground, for: appearance, in: registry)
                for ground: LumenToken in [.toolbarBackground, .titlebarActiveTop, .titlebarActiveBottom] {
                    let background = theme.color(ground, for: appearance, in: registry)
                    for state: ControlActiveState in [.active, .inactive] {
                        let rendered = try toolbarPixel(foreground: foreground, background: background,
                                                        isEnabled: false, activeState: state)
                        XCTAssertGreaterThanOrEqual(rendered.contrastRatio(against: background), 2,
                            "\(theme.id) \(appearance) \(ground.rawValue) \(state)")
                    }
                }
            }
        }
    }

    @MainActor
    private func toolbarPixel(foreground: LumenColor, background: LumenColor,
                              isEnabled: Bool, activeState: ControlActiveState) throws -> LumenColor {
        let content = Button {} label: {
            Color(.sRGB, red: foreground.red, green: foreground.green, blue: foreground.blue, opacity: 1)
        }
        .buttonStyle(LumenToolbarIconButtonStyle())
        .dsToolbarDimming()
        .disabled(!isEnabled)
        .background(Color(.sRGB, red: background.red, green: background.green, blue: background.blue, opacity: 1))
        .environment(\.controlActiveState, activeState)
        return try renderedPixel(content)
    }

    @MainActor
    private func renderedPixel<Content: View>(_ content: Content) throws -> LumenColor {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return LumenColor(red: Double(pixel.redComponent), green: Double(pixel.greenComponent), blue: Double(pixel.blueComponent))
    }

    func testTitlebarColorsInEveryMacScopeVariant() throws {
        let lightContrast = LumenAppearance(isDark: false, isHighContrast: true)
        let darkContrast = LumenAppearance(isDark: true, isHighContrast: true)
        let variants: [(String, LumenAppearance, String, String)] = [
            (MacScopeThemes.scopeID, .light, "#F3E5E8", "#F3F2F8"),
            (MacScopeThemes.scopeID, .dark, "#3A202B", "#201E2E"),
            (MacScopeThemes.scopeID, lightContrast, "#FFFFFF", "#FFFFFF"),
            (MacScopeThemes.scopeID, darkContrast, "#000000", "#000000"),
            (MacScopeThemes.midnightID, .dark, "#391724", "#0E1331"),
            (MacScopeThemes.midnightID, darkContrast, "#391724", "#0E1331"),
            (MacScopeThemes.contrastID, .light, "#FFFFFF", "#FFFFFF"),
            (MacScopeThemes.contrastID, .dark, "#000000", "#000000"),
            (MacScopeThemes.contrastID, lightContrast, "#FFFFFF", "#FFFFFF"),
            (MacScopeThemes.contrastID, darkContrast, "#000000", "#000000"),
        ]
        let registry = LumenRegistry.macScope
        for (id, appearance, top, bottom) in variants {
            let theme = try XCTUnwrap(registry.theme(id: id))
            XCTAssertEqual(theme.color(.titlebarActiveTop, for: appearance, in: registry).hexString, top, "\(id) \(appearance)")
            XCTAssertEqual(theme.color(.titlebarActiveBottom, for: appearance, in: registry).hexString, bottom, "\(id) \(appearance)")
        }
        let scope = try XCTUnwrap(registry.theme(id: MacScopeThemes.scopeID))
        XCTAssertEqual(scope.color(.layoutToggleOn, for: .light, in: registry).hexString, "#6757D0")
    }
}
