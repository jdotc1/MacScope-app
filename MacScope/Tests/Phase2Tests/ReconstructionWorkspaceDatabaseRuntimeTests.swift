import CryptoKit
import Foundation
import SQLite3
import XCTest

@testable import MacScope

final class ReconstructionWorkspaceDatabaseRuntimeTests: XCTestCase {
    func testDeterministicIdentityPathUsesPrivateDirectoriesAndOnlySidecarArtifacts()
        async throws
    {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let expected = try ReconstructionWorkspaceDatabaseRuntime
            .deterministicSidecarDirectoryURL(
                workspaceID: binding.workspaceID,
                documentID: binding.documentID,
                baseDirectoryURL: base
            )

        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )

        XCTAssertEqual(runtime.sidecarDirectoryURL, expected)
        XCTAssertEqual(runtime.reconciliationDisposition, .seededPackage)
        XCTAssertEqual(try permissions(of: expected), 0o700)
        XCTAssertEqual(
            try permissions(of: expected.deletingLastPathComponent()),
            0o700
        )
        XCTAssertEqual(try permissions(of: runtime.databaseURL), 0o600)
        XCTAssertEqual(try permissions(of: runtime.attachmentVaultURL), 0o700)
        let openedState = try await runtime.databaseOwner().load(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(openedState, .empty)
        let createdNames = try Set(FileManager.default.contentsOfDirectory(atPath: expected.path))
        XCTAssertTrue(createdNames.isSubset(of: [
            ReconstructionWorkspaceDatabaseRuntime.databaseFileName,
            ReconstructionWorkspaceDatabaseRuntime.databaseFileName + "-journal",
            ReconstructionWorkspaceDatabaseRuntime.databaseFileName + "-wal",
            ReconstructionWorkspaceDatabaseRuntime.databaseFileName + "-shm",
            ReconstructionWorkspaceDatabaseRuntime.attachmentVaultDirectoryName,
        ]))
        await runtime.close()
    }

    func testRefusesSecondLiveRuntimeForTheSameIdentity() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let first = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .identityAlreadyOpen
            )
        }

        let escapedOwner = try first.databaseOwner()
        await first.close()
        do {
            _ = try await escapedOwner.load(workspaceID: binding.workspaceID)
            XCTFail("Expected close to revoke an already-issued owner")
        } catch {
            XCTAssertEqual(error as? ReconstructionDatabaseOwnerError, .revoked)
        }
        let reopened = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        XCTAssertEqual(reopened.reconciliationDisposition, .equal)
        let reopenedState = try await reopened.databaseOwner().load(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(reopenedState, .empty)
        withExtendedLifetime(escapedOwner) {}
        await reopened.close()
    }

    func testRefusesSymlinkAtIdentityQualifiedWorkspaceDirectory() throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let workspaceDirectory = base.appendingPathComponent(
            binding.workspaceID.uuidString.lowercased(),
            isDirectory: true
        )
        let decoy = base.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: workspaceDirectory,
            withDestinationURL: decoy
        )

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base
            )
        ) { error in
            guard case ReconstructionWorkspaceDatabaseRuntimeError.unsafeFilesystemEntry = error
            else {
                return XCTFail("Expected unsafeFilesystemEntry, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: decoy.appendingPathComponent(
                    binding.documentID.uuidString.lowercased()
                ).path
            )
        )
    }

    func testRefusesExistingNonprivateIdentityDirectoryWithoutChangingItsMode()
        async throws
    {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let first = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        let originalDirectory = first.sidecarDirectoryURL
        await first.close()
        let relocatedBinding = ReconstructionWorkspaceStateBinding(
            workspaceID: binding.workspaceID,
            documentID: Self.relocatedDocumentID,
            canonicalPackagePath: binding.canonicalPackagePath
        )
        let relocatedDirectory = try ReconstructionWorkspaceDatabaseRuntime
            .deterministicSidecarDirectoryURL(
                workspaceID: relocatedBinding.workspaceID,
                documentID: relocatedBinding.documentID,
                baseDirectoryURL: base
            )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: originalDirectory.path
        )
        try FileManager.default.moveItem(at: originalDirectory, to: relocatedDirectory)

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: relocatedBinding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base
            )
        ) { error in
            guard case ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry = error else {
                return XCTFail("Expected nonprivate-directory refusal, got \(error)")
            }
        }
        XCTAssertEqual(try permissions(of: relocatedDirectory), 0o755)
    }

    func testRefusesSameWorkspaceAndDocumentAtDifferentCanonicalPackagePath() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        var first: ReconstructionWorkspaceDatabaseRuntime? = try .open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        await first?.close()
        first = nil

        let driftedBinding = ReconstructionWorkspaceStateBinding(
            workspaceID: binding.workspaceID,
            documentID: binding.documentID,
            canonicalPackagePath: base.appendingPathComponent("Other.mscope").path
        )
        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: driftedBinding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .canonicalPackagePathMismatch
            )
        }
    }

    func testRefusesSidecarRelocatedAcrossDocumentOrWorkspaceIdentity() async throws {
        let documentBase = try makeBaseDirectory()
        let originalDocumentBinding = makeBinding(base: documentBase)
        let originalDocumentRuntime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: originalDocumentBinding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: documentBase
        )
        await originalDocumentRuntime.close()
        try dropTable(
            named: "phase2_runtime_authority_records",
            databaseURL: originalDocumentRuntime.databaseURL
        )
        let relocatedDocumentBinding = ReconstructionWorkspaceStateBinding(
            workspaceID: originalDocumentBinding.workspaceID,
            documentID: Self.relocatedDocumentID,
            canonicalPackagePath: originalDocumentBinding.canonicalPackagePath
        )
        let relocatedDocumentURL = try ReconstructionWorkspaceDatabaseRuntime
            .deterministicSidecarDirectoryURL(
                workspaceID: relocatedDocumentBinding.workspaceID,
                documentID: relocatedDocumentBinding.documentID,
                baseDirectoryURL: documentBase
            )
        let documentTreeBeforeRefusal = try sidecarTreeSnapshot(
            at: originalDocumentRuntime.sidecarDirectoryURL
        )
        try FileManager.default.moveItem(
            at: originalDocumentRuntime.sidecarDirectoryURL,
            to: relocatedDocumentURL
        )
        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: relocatedDocumentBinding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: documentBase
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .documentIdentityMismatch
            )
        }
        XCTAssertEqual(
            try sidecarTreeSnapshot(at: relocatedDocumentURL),
            documentTreeBeforeRefusal
        )

        let workspaceBase = try makeBaseDirectory()
        let originalWorkspaceBinding = makeBinding(base: workspaceBase)
        let originalWorkspaceRuntime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: originalWorkspaceBinding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: workspaceBase
        )
        await originalWorkspaceRuntime.close()
        let relocatedWorkspaceBinding = ReconstructionWorkspaceStateBinding(
            workspaceID: Self.relocatedWorkspaceID,
            documentID: originalWorkspaceBinding.documentID,
            canonicalPackagePath: originalWorkspaceBinding.canonicalPackagePath
        )
        let originalWorkspaceURL = originalWorkspaceRuntime.sidecarDirectoryURL
            .deletingLastPathComponent()
        let relocatedWorkspaceURL = workspaceBase.appendingPathComponent(
            relocatedWorkspaceBinding.workspaceID.uuidString.lowercased(),
            isDirectory: true
        )
        let workspaceTreeBeforeRefusal = try sidecarTreeSnapshot(
            at: originalWorkspaceRuntime.sidecarDirectoryURL
        )
        try FileManager.default.moveItem(
            at: originalWorkspaceURL,
            to: relocatedWorkspaceURL
        )
        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: relocatedWorkspaceBinding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: workspaceBase
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .workspaceIdentityMismatch
            )
        }
        XCTAssertEqual(
            try sidecarTreeSnapshot(
                at: relocatedWorkspaceURL.appendingPathComponent(
                    originalWorkspaceBinding.documentID.uuidString.lowercased(),
                    isDirectory: true
                )
            ),
            workspaceTreeBeforeRefusal
        )
    }

    func testCurrentSchemaWithoutRowsCompletesAtomicBootstrap() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let sidecarURL = try createIdentityDirectories(binding: binding, base: base)
        let databaseURL = sidecarURL.appendingPathComponent(
            ReconstructionWorkspaceDatabaseRuntime.databaseFileName
        )
        var database: WorkspaceDatabase? = try WorkspaceDatabase(path: databaseURL.path)
        try database?.applySchema()
        database = nil

        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        XCTAssertEqual(runtime.reconciliationDisposition, .seededPackage)
        let openedState = try await runtime.databaseOwner().load(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(openedState, .empty)
        await runtime.close()
    }

    func testRejectsSwapOpenRestoreAgainstTheActualSQLiteHandle() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let first = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        let databaseURL = first.databaseURL
        await first.close()

        let decoyURL = base.appendingPathComponent("decoy.sqlite3")
        var decoy: WorkspaceDatabase? = try WorkspaceDatabase(path: decoyURL.path)
        try decoy?.applySchema()
        _ = try decoy?.bootstrapReconstructionWorkspaceSidecar(
            workspaceUUID: binding.workspaceID,
            workspaceName: "Decoy",
            documentID: binding.documentID,
            canonicalPackagePath: binding.canonicalPackagePath,
            now: Date(timeIntervalSince1970: 1_787_000_000)
        )
        decoy = nil
        let displacedRealURL = base.appendingPathComponent("displaced-real.sqlite3")
        let interposition = ReconstructionWorkspaceDatabaseRuntime
            .DatabaseOpenInterpositionForTesting { operation in
                try FileManager.default.moveItem(
                    at: databaseURL,
                    to: displacedRealURL
                )
                try FileManager.default.moveItem(at: decoyURL, to: databaseURL)
                let opened: WorkspaceDatabase
                do {
                    opened = try operation()
                } catch {
                    try FileManager.default.moveItem(at: databaseURL, to: decoyURL)
                    try FileManager.default.moveItem(
                        at: displacedRealURL,
                        to: databaseURL
                    )
                    throw error
                }
                try FileManager.default.moveItem(at: databaseURL, to: decoyURL)
                try FileManager.default.moveItem(at: displacedRealURL, to: databaseURL)
                return opened
            }

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base,
                databaseOpenInterpositionForTesting: interposition
            )
        ) { error in
            guard case ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry = error else {
                return XCTFail("Expected swapped SQLite handle refusal, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoyURL.path))
    }

    func testVaultPublicationUsesPinnedDirectoryAcrossSwapAndRestore() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let fixture = try foundation()
        let source = try makeSource(for: fixture.occurrence.contentIdentity, below: base)
        let sidecarURL = try ReconstructionWorkspaceDatabaseRuntime
            .deterministicSidecarDirectoryURL(
                workspaceID: binding.workspaceID,
                documentID: binding.documentID,
                baseDirectoryURL: base
            )
        let vaultURL = sidecarURL.appendingPathComponent(
            ReconstructionWorkspaceDatabaseRuntime.attachmentVaultDirectoryName,
            isDirectory: true
        )
        let displacedVaultURL = base.appendingPathComponent(
            "displaced-vault",
            isDirectory: true
        )
        let retainedDecoyURL = base.appendingPathComponent(
            "retained-decoy-vault",
            isDirectory: true
        )
        let sentinelName = "sentinel"
        var didInterpose = false
        let interposition = ReconstructionWorkspaceDatabaseRuntime
            .VaultPublicationInterpositionForTesting { operation in
                XCTAssertFalse(didInterpose)
                didInterpose = true
                try FileManager.default.moveItem(at: vaultURL, to: displacedVaultURL)
                try FileManager.default.createDirectory(
                    at: vaultURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try Data("untouched".utf8).write(
                    to: vaultURL.appendingPathComponent(sentinelName)
                )

                do {
                    let result = try operation()
                    try FileManager.default.moveItem(at: vaultURL, to: retainedDecoyURL)
                    try FileManager.default.moveItem(at: displacedVaultURL, to: vaultURL)
                    return result
                } catch {
                    let operationError = error
                    if FileManager.default.fileExists(atPath: vaultURL.path) {
                        try? FileManager.default.moveItem(at: vaultURL, to: retainedDecoyURL)
                    }
                    if FileManager.default.fileExists(atPath: displacedVaultURL.path) {
                        try? FileManager.default.moveItem(at: displacedVaultURL, to: vaultURL)
                    }
                    throw operationError
                }
            }

        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: fixture.state,
            packageAttachmentSources: [source],
            baseDirectoryURL: base,
            vaultPublicationInterpositionForTesting: interposition
        )
        XCTAssertTrue(didInterpose)
        let durable = try await runtime.databaseOwner().availableDurableAttachmentSources(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(durable.map(\.contentIdentity), [fixture.occurrence.contentIdentity])
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(durable.first).verifiedURL),
            Data("test".utf8)
        )
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(atPath: retainedDecoyURL.path)),
            [sentinelName]
        )
        XCTAssertEqual(
            try Data(contentsOf: retainedDecoyURL.appendingPathComponent(sentinelName)),
            Data("untouched".utf8)
        )
        await runtime.close()
    }

    func testRefusesIncompleteBootstrapWithoutRepairOrMutation() throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let sidecarURL = try createIdentityDirectories(binding: binding, base: base)
        let databaseURL = sidecarURL.appendingPathComponent(
            ReconstructionWorkspaceDatabaseRuntime.databaseFileName
        )
        var database: WorkspaceDatabase? = try WorkspaceDatabase(path: databaseURL.path)
        try database?.applySchema()
        _ = try database?.saveSnapshot(
            workspaceUUID: binding.workspaceID,
            workspaceName: "Interrupted Bootstrap",
            snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        )
        database = nil
        let beforeRefusal = try sidecarTreeSnapshot(at: sidecarURL)

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .documentIdentityMismatch
            )
        }
        XCTAssertEqual(try sidecarTreeSnapshot(at: sidecarURL), beforeRefusal)
    }

    func testOrdinaryCloseRetainsDatabaseAndPreexistingWALAndSHMArtifacts() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        var runtime: ReconstructionWorkspaceDatabaseRuntime? = try .open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        let databaseURL = try XCTUnwrap(runtime).databaseURL
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: databaseURL.path + "-shm")
        try Data("retained-wal".utf8).write(to: walURL)
        try Data("retained-shm".utf8).write(to: shmURL)
        await runtime?.close()
        runtime = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmURL.path))
    }

    func testRefusesHardLinkedDatabaseJournalWALAndSHMEntries() async throws {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let base = try makeBaseDirectory()
            let binding = makeBinding(base: base)
            var first: ReconstructionWorkspaceDatabaseRuntime? = try .open(
                binding: binding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base
            )
            let databaseURL = try XCTUnwrap(first).databaseURL
            await first?.close()
            first = nil

            let candidate = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                try FileManager.default.removeItem(at: candidate)
            }
            let external = base.appendingPathComponent("external\(suffix).bin")
            try Data("not-a-database".utf8).write(to: external)
            try FileManager.default.linkItem(at: external, to: candidate)

            XCTAssertThrowsError(
                try ReconstructionWorkspaceDatabaseRuntime.open(
                    binding: binding,
                    packageState: .empty,
                    packageAttachmentSources: [],
                    baseDirectoryURL: base
                )
            ) { error in
                guard case ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry = error else {
                    return XCTFail("Expected unsafeFilesystemEntry for \(suffix), got \(error)")
                }
            }
        }
    }

    func testRefusesSymlinkedRollbackJournal() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let first = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        let databaseURL = first.databaseURL
        await first.close()

        let journalURL = URL(fileURLWithPath: databaseURL.path + "-journal")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        }
        let decoy = base.appendingPathComponent("journal-decoy.bin")
        try Data("decoy".utf8).write(to: decoy)
        try FileManager.default.createSymbolicLink(
            at: journalURL,
            withDestinationURL: decoy
        )

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: .empty,
                packageAttachmentSources: [],
                baseDirectoryURL: base
            )
        ) { error in
            guard case ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry = error else {
                return XCTFail("Expected unsafe rollback journal refusal, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: decoy), Data("decoy".utf8))
    }

    func testOwnerRefusesWorkspaceAncestorReplacementBeforeDatabaseAccess() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        let owner = try runtime.databaseOwner()
        let workspaceURL = runtime.sidecarDirectoryURL.deletingLastPathComponent()
        let displacedWorkspaceURL = base.appendingPathComponent(
            "displaced-workspace",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: workspaceURL, to: displacedWorkspaceURL)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let replacementDocumentURL = workspaceURL.appendingPathComponent(
            binding.documentID.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementDocumentURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = replacementDocumentURL.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)

        do {
            _ = try await owner.load(workspaceID: binding.workspaceID)
            XCTFail("Expected the descriptor/path authority validator to reject replacement")
        } catch {
            guard case ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry = error else {
                return XCTFail("Expected unsafeFilesystemEntry, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(
                atPath: replacementDocumentURL.path
            )),
            ["sentinel"]
        )
        await runtime.close()
    }

    func testOwnerRefusesStorageRootReplacementBeforeDatabaseAccess() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        let owner = try runtime.databaseOwner()
        let displacedBase = base.deletingLastPathComponent().appendingPathComponent(
            "displaced-sidecar-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: displacedBase) }
        try FileManager.default.moveItem(at: base, to: displacedBase)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let replacementDocumentURL = try createIdentityDirectories(
            binding: binding,
            base: base
        )
        let sentinel = replacementDocumentURL.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)

        do {
            _ = try await owner.load(workspaceID: binding.workspaceID)
            XCTFail("Expected the storage-root identity validator to reject replacement")
        } catch {
            guard case ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry = error else {
                return XCTFail("Expected unsafeFilesystemEntry, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertEqual(
            try Set(FileManager.default.contentsOfDirectory(
                atPath: replacementDocumentURL.path
            )),
            ["sentinel"]
        )
        await runtime.close()
    }

    func testOwnerRefusesPersistentDatabasePathReplacementBeforeAccess() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: .empty,
            packageAttachmentSources: [],
            baseDirectoryURL: base
        )
        let owner = try runtime.databaseOwner()
        let displacedDatabase = base.appendingPathComponent("displaced-database.sqlite3")
        try FileManager.default.moveItem(at: runtime.databaseURL, to: displacedDatabase)
        let replacementBytes = Data("replacement-database".utf8)
        try replacementBytes.write(to: runtime.databaseURL)

        do {
            _ = try await owner.load(workspaceID: binding.workspaceID)
            XCTFail("Expected the persistent database identity check to reject replacement")
        } catch {
            guard case ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry = error else {
                return XCTFail("Expected unsafeFilesystemEntry, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: runtime.databaseURL), replacementBytes)
        await runtime.close()
    }

    func testOwnerRefusesPersistentVaultPathReplacementBeforeAccess() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let fixture = try foundation()
        let source = try makeSource(for: fixture.occurrence.contentIdentity, below: base)
        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: fixture.state,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        let owner = try runtime.databaseOwner()
        let displacedVault = base.appendingPathComponent(
            "displaced-attachment-vault",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: runtime.attachmentVaultURL, to: displacedVault)
        try FileManager.default.createDirectory(
            at: runtime.attachmentVaultURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = runtime.attachmentVaultURL.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)

        do {
            _ = try await owner.availableDurableAttachmentSources(
                workspaceID: binding.workspaceID
            )
            XCTFail("Expected the persistent vault identity check to reject replacement")
        } catch {
            guard case ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry = error else {
                return XCTFail("Expected unsafeFilesystemEntry, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        await runtime.close()
    }

    func testSeedsExactVerifiedSourcesAndOrdinaryClosePreservesReopenAuthority()
        async throws
    {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let fixture = try foundation()
        let source = try makeSource(for: fixture.occurrence.contentIdentity, below: base)

        var runtime: ReconstructionWorkspaceDatabaseRuntime? = try .open(
            binding: binding,
            packageState: fixture.state,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        XCTAssertEqual(runtime?.reconciliationDisposition, .seededPackage)
        let seededState = try await XCTUnwrap(runtime).databaseOwner().load(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(seededState, fixture.state)
        let durable = try await XCTUnwrap(runtime).databaseOwner()
            .availableDurableAttachmentSources(workspaceID: binding.workspaceID)
        XCTAssertEqual(durable.map(\.contentIdentity), [fixture.occurrence.contentIdentity])
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(durable.first).verifiedURL),
            Data("test".utf8)
        )
        let escapedDurableSource = try XCTUnwrap(durable.first)

        let databaseURL = try XCTUnwrap(runtime).databaseURL
        let vaultURL = try XCTUnwrap(runtime).attachmentVaultURL
        await runtime?.close()
        runtime = nil
        XCTAssertThrowsError(try escapedDurableSource.openVerifiedDescriptor()) { error in
            XCTAssertEqual(
                error as? ReconstructionSidecarAttachmentAuthorityError,
                .revoked
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.path))

        let reopened = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: fixture.state,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        XCTAssertEqual(reopened.reconciliationDisposition, .equal)
        let reopenedState = try await reopened.databaseOwner().load(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(reopenedState, fixture.state)
        await reopened.close()
    }

    func testUsesDurableCheckpointDescendantWhenPackageIsAnAncestor() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let foundation = try foundation()
        let durableDescendant = try checkpointDescendant(
            of: foundation,
            checkpointID: Self.checkpointOneID
        )
        let source = try makeSource(for: foundation.occurrence.contentIdentity, below: base)

        var first: ReconstructionWorkspaceDatabaseRuntime? = try .open(
            binding: binding,
            packageState: durableDescendant,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        await first?.close()
        first = nil

        let reopened = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: foundation.state,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        XCTAssertEqual(reopened.reconciliationDisposition, .usedDurableDescendant)
        XCTAssertEqual(reopened.reconciledOpeningState, durableDescendant)
        let reopenedState = try await reopened.databaseOwner().load(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(reopenedState, durableDescendant)
        await reopened.close()
    }

    func testFastForwardsDurableStateWhenPackageIsTheCheckpointDescendant() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let foundation = try foundation()
        let packageDescendant = try checkpointDescendant(
            of: foundation,
            checkpointID: Self.checkpointOneID
        )
        let source = try makeSource(for: foundation.occurrence.contentIdentity, below: base)

        var first: ReconstructionWorkspaceDatabaseRuntime? = try .open(
            binding: binding,
            packageState: foundation.state,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        await first?.close()
        first = nil

        let reopened = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: packageDescendant,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        XCTAssertEqual(
            reopened.reconciliationDisposition,
            .fastForwardedDurableFromPackage
        )
        let reopenedState = try await reopened.databaseOwner().load(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(reopenedState, packageDescendant)
        await reopened.close()
    }

    func testSeedsSourcesForEveryRetainedCorpusManifest() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let foundation = try foundation()
        let secondBytes = Data("second-source".utf8)
        let history = try corpusDescendant(of: foundation, additionalBytes: secondBytes)
        let identities = try ReconstructionPackageCodec.contentRecords(in: history)
            .map(\.contentIdentity)
        let originalIdentity = foundation.occurrence.contentIdentity
        let secondIdentity = try XCTUnwrap(identities.first { $0 != originalIdentity })
        let originalSource = try makeSource(
            for: originalIdentity,
            bytes: Data("test".utf8),
            below: base
        )
        let secondSource = try makeSource(
            for: secondIdentity,
            bytes: secondBytes,
            below: base
        )

        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: history,
            packageAttachmentSources: [secondSource, originalSource],
            baseDirectoryURL: base
        )
        let durable = try await runtime.databaseOwner().availableDurableAttachmentSources(
            workspaceID: binding.workspaceID
        )

        XCTAssertEqual(Set(durable.map(\.contentIdentity)), Set(identities))
        XCTAssertEqual(durable.count, 2)
        XCTAssertEqual(runtime.reconciledOpeningState.corpusManifests.count, 2)
        await runtime.close()
    }

    func testRefusesSiblingCheckpointDivergenceAndLeavesDurableStateUnchanged() async throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let foundation = try foundation()
        let durableSibling = try checkpointDescendant(
            of: foundation,
            checkpointID: Self.checkpointOneID
        )
        let packageSibling = try checkpointDescendant(
            of: foundation,
            checkpointID: Self.checkpointTwoID
        )
        let source = try makeSource(for: foundation.occurrence.contentIdentity, below: base)

        var first: ReconstructionWorkspaceDatabaseRuntime? = try .open(
            binding: binding,
            packageState: durableSibling,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        await first?.close()
        first = nil

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: packageSibling,
                packageAttachmentSources: [source],
                baseDirectoryURL: base
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .reconciliationConflict(.checkpointAncestryDiverged(foundation.job.jobID))
            )
        }

        let reopened = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: durableSibling,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        let reopenedState = try await reopened.databaseOwner().load(
            workspaceID: binding.workspaceID
        )
        XCTAssertEqual(reopenedState, durableSibling)
        await reopened.close()
    }

    func testRejectsSourceBytesThatDoNotMatchTheDeclaredIdentity() throws {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let fixture = try foundation()
        let sourceURL = base.appendingPathComponent("drifted-source.bin")
        try Data("evil".utf8).write(to: sourceURL)
        let drifted = ReconstructionAttachmentSource(
            contentIdentity: fixture.occurrence.contentIdentity,
            verifiedURL: sourceURL
        )

        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: fixture.state,
                packageAttachmentSources: [drifted],
                baseDirectoryURL: base
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .sourceCatalogMismatch
            )
        }
    }

    func testDiscardIsRefusedBeforeExactRetirementAndThenRemovesOnlyIdentityLeaf()
        async throws
    {
        let base = try makeBaseDirectory()
        let binding = makeBinding(base: base)
        let fixture = try foundation()
        let source = try makeSource(for: fixture.occurrence.contentIdentity, below: base)
        let sibling = base.appendingPathComponent("preserve-sibling.txt")
        try Data("preserve".utf8).write(to: sibling)
        let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: fixture.state,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )

        do {
            try await runtime.discardRetiredSidecar()
            XCTFail("Expected retirementRequired before retirement")
        } catch {
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .retirementRequired
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.sidecarDirectoryURL.path))

        let wrongBinding = ReconstructionWorkspaceStateBinding(
            workspaceID: binding.workspaceID,
            documentID: UUID(),
            canonicalPackagePath: binding.canonicalPackagePath
        )
        do {
            try await runtime.retire(binding: wrongBinding)
            XCTFail("Expected retirementIdentityMismatch")
        } catch {
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .retirementIdentityMismatch
            )
        }

        let escapedOwner = try runtime.databaseOwner()
        try await runtime.retire(binding: binding)
        do {
            _ = try await escapedOwner.load(workspaceID: binding.workspaceID)
            XCTFail("Expected owner revocation before physical discard")
        } catch {
            XCTAssertEqual(error as? ReconstructionDatabaseOwnerError, .revoked)
        }
        XCTAssertThrowsError(
            try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: fixture.state,
                packageAttachmentSources: [source],
                baseDirectoryURL: base
            )
        ) { error in
            XCTAssertEqual(
                error as? ReconstructionWorkspaceDatabaseRuntimeError,
                .identityAlreadyOpen
            )
        }
        try await runtime.discardRetiredSidecar()
        withExtendedLifetime(escapedOwner) {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.sidecarDirectoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: runtime.sidecarDirectoryURL.deletingLastPathComponent().path
            )
        )
        let reopened = try ReconstructionWorkspaceDatabaseRuntime.open(
            binding: binding,
            packageState: fixture.state,
            packageAttachmentSources: [source],
            baseDirectoryURL: base
        )
        XCTAssertEqual(reopened.reconciliationDisposition, .seededPackage)
        await reopened.close()
    }

    // Mutation RED recipes:
    // 1. Change `durableWasAbsent ? .absent : .present` to always `.absent`; the descendant and
    //    divergence tests must fail because persisted authority is ignored.
    // 2. Remove only `digest == source.contentIdentity.digest` from
    //    `ReconstructionAttachmentDescriptorReader.consume`; the same-length drifted-source test
    //    must fail because the invalid source then opens successfully.
    // 3. Remove the `try requireRevokedRetirement()` call before lease discard; the bounded-
    //    discard test must fail at its first assertion while ordinary close/reopen remains green.
    // 4. Remove the identity registry claim; the same-identity double-open test must fail because
    //    two live mutation owners are returned.
    // 5. Replace the `Task { await owner.revoke() }` revocation barrier with an empty task; both
    //    escaped-owner assertions must fail with a still-live owner.
    // 6. Remove the journal check or the link-count clause from post-open entry validation; the
    //    journal/WAL/SHM hard-link subcases must fail by accepting a multiply-linked artifact.
    // 7. Remove either persisted workspace/document identity comparison; the corresponding
    //    relocated-sidecar subcase must fail by opening a database under a false path identity.
    // 8. Release the identity claim when retirement revocation finishes; the pre-discard reopen
    //    assertion must fail because a successor runtime is admitted before deletion.
    // 9. Remove the owner database-authority validator or any ancestor identity comparison; the
    //    root/workspace replacement tests must fail by reaching the displaced database.
    // 10. Call `applySchema()` before binding preflight; the relocated document fixture's missing
    //     repairable Phase 2 table must be recreated and make its byte snapshot comparison fail.
    // 11. Treat a workspace row without a document row as empty/recoverable; the incomplete-
    //     bootstrap test must fail because the runtime then silently repairs ambiguous identity.
    // 12. Replace stable-entry inode equality with type-only checks; the database and vault path-
    //     replacement tests must fail because a different ordinary object is then accepted.
    // 13. Restore unconditional chmod of existing directories; the relocated 0755 test must fail
    //     because refusal then mutates the directory back to 0700.
    // 14. Remove either main-file `SQLITE_FCNTL_HAS_MOVED` check; the swap-open-restore test must
    //     fail because a decoy handle with an exact copied binding is accepted.
    // 15. Configure the vault from its URL instead of the pinned directory descriptor; the vault
    //     swap/restore test must fail by publishing into the decoy rather than the retained inode.
    // 16. Omit attachment-authority revocation after the owner actor drains; the escaped durable
    //     source assertion must fail because it can still open a sidecar descriptor after close.
    // 17. Restore absolute root-path prefix slicing in `sidecarTreeSnapshot`; the relocated-document
    //     case must fail on a /private/var alias host with the ...0007 leaf compared to ...0002.

    private static let workspaceID = UUID(
        uuidString: "3A000000-0000-0000-0000-000000000001"
    )!
    private static let documentID = UUID(
        uuidString: "3A000000-0000-0000-0000-000000000002"
    )!
    private static let workspaceBinaryID = UUID(
        uuidString: "3A000000-0000-0000-0000-000000000003"
    )!
    private static let checkpointOneID = UUID(
        uuidString: "3A000000-0000-0000-0000-000000000004"
    )!
    private static let checkpointTwoID = UUID(
        uuidString: "3A000000-0000-0000-0000-000000000005"
    )!
    private static let secondOccurrenceID = UUID(
        uuidString: "3A000000-0000-0000-0000-000000000006"
    )!
    private static let relocatedDocumentID = UUID(
        uuidString: "3A000000-0000-0000-0000-000000000007"
    )!
    private static let relocatedWorkspaceID = UUID(
        uuidString: "3A000000-0000-0000-0000-000000000008"
    )!

    private func makeBaseDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MacScope-ReconstructionSidecarTests-\(UUID().uuidString)",
                isDirectory: true
            )
            .resolvingSymlinksInPath()
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: base)
        }
        return base
    }

    private func makeBinding(base: URL) -> ReconstructionWorkspaceStateBinding {
        ReconstructionWorkspaceStateBinding(
            workspaceID: Self.workspaceID,
            documentID: Self.documentID,
            canonicalPackagePath: base.appendingPathComponent("Fixture.mscope").path
        )
    }

    private func createIdentityDirectories(
        binding: ReconstructionWorkspaceStateBinding,
        base: URL
    ) throws -> URL {
        let sidecarURL = try ReconstructionWorkspaceDatabaseRuntime
            .deterministicSidecarDirectoryURL(
                workspaceID: binding.workspaceID,
                documentID: binding.documentID,
                baseDirectoryURL: base
            )
        try FileManager.default.createDirectory(
            at: sidecarURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return sidecarURL
    }

    private struct SidecarTreeSnapshot: Equatable {
        let directories: [String]
        let files: [String: Data]
    }

    private func sidecarTreeSnapshot(at root: URL) throws -> SidecarTreeSnapshot {
        var directories: [String] = []
        var files: [String: Data] = [:]
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]

        func visit(_ directory: URL, below relativeDirectoryPath: String?) throws {
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: []
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            for url in children {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw CocoaError(.fileReadUnknown)
                }
                let relativePath = relativeDirectoryPath.map {
                    $0 + "/" + url.lastPathComponent
                } ?? url.lastPathComponent
                if values.isDirectory == true {
                    directories.append(relativePath)
                    try visit(url, below: relativePath)
                } else if values.isRegularFile == true {
                    files[relativePath] = try Data(contentsOf: url)
                } else {
                    throw CocoaError(.fileReadUnknown)
                }
            }
        }
        try visit(root, below: nil)
        return SidecarTreeSnapshot(
            directories: directories.sorted(),
            files: files
        )
    }

    private func foundation() throws -> ReconstructionDatabaseTestFixtures.StateFixture {
        try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: Self.workspaceBinaryID
        )
    }

    private func makeSource(
        for identity: ReconstructionContentIdentity,
        bytes: Data = Data("test".utf8),
        below base: URL
    ) throws -> ReconstructionAttachmentSource {
        let sourceURL = base.appendingPathComponent(
            "source-\(UUID().uuidString).bin",
            isDirectory: false
        )
        try bytes.write(to: sourceURL)
        return ReconstructionAttachmentSource(
            contentIdentity: identity,
            verifiedURL: sourceURL
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func dropTable(named name: String, databaseURL: URL) throws {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var connection: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
        let connection else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(connection) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(
            connection,
            "DROP TABLE \(name);",
            nil,
            nil,
            &errorMessage
        )
        if let errorMessage { sqlite3_free(errorMessage) }
        guard status == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func checkpointDescendant(
        of fixture: ReconstructionDatabaseTestFixtures.StateFixture,
        checkpointID: UUID
    ) throws -> ReconstructionWorkspaceState {
        let completedTask = ReconstructionTaskRecord(
            identity: fixture.task.identity,
            state: .completed,
            diagnostic: nil
        )
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: checkpointID,
            jobID: fixture.job.jobID,
            revision: fixture.checkpoint.revision + 1,
            parentCheckpointID: fixture.checkpoint.checkpointID,
            parentCheckpointSHA256: fixture.checkpoint.canonicalSHA256,
            corpusManifestSHA256: fixture.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: fixture.checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: [fixture.task.identity.taskID],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: fixture.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .completed,
            terminalReason: nil
        )
        let job = try ReconstructionJobRecord(
            jobID: fixture.job.jobID,
            reconstructionProjectID: fixture.job.reconstructionProjectID,
            objective: fixture.job.objective,
            objectiveSHA256: fixture.job.objectiveSHA256,
            creationCorpusManifestSHA256: fixture.job.creationCorpusManifestSHA256,
            state: .completed,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: nil,
            budget: fixture.job.budget,
            creationOrdinal: try XCTUnwrap(fixture.job.creationOrdinal)
        )
        return try ReconstructionWorkspaceState(
            projects: fixture.state.projects,
            corpusManifests: fixture.state.corpusManifests,
            evidence: fixture.state.evidence,
            evidenceRelations: fixture.state.evidenceRelations,
            evidenceGaps: fixture.state.evidenceGaps,
            jobs: [job],
            tasks: [completedTask],
            checkpoints: [fixture.checkpoint, checkpoint],
            toolReceipts: fixture.state.toolReceipts,
            modelReceipts: fixture.state.modelReceipts
        )
    }

    private func corpusDescendant(
        of fixture: ReconstructionDatabaseTestFixtures.StateFixture,
        additionalBytes: Data
    ) throws -> ReconstructionWorkspaceState {
        let digest = SHA256.hash(data: additionalBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let identity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digest,
            byteCount: UInt64(additionalBytes.count)
        )
        let occurrence = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: ReconstructionArtifactOccurrenceID(
                rawValue: Self.secondOccurrenceID
            ),
            contentIdentity: identity,
            kind: .source,
            roles: [.referenceSource],
            executableMode: false,
            originalName: "second.swift",
            diagnostic: nil
        )
        let artifacts = fixture.manifest.artifacts + [occurrence]
        let draft = try ReconstructionCorpusManifest(
            reconstructionProjectID: fixture.project.projectID,
            artifacts: artifacts,
            relations: fixture.manifest.relations,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        let manifest = try ReconstructionCorpusManifest(
            reconstructionProjectID: fixture.project.projectID,
            artifacts: artifacts,
            relations: fixture.manifest.relations,
            canonicalSHA256: ReconstructionCorpusCanonicalizer.canonicalSHA256(of: draft)
        )
        let project = try ReconstructionProjectRecord(
            projectID: fixture.project.projectID,
            name: fixture.project.name,
            currentCorpusManifestSHA256: manifest.canonicalSHA256
        )
        return try ReconstructionWorkspaceState(
            projects: [project],
            corpusManifests: [fixture.manifest, manifest],
            evidence: fixture.state.evidence,
            evidenceRelations: fixture.state.evidenceRelations,
            evidenceGaps: fixture.state.evidenceGaps,
            jobs: fixture.state.jobs,
            tasks: fixture.state.tasks,
            checkpoints: fixture.state.checkpoints,
            toolReceipts: fixture.state.toolReceipts,
            modelReceipts: fixture.state.modelReceipts
        )
    }
}
