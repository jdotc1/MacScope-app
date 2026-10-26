import Foundation
import XCTest
@testable import MacScope

/// RED identity oracles for independently owned image-slot reanalysis.
///
/// The intended scope rules are deliberately distinct:
/// - a newer structural edit supersedes only an older request for the same slot;
/// - sibling slots remain independently live and contribute to the aggregate busy state;
/// - a whole-workspace identity replacement invalidates every outstanding slot request.
@MainActor
final class CrossSlotStructuralReanalysisIdentityTests: XCTestCase {
    private let slotA = ImageSlot.primary
    private let slotB = ImageSlot(rawValue: 1)
    private let slotC = ImageSlot(rawValue: 2)
    private let addressA: UInt64 = 0x1_0000_1000
    private let addressB: UInt64 = 0x2_0000_1000

    func testSiblingSlotReanalysisIsNotCancelledAndAggregateIndicatorStaysTrue() async throws {
        let files = try makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlA.lastPathComponent: [resultSnapshot(
                    path: files.urlA.path,
                    address: addressA,
                    mnemonic: "reanalyzed_a"
                )],
                files.urlB.lastPathComponent: [resultSnapshot(
                    path: files.urlB.path,
                    address: addressB,
                    mnemonic: "reanalyzed_b"
                )],
            ]
        )
        let store = makeStore(files: files, provider: provider)
        let requestA = invocation(files.urlA, 1)
        let requestB = invocation(files.urlB, 1)

        select(addressB, in: slotB, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestB)

        select(addressA, in: slotA, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestA)

        await gate.release(requestA)
        await gate.waitUntilFinished(requestA)
        let slotALanded = await waitForMnemonic("reanalyzed_a", in: slotA, store: store)
        XCTAssertTrue(slotALanded)
        XCTAssertTrue(
            store.isReanalyzing,
            "the aggregate indicator must remain true while the sibling slot is still gated"
        )
        let siblingFinishedEarly = await gate.hasFinished(requestB)
        XCTAssertFalse(siblingFinishedEarly, "finishing slot A must not disturb gated slot B")

        await gate.release(requestB)
        await gate.waitUntilFinished(requestB)
        await store.awaitPendingReanalysis()
        let slotBLanded = await waitForMnemonic("reanalyzed_b", in: slotB, store: store)
        XCTAssertTrue(slotBLanded)

        let siblingWasCancelled = await gate.wasCancelled(requestB)
        XCTAssertEqual(siblingWasCancelled, false, "a structural edit in A must not cancel B")
        XCTAssertEqual(mnemonic(in: slotA, store: store), "reanalyzed_a")
        XCTAssertEqual(mnemonic(in: slotB, store: store), "reanalyzed_b")
        XCTAssertFalse(store.isReanalyzing)
        XCTAssertEqual(
            store.snapshot.addressOverrides[ImageAddress(slot: slotA, address: addressA)]?.markAsProcedure,
            true
        )
        XCTAssertEqual(
            store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: addressB)]?.markAsProcedure,
            true
        )
    }

    func testPrimaryReanalysisCompletionDoesNotRewriteSidebarAfterFocusMovesToSibling() async throws {
        let files = try makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlA.lastPathComponent: [resultSnapshot(
                    path: files.urlA.path,
                    address: addressA,
                    mnemonic: "delayed_primary"
                )],
            ]
        )
        let store = makeStore(files: files, provider: provider)
        let requestA = invocation(files.urlA, 1)

        select(addressA, in: slotA, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestA)

        select(addressB, in: slotB, store: store)
        let siblingSidebarSelection = "function:CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
        store.selectedSidebarItemID = siblingSidebarSelection

        await gate.release(requestA)
        await gate.waitUntilFinished(requestA)
        await store.awaitPendingReanalysis()

        XCTAssertEqual(mnemonic(in: slotA, store: store), "delayed_primary")
        XCTAssertEqual(store.focusedImageSlot, slotB)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slotB, address: addressB))
        XCTAssertEqual(
            store.selectedSidebarItemID,
            siblingSidebarSelection,
            "a delayed primary completion must not reinterpret sibling focus into the primary-only sidebar"
        )
    }

    func testAwaitPendingReanalysisWaitsForEveryActiveSlot() async throws {
        let files = try makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlA.lastPathComponent: [resultSnapshot(
                    path: files.urlA.path,
                    address: addressA,
                    mnemonic: "awaited_a"
                )],
                files.urlB.lastPathComponent: [resultSnapshot(
                    path: files.urlB.path,
                    address: addressB,
                    mnemonic: "awaited_b"
                )],
            ]
        )
        let store = makeStore(files: files, provider: provider)
        let requestA = invocation(files.urlA, 1)
        let requestB = invocation(files.urlB, 1)

        select(addressB, in: slotB, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestB)
        select(addressA, in: slotA, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestA)

        let completion = CrossSlotCompletionProbe()
        let waiter = Task { @MainActor in
            await store.awaitPendingReanalysis()
            await completion.markFinished()
        }

        await gate.release(requestA)
        await gate.waitUntilFinished(requestA)
        let slotALanded = await waitForMnemonic("awaited_a", in: slotA, store: store)
        XCTAssertTrue(slotALanded)

        var completedBeforeSibling = false
        for _ in 0..<200 {
            if await completion.isFinished() {
                completedBeforeSibling = true
                break
            }
            await Task.yield()
        }

        // Always unblock the fixture before asserting, including on the known-RED implementation.
        await gate.release(requestB)
        await gate.waitUntilFinished(requestB)
        await waiter.value

        XCTAssertFalse(
            completedBeforeSibling,
            "awaitPendingReanalysis returned while another slot still had an active request"
        )
        let slotBLanded = await waitForMnemonic("awaited_b", in: slotB, store: store)
        XCTAssertTrue(slotBLanded)
        XCTAssertFalse(store.isReanalyzing)
    }

    func testNewerRequestSupersedesOnlyTheSameSlotAndLatestResultWins() async throws {
        let files = try makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlA.lastPathComponent: [
                    resultSnapshot(path: files.urlA.path, address: addressA, mnemonic: "stale_a"),
                    resultSnapshot(path: files.urlA.path, address: addressA, mnemonic: "latest_a"),
                ],
            ]
        )
        let store = makeStore(files: files, provider: provider)
        let staleRequest = invocation(files.urlA, 1)
        let latestRequest = invocation(files.urlA, 2)

        select(addressA, in: slotA, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(staleRequest)
        store.markSelectionAsProcedure(false)
        await gate.waitUntilStarted(latestRequest)

        await gate.release(latestRequest)
        await gate.waitUntilFinished(latestRequest)
        let latestLanded = await waitForMnemonic("latest_a", in: slotA, store: store)
        XCTAssertTrue(latestLanded)

        await gate.release(staleRequest)
        await gate.waitUntilFinished(staleRequest)
        await store.awaitPendingReanalysis()
        for _ in 0..<100 { await Task.yield() }

        let staleWasCancelled = await gate.wasCancelled(staleRequest)
        let latestWasCancelled = await gate.wasCancelled(latestRequest)
        XCTAssertEqual(staleWasCancelled, true)
        XCTAssertEqual(latestWasCancelled, false)
        XCTAssertEqual(mnemonic(in: slotA, store: store), "latest_a")
        XCTAssertNotEqual(mnemonic(in: slotA, store: store), "stale_a")
        XCTAssertNotEqual(
            store.snapshot.addressOverrides[ImageAddress(slot: slotA, address: addressA)]?.markAsProcedure,
            true
        )
        XCTAssertFalse(store.isReanalyzing)
    }

    func testWholeWorkspaceReplacementRejectsLateResultsFromEverySlot() async throws {
        let files = try makeFiles(includeReplacement: true)
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let replacementURL = try XCTUnwrap(files.replacementURL)

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlA.lastPathComponent: [resultSnapshot(
                    path: files.urlA.path,
                    address: addressA,
                    mnemonic: "late_a"
                )],
                files.urlB.lastPathComponent: [resultSnapshot(
                    path: files.urlB.path,
                    address: addressB,
                    mnemonic: "late_b"
                )],
                replacementURL.lastPathComponent: [workspaceSnapshot(
                    urlA: files.urlA,
                    urlB: files.urlB,
                    mnemonicA: "replacement_a",
                    mnemonicB: "replacement_b"
                )],
            ],
            ungatedKeys: [replacementURL.lastPathComponent]
        )
        let store = makeStore(files: files, provider: provider)
        let requestA = invocation(files.urlA, 1)
        let requestB = invocation(files.urlB, 1)

        select(addressB, in: slotB, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestB)
        select(addressA, in: slotA, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestA)

        await store.importBinary(url: replacementURL)
        XCTAssertEqual(mnemonic(in: slotA, store: store), "replacement_a")
        XCTAssertEqual(mnemonic(in: slotB, store: store), "replacement_b")

        await gate.release(requestA)
        await gate.release(requestB)
        await gate.waitUntilFinished(requestA)
        await gate.waitUntilFinished(requestB)
        for _ in 0..<200 { await Task.yield() }

        let requestACancelled = await gate.wasCancelled(requestA)
        let requestBCancelled = await gate.wasCancelled(requestB)
        XCTAssertEqual(requestACancelled, true)
        XCTAssertEqual(requestBCancelled, true)
        XCTAssertEqual(mnemonic(in: slotA, store: store), "replacement_a")
        XCTAssertEqual(mnemonic(in: slotB, store: store), "replacement_b")
        XCTAssertNotEqual(mnemonic(in: slotA, store: store), "late_a")
        XCTAssertNotEqual(mnemonic(in: slotB, store: store), "late_b")
        XCTAssertFalse(store.isReanalyzing)
    }

    func testDeinitCancelsOutstandingReanalysisForEverySlot() async throws {
        let files = try makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlA.lastPathComponent: [resultSnapshot(
                    path: files.urlA.path,
                    address: addressA,
                    mnemonic: "deinit_a"
                )],
                files.urlB.lastPathComponent: [resultSnapshot(
                    path: files.urlB.path,
                    address: addressB,
                    mnemonic: "deinit_b"
                )],
            ]
        )
        var store: WorkspaceStore? = makeStore(files: files, provider: provider)
        weak var weakStore = store
        let requestA = invocation(files.urlA, 1)
        let requestB = invocation(files.urlB, 1)

        select(addressB, in: slotB, store: try XCTUnwrap(store))
        store?.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestB)
        select(addressA, in: slotA, store: try XCTUnwrap(store))
        store?.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(requestA)

        // Remove UndoManager's store targets so this test isolates task ownership rather than
        // relying on framework-specific undo-target retention behavior.
        store?.undoManager.removeAllActions()
        store = nil
        for _ in 0..<100 where weakStore != nil { await Task.yield() }
        XCTAssertNil(weakStore)

        await gate.release(requestA)
        await gate.release(requestB)
        await gate.waitUntilFinished(requestA)
        await gate.waitUntilFinished(requestB)

        let requestACancelled = await gate.wasCancelled(requestA)
        let requestBCancelled = await gate.wasCancelled(requestB)
        XCTAssertEqual(requestACancelled, true)
        XCTAssertEqual(requestBCancelled, true)
    }

    func testRemapCancelsOldSlotRequestAndReschedulesItForTheNewSlot() async throws {
        let files = try makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlB.lastPathComponent: [
                    resultSnapshot(path: files.urlB.path, address: addressB, mnemonic: "pre_remap"),
                    resultSnapshot(path: files.urlB.path, address: addressB, mnemonic: "remapped_b"),
                ],
            ]
        )
        let store = makeStore(files: files, provider: provider)
        let oldRequest = invocation(files.urlB, 1)
        let remappedRequest = invocation(files.urlB, 2)

        select(addressB, in: slotB, store: store)
        store.markSelectionAsProcedure(true)
        await gate.waitUntilStarted(oldRequest)

        store.remapImageSlot(from: slotB, to: slotC)
        XCTAssertNil(store.snapshot.binary(in: slotB))
        XCTAssertNotNil(store.snapshot.binary(in: slotC))

        await gate.release(oldRequest)
        await gate.waitUntilFinished(oldRequest)
        let oldRequestCancelled = await gate.wasCancelled(oldRequest)
        let didReschedule = await waitForStart(remappedRequest, gate: gate)

        // The current global-task implementation reaches this bounded RED assertion instead of
        // hanging forever on waitUntilStarted for a request that it never schedules.
        guard didReschedule else {
            XCTAssertEqual(oldRequestCancelled, true, "slot remap must cancel the old-slot request")
            XCTFail("slot remap did not reschedule structural analysis under the new slot")
            return
        }

        await gate.release(remappedRequest)
        await gate.waitUntilFinished(remappedRequest)
        await store.awaitPendingReanalysis()

        XCTAssertEqual(oldRequestCancelled, true)
        XCTAssertEqual(mnemonic(in: slotC, store: store), "remapped_b")
        XCTAssertNil(store.snapshot.analysis(in: slotB))
        XCTAssertEqual(
            store.snapshot.addressOverrides[ImageAddress(slot: slotC, address: addressB)]?.markAsProcedure,
            true
        )
        XCTAssertFalse(store.isReanalyzing)
    }

    func testBulkOverrideUndoReanalyzesTheAuthoredSlotAfterFocusMoves() async throws {
        let stringBytes = Data("HELLO\0".utf8)
        let files = try makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlA.lastPathComponent: [
                    resultSnapshot(
                        path: files.urlA.path,
                        address: addressA,
                        mnemonic: "bulk_apply_a",
                        bytes: stringBytes
                    ),
                    resultSnapshot(
                        path: files.urlA.path,
                        address: addressA,
                        mnemonic: "bulk_undo_a",
                        bytes: stringBytes
                    ),
                ],
                files.urlB.lastPathComponent: [resultSnapshot(
                    path: files.urlB.path,
                    address: addressB,
                    mnemonic: "wrong_slot_b"
                )],
            ]
        )
        let store = WorkspaceStore(
            workspaceName: "bulk exact-slot undo",
            snapshot: workspaceSnapshot(
                urlA: files.urlA,
                urlB: files.urlB,
                mnemonicA: "initial_a",
                mnemonicB: "initial_b",
                bytesA: stringBytes
            ),
            engine: provider,
            autosaveScheduler: nil
        )
        let applyRequest = invocation(files.urlA, 1)
        let undoRequest = invocation(files.urlA, 2)
        let wrongSlotRequest = invocation(files.urlB, 1)

        store.focusImage(slotA)
        let transformed = store.transformSectionToStrings(
            sectionName: "__TEXT,__text",
            minimumLength: 5
        )
        XCTAssertEqual(transformed, 1)
        await gate.waitUntilStarted(applyRequest)
        await gate.release(applyRequest)
        await gate.waitUntilFinished(applyRequest)
        await store.awaitPendingReanalysis()
        let bulkApplyLanded = await waitForMnemonic("bulk_apply_a", in: slotA, store: store)
        XCTAssertTrue(bulkApplyLanded)

        store.focusImage(slotB)
        store.undoManager.undo()
        XCTAssertNil(
            store.snapshot.addressOverrides[ImageAddress(slot: slotA, address: addressA)],
            "bulk undo must synchronously restore the exact authored override map"
        )

        let scheduledAuthoredSlot = await waitForStart(undoRequest, gate: gate)
        let scheduledFocusedSibling = await gate.hasStarted(wrongSlotRequest)

        guard scheduledAuthoredSlot else {
            if scheduledFocusedSibling {
                await gate.release(wrongSlotRequest)
                await gate.waitUntilFinished(wrongSlotRequest)
            }
            XCTAssertFalse(
                scheduledFocusedSibling,
                "bulk undo incorrectly reanalyzed the mutable focused sibling"
            )
            XCTFail("bulk undo did not reanalyze the slot that authored the override map")
            return
        }

        await gate.release(undoRequest)
        await gate.waitUntilFinished(undoRequest)
        await store.awaitPendingReanalysis()

        XCTAssertFalse(scheduledFocusedSibling)
        XCTAssertEqual(mnemonic(in: slotA, store: store), "bulk_undo_a")
        XCTAssertEqual(mnemonic(in: slotB, store: store), "initial_b")
        XCTAssertFalse(store.isReanalyzing)
    }

    func testTransformSectionToStringsAtSelectionReadsTheFocusedSiblingBytes() async throws {
        let primaryBytes = Data("HELLO\0".utf8) + Data(repeating: 0, count: 10)
        let siblingStringOffset: UInt64 = 8
        let siblingBytes = Data(repeating: 0, count: Int(siblingStringOffset))
            + Data("WORLD\0".utf8)
            + Data(repeating: 0, count: 2)
        let files = try makeFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }

        let gate = CrossSlotReanalysisGate()
        let provider = CrossSlotReanalysisProvider(
            gate: gate,
            results: [
                files.urlB.lastPathComponent: [resultSnapshot(
                    path: files.urlB.path,
                    address: addressA,
                    mnemonic: "reanalyzed_b",
                    bytes: siblingBytes
                )],
            ],
            ungatedKeys: [files.urlB.lastPathComponent]
        )
        var snapshot = workspaceSnapshot(
            urlA: files.urlA,
            urlB: files.urlB,
            bytesA: primaryBytes
        )
        snapshot.analysisBySlot[slotB] = analysis(
            address: addressA,
            mnemonic: "initial_b",
            bytes: siblingBytes
        )
        let store = WorkspaceStore(
            workspaceName: "bulk focused sibling bytes",
            snapshot: snapshot,
            engine: provider,
            autosaveScheduler: nil
        )

        select(addressA, in: slotB, store: store)
        let transformed = store.transformSectionToStringsAtSelection(minimumLength: 5)

        XCTAssertEqual(transformed, 1)
        XCTAssertNil(
            store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: addressA)],
            "the focused sibling must not inherit the primary image's colliding string"
        )
        XCTAssertEqual(
            store.snapshot.addressOverrides[
                ImageAddress(slot: slotB, address: addressA + siblingStringOffset)
            ]?.dataShape,
            DataShapeOverride(kind: .string, isNullTerminated: true)
        )
        XCTAssertNil(
            store.snapshot.addressOverrides[ImageAddress(slot: slotA, address: addressA)],
            "bulk authoring must not mutate the unfocused primary image"
        )

        await store.awaitPendingReanalysis()
        XCTAssertEqual(mnemonic(in: slotB, store: store), "reanalyzed_b")
    }

    private func makeStore(
        files: CrossSlotTestFiles,
        provider: CrossSlotReanalysisProvider
    ) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "cross-slot reanalysis identity",
            snapshot: workspaceSnapshot(urlA: files.urlA, urlB: files.urlB),
            engine: provider,
            autosaveScheduler: nil
        )
    }

    private func makeFiles(includeReplacement: Bool = false) throws -> CrossSlotTestFiles {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-cross-slot-reanalysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let urlA = directory.appendingPathComponent("slot-a.bin")
        let urlB = directory.appendingPathComponent("slot-b.bin")
        try Data([0xAA]).write(to: urlA)
        try Data([0xBB]).write(to: urlB)

        let replacementURL: URL?
        if includeReplacement {
            let url = directory.appendingPathComponent("replacement.bin")
            try Data([0xCC]).write(to: url)
            replacementURL = url
        } else {
            replacementURL = nil
        }
        return CrossSlotTestFiles(
            directory: directory,
            urlA: urlA,
            urlB: urlB,
            replacementURL: replacementURL
        )
    }

    private func invocation(_ url: URL, _ index: Int) -> String {
        "\(url.lastPathComponent)#\(index)"
    }

    private func waitForStart(
        _ key: String,
        gate: CrossSlotReanalysisGate,
        attempts: Int = 500
    ) async -> Bool {
        for _ in 0..<attempts {
            if await gate.hasStarted(key) { return true }
            await Task.yield()
        }
        return await gate.hasStarted(key)
    }

    private func waitForMnemonic(
        _ expected: String,
        in slot: ImageSlot,
        store: WorkspaceStore,
        attempts: Int = 500
    ) async -> Bool {
        for _ in 0..<attempts {
            if mnemonic(in: slot, store: store) == expected { return true }
            await Task.yield()
        }
        return mnemonic(in: slot, store: store) == expected
    }

    private func select(_ address: UInt64, in slot: ImageSlot, store: WorkspaceStore) {
        store.focusImage(slot)
        store.selectInstruction(address)
        XCTAssertEqual(store.selectedImageAddress, ImageAddress(slot: slot, address: address))
    }

    private func mnemonic(in slot: ImageSlot, store: WorkspaceStore) -> String? {
        store.snapshot.analysis(in: slot)?.instructions.first?.mnemonic
    }

    private func workspaceSnapshot(
        urlA: URL,
        urlB: URL,
        mnemonicA: String = "initial_a",
        mnemonicB: String = "initial_b",
        bytesA: Data? = nil
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [
                binary(
                    id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA0")!,
                    name: "Slot A",
                    path: urlA.path,
                    slot: slotA
                ),
                binary(
                    id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB0")!,
                    name: "Slot B",
                    path: urlB.path,
                    slot: slotB
                ),
            ],
            analysisBySlot: [
                slotA: analysis(address: addressA, mnemonic: mnemonicA, bytes: bytesA),
                slotB: analysis(address: addressB, mnemonic: mnemonicB),
            ]
        )
    }

    private func resultSnapshot(
        path: String,
        address: UInt64,
        mnemonic: String,
        bytes: Data? = nil
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [
                binary(id: UUID(), name: mnemonic, path: path, slot: .primary),
            ],
            analysisBySlot: [
                .primary: analysis(address: address, mnemonic: mnemonic, bytes: bytes),
            ]
        )
    }

    private func binary(id: UUID, name: String, path: String, slot: ImageSlot) -> BinaryImage {
        BinaryImage(
            id: id,
            name: name,
            path: path,
            kind: "fixture",
            architecture: "arm64",
            slot: slot
        )
    }

    private func analysis(address: UInt64, mnemonic: String, bytes: Data? = nil) -> ImageAnalysis {
        let payload = bytes ?? Data(repeating: 0, count: 0x100)
        var result = ImageAnalysis()
        result.functions = [FunctionSummary(
            id: UUID(),
            name: mnemonic,
            startAddress: address,
            endAddress: address + 4,
            confidence: 1
        )]
        result.instructions = [InstructionRow(
            address: address,
            bytes: "00 00 00 00",
            mnemonic: mnemonic,
            operands: "",
            hasBreakpoint: false,
            comment: nil
        )]
        result.sections = [SectionSummary(
            id: UUID(),
            name: "__TEXT,__text",
            address: address,
            size: UInt64(payload.count),
            fileOffset: 0,
            isExecutable: true
        )]
        result.hexBytes = payload
        return result
    }
}

private struct CrossSlotTestFiles {
    let directory: URL
    let urlA: URL
    let urlB: URL
    let replacementURL: URL?
}

private struct CrossSlotReanalysisInvocation: Sendable {
    let key: String
    let index: Int
}

private actor CrossSlotReanalysisGate {
    private var invocationCounts: [String: Int] = [:]
    private var started: Set<String> = []
    private var finished: Set<String> = []
    private var released: Set<String> = []
    private var cancellationByKey: [String: Bool] = [:]
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var finishWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func begin(_ baseKey: String) -> CrossSlotReanalysisInvocation {
        let index = invocationCounts[baseKey, default: 0] + 1
        invocationCounts[baseKey] = index
        return CrossSlotReanalysisInvocation(key: "\(baseKey)#\(index)", index: index)
    }

    func blockUntilReleased(_ key: String) async {
        started.insert(key)
        startWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
        guard !released.contains(key) else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[key, default: []].append(continuation)
        }
    }

    func hasStarted(_ key: String) -> Bool {
        started.contains(key)
    }

    func waitUntilStarted(_ key: String) async {
        guard !started.contains(key) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        released.insert(key)
        releaseWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    func recordFinished(_ key: String, wasCancelled: Bool) {
        cancellationByKey[key] = wasCancelled
        finished.insert(key)
        finishWaiters.removeValue(forKey: key)?.forEach { $0.resume() }
    }

    func hasFinished(_ key: String) -> Bool {
        finished.contains(key)
    }

    func waitUntilFinished(_ key: String) async {
        guard !finished.contains(key) else { return }
        await withCheckedContinuation { continuation in
            finishWaiters[key, default: []].append(continuation)
        }
    }

    func wasCancelled(_ key: String) -> Bool? {
        cancellationByKey[key]
    }
}

private actor CrossSlotCompletionProbe {
    private var finished = false

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

private final class CrossSlotReanalysisProvider: AnalysisProviding, @unchecked Sendable {
    private let gate: CrossSlotReanalysisGate
    private let results: [String: [WorkspaceSnapshot]]
    private let ungatedKeys: Set<String>

    init(
        gate: CrossSlotReanalysisGate,
        results: [String: [WorkspaceSnapshot]],
        ungatedKeys: Set<String> = []
    ) {
        self.gate = gate
        self.results = results
        self.ungatedKeys = ungatedKeys
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        try result(for: url.lastPathComponent, invocationIndex: 1)
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        let baseKey = url.lastPathComponent
        if ungatedKeys.contains(baseKey) {
            return try result(for: baseKey, invocationIndex: 1)
        }

        let invocation = await gate.begin(baseKey)
        await gate.blockUntilReleased(invocation.key)
        let result = try result(for: baseKey, invocationIndex: invocation.index)
        await gate.recordFinished(invocation.key, wasCancelled: Task.isCancelled)
        return result
    }

    private func result(for key: String, invocationIndex: Int) throws -> WorkspaceSnapshot {
        guard let scriptedResults = results[key], !scriptedResults.isEmpty else {
            throw CrossSlotReanalysisProviderError.missingResult(key)
        }
        let index = min(invocationIndex - 1, scriptedResults.count - 1)
        return scriptedResults[index]
    }
}

private enum CrossSlotReanalysisProviderError: Error {
    case missingResult(String)
}
