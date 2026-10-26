import Foundation
import XCTest
@testable import MacScope

/// Exercises the production default printer, not the proposed loop-proof API.
/// The oracle below executes emitted names/expressions verbatim. In particular it
/// must never turn x1_1 and an entry argument into one architectural register.
final class EntryLoopCarryTests: XCTestCase {
    // Freeze the authored input and default-off envelope before candidate
    // printing. This is not a registry of current-native scalar corpus fixtures.
    private var sources: [String: LoopTextMachine.Source] = [:]
    private func rows(_ body: [(String, String)], at start: UInt64 = 0x9100,
                      polarity: String = "ne") -> [InstructionRow] {
        let instructions = body + [("subs", "w3, w3, #1"),
                                   ("b.\(polarity)", "0x\(String(start, radix: 16))"), ("ret", "")]
        return instructions.enumerated().map { index, item in
            InstructionRow(address: start + UInt64(index * 4), bytes: "00 00 00 00",
                           mnemonic: item.0, operands: item.1, hasBreakpoint: false,
                           comment: "carry_effect_\(index)")
        }
    }

    private func copyRows(at start: UInt64 = 0x9100, halfword: Bool = false,
                          polarity: String = "ne", returnsPointer: Bool = false) -> [InstructionRow] {
        var body = [("ldr", "w8, [x1], #4"),
                    (halfword ? "strh" : "strb", "w8, [x2], #\(halfword ? 2 : 1)")]
        if returnsPointer { body.append(("mov", "x0, x1")) }
        return rows(body, at: start, polarity: polarity)
    }

    private func document(_ instructions: [InstructionRow], name: String = "_carry_probe",
                          prepareOracle: Bool = true) throws -> PseudocodeDocument {
        let start = try XCTUnwrap(instructions.first?.address)
        let summary = FunctionSummary(id: UUID(), name: name, startAddress: start,
                                      endAddress: start + UInt64(instructions.count * 4), confidence: 1)
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [summary], instructions: instructions,
                                         xrefs: [], hexBytes: Data())
        let input = snapshot.pseudocodeRenderInput(selectedAddress: start, in: .primary)
        let function = MacIRBuilder().buildFunction(name: input.functionName, instructions: input.instructions)
        if prepareOracle {
            var baselineOptions = DecompilerOptions.default
            baselineOptions.structureControlFlow = false
            let baseline = PseudocodePrinter(options: baselineOptions).print(function: function)
            sources[name] = try LoopTextMachine.Source(rows: instructions, function: function, baseline: baseline)
        }
        let printer = PseudocodePrinter(options: .default)
        let result = printer.print(function: function)
        XCTAssertEqual(result.text, DocumentExportService().pseudocodeText(for: input, options: .default))
        return result
    }

    private func seeds(_ document: PseudocodeDocument, count: UInt64,
                       source: UInt64 = 0x4000, destination: UInt64 = 0x6000,
                       context: UInt64 = 0x8000) throws -> [String: LoopTextMachine.Value] {
        let physical = [0: context, 1: source, 2: destination, 3: count]
        var result: [String: LoopTextMachine.Value] = [:]
        // This is only external input binding. The emitted-text machine receives
        // no MacIR, assembly, physical-register map, or loop certificate.
        let sourceContract = try XCTUnwrap(sources[document.functionName])
        for input in sourceContract.inputs {
            let parameter = input.parameter
            guard let bits = physical[input.register],
                  let type = LoopTextMachine.CType.named(parameter.type) else {
                throw LoopTextMachine.Failure.invalid("unsupported fixture input \(parameter)")
            }
            result[parameter.name] = .init(bits, type)
        }
        return result
    }

    private func memory(_ words: [UInt32], source: UInt64 = 0x4000,
                        destination: UInt64 = 0x6000) -> [UInt64: UInt8] {
        var result: [UInt64: UInt8] = [:]
        for offset in 0..<12 { result[destination &+ UInt64(offset)] = 0x55 }
        for (index, word) in words.enumerated() {
            for byte in 0..<4 {
                result[source &+ UInt64(index * 4 + byte)] = UInt8(truncatingIfNeeded: word >> (byte * 8))
            }
        }
        return result
    }

    private func run(_ document: PseudocodeDocument, count: UInt64,
                     memory: [UInt64: UInt8], source: UInt64 = 0x4000,
                     destination: UInt64 = 0x6000, context: UInt64 = 0x8000,
                     latchLimit: Int = 4) throws -> LoopTextMachine.Result {
        let sourceContract = try XCTUnwrap(sources[document.functionName])
        let program = try LoopTextMachine.Program(document: document, source: sourceContract)
        do {
            return try LoopTextMachine(program: program,
                                        inputs: seeds(document, count: count, source: source,
                                                      destination: destination, context: context),
                                        memory: memory).run(latchLimit: latchLimit)
        } catch LoopTextMachine.Failure.undefined(let detail) {
            // Undefined emitted arithmetic is a production-behavior assertion,
            // not an unexpected test-harness exception. Keep the strict check.
            return try XCTUnwrap(nil as LoopTextMachine.Result?,
                                 "emitted arithmetic is undefined: \(detail)\n\(document.text)")
        }
    }

    private func assertRepair(_ document: PseudocodeDocument, rows: [InstructionRow],
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let sourceContract = try XCTUnwrap(sources[document.functionName])
        let legacy = sourceContract.baseline
        func gotos(_ text: String) -> Int { text.components(separatedBy: "goto ").count - 1 }
        XCTAssertGreaterThan(gotos(legacy.text), 0, legacy.text, file: file, line: line)
        XCTAssertEqual(gotos(document.text), 0, document.text, file: file, line: line)
        XCTAssertFalse(document.text.contains("__branch("), document.text, file: file, line: line)
        XCTAssertEqual(sourceContract.rows, rows, "the original input must stay frozen", file: file, line: line)
        // Parsing and binding prove complete ordered source effects/definition
        // slots, both original latch routes, and the storage lifetime relation.
        // No declaration count, printed carrier name or comment count is proof.
        let program = try LoopTextMachine.Program(document: document, source: sourceContract)
        XCTAssertEqual(program.binding.routes.count, 2, file: file, line: line)
        XCTAssertEqual(Set(program.binding.routes.map(\.backedge)), [false, true], file: file, line: line)
        let returned = try XCTUnwrap(rows.last?.address)
        XCTAssertEqual(document.lines(sourcedAt: returned).map(\.text),
                       legacy.lines(sourcedAt: returned).map(\.text),
                       "the terminal return contract is not repaired by this family", file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverSharedTails)
        XCTAssertFalse(DecompilerOptions.default.recoverLoopExits)
        XCTAssertFalse(DecompilerOptions.default.recoverGuardRegions)
    }

    func testDefaultEntryLoopCopiesOneTwoAndThreeElementsAtActualWidths() throws {
        let words: [UInt32] = [0xa1b2c3d4, 0x0102037e, 0xfedcba09]
        for (start, halfword) in [(UInt64(0x9100), false), (0x9700, true), (0xa300, true)] {
            let input = copyRows(at: start, halfword: halfword)
            let actual = try document(input, name: "_transfer_\(start)")
            for count in 1...3 {
                let result = try run(actual, count: UInt64(count), memory: memory(words))
                let stride = halfword ? 2 : 1
                var expected: [LoopTextMachine.Event] = []
                for index in 0..<count {
                    expected.append(.init(kind: .load, address: 0x4000 + UInt64(index * 4),
                                          bytes: 4, value: UInt64(words[index])))
                    expected.append(.init(kind: .store, address: 0x6000 + UInt64(index * stride),
                                          bytes: stride, value: UInt64(words[index]) & (halfword ? 0xffff : 0xff)))
                }
                XCTAssertEqual(result.events, expected, actual.text)
                XCTAssertTrue(result.returned, "count \(count) must terminate\n\(actual.text)")
                XCTAssertEqual(result.decisions, Array(repeating: true, count: count - 1) + [false])
                XCTAssertEqual(result.memory[0x6000 + UInt64(count * stride)], 0x55)
            }
            try assertRepair(actual, rows: input)
        }
    }

    func testDefaultEntryLoopPreservesZeroCountAndUnsignedBoundaryTransitions() throws {
        let input = copyRows()
        let actual = try document(input)
        let subtractionAddress = input[input.count - 3].address
        for (initial, first, second): (UInt64, UInt64, UInt64) in [
            (0, 0xffff_ffff, 0xffff_fffe),
            (0x8000_0000, 0x7fff_ffff, 0x7fff_fffe),
            (0xffff_ffff, 0xffff_fffe, 0xffff_fffd)
        ] {
            let result = try run(actual, count: initial, memory: memory([0x11, 0x22]), latchLimit: 2)
            XCTAssertFalse(result.returned, "input zero is not a zero-trip loop")
            XCTAssertTrue(result.stoppedAtBackedge)
            XCTAssertEqual(result.decisions, [true, true])
            XCTAssertEqual(result.values(at: subtractionAddress, slot: 0).map(\.bits), [first, second], actual.text)
            XCTAssertEqual(result.events.filter { $0.kind == .load }.map(\.address), [0x4000, 0x4004])
            XCTAssertEqual(result.events.filter { $0.kind == .store }.map(\.address), [0x6000, 0x6001])
        }
        // These address vectors do not overlap source with destination. Both
        // modulo-64 wrap and crossing signed INT64_MAX must remain defined.
        for source in [UInt64.max - 3, UInt64(0x7fff_ffff_ffff_fffc)] {
            let result = try run(actual, count: 2,
                                 memory: memory([0x11, 0x22], source: source), source: source)
            XCTAssertTrue(result.returned)
            XCTAssertEqual(result.events.filter { $0.kind == .load }.map(\.address), [source, source &+ 4])
        }
        let destination = UInt64.max
        let destinationWrap = try run(actual, count: 2,
                                      memory: memory([0x11, 0x22], destination: destination),
                                      destination: destination)
        XCTAssertTrue(destinationWrap.returned)
        XCTAssertEqual(destinationWrap.events.filter { $0.kind == .store }.map(\.address), [destination, 0])
        XCTAssertEqual(destinationWrap.memory[destination], 0x11)
        XCTAssertEqual(destinationWrap.memory[0], 0x22)
        try assertRepair(actual, rows: input)
    }

    func testDefaultEntryLoopUsesSUBSResultForEQAndNEWithoutInvertingTheLatch() throws {
        for polarity in ["ne", "eq"] {
            let input = copyRows(at: polarity == "ne" ? 0xb100 : 0xb700, polarity: polarity)
            let actual = try document(input, name: "_polarity_\(polarity)")
            let cases: [(UInt64, Int)] = polarity == "ne" ? [(1, 1), (2, 2), (3, 3)] : [(0, 1), (1, 2), (2, 1)]
            for (count, trips) in cases {
                let result = try run(actual, count: count, memory: memory([0x31, 0x42, 0x53]))
                XCTAssertTrue(result.returned, actual.text)
                XCTAssertEqual(result.decisions, Array(repeating: true, count: trips - 1) + [false])
                XCTAssertEqual(result.events.filter { $0.kind == .load }.map(\.address),
                               (0..<trips).map { 0x4000 + UInt64($0 * 4) })
                XCTAssertEqual(result.events.filter { $0.kind == .store }.map(\.value),
                               Array([UInt64(0x31), 0x42, 0x53].prefix(trips)))
            }
            try assertRepair(actual, rows: input)
        }
    }

    func testDefaultEntryLoopReloadsShiftMemoryAndPreservesOverlappingAccessOrder() throws {
        for downscale in [true, false] {
            let offset = downscale ? 0x1d8 : 0x220
            let body: [(String, String)] = [
                (downscale ? "ldrb" : "ldr", "w8, [x1], #\(downscale ? 1 : 4)"),
                ("ldr", "w9, [x0, #0x\(String(offset, radix: 16))]"),
                (downscale ? "lsr" : "lsl", "w8, w8, w9"),
                ("strb", "w8, [x2], #1")
            ]
            let input = rows(body, at: downscale ? 0xc100 : 0xc700)
            let actual = try document(input, name: downscale ? "_right_scale" : "_left_scale")
            var bytes = memory(downscale ? [0x0000_1008] : [2, 3])
            for index in 0..<4 { bytes[0x6000 + UInt64(index)] = index == 0 ? 1 : 0 }
            let result = try run(actual, count: 2, memory: bytes, context: 0x6000 - UInt64(offset))
            XCTAssertTrue(result.returned)
            XCTAssertEqual(result.events.map(\.kind), [.load, .load, .store, .load, .load, .store])
            XCTAssertEqual(result.events.filter { $0.kind == .store }.map(\.value), downscale ? [4, 1] : [4, 48])
            XCTAssertEqual(result.events.filter { $0.kind == .load && $0.address == 0x6000 }.map(\.value), [1, 4])
            XCTAssertEqual(result.returnMarker, "unresolved_return_contract")
            // 33 is masked to one, not an out-of-range C shift.
            var maskedMemory = memory(downscale ? [0x80] : [0x8000_0003])
            for byte in 0..<4 { maskedMemory[0x8000 + UInt64(offset + byte)] = byte == 0 ? 33 : 0 }
            let masked = try run(actual, count: 1, memory: maskedMemory)
            XCTAssertEqual(masked.events.filter { $0.kind == .store }.map(\.value), downscale ? [64] : [6])
            try assertRepair(actual, rows: input)
        }
        let input = copyRows(at: 0xcd00)
        let actual = try document(input, name: "_overlapping_copy")
        let result = try run(actual, count: 2,
                             memory: memory([0x0000_00d4, 0x0000_007e], destination: 0x4004),
                             destination: 0x4004)
        XCTAssertTrue(result.returned)
        XCTAssertEqual(result.events.filter { $0.kind == .load }.map(\.value), [0xd4, 0xd4])
        XCTAssertEqual(result.events.filter { $0.kind == .store }.map(\.address), [0x4004, 0x4005])
        try assertRepair(actual, rows: input)
    }

    func testDefaultEntryLoopCarriesFinalBodyValueThroughStoresAndCopiesTheLastDefinition() throws {
        let input = copyRows(at: 0xd100, returnsPointer: true)
        let actual = try document(input, name: "_final_pointer")
        let result = try run(actual, count: 2, memory: memory([0x11, 0x22]))
        XCTAssertTrue(result.returned)
        XCTAssertEqual(result.returnMarker, "unresolved_return_contract")
        XCTAssertNil(result.returnValue)
        XCTAssertEqual(result.values(at: input[2].address, slot: 0).map(\.bits), [0x4004, 0x4008],
                       "the body must copy each iteration's final pointer definition into x0")
        XCTAssertEqual(result.events.filter { $0.kind == .load }.map(\.address), [0x4000, 0x4004])
        try assertRepair(actual, rows: input)

        // Source writeback is followed by another write to that same carrier.
        // The second load must use the final +8 base, not the first +4 base.
        let multiple = rows([("ldr", "w8, [x1], #4"), ("add", "x1, x1, #4"),
                             ("strb", "w8, [x2], #1"), ("mov", "x0, x1")], at: 0xd700)
        let advanced = try document(multiple, name: "_last_definition")
        let last = try run(advanced, count: 2, memory: memory([0x11, 0x22, 0x33]))
        XCTAssertTrue(last.returned)
        XCTAssertEqual(last.events.filter { $0.kind == .load }.map(\.address), [0x4000, 0x4008])
        XCTAssertEqual(last.events.filter { $0.kind == .store }.map(\.value), [0x11, 0x33])
        XCTAssertEqual(last.returnMarker, "unresolved_return_contract")
        XCTAssertNil(last.returnValue)
        XCTAssertEqual(last.values(at: multiple[3].address, slot: 0).map(\.bits), [0x4008, 0x4010])
        try assertRepair(advanced, rows: multiple)
    }

    func testDefaultEntryLoopDeclinesMismatchedOperandsAndUnsupportedReturnShapes() throws {
        let validRows = copyRows(at: 0xe100)
        let positive = try document(validRows, name: "_proof_boundary")
        try assertOracleBoundaries(template: positive)
        let result = try run(positive, count: 2, memory: memory([0x11, 0x22]))
        XCTAssertTrue(result.returned)
        XCTAssertEqual(result.events.filter { $0.kind == .load }.map(\.address), [0x4000, 0x4004])
        try assertRepair(positive, rows: validRows)

        func assertDeclines(_ function: MacIRFunction, _ label: String) {
            var options = DecompilerOptions.default
            options.structureControlFlow = false
            let legacy = PseudocodePrinter(options: options).print(function: function)
            let actual = PseudocodePrinter(options: .default).print(function: function)
            XCTAssertTrue(legacy.lines.contains { $0.tokens.contains { $0.text == "goto" } }, "fixture must retain a raw-loop control: \(label)")
            XCTAssertEqual(actual.text, legacy.text, "unproved case must keep its old fallback: \(label)")
            XCTAssertFalse(actual.text.contains("do {"), label)
        }
        let original = MacIRBuilder().buildFunction(name: "_operand_mismatch", instructions: validRows)
        for name in ["return", "uint32_t", "uint64_t", "not an identifier", "valid\n", "valid\r\n", "return\n"] {
            var invalidName = original
            invalidName.parameters.append(try XCTUnwrap(MacIRFunctionParameter(
                id: .recovered(.gpr(5)), bindingID: .gpr(5), sourcePosition: nil,
                abiLocation: .gpr(index: 5, carrierWidth: 32), type: "int32_t", name: name,
                evidence: .authoritativeUser)))
            assertDeclines(invalidName, "unused formal has an invalid or reserved identifier: \(name)")
        }
        // Even an unused formal owns its printed name and type. A recovered
        // body temporary must not capture that storage during loop emission.
        if case let .loadWriteback(destination, _, _, _, _) = original.instructions[0].operation {
            var collision = original
            let name = PseudocodePrinter(options: .default).valueText(
                for: destination, names: PseudocodeNameContext(function: original))
            collision.parameters.append(try XCTUnwrap(MacIRFunctionParameter(
                id: .recovered(.gpr(5)), bindingID: .gpr(5), sourcePosition: nil,
                abiLocation: .gpr(index: 5, carrierWidth: 32), type: "int8_t", name: name,
                evidence: .authoritativeUser)))
            assertDeclines(collision, "body temporary captures an unused narrow formal")
        } else { XCTFail("fixture load changed unexpectedly") }
        for mutation in 0..<3 {
            var changed = original
            if mutation == 0, case let .binary(destination, _, left, _) = changed.instructions[2].operation {
                changed.instructions[2].operation = .binary(destination: destination, op: "-", left: left, right: .immediate(2))
            } else if mutation == 1, case let .loadWriteback(destination, baseDestination, baseSource, _, preIndex) = changed.instructions[0].operation {
                changed.instructions[0].operation = .loadWriteback(destination: destination, baseDestination: baseDestination,
                                                                  baseSource: baseSource, delta: 8, preIndex: preIndex)
            } else if mutation == 2, case let .storeWriteback(_, baseDestination, baseSource, delta, preIndex) = changed.instructions[1].operation {
                changed.instructions[1].operation = .storeWriteback(source: .immediate(0x77), baseDestination: baseDestination,
                                                                   baseSource: baseSource, delta: delta, preIndex: preIndex)
            } else { XCTFail("fixture operation changed unexpectedly"); continue }
            assertDeclines(changed, "source/typed disagreement \(mutation)")
        }
        var explicitReturn = validRows
        explicitReturn[explicitReturn.count - 1].operands = "x1"
        assertDeclines(MacIRBuilder().buildFunction(name: "_explicit_target", instructions: explicitReturn), "explicit RET target")
        let mixed = rows([("ldr", "w8, [x1], #4"), ("mov", "w9, w1"),
                          ("strb", "w8, [x2], #1")], at: 0xe700)
        assertDeclines(MacIRBuilder().buildFunction(name: "_mixed_view", instructions: mixed), "mixed W/X body view")
        let nonReturnSuffix = validRows.dropLast() + [
            InstructionRow(address: 0xe110, bytes: "00 00 00 00", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0xe114, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        assertDeclines(MacIRBuilder().buildFunction(name: "_suffix_use", instructions: Array(nonReturnSuffix)), "non-RET suffix")
        let linkWrite = rows([("ldr", "w8, [x1], #4"), ("strb", "w8, [x2], #1"),
                              ("mov", "x30, x1")], at: 0xeb00)
        assertDeclines(MacIRBuilder().buildFunction(name: "_link_write", instructions: linkWrite), "implicit RET link-register write")
        let overlap = rows([("ldr", "w1, [x1], #4"), ("strb", "w1, [x2], #1")], at: 0xef00)
        assertDeclines(MacIRBuilder().buildFunction(name: "_base_overlap", instructions: overlap), "data/writeback-base physical overlap")
        for access in [MacIRMemoryAccess(byteWidth: 8), MacIRMemoryAccess(byteWidth: 4, extensionKind: .sign)] {
            var changed = original
            changed.instructions[0].memoryAccess = access
            assertDeclines(changed, "source/typed memory access disagreement: \(access)")
        }
        let shiftRows = rows([("ldrb", "w8, [x1], #1"), ("ldr", "w9, [x0, #0x1d8]"),
                              ("lsr", "w8, w8, w9"), ("strb", "w8, [x2], #1")], at: 0xf300)
        var badMask = MacIRBuilder().buildFunction(name: "_wrong_shift_mask", instructions: shiftRows)
        if case let .binary(destination, op, left, .binaryExpression(maskOp, amount, _)) = badMask.instructions[2].operation {
            badMask.instructions[2].operation = .binary(destination: destination, op: op, left: left,
                right: .binaryExpression(op: maskOp, left: amount, right: .immediate(63)))
            assertDeclines(badMask, "32-bit register shift with a 64-bit mask")
        } else { XCTFail("fixture register shift did not have the expected masked operand") }
    }

    func testDefaultEntryLoopExecutesDecodedRecurrencesWithCanonicalUnavailableSidecars() throws {
        // Exact recorded instruction bytes, relocated without rewriting operands
        // or dropping sidecars. Names and bases are deliberately unrelated to the
        // original symbols; the two identical halfword records stay independent.
        let fixtures: [(bytes: String, sourceWidth: Int, destinationWidth: Int,
                        shift: Int, shiftOffset: UInt64?)] = [
            ("28 14 40 38 09 d8 41 b9 08 25 c9 1a 48 14 00 38 63 04 00 71 61 ff ff 54 c0 03 5f d6", 1, 1, -1, 0x1d8),
            ("28 44 40 b8 09 20 42 b9 08 21 c9 1a 48 14 00 38 63 04 00 71 61 ff ff 54 c0 03 5f d6", 4, 1, 1, 0x220),
            ("28 44 40 b8 48 14 00 38 63 04 00 71 a1 ff ff 54 c0 03 5f d6", 4, 1, 0, nil),
            ("28 44 40 b8 48 24 00 78 63 04 00 71 a1 ff ff 54 c0 03 5f d6", 4, 2, 0, nil),
            ("28 44 40 b8 48 24 00 78 63 04 00 71 a1 ff ff 54 c0 03 5f d6", 4, 2, 0, nil)
        ]
        let words: [UInt32] = [0xa1b2c3d4, 0x0102037e, 0xfedcba09]
        let source: UInt64 = 0x1_0000_4000, destination: UInt64 = 0x2_0000_6000
        let context: UInt64 = 0x3_0000_8000
        for (fixtureIndex, fixture) in fixtures.enumerated() {
            let bytes = try fixture.bytes.split(separator: " ").map { try XCTUnwrap(UInt8($0, radix: 16)) }
            let start = UInt64(0x11100 + fixtureIndex * 0x400)
            let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: start)
            XCTAssertEqual(decoded.count * 4, bytes.count)
            XCTAssertEqual(decoded[decoded.count - 2].branchTarget, start)
            var input = decoded.map { InstructionRow(decoded: $0) }
            for index in input.indices {
                let sidecar = try XCTUnwrap(input[index].structuredOperands)
                if index == input.count - 1 || (fixture.shift != 0 && index == 2) {
                    XCTAssertEqual(sidecar, .unavailable(mnemonic: input[index].mnemonic,
                                                         operands: input[index].operands))
                } else {
                    XCTAssertEqual(sidecar.coverage, .complete)
                }
                input[index].comment = "decoded_effect_\(fixtureIndex)_\(index)"
            }
            let actual = try document(input, name: "_decoded_transfer_\(fixtureIndex)")
            for count in [1, 3] {
                var bytes = memory(words, source: source, destination: destination)
                if let offset = fixture.shiftOffset {
                    for byte in 0..<4 { bytes[context + offset + UInt64(byte)] = byte == 0 ? 33 : 0 }
                }
                let result = try run(actual, count: UInt64(count), memory: bytes,
                                     source: source, destination: destination, context: context)
                var expected: [LoopTextMachine.Event] = []
                for index in 0..<count {
                    let loaded = fixture.sourceWidth == 1
                        ? UInt64((words[0] >> (index * 8)) & 0xff) : UInt64(words[index])
                    expected.append(.init(kind: .load, address: source + UInt64(index * fixture.sourceWidth),
                                          bytes: fixture.sourceWidth, value: loaded))
                    if let offset = fixture.shiftOffset {
                        expected.append(.init(kind: .load, address: context + offset, bytes: 4, value: 33))
                    }
                    let scaled = fixture.shift < 0 ? loaded >> 1 : (fixture.shift > 0 ? (loaded << 1) & 0xffff_ffff : loaded)
                    expected.append(.init(kind: .store, address: destination + UInt64(index * fixture.destinationWidth),
                                          bytes: fixture.destinationWidth,
                                          value: scaled & (fixture.destinationWidth == 1 ? 0xff : 0xffff)))
                }
                XCTAssertEqual(result.events, expected, actual.text)
                XCTAssertTrue(result.returned, actual.text)
                XCTAssertEqual(result.returnMarker, "unresolved_return_contract")
                XCTAssertNil(result.returnValue)
                XCTAssertEqual(result.decisions, Array(repeating: true, count: count - 1) + [false])
                XCTAssertEqual(result.memory[destination + UInt64(count * fixture.destinationWidth)], 0x55)
            }
            var zeroMemory = memory(words, source: source, destination: destination)
            if let offset = fixture.shiftOffset {
                for byte in 0..<4 { zeroMemory[context + offset + UInt64(byte)] = byte == 0 ? 33 : 0 }
            }
            let zero = try run(actual, count: 0, memory: zeroMemory, source: source,
                               destination: destination, context: context, latchLimit: 2)
            XCTAssertFalse(zero.returned, "decoded input zero is not a zero-trip loop")
            XCTAssertTrue(zero.stoppedAtBackedge)
            XCTAssertEqual(zero.decisions, [true, true])
            XCTAssertEqual(zero.values(at: input[input.count - 3].address, slot: 0).map(\.bits),
                           [0xffff_ffff, 0xffff_fffe], actual.text)
            XCTAssertEqual(zero.events.filter { $0.kind == .load && $0.address >= source && $0.address < source + 12 }.map(\.address),
                           [source, source + UInt64(fixture.sourceWidth)])
            XCTAssertEqual(zero.events.filter { $0.kind == .store }.map(\.address),
                           [destination, destination + UInt64(fixture.destinationWidth)])
            if let offset = fixture.shiftOffset {
                // The first destination byte aliases the shift word. Iteration
                // two must reload four, rather than reuse the initial shift one.
                var bytes = memory(fixture.shift < 0 ? [0x0000_1008] : [2, 3])
                for byte in 0..<4 { bytes[0x6000 + UInt64(byte)] = byte == 0 ? 1 : 0 }
                let result = try run(actual, count: 2, memory: bytes, context: 0x6000 - offset)
                let secondSource: UInt64 = fixture.shift < 0 ? 16 : 3
                let secondStore: UInt64 = fixture.shift < 0 ? 1 : 48
                XCTAssertEqual(result.events, [
                    .init(kind: .load, address: 0x4000, bytes: fixture.sourceWidth, value: fixture.shift < 0 ? 8 : 2),
                    .init(kind: .load, address: 0x6000, bytes: 4, value: 1),
                    .init(kind: .store, address: 0x6000, bytes: 1, value: 4),
                    .init(kind: .load, address: 0x4000 + UInt64(fixture.sourceWidth), bytes: fixture.sourceWidth, value: secondSource),
                    .init(kind: .load, address: 0x6000, bytes: 4, value: 4),
                    .init(kind: .store, address: 0x6001, bytes: 1, value: secondStore)
                ], actual.text)
                XCTAssertTrue(result.returned)
                XCTAssertEqual(result.decisions, [true, false])
            }
            try assertRepair(actual, rows: input)
        }
    }

    func testDefaultEntryLoopRejectsContradictoryAndUnsupportedOperandSidecars() throws {
        // Clone the complete recorded byte-copy stream, retaining every decoder
        // envelope, including the canonical unavailable RET. The control must
        // repair before a one-envelope mutation can establish a rejection.
        let bytes: [UInt8] = [
            0x28, 0x44, 0x40, 0xb8, 0x48, 0x14, 0x00, 0x38,
            0x63, 0x04, 0x00, 0x71, 0xa1, 0xff, 0xff, 0x54,
            0xc0, 0x03, 0x5f, 0xd6
        ]
        var baseline = ARM64Decoder().decode(Data(bytes), baseAddress: 0x13100).map { InstructionRow(decoded: $0) }
        XCTAssertEqual(baseline.count, 5)
        for index in baseline.indices {
            XCTAssertNotNil(baseline[index].structuredOperands)
            baseline[index].comment = "sidecar_effect_\(index)"
        }
        let control = try document(baseline, name: "_canonical_sidecar_control")
        try assertRepair(control, rows: baseline)
        let result = try run(control, count: 2, memory: memory([0x11, 0x22]))
        XCTAssertTrue(result.returned)
        XCTAssertEqual(result.events.filter { $0.kind == .load }.map(\.address), [0x4000, 0x4004])
        XCTAssertEqual(result.events.filter { $0.kind == .store }.map(\.value), [0x11, 0x22])
        let load = try XCTUnwrap(baseline[0].structuredOperands)
        let subtraction = try XCTUnwrap(baseline[2].structuredOperands)
        let returned = try XCTUnwrap(baseline[4].structuredOperands)
        func envelope(_ original: InstructionOperands, coverage: InstructionOperands.Coverage? = nil,
                      opcode: String? = nil, operands: [InstructionOperands.Operand]? = nil,
                      presentation: InstructionOperands.Presentation? = nil,
                      semantics: InstructionOperands.Semantics? = nil,
                      legacyText: InstructionOperands.LegacyText? = nil) -> InstructionOperands {
            .init(architecture: original.architecture, schemaVersion: original.schemaVersion,
                  coverage: coverage ?? original.coverage, opcodeClass: opcode ?? original.opcodeClass,
                  operands: operands ?? original.operands, presentation: presentation ?? original.presentation,
                  semantics: semantics ?? original.semantics, legacyText: legacyText ?? original.legacyText)
        }
        var mismatchedLoad = load.operands
        mismatchedLoad[0] = .register(.init(index: 9, width: 32))
        let cases: [(label: String, index: Int, sidecar: InstructionOperands, sameText: Bool)] = [
            ("complete mismatched operand", 0, envelope(load, operands: mismatchedLoad), false),
            ("partial coverage", 0, envelope(load, coverage: .partial), true),
            ("unavailable contradictory legacy text", 4,
             envelope(returned, legacyText: .init(mnemonic: "ret", operands: "x1")), false),
            ("unavailable hidden semantics", 4,
             envelope(returned, semantics: .init(memoryAccessWidth: 64, memoryAccess: .write)), true),
            ("complete wrong memory width", 0,
             envelope(load, semantics: .init(memoryAccessWidth: 64, memoryAccess: .read)), true),
            ("complete wrong memory direction", 0,
             envelope(load, semantics: .init(memoryAccessWidth: 32, memoryAccess: .write)), true),
            ("complete hidden operand", 2,
             envelope(subtraction, operands: subtraction.operands + [.register(.init(index: 9, width: 64))],
                      presentation: .init(mnemonic: "subs", omittedOperandIndices: [3])), true),
            ("complete masked opcode contradiction", 2, envelope(subtraction, opcode: "add"), true)
        ]
        for item in cases {
            var input = baseline
            input[item.index].structuredOperands = item.sidecar
            let rendered = try XCTUnwrap(ARM64OperandRenderer.render(item.sidecar,
                legacyMnemonic: input[item.index].mnemonic, legacyOperands: input[item.index].operands))
            XCTAssertEqual(rendered.mnemonic == input[item.index].mnemonic && rendered.operands == input[item.index].operands,
                           item.sameText, item.label)
            let actual = try document(input, name: "_sidecar_rejection", prepareOracle: false)
            let function = MacIRBuilder().buildFunction(name: actual.functionName, instructions: input)
            var options = DecompilerOptions.default
            options.structureControlFlow = false
            let legacy = PseudocodePrinter(options: options).print(function: function)
            XCTAssertTrue(legacy.lines.contains { $0.tokens.contains { $0.text == "goto" } }, item.label)
            XCTAssertEqual(actual.text, legacy.text, "sidecar rejection must preserve byte-identical fallback: \(item.label)")
            XCTAssertFalse(actual.text.contains("do {"), item.label)
        }
    }

    /// Keep literal/undefinedness refusals and capture controls within the
    /// existing selector. These are adapter checks, not production PASS claims.
    private func assertOracleBoundaries(template: PseudocodeDocument) throws {
        for (literal, expected): (String, LoopTextMachine.CType) in [
            ("0xffffffff", .u32), ("0x100000000", .i64),
            ("0x8000000000000000", .u64), ("4294967295", .i64)
        ] {
            XCTAssertEqual(try LoopTextMachine.literal(literal).type, expected, literal)
        }
        XCTAssertThrowsError(try LoopTextMachine.literal("0x7fffffffffffffff + 1")) { error in
            guard case LoopTextMachine.Failure.undefined = error else {
                return XCTFail("signed64 overflow must be undefined, not unsigned wrap: \(error)")
            }
        }
        XCTAssertThrowsError(try LoopTextMachine.literal("9223372036854775808")) { error in
            guard case LoopTextMachine.Failure.invalid = error else {
                return XCTFail("unsupported decimal overflow must be rejected: \(error)")
            }
        }
        let parameter = try XCTUnwrap(template.parameters.first)
        let local = MacIRLocalVariable(offset: 16, name: "oracle_local", type: "uint64_t", byteWidth: 8)
        for name in [parameter.name, local.name] {
            XCTAssertThrowsError(try LoopTextMachine.storage(name, parameter: parameter, local: local), name)
        }
        XCTAssertEqual(try LoopTextMachine.storage("oracle_fresh", parameter: parameter, local: local).bits, 1,
                       "an unsourced copy to fresh storage is legal")

        let original = try XCTUnwrap(sources[template.functionName])
        let bound = try LoopTextMachine.Program(document: template, source: original)
        let count = try XCTUnwrap(bound.binding.slots.first { $0.row == original.rows.count - 3 && $0.ordinal == 0 })
        func renamed(_ document: PseudocodeDocument, _ old: String, _ new: String) -> PseudocodeDocument {
            var copy = document
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: old) + #"\b"#
            for index in copy.lines.indices {
                copy.lines[index].text = copy.lines[index].text.replacingOccurrences(of: pattern, with: new, options: .regularExpression)
            }
            return copy
        }
        // A declared count cell and the same final source definition may share
        // one name only because every read/write phase has the same owner.
        let coalesced = renamed(template, count.name, "oracle_body")
        let sameDefinition = try LoopTextMachine.Program(document: coalesced, source: original)
        XCTAssertTrue(sameDefinition.candidate.symbols["oracle_body"]?.declared == true)
        let copied = try run(coalesced, count: 2, memory: memory([0x11, 0x22]))
        XCTAssertTrue(copied.returned)
        XCTAssertEqual(copied.events.filter { $0.kind == .load }.map(\.address), [0x4000, 0x4004])
        XCTAssertEqual(copied.decisions, [true, false])

        // The conflicting-owner negative is same-width, not merely a duplicate
        // declaration or a count/pointer type error. Removing one initializer
        // cannot grant the destination pointer the source pointer's lifetime.
        let source = try XCTUnwrap(bound.binding.slots.first { $0.row == 0 && $0.ordinal == 1 })
        let destination = try XCTUnwrap(bound.binding.slots.first { $0.row == 1 && $0.ordinal == 0 })
        var conflict = template
        let lineCount = conflict.lines.count
        conflict.lines.removeAll { line in
            line.kind == .declaration && (try? OrdinaryC.lex(line.text).map(\.text).dropFirst().first) == destination.name
        }
        XCTAssertEqual(lineCount - conflict.lines.count, 1, "remove exactly the conflicting carrier initializer")
        conflict = renamed(conflict, destination.name, source.name)
        // Require the ordinary parser to accept the same-width scalar program
        // first: a parser/type/duplicate-declaration error is not this control.
        let parsedConflict = try NativeScalarNoCallContract.program(lines: OrdinaryC.lines(conflict), manifest: original.manifest)
        XCTAssertEqual(parsedConflict.symbols[source.name]?.type, .u64)
        XCTAssertNil(parsedConflict.symbols[destination.name])
        XCTAssertThrowsError(try LoopTextMachine.Program(document: conflict, source: original),
                             "different live pointer owners cannot be coalesced") { error in
            guard case let OrdinaryC.Failure.invalidContract(reason) = error,
                  reason == "store is missing, reordered, wrong-width or has conflicting source owners" else {
                return XCTFail("the same-width conflict must fail source ownership, not parsing: \(error)")
            }
        }
    }
}

/// Candidate adapter for the original authored/relocated entry tests. Source
/// ownership is an independent, deliberately bounded literal grammar; candidate
/// numbers come only from the shared ordinary-C parser/evaluator. No product
/// plan, original IR arithmetic, source reference value or expected test number
/// is supplied to that evaluator. SOURCE ONLY / NOT RUN after supersession.
private struct LoopTextMachine {
    typealias C = OrdinaryC
    typealias N = NativeScalarNoCallContract
    typealias CType = C.CType
    typealias Value = C.Value
    enum Failure: Error { case invalid(String), undefined(String) }

    struct Input { let parameter: MacIRFunctionParameter; let register: Int }
    enum SourceOperation {
        case load(data: Int, base: Int, offset: UInt64, post: UInt64?, bytes: Int)
        case store(data: Int, base: Int, post: UInt64, bytes: Int)
        case addPointer, moveReturn, shift(String), subtractCount
    }
    struct Source {
        let rows: [InstructionRow]
        let baseline: PseudocodeDocument
        let inputs: [Input]
        let operations: [SourceOperation]
        let manifest: N.FrozenManifest
        let polarity: String
        let numericReturn: Bool

        init(rows: [InstructionRow], function: MacIRFunction, baseline: PseudocodeDocument) throws {
            guard rows.count >= 5, let start = rows.first?.address,
                  rows.last?.mnemonic == "ret", rows.last?.operands == "",
                  rows[rows.count - 3].mnemonic == "subs",
                  ["b.eq", "b.ne"].contains(rows[rows.count - 2].mnemonic),
                  Self.immediate(rows[rows.count - 2].operands) == start,
                  function.localVariables.isEmpty, baseline.localVariables.isEmpty,
                  baseline.parameters == function.parameters,
                  let signature = baseline.lines.first(where: { $0.kind == .signature })?.text else {
                throw C.Failure.invalidContract("outside the authored entry-loop source grammar")
            }
            var operations: [SourceOperation] = [], memory: [Int: [C.MemoryEffect]] = [:]
            var written: Set<Int> = [], demand: [Int: Int] = [:]
            func reads(_ register: Int, _ width: Int) throws {
                if !written.contains(register) {
                    guard demand[register] == nil || demand[register] == width else {
                        throw C.Failure.invalidContract("mixed original external widths")
                    }
                    demand[register] = width
                }
            }
            for (index, row) in rows.dropLast(2).enumerated() {
                let operands = row.operands.replacingOccurrences(of: " ", with: "").lowercased()
                let operation: SourceOperation
                switch (row.mnemonic, operands) {
                case ("ldr", "w8,[x1],#4"), ("ldr", "w8,[x1],#0x4"):
                    operation = .load(data: 8, base: 1, offset: 0, post: 4, bytes: 4)
                    try reads(1, 64); written.formUnion([8, 1]); memory[index] = [.init(loading: true, bytes: 4)]
                case ("ldrb", "w8,[x1],#1"), ("ldrb", "w8,[x1],#0x1"):
                    operation = .load(data: 8, base: 1, offset: 0, post: 1, bytes: 1)
                    try reads(1, 64); written.formUnion([8, 1]); memory[index] = [.init(loading: true, bytes: 1)]
                case ("ldr", "w9,[x0,#0x1d8]"), ("ldr", "w9,[x0,#472]"):
                    operation = .load(data: 9, base: 0, offset: 0x1d8, post: nil, bytes: 4)
                    try reads(0, 64); written.insert(9); memory[index] = [.init(loading: true, bytes: 4)]
                case ("ldr", "w9,[x0,#0x220]"), ("ldr", "w9,[x0,#544]"):
                    operation = .load(data: 9, base: 0, offset: 0x220, post: nil, bytes: 4)
                    try reads(0, 64); written.insert(9); memory[index] = [.init(loading: true, bytes: 4)]
                case ("strb", "w8,[x2],#1"), ("strb", "w8,[x2],#0x1"):
                    operation = .store(data: 8, base: 2, post: 1, bytes: 1)
                    try reads(8, 32); try reads(2, 64); written.insert(2); memory[index] = [.init(loading: false, bytes: 1)]
                case ("strh", "w8,[x2],#2"), ("strh", "w8,[x2],#0x2"):
                    operation = .store(data: 8, base: 2, post: 2, bytes: 2)
                    try reads(8, 32); try reads(2, 64); written.insert(2); memory[index] = [.init(loading: false, bytes: 2)]
                case ("add", "x1,x1,#4"), ("add", "x1,x1,#0x4"):
                    operation = .addPointer; try reads(1, 64); written.insert(1)
                case ("mov", "x0,x1"):
                    operation = .moveReturn; try reads(1, 64); written.insert(0)
                case ("lsr", "w8,w8,w9"), ("lsl", "w8,w8,w9"):
                    operation = .shift(row.mnemonic == "lsr" ? ">>" : "<<")
                    try reads(8, 32); try reads(9, 32); written.insert(8)
                case ("subs", "w3,w3,#1"), ("subs", "w3,w3,#0x1"):
                    guard index == rows.count - 3 else { throw C.Failure.invalidContract("early source flag writer") }
                    operation = .subtractCount; try reads(3, 32); written.insert(3)
                default: throw C.Failure.invalidContract("unmodeled authored entry row \(index): \(row.mnemonic) \(row.operands)")
                }
                operations.append(operation)
            }
            var inputs: [Input] = []
            for parameter in function.parameters {
                guard let binding = parameter.bindingID, binding.kind == .gpr,
                      case let .gpr(register, width) = parameter.abiLocation,
                      binding.value == register, demand[register] == width,
                      parameter.richLocation == nil, let type = C.CType.named(parameter.type),
                      type.width == width, C.identifier(parameter.name) else {
                    throw C.Failure.invalidContract("original formal disagrees with literal source entry demand")
                }
                inputs.append(.init(parameter: parameter, register: register))
            }
            guard Set(inputs.map(\.register)) == Set(demand.keys),
                  Set(inputs.map(\.register)).count == inputs.count,
                  Set(inputs.map { $0.parameter.name }).count == inputs.count else {
                throw C.Failure.invalidContract("missing/duplicate original external role")
            }
            let terminalLines = baseline.lines(sourcedAt: rows[rows.count - 1].address)
            guard terminalLines.count == 1 else { throw C.Failure.invalidContract("original terminal is not singular") }
            let payload = String(terminalLines[0].text.drop(while: { $0 == " " || $0 == "\t" }))
            let terminalTokens = try C.lex(payload).map(\.text)
            let terminal: N.Terminal, numeric: Bool
            if terminalTokens == ["return", ";"] { terminal = .void; numeric = false }
            else if terminalTokens == ["return", "unresolved_return_contract", ";"] {
                terminal = .unavailableReturnContract; numeric = false
            } else {
                guard terminalTokens.count == 3, terminalTokens[0] == "return", terminalTokens[2] == ";",
                      C.identifier(terminalTokens[1]), let type = C.CType.named(baseline.returnType),
                      operations.contains(where: { if case .moveReturn = $0 { return true }; return false }) else {
                    throw C.Failure.invalidContract("unmodeled original numeric RET")
                }
                terminal = .value(name: terminalTokens[1], type: type); numeric = true
            }
            let envelope: N.EntryEnvelope
            if let open = signature.range(of: "/* ABI inputs: "),
               let close = signature.range(of: " */", range: open.lowerBound..<signature.endIndex) {
                envelope = .frozenABIInputs(comment: String(signature[open.lowerBound..<close.upperBound]))
            } else { envelope = .declaredFormals }
            let manifest = N.FrozenManifest(signature: signature,
                formals: inputs.map { .init(name: $0.parameter.name, type: C.CType.named($0.parameter.type)!) },
                sourceAddresses: rows.map(\.address), terminalRow: rows.count - 1,
                terminalPayload: payload, terminal: terminal,
                labelAddresses: [start, rows[rows.count - 1].address], memoryEffects: memory, entryEnvelope: envelope)
            _ = try N.contract(manifest)
            self.rows = rows; self.baseline = baseline; self.inputs = inputs; self.operations = operations
            self.manifest = manifest; polarity = rows[rows.count - 2].mnemonic == "b.ne" ? "!=" : "=="
            numericReturn = numeric
        }
        private static func immediate(_ text: String) -> UInt64? {
            let text = text.trimmingCharacters(in: .whitespaces)
            return text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
        }
    }

    enum Owner: Hashable { case entry(Int), definition(Int, Int, Int) }
    indirect enum Term: Hashable {
        case owner(Owner), literal(UInt64), binary(String, Int, Term, Term), load(Int, Int, Term), narrow(Int, Term)
        func relative(to epoch: Int) -> Term {
            switch self {
            case let .owner(.definition(row, slot, occurrence)): return .owner(.definition(row, slot, occurrence - epoch))
            case let .binary(op, width, a, b): return .binary(op, width, a.relative(to: epoch), b.relative(to: epoch))
            case let .load(row, bytes, a): return .load(row, bytes, a.relative(to: epoch))
            case let .narrow(width, a): return .narrow(width, a.relative(to: epoch))
            default: return self
            }
        }
    }
    struct Symbolic: Equatable {
        let term: Term
        let bits: Int // Proven upper bound on significant unsigned source bits.
        func project(_ width: Int) -> Symbolic {
            width >= bits ? self : .init(term: .narrow(width, term), bits: width)
        }
        func relative(to epoch: Int) -> Symbolic { .init(term: term.relative(to: epoch), bits: bits) }
    }
    enum Unit {
        case scalar(row: Int, slot: Int, register: Int, width: Int, result: Symbolic, expression: Term)
        case store(row: Int, bytes: Int, address: Term, data: Term)
        var row: Int {
            switch self { case let .scalar(row, _, _, _, _, _), let .store(row, _, _, _): return row }
        }
    }
    struct Slot: Equatable {
        let row: Int
        let ordinal: Int
        let width: Int
        let knownBits: Int
        let pc: Int
        let span: C.Span
        let name: String
        let storageType: C.CType
    }
    struct Route {
        let pcs: [Int]
        let transfers: [C.Transfer]
        let destination: Int
        let backedge: Bool
    }
    struct Binding {
        let header: Int
        let terminal: Int
        let routes: [Route]
        let slots: [Slot]
    }

    struct Program {
        let candidate: C.Program
        let source: Source
        let binding: Binding
        init(document: PseudocodeDocument, source: Source) throws {
            guard document.functionName == source.baseline.functionName,
                  document.entryAddress == source.baseline.entryAddress,
                  document.returnType == source.baseline.returnType,
                  document.parameters == source.baseline.parameters,
                  document.localVariables == source.baseline.localVariables,
                  document.nameBindings == source.baseline.nameBindings,
                  document.stackFrameSize == source.baseline.stackFrameSize,
                  document.callTargets == source.baseline.callTargets,
                  document.callSignatures == source.baseline.callSignatures else {
                throw C.Failure.invalidContract("candidate changed the original entry envelope")
            }
            for line in document.lines {
                if let span = line.source {
                    guard source.rows.contains(where: { $0.address == span.address }),
                          source.baseline.lines(sourcedAt: span.address).contains(where: { $0.source == span }) else {
                        throw C.Failure.invalidContract("foreign or altered original source span")
                    }
                }
            }
            let candidate = try N.program(lines: C.lines(document), manifest: source.manifest)
            guard Self.loopCount(candidate.root) == 1,
                  !candidate.tokens.contains(where: { $0.text == "goto" }) else {
                throw C.Failure.invalidContract("entry candidate requires one actual structured loop and no raw goto")
            }
            self.candidate = candidate; self.source = source
            binding = try Self.bind(candidate, source: source)
        }
        private static func loopCount(_ statement: C.Statement) -> Int {
            switch statement.node {
            case let .compound(_, body): return body.reduce(0) { $0 + loopCount($1) }
            case let .conditional(_, a, b): return loopCount(a) + (b.map(loopCount) ?? 0)
            case let .whileLoop(_, body), let .doLoop(body, _): return 1 + loopCount(body)
            case let .forLoop(a, _, b, body): return 1 + (a.map(loopCount) ?? 0) + (b.map(loopCount) ?? 0) + loopCount(body)
            case let .label(_, body): return loopCount(body)
            default: return 0
            }
        }
        private static func row(_ instruction: C.Instruction, in program: C.Program) throws -> Int? {
            let span: C.Span
            if case let .branch(e, _, _) = instruction.node { span = e.span } else { span = instruction.span }
            guard program.tokens.indices.contains(span.first) else { throw C.Failure.invalidContract("invalid candidate span") }
            guard let address = program.tokens[span.first].source else { return nil }
            guard let row = program.contract.rowsByAddress[address] else { throw C.Failure.invalidContract("foreign candidate source address") }
            return row
        }
        private static func symbolic(_ expression: C.Expression, in program: C.Program,
                                     values: [String: Symbolic]) throws -> Symbolic {
            switch expression.node {
            case let .name(name):
                guard let value = values[name] else { throw C.Failure.invalidContract("unowned or premature read of \(name)") }
                return value
            case let .literal(value): return .init(term: .literal(value.bits), bits: max(1, 64 - value.bits.leadingZeroBitCount))
            case let .cast(type, e):
                // This ownership subset admits unsigned projections, not a
                // guessed signed-extension/representation equivalence.
                guard type.unsigned, !type.pointer else { throw C.Failure.unsupportedSyntax("entry ownership requires unsigned scalar projections") }
                return try symbolic(e, in: program, values: values).project(type.width)
            case let .binary(op, a, b):
                guard ["+", "-", "&", "<<", ">>", "==", "!="].contains(op),
                      let type = program.expressionTypes[expression.span], !type.pointer,
                      ["==", "!="].contains(op) || type.unsigned else {
                    throw C.Failure.unsupportedSyntax("entry ownership has unmodeled arithmetic/type")
                }
                let left = try symbolic(a, in: program, values: values)
                let right = try symbolic(b, in: program, values: values)
                return .init(term: .binary(op, type.width, left.term, right.term), bits: type.width)
            case let .load(type, address):
                guard type.unsigned, let site = program.memorySites[expression.span], site.effectOrdinal == 0 else {
                    throw C.Failure.invalidContract("unowned or signed entry memory expression")
                }
                return .init(term: .load(site.row, type.width / 8, try symbolic(address, in: program, values: values).term), bits: type.width)
            default: throw C.Failure.unsupportedSyntax("entry ownership rejects helpers, inline updates and unmodeled expressions")
            }
        }
        private static func pureOwner(_ value: Symbolic) -> Bool {
            if case .owner = value.term { return true }; return false
        }
        private static func store(_ value: Symbolic, name: String, program: C.Program,
                                  values: inout [String: Symbolic]) throws {
            guard let symbol = program.symbols[name], !symbol.external, !symbol.type.pointer,
                  symbol.type.unsigned, symbol.type.width >= value.bits else {
                throw C.Failure.invalidContract("storage loses source bits or captures an external owner")
            }
            values[name] = value
        }
        private static func units(_ source: Source, incoming: [Int: Symbolic], epoch: Int) throws -> ([Unit], [Int: Symbolic]) {
            var registers = incoming, units: [Unit] = []
            func read(_ register: Int) throws -> Symbolic {
                guard let value = registers[register] else { throw C.Failure.invalidContract("missing literal source role \(register)") }
                return value
            }
            func scalar(_ row: Int, _ slot: Int, _ register: Int, _ width: Int, _ bits: Int, _ expression: Term) {
                let result = Symbolic(term: .owner(.definition(row, slot, epoch)), bits: bits)
                units.append(.scalar(row: row, slot: slot, register: register, width: width, result: result, expression: expression))
                registers[register] = result
            }
            for (row, operation) in source.operations.enumerated() {
                switch operation {
                case let .load(data, base, offset, post, bytes):
                    let old = try read(base)
                    let address = offset == 0 ? old.term : .binary("+", 64, old.term, .literal(offset))
                    scalar(row, 0, data, 32, bytes * 8, .load(row, bytes, address))
                    if let post { scalar(row, 1, base, 64, 64, .binary("+", 64, old.term, .literal(post))) }
                case let .store(data, base, post, bytes):
                    let address = try read(base).term, value = try read(data).project(bytes * 8).term
                    units.append(.store(row: row, bytes: bytes, address: address, data: value))
                    scalar(row, 0, base, 64, 64, .binary("+", 64, address, .literal(post)))
                case .addPointer:
                    scalar(row, 0, 1, 64, 64, .binary("+", 64, try read(1).term, .literal(4)))
                case .moveReturn: scalar(row, 0, 0, 64, 64, try read(1).term)
                case let .shift(op):
                    scalar(row, 0, 8, 32, 32, .binary(op, 32, try read(8).term,
                        .binary("&", 32, try read(9).term, .literal(31))))
                case .subtractCount:
                    scalar(row, 0, 3, 32, 32, .binary("-", 32, try read(3).term, .literal(1)))
                }
            }
            return (units, registers)
        }
        private static func predicate(_ expression: C.Expression, program: C.Program,
                                      values: [String: Symbolic], counter: Symbolic) throws -> String {
            if case let .unary("!", child) = expression.node {
                return try predicate(child, program: program, values: values, counter: counter) == "==" ? "!=" : "=="
            }
            let value = try symbolic(expression, in: program, values: values)
            guard case let .binary(op, _, a, b) = value.term, ["==", "!="].contains(op),
                  (a == counter.term && b == .literal(0)) || (b == counter.term && a == .literal(0)) else {
                throw C.Failure.invalidContract("latch does not read the exact current SUBS destination against zero")
            }
            return op
        }
        private static func bind(_ program: C.Program, source: Source) throws -> Binding {
            var branches: [Int] = [], terminals: [Int] = [], firstRow: [Int] = []
            for (pc, instruction) in program.code.enumerated() {
                let row = try row(instruction, in: program)
                switch instruction.node {
                case .nop: break
                case .declaration, .assign:
                    if row == 0 { firstRow.append(pc) }
                case .branch:
                    guard row == source.rows.count - 2 else { throw C.Failure.invalidContract("branch lost original latch ownership") }
                    branches.append(pc)
                case .returned, .unavailableReturn:
                    guard row == source.rows.count - 1 else { throw C.Failure.invalidContract("terminal lost original RET ownership") }
                    terminals.append(pc)
                case .jump: break
                case .call, .unresolved, .update:
                    throw C.Failure.unsupportedSyntax("entry adapter rejects calls, unresolved control and inline update syntax")
                }
            }
            guard branches.count == 1, terminals.count == 1, let branch = branches.first,
                  let terminal = terminals.first, let header = firstRow.min() else {
                throw C.Failure.invalidContract("entry control/source header is not singular")
            }
            var routes: [Route] = []
            var work: [(Int, [Int], [C.Transfer], Set<Int>)] = [(header, [], [], [])]
            while let (pc, path, transfers, seen) = work.popLast() {
                if !path.isEmpty && (pc == header || pc == terminal) {
                    guard path.filter({ $0 == branch }).count == 1 else { throw C.Failure.invalidContract("route omits/repeats original latch") }
                    routes.append(.init(pcs: path, transfers: transfers, destination: pc, backedge: pc == header)); continue
                }
                guard program.code.indices.contains(pc), !seen.contains(pc) else { throw C.Failure.invalidContract("cycle outside original taken edge") }
                let instruction = program.code[pc], nextPath = path + [pc], nextSeen = seen.union([pc])
                switch instruction.node {
                case let .branch(e, yes, no):
                    guard pc == branch else { throw C.Failure.invalidContract("invented entry branch") }
                    for (taken, target) in [(true, yes), (false, no)] {
                        work.append((target, nextPath, transfers + [.init(span: e.span, sourceRow: source.rows.count - 2, taken: taken, destination: target)], nextSeen))
                    }
                case let .jump(target):
                    work.append((target, nextPath, transfers + [.init(span: instruction.span, sourceRow: try row(instruction, in: program), taken: nil, destination: target)], nextSeen))
                case .returned, .unavailableReturn, .call, .unresolved:
                    throw C.Failure.invalidContract("premature terminal/control on original loop route")
                default: work.append((pc + 1, nextPath, transfers, nextSeen))
                }
            }
            guard routes.count == 2, Set(routes.map(\.backedge)) == [false, true],
                  let backedge = routes.first(where: \.backedge), let exit = routes.first(where: { !$0.backedge }) else {
                throw C.Failure.invalidContract("original taken/fallthrough edges lack unique actual routes")
            }
            var values: [String: Symbolic] = [:], registers: [Int: Symbolic] = [:]
            for input in source.inputs {
                let value = Symbolic(term: .owner(.entry(input.register)), bits: input.register == 3 ? 32 : 64)
                values[input.parameter.name] = value; registers[input.register] = value
            }
            var prelude: Set<Int> = [], pc = 0
            while pc != header {
                guard program.code.indices.contains(pc), prelude.insert(pc).inserted else { throw C.Failure.invalidContract("prelude cannot reach original first row") }
                let instruction = program.code[pc]
                switch instruction.node {
                case .nop, .declaration(_, nil): pc += 1
                case let .declaration(name, .some(expression)):
                    guard try row(instruction, in: program) == nil else { throw C.Failure.invalidContract("source effect escaped into initializer prelude") }
                    let value = try symbolic(expression, in: program, values: values)
                    guard pureOwner(value) else { throw C.Failure.invalidContract("prelude invents arithmetic or memory") }
                    try store(value, name: name, program: program, values: &values); pc += 1
                case let .assign(left, right):
                    guard try row(instruction, in: program) == nil, left.count == 1, right.count == 1,
                          case let .name(name) = left[0].node else { throw C.Failure.invalidContract("invalid entry transport") }
                    let value = try symbolic(right[0], in: program, values: values)
                    guard pureOwner(value) else { throw C.Failure.invalidContract("entry copy is not source-value transport") }
                    try store(value, name: name, program: program, values: &values); pc += 1
                case let .jump(target): pc = target
                default: throw C.Failure.invalidContract("prelude contains invented source/control work")
                }
            }
            let covered = prelude.union(routes.flatMap(\.pcs)).union([terminal])
            guard covered == Set(program.code.indices) else { throw C.Failure.invalidContract("candidate contains unowned or unreachable executable work") }
            let first = try bindRoute(backedge, program: program, source: source, values: &values, registers: &registers, epoch: 0)
            let firstState = values.mapValues { $0.relative(to: 0) }
            let second = try bindRoute(backedge, program: program, source: source, values: &values, registers: &registers, epoch: 1)
            // The whole named-store ownership relation repeats after renaming
            // the iteration. This is a fixed-point/lifetime proof, not a guess
            // from carrier spelling, count or two matching numerical runs.
            guard first == second, firstState == values.mapValues({ $0.relative(to: 1) }) else {
                throw C.Failure.invalidContract("coalesced storage has no stable noninterfering recurrence ownership")
            }
            let last = try bindRoute(exit, program: program, source: source, values: &values, registers: &registers, epoch: 2)
            guard first == last else { throw C.Failure.invalidContract("taken and exit routes bind different source slots") }
            if source.numericReturn {
                guard case let .returned(.some(expression)) = program.code[terminal].node,
                      let expected = registers[0], try symbolic(expression, in: program, values: values).term == expected.term else {
                    throw C.Failure.invalidContract("numeric RET does not read the last original body definition")
                }
            }
            return .init(header: header, terminal: terminal, routes: routes, slots: first)
        }

        private static func bindRoute(_ route: Route, program: C.Program, source: Source,
                                      values: inout [String: Symbolic], registers: inout [Int: Symbolic],
                                      epoch: Int) throws -> [Slot] {
            let (expected, finalRegisters) = try units(source, incoming: registers, epoch: epoch)
            var cursor = 0, slots: [Slot] = []
            for pc in route.pcs {
                let instruction = program.code[pc], sourceRow = try row(instruction, in: program)
                let destination: String?, expression: C.Expression?, span: C.Span
                switch instruction.node {
                case .nop, .jump: continue
                case let .declaration(name, nil):
                    guard sourceRow == nil else { throw C.Failure.invalidContract("empty declaration falsely claims original effect") }
                    values.removeValue(forKey: name); continue
                case let .declaration(name, .some(e)):
                    destination = name; expression = e; span = instruction.span
                case let .assign(left, right):
                    guard left.count == 1, right.count == 1 else { throw C.Failure.unsupportedSyntax("body tuple is not ordinary scalar C") }
                    if case let .load(type, address) = left[0].node {
                        guard expected.indices.contains(cursor),
                              case let .store(row, bytes, expectedAddress, expectedData) = expected[cursor],
                              sourceRow == row, type.unsigned, type.width == bytes * 8,
                              program.memorySites[left[0].span] == .init(row: row, effectOrdinal: 0),
                              try symbolic(address, in: program, values: values).term == expectedAddress,
                              try symbolic(right[0], in: program, values: values).project(type.width).term == expectedData else {
                            throw C.Failure.invalidContract("store is missing, reordered, wrong-width or has conflicting source owners")
                        }
                        cursor += 1; continue
                    }
                    guard case let .name(name) = left[0].node else { throw C.Failure.unsupportedSyntax("non-scalar entry lvalue") }
                    destination = name; expression = right[0]; span = left[0].span
                case let .branch(condition, _, _):
                    guard cursor == expected.count, let counter = finalRegisters[3],
                          let transfer = route.transfers.first(where: { $0.span == condition.span }),
                          let taken = transfer.taken else {
                        throw C.Failure.invalidContract("latch precedes a source effect or lacks a real transfer")
                    }
                    let actualPolarity = try predicate(condition, program: program, values: values, counter: counter)
                    // A structured guard may invert the textual comparison, but
                    // its actual destination must preserve the original edge.
                    guard route.backedge == (actualPolarity == source.polarity ? taken : !taken) else {
                        throw C.Failure.invalidContract("SUBS latch has inverted original taken/fallthrough polarity")
                    }
                    continue
                default: throw C.Failure.invalidContract("unmodeled operation on source route")
                }
                guard let name = destination, let expression else { throw C.Failure.invalidContract("lost scalar assignment") }
                let value = try symbolic(expression, in: program, values: values)
                if expected.indices.contains(cursor),
                   case let .scalar(row, ordinal, _, width, result, expectedExpression) = expected[cursor],
                   sourceRow == row, value.term == expectedExpression {
                    guard let type = program.symbols[name]?.type, type.unsigned, !type.pointer,
                          type.width >= result.bits, type.width <= width,
                          try program.row(at: span) == row else {
                        throw C.Failure.invalidContract("source destination slot has wrong representation or AST commit identity")
                    }
                    slots.append(.init(row: row, ordinal: ordinal, width: width, knownBits: result.bits,
                                       pc: pc, span: span, name: name, storageType: type))
                    try store(result, name: name, program: program, values: &values)
                    cursor += 1
                } else {
                    // Administrative transport does not consume an original
                    // definition slot. It executes in its actual printed order,
                    // and can never repair a missing/reordered arithmetic effect.
                    guard pureOwner(value), sourceRow == nil || (0..<(source.rows.count - 1)).contains(sourceRow!) else {
                        throw C.Failure.invalidContract("extra arithmetic/load or unowned administrative copy")
                    }
                    try store(value, name: name, program: program, values: &values)
                }
            }
            guard cursor == expected.count, Set(slots.map(\.span)).count == slots.count else {
                throw C.Failure.invalidContract("route does not own every original effect/destination slot exactly once")
            }
            registers = finalRegisters
            return slots
        }
    }

    struct Event: Equatable {
        enum Kind: Equatable { case load, store }
        let kind: Kind
        let address: UInt64
        let bytes: Int
        let value: UInt64
    }
    struct Write { let source: UInt64; let slot: Int; let value: Value }
    struct Result {
        var events: [Event] = []
        var decisions: [Bool] = []
        var writes: [Write] = []
        var memory: [UInt64: UInt8]
        var returned = false
        var stoppedAtBackedge = false
        var returnValue: Value?
        var returnMarker: String?
        func values(at source: UInt64, slot: Int) -> [Value] {
            writes.filter { $0.source == source && $0.slot == slot }.map(\.value)
        }
    }
    private struct Trace {
        let binding: Binding
        var started = false
        var path: [Int] = []
        var transferStart = 0
        var decisions: [Bool] = []
        var stopped = false
        mutating func before(_ pc: Int, transfers: [C.Transfer], limit: Int) throws -> Bool {
            if !started {
                guard pc == binding.header else { return false }
                started = true; transferStart = transfers.count
            } else if pc == binding.header || pc == binding.terminal {
                let actual = Array(transfers.dropFirst(transferStart))
                let routes = binding.routes.filter { route in
                    route.destination == pc && route.pcs == path && route.transfers.count == actual.count &&
                        zip(route.transfers, actual).allSatisfy { pair in
                            pair.0.span == pair.1.span && pair.0.sourceRow == pair.1.sourceRow &&
                                pair.0.taken == pair.1.taken && pair.0.destination == pair.1.destination
                        }
                }
                guard routes.count == 1 else { throw C.Failure.invalidContract("executed route has no exact original edge ownership") }
                decisions.append(routes[0].backedge)
                if decisions.filter({ $0 }).count == limit {
                    guard pc == binding.header, decisions.allSatisfy({ $0 }) else { throw C.Failure.invalidContract("prefix boundary is not a completed original taken edge") }
                    stopped = true; return true
                }
                path = []; transferStart = transfers.count
                if pc == binding.terminal { return false }
            }
            path.append(pc); return false
        }
    }
    let program: Program
    let inputs: [String: Value]
    let memory: [UInt64: UInt8]
    func run(latchLimit: Int) throws -> Result {
        do {
            guard latchLimit > 0 else { throw C.Failure.invalidContract("nonpositive source-edge prefix limit") }
            let scenario = try N.scenario(name: "authored-entry", inputs: inputs, memory: memory, manifest: program.source.manifest)
            var machine = try C.Machine(program: program.candidate, scenario: scenario)
            var trace = Trace(binding: program.binding)
            let actual = try machine.execute(fuel: 10_000, beforeInstruction: { pc, transfers in
                try trace.before(pc, transfers: transfers, limit: latchLimit)
            })
            guard actual.returned != trace.stopped, !actual.reachedRegionBoundary, actual.consumedResponses == 0 else {
                throw C.Failure.invalidContract("candidate has neither an exact terminal nor a complete taken-edge prefix")
            }
            if actual.returned {
                try N.requireTerminal(actual, manifest: program.source.manifest)
                guard trace.decisions.last == false else { throw C.Failure.invalidContract("return lacks original fallthrough edge") }
            }
            var result = Result(memory: actual.memory)
            result.decisions = trace.decisions; result.returned = actual.returned; result.stoppedAtBackedge = trace.stopped
            result.returnValue = actual.terminal
            if actual.unavailableTerminal == .unresolvedReturnContract { result.returnMarker = "unresolved_return_contract" }
            result.events = try actual.events.map { event in
                switch event {
                case let .load(_, _, address, bytes, value): return .init(kind: .load, address: address, bytes: bytes, value: value)
                case let .store(_, _, address, bytes, value): return .init(kind: .store, address: address, bytes: bytes, value: value)
                case .call: throw C.Failure.invalidContract("call escaped the no-call contract")
                }
            }
            let slots = Dictionary(uniqueKeysWithValues: program.binding.slots.map { ($0.span, $0) })
            for commit in actual.commits {
                guard let slot = slots[commit.span] else { continue } // Independently proven transport, never a source slot.
                guard commit.name == slot.name, commit.sourceRow == slot.row, commit.value.type == slot.storageType,
                      commit.value.origins.isEmpty else { throw C.Failure.invalidContract("actual commit differs from its frozen source-slot binding") }
                result.writes.append(.init(source: program.source.rows[slot.row].address, slot: slot.ordinal,
                    value: .init(commit.value.bits, .init(slot.width, true))))
            }
            // Every full original route commits all bound source slots once.
            // Missing/extra commits cannot disappear in a source-row projection.
            guard result.writes.count == trace.decisions.count * program.binding.slots.count else {
                throw C.Failure.invalidContract("actual source-slot commit cardinality differs from completed original routes")
            }
            return result
        } catch let error as C.Failure {
            if case let .undefinedC(detail) = error { throw Failure.undefined(detail) }
            throw Failure.invalid(String(describing: error))
        }
    }

    /// Strict parsed-expression self-checks keep the original literal typing and
    /// overflow obligations without accepting any loop dialect or source values.
    static func literal(_ expression: String) throws -> Value {
        do {
            let signature = "uint64_t oracle_literal(void) {", name = "oracle_value"
            let payload = "return \(name);"
            let contract = C.Contract(signature: signature, inputs: [], fields: [], calls: [:], exterior: [:],
                terminalRow: 0, terminalPayload: payload, terminalName: name, returnType: .u64,
                rowsByAddress: [0: 0], allowedLabels: [], memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
            let program = try C.Program(lines: [.init(text: signature, source: nil, envelope: .signature),
                .init(text: "uint64_t \(name) = \(expression);", source: nil, envelope: .body),
                .init(text: payload, source: 0, envelope: .body), .init(text: "}", source: nil, envelope: .closingBrace)], contract: contract)
            guard let instruction = program.code.first(where: {
                if case .declaration = $0.node { return true }
                return false
            }),
                  case let .declaration(parsedName, .some(value)) = instruction.node,
                  parsedName == name else {
                throw C.Failure.invalidContract("missing parsed literal initializer expression")
            }
            var machine = try C.Machine(program: program, scenario: .init(name: "literal", inputs: [:], memory: [:], responses: []))
            return try machine.evaluate(value) // Observe expression type before storage or function-return conversion.
        } catch let error as C.Failure {
            if case let .undefinedC(detail) = error { throw Failure.undefined(detail) }
            throw Failure.invalid(String(describing: error))
        }
    }
    static func storage(_ name: String, parameter: MacIRFunctionParameter, local: MacIRLocalVariable) throws -> Value {
        guard let inputType = C.CType.named(parameter.type) else { throw Failure.invalid("unsupported storage-probe formal") }
        let signature = "uint64_t oracle_storage(\(parameter.type) \(parameter.name)) {"
        let payload = "return \(name);"
        let contract = C.Contract(signature: signature,
            inputs: [.init(name: parameter.name, type: inputType, entrySlot: 0)], fields: [], calls: [:], exterior: [:],
            terminalRow: 1, terminalPayload: payload, terminalName: name, returnType: .u64,
            rowsByAddress: [0: 0, 4: 1], allowedLabels: [], memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        let lines: [C.TextLine] = [
            .init(text: signature, source: nil, envelope: .signature),
            .init(text: "uint64_t \(name) = 0x0;", source: nil, envelope: .body),
            .init(text: "oracle_body = 0x1;", source: 0, envelope: .body),
            .init(text: "\(name) = (uint64_t)oracle_body;", source: nil, envelope: .body),
            .init(text: payload, source: 4, envelope: .body),
            .init(text: "}", source: nil, envelope: .closingBrace)]
        let program = try C.Program(lines: lines, contract: contract)
        guard program.symbols[local.name] == nil else { throw Failure.invalid("declared storage captures a reserved local") }
        let result = try C.Machine(program: program,
            scenario: .init(name: "storage", inputs: [parameter.name: .init(0, inputType)], memory: [:], responses: [])).run()
        guard result.returned, let value = result.terminal else { throw Failure.invalid("storage probe did not return") }
        return value
    }
}
