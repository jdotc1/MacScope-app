import XCTest
@testable import MacScope

final class DecompilerImmediateBitPatternTests: XCTestCase {
    private func operation(_ mnemonic: String, _ operands: String) -> MacIROperation {
        var state = BuilderState()
        return MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).operation(
            for: .init(address: 0x1000, byteText: "", mnemonic: mnemonic, operands: operands),
            state: &state)
    }

    func testRegisterHexadecimalBitPatterns() {
        let cases: [(String, Int, UInt64)] = [
            ("#0xffffffff00000000", 64, 0xffffffff00000000),
            ("#0xfefefefefefefefe", 64, 0xfefefefefefefefe),
            ("#0xfffffffffffffff0", 64, 0xfffffffffffffff0),
            ("#0xffffffffffffffe0", 64, 0xffffffffffffffe0),
            ("#0xffffffffffffffc0", 64, 0xffffffffffffffc0),
            ("#0xfffffffffffffffc", 64, 0xfffffffffffffffc),
            ("#0x8000000000000000", 64, 0x8000000000000000),
            ("#-0x8000000000000000", 64, 0x8000000000000000),
            ("#-0xffffffffffffffff", 64, 1),
            ("#0xffffffffffffffff", 64, 0xffffffffffffffff),
            ("#0xffffffff", 32, 0xffffffff),
            ("#-0x80000000", 32, 0x80000000),
            ("#0xfffffffffffffff0", 32, 0xfffffff0),
            ("#-0x1", 32, 0xffffffff),
            ("#0x0", 64, 0),
            ("#-0x0", 64, 0)]
        for (text, width, bits) in cases {
            XCTAssertEqual(MacIRBuilder.parseRegisterImmediate(text, bitWidth: width),
                           Int64(bitPattern: bits), text)
        }
    }

    func testRejectsMalformedAndOverwideHexadecimal() {
        for text in ["#0x10000000000000000", "#-0x10000000000000000", "#0x",
                     "#-0x", "#0xg", "#0x1_0", "#0x1 0", "#--0x1",
                     "##0x1", "#0x+1", "#0x-1", "#0xfffffffffffffffff"] {
            XCTAssertNil(MacIRBuilder.parseRegisterImmediate(text, bitWidth: 64), text)
        }
        XCTAssertNil(MacIRBuilder.parseRegisterImmediate("#0xff", bitWidth: 16))
        XCTAssertNil(MacIRBuilder.parseRegisterImmediate("#0xff", bitWidth: 128))
    }

    func testLegacyRangeParserAndGenericValueStayUnchanged() {
        for text in ["#0x8000000000000000", "#0xffffffffffffffff", "#0xfffffffffffffff0",
                     "#0xffffffff00000000", "#0xfefefefefefefefe", "#-0x8000000000000000",
                     "#0x10000000000000000", "#-0x10000000000000000"] {
            XCTAssertNil(MacIRBuilder.parseImmediate(text), text)
            XCTAssertEqual(MacIRBuilder.value(for: text, state: BuilderState()), .unknown(text))
        }
        XCTAssertEqual(MacIRBuilder.parseImmediate("#63"), 63)
        XCTAssertEqual(MacIRBuilder.parseImmediate("#-16"), -16)
        XCTAssertEqual(MacIRBuilder.parseImmediate("#0xffff"), 65535)
    }

    func testMovCarriesSixRetainedLiteralsAndExpectedSpelling() {
        let cases: [(String, UInt64, String)] = [
            ("#0xffffffff00000000", 0xffffffff00000000, "-0x100000000"),
            ("#0xfefefefefefefefe", 0xfefefefefefefefe, "-0x101010101010102"),
            ("#0xfffffffffffffff0", 0xfffffffffffffff0, "-0x10"),
            ("#0xffffffffffffffe0", 0xffffffffffffffe0, "-0x20"),
            ("#0xffffffffffffffc0", 0xffffffffffffffc0, "-0x40"),
            ("#0xfffffffffffffffc", 0xfffffffffffffffc, "-0x4")]
        for (text, bits, spelling) in cases {
            guard case let .assign(_, source) = operation("mov", "x9, \(text)") else {
                return XCTFail("Expected MOV assignment")
            }
            XCTAssertEqual(source, .immediate(Int64(bitPattern: bits)))
            XCTAssertEqual(source.description, spelling)
        }
    }

    func testAndOnlyOptsInForMatchingCanonicalGPRViews() {
        let cases: [(String, UInt64)] = [("x9", 0xfffffffffffffff0), ("w9", 0xfffffff0)]
        for (register, bits) in cases {
            guard case let .binary(_, op, _, right) = operation("and", "\(register), \(register), #0xfffffffffffffff0") else {
                return XCTFail("Expected AND binary operation")
            }
            XCTAssertEqual(op, "&")
            XCTAssertEqual(right, .immediate(Int64(bitPattern: bits)))
        }
        for operands in ["x99, x99, #0xfffffffffffffff0", "x9, w9, #0xfffffffffffffff0"] {
            guard case let .binary(_, _, _, right) = operation("and", operands) else {
                return XCTFail("Expected unchanged binary fallback")
            }
            XCTAssertEqual(right, .unknown("#0xfffffffffffffff0"))
        }
    }

    func testMovzAndInvalidDestinationDoNotGainHighBitValues() {
        for (mnemonic, destination) in [("movz", "x9"), ("mov", "x99")] {
            guard case let .assign(_, source) = operation(mnemonic, "\(destination), #0xfffffffffffffff0") else {
                return XCTFail("Expected unchanged assignment fallback")
            }
            XCTAssertEqual(source, .unknown("#0xfffffffffffffff0"))
        }
    }
    func testRangeSensitiveShiftOperandsRemainUnknown() {
        for mnemonic in ["lsl", "lsr", "asr"] {
            for (register, width) in [("x9", 64), ("w9", 32)] {
                guard case let .binary(_, _, _, right) = operation(mnemonic,
                    "\(register), \(register), #0xfffffffffffffff0") else {
                    return XCTFail("Expected original shift fallback")
                }
                XCTAssertEqual(right, .binaryExpression(op: "&",
                    left: .unknown("#0xfffffffffffffff0"), right: .immediate(Int64(width - 1))))
            }
        }
    }

}
