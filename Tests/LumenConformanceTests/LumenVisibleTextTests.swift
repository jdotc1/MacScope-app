import AppKit
import SwiftUI
import XCTest
import LumenTokens
import LumenUI
import LumenConformance

/// PRINCIPLES §6 for columns of values: two different values that truncate to the same
/// visible text read as one. MacScope's members table showed "triggerAna…" for both
/// triggerAnalysisOnAppear and triggerAnalysisOnChange; the 8-character floor passed each.
@MainActor
final class LumenVisibleTextTests: XCTestCase {
    let font = NSFont.systemFont(ofSize: 12)
    let members = ["triggerAnalysisOnAppear", "triggerAnalysisOnChange", "count"]

    private func column(width: CGFloat, truncation: Text.TruncationMode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(members, id: \.self) { name in
                Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(truncation)
                    .lumenReportsVisibleText(name, column: "Members", font: self.font, truncation: truncation)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    func testTailTruncatedDuplicatesAreReported() {
        let findings = LumenConformance.truncation(sizes: [CGSize(width: 300, height: 120)]) { column(width: 80, truncation: .tail) }
        XCTAssertEqual(findings.count, 1, findings.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(findings.first?.message.hasPrefix("“Members” shows “trigger") ?? false, "\(findings)")
        XCTAssertTrue(findings.first?.message.hasSuffix("for “triggerAnalysisOnAppear”, “triggerAnalysisOnChange”") ?? false, "\(findings)")
    }

    /// The fix MacScope shipped (`LumenTableText(truncationMode: .middle)`) tells them apart.
    func testMiddleTruncationThatKeepsTheEndsPasses() {
        XCTAssertEqual(LumenConformance.truncation(sizes: [CGSize(width: 300, height: 120)]) { column(width: 110, truncation: .middle) }, [])
    }

    func testValuesThatFitPass() {
        XCTAssertEqual(LumenConformance.truncation(sizes: [CGSize(width: 400, height: 120)]) { column(width: 220, truncation: .tail) }, [])
    }

    func testThePureCheckForAnAppsOwnColumn() {
        let findings = LumenConformance.visibleDuplicates(column: "Type", values: ["CalculatorModel", "CalculatorMode", "Display"],
                                                          width: 70, font: font)
        XCTAssertEqual(findings.count, 1, "\(findings)")
        XCTAssertEqual(LumenConformance.visibleDuplicates(column: "Type", values: ["CalculatorModel", "CalculatorMode"], width: 300, font: font), [])
    }

    func testVisibleTextEstimate() {
        XCTAssertEqual(LumenVisibleText.visible("short", width: 200, font: font), "short")
        let tail = LumenVisibleText.visible("triggerAnalysisOnAppear", width: 80, font: font)
        XCTAssertTrue(tail.hasPrefix("trigger") && tail.hasSuffix("…"), tail)
        let middle = LumenVisibleText.visible("triggerAnalysisOnAppear", width: 110, font: font, truncation: .middle)
        XCTAssertTrue(middle.contains("…") && middle.hasSuffix("ppear"), middle)
        let head = LumenVisibleText.visible("triggerAnalysisOnAppear", width: 80, font: font, truncation: .head)
        XCTAssertTrue(head.hasPrefix("…") && head.hasSuffix("Appear"), head)
    }
}
