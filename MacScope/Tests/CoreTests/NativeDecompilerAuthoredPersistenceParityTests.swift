import SQLite3
import XCTest
@testable import MacScope

final class NativeDecompilerAuthoredPersistenceParityTests: XCTestCase {
    func testPackageAndFreshV41DatabaseRestoreProduceIdenticalAuthoredDigest() throws {
        let databaseURL = temporarySQLiteURL()
        let packageURL = temporaryPackageURL()
        defer { removePersistenceArtifacts(databaseURL: databaseURL, packageURL: packageURL) }
        let snapshot = try authoredSnapshot(
            layoutRules: AggregateLayoutRules(
                isPacked: true,
                packAlignment: 2,
                minimumAlignment: 8
            )
        )
        let workspaceID = try persistAndWritePackage(
            snapshot,
            databaseURL: databaseURL,
            packageURL: packageURL
        )

        let packageSnapshot = try MacScopeDocumentPackage.openPackage(from: packageURL).snapshot
        let database = try WorkspaceDatabase(path: databaseURL.path)
        try database.applySchema()
        let restored = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        let packageProjection = try requireValidProjection(packageSnapshot)
        let databaseProjection = try requireValidProjection(restored.snapshot)

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(restored.typeCatalogLoadDiagnostics, [])
        XCTAssertEqual(
            packageProjection.canonicalIdentitySHA256,
            databaseProjection.canonicalIdentitySHA256
        )
        XCTAssertEqual(packageProjection.authoredInputs, databaseProjection.authoredInputs)
    }

    func testPackageAndMigratedV38DefaultLayoutProduceIdenticalAuthoredDigestWithLossDiagnostic() throws {
        let databaseURL = temporarySQLiteURL()
        let packageURL = temporaryPackageURL()
        defer { removePersistenceArtifacts(databaseURL: databaseURL, packageURL: packageURL) }
        let snapshot = try authoredSnapshot(layoutRules: .default)
        let workspaceID = try persistAndWritePackage(
            snapshot,
            databaseURL: databaseURL,
            packageURL: packageURL
        )
        let packageSnapshot = try MacScopeDocumentPackage.openPackage(from: packageURL).snapshot
        try replaceTypeDefinitionsWithV38Shape(at: databaseURL)

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        try migrated.applySchema()
        let restored = try XCTUnwrap(migrated.loadWorkspaceState(workspaceID: workspaceID))
        let packageProjection = try requireValidProjection(packageSnapshot)
        let migratedProjection = try requireValidProjection(restored.snapshot)

        XCTAssertEqual(try migrated.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertEqual(
            restored.typeCatalogLoadDiagnostics,
            [.legacyDefaultLayoutSubstitution(typeName: "Packet")]
        )
        XCTAssertEqual(
            packageProjection.canonicalIdentitySHA256,
            migratedProjection.canonicalIdentitySHA256
        )
        XCTAssertEqual(packageProjection.authoredInputs, migratedProjection.authoredInputs)
    }

    func testMigratedV38CannotClaimParityWithHistoricallyLostNondefaultPackageLayout() throws {
        let databaseURL = temporarySQLiteURL()
        let packageURL = temporaryPackageURL()
        defer { removePersistenceArtifacts(databaseURL: databaseURL, packageURL: packageURL) }
        let retainedPackageLayout = AggregateLayoutRules(
            isPacked: true,
            packAlignment: 4,
            minimumAlignment: 16
        )
        let snapshot = try authoredSnapshot(layoutRules: retainedPackageLayout)
        let workspaceID = try persistAndWritePackage(
            snapshot,
            databaseURL: databaseURL,
            packageURL: packageURL
        )
        let packageSnapshot = try MacScopeDocumentPackage.openPackage(from: packageURL).snapshot
        try replaceTypeDefinitionsWithV38Shape(at: databaseURL)

        let migrated = try WorkspaceDatabase(path: databaseURL.path)
        try migrated.applySchema()
        let restored = try XCTUnwrap(migrated.loadWorkspaceState(workspaceID: workspaceID))
        let packageProjection = try requireValidProjection(packageSnapshot)
        let migratedProjection = try requireValidProjection(restored.snapshot)

        XCTAssertEqual(packageSnapshot.typeDefinitions.first?.layoutRules, retainedPackageLayout)
        XCTAssertEqual(restored.snapshot.typeDefinitions.first?.layoutRules, .default)
        XCTAssertEqual(
            restored.typeCatalogLoadDiagnostics,
            [.legacyDefaultLayoutSubstitution(typeName: "Packet")]
        )
        XCTAssertNotEqual(
            packageProjection.canonicalIdentitySHA256,
            migratedProjection.canonicalIdentitySHA256
        )
        XCTAssertNotEqual(packageProjection.authoredInputs, migratedProjection.authoredInputs)
    }

    private func authoredSnapshot(
        layoutRules: AggregateLayoutRules
    ) throws -> WorkspaceSnapshot {
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = [
            TypeDefinition(
                id: UUID(uuidString: "39000000-0000-0000-0000-000000000101")!,
                kind: .struct,
                name: "Packet",
                fields: [
                    FieldDef(
                        name: "value",
                        type: "uint32_t",
                        declaratorSemanticsV1: .ordinary
                    ),
                    FieldDef(
                        name: "next",
                        type: "struct Packet *",
                        declaratorSemanticsV1: .ordinary
                    ),
                ],
                layoutRules: layoutRules
            ),
        ]
        let binary = try XCTUnwrap(snapshot.binaries.first)
        let function = try XCTUnwrap(snapshot.analysis(in: binary.slot)?.functions.first)
        snapshot.addressOverrides[ImageAddress(slot: binary.slot, address: function.startAddress)] =
            AddressOverride(signature: FunctionSignatureOverride(
                parameterList: .authoritative([
                    ArgOverride(rowToken: "packet", name: "packet", type: "struct Packet *"),
                ])
            ))
        return snapshot
    }

    private func persistAndWritePackage(
        _ snapshot: WorkspaceSnapshot,
        databaseURL: URL,
        packageURL: URL
    ) throws -> Int64 {
        let database = try WorkspaceDatabase(path: databaseURL.path)
        try database.applySchema()
        let persisted = try database.saveSnapshot(
            workspaceUUID: UUID(uuidString: "39000000-0000-0000-0000-000000000102")!,
            workspaceName: "Authored persistence parity",
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1_800_039_101)
        )
        let workspaceID = try XCTUnwrap(persisted.id)
        try database.writePackage(
            workspaceID: workspaceID,
            documentID: UUID(uuidString: "39000000-0000-0000-0000-000000000103")!,
            to: packageURL
        )
        return workspaceID
    }

    private func requireValidProjection(
        _ snapshot: WorkspaceSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NativeDecompilerAuthoredProjection {
        let binary = try XCTUnwrap(snapshot.binaries.first, file: file, line: line)
        let function = try XCTUnwrap(
            snapshot.analysis(in: binary.slot)?.functions.first,
            file: file,
            line: line
        )
        switch NativeDecompilerAuthoredInputProjector.project(
            workspace: snapshot,
            imageSlot: binary.slot,
            functionID: function.id
        ) {
        case let .valid(projection):
            return projection
        case let .invalid(diagnostic):
            XCTFail("expected valid authored projection, got \(diagnostic)", file: file, line: line)
            throw diagnostic
        }
    }

    private func replaceTypeDefinitionsWithV38Shape(at databaseURL: URL) throws {
        try executeSQLiteStatements(
            """
            PRAGMA foreign_keys = OFF;
            BEGIN IMMEDIATE;
            DROP INDEX IF EXISTS idx_type_definitions_workspace_name;
            ALTER TABLE type_definitions RENAME TO type_definitions_v39;
            CREATE TABLE type_definitions (
              id TEXT PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              kind TEXT NOT NULL,
              name TEXT NOT NULL,
              fields_json TEXT NOT NULL,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
            );
            INSERT INTO type_definitions (
              id, workspace_id, kind, name, fields_json, created_at, modified_at
            )
            SELECT id, workspace_id, kind, name, fields_json, created_at, modified_at
            FROM type_definitions_v39;
            DROP TABLE type_definitions_v39;
            CREATE UNIQUE INDEX idx_type_definitions_workspace_name
              ON type_definitions(workspace_id, name);
            PRAGMA user_version = 38;
            COMMIT;
            PRAGMA foreign_keys = ON;
            """,
            to: databaseURL
        )
    }

    private func executeSQLiteStatements(
        _ sql: String,
        to databaseURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var handle: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        XCTAssertEqual(openStatus, SQLITE_OK, file: file, line: line)
        let connection = try XCTUnwrap(handle, file: file, line: line)
        defer { sqlite3_close(connection) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(connection, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) } ?? "Unknown SQLite error"
        sqlite3_free(errorMessage)
        XCTAssertEqual(status, SQLITE_OK, message, file: file, line: line)
    }

    private func temporarySQLiteURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func temporaryPackageURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(MacScopeDocumentPackage.fileExtension)
    }

    private func removePersistenceArtifacts(databaseURL: URL, packageURL: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: packageURL)
        try? fileManager.removeItem(at: databaseURL)
        try? fileManager.removeItem(atPath: databaseURL.path + "-shm")
        try? fileManager.removeItem(atPath: databaseURL.path + "-wal")
    }
}
