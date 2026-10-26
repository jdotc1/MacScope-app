import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class REAUIResourceProjectionTests: XCTestCase {
    private let target = "110f46b5b35c069160560c6ad6786f647dd44e8760a52a46fc22dbbcd7630b91"
    private let snapshot = "selected-snapshot"

    private func image() -> LoadedBinary {
        let bytes = Data([0x99, 0xc0, 0x03, 0x5f, 0xd6, 0x88])
        return LoadedBinary(name: "selected-image", path: "/not/reopened", isBundle: true,
                            cpuType: MachOConstants.cpuTypeARM64, fileTypeName: "Mach-O executable", architectureDisplayName: "arm64",
                            metadata: .empty, bytes: bytes, sliceOffset: 1, sliceSize: 4,
                            sections: [], executableTextSection: nil, entryPointAddress: nil,
                            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [], functionStarts: [], objcSelectors: [:])
    }
    private func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func capture(target: String? = nil, snapshot: String? = nil, path: String = "Resources/Main.nib", bytes: Data = Data([1, 2, 3])) -> REAUIResourceCapture {
        REAUIResourceCapture(targetSHA256: target ?? self.target, snapshotID: snapshot ?? self.snapshot,
                             relativePath: path, archiveSHA256: hash(bytes), kind: .nib, format: .nibArchive, bytes: bytes)
    }
    private func encode(_ input: REAUIResourceInput) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
    }
    private func build(_ binary: LoadedBinary? = nil, documents: [REAUIResourceCapture] = []) throws -> REAUIResourceInput {
        try REAUIResourceProjection.build(selectedImage: binary ?? image(), snapshotID: snapshot, documents: documents)
    }

    func testHashesOnlyTheSelectedSlice() throws {
        XCTAssertEqual(try REAUIResourceProjection.selectedSliceSHA256(image()), target)
        let input = try build(documents: [capture()])
        XCTAssertEqual(input.targetSHA256, target)
        XCTAssertEqual(input.metadata.targetSHA256, target)
        XCTAssertEqual(input.metadata.snapshotID, snapshot)
    }

    func testActualClassAndCategoryMethodsRetainDuplicateCandidatesAndExactAddresses() throws {
        var binary = image()
        let method = ObjCMethod(selector: "perform:", typeEncoding: nil, isClassMethod: false, implementation: UInt64.max - 15)
        let classMethod = ObjCMethod(selector: "shared", typeEncoding: nil, isClassMethod: true, implementation: 0x1234)
        binary.objcClasses = [ObjCClass(name: "BuildViewController", superclassName: nil, adoptedProtocols: [],
                                       classMethods: [classMethod], instanceMethods: [method, method], ivars: [], properties: [])]
        binary.objcCategories = [ObjCCategory(name: "Extra", className: "BuildViewController", classMethods: [],
                                             instanceMethods: [method], adoptedProtocols: [], properties: [])]
        let implementations = try build(binary).metadata.value.implementations
        XCTAssertEqual(implementations.count, 4)
        XCTAssertEqual(implementations.filter { $0.selector == "perform:" }.count, 3)
        XCTAssertEqual(implementations[0].implementationAddress, "0xfffffffffffffff0")
        XCTAssertEqual(implementations.last?.className, "BuildViewController(Extra)")
        XCTAssertEqual(implementations.last?.category, "Extra")
        XCTAssertEqual(implementations[2].methodType, "class")
        XCTAssertEqual(implementations[0].evidence[0].artifactSHA256, target)
        XCTAssertEqual(try build(binary).metadata.value.coverage[0].status, "partial")
    }

    func testMissingImplementationAndUnknownOffsetsEncodeExplicitNulls() throws {
        var binary = image()
        binary.objcClasses = [ObjCClass(name: "BuildViewController", superclassName: nil, adoptedProtocols: [], classMethods: [],
                                       instanceMethods: [ObjCMethod(selector: "missing:", typeEncoding: nil, isClassMethod: false)], ivars: [], properties: [])]
        let json = try encode(build(binary))
        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        let value = try XCTUnwrap(metadata["value"] as? [String: Any])
        XCTAssertTrue(value["db_save_result"] is NSNull)
        let methods = try XCTUnwrap(value["objc_dispatch_implementations"] as? [[String: Any]])
        XCTAssertTrue(methods[0]["implementation_address"] is NSNull)
        let location = try XCTUnwrap(methods[0]["location"] as? [String: Any])
        XCTAssertTrue(location["address"] is NSNull)
        XCTAssertTrue(location["file_offset"] is NSNull)
    }

    func testWrongImageAndStaleSnapshotRejectBeforeProjection() {
        XCTAssertThrowsError(try build(documents: [capture(target: String(repeating: "a", count: 64))])) { error in
            XCTAssertEqual(error as? REAUIResourceProjection.Failure, .wrongImageOrSnapshot)
        }
        XCTAssertThrowsError(try build(documents: [capture(snapshot: "stale")]))
    }

    func testCapturedBytesMustMatchCommittedDigest() {
        let forged = REAUIResourceCapture(targetSHA256: target, snapshotID: snapshot, relativePath: "Main.nib",
                                          archiveSHA256: String(repeating: "0", count: 64), kind: .nib, format: .nibArchive, bytes: Data([1]))
        XCTAssertThrowsError(try build(documents: [forged])) { error in
            XCTAssertEqual(error as? REAUIResourceProjection.Failure, .invalidCaptureHash)
        }
    }

    func testPathsAndDuplicateArchivesReject() {
        for path in ["../Main.nib", "/Main.nib", "Resources//Main.nib", "Resources/./Main.nib", "Resources\\Main.nib"] {
            XCTAssertThrowsError(try build(documents: [capture(path: path)]))
        }
        XCTAssertThrowsError(try build(documents: [capture(), capture()])) { error in
            XCTAssertEqual(error as? REAUIResourceProjection.Failure, .duplicatePath)
        }
    }

    func testOmissionAndCatalogUnavailabilityRemainExplicit() throws {
        let input = try REAUIResourceProjection.build(selectedImage: image(), snapshotID: snapshot, documents: [], omittedDocuments: 3)
        XCTAssertEqual(input.omittedDocuments, 3)
        XCTAssertNil(input.assetCatalogs)
        XCTAssertNil(try encode(input)["assetCatalogs"])
        XCTAssertEqual(input.metadata.value.coverage[0].reason, "loader_metadata_projection_not_exhaustive")
    }

    func testCatalogBindingAndMetadataBytesArePreservedAndVerified() throws {
        let bytes = Data("[{\"Name\":\"BuildIcon\"}]".utf8)
        let catalog = REAUIAssetCatalogCapture(targetSHA256: target, snapshotID: snapshot, path: "Resources/Assets.car",
                                              catalogSHA256: String(repeating: "b", count: 64), captureID: "producer-capture",
                                              toolSHA256: String(repeating: "c", count: 64), metadataSHA256: hash(bytes), metadataBytes: bytes)
        let input = try REAUIResourceProjection.build(selectedImage: image(), snapshotID: snapshot, documents: [], catalogs: [catalog])
        XCTAssertEqual(input.assetCatalogs?.first?.metadataJSONBase64, bytes.base64EncodedString())
        XCTAssertEqual(input.assetCatalogs?.first?.captureID, "producer-capture")
        let forged = REAUIAssetCatalogCapture(targetSHA256: target, snapshotID: snapshot, path: catalog.path,
                                             catalogSHA256: catalog.catalogSHA256, captureID: catalog.captureID,
                                             toolSHA256: catalog.toolSHA256, metadataSHA256: hash(Data([0])), metadataBytes: bytes)
        XCTAssertThrowsError(try REAUIResourceProjection.build(selectedImage: image(), snapshotID: snapshot, documents: [], catalogs: [forged]))
    }

    func testContradictoryAndOutOfBoundsSlicesReject() {
        var binary = image()
        binary.artifactIntegrityState = .contradictoryEvidence(diagnostic: "retained conflict")
        XCTAssertThrowsError(try build(binary))
        binary = image(); binary.sliceOffset = UInt64.max
        XCTAssertThrowsError(try build(binary))
        binary = image(); binary.sliceSize = 6
        XCTAssertThrowsError(try build(binary))
    }

    func testMatchingLoaderIdentityIsRecheckedAgainstActualSelectedBytes() throws {
        var binary = image()
        binary.artifactIdentity = try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: binary.cpuType, rawCPUSubtype: 0,
                                                                selectedSliceSHA256: String(repeating: "a", count: 64), selectedSliceByteCount: 4)
        XCTAssertThrowsError(try build(binary)) { error in
            XCTAssertEqual(error as? REAUIResourceProjection.Failure, .contradictoryImage)
        }
    }

    func testCapturedByteBudgetRejectsBeforeBase64Expansion() {
        XCTAssertThrowsError(try build(documents: [capture(bytes: Data(repeating: 0, count: 8 * 1024 * 1024 + 1))])) { error in
            XCTAssertEqual(error as? REAUIResourceProjection.Failure, .budgetExceeded)
        }
    }

    func testKeyedCaptureIsExplicitlyDecodedJSONAndNotBinaryPlist() throws {
        let bytes = Data("{\"$archiver\":\"NSKeyedArchiver\"}".utf8)
        let document = REAUIResourceCapture(targetSHA256: target, snapshotID: snapshot, relativePath: "Main.nib",
                                            archiveSHA256: hash(bytes), kind: .storyboard_scene, format: .keyedArchiveJSON, bytes: bytes)
        XCTAssertEqual(try build(documents: [document]).documents[0].format, .keyedArchiveJSON)
    }
    func testLargeMethodInventoryBecomesBoundedPartialInputThroughRealKernel() throws {
        var binary = image()
        let method = ObjCMethod(selector: "perform:", typeEncoding: nil, isClassMethod: false, implementation: 0x1234)
        binary.objcClasses = [ObjCClass(name: "Controller", superclassName: nil, adoptedProtocols: [],
            classMethods: [], instanceMethods: Array(repeating: method, count: 14_000), ivars: [], properties: [])]
        let input = try REAUIResourceProjection.build(selectedImage: binary, snapshotID: snapshot,
            documents: [], omittedCatalogs: 7)
        XCTAssertEqual(input.metadata.value.implementations.count, 8_000)
        let omitted = try XCTUnwrap(input.metadata.value.coverage.first { $0.facet == "objc_dispatch_projection_budget" })
        XCTAssertEqual(omitted.examined, 6_000)
        XCTAssertEqual(omitted.decoded, 0)
        XCTAssertEqual(omitted.status, "partial")
        struct Request: Encodable {
            let schemaVersion = 1
            let requestID: String
            let operation = "uiResources"
            let input: REAUIResourceInput
        }
        let id = UUID()
        let request = try REAInspectionWireCodec.canonicalRequest(
            Request(requestID: id.uuidString, input: input), requestID: id)
        var root = TestSourceRoot.fileURL(#filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let host = REAJavaScriptHost(resourceURL: root.appendingPathComponent("ThirdParty/REA/generated/MacScopeREAKernel.js"),
            expectedSHA256: REAEmbeddedIdentity.resourceSHA256,
            implementationIdentity: REAEmbeddedIdentity.implementationIdentity)
        let completed = expectation(description: "Swift UI request accepted by actual verified kernel")
        host.execute(requestData: request, requestID: id,
            control: .init(deadline: Date().addingTimeInterval(25), maximumResidentBytes: Int64.max)) { result in
            defer { completed.fulfill() }
            do {
                let bytes = try result.get()
                try REAInspectionWireCodec.validateResponse(bytes, requestID: id, operation: .uiResources,
                    implementationIdentity: REAEmbeddedIdentity.implementationIdentity)
                let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                XCTAssertEqual(envelope["ok"] as? Bool, true, String(describing: envelope["error"]))
                let response = try XCTUnwrap(envelope["result"] as? [String: Any])
                let coverage = try XCTUnwrap(response["coverage"] as? [[String: Any]])
                let methodCoverage = try XCTUnwrap(coverage.first { $0["facet"] as? String == "metadata:objc_dispatch_projection_budget" })
                XCTAssertEqual(methodCoverage["omitted"] as? Int, 6_000)
                let catalogCoverage = try XCTUnwrap(coverage.first { $0["facet"] as? String == "asset_catalog_inventory" })
                XCTAssertEqual(catalogCoverage["omitted"] as? Int, 7)
            } catch { XCTFail("Verified kernel rejected bounded Swift UI request: \(error)") }
        }
        wait(for: [completed], timeout: 30)
    }
}
