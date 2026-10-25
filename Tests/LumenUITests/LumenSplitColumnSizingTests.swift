import AppKit
import SwiftUI
import XCTest
@testable import LumenUI

/// Minimum-height regressions for generic content and the console's non-scrolling path.
@MainActor
final class LumenSplitColumnSizingTests: XCTestCase {
    private let sentence = "No symbols in the current document, so there is nothing to list yet"

    private func assertShort(_ view: some View, limit: CGFloat = 160,
                             file: StaticString = #filePath, line: UInt = #line) {
        let host = NSHostingController(rootView: view.lumenPaletteRoot())
        let size = host.sizeThatFits(in: CGSize(width: 1, height: 0))
        XCTAssertGreaterThan(size.height, 0, file: file, line: line)
        XCTAssertLessThan(size.height, limit, "1 pt proposal asks for \(size.height) pt", file: file, line: line)
    }

    func testFittedTableStaysShortWhenMeasuredNarrow() {
        assertShort(LumenTable([Row(id: 1)], selection: .constant(nil), height: .fitRows(maxVisible: 1),
                               columns: [LumenTableColumn("Message") { _ in Text(self.sentence) }]))
    }

    func testInspectorStaysShortWhenMeasuredNarrow() {
        assertShort(LumenInspector(scrolls: false) { Text(self.sentence) })
    }

    func testConsoleStaysShortWhenMeasuredNarrow() {
        assertShort(LumenConsole(lines: [LumenConsoleLine(.output, sentence)], input: .constant(""),
                                 prompt: "", placeholder: "", drawsStatic: true, onSubmit: { _ in }))
    }

    func testUnderTitleBarStaysShortWhenMeasuredNarrow() {
        assertShort(Color.clear.frame(height: 1).lumenTopBar { Text(sentence) }
            .lumenTopBarPlacement(.underTitleBar))
    }
}

private struct Row: Identifiable { let id: Int }
