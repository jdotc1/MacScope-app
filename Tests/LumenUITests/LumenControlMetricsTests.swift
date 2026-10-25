import XCTest
import SwiftUI
import LumenTokens
@testable import LumenUI

/// Control heights, the table's rows area, one disabled fade, compact stats.
@MainActor final class LumenControlMetricsTests: XCTestCase {
    private struct Item: Identifiable { let id: Int; let name: String }

    /// `view` rendered offscreen at 1×, `width` wide, its own height.
    private func render(_ view: some View, width: CGFloat? = nil) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.lumenRendersOffscreen, true))
        renderer.scale = 1
        if let width { renderer.proposedSize = ProposedViewSize(width: width, height: nil) }
        return try XCTUnwrap(renderer.cgImage)
    }

    /// The most opaque pixel's alpha, 0…1.
    private func maximumAlpha(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Double(stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0) / 255
    }

    private var rowHeight: CGFloat { LumenDensity.regular.rowHeight(in: LumenMetrics.standard.layout) }

    /// CODE-01: the empty table is its header, the header's hairline and the rows area's least
    /// height, not the header plus two of them.
    func testAnEmptyTableIsHeaderPlusItsMinimumHeight() throws {
        let empty = try render(LumenTable([Item](), selection: .constant(nil), minHeight: 44, columns: [.text("Key") { $0.name }]), width: 300)
        XCTAssertEqual(CGFloat(empty.height), rowHeight + 1 + 44, accuracy: 1)
    }

    /// M12: `.fitRows` hugs its rows; `.minimum` keeps its least height.
    func testFitRowsHugsItsRowsAndShowsAFootnote() throws {
        let rows = (1...3).map { Item(id: $0, name: "row \($0)") }
        let fit = try render(LumenTable(rows, selection: .constant(nil), height: .fitRows(maxVisible: 10), columns: [.text("Key") { $0.name }]), width: 300)
        let minimum = try render(LumenTable(rows, selection: .constant(nil), minHeight: 200, columns: [.text("Key") { $0.name }]), width: 300)
        XCTAssertLessThan(fit.height, minimum.height)
        XCTAssertEqual(CGFloat(fit.height), rowHeight + 3 * (rowHeight + 1), accuracy: 2, "Header plus three rows and their hairlines")
        let noted = try render(LumenTable(rows, selection: .constant(nil), height: .fitRows(maxVisible: 10), footnote: "Offsets aren't recorded.",
                                          columns: [.text("Key") { $0.name }]), width: 300)
        XCTAssertGreaterThan(noted.height, fit.height)
    }

    /// The pill switcher is one control height overall, rim included.
    func testThePillSwitcherIsOneControlHeight() throws {
        let pill = try render(LumenModeSwitcher(selection: .constant("A"), options: ["A", "B"], style: .pill, title: { $0 }))
        XCTAssertEqual(CGFloat(pill.height), LumenMetrics.standard.layout.controlHeight, accuracy: 0.5)
        let popUp = try render(LumenPopUpLabel("SF Mono 12"))
        XCTAssertEqual(CGFloat(popUp.height), LumenMetrics.standard.layout.controlHeight, accuracy: 0.5)
    }

    /// CODE-07: a disabled checkbox fades to the disabled opacity once, alone or inside a disabled
    /// dependent group (it was 0.28 and 0.13).
    func testADisabledCheckboxFadesOnceEvenInsideADisabledGroup() throws {
        let target = LumenMetrics.standard.layout.disabledOpacity
        let alone = try render(Toggle("On", isOn: .constant(true)).toggleStyle(.lumenCheckbox).disabled(true))
        let grouped = try render(LumenDependentGroup(enabled: false) { Toggle("On", isOn: .constant(true)).toggleStyle(.lumenCheckbox) })
        XCTAssertEqual(maximumAlpha(alone), target, accuracy: 0.05)
        XCTAssertEqual(maximumAlpha(grouped), target, accuracy: 0.05)
    }

    /// Large counts go compact with the exact count as help; smaller ones stay whole.
    func testLargeCountsUseCompactNotation() {
        let large = LumenStat("Functions", count: 98_765_432)
        XCTAssertEqual(large.fullValue, 98_765_432.formatted())
        XCTAssertLessThanOrEqual(large.value.count, 6, "\(large.value)")
        let small = LumenStat("Functions", count: 120_000)
        XCTAssertEqual(small.value, 120_000.formatted())
        XCTAssertNil(small.fullValue)
    }

    /// M02 / M09: the panel bar takes a toned state and an accessory and still fits a narrow column
    /// (the state's words give way; the status label alone never does).
    func testThePanelBarTakesAToneAndAnAccessory() {
        let bar = LumenPanelBar("Debugger", systemImage: "ladybug.fill",
                                statusLabel: LumenStripStatus("Backend unavailable", tone: .statusDanger),
                                primary: LumenBarAction("Attach…") {}) {
            Button("Continue", systemImage: "play.fill") {}.labelStyle(.iconOnly).buttonStyle(.lumenToolbarIcon)
        }
        XCTAssertLessThan(LumenLayout.minimumWidth(of: bar), 380)
        let label = LumenStatusLabel("Backend unavailable", tone: .statusDanger)
        XCTAssertGreaterThan(LumenLayout.minimumWidth(of: label), 100, "A status label keeps its words")
    }
}
