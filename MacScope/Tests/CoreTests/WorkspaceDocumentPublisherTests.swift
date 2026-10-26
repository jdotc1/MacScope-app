import CryptoKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import MacScope

final class WorkspaceDocumentPublisherTests: XCTestCase {
    func testStageAndReaderRoundTripFileBackedReconstructionWithoutChangingState() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try reconstructionPackageFixture(
                name: "Reconstruction",
                byte: 0x09,
                in: parent
            )
            let publisher = WorkspaceDocumentPublisher()

            let staged = try await publisher.stage(fixture.payload, in: parent)
            let reopened = try MacScopeDocumentPackage.openPackage(from: staged.stagingURL)

            XCTAssertEqual(
                reopened.manifest.analysisFormatVersion,
                WorkspacePackageManifest.reconstructionFormatVersion
            )
            XCTAssertEqual(reopened.reconstructionState, fixture.payload.reconstructionState)
            XCTAssertEqual(reopened.reconstructionAttachmentSources.count, 1)
            XCTAssertEqual(
                reopened.reconstructionAttachmentSources.first?.contentIdentity,
                fixture.contentIdentity
            )
            XCTAssertEqual(
                try Data(contentsOf: try XCTUnwrap(
                    reopened.reconstructionAttachmentSources.first?.verifiedURL
                )),
                fixture.corpusBytes
            )

            let location = try WorkspaceDocumentLocation.canonicalized(from: staged.stagingURL)
            let validated = try await WorkspaceDocumentReader().readValidated(from: location)
            XCTAssertEqual(validated.reconstructionState, fixture.payload.reconstructionState)
            XCTAssertEqual(validated.reconstructionAttachmentSources.count, 1)
            XCTAssertEqual(
                validated.reconstructionAttachmentSources.first?.contentIdentity,
                fixture.contentIdentity
            )
        }
    }

    func testStageRejectsRevokedDescriptorBackedReconstructionSource() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try reconstructionPackageFixture(
                name: "Revoked Reconstruction",
                byte: 0x0a,
                in: parent
            )
            let vaultRoot = parent.appendingPathComponent("descriptor-vault", isDirectory: true)
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
            let payload = WorkspaceDocumentPackagePayload(
                documentID: fixture.payload.documentID,
                workspaceID: fixture.payload.workspaceID,
                manifestData: fixture.payload.manifestData,
                attachmentsByBinaryID: fixture.payload.attachmentsByBinaryID,
                reconstructionState: fixture.payload.reconstructionState,
                reconstructionAttachmentSources: [source],
                capturedMutationGeneration: fixture.payload.capturedMutationGeneration
            )
            authority.revoke()

            do {
                _ = try await WorkspaceDocumentPublisher().stage(payload, in: parent)
                XCTFail("A revoked sidecar attachment authority must not stage a package")
            } catch {
                XCTAssertEqual(
                    error as? ReconstructionSidecarAttachmentAuthorityError,
                    .revoked
                )
            }
            let stagedNames = try FileManager.default.contentsOfDirectory(atPath: parent.path)
                .filter { $0.hasPrefix(".macscope-stage-") }
            XCTAssertEqual(stagedNames, [])
        }
    }

    func testStageMaterializesAndReopensValidatedPayload() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Staged", byte: 0x11)
            let publisher = WorkspaceDocumentPublisher()

            let staged = try await publisher.stage(
                fixture.payload,
                in: parent
            )

            XCTAssertEqual(staged.capturedMutationGeneration, fixture.payload.capturedMutationGeneration)
            XCTAssertEqual(staged.stagedObservation.condition, .valid)
            XCTAssertEqual(staged.stagingURL.deletingLastPathComponent(), parent)
            XCTAssertTrue(staged.stagingURL.lastPathComponent.hasPrefix(".macscope-stage-"))
            let reopened = try MacScopeDocumentPackage.openPackage(from: staged.stagingURL)
            XCTAssertEqual(reopened.manifest.documentID, fixture.payload.documentID)
            XCTAssertEqual(reopened.manifest.workspaceUUID, fixture.payload.workspaceID)
            XCTAssertEqual(reopened.attachmentsByBinaryID, fixture.payload.attachmentsByBinaryID)
        }
    }

    func testAbsentDestinationIsCreatedExclusivelyAndReceiptUsesPostPublishObservation() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Created", byte: 0x22)
            let destinationURL = parent.appendingPathComponent("Created.mscope", isDirectory: true)
            let publisher = WorkspaceDocumentPublisher()
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            XCTAssertEqual(expected.condition, .absent)
            let staged = try await publisher.stage(fixture.payload, in: parent)

            let receipt = try await publisher.publish(
                staged,
                to: expected.location,
                expecting: expected
            )

            XCTAssertEqual(receipt.stagingID, staged.stagingID)
            XCTAssertEqual(receipt.priorObservation, expected)
            XCTAssertEqual(receipt.publishedObservation.condition, .valid)
            let observedAfterPublish = try await probe.observe(destinationURL)
            XCTAssertEqual(
                receipt.publishedObservation,
                observedAfterPublish
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingURL.path))
            let reopened = try MacScopeDocumentPackage.openPackage(from: destinationURL)
            XCTAssertEqual(reopened.attachmentsByBinaryID, fixture.payload.attachmentsByBinaryID)
        }
    }

    func testEmptyPackageDirectoryCreatedBySavePanelIsReplacedAndReceiptUsesCanonicalDestination() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Save Panel", byte: 0x23)
            let destinationURL = parent.appendingPathComponent(
                "Save Panel.mscope",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: false
            )
            let publisher = WorkspaceDocumentPublisher()
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            XCTAssertEqual(expected.condition, .invalid)
            let staged = try await publisher.stage(fixture.payload, in: parent)

            let receipt = try await publisher.publish(
                staged,
                to: expected.location,
                expecting: expected
            )

            XCTAssertEqual(receipt.priorObservation, expected)
            XCTAssertEqual(receipt.destination.canonicalURL, expected.location.canonicalURL)
            XCTAssertEqual(receipt.publishedObservation.condition, .valid)
            XCTAssertEqual(
                receipt.publishedObservation.location.canonicalURL,
                expected.location.canonicalURL
            )
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: destinationURL).manifest.workspaceName,
                "Save Panel"
            )
        }
    }

    func testExactBaselineCanBeAtomicallyReplaced() async throws {
        try await withTemporaryDirectory { parent in
            let original = try packageFixture(name: "Original", byte: 0x31)
            let replacement = try packageFixture(name: "Replacement", byte: 0x32)
            let destinationURL = parent.appendingPathComponent("Document.mscope", isDirectory: true)
            try write(fixture: original, to: destinationURL)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(replacement.payload, in: parent)

            let receipt = try await publisher.publish(
                staged,
                to: expected.location,
                expecting: expected
            )

            XCTAssertEqual(receipt.priorObservation, expected)
            XCTAssertNotEqual(receipt.publishedObservation.observationSHA256, expected.observationSHA256)
            let reopened = try MacScopeDocumentPackage.openPackage(from: destinationURL)
            XCTAssertEqual(reopened.manifest.workspaceName, "Replacement")
            XCTAssertEqual(reopened.attachmentsByBinaryID, replacement.payload.attachmentsByBinaryID)
        }
    }

    func testCancellationAtPublicationRenameBoundaryLeavesDestinationUnchanged() async throws {
        try await withTemporaryDirectory { parent in
            let original = try packageFixture(name: "Original", byte: 0x33)
            let replacement = try packageFixture(name: "Replacement", byte: 0x34)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            try write(fixture: original, to: destinationURL)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let cancellation = PublicationCancellationCheckpoint()
            let publisher = publisher(
                probe: probe,
                faults: PublicationFaultInjector(),
                beforeAtomicPublicationRename: cancellation.cancelCurrentTask
            )
            let staged = try await publisher.stage(replacement.payload, in: parent)

            let publication = Task {
                try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }
            let error = await capturedError {
                _ = try await publication.value
            }

            XCTAssertTrue(cancellation.didReachCheckpoint)
            XCTAssertTrue(error is CancellationError)
            let observedDestination = try await probe.observe(destinationURL)
            XCTAssertEqual(observedDestination, expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingURL.path))
            let reopened = try MacScopeDocumentPackage.openPackage(from: destinationURL)
            XCTAssertEqual(reopened.manifest.workspaceName, "Original")
            XCTAssertEqual(reopened.attachmentsByBinaryID, original.payload.attachmentsByBinaryID)
        }
    }

    func testCancellationAtExclusiveCreateRenameBoundaryLeavesDestinationAbsent() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Exclusive", byte: 0x35)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            XCTAssertEqual(expected.condition, .absent)
            let cancellation = PublicationCancellationCheckpoint()
            let publisher = publisher(
                probe: probe,
                faults: PublicationFaultInjector(),
                beforeAtomicPublicationRename: cancellation.cancelCurrentTask
            )
            let staged = try await publisher.stage(fixture.payload, in: parent)

            let publication = Task {
                try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }
            let error = await capturedError {
                _ = try await publication.value
            }

            XCTAssertTrue(cancellation.didReachCheckpoint)
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingURL.path))
        }
    }

    func testAlreadyCancelledPublishDiscardsOwnedStageAndAllowsSubsequentPublish() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Cancelled", byte: 0x36)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let publisher = WorkspaceDocumentPublisher()
            let abandonedStage = try await publisher.stage(fixture.payload, in: parent)

            let publication = Task {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                return try await publisher.publish(
                    abandonedStage,
                    to: expected.location,
                    expecting: expected
                )
            }
            let error = await capturedError {
                _ = try await publication.value
            }

            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: abandonedStage.stagingURL.path)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))

            let retryStage = try await publisher.stage(fixture.payload, in: parent)
            let receipt = try await publisher.publish(
                retryStage,
                to: expected.location,
                expecting: expected
            )
            XCTAssertEqual(receipt.publishedObservation.condition, .valid)
            XCTAssertFalse(FileManager.default.fileExists(atPath: retryStage.stagingURL.path))
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: destinationURL)
                    .manifest.workspaceName,
                "Cancelled"
            )
        }
    }

    func testReplacementParentSyncFailureRestoresPriorPackageAndSyncsRollback() async throws {
        try await withTemporaryDirectory { parent in
            let original = try packageFixture(name: "Original", byte: 0x35)
            let replacement = try packageFixture(name: "Replacement", byte: 0x36)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            try write(fixture: original, to: destinationURL)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let faults = PublicationFaultInjector(parentSyncFailures: [1])
            let publisher = publisher(probe: probe, faults: faults)
            let staged = try await publisher.stage(replacement.payload, in: parent)

            let error = await capturedError {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertEqual(
                error as? WorkspaceDocumentSessionError,
                .operationFailed("document-publish-parent-synchronization-failed")
            )
            XCTAssertEqual(faults.parentSyncAttempts, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingURL.path))
            let reopened = try MacScopeDocumentPackage.openPackage(from: destinationURL)
            XCTAssertEqual(reopened.manifest.workspaceName, "Original")
            XCTAssertEqual(reopened.attachmentsByBinaryID, original.payload.attachmentsByBinaryID)
        }
    }

    func testExclusiveCreateParentSyncFailureRollsBackAndSyncsAbsentNamespace() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Exclusive", byte: 0x37)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let faults = PublicationFaultInjector(parentSyncFailures: [1])
            let publisher = publisher(probe: probe, faults: faults)
            let staged = try await publisher.stage(fixture.payload, in: parent)

            let error = await capturedError {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertEqual(
                error as? WorkspaceDocumentSessionError,
                .operationFailed("document-publish-parent-synchronization-failed")
            )
            XCTAssertEqual(faults.parentSyncAttempts, 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingURL.path))
        }
    }

    func testRollbackRenameFailurePreservesAndReportsPriorPackageAtStage() async throws {
        try await withTemporaryDirectory { parent in
            let original = try packageFixture(name: "Recoverable Original", byte: 0x38)
            let replacement = try packageFixture(name: "Replacement", byte: 0x39)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            try write(fixture: original, to: destinationURL)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let faults = PublicationFaultInjector(
                parentSyncFailures: [1],
                rollbackRenameFails: true
            )
            let publisher = publisher(probe: probe, faults: faults)
            let staged = try await publisher.stage(replacement.payload, in: parent)

            let error = await capturedError {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertEqual(
                error as? WorkspaceDocumentSessionError,
                .operationFailed(
                    "document-publish-rollback-failed-recovery:\(staged.stagingURL.lastPathComponent)"
                )
            )
            XCTAssertEqual(faults.parentSyncAttempts, 1)
            XCTAssertEqual(faults.rollbackRenameAttempts, 1)
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: staged.stagingURL)
                    .manifest.workspaceName,
                "Recoverable Original"
            )
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: destinationURL)
                    .manifest.workspaceName,
                "Replacement"
            )
        }
    }

    func testRollbackParentSyncFailureReportsPriorPackageAtDestination() async throws {
        try await withTemporaryDirectory { parent in
            let original = try packageFixture(name: "Recoverable Original", byte: 0x3a)
            let replacement = try packageFixture(name: "Replacement", byte: 0x3b)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            try write(fixture: original, to: destinationURL)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let faults = PublicationFaultInjector(parentSyncFailures: [1, 2])
            let publisher = publisher(probe: probe, faults: faults)
            let staged = try await publisher.stage(replacement.payload, in: parent)

            let error = await capturedError {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertEqual(
                error as? WorkspaceDocumentSessionError,
                .operationFailed("document-publish-rollback-sync-failed-prior-at-destination")
            )
            XCTAssertEqual(faults.parentSyncAttempts, 2)
            XCTAssertEqual(faults.rollbackRenameAttempts, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagingURL.path))
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: destinationURL)
                    .manifest.workspaceName,
                "Recoverable Original"
            )
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: staged.stagingURL)
                    .manifest.workspaceName,
                "Replacement"
            )
        }
    }

    func testDestinationMutationAfterStagingRefusesReplacement() async throws {
        try await withTemporaryDirectory { parent in
            let original = try packageFixture(name: "Original", byte: 0x41)
            let replacement = try packageFixture(name: "Replacement", byte: 0x42)
            let external = try packageFixture(name: "External", byte: 0x43)
            let destinationURL = parent.appendingPathComponent("Document.mscope", isDirectory: true)
            try write(fixture: original, to: destinationURL)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(replacement.payload, in: parent)
            try write(fixture: external, to: destinationURL)

            await assertThrows {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            let reopened = try MacScopeDocumentPackage.openPackage(from: destinationURL)
            XCTAssertEqual(reopened.manifest.workspaceName, "External")
            XCTAssertEqual(reopened.attachmentsByBinaryID, external.payload.attachmentsByBinaryID)
        }
    }

    func testKeepLocalPublishCompareRejectsSameSizeMutationThroughHardLinkedV3Alias() async throws {
        try await withTemporaryDirectory { parent in
            let external = try reconstructionPackageFixture(
                name: "External",
                byte: 0x44,
                in: parent
            )
            let local = try packageFixture(name: "Local", byte: 0x45)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            try write(reconstructionFixture: external, to: destinationURL)
            let source = try XCTUnwrap(
                external.payload.reconstructionAttachmentSources.first
            )
            let corpusURL = try MacScopeDocumentPackage.reconstructionAttachmentURL(
                in: destinationURL,
                contentIdentity: source.contentIdentity
            )
            try FileManager.default.removeItem(at: corpusURL)
            try FileManager.default.linkItem(at: source.verifiedURL, to: corpusURL)

            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            XCTAssertEqual(expected.condition, .invalid)
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(local.payload, in: parent)

            let mutatedBytes = Data(repeating: 0x6b, count: external.corpusBytes.count)
            let handle = try FileHandle(forWritingTo: source.verifiedURL)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: mutatedBytes)
            try handle.synchronize()
            try handle.close()
            let externallyMutated = try await probe.observe(destinationURL)
            XCTAssertEqual(externallyMutated.condition, .invalid)
            XCTAssertNotEqual(externallyMutated.observationSHA256, expected.observationSHA256)

            await assertThrows {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertEqual(try Data(contentsOf: corpusURL), mutatedBytes)
            let observedAfterRefusal = try await probe.observe(destinationURL)
            XCTAssertEqual(observedAfterRefusal, externallyMutated)
        }
    }

    func testDestinationCreationRaceRefusesExclusiveCreate() async throws {
        try await withTemporaryDirectory { parent in
            let local = try packageFixture(name: "Local", byte: 0x51)
            let external = try packageFixture(name: "External", byte: 0x52)
            let destinationURL = parent.appendingPathComponent("Document.mscope", isDirectory: true)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(local.payload, in: parent)
            try write(fixture: external, to: destinationURL)

            await assertThrows {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            let reopened = try MacScopeDocumentPackage.openPackage(from: destinationURL)
            XCTAssertEqual(reopened.manifest.workspaceName, "External")
            XCTAssertEqual(reopened.attachmentsByBinaryID, external.payload.attachmentsByBinaryID)
        }
    }

    func testEquivalentRuntimeAuthoritySerializationStagesAndPublishesExactWriterBytes() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Runtime Authority", byte: 0x60)
            var manifest = fixture.manifest
            manifest.runtimeAuthorityRecords = [WorkspacePackageRuntimeAuthorityRecord(
                id: UUID(), sessionID: UUID(),
                surfaces: [.terminalEmulation, .shellBrokerPTYReuse, .debuggerReadOnly],
                terminalBackend: .ghosttyLib, ptyReusePolicy: .shellBrokerSession,
                debuggerAuthorityPolicy: .readOnlyInspection,
                providerVisibleShellExecutionEnabled: false,
                createdAt: Date(timeIntervalSince1970: 1_800_100_002)
            )]
            // A valid alternate serialization makes the writer's byte transformation
            // deterministic, without relying on randomized Set iteration order.
            let payloadData = Data("\n".utf8) + (try MacScopeDocumentPackage.encodedManifest(manifest))
            let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
            let encodedRecords = try XCTUnwrap(encodedObject["runtimeAuthorityRecords"] as? [[String: Any]])
            XCTAssertEqual(encodedRecords.first?["surfaces"] as? [String],
                           ["debuggerReadOnly", "shellBrokerPTYReuse", "terminalEmulation"])
            let payload = WorkspaceDocumentPackagePayload(
                documentID: fixture.payload.documentID,
                workspaceID: fixture.payload.workspaceID,
                manifestData: payloadData,
                attachmentsByBinaryID: fixture.payload.attachmentsByBinaryID,
                capturedMutationGeneration: fixture.payload.capturedMutationGeneration
            )
            let destination = parent.appendingPathComponent("Runtime Authority.mscope", isDirectory: true)
            let expected = try await WorkspacePackageVersionProbe().observe(destination)
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(payload, in: parent)
            let stagedData = try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: staged.stagingURL))
            XCTAssertNotEqual(stagedData, payloadData)
            let written = try MacScopeDocumentPackage.validatedManifest(manifestData: stagedData)
            XCTAssertEqual(written.documentID, manifest.documentID)
            XCTAssertEqual(written.workspaceUUID, manifest.workspaceUUID)
            XCTAssertEqual(written.runtimeAuthorityRecords, manifest.runtimeAuthorityRecords)
            let firstObservation = try await WorkspacePackageVersionProbe().observe(staged.stagingURL)
            let repeatedObservation = try await WorkspacePackageVersionProbe().observe(staged.stagingURL)
            XCTAssertEqual(firstObservation, repeatedObservation,
                           "unchanged package bytes must have stable validated-content digests")
            XCTAssertEqual(firstObservation, staged.stagedObservation)
            _ = try await publisher.publish(staged, to: expected.location, expecting: expected)
            XCTAssertEqual(try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: destination)), stagedData)
            let reopened = try MacScopeDocumentPackage.openPackage(from: destination)
            XCTAssertEqual(reopened.manifest.runtimeAuthorityRecords, manifest.runtimeAuthorityRecords)
        }
    }

    func testStageIgnoresOnlyUnpersistedPristineCatalogIdentity() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Pristine Catalog", byte: 0x5e)
            let first = try MacScopeDocumentPackage.validatedManifest(manifestData: fixture.payload.manifestData)
            let second = try MacScopeDocumentPackage.validatedManifest(manifestData: fixture.payload.manifestData)
            let firstAnalysis = try XCTUnwrap(first.analysis)
            let secondAnalysis = try XCTUnwrap(second.analysis)
            XCTAssertTrue(firstAnalysis.logicalBreakpointCatalog.isPristine)
            XCTAssertTrue(secondAnalysis.logicalBreakpointCatalog.isPristine)
            XCTAssertNotEqual(firstAnalysis.logicalBreakpointCatalog.catalogID,
                              secondAnalysis.logicalBreakpointCatalog.catalogID)
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(fixture.payload, in: parent)
            let reopened = try MacScopeDocumentPackage.openPackage(from: staged.stagingURL)
            XCTAssertEqual(reopened.manifest.documentID, fixture.manifest.documentID)
            XCTAssertEqual(reopened.attachmentsByBinaryID, fixture.payload.attachmentsByBinaryID)
            await publisher.discard(staged)
        }
    }

    func testEquivalentManifestRewriteAfterStagingIsStillRejected() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Changed Bytes", byte: 0x5f)
            let destination = parent.appendingPathComponent("Changed Bytes.mscope", isDirectory: true)
            let expected = try await WorkspacePackageVersionProbe().observe(destination)
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(fixture.payload, in: parent)
            let url = MacScopeDocumentPackage.manifestURL(in: staged.stagingURL)
            try (Data("\n".utf8) + Data(contentsOf: url)).write(to: url, options: .atomic)
            await assertThrows {
                _ = try await publisher.publish(staged, to: expected.location, expecting: expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testInvalidatedStageCannotPublish() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Local", byte: 0x61)
            let destinationURL = parent.appendingPathComponent("Document.mscope", isDirectory: true)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let publisher = WorkspaceDocumentPublisher()
            let staged = try await publisher.stage(fixture.payload, in: parent)
            try Data("{}".utf8).write(
                to: MacScopeDocumentPackage.manifestURL(in: staged.stagingURL),
                options: .atomic
            )

            await assertThrows {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        }
    }

    func testFailedPostPublishObservationRollsBackExclusiveCreate() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Rollback", byte: 0x68)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            let mutation = PostPublishManifestMutation(
                destinationURL: destinationURL
            )
            let probe = WorkspacePackageVersionProbe(
                beforeReadingRelativePath: { relativePath in
                    mutation.mutateOnceWhenPublished(relativePath: relativePath)
                }
            )
            let expected = try await probe.observe(destinationURL)
            let faults = PublicationFaultInjector()
            let publisher = publisher(probe: probe, faults: faults)
            let staged = try await publisher.stage(fixture.payload, in: parent)

            await assertThrows {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertTrue(mutation.didMutate)
            // The invalid publication is rejected before its durability barrier; only the
            // compensating rollback synchronizes the destination parent.
            XCTAssertEqual(faults.parentSyncAttempts, 1)
            XCTAssertEqual(faults.rollbackRenameAttempts, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staged.stagingURL.path))
        }
    }

    func testReplacementCleanupRefusesAnAlreadyObservedForeignStageRoot() async throws {
        try await withTemporaryDirectory { parent in
            let original = try packageFixture(name: "Original", byte: 0x69)
            let replacement = try packageFixture(name: "Replacement", byte: 0x6a)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            try write(fixture: original, to: destinationURL)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let substitution = RetiredPackageSubstitution()
            let publisher = publisher(
                probe: probe,
                faults: PublicationFaultInjector(),
                beforeRetiredPackageCleanup: substitution.replaceWithForeignRoot
            )
            let staged = try await publisher.stage(replacement.payload, in: parent)
            substitution.configure(stagingURL: staged.stagingURL)

            let error = await capturedError {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertEqual(
                error as? WorkspaceDocumentSessionError,
                .operationFailed(
                    "document-publish-cleanup-ownership-unproven-recovery:\(staged.stagingURL.lastPathComponent)"
                )
            )
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: destinationURL)
                    .manifest.workspaceName,
                "Replacement"
            )
            XCTAssertEqual(
                try Data(contentsOf: staged.stagingURL.appendingPathComponent("foreign.txt")),
                Data("foreign".utf8)
            )
        }
    }

    func testReplacementCleanupHookFailureRetainsPriorPackageAtRecoveryStage() async throws {
        struct InjectedCleanupFailure: Error {}

        try await withTemporaryDirectory { parent in
            let original = try packageFixture(name: "Original", byte: 0x6b)
            let replacement = try packageFixture(name: "Replacement", byte: 0x6c)
            let destinationURL = parent.appendingPathComponent(
                "Document.mscope",
                isDirectory: true
            )
            try write(fixture: original, to: destinationURL)
            let probe = WorkspacePackageVersionProbe()
            let expected = try await probe.observe(destinationURL)
            let publisher = publisher(
                probe: probe,
                faults: PublicationFaultInjector(),
                beforeRetiredPackageCleanup: { throw InjectedCleanupFailure() }
            )
            let staged = try await publisher.stage(replacement.payload, in: parent)

            let error = await capturedError {
                _ = try await publisher.publish(
                    staged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertEqual(
                error as? WorkspaceDocumentSessionError,
                .operationFailed(
                    "document-publish-cleanup-failed-recovery:\(staged.stagingURL.lastPathComponent)"
                )
            )
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: destinationURL)
                    .manifest.workspaceName,
                "Replacement"
            )
            XCTAssertEqual(
                try MacScopeDocumentPackage.openPackage(from: staged.stagingURL)
                    .manifest.workspaceName,
                "Original"
            )
        }
    }

    func testForgedStageCannotDeleteOrMoveUnownedContent() async throws {
        try await withTemporaryDirectory { parent in
            let outside = parent.appendingPathComponent("user-owned", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let marker = outside.appendingPathComponent("marker.txt")
            try Data("preserve".utf8).write(to: marker)
            let destinationURL = parent.appendingPathComponent("Document.mscope", isDirectory: true)
            let expected = try await WorkspacePackageVersionProbe().observe(destinationURL)
            let forged = WorkspaceDocumentStagedPackage(
                stagingID: UUID(),
                stagingURL: outside,
                stagedObservation: expected,
                capturedMutationGeneration: WorkspaceDocumentMutationGeneration(rawValue: 1)
            )
            let publisher = WorkspaceDocumentPublisher()

            await assertThrows {
                _ = try await publisher.publish(
                    forged,
                    to: expected.location,
                    expecting: expected
                )
            }

            XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    func testReaderReturnsBytesBoundToAValidObservation() async throws {
        try await withTemporaryDirectory { parent in
            let fixture = try packageFixture(name: "Read", byte: 0x71)
            let packageURL = parent.appendingPathComponent("Read.mscope", isDirectory: true)
            try write(fixture: fixture, to: packageURL)
            let location = try WorkspaceDocumentLocation.canonicalized(from: packageURL)

            let validated = try await WorkspaceDocumentReader().readValidated(from: location)

            XCTAssertEqual(validated.observation.condition, .valid)
            XCTAssertEqual(validated.attachmentsByBinaryID, fixture.payload.attachmentsByBinaryID)
            let decoded = try MacScopeDocumentPackage.validatedContents(
                manifestData: validated.manifestData,
                attachmentsByBinaryID: validated.attachmentsByBinaryID,
                instructionSidecarData: validated.instructionSidecarData
            )
            XCTAssertEqual(decoded.manifest.documentID, fixture.payload.documentID)
            XCTAssertEqual(decoded.manifest.workspaceUUID, fixture.payload.workspaceID)
        }
    }

    private struct Fixture {
        let manifest: WorkspacePackageManifest
        let payload: WorkspaceDocumentPackagePayload
    }

    private struct ReconstructionFixture {
        let payload: WorkspaceDocumentPackagePayload
        let contentIdentity: ReconstructionContentIdentity
        let corpusBytes: Data
    }

    private func packageFixture(name: String, byte: UInt8) throws -> Fixture {
        let documentID = UUID()
        let workspaceID = UUID()
        let binaryID = UUID()
        let data = Data([byte, byte &+ 1, byte &+ 2])
        let binary = WorkspacePackageBinary(
            id: binaryID,
            displayName: name,
            originalPath: "/fixtures/\(name).bin",
            attachmentRelativePath:
                "attachments/\(binaryID.uuidString.lowercased())/\(name).bin",
            kind: "Raw data",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: data),
            fileSize: Int64(data.count)
        )
        let manifest = WorkspacePackageManifest(
            documentID: documentID,
            workspaceUUID: workspaceID,
            workspaceName: name,
            createdAt: Date(timeIntervalSince1970: 1_800_100_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_100_001),
            binaries: [binary],
            analysis: WorkspacePackageAnalysis(),
            session: nil
        )
        return Fixture(
            manifest: manifest,
            payload: WorkspaceDocumentPackagePayload(
                documentID: documentID,
                workspaceID: workspaceID,
                manifestData: try MacScopeDocumentPackage.encodedManifest(manifest),
                attachmentsByBinaryID: [binaryID: data],
                capturedMutationGeneration: WorkspaceDocumentMutationGeneration(rawValue: 7)
            )
        )
    }

    private func reconstructionPackageFixture(
        name: String,
        byte: UInt8,
        in directory: URL
    ) throws -> ReconstructionFixture {
        let legacy = try packageFixture(name: name, byte: byte)
        let corpusBytes = Data("immutable reconstruction corpus".utf8)
        let sourceURL = directory.appendingPathComponent("reconstruction-source.bin")
        try corpusBytes.write(to: sourceURL)
        let contentIdentity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: SHA256.hash(data: corpusBytes)
                .map { String(format: "%02x", $0) }
                .joined(),
            byteCount: UInt64(corpusBytes.count)
        )
        let projectID = UUID()
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: UUID()),
            contentIdentity: contentIdentity,
            kind: .opaque,
            roles: [.primaryTarget],
            executableMode: false,
            originalName: "reconstruction-source.bin",
            diagnostic: nil
        )
        let corpusManifestSHA256 = try ReconstructionCorpusCanonicalizer.canonicalSHA256(
            reconstructionProjectID: projectID,
            artifacts: [occurrence],
            relations: []
        )
        let corpusManifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: projectID,
            artifacts: [occurrence],
            relations: [],
            canonicalSHA256: corpusManifestSHA256
        )
        let state = try ReconstructionWorkspaceState(
            projects: [
                try ReconstructionProjectRecord(
                    projectID: projectID,
                    name: "Publisher reconstruction",
                    currentCorpusManifestSHA256: corpusManifest.canonicalSHA256
                ),
            ],
            corpusManifests: [corpusManifest],
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: [],
            tasks: [],
            checkpoints: [],
            toolReceipts: [],
            modelReceipts: []
        )
        let manifest = try MacScopeDocumentPackage.preparedManifest(
            legacy.manifest,
            reconstructionState: state
        )
        return ReconstructionFixture(
            payload: WorkspaceDocumentPackagePayload(
                documentID: legacy.payload.documentID,
                workspaceID: legacy.payload.workspaceID,
                manifestData: try MacScopeDocumentPackage.encodedManifest(manifest),
                attachmentsByBinaryID: legacy.payload.attachmentsByBinaryID,
                reconstructionState: state,
                reconstructionAttachmentSources: [
                    ReconstructionAttachmentSource(
                        contentIdentity: contentIdentity,
                        verifiedURL: sourceURL
                    ),
                ],
                capturedMutationGeneration: legacy.payload.capturedMutationGeneration
            ),
            contentIdentity: contentIdentity,
            corpusBytes: corpusBytes
        )
    }

    private func write(fixture: Fixture, to url: URL) throws {
        try MacScopeDocumentPackage.writePackage(
            fixture.manifest,
            attachmentsByBinaryID: fixture.payload.attachmentsByBinaryID,
            to: url
        )
    }

    private func write(
        reconstructionFixture fixture: ReconstructionFixture,
        to url: URL
    ) throws {
        try MacScopeDocumentPackage.writePackage(
            try MacScopeDocumentPackage.validatedManifest(
                manifestData: fixture.payload.manifestData
            ),
            attachmentsByBinaryID: fixture.payload.attachmentsByBinaryID,
            reconstructionState: fixture.payload.reconstructionState,
            reconstructionAttachmentSources: fixture.payload.reconstructionAttachmentSources,
            to: url
        )
    }

    private func publisher(
        probe: WorkspacePackageVersionProbe,
        faults: PublicationFaultInjector,
        beforeAtomicPublicationRename: @escaping @Sendable () -> Void = {},
        beforeRetiredPackageCleanup: @escaping @Sendable () throws -> Void = {}
    ) -> WorkspaceDocumentPublisher {
        WorkspaceDocumentPublisher(
            probe: probe,
            beforeParentDirectorySynchronization: faults.beforeParentSynchronization,
            beforeRollbackRename: faults.beforeRollbackRename,
            beforeAtomicPublicationRename: beforeAtomicPublicationRename,
            beforeRetiredPackageCleanup: beforeRetiredPackageCleanup
        )
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceDocumentPublisherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        try await operation(url)
    }

    private func assertThrows(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            // Expected.
        }
    }

    private func capturedError(
        _ operation: () async throws -> Void
    ) async -> Error? {
        do {
            try await operation()
            return nil
        } catch {
            return error
        }
    }
}

private final class PublicationCancellationCheckpoint: Sendable {
    private let reached = Mutex(false)

    var didReachCheckpoint: Bool {
        reached.withLock { $0 }
    }

    func cancelCurrentTask() {
        reached.withLock { $0 = true }
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
    }
}

private enum InjectedPublicationFault: Error {
    case parentSynchronization
    case rollbackRename
}

private final class PublicationFaultInjector: Sendable {
    private struct State: Sendable {
        var parentSyncAttempts = 0
        var rollbackRenameAttempts = 0
    }

    private let state = Mutex(State())
    private let parentSyncFailures: Set<Int>
    private let rollbackRenameFails: Bool

    init(
        parentSyncFailures: Set<Int> = [],
        rollbackRenameFails: Bool = false
    ) {
        self.parentSyncFailures = parentSyncFailures
        self.rollbackRenameFails = rollbackRenameFails
    }

    var parentSyncAttempts: Int {
        state.withLock { $0.parentSyncAttempts }
    }

    var rollbackRenameAttempts: Int {
        state.withLock { $0.rollbackRenameAttempts }
    }

    func beforeParentSynchronization() throws {
        let attempt = state.withLock { state in
            state.parentSyncAttempts += 1
            return state.parentSyncAttempts
        }
        if parentSyncFailures.contains(attempt) {
            throw InjectedPublicationFault.parentSynchronization
        }
    }

    func beforeRollbackRename() throws {
        state.withLock { $0.rollbackRenameAttempts += 1 }
        if rollbackRenameFails {
            throw InjectedPublicationFault.rollbackRename
        }
    }
}

private final class PostPublishManifestMutation: Sendable {
    private let destinationURL: URL
    private let mutated = Mutex(false)

    init(destinationURL: URL) {
        self.destinationURL = destinationURL
    }

    var didMutate: Bool {
        mutated.withLock { $0 }
    }

    func mutateOnceWhenPublished(relativePath: String) {
        guard relativePath == MacScopeDocumentPackage.manifestFileName,
              FileManager.default.fileExists(atPath: destinationURL.path) else {
            return
        }
        mutated.withLock {
            guard !$0 else { return }
            $0 = true
            try? Data("{}".utf8).write(
                to: MacScopeDocumentPackage.manifestURL(in: destinationURL),
                options: .atomic
            )
        }
    }
}

private final class RetiredPackageSubstitution: Sendable {
    private let stagingURL = Mutex<URL?>(nil)

    func configure(stagingURL: URL) {
        self.stagingURL.withLock { $0 = stagingURL }
    }

    func replaceWithForeignRoot() throws {
        let url = try XCTUnwrap(stagingURL.withLock { $0 })
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        try Data("foreign".utf8).write(to: url.appendingPathComponent("foreign.txt"))
    }
}
