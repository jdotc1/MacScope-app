import XCTest
@testable import MacScope

/// Tests for the analysis performance benchmark seam (`AnalysisBenchmark`).
///
/// The seam is OFF by default: the repeated-iteration `measure {}` test is gated behind
/// an env var so a normal `xcodebuild test` run stays fast. The plain run test exercises
/// the seam once on a small system binary (`/bin/ls`) and asserts coarse sanity (the
/// timings are non-negative, the analysis decoded instructions and recovered procedures).
/// No binary fixtures are committed; the binary is read in place and the tests skip when
/// it is unreadable. ARM64/x86_64 only.
@MainActor
final class AnalysisBenchmarkTests: XCTestCase {
    private let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")

    func testBenchmarkRunsAndReportsCoarseTimingsForSystemBinary() throws {
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls is not readable on this host")
        }
        let result = try AnalysisBenchmark().run(url: systemBinaryURL)

        // Timings are non-negative wall-clock seconds.
        XCTAssertGreaterThanOrEqual(result.loadSeconds, 0)
        XCTAssertGreaterThanOrEqual(result.analyzeSeconds, 0)
        XCTAssertGreaterThanOrEqual(result.decompileFirstProcedureSeconds, 0)
        // The full analysis decoded instructions and recovered procedures.
        XCTAssertGreaterThan(result.instructionCount, 0)
        XCTAssertGreaterThan(result.procedureCount, 0)
        // Peak memory, when reported, is a positive byte count.
        if let peak = result.peakResidentBytes {
            XCTAssertGreaterThan(peak, 0)
        }
    }

    func testBenchmarkEnvironmentGateDefaultsOff() {
        // The slow full-binary measurement must default OFF so a normal test run stays
        // fast. With the env var unset, the gate reports disabled.
        if ProcessInfo.processInfo.environment[AnalysisBenchmark.enableEnvironmentKey] == nil {
            XCTAssertFalse(AnalysisBenchmark.isEnabledByEnvironment)
        }
    }

    /// XCTest `measure {}` over the analysis pipeline on the small system binary. This is
    /// the performance-seam measurement; it stays fast because `/bin/ls` is small. Gated
    /// behind the benchmark env var so the normal `xcodebuild test` run does not pay the
    /// repeated-iteration cost.
    func testMeasureAnalysisThroughputGated() throws {
        guard AnalysisBenchmark.isEnabledByEnvironment else {
            throw XCTSkip("set \(AnalysisBenchmark.enableEnvironmentKey)=1 to run the analysis throughput measurement")
        }
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls is not readable on this host")
        }
        measure {
            _ = try? AnalysisEngine().analyze(url: systemBinaryURL)
        }
    }
}
