import Foundation
import XCTest
@testable import MacScope

final class JumpTableAffineProofTests: XCTestCase {
    private func rows(_ assembly: [(String, String)]) -> [InstructionRow] {
        assembly.enumerated().map { i, a in InstructionRow(address: 0x1000 + UInt64(i * 4),
            bytes: "", mnemonic: a.0, operands: a.1, hasBreakpoint: false, comment: nil) }
    }
    private func induction(step: Int = 16, counterStep: Int = 16) -> [InstructionRow] {
        rows([("cmp", "w0, #16"), ("b.lt", "0x1024"),
            ("mov", "x15, #0"), ("add", "w16, w0, #16"),
            ("add", "x15, x15, #\(step)"), ("sub", "w16, w16, #\(counterStep)"),
            ("cmp", "w16, #31"), ("b.hi", "0x1010"),
            ("sub", "w0, w0, w15"), ("subs", "w15, w0, #1"), ("b.lt", "0x1044"),
            ("adrp", "x9, 0x2000"), ("add", "x9, x9, #0"), ("adr", "x10, 0x1044"),
            ("ldrb", "w11, [x9, x15]"), ("add", "x10, x10, x11, lsl #2"),
            ("br", "x10"), ("ret", "")])
    }
    private func proof(_ rows: [InstructionRow]) -> JumpTableSelectorProof? {
        JumpTableRangeAnalysis.prove(rows: rows, dispatchIndex: 16, jumpTables: [:])
    }
    func testModuloInductionProvesTailWithoutInputWidthContract() throws {
        let result = try XCTUnwrap(proof(induction()))
        XCTAssertEqual(result.caseCount, 15)
        XCTAssertEqual(result.register, "x15")
        // Generality: a different stride and compare bound also prove a tail.
        var changed = induction(step: 8, counterStep: 8)
        changed[0].operands = "w0, #8"; changed[3].operands = "w16, w0, #8"
        changed[6].operands = "w16, #15"
        XCTAssertEqual(proof(changed)?.caseCount, 7)
    }
    func testMismatchedInductionUnknownWritesAndUpperBitsRefuse() {
        XCTAssertNil(proof(induction(step: 17)))
        XCTAssertNil(proof(induction(counterStep: 15)))
        var changed = induction(); changed[4].mnemonic = "ldr"; changed[4].operands = "x15, [x2]"
        XCTAssertNil(proof(changed))
        changed = induction(); changed[9].operands = "x15, x0, #1"
        XCTAssertNil(proof(changed))
        changed = induction(); changed[8].mnemonic = "mov"; changed[8].operands = "w0, w1"
        XCTAssertNil(proof(changed))
    }
    func testBypassOfInitializationDestroysInvariant() {
        var changed = induction()
        changed[1].mnemonic = "cbnz"; changed[1].operands = "w2, 0x1010"
        XCTAssertNil(proof(changed))
    }
    func testBranchBypassingWDefinitionAtOrBeforeCompareRefusesXIndexProof() throws {
        // Both paths have the same low32 range after CMP. Only the fallthrough
        // path executes MOV W0,W0, so X0 may still have arbitrary upper bits on
        // the branch path. Cover a landing before CMP and exactly at CMP (#672).
        for target in ["0x1008", "0x100c"] {
            var input = rows([
                ("cbnz", "w2, \(target)"), ("mov", "w0, w0"),
                ("nop", ""), ("cmp", "w0, #15"), ("b.hi", "0x102c"),
                ("adrp", "x9, 0x2000"), ("add", "x9, x9, #0"),
                ("adr", "x10, 0x102c"), ("ldrb", "w11, [x9, x0]"),
                ("add", "x10, x10, x11, lsl #2"), ("br", "x10"), ("ret", "")
            ])
            XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 10,
                                                     jumpTables: [:]), target)
            // The W-index control proves that the branch/range itself is valid.
            input[8].operands = "w11, [x9, w0, uxtw]"
            XCTAssertEqual(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 10,
                                                       jumpTables: [:])?.caseCount, 16, target)
            // Without the bypass every predecessor executes the W definition.
            input[8].operands = "w11, [x9, x0]"
            input[0].mnemonic = "nop"; input[0].operands = ""
            let admitted = try XCTUnwrap(JumpTableRangeAnalysis.prove(
                rows: input, dispatchIndex: 10, jumpTables: [:]))
            XCTAssertEqual(admitted.caseCount, 16, target)
        }
    }
    func testImplicitPointerAuthenticationWritesDestroyScalarProofs() {
        for mnemonic in ["paciasp", "pacibsp", "autiasp", "autibsp", "paciaz", "pacibz",
                         "autiaz", "autibz", "xpaclri"] {
            let input = rows([("cmp", "w0, #16"), ("b.ge", "0x1030"),
                ("subs", "w30, w0, #1"), ("b.lt", "0x1030"),
                (mnemonic, ""), ("adrp", "x9, 0x2000"), ("add", "x9, x9, #0"),
                ("adr", "x10, 0x1030"), ("ldrb", "w11, [x9, x30]"),
                ("add", "x10, x10, x11, lsl #2"), ("br", "x10"), ("nop", ""), ("ret", "")])
            XCTAssertTrue(JumpTableResolver.rangeWrittenRegisters(input[4]).contains("x30"), mnemonic)
            XCTAssertNil(JumpTableRangeAnalysis.prove(rows: input, dispatchIndex: 10, jumpTables: [:]), mnemonic)
        }
        var raw = induction(); raw[12].mnemonic = "hint"; raw[12].operands = "#7"
        XCTAssertNil(proof(raw), "unclassified hint aliases cannot carry stale implicit writes")
    }

    func testAffineModuleKeepsTorsionAndDoesNotTreatEvenPivotsAsUnits() {
        var state = JumpTableAffineState(count: 2, independent: false)
        XCTAssertTrue(state.insert([2, 1]))
        XCTAssertNil(state.constant(terms: [(1, 1)]))
        XCTAssertEqual(state.constant(terms: [(0, 1), (1, UInt32.max - 1)]), 0)
        XCTAssertFalse(state.insert([0, 0x8000_0000]), "torsion vector is already generated")
        XCTAssertTrue(state.insert([1, 0]))
        XCTAssertNil(state.constant(terms: [(0, 1), (1, UInt32.max - 1)]))
    }
    func testAffineTransfersAndJoinsCoverWrapAndIndependentWrites() {
        var first = JumpTableAffineState(count: 3)
        first.assign(1, terms: [], constant: 0)
        first.assign(2, terms: [(0, 1)], constant: 16)
        var next = first
        next.assign(1, terms: [(1, 1)], constant: 16)
        next.assign(2, terms: [(2, 1)], constant: UInt32.max - 15)
        XCTAssertTrue(first.join(next))
        let relation: [(Int, UInt32)] = [(2, 1), (1, 1), (0, UInt32.max)]
        XCTAssertEqual(first.constant(terms: relation), 16)
        var twice = next
        twice.assign(1, terms: [(1, 1)], constant: 16)
        twice.assign(2, terms: [(2, 1)], constant: UInt32.max - 15)
        XCTAssertFalse(first.join(twice))
        first.forget(1)
        XCTAssertNil(first.constant(terms: relation))
    }
    func testModuleClaimedEqualitiesHoldForAdversarialGeneratedPoints() {
        var generator = UInt64(0x6936_6166_6669_6e65)
        func random() -> UInt32 { generator = generator &* 6364136223846793005 &+ 1442695040888963407; return UInt32(truncatingIfNeeded: generator >> 17) }
        for valuation in [0, 1, 4, 16, 31] {
            var state = JumpTableAffineState(count: 3, independent: false)
            let row: [UInt32] = [UInt32(1) << valuation, random(), random()]
            state.insert(row)
            for coefficient: UInt32 in [0, 1, 2, 0x7fff_ffff, 0x8000_0000, UInt32.max] {
                XCTAssertFalse(state.insert(row.map { $0 &* coefficient }))
            }
            for _ in 0..<32 {
                let terms: [(Int, UInt32)] = [(0, random()), (1, random()), (2, random())]
                if let claimed = state.constant(terms: terms) {
                    XCTAssertEqual(claimed, 0)
                    XCTAssertEqual(terms.reduce(UInt32(0)) { $0 &+ row[$1.0] &* $1.1 }, 0)
                }
            }
        }
    }
}
