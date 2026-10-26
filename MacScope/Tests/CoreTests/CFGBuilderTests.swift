import XCTest
@testable import MacScope

final class CFGBuilderTests: XCTestCase {
    // MARK: - Fixture helpers

    /// Builds a MacIR instruction at a 4-byte-stride address from index.
    private func instruction(_ index: Int, mnemonic: String = "nop", _ operation: MacIROperation) -> MacIRInstruction {
        MacIRInstruction(
            source: MacIRSourceSpan(
                address: 0x1000 + UInt64(index) * 4,
                byteText: "00 00 00 00",
                mnemonic: mnemonic,
                operands: ""
            ),
            operation: operation
        )
    }

    private func address(_ index: Int) -> Int64 { Int64(0x1000 + index * 4) }

    private func nop(_ index: Int) -> MacIRInstruction {
        instruction(index, .intrinsic(destination: nil, name: "nop", arguments: []))
    }

    private func ret(_ index: Int) -> MacIRInstruction {
        instruction(index, mnemonic: "ret", .returnValue(nil))
    }

    private func condBranch(_ index: Int, to targetIndex: Int, left: MacIRValue = .register(name: "x0", version: 0)) -> MacIRInstruction {
        instruction(index, mnemonic: "cbnz", .conditionalBranch(condition: "!=", left: left, right: .immediate(0), target: .immediate(address(targetIndex))))
    }

    private func branch(_ index: Int, to targetIndex: Int) -> MacIRInstruction {
        instruction(index, mnemonic: "b", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(address(targetIndex))]))
    }

    // MARK: - One-block linear

    func testSingleBlockLinearFunctionHasOneBlock() {
        let instructions = [nop(0), nop(1), ret(2)]
        let cfg = CFGBuilder.buildCFG(instructions: instructions)

        XCTAssertEqual(cfg.blocks.count, 1)
        XCTAssertEqual(cfg.entryIndex, 0)
        XCTAssertEqual(cfg.blocks[0].startIndex, 0)
        XCTAssertEqual(cfg.blocks[0].endIndex, 3)
        XCTAssertTrue(cfg.blocks[0].successors.isEmpty)
        XCTAssertTrue(cfg.loopHeaders.isEmpty)
        XCTAssertTrue(cfg.backEdges.isEmpty)
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
        XCTAssertFalse(cfg.hasUnresolvedTargets)
        XCTAssertEqual(cfg.domTree[0], 0)
    }

    // MARK: - If-then: two successors + immediate dominator

    func testIfThenHasTwoSuccessorsAndIdom() {
        // 0: cbnz -> 3 (join)   [branch block]
        // 1: nop                [then body]
        // 2: b -> 3
        // 3: ret                [join]
        let instructions = [
            condBranch(0, to: 3),
            nop(1),
            branch(2, to: 3),
            ret(3)
        ]
        let cfg = CFGBuilder.buildCFG(instructions: instructions)

        XCTAssertEqual(cfg.blocks.count, 3)
        // Block 0 = [0], Block 1 = [1,2], Block 2 = [3].
        let entry = cfg.blocks[0]
        XCTAssertEqual(Set(entry.successors), [1, 2])
        // Both arms reach the join (block 2). Join's idom is the entry (block 0),
        // since it is reachable two ways.
        XCTAssertEqual(cfg.domTree[2], 0)
        // The then-body block (1) is dominated by the entry.
        XCTAssertEqual(cfg.domTree[1], 0)
        XCTAssertTrue(cfg.loopHeaders.isEmpty)
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
        // Join post-dominates the entry.
        XCTAssertTrue(CFGBuilder.postDominates(2, 0, postDomTree: cfg.postDomTree))
    }

    // MARK: - While: back-edge + loop header

    func testWhileLoopHasBackEdgeAndLoopHeader() {
        // 0: cbz x0 -> 3 (exit) [header, top test]   (cbnz here as a stand-in)
        // 1: nop                [body]
        // 2: b -> 0             [back-edge]
        // 3: ret                [exit]
        let instructions = [
            instruction(0, mnemonic: "cbz", .conditionalBranch(condition: "==", left: .register(name: "x0", version: 0), right: .immediate(0), target: .immediate(address(3)))),
            nop(1),
            branch(2, to: 0),
            ret(3)
        ]
        let cfg = CFGBuilder.buildCFG(instructions: instructions)

        // Block 0 = [0], Block 1 = [1,2], Block 2 = [3].
        XCTAssertTrue(cfg.loopHeaders.contains(0))
        XCTAssertTrue(cfg.blocks[0].isLoopHeader)
        XCTAssertTrue(cfg.backEdges.contains(CFGEdge(1, 0)))
        XCTAssertEqual(cfg.domTree[0], 0)
        XCTAssertEqual(cfg.domTree[1], 0)
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty)
    }

    // MARK: - Irreducible SCC flagged

    func testIrreducibleMultiEntryLoopIsFlagged() {
        // Two blocks that branch into each other's "middle" — a classic
        // irreducible (multi-entry) loop. Entry can reach both heads, and each
        // head jumps to the other, with no single dominating header.
        // 0: cbnz -> 2          (entry: to B at idx2, fallthrough to idx1)
        // 1: cbnz -> 3 ; (A)    fallthrough -> idx2 (B); taken -> 3 exit-ish
        // 2: cbnz -> 1 ; (B)    fallthrough -> idx3; taken -> 1 (A)
        // 3: ret
        let instructions = [
            condBranch(0, to: 2),
            condBranch(1, to: 3),
            condBranch(2, to: 1),
            ret(3)
        ]
        let cfg = CFGBuilder.buildCFG(instructions: instructions)
        // The mutual A<->B cycle with two entries is irreducible.
        XCTAssertFalse(cfg.irreducibleBlocks.isEmpty)
    }

    func testSelfLoopIsReducibleNotIrreducible() {
        // A single-block self-loop (back-edge to itself) is a perfectly
        // reducible while(true)-style loop, NOT irreducible.
        // 0: nop
        // 1: cbnz -> 0  (back-edge to header at 0; fallthrough to 2)
        // 2: ret
        let instructions = [
            nop(0),
            condBranch(1, to: 0),
            ret(2)
        ]
        let cfg = CFGBuilder.buildCFG(instructions: instructions)
        XCTAssertTrue(cfg.loopHeaders.contains(0))
        XCTAssertTrue(cfg.backEdges.contains(CFGEdge(0, 0)))
        XCTAssertTrue(cfg.irreducibleBlocks.isEmpty, "a self-loop must be reducible")
    }

    // MARK: - Switch: four successors

    func testSwitchDispatchHasAllCaseSuccessors() {
        // 0: switchDispatch with 3 cases + default, all targets in-window.
        let instructions = [
            instruction(0, mnemonic: "br", .switchDispatch(
                index: .register(name: "x0", version: 0),
                cases: [
                    MacIRSwitchCase(value: 0, target: .immediate(address(1))),
                    MacIRSwitchCase(value: 1, target: .immediate(address(2))),
                    MacIRSwitchCase(value: 2, target: .immediate(address(3)))
                ],
                defaultTarget: .immediate(address(4))
            )),
            ret(1),
            ret(2),
            ret(3),
            ret(4)
        ]
        let cfg = CFGBuilder.buildCFG(instructions: instructions)
        // Block 0 = [0]; its successors are the 3 case blocks + default = 4.
        XCTAssertEqual(cfg.blocks[0].successors.count, 4)
        XCTAssertFalse(cfg.hasUnresolvedTargets)
    }

    func testUnresolvableBranchTargetIsFlagged() {
        // A conditional branch to an address that is not an instruction.
        let instructions = [
            instruction(0, mnemonic: "cbnz", .conditionalBranch(condition: "!=", left: .register(name: "x0", version: 0), right: .immediate(0), target: .immediate(0x9999))),
            ret(1)
        ]
        let cfg = CFGBuilder.buildCFG(instructions: instructions)
        XCTAssertTrue(cfg.hasUnresolvedTargets)
    }

    // MARK: - arm64e authenticated control flow (end-to-end through MacIRBuilder)

    /// Lifts arm64e rows through the real `MacIRBuilder` so the CFG sees the
    /// production IR (not hand-built operations). Keeps these tests honest: a
    /// regression in the lifting cases (`blraa` -> call, `retaa` -> return) would
    /// change the IR here and break the CFG assertions below.
    private func cfg(forRows rows: [InstructionRow]) -> CFG {
        let function = MacIRBuilder().buildFunction(name: "_authcfg", instructions: rows)
        return CFGBuilder.buildCFG(instructions: function.instructions)
    }

    /// `blraa` (authenticated indirect CALL) must NOT terminate its block — a call
    /// returns, so control flows on to the next instruction. A straight-line
    /// `mov; blraa; retaa` therefore stays a single block whose only exit is the
    /// authenticated return (no spurious split at the call, no in-graph successor).
    func testAuthenticatedCallKeepsFunctionFlowingToReturn() {
        let rows = [
            InstructionRow(address: 0x1000_00000, bytes: "e8 03 00 aa", mnemonic: "mov", operands: "x8, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00004, bytes: "01 11 3f d7", mnemonic: "blraa", operands: "x8, x17", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00008, bytes: "ff 0b 5f d6", mnemonic: "retaa", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let cfg = self.cfg(forRows: rows)

        // The authenticated call did not split the block: all three instructions
        // live in the single entry block.
        XCTAssertEqual(cfg.blocks.count, 1, "blraa must not terminate its block — a call returns")
        XCTAssertEqual(cfg.blocks[0].startIndex, 0)
        XCTAssertEqual(cfg.blocks[0].endIndex, 3)
        // The block's sole exit is the function return (no in-graph successor),
        // and the synthetic exit post-dominates it — i.e. the function has an exit.
        XCTAssertTrue(cfg.blocks[0].successors.isEmpty, "retaa is the only exit; there is no in-graph successor")
        XCTAssertEqual(cfg.entryIndex, 0)
        XCTAssertFalse(cfg.hasUnresolvedTargets, "an authenticated call/return has no static target to leave unresolved")
    }

    /// A conditional-branch diamond whose join block ends in `retaa` must build a
    /// correct CFG: two arms from the entry, both reaching the join, and the
    /// authenticated return as the single function exit (post-dominated by exit).
    func testAuthenticatedReturnTerminatesDiamondJoinBlock() {
        // 0x..00 cbnz x0 -> 0x..0c   (entry, taken skips the then-body)
        // 0x..04 mov  x1, x0         (then-body)
        // 0x..08 b    0x..0c
        // 0x..0c retaa               (join / exit)
        let rows = [
            InstructionRow(address: 0x1000_00000, bytes: "20 00 00 b5", mnemonic: "cbnz", operands: "x0, 0x10000000c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00004, bytes: "e1 03 00 aa", mnemonic: "mov", operands: "x1, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00008, bytes: "01 00 00 14", mnemonic: "b", operands: "0x10000000c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_0000c, bytes: "ff 0b 5f d6", mnemonic: "retaa", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let cfg = self.cfg(forRows: rows)

        // Block 0 = [0] (cbnz), Block 1 = [1,2] (then + b), Block 2 = [3] (retaa join).
        XCTAssertEqual(cfg.blocks.count, 3)
        XCTAssertEqual(Set(cfg.blocks[0].successors), [1, 2], "cbnz: taken (join) + fall-through (then-body)")
        XCTAssertEqual(cfg.blocks[1].successors, [2], "the then-body branches to the join")
        // The retaa join is the function exit: no in-graph successor, and it
        // post-dominates the entry (every path must pass through the return).
        XCTAssertTrue(cfg.blocks[2].successors.isEmpty, "retaa is a return terminator — flows to exit")
        XCTAssertTrue(
            CFGBuilder.postDominates(2, 0, postDomTree: cfg.postDomTree),
            "the authenticated return must post-dominate the entry"
        )
        XCTAssertFalse(cfg.hasUnresolvedTargets)
    }

    /// `braa` (authenticated indirect BRANCH / tail-call) with no recovered jump
    /// table is an indirect-branch terminator: it ends its block and leaves the
    /// graph (no in-graph successor), exactly like a plain `br`.
    func testAuthenticatedIndirectBranchIsTerminatorWithNoSuccessor() {
        let rows = [
            InstructionRow(address: 0x1000_00000, bytes: "e8 03 00 aa", mnemonic: "mov", operands: "x8, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1000_00004, bytes: "01 09 1f d7", mnemonic: "braa", operands: "x8, x17", hasBreakpoint: false, comment: nil),
        ]
        let cfg = self.cfg(forRows: rows)

        // Straight-line into the indirect branch: one block, ending at the braa.
        XCTAssertEqual(cfg.blocks.count, 1)
        XCTAssertTrue(cfg.blocks[0].successors.isEmpty, "braa leaves the graph — no static successor")
        XCTAssertFalse(cfg.hasUnresolvedTargets, "an unresolved indirect branch is intentional, not a structural failure")
    }
}
