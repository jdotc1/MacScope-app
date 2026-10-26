import Foundation
import XCTest
@testable import MacScope

/// RX-01 on real binaries: the committed clang-built v1/v2 fixture
/// (`MacScope/Tests/Fixtures/RX01Versioned`, generated and checked by
/// `Scripts/version-matching/generate_rx01_versioned_fixture.py`) runs through the real loader,
/// analysis, fingerprint adapter, matcher, candidate builder and planner. No compiler is needed at
/// test time, so nothing here skips.
///
/// Stripped variants keep the exact layout of their named build, so every function is labelled by
/// its source name through the named build's start addresses.
final class AnnotationTransferRealBinaryTests: XCTestCase {
    private let oldSlot = ImageSlot.primary
    private let newSlot = ImageSlot(rawValue: 1)

    // MARK: - Fixture loading

    private static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/RX01Versioned", isDirectory: true)

    private func analyzed(_ variant: String) throws -> (BinaryImage, ImageAnalysis) {
        let url = Self.fixtureDirectory.appendingPathComponent(variant)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture \(url.path)")
        let snapshot = try AnalysisEngine().analyze(url: url)
        let binary = try XCTUnwrap(snapshot.binaries.first)
        return (binary, try XCTUnwrap(snapshot.analysis(in: binary.slot)))
    }

    /// Source-name labels by function start, read from a NAMED build (leading `_` dropped).
    private func labels(fromNamed variant: String) throws -> [UInt64: String] {
        let (_, analysis) = try analyzed(variant)
        var result: [UInt64: String] = [:]
        for function in analysis.functions where !FunctionVersionFingerprinting.isGeneratedName(function.name) {
            result[function.startAddress] = function.name.hasPrefix("_") ? String(function.name.dropFirst()) : function.name
        }
        return result
    }

    private struct Comparison {
        let snapshot: WorkspaceSnapshot
        let result: FunctionVersionMatchResult
        let oldLabels: [UInt64: String]
        let newLabels: [UInt64: String]
        let oldAddresses: [String: UInt64]
        let newAddresses: [String: UInt64]

        func oldLabel(_ address: UInt64) -> String { oldLabels[address] ?? String(format: "?0x%llx", address) }
        func newLabel(_ address: UInt64) -> String { newLabels[address] ?? String(format: "?0x%llx", address) }

        /// The source function an old label is in the new version: identical, except the one
        /// function the fixture renames (`old_name` in v1 is `new_name` in v2, same body).
        static let renamedInV2 = ["old_name": "new_name"]

        /// True when the old and new starts are the same source function.
        func isSameSourceFunction(old: UInt64, new: UInt64) -> Bool {
            let source = oldLabel(old)
            return (Self.renamedInV2[source] ?? source) == newLabel(new)
        }

        /// One line per pair, then removed, added and unresolved, all by source name.
        var table: [String] {
            var lines = result.matches.map { match in
                let differences = match.differences.map(\.rawValue).joined(separator: ",")
                return "\(oldLabel(match.oldAddress))>\(newLabel(match.newAddress)) \(match.basis.rawValue) "
                    + "\(match.confidence) [\(differences)]"
            }
            lines += result.removedIDs.compactMap { oldAddresses[$0] }.map { "removed \(oldLabel($0))" }
            lines += result.addedIDs.compactMap { newAddresses[$0] }.map { "added \(newLabel($0))" }
            lines += result.unresolved.map { group in
                let olds = group.oldIDs.compactMap { oldAddresses[$0] }.map(oldLabel).joined(separator: ",")
                let news = group.newIDs.compactMap { newAddresses[$0] }.map(newLabel).joined(separator: ",")
                return "unresolved [\(olds)]>[\(news)] \(group.bases.map(\.rawValue).joined(separator: ","))"
            }
            return lines
        }
    }

    /// Loads `old` into slot 0 and `new` into slot 1, authors a name and an entry comment on every
    /// labelled old function (`user_<label>`, `note <label>`), and runs Compare Images' computation.
    private func compare(old: String, oldNamed: String, new: String, newNamed: String,
                         newOverrides: [String: AddressOverride] = [:]) throws -> Comparison {
        let (oldBinary, oldAnalysis) = try analyzed(old)
        let (loadedNew, newAnalysis) = try analyzed(new)
        var newBinary = loadedNew
        newBinary.slot = newSlot
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: oldBinary, analysis: oldAnalysis)
        snapshot.insertImage(binary: newBinary, analysis: newAnalysis)
        XCTAssertEqual(oldBinary.slot, oldSlot)

        let oldLabels = try labels(fromNamed: oldNamed)
        let newLabels = try labels(fromNamed: newNamed)
        for function in oldAnalysis.functions {
            guard let label = oldLabels[function.startAddress] else { continue }
            snapshot.addressOverrides[ImageAddress(slot: oldSlot, address: function.startAddress)] =
                AddressOverride(customName: "user_\(label)", customComment: "note \(label)")
        }
        let newStarts = Dictionary(newLabels.map { ($0.value, $0.key) }, uniquingKeysWith: min)
        for (label, override) in newOverrides {
            let address = try XCTUnwrap(newStarts[label], "no new function \(label)")
            snapshot.addressOverrides[ImageAddress(slot: newSlot, address: address)] = override
        }

        let computation = try VersionCompareComputation.build(old: oldAnalysis, new: newAnalysis)
        return Comparison(
            snapshot: snapshot, result: computation.result, oldLabels: oldLabels, newLabels: newLabels,
            oldAddresses: Dictionary(uniqueKeysWithValues: oldAnalysis.functions.map { ($0.id.uuidString, $0.startAddress) }),
            newAddresses: Dictionary(uniqueKeysWithValues: newAnalysis.functions.map { ($0.id.uuidString, $0.startAddress) }))
    }

    private func candidates(_ comparison: Comparison) -> [AnnotationTransferCandidate] {
        AnnotationTransferCandidates.build(result: comparison.result, oldSlot: oldSlot, newSlot: newSlot,
                                           snapshot: comparison.snapshot)
    }

    private func preview(_ comparison: Comparison, _ candidates: [AnnotationTransferCandidate]) throws -> AnnotationTransferPreview {
        try AnnotationTransferCandidates.preview(
            candidates, selected: AnnotationTransferCandidates.defaultSelection(candidates),
            oldSlot: oldSlot, newSlot: newSlot, snapshot: comparison.snapshot)
    }

    private func assertTable(_ comparison: Comparison, _ expected: [String],
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = comparison.table
        XCTAssertEqual(actual.sorted(), expected.sorted(),
                       "actual match table:\n" + actual.joined(separator: "\n"), file: file, line: line)
    }

    // MARK: - Cases

    func testNamedBuildsTransferExpectedSet() throws {
        let comparison = try compare(old: "rx01_v1", oldNamed: "rx01_v1", new: "rx01_v2", newNamed: "rx01_v2",
                                     newOverrides: ["checksum": AddressOverride(customName: "authored_in_v2")])
        assertTable(comparison, Self.namedTable)

        let candidates = candidates(comparison)
        let preview = try preview(comparison, candidates)
        XCTAssertEqual(candidates.filter(\.isPreselected).map { comparison.oldLabel($0.oldAddress) }.sorted(),
                       Self.namedPreselected)
        XCTAssertEqual(preview.changes.compactMap(\.newName).sorted(), Self.namedTransferredNames)
        XCTAssertEqual(preview.conflicts.map { "\(comparison.newLabel($0.destinationAddress)) \($0.field) \($0.kind)" }.sorted(),
                       Self.namedConflicts)
        XCTAssertTrue(candidates.allSatisfy { $0.skip == nil })
        for change in preview.changes {
            XCTAssertTrue(comparison.isSameSourceFunction(old: change.sourceAddress, new: change.destinationAddress),
                          "a transfer lands on the same source function: "
                              + "\(comparison.oldLabel(change.sourceAddress))>\(comparison.newLabel(change.destinationAddress))")
        }
    }

    func testStrippedDestinationStillMatchesByBodyAndTransfersNames() throws {
        let comparison = try compare(old: "rx01_v1", oldNamed: "rx01_v1", new: "rx01_v2_stripped", newNamed: "rx01_v2")
        assertTable(comparison, Self.strippedDestinationTable)

        let candidates = candidates(comparison)
        XCTAssertTrue(candidates.allSatisfy { $0.destinationSymbol == nil }, "stripped names are generated, never D3 conflicts")
        let preview = try preview(comparison, candidates)
        XCTAssertEqual(preview.changes.compactMap(\.newName).sorted(), Self.strippedDestinationTransferredNames)
        XCTAssertTrue(preview.conflicts.isEmpty)
        for change in preview.changes {
            XCTAssertTrue(comparison.isSameSourceFunction(old: change.sourceAddress, new: change.destinationAddress),
                          "\(comparison.oldLabel(change.sourceAddress))>\(comparison.newLabel(change.destinationAddress))")
        }
    }

    func testBothStrippedNeverMatchByAddress() throws {
        let comparison = try compare(old: "rx01_v1_stripped", oldNamed: "rx01_v1",
                                     new: "rx01_v2_stripped", newNamed: "rx01_v2")
        assertTable(comparison, Self.bothStrippedTable)
        for match in comparison.result.matches {
            XCTAssertTrue(comparison.isSameSourceFunction(old: match.oldAddress, new: match.newAddress),
                          "every pair joins the same source function, never an address coincidence: "
                              + "\(comparison.oldLabel(match.oldAddress))>\(comparison.newLabel(match.newAddress))")
        }
    }

    func testInlinedFunctionIsRemovedNotMisattributed() throws {
        let comparison = try compare(old: "rx01_v1", oldNamed: "rx01_v1", new: "rx01_v2_inlined", newNamed: "rx01_v2_inlined")
        assertTable(comparison, Self.inlinedTable)
        let preview = try preview(comparison, candidates(comparison))
        let parseHeader = try XCTUnwrap(preview.changes.first { comparison.newLabel($0.destinationAddress) == "parse_header" })
        XCTAssertEqual(parseHeader.newName, "user_parse_header")
        XCTAssertEqual(parseHeader.newComment, "note parse_header", "the inlined callee's comment is not carried")
        XCTAssertFalse(preview.changes.contains { $0.newName == "user_leaf_called_once" || $0.newComment == "note leaf_called_once" })
    }

    func testIdenticalCodeFoldedPairsStayUnresolved() throws {
        let stripped = try compare(old: "rx01_v1_stripped", oldNamed: "rx01_v1",
                                   new: "rx01_v2_merged_stripped", newNamed: "rx01_v2_merged")
        assertTable(stripped, Self.mergedStrippedTable)
        XCTAssertFalse(candidates(stripped).contains { stripped.oldLabel($0.oldAddress).hasPrefix("helper_") },
                       "folded helpers are never offered")

        let named = try compare(old: "rx01_v1", oldNamed: "rx01_v1", new: "rx01_v2_merged", newNamed: "rx01_v2_merged")
        assertTable(named, Self.mergedNamedTable)
    }

    // MARK: - Expected tables (established against the committed fixture; see the RX-01 report)

    static let namedTable = [
        "leaf_called_once>leaf_called_once symbolName high [body,size]",
        "parse_header>parse_header symbolName high []",
        "checksum>checksum symbolName high [body]",
        "old_name>new_name normalizedBody high []",
        "main>main symbolName high [body,callees,size]",
        "helper_a>helper_a symbolName high []",
        "helper_b>helper_b symbolName high []",
        "removed removed_fn",
        "added added_fn",
    ]
    static let namedPreselected = ["checksum", "helper_a", "helper_b", "leaf_called_once", "main", "old_name", "parse_header"]
    static let namedTransferredNames = ["user_helper_a", "user_helper_b", "user_leaf_called_once", "user_main", "user_parse_header"]
    static let namedConflicts = ["checksum name authored", "new_name name destinationSymbol"]
    static let strippedDestinationTable = [
        "parse_header>parse_header normalizedBody high []",
        "checksum>checksum normalizedBody high [body]",
        "old_name>new_name normalizedBody high []",
        "leaf_called_once>leaf_called_once callGraphPropagation low [body,size]",
        "unresolved [helper_a,helper_b]>[helper_a,helper_b] duplicateNormalizedBody",
        "removed main",
        "removed removed_fn",
        "added added_fn",
        "added main",
    ]
    static let strippedDestinationTransferredNames = ["user_checksum", "user_old_name", "user_parse_header"]
    static let bothStrippedTable = strippedDestinationTable
    static let inlinedTable = [
        "parse_header>parse_header symbolName high [body,callees,size]",
        "checksum>checksum symbolName high [body]",
        "old_name>new_name normalizedBody high []",
        "main>main symbolName high [body,callees,size]",
        "helper_a>helper_a symbolName high []",
        "helper_b>helper_b symbolName high []",
        "removed leaf_called_once",
        "removed removed_fn",
        "added added_fn",
    ]
    /// `-Wl,-deduplicate` folds the helpers into one body at helper_b's old slot; the linker
    /// emits `_helper_b` first in the symbol table for that address, so the folded function is
    /// labelled `helper_b` (the analysis keeps the first symbol at an address).
    static let mergedStrippedTable = [
        "parse_header>parse_header normalizedBody high []",
        "checksum>checksum normalizedBody high [body]",
        "old_name>new_name normalizedBody high []",
        "leaf_called_once>leaf_called_once callGraphPropagation low [body,size]",
        "unresolved [helper_a,helper_b]>[helper_b] duplicateNormalizedBody",
        "removed main",
        "removed removed_fn",
        "added added_fn",
        "added main",
    ]
    /// Named merged build: the folded function's real symbol is `_helper_b`, so helper_b keeps its
    /// name pair and helper_a, whose body no longer exists separately, is removed.
    static let mergedNamedTable = namedTable.filter { !$0.hasPrefix("helper_a>") } + ["removed helper_a"]
}
