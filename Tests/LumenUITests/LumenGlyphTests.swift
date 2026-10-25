import SwiftUI
import XCTest
@testable import LumenUI

@MainActor
final class LumenGlyphTests: XCTestCase {
    func testBuiltInsHaveUniqueLumenNames() {
        let names = LumenGlyph.builtIns.map(\.symbolName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("lumen.") })
        XCTAssertEqual(LumenGlyph.families.prefix(3), ["Lumen", "Binary Analysis", "Imaging"])
    }

    /// Every mark stays inside the grid's 2…22 live area, strokes included at bold, so glyphs never
    /// clip in tiles and share one optical size (C-39).
    func testEveryBuiltInDrawsInsideTheGrid() {
        let grid = CGRect(x: 0, y: 0, width: LumenGlyph.gridSize, height: LumenGlyph.gridSize).insetBy(dx: 1.95, dy: 1.95)
        for glyph in LumenGlyph.builtIns {
            let d = glyph.drawing
            XCTAssertFalse(d.stroke.isEmpty && d.fill.isEmpty, "\(glyph.id) draws nothing at full strength")
            let halfStroke = LumenGlyphView.Weight.bold.lineWidth / 2
            let bounds = [d.stroke.isEmpty ? nil : d.stroke.boundingRect.insetBy(dx: -halfStroke, dy: -halfStroke),
                          d.fill.isEmpty ? nil : d.fill.boundingRect,
                          d.tint.isEmpty ? nil : d.tint.boundingRect].compactMap(\.self)
            for rect in bounds {
                XCTAssertTrue(grid.contains(rect), "\(glyph.id) reaches \(rect), outside the grid")
            }
        }
    }

    func testNamesResolveGlyphsAndLeaveSFSymbolsAlone() {
        XCTAssertEqual(LumenGlyph.named("lumen.callGraph"), .callGraph)
        XCTAssertNil(LumenGlyph.named("star.fill"))
        XCTAssertNil(LumenGlyph.named("lumen.noSuchGlyph"))
    }

    func testAppsRegisterTheirOwnGlyphsButCannotReplaceBuiltIns() {
        let own = LumenGlyph(id: "test.owl", title: "Owl", family: "Tests") { $0.fill.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16)) }
        let impostor = LumenGlyph(id: "callGraph", title: "Not a call graph", family: "Tests") { $0.fill.addRect(CGRect(x: 4, y: 4, width: 2, height: 2)) }
        LumenGlyph.register([own, impostor])
        XCTAssertEqual(LumenGlyph.named("lumen.test.owl")?.title, "Owl")
        XCTAssertTrue(LumenGlyph.all.contains(own))
        XCTAssertEqual(LumenGlyph.named("lumen.callGraph")?.title, "Call Graph", "Built-ins win")
        XCTAssertEqual(LumenGlyph.all.filter { $0.id == "callGraph" }.count, 1)
    }

    func testTemplateImagesAreTintableAndSized() throws {
        let image = try XCTUnwrap(LumenGlyph.breakpoint.templateImage(size: 16))
        XCTAssertTrue(image.isTemplate, "Native menus tint template images, including the highlight")
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(image.accessibilityDescription, "Breakpoint")
    }

    func testSymbolsRenderForGlyphsAndSFSymbols() {
        for name in ["lumen.anonymize", "star.fill"] {
            let view = HStack { LumenSymbol(name); LumenSymbol(name, size: 20); LumenIconTile(name, hue: .hueTeal, size: 28) }
                .font(.title2).foregroundStyle(.black)
            XCTAssertNotNil(ImageRenderer(content: view.padding(4)).cgImage, name)
        }
    }
}
