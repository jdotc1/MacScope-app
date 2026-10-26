import XCTest
@testable import MacScope

final class RegionTreeTests: XCTestCase {
    /// Builds the region tree for a row fixture via the real IR builder + CFG.
    private func regionTree(_ rows: [InstructionRow]) -> Region? {
        let function = MacIRBuilder().buildFunction(name: "_f", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        return RegionTree.build(cfg: cfg, instructions: function.instructions)
    }

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ comment: String? = nil) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: comment)
    }

    // MARK: - block

    func testLinearFunctionIsASingleBlockRegion() throws {
        let rows = [
            row(0x1000, "nop", ""),
            row(0x1004, "ret", "")
        ]
        let region = try XCTUnwrap(regionTree(rows))
        // A single straight-line block.
        if case .block = region { return }
        if case let .sequence(items) = region, items.allSatisfy({ if case .block = $0 { return true } else { return false } }) { return }
        XCTFail("expected a block/sequence-of-blocks region, got \(region)")
    }

    // MARK: - ifThen

    func testCompareGuardOverFallthroughIsIfThen() throws {
        let rows = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x100c", "skip"),
            row(0x1008, "nop", "", "body"),
            row(0x100c, "ret", "")
        ]
        let region = try XCTUnwrap(regionTree(rows))
        guard case let .ifThen(cond, _, _, _) = topRegion(region) else {
            return XCTFail("expected ifThen, got \(region)")
        }
        XCTAssertFalse(cond.isZeroCheck)
        XCTAssertNotNil(cond.compareIndex)
    }

    // MARK: - ifThenElse diamond

    func testCompareGuardToElseArmIsIfThenElse() throws {
        let rows = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1010", "else"),
            row(0x1008, "nop", "", "then"),
            row(0x100c, "b", "0x1014"),
            row(0x1010, "nop", "", "else body"),
            row(0x1014, "ret", "")
        ]
        let region = try XCTUnwrap(regionTree(rows))
        guard case .ifThenElse = topRegion(region) else {
            return XCTFail("expected ifThenElse, got \(region)")
        }
    }

    // MARK: - while

    func testGuardedBackEdgeIsWhileLoop() throws {
        let rows = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1010", "exit"),
            row(0x1008, "nop", "", "body"),
            row(0x100c, "b", "0x1000"),
            row(0x1010, "ret", "")
        ]
        let region = try XCTUnwrap(regionTree(rows))
        guard case .whileLoop = topRegion(region) else {
            return XCTFail("expected whileLoop, got \(region)")
        }
    }

    // MARK: - do-while

    func testBottomTestedBackEdgeIsDoWhileLoop() throws {
        let rows = [
            row(0x1000, "nop", "", "body"),
            row(0x1004, "cmp", "x0, #0x0"),
            row(0x1008, "b.ne", "0x1000", "back-edge"),
            row(0x100c, "ret", "")
        ]
        let region = try XCTUnwrap(regionTree(rows))
        guard case .doWhileLoop = topRegion(region) else {
            return XCTFail("expected doWhileLoop, got \(region)")
        }
    }

    // MARK: - supported double guards

    func testDoubleCompareGuardChainUsesRegionFusion() {
        let rows = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1014", "first"),
            row(0x1008, "cmp", "x1, #0x0"),
            row(0x100c, "b.eq", "0x1014", "second"),
            row(0x1010, "nop", "", "body"),
            row(0x1014, "ret", "")
        ]
        let region = regionTree(rows)
        XCTAssertFalse(containsIrreducible(region))
        guard let region, case .ifThen = topRegion(region) else {
            return XCTFail("expected supported double-guard ifThen")
        }
        let function = MacIRBuilder().buildFunction(name: "_guards", instructions: rows)
        XCTAssertTrue(PseudocodePrinter().print(function: function).text.contains("arg0 != 0x0 && arg1 != 0x0"))
    }

    // MARK: - irreducible fallback

    func testIrreducibleCFGReturnsNilTree() {
        // Multi-entry mutual loop → build returns nil (no clean tree).
        let rows = [
            row(0x1000, "cbnz", "x0, 0x1008", "to B"),
            row(0x1004, "cbnz", "x1, 0x100c", "A: to exit"),
            row(0x1008, "cbnz", "x2, 0x1004", "B: to A"),
            row(0x100c, "ret", "")
        ]
        let function = MacIRBuilder().buildFunction(name: "_irr", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        if !cfg.irreducibleBlocks.isEmpty {
            XCTAssertNil(RegionTree.build(cfg: cfg, instructions: function.instructions))
        }
    }

    // MARK: - nested-if-inside-while (the case the old code BROKE)

    func testNestedIfInsideWhileStructuresCleanly() throws {
        // while (arg0 != 0) { if (arg1) { nop } ; nop ; }  — the legacy peephole
        // structurer broke on nesting; the region builder must recover it.
        let rows = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x101c", "loop exit"),
            row(0x1008, "cbz", "x1, 0x1010", "inner guard"),
            row(0x100c, "nop", "", "inner body"),
            row(0x1010, "nop", "", "after inner"),
            row(0x1014, "nop", "", "tail"),
            row(0x1018, "b", "0x1000", "back-edge"),
            row(0x101c, "ret", "")
        ]
        let region = try XCTUnwrap(regionTree(rows))
        guard case let .whileLoop(_, body, _) = topRegion(region) else {
            return XCTFail("expected whileLoop, got \(region)")
        }
        XCTAssertTrue(containsIfThen(body), "the while body must contain a nested ifThen")
    }

    // MARK: - REGRESSION (Fix 1): switch with in-function cases bails to legacy

    private func instr(_ index: Int, mnemonic: String, _ operation: MacIROperation) -> MacIRInstruction {
        MacIRInstruction(
            source: MacIRSourceSpan(address: 0x1000 + UInt64(index) * 4, byteText: "00 00 00 00", mnemonic: mnemonic, operands: ""),
            operation: operation
        )
    }

    private func switchCaseAddr(_ index: Int) -> Int64 { Int64(0x1000 + index * 4) }

    func testSwitchWithInFunctionCasesYieldsIrreducible() {
        // idx0: switch -> case0=idx1, case1=idx2, default=idx3; all merge at idx4.
        let instructions: [MacIRInstruction] = [
            instr(0, mnemonic: "br", .switchDispatch(
                index: .register(name: "x0", version: 0),
                cases: [
                    MacIRSwitchCase(value: 0, target: .immediate(switchCaseAddr(1))),
                    MacIRSwitchCase(value: 1, target: .immediate(switchCaseAddr(2)))
                ],
                defaultTarget: .immediate(switchCaseAddr(3))
            )),
            instr(1, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: [])),
            instr(2, mnemonic: "b", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(switchCaseAddr(4))])),
            instr(3, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: [])),
            instr(4, mnemonic: "b", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(switchCaseAddr(4))])),
            instr(5, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: [])),
            instr(6, mnemonic: "nop", .intrinsic(destination: nil, name: "nop", arguments: [])),
            instr(7, mnemonic: "ret", .returnValue(nil))
        ]
        let cfg = CFGBuilder.buildCFG(instructions: instructions)
        let region = RegionTree.build(cfg: cfg, instructions: instructions)
        // The dispatch block has in-graph successors → must bail (irreducible
        // leaf), so the printer renders the full function via legacy goto.
        XCTAssertTrue(containsIrreducible(region), "an in-function switch must yield an irreducible leaf (legacy goto), never a clean switchDispatch that drops the join")
    }

    // MARK: - REGRESSION (Fix 2): nested loop build must terminate (no crash)

    func testNestedLoopBuildTerminatesWithoutCrash() {
        let rows = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x101c", "outer exit"),
            row(0x1008, "cmp", "x1, #0x0"),
            row(0x100c, "b.eq", "0x1014", "inner exit"),
            row(0x1010, "b", "0x1008", "inner back-edge"),
            row(0x1014, "nop", "", "outer tail"),
            row(0x1018, "b", "0x1000", "outer back-edge"),
            row(0x101c, "ret", "")
        ]
        // The only requirement is that this returns (does not recurse forever /
        // crash). Either a clean tree or nil/irreducible is acceptable.
        _ = regionTree(rows)
    }

    // MARK: - helpers

    /// Unwraps a single-item sequence to its sole region for top-level matching.
    private func topRegion(_ region: Region) -> Region {
        if case let .sequence(items) = region {
            // Skip leading/trailing plain blocks to find the structured construct.
            for item in items {
                switch item {
                case .ifThen, .ifThenElse, .whileLoop, .doWhileLoop, .naturalLoop, .switchDispatch:
                    return item
                default:
                    continue
                }
            }
            return items.first ?? region
        }
        return region
    }

    private func containsIfThen(_ region: Region) -> Bool {
        switch region {
        case .ifThen:
            return true
        case let .sequence(items):
            return items.contains(where: containsIfThen)
        case let .ifThenElse(_, t, e, _):
            return containsIfThen(t) || containsIfThen(e)
        case let .whileLoop(_, b, _), let .doWhileLoop(b, _), let .naturalLoop(b, _):
            return containsIfThen(b)
        default:
            return false
        }
    }

    private func containsIrreducible(_ region: Region?) -> Bool {
        guard let region else { return true }
        switch region {
        case .irreducible:
            return true
        case let .sequence(items):
            return items.contains(where: { containsIrreducible($0) })
        case let .ifThen(_, b, _, _):
            return containsIrreducible(b)
        case let .ifThenElse(_, t, e, _):
            return containsIrreducible(t) || containsIrreducible(e)
        case let .whileLoop(_, b, _), let .doWhileLoop(b, _), let .naturalLoop(b, _):
            return containsIrreducible(b)
        default:
            return false
        }
    }

    // MARK: - early-exit (guard clause)

    /// `if (cond) { …; return; }` then continue: the fall-through arm always returns and the
    /// taken target is the continuation. The branch has NO in-graph post-dominator join (both
    /// paths reach the function exit), so the structurer used to bail to `.irreducible`; the
    /// early-exit rule recovers an `ifThen` guard followed by the continuation.
    func testEarlyExitGuardIsStructuredNotIrreducible() throws {
        let rows = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x1010", "skip the guard body"),
            row(0x1008, "mov", "x0, #0x1", "guard body"),
            row(0x100c, "ret", ""),                 // fall-through arm returns
            row(0x1010, "nop", "", "continuation"),
            row(0x1014, "ret", "")
        ]
        let region = try XCTUnwrap(regionTree(rows))
        XCTAssertFalse(containsIrreducible(region), "early-exit guard must structure, not bail to goto: \(region)")
        XCTAssertTrue(containsIfThen(region), "expected an ifThen guard, got \(region)")
    }

    /// `if (cond) return A; return B;` — BOTH arms exit. Still a faithful guard + tail return
    /// (`if (!cc) { return A; } return B;`), never `.irreducible`.
    func testBothArmsReturnIsStructured() throws {
        let rows = [
            row(0x1000, "cmp", "x0, #0x0"),
            row(0x1004, "b.eq", "0x100c", "to the second return"),
            row(0x1008, "ret", ""),                 // fall-through returns
            row(0x100c, "mov", "x0, #0x2", "taken: second return"),
            row(0x1010, "ret", "")
        ]
        let region = try XCTUnwrap(regionTree(rows))
        XCTAssertFalse(containsIrreducible(region))
        XCTAssertTrue(containsIfThen(region))
    }
}
