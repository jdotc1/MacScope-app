import Foundation
import XCTest
@testable import MacScope

/// Regression coverage for the byte-address integrity core (Stage 1 of the persistence /
/// exact-byte-address tranche): the verified `FileAddressMapping` table, mapping-driven hex
/// editing that can never patch a fabricated address, exact selected-slice extraction, and the
/// database restore byte invariant.
///
/// The multi-image persistence surface from the originally proposed tranche (per-slot payloads,
/// sibling-preserving reanalysis, package/DB slot round-trip, collision-import authoring copy)
/// is deliberately NOT covered here — it is latent behind the unshipped "Load Additional
/// Binary" feature and folds into the later per-image container refactor, so those tests were
/// discarded from this integration rather than asserted against speculative APIs.
final class PersistenceByteIntegrityTests: XCTestCase {

    // MARK: - Verified byte mappings (section-derived clamps)

    func testSectionMappingsClampToPhysicalBytesPayloadAndNextSection() {
        let sections = [
            SectionSummary(
                id: UUID(), name: ".text", address: 0x1_0000,
                size: 0x1000, fileOffset: 0x100, isExecutable: true, fileSize: 0x80
            ),
            SectionSummary(
                id: UUID(), name: ".data", address: 0x2_0000,
                size: 0x100, fileOffset: 0x160, isExecutable: false
            ),
            SectionSummary(
                id: UUID(), name: ".bss", address: 0x3_0000,
                size: 0x400, fileOffset: 0x200, isExecutable: false, isZeroFill: true
            )
        ]

        let mappings = FileAddressMapping.verifiedMappings(from: sections, payloadLength: 0x240)
        XCTAssertEqual(mappings.count, 2)
        // Physical .text bytes say 0x80, but the next raw section begins after 0x60 bytes.
        XCTAssertEqual(mappings[0].size, 0x60)
        XCTAssertEqual(mappings[0].virtualAddress(forFileOffset: 0x15f), 0x1_005f)
        XCTAssertNil(mappings[0].virtualAddress(forFileOffset: 0x160))
        // A legacy section with no explicit fileSize is clamped to the payload boundary.
        XCTAssertEqual(mappings[1].size, 0xe0)
        // Zero-fill memory never acquires a file mapping.
        XCTAssertFalse(mappings.contains { $0.sectionName == ".bss" })
    }

    func testSectionMappingsDoNotInventAddressesForRawPaddingPastVirtualSize() {
        let section = SectionSummary(
            id: UUID(), name: ".raw-padded", address: 0x5000,
            size: 4, fileOffset: 0, isExecutable: true, fileSize: 8
        )

        let mappings = FileAddressMapping.verifiedMappings(from: [section], payloadLength: 8)
        XCTAssertEqual(mappings, [
            FileAddressMapping(
                fileOffset: 0, size: 4, virtualAddress: 0x5000, sectionName: ".raw-padded"
            )
        ])
        XCTAssertNil(mappings[0].virtualAddress(forFileOffset: 4))
    }

    // MARK: - Mapping-driven hex editing

    func testHexEditorRejectsUnmappedHeaderAndUsesExactMappedAddress() {
        let bytes = Data((0..<16).map { UInt8($0) })
        let model = HexEditModel(
            bytes: bytes,
            mappings: [
                FileAddressMapping(
                    fileOffset: 4,
                    size: 8,
                    virtualAddress: 0x1_0000_1000,
                    sectionName: "__TEXT,__text"
                )
            ]
        )

        XCTAssertFalse(model.isReadOnly, "mapped cells keep the mixed window editable")
        XCTAssertNil(model.address(forOffset: 0), "header bytes must not inherit the first instruction address")
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: "ff"), .unmapped)
        XCTAssertEqual(model.address(forOffset: 4), 0x1_0000_1000)
        XCTAssertEqual(
            model.resolveEdit(offset: 11, hexByte: "fe"),
            .patch(address: 0x1_0000_1007, byte: 0xfe)
        )
        XCTAssertEqual(model.offset(forAddress: 0x1_0000_1003), 7)
        XCTAssertNil(model.address(forOffset: 12))
    }

    func testConflictingAliasesNeverChooseAnAddress() {
        let model = HexEditModel(
            bytes: Data([0xaa]),
            mappings: [
                FileAddressMapping(fileOffset: 0, size: 1, virtualAddress: 0x1000, sectionName: "a"),
                FileAddressMapping(fileOffset: 0, size: 1, virtualAddress: 0x2000, sectionName: "b")
            ]
        )

        XCTAssertTrue(model.isReadOnly)
        XCTAssertNil(model.address(forOffset: 0))
        XCTAssertNil(model.offset(forAddress: 0x1000), "reverse lookup is also ambiguity-safe")
    }

    func testEmptyMappingsWindowIsReadOnly() {
        let model = HexEditModel(bytes: Data([0xaa, 0xbb]), mappings: [])
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(model.resolveEdit(offset: 0, hexByte: "4f"), .readOnly)
        XCTAssertNil(model.address(forOffset: 0))
    }

    // MARK: - Exact selected-slice extraction

    func testAnalysisPersistsOnlyTheExactSelectedSlice() throws {
        let prefix = Data([0xde, 0xad, 0xbe])
        let payload = Data([0xca, 0xfe, 0xba, 0xbe, 0xc0, 0x03, 0x5f, 0xd6])
        let suffix = Data([0xfa, 0xce, 0xfa, 0xce])
        let container = prefix + payload + suffix
        let text = BinarySection(
            name: ".text", address: 0x4004, size: 4, fileOffset: 4,
            isExecutable: true, fileSize: 4
        )
        let loaded = LoadedBinary(
            name: "fat-fixture", path: "/tmp/fat-fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "universal fixture", architectureDisplayName: "arm64 slice 3",
            metadata: BinaryMetadataSummary(uuid: "slice-uuid"),
            bytes: container,
            sliceOffset: UInt64(prefix.count),
            sliceSize: UInt64(payload.count),
            sections: [text], executableTextSection: text, entryPointAddress: 0x4004,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [0x4004], objcSelectors: [:]
        )

        let snapshot = try AnalysisEngine(
            loader: IntegrityStubLoader(binary: loaded),
            decoder: IntegrityStubDisassembler()
        ).analyze(url: URL(fileURLWithPath: "/tmp/ignored"))

        XCTAssertEqual(snapshot.imageBytes, payload, "only the declared selected-slice extent is persisted")
        XCTAssertEqual(snapshot.hexBytes, payload, "the window is a prefix of the exact slice (payload < 4 KiB here)")
        XCTAssertFalse(snapshot.imageBytes.contains(0xfa), "trailing bytes past the slice must be excluded")
        XCTAssertEqual(snapshot.binaries.first?.selectedSliceIndex, nil)
        XCTAssertEqual(snapshot.instructions.first?.mnemonic, "integrity_stub")
    }

    func testAnalysisRejectsLoaderSliceExtentBeyondContainer() throws {
        let bytes = Data([0xaa, 0xbb, 0xcc, 0xdd])
        let section = BinarySection(
            name: ".text", address: 0x1000, size: 1, fileOffset: 0,
            isExecutable: true, fileSize: 1
        )
        let loaded = LoadedBinary(
            name: "invalid-slice", path: "/tmp/invalid-slice", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64,
            fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty, bytes: bytes,
            sliceOffset: 2, sliceSize: 8,
            sections: [section], executableTextSection: section,
            entryPointAddress: 0x1000, symbols: [], imports: [], indirectSymbols: [],
            exports: [], stringLiterals: [], functionStarts: [0x1000], objcSelectors: [:]
        )

        XCTAssertThrowsError(
            try AnalysisEngine(
                loader: IntegrityStubLoader(binary: loaded),
                decoder: IntegrityStubDisassembler()
            ).analyze(url: URL(fileURLWithPath: "/tmp/ignored"))
        ) { error in
            guard let analysisError = error as? AnalysisEngineError,
                  case .invalidSelectedSliceRange(let offset, let size, let containerSize) = analysisError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(offset, UInt64(2))
            XCTAssertEqual(size, UInt64(8))
            XCTAssertEqual(containerSize, bytes.count)
        }
    }

    // MARK: - Database restore byte invariant (f6)

    func testDatabaseRestorePopulatesExactImageBytesAndBoundedHexWindow() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let payload = Data((0..<7000).map { UInt8(truncatingIfNeeded: $0) })
        let binary = BinaryImage(
            id: UUID(), name: "primary", path: "/gone/primary",
            kind: "Mach-O executable", architecture: "arm64"
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [binary], functions: [], instructions: [], xrefs: [],
            hexBytes: Data(payload.prefix(WorkspaceSnapshot.hexViewByteWindow)),
            imageBytes: payload
        )

        let workspace = try database.saveSnapshot(workspaceName: "byte-invariant", snapshot: snapshot)
        let restored = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))

        XCTAssertEqual(restored.imageBytes, payload, "the full exact payload is restored into imageBytes")
        XCTAssertEqual(restored.hexBytes.count, WorkspaceSnapshot.hexViewByteWindow,
                       "hexBytes stays a bounded window, not the whole blob")
        XCTAssertEqual(restored.hexBytes, Data(payload.prefix(WorkspaceSnapshot.hexViewByteWindow)))
    }

    // MARK: - Persisted selected-slice pick (f2)

    func testSelectedSliceIndexRoundTripsThroughDatabase() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)

        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let sliced = BinaryImage(
            id: UUID(), name: "universal", path: "/gone/universal",
            kind: "Mach-O executable", architecture: "arm64", selectedSliceIndex: 2
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [sliced], functions: [], instructions: [], xrefs: [],
            hexBytes: payload, imageBytes: payload
        )

        let workspace = try database.saveSnapshot(workspaceName: "slice-pick", snapshot: snapshot)
        let restored = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertEqual(restored.binaries.first?.selectedSliceIndex, 2,
                       "a reopened universal-binary document keeps its slice pick")
    }

    func testDefaultSliceSelectionRoundTripsAsNil() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        let payload = Data([0xaa])
        let thin = BinaryImage(
            id: UUID(), name: "thin", path: "/gone/thin",
            kind: "Mach-O executable", architecture: "arm64"
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [thin], functions: [], instructions: [], xrefs: [],
            hexBytes: payload, imageBytes: payload
        )

        let workspace = try database.saveSnapshot(workspaceName: "thin", snapshot: snapshot)
        let restored = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        XCTAssertNil(restored.binaries.first?.selectedSliceIndex, "no pick persists (and restores) as nil")
    }

    func testELFArchiveMemberIdentityRoundTripsThroughDatabaseAsCanonicalOptionalJSON() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46, 0x01, 0x02])
        let selection = Self.archiveSelection(payload: payload)
        let binary = BinaryImage(
            id: UUID(), name: "member.o", path: "/tmp/libfixture.a",
            kind: "ELF relocatable object", architecture: "arm64",
            elfArchiveMemberIdentity: selection
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [binary], functions: [], instructions: [], xrefs: [],
            hexBytes: payload, imageBytes: payload
        )

        let workspace = try database.saveSnapshot(workspaceName: "archive", snapshot: snapshot)
        let workspaceID = try XCTUnwrap(workspace.id)
        let stored = try XCTUnwrap(database.scalarTextForTesting(
            "SELECT elf_archive_member_identity_json FROM binaries WHERE workspace_id = \(workspaceID);"
        ))
        let restored = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))

        XCTAssertEqual(
            stored,
            try String(decoding: JSONEncoder.sorted.encode(selection), as: UTF8.self)
        )
        XCTAssertEqual(restored.binaries.first?.path, "/tmp/libfixture.a")
        XCTAssertEqual(restored.binaries.first?.elfArchiveMemberIdentity, selection)
        XCTAssertEqual(restored.imageBytes, payload)
    }

    func testDatabaseRejectsDeletedArchiveIdentityWhenFingerprintStillBindsMember() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46, 0x11, 0x22])
        let selection = Self.archiveSelection(payload: payload)
        let binary = BinaryImage(
            id: UUID(), name: "member.o", path: "/tmp/libfixture.a",
            kind: "ELF relocatable object", architecture: "arm64",
            elfArchiveMemberIdentity: selection
        )
        var analysis = ImageAnalysis()
        analysis.hexBytes = payload
        analysis.imageBytes = payload
        analysis.analysisInputFingerprint = try Self.archiveFingerprint(
            binary: binary,
            payload: payload
        )
        let workspace = try database.saveSnapshot(
            workspaceName: "archive-null-deletion",
            snapshot: WorkspaceSnapshot(
                binaries: [binary],
                analysisBySlot: [.primary: analysis]
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)

        // Deliberate persistence mutation: removing only the binary-row anchor must not turn an
        // archive member into an ordinary ELF while its independent fingerprint still says archive.
        try database.executeRawForTesting(
            "UPDATE binaries SET elf_archive_member_identity_json = NULL WHERE workspace_id = \(workspaceID);"
        )

        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID)) { error in
            guard let databaseError = error as? WorkspaceDatabase.DatabaseError,
                  case .corruptRow(
                table: "binaries",
                rowIdentity: _,
                field: "elf_archive_member_identity_json"
            ) = databaseError else {
                return XCTFail("Expected archive-identity corruption, got \(error)")
            }
        }
    }

    func testMalformedELFArchiveMemberIdentityJSONFailsClosedOnDatabaseRestore() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46])
        let binary = BinaryImage(
            id: UUID(), name: "member.o", path: "/tmp/libfixture.a",
            kind: "ELF relocatable object", architecture: "arm64",
            elfArchiveMemberIdentity: Self.archiveSelection(payload: payload)
        )
        let workspace = try database.saveSnapshot(
            workspaceName: "malformed-archive",
            snapshot: WorkspaceSnapshot(
                binaries: [binary], functions: [], instructions: [], xrefs: [],
                hexBytes: payload, imageBytes: payload
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting(
            "UPDATE binaries SET elf_archive_member_identity_json = '{' WHERE workspace_id = \(workspaceID);"
        )

        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID))
    }

    func testWellFormedButTamperedELFArchiveMemberIdentityFailsClosedOnDatabaseRestore() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46])
        let binary = BinaryImage(
            id: UUID(), name: "member.o", path: "/tmp/libfixture.a",
            kind: "ELF relocatable object", architecture: "arm64",
            elfArchiveMemberIdentity: Self.archiveSelection(payload: payload)
        )
        let workspace = try database.saveSnapshot(
            workspaceName: "tampered-archive",
            snapshot: WorkspaceSnapshot(
                binaries: [binary], functions: [], instructions: [], xrefs: [],
                hexBytes: payload, imageBytes: payload
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let stored = try XCTUnwrap(database.scalarTextForTesting(
            "SELECT elf_archive_member_identity_json FROM binaries WHERE workspace_id = \(workspaceID);"
        ))
        let tampered = stored.replacingOccurrences(
            of: MacScopeDocumentPackage.fileHash(for: payload),
            with: String(repeating: "0", count: 64)
        )
        try database.executeRawForTesting(
            "UPDATE binaries SET elf_archive_member_identity_json = '\(tampered)' WHERE workspace_id = \(workspaceID);"
        )

        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID))
    }

    func testBinaryMetadataRoundTripsThroughDatabaseAsCanonicalOptionalJSON() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let metadata = BinaryMetadataSummary(
            uuid: "Mach-O-domain-value",
            elfGNUBuildID: "00112233445566778899aabbccddeeff",
            platformName: "GNU/Linux",
            minimumOSVersion: "6.8.0",
            sdkVersion: "2.41",
            buildTools: ["ld", "clang"]
        )
        let binary = BinaryImage(
            id: UUID(), name: "ELF", path: "/gone/elf", kind: "ELF executable",
            architecture: "arm64", metadata: metadata
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [binary], functions: [], instructions: [], xrefs: [],
            hexBytes: Data([0x7f, 0x45, 0x4c, 0x46]),
            imageBytes: Data([0x7f, 0x45, 0x4c, 0x46])
        )

        let workspace = try database.saveSnapshot(workspaceName: "metadata", snapshot: snapshot)
        let workspaceID = try XCTUnwrap(workspace.id)
        let stored = try XCTUnwrap(database.scalarTextForTesting(
            "SELECT binary_metadata_json FROM binaries WHERE workspace_id = \(workspaceID);"
        ))
        let restored = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))

        XCTAssertEqual(
            stored,
            #"{"buildTools":["ld","clang"],"elfGNUBuildID":"00112233445566778899aabbccddeeff","minimumOSVersion":"6.8.0","platformName":"GNU/Linux","sdkVersion":"2.41","uuid":"Mach-O-domain-value"}"#
        )
        XCTAssertEqual(restored.binaries.first?.metadata, metadata)
        XCTAssertNotEqual(restored.binaries.first?.metadata.uuid, restored.binaries.first?.metadata.elfGNUBuildID)
    }

    func testDatabaseRejectsWellFormedGNUBuildIDReplacementAgainstFingerprint() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00])
        let originalBuildID = "00112233445566778899aabbccddeeff"
        let replacementBuildID = "ffeeddccbbaa99887766554433221100"
        let binary = BinaryImage(
            id: UUID(), name: "ELF", path: "/gone/elf", kind: "ELF executable",
            architecture: "arm64",
            metadata: BinaryMetadataSummary(
                elfGNUBuildID: originalBuildID,
                platformName: "GNU/Linux"
            )
        )
        var analysis = ImageAnalysis()
        analysis.imageBytes = payload
        analysis.hexBytes = payload
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        let workspace = try database.saveSnapshot(
            workspaceName: "metadata-fingerprint",
            snapshot: WorkspaceSnapshot(
                binaries: [binary],
                analysisBySlot: [.primary: analysis]
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let stored = try XCTUnwrap(database.scalarTextForTesting(
            "SELECT binary_metadata_json FROM binaries WHERE workspace_id = \(workspaceID);"
        ))
        let tampered = stored.replacingOccurrences(
            of: originalBuildID,
            with: replacementBuildID
        )
        XCTAssertNotEqual(stored, tampered)
        try database.executeRawForTesting(
            "UPDATE binaries SET binary_metadata_json = '\(tampered)' WHERE workspace_id = \(workspaceID);"
        )

        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID)) { error in
            guard let databaseError = error as? WorkspaceDatabase.DatabaseError,
                  case .corruptRow(
                    table: "binaries",
                    rowIdentity: _,
                    field: "binary_metadata_json"
                  ) = databaseError else {
                return XCTFail("Expected loader-metadata fingerprint corruption, got \(error)")
            }
        }
    }

    func testDatabaseRejectsDeletedGNUBuildIDAgainstFingerprint() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let fixture = try Self.elfMetadataFingerprintFixture()
        let workspace = try database.saveSnapshot(
            workspaceName: "metadata-build-id-deletion",
            snapshot: WorkspaceSnapshot(
                binaries: [fixture.binary],
                analysisBySlot: [.primary: fixture.analysis]
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let stored = try XCTUnwrap(database.scalarTextForTesting(
            "SELECT binary_metadata_json FROM binaries WHERE workspace_id = \(workspaceID);"
        ))
        var metadataObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(metadataObject.removeValue(forKey: "elfGNUBuildID"))
        let tampered = String(decoding: try JSONSerialization.data(
            withJSONObject: metadataObject,
            options: [.sortedKeys]
        ), as: UTF8.self)
        try database.executeRawForTesting(
            "UPDATE binaries SET binary_metadata_json = '\(tampered)' WHERE workspace_id = \(workspaceID);"
        )

        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID)) { error in
            guard let databaseError = error as? WorkspaceDatabase.DatabaseError,
                  case .corruptRow(
                    table: "binaries",
                    rowIdentity: _,
                    field: "binary_metadata_json"
                  ) = databaseError else {
                return XCTFail("Expected deleted GNU build-ID corruption, got \(error)")
            }
        }
    }

    func testDatabaseRejectsELFKindDriftAgainstFingerprintBoundAttachment() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let fixture = try Self.elfMetadataFingerprintFixture()
        let workspace = try database.saveSnapshot(
            workspaceName: "metadata-kind-drift",
            snapshot: WorkspaceSnapshot(
                binaries: [fixture.binary],
                analysisBySlot: [.primary: fixture.analysis]
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting(
            "UPDATE binaries SET kind = 'PE executable' WHERE workspace_id = \(workspaceID);"
        )

        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID)) { error in
            guard let databaseError = error as? WorkspaceDatabase.DatabaseError,
                  case .corruptRow(
                    table: "binaries",
                    rowIdentity: _,
                    field: "binary_metadata_json"
                  ) = databaseError else {
                return XCTFail("Expected ELF kind-drift corruption, got \(error)")
            }
        }
    }

    func testFingerprintBoundELFRejectsIncompatibleMachOArtifactIdentityInjection() throws {
        let fixture = try Self.elfMetadataFingerprintFixture()
        var fingerprint = try XCTUnwrap(fixture.analysis.analysisInputFingerprint)
        fingerprint.artifactIdentity = try MachOSliceArtifactIdentity(
            uuid: nil,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: MacScopeDocumentPackage.fileHash(for: fixture.payload),
            selectedSliceByteCount: UInt64(fixture.payload.count)
        )

        XCTAssertFalse(try AnalysisFingerprintBuilder.persistedELFLoadMetadataMatchesFingerprint(
            attachmentData: fixture.payload,
            persistedKind: fixture.binary.kind,
            metadata: fixture.binary.metadata,
            fingerprint: fingerprint
        ))
    }

    func testFingerprintBoundLegacyELFWithoutGNUBuildIDRemainsCompatible() throws {
        let payload = Data([0x7f, 0x45, 0x4c, 0x46, 0x01, 0x01, 0x01, 0x00])
        let binary = BinaryImage(
            id: UUID(),
            name: "legacy-elf",
            path: "/gone/legacy-elf",
            kind: "ELF executable",
            architecture: "arm64",
            metadata: BinaryMetadataSummary(platformName: "GNU/Linux")
        )
        var analysis = ImageAnalysis()
        analysis.imageBytes = payload
        analysis.hexBytes = payload
        let fingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )

        XCTAssertTrue(try AnalysisFingerprintBuilder.persistedELFLoadMetadataMatchesFingerprint(
            attachmentData: payload,
            persistedKind: binary.kind,
            metadata: binary.metadata,
            fingerprint: fingerprint
        ))
    }

    func testMalformedBinaryMetadataJSONFailsClosedOnDatabaseRestore() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let binary = BinaryImage(
            id: UUID(), name: "ELF", path: "/gone/elf", kind: "ELF executable",
            architecture: "arm64", metadata: BinaryMetadataSummary(elfGNUBuildID: "aabb")
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [binary], functions: [], instructions: [], xrefs: [],
            hexBytes: Data([0x7f]), imageBytes: Data([0x7f])
        )
        let workspace = try database.saveSnapshot(workspaceName: "malformed", snapshot: snapshot)
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting(
            "UPDATE binaries SET binary_metadata_json = '{' WHERE workspace_id = \(workspaceID);"
        )

        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID))
    }

    func testVersion40MigrationAddsOptionalBinaryMetadataWithoutBackfill() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let binary = BinaryImage(
            id: UUID(), name: "legacy", path: "/gone/legacy",
            kind: "ELF executable", architecture: "arm64"
        )
        let workspace = try database.saveSnapshot(
            workspaceName: "v40",
            snapshot: WorkspaceSnapshot(
                binaries: [binary], functions: [], instructions: [], xrefs: [],
                hexBytes: Data([0x7f]), imageBytes: Data([0x7f])
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting("ALTER TABLE binaries DROP COLUMN binary_metadata_json;")
        try database.executeRawForTesting("ALTER TABLE binaries DROP COLUMN elf_archive_member_identity_json;")
        try database.setUserVersionForTesting(40)

        try database.applySchema()

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try database.columnNames(in: "binaries").contains("binary_metadata_json"))
        XCTAssertTrue(try database.columnNames(in: "binaries").contains("elf_archive_member_identity_json"))
        XCTAssertNil(try database.scalarTextForTesting(
            "SELECT binary_metadata_json FROM binaries WHERE workspace_id = \(workspaceID);"
        ))
        XCTAssertEqual(
            try database.loadSnapshot(workspaceID: workspaceID)?.binaries.first?.metadata,
            .empty
        )
        XCTAssertNil(try database.loadSnapshot(workspaceID: workspaceID)?
            .binaries.first?.elfArchiveMemberIdentity)
    }

    func testCurrentSchemaRejectsMissingBinaryMetadataColumns() throws {
        for missingColumn in [
            "binary_metadata_json",
            "elf_archive_member_identity_json",
        ] {
            let database = try WorkspaceDatabase.inMemory()
            try database.applySchema()
            XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
            try database.executeRawForTesting(
                "ALTER TABLE binaries DROP COLUMN \(missingColumn);"
            )

            XCTAssertThrowsError(try database.applySchema()) { error in
                XCTAssertEqual(
                    error as? WorkspaceDatabase.DatabaseError,
                    .binaryMetadataSchemaInvalid(columns: [missingColumn])
                )
            }
        }
    }

    func testSelectedSliceIndexRoundTripsThroughPackage() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceByteIntegrity-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let id = UUID()
        let payload = Data([0xca, 0xfe, 0xba, 0xbe, 0x00, 0x11])
        let packageBinary = WorkspacePackageBinary(
            id: id,
            displayName: "universal",
            originalPath: "/tmp/universal",
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: id, originalPath: "/tmp/universal"
            ),
            kind: "executable",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: payload),
            fileSize: Int64(payload.count),
            selectedSliceIndex: 3
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(), workspaceUUID: UUID(), workspaceName: "Slice pick",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_001),
            binaries: [packageBinary], analysis: nil, session: nil
        )

        try MacScopeDocumentPackage.writePackage(
            manifest, attachmentsByBinaryID: [id: payload], to: packageURL
        )
        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)
        XCTAssertEqual(opened.snapshot.binaries.first?.selectedSliceIndex, 3,
                       "the package round-trips the selected-slice pick onto the restored image")
    }

    func testBinaryMetadataRoundTripsThroughWorkspacePackage() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceMetadata-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let id = UUID()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46])
        let metadata = BinaryMetadataSummary(
            uuid: nil,
            elfGNUBuildID: "00112233445566778899aabbccddeeff",
            platformName: "GNU/Linux"
        )
        let packageBinary = WorkspacePackageBinary(
            id: id,
            displayName: "elf",
            originalPath: "/tmp/elf",
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: id, originalPath: "/tmp/elf"
            ),
            kind: "ELF executable",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: payload),
            fileSize: Int64(payload.count),
            metadata: metadata
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(), workspaceUUID: UUID(), workspaceName: "ELF metadata",
            createdAt: Date(timeIntervalSince1970: 1_800_000_010),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_011),
            binaries: [packageBinary], analysis: nil, session: nil
        )

        try MacScopeDocumentPackage.writePackage(
            manifest, attachmentsByBinaryID: [id: payload], to: packageURL
        )
        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)

        XCTAssertEqual(opened.manifest.binaries.first?.metadata, metadata)
        XCTAssertEqual(opened.snapshot.binaries.first?.metadata, metadata)
        XCTAssertNil(opened.snapshot.binaries.first?.metadata.uuid)
        XCTAssertEqual(opened.snapshot.binaries.first?.metadata.elfGNUBuildID, metadata.elfGNUBuildID)
    }

    func testPackageRejectsWellFormedGNUBuildIDReplacementAgainstFingerprint() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceMetadataTamper-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let id = UUID()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00])
        let originalBuildID = "00112233445566778899aabbccddeeff"
        let replacementBuildID = "ffeeddccbbaa99887766554433221100"
        let metadata = BinaryMetadataSummary(
            elfGNUBuildID: originalBuildID,
            platformName: "GNU/Linux"
        )
        let binaryImage = BinaryImage(
            id: id, name: "elf", path: "/tmp/elf", kind: "ELF executable",
            architecture: "arm64", metadata: metadata
        )
        var analysis = ImageAnalysis()
        analysis.imageBytes = payload
        analysis.hexBytes = payload
        let fingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binaryImage,
            analysis: analysis
        )
        let packageBinary = WorkspacePackageBinary(
            id: id,
            displayName: binaryImage.name,
            originalPath: binaryImage.path,
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: id, originalPath: binaryImage.path
            ),
            kind: binaryImage.kind,
            architecture: binaryImage.architecture,
            fileHash: MacScopeDocumentPackage.fileHash(for: payload),
            fileSize: Int64(payload.count),
            metadata: metadata
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(), workspaceUUID: UUID(), workspaceName: "ELF metadata tamper",
            createdAt: Date(timeIntervalSince1970: 1_800_000_012),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_013),
            binaries: [packageBinary],
            analysis: WorkspacePackageAnalysis(analysisInputFingerprint: fingerprint),
            session: nil
        )
        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: [id: payload],
            to: packageURL
        )

        let manifestURL = MacScopeDocumentPackage.manifestURL(in: packageURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var binaries = try XCTUnwrap(object["binaries"] as? [[String: Any]])
        var persistedMetadata = try XCTUnwrap(binaries[0]["metadata"] as? [String: Any])
        persistedMetadata["elfGNUBuildID"] = replacementBuildID
        binaries[0]["metadata"] = persistedMetadata
        object["binaries"] = binaries
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL, options: [.atomic])

        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: packageURL)) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .binaryMetadataFingerprintMismatch(id)
            )
        }
    }

    func testPackageRejectsDeletedGNUBuildIDAgainstFingerprint() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceMetadataDeletion-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let fixture = try Self.elfMetadataFingerprintFixture()
        try Self.writeELFMetadataFingerprintPackage(fixture, to: packageURL)
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: packageURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var binaries = try XCTUnwrap(object["binaries"] as? [[String: Any]])
        var metadata = try XCTUnwrap(binaries[0]["metadata"] as? [String: Any])
        XCTAssertNotNil(metadata.removeValue(forKey: "elfGNUBuildID"))
        binaries[0]["metadata"] = metadata
        object["binaries"] = binaries
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL, options: [.atomic])

        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: packageURL)) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .binaryMetadataFingerprintMismatch(fixture.binary.id)
            )
        }
    }

    func testPackageRejectsELFKindDriftAgainstFingerprintBoundAttachment() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceMetadataKindDrift-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let fixture = try Self.elfMetadataFingerprintFixture()
        try Self.writeELFMetadataFingerprintPackage(fixture, to: packageURL)
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: packageURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        var binaries = try XCTUnwrap(object["binaries"] as? [[String: Any]])
        binaries[0]["kind"] = "PE executable"
        object["binaries"] = binaries
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL, options: [.atomic])

        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: packageURL)) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .binaryMetadataFingerprintMismatch(fixture.binary.id)
            )
        }
    }

    func testELFArchiveMemberIdentityRoundTripsThroughWorkspacePackage() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceArchive-\(UUID().uuidString)")
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        let id = UUID()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46, 0xaa, 0xbb])
        let selection = Self.archiveSelection(payload: payload)
        let packageBinary = WorkspacePackageBinary(
            id: id,
            displayName: "member.o",
            originalPath: "/tmp/libfixture.a",
            originalPathBookmark: Data([0x01, 0x02]),
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: id, originalPath: "/tmp/libfixture.a"
            ),
            kind: "ELF relocatable object",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: payload),
            fileSize: Int64(payload.count),
            elfArchiveMemberIdentity: selection
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(), workspaceUUID: UUID(), workspaceName: "Archive",
            createdAt: Date(timeIntervalSince1970: 1_800_000_020),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_021),
            binaries: [packageBinary], analysis: nil, session: nil
        )

        try MacScopeDocumentPackage.writePackage(
            manifest, attachmentsByBinaryID: [id: payload], to: packageURL
        )
        let opened = try MacScopeDocumentPackage.openPackage(from: packageURL)

        XCTAssertEqual(opened.manifest.binaries.first?.elfArchiveMemberIdentity, selection)
        XCTAssertEqual(opened.snapshot.binaries.first?.path, "/tmp/libfixture.a")
        XCTAssertEqual(opened.snapshot.binaries.first?.originalPathBookmark, Data([0x01, 0x02]))
        XCTAssertEqual(opened.snapshot.binaries.first?.elfArchiveMemberIdentity, selection)
        XCTAssertEqual(opened.snapshot.imageBytes, payload)
    }

    func testPackageRejectsDeletedArchiveIdentityKeyWhenFingerprintStillBindsMember() throws {
        let id = UUID()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46, 0x33, 0x44])
        let selection = Self.archiveSelection(payload: payload)
        let binaryImage = BinaryImage(
            id: id, name: "member.o", path: "/tmp/libfixture.a",
            kind: "ELF relocatable object", architecture: "arm64",
            elfArchiveMemberIdentity: selection
        )
        let packageBinary = WorkspacePackageBinary(
            id: id,
            displayName: binaryImage.name,
            originalPath: binaryImage.path,
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: id, originalPath: binaryImage.path
            ),
            kind: binaryImage.kind,
            architecture: binaryImage.architecture,
            fileHash: MacScopeDocumentPackage.fileHash(for: payload),
            fileSize: Int64(payload.count),
            elfArchiveMemberIdentity: selection
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(), workspaceUUID: UUID(), workspaceName: "Archive deletion",
            createdAt: Date(timeIntervalSince1970: 1_800_000_030),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_031),
            binaries: [packageBinary],
            analysis: WorkspacePackageAnalysis(
                analysisInputFingerprint: try Self.archiveFingerprint(
                    binary: binaryImage,
                    payload: payload
                )
            ),
            session: nil
        )
        XCTAssertEqual(
            manifest.formatVersion,
            WorkspacePackageManifest.currentFormatVersion,
            "optional archive identity does not impersonate a v3 reconstruction package"
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: MacScopeDocumentPackage.encodedManifest(manifest)
            ) as? [String: Any]
        )
        var binaries = try XCTUnwrap(object["binaries"] as? [[String: Any]])
        XCTAssertNotNil(binaries[0].removeValue(forKey: "elfArchiveMemberIdentity"))
        object["binaries"] = binaries
        let tamperedManifestData = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validatedContents(
                manifestData: tamperedManifestData,
                attachmentsByBinaryID: [id: payload]
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .archiveMemberFingerprintMismatch(id)
            )
        }
    }

    func testPackageRejectsArchiveIdentityThatDoesNotMatchAttachmentDeclaration() throws {
        let id = UUID()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46])
        let packageBinary = WorkspacePackageBinary(
            id: id,
            displayName: "member.o",
            originalPath: "/tmp/libfixture.a",
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: id, originalPath: "/tmp/libfixture.a"
            ),
            kind: "ELF relocatable object",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: payload),
            fileSize: Int64(payload.count),
            elfArchiveMemberIdentity: Self.archiveSelection(
                payload: Data([0x7f, 0x45, 0x4c, 0x47])
            )
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(), workspaceUUID: UUID(), workspaceName: "Tampered archive",
            createdAt: Date(), modifiedAt: Date(), binaries: [packageBinary], analysis: nil,
            session: nil
        )

        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validateManifest(
                manifest,
                in: FileManager.default.temporaryDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .archiveMemberAttachmentMismatch(id)
            )
        }
    }

    func testWorkspacePackageBinaryDecodingRejectsMalformedArchiveIdentity() throws {
        let id = UUID()
        let payload = Data([0x7f, 0x45, 0x4c, 0x46])
        let binary = WorkspacePackageBinary(
            id: id,
            displayName: "member.o",
            originalPath: "/tmp/libfixture.a",
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: id, originalPath: "/tmp/libfixture.a"
            ),
            kind: "ELF relocatable object",
            architecture: "arm64",
            fileHash: MacScopeDocumentPackage.fileHash(for: payload),
            fileSize: Int64(payload.count),
            elfArchiveMemberIdentity: Self.archiveSelection(payload: payload)
        )
        let encoded = try JSONEncoder().encode(binary)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var selection = try XCTUnwrap(
            object["elfArchiveMemberIdentity"] as? [String: Any]
        )
        var container = try XCTUnwrap(selection["container"] as? [String: Any])
        container["sha256"] = String(repeating: "A", count: 64)
        selection["container"] = container
        object["elfArchiveMemberIdentity"] = selection
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(WorkspacePackageBinary.self, from: malformed)
        )
    }

    func testLegacyPackageBinaryWithoutSelectedSliceIndexDecodesAsNil() throws {
        // A pre-v26 package manifest never wrote the key; synthesized Decodable must tolerate its
        // absence (nil), so no package-format bump is forced on old documents.
        let json = Data("""
        {
          "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
          "displayName": "legacy",
          "originalPath": "/tmp/legacy",
          "attachmentRelativePath": "attachments/legacy.bin",
          "kind": "executable",
          "architecture": "arm64",
          "fileHash": "abc",
          "fileSize": 4
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(WorkspacePackageBinary.self, from: json)
        XCTAssertNil(decoded.selectedSliceIndex)
        XCTAssertNil(decoded.metadata)
        XCTAssertNil(decoded.elfArchiveMemberIdentity)
    }

    private static func archiveSelection(payload: Data) -> ELFArchiveMemberSelection {
        ELFArchiveMemberSelection(
            container: ELFArchiveContainerIdentity(
                byteCount: 512,
                sha256: String(repeating: "a", count: 64)
            ),
            member: ELFArchiveMemberIdentity(
                index: 1,
                archiveHeaderIndex: 3,
                name: "member.o",
                payloadOffset: 128,
                byteCount: payload.count,
                sha256: MacScopeDocumentPackage.fileHash(for: payload)
            )
        )
    }

    private static func elfMetadataFingerprintFixture() throws -> (
        binary: BinaryImage,
        analysis: ImageAnalysis,
        payload: Data
    ) {
        let payload = Data([0x7f, 0x45, 0x4c, 0x46, 0x02, 0x01, 0x01, 0x00])
        let binary = BinaryImage(
            id: UUID(),
            name: "ELF",
            path: "/gone/elf",
            kind: "ELF executable",
            architecture: "arm64",
            metadata: BinaryMetadataSummary(
                elfGNUBuildID: "00112233445566778899aabbccddeeff",
                platformName: "GNU/Linux"
            )
        )
        var analysis = ImageAnalysis()
        analysis.imageBytes = payload
        analysis.hexBytes = payload
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        return (binary, analysis, payload)
    }

    private static func writeELFMetadataFingerprintPackage(
        _ fixture: (binary: BinaryImage, analysis: ImageAnalysis, payload: Data),
        to packageURL: URL
    ) throws {
        let binary = WorkspacePackageBinary(
            id: fixture.binary.id,
            displayName: fixture.binary.name,
            originalPath: fixture.binary.path,
            attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                for: fixture.binary.id,
                originalPath: fixture.binary.path
            ),
            kind: fixture.binary.kind,
            architecture: fixture.binary.architecture,
            fileHash: MacScopeDocumentPackage.fileHash(for: fixture.payload),
            fileSize: Int64(fixture.payload.count),
            metadata: fixture.binary.metadata
        )
        let manifest = WorkspacePackageManifest(
            documentID: UUID(),
            workspaceUUID: UUID(),
            workspaceName: "ELF metadata fingerprint",
            createdAt: Date(timeIntervalSince1970: 1_800_000_030),
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_031),
            binaries: [binary],
            analysis: WorkspacePackageAnalysis(
                analysisInputFingerprint: fixture.analysis.analysisInputFingerprint
            ),
            session: nil
        )
        try MacScopeDocumentPackage.writePackage(
            manifest,
            attachmentsByBinaryID: [fixture.binary.id: fixture.payload],
            to: packageURL
        )
    }

    private static func archiveFingerprint(
        binary: BinaryImage,
        payload: Data
    ) throws -> AnalysisInputFingerprint {
        try AnalysisInputFingerprint(
            imageSlot: binary.slot,
            binaryID: binary.id,
            binaryName: binary.name,
            binaryPath: binary.path,
            selectedSliceIndex: binary.selectedSliceIndex,
            artifactIdentity: binary.artifactIdentity,
            elfArchiveMemberIdentity: binary.elfArchiveMemberIdentity,
            imageByteCount: UInt64(payload.count),
            imageBytesSHA256: MacScopeDocumentPackage.fileHash(for: payload),
            facets: [],
            overallSHA256: String(repeating: "b", count: 64)
        )
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct IntegrityStubLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}

private struct IntegrityStubDisassembler: Disassembler {
    func decode(_ bytes: Data, baseAddress: UInt64, maxInstructionCount: Int) -> [DecodedInstruction] {
        guard !bytes.isEmpty else { return [] }
        return [
            DecodedInstruction(
                address: baseAddress,
                bytes: Array(bytes.prefix(4)),
                mnemonic: "integrity_stub",
                operands: "",
                branchTarget: nil,
                comment: nil,
                flow: .return
            )
        ]
    }
}
