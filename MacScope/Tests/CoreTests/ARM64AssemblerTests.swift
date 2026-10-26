import Foundation
import XCTest
@testable import MacScope

final class ARM64AssemblerTests: XCTestCase {
    private let assembler = ARM64Assembler()
    private let decoder = ARM64Decoder()

    // MARK: - Helpers

    /// Assembles `text` and returns the 4-byte little-endian word, failing the
    /// test with the diagnostic if it could not be encoded.
    private func assembleWord(_ text: String, at address: UInt64 = 0, file: StaticString = #filePath, line: UInt = #line) -> UInt32? {
        switch assembler.assemble(text, at: address) {
        case .success(let bytes):
            XCTAssertEqual(bytes.count, 4, "expected 4 bytes", file: file, line: line)
            return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        case .failure(let diagnostic):
            XCTFail("failed to assemble '\(text)': \(diagnostic)", file: file, line: line)
            return nil
        }
    }

    /// Decodes a 32-bit word at `address` and returns "<mnemonic> <operands>".
    private func decodeText(_ word: UInt32, at address: UInt64 = 0) -> String {
        let data = Data([
            UInt8(word & 0xff),
            UInt8((word >> 8) & 0xff),
            UInt8((word >> 16) & 0xff),
            UInt8((word >> 24) & 0xff),
        ])
        let rows = decoder.decode(data, baseAddress: address, maxInstructionCount: 1)
        guard let row = rows.first else { return "" }
        return row.operands.isEmpty ? row.mnemonic : "\(row.mnemonic) \(row.operands)"
    }

    /// The core oracle: assemble `text`, decode the bytes, and assert the decoder
    /// reproduces the canonical text. Spacing is normalized to a single space
    /// after the mnemonic (the decoder's exact rendering otherwise).
    private func assertRoundTrips(_ text: String, at address: UInt64 = 0, file: StaticString = #filePath, line: UInt = #line) {
        guard let word = assembleWord(text, at: address, file: file, line: line) else { return }
        let decoded = decodeText(word, at: address)
        XCTAssertEqual(decoded, text, "round-trip mismatch", file: file, line: line)
    }

    /// Asserts the exact 32-bit encoding (hand-encoded from the ARM ARM).
    private func assertEncodes(_ text: String, _ expected: UInt32, at address: UInt64 = 0, file: StaticString = #filePath, line: UInt = #line) {
        guard let word = assembleWord(text, at: address, file: file, line: line) else { return }
        XCTAssertEqual(word, expected, "encoding mismatch for '\(text)' got 0x\(String(word, radix: 16))", file: file, line: line)
    }

    private func assertFails(_ text: String, at address: UInt64 = 0, file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let bytes) = assembler.assemble(text, at: address) {
            XCTFail("expected '\(text)' to fail but got bytes \(bytes)", file: file, line: line)
        }
    }

    // MARK: - Known-good hand encodings (anchors the round-trip oracle)

    func testKnownGoodEncodings() {
        // sub sp, sp, #0x20  (from the existing decoder test corpus: 0xd10083ff)
        assertEncodes("sub sp, sp, #0x20", 0xd10083ff)
        // nop -> 0xd503201f
        assertEncodes("nop", 0xd503_201f)
        // ret -> 0xd65f03c0
        assertEncodes("ret", 0xd65f_03c0)
        // mov x0, #0  (movz x0, #0) -> 0xd2800000
        assertEncodes("mov x0, #0", 0xd280_0000)
        // movk x0, #1 -> 0xf2800020
        assertEncodes("movk x0, #1", 0xf280_0020)
    }

    // MARK: - Move wide

    func testMoveWideRoundTrips() {
        assertRoundTrips("mov x0, #0")
        assertRoundTrips("mov x1, #1")
        assertRoundTrips("mov w2, #0xffff")
        assertRoundTrips("mov x3, #-0x1")      // MOVN fold (decoder renders signed hex)
        assertRoundTrips("mov w4, #-0x2")      // MOVN fold (32-bit)
        assertRoundTrips("movk x5, #0x1234, lsl #16")
        assertRoundTrips("movk w6, #0xabcd")
        assertRoundTrips("mov x7, #0x10000")   // MOVZ shift 16
    }

    func testMoveWideOutOfRange() {
        assertFails("movz x0, #0x10000")       // exceeds 16-bit immediate
        assertFails("movz w0, #1, lsl #32")    // shift invalid for w-form
    }

    // MARK: - Add / sub immediate + shifted register

    func testAddSubImmediateRoundTrips() {
        assertRoundTrips("add x0, x1, #0x10")
        assertRoundTrips("sub sp, sp, #0x20")
        assertRoundTrips("adds w2, w3, #5")
        assertRoundTrips("subs x4, x5, #0xfff")
        assertRoundTrips("add x6, x7, #0x1000")     // shift-12 fold
        assertRoundTrips("cmp x0, #0")
        assertRoundTrips("cmn w1, #4")
    }

    func testAddSubShiftedRegisterRoundTrips() {
        assertRoundTrips("add x0, x1, x2")
        assertRoundTrips("sub w3, w4, w5")
        assertRoundTrips("adds x6, x7, x8, lsl #4")
        assertRoundTrips("subs x9, x10, x11, asr #2")
        assertRoundTrips("cmp x0, x1")
        assertRoundTrips("cmn w2, w3, lsl #1")
        assertRoundTrips("neg x0, x1")
        assertRoundTrips("negs x2, x3, lsl #3")
    }

    func testAddSubImmediateOutOfRange() {
        assertFails("add x0, x1, #0x12345")    // not 12-bit, not a clean shift-12 multiple
        assertFails("add x0, w1, #1")          // width mismatch
    }

    // MARK: - Logical immediate + shifted register

    func testLogicalImmediateRoundTrips() {
        assertRoundTrips("and x0, x1, #0xff")
        assertRoundTrips("orr w2, w3, #0xf")
        assertRoundTrips("eor x4, x5, #0xffff0000ffff0000")
        assertRoundTrips("ands x6, x7, #1")
        assertRoundTrips("tst x0, #0xff")
    }

    func testLogicalShiftedRegisterRoundTrips() {
        assertRoundTrips("and x0, x1, x2")
        assertRoundTrips("orr w3, w4, w5, lsl #2")
        assertRoundTrips("eor x6, x7, x8")
        assertRoundTrips("ands x9, x10, x11, lsr #1")
        assertRoundTrips("bic x0, x1, x2")
        assertRoundTrips("orn w3, w4, w5")
        assertRoundTrips("eon x6, x7, x8, asr #4")
        assertRoundTrips("bics x9, x10, x11")
        assertRoundTrips("mvn x0, x1")
        assertRoundTrips("tst x2, x3")
        assertRoundTrips("mov x4, x5")          // orr alias (register move)
    }

    func testLogicalImmediateRejectsNonBitmask() {
        // 0xff_00_00_ff is not a single rotated run within any element size.
        assertFails("and x0, x1, #0xff0000ff")
        // all-ones is not a valid logical immediate
        assertFails("and x0, x1, #0xffffffffffffffff")
    }

    func testInverseBitMasksAgainstDecoder() {
        // Exhaustively verify the inverse-DecodeBitMasks against the decoder for
        // every encodable 64-bit bitmask, then for 32-bit.
        for width in [32, 64] {
            for n in (width == 64 ? [0, 1] : [0]) {
                for immr in 0...63 {
                    for imms in 0...63 {
                        // Decode the value the forward algorithm yields.
                        guard let value = forwardReference(n: UInt32(n), imms: imms, immr: immr, width: width) else { continue }
                        guard let (rn, rImmr, rImms) = assembler.encodeBitMasks(value, width: width) else {
                            XCTFail("encodeBitMasks returned nil for an encodable value 0x\(String(value, radix: 16)) (w\(width))")
                            continue
                        }
                        // The re-encoded triple must reproduce the same value.
                        let reValue = forwardReference(n: rn, imms: rImms, immr: rImmr, width: width)
                        XCTAssertEqual(reValue, value, "bitmask re-encode mismatch w\(width) value 0x\(String(value, radix: 16))")
                    }
                }
            }
        }
    }

    /// A local copy of the decoder's DecodeBitMasks for the exhaustive test.
    private func forwardReference(n: UInt32, imms: Int, immr: Int, width: Int) -> UInt64? {
        let control = (Int(n) << 6) | ((~imms) & 0x3f)
        var length = -1
        for bit in stride(from: 6, through: 0, by: -1) where (control & (1 << bit)) != 0 { length = bit; break }
        guard length >= 1 else { return nil }
        let esize = 1 << length
        let levels = esize - 1
        let s = imms & levels
        let r = immr & levels
        guard s != levels else { return nil }
        let elementMask: UInt64 = esize >= 64 ? ~0 : ((UInt64(1) << UInt64(esize)) - 1)
        let welem: UInt64 = (UInt64(1) << UInt64(s + 1)) - 1
        let rotation = r % esize
        let rotated: UInt64 = rotation == 0 ? (welem & elementMask)
            : (((welem >> UInt64(rotation)) | (welem << UInt64(esize - rotation))) & elementMask)
        var result: UInt64 = 0
        var shift = 0
        while shift < width { result |= rotated << UInt64(shift); shift += esize }
        if width < 64 { result &= (UInt64(1) << UInt64(width)) - 1 }
        return result
    }

    // MARK: - Branches

    func testBranchFamilyRoundTrips() {
        let pc: UInt64 = 0x1_0000_1000
        assertRoundTrips("b 0x0000000100001020", at: pc)
        assertRoundTrips("bl 0x0000000100000000", at: pc)
        assertRoundTrips("b.eq 0x0000000100001040", at: pc)
        assertRoundTrips("b.ne 0x0000000100000ff0", at: pc)
        assertRoundTrips("cbz x0, 0x0000000100001020", at: pc)
        assertRoundTrips("cbnz w1, 0x0000000100001008", at: pc)
        assertRoundTrips("tbz w2, #3, 0x0000000100001020", at: pc)
        assertRoundTrips("tbnz x3, #40, 0x0000000100001020", at: pc)
        assertRoundTrips("ret")
        assertRoundTrips("ret x5")
        assertRoundTrips("br x0")
        assertRoundTrips("blr x16")
    }

    func testBranchAcceptsHashOffset() {
        // `b #8` at PC 0x1000 should target 0x1008.
        guard let word = assembleWord("b #8", at: 0x1000) else { return }
        XCTAssertEqual(decodeText(word, at: 0x1000), "b 0x0000000000001008")
    }

    func testBranchOffsetOutOfRange() {
        // bl reaches ±128 MiB; this is well beyond.
        assertFails("bl 0x7000000000000000", at: 0x1000)
        // Unaligned branch target.
        assertFails("b 0x1003", at: 0x1000)
        // tbz reaches only ±32 KiB.
        assertFails("tbz w0, #1, 0x0000000000010000", at: 0x1000)
    }

    func testConditionalBranchUnknownCondition() {
        assertFails("b.zz 0x1000", at: 0x1000)
    }

    // MARK: - Load / store

    func testLoadStoreRoundTrips() {
        assertRoundTrips("ldr x0, [x1]")
        assertRoundTrips("ldr x0, [x1, #0x10]")
        assertRoundTrips("str w2, [x3, #4]")
        assertRoundTrips("ldrb w4, [x5, #1]")
        assertRoundTrips("strh w6, [x7, #2]")
        assertRoundTrips("ldrsw x8, [x9, #8]")
        assertRoundTrips("ldur x10, [x11, #-0x8]")
        assertRoundTrips("stur w12, [x13, #-0x4]")
        assertRoundTrips("ldr x14, [x15, #8]!")    // pre-indexed
        assertRoundTrips("ldr x16, [x17], #0x10")  // post-indexed
        assertRoundTrips("str x18, [sp, #0x20]")
        assertRoundTrips("ldr x0, [x1, x2]")       // register offset (lsl)
        assertRoundTrips("ldr x0, [x1, x2, lsl #3]")
        assertRoundTrips("ldr w0, [x1, w2, uxtw]")
        assertRoundTrips("ldr w0, [x1, w2, sxtw #2]")
    }

    func testLoadStoreOutOfRange() {
        // Scaled offset must be a multiple of the access size.
        assertFails("ldr x0, [x1, #7]")
        // Unscaled (ldur) range is -256..255.
        assertFails("ldur x0, [x1, #256]")
        // Pre-indexed imm9 range.
        assertFails("ldr x0, [x1, #512]!")
    }

    // MARK: - Hints / system

    func testHintsRoundTrip() {
        assertRoundTrips("nop")
        assertRoundTrips("yield")
        assertRoundTrips("wfe")
        assertRoundTrips("wfi")
        assertRoundTrips("sev")
        assertRoundTrips("paciasp")
        assertRoundTrips("autiasp")
    }

    // MARK: - Diagnostics

    func testMalformedInputDiagnostics() {
        assertFails("")
        assertFails("   ")
        assertFails("frobnicate x0, x1")           // unknown mnemonic
        assertFails("add x0, x1")                   // too few operands
        assertFails("add q0, q1, q2")               // bad register
        assertFails("mov x0, x1, x2")               // mov register move with extra op -> not 2 operands? actually 3
        assertFails("movk x0, #0x10000")            // immediate out of range
    }

    func testDiagnosticDescriptionsAreNonEmpty() {
        if case .failure(let d) = assembler.assemble("frobnicate") {
            XCTAssertFalse(d.description.isEmpty)
            XCTAssertTrue(d.description.contains("frobnicate"))
        } else {
            XCTFail("expected failure")
        }
    }

    // MARK: - Broad round-trip sweep over the decoder's own output

    /// Decode a spread of real instruction words, then re-assemble the canonical
    /// text and assert the bytes match. This makes the decoder the ground truth
    /// across families simultaneously.
    func testReassemblesDecoderOutput() {
        let pc: UInt64 = 0x1_0000_2000
        let words: [UInt32] = [
            0xd10083ff, // sub sp, sp, #0x20
            0x910003fd, // add x29, sp, #0
            0xa9007bfd, // stp (not in scope) -- will be skipped if decoder emits unsupported
            0xf9400000, // ldr x0, [x0]
            0xaa0103e0, // mov x0, x1
            0x8b020020, // add x0, x1, x2
            0xcb020020, // sub x0, x1, x2
            0x6b02003f, // cmp w1, w2
            0x8a020020, // and x0, x1, x2
            0xd2800020, // mov x0, #1
            0xeb01001f, // cmp x0, x1
            0xd65f03c0, // ret
            0xd503201f, // nop
        ]
        for word in words {
            let text = decodeText(word, at: pc)
            // Skip anything outside the assembler's declared scope (e.g. stp).
            guard isInScope(text) else { continue }
            switch assembler.assemble(text, at: pc) {
            case .success(let bytes):
                let reword = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
                XCTAssertEqual(reword, word, "re-assembly mismatch for '\(text)' (orig 0x\(String(word, radix: 16)))")
            case .failure(let d):
                XCTFail("could not re-assemble in-scope '\(text)': \(d)")
            }
        }
    }

    private func isInScope(_ text: String) -> Bool {
        let mnemonic = ARM64Assembler.split(text).mnemonic
        let supported: Set<String> = [
            "mov", "movz", "movn", "movk", "add", "sub", "adds", "subs",
            "cmp", "cmn", "neg", "negs", "and", "orr", "eor", "ands",
            "bic", "orn", "eon", "bics", "mvn", "tst",
            "b", "bl", "cbz", "cbnz", "tbz", "tbnz", "ret", "br", "blr",
            "ldr", "str", "ldrb", "strb", "ldrh", "strh", "ldrsb", "ldrsh", "ldrsw",
            "ldur", "stur", "nop", "yield", "wfe", "wfi", "sev",
        ]
        return supported.contains(mnemonic) || mnemonic.hasPrefix("b.")
    }
}
