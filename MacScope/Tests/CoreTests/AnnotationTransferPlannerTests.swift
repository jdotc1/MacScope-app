import Foundation
import XCTest
@testable import MacScope

/// RX-01 pure pair planner. The first six cases port the roadmap reference tests
/// (`IntegrationCoreTests`, `RevisionFixTests`); the rest cover the MacScope deltas.
final class AnnotationTransferPlannerTests: XCTestCase {
    private typealias Annotation = TransferableAnnotation

    private func pair(_ source: UInt64, _ destination: UInt64) -> AnnotationTransferPair {
        AnnotationTransferPair(sourceAddress: source, destinationAddress: destination)
    }

    // MARK: - Ported reference cases

    func testAnnotationPreviewNeverOverwritesAuthoredName() throws {
        let plan = try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2)],
            source: [1: Annotation(name: "oldName", comment: "useful note")],
            destination: [2: Annotation(name: "myName", comment: nil)])
        XCTAssertEqual(plan.conflicts, [AnnotationTransferConflict(
            destinationAddress: 2, field: .name, kind: .authored, existing: "myName", incoming: "oldName")])
        XCTAssertEqual(plan.changes, [AnnotationTransferChange(
            sourceAddress: 1, destinationAddress: 2, newName: nil, newComment: "useful note")])
        XCTAssertFalse(plan.isStillApplicable(to: [2: Annotation(name: "myName", comment: "new edit")]))
    }

    func testIdenticalAnnotationsProduceNoMutations() throws {
        let value = Annotation(name: "f", comment: "c")
        let plan = try AnnotationTransferPlanner.preview(pairs: [pair(1, 2)], source: [1: value], destination: [2: value])
        XCTAssertTrue(plan.changes.isEmpty)
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.expectedDestination, [2: value], "an identical destination is still examined")
    }

    func testExistingConflictTextMustAlsoBeBounded() {
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2)],
            source: [1: Annotation(name: "new", comment: nil)],
            destination: [2: Annotation(name: String(repeating: "x", count: 4_097), comment: nil)])) { error in
            XCTAssertEqual(error as? AnnotationTransferError, .textLimitExceeded(address: 2))
        }
    }

    /// Reference R-03: an edit to an unrelated destination function must not stale the preview.
    func testUnrelatedDestinationEditKeepsPreviewApplicable() throws {
        var destination: [UInt64: Annotation] = [0x3000: Annotation(name: "other", comment: nil)]
        let preview = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x1000, 0x2000)],
            source: [0x1000: Annotation(name: "parse_header", comment: nil)],
            destination: destination)
        XCTAssertEqual(preview.changes.map(\.newName), ["parse_header"])
        destination[0x3000] = Annotation(name: "renamed_elsewhere", comment: nil)
        XCTAssertEqual(preview.staleDestinations(destination), [])
        destination[0x2000] = Annotation(name: "user_named_it", comment: nil)
        XCTAssertEqual(preview.staleDestinations(destination), [0x2000])
    }

    func testRemovingExaminedDestinationAnnotationStalesPreview() throws {
        var destination: [UInt64: Annotation] = [0x2000: Annotation(name: "authored", comment: nil)]
        let preview = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x1000, 0x2000)],
            source: [0x1000: Annotation(name: "a", comment: "c")],
            destination: destination)
        XCTAssertEqual(preview.conflicts.count, 1)
        XCTAssertEqual(preview.changes.first?.newComment, "c")
        destination.removeValue(forKey: 0x2000)
        XCTAssertEqual(preview.staleDestinations(destination), [0x2000])
        XCTAssertFalse(preview.isStillApplicable(to: destination))
    }

    func testPairsMustBeOneToOne() {
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2), pair(3, 2)], source: [:], destination: [:])) { error in
            XCTAssertEqual(error as? AnnotationTransferError, .notOneToOne(sourceOrDestination: 2),
                           "duplicate destination")
        }
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2), pair(1, 4)], source: [:], destination: [:])) { error in
            XCTAssertEqual(error as? AnnotationTransferError, .notOneToOne(sourceOrDestination: 1),
                           "duplicate source")
        }
    }

    // MARK: - Field rules

    func testNameAndCommentJudgedIndependently() throws {
        let plan = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x10, 0x20)],
            source: [0x10: Annotation(name: "incoming_name", comment: "incoming comment")],
            destination: [0x20: Annotation(name: "authored_name", comment: nil)])
        XCTAssertEqual(plan.conflicts.map(\.field), [.name])
        XCTAssertEqual(plan.changes, [AnnotationTransferChange(
            sourceAddress: 0x10, destinationAddress: 0x20, newName: nil, newComment: "incoming comment")])

        let reversed = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x10, 0x20)],
            source: [0x10: Annotation(name: "incoming_name", comment: "incoming comment")],
            destination: [0x20: Annotation(name: nil, comment: "authored comment")])
        XCTAssertEqual(reversed.conflicts.map(\.field), [.comment])
        XCTAssertEqual(reversed.changes.map(\.newName), ["incoming_name"])
        XCTAssertEqual(reversed.changes.map(\.newComment), [nil])
    }

    func testEmptyIncomingFieldNeverClearsDestination() throws {
        let plan = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x10, 0x20), pair(0x11, 0x21)],
            source: [0x10: Annotation(name: "", comment: "note"), 0x11: Annotation(name: nil, comment: "")],
            destination: [0x20: Annotation(name: "keep_me", comment: nil), 0x21: Annotation(name: nil, comment: "keep")])
        XCTAssertEqual(plan.changes, [AnnotationTransferChange(
            sourceAddress: 0x10, destinationAddress: 0x20, newName: nil, newComment: "note")])
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertNil(plan.expectedDestination[0x21], "a source with no text never examines its destination")
        XCTAssertEqual(plan.expectedSource[0x11], .empty, "the empty source is still recorded (D6)")
    }

    /// D3: a different real symbol at the destination blocks the name, never the comment, and a
    /// symbol equal to the incoming name is a no-op rather than a conflict.
    func testDestinationSymbolConflictBlocksNameOnly() throws {
        let plan = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x10, 0x20), pair(0x11, 0x21)],
            source: [0x10: Annotation(name: "parse_header", comment: "entry"),
                     0x11: Annotation(name: "_bar", comment: nil)],
            destination: [:],
            destinationSymbolConflicts: [0x20: "_other_symbol", 0x21: "_bar"])
        XCTAssertEqual(plan.conflicts, [AnnotationTransferConflict(
            destinationAddress: 0x20, field: .name, kind: .destinationSymbol,
            existing: "_other_symbol", incoming: "parse_header")])
        XCTAssertEqual(plan.changes, [AnnotationTransferChange(
            sourceAddress: 0x10, destinationAddress: 0x20, newName: nil, newComment: "entry")])

        let authored = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x10, 0x20)],
            source: [0x10: Annotation(name: "parse_header", comment: nil)],
            destination: [0x20: Annotation(name: "mine", comment: nil)],
            destinationSymbolConflicts: [0x20: "_other_symbol"])
        XCTAssertEqual(authored.conflicts.map(\.kind), [.authored], "an authored name outranks the symbol")
    }

    func testChangesSortedBySourceAddressIndependentOfInputOrder() throws {
        let pairs: [AnnotationTransferPair] = (0..<64).map { (index: Int) -> AnnotationTransferPair in
            let offset = UInt64(index) * 0x10
            return pair(0x1000 + offset, 0x9000 - offset)
        }
        let source: [UInt64: Annotation] = Dictionary(uniqueKeysWithValues: pairs.map {
            (pair: AnnotationTransferPair) -> (UInt64, Annotation) in
            (pair.sourceAddress, Annotation(name: "f_\(pair.sourceAddress)", comment: nil))
        })
        let destination: [UInt64: Annotation] = [pairs[5].destinationAddress: Annotation(name: "taken", comment: nil)]
        let reference = try AnnotationTransferPlanner.preview(pairs: pairs, source: source, destination: destination)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<8 {
            let shuffled = try AnnotationTransferPlanner.preview(
                pairs: pairs.shuffled(using: &generator), source: source, destination: destination)
            XCTAssertEqual(shuffled, reference)
        }
        let changedSources: [UInt64] = reference.changes.map { $0.sourceAddress }
        XCTAssertEqual(changedSources, changedSources.sorted())
        XCTAssertEqual(reference.changes.count, 63)
    }

    // MARK: - Limits

    func testPairLimitIsTyped() {
        let pairs = (0..<100_001).map { pair(UInt64($0), UInt64($0)) }
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(pairs: pairs, source: [:], destination: [:])) { error in
            XCTAssertEqual(error as? AnnotationTransferError, .pairLimitExceeded(100_001))
        }
        XCTAssertNoThrow(try AnnotationTransferPlanner.preview(pairs: Array(pairs.prefix(100_000)),
                                                               source: [:], destination: [:]))
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(pairs: [], source: [:], destination: [:],
                                                                   maximumPairs: 0))
    }

    func testAggregateTextBudgetIsTyped() throws {
        // 129 comments of 64 KiB each = 8 MiB + 64 KiB, each individually admissible.
        let comment = String(repeating: "c", count: AnnotationTransferPlanner.maximumCommentBytes)
        let pairs = (0..<129).map { pair(UInt64(0x1000 + $0), UInt64(0x9000 + $0)) }
        let source = Dictionary(uniqueKeysWithValues: pairs.map { ($0.sourceAddress, Annotation(name: nil, comment: comment)) })
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(pairs: pairs, source: source, destination: [:])) { error in
            XCTAssertEqual(error as? AnnotationTransferError, .textLimitExceeded(address: 0x1000 + 128),
                           "the first pair past the budget is named")
        }
        let fitting = try AnnotationTransferPlanner.preview(pairs: Array(pairs.prefix(128)), source: source, destination: [:])
        XCTAssertEqual(fitting.commentCount, 128)
    }

    func testEmbeddedNULRejected() {
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2)], source: [1: Annotation(name: "bad\u{0}name", comment: nil)], destination: [:])) { error in
            XCTAssertEqual(error as? AnnotationTransferError, .textLimitExceeded(address: 1))
        }
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2)], source: [1: Annotation(name: nil, comment: "ok")],
            destination: [2: Annotation(name: nil, comment: "existing\u{0}")])) { error in
            XCTAssertEqual(error as? AnnotationTransferError, .textLimitExceeded(address: 2))
        }
    }

    func testUTF8MultibyteNamesCountBytesNotCharacters() throws {
        let fits = String(repeating: "日", count: 1_365)      // 4,095 bytes
        let tooLong = String(repeating: "日", count: 1_366)   // 4,098 bytes
        XCTAssertEqual(fits.utf8.count, 4_095)
        XCTAssertEqual(tooLong.utf8.count, 4_098)
        let plan = try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2)], source: [1: Annotation(name: fits, comment: nil)], destination: [:])
        XCTAssertEqual(plan.changes.first?.newName, fits, "text is carried unchanged")
        XCTAssertThrowsError(try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2)], source: [1: Annotation(name: tooLong, comment: nil)], destination: [:])) { error in
            XCTAssertEqual(error as? AnnotationTransferError, .textLimitExceeded(address: 1))
        }
    }

    // MARK: - Source snapshot (D6)

    func testSourceEditStalesPreview() throws {
        var source: [UInt64: Annotation] = [0x10: Annotation(name: "first", comment: nil),
                                            0x11: Annotation(name: "second", comment: nil),
                                            0x99: Annotation(name: "not_paired", comment: nil)]
        let preview = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x10, 0x20), pair(0x11, 0x21)], source: source, destination: [:])
        XCTAssertEqual(preview.staleSources(source), [])
        source[0x99] = Annotation(name: "edited_elsewhere", comment: nil)
        XCTAssertEqual(preview.staleSources(source), [], "an unread source never stales the preview")
        source[0x11] = Annotation(name: "second", comment: "added a comment")
        source.removeValue(forKey: 0x10)
        XCTAssertEqual(preview.staleSources(source), [0x10, 0x11])
    }

    func testSourceAbsentFromMapProducesNoChange() throws {
        var source: [UInt64: Annotation] = [:]
        let preview = try AnnotationTransferPlanner.preview(
            pairs: [pair(0x10, 0x20)], source: source, destination: [0x20: Annotation(name: "x", comment: nil)])
        XCTAssertTrue(preview.changes.isEmpty)
        XCTAssertTrue(preview.conflicts.isEmpty)
        XCTAssertEqual(preview.expectedSource, [0x10: .empty])
        XCTAssertTrue(preview.expectedDestination.isEmpty)
        source[0x10] = Annotation(name: "late", comment: nil)
        XCTAssertEqual(preview.staleSources(source), [0x10], "text added after the preview is a source change")
    }

    func testNameCountAndCommentCountMatchChanges() throws {
        let plan = try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 11), pair(2, 12), pair(3, 13), pair(4, 14)],
            source: [1: Annotation(name: "a", comment: "ca"),
                     2: Annotation(name: "b", comment: nil),
                     3: Annotation(name: nil, comment: "cc"),
                     4: Annotation(name: "d", comment: "cd")],
            destination: [14: Annotation(name: "taken", comment: "taken")])
        XCTAssertEqual(plan.nameCount, 2)
        XCTAssertEqual(plan.commentCount, 2)
        XCTAssertEqual(plan.changes.count, 3)
        XCTAssertEqual(plan.conflicts.count, 2)
        XCTAssertEqual(plan.changes.filter { $0.newName != nil }.count, plan.nameCount)
        XCTAssertEqual(plan.changes.filter { $0.newComment != nil }.count, plan.commentCount)
    }

    func testEmptyStringsAndAbsentEntriesCompareEqualForStaleness() throws {
        let preview = try AnnotationTransferPlanner.preview(
            pairs: [pair(1, 2)], source: [1: Annotation(name: "n", comment: nil)], destination: [:])
        XCTAssertEqual(preview.staleDestinations([2: Annotation(name: "", comment: "")]), [])
        XCTAssertEqual(preview.staleSources([1: Annotation(name: "n", comment: "")]), [])
    }
}
