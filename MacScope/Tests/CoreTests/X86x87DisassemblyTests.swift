import Foundation
import XCTest
@testable import MacScope

/// Tests for the x87 floating-point escape opcodes (0xD8–0xDF). Ground-truth byte
/// sequences and renderings come from `clang -arch x86_64` + `otool -tvVj`. These
/// exercise both memory-load forms and the 0xDE register forms, and verify that the
/// instruction length is correct so the linear sweep stays synchronized.
final class X86x87DisassemblyTests: XCTestCase {
    private let decoder = X86_64Decoder()

    private func one(_ bytes: [UInt8], at address: UInt64 = 0x1000) -> DecodedInstruction {
        let rows = decoder.decode(Data(bytes), baseAddress: address, maxInstructionCount: 1)
        return rows[0]
    }

    private func assertDecode(_ bytes: [UInt8], _ mnemonic: String, _ operands: String,
                              length: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let r = one(bytes)
        XCTAssertEqual(r.mnemonic, mnemonic, "mnemonic", file: file, line: line)
        XCTAssertEqual(r.operands, operands, "operands", file: file, line: line)
        XCTAssertEqual(r.bytes.count, length ?? bytes.count, "length", file: file, line: line)
    }

    private func sweep(_ bytes: [UInt8]) -> [DecodedInstruction] {
        return decoder.decode(Data(bytes), baseAddress: 0x1000, maxInstructionCount: 8)
    }

    // Memory load forms (mod != 3). otool shows `_start(%rdi)` due to symbol
    // resolution; the raw decoder has no symbols so it renders `(%rdi)`.
    func testFldsMemory() {
        assertDecode([0xD9, 0x07], "flds", "(%rdi)")    // d9 07  FLD m32fp
    }
    func testFldlMemory() {
        assertDecode([0xDD, 0x07], "fldl", "(%rdi)")    // dd 07  FLD m64fp
    }
    func testFildlMemory() {
        assertDecode([0xDB, 0x07], "fildl", "(%rdi)")   // db 07  FILD m32int
    }
    func testFildllMemory() {
        assertDecode([0xDF, 0x2F], "fildll", "(%rdi)")  // df 2f  FILD m64int (reg=5)
    }

    // 0xDE register forms (mod == 3).
    func testFaddp()  { assertDecode([0xDE, 0xC1], "faddp",  "%st, %st(1)") }  // de c1
    func testFmulp()  { assertDecode([0xDE, 0xC9], "fmulp",  "%st, %st(1)") }  // de c9
    func testFsubp()  { assertDecode([0xDE, 0xE1], "fsubp",  "%st, %st(1)") }  // de e1 (reg=4)
    func testFsubrp() { assertDecode([0xDE, 0xE9], "fsubrp", "%st, %st(1)") }  // de e9 (reg=5)
    func testFdivrp() { assertDecode([0xDE, 0xF1], "fdivrp", "%st, %st(1)") }  // de f1 (reg=6)
    func testFdivp()  { assertDecode([0xDE, 0xF9], "fdivp",  "%st, %st(1)") }  // de f9 (reg=7)

    // Desync guard: faddp (2 bytes) followed by ret (1 byte) must decode as exactly
    // two instructions with ret at the correct address.
    func testX87DesyncGuard() {
        let stream: [UInt8] = [0xDE, 0xC1, 0xC3]
        let rows = sweep(stream)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "faddp")
        XCTAssertEqual(rows[0].bytes.count, 2)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 2)
    }

    // A memory form with a 1-byte displacement (mod=01) must consume escape + ModRM
    // + disp8 = 3 bytes and not desync a trailing ret.
    func testX87MemoryDispLengthCorrect() {
        // d9 47 04  ->  flds 0x4(%rdi)   ; then ret
        let stream: [UInt8] = [0xD9, 0x47, 0x04, 0xC3]
        let rows = sweep(stream)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "flds")
        XCTAssertEqual(rows[0].bytes.count, 3)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 3)
    }
}
