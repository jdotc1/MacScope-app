import XCTest
@testable import MacScope

/// The end-to-end MacScope-vs-oracle differential. Analyzes a real in-scope binary, normalizes
/// it (`GoldenOutput`), and — when an authorized reference is present — diffs the two
/// (`GoldenOutputDiff`). Stored reference outputs share the same normalized schema.
/// Without a reference each
/// comparison SKIPS with a clear instruction; the MacScope side still self-validates the JSON
/// round-trip + diff on real analyzer output (`testRealBinaryRoundTripsAndSelfMatches`).
///
/// No oracle output or binary fixture is committed: the binary is `/bin/ls` (read in place) and
/// the references (`GoldenFixtures/ls/{reference,ghidra}.json`) are git-ignored (clean-room — see
/// GoldenFixtures/README.md).
@MainActor
final class GoldenDifferentialTests: XCTestCase {

    private let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")

    /// A corpus binary built from committed sources by `Scripts/build_golden_corpus.sh` and living
    /// (git-ignored) at `GoldenFixtures/<name>/<name>`. Absent until that script is run, so the
    /// corpus differentials skip on a fresh checkout / CI, exactly like `/bin/ls`'s oracle JSON.
    private func corpusBinaryURL(_ name: String) -> URL {
        fixturesDirectory().appendingPathComponent("\(name)/\(name)")
    }

    private func analyzeGolden(_ binaryURL: URL) throws -> GoldenOutput {
        guard FileManager.default.isReadableFile(atPath: binaryURL.path) else {
            throw XCTSkip("binary not present/readable: \(binaryURL.path)")
        }
        return GoldenOutput(snapshot: try AnalysisEngine().analyze(url: binaryURL))
    }

    /// Real analyzer output must survive a JSON round-trip and diff clean against itself —
    /// proves the encode/decode + diff engine compose correctly on production data, not just the
    /// synthetic fixtures in `GoldenOutputDiffTests`.
    func testRealBinaryRoundTripsAndSelfMatches() throws {
        let golden = try analyzeGolden(systemBinaryURL)
        let data = try golden.jsonData()
        let decoded = try JSONDecoder().decode(GoldenOutput.self, from: data)
        let diff = GoldenOutputDiff.compare(actual: decoded, reference: golden)
        XCTAssertTrue(diff.matches, "round-tripped golden output must diff clean: \(diff.summaryLines)")
    }

    /// Writes MacScope's own normalized golden JSON to `macscope.json` when requested; otherwise
    /// skips. This is the "eyeballing" snapshot the fixtures README describes — pair it with
    /// `ls/ghidra.json` (or `ls/reference.json`) for an offline, per-entry diff outside the test
    /// harness. The file is git-ignored (clean-room).
    ///
    /// Enable with `MACSCOPE_EMIT_GOLDEN=1` (pass it through xcodebuild with the `TEST_RUNNER_`
    /// prefix — `TEST_RUNNER_MACSCOPE_EMIT_GOLDEN=1` — since xcodebuild does NOT forward the shell
    /// environment to the xctest host). Output goes to `MACSCOPE_EMIT_GOLDEN_DIR` if set, else to
    /// the source-tree `GoldenFixtures/ls/` (resolved from `#filePath`, so no path needs to
    /// survive env propagation).
    func testEmitMacScopeGoldenWhenRequested() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MACSCOPE_EMIT_GOLDEN"] != nil || env["MACSCOPE_EMIT_GOLDEN_DIR"] != nil else {
            throw XCTSkip("Set MACSCOPE_EMIT_GOLDEN=1 (via TEST_RUNNER_MACSCOPE_EMIT_GOLDEN=1 with "
                + "xcodebuild) to emit macscope.json for offline diffing.")
        }
        let golden = try analyzeGolden(systemBinaryURL)
        let dir = env["MACSCOPE_EMIT_GOLDEN_DIR"].map { URL(fileURLWithPath: $0) }
            ?? fixturesDirectory().appendingPathComponent("ls")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = dir.appendingPathComponent("macscope.json")
        try golden.jsonData().write(to: outURL)
        print("MACSCOPE_GOLDEN_EMITTED -> \(outURL.path)")
    }

    // MARK: - /bin/ls (a real arm64e system executable)

    /// The real differential. Drop an authorized, normalized reference at
    /// `GoldenFixtures/ls/reference.json` (see GoldenFixtures/README.md) to enable it; until then it
    /// skips. The reference is NEVER committed.
    func testReferenceDifferential() throws {
        try runReferenceDifferential(binaryURL: systemBinaryURL, referenceFile: "ls/reference.json", oracleName: "Reference")
    }

    /// Compares stored reference output at `GoldenFixtures/ls/ghidra.json`.
    /// Skips when absent; reference output is never committed.
    func testGhidraReferenceDifferential() throws {
        try runReferenceDifferential(binaryURL: systemBinaryURL, referenceFile: "ls/ghidra.json", oracleName: "Reference output")
    }

    // MARK: - Corpus: modern-binary shapes (Swift metadata, ObjC classes) the system binary lacks
    //
    // Each corpus binary is built (arm64e) from a committed source by `Scripts/build_golden_corpus.sh`
    // and lives git-ignored at `GoldenFixtures/<name>/<name>` alongside stored reference output.
    // Both are absent on a fresh checkout, so these skip until a
    // developer opts in — exactly like `/bin/ls`'s reference.

    func testSwiftCorpusGhidraDifferential() throws {
        try runReferenceDifferential(binaryURL: corpusBinaryURL("swift_corpus"),
                                     referenceFile: "swift_corpus/ghidra.json", oracleName: "Reference output")
    }

    func testSwiftCorpusReferenceDifferential() throws {
        try runReferenceDifferential(binaryURL: corpusBinaryURL("swift_corpus"),
                                     referenceFile: "swift_corpus/reference.json", oracleName: "Reference")
    }

    func testObjCCorpusGhidraDifferential() throws {
        try runReferenceDifferential(binaryURL: corpusBinaryURL("objc_corpus"),
                                     referenceFile: "objc_corpus/ghidra.json", oracleName: "Reference output")
    }

    func testObjCCorpusReferenceDifferential() throws {
        try runReferenceDifferential(binaryURL: corpusBinaryURL("objc_corpus"),
                                     referenceFile: "objc_corpus/reference.json", oracleName: "Reference")
    }

    /// Shared body for an oracle differential: load the normalized reference (skip if absent),
    /// analyze `binaryURL` through MacScope (skip if the binary is absent), and evaluate the TRUSTED
    /// GATE. The gate fails only on a real, un-accepted divergence — a decode error or a genuine
    /// named-function/code-symbol coverage regression — not on the large volume of oracle scope /
    /// taxonomy / naming-convention differences that are not MacScope defects (those are printed but
    /// do not fail). See `GoldenGate` and `GoldenFixtures/README.md`. `oracleName` labels the report.
    private func runReferenceDifferential(binaryURL: URL, referenceFile: String, oracleName: String) throws {
        let referenceURL = fixturesDirectory().appendingPathComponent(referenceFile)
        guard let data = try? Data(contentsOf: referenceURL) else {
            throw XCTSkip("No \(oracleName) reference at \(referenceURL.path) — capture one to enable "
                + "the MacScope-vs-\(oracleName) differential (see GoldenFixtures/README.md).")
        }
        let golden = try analyzeGolden(binaryURL)
        let reference = try JSONDecoder().decode(GoldenOutput.self, from: data)
        let verdict = GoldenGate.evaluate(actual: golden, reference: reference)
        let label = "\(binaryURL.lastPathComponent) vs \(oracleName)"
        // Always surface the full report (gated + accepted + reported) so a passing run still shows
        // the standing oracle-scope differences and a failing run shows exactly what regressed.
        print("MacScope \(label) gate:\n" + verdict.lines.joined(separator: "\n"))
        XCTAssertTrue(verdict.passes,
                      "MacScope \(label) — un-accepted divergences:\n"
                      + verdict.lines.joined(separator: "\n"))
    }

    /// The source-tree `GoldenFixtures` directory (resolved from this file's compile-time path).
    private func fixturesDirectory() -> URL {
        TestSourceRoot.fileURL(#filePath)      // …/Tests/CoreTests/GoldenDifferentialTests.swift
            .deletingLastPathComponent()     // …/Tests/CoreTests
            .appendingPathComponent("GoldenFixtures")
    }
}
