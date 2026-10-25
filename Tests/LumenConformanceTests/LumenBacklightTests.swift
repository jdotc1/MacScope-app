import SwiftUI
import XCTest
import LumenTokens
import LumenUI
import LumenConformance

/// A tile's backlight stays inside its strip and never crosses the
/// strip's hairline or edge (a sidebar switcher must not bleed through its divider); in
/// the toolbar it's off, since there it can only be clipped into a hard-edged disc.
@MainActor
final class LumenBacklightTests: XCTestCase {
    let sizes = [CGSize(width: 320, height: 160)]

    /// A glow shaped as LumenIconTile's (an ellipse under a 20 pt tile), offset `drop` below it.
    private func tile(drop: CGFloat, blur: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(.purple).frame(width: 20, height: 20)
            .background {
                Ellipse().fill(.purple.opacity(0.4)).frame(width: 25, height: 14)
                    .lumenBacklightExtent(blur: blur).offset(y: drop).blur(radius: blur)
            }
    }

    private func strip(height: CGFloat, drop: CGFloat, blur: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack { tile(drop: drop, blur: blur); tile(drop: drop, blur: blur) }
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .lumenBacklightContainer("Switcher")
            Rectangle().fill(.gray).frame(height: 1)   // the hairline under the strip
            Color.clear
        }
    }

    func testAContainedGlowPasses() {
        XCTAssertEqual(LumenConformance.backlight(sizes: sizes) { strip(height: 40, drop: 2, blur: 2) }, [])
    }

    /// Today's tile: offset 0.32 × size and blur 0.32 × size, in a 28 pt strip: it reaches past the hairline.
    func testAGlowCrossingTheStripsHairlineIsReported() {
        let findings = LumenConformance.backlight(sizes: sizes) { strip(height: 28, drop: 6.4, blur: 6.4) }
        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertTrue(findings.first?.message.hasPrefix("a tile backlight crosses the edge of “Switcher” by ") ?? false, "\(findings)")
    }

    func testAGlowOutsideAnyStripIsReported() {
        let findings = LumenConformance.backlight(sizes: sizes) { tile(drop: 2, blur: 2) }
        XCTAssertEqual(findings.map(\.message), ["a tile backlight shows outside any backlit strip (.lumenBacklightContainer)"])
    }

    // MARK: Lumen's own tiles

    /// A backlit tile in the toolbar (the unified top bar's launcher, the Catalog's identity):
    /// the backlight is off there. If the tile still draws a glow outside any strip, it must
    /// report it through `.lumenBacklightExtent`.
    func testABacklitTileOutsideAStripIsReportedOrUnlit() {
        let tile = LumenIconTile("lumen.lens", hue: .huePink, size: 20)
        guard LumenTileBacklightProbe.drawsGlow(lit: tile.lumenTileBacklight(), unlit: tile) else { return }   // off: fine
        XCTAssertEqual(LumenConformance.backlight(sizes: sizes) { tile.lumenTileBacklight() }.map(\.message),
                       ["a tile backlight shows outside any backlit strip (.lumenBacklightContainer)"],
                       "LumenIconTile draws a backlight outside any strip without reporting it")
    }

    /// The sidebar switcher's tiles stay inside their strip.
    func testTheSidebarSwitcherBacklightStaysInItsStrip() {
        XCTAssertEqual(LumenConformance.backlight(sizes: [CGSize(width: 300, height: 160)]) {
            VStack(spacing: 0) {
                LumenSidebarSwitcher(selection: .constant("project"), items: [
                    LumenSidebarItem(id: "project", title: "Project", systemImage: "square.stack.3d.up", hue: .huePink),
                    LumenSidebarItem(id: "functions", title: "Functions", systemImage: "function", hue: .hueBlue),
                    LumenSidebarItem(id: "strings", title: "Strings", systemImage: "text.quote", hue: .hueOrange),
                ], shortcuts: false, style: .tiles)
                Color.clear
            }
            .frame(width: 280)
        }.map(\.description), [])
    }
}

/// Whether `lit` draws differently from `unlit` (the same tile without the backlight environment).
@MainActor
enum LumenTileBacklightProbe {
    static func drawsGlow<A: View, B: View>(lit: A, unlit: B) -> Bool {
        let variant = LumenSnapshot.Variant(themeID: LumenThemes.standardID, colorScheme: .dark)
        let size = CGSize(width: 60, height: 60)
        guard let a = LumenSnapshot.png(of: lit, size: size, variant: variant, registry: .core),
              let b = LumenSnapshot.png(of: unlit, size: size, variant: variant, registry: .core) else { return false }
        return LumenSnapshot.compare(a, b).differingPixelFraction > 0.001
    }
}
