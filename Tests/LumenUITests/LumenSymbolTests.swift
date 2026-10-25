import AppKit
import SwiftUI
import XCTest
@testable import LumenUI

/// Every Lumen glyph draws as an SF Symbol: Apple's where one fits, a custom symbol from LumenUI's
/// catalog otherwise (PRINCIPLES §7).
final class LumenSymbolTests: XCTestCase {
    func testEveryBuiltInGlyphHasASymbol() {
        for glyph in LumenGlyph.builtIns {
            let name = glyph.symbolName
            XCTAssertTrue(LumenGlyph.customSymbols.contains(name) || LumenGlyph.sfEquivalents[name] != nil, "\(name) has no SF Symbol")
        }
    }

    func testCustomSymbolsLoadFromTheCatalog() throws {
        // SwiftPM's command-line resource processing can copy an xcassets directory without
        // compiling it. Missing or broken compiled catalogs must still fail, not skip.
        if Bundle.module.url(forResource: "Assets", withExtension: "car") == nil {
            let catalog = try XCTUnwrap(Bundle.module.url(forResource: "Symbols", withExtension: "xcassets"),
                                        "Neither the compiled nor the source symbol catalog was packaged")
            for name in LumenGlyph.customSymbols.union(LumenGlyph.customFillSymbols).sorted() {
                let symbolSet = catalog.appendingPathComponent(name + ".symbolset", isDirectory: true)
                let data = try Data(contentsOf: symbolSet.appendingPathComponent("Contents.json"))
                let manifest = try JSONDecoder().decode(SymbolManifest.self, from: data)
                XCTAssertFalse(manifest.symbols.isEmpty, "\(name) has no symbol sources")
                for symbol in manifest.symbols {
                    let source = symbolSet.appendingPathComponent(symbol.filename)
                    XCTAssertEqual(source.pathExtension, "svg", "\(name) must reference an SVG symbol template")
                    let template = try String(contentsOf: source, encoding: .utf8)
                    XCTAssertTrue(template.contains("<svg"), "\(name) has no SVG symbol template")
                }
            }
            throw XCTSkip("This build copied Symbols.xcassets without compiling Assets.car; runtime symbol lookup requires a compiled asset catalog")
        }
        for name in LumenGlyph.customSymbols.union(LumenGlyph.customFillSymbols).sorted() {
            XCTAssertNotNil(NSImage(symbolName: name, bundle: .module, variableValue: 1), "\(name) didn't load from LumenUI's catalog")
        }
    }

    private struct SymbolManifest: Decodable {
        struct Symbol: Decodable { let filename: String }
        let symbols: [Symbol]
    }

    func testSFEquivalentsExist() {
        for (name, symbol) in LumenGlyph.sfEquivalents.sorted(by: { $0.key < $1.key }) {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(name) → \(symbol) isn't an SF Symbol")
            if let fill = LumenGlyph.sfFillOverrides[symbol] {
                XCTAssertNotNil(NSImage(systemSymbolName: fill, accessibilityDescription: nil), "\(symbol) → \(fill) isn't an SF Symbol")
            }
        }
    }
}
