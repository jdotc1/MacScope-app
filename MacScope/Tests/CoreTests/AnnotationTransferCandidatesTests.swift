import Foundation
import XCTest
@testable import MacScope

/// RX-01 candidate builder: match result + both images' authored overrides → review rows and
/// planner inputs. Synthetic `WorkspaceSnapshot`s; where the matcher's own behaviour is the point
/// (ambiguity, added/removed, address coincidence) the fixtures run through the real fingerprint
/// adapter and matcher via `VersionCompareComputation.build`.
final class AnnotationTransferCandidatesTests: XCTestCase {
    private let oldSlot = ImageSlot.primary
    private let newSlot = ImageSlot(rawValue: 1)

    // MARK: - Fixtures

    private struct Fn {
        let id = UUID()
        let name: String
        let start: UInt64
        var size: UInt64 = 0x40
        /// Instruction lines ("mnemonic operands"), 4 bytes apart from `start`.
        var body: [String] = []
    }

    private func analysis(_ functions: [Fn]) -> ImageAnalysis {
        var analysis = ImageAnalysis()
        analysis.functions = functions.map {
            FunctionSummary(id: $0.id, name: $0.name, startAddress: $0.start, endAddress: $0.start + $0.size, confidence: 1)
        }
        analysis.instructions = functions.flatMap { function in
            function.body.enumerated().map { index, line in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                return InstructionRow(address: function.start + UInt64(index * 4), bytes: "00 00 00 00",
                                      mnemonic: parts[0], operands: parts.count > 1 ? parts[1] : "",
                                      hasBreakpoint: false, comment: nil)
            }
        }
        return analysis
    }

    private func snapshot(old: [Fn], new: [Fn],
                          oldOverrides: [UInt64: AddressOverride] = [:],
                          newOverrides: [UInt64: AddressOverride] = [:]) -> WorkspaceSnapshot {
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "v1", path: "/tmp/v1", kind: "executable",
                                                 architecture: "arm64", slot: oldSlot),
                             analysis: analysis(old))
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "v2", path: "/tmp/v2", kind: "executable",
                                                 architecture: "arm64", slot: newSlot),
                             analysis: analysis(new))
        for (address, value) in oldOverrides { snapshot.addressOverrides[ImageAddress(slot: oldSlot, address: address)] = value }
        for (address, value) in newOverrides { snapshot.addressOverrides[ImageAddress(slot: newSlot, address: address)] = value }
        return snapshot
    }

    private func named(_ name: String?, _ comment: String? = nil) -> AddressOverride {
        AddressOverride(customName: name, customComment: comment)
    }

    private func match(_ old: Fn, _ new: Fn, _ basis: FunctionVersionMatchBasis,
                       _ confidence: FunctionVersionMatchConfidence,
                       differences: [FunctionVersionDifference] = []) -> FunctionVersionMatch {
        FunctionVersionMatch(oldID: old.id.uuidString, newID: new.id.uuidString,
                             oldAddress: old.start, newAddress: new.start, basis: basis, confidence: confidence,
                             propagatedFromOldCallerID: nil, propagatedFromNewCallerID: nil,
                             differences: differences, symbolNameChanged: old.name != new.name)
    }

    private func result(_ matches: [FunctionVersionMatch]) -> FunctionVersionMatchResult {
        FunctionVersionMatchResult(matches: matches, addedIDs: [], removedIDs: [], unresolved: [], manualPins: [])
    }

    private func matched(_ snapshot: WorkspaceSnapshot) throws -> FunctionVersionMatchResult {
        try VersionCompareComputation.build(old: XCTUnwrap(snapshot.analysis(in: oldSlot)),
                                            new: XCTUnwrap(snapshot.analysis(in: newSlot))).result
    }

    private func build(_ result: FunctionVersionMatchResult, _ snapshot: WorkspaceSnapshot) -> [AnnotationTransferCandidate] {
        AnnotationTransferCandidates.build(result: result, oldSlot: oldSlot, newSlot: newSlot, snapshot: snapshot)
    }

    /// Distinct, substantial (>= 3 instruction) bodies.
    private func body(_ seed: Int) -> [String] {
        ["sub sp, sp, #0x\(String(seed, radix: 16))", "eor w\(seed % 28), w0, w1", "add x0, x0, x1", "ret"]
    }

    // MARK: - What becomes a candidate

    func testOnlyAnnotatedSourcesBecomeCandidates() throws {
        let olds = (0..<5).map { Fn(name: "_f\($0)", start: 0x1000 + UInt64($0) * 0x100) }
        let news = (0..<5).map { Fn(name: "_f\($0)", start: 0x8000 + UInt64($0) * 0x100) }
        var tagOnly = AddressOverride()
        tagOnly.tag = "parser"
        let snapshot = self.snapshot(
            old: olds, new: news,
            oldOverrides: [olds[1].start: named("renamed_one"),
                           olds[2].start: named(nil, "a comment"),
                           olds[3].start: tagOnly,
                           olds[4].start: named("   ", "\n")],
            newOverrides: [news[0].start: named("destination_only")])
        let candidates = build(try matched(snapshot), snapshot)
        XCTAssertEqual(candidates.map(\.oldAddress), [olds[1].start, olds[2].start],
                       "tags, whitespace-only text and destination-only text are not sources")
        XCTAssertEqual(candidates.map(\.incoming), [TransferableAnnotation(name: "renamed_one", comment: nil),
                                                    TransferableAnnotation(name: nil, comment: "a comment")])
        XCTAssertEqual(candidates.first?.id, "match:\(olds[1].id.uuidString)>\(news[1].id.uuidString)",
                       "ids use the VersionCompareRow spelling")
    }

    func testPreselectsHighAndUserConfirmedOnly() {
        let rows: [(FunctionVersionMatchBasis, FunctionVersionMatchConfidence)] = [
            (.manual, .userConfirmed), (.symbolName, .high), (.normalizedBody, .high),
            (.normalizedBody, .medium), (.controlFlowAndCallees, .medium), (.callGraphPropagation, .low)]
        let olds = rows.indices.map { Fn(name: "sub_\(String(0x1000 + $0 * 0x100, radix: 16))", start: 0x1000 + UInt64($0) * 0x100) }
        let news = rows.indices.map { Fn(name: "sub_\(String(0x8000 + $0 * 0x100, radix: 16))", start: 0x8000 + UInt64($0) * 0x100) }
        let snapshot = self.snapshot(old: olds, new: news,
                                     oldOverrides: Dictionary(uniqueKeysWithValues: olds.map { ($0.start, named("n_\($0.start)")) }))
        let candidates = build(result(rows.indices.map { match(olds[$0], news[$0], rows[$0].0, rows[$0].1) }), snapshot)
        XCTAssertEqual(candidates.count, rows.count)
        XCTAssertEqual(candidates.map(\.isPreselected), [true, true, true, false, false, false])
        XCTAssertEqual(AnnotationTransferCandidates.defaultSelection(candidates),
                       Set(candidates.prefix(3).map(\.id)))
    }

    func testChangedHighPairStaysPreselectedAndCarriesDifferences() throws {
        let old = Fn(name: "_checksum", start: 0x1000)
        let new = Fn(name: "_checksum", start: 0x2000)
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [old.start: named(nil, "folds bytes")])
        let candidates = build(result([match(old, new, .symbolName, .high, differences: [.body, .size])]), snapshot)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertTrue(candidate.isPreselected)
        XCTAssertTrue(candidate.isChanged)
        XCTAssertEqual(candidate.differences, [.body, .size])
    }

    func testUnresolvedGroupsAreNeverCandidates() throws {
        // 2:2 duplicate names (the VersionCompare fixture's `_dup`) and 1:N.
        let olds = [Fn(name: "_dup", start: 0x1000), Fn(name: "_dup", start: 0x1100), Fn(name: "_one", start: 0x1200),
                    Fn(name: "_keep", start: 0x1300)]
        let news = [Fn(name: "_dup", start: 0x2000), Fn(name: "_dup", start: 0x2100), Fn(name: "_one", start: 0x2200),
                    Fn(name: "_one", start: 0x2300), Fn(name: "_keep", start: 0x2400)]
        let snapshot = self.snapshot(old: olds, new: news,
                                     oldOverrides: Dictionary(uniqueKeysWithValues: olds.map { ($0.start, named("user_\($0.start)")) }))
        let result = try matched(snapshot)
        XCTAssertEqual(result.unresolved.count, 2)
        let candidates = build(result, snapshot)
        XCTAssertEqual(candidates.map(\.oldAddress), [0x1300], "only the unique `_keep` pair is offered")
    }

    func testAddedAndRemovedAreNeverCandidates() throws {
        let olds = [Fn(name: "_gone", start: 0x1000), Fn(name: "_stay", start: 0x1100)]
        let news = [Fn(name: "_stay", start: 0x2000), Fn(name: "_fresh", start: 0x2100)]
        let snapshot = self.snapshot(old: olds, new: news,
                                     oldOverrides: [0x1000: named("was_gone"), 0x1100: named("stays")])
        let result = try matched(snapshot)
        XCTAssertEqual(result.removedIDs, [olds[0].id.uuidString])
        XCTAssertEqual(result.addedIDs, [news[1].id.uuidString])
        XCTAssertEqual(build(result, snapshot).map(\.incoming.name), ["stays"])
    }

    func testSameAddressWithoutEvidenceIsNotOffered() throws {
        // Same VA, generated names, different bodies: the matcher never uses address as evidence.
        let old = Fn(name: "sub_1000", start: 0x1000, size: 0x10, body: body(1))
        let new = Fn(name: "sub_1000", start: 0x1000, size: 0x10, body: body(2))
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [0x1000: named("parse_header", "entry")])
        let result = try matched(snapshot)
        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertTrue(build(result, snapshot).isEmpty)
    }

    func testCollidingVirtualAddressesStayInTheirSlots() throws {
        let old = Fn(name: "_foo", start: 0x1000)
        let new = Fn(name: "_foo", start: 0x1000)
        let snapshot = self.snapshot(old: [old], new: [new],
                                     oldOverrides: [0x1000: named("old_user_name")],
                                     newOverrides: [0x1000: named(nil, "new authored comment")])
        let candidate = try XCTUnwrap(build(try matched(snapshot), snapshot).first)
        XCTAssertEqual(candidate.incoming, TransferableAnnotation(name: "old_user_name", comment: nil))
        XCTAssertEqual(candidate.existing, TransferableAnnotation(name: nil, comment: "new authored comment"))
        XCTAssertEqual(AnnotationTransferCandidates.annotations(in: newSlot, at: [0x1000], snapshot: snapshot),
                       [0x1000: TransferableAnnotation(name: nil, comment: "new authored comment")])
        XCTAssertEqual(AnnotationTransferCandidates.annotations(in: oldSlot, at: [0x1000], snapshot: snapshot),
                       [0x1000: TransferableAnnotation(name: "old_user_name", comment: nil)])
        let preview = try AnnotationTransferCandidates.preview(
            [candidate], selected: [candidate.id], oldSlot: oldSlot, newSlot: newSlot, snapshot: snapshot)
        XCTAssertEqual(preview.changes, [AnnotationTransferChange(sourceAddress: 0x1000, destinationAddress: 0x1000,
                                                                  newName: "old_user_name", newComment: nil)])
    }

    // MARK: - Destination symbol rule (D3)

    func testRenamedSymbolCarriesUserNameForward() throws {
        let old = Fn(name: "_foo", start: 0x1000)
        let new = Fn(name: "_foo", start: 0x2000)
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [0x1000: named("parse_header")])
        let candidates = build(try matched(snapshot), snapshot)
        XCTAssertNil(candidates.first?.destinationSymbol)
        let preview = try AnnotationTransferCandidates.preview(
            candidates, selected: AnnotationTransferCandidates.defaultSelection(candidates),
            oldSlot: oldSlot, newSlot: newSlot, snapshot: snapshot)
        XCTAssertEqual(preview.changes.map(\.newName), ["parse_header"])
        XCTAssertTrue(preview.conflicts.isEmpty)
    }

    func testDifferentDestinationSymbolIsConflictNotChange() throws {
        let old = Fn(name: "_old_name", start: 0x1000, size: 0x10, body: body(7))
        let new = Fn(name: "_new_name", start: 0x2000, size: 0x10, body: body(7))
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [0x1000: named("multiply_mod", "keeps sign")])
        let result = try matched(snapshot)
        XCTAssertEqual(result.matches.map(\.basis), [.normalizedBody])
        let candidates = build(result, snapshot)
        XCTAssertEqual(candidates.first?.destinationSymbol, "_new_name")
        XCTAssertEqual(candidates.first?.symbolNameChanged, true)
        let preview = try AnnotationTransferCandidates.preview(
            candidates, selected: AnnotationTransferCandidates.defaultSelection(candidates),
            oldSlot: oldSlot, newSlot: newSlot, snapshot: snapshot)
        XCTAssertEqual(preview.conflicts, [AnnotationTransferConflict(
            destinationAddress: 0x2000, field: .name, kind: .destinationSymbol,
            existing: "_new_name", incoming: "multiply_mod")])
        XCTAssertEqual(preview.changes, [AnnotationTransferChange(
            sourceAddress: 0x1000, destinationAddress: 0x2000, newName: nil, newComment: "keeps sign")])
    }

    func testGeneratedDestinationNameIsNotAConflict() throws {
        let old = Fn(name: "_parse", start: 0x1000, size: 0x10, body: body(9))
        let new = Fn(name: "sub_2000", start: 0x2000, size: 0x10, body: body(9))
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [0x1000: named("parse_header")])
        let candidates = build(try matched(snapshot), snapshot)
        XCTAssertNil(candidates.first?.destinationSymbol)
        XCTAssertEqual(candidates.first?.isPreselected, true)
        let preview = try AnnotationTransferCandidates.preview(
            candidates, selected: AnnotationTransferCandidates.defaultSelection(candidates),
            oldSlot: oldSlot, newSlot: newSlot, snapshot: snapshot)
        XCTAssertEqual(preview.changes.map(\.newName), ["parse_header"])
    }

    /// Synthetic ELF/PE-shaped images carry no Mach-O linkage sections; body evidence alone pairs them.
    func testELFLikeImageWithoutLinkageSectionsStillMatchesByBody() throws {
        let old = Fn(name: "sub_401000", start: 0x401000, size: 0x10, body: body(11))
        let new = Fn(name: "sub_402000", start: 0x402000, size: 0x10, body: body(11))
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [0x401000: named("elf_entry")])
        let candidates = build(try matched(snapshot), snapshot)
        XCTAssertEqual(candidates.map(\.basis), [.normalizedBody])
        XCTAssertEqual(candidates.map(\.isPreselected), [true])
    }

    // MARK: - Skips

    func testOversizeSourceTextIsSkippedNotThrown() throws {
        let olds = [Fn(name: "_big", start: 0x1000), Fn(name: "_nul", start: 0x1100), Fn(name: "_ok", start: 0x1200)]
        let news = [Fn(name: "_big", start: 0x2000), Fn(name: "_nul", start: 0x2100), Fn(name: "_ok", start: 0x2200)]
        let snapshot = self.snapshot(
            old: olds, new: news,
            oldOverrides: [0x1000: named(nil, String(repeating: "c", count: AnnotationTransferPlanner.maximumCommentBytes + 1)),
                           0x1100: named("bad\u{0}name"),
                           0x1200: named("fine")])
        let candidates = build(try matched(snapshot), snapshot)
        XCTAssertEqual(candidates.map(\.skip), [.textLimit, .textLimit, nil])
        XCTAssertEqual(candidates.map(\.isPreselected), [false, false, true])
        // Even an explicit selection of a skipped row never reaches the planner.
        let preview = try AnnotationTransferCandidates.preview(
            candidates, selected: Set(candidates.map(\.id)), oldSlot: oldSlot, newSlot: newSlot, snapshot: snapshot)
        XCTAssertEqual(preview.changes.map(\.newName), ["fine"])
    }

    func testOversizeExistingDestinationTextIsSkipped() throws {
        let old = Fn(name: "_f", start: 0x1000)
        let new = Fn(name: "_f", start: 0x2000)
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [0x1000: named("x")],
                                     newOverrides: [0x2000: named(String(repeating: "n", count: 4_097))])
        XCTAssertEqual(build(try matched(snapshot), snapshot).map(\.skip), [.textLimit])
    }

    func testNotFunctionStartIsSkipped() {
        let old = Fn(name: "_f", start: 0x1000)
        let new = Fn(name: "_f", start: 0x2000)
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [0x1000: named("x")])
        let stale = FunctionVersionMatch(oldID: old.id.uuidString, newID: new.id.uuidString, oldAddress: 0x1000,
                                         newAddress: 0x2004, basis: .symbolName, confidence: .high,
                                         propagatedFromOldCallerID: nil, propagatedFromNewCallerID: nil,
                                         differences: [], symbolNameChanged: false)
        let candidates = build(result([stale]), snapshot)
        XCTAssertEqual(candidates.map(\.skip), [.notFunctionStart])
        XCTAssertTrue(AnnotationTransferCandidates.pairs(candidates, selected: Set(candidates.map(\.id))).isEmpty)
    }

    func testInteriorCommentIsIgnored() throws {
        let old = Fn(name: "_f", start: 0x1000)
        let new = Fn(name: "_f", start: 0x2000)
        let snapshot = self.snapshot(old: [old], new: [new], oldOverrides: [0x1004: named(nil, "interior")])
        XCTAssertTrue(build(try matched(snapshot), snapshot).isEmpty)
    }

    func testSameSlotBuildsNothing() throws {
        let old = Fn(name: "_f", start: 0x1000)
        let snapshot = self.snapshot(old: [old], new: [Fn(name: "_f", start: 0x2000)], oldOverrides: [0x1000: named("x")])
        XCTAssertTrue(AnnotationTransferCandidates.build(result: try matched(snapshot), oldSlot: oldSlot,
                                                         newSlot: oldSlot, snapshot: snapshot).isEmpty)
    }

    // MARK: - Planner inputs

    func testPreviewSnapshotsTrackCurrentOverrides() throws {
        let olds = [Fn(name: "_a", start: 0x1000), Fn(name: "_b", start: 0x1100), Fn(name: "_c", start: 0x1200)]
        let news = [Fn(name: "_a", start: 0x2000), Fn(name: "_b", start: 0x2100), Fn(name: "_c", start: 0x2200)]
        var snapshot = self.snapshot(old: olds, new: news,
                                     oldOverrides: [0x1000: named("alpha", "first"), 0x1100: named("beta")],
                                     newOverrides: [0x2100: named("mine"), 0x2200: named("untouched")])
        let candidates = build(try matched(snapshot), snapshot)
        let preview = try AnnotationTransferCandidates.preview(
            candidates, selected: AnnotationTransferCandidates.defaultSelection(candidates),
            oldSlot: oldSlot, newSlot: newSlot, snapshot: snapshot)
        XCTAssertEqual(preview.nameCount, 1)
        XCTAssertEqual(preview.commentCount, 1)
        XCTAssertEqual(preview.conflicts.map(\.destinationAddress), [0x2100])
        XCTAssertEqual(Set(preview.expectedDestination.keys), [0x2000, 0x2100])

        // Commit-time projection: an edit at an unexamined address keeps the preview applicable.
        snapshot.addressOverrides[ImageAddress(slot: newSlot, address: 0x2200)] = named("edited")
        let current = AnnotationTransferCandidates.annotations(in: newSlot, at: preview.expectedDestination.keys, snapshot: snapshot)
        XCTAssertEqual(preview.staleDestinations(current), [])
        snapshot.addressOverrides[ImageAddress(slot: newSlot, address: 0x2000)] = named(nil, "user typed")
        let touched = AnnotationTransferCandidates.annotations(in: newSlot, at: preview.expectedDestination.keys, snapshot: snapshot)
        XCTAssertEqual(preview.staleDestinations(touched), [0x2000])
        snapshot.addressOverrides[ImageAddress(slot: oldSlot, address: 0x1100)] = named("beta2")
        let sources = AnnotationTransferCandidates.annotations(in: oldSlot, at: preview.expectedSource.keys, snapshot: snapshot)
        XCTAssertEqual(preview.staleSources(sources), [0x1100])
    }

    // MARK: - Scale

    func testBuildIsLinearInMatches() {
        let count = 50_000
        let olds = (0..<count).map { Fn(name: "sub_\(String(0x10_0000 + $0 * 0x10, radix: 16))", start: 0x10_0000 + UInt64($0) * 0x10, size: 0x10) }
        let news = (0..<count).map { Fn(name: "sub_\(String(0x80_0000 + $0 * 0x10, radix: 16))", start: 0x80_0000 + UInt64($0) * 0x10, size: 0x10) }
        var overrides: [UInt64: AddressOverride] = [:]
        for index in stride(from: 0, to: count, by: 50) { overrides[olds[index].start] = named("user_\(index)") }
        let snapshot = self.snapshot(old: olds, new: news, oldOverrides: overrides)
        let matches = result((0..<count).map { match(olds[$0], news[$0], .normalizedBody, .high) })
        let clock = ContinuousClock()
        var candidates: [AnnotationTransferCandidate] = []
        let elapsed = clock.measure { candidates = build(matches, snapshot) }
        XCTAssertEqual(candidates.count, 1_000)
        // A ceiling, not a benchmark: an O(m^2) regression (2.5e9 steps) blows far past it.
        XCTAssertLessThan(elapsed, .seconds(10), "build took \(elapsed)")
    }
}
