import Foundation
import XCTest
@testable import MacScope

final class WorkspacePackageValidationHardeningTests: XCTestCase {
    func testOpenRejectsAttachmentChangedAfterInitialValidationBeforeFinalConsumption() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let binary = try XCTUnwrap(fixture.manifest.binaries.first)
        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: fixture.packageURL,
            relativePath: binary.attachmentRelativePath
        )
        let replacementBytes = Data([0xf0, 0xf1, 0xf2])
        var didReplaceAttachment = false

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.openPackage(
                from: fixture.packageURL,
                testHooks: .init(afterInitialAttachmentValidation: {
                    didReplaceAttachment = true
                    try replacementBytes.write(to: attachmentURL, options: [.atomic])
                })
            )
        ) { error in
            guard let packageError = error as? MacScopeDocumentPackage.PackageError,
                  case let .attachmentHashMismatch(
                path,
                expected,
                actual
            ) = packageError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, binary.attachmentRelativePath)
            XCTAssertEqual(expected, binary.fileHash)
            XCTAssertNotEqual(actual, expected)
        }
        XCTAssertTrue(didReplaceAttachment)
    }

    func testManifestDecodeRejectsDuplicateAnalysisAncestorWithConflictingLogicalCatalogStates() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mscope")
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let catalogAnalysis = WorkspacePackageAnalysis(
            logicalBreakpointCatalog: try logicalCatalogWithExpressionAction()
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            workspaceUUID: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            workspaceName: "Duplicate analysis ancestor",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2),
            binaries: [],
            analysis: catalogAnalysis,
            imageAnalyses: nil,
            session: nil
        )
        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)

        let manifestURL = MacScopeDocumentPackage.manifestURL(in: packageURL)
        let canonicalData = try Data(contentsOf: manifestURL)
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData) as? [String: Any]
        )
        let catalogAnalysisObject = try XCTUnwrap(manifestObject.removeValue(forKey: "analysis"))
        let pristineAnalysisObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WorkspacePackageAnalysis())
        )
        let ancestorData = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys]
        )
        let ancestorJSON = try XCTUnwrap(String(data: ancestorData, encoding: .utf8))
        let catalogJSON = try jsonString(for: catalogAnalysisObject)
        let pristineJSON = try jsonString(for: pristineAnalysisObject)

        for (first, second) in [
            (catalogJSON, pristineJSON),
            (pristineJSON, catalogJSON),
            (catalogJSON, "null"),
            ("null", catalogJSON),
        ] {
            let hostile = try XCTUnwrap(ancestorJSON.dropLast().isEmpty ? nil : String(ancestorJSON.dropLast()))
                + ",\"analysis\":\(first),\"\\u0061nalysis\":\(second)}"
            try Data(hostile.utf8).write(to: manifestURL, options: .atomic)

            let decoded = try MacScopeDocumentPackage.readManifest(from: packageURL)
            XCTAssertEqual(
                decoded.analysis?.logicalBreakpointCatalogAvailability,
                .unavailable
            )
            XCTAssertTrue(decoded.analysis?.logicalBreakpointCatalog.specifications.isEmpty == true)
        }
    }

    func testStrictPackageDecodeRejectsEscapedDuplicateKeyDeepInsideLogicalCatalog() throws {
        let catalog = try logicalCatalogWithExpressionAction()
        let encoded = try JSONEncoder().encode(
            WorkspacePackageAnalysis(logicalBreakpointCatalog: catalog)
        )
        let canonical = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let originalMember = "\"label\":\"capture\""
        let duplicatedMember = "\"label\":\"capture\",\"\\u006cabel\":\"capture\""
        let hostile = canonical.replacingOccurrences(
            of: originalMember,
            with: duplicatedMember
        )
        XCTAssertNotEqual(hostile, canonical, "fixture must inject an escaped duplicate key")

        let decoded = try WorkspacePackageAnalysis.decodeStrictPackageJSON(
            from: Data(hostile.utf8)
        )

        XCTAssertEqual(decoded.logicalBreakpointCatalogAvailability, .unavailable)
        XCTAssertTrue(decoded.logicalBreakpointCatalog.specifications.isEmpty)
    }

    func testVersion2TopLevelSourceLinesAreRejectedAsDerivedPayload() throws {
        let analysis = WorkspacePackageAnalysis(
            sourceLines: [
                SourceLineEntry(
                    address: 0x1_0000_1000,
                    file: "/tmp/main.swift",
                    line: 7,
                    column: 3,
                    endSequence: false
                ),
            ]
        )
        XCTAssertTrue(analysis.hasDerivedPayload)
        let manifest = WorkspacePackageManifest(
            formatVersion: WorkspacePackageManifest.multiImageFormatVersion,
            documentID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            workspaceUUID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            workspaceName: "Source-line ownership",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2),
            binaries: [],
            analysis: analysis,
            imageAnalyses: [],
            session: nil
        )

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validateManifest(
                manifest,
                in: FileManager.default.temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .version2TopLevelAnalysisContainsDerivedData
            )
        }
    }

    func testVersion3AppliesVersion2PerImageAnalysisOwnershipRules() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        var manifest = try MacScopeDocumentPackage.preparedManifest(
            fixture.manifest,
            reconstructionState: fixture.state
        )
        manifest.analysis = WorkspacePackageAnalysis(
            sourceLines: [
                SourceLineEntry(
                    address: 0x1_0000_1000,
                    file: "/tmp/hostile.swift",
                    line: 9,
                    column: 1,
                    endSequence: false
                ),
            ]
        )

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validateManifest(
                manifest,
                in: FileManager.default.temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .version2TopLevelAnalysisContainsDerivedData
            )
        }
    }

    /// Lane AG: the byte-level preflight keeps the duplicate-key semantics of the former
    /// Foundation-object scan — repeats are found at every depth, by decoded key bytes (escaped
    /// spellings collide with plain ones), in small and large (> 24 key) objects alike.
    func testDuplicateKeyPreflightRejectsRepeatsAtEveryDepthEscapedAndInLargeObjects() throws {
        func findings(_ json: String) throws -> WorkspacePackageDuplicateKeyFindings {
            try WorkspacePackageDuplicateKeyPreflight.findings(in: Data(json.utf8))
        }
        XCTAssertTrue(try findings(#"{"a":1,"a":2}"#).anyObjectMember)
        XCTAssertTrue(try findings(#"{"ab":1,"a\u0062":2}"#).anyObjectMember)
        XCTAssertFalse(try findings(#"{"ab":1,"a\u0063":2}"#).anyObjectMember)
        XCTAssertTrue(try findings(#"{"x":[{"k":1},{"k":2,"q":{"z":1,"z":1}}]}"#).anyObjectMember)
        XCTAssertFalse(try findings(#"{"x":[{"k":1},{"k":2,"q":{"z":1,"y":1}}],"k":{}}"#).anyObjectMember)
        XCTAssertTrue(try findings(#"{"analysis":{},"analysis":null}"#).analysisAncestor)
        XCTAssertFalse(try findings(#"{"x":{"analysis":{},"analysis":{}}}"#).analysisAncestor)
        XCTAssertTrue(try findings(
            #"{"analysis":{"logicalBreakpointCatalog":{"s":[{"b":1,"b":2}]}}}"#
        ).logicalBreakpointCatalog)
        XCTAssertTrue(try findings(
            #"{"analysis":{"launchProfileCatalog":"a","launchProfileCatalog":"b"}}"#
        ).launchProfileCatalog)
        XCTAssertTrue(try findings(
            #"{"analysis":{"savedWatchCatalog":"a","savedW\u0061tchCatalog":"b"}}"#
        ).savedWatchCatalog)

        let large = "{" + (0..<100).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        XCTAssertFalse(try findings(large + "}").anyObjectMember)
        XCTAssertTrue(try findings(large + #","k7":1}"#).anyObjectMember)
        XCTAssertTrue(try findings(large + #","k\u0037":1}"#).anyObjectMember)
        XCTAssertTrue(try findings(#"{"k7":0,"# + String(large.dropFirst()) + "}").anyObjectMember)
    }

    /// The preflight replaces the full JSONSerialization parse the manifest decoder used to run,
    /// so it must stay a strict RFC 8259 check: JSONDecoder alone accepts a malformed value under
    /// a key it ignores.
    func testDuplicateKeyPreflightIsAStrictJSONGrammarCheck() throws {
        for malformed in [
            #"{"a":01}"#, #"{"a":1.}"#, #"{"a":1e}"#, #"{"a":-}"#, #"{"a":tru}"#, #"{"a":NaN}"#,
            #"{"a":"\q"}"#, #"{"a":"\ud800"}"#, #"{"a":"\udc00x"}"#, "{\"a\":\"\u{01}\"}",
            #"{"a":1,}"#, #"{"a" 1}"#, #"{"a":1} x"#, "", " ",
        ] {
            XCTAssertThrowsError(
                try WorkspacePackageDuplicateKeyPreflight.findings(in: Data(malformed.utf8)),
                malformed
            )
        }
        var invalidUTF8 = Data(#"{"ignored":"x"#.utf8)
        invalidUTF8.append(0xC3)
        invalidUTF8.append(contentsOf: Data(#""}"#.utf8))
        XCTAssertThrowsError(try WorkspacePackageDuplicateKeyPreflight.findings(in: invalidUTF8))
        for wellFormed in [
            #"{"a":"\ud83d\ude00","b":[true,false,null,-0.5e+10,0,12.25E-3],"c":"é\n\"\\\/"}"#,
            "{}", "[]", " { } ",
        ] {
            XCTAssertNoThrow(
                try WorkspacePackageDuplicateKeyPreflight.findings(in: Data(wellFormed.utf8)),
                wellFormed
            )
        }
        let summary = try XCTUnwrap(WorkspacePackageDuplicateKeyPreflight.scan(Data(
            #"{"formatVersion" : 3 , "session": null, "x": {"formatVersion": 1}}"#.utf8
        )).root)
        XCTAssertEqual(summary.keys, ["formatVersion", "session", "x"])
        XCTAssertEqual(summary.nullValuedKeys, ["session"])
        XCTAssertEqual(summary.formatVersionTokens, [Data("3".utf8)])

        // End to end: a manifest JSONDecoder would accept (bad number under an unknown key) is
        // still refused by the package decoder.
        let manifest = WorkspacePackageManifest(
            documentID: UUID(), workspaceUUID: UUID(), workspaceName: "Strict grammar",
            createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 2),
            binaries: [], analysis: nil, imageAnalyses: nil, session: nil
        )
        let canonical = try MacScopeDocumentPackage.encodedManifest(manifest)
        XCTAssertNoThrow(try MacScopeDocumentPackage.validatedManifest(manifestData: canonical))
        var hostile = canonical
        hostile.removeLast(hostile.last == 0x0A ? 2 : 1)
        hostile.append(contentsOf: Data(#","ignoredMember":1.}"#.utf8))
        XCTAssertThrowsError(try MacScopeDocumentPackage.validatedManifest(manifestData: hostile))
    }

    /// The decode-once scope returns a cached manifest only for byte-identical input: a changed
    /// buffer inside the same scope is decoded and validated afresh (and still rejected).
    func testManifestDecodeScopeReusesOnlyByteIdenticalManifests() throws {
        let manifest = WorkspacePackageManifest(
            documentID: UUID(), workspaceUUID: UUID(), workspaceName: "Decode once",
            createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 2),
            binaries: [], analysis: nil, imageAnalyses: nil, session: nil
        )
        let canonical = try MacScopeDocumentPackage.encodedManifest(manifest)
        var duplicated = canonical
        duplicated.removeLast(duplicated.last == 0x0A ? 2 : 1)
        duplicated.append(contentsOf: Data(#","workspaceName":"Other"}"#.utf8))
        let scope = WorkspaceManifestDecodeScope()
        try WorkspaceManifestDecodeScope.$current.withValue(scope) {
            XCTAssertNil(scope.manifest(for: canonical))
            let first = try MacScopeDocumentPackage.validatedManifest(manifestData: canonical)
            XCTAssertEqual(scope.manifest(for: canonical)?.documentID, first.documentID)
            let again = try MacScopeDocumentPackage.validatedManifest(manifestData: canonical)
            XCTAssertEqual(again.documentID, manifest.documentID)
            XCTAssertEqual(
                try MacScopeDocumentPackage.canonicalEncodedManifest(again, decodedFrom: canonical),
                canonical
            )
            XCTAssertNil(scope.manifest(for: duplicated))
            let reparsed = try WorkspacePackageDuplicateKeyPreflight.findings(in: duplicated)
            XCTAssertTrue(reparsed.anyObjectMember)
        }
        XCTAssertNil(WorkspaceManifestDecodeScope.current)
    }

    private func logicalCatalogWithExpressionAction() throws -> DebuggerLogicalBreakpointCatalog {
        let revision = try DebuggerLogicalBreakpointRevision(validating: 2)
        let specification = try DebuggerLogicalBreakpointSpecification(
            id: DebuggerLogicalBreakpointID(
                rawValue: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
            ),
            revision: revision,
            enabled: true,
            target: .preferredAddress(
                owner: DebuggerWorkspaceImageOwnerSeal(
                    slot: .primary,
                    binaryID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
                    artifactIdentity: nil
                ),
                preferredVA: 0x1_0000_1000
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [
                .evaluateTargetExpression(
                    try DebuggerBreakpointExpressionCapture(
                        label: "capture",
                        expression: "$x0"
                    )
                ),
            ],
            disposition: .stop
        )
        return try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            revision: revision.rawValue,
            specifications: [specification]
        )
    }

    private func jsonString(for object: Any) throws -> String {
        try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        ))
    }
}
