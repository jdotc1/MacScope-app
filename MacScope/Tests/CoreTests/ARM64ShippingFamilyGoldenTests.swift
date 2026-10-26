import Foundation
import XCTest
@testable import MacScope

/// MS-24: AArch64 families that ship in macOS code (PAC 1716 hints, the Xn|SP modifier of
/// PAC/AUT/PACGA and STG, LDRAA/LDRAB, FJCVTZS, CRC32, FHM, CSSC, DC operations, BTI, SB, FlagM, and
/// the MTE/PAuth system registers), plus the upstream LLVM MC files of those families (`llvm-mc:*`
/// rows, assembled as text input by the generator). Fixtures in `GoldenFixtures/arm64-shipping-vectors/` come from
/// `Scripts/arm64_golden/generate_arm64_shipping_vectors.py`: Apple clang assembles every word for an
/// ELF triple and `llvm-objdump` prints it in generic syntax, so nothing here is hand-encoded.
final class ARM64ShippingFamilyGoldenTests: XCTestCase {
    private struct Row {
        let family: String
        let word: UInt32
        let mnemonic: String
        let operands: String
    }

    private static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("GoldenFixtures/arm64-shipping-vectors")

    private static func table(_ name: String) throws -> [[String]] {
        let text = try String(contentsOf: fixtureDirectory.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
    }

    private static func vectors() throws -> [Row] {
        try table("vectors.tsv").map { f in
            XCTAssertEqual(f.count, 5, "malformed vectors.tsv row \(f)")
            return Row(family: f[0], word: try XCTUnwrap(UInt32(f[1], radix: 16)), mnemonic: f[2], operands: f[3])
        }
    }

    private static func boundary() throws -> [Row] {
        try table("boundary.tsv").map { f in
            Row(family: "boundary", word: try XCTUnwrap(UInt32(f[0], radix: 16)), mnemonic: f[1], operands: f.count > 2 ? f[2] : "")
        }
    }

    private func decode(_ word: UInt32) -> DecodedInstruction {
        let data = Data([UInt8(word & 0xff), UInt8((word >> 8) & 0xff), UInt8((word >> 16) & 0xff), UInt8(word >> 24)])
        return ARM64Decoder().decode(data, baseAddress: 0, maxInstructionCount: 1)[0]
    }

    private func text(_ d: DecodedInstruction) -> String {
        d.operands.isEmpty ? d.mnemonic : "\(d.mnemonic) \(d.operands)"
    }

    /// Numbers compare by value: MacScope prints small immediates in decimal, objdump in hex.
    private static func normalized(_ text: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(-?)(0x[0-9a-fA-F]+|[0-9]+)(?![A-Za-z0-9_])"#)
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let sign = Range(match.range(at: 1), in: text),
                  let digits = Range(match.range(at: 2), in: text) else { continue }
            let token = String(text[digits])
            guard let value = token.hasPrefix("0x") ? UInt64(token.dropFirst(2), radix: 16) : UInt64(token) else { continue }
            result.replaceSubrange(whole, with: "\(text[sign])\(value)")
        }
        return result
    }

    func testFixtureCoversEveryFamily() throws {
        let families = Set(try Self.vectors().map(\.family))
        let ownFamilies: Set<String> = families.filter { !$0.hasPrefix("llvm-mc:") }
        XCTAssertEqual(ownFamilies,
                       ["pac-1716", "pac-sp", "mte-stg", "ldra", "fjcvtzs", "crc32", "fhm", "cssc", "dc", "system", "flagm", "sysreg"])
        XCTAssertEqual(families.filter { $0.hasPrefix("llvm-mc:") }.count, 12)
    }

    func testReferenceEncodings() {
        XCTAssertEqual(text(decode(0xd503_211f)), "pacia1716")
        XCTAssertEqual(text(decode(0xdac1_03e0)), "pacia x0, sp")
        XCTAssertEqual(text(decode(0x9adf_3128)), "pacga x8, x9, sp")
        XCTAssertEqual(text(decode(0xd920_1bff)), "stg sp, [sp, #0x10]")
        XCTAssertEqual(text(decode(0xf860_0fff)), "ldraa xzr, [sp, #-0x1000]!")
        XCTAssertEqual(text(decode(0x1e7e_0225)), "fjcvtzs w5, d17")
        XCTAssertEqual(text(decode(0x9add_5ef3)), "crc32cx w19, w23, x29")
        XCTAssertEqual(text(decode(0x0fb2_0820)), "fmlal v0.2s, v1.2h, v2.h[7]")
        XCTAssertEqual(text(decode(0x91c3_ffff)), "smax xzr, xzr, #-0x1")
        XCTAssertEqual(text(decode(0xd50b_7468)), "dc gva, x8")
        XCTAssertEqual(text(decode(0xd503_24df)), "bti jc")
        XCTAssertEqual(text(decode(0xdac0_1bdf)), "ctz xzr, x30")
        XCTAssertEqual(text(decode(0x3a00_4bed)), "setf16 wzr")
        // RMIF must not fall into the load/store class as a fabricated `str w15, [x1], #-0x8`.
        XCTAssertEqual(text(decode(0xba1f_842f)), "rmif x1, #0x3f, #0xf")
        XCTAssertEqual(text(decode(0xd538_2148)), "mrs x8, APIBKeyLo_EL1")
        XCTAssertEqual(text(decode(0xd503_419f)), "msr TCO, #1")
        // GMID_EL1 is read-only: a write keeps the generic spelling.
        XCTAssertNotEqual(text(decode(0xd519_0083)), "msr GMID_EL1, x3")
        // Apple rejects sf=0 PACGA and sf=0 PAC data-processing words; they must not decode.
        XCTAssertEqual(decode(0x1ac0_3000).mnemonic, "unknown")
        XCTAssertEqual(decode(0x5ac1_03e0).mnemonic, "unknown")
    }

    func testEveryGoldenVectorMatchesObjdumpText() throws {
        let rows = try Self.vectors()
        XCTAssertGreaterThan(rows.count, 350)
        for row in rows {
            let decoded = decode(row.word)
            let context = "\(String(format: "%08x", row.word)) [\(row.family)]"
            XCTAssertEqual(decoded.mnemonic, row.mnemonic, context)
            XCTAssertEqual(Self.normalized(decoded.operands), Self.normalized(row.operands), context)
        }
    }

    /// The MTE and PAuth system registers MacScope names (spelled as LLVM prints them).
    private static let shippingSystemRegisters: Set<String> = [
        "TCO", "GCR_EL1", "RGSR_EL1", "TFSR_EL1", "TFSRE0_EL1", "TFSR_EL2", "TFSR_EL12", "TFSR_EL3", "GMID_EL1",
        "APIAKeyLo_EL1", "APIAKeyHi_EL1", "APIBKeyLo_EL1", "APIBKeyHi_EL1", "APDAKeyLo_EL1", "APDAKeyHi_EL1",
        "APDBKeyLo_EL1", "APDBKeyHi_EL1", "APGAKeyLo_EL1", "APGAKeyHi_EL1",
    ]

    private static func namesShippingRegister(_ mnemonic: String, _ operands: String) -> Bool {
        (mnemonic == "mrs" || mnemonic == "msr")
            && operands.components(separatedBy: CharacterSet(charactersIn: ", ")).contains { shippingSystemRegisters.contains($0) }
    }

    /// Bit-flip and register-edge neighbours: where objdump decodes a mnemonic of these families,
    /// MacScope must render the same text; elsewhere it must not claim one of these mnemonics.
    /// MRS/MSR neighbours are compared only when either side names one of the registers above
    /// (other system registers keep MacScope's generic spelling, which is not this family's).
    func testBoundaryNeighboursMatchObjdump() throws {
        let familyMnemonics = Set(try Self.vectors().filter { !$0.family.hasPrefix("llvm-mc:") }.map(\.mnemonic))
            .subtracting(["mrs", "msr"])
        let rows = try Self.boundary()
        XCTAssertGreaterThan(rows.count, 20000)
        var matched = 0, other = 0
        for row in rows {
            let decoded = decode(row.word)
            let context = "\(String(format: "%08x", row.word)): objdump `\(row.mnemonic) \(row.operands)`, MacScope `\(text(decoded))`"
            if familyMnemonics.contains(row.mnemonic) || Self.namesShippingRegister(row.mnemonic, row.operands) {
                XCTAssertEqual(Self.normalized(text(decoded)), Self.normalized("\(row.mnemonic) \(row.operands)".trimmingCharacters(in: .whitespaces)), context)
                matched += 1
            } else {
                XCTAssertFalse(familyMnemonics.contains(decoded.mnemonic), context)
                XCTAssertFalse(Self.namesShippingRegister(decoded.mnemonic, decoded.operands), context)
                other += 1
            }
        }
        XCTAssertGreaterThan(matched, 10000)
        XCTAssertGreaterThan(other, 10000)
    }
}
