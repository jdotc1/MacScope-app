import Foundation
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceDocumentContentSourceTests: XCTestCase {
    private final class SpyRecents: WorkspaceRecentsRecording {
        private(set) var notedURLs: [URL] = []

        func noteRecentDocument(_ url: URL) {
            notedURLs.append(url)
        }

        var recentDocumentURLs: [URL] { notedURLs }

        func clearRecentDocuments() {
            notedURLs.removeAll()
        }
    }

    private let documentID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let workspaceID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let primaryBinaryID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
    private let secondaryBinaryID = UUID(uuidString: "30000000-0000-4000-8000-000000000002")!
    private let primaryBytes = Data([0x10, 0x20, 0x30, 0x40])
    private let secondaryBytes = Data([0x50, 0x60, 0x70, 0x80])

    func testMutationGenerationAdvancesAcrossEditUndoAndRedoWhileDirtyTruthRewinds() {
        let store = makeStore()
        let source: any WorkspaceDocumentContentSource = store

        XCTAssertEqual(source.mutationGeneration.rawValue, 0)
        XCTAssertFalse(source.hasUnsavedChanges)

        store.setCustomName(0x1000, name: "renamed")
        XCTAssertEqual(source.mutationGeneration.rawValue, 1)
        XCTAssertTrue(source.hasUnsavedChanges)
        let generationAfterEdit = source.mutationGeneration

        store.undoManager.undo()
        XCTAssertGreaterThan(source.mutationGeneration, generationAfterEdit)
        XCTAssertFalse(source.hasUnsavedChanges)
        let generationAfterUndo = source.mutationGeneration

        store.undoManager.redo()
        XCTAssertGreaterThan(source.mutationGeneration, generationAfterUndo)
        XCTAssertTrue(source.hasUnsavedChanges)
    }

    func testPackagePayloadUsesLogicalIDsExactAttachmentBytesAndRestoresScratchMetadata() throws {
        let store = makeStore()
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let persisted = try store.saveWorkspace(to: database)
        let priorPersistedID = try XCTUnwrap(persisted.workspace.id)
        XCTAssertEqual(store.persistedWorkspaceID, priorPersistedID)

        let payload = try store.makePackagePayload()
        let contents = try MacScopeDocumentPackage.validatedContents(
            manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID,
            instructionSidecarData: payload.instructionSidecarData
        )

        XCTAssertEqual(payload.documentID, documentID)
        XCTAssertEqual(payload.workspaceID, workspaceID)
        XCTAssertEqual(payload.capturedMutationGeneration, store.mutationGeneration)
        XCTAssertEqual(payload.attachmentsByBinaryID, [primaryBinaryID: primaryBytes])
        XCTAssertEqual(contents.manifest.documentID, documentID)
        XCTAssertEqual(contents.manifest.workspaceUUID, workspaceID)
        XCTAssertEqual(contents.manifest.formatVersion, WorkspacePackageManifest.instructionSidecarFormatVersion)
        XCTAssertEqual(contents.snapshot.imageBytes, primaryBytes)
        XCTAssertEqual(store.persistedWorkspaceID, priorPersistedID)
    }

    func testAcceptingCapturedWriteDoesNotClearMutationThatLandedDuringCapture() throws {
        let store = makeStore()
        store.setCustomName(0x1000, name: "captured")
        let payload = try store.makePackagePayload()

        store.setCustomComment(0x1000, comment: "newer")
        XCTAssertGreaterThan(store.mutationGeneration, payload.capturedMutationGeneration)

        store.acceptPublishedWrite(
            capturedGeneration: payload.capturedMutationGeneration,
            adopting: nil
        )

        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customName, "captured")
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customComment, "newer")
    }

    func testAcceptedWriteAdoptsOnlyExactLocationAndRecordsRecentDocument() throws {
        let store = makeStore()
        let recents = SpyRecents()
        store.recents = recents
        store.setCustomName(0x1000, name: "saved")
        let payload = try store.makePackagePayload()
        let location = try makeLocation(named: "Adopted.mscope")

        store.acceptPublishedWrite(
            capturedGeneration: payload.capturedMutationGeneration,
            adopting: location
        )

        XCTAssertEqual(store.documentURL, location.canonicalURL)
        XCTAssertEqual(recents.notedURLs, [location.canonicalURL])
        XCTAssertFalse(store.hasUnsavedChanges)
    }

    func testPayloadCaptureForSaveCopyDoesNotAdoptOrClearDirtyState() throws {
        let store = makeStore()
        let original = try makeLocation(named: "Original.mscope")
        let initialPayload = try store.makePackagePayload()
        store.acceptPublishedWrite(
            capturedGeneration: initialPayload.capturedMutationGeneration,
            adopting: original
        )

        store.setCustomName(0x1000, name: "copy-only")
        let copyPayload = try store.makePackagePayload()

        XCTAssertEqual(copyPayload.capturedMutationGeneration, store.mutationGeneration)
        XCTAssertEqual(store.documentURL, original.canonicalURL)
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    func testStaleCapturedGenerationCannotClearDirtyOrAdoptLocation() throws {
        let store = makeStore()
        let recents = SpyRecents()
        store.recents = recents
        store.setCustomName(0x1000, name: "pending")
        _ = try store.makePackagePayload()
        let stale = WorkspaceDocumentMutationGeneration(
            rawValue: store.mutationGeneration.rawValue + 1
        )
        let location = try makeLocation(named: "Stale.mscope")

        store.acceptPublishedWrite(capturedGeneration: stale, adopting: location)

        XCTAssertNil(store.documentURL)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertTrue(recents.notedURLs.isEmpty)
    }

    func testInvalidTransferredPackageIsRejectedWithoutPartialStoreMutation() throws {
        let store = makeStore()
        store.setCustomName(0x1000, name: "preserved")
        let location = try makeLocation(named: "Invalid.mscope")
        let beforeGeneration = store.mutationGeneration
        let beforeDocumentID = store.documentID
        let beforeWorkspaceID = store.workspaceID
        let beforeURL = store.documentURL
        let invalid = WorkspaceDocumentValidatedPackage(
            manifestData: Data("{}".utf8),
            attachmentsByBinaryID: [:],
            observation: observation(
                at: location,
                manifestData: Data("{}".utf8)
            )
        )

        XCTAssertThrowsError(
            try store.installValidatedPackage(invalid, from: location)
        )
        XCTAssertEqual(store.documentID, beforeDocumentID)
        XCTAssertEqual(store.workspaceID, beforeWorkspaceID)
        XCTAssertEqual(store.documentURL, beforeURL)
        XCTAssertEqual(store.mutationGeneration, beforeGeneration)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertEqual(
            store.snapshot.addressOverrides[.primary(0x1000)]?.customName,
            "preserved"
        )
    }

    func testInstallsValidatedVersion1PackageAndAdoptsItsLogicalIdentity() throws {
        let source = makeStore()
        let payload = try source.makePackagePayload()
        let location = try makeLocation(named: "Version1.mscope")
        let package = validatedPackage(payload, at: location)
        let target = makeStore(
            documentID: UUID(),
            workspaceID: UUID(),
            workspaceName: "Target"
        )

        try target.installValidatedPackage(package, from: location)

        XCTAssertEqual(target.documentID, documentID)
        XCTAssertEqual(target.workspaceID, workspaceID)
        XCTAssertEqual(target.workspaceName, "DOC-01 Fixture")
        XCTAssertEqual(target.documentURL, location.canonicalURL)
        XCTAssertEqual(target.snapshot.binaries.map(\.id), [primaryBinaryID])
        XCTAssertEqual(target.snapshot.imageBytes, primaryBytes)
        XCTAssertFalse(target.hasUnsavedChanges)
    }

    func testInstallsValidatedVersion2PackageWithoutFlatteningImageOwnership() throws {
        let source = makeStore(includesSecondaryImage: true)
        let payload = try source.makePackagePayload()
        let decoded = try MacScopeDocumentPackage.validatedManifest(
            manifestData: payload.manifestData
        )
        XCTAssertEqual(decoded.formatVersion, WorkspacePackageManifest.instructionSidecarFormatVersion)
        XCTAssertEqual(decoded.analysisFormatVersion, WorkspacePackageManifest.multiImageFormatVersion)
        let location = try makeLocation(named: "Version2.mscope")
        let target = makeStore(
            documentID: UUID(),
            workspaceID: UUID(),
            workspaceName: "Target"
        )

        try target.installValidatedPackage(validatedPackage(payload, at: location), from: location)

        XCTAssertEqual(target.documentID, documentID)
        XCTAssertEqual(target.workspaceID, workspaceID)
        XCTAssertEqual(Set(target.snapshot.binaries.map(\.id)), [primaryBinaryID, secondaryBinaryID])
        XCTAssertEqual(target.snapshot.analysis(in: .primary)?.imageBytes, primaryBytes)
        XCTAssertEqual(
            target.snapshot.analysis(in: ImageSlot(rawValue: 1))?.imageBytes,
            secondaryBytes
        )
        XCTAssertFalse(target.hasUnsavedChanges)
    }

    private func makeStore(
        includesSecondaryImage: Bool = false,
        documentID: UUID? = nil,
        workspaceID: UUID? = nil,
        workspaceName: String = "DOC-01 Fixture"
    ) -> WorkspaceStore {
        let primary = BinaryImage(
            id: primaryBinaryID,
            name: "Primary",
            path: "/fixtures/primary.bin",
            kind: "raw fixture",
            architecture: "arm64",
            slot: .primary
        )
        var primaryAnalysis = ImageAnalysis()
        primaryAnalysis.instructions = [
            InstructionRow(
                address: 0x1000,
                bytes: "1f 20 03 d5",
                mnemonic: "nop",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        ]
        primaryAnalysis.hexBytes = primaryBytes
        primaryAnalysis.imageBytes = primaryBytes
        var binaries = [primary]
        var analyses: [ImageSlot: ImageAnalysis] = [.primary: primaryAnalysis]
        if includesSecondaryImage {
            let slot = ImageSlot(rawValue: 1)
            binaries.append(
                BinaryImage(
                    id: secondaryBinaryID,
                    name: "Secondary",
                    path: "/fixtures/secondary.bin",
                    kind: "raw fixture",
                    architecture: "arm64",
                    slot: slot
                )
            )
            var secondaryAnalysis = ImageAnalysis()
            secondaryAnalysis.hexBytes = secondaryBytes
            secondaryAnalysis.imageBytes = secondaryBytes
            analyses[slot] = secondaryAnalysis
        }
        return WorkspaceStore(
            workspaceName: workspaceName,
            snapshot: WorkspaceSnapshot(
                binaries: binaries,
                analysisBySlot: analyses
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: ManualAutosaveTrigger(),
            documentID: documentID ?? self.documentID,
            workspaceID: workspaceID ?? self.workspaceID
        )
    }

    private func makeLocation(named name: String) throws -> WorkspaceDocumentLocation {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceDocumentContentSourceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return try WorkspaceDocumentLocation.canonicalized(
            from: parent.appendingPathComponent("\(UUID().uuidString)-\(name)", isDirectory: true)
        )
    }

    private func validatedPackage(
        _ payload: WorkspaceDocumentPackagePayload,
        at location: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentValidatedPackage {
        WorkspaceDocumentValidatedPackage(
            manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID,
            reconstructionState: payload.reconstructionState,
            reconstructionAttachmentSources: payload.reconstructionAttachmentSources,
            instructionSidecarData: payload.instructionSidecarData,
            observation: observation(at: location, manifestData: payload.manifestData)
        )
    }

    private func observation(
        at location: WorkspaceDocumentLocation,
        manifestData: Data
    ) -> WorkspacePackageExternalVersion {
        WorkspacePackageExternalVersion(
            location: location,
            condition: .valid,
            observationSHA256: String(repeating: "a", count: 64),
            manifestSHA256: MacScopeDocumentPackage.fileHash(for: manifestData),
            validatedContentSHA256: String(repeating: "b", count: 64),
            boundedReason: nil
        )
    }
}
