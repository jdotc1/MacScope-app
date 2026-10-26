import Foundation
import CryptoKit
import XCTest
@testable import MacScope

final class DebuggerLaunchProfileDatabasePersistenceTests: XCTestCase {
    func testFreshSchemaCreatesAndValidatesExactLaunchCatalogTable() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            try database.columnNames(in: "launch_profile_catalogs"),
            [
                "workspace_id", "workspace_uuid", "catalog_uuid", "revision",
                "profile_count", "selected_profile_uuid", "catalog_version",
                "catalog_byte_count", "catalog_sha256", "catalog_blob",
            ]
        )
        XCTAssertNoThrow(try database.applySchema())

        try database.executeRawForTesting("PRAGMA foreign_keys = OFF;")
        try database.executeRawForTesting("DROP TABLE launch_profile_catalogs;")
        try database.executeRawForTesting(
            """
            CREATE TABLE launch_profile_catalogs (
              workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
              workspace_uuid TEXT NOT NULL,
              catalog_uuid TEXT NOT NULL,
              revision INTEGER NOT NULL,
              profile_count INTEGER NOT NULL,
              selected_profile_uuid TEXT,
              catalog_version INTEGER NOT NULL,
              catalog_byte_count INTEGER NOT NULL,
              catalog_sha256 TEXT NOT NULL,
              catalog_blob TEXT NOT NULL
            );
            """
        )
        XCTAssertThrowsError(try database.applySchema()) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileSchemaInvalid)
        }
    }

    func testDirectV30MigrationPreservesLogicalRowsExactlyAndIsDeterministicIdempotent() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspaceUUID = UUID(uuidString: "A0000000-0000-0000-0000-000000000031")!
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.logicalBreakpointCatalog = try logicalCatalog(
            binaryID: try XCTUnwrap(snapshot.binaries.first?.id)
        )
        let workspace = try database.saveSnapshot(
            workspaceUUID: workspaceUUID,
            workspaceName: "v30",
            snapshot: snapshot
        )
        let workspaceID = try XCTUnwrap(workspace.id)

        // Contradictory legacy instruction bits are deliberately non-authoritative at v30.
        try database.executeRawForTesting("UPDATE instructions SET has_breakpoint = 1;")
        // SQLite affinity coercion is part of the raw durability proof: preserve an exact BLOB
        // even in a TEXT-declared logical receipt cell during the unrelated v31 migration.
        try database.executeRawForTesting(
            "UPDATE logical_breakpoints SET specification_sha256 = X'00FF' WHERE workspace_id = \(workspaceID);"
        )
        let before = try logicalAuthorityFingerprint(database, workspaceID: workspaceID)

        try database.executeRawForTesting("DROP TABLE launch_profile_catalogs;")
        try database.setUserVersionForTesting(30)
        try database.applySchema()

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(try logicalAuthorityFingerprint(database, workspaceID: workspaceID), before)
        let migratedID = try XCTUnwrap(database.scalarTextForTesting(
            "SELECT catalog_uuid FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
        ))
        let migratedBlob = try XCTUnwrap(database.scalarTextForTesting(
            "SELECT hex(catalog_blob) FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
        ))

        try database.setUserVersionForTesting(30)
        try database.applySchema()
        XCTAssertEqual(
            try database.scalarTextForTesting(
                "SELECT catalog_uuid FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
            ),
            migratedID
        )
        XCTAssertEqual(
            try database.scalarTextForTesting(
                "SELECT hex(catalog_blob) FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
            ),
            migratedBlob
        )

        let second = try WorkspaceDatabase.inMemory()
        try second.applySchema()
        _ = try second.saveSnapshot(
            workspaceUUID: workspaceUUID,
            workspaceName: "v30 twin",
            snapshot: snapshot
        )
        try second.executeRawForTesting("DROP TABLE launch_profile_catalogs;")
        try second.setUserVersionForTesting(30)
        try second.applySchema()
        XCTAssertEqual(
            try second.scalarTextForTesting("SELECT catalog_uuid FROM launch_profile_catalogs;"),
            migratedID
        )
    }

    func testCanonicalBlobReceiptRoundTripsExactTombstone() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let catalog = try DebuggerLaunchProfileCatalog(
            catalogID: UUID(uuidString: "B0000000-0000-0000-0000-000000000031")!,
            revision: 2,
            profiles: [],
            selectedProfileID: nil
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [], analysisBySlot: [:], launchProfileCatalog: catalog
        )
        let workspace = try database.saveSnapshot(
            workspaceName: "launch tombstone", snapshot: snapshot
        )
        let workspaceID = try XCTUnwrap(workspace.id)

        XCTAssertEqual(
            try database.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM launch_profile_catalogs
                WHERE workspace_id = \(workspaceID)
                  AND typeof(workspace_id) = 'integer'
                  AND typeof(workspace_uuid) = 'text'
                  AND typeof(catalog_uuid) = 'text'
                  AND typeof(revision) = 'integer'
                  AND typeof(profile_count) = 'integer'
                  AND typeof(selected_profile_uuid) = 'null'
                  AND typeof(catalog_version) = 'integer'
                  AND typeof(catalog_byte_count) = 'integer'
                  AND typeof(catalog_sha256) = 'text'
                  AND typeof(catalog_blob) = 'blob'
                  AND catalog_byte_count = length(catalog_blob);
                """
            ),
            1
        )
        XCTAssertEqual(
            try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID)).launchProfileCatalog,
            catalog
        )
    }

    func testSelectedImportedProfilePersistsExactCanonicalBlobAndReceipt() throws {
        let profileID = DebuggerLaunchProfileID(
            rawValue: UUID(uuidString: "B1000000-0000-0000-0000-000000000031")!
        )
        let profile = try DebuggerLaunchProfile(
            id: profileID,
            revision: 3,
            name: "Imported target",
            target: .importedExecutable(
                try DebuggerImportedExecutableSeal(
                    canonicalPath: "/tmp/MacScopeTarget",
                    deviceID: 7,
                    fileID: 11,
                    byteCount: 4_096,
                    sha256: String(repeating: "a", count: 64),
                    architecture: .arm64,
                    machOUUID: UUID(uuidString: "B2000000-0000-0000-0000-000000000031")!
                )
            ),
            arguments: ["--mode", "fast"],
            environment: [
                try DebuggerLaunchProfileEnvironmentEntry(key: "TRACE", value: "1"),
                try DebuggerLaunchProfileEnvironmentEntry(key: "LANG", value: "en_US.UTF-8"),
            ],
            workingDirectory: "/tmp",
            standardIOPolicy: .inheritNoCapture
        )
        let catalog = try DebuggerLaunchProfileCatalog(
            catalogID: UUID(uuidString: "B3000000-0000-0000-0000-000000000031")!,
            revision: 3,
            profiles: [profile],
            selectedProfileID: profileID
        )
        let canonical = try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(catalog)
        let expectedHex = canonical.map { String(format: "%02X", $0) }.joined()
        let expectedDigest = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceName: "selected imported profile",
            snapshot: WorkspaceSnapshot(
                binaries: [], analysisBySlot: [:], launchProfileCatalog: catalog
            )
        )
        let workspaceID = try XCTUnwrap(workspace.id)

        XCTAssertEqual(
            try database.scalarIntForTesting(
                "SELECT profile_count FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
            ),
            1
        )
        XCTAssertEqual(
            try database.scalarTextForTesting(
                "SELECT selected_profile_uuid FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
            ),
            profileID.rawValue.uuidString
        )
        XCTAssertEqual(
            try database.scalarIntForTesting(
                "SELECT catalog_byte_count FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
            ),
            canonical.count
        )
        XCTAssertEqual(
            try database.scalarTextForTesting(
                "SELECT catalog_sha256 FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
            ),
            expectedDigest
        )
        XCTAssertEqual(
            try database.scalarTextForTesting(
                "SELECT hex(catalog_blob) FROM launch_profile_catalogs WHERE workspace_id = \(workspaceID);"
            ),
            expectedHex
        )
        XCTAssertEqual(
            try database.scalarIntForTesting(
                """
                SELECT COUNT(*) FROM launch_profile_catalogs
                WHERE workspace_id = \(workspaceID)
                  AND typeof(catalog_blob) = 'blob'
                  AND length(catalog_blob) = catalog_byte_count;
                """
            ),
            1
        )
        XCTAssertEqual(
            try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID)).launchProfileCatalog,
            catalog
        )
    }

    func testCorruptCatalogLoadsUnavailableBlocksAllSaveBoundariesAndRepairIsIsolated() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let catalog = try DebuggerLaunchProfileCatalog(
            catalogID: UUID(uuidString: "C0000000-0000-0000-0000-000000000031")!,
            revision: 2,
            profiles: [],
            selectedProfileID: nil
        )
        let logical = DebuggerLogicalBreakpointCatalog.freshPristine(
            catalogID: UUID(uuidString: "D0000000-0000-0000-0000-000000000031")!
        )
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.logicalBreakpointCatalog = logical
        snapshot.launchProfileCatalog = catalog
        let workspace = try database.createWorkspaceState(
            workspaceUUID: UUID(uuidString: "E0000000-0000-0000-0000-000000000031")!,
            workspaceName: "before",
            snapshot: snapshot,
            selectedSidebarItemID: "function:preserved",
            selectedAddress: 0x1_0000_0000,
            selectedTool: .symbols,
            editorMode: .pseudocode,
            isInspectorPresented: false,
            sidebarSearchText: "preserved"
        )
        let workspaceID = try XCTUnwrap(workspace.workspace.id)
        let logicalFingerprint = try logicalAuthorityFingerprint(database, workspaceID: workspaceID)
        let binaryCount = try database.scalarIntForTesting(
            "SELECT COUNT(*) FROM binaries WHERE workspace_id = \(workspaceID);"
        )
        // Establish the no-mutation baseline through the same SQLite decoding boundary used
        // after repair. The insert result still carries subsecond `Date()` precision that the
        // durable date representation intentionally normalizes, so comparing against it would
        // test timestamp encoding rather than repair isolation.
        let persistedBeforeCorruption = try XCTUnwrap(
            database.loadWorkspaceState(workspaceID: workspaceID)
        )
        let workspaceBefore = persistedBeforeCorruption.workspace
        let sessionBefore = persistedBeforeCorruption.session
        let binariesBefore = persistedBeforeCorruption.snapshot.binaries
        try database.executeRawForTesting(
            "UPDATE launch_profile_catalogs SET catalog_sha256 = printf('%064d', 0) WHERE workspace_id = \(workspaceID);"
        )

        let loaded = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(loaded.launchProfileCatalogAvailability, .unavailable)
        XCTAssertTrue(loaded.snapshot.launchProfileCatalog.isPristine)
        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID)) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileCatalogUnavailable)
        }
        XCTAssertThrowsError(
            try database.replaceWorkspaceState(
                workspaceID: workspaceID,
                workspaceName: "must not replace",
                snapshot: loaded.snapshot,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: ""
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileCatalogUnavailable)
        }
        XCTAssertThrowsError(try database.packageManifest(workspaceID: workspaceID)) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileCatalogUnavailable)
        }
        XCTAssertEqual(try database.scalarTextForTesting(
            "SELECT name FROM workspaces WHERE id = \(workspaceID);"
        ), "before")

        let repaired = try database.discardCorruptLaunchProfileCatalog(workspaceID: workspaceID)
        XCTAssertTrue(repaired.isPristine)
        XCTAssertNotEqual(repaired.catalogID, catalog.catalogID)
        XCTAssertEqual(try logicalAuthorityFingerprint(database, workspaceID: workspaceID), logicalFingerprint)
        XCTAssertEqual(
            try database.scalarIntForTesting(
                "SELECT COUNT(*) FROM binaries WHERE workspace_id = \(workspaceID);"
            ),
            binaryCount
        )
        let reloaded = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.launchProfileCatalogAvailability, .available)
        XCTAssertEqual(reloaded.snapshot.launchProfileCatalog, repaired)
        XCTAssertEqual(reloaded.workspace, workspaceBefore)
        XCTAssertEqual(reloaded.session, sessionBefore)
        XCTAssertEqual(reloaded.snapshot.binaries, binariesBefore)
    }

    func testMissingAndMalformedStorageReceiptsFailClosedAtEveryOrdinarySaveBoundary() throws {
        let corruptions = [
            "DELETE FROM launch_profile_catalogs;",
            "UPDATE launch_profile_catalogs SET catalog_byte_count = catalog_byte_count + 1;",
            "UPDATE launch_profile_catalogs SET catalog_blob = CAST(catalog_blob AS TEXT);",
        ]

        for corruption in corruptions {
            let database = try WorkspaceDatabase.inMemory()
            try database.applySchema()
            let persisted = try database.createWorkspaceState(
                workspaceName: "receipt",
                snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: ""
            )
            let workspaceID = try XCTUnwrap(persisted.workspace.id)
            try database.executeRawForTesting(corruption)

            let loaded = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
            XCTAssertEqual(
                loaded.launchProfileCatalogAvailability,
                .unavailable,
                corruption
            )
            XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID)) { error in
                XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileCatalogUnavailable)
            }
            XCTAssertThrowsError(try database.packageManifest(workspaceID: workspaceID)) { error in
                XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileCatalogUnavailable)
            }
            XCTAssertThrowsError(
                try database.replaceWorkspaceState(
                    workspaceID: workspaceID,
                    workspaceName: "blocked",
                    snapshot: loaded.snapshot,
                    selectedSidebarItemID: nil,
                    selectedAddress: nil,
                    selectedTool: .project,
                    editorMode: .disassembly,
                    isInspectorPresented: true,
                    sidebarSearchText: ""
                )
            ) { error in
                XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileCatalogUnavailable)
            }
            XCTAssertEqual(
                try database.scalarTextForTesting(
                    "SELECT name FROM workspaces WHERE id = \(workspaceID);"
                ),
                "receipt"
            )
        }
    }

    private func logicalCatalog(binaryID: UUID) throws -> DebuggerLogicalBreakpointCatalog {
        let specification = try DebuggerLogicalBreakpointSpecification(
            id: DebuggerLogicalBreakpointID(
                rawValue: UUID(uuidString: "F0000000-0000-0000-0000-000000000031")!
            ),
            revision: DebuggerLogicalBreakpointRevision(validating: 1),
            enabled: true,
            target: .preferredAddress(
                owner: DebuggerWorkspaceImageOwnerSeal(
                    slot: .primary,
                    binaryID: binaryID,
                    artifactIdentity: nil
                ),
                preferredVA: 0x1_0000_0000
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
        return try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(uuidString: "F1000000-0000-0000-0000-000000000031")!,
            revision: 1,
            specifications: [specification]
        )
    }

    private func logicalAuthorityFingerprint(
        _ database: WorkspaceDatabase,
        workspaceID: Int64
    ) throws -> String {
        let header = try XCTUnwrap(database.scalarTextForTesting(
            """
            SELECT typeof(workspace_id)||':'||hex(workspace_id)||'|'||
                   typeof(workspace_uuid)||':'||hex(workspace_uuid)||'|'||
                   typeof(catalog_uuid)||':'||hex(catalog_uuid)||'|'||
                   typeof(revision)||':'||hex(revision)||'|'||
                   typeof(specification_count)||':'||hex(specification_count)||'|'||
                   typeof(catalog_sha256)||':'||hex(catalog_sha256)
            FROM logical_breakpoint_catalogs WHERE workspace_id = \(workspaceID);
            """
        ))
        let children = try database.scalarTextForTesting(
            """
            SELECT group_concat(fingerprint, ';') FROM (
              SELECT typeof(id)||':'||hex(id)||'|'||
                     typeof(workspace_id)||':'||hex(workspace_id)||'|'||
                     typeof(revision)||':'||hex(revision)||'|'||
                     typeof(specification_version)||':'||hex(specification_version)||'|'||
                     typeof(specification_byte_count)||':'||hex(specification_byte_count)||'|'||
                     typeof(specification_sha256)||':'||hex(specification_sha256)||'|'||
                     typeof(specification_json)||':'||hex(specification_json)||'|'||
                     typeof(created_at)||':'||hex(created_at)||'|'||
                     typeof(modified_at)||':'||hex(modified_at) AS fingerprint
              FROM logical_breakpoints WHERE workspace_id = \(workspaceID) ORDER BY id
            );
            """
        ) ?? "<none>"
        return header + "#" + children
    }
}
