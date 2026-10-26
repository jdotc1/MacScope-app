import XCTest
@testable import MacScope

final class WorkspacePackageVersion3KeyPolicyTests: XCTestCase {
    func testVersion3OpenRejectsUnknownKeysThroughoutManifestObjectGraph() throws {
        typealias Mutation = (inout [String: Any]) throws -> Void
        let mutations: [(label: String, apply: Mutation)] = [
            ("binary", { manifest in
                var binaries = try XCTUnwrap(manifest["binaries"] as? [[String: Any]])
                binaries[0]["unexpectedBinaryMetadata"] = true
                manifest["binaries"] = binaries
            }),
            ("analysis", { manifest in
                var analysis = try XCTUnwrap(manifest["analysis"] as? [String: Any])
                analysis["unexpectedAnalysisMetadata"] = true
                manifest["analysis"] = analysis
            }),
            ("image-analysis record", { manifest in
                var imageAnalyses = try XCTUnwrap(
                    manifest["imageAnalyses"] as? [[String: Any]]
                )
                imageAnalyses[0]["unexpectedImageAnalysisMetadata"] = true
                manifest["imageAnalyses"] = imageAnalyses
            }),
            ("image-analysis payload", { manifest in
                var imageAnalyses = try XCTUnwrap(
                    manifest["imageAnalyses"] as? [[String: Any]]
                )
                var analysis = try XCTUnwrap(
                    imageAnalyses[0]["analysis"] as? [String: Any]
                )
                analysis["unexpectedImageAnalysisPayloadMetadata"] = true
                imageAnalyses[0]["analysis"] = analysis
                manifest["imageAnalyses"] = imageAnalyses
            }),
            ("session", { manifest in
                manifest["session"] = [
                    "selectedTool": WorkspaceTool.project.rawValue,
                    "editorMode": EditorMode.disassembly.rawValue,
                    "isInspectorPresented": false,
                    "sidebarSearchText": "",
                    "updatedAt": "1970-01-01T00:00:03.000Z",
                    "unexpectedSessionMetadata": true,
                ]
            }),
        ]

        for mutation in mutations {
            let fixture = try ReconstructionPackageFixture.make()
            defer { fixture.remove() }
            try fixture.write()
            let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
            var object = try manifestObject(at: manifestURL)
            try mutation.apply(&object)
            try writeManifestObject(object, to: manifestURL)

            XCTAssertThrowsError(
                try MacScopeDocumentPackage.openPackage(from: fixture.packageURL),
                mutation.label
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionPackageValidationError,
                    .noncanonicalManifest(MacScopeDocumentPackage.manifestFileName),
                    mutation.label
                )
            }
        }
    }

    func testVersion3OpenRejectsMissingWriterRequiredKeysThroughoutManifestObjectGraph() throws {
        typealias Mutation = (inout [String: Any]) throws -> Void
        let mutations: [(label: String, apply: Mutation)] = [
            ("analysis core array", { manifest in
                var analysis = try XCTUnwrap(manifest["analysis"] as? [String: Any])
                XCTAssertNotNil(analysis.removeValue(forKey: "symbols"))
                manifest["analysis"] = analysis
            }),
            ("image-analysis core array", { manifest in
                var imageAnalyses = try XCTUnwrap(
                    manifest["imageAnalyses"] as? [[String: Any]]
                )
                var analysis = try XCTUnwrap(
                    imageAnalyses[0]["analysis"] as? [String: Any]
                )
                XCTAssertNotNil(analysis.removeValue(forKey: "functions"))
                imageAnalyses[0]["analysis"] = analysis
                manifest["imageAnalyses"] = imageAnalyses
            }),
            ("assistant-session authority collection", { manifest in
                XCTAssertNotNil(manifest.removeValue(forKey: "assistantSessionRecords"))
            }),
            ("runtime-authority collection", { manifest in
                XCTAssertNotNil(manifest.removeValue(forKey: "runtimeAuthorityRecords"))
            }),
        ]

        for mutation in mutations {
            let fixture = try ReconstructionPackageFixture.make()
            defer { fixture.remove() }
            try fixture.write()
            let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
            var object = try manifestObject(at: manifestURL)
            try mutation.apply(&object)
            try writeManifestObject(object, to: manifestURL)

            XCTAssertThrowsError(
                try MacScopeDocumentPackage.openPackage(from: fixture.packageURL),
                mutation.label
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionPackageValidationError,
                    .noncanonicalManifest(MacScopeDocumentPackage.manifestFileName),
                    mutation.label
                )
            }
        }
    }

    func testVersion3OpenRejectsNullRequiredRootAuthority() throws {
        typealias Mutation = (inout [String: Any]) -> Void
        let mutations: [(label: String, apply: Mutation)] = [
            ("analysis", { manifest in
                manifest["analysis"] = NSNull()
            }),
            ("assistant-session authority collection", { manifest in
                manifest["assistantSessionRecords"] = NSNull()
            }),
        ]

        for mutation in mutations {
            let fixture = try ReconstructionPackageFixture.make()
            defer { fixture.remove() }
            try fixture.write()
            let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
            var object = try manifestObject(at: manifestURL)
            mutation.apply(&object)
            try writeManifestObject(object, to: manifestURL)

            XCTAssertThrowsError(
                try MacScopeDocumentPackage.openPackage(from: fixture.packageURL),
                mutation.label
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionPackageValidationError,
                    .noncanonicalManifest(MacScopeDocumentPackage.manifestFileName),
                    mutation.label
                )
            }
        }
    }

    func testVersion3OpenRejectsDeletionOfNonemptyImageAnalysisFunctions() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        var manifest = fixture.manifest
        manifest.analysis = WorkspacePackageAnalysis(functions: [
            FunctionSummary(
                id: UUID(),
                name: "required_function",
                startAddress: 0x1_000,
                endAddress: 0x1_004,
                confidence: 1
            ),
        ])
        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            reconstructionState: fixture.state,
            reconstructionAttachmentSources: [fixture.source],
            to: fixture.packageURL
        )

        let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        var object = try manifestObject(at: manifestURL)
        var imageAnalyses = try XCTUnwrap(object["imageAnalyses"] as? [[String: Any]])
        var analysis = try XCTUnwrap(imageAnalyses[0]["analysis"] as? [String: Any])
        let functions = try XCTUnwrap(analysis["functions"] as? [[String: Any]])
        XCTAssertEqual(functions.count, 1)
        analysis.removeValue(forKey: "functions")
        imageAnalyses[0]["analysis"] = analysis
        object["imageAnalyses"] = imageAnalyses
        try writeManifestObject(object, to: manifestURL)

        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)) {
            XCTAssertEqual(
                $0 as? ReconstructionPackageValidationError,
                .noncanonicalManifest(MacScopeDocumentPackage.manifestFileName)
            )
        }
    }

    func testVersion1OpenRetainsUnknownNestedKeyCompatibility() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try MacScopeDocumentPackage.writeManifest(fixture.manifest, to: fixture.packageURL)
        try fixture.binaryBytes.write(to: MacScopeDocumentPackage.attachmentURL(
            in: fixture.packageURL, relativePath: fixture.manifest.binaries[0].attachmentRelativePath
        ))
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        var object = try manifestObject(at: manifestURL)
        try addLegacyUnknownKeys(to: &object, includeImageAnalysis: false)
        try writeManifestObject(object, to: manifestURL)

        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)

        XCTAssertEqual(opened.manifest.formatVersion, WorkspacePackageManifest.currentFormatVersion)
    }

    func testVersion2OpenRetainsUnknownNestedKeyCompatibility() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        var manifest = fixture.manifest
        manifest.formatVersion = WorkspacePackageManifest.multiImageFormatVersion
        manifest.analysis = WorkspacePackageAnalysis()
        manifest.imageAnalyses = [
            WorkspacePackageImageAnalysis(
                binaryID: fixture.binaryID,
                imageSlot: .primary,
                analysis: WorkspacePackageAnalysis()
            ),
        ]
        try MacScopeDocumentPackage.writeManifest(manifest, to: fixture.packageURL)
        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: fixture.packageURL,
            relativePath: try XCTUnwrap(manifest.binaries.first).attachmentRelativePath
        )
        try fixture.binaryBytes.write(to: attachmentURL)
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        var object = try manifestObject(at: manifestURL)
        try addLegacyUnknownKeys(to: &object, includeImageAnalysis: true)
        try writeManifestObject(object, to: manifestURL)

        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)

        XCTAssertEqual(
            opened.manifest.formatVersion,
            WorkspacePackageManifest.multiImageFormatVersion
        )
    }

    private func addLegacyUnknownKeys(
        to manifest: inout [String: Any],
        includeImageAnalysis: Bool
    ) throws {
        var binaries = try XCTUnwrap(manifest["binaries"] as? [[String: Any]])
        binaries[0]["legacyBinaryMetadata"] = true
        manifest["binaries"] = binaries

        var analysis = try XCTUnwrap(manifest["analysis"] as? [String: Any])
        analysis["legacyAnalysisMetadata"] = true
        manifest["analysis"] = analysis

        if includeImageAnalysis {
            var imageAnalyses = try XCTUnwrap(
                manifest["imageAnalyses"] as? [[String: Any]]
            )
            imageAnalyses[0]["legacyImageAnalysisMetadata"] = true
            var imageAnalysis = try XCTUnwrap(
                imageAnalyses[0]["analysis"] as? [String: Any]
            )
            imageAnalysis["legacyImageAnalysisPayloadMetadata"] = true
            imageAnalyses[0]["analysis"] = imageAnalysis
            manifest["imageAnalyses"] = imageAnalyses
        }

        manifest["session"] = [
            "selectedTool": WorkspaceTool.project.rawValue,
            "editorMode": EditorMode.disassembly.rawValue,
            "isInspectorPresented": false,
            "sidebarSearchText": "",
            "updatedAt": "1970-01-01T00:00:03.000Z",
            "legacySessionMetadata": true,
        ]
    }

    private func manifestObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func writeManifestObject(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: [.atomic])
    }
}
