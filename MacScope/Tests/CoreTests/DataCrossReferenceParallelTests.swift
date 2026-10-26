import Foundation
import XCTest
@testable import MacScope

/// `resolveParallel` chunks the STATEFUL data-xref pass at terminator boundaries and resolves the
/// chunks concurrently. Its one contract: byte-identical output to the sequential `resolve`. These
/// tests prove that on real binaries (real terminator distribution + real adrp/add/ldr idioms),
/// forcing the parallel path with `threshold: 1` so even a small binary splits into many chunks.
final class DataCrossReferenceParallelTests: XCTestCase {
    private let resolver = DataCrossReferenceResolver()

    private func dataRanges(_ snapshot: WorkspaceSnapshot) -> [DataCrossReferenceResolver.DataRange] {
        snapshot.sections
            .filter { !$0.isExecutable && $0.size > 0 }
            .map { .init(lowerBound: $0.address, upperBound: $0.address &+ $0.size) }
    }

    /// The equivalence guarantee on a large binary: many terminator-aligned chunks, resolved in
    /// parallel, must yield exactly the references (same order, same values) the linear pass does.
    func testParallelMatchesSequentialOnRealBinary() throws {
        for path in ["/usr/lib/dyld", "/bin/ls"] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let snapshot = try AnalysisEngine().analyze(url: URL(fileURLWithPath: path))
            let rows = snapshot.instructions
            let strings = Set(snapshot.stringLiterals.map(\.address))
            let selectors = Set(snapshot.objcSelectors.keys)
            let ranges = dataRanges(snapshot)

            let sequential = resolver.resolve(
                instructions: rows, stringAddresses: strings, selectorSlots: selectors, dataRanges: ranges)
            // threshold: 1 forces the parallel path regardless of size, so even /bin/ls splits.
            let parallel = resolver.resolveParallel(
                instructions: rows, stringAddresses: strings, selectorSlots: selectors,
                dataRanges: ranges, threshold: 1)

            XCTAssertEqual(parallel, sequential,
                           "parallel data-xref resolution diverged from sequential on \(path)")
            if path.hasSuffix("dyld") {
                XCTAssertFalse(parallel.isEmpty, "sanity: dyld should have recovered data xrefs")
            }
        }
    }

    /// A binary with NO data sections / empty classification sets still resolves identically
    /// (the page-base tracking runs but nothing classifies) — guards the empty-output path.
    func testParallelMatchesSequentialWithEmptyClassificationInputs() throws {
        let path = "/bin/ls"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no /bin/ls") }
        let rows = try AnalysisEngine().analyze(url: URL(fileURLWithPath: path)).instructions
        let sequential = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: [])
        let parallel = resolver.resolveParallel(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: [], threshold: 1)
        XCTAssertEqual(parallel, sequential)
    }

    /// Below the threshold the parallel entry falls back to the sequential core — still identical.
    func testBelowThresholdFallbackMatchesSequential() throws {
        let path = "/bin/ls"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("no /bin/ls") }
        let rows = try AnalysisEngine().analyze(url: URL(fileURLWithPath: path)).instructions
        let sequential = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: [])
        let belowThreshold = resolver.resolveParallel(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: [],
            threshold: rows.count + 1)
        XCTAssertEqual(belowThreshold, sequential)
    }
}
