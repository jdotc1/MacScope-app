import Foundation
import XCTest
@testable import MacScope

/// Real selected-image bytes exercise the existing caller-audit entry point.
/// The large positive must execute as behavioral red before ownership indexing
/// changes; no invented completion flag or test-only production API is used.
final class S1RecoveryCodeOwnershipTests: XCTestCase {
    private let caller: UInt64 = 0x1000
    private let leaf: UInt64 = 0x1014
    private let options = MachOParseOptions(recoverStringLiterals: false,
        recoverObjectiveCMetadata: false, recoverSwiftMetadata: false, parseCodeSignature: false)

    private func fixture(functionCount: Int = 3) throws -> ImageAnalysis {
        precondition((2...4096).contains(functionCount))
        var bodies: [UInt64: (String, [UInt32])] = [
            caller: ("caller", [0xa9bf7bfd, 0x94000004, 0xd2800000, 0xa8c17bfd, 0xd65f03c0]),
            leaf: ("leaf", [0xf9400008, 0xf9000028, 0xd503201f, 0xd65f03c0])
        ]
        for index in 2..<functionCount {
            bodies[leaf + UInt64((index - 1) * 16)] =
                ("ordinary_\(index)", [0xd503201f, 0xd503201f, 0xd503201f, 0xd65f03c0])
        }
        let bytes = S1RecoveryMachOFixture.make(bodies: bodies, exported: [])
        let parsed = try MachOParser().parseWithFixupCoverage(bytes, options: options)
        XCTAssertTrue(parsed.coverage.isComplete && parsed.coverage.symbolInventoryIsComplete
            && parsed.coverage.exportInventoryIsComplete && parsed.coverage.functionStartsInventoryIsComplete
            && parsed.coverage.dataInCodeInventoryIsComplete,
            "The fixture must reach the ownership audit, not an earlier inventory refusal")
        XCTAssertEqual(parsed.file.functionStarts.map(\.address), bodies.keys.sorted())
        let section = try XCTUnwrap(parsed.file.sections.first { $0.sectionName == "__text" })
        let raw = bytes.subdata(in: Int(section.fileOffset)..<(Int(section.fileOffset) + Int(section.size)))
        let words = ARM64Decoder().decode(raw, baseAddress: section.address,
                                         maxInstructionCount: Int(section.size / 4))
        XCTAssertEqual(words.count, functionCount * 4 + 1)
        XCTAssertEqual(UInt64(words.count * 4), section.size)
        XCTAssertFalse(words.contains { ["unknown", "unavailable", "udf"].contains($0.mnemonic)
            || $0.mnemonic.hasPrefix(".") })
        XCTAssertEqual(words.first { $0.address == caller + 4 }?.branchTarget, leaf)
        var analysis = ImageAnalysis()
        analysis.functions = bodies.sorted { $0.key < $1.key }.map { address, body in
            FunctionSummary(id: UUID(), name: body.0, startAddress: address,
                endAddress: address + UInt64(body.1.count * 4), confidence: 1)
        }
        analysis.instructions = words.map(InstructionRow.init(decoded:))
        analysis.imageBytes = bytes
        XCTAssertEqual(analysis.functions.count, functionCount)
        XCTAssertEqual(analysis.functions[0].endAddress, leaf)
        XCTAssertEqual(analysis.functions.last?.endAddress, section.address + section.size)
        return analysis
    }

    private func audit(_ analysis: ImageAnalysis) -> MacIRCallerReturnEvidence.ClosedWorldReport {
        // Only the actual direct caller needs IR for the discard proof. Its raw
        // bytes and every other function's bytes are independently re-decoded by
        // collectClosedWorld, including functions with no direct callers.
        let rows = analysis.instructions.filter { $0.address >= caller && $0.address < leaf }
        let function = MacIRBuilder().buildFunction(name: "caller", startAddress: caller, instructions: rows)
        return MacIRCallerReturnEvidence.collectClosedWorld(analysis: analysis, functions: [function])
    }

    @discardableResult
    private func assertAdmitted(_ analysis: ImageAnalysis,
                                file: StaticString = #filePath, line: UInt = #line)
        -> MacIRCallerReturnEvidence.ClosedWorldReport {
        let report = audit(analysis)
        XCTAssertEqual(report.census["decoded_code_words"], analysis.instructions.count, file: file, line: line)
        XCTAssertNil(report.contracts[leaf], file: file, line: line)
        XCTAssertTrue(report.refusals.contains {
            $0.functionAddress == leaf && $0.reason == "discard_without_return_type_authority"
        }, file: file, line: line)
        XCTAssertEqual(report.evidence[leaf]?.count, 6, file: file, line: line)
        XCTAssertTrue(report.evidence[leaf]?.allSatisfy(\.satisfied) == true, file: file, line: line)
        XCTAssertEqual(report.contracts.count, 0, file: file, line: line)
        return report
    }

    private func assertRefused(_ analysis: ImageAnalysis, reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let report = audit(analysis)
        XCTAssertTrue(report.contracts.isEmpty, file: file, line: line)
        XCTAssertTrue(report.refusals.contains { $0.reason == reason },
            "Expected \(reason), got \(report.refusals.map(\.reason))", file: file, line: line)
    }

    func testCompleteCodeBeyondQuadraticOwnershipBudgetPreservesDiscardEvidence() throws {
        // 4095 four-word functions plus one five-word caller: exactly 4096
        // functions, 16,385 words, and 67,112,960 old linear-scan comparisons.
        let analysis = try fixture(functionCount: 4096)
        XCTAssertEqual(analysis.instructions.count * analysis.functions.count, 67_112_960)
        XCTAssertLessThan(analysis.instructions.count, 1_000_000)
        let report = assertAdmitted(analysis)
        XCTAssertFalse(report.refusals.contains { $0.reason == "code_ownership_work_cap" })
    }

    func testAdjacentHalfOpenSpansAdmitButInteriorAndFinalGapsRefuse() throws {
        // Paired scalable admission is intentionally red on the original audit;
        // the small mutations independently preserve its fail-closed behavior.
        assertAdmitted(try fixture(functionCount: 4096))
        let control = try fixture()
        assertAdmitted(control)
        var reversed = control
        reversed.functions.reverse()
        assertAdmitted(reversed)
        // The exact end of one function is the next function's start, never an
        // owner in both. Removing the preceding RET creates a one-word gap.
        var interiorGap = control
        interiorGap.functions[0].endAddress -= 4
        assertRefused(interiorGap, reason: "decoded_code_mismatch_unknown_or_unowned")
        // The final decoded RET at an exclusive end is not owned by that span.
        var finalGap = control
        finalGap.functions[finalGap.functions.count - 1].endAddress -= 4
        assertRefused(finalGap, reason: "decoded_code_mismatch_unknown_or_unowned")
    }

    func testOverlappingAndEmptySpansCannotAcquireAnOwner() throws {
        assertAdmitted(try fixture(functionCount: 4096))
        let control = try fixture()
        assertAdmitted(control)
        var overlap = control
        overlap.functions[0].endAddress += 4
        assertRefused(overlap, reason: "function_span_ambiguous_or_outside_declared_code")
        var empty = control
        empty.functions[1].endAddress = empty.functions[1].startAddress
        assertRefused(empty, reason: "function_span_ambiguous_or_outside_declared_code")
        var duplicate = control
        duplicate.functions.append(duplicate.functions[1])
        assertRefused(duplicate, reason: "image_or_function_inventory_unavailable_or_capped")
    }

    func testIndexedOwnershipStillRequiresEveryExactUniqueDecodedRow() throws {
        assertAdmitted(try fixture(functionCount: 4096))
        let control = try fixture()
        assertAdmitted(control)
        let index = try XCTUnwrap(control.instructions.firstIndex { $0.address == leaf + 8 })
        var missing = control
        missing.instructions.remove(at: index)
        assertRefused(missing, reason: "decoded_code_mismatch_unknown_or_unowned")
        var duplicate = control
        duplicate.instructions.append(duplicate.instructions[index])
        assertRefused(duplicate, reason: "decoded_code_mismatch_unknown_or_unowned")
        var badBytes = control
        badBytes.instructions[index].bytes = "c0 03 5f d6"
        assertRefused(badBytes, reason: "decoded_code_mismatch_unknown_or_unowned")
        var badMnemonic = control
        badMnemonic.instructions[index].mnemonic = "ret"
        assertRefused(badMnemonic, reason: "decoded_code_mismatch_unknown_or_unowned")
        var badOperands = control
        badOperands.instructions[index].operands = "x9"
        assertRefused(badOperands, reason: "decoded_code_mismatch_unknown_or_unowned")
        var outside = control
        outside.instructions.append(InstructionRow(address: 0x800,
            bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil))
        assertRefused(outside, reason: "rows_outside_complete_code_data_partition")
    }

    func testOwnedUnknownRawWordStillRefusesDespiteMatchingStoredRow() throws {
        assertAdmitted(try fixture(functionCount: 4096))
        let control = try fixture()
        assertAdmitted(control)
        var unknown = control
        let address = leaf + 8
        let parsed = try MachOParser().parse(control.imageBytes, options: options)
        let section = try XCTUnwrap(parsed.sections.first { $0.sectionName == "__text" })
        let offset = Int(section.fileOffset) + Int(address - section.address)
        for index in 0..<4 { unknown.imageBytes[offset + index] = 0 }
        let word = try XCTUnwrap(ARM64Decoder().decode(Data(repeating: 0, count: 4),
            baseAddress: address, maxInstructionCount: 1).first)
        XCTAssertTrue(["unknown", "unavailable", "udf"].contains(word.mnemonic) || word.mnemonic.hasPrefix("."))
        let rowIndex = try XCTUnwrap(unknown.instructions.firstIndex { $0.address == address })
        unknown.instructions[rowIndex] = InstructionRow(decoded: word)
        assertRefused(unknown, reason: "decoded_code_mismatch_unknown_or_unowned")
    }

    func testOneMillionDeclaredWordLimitStillRefusesBeforeDecoding() throws {
        assertAdmitted(try fixture(functionCount: 4096))
        assertAdmitted(try fixture())
        let count = 1_000_001
        var words = Array(repeating: UInt32(0xd503201f), count: count)
        words[count - 1] = 0xd65f03c0
        let bytes = S1RecoveryMachOFixture.make(bodies: [caller: ("oversized", words)], exported: [])
        let parsed = try MachOParser().parseWithFixupCoverage(bytes, options: options)
        XCTAssertTrue(parsed.coverage.isComplete)
        XCTAssertEqual(parsed.file.sections.filter(\.isExecutableInstructions).reduce(UInt64(0)) { $0 + $1.size / 4 },
                       UInt64(count))
        var analysis = ImageAnalysis()
        analysis.imageBytes = bytes
        analysis.functions = [FunctionSummary(id: UUID(), name: "oversized", startAddress: caller,
            endAddress: caller + UInt64(count * 4), confidence: 1)]
        // No stored rows: a cap must refuse before decoding or row matching.
        let report = MacIRCallerReturnEvidence.collectClosedWorld(analysis: analysis, functions: [])
        XCTAssertTrue(report.contracts.isEmpty)
        XCTAssertEqual(report.refusals.map(\.reason), ["code_ownership_work_cap"])
        XCTAssertNil(report.census["decoded_code_words"])
    }
}
