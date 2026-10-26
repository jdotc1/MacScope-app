import XCTest
@testable import MacScope

/// Unit tests for the trusted-gate layer (`GoldenGate`) and the addressing-offset normalization it
/// relies on. These are deterministic and fixture-free: they build synthetic `GoldenOutput`s, so
/// they run in CI without any oracle JSON. The end-to-end gate (against `/bin/ls` + a captured
/// oracle) lives in `GoldenDifferentialTests`.
final class GoldenGateTests: XCTestCase {

    // MARK: - Fixtures

    private let textLo: UInt64 = 0x1_0000_3000
    private let stubLo: UInt64 = 0x1_0000_7000
    private let objcStubLo: UInt64 = 0x1_0000_8000
    private let dataLo: UInt64 = 0x1_0000_c000

    private func sectionsFixture() -> [GoldenSection] {
        [
            GoldenSection(name: "__TEXT,__text", address: hex(textLo), size: 0x1000,
                          fileOffset: 0, isExecutable: true, isZeroFill: false),
            GoldenSection(name: "__TEXT,__auth_stubs", address: hex(stubLo), size: 0x1000,
                          fileOffset: 0, isExecutable: true, isZeroFill: false),
            GoldenSection(name: "__TEXT,__objc_stubs", address: hex(objcStubLo), size: 0x1000,
                          fileOffset: 0, isExecutable: true, isZeroFill: false),
            GoldenSection(name: "__DATA,__data", address: hex(dataLo), size: 0x1000,
                          fileOffset: 0, isExecutable: false, isZeroFill: false)
        ]
    }

    private func hex(_ v: UInt64) -> String { "0x" + String(format: "%016llx", v) }

    private func output(symbols: [GoldenSymbol] = [], imports: [GoldenImport] = [],
                        instructions: [GoldenInstruction] = [], procedures: [GoldenProcedure] = [],
                        sections: [GoldenSection]? = nil) -> GoldenOutput {
        GoldenOutput(
            schemaVersion: 1,
            binary: GoldenBinary(name: "ls", pathBasename: "ls", kind: "executable",
                                 architecture: "arm64", hasEmbeddedUUID: true,
                                 platformName: "macOS", minimumOSVersion: "12.0",
                                 sdkVersion: "14.0", buildTools: []),
            sections: sections ?? sectionsFixture(),
            symbols: symbols, imports: imports, exports: [],
            instructions: instructions, procedures: procedures, basicBlocks: [],
            controlFlowEdges: [], crossReferences: [], demangledNames: [], pseudocode: []
        )
    }

    private func instr(_ addr: UInt64, _ mnem: String, _ ops: String) -> GoldenInstruction {
        GoldenInstruction(address: hex(addr), bytes: "00 00 00 00", mnemonic: mnem, operands: ops, comment: nil)
    }
    private func proc(_ name: String, _ addr: UInt64) -> GoldenProcedure {
        GoldenProcedure(name: name, startAddress: hex(addr), endAddress: hex(addr + 0x40), confidence: 1)
    }
    private func sym(_ name: String, _ addr: UInt64, kind: String = "function") -> GoldenSymbol {
        GoldenSymbol(name: name, address: hex(addr), kind: kind, libraryName: nil)
    }

    // MARK: - OperandNormalizer: addressing-offset sign/width fold

    /// The reference renders a negative pre/post-index offset as a width-masked UNSIGNED hex; MacScope and
    /// reference output render it signed. Inside `[...]` these must compare equivalent.
    func testBracketOffsetSignWidthEquivalence() {
        XCTAssertTrue(OperandNormalizer.equivalent("x29, x30, [sp, #-0x10]!", "fp, lr, [sp, #0xfff0]!"))
        XCTAssertTrue(OperandNormalizer.equivalent("x8, [x29, #-0x60]", "x8, [fp, #0xffa0]"))
        XCTAssertTrue(OperandNormalizer.equivalent("x20, x19, [sp, #-0x20]!", "x20, x19, [sp, #0xffe0]!"))
    }

    /// The fold must NOT collapse genuinely-different offsets, nor reach OUTSIDE brackets (a branch
    /// or `adr` target is a real absolute address, never sign-folded).
    func testBracketOffsetFoldIsConservative() {
        XCTAssertFalse(OperandNormalizer.equivalent("x8, [x29, #0x10]", "x8, [x29, #0x20]"))
        XCTAssertFalse(OperandNormalizer.equivalent("x8, [x29, #-0x60]", "x8, [x29, #-0x64]"))
        // Outside brackets: a small value and its 64-bit two's-complement are DIFFERENT addresses.
        XCTAssertFalse(OperandNormalizer.equivalent("0x8000", "0xffffffffffff8000"))
    }

    // MARK: - Gate: decode

    func testDecodeMismatchIsGated() {
        let a = output(instructions: [instr(textLo + 0x100, "add", "x0, x1, x2")])
        let r = output(instructions: [instr(textLo + 0x100, "sub", "x0, x1, x2")])
        let v = GoldenGate.evaluate(actual: a, reference: r)
        XCTAssertFalse(v.passes)
        XCTAssertEqual(v.gated.filter { $0.capability == "instructions" }.count, 1)
    }

    func testEquivalentInstructionIsNotGated() {
        // Differ only by the reference masked-offset rendering — the normalizer collapses them.
        let a = output(instructions: [instr(textLo + 0x200, "ldur", "x8, [x29, #-0x60]")])
        let r = output(instructions: [instr(textLo + 0x200, "ldur", "x8, [fp, #0xffa0]")])
        let v = GoldenGate.evaluate(actual: a, reference: r)
        XCTAssertTrue(v.passes)
        XCTAssertTrue(v.gated.isEmpty)
    }

    func testAllowlistedDecodeDeltaIsAcceptedNotGated() {
        // The shipped allowlist accepts the BFI/BFM alias at 0x100003748.
        let addr: UInt64 = 0x1_0000_3748
        let a = output(instructions: [instr(addr, "bfi", "x10, x23, #1, #63")])
        let r = output(instructions: [instr(addr, "bfm", "x10, x23, #0x3f, #0x3e")])
        let v = GoldenGate.evaluate(actual: a, reference: r)
        XCTAssertTrue(v.passes)
        XCTAssertTrue(v.gated.isEmpty)
        XCTAssertEqual(v.accepted.count, 1)
    }

    // MARK: - Gate: function coverage

    func testMissingNamedFunctionIsGated() {
        let r = output(procedures: [proc("_helper", textLo + 0x800)])
        let v = GoldenGate.evaluate(actual: output(), reference: r)
        XCTAssertFalse(v.passes)
        XCTAssertEqual(v.gated.filter { $0.capability == "procedures" }.count, 1)
    }

    func testStubAutoAndOutOfImageFunctionsAreNotGated() {
        let r = output(procedures: [
            proc("imp___auth_stubs__exit", stubLo + 0x10),  // import stub → modeled as import
            proc("name", objcStubLo + 0x20),                // `_objc_msgSend$name` selector stub
            proc("stringWithFormat:", objcStubLo + 0x40),   // another __objc_stubs dispatch stub
            proc("FUN_100003900", textLo + 0x900),          // unnamed auto-discovered
            proc("_weird", 0xffff_ff00)                      // outside the loaded image
        ])
        let v = GoldenGate.evaluate(actual: output(), reference: r)
        XCTAssertTrue(v.passes, "\(v.lines)")
        XCTAssertTrue(v.gated.isEmpty)
    }

    /// An oracle "function" whose start falls INSIDE a function MacScope already discovered is a
    /// boundary disagreement (the oracle over-split / over-discovered a mid-function entry, e.g.
    /// reference output creating `FUN_…ec` at the `stp` right after an arm64e `pacibsp` prologue), NOT a
    /// missing function. It must not be gated even when the oracle gives it a real-looking name.
    func testOracleFunctionInsideMacScopeFunctionIsNotGated() {
        let a = output(procedures: [proc("_outer", textLo + 0x100)])           // spans +0x100..+0x140
        let r = output(procedures: [proc("_inner", textLo + 0x110)])           // mid-body, real name
        let v = GoldenGate.evaluate(actual: a, reference: r)
        XCTAssertTrue(v.passes, "\(v.lines)")
    }

    // MARK: - Gate: symbol coverage

    func testMissingNamedCodeSymbolIsGated() {
        let r = output(symbols: [sym("_realfunc", textLo + 0xa00)])
        let v = GoldenGate.evaluate(actual: output(), reference: r)
        XCTAssertFalse(v.passes)
        XCTAssertEqual(v.gated.filter { $0.capability == "symbols" }.count, 1)
    }

    func testAutoLabelImportDataAndOutOfImageSymbolsAreNotGated() {
        let r = output(symbols: [
            sym("loc_100003a10", textLo + 0xa10),            // auto-generated code label
            sym("switch_table_100003a20", textLo + 0xa20),   // switch-table label in __text
            sym("byte_10000c024", dataLo + 0x24),            // data label (non-executable)
            sym("___assert_rtn", textLo + 0xb00),            // a libSystem import (modeled separately)
            sym("_objc_msgSend_rtp", 0xfffe_ff00)            // oracle-synthetic, outside the image
        ])
        let a = output(imports: [GoldenImport(name: "___assert_rtn", libraryName: "libSystem", libraryOrdinal: 1)])
        let v = GoldenGate.evaluate(actual: a, reference: r)
        XCTAssertTrue(v.passes, "\(v.lines)")
        XCTAssertTrue(v.gated.isEmpty)
    }

    /// A named code symbol inside a function MacScope already discovered is a labeling difference
    /// (a local entry the oracle named within MacScope's function), not missing coverage — MacScope
    /// decoded that code as part of a function. Not gated.
    func testOracleSymbolInsideMacScopeFunctionIsNotGated() {
        let a = output(procedures: [proc("_fn", textLo + 0x100)])              // spans +0x100..+0x140
        let r = output(symbols: [sym("_locallabel", textLo + 0x120)])          // mid-body, real name
        let v = GoldenGate.evaluate(actual: a, reference: r)
        XCTAssertTrue(v.passes, "\(v.lines)")
    }

    /// A symbol MacScope already has at the same address must not be reported as a coverage gap,
    /// even if the oracle named it differently (coverage is keyed by address, not name).
    func testSymbolPresentAtAddressIsNotGatedDespiteDifferentName() {
        let a = output(symbols: [sym("_main", textLo + 0xc0)])
        let r = output(symbols: [sym("entry", textLo + 0xc0)])  // same address, oracle's name
        let v = GoldenGate.evaluate(actual: a, reference: r)
        XCTAssertTrue(v.passes, "\(v.lines)")
    }

    // MARK: - Gate: imports

    func testImportMatchIsNotGated() {
        let a = output(imports: [
            GoldenImport(name: "_printf", libraryName: "/usr/lib/libSystem.B.dylib", libraryOrdinal: 1)
        ])
        let r = output(imports: [
            GoldenImport(name: "printf", libraryName: nil, libraryOrdinal: nil)
        ])

        let v = GoldenGate.evaluate(actual: a, reference: r)

        XCTAssertTrue(v.passes, "\(v.lines)")
        XCTAssertTrue(v.gated.filter { $0.capability == "imports" }.isEmpty)
        XCTAssertTrue(v.accepted.isEmpty)
    }

    func testMissingReferenceImportIsGated() {
        let r = output(imports: [
            GoldenImport(name: "_printf", libraryName: "/usr/lib/libSystem.B.dylib", libraryOrdinal: 1)
        ])

        let v = GoldenGate.evaluate(actual: output(), reference: r)

        XCTAssertFalse(v.passes)
        XCTAssertEqual(v.gated.filter { $0.capability == "imports" }.count, 1)
        XCTAssertTrue(v.accepted.isEmpty)
    }

    func testAllowlistedImportDeltaIsAcceptedNotGated() {
        let r = output(imports: [
            GoldenImport(name: "_optional_toolchain_import", libraryName: nil, libraryOrdinal: nil)
        ])
        let allowlist = [
            GoldenAcceptedDelta(kind: .imports,
                                key: "_optional_toolchain_import",
                                reason: "synthetic accepted import delta")
        ]

        let v = GoldenGate.evaluate(actual: output(), reference: r, allowlist: allowlist)

        XCTAssertTrue(v.passes, "\(v.lines)")
        XCTAssertTrue(v.gated.isEmpty)
        XCTAssertEqual(v.accepted.filter { $0.capability == "imports" }.count, 1)
    }

    // MARK: - Gate: clean pass on pure oracle-scope differences

    func testOracleScopeOnlyDifferencesPass() {
        // MacScope is richer (imports, an extra instruction); the oracle is a sparse subset. None of
        // that is a decode error or a coverage regression, so the gate passes.
        let a = output(
            symbols: [sym("_main", textLo + 0x100)],
            imports: [GoldenImport(name: "_printf", libraryName: "libSystem", libraryOrdinal: 1)],
            instructions: [instr(textLo + 0x100, "stp", "x29, x30, [sp, #-0x10]!"),
                           instr(textLo + 0x104, "mov", "x29, sp")],
            procedures: [proc("_main", textLo + 0x100)]
        )
        let r = output(
            symbols: [sym("_main", textLo + 0x100)],
            instructions: [instr(textLo + 0x100, "stp", "fp, lr, [sp, #0xfff0]!")],
            procedures: [proc("_main", textLo + 0x100)]
        )
        let v = GoldenGate.evaluate(actual: a, reference: r)
        XCTAssertTrue(v.passes, "\(v.lines)")
        XCTAssertFalse(v.reported.isEmpty, "non-gated differences should still be reported")
    }
}
