import Combine
import XCTest
@testable import MacScope

private actor ListingPreparationGate {
    private var queuedStarts: [DisassemblyListingRequest] = []
    private var startWaiter: CheckedContinuation<DisassemblyListingRequest, Error>?
    private var completions: [UInt64: CheckedContinuation<PreparedDisassemblyListing, Error>] = [:]
    private var startTimeout: Task<Void, Never>?
    private var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var canceledRevisions: Set<UInt64> = []

    func run(_ request: DisassemblyListingRequest) async throws -> PreparedDisassemblyListing {
        let result: PreparedDisassemblyListing = try await withCheckedThrowingContinuation { continuation in
            completions[request.revision] = continuation
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
            if let waiter = startWaiter {
                startWaiter = nil
                startTimeout?.cancel()
                startTimeout = nil
                waiter.resume(returning: request)
            } else {
                queuedStarts.append(request)
            }
        }
        if Task.isCancelled { canceledRevisions.insert(request.revision) }
        return result
    }

    func nextStart() async throws -> DisassemblyListingRequest {
        if !queuedStarts.isEmpty { return queuedStarts.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            startWaiter = continuation
            startTimeout = Task {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                self.startWaiter?.resume(throwing: GateError.startTimedOut)
                self.startWaiter = nil
                self.startTimeout = nil
            }
        }
    }

    private enum GateError: Error { case startTimedOut }

    // Intentionally ignores Task cancellation: exercises the generation fence.
    func finish(_ request: DisassemblyListingRequest) throws {
        let listing = try PreparedDisassemblyListing.prepare(request)
        activeCount -= 1
        completions.removeValue(forKey: request.revision)?.resume(returning: listing)
    }
}

final class DisassemblyListingCacheTests: XCTestCase {
    private func snapshot(slot: ImageSlot = .primary, owner: UUID = UUID(), name: String = "_entry") -> WorkspaceSnapshot {
        let binary = BinaryImage(id: owner, name: "same", path: "/tmp/same", kind: "exe",
                                 architecture: "arm64", slot: slot)
        var analysis = ImageAnalysis()
        analysis.instructions = [
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "bl",
                           operands: "0x1000", hasBreakpoint: false, comment: "decoder"),
            InstructionRow(address: 0x1000, bytes: "41 42 00 00", mnemonic: "nop",
                           operands: "", hasBreakpoint: false, comment: "decoder")
        ]
        analysis.functions = [FunctionSummary(id: UUID(), name: name, startAddress: 0x1000,
                                             endAddress: 0x1008, confidence: 1)]
        analysis.sections = [SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000,
                                            size: 8, fileOffset: 0, isExecutable: true)]
        analysis.hexBytes = Data([0x41, 0x42, 0, 0, 0, 0, 0, 0])
        return WorkspaceSnapshot(binaries: [binary], analysisBySlot: [slot: analysis])
    }

    func testPreparationIsByteIdenticalToFrozenBaselineAcrossAllEncodings() throws {
        var snapshot = snapshot()
        let target = ImageAddress(slot: .primary, address: 0x1000)
        snapshot.addressOverrides[target] = AddressOverride(
            customName: "renamed", customComment: "a prefix\ncomment", tag: "tag",
            colorTag: .red, isData: true, appliedTypeName: "uint8_t",
            operandFormat: .hex,
            dataShape: DataShapeOverride(kind: .string, isNullTerminated: false, stringLength: 4),
            patch: BytePatch(bytes: [0x43])
        )
        snapshot.addressOverrides[ImageAddress(slot: .primary, address: 0x1004)] = AddressOverride(isUndefined: true)
        for encoding in StringDisplayEncoding.allCases {
            let expected = UncachedDisassemblyListingOracle.buildResolved(
                snapshot: snapshot, stringEncoding: encoding, slot: .primary
            )
            let actual = try PreparedDisassemblyListing.prepare(.init(
                revision: 1, snapshot: snapshot, slot: .primary, encodingRaw: encoding.rawValue
            ))
            XCTAssertEqual(actual.indexedRows.map(\.row), expected.rows)
            XCTAssertEqual(actual.resolved, expected.resolved)
            XCTAssertEqual(actual.indexedRows.map(\.id), expected.rows.map(\.id))
            XCTAssertEqual(actual.indexedRows.map(\.index), Array(expected.rows.indices))
        }
    }

    func testBuilderCancellationInterruptsRowPreparation() {
        var snapshot = snapshot()
        snapshot.analysisBySlot[.primary]?.instructions = (0..<2048).map { index in
            InstructionRow(address: UInt64(index * 4), bytes: "00", mnemonic: "nop",
                           operands: "", hasBreakpoint: false, comment: nil)
        }
        var checkpoints = 0
        XCTAssertThrowsError(try DisassemblyListingBuilder.buildResolved(
            snapshot: snapshot, checkCancellation: {
                checkpoints += 1
                if checkpoints == 12 { throw CancellationError() }
            }
        )) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checkpoints, 12)
    }

    @MainActor
    func testOnlyLatestPendingRevisionInstallsWhenCanceledWorkerCompletes() async throws {
        let gate = ListingPreparationGate()
        let cache = DisassemblyListingCache { try await gate.run($0) }
        var snapshot = snapshot()
        cache.snapshotDidChange(snapshot, slot: .primary, encodingRaw: "utf8")
        let first = try await gate.nextStart()
        for index in 1...20 {
            snapshot.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] =
                AddressOverride(customComment: "revision \(index)")
            cache.snapshotDidChange(snapshot, slot: .primary, encodingRaw: "utf8")
        }
        XCTAssertEqual(cache.preparationCount, 1)
        try await gate.finish(first)
        let latest = try await gate.nextStart()
        XCTAssertEqual(latest.revision, cache.revision)
        XCTAssertEqual(cache.listing.revision, 0)
        XCTAssertEqual(cache.preparationCount, 2)
        let canceledRevisions = await gate.canceledRevisions
        XCTAssertTrue(canceledRevisions.contains(first.revision))
        let installed = expectation(description: "latest revision installs on main actor")
        let token = cache.$listing.filter { $0.revision == latest.revision }.sink { _ in installed.fulfill() }
        try await gate.finish(latest)
        await fulfillment(of: [installed], timeout: 2)
        withExtendedLifetime(token) {}
        XCTAssertEqual(cache.listing.resolved[0x1000]?.inlineComment, "revision 20")
        let maximum = await gate.maximumActiveCount
        XCTAssertEqual(maximum, 1)
    }

    @MainActor
    func testSamePathDifferentSlotsAndOwnersCannotInstallStaleRows() async throws {
        let gate = ListingPreparationGate()
        let cache = DisassemblyListingCache { try await gate.run($0) }
        let primary = snapshot()
        let otherSlot = ImageSlot(rawValue: 1)
        let secondary = snapshot(slot: otherSlot, name: "_other")
        var combined = primary
        combined.binaries += secondary.binaries
        combined.analysisBySlot[otherSlot] = secondary.analysisBySlot[otherSlot]
        cache.snapshotDidChange(combined, slot: .primary, encodingRaw: "utf8")
        let first = try await gate.nextStart()
        cache.presentationDidChange(slot: otherSlot, encodingRaw: "utf8")
        try await gate.finish(first)
        let second = try await gate.nextStart()
        XCTAssertEqual(second.slot, otherSlot)
        XCTAssertEqual(second.ownerBinaryID, secondary.binaries.first?.id)
        XCTAssertTrue(cache.listing.indexedRows.isEmpty)
        let installed = expectation(description: "secondary owner installs")
        let token = cache.$listing.filter { $0.revision == second.revision }.sink { _ in installed.fulfill() }
        try await gate.finish(second)
        await fulfillment(of: [installed], timeout: 2)
        withExtendedLifetime(token) {}
        XCTAssertEqual(cache.listing.resolved[0x1004]?.row.operands, "_other")
        // Same slot/path but a new binary UUID is a new owner, and clears old rows.
        let replacement = snapshot(slot: otherSlot, name: "_replacement")
        cache.snapshotDidChange(replacement, slot: otherSlot, encodingRaw: "utf8")
        XCTAssertTrue(cache.listing.indexedRows.isEmpty)
        let third = try await gate.nextStart()
        let rejected = expectation(description: "canceled owner must never publish")
        rejected.isInverted = true
        let rejectionToken = cache.$listing.filter { $0.revision == third.revision }
            .sink { _ in rejected.fulfill() }
        cache.cancel()
        try await gate.finish(third)
        await fulfillment(of: [rejected], timeout: 0.1)
        withExtendedLifetime(rejectionToken) {}
        XCTAssertEqual(cache.listing.revision, 0)
    }

    @MainActor
    func testSnapshotEventsCoverEveryListingInvalidatorWithoutValueHashing() async throws {
        let gate = ListingPreparationGate()
        let cache = DisassemblyListingCache { try await gate.run($0) }
        var snapshot = snapshot()
        cache.snapshotDidChange(snapshot, slot: .primary, encodingRaw: "utf8")
        let first = try await gate.nextStart()
        let mutations: [(inout WorkspaceSnapshot) -> Void] = [
            { $0.analysisBySlot[.primary]?.instructions[0].mnemonic = "b" },
            { $0.analysisBySlot[.primary]?.functions[0].name = "new function" },
            { $0.analysisBySlot[.primary]?.symbols = [SymbolSummary(id: UUID(), name: "symbol", address: 0x1004, kind: "function", libraryName: nil)] },
            { $0.analysisBySlot[.primary]?.sections[0].name = "new section" },
            { $0.analysisBySlot[.primary]?.hexBytes = Data([1, 2, 3]) },
            { $0.analysisBySlot[.primary]?.imageBytes = Data([4, 5, 6]) },
            { $0.analysisBySlot[.primary]?.sourceLines = [SourceLineEntry(address: 0x1000, file: "example.c", line: 9, column: 1, endSequence: false)] },
            { $0.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = AddressOverride(customName: "name") },
            { $0.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = AddressOverride(customComment: "comment") },
            { $0.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = AddressOverride(tag: "tag", colorTag: .red) },
            { $0.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = AddressOverride(isData: true, appliedTypeName: "uint32_t") },
            { $0.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = AddressOverride(operandFormat: .hex) },
            { $0.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = AddressOverride(dataShape: DataShapeOverride(kind: .alignment)) },
            { $0.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = AddressOverride(isUndefined: true) },
            { $0.addressOverrides[ImageAddress(slot: .primary, address: 0x1000)] = AddressOverride(patch: BytePatch(bytes: [0xFF])) },
            { $0.typeDefinitions = [TypeDefinition(kind: .struct, name: "AddedType")] },
            { $0.segmentOverrides = [SegmentOverride(originalName: "__TEXT,__text", displayName: "renamed")] },
            { $0.binaries[0] = BinaryImage(id: UUID(), name: "same", path: "/tmp/same", kind: "exe", architecture: "arm64", slot: .primary) }
        ]
        for mutation in mutations {
            let before = cache.revision
            mutation(&snapshot)
            cache.snapshotDidChange(snapshot, slot: .primary, encodingRaw: "utf8")
            XCTAssertEqual(cache.revision, before + 1)
        }
        let beforeEncoding = cache.revision
        cache.presentationDidChange(slot: .primary, encodingRaw: "hex")
        XCTAssertEqual(cache.revision, beforeEncoding + 1)
        try await gate.finish(first)
        let latest = try await gate.nextStart()
        XCTAssertEqual(latest.encodingRaw, "hex")
        cache.cancel()
        try await gate.finish(latest)
    }

    @MainActor
    func testSelectionAndLivePCAreCheapOverlaysAndDoNotRequestPreparation() async throws {
        let gate = ListingPreparationGate()
        let cache = DisassemblyListingCache { try await gate.run($0) }
        let store = WorkspaceStore(workspaceName: "listing", snapshot: snapshot(),
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        // Exactly the publisher that feeds DisassemblyView, including its initial emission.
        let observation = store.$snapshot.sink { candidate in
            cache.snapshotDidChange(candidate, slot: store.focusedImageSlot, encodingRaw: "utf8")
        }
        let request = try await gate.nextStart()
        let installed = expectation(description: "first installation")
        let token = cache.$listing.filter { $0.revision == request.revision }.sink { _ in installed.fulfill() }
        try await gate.finish(request)
        await fulfillment(of: [installed], timeout: 2)
        withExtendedLifetime(token) {}
        let revision = cache.revision
        for address in [UInt64(0x1000), 0x1004, 0x1000] {
            let selection = ImageAddress(slot: .primary, address: address)
            store.selectInstruction(address)
            store.updateLiveProgramCounterTarget(selection)
            XCTAssertEqual(store.selectedImageAddress, selection)
            XCTAssertEqual(store.liveProgramCounterTarget, selection)
            XCTAssertEqual(DisassemblyScrollAnchor.selectionTarget(selection, focusedSlot: .primary,
                containsInstruction: { cache.listing.resolved[$0] != nil }), selection)
            XCTAssertNotNil(cache.listing.resolved[address])
            // The view compares a qualified PC/selection with each row; PC is never
            // part of the retained preparation request or resolved payload.
            XCTAssertFalse(cache.listing.resolved[address]?.isLiveProgramCounter ?? true)
        }
        store.updateLiveProgramCounterTarget(nil)
        cache.presentationDidChange(slot: .primary, encodingRaw: "utf8")
        XCTAssertEqual(cache.revision, revision)
        XCTAssertEqual(cache.preparationCount, 1)
        withExtendedLifetime(observation) {}
    }
}
