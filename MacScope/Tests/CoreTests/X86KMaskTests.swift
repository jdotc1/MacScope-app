import Foundation
import XCTest
@testable import MacScope

/// Ground truth is `handoff_package/groundtruth.txt` plus supplemental
/// `clang -arch x86_64 -mavx512f -mavx512bw -mavx512vl -mavx512dq` + `otool -tvj`
/// checks for the complete width matrix.
final class X86KMaskTests: XCTestCase {
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
        let actual = row.operands.isEmpty ? row.mnemonic : row.mnemonic + " " + row.operands
        XCTAssertEqual(actual, expected, "instruction text", file: file, line: line)
        XCTAssertEqual(row.bytes.count, length ?? bytes(hex).count, "length", file: file, line: line)
    }

    func testKLogicalArithmeticFamiliesAcrossWidths() {
        assertInstruction("c5ed41d9", "kandb %k1, %k2, %k3")
        assertInstruction("c5ec41d9", "kandw %k1, %k2, %k3")
        assertInstruction("c4e1ed41d9", "kandd %k1, %k2, %k3")
        assertInstruction("c4e1ec41d9", "kandq %k1, %k2, %k3")

        assertInstruction("c5ed42d9", "kandnb %k1, %k2, %k3")
        assertInstruction("c5ec42d9", "kandnw %k1, %k2, %k3")
        assertInstruction("c4e1ed42d9", "kandnd %k1, %k2, %k3")
        assertInstruction("c4e1ec42d9", "kandnq %k1, %k2, %k3")

        assertInstruction("c5ed45d9", "korb %k1, %k2, %k3")
        assertInstruction("c5ec45d9", "korw %k1, %k2, %k3")
        assertInstruction("c4e1ed45d9", "kord %k1, %k2, %k3")
        assertInstruction("c4e1ec45d9", "korq %k1, %k2, %k3")

        assertInstruction("c5ed46d9", "kxnorb %k1, %k2, %k3")
        assertInstruction("c5ec46d9", "kxnorw %k1, %k2, %k3")
        assertInstruction("c4e1ed46d9", "kxnord %k1, %k2, %k3")
        assertInstruction("c4e1ec46d9", "kxnorq %k1, %k2, %k3")

        assertInstruction("c5ed47d9", "kxorb %k1, %k2, %k3")
        assertInstruction("c5ec47d9", "kxorw %k1, %k2, %k3")
        assertInstruction("c4e1ed47d9", "kxord %k1, %k2, %k3")
        assertInstruction("c4e1ec47d9", "kxorq %k1, %k2, %k3")

        assertInstruction("c5ed4ad9", "kaddb %k1, %k2, %k3")
        assertInstruction("c5ec4ad9", "kaddw %k1, %k2, %k3")
        assertInstruction("c4e1ed4ad9", "kaddd %k1, %k2, %k3")
        assertInstruction("c4e1ec4ad9", "kaddq %k1, %k2, %k3")

        assertInstruction("c5f944d1", "knotb %k1, %k2")
        assertInstruction("c5f844d1", "knotw %k1, %k2")
        assertInstruction("c4e1f944d1", "knotd %k1, %k2")
        assertInstruction("c4e1f844d1", "knotq %k1, %k2")
    }

    func testKShiftImmediateWidths() {
        assertInstruction("c4e37932d103", "kshiftlb $0x3, %k1, %k2", length: 6)
        assertInstruction("c4e3f932d104", "kshiftlw $0x4, %k1, %k2", length: 6)
        assertInstruction("c4e37933d105", "kshiftld $0x5, %k1, %k2", length: 6)
        assertInstruction("c4e3f933d106", "kshiftlq $0x6, %k1, %k2", length: 6)

        assertInstruction("c4e37930d103", "kshiftrb $0x3, %k1, %k2", length: 6)
        assertInstruction("c4e3f930d104", "kshiftrw $0x4, %k1, %k2", length: 6)
        assertInstruction("c4e37931d105", "kshiftrd $0x5, %k1, %k2", length: 6)
        assertInstruction("c4e3f931d106", "kshiftrq $0x6, %k1, %k2", length: 6)
    }

    func testKOrTestAndKTestWidths() {
        assertInstruction("c5f998d1", "kortestb %k1, %k2")
        assertInstruction("c5f898d1", "kortestw %k1, %k2")
        assertInstruction("c4e1f998d1", "kortestd %k1, %k2")
        assertInstruction("c4e1f898d1", "kortestq %k1, %k2")

        assertInstruction("c5f999d1", "ktestb %k1, %k2")
        assertInstruction("c5f899d1", "ktestw %k1, %k2")
        assertInstruction("c4e1f999d1", "ktestd %k1, %k2")
        assertInstruction("c4e1f899d1", "ktestq %k1, %k2")
    }

    func testKUnpackWidths() {
        assertInstruction("c5ed4bd9", "kunpckbw %k1, %k2, %k3")
        assertInstruction("c5ec4bd9", "kunpckwd %k1, %k2, %k3")
        assertInstruction("c4e1ec4bd9", "kunpckdq %k1, %k2, %k3")
    }

    func testVEXNarrowingConverts() {
        assertInstruction("c5fde6d1", "vcvttpd2dq %ymm1, %xmm2")
        assertInstruction("c5ffe6d1", "vcvtpd2dq %ymm1, %xmm2")
        assertInstruction("c5f9e6d1", "vcvttpd2dq %xmm1, %xmm2")
        assertInstruction("c5fd5ad1", "vcvtpd2ps %ymm1, %xmm2")
    }

    // Narrowing converts (pd->ps/dq) leave an xmm dest for BOTH the 128- and 256-bit source
    // widths, so a MEMORY source is size-ambiguous in AT&T syntax -> otool/LLVM append an
    // x (xmmword/128) or y (ymmword/256) operand-size suffix. Register sources carry their own
    // width (no suffix), and the EVEX 512-bit form has a ymm dest (unambiguous, no suffix).
    // Expected strings are otool ground truth.
    func testNarrowingConvertMemorySuffix() {
        // VEX, memory source: x (128) / y (256)
        assertInstruction("c5f95a17", "vcvtpd2psx (%rdi), %xmm2")
        assertInstruction("c5fd5a17", "vcvtpd2psy (%rdi), %xmm2")
        assertInstruction("c5fbe617", "vcvtpd2dqx (%rdi), %xmm2")
        assertInstruction("c5ffe617", "vcvtpd2dqy (%rdi), %xmm2")
        assertInstruction("c5f9e617", "vcvttpd2dqx (%rdi), %xmm2")
        assertInstruction("c5fde617", "vcvttpd2dqy (%rdi), %xmm2")
        // EVEX (mask forces EVEX), memory source: x (128) / y (256)
        assertInstruction("62f1fd095a17", "vcvtpd2psx (%rdi), %xmm2 {%k1}")
        assertInstruction("62f1fd295a17", "vcvtpd2psy (%rdi), %xmm2 {%k1}")
        assertInstruction("62f1ff09e617", "vcvtpd2dqx (%rdi), %xmm2 {%k1}")
        assertInstruction("62f1ff29e617", "vcvtpd2dqy (%rdi), %xmm2 {%k1}")
        assertInstruction("62f1fd89e617", "vcvttpd2dqx (%rdi), %xmm2 {%k1} {z}")
        // Negative controls: NO suffix. Register source (width from reg name)...
        assertInstruction("c5f95ad1", "vcvtpd2ps %xmm1, %xmm2")
        assertInstruction("c5fde6d1", "vcvttpd2dq %ymm1, %xmm2")
        assertInstruction("62f1fd095ad1", "vcvtpd2ps %xmm1, %xmm2 {%k1}")
        // ...EVEX 512-bit source (ymm dest is unambiguous)...
        assertInstruction("62f1fd485a17", "vcvtpd2ps (%rdi), %ymm2")
        // ...EVEX broadcast (the {1toN} decoration disambiguates)...
        assertInstruction("62f1fd585a17", "vcvtpd2ps (%rdi){1to8}, %ymm2")
        // ...and widening converts (dest reg size already varies with L).
        assertInstruction("c5fc5a17", "vcvtps2pd (%rdi), %ymm2")
        assertInstruction("c5fee617", "vcvtdq2pd (%rdi), %ymm2")
    }

    func testKMovWRegressionAndStreamSync() {
        assertInstruction("c5f890d1", "kmovw %k1, %k2", length: 4)

        let stream = bytes("c5f890d1c5ec46d9c4e3f930d104c5f899d1c5ec4bd9c3")
        let rows = decoder.decode(Data(stream), baseAddress: 0x1000, maxInstructionCount: 8)
        XCTAssertEqual(rows.map(\.mnemonic), ["kmovw", "kxnorw", "kshiftrw", "ktestw", "kunpckwd", "ret"])
        XCTAssertEqual(rows.map { $0.bytes.count }, [4, 4, 6, 4, 4, 1])
        XCTAssertEqual(rows.last?.address, 0x1016)
    }
}
