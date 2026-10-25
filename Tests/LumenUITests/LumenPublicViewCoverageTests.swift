import Foundation
import XCTest

/// Every public Lumen view is exercised somewhere a person or a test looks at it: a Catalog page (so
/// it's seen, and the Catalog rule tests check its labels, tiles and containers) or a golden image.
/// Exercised means built in code there (`Name(`, `Name {`, `Name.factory(`), not named in a comment
/// or a string.
/// Views missing from both today are allow-listed; a new public view must show up in one of them.
final class LumenPublicViewCoverageTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Public views in neither the Catalog nor the golden tests. Each should be added to a
    /// Catalog page or a golden.
    static let knownUnexercised: Set<String> = [
        // The original hand-drawn glyph paths; every built-in glyph now draws as an SF Symbol, and this
        // remains only for app-registered glyphs without one.
        "LumenGlyphView",
        // not yet exercised
        "LumenInlineField",
        "LumenRadioButton",
        "LumenSidebarActions",
        "LumenStarfield",
        "LumenThemeCard",
        "LumenThemeEditor",
        "LumenVariableRow",
    ]

    /// Public views the Catalog and goldens see only inside another public view that builds them:
    /// view → the view it's drawn in. Exercised when that one is.
    static let shownInside: [String: String] = [
        "LumenLogFilterBar": "LumenLogConsole",   // its bar (LumenPanels.swift)
    ]

    static func swiftFiles(in directory: String) throws -> [URL] {
        let url = root.appending(path: directory, directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
    }

    static func publicViews() throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: #"public struct (Lumen\w+)(<[^>{]*>)?\s*:\s*View\b"#)
        var names: Set<String> = []
        for file in try swiftFiles(in: "Sources/LumenUI") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
            }
        }
        return names
    }

    /// `source` with its comments and string literals blanked, so a name only mentioned there (a doc
    /// comment, a label) doesn't count as the view being built.
    static func code(_ source: String) -> String {
        var out = "", chars = Array(source), i = 0
        func at(_ offset: Int) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }
        while i < chars.count {
            if chars[i] == "/", at(1) == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if chars[i] == "/", at(1) == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && at(1) == "/") { i += 1 }
                i += 2
            } else if chars[i] == "\"" {
                let triple = at(1) == "\"" && at(2) == "\""
                i += triple ? 3 : 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if triple ? (chars[i] == "\"" && at(1) == "\"" && at(2) == "\"") : (chars[i] == "\"" || chars[i] == "\n") { break }
                    i += 1
                }
                i += triple ? 3 : 1
                out.append("\"\"")
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    /// Whether `code` builds `name`: `Name(`, `Name {`, `Name<…>(` or `Name.factory(`, not just
    /// the name (as a whole word, so LumenRow isn't counted as used by LumenRowGroup).
    static func instantiates(_ name: String, in code: String) -> Bool {
        code.range(of: #"\b\#(name)\b(<[^>\n]*>)?\s*(\(|\{|\.\w+\s*[({])"#, options: .regularExpression) != nil
    }

    func testCoverageCountsOnlyCodeThatBuildsTheView() {
        XCTAssertFalse(Self.instantiates("LumenCoverageProbe", in: Self.code("// LumenCoverageProbe()\nlet a = \"LumenCoverageProbe()\"")))
        XCTAssertFalse(Self.instantiates("LumenCoverageProbe", in: Self.code("/* LumenCoverageProbe { } */ struct X: LumenCoverageProbe")))
        XCTAssertTrue(Self.instantiates("LumenCoverageProbe", in: Self.code("VStack { LumenCoverageProbe(\"x\") }")))
        XCTAssertTrue(Self.instantiates("LumenCoverageProbe", in: Self.code("LumenCoverageProbe<Text> { Text(\"x\") }")))
        XCTAssertTrue(Self.instantiates("LumenCoverageProbe", in: Self.code("LumenCoverageProbe.compact(items)")))
        XCTAssertFalse(Self.instantiates("LumenRow", in: Self.code("LumenRowGroup { }")))
    }

    func testEveryPublicViewIsInTheCatalogOrAGolden() throws {
        let views = try Self.publicViews()
        XCTAssertGreaterThan(views.count, 20, "the scan found too few public views")
        // The MacScope workspace shell is a Catalog page whose views live in their own target.
        var exercised = try (Self.swiftFiles(in: "Sources/LumenCatalog") + Self.swiftFiles(in: "Sources/MacScopeShell")).map { try String(contentsOf: $0, encoding: .utf8) }
        exercised.append(try String(contentsOf: Self.root.appending(path: "Tests/LumenUITests/LumenGoldenTests.swift"), encoding: .utf8))
        let corpus = Self.code(exercised.joined(separator: "\n"))
        let missing = views.filter { name in
            if let container = Self.shownInside[name] { return !Self.instantiates(container, in: corpus) }
            return !Self.instantiates(name, in: corpus)
        }
        let lumenUI = try Self.code(Self.swiftFiles(in: "Sources/LumenUI").map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n"))
        for (name, container) in Self.shownInside {
            XCTAssertTrue(views.contains(container) && Self.instantiates(name, in: lumenUI), "\(container) or a build of \(name) in LumenUI is gone; update shownInside")
        }
        let new = missing.subtracting(Self.knownUnexercised).sorted()
        let stale = Self.knownUnexercised.subtracting(missing).sorted()
        XCTAssertEqual(new, [], "public views in neither the Catalog nor a golden:\n" + new.map { "\"\($0)\"," }.joined(separator: "\n"))
        XCTAssertEqual(stale, [], "allow-listed views are now exercised (or gone); remove them:\n" + stale.joined(separator: "\n"))
    }
}
