import CryptoKit
import XCTest

/// A product-generated package copied from the UI-test bundle and verified before use.
/// Future installed selectors may mutate only their private temporary copy.
struct Task10InstalledWorkspaceFixture {
    private struct FixtureSidecar: Decodable {
        let generator: String
        let packageTreeSHA256: String
        let schemaVersion: Int
        let workspaceName: String
    }

    let rootURL: URL
    let packageURL: URL
    let workspaceName: String

    static func copyIntoTemporaryDirectory() throws -> Self {
        let bundle = Bundle(for: WS24InstalledAppUITests.self)
        guard let sidecarURL = bundle.url(
            forResource: "Task10PersistedWorkspace.fixture",
            withExtension: "json"
        ) else {
            throw NSError(
                domain: "WS24InstalledAppUITests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The Task 10 fixture integrity sidecar is missing from the UI-test bundle."
                ]
            )
        }
        let sidecar = try JSONDecoder().decode(
            FixtureSidecar.self,
            from: Data(contentsOf: sidecarURL)
        )
        guard sidecar.schemaVersion == 1,
              sidecar.generator == "WorkspaceStore.writeDocumentPackage",
              sidecar.workspaceName == "Task 10 persisted workspace",
              sidecar.packageTreeSHA256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw NSError(
                domain: "WS24InstalledAppUITests",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The Task 10 fixture integrity sidecar has an unexpected schema or provenance claim."
                ]
            )
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacScope-Task10-Installed-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        let packageURL = rootURL.appendingPathComponent("Task10.mscope", isDirectory: true)
        guard let bundledFixtureURL = bundle.url(
            forResource: "Task10PersistedWorkspace",
            withExtension: "mscope"
        ) else {
            throw NSError(
                domain: "WS24InstalledAppUITests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The Task 10 persisted-workspace fixture is missing from the UI-test bundle."
                ]
            )
        }
        try FileManager.default.copyItem(at: bundledFixtureURL, to: packageURL)
        guard try packageTreeSHA256(at: packageURL) == sidecar.packageTreeSHA256 else {
            try? FileManager.default.removeItem(at: rootURL)
            throw NSError(
                domain: "WS24InstalledAppUITests",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The Task 10 fixture package does not match its recorded package-tree SHA-256."
                ]
            )
        }
        return Self(
            rootURL: rootURL,
            packageURL: packageURL,
            workspaceName: sidecar.workspaceName
        )
    }

    private static func packageTreeSHA256(at packageURL: URL) throws -> String {
        let manager = FileManager.default
        let relativePaths = try manager.subpathsOfDirectory(atPath: packageURL.path).sorted()
        var hasher = SHA256()
        for relativePath in relativePaths {
            let fileURL = packageURL.appendingPathComponent(relativePath)
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let bytes = try Data(contentsOf: fileURL)
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: bytes)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
