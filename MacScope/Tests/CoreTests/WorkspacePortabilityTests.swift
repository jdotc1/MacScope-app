import XCTest
@testable import MacScope

/// Regression for the P0 workspace data-loss defect: the ordinary save path persisted only the
/// first binary's 4 KB hex-view PREVIEW (`hexBytes`) instead of the full selected slice
/// (`imageBytes`), so a saved `.mscope` could not be reanalyzed after the original file moved or
/// was deleted. These tests would have caught it: a >4 KB binary must round-trip its FULL bytes
/// through save+reopen, and reanalysis must recover from the embedded bytes when the source is
/// gone.
final class WorkspacePortabilityTests: XCTestCase {
    func testLegacyVersionsOpenEmptyAndResaveAtLowestCompatibleVersion() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }

        let v1URL = fixture.root.appendingPathComponent("Legacy-v1.mscope", isDirectory: true)
        try writeLegacyPackage(
            fixture.manifest,
            attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            to: v1URL
        )
        let v1 = try MacScopeDocumentPackage.openPackage(from: v1URL)
        XCTAssertEqual(v1.manifest.formatVersion, WorkspacePackageManifest.currentFormatVersion)
        XCTAssertEqual(v1.reconstructionState, .empty)

        let secondID = UUID()
        let secondBytes = Data([0x04, 0x05])
        let secondBinary = WorkspacePackageBinary(
            id: secondID,
            displayName: "Secondary",
            originalPath: "/fixtures/secondary.bin",
            attachmentRelativePath: "attachments/\(secondID.uuidString.lowercased())/secondary.bin",
            kind: "Raw data",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: secondBytes),
            fileSize: Int64(secondBytes.count),
            slot: ImageSlot(rawValue: 1)
        )
        var v2Manifest = fixture.manifest
        v2Manifest.formatVersion = WorkspacePackageManifest.multiImageFormatVersion
        v2Manifest.binaries.append(secondBinary)
        v2Manifest.analysis = WorkspacePackageAnalysis()
        v2Manifest.imageAnalyses = v2Manifest.binaries.map {
            WorkspacePackageImageAnalysis(
                binaryID: $0.id,
                imageSlot: $0.slot,
                analysis: WorkspacePackageAnalysis()
            )
        }
        let v2URL = fixture.root.appendingPathComponent("Legacy-v2.mscope", isDirectory: true)
        try writeLegacyPackage(
            v2Manifest,
            attachmentsByBinaryID: [
                fixture.binaryID: fixture.binaryBytes,
                secondID: secondBytes,
            ],
            to: v2URL
        )
        let v2 = try MacScopeDocumentPackage.openPackage(from: v2URL)
        XCTAssertEqual(v2.manifest.formatVersion, WorkspacePackageManifest.multiImageFormatVersion)
        XCTAssertEqual(v2.reconstructionState, .empty)

        let v2Resave = fixture.root.appendingPathComponent("Legacy-v2-resave.mscope", isDirectory: true)
        try MacScopeDocumentPackage.writePackage(
            v2.manifest,
            attachmentsByBinaryID: v2.attachmentsByBinaryID,
            to: v2Resave
        )
        let migrated = try MacScopeDocumentPackage.openPackage(from: v2Resave)
        XCTAssertEqual(migrated.manifest.formatVersion, WorkspacePackageManifest.instructionSidecarFormatVersion)
        XCTAssertEqual(migrated.manifest.analysisFormatVersion, WorkspacePackageManifest.multiImageFormatVersion)
    }

    func testClearingReconstructionStateDowngradesVersion3ToVersion1() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        var manifest = fixture.manifest
        let instruction = InstructionRow(
            address: 0x1000, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "",
            hasBreakpoint: false, comment: "kept while clearing reconstruction"
        )
        manifest.analysis = WorkspacePackageAnalysis(instructions: [instruction])
        try MacScopeDocumentPackage.writePackage(
            manifest, attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            reconstructionState: fixture.state, reconstructionAttachmentSources: [fixture.source],
            to: fixture.packageURL
        )
        let v3 = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        let clearedURL = fixture.root.appendingPathComponent("Cleared.mscope", isDirectory: true)

        try MacScopeDocumentPackage.writePackage(
            v3.manifest,
            attachmentsByBinaryID: v3.attachmentsByBinaryID,
            reconstructionState: .empty,
            reconstructionAttachmentSources: [],
            to: clearedURL,
            instructionSidecarData: v3.instructionSidecarData
        )

        let cleared = try MacScopeDocumentPackage.openPackage(from: clearedURL)
        XCTAssertEqual(cleared.manifest.formatVersion, WorkspacePackageManifest.instructionSidecarFormatVersion)
        XCTAssertEqual(cleared.manifest.analysisFormatVersion, WorkspacePackageManifest.currentFormatVersion)
        XCTAssertEqual(cleared.snapshot.instructions.map(\.address), [instruction.address])
        XCTAssertEqual(cleared.snapshot.instructions.first?.comment, instruction.comment)
        XCTAssertNil(cleared.manifest.reconstruction)
        XCTAssertEqual(cleared.reconstructionState, .empty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: clearedURL.appendingPathComponent("Reconstruction").path
        ))
    }

    func testVersion2WithoutTopLevelAnalysisPromotesToVersion3() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        var version2 = fixture.manifest
        version2.formatVersion = WorkspacePackageManifest.multiImageFormatVersion
        version2.analysis = nil
        version2.imageAnalyses = version2.binaries.map {
            WorkspacePackageImageAnalysis(
                binaryID: $0.id,
                imageSlot: $0.slot,
                analysis: WorkspacePackageAnalysis()
            )
        }
        let destination = fixture.root.appendingPathComponent(
            "Version2-to-Version3.mscope",
            isDirectory: true
        )

        try MacScopeDocumentPackage.writePackage(
            version2,
            attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            reconstructionState: fixture.state,
            reconstructionAttachmentSources: [fixture.source],
            to: destination
        )

        let opened = try MacScopeDocumentPackage.openPackage(from: destination)
        XCTAssertEqual(opened.manifest.formatVersion, WorkspacePackageManifest.instructionSidecarFormatVersion)
        XCTAssertEqual(opened.manifest.analysisFormatVersion, WorkspacePackageManifest.reconstructionFormatVersion)
        let promotedAuthoring = try XCTUnwrap(opened.manifest.analysis)
        XCTAssertFalse(promotedAuthoring.hasDerivedPayload)
        XCTAssertFalse(promotedAuthoring.hasAuthoringPayload)
        XCTAssertEqual(opened.reconstructionState, fixture.state)
    }

    func testLegacyVersion1RetainsUnknownKeyCompatibility() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let packageURL = fixture.root.appendingPathComponent("Legacy-unknown.mscope", isDirectory: true)
        try writeLegacyPackage(
            fixture.manifest,
            attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            to: packageURL
        )
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: packageURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        object["futureLegacyMetadata"] = ["preservedCompatibility": true]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL)

        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(opened.manifest.formatVersion, WorkspacePackageManifest.currentFormatVersion)
        XCTAssertEqual(opened.reconstructionState, .empty)
    }

    private func writeLegacyPackage(
        _ manifest: WorkspacePackageManifest,
        attachmentsByBinaryID: [UUID: Data],
        to packageURL: URL
    ) throws {
        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)
        for binary in manifest.binaries {
            try XCTUnwrap(attachmentsByBinaryID[binary.id]).write(
                to: MacScopeDocumentPackage.attachmentURL(in: packageURL, relativePath: binary.attachmentRelativePath)
            )
        }
    }

    /// A real, loadable Mach-O whose total file size comfortably exceeds the 4 KB hex window, so
    /// hexBytes (bounded) and imageBytes (full) are provably different sizes.
    private func largeFixtureURL() throws -> (url: URL, byteCount: Int) {
        // ~1600 instructions of `nop` + `ret` => ~6.4 KB of code alone, well over the 4 KB window.
        var code = Data()
        for _ in 0..<1600 { code.append(contentsOf: [0x1f, 0x20, 0x03, 0xd5]) } // nop
        code.append(contentsOf: [0xc0, 0x03, 0x5f, 0xd6]) // ret
        let fixture = MachOFixture.makeExecutable(code: code)
        XCTAssertGreaterThan(fixture.bytes.count, WorkspaceSnapshot.hexViewByteWindow,
                             "fixture must exceed the hex window to exercise the bug")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortabilityFixture-\(UUID().uuidString)")
        try fixture.bytes.write(to: url)
        return (url, fixture.bytes.count)
    }

    /// Analysis must retain the FULL slice in imageBytes while hexBytes stays the bounded window.
    func testAnalysisRetainsFullImageBytesNotJustHexWindow() throws {
        let (url, byteCount) = try largeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try AnalysisEngine().analyze(url: url)

        XCTAssertEqual(snapshot.hexBytes.count, WorkspaceSnapshot.hexViewByteWindow,
                       "hexBytes is the bounded view window")
        XCTAssertGreaterThan(snapshot.imageBytes.count, WorkspaceSnapshot.hexViewByteWindow,
                             "imageBytes must hold the full slice, not a 4 KB preview")
        // imageBytes is the selected slice from its file offset to EOF; for a thin fixture that is
        // the whole file.
        XCTAssertEqual(snapshot.imageBytes.count, byteCount)
    }

    /// The saved package attachment must be the FULL slice (SHA + count), not the 4 KB preview,
    /// and reopening must restore imageBytes byte-for-byte with hexBytes re-derived as the window.
    @MainActor
    func testSavedPackageEmbedsFullSourceAndSurvivesReopen() throws {
        let (url, _) = try largeFixtureURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try AnalysisEngine().analyze(url: url)
        let store = WorkspaceStore(workspaceName: "Portable", snapshot: snapshot, engine: AnalysisEngine())

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let manifest = try store.saveWorkspacePackage(to: packageURL, using: database)
        let manifestBinary = try XCTUnwrap(manifest.binaries.first)
        let attachmentURL = try MacScopeDocumentPackage.attachmentURL(
            in: packageURL, relativePath: manifestBinary.attachmentRelativePath
        )
        let attachment = try Data(contentsOf: attachmentURL)

        // The attachment is the FULL slice — NOT the 4 KB hex window (the defect).
        XCTAssertEqual(attachment, snapshot.imageBytes, "attachment must be the full source slice")
        XCTAssertGreaterThan(attachment.count, WorkspaceSnapshot.hexViewByteWindow)
        XCTAssertNotEqual(attachment, snapshot.hexBytes, "attachment must NOT be the 4 KB preview")
        XCTAssertEqual(manifestBinary.fileSize, Int64(snapshot.imageBytes.count))
        XCTAssertEqual(manifestBinary.fileHash, MacScopeDocumentPackage.fileHash(for: snapshot.imageBytes))

        // Reopen: imageBytes restored byte-for-byte; hexBytes re-derived as the bounded window.
        let reopened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(reopened.snapshot.imageBytes, snapshot.imageBytes)
        XCTAssertEqual(reopened.snapshot.hexBytes.count, WorkspaceSnapshot.hexViewByteWindow)
        XCTAssertEqual(reopened.snapshot.hexBytes,
                       Data(snapshot.imageBytes.prefix(WorkspaceSnapshot.hexViewByteWindow)))
    }

    /// The portability acceptance gate, framed so it can ONLY pass if recovery actually runs:
    /// the recovery store starts with an EMPTY derived stream (as if a reopen dropped it) but with
    /// `imageBytes` present and a now-deleted source path. Triggering reanalysis must repopulate
    /// the stream from the embedded bytes, matching a fresh on-disk analyze. A no-op recovery
    /// (the pre-fix behavior when the path is gone) leaves the stream empty — an unmissable RED.
    @MainActor
    func testReanalysisFromEmbeddedBytesRepopulatesDroppedStream() throws {
        let (url, _) = try largeFixtureURL()

        let full = try AnalysisEngine().analyze(url: url)
        XCTAssertFalse(full.instructions.isEmpty)
        let expectedStream = full.instructions.map { InstructionKey($0) }
        let entryAddress = try XCTUnwrap(full.instructions.first?.address)

        // Simulate a reopened package that kept the source bytes but dropped the derived stream.
        var dropped = full
        dropped.instructions = []
        dropped.functions = []
        dropped.basicBlocks = []
        dropped.controlFlowEdges = []
        XCTAssertFalse(dropped.imageBytes.isEmpty, "the embedded slice is the only remaining source")

        let store = WorkspaceStore(workspaceName: "Recovery", snapshot: dropped, engine: AnalysisEngine())

        // The original source is gone — recovery must come from imageBytes.
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // Any structural edit kicks reanalysis; setMarkAsProcedure takes an explicit address, so it
        // works even with no selectable instruction in the dropped stream.
        store.withSynchronousReanalysis {
            store.setMarkAsProcedure(entryAddress, true)
        }

        // Recovery re-derived the full stream from the embedded bytes — byte-equivalent to a fresh
        // on-disk analyze.
        XCTAssertEqual(store.snapshot.instructions.map { InstructionKey($0) }, expectedStream,
                       "recovery-from-embedded-bytes must reproduce the on-disk instruction stream")
        // Embedded bytes are preserved and the user-facing path is restored (not the temp file).
        XCTAssertFalse(store.snapshot.imageBytes.isEmpty)
        XCTAssertEqual(store.snapshot.binaries.first?.path, url.path)
    }

    /// Stable identity for comparing two derived instruction streams.
    private struct InstructionKey: Equatable {
        let address: UInt64
        let mnemonic: String
        let operands: String
        init(_ row: InstructionRow) {
            address = row.address
            mnemonic = row.mnemonic
            operands = row.operands
        }
    }
}
