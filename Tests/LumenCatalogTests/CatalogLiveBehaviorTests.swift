import AppKit
import SwiftUI
import XCTest
@testable import LumenCatalog
@testable import LumenUI

@MainActor
final class CatalogLiveBehaviorTests: XCTestCase {
    func testWorkspaceNewDocumentAppendsSelectsAndCloses() throws {
        var model = WorkspaceDemoModel()
        let originalIDs = model.tabs.map(\.id)
        for number in 2...4 {
            model.newDocument()
            XCTAssertEqual(model.tabs.last?.title, "untitled \(number)")
            XCTAssertEqual(model.selection, model.tabs.last?.id)
        }
        XCTAssertEqual(model.tabs.count, 6)
        XCTAssertEqual(Array(model.tabs.prefix(3)).map(\.id), originalIDs)
        XCTAssertEqual(Set(model.tabs.map(\.id)).count, 6)
        let selected = try XCTUnwrap(model.selection)
        model.close("style")
        XCTAssertEqual(model.selection, selected, "Closing another tab preserves selection")
        XCTAssertFalse(model.tabs.contains { $0.id == "style" })
        model.close(selected)
        XCTAssertFalse(model.tabs.contains { $0.id == selected })
        XCTAssertEqual(model.selection, model.tabs.last?.id)
        model.newDocument()
        XCTAssertEqual(model.tabs.last?.title, "untitled 5", "Closing does not reuse names or IDs")
        for tab in model.tabs { model.close(tab.id) }
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.selection)
        model.newDocument()
        XCTAssertEqual(model.tabs.last?.title, "untitled 6")
        XCTAssertEqual(model.selection, model.tabs.last?.id)
    }

    func testNarrowSemanticValueRendersShortenedAndRetainsOriginal() throws {
        let original = CatalogSemanticValues.values[0]
        let width = CatalogSemanticValues.narrowWidth
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let lines = LumenSemanticTextPolicy.presentation(for: original, kind: .path,
            width: width, maxLines: 1, measure: {
                ($0 as NSString).size(withAttributes: [.font: font]).width
            })
        let shortened = lines.joined()
        XCTAssertNotEqual(shortened, original)
        XCTAssertTrue(shortened.contains("…"))
        XCTAssertTrue(shortened.hasSuffix("Document.swift"))

        let semantic = LumenSemanticText(original, kind: .path)
        // The production context-menu Copy action reads this
        // unmodified source, independently of the candidate chosen by the layout.
        XCTAssertEqual(semantic.originalValue, original)
        let rendered = try image(semantic.font(.system(size: 12, design: .monospaced)), width: width)
        let expected = try image(Text(verbatim: shortened).font(.system(size: 12, design: .monospaced)), width: width)
        XCTAssertEqual(rendered, expected, "The actual semantic layout must draw the abbreviated candidate")

    }

    private func image<V: View>(_ view: V, width: CGFloat) throws -> Data {
        let renderer = ImageRenderer(content: view
            .foregroundStyle(.black)
            .frame(width: width, height: 24, alignment: .leading)
            .background(.white))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        return try XCTUnwrap(image.dataProvider?.data) as Data
    }
}
