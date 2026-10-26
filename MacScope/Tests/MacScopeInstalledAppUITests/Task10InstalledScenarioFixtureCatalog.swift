import CryptoKit
import Foundation
import XCTest

struct Task10InstalledScenarioFixtureCatalog {
    struct ProviderOracle: Decodable, Equatable {
        let displayName: String
        let instanceID: String
        let modelKey: String
        let publisher: String
    }

    private struct ScenarioOracle: Decodable {
        let expectedCheckpointFreshness: String?
        let expectedCorpusOccurrenceCount: Int
        let expectedCorpusRelationCount: Int
        let expectedCorpusUniqueContentCount: Int
        let expectedCorpusUnresolvedRelationCount: Int
        let expectedCurrentGapOperationID: String?
        let expectedEvidenceCount: Int
        let expectedEvidenceCurrentCount: Int
        let expectedEvidenceHistoricalCount: Int
        let expectedEvidenceStaleCount: Int
        let expectedEvidenceUnavailableCount: Int
        let expectedEditorMode: String
        let expectedFocusedImageName: String
        let expectedFunctionAddress: UInt64?
        let expectedStartingImageName: String?
        let expectedStartingFunctionAddress: UInt64?
        let expectedGapCount: Int
        let expectedJobID: UUID?
        let expectedJobState: String?
        let expectedNavigableEvidenceID: UUID?
        let expectedPauseCause: String?
        let expectedResumeTarget: String?
        let expectedTaskCount: Int
        let forbiddenRawPathCanary: String?
        let forbiddenRawPromptCanary: String?
        let forbiddenRawPseudocodeCanary: String?
        let packageName: String
        let packageTreeSHA256: String
        let scenarioID: String
        let workspaceName: String
    }

    private struct CatalogOracle: Decodable {
        let generator: String
        let provider: ProviderOracle
        let scenarios: [ScenarioOracle]
        let schemaVersion: Int
    }

    struct Fixture {
        let expectedCheckpointFreshness: String?
        let expectedCorpusOccurrenceCount: Int
        let expectedCorpusRelationCount: Int
        let expectedCorpusUniqueContentCount: Int
        let expectedCorpusUnresolvedRelationCount: Int
        let expectedCurrentGapOperationID: String?
        let expectedEvidenceCount: Int
        let expectedEvidenceCurrentCount: Int
        let expectedEvidenceHistoricalCount: Int
        let expectedEvidenceStaleCount: Int
        let expectedEvidenceUnavailableCount: Int
        let expectedEditorMode: String
        let expectedFocusedImageName: String
        let expectedFunctionAddress: UInt64?
        let expectedStartingImageName: String?
        let expectedStartingFunctionAddress: UInt64?
        let expectedGapCount: Int
        let expectedJobID: UUID?
        let expectedJobState: String?
        let expectedNavigableEvidenceID: UUID?
        let expectedPauseCause: String?
        let expectedResumeTarget: String?
        let expectedTaskCount: Int
        let forbiddenRawPathCanary: String?
        let forbiddenRawPromptCanary: String?
        let forbiddenRawPseudocodeCanary: String?
        let packageURL: URL
        let rootURL: URL
        let scenarioID: String
        let workspaceName: String

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    static let requiredScenarioIDs = [
        "active-executing-reads",
        "active-retrieving",
        "checkpoint-stale",
        "navigation-current",
        "navigation-stale",
        "no-job",
        "paused-model-unavailable-awaiting-model",
        "paused-user-retrieving",
        "terminal-completed",
    ]

    let provider: ProviderOracle
    private let catalog: CatalogOracle
    private let bundle: Bundle

    static func load() throws -> Self {
        let bundle = Bundle(for: WS24InstalledAppUITests.self)
        guard let catalogURL = bundle.url(
            forResource: "Task10InstalledScenarios.fixture",
            withExtension: "json"
        ) else {
            throw fixtureError(1, "The installed-scenario oracle sidecar is missing.")
        }
        let catalog = try JSONDecoder().decode(
            CatalogOracle.self,
            from: Data(contentsOf: catalogURL)
        )
        let scenarioIDs = catalog.scenarios.map(\.scenarioID)
        let navigation = catalog.scenarios.first { $0.scenarioID == "navigation-current" }
        guard catalog.schemaVersion == 3,
              catalog.generator == "WorkspaceStore.restoredPackage/writeDocumentPackage",
              scenarioIDs == requiredScenarioIDs,
              scenarioIDs == scenarioIDs.sorted(),
              !catalog.provider.modelKey.isEmpty,
              !catalog.provider.instanceID.isEmpty,
              catalog.scenarios.allSatisfy({ scenario in
                  scenario.packageName == "\(scenario.scenarioID).mscope"
                      && scenario.workspaceName == "Task 10 \(scenario.scenarioID)"
                      && scenario.expectedTaskCount >= 0
                      && scenario.expectedCorpusOccurrenceCount >= 0
                      && scenario.expectedCorpusUniqueContentCount >= 0
                      && scenario.expectedCorpusRelationCount >= 0
                      && scenario.expectedCorpusUnresolvedRelationCount >= 0
                      && scenario.expectedEvidenceCount >= 0
                      && scenario.expectedEvidenceCurrentCount >= 0
                      && scenario.expectedEvidenceHistoricalCount >= 0
                      && scenario.expectedEvidenceStaleCount >= 0
                      && scenario.expectedEvidenceUnavailableCount >= 0
                      && scenario.expectedEditorMode == "Disassembly"
                      && scenario.expectedFocusedImageName == "Installed fixture"
                      && ((scenario.scenarioID == "navigation-current"
                           && scenario.expectedStartingImageName == "Installed starting fixture"
                           && scenario.expectedStartingFunctionAddress != nil
                           && scenario.expectedStartingFunctionAddress
                               != scenario.expectedFunctionAddress)
                          || (scenario.scenarioID != "navigation-current"
                              && scenario.expectedStartingImageName == nil
                              && scenario.expectedStartingFunctionAddress == nil))
                      && scenario.expectedEvidenceCount
                          == scenario.expectedEvidenceCurrentCount
                              + scenario.expectedEvidenceHistoricalCount
                              + scenario.expectedEvidenceStaleCount
                              + scenario.expectedEvidenceUnavailableCount
                      && scenario.expectedGapCount >= 0
                      && [nil, "current", "stale"].contains(
                          scenario.expectedCheckpointFreshness
                      )
                      && scenario.packageTreeSHA256.range(
                          of: "^[0-9a-f]{64}$",
                          options: .regularExpression
                      ) != nil
              }),
              navigation?.expectedCorpusOccurrenceCount == 7,
              navigation?.expectedCorpusUniqueContentCount == 5,
              navigation?.expectedCorpusRelationCount == 3,
              navigation?.expectedCorpusUnresolvedRelationCount == 2,
              navigation?.expectedEvidenceCurrentCount == 4,
              navigation?.expectedEvidenceHistoricalCount == 3,
              navigation?.expectedEvidenceStaleCount == 3,
              navigation?.expectedEvidenceUnavailableCount == 3,
              navigation?.expectedCurrentGapOperationID == "reconstruction.evidence.query",
              navigation?.expectedStartingImageName == "Installed starting fixture",
              navigation?.expectedStartingFunctionAddress != navigation?.expectedFunctionAddress,
              navigation?.forbiddenRawPathCanary == "/fixtures/task10-installed.bin",
              navigation?.forbiddenRawPromptCanary
                  == "MACSCOPE_TASK10_RAW_PROMPT_CANARY_DO_NOT_EXPOSE",
              navigation?.forbiddenRawPseudocodeCanary
                  == "MACSCOPE_TASK10_RAW_PSEUDOCODE_CANARY_DO_NOT_EXPOSE" else {
            throw fixtureError(2, "The installed-scenario oracle is not the closed sorted catalog.")
        }
        return Self(provider: catalog.provider, catalog: catalog, bundle: bundle)
    }

    func copyScenario(_ scenarioID: String) throws -> Fixture {
        guard let oracle = catalog.scenarios.first(where: { $0.scenarioID == scenarioID }) else {
            throw Self.fixtureError(3, "Unknown installed-scenario ID: \(scenarioID)")
        }
        guard let bundledRoot = bundle.url(
            forResource: "Task10InstalledScenarios",
            withExtension: nil
        ) else {
            throw Self.fixtureError(1, "The installed-scenario package catalog is missing.")
        }
        let bundledPackage = bundledRoot.appendingPathComponent(
            oracle.packageName,
            isDirectory: true
        )
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-Task10-Installed-\(scenarioID)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )
        let packageURL = temporaryRoot.appendingPathComponent("Scenario.mscope", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: bundledPackage, to: packageURL)
            guard try Self.packageTreeSHA256(at: packageURL) == oracle.packageTreeSHA256 else {
                throw Self.fixtureError(
                    4,
                    "The installed-scenario package does not match the oracle tree digest."
                )
            }
            // The sidecar is keyed by document/workspace identity and bound to this canonical
            // path. Each copy needs a new scope; save/reopen retains this same Fixture instance.
            let manifestURL = packageURL.appendingPathComponent("manifest.json")
            let isolatedManifest = try Task10FixtureDocumentIdentity.isolatedManifest(
                from: Data(contentsOf: manifestURL)
            )
            try isolatedManifest.write(to: manifestURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
        return Fixture(
            expectedCheckpointFreshness: oracle.expectedCheckpointFreshness,
            expectedCorpusOccurrenceCount: oracle.expectedCorpusOccurrenceCount,
            expectedCorpusRelationCount: oracle.expectedCorpusRelationCount,
            expectedCorpusUniqueContentCount: oracle.expectedCorpusUniqueContentCount,
            expectedCorpusUnresolvedRelationCount: oracle.expectedCorpusUnresolvedRelationCount,
            expectedCurrentGapOperationID: oracle.expectedCurrentGapOperationID,
            expectedEvidenceCount: oracle.expectedEvidenceCount,
            expectedEvidenceCurrentCount: oracle.expectedEvidenceCurrentCount,
            expectedEvidenceHistoricalCount: oracle.expectedEvidenceHistoricalCount,
            expectedEvidenceStaleCount: oracle.expectedEvidenceStaleCount,
            expectedEvidenceUnavailableCount: oracle.expectedEvidenceUnavailableCount,
            expectedEditorMode: oracle.expectedEditorMode,
            expectedFocusedImageName: oracle.expectedFocusedImageName,
            expectedFunctionAddress: oracle.expectedFunctionAddress,
            expectedStartingImageName: oracle.expectedStartingImageName,
            expectedStartingFunctionAddress: oracle.expectedStartingFunctionAddress,
            expectedGapCount: oracle.expectedGapCount,
            expectedJobID: oracle.expectedJobID,
            expectedJobState: oracle.expectedJobState,
            expectedNavigableEvidenceID: oracle.expectedNavigableEvidenceID,
            expectedPauseCause: oracle.expectedPauseCause,
            expectedResumeTarget: oracle.expectedResumeTarget,
            expectedTaskCount: oracle.expectedTaskCount,
            forbiddenRawPathCanary: oracle.forbiddenRawPathCanary,
            forbiddenRawPromptCanary: oracle.forbiddenRawPromptCanary,
            forbiddenRawPseudocodeCanary: oracle.forbiddenRawPseudocodeCanary,
            packageURL: packageURL,
            rootURL: temporaryRoot,
            scenarioID: oracle.scenarioID,
            workspaceName: oracle.workspaceName
        )
    }

    private static func packageTreeSHA256(at packageURL: URL) throws -> String {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: packageURL.path).sorted()
        var hasher = SHA256()
        for path in paths {
            let fileURL = packageURL.appendingPathComponent(path)
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: fileURL))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fixtureError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "MacScopeInstalledAppUITests.Task10ScenarioFixture",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
