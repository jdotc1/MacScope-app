import Foundation
import XCTest
@testable import MacScope

/// RX-01 §5.3: `WorkspaceStore.commitAnnotationTransfer` against a real store with no window
/// (fallback `UndoManager`), plus the §2.8 headless acceptance runner. Most fixtures are synthetic
/// two-image snapshots run through the real fingerprint adapter and matcher (the
/// `VersionCompareViewModelTests` pattern); the reanalysis-in-flight case uses on-disk TinyMachO
/// images loaded through `loadAdditionalBinary`, because only a real file can be reanalyzed.
@MainActor
final class WorkspaceStoreAnnotationTransferTests: XCTestCase {
    private let slotB = ImageSlot(rawValue: 1)

    // MARK: - Synthetic two-image fixture

    private struct FixtureFunction {
        let id = UUID()
        let name: String
        let start: UInt64
        let size: UInt64
    }

    /// Old (primary) and new (slot 1). `_changed` grew; `sub_*` are generated names.
    private let oldMain = FixtureFunction(name: "_main", start: 0x1000, size: 0x40)
    private let oldChanged = FixtureFunction(name: "_changed", start: 0x1100, size: 0x40)
    private let oldAlpha = FixtureFunction(name: "_alpha", start: 0x1200, size: 0x40)
    private let oldGenerated = FixtureFunction(name: "sub_1300", start: 0x1300, size: 0x40)
    private let oldKeep = FixtureFunction(name: "_keep", start: 0x1400, size: 0x40)
    private let newMain = FixtureFunction(name: "_main", start: 0x2000, size: 0x40)
    private let newChanged = FixtureFunction(name: "_changed", start: 0x2100, size: 0x80)
    private let newAlpha = FixtureFunction(name: "_alpha", start: 0x2200, size: 0x40)
    private let newGenerated = FixtureFunction(name: "sub_2300", start: 0x2300, size: 0x40)
    private let newKeep = FixtureFunction(name: "_keep", start: 0x2400, size: 0x40)

    /// Decomposed "é" (e + U+0301) and a multi-line comment with a non-ASCII scalar: a
    /// normalizing round trip would change these bytes.
    private let mainName = "cafe\u{301}_init"
    private let mainComment = "entry point\nsecond line \u{2713}"

    private func analysis(_ functions: [FixtureFunction], base: UInt64, fill: UInt8) -> ImageAnalysis {
        var analysis = ImageAnalysis()
        analysis.functions = functions.map {
            FunctionSummary(id: $0.id, name: $0.name, startAddress: $0.start,
                            endAddress: $0.start + $0.size, confidence: 1)
        }
        analysis.sections = [SectionSummary(id: UUID(), name: "__text", address: base, size: 0x1000,
                                            fileOffset: 0, isExecutable: true)]
        analysis.imageBytes = Data(repeating: fill, count: 256)
        return analysis
    }

    private func override(_ name: String?, _ comment: String? = nil) -> AddressOverride {
        var value = AddressOverride()
        value.customName = name
        value.customComment = comment
        return value
    }

    /// Old: three authored names and two authored entry comments on high-confidence pairs, one
    /// authored name on `_keep`. New: `_keep` already has an authored name (the conflict).
    private func fixtureSnapshot() -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(
            binary: BinaryImage(id: UUID(), name: "v1", path: "/tmp/rx01b-v1", kind: "executable",
                                architecture: "arm64", slot: .primary),
            analysis: analysis([oldMain, oldChanged, oldAlpha, oldGenerated, oldKeep], base: 0x1000, fill: 0x11))
        snapshot.insertImage(
            binary: BinaryImage(id: UUID(), name: "v2", path: "/tmp/rx01b-v2", kind: "executable",
                                architecture: "arm64", slot: slotB),
            analysis: analysis([newMain, newChanged, newAlpha, newGenerated, newKeep], base: 0x2000, fill: 0x22))
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: oldMain.start)] = override(mainName, mainComment)
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: oldChanged.start)] = override("changedRenamed")
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: oldAlpha.start)] = override("alphaRenamed", "alpha comment")
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: oldKeep.start)] = override("keepTheirs")
        snapshot.addressOverrides[ImageAddress(slot: slotB, address: newKeep.start)] = override("mine")
        return snapshot
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(workspaceName: "Transfer", snapshot: fixtureSnapshot(),
                       engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private struct Prepared {
        let pair: VersionComparePair
        let candidates: [AnnotationTransferCandidate]
        let preview: AnnotationTransferPreview
        var request: AnnotationTransferCommitRequest { .init(pair: pair, preview: preview) }
    }

    /// The review → plan step with the default (high-confidence) selection, or `selected`.
    private func prepare(_ store: WorkspaceStore, selected: Set<String>? = nil) throws -> Prepared {
        let images = VersionCompareViewModel.images(in: store.snapshot)
        XCTAssertGreaterThanOrEqual(images.count, 2)
        let pair = VersionComparePair(old: images[0], new: images[1])
        let computation = try VersionCompareComputation.build(
            old: try XCTUnwrap(store.snapshot.analysis(in: pair.old.slot)),
            new: try XCTUnwrap(store.snapshot.analysis(in: pair.new.slot)))
        let candidates = AnnotationTransferCandidates.build(
            result: computation.result, oldSlot: pair.old.slot, newSlot: pair.new.slot, snapshot: store.snapshot)
        let preview = try AnnotationTransferCandidates.preview(
            candidates, selected: selected ?? AnnotationTransferCandidates.defaultSelection(candidates),
            oldSlot: pair.old.slot, newSlot: pair.new.slot, snapshot: store.snapshot)
        return Prepared(pair: pair, candidates: candidates, preview: preview)
    }

    private func partition(_ store: WorkspaceStore, _ slot: ImageSlot) -> [UInt64: AddressOverride] {
        var result: [UInt64: AddressOverride] = [:]
        for (key, value) in store.snapshot.addressOverrides where key.slot == slot { result[key.address] = value }
        return result
    }

    private func destination(_ store: WorkspaceStore, _ address: UInt64) -> AddressOverride? {
        store.snapshot.addressOverrides[ImageAddress(slot: slotB, address: address)]
    }

    /// A refusal must write nothing and register no Undo.
    private func assertRefused(_ store: WorkspaceStore, _ request: AnnotationTransferCommitRequest,
                               _ expected: AnnotationTransferRefusal,
                               file: StaticString = #filePath, line: UInt = #line) {
        let overrides = store.snapshot.addressOverrides
        let canUndo = store.undoManager.canUndo
        let undoName = store.undoManager.undoActionName
        XCTAssertEqual(store.commitAnnotationTransfer(request), .refused(expected), file: file, line: line)
        XCTAssertEqual(store.snapshot.addressOverrides, overrides, "a refusal writes nothing", file: file, line: line)
        XCTAssertEqual(store.undoManager.canUndo, canUndo, file: file, line: line)
        XCTAssertEqual(store.undoManager.undoActionName, undoName, file: file, line: line)
    }

    /// Same slot, new owner identity (what replacing the image in that slot produces).
    private func replaceBinaryID(_ store: WorkspaceStore, at index: Int) {
        let old = store.snapshot.binaries[index]
        store.snapshot.binaries[index] = BinaryImage(id: UUID(), name: old.name, path: old.path, kind: old.kind,
                                                     architecture: old.architecture, slot: old.slot)
    }

    // MARK: - Commit and Undo

    func testThreeNamesAndTwoCommentsTransferInOneUndo() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        XCTAssertEqual(prepared.preview.nameCount, 3)
        XCTAssertEqual(prepared.preview.commentCount, 2)
        XCTAssertFalse(store.undoManager.canUndo)
        let before = partition(store, slotB)

        XCTAssertEqual(store.commitAnnotationTransfer(prepared.request), .applied(names: 3, comments: 2, conflicts: 1))
        XCTAssertEqual(destination(store, newMain.start)?.customName, mainName)
        XCTAssertEqual(destination(store, newMain.start)?.customComment, mainComment)
        XCTAssertEqual(destination(store, newChanged.start)?.customName, "changedRenamed")
        XCTAssertNil(destination(store, newChanged.start)?.customComment)
        XCTAssertEqual(destination(store, newAlpha.start)?.customName, "alphaRenamed")
        XCTAssertEqual(destination(store, newAlpha.start)?.customComment, "alpha comment")
        XCTAssertEqual(partition(store, .primary), partition(makeStore(), .primary), "the source image is untouched")
        let after = partition(store, slotB)
        XCTAssertEqual(store.undoManager.undoActionName, WorkspaceStore.annotationTransferActionName)

        store.undoManager.undo()
        XCTAssertEqual(partition(store, slotB), before, "one Undo reverts the whole transfer")
        XCTAssertFalse(store.undoManager.canUndo, "the transfer was exactly one Undo step")
        store.undoManager.redo()
        XCTAssertEqual(partition(store, slotB), after, "Redo restores the applied state")
    }

    func testAuthoredConflictIsNeverOverwrittenAndIsReported() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        XCTAssertEqual(prepared.preview.conflicts.map(\.destinationAddress), [newKeep.start])
        XCTAssertEqual(prepared.preview.conflicts.map(\.kind), [.authored])

        XCTAssertEqual(store.commitAnnotationTransfer(prepared.request), .applied(names: 3, comments: 2, conflicts: 1))
        XCTAssertEqual(destination(store, newKeep.start), override("mine"), "authored destination text is kept")
    }

    func testGeneratedSubNamesNeverTransfer() throws {
        let store = makeStore()
        // Select every non-skipped row, not only the high-confidence default.
        let all = try prepare(store)
        let selectAll = Set(all.candidates.filter { $0.skip == nil }.map(\.id))
        let prepared = try prepare(store, selected: selectAll)
        XCTAssertFalse(prepared.candidates.contains { $0.oldAddress == oldGenerated.start },
                       "an analysis-generated name is not authored text, so it is never a candidate")
        XCTAssertFalse(prepared.preview.changes.contains { $0.newName?.hasPrefix("sub_") == true })

        _ = store.commitAnnotationTransfer(prepared.request)
        XCTAssertNil(destination(store, newGenerated.start))
        XCTAssertFalse(partition(store, slotB).values.contains { $0.customName?.hasPrefix("sub_") == true })
    }

    func testNothingToApplyRegistersNoUndoAndLeavesDocumentClean() throws {
        let store = makeStore()
        let prepared = try prepare(store, selected: [])
        XCTAssertTrue(prepared.preview.changes.isEmpty)
        let overrides = store.snapshot.addressOverrides
        let dirty = store.isDirty

        XCTAssertEqual(store.commitAnnotationTransfer(prepared.request), .nothingToApply(conflicts: 0))
        XCTAssertEqual(store.snapshot.addressOverrides, overrides)
        XCTAssertFalse(store.undoManager.canUndo)
        XCTAssertEqual(store.isDirty, dirty)
    }

    func testEditElsewhereBetweenPreviewAndCommitIsAccepted() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        // `sub_2300` / `sub_1300` are not examined by the preview.
        store.setCustomName(newGenerated.start, in: slotB, name: "unrelatedNew")
        store.setCustomComment(oldGenerated.start, in: .primary, comment: "unrelated old")

        XCTAssertEqual(store.commitAnnotationTransfer(prepared.request), .applied(names: 3, comments: 2, conflicts: 1))
        XCTAssertEqual(destination(store, newGenerated.start)?.customName, "unrelatedNew")
    }

    // MARK: - Refusals (each writes nothing)

    func testDestinationEditAfterPreviewIsRefused() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        store.setCustomName(newMain.start, in: slotB, name: "typedMeanwhile")
        assertRefused(store, prepared.request, .destinationChanged([newMain.start]))
        XCTAssertEqual(destination(store, newMain.start)?.customName, "typedMeanwhile")
        XCTAssertNil(destination(store, newAlpha.start), "no other destination was written either")
    }

    func testSourceEditAfterPreviewIsRefused() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        store.setCustomComment(oldChanged.start, in: .primary, comment: "added after preview")
        assertRefused(store, prepared.request, .sourceChanged([oldChanged.start]))
    }

    func testReplacedDestinationImageIsRefused() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        let index = try XCTUnwrap(store.snapshot.binaries.firstIndex { $0.slot == slotB })
        replaceBinaryID(store, at: index)
        assertRefused(store, prepared.request, .imageReplaced(.new))
    }

    func testReplacedSourceImageIsRefused() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        let index = try XCTUnwrap(store.snapshot.binaries.firstIndex { $0.slot == .primary })
        replaceBinaryID(store, at: index)
        assertRefused(store, prepared.request, .imageReplaced(.old))
    }

    func testChangedDestinationAnalysisFingerprintIsRefused() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        XCTAssertNil(prepared.pair.new.analysisFingerprint, "synthetic fixture starts as a legacy (nil) fingerprint")
        let real = try AnalysisEngine().analyze(url: try TinyMachO.make(code: Self.v1Code, symbols: Self.v1Symbols).write())
        let fingerprint = try XCTUnwrap(real.analysis(in: .primary)?.analysisInputFingerprint)
        store.snapshot.mutateAnalysis(in: slotB) { $0.analysisInputFingerprint = fingerprint }
        assertRefused(store, prepared.request, .analysisChanged(.new))
    }

    func testDestinationNoLongerFunctionStartIsRefused() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        store.snapshot.mutateAnalysis(in: slotB) { analysis in
            analysis.functions.removeAll { $0.startAddress == self.newAlpha.start }
        }
        assertRefused(store, prepared.request, .destinationNotFunctionStart([newAlpha.start]))
    }

    func testSameSlotIsRefused() throws {
        let store = makeStore()
        let prepared = try prepare(store)
        let same = VersionComparePair(old: prepared.pair.new, new: prepared.pair.new)
        assertRefused(store, .init(pair: same, preview: prepared.preview), .sameImage)
    }

    func testReanalysisInFlightIsRefused() async throws {
        let engine = AnalysisEngine()
        let v1 = try TinyMachO.make(code: Self.v1Code, symbols: Self.v1Symbols).write()
        let v2 = try TinyMachO.make(code: Self.v2Code, symbols: Self.v2Symbols).write()
        defer {
            try? FileManager.default.removeItem(at: v1.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: v2.deletingLastPathComponent())
        }
        let store = WorkspaceStore(workspaceName: "Transfer reanalysis", snapshot: try engine.analyze(url: v1),
                                   engine: engine, autosaveScheduler: nil)
        await store.loadAdditionalBinary(url: v2)
        await store.awaitCurrentRehydrationForTesting()
        let newSlot = try XCTUnwrap(store.snapshot.binaries.map(\.slot).first { $0 != .primary })
        let oldStart = try XCTUnwrap(store.snapshot.analysis(in: .primary)?.functions.first?.startAddress)
        store.snapshot.addressOverrides[ImageAddress(slot: .primary, address: oldStart)] = override("renamedEntry")
        let prepared = try prepare(store)
        let newStart = try XCTUnwrap(store.snapshot.analysis(in: newSlot)?.functions.last?.startAddress)

        store.setMarkAsProcedure(newStart + 4, in: newSlot, true)
        XCTAssertTrue(store.isReanalyzing, "the structural edit retained a reanalysis task for the new image")
        assertRefused(store, prepared.request, .reanalysisInFlight(.new))
        await store.awaitPendingReanalysis()
    }

    // MARK: - Save and reopen

    func testSaveReopenKeepsTransferredTextByteExactly() throws {
        let store = makeStore()
        XCTAssertEqual(store.commitAnnotationTransfer(try prepare(store).request),
                       .applied(names: 3, comments: 2, conflicts: 1))
        let expected = partition(store, slotB)

        // Package writer / reader (the document Save and Open path).
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rx01b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("Transfer.mscope", isDirectory: true)
        XCTAssertTrue(store.writeDocumentPackage(to: url), store.saveError ?? "save failed")
        let reopened = try WorkspaceStore.restoredPackage(from: url, scheduleDurableRecovery: false)
        assertByteExact(reopened.snapshot, expected)
        XCTAssertEqual(HeadlessWorkspaceAnnotationTransferAcceptance.authoringDigestBySlot(reopened.snapshot),
                       HeadlessWorkspaceAnnotationTransferAcceptance.authoringDigestBySlot(store.snapshot))

        // SQLite workspace state.
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let persisted = try store.saveWorkspace(to: database)
        let loaded = try XCTUnwrap(database.loadSnapshot(workspaceID: try XCTUnwrap(persisted.workspace.id)))
        assertByteExact(loaded, expected)
    }

    private func assertByteExact(_ snapshot: WorkspaceSnapshot, _ expected: [UInt64: AddressOverride],
                                 file: StaticString = #filePath, line: UInt = #line) {
        var actual: [UInt64: AddressOverride] = [:]
        for (key, value) in snapshot.addressOverrides where key.slot == slotB { actual[key.address] = value }
        XCTAssertEqual(actual.keys.sorted(), expected.keys.sorted(), file: file, line: line)
        for (address, value) in expected {
            XCTAssertEqual(actual[address]?.customName.map { Array($0.utf8) }, value.customName.map { Array($0.utf8) },
                           "name bytes at \(address.hexAddress)", file: file, line: line)
            XCTAssertEqual(actual[address]?.customComment.map { Array($0.utf8) }, value.customComment.map { Array($0.utf8) },
                           "comment bytes at \(address.hexAddress)", file: file, line: line)
        }
    }

    // MARK: - Headless acceptance runner (§2.8)

    func testHeadlessAcceptanceRunsPreviewCommitSaveReopenAndReportsPassed() async throws {
        let store = makeStore()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("rx01b-accept-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("Accept.mscope", isDirectory: true)

        let result = try await HeadlessWorkspaceAnnotationTransferAcceptance.run(store: store) { store in
            guard store.writeDocumentPackage(to: url) else {
                throw HeadlessWorkspaceAnnotationTransferAcceptance.Failure(description: store.saveError ?? "save")
            }
            return (url, try WorkspaceStore.restoredPackage(from: url, scheduleDurableRecovery: false).snapshot)
        }
        guard case let .object(fields) = result else { return XCTFail("expected an object, got \(result)") }
        XCTAssertEqual(fields["passed"], .bool(true), "failures: \(String(describing: fields["failures"]))")
        XCTAssertEqual(fields["outcome"], .object(["kind": .string("applied"), "names": .int(3),
                                                   "comments": .int(2), "conflicts": .int(1)]))
        XCTAssertEqual(fields["oldSlot"], .int(0))
        XCTAssertEqual(fields["newSlot"], .int(1))
        XCTAssertEqual(fields["undoRestoresBefore"], .bool(true))
        XCTAssertEqual(fields["redoRestoresAfter"], .bool(true))
        XCTAssertEqual(fields["reopenMatches"], .bool(true))
        XCTAssertEqual(fields["conflicts"], .array([.object([
            "destinationAddress": .string(newKeep.start.hexAddress), "field": .string("name"), "kind": .string("authored")
        ])]))
        XCTAssertNotEqual(fields["destinationDigestBefore"], fields["destinationDigestAfter"])
        XCTAssertEqual(destination(store, newMain.start)?.customName, mainName, "the runner leaves the applied state")
        // The result is machine-readable JSON.
        XCTAssertNoThrow(try result.jsonData())
    }

    func testHeadlessRequestAdmitsAnnotationTransferAction() throws {
        let data = try ScriptValue.object([
            "action": .string("annotation-transfer"), "workspace": .string("/tmp/rx01.mscope"),
            "output": .string("/tmp/rx01-out")
        ]).jsonData()
        XCTAssertEqual(try HeadlessWorkspaceAcceptance.Request.decode(data).action, "annotation-transfer")
    }

    // MARK: - TinyMachO versions

    /// v1: `_main`, `_alpha`, `_beta` (mov w0,#n ; ret each). v2 prepends `_fresh`, shifting all.
    private static let v1Code = Data([
        0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6,   // _main:  mov w0,#0 ; ret
        0x20, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6,   // _alpha: mov w0,#1 ; ret
        0x40, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6    // _beta:  mov w0,#2 ; ret
    ])
    private static let v1Symbols: [(name: String, offset: Int)] = [("_main", 0), ("_alpha", 8), ("_beta", 16)]
    private static let v2Code = Data([0x20, 0x01, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]) + v1Code
    private static let v2Symbols: [(name: String, offset: Int)] = [("_fresh", 0), ("_main", 8), ("_alpha", 16), ("_beta", 24)]
}
