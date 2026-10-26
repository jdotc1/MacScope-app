import Foundation
import XCTest
@testable import MacScope

final class MachOExportTrieBudgetTests: XCTestCase {
    func testRepeatedOffsetIsIgnoredBeforeQueueAndPrefixReservations() throws {
        var budget = MachOExportTrieBudget(maximumPendingEntries: 1, maximumPrefixBytes: 1)
        XCTAssertEqual(try budget.reserve(
            relativeOffset: 1, pendingEntryCount: 0, parentPrefixByteCount: 0,
            edgeByteCount: 1, commandIndex: 3
        ), 1)
        XCTAssertNil(try budget.reserve(
            relativeOffset: 1, pendingEntryCount: 1, parentPrefixByteCount: Int.max,
            edgeByteCount: Int.max, commandIndex: 3
        ))
        XCTAssertNil(try budget.reserve(
            relativeOffset: 0, pendingEntryCount: 1, parentPrefixByteCount: Int.max,
            edgeByteCount: Int.max, commandIndex: 3
        ))
    }

    func testPendingEntryBudgetFailsExplicitly() {
        assertBudgetFailure("export trie pending entry budget exceeded") {
            try parseTwoExports(budget: .init(maximumPendingEntries: 1, maximumPrefixBytes: 64))
        }
    }

    func testAggregatePrefixBudgetFailsExplicitly() {
        assertBudgetFailure("export trie aggregate prefix byte budget exceeded") {
            try parseTwoExports(budget: .init(maximumPendingEntries: 8, maximumPrefixBytes: 1))
        }
    }

    func testPrefixBudgetCountsParentsAndPreviouslyPoppedEntries() throws {
        var budget = MachOExportTrieBudget(maximumPendingEntries: 8, maximumPrefixBytes: 4)
        XCTAssertEqual(try budget.reserve(
            relativeOffset: 1, pendingEntryCount: 0, parentPrefixByteCount: 0,
            edgeByteCount: 2, commandIndex: 3
        ), 2)
        assertBudgetFailure("export trie aggregate prefix byte budget exceeded") {
            try budget.reserve(
                relativeOffset: 2, pendingEntryCount: 0, parentPrefixByteCount: 2,
                edgeByteCount: 1, commandIndex: 3
            )
        }
    }

    func testValidTriePreservesNamesAddressesFlagsAndSourceAtBudgetBoundary() throws {
        let exports = try parseTwoExports(budget: .init(maximumPendingEntries: 2, maximumPrefixBytes: 2))
        XCTAssertEqual(exports.map(\.name), ["a", "b"])
        XCTAssertEqual(exports.map(\.address), [0x1_0000_0001, 0x1_0000_0002])
        XCTAssertEqual(exports.map(\.flags), [0, 0])
        XCTAssertEqual(exports.map(\.source), ["LC_DYLD_EXPORTS_TRIE", "LC_DYLD_EXPORTS_TRIE"])
    }

    private func parseTwoExports(budget: MachOExportTrieBudget) throws -> [MachOExport] {
        // A root with two distinct one-character edges and ordinary image-relative terminals.
        let trie: [UInt8] = [0, 2, 97, 0, 8, 98, 0, 12, 2, 0, 1, 0, 2, 0, 2, 0]
        return try MachOParser().parseExportTrie(
            in: Data([0] + trie), exportOffset: 1, exportSize: UInt32(trie.count),
            commandIndex: 3, source: "LC_DYLD_EXPORTS_TRIE", imageBase: 0x1_0000_0000,
            budget: budget
        )
    }

    private func assertBudgetFailure<T>(
        _ expectedReason: String, file: StaticString = #filePath, line: UInt = #line,
        operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case MachOParserError.invalidLoadCommand(let index, let reason) = error else {
                return XCTFail("Expected invalidLoadCommand, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(index, 3, file: file, line: line)
            XCTAssertEqual(reason, expectedReason, file: file, line: line)
        }
    }
}
