import AppKit
import SwiftUI
import XCTest
import LumenTokens
import LumenConformance
@testable import LumenUI

/// Layout and visual regression fixes.
@MainActor
final class LumenLayoutRegressionTests: XCTestCase {
    private let registry = LumenRegistry(packs: [.core])
    private let light = LumenSnapshot.Variant(themeID: LumenThemes.standardID, colorScheme: .light)

    /// RGBA pixels of a PNG.
    private func pixels(_ png: Data?) throws -> (data: [UInt8], width: Int, height: Int) {
        let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(png))?.cgImage)
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height)
    }

    /// How many pixels tall the outermost inked column is at each end of the view's ink, in a live
    /// (never-shown) window at 2x. A 24 pt capsule's round end touches its edge for about 12 px; a
    /// cut-off end adds a vertical stub, and the run reaches the full 24 px.
    private func endColumnRuns(_ view: some View, size: CGSize) throws -> (leading: Int, trailing: Int) {
        let png = LumenSnapshot.png(of: view.frame(maxWidth: .infinity, maxHeight: .infinity), size: size, variant: light,
                                    registry: registry, renderer: .window)
        let (data, width, height) = try pixels(png)
        let background = Array(data[0..<3])
        func inked(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return (0..<3).contains { abs(Int(data[i + $0]) - Int(background[$0])) > 24 }
        }
        let columns = (0..<width).filter { x in (0..<height).contains { inked(x, $0) } }
        let first = try XCTUnwrap(columns.first), last = try XCTUnwrap(columns.last)
        return ((0..<height).filter { inked(first, $0) }.count, (0..<height).filter { inked(last, $0) }.count)
    }

    func testPillCapsulesKeepTheirRoundEndsInALiveWindow() throws {
        enum Mode: String, CaseIterable { case compact = "Compact", regular = "Regular" }
        let pill = LumenModeSwitcher(selection: .constant(Mode.regular), options: Mode.allCases, style: .pill, title: { $0.rawValue })
        let runs = try endColumnRuns(pill, size: CGSize(width: 220, height: 40))
        XCTAssertLessThanOrEqual(runs.leading, 18, "the pill track's leading end is cut off flat")
        XCTAssertLessThanOrEqual(runs.trailing, 18, "the pill track's trailing end is cut off flat")

        let header = LumenComparisonHeader(leading: .init("Current Version", tone: .hueBlue), trailing: .init("Latest", tone: .hueOrange))
            .frame(width: 360)
        let capsuleRuns = try endColumnRuns(header, size: CGSize(width: 380, height: 40))
        XCTAssertLessThanOrEqual(capsuleRuns.leading, 18, "the comparison capsule's leading end is cut off flat")
    }

    /// The height a view takes when its container offers `height`.
    private func height(of view: some View, offered height: CGFloat, width: CGFloat = 320) -> CGFloat {
        NSHostingController(rootView: view.lumenMetrics(.standard)).sizeThatFits(in: CGSize(width: width, height: height)).height
    }

    func testHistoryRowKeepsItsContentHeightInATallContainer() {
        let row = LumenHistoryRow(message: "Consistency cleanup", hash: "a1f5083", refs: [("HEAD", .head), ("main", .branch)],
                                  time: "14m", author: "Avery", isSelected: true)
        let natural = height(of: row, offered: 60)
        XCTAssertEqual(height(of: row, offered: 400), natural, accuracy: 0.5, "the row grows to fill its container (G1)")
        XCTAssertLessThan(natural, 70)
    }

    func testHistoryRowRefsWrapInASidebarColumn() {
        let row = LumenHistoryRow(message: "Consistency cleanup", hash: "a1f5083",
                                  refs: [("HEAD", .head), ("main", .branch), ("origin/main", .remote)], time: "14m", author: "Avery")
        XCTAssertEqual(LumenConformance.overflow(sizes: [CGSize(width: 200, height: 200)]) { row }.map(\.description), [],
                       "three refs run out of a 200 pt sidebar")
    }

    func testInspectorValuesFitTheInspectorMinimum() {
        let section = LumenInspectorSection("Evidence", systemImage: "checkmark.seal.fill", hue: .hueGreen) {
            LumenInspectorRow("Status") {
                HStack(spacing: 6) { LumenBadge("Verified", systemImage: "checkmark", tone: .success); LumenBadge("2 inferred", tone: .warning) }
            }
            LumenInspectorRow("Tags") {
                HStack(spacing: 4) { LumenTag("hot path", token: .hueOrange); LumenTag("crypto", token: .hueTeal) }
            }
        }
        XCTAssertEqual(LumenConformance.overflow(sizes: [CGSize(width: LumenLayout.inspectorColumn.min, height: 400)]) { section }
            .map(\.description), [], "a two-badge value runs out of the inspector at its minimum")
    }

    func testEvaluationResultWithALongTypeFitsAnInspector() {
        let result = LumenEvaluationResult("0x600003a1c000", type: "UnsafeMutablePointer<Dictionary<String, Array<Int>>>")
        XCTAssertEqual(LumenConformance.overflow(sizes: [CGSize(width: 220, height: 200)]) { result }.map(\.description), [],
                       "a long type runs out of a 220 pt column")
    }

    func testPropertyRowWrapsASymbolInsteadOfCuttingIt() {
        XCTAssertGreaterThanOrEqual(LumenPropertyRow.valueLineLimit, 3, "a dotted symbol needs three lines at 220 pt")
    }
}
