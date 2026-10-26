import XCTest
@testable import MacScope

@MainActor
final class DebuggerWorkspaceArtifactCatalogStoreTests: XCTestCase {
    private let primaryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondaryID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let secondarySlot = ImageSlot(rawValue: 1)

    func testInitialCatalogCoversEveryImageAndNormalizesPathHints() throws {
        let store = try makeStore()
        let catalog = store.debuggerWorkspaceArtifactCatalog

        XCTAssertEqual(catalog.revision, .init(rawValue: 1))
        XCTAssertEqual(catalog.artifacts.map(\.binaryID), [primaryID, secondaryID])
        XCTAssertEqual(catalog.artifacts.map(\.slot), [.primary, secondarySlot])
        XCTAssertEqual(catalog.artifacts.map(\.ownerRevision), [
            .init(rawValue: 1),
            .init(rawValue: 1),
        ])
        XCTAssertEqual(catalog.artifacts[0].sourcePathHint, "/tmp/Primary")
        XCTAssertEqual(catalog.artifacts[0].executablePathHint, "/Applications/Primary.app/Contents/MacOS/Primary")
        XCTAssertEqual(catalog.artifacts[0].artifactIntegrityState, .verified)
        XCTAssertNotNil(catalog.artifacts[0].artifactIdentity)
        XCTAssertNotNil(catalog.artifacts[0].preferredSegmentLayout)
    }

    func testFocusAndAnalysisOnlyChangesDoNotAdvanceCatalog() throws {
        let store = try makeStore()
        let initial = store.debuggerWorkspaceArtifactCatalog

        store.focusImage(secondarySlot)
        XCTAssertEqual(store.debuggerWorkspaceArtifactCatalog, initial)

        store.snapshot.mutateAnalysis(in: .primary) {
            $0.diagnostics.append(
                AnalysisDiagnostic(
                    severity: .warning,
                    address: 0x1000,
                    kind: .loaderTruncation,
                    message: "Catalog-irrelevant analysis output"
                )
            )
        }
        XCTAssertEqual(store.debuggerWorkspaceArtifactCatalog, initial)
    }

    func testPathOnlyPublicationChangeAdvancesCatalogButNotOwner() throws {
        let store = try makeStore()
        let initial = store.debuggerWorkspaceArtifactCatalog
        let initialOwners = owners(in: initial)

        store.snapshot.binaries[0].path = "/tmp/Primary-v2"
        let changed = store.debuggerWorkspaceArtifactCatalog
        let changedOwners = owners(in: changed)

        XCTAssertEqual(changed.revision, .init(rawValue: 2))
        XCTAssertEqual(changedOwners[primaryID], initialOwners[primaryID])
        XCTAssertEqual(changedOwners[secondaryID], initialOwners[secondaryID])
        XCTAssertEqual(changed.artifacts.first(where: { $0.binaryID == primaryID })?.sourcePathHint, "/tmp/Primary-v2")
    }

    func testSameSlotOwnerReplacementAdvancesCatalogAndRemintsOwnerAuthority() throws {
        let store = try makeStore()
        let initial = store.debuggerWorkspaceArtifactCatalog
        let replacementID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var replacement = try image(
            id: replacementID,
            slot: .primary,
            name: "Replacement"
        )
        replacement.path = "/tmp/Replacement"
        store.snapshot.binaries[0] = replacement

        let changed = store.debuggerWorkspaceArtifactCatalog
        XCTAssertEqual(changed.revision, .init(rawValue: 2))
        XCTAssertNil(changed.artifacts.first(where: { $0.binaryID == primaryID }))
        XCTAssertEqual(
            changed.artifacts.first(where: { $0.binaryID == replacementID })?.ownerRevision,
            initial.artifacts.first(where: { $0.binaryID == primaryID })?.ownerRevision.incremented()
        )
    }

    func testWholeWorkspaceRestoreRemintsAllOwnersEvenWhenIdentifiersRepeat() throws {
        let store = try makeStore()
        let initial = store.debuggerWorkspaceArtifactCatalog
        let persisted = WorkspaceDatabase.PersistedWorkspace(
            workspace: .init(
                id: 1,
                uuid: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
                name: "Restored",
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            ),
            snapshot: store.snapshot,
            session: .init(
                workspaceID: 1,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                updatedAt: Date(timeIntervalSince1970: 2),
                focusedImageSlot: .primary
            )
        )

        store.restoreWorkspace(persisted)
        let restored = store.debuggerWorkspaceArtifactCatalog

        XCTAssertEqual(restored.revision, initial.revision.incremented())
        for binaryID in [primaryID, secondaryID] {
            XCTAssertEqual(
                owners(in: restored)[binaryID],
                owners(in: initial)[binaryID]?.incremented()
            )
        }
    }

    func testSlotRemapAdvancesCatalogAndAffectedOwnerOnly() throws {
        let store = try makeStore()
        let initial = store.debuggerWorkspaceArtifactCatalog
        let destination = ImageSlot(rawValue: 4)

        store.remapImageSlot(from: secondarySlot, to: destination)
        let remapped = store.debuggerWorkspaceArtifactCatalog

        XCTAssertEqual(remapped.revision, initial.revision.incremented())
        XCTAssertEqual(
            remapped.artifacts.first(where: { $0.binaryID == secondaryID })?.ownerRevision,
            owners(in: initial)[secondaryID]?.incremented()
        )
        XCTAssertEqual(
            remapped.artifacts.first(where: { $0.binaryID == secondaryID })?.slot,
            destination
        )
        XCTAssertEqual(
            remapped.artifacts.first(where: { $0.binaryID == primaryID })?.ownerRevision,
            owners(in: initial)[primaryID]
        )
    }

    func testRevisionOverflowFailsClosedWithoutWrapping() throws {
        let snapshot = try makeSnapshot()
        var ledger = DebuggerWorkspaceArtifactCatalogLedger(
            snapshot: snapshot,
            catalogRevision: .init(rawValue: .max - 1),
            initialOwnerRevision: .init(rawValue: .max - 1)
        )
        var firstChange = snapshot
        firstChange.binaries[0].path = "/tmp/Primary-at-max"

        let failedClosed = ledger.reconcile(snapshot: firstChange)
        XCTAssertEqual(failedClosed.revision, .init(rawValue: .max))
        XCTAssertTrue(failedClosed.artifacts.isEmpty)
        XCTAssertTrue(ledger.isExhausted)
        XCTAssertEqual(ledger.reconcile(snapshot: snapshot), failedClosed)
    }

    func testRetiredOwnerHighWaterPreventsABARemint() throws {
        let original = try image(id: primaryID, slot: .primary, name: "Primary")
        var ledger = DebuggerWorkspaceArtifactCatalogLedger(
            snapshot: WorkspaceSnapshot(binaries: [original], analysisBySlot: [.primary: ImageAnalysis()])
        )
        let replacementID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let replacement = try image(id: replacementID, slot: .primary, name: "Replacement")

        let replacementCatalog = ledger.reconcile(
            snapshot: WorkspaceSnapshot(binaries: [replacement], analysisBySlot: [.primary: ImageAnalysis()])
        )
        XCTAssertEqual(replacementCatalog.artifacts.first?.ownerRevision, .init(rawValue: 2))

        let restoredCatalog = ledger.reconcile(
            snapshot: WorkspaceSnapshot(binaries: [original], analysisBySlot: [.primary: ImageAnalysis()])
        )
        XCTAssertEqual(restoredCatalog.artifacts.first?.ownerRevision, .init(rawValue: 3))
    }

    func testDuplicateBinaryIDFailsClosedTerminally() throws {
        var duplicate = try makeSnapshot()
        duplicate.binaries[1] = try image(
            id: duplicate.binaries[0].id,
            slot: secondarySlot,
            name: "DuplicateID"
        )
        var ledger = DebuggerWorkspaceArtifactCatalogLedger(snapshot: duplicate)

        XCTAssertEqual(ledger.catalog.revision, .init(rawValue: .max))
        XCTAssertTrue(ledger.catalog.artifacts.isEmpty)
        XCTAssertTrue(ledger.isExhausted)
        XCTAssertEqual(ledger.reconcile(snapshot: try makeSnapshot()), ledger.catalog)
    }

    func testDuplicateSlotFailsClosedTerminally() throws {
        var duplicate = try makeSnapshot()
        duplicate.binaries[1].slot = .primary
        var ledger = DebuggerWorkspaceArtifactCatalogLedger(snapshot: duplicate)

        XCTAssertEqual(ledger.catalog.revision, .init(rawValue: .max))
        XCTAssertTrue(ledger.catalog.artifacts.isEmpty)
        XCTAssertTrue(ledger.isExhausted)
        XCTAssertEqual(ledger.reconcile(snapshot: try makeSnapshot()), ledger.catalog)
    }

    private func makeStore() throws -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "Catalog",
            snapshot: try makeSnapshot(),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    private func makeSnapshot() throws -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [
                try image(id: primaryID, slot: .primary, name: "Primary"),
                try image(id: secondaryID, slot: secondarySlot, name: "Secondary"),
            ],
            analysisBySlot: [
                .primary: ImageAnalysis(),
                secondarySlot: ImageAnalysis(),
            ]
        )
    }

    private func image(
        id: UUID,
        slot: ImageSlot,
        name: String
    ) throws -> BinaryImage {
        let identity = try MachOSliceArtifactIdentity(
            uuid: id,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: slot == .primary ? "a" : "b", count: 64),
            selectedSliceByteCount: 0x4000
        )
        let layout = try MachOPreferredSegmentLayout(
            records: [
                .init(
                    name: "__TEXT",
                    preferredVMStart: 0x1000_0000,
                    preferredVMSize: 0x2000,
                    sliceRelativeFileOffset: 0,
                    fileSize: 0x2000,
                    initialProtections: 5
                )
            ],
            selectedSliceByteCount: identity.selectedSliceByteCount
        )
        return BinaryImage(
            id: id,
            name: name,
            path: "/tmp/one/../\(name)",
            kind: "executable",
            architecture: "arm64",
            artifactIdentity: identity,
            preferredSegmentLayout: layout,
            artifactIntegrityState: .verified,
            resolvedExecutablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
            slot: slot
        )
    }

    private func owners(
        in catalog: DebuggerWorkspaceArtifactCatalog
    ) -> [UUID: DebuggerWorkspaceArtifactOwnerRevision] {
        Dictionary(uniqueKeysWithValues: catalog.artifacts.map { ($0.binaryID, $0.ownerRevision) })
    }
}
