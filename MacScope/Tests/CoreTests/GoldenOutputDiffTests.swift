import XCTest
@testable import MacScope

/// The differential core: a structured, per-capability diff over the normalized
/// `GoldenOutput` schema. This is the MacScope-vs-oracle comparison engine — it must report
/// every SEMANTIC difference (a different mnemonic, a missing symbol, an extra xref) and must
/// never hide one behind normalization. Tested entirely with synthetic golden models, so it
/// is verifiable without a live oracle capture; the reference fixtures are imported separately.
final class GoldenOutputDiffTests: XCTestCase {

    // MARK: - Operand normalization (cross-disassembler cosmetics)

    /// Provably-equivalent surface forms must compare equal so the differential reports only real
    /// decode divergences, not each oracle's pretty-printing.
    func testOperandNormalizerCollapsesCosmeticDifferences() {
        let eq = OperandNormalizer.equivalent
        XCTAssertTrue(eq("w0, #1", "w0, #0x1"))                         // decimal vs hex
        XCTAssertTrue(eq("w8, #0", "w8, #0x0"))                         // zero
        XCTAssertTrue(eq("w0, #-0x1", "w0, #0xffffffff"))               // signed vs unsigned, 32-bit
        XCTAssertTrue(eq("x0, #-0x1", "x0, #0xffffffffffffffff"))       // signed vs unsigned, 64-bit
        XCTAssertTrue(eq("x29, sp", "fp, sp"))                          // fp == x29
        XCTAssertTrue(eq("x30, x0", "lr, x0"))                          // lr == x30
        XCTAssertTrue(eq("x8, 0x000000010000c000", "x8, 0x10000c000"))  // address zero-padding
        XCTAssertTrue(eq("x8, 0x000000010000c000", "x8, #0x10000c000")) // leading # on an address
        XCTAssertTrue(eq("w0,#0x1", "w0, #0x1"))                        // comma spacing (reference output style)
        XCTAssertTrue(eq("x29, x30, [sp, #-0x10]!", "x29,x30,[sp,#-0x10]!"))
        // immediate shift fold: #0x6 lsl 12 == #0x6000
        XCTAssertTrue(eq("w8, #0x6000", "w8, #0x6, lsl #12"))
        XCTAssertTrue(eq("w8, w0, #0x1000", "w8, w0, #0x1, lsl #12"))
        // explicit zero / empty register-offset shift == no shift (reference output)
        XCTAssertTrue(eq("x0, [x28, x8]", "x0, [x28, x8, lsl #0x0]"))
        XCTAssertTrue(eq("w8, [x11, x9]", "w8, [x11, x9, LSL ]"))
        // condition-code synonyms (HS==CS, LO==CC)
        XCTAssertEqual(OperandNormalizer.canonicalMnemonic("b.cc"), OperandNormalizer.canonicalMnemonic("b.lo"))
        XCTAssertEqual(OperandNormalizer.canonicalMnemonic("b.cs"), OperandNormalizer.canonicalMnemonic("b.hs"))
    }

    /// The fold must NOT touch a register shift (that would corrupt a real shifted-register operand).
    func testOperandNormalizerLeavesRegisterShiftIntact() {
        XCTAssertFalse(OperandNormalizer.equivalent("x0, x1, x2, lsl #3", "x0, x1, x2, lsl #4"))
        XCTAssertFalse(OperandNormalizer.equivalent("x0, x1, x2, lsl #3", "x0, x1, x2"))
        // a register shift is not an immediate fold, so x2 lsl 3 != the immediate #0x10
        XCTAssertFalse(OperandNormalizer.equivalent("x0, x1, x2, lsl #3", "x0, x1, #0x10"))
    }

    /// CONSERVATISM: a different register, a different immediate value, or different structure must
    /// still compare UNEQUAL — the normalizer must not hide a real bug.
    func testOperandNormalizerKeepsRealDifferences() {
        let eq = OperandNormalizer.equivalent
        XCTAssertFalse(eq("x0, x1", "x0, x2"))          // different source register
        XCTAssertFalse(eq("w0, #1", "w0, #2"))          // different immediate
        XCTAssertFalse(eq("x0, #0x10", "x0, #0x20"))    // different immediate
        XCTAssertFalse(eq("x29, sp", "x28, sp"))        // fp(=x29) != x28
        XCTAssertFalse(eq("w0, #-0x1", "w0, #0x1"))     // -1 != 1
        XCTAssertFalse(eq("[sp, #0x8]", "[sp, #0x10]")) // different memory offset
    }

    /// A small but complete normalized model spanning every collection.
    private func makeGolden() -> GoldenOutput {
        GoldenOutput(
            schemaVersion: GoldenOutput.currentSchemaVersion,
            binary: GoldenBinary(name: "ls", pathBasename: "ls", kind: "executable",
                                 architecture: "arm64", hasEmbeddedUUID: true, platformName: "macOS",
                                 minimumOSVersion: "12.0", sdkVersion: "14.0", buildTools: []),
            sections: [GoldenSection(name: "__text", address: "0x1000", size: 256, fileOffset: 0,
                                     isExecutable: true, isZeroFill: false)],
            symbols: [GoldenSymbol(name: "_main", address: "0x1000", kind: "function", libraryName: nil)],
            imports: [GoldenImport(name: "_printf", libraryName: "libSystem", libraryOrdinal: 1)],
            exports: [GoldenExport(name: "_main", address: "0x1000", source: "symtab")],
            instructions: [GoldenInstruction(address: "0x1000", bytes: "fd 7b bf a9", mnemonic: "stp",
                                             operands: "x29, x30, [sp, #-0x10]!", comment: nil)],
            procedures: [GoldenProcedure(name: "_main", startAddress: "0x1000", endAddress: "0x1100",
                                         confidence: 1.0)],
            basicBlocks: [GoldenBasicBlock(procedureStartAddress: "0x1000", startAddress: "0x1000",
                                           endAddress: "0x1100", instructionCount: 4)],
            controlFlowEdges: [GoldenEdge(from: "0x1000", to: "0x1100", kind: "fallthrough")],
            crossReferences: [GoldenXRef(from: "0x1004", to: "0x2000", kind: "call")],
            demangledNames: [GoldenDemangledName(mangled: "_Z3fooi", demangled: "foo(int)")],
            pseudocode: [GoldenPseudocode(procedureStartAddress: "0x1000", procedureName: "_main",
                                          returnType: "int", lines: ["int _main() {", "}"])]
        )
    }

    func testIdenticalOutputsMatch() {
        let diff = GoldenOutputDiff.compare(actual: makeGolden(), reference: makeGolden())
        XCTAssertTrue(diff.matches)
        XCTAssertTrue(diff.capabilities.allSatisfy(\.matches))
    }

    /// The critical guarantee: a changed mnemonic at the same address is a MISMATCH, not
    /// something normalization can swallow.
    func testChangedInstructionIsReportedNotHidden() {
        var actual = makeGolden()
        actual.instructions[0].mnemonic = "nop"
        let diff = GoldenOutputDiff.compare(actual: actual, reference: makeGolden())
        XCTAssertFalse(diff.matches)
        XCTAssertEqual(diff.capability(named: "instructions")?.mismatched, ["0x1000"])
    }

    func testMissingAndExtraSymbolsAreReported() {
        var actual = makeGolden()
        actual.symbols = [GoldenSymbol(name: "_start", address: "0x900", kind: "function", libraryName: nil)]
        let diff = GoldenOutputDiff.compare(actual: actual, reference: makeGolden())
        let symbols = diff.capability(named: "symbols")
        XCTAssertEqual(symbols?.onlyInActual, ["_start@0x900"])      // ours, not in reference
        XCTAssertEqual(symbols?.onlyInReference, ["_main@0x1000"])   // reference's, not ours
    }

    func testSchemaVersionMismatchIsFlagged() {
        var reference = makeGolden()
        reference.schemaVersion = GoldenOutput.currentSchemaVersion + 1
        let diff = GoldenOutputDiff.compare(actual: makeGolden(), reference: reference)
        XCTAssertTrue(diff.schemaMismatch)
        XCTAssertFalse(diff.matches)
    }

    func testBinaryMetadataDifferenceIsReported() {
        var actual = makeGolden()
        actual.binary.architecture = "x86_64"
        let diff = GoldenOutputDiff.compare(actual: actual, reference: makeGolden())
        XCTAssertTrue(diff.binaryFieldDifferences.contains("architecture"))
        XCTAssertFalse(diff.matches)
    }
}
