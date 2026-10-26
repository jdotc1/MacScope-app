import Foundation
import XCTest
@testable import MacScope

final class VersionCompareExportServiceTests: XCTestCase {
    private let newSlot = ImageSlot(rawValue: 1)
    private let oldDigest = String(repeating: "a", count: 64)
    private let newDigest = String(repeating: "b", count: 64)

    func testFunctionsAreExportedInNumericAddressOrder() throws {
        let oldBinary = binary(.primary, name: "old")
        let newBinary = binary(newSlot, name: "new")
        let old = [
            function(UUID(), "_later", 0x100),
            function(UUID(), "_earlier", 0x0f),
        ]
        let snapshot = try workspace(oldBinary: oldBinary, newBinary: newBinary, old: old, new: [])
        let computation = try computation(in: snapshot)

        let data = try VersionCompareExportService.encode(
            computation: computation, pair: pair(oldBinary, newBinary), snapshot: snapshot)
        let report = try object(data)
        let removed = try XCTUnwrap(report["removed"] as? [[String: Any]])
        XCTAssertEqual(removed.compactMap { $0["address"] as? String },
                       [UInt64(0x0f).hexAddress, UInt64(0x100).hexAddress])
    }

    func testChangedSourceFactsAndReplacedImageAreRefused() throws {
        let oldBinary = binary(.primary, name: "old")
        let newBinary = binary(newSlot, name: "new")
        let oldID = UUID()
        let newID = UUID()
        let old = [function(oldID, "_main", 0x1000)]
        let new = [function(newID, "_main", 0x2000)]
        let original = try workspace(oldBinary: oldBinary, newBinary: newBinary, old: old, new: new)
        let comparison = try computation(in: original)
        let publishedPair = pair(oldBinary, newBinary)
        XCTAssertNoThrow(try VersionCompareExportService.encode(
            computation: comparison, pair: publishedPair, snapshot: original))

        // Keep the image IDs, slots, and declared analysis fingerprints. The matcher inputs
        // still differ because the currently analyzed function has another range.
        let changedFacts = try workspace(
            oldBinary: oldBinary, newBinary: newBinary,
            old: [function(oldID, "_main", 0x1000, size: 0x20)], new: new)
        XCTAssertThrowsError(try VersionCompareExportService.encode(
            computation: comparison, pair: publishedPair, snapshot: changedFacts)) {
            XCTAssertEqual($0 as? VersionCompareExportService.ExportError, .staleComparison)
        }

        let replacedBinary = binary(.primary, name: "old")
        let replaced = try workspace(
            oldBinary: replacedBinary, newBinary: newBinary, old: old, new: new)
        XCTAssertThrowsError(try VersionCompareExportService.encode(
            computation: comparison, pair: publishedPair, snapshot: replaced)) {
            XCTAssertEqual($0 as? VersionCompareExportService.ExportError, .staleComparison)
        }
    }

    func testUnresolvedGroupsAndManualPinsHaveDeterministicOutput() throws {
        let oldBinary = binary(.primary, name: "old")
        let newBinary = binary(newSlot, name: "new")
        let oldA1 = UUID(), oldA2 = UUID(), oldB1 = UUID(), oldB2 = UUID()
        let newA1 = UUID(), newA2 = UUID(), newB1 = UUID(), newB2 = UUID()
        let old = [
            function(oldA1, "_dupA", 0x1000), function(oldA2, "_dupA", 0x1100),
            function(oldB1, "_dupB", 0x2000), function(oldB2, "_dupB", 0x2100),
        ]
        let new = [
            function(newA1, "_dupA", 0x3000), function(newA2, "_dupA", 0x3100),
            function(newB1, "_dupB", 0x4000), function(newB2, "_dupB", 0x4100),
        ]
        let pin = FunctionVersionManualPin(oldID: oldA1.uuidString, newID: newA2.uuidString)
        let firstSnapshot = try workspace(oldBinary: oldBinary, newBinary: newBinary, old: old, new: new)
        let first = try pinnedComputation(in: firstSnapshot, pin: pin)
        let firstData = try VersionCompareExportService.encode(
            computation: first, pair: pair(oldBinary, newBinary), snapshot: firstSnapshot)

        let reversedSnapshot = try workspace(
            oldBinary: oldBinary, newBinary: newBinary,
            old: Array(old.reversed()), new: Array(new.reversed()))
        let second = try pinnedComputation(in: reversedSnapshot, pin: pin)
        let secondData = try VersionCompareExportService.encode(
            computation: second, pair: pair(oldBinary, newBinary), snapshot: reversedSnapshot)
        XCTAssertEqual(firstData, secondData)

        let report = try object(firstData)
        let summary = try XCTUnwrap(report["summary"] as? [String: Int])
        XCTAssertEqual(summary["manualPins"], 1)
        XCTAssertEqual(summary["unresolvedGroups"], 1)
        let pins = try XCTUnwrap(report["manualPins"] as? [[String: Any]])
        XCTAssertEqual(pins.count, 1)
        let unresolved = try XCTUnwrap(report["unresolved"] as? [[String: Any]])
        XCTAssertEqual(unresolved.count, 1)
        XCTAssertEqual(unresolved.first?["bases"] as? [String], ["duplicateSymbolName"])
    }

    private func binary(_ slot: ImageSlot, name: String) -> BinaryImage {
        BinaryImage(id: UUID(), name: name, path: "/tmp/\(name)", kind: "executable",
                    architecture: "arm64", slot: slot)
    }

    private func function(_ id: UUID, _ name: String, _ address: UInt64,
                          size: UInt64 = 0x10) -> FunctionSummary {
        FunctionSummary(id: id, name: name, startAddress: address,
                        endAddress: address + size, confidence: 1)
    }

    private func workspace(oldBinary: BinaryImage, newBinary: BinaryImage,
                           old: [FunctionSummary], new: [FunctionSummary]) throws -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        var oldAnalysis = ImageAnalysis()
        oldAnalysis.functions = old
        oldAnalysis.analysisInputFingerprint = try fingerprint(oldBinary, digest: oldDigest)
        var newAnalysis = ImageAnalysis()
        newAnalysis.functions = new
        newAnalysis.analysisInputFingerprint = try fingerprint(newBinary, digest: newDigest)
        snapshot.insertImage(binary: oldBinary, analysis: oldAnalysis)
        snapshot.insertImage(binary: newBinary, analysis: newAnalysis)
        return snapshot
    }

    private func fingerprint(_ binary: BinaryImage, digest: String) throws -> AnalysisInputFingerprint {
        try AnalysisInputFingerprint(
            imageSlot: binary.slot, binaryID: binary.id, binaryName: binary.name,
            binaryPath: binary.path, selectedSliceIndex: nil, artifactIdentity: nil,
            imageByteCount: 0, imageBytesSHA256: digest, facets: [], overallSHA256: digest)
    }

    private func pair(_ old: BinaryImage, _ new: BinaryImage) -> VersionComparePair {
        VersionComparePair(
            old: VersionCompareImage(slot: old.slot, binaryID: old.id, name: old.name,
                                     analysisFingerprint: oldDigest),
            new: VersionCompareImage(slot: new.slot, binaryID: new.id, name: new.name,
                                     analysisFingerprint: newDigest))
    }

    private func computation(in snapshot: WorkspaceSnapshot) throws -> VersionCompareComputation {
        try VersionCompareComputation.build(
            old: XCTUnwrap(snapshot.analysis(in: .primary)),
            new: XCTUnwrap(snapshot.analysis(in: newSlot)))
    }

    private func pinnedComputation(in snapshot: WorkspaceSnapshot,
                                   pin: FunctionVersionManualPin) throws -> VersionCompareComputation {
        let initial = try computation(in: snapshot)
        let result = try initial.matcher.resolve(initial.result, pinning: pin)
        return initial.replacingResult(result)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
