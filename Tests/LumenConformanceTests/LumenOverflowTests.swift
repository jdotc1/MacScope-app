import SwiftUI
import XCTest
import LumenTokens
import LumenUI
import LumenConformance

/// PRINCIPLES §6 for fixed-height containers: a card whose content needs more height than it got is
/// reported; one whose content fits isn't.
@MainActor
final class LumenOverflowTests: XCTestCase {
    let sizes = [CGSize(width: 480, height: 320)]

    private func card(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<lines, id: \.self) { Text("Line \($0 + 1) of the card") }
        }
        .padding(12)
        .lumenFixedContainer("Card")
        .frame(width: 300, height: 120)
    }

    func testACardWithSixLinesInOneHundredTwentyPointsIsReported() {
        let findings = LumenConformance.overflow(sizes: sizes) { card(lines: 6) }
        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertTrue(findings.first?.message.hasPrefix("“Card” clips its content by ") ?? false, "\(findings)")
    }

    func testACardWithTwoLinesPasses() {
        XCTAssertEqual(LumenConformance.overflow(sizes: sizes) { card(lines: 2) }, [])
    }

    /// Wrapping text squeezed into fewer lines (rather than spilling over) is clipping too.
    func testAParagraphSqueezedIntoTheCardIsReported() {
        let findings = LumenConformance.overflow(sizes: sizes) {
            Text(String(repeating: "A paragraph that wraps over many lines in a narrow card. ", count: 8))
                .padding(12)
                .lumenFixedContainer("Paragraph card")
                .frame(width: 300, height: 120)
        }
        XCTAssertEqual(findings.count, 1, "\(findings)")
    }

    // MARK: The view as a whole

    /// The app-icons golden: 8 + 3 × 128 + 3 × 8 + 32 + 8 = 456 pt of fixed views in a 440 pt frame.
    /// No container inside reports it (there is none), so the check measures the root: it passed
    /// before, unseen, while SwiftUI centered the row and cut 8 pt off each edge.
    func testARowWiderThanItsFrameIsReported() {
        let findings = LumenConformance.overflow(sizes: [CGSize(width: 440, height: 144)]) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in Color.red.frame(width: 128, height: 128) }
                Color.red.frame(width: 32, height: 32)
            }
            .padding(8)
        }
        XCTAssertEqual(findings.map(\.message), ["the content is 16 pt wider than its 440 pt frame"])
    }

    func testAMinimumHeightTallerThanTheFrameIsReported() {
        let findings = LumenConformance.overflow(sizes: [CGSize(width: 900, height: 560)]) {
            Color.gray.frame(minWidth: 400, minHeight: 600)
        }
        XCTAssertEqual(findings.map(\.message), ["the content is 40 pt taller than its 560 pt frame"])
    }

    func testFlexibleAndFittingContentPasses() {
        XCTAssertEqual(LumenConformance.overflow(sizes: [CGSize(width: 456, height: 144)]) {
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in Color.red.frame(width: 128, height: 128) }
                Color.red.frame(width: 32, height: 32)
            }
            .padding(8)
        }, [])
        XCTAssertEqual(LumenConformance.overflow(sizes: sizes) {
            Text(String(repeating: "Wrapping text fills what it's given. ", count: 30)).padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }, [])
    }
}
