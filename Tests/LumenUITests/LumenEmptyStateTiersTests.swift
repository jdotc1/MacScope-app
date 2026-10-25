import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

/// One empty-state design in tiers (`.inline`, `.pane`, hero), with
/// loading and error on the pane layout, so the three swap in place without a jump.
@MainActor
final class LumenEmptyStateTiersTests: XCTestCase {
    private func height(_ view: some View, width: CGFloat = 300) -> CGFloat {
        NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true).lumenPaletteRoot())
            .fittingSize.height
    }

    func testLoadingAndErrorSwapInPlaceWithThePaneEmptyState() {
        let empty = height(LumenEmptyState("Analyzing", message: "Reading symbols", systemImage: "tray", actionTitle: "Cancel") {})
        let loading = height(LumenLoadingState("Analyzing", message: "Reading symbols", onCancel: {}))
        let progress = height(LumenLoadingState("Analyzing", message: "Reading symbols", progress: 0.4, onCancel: {}))
        XCTAssertEqual(progress, empty, accuracy: 1, "The progress bar sits in the same 32 pt mark slot")
        let error = height(LumenErrorState("Analyzing", message: "Reading symbols", retryTitle: "Cancel", onRetry: {}))
        XCTAssertEqual(loading, empty, accuracy: 1, "Same mark slot, text block and link: no card around loading")
        XCTAssertEqual(error, empty, accuracy: 1, "Same mark slot, text block and link: no card or tile around error")
    }

    /// G16: a state message wraps to even lines, at the narrowest width that keeps its line count,
    /// instead of filling the column and leaving "references." alone on the last line.
    func testStateMessagesWrapToEvenLines() {
        let message = "Select an instruction to see its bytes, function, data and cross-references."
        let text = Text(message).font(LumenMetrics.standard.typography.callout).multilineTextAlignment(.center)
        let column: CGFloat = 192   // the 240 pt inspector less the empty state's s8 insets
        let balanced = NSHostingController(rootView: LumenBalancedWrapLayout { text }).sizeThatFits(in: CGSize(width: column, height: 10_000))
        let filled = NSHostingController(rootView: text).sizeThatFits(in: CGSize(width: column, height: 10_000))
        XCTAssertEqual(balanced.height, filled.height, accuracy: 0.5, "same number of lines")
        XCTAssertLessThan(balanced.width, column - 10, "the lines are evened out, narrower than the column")
        let narrower = NSHostingController(rootView: text).sizeThatFits(in: CGSize(width: balanced.width - 2, height: 10_000))
        XCTAssertGreaterThan(narrower.height, balanced.height + 0.5, "any narrower adds a line")
    }

    func testTheInspectorEmptyStateAddsNoSecondInset() {
        let message = "Select an instruction to see its bytes, function, data and cross-references."
        let plain = height(LumenEmptyState("Nothing selected", message: message, systemImage: "cursorarrow.rays"))
        let inspector = height(Color.clear.frame(height: 1).lumenInspectorEmptyState(true, message: message))
        XCTAssertEqual(inspector, plain, accuracy: 0.5, "C-48: the modifier's extra .padding() is gone")
        let withAction = height(Color.clear.frame(height: 1).lumenInspectorEmptyState(true, message: message, actionTitle: "Open…") {})
        XCTAssertGreaterThan(withAction, inspector, "The inspector empty state can carry one link action")
    }

    func testInlineIsOneSentenceWithoutAGlyph() {
        let inline = height(LumenEmptyState("Nothing here yet", message: "Ignored inline", systemImage: "tray", prominence: .inline))
        let pane = height(LumenEmptyState("Nothing here yet", systemImage: "tray"))
        // One callout line plus s4 above and below.
        XCTAssertLessThan(inline, 36)
        XCTAssertLessThan(inline, pane)
    }

    /// A split view sizing its columns measures at a near-zero width, and an
    /// inline sentence wrapped a few letters per line held the Workspace window 1325 pt tall. Measured
    /// that narrow, a sentence stays a few lines high.
    func testInlineSentenceStaysShortWhenMeasuredNarrow() {
        let sentence = LumenEmptyState("No symbols in the current document", prominence: .inline)
        let narrow = NSHostingController(rootView: sentence.lumenPaletteRoot()).sizeThatFits(in: CGSize(width: 1, height: 0))
        XCTAssertLessThan(narrow.height, 100, "an inline sentence measured 1 pt wide asks for \(narrow.height) pt")
    }

    /// API-03: apps get the leading inline sentence Lumen's sidebar count section draws, so a
    /// `LumenSidebarSection`'s empty state can sit at the same x instead of centered.
    func testThePublicInlineFormDrawsLeadingOrCentered() throws {
        let variant = LumenSnapshot.Variant(themeID: LumenThemes.standardID, colorScheme: .light)
        func firstInkColumn(_ state: LumenEmptyState) throws -> Int {
            let data = try XCTUnwrap(LumenSnapshot.png(of: state, size: CGSize(width: 300, height: 40), variant: variant,
                                                       registry: TestPack.registry, scale: 1))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
            let canvas = rep.colorAt(x: 0, y: 0)
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh where rep.colorAt(x: x, y: y) != canvas { return x }
            }
            return rep.pixelsWide
        }
        XCTAssertLessThan(try firstInkColumn(.inline("No open pull requests", leading: true)), 4)
        XCTAssertGreaterThan(try firstInkColumn(.inline("No open pull requests")), 60)
    }

    func testDataViewsSaySomethingWhenEmpty() {
        XCTAssertGreaterThan(height(LumenProcessList([], selection: .constant(nil))), 20)
        XCTAssertGreaterThan(height(LumenStackFrameList([], selection: .constant(nil))), 20)
        XCTAssertGreaterThan(height(LumenCollection([], mode: .list, selection: .constant(nil), sort: .constant(.title)) { _ in }), 40)
        XCTAssertGreaterThan(height(LumenSearchResults([], collapsed: .constant([])) { _, _ in }), 40)
        // Unchanged with content: the inline state appears only when there is nothing.
        let process = LumenProcess(pid: 1, name: "launchd")
        XCTAssertEqual(height(LumenProcessList([process], selection: .constant(nil))),
                       height(LumenProcessList([process], selection: .constant(nil)).lumenEmptyMessage("Ignored")), accuracy: 0.5)
    }

    func testSidebarCountSectionKeepsItsHeight() {
        // 53 pt before the inline empty state replaced the caption (measured at v0.49.0).
        let section = LumenSidebarCountSection("Binaries", systemImage: "cpu", hue: .huePink, count: 0,
                                               emptyMessage: "Open a binary to list it here.") { EmptyView() }
        XCTAssertLessThanOrEqual(height(section), 53)
    }
}
