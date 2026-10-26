import Foundation
import XCTest
@testable import MacScope

final class DebuggerLogicalBreakpointPersistenceTests: XCTestCase {
    func testSchemaRetainsExactLogicalCatalogTablesAndIndex() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()

        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
        XCTAssertTrue(try database.tableNames().contains("logical_breakpoint_catalogs"))
        XCTAssertTrue(try database.tableNames().contains("logical_breakpoints"))
        XCTAssertEqual(
            try database.columnNames(in: "logical_breakpoint_catalogs"),
            [
                "workspace_id", "workspace_uuid", "catalog_uuid", "revision",
                "specification_count", "catalog_sha256",
            ]
        )
        XCTAssertEqual(
            try database.columnNames(in: "logical_breakpoints"),
            [
                "id", "workspace_id", "revision", "specification_version",
                "specification_byte_count", "specification_sha256", "specification_json",
                "created_at", "modified_at",
            ]
        )
        XCTAssertEqual(
            try database.indexColumns(of: "idx_logical_breakpoints_workspace_id"),
            ["workspace_id", "id"]
        )
    }

    func testSQLiteSaveReopenSavePreservesCanonicalCatalog() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspaceUUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
        let catalog = try catalog(revision: 7)
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            analysisBySlot: [:],
            logicalBreakpointCatalog: catalog
        )

        let workspace = try database.saveSnapshot(
            workspaceUUID: workspaceUUID,
            workspaceName: "Breakpoints",
            snapshot: snapshot
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let loaded = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(loaded.logicalBreakpointCatalog, catalog)

        _ = try database.replaceWorkspaceState(
            workspaceID: workspaceID,
            workspaceName: "Breakpoints",
            snapshot: loaded,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let resaved = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(resaved.logicalBreakpointCatalog),
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(catalog)
        )
    }

    func testPackageMissingAndPristineCatalogOmitKeyButDeletionTombstonePersists() throws {
        let missing = try JSONDecoder().decode(
            WorkspacePackageAnalysis.self,
            from: Data(#"{"functions":[],"symbols":[],"imports":[],"indirectSymbols":[],"exports":[],"stringLiterals":[],"basicBlocks":[],"instructions":[],"xrefs":[],"controlFlowEdges":[],"addressOverrides":[],"typeDefinitions":[],"manualXRefs":[],"bookmarks":[],"segmentOverrides":[]}"#.utf8)
        )
        XCTAssertTrue(missing.logicalBreakpointCatalog.isPristine)
        XCTAssertFalse(missing.hasAuthoringPayload)

        let pristineData = try JSONEncoder().encode(WorkspacePackageAnalysis())
        let pristineObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: pristineData) as? [String: Any]
        )
        XCTAssertNil(pristineObject["logicalBreakpointCatalog"])

        let tombstone = try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!,
            revision: 2,
            specifications: []
        )
        let analysis = WorkspacePackageAnalysis(logicalBreakpointCatalog: tombstone)
        XCTAssertTrue(analysis.hasAuthoringPayload)
        let tombstoneData = try JSONEncoder().encode(analysis)
        let tombstoneObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: tombstoneData) as? [String: Any]
        )
        XCTAssertNotNil(tombstoneObject["logicalBreakpointCatalog"])
        XCTAssertEqual(
            try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: tombstoneData)
                .logicalBreakpointCatalog,
            tombstone
        )
    }

    func testPerImagePackageAnalysisCannotCarryLogicalAuthoring() throws {
        let catalog = try catalog(revision: 2)
        let analysis = WorkspacePackageAnalysis(logicalBreakpointCatalog: catalog)
        XCTAssertTrue(analysis.hasAuthoringPayload)

        let derivedOnly = WorkspacePackageAnalysis(imageAnalysis: ImageAnalysis())
        XCTAssertTrue(derivedOnly.logicalBreakpointCatalog.isPristine)
        XCTAssertFalse(derivedOnly.hasAuthoringPayload)
        let encoded = try JSONEncoder().encode(derivedOnly)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["logicalBreakpointCatalog"])
    }

    func testCorruptDatabaseCatalogOpensAnalysisUnavailableBlocksSaveAndRequiresExplicitRepair() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let originalCatalog = try catalog(revision: 3)
        let preservedBinary = BinaryImage(
            id: UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000031")!,
            name: "Preserved",
            path: "/tmp/Preserved",
            kind: "ELF",
            architecture: "arm64",
            slot: .primary
        )
        let preservedAnalysis = ImageAnalysis(
            functions: [
                FunctionSummary(
                    id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000031")!,
                    name: "_preserved",
                    startAddress: 0x1_0000_3000,
                    endAddress: 0x1_0000_3004,
                    confidence: 1
                ),
            ],
            instructions: [
                InstructionRow(
                    address: 0x1_0000_3000,
                    bytes: "c0 03 5f d6",
                    mnemonic: "ret",
                    operands: "",
                    hasBreakpoint: false
                ),
            ]
        )
        let persisted = try database.createWorkspaceState(
            workspaceUUID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000031")!,
            workspaceName: "Corrupt",
            snapshot: WorkspaceSnapshot(
                binaries: [preservedBinary],
                analysisBySlot: [.primary: preservedAnalysis],
                logicalBreakpointCatalog: originalCatalog
            ),
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let workspaceID: Int64 = try XCTUnwrap(persisted.workspace.id)
        try database.executeRawForTesting("""
            UPDATE logical_breakpoints
            SET specification_sha256 = '\(String(repeating: "0", count: 64))'
            WHERE workspace_id = \(workspaceID);
            """)

        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID)) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .logicalBreakpointCatalogUnavailable)
        }
        let unavailable = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(
            unavailable.logicalBreakpointCatalogAvailability,
            DebuggerLogicalBreakpointCatalogAvailability.unavailable
        )
        XCTAssertTrue(unavailable.snapshot.logicalBreakpointCatalog.specifications.isEmpty)
        XCTAssertThrowsError(
            try database.replaceWorkspaceState(
                workspaceID: workspaceID,
                workspaceName: "Blocked",
                snapshot: unavailable.snapshot,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: ""
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .logicalBreakpointCatalogUnavailable)
        }

        let repaired = try database.discardCorruptLogicalBreakpointCatalog(workspaceID: workspaceID)
        XCTAssertTrue(repaired.isPristine)
        XCTAssertNotEqual(repaired.catalogID, originalCatalog.catalogID)
        let available = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(
            available.logicalBreakpointCatalogAvailability,
            DebuggerLogicalBreakpointCatalogAvailability.available
        )
        XCTAssertEqual(available.snapshot.logicalBreakpointCatalog, repaired)
        XCTAssertEqual(available.snapshot.binary(in: .primary)?.id, preservedBinary.id)
        XCTAssertEqual(
            available.snapshot.analysis(in: .primary)?.instructions,
            preservedAnalysis.instructions
        )
        XCTAssertEqual(available.workspace.name, "Corrupt")
        XCTAssertNoThrow(
            try database.replaceWorkspaceState(
                workspaceID: workspaceID,
                workspaceName: "Unblocked",
                snapshot: available.snapshot,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: ""
            )
        )
    }

    func testCorruptPackageCatalogPreservesUnavailableLatchAndCannotBeReencoded() throws {
        let valid = try JSONEncoder().encode(
            WorkspacePackageAnalysis(logicalBreakpointCatalog: try catalog(revision: 2))
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var catalogObject = try XCTUnwrap(object["logicalBreakpointCatalog"] as? [String: Any])
        catalogObject["revision"] = 0
        object["logicalBreakpointCatalog"] = catalogObject
        let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: corrupt)
        XCTAssertEqual(decoded.logicalBreakpointCatalogAvailability, .unavailable)
        XCTAssertTrue(decoded.logicalBreakpointCatalog.specifications.isEmpty)
        XCTAssertTrue(decoded.hasAuthoringPayload)
        XCTAssertThrowsError(try JSONEncoder().encode(decoded)) { error in
            XCTAssertEqual(
                error as? DebuggerLogicalBreakpointCatalogPersistenceError,
                .unavailable
            )
        }
    }

    func testPackageLogicalCatalogRejectsUnknownAndRuntimeKeysButAcceptsPrettyJSON() throws {
        let authored = try catalogWithAction(revision: 2)
        let valid = try JSONEncoder().encode(
            WorkspacePackageAnalysis(logicalBreakpointCatalog: authored)
        )
        let prettyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        let pretty = try JSONSerialization.data(withJSONObject: prettyObject, options: [.prettyPrinted])
        let prettyDecoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: pretty)
        XCTAssertEqual(prettyDecoded.logicalBreakpointCatalogAvailability, .available)
        XCTAssertEqual(prettyDecoded.logicalBreakpointCatalog, authored)

        for insertion in ["catalog", "specification", "locator", "action", "runtime"] {
            var object = prettyObject
            var catalogObject = try XCTUnwrap(object["logicalBreakpointCatalog"] as? [String: Any])
            var specifications = try XCTUnwrap(catalogObject["specifications"] as? [[String: Any]])
            var specification = try XCTUnwrap(specifications.first)
            switch insertion {
            case "catalog":
                catalogObject["futureCatalogField"] = true
            case "specification":
                specification["futureSpecificationField"] = "ignored-before-ws21"
            case "locator":
                var target = try XCTUnwrap(specification["target"] as? [String: Any])
                target["futureLocatorField"] = 7
                specification["target"] = target
            case "action":
                var actions = try XCTUnwrap(specification["actions"] as? [[String: Any]])
                actions[0]["futureActionField"] = true
                specification["actions"] = actions
            case "runtime":
                specification["backendBreakpointID"] = 41
            default:
                XCTFail("Unhandled insertion")
            }
            specifications[0] = specification
            catalogObject["specifications"] = specifications
            object["logicalBreakpointCatalog"] = catalogObject
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
            let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: data)
            XCTAssertEqual(
                decoded.logicalBreakpointCatalogAvailability,
                .unavailable,
                insertion
            )
            XCTAssertTrue(decoded.logicalBreakpointCatalog.specifications.isEmpty, insertion)
        }
    }

    func testPackageLogicalCatalogPreservesCanonicallyEquivalentTextAsExactUTF8() throws {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        XCTAssertEqual(nfc, nfd, "Swift String equality is intentionally canonical-equivalent")
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8))

        let nfcCatalog = try catalogWithAction(revision: 2, label: nfc)
        let nfdCatalog = try catalogWithAction(revision: 2, label: nfd)
        XCTAssertNotEqual(nfcCatalog, nfdCatalog)

        for (name, catalog, expectedLabel) in [
            ("NFC", nfcCatalog, nfc),
            ("NFD", nfdCatalog, nfd),
        ] {
            let encoded = try JSONEncoder().encode(
                WorkspacePackageAnalysis(logicalBreakpointCatalog: catalog)
            )
            let decoded = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: encoded)
            XCTAssertEqual(decoded.logicalBreakpointCatalogAvailability, .available, name)
            XCTAssertEqual(
                Array(try XCTUnwrap(expressionLabel(in: decoded.logicalBreakpointCatalog)).utf8),
                Array(expectedLabel.utf8),
                name
            )

            let reencoded = try JSONEncoder().encode(decoded)
            let retried = try JSONDecoder().decode(WorkspacePackageAnalysis.self, from: reencoded)
            XCTAssertEqual(retried.logicalBreakpointCatalogAvailability, .available, name)
            XCTAssertEqual(
                Array(try XCTUnwrap(expressionLabel(in: retried.logicalBreakpointCatalog)).utf8),
                Array(expectedLabel.utf8),
                name
            )
        }
    }

    func testPackageLogicalCatalogRejectsDuplicateKeysAtEveryNestedAuthorityLevel() throws {
        let valid = try JSONEncoder().encode(
            WorkspacePackageAnalysis(logicalBreakpointCatalog: try catalogWithAction(revision: 2))
        )
        let json = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let members = [
            "\"catalogID\":\"CCCCCCCC-0000-0000-0000-000000000091\"",
            "\"enabled\":true",
            "\"preferredVA\":4294971392",
            "\"type\":\"evaluateTargetExpression\"",
        ]
        for member in members {
            let duplicate = "\(member),\(member)"
            let hostile = try replacingFirst(member, with: duplicate, in: json)
            let decoded = try WorkspacePackageAnalysis.decodeStrictPackageJSON(
                from: Data(hostile.utf8)
            )
            XCTAssertEqual(decoded.logicalBreakpointCatalogAvailability, .unavailable, member)
            XCTAssertTrue(decoded.logicalBreakpointCatalog.specifications.isEmpty, member)
        }

        let catalogJSON = try XCTUnwrap(String(
            data: DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(
                try catalogWithAction(revision: 2)
            ),
            encoding: .utf8
        ))
        let duplicateCatalogMember = """
            {
              "logicalBreakpointCatalog": \(catalogJSON),
              "logicalBreakpointCatalog": \(catalogJSON)
            }
            """
        let duplicatedCatalog = try WorkspacePackageAnalysis.decodeStrictPackageJSON(
            from: Data(duplicateCatalogMember.utf8)
        )
        XCTAssertEqual(duplicatedCatalog.logicalBreakpointCatalogAvailability, .unavailable)
        XCTAssertTrue(duplicatedCatalog.logicalBreakpointCatalog.specifications.isEmpty)

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mscope")
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let manifest = WorkspacePackageManifest(
            documentID: UUID(),
            workspaceUUID: UUID(),
            workspaceName: "Duplicate nested catalog",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1),
            binaries: [],
            analysis: WorkspacePackageAnalysis(
                logicalBreakpointCatalog: try catalogWithAction(revision: 2)
            ),
            imageAnalyses: nil,
            session: nil
        )
        try MacScopeDocumentPackage.writeManifest(manifest, to: packageURL)
        let manifestURL = packageURL.appendingPathComponent(
            MacScopeDocumentPackage.manifestFileName
        )
        let duplicatedManifest = try duplicatingJSONObjectMember(
            named: "logicalBreakpointCatalog",
            in: Data(contentsOf: manifestURL)
        )
        try duplicatedManifest.write(to: manifestURL, options: .atomic)
        let decodedManifest = try MacScopeDocumentPackage.readManifest(from: packageURL)
        XCTAssertEqual(
            decodedManifest.analysis?.logicalBreakpointCatalogAvailability,
            .unavailable
        )
    }

    func testV29FinalizerPreservesUpperHalfAddressAndRetriesDeterministically() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let address: UInt64 = 0xFFFF_0000_0000_1000
        let workspace = try database.saveSnapshot(
            workspaceUUID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000071")!,
            workspaceName: "Upper half",
            snapshot: legacySnapshotWithSameAddressBreakpoints()
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let signedAddress = Int64(bitPattern: address)
        try database.executeRawForTesting("""
            UPDATE instructions SET address = \(signedAddress);
            UPDATE functions
            SET start_address = \(signedAddress), end_address = \(signedAddress + 4);
            PRAGMA user_version = 29;
            """)
        try database.applySchema()

        let firstSnapshot = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
        let first = firstSnapshot.logicalBreakpointCatalog
        XCTAssertEqual(Set(first.specifications.compactMap(Self.preferredAddress)), Set([address]))
        for binary in firstSnapshot.binaries {
            let analysis = try XCTUnwrap(firstSnapshot.analysis(in: binary.slot))
            XCTAssertEqual(analysis.functions.first?.startAddress, address)
            XCTAssertEqual(analysis.functions.first?.endAddress, address + 4)
            XCTAssertEqual(analysis.instructions.first?.address, address)
        }
        try database.setUserVersionForTesting(29)
        try database.applySchema()
        let retry = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
            .logicalBreakpointCatalog
        XCTAssertEqual(
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(first),
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(retry)
        )
        try database.executeRawForTesting(
            "UPDATE functions SET start_address = 'not-an-address' "
                + "WHERE id = (SELECT MIN(id) FROM functions);"
        )
        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: workspaceID))
    }

    func testV29FinalizerRebuildsPartialAndBadExistingReceiptsThenRetries() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceUUID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000072")!,
            workspaceName: "Partial receipt",
            snapshot: legacySnapshotWithSameAddressBreakpoints()
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting("""
            UPDATE logical_breakpoint_catalogs
            SET specification_count = 1
            WHERE workspace_id = \(workspaceID);
            PRAGMA user_version = 29;
            """)
        try database.applySchema()
        let rebuilt = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
            .logicalBreakpointCatalog
        XCTAssertEqual(rebuilt.specifications.count, 2)

        try database.executeRawForTesting("""
            UPDATE logical_breakpoint_catalogs
            SET catalog_sha256 = '\(String(repeating: "0", count: 64))'
            WHERE workspace_id = \(workspaceID);
            PRAGMA user_version = 29;
            """)
        try database.applySchema()
        let repairedRetry = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
            .logicalBreakpointCatalog
        XCTAssertEqual(
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(rebuilt),
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(repairedRetry)
        )
    }

    func testV29FinalizerRejectsSameColumnsWithWrongConstraintsAndAllowsValidRetry() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        try database.executeRawForTesting("""
            DROP TABLE logical_breakpoints;
            DROP TABLE logical_breakpoint_catalogs;
            CREATE TABLE logical_breakpoint_catalogs (
              workspace_id INTEGER PRIMARY KEY,
              workspace_uuid TEXT,
              catalog_uuid TEXT,
              revision INTEGER,
              specification_count INTEGER,
              catalog_sha256 TEXT
            );
            CREATE TABLE logical_breakpoints (
              id TEXT PRIMARY KEY,
              workspace_id INTEGER,
              revision INTEGER,
              specification_version INTEGER,
              specification_byte_count INTEGER,
              specification_sha256 TEXT,
              specification_json TEXT,
              created_at TEXT,
              modified_at TEXT
            );
            CREATE UNIQUE INDEX idx_logical_breakpoints_workspace_id
              ON logical_breakpoints(workspace_id, id);
            PRAGMA user_version = 29;
            """)

        XCTAssertThrowsError(try database.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .logicalBreakpointSchemaInvalid
            )
        }
        XCTAssertEqual(try database.userVersion(), 29)
        try database.executeRawForTesting("""
            DROP TABLE logical_breakpoints;
            DROP TABLE logical_breakpoint_catalogs;
            """)
        try database.applySchema()
        XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion)
    }

    func testCatalogRejectsCoercibleTextInEveryMutableIntegerMetadataColumn() throws {
        let mutations: [(field: String, sql: String)] = [
            (
                "logical_breakpoint_catalogs.revision",
                "UPDATE logical_breakpoint_catalogs SET revision = revision || 'x';"
            ),
            (
                "logical_breakpoint_catalogs.specification_count",
                "UPDATE logical_breakpoint_catalogs "
                    + "SET specification_count = specification_count || 'x';"
            ),
            (
                "logical_breakpoints.workspace_id",
                "PRAGMA foreign_keys = OFF; "
                    + "UPDATE logical_breakpoints SET workspace_id = workspace_id || 'x'; "
                    + "PRAGMA foreign_keys = ON;"
            ),
            (
                "logical_breakpoints.revision",
                "UPDATE logical_breakpoints SET revision = revision || 'x';"
            ),
            (
                "logical_breakpoints.specification_version",
                "UPDATE logical_breakpoints "
                    + "SET specification_version = specification_version || 'x';"
            ),
            (
                "logical_breakpoints.specification_byte_count",
                "UPDATE logical_breakpoints "
                    + "SET specification_byte_count = specification_byte_count || 'x';"
            ),
        ]
        for mutation in mutations {
            let database = try WorkspaceDatabase.inMemory()
            try database.applySchema()
            let workspace = try database.saveSnapshot(
                workspaceUUID: UUID(),
                workspaceName: "Storage class",
                snapshot: WorkspaceSnapshot(
                    binaries: [],
                    analysisBySlot: [:],
                    logicalBreakpointCatalog: try catalog(revision: 2)
                )
            )
            let workspaceID = try XCTUnwrap(workspace.id)
            try database.executeRawForTesting(mutation.sql)
            let state = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
            XCTAssertEqual(
                state.logicalBreakpointCatalogAvailability,
                .unavailable,
                mutation.field
            )
            XCTAssertTrue(
                state.snapshot.logicalBreakpointCatalog.specifications.isEmpty,
                mutation.field
            )
        }
    }

    func testDiscardRepairDeletesOrphanChildrenAndPreservesAnalysis() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceUUID: UUID(),
            workspaceName: "Orphan repair",
            snapshot: legacySnapshotWithSameAddressBreakpoints()
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        let before = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        try database.executeRawForTesting("""
            PRAGMA foreign_keys = OFF;
            UPDATE logical_breakpoints
            SET workspace_id = workspace_id || 'x'
            WHERE workspace_id = \(workspaceID);
            DELETE FROM logical_breakpoint_catalogs WHERE workspace_id = \(workspaceID);
            PRAGMA foreign_keys = ON;
            """)
        let unavailable = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(unavailable.logicalBreakpointCatalogAvailability, .unavailable)

        let repaired = try database.discardCorruptLogicalBreakpointCatalog(
            workspaceID: workspaceID
        )
        XCTAssertTrue(repaired.isPristine)
        let after = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(after.logicalBreakpointCatalogAvailability, .available)
        XCTAssertEqual(after.workspace.name, before.workspace.name)
        XCTAssertEqual(
            after.snapshot.binaries.flatMap {
                after.snapshot.analysis(in: $0.slot)?.instructions ?? []
            },
            before.snapshot.binaries.flatMap {
                before.snapshot.analysis(in: $0.slot)?.instructions ?? []
            }
        )
        XCTAssertNoThrow(
            try database.replaceWorkspaceState(
                workspaceID: workspaceID,
                workspaceName: before.workspace.name,
                snapshot: before.snapshot,
                selectedSidebarItemID: before.session.selectedSidebarItemID,
                selectedAddress: before.session.selectedAddress,
                selectedTool: before.session.selectedTool,
                editorMode: before.session.editorMode,
                isInspectorPresented: before.session.isInspectorPresented,
                sidebarSearchText: before.session.sidebarSearchText,
                focusedImageSlot: before.session.focusedImageSlot
            )
        )
    }

    func testV29FinalizerDropsOrphanLogicalChildrenButRejectsOrphanLegacyIntent() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceUUID: UUID(),
            workspaceName: "Finalizer orphan",
            snapshot: legacySnapshotWithSameAddressBreakpoints()
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting("""
            PRAGMA foreign_keys = OFF;
            DELETE FROM logical_breakpoint_catalogs WHERE workspace_id = \(workspaceID);
            PRAGMA foreign_keys = ON;
            PRAGMA user_version = 29;
            """)
        try database.applySchema()
        XCTAssertEqual(
            try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
                .logicalBreakpointCatalog.specifications.count,
            2
        )

        try database.executeRawForTesting("""
            PRAGMA foreign_keys = OFF;
            DELETE FROM functions;
            PRAGMA foreign_keys = ON;
            PRAGMA user_version = 29;
            """)
        XCTAssertThrowsError(try database.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .logicalBreakpointCatalogUnavailable
            )
        }
        XCTAssertEqual(try database.userVersion(), 29)
    }

    func testPrerequisiteAndCurrentV30SchemaDamageFailsBeforeStampOrUse() throws {
        let prerequisite = try WorkspaceDatabase.inMemory()
        try prerequisite.applySchema()
        try prerequisite.executeRawForTesting("""
            DROP TABLE source_lines;
            CREATE TABLE source_lines (
              id INTEGER PRIMARY KEY,
              binary_id INTEGER NOT NULL,
              address INTEGER NOT NULL,
              file TEXT,
              line INTEGER NOT NULL,
              column INTEGER NOT NULL,
              is_end_sequence INTEGER NOT NULL DEFAULT 0,
              debug_artifact_uuid INTEGER,
              debug_artifact_macho_sha256 TEXT,
              debug_artifact_macho_byte_count INTEGER,
              line_program_unit_offset INTEGER,
              file_table_index INTEGER,
              table_path_kind TEXT,
              table_path TEXT
            );
            PRAGMA user_version = 29;
            """)
        XCTAssertThrowsError(try prerequisite.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .logicalBreakpointSchemaInvalid
            )
        }
        XCTAssertEqual(try prerequisite.userVersion(), 29)

        let current = try WorkspaceDatabase.inMemory()
        try current.applySchema()
        try current.executeRawForTesting("DROP INDEX idx_logical_breakpoints_workspace_id;")
        XCTAssertThrowsError(try current.applySchema()) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .logicalBreakpointSchemaInvalid
            )
        }
    }

    func testV2TopLevelSourceEvidenceIsRejectedAsDerivedPayload() throws {
        let source = SourceLineEntry(
            address: 0x1000,
            file: "/src/main.c",
            line: 1,
            column: 1,
            endSequence: false
        )
        let manifest = WorkspacePackageManifest(
            formatVersion: WorkspacePackageManifest.multiImageFormatVersion,
            documentID: UUID(),
            workspaceUUID: UUID(),
            workspaceName: "Hostile v2",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1),
            binaries: [],
            analysis: WorkspacePackageAnalysis(sourceLines: [source]),
            imageAnalyses: [],
            session: nil
        )
        XCTAssertThrowsError(
            try MacScopeDocumentPackage.validateManifest(
                manifest,
                in: URL(fileURLWithPath: "/tmp/Hostile-v2.mscope")
            )
        ) { error in
            XCTAssertEqual(
                error as? MacScopeDocumentPackage.PackageError,
                .version2TopLevelAnalysisContainsDerivedData
            )
        }
    }

    func testLegacyPartialSourceEvidenceRoundTripsWithoutInventingAuthority() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        var snapshot = legacySnapshotWithSameAddressBreakpoints()
        let slot = try XCTUnwrap(snapshot.binaries.first?.slot)
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        analysis.sourceLines = [
            SourceLineEntry(
                address: 0x1000,
                file: "/legacy/main.c",
                line: 7,
                column: 2,
                endSequence: false,
                debugArtifactUUID: UUID(uuidString: "77777777-0000-0000-0000-000000000007")!
            ),
        ]
        snapshot.replaceAnalysis(analysis, in: slot)
        let workspace = try database.saveSnapshot(
            workspaceUUID: UUID(),
            workspaceName: "Partial source",
            snapshot: snapshot
        )
        let reopened = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(workspace.id)))
        let line = try XCTUnwrap(reopened.analysis(in: slot)?.sourceLines.first)
        XCTAssertEqual(line.debugArtifactUUID, analysis.sourceLines[0].debugArtifactUUID)
        XCTAssertNil(line.debugArtifactMachOSHA256)
        XCTAssertNil(line.debugArtifactMachOByteCount)
        XCTAssertNil(line.lineProgramUnitOffset)
        XCTAssertNil(line.fileTableIndex)
        XCTAssertNil(line.tablePath)
    }

    func testEverySupportedStoredVersionConvergesToV30FromRepresentativeData() throws {
        var earlyCatalogBytes: Data?
        for version in 1...29 {
            let database = try WorkspaceDatabase.inMemory()
            try database.executeRawForTesting(historicalSchemaSQL(version: version))
            if (1...7).contains(version) {
                XCTAssertEqual(
                    try database.legacyBreakpointCountForTesting(workspaceID: 1),
                    1,
                    "stored version \(version) must start with durable legacy intent"
                )
            }

            try database.applySchema()
            XCTAssertEqual(try database.userVersion(), WorkspaceDatabase.schemaVersion, "stored version \(version)")
            XCTAssertTrue(
                try database.tableNames().contains("logical_breakpoint_catalogs"),
                "stored version \(version)"
            )

            if (1...7).contains(version) {
                let snapshot = try XCTUnwrap(
                    database.loadSnapshot(workspaceID: 1),
                    "stored version \(version)"
                )
                let catalog = snapshot.logicalBreakpointCatalog
                let specification = try XCTUnwrap(
                    catalog.specifications.first,
                    "stored version \(version)"
                )
                XCTAssertEqual(catalog.revision, 1, "stored version \(version)")
                XCTAssertEqual(catalog.specifications.count, 1, "stored version \(version)")
                XCTAssertEqual(specification.revision.rawValue, 1, "stored version \(version)")
                XCTAssertEqual(Self.preferredAddress(specification), 0x1_0000_1000)
                XCTAssertEqual(
                    Self.ownerBinaryID(specification),
                    UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000099")
                )
                XCTAssertEqual(specification.condition, nil, "stored version \(version)")
                XCTAssertEqual(specification.hitPolicy, .always, "stored version \(version)")
                XCTAssertEqual(specification.actions, [], "stored version \(version)")
                XCTAssertEqual(specification.disposition, .stop, "stored version \(version)")

                let canonical = try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(catalog)
                if let earlyCatalogBytes {
                    XCTAssertEqual(
                        canonical,
                        earlyCatalogBytes,
                        "the stored schema stamp must not change deterministic legacy intent"
                    )
                } else {
                    earlyCatalogBytes = canonical
                }
            }

            XCTAssertNoThrow(try database.applySchema(), "stored version \(version)")
            if (1...7).contains(version) {
                let reopened = try XCTUnwrap(database.loadSnapshot(workspaceID: 1))
                XCTAssertEqual(
                    try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(
                        reopened.logicalBreakpointCatalog
                    ),
                    earlyCatalogBytes,
                    "stored version \(version) must retain intent after current-schema reapply"
                )
            }
        }
    }

    func testV29FinalizerMigratesSameAddressRowsDeterministicallyAndIdempotently() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspaceUUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000029")!
        let snapshot = legacySnapshotWithSameAddressBreakpoints()
        let workspace = try database.saveSnapshot(
            workspaceUUID: workspaceUUID,
            workspaceName: "Legacy",
            snapshot: snapshot
        )
        let workspaceID = try XCTUnwrap(workspace.id)

        try database.executeRawForTesting("""
            DROP TABLE logical_breakpoints;
            DROP TABLE logical_breakpoint_catalogs;
            PRAGMA user_version = 29;
            """)
        try database.applySchema()

        let first = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
            .logicalBreakpointCatalog
        XCTAssertEqual(first.specifications.count, 2)
        XCTAssertEqual(Set(first.specifications.map(\.id)).count, 2)
        XCTAssertEqual(Set(first.specifications.compactMap(Self.preferredAddress)).count, 1)
        XCTAssertEqual(Set(first.specifications.compactMap(Self.ownerBinaryID)).count, 2)

        try database.applySchema()
        let second = try XCTUnwrap(database.loadSnapshot(workspaceID: workspaceID))
            .logicalBreakpointCatalog
        XCTAssertEqual(
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(first),
            try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(second)
        )
    }

    func testV29FinalizerRollsBackVersionAndIntentOnMalformedOwnership() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(
            workspaceUUID: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000030")!,
            workspaceName: "Malformed",
            snapshot: legacySnapshotWithSameAddressBreakpoints()
        )
        let workspaceID = try XCTUnwrap(workspace.id)
        try database.executeRawForTesting("""
            DROP TABLE logical_breakpoints;
            DROP TABLE logical_breakpoint_catalogs;
            UPDATE binaries SET uuid = 'not-a-uuid' WHERE workspace_id = \(workspaceID)
              AND image_slot = 0;
            PRAGMA user_version = 29;
            """)

        XCTAssertThrowsError(try database.applySchema())
        XCTAssertEqual(try database.userVersion(), 29)
        XCTAssertFalse(try database.tableNames().contains("logical_breakpoint_catalogs"))
        XCTAssertEqual(
            try database.legacyBreakpointCountForTesting(workspaceID: workspaceID),
            2
        )
    }

    private func catalog(revision: UInt64) throws -> DebuggerLogicalBreakpointCatalog {
        let spec = try DebuggerLogicalBreakpointSpecification(
            id: DebuggerLogicalBreakpointID(
                rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000001")!
            ),
            revision: DebuggerLogicalBreakpointRevision(validating: revision),
            enabled: true,
            target: .preferredAddress(
                owner: DebuggerWorkspaceImageOwnerSeal(
                    slot: .primary,
                    binaryID: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000001")!,
                    artifactIdentity: nil
                ),
                preferredVA: 0x1_0000_1000
            ),
            condition: "counter > 1",
            hitPolicy: .ignoreFirst(2),
            actions: [],
            disposition: .stop
        )
        return try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!,
            revision: revision,
            specifications: [spec]
        )
    }

    private func catalogWithAction(
        revision: UInt64,
        label: String = "value"
    ) throws -> DebuggerLogicalBreakpointCatalog {
        let spec = try DebuggerLogicalBreakpointSpecification(
            id: DebuggerLogicalBreakpointID(
                rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000091")!
            ),
            revision: DebuggerLogicalBreakpointRevision(validating: revision),
            enabled: true,
            target: .preferredAddress(
                owner: DebuggerWorkspaceImageOwnerSeal(
                    slot: .primary,
                    binaryID: UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000091")!,
                    artifactIdentity: nil
                ),
                preferredVA: 0x1_0000_1000
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [
                .evaluateTargetExpression(
                    try DebuggerBreakpointExpressionCapture(label: label, expression: "$x0")
                ),
            ],
            disposition: .stop
        )
        return try DebuggerLogicalBreakpointCatalog(
            catalogID: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000091")!,
            revision: revision,
            specifications: [spec]
        )
    }

    private func historicalSchemaSQL(version: Int) -> String {
        let stamp = "PRAGMA user_version = \(version);"
        if (1...7).contains(version) {
            // WorkspaceDatabase first appears in repository history with the complete v9 schema
            // and an explicit v8 migration. There are therefore no checked-in, version-specific
            // v1...v7 column inventories to fabricate here. The production early-version
            // contract instead recognizes these four durable core tables. Keep their definitions
            // verbatim-compatible with that earliest checked-in schema and populate real rows so
            // every supported early stamp proves data-preserving logical-breakpoint migration.
            return """
                CREATE TABLE workspaces (
                  id INTEGER PRIMARY KEY,
                  uuid TEXT NOT NULL UNIQUE,
                  name TEXT NOT NULL,
                  created_at TEXT NOT NULL,
                  modified_at TEXT NOT NULL
                );
                CREATE TABLE binaries (
                  id INTEGER PRIMARY KEY,
                  uuid TEXT NOT NULL UNIQUE,
                  workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                  name TEXT NOT NULL,
                  path TEXT NOT NULL,
                  original_path_bookmark BLOB,
                  kind TEXT NOT NULL,
                  architecture TEXT NOT NULL,
                  file_hash TEXT NOT NULL,
                  file_size INTEGER NOT NULL,
                  hex_bytes BLOB,
                  is_bundle INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE functions (
                  id INTEGER PRIMARY KEY,
                  uuid TEXT NOT NULL UNIQUE,
                  binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
                  start_address INTEGER NOT NULL,
                  end_address INTEGER,
                  symbol_name TEXT,
                  demangled_name TEXT,
                  confidence REAL NOT NULL DEFAULT 0.0
                );
                CREATE TABLE instructions (
                  id INTEGER PRIMARY KEY,
                  function_id INTEGER NOT NULL REFERENCES functions(id) ON DELETE CASCADE,
                  address INTEGER NOT NULL,
                  bytes BLOB NOT NULL,
                  mnemonic TEXT NOT NULL,
                  operands TEXT NOT NULL,
                  has_breakpoint INTEGER NOT NULL DEFAULT 0,
                  comment TEXT,
                  ir_json BLOB
                );
                CREATE INDEX idx_binaries_workspace_id ON binaries(workspace_id);
                CREATE INDEX idx_functions_binary_id ON functions(binary_id);
                CREATE INDEX idx_instructions_function_id ON instructions(function_id);
                CREATE UNIQUE INDEX idx_instructions_function_address
                  ON instructions(function_id, address);
                INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
                VALUES (
                  1, 'AAAAAAAA-0000-0000-0000-000000000099', 'Historical early workspace',
                  '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'
                );
                INSERT INTO binaries (
                  id, uuid, workspace_id, name, path, kind, architecture,
                  file_hash, file_size, hex_bytes, is_bundle
                ) VALUES (
                  1, 'BBBBBBBB-0000-0000-0000-000000000099', 1,
                  'Historical early binary', '/tmp/historical-early', 'Mach-O executable',
                  'arm64', 'historical-fixture', 4, X'C0035FD6', 0
                );
                INSERT INTO functions (
                  id, uuid, binary_id, start_address, end_address,
                  symbol_name, demangled_name, confidence
                ) VALUES (
                  1, 'CCCCCCCC-0000-0000-0000-000000000099', 1,
                  4294971392, 4294971396, '_historical_entry', NULL, 1.0
                );
                INSERT INTO instructions (
                  id, function_id, address, bytes, mnemonic, operands,
                  has_breakpoint, comment, ir_json
                ) VALUES (
                  1, 1, 4294971392, X'C0035FD6', 'ret', '', 1,
                  'durable early breakpoint', NULL
                );
                \(stamp)
                """
        }

        let workspace = """
            CREATE TABLE workspaces (
              id INTEGER PRIMARY KEY,
              uuid TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
            );
            INSERT INTO workspaces (id, uuid, name, created_at, modified_at)
            VALUES (
              1, 'AAAAAAAA-0000-0000-0000-000000000099', 'Historical',
              '2026-01-01T00:00:00.000Z', '2026-01-01T00:00:00.000Z'
            );
            """
        let overrideImageSlotColumn = version >= 26
            ? ", image_slot INTEGER NOT NULL DEFAULT 0" : ""
        let overrideIndexColumns = version >= 26
            ? "workspace_id, image_slot, address" : "workspace_id, address"
        let addressOverrides = """
            CREATE TABLE address_overrides (
              id INTEGER PRIMARY KEY,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              custom_name TEXT,
              custom_comment TEXT,
              created_at TEXT NOT NULL,
              modified_at TEXT NOT NULL
              \(overrideImageSlotColumn)
            );
            CREATE UNIQUE INDEX idx_address_overrides_workspace_address
              ON address_overrides(\(overrideIndexColumns));
            """
        let binaryImageIdentityColumns = version == 29
            ? ", image_slot INTEGER NOT NULL DEFAULT 0, selected_slice_index INTEGER"
            : ""
        let core = """
            CREATE TABLE binaries (
              id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE,
              workspace_id INTEGER NOT NULL REFERENCES workspaces(id),
              name TEXT NOT NULL, path TEXT NOT NULL, original_path_bookmark BLOB,
              kind TEXT NOT NULL, architecture TEXT NOT NULL, file_hash TEXT NOT NULL,
              file_size INTEGER NOT NULL, hex_bytes BLOB, is_bundle INTEGER NOT NULL DEFAULT 0
              \(binaryImageIdentityColumns)
            );
            CREATE TABLE functions (
              id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE,
              binary_id INTEGER NOT NULL, start_address INTEGER NOT NULL,
              end_address INTEGER, symbol_name TEXT, demangled_name TEXT,
              confidence REAL NOT NULL DEFAULT 0.0
            );
            CREATE TABLE instructions (
              id INTEGER PRIMARY KEY, function_id INTEGER NOT NULL,
              address INTEGER NOT NULL, bytes BLOB NOT NULL,
              mnemonic TEXT NOT NULL, operands TEXT NOT NULL,
              has_breakpoint INTEGER NOT NULL DEFAULT 0, comment TEXT, ir_json BLOB
            );
            CREATE TABLE symbols (
              id INTEGER PRIMARY KEY, uuid TEXT NOT NULL UNIQUE,
              binary_id INTEGER NOT NULL, name TEXT NOT NULL, address INTEGER,
              kind TEXT NOT NULL, library_name TEXT
            );
            CREATE TABLE workspace_sessions (id INTEGER PRIMARY KEY);
            CREATE TABLE basic_blocks (id INTEGER PRIMARY KEY);
            CREATE TABLE control_flow_edges (id INTEGER PRIMARY KEY);
            CREATE TABLE exports (id INTEGER PRIMARY KEY);
            CREATE TABLE imports (id INTEGER PRIMARY KEY);
            CREATE TABLE indirect_symbols (id INTEGER PRIMARY KEY);
            CREATE TABLE plugin_external_runs (id INTEGER PRIMARY KEY);
            CREATE TABLE plugin_trust_decisions (id INTEGER PRIMARY KEY);
            CREATE TABLE string_literals (id INTEGER PRIMARY KEY);
            CREATE TABLE xrefs (id INTEGER PRIMARY KEY);
            """
        let sourceLines = version == 29
            ? """
              CREATE TABLE source_lines (
                id INTEGER PRIMARY KEY,
                binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
                address INTEGER NOT NULL,
                file TEXT,
                line INTEGER NOT NULL,
                column INTEGER NOT NULL,
                is_end_sequence INTEGER NOT NULL DEFAULT 0
              );
              CREATE INDEX idx_source_lines_binary_id ON source_lines(binary_id);
              """
            : ""

        if version == 8 { return workspace + core + stamp }

        if (9...11).contains(version) {
            let document = """
                CREATE TABLE workspace_documents (
                  workspace_id INTEGER PRIMARY KEY,
                  document_id TEXT NOT NULL,
                  package_path TEXT NOT NULL,
                  last_opened_at TEXT NOT NULL,
                  last_saved_at TEXT,
                  is_dirty INTEGER NOT NULL DEFAULT 0
                );
                """
            let autosave = version == 11
                ? """
                  CREATE TABLE workspace_document_autosave_decisions (
                    id INTEGER PRIMARY KEY,
                    uuid TEXT NOT NULL UNIQUE,
                    workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                    document_id TEXT NOT NULL,
                    package_path TEXT NOT NULL,
                    decision TEXT NOT NULL,
                    reason TEXT,
                    file_version_identifier TEXT,
                    decided_at TEXT NOT NULL,
                    completed_at TEXT,
                    error_message TEXT
                  );
                  """
                : ""
            return workspace + core + document + autosave + stamp
        }

        if (13...25).contains(version) {
            return workspace + core + addressOverrides + stamp
        }
        return workspace + core + sourceLines + (version >= 26 ? addressOverrides : "") + stamp
    }

    private func legacySnapshotWithSameAddressBreakpoints(
        address: UInt64 = 0x1_0000_1000
    ) -> WorkspaceSnapshot {
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let firstSlot = ImageSlot.primary
        let secondSlot = ImageSlot(rawValue: 1)
        let first = BinaryImage(
            id: firstID,
            name: "First",
            path: "/tmp/First",
            kind: "ELF",
            architecture: "arm64",
            slot: firstSlot
        )
        let second = BinaryImage(
            id: secondID,
            name: "Second",
            path: "/tmp/Second",
            kind: "ELF",
            architecture: "arm64",
            slot: secondSlot
        )
        func analysis(_ suffix: String) -> ImageAnalysis {
            ImageAnalysis(
                functions: [
                    FunctionSummary(
                        id: UUID(),
                        name: "_legacy_\(suffix)",
                        startAddress: address,
                        endAddress: address + 4,
                        confidence: 1
                    ),
                ],
                instructions: [
                    InstructionRow(
                        address: address,
                        bytes: "c0 03 5f d6",
                        mnemonic: "ret",
                        operands: "",
                        hasBreakpoint: true
                    ),
                ]
            )
        }
        return WorkspaceSnapshot(
            binaries: [first, second],
            analysisBySlot: [firstSlot: analysis("first"), secondSlot: analysis("second")]
        )
    }

    private static func preferredAddress(
        _ specification: DebuggerLogicalBreakpointSpecification
    ) -> UInt64? {
        guard case .preferredAddress(_, let preferredVA) = specification.target else { return nil }
        return preferredVA
    }

    private static func ownerBinaryID(
        _ specification: DebuggerLogicalBreakpointSpecification
    ) -> UUID? {
        guard case .preferredAddress(let owner, _) = specification.target else { return nil }
        return owner.binaryID
    }

    private func expressionLabel(
        in catalog: DebuggerLogicalBreakpointCatalog
    ) -> String? {
        guard let action = catalog.specifications.first?.actions.first,
              case .evaluateTargetExpression(let expression) = action
        else { return nil }
        return expression.label
    }

    private func replacingFirst(
        _ needle: String,
        with replacement: String,
        in value: String
    ) throws -> String {
        let range = try XCTUnwrap(value.range(of: needle))
        var result = value
        result.replaceSubrange(range, with: replacement)
        return result
    }

    private func duplicatingJSONObjectMember(named name: String, in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let key = [UInt8]("\"\(name)\"".utf8)
        guard let keyStart = bytes.indices.first(where: { start in
            start + key.count <= bytes.count
                && bytes[start..<(start + key.count)].elementsEqual(key)
        }) else {
            throw XCTSkip("Missing JSON member \(name)")
        }
        var valueStart = keyStart + key.count
        while valueStart < bytes.count, bytes[valueStart] != 0x3A { valueStart += 1 }
        valueStart += 1
        while valueStart < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[valueStart]) {
            valueStart += 1
        }
        guard valueStart < bytes.count, bytes[valueStart] == 0x7B else {
            throw XCTSkip("JSON member \(name) is not an object")
        }
        var cursor = valueStart
        var depth = 0
        var inString = false
        var escaped = false
        while cursor < bytes.count {
            let byte = bytes[cursor]
            cursor += 1
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
                continue
            }
            if byte == 0x22 { inString = true }
            else if byte == 0x7B { depth += 1 }
            else if byte == 0x7D {
                depth -= 1
                if depth == 0 { break }
            }
        }
        guard depth == 0 else { throw XCTSkip("Unterminated JSON member \(name)") }
        let member = bytes[keyStart..<cursor]
        var result = Data(bytes[..<keyStart])
        result.append(contentsOf: member)
        result.append(0x2C)
        result.append(contentsOf: member)
        result.append(contentsOf: bytes[cursor...])
        return result
    }
}
