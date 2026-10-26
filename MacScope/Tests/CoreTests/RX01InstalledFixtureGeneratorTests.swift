import Foundation
import XCTest
@testable import MacScope

/// RX-01 §5.6: explicit, opt-in generator for the installed `annotation-transfer` acceptance
/// fixture, following the `Task10InstalledWorkspaceFixtureGeneratorTests` precedent. The package is
/// never hand-authored: the committed clang-built `RX01Versioned` binaries are analyzed through
/// the production engine and `loadAdditionalBinary`, the annotations are authored through the
/// store's override editor, and `WorkspaceStore.writeDocumentPackage` serializes the package.
///
/// Before writing, the test runs the store-level `HeadlessWorkspaceAnnotationTransferAcceptance`
/// on a reopened copy of the package and requires `applied {names: 3, comments: 2, conflicts: 1}`,
/// so the fixture is known-good before the installed run.
///
/// Layout (v1 named → v2 stripped; the matcher pairs exactly three functions at high confidence,
/// see `AnnotationTransferRealBinaryTests.strippedDestinationTable`):
/// - primary (`rx01_v1`): authored names on `parse_header`, `checksum`, `old_name`; authored entry
///   comments on all three;
/// - slot 1 (`rx01_v2_stripped`): one authored entry comment on `new_name` (v1's `old_name`).
///
/// The commit therefore transfers 3 names and 2 comments; `old_name`'s comment meets the authored
/// destination comment and is reported as the one conflict (planner conflicts are per field, so a
/// conflict on the comment keeps the name transfer). The design text says "3 names and 2 entry
/// comments" on the primary; the third source comment is what makes the conflict observable
/// without losing a name, because this fixture has only three high-confidence pairs.
///
/// Skipped unless `MACSCOPE_RX01_FIXTURE_OUTPUT_ROOT` names an absolute output directory. Through
/// `Scripts/dev_loop.sh` (xcodebuild) export it with the `TEST_RUNNER_` prefix:
///
/// ```sh
/// TEST_RUNNER_MACSCOPE_RX01_FIXTURE_OUTPUT_ROOT=$MACSCOPE_WORK_ROOT/MacScopeCIQualificationRuns/tier2-20261012-fixtures \
///   Scripts/dev_loop.sh CoreTests/RX01InstalledFixtureGeneratorTests
/// ```
///
/// The package records the absolute paths of the fixture binaries in the generating checkout;
/// the installed run must use a checkout that still holds them at those paths.
@MainActor
final class RX01InstalledFixtureGeneratorTests: XCTestCase {
    static let outputRootEnvironmentKey = "MACSCOPE_RX01_FIXTURE_OUTPUT_ROOT"
    static let packageName = "RX01TwoVersions.mscope"
    static let sidecarName = "RX01TwoVersions.fixture.json"
    static let workspaceName = "RX01 Two Versions"

    private let newSlot = ImageSlot(rawValue: 1)

    private static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/RX01Versioned", isDirectory: true)

    /// Source function → (authored name, authored entry comment) on the primary image.
    static let primaryAnnotations: [(function: String, name: String, comment: String)] = [
        ("parse_header", "rx01_parse_header", "validates the 0x7f magic, then sums the payload"),
        ("checksum", "rx01_checksum", "djb-style rolling checksum"),
        ("old_name", "rx01_abs_product_mod", "|left * right| mod 1009"),
    ]
    /// Authored entry comment on slot 1's `new_name` (v1 `old_name`): the one conflict.
    static let destinationConflictFunction = "new_name"
    static let destinationConflictComment = "authored in v2 before the transfer"

    // MARK: - Generator

    func testOptInGeneratesRX01TwoVersionsPackageThroughProductionPersistence() async throws {
        guard let rawRoot = ProcessInfo.processInfo.environment[Self.outputRootEnvironmentKey] else {
            throw XCTSkip("Set \(Self.outputRootEnvironmentKey) (TEST_RUNNER_ prefix via xcodebuild) "
                + "to generate the RX-01 installed fixture.")
        }
        guard rawRoot.hasPrefix("/"), !rawRoot.contains("\0") else {
            return XCTFail("\(Self.outputRootEnvironmentKey) must be an absolute path, got \(rawRoot)")
        }
        let outputRoot = URL(fileURLWithPath: rawRoot, isDirectory: true).standardizedFileURL

        let store = try await makeFixtureStore()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rx01-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Write once to scratch and prove it before anything lands in the output root.
        let staged = scratch.appendingPathComponent(Self.packageName, isDirectory: true)
        XCTAssertTrue(store.writeDocumentPackage(to: staged), store.saveError ?? "the production writer rejected the package")
        let acceptance = try await runStoreLevelAcceptance(onCopyOf: staged, scratch: scratch)

        let manager = FileManager.default
        try manager.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let packageURL = outputRoot.appendingPathComponent(Self.packageName, isDirectory: true)
        let sidecarURL = outputRoot.appendingPathComponent(Self.sidecarName)
        for url in [packageURL, sidecarURL] where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        XCTAssertTrue(store.writeDocumentPackage(to: packageURL), store.saveError ?? "the production writer rejected the package")
        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(opened.manifest.workspaceName, Self.workspaceName)

        let sidecar: ScriptValue = .object([
            "schema": .string("macscope.rx01-installed-fixture.v1"),
            "generator": .string("CoreTests/RX01InstalledFixtureGeneratorTests via WorkspaceStore.writeDocumentPackage"),
            "package": .string(packageURL.path),
            "binaries": .array(store.snapshot.binaries.sorted { $0.slot.rawValue < $1.slot.rawValue }.map {
                .object(["slot": .int(Int64($0.slot.rawValue)), "path": .string($0.path)])
            }),
            "authoringDigestBySlot": HeadlessWorkspaceAnnotationTransferAcceptance.scriptValue(
                HeadlessWorkspaceAnnotationTransferAcceptance.authoringDigestBySlot(store.snapshot)),
            "storeLevelAcceptance": acceptance,
        ])
        try sidecar.jsonData().write(to: sidecarURL, options: .atomic)
    }

    /// Always runs (no output root needed): the fixture the generator would write is known-good.
    func testFixtureStoreGivesExpectedStoreLevelAcceptance() async throws {
        let store = try await makeFixtureStore()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rx01-fixture-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(Self.packageName, isDirectory: true)
        XCTAssertTrue(store.writeDocumentPackage(to: staged), store.saveError ?? "the production writer rejected the package")
        _ = try await runStoreLevelAcceptance(onCopyOf: staged, scratch: scratch)
    }

    // MARK: - Fixture construction

    private func makeFixtureStore() async throws -> WorkspaceStore {
        let v1 = Self.fixtureDirectory.appendingPathComponent("rx01_v1")
        let v2 = Self.fixtureDirectory.appendingPathComponent("rx01_v2_stripped")
        for url in [v1, v2] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing fixture \(url.path)")
        }
        let engine = AnalysisEngine()
        let store = WorkspaceStore(workspaceName: Self.workspaceName, snapshot: try engine.analyze(url: v1),
                                   engine: engine, autosaveScheduler: nil)
        await store.loadAdditionalBinary(url: v2)
        await store.awaitCurrentRehydrationForTesting()
        XCTAssertEqual(store.snapshot.binaries.map(\.slot).sorted { $0.rawValue < $1.rawValue }, [.primary, newSlot])
        XCTAssertNotNil(store.snapshot.analysis(in: .primary))
        XCTAssertNotNil(store.snapshot.analysis(in: newSlot))

        // Stripped v2 keeps the named v2 layout, so source names come from the named build.
        let oldStarts = try starts(namedVariant: "rx01_v1")
        let newStarts = try starts(namedVariant: "rx01_v2")
        let primaryFunctionStarts = Set(try XCTUnwrap(store.snapshot.analysis(in: .primary)).functions.map(\.startAddress))
        let newFunctionStarts = Set(try XCTUnwrap(store.snapshot.analysis(in: newSlot)).functions.map(\.startAddress))
        for entry in Self.primaryAnnotations {
            let address = try XCTUnwrap(oldStarts[entry.function], "no v1 function \(entry.function)")
            XCTAssertTrue(primaryFunctionStarts.contains(address))
            store.setCustomName(address, in: .primary, name: entry.name)
            store.setCustomComment(address, in: .primary, comment: entry.comment)
        }
        let conflictAddress = try XCTUnwrap(newStarts[Self.destinationConflictFunction])
        XCTAssertTrue(newFunctionStarts.contains(conflictAddress), "stripped v2 keeps the named v2 start")
        store.setCustomComment(conflictAddress, in: newSlot, comment: Self.destinationConflictComment)
        return store
    }

    /// Source name (leading `_` dropped) → function start, from a named build.
    private func starts(namedVariant: String) throws -> [String: UInt64] {
        let snapshot = try AnalysisEngine().analyze(url: Self.fixtureDirectory.appendingPathComponent(namedVariant))
        let analysis = try XCTUnwrap(snapshot.analysis(in: .primary))
        var result: [String: UInt64] = [:]
        for function in analysis.functions where !FunctionVersionFingerprinting.isGeneratedName(function.name) {
            let label = function.name.hasPrefix("_") ? String(function.name.dropFirst()) : function.name
            result[label] = min(result[label] ?? .max, function.startAddress)
        }
        return result
    }

    // MARK: - Store-level acceptance (the installed run's runner, in process)

    /// Reopens a copy of `package` exactly as a fresh process would, then runs the §2.8 runner and
    /// requires `passed: true` with `applied {names: 3, comments: 2, conflicts: 1}`.
    @discardableResult
    private func runStoreLevelAcceptance(onCopyOf package: URL, scratch: URL) async throws -> ScriptValue {
        let runRoot = scratch.appendingPathComponent("acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let copy = runRoot.appendingPathComponent(Self.packageName, isDirectory: true)
        try FileManager.default.copyItem(at: package, to: copy)
        let reopened = try WorkspaceStore.restoredPackage(from: copy, scheduleDurableRecovery: false)
        await reopened.rehydrateLoadedImagesSynchronouslyForTesting()

        let saved = runRoot.appendingPathComponent("saved-\(Self.packageName)", isDirectory: true)
        let result = try await HeadlessWorkspaceAnnotationTransferAcceptance.run(store: reopened) { store in
            guard store.writeDocumentPackage(to: saved) else {
                throw HeadlessWorkspaceAnnotationTransferAcceptance.Failure(description: store.saveError ?? "save")
            }
            return (saved, try WorkspaceStore.restoredPackage(from: saved, scheduleDurableRecovery: false).snapshot)
        }
        guard case let .object(fields) = result else {
            XCTFail("expected an object, got \(result)")
            return result
        }
        XCTAssertEqual(fields["passed"], .bool(true), "failures: \(String(describing: fields["failures"])); result \(result)")
        XCTAssertEqual(fields["outcome"], .object(["kind": .string("applied"), "names": .int(3),
                                                   "comments": .int(2), "conflicts": .int(1)]),
                       "result \(result)")
        XCTAssertEqual(fields["oldSlot"], .int(0))
        XCTAssertEqual(fields["newSlot"], .int(1))
        XCTAssertEqual(fields["undoRestoresBefore"], .bool(true))
        XCTAssertEqual(fields["redoRestoresAfter"], .bool(true))
        XCTAssertEqual(fields["reopenMatches"], .bool(true))
        guard case let .array(conflicts)? = fields["conflicts"], conflicts.count == 1,
              case let .object(conflict) = conflicts[0] else {
            XCTFail("expected exactly one conflict, got \(String(describing: fields["conflicts"]))")
            return result
        }
        XCTAssertEqual(conflict["field"], .string("comment"))
        XCTAssertEqual(conflict["kind"], .string("authored"))

        // The transferred names sit on slot 1 and the authored destination comment is kept.
        let newStarts = try starts(namedVariant: "rx01_v2")
        let expectedNames = ["parse_header": "rx01_parse_header", "checksum": "rx01_checksum",
                             "new_name": "rx01_abs_product_mod"]
        for (function, name) in expectedNames {
            let address = try XCTUnwrap(newStarts[function])
            XCTAssertEqual(reopened.snapshot.addressOverrides[ImageAddress(slot: newSlot, address: address)]?.customName,
                           name, function)
        }
        let conflictAddress = try XCTUnwrap(newStarts[Self.destinationConflictFunction])
        XCTAssertEqual(reopened.snapshot.addressOverrides[ImageAddress(slot: newSlot, address: conflictAddress)]?.customComment,
                       Self.destinationConflictComment, "authored destination text is never overwritten")
        return result
    }
}
