import Foundation
import XCTest
@testable import MacScope

final class X86EVEXUIntConvertTests: XCTestCase {
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

    private func assertInstructions(_ cases: [(String, String)],
                                    file: StaticString = #filePath, line: UInt = #line) {
        for (hex, expected) in cases {
            assertInstruction(hex, expected, file: file, line: line)
        }
    }

    func testVCVTQQ2PSNarrowingForms() {
        assertInstructions([
            ("62f1fc485bd1", "vcvtqq2ps %zmm1, %ymm2"),
            ("62f1fc285bd1", "vcvtqq2ps %ymm1, %xmm2"),
            ("62f1fc085bd1", "vcvtqq2ps %xmm1, %xmm2"),
            ("62f1fc095b17", "vcvtqq2psx (%rdi), %xmm2 {%k1}"),
            ("62f1fca95b17", "vcvtqq2psy (%rdi), %xmm2 {%k1} {z}"),
            ("62f1fc585b17", "vcvtqq2ps (%rdi){1to8}, %ymm2"),
            ("62f1fc185bd1", "vcvtqq2ps {rn-sae}, %zmm1, %ymm2"),
            ("6201fc4f5bee", "vcvtqq2ps %zmm30, %ymm29 {%k7}"),
        ])
    }

    func testOpcode79RoundingUnsignedRegisterVLForms() {
        assertInstructions([
            ("62f17c0879d1", "vcvtps2udq %xmm1, %xmm2"),
            ("62f17c2879d1", "vcvtps2udq %ymm1, %ymm2"),
            ("62f17c4879d1", "vcvtps2udq %zmm1, %zmm2"),
            ("62f1fc0879d1", "vcvtpd2udq %xmm1, %xmm2"),
            ("62f1fc2879d1", "vcvtpd2udq %ymm1, %xmm2"),
            ("62f1fc4879d1", "vcvtpd2udq %zmm1, %ymm2"),
            ("62f17d0879d1", "vcvtps2uqq %xmm1, %xmm2"),
            ("62f17d2879d1", "vcvtps2uqq %xmm1, %ymm2"),
            ("62f17d4879d1", "vcvtps2uqq %ymm1, %zmm2"),
            ("62f1fd0879d1", "vcvtpd2uqq %xmm1, %xmm2"),
            ("62f1fd2879d1", "vcvtpd2uqq %ymm1, %ymm2"),
            ("62f1fd4879d1", "vcvtpd2uqq %zmm1, %zmm2"),
        ])
    }

    func testOpcode79RoundingUnsignedMemoryMaskBroadcastAndER() {
        assertInstructions([
            ("62f17c587917", "vcvtps2udq (%rdi){1to16}, %zmm2"),
            ("62f17c5879d1", "vcvtps2udq {ru-sae}, %zmm1, %zmm2"),
            ("62f17c2979d1", "vcvtps2udq %ymm1, %ymm2 {%k1}"),
            ("62017ccf79ee", "vcvtps2udq %zmm30, %zmm29 {%k7} {z}"),
            ("62f1fc097917", "vcvtpd2udqx (%rdi), %xmm2 {%k1}"),
            ("62f1fc287917", "vcvtpd2udqy (%rdi), %xmm2"),
            ("62f1fc587917", "vcvtpd2udq (%rdi){1to8}, %ymm2"),
            ("62f1fc7879d1", "vcvtpd2udq {rz-sae}, %zmm1, %ymm2"),
            ("62f17d587917", "vcvtps2uqq (%rdi){1to8}, %zmm2"),
            ("62f17d58795710", "vcvtps2uqq 0x40(%rdi){1to8}, %zmm2"),
            ("62f17d1879d1", "vcvtps2uqq {rn-sae}, %ymm1, %zmm2"),
            ("62017dcf79ee", "vcvtps2uqq %ymm30, %zmm29 {%k7} {z}"),
            ("62f1fd587917", "vcvtpd2uqq (%rdi){1to8}, %zmm2"),
            ("62f1fd5879d1", "vcvtpd2uqq {ru-sae}, %zmm1, %zmm2"),
        ])
    }

    func testOpcode78TruncatingUnsignedRegisterVLForms() {
        assertInstructions([
            ("62f17c0878d1", "vcvttps2udq %xmm1, %xmm2"),
            ("62f17c2878d1", "vcvttps2udq %ymm1, %ymm2"),
            ("62f17c4878d1", "vcvttps2udq %zmm1, %zmm2"),
            ("62f1fc0878d1", "vcvttpd2udq %xmm1, %xmm2"),
            ("62f1fc2878d1", "vcvttpd2udq %ymm1, %xmm2"),
            ("62f1fc4878d1", "vcvttpd2udq %zmm1, %ymm2"),
            ("62f17d0878d1", "vcvttps2uqq %xmm1, %xmm2"),
            ("62f17d2878d1", "vcvttps2uqq %xmm1, %ymm2"),
            ("62f17d4878d1", "vcvttps2uqq %ymm1, %zmm2"),
            ("62f1fd0878d1", "vcvttpd2uqq %xmm1, %xmm2"),
            ("62f1fd2878d1", "vcvttpd2uqq %ymm1, %ymm2"),
            ("62f1fd4878d1", "vcvttpd2uqq %zmm1, %zmm2"),
        ])
    }

    func testOpcode78TruncatingUnsignedMemoryMaskBroadcastAndSAE() {
        assertInstructions([
            ("62f17c587817", "vcvttps2udq (%rdi){1to16}, %zmm2"),
            ("62f17c1878d1", "vcvttps2udq {sae}, %zmm1, %zmm2"),
            ("62017ccf78ee", "vcvttps2udq %zmm30, %zmm29 {%k7} {z}"),
            ("62f1fc097817", "vcvttpd2udqx (%rdi), %xmm2 {%k1}"),
            ("62f1fc287817", "vcvttpd2udqy (%rdi), %xmm2"),
            ("62f1fc587817", "vcvttpd2udq (%rdi){1to8}, %ymm2"),
            ("62f1fc1878d1", "vcvttpd2udq {sae}, %zmm1, %ymm2"),
            ("62f17d587817", "vcvttps2uqq (%rdi){1to8}, %zmm2"),
            ("62f17d58785710", "vcvttps2uqq 0x40(%rdi){1to8}, %zmm2"),
            ("62f17d1878d1", "vcvttps2uqq {sae}, %ymm1, %zmm2"),
            ("62017dcf78ee", "vcvttps2uqq %ymm30, %zmm29 {%k7} {z}"),
            ("62f1fd587817", "vcvttpd2uqq (%rdi){1to8}, %zmm2"),
            ("62f1fd1878d1", "vcvttpd2uqq {sae}, %zmm1, %zmm2"),
        ])
    }

    func testExistingConvertAndWideningRegressionsRemainUnchanged() {
        assertInstructions([
            ("62f17c485bd1", "vcvtdq2ps %zmm1, %zmm2"),
            ("62f17d485bd1", "vcvtps2dq %zmm1, %zmm2"),
            ("62f17e485bd1", "vcvttps2dq %zmm1, %zmm2"),
            ("62f27d4830d1", "vpmovzxbw %ymm1, %zmm2"),
            ("62f17c485ad1", "vcvtps2pd %ymm1, %zmm2"),
        ])
    }

    func testUIntConvertStreamStaysSynchronized() {
        let stream = bytes(
            "62f1fc485bd1" +
            "62f17c4879d1" +
            "62f1fc4879d1" +
            "62f17d1879d1" +
            "62f1fd1878d1" +
            "c3"
        )
        let rows = decoder.decode(Data(stream), baseAddress: 0x1000, maxInstructionCount: 8)
        XCTAssertEqual(rows.map(\.mnemonic), [
            "vcvtqq2ps", "vcvtps2udq", "vcvtpd2udq",
            "vcvtps2uqq", "vcvttpd2uqq", "ret",
        ])
        XCTAssertEqual(rows.map { $0.bytes.count }, [6, 6, 6, 6, 6, 1])
        XCTAssertEqual(rows.last?.address, 0x101E)
    }
}
