import Foundation
import XCTest
@testable import MacScope

/// Ground-truth lock for the x86_64 SYSTEM / privileged instruction families added behind the
/// `Disassembler` seam (bswap, control/debug-register moves, the 0F 01 descriptor-table group,
/// MSR/TSC ops, endbr). Every expected mnemonic/operand/length below was established with
/// `clang -arch x86_64` + `otool -tvVj` (rendered in the decoder's AT&T house style — unsuffixed
/// mnemonics, since the register operand makes the size unambiguous).
///
/// Two tests specifically guard the linear-sweep DESYNC class: because x86 decode is a
/// length-driven sweep (`offset += decoded.bytes.count`), an instruction that reports the wrong
/// length silently corrupts every instruction after it. Those tests decode a two-instruction
/// sequence and assert the SECOND instruction is found at the correct offset.
final class X86SystemInstructionTests: XCTestCase {
    private let decoder = X86_64Decoder()

    private func one(_ bytes: [UInt8]) -> DecodedInstruction {
        decoder.decode(Data(bytes), baseAddress: 0x1000, maxInstructionCount: 1)[0]
    }

    private func assertDecode(_ bytes: [UInt8], _ mnemonic: String, _ operands: String,
                              length: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let r = one(bytes)
        XCTAssertEqual(r.mnemonic, mnemonic, "mnemonic", file: file, line: line)
        XCTAssertEqual(r.operands, operands, "operands", file: file, line: line)
        XCTAssertEqual(r.bytes.count, length ?? bytes.count, "length", file: file, line: line)
    }

    private func sweep(_ bytes: [UInt8]) -> [DecodedInstruction] {
        decoder.decode(Data(bytes), baseAddress: 0x1000, maxInstructionCount: 8)
    }

    // MARK: - bswap (0F C8+rd; REX.W = 64-bit; REX.B extends the register)

    func testBSWAP() {
        assertDecode([0x0F, 0xC8], "bswap", "%eax")              // 2 bytes
        assertDecode([0x48, 0x0F, 0xC8], "bswap", "%rax")       // REX.W -> 64-bit
        assertDecode([0x49, 0x0F, 0xC8], "bswap", "%r8")        // REX.W+REX.B
        assertDecode([0x49, 0x0F, 0xCF], "bswap", "%r15")
        assertDecode([0x41, 0x0F, 0xC8], "bswap", "%r8d")       // REX.B only
    }

    // MARK: - mov to/from control & debug registers (0F 20/21/22/23)

    func testControlAndDebugRegisterMov() {
        assertDecode([0x0F, 0x20, 0xC0], "mov", "%cr0, %rax")   // from CR0
        assertDecode([0x0F, 0x22, 0xC0], "mov", "%rax, %cr0")   // to CR0
        assertDecode([0x44, 0x0F, 0x20, 0xC0], "mov", "%cr8, %rax") // REX.R -> CR8 (4 bytes)
        assertDecode([0x0F, 0x21, 0xFB], "mov", "%dr7, %rbx")   // from DR7
        assertDecode([0x0F, 0x23, 0xF9], "mov", "%rcx, %dr7")   // to DR7
    }

    /// DESYNC GUARD: the cr/dr moves ignore the ModRM `mod` field — the r/m is ALWAYS a register
    /// and there is NO displacement. A non-canonical ModRM byte (mod=00, rm=101) must NOT be
    /// mis-read as RIP-relative (which would consume 4 phantom displacement bytes). The move is
    /// exactly 3 bytes, so the trailing `ret` must decode at offset 3.
    func testControlRegisterMovRegisterDirectDoesNotDesync() {
        let rows = sweep([0x0F, 0x22, 0x05, 0xC3]) // mov %rbp,%cr0 ; ret
        XCTAssertEqual(rows[0].mnemonic, "mov")
        XCTAssertEqual(rows[0].operands, "%rbp, %cr0")
        XCTAssertEqual(rows[0].bytes.count, 3, "cr move must be 3 bytes, not 7 (no phantom RIP disp)")
        XCTAssertEqual(rows[1].mnemonic, "ret", "the sweep must resync onto the ret at offset 3")
    }

    // MARK: - 0F 01 descriptor-table group + register-encoded specials

    func test0F01Group() {
        assertDecode([0x0F, 0x01, 0x10], "lgdt", "(%rax)")
        assertDecode([0x0F, 0x01, 0x18], "lidt", "(%rax)")
        assertDecode([0x0F, 0x01, 0x00], "sgdt", "(%rax)")
        assertDecode([0x0F, 0x01, 0x08], "sidt", "(%rax)")
        assertDecode([0x0F, 0x01, 0x38], "invlpg", "(%rax)")
        assertDecode([0x0F, 0x01, 0xF8], "swapgs", "")
        assertDecode([0x0F, 0x01, 0xF9], "rdtscp", "")
        assertDecode([0x0F, 0x01, 0xD0], "xgetbv", "")
        assertDecode([0x0F, 0x01, 0xD1], "xsetbv", "")
        // memory forms with displacement/SIB keep the correct length
        assertDecode([0x0F, 0x01, 0x50, 0x10], "lgdt", "0x10(%rax)")          // mod=01 disp8 (4 bytes)
    }

    /// DESYNC GUARD: REX.R must NOT extend the 0F 01 group-opcode selector. A legal REX.R-prefixed
    /// `lgdt` (e.g. 0x44 0F 01 10) must still decode as a 4-byte lgdt, not fall through to a
    /// single `.byte` (which would advance only 1 byte and desync the sweep).
    func test0F01GroupWithREXRDoesNotDesync() {
        let rows = sweep([0x44, 0x0F, 0x01, 0x10, 0xC3]) // REX.R lgdt (%rax) ; ret
        XCTAssertEqual(rows[0].mnemonic, "lgdt")
        XCTAssertEqual(rows[0].bytes.count, 4, "REX.R lgdt must be 4 bytes, not a 1-byte .byte")
        XCTAssertEqual(rows[1].mnemonic, "ret", "the sweep must resync onto the ret at offset 4")
    }

    // MARK: - smsw operand size (register-direct follows operand size; memory form is r/m16)

    func testSMSWOperandSize() {
        assertDecode([0x0F, 0x01, 0xE0], "smsw", "%eax")            // register-direct, default 32-bit
        assertDecode([0x48, 0x0F, 0x01, 0xE0], "smsw", "%rax")     // REX.W -> 64-bit
        assertDecode([0x66, 0x0F, 0x01, 0xE0], "smsw", "%ax")      // 0x66 -> 16-bit
        assertDecode([0x0F, 0x01, 0x20], "smsw", "(%rax)")          // memory form (r/m16)
    }

    // MARK: - MSR / performance counters / timestamp

    func testMSRAndCounters() {
        assertDecode([0x0F, 0x30], "wrmsr", "")
        assertDecode([0x0F, 0x32], "rdmsr", "")
        assertDecode([0x0F, 0x31], "rdtsc", "")
        assertDecode([0x0F, 0x33], "rdpmc", "")
    }

    // MARK: - CET endbr

    func testEndbr() {
        assertDecode([0xF3, 0x0F, 0x1E, 0xFA], "endbr64", "")
        assertDecode([0xF3, 0x0F, 0x1E, 0xFB], "endbr32", "")
    }
}
