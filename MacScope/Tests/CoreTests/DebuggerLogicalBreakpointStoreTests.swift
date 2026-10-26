import XCTest
@testable import MacScope

@MainActor
final class DebuggerLogicalBreakpointStoreTests: XCTestCase {
    private let address: UInt64 = 0x1_0000_1000
    private let siblingAddress: UInt64 = 0x1_0000_2000
    private let primaryID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let siblingID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    private let catalogID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    private let workspaceID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
    private let siblingSlot = ImageSlot(rawValue: 7)

    func testCreateAdvancesCatalogOnceStampsSpecificationAndDirtiesDocument() throws {
        let store = makeStore()

        let created = try store.createLogicalBreakpoint(
            target: .preferredAddress(owner: owner(slot: .primary, binaryID: primaryID), preferredVA: address)
        )

        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.catalogID, catalogID)
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 2)
        XCTAssertEqual(created.revision.rawValue, 2)
        XCTAssertEqual(store.logicalBreakpoint(id: created.id), created)
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(
            store.logicalBreakpointCatalogCoordinate,
            try DebuggerLogicalBreakpointCatalogCoordinate(
                workspaceID: workspaceID,
                catalogID: catalogID,
                revision: 2
            )
        )
    }

    func testNoOpEditDoesNotAdvanceRevisionDirtyOrUndo() throws {
        let existing = try specification(
            id: id(1),
            revision: 4,
            enabled: true,
            target: .preferredAddress(owner: owner(slot: .primary, binaryID: primaryID), preferredVA: address)
        )
        let store = makeStore(catalog: try catalog(revision: 4, specifications: [existing]))

        XCTAssertFalse(
            try store.editLogicalBreakpoint(
                id: existing.id,
                draft: .init(existing)
            )
        )

        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 4)
        XCTAssertEqual(store.logicalBreakpoint(id: existing.id), existing)
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(store.undoManager.canUndo)
    }

    func testCanonicallyEquivalentButByteDistinctEditAdvancesRevision() throws {
        let decomposed = "e\u{301}"
        let composed = "\u{e9}"
        XCTAssertEqual(decomposed, composed, "the fixture must exercise Swift canonical equivalence")
        XCTAssertNotEqual(Data(decomposed.utf8), Data(composed.utf8))
        let existing = try specification(
            id: id(1),
            revision: 4,
            enabled: true,
            target: .preferredAddress(
                owner: owner(slot: .primary, binaryID: primaryID),
                preferredVA: address
            ),
            condition: decomposed
        )
        let store = makeStore(catalog: try catalog(revision: 4, specifications: [existing]))
        var draft = WorkspaceLogicalBreakpointDraft(existing)
        draft.condition = composed

        XCTAssertTrue(try store.editLogicalBreakpoint(id: existing.id, draft: draft))

        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 5)
        let edited = try XCTUnwrap(store.logicalBreakpoint(id: existing.id))
        XCTAssertEqual(edited.revision.rawValue, 5)
        XCTAssertEqual(Data(try XCTUnwrap(edited.condition).utf8), Data(composed.utf8))
        XCTAssertTrue(store.isDirty)
    }

    func testConditionOnlyEditAdvancesDebuggerCompatibilityRevisionWithoutMovingAddress() throws {
        let existing = try specification(
            id: id(1), revision: 4, enabled: true,
            target: .preferredAddress(
                owner: owner(slot: .primary, binaryID: primaryID),
                preferredVA: address
            ),
            condition: "counter == 1"
        )
        let store = makeStore(catalog: try catalog(revision: 4, specifications: [existing]))
        let before = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        let resolutionCoordinate = before.breakpointResolutionCatalogCoordinate
        var draft = WorkspaceLogicalBreakpointDraft(existing)
        draft.condition = "counter == 2"

        XCTAssertTrue(try store.editLogicalBreakpoint(id: existing.id, draft: draft))

        let after = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(before.gutterBreakpointAddresses, [address])
        XCTAssertEqual(after.gutterBreakpointAddresses, before.gutterBreakpointAddresses)
        XCTAssertEqual(before.breakpointRevision, 4)
        XCTAssertEqual(after.breakpointRevision, 5)
        XCTAssertEqual(store.debuggerBreakpointRevisions[.primary], 5)
        XCTAssertEqual(after.logicalBreakpointCatalogCoordinate.revision, 5)
        XCTAssertEqual(after.logicalBreakpointCatalog, store.snapshot.logicalBreakpointCatalog)
        XCTAssertEqual(after.breakpointResolutionCatalogCoordinate, resolutionCoordinate)
    }

    func testDebuggerWorkspaceInputCarriesCompleteWorkspaceCatalogsAndUnavailableArmsZero() throws {
        let available = makeResolutionStore()
        let input = try XCTUnwrap(available.debuggerWorkspaceInput(in: .primary))

        XCTAssertEqual(input.logicalBreakpointCatalogAvailability, .available)
        XCTAssertEqual(input.logicalBreakpointCatalog, available.snapshot.logicalBreakpointCatalog)
        XCTAssertEqual(input.logicalBreakpointCatalogCoordinate.workspaceID, workspaceID)
        XCTAssertEqual(input.breakpointResolutionCatalogCoordinate.workspaceID, workspaceID)
        XCTAssertEqual(input.breakpointResolutionCatalog.coordinate, input.breakpointResolutionCatalogCoordinate)
        XCTAssertEqual(input.breakpointResolutionCatalog.owners.count, 2)

        let unavailable = makeResolutionStore(availability: .unavailable)
        let unavailableInput = try XCTUnwrap(unavailable.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(unavailableInput.logicalBreakpointCatalogAvailability, .unavailable)
        XCTAssertTrue(unavailableInput.logicalBreakpointCatalog.specifications.isEmpty)
        XCTAssertTrue(unavailableInput.gutterBreakpointAddresses.isEmpty)
        XCTAssertEqual(unavailableInput.breakpointRevision, 0)
    }

    func testResolutionCatalogIgnoresFocusButAdvancesForRelevantReanalysis() throws {
        let store = makeResolutionStore()
        let before = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))

        store.focusImage(siblingSlot)
        XCTAssertTrue(store.selectAddress(.init(slot: siblingSlot, address: siblingAddress)))
        let afterFocus = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(afterFocus.breakpointResolutionCatalogCoordinate, before.breakpointResolutionCatalogCoordinate)
        XCTAssertEqual(afterFocus.breakpointResolutionCatalog, before.breakpointResolutionCatalog)

        var reanalyzed = store.snapshot
        reanalyzed.mutateAnalysis(in: .primary) { analysis in
            analysis.instructions.append(instruction(address + 4, hasBreakpoint: false))
        }
        store.snapshot = reanalyzed

        let afterReanalysis = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(
            afterReanalysis.breakpointResolutionCatalogCoordinate.revision.rawValue,
            before.breakpointResolutionCatalogCoordinate.revision.rawValue + 1
        )
        XCTAssertEqual(
            resolutionOwner(in: afterReanalysis, binaryID: primaryID)?.revision,
            (resolutionOwner(in: before, binaryID: primaryID)?.revision ?? 0) + 1
        )
        XCTAssertEqual(
            resolutionOwner(in: afterReanalysis, binaryID: siblingID)?.revision,
            resolutionOwner(in: before, binaryID: siblingID)?.revision
        )
    }

    func testResolutionCatalogAdvancesForExactSourceArtifactReplacement() throws {
        let store = makeResolutionStore()
        let before = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        var replaced = store.snapshot
        replaced.mutateAnalysis(in: .primary) { analysis in
            analysis.sourceLines[0].debugArtifactMachOSHA256 = String(repeating: "c", count: 64)
        }

        store.snapshot = replaced

        let after = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(
            after.breakpointResolutionCatalogCoordinate.revision.rawValue,
            before.breakpointResolutionCatalogCoordinate.revision.rawValue + 1
        )
        XCTAssertNotEqual(
            resolutionOwner(in: after, binaryID: primaryID)?.sourceRows,
            resolutionOwner(in: before, binaryID: primaryID)?.sourceRows
        )
    }

    func testResolutionCatalogUsesRawLinkageBytesNotDisplayNameOrUnicodeEquality() throws {
        let decomposed = "_e\u{301}ntry"
        let composed = "_\u{e9}ntry"
        XCTAssertEqual(decomposed, composed)
        XCTAssertNotEqual(Data(decomposed.utf8), Data(composed.utf8))
        let store = makeResolutionStore()
        var first = store.snapshot
        first.mutateAnalysis(in: .primary) { analysis in
            analysis.symbols[0].name = "Demangled Display Name"
            analysis.symbols[0].rawLinkageName = decomposed
        }
        store.snapshot = first
        let before = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(
            resolutionOwner(in: before, binaryID: primaryID)?.functions.first?.rawLinkageName,
            decomposed
        )

        var displayOnly = store.snapshot
        displayOnly.mutateAnalysis(in: .primary) { analysis in
            analysis.symbols[0].name = "Another Display Name"
        }
        store.snapshot = displayOnly
        let afterDisplay = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(
            afterDisplay.breakpointResolutionCatalogCoordinate,
            before.breakpointResolutionCatalogCoordinate
        )

        var second = store.snapshot
        second.mutateAnalysis(in: .primary) { analysis in
            analysis.symbols[0].rawLinkageName = composed
        }
        store.snapshot = second

        let after = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(
            after.breakpointResolutionCatalogCoordinate.revision.rawValue,
            afterDisplay.breakpointResolutionCatalogCoordinate.revision.rawValue + 1
        )
        XCTAssertEqual(
            Data(try XCTUnwrap(
                resolutionOwner(in: after, binaryID: primaryID)?.functions.first?.rawLinkageName
            ).utf8),
            Data(composed.utf8)
        )
    }

    func testResolutionCatalogAdvancesForOwnerRemapAndRemoval() throws {
        let store = makeResolutionStore()
        let initial = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        let destination = ImageSlot(rawValue: 11)

        store.remapImageSlot(from: siblingSlot, to: destination)

        let remapped = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(
            remapped.breakpointResolutionCatalogCoordinate.revision.rawValue,
            initial.breakpointResolutionCatalogCoordinate.revision.rawValue + 1
        )
        XCTAssertEqual(resolutionOwner(in: remapped, binaryID: siblingID)?.coordinate.slot, destination)

        var removed = store.snapshot
        removed.removeImage(in: destination)
        store.snapshot = removed

        let afterRemoval = try XCTUnwrap(store.debuggerWorkspaceInput(in: .primary))
        XCTAssertEqual(
            afterRemoval.breakpointResolutionCatalogCoordinate.revision.rawValue,
            remapped.breakpointResolutionCatalogCoordinate.revision.rawValue + 1
        )
        XCTAssertNil(resolutionOwner(in: afterRemoval, binaryID: siblingID))
    }

    func testResolutionLedgerCanonicalEvidenceBytesMatchRetainedEncoder() throws {
        let store = makeResolutionStore()
        let owners = store.debuggerBreakpointResolutionCatalog.owners
        let base = try XCTUnwrap(owners.first)
        let files = try [
            DebuggerCanonicalSourceTablePath.absoluteUTF8("/src/e\u{301}.c"),
            .compilationDirectoryRelativeUTF8("src/\u{e9}.c"),
        ].enumerated().map { index, path in
            try DebuggerCanonicalSourceFileIdentity(
                debugArtifactUUID: UUID(uuidString: "01234567-89ab-cdef-fedc-ba9876543210")!,
                debugArtifactMachOSHA256: String(repeating: index == 0 ? "a" : "b", count: 64),
                debugArtifactMachOByteCount: .max,
                lineProgramUnitOffset: UInt64(index),
                fileTableIndex: .max,
                tablePath: path
            )
        }
        let rich = DebuggerBreakpointResolutionOwnerIndex(
            coordinate: base.coordinate,
            revision: 1,
            segments: [
                try XCTUnwrap(.init(name: "__TEXT", preferredStart: 0, byteCount: 1, isExecutable: true)),
                try XCTUnwrap(.init(name: "\u{e9}", preferredStart: .max - 15, byteCount: 16, isExecutable: false)),
            ],
            staticAddresses: [
                .init(preferredVA: .max, segmentName: "\u{e9}", kind: .data),
                .init(preferredVA: 0, segmentName: "__TEXT", kind: .decodedExecutableInstruction),
            ],
            functions: [
                .init(entryPreferredVA: 0, rawLinkageName: nil),
                .init(entryPreferredVA: 1, rawLinkageName: ""),
                .init(entryPreferredVA: .max, rawLinkageName: "_e\u{301}"),
            ],
            hasCanonicalRawSymbolAuthority: true,
            rawSymbols: [
                .init(exactRawLinkageName: "_raw\0tail", kind: nil, libraryName: "", preferredVA: .max),
                .init(exactRawLinkageName: "_\u{e9}", kind: "function", libraryName: "lib\u{e9}.dylib", preferredVA: 0),
            ],
            hasExactSourceAuthority: true,
            sourceRows: [
                .init(file: files[0], line: 0, column: .max, preferredVA: .max, isEndSequence: false),
                .init(file: files[1], line: .max, column: 0, preferredVA: 0, isEndSequence: true),
            ]
        )
        let empty = DebuggerBreakpointResolutionOwnerIndex(
            coordinate: base.coordinate, revision: 1,
            segments: [], staticAddresses: [], functions: [],
            hasCanonicalRawSymbolAuthority: false, rawSymbols: [],
            hasExactSourceAuthority: false, sourceRows: []
        )
        for owner in owners + [rich, empty] {
            XCTAssertEqual(
                DebuggerBreakpointResolutionCatalogLedger.exactDigest(of: owner),
                retainedResolutionEvidenceBytes(of: owner)
            )
        }
        XCTAssertEqual(DebuggerBreakpointResolutionCatalogLedger.exactDigest(of: empty), Data(repeating: 0, count: 42))
    }

    func testResolutionLedgerEvidencePreservesOptionalAndUnicodeByteDistinctions() throws {
        let store = makeResolutionStore()
        let coordinate = try XCTUnwrap(store.debuggerBreakpointResolutionCatalog.owners.first).coordinate
        let names: [String?] = [nil, "", "e\u{301}", "\u{e9}", String(repeating: "x", count: 257)]
        var encodings: [Data] = []
        for name in names {
            let owner = DebuggerBreakpointResolutionOwnerIndex(
                coordinate: coordinate, revision: 1,
                segments: [], staticAddresses: [],
                functions: [.init(entryPreferredVA: .max, rawLinkageName: name)],
                hasCanonicalRawSymbolAuthority: false, rawSymbols: [],
                hasExactSourceAuthority: false, sourceRows: []
            )
            let bytes = DebuggerBreakpointResolutionCatalogLedger.exactDigest(of: owner)
            XCTAssertEqual(bytes, retainedResolutionEvidenceBytes(of: owner))
            encodings.append(bytes)
        }
        XCTAssertEqual(Set(encodings).count, names.count)
    }

    func testEditEnableDisableAndDeleteEachAdvanceExactlyOnce() throws {
        let store = makeStore()
        let created = try store.createLogicalBreakpoint(
            target: .function(
                owner: owner(slot: .primary, binaryID: primaryID),
                entryPreferredVA: address,
                rawLinkageNameHint: "_entry"
            )
        )

        XCTAssertTrue(try store.setLogicalBreakpointEnabled(created.id, enabled: false))
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 3)
        XCTAssertEqual(store.logicalBreakpoint(id: created.id)?.revision.rawValue, 3)
        XCTAssertEqual(store.logicalBreakpoint(id: created.id)?.enabled, false)

        XCTAssertTrue(
            try store.editLogicalBreakpoint(
                id: created.id,
                draft: WorkspaceLogicalBreakpointDraft(
                    enabled: false,
                    target: .function(
                        owner: owner(slot: .primary, binaryID: primaryID),
                        entryPreferredVA: siblingAddress,
                        rawLinkageNameHint: "_replacement"
                    ),
                    condition: "counter == 3",
                    hitPolicy: .ignoreFirst(2),
                    actions: [],
                    disposition: .stop
                )
            )
        )
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 4)
        XCTAssertEqual(store.logicalBreakpoint(id: created.id)?.revision.rawValue, 4)

        XCTAssertTrue(try store.deleteLogicalBreakpoint(created.id))
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 5)
        XCTAssertNil(store.logicalBreakpoint(id: created.id))

        XCTAssertFalse(try store.deleteLogicalBreakpoint(created.id))
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 5)
    }

    func testUndoRedoPreservesIDAndAdvancesMonotonicRevision() throws {
        let store = makeStore()
        let created = try store.createLogicalBreakpoint(
            target: .preferredAddress(owner: owner(slot: .primary, binaryID: primaryID), preferredVA: address)
        )
        XCTAssertTrue(store.isDirty)

        store.undoManager.undo()

        XCTAssertNil(store.logicalBreakpoint(id: created.id))
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 3)
        XCTAssertFalse(store.isDirty)

        store.undoManager.redo()

        let restored = try XCTUnwrap(store.logicalBreakpoint(id: created.id))
        XCTAssertEqual(restored.id, created.id)
        XCTAssertEqual(restored.revision.rawValue, 4)
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 4)
        XCTAssertTrue(store.isDirty)
    }

    func testEditAfterFocusChangeKeepsExactAuthoredOwner() throws {
        let store = makeStore()
        let target = DebuggerLogicalBreakpointTarget.preferredAddress(
            owner: owner(slot: siblingSlot, binaryID: siblingID),
            preferredVA: address
        )
        let created = try store.createLogicalBreakpoint(target: target)

        store.focusImage(.primary)
        XCTAssertTrue(try store.setLogicalBreakpointEnabled(created.id, enabled: false))

        XCTAssertEqual(store.logicalBreakpoint(id: created.id)?.target, target)
        XCTAssertTrue(store.logicalBreakpointSpecifications(at: .init(slot: siblingSlot, address: address)).isEmpty == false)
        XCTAssertTrue(store.logicalBreakpointSpecifications(at: .init(slot: .primary, address: address)).isEmpty)
    }

    func testProjectionUsesCatalogNotInstructionBreakpointBits() throws {
        // A revision-advanced empty catalog is a deletion tombstone, not a pre-WS-21 pristine
        // snapshot. Legacy bits must never be imported after that one-time migration boundary.
        let store = makeStore(
            catalog: try catalog(revision: 2, specifications: []),
            primaryInstructionHasLegacyBit: true
        )

        XCTAssertTrue(store.logicalBreakpointSpecifications(at: .primary(address)).isEmpty)
        XCTAssertEqual(store.enabledLogicalBreakpointPreferredAddresses(in: .primary), [])

        let disabled = try store.createLogicalBreakpoint(
            enabled: false,
            target: .preferredAddress(owner: owner(slot: .primary, binaryID: primaryID), preferredVA: address)
        )
        XCTAssertEqual(store.logicalBreakpointSpecifications(at: .primary(address)).map(\.id), [disabled.id])
        XCTAssertEqual(store.enabledLogicalBreakpointPreferredAddresses(in: .primary), [])

        XCTAssertTrue(try store.setLogicalBreakpointEnabled(disabled.id, enabled: true))
        XCTAssertEqual(store.enabledLogicalBreakpointPreferredAddresses(in: .primary), [address])
        XCTAssertEqual(store.logicalBreakpointCount, 1)
        XCTAssertEqual(store.enabledLogicalBreakpointCount, 1)
    }

    func testLegacyToggleGutterSidebarAndDebuggerInputUseOnlyLogicalCatalog() throws {
        let store = makeStore(
            catalog: try catalog(revision: 2, specifications: []),
            primaryInstructionHasLegacyBit: true
        )
        store.selectedTool = .debug

        XCTAssertFalse(try XCTUnwrap(store.snapshot.instructions.first).hasBreakpoint)
        XCTAssertEqual(store.gutterBreakpointAddresses, [])
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.gutterBreakpointAddresses, [])
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.breakpointRevision, 2)
        XCTAssertEqual(
            store.sidebarItems.first(where: { $0.id == "debug:breakpoints" })?.detail,
            "0 saved · 0 enabled"
        )

        store.toggleBreakpoint(.primary(address))

        XCTAssertEqual(store.logicalBreakpointCount, 1)
        XCTAssertEqual(store.enabledLogicalBreakpointCount, 1)
        XCTAssertTrue(try XCTUnwrap(store.snapshot.instructions.first).hasBreakpoint)
        XCTAssertEqual(store.gutterBreakpointAddresses, [address])
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.gutterBreakpointAddresses, [address])
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.breakpointRevision, 3)
        XCTAssertEqual(
            store.sidebarItems.first(where: { $0.id == "debug:breakpoints" })?.detail,
            "1 saved · 1 enabled"
        )

        store.toggleBreakpoint(.primary(address))

        XCTAssertEqual(store.logicalBreakpointCount, 0)
        XCTAssertFalse(try XCTUnwrap(store.snapshot.instructions.first).hasBreakpoint)
        XCTAssertEqual(store.gutterBreakpointAddresses, [])
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.gutterBreakpointAddresses, [])
        XCTAssertEqual(store.debuggerWorkspaceInput(in: .primary)?.breakpointRevision, 4)
    }

    func testMultiplePreferredAddressMatchesRouteToManagementWithoutMutation() throws {
        let first = try specification(
            id: id(1), revision: 4, enabled: true,
            target: .preferredAddress(
                owner: owner(slot: .primary, binaryID: primaryID),
                preferredVA: address
            )
        )
        let second = try specification(
            id: id(2), revision: 4, enabled: false,
            target: .preferredAddress(
                owner: owner(slot: .primary, binaryID: primaryID),
                preferredVA: address
            )
        )
        let store = makeStore(catalog: try catalog(revision: 4, specifications: [first, second]))
        let before = store.snapshot.logicalBreakpointCatalog

        store.toggleBreakpoint(.primary(address))

        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog, before)
        XCTAssertEqual(store.logicalBreakpointSpecifications(at: .primary(address)).map(\.id), [first.id, second.id])
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 4)
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertEqual(store.selectedTool, .debug)
        XCTAssertEqual(store.selectedSidebarItemID, "debug:breakpoints")
        XCTAssertEqual(
            store.sidebarItems.first(where: { $0.id == "debug:breakpoints" })?.detail,
            "2 saved · 1 enabled"
        )
    }

    func testSlotRemapUpdatesOnlyExactBinaryOwnerInOneCatalogRevision() throws {
        let primary = try specification(
            id: id(1), revision: 8, enabled: true,
            target: .preferredAddress(owner: owner(slot: .primary, binaryID: primaryID), preferredVA: address)
        )
        let sibling = try specification(
            id: id(2), revision: 8, enabled: true,
            target: .preferredAddress(owner: owner(slot: siblingSlot, binaryID: siblingID), preferredVA: address)
        )
        let store = makeStore(catalog: try catalog(revision: 8, specifications: [primary, sibling]))
        let destination = ImageSlot(rawValue: 11)

        store.remapImageSlot(from: siblingSlot, to: destination)

        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 9)
        XCTAssertEqual(store.logicalBreakpoint(id: primary.id)?.revision.rawValue, 8)
        XCTAssertEqual(store.logicalBreakpoint(id: primary.id)?.target, primary.target)
        let moved = try XCTUnwrap(store.logicalBreakpoint(id: sibling.id))
        XCTAssertEqual(moved.revision.rawValue, 9)
        XCTAssertEqual(
            moved.target,
            .preferredAddress(owner: owner(slot: destination, binaryID: siblingID), preferredVA: address)
        )
    }

    func testSlotRemapMarksOnePersistedMutationAndSchedulesAutosaveOnce() throws {
        let sibling = try specification(
            id: id(2), revision: 8, enabled: true,
            target: .preferredAddress(
                owner: owner(slot: siblingSlot, binaryID: siblingID),
                preferredVA: address
            )
        )
        let trigger = ManualAutosaveTrigger()
        let store = makeStore(
            catalog: try catalog(revision: 8, specifications: [sibling]),
            autosaveScheduler: trigger
        )

        store.remapImageSlot(from: siblingSlot, to: ImageSlot(rawValue: 11))

        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(trigger.scheduleCount, 1)
        XCTAssertTrue(trigger.isPending)
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 9)
    }

    func testRevisionExhaustionRefusesMutationByteForByte() throws {
        let maximum = DebuggerLogicalBreakpointRevision.maximum
        let existing = try specification(
            id: id(1), revision: maximum, enabled: true,
            target: .preferredAddress(owner: owner(slot: .primary, binaryID: primaryID), preferredVA: address)
        )
        let store = makeStore(catalog: try catalog(revision: maximum, specifications: [existing]))
        let before = store.snapshot.logicalBreakpointCatalog

        XCTAssertThrowsError(try store.setLogicalBreakpointEnabled(existing.id, enabled: false)) { error in
            XCTAssertEqual(error as? DebuggerLogicalBreakpointValidationError, .revisionExhausted)
        }

        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog, before)
        XCTAssertFalse(store.isDirty)
        XCTAssertFalse(store.undoManager.canUndo)
    }

    func testUnavailableCatalogBlocksAuthoringSaveAndAutosaveUntilConfirmedRepair() throws {
        let store = makeStore(availability: .unavailable)
        let before = store.snapshot.logicalBreakpointCatalog
        let target = DebuggerLogicalBreakpointTarget.preferredAddress(
            owner: owner(slot: .primary, binaryID: primaryID),
            preferredVA: address
        )

        XCTAssertThrowsError(try store.createLogicalBreakpoint(target: target)) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .logicalBreakpointCatalogUnavailable
            )
        }
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog, before)
        XCTAssertEqual(store.autosaveDecision, .skipConflict)
        store.toggleBreakpoint(.primary(address))
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog, before)
        XCTAssertFalse(try XCTUnwrap(store.snapshot.instructions.first).hasBreakpoint)
        store.remapImageSlot(from: siblingSlot, to: ImageSlot(rawValue: 11))
        XCTAssertNotNil(store.snapshot.binary(in: siblingSlot))
        XCTAssertNil(store.snapshot.binary(in: ImageSlot(rawValue: 11)))
        let database = try WorkspaceDatabase.inMemory()
        XCTAssertThrowsError(try store.saveWorkspace(to: database)) { error in
            XCTAssertEqual(
                error as? WorkspaceDatabase.DatabaseError,
                .logicalBreakpointCatalogUnavailable
            )
        }
        XCTAssertFalse(store.discardCorruptLogicalBreakpointCatalog(confirmed: false))
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .unavailable)

        XCTAssertTrue(store.discardCorruptLogicalBreakpointCatalog(confirmed: true))
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .available)
        XCTAssertNotEqual(store.snapshot.logicalBreakpointCatalog.catalogID, before.catalogID)
        XCTAssertEqual(store.snapshot.logicalBreakpointCatalog.revision, 1)
        XCTAssertTrue(store.snapshot.logicalBreakpointCatalog.specifications.isEmpty)
        XCTAssertTrue(store.isDirty)
    }

    func testBlockedPackageSavePreservesDatabaseIdentityForConfirmedRepair() throws {
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let existing = try specification(
            id: id(1), revision: 2, enabled: true,
            target: .preferredAddress(
                owner: owner(slot: .primary, binaryID: primaryID),
                preferredVA: address
            )
        )
        let persisted = try database.createWorkspaceState(
            workspaceUUID: workspaceID,
            workspaceName: "Repair identity",
            snapshot: makeStore(catalog: try catalog(revision: 2, specifications: [existing])).snapshot,
            selectedSidebarItemID: nil,
            selectedAddress: nil,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: ""
        )
        let databaseID = try XCTUnwrap(persisted.workspace.id)
        try database.executeRawForTesting("""
            UPDATE logical_breakpoints
            SET specification_sha256 = '\(String(repeating: "0", count: 64))'
            WHERE workspace_id = \(databaseID);
            """)
        let store = makeStore()
        XCTAssertTrue(try store.restoreWorkspace(workspaceID: databaseID, from: database))
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .unavailable)
        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws21-blocked-save-\(UUID().uuidString).mscope", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        XCTAssertFalse(store.writeDocumentPackage(to: packageURL))
        XCTAssertTrue(
            try store.discardCorruptLogicalBreakpointCatalog(confirmed: true, in: database)
        )
        XCTAssertEqual(store.logicalBreakpointCatalogAvailability, .available)
    }

    /// Frozen encoder from main 9373b11a8, retained as the byte-identity oracle for T23.
    private func retainedResolutionEvidenceBytes(
        of owner: DebuggerBreakpointResolutionOwnerIndex
    ) -> Data {
        var data = Data()
        func appendByte(_ value: UInt8) { data.append(value) }
        func appendUInt64(_ value: UInt64) {
            var encoded = value.bigEndian
            data.append(Data(bytes: &encoded, count: MemoryLayout<UInt64>.size))
        }
        func appendUInt32(_ value: UInt32) { appendUInt64(UInt64(value)) }
        func appendData(_ value: Data) { appendUInt64(UInt64(value.count)); data.append(value) }
        func appendString(_ value: String) { appendData(Data(value.utf8)) }
        func appendOptionalString(_ value: String?) {
            guard let value else { appendByte(0); return }
            appendByte(1); appendString(value)
        }
        func appendUUID(_ value: UUID) {
            withUnsafeBytes(of: value.uuid) { appendData(Data($0)) }
        }
        func appendSourceFile(_ file: DebuggerCanonicalSourceFileIdentity) {
            appendUUID(file.debugArtifactUUID)
            appendString(file.debugArtifactMachOSHA256)
            appendUInt64(file.debugArtifactMachOByteCount)
            appendUInt64(file.lineProgramUnitOffset)
            appendUInt32(file.fileTableIndex)
            switch file.tablePath {
            case .absoluteUTF8(let path): appendByte(0); appendString(path)
            case .compilationDirectoryRelativeUTF8(let path): appendByte(1); appendString(path)
            }
        }
        appendUInt64(UInt64(owner.segments.count))
        for segment in owner.segments {
            appendString(segment.name); appendUInt64(segment.preferredStart)
            appendUInt64(segment.byteCount); appendByte(segment.isExecutable ? 1 : 0)
        }
        appendUInt64(UInt64(owner.staticAddresses.count))
        for address in owner.staticAddresses {
            appendUInt64(address.preferredVA); appendString(address.segmentName)
            appendByte(address.kind == .decodedExecutableInstruction ? 0 : 1)
        }
        appendUInt64(UInt64(owner.functions.count))
        for function in owner.functions {
            appendUInt64(function.entryPreferredVA); appendOptionalString(function.rawLinkageName)
        }
        appendByte(owner.hasCanonicalRawSymbolAuthority ? 1 : 0)
        appendUInt64(UInt64(owner.rawSymbols.count))
        for symbol in owner.rawSymbols {
            appendString(symbol.exactRawLinkageName); appendOptionalString(symbol.kind)
            appendOptionalString(symbol.libraryName); appendUInt64(symbol.preferredVA)
        }
        appendByte(owner.hasExactSourceAuthority ? 1 : 0)
        appendUInt64(UInt64(owner.sourceRows.count))
        for row in owner.sourceRows {
            appendSourceFile(row.file); appendUInt32(row.line); appendUInt32(row.column)
            appendUInt64(row.preferredVA); appendByte(row.isEndSequence ? 1 : 0)
        }
        return data
    }

    private func makeStore(
        catalog: DebuggerLogicalBreakpointCatalog? = nil,
        primaryInstructionHasLegacyBit: Bool = false,
        availability: DebuggerLogicalBreakpointCatalogAvailability = .available,
        autosaveScheduler: AutosaveScheduling? = nil
    ) -> WorkspaceStore {
        var primaryAnalysis = ImageAnalysis()
        primaryAnalysis.instructions = [instruction(address, hasBreakpoint: primaryInstructionHasLegacyBit)]
        var siblingAnalysis = ImageAnalysis()
        siblingAnalysis.instructions = [instruction(address, hasBreakpoint: false)]
        let snapshot = WorkspaceSnapshot(
            binaries: [
                binary(id: primaryID, slot: .primary),
                binary(id: siblingID, slot: siblingSlot),
            ],
            analysisBySlot: [.primary: primaryAnalysis, siblingSlot: siblingAnalysis],
            logicalBreakpointCatalog: catalog ?? .freshPristine(catalogID: catalogID)
        )
        return WorkspaceStore(
            workspaceName: "Logical breakpoints",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: autosaveScheduler,
            workspaceID: workspaceID,
            logicalBreakpointCatalogAvailability: availability
        )
    }

    private func makeResolutionStore(
        availability: DebuggerLogicalBreakpointCatalogAvailability = .available
    ) -> WorkspaceStore {
        var primaryAnalysis = resolutionAnalysis(address: address)
        primaryAnalysis.sourceLines = [exactSourceLine(address: address)]
        let snapshot = WorkspaceSnapshot(
            binaries: [
                verifiedBinary(id: primaryID, slot: .primary, shaByte: "a"),
                verifiedBinary(id: siblingID, slot: siblingSlot, shaByte: "b"),
            ],
            analysisBySlot: [
                .primary: primaryAnalysis,
                siblingSlot: resolutionAnalysis(address: siblingAddress),
            ],
            logicalBreakpointCatalog: .freshPristine(catalogID: catalogID)
        )
        return WorkspaceStore(
            workspaceName: "Resolution catalog",
            snapshot: snapshot,
            engine: AnalysisEngine(),
            autosaveScheduler: nil,
            workspaceID: workspaceID,
            logicalBreakpointCatalogAvailability: availability
        )
    }

    private func verifiedBinary(id: UUID, slot: ImageSlot, shaByte: String) -> BinaryImage {
        let identity = try! MachOSliceArtifactIdentity(
            uuid: id,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: shaByte, count: 64),
            selectedSliceByteCount: 0x4000
        )
        let layout = try! MachOPreferredSegmentLayout(
            records: [
                .init(
                    name: "__TEXT",
                    preferredVMStart: slot == .primary ? address : siblingAddress,
                    preferredVMSize: 0x1000,
                    sliceRelativeFileOffset: 0,
                    fileSize: 0x1000,
                    initialProtections: 5
                ),
            ],
            selectedSliceByteCount: identity.selectedSliceByteCount
        )
        return BinaryImage(
            id: id,
            name: "image-\(slot.rawValue)",
            path: "/tmp/image-\(slot.rawValue)",
            kind: "Mach-O executable",
            architecture: "arm64",
            artifactIdentity: identity,
            preferredSegmentLayout: layout,
            artifactIntegrityState: .verified,
            slot: slot
        )
    }

    private func resolutionAnalysis(address: UInt64) -> ImageAnalysis {
        var analysis = ImageAnalysis()
        analysis.sections = [
            SectionSummary(
                id: UUID(),
                name: "__TEXT",
                address: address,
                size: 0x1000,
                fileOffset: 0,
                isExecutable: true
            ),
        ]
        analysis.instructions = [instruction(address, hasBreakpoint: false)]
        analysis.functions = [
            FunctionSummary(
                id: UUID(),
                name: "entry",
                startAddress: address,
                endAddress: address + 4,
                confidence: 1
            ),
        ]
        analysis.symbols = [
            SymbolSummary(
                id: UUID(),
                name: "entry",
                address: address,
                kind: "function",
                libraryName: nil,
                rawLinkageName: "_entry"
            ),
        ]
        return analysis
    }

    private func exactSourceLine(address: UInt64) -> SourceLineEntry {
        SourceLineEntry(
            address: address,
            file: "/src/main.c",
            line: 17,
            column: 3,
            endSequence: false,
            debugArtifactUUID: UUID(uuidString: "60000000-0000-0000-0000-000000000006"),
            debugArtifactMachOSHA256: String(repeating: "d", count: 64),
            debugArtifactMachOByteCount: 0x2000,
            lineProgramUnitOffset: 0x40,
            fileTableIndex: 2,
            tablePath: .absoluteUTF8("/src/main.c")
        )
    }

    private func resolutionOwner(
        in input: DebuggerWorkspaceInput,
        binaryID: UUID
    ) -> DebuggerBreakpointResolutionOwnerIndex? {
        input.breakpointResolutionCatalog.owners.first { $0.coordinate.binaryID == binaryID }
    }

    private func binary(id: UUID, slot: ImageSlot) -> BinaryImage {
        BinaryImage(
            id: id,
            name: "image-\(slot.rawValue)",
            path: "/tmp/image-\(slot.rawValue)",
            kind: "Mach-O executable",
            architecture: "arm64",
            slot: slot
        )
    }

    private func instruction(_ address: UInt64, hasBreakpoint: Bool) -> InstructionRow {
        InstructionRow(
            address: address,
            bytes: "1f 20 03 d5",
            mnemonic: "nop",
            operands: "",
            hasBreakpoint: hasBreakpoint,
            comment: nil
        )
    }

    private func owner(slot: ImageSlot, binaryID: UUID) -> DebuggerWorkspaceImageOwnerSeal {
        DebuggerWorkspaceImageOwnerSeal(slot: slot, binaryID: binaryID, artifactIdentity: nil)
    }

    private func id(_ value: UInt8) -> DebuggerLogicalBreakpointID {
        DebuggerLogicalBreakpointID(
            rawValue: UUID(uuidString: String(format: "50000000-0000-0000-0000-%012d", value))!
        )
    }

    private func specification(
        id: DebuggerLogicalBreakpointID,
        revision: UInt64,
        enabled: Bool,
        target: DebuggerLogicalBreakpointTarget,
        condition: String? = nil
    ) throws -> DebuggerLogicalBreakpointSpecification {
        try DebuggerLogicalBreakpointSpecification(
            id: id,
            revision: DebuggerLogicalBreakpointRevision(validating: revision),
            enabled: enabled,
            target: target,
            condition: condition,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
    }

    private func catalog(
        revision: UInt64,
        specifications: [DebuggerLogicalBreakpointSpecification]
    ) throws -> DebuggerLogicalBreakpointCatalog {
        try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID,
            revision: revision,
            specifications: specifications
        )
    }
}
