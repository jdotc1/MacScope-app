import Foundation
import XCTest
@testable import MacScope

/// The single-row resolver the selection's accessibility label uses matches the full listing's
/// row for every instruction (except the symbolized operands, which the label doesn't read).
@MainActor
final class DisassemblyRowResolutionTests: XCTestCase {
    func testEveryRowResolvesAsTheListingResolvesIt() throws {
        let snapshot = AnalysisEngine.previewSnapshot()
        let slot = snapshot.primarySlot
        let instructions = try XCTUnwrap(snapshot.analysis(in: slot)?.instructions)
        XCTAssertFalse(instructions.isEmpty)
        let programCounter = instructions[instructions.count / 2].address
        let full = DisassemblyListingBuilder.buildResolved(snapshot: snapshot, liveProgramCounter: programCounter,
                                                           slot: slot).resolved
        for instruction in instructions {
            var single = DisassemblyListingBuilder.resolvedInstruction(
                instruction, snapshot: snapshot, slot: slot,
                programCounterRow: DisassemblyListingBuilder.liveProgramCounterRowAddress(
                    snapshot: snapshot, programCounter: programCounter, slot: slot))
            let listed = try XCTUnwrap(full[instruction.address], instruction.address.hexAddress)
            single.row = listed.row
            XCTAssertEqual(single, listed, instruction.address.hexAddress)
        }
        XCTAssertEqual(full.values.filter(\.isLiveProgramCounter).count, 1)
    }
}
