import XCTest
@testable import LumenUI

final class LumenSemanticTextPolicyTests: XCTestCase {
    func testQualifiedSymbolsRetainTerminalSignatureAndBalancedGenerics() {
        let swift = "Module.Container<Result<Key, Value>>.transform(input: Output<Value>)"
        XCTAssertEqual(LumenSemanticTextPolicy.candidates(for: swift, kind: .symbol), [
            swift, "…Container<Result<Key, Value>>.transform(input: Output<Value>)",
            "…transform(input: Output<Value>)", "…"
        ])
        let cpp = "project::Container<std::vector<Value>>::transform(Value)"
        XCTAssertEqual(LumenSemanticTextPolicy.candidates(for: cpp, kind: .type), [
            cpp, "…Container<std::vector<Value>>::transform(Value)", "…transform(Value)", "…"
        ])
    }

    func testSelectorLabelsAndAtomicIdentifiersAreNeverCut() {
        for value in ["setObject:forKey:", "-[Collection setObject:forKey:]", "HTTPResponseIdentifier"] {
            XCTAssertEqual(LumenSemanticTextPolicy.candidates(for: value, kind: .symbol), [value, "…"])
            XCTAssertEqual(LumenSemanticTextPolicy.chunks(for: value, kind: .symbol).joined(), value)
        }
    }

    func testUnicodePathsRetainCompleteTerminalComponents() {
        let value = "/Users/Zoë/研究/測定値.swift"
        let candidates = LumenSemanticTextPolicy.candidates(for: value, kind: .path)
        XCTAssertEqual(candidates.first, value)
        XCTAssertTrue(candidates.contains("…研究/測定値.swift"))
        XCTAssertTrue(candidates.contains("…測定値.swift"))
        XCTAssertFalse(candidates.contains("…定値.swift"))
    }

    func testUnknownSyntaxAndExpressionsAreConservative() {
        for value in ["Module.Type<Broken", "Module.\"literal\"", "value?.member", "0.123", ".leading"] {
            XCTAssertEqual(LumenSemanticTextPolicy.candidates(for: value, kind: .type), [value, "…"])
        }
        let expression = "left + call(\"a.b\", right)"
        XCTAssertEqual(LumenSemanticTextPolicy.candidates(for: expression, kind: .expression), [expression, "…"])
        XCTAssertEqual(LumenSemanticTextPolicy.chunks(for: expression, kind: .expression).joined(), expression)
    }

    func testMeasuredPresentationUsesWholeCandidatesAndBoundaries() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) }
        let original = "Module.Type.member"
        XCTAssertEqual(LumenSemanticTextPolicy.presentation(for: original, kind: .symbol,
                       width: 12, maxLines: 2, measure: measure), ["Module.Type.", "member"])
        XCTAssertEqual(LumenSemanticTextPolicy.presentation(for: original, kind: .symbol,
                       width: 8, maxLines: 1, measure: measure), ["…member"])
        // No complete candidate fits: the original wraps and its last line middle-truncates.
        XCTAssertEqual(LumenSemanticTextPolicy.presentation(for: "Box<Nested<Value>>", kind: .type,
                       width: 8, maxLines: 2, measure: measure), ["Box<Nest", "ed<V…e>>"])
        XCTAssertEqual(LumenSemanticTextPolicy.presentation(for: original, kind: .symbol,
                       width: 0.5, maxLines: 1, measure: measure), [])
    }

    func testGenericAndSelectorWrappingRetainsEveryToken() {
        let measure: (String) -> CGFloat = { CGFloat($0.count) }
        XCTAssertEqual(LumenSemanticTextPolicy.presentation(for: "AnyCollection<Element>", kind: .type,
                       width: 14, maxLines: 2, measure: measure), ["AnyCollection<", "Element>"])
        XCTAssertEqual(LumenSemanticTextPolicy.presentation(for: "setObject:forKey:", kind: .symbol,
                       width: 10, maxLines: 2, measure: measure), ["setObject:", "forKey:"])
        let nested = "Dictionary<String, Array<Item>>"
        XCTAssertEqual(LumenSemanticTextPolicy.chunks(for: nested, kind: .type).joined(), nested)
        XCTAssertTrue(LumenSemanticTextPolicy.chunks(for: nested, kind: .type).contains("Array<"))
    }

    func testExpressionWrappingKeepsEscapedLiteralAtomicAndOriginal() {
        let value = "left + call(\"a.\\\"b\", right)"
        let chunks = LumenSemanticTextPolicy.chunks(for: value, kind: .expression)
        XCTAssertEqual(chunks.joined(), value)
        XCTAssertTrue(chunks.contains("\"a.\\\"b\","))
        XCTAssertEqual(LumenSemanticTextPolicy.chunks(for: "call(unbalanced", kind: .expression), ["call(unbalanced"])
        let lines = LumenSemanticTextPolicy.presentation(for: "left + right", kind: .expression,
                    width: 7, maxLines: 2, measure: { CGFloat($0.count) })
        XCTAssertEqual(lines, ["left + ", "right"])
        XCTAssertEqual(lines.joined(), "left + right")
    }

    func testSourceSnippetAllowsIncompleteDeclarationWithoutCuttingIdentifiers() {
        let value = "public struct LumenStat: Identifiable {"
        let chunks = LumenSemanticTextPolicy.chunks(for: value, kind: .snippet)
        XCTAssertEqual(chunks.joined(), value)
        XCTAssertTrue(chunks.contains("Identifiable "))
        let lines = LumenSemanticTextPolicy.presentation(for: value, kind: .snippet,
                    width: 24, maxLines: 2, measure: { CGFloat($0.count) })
        XCTAssertEqual(lines.joined(), value)
        XCTAssertTrue(lines.contains(where: { $0.contains("Identifiable") }))
        let candidates = LumenSemanticTextPolicy.candidates(for: value, kind: .snippet)
        XCTAssertEqual(candidates.first, value)
        XCTAssertTrue(candidates.contains("public struct LumenStat: …"))
        XCTAssertFalse(candidates.contains(where: { $0.hasSuffix("Identifi…") }))
        XCTAssertEqual(LumenSemanticTextPolicy.chunks(for: value, kind: .expression), [value])
    }

    func testCandidateBudgetKeepsTerminalAndSourceIdentity() {
        let components = (0..<64).map { "Component\($0)" }
        let value = components.joined(separator: ".")
        let candidates = LumenSemanticTextPolicy.candidates(for: value, kind: .symbol)
        XCTAssertEqual(candidates.count, 14)
        XCTAssertEqual(candidates.first, value)
        XCTAssertEqual(candidates.suffix(2), ["…Component63", "…"])
        XCTAssertEqual(candidates, LumenSemanticTextPolicy.candidates(for: value, kind: .symbol))
        XCTAssertEqual(LumenSemanticTextPolicy.chunks(for: value, kind: .symbol).joined(), value)
        let snippet = components.joined(separator: " ")
        let excerpts = LumenSemanticTextPolicy.candidates(for: snippet, kind: .snippet)
        XCTAssertEqual(excerpts.count, 14)
        XCTAssertEqual(excerpts.first, snippet)
        XCTAssertEqual(excerpts.suffix(2), ["Component0 …", "…"])
        XCTAssertEqual(LumenSemanticTextPolicy.chunks(for: snippet, kind: .snippet).joined(), snippet)
    }

    func testChunksAndCandidatesPreserveSourceAndDeterministicOrder() {
        for kind: LumenSemanticTextKind in [.symbol, .type, .path, .expression, .snippet] {
            for value in ["", "Module.Box<Array<Value>>.member", "/研究/👩🏽‍💻/source.swift", "setObject:forKey:", "a + b"] {
                XCTAssertEqual(LumenSemanticTextPolicy.chunks(for: value, kind: kind).joined(), value)
                let candidates = LumenSemanticTextPolicy.candidates(for: value, kind: kind)
                XCTAssertEqual(candidates.first, value)
                XCTAssertEqual(candidates, LumenSemanticTextPolicy.candidates(for: value, kind: kind))
                XCTAssertEqual(Set(candidates).count, candidates.count)
            }
        }
    }

    // MARK: Never a bare "…"

    /// 7 pt per character, the test harness's measure.
    private let seven: (String) -> CGFloat = { CGFloat($0.count) * 7 }

    private func shown(_ value: String, _ kind: LumenSemanticTextKind, width: CGFloat, lines: Int = 2) -> [String] {
        LumenSemanticTextPolicy.presentation(for: value, kind: kind, width: width, maxLines: lines, measure: seven)
    }

    private func assertNeverBareEllipsis(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(lines.isEmpty, file: file, line: line)
        XCTAssertNotEqual(lines, ["…"], file: file, line: line)
        XCTAssertFalse(lines.contains("…"), "No line may be a bare ellipsis: \(lines)", file: file, line: line)
        for text in lines { XCTAssertLessThanOrEqual(seven(text), 1_000, file: file, line: line) }
    }

    func testUUIDWrapsWholeAt170AndMiddleTruncatesOnOneLine() {
        let uuid = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let wrapped = shown(uuid, .symbol, width: 170)
        assertNeverBareEllipsis(wrapped)
        XCTAssertEqual(wrapped.joined(), uuid, "36 × 7 pt fits two 170 pt lines whole, as in 0.47")
        XCTAssertTrue(wrapped.allSatisfy { seven($0) <= 170 })
        let single = shown(uuid, .symbol, width: 170, lines: 1)
        XCTAssertEqual(single.count, 1)
        XCTAssertTrue(single[0].hasPrefix("3F2504E0") && single[0].hasSuffix("2C3301") && single[0].contains("…"), single[0])
        XCTAssertLessThanOrEqual(seven(single[0]), 170)
    }

    func testSHA256WrapsWholeAt300() {
        let sha = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        let lines = shown(sha, .expression, width: 300)
        assertNeverBareEllipsis(lines)
        XCTAssertEqual(lines.joined(), sha)
        let narrow = shown(sha, .expression, width: 200)
        XCTAssertEqual(narrow.count, 2)
        XCTAssertTrue(narrow[0].hasPrefix("9f86") && narrow[1].hasSuffix("0a08") && narrow[1].contains("…"), "\(narrow)")
    }

    func testEscapedStringAndApostropheWrapAndMiddleTruncate() {
        let escaped = "Unable to open the configuration file at the given location: %s (errno %d)\\n"
        let lines = shown(escaped, .expression, width: 220)
        assertNeverBareEllipsis(lines)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Unable to open"), lines[0])
        XCTAssertTrue(lines[1].contains("…") && lines[1].hasSuffix("%d)\\n"), lines[1])
        XCTAssertTrue(lines.allSatisfy { seven($0) <= 220 })
        let apostrophe = "Couldn't load the plug-in bundle because its executable is missing or damaged"
        let quoted = shown(apostrophe, .expression, width: 220)
        assertNeverBareEllipsis(quoted)
        XCTAssertTrue(quoted[0].hasPrefix("Couldn't load"), quoted[0])
    }

    func testSearchSnippetsWithPunctuationKeepLeadingContextAndTailTruncate() {
        XCTAssertEqual(LumenSemanticTextPolicy.fallback(for: .snippet), .tail)
        for line in ["…result = computeTheValue(a, b, c); return …",
                     "…// Don't call this from the main thread because …",
                     "…#include <CoreFoundation/CoreFoundation.h> …"] {
            let lines = shown(line, .snippet, width: 300)
            assertNeverBareEllipsis(lines)
            XCTAssertEqual(lines.joined(), line, "Two 300 pt lines hold the whole match line")
        }
        // Too long for two lines: the leading context (where C-31 put the match) stays; the tail goes.
        let long = "…// Don't call this from the main thread because the lock below is not reentrant; see #4512 for the story"
        let lines = shown(long, .snippet, width: 300)
        assertNeverBareEllipsis(lines)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("…// Don't call"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("…") && !lines[1].hasSuffix("story"), lines[1])
    }

    func testFileNameTitlesUseThePathPolicyAndKeepTheirStem() {
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "LumenExtras.swift"), .path)
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "Configuration.json"), .path)
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "LumenExtras.swift:178"), .path)
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "Sources/LumenUI"), .path)
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "Module.Type.member"), .symbol)
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "NSApplication.shared"), .symbol)
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "compute(_:)"), .symbol)
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "arm64e Mach-O executable"), .symbol)
        XCTAssertEqual(LumenSemanticTextPolicy.labelKind(for: "-[NSViewController loadViewIfRequired]+112"), .symbol)

        let extras = shown("LumenExtras.swift", LumenSemanticTextPolicy.labelKind(for: "LumenExtras.swift"), width: 80, lines: 1)
        XCTAssertEqual(extras, ["Lumen…swift"])
        let config = shown("Configuration.json", LumenSemanticTextPolicy.labelKind(for: "Configuration.json"), width: 90, lines: 1)
        XCTAssertEqual(config, ["Config….json"])
        // A full path drops leading components first, then middle-truncates the file name itself.
        let path = "/Users/dev/Projects/Lumen/Sources/LumenUI/LumenExtras.swift"
        XCTAssertEqual(shown(path, .path, width: 140, lines: 1), ["…LumenExtras.swift"])
        XCTAssertEqual(shown(path, .path, width: 80, lines: 1), ["Lumen…swift"])
    }

    func testTitleWithSpaceMiddleTruncates() {
        let title = "arm64e Mach-O executable"
        let lines = shown(title, LumenSemanticTextPolicy.labelKind(for: title), width: 120, lines: 1)
        assertNeverBareEllipsis(lines)
        XCTAssertEqual(lines, ["arm64e M…ecutable"])
    }

    func testObjCReferenceKeepsSelectorEndAndOffsetAtInspectorWidths() {
        let reference = "-[NSViewController loadViewIfRequired]+112"
        let kind = LumenSemanticTextPolicy.labelKind(for: reference)
        for width: CGFloat in [280, 200] {
            let lines = shown(reference, kind, width: width, lines: 1)
            assertNeverBareEllipsis(lines)
            XCTAssertEqual(lines.count, 1)
            XCTAssertTrue(lines[0].hasPrefix("-[NSView") && lines[0].hasSuffix("]+112") && lines[0].contains("…"), lines[0])
            XCTAssertLessThanOrEqual(seven(lines[0]), width)
        }
    }

    func testFallbackDrawsNothingWhenNotOneCharacterFits() {
        XCTAssertEqual(LumenSemanticTextPolicy.fallbackLines(for: "abc", mode: .middle, width: 10,
                       maxLines: 1, measure: seven), [])
    }
}
