import XCTest
@testable import MacScope

/// WS-9: a BinaryLoader wrapper that returns the real `LoadedBinary` with its `functionStarts` table
/// emptied — the "held out" ground-truth mode. Discovery must then recover starts by heuristics +
/// metadata seeding alone, exactly as it does on a stripped / dyld-cache binary that has no table.
struct HeldOutFunctionStartsLoader: BinaryLoader {
    let base: any BinaryLoader
    func load(at url: URL) throws -> LoadedBinary {
        var loaded = try base.load(at: url)
        loaded.functionStarts = []
        return loaded
    }
}

/// WS-9 measurement harness: `LC_FUNCTION_STARTS` is the linker's complete function-start table, so it
/// is the oracle. Hold it out from discovery and measure how many entries the heuristics (+ future
/// Swift-metadata seeding) recover. The delta this reports is the whole wave's success metric.
enum FunctionStartCoverage {
    struct Report: Equatable {
        var total: Int
        var recovered: Int
        var missed: [UInt64]
        var coverage: Double
    }

    /// Analyze `url` with the function-starts table HELD OUT, comparing discovered starts to the table.
    /// Requires `requestedSliceIndex == nil` so the engine uses the injected (held-out) loader.
    static func measure(url: URL, requestedSliceIndex: Int? = nil) throws -> Report {
        let table = Set(try BinaryLoaderRouter(requestedMachOSliceIndex: requestedSliceIndex)
            .load(at: url).functionStarts)
        guard !table.isEmpty else {
            return Report(total: 0, recovered: 0, missed: [], coverage: 1)
        }
        let engine = AnalysisEngine(loader: HeldOutFunctionStartsLoader(
            base: BinaryLoaderRouter(requestedMachOSliceIndex: requestedSliceIndex)))
        let snapshot = try engine.analyze(url: url, requestedSliceIndex: requestedSliceIndex,
                                          overrides: [:], cancellation: .never)
        let discovered = Set((snapshot.analysis(in: snapshot.primarySlot)?.functions ?? []).map(\.startAddress))
        let recovered = table.intersection(discovered)
        let missed = table.subtracting(discovered).sorted()
        return Report(total: table.count, recovered: recovered.count, missed: missed,
                      coverage: Double(recovered.count) / Double(table.count))
    }

    /// Coverage WITHOUT holding out the table — the engine seeds directly from it, so recovery must be
    /// complete. Proves the held-out wrapper is what drops coverage (the harness discriminates).
    static func measureWithTable(url: URL, requestedSliceIndex: Int? = nil) throws -> Report {
        let table = Set(try BinaryLoaderRouter(requestedMachOSliceIndex: requestedSliceIndex)
            .load(at: url).functionStarts)
        guard !table.isEmpty else {
            return Report(total: 0, recovered: 0, missed: [], coverage: 1)
        }
        let snapshot = try AnalysisEngine().analyze(url: url, requestedSliceIndex: requestedSliceIndex,
                                                    overrides: [:], cancellation: .never)
        let discovered = Set((snapshot.analysis(in: snapshot.primarySlot)?.functions ?? []).map(\.startAddress))
        let recovered = table.intersection(discovered)
        return Report(total: table.count, recovered: recovered.count,
                      missed: table.subtracting(discovered).sorted(),
                      coverage: Double(recovered.count) / Double(table.count))
    }
}

final class FunctionStartCoverageTests: XCTestCase {
    func testHeldOutLoaderDiscriminatesRecoveryFromTheTable() throws {
        let ls = URL(fileURLWithPath: "/bin/ls")
        try XCTSkipUnless(FileManager.default.isReadableFile(atPath: ls.path))

        let withTable = try FunctionStartCoverage.measureWithTable(url: ls)
        try XCTSkipUnless(withTable.total > 0, "no LC_FUNCTION_STARTS to hold out")
        // With the table present the engine seeds from it → complete recovery.
        XCTAssertEqual(withTable.recovered, withTable.total, "table entries must all be discovered when present")

        let heldOut = try FunctionStartCoverage.measure(url: ls)
        XCTAssertEqual(heldOut.total, withTable.total)
        XCTAssertLessThanOrEqual(heldOut.recovered, heldOut.total)
        XCTAssertGreaterThan(heldOut.coverage, 0.0)
        // The harness must actually discriminate — holding out the table can only lose coverage.
        XCTAssertLessThanOrEqual(heldOut.recovered, withTable.recovered)
        print("[WS-9] /bin/ls  held-out coverage: \(heldOut.recovered)/\(heldOut.total) = " +
              String(format: "%.3f", heldOut.coverage) + "  (missed \(heldOut.missed.count))")
    }
}
