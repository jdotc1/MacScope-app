import Foundation
import XCTest
@testable import MacScope

/// Inspect the existing Encodable report, so the missing provenance fields are
/// behavioral red rather than a compile error against a not-yet-existing API.
final class S1RecoveryCodeOwnershipDiagnosticTests: XCTestCase {
    private let caller: UInt64 = 0x1000
    private let leaf: UInt64 = 0x1014
    private let options = MachOParseOptions(recoverStringLiterals: false,
        recoverObjectiveCMetadata: false, recoverSwiftMetadata: false, parseCodeSignature: false)

    private func fixture() throws -> ImageAnalysis {
        let bytes = S1RecoveryMachOFixture.make(bodies: [
            caller: ("caller", [0xa9bf7bfd, 0x94000004, 0xd2800000, 0xa8c17bfd, 0xd65f03c0]),
            leaf: ("leaf", [0xf9400008, 0xf9000028, 0xd65f03c0])
        ], exported: [])
        let parsed = try MachOParser().parseWithFixupCoverage(bytes, options: options)
        XCTAssertTrue(parsed.coverage.isComplete && parsed.coverage.symbolInventoryIsComplete
            && parsed.coverage.exportInventoryIsComplete && parsed.coverage.functionStartsInventoryIsComplete
            && parsed.coverage.dataInCodeInventoryIsComplete)
        XCTAssertEqual(parsed.file.functionStarts.map(\.address), [caller, leaf])
        let section = try XCTUnwrap(parsed.file.sections.first { $0.sectionName == "__text" })
        let raw = bytes.subdata(in: Int(section.fileOffset)..<(Int(section.fileOffset) + Int(section.size)))
        let words = ARM64Decoder().decode(raw, baseAddress: section.address,
                                         maxInstructionCount: Int(section.size / 4))
        XCTAssertEqual(words.count, 8)
        XCTAssertEqual(UInt64(words.count * 4), section.size)
        var analysis = ImageAnalysis()
        analysis.imageBytes = bytes
        analysis.instructions = words.map(InstructionRow.init(decoded:))
        analysis.functions = [
            FunctionSummary(id: UUID(), name: "caller", startAddress: caller, endAddress: leaf, confidence: 1),
            FunctionSummary(id: UUID(), name: "leaf", startAddress: leaf, endAddress: leaf + 12, confidence: 1)
        ]
        return analysis
    }

    private func audit(_ analysis: ImageAnalysis) -> MacIRCallerReturnEvidence.ClosedWorldReport {
        let rows = analysis.instructions.filter { $0.address >= caller && $0.address < leaf }
        let function = MacIRBuilder().buildFunction(name: "caller", startAddress: caller, instructions: rows)
        return MacIRCallerReturnEvidence.collectClosedWorld(analysis: analysis, functions: [function])
    }

    private func admittedControl(file: StaticString = #filePath, line: UInt = #line) throws -> ImageAnalysis {
        let analysis = try fixture()
        let report = audit(analysis)
        XCTAssertNil(report.contracts[leaf], file: file, line: line)
        XCTAssertTrue(report.refusals.contains {
            $0.functionAddress == leaf && $0.reason == "discard_without_return_type_authority"
        }, file: file, line: line)
        XCTAssertTrue(report.evidence[leaf]?.allSatisfy(\.satisfied) == true, file: file, line: line)
        XCTAssertEqual(report.census["decoded_code_words"], 8, file: file, line: line)
        return analysis
    }

    private func assertDiagnostic(_ analysis: ImageAnalysis, address: UInt64, detail: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let report = audit(analysis)
        XCTAssertTrue(report.contracts.isEmpty, file: file, line: line)
        XCTAssertEqual(report.census["condition_4_refused"], analysis.functions.count, file: file, line: line)
        XCTAssertEqual(report.refusals.map(\.reason), ["decoded_code_mismatch_unknown_or_unowned"],
                       file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any],
                                  file: file, line: line)
        let refusals = try XCTUnwrap(object["refusals"] as? [[String: Any]], file: file, line: line)
        let refusal = try XCTUnwrap(refusals.first, file: file, line: line)
        XCTAssertEqual((refusal["instructionAddress"] as? NSNumber)?.uint64Value, address,
            "The refused instruction must have explicit instruction provenance", file: file, line: line)
        XCTAssertEqual(refusal["detail"] as? String, detail,
            "The generic fail-closed reason must carry the exact failed predicate", file: file, line: line)
        XCTAssertNil(refusal["tableAddress"], "Instruction provenance is not a table address", file: file, line: line)
    }

    func testUnknownDecodedWordReportsExactLocationAndDetail() throws {
        var analysis = try admittedControl()
        let address = leaf + 4
        let parsed = try MachOParser().parse(analysis.imageBytes, options: options)
        let section = try XCTUnwrap(parsed.sections.first { $0.sectionName == "__text" })
        let offset = Int(section.fileOffset) + Int(address - section.address)
        for index in 0..<4 { analysis.imageBytes[offset + index] = 0 }
        let word = try XCTUnwrap(ARM64Decoder().decode(Data(repeating: 0, count: 4),
            baseAddress: address, maxInstructionCount: 1).first)
        XCTAssertTrue(["unknown", "unavailable", "udf"].contains(word.mnemonic) || word.mnemonic.hasPrefix("."))
        let index = try XCTUnwrap(analysis.instructions.firstIndex { $0.address == address })
        analysis.instructions[index] = InstructionRow(decoded: word)
        try assertDiagnostic(analysis, address: address,
            detail: "unknown_decoded_word; bytes=\(word.byteText); mnemonic=\(word.mnemonic); operands=\(word.operands)")
    }

    func testMissingStoredRowReportsExactLocationAndDetail() throws {
        var analysis = try admittedControl()
        let address = leaf + 4
        analysis.instructions.removeAll { $0.address == address }
        try assertDiagnostic(analysis, address: address, detail: "missing_stored_row")
    }

    func testDuplicateStoredRowsReportExactLocationAndCount() throws {
        var analysis = try admittedControl()
        let address = leaf + 4
        let row = try XCTUnwrap(analysis.instructions.first { $0.address == address })
        analysis.instructions.append(row)
        try assertDiagnostic(analysis, address: address, detail: "duplicate_stored_rows; count=2")
    }

    func testStoredBytesMismatchReportsExactLocationAndValues() throws {
        var analysis = try admittedControl()
        let address = leaf + 4
        let index = try XCTUnwrap(analysis.instructions.firstIndex { $0.address == address })
        let expected = analysis.instructions[index].bytes
        analysis.instructions[index].bytes = "1f 20 03 d5"
        try assertDiagnostic(analysis, address: address,
            detail: "stored_bytes_mismatch; expected=\(expected); actual=1f 20 03 d5")
    }

    func testStoredMnemonicMismatchReportsExactLocationAndValues() throws {
        var analysis = try admittedControl()
        let address = leaf + 4
        let index = try XCTUnwrap(analysis.instructions.firstIndex { $0.address == address })
        let expected = analysis.instructions[index].mnemonic
        analysis.instructions[index].mnemonic = "nop"
        try assertDiagnostic(analysis, address: address,
            detail: "stored_mnemonic_mismatch; expected=\(expected); actual=nop")
    }

    func testStoredOperandsMismatchReportsExactLocationAndValues() throws {
        var analysis = try admittedControl()
        let address = leaf + 4
        let index = try XCTUnwrap(analysis.instructions.firstIndex { $0.address == address })
        let expected = analysis.instructions[index].operands
        analysis.instructions[index].operands = "x9, [x1]"
        try assertDiagnostic(analysis, address: address,
            detail: "stored_operands_mismatch; expected=\(expected); actual=x9, [x1]")
    }

    func testUnownedDecodedWordReportsExactLocationAndDetail() throws {
        var analysis = try admittedControl()
        analysis.functions[0].endAddress -= 4
        try assertDiagnostic(analysis, address: leaf - 4, detail: "unowned_decoded_word")
    }
}
