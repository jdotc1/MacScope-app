import XCTest
@testable import MacScope

/// Tier 1.6 — data-xref reaching state across CFG boundaries.
///
/// These tests exercise `DataCrossReferenceResolver` directly with crafted
/// instruction-row sequences. The core regression: an `adrp xN, page` formed in one
/// basic block and completed by an `add`/`ldr xN, [xN, #off]` in a SUCCESSOR block
/// (across a branch) must still recover the data xref. The conservative guards must
/// still hold: a genuinely clobbered register, or a caller-saved register written by
/// an intervening call, must NOT produce a phantom xref.
final class DataXRefCFGBoundaryTests: XCTestCase {

    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                       hasBreakpoint: false, comment: nil)
    }

    private let resolver = DataCrossReferenceResolver()

    // A data section [0x4000, 0x5000); the materialized target 0x4010 lands inside it.
    private let dataRanges = [DataCrossReferenceResolver.DataRange(lowerBound: 0x4000, upperBound: 0x5000)]

    func testWritebackInvalidatesPageBaseBeforeSubsequentLoad() {
        for (mnemonic, operands) in [
            ("ldr", "x0, [x8], #0x10"),
            ("ldr", "x0, [x8, #0x10]!"),
            ("str", "x0, [x8], #0x10"),
            ("str", "x0, [x8, #0x10]!"),
            ("ldp", "x0, x1, [x8], #0x10"),
            ("stp", "x0, x1, [x8, #0x10]!"),
        ] {
            let references = resolver.resolve(
                instructions: [row(0x1000, "adrp", "x8, 0x4000"),
                               row(0x1004, mnemonic, operands),
                               row(0x1008, "ldr", "x2, [x8, #0x20]")],
                stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
            )
            XCTAssertTrue(references.filter { $0.from == 0x1008 }.isEmpty,
                          "\(mnemonic) \(operands) must not leave a stale page base")
        }
        let control = resolver.resolve(
            instructions: [row(0x1000, "adrp", "x8, 0x4000"),
                           row(0x1004, "str", "x0, [x8, #0x10]"),
                           row(0x1008, "ldr", "x2, [x8, #0x20]")],
            stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(control.filter { $0.from == 0x1008 }.map(\.to), [0x4020])
    }

    // MARK: - The fix: adrp + add split across a branch

    func testAdrpThenAddAcrossConditionalBranchRecoversDataXRef() {
        // adrp x8, 0x4000 / cbz x1, 0x2000 / add x8, x8, #0x10. The conditional branch's
        // FALL-THROUGH (0x1008) is a real successor, so the base survives and resolves 0x4010.
        let rows = [
            row(0x1000, "adrp", "x8, 0x4000"),
            row(0x1004, "cbz", "x1, 0x2000"),
            row(0x1008, "add", "x8, x8, #0x10"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [
            DataCrossReferenceResolver.Reference(from: 0x1008, to: 0x4010, kind: XRefKind.data)
        ], "page base from adrp must survive a conditional branch so the fall-through-block add resolves")
    }

    func testAdrpThenAddAcrossUNCONDITIONALBranchProducesNoPhantomXRef() {
        // adrp x8, 0x4000 / b 0x9999 (jumps AWAY) / add x8, x8, #0x10. The next linear
        // instruction (0x1008) is NOT the branch's successor, so carrying the base would
        // FABRICATE a reference to 0x4010 (which IS a known data address). The resolver
        // must clear the base at the unconditional branch and emit nothing.
        let rows = [
            row(0x1000, "adrp", "x8, 0x4000"),
            row(0x1004, "b", "0x9999"),
            row(0x1008, "add", "x8, x8, #0x10"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [], "an unconditional branch is not a fall-through; no phantom xref across it")
    }

    func testAdrpThenLdrAcrossConditionalBranchRecoversDataXRef() {
        // adrp x8, 0x4000  /  cbz x0, L  /  L: ldr x9, [x8, #0x10]  -> slot 0x4010.
        let rows = [
            row(0x2000, "adrp", "x8, 0x4000"),
            row(0x2004, "cbz", "x0, 0x2008"),
            row(0x2008, "ldr", "x9, [x8, #0x10]"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [
            DataCrossReferenceResolver.Reference(from: 0x2008, to: 0x4010, kind: XRefKind.data)
        ], "page base must survive a conditional branch for a successor-block ldr to resolve")
    }

    func testStringRefSplitAcrossBranchIsClassifiedAsString() {
        // The materialized 0x4010 is a known string literal address, not just data.
        let rows = [
            row(0x3000, "adrp", "x1, 0x4000"),
            row(0x3004, "tbz", "w0, #1, 0x3008"),
            row(0x3008, "add", "x1, x1, #0x10"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [0x4010], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [
            DataCrossReferenceResolver.Reference(from: 0x3008, to: 0x4010, kind: XRefKind.string)
        ])
    }

    // MARK: - Conservative guards: no phantom xrefs

    func testClobberedRegisterBeforeBranchProducesNoPhantomXRef() {
        // adrp x8 then x8 is OVERWRITTEN (mov) before the branch: the later add must
        // NOT resolve — the tracked base is genuinely dead.
        let rows = [
            row(0x5000, "adrp", "x8, 0x4000"),
            row(0x5004, "mov", "x8, #0x0"),
            row(0x5008, "b", "0x500c"),
            row(0x500c, "add", "x8, x8, #0x10"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [], "a genuinely clobbered register must not produce a phantom xref across a branch")
    }

    func testCallerSavedRegisterIsInvalidatedAcrossCall() {
        // adrp x0 (caller-saved) then bl; the callee may overwrite x0, so the
        // post-call add must NOT resolve.
        let rows = [
            row(0x6000, "adrp", "x0, 0x4000"),
            row(0x6004, "bl", "_callee"),
            row(0x6008, "add", "x0, x0, #0x10"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [], "a caller-saved base must be dropped across a call (no phantom xref)")
    }

    func testCalleeSavedRegisterSurvivesCall() {
        // x19 is callee-saved: its page base survives the call, so the post-call add
        // still resolves the reference. This is the legitimate cross-call recovery.
        let rows = [
            row(0x7000, "adrp", "x19, 0x4000"),
            row(0x7004, "bl", "_callee"),
            row(0x7008, "add", "x19, x19, #0x10"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [
            DataCrossReferenceResolver.Reference(from: 0x7008, to: 0x4010, kind: XRefKind.data)
        ], "a callee-saved (x19–x28) base must survive a call")
    }

    func testStateDoesNotLeakPastReturn() {
        // adrp x19 / ret / add x19 — the ret ends the flow; whatever decodes after is
        // a new region and must not inherit the base. No xref.
        let rows = [
            row(0x8000, "adrp", "x19, 0x4000"),
            row(0x8004, "ret", ""),
            row(0x8008, "add", "x19, x19, #0x10"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [], "reaching state must not leak past a return")
    }

    func testTargetOutsideKnownTablesIsNotEmittedEvenAcrossBranch() {
        // Carrying the base across a (conditional) branch must not, by itself, manufacture
        // an edge: the completed address 0x9010 is in NO known table, so nothing is emitted.
        let rows = [
            row(0xA000, "adrp", "x8, 0x9000"),
            row(0xA004, "cbz", "x1, 0xB000"),
            row(0xA008, "add", "x8, x8, #0x10"),
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [], "a resolved target outside every known table is not a reference")
    }

    func testMultiBlockChainResolvesSelectorSlot() {
        // Realistic multi-block split: adrp in block A, an intervening conditional
        // branch and a callee-saved spill region, then the ldr in block C resolves an
        // objc selector slot.
        let rows = [
            row(0xB000, "adrp", "x20, 0x4000"),
            row(0xB004, "cmp", "x0, #0x0"),          // compares write no register
            row(0xB008, "b.eq", "0xB010"),
            row(0xB00c, "nop", ""),                  // unrelated default-clobber op (no operand)
            row(0xB010, "ldr", "x21, [x20, #0x10]"), // selref slot 0x4010
        ]
        let references = resolver.resolve(
            instructions: rows, stringAddresses: [], selectorSlots: [0x4010], dataRanges: dataRanges
        )
        XCTAssertEqual(references, [
            DataCrossReferenceResolver.Reference(from: 0xB010, to: 0x4010, kind: XRefKind.selref)
        ])
    }

    // MARK: - MS-22: registers written by MOPS, RCW, LSE atomics, PAC 1716 and PAuth_LR

    /// `adrp <reg>, 0x4000` / instruction / `ldr x2, [<reg>, #0x20]`.
    private func referencesAfter(_ mnemonic: String, _ operands: String, pageBaseIn register: String)
        -> [DataCrossReferenceResolver.Reference] {
        resolver.resolve(
            instructions: [row(0x1000, "adrp", "\(register), 0x4000"),
                           row(0x1004, mnemonic, operands),
                           row(0x1008, "ldr", "x2, [\(register), #0x20]")],
            stringAddresses: [], selectorSlots: [], dataRanges: dataRanges
        ).filter { $0.from == 0x1008 }
    }

    func testModernISAWritesClearTrackedPageBases() {
        for (mnemonic, operands, register) in [
            ("setp", "[x8]!, x2!, x3", "x8"),               // MOPS Xd
            ("setgm", "[x0]!, x8!, x3", "x8"),              // MOPS set Xn (bare writeback)
            ("cpyfp", "[x8]!, [x1]!, x2!", "x8"),           // MOPS copy Xd
            ("cpym", "[x0]!, [x8]!, x2!", "x8"),            // MOPS copy Xs
            ("cpyfewtrn", "[x0]!, [x1]!, x8!", "x8"),       // MOPS copy Xn
            ("rcwcas", "x8, x2, [x0]", "x8"),               // RCW CAS writes Xs
            ("rcwscaspal", "x8, x9, x2, x3, [x0]", "x9"),   // RCW CASP writes Xs+1
            ("rcwswp", "x1, x8, [x0]", "x8"),               // RCW SWP writes Xt
            ("rcwsetal", "x1, x8, [x0]", "x8"),             // RCW SET writes Xt
            ("rcwsclrpl", "x1, x8, [x0]", "x8"),            // RCW *P writes Xt2
            ("swpal", "x1, x8, [x0]", "x8"),                // LSE SWP writes Rt
            ("ldaddal", "w1, w8, [x0]", "x8"),              // LSE ld<op> writes Rt (W view)
            ("ldsmaxh", "w1, w8, [x0]", "x8"),
            ("casp", "x8, x9, x2, x3, [x0]", "x9"),         // LSE CASP writes Rs+1
            ("ldraa", "x0, [x8, #0x10]!", "x8"),            // LDRAA pre-index writeback
            ("ldrab", "x8, [x1]", "x8"),                    // LDRAB writes Rt
            ("pacia1716", "", "x17"),
            ("autib171615", "", "x17"),
            ("autiasppcr", "x5", "x30"),                    // PAuth_LR writes LR
            ("paciasppc", "", "x30"),
        ] {
            XCTAssertEqual(referencesAfter(mnemonic, operands, pageBaseIn: register), [],
                           "\(mnemonic) \(operands) must not leave a stale page base in \(register)")
        }
    }

    func testModernISAReadOnlyOperandsKeepTrackedPageBases() {
        let expected = [DataCrossReferenceResolver.Reference(from: 0x1008, to: 0x4020, kind: XRefKind.data)]
        for (mnemonic, operands) in [
            ("autiasppcr", "x8"),           // the modifier is read, never written
            ("autibsppcr", "x8"),
            ("setp", "[x0]!, x1!, x8"),      // the MOPS fill value is read
            ("rcwswp", "x8, x1, [x0]"),     // RCW SWP reads Xs
            ("swp", "x8, x1, [x0]"),        // LSE SWP reads Rs
            ("ldadd", "x8, x1, [x0]"),      // LSE ld<op> reads Rs
            ("pacia171615", ""),            // writes x17 only
        ] {
            XCTAssertEqual(referencesAfter(mnemonic, operands, pageBaseIn: "x8"), expected,
                           "\(mnemonic) \(operands) does not write x8")
        }
    }
}
