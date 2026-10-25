import AppKit
import SwiftUI
import XCTest
@testable import LumenUI

@MainActor
final class LumenSemanticSelectionTests: XCTestCase {
    func testSemanticDisplayKeepsOriginalFieldEditorAndAccessibilityText() throws {
        let original = "Framework.Module.Container<Result<Value, Failure>>"
        let host = NSHostingView(rootView: LumenCodeValue(value: original,
            font: .system(size: 10, design: .monospaced),
            nativeFont: .monospacedSystemFont(ofSize: 10, weight: .regular),
            color: .primary, kind: .type, lineLimit: 2).frame(width: 110))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 110, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findField(_ view: NSView) -> NSTextField? {
            (view as? NSTextField) ?? view.subviews.lazy.compactMap(findField).first
        }
        let field = try XCTUnwrap(findField(host))
        let cell = try XCTUnwrap(field.cell as? LumenSemanticCodeCell)
        let lines = cell.presentation(width: 106)
        XCTAssertLessThanOrEqual(lines.count, 2)
        XCTAssertNotEqual(lines.joined(), original, "The narrow display must actually exercise abbreviation")
        XCTAssertEqual(field.attributedStringValue.string, original)
        XCTAssertEqual(field.toolTip, original)
        XCTAssertEqual(field.accessibilityValue(), original)
        XCTAssertTrue(field.frame.width.isFinite)
        XCTAssertTrue(field.frame.height.isFinite)
        XCTAssertGreaterThan(field.frame.height, 0)
        XCTAssertLessThanOrEqual(field.frame.height, 36)

        // AppKit's selection editor must contain the original source, so copying any
        // selected range cannot silently substitute an abbreviated presentation.
        let editor = try XCTUnwrap(window.fieldEditor(true, for: field))
        cell.select(withFrame: field.bounds, in: field, editor: editor,
            delegate: nil, start: 0, length: (original as NSString).length)
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: (original as NSString).length))
        window.endEditing(for: nil)
    }
}
