import Foundation
import XCTest
@testable import MacScope

/// Ground truth for these x86_64 real-world tail opcodes comes from the handoff
/// corpus (`otool -arch x86_64 -tvj`) and the decoder's AT&T house style.
final class X86RealWorldTailTests: XCTestCase {
    private let decoder = X86_64Decoder()

    private func one(_ bytes: [UInt8], at address: UInt64 = 0x1000) -> DecodedInstruction {
        decoder.decode(Data(bytes), baseAddress: address, maxInstructionCount: 1)[0]
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

    // MARK: - SSE 0F tail

    func testSSEMaskMovesUseGPRDestination() {
        assertDecode([0x0F, 0x50, 0xC1], "movmskps", "%xmm1, %eax", length: 3)
        assertDecode([0x45, 0x0F, 0x50, 0xC7], "movmskps", "%xmm15, %r8d", length: 4)
        assertDecode([0x66, 0x0F, 0x50, 0xC8], "movmskpd", "%xmm0, %ecx", length: 4)
        assertDecode([0x66, 0x0F, 0xD7, 0xC8], "pmovmskb", "%xmm0, %ecx", length: 4)
        assertDecode([0x66, 0x0F, 0xD7, 0xD7], "pmovmskb", "%xmm7, %edx", length: 4)
    }

    func testSSELowHighStoreFormsAndExistingLoads() {
        assertDecode([0x0F, 0x12, 0x00], "movlps", "(%rax), %xmm0", length: 3)
        assertDecode([0x0F, 0x16, 0x00], "movhps", "(%rax), %xmm0", length: 3)

        assertDecode([0x0F, 0x13, 0x80, 0x44, 0x03, 0x00, 0x00],
                     "movlps", "%xmm0, 0x344(%rax)", length: 7)
        assertDecode([0x66, 0x0F, 0x13, 0x52, 0x04],
                     "movlpd", "%xmm2, 0x4(%rdx)", length: 5)
        assertDecode([0x0F, 0x17, 0x00], "movhps", "%xmm0, (%rax)", length: 3)
        assertDecode([0x66, 0x0F, 0x17, 0x4B, 0x08],
                     "movhpd", "%xmm1, 0x8(%rbx)", length: 5)
    }

    func testSSEConvertsHorizontalAndAddSub() {
        assertDecode([0x66, 0x0F, 0xE6, 0xC2], "cvttpd2dq", "%xmm2, %xmm0", length: 4)
        assertDecode([0xF3, 0x0F, 0xE6, 0xD1], "cvtdq2pd", "%xmm1, %xmm2", length: 4)
        assertDecode([0xF2, 0x0F, 0xE6, 0xD1], "cvtpd2dq", "%xmm1, %xmm2", length: 4)
        assertDecode([0x66, 0x0F, 0x7C, 0xC0], "haddpd", "%xmm0, %xmm0", length: 4)
        assertDecode([0xF2, 0x0F, 0x7C, 0xD1], "haddps", "%xmm1, %xmm2", length: 4)
        assertDecode([0x66, 0x0F, 0x7D, 0xC8], "hsubpd", "%xmm0, %xmm1", length: 4)
        assertDecode([0xF2, 0x0F, 0x7D, 0xDA], "hsubps", "%xmm2, %xmm3", length: 4)
        assertDecode([0x66, 0x0F, 0xD0, 0xC8], "addsubpd", "%xmm0, %xmm1", length: 4)
        assertDecode([0xF2, 0x0F, 0xD0, 0xDA], "addsubps", "%xmm2, %xmm3", length: 4)
    }

    // MARK: - Legacy and port I/O

    func testPortAndStringIOForms() {
        assertDecode([0xEE], "outb", "%al, %dx", length: 1)
        assertDecode([0xEF], "outl", "%eax, %dx", length: 1)
        assertDecode([0xEC], "inb", "%dx, %al", length: 1)
        assertDecode([0xED], "inl", "%dx, %eax", length: 1)
        assertDecode([0xE6, 0x10], "outb", "%al, $0x10", length: 2)
        assertDecode([0xE7, 0x20], "outl", "%eax, $0x20", length: 2)
        assertDecode([0xE4, 0x10], "inb", "$0x10, %al", length: 2)
        assertDecode([0xE5, 0x20], "inl", "$0x20, %eax", length: 2)
        assertDecode([0x6C], "insb", "%dx, %es:(%rdi)", length: 1)
        assertDecode([0x6D], "insl", "%dx, %es:(%rdi)", length: 1)
        assertDecode([0x6E], "outsb", "(%rsi), %dx", length: 1)
        assertDecode([0x6F], "outsl", "(%rsi), %dx", length: 1)
    }

    func testSingleByteSystemAndFlagStragglers() {
        assertDecode([0xFA], "cli", "", length: 1)
        assertDecode([0xFB], "sti", "", length: 1)
        assertDecode([0xD7], "xlatb", "", length: 1)
        assertDecode([0xCF], "iretl", "", length: 1)
        assertDecode([0x48, 0xCF], "iretq", "", length: 2)
        assertDecode([0xF4], "hlt", "", length: 1)
        assertDecode([0x9E], "sahf", "", length: 1)
        assertDecode([0x9F], "lahf", "", length: 1)
    }

    // MARK: - Basic stragglers

    func testXchgAccumulatorForms() {
        assertDecode([0x91], "xchg", "%ecx, %eax", length: 1)
        assertDecode([0x92], "xchg", "%edx, %eax", length: 1)
        assertDecode([0x49, 0x91], "xchg", "%r9, %rax", length: 2)
    }

    func testXchgModRMForms() {
        assertDecode([0x87, 0x08], "xchg", "%ecx, (%rax)", length: 2)
        assertDecode([0x87, 0xff], "xchg", "%edi, %edi", length: 2)
        assertDecode([0x87, 0x8e, 0x00, 0x00, 0x00, 0x48], "xchg", "%ecx, 0x48000000(%rsi)", length: 6)
        assertDecode([0x86, 0x00], "xchg", "%al, (%rax)", length: 2)
    }

    func testMovabsMoffsConsumesNineBytes() {
        let moffs: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]
        let address = "-0x778899aabbccddef"
        assertDecode([0xA0] + moffs, "movabs", address + ", %al", length: 9)
        assertDecode([0xA1] + moffs, "movabs", address + ", %eax", length: 9)
        assertDecode([0xA2] + moffs, "movabs", "%al, " + address, length: 9)
        assertDecode([0xA3] + moffs, "movabs", "%eax, " + address, length: 9)
    }

    func testMovabsMoffsDoesNotDesyncTrailingInstruction() {
        let stream: [UInt8] = [0xA0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0xC3]
        let rows = sweep(stream)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].mnemonic, "movabs")
        XCTAssertEqual(rows[0].bytes.count, 9)
        XCTAssertEqual(rows[1].mnemonic, "ret")
        XCTAssertEqual(rows[1].address, 0x1000 + 9)
    }
}
