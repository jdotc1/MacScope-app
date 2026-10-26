import Foundation
import XCTest
@testable import MacScope

final class X86EVEXMiscTests: XCTestCase {
    private let decoder = X86_64Decoder()

    private func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    private func one(_ hex: String, at address: UInt64 = 0x1000) -> DecodedInstruction {
        decoder.decode(Data(bytes(hex)), baseAddress: address, maxInstructionCount: 1)[0]
    }

    private func assertInstruction(_ hex: String, _ expected: String, length: Int? = nil,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let row = one(hex)
        let text = row.operands.isEmpty ? row.mnemonic : row.mnemonic + " " + row.operands
        XCTAssertEqual(text, expected, file: file, line: line)
        XCTAssertEqual(row.bytes.count, length ?? bytes(hex).count, file: file, line: line)
    }

    func testIFMAForms() {
        assertInstruction("62f2f548b4c2", "vpmadd52luq %zmm2, %zmm1, %zmm0")
        assertInstruction("62f2f549b5c2", "vpmadd52huq %zmm2, %zmm1, %zmm0 {%k1}")
        assertInstruction("62f2f558b44008", "vpmadd52luq 0x40(%rax){1to8}, %zmm1, %zmm0")
        assertInstruction("62028dc7b4ef", "vpmadd52luq %zmm31, %zmm30, %zmm29 {%k7} {z}")
    }

    func testVBMIForms() {
        assertInstruction("62f275488dc2", "vpermb %zmm2, %zmm1, %zmm0")
        assertInstruction("62f2754a8d4001", "vpermb 0x40(%rax), %zmm1, %zmm0 {%k2}")
        assertInstruction("62f2f54883c2", "vpmultishiftqb %zmm2, %zmm1, %zmm0")
        assertInstruction("62428d57836f08", "vpmultishiftqb 0x40(%r15){1to8}, %zmm30, %zmm29 {%k7}")
    }

    func testVBMI2VariableShiftDoubleForms() {
        assertInstruction("62f2f54870c2", "vpshldvw %zmm2, %zmm1, %zmm0")
        assertInstruction("62f2754871c2", "vpshldvd %zmm2, %zmm1, %zmm0")
        assertInstruction("62f2f54871c2", "vpshldvq %zmm2, %zmm1, %zmm0")
        assertInstruction("62f2f54972c2", "vpshrdvw %zmm2, %zmm1, %zmm0 {%k1}")
        assertInstruction("62f2754873c2", "vpshrdvd %zmm2, %zmm1, %zmm0")
        assertInstruction("62f2f54873c2", "vpshrdvq %zmm2, %zmm1, %zmm0")
        assertInstruction("62420d57716f10", "vpshldvd 0x40(%r15){1to16}, %zmm30, %zmm29 {%k7}")
    }

    func testVBMI2ImmediateShiftDoubleForms() {
        assertInstruction("62f3f54870c201", "vpshldw $0x1, %zmm2, %zmm1, %zmm0")
        assertInstruction("62f3754871c205", "vpshldd $0x5, %zmm2, %zmm1, %zmm0")
        assertInstruction("62f3f54871c203", "vpshldq $0x3, %zmm2, %zmm1, %zmm0")
        assertInstruction("62f3f54872c201", "vpshrdw $0x1, %zmm2, %zmm1, %zmm0")
        assertInstruction("62f3754873c202", "vpshrdd $0x2, %zmm2, %zmm1, %zmm0")
        assertInstruction("62f3f54873c204", "vpshrdq $0x4, %zmm2, %zmm1, %zmm0")
        assertInstruction("62438d57736f080a", "vpshrdq $0xa, 0x40(%r15){1to8}, %zmm30, %zmm29 {%k7}")
    }

    func testVPOPCNTForms() {
        assertInstruction("62f27d4854c1", "vpopcntb %zmm1, %zmm0")
        assertInstruction("62f2fd4854c1", "vpopcntw %zmm1, %zmm0")
        assertInstruction("62f27d4955c1", "vpopcntd %zmm1, %zmm0 {%k1}")
        assertInstruction("62f2fd58554008", "vpopcntq 0x40(%rax){1to8}, %zmm0")
        assertInstruction("62027dcf54ef", "vpopcntb %zmm31, %zmm29 {%k7} {z}")
    }

    func testGFNIForms() {
        assertInstruction("62f27548cfc2", "vgf2p8mulb %zmm2, %zmm1, %zmm0")
        assertInstruction("62f3f548cec201", "vgf2p8affineqb $0x1, %zmm2, %zmm1, %zmm0")
        assertInstruction("62f3f548cfc202", "vgf2p8affineinvqb $0x2, %zmm2, %zmm1, %zmm0")
        assertInstruction("62f3f558ce400800", "vgf2p8affineqb $0x0, 0x40(%rax){1to8}, %zmm1, %zmm0")
        assertInstruction("62438d57cf6f0806", "vgf2p8affineinvqb $0x6, 0x40(%r15){1to8}, %zmm30, %zmm29 {%k7}")
    }

    // GFNI has three encodings; package 09 shipped only EVEX. otool decodes the VEX
    // (C4…) and legacy-SSE (66 0F38/0F3A) forms too. VEX gates on W: mulb is W0-only,
    // affine{,inv}qb are W1-only (the opposite W is #UD). Legacy forms drop the vvvv
    // source (2-op mul, 3-op affine). Expected strings are otool ground truth.
    func testGFNIVEXEncodings() {
        assertInstruction("c4e3f5cec203", "vgf2p8affineqb $0x3, %ymm2, %ymm1, %ymm0")
        assertInstruction("c4e3f1cfc203", "vgf2p8affineinvqb $0x3, %xmm2, %xmm1, %xmm0")
        assertInstruction("c4e275cf4040", "vgf2p8mulb 0x40(%rax), %ymm1, %ymm0")
    }

    func testGFNILegacySSEEncodings() {
        assertInstruction("660f3acec203", "gf2p8affineqb $0x3, %xmm2, %xmm0")
        assertInstruction("660f3acfc203", "gf2p8affineinvqb $0x3, %xmm2, %xmm0")
        assertInstruction("660f38cfc2", "gf2p8mulb %xmm2, %xmm0")
    }

    func testVP2IntersectDestIsMaskRegister() {
        assertInstruction("62f2774868e2", "vp2intersectd %zmm2, %zmm1, %k4")
        assertInstruction("62f2f74868d2", "vp2intersectq %zmm2, %zmm1, %k2")
        assertInstruction("62f27758686010", "vp2intersectd 0x40(%rax){1to16}, %zmm1, %k4")
        assertInstruction("62d28f50686708", "vp2intersectq 0x40(%r15){1to8}, %zmm30, %k4")
    }

    func testEVEXMiscStreamStaysSynchronized() {
        let stream = bytes(
            "62f2f548b4c2" +
            "62f275488dc2" +
            "62f2f54870c2" +
            "62f3f54872c201" +
            "62f27d4854c1" +
            "62f3f548cec201" +
            "62f2774868e2" +
            "c3"
        )
        let rows = decoder.decode(Data(stream), baseAddress: 0x1000, maxInstructionCount: 16)
        XCTAssertEqual(rows.map(\.mnemonic), [
            "vpmadd52luq", "vpermb", "vpshldvw", "vpshrdw",
            "vpopcntb", "vgf2p8affineqb", "vp2intersectd", "ret",
        ])
        XCTAssertEqual(rows.map { $0.bytes.count }, [6, 6, 6, 7, 6, 7, 6, 1])
        XCTAssertEqual(rows.last?.address, 0x102C)
    }
}
