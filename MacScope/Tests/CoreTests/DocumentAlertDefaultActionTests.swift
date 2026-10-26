import Foundation
import XCTest
@testable import MacScope

/// Every single-button SwiftUI alert in the app shell must answer Return. A lone
/// `Button("OK", role: .cancel)` binds Escape only, so after an export or workspace save failure
/// the "Save Failed" sheet ignored Return (Tier 2d, round 4 lane AE). The fix is
/// `.keyboardShortcut(.defaultAction)` on that button; this source scan keeps it from regressing
/// on any alert added later in App/ or Features/.
final class DocumentAlertDefaultActionTests: XCTestCase {
    func testSingleButtonAlertsBindReturn() throws {
        let root = repositoryRoot()
        var scanned = 0
        var violations: [String] = []
        for url in try swiftSources(below: [
            root.appendingPathComponent("MacScope/App", isDirectory: true),
            root.appendingPathComponent("MacScope/Features", isDirectory: true),
        ]) {
            let source = try String(contentsOf: url, encoding: .utf8)
            for alert in Self.alertActionBlocks(in: source) {
                scanned += 1
                let buttons = alert.actions.components(separatedBy: "Button(").count - 1
                if buttons == 1, !alert.actions.contains(".keyboardShortcut(.defaultAction)") {
                    let file = url.path.replacingOccurrences(of: root.path + "/", with: "")
                    violations.append("\(file): \(alert.title)")
                }
            }
        }
        // The workspace root alone has six document alerts; a scan that finds none is broken.
        XCTAssertGreaterThanOrEqual(scanned, 6, "The alert scan found too few alerts to be meaningful")
        XCTAssertEqual(violations, [], "Single-button alerts need .keyboardShortcut(.defaultAction) so Return dismisses them")
    }

    func testScannerFlagsAnEscapeOnlyAlertAndAcceptsTheFixedOne() {
        let broken = """
        .alert("Save Failed", isPresented: Binding(get: { a != nil }, set: { _ in })) {
            Button("OK", role: .cancel) { a = nil }
        } message: { Text("x") }
        """
        let fixed = """
        .alert("Save Failed", isPresented: $shown) {
            Button("OK", role: .cancel) { a = nil }
                .keyboardShortcut(.defaultAction)
        } message: { Text("x") }
        """
        let brokenBlocks = Self.alertActionBlocks(in: broken)
        XCTAssertEqual(brokenBlocks.map(\.title), ["\"Save Failed\""])
        XCTAssertFalse(brokenBlocks[0].actions.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertFalse(brokenBlocks[0].actions.contains("Text(\"x\")"), "The message closure is not part of the actions")
        XCTAssertTrue(Self.alertActionBlocks(in: fixed)[0].actions.contains(".keyboardShortcut(.defaultAction)"))
    }

    /// For each `.alert(` call: its first argument (the title) and the trailing actions closure,
    /// found by balancing the call's parentheses and then the closure's braces.
    static func alertActionBlocks(in source: String) -> [(title: String, actions: String)] {
        let chars = Array(source)
        let marker = Array(".alert(")
        var results: [(String, String)] = []
        var index = 0
        while index + marker.count <= chars.count {
            guard Array(chars[index..<index + marker.count]) == marker else { index += 1; continue }
            var cursor = index + marker.count
            var depth = 1
            let argsStart = cursor
            while cursor < chars.count, depth > 0 {
                if chars[cursor] == "(" { depth += 1 } else if chars[cursor] == ")" { depth -= 1 }
                cursor += 1
            }
            let args = String(chars[argsStart..<max(argsStart, cursor - 1)])
            let title = args.split(separator: ",", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            while cursor < chars.count, chars[cursor].isWhitespace { cursor += 1 }
            guard cursor < chars.count, chars[cursor] == "{" else { index = cursor; continue }
            let bodyStart = cursor + 1
            depth = 1
            cursor += 1
            while cursor < chars.count, depth > 0 {
                if chars[cursor] == "{" { depth += 1 } else if chars[cursor] == "}" { depth -= 1 }
                cursor += 1
            }
            results.append((title, String(chars[bodyStart..<max(bodyStart, cursor - 1)])))
            index = cursor
        }
        return results
    }

    private func swiftSources(below roots: [URL]) throws -> [URL] {
        roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
                return url
            }
        }
    }

    private func repositoryRoot() -> URL {
        var root = TestSourceRoot.fileURL(#filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }
}
