import Foundation
import XCTest
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif

final class TSTASRStatementLocalTests: XCTestCase {
    private let overrides = ["w8": "source_word", "w9": "other_word", "w10": "guard_word",
                             "x13": "selected_a", "x14": "selected_b", "x0": "result"]

    private func fixture(producer: UInt32, consumer: UInt32,
                         middle: [UInt32] = [], tail: [UInt32] = [0x710001ff, 0xd65f03c0]) -> MacIRFunction {
        let words: [UInt32] = [0xb9400268, 0xb9400289, 0xb94002aa, producer] + middle + [consumer] + tail
        let bytes = words.flatMap { word in
            [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
             UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
        }
        let rows = ARM64Decoder().decode(Data(bytes), baseAddress: 0x7000,
            maxInstructionCount: words.count).map { InstructionRow(decoded: $0) }
        XCTAssertEqual(rows.count, words.count)
        return MacIRBuilder(ssaEnabled: false).buildFunction(name: "_339_cell", instructions: rows)
    }

    private func checkCell(_ id: String, consumer: UInt32, mnemonic: String,
                           truth: [Bool], shift: Int = 1,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let function = fixture(producer: 0x6a89011f | (UInt32(shift) << 10), consumer: consumer)
        XCTAssertFalse(function.ssaEnabled, file: file, line: line)
        let printer = PseudocodePrinter()
        let document = printer.print(function: function, registerNameOverrides: overrides)
        // This already-existing overload carries nonnil cancellation state and
        // therefore deliberately retains the approved legacy presentation path.
        let legacy = try printer.print(function: function, registerNameOverrides: overrides, checkpoint: {})
        XCTAssertNotEqual(document.text, legacy.text, id, file: file, line: line)
        let bindings = document.lines.filter { $0.sourceAddress == 0x700c }
        XCTAssertEqual(bindings.count, 1, document.text, file: file, line: line)
        let binding = try XCTUnwrap(bindings.first, file: file, line: line)
        XCTAssertEqual(binding.kind, .declaration, file: file, line: line)
        XCTAssertEqual(binding.text.trimmingCharacters(in: .whitespaces),
            "uint32_t tst_u_700c = (uint32_t)(other_word);", file: file, line: line)
        XCTAssertFalse(document.text.contains("__compare((int32_t)((uint32_t)(source_word)"), file: file, line: line)
        let consumers = document.lines.filter { $0.sourceAddress == 0x7010 }
        XCTAssertEqual(consumers.count, 1, document.text, file: file, line: line)
        let consumed = try XCTUnwrap(consumers.first, file: file, line: line)
        XCTAssertEqual(consumed.lineNumber, binding.lineNumber + 1, file: file, line: line)
        let body = String(consumed.text.components(separatedBy: " //")[0]).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(body.contains("tst_u_700c"), body, file: file, line: line)
        XCTAssertFalse(body.contains("other_word"), "Wm must be bound exactly once", file: file, line: line)
        XCTAssertTrue(body.contains("0x80000000"), body, file: file, line: line)
        let statement: String
        if mnemonic == "b.cond" {
            XCTAssertTrue(body.hasPrefix("if (") && body.hasSuffix(") {"), body, file: file, line: line)
            guard body.hasPrefix("if ("), body.hasSuffix(") {") else { return }
            // Observe the actual inverted structured header, not a newly rendered IR predicate.
            statement = "result = !(\(body.dropFirst(4).dropLast(3)));"
        } else { statement = body }
        let signature = "int64_t cell339(uint32_t source_word, uint32_t other_word, int64_t selected_a, int64_t selected_b) {"
        let contract = OrdinaryC.Contract(signature: signature,
            inputs: [.init(name: "source_word", type: .u32, entrySlot: 8),
                     .init(name: "other_word", type: .u32, entrySlot: 9),
                     .init(name: "selected_a", type: .i64, entrySlot: 13),
                     .init(name: "selected_b", type: .i64, entrySlot: 14)],
            fields: [], calls: [:], exterior: [:], terminalRow: 99,
            terminalPayload: "return result;", terminalName: "result", returnType: .i64,
            rowsByAddress: [0x700c: 3, 0x7010: 4, 0x7100: 99], allowedLabels: [],
            memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        // Full printing above establishes placement. The observation below runs
        // only its actual emitted binding and consumer, not an invented return contract.
        let program = try OrdinaryC.Program(lines: [
            .init(text: signature, source: nil, envelope: .signature),
            // Observation scaffold: preserve a real, explicitly typed C destination.
            .init(text: "int64_t result;", source: nil, envelope: .body),
            .init(text: binding.text, source: 0x700c, envelope: .body),
            .init(text: statement, source: 0x7010, envelope: .body),
            .init(text: "return result;", source: 0x7100, envelope: .body),
            .init(text: "}", source: nil, envelope: .closingBrace)], contract: contract)
        let boundaries: [UInt64] = [0x80000000, 0xffffffff, 0, 0x7fffffff]
        XCTAssertEqual(truth.count, 4, file: file, line: line)
        guard truth.count == 4 else { return }
        for (i, bits) in boundaries.enumerated() {
            do {
                let result = try OrdinaryC.Machine(program: program, scenario: .init(name: "\(id)-\(i)",
                    inputs: ["source_word": .init(bits, .u32), "other_word": .init(0xffffffff, .u32),
                             "selected_a": .init(5, .i64), "selected_b": .init(9, .i64)],
                    memory: [:], responses: [])).run()
                let expected: Int64
                switch mnemonic {
                case "cset": expected = truth[i] ? 1 : 0
                case "csetm": expected = truth[i] ? -1 : 0
                case "csel": expected = truth[i] ? 5 : 9
                case "csinc": expected = truth[i] ? 5 : 10
                case "csinv": expected = truth[i] ? 5 : -10
                case "csneg": expected = truth[i] ? 5 : -9
                case "cinc": expected = truth[i] ? 6 : 5
                case "cinv": expected = truth[i] ? -6 : 5
                case "cneg": expected = truth[i] ? -5 : 5
                default: expected = truth[i] ? 1 : 0
                }
                XCTAssertTrue(result.returned, file: file, line: line)
                XCTAssertEqual(result.terminal?.bits, UInt64(bitPattern: expected), body, file: file, line: line)
            } catch { XCTFail("\(id) boundary \(i): \(error)", file: file, line: line) }
        }
    }

    private func checkDeclined(_ function: MacIRFunction, names: [String: String]? = nil,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let printer = PseudocodePrinter(), names = names ?? overrides
        let actual = printer.print(function: function, registerNameOverrides: names)
        let legacy = try printer.print(function: function, registerNameOverrides: names, checkpoint: {})
        XCTAssertEqual(actual.text, legacy.text, file: file, line: line)
        XCTAssertFalse(actual.lines.contains { $0.kind == .declaration && $0.text.contains("uint32_t tst_u_700c =") },
            actual.text, file: file, line: line)
    }

    func test339TSTASRBCONDGE() throws {
        try checkCell("TSTASRBCONDGE", consumer: 0x5400004a, mnemonic: "b.cond",
            truth: [false, false, true, true])
    }

    func test339TSTASRBCONDLT() throws {
        try checkCell("TSTASRBCONDLT", consumer: 0x5400004b, mnemonic: "b.cond",
            truth: [true, true, false, false])
    }

    func test339TSTASRBCONDGT() throws {
        try checkCell("TSTASRBCONDGT", consumer: 0x5400004c, mnemonic: "b.cond",
            truth: [false, false, false, true])
    }

    func test339TSTASRBCONDLE() throws {
        try checkCell("TSTASRBCONDLE", consumer: 0x5400004d, mnemonic: "b.cond",
            truth: [true, true, true, false])
    }

    func test339TSTASRCSETGE() throws {
        try checkCell("TSTASRCSETGE", consumer: 0x9a9fb7e0, mnemonic: "cset",
            truth: [false, false, true, true])
    }

    func test339TSTASRCSETLT() throws {
        try checkCell("TSTASRCSETLT", consumer: 0x9a9fa7e0, mnemonic: "cset",
            truth: [true, true, false, false])
    }

    func test339TSTASRCSETGT() throws {
        try checkCell("TSTASRCSETGT", consumer: 0x9a9fd7e0, mnemonic: "cset",
            truth: [false, false, false, true])
    }

    func test339TSTASRCSETLE() throws {
        try checkCell("TSTASRCSETLE", consumer: 0x9a9fc7e0, mnemonic: "cset",
            truth: [true, true, true, false])
    }

    func test339TSTASRCSETMGE() throws {
        try checkCell("TSTASRCSETMGE", consumer: 0xda9fb3e0, mnemonic: "csetm",
            truth: [false, false, true, true])
    }

    func test339TSTASRCSETMLT() throws {
        try checkCell("TSTASRCSETMLT", consumer: 0xda9fa3e0, mnemonic: "csetm",
            truth: [true, true, false, false])
    }

    func test339TSTASRCSETMGT() throws {
        try checkCell("TSTASRCSETMGT", consumer: 0xda9fd3e0, mnemonic: "csetm",
            truth: [false, false, false, true])
    }

    func test339TSTASRCSETMLE() throws {
        try checkCell("TSTASRCSETMLE", consumer: 0xda9fc3e0, mnemonic: "csetm",
            truth: [true, true, true, false])
    }

    func test339TSTASRCSELGE() throws {
        try checkCell("TSTASRCSELGE", consumer: 0x9a8ea1a0, mnemonic: "csel",
            truth: [false, false, true, true])
    }

    func test339TSTASRCSELLT() throws {
        try checkCell("TSTASRCSELLT", consumer: 0x9a8eb1a0, mnemonic: "csel",
            truth: [true, true, false, false])
    }

    func test339TSTASRCSELGT() throws {
        try checkCell("TSTASRCSELGT", consumer: 0x9a8ec1a0, mnemonic: "csel",
            truth: [false, false, false, true])
    }

    func test339TSTASRCSELLE() throws {
        try checkCell("TSTASRCSELLE", consumer: 0x9a8ed1a0, mnemonic: "csel",
            truth: [true, true, true, false])
    }

    func test339TSTASRCSINCGE() throws {
        try checkCell("TSTASRCSINCGE", consumer: 0x9a8ea5a0, mnemonic: "csinc",
            truth: [false, false, true, true])
    }

    func test339TSTASRCSINCLT() throws {
        try checkCell("TSTASRCSINCLT", consumer: 0x9a8eb5a0, mnemonic: "csinc",
            truth: [true, true, false, false])
    }

    func test339TSTASRCSINCGT() throws {
        try checkCell("TSTASRCSINCGT", consumer: 0x9a8ec5a0, mnemonic: "csinc",
            truth: [false, false, false, true])
    }

    func test339TSTASRCSINCLE() throws {
        try checkCell("TSTASRCSINCLE", consumer: 0x9a8ed5a0, mnemonic: "csinc",
            truth: [true, true, true, false])
    }

    func test339TSTASRCSINVGE() throws {
        try checkCell("TSTASRCSINVGE", consumer: 0xda8ea1a0, mnemonic: "csinv",
            truth: [false, false, true, true])
    }

    func test339TSTASRCSINVLT() throws {
        try checkCell("TSTASRCSINVLT", consumer: 0xda8eb1a0, mnemonic: "csinv",
            truth: [true, true, false, false])
    }

    func test339TSTASRCSINVGT() throws {
        try checkCell("TSTASRCSINVGT", consumer: 0xda8ec1a0, mnemonic: "csinv",
            truth: [false, false, false, true])
    }

    func test339TSTASRCSINVLE() throws {
        try checkCell("TSTASRCSINVLE", consumer: 0xda8ed1a0, mnemonic: "csinv",
            truth: [true, true, true, false])
    }

    func test339TSTASRCSNEGGE() throws {
        try checkCell("TSTASRCSNEGGE", consumer: 0xda8ea5a0, mnemonic: "csneg",
            truth: [false, false, true, true])
    }

    func test339TSTASRCSNEGLT() throws {
        try checkCell("TSTASRCSNEGLT", consumer: 0xda8eb5a0, mnemonic: "csneg",
            truth: [true, true, false, false])
    }

    func test339TSTASRCSNEGGT() throws {
        try checkCell("TSTASRCSNEGGT", consumer: 0xda8ec5a0, mnemonic: "csneg",
            truth: [false, false, false, true])
    }

    func test339TSTASRCSNEGLE() throws {
        try checkCell("TSTASRCSNEGLE", consumer: 0xda8ed5a0, mnemonic: "csneg",
            truth: [true, true, true, false])
    }

    func test339TSTASRCINCGE() throws {
        try checkCell("TSTASRCINCGE", consumer: 0x9a8db5a0, mnemonic: "cinc",
            truth: [false, false, true, true])
    }

    func test339TSTASRCINCLT() throws {
        try checkCell("TSTASRCINCLT", consumer: 0x9a8da5a0, mnemonic: "cinc",
            truth: [true, true, false, false])
    }

    func test339TSTASRCINCGT() throws {
        try checkCell("TSTASRCINCGT", consumer: 0x9a8dd5a0, mnemonic: "cinc",
            truth: [false, false, false, true])
    }

    func test339TSTASRCINCLE() throws {
        try checkCell("TSTASRCINCLE", consumer: 0x9a8dc5a0, mnemonic: "cinc",
            truth: [true, true, true, false])
    }

    func test339TSTASRCINVGE() throws {
        try checkCell("TSTASRCINVGE", consumer: 0xda8db1a0, mnemonic: "cinv",
            truth: [false, false, true, true])
    }

    func test339TSTASRCINVLT() throws {
        try checkCell("TSTASRCINVLT", consumer: 0xda8da1a0, mnemonic: "cinv",
            truth: [true, true, false, false])
    }

    func test339TSTASRCINVGT() throws {
        try checkCell("TSTASRCINVGT", consumer: 0xda8dd1a0, mnemonic: "cinv",
            truth: [false, false, false, true])
    }

    func test339TSTASRCINVLE() throws {
        try checkCell("TSTASRCINVLE", consumer: 0xda8dc1a0, mnemonic: "cinv",
            truth: [true, true, true, false])
    }

    func test339TSTASRCNEGGE() throws {
        try checkCell("TSTASRCNEGGE", consumer: 0xda8db5a0, mnemonic: "cneg",
            truth: [false, false, true, true])
    }

    func test339TSTASRCNEGLT() throws {
        try checkCell("TSTASRCNEGLT", consumer: 0xda8da5a0, mnemonic: "cneg",
            truth: [true, true, false, false])
    }

    func test339TSTASRCNEGGT() throws {
        try checkCell("TSTASRCNEGGT", consumer: 0xda8dd5a0, mnemonic: "cneg",
            truth: [false, false, false, true])
    }

    func test339TSTASRCNEGLE() throws {
        try checkCell("TSTASRCNEGLE", consumer: 0xda8dc5a0, mnemonic: "cneg",
            truth: [true, true, true, false])
    }

    func test339ASRShift31GE() throws {
        try checkCell("shift31", consumer: 0x9a9fb7e0, mnemonic: "cset", truth: [false, false, true, true], shift: 31)
    }
    func test339XTSTExcluded() throws { try checkDeclined(fixture(producer: 0xea89051f, consumer: 0x9a9fb7e0)) }
    func test339LSLExcluded() throws { try checkDeclined(fixture(producer: 0x6a09051f, consumer: 0x9a9fb7e0)) }
    func test339LSRExcluded() throws { try checkDeclined(fixture(producer: 0x6a49051f, consumer: 0x9a9fb7e0)) }
    func test339RORExcluded() throws { try checkDeclined(fixture(producer: 0x6ac9051f, consumer: 0x9a9fb7e0)) }
    func test339ASRZeroExcluded() throws { try checkDeclined(fixture(producer: 0x6a89011f, consumer: 0x9a9fb7e0)) }
    func test339InterveningFlagWriterExcluded() throws { try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0, middle: [0xf100013f])) }
    func test339NonadjacentExcluded() throws { try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0, middle: [0xd503201f])) }
    func test339NameCollisionExcluded() throws {
        var names = overrides; names["w15"] = "tst_u_700c"
        try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0), names: names)
    }
    func test339UnsignedConditionExcluded() throws { try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9f37e0)) }
    func test339SecondReaderExcluded() throws { try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0, tail: [0x9a9fa7e1, 0xd65f03c0])) }
    func test339CallBeforeKillExcluded() throws { try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0, tail: [0x94000040, 0xd65f03c0])) }
    func test339UnknownBeforeKillExcluded() throws { try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0, tail: [0xffffffff, 0xd65f03c0])) }
    func test339TrueSSAInputExcluded() throws {
        var function = fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0)
        function.ssaEnabled = true // authored input-mode guard, not an SSA producer proof
        try checkDeclined(function)
    }
    func test339DuplicateProducerIdentityExcluded() throws {
        var function = fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0)
        let producer = try XCTUnwrap(function.instructions.first { $0.source.address == 0x700c })
        function.instructions.insert(producer, at: 3)
        try checkDeclined(function)
    }
    func test339ChangedProducerBytesExcluded() throws {
        var function = fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0)
        let index = try XCTUnwrap(function.instructions.firstIndex { $0.source.address == 0x700c })
        function.instructions[index].source.byteText = "1f 05 89 ea"
        try checkDeclined(function)
    }
    func test339RowBudgetExcluded() throws {
        try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0,
            tail: Array(repeating: 0xd503201f, count: 65) + [0xd65f03c0]))
    }
    func test339BlockBudgetExcluded() throws {
        try checkDeclined(fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0,
            tail: Array(repeating: 0x14000001, count: 17) + [0xd65f03c0]))
    }
    func test339ChangedConsumerOperationExcluded() throws {
        var function = fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0)
        let index = try XCTUnwrap(function.instructions.firstIndex { $0.source.address == 0x7010 })
        guard case let .compareToBool(destination, condition, _, right) = function.instructions[index].operation else {
            return XCTFail("missing authored consumer")
        }
        function.instructions[index].operation = .compareToBool(destination: destination, condition: condition,
            left: .immediate(1), right: right)
        try checkDeclined(function)
    }
    func test339PointerOperandTypeExcluded() throws {
        var function = fixture(producer: 0x6a89051f, consumer: 0x9a9fb7e0)
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7004 })
        guard case let .load(.register(name, version), _) = instruction.operation else {
            return XCTFail("missing Wm load")
        }
        let target = MacIRNameBindingTarget.register(name: name, version: version)
        function.nameBindings.removeAll { $0.target == target }
        function.nameBindings.append(.init(target: target, name: "other_word", type: "uint32_t *", kind: .registerTemporary))
        try checkDeclined(function)
    }

}
