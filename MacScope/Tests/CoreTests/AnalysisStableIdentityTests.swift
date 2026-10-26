import Foundation
import XCTest
@testable import MacScope

/// HOP-4: function and symbol ids derive from (image slot, address), so they survive
/// re-analysis, stay unique within an image, and differ between slots.
@MainActor
final class AnalysisStableIdentityTests: XCTestCase {
    private static let code = Data([
        0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6, // f0: mov w0,#0; ret
        0xfd, 0x7b, 0xbf, 0xa9, 0xc0, 0x03, 0x5f, 0xd6, // f1: stp x29,x30,[sp,#-16]!; ret
    ])

    func testFunctionIDsAreStableAcrossReanalysis() throws {
        let url = try TinyMachO.make(code: Self.code).write()
        let first = try AnalysisEngine().analyze(url: url)
        let second = try AnalysisEngine().analyze(url: url)
        XCTAssertEqual(first.functions.count, 2)
        XCTAssertEqual(first.functions.map(\.id), second.functions.map(\.id))
        XCTAssertEqual(Set(first.functions.map(\.id)).count, first.functions.count)
        XCTAssertEqual(first.symbols.map(\.id), second.symbols.map(\.id))
        XCTAssertEqual(first.functions.first?.id,
                       AnalysisStableIdentity.functionID(slot: .primary, startAddress: first.functions[0].startAddress))
        // Basic blocks still point at their owning function.
        XCTAssertTrue(Set(first.basicBlocks.map(\.functionID)).isSubset(of: Set(first.functions.map(\.id))))
    }

    func testSymbolIDsAreUniqueForAliasesAndDifferBySlot() {
        let symbols = [
            SymbolSummary(id: UUID(), name: "_a", address: 0x10, kind: "function", libraryName: nil),
            SymbolSummary(id: UUID(), name: "_a", address: 0x10, kind: "function", libraryName: nil),
            SymbolSummary(id: UUID(), name: "_b", address: 0x10, kind: "function", libraryName: nil),
            SymbolSummary(id: UUID(), name: "_c", address: nil, kind: "import", libraryName: "libSystem"),
        ]
        let primary = AnalysisStableIdentity.assigningSymbolIDs(symbols, slot: .primary)
        XCTAssertEqual(Set(primary.map(\.id)).count, 4)
        XCTAssertEqual(primary.map(\.id), AnalysisStableIdentity.assigningSymbolIDs(symbols, slot: .primary).map(\.id))
        let other = AnalysisStableIdentity.assigningSymbolIDs(symbols, slot: ImageSlot(rawValue: 1))
        XCTAssertTrue(Set(primary.map(\.id)).isDisjoint(with: Set(other.map(\.id))))
        XCTAssertEqual(primary.map(\.name), symbols.map(\.name))
    }

    func testRestampToAnotherSlotRemapsBlocksAndKeepsProvenance() throws {
        let url = try TinyMachO.make(code: Self.code).write()
        let snapshot = try AnalysisEngine().analyze(url: url)
        var analysis = try XCTUnwrap(snapshot.analysis(in: snapshot.primarySlot))
        analysis.functions[0].noReturnProvenance = .catalog
        let slot = ImageSlot(rawValue: 3)
        AnalysisStableIdentity.restamp(&analysis, to: slot)
        XCTAssertEqual(analysis.functions.map(\.id), analysis.functions.map {
            AnalysisStableIdentity.functionID(slot: slot, startAddress: $0.startAddress)
        })
        XCTAssertTrue(Set(analysis.basicBlocks.map(\.functionID)).isSubset(of: Set(analysis.functions.map(\.id))))
        XCTAssertEqual(analysis.functions[0].noReturnProvenance, .catalog)
        XCTAssertTrue(Set(analysis.functions.map(\.id)).isDisjoint(with: Set(snapshot.functions.map(\.id))))
    }
}
