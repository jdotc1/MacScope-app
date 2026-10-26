import Foundation
import XCTest
@testable import MacScope

/// The Swift demangler reference corpus (`GoldenFixtures/swift-demangler-corpus/`): 25,580
/// distinct manglings with Swift 6.2's `swift-demangle --compact` output (or `null` where the
/// reference rejects the name), each run through `Demangler.mangledToReadable` as the corpus did.
///
/// A name matches when the result equals the reference exactly, or when both reject it. Two gates:
/// every name in `baseline-match.txt` must still match, so a grammar PR may turn names green but
/// never red; and no name may render text the reference disagrees with unless the corpus already
/// recorded that disagreement (`baseline_result`), so a nil never turns into a wrong name. Record a
/// new baseline with `TEST_RUNNER_MACSCOPE_DEMANGLER_CORPUS_RECORD_BASELINE=1`; it is written only
/// when no name in the old one regressed. The report (counts by
/// outcome and by reference node kind, every non-nil disagreement) goes to
/// `TEST_RUNNER_MACSCOPE_DEMANGLER_CORPUS_REPORT=<dir>`, or to the temporary directory when unset.
final class SwiftDemanglerCorpusTests: XCTestCase {
    struct Entry: Decodable {
        let id: String
        let mangled: String
        /// Reference text, or nil when the reference rejects the name.
        let expected: String?
        /// The corpus's classification of MacScope at `product_revision`.
        let status: String
        /// First non-Global reference node: a grouping, not the failing production.
        let nodeKind: String
        /// MacScope's text at `product_revision`, recorded only where it disagreed with the reference.
        let baselineResult: String?

        enum CodingKeys: String, CodingKey {
            case id, mangled, expected, status
            case nodeKind = "node_kind"
            case baselineResult = "baseline_result"
        }
    }

    struct File: Decodable {
        let schema: String
        let productRevision: String
        let entries: [Entry]

        enum CodingKeys: String, CodingKey {
            case schema, entries
            case productRevision = "product_revision"
        }
    }

    enum Outcome: String, CaseIterable {
        case match
        /// The reference renders the name; MacScope falls back to the raw name.
        case unsupported
        /// Both render, with different text.
        case wrongOutput = "wrong-output"
        /// The reference rejects the name; MacScope renders it.
        case acceptedOnlyByMacScope = "accepted-only-by-macscope"
    }

    static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent() // …/CoreTests
        .appendingPathComponent("GoldenFixtures/swift-demangler-corpus", isDirectory: true)
    private static let baselineURL = fixtureDirectory.appendingPathComponent("baseline-match.txt")

    static func outcome(of entry: Entry, result: String?) -> Outcome {
        switch (entry.expected, result) {
        case (nil, nil): .match
        case (nil, _?): .acceptedOnlyByMacScope
        case (_?, nil): .unsupported
        case let (expected?, result?): expected == result ? .match : .wrongOutput
        }
    }

    func testReferenceCorpusAgainstTheDemangler() throws {
        let compressed = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("corpus.json.gz"))
        let file = try JSONDecoder().decode(File.self, from: try A64OracleGzip.decompress(compressed))
        XCTAssertEqual(file.schema, "macscope-swift-demangler-corpus-slice-1")
        XCTAssertEqual(file.entries.count, 25_580)
        XCTAssertEqual(Set(file.entries.map(\.mangled)).count, file.entries.count)

        let results = file.entries.map { Demangler.mangledToReadable($0.mangled) }
        // CP5 pinned these 43 deliberate display/reference-profile outcomes exactly.
        // The general no-new-wrong gate below alone would allow them to become nil.
        let compatibilityURL = Self.fixtureDirectory.appendingPathComponent("cp5-compatibility-preserve.txt")
        let compatibilityText = try String(contentsOf: compatibilityURL, encoding: .utf8)
        let compatibilityIDs = Set(compatibilityText.split(whereSeparator: \.isNewline).map(String.init))
        XCTAssertEqual(compatibilityIDs.count, 43)
        XCTAssertTrue(compatibilityIDs.isSubset(of: Set(file.entries.map(\.id))))
        for index in file.entries.indices where compatibilityIDs.contains(file.entries[index].id) {
            XCTAssertNotNil(file.entries[index].baselineResult, file.entries[index].mangled)
            XCTAssertEqual(results[index], file.entries[index].baselineResult, file.entries[index].mangled)
        }

        let outcomes = zip(file.entries, results).map { Self.outcome(of: $0, result: $1) }

        let environment = ProcessInfo.processInfo.environment
        let reportDirectory = environment["MACSCOPE_DEMANGLER_CORPUS_REPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("swift-demangler-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let report = Self.report(file: file, results: results, outcomes: outcomes)
        try report.markdown.write(to: reportDirectory.appendingPathComponent("swift-demangler-corpus-report.md"), atomically: true, encoding: .utf8)
        print("Swift demangler corpus: \(report.summary) → \(reportDirectory.path)")

        // A non-nil name the reference disagrees with is the bug class this corpus exists for: only
        // the disagreements the corpus recorded at its baseline may remain (each with its own text).
        let newlyWrong = file.entries.indices.filter { index in
            let entry = file.entries[index]
            guard outcomes[index] == .wrongOutput || outcomes[index] == .acceptedOnlyByMacScope else { return false }
            return entry.baselineResult == nil || entry.baselineResult != results[index]
        }
        XCTAssertTrue(newlyWrong.isEmpty, "\(newlyWrong.count) names now render text the reference disagrees with:\n"
            + newlyWrong.prefix(20).map { "\(file.entries[$0].mangled)\n  got      \(results[$0] ?? "nil")\n  expected \(file.entries[$0].expected ?? "nil (rejected)")" }
                .joined(separator: "\n"))

        let matching = Set(zip(file.entries, outcomes).filter { $1 == .match }.map(\.0.id))
        let record = environment["MACSCOPE_DEMANGLER_CORPUS_RECORD_BASELINE"] == "1"
        // Recording also checks the existing baseline first, so one run both proves nothing was lost
        // and records the names a fix turned green.
        guard let baselineText = try? String(contentsOf: Self.baselineURL, encoding: .utf8) else {
            guard record else {
                return XCTFail("no baseline-match.txt; record one with TEST_RUNNER_MACSCOPE_DEMANGLER_CORPUS_RECORD_BASELINE=1")
            }
            try (matching.sorted().joined(separator: "\n") + "\n").write(to: Self.baselineURL, atomically: true, encoding: .utf8)
            return
        }
        let baseline = Set(baselineText.split(whereSeparator: \.isNewline).map(String.init))
        let regressed = file.entries.indices.filter { baseline.contains(file.entries[$0].id) && outcomes[$0] != .match }
        XCTAssertTrue(regressed.isEmpty, "\(regressed.count) baseline names no longer match:\n"
            + regressed.prefix(20).map { "\(file.entries[$0].mangled): \(outcomes[$0].rawValue), got \(results[$0] ?? "nil")" }
                .joined(separator: "\n"))
        let newlyMatching = matching.subtracting(baseline)
        if record, regressed.isEmpty {
            try (matching.sorted().joined(separator: "\n") + "\n").write(to: Self.baselineURL, atomically: true, encoding: .utf8)
            print("Swift demangler corpus: recorded \(matching.count) matching names (+\(newlyMatching.count)).")
        } else if !newlyMatching.isEmpty {
            print("Swift demangler corpus: \(newlyMatching.count) names now match beyond the baseline; re-record it in this PR.")
        }
    }

    func testOutcomeClassification() throws {
        func entry(_ expected: String?) -> Entry {
            Entry(id: "x", mangled: "$sx", expected: expected, status: "", nodeKind: "Function", baselineResult: nil)
        }
        XCTAssertEqual(Self.outcome(of: entry("a"), result: "a"), .match)
        XCTAssertEqual(Self.outcome(of: entry(nil), result: nil), .match, "both reject")
        XCTAssertEqual(Self.outcome(of: entry("a"), result: nil), .unsupported)
        XCTAssertEqual(Self.outcome(of: entry("a"), result: "a "), .wrongOutput, "exact text, no normalization")
        XCTAssertEqual(Self.outcome(of: entry(nil), result: "a"), .acceptedOnlyByMacScope)
    }

    // MARK: Report

    struct Report {
        let summary: String
        let markdown: String
    }

    static func report(file: File, results: [String?], outcomes: [Outcome]) -> Report {
        var totals: [Outcome: Int] = [:]
        var byKind: [String: [Outcome: Int]] = [:]
        for (entry, outcome) in zip(file.entries, outcomes) {
            totals[outcome, default: 0] += 1
            byKind[entry.nodeKind, default: [:]][outcome, default: 0] += 1
        }
        let summary = Outcome.allCases.map { "\(totals[$0] ?? 0) \($0.rawValue)" }.joined(separator: ", ")
            + " of \(file.entries.count)"
        var lines = [
            "# Swift demangler reference corpus",
            "",
            "Reference: Swift 6.2 RELEASE `swift-demangle --compact`; corpus baseline \(file.productRevision).",
            "",
            "| Outcome | Names |",
            "|---|---:|",
        ]
        lines += Outcome.allCases.map { "| \($0.rawValue) | \(totals[$0] ?? 0) |" }
        lines += ["", "## By reference node kind", "",
                  "| Node kind | Total | " + Outcome.allCases.map(\.rawValue).joined(separator: " | ") + " |",
                  "|---|---:|" + String(repeating: "---:|", count: Outcome.allCases.count)]
        let kinds = byKind.sorted { lhs, rhs in
            let l = lhs.value.values.reduce(0, +), r = rhs.value.values.reduce(0, +)
            return l != r ? l > r : lhs.key < rhs.key
        }
        for (kind, counts) in kinds {
            lines.append("| \(kind) | \(counts.values.reduce(0, +)) | "
                + Outcome.allCases.map { String(counts[$0] ?? 0) }.joined(separator: " | ") + " |")
        }
        lines += ["", "## Non-nil disagreements", ""]
        for index in file.entries.indices where outcomes[index] == .wrongOutput || outcomes[index] == .acceptedOnlyByMacScope {
            let entry = file.entries[index]
            lines += ["- `\(entry.mangled)` (\(outcomes[index].rawValue), \(entry.nodeKind))",
                      "  - MacScope: `\(results[index] ?? "nil")`",
                      "  - reference: `\(entry.expected ?? "rejected")`"]
        }
        return Report(summary: summary, markdown: lines.joined(separator: "\n") + "\n")
    }

    // CP5's independent malformed-input checks share this gate's test class;
    // the main 25,580-name corpus is not duplicated.
    private struct CP5MutationFile: Decodable { let entries: [CP5MutationEntry] }
    private struct CP5MutationEntry: Decodable {
        let mangled: String
        let expected: String?
        let status: String
        let compatibility_result: String?
    }

    /// Every proper prefix and deterministic token edit of representative new
    /// productions. A prefix that is itself valid keeps its oracle meaning.
    func testTruncatedAndMutatedProductionsFailClosed() throws {
        let path = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CP5SwiftDemanglerMutationCorpus.json.gz")
        let data = try A64OracleGzip.decompress(Data(contentsOf: path))
        let entries = try JSONDecoder().decode(CP5MutationFile.self, from: data).entries
        XCTAssertEqual(entries.count, 12_493)
        var rejected = 0
        for entry in entries {
            let actual = Demangler.mangledToReadable(entry.mangled)
            if let compatibility = entry.compatibility_result {
                XCTAssertEqual(actual, compatibility, entry.mangled)
            } else if entry.status == "match" || actual != nil {
                XCTAssertEqual(actual, entry.expected, entry.mangled)
            }
            if entry.expected == nil {
                XCTAssertNil(actual, entry.mangled)
                rejected += 1
            }
        }
        print("CP5-MUTATIONS entries=\(entries.count) referenceRejected=\(rejected)")
    }

}
