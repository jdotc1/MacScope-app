import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class InvestigatorNativeExportTests: XCTestCase {
    private let sliceHash = String(repeating: "a", count: 64)
    private let analysisHash = String(repeating: "b", count: 64)

    private func input(slot: ImageSlot = .primary, subtype: Int32 = 0,
                       sliceIndex: Int? = nil) throws -> InvestigatorNativeExportInput {
        let binaryID = UUID()
        let functionID = UUID()
        let artifact = try MachOSliceArtifactIdentity(
            uuid: nil, rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: subtype, selectedSliceSHA256: sliceHash,
            selectedSliceByteCount: 4096
        )
        let binary = BinaryImage(id: binaryID, name: "Fixture", path: "/fixture",
                                 kind: "executable", architecture: subtype == 2 ? "arm64e" : "arm64",
                                 selectedSliceIndex: sliceIndex, artifactIdentity: artifact,
                                 artifactIntegrityState: .verified, slot: slot)
        var analysis = ImageAnalysis()
        analysis.functions = [FunctionSummary(id: functionID, name: "_entry",
                                              startAddress: 0x1000, endAddress: 0x1008,
                                              confidence: 1)]
        analysis.instructions = [InstructionRow(address: 0x1000, bytes: "00 00 80 d2",
                                                mnemonic: "mov", operands: "x0, #0",
                                                hasBreakpoint: false, comment: nil),
                                 InstructionRow(address: 0x1004, bytes: "c0 03 5f d6",
                                                mnemonic: "ret", operands: "",
                                                hasBreakpoint: false, comment: nil)]
        analysis.analysisInputFingerprint = try AnalysisInputFingerprint(
            imageSlot: slot, binaryID: binaryID, binaryName: binary.name,
            binaryPath: binary.path, selectedSliceIndex: sliceIndex,
            artifactIdentity: artifact, imageByteCount: 4096,
            imageBytesSHA256: String(repeating: "c", count: 64),
            facets: [], overallSHA256: analysisHash
        )
        let workspace = Phase2ReadWorkspaceIdentity(
            document: .init(instanceID: UUID()), instanceID: UUID()
        )
        let image = Phase2ReadImageIdentity(
            owner: .init(slot: slot, binaryID: binaryID,
                         architecture: binary.architecture, sliceIndex: sliceIndex,
                         ownerGeneration: 1),
            analysisRevision: 1, analysisFingerprintSHA256: analysisHash
        )
        return .init(captureID: UUID(), documentID: UUID(), workspaceID: UUID(),
                     precondition: .init(workspace: workspace, workspaceRevision: 1,
                                         strictWholeWorkspace: true, image: image,
                                         dependencies: []), binary: binary, analysis: analysis,
                     functionID: functionID)
    }

    private func object(_ export: InvestigatorNativeExport) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: export.bytes) as? [String: Any])
    }

    func testStructuredFunctionExportAndExactReverseMap() throws {
        let first = try input()
        let second = try input(slot: .init(rawValue: 1), subtype: 2, sliceIndex: 1)
        let firstExport = try InvestigatorNativeExporter.export(first)
        let secondExport = try InvestigatorNativeExporter.export(second)
        let firstRecord = try XCTUnwrap((object(firstExport)["records"] as? [[String: Any]])?.first)
        let secondImage = try XCTUnwrap((object(secondExport)["images"] as? [[String: Any]])?.first)
        let firstID = try XCTUnwrap(firstRecord["record_id"] as? String)
        let secondID = try XCTUnwrap(secondExport.reverse.keys.first)

        XCTAssertEqual(try object(firstExport)["schema_version"] as? Int, 1)
        XCTAssertEqual(firstRecord["kind"] as? String, "function")
        XCTAssertEqual(firstRecord["address"] as? String, "0x1000")
        XCTAssertTrue(firstRecord["scenario_id"] is NSNull)
        XCTAssertEqual(firstRecord["content_sha256"] as? String,
                       SHA256.hash(data: Data((firstRecord["text"] as? String ?? "").utf8))
                        .map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(firstExport.reverse[firstID]?.lineAddresses, [0x1000, 0x1004])
        XCTAssertEqual(firstExport.reverse[firstID]?.functionID, first.functionID)
        XCTAssertNotEqual(firstID, secondID) // equal addresses cannot alias another image
        XCTAssertEqual(secondImage["architecture"] as? String, "arm64e")
        XCTAssertEqual(secondImage["slice_id"] as? String, "s-\(sliceHash)-1")
    }

    func testUnrepresentableOrUnverifiedSliceRefused() throws {
        let source = try input()
        var unverifiedBinary = source.binary
        unverifiedBinary.artifactIntegrityState = .unavailable
        let unknown = InvestigatorNativeExportInput(
            captureID: source.captureID, documentID: source.documentID,
            workspaceID: source.workspaceID, precondition: source.precondition,
            binary: unverifiedBinary, analysis: source.analysis,
            functionID: source.functionID
        )
        XCTAssertThrowsError(try InvestigatorNativeExporter.export(unknown)) {
            XCTAssertEqual($0 as? InvestigatorNativeExportError, .missingSelectedSlice)
        }
        let x86h = try MachOSliceArtifactIdentity(
            uuid: nil, rawCPUType: MachOConstants.cpuTypeX86_64,
            rawCPUSubtype: 8, selectedSliceSHA256: sliceHash,
            selectedSliceByteCount: 4096
        )
        var unsupportedBinary = source.binary
        unsupportedBinary.artifactIdentity = x86h
        let unsupported = InvestigatorNativeExportInput(
            captureID: source.captureID, documentID: source.documentID,
            workspaceID: source.workspaceID, precondition: source.precondition,
            binary: unsupportedBinary, analysis: source.analysis,
            functionID: source.functionID
        )
        XCTAssertThrowsError(try InvestigatorNativeExporter.export(unsupported)) {
            XCTAssertEqual($0 as? InvestigatorNativeExportError, .unsupportedArchitecture)
        }
    }

    func testPublicationRefusesReplacedDocumentCaptureAndAnalysis() throws {
        let source = try input()
        let export = try InvestigatorNativeExporter.export(source)
        let expected = Phase2ReadCurrentState(
            workspace: source.precondition.workspace, workspaceRevision: 1,
            image: source.precondition.image, facetRevisions: []
        )
        XCTAssertTrue(export.mayPublish(documentID: source.documentID,
                                         workspaceID: source.workspaceID,
                                         activeCaptureID: source.captureID,
                                         currentState: expected))
        XCTAssertFalse(export.mayPublish(documentID: UUID(), workspaceID: source.workspaceID,
                                          activeCaptureID: source.captureID, currentState: expected))
        XCTAssertFalse(export.mayPublish(documentID: source.documentID,
                                          workspaceID: source.workspaceID,
                                          activeCaptureID: UUID(), currentState: expected))
        let changed = Phase2ReadCurrentState(
            workspace: source.precondition.workspace, workspaceRevision: 1,
            image: .init(owner: source.precondition.image!.owner,
                         analysisRevision: 2, analysisFingerprintSHA256: analysisHash),
            facetRevisions: []
        )
        XCTAssertFalse(export.mayPublish(documentID: source.documentID,
                                          workspaceID: source.workspaceID,
                                          activeCaptureID: source.captureID, currentState: changed))
        let originalOwner = try XCTUnwrap(source.precondition.image?.owner)
        let reusedSlot = Phase2ReadCurrentState(
            workspace: source.precondition.workspace, workspaceRevision: 1,
            image: .init(owner: .init(slot: originalOwner.slot, binaryID: UUID(),
                                      architecture: originalOwner.architecture,
                                      sliceIndex: originalOwner.sliceIndex,
                                      ownerGeneration: originalOwner.ownerGeneration + 1),
                         analysisRevision: 1, analysisFingerprintSHA256: analysisHash),
            facetRevisions: []
        )
        XCTAssertFalse(export.mayPublish(documentID: source.documentID,
                                          workspaceID: source.workspaceID,
                                          activeCaptureID: source.captureID,
                                          currentState: reusedSlot))
    }
}
