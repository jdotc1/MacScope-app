import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacScope

final class ReconstructionPackagePersistenceTests: XCTestCase {
    @MainActor
    func testFindingLifecycleNormalCaptureSaveReopenRetainsCompleteHistory() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let store = WorkspaceStore(workspaceName: "Finding lifecycle", snapshot: .init(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil)
        let initial = try AnalystFindingEnvelopeFixture.make(workspaceID: store.workspaceID, documentID: store.documentID)
        store.installValidatedAnalystFindings(initial)
        let id = initial.records[0].id
        _ = try store.editAnalystFinding(store.analystFindingEditToken(for: id), text: "Authored revision A\nΩ")
        _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: id), decision: .reviewed)
        _ = try store.editAnalystFinding(store.analystFindingEditToken(for: id), text: "Authored revision B")
        store.undoManager.undo()
        store.undoManager.redo()
        let expected = store.analystFindings
        let payload = try store.makePackagePayload()
        let captured = try MacScopeDocumentPackage.validatedContents(manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID, reconstructionState: payload.reconstructionState,
            instructionSidecarData: payload.instructionSidecarData)
        XCTAssertEqual(captured.manifest.analystFindings, expected)
        XCTAssertTrue(captured.manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingHistoryReaderFeature))
        let url = fixture.root.appendingPathComponent("FindingLifecycle.mscope")
        _ = try store.writeDocumentPackageThrowing(to: url)
        XCTAssertFalse(store.hasUnsavedChanges)
        store.undoManager.undo()
        XCTAssertTrue(store.hasUnsavedChanges, "Compensating history must remain a persisted edit")
        let reopened = try WorkspaceStore.restoredPackage(from: url, scheduleDurableRecovery: false)
        XCTAssertEqual(reopened.analystFindings, expected)
        XCTAssertEqual(reopened.analystFindings.records[0].content, initial.records[0].content)
        XCTAssertFalse(reopened.analystFindings.records[0].authoredLifecycle.isReviewCurrent)
        XCTAssertFalse(reopened.hasUnsavedChanges)
        XCTAssertNil(reopened.pendingAnalystFinding)
        XCTAssertNotEqual(reopened.documentInstallationID, store.documentInstallationID)
    }

    @MainActor
    func testFindingHistoryCapabilityAndNestedUnknownFieldsRefuseLossyPackageRead() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let initial = try AnalystFindingEnvelopeFixture.make(workspaceID: fixture.manifest.workspaceUUID,
            documentID: fixture.manifest.documentID).records[0]
        let lifecycle = try initial.authoredLifecycle.applying(.review(.needsChanges), identity: initial.revisionIdentity,
            initialText: initial.content.candidateText, expected: .init(content: 1, review: 0), now: Date())
        var manifest = fixture.manifest
        manifest.analystFindings = .init(records: [initial.revising(with: lifecycle)])
        try MacScopeDocumentPackage.writePackage(manifest, attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            reconstructionState: fixture.state, reconstructionAttachmentSources: [fixture.source], to: fixture.packageURL)
        let url = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for mutation in 0..<3 {
            var root = original
            if mutation == 0 {
                root["requiredReaderFeatures"] = (root["requiredReaderFeatures"] as? [String])?.filter {
                    $0 != WorkspacePackageManifest.analystFindingHistoryReaderFeature
                }
            } else if mutation == 1 {
                root["requiredReaderFeatures"] = ["analyst.findings.history.v999"]
            } else {
                var envelope = try XCTUnwrap(root["analystFindings"] as? [String: Any])
                var records = try XCTUnwrap(envelope["records"] as? [[String: Any]])
                var saved = try XCTUnwrap(records[0]["lifecycle"] as? [String: Any])
                var state = try XCTUnwrap(saved["state"] as? [String: Any])
                var review = try XCTUnwrap(state["latestReview"] as? [String: Any])
                review["futureDecisionEvidence"] = "must not disappear"
                state["latestReview"] = review; saved["state"] = state
                records[0]["lifecycle"] = saved; envelope["records"] = records; root["analystFindings"] = envelope
            }
            try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url)
            XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL))
        }
    }

    @MainActor
    func testAnalystFindingsRoundTripPreservesExactContentAndRejectsInvalidPackageAuthority() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let envelope = try AnalystFindingEnvelopeFixture.make(workspaceID: fixture.manifest.workspaceUUID,
            documentID: fixture.manifest.documentID)
        var manifest = fixture.manifest
        manifest.analystFindings = envelope
        try MacScopeDocumentPackage.writePackage(manifest,
            attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes], reconstructionState: fixture.state,
            reconstructionAttachmentSources: [fixture.source], to: fixture.packageURL)
        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertEqual(opened.manifest.analystFindings, envelope)
        XCTAssertTrue(opened.manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingsReaderFeature))
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        let original = try Data(contentsOf: manifestURL)
        for mutation in 0..<5 {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            switch mutation {
            case 0:
                var malformed = try XCTUnwrap(object["analystFindings"] as? [String: Any])
                malformed["schemaVersion"] = 99
                malformed["records"] = [[:]]
                object["analystFindings"] = malformed
            case 1: object["documentID"] = UUID().uuidString
            case 2: object.removeValue(forKey: "requiredReaderFeatures")
            case 3: object["requiredReaderFeatures"] = ["analyst.findings.v999"]
            default:
                var envelopeObject = try XCTUnwrap(object["analystFindings"] as? [String: Any])
                var records = try XCTUnwrap(envelopeObject["records"] as? [[String: Any]])
                var content = try XCTUnwrap(records[0]["content"] as? [String: Any])
                var request = try XCTUnwrap(content["originalRequest"] as? [String: Any])
                var context = try XCTUnwrap(request["groundedContext"] as? [String: Any])
                context["unknownContextField"] = "must not disappear during typed decoding"
                request["groundedContext"] = context
                content["originalRequest"] = request
                records[0]["content"] = content
                envelopeObject["records"] = records
                object["analystFindings"] = envelopeObject
            }
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL)
            XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)) { error in
                switch mutation {
                case 0: XCTAssertEqual(error as? AnalystFindingError, .unsupportedSchema(99))
                case 1: XCTAssertEqual(error as? AnalystFindingError, .wrongOwner)
                case 2: XCTAssertEqual(error as? ReconstructionPackageValidationError,
                    .stateGraphInvalid("analyst finding reader feature disagreement"))
                case 3: XCTAssertEqual(error as? MacScopeDocumentPackage.UnsupportedReaderFeaturesError,
                    .init(features: ["analyst.findings.v999"]))
                default: XCTAssertEqual(error as? ReconstructionPackageValidationError,
                    .noncanonicalManifest(MacScopeDocumentPackage.manifestFileName))
                }
            }
        }
    }

    func testLegacyPackageOmitsAnalystFindingsAndRejectsPhantomCapability() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertNil(opened.manifest.analystFindings)
        XCTAssertFalse(opened.manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingsReaderFeature))
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: fixture.packageURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        XCTAssertNil(object["analystFindings"])
        object["requiredReaderFeatures"] = [WorkspacePackageManifest.analystFindingsReaderFeature]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL)
        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)) {
            XCTAssertEqual($0 as? ReconstructionPackageValidationError,
                .stateGraphInvalid("analyst finding reader feature disagreement"))
        }
    }

    @MainActor
    func testStoreAnalystFindingCaptureAndDirectSaveRestorePreserveSameEnvelope() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let store = WorkspaceStore(workspaceName: "Authored finding transport",
            snapshot: .init(binaries: [], analysisBySlot: [:]), engine: AnalysisEngine(), autosaveScheduler: nil)
        let original = try AnalystFindingEnvelopeFixture.make(workspaceID: store.workspaceID, documentID: store.documentID)
        try WorkspaceStore.validateAnalystFindingsForRestore(original,
            workspaceID: store.workspaceID, documentID: store.documentID)
        store.installValidatedAnalystFindings(original)
        let capture = try store.makePackagePayload()
        let captured = try MacScopeDocumentPackage.validatedContents(manifestData: capture.manifestData,
            attachmentsByBinaryID: capture.attachmentsByBinaryID, reconstructionState: capture.reconstructionState,
            instructionSidecarData: capture.instructionSidecarData)
        XCTAssertEqual(captured.manifest.analystFindings, original)
        XCTAssertTrue(captured.manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingsReaderFeature))
        let url = fixture.root.appendingPathComponent("AuthoredFinding.mscope")
        _ = try store.writeDocumentPackageThrowing(to: url)
        let reopened = try WorkspaceStore.restoredPackage(from: url, scheduleDurableRecovery: false)
        XCTAssertEqual(try reopened.persistableAnalystFindings(), original)
        XCTAssertEqual(reopened.documentID, store.documentID)
        XCTAssertEqual(reopened.workspaceID, store.workspaceID)
        XCTAssertFalse(reopened.hasUnsavedChanges)
        // Reopen preserves the complete historical source snapshot.
        XCTAssertEqual(try reopened.persistableAnalystFindings()?.records.first?.content,
            original.records.first?.content)
    }

    func testVerifiedReconstructionSourceAcquisitionPreservesCancellation() {
        let cancelled: () throws -> Void = { throw CancellationError() }

        XCTAssertThrowsError(
            try WorkspaceDatabase.withVerifiedReconstructionAttachmentSourceErrorMapping(
                cancelled
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Cancellation was remapped to \(error)")
        }
    }

    func testVersion3RoundTripsThroughSystemTemporaryDirectoryTrustRoot() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        XCTAssertTrue(
            fixture.packageURL.path.hasPrefix(
                FileManager.default.temporaryDirectory.path + "/"
            )
        )

        try fixture.write()

        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertEqual(opened.reconstructionState, fixture.state)
        XCTAssertEqual(opened.reconstructionAttachmentSources.count, 1)
    }

    func testSingleImageReconstructionWritesVersion3AndExactPortablePaths() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }

        try fixture.write()

        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertEqual(opened.manifest.analysisFormatVersion, WorkspacePackageManifest.reconstructionFormatVersion)
        XCTAssertEqual(opened.reconstructionState, fixture.state)
        let descriptor = try XCTUnwrap(opened.manifest.reconstruction)
        XCTAssertEqual(descriptor.corpusManifestPath, "Reconstruction/corpus-manifest.json")
        XCTAssertEqual(descriptor.evidenceManifestPath, "Reconstruction/evidence-manifest.json")
        XCTAssertEqual(descriptor.checkpointManifestPath, "Reconstruction/checkpoint-manifest.json")
        XCTAssertEqual(try Data(contentsOf: fixture.corpusAttachmentURL), fixture.corpusBytes)
    }

    func testMixedStateRoundTripsWithByteIdenticalCanonicalManifests() throws {
        let fixture = try ReconstructionPackageFixture.make(includesEvidenceGraph: true)
        defer { fixture.remove() }
        try fixture.write()
        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertEqual(opened.reconstructionState, fixture.state)
        XCTAssertEqual(opened.reconstructionAttachmentSources.map(\.contentIdentity), [fixture.contentIdentity])

        let secondURL = fixture.root.appendingPathComponent("Second.mscope", isDirectory: true)
        try MacScopeDocumentPackage.writePackage(
            opened.manifest,
            attachmentsByBinaryID: opened.attachmentsByBinaryID,
            reconstructionState: opened.reconstructionState,
            reconstructionAttachmentSources: opened.reconstructionAttachmentSources,
            to: secondURL, instructionSidecarData: opened.instructionSidecarData
        )
        let second = try MacScopeDocumentPackage.openPackage(from: secondURL)
        XCTAssertEqual(second.reconstructionState, fixture.state)
        for path in [
            ReconstructionPackageLayout.corpusManifestPath,
            ReconstructionPackageLayout.evidenceManifestPath,
            ReconstructionPackageLayout.checkpointManifestPath,
        ] {
            XCTAssertEqual(
                try Data(contentsOf: fixture.packageURL.appendingPathComponent(path)),
                try Data(contentsOf: secondURL.appendingPathComponent(path)),
                "canonical manifest changed after reopen/resave: \(path)"
            )
        }
    }

    func testQualifiedEvidenceReadAuthoritySurvivesPhysicalPackageReopen() throws {
        let fixture = try ReconstructionPackageFixture.make(
            includesEvidenceGraph: true, includesEvidenceReadAuthority: true)
        defer { fixture.remove() }
        try fixture.write()
        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertEqual(opened.reconstructionState, fixture.state)
        let receipt = try XCTUnwrap(opened.reconstructionState.toolReceipts.first {
            $0.evidenceReadAuthority != nil
        })
        let expected = try XCTUnwrap(fixture.state.toolReceipts.first {
            $0.evidenceReadAuthority != nil
        })
        XCTAssertEqual(receipt.evidenceReadAuthority, expected.evidenceReadAuthority)
        XCTAssertEqual(receipt.evidenceReadAuthority?.readEvidenceIDs,
            fixture.state.evidence.map(\.evidenceID))
        XCTAssertTrue(receipt.outputEvidenceIDs.isEmpty)
        XCTAssertTrue(try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt))
        try XCTUnwrap(receipt.evidenceReadAuthority).validate(receipt: receipt)
        let secondURL = fixture.root.appendingPathComponent("ReadResaved.mscope", isDirectory: true)
        try MacScopeDocumentPackage.writePackage(opened.manifest,
            attachmentsByBinaryID: opened.attachmentsByBinaryID,
            reconstructionState: opened.reconstructionState,
            reconstructionAttachmentSources: opened.reconstructionAttachmentSources, to: secondURL,
            instructionSidecarData: opened.instructionSidecarData)
        XCTAssertEqual(try MacScopeDocumentPackage.openPackage(from: secondURL).reconstructionState,
            fixture.state)
    }

    func testDuplicateContentStagesOneObjectAndRetainsDistinctOccurrenceRoles() throws {
        let fixture = try ReconstructionPackageFixture.make(duplicatesContent: true)
        defer { fixture.remove() }
        try fixture.write()

        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        let occurrences = try XCTUnwrap(opened.reconstructionState.corpusManifests.first).artifacts
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(Set(occurrences.map(\.contentIdentity)), [fixture.contentIdentity])
        XCTAssertEqual(Set(occurrences.flatMap(\.roles)), [.primaryTarget, .referenceSource])

        let corpusRoot = fixture.packageURL.appendingPathComponent(
            ReconstructionPackageLayout.corpusDirectoryPath,
            isDirectory: true
        )
        let regularFiles = try XCTUnwrap(
            FileManager.default.enumerator(
                at: corpusRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        ).compactMap { item -> URL? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url
        }
        XCTAssertEqual(regularFiles.count, 1)
        XCTAssertEqual(
            try canonicalFileSystemPath(XCTUnwrap(regularFiles.first)),
            try canonicalFileSystemPath(fixture.corpusAttachmentURL)
        )
    }

    func testFailedStagedWriteLeavesPublishedPackageByteForByteUnchanged() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let before = try recursiveFileBytes(at: fixture.packageURL)

        try Data("mutated after identity verification".utf8).write(to: fixture.sourceURL)
        XCTAssertThrowsError(try fixture.write())

        XCTAssertEqual(try recursiveFileBytes(at: fixture.packageURL), before)
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL).reconstructionState,
            fixture.state
        )
    }

    @MainActor
    func testCancelledReplacementPropagatesAndNeverPublishesDestination() async throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let before = try recursiveFileBytes(at: fixture.packageURL)
        var replacementManifest = fixture.manifest
        replacementManifest.workspaceName = "Cancelled replacement"

        let writeTask = Task<Void, Error> { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            try MacScopeDocumentPackage.writePackage(
                replacementManifest,
                attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
                reconstructionState: fixture.state,
                reconstructionAttachmentSources: [fixture.source],
                to: fixture.packageURL
            )
        }
        writeTask.cancel()

        do {
            try await writeTask.value
            XCTFail("A cancelled package replacement must not publish.")
        } catch is CancellationError {
            // Expected cooperative cancellation through staged-package cleanup.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        XCTAssertEqual(try recursiveFileBytes(at: fixture.packageURL), before)
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL).manifest.workspaceName,
            fixture.manifest.workspaceName
        )
    }

    @MainActor
    func testCancelledOpenStopsBeforeFullReconstructionTraversal() async throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let unreferenced = fixture.packageURL.appendingPathComponent(
            "Reconstruction/Corpus/sha256/ff/" + String(repeating: "f", count: 64)
        )
        try FileManager.default.createDirectory(
            at: unreferenced.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("must not be traversed after cancellation".utf8).write(to: unreferenced)

        let openTask = Task<Void, Error> { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            _ = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        }
        openTask.cancel()

        do {
            _ = try await openTask.value
            XCTFail("A cancelled package open must stop before inventory traversal.")
        } catch is CancellationError {
            // Expected before the unreferenced corpus object is traversed.
        } catch {
            XCTFail("Cancellation must win over later corpus validation: \(error)")
        }
    }

    func testPostPublishDurabilityFailureRollsBackToOriginalPackage() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let before = try recursiveFileBytes(at: fixture.packageURL)

        struct InjectedFailure: Error {}
        var changedManifest = fixture.manifest
        changedManifest.workspaceName = "Replacement that must roll back"
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                changedManifest,
                attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
                reconstructionState: fixture.state,
                reconstructionAttachmentSources: [fixture.source],
                to: fixture.packageURL,
                testHooks: .init(
                    beforeDestinationParentSynchronization: { throw InjectedFailure() }
                )
            )
        )

        XCTAssertEqual(try recursiveFileBytes(at: fixture.packageURL), before)
        XCTAssertEqual(
            try MacScopeDocumentPackage.openPackage(from: fixture.packageURL).manifest.workspaceName,
            fixture.manifest.workspaceName
        )
    }

    func testWriterSynchronizesEveryStagedDirectoryIncludingBinaryAndCorpusShards() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        var synchronizedRelativePaths = Set<String>()

        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            reconstructionState: fixture.state,
            reconstructionAttachmentSources: [fixture.source],
            to: fixture.packageURL,
            testHooks: .init(didSynchronizeDirectory: { url in
                let marker = ".Portable.mscope."
                guard let markerRange = url.path.range(of: marker),
                      let suffixRange = url.path[markerRange.upperBound...].range(of: ".tmp") else {
                    return
                }
                let rootEnd = suffixRange.upperBound
                let relativeStart = url.path.index(rootEnd, offsetBy: 1, limitedBy: url.path.endIndex)
                let relative = relativeStart.map { String(url.path[$0...]) } ?? ""
                synchronizedRelativePaths.insert(relative)
            })
        )

        XCTAssertTrue(synchronizedRelativePaths.contains(""))
        XCTAssertTrue(synchronizedRelativePaths.contains("attachments"))
        XCTAssertTrue(synchronizedRelativePaths.contains(
            "attachments/\(fixture.binaryID.uuidString.lowercased())"
        ))
        XCTAssertTrue(synchronizedRelativePaths.contains("Reconstruction"))
        XCTAssertTrue(synchronizedRelativePaths.contains(
            "Reconstruction/Corpus/sha256/\(fixture.contentIdentity.digest.prefix(2))"
        ))
    }

    func testPackageBackedSourceIsRevalidatedBeforeResave() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        try fixture.write()
        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        let destination = fixture.root.appendingPathComponent("Resaved.mscope", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let before = try recursiveFileBytes(at: destination)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.corpusAttachmentURL.path
        )
        try Data("tampered package object".utf8).write(to: fixture.corpusAttachmentURL)
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                opened.manifest,
                attachmentsByBinaryID: opened.attachmentsByBinaryID,
                reconstructionState: opened.reconstructionState,
                reconstructionAttachmentSources: opened.reconstructionAttachmentSources,
                to: destination, instructionSidecarData: opened.instructionSidecarData
            )
        )
        XCTAssertEqual(try recursiveFileBytes(at: destination), before)
    }

    func testDescriptorBackedSourceCannotBeResavedAfterAuthorityRevocation() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let vaultRoot = fixture.root.appendingPathComponent("descriptor-vault", isDirectory: true)
        let shard = vaultRoot.appendingPathComponent(
            String(fixture.contentIdentity.digest.prefix(2)),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: shard,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fixture.corpusBytes.write(
            to: shard.appendingPathComponent(fixture.contentIdentity.digest)
        )
        let rootDescriptor = vaultRoot.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            } ?? -1
        }
        XCTAssertGreaterThanOrEqual(rootDescriptor, 0)
        let authority = try ReconstructionSidecarAttachmentAuthority(
            pinnedRootDescriptor: rootDescriptor
        )
        _ = Darwin.close(rootDescriptor)
        let source = authority.source(
            contentIdentity: fixture.contentIdentity,
            rootURL: vaultRoot
        )
        authority.revoke()

        let destination = fixture.root.appendingPathComponent(
            "RevokedSource.mscope",
            isDirectory: true
        )
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.writePackage(
                fixture.manifest,
                attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
                reconstructionState: fixture.state,
                reconstructionAttachmentSources: [source],
                to: destination
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionSidecarAttachmentAuthorityError,
                .revoked
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func recursiveFileBytes(at root: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    private func canonicalFileSystemPath(_ url: URL) throws -> String {
        errno = 0
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

struct ReconstructionPackageFixture {
    let root: URL
    let packageURL: URL
    let sourceURL: URL
    let binaryID: UUID
    let binaryBytes: Data
    let corpusBytes: Data
    let contentIdentity: ReconstructionContentIdentity
    let manifest: WorkspacePackageManifest
    let state: ReconstructionWorkspaceState

    var source: ReconstructionAttachmentSource {
        ReconstructionAttachmentSource(
            contentIdentity: contentIdentity,
            verifiedURL: sourceURL
        )
    }

    var corpusAttachmentURL: URL {
        get throws {
            try MacScopeDocumentPackage.reconstructionAttachmentURL(
                in: packageURL,
                contentIdentity: contentIdentity
            )
        }
    }

    static func make(
        duplicatesContent: Bool = false,
        includesEvidenceGraph: Bool = false,
        includesEvidenceReadAuthority: Bool = false
    ) throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReconstructionPackageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sourceURL = root.appendingPathComponent("source.bin")
        let corpusBytes = Data("immutable reconstruction corpus".utf8)
        try corpusBytes.write(to: sourceURL)
        let identity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digest(corpusBytes),
            byteCount: UInt64(corpusBytes.count)
        )
        let projectID = UUID()
        let primaryOccurrenceID = ReconstructionArtifactOccurrenceID(rawValue: UUID())
        var occurrences = [
            try ReconstructionArtifactOccurrenceRecord(
                occurrenceID: primaryOccurrenceID,
                contentIdentity: identity,
                kind: .opaque,
                roles: [.primaryTarget],
                executableMode: false,
                originalName: "source.bin",
                diagnostic: nil
            ),
        ]
        if duplicatesContent {
            occurrences.append(
                try ReconstructionArtifactOccurrenceRecord(
                    occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: UUID()),
                    contentIdentity: identity,
                    kind: .source,
                    roles: [.referenceSource],
                    executableMode: false,
                    originalName: "reference-source.bin",
                    diagnostic: nil
                )
            )
        }
        let provisionalCorpusManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: occurrences,
            relations: [],
            canonicalSHA256: digest(Data("corpus-manifest-authority".utf8))
        )
        let corpusDigest = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            of: provisionalCorpusManifest
        )
        let corpusManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: occurrences,
            relations: [],
            canonicalSHA256: corpusDigest
        )
        let project = try ReconstructionProjectRecord(
            projectID: projectID,
            name: "Portable reconstruction",
            currentCorpusManifestSHA256: corpusDigest
        )

        var jobs: [ReconstructionJobRecord] = []
        var tasks: [ReconstructionTaskRecord] = []
        var checkpoints: [ReconstructionCheckpoint] = []
        var evidence: [ReconstructionEvidenceRecord] = []
        var toolReceipts: [ReconstructionToolReceipt] = []
        if includesEvidenceGraph {
            let jobID = UUID()
            let taskID = UUID()
            let checkpointID = UUID()
            let readCheckpointID = UUID()
            let readTaskID = UUID()
            let evidenceID = UUID()
            let toolReceiptID = UUID()
            let operationID = ReconstructionOperationID.evidenceQuery.rawValue
            let subject = ReconstructionSubjectCoordinate.artifact(
                ReconstructionArtifactCoordinate(
                    occurrenceID: primaryOccurrenceID,
                    contentIdentity: identity
                )
            )
            let taskIdentity = try ReconstructionTaskIdentity.make(
                taskID: taskID,
                jobID: jobID,
                kind: .retrieveEvidence,
                subject: subject,
                dependencyTaskIDs: [],
                operationContractIdentity: operationID
            )
            tasks = [ReconstructionTaskRecord(identity: taskIdentity, state: .completed, diagnostic: nil)]
            jobs = [
                try ReconstructionJobRecord(
                    jobID: jobID,
                    reconstructionProjectID: projectID,
                    objective: "Preserve mixed reconstruction state",
                    objectiveSHA256: digest(Data("Preserve mixed reconstruction state".utf8)),
                    creationCorpusManifestSHA256: corpusDigest,
                    state: .completed,
                    currentCheckpointID: includesEvidenceReadAuthority ? readCheckpointID : checkpointID,
                    terminalReason: nil,
                    budget: try ReconstructionJobBudget(
                        maxRounds: 1,
                        maxTasks: 4,
                        maxEvidenceRecords: 4,
                        maxEncodedBytes: 4_096
                    )
                ),
            ]
            let payload = Data("accepted evidence".utf8)
            func producer(canonicalSHA256: String) throws -> ReconstructionProducerIdentity {
                try ReconstructionProducerIdentity(
                    macScopeBuildIdentity: "test-build",
                    macScopeSourceIdentity: "test-source",
                    operationIdentity: operationID,
                    registryIdentity: "test-registry",
                    protocolIdentity: "test-protocol",
                    canonicalSHA256: canonicalSHA256
                )
            }
            let draftProducer = try producer(canonicalSHA256: digest(Data("producer".utf8)))
            let canonicalProducer = try producer(
                canonicalSHA256: ReconstructionEvidenceIntegrity.canonicalProducerSHA256(
                    draftProducer
                )
            )
            let evidenceRecord = try ReconstructionEvidenceRecord(
                evidenceID: evidenceID,
                subject: subject,
                operationID: operationID,
                payloadKind: .text,
                payload: payload,
                payloadByteCount: UInt64(payload.count),
                payloadSHA256: digest(payload),
                facetDependencies: [],
                producer: canonicalProducer,
                citations: [
                    try ReconstructionEvidenceCitation(
                        citationID: UUID(),
                        sourceEvidenceID: nil,
                        subject: subject,
                        locator: nil
                    ),
                ],
                creatingJobID: jobID,
                creatingTaskID: taskID,
                creatingCheckpointID: checkpointID,
                modelReceiptID: nil,
                toolReceiptID: toolReceiptID,
                classification: .acceptedCurrent,
                supersedesEvidenceID: nil,
                supersededByEvidenceID: nil,
                diagnostic: nil
            )
            evidence = [evidenceRecord]
            toolReceipts = [
                try ReconstructionReceiptAuthority.makeToolReceipt(
                    receiptID: toolReceiptID,
                    jobID: jobID,
                    taskID: taskID,
                    checkpointRevision: 0,
                    requestIdentitySHA256: digest(Data("tool request".utf8)),
                    producer: canonicalProducer,
                    terminalState: .completed,
                    outputEvidenceIDs: [evidenceID],
                    diagnostic: nil
                ),
            ]
            checkpoints = [
                try ReconstructionCheckpoint.make(
                    checkpointID: checkpointID,
                    jobID: jobID,
                    revision: 0,
                    parentCheckpointID: nil,
                    parentCheckpointSHA256: nil,
                    corpusManifestSHA256: corpusDigest,
                    evidenceFrontierSHA256: try ReconstructionEvidenceFrontier.canonicalSHA256(
                        corpusManifestSHA256: corpusDigest,
                        records: evidence,
                        projectedClassificationsByEvidenceID: [
                            evidenceID: .acceptedCurrent,
                        ],
                        relations: [],
                        gaps: [],
                        checkpointRevisionsByID: [checkpointID: 0]
                    ),
                    pendingTaskIDs: includesEvidenceReadAuthority ? [readTaskID] : [],
                    runningTaskIDs: [],
                    completedTaskIDs: [taskID],
                    failedTaskIDs: [],
                    blockedTaskIDs: [],
                    unresolvedEvidenceGapSHA256:
                        try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: []),
                    modelReceiptIDs: [],
                    toolReceiptIDs: [toolReceiptID],
                    coordinatorState: includesEvidenceReadAuthority ? .retrieving : .completed,
                    terminalReason: nil
                ),
            ]
            if includesEvidenceReadAuthority {
                tasks.append(ReconstructionTaskRecord(identity: try ReconstructionTaskIdentity.make(
                    taskID: readTaskID, jobID: jobID, kind: .retrieveEvidence, subject: subject,
                    dependencyTaskIDs: [], operationContractIdentity: operationID),
                    state: .completed, diagnostic: nil))
                let parent = checkpoints[0]
                let query = try ReconstructionRetrievalQuery(corpusManifestSHA256: corpusDigest,
                    subject: subject, operationIDs: [.evidenceQuery], classifications: [.acceptedCurrent],
                    cursor: nil, maximumRecords: 4, maximumEncodedBytes: 65_536)
                let authority = try ReconstructionToolAuthorityCut(jobID: jobID,
                    checkpointRevision: 0, roundID: UUID(), corpusManifestSHA256: corpusDigest,
                    evidenceFrontierSHA256: parent.evidenceFrontierSHA256,
                    projectionFrontierSHA256: parent.evidenceFrontierSHA256)
                let request = ReconstructionToolRequest(operationID: .evidenceQuery,
                    taskID: readTaskID, subject: subject, retrievalQuery: query, offset: 0,
                    maximumRecords: query.maximumRecords, maximumEncodedBytes: query.maximumEncodedBytes)
                let handle = try ReconstructionToolRegistry().mintHandles(
                    authority: authority, requests: [request])[0]
                let cut = try ReconstructionEvidenceCut(corpusManifestSHA256: corpusDigest,
                    records: evidence, relations: [], gaps: [], frontierSHA256: parent.evidenceFrontierSHA256,
                    projectedClassificationsByEvidenceID: [evidenceID: .acceptedCurrent],
                    checkpointRevisionsByID: [checkpointID: 0])
                let packet = try ReconstructionRetrievalCompiler().compile(cut: cut, query: query)
                let read = try ReconstructionEvidenceReadAuthority(
                    request: ReconstructionToolRegistry().decodeCanonicalRequest(handle),
                    packetSHA256: packet.canonicalSHA256,
                    readEvidenceIDs: packet.records.map(\.evidenceID), nextCursor: packet.nextCursor)
                toolReceipts.append(try ReconstructionReceiptAuthority.makeToolReceipt(
                    receiptID: handle.handleID, jobID: jobID, taskID: readTaskID,
                    checkpointRevision: 1, requestIdentitySHA256: handle.requestSHA256,
                    producer: canonicalProducer, terminalState: .completed, outputEvidenceIDs: [],
                    diagnostic: nil, evidenceReadAuthority: read))
                checkpoints.append(try ReconstructionCheckpoint.make(
                    checkpointID: readCheckpointID, jobID: jobID, revision: 1,
                    parentCheckpointID: parent.checkpointID, parentCheckpointSHA256: parent.canonicalSHA256,
                    corpusManifestSHA256: corpusDigest,
                    evidenceFrontierSHA256: parent.evidenceFrontierSHA256,
                    pendingTaskIDs: [], runningTaskIDs: [], completedTaskIDs: [taskID, readTaskID],
                    failedTaskIDs: [], blockedTaskIDs: [],
                    unresolvedEvidenceGapSHA256: parent.unresolvedEvidenceGapSHA256,
                    modelReceiptIDs: [], toolReceiptIDs: toolReceipts.map(\.receiptID),
                    coordinatorState: .completed, terminalReason: nil))
            }
        }
        let state = try ReconstructionWorkspaceState(
            projects: [project],
            corpusManifests: [corpusManifest],
            evidence: evidence,
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: jobs,
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: toolReceipts,
            modelReceipts: []
        )

        let binaryID = UUID()
        let binaryBytes = Data([0x01, 0x02, 0x03])
        let binary = WorkspacePackageBinary(
            id: binaryID,
            displayName: "Primary",
            originalPath: "/fixtures/primary.bin",
            attachmentRelativePath: "attachments/\(binaryID.uuidString.lowercased())/primary.bin",
            kind: "Raw data",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: binaryBytes),
            fileSize: Int64(binaryBytes.count)
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(),
            workspaceUUID: UUID(),
            workspaceName: "Portable",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 2),
            binaries: [binary],
            analysis: WorkspacePackageAnalysis(),
            session: nil
        )
        return Self(
            root: root,
            packageURL: root.appendingPathComponent("Portable.mscope", isDirectory: true),
            sourceURL: sourceURL,
            binaryID: binaryID,
            binaryBytes: binaryBytes,
            corpusBytes: corpusBytes,
            contentIdentity: identity,
            manifest: manifest,
            state: state
        )
    }

    func write() throws {
        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: [binaryID: binaryBytes],
            reconstructionState: state,
            reconstructionAttachmentSources: [source],
            to: packageURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
