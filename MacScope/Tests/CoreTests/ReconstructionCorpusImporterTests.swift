import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionCorpusImporterTests: XCTestCase {
    func testSelectedDuplicateBytesCreateDistinctOccurrencesAndOneAttachment() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-ReconstructionCorpusImporterTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bytes = Data("identical corpus bytes\n".utf8)
        let primaryURL = root.appendingPathComponent("alpha.input")
        let referenceURL = root.appendingPathComponent("beta.input")
        try bytes.write(to: primaryURL)
        try bytes.write(to: referenceURL)

        let importer = ReconstructionCorpusImporter()
        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
        let result = await importer.ingest(
            selections: [
                ReconstructionImportSelection(
                    rootURL: primaryURL,
                    roles: [.primaryTarget]
                ),
                ReconstructionImportSelection(
                    rootURL: referenceURL,
                    roles: [.referenceSource]
                ),
            ],
            projectID: projectID,
            cancellation: ReconstructionCancellation()
        )

        let records = result.occurrences.sorted {
            ($0.originalName ?? "") < ($1.originalName ?? "")
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.originalName), ["alpha.input", "beta.input"])
        XCTAssertEqual(records.map(\.roles), [[.primaryTarget], [.referenceSource]])
        XCTAssertEqual(Set(records.map(\.occurrenceID)).count, 2)

        XCTAssertEqual(result.contents.count, 1)
        let content = try XCTUnwrap(result.contents.first)
        XCTAssertEqual(
            content.digest,
            "4da49c89ce37b61a8c116301446184b064b89da78928cadb6d2d8548232f9443"
        )
        XCTAssertEqual(content.byteCount, 23)
        XCTAssertEqual(content.algorithm, .sha256)
        XCTAssertEqual(records.map(\.contentIdentity), [content, content])

        XCTAssertEqual(result.attachmentSources.count, 1)
        XCTAssertEqual(
            result.attachmentSources.first?.contentIdentity,
            content
        )
        let attachmentURL = try XCTUnwrap(result.attachmentSources.first?.verifiedURL)
        XCTAssertNotEqual(attachmentURL.standardizedFileURL, primaryURL.standardizedFileURL)
        XCTAssertNotEqual(attachmentURL.standardizedFileURL, referenceURL.standardizedFileURL)
        XCTAssertTrue(result.failures.isEmpty)

        XCTAssertEqual(result.canonicalManifestSHA256.utf8.count, 64)
        XCTAssertTrue(result.canonicalManifestSHA256.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        })
        XCTAssertEqual(
            result.canonicalManifestSHA256,
            try ReconstructionCorpusCanonicalizer.canonicalSHA256(
                reconstructionProjectID: projectID,
                artifacts: result.occurrences,
                relations: result.relations
            )
        )

        try Data("mutated selected bytes\n".utf8).write(to: primaryURL)
        try FileManager.default.removeItem(at: referenceURL)
        XCTAssertEqual(try Data(contentsOf: attachmentURL), bytes)
    }

    func testSelectedZeroByteFileReturnsOneBoundedFailureAndPublishesNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-ReconstructionCorpusImporterTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let emptyURL = root.appendingPathComponent("empty.input")
        try Data().write(to: emptyURL)

        let result = await ReconstructionCorpusImporter().ingest(
            selections: [
                ReconstructionImportSelection(
                    rootURL: emptyURL,
                    roles: [.primaryTarget]
                ),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.reason, .emptyContent)
        XCTAssertFalse(failure.diagnostic.text.isEmpty)
        XCTAssertLessThanOrEqual(
            failure.diagnostic.text.utf8.count,
            ReconstructionDiagnostic.defaultMaxUTF8Bytes
        )
    }

    func testFlatAndNestedDirectorySelectionsUseBuilderSupportedManifestLimits() async throws {
        let root = try makeTemporaryRoot(named: "builder-supported-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let flatURL = root.appendingPathComponent("Flat", isDirectory: true)
        let nestedURL = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: flatURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: nestedURL.appendingPathComponent("Child", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("flat payload\n".utf8).write(to: flatURL.appendingPathComponent("flat.txt"))
        try Data("nested payload\n".utf8).write(
            to: nestedURL.appendingPathComponent("Child/nested.txt")
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader()
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: flatURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: nestedURL, roles: [.referenceSource]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000416")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(
            Set(result.occurrences.compactMap(\.originalName)),
            ["Flat", "flat.txt", "Nested", "Child", "nested.txt"]
        )
        XCTAssertEqual(
            Set(result.occurrences.filter { $0.kind == .directory }.compactMap(\.originalName)),
            ["Flat", "Nested", "Child"]
        )
    }

    func testResidualGlobalByteBudgetRejectsSecondSelectionBeforeItsReadHook() async throws {
        let root = try makeTemporaryRoot(named: "residual-byte-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.input")
        let secondURL = root.appendingPathComponent("second.input")
        try Data("12345678".utf8).write(to: firstURL)
        try Data("abcdefgh".utf8).write(to: secondURL)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotRegularFile: { url, _ in
                await recorder.recordURL(url.standardizedFileURL)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks,
            maximumTotalByteCount: 10
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: firstURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: secondURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000419")!,
            cancellation: ReconstructionCancellation()
        )

        let streamedURLs = await recorder.recordedURLs()
        XCTAssertEqual(streamedURLs, [firstURL.standardizedFileURL])
        XCTAssertEqual(result.failures.map(\.reason), [.boundsExceeded])
        XCTAssertEqual(result.occurrences.compactMap(\.originalName), ["first.input"])
        XCTAssertEqual(result.contents.map(\.byteCount), [8])
        XCTAssertEqual(result.attachmentSources.count, 1)
    }

    func testExactGlobalByteBudgetStillCatalogsSelectedFile() async throws {
        let root = try makeTemporaryRoot(named: "exact-byte-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("exact.input")
        try Data("12345678".utf8).write(to: selectedURL)

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            maximumTotalByteCount: 8
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000420")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.occurrences.compactMap(\.originalName), ["exact.input"])
        XCTAssertEqual(result.contents.map(\.byteCount), [8])
        XCTAssertEqual(result.attachmentSources.count, 1)
    }

    func testLoadableAttemptedByteBudgetChargesAllFiveFullBytePasses() async throws {
        let root = try makeTemporaryRoot(named: "loadable-attempted-byte-passes")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("Selected")
        let bytes = MachOFixture.makeExecutable().bytes
        try bytes.write(to: selectedURL)
        let byteCount = UInt64(bytes.count)
        let selection = ReconstructionImportSelection(
            rootURL: selectedURL,
            roles: [.primaryTarget]
        )
        let commonLimits = ReconstructionCorpusImporterAttemptedWorkLimits(
            maximumByteCount: byteCount * 4,
            maximumEntryCount: 8,
            maximumNameUTF8Bytes: 1_024,
            maximumExpandedPathUTF8Bytes: 1_024,
            maximumExpandedComponentWork: 1_024
        )

        let boundedResult = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            maximumTotalByteCount: byteCount,
            attemptedWorkLimits: commonLimits
        ).ingest(
            selections: [selection],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000433")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(boundedResult.failures.map(\.reason), [.boundsExceeded])
        XCTAssertTrue(boundedResult.occurrences.isEmpty)
        XCTAssertTrue(boundedResult.contents.isEmpty)
        XCTAssertTrue(boundedResult.relations.isEmpty)
        XCTAssertTrue(boundedResult.attachmentSources.isEmpty)

        let exactResult = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            maximumTotalByteCount: byteCount,
            attemptedWorkLimits: .init(
                maximumByteCount: byteCount * 5,
                maximumEntryCount: 8,
                maximumNameUTF8Bytes: 1_024,
                maximumExpandedPathUTF8Bytes: 1_024,
                maximumExpandedComponentWork: 1_024
            )
        ).ingest(
            selections: [selection],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000434")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(exactResult.failures.isEmpty)
        XCTAssertEqual(exactResult.occurrences.count, 1)
        XCTAssertEqual(exactResult.occurrences.first?.kind, .machOImage)
        XCTAssertEqual(exactResult.contents.map(\.byteCount), [byteCount])
        XCTAssertEqual(exactResult.attachmentSources.count, 1)
    }

    func testExpandedPathBudgetRejectsBeforeJoinedPathWorkBegins() async throws {
        let root = try makeTemporaryRoot(named: "expanded-path-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("r", isDirectory: true)
        let nestedURL = selectedURL.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: nestedURL.appendingPathComponent("bc"))
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotDirectoryEntry: { _, _ in
                await recorder.record(1)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks,
            capturedTreeLimits: .init(
                // Root-inclusive identity work is: r (1) + r/a (3) + r/a/bc (6).
                // Nine bytes admits the directory edge but rejects the leaf before its hook.
                maximumExpandedPathUTF8Bytes: 9,
                maximumExpandedComponentWork: 10
            )
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000422")!,
            cancellation: ReconstructionCancellation()
        )

        let recordedValues = await recorder.recordedValues()
        XCTAssertEqual(recordedValues, [1])
        XCTAssertEqual(result.failures.map(\.reason), [.boundsExceeded])
        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.relations.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
    }

    func testExpandedPathBudgetIsSharedAcrossDirectorySelections() async throws {
        let root = try makeTemporaryRoot(named: "shared-expanded-path-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("F", isDirectory: true)
        let secondURL = root.appendingPathComponent("S", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        let firstChildURL = firstURL.appendingPathComponent("a")
        let secondChildURL = secondURL.appendingPathComponent("bbbb")
        try Data("first".utf8).write(to: firstChildURL)
        try Data("second".utf8).write(to: secondChildURL)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotDirectoryEntry: { url, _ in
                await recorder.recordURL(url.standardizedFileURL)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks,
            capturedTreeLimits: .init(
                // F (1) + F/a (3) consumes four bytes. S consumes the final byte,
                // leaving no capacity to construct S/bbbb.
                maximumExpandedPathUTF8Bytes: 5,
                maximumExpandedComponentWork: 10
            )
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: firstURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: secondURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000423")!,
            cancellation: ReconstructionCancellation()
        )

        let recordedURLs = await recorder.recordedURLs()
        XCTAssertEqual(recordedURLs, [firstChildURL.standardizedFileURL])
        XCTAssertEqual(result.failures.map(\.reason), [.boundsExceeded])
        XCTAssertEqual(
            Set(result.occurrences.compactMap(\.originalName)),
            ["F", "a"]
        )
    }

    func testFailedSelectionDoesNotRefundAttemptedByteWorkForRetry() async throws {
        let root = try makeTemporaryRoot(named: "attempted-byte-work")
        defer { try? FileManager.default.removeItem(at: root) }
        let failedDirectoryURL = root.appendingPathComponent("f", isDirectory: true)
        try FileManager.default.createDirectory(
            at: failedDirectoryURL,
            withIntermediateDirectories: false
        )
        let payloadURL = failedDirectoryURL.appendingPathComponent("a")
        try Data("12345678".utf8).write(to: payloadURL)
        let fifoURL = failedDirectoryURL.appendingPathComponent("z")
        XCTAssertEqual(makeFIFO(at: fifoURL), 0)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotRegularFile: { url, _ in
                await recorder.recordURL(url.standardizedFileURL)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks,
            maximumTotalByteCount: 8,
            attemptedWorkLimits: .init(
                // One complete catalog pass plus the classifier's identity pass.
                maximumByteCount: 16,
                maximumEntryCount: 32,
                maximumNameUTF8Bytes: 1_024,
                maximumExpandedPathUTF8Bytes: 1_024,
                maximumExpandedComponentWork: 1_024
            )
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: failedDirectoryURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: failedDirectoryURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000424")!,
            cancellation: ReconstructionCancellation()
        )

        let streamedURLs = await recorder.recordedURLs()
        XCTAssertEqual(streamedURLs, [payloadURL.standardizedFileURL])
        XCTAssertEqual(result.failures.map(\.reason), [.unsupportedFileType, .boundsExceeded])
        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
    }

    func testFailedSelectionDoesNotRefundAttemptedIdentityPathWork() async throws {
        let root = try makeTemporaryRoot(named: "attempted-identity-path-work")
        defer { try? FileManager.default.removeItem(at: root) }
        let failedDirectoryURL = root.appendingPathComponent("f", isDirectory: true)
        try FileManager.default.createDirectory(
            at: failedDirectoryURL,
            withIntermediateDirectories: false
        )
        let payloadURL = failedDirectoryURL.appendingPathComponent("a")
        try Data("x".utf8).write(to: payloadURL)
        let driftingURL = failedDirectoryURL.appendingPathComponent("z")
        try Data("before".utf8).write(to: driftingURL)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotDirectoryEntry: { url, _ in
                await recorder.recordURL(url.standardizedFileURL)
                guard url.standardizedFileURL == driftingURL.standardizedFileURL,
                      await recorder.claim() else {
                    return
                }
                try FileManager.default.removeItem(at: driftingURL)
                try Data("after!".utf8).write(to: driftingURL)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks,
            attemptedWorkLimits: .init(
                maximumByteCount: 1_024,
                maximumEntryCount: 32,
                maximumNameUTF8Bytes: 1_024,
                // f (1) + f/a (3) + f/z (3), with 1 + 2 + 2 component visits.
                maximumExpandedPathUTF8Bytes: 7,
                maximumExpandedComponentWork: 5
            )
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: failedDirectoryURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: failedDirectoryURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000425")!,
            cancellation: ReconstructionCancellation()
        )

        let observedEntries = await recorder.recordedURLs()
        XCTAssertEqual(
            observedEntries,
            [payloadURL.standardizedFileURL, driftingURL.standardizedFileURL]
        )
        XCTAssertEqual(result.failures.map(\.reason), [.changedDuringImport, .boundsExceeded])
        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
    }

    func testFailedSelectionRestoresAcceptedEntryAndNameBudgets() async throws {
        let root = try makeTemporaryRoot(named: "accepted-name-entry-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let failedDirectoryURL = root.appendingPathComponent("f", isDirectory: true)
        try FileManager.default.createDirectory(
            at: failedDirectoryURL,
            withIntermediateDirectories: false
        )
        try Data("x".utf8).write(to: failedDirectoryURL.appendingPathComponent("a"))
        let fifoURL = failedDirectoryURL.appendingPathComponent("z")
        XCTAssertEqual(makeFIFO(at: fifoURL), 0)
        let laterURL = root.appendingPathComponent("v")
        try Data("v".utf8).write(to: laterURL)

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            maximumEntryCount: 3,
            maximumTotalNameUTF8Bytes: 3,
            attemptedWorkLimits: .init(
                maximumByteCount: 1_024,
                maximumEntryCount: 4,
                maximumNameUTF8Bytes: 4,
                maximumExpandedPathUTF8Bytes: 1_024,
                maximumExpandedComponentWork: 1_024
            )
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: failedDirectoryURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: laterURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000426")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result.failures.map(\.reason), [.unsupportedFileType])
        XCTAssertEqual(result.occurrences.compactMap(\.originalName), ["v"])
        XCTAssertEqual(result.contents.map(\.byteCount), [1])
        XCTAssertEqual(result.attachmentSources.count, 1)
    }

    func testFailedSelectionRestoresCommittedByteBudgetForLaterSelection() async throws {
        let root = try makeTemporaryRoot(named: "failed-selection-byte-rollback")
        defer { try? FileManager.default.removeItem(at: root) }
        let failedDirectoryURL = root.appendingPathComponent("Failed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: failedDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("12345678".utf8).write(
            to: failedDirectoryURL.appendingPathComponent("a-good.input")
        )
        let driftingURL = failedDirectoryURL.appendingPathComponent("z-drift.input")
        try Data("before".utf8).write(to: driftingURL)
        let laterURL = root.appendingPathComponent("later.input")
        try Data("abcdefgh".utf8).write(to: laterURL)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotDirectoryEntry: { _, relativePath in
                guard relativePath == "z-drift.input",
                      await recorder.claim() else {
                    return
                }
                try FileManager.default.removeItem(at: driftingURL)
                try Data("after!".utf8).write(to: driftingURL)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks,
            maximumTotalByteCount: 8
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: failedDirectoryURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: laterURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000421")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result.failures.map(\.reason), [.changedDuringImport])
        XCTAssertEqual(result.occurrences.compactMap(\.originalName), ["later.input"])
        XCTAssertEqual(result.contents.map(\.byteCount), [8])
        XCTAssertEqual(result.attachmentSources.count, 1)
    }

    func testDirectorySelectionPublishesManifestRootChildrenAndVerifiedRelations() async throws {
        let temporaryRoot = try makeTemporaryRoot(named: "directory-relations")
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let corpusURL = temporaryRoot.appendingPathComponent("Corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusURL, withIntermediateDirectories: true)
        let targetURL = corpusURL.appendingPathComponent("target.txt")
        try Data("selected target\n".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            atPath: corpusURL.appendingPathComponent("inside").path,
            withDestinationPath: "target.txt"
        )
        try FileManager.default.createSymbolicLink(
            atPath: corpusURL.appendingPathComponent("escape").path,
            withDestinationPath: "../outside.txt"
        )
        try Data("must not import\n".utf8).write(
            to: temporaryRoot.appendingPathComponent("outside.txt")
        )

        let cancellation = ReconstructionCancellation()
        let limits = ReconstructionContainerManifestBuilder.Limits(
            maximumDepth: 64,
            maximumEntries: 100_000,
            maximumRelativePathUTF8Bytes:
                ReconstructionContainerManifestBuilder.maximumSupportedRelativePathUTF8Bytes,
            maximumEncodedBytes: 64 * 1_024 * 1_024
        )
        let expectedManifest = try await ReconstructionContainerManifestBuilder().build(
            rootURL: corpusURL,
            limits: limits,
            cancellation: cancellation
        )
        defer { try? FileManager.default.removeItem(at: expectedManifest.attachmentSource.verifiedURL) }

        let projectID = UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader()
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: corpusURL, roles: [.primaryTarget]),
            ],
            projectID: projectID,
            cancellation: cancellation
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(
            result.occurrences.compactMap(\.originalName).sorted(),
            ["Corpus", "escape", "inside", "target.txt"]
        )
        let rootOccurrence = try XCTUnwrap(result.occurrences.first {
            $0.originalName == "Corpus"
        })
        XCTAssertEqual(rootOccurrence.kind, .directory)
        XCTAssertEqual(rootOccurrence.roles, [.primaryTarget])
        XCTAssertEqual(rootOccurrence.contentIdentity, expectedManifest.contentIdentity)
        let rootSource = try XCTUnwrap(result.attachmentSources.first {
            $0.contentIdentity == rootOccurrence.contentIdentity
        })
        XCTAssertEqual(
            try Data(contentsOf: rootSource.verifiedURL),
            expectedManifest.canonicalManifestBytes
        )

        let children = result.occurrences.filter { $0.occurrenceID != rootOccurrence.occurrenceID }
        let contains = result.relations.filter {
            $0.kind == .contains && $0.sourceOccurrenceID == rootOccurrence.occurrenceID
        }
        XCTAssertEqual(Set(contains.compactMap(\.targetOccurrenceID)), Set(children.map(\.occurrenceID)))
        XCTAssertTrue(contains.allSatisfy { $0.evidenceSource == .containerManifest })

        let internalLink = try XCTUnwrap(result.occurrences.first { $0.originalName == "inside" })
        let escapingLink = try XCTUnwrap(result.occurrences.first { $0.originalName == "escape" })
        let target = try XCTUnwrap(result.occurrences.first { $0.originalName == "target.txt" })
        XCTAssertEqual(internalLink.kind, .symbolicLink)
        XCTAssertEqual(escapingLink.kind, .symbolicLink)
        XCTAssertTrue(result.relations.contains {
            $0.kind == .symbolicLinkTarget
                && $0.sourceOccurrenceID == internalLink.occurrenceID
                && $0.targetOccurrenceID == target.occurrenceID
                && $0.evidenceSource == .containerManifest
        })
        XCTAssertFalse(result.relations.contains {
            $0.sourceOccurrenceID == escapingLink.occurrenceID
                && ($0.kind == .symbolicLinkTarget || $0.kind == .unresolvedDependency)
        })
        XCTAssertFalse(result.occurrences.contains { $0.originalName == "outside.txt" })
        for relation in result.relations {
            XCTAssertEqual(
                relation.canonicalSHA256,
                try ReconstructionRelationDiscoverer().canonicalDigest(for: relation)
            )
        }
        XCTAssertEqual(
            result.canonicalManifestSHA256,
            try ReconstructionCorpusCanonicalizer.canonicalSHA256(
                reconstructionProjectID: projectID,
                artifacts: result.occurrences,
                relations: result.relations
            )
        )
    }

    func testStructuredContainersPublishApplicationFrameworkAndDirectoryRootKinds() async throws {
        let root = try makeTemporaryRoot(named: "container-kinds")
        defer { try? FileManager.default.removeItem(at: root) }

        let directoryURL = root.appendingPathComponent("PlainDirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("plain resource\n".utf8).write(
            to: directoryURL.appendingPathComponent("item.txt")
        )

        let appURL = root.appendingPathComponent("Sample.app", isDirectory: true)
        let appMacOSURL = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: appMacOSURL, withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8).write(
            to: appURL.appendingPathComponent("Contents/Info.plist")
        )
        let appExecutableURL = appMacOSURL.appendingPathComponent("Sample")
        try MachOFixture.makeExecutable().bytes.write(to: appExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: appExecutableURL.path
        )

        let frameworkURL = root.appendingPathComponent("Sample.framework", isDirectory: true)
        let frameworkVersionURL = frameworkURL.appendingPathComponent("Versions/A", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworkVersionURL, withIntermediateDirectories: true)
        let frameworkBinaryURL = frameworkVersionURL.appendingPathComponent("Sample")
        try MachOFixture.makeExecutable(code: Data([0xc0, 0x03, 0x5f, 0xd6])).bytes.write(
            to: frameworkBinaryURL
        )

        let textAppURL = root.appendingPathComponent("Text.app", isDirectory: true)
        let textAppMacOSURL = textAppURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: textAppMacOSURL, withIntermediateDirectories: true)
        try Data("<?xml version=\"1.0\"?><plist><dict/></plist>".utf8).write(
            to: textAppURL.appendingPathComponent("Contents/Info.plist")
        )
        let textExecutableURL = textAppMacOSURL.appendingPathComponent("Text")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: textExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: textExecutableURL.path
        )

        let textFrameworkURL = root.appendingPathComponent("Text.framework", isDirectory: true)
        let textFrameworkVersionURL = textFrameworkURL.appendingPathComponent(
            "Versions/A",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: textFrameworkVersionURL,
            withIntermediateDirectories: true
        )
        try Data("not a loadable framework image\n".utf8).write(
            to: textFrameworkVersionURL.appendingPathComponent("Text")
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader()
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: directoryURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: appURL, roles: [.primaryTarget]),
                ReconstructionImportSelection(rootURL: frameworkURL, roles: [.dependency]),
                ReconstructionImportSelection(rootURL: textAppURL, roles: [.auxiliary]),
                ReconstructionImportSelection(rootURL: textFrameworkURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000404")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        let roots = result.occurrences.filter {
            [
                "PlainDirectory",
                "Sample.app",
                "Sample.framework",
                "Text.app",
                "Text.framework",
            ].contains($0.originalName ?? "")
        }
        XCTAssertEqual(roots.count, 5)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: roots.map { ($0.originalName!, $0.kind) }),
            [
                "PlainDirectory": .directory,
                "Sample.app": .applicationBundle,
                "Sample.framework": .frameworkBundle,
                "Text.app": .directory,
                "Text.framework": .directory,
            ]
        )
        for container in roots {
            XCTAssertTrue(result.relations.contains {
                $0.kind == .contains && $0.sourceOccurrenceID == container.occurrenceID
            })
        }
    }

    func testVerifiedBytesClassifyMajorKindsAndSuffixCannotFabricateBinary() async throws {
        let root = try makeTemporaryRoot(named: "classification")
        defer { try? FileManager.default.removeItem(at: root) }

        let machOBytes = MachOFixture.makeExecutable().bytes
        var objectBytes = MachOFixture.makeExecutable().bytes
        objectBytes.replaceSubrange(12..<16, with: [0x01, 0x00, 0x00, 0x00])
        let fixtures: [(String, Data, ReconstructionArtifactKind)] = [
            ("binary.payload", machOBytes, .machOImage),
            ("implementation.c", Data("int value(void) { return 1; }\n".utf8), .source),
            ("contract.h", Data("#define FIXTURE_VALUE 1\n".utf8), .header),
            ("pixel.payload", Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), .resource),
            ("failure.crash", Data("Exception Type: EXC_BAD_ACCESS\n".utf8), .diagnostic),
            ("events.log", Data("2026-08-09 importer started\n".utf8), .log),
            ("compressed.payload", Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0, count: 18)), .archive),
            ("static.payload", Data("!<arch>\n".utf8), .staticLibrary),
            ("object.payload", objectBytes, .objectFile),
            ("masquerade.dylib", Data([0xde, 0xad, 0xbe, 0xef]), .opaque),
        ]
        var selections: [ReconstructionImportSelection] = []
        for fixture in fixtures {
            let url = root.appendingPathComponent(fixture.0)
            try fixture.1.write(to: url)
            selections.append(ReconstructionImportSelection(rootURL: url, roles: [.auxiliary]))
        }
        let loader = ReconstructionRecordingBinaryLoader()

        let result = await ReconstructionCorpusImporter(binaryLoader: loader).ingest(
            selections: selections,
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000405")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.occurrences.count, fixtures.count)
        let kinds = Dictionary(uniqueKeysWithValues: result.occurrences.map {
            ($0.originalName!, $0.kind)
        })
        XCTAssertEqual(kinds, Dictionary(uniqueKeysWithValues: fixtures.map { ($0.0, $0.2) }))
        let opaque = try XCTUnwrap(result.occurrences.first {
            $0.originalName == "masquerade.dylib"
        })
        XCTAssertEqual(opaque.kind, .opaque)
        XCTAssertNotNil(opaque.diagnostic)
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(opaque.diagnostic).text.utf8.count,
            ReconstructionDiagnostic.defaultMaxUTF8Bytes
        )
        XCTAssertEqual(Set(loader.loads().map(\.data)), Set([machOBytes, objectBytes]))

        let pureOpaque = ReconstructionArtifactClassifier().classifyVerifiedRegularFile(
            originalName: "fabricated.dylib",
            verifiedPrefix: Data([0xde, 0xad, 0xbe, 0xef]),
            verifiedByteCount: 4,
            completeSample: true
        )
        XCTAssertEqual(pureOpaque.kind, .opaque)
    }

    func testFat64AndByteSwappedFat64DylibsUseBoundedSelectedSliceProof() async throws {
        let root = try makeTemporaryRoot(named: "fat64-dylibs")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures = [
            ("fat64.dylib", makeSparseFat64Dylib(byteOrder: .bigEndian)),
            ("fat64-swapped.dylib", makeSparseFat64Dylib(byteOrder: .littleEndian)),
        ]
        var selections: [ReconstructionImportSelection] = []
        for (name, bytes) in fixtures {
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url)
            selections.append(ReconstructionImportSelection(rootURL: url, roles: [.auxiliary]))
        }
        let loader = ReconstructionRecordingBinaryLoader()

        let result = await ReconstructionCorpusImporter(binaryLoader: loader).ingest(
            selections: selections,
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000427")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.occurrences.count, 2)
        XCTAssertTrue(result.occurrences.allSatisfy { $0.kind == .dynamicLibrary })
        XCTAssertEqual(Set(loader.loads().map(\.data)), Set(fixtures.map(\.1)))
    }

    func testPostCatalogSameSizeReplacementCannotDriveClassificationOrLoading() async throws {
        let root = try makeTemporaryRoot(named: "catalog-identity-binding")
        defer { try? FileManager.default.removeItem(at: root) }
        let cataloguedBytes = MachOFixture.makeExecutable().bytes
        var mutableReplacementBytes = cataloguedBytes
        mutableReplacementBytes.replaceSubrange(12..<16, with: [0x06, 0x00, 0x00, 0x00])
        let replacementBytes = mutableReplacementBytes
        XCTAssertEqual(cataloguedBytes.count, replacementBytes.count)
        let selectedURL = root.appendingPathComponent("Selected")
        try cataloguedBytes.write(to: selectedURL)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didCatalogAttachment: { source in
                guard await recorder.claim() else { return }
                await recorder.recordURL(source.verifiedURL)
                try! FileManager.default.removeItem(at: source.verifiedURL)
                try! replacementBytes.write(to: source.verifiedURL, options: .withoutOverwriting)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.primaryTarget]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000428")!,
            cancellation: ReconstructionCancellation()
        )

        let replacementWasInstalled = await recorder.wasClaimed()
        XCTAssertTrue(replacementWasInstalled)
        XCTAssertEqual(result.failures.map(\.reason), [.changedDuringImport])
        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.relations.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
    }

    func testLoaderBytesMustMatchCataloguedContentIdentity() async throws {
        let root = try makeTemporaryRoot(named: "loader-identity-binding")
        defer { try? FileManager.default.removeItem(at: root) }
        let cataloguedBytes = MachOFixture.makeExecutable().bytes
        var substitutedBytes = cataloguedBytes
        substitutedBytes[substitutedBytes.index(before: substitutedBytes.endIndex)] ^= 0xff
        let selectedURL = root.appendingPathComponent("Selected")
        try cataloguedBytes.write(to: selectedURL)

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionSubstitutingBinaryLoader(bytes: substitutedBytes)
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.primaryTarget]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000429")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertEqual(result.failures.map(\.reason), [.changedDuringImport])
        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.relations.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
    }

    func testLoadableHintDemotesToOpaqueWhenImmutableBytesDoNotLoad() async throws {
        let root = try makeTemporaryRoot(named: "loader-demotion")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("ForgedMachO")
        try MachOFixture.makeExecutable().bytes.write(to: selectedURL)

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionAlwaysRejectingBinaryLoader()
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000417")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        let occurrence = try XCTUnwrap(result.occurrences.first)
        XCTAssertEqual(occurrence.kind, .opaque)
        XCTAssertNotNil(occurrence.diagnostic)
        XCTAssertTrue(result.relations.isEmpty)
    }

    func testInjectedLoaderUsesOnlyImmutableCopiesAndNeverImplicitlyImportsDependencies() async throws {
        let root = try makeTemporaryRoot(named: "dependency-evidence")
        defer { try? FileManager.default.removeItem(at: root) }
        let mainBytes = MachOFixture.makeExecutable().bytes
        var selectedBytes = MachOFixture.makeExecutable(
            code: Data([0xc0, 0x03, 0x5f, 0xd6])
        ).bytes
        selectedBytes.replaceSubrange(12..<16, with: [0x06, 0x00, 0x00, 0x00])
        let mainURL = root.appendingPathComponent("Main")
        let selectedURL = root.appendingPathComponent("Selected")
        try mainBytes.write(to: mainURL)
        try selectedBytes.write(to: selectedURL)
        let loader = ReconstructionRecordingBinaryLoader { data in
            data == mainBytes ? ["Selected", "Outside"] : []
        }

        let result = await ReconstructionCorpusImporter(binaryLoader: loader).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: mainURL, roles: [.primaryTarget]),
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.dependency]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000406")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.occurrences.count, 2)
        XCTAssertFalse(result.occurrences.contains { $0.originalName == "Outside" })
        let main = try XCTUnwrap(result.occurrences.first { $0.originalName == "Main" })
        let selected = try XCTUnwrap(result.occurrences.first { $0.originalName == "Selected" })
        XCTAssertTrue(result.relations.contains {
            $0.kind == .dependsOn
                && $0.sourceOccurrenceID == main.occurrenceID
                && $0.targetOccurrenceID == selected.occurrenceID
                && $0.evidenceSource == .dependencyCommand
        })
        XCTAssertTrue(result.relations.contains {
            $0.kind == .unresolvedDependency
                && $0.sourceOccurrenceID == main.occurrenceID
                && $0.targetOccurrenceID == nil
                && $0.unresolvedLocator == "Outside"
                && $0.evidenceSource == .dependencyCommand
        })
        XCTAssertEqual(result.relations.count, 2)

        let loads = loader.loads()
        XCTAssertEqual(loads.count, 2)
        XCTAssertEqual(Set(loads.map(\.data)), Set([mainBytes, selectedBytes]))
        XCTAssertTrue(loads.allSatisfy {
            $0.url.standardizedFileURL != mainURL.standardizedFileURL
                && $0.url.standardizedFileURL != selectedURL.standardizedFileURL
        })
    }

    func testRegularFileMetadataDriftRetriesExactlyOnce() async throws {
        let root = try makeTemporaryRoot(named: "regular-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("retry.input")
        try Data("initial descriptor payload\n".utf8).write(to: selectedURL)
        let stableBytes = Data("stable retry payload after drift\n".utf8)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotRegularFile: { url, attempt in
                await recorder.record(attempt)
                guard attempt == 1 else { return }
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: stableBytes)
                try handle.close()
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks,
            maximumTotalByteCount: UInt64(stableBytes.count)
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000407")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        let recordedAttempts = await recorder.recordedValues()
        XCTAssertEqual(recordedAttempts, [1, 2])
        let content = try XCTUnwrap(result.contents.first)
        XCTAssertEqual(
            content.digest,
            "37a02b0d58a05a94bb8ce07124a28e044a36b24162cff336de7142d2457a9451"
        )
        XCTAssertEqual(content.byteCount, 33)
        let source = try XCTUnwrap(result.attachmentSources.first)
        XCTAssertEqual(try Data(contentsOf: source.verifiedURL), stableBytes)
    }

    func testChildNameToDescriptorDriftRollsBackUnpublishedSelectionCopies() async throws {
        let root = try makeTemporaryRoot(named: "child-drift")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedRoot = root.appendingPathComponent("Corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try Data("catalogued before later failure\n".utf8).write(
            to: selectedRoot.appendingPathComponent("a-good.txt")
        )
        let driftURL = selectedRoot.appendingPathComponent("z-drift.bin")
        try Data("first inode\n".utf8).write(to: driftURL)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotDirectoryEntry: { url, relativePath in
                guard relativePath == "z-drift.bin", await recorder.claim() else { return }
                try FileManager.default.removeItem(at: url)
                try Data("replacement inode\n".utf8).write(to: url)
            },
            didCatalogAttachment: { source in
                await recorder.recordURL(source.verifiedURL)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedRoot, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000408")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
        XCTAssertEqual(result.failures.map(\.reason), [.changedDuringImport])
        let unpublishedURLs = await recorder.recordedURLs()
        XCTAssertFalse(unpublishedURLs.isEmpty)
        XCTAssertTrue(unpublishedURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    func testRootLinkMetadataDriftFailsWithoutPublishingTheReplacement() async throws {
        let root = try makeTemporaryRoot(named: "root-link-drift")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstTarget = root.appendingPathComponent("first-target")
        let secondTarget = root.appendingPathComponent("second-target")
        try Data("first\n".utf8).write(to: firstTarget)
        try Data("second\n".utf8).write(to: secondTarget)
        let linkURL = root.appendingPathComponent("selected-link")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: "first-target"
        )
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didSnapshotRoot: { url in
                guard await recorder.claim() else { return }
                try FileManager.default.removeItem(at: url)
                try FileManager.default.createSymbolicLink(
                    atPath: url.path,
                    withDestinationPath: "second-target"
                )
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: linkURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000409")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
        XCTAssertEqual(result.failures.map(\.reason), [.changedDuringImport])
    }

    func testSameSizeByteMutationAfterContainerChildCatalogFailsClosed() async throws {
        try await assertPostCatalogContainerMutationFailsClosed(
            .sameSizeRegularFileBytes,
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000411")!
        )
    }

    func testExecutableModeMutationAfterContainerChildCatalogFailsClosed() async throws {
        try await assertPostCatalogContainerMutationFailsClosed(
            .regularFileExecutableMode,
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000412")!
        )
    }

    func testSymlinkTextMutationAfterContainerChildCatalogFailsClosed() async throws {
        try await assertPostCatalogContainerMutationFailsClosed(
            .symbolicLinkText,
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000413")!
        )
    }

    func testNestedContainerTreePublishesCapturedManifestFactsAndImmediateTopology() async throws {
        let root = try makeTemporaryRoot(named: "nested-container-truth")
        defer { try? FileManager.default.removeItem(at: root) }
        let corpusURL = root.appendingPathComponent("Corpus", isDirectory: true)
        let malformedAppURL = corpusURL.appendingPathComponent("Malformed.app", isDirectory: true)
        let validAppURL = corpusURL.appendingPathComponent("Valid.app", isDirectory: true)
        let contentsURL = validAppURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let ordinaryURL = corpusURL.appendingPathComponent("Ordinary", isDirectory: true)
        for directoryURL in [malformedAppURL, macOSURL, ordinaryURL] {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }

        try Data("not an application bundle\n".utf8).write(
            to: malformedAppURL.appendingPathComponent("payload.txt")
        )
        try Data("<?xml version=\"1.0\"?><plist><dict/></plist>\n".utf8).write(
            to: contentsURL.appendingPathComponent("Info.plist")
        )
        let executableURL = macOSURL.appendingPathComponent("Valid")
        try MachOFixture.makeExecutable().bytes.write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try Data("ordinary nested bytes\n".utf8).write(
            to: ordinaryURL.appendingPathComponent("note.txt")
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader()
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: corpusURL, roles: [.primaryTarget]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000414")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        let expectedNames: Set<String> = [
            "Corpus",
            "Malformed.app",
            "payload.txt",
            "Valid.app",
            "Contents",
            "Info.plist",
            "MacOS",
            "Valid",
            "Ordinary",
            "note.txt",
        ]
        XCTAssertEqual(Set(result.occurrences.compactMap(\.originalName)), expectedNames)
        XCTAssertEqual(result.occurrences.count, expectedNames.count)
        let occurrencesByName = Dictionary(uniqueKeysWithValues: result.occurrences.map {
            ($0.originalName!, $0)
        })

        let expectedContainerKinds: [String: ReconstructionArtifactKind] = [
            "Corpus": .directory,
            "Malformed.app": .directory,
            "Valid.app": .applicationBundle,
            "Contents": .directory,
            "MacOS": .directory,
            "Ordinary": .directory,
        ]
        for (name, expectedKind) in expectedContainerKinds {
            let occurrence = try XCTUnwrap(occurrencesByName[name])
            XCTAssertEqual(occurrence.kind, expectedKind, name)
            XCTAssertEqual(occurrence.roles, [.primaryTarget], name)
        }
        XCTAssertEqual(occurrencesByName["Valid"]?.kind, .machOImage)
        XCTAssertEqual(occurrencesByName["Valid"]?.executableMode, true)

        let expectedChildren: [String: Set<String>] = [
            "Corpus": ["Malformed.app", "Ordinary", "Valid.app"],
            "Malformed.app": ["payload.txt"],
            "Valid.app": ["Contents"],
            "Contents": ["Info.plist", "MacOS"],
            "MacOS": ["Valid"],
            "Ordinary": ["note.txt"],
        ]
        let expectedContains = Set(expectedChildren.flatMap { parent, children in
            children.map { ReconstructionImporterContainsEdge(parent: parent, child: $0) }
        })
        let namesByID = Dictionary(uniqueKeysWithValues: result.occurrences.map {
            ($0.occurrenceID, $0.originalName!)
        })
        let contains = result.relations.filter { $0.kind == .contains }
        let actualContains = try Set(contains.map { relation in
            ReconstructionImporterContainsEdge(
                parent: try XCTUnwrap(namesByID[relation.sourceOccurrenceID]),
                child: try XCTUnwrap(namesByID[try XCTUnwrap(relation.targetOccurrenceID)])
            )
        })
        XCTAssertEqual(actualContains, expectedContains)
        XCTAssertEqual(contains.count, expectedContains.count)
        XCTAssertTrue(contains.allSatisfy { $0.evidenceSource == .containerManifest })

        let decoder = JSONDecoder()
        for (parentName, childNames) in expectedChildren {
            let parent = try XCTUnwrap(occurrencesByName[parentName])
            XCTAssertTrue(result.contents.contains(parent.contentIdentity), parentName)
            let source = try XCTUnwrap(result.attachmentSources.first {
                $0.contentIdentity == parent.contentIdentity
            })
            let manifestBytes = try Data(contentsOf: source.verifiedURL)
            XCTAssertEqual(source.contentIdentity, parent.contentIdentity, parentName)
            XCTAssertEqual(UInt64(manifestBytes.count), parent.contentIdentity.byteCount, parentName)
            XCTAssertEqual(sha256(manifestBytes), parent.contentIdentity.digest, parentName)
            let manifest = try decoder.decode(
                ReconstructionImporterContainerManifest.self,
                from: manifestBytes
            )
            XCTAssertEqual(manifest.schemaVersion, 1, parentName)
            XCTAssertEqual(
                try ReconstructionCanonicalJSON.encode(manifest),
                manifestBytes,
                "\(parentName) must attach canonical manifest bytes."
            )
            let immediateEntries = manifest.entries.filter {
                !$0.relativePath.contains("/")
            }
            XCTAssertEqual(Set(immediateEntries.map(\.relativePath)), childNames, parentName)
            XCTAssertEqual(immediateEntries.count, childNames.count, parentName)
            for childName in childNames {
                let child = try XCTUnwrap(occurrencesByName[childName])
                let entry = try XCTUnwrap(immediateEntries.first {
                    $0.relativePath == childName
                })
                XCTAssertEqual(entry.kind, child.kind, "\(parentName)/\(childName)")
                XCTAssertEqual(
                    entry.contentIdentity,
                    child.contentIdentity,
                    "\(parentName)/\(childName)"
                )
                XCTAssertEqual(
                    entry.executableMode,
                    child.executableMode,
                    "\(parentName)/\(childName)"
                )
                XCTAssertNil(entry.symbolicLinkTarget, "\(parentName)/\(childName)")
            }
        }
    }

    func testDeepUnrelatedFanoutIsNotCopiedIntoAncestorClassificationFacts() async throws {
        let root = try makeTemporaryRoot(named: "bounded-container-facts")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("r", isDirectory: true)
        let fanoutURL = selectedURL.appendingPathComponent("d1/d2/d3", isDirectory: true)
        try FileManager.default.createDirectory(at: fanoutURL, withIntermediateDirectories: true)
        for index in 0..<32 {
            try Data("x".utf8).write(
                to: fanoutURL.appendingPathComponent(String(format: "leaf-%02d", index))
            )
        }
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didPrepareContainerClassification: { url, factCount, maximumFactDepth in
                guard url.standardizedFileURL == selectedURL.standardizedFileURL else { return }
                await recorder.record(factCount)
                await recorder.record(maximumFactDepth)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000430")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        let rootFactSummary = await recorder.recordedValues()
        XCTAssertEqual(rootFactSummary, [3, 3])
        XCTAssertEqual(result.occurrences.count, 36)
    }

    func testCapturedTreeObserverCountsOnlySuccessfullyExecutedVerificationEdges() async throws {
        let root = try makeTemporaryRoot(named: "executed-verification-edges")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("r", isDirectory: true)
        let nestedURL = selectedURL.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try Data("leaf".utf8).write(to: nestedURL.appendingPathComponent("leaf"))
        try Data("top".utf8).write(to: selectedURL.appendingPathComponent("z"))
        let recorder = ReconstructionVerificationEdgeRecorder()
        let observer = ReconstructionCapturedTreeVerifier.VerificationObserver(
            didVerifyEdge: { parentIndex, childIndex in
                recorder.record(parentIndex: parentIndex, childIndex: childIndex)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: ReconstructionCorpusImporterHooks(verificationObserver: observer)
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000431")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(
            recorder.edges(),
            [
                ReconstructionVerificationEdge(parentIndex: 0, childIndex: 1),
                ReconstructionVerificationEdge(parentIndex: 1, childIndex: 2),
                ReconstructionVerificationEdge(parentIndex: 0, childIndex: 3),
            ]
        )
    }

    func testBuilderManifestLeaseDoesNotDeleteReplacementAtTemporaryPath() async throws {
        let root = try makeTemporaryRoot(named: "builder-manifest-lease")
        defer { try? FileManager.default.removeItem(at: root) }
        let corpusURL = root.appendingPathComponent("Corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpusURL, withIntermediateDirectories: true)
        try Data("captured child bytes\n".utf8).write(
            to: corpusURL.appendingPathComponent("child.txt")
        )
        let replacement = Data("replacement at relinquished builder path\n".utf8)
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            // Compile-time seam: this callback observes the builder-owned source while its
            // identity-bound lifetime lease is alive. Import cleanup must release that lease;
            // it must never call removeItem directly on the source URL.
            didBuildContainerManifest: { source in
                guard await recorder.claim() else { return }
                await recorder.recordURL(source.verifiedURL)
                try FileManager.default.removeItem(at: source.verifiedURL)
                try replacement.write(to: source.verifiedURL, options: .withoutOverwriting)
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: corpusURL, roles: [.auxiliary]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000415")!,
            cancellation: ReconstructionCancellation()
        )

        XCTAssertTrue(result.failures.isEmpty)
        let recordedURLs = await recorder.recordedURLs()
        let replacementURL = try XCTUnwrap(recordedURLs.first)
        defer { try? FileManager.default.removeItem(at: replacementURL) }
        XCTAssertEqual(try Data(contentsOf: replacementURL), replacement)
    }

    func testCancellationAfterFirstOccurrenceReturnsTerminalEmptyPublication() async throws {
        let root = try makeTemporaryRoot(named: "cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.input")
        let secondURL = root.appendingPathComponent("second.input")
        try Data("first selected bytes\n".utf8).write(to: firstURL)
        try Data("second selected bytes\n".utf8).write(to: secondURL)
        let cancellation = ReconstructionCancellation()
        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didAcquireOccurrence: { _ in
                guard await recorder.claim() else { return }
                cancellation.cancel()
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: firstURL, roles: [.primaryTarget]),
                ReconstructionImportSelection(rootURL: secondURL, roles: [.dependency]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000410")!,
            cancellation: cancellation
        )

        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.relations.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
        XCTAssertEqual(result.failures.map(\.reason), [.cancelled])
    }

    func testCancellationAfterResultPreparationPreventsSuccessfulPublication() async throws {
        let root = try makeTemporaryRoot(named: "final-publication-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let selectedURL = root.appendingPathComponent("selected.txt")
        try Data("selected bytes\n".utf8).write(to: selectedURL)
        let cancellation = ReconstructionCancellation()
        let hooks = ReconstructionCorpusImporterHooks(
            didPrepareSuccessfulResult: {
                cancellation.cancel()
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: selectedURL, roles: [.primaryTarget]),
            ],
            projectID: UUID(uuidString: "00000000-0000-0000-0000-000000000432")!,
            cancellation: cancellation
        )

        XCTAssertEqual(result.failures.map(\.reason), [.cancelled])
        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertTrue(result.contents.isEmpty)
        XCTAssertTrue(result.relations.isEmpty)
        XCTAssertTrue(result.attachmentSources.isEmpty)
    }

    private func assertPostCatalogContainerMutationFailsClosed(
        _ mutation: ReconstructionImporterPostCatalogMutation,
        projectID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let root = try makeTemporaryRoot(named: "post-catalog-\(mutation.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let corpusURL = root.appendingPathComponent("Corpus", isDirectory: true)
        let nestedURL = corpusURL.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        let subjectURL = nestedURL.appendingPathComponent("subject")
        switch mutation {
        case .sameSizeRegularFileBytes:
            try Data("fact-A\n".utf8).write(to: subjectURL)
        case .regularFileExecutableMode:
            try Data("mode fact\n".utf8).write(to: subjectURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: subjectURL.path
            )
        case .symbolicLinkText:
            try FileManager.default.createSymbolicLink(
                atPath: subjectURL.path,
                withDestinationPath: "target-A"
            )
        }

        let recorder = ReconstructionImporterEventRecorder()
        let hooks = ReconstructionCorpusImporterHooks(
            didCatalogContainerChildren: { cataloguedRootURL in
                guard cataloguedRootURL.standardizedFileURL == corpusURL.standardizedFileURL,
                      await recorder.claim() else {
                    return
                }
                switch mutation {
                case .sameSizeRegularFileBytes:
                    let handle = try FileHandle(forWritingTo: subjectURL)
                    try handle.write(contentsOf: Data("fact-B\n".utf8))
                    try handle.synchronize()
                    try handle.close()
                case .regularFileExecutableMode:
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: subjectURL.path
                    )
                case .symbolicLinkText:
                    try FileManager.default.removeItem(at: subjectURL)
                    try FileManager.default.createSymbolicLink(
                        atPath: subjectURL.path,
                        withDestinationPath: "target-B"
                    )
                }
            }
        )

        let result = await ReconstructionCorpusImporter(
            binaryLoader: ReconstructionRecordingBinaryLoader(),
            hooks: hooks
        ).ingest(
            selections: [
                ReconstructionImportSelection(rootURL: corpusURL, roles: [.primaryTarget]),
            ],
            projectID: projectID,
            cancellation: ReconstructionCancellation()
        )

        let hookWasClaimed = await recorder.wasClaimed()
        XCTAssertTrue(hookWasClaimed, mutation.rawValue, file: file, line: line)
        XCTAssertEqual(
            result.failures.map(\.reason),
            [.changedDuringImport],
            mutation.rawValue,
            file: file,
            line: line
        )
        XCTAssertTrue(result.occurrences.isEmpty, mutation.rawValue, file: file, line: line)
        XCTAssertTrue(result.contents.isEmpty, mutation.rawValue, file: file, line: line)
        XCTAssertTrue(result.relations.isEmpty, mutation.rawValue, file: file, line: line)
        XCTAssertTrue(result.attachmentSources.isEmpty, mutation.rawValue, file: file, line: line)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private enum FatByteOrder: Equatable {
        case bigEndian
        case littleEndian
    }

    private func makeSparseFat64Dylib(byteOrder: FatByteOrder) -> Data {
        let sliceOffset = 1_100_000
        var bytes = Data()
        appendUInt32(0xcafe_babf, byteOrder: byteOrder, to: &bytes)
        appendUInt32(1, byteOrder: byteOrder, to: &bytes)
        appendUInt32(UInt32(bitPattern: MachOConstants.cpuTypeARM64), byteOrder: byteOrder, to: &bytes)
        appendUInt32(0, byteOrder: byteOrder, to: &bytes)
        appendUInt64(UInt64(sliceOffset), byteOrder: byteOrder, to: &bytes)
        appendUInt64(32, byteOrder: byteOrder, to: &bytes)
        appendUInt32(0, byteOrder: byteOrder, to: &bytes)
        appendUInt32(0, byteOrder: byteOrder, to: &bytes)
        bytes.append(Data(repeating: 0, count: sliceOffset - bytes.count))
        appendUInt32(0xfeed_facf, byteOrder: .littleEndian, to: &bytes)
        appendUInt32(UInt32(bitPattern: MachOConstants.cpuTypeARM64), byteOrder: .littleEndian, to: &bytes)
        appendUInt32(0, byteOrder: .littleEndian, to: &bytes)
        appendUInt32(0x6, byteOrder: .littleEndian, to: &bytes)
        appendUInt32(0, byteOrder: .littleEndian, to: &bytes)
        appendUInt32(0, byteOrder: .littleEndian, to: &bytes)
        appendUInt32(0, byteOrder: .littleEndian, to: &bytes)
        appendUInt32(0, byteOrder: .littleEndian, to: &bytes)
        return bytes
    }

    private func appendUInt32(_ value: UInt32, byteOrder: FatByteOrder, to data: inout Data) {
        let ordered = byteOrder == .littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
    }

    private func appendUInt64(_ value: UInt64, byteOrder: FatByteOrder, to data: inout Data) {
        let ordered = byteOrder == .littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
    }

    private func makeFIFO(at url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.mkfifo($0, 0o600) } ?? -1
        }
    }

    private func makeTemporaryRoot(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-ReconstructionCorpusImporterTests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private actor ReconstructionImporterEventRecorder {
    private var values: [Int] = []
    private var urls: [URL] = []
    private var claimed = false

    func record(_ value: Int) {
        values.append(value)
    }

    func recordURL(_ url: URL) {
        urls.append(url)
    }

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }

    func recordedValues() -> [Int] {
        values
    }

    func recordedURLs() -> [URL] {
        urls
    }

    func wasClaimed() -> Bool {
        claimed
    }
}

private enum ReconstructionImporterPostCatalogMutation: String, Sendable {
    case sameSizeRegularFileBytes = "same-size-regular-file-bytes"
    case regularFileExecutableMode = "regular-file-executable-mode"
    case symbolicLinkText = "symbolic-link-text"
}

private struct ReconstructionImporterContainsEdge: Hashable {
    let parent: String
    let child: String
}

private struct ReconstructionImporterContainerManifest: Codable {
    let schemaVersion: Int
    let entries: [ReconstructionImporterContainerManifestEntry]
}

private struct ReconstructionImporterContainerManifestEntry: Codable {
    let relativePath: String
    let kind: ReconstructionArtifactKind
    let contentIdentity: ReconstructionContentIdentity?
    let executableMode: Bool
    let symbolicLinkTarget: String?
}

private struct ReconstructionVerificationEdge: Equatable {
    let parentIndex: Int
    let childIndex: Int
}

private final class ReconstructionVerificationEdgeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEdges: [ReconstructionVerificationEdge] = []

    func record(parentIndex: Int, childIndex: Int) {
        lock.lock()
        recordedEdges.append(ReconstructionVerificationEdge(
            parentIndex: parentIndex,
            childIndex: childIndex
        ))
        lock.unlock()
    }

    func edges() -> [ReconstructionVerificationEdge] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEdges
    }
}

private final class ReconstructionRecordingBinaryLoader: BinaryLoader, @unchecked Sendable {
    struct Load: Sendable {
        let url: URL
        let data: Data
    }

    private let lock = NSLock()
    private var recordedLoads: [Load] = []
    private let dependencies: @Sendable (Data) -> [String]

    init(dependencies: @escaping @Sendable (Data) -> [String] = { _ in [] }) {
        self.dependencies = dependencies
    }

    func load(at url: URL) throws -> LoadedBinary {
        let data = try Data(contentsOf: url)
        lock.lock()
        recordedLoads.append(Load(url: url, data: data))
        lock.unlock()
        let dylibs = dependencies(data).enumerated().map { index, path in
            MachOLoadMetadata.DependentDylib(
                path: path,
                kind: "required",
                currentVersion: "1.0.0",
                compatibilityVersion: "1.0.0",
                ordinal: index + 1
            )
        }
        return LoadedBinary(
            name: url.lastPathComponent,
            path: url.path,
            isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "Mach-O fixture",
            architectureDisplayName: "arm64",
            metadata: .empty,
            bytes: data,
            sliceOffset: 0,
            sliceSize: UInt64(data.count),
            sections: [],
            executableTextSection: nil,
            entryPointAddress: nil,
            symbols: [],
            imports: [],
            indirectSymbols: [],
            exports: [],
            stringLiterals: [],
            functionStarts: [],
            objcSelectors: [:],
            machOMetadata: MachOLoadMetadata(
                codeSignature: nil,
                importedSymbols: [],
                dependentDylibs: dylibs
            )
        )
    }

    func loads() -> [Load] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLoads
    }
}

private struct ReconstructionSubstitutingBinaryLoader: BinaryLoader {
    let bytes: Data

    func load(at url: URL) throws -> LoadedBinary {
        var loaded = try ReconstructionRecordingBinaryLoader().load(at: url)
        loaded.bytes = bytes
        loaded.sliceOffset = 0
        loaded.sliceSize = UInt64(bytes.count)
        return loaded
    }
}

private struct ReconstructionAlwaysRejectingBinaryLoader: BinaryLoader {
    private enum Failure: Error {
        case rejected
    }

    func load(at url: URL) throws -> LoadedBinary {
        throw Failure.rejected
    }
}
