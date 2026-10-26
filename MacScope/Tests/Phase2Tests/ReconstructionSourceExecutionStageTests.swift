import Darwin
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionSourceExecutionStageTests: XCTestCase {
    private func fixture() throws -> (ReconstructionSourceRevisionAuthority, ReconstructionSourceRevision) {
        let project = UUID(), job = UUID(), evidence = UUID()
        let hash = String(repeating: "a", count: 64)
        let artifact = ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: project),
            contentIdentity: try .init(algorithm: .sha256, digest: hash, byteCount: 100))
        let function = try ReconstructionFunctionCoordinate(artifact: artifact,
            image: .init(binaryID: project, imageSlot: .primary, selectedSliceIndex: nil, architecture: .arm64, machOIdentity: nil),
            analysisFingerprintSHA256: hash, startAddress: 0x1000, endAddressExclusive: 0x1010,
            boundarySchemaVersion: 1, functionUUIDHint: nil, symbolHint: nil)
        let authority = ReconstructionSourceRevisionAuthority(projectID: project, jobID: job, function: function,
            objectiveSHA256: hash, evidenceFrontierSHA256: hash, oracleSuiteSHA256: hash,
            admissibleEvidenceIDs: [evidence], currentRevision: nil)
        let source = Data("#include <stdint.h>\nuint32_t reconstructed(uint32_t x) { return x; }\n".utf8)
        let revision = try ReconstructionSourceRevisionAdmission.admit(proposal: .init(sourceUTF8: source,
            claimedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(source), evidenceIDs: [evidence]), authority: authority)
        return (authority, revision)
    }

    private func parent() throws -> URL {
        let url = TestWorkRoot.authority
            .appendingPathComponent("source-stage-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    func testExactAdmittedBytesAndExecutableIdentity() throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (authority, revision) = try fixture()
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let stage = try ReconstructionSourceExecutionStage.create(revision: revision, authority: authority, harness: harness, parent: parent)
        XCTAssertEqual(try Data(contentsOf: stage.root.appendingPathComponent("candidate.c")), revision.sourceUTF8)
        XCTAssertEqual(try Data(contentsOf: stage.root.appendingPathComponent("harness.c")), harness.sourceUTF8)
        try stage.verifyInputs()
        let output = stage.root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let binary = output.appendingPathComponent("candidate")
        try Data("controlled executable identity fixture".utf8).write(to: binary)
        XCTAssertEqual(chmod(binary.path, 0o700), 0)
        let identity = try stage.captureExecutable()
        try stage.verifyExecutable(identity)
        try Data("changed artifact".utf8).write(to: binary)
        XCTAssertThrowsError(try stage.verifyExecutable(identity))
    }

    func testRejectsSourceMutationSymlinkAndSameBytesReplacement() throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (authority, revision) = try fixture()
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        for alteration in 0..<3 {
            let stage = try ReconstructionSourceExecutionStage.create(revision: revision, authority: authority, harness: harness, parent: parent)
            let path = stage.root.appendingPathComponent("candidate.c")
            let old = stage.root.appendingPathComponent("retained-original.c")
            try FileManager.default.moveItem(at: path, to: old)
            if alteration == 0 { try Data("changed".utf8).write(to: path) }
            if alteration == 1 { try FileManager.default.createSymbolicLink(at: path, withDestinationURL: old) }
            if alteration == 2 { try revision.sourceUTF8.write(to: path) }
            XCTAssertThrowsError(try stage.verifyInputs())
        }
    }

    func testTrustedOriginalIsDistinctAndRequiresExactImmutableBytes() throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (_, revision) = try fixture()
        let harness = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        let stage = try ReconstructionSourceExecutionStage.createOriginalAuthority(
            sourceUTF8: revision.sourceUTF8, expectedSourceSHA256: revision.sourceSHA256,
            harness: harness, parent: parent)
        XCTAssertEqual(stage.sourceAuthority, .trustedOriginal(sourceSHA256: revision.sourceSHA256))
        XCTAssertNil(stage.revisionSHA256)
        XCTAssertEqual(try Data(contentsOf: stage.root.appendingPathComponent("candidate.c")), revision.sourceUTF8)
        try stage.verifyInputs()
        for bytes in [Data(), Data([0xff]), Data([0]), Data(repeating: 65, count: 65_537)] {
            XCTAssertThrowsError(try ReconstructionSourceExecutionStage.createOriginalAuthority(
                sourceUTF8: bytes, expectedSourceSHA256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes),
                harness: harness, parent: parent))
        }
        XCTAssertThrowsError(try ReconstructionSourceExecutionStage.createOriginalAuthority(
            sourceUTF8: revision.sourceUTF8, expectedSourceSHA256: String(repeating: "0", count: 64),
            harness: harness, parent: parent))
        let source = stage.root.appendingPathComponent("candidate.c")
        try FileManager.default.moveItem(at: source,
            to: stage.root.appendingPathComponent("retained-original.c"))
        try revision.sourceUTF8.write(to: source)
        XCTAssertThrowsError(try stage.verifyInputs())
    }

    func testInspectionCapturesBoundedBytesAndRejectsUnsafeFiles() throws {
        let parent = try parent(); defer { try? FileManager.default.removeItem(at: parent) }
        let (authority, revision) = try fixture()
        let stage = try ReconstructionSourceExecutionStage.create(revision: revision, authority: authority,
            harness: ReconstructionSourceBehaviorHarness.saturatingIncrementV1(), parent: parent)
        XCTAssertEqual(stage.sourceAuthority, .admittedRevision(revisionSHA256: revision.revisionSHA256))
        let directory = stage.root.appendingPathComponent("inspection", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("candidate.ast.json")
        let bytes = Data("{\"kind\":\"TranslationUnitDecl\"}".utf8)
        try bytes.write(to: file)
        let captured = try stage.captureInspectionBytes()
        XCTAssertEqual(captured.bytes, bytes)
        XCTAssertEqual(captured.identity.sha256, ReconstructionSourceRevisionAdmission.sourceSHA256(bytes))
        XCTAssertEqual(try stage.captureInspection(), captured.identity)
        try Data(repeating: 65, count: 1_048_577).write(to: file)
        XCTAssertThrowsError(try stage.captureInspectionBytes())
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file,
            withDestinationURL: stage.root.appendingPathComponent("candidate.c"))
        XCTAssertThrowsError(try stage.captureInspectionBytes())
    }

    func testHarnessRetainsIndependentObservedOutputsAndRejectsMalformedValues() throws {
        let harness = try ReconstructionSourceBehaviorHarness(inputs: [0, 41, UInt32.max])
        XCTAssertEqual(try harness.decodeObservedOutputs(Data("0:7\n41:123\n4294967295:0\n".utf8)), [7, 123, 0])
        for text in ["0:7\n41:123\n", "00:7\n41:123\n4294967295:0\n", "0:7\n41:123\n4294967295:4294967296\n",
                     "0:7\n41:123\n4294967295:0", "0:7\n41:123\n4294967295:0\nextra\n"] {
            XCTAssertThrowsError(try harness.decodeObservedOutputs(Data(text.utf8)))
        }
        let fixed = try ReconstructionSourceBehaviorHarness.saturatingIncrementV1()
        XCTAssertEqual(fixed, try ReconstructionSourceBehaviorHarness.saturatingIncrementV1())
        XCTAssertEqual(Array(fixed.inputs.prefix(5)), [0, 1, 41, UInt32.max - 1, UInt32.max])
        XCTAssertEqual(fixed.inputs.count, 37)
    }
}
