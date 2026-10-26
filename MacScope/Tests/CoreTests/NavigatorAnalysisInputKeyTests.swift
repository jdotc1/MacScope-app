import Foundation
import XCTest
@testable import MacScope

/// Analysis input key: component sensitivity, and the optional `inputKey` on `AnalysisInputFingerprint`
/// that leaves `overallSHA256` and every facet unchanged.
final class NavigatorAnalysisInputKeyTests: XCTestCase {
    private static let sliceSHA256 = String(repeating: "a", count: 64)

    private static let context = NavigatorInputKeyContext(
        patchOverlayDigest: String(repeating: "1", count: 64),
        analyzerStamp: "analyzer-7",
        knowledgeVersion: String(repeating: "2", count: 64),
        structuralOverridesDigest: String(repeating: "3", count: 64)
    )

    private static func binary() -> BinaryImage {
        let identity = try! MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: sliceSHA256,
            selectedSliceByteCount: 6
        )
        return BinaryImage(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "InputKeyFixture",
            path: "/tmp/InputKeyFixture",
            kind: "Mach-O executable",
            architecture: "arm64",
            selectedSliceIndex: 0,
            artifactIdentity: identity,
            slot: .primary
        )
    }

    private static func analysis() -> ImageAnalysis {
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data([0, 1, 2, 3, 4, 5])
        analysis.hexBytes = Data([0, 1])
        return analysis
    }

    func testInputKeyIsStableLowercaseSHA256() {
        let first = NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: Self.context)
        let second = NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: Self.context)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.utf8.count, 64)
        XCTAssertTrue(AnalysisFacetFingerprint.isLowercaseSHA256(first))
    }

    func testEveryComponentChangesTheKey() {
        let baseline = NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: Self.context)

        var overlay = Self.context
        overlay.patchOverlayDigest = String(repeating: "4", count: 64)
        var stamp = Self.context
        stamp.analyzerStamp = "analyzer-8"
        var knowledge = Self.context
        knowledge.knowledgeVersion = String(repeating: "5", count: 64)
        var overrides = Self.context
        overrides.structuralOverridesDigest = String(repeating: "6", count: 64)

        let variants = [
            NavigatorAnalysisInputKey.inputKey(
                sliceSHA256: String(repeating: "b", count: 64), selectedSliceIndex: 0, context: Self.context),
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 1, context: Self.context),
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: nil, context: Self.context),
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: overlay),
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: stamp),
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: knowledge),
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: overrides),
        ]

        for variant in variants { XCTAssertNotEqual(variant, baseline) }
        XCTAssertEqual(Set(variants).count, variants.count)
    }

    func testComponentsAreLengthPrefixedNotConcatenated() {
        let left = NavigatorInputKeyContext(
            patchOverlayDigest: "ab", analyzerStamp: "c", knowledgeVersion: "k", structuralOverridesDigest: "s")
        let right = NavigatorInputKeyContext(
            patchOverlayDigest: "a", analyzerStamp: "bc", knowledgeVersion: "k", structuralOverridesDigest: "s")

        XCTAssertNotEqual(
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: left),
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: right)
        )
    }

    func testExistingOverloadLeavesInputKeyAbsent() throws {
        let legacy = try AnalysisFingerprintBuilder.fingerprint(binary: Self.binary(), analysis: Self.analysis())
        let explicitNil = try AnalysisFingerprintBuilder.fingerprint(
            binary: Self.binary(), analysis: Self.analysis(), navigatorContext: nil)

        XCTAssertNil(legacy.inputKey)
        XCTAssertEqual(legacy, explicitNil)
    }

    func testContextRecordsInputKeyWithoutChangingOverallDigest() throws {
        let legacy = try AnalysisFingerprintBuilder.fingerprint(binary: Self.binary(), analysis: Self.analysis())
        let keyed = try AnalysisFingerprintBuilder.fingerprint(
            binary: Self.binary(), analysis: Self.analysis(), navigatorContext: Self.context)

        XCTAssertEqual(keyed.overallSHA256, legacy.overallSHA256)
        XCTAssertEqual(keyed.facets, legacy.facets)
        XCTAssertEqual(keyed.imageBytesSHA256, legacy.imageBytesSHA256)
        XCTAssertEqual(
            keyed.inputKey,
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: 0, context: Self.context)
        )
        XCTAssertNotEqual(keyed, legacy)

        let again = try AnalysisFingerprintBuilder.fingerprint(
            binary: Self.binary(), analysis: Self.analysis(), navigatorContext: Self.context)
        XCTAssertEqual(again.inputKey, keyed.inputKey)

        var otherContext = Self.context
        otherContext.analyzerStamp = "analyzer-9"
        let other = try AnalysisFingerprintBuilder.fingerprint(
            binary: Self.binary(), analysis: Self.analysis(), navigatorContext: otherContext)
        XCTAssertNotEqual(other.inputKey, keyed.inputKey)
        XCTAssertEqual(other.overallSHA256, keyed.overallSHA256)
    }

    func testInputKeyFallsBackToImageBytesWithoutArtifactIdentity() throws {
        var binary = Self.binary()
        binary.artifactIdentity = nil
        binary.selectedSliceIndex = nil

        let fingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary, analysis: Self.analysis(), navigatorContext: Self.context)

        XCTAssertEqual(
            fingerprint.inputKey,
            NavigatorAnalysisInputKey.inputKey(
                sliceSHA256: fingerprint.imageBytesSHA256, selectedSliceIndex: nil, context: Self.context)
        )
        XCTAssertNotEqual(
            fingerprint.inputKey,
            NavigatorAnalysisInputKey.inputKey(sliceSHA256: Self.sliceSHA256, selectedSliceIndex: nil, context: Self.context)
        )
    }

    func testInputKeyIsOmittedFromJSONWhenAbsentAndRoundTripsWhenPresent() throws {
        let legacy = try AnalysisFingerprintBuilder.fingerprint(binary: Self.binary(), analysis: Self.analysis())
        let keyed = try AnalysisFingerprintBuilder.fingerprint(
            binary: Self.binary(), analysis: Self.analysis(), navigatorContext: Self.context)

        let legacyData = try JSONEncoder().encode(legacy)
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(legacyObject["inputKey"])
        XCTAssertEqual(try JSONDecoder().decode(AnalysisInputFingerprint.self, from: legacyData), legacy)

        let keyedData = try JSONEncoder().encode(keyed)
        let keyedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: keyedData) as? [String: Any])
        XCTAssertEqual(keyedObject["inputKey"] as? String, keyed.inputKey)
        XCTAssertEqual(try JSONDecoder().decode(AnalysisInputFingerprint.self, from: keyedData), keyed)
    }

    func testMalformedInputKeyIsRejected() {
        XCTAssertThrowsError(
            try AnalysisInputFingerprint(
                imageSlot: .primary,
                binaryID: UUID(),
                binaryName: "bad",
                binaryPath: "/tmp/bad",
                selectedSliceIndex: nil,
                artifactIdentity: nil,
                imageByteCount: 0,
                imageBytesSHA256: String(repeating: "0", count: 64),
                facets: [],
                overallSHA256: String(repeating: "0", count: 64),
                inputKey: String(repeating: "A", count: 64)
            )
        ) { error in
            XCTAssertEqual(error as? AnalysisFingerprintError, .invalidSHA256(field: "inputKey"))
        }
    }
}
