import Foundation
import SwiftUI
import XCTest
import LumenConformance
@testable import LumenUI

/// PRINCIPLES §7, icon-only controls: a button whose label is only an icon carries
/// `.lumenIconOnlyControl()`, which measures its hit area, and an undersized one is reported.
/// `.labelStyle(.iconOnly)` alone doesn't count: it makes a titled button icon-only without
/// measuring it (an 18×18 notice dismiss button passed that way).
@MainActor
final class LumenIconOnlyControlTests: XCTestCase {
    let sizes = [CGSize(width: 320, height: 200)]

    func testAnUndersizedIconOnlyButtonIsReported() {
        let findings = LumenConformance.iconScale(sizes: sizes) {
            Button {} label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .frame(width: 16, height: 16)
                .lumenIconOnlyControl("Add")
        }
        XCTAssertEqual(findings.map(\.message), ["“Add” icon-only control is 16×16 pt; its hit area needs 24 pt"])
    }

    func testAFullSizeIconOnlyButtonPasses() {
        let findings = LumenConformance.iconScale(sizes: sizes) {
            Button {} label: { Image(systemName: "plus") }
                .buttonStyle(.lumenPlain)
                .lumenIconOnlyControl("Add")
        }
        XCTAssertEqual(findings, [])
    }

    func testAQuietButtonKeepsItsHitAreaWhenItsSymbolIsMissing() {
        let findings = LumenConformance.iconScale(sizes: sizes) {
            Button {} label: { Color.clear.frame(width: 0, height: 16) }
                .buttonStyle(.lumenQuiet)
                .lumenIconOnlyControl("Missing symbol")
                .fixedSize()
        }
        XCTAssertEqual(findings, [])
    }

    /// A titled button drawn icon-only is measured once it's marked: the notice dismiss button's case.
    func testAnUndersizedIconOnlyStyledButtonIsReportedWhenMarked() {
        let findings = LumenConformance.iconScale(sizes: sizes) {
            Button("Dismiss", systemImage: "xmark") {}
                .labelStyle(.iconOnly).buttonStyle(.plain)
                .frame(width: 18, height: 18)
                .lumenIconOnlyControl("Dismiss")
        }
        XCTAssertEqual(findings.map(\.message), ["“Dismiss” icon-only control is 18×18 pt; its hit area needs 24 pt"])
    }

    // MARK: Source scan

    /// Icon-only buttons in Lumen's sources that carry no `.lumenIconOnlyControl()`, as
    /// "<file>: <label>", that are genuinely exempt: each is one part of a larger control whose
    /// hit area is the whole (a stepper's halves). Everything else is fixed, not listed.
    static let allowed: Set<String> = [
        // A stepper's up/down halves, 15×11: one control together, 15×22, as macOS draws it.
        "LumenForms.swift: LumenSymbol(symbol).font(.system(size: metrics.layout.disclosureGlyph - 1, weight: .bold)).foregroundStyle(palette[.fgSecondary])",
    ]

    func testEveryIconOnlyButtonInLumenIsMarked() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LumenUI", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty)
        var unmarked: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for label in IconButtonScan.unmarkedIconButtons(in: text) {
                unmarked.append("\(file.lastPathComponent): \(label)")
            }
        }
        let new = unmarked.filter { !Self.allowed.contains($0) }
        XCTAssertEqual(new, [], "mark icon-only buttons with .lumenIconOnlyControl() and give them a 24 pt hit area:\n"
                       + new.joined(separator: "\n"))
        let stale = Self.allowed.subtracting(unmarked)
        XCTAssertEqual(stale, [], "allow-list entries that no longer occur; remove them")
    }

    func testTheScanFindsEveryIconOnlyForm() {
        let source = """
        Button(action: add) { Image(systemName: "plus") }
            .buttonStyle(.plain)
        Button { remove() } label: { LumenSymbol("minus").font(.caption) }
            .buttonStyle(.plain)
            .lumenIconOnlyControl()
        Button { go() } label: { Label("Go", systemImage: "arrow.right") }
        Button("Done") { finish() }
        Button("Dismiss", systemImage: "xmark", action: dismiss)
            .labelStyle(.iconOnly).buttonStyle(.plain)
        Button("Share", systemImage: "square.and.arrow.up") { share() }
            .labelStyle(.iconOnly).lumenIconOnlyControl("Share")
        Button { help() } label: { Text("?").font(.caption) }
            .buttonStyle(.plain)
        Button { pick() } label: { Circle().fill(color).frame(width: 12, height: 12) }
        Button { more() } label: { Label("More", systemImage: "ellipsis") }.labelStyle(.iconOnly)
        Button { save() } label: { Text("Save") }
        """
        XCTAssertEqual(IconButtonScan.unmarkedIconButtons(in: source), [
            "Image(systemName: \"plus\")",
            "Button(\"Dismiss\", systemImage: \"xmark\", action: dismiss)",
            "Text(\"?\").font(.caption)",
            "Circle().fill(color).frame(width: 12, height: 12)",
            "Label(\"More\", systemImage: \"ellipsis\")",
        ])
    }
}

/// A small scanner for icon-only buttons in source: `Button(action:) { Image… }`,
/// `Button { … } label: { Image… }`, labels that are a glyph of text (`Text("?")`) or a shape, and
/// any button (titled or not) styled `.labelStyle(.iconOnly)`. A button is marked when its modifier
/// chain carries `.lumenIconOnlyControl(`.
enum IconButtonScan {
    /// Shapes drawn as a whole button label (a swatch, a dot).
    static let shapes = ["Circle()", "Capsule()", "Ellipse()", "Rectangle()", "RoundedRectangle("]

    static func unmarkedIconButtons(in text: String) -> [String] {
        let chars = Array(text)
        var results: [String] = []
        var i = 0
        func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        func skipSpace(_ j: inout Int) { while j < chars.count, chars[j].isWhitespace { j += 1 } }
        /// Index just past the balanced group that opens at `j`.
        func skipGroup(_ j: Int, open: Character, close: Character) -> Int {
            var depth = 0, k = j, inString = false
            while k < chars.count {
                let c = chars[k]
                if c == "\"" && (k == 0 || chars[k - 1] != "\\") { inString.toggle() }
                if !inString {
                    if c == open { depth += 1 }
                    if c == close { depth -= 1; if depth == 0 { return k + 1 } }
                }
                k += 1
            }
            return chars.count
        }
        /// The modifier chain after `start`: the rest of its line, then each following line that starts with ".".
        func chain(after start: Int) -> String {
            var end = start
            while end < chars.count, chars[end] != "\n" { end += 1 }
            var chain = String(chars[start..<end])
            var lineStart = end + 1
            while lineStart < chars.count {
                var lineEnd = lineStart
                while lineEnd < chars.count, chars[lineEnd] != "\n" { lineEnd += 1 }
                let line = String(chars[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix(".") else { break }
                chain += line
                lineStart = lineEnd + 1
            }
            return chain
        }
        func firstLine(_ s: String) -> String {
            (s.split(separator: "\n").first.map(String.init) ?? s).trimmingCharacters(in: .whitespaces)
        }
        while i < chars.count {
            guard chars[i] == "B", i + 6 <= chars.count, String(chars[i..<i + 6]) == "Button",
                  i == 0 || !isIdent(chars[i - 1]), i + 6 == chars.count || !isIdent(chars[i + 6]) else { i += 1; continue }
            var j = i + 6
            var arguments = ""
            var argumentsEnd = j
            if j < chars.count, chars[j] == "(" {
                let end = skipGroup(j, open: "(", close: ")")
                arguments = String(chars[j..<end])
                j = end
                argumentsEnd = end
            }
            var k = j
            skipSpace(&k)
            let hasClosure = k < chars.count && chars[k] == "{"
            var label: String?
            var end = argumentsEnd
            if hasClosure {
                var labelRange = k..<skipGroup(k, open: "{", close: "}")
                var m = labelRange.upperBound
                skipSpace(&m)
                if m + 6 <= chars.count, String(chars[m..<m + 6]) == "label:" {
                    m += 6
                    skipSpace(&m)
                    guard m < chars.count, chars[m] == "{" else { i += 6; continue }
                    labelRange = m..<skipGroup(m, open: "{", close: "}")
                    label = String(chars[(labelRange.lowerBound + 1)..<max(labelRange.lowerBound + 1, labelRange.upperBound - 1)])
                } else if arguments.contains("action:") {
                    label = String(chars[(labelRange.lowerBound + 1)..<max(labelRange.lowerBound + 1, labelRange.upperBound - 1)])
                }
                // Otherwise a titled button: the closure is its action.
                end = labelRange.upperBound
            } else if arguments.isEmpty {
                i += 6
                continue   // not a button call (a type name, say)
            }
            let modifiers = chain(after: end)
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            var iconOnly = false
            if let trimmed {
                let symbol = (trimmed.hasPrefix("Image(systemName:") || trimmed.hasPrefix("LumenSymbol("))
                    && !trimmed.contains("Text(") && !trimmed.contains("Label")
                let glyphText = trimmed.range(of: #"^Text\("[^"]{1,2}"\)"#, options: .regularExpression) != nil
                let shape = shapes.contains { trimmed.hasPrefix($0) } && !trimmed.contains("Text(") && !trimmed.contains("Label")
                iconOnly = symbol || glyphText || shape
            }
            if modifiers.contains(".labelStyle(.iconOnly)") { iconOnly = true }
            if iconOnly && !modifiers.contains(".lumenIconOnlyControl(") {
                results.append(trimmed.map(firstLine) ?? firstLine("Button" + arguments))
            }
            i = max(end, i + 6)
        }
        return results
    }
}
