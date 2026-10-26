import Foundation
import XCTest
@testable import MacScope

final class WorkspacePackageByteCodecTests: XCTestCase {
    func testVersion1ByteAndDiskDecodingAreEquivalentAndCanonical() throws {
        try assertByteAndDiskEquivalence(formatVersion: 1)
    }

    func testVersion2ByteAndDiskDecodingAreEquivalentAndCanonical() throws {
        try assertByteAndDiskEquivalence(formatVersion: 2)
    }

    func testValidatedContentsRejectsDuplicateManifestAuthority() throws {
        let fixture = fixture(formatVersion: 1)
        let encoded = try MacScopeDocumentPackage.encodedManifest(fixture.manifest)
        let canonical = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let hostile = String(canonical.dropLast())
            + ",\"analysis\":null}"

        let contents = try MacScopeDocumentPackage.validatedContents(
            manifestData: Data(hostile.utf8),
            attachmentsByBinaryID: fixture.attachments
        )

        XCTAssertEqual(contents.logicalBreakpointCatalogAvailability, .unavailable)
        XCTAssertEqual(contents.launchProfileCatalogAvailability, .unavailable)
        XCTAssertTrue(contents.snapshot.logicalBreakpointCatalog.specifications.isEmpty)
        XCTAssertTrue(contents.snapshot.launchProfileCatalog.profiles.isEmpty)
    }

    func testValidatedContentsRejectsMissingAndUnknownAttachments() throws {
        let fixture = fixture(formatVersion: 1)
        let encoded = try MacScopeDocumentPackage.encodedManifest(fixture.manifest)

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validatedContents(
                manifestData: encoded,
                attachmentsByBinaryID: [:]
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .missingAttachment(fixture.manifest.binaries[0].attachmentRelativePath)
            )
        }

        let unknownID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        var attachments = fixture.attachments
        attachments[unknownID] = Data([0x99])
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validatedContents(
                manifestData: encoded,
                attachmentsByBinaryID: attachments
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .unknownAttachmentBinaryID(unknownID)
            )
        }
    }

    func testValidatedContentsRejectsAttachmentHashAndSizeMismatch() throws {
        let fixture = fixture(formatVersion: 1)
        let binary = fixture.manifest.binaries[0]

        var wrongHashManifest = fixture.manifest
        wrongHashManifest.binaries[0].fileHash = String(repeating: "f", count: 64)
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validatedContents(
                manifestData: MacScopeDocumentPackage.encodedManifest(wrongHashManifest),
                attachmentsByBinaryID: fixture.attachments
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .attachmentHashMismatch(
                    binary.attachmentRelativePath,
                    expected: String(repeating: "f", count: 64),
                    actual: binary.fileHash
                )
            )
        }

        var wrongSizeManifest = fixture.manifest
        wrongSizeManifest.binaries[0].fileSize += 1
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validatedContents(
                manifestData: MacScopeDocumentPackage.encodedManifest(wrongSizeManifest),
                attachmentsByBinaryID: fixture.attachments
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .attachmentSizeMismatch(
                    binary.attachmentRelativePath,
                    expected: binary.fileSize + 1,
                    actual: binary.fileSize
                )
            )
        }
    }

    func testZeroByteAttachmentSurvivesByteAndDiskPaths() throws {
        let fixture = fixture(formatVersion: 1, attachmentData: Data())
        let encoded = try MacScopeDocumentPackage.encodedManifest(fixture.manifest)
        let bytes = try MacScopeDocumentPackage.validatedContents(
            manifestData: encoded,
            attachmentsByBinaryID: fixture.attachments
        )

        XCTAssertEqual(bytes.attachmentsByBinaryID[fixture.binaryID], Data())
        XCTAssertEqual(bytes.snapshot.imageBytes, Data())

        try withTemporaryPackage { packageURL in
            try MacScopeDocumentPackage.writePackage(
                fixture.manifest,
                attachmentsByBinaryID: fixture.attachments,
                to: packageURL
            )
            let disk = try MacScopeDocumentPackage.openPackage(from: packageURL)
            XCTAssertEqual(disk.attachmentsByBinaryID[fixture.binaryID], Data())
            XCTAssertEqual(disk.snapshot.imageBytes, Data())
        }
    }

    private func assertByteAndDiskEquivalence(formatVersion: Int) throws {
        let fixture = fixture(formatVersion: formatVersion)
        let encoded = try MacScopeDocumentPackage.encodedManifest(fixture.manifest)
        XCTAssertEqual(encoded, try MacScopeDocumentPackage.encodedManifest(fixture.manifest))

        let bytes = try MacScopeDocumentPackage.validatedContents(
            manifestData: encoded,
            attachmentsByBinaryID: fixture.attachments
        )
        try withTemporaryPackage { packageURL in
            // Explicit legacy serialization keeps this fixture on v1/v2 after the v4 writer bump.
            try MacScopeDocumentPackage.writeManifest(fixture.manifest, to: packageURL)
            for binary in fixture.manifest.binaries {
                try XCTUnwrap(fixture.attachments[binary.id]).write(
                    to: MacScopeDocumentPackage.attachmentURL(in: packageURL, relativePath: binary.attachmentRelativePath)
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: packageURL)),
                encoded
            )
            let disk = try MacScopeDocumentPackage.openPackage(from: packageURL)
            XCTAssertEqual(
                try MacScopeDocumentPackage.encodedManifest(disk.manifest),
                try MacScopeDocumentPackage.encodedManifest(bytes.manifest)
            )
            XCTAssertEqual(disk.manifest.documentID, bytes.manifest.documentID)
            XCTAssertEqual(disk.manifest.workspaceUUID, bytes.manifest.workspaceUUID)
            XCTAssertEqual(disk.attachmentsByBinaryID, bytes.attachmentsByBinaryID)
            XCTAssertEqual(disk.snapshot.binaries, bytes.snapshot.binaries)
            XCTAssertEqual(
                Set(disk.snapshot.analysisBySlot.keys),
                Set(bytes.snapshot.analysisBySlot.keys)
            )
            for slot in bytes.snapshot.analysisBySlot.keys {
                XCTAssertEqual(
                    disk.snapshot.analysisBySlot[slot]?.imageBytes,
                    bytes.snapshot.analysisBySlot[slot]?.imageBytes
                )
                XCTAssertEqual(
                    disk.snapshot.analysisBySlot[slot]?.hexBytes,
                    bytes.snapshot.analysisBySlot[slot]?.hexBytes
                )
                XCTAssertEqual(
                    disk.snapshot.analysisBySlot[slot]?.functions.count,
                    bytes.snapshot.analysisBySlot[slot]?.functions.count
                )
                XCTAssertEqual(
                    disk.snapshot.analysisBySlot[slot]?.symbols.count,
                    bytes.snapshot.analysisBySlot[slot]?.symbols.count
                )
            }
            XCTAssertEqual(disk.snapshot.addressOverrides, bytes.snapshot.addressOverrides)
        }
    }

    private func fixture(
        formatVersion: Int,
        attachmentData: Data = Data([0xca, 0xfe, 0xba, 0xbe])
    ) -> (manifest: WorkspacePackageManifest, attachments: [UUID: Data], binaryID: UUID) {
        let binaryID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let isVersion2 = formatVersion == WorkspacePackageManifest.multiImageFormatVersion
        let imageSlot = isVersion2 ? ImageSlot(rawValue: 1) : .primary
        let binary = WorkspacePackageBinary(
            id: binaryID,
            displayName: "Codec Fixture",
            originalPath: "/fixture/codec.bin",
            attachmentRelativePath: "attachments/\(binaryID.uuidString.lowercased())/codec.bin",
            kind: "Raw data",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: attachmentData),
            fileSize: Int64(attachmentData.count),
            slot: imageSlot
        )
        let manifest = WorkspacePackageManifest(
            formatVersion: formatVersion,
            documentID: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            workspaceUUID: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            workspaceName: "Codec Fixture",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_001),
            binaries: [binary],
            analysis: WorkspacePackageAnalysis(),
            imageAnalyses: isVersion2
                ? [WorkspacePackageImageAnalysis(
                    binaryID: binaryID,
                    imageSlot: imageSlot,
                    analysis: WorkspacePackageAnalysis()
                )]
                : nil,
            session: nil
        )
        return (manifest, [binaryID: attachmentData], binaryID)
    }

    private func withTemporaryPackage(_ operation: (URL) throws -> Void) throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePackageByteCodecTests-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        try operation(packageURL)
    }
}
