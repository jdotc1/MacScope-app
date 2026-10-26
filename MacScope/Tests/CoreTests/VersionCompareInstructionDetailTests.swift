import Foundation
import XCTest
@testable import MacScope

final class VersionCompareInstructionDetailTests: XCTestCase {
    func testAcceptedPairShowsBothSourcesAndRejectsChangedLiveFacts() throws {
        let oldBinary = binary(.primary, name: "old")
        let newSlot = ImageSlot(rawValue: 1)
        let newBinary = binary(newSlot, name: "new")
        let oldID = UUID()
        let newID = UUID()
        let oldFunction = function(oldID, at: 0x1000, end: 0x1010)
        let newFunction = function(newID, at: 0x2000, end: 0x2010)
        var oldAnalysis = try analysis(binary: oldBinary, function: oldFunction, instruction: instruction(0x1000))
        var newAnalysis = try analysis(binary: newBinary, function: newFunction, instruction: instruction(0x2000))
        oldAnalysis.xrefs = [XRef(id: UUID(), from: 0x900, to: 0x1000, kind: XRefKind.call)]
        newAnalysis.xrefs = [XRef(id: UUID(), from: 0x1900, to: 0x2000, kind: XRefKind.call)]
        let original = workspace(oldBinary: oldBinary, newBinary: newBinary,
                                 oldAnalysis: oldAnalysis, newAnalysis: newAnalysis)
        let computation = try VersionCompareComputation.build(old: oldAnalysis, new: newAnalysis)
        let pair = VersionComparePair(
            old: VersionCompareImage(slot: oldBinary.slot, binaryID: oldBinary.id, name: oldBinary.name,
                                     analysisFingerprint: oldAnalysis.analysisInputFingerprint?.overallSHA256),
            new: VersionCompareImage(slot: newBinary.slot, binaryID: newBinary.id, name: newBinary.name,
                                     analysisFingerprint: newAnalysis.analysisInputFingerprint?.overallSHA256))
        let row = try XCTUnwrap(computation.report.rows.first {
            $0.old?.id == oldID.uuidString && $0.new?.id == newID.uuidString
        })

        switch VersionCompareInstructionDetail.project(
            row: row, pair: pair, computation: computation, snapshot: original
        ) {
        case .ready(let detail):
            XCTAssertEqual(detail.old.instructions.map(\.address), [0x1000])
            XCTAssertEqual(detail.new.instructions.map(\.address), [0x2000])
            XCTAssertEqual(detail.old.context.callers.map(\.address), [0x900])
            XCTAssertEqual(detail.new.context.callers.map(\.address), [0x1900])
        case .unavailable(let reason):
            XCTFail("Expected both source rows: \(reason)")
        }

        // A declared analysis digest can remain unchanged while its in-memory function facts
        // change. The detail must compare the current matcher inputs before showing rows.
        var alteredOld = oldAnalysis
        alteredOld.functions = [function(oldID, at: 0x1000, end: 0x1020)]
        let altered = workspace(oldBinary: oldBinary, newBinary: newBinary,
                                oldAnalysis: alteredOld, newAnalysis: newAnalysis)
        switch VersionCompareInstructionDetail.project(
            row: row, pair: pair, computation: computation, snapshot: altered
        ) {
        case .ready:
            XCTFail("Stale source facts must not be shown")
        case .unavailable:
            break
        }
    }

    func testChangeContextKeepsKindsAndBoundsVisibleLinks() {
        let target = function(UUID(), at: 0x1000, end: 0x1010)
        let caller = function(UUID(), at: 0x800, end: 0x900)
        let calls = (0..<30).map { index in
            XRef(id: UUID(), from: 0x800 + UInt64(index), to: 0x1000, kind: XRefKind.call)
        }
        let otherIn = XRef(id: UUID(), from: 0x700, to: 0x1004, kind: XRefKind.data)
        let out = XRef(id: UUID(), from: 0x1008, to: 0x3000, kind: XRefKind.string)
        let type = TypeAtlasEntry(
            id: TypeAtlasEntryID(slot: .primary, kind: .userType, key: .name("Record")),
            kind: .userType, name: "Record", superclass: nil, members: [],
            conformances: [], methods: [], users: [0x1004, 0x2000], evidence: .authored
        )
        let context = VersionCompareChangeContext.project(
            function: target, functions: [target, caller], xrefs: calls + [otherIn, out],
            catalog: ImageTypeCatalog(slot: .primary, entries: [type]))
        XCTAssertEqual(context.callerCount, 30)
        XCTAssertEqual(context.callers.count, VersionCompareChangeContext.maximumLinksPerGroup)
        XCTAssertEqual(context.callers.first?.address, 0x800)
        XCTAssertEqual(context.incomingReferences.map(\.address), [0x700])
        XCTAssertEqual(context.outgoingReferences.map(\.address), [0x3000])
        XCTAssertEqual(context.typeUsers.map(\.address), [0x1004])
        XCTAssertEqual(context.typeUsers.first?.label, "Record")
    }

    private func binary(_ slot: ImageSlot, name: String) -> BinaryImage {
        BinaryImage(id: UUID(), name: name, path: "/tmp/\(name)", kind: "executable",
                    architecture: "arm64", slot: slot)
    }

    private func function(_ id: UUID, at address: UInt64, end: UInt64) -> FunctionSummary {
        FunctionSummary(id: id, name: "_target", startAddress: address,
                        endAddress: end, confidence: 1)
    }

    private func instruction(_ address: UInt64) -> InstructionRow {
        InstructionRow(address: address, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
                       hasBreakpoint: false, comment: nil)
    }

    private func analysis(binary: BinaryImage, function: FunctionSummary,
                          instruction: InstructionRow) throws -> ImageAnalysis {
        var value = ImageAnalysis()
        value.functions = [function]
        value.instructions = [instruction]
        let digest = String(repeating: binary.slot == .primary ? "a" : "b", count: 64)
        value.analysisInputFingerprint = try AnalysisInputFingerprint(
            imageSlot: binary.slot, binaryID: binary.id, binaryName: binary.name,
            binaryPath: binary.path, selectedSliceIndex: nil, artifactIdentity: nil,
            imageByteCount: 0, imageBytesSHA256: digest, facets: [], overallSHA256: digest)
        return value
    }

    private func workspace(oldBinary: BinaryImage, newBinary: BinaryImage,
                           oldAnalysis: ImageAnalysis, newAnalysis: ImageAnalysis) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: oldBinary, analysis: oldAnalysis)
        snapshot.insertImage(binary: newBinary, analysis: newAnalysis)
        return snapshot
    }
}
