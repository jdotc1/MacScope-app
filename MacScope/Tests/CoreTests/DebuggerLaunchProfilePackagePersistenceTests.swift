import Foundation
import XCTest
@testable import MacScope

final class DebuggerLaunchProfilePackagePersistenceTests: XCTestCase {
    func testAbsentPackageBlobRestoresPristineAvailableCatalog() throws {
        let analysis = try WorkspacePackageAnalysis.decodeStrictPackageJSON(from: Data("{}".utf8))
        let second = try WorkspacePackageAnalysis.decodeStrictPackageJSON(from: Data("{}".utf8))

        XCTAssertTrue(analysis.launchProfileCatalog.isPristine)
        XCTAssertEqual(analysis.launchProfileCatalogAvailability, .available)
        XCTAssertEqual(analysis.launchProfileCatalog, second.launchProfileCatalog)
        XCTAssertFalse(analysis.hasAuthoringPayload)
        let encoded = try JSONEncoder().encode(analysis)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["launchProfileCatalog"])
    }

    func testEmptyRevisionTombstonePersistsAsTheExactCanonicalBase64Blob() throws {
        let tombstone = try DebuggerLaunchProfileCatalog(
            catalogID: UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!,
            revision: 2,
            profiles: [],
            selectedProfileID: nil
        )
        let analysis = WorkspacePackageAnalysis(launchProfileCatalog: tombstone)

        let encoded = try JSONEncoder().encode(analysis)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            object["launchProfileCatalog"] as? String,
            try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(tombstone).base64EncodedString()
        )

        let decoded = try WorkspacePackageAnalysis.decodeStrictPackageJSON(from: encoded)
        XCTAssertEqual(decoded.launchProfileCatalog, tombstone)
        XCTAssertEqual(decoded.launchProfileCatalogAvailability, .available)
    }

    func testMalformedNoncanonicalAndDuplicatePackageBlobsFailWholeCatalogClosed() throws {
        let canonical = try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(
            .freshPristine(
                catalogID: UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
            )
        )
        let pretty = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: canonical),
            options: [.prettyPrinted, .sortedKeys]
        )
        let cases = [
            #"{"launchProfileCatalog":"%%%"}"#,
            "{\"launchProfileCatalog\":\"\(pretty.base64EncodedString())\"}",
            "{\"launchProfileCatalog\":\"\(canonical.base64EncodedString())\","
                + "\"launchProfileCatalog\":\"\(canonical.base64EncodedString())\"}",
            "{\"launchProfileCatalog\":\"\(canonical.base64EncodedString())\","
                + "\"launchProfileC\\u0061talog\":\"\(canonical.base64EncodedString())\"}",
        ]

        for payload in cases {
            let decoded = try WorkspacePackageAnalysis.decodeStrictPackageJSON(
                from: Data(payload.utf8)
            )
            XCTAssertTrue(decoded.launchProfileCatalog.isPristine, payload)
            XCTAssertEqual(decoded.launchProfileCatalogAvailability, .unavailable, payload)
            XCTAssertEqual(decoded.logicalBreakpointCatalogAvailability, .available, payload)
        }
    }

    func testDuplicateLogicalCatalogDoesNotInvalidateLaunchCatalog() throws {
        let payload = #"{"logicalBreakpointCatalog":null,"logicalBreakpointCatalog":null}"#
        let decoded = try WorkspacePackageAnalysis.decodeStrictPackageJSON(
            from: Data(payload.utf8)
        )

        XCTAssertEqual(decoded.logicalBreakpointCatalogAvailability, .unavailable)
        XCTAssertEqual(decoded.launchProfileCatalogAvailability, .available)
        XCTAssertTrue(decoded.launchProfileCatalog.isPristine)
    }

    func testEscapedDuplicateDeepInsideLogicalCatalogInvalidatesLogicalOnly() throws {
        let payload = #"{"logicalBreakpointCatalog":{"nested":{"value":1,"v\u0061lue":1}}}"#
        let decoded = try WorkspacePackageAnalysis.decodeStrictPackageJSON(
            from: Data(payload.utf8)
        )

        XCTAssertEqual(decoded.logicalBreakpointCatalogAvailability, .unavailable)
        XCTAssertEqual(decoded.launchProfileCatalogAvailability, .available)
    }

    func testUnavailableCatalogBlocksPackageEncodingWithoutWeakeningLogicalCatalog() throws {
        let analysis = WorkspacePackageAnalysis(
            launchProfileCatalogAvailability: .unavailable
        )

        XCTAssertEqual(analysis.logicalBreakpointCatalogAvailability, .available)
        XCTAssertThrowsError(try JSONEncoder().encode(analysis)) { error in
            XCTAssertEqual(
                error as? DebuggerLaunchProfileCatalogPersistenceError,
                .unavailable
            )
        }
    }

    func testPackageRejectsCatalogRevisionBeyondSQLiteIntegerAuthority() throws {
        let canonical = try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(
            .freshPristine(
                catalogID: UUID(uuidString: "A0000000-0000-4000-8000-000000000007")!
            )
        )
        let oversizedRevision = try XCTUnwrap(
            String(data: canonical, encoding: .utf8)?
                .replacingOccurrences(
                    of: #""revision":1"#,
                    with: #""revision":9223372036854775808"#
                )
        )
        let payload = "{\"launchProfileCatalog\":\"\(Data(oversizedRevision.utf8).base64EncodedString())\"}"

        let decoded = try WorkspacePackageAnalysis.decodeStrictPackageJSON(
            from: Data(payload.utf8)
        )
        XCTAssertEqual(decoded.launchProfileCatalogAvailability, .unavailable)
    }

    func testPristinePackageManifestRoundTripUsesStableCompatibilityCoordinate() throws {
        var original = manifest()
        let logicalTombstone = try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(uuidString: "A0000000-0000-4000-8000-000000000008")!,
            revision: 2,
            specifications: []
        )
        original.analysis = WorkspacePackageAnalysis(
            logicalBreakpointCatalog: logicalTombstone
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkspacePackageManifest.self, from: data)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let analysis = try XCTUnwrap(object["analysis"] as? [String: Any])

        XCTAssertEqual(decoded, original)
        XCTAssertNil(analysis["launchProfileCatalog"])
        XCTAssertEqual(
            decoded.analysis?.launchProfileCatalog,
            original.analysis?.launchProfileCatalog
        )
    }

    func testDuplicateManifestAnalysisAncestorInvalidatesLaunchCatalog() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let payload = """
        {
          "formatIdentifier":"\(MacScopeDocumentPackage.formatIdentifier)",
          "formatVersion":1,
          "documentID":"A0000000-0000-4000-8000-000000000005",
          "workspaceUUID":"A0000000-0000-4000-8000-000000000006",
          "workspaceName":"Launch Profiles",
          "createdAt":"1970-01-01T00:00:01Z",
          "modifiedAt":"1970-01-01T00:00:01Z",
          "binaries":[],
          "analysis":{},
          "analysis":{},
          "session":null
        }
        """
        try Data(payload.utf8).write(
            to: MacScopeDocumentPackage.manifestURL(in: packageURL)
        )

        let decoded = try MacScopeDocumentPackage.readManifest(from: packageURL)
        XCTAssertEqual(
            decoded.analysis?.launchProfileCatalogAvailability,
            .unavailable
        )
        XCTAssertEqual(
            decoded.analysis?.logicalBreakpointCatalogAvailability,
            .unavailable
        )
    }

    func testSnapshotAndPackageContentsCarryLaunchCatalogAuthority() throws {
        let snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        XCTAssertTrue(snapshot.launchProfileCatalog.isPristine)

        let contents = WorkspacePackageContents(
            manifest: manifest(),
            snapshot: snapshot,
            attachmentsByBinaryID: [:],
            session: nil,
            launchProfileCatalogAvailability: .unavailable
        )
        XCTAssertEqual(contents.launchProfileCatalogAvailability, .unavailable)
    }

    private func manifest() -> WorkspacePackageManifest {
        WorkspacePackageManifest(
            documentID: UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!,
            workspaceUUID: UUID(uuidString: "A0000000-0000-4000-8000-000000000004")!,
            workspaceName: "Launch Profiles",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1),
            binaries: [],
            session: nil
        )
    }
}
