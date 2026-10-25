import AppKit
import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

final class LumenPaletteTests: XCTestCase {
    func testPaletteResolvesTheSameColorsAsTheStore() throws {
        let store = TestPack.store()
        store.select(LumenThemes.midnightID, for: TestPack.editor)
        let palette = store.resolvedPalette()
        for token in TestPack.registry.tokens {
            let fromPalette = try resolve(NSColor(palette[token]), in: .darkAqua)
            let fromStore = try resolve(store.nsColor(token), in: .darkAqua)
            XCTAssertEqual(fromPalette.redComponent, fromStore.redComponent, accuracy: 0.002, token.rawValue)
            XCTAssertEqual(fromPalette.blueComponent, fromStore.blueComponent, accuracy: 0.002, token.rawValue)
        }
        XCTAssertEqual(try hex(NSColor(palette[TestPack.keyword]), in: .darkAqua, space: .displayP3), "#E532AD",
                       "Editor roles come from the editor's theme")
        XCTAssertEqual(try hex(NSColor(palette[.bgCanvas]), in: .darkAqua), "#16181E", "Window roles stay with the window theme")
    }

    func testPaletteIdentityFollowsTheSelectionOnly() {
        let store = TestPack.store()
        let first = store.resolvedPalette()
        XCTAssertEqual(first, store.resolvedPalette(), "Same selection, same palette")
        store.select(LumenThemes.contrastID)
        XCTAssertNotEqual(first, store.resolvedPalette())
        store.select(LumenThemes.standardID)
        XCTAssertEqual(first, store.resolvedPalette())
        store.select(LumenThemes.midnightID, for: TestPack.editor)
        XCTAssertNotEqual(first, store.resolvedPalette(), "Another surface's theme changes the palette")
        store.select(nil, for: TestPack.editor)
        store.setUsesSystemAccent(true)
        XCTAssertNotEqual(first, store.resolvedPalette(), "System accent changes the palette")
        store.setUsesSystemAccent(false)
        XCTAssertEqual(first, store.resolvedPalette())
        XCTAssertNotEqual(first, TestPack.store().resolvedPalette(), "Two stores never share a palette")
    }

    func testReloadBumpsTheRevisionSoInPlaceEditsGetANewPalette() throws {
        let folder = try temporaryFolder()
        let calm = ##"{"id": "user.calm", "name": "Calm", "inherits": "lumen.standard", "light": {"accent.default": "#2F6FDE"}}"##
        try write(calm, "calm.json", in: folder)
        let store = TestPack.store(folder: folder)
        store.select("user.calm")
        let before = store.resolvedPalette()

        try write(calm.replacingOccurrences(of: "#2F6FDE", with: "#C2185B"), "calm.json", in: folder)
        store.reloadUserThemes()

        XCTAssertEqual(store.paletteKey.revision, before.key.revision + 1)
        XCTAssertNotEqual(store.resolvedPalette(), before, "Same theme id, new colors: readers must re-render")
        XCTAssertEqual(try hex(store.nsColor(.accent), in: .aqua), "#C2185B", "The color cache is cleared too")
    }
}

final class LumenMetricsAndDensityTests: XCTestCase {
    func testStandardMetricsReproduceTheShippedScales() {
        let standard = LumenMetrics.standard
        XCTAssertEqual([standard.radius.xs, standard.radius.sm, standard.radius.md, standard.radius.lg, standard.radius.xl], [4, 6, 8, 10, 14])
        XCTAssertEqual([Lumen.Radius.xs, Lumen.Radius.sm, Lumen.Radius.md, Lumen.Radius.lg, Lumen.Radius.xl], [4, 6, 8, 10, 14],
                       "The static scale equals the standard metrics")
        XCTAssertEqual([Lumen.Space.s1, Lumen.Space.s4, Lumen.Space.s6, Lumen.Space.s11], [2, 8, 16, 48])
        XCTAssertEqual(standard.motion.fast, 0.14)
        XCTAssertEqual(standard.motion.standard, 0.22)
        XCTAssertNil(standard.motion.animation(standard.motion.standardCurve, reduceMotion: true), "Reduce Motion: change at once")
        XCTAssertNotNil(Lumen.Motion.animation(Lumen.Motion.standardCurve, reduceMotion: false))
        XCTAssertEqual(standard.layout.propertyLabelWidth, 82)
        XCTAssertEqual(LumenMetrics(), .standard)
    }

    func testRadiiSitOnTheTwoPointGridAndIncrease() {
        let r = LumenMetrics.standard.radius
        let scale = [r.xs, r.sm, r.md, r.lg, r.xl]
        XCTAssertEqual(scale, scale.sorted())
        XCTAssertEqual(Set(scale).count, scale.count)
        XCTAssertTrue(scale.allSatisfy { $0.truncatingRemainder(dividingBy: 2) == 0 }, "\(scale)")
    }

    func testRegularDensityReproducesTheBaseLayout() {
        let layout = LumenMetrics.Layout.standard
        XCTAssertEqual(LumenDensity.regular.rowHeight(in: layout), 26)
        XCTAssertEqual(LumenDensity.regular.detailedRowHeight(in: layout), 36)
        XCTAssertEqual(LumenDensity.regular.rowVerticalPadding(detailed: false, in: layout), 4)
        XCTAssertEqual(LumenDensity.regular.rowVerticalPadding(detailed: true, in: layout), 5)
        XCTAssertEqual(LumenDensity.compact.rowVerticalPadding(detailed: false, in: layout), 2)
        XCTAssertEqual(LumenDensity.comfortable.rowVerticalPadding(detailed: true, in: layout), 7)
        XCTAssertEqual(LumenDensity.resolve("nonsense"), .regular)
        XCTAssertEqual(LumenDensity.resolve("compact"), .compact)
    }

    func testDensityOrdersFromCompactToComfortable() {
        let layout = LumenMetrics.Layout.standard
        for heights in [LumenDensity.allCases.map { $0.rowHeight(in: layout) }, LumenDensity.allCases.map { $0.detailedRowHeight(in: layout) }] {
            XCTAssertEqual(heights, heights.sorted())
        }
        XCTAssertGreaterThanOrEqual(LumenDensity.compact.rowHeight(in: layout), 22, "Rows stay at or above a usable hit target")
    }

    func testDensityReadsTheAppsLayout() {
        var layout = LumenMetrics.Layout()
        layout.rowHeightCompact = 20
        layout.rowHeightRegular = 24
        layout.rowHeightComfortable = 32
        layout.detailedRowHeightRegular = 40
        layout.rowVerticalPadding = 6
        XCTAssertEqual(LumenDensity.allCases.map { $0.rowHeight(in: layout) }, [20, 24, 32])
        XCTAssertEqual(LumenDensity.regular.detailedRowHeight(in: layout), 40)
        XCTAssertEqual(LumenDensity.compact.rowVerticalPadding(detailed: false, in: layout), 4)
    }

    /// The rendered size of `view` under `metrics`, in points.
    @MainActor
    private func renderedSize(_ view: some View, metrics: LumenMetrics) throws -> CGSize {
        let renderer = ImageRenderer(content: view.environment(\.lumenMetrics, metrics))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        return CGSize(width: image.width, height: image.height)
    }

    @MainActor
    func testComponentsTakeTheirSizesFromTheEnvironmentsMetrics() throws {
        var roomy = LumenMetrics.standard
        roomy.spacing.s3 = 20   // badge horizontal padding
        roomy.spacing.s1 = 8    // badge vertical padding
        let standard = try renderedSize(LumenBadge("Draft", tone: .warning), metrics: .standard)
        let wider = try renderedSize(LumenBadge("Draft", tone: .warning), metrics: roomy)
        XCTAssertEqual(wider.width - standard.width, 2 * (20 - 6), accuracy: 1, "Horizontal padding comes from the metrics")
        XCTAssertEqual(wider.height - standard.height, 2 * (8 - 2), accuracy: 1, "Vertical padding comes from the metrics")

        var wideLabels = LumenMetrics.standard
        wideLabels.layout.propertyLabelWidth = 140
        wideLabels.layout.minimumHitTarget = 40
        let row = LumenPropertyRow(label: "Path", value: "x").frame(width: 300)
        XCTAssertEqual(try renderedSize(row, metrics: wideLabels).height, 40, accuracy: 1, "Row height follows minimumHitTarget")

        var document = LumenMetrics.standard
        document.typography.headline = .custom("Arial", size: 30)
        let header = LumenEmptyState(systemImage: "tray", title: "Empty", message: "Nothing").fixedSize()
        XCTAssertGreaterThan(try renderedSize(header, metrics: document).height, try renderedSize(header, metrics: .standard).height,
                             "Type comes from the metrics")
    }
}
