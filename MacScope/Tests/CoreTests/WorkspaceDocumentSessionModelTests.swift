import Foundation
import XCTest
@testable import MacScope

final class WorkspaceDocumentSessionModelTests: XCTestCase {
    private let sessionID = WorkspaceDocumentSessionID(
        rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
    private let documentID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let workspaceID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!

    func testLifecyclePresentationCoversUntitledCleanAndDirtyStates() {
        XCTAssertEqual(snapshot(hasLocation: false).lifecyclePresentationState, .untitled)
        XCTAssertEqual(snapshot(hasUnsavedChanges: false).lifecyclePresentationState, .clean)
        XCTAssertEqual(snapshot(hasUnsavedChanges: true).lifecyclePresentationState, .dirty)
    }

    func testLifecyclePresentationPreservesRequiredPrecedence() {
        let conflict = conflict(reason: .externallyChanged)
        let activeSave = WorkspaceDocumentActiveSave(
            requestID: .init(rawValue: UUID()),
            saveGeneration: .init(rawValue: 4),
            capturedMutationGeneration: .init(rawValue: 9),
            intent: .save
        )

        XCTAssertEqual(
            snapshot(
                hasLocation: false,
                hasUnsavedChanges: true,
                activeSave: activeSave,
                conflict: conflict,
                lastFailure: "ignored"
            ).lifecyclePresentationState,
            .untitled
        )
        XCTAssertEqual(
            snapshot(
                hasUnsavedChanges: true,
                activeSave: activeSave,
                conflict: conflict,
                lastFailure: "ignored"
            ).lifecyclePresentationState,
            .conflicted(.externallyChanged)
        )
        XCTAssertEqual(
            snapshot(
                hasUnsavedChanges: true,
                activeSave: activeSave,
                lastFailure: "ignored"
            ).lifecyclePresentationState,
            .saving
        )
    }

    func testLifecycleFailureRetainsIndependentDirtyProjection() {
        XCTAssertEqual(
            snapshot(hasUnsavedChanges: true, lastFailure: "save-failed")
                .lifecyclePresentationState,
            .failed("save-failed", hasUnsavedChanges: true)
        )
        XCTAssertEqual(
            snapshot(hasUnsavedChanges: false, lastFailure: "save-failed")
                .lifecyclePresentationState,
            .failed("save-failed", hasUnsavedChanges: false)
        )
    }

    func testMutationAndSaveGenerationsAdvanceWithoutSignedConversion() throws {
        XCTAssertEqual(
            try WorkspaceDocumentMutationGeneration(rawValue: 0).next(),
            .init(rawValue: 1)
        )
        XCTAssertEqual(
            try WorkspaceDocumentMutationGeneration(rawValue: UInt64.max - 1).next(),
            .init(rawValue: UInt64.max)
        )
        XCTAssertEqual(
            try WorkspaceDocumentSaveGeneration(rawValue: 41).next(),
            .init(rawValue: 42)
        )
        XCTAssertEqual(
            try WorkspaceDocumentSaveGeneration(rawValue: UInt64.max - 1).next(),
            .init(rawValue: UInt64.max)
        )
    }

    func testGenerationExhaustionFailsClosed() {
        assertGenerationExhaustion {
            _ = try WorkspaceDocumentMutationGeneration(rawValue: UInt64.max).next()
        }
        assertGenerationExhaustion {
            _ = try WorkspaceDocumentSaveGeneration(rawValue: UInt64.max).next()
        }
    }

    func testCanonicalLocationRejectsNonFileURL() {
        XCTAssertThrowsError(
            try WorkspaceDocumentLocation.canonicalized(
                from: URL(string: "https://example.invalid/workspace.mscope")!
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDocumentSessionError,
                .operationFailed("document-location-not-file-url")
            )
        }
    }

    func testCanonicalLocationResolvesSymlinkAndCapturesExistingIdentity() throws {
        try withTemporaryDirectory { directory in
            let target = directory.appendingPathComponent("target.mscope")
            let alias = directory.appendingPathComponent("alias.mscope")
            try Data("package".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

            let canonicalTarget = try WorkspaceDocumentLocation.canonicalized(from: target)
            let canonicalAlias = try WorkspaceDocumentLocation.canonicalized(from: alias)

            XCTAssertEqual(canonicalAlias.canonicalURL, canonicalTarget.canonicalURL)
            XCTAssertEqual(canonicalAlias.fileObjectIdentity, canonicalTarget.fileObjectIdentity)
            XCTAssertNotNil(canonicalAlias.fileObjectIdentity)
        }
    }

    func testCanonicalLocationLeavesAbsentDestinationWithoutPhysicalIdentity() throws {
        try withTemporaryDirectory { directory in
            let absent = directory
                .appendingPathComponent("folder")
                .appendingPathComponent("../new-workspace.mscope")

            let location = try WorkspaceDocumentLocation.canonicalized(from: absent)

            XCTAssertEqual(
                location.canonicalURL,
                directory.appendingPathComponent("new-workspace.mscope").standardizedFileURL
            )
            XCTAssertNil(location.fileObjectIdentity)
        }
    }

    func testCanonicalLocationRemainsStableWhenSavePanelFileURLBecomesPackageDirectory() throws {
        try withTemporaryDirectory { directory in
            let savePanelURL = directory.appendingPathComponent(
                "New Workspace.mscope",
                isDirectory: false
            )
            let beforeCreation = try WorkspaceDocumentLocation.canonicalized(
                from: savePanelURL
            )
            XCTAssertNil(beforeCreation.fileObjectIdentity)

            try FileManager.default.createDirectory(
                at: savePanelURL,
                withIntermediateDirectories: false
            )
            let afterCreation = try WorkspaceDocumentLocation.canonicalized(
                from: savePanelURL
            )

            XCTAssertEqual(afterCreation.canonicalURL, beforeCreation.canonicalURL)
            XCTAssertNotNil(afterCreation.fileObjectIdentity)
        }
    }

    func testHardLinksSharePhysicalIdentityWithoutSharingCanonicalPath() throws {
        try withTemporaryDirectory { directory in
            let first = directory.appendingPathComponent("first.mscope")
            let second = directory.appendingPathComponent("second.mscope")
            try Data("package".utf8).write(to: first)
            try FileManager.default.linkItem(at: first, to: second)

            let firstLocation = try WorkspaceDocumentLocation.canonicalized(from: first)
            let secondLocation = try WorkspaceDocumentLocation.canonicalized(from: second)

            XCTAssertNotEqual(firstLocation.canonicalURL, secondLocation.canonicalURL)
            XCTAssertEqual(firstLocation.fileObjectIdentity, secondLocation.fileObjectIdentity)
            XCTAssertNotNil(firstLocation.fileObjectIdentity)
        }
    }

    func testFrozenIntentOutcomeTransferAndOpenValuesRetainAuthorityInputs() {
        let location = location()
        let externalVersion = version(at: location)
        let payload = WorkspaceDocumentPackagePayload(
            documentID: documentID,
            workspaceID: workspaceID,
            manifestData: Data("manifest".utf8),
            attachmentsByBinaryID: [documentID: Data()],
            instructionSidecarData: Data("instructions".utf8),
            capturedMutationGeneration: .init(rawValue: 8)
        )
        let staged = WorkspaceDocumentStagedPackage(
            stagingID: UUID(),
            stagingURL: URL(fileURLWithPath: "/tmp/staging.mscope"),
            stagedObservation: externalVersion,
            capturedMutationGeneration: payload.capturedMutationGeneration
        )
        let receipt = WorkspaceDocumentPublishReceipt(
            stagingID: staged.stagingID,
            destination: location,
            priorObservation: externalVersion,
            publishedObservation: externalVersion
        )
        let request = WorkspaceOpenRequest(
            url: location.canonicalURL,
            source: .automation,
            preferredReusableWindow: .primary
        )

        XCTAssertEqual(WorkspaceDocumentWriteIntent.saveAs(adopting: location), .saveAs(adopting: location))
        XCTAssertEqual(WorkspaceDocumentWriteOutcome.copied(location), .copied(location))
        XCTAssertEqual(receipt.stagingID, staged.stagingID)
        XCTAssertEqual(payload.attachmentsByBinaryID[documentID], Data())
        XCTAssertEqual(payload.instructionSidecarData, Data("instructions".utf8))
        let validated = WorkspaceDocumentValidatedPackage(
            manifestData: payload.manifestData, attachmentsByBinaryID: payload.attachmentsByBinaryID,
            instructionSidecarData: payload.instructionSidecarData, observation: externalVersion
        )
        XCTAssertEqual(validated.instructionSidecarData, payload.instructionSidecarData)
        XCTAssertEqual(request.source, .automation)
        XCTAssertEqual(request.preferredReusableWindow, .primary)
        XCTAssertEqual(WorkspaceOpenDisposition.activatedExisting(.primary), .activatedExisting(.primary))
        XCTAssertEqual(
            WorkspaceDocumentLocationReservationResult.alreadyOwned(.primary),
            .alreadyOwned(.primary)
        )
    }

    private func snapshot(
        hasLocation: Bool = true,
        hasUnsavedChanges: Bool = false,
        activeSave: WorkspaceDocumentActiveSave? = nil,
        conflict: WorkspaceDocumentConflict? = nil,
        lastFailure: String? = nil
    ) -> WorkspaceDocumentSessionSnapshot {
        let resolvedLocation = location()
        return WorkspaceDocumentSessionSnapshot(
            sessionID: sessionID,
            documentID: documentID,
            workspaceID: workspaceID,
            location: hasLocation ? resolvedLocation : nil,
            expectedExternalVersion: hasLocation ? version(at: resolvedLocation) : nil,
            mutationGeneration: .init(rawValue: 9),
            savedMutationGeneration: .init(rawValue: 7),
            hasUnsavedChanges: hasUnsavedChanges,
            nextSaveGeneration: .init(rawValue: 4),
            activeSave: activeSave,
            conflict: conflict,
            lastFailure: lastFailure
        )
    }

    private func location() -> WorkspaceDocumentLocation {
        WorkspaceDocumentLocation(
            canonicalURL: URL(fileURLWithPath: "/tmp/current.mscope"),
            fileObjectIdentity: .init(device: 1, inode: 2)
        )
    }

    private func version(at location: WorkspaceDocumentLocation) -> WorkspacePackageExternalVersion {
        WorkspacePackageExternalVersion(
            location: location,
            condition: .valid,
            observationSHA256: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64),
            validatedContentSHA256: String(repeating: "c", count: 64),
            boundedReason: nil
        )
    }

    private func conflict(reason: WorkspaceDocumentConflictReason) -> WorkspaceDocumentConflict {
        let location = location()
        let expected = version(at: location)
        let observed = WorkspacePackageExternalVersion(
            location: location,
            condition: .invalid,
            observationSHA256: String(repeating: "d", count: 64),
            manifestSHA256: nil,
            validatedContentSHA256: nil,
            boundedReason: "changed"
        )
        return WorkspaceDocumentConflict(expected: expected, observed: observed, reason: reason)
    }

    private func assertGenerationExhaustion(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? WorkspaceDocumentSessionError,
                .operationFailed("document-generation-exhausted"),
                file: file,
                line: line
            )
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceDocumentSessionModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }
}
