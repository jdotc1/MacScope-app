import Foundation
import XCTest
@testable import MacScope

final class LoadPathRiskEntitlementTests: XCTestCase {
    private let disableLV = "com.apple.security.cs.disable-library-validation"
    private let allowEnvironment = "com.apple.security.cs.allow-dyld-environment-variables"
    private var fixture: URL {
        TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            .appendingPathComponent("GoldenFixtures/load-path-risk/hardened.app")
    }

    // Constructed signature models isolate value-sensitive rules without signing or
    // executing another binary. Load commands remain those of the built fixture.
    private func input(_ values: [String: Any], root: URL? = nil) throws -> (MachOFile, Data, URL) {
        let root = root ?? fixture
        let path = root.appendingPathComponent("Contents/MacOS/RiskFixture")
        var file = try MachOParser().parse(Data(contentsOf: path))
        var signature = try XCTUnwrap(file.codeSignature)
        var blob = try XCTUnwrap(signature.superBlob)
        let xml = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        var bytes = Data(repeating: 0, count: 8)
        bytes.append(xml)
        blob.blobs.removeAll { $0.type == MachOConstants.codeSignatureSlotEntitlements ||
            $0.type == MachOConstants.codeSignatureSlotDerEntitlements }
        blob.blobs.append(.init(type: MachOConstants.codeSignatureSlotEntitlements,
            relativeOffset: 0, fileOffset: 0, magic: MachOConstants.codeSignatureEmbeddedEntitlementsMagic,
            length: UInt32(bytes.count), codeDirectory: nil,
            entitlements: .init(format: .xml, keyCount: values.count, keys: values.keys.sorted(), isParsed: true)))
        blob.blobCount = UInt32(blob.blobs.count)
        signature.superBlob = blob
        file.codeSignature = signature
        return (file, bytes, path)
    }

    private func assess(_ values: [String: Any], bytesAvailable: Bool = true) throws -> LoadPathRiskReport.Image {
        let (file, bytes, path) = try input(values)
        return try XCTUnwrap(LoadPathRiskAnalyzer().analyze(file, at: path, bundleRoot: fixture,
            selectedSliceBytes: bytesAvailable ? bytes : nil).images.first)
    }

    func testTrueExceptionsRestoreLoadingFindings() throws {
        let image = try assess([disableLV: true, allowEnvironment: true])
        XCTAssertEqual(image.entitlementState, "parsed")
        XCTAssertEqual(image.findings.first { $0.ruleID == "L2" }?.severity, .high)
        for id in ["L1", "L4", "L5"] {
            XCTAssertEqual(image.findings.first { $0.ruleID == id }?.severity, .medium)
        }
        XCTAssertFalse(image.findings.contains { $0.confidence == .needsPhaseB })
        XCTAssertEqual(image.priority?.level, .review)
    }

    func testFalseExceptionsKeepMitigations() throws {
        let image = try assess([disableLV: false, allowEnvironment: false])
        for id in ["L1", "L2", "L4"] {
            XCTAssertEqual(image.findings.first { $0.ruleID == id }?.severity, .low)
        }
        XCTAssertEqual(image.findings.first { $0.ruleID == "L5" }?.severity, .informational)
        XCTAssertFalse(image.findings.contains { $0.confidence == .needsPhaseB })
    }

    func testUnavailableAndNonBooleanValuesRemainReviewable() throws {
        for image in [try assess([disableLV: true, allowEnvironment: true], bytesAvailable: false),
                      try assess([disableLV: "false", allowEnvironment: "false"])] {
            XCTAssertEqual(image.findings.first { $0.ruleID == "L2" }?.severity, .high)
            XCTAssertEqual(image.findings.first { $0.ruleID == "L2" }?.confidence, .needsReview)
            XCTAssertEqual(image.findings.first { $0.ruleID == "L5" }?.confidence, .needsReview)
            XCTAssertFalse(image.findings.contains { $0.confidence == .needsPhaseB })
        }
    }

    func testPriorityRequiresPlistAndExplicitWriterEvidence() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.copyItem(at: fixture, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directory = temporary.appendingPathComponent("Contents/Library/LaunchDaemons")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appendingPathComponent("example.fixture.plist")
        func declare(_ user: String) throws {
            try PropertyListSerialization.data(fromPropertyList: [
                "Label": "example.fixture", "BundleProgram": "Contents/MacOS/RiskFixture", "UserName": user
            ], format: .xml, options: 0).write(to: plist)
        }
        try declare("root")
        let (file, bytes, path) = try input([disableLV: true], root: temporary)
        let evidence = LoadPathRiskReport.CandidateAccessEvidence(
            path: "/usr/local/lib/Found.framework/Found", writerUserID: 501, exists: true,
            source: "constructed ownership evidence")
        func assess(_ access: [LoadPathRiskReport.CandidateAccessEvidence]) throws -> LoadPathRiskReport.Image {
            try XCTUnwrap(LoadPathRiskAnalyzer().analyze(file, at: path, bundleRoot: temporary,
                selectedSliceBytes: bytes, candidateAccessEvidence: access).images.first)
        }
        let uncertain = try assess([])
        XCTAssertEqual(uncertain.privilege?.kind, .root)
        XCTAssertEqual(uncertain.privilege?.sources, [plist.path])
        XCTAssertEqual(uncertain.priority?.level, .review)
        let elevated = try assess([evidence])
        XCTAssertEqual(elevated.priority?.level, .high)
        XCTAssertTrue(elevated.priority?.reason.contains(evidence.source) == true)
        XCTAssertTrue(elevated.resolution.filter { $0.location != .bundle }.allSatisfy { $0.existence == .notChecked })
        let encoded = try JSONEncoder().encode(elevated)
        XCTAssertEqual(try JSONDecoder().decode(LoadPathRiskReport.Image.self, from: encoded).priority?.level, .high)
        let (protectedFile, protectedBytes, protectedPath) = try input([disableLV: false], root: temporary)
        let protectedImage = try XCTUnwrap(LoadPathRiskAnalyzer().analyze(protectedFile, at: protectedPath,
            bundleRoot: temporary, selectedSliceBytes: protectedBytes, candidateAccessEvidence: [evidence]).images.first)
        XCTAssertEqual(protectedImage.privilege?.kind, .root)
        XCTAssertEqual(protectedImage.priority?.level, .review)
        XCTAssertEqual(protectedImage.findings.first { $0.ruleID == "L2" }?.severity, .low)
        var absent = evidence
        absent.exists = false
        XCTAssertEqual(try assess([absent]).priority?.level, .review)
        var rootWriter = evidence
        rootWriter.writerUserID = 0
        XCTAssertEqual(try assess([rootWriter]).priority?.level, .review)
        try declare("fixture-user")
        XCTAssertEqual(try assess([evidence]).priority?.level, .review)
        try FileManager.default.removeItem(at: plist)
        XCTAssertEqual(try assess([evidence]).privilege?.kind, .unknown)
        XCTAssertEqual(try assess([evidence]).priority?.level, .review)
    }

    func testUniversalBundleReadsEntitlementsFromSelectedSlice() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.copyItem(at: fixture, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = fixture.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("entitlement-risk/library-and-dyld")
        let thin = try Data(contentsOf: source)
        var fat = Data()
        for value in [UInt32(0xcafe_babe), 1, 0x0100_000c, 0, 4096, UInt32(thin.count), 12] {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { fat.append(contentsOf: $0) }
        }
        fat.append(Data(repeating: 0, count: 4096 - fat.count))
        fat.append(thin)
        try fat.write(to: temporary.appendingPathComponent("Contents/MacOS/RiskFixture"))
        let report = try LoadPathRiskAnalyzer().analyze(bundleURL: temporary)
        XCTAssertEqual(report.images.first { $0.role == .mainExecutable }?.entitlementState, "parsed")
    }
}
