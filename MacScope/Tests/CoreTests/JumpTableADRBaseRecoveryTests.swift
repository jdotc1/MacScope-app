import XCTest
@testable import MacScope

/// New compiler witness: Clang 19.1.7, AArch64 ELF tiny code model.
/// See DOT-03 handback minimal.c, linked object, and independent source oracle.
final class JumpTableADRBaseRecoveryTests: XCTestCase {
    private struct Row: DecompilerInstructionRow {
        var address: UInt64
        var bytes = ""
        var mnemonic: String
        var operands: String
        var comment: String? { nil }
    }

    private func rows() -> [Row] {
        let instructions = [
            ("cmp", "w0, #3"), ("b.hi", "0x1030"), ("mov", "w8, w0"),
            ("adr", "x9, 0x2000"), ("adr", "x10, 0x1020"),
            ("ldrb", "w11, [x9, x8]"), ("add", "x10, x10, x11, lsl #2"),
            ("br", "x10"),
        ]
        return instructions.enumerated().map { index, instruction in
            Row(address: 0x1000 + UInt64(index * 4), mnemonic: instruction.0, operands: instruction.1)
        }
    }

    private func resolve(_ rows: [Row], bytes: [UInt8] = [0, 3, 1, 2],
                         upperBound: UInt64 = 0x1034) -> [UInt64: [UInt64]] {
        JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
            guard address >= 0x2000, let offset = Int(exactly: address - 0x2000),
                  offset <= bytes.count, count <= bytes.count - offset else { return nil }
            return Data(bytes[offset..<offset + count])
        }, codeRange: .init(lowerBound: 0x1000, upperBound: upperBound))
    }

    func testCompilerADRBasePreservesOrderedTargets() {
        // Source cases 0:a, 1:b, 2:c, 3:d. Compiler block order is a,c,d,b.
        XCTAssertEqual(resolve(rows())[0x101c], [0x1020, 0x102c, 0x1024, 0x1028])
        let selector = JumpTableResolver.proveSelector(rows: rows(), dispatchIndex: 7)
        XCTAssertEqual(selector?.register, "w0")
        XCTAssertEqual(selector?.caseCount, 4)
    }

    func testSharedTargetsAndHolesRemainOrdered() {
        var input = rows()
        input[0].operands = "w0, #6"
        // Source 0/3:a, 1:b, 4:c, 6:d; 2/5 share the default block.
        XCTAssertEqual(resolve(input, bytes: [0, 2, 1, 0, 3, 1, 4], upperBound: 0x1038)[0x101c],
                       [0x1020, 0x1028, 0x1024, 0x1020, 0x102c, 0x1024, 0x1030])
    }

    func testUnprovenUpperBitsRefuseWholeSite() {
        var input = rows()
        input[2].operands = "x8, x0"
        XCTAssertTrue(resolve(input).isEmpty)
    }

    func testTruncatedOrInvalidTargetRefusesWholeSite() {
        XCTAssertTrue(resolve(rows(), bytes: [0, 3, 1]).isEmpty)
        XCTAssertTrue(resolve(rows(), bytes: [0, 255, 1, 2]).isEmpty)
        XCTAssertTrue(resolve(rows(), upperBound: 0x102c).isEmpty)
    }

    func testExtraRecognizedAddBackCannotHideDispatchClobber() {
        var input = rows()
        input[7] = Row(address: 0x101c, mnemonic: "add", operands: "x10, x0, x2")
        input.append(Row(address: 0x1020, mnemonic: "br", operands: "x10"))
        XCTAssertTrue(resolve(input).isEmpty)
    }

    func testNoncontiguousRowsRefuseWholeSite() {
        var input = rows()
        input[4].address += 1
        XCTAssertTrue(resolve(input).isEmpty)
    }
}
