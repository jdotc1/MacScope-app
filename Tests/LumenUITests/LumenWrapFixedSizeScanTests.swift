import Foundation
import XCTest

/// PRINCIPLES §6, narrow sizing, at the source: text that wraps without truncating uses
/// `.lumenWrapsWithoutTruncating()`, never a bare `.fixedSize(horizontal: false, vertical: true)`.
/// The bare form answers a split view's near-zero-width sizing pass with the text a few letters per
/// line, and that height becomes a minimum taller than the window (the Workspace window,
/// among other components).
///
/// A heuristic scan: for each bare use, the statement it hangs off (back over `.modifier` lines) is
/// searched for the `Text(…)` it applies to. Other uses are keyed by the prefix on the modifier's
/// line, including empty prefixes for multiline containers. Every bare use must be allow-listed
/// with a reason; containers can force arbitrary child text to wrap just as bare Text does.
/// A new bare site fails, and a converted one must leave the list.
final class LumenWrapFixedSizeScanTests: XCTestCase {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/LumenUI", directoryHint: .isDirectory)

    /// "<file> · <Text expression or container prefix>" (with " #n" for identical sites).
    static let allowed: Set<String> = [
        // Results scroll and have a 380 pt height ceiling, independent of the proposed width.
        "LumenCommandPalette.swift · container:",
        // ViewThatFits measures the first candidate's ideal width; the fallback fixes both axes.
        // Live horizontal scrolling proposes an unspecified width to the lazy row.
        "LumenExtras.swift · container:",
        "LumenExtras.swift · container: #2",
        // A hidden measurement in a GeometryReader background cannot enlarge the parent.
        "LumenOverflow.swift · container:",
        // Both texts in every stat cell have lineLimit(1).
        "LumenPanelBar.swift · container:",
        // The notice card is a fixed 340 pt wide: its title and message are never measured narrower.
        "LumenDataViews.swift · Text(notice.title)",
        "LumenDataViews.swift · Text(message)",
        // A bounded line limit (3): at most three lines tall at any width.
        "LumenExtras.swift · Text(summary)",
        // A popover's fixed 260 pt width.
        "LumenForms.swift · Text(message)",
        // A bounded line limit (2), middle-truncated past it.
        "LumenInspector.swift · Text(title)",
        // A popover's fixed 260 pt width (`lumenPopover(width: 260)`).
        "LumenPopover.swift · Text(message)",
        // A bounded line limit (2).
        "LumenSheet.swift · Text(status.message)",
        // A fixed-width label column (`frame(width: labelWidth ?? propertyLabelWidth)`).
        "LumenSheet.swift · Text(label)",
    ]

    static let bare = try! NSRegularExpression(pattern: #"\.fixedSize\(\s*horizontal:\s*false,\s*vertical:\s*true\s*\)"#)

    /// Every bare use in `source`, keyed as `allowed` is.
    static func bareTextSites(in source: String, file: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        var keys: [String] = []
        var seen: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            if trimmed[index].hasPrefix("//") { continue }
            guard let match = bare.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range, in: line) else { continue }
            // The statement: back over `.modifier` lines to the line the chain hangs off; on the
            // modifier's own line, only what comes before it.
            var start = index
            while start > 0, index - start < 6, trimmed[start].hasPrefix(".") { start -= 1 }
            let chain = Array(lines[start..<index]) + [String(line[..<range.lowerBound])]
            let prefix = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let text = chain.reversed().lazy.compactMap(textExpression(in:)).first
                ?? ("container:" + (prefix.isEmpty ? "" : " " + prefix))
            let count = seen[text, default: 0] + 1
            seen[text] = count
            keys.append("\(file) · \(text)" + (count > 1 ? " #\(count)" : ""))
        }
        return keys
    }

    /// The last `Text(…)` on `line`, with its balanced arguments.
    static func textExpression(in line: String) -> String? {
        guard let start = line.range(of: "Text(", options: .backwards) else { return nil }
        // `LumenHighlightedText(`, `LumenSemanticText(` and the like are components, not Text.
        if start.lowerBound > line.startIndex, line[line.index(before: start.lowerBound)].isLetter { return nil }
        var depth = 0
        for position in line[start.lowerBound...].indices {
            let character = line[position]
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth == 0 { return String(line[start.lowerBound...position]) } }
        }
        return String(line[start.lowerBound...])
    }

    func testNoTextWrapsWithABareFixedSize() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no sources at \(Self.sources.path)")
        var found: [String] = []
        for file in files {
            found += Self.bareTextSites(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        let new = Set(found).subtracting(Self.allowed).sorted()
        let stale = Self.allowed.subtracting(found).sorted()
        XCTAssertEqual(new, [], "Unbounded content with a bare .fixedSize(horizontal: false, vertical: true); use .lumenWrapsWithoutTruncating(), "
                       + "or allow-list it with the reason it stays bounded (a line limit, a fixed-width container):\n"
                       + new.joined(separator: "\n"))
        XCTAssertEqual(stale, [], "allow-listed sites no longer occur; remove them:\n" + stale.joined(separator: "\n"))
    }

    func testTheScanFindsBareTextAndContainers() {
        let source = """
            Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(summary).lumenWrapsWithoutTruncating()
            HStack { Text(a); Text(b) }
            rowStack.fixedSize(horizontal: false, vertical: true)
            LumenHighlightedText(name, matching: query).fixedSize(horizontal: false, vertical: true)
            text(for: line)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            // Text(old).fixedSize(horizontal: false, vertical: true)
            """
        XCTAssertEqual(Self.bareTextSites(in: source, file: "X.swift"), [
            "X.swift · Text(title)", "X.swift · Text(detail)",
            "X.swift · container: rowStack", "X.swift · container: LumenHighlightedText(name, matching: query)",
            "X.swift · container:",
        ])
    }
}
