import Foundation
import XCTest
@testable import MacScope

final class MachOSliceArtifactPersistenceTests: XCTestCase {
    private func requireSendableAnalysisPayload() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(BinaryImage.self)
    }

    func testDatabaseKeepsUniversalFactWhenOnlySelectedThinBytesRemain() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        var snapshot = try verifiedSnapshot(bytes: selectedSliceBytes())
        let fact = try MachOSelectedSliceFact(
            containerKind: .universal, sliceCount: 3, selectedSliceIndex: 2,
            cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 2
        )
        snapshot.binaries[0].machOSelectedSliceFact = fact
        // The legacy request is nil even though the loader observed a selected universal slice.
        XCTAssertNil(snapshot.binaries[0].selectedSliceIndex)
        let workspace = try database.saveSnapshot(workspaceName: "Selected fact", snapshot: snapshot)
        let reopened = try XCTUnwrap(
            try database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id))
        )
        XCTAssertEqual(reopened.binaries[0].machOSelectedSliceFact, fact)
        XCTAssertNil(reopened.binaries[0].selectedSliceIndex)
    }

    func testVersion43MigrationKeepsLegacyContainerUnknown() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let snapshot = try verifiedSnapshot(bytes: selectedSliceBytes(), selectedSliceIndex: 7)
        let workspace = try database.saveSnapshot(workspaceName: "Legacy fact", snapshot: snapshot)
        try database.executeRawForTesting("ALTER TABLE binaries DROP COLUMN macho_selected_slice_fact_json;")
        try database.executeRawForTesting("PRAGMA user_version = 43;")
        try database.applySchema()
        let reopened = try XCTUnwrap(
            try database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id))
        )
        XCTAssertEqual(reopened.binaries[0].selectedSliceIndex, 7)
        XCTAssertNil(reopened.binaries[0].machOSelectedSliceFact)
    }

    func testPackageBinaryMissingFactDecodesUnknownNotThinOrSliceZero() throws {
        let record = WorkspacePackageBinary(
            id: UUID(), displayName: "Legacy", originalPath: "Legacy",
            attachmentRelativePath: "Attachments/legacy/image", kind: "Mach-O executable",
            architecture: "arm64e", fileHash: String(repeating: "a", count: 64), fileSize: 256,
            selectedSliceIndex: 7
        )
        let encoded = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["machOSelectedSliceFact"])
        let decoded = try JSONDecoder().decode(WorkspacePackageBinary.self, from: encoded)
        XCTAssertEqual(decoded.selectedSliceIndex, 7)
        XCTAssertNil(decoded.machOSelectedSliceFact)
    }

    func testBinaryImageDecodeRejectsForgedVerifiedLayoutOutsideIdentityByteCount() throws {
        let image = try verifiedSnapshot(bytes: selectedSliceBytes()).binaries[0]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? [String: Any]
        )
        var layout = try XCTUnwrap(object["preferredSegmentLayout"] as? [String: Any])
        var records = try XCTUnwrap(layout["records"] as? [[String: Any]])
        records[0]["fileSize"] = 0x1_000
        layout["records"] = records
        object["preferredSegmentLayout"] = layout

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BinaryImage.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testBinaryImageLegacyDecodeDefaultsAbsentArtifactFields() throws {
        let image = unavailableSnapshot(binaryID: UUID()).binaries[0]
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as? [String: Any]
        )
        object.removeValue(forKey: "artifactIdentity")
        object.removeValue(forKey: "preferredSegmentLayout")
        object.removeValue(forKey: "artifactIntegrityState")
        object.removeValue(forKey: "resolvedExecutablePath")

        let decoded = try JSONDecoder().decode(
            BinaryImage.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertNil(decoded.artifactIdentity)
        XCTAssertNil(decoded.preferredSegmentLayout)
        XCTAssertEqual(decoded.artifactIntegrityState, .unavailable)
        XCTAssertNil(decoded.resolvedExecutablePath)
    }

    func testDatabaseReopenReconstructsVerifiedEvidenceAndDropsExecutablePathHint() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let bytes = selectedSliceBytes()
        let snapshot = try verifiedSnapshot(bytes: bytes, resolvedExecutablePath: "/tmp/Fresh.app/Contents/MacOS/Fresh")

        let workspace = try database.saveSnapshot(
            workspaceName: "Verified artifact",
            snapshot: snapshot
        )
        let reopened = try XCTUnwrap(
            try database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id))
        )
        let binary = try XCTUnwrap(reopened.binaries.first)

        XCTAssertEqual(binary.artifactIntegrityState, .verified)
        XCTAssertEqual(binary.artifactIdentity, snapshot.binaries[0].artifactIdentity)
        XCTAssertEqual(binary.preferredSegmentLayout, snapshot.binaries[0].preferredSegmentLayout)
        XCTAssertNil(binary.resolvedExecutablePath)
    }

    func testDatabaseContradictoryAttachmentEvidenceOpensWithoutAuthorityAndAddsBoundedDiagnostic() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let snapshot = try verifiedSnapshot(bytes: selectedSliceBytes())
        let workspace = try database.saveSnapshot(
            workspaceName: "Contradictory artifact",
            snapshot: snapshot
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting("UPDATE binaries SET file_size = file_size + 1 WHERE workspace_id = \(workspaceID);")

        let reopened = try XCTUnwrap(try database.loadSnapshot(workspaceID: workspaceID))
        let binary = try XCTUnwrap(reopened.binaries.first)

        guard case let .contradictoryEvidence(diagnostic) = binary.artifactIntegrityState else {
            return XCTFail("Expected contradictory artifact evidence")
        }
        XCTAssertLessThanOrEqual(diagnostic.utf8.count, 4_096)
        XCTAssertNil(binary.artifactIdentity)
        XCTAssertNil(binary.preferredSegmentLayout)
        XCTAssertTrue(
            reopened.analysis(in: binary.slot)?.diagnostics.contains(where: {
                $0.kind == .loaderTruncation && $0.message == diagnostic
            }) == true
        )
    }

    func testContradictoryEvidenceRefusesReplaceBeforeDatabaseMutation() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let binaryID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var initial = unavailableSnapshot(binaryID: binaryID)
        let persisted = try database.createWorkspaceState(
            workspaceName: "Before",
            snapshot: initial,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)

        initial.binaries[0].artifactIntegrityState = .contradictoryEvidence(
            diagnostic: "Selected-slice bytes disagree with persisted size."
        )
        XCTAssertThrowsError(
            try database.replaceWorkspaceState(
                workspaceID: workspaceID,
                workspaceName: "After",
                snapshot: initial,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .artifactIntegrityRequiresReimport(binaryID: binaryID)
            )
        }

        XCTAssertEqual(try database.workspace(id: workspaceID)?.name, "Before")
        XCTAssertEqual(try database.binaries(workspaceID: workspaceID).map(\.uuid), [binaryID])
    }

    func testLegacyUnavailableEvidenceRemainsSaveCompatible() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let snapshot = unavailableSnapshot(binaryID: UUID())

        XCTAssertNoThrow(
            try database.saveSnapshot(workspaceName: "Legacy", snapshot: snapshot)
        )
    }

    @MainActor
    func testExplicitReimportReplacesContradictoryBytesAndRestoresVerifiedEvidence() async throws {
        let binaryID = UUID(uuidString: "99999999-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var snapshot = unavailableSnapshot(binaryID: binaryID)
        snapshot.binaries[0].artifactIntegrityState = .contradictoryEvidence(
            diagnostic: "Selected-slice attachment cannot be trusted."
        )
        snapshot.analysisBySlot[.primary]?.imageBytes = Data(repeating: 0xFF, count: 64)
        let store = WorkspaceStore(
            workspaceName: "Contradictory",
            snapshot: snapshot,
            engine: AnalysisEngine()
        )
        let bytes = selectedSliceBytes()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-WS20-reimport-\(UUID().uuidString)")
        try bytes.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }

        let replaced = await store.reimportBinary(
            in: .primary,
            from: url,
            requestedSliceIndex: nil
        )

        XCTAssertTrue(replaced)
        let binary = try XCTUnwrap(store.snapshot.binary(in: .primary))
        XCTAssertEqual(binary.id, binaryID)
        XCTAssertEqual(binary.artifactIntegrityState, .verified)
        XCTAssertEqual(binary.artifactIdentity?.selectedSliceByteCount, UInt64(bytes.count))
        XCTAssertEqual(store.snapshot.analysis(in: .primary)?.imageBytes, bytes)
    }

    @MainActor
    func testStructuralReanalysisCannotBlessContradictoryArtifactEvidence() throws {
        let diagnostic = "Selected-slice bytes contradict their durable identity."
        let bytes = selectedSliceBytes()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-WS20-contradictory-reanalysis-\(UUID().uuidString)")
        try bytes.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }

        var snapshot = try AnalysisEngine().analyze(url: url)
        snapshot.binaries[0].artifactIdentity = nil
        snapshot.binaries[0].preferredSegmentLayout = nil
        snapshot.binaries[0].artifactIntegrityState = .contradictoryEvidence(
            diagnostic: diagnostic
        )
        snapshot.analysisBySlot[.primary]?.diagnostics.append(
            AnalysisDiagnostic(
                severity: .error,
                address: 0,
                kind: .loaderTruncation,
                message: diagnostic
            )
        )
        let store = WorkspaceStore(
            workspaceName: "Contradictory structural edit",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )

        store.withSynchronousReanalysis {
            store.setIsData(0x1_0000_0000, true)
        }

        let binary = try XCTUnwrap(store.snapshot.binary(in: .primary))
        XCTAssertEqual(
            binary.artifactIntegrityState,
            .contradictoryEvidence(diagnostic: diagnostic)
        )
        XCTAssertNil(binary.artifactIdentity)
        XCTAssertNil(binary.preferredSegmentLayout)
        XCTAssertTrue(
            store.snapshot.analysis(in: .primary)?.diagnostics.contains(where: {
                $0.kind == .loaderTruncation && $0.message == diagnostic
            }) == true
        )
    }

    @MainActor
    func testRehydrationTreatsPersistedImageBytesAsAlreadySelectedThinSlice() async throws {
        let provider = RequestedSliceRecordingProvider()
        let bytes = selectedSliceBytes()
        var snapshot = try verifiedSnapshot(bytes: bytes, selectedSliceIndex: 7)
        snapshot.analysisBySlot[.primary]?.sections = []
        snapshot.analysisBySlot[.primary]?.machOMetadata = nil
        let store = WorkspaceStore(
            workspaceName: "Selected slice",
            snapshot: snapshot,
            engine: provider
        )

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        XCTAssertEqual(provider.requestedSliceIndices.count, 1)
        XCTAssertNil(provider.requestedSliceIndices[0])
    }

    @MainActor
    func testDelayedReimportCannotClobberAReplacementWorkspaceOwner() async throws {
        let originalID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let replacementID = UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let original = unavailableSnapshot(binaryID: originalID)
        let reimportResult = try verifiedSnapshot(bytes: selectedSliceBytes())
        var replacement = try verifiedSnapshot(bytes: selectedSliceBytes())
        replacement.binaries[0] = BinaryImage(
            id: replacementID,
            name: "Replacement",
            path: "/tmp/Replacement",
            kind: replacement.binaries[0].kind,
            architecture: replacement.binaries[0].architecture,
            artifactIdentity: replacement.binaries[0].artifactIdentity,
            preferredSegmentLayout: replacement.binaries[0].preferredSegmentLayout,
            artifactIntegrityState: .verified,
            slot: .primary
        )
        let delayedURL = URL(fileURLWithPath: "/tmp/delayed-reimport")
        let replacementURL = URL(fileURLWithPath: "/tmp/replacement-import")
        let provider = DelayedReimportProvider(
            delayedURL: delayedURL,
            delayedResult: reimportResult,
            immediateResult: replacement
        )
        let store = WorkspaceStore(
            workspaceName: "Original",
            snapshot: original,
            engine: provider
        )

        let reimportTask = Task {
            await store.reimportBinary(in: .primary, from: delayedURL)
        }
        await provider.waitUntilDelayedRequestStarts()
        await store.importBinary(url: replacementURL)
        await provider.finishDelayedRequest()
        let replaced = await reimportTask.value

        XCTAssertFalse(replaced)
        XCTAssertEqual(store.snapshot.binary(in: .primary)?.id, replacementID)
        XCTAssertEqual(store.snapshot.binary(in: .primary)?.name, "Replacement")
    }

    func testPackageOpenReconstructsAlreadySelectedThinSliceAndLeavesPathHintNil() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let bytes = selectedSliceBytes()
        var snapshot = try verifiedSnapshot(bytes: bytes, selectedSliceIndex: 7)
        let fact = try MachOSelectedSliceFact(
            containerKind: .universal, sliceCount: 8, selectedSliceIndex: 7,
            cpuType: MachOConstants.cpuTypeARM64, cpuSubtype: 2
        )
        snapshot.binaries[0].machOSelectedSliceFact = fact
        let persisted = try database.createWorkspaceState(
            workspaceName: "Package artifact",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-WS20-\(UUID().uuidString).mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        _ = try database.writePackage(
            workspaceID: try XCTUnwrap(persisted.workspace.id),
            to: packageURL
        )
        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        let binary = try XCTUnwrap(opened.snapshot.binaries.first)

        XCTAssertEqual(binary.selectedSliceIndex, 7)
        XCTAssertEqual(binary.machOSelectedSliceFact, fact)
        XCTAssertEqual(binary.artifactIntegrityState, .verified)
        XCTAssertEqual(binary.artifactIdentity?.selectedSliceByteCount, UInt64(bytes.count))
        XCTAssertEqual(binary.artifactIdentity?.architectureVariant, .arm64e)
        XCTAssertNil(binary.resolvedExecutablePath)
    }

    func testPackageAndDatabaseReopenKeepAnonymousMachOObjectEvidenceUnavailable() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let bytes = anonymousObjectBytes()
        let objectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-WS20-anonymous-\(UUID().uuidString).o")
        try bytes.write(to: objectURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: objectURL) }

        let snapshot = try AnalysisEngine().analyze(url: objectURL)
        let importedBinary = try XCTUnwrap(snapshot.binaries.first)
        XCTAssertEqual(importedBinary.kind, "Mach-O object")
        XCTAssertEqual(importedBinary.artifactIntegrityState, .unavailable)
        XCTAssertNil(importedBinary.artifactIdentity)
        XCTAssertNil(importedBinary.preferredSegmentLayout)
        let persisted = try database.createWorkspaceState(
            workspaceName: "Anonymous object",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let workspaceID = try XCTUnwrap(persisted.workspace.id)
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-WS20-object-\(UUID().uuidString).mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        _ = try database.writePackage(workspaceID: workspaceID, to: packageURL)
        let packageBinary = try XCTUnwrap(
            MacScopeDocumentPackage.openPackage(from: packageURL).snapshot.binaries.first
        )
        XCTAssertEqual(packageBinary.artifactIntegrityState, .unavailable)
        XCTAssertNil(packageBinary.artifactIdentity)
        XCTAssertNil(packageBinary.preferredSegmentLayout)

        let databaseSnapshot = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        let databaseBinary = try XCTUnwrap(databaseSnapshot.binaries.first)
        XCTAssertEqual(databaseBinary.artifactIntegrityState, .unavailable)
        XCTAssertNil(databaseBinary.artifactIdentity)
        XCTAssertNil(databaseBinary.preferredSegmentLayout)
        XCTAssertFalse(
            databaseSnapshot.diagnostics.contains(where: {
                $0.kind == .loaderTruncation
                    && $0.message == "Selected-slice attachment cannot be reconstructed as a complete Mach-O slice."
            })
        )
    }

    func testPackageOpenTreatsVerifiedMachOAttachmentReconstructionFailureAsCorruption() throws {
        let binaryID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let attachmentPath = MacScopeDocumentPackage.attachmentRelativePath(
            for: binaryID,
            originalPath: "/tmp/CorruptMachO"
        )
        let bytes = Data(repeating: 0xA5, count: 64)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = WorkspacePackageManifest(
            documentID: UUID(uuidString: "AAAAAAAA-2222-3333-4444-555555555555")!,
            workspaceUUID: UUID(uuidString: "BBBBBBBB-2222-3333-4444-555555555555")!,
            workspaceName: "Corrupt package artifact",
            createdAt: now,
            modifiedAt: now,
            binaries: [
                WorkspacePackageBinary(
                    id: binaryID,
                    displayName: "CorruptMachO",
                    originalPath: "/tmp/CorruptMachO",
                    attachmentRelativePath: attachmentPath,
                    kind: "Mach-O executable",
                    architecture: "arm64",
                    fileHash: MacScopeDocumentPackage.fileHash(for: bytes),
                    fileSize: Int64(bytes.count)
                )
            ],
            analysis: WorkspacePackageAnalysis(),
            session: nil
        )
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-WS20-corrupt-\(UUID().uuidString).mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        try MacScopeDocumentPackage.preparePackageDirectory(
            at: packageURL,
            for: manifest
        )
        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: packageURL,
            relativePath: attachmentPath
        )
        try bytes.write(to: attachmentURL)
        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)

        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: packageURL)) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .attachmentArtifactReconstructionFailed(attachmentPath)
            )
        }
    }

    func testPackageUUIDCollisionRemapPreservesReconstructedArtifactEvidence() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let bytes = selectedSliceBytes()
        let snapshot = try verifiedSnapshot(
            bytes: bytes,
            resolvedExecutablePath: "/tmp/Fresh.app/Contents/MacOS/Fresh",
            selectedSliceIndex: 3
        )
        let persisted = try database.createWorkspaceState(
            workspaceName: "Collision source",
            snapshot: snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-WS20-collision-\(UUID().uuidString).mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        _ = try database.writePackage(
            workspaceID: try XCTUnwrap(persisted.workspace.id),
            to: packageURL
        )

        let imported = try database.importPackage(from: packageURL)
        let binary = try XCTUnwrap(imported.snapshot.binaries.first)

        XCTAssertNotEqual(binary.id, snapshot.binaries[0].id)
        XCTAssertEqual(binary.selectedSliceIndex, 3)
        XCTAssertEqual(binary.artifactIdentity, snapshot.binaries[0].artifactIdentity)
        XCTAssertEqual(binary.preferredSegmentLayout, snapshot.binaries[0].preferredSegmentLayout)
        XCTAssertEqual(binary.artifactIntegrityState, .verified)
        XCTAssertNil(binary.resolvedExecutablePath)
    }

    private func selectedSliceBytes() -> Data {
        WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 2,
            uuid: UUID(uuidString: "38121563-B342-3249-BA9C-DAAC2257A52D")!,
            segments: [
                .init(
                    name: "__TEXT",
                    vmAddress: 0x1_0000_0000,
                    vmSize: 0x1_000,
                    fileOffset: 0,
                    fileSize: 0x100,
                    initialProtections: 0x5
                )
            ],
            byteCount: 0x100
        )
    }

    private func anonymousObjectBytes() -> Data {
        WS20MachOSliceFixture.thin64(
            cpuType: MachOConstants.cpuTypeARM64,
            cpuSubtype: 0,
            fileType: MachOConstants.fileTypeObject,
            uuid: nil,
            segments: [
                .init(
                    name: "",
                    vmAddress: 0,
                    vmSize: 0x100,
                    fileOffset: 0,
                    fileSize: 0x100,
                    initialProtections: 0x7
                )
            ],
            byteCount: 0x100
        )
    }

    private func verifiedSnapshot(
        bytes: Data,
        resolvedExecutablePath: String? = nil,
        selectedSliceIndex: Int? = nil
    ) throws -> WorkspaceSnapshot {
        let reconstructed = try MachOSliceArtifactReconstructor.reconstruct(
            selectedSliceBytes: bytes
        )
        let binary = BinaryImage(
            id: UUID(uuidString: "38121563-B342-3249-BA9C-DAAC2257A52D")!,
            name: "Artifact",
            path: "/tmp/Artifact",
            kind: "Mach-O executable",
            architecture: "arm64e",
            selectedSliceIndex: selectedSliceIndex,
            artifactIdentity: reconstructed.identity,
            preferredSegmentLayout: reconstructed.preferredSegmentLayout,
            artifactIntegrityState: .verified,
            resolvedExecutablePath: resolvedExecutablePath,
            slot: .primary
        )
        return WorkspaceSnapshot(
            binaries: [binary],
            analysisBySlot: [
                .primary: ImageAnalysis(
                    hexBytes: Data(bytes.prefix(WorkspaceSnapshot.hexViewByteWindow)),
                    imageBytes: bytes
                )
            ]
        )
    }

    private func unavailableSnapshot(binaryID: UUID) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [
                BinaryImage(
                    id: binaryID,
                    name: "Legacy",
                    path: "/tmp/Legacy",
                    kind: "Mach-O executable",
                    architecture: "arm64",
                    artifactIntegrityState: .unavailable,
                    slot: .primary
                )
            ],
            analysisBySlot: [.primary: ImageAnalysis()]
        )
    }
}

private final class RequestedSliceRecordingProvider: AnalysisProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequestedSliceIndices: [Int?] = []

    var requestedSliceIndices: [Int?] {
        lock.withLock { storedRequestedSliceIndices }
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("Unexpected analyze")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        fatalError("Unexpected openBinary")
    }

    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        lock.withLock { storedRequestedSliceIndices.append(requestedSliceIndex) }
        return persisted
    }
}

private final class DelayedReimportProvider: AnalysisProviding, @unchecked Sendable {
    private actor State {
        var continuation: CheckedContinuation<WorkspaceSnapshot, Never>?
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        let delayedResult: WorkspaceSnapshot

        init(delayedResult: WorkspaceSnapshot) {
            self.delayedResult = delayedResult
        }

        func waitForDelayedResult() async -> WorkspaceSnapshot {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                startWaiters.forEach { $0.resume() }
                startWaiters.removeAll()
            }
        }

        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func finish() {
            continuation?.resume(returning: delayedResult)
            continuation = nil
        }
    }

    private let delayedURL: URL
    private let immediateResult: WorkspaceSnapshot
    private let state: State

    init(delayedURL: URL, delayedResult: WorkspaceSnapshot, immediateResult: WorkspaceSnapshot) {
        self.delayedURL = delayedURL
        self.immediateResult = immediateResult
        state = State(delayedResult: delayedResult)
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        immediateResult
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        if url == delayedURL {
            return await state.waitForDelayedResult()
        }
        return immediateResult
    }

    func waitUntilDelayedRequestStarts() async {
        await state.waitUntilStarted()
    }

    func finishDelayedRequest() async {
        await state.finish()
    }
}
