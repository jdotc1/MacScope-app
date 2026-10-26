import XCTest
@testable import MacScope

final class MacIRFPEnvironmentPseudocodeTests: XCTestCase {
    func testStraightLineFAddsExposeAndCarrySymbolicFPSR() {
        let rows = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "fadd",
                           operands: "s0, s1, s2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "fadd",
                           operands: "s3, s4, s5", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "c0 03 5f d6", mnemonic: "ret",
                           operands: "", hasBreakpoint: false, comment: nil),
        ]
        let text = PseudocodePrinter().print(functionName: "two_fadds", instructions: rows).text
        XCTAssertEqual(text.components(separatedBy: "__a64_fp_env_add_f32(").count - 1, 2, text)
        XCTAssertTrue(text.contains("&fpsr_1"), text)
        XCTAssertTrue(text.contains("&fpsr_2"), text)
        XCTAssertTrue(text.contains("fpcr_0, fpsr_0"), text)
        XCTAssertTrue(text.contains("fpcr_0, fpsr_1"), text)

        // A mixed FP body is outside the bounded state contract. Its FADD
        // must retain the older numeric-only representation without a made-up
        // FPSR carry through the unmodeled FMUL.
        var mixed = rows
        mixed[1] = InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "fmul",
                                  operands: "s3, s4, s5", hasBreakpoint: false, comment: nil)
        let mixedText = PseudocodePrinter().print(functionName: "mixed_fp", instructions: mixed).text
        XCTAssertFalse(mixedText.contains("__a64_fp_env_add_f32"), mixedText)
    }
}
