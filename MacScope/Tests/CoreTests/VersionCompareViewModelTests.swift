import Foundation
import XCTest
@testable import MacScope

/// M8 Compare Images: the window-owned view model over `FunctionVersionMatcher`. Fixtures are
/// synthetic `ImageAnalysis` values run through the real fingerprint adapter and matcher.
@MainActor
final class VersionCompareViewModelTests: XCTestCase {
    private let slotB = ImageSlot(rawValue: 1)
    private let slotC = ImageSlot(rawValue: 2)

    // MARK: - Fixtures

    private struct FixtureFunction {
        let id = UUID()
        let name: String
        let start: UInt64
        let size: UInt64
    }

    private func analysis(_ functions: [FixtureFunction], base: UInt64) -> ImageAnalysis {
        var analysis = ImageAnalysis()
        analysis.functions = functions.map {
            FunctionSummary(id: $0.id, name: $0.name, startAddress: $0.start,
                            endAddress: $0.start + $0.size, confidence: 1)
        }
        analysis.sections = [SectionSummary(id: UUID(), name: "__text", address: base, size: 0x1000,
                                            fileOffset: 0, isExecutable: true)]
        return analysis
    }

    private func binary(_ slot: ImageSlot, name: String) -> BinaryImage {
        BinaryImage(id: UUID(), name: name, path: "/tmp/\(name)", kind: "executable",
                    architecture: "arm64", slot: slot)
    }

    /// Old version: `_main`, `_changed`, `_gone`, and two `_dup` functions.
    private let oldMain = FixtureFunction(name: "_main", start: 0x1000, size: 0x40)
    private let oldChanged = FixtureFunction(name: "_changed", start: 0x1100, size: 0x40)
    private let oldGone = FixtureFunction(name: "_gone", start: 0x1200, size: 0x40)
    private let oldDup1 = FixtureFunction(name: "_dup", start: 0x1300, size: 0x40)
    private let oldDup2 = FixtureFunction(name: "_dup", start: 0x1400, size: 0x40)
    /// New version: `_main` moved, `_changed` grew, `_fresh` appeared, `_dup` still duplicated.
    private let newMain = FixtureFunction(name: "_main", start: 0x2000, size: 0x40)
    private let newChanged = FixtureFunction(name: "_changed", start: 0x2100, size: 0x80)
    private let newFresh = FixtureFunction(name: "_fresh", start: 0x2200, size: 0x40)
    private let newDup1 = FixtureFunction(name: "_dup", start: 0x2300, size: 0x40)
    private let newDup2 = FixtureFunction(name: "_dup", start: 0x2400, size: 0x40)
    /// A third, unrelated image.
    private let otherOnly = FixtureFunction(name: "_other", start: 0x3000, size: 0x40)

    private func snapshot(imageCount: Int) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: binary(.primary, name: "v1"),
                             analysis: analysis([oldMain, oldChanged, oldGone, oldDup1, oldDup2], base: 0x1000))
        if imageCount >= 2 {
            snapshot.insertImage(binary: binary(slotB, name: "v2"),
                                 analysis: analysis([newMain, newChanged, newFresh, newDup1, newDup2], base: 0x2000))
        }
        if imageCount >= 3 {
            snapshot.insertImage(binary: binary(slotC, name: "other"),
                                 analysis: analysis([otherOnly], base: 0x3000))
        }
        return snapshot
    }

    private func store(imageCount: Int) -> WorkspaceStore {
        WorkspaceStore(workspaceName: "Compare", snapshot: snapshot(imageCount: imageCount),
                       engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func waitUntil(timeout: Duration = .seconds(5),
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func readyModel(imageCount: Int = 2,
                            worker: VersionCompareViewModel.Worker? = nil) async throws -> VersionCompareViewModel {
        let model = worker.map { VersionCompareViewModel(worker: $0) } ?? VersionCompareViewModel()
        model.bind(to: snapshot(imageCount: imageCount))
        let ready = await waitUntil { model.phase == .ready }
        XCTAssertTrue(ready, "comparison never published; phase = \(model.phase)")
        return model
    }

    // MARK: - Grouping

    func testBindComparesFirstTwoImagesAndGroupsResults() async throws {
        let model = try await readyModel()

        XCTAssertEqual(model.oldSlot, .primary)
        XCTAssertEqual(model.newSlot, slotB)
        XCTAssertEqual(model.comparedPair?.old.slot, .primary)
        XCTAssertEqual(model.comparedPair?.new.slot, slotB)
        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(report.summary, VersionCompareSummary(unchanged: 1, changed: 1, added: 1, removed: 1,
                                                             unresolvedGroups: 1, manualPins: 0))
        XCTAssertEqual(report.rows.map(\.status), [.changed, .removed, .added, .unchanged],
                       "rows are grouped changed, removed, added, unchanged")

        let changed = try XCTUnwrap(report.rows.first { $0.status == .changed })
        XCTAssertEqual(changed.old?.name, "_changed")
        XCTAssertEqual(changed.old?.address, 0x1100)
        XCTAssertEqual(changed.new?.address, 0x2100)
        XCTAssertEqual(changed.basis, .symbolName)
        XCTAssertEqual(changed.confidence, .high)
        XCTAssertEqual(changed.differences, [.size])

        XCTAssertEqual(report.rows.first { $0.status == .removed }?.old?.id, oldGone.id.uuidString)
        XCTAssertNil(report.rows.first { $0.status == .removed }?.new)
        XCTAssertEqual(report.rows.first { $0.status == .added }?.new?.id, newFresh.id.uuidString)
        XCTAssertEqual(report.rows.first { $0.status == .unchanged }?.new?.name, "_main")

        let group = try XCTUnwrap(report.unresolvedGroups.first)
        XCTAssertEqual(group.bases, [.duplicateSymbolName])
        XCTAssertEqual(Set(group.old.map(\.id)), [oldDup1.id.uuidString, oldDup2.id.uuidString])
        XCTAssertEqual(Set(group.new.map(\.id)), [newDup1.id.uuidString, newDup2.id.uuidString])
    }

    func testFilterAndSearchNarrowRowsAndGroups() async throws {
        let model = try await readyModel()
        let report = try XCTUnwrap(model.report)

        XCTAssertEqual(report.filteredRows(filter: .added, search: "").map(\.new?.name), ["_fresh"])
        XCTAssertTrue(report.filteredRows(filter: .unresolved, search: "").isEmpty)
        XCTAssertEqual(report.filteredUnresolvedGroups(filter: .unresolved, search: "").count, 1)
        XCTAssertTrue(report.filteredUnresolvedGroups(filter: .changed, search: "").isEmpty)
        XCTAssertEqual(report.filteredRows(filter: .all, search: " CHANGED ").map(\.status), [.changed])
        XCTAssertEqual(report.filteredRows(filter: .all, search: "2200").map(\.status), [.added],
                       "search matches the hex address")
        XCTAssertTrue(report.filteredUnresolvedGroups(filter: .all, search: "_main").isEmpty)
    }

    // MARK: - Manual resolution

    func testPinResolvesUnresolvedGroupAndRecomputes() async throws {
        let model = try await readyModel()
        let before = try XCTUnwrap(model.report)

        model.pin(oldID: oldDup1.id.uuidString, newID: newDup2.id.uuidString)
        XCTAssertTrue(model.isPinning)
        let settled = await waitUntil { !model.isPinning }
        XCTAssertTrue(settled)

        XCTAssertNil(model.pinError)
        XCTAssertEqual(model.phase, .ready)
        let report = try XCTUnwrap(model.report)
        XCTAssertNotEqual(report, before)
        XCTAssertTrue(report.unresolvedGroups.isEmpty)
        XCTAssertEqual(report.summary.manualPins, 1)
        XCTAssertEqual(report.summary.unchanged, 3, "_main plus both _dup functions")
        let pinned = try XCTUnwrap(report.rows.first { $0.old?.id == oldDup1.id.uuidString })
        XCTAssertEqual(pinned.new?.id, newDup2.id.uuidString)
        XCTAssertEqual(pinned.basis, .manual)
        XCTAssertEqual(pinned.confidence, .userConfirmed)
        let remaining = try XCTUnwrap(report.rows.first { $0.old?.id == oldDup2.id.uuidString })
        XCTAssertEqual(remaining.new?.id, newDup1.id.uuidString,
                       "with one pair pinned the remaining _dup pair is unique by name")
        XCTAssertEqual(remaining.basis, .symbolName)
        XCTAssertEqual(model.computation?.result.manualPins,
                       [FunctionVersionManualPin(oldID: oldDup1.id.uuidString, newID: newDup2.id.uuidString)])
    }

    func testPinRejectedByMatcherKeepsReportAndSurfacesError() async throws {
        let model = try await readyModel()
        let before = model.report

        // `_main` is already matched automatically; the matcher refuses to re-pin it.
        model.pin(oldID: oldMain.id.uuidString, newID: newDup1.id.uuidString)
        let settled = await waitUntil { !model.isPinning }
        XCTAssertTrue(settled)

        XCTAssertNotNil(model.pinError)
        XCTAssertEqual(model.report, before)
        XCTAssertEqual(model.phase, .ready)
    }

    func testRerunDiscardsManualPins() async throws {
        let model = try await readyModel()
        model.pin(oldID: oldDup1.id.uuidString, newID: newDup2.id.uuidString)
        _ = await waitUntil { !model.isPinning }
        XCTAssertEqual(model.report?.summary.manualPins, 1)

        model.run()
        let ready = await waitUntil { model.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.report?.summary.manualPins, 0)
        XCTAssertEqual(model.report?.summary.unresolvedGroups, 1)
    }

    // MARK: - Stale-selection cancellation

    func testSelectionChangeCancelsStaleComparisonAndItNeverPublishes() async throws {
        let firstGate = CompareWorkerGate()
        let probe = CompareWorkerProbe()
        let model = VersionCompareViewModel(worker: { old, new in
            let call = probe.begin()
            if call == 0 {
                // Ignore cancellation on purpose: only the generation fence may stop publication.
                await firstGate.wait()
                probe.finishStale(cancelled: Task.isCancelled)
            }
            return try VersionCompareComputation.build(old: old, new: new)
        })
        model.bind(to: snapshot(imageCount: 3))
        XCTAssertEqual(model.phase, .running)
        let started = await waitUntil { probe.calls == 1 }
        XCTAssertTrue(started)

        model.selectNew(slotC)
        XCTAssertNil(model.report)
        let ready = await waitUntil { model.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.comparedPair?.new.slot, slotC)
        XCTAssertEqual(model.report?.summary.added, 1, "v1 → other adds only _other")
        let publishedForC = model.report

        firstGate.open()
        let staleDone = await waitUntil { probe.staleFinished }
        XCTAssertTrue(staleDone)
        XCTAssertTrue(probe.staleWasCancelled, "the superseded worker task is cancelled")
        // Give the stale publication a chance to (wrongly) land.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.comparedPair?.new.slot, slotC)
        XCTAssertEqual(model.report, publishedForC)
        XCTAssertEqual(model.phase, .ready)
    }

    func testSelectingTheOtherSideSwapsInsteadOfComparingAnImageWithItself() async throws {
        let model = try await readyModel()
        model.selectNew(.primary)
        XCTAssertEqual(model.oldSlot, slotB)
        XCTAssertEqual(model.newSlot, .primary)
        let ready = await waitUntil { model.phase == .ready }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.comparedPair?.old.slot, slotB)
        XCTAssertEqual(model.report?.summary.added, 1, "reversed: _gone is now added")
        XCTAssertEqual(model.report?.rows.first { $0.status == .added }?.new?.name, "_gone")
    }

    func testRebindWithUnchangedImagesDoesNotRestartComparison() async throws {
        let probe = CompareWorkerProbe()
        let snapshot = snapshot(imageCount: 2)
        let model = VersionCompareViewModel(worker: { old, new in
            _ = probe.begin()
            return try VersionCompareComputation.build(old: old, new: new)
        })
        model.bind(to: snapshot)
        _ = await waitUntil { model.phase == .ready }
        model.bind(to: snapshot)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(probe.calls, 1)
    }

    // MARK: - Availability

    func testUnavailableWithFewerThanTwoImages() async throws {
        let single = snapshot(imageCount: 1)
        XCTAssertFalse(VersionCompareViewModel.isAvailable(in: single))
        XCTAssertFalse(VersionCompareViewModel.isAvailable(in: WorkspaceSnapshot(binaries: [], analysisBySlot: [:])))
        XCTAssertTrue(VersionCompareViewModel.isAvailable(in: snapshot(imageCount: 2)))

        let probe = CompareWorkerProbe()
        let model = VersionCompareViewModel(worker: { old, new in
            _ = probe.begin()
            return try VersionCompareComputation.build(old: old, new: new)
        })
        model.bind(to: single)
        XCTAssertFalse(model.isAvailable)
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.selectedPair)
        model.run()
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.report)
        XCTAssertEqual(probe.calls, 0, "no work is started without two images")
    }

    func testRemovingAnImageRetiresThePublishedComparison() async throws {
        let model = try await readyModel()
        model.bind(to: snapshot(imageCount: 1))
        XCTAssertEqual(model.phase, .unavailable)
        XCTAssertNil(model.report)
        XCTAssertNil(model.comparedPair)
    }

    // MARK: - Navigation

    func testRowNavigationFocusesTheRespectiveImage() async throws {
        let store = store(imageCount: 2)
        let model = VersionCompareViewModel()
        model.bind(to: store.snapshot)
        _ = await waitUntil { model.phase == .ready }
        let row = try XCTUnwrap(model.report?.rows.first { $0.status == .changed })

        let newTarget = try XCTUnwrap(model.navigationTarget(for: row.new, side: .new))
        XCTAssertTrue(VersionCompareViewModel.navigate(to: newTarget, in: store))
        XCTAssertEqual(store.focusedImageSlot, slotB)
        XCTAssertEqual(store.selectedAddress, 0x2100)

        let oldTarget = try XCTUnwrap(model.navigationTarget(for: row.old, side: .old))
        XCTAssertTrue(VersionCompareViewModel.navigate(to: oldTarget, in: store))
        XCTAssertEqual(store.focusedImageSlot, .primary)
        XCTAssertEqual(store.selectedAddress, 0x1100)
    }

    func testNavigationIsRejectedAfterTheImageIsReplaced() async throws {
        let store = store(imageCount: 2)
        let model = VersionCompareViewModel()
        model.bind(to: store.snapshot)
        _ = await waitUntil { model.phase == .ready }
        let row = try XCTUnwrap(model.report?.rows.first { $0.status == .changed })
        let target = try XCTUnwrap(model.navigationTarget(for: row.new, side: .new))

        var replaced = store.snapshot
        let analysis = replaced.analysis(in: slotB)!
        replaced.removeImage(in: slotB)
        replaced.insertImage(binary: binary(slotB, name: "v2-replacement"), analysis: analysis)
        store.snapshot = replaced

        XCTAssertFalse(VersionCompareViewModel.navigate(to: target, in: store))
        XCTAssertEqual(store.focusedImageSlot, .primary)
    }

    // MARK: - RX-01 annotation transfer

    private func override(_ name: String?, _ comment: String? = nil) -> AddressOverride {
        var value = AddressOverride()
        value.customName = name
        value.customComment = comment
        return value
    }

    /// Old: `_main` renamed + commented, `_changed` renamed, `_gone` (removed) and one `_dup`
    /// (unresolved) renamed. New: `_changed` already carries an authored name (the conflict).
    private func transferStore() -> WorkspaceStore {
        var fixture = snapshot(imageCount: 2)
        fixture.addressOverrides[ImageAddress(slot: .primary, address: oldMain.start)] = override("mainRenamed", "entry point")
        fixture.addressOverrides[ImageAddress(slot: .primary, address: oldChanged.start)] = override("changedRenamed")
        fixture.addressOverrides[ImageAddress(slot: .primary, address: oldGone.start)] = override("goneRenamed")
        fixture.addressOverrides[ImageAddress(slot: .primary, address: oldDup1.start)] = override("dupRenamed")
        fixture.addressOverrides[ImageAddress(slot: slotB, address: newChanged.start)] = override("keepMine")
        return WorkspaceStore(workspaceName: "Transfer", snapshot: fixture,
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func readyTransferModel(_ store: WorkspaceStore) async throws -> VersionCompareViewModel {
        let model = VersionCompareViewModel()
        model.bind(to: store.snapshot)
        let ready = await waitUntil { model.phase == .ready }
        XCTAssertTrue(ready, "comparison never published; phase = \(model.phase)")
        return model
    }

    func testTransferReviewListsMatchedCandidatesAndApplyWritesNamesInOneUndo() async throws {
        let store = transferStore()
        let model = try await readyTransferModel(store)
        XCTAssertTrue(model.beginTransferReview(snapshot: store.snapshot))
        let review = try XCTUnwrap(model.transferReview)

        // Only 1:1 matched pairs with authored old text: removed and ambiguous functions never appear.
        let mainID = "match:\(oldMain.id.uuidString)>\(newMain.id.uuidString)"
        let changedID = "match:\(oldChanged.id.uuidString)>\(newChanged.id.uuidString)"
        XCTAssertEqual(review.candidates.map(\.id), [mainID, changedID])
        XCTAssertEqual(review.candidates.map(\.confidence), [.high, .high])
        XCTAssertEqual(review.candidates.map(\.basis), [.symbolName, .symbolName])
        XCTAssertEqual(review.candidates.map(\.movesText), ["name + comment", "name"])
        XCTAssertEqual(review.selected, [mainID, changedID], "high-confidence pairs are preselected")
        XCTAssertEqual(review.unresolvedGroupCount, 1)
        let plan = try XCTUnwrap(review.plan)
        XCTAssertEqual(plan.changes, [AnnotationTransferChange(sourceAddress: oldMain.start, destinationAddress: newMain.start,
                                                               newName: "mainRenamed", newComment: "entry point")])
        XCTAssertEqual(plan.conflicts.map(\.kind), [.authored])
        XCTAssertEqual(plan.conflicts.first?.destinationAddress, newChanged.start)
        XCTAssertEqual(review.applyTitle, "Apply 1 name and 1 comment")

        // Select None empties the plan; the default rule restores it.
        model.clearTransferSelection()
        XCTAssertEqual(model.transferReview?.canApply, false)
        model.selectHighConfidenceTransferCandidates()
        XCTAssertEqual(model.transferReview?.selected, [mainID, changedID])

        let before = store.snapshot.addressOverrides.filter { $0.key.slot == slotB }
        XCTAssertEqual(model.applyTransfer(in: store), .applied(names: 1, comments: 1, conflicts: 1))
        XCTAssertNil(model.transferReview, "a successful apply closes the review")
        let written = store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: newMain.start)]
        XCTAssertEqual(written?.customName, "mainRenamed")
        XCTAssertEqual(written?.customComment, "entry point")
        XCTAssertEqual(store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: newChanged.start)]?.customName,
                       "keepMine", "authored destination text is never overwritten")
        for function in [newFresh, newDup1, newDup2] {
            XCTAssertNil(store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: function.start)])
        }
        XCTAssertEqual(store.undoManager.undoActionName, WorkspaceStore.annotationTransferActionName)

        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides.filter { $0.key.slot == slotB }, before,
                       "one Undo reverts the whole transfer")
    }

    func testRefusedTransferWritesNothingKeepsReviewAndRebuildSeesTheEdit() async throws {
        let store = transferStore()
        let model = try await readyTransferModel(store)
        XCTAssertTrue(model.beginTransferReview(snapshot: store.snapshot))

        store.setCustomName(newMain.start, in: slotB, name: "typedMeanwhile")
        XCTAssertEqual(model.applyTransfer(in: store), .refused(.destinationChanged([newMain.start])))
        XCTAssertNotNil(model.transferReview, "a refusal keeps the review open")
        let destination = store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: newMain.start)]
        XCTAssertEqual(destination?.customName, "typedMeanwhile")
        XCTAssertNil(destination?.customComment)

        XCTAssertTrue(model.rebuildTransferPreview(snapshot: store.snapshot))
        let plan = try XCTUnwrap(model.transferReview?.plan)
        XCTAssertEqual(plan.changes.map(\.newName), [nil], "only the comment can still move")
        XCTAssertEqual(plan.changes.map(\.newComment), ["entry point"])
        XCTAssertEqual(Set(plan.conflicts.map(\.destinationAddress)), [newMain.start, newChanged.start])

        model.run()
        XCTAssertNil(model.transferReview, "a re-run discards the review")
    }

}

// MARK: - Test doubles

/// A one-shot gate a worker can await off the main actor.
private final class CompareWorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuation = lock.withLock {
            isOpen = true
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume()
    }
}

/// Thread-safe record of worker invocations.
private final class CompareWorkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var finished = false
    private var cancelled = false

    var calls: Int { lock.withLock { callCount } }
    var staleFinished: Bool { lock.withLock { finished } }
    var staleWasCancelled: Bool { lock.withLock { cancelled } }

    func begin() -> Int {
        lock.withLock {
            defer { callCount += 1 }
            return callCount
        }
    }

    func finishStale(cancelled wasCancelled: Bool) {
        lock.withLock {
            finished = true
            cancelled = wasCancelled
        }
    }
}
