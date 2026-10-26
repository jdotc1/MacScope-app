import Foundation
import XCTest
@testable import MacScope

final class WorkspaceDocumentSourceBoundaryTests: XCTestCase {
    func testAppAndFeatureSourcesDoNotBypassDocumentAuthority() throws {
        let root = repositoryRoot()
        let sourceURLs = try swiftSources(
            below: [
                root.appendingPathComponent("MacScope/App", isDirectory: true),
                root.appendingPathComponent("MacScope/Features", isDirectory: true),
            ]
        )
        let forbidden = [
            "writeDocumentPackage(to:",
            "openDocumentPackage(at:",
            "restoredPackage(from:",
        ]

        var violations: [String] = []
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for token in forbidden where source.contains(token) {
                violations.append(
                    "\(sourceURL.path.replacingOccurrences(of: root.path + "/", with: "")): \(token)"
                )
            }
        }

        XCTAssertEqual(
            violations,
            [],
            "Production UI must route package I/O through WorkspaceDocumentSession/WorkspaceOpenCoordinator"
        )
    }

    func testEveryDeclaredPackageOpenSourceRoutesThroughCoordinator() throws {
        let source = try trackedSource(
            "MacScope/Features/Workspace/WorkspaceRootView.swift"
        )
        XCTAssertTrue(source.contains("openCoordinator.open("))
        for openSource in [".fileMenu", ".recentMenu", ".finder", ".dragAndDrop", ".automation"] {
            XCTAssertTrue(
                source.contains("source: \(openSource)"),
                "Missing coordinator route for \(openSource)"
            )
        }
    }

    func testAutosavePrefersBoundSessionAndRetainsNamedHeadlessCompatibilityPath() throws {
        let source = try trackedSplitSource("MacScope/Stores/WorkspaceStore.swift")
        guard let start = source.range(of: "func performAutosaveIfNeeded()") else {
            return XCTFail("Missing autosave entry point")
        }
        let suffix = source[start.lowerBound...]
        guard let end = suffix.range(of: "\n    static func bootstrap(") else {
            return XCTFail("Could not bound autosave implementation")
        }
        let implementation = String(suffix[..<end.lowerBound])
        XCTAssertTrue(implementation.contains("WorkspaceDocumentSession"))
        XCTAssertTrue(implementation.contains("autosaveIfNeeded()"))
        XCTAssertTrue(implementation.contains("Headless compatibility"))
        XCTAssertEqual(
            implementation.components(separatedBy: "writeDocumentPackage(to:").count - 1,
            1,
            "Only the explicit headless compatibility fallback may call the legacy writer"
        )
    }

    func testEveryCooperatingPackagePublisherCoordinatesBothNamespaceURLs() throws {
        let models = try trackedSplitSource("MacScope/Models/AnalysisModels.swift")
        let documentPublisher = try trackedSource(
            "MacScope/Services/Documents/WorkspaceDocumentPublisher.swift"
        )
        let openCoordinator = try trackedSource(
            "MacScope/App/WorkspaceOpenCoordinator.swift"
        )

        XCTAssertTrue(
            models.contains("enum WorkspacePackageNamespaceCoordinator"),
            "The shared two-URL coordination boundary must remain in the common model source"
        )
        let writePackage = boundedImplementation(
            named: "static func writePackage(",
            endingAt: "\n    static func preparedManifest(",
            in: models
        )
        XCTAssertEqual(
            writePackage.components(separatedBy: "defer {").count - 1,
            1,
            "Only the scoped pre-publication partial-write cleanup may remain"
        )
        XCTAssertTrue(
            writePackage.contains(
                "stagedPackageIsComplete = true\n        }\n        try publishStagedPackage("
            ),
            "Partial-write cleanup must leave scope before coordinated publication begins"
        )
        guard let publishStart = writePackage.range(of: "try publishStagedPackage(") else {
            return XCTFail("Missing package publication call")
        }
        XCTAssertFalse(
            writePackage[publishStart.lowerBound...]
                .contains("removeItem(at: temporaryPackageURL)"),
            "No post-publication path cleanup may run outside the coordinated accessor"
        )
        XCTAssertTrue(
            boundedImplementation(
                named: "private static func publishStagedPackage(",
                endingAt: "\n    private static func atomicRename(",
                in: models
            ).contains("WorkspacePackageNamespaceCoordinator.coordinate(")
        )
        XCTAssertTrue(
            boundedImplementation(
                named: "private func coordinatedPublish(",
                endingAt: "\n    private func validateStage(",
                in: documentPublisher
            ).contains("WorkspacePackageNamespaceCoordinator.coordinate(")
        )
        XCTAssertTrue(
            boundedImplementation(
                named: "func beginPhysicalPublication(",
                endingAt: "\n    func completePhysicalPublication(",
                in: openCoordinator
            ).contains("pendingPublications.values.first")
        )
    }

    private func trackedSource(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(path),
            encoding: .utf8
        )
    }

    /// Reads a primary source plus its `<Stem>+<Topic>.swift` extension files in the same
    /// directory, so source-boundary assertions survive mechanical file splits.
    private func trackedSplitSource(_ path: String) throws -> String {
        let primary = repositoryRoot().appendingPathComponent(path)
        let directory = primary.deletingLastPathComponent()
        let prefix = primary.deletingPathExtension().lastPathComponent + "+"
        let extensions = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".swift") }
            .sorted()
        return try ([primary] + extensions.map { directory.appendingPathComponent($0) })
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func boundedImplementation(
        named startToken: String,
        endingAt endToken: String,
        in source: String
    ) -> String {
        guard let start = source.range(of: startToken) else {
            XCTFail("Missing source boundary: \(startToken)")
            return ""
        }
        let suffix = source[start.lowerBound...]
        guard let end = suffix.range(of: endToken) else {
            XCTFail("Missing source boundary: \(endToken)")
            return ""
        }
        return String(suffix[..<end.lowerBound])
    }

    private func swiftSources(below roots: [URL]) throws -> [URL] {
        try roots.flatMap { root in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw WorkspaceDocumentSessionError.operationFailed(
                    "document-source-boundary-enumeration-failed"
                )
            }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
                return url
            }
        }
    }

    private func repositoryRoot() -> URL {
        var root = TestSourceRoot.fileURL(#filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root
    }
}
