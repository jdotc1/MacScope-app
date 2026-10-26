import XCTest
@testable import MacScope

/// EE-1: `earlyExitArmNotClean` was a first-failure catch-all with ZERO internal attribution.
/// It is now split by orientation x cause x in-loop x acyclic x tail-shape.
///
/// `classifyEarlyExit` is reached ONLY when the branch block has no in-graph post-dominator join
/// (both successors reach the function exit independently), AND the catch-all fires only when
/// BOTH orientations fail. Every fixture below was validated against the real classifier; a
/// hand-guessed set formed proper diamonds and never reached the catch-all at all.
final class DecompilerEarlyExitAttributionTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "") -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func diagnostics(_ rows: [InstructionRow]) -> RegionTree.Diagnostics {
        let function = MacIRBuilder().buildFunction(name: "_early_exit", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        return RegionTree
            .buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
            .diagnostics
    }

    private func branchDominanceRows() -> [InstructionRow] {
        [row(0x1000, "cbz", "x1, 0x1010"),
         row(0x1004, "nop"),
         row(0x1008, "cbnz", "x0, 0x1014"),   // does NOT dominate its fall-through 0x1010
         row(0x1010, "ret"),
         row(0x1014, "ret")]
    }

    /// Cause 3 — found by adversarial pre-launch review. A branch failing either dominance guard
    /// (`:703-704` / `:713-714`) never calls `isCleanExitArm`, yet still lands in the catch-all.
    /// Instrumenting only `isCleanExitArm` makes the partition non-exhaustive: corpus-wide this
    /// cause is 76 of the 270 functions, which would have been invisible.
    func testBranchDominanceFailedIsAttributed() {
        let d = diagnostics(branchDominanceRows())
        XCTAssertEqual(d.fatalVeto, .earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicPlainTail)
        XCTAssertNil(d.siteCounts[.earlyExitArmNotClean])
    }

    /// Cause 2 — the fall-through arm walks into the continuation (a reconverging diamond).
    /// The mirror fails separately on a shared tail, so the catch-all is reached.
    func testReachesContinuationIsAttributed() {
        let d = diagnostics([
            row(0x2000, "cbz", "x2, 0x2020"),
            row(0x2004, "cbnz", "x0, 0x2018"),   // the branch
            row(0x2008, "cbz", "x1, 0x2018"),    // fall-through arm reaches the continuation
            row(0x200c, "ret"),
            row(0x2018, "b", "0x2020"),
            row(0x2020, "ret")                   // shared tail: preds {0x2018, 0x2000}
        ])
        XCTAssertEqual(d.fatalVeto, .earlyExitFallthroughReachesContinuationOutOfLoopAcyclicPlainTail)
        XCTAssertNil(d.siteCounts[.earlyExitArmNotClean])
    }

    /// Cause 1 — the arm contains a block with an external predecessor (a SHARED tail), so the
    /// arm entry does not dominate it. Corpus-wide this is the dominant cell (97 of 270) and the
    /// real target for any future lift.
    func testArmDominanceFailedIsAttributed() {
        let d = diagnostics([
            row(0x3000, "cbz", "x1, 0x3018"),
            row(0x3004, "cbz", "x2, 0x3028"),
            row(0x3008, "cbnz", "x0, 0x3020"),   // the branch; BOTH arms hit shared tails
            row(0x300c, "b", "0x3014"),
            row(0x3014, "ret"),                  // shared tail: preds {0x300c, 0x3018}
            row(0x3018, "b", "0x3014"),
            row(0x3020, "b", "0x3028"),
            row(0x3028, "ret")                   // shared tail: preds {0x3020, 0x3004}
        ])
        XCTAssertEqual(d.fatalVeto, .earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicPlainTail)
        XCTAssertNil(d.siteCounts[.earlyExitArmNotClean])
    }

    /// The old catch-all must never be recorded again: every path through the `else` at `:730`
    /// now carries a named cause. Corpus proof: the sub-counters sum to exactly 270 fatal /
    /// 274 site, and `earlyExitArmNotClean` is 0.
    func testArmNotCleanCatchAllIsNeverRecorded() {
        XCTAssertNil(diagnostics(branchDominanceRows()).siteCounts[.earlyExitArmNotClean])
        XCTAssertNil(diagnostics([
            row(0x2000, "cbz", "x2, 0x2020"),
            row(0x2004, "cbnz", "x0, 0x2018"),
            row(0x2008, "cbz", "x1, 0x2018"),
            row(0x200c, "ret"),
            row(0x2018, "b", "0x2020"),
            row(0x2020, "ret")
        ]).siteCounts[.earlyExitArmNotClean])
    }

    /// The iteration-6 mirror-SUCCESS counters live outside this bucket. They may co-occur as
    /// sites, but they are never the fatal for a not-clean function.
    func testMirrorSuccessCountersRemainOutsideNotCleanBucket() {
        let d = diagnostics(branchDominanceRows())
        XCTAssertNotEqual(d.fatalVeto, .earlyExitTakenSinglePred)
        XCTAssertNotEqual(d.fatalVeto, .earlyExitTakenSharedExit)
        XCTAssertEqual(d.fatalVeto, .earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicPlainTail)
    }

    /// A clean early exit still structures — the attribution pass changes no decision.
    func testCleanEarlyExitStillStructures() {
        let d = diagnostics([
            row(0x5000, "cbnz", "x0, 0x500c"),
            row(0x5004, "mov", "x0, #0x0"),
            row(0x5008, "ret"),
            row(0x500c, "ret")
        ])
        XCTAssertNil(d.siteCounts[.earlyExitArmNotClean])
        XCTAssertNil(d.fatalVeto)
    }
}
