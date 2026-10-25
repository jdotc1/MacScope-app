import AppKit
import SwiftUI
import XCTest
@testable import LumenUI

@MainActor
final class LumenCodeValueTests: XCTestCase {
    func testNativeCodeValueRetainsOriginalAtNarrowWidths() throws {
        let original = "chevron.left.forwardslash.chevron.right"
        let host = NSHostingView(rootView: LumenCodeValue(value: original, font: .caption.monospaced(),
                                                       nativeFont: .monospacedSystemFont(ofSize: 10, weight: .regular),
                                                       color: .primary).frame(width: 120))
        host.frame = CGRect(x: 0, y: 0, width: 120, height: 60)
        host.layoutSubtreeIfNeeded()
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField { return field }
            return view.subviews.lazy.compactMap { textField(in: $0) }.first
        }
        let field = try XCTUnwrap(textField(in: host))
        XCTAssertEqual(field.attributedStringValue.string, original, "Selection and copying retain the source identifier")
        XCTAssertEqual(field.toolTip, original)
        let paragraph = try XCTUnwrap(field.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertFalse(paragraph.usesDefaultHyphenation)
        XCTAssertEqual(paragraph.hyphenationFactor, 0)
        XCTAssertLessThanOrEqual(field.alignmentRect(forFrame: field.bounds).width, 120,
                                 "AppKit’s alignment rect excludes the text field’s outer insets")
        XCTAssertGreaterThan(field.frame.height, 0)
        XCTAssertLessThanOrEqual(field.frame.height, 36, "The narrow value remains within two caption lines")
    }

    /// R1: the property-row cell drew only "…" for a UUID in a 170 pt value column.
    func testCodeCellNeverDrawsBareEllipsisForUnbreakableValues() {
        let cell = LumenSemanticCodeCell(textCell: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")
        cell.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.kind = LumenSemanticTextPolicy.labelKind(for: cell.stringValue)
        cell.semanticLineLimit = 2
        XCTAssertEqual(cell.presentation(width: 170).joined(), cell.stringValue, "The UUID wraps whole over two lines")
        XCTAssertEqual(cell.presentation(width: 170), cell.presentation(width: 170), "The cached plan is stable")
        cell.semanticLineLimit = 1
        let single = cell.presentation(width: 170)
        XCTAssertEqual(single.count, 1)
        XCTAssertTrue(single[0].hasPrefix("3F25") && single[0].hasSuffix("3301") && single[0].contains("…"), "\(single)")
        cell.stringValue = "-[NSViewController loadViewIfRequired]+112"
        let reference = cell.presentation(width: 200)
        XCTAssertEqual(reference.count, 1)
        XCTAssertTrue(reference[0].hasSuffix("]+112") && reference[0] != "…", "\(reference)")
    }
}
