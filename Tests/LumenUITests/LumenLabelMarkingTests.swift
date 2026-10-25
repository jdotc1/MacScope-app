import Foundation
import XCTest

/// PRINCIPLES §6, at the source: every one-line label in LumenUI says what happens when it doesn't
/// fit. A primary label reports itself when cut short (`.lumenNeverTruncates`); secondary detail
/// truncates in the middle (`.truncationMode(.middle)`), or at an explicit end with a help tag holding
/// the whole text (`.truncationMode(.tail)` + `.help(text)`). A `.lineLimit(1)` with none of these
/// silently cuts words off at the end, where no check sees it.
///
/// A heuristic scan: for each `.lineLimit(1)`, the modifier chain around it (two lines before, six
/// after) must hold one of the two. Sites known today are allow-listed by file and the `Text`
/// expression they limit (not by line number, so edits elsewhere don't disturb the list); a new
/// unmarked site fails, and a fixed one must leave the list.
final class LumenLabelMarkingTests: XCTestCase {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/LumenUI", directoryHint: .isDirectory)

    /// "<file> · <Text expression or line>" (with " #n" for the nth identical one in a file).
    /// Each entry is a deliberate exception, with its reason.
    /// A key that ends in ".lineLimit(1)" is a limit on a container (a stack of
    /// fields, a button row) with no `Text` nearby; the "#n" counts them in file order.
    static let knownUnmarked: Set<String> = [
        // Code lines clip at the pane's edge as an editor does; they aren't labels.
        "LumenCodePane.swift · Text(verbatim: $1.text)",
        // Static stand-ins for a TextField in offscreen renders; they clip as the field does.
        "LumenEditors.swift · Text(text)",
        // The status label: whole and marked when it may not truncate, tail plus help when it may
        // (the mode is a parameter, so the scan can't see either branch).
        "LumenStates.swift · Text(status.title)",
        // Table text: its truncation mode is a parameter, and it carries a help tag and the 8-character watch.
        "LumenControls.swift · Text(text)",
        // Containers: the limit applies to fields and buttons inside, each marked or sized itself.
        "LumenComponents.swift · .lineLimit(1)",          // keycap/label HStack, fixedSize horizontally
        "LumenComponents.swift · .lineLimit(1) #2",       // pill: a metric is fixed size; a metadata value truncates in the middle
        "LumenEditors.swift · .lineLimit(1)",             // text field row
        "LumenEditors.swift · .lineLimit(1) #2",          // text field row
        "LumenPickers.swift · .lineLimit(1)",             // trailing field
        "LumenThemeGallery.swift · .lineLimit(1)",        // Reload/Reveal link buttons
    ]

    /// The unmarked `.lineLimit(1)` sites in `source`, keyed as `knownUnmarked` is.
    static func unmarkedSites(in source: String, file: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        var keys: [String] = []
        var seen: [String: Int] = [:]
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.contains(".lineLimit(1)") {
            if trimmed[index].hasPrefix("//") { continue }
            // The modifier chain: back to the line it hangs off, forward over up to six `.modifier` lines.
            var start = index, end = index
            while start > 0, index - start < 6, trimmed[start].hasPrefix(".") { start -= 1 }
            while end + 1 < lines.count, end - index < 6, trimmed[end + 1].hasPrefix(".") { end += 1 }
            // On the lineLimit's own line, only what follows the last `Text(` before it counts as its chain.
            let own = line.range(of: ".lineLimit(1)").map { limit -> String in
                let head = line[..<limit.lowerBound]
                let from = head.range(of: "Text(", options: .backwards)?.lowerBound ?? line.startIndex
                return String(line[from...])
            } ?? line
            let chain = (Array(lines[start..<index]) + [own] + (end > index ? Array(lines[(index + 1)...end]) : [])).joined(separator: "\n")
            if chain.contains(".truncationMode(.middle)") || chain.contains(".lumenNeverTruncates") { continue }
            // Secondary detail may also truncate at an explicit end, as long as a help tag carries the whole text.
            if chain.contains(".help("), chain.contains(".truncationMode(.tail)") || chain.contains(".truncationMode(.head)") { continue }
            let snippet = textExpression(near: index, in: lines) ?? trimmed[index]
            let count = seen[snippet, default: 0] + 1
            seen[snippet] = count
            keys.append("\(file) · \(snippet)" + (count > 1 ? " #\(count)" : ""))
        }
        return keys
    }

    /// The `Text(…)` (or `Label(…)`) on the line or up to four lines above it: the label being limited.
    static func textExpression(near index: Int, in lines: [String]) -> String? {
        for offset in 0...4 where index - offset >= 0 {
            var line = lines[index - offset]
            if offset == 0, let limit = line.range(of: ".lineLimit(1)") { line = String(line[..<limit.lowerBound]) }
            for opener in ["Text(", "Label("] {
                guard let start = line.range(of: opener, options: .backwards) else { continue }
                var depth = 0
                var end = line.endIndex
                for position in line[start.lowerBound...].indices {
                    let character = line[position]
                    if character == "(" { depth += 1 }
                    if character == ")" { depth -= 1; if depth == 0 { end = line.index(after: position); break } }
                }
                return String(line[start.lowerBound..<end])
            }
        }
        return nil
    }

    func testEveryOneLineLabelIsMarked() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no sources at \(Self.sources.path)")
        var found: [String] = []
        for file in files {
            found += Self.unmarkedSites(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        let new = Set(found).subtracting(Self.knownUnmarked).sorted()
        let stale = Self.knownUnmarked.subtracting(found).sorted()
        XCTAssertEqual(new, [], "new unmarked .lineLimit(1) labels; mark them .lumenNeverTruncates or .truncationMode(.middle):\n"
                       + new.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"," }.joined(separator: "\n"))
        XCTAssertEqual(stale, [], "allow-listed labels are now marked (or moved); remove them:\n" + stale.joined(separator: "\n"))
    }

    func testTheScanFindsAnUnmarkedLabelAndSkipsMarkedOnes() {
        let source = """
            Text(title).font(.headline).lineLimit(1)
            Text(path).lineLimit(1).truncationMode(.middle)
            Text(detail).lineLimit(1).truncationMode(.tail).help(detail)
            Text(source).lineLimit(1).truncationMode(.tail)
            Text(name)
                .lineLimit(1)
                .lumenNeverTruncates(name)
            """
        XCTAssertEqual(Self.unmarkedSites(in: source, file: "X.swift"), ["X.swift · Text(title)", "X.swift · Text(source)"])
    }
}
