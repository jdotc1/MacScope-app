import XCTest
@testable import MacScope

@MainActor
final class DebuggerLaunchProfileStoreTests: XCTestCase {
    private let catalogID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let firstID = DebuggerLaunchProfileID(
        rawValue: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    )
    private let secondID = DebuggerLaunchProfileID(
        rawValue: UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    )

    func testCreateEditRenameSelectAndNoOpsAdvanceExactlyOnce() throws {
        let trigger = ManualAutosaveTrigger()
        let store = makeStore(autosaveScheduler: trigger)

        let created = try store.createLaunchProfile(
            draft: draft(name: "Primary", arguments: ["--first"]),
            id: firstID
        )

        XCTAssertEqual(created.id, firstID)
        XCTAssertEqual(created.revision, 2)
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 2)
        XCTAssertEqual(store.launchProfiles.map(\.id), [firstID])
        XCTAssertEqual(store.selectedLaunchProfile?.id, firstID)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(trigger.scheduleCount, 1)

        XCTAssertFalse(try store.editLaunchProfile(id: firstID, draft: WorkspaceLaunchProfileDraft(created)))
        XCTAssertFalse(try store.renameLaunchProfile(id: firstID, name: "Primary"))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 2)
        XCTAssertEqual(trigger.scheduleCount, 1)

        XCTAssertTrue(try store.renameLaunchProfile(id: firstID, name: "Renamed"))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 3)
        XCTAssertEqual(store.launchProfile(id: firstID)?.revision, 3)
        XCTAssertEqual(store.launchProfile(id: firstID)?.name, "Renamed")

        XCTAssertTrue(try store.selectLaunchProfile(nil))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 4)
        XCTAssertNil(store.selectedLaunchProfile)
        XCTAssertTrue(try store.selectLaunchProfile(firstID))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 5)
        XCTAssertEqual(store.selectedLaunchProfile?.id, firstID)
        XCTAssertEqual(store.launchProfile(id: firstID)?.revision, 3)
        XCTAssertFalse(try store.selectLaunchProfile(firstID))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 5)
    }

    func testCanonicallyEquivalentButByteDistinctRenameIsEffective() throws {
        let decomposed = "e\u{301} profile"
        let composed = "\u{e9} profile"
        XCTAssertEqual(decomposed, composed)
        XCTAssertNotEqual(Data(decomposed.utf8), Data(composed.utf8))
        let profile = try makeProfile(id: firstID, revision: 4, name: decomposed)
        let store = makeStore(catalog: try catalog(revision: 4, profiles: [profile]))

        XCTAssertTrue(try store.renameLaunchProfile(id: firstID, name: composed))

        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 5)
        XCTAssertEqual(
            Data(try XCTUnwrap(store.launchProfile(id: firstID)?.name).utf8),
            Data(composed.utf8)
        )
    }

    func testWorkspaceImageUpsertsRequireExactCurrentBinaryAndArtifactOwner() throws {
        let binaryID = UUID()
        let artifact = artifactIdentity(shaByte: "a")
        let mismatch = artifactIdentity(shaByte: "b")
        let store = makeWorkspaceImageStore(binaryID: binaryID, artifact: artifact)
        let before = store.snapshot.launchProfileCatalog
        let invalidOwners = [
            DebuggerWorkspaceImageOwnerSeal(
                slot: ImageSlot(rawValue: 7), binaryID: binaryID, artifactIdentity: artifact
            ),
            DebuggerWorkspaceImageOwnerSeal(
                slot: .primary, binaryID: UUID(), artifactIdentity: artifact
            ),
            DebuggerWorkspaceImageOwnerSeal(
                slot: .primary, binaryID: binaryID, artifactIdentity: nil
            ),
            DebuggerWorkspaceImageOwnerSeal(
                slot: .primary, binaryID: binaryID, artifactIdentity: mismatch
            ),
        ]

        for owner in invalidOwners {
            XCTAssertThrowsError(
                try store.createLaunchProfile(
                    draft: workspaceImageDraft(name: "Invalid", owner: owner)
                )
            ) { error in
                XCTAssertEqual(error as? DebuggerLaunchProfileValidationError, .invalidWorkspaceOwner)
            }
            XCTAssertEqual(store.snapshot.launchProfileCatalog, before)
            XCTAssertFalse(store.isDirty)
            XCTAssertFalse(store.undoManager.canUndo)
        }

        let missingPersistedArtifact = makeWorkspaceImageStore(
            binaryID: binaryID,
            artifact: nil
        )
        XCTAssertThrowsError(
            try missingPersistedArtifact.createLaunchProfile(
                draft: workspaceImageDraft(
                    name: "Missing persisted seal",
                    owner: .init(
                        slot: .primary,
                        binaryID: binaryID,
                        artifactIdentity: artifact
                    )
                )
            )
        ) { error in
            XCTAssertEqual(error as? DebuggerLaunchProfileValidationError, .invalidWorkspaceOwner)
        }
        XCTAssertTrue(missingPersistedArtifact.snapshot.launchProfileCatalog.isPristine)
        XCTAssertFalse(missingPersistedArtifact.isDirty)
    }

    func testUndoRefusesStaleWorkspaceOwnerWithoutPartialMutation() throws {
        let binaryID = UUID()
        let originalArtifact = artifactIdentity(shaByte: "a")
        let replacementArtifact = artifactIdentity(shaByte: "b")
        let owner = DebuggerWorkspaceImageOwnerSeal(
            slot: .primary,
            binaryID: binaryID,
            artifactIdentity: originalArtifact
        )
        let original = try workspaceImageDraft(name: "Original", owner: owner)
            .profile(id: firstID, revision: 1)
        let catalog = try DebuggerLaunchProfileCatalog(
            catalogID: catalogID,
            revision: 1,
            profiles: [original],
            selectedProfileID: firstID
        )
        let store = makeWorkspaceImageStore(
            binaryID: binaryID,
            artifact: originalArtifact,
            catalog: catalog
        )
        XCTAssertTrue(try store.renameLaunchProfile(id: firstID, name: "Edited"))
        var replaced = store.snapshot
        replaced.binaries[0].artifactIdentity = replacementArtifact
        store.snapshot = replaced
        let beforeUndo = store.snapshot.launchProfileCatalog

        store.undoManager.undo()

        XCTAssertEqual(store.snapshot.launchProfileCatalog, beforeUndo)
        XCTAssertEqual(store.launchProfile(id: firstID)?.name, "Edited")
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(
            store.lastIssue,
            DebuggerLaunchProfileValidationError.invalidWorkspaceOwner.localizedDescription
        )
    }

    func testDuplicatePreservesOrderAndUnaffectedRevisions() throws {
        let first = try makeProfile(id: firstID, revision: 5, name: "First")
        let second = try makeProfile(id: secondID, revision: 3, name: "Second")
        let duplicateID = DebuggerLaunchProfileID(rawValue: UUID())
        let store = makeStore(catalog: try catalog(revision: 5, profiles: [first, second]))

        let duplicate = try store.duplicateLaunchProfile(
            firstID,
            name: "First Copy",
            id: duplicateID
        )

        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 6)
        XCTAssertEqual(store.launchProfiles.map(\.id), [firstID, duplicateID, secondID])
        XCTAssertEqual(duplicate.revision, 6)
        XCTAssertEqual(duplicate.name, "First Copy")
        XCTAssertEqual(store.selectedLaunchProfile?.id, duplicateID)
        XCTAssertEqual(store.launchProfile(id: firstID)?.revision, 5)
        XCTAssertEqual(store.launchProfile(id: secondID)?.revision, 3)
    }

    func testFullEditReplacesAuthoredFieldsAndRetainsOrder() throws {
        let first = try makeProfile(id: firstID, revision: 7, name: "First")
        let second = try makeProfile(id: secondID, revision: 2, name: "Second")
        let store = makeStore(catalog: try catalog(revision: 7, profiles: [first, second]))
        let environment = [
            try DebuggerLaunchProfileEnvironmentEntry(key: "B", value: "2"),
            try DebuggerLaunchProfileEnvironmentEntry(key: "A", value: "1"),
        ]
        let edited = WorkspaceLaunchProfileDraft(
            name: "Edited",
            target: .importedExecutable(importedSeal(path: "/tmp/edited")),
            arguments: ["--flag", ""],
            environment: environment,
            workingDirectory: "/tmp",
            standardIOPolicy: .inheritNoCapture
        )

        XCTAssertTrue(try store.editLaunchProfile(id: firstID, draft: edited))

        let profile = try XCTUnwrap(store.launchProfile(id: firstID))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 8)
        XCTAssertEqual(store.launchProfiles.map(\.id), [firstID, secondID])
        XCTAssertEqual(profile.revision, 8)
        XCTAssertEqual(profile.name, "Edited")
        XCTAssertEqual(profile.target, edited.target)
        XCTAssertEqual(profile.arguments, ["--flag", ""])
        XCTAssertEqual(profile.environment.map(\.key), ["A", "B"])
        XCTAssertEqual(profile.workingDirectory, "/tmp")
        XCTAssertEqual(profile.standardIOPolicy, .inheritNoCapture)
        XCTAssertEqual(store.launchProfile(id: secondID)?.revision, 2)
    }

    func testSelectionClearAndMissingSelectionBehavior() throws {
        let profile = try makeProfile(id: firstID, revision: 2, name: "First")
        let store = makeStore(
            catalog: try catalog(revision: 2, profiles: [profile], selected: firstID)
        )
        let missing = DebuggerLaunchProfileID(rawValue: UUID())

        XCTAssertFalse(try store.selectLaunchProfile(missing))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 2)
        XCTAssertEqual(store.selectedLaunchProfile?.id, firstID)

        XCTAssertTrue(try store.selectLaunchProfile(nil))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 3)
        XCTAssertNil(store.selectedLaunchProfile)
        XCTAssertEqual(store.launchProfile(id: firstID)?.revision, 2)
        XCTAssertFalse(try store.selectLaunchProfile(nil))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 3)
    }

    func testMaximumRevisionExactNoOpsAndMissingTargetsRemainNoOps() throws {
        let maximum = UInt64(Int64.max)
        let profile = try makeProfile(id: firstID, revision: maximum, name: "At Maximum")
        let store = makeStore(
            catalog: try catalog(
                revision: maximum,
                profiles: [profile],
                selected: firstID
            )
        )
        let missing = DebuggerLaunchProfileID(rawValue: UUID())
        let before = store.snapshot.launchProfileCatalog

        XCTAssertFalse(
            try store.editLaunchProfile(
                id: firstID,
                draft: WorkspaceLaunchProfileDraft(profile)
            )
        )
        XCTAssertFalse(try store.renameLaunchProfile(id: firstID, name: "At Maximum"))
        XCTAssertFalse(try store.selectLaunchProfile(firstID))
        XCTAssertFalse(try store.selectLaunchProfile(missing))
        XCTAssertFalse(
            try store.editLaunchProfile(
                id: missing,
                draft: draft(name: "Missing")
            )
        )
        XCTAssertFalse(try store.renameLaunchProfile(id: missing, name: "Missing"))
        XCTAssertFalse(try store.deleteLaunchProfile(missing))

        XCTAssertEqual(store.snapshot.launchProfileCatalog, before)
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(store.undoManager.canUndo)
    }

    func testMaximumRevisionEffectiveMutationsFailWithoutPartialState() throws {
        let maximum = UInt64(Int64.max)
        let profile = try makeProfile(id: firstID, revision: maximum, name: "At Maximum")
        let store = makeStore(
            catalog: try catalog(
                revision: maximum,
                profiles: [profile],
                selected: firstID
            )
        )
        let before = store.snapshot.launchProfileCatalog

        let mutations: [() throws -> Void] = [
            { _ = try store.renameLaunchProfile(id: self.firstID, name: "Changed") },
            { _ = try store.selectLaunchProfile(nil) },
            { _ = try store.deleteLaunchProfile(self.firstID) },
            {
                _ = try store.createLaunchProfile(
                    draft: self.draft(name: "New"),
                    id: self.secondID
                )
            },
            {
                _ = try store.duplicateLaunchProfile(
                    self.firstID,
                    name: "Copy",
                    id: self.secondID
                )
            },
        ]

        for mutation in mutations {
            XCTAssertThrowsError(try mutation()) { error in
                XCTAssertEqual(error as? DebuggerLaunchProfileValidationError, .invalidRevision)
            }
            XCTAssertEqual(store.snapshot.launchProfileCatalog, before)
            XCTAssertFalse(store.isDirty)
            XCTAssertFalse(store.undoManager.canUndo)
        }
    }

    func testDeleteFinalProfileLeavesSameCatalogIdentityTombstone() throws {
        let profile = try makeProfile(id: firstID, revision: 1, name: "Only")
        let store = makeStore(
            catalog: try catalog(revision: 1, profiles: [profile], selected: firstID)
        )

        XCTAssertTrue(try store.deleteLaunchProfile(firstID))

        XCTAssertEqual(store.snapshot.launchProfileCatalog.catalogID, catalogID)
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 2)
        XCTAssertTrue(store.launchProfiles.isEmpty)
        XCTAssertNil(store.selectedLaunchProfile)
        XCTAssertFalse(store.snapshot.launchProfileCatalog.isPristine)
    }

    func testUndoRedoUsesInverseIntentAndMonotonicRevisions() throws {
        let store = makeStore()
        let created = try store.createLaunchProfile(
            draft: draft(name: "Undoable"),
            id: firstID
        )

        store.undoManager.undo()

        XCTAssertNil(store.launchProfile(id: created.id))
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 3)
        XCTAssertFalse(store.isDirty)

        store.undoManager.redo()

        XCTAssertEqual(store.launchProfile(id: created.id)?.revision, 4)
        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 4)
        XCTAssertTrue(store.isDirty)
    }

    func testUndoDeleteRestoresExactOrderAndSelectionAtNewRevision() throws {
        let first = try makeProfile(id: firstID, revision: 4, name: "First")
        let second = try makeProfile(id: secondID, revision: 4, name: "Second")
        let store = makeStore(
            catalog: try catalog(revision: 4, profiles: [first, second], selected: firstID)
        )

        XCTAssertTrue(try store.deleteLaunchProfile(firstID))
        XCTAssertEqual(store.launchProfiles.map(\.id), [secondID])
        XCTAssertNil(store.selectedLaunchProfile)

        store.undoManager.undo()

        XCTAssertEqual(store.snapshot.launchProfileCatalog.revision, 6)
        XCTAssertEqual(store.launchProfiles.map(\.id), [firstID, secondID])
        XCTAssertEqual(store.launchProfile(id: firstID)?.revision, 6)
        XCTAssertEqual(store.launchProfile(id: secondID)?.revision, 4)
        XCTAssertEqual(store.selectedLaunchProfile?.id, firstID)
    }

    func testUnavailableCatalogBlocksAuthoringAndAutosaveUntilConfirmedDiscard() throws {
        let logicalID = snapshotLogicalCatalogID()
        let trigger = ManualAutosaveTrigger()
        let store = makeStore(
            availability: .unavailable,
            autosaveScheduler: trigger
        )
        let before = store.snapshot.launchProfileCatalog

        XCTAssertThrowsError(
            try store.createLaunchProfile(draft: draft(name: "Blocked"), id: firstID)
        ) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileCatalogUnavailable)
        }
        XCTAssertEqual(store.snapshot.launchProfileCatalog, before)
        XCTAssertEqual(store.autosaveDecision, .skipConflict)
        let database = try WorkspaceDatabase.inMemory()
        XCTAssertThrowsError(try store.saveWorkspace(to: database)) { error in
            XCTAssertEqual(error as? WorkspaceDatabase.DatabaseError, .launchProfileCatalogUnavailable)
        }
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocked-launch-\(UUID().uuidString).mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        XCTAssertFalse(store.writeDocumentPackage(to: packageURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: packageURL.path))
        XCTAssertFalse(store.discardCorruptLaunchProfileCatalog(confirmed: false))
        XCTAssertEqual(store.launchProfileCatalogAvailability, .unavailable)
        XCTAssertFalse(store.isDirty)

        XCTAssertTrue(store.discardCorruptLaunchProfileCatalog(confirmed: true))

        XCTAssertEqual(store.launchProfileCatalogAvailability, .available)
        XCTAssertNotEqual(store.snapshot.launchProfileCatalog.catalogID, before.catalogID)
        XCTAssertTrue(store.snapshot.launchProfileCatalog.isPristine)
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.catalogID, logicalID)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(trigger.scheduleCount, 1)
    }

    func testRepairingLaunchConflictDoesNotClearLogicalConflict() {
        let store = makeStore(
            logicalAvailability: .unavailable,
            availability: .unavailable
        )

        XCTAssertTrue(store.discardCorruptLaunchProfileCatalog(confirmed: true))

        XCTAssertEqual(store.launchProfileCatalogAvailability, .available)
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .unavailable)
        XCTAssertEqual(store.autosaveDecision, .skipConflict)
        XCTAssertEqual(store.catalogPersistenceConflictError, .logicalBreakpointCatalogUnavailable)
    }

    func testRepairingLogicalConflictDoesNotClearLaunchConflict() {
        let launchCatalogID = catalogID
        let store = makeStore(
            logicalAvailability: .unavailable,
            availability: .unavailable
        )

        XCTAssertTrue(store.discardCorruptLogicalBreakpointCatalog(confirmed: true))

        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .available)
        XCTAssertEqual(store.launchProfileCatalogAvailability, .unavailable)
        XCTAssertEqual(store.snapshot.launchProfileCatalog.catalogID, launchCatalogID)
        XCTAssertEqual(store.catalogPersistenceConflictError, .launchProfileCatalogUnavailable)
        XCTAssertEqual(store.autosaveDecision, .skipConflict)
    }

    func testInitializerAndFreshImportAvailabilityAreIndependent() async throws {
        let replacement = WorkspaceSnapshot(
            binaries: [],
            analysisBySlot: [:],
            launchProfileCatalog: .freshPristine(catalogID: UUID())
        )
        let store = makeStore(
            logicalAvailability: .available,
            availability: .unavailable,
            engine: ImmediateLaunchProfileImportProvider(snapshot: replacement)
        )
        XCTAssertEqual(store.launchProfileCatalogAvailability, .unavailable)
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .available)

        await store.importBinary(url: URL(fileURLWithPath: "/tmp/ws22-launch-profile-import"))
        XCTAssertEqual(store.launchProfileCatalogAvailability, .available)
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .available)
        XCTAssertEqual(store.snapshot.launchProfileCatalog.catalogID, replacement.launchProfileCatalog.catalogID)
        XCTAssertTrue(store.snapshot.launchProfileCatalog.isPristine)
    }

    func testDatabaseRestorePropagatesLaunchAvailabilityIndependently() {
        let store = makeStore()
        let restoredCatalog = DebuggerLaunchProfileCatalog.freshPristine(catalogID: UUID())
        let persisted = WorkspaceDatabase.PersistedWorkspace(
            workspace: .init(
                id: 17,
                uuid: UUID(),
                name: "Restored",
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            ),
            snapshot: WorkspaceSnapshot(
                binaries: [],
                analysisBySlot: [:],
                launchProfileCatalog: restoredCatalog
            ),
            session: .init(
                workspaceID: 17,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                updatedAt: Date(timeIntervalSince1970: 2)
            ),
            logicalBreakpointCatalogAvailability: .available,
            launchProfileCatalogAvailability: .unavailable
        )

        store.restoreWorkspace(persisted)

        XCTAssertEqual(store.launchProfileCatalogAvailability, .unavailable)
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .available)
        XCTAssertEqual(store.snapshot.launchProfileCatalog.catalogID, restoredCatalog.catalogID)
        XCTAssertEqual(store.autosaveDecision, .skipConflict)
    }

    func testOpenDocumentPackagePreservesLaunchCatalogConflictIssue() throws {
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws22-open-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }
        let payload = """
        {
          "formatIdentifier":"\(MacScopeDocumentPackage.formatIdentifier)",
          "formatVersion":1,
          "documentID":"A0000000-0000-4000-8000-000000000001",
          "workspaceUUID":"A0000000-0000-4000-8000-000000000002",
          "workspaceName":"Corrupt Launch Profiles",
          "createdAt":"1970-01-01T00:00:01Z",
          "modifiedAt":"1970-01-01T00:00:01Z",
          "binaries":[],
          "analysis":{"launchProfileCatalog":"%%%"},
          "session":null
        }
        """
        try Data(payload.utf8).write(to: MacScopeDocumentPackage.manifestURL(in: packageURL))
        let store = makeStore()

        XCTAssertTrue(store.openDocumentPackage(at: packageURL))

        XCTAssertEqual(store.launchProfileCatalogAvailability, .unavailable)
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .available)
        XCTAssertEqual(
            store.lastIssue,
            WorkspaceDatabase.DatabaseError.launchProfileCatalogUnavailable.localizedDescription
        )
    }

    private func makeStore(
        catalog: DebuggerLaunchProfileCatalog? = nil,
        logicalAvailability: DebuggerLogicalBreakpointCatalogAvailability = .available,
        availability: DebuggerLaunchProfileCatalogAvailability = .available,
        autosaveScheduler: AutosaveScheduling? = nil,
        engine: any AnalysisProviding = AnalysisEngine()
    ) -> WorkspaceStore {
        let logicalCatalogID = snapshotLogicalCatalogID()
        let snapshot = WorkspaceSnapshot(
            binaries: [],
            analysisBySlot: [:],
            logicalBreakpointCatalog: .freshPristine(catalogID: logicalCatalogID),
            launchProfileCatalog: catalog ?? .freshPristine(catalogID: catalogID)
        )
        return WorkspaceStore(
            workspaceName: "Launch profiles",
            snapshot: snapshot,
            engine: engine,
            autosaveScheduler: autosaveScheduler,
            logicalBreakpointCatalogAvailability: logicalAvailability,
            launchProfileCatalogAvailability: availability
        )
    }

    private func draft(
        name: String,
        arguments: [String] = []
    ) -> WorkspaceLaunchProfileDraft {
        WorkspaceLaunchProfileDraft(
            name: name,
            target: .importedExecutable(importedSeal()),
            arguments: arguments,
            environment: [],
            workingDirectory: nil,
            standardIOPolicy: .inheritNoCapture
        )
    }

    private func workspaceImageDraft(
        name: String,
        owner: DebuggerWorkspaceImageOwnerSeal
    ) -> WorkspaceLaunchProfileDraft {
        WorkspaceLaunchProfileDraft(
            name: name,
            target: .workspaceImage(owner)
        )
    }

    private func makeWorkspaceImageStore(
        binaryID: UUID,
        artifact: MachOSliceArtifactIdentity?,
        catalog: DebuggerLaunchProfileCatalog? = nil
    ) -> WorkspaceStore {
        let binary = BinaryImage(
            id: binaryID,
            name: "Fixture",
            path: "/tmp/fixture",
            kind: "Mach-O executable",
            architecture: "arm64",
            artifactIdentity: artifact,
            slot: .primary
        )
        let snapshot = WorkspaceSnapshot(
            binaries: [binary],
            analysisBySlot: [.primary: ImageAnalysis()],
            launchProfileCatalog: catalog ?? .freshPristine(catalogID: catalogID)
        )
        return WorkspaceStore(
            workspaceName: "Workspace image profile",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    private func artifactIdentity(shaByte: Character) -> MachOSliceArtifactIdentity {
        try! MachOSliceArtifactIdentity(
            uuid: UUID(),
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: String(shaByte), count: 64),
            selectedSliceByteCount: 0x1000
        )
    }

    private func makeProfile(
        id: DebuggerLaunchProfileID,
        revision: UInt64,
        name: String
    ) throws -> DebuggerLaunchProfile {
        try draft(name: name).profile(id: id, revision: revision)
    }

    private func catalog(
        revision: UInt64,
        profiles: [DebuggerLaunchProfile],
        selected: DebuggerLaunchProfileID? = nil
    ) throws -> DebuggerLaunchProfileCatalog {
        try DebuggerLaunchProfileCatalog(
            catalogID: catalogID,
            revision: revision,
            profiles: profiles,
            selectedProfileID: selected
        )
    }

    private func importedSeal(
        path: String = "/Applications/Fixture.app/Contents/MacOS/Fixture"
    ) -> DebuggerImportedExecutableSeal {
        try! DebuggerImportedExecutableSeal(
            canonicalPath: path,
            deviceID: 1,
            fileID: 2,
            byteCount: 3,
            sha256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: nil
        )
    }

    private func snapshotLogicalCatalogID() -> UUID {
        UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
    }
}

private final class ImmediateLaunchProfileImportProvider: AnalysisProviding, @unchecked Sendable {
    let snapshot: WorkspaceSnapshot

    init(snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        snapshot
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        snapshot
    }
}
