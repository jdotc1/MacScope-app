import XCTest
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif

/// A28: a cmp;ccmp chain's `__compare` / `__conditional_compare_*` statements are
/// elided under SSA only when every NZCV reader of the chain lifted a condition.
final class CmpCcmpChainElisionTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic, operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func text(ssa: Bool = true, _ rows: [InstructionRow]) -> String {
        let function = MacIRBuilder(ssaEnabled: ssa).buildFunction(name: "_chain", instructions: rows)
        return PseudocodePrinter().print(function: function).text
    }

    private let chain: [InstructionRow] = [
        InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "cmp", operands: "w0, #0x1", hasBreakpoint: false, comment: nil),
        InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "lsl", operands: "w4, w1, #0x1", hasBreakpoint: false, comment: nil),
        InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "ccmp", operands: "w2, #0x3, #0x0, ne", hasBreakpoint: false, comment: nil),
    ]

    private func requireHelpers(_ out: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(out.contains("__compare("), out, file: file, line: line)
        XCTAssertTrue(out.contains("__conditional_compare_"), out, file: file, line: line)
    }

    private func requireNoHelpers(_ out: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(out.contains("__compare("), out, file: file, line: line)
        XCTAssertFalse(out.contains("__conditional_compare_"), out, file: file, line: line)
    }

    func testCmpLslCcmpBranchElidesChain() {
        let out = text(chain + [row(0x100c, "b.eq", "0x1014"), row(0x1010, "nop", ""), row(0x1014, "ret", "")])
        requireNoHelpers(out)
        XCTAssertTrue(out.contains("&&"), out)
    }

    func testCmpLslCcmpCsetElidesChain() {
        let out = text(chain + [row(0x100c, "cset", "w15, eq"), row(0x1010, "ret", "")])
        requireNoHelpers(out)
        XCTAssertFalse(out.contains("__unknown(\"cset\""), out)
    }

    func testChainBesideLiftedFlagsPhiElidesBoth() {
        let out = text([
            row(0x1000, "cbz", "w5, 0x1020"),
            row(0x1004, "cmp", "w0, #0x1"),
            row(0x1008, "b", "0x1040"),
            row(0x100c, "nop", ""),
            row(0x1020, "cmp", "w1, #0x2"),
            row(0x1024, "lsl", "w4, w1, #0x1"),
            row(0x1028, "ccmp", "w2, #0x3, #0x0, ne"),
            row(0x102c, "cset", "w6, eq"),
            row(0x1030, "cmp", "w3, #0x4"),
            row(0x1034, "b", "0x1040"),
            row(0x1040, "csel", "x9, x2, x3, eq"),
            row(0x1044, "ret", ""),
        ])
        XCTAssertFalse(out.contains("__unknown(\"csel\""), out)
        requireNoHelpers(out)
    }

    func testCcmpFlagsReadByUnliftedConsumerKeepsChain() {
        let out = text(chain + [
            row(0x100c, "b.eq", "0x1018"), row(0x1010, "adc", "x7, x7, xzr"), row(0x1014, "ret", ""), row(0x1018, "ret", "")])
        XCTAssertTrue(out.contains("&&"), out)
        requireHelpers(out)
    }

    func testCmpFlagsReadByCcmpAndLaterUnliftedConsumerKeepsChain() {
        let out = text([
            row(0x1000, "cmp", "w0, #0x1"),
            row(0x1004, "adc", "x7, x7, xzr"),
            row(0x1008, "lsl", "w4, w1, #0x1"),
            row(0x100c, "ccmp", "w2, #0x3, #0x0, ne"),
            row(0x1010, "b.eq", "0x1018"), row(0x1014, "ret", ""), row(0x1018, "ret", "")])
        requireHelpers(out)
    }

    func testChainFlagsLiveOutToJoinWithoutLiftedFlagsPhiKeepsChain() {
        let out = text([
            row(0x1000, "cbz", "w5, 0x1020"),
            row(0x1004, "cmp", "w0, #0x1"),
            row(0x1008, "lsl", "w4, w1, #0x1"),
            row(0x100c, "ccmp", "w2, #0x3, #0x0, ne"),
            row(0x1010, "b", "0x1030"),
            row(0x1020, "cmp", "w1, #0x2"),
            row(0x1024, "b", "0x1030"),
            row(0x1030, "csel", "x9, x2, x3, eq"),
            row(0x1034, "ret", ""),
        ])
        XCTAssertTrue(out.contains("__unknown(\"csel\""), out)
        requireHelpers(out)
    }

    func testChainCompareFeedingRefusedFlagsPhiKeepsChain() {
        let out = text([
            row(0x1000, "cmp", "w0, #0x1"),
            row(0x1004, "b.ne", "0x1030"),
            row(0x1008, "lsl", "w4, w1, #0x1"),
            row(0x100c, "ccmp", "w2, #0x3, #0x0, ne"),
            row(0x1010, "b.eq", "0x1040"),
            row(0x1014, "bl", "_f"),
            row(0x1030, "csel", "x9, x2, x3, eq"),
            row(0x1034, "ret", ""),
            row(0x1040, "ret", ""),
        ])
        XCTAssertTrue(out.contains("__unknown(\"csel\""), out)
        requireHelpers(out)
    }

    func testFlagOffKeepsChainStatements() {
        let out = text(ssa: false, chain + [row(0x100c, "b.eq", "0x1014"), row(0x1010, "nop", ""), row(0x1014, "ret", "")])
        requireHelpers(out)
    }

    // Item338 cells are independently named below. This helper never loops over cells.
    // Numerical observation is a component test of the actual emitted consumer C;
    // it does not grant the original function a return contract or prove whole CFG rendering.
    private func checkLogicalConditionalCell(
        _ id: String, producer: UInt32, consumer: UInt32, family: String,
        mnemonic: String, suffix: String, chain: Bool, guardSuffix: String = "ge", guardBits: UInt64,
        otherBits: UInt64, expected: [Bool], refused: Bool,
        declined: Bool = false, strictRefusals: [Bool] = [],
        distinguishAliasedResult: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let words: [UInt32] = [0xb9400268, 0xb9400289, 0xb94002aa]
            + (chain ? [0x7100055f] : []) + [producer, consumer, 0x710001ff, 0xd65f03c0]
        let bytes = words.flatMap { word in
            [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
             UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
        }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: 0x7000,
            maxInstructionCount: words.count)
        XCTAssertEqual(decoded.count, words.count, file: file, line: line)
        let rows = decoded.map { InstructionRow(decoded: $0) }
        XCTAssertFalse(rows.contains { $0.mnemonic == "unknown" || $0.mnemonic == ".word" },
            id, file: file, line: line)
        let producerAddress: UInt64 = chain ? 0x7010 : 0x700c
        let consumerAddress = producerAddress + 4
        XCTAssertEqual(rows.first { $0.address == producerAddress }?.mnemonic, family,
            id, file: file, line: line)
        XCTAssertEqual(rows.first { $0.address == consumerAddress }?.mnemonic, mnemonic,
            id, file: file, line: line)
        if chain {
            XCTAssertTrue(rows.first { $0.address == producerAddress }?.operands.hasSuffix(", \(guardSuffix)") == true,
                id, file: file, line: line)
        }
        if !mnemonic.hasPrefix("b.") {
            XCTAssertTrue(rows.first { $0.address == consumerAddress }?.operands.hasSuffix(", \(suffix)") == true,
                id, file: file, line: line)
        }
        var function = MacIRBuilder(ssaEnabled: false).buildFunction(name: "_338_cell", instructions: rows)
        XCTAssertFalse(function.ssaEnabled, id, file: file, line: line)
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == consumerAddress },
            id, file: file, line: line)
        let producerInstruction = try XCTUnwrap(function.instructions.first { $0.source.address == producerAddress },
            id, file: file, line: line)
        var overrides = [
            "w8": "source_word", "w9": "other_word", "w10": "guard_word",
            "w12": "logical_result", "x13": "selected_a", "x14": "selected_b", "x0": "result"
        ]
        if distinguishAliasedResult {
            let initial = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7000 },
                id, file: file, line: line)
            guard case let .load(input, _) = initial.operation,
                  case let .assign(output, _) = producerInstruction.operation,
                  case let .register(inputName, inputVersion) = input,
                  case let .register(outputName, outputVersion) = output else {
                return XCTFail("\(id): missing distinct register-version alias fixture", file: file, line: line)
            }
            XCTAssertEqual(inputName, outputName, file: file, line: line)
            XCTAssertNotEqual(input, output, file: file, line: line)
            guard input != output else { return }
            guard case let .compareToBool(_, _, observedLeft, _) = instruction.operation else {
                return XCTFail("\(id): missing alias-control consumer", file: file, line: line)
            }
            XCTAssertEqual(MacIRBuilder.droppingSignedProjection(observedLeft), output,
                "the certificate must read the actual written result, not re-evaluate an aliased source",
                file: file, line: line)
            // Name actual IR identities, not physical storage: an OrdinaryC input is immutable.
            // Only presentation bindings change; the produced operations are left untouched.
            let inputTarget = MacIRNameBindingTarget.register(name: inputName, version: inputVersion)
            let outputTarget = MacIRNameBindingTarget.register(name: outputName, version: outputVersion)
            function.nameBindings.removeAll { $0.target == inputTarget || $0.target == outputTarget }
            function.nameBindings += [
                .init(target: inputTarget, name: "source_word", type: "uint32_t", kind: .registerTemporary),
                .init(target: outputTarget, name: "logical_result", type: "uint32_t", kind: .registerTemporary)
            ]
            overrides.removeValue(forKey: inputName)
        }
        let names = PseudocodeNameContext(function: function, registerNameOverrides: overrides)
        let printer = PseudocodePrinter(options: .default)
        let actual = printer.render(instruction: instruction, names: names)
        if declined {
            // No standalone CMP consumer exists here. Disabling the native certificate
            // policy supplies the unchanged main path for this logical-only witness.
            let legacy = MacIRBuilder(skippingRejectedCFGReconciliation: false,
                explicitCFGEnabled: nil, nativeSignedWordCMPEnabled: false)
                .buildFunction(name: "_338_cell", instructions: rows)
            XCTAssertEqual(function.instructions, legacy.instructions, id, file: file, line: line)
            XCTAssertEqual(printer.print(function: function, registerNameOverrides: overrides).text,
                printer.print(function: legacy, registerNameOverrides: overrides).text,
                "\(id): a declined pair must preserve the complete main document", file: file, line: line)
        }
        if refused {
            if mnemonic.hasPrefix("b.") {
                guard case let .intrinsic(nil, name, arguments) = instruction.operation,
                      name == "branch_\(suffix)",
                      arguments == [.immediate(Int64(consumerAddress + 8))] else {
                    return XCTFail("\(id): missing exact retained branch refusal: \(actual)", file: file, line: line)
                }
                XCTAssertTrue(actual.contains("__branch_\(suffix)("), actual, file: file, line: line)
            } else {
                guard case .unknown = instruction.operation else {
                    return XCTFail("\(id): an explicit retained refusal disappeared: \(actual)", file: file, line: line)
                }
                XCTAssertTrue(actual.contains("__unknown("), actual, file: file, line: line)
            }
            let retained = printer.render(instruction: producerInstruction, names: names)
            XCTAssertTrue(retained.contains(chain ? "__conditional_compare_" : "__unknown("),
                retained, file: file, line: line)
            return
        }
        if family == "tst" {
            guard case let .intrinsic(nil, "compare", arguments) = producerInstruction.operation,
                  arguments.count == 2 else {
                return XCTFail("\(id): missing exact TST producer operation", file: file, line: line)
            }
            let consumedLeft: MacIRValue
            switch instruction.operation {
            case let .conditionalBranch(_, value, _, _), let .compareToBool(_, _, value, _),
                 let .select(_, _, value, _, _, _): consumedLeft = value
            default: return XCTFail("\(id): missing TST consumer", file: file, line: line)
            }
            XCTAssertEqual(arguments[0], consumedLeft, "producer and consumer must agree", file: file, line: line)
            if declined {
                guard case .unary("(int32_t)", _) = consumedLeft else {
                    return XCTFail("\(id): declined pair changed main's raw cast", file: file, line: line)
                }
            } else {
                guard case let .binaryExpression(marker, _, _) = consumedLeft else {
                    return XCTFail("\(id): missing safe result projection", file: file, line: line)
                }
                XCTAssertEqual(marker, MacIRBuilder.signedProjectionOperator, file: file, line: line)
                let document = printer.print(function: function, registerNameOverrides: overrides)
                XCTAssertTrue(document.text.contains("0x80000000"), document.text, file: file, line: line)
                XCTAssertFalse(document.lines.contains { $0.sourceAddress == producerAddress
                    && $0.text.contains("__compare(") }, "no orphan TST compare", file: file, line: line)
            }
        }
        let statement: String
        if mnemonic.hasPrefix("b.") {
            guard case let .conditionalBranch(condition, left, right, _) = instruction.operation else {
                return XCTFail("\(id): missing actual branch predicate: \(actual)", file: file, line: line)
            }
            // Same actual operands and same renderCondition; only the observation sink changes.
            statement = printer.render(operation: .compareToBool(destination: .register(name: "x0", version: 0),
                condition: condition, left: left, right: right), names: names)
            let expression = String(statement.dropFirst("result = ".count))
            XCTAssertTrue(actual.contains("if (\(expression))"), actual, file: file, line: line)
        } else {
            statement = actual
            XCTAssertFalse(actual.contains("__unknown("), actual, file: file, line: line)
        }
        let signature = "int64_t cell338(uint32_t source_word, uint32_t other_word, uint32_t guard_word, int64_t selected_a, int64_t selected_b) {"
        let terminal = "return result;"
        let observation: UInt64 = 0x7100
        let contract = OrdinaryC.Contract(signature: signature,
            inputs: [.init(name: "source_word", type: .u32, entrySlot: 8),
                     .init(name: "other_word", type: .u32, entrySlot: 9),
                     .init(name: "guard_word", type: .u32, entrySlot: 10),
                     .init(name: "selected_a", type: .i64, entrySlot: 13),
                     .init(name: "selected_b", type: .i64, entrySlot: 14)],
            fields: [], calls: [:], exterior: [:], terminalRow: 99,
            terminalPayload: terminal, terminalName: "result", returnType: .i64,
            rowsByAddress: [producerAddress: 3, consumerAddress: 4, observation: 99],
            allowedLabels: [], memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        var lines: [OrdinaryC.TextLine] = [.init(text: signature, source: nil, envelope: .signature)]
        if family == "ands" {
            lines.append(.init(text: printer.render(instruction: producerInstruction, names: names) + ";",
                source: producerAddress, envelope: .body))
        }
        lines += [.init(text: statement + ";", source: consumerAddress, envelope: .body),
                  .init(text: terminal, source: observation, envelope: .body),
                  .init(text: "}", source: nil, envelope: .closingBrace)]
        let program = try OrdinaryC.Program(lines: lines, contract: contract)
        let boundaries: [UInt64] = [0x80000000, 0xffffffff, 0, 0x7fffffff]
        XCTAssertEqual(expected.count, boundaries.count, id, file: file, line: line)
        guard expected.count == boundaries.count else { return }
        for (index, bits) in boundaries.enumerated() {
            // A failed boundary is reported without suppressing the remaining boundaries.
            do {
                let result = try OrdinaryC.Machine(program: program, scenario: .init(name: "\(id)-\(bits)",
                    inputs: ["source_word": .init(bits, .u32), "other_word": .init(otherBits, .u32),
                             "guard_word": .init(guardBits, .u32), "selected_a": .init(5, .i64),
                             "selected_b": .init(9, .i64)], memory: [:], responses: [])).run()
                if declined && strictRefusals.indices.contains(index) && strictRefusals[index] {
                    XCTFail("\(id): known strict-C failure unexpectedly vanished", file: file, line: line)
                    continue
                }
                let holds = expected[index]
                let value: Int64
                switch mnemonic {
                case "cset": value = holds ? 1 : 0
                case "csetm": value = holds ? -1 : 0
                case "csel": value = holds ? 5 : 9
                case "csinc": value = holds ? 5 : 10
                case "csinv": value = holds ? 5 : -10
                case "csneg": value = holds ? 5 : -9
                case "cinc": value = holds ? 6 : 5
                case "cinv": value = holds ? -6 : 5
                case "cneg": value = holds ? -5 : 5
                default: value = holds ? 1 : 0
                }
                XCTAssertTrue(result.returned, id, file: file, line: line)
                XCTAssertEqual(result.terminal?.bits, UInt64(bitPattern: value),
                    "\(id), boundary \(bits): \(actual)", file: file, line: line)
            } catch OrdinaryC.Failure.undefinedC(let detail) {
                if declined && strictRefusals.indices.contains(index) && strictRefusals[index] {
                    XCTAssertEqual(detail, "unsigned/signed conversion not representable", file: file, line: line)
                } else {
                    XCTFail("\(id), boundary \(bits): \(detail)", file: file, line: line)
                }
            } catch {
                XCTFail("\(id), boundary \(bits): \(error)", file: file, line: line)
            }
        }
    }

    func test338TSTImmediateBCONDGE() throws {
        try checkLogicalConditionalCell("TSTImmediateBCONDGE", producer: 0x7201011f, consumer: 0x5400004a,
            family: "tst", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateBCONDLT() throws {
        try checkLogicalConditionalCell("TSTImmediateBCONDLT", producer: 0x7201011f, consumer: 0x5400004b,
            family: "tst", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateBCONDGT() throws {
        try checkLogicalConditionalCell("TSTImmediateBCONDGT", producer: 0x7201011f, consumer: 0x5400004c,
            family: "tst", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateBCONDLE() throws {
        try checkLogicalConditionalCell("TSTImmediateBCONDLE", producer: 0x7201011f, consumer: 0x5400004d,
            family: "tst", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSETGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSETGE", producer: 0x7201011f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSETLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSETLT", producer: 0x7201011f, consumer: 0x9a9fa7e0,
            family: "tst", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSETGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSETGT", producer: 0x7201011f, consumer: 0x9a9fd7e0,
            family: "tst", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSETLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSETLE", producer: 0x7201011f, consumer: 0x9a9fc7e0,
            family: "tst", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSETMGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSETMGE", producer: 0x7201011f, consumer: 0xda9fb3e0,
            family: "tst", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSETMLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSETMLT", producer: 0x7201011f, consumer: 0xda9fa3e0,
            family: "tst", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSETMGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSETMGT", producer: 0x7201011f, consumer: 0xda9fd3e0,
            family: "tst", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSETMLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSETMLE", producer: 0x7201011f, consumer: 0xda9fc3e0,
            family: "tst", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSELGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSELGE", producer: 0x7201011f, consumer: 0x9a8ea1a0,
            family: "tst", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSELLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSELLT", producer: 0x7201011f, consumer: 0x9a8eb1a0,
            family: "tst", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSELGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSELGT", producer: 0x7201011f, consumer: 0x9a8ec1a0,
            family: "tst", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSELLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSELLE", producer: 0x7201011f, consumer: 0x9a8ed1a0,
            family: "tst", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSINCGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSINCGE", producer: 0x7201011f, consumer: 0x9a8ea5a0,
            family: "tst", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSINCLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSINCLT", producer: 0x7201011f, consumer: 0x9a8eb5a0,
            family: "tst", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSINCGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSINCGT", producer: 0x7201011f, consumer: 0x9a8ec5a0,
            family: "tst", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSINCLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSINCLE", producer: 0x7201011f, consumer: 0x9a8ed5a0,
            family: "tst", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSINVGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSINVGE", producer: 0x7201011f, consumer: 0xda8ea1a0,
            family: "tst", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSINVLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSINVLT", producer: 0x7201011f, consumer: 0xda8eb1a0,
            family: "tst", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSINVGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSINVGT", producer: 0x7201011f, consumer: 0xda8ec1a0,
            family: "tst", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSINVLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSINVLE", producer: 0x7201011f, consumer: 0xda8ed1a0,
            family: "tst", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSNEGGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSNEGGE", producer: 0x7201011f, consumer: 0xda8ea5a0,
            family: "tst", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSNEGLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSNEGLT", producer: 0x7201011f, consumer: 0xda8eb5a0,
            family: "tst", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSNEGGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCSNEGGT", producer: 0x7201011f, consumer: 0xda8ec5a0,
            family: "tst", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCSNEGLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCSNEGLE", producer: 0x7201011f, consumer: 0xda8ed5a0,
            family: "tst", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCINCGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCINCGE", producer: 0x7201011f, consumer: 0x9a8db5a0,
            family: "tst", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCINCLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCINCLT", producer: 0x7201011f, consumer: 0x9a8da5a0,
            family: "tst", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCINCGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCINCGT", producer: 0x7201011f, consumer: 0x9a8dd5a0,
            family: "tst", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCINCLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCINCLE", producer: 0x7201011f, consumer: 0x9a8dc5a0,
            family: "tst", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCINVGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCINVGE", producer: 0x7201011f, consumer: 0xda8db1a0,
            family: "tst", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCINVLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCINVLT", producer: 0x7201011f, consumer: 0xda8da1a0,
            family: "tst", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCINVGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCINVGT", producer: 0x7201011f, consumer: 0xda8dd1a0,
            family: "tst", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCINVLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCINVLE", producer: 0x7201011f, consumer: 0xda8dc1a0,
            family: "tst", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCNEGGE() throws {
        try checkLogicalConditionalCell("TSTImmediateCNEGGE", producer: 0x7201011f, consumer: 0xda8db5a0,
            family: "tst", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCNEGLT() throws {
        try checkLogicalConditionalCell("TSTImmediateCNEGLT", producer: 0x7201011f, consumer: 0xda8da5a0,
            family: "tst", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCNEGGT() throws {
        try checkLogicalConditionalCell("TSTImmediateCNEGGT", producer: 0x7201011f, consumer: 0xda8dd5a0,
            family: "tst", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTImmediateCNEGLE() throws {
        try checkLogicalConditionalCell("TSTImmediateCNEGLE", producer: 0x7201011f, consumer: 0xda8dc5a0,
            family: "tst", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterBCONDGE() throws {
        try checkLogicalConditionalCell("TSTRegisterBCONDGE", producer: 0x6a09011f, consumer: 0x5400004a,
            family: "tst", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterBCONDLT() throws {
        try checkLogicalConditionalCell("TSTRegisterBCONDLT", producer: 0x6a09011f, consumer: 0x5400004b,
            family: "tst", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterBCONDGT() throws {
        try checkLogicalConditionalCell("TSTRegisterBCONDGT", producer: 0x6a09011f, consumer: 0x5400004c,
            family: "tst", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterBCONDLE() throws {
        try checkLogicalConditionalCell("TSTRegisterBCONDLE", producer: 0x6a09011f, consumer: 0x5400004d,
            family: "tst", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSETGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSETGE", producer: 0x6a09011f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSETLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSETLT", producer: 0x6a09011f, consumer: 0x9a9fa7e0,
            family: "tst", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSETGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSETGT", producer: 0x6a09011f, consumer: 0x9a9fd7e0,
            family: "tst", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSETLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSETLE", producer: 0x6a09011f, consumer: 0x9a9fc7e0,
            family: "tst", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSETMGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSETMGE", producer: 0x6a09011f, consumer: 0xda9fb3e0,
            family: "tst", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSETMLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSETMLT", producer: 0x6a09011f, consumer: 0xda9fa3e0,
            family: "tst", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSETMGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSETMGT", producer: 0x6a09011f, consumer: 0xda9fd3e0,
            family: "tst", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSETMLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSETMLE", producer: 0x6a09011f, consumer: 0xda9fc3e0,
            family: "tst", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSELGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSELGE", producer: 0x6a09011f, consumer: 0x9a8ea1a0,
            family: "tst", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSELLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSELLT", producer: 0x6a09011f, consumer: 0x9a8eb1a0,
            family: "tst", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSELGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSELGT", producer: 0x6a09011f, consumer: 0x9a8ec1a0,
            family: "tst", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSELLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSELLE", producer: 0x6a09011f, consumer: 0x9a8ed1a0,
            family: "tst", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSINCGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSINCGE", producer: 0x6a09011f, consumer: 0x9a8ea5a0,
            family: "tst", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSINCLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSINCLT", producer: 0x6a09011f, consumer: 0x9a8eb5a0,
            family: "tst", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSINCGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSINCGT", producer: 0x6a09011f, consumer: 0x9a8ec5a0,
            family: "tst", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSINCLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSINCLE", producer: 0x6a09011f, consumer: 0x9a8ed5a0,
            family: "tst", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSINVGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSINVGE", producer: 0x6a09011f, consumer: 0xda8ea1a0,
            family: "tst", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSINVLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSINVLT", producer: 0x6a09011f, consumer: 0xda8eb1a0,
            family: "tst", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSINVGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSINVGT", producer: 0x6a09011f, consumer: 0xda8ec1a0,
            family: "tst", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSINVLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSINVLE", producer: 0x6a09011f, consumer: 0xda8ed1a0,
            family: "tst", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSNEGGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSNEGGE", producer: 0x6a09011f, consumer: 0xda8ea5a0,
            family: "tst", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSNEGLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSNEGLT", producer: 0x6a09011f, consumer: 0xda8eb5a0,
            family: "tst", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSNEGGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCSNEGGT", producer: 0x6a09011f, consumer: 0xda8ec5a0,
            family: "tst", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCSNEGLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCSNEGLE", producer: 0x6a09011f, consumer: 0xda8ed5a0,
            family: "tst", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCINCGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCINCGE", producer: 0x6a09011f, consumer: 0x9a8db5a0,
            family: "tst", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCINCLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCINCLT", producer: 0x6a09011f, consumer: 0x9a8da5a0,
            family: "tst", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCINCGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCINCGT", producer: 0x6a09011f, consumer: 0x9a8dd5a0,
            family: "tst", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCINCLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCINCLE", producer: 0x6a09011f, consumer: 0x9a8dc5a0,
            family: "tst", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCINVGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCINVGE", producer: 0x6a09011f, consumer: 0xda8db1a0,
            family: "tst", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCINVLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCINVLT", producer: 0x6a09011f, consumer: 0xda8da1a0,
            family: "tst", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCINVGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCINVGT", producer: 0x6a09011f, consumer: 0xda8dd1a0,
            family: "tst", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCINVLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCINVLE", producer: 0x6a09011f, consumer: 0xda8dc1a0,
            family: "tst", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCNEGGE() throws {
        try checkLogicalConditionalCell("TSTRegisterCNEGGE", producer: 0x6a09011f, consumer: 0xda8db5a0,
            family: "tst", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCNEGLT() throws {
        try checkLogicalConditionalCell("TSTRegisterCNEGLT", producer: 0x6a09011f, consumer: 0xda8da5a0,
            family: "tst", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCNEGGT() throws {
        try checkLogicalConditionalCell("TSTRegisterCNEGGT", producer: 0x6a09011f, consumer: 0xda8dd5a0,
            family: "tst", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTRegisterCNEGLE() throws {
        try checkLogicalConditionalCell("TSTRegisterCNEGLE", producer: 0x6a09011f, consumer: 0xda8dc5a0,
            family: "tst", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLBCONDGE() throws {
        try checkLogicalConditionalCell("TSTLSLBCONDGE", producer: 0x6a09051f, consumer: 0x5400004a,
            family: "tst", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLBCONDLT() throws {
        try checkLogicalConditionalCell("TSTLSLBCONDLT", producer: 0x6a09051f, consumer: 0x5400004b,
            family: "tst", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLBCONDGT() throws {
        try checkLogicalConditionalCell("TSTLSLBCONDGT", producer: 0x6a09051f, consumer: 0x5400004c,
            family: "tst", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLBCONDLE() throws {
        try checkLogicalConditionalCell("TSTLSLBCONDLE", producer: 0x6a09051f, consumer: 0x5400004d,
            family: "tst", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSETGE() throws {
        try checkLogicalConditionalCell("TSTLSLCSETGE", producer: 0x6a09051f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSETLT() throws {
        try checkLogicalConditionalCell("TSTLSLCSETLT", producer: 0x6a09051f, consumer: 0x9a9fa7e0,
            family: "tst", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSETGT() throws {
        try checkLogicalConditionalCell("TSTLSLCSETGT", producer: 0x6a09051f, consumer: 0x9a9fd7e0,
            family: "tst", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSETLE() throws {
        try checkLogicalConditionalCell("TSTLSLCSETLE", producer: 0x6a09051f, consumer: 0x9a9fc7e0,
            family: "tst", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSETMGE() throws {
        try checkLogicalConditionalCell("TSTLSLCSETMGE", producer: 0x6a09051f, consumer: 0xda9fb3e0,
            family: "tst", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSETMLT() throws {
        try checkLogicalConditionalCell("TSTLSLCSETMLT", producer: 0x6a09051f, consumer: 0xda9fa3e0,
            family: "tst", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSETMGT() throws {
        try checkLogicalConditionalCell("TSTLSLCSETMGT", producer: 0x6a09051f, consumer: 0xda9fd3e0,
            family: "tst", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSETMLE() throws {
        try checkLogicalConditionalCell("TSTLSLCSETMLE", producer: 0x6a09051f, consumer: 0xda9fc3e0,
            family: "tst", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSELGE() throws {
        try checkLogicalConditionalCell("TSTLSLCSELGE", producer: 0x6a09051f, consumer: 0x9a8ea1a0,
            family: "tst", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSELLT() throws {
        try checkLogicalConditionalCell("TSTLSLCSELLT", producer: 0x6a09051f, consumer: 0x9a8eb1a0,
            family: "tst", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSELGT() throws {
        try checkLogicalConditionalCell("TSTLSLCSELGT", producer: 0x6a09051f, consumer: 0x9a8ec1a0,
            family: "tst", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSELLE() throws {
        try checkLogicalConditionalCell("TSTLSLCSELLE", producer: 0x6a09051f, consumer: 0x9a8ed1a0,
            family: "tst", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSINCGE() throws {
        try checkLogicalConditionalCell("TSTLSLCSINCGE", producer: 0x6a09051f, consumer: 0x9a8ea5a0,
            family: "tst", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSINCLT() throws {
        try checkLogicalConditionalCell("TSTLSLCSINCLT", producer: 0x6a09051f, consumer: 0x9a8eb5a0,
            family: "tst", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSINCGT() throws {
        try checkLogicalConditionalCell("TSTLSLCSINCGT", producer: 0x6a09051f, consumer: 0x9a8ec5a0,
            family: "tst", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSINCLE() throws {
        try checkLogicalConditionalCell("TSTLSLCSINCLE", producer: 0x6a09051f, consumer: 0x9a8ed5a0,
            family: "tst", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSINVGE() throws {
        try checkLogicalConditionalCell("TSTLSLCSINVGE", producer: 0x6a09051f, consumer: 0xda8ea1a0,
            family: "tst", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSINVLT() throws {
        try checkLogicalConditionalCell("TSTLSLCSINVLT", producer: 0x6a09051f, consumer: 0xda8eb1a0,
            family: "tst", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSINVGT() throws {
        try checkLogicalConditionalCell("TSTLSLCSINVGT", producer: 0x6a09051f, consumer: 0xda8ec1a0,
            family: "tst", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSINVLE() throws {
        try checkLogicalConditionalCell("TSTLSLCSINVLE", producer: 0x6a09051f, consumer: 0xda8ed1a0,
            family: "tst", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSNEGGE() throws {
        try checkLogicalConditionalCell("TSTLSLCSNEGGE", producer: 0x6a09051f, consumer: 0xda8ea5a0,
            family: "tst", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSNEGLT() throws {
        try checkLogicalConditionalCell("TSTLSLCSNEGLT", producer: 0x6a09051f, consumer: 0xda8eb5a0,
            family: "tst", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSNEGGT() throws {
        try checkLogicalConditionalCell("TSTLSLCSNEGGT", producer: 0x6a09051f, consumer: 0xda8ec5a0,
            family: "tst", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCSNEGLE() throws {
        try checkLogicalConditionalCell("TSTLSLCSNEGLE", producer: 0x6a09051f, consumer: 0xda8ed5a0,
            family: "tst", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCINCGE() throws {
        try checkLogicalConditionalCell("TSTLSLCINCGE", producer: 0x6a09051f, consumer: 0x9a8db5a0,
            family: "tst", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCINCLT() throws {
        try checkLogicalConditionalCell("TSTLSLCINCLT", producer: 0x6a09051f, consumer: 0x9a8da5a0,
            family: "tst", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCINCGT() throws {
        try checkLogicalConditionalCell("TSTLSLCINCGT", producer: 0x6a09051f, consumer: 0x9a8dd5a0,
            family: "tst", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCINCLE() throws {
        try checkLogicalConditionalCell("TSTLSLCINCLE", producer: 0x6a09051f, consumer: 0x9a8dc5a0,
            family: "tst", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCINVGE() throws {
        try checkLogicalConditionalCell("TSTLSLCINVGE", producer: 0x6a09051f, consumer: 0xda8db1a0,
            family: "tst", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCINVLT() throws {
        try checkLogicalConditionalCell("TSTLSLCINVLT", producer: 0x6a09051f, consumer: 0xda8da1a0,
            family: "tst", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCINVGT() throws {
        try checkLogicalConditionalCell("TSTLSLCINVGT", producer: 0x6a09051f, consumer: 0xda8dd1a0,
            family: "tst", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCINVLE() throws {
        try checkLogicalConditionalCell("TSTLSLCINVLE", producer: 0x6a09051f, consumer: 0xda8dc1a0,
            family: "tst", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCNEGGE() throws {
        try checkLogicalConditionalCell("TSTLSLCNEGGE", producer: 0x6a09051f, consumer: 0xda8db5a0,
            family: "tst", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCNEGLT() throws {
        try checkLogicalConditionalCell("TSTLSLCNEGLT", producer: 0x6a09051f, consumer: 0xda8da5a0,
            family: "tst", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCNEGGT() throws {
        try checkLogicalConditionalCell("TSTLSLCNEGGT", producer: 0x6a09051f, consumer: 0xda8dd5a0,
            family: "tst", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSLCNEGLE() throws {
        try checkLogicalConditionalCell("TSTLSLCNEGLE", producer: 0x6a09051f, consumer: 0xda8dc5a0,
            family: "tst", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRBCONDGE() throws {
        try checkLogicalConditionalCell("TSTLSRBCONDGE", producer: 0x6a49051f, consumer: 0x5400004a,
            family: "tst", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRBCONDLT() throws {
        try checkLogicalConditionalCell("TSTLSRBCONDLT", producer: 0x6a49051f, consumer: 0x5400004b,
            family: "tst", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRBCONDGT() throws {
        try checkLogicalConditionalCell("TSTLSRBCONDGT", producer: 0x6a49051f, consumer: 0x5400004c,
            family: "tst", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRBCONDLE() throws {
        try checkLogicalConditionalCell("TSTLSRBCONDLE", producer: 0x6a49051f, consumer: 0x5400004d,
            family: "tst", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSETGE() throws {
        try checkLogicalConditionalCell("TSTLSRCSETGE", producer: 0x6a49051f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSETLT() throws {
        try checkLogicalConditionalCell("TSTLSRCSETLT", producer: 0x6a49051f, consumer: 0x9a9fa7e0,
            family: "tst", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSETGT() throws {
        try checkLogicalConditionalCell("TSTLSRCSETGT", producer: 0x6a49051f, consumer: 0x9a9fd7e0,
            family: "tst", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSETLE() throws {
        try checkLogicalConditionalCell("TSTLSRCSETLE", producer: 0x6a49051f, consumer: 0x9a9fc7e0,
            family: "tst", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSETMGE() throws {
        try checkLogicalConditionalCell("TSTLSRCSETMGE", producer: 0x6a49051f, consumer: 0xda9fb3e0,
            family: "tst", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSETMLT() throws {
        try checkLogicalConditionalCell("TSTLSRCSETMLT", producer: 0x6a49051f, consumer: 0xda9fa3e0,
            family: "tst", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSETMGT() throws {
        try checkLogicalConditionalCell("TSTLSRCSETMGT", producer: 0x6a49051f, consumer: 0xda9fd3e0,
            family: "tst", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSETMLE() throws {
        try checkLogicalConditionalCell("TSTLSRCSETMLE", producer: 0x6a49051f, consumer: 0xda9fc3e0,
            family: "tst", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSELGE() throws {
        try checkLogicalConditionalCell("TSTLSRCSELGE", producer: 0x6a49051f, consumer: 0x9a8ea1a0,
            family: "tst", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSELLT() throws {
        try checkLogicalConditionalCell("TSTLSRCSELLT", producer: 0x6a49051f, consumer: 0x9a8eb1a0,
            family: "tst", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSELGT() throws {
        try checkLogicalConditionalCell("TSTLSRCSELGT", producer: 0x6a49051f, consumer: 0x9a8ec1a0,
            family: "tst", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSELLE() throws {
        try checkLogicalConditionalCell("TSTLSRCSELLE", producer: 0x6a49051f, consumer: 0x9a8ed1a0,
            family: "tst", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSINCGE() throws {
        try checkLogicalConditionalCell("TSTLSRCSINCGE", producer: 0x6a49051f, consumer: 0x9a8ea5a0,
            family: "tst", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSINCLT() throws {
        try checkLogicalConditionalCell("TSTLSRCSINCLT", producer: 0x6a49051f, consumer: 0x9a8eb5a0,
            family: "tst", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSINCGT() throws {
        try checkLogicalConditionalCell("TSTLSRCSINCGT", producer: 0x6a49051f, consumer: 0x9a8ec5a0,
            family: "tst", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSINCLE() throws {
        try checkLogicalConditionalCell("TSTLSRCSINCLE", producer: 0x6a49051f, consumer: 0x9a8ed5a0,
            family: "tst", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSINVGE() throws {
        try checkLogicalConditionalCell("TSTLSRCSINVGE", producer: 0x6a49051f, consumer: 0xda8ea1a0,
            family: "tst", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSINVLT() throws {
        try checkLogicalConditionalCell("TSTLSRCSINVLT", producer: 0x6a49051f, consumer: 0xda8eb1a0,
            family: "tst", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSINVGT() throws {
        try checkLogicalConditionalCell("TSTLSRCSINVGT", producer: 0x6a49051f, consumer: 0xda8ec1a0,
            family: "tst", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSINVLE() throws {
        try checkLogicalConditionalCell("TSTLSRCSINVLE", producer: 0x6a49051f, consumer: 0xda8ed1a0,
            family: "tst", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSNEGGE() throws {
        try checkLogicalConditionalCell("TSTLSRCSNEGGE", producer: 0x6a49051f, consumer: 0xda8ea5a0,
            family: "tst", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSNEGLT() throws {
        try checkLogicalConditionalCell("TSTLSRCSNEGLT", producer: 0x6a49051f, consumer: 0xda8eb5a0,
            family: "tst", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSNEGGT() throws {
        try checkLogicalConditionalCell("TSTLSRCSNEGGT", producer: 0x6a49051f, consumer: 0xda8ec5a0,
            family: "tst", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCSNEGLE() throws {
        try checkLogicalConditionalCell("TSTLSRCSNEGLE", producer: 0x6a49051f, consumer: 0xda8ed5a0,
            family: "tst", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCINCGE() throws {
        try checkLogicalConditionalCell("TSTLSRCINCGE", producer: 0x6a49051f, consumer: 0x9a8db5a0,
            family: "tst", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCINCLT() throws {
        try checkLogicalConditionalCell("TSTLSRCINCLT", producer: 0x6a49051f, consumer: 0x9a8da5a0,
            family: "tst", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCINCGT() throws {
        try checkLogicalConditionalCell("TSTLSRCINCGT", producer: 0x6a49051f, consumer: 0x9a8dd5a0,
            family: "tst", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCINCLE() throws {
        try checkLogicalConditionalCell("TSTLSRCINCLE", producer: 0x6a49051f, consumer: 0x9a8dc5a0,
            family: "tst", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCINVGE() throws {
        try checkLogicalConditionalCell("TSTLSRCINVGE", producer: 0x6a49051f, consumer: 0xda8db1a0,
            family: "tst", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCINVLT() throws {
        try checkLogicalConditionalCell("TSTLSRCINVLT", producer: 0x6a49051f, consumer: 0xda8da1a0,
            family: "tst", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCINVGT() throws {
        try checkLogicalConditionalCell("TSTLSRCINVGT", producer: 0x6a49051f, consumer: 0xda8dd1a0,
            family: "tst", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCINVLE() throws {
        try checkLogicalConditionalCell("TSTLSRCINVLE", producer: 0x6a49051f, consumer: 0xda8dc1a0,
            family: "tst", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCNEGGE() throws {
        try checkLogicalConditionalCell("TSTLSRCNEGGE", producer: 0x6a49051f, consumer: 0xda8db5a0,
            family: "tst", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCNEGLT() throws {
        try checkLogicalConditionalCell("TSTLSRCNEGLT", producer: 0x6a49051f, consumer: 0xda8da5a0,
            family: "tst", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCNEGGT() throws {
        try checkLogicalConditionalCell("TSTLSRCNEGGT", producer: 0x6a49051f, consumer: 0xda8dd5a0,
            family: "tst", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTLSRCNEGLE() throws {
        try checkLogicalConditionalCell("TSTLSRCNEGLE", producer: 0x6a49051f, consumer: 0xda8dc5a0,
            family: "tst", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTASRBCONDGE() throws {
        try checkLogicalConditionalCell("TSTASRBCONDGE", producer: 0x6a89051f, consumer: 0x5400004a,
            family: "tst", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRBCONDLT() throws {
        try checkLogicalConditionalCell("TSTASRBCONDLT", producer: 0x6a89051f, consumer: 0x5400004b,
            family: "tst", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRBCONDGT() throws {
        try checkLogicalConditionalCell("TSTASRBCONDGT", producer: 0x6a89051f, consumer: 0x5400004c,
            family: "tst", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRBCONDLE() throws {
        try checkLogicalConditionalCell("TSTASRBCONDLE", producer: 0x6a89051f, consumer: 0x5400004d,
            family: "tst", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSETGE() throws {
        try checkLogicalConditionalCell("TSTASRCSETGE", producer: 0x6a89051f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSETLT() throws {
        try checkLogicalConditionalCell("TSTASRCSETLT", producer: 0x6a89051f, consumer: 0x9a9fa7e0,
            family: "tst", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSETGT() throws {
        try checkLogicalConditionalCell("TSTASRCSETGT", producer: 0x6a89051f, consumer: 0x9a9fd7e0,
            family: "tst", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSETLE() throws {
        try checkLogicalConditionalCell("TSTASRCSETLE", producer: 0x6a89051f, consumer: 0x9a9fc7e0,
            family: "tst", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSETMGE() throws {
        try checkLogicalConditionalCell("TSTASRCSETMGE", producer: 0x6a89051f, consumer: 0xda9fb3e0,
            family: "tst", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSETMLT() throws {
        try checkLogicalConditionalCell("TSTASRCSETMLT", producer: 0x6a89051f, consumer: 0xda9fa3e0,
            family: "tst", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSETMGT() throws {
        try checkLogicalConditionalCell("TSTASRCSETMGT", producer: 0x6a89051f, consumer: 0xda9fd3e0,
            family: "tst", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSETMLE() throws {
        try checkLogicalConditionalCell("TSTASRCSETMLE", producer: 0x6a89051f, consumer: 0xda9fc3e0,
            family: "tst", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSELGE() throws {
        try checkLogicalConditionalCell("TSTASRCSELGE", producer: 0x6a89051f, consumer: 0x9a8ea1a0,
            family: "tst", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSELLT() throws {
        try checkLogicalConditionalCell("TSTASRCSELLT", producer: 0x6a89051f, consumer: 0x9a8eb1a0,
            family: "tst", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSELGT() throws {
        try checkLogicalConditionalCell("TSTASRCSELGT", producer: 0x6a89051f, consumer: 0x9a8ec1a0,
            family: "tst", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSELLE() throws {
        try checkLogicalConditionalCell("TSTASRCSELLE", producer: 0x6a89051f, consumer: 0x9a8ed1a0,
            family: "tst", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSINCGE() throws {
        try checkLogicalConditionalCell("TSTASRCSINCGE", producer: 0x6a89051f, consumer: 0x9a8ea5a0,
            family: "tst", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSINCLT() throws {
        try checkLogicalConditionalCell("TSTASRCSINCLT", producer: 0x6a89051f, consumer: 0x9a8eb5a0,
            family: "tst", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSINCGT() throws {
        try checkLogicalConditionalCell("TSTASRCSINCGT", producer: 0x6a89051f, consumer: 0x9a8ec5a0,
            family: "tst", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSINCLE() throws {
        try checkLogicalConditionalCell("TSTASRCSINCLE", producer: 0x6a89051f, consumer: 0x9a8ed5a0,
            family: "tst", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSINVGE() throws {
        try checkLogicalConditionalCell("TSTASRCSINVGE", producer: 0x6a89051f, consumer: 0xda8ea1a0,
            family: "tst", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSINVLT() throws {
        try checkLogicalConditionalCell("TSTASRCSINVLT", producer: 0x6a89051f, consumer: 0xda8eb1a0,
            family: "tst", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSINVGT() throws {
        try checkLogicalConditionalCell("TSTASRCSINVGT", producer: 0x6a89051f, consumer: 0xda8ec1a0,
            family: "tst", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSINVLE() throws {
        try checkLogicalConditionalCell("TSTASRCSINVLE", producer: 0x6a89051f, consumer: 0xda8ed1a0,
            family: "tst", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSNEGGE() throws {
        try checkLogicalConditionalCell("TSTASRCSNEGGE", producer: 0x6a89051f, consumer: 0xda8ea5a0,
            family: "tst", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSNEGLT() throws {
        try checkLogicalConditionalCell("TSTASRCSNEGLT", producer: 0x6a89051f, consumer: 0xda8eb5a0,
            family: "tst", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSNEGGT() throws {
        try checkLogicalConditionalCell("TSTASRCSNEGGT", producer: 0x6a89051f, consumer: 0xda8ec5a0,
            family: "tst", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCSNEGLE() throws {
        try checkLogicalConditionalCell("TSTASRCSNEGLE", producer: 0x6a89051f, consumer: 0xda8ed5a0,
            family: "tst", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCINCGE() throws {
        try checkLogicalConditionalCell("TSTASRCINCGE", producer: 0x6a89051f, consumer: 0x9a8db5a0,
            family: "tst", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCINCLT() throws {
        try checkLogicalConditionalCell("TSTASRCINCLT", producer: 0x6a89051f, consumer: 0x9a8da5a0,
            family: "tst", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCINCGT() throws {
        try checkLogicalConditionalCell("TSTASRCINCGT", producer: 0x6a89051f, consumer: 0x9a8dd5a0,
            family: "tst", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCINCLE() throws {
        try checkLogicalConditionalCell("TSTASRCINCLE", producer: 0x6a89051f, consumer: 0x9a8dc5a0,
            family: "tst", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCINVGE() throws {
        try checkLogicalConditionalCell("TSTASRCINVGE", producer: 0x6a89051f, consumer: 0xda8db1a0,
            family: "tst", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCINVLT() throws {
        try checkLogicalConditionalCell("TSTASRCINVLT", producer: 0x6a89051f, consumer: 0xda8da1a0,
            family: "tst", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCINVGT() throws {
        try checkLogicalConditionalCell("TSTASRCINVGT", producer: 0x6a89051f, consumer: 0xda8dd1a0,
            family: "tst", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCINVLE() throws {
        try checkLogicalConditionalCell("TSTASRCINVLE", producer: 0x6a89051f, consumer: 0xda8dc1a0,
            family: "tst", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCNEGGE() throws {
        try checkLogicalConditionalCell("TSTASRCNEGGE", producer: 0x6a89051f, consumer: 0xda8db5a0,
            family: "tst", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCNEGLT() throws {
        try checkLogicalConditionalCell("TSTASRCNEGLT", producer: 0x6a89051f, consumer: 0xda8da5a0,
            family: "tst", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCNEGGT() throws {
        try checkLogicalConditionalCell("TSTASRCNEGGT", producer: 0x6a89051f, consumer: 0xda8dd5a0,
            family: "tst", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTASRCNEGLE() throws {
        try checkLogicalConditionalCell("TSTASRCNEGLE", producer: 0x6a89051f, consumer: 0xda8dc5a0,
            family: "tst", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: true, strictRefusals: [true, true, true, true])
    }

    func test338TSTRORBCONDGE() throws {
        try checkLogicalConditionalCell("TSTRORBCONDGE", producer: 0x6ac9051f, consumer: 0x5400004a,
            family: "tst", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORBCONDLT() throws {
        try checkLogicalConditionalCell("TSTRORBCONDLT", producer: 0x6ac9051f, consumer: 0x5400004b,
            family: "tst", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORBCONDGT() throws {
        try checkLogicalConditionalCell("TSTRORBCONDGT", producer: 0x6ac9051f, consumer: 0x5400004c,
            family: "tst", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORBCONDLE() throws {
        try checkLogicalConditionalCell("TSTRORBCONDLE", producer: 0x6ac9051f, consumer: 0x5400004d,
            family: "tst", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSETGE() throws {
        try checkLogicalConditionalCell("TSTRORCSETGE", producer: 0x6ac9051f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSETLT() throws {
        try checkLogicalConditionalCell("TSTRORCSETLT", producer: 0x6ac9051f, consumer: 0x9a9fa7e0,
            family: "tst", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSETGT() throws {
        try checkLogicalConditionalCell("TSTRORCSETGT", producer: 0x6ac9051f, consumer: 0x9a9fd7e0,
            family: "tst", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSETLE() throws {
        try checkLogicalConditionalCell("TSTRORCSETLE", producer: 0x6ac9051f, consumer: 0x9a9fc7e0,
            family: "tst", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSETMGE() throws {
        try checkLogicalConditionalCell("TSTRORCSETMGE", producer: 0x6ac9051f, consumer: 0xda9fb3e0,
            family: "tst", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSETMLT() throws {
        try checkLogicalConditionalCell("TSTRORCSETMLT", producer: 0x6ac9051f, consumer: 0xda9fa3e0,
            family: "tst", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSETMGT() throws {
        try checkLogicalConditionalCell("TSTRORCSETMGT", producer: 0x6ac9051f, consumer: 0xda9fd3e0,
            family: "tst", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSETMLE() throws {
        try checkLogicalConditionalCell("TSTRORCSETMLE", producer: 0x6ac9051f, consumer: 0xda9fc3e0,
            family: "tst", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSELGE() throws {
        try checkLogicalConditionalCell("TSTRORCSELGE", producer: 0x6ac9051f, consumer: 0x9a8ea1a0,
            family: "tst", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSELLT() throws {
        try checkLogicalConditionalCell("TSTRORCSELLT", producer: 0x6ac9051f, consumer: 0x9a8eb1a0,
            family: "tst", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSELGT() throws {
        try checkLogicalConditionalCell("TSTRORCSELGT", producer: 0x6ac9051f, consumer: 0x9a8ec1a0,
            family: "tst", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSELLE() throws {
        try checkLogicalConditionalCell("TSTRORCSELLE", producer: 0x6ac9051f, consumer: 0x9a8ed1a0,
            family: "tst", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSINCGE() throws {
        try checkLogicalConditionalCell("TSTRORCSINCGE", producer: 0x6ac9051f, consumer: 0x9a8ea5a0,
            family: "tst", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSINCLT() throws {
        try checkLogicalConditionalCell("TSTRORCSINCLT", producer: 0x6ac9051f, consumer: 0x9a8eb5a0,
            family: "tst", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSINCGT() throws {
        try checkLogicalConditionalCell("TSTRORCSINCGT", producer: 0x6ac9051f, consumer: 0x9a8ec5a0,
            family: "tst", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSINCLE() throws {
        try checkLogicalConditionalCell("TSTRORCSINCLE", producer: 0x6ac9051f, consumer: 0x9a8ed5a0,
            family: "tst", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSINVGE() throws {
        try checkLogicalConditionalCell("TSTRORCSINVGE", producer: 0x6ac9051f, consumer: 0xda8ea1a0,
            family: "tst", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSINVLT() throws {
        try checkLogicalConditionalCell("TSTRORCSINVLT", producer: 0x6ac9051f, consumer: 0xda8eb1a0,
            family: "tst", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSINVGT() throws {
        try checkLogicalConditionalCell("TSTRORCSINVGT", producer: 0x6ac9051f, consumer: 0xda8ec1a0,
            family: "tst", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSINVLE() throws {
        try checkLogicalConditionalCell("TSTRORCSINVLE", producer: 0x6ac9051f, consumer: 0xda8ed1a0,
            family: "tst", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSNEGGE() throws {
        try checkLogicalConditionalCell("TSTRORCSNEGGE", producer: 0x6ac9051f, consumer: 0xda8ea5a0,
            family: "tst", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSNEGLT() throws {
        try checkLogicalConditionalCell("TSTRORCSNEGLT", producer: 0x6ac9051f, consumer: 0xda8eb5a0,
            family: "tst", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSNEGGT() throws {
        try checkLogicalConditionalCell("TSTRORCSNEGGT", producer: 0x6ac9051f, consumer: 0xda8ec5a0,
            family: "tst", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCSNEGLE() throws {
        try checkLogicalConditionalCell("TSTRORCSNEGLE", producer: 0x6ac9051f, consumer: 0xda8ed5a0,
            family: "tst", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCINCGE() throws {
        try checkLogicalConditionalCell("TSTRORCINCGE", producer: 0x6ac9051f, consumer: 0x9a8db5a0,
            family: "tst", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCINCLT() throws {
        try checkLogicalConditionalCell("TSTRORCINCLT", producer: 0x6ac9051f, consumer: 0x9a8da5a0,
            family: "tst", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCINCGT() throws {
        try checkLogicalConditionalCell("TSTRORCINCGT", producer: 0x6ac9051f, consumer: 0x9a8dd5a0,
            family: "tst", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCINCLE() throws {
        try checkLogicalConditionalCell("TSTRORCINCLE", producer: 0x6ac9051f, consumer: 0x9a8dc5a0,
            family: "tst", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCINVGE() throws {
        try checkLogicalConditionalCell("TSTRORCINVGE", producer: 0x6ac9051f, consumer: 0xda8db1a0,
            family: "tst", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCINVLT() throws {
        try checkLogicalConditionalCell("TSTRORCINVLT", producer: 0x6ac9051f, consumer: 0xda8da1a0,
            family: "tst", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCINVGT() throws {
        try checkLogicalConditionalCell("TSTRORCINVGT", producer: 0x6ac9051f, consumer: 0xda8dd1a0,
            family: "tst", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCINVLE() throws {
        try checkLogicalConditionalCell("TSTRORCINVLE", producer: 0x6ac9051f, consumer: 0xda8dc1a0,
            family: "tst", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCNEGGE() throws {
        try checkLogicalConditionalCell("TSTRORCNEGGE", producer: 0x6ac9051f, consumer: 0xda8db5a0,
            family: "tst", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCNEGLT() throws {
        try checkLogicalConditionalCell("TSTRORCNEGLT", producer: 0x6ac9051f, consumer: 0xda8da5a0,
            family: "tst", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCNEGGT() throws {
        try checkLogicalConditionalCell("TSTRORCNEGGT", producer: 0x6ac9051f, consumer: 0xda8dd5a0,
            family: "tst", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338TSTRORCNEGLE() throws {
        try checkLogicalConditionalCell("TSTRORCNEGLE", producer: 0x6ac9051f, consumer: 0xda8dc5a0,
            family: "tst", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateBCONDGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateBCONDGE", producer: 0x7201010c, consumer: 0x5400004a,
            family: "ands", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateBCONDLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateBCONDLT", producer: 0x7201010c, consumer: 0x5400004b,
            family: "ands", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateBCONDGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateBCONDGT", producer: 0x7201010c, consumer: 0x5400004c,
            family: "ands", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateBCONDLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateBCONDLE", producer: 0x7201010c, consumer: 0x5400004d,
            family: "ands", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSETGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSETGE", producer: 0x7201010c, consumer: 0x9a9fb7e0,
            family: "ands", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSETLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSETLT", producer: 0x7201010c, consumer: 0x9a9fa7e0,
            family: "ands", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSETGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSETGT", producer: 0x7201010c, consumer: 0x9a9fd7e0,
            family: "ands", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSETLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSETLE", producer: 0x7201010c, consumer: 0x9a9fc7e0,
            family: "ands", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSETMGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSETMGE", producer: 0x7201010c, consumer: 0xda9fb3e0,
            family: "ands", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSETMLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSETMLT", producer: 0x7201010c, consumer: 0xda9fa3e0,
            family: "ands", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSETMGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSETMGT", producer: 0x7201010c, consumer: 0xda9fd3e0,
            family: "ands", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSETMLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSETMLE", producer: 0x7201010c, consumer: 0xda9fc3e0,
            family: "ands", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSELGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSELGE", producer: 0x7201010c, consumer: 0x9a8ea1a0,
            family: "ands", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSELLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSELLT", producer: 0x7201010c, consumer: 0x9a8eb1a0,
            family: "ands", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSELGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSELGT", producer: 0x7201010c, consumer: 0x9a8ec1a0,
            family: "ands", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSELLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSELLE", producer: 0x7201010c, consumer: 0x9a8ed1a0,
            family: "ands", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSINCGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSINCGE", producer: 0x7201010c, consumer: 0x9a8ea5a0,
            family: "ands", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSINCLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSINCLT", producer: 0x7201010c, consumer: 0x9a8eb5a0,
            family: "ands", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSINCGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSINCGT", producer: 0x7201010c, consumer: 0x9a8ec5a0,
            family: "ands", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSINCLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSINCLE", producer: 0x7201010c, consumer: 0x9a8ed5a0,
            family: "ands", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSINVGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSINVGE", producer: 0x7201010c, consumer: 0xda8ea1a0,
            family: "ands", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSINVLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSINVLT", producer: 0x7201010c, consumer: 0xda8eb1a0,
            family: "ands", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSINVGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSINVGT", producer: 0x7201010c, consumer: 0xda8ec1a0,
            family: "ands", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSINVLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSINVLE", producer: 0x7201010c, consumer: 0xda8ed1a0,
            family: "ands", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSNEGGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSNEGGE", producer: 0x7201010c, consumer: 0xda8ea5a0,
            family: "ands", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSNEGLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSNEGLT", producer: 0x7201010c, consumer: 0xda8eb5a0,
            family: "ands", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSNEGGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSNEGGT", producer: 0x7201010c, consumer: 0xda8ec5a0,
            family: "ands", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCSNEGLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCSNEGLE", producer: 0x7201010c, consumer: 0xda8ed5a0,
            family: "ands", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCINCGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCINCGE", producer: 0x7201010c, consumer: 0x9a8db5a0,
            family: "ands", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCINCLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCINCLT", producer: 0x7201010c, consumer: 0x9a8da5a0,
            family: "ands", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCINCGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCINCGT", producer: 0x7201010c, consumer: 0x9a8dd5a0,
            family: "ands", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCINCLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCINCLE", producer: 0x7201010c, consumer: 0x9a8dc5a0,
            family: "ands", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCINVGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCINVGE", producer: 0x7201010c, consumer: 0xda8db1a0,
            family: "ands", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCINVLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCINVLT", producer: 0x7201010c, consumer: 0xda8da1a0,
            family: "ands", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCINVGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCINVGT", producer: 0x7201010c, consumer: 0xda8dd1a0,
            family: "ands", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCINVLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCINVLE", producer: 0x7201010c, consumer: 0xda8dc1a0,
            family: "ands", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCNEGGE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCNEGGE", producer: 0x7201010c, consumer: 0xda8db5a0,
            family: "ands", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCNEGLT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCNEGLT", producer: 0x7201010c, consumer: 0xda8da5a0,
            family: "ands", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCNEGGT() throws {
        try checkLogicalConditionalCell("ANDSImmediateCNEGGT", producer: 0x7201010c, consumer: 0xda8dd5a0,
            family: "ands", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSImmediateCNEGLE() throws {
        try checkLogicalConditionalCell("ANDSImmediateCNEGLE", producer: 0x7201010c, consumer: 0xda8dc5a0,
            family: "ands", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterBCONDGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterBCONDGE", producer: 0x6a09010c, consumer: 0x5400004a,
            family: "ands", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterBCONDLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterBCONDLT", producer: 0x6a09010c, consumer: 0x5400004b,
            family: "ands", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterBCONDGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterBCONDGT", producer: 0x6a09010c, consumer: 0x5400004c,
            family: "ands", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterBCONDLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterBCONDLE", producer: 0x6a09010c, consumer: 0x5400004d,
            family: "ands", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSETGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSETGE", producer: 0x6a09010c, consumer: 0x9a9fb7e0,
            family: "ands", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSETLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSETLT", producer: 0x6a09010c, consumer: 0x9a9fa7e0,
            family: "ands", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSETGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSETGT", producer: 0x6a09010c, consumer: 0x9a9fd7e0,
            family: "ands", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSETLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSETLE", producer: 0x6a09010c, consumer: 0x9a9fc7e0,
            family: "ands", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSETMGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSETMGE", producer: 0x6a09010c, consumer: 0xda9fb3e0,
            family: "ands", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSETMLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSETMLT", producer: 0x6a09010c, consumer: 0xda9fa3e0,
            family: "ands", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSETMGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSETMGT", producer: 0x6a09010c, consumer: 0xda9fd3e0,
            family: "ands", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSETMLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSETMLE", producer: 0x6a09010c, consumer: 0xda9fc3e0,
            family: "ands", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSELGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSELGE", producer: 0x6a09010c, consumer: 0x9a8ea1a0,
            family: "ands", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSELLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSELLT", producer: 0x6a09010c, consumer: 0x9a8eb1a0,
            family: "ands", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSELGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSELGT", producer: 0x6a09010c, consumer: 0x9a8ec1a0,
            family: "ands", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSELLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSELLE", producer: 0x6a09010c, consumer: 0x9a8ed1a0,
            family: "ands", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSINCGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSINCGE", producer: 0x6a09010c, consumer: 0x9a8ea5a0,
            family: "ands", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSINCLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSINCLT", producer: 0x6a09010c, consumer: 0x9a8eb5a0,
            family: "ands", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSINCGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSINCGT", producer: 0x6a09010c, consumer: 0x9a8ec5a0,
            family: "ands", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSINCLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSINCLE", producer: 0x6a09010c, consumer: 0x9a8ed5a0,
            family: "ands", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSINVGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSINVGE", producer: 0x6a09010c, consumer: 0xda8ea1a0,
            family: "ands", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSINVLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSINVLT", producer: 0x6a09010c, consumer: 0xda8eb1a0,
            family: "ands", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSINVGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSINVGT", producer: 0x6a09010c, consumer: 0xda8ec1a0,
            family: "ands", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSINVLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSINVLE", producer: 0x6a09010c, consumer: 0xda8ed1a0,
            family: "ands", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSNEGGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSNEGGE", producer: 0x6a09010c, consumer: 0xda8ea5a0,
            family: "ands", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSNEGLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSNEGLT", producer: 0x6a09010c, consumer: 0xda8eb5a0,
            family: "ands", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSNEGGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSNEGGT", producer: 0x6a09010c, consumer: 0xda8ec5a0,
            family: "ands", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCSNEGLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCSNEGLE", producer: 0x6a09010c, consumer: 0xda8ed5a0,
            family: "ands", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCINCGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCINCGE", producer: 0x6a09010c, consumer: 0x9a8db5a0,
            family: "ands", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCINCLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCINCLT", producer: 0x6a09010c, consumer: 0x9a8da5a0,
            family: "ands", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCINCGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCINCGT", producer: 0x6a09010c, consumer: 0x9a8dd5a0,
            family: "ands", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCINCLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCINCLE", producer: 0x6a09010c, consumer: 0x9a8dc5a0,
            family: "ands", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCINVGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCINVGE", producer: 0x6a09010c, consumer: 0xda8db1a0,
            family: "ands", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCINVLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCINVLT", producer: 0x6a09010c, consumer: 0xda8da1a0,
            family: "ands", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCINVGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCINVGT", producer: 0x6a09010c, consumer: 0xda8dd1a0,
            family: "ands", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCINVLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCINVLE", producer: 0x6a09010c, consumer: 0xda8dc1a0,
            family: "ands", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCNEGGE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCNEGGE", producer: 0x6a09010c, consumer: 0xda8db5a0,
            family: "ands", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCNEGLT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCNEGLT", producer: 0x6a09010c, consumer: 0xda8da5a0,
            family: "ands", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCNEGGT() throws {
        try checkLogicalConditionalCell("ANDSRegisterCNEGGT", producer: 0x6a09010c, consumer: 0xda8dd5a0,
            family: "ands", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRegisterCNEGLE() throws {
        try checkLogicalConditionalCell("ANDSRegisterCNEGLE", producer: 0x6a09010c, consumer: 0xda8dc5a0,
            family: "ands", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLBCONDGE() throws {
        try checkLogicalConditionalCell("ANDSLSLBCONDGE", producer: 0x6a09050c, consumer: 0x5400004a,
            family: "ands", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLBCONDLT() throws {
        try checkLogicalConditionalCell("ANDSLSLBCONDLT", producer: 0x6a09050c, consumer: 0x5400004b,
            family: "ands", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLBCONDGT() throws {
        try checkLogicalConditionalCell("ANDSLSLBCONDGT", producer: 0x6a09050c, consumer: 0x5400004c,
            family: "ands", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLBCONDLE() throws {
        try checkLogicalConditionalCell("ANDSLSLBCONDLE", producer: 0x6a09050c, consumer: 0x5400004d,
            family: "ands", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSETGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSETGE", producer: 0x6a09050c, consumer: 0x9a9fb7e0,
            family: "ands", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSETLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSETLT", producer: 0x6a09050c, consumer: 0x9a9fa7e0,
            family: "ands", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSETGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSETGT", producer: 0x6a09050c, consumer: 0x9a9fd7e0,
            family: "ands", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSETLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSETLE", producer: 0x6a09050c, consumer: 0x9a9fc7e0,
            family: "ands", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSETMGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSETMGE", producer: 0x6a09050c, consumer: 0xda9fb3e0,
            family: "ands", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSETMLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSETMLT", producer: 0x6a09050c, consumer: 0xda9fa3e0,
            family: "ands", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSETMGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSETMGT", producer: 0x6a09050c, consumer: 0xda9fd3e0,
            family: "ands", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSETMLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSETMLE", producer: 0x6a09050c, consumer: 0xda9fc3e0,
            family: "ands", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSELGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSELGE", producer: 0x6a09050c, consumer: 0x9a8ea1a0,
            family: "ands", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSELLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSELLT", producer: 0x6a09050c, consumer: 0x9a8eb1a0,
            family: "ands", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSELGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSELGT", producer: 0x6a09050c, consumer: 0x9a8ec1a0,
            family: "ands", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSELLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSELLE", producer: 0x6a09050c, consumer: 0x9a8ed1a0,
            family: "ands", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSINCGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSINCGE", producer: 0x6a09050c, consumer: 0x9a8ea5a0,
            family: "ands", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSINCLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSINCLT", producer: 0x6a09050c, consumer: 0x9a8eb5a0,
            family: "ands", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSINCGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSINCGT", producer: 0x6a09050c, consumer: 0x9a8ec5a0,
            family: "ands", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSINCLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSINCLE", producer: 0x6a09050c, consumer: 0x9a8ed5a0,
            family: "ands", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSINVGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSINVGE", producer: 0x6a09050c, consumer: 0xda8ea1a0,
            family: "ands", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSINVLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSINVLT", producer: 0x6a09050c, consumer: 0xda8eb1a0,
            family: "ands", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSINVGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSINVGT", producer: 0x6a09050c, consumer: 0xda8ec1a0,
            family: "ands", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSINVLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSINVLE", producer: 0x6a09050c, consumer: 0xda8ed1a0,
            family: "ands", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSNEGGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSNEGGE", producer: 0x6a09050c, consumer: 0xda8ea5a0,
            family: "ands", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSNEGLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSNEGLT", producer: 0x6a09050c, consumer: 0xda8eb5a0,
            family: "ands", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSNEGGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCSNEGGT", producer: 0x6a09050c, consumer: 0xda8ec5a0,
            family: "ands", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCSNEGLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCSNEGLE", producer: 0x6a09050c, consumer: 0xda8ed5a0,
            family: "ands", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCINCGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCINCGE", producer: 0x6a09050c, consumer: 0x9a8db5a0,
            family: "ands", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCINCLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCINCLT", producer: 0x6a09050c, consumer: 0x9a8da5a0,
            family: "ands", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCINCGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCINCGT", producer: 0x6a09050c, consumer: 0x9a8dd5a0,
            family: "ands", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCINCLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCINCLE", producer: 0x6a09050c, consumer: 0x9a8dc5a0,
            family: "ands", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCINVGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCINVGE", producer: 0x6a09050c, consumer: 0xda8db1a0,
            family: "ands", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCINVLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCINVLT", producer: 0x6a09050c, consumer: 0xda8da1a0,
            family: "ands", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCINVGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCINVGT", producer: 0x6a09050c, consumer: 0xda8dd1a0,
            family: "ands", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCINVLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCINVLE", producer: 0x6a09050c, consumer: 0xda8dc1a0,
            family: "ands", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCNEGGE() throws {
        try checkLogicalConditionalCell("ANDSLSLCNEGGE", producer: 0x6a09050c, consumer: 0xda8db5a0,
            family: "ands", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCNEGLT() throws {
        try checkLogicalConditionalCell("ANDSLSLCNEGLT", producer: 0x6a09050c, consumer: 0xda8da5a0,
            family: "ands", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCNEGGT() throws {
        try checkLogicalConditionalCell("ANDSLSLCNEGGT", producer: 0x6a09050c, consumer: 0xda8dd5a0,
            family: "ands", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSLCNEGLE() throws {
        try checkLogicalConditionalCell("ANDSLSLCNEGLE", producer: 0x6a09050c, consumer: 0xda8dc5a0,
            family: "ands", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRBCONDGE() throws {
        try checkLogicalConditionalCell("ANDSLSRBCONDGE", producer: 0x6a49050c, consumer: 0x5400004a,
            family: "ands", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRBCONDLT() throws {
        try checkLogicalConditionalCell("ANDSLSRBCONDLT", producer: 0x6a49050c, consumer: 0x5400004b,
            family: "ands", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRBCONDGT() throws {
        try checkLogicalConditionalCell("ANDSLSRBCONDGT", producer: 0x6a49050c, consumer: 0x5400004c,
            family: "ands", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRBCONDLE() throws {
        try checkLogicalConditionalCell("ANDSLSRBCONDLE", producer: 0x6a49050c, consumer: 0x5400004d,
            family: "ands", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSETGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSETGE", producer: 0x6a49050c, consumer: 0x9a9fb7e0,
            family: "ands", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSETLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSETLT", producer: 0x6a49050c, consumer: 0x9a9fa7e0,
            family: "ands", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSETGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSETGT", producer: 0x6a49050c, consumer: 0x9a9fd7e0,
            family: "ands", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSETLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSETLE", producer: 0x6a49050c, consumer: 0x9a9fc7e0,
            family: "ands", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSETMGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSETMGE", producer: 0x6a49050c, consumer: 0xda9fb3e0,
            family: "ands", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSETMLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSETMLT", producer: 0x6a49050c, consumer: 0xda9fa3e0,
            family: "ands", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSETMGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSETMGT", producer: 0x6a49050c, consumer: 0xda9fd3e0,
            family: "ands", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSETMLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSETMLE", producer: 0x6a49050c, consumer: 0xda9fc3e0,
            family: "ands", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSELGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSELGE", producer: 0x6a49050c, consumer: 0x9a8ea1a0,
            family: "ands", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSELLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSELLT", producer: 0x6a49050c, consumer: 0x9a8eb1a0,
            family: "ands", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSELGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSELGT", producer: 0x6a49050c, consumer: 0x9a8ec1a0,
            family: "ands", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSELLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSELLE", producer: 0x6a49050c, consumer: 0x9a8ed1a0,
            family: "ands", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSINCGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSINCGE", producer: 0x6a49050c, consumer: 0x9a8ea5a0,
            family: "ands", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSINCLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSINCLT", producer: 0x6a49050c, consumer: 0x9a8eb5a0,
            family: "ands", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSINCGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSINCGT", producer: 0x6a49050c, consumer: 0x9a8ec5a0,
            family: "ands", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSINCLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSINCLE", producer: 0x6a49050c, consumer: 0x9a8ed5a0,
            family: "ands", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSINVGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSINVGE", producer: 0x6a49050c, consumer: 0xda8ea1a0,
            family: "ands", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSINVLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSINVLT", producer: 0x6a49050c, consumer: 0xda8eb1a0,
            family: "ands", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSINVGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSINVGT", producer: 0x6a49050c, consumer: 0xda8ec1a0,
            family: "ands", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSINVLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSINVLE", producer: 0x6a49050c, consumer: 0xda8ed1a0,
            family: "ands", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSNEGGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSNEGGE", producer: 0x6a49050c, consumer: 0xda8ea5a0,
            family: "ands", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSNEGLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSNEGLT", producer: 0x6a49050c, consumer: 0xda8eb5a0,
            family: "ands", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSNEGGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCSNEGGT", producer: 0x6a49050c, consumer: 0xda8ec5a0,
            family: "ands", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCSNEGLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCSNEGLE", producer: 0x6a49050c, consumer: 0xda8ed5a0,
            family: "ands", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCINCGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCINCGE", producer: 0x6a49050c, consumer: 0x9a8db5a0,
            family: "ands", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCINCLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCINCLT", producer: 0x6a49050c, consumer: 0x9a8da5a0,
            family: "ands", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCINCGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCINCGT", producer: 0x6a49050c, consumer: 0x9a8dd5a0,
            family: "ands", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCINCLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCINCLE", producer: 0x6a49050c, consumer: 0x9a8dc5a0,
            family: "ands", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCINVGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCINVGE", producer: 0x6a49050c, consumer: 0xda8db1a0,
            family: "ands", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCINVLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCINVLT", producer: 0x6a49050c, consumer: 0xda8da1a0,
            family: "ands", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCINVGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCINVGT", producer: 0x6a49050c, consumer: 0xda8dd1a0,
            family: "ands", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCINVLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCINVLE", producer: 0x6a49050c, consumer: 0xda8dc1a0,
            family: "ands", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCNEGGE() throws {
        try checkLogicalConditionalCell("ANDSLSRCNEGGE", producer: 0x6a49050c, consumer: 0xda8db5a0,
            family: "ands", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCNEGLT() throws {
        try checkLogicalConditionalCell("ANDSLSRCNEGLT", producer: 0x6a49050c, consumer: 0xda8da5a0,
            family: "ands", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCNEGGT() throws {
        try checkLogicalConditionalCell("ANDSLSRCNEGGT", producer: 0x6a49050c, consumer: 0xda8dd5a0,
            family: "ands", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, true, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSLSRCNEGLE() throws {
        try checkLogicalConditionalCell("ANDSLSRCNEGLE", producer: 0x6a49050c, consumer: 0xda8dc5a0,
            family: "ands", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, false, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRBCONDGE() throws {
        try checkLogicalConditionalCell("ANDSASRBCONDGE", producer: 0x6a89050c, consumer: 0x5400004a,
            family: "ands", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRBCONDLT() throws {
        try checkLogicalConditionalCell("ANDSASRBCONDLT", producer: 0x6a89050c, consumer: 0x5400004b,
            family: "ands", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRBCONDGT() throws {
        try checkLogicalConditionalCell("ANDSASRBCONDGT", producer: 0x6a89050c, consumer: 0x5400004c,
            family: "ands", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRBCONDLE() throws {
        try checkLogicalConditionalCell("ANDSASRBCONDLE", producer: 0x6a89050c, consumer: 0x5400004d,
            family: "ands", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSETGE() throws {
        try checkLogicalConditionalCell("ANDSASRCSETGE", producer: 0x6a89050c, consumer: 0x9a9fb7e0,
            family: "ands", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSETLT() throws {
        try checkLogicalConditionalCell("ANDSASRCSETLT", producer: 0x6a89050c, consumer: 0x9a9fa7e0,
            family: "ands", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSETGT() throws {
        try checkLogicalConditionalCell("ANDSASRCSETGT", producer: 0x6a89050c, consumer: 0x9a9fd7e0,
            family: "ands", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSETLE() throws {
        try checkLogicalConditionalCell("ANDSASRCSETLE", producer: 0x6a89050c, consumer: 0x9a9fc7e0,
            family: "ands", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSETMGE() throws {
        try checkLogicalConditionalCell("ANDSASRCSETMGE", producer: 0x6a89050c, consumer: 0xda9fb3e0,
            family: "ands", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSETMLT() throws {
        try checkLogicalConditionalCell("ANDSASRCSETMLT", producer: 0x6a89050c, consumer: 0xda9fa3e0,
            family: "ands", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSETMGT() throws {
        try checkLogicalConditionalCell("ANDSASRCSETMGT", producer: 0x6a89050c, consumer: 0xda9fd3e0,
            family: "ands", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSETMLE() throws {
        try checkLogicalConditionalCell("ANDSASRCSETMLE", producer: 0x6a89050c, consumer: 0xda9fc3e0,
            family: "ands", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSELGE() throws {
        try checkLogicalConditionalCell("ANDSASRCSELGE", producer: 0x6a89050c, consumer: 0x9a8ea1a0,
            family: "ands", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSELLT() throws {
        try checkLogicalConditionalCell("ANDSASRCSELLT", producer: 0x6a89050c, consumer: 0x9a8eb1a0,
            family: "ands", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSELGT() throws {
        try checkLogicalConditionalCell("ANDSASRCSELGT", producer: 0x6a89050c, consumer: 0x9a8ec1a0,
            family: "ands", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSELLE() throws {
        try checkLogicalConditionalCell("ANDSASRCSELLE", producer: 0x6a89050c, consumer: 0x9a8ed1a0,
            family: "ands", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSINCGE() throws {
        try checkLogicalConditionalCell("ANDSASRCSINCGE", producer: 0x6a89050c, consumer: 0x9a8ea5a0,
            family: "ands", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSINCLT() throws {
        try checkLogicalConditionalCell("ANDSASRCSINCLT", producer: 0x6a89050c, consumer: 0x9a8eb5a0,
            family: "ands", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSINCGT() throws {
        try checkLogicalConditionalCell("ANDSASRCSINCGT", producer: 0x6a89050c, consumer: 0x9a8ec5a0,
            family: "ands", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSINCLE() throws {
        try checkLogicalConditionalCell("ANDSASRCSINCLE", producer: 0x6a89050c, consumer: 0x9a8ed5a0,
            family: "ands", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSINVGE() throws {
        try checkLogicalConditionalCell("ANDSASRCSINVGE", producer: 0x6a89050c, consumer: 0xda8ea1a0,
            family: "ands", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSINVLT() throws {
        try checkLogicalConditionalCell("ANDSASRCSINVLT", producer: 0x6a89050c, consumer: 0xda8eb1a0,
            family: "ands", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSINVGT() throws {
        try checkLogicalConditionalCell("ANDSASRCSINVGT", producer: 0x6a89050c, consumer: 0xda8ec1a0,
            family: "ands", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSINVLE() throws {
        try checkLogicalConditionalCell("ANDSASRCSINVLE", producer: 0x6a89050c, consumer: 0xda8ed1a0,
            family: "ands", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSNEGGE() throws {
        try checkLogicalConditionalCell("ANDSASRCSNEGGE", producer: 0x6a89050c, consumer: 0xda8ea5a0,
            family: "ands", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSNEGLT() throws {
        try checkLogicalConditionalCell("ANDSASRCSNEGLT", producer: 0x6a89050c, consumer: 0xda8eb5a0,
            family: "ands", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSNEGGT() throws {
        try checkLogicalConditionalCell("ANDSASRCSNEGGT", producer: 0x6a89050c, consumer: 0xda8ec5a0,
            family: "ands", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCSNEGLE() throws {
        try checkLogicalConditionalCell("ANDSASRCSNEGLE", producer: 0x6a89050c, consumer: 0xda8ed5a0,
            family: "ands", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCINCGE() throws {
        try checkLogicalConditionalCell("ANDSASRCINCGE", producer: 0x6a89050c, consumer: 0x9a8db5a0,
            family: "ands", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCINCLT() throws {
        try checkLogicalConditionalCell("ANDSASRCINCLT", producer: 0x6a89050c, consumer: 0x9a8da5a0,
            family: "ands", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCINCGT() throws {
        try checkLogicalConditionalCell("ANDSASRCINCGT", producer: 0x6a89050c, consumer: 0x9a8dd5a0,
            family: "ands", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCINCLE() throws {
        try checkLogicalConditionalCell("ANDSASRCINCLE", producer: 0x6a89050c, consumer: 0x9a8dc5a0,
            family: "ands", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCINVGE() throws {
        try checkLogicalConditionalCell("ANDSASRCINVGE", producer: 0x6a89050c, consumer: 0xda8db1a0,
            family: "ands", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCINVLT() throws {
        try checkLogicalConditionalCell("ANDSASRCINVLT", producer: 0x6a89050c, consumer: 0xda8da1a0,
            family: "ands", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCINVGT() throws {
        try checkLogicalConditionalCell("ANDSASRCINVGT", producer: 0x6a89050c, consumer: 0xda8dd1a0,
            family: "ands", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCINVLE() throws {
        try checkLogicalConditionalCell("ANDSASRCINVLE", producer: 0x6a89050c, consumer: 0xda8dc1a0,
            family: "ands", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCNEGGE() throws {
        try checkLogicalConditionalCell("ANDSASRCNEGGE", producer: 0x6a89050c, consumer: 0xda8db5a0,
            family: "ands", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCNEGLT() throws {
        try checkLogicalConditionalCell("ANDSASRCNEGLT", producer: 0x6a89050c, consumer: 0xda8da5a0,
            family: "ands", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCNEGGT() throws {
        try checkLogicalConditionalCell("ANDSASRCNEGGT", producer: 0x6a89050c, consumer: 0xda8dd5a0,
            family: "ands", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSASRCNEGLE() throws {
        try checkLogicalConditionalCell("ANDSASRCNEGLE", producer: 0x6a89050c, consumer: 0xda8dc5a0,
            family: "ands", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORBCONDGE() throws {
        try checkLogicalConditionalCell("ANDSRORBCONDGE", producer: 0x6ac9050c, consumer: 0x5400004a,
            family: "ands", mnemonic: "b.ge", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORBCONDLT() throws {
        try checkLogicalConditionalCell("ANDSRORBCONDLT", producer: 0x6ac9050c, consumer: 0x5400004b,
            family: "ands", mnemonic: "b.lt", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORBCONDGT() throws {
        try checkLogicalConditionalCell("ANDSRORBCONDGT", producer: 0x6ac9050c, consumer: 0x5400004c,
            family: "ands", mnemonic: "b.gt", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORBCONDLE() throws {
        try checkLogicalConditionalCell("ANDSRORBCONDLE", producer: 0x6ac9050c, consumer: 0x5400004d,
            family: "ands", mnemonic: "b.le", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSETGE() throws {
        try checkLogicalConditionalCell("ANDSRORCSETGE", producer: 0x6ac9050c, consumer: 0x9a9fb7e0,
            family: "ands", mnemonic: "cset", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSETLT() throws {
        try checkLogicalConditionalCell("ANDSRORCSETLT", producer: 0x6ac9050c, consumer: 0x9a9fa7e0,
            family: "ands", mnemonic: "cset", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSETGT() throws {
        try checkLogicalConditionalCell("ANDSRORCSETGT", producer: 0x6ac9050c, consumer: 0x9a9fd7e0,
            family: "ands", mnemonic: "cset", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSETLE() throws {
        try checkLogicalConditionalCell("ANDSRORCSETLE", producer: 0x6ac9050c, consumer: 0x9a9fc7e0,
            family: "ands", mnemonic: "cset", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSETMGE() throws {
        try checkLogicalConditionalCell("ANDSRORCSETMGE", producer: 0x6ac9050c, consumer: 0xda9fb3e0,
            family: "ands", mnemonic: "csetm", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSETMLT() throws {
        try checkLogicalConditionalCell("ANDSRORCSETMLT", producer: 0x6ac9050c, consumer: 0xda9fa3e0,
            family: "ands", mnemonic: "csetm", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSETMGT() throws {
        try checkLogicalConditionalCell("ANDSRORCSETMGT", producer: 0x6ac9050c, consumer: 0xda9fd3e0,
            family: "ands", mnemonic: "csetm", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSETMLE() throws {
        try checkLogicalConditionalCell("ANDSRORCSETMLE", producer: 0x6ac9050c, consumer: 0xda9fc3e0,
            family: "ands", mnemonic: "csetm", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSELGE() throws {
        try checkLogicalConditionalCell("ANDSRORCSELGE", producer: 0x6ac9050c, consumer: 0x9a8ea1a0,
            family: "ands", mnemonic: "csel", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSELLT() throws {
        try checkLogicalConditionalCell("ANDSRORCSELLT", producer: 0x6ac9050c, consumer: 0x9a8eb1a0,
            family: "ands", mnemonic: "csel", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSELGT() throws {
        try checkLogicalConditionalCell("ANDSRORCSELGT", producer: 0x6ac9050c, consumer: 0x9a8ec1a0,
            family: "ands", mnemonic: "csel", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSELLE() throws {
        try checkLogicalConditionalCell("ANDSRORCSELLE", producer: 0x6ac9050c, consumer: 0x9a8ed1a0,
            family: "ands", mnemonic: "csel", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSINCGE() throws {
        try checkLogicalConditionalCell("ANDSRORCSINCGE", producer: 0x6ac9050c, consumer: 0x9a8ea5a0,
            family: "ands", mnemonic: "csinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSINCLT() throws {
        try checkLogicalConditionalCell("ANDSRORCSINCLT", producer: 0x6ac9050c, consumer: 0x9a8eb5a0,
            family: "ands", mnemonic: "csinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSINCGT() throws {
        try checkLogicalConditionalCell("ANDSRORCSINCGT", producer: 0x6ac9050c, consumer: 0x9a8ec5a0,
            family: "ands", mnemonic: "csinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSINCLE() throws {
        try checkLogicalConditionalCell("ANDSRORCSINCLE", producer: 0x6ac9050c, consumer: 0x9a8ed5a0,
            family: "ands", mnemonic: "csinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSINVGE() throws {
        try checkLogicalConditionalCell("ANDSRORCSINVGE", producer: 0x6ac9050c, consumer: 0xda8ea1a0,
            family: "ands", mnemonic: "csinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSINVLT() throws {
        try checkLogicalConditionalCell("ANDSRORCSINVLT", producer: 0x6ac9050c, consumer: 0xda8eb1a0,
            family: "ands", mnemonic: "csinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSINVGT() throws {
        try checkLogicalConditionalCell("ANDSRORCSINVGT", producer: 0x6ac9050c, consumer: 0xda8ec1a0,
            family: "ands", mnemonic: "csinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSINVLE() throws {
        try checkLogicalConditionalCell("ANDSRORCSINVLE", producer: 0x6ac9050c, consumer: 0xda8ed1a0,
            family: "ands", mnemonic: "csinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSNEGGE() throws {
        try checkLogicalConditionalCell("ANDSRORCSNEGGE", producer: 0x6ac9050c, consumer: 0xda8ea5a0,
            family: "ands", mnemonic: "csneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSNEGLT() throws {
        try checkLogicalConditionalCell("ANDSRORCSNEGLT", producer: 0x6ac9050c, consumer: 0xda8eb5a0,
            family: "ands", mnemonic: "csneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSNEGGT() throws {
        try checkLogicalConditionalCell("ANDSRORCSNEGGT", producer: 0x6ac9050c, consumer: 0xda8ec5a0,
            family: "ands", mnemonic: "csneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCSNEGLE() throws {
        try checkLogicalConditionalCell("ANDSRORCSNEGLE", producer: 0x6ac9050c, consumer: 0xda8ed5a0,
            family: "ands", mnemonic: "csneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCINCGE() throws {
        try checkLogicalConditionalCell("ANDSRORCINCGE", producer: 0x6ac9050c, consumer: 0x9a8db5a0,
            family: "ands", mnemonic: "cinc", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCINCLT() throws {
        try checkLogicalConditionalCell("ANDSRORCINCLT", producer: 0x6ac9050c, consumer: 0x9a8da5a0,
            family: "ands", mnemonic: "cinc", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCINCGT() throws {
        try checkLogicalConditionalCell("ANDSRORCINCGT", producer: 0x6ac9050c, consumer: 0x9a8dd5a0,
            family: "ands", mnemonic: "cinc", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCINCLE() throws {
        try checkLogicalConditionalCell("ANDSRORCINCLE", producer: 0x6ac9050c, consumer: 0x9a8dc5a0,
            family: "ands", mnemonic: "cinc", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCINVGE() throws {
        try checkLogicalConditionalCell("ANDSRORCINVGE", producer: 0x6ac9050c, consumer: 0xda8db1a0,
            family: "ands", mnemonic: "cinv", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCINVLT() throws {
        try checkLogicalConditionalCell("ANDSRORCINVLT", producer: 0x6ac9050c, consumer: 0xda8da1a0,
            family: "ands", mnemonic: "cinv", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCINVGT() throws {
        try checkLogicalConditionalCell("ANDSRORCINVGT", producer: 0x6ac9050c, consumer: 0xda8dd1a0,
            family: "ands", mnemonic: "cinv", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCINVLE() throws {
        try checkLogicalConditionalCell("ANDSRORCINVLE", producer: 0x6ac9050c, consumer: 0xda8dc1a0,
            family: "ands", mnemonic: "cinv", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCNEGGE() throws {
        try checkLogicalConditionalCell("ANDSRORCNEGGE", producer: 0x6ac9050c, consumer: 0xda8db5a0,
            family: "ands", mnemonic: "cneg", suffix: "ge", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCNEGLT() throws {
        try checkLogicalConditionalCell("ANDSRORCNEGLT", producer: 0x6ac9050c, consumer: 0xda8da5a0,
            family: "ands", mnemonic: "cneg", suffix: "lt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCNEGGT() throws {
        try checkLogicalConditionalCell("ANDSRORCNEGGT", producer: 0x6ac9050c, consumer: 0xda8dd5a0,
            family: "ands", mnemonic: "cneg", suffix: "gt", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338ANDSRORCNEGLE() throws {
        try checkLogicalConditionalCell("ANDSRORCNEGLE", producer: 0x6ac9050c, consumer: 0xda8dc5a0,
            family: "ands", mnemonic: "cneg", suffix: "le", chain: false,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0xffffffff,
            expected: [true, true, true, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDGEExecuted", producer: 0x7a41a909, consumer: 0x5400004a,
            family: "ccmp", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDGEFallbackTrue", producer: 0x7a41a909, consumer: 0x5400004a,
            family: "ccmp", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDGEFallbackFalse", producer: 0x7a41a908, consumer: 0x5400004a,
            family: "ccmp", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDLTExecuted", producer: 0x7a41a908, consumer: 0x5400004b,
            family: "ccmp", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDLTFallbackTrue", producer: 0x7a41a908, consumer: 0x5400004b,
            family: "ccmp", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDLTFallbackFalse", producer: 0x7a41a909, consumer: 0x5400004b,
            family: "ccmp", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDGTExecuted", producer: 0x7a41a909, consumer: 0x5400004c,
            family: "ccmp", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDGTFallbackTrue", producer: 0x7a41a909, consumer: 0x5400004c,
            family: "ccmp", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDGTFallbackFalse", producer: 0x7a41a90d, consumer: 0x5400004c,
            family: "ccmp", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDLEExecuted", producer: 0x7a41a90d, consumer: 0x5400004d,
            family: "ccmp", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDLEFallbackTrue", producer: 0x7a41a90d, consumer: 0x5400004d,
            family: "ccmp", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateBCONDLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateBCONDLEFallbackFalse", producer: 0x7a41a909, consumer: 0x5400004d,
            family: "ccmp", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETGEExecuted", producer: 0x7a41a909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETGEFallbackTrue", producer: 0x7a41a909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETGEFallbackFalse", producer: 0x7a41a908, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETLTExecuted", producer: 0x7a41a908, consumer: 0x9a9fa7e0,
            family: "ccmp", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETLTFallbackTrue", producer: 0x7a41a908, consumer: 0x9a9fa7e0,
            family: "ccmp", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETLTFallbackFalse", producer: 0x7a41a909, consumer: 0x9a9fa7e0,
            family: "ccmp", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETGTExecuted", producer: 0x7a41a909, consumer: 0x9a9fd7e0,
            family: "ccmp", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETGTFallbackTrue", producer: 0x7a41a909, consumer: 0x9a9fd7e0,
            family: "ccmp", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETGTFallbackFalse", producer: 0x7a41a90d, consumer: 0x9a9fd7e0,
            family: "ccmp", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETLEExecuted", producer: 0x7a41a90d, consumer: 0x9a9fc7e0,
            family: "ccmp", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETLEFallbackTrue", producer: 0x7a41a90d, consumer: 0x9a9fc7e0,
            family: "ccmp", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETLEFallbackFalse", producer: 0x7a41a909, consumer: 0x9a9fc7e0,
            family: "ccmp", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMGEExecuted", producer: 0x7a41a909, consumer: 0xda9fb3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMGEFallbackTrue", producer: 0x7a41a909, consumer: 0xda9fb3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMGEFallbackFalse", producer: 0x7a41a908, consumer: 0xda9fb3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMLTExecuted", producer: 0x7a41a908, consumer: 0xda9fa3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMLTFallbackTrue", producer: 0x7a41a908, consumer: 0xda9fa3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMLTFallbackFalse", producer: 0x7a41a909, consumer: 0xda9fa3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMGTExecuted", producer: 0x7a41a909, consumer: 0xda9fd3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMGTFallbackTrue", producer: 0x7a41a909, consumer: 0xda9fd3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMGTFallbackFalse", producer: 0x7a41a90d, consumer: 0xda9fd3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMLEExecuted", producer: 0x7a41a90d, consumer: 0xda9fc3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMLEFallbackTrue", producer: 0x7a41a90d, consumer: 0xda9fc3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSETMLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSETMLEFallbackFalse", producer: 0x7a41a909, consumer: 0xda9fc3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELGEExecuted", producer: 0x7a41a909, consumer: 0x9a8ea1a0,
            family: "ccmp", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELGEFallbackTrue", producer: 0x7a41a909, consumer: 0x9a8ea1a0,
            family: "ccmp", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELGEFallbackFalse", producer: 0x7a41a908, consumer: 0x9a8ea1a0,
            family: "ccmp", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELLTExecuted", producer: 0x7a41a908, consumer: 0x9a8eb1a0,
            family: "ccmp", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELLTFallbackTrue", producer: 0x7a41a908, consumer: 0x9a8eb1a0,
            family: "ccmp", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELLTFallbackFalse", producer: 0x7a41a909, consumer: 0x9a8eb1a0,
            family: "ccmp", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELGTExecuted", producer: 0x7a41a909, consumer: 0x9a8ec1a0,
            family: "ccmp", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELGTFallbackTrue", producer: 0x7a41a909, consumer: 0x9a8ec1a0,
            family: "ccmp", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELGTFallbackFalse", producer: 0x7a41a90d, consumer: 0x9a8ec1a0,
            family: "ccmp", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELLEExecuted", producer: 0x7a41a90d, consumer: 0x9a8ed1a0,
            family: "ccmp", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELLEFallbackTrue", producer: 0x7a41a90d, consumer: 0x9a8ed1a0,
            family: "ccmp", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSELLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSELLEFallbackFalse", producer: 0x7a41a909, consumer: 0x9a8ed1a0,
            family: "ccmp", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCGEExecuted", producer: 0x7a41a909, consumer: 0x9a8ea5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCGEFallbackTrue", producer: 0x7a41a909, consumer: 0x9a8ea5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCGEFallbackFalse", producer: 0x7a41a908, consumer: 0x9a8ea5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCLTExecuted", producer: 0x7a41a908, consumer: 0x9a8eb5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCLTFallbackTrue", producer: 0x7a41a908, consumer: 0x9a8eb5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCLTFallbackFalse", producer: 0x7a41a909, consumer: 0x9a8eb5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCGTExecuted", producer: 0x7a41a909, consumer: 0x9a8ec5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCGTFallbackTrue", producer: 0x7a41a909, consumer: 0x9a8ec5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCGTFallbackFalse", producer: 0x7a41a90d, consumer: 0x9a8ec5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCLEExecuted", producer: 0x7a41a90d, consumer: 0x9a8ed5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCLEFallbackTrue", producer: 0x7a41a90d, consumer: 0x9a8ed5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINCLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINCLEFallbackFalse", producer: 0x7a41a909, consumer: 0x9a8ed5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVGEExecuted", producer: 0x7a41a909, consumer: 0xda8ea1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVGEFallbackTrue", producer: 0x7a41a909, consumer: 0xda8ea1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVGEFallbackFalse", producer: 0x7a41a908, consumer: 0xda8ea1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVLTExecuted", producer: 0x7a41a908, consumer: 0xda8eb1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVLTFallbackTrue", producer: 0x7a41a908, consumer: 0xda8eb1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVLTFallbackFalse", producer: 0x7a41a909, consumer: 0xda8eb1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVGTExecuted", producer: 0x7a41a909, consumer: 0xda8ec1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVGTFallbackTrue", producer: 0x7a41a909, consumer: 0xda8ec1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVGTFallbackFalse", producer: 0x7a41a90d, consumer: 0xda8ec1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVLEExecuted", producer: 0x7a41a90d, consumer: 0xda8ed1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVLEFallbackTrue", producer: 0x7a41a90d, consumer: 0xda8ed1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSINVLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSINVLEFallbackFalse", producer: 0x7a41a909, consumer: 0xda8ed1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGGEExecuted", producer: 0x7a41a909, consumer: 0xda8ea5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGGEFallbackTrue", producer: 0x7a41a909, consumer: 0xda8ea5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGGEFallbackFalse", producer: 0x7a41a908, consumer: 0xda8ea5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGLTExecuted", producer: 0x7a41a908, consumer: 0xda8eb5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGLTFallbackTrue", producer: 0x7a41a908, consumer: 0xda8eb5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGLTFallbackFalse", producer: 0x7a41a909, consumer: 0xda8eb5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGGTExecuted", producer: 0x7a41a909, consumer: 0xda8ec5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGGTFallbackTrue", producer: 0x7a41a909, consumer: 0xda8ec5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGGTFallbackFalse", producer: 0x7a41a90d, consumer: 0xda8ec5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGLEExecuted", producer: 0x7a41a90d, consumer: 0xda8ed5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGLEFallbackTrue", producer: 0x7a41a90d, consumer: 0xda8ed5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCSNEGLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCSNEGLEFallbackFalse", producer: 0x7a41a909, consumer: 0xda8ed5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCGEExecuted", producer: 0x7a41a909, consumer: 0x9a8db5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCGEFallbackTrue", producer: 0x7a41a909, consumer: 0x9a8db5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCGEFallbackFalse", producer: 0x7a41a908, consumer: 0x9a8db5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCLTExecuted", producer: 0x7a41a908, consumer: 0x9a8da5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCLTFallbackTrue", producer: 0x7a41a908, consumer: 0x9a8da5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCLTFallbackFalse", producer: 0x7a41a909, consumer: 0x9a8da5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCGTExecuted", producer: 0x7a41a909, consumer: 0x9a8dd5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCGTFallbackTrue", producer: 0x7a41a909, consumer: 0x9a8dd5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCGTFallbackFalse", producer: 0x7a41a90d, consumer: 0x9a8dd5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCLEExecuted", producer: 0x7a41a90d, consumer: 0x9a8dc5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCLEFallbackTrue", producer: 0x7a41a90d, consumer: 0x9a8dc5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINCLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINCLEFallbackFalse", producer: 0x7a41a909, consumer: 0x9a8dc5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVGEExecuted", producer: 0x7a41a909, consumer: 0xda8db1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVGEFallbackTrue", producer: 0x7a41a909, consumer: 0xda8db1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVGEFallbackFalse", producer: 0x7a41a908, consumer: 0xda8db1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVLTExecuted", producer: 0x7a41a908, consumer: 0xda8da1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVLTFallbackTrue", producer: 0x7a41a908, consumer: 0xda8da1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVLTFallbackFalse", producer: 0x7a41a909, consumer: 0xda8da1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVGTExecuted", producer: 0x7a41a909, consumer: 0xda8dd1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVGTFallbackTrue", producer: 0x7a41a909, consumer: 0xda8dd1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVGTFallbackFalse", producer: 0x7a41a90d, consumer: 0xda8dd1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVLEExecuted", producer: 0x7a41a90d, consumer: 0xda8dc1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVLEFallbackTrue", producer: 0x7a41a90d, consumer: 0xda8dc1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCINVLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCINVLEFallbackFalse", producer: 0x7a41a909, consumer: 0xda8dc1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGGEExecuted", producer: 0x7a41a909, consumer: 0xda8db5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGGEFallbackTrue", producer: 0x7a41a909, consumer: 0xda8db5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGGEFallbackFalse", producer: 0x7a41a908, consumer: 0xda8db5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGLTExecuted", producer: 0x7a41a908, consumer: 0xda8da5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGLTFallbackTrue", producer: 0x7a41a908, consumer: 0xda8da5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGLTFallbackFalse", producer: 0x7a41a909, consumer: 0xda8da5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGGTExecuted", producer: 0x7a41a909, consumer: 0xda8dd5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGGTFallbackTrue", producer: 0x7a41a909, consumer: 0xda8dd5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGGTFallbackFalse", producer: 0x7a41a90d, consumer: 0xda8dd5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGLEExecuted", producer: 0x7a41a90d, consumer: 0xda8dc5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGLEFallbackTrue", producer: 0x7a41a90d, consumer: 0xda8dc5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateCNEGLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateCNEGLEFallbackFalse", producer: 0x7a41a909, consumer: 0xda8dc5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDGEExecuted", producer: 0x7a49a109, consumer: 0x5400004a,
            family: "ccmp", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDGEFallbackTrue", producer: 0x7a49a109, consumer: 0x5400004a,
            family: "ccmp", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDGEFallbackFalse", producer: 0x7a49a108, consumer: 0x5400004a,
            family: "ccmp", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDLTExecuted", producer: 0x7a49a108, consumer: 0x5400004b,
            family: "ccmp", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDLTFallbackTrue", producer: 0x7a49a108, consumer: 0x5400004b,
            family: "ccmp", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDLTFallbackFalse", producer: 0x7a49a109, consumer: 0x5400004b,
            family: "ccmp", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDGTExecuted", producer: 0x7a49a109, consumer: 0x5400004c,
            family: "ccmp", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDGTFallbackTrue", producer: 0x7a49a109, consumer: 0x5400004c,
            family: "ccmp", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDGTFallbackFalse", producer: 0x7a49a10d, consumer: 0x5400004c,
            family: "ccmp", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDLEExecuted", producer: 0x7a49a10d, consumer: 0x5400004d,
            family: "ccmp", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDLEFallbackTrue", producer: 0x7a49a10d, consumer: 0x5400004d,
            family: "ccmp", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterBCONDLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterBCONDLEFallbackFalse", producer: 0x7a49a109, consumer: 0x5400004d,
            family: "ccmp", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETGEExecuted", producer: 0x7a49a109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETGEFallbackTrue", producer: 0x7a49a109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETGEFallbackFalse", producer: 0x7a49a108, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETLTExecuted", producer: 0x7a49a108, consumer: 0x9a9fa7e0,
            family: "ccmp", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETLTFallbackTrue", producer: 0x7a49a108, consumer: 0x9a9fa7e0,
            family: "ccmp", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETLTFallbackFalse", producer: 0x7a49a109, consumer: 0x9a9fa7e0,
            family: "ccmp", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETGTExecuted", producer: 0x7a49a109, consumer: 0x9a9fd7e0,
            family: "ccmp", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETGTFallbackTrue", producer: 0x7a49a109, consumer: 0x9a9fd7e0,
            family: "ccmp", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETGTFallbackFalse", producer: 0x7a49a10d, consumer: 0x9a9fd7e0,
            family: "ccmp", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETLEExecuted", producer: 0x7a49a10d, consumer: 0x9a9fc7e0,
            family: "ccmp", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETLEFallbackTrue", producer: 0x7a49a10d, consumer: 0x9a9fc7e0,
            family: "ccmp", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETLEFallbackFalse", producer: 0x7a49a109, consumer: 0x9a9fc7e0,
            family: "ccmp", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMGEExecuted", producer: 0x7a49a109, consumer: 0xda9fb3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMGEFallbackTrue", producer: 0x7a49a109, consumer: 0xda9fb3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMGEFallbackFalse", producer: 0x7a49a108, consumer: 0xda9fb3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMLTExecuted", producer: 0x7a49a108, consumer: 0xda9fa3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMLTFallbackTrue", producer: 0x7a49a108, consumer: 0xda9fa3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMLTFallbackFalse", producer: 0x7a49a109, consumer: 0xda9fa3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMGTExecuted", producer: 0x7a49a109, consumer: 0xda9fd3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMGTFallbackTrue", producer: 0x7a49a109, consumer: 0xda9fd3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMGTFallbackFalse", producer: 0x7a49a10d, consumer: 0xda9fd3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMLEExecuted", producer: 0x7a49a10d, consumer: 0xda9fc3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMLEFallbackTrue", producer: 0x7a49a10d, consumer: 0xda9fc3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSETMLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSETMLEFallbackFalse", producer: 0x7a49a109, consumer: 0xda9fc3e0,
            family: "ccmp", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELGEExecuted", producer: 0x7a49a109, consumer: 0x9a8ea1a0,
            family: "ccmp", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELGEFallbackTrue", producer: 0x7a49a109, consumer: 0x9a8ea1a0,
            family: "ccmp", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELGEFallbackFalse", producer: 0x7a49a108, consumer: 0x9a8ea1a0,
            family: "ccmp", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELLTExecuted", producer: 0x7a49a108, consumer: 0x9a8eb1a0,
            family: "ccmp", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELLTFallbackTrue", producer: 0x7a49a108, consumer: 0x9a8eb1a0,
            family: "ccmp", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELLTFallbackFalse", producer: 0x7a49a109, consumer: 0x9a8eb1a0,
            family: "ccmp", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELGTExecuted", producer: 0x7a49a109, consumer: 0x9a8ec1a0,
            family: "ccmp", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELGTFallbackTrue", producer: 0x7a49a109, consumer: 0x9a8ec1a0,
            family: "ccmp", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELGTFallbackFalse", producer: 0x7a49a10d, consumer: 0x9a8ec1a0,
            family: "ccmp", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELLEExecuted", producer: 0x7a49a10d, consumer: 0x9a8ed1a0,
            family: "ccmp", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELLEFallbackTrue", producer: 0x7a49a10d, consumer: 0x9a8ed1a0,
            family: "ccmp", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSELLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSELLEFallbackFalse", producer: 0x7a49a109, consumer: 0x9a8ed1a0,
            family: "ccmp", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCGEExecuted", producer: 0x7a49a109, consumer: 0x9a8ea5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCGEFallbackTrue", producer: 0x7a49a109, consumer: 0x9a8ea5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCGEFallbackFalse", producer: 0x7a49a108, consumer: 0x9a8ea5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCLTExecuted", producer: 0x7a49a108, consumer: 0x9a8eb5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCLTFallbackTrue", producer: 0x7a49a108, consumer: 0x9a8eb5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCLTFallbackFalse", producer: 0x7a49a109, consumer: 0x9a8eb5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCGTExecuted", producer: 0x7a49a109, consumer: 0x9a8ec5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCGTFallbackTrue", producer: 0x7a49a109, consumer: 0x9a8ec5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCGTFallbackFalse", producer: 0x7a49a10d, consumer: 0x9a8ec5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCLEExecuted", producer: 0x7a49a10d, consumer: 0x9a8ed5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCLEFallbackTrue", producer: 0x7a49a10d, consumer: 0x9a8ed5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINCLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINCLEFallbackFalse", producer: 0x7a49a109, consumer: 0x9a8ed5a0,
            family: "ccmp", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVGEExecuted", producer: 0x7a49a109, consumer: 0xda8ea1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVGEFallbackTrue", producer: 0x7a49a109, consumer: 0xda8ea1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVGEFallbackFalse", producer: 0x7a49a108, consumer: 0xda8ea1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVLTExecuted", producer: 0x7a49a108, consumer: 0xda8eb1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVLTFallbackTrue", producer: 0x7a49a108, consumer: 0xda8eb1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVLTFallbackFalse", producer: 0x7a49a109, consumer: 0xda8eb1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVGTExecuted", producer: 0x7a49a109, consumer: 0xda8ec1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVGTFallbackTrue", producer: 0x7a49a109, consumer: 0xda8ec1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVGTFallbackFalse", producer: 0x7a49a10d, consumer: 0xda8ec1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVLEExecuted", producer: 0x7a49a10d, consumer: 0xda8ed1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVLEFallbackTrue", producer: 0x7a49a10d, consumer: 0xda8ed1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSINVLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSINVLEFallbackFalse", producer: 0x7a49a109, consumer: 0xda8ed1a0,
            family: "ccmp", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGGEExecuted", producer: 0x7a49a109, consumer: 0xda8ea5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGGEFallbackTrue", producer: 0x7a49a109, consumer: 0xda8ea5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGGEFallbackFalse", producer: 0x7a49a108, consumer: 0xda8ea5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGLTExecuted", producer: 0x7a49a108, consumer: 0xda8eb5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGLTFallbackTrue", producer: 0x7a49a108, consumer: 0xda8eb5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGLTFallbackFalse", producer: 0x7a49a109, consumer: 0xda8eb5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGGTExecuted", producer: 0x7a49a109, consumer: 0xda8ec5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGGTFallbackTrue", producer: 0x7a49a109, consumer: 0xda8ec5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGGTFallbackFalse", producer: 0x7a49a10d, consumer: 0xda8ec5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGLEExecuted", producer: 0x7a49a10d, consumer: 0xda8ed5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGLEFallbackTrue", producer: 0x7a49a10d, consumer: 0xda8ed5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCSNEGLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCSNEGLEFallbackFalse", producer: 0x7a49a109, consumer: 0xda8ed5a0,
            family: "ccmp", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCGEExecuted", producer: 0x7a49a109, consumer: 0x9a8db5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCGEFallbackTrue", producer: 0x7a49a109, consumer: 0x9a8db5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCGEFallbackFalse", producer: 0x7a49a108, consumer: 0x9a8db5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCLTExecuted", producer: 0x7a49a108, consumer: 0x9a8da5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCLTFallbackTrue", producer: 0x7a49a108, consumer: 0x9a8da5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCLTFallbackFalse", producer: 0x7a49a109, consumer: 0x9a8da5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCGTExecuted", producer: 0x7a49a109, consumer: 0x9a8dd5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCGTFallbackTrue", producer: 0x7a49a109, consumer: 0x9a8dd5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCGTFallbackFalse", producer: 0x7a49a10d, consumer: 0x9a8dd5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCLEExecuted", producer: 0x7a49a10d, consumer: 0x9a8dc5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCLEFallbackTrue", producer: 0x7a49a10d, consumer: 0x9a8dc5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINCLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINCLEFallbackFalse", producer: 0x7a49a109, consumer: 0x9a8dc5a0,
            family: "ccmp", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVGEExecuted", producer: 0x7a49a109, consumer: 0xda8db1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVGEFallbackTrue", producer: 0x7a49a109, consumer: 0xda8db1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVGEFallbackFalse", producer: 0x7a49a108, consumer: 0xda8db1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVLTExecuted", producer: 0x7a49a108, consumer: 0xda8da1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVLTFallbackTrue", producer: 0x7a49a108, consumer: 0xda8da1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVLTFallbackFalse", producer: 0x7a49a109, consumer: 0xda8da1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVGTExecuted", producer: 0x7a49a109, consumer: 0xda8dd1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVGTFallbackTrue", producer: 0x7a49a109, consumer: 0xda8dd1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVGTFallbackFalse", producer: 0x7a49a10d, consumer: 0xda8dd1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVLEExecuted", producer: 0x7a49a10d, consumer: 0xda8dc1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVLEFallbackTrue", producer: 0x7a49a10d, consumer: 0xda8dc1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCINVLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCINVLEFallbackFalse", producer: 0x7a49a109, consumer: 0xda8dc1a0,
            family: "ccmp", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGGEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGGEExecuted", producer: 0x7a49a109, consumer: 0xda8db5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGGEFallbackTrue", producer: 0x7a49a109, consumer: 0xda8db5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGGEFallbackFalse", producer: 0x7a49a108, consumer: 0xda8db5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGLTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGLTExecuted", producer: 0x7a49a108, consumer: 0xda8da5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGLTFallbackTrue", producer: 0x7a49a108, consumer: 0xda8da5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGLTFallbackFalse", producer: 0x7a49a109, consumer: 0xda8da5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGGTExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGGTExecuted", producer: 0x7a49a109, consumer: 0xda8dd5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGGTFallbackTrue", producer: 0x7a49a109, consumer: 0xda8dd5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGGTFallbackFalse", producer: 0x7a49a10d, consumer: 0xda8dd5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGLEExecuted() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGLEExecuted", producer: 0x7a49a10d, consumer: 0xda8dc5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGLEFallbackTrue", producer: 0x7a49a10d, consumer: 0xda8dc5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterCNEGLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterCNEGLEFallbackFalse", producer: 0x7a49a109, consumer: 0xda8dc5a0,
            family: "ccmp", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDGEExecuted", producer: 0x3a41a909, consumer: 0x5400004a,
            family: "ccmn", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDGEFallbackTrue", producer: 0x3a41a909, consumer: 0x5400004a,
            family: "ccmn", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDGEFallbackFalse", producer: 0x3a41a908, consumer: 0x5400004a,
            family: "ccmn", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDLTExecuted", producer: 0x3a41a908, consumer: 0x5400004b,
            family: "ccmn", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDLTFallbackTrue", producer: 0x3a41a908, consumer: 0x5400004b,
            family: "ccmn", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDLTFallbackFalse", producer: 0x3a41a909, consumer: 0x5400004b,
            family: "ccmn", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDGTExecuted", producer: 0x3a41a909, consumer: 0x5400004c,
            family: "ccmn", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDGTFallbackTrue", producer: 0x3a41a909, consumer: 0x5400004c,
            family: "ccmn", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDGTFallbackFalse", producer: 0x3a41a90d, consumer: 0x5400004c,
            family: "ccmn", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDLEExecuted", producer: 0x3a41a90d, consumer: 0x5400004d,
            family: "ccmn", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDLEFallbackTrue", producer: 0x3a41a90d, consumer: 0x5400004d,
            family: "ccmn", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateBCONDLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateBCONDLEFallbackFalse", producer: 0x3a41a909, consumer: 0x5400004d,
            family: "ccmn", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETGEExecuted", producer: 0x3a41a909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETGEFallbackTrue", producer: 0x3a41a909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETGEFallbackFalse", producer: 0x3a41a908, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETLTExecuted", producer: 0x3a41a908, consumer: 0x9a9fa7e0,
            family: "ccmn", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETLTFallbackTrue", producer: 0x3a41a908, consumer: 0x9a9fa7e0,
            family: "ccmn", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETLTFallbackFalse", producer: 0x3a41a909, consumer: 0x9a9fa7e0,
            family: "ccmn", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETGTExecuted", producer: 0x3a41a909, consumer: 0x9a9fd7e0,
            family: "ccmn", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETGTFallbackTrue", producer: 0x3a41a909, consumer: 0x9a9fd7e0,
            family: "ccmn", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETGTFallbackFalse", producer: 0x3a41a90d, consumer: 0x9a9fd7e0,
            family: "ccmn", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETLEExecuted", producer: 0x3a41a90d, consumer: 0x9a9fc7e0,
            family: "ccmn", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETLEFallbackTrue", producer: 0x3a41a90d, consumer: 0x9a9fc7e0,
            family: "ccmn", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETLEFallbackFalse", producer: 0x3a41a909, consumer: 0x9a9fc7e0,
            family: "ccmn", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMGEExecuted", producer: 0x3a41a909, consumer: 0xda9fb3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMGEFallbackTrue", producer: 0x3a41a909, consumer: 0xda9fb3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMGEFallbackFalse", producer: 0x3a41a908, consumer: 0xda9fb3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMLTExecuted", producer: 0x3a41a908, consumer: 0xda9fa3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMLTFallbackTrue", producer: 0x3a41a908, consumer: 0xda9fa3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMLTFallbackFalse", producer: 0x3a41a909, consumer: 0xda9fa3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMGTExecuted", producer: 0x3a41a909, consumer: 0xda9fd3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMGTFallbackTrue", producer: 0x3a41a909, consumer: 0xda9fd3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMGTFallbackFalse", producer: 0x3a41a90d, consumer: 0xda9fd3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMLEExecuted", producer: 0x3a41a90d, consumer: 0xda9fc3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMLEFallbackTrue", producer: 0x3a41a90d, consumer: 0xda9fc3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSETMLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSETMLEFallbackFalse", producer: 0x3a41a909, consumer: 0xda9fc3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELGEExecuted", producer: 0x3a41a909, consumer: 0x9a8ea1a0,
            family: "ccmn", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELGEFallbackTrue", producer: 0x3a41a909, consumer: 0x9a8ea1a0,
            family: "ccmn", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELGEFallbackFalse", producer: 0x3a41a908, consumer: 0x9a8ea1a0,
            family: "ccmn", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELLTExecuted", producer: 0x3a41a908, consumer: 0x9a8eb1a0,
            family: "ccmn", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELLTFallbackTrue", producer: 0x3a41a908, consumer: 0x9a8eb1a0,
            family: "ccmn", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELLTFallbackFalse", producer: 0x3a41a909, consumer: 0x9a8eb1a0,
            family: "ccmn", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELGTExecuted", producer: 0x3a41a909, consumer: 0x9a8ec1a0,
            family: "ccmn", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELGTFallbackTrue", producer: 0x3a41a909, consumer: 0x9a8ec1a0,
            family: "ccmn", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELGTFallbackFalse", producer: 0x3a41a90d, consumer: 0x9a8ec1a0,
            family: "ccmn", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELLEExecuted", producer: 0x3a41a90d, consumer: 0x9a8ed1a0,
            family: "ccmn", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELLEFallbackTrue", producer: 0x3a41a90d, consumer: 0x9a8ed1a0,
            family: "ccmn", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSELLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSELLEFallbackFalse", producer: 0x3a41a909, consumer: 0x9a8ed1a0,
            family: "ccmn", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCGEExecuted", producer: 0x3a41a909, consumer: 0x9a8ea5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCGEFallbackTrue", producer: 0x3a41a909, consumer: 0x9a8ea5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCGEFallbackFalse", producer: 0x3a41a908, consumer: 0x9a8ea5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCLTExecuted", producer: 0x3a41a908, consumer: 0x9a8eb5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCLTFallbackTrue", producer: 0x3a41a908, consumer: 0x9a8eb5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCLTFallbackFalse", producer: 0x3a41a909, consumer: 0x9a8eb5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCGTExecuted", producer: 0x3a41a909, consumer: 0x9a8ec5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCGTFallbackTrue", producer: 0x3a41a909, consumer: 0x9a8ec5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCGTFallbackFalse", producer: 0x3a41a90d, consumer: 0x9a8ec5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCLEExecuted", producer: 0x3a41a90d, consumer: 0x9a8ed5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCLEFallbackTrue", producer: 0x3a41a90d, consumer: 0x9a8ed5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINCLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINCLEFallbackFalse", producer: 0x3a41a909, consumer: 0x9a8ed5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVGEExecuted", producer: 0x3a41a909, consumer: 0xda8ea1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVGEFallbackTrue", producer: 0x3a41a909, consumer: 0xda8ea1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVGEFallbackFalse", producer: 0x3a41a908, consumer: 0xda8ea1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVLTExecuted", producer: 0x3a41a908, consumer: 0xda8eb1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVLTFallbackTrue", producer: 0x3a41a908, consumer: 0xda8eb1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVLTFallbackFalse", producer: 0x3a41a909, consumer: 0xda8eb1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVGTExecuted", producer: 0x3a41a909, consumer: 0xda8ec1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVGTFallbackTrue", producer: 0x3a41a909, consumer: 0xda8ec1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVGTFallbackFalse", producer: 0x3a41a90d, consumer: 0xda8ec1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVLEExecuted", producer: 0x3a41a90d, consumer: 0xda8ed1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVLEFallbackTrue", producer: 0x3a41a90d, consumer: 0xda8ed1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSINVLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSINVLEFallbackFalse", producer: 0x3a41a909, consumer: 0xda8ed1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGGEExecuted", producer: 0x3a41a909, consumer: 0xda8ea5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGGEFallbackTrue", producer: 0x3a41a909, consumer: 0xda8ea5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGGEFallbackFalse", producer: 0x3a41a908, consumer: 0xda8ea5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGLTExecuted", producer: 0x3a41a908, consumer: 0xda8eb5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGLTFallbackTrue", producer: 0x3a41a908, consumer: 0xda8eb5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGLTFallbackFalse", producer: 0x3a41a909, consumer: 0xda8eb5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGGTExecuted", producer: 0x3a41a909, consumer: 0xda8ec5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGGTFallbackTrue", producer: 0x3a41a909, consumer: 0xda8ec5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGGTFallbackFalse", producer: 0x3a41a90d, consumer: 0xda8ec5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGLEExecuted", producer: 0x3a41a90d, consumer: 0xda8ed5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGLEFallbackTrue", producer: 0x3a41a90d, consumer: 0xda8ed5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCSNEGLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCSNEGLEFallbackFalse", producer: 0x3a41a909, consumer: 0xda8ed5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCGEExecuted", producer: 0x3a41a909, consumer: 0x9a8db5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCGEFallbackTrue", producer: 0x3a41a909, consumer: 0x9a8db5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCGEFallbackFalse", producer: 0x3a41a908, consumer: 0x9a8db5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCLTExecuted", producer: 0x3a41a908, consumer: 0x9a8da5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCLTFallbackTrue", producer: 0x3a41a908, consumer: 0x9a8da5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCLTFallbackFalse", producer: 0x3a41a909, consumer: 0x9a8da5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCGTExecuted", producer: 0x3a41a909, consumer: 0x9a8dd5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCGTFallbackTrue", producer: 0x3a41a909, consumer: 0x9a8dd5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCGTFallbackFalse", producer: 0x3a41a90d, consumer: 0x9a8dd5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCLEExecuted", producer: 0x3a41a90d, consumer: 0x9a8dc5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCLEFallbackTrue", producer: 0x3a41a90d, consumer: 0x9a8dc5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINCLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINCLEFallbackFalse", producer: 0x3a41a909, consumer: 0x9a8dc5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVGEExecuted", producer: 0x3a41a909, consumer: 0xda8db1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVGEFallbackTrue", producer: 0x3a41a909, consumer: 0xda8db1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVGEFallbackFalse", producer: 0x3a41a908, consumer: 0xda8db1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVLTExecuted", producer: 0x3a41a908, consumer: 0xda8da1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVLTFallbackTrue", producer: 0x3a41a908, consumer: 0xda8da1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVLTFallbackFalse", producer: 0x3a41a909, consumer: 0xda8da1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVGTExecuted", producer: 0x3a41a909, consumer: 0xda8dd1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVGTFallbackTrue", producer: 0x3a41a909, consumer: 0xda8dd1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVGTFallbackFalse", producer: 0x3a41a90d, consumer: 0xda8dd1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVLEExecuted", producer: 0x3a41a90d, consumer: 0xda8dc1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVLEFallbackTrue", producer: 0x3a41a90d, consumer: 0xda8dc1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCINVLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCINVLEFallbackFalse", producer: 0x3a41a909, consumer: 0xda8dc1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGGEExecuted", producer: 0x3a41a909, consumer: 0xda8db5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGGEFallbackTrue", producer: 0x3a41a909, consumer: 0xda8db5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGGEFallbackFalse", producer: 0x3a41a908, consumer: 0xda8db5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGLTExecuted", producer: 0x3a41a908, consumer: 0xda8da5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGLTFallbackTrue", producer: 0x3a41a908, consumer: 0xda8da5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGLTFallbackFalse", producer: 0x3a41a909, consumer: 0xda8da5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGGTExecuted", producer: 0x3a41a909, consumer: 0xda8dd5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGGTFallbackTrue", producer: 0x3a41a909, consumer: 0xda8dd5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGGTFallbackFalse", producer: 0x3a41a90d, consumer: 0xda8dd5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGLEExecuted", producer: 0x3a41a90d, consumer: 0xda8dc5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGLEFallbackTrue", producer: 0x3a41a90d, consumer: 0xda8dc5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateCNEGLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateCNEGLEFallbackFalse", producer: 0x3a41a909, consumer: 0xda8dc5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDGEExecuted", producer: 0x3a49a109, consumer: 0x5400004a,
            family: "ccmn", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDGEFallbackTrue", producer: 0x3a49a109, consumer: 0x5400004a,
            family: "ccmn", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDGEFallbackFalse", producer: 0x3a49a108, consumer: 0x5400004a,
            family: "ccmn", mnemonic: "b.ge", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDLTExecuted", producer: 0x3a49a108, consumer: 0x5400004b,
            family: "ccmn", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDLTFallbackTrue", producer: 0x3a49a108, consumer: 0x5400004b,
            family: "ccmn", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDLTFallbackFalse", producer: 0x3a49a109, consumer: 0x5400004b,
            family: "ccmn", mnemonic: "b.lt", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDGTExecuted", producer: 0x3a49a109, consumer: 0x5400004c,
            family: "ccmn", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDGTFallbackTrue", producer: 0x3a49a109, consumer: 0x5400004c,
            family: "ccmn", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDGTFallbackFalse", producer: 0x3a49a10d, consumer: 0x5400004c,
            family: "ccmn", mnemonic: "b.gt", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDLEExecuted", producer: 0x3a49a10d, consumer: 0x5400004d,
            family: "ccmn", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDLEFallbackTrue", producer: 0x3a49a10d, consumer: 0x5400004d,
            family: "ccmn", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterBCONDLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterBCONDLEFallbackFalse", producer: 0x3a49a109, consumer: 0x5400004d,
            family: "ccmn", mnemonic: "b.le", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETGEExecuted", producer: 0x3a49a109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETGEFallbackTrue", producer: 0x3a49a109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETGEFallbackFalse", producer: 0x3a49a108, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETLTExecuted", producer: 0x3a49a108, consumer: 0x9a9fa7e0,
            family: "ccmn", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETLTFallbackTrue", producer: 0x3a49a108, consumer: 0x9a9fa7e0,
            family: "ccmn", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETLTFallbackFalse", producer: 0x3a49a109, consumer: 0x9a9fa7e0,
            family: "ccmn", mnemonic: "cset", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETGTExecuted", producer: 0x3a49a109, consumer: 0x9a9fd7e0,
            family: "ccmn", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETGTFallbackTrue", producer: 0x3a49a109, consumer: 0x9a9fd7e0,
            family: "ccmn", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETGTFallbackFalse", producer: 0x3a49a10d, consumer: 0x9a9fd7e0,
            family: "ccmn", mnemonic: "cset", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETLEExecuted", producer: 0x3a49a10d, consumer: 0x9a9fc7e0,
            family: "ccmn", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETLEFallbackTrue", producer: 0x3a49a10d, consumer: 0x9a9fc7e0,
            family: "ccmn", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETLEFallbackFalse", producer: 0x3a49a109, consumer: 0x9a9fc7e0,
            family: "ccmn", mnemonic: "cset", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMGEExecuted", producer: 0x3a49a109, consumer: 0xda9fb3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMGEFallbackTrue", producer: 0x3a49a109, consumer: 0xda9fb3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMGEFallbackFalse", producer: 0x3a49a108, consumer: 0xda9fb3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMLTExecuted", producer: 0x3a49a108, consumer: 0xda9fa3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMLTFallbackTrue", producer: 0x3a49a108, consumer: 0xda9fa3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMLTFallbackFalse", producer: 0x3a49a109, consumer: 0xda9fa3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMGTExecuted", producer: 0x3a49a109, consumer: 0xda9fd3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMGTFallbackTrue", producer: 0x3a49a109, consumer: 0xda9fd3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMGTFallbackFalse", producer: 0x3a49a10d, consumer: 0xda9fd3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMLEExecuted", producer: 0x3a49a10d, consumer: 0xda9fc3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMLEFallbackTrue", producer: 0x3a49a10d, consumer: 0xda9fc3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSETMLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSETMLEFallbackFalse", producer: 0x3a49a109, consumer: 0xda9fc3e0,
            family: "ccmn", mnemonic: "csetm", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELGEExecuted", producer: 0x3a49a109, consumer: 0x9a8ea1a0,
            family: "ccmn", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELGEFallbackTrue", producer: 0x3a49a109, consumer: 0x9a8ea1a0,
            family: "ccmn", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELGEFallbackFalse", producer: 0x3a49a108, consumer: 0x9a8ea1a0,
            family: "ccmn", mnemonic: "csel", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELLTExecuted", producer: 0x3a49a108, consumer: 0x9a8eb1a0,
            family: "ccmn", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELLTFallbackTrue", producer: 0x3a49a108, consumer: 0x9a8eb1a0,
            family: "ccmn", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELLTFallbackFalse", producer: 0x3a49a109, consumer: 0x9a8eb1a0,
            family: "ccmn", mnemonic: "csel", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELGTExecuted", producer: 0x3a49a109, consumer: 0x9a8ec1a0,
            family: "ccmn", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELGTFallbackTrue", producer: 0x3a49a109, consumer: 0x9a8ec1a0,
            family: "ccmn", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELGTFallbackFalse", producer: 0x3a49a10d, consumer: 0x9a8ec1a0,
            family: "ccmn", mnemonic: "csel", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELLEExecuted", producer: 0x3a49a10d, consumer: 0x9a8ed1a0,
            family: "ccmn", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELLEFallbackTrue", producer: 0x3a49a10d, consumer: 0x9a8ed1a0,
            family: "ccmn", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSELLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSELLEFallbackFalse", producer: 0x3a49a109, consumer: 0x9a8ed1a0,
            family: "ccmn", mnemonic: "csel", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCGEExecuted", producer: 0x3a49a109, consumer: 0x9a8ea5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCGEFallbackTrue", producer: 0x3a49a109, consumer: 0x9a8ea5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCGEFallbackFalse", producer: 0x3a49a108, consumer: 0x9a8ea5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCLTExecuted", producer: 0x3a49a108, consumer: 0x9a8eb5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCLTFallbackTrue", producer: 0x3a49a108, consumer: 0x9a8eb5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCLTFallbackFalse", producer: 0x3a49a109, consumer: 0x9a8eb5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCGTExecuted", producer: 0x3a49a109, consumer: 0x9a8ec5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCGTFallbackTrue", producer: 0x3a49a109, consumer: 0x9a8ec5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCGTFallbackFalse", producer: 0x3a49a10d, consumer: 0x9a8ec5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCLEExecuted", producer: 0x3a49a10d, consumer: 0x9a8ed5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCLEFallbackTrue", producer: 0x3a49a10d, consumer: 0x9a8ed5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINCLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINCLEFallbackFalse", producer: 0x3a49a109, consumer: 0x9a8ed5a0,
            family: "ccmn", mnemonic: "csinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVGEExecuted", producer: 0x3a49a109, consumer: 0xda8ea1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVGEFallbackTrue", producer: 0x3a49a109, consumer: 0xda8ea1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVGEFallbackFalse", producer: 0x3a49a108, consumer: 0xda8ea1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVLTExecuted", producer: 0x3a49a108, consumer: 0xda8eb1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVLTFallbackTrue", producer: 0x3a49a108, consumer: 0xda8eb1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVLTFallbackFalse", producer: 0x3a49a109, consumer: 0xda8eb1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVGTExecuted", producer: 0x3a49a109, consumer: 0xda8ec1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVGTFallbackTrue", producer: 0x3a49a109, consumer: 0xda8ec1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVGTFallbackFalse", producer: 0x3a49a10d, consumer: 0xda8ec1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVLEExecuted", producer: 0x3a49a10d, consumer: 0xda8ed1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVLEFallbackTrue", producer: 0x3a49a10d, consumer: 0xda8ed1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSINVLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSINVLEFallbackFalse", producer: 0x3a49a109, consumer: 0xda8ed1a0,
            family: "ccmn", mnemonic: "csinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGGEExecuted", producer: 0x3a49a109, consumer: 0xda8ea5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGGEFallbackTrue", producer: 0x3a49a109, consumer: 0xda8ea5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGGEFallbackFalse", producer: 0x3a49a108, consumer: 0xda8ea5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGLTExecuted", producer: 0x3a49a108, consumer: 0xda8eb5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGLTFallbackTrue", producer: 0x3a49a108, consumer: 0xda8eb5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGLTFallbackFalse", producer: 0x3a49a109, consumer: 0xda8eb5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGGTExecuted", producer: 0x3a49a109, consumer: 0xda8ec5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGGTFallbackTrue", producer: 0x3a49a109, consumer: 0xda8ec5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGGTFallbackFalse", producer: 0x3a49a10d, consumer: 0xda8ec5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGLEExecuted", producer: 0x3a49a10d, consumer: 0xda8ed5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGLEFallbackTrue", producer: 0x3a49a10d, consumer: 0xda8ed5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCSNEGLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCSNEGLEFallbackFalse", producer: 0x3a49a109, consumer: 0xda8ed5a0,
            family: "ccmn", mnemonic: "csneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCGEExecuted", producer: 0x3a49a109, consumer: 0x9a8db5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCGEFallbackTrue", producer: 0x3a49a109, consumer: 0x9a8db5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCGEFallbackFalse", producer: 0x3a49a108, consumer: 0x9a8db5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCLTExecuted", producer: 0x3a49a108, consumer: 0x9a8da5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCLTFallbackTrue", producer: 0x3a49a108, consumer: 0x9a8da5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCLTFallbackFalse", producer: 0x3a49a109, consumer: 0x9a8da5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCGTExecuted", producer: 0x3a49a109, consumer: 0x9a8dd5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCGTFallbackTrue", producer: 0x3a49a109, consumer: 0x9a8dd5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCGTFallbackFalse", producer: 0x3a49a10d, consumer: 0x9a8dd5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCLEExecuted", producer: 0x3a49a10d, consumer: 0x9a8dc5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCLEFallbackTrue", producer: 0x3a49a10d, consumer: 0x9a8dc5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINCLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINCLEFallbackFalse", producer: 0x3a49a109, consumer: 0x9a8dc5a0,
            family: "ccmn", mnemonic: "cinc", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVGEExecuted", producer: 0x3a49a109, consumer: 0xda8db1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVGEFallbackTrue", producer: 0x3a49a109, consumer: 0xda8db1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVGEFallbackFalse", producer: 0x3a49a108, consumer: 0xda8db1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVLTExecuted", producer: 0x3a49a108, consumer: 0xda8da1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVLTFallbackTrue", producer: 0x3a49a108, consumer: 0xda8da1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVLTFallbackFalse", producer: 0x3a49a109, consumer: 0xda8da1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVGTExecuted", producer: 0x3a49a109, consumer: 0xda8dd1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVGTFallbackTrue", producer: 0x3a49a109, consumer: 0xda8dd1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVGTFallbackFalse", producer: 0x3a49a10d, consumer: 0xda8dd1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVLEExecuted", producer: 0x3a49a10d, consumer: 0xda8dc1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVLEFallbackTrue", producer: 0x3a49a10d, consumer: 0xda8dc1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCINVLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCINVLEFallbackFalse", producer: 0x3a49a109, consumer: 0xda8dc1a0,
            family: "ccmn", mnemonic: "cinv", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGGEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGGEExecuted", producer: 0x3a49a109, consumer: 0xda8db5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGGEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGGEFallbackTrue", producer: 0x3a49a109, consumer: 0xda8db5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGGEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGGEFallbackFalse", producer: 0x3a49a108, consumer: 0xda8db5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGLTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGLTExecuted", producer: 0x3a49a108, consumer: 0xda8da5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGLTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGLTFallbackTrue", producer: 0x3a49a108, consumer: 0xda8da5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGLTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGLTFallbackFalse", producer: 0x3a49a109, consumer: 0xda8da5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "lt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGGTExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGGTExecuted", producer: 0x3a49a109, consumer: 0xda8dd5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGGTFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGGTFallbackTrue", producer: 0x3a49a109, consumer: 0xda8dd5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGGTFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGGTFallbackFalse", producer: 0x3a49a10d, consumer: 0xda8dd5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "gt", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGLEExecuted() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGLEExecuted", producer: 0x3a49a10d, consumer: 0xda8dc5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGLEFallbackTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGLEFallbackTrue", producer: 0x3a49a10d, consumer: 0xda8dc5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterCNEGLEFallbackFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterCNEGLEFallbackFalse", producer: 0x3a49a109, consumer: 0xda8dc5a0,
            family: "ccmn", mnemonic: "cneg", suffix: "le", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, false], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardEQTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardEQTrue", producer: 0x7a410909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "eq", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardEQFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardEQFalse", producer: 0x7a410909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "eq", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardNETrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardNETrue", producer: 0x7a411909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ne", guardBits: 0x0, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardNEFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardNEFalse", producer: 0x7a411909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ne", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardHSTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardHSTrue", producer: 0x7a412909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hs", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardHSFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardHSFalse", producer: 0x7a412909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hs", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardLOTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardLOTrue", producer: 0x7a413909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lo", guardBits: 0x0, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardLOFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardLOFalse", producer: 0x7a413909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lo", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardMITrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardMITrue", producer: 0x7a414909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "mi", guardBits: 0x0, otherBits: 0x1,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardMIFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardMIFalse", producer: 0x7a414909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "mi", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardPLTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardPLTrue", producer: 0x7a415909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "pl", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardPLFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardPLFalse", producer: 0x7a415909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "pl", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardVSTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardVSTrue", producer: 0x7a416909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vs", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardVSFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardVSFalse", producer: 0x7a416909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vs", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardVCTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardVCTrue", producer: 0x7a417909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vc", guardBits: 0x0, otherBits: 0x1,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardVCFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardVCFalse", producer: 0x7a417909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vc", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardHITrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardHITrue", producer: 0x7a418909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hi", guardBits: 0x2, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardHIFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardHIFalse", producer: 0x7a418909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hi", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardLSTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardLSTrue", producer: 0x7a419909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ls", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardLSFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardLSFalse", producer: 0x7a419909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ls", guardBits: 0x2, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardGETrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardGETrue", producer: 0x7a41a909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardGEFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardGEFalse", producer: 0x7a41a909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardLTTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardLTTrue", producer: 0x7a41b909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lt", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardLTFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardLTFalse", producer: 0x7a41b909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lt", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardGTTrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardGTTrue", producer: 0x7a41c909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "gt", guardBits: 0x2, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardGTFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardGTFalse", producer: 0x7a41c909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "gt", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardLETrue() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardLETrue", producer: 0x7a41d909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "le", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardLEFalse() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardLEFalse", producer: 0x7a41d909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "le", guardBits: 0x2, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardALRefusal() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardALRefusal", producer: 0x7a41e909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "al", guardBits: 0x0, otherBits: 0x1,
            expected: [], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPImmediateGuardNVRefusal() throws {
        try checkLogicalConditionalCell("CCMPImmediateGuardNVRefusal", producer: 0x7a41f909, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "nv", guardBits: 0x0, otherBits: 0x1,
            expected: [], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardEQTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardEQTrue", producer: 0x7a490109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "eq", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardEQFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardEQFalse", producer: 0x7a490109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "eq", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardNETrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardNETrue", producer: 0x7a491109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ne", guardBits: 0x0, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardNEFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardNEFalse", producer: 0x7a491109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ne", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardHSTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardHSTrue", producer: 0x7a492109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hs", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardHSFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardHSFalse", producer: 0x7a492109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hs", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardLOTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardLOTrue", producer: 0x7a493109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lo", guardBits: 0x0, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardLOFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardLOFalse", producer: 0x7a493109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lo", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardMITrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardMITrue", producer: 0x7a494109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "mi", guardBits: 0x0, otherBits: 0x1,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardMIFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardMIFalse", producer: 0x7a494109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "mi", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardPLTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardPLTrue", producer: 0x7a495109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "pl", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardPLFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardPLFalse", producer: 0x7a495109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "pl", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardVSTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardVSTrue", producer: 0x7a496109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vs", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardVSFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardVSFalse", producer: 0x7a496109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vs", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardVCTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardVCTrue", producer: 0x7a497109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vc", guardBits: 0x0, otherBits: 0x1,
            expected: [false, false, false, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardVCFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardVCFalse", producer: 0x7a497109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vc", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardHITrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardHITrue", producer: 0x7a498109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hi", guardBits: 0x2, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardHIFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardHIFalse", producer: 0x7a498109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hi", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardLSTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardLSTrue", producer: 0x7a499109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ls", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardLSFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardLSFalse", producer: 0x7a499109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ls", guardBits: 0x2, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardGETrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardGETrue", producer: 0x7a49a109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardGEFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardGEFalse", producer: 0x7a49a109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardLTTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardLTTrue", producer: 0x7a49b109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lt", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardLTFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardLTFalse", producer: 0x7a49b109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lt", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardGTTrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardGTTrue", producer: 0x7a49c109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "gt", guardBits: 0x2, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardGTFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardGTFalse", producer: 0x7a49c109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "gt", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardLETrue() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardLETrue", producer: 0x7a49d109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "le", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, false, false, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardLEFalse() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardLEFalse", producer: 0x7a49d109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "le", guardBits: 0x2, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardALRefusal() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardALRefusal", producer: 0x7a49e109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "al", guardBits: 0x0, otherBits: 0x1,
            expected: [], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMPRegisterGuardNVRefusal() throws {
        try checkLogicalConditionalCell("CCMPRegisterGuardNVRefusal", producer: 0x7a49f109, consumer: 0x9a9fb7e0,
            family: "ccmp", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "nv", guardBits: 0x0, otherBits: 0x1,
            expected: [], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardEQTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardEQTrue", producer: 0x3a410909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "eq", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardEQFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardEQFalse", producer: 0x3a410909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "eq", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardNETrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardNETrue", producer: 0x3a411909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ne", guardBits: 0x0, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardNEFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardNEFalse", producer: 0x3a411909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ne", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardHSTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardHSTrue", producer: 0x3a412909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hs", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardHSFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardHSFalse", producer: 0x3a412909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hs", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardLOTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardLOTrue", producer: 0x3a413909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lo", guardBits: 0x0, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardLOFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardLOFalse", producer: 0x3a413909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lo", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardMITrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardMITrue", producer: 0x3a414909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "mi", guardBits: 0x0, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardMIFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardMIFalse", producer: 0x3a414909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "mi", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardPLTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardPLTrue", producer: 0x3a415909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "pl", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardPLFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardPLFalse", producer: 0x3a415909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "pl", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardVSTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardVSTrue", producer: 0x3a416909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vs", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardVSFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardVSFalse", producer: 0x3a416909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vs", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardVCTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardVCTrue", producer: 0x3a417909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vc", guardBits: 0x0, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardVCFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardVCFalse", producer: 0x3a417909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vc", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardHITrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardHITrue", producer: 0x3a418909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hi", guardBits: 0x2, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardHIFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardHIFalse", producer: 0x3a418909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hi", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardLSTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardLSTrue", producer: 0x3a419909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ls", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardLSFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardLSFalse", producer: 0x3a419909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ls", guardBits: 0x2, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardGETrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardGETrue", producer: 0x3a41a909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardGEFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardGEFalse", producer: 0x3a41a909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardLTTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardLTTrue", producer: 0x3a41b909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lt", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardLTFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardLTFalse", producer: 0x3a41b909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lt", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardGTTrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardGTTrue", producer: 0x3a41c909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "gt", guardBits: 0x2, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardGTFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardGTFalse", producer: 0x3a41c909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "gt", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardLETrue() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardLETrue", producer: 0x3a41d909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "le", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardLEFalse() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardLEFalse", producer: 0x3a41d909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "le", guardBits: 0x2, otherBits: 0x1,
            expected: [true, true, true, true], refused: false,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardALRefusal() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardALRefusal", producer: 0x3a41e909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "al", guardBits: 0x0, otherBits: 0x1,
            expected: [], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNImmediateGuardNVRefusal() throws {
        try checkLogicalConditionalCell("CCMNImmediateGuardNVRefusal", producer: 0x3a41f909, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "nv", guardBits: 0x0, otherBits: 0x1,
            expected: [], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardEQTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardEQTrue", producer: 0x3a490109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "eq", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardEQFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardEQFalse", producer: 0x3a490109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "eq", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardNETrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardNETrue", producer: 0x3a491109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ne", guardBits: 0x0, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardNEFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardNEFalse", producer: 0x3a491109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ne", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardHSTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardHSTrue", producer: 0x3a492109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hs", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardHSFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardHSFalse", producer: 0x3a492109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hs", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardLOTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardLOTrue", producer: 0x3a493109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lo", guardBits: 0x0, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardLOFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardLOFalse", producer: 0x3a493109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lo", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardMITrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardMITrue", producer: 0x3a494109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "mi", guardBits: 0x0, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardMIFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardMIFalse", producer: 0x3a494109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "mi", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardPLTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardPLTrue", producer: 0x3a495109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "pl", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardPLFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardPLFalse", producer: 0x3a495109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "pl", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardVSTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardVSTrue", producer: 0x3a496109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vs", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardVSFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardVSFalse", producer: 0x3a496109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vs", guardBits: 0x0, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardVCTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardVCTrue", producer: 0x3a497109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vc", guardBits: 0x0, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardVCFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardVCFalse", producer: 0x3a497109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "vc", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardHITrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardHITrue", producer: 0x3a498109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hi", guardBits: 0x2, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardHIFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardHIFalse", producer: 0x3a498109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "hi", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardLSTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardLSTrue", producer: 0x3a499109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ls", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardLSFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardLSFalse", producer: 0x3a499109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ls", guardBits: 0x2, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardGETrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardGETrue", producer: 0x3a49a109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x1, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardGEFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardGEFalse", producer: 0x3a49a109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "ge", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardLTTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardLTTrue", producer: 0x3a49b109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lt", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardLTFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardLTFalse", producer: 0x3a49b109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "lt", guardBits: 0x1, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardGTTrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardGTTrue", producer: 0x3a49c109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "gt", guardBits: 0x2, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardGTFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardGTFalse", producer: 0x3a49c109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "gt", guardBits: 0x80000000, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardLETrue() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardLETrue", producer: 0x3a49d109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "le", guardBits: 0x80000000, otherBits: 0x1,
            expected: [false, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardLEFalse() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardLEFalse", producer: 0x3a49d109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "le", guardBits: 0x2, otherBits: 0x1,
            expected: [true, true, true, true], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardALRefusal() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardALRefusal", producer: 0x3a49e109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "al", guardBits: 0x0, otherBits: 0x1,
            expected: [], refused: true,
            declined: false, strictRefusals: [])
    }

    func test338CCMNRegisterGuardNVRefusal() throws {
        try checkLogicalConditionalCell("CCMNRegisterGuardNVRefusal", producer: 0x3a49f109, consumer: 0x9a9fb7e0,
            family: "ccmn", mnemonic: "cset", suffix: "ge", chain: true,
            guardSuffix: "nv", guardBits: 0x0, otherBits: 0x1,
            expected: [], refused: true,
            declined: false, strictRefusals: [])
    }

    // Isolated commit controls: these authored records test atomic matching only.
    // They are not evidence that an unencoded producer can mint a certificate.
    private func authoredLogicalPair() -> (NativeSignedWordLogicalPair, [MacIRInstruction]) {
        let p = MacIRSourceSpan(address: 0x7000, byteText: "1f 01 09 6a", mnemonic: "tst", operands: "w8, w9")
        let c = MacIRSourceSpan(address: 0x7004, byteText: "e0 b7 9f 9a", mnemonic: "cset", operands: "x0, ge")
        let bits = MacIRValue.binaryExpression(op: "&",
            left: .unary(op: "(uint32_t)", value: .register(name: "w8", version: 0)),
            right: .unary(op: "(uint32_t)", value: .register(name: "w9", version: 0)))
        let old = MacIRValue.unary(op: "(int32_t)", value: bits)
        let safe = MacIRBuilder.signedProjection(bits, width: 32, partner: .immediate(0))
        let destination = MacIRValue.register(name: "x0", version: 1)
        let producer = MacIROperation.intrinsic(destination: nil, name: "compare", arguments: [old, .immediate(0)])
        let consumer = MacIROperation.compareToBool(destination: destination, condition: ">=", left: old, right: .immediate(0))
        let pair = NativeSignedWordLogicalPair(producerSource: p, originalProducer: producer,
            replacementProducer: .intrinsic(destination: nil, name: "compare", arguments: [safe, .immediate(0)]),
            consumerSource: c, originalConsumer: consumer,
            replacementConsumer: .compareToBool(destination: destination, condition: ">=", left: safe, right: .immediate(0)))
        return (pair, [.init(source: p, operation: producer), .init(source: c, operation: consumer)])
    }

    func test338AtomicPairCommitsBothExactOperations() {
        let (pair, original) = authoredLogicalPair()
        let committed = MacIRBuilder.committingNativeLogicalPairs([pair], to: original)
        XCTAssertEqual(committed.count, original.count)
        XCTAssertEqual(committed[0].operation, pair.replacementProducer)
        XCTAssertEqual(committed[1].operation, pair.replacementConsumer)
        XCTAssertNotEqual(committed[0].operation, original[0].operation)
        XCTAssertNotEqual(committed[1].operation, original[1].operation)
        XCTAssertEqual(committed.map(\.source), original.map(\.source))
    }

    func test338AtomicPairMissingProducerLeavesConsumerUntouched() {
        let (pair, original) = authoredLogicalPair()
        let changed = [original[1]]
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairMissingConsumerLeavesProducerUntouched() {
        let (pair, original) = authoredLogicalPair()
        let changed = [original[0]]
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairDuplicateProducerAddressAndOperationDeclines() {
        let (pair, original) = authoredLogicalPair()
        let changed = [original[0], original[0], original[1]]
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairDuplicateProducerAddressDifferentOperationDeclines() {
        let (pair, original) = authoredLogicalPair()
        var duplicate = original[0]
        duplicate.operation = .intrinsic(destination: nil, name: "compare", arguments: [.immediate(0), .immediate(0)])
        let changed = [original[0], duplicate, original[1]]
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairDuplicateConsumerAddressDeclines() {
        let (pair, original) = authoredLogicalPair()
        let changed = [original[0], original[1], original[1]]
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairChangedProducerOperationLeavesBothUntouched() {
        let (pair, original) = authoredLogicalPair()
        var changed = original
        changed[0].operation = .intrinsic(destination: nil, name: "compare", arguments: [.immediate(1), .immediate(0)])
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairChangedConsumerOperationLeavesBothUntouched() {
        let (pair, original) = authoredLogicalPair()
        var changed = original
        changed[1].operation = .compareToBool(destination: .register(name: "x0", version: 1),
            condition: "<", left: .immediate(0), right: .immediate(1))
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairChangedProducerBytesLeavesBothUntouched() {
        let (pair, original) = authoredLogicalPair()
        var changed = original
        changed[0].source.byteText = "1f 01 09 ea"
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairChangedConsumerBytesLeavesBothUntouched() {
        let (pair, original) = authoredLogicalPair()
        var changed = original
        changed[1].source.byteText = "e0 a7 9f 9a"
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairInsertedCollectionStatementLeavesBothUntouched() {
        let (pair, original) = authoredLogicalPair()
        let extra = MacIRInstruction(source: .init(address: 0x7002, byteText: "", mnemonic: "nop", operands: ""),
            operation: .intrinsic(destination: nil, name: "nop", arguments: []))
        let changed = [original[0], extra, original[1]]
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair], to: changed), changed)
    }

    func test338AtomicPairDuplicateProposalLeavesBothUntouched() {
        let (pair, original) = authoredLogicalPair()
        XCTAssertEqual(MacIRBuilder.committingNativeLogicalPairs([pair, pair], to: original), original)
    }

    // This existing internal policy disables native projection only. These fixtures
    // have no standalone CMP arithmetic consumer, so its legacy operations are the
    // source-equivalent main baseline for the logical/conditional seam under test.
    private func check338MainUnchanged(_ words: [UInt32], changedBytesAt index: Int? = nil,
        bytes replacement: String = "", expectedUnknownIndex: Int? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let bytes = words.flatMap { word in
            [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
             UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)]
        }
        var rows = ARM64Decoder().decode(Data(bytes), baseAddress: 0x7000,
            maxInstructionCount: words.count).map { InstructionRow(decoded: $0) }
        XCTAssertEqual(rows.count, words.count, file: file, line: line)
        if let index {
            guard rows.indices.contains(index) else { return XCTFail("missing changed source", file: file, line: line) }
            let original = rows[index]
            rows[index] = InstructionRow(address: original.address, bytes: replacement,
                mnemonic: original.mnemonic, operands: original.operands,
                hasBreakpoint: false, comment: nil)
        }
        if let expectedUnknownIndex {
            guard rows.indices.contains(expectedUnknownIndex) else {
                return XCTFail("missing unknown control row", file: file, line: line)
            }
            XCTAssertTrue(["unknown", ".word"].contains(rows[expectedUnknownIndex].mnemonic),
                rows[expectedUnknownIndex].mnemonic, file: file, line: line)
        }
        let candidate = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false)
            .buildFunction(name: "_338_exclusion", instructions: rows)
        let legacy = MacIRBuilder(skippingRejectedCFGReconciliation: false,
            explicitCFGEnabled: false, nativeSignedWordCMPEnabled: false)
            .buildFunction(name: "_338_exclusion", instructions: rows)
        XCTAssertEqual(candidate.instructions, legacy.instructions, file: file, line: line)
        XCTAssertEqual(PseudocodePrinter().print(function: candidate).text,
            PseudocodePrinter().print(function: legacy).text, file: file, line: line)
    }

    func test338UncertifiedTSTKeepsMain() {
        check338MainUnchanged([0x6a09011f, 0x9a9fb7e0, 0x710001ff, 0xd65f03c0],
            changedBytesAt: 0, bytes: "1f 01 09 ea")
    }
    func test338UncertifiedANDSKeepsMain() {
        check338MainUnchanged([0x6a09010c, 0x9a9fb7e0, 0xd65f03c0],
            changedBytesAt: 0, bytes: "0c 01 09 ea")
    }
    func test338UncertifiedCCMPKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x7a41a909, 0x9a9fb7e0, 0xd65f03c0],
            changedBytesAt: 1, bytes: "09 a9 41 fa")
    }
    func test338UncertifiedCCMNKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x3a41a909, 0x9a9fb7e0, 0xd65f03c0],
            changedBytesAt: 1, bytes: "09 a9 41 ba")
    }
    func test338UncertifiedFirstCMPKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x7a41a909, 0x9a9fb7e0, 0xd65f03c0],
            changedBytesAt: 0, bytes: "5f 05 00 f1")
    }
    func test338TSTNonadjacentKeepsMain() {
        check338MainUnchanged([0x6a09011f, 0xd503201f, 0x9a9fb7e0, 0x710001ff, 0xd65f03c0])
    }
    func test338ANDSNonadjacentKeepsMain() {
        check338MainUnchanged([0x6a09010c, 0xd503201f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338CCMPNonadjacentKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x7a41a909, 0xd503201f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338CCMNNonadjacentKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x3a41a909, 0xd503201f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338FirstCMPNonadjacentToCCMPKeepsMain() {
        check338MainUnchanged([0x7100055f, 0xd503201f, 0x7a41a909, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338TSTCallSeparatedKeepsMain() {
        check338MainUnchanged([0x6a09011f, 0x94000040, 0x9a9fb7e0, 0x710001ff, 0xd65f03c0])
    }
    func test338ANDSCallSeparatedKeepsMain() {
        check338MainUnchanged([0x6a09010c, 0x94000040, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338CCMPCallSeparatedKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x7a41a909, 0x94000040, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338CCMNCallSeparatedKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x3a41a909, 0x94000040, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338TSTInterveningXFlagWriterKeepsMain() {
        check338MainUnchanged([0x6a09011f, 0xf100013f, 0x9a9fb7e0, 0x710001ff, 0xd65f03c0])
    }
    func test338ANDSInterveningXFlagWriterKeepsMain() {
        check338MainUnchanged([0x6a09010c, 0xf100013f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338CCMPInterveningXFlagWriterKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x7a41a909, 0xf100013f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338CCMNInterveningXFlagWriterKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x3a41a909, 0xf100013f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338TSTSecondReaderDeclinesEntirePair() {
        check338MainUnchanged([0x6a09011f, 0x9a9fb7e0, 0x9a9fa7e1, 0x710001ff, 0xd65f03c0])
    }
    func test338TSTReaderAfterBranchDeclinesEntirePair() {
        check338MainUnchanged([0x6a09011f, 0x9a9fb7e0, 0x14000001, 0x9a9fa7e1, 0x710001ff, 0xd65f03c0])
    }
    func test338TSTUnknownBeforeWriterDeclinesEntirePair() {
        check338MainUnchanged([0x6a09011f, 0x9a9fb7e0, 0xffffffff, 0x710001ff, 0xd65f03c0], expectedUnknownIndex: 2)
    }
    func test338TSTRetBeforeWriterDeclinesEntirePair() {
        check340SupersededDiagnostic([0x6a09011f, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338TSTNeutralRowExceedsKillProofCap() {
        check338MainUnchanged([0x6a09011f, 0x9a9fb7e0, 0xd503201f, 0x710001ff, 0xd65f03c0])
    }
    func test338XTSTKeepsMain() {
        check340SupersededDiagnostic([0xea09011f, 0x9a9fb7e0, 0x710001ff, 0xd65f03c0])
    }
    func test338XANDSKeepsMain() {
        check338MainUnchanged([0xea09010c, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338XCCMPKeepsMain() {
        check338MainUnchanged([0x7100055f, 0xfa41a909, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338XCCMNKeepsMain() {
        check338MainUnchanged([0x7100055f, 0xba41a909, 0x9a9fb7e0, 0xd65f03c0])
    }

    func test338CallBetweenFirstCMPAndCCMPKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x94000040, 0x7a41a909, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338CallBetweenFirstCMPAndCCMNKeepsMain() {
        check338MainUnchanged([0x7100055f, 0x94000040, 0x3a41a909, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338FirstCMPNonadjacentToCCMNKeepsMain() {
        check338MainUnchanged([0x7100055f, 0xd503201f, 0x3a41a909, 0x9a9fb7e0, 0xd65f03c0])
    }
    func test338LogicalMaskBytesMustMatchText() {
        check338MainUnchanged([0x7201011f, 0x9a9fb7e0, 0x710001ff, 0xd65f03c0],
            changedBytesAt: 0, bytes: "1f 05 01 72")
    }
    func test338LogicalRegisterBytesMustMatchText() {
        check338MainUnchanged([0x6a09010c, 0x9a9fb7e0, 0xd65f03c0],
            changedBytesAt: 0, bytes: "0c 01 0a 6a")
    }
    func test338ConditionalNZCVBytesMustMatchText() {
        check338MainUnchanged([0x7100055f, 0x7a41a909, 0x9a9fb7e0, 0xd65f03c0],
            changedBytesAt: 1, bytes: "08 a9 41 7a")
    }
    func test338ConditionalGuardBytesMustMatchText() {
        check338MainUnchanged([0x7100055f, 0x7a41a909, 0x9a9fb7e0, 0xd65f03c0],
            changedBytesAt: 1, bytes: "09 b9 41 7a")
    }
    func test338ConditionalImmediateBytesMustMatchText() {
        check338MainUnchanged([0x7100055f, 0x3a41a909, 0x9a9fb7e0, 0xd65f03c0],
            changedBytesAt: 1, bytes: "09 a9 42 3a")
    }

    // Local SSA-instance guards only; these are not a whole SSA CFG/caller census.
    private func check338SSAInstanceInert(_ producer: MacIRSourceSpan, chain: Bool,
        file: StaticString = #filePath, line: UInt = #line) {
        let first = MacIRSourceSpan(address: 0x7000, byteText: "5f 05 00 71", mnemonic: "cmp", operands: "w10, #0x1")
        let consumer = MacIRSourceSpan(address: producer.address + 4, byteText: "e0 b7 9f 9a", mnemonic: "cset", operands: "x0, ge")
        let kill = MacIRSourceSpan(address: producer.address + 8, byteText: "ff 01 00 71", mnemonic: "cmp", operands: "w15, #0x0")
        var state = BuilderState()
        state.returnProducerSources = (chain ? [first] : []) + [producer, consumer, kill]
        let builder = MacIRBuilder(ssaEnabled: true)
        if chain { _ = builder.operation(for: first, state: &state) }
        _ = builder.operation(for: producer, state: &state)
        XCTAssertNil(state.lastAdjacentComparison?.nativeSignedWordLogical, file: file, line: line)
        XCTAssertNil(state.pendingConditionalCompare?.nativeSignedWordConditionalSource, file: file, line: line)
        _ = builder.operation(for: consumer, state: &state)
        XCTAssertNil(state.pendingNativeLogicalPair, file: file, line: line)
    }

    func test338SSAInstanceDoesNotMintTSTCertificate() {
        check338SSAInstanceInert(.init(address: 0x7000, byteText: "1f 01 09 6a", mnemonic: "tst", operands: "w8, w9"), chain: false)
    }
    func test338SSAInstanceDoesNotMintANDSCertificate() {
        check338SSAInstanceInert(.init(address: 0x7000, byteText: "0c 01 09 6a", mnemonic: "ands", operands: "w12, w8, w9"), chain: false)
    }
    func test338SSAInstanceDoesNotMintCCMPCertificate() {
        check338SSAInstanceInert(.init(address: 0x7004, byteText: "09 a9 41 7a", mnemonic: "ccmp", operands: "w8, #0x1, #0x9, ge"), chain: true)
    }
    func test338SSAInstanceDoesNotMintCCMNCertificate() {
        check338SSAInstanceInert(.init(address: 0x7004, byteText: "09 a9 41 3a", mnemonic: "ccmn", operands: "w8, #0x1, #0x9, ge"), chain: true)
    }

    func test338SSAOriginPolicyNativeInstanceKeepsLegacyTST() {
        let p = MacIRSourceSpan(address: 0x7000, byteText: "1f 01 09 6a", mnemonic: "tst", operands: "w8, w9")
        let c = MacIRSourceSpan(address: 0x7004, byteText: "e0 b7 9f 9a", mnemonic: "cset", operands: "x0, ge")
        let k = MacIRSourceSpan(address: 0x7008, byteText: "ff 01 00 71", mnemonic: "cmp", operands: "w15, #0x0")
        var state = BuilderState()
        state.returnProducerSources = [p, c, k]
        let builder = MacIRBuilder(skippingRejectedCFGReconciliation: true,
            explicitCFGEnabled: false, nativeSignedWordCMPEnabled: false)
        XCTAssertFalse(builder.ssaEnabled)
        _ = builder.operation(for: p, state: &state)
        XCTAssertNil(state.lastAdjacentComparison?.nativeSignedWordLogical)
        let consumer = builder.operation(for: c, state: &state)
        guard case let .compareToBool(_, ">=", left, .immediate(0)) = consumer,
              case .unary("(int32_t)", _) = left else {
            return XCTFail("original SSA-request policy must retain the existing legacy operation")
        }
        XCTAssertNil(state.pendingNativeLogicalPair)
    }

    // Exact decoder canonicalization controls: amount zero omits every shift modifier.
    // These are unshifted-value controls, not portable nonzero-ASR coverage.
    func test338TSTLSRZeroAliasKeepsUnshiftedValue() throws {
        try checkLogicalConditionalCell("TST-LSR-zero", producer: 0x6a49011f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardBits: 1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false)
    }

    func test338TSTASRZeroAliasKeepsUnshiftedValue() throws {
        try checkLogicalConditionalCell("TST-ASR-zero", producer: 0x6a89011f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardBits: 1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false)
    }

    func test338TSTRORZeroAliasKeepsUnshiftedValue() throws {
        try checkLogicalConditionalCell("TST-ROR-zero", producer: 0x6ac9011f, consumer: 0x9a9fb7e0,
            family: "tst", mnemonic: "cset", suffix: "ge", chain: false,
            guardBits: 1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false)
    }

    // Destination aliases the first source: the certificate must consume the written result.
    func test338ANDSDestinationAliasesFirstSource() throws {
        try checkLogicalConditionalCell("ANDS-destination-source-alias", producer: 0x6a090108, consumer: 0x9a9fb7e0,
            family: "ands", mnemonic: "cset", suffix: "ge", chain: false,
            guardBits: 1, otherBits: 0xffffffff,
            expected: [false, false, true, true], refused: false, distinguishAliasedResult: true)
    }

}


extension CmpCcmpChainElisionTests {
    func test340CCMN32REGREGISTERREFUSALBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_BCOND_GE", producer: 0x3a490108, consumer: 0x5400004a,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_BCOND_LT", producer: 0x3a490108, consumer: 0x5400004b,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_BCOND_GT", producer: 0x3a490108, consumer: 0x5400004c,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_BCOND_LE", producer: 0x3a490108, consumer: 0x5400004d,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "b.le",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSET_GE", producer: 0x3a490108, consumer: 0x9a9fb7e0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSET_LT", producer: 0x3a490108, consumer: 0x9a9fa7e0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSET_GT", producer: 0x3a490108, consumer: 0x9a9fd7e0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSET_LE", producer: 0x3a490108, consumer: 0x9a9fc7e0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSETM_GE", producer: 0x3a490108, consumer: 0xda9fb3e0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSETM_LT", producer: 0x3a490108, consumer: 0xda9fa3e0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSETM_GT", producer: 0x3a490108, consumer: 0xda9fd3e0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSETM_LE", producer: 0x3a490108, consumer: 0xda9fc3e0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSEL_GE", producer: 0x3a490108, consumer: 0x9a8ea1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSEL_LT", producer: 0x3a490108, consumer: 0x9a8eb1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSEL_GT", producer: 0x3a490108, consumer: 0x9a8ec1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSEL_LE", producer: 0x3a490108, consumer: 0x9a8ed1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSINC_GE", producer: 0x3a490108, consumer: 0x9a8ea5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSINC_LT", producer: 0x3a490108, consumer: 0x9a8eb5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSINC_GT", producer: 0x3a490108, consumer: 0x9a8ec5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSINC_LE", producer: 0x3a490108, consumer: 0x9a8ed5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSINV_GE", producer: 0x3a490108, consumer: 0xda8ea1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSINV_LT", producer: 0x3a490108, consumer: 0xda8eb1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSINV_GT", producer: 0x3a490108, consumer: 0xda8ec1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSINV_LE", producer: 0x3a490108, consumer: 0xda8ed1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSNEG_GE", producer: 0x3a490108, consumer: 0xda8ea5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSNEG_LT", producer: 0x3a490108, consumer: 0xda8eb5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSNEG_GT", producer: 0x3a490108, consumer: 0xda8ec5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CSNEG_LE", producer: 0x3a490108, consumer: 0xda8ed5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CINC_GE", producer: 0x3a490108, consumer: 0x9a8db5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CINC_LT", producer: 0x3a490108, consumer: 0x9a8da5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CINC_GT", producer: 0x3a490108, consumer: 0x9a8dd5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CINC_LE", producer: 0x3a490108, consumer: 0x9a8dc5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CINV_GE", producer: 0x3a490108, consumer: 0xda8db1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CINV_LT", producer: 0x3a490108, consumer: 0xda8da1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CINV_GT", producer: 0x3a490108, consumer: 0xda8dd1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CINV_LE", producer: 0x3a490108, consumer: 0xda8dc1a0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CNEG_GE", producer: 0x3a490108, consumer: 0xda8db5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CNEG_LT", producer: 0x3a490108, consumer: 0xda8da5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CNEG_GT", producer: 0x3a490108, consumer: 0xda8dd5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN32REGREGISTERREFUSALCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_32_REG_EQ_CNEG_LE", producer: 0x3a490108, consumer: 0xda8dc5a0,
            family: "ccmn", form: "REG", width: 32, suffix: "le", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMEQBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_BCOND_GE", producer: 0xfa410908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_BCOND_LT", producer: 0xfa410908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_BCOND_GT", producer: 0xfa410908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_BCOND_LE", producer: 0xfa410908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSET_GE", producer: 0xfa410908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSET_LT", producer: 0xfa410908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSET_GT", producer: 0xfa410908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSET_LE", producer: 0xfa410908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSETM_GE", producer: 0xfa410908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSETM_LT", producer: 0xfa410908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSETM_GT", producer: 0xfa410908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSETM_LE", producer: 0xfa410908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSEL_GE", producer: 0xfa410908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSEL_LT", producer: 0xfa410908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSEL_GT", producer: 0xfa410908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSEL_LE", producer: 0xfa410908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSINC_GE", producer: 0xfa410908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSINC_LT", producer: 0xfa410908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSINC_GT", producer: 0xfa410908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSINC_LE", producer: 0xfa410908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSINV_GE", producer: 0xfa410908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSINV_LT", producer: 0xfa410908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSINV_GT", producer: 0xfa410908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSINV_LE", producer: 0xfa410908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSNEG_GE", producer: 0xfa410908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSNEG_LT", producer: 0xfa410908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSNEG_GT", producer: 0xfa410908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CSNEG_LE", producer: 0xfa410908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CINC_GE", producer: 0xfa410908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CINC_LT", producer: 0xfa410908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CINC_GT", producer: 0xfa410908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CINC_LE", producer: 0xfa410908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CINV_GE", producer: 0xfa410908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CINV_LT", producer: 0xfa410908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CINV_GT", producer: 0xfa410908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CINV_LE", producer: 0xfa410908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CNEG_GE", producer: 0xfa410908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CNEG_LT", producer: 0xfa410908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CNEG_GT", producer: 0xfa410908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMEQCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_EQ_CNEG_LE", producer: 0xfa410908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNEBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_BCOND_GE", producer: 0xfa411908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNEBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_BCOND_LT", producer: 0xfa411908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNEBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_BCOND_GT", producer: 0xfa411908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNEBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_BCOND_LE", producer: 0xfa411908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSET_GE", producer: 0xfa411908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSET_LT", producer: 0xfa411908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSET_GT", producer: 0xfa411908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSET_LE", producer: 0xfa411908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSETM_GE", producer: 0xfa411908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSETM_LT", producer: 0xfa411908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSETM_GT", producer: 0xfa411908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSETM_LE", producer: 0xfa411908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSEL_GE", producer: 0xfa411908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSEL_LT", producer: 0xfa411908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSEL_GT", producer: 0xfa411908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSEL_LE", producer: 0xfa411908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSINC_GE", producer: 0xfa411908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSINC_LT", producer: 0xfa411908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSINC_GT", producer: 0xfa411908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSINC_LE", producer: 0xfa411908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSINV_GE", producer: 0xfa411908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSINV_LT", producer: 0xfa411908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSINV_GT", producer: 0xfa411908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSINV_LE", producer: 0xfa411908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSNEG_GE", producer: 0xfa411908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSNEG_LT", producer: 0xfa411908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSNEG_GT", producer: 0xfa411908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CSNEG_LE", producer: 0xfa411908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CINC_GE", producer: 0xfa411908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CINC_LT", producer: 0xfa411908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CINC_GT", producer: 0xfa411908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CINC_LE", producer: 0xfa411908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CINV_GE", producer: 0xfa411908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CINV_LT", producer: 0xfa411908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CINV_GT", producer: 0xfa411908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CINV_LE", producer: 0xfa411908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CNEG_GE", producer: 0xfa411908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CNEG_LT", producer: 0xfa411908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CNEG_GT", producer: 0xfa411908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMNECNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_NE_CNEG_LE", producer: 0xfa411908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_BCOND_GE", producer: 0xfa412908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_BCOND_LT", producer: 0xfa412908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_BCOND_GT", producer: 0xfa412908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_BCOND_LE", producer: 0xfa412908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSET_GE", producer: 0xfa412908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSET_LT", producer: 0xfa412908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSET_GT", producer: 0xfa412908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSET_LE", producer: 0xfa412908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSETM_GE", producer: 0xfa412908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSETM_LT", producer: 0xfa412908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSETM_GT", producer: 0xfa412908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSETM_LE", producer: 0xfa412908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSEL_GE", producer: 0xfa412908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSEL_LT", producer: 0xfa412908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSEL_GT", producer: 0xfa412908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSEL_LE", producer: 0xfa412908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSINC_GE", producer: 0xfa412908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSINC_LT", producer: 0xfa412908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSINC_GT", producer: 0xfa412908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSINC_LE", producer: 0xfa412908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSINV_GE", producer: 0xfa412908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSINV_LT", producer: 0xfa412908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSINV_GT", producer: 0xfa412908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSINV_LE", producer: 0xfa412908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSNEG_GE", producer: 0xfa412908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSNEG_LT", producer: 0xfa412908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSNEG_GT", producer: 0xfa412908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CSNEG_LE", producer: 0xfa412908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CINC_GE", producer: 0xfa412908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CINC_LT", producer: 0xfa412908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CINC_GT", producer: 0xfa412908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CINC_LE", producer: 0xfa412908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CINV_GE", producer: 0xfa412908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CINV_LT", producer: 0xfa412908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CINV_GT", producer: 0xfa412908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CINV_LE", producer: 0xfa412908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CNEG_GE", producer: 0xfa412908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CNEG_LT", producer: 0xfa412908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CNEG_GT", producer: 0xfa412908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHSCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HS_CNEG_LE", producer: 0xfa412908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_BCOND_GE", producer: 0xfa413908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_BCOND_LT", producer: 0xfa413908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_BCOND_GT", producer: 0xfa413908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_BCOND_LE", producer: 0xfa413908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSET_GE", producer: 0xfa413908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSET_LT", producer: 0xfa413908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSET_GT", producer: 0xfa413908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSET_LE", producer: 0xfa413908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSETM_GE", producer: 0xfa413908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSETM_LT", producer: 0xfa413908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSETM_GT", producer: 0xfa413908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSETM_LE", producer: 0xfa413908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSEL_GE", producer: 0xfa413908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSEL_LT", producer: 0xfa413908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSEL_GT", producer: 0xfa413908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSEL_LE", producer: 0xfa413908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSINC_GE", producer: 0xfa413908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSINC_LT", producer: 0xfa413908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSINC_GT", producer: 0xfa413908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSINC_LE", producer: 0xfa413908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSINV_GE", producer: 0xfa413908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSINV_LT", producer: 0xfa413908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSINV_GT", producer: 0xfa413908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSINV_LE", producer: 0xfa413908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSNEG_GE", producer: 0xfa413908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSNEG_LT", producer: 0xfa413908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSNEG_GT", producer: 0xfa413908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CSNEG_LE", producer: 0xfa413908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CINC_GE", producer: 0xfa413908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CINC_LT", producer: 0xfa413908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CINC_GT", producer: 0xfa413908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CINC_LE", producer: 0xfa413908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CINV_GE", producer: 0xfa413908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CINV_LT", producer: 0xfa413908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CINV_GT", producer: 0xfa413908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CINV_LE", producer: 0xfa413908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CNEG_GE", producer: 0xfa413908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CNEG_LT", producer: 0xfa413908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CNEG_GT", producer: 0xfa413908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLOCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LO_CNEG_LE", producer: 0xfa413908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_BCOND_GE", producer: 0xfa414908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_BCOND_LT", producer: 0xfa414908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_BCOND_GT", producer: 0xfa414908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_BCOND_LE", producer: 0xfa414908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSET_GE", producer: 0xfa414908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSET_LT", producer: 0xfa414908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSET_GT", producer: 0xfa414908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSET_LE", producer: 0xfa414908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSETM_GE", producer: 0xfa414908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSETM_LT", producer: 0xfa414908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSETM_GT", producer: 0xfa414908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSETM_LE", producer: 0xfa414908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSEL_GE", producer: 0xfa414908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSEL_LT", producer: 0xfa414908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSEL_GT", producer: 0xfa414908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSEL_LE", producer: 0xfa414908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSINC_GE", producer: 0xfa414908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSINC_LT", producer: 0xfa414908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSINC_GT", producer: 0xfa414908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSINC_LE", producer: 0xfa414908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSINV_GE", producer: 0xfa414908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSINV_LT", producer: 0xfa414908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSINV_GT", producer: 0xfa414908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSINV_LE", producer: 0xfa414908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSNEG_GE", producer: 0xfa414908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSNEG_LT", producer: 0xfa414908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSNEG_GT", producer: 0xfa414908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CSNEG_LE", producer: 0xfa414908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CINC_GE", producer: 0xfa414908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CINC_LT", producer: 0xfa414908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CINC_GT", producer: 0xfa414908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CINC_LE", producer: 0xfa414908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CINV_GE", producer: 0xfa414908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CINV_LT", producer: 0xfa414908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CINV_GT", producer: 0xfa414908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CINV_LE", producer: 0xfa414908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CNEG_GE", producer: 0xfa414908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CNEG_LT", producer: 0xfa414908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CNEG_GT", producer: 0xfa414908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMUNSUPPORTEDGUARDCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_MI_CNEG_LE", producer: 0xfa414908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64IMMHIBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_BCOND_GE", producer: 0xfa418908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHIBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_BCOND_LT", producer: 0xfa418908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHIBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_BCOND_GT", producer: 0xfa418908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHIBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_BCOND_LE", producer: 0xfa418908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSET_GE", producer: 0xfa418908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSET_LT", producer: 0xfa418908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSET_GT", producer: 0xfa418908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSET_LE", producer: 0xfa418908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSETM_GE", producer: 0xfa418908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSETM_LT", producer: 0xfa418908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSETM_GT", producer: 0xfa418908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSETM_LE", producer: 0xfa418908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSEL_GE", producer: 0xfa418908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSEL_LT", producer: 0xfa418908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSEL_GT", producer: 0xfa418908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSEL_LE", producer: 0xfa418908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSINC_GE", producer: 0xfa418908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSINC_LT", producer: 0xfa418908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSINC_GT", producer: 0xfa418908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSINC_LE", producer: 0xfa418908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSINV_GE", producer: 0xfa418908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSINV_LT", producer: 0xfa418908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSINV_GT", producer: 0xfa418908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSINV_LE", producer: 0xfa418908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSNEG_GE", producer: 0xfa418908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSNEG_LT", producer: 0xfa418908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSNEG_GT", producer: 0xfa418908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CSNEG_LE", producer: 0xfa418908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CINC_GE", producer: 0xfa418908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CINC_LT", producer: 0xfa418908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CINC_GT", producer: 0xfa418908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CINC_LE", producer: 0xfa418908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CINV_GE", producer: 0xfa418908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CINV_LT", producer: 0xfa418908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CINV_GT", producer: 0xfa418908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CINV_LE", producer: 0xfa418908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CNEG_GE", producer: 0xfa418908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CNEG_LT", producer: 0xfa418908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CNEG_GT", producer: 0xfa418908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMHICNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_HI_CNEG_LE", producer: 0xfa418908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_BCOND_GE", producer: 0xfa419908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_BCOND_LT", producer: 0xfa419908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_BCOND_GT", producer: 0xfa419908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_BCOND_LE", producer: 0xfa419908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSET_GE", producer: 0xfa419908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSET_LT", producer: 0xfa419908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSET_GT", producer: 0xfa419908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSET_LE", producer: 0xfa419908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSETM_GE", producer: 0xfa419908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSETM_LT", producer: 0xfa419908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSETM_GT", producer: 0xfa419908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSETM_LE", producer: 0xfa419908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSEL_GE", producer: 0xfa419908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSEL_LT", producer: 0xfa419908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSEL_GT", producer: 0xfa419908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSEL_LE", producer: 0xfa419908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSINC_GE", producer: 0xfa419908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSINC_LT", producer: 0xfa419908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSINC_GT", producer: 0xfa419908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSINC_LE", producer: 0xfa419908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSINV_GE", producer: 0xfa419908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSINV_LT", producer: 0xfa419908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSINV_GT", producer: 0xfa419908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSINV_LE", producer: 0xfa419908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSNEG_GE", producer: 0xfa419908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSNEG_LT", producer: 0xfa419908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSNEG_GT", producer: 0xfa419908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CSNEG_LE", producer: 0xfa419908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CINC_GE", producer: 0xfa419908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CINC_LT", producer: 0xfa419908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CINC_GT", producer: 0xfa419908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CINC_LE", producer: 0xfa419908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CINV_GE", producer: 0xfa419908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CINV_LT", producer: 0xfa419908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CINV_GT", producer: 0xfa419908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CINV_LE", producer: 0xfa419908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CNEG_GE", producer: 0xfa419908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CNEG_LT", producer: 0xfa419908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CNEG_GT", producer: 0xfa419908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLSCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LS_CNEG_LE", producer: 0xfa419908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGEBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_BCOND_GE", producer: 0xfa41a908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGEBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_BCOND_LT", producer: 0xfa41a908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGEBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_BCOND_GT", producer: 0xfa41a908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGEBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_BCOND_LE", producer: 0xfa41a908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSET_GE", producer: 0xfa41a908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSET_LT", producer: 0xfa41a908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSET_GT", producer: 0xfa41a908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSET_LE", producer: 0xfa41a908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSETM_GE", producer: 0xfa41a908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSETM_LT", producer: 0xfa41a908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSETM_GT", producer: 0xfa41a908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSETM_LE", producer: 0xfa41a908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSEL_GE", producer: 0xfa41a908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSEL_LT", producer: 0xfa41a908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSEL_GT", producer: 0xfa41a908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSEL_LE", producer: 0xfa41a908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSINC_GE", producer: 0xfa41a908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSINC_LT", producer: 0xfa41a908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSINC_GT", producer: 0xfa41a908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSINC_LE", producer: 0xfa41a908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSINV_GE", producer: 0xfa41a908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSINV_LT", producer: 0xfa41a908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSINV_GT", producer: 0xfa41a908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSINV_LE", producer: 0xfa41a908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSNEG_GE", producer: 0xfa41a908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSNEG_LT", producer: 0xfa41a908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSNEG_GT", producer: 0xfa41a908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CSNEG_LE", producer: 0xfa41a908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CINC_GE", producer: 0xfa41a908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CINC_LT", producer: 0xfa41a908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CINC_GT", producer: 0xfa41a908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CINC_LE", producer: 0xfa41a908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CINV_GE", producer: 0xfa41a908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CINV_LT", producer: 0xfa41a908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CINV_GT", producer: 0xfa41a908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CINV_LE", producer: 0xfa41a908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CNEG_GE", producer: 0xfa41a908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CNEG_LT", producer: 0xfa41a908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CNEG_GT", producer: 0xfa41a908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGECNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GE_CNEG_LE", producer: 0xfa41a908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_BCOND_GE", producer: 0xfa41b908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_BCOND_LT", producer: 0xfa41b908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_BCOND_GT", producer: 0xfa41b908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_BCOND_LE", producer: 0xfa41b908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSET_GE", producer: 0xfa41b908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSET_LT", producer: 0xfa41b908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSET_GT", producer: 0xfa41b908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSET_LE", producer: 0xfa41b908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSETM_GE", producer: 0xfa41b908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSETM_LT", producer: 0xfa41b908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSETM_GT", producer: 0xfa41b908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSETM_LE", producer: 0xfa41b908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSEL_GE", producer: 0xfa41b908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSEL_LT", producer: 0xfa41b908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSEL_GT", producer: 0xfa41b908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSEL_LE", producer: 0xfa41b908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSINC_GE", producer: 0xfa41b908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSINC_LT", producer: 0xfa41b908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSINC_GT", producer: 0xfa41b908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSINC_LE", producer: 0xfa41b908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSINV_GE", producer: 0xfa41b908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSINV_LT", producer: 0xfa41b908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSINV_GT", producer: 0xfa41b908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSINV_LE", producer: 0xfa41b908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSNEG_GE", producer: 0xfa41b908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSNEG_LT", producer: 0xfa41b908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSNEG_GT", producer: 0xfa41b908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CSNEG_LE", producer: 0xfa41b908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CINC_GE", producer: 0xfa41b908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CINC_LT", producer: 0xfa41b908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CINC_GT", producer: 0xfa41b908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CINC_LE", producer: 0xfa41b908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CINV_GE", producer: 0xfa41b908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CINV_LT", producer: 0xfa41b908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CINV_GT", producer: 0xfa41b908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CINV_LE", producer: 0xfa41b908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CNEG_GE", producer: 0xfa41b908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CNEG_LT", producer: 0xfa41b908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CNEG_GT", producer: 0xfa41b908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLTCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LT_CNEG_LE", producer: 0xfa41b908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_BCOND_GE", producer: 0xfa41c908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_BCOND_LT", producer: 0xfa41c908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_BCOND_GT", producer: 0xfa41c908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_BCOND_LE", producer: 0xfa41c908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSET_GE", producer: 0xfa41c908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSET_LT", producer: 0xfa41c908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSET_GT", producer: 0xfa41c908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSET_LE", producer: 0xfa41c908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSETM_GE", producer: 0xfa41c908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSETM_LT", producer: 0xfa41c908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSETM_GT", producer: 0xfa41c908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSETM_LE", producer: 0xfa41c908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSEL_GE", producer: 0xfa41c908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSEL_LT", producer: 0xfa41c908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSEL_GT", producer: 0xfa41c908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSEL_LE", producer: 0xfa41c908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSINC_GE", producer: 0xfa41c908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSINC_LT", producer: 0xfa41c908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSINC_GT", producer: 0xfa41c908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSINC_LE", producer: 0xfa41c908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSINV_GE", producer: 0xfa41c908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSINV_LT", producer: 0xfa41c908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSINV_GT", producer: 0xfa41c908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSINV_LE", producer: 0xfa41c908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSNEG_GE", producer: 0xfa41c908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSNEG_LT", producer: 0xfa41c908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSNEG_GT", producer: 0xfa41c908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CSNEG_LE", producer: 0xfa41c908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CINC_GE", producer: 0xfa41c908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CINC_LT", producer: 0xfa41c908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CINC_GT", producer: 0xfa41c908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CINC_LE", producer: 0xfa41c908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CINV_GE", producer: 0xfa41c908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CINV_LT", producer: 0xfa41c908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CINV_GT", producer: 0xfa41c908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CINV_LE", producer: 0xfa41c908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CNEG_GE", producer: 0xfa41c908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CNEG_LT", producer: 0xfa41c908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CNEG_GT", producer: 0xfa41c908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMGTCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_GT_CNEG_LE", producer: 0xfa41c908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLEBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_BCOND_GE", producer: 0xfa41d908, consumer: 0x5400004a,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLEBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_BCOND_LT", producer: 0xfa41d908, consumer: 0x5400004b,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLEBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_BCOND_GT", producer: 0xfa41d908, consumer: 0x5400004c,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLEBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_BCOND_LE", producer: 0xfa41d908, consumer: 0x5400004d,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSET_GE", producer: 0xfa41d908, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSET_LT", producer: 0xfa41d908, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSET_GT", producer: 0xfa41d908, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSET_LE", producer: 0xfa41d908, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSETM_GE", producer: 0xfa41d908, consumer: 0xda9fb3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSETM_LT", producer: 0xfa41d908, consumer: 0xda9fa3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSETM_GT", producer: 0xfa41d908, consumer: 0xda9fd3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSETM_LE", producer: 0xfa41d908, consumer: 0xda9fc3e0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSEL_GE", producer: 0xfa41d908, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSEL_LT", producer: 0xfa41d908, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSEL_GT", producer: 0xfa41d908, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSEL_LE", producer: 0xfa41d908, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSINC_GE", producer: 0xfa41d908, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSINC_LT", producer: 0xfa41d908, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSINC_GT", producer: 0xfa41d908, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSINC_LE", producer: 0xfa41d908, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSINV_GE", producer: 0xfa41d908, consumer: 0xda8ea1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSINV_LT", producer: 0xfa41d908, consumer: 0xda8eb1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSINV_GT", producer: 0xfa41d908, consumer: 0xda8ec1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSINV_LE", producer: 0xfa41d908, consumer: 0xda8ed1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSNEG_GE", producer: 0xfa41d908, consumer: 0xda8ea5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSNEG_LT", producer: 0xfa41d908, consumer: 0xda8eb5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSNEG_GT", producer: 0xfa41d908, consumer: 0xda8ec5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CSNEG_LE", producer: 0xfa41d908, consumer: 0xda8ed5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CINC_GE", producer: 0xfa41d908, consumer: 0x9a8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CINC_LT", producer: 0xfa41d908, consumer: 0x9a8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CINC_GT", producer: 0xfa41d908, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CINC_LE", producer: 0xfa41d908, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CINV_GE", producer: 0xfa41d908, consumer: 0xda8db1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CINV_LT", producer: 0xfa41d908, consumer: 0xda8da1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CINV_GT", producer: 0xfa41d908, consumer: 0xda8dd1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CINV_LE", producer: 0xfa41d908, consumer: 0xda8dc1a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CNEG_GE", producer: 0xfa41d908, consumer: 0xda8db5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CNEG_LT", producer: 0xfa41d908, consumer: 0xda8da5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CNEG_GT", producer: 0xfa41d908, consumer: 0xda8dd5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64IMMLECNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_IMM_LE_CNEG_LE", producer: 0xfa41d908, consumer: 0xda8dc5a0,
            family: "ccmp", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_BCOND_GE", producer: 0xfa490108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_BCOND_LT", producer: 0xfa490108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_BCOND_GT", producer: 0xfa490108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_BCOND_LE", producer: 0xfa490108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSET_GE", producer: 0xfa490108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSET_LT", producer: 0xfa490108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSET_GT", producer: 0xfa490108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSET_LE", producer: 0xfa490108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSETM_GE", producer: 0xfa490108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSETM_LT", producer: 0xfa490108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSETM_GT", producer: 0xfa490108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSETM_LE", producer: 0xfa490108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSEL_GE", producer: 0xfa490108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSEL_LT", producer: 0xfa490108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSEL_GT", producer: 0xfa490108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSEL_LE", producer: 0xfa490108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSINC_GE", producer: 0xfa490108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSINC_LT", producer: 0xfa490108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSINC_GT", producer: 0xfa490108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSINC_LE", producer: 0xfa490108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSINV_GE", producer: 0xfa490108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSINV_LT", producer: 0xfa490108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSINV_GT", producer: 0xfa490108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSINV_LE", producer: 0xfa490108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSNEG_GE", producer: 0xfa490108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSNEG_LT", producer: 0xfa490108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSNEG_GT", producer: 0xfa490108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CSNEG_LE", producer: 0xfa490108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CINC_GE", producer: 0xfa490108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CINC_LT", producer: 0xfa490108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CINC_GT", producer: 0xfa490108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CINC_LE", producer: 0xfa490108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CINV_GE", producer: 0xfa490108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CINV_LT", producer: 0xfa490108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CINV_GT", producer: 0xfa490108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CINV_LE", producer: 0xfa490108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CNEG_GE", producer: 0xfa490108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CNEG_LT", producer: 0xfa490108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CNEG_GT", producer: 0xfa490108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGEQCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_EQ_CNEG_LE", producer: 0xfa490108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "eq", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNEBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_BCOND_GE", producer: 0xfa491108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNEBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_BCOND_LT", producer: 0xfa491108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNEBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_BCOND_GT", producer: 0xfa491108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNEBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_BCOND_LE", producer: 0xfa491108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSET_GE", producer: 0xfa491108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSET_LT", producer: 0xfa491108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSET_GT", producer: 0xfa491108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSET_LE", producer: 0xfa491108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSETM_GE", producer: 0xfa491108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSETM_LT", producer: 0xfa491108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSETM_GT", producer: 0xfa491108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSETM_LE", producer: 0xfa491108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSEL_GE", producer: 0xfa491108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSEL_LT", producer: 0xfa491108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSEL_GT", producer: 0xfa491108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSEL_LE", producer: 0xfa491108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSINC_GE", producer: 0xfa491108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSINC_LT", producer: 0xfa491108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSINC_GT", producer: 0xfa491108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSINC_LE", producer: 0xfa491108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSINV_GE", producer: 0xfa491108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSINV_LT", producer: 0xfa491108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSINV_GT", producer: 0xfa491108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSINV_LE", producer: 0xfa491108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSNEG_GE", producer: 0xfa491108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSNEG_LT", producer: 0xfa491108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSNEG_GT", producer: 0xfa491108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CSNEG_LE", producer: 0xfa491108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CINC_GE", producer: 0xfa491108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CINC_LT", producer: 0xfa491108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CINC_GT", producer: 0xfa491108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CINC_LE", producer: 0xfa491108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CINV_GE", producer: 0xfa491108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CINV_LT", producer: 0xfa491108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CINV_GT", producer: 0xfa491108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CINV_LE", producer: 0xfa491108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CNEG_GE", producer: 0xfa491108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CNEG_LT", producer: 0xfa491108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CNEG_GT", producer: 0xfa491108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGNECNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_NE_CNEG_LE", producer: 0xfa491108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "ne", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_BCOND_GE", producer: 0xfa492108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_BCOND_LT", producer: 0xfa492108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_BCOND_GT", producer: 0xfa492108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_BCOND_LE", producer: 0xfa492108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSET_GE", producer: 0xfa492108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSET_LT", producer: 0xfa492108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSET_GT", producer: 0xfa492108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSET_LE", producer: 0xfa492108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSETM_GE", producer: 0xfa492108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSETM_LT", producer: 0xfa492108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSETM_GT", producer: 0xfa492108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSETM_LE", producer: 0xfa492108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSEL_GE", producer: 0xfa492108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSEL_LT", producer: 0xfa492108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSEL_GT", producer: 0xfa492108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSEL_LE", producer: 0xfa492108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSINC_GE", producer: 0xfa492108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSINC_LT", producer: 0xfa492108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSINC_GT", producer: 0xfa492108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSINC_LE", producer: 0xfa492108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSINV_GE", producer: 0xfa492108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSINV_LT", producer: 0xfa492108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSINV_GT", producer: 0xfa492108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSINV_LE", producer: 0xfa492108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSNEG_GE", producer: 0xfa492108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSNEG_LT", producer: 0xfa492108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSNEG_GT", producer: 0xfa492108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CSNEG_LE", producer: 0xfa492108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CINC_GE", producer: 0xfa492108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CINC_LT", producer: 0xfa492108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CINC_GT", producer: 0xfa492108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CINC_LE", producer: 0xfa492108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CINV_GE", producer: 0xfa492108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CINV_LT", producer: 0xfa492108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CINV_GT", producer: 0xfa492108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CINV_LE", producer: 0xfa492108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CNEG_GE", producer: 0xfa492108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CNEG_LT", producer: 0xfa492108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CNEG_GT", producer: 0xfa492108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHSCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HS_CNEG_LE", producer: 0xfa492108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "hs", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_BCOND_GE", producer: 0xfa493108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_BCOND_LT", producer: 0xfa493108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_BCOND_GT", producer: 0xfa493108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_BCOND_LE", producer: 0xfa493108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSET_GE", producer: 0xfa493108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSET_LT", producer: 0xfa493108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSET_GT", producer: 0xfa493108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSET_LE", producer: 0xfa493108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSETM_GE", producer: 0xfa493108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSETM_LT", producer: 0xfa493108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSETM_GT", producer: 0xfa493108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSETM_LE", producer: 0xfa493108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSEL_GE", producer: 0xfa493108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSEL_LT", producer: 0xfa493108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSEL_GT", producer: 0xfa493108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSEL_LE", producer: 0xfa493108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSINC_GE", producer: 0xfa493108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSINC_LT", producer: 0xfa493108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSINC_GT", producer: 0xfa493108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSINC_LE", producer: 0xfa493108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSINV_GE", producer: 0xfa493108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSINV_LT", producer: 0xfa493108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSINV_GT", producer: 0xfa493108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSINV_LE", producer: 0xfa493108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSNEG_GE", producer: 0xfa493108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSNEG_LT", producer: 0xfa493108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSNEG_GT", producer: 0xfa493108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CSNEG_LE", producer: 0xfa493108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CINC_GE", producer: 0xfa493108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CINC_LT", producer: 0xfa493108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CINC_GT", producer: 0xfa493108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CINC_LE", producer: 0xfa493108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CINV_GE", producer: 0xfa493108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CINV_LT", producer: 0xfa493108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CINV_GT", producer: 0xfa493108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CINV_LE", producer: 0xfa493108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CNEG_GE", producer: 0xfa493108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CNEG_LT", producer: 0xfa493108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CNEG_GT", producer: 0xfa493108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLOCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LO_CNEG_LE", producer: 0xfa493108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "lo", preservation: false, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_BCOND_GE", producer: 0xfa494108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_BCOND_LT", producer: 0xfa494108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_BCOND_GT", producer: 0xfa494108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_BCOND_LE", producer: 0xfa494108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSET_GE", producer: 0xfa494108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSET_LT", producer: 0xfa494108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSET_GT", producer: 0xfa494108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSET_LE", producer: 0xfa494108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSETM_GE", producer: 0xfa494108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSETM_LT", producer: 0xfa494108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSETM_GT", producer: 0xfa494108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSETM_LE", producer: 0xfa494108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSEL_GE", producer: 0xfa494108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSEL_LT", producer: 0xfa494108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSEL_GT", producer: 0xfa494108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSEL_LE", producer: 0xfa494108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSINC_GE", producer: 0xfa494108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSINC_LT", producer: 0xfa494108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSINC_GT", producer: 0xfa494108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSINC_LE", producer: 0xfa494108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSINV_GE", producer: 0xfa494108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSINV_LT", producer: 0xfa494108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSINV_GT", producer: 0xfa494108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSINV_LE", producer: 0xfa494108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSNEG_GE", producer: 0xfa494108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSNEG_LT", producer: 0xfa494108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSNEG_GT", producer: 0xfa494108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CSNEG_LE", producer: 0xfa494108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CINC_GE", producer: 0xfa494108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CINC_LT", producer: 0xfa494108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CINC_GT", producer: 0xfa494108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CINC_LE", producer: 0xfa494108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CINV_GE", producer: 0xfa494108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CINV_LT", producer: 0xfa494108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CINV_GT", producer: 0xfa494108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CINV_LE", producer: 0xfa494108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CNEG_GE", producer: 0xfa494108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CNEG_LT", producer: 0xfa494108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CNEG_GT", producer: 0xfa494108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGUNSUPPORTEDGUARDCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_MI_CNEG_LE", producer: 0xfa494108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMP64REGHIBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_BCOND_GE", producer: 0xfa498108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHIBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_BCOND_LT", producer: 0xfa498108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHIBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_BCOND_GT", producer: 0xfa498108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHIBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_BCOND_LE", producer: 0xfa498108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSET_GE", producer: 0xfa498108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSET_LT", producer: 0xfa498108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSET_GT", producer: 0xfa498108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSET_LE", producer: 0xfa498108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSETM_GE", producer: 0xfa498108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSETM_LT", producer: 0xfa498108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSETM_GT", producer: 0xfa498108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSETM_LE", producer: 0xfa498108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSEL_GE", producer: 0xfa498108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSEL_LT", producer: 0xfa498108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSEL_GT", producer: 0xfa498108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSEL_LE", producer: 0xfa498108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSINC_GE", producer: 0xfa498108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSINC_LT", producer: 0xfa498108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSINC_GT", producer: 0xfa498108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSINC_LE", producer: 0xfa498108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSINV_GE", producer: 0xfa498108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSINV_LT", producer: 0xfa498108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSINV_GT", producer: 0xfa498108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSINV_LE", producer: 0xfa498108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSNEG_GE", producer: 0xfa498108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSNEG_LT", producer: 0xfa498108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSNEG_GT", producer: 0xfa498108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CSNEG_LE", producer: 0xfa498108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CINC_GE", producer: 0xfa498108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CINC_LT", producer: 0xfa498108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CINC_GT", producer: 0xfa498108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CINC_LE", producer: 0xfa498108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CINV_GE", producer: 0xfa498108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CINV_LT", producer: 0xfa498108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CINV_GT", producer: 0xfa498108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CINV_LE", producer: 0xfa498108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CNEG_GE", producer: 0xfa498108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CNEG_LT", producer: 0xfa498108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CNEG_GT", producer: 0xfa498108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGHICNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_HI_CNEG_LE", producer: 0xfa498108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "hi", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_BCOND_GE", producer: 0xfa499108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_BCOND_LT", producer: 0xfa499108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_BCOND_GT", producer: 0xfa499108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_BCOND_LE", producer: 0xfa499108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSET_GE", producer: 0xfa499108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSET_LT", producer: 0xfa499108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSET_GT", producer: 0xfa499108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSET_LE", producer: 0xfa499108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSETM_GE", producer: 0xfa499108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSETM_LT", producer: 0xfa499108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSETM_GT", producer: 0xfa499108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSETM_LE", producer: 0xfa499108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSEL_GE", producer: 0xfa499108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSEL_LT", producer: 0xfa499108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSEL_GT", producer: 0xfa499108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSEL_LE", producer: 0xfa499108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSINC_GE", producer: 0xfa499108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSINC_LT", producer: 0xfa499108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSINC_GT", producer: 0xfa499108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSINC_LE", producer: 0xfa499108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSINV_GE", producer: 0xfa499108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSINV_LT", producer: 0xfa499108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSINV_GT", producer: 0xfa499108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSINV_LE", producer: 0xfa499108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSNEG_GE", producer: 0xfa499108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSNEG_LT", producer: 0xfa499108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSNEG_GT", producer: 0xfa499108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CSNEG_LE", producer: 0xfa499108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CINC_GE", producer: 0xfa499108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CINC_LT", producer: 0xfa499108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CINC_GT", producer: 0xfa499108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CINC_LE", producer: 0xfa499108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CINV_GE", producer: 0xfa499108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CINV_LT", producer: 0xfa499108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CINV_GT", producer: 0xfa499108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CINV_LE", producer: 0xfa499108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CNEG_GE", producer: 0xfa499108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CNEG_LT", producer: 0xfa499108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CNEG_GT", producer: 0xfa499108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLSCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LS_CNEG_LE", producer: 0xfa499108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "ls", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGEBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_BCOND_GE", producer: 0xfa49a108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGEBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_BCOND_LT", producer: 0xfa49a108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGEBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_BCOND_GT", producer: 0xfa49a108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGEBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_BCOND_LE", producer: 0xfa49a108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSET_GE", producer: 0xfa49a108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSET_LT", producer: 0xfa49a108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSET_GT", producer: 0xfa49a108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSET_LE", producer: 0xfa49a108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSETM_GE", producer: 0xfa49a108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSETM_LT", producer: 0xfa49a108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSETM_GT", producer: 0xfa49a108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSETM_LE", producer: 0xfa49a108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSEL_GE", producer: 0xfa49a108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSEL_LT", producer: 0xfa49a108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSEL_GT", producer: 0xfa49a108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSEL_LE", producer: 0xfa49a108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSINC_GE", producer: 0xfa49a108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSINC_LT", producer: 0xfa49a108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSINC_GT", producer: 0xfa49a108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSINC_LE", producer: 0xfa49a108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSINV_GE", producer: 0xfa49a108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSINV_LT", producer: 0xfa49a108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSINV_GT", producer: 0xfa49a108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSINV_LE", producer: 0xfa49a108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSNEG_GE", producer: 0xfa49a108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSNEG_LT", producer: 0xfa49a108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSNEG_GT", producer: 0xfa49a108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CSNEG_LE", producer: 0xfa49a108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CINC_GE", producer: 0xfa49a108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CINC_LT", producer: 0xfa49a108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CINC_GT", producer: 0xfa49a108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CINC_LE", producer: 0xfa49a108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CINV_GE", producer: 0xfa49a108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CINV_LT", producer: 0xfa49a108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CINV_GT", producer: 0xfa49a108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CINV_LE", producer: 0xfa49a108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CNEG_GE", producer: 0xfa49a108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CNEG_LT", producer: 0xfa49a108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CNEG_GT", producer: 0xfa49a108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGECNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GE_CNEG_LE", producer: 0xfa49a108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_BCOND_GE", producer: 0xfa49b108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_BCOND_LT", producer: 0xfa49b108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_BCOND_GT", producer: 0xfa49b108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_BCOND_LE", producer: 0xfa49b108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSET_GE", producer: 0xfa49b108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSET_LT", producer: 0xfa49b108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSET_GT", producer: 0xfa49b108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSET_LE", producer: 0xfa49b108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSETM_GE", producer: 0xfa49b108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSETM_LT", producer: 0xfa49b108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSETM_GT", producer: 0xfa49b108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSETM_LE", producer: 0xfa49b108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSEL_GE", producer: 0xfa49b108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSEL_LT", producer: 0xfa49b108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSEL_GT", producer: 0xfa49b108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSEL_LE", producer: 0xfa49b108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSINC_GE", producer: 0xfa49b108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSINC_LT", producer: 0xfa49b108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSINC_GT", producer: 0xfa49b108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSINC_LE", producer: 0xfa49b108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSINV_GE", producer: 0xfa49b108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSINV_LT", producer: 0xfa49b108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSINV_GT", producer: 0xfa49b108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSINV_LE", producer: 0xfa49b108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSNEG_GE", producer: 0xfa49b108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSNEG_LT", producer: 0xfa49b108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSNEG_GT", producer: 0xfa49b108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CSNEG_LE", producer: 0xfa49b108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CINC_GE", producer: 0xfa49b108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CINC_LT", producer: 0xfa49b108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CINC_GT", producer: 0xfa49b108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CINC_LE", producer: 0xfa49b108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CINV_GE", producer: 0xfa49b108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CINV_LT", producer: 0xfa49b108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CINV_GT", producer: 0xfa49b108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CINV_LE", producer: 0xfa49b108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CNEG_GE", producer: 0xfa49b108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CNEG_LT", producer: 0xfa49b108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CNEG_GT", producer: 0xfa49b108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLTCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LT_CNEG_LE", producer: 0xfa49b108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_BCOND_GE", producer: 0xfa49c108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_BCOND_LT", producer: 0xfa49c108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_BCOND_GT", producer: 0xfa49c108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_BCOND_LE", producer: 0xfa49c108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSET_GE", producer: 0xfa49c108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSET_LT", producer: 0xfa49c108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSET_GT", producer: 0xfa49c108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSET_LE", producer: 0xfa49c108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSETM_GE", producer: 0xfa49c108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSETM_LT", producer: 0xfa49c108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSETM_GT", producer: 0xfa49c108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSETM_LE", producer: 0xfa49c108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSEL_GE", producer: 0xfa49c108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSEL_LT", producer: 0xfa49c108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSEL_GT", producer: 0xfa49c108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSEL_LE", producer: 0xfa49c108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSINC_GE", producer: 0xfa49c108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSINC_LT", producer: 0xfa49c108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSINC_GT", producer: 0xfa49c108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSINC_LE", producer: 0xfa49c108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSINV_GE", producer: 0xfa49c108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSINV_LT", producer: 0xfa49c108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSINV_GT", producer: 0xfa49c108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSINV_LE", producer: 0xfa49c108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSNEG_GE", producer: 0xfa49c108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSNEG_LT", producer: 0xfa49c108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSNEG_GT", producer: 0xfa49c108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CSNEG_LE", producer: 0xfa49c108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CINC_GE", producer: 0xfa49c108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CINC_LT", producer: 0xfa49c108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CINC_GT", producer: 0xfa49c108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CINC_LE", producer: 0xfa49c108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CINV_GE", producer: 0xfa49c108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CINV_LT", producer: 0xfa49c108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CINV_GT", producer: 0xfa49c108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CINV_LE", producer: 0xfa49c108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CNEG_GE", producer: 0xfa49c108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CNEG_LT", producer: 0xfa49c108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CNEG_GT", producer: 0xfa49c108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGGTCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_GT_CNEG_LE", producer: 0xfa49c108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLEBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_BCOND_GE", producer: 0xfa49d108, consumer: 0x5400004a,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLEBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_BCOND_LT", producer: 0xfa49d108, consumer: 0x5400004b,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLEBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_BCOND_GT", producer: 0xfa49d108, consumer: 0x5400004c,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLEBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_BCOND_LE", producer: 0xfa49d108, consumer: 0x5400004d,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSET_GE", producer: 0xfa49d108, consumer: 0x9a9fb7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSET_LT", producer: 0xfa49d108, consumer: 0x9a9fa7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSET_GT", producer: 0xfa49d108, consumer: 0x9a9fd7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSET_LE", producer: 0xfa49d108, consumer: 0x9a9fc7e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSETM_GE", producer: 0xfa49d108, consumer: 0xda9fb3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSETM_LT", producer: 0xfa49d108, consumer: 0xda9fa3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSETM_GT", producer: 0xfa49d108, consumer: 0xda9fd3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSETM_LE", producer: 0xfa49d108, consumer: 0xda9fc3e0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSEL_GE", producer: 0xfa49d108, consumer: 0x9a8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSEL_LT", producer: 0xfa49d108, consumer: 0x9a8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSEL_GT", producer: 0xfa49d108, consumer: 0x9a8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSEL_LE", producer: 0xfa49d108, consumer: 0x9a8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSINC_GE", producer: 0xfa49d108, consumer: 0x9a8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSINC_LT", producer: 0xfa49d108, consumer: 0x9a8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSINC_GT", producer: 0xfa49d108, consumer: 0x9a8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSINC_LE", producer: 0xfa49d108, consumer: 0x9a8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSINV_GE", producer: 0xfa49d108, consumer: 0xda8ea1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSINV_LT", producer: 0xfa49d108, consumer: 0xda8eb1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSINV_GT", producer: 0xfa49d108, consumer: 0xda8ec1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSINV_LE", producer: 0xfa49d108, consumer: 0xda8ed1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSNEG_GE", producer: 0xfa49d108, consumer: 0xda8ea5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSNEG_LT", producer: 0xfa49d108, consumer: 0xda8eb5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSNEG_GT", producer: 0xfa49d108, consumer: 0xda8ec5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CSNEG_LE", producer: 0xfa49d108, consumer: 0xda8ed5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CINC_GE", producer: 0xfa49d108, consumer: 0x9a8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CINC_LT", producer: 0xfa49d108, consumer: 0x9a8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CINC_GT", producer: 0xfa49d108, consumer: 0x9a8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CINC_LE", producer: 0xfa49d108, consumer: 0x9a8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CINV_GE", producer: 0xfa49d108, consumer: 0xda8db1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CINV_LT", producer: 0xfa49d108, consumer: 0xda8da1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CINV_GT", producer: 0xfa49d108, consumer: 0xda8dd1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CINV_LE", producer: 0xfa49d108, consumer: 0xda8dc1a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CNEG_GE", producer: 0xfa49d108, consumer: 0xda8db5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CNEG_LT", producer: 0xfa49d108, consumer: 0xda8da5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CNEG_GT", producer: 0xfa49d108, consumer: 0xda8dd5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMP64REGLECNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMP_64_REG_LE_CNEG_LE", producer: 0xfa49d108, consumer: 0xda8dc5a0,
            family: "ccmp", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_BCOND_GE", producer: 0xba410908, consumer: 0x5400004a,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_BCOND_LT", producer: 0xba410908, consumer: 0x5400004b,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_BCOND_GT", producer: 0xba410908, consumer: 0x5400004c,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_BCOND_LE", producer: 0xba410908, consumer: 0x5400004d,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSET_GE", producer: 0xba410908, consumer: 0x9a9fb7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSET_LT", producer: 0xba410908, consumer: 0x9a9fa7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSET_GT", producer: 0xba410908, consumer: 0x9a9fd7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSET_LE", producer: 0xba410908, consumer: 0x9a9fc7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSETM_GE", producer: 0xba410908, consumer: 0xda9fb3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSETM_LT", producer: 0xba410908, consumer: 0xda9fa3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSETM_GT", producer: 0xba410908, consumer: 0xda9fd3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSETM_LE", producer: 0xba410908, consumer: 0xda9fc3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSEL_GE", producer: 0xba410908, consumer: 0x9a8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSEL_LT", producer: 0xba410908, consumer: 0x9a8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSEL_GT", producer: 0xba410908, consumer: 0x9a8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSEL_LE", producer: 0xba410908, consumer: 0x9a8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSINC_GE", producer: 0xba410908, consumer: 0x9a8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSINC_LT", producer: 0xba410908, consumer: 0x9a8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSINC_GT", producer: 0xba410908, consumer: 0x9a8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSINC_LE", producer: 0xba410908, consumer: 0x9a8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSINV_GE", producer: 0xba410908, consumer: 0xda8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSINV_LT", producer: 0xba410908, consumer: 0xda8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSINV_GT", producer: 0xba410908, consumer: 0xda8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSINV_LE", producer: 0xba410908, consumer: 0xda8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSNEG_GE", producer: 0xba410908, consumer: 0xda8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSNEG_LT", producer: 0xba410908, consumer: 0xda8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSNEG_GT", producer: 0xba410908, consumer: 0xda8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CSNEG_LE", producer: 0xba410908, consumer: 0xda8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CINC_GE", producer: 0xba410908, consumer: 0x9a8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CINC_LT", producer: 0xba410908, consumer: 0x9a8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CINC_GT", producer: 0xba410908, consumer: 0x9a8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CINC_LE", producer: 0xba410908, consumer: 0x9a8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CINV_GE", producer: 0xba410908, consumer: 0xda8db1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CINV_LT", producer: 0xba410908, consumer: 0xda8da1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CINV_GT", producer: 0xba410908, consumer: 0xda8dd1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CINV_LE", producer: 0xba410908, consumer: 0xda8dc1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CNEG_GE", producer: 0xba410908, consumer: 0xda8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CNEG_LT", producer: 0xba410908, consumer: 0xda8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CNEG_GT", producer: 0xba410908, consumer: 0xda8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMNODEFECTCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_EQ_CNEG_LE", producer: 0xba410908, consumer: 0xda8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_BCOND_GE", producer: 0xba414908, consumer: 0x5400004a,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_BCOND_LT", producer: 0xba414908, consumer: 0x5400004b,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_BCOND_GT", producer: 0xba414908, consumer: 0x5400004c,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_BCOND_LE", producer: 0xba414908, consumer: 0x5400004d,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSET_GE", producer: 0xba414908, consumer: 0x9a9fb7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSET_LT", producer: 0xba414908, consumer: 0x9a9fa7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSET_GT", producer: 0xba414908, consumer: 0x9a9fd7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSET_LE", producer: 0xba414908, consumer: 0x9a9fc7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSETM_GE", producer: 0xba414908, consumer: 0xda9fb3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSETM_LT", producer: 0xba414908, consumer: 0xda9fa3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSETM_GT", producer: 0xba414908, consumer: 0xda9fd3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSETM_LE", producer: 0xba414908, consumer: 0xda9fc3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSEL_GE", producer: 0xba414908, consumer: 0x9a8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSEL_LT", producer: 0xba414908, consumer: 0x9a8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSEL_GT", producer: 0xba414908, consumer: 0x9a8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSEL_LE", producer: 0xba414908, consumer: 0x9a8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSINC_GE", producer: 0xba414908, consumer: 0x9a8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSINC_LT", producer: 0xba414908, consumer: 0x9a8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSINC_GT", producer: 0xba414908, consumer: 0x9a8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSINC_LE", producer: 0xba414908, consumer: 0x9a8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSINV_GE", producer: 0xba414908, consumer: 0xda8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSINV_LT", producer: 0xba414908, consumer: 0xda8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSINV_GT", producer: 0xba414908, consumer: 0xda8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSINV_LE", producer: 0xba414908, consumer: 0xda8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSNEG_GE", producer: 0xba414908, consumer: 0xda8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSNEG_LT", producer: 0xba414908, consumer: 0xda8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSNEG_GT", producer: 0xba414908, consumer: 0xda8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CSNEG_LE", producer: 0xba414908, consumer: 0xda8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CINC_GE", producer: 0xba414908, consumer: 0x9a8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CINC_LT", producer: 0xba414908, consumer: 0x9a8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CINC_GT", producer: 0xba414908, consumer: 0x9a8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CINC_LE", producer: 0xba414908, consumer: 0x9a8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CINV_GE", producer: 0xba414908, consumer: 0xda8db1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CINV_LT", producer: 0xba414908, consumer: 0xda8da1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CINV_GT", producer: 0xba414908, consumer: 0xda8dd1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CINV_LE", producer: 0xba414908, consumer: 0xda8dc1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CNEG_GE", producer: 0xba414908, consumer: 0xda8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CNEG_LT", producer: 0xba414908, consumer: 0xda8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CNEG_GT", producer: 0xba414908, consumer: 0xda8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMUNSUPPORTEDGUARDCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_MI_CNEG_LE", producer: 0xba414908, consumer: 0xda8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "mi", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64IMMGEBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_BCOND_GE", producer: 0xba41a908, consumer: 0x5400004a,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGEBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_BCOND_LT", producer: 0xba41a908, consumer: 0x5400004b,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGEBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_BCOND_GT", producer: 0xba41a908, consumer: 0x5400004c,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGEBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_BCOND_LE", producer: 0xba41a908, consumer: 0x5400004d,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSET_GE", producer: 0xba41a908, consumer: 0x9a9fb7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSET_LT", producer: 0xba41a908, consumer: 0x9a9fa7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSET_GT", producer: 0xba41a908, consumer: 0x9a9fd7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSET_LE", producer: 0xba41a908, consumer: 0x9a9fc7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSETM_GE", producer: 0xba41a908, consumer: 0xda9fb3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSETM_LT", producer: 0xba41a908, consumer: 0xda9fa3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSETM_GT", producer: 0xba41a908, consumer: 0xda9fd3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSETM_LE", producer: 0xba41a908, consumer: 0xda9fc3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSEL_GE", producer: 0xba41a908, consumer: 0x9a8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSEL_LT", producer: 0xba41a908, consumer: 0x9a8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSEL_GT", producer: 0xba41a908, consumer: 0x9a8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSEL_LE", producer: 0xba41a908, consumer: 0x9a8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSINC_GE", producer: 0xba41a908, consumer: 0x9a8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSINC_LT", producer: 0xba41a908, consumer: 0x9a8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSINC_GT", producer: 0xba41a908, consumer: 0x9a8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSINC_LE", producer: 0xba41a908, consumer: 0x9a8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSINV_GE", producer: 0xba41a908, consumer: 0xda8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSINV_LT", producer: 0xba41a908, consumer: 0xda8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSINV_GT", producer: 0xba41a908, consumer: 0xda8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSINV_LE", producer: 0xba41a908, consumer: 0xda8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSNEG_GE", producer: 0xba41a908, consumer: 0xda8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSNEG_LT", producer: 0xba41a908, consumer: 0xda8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSNEG_GT", producer: 0xba41a908, consumer: 0xda8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CSNEG_LE", producer: 0xba41a908, consumer: 0xda8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CINC_GE", producer: 0xba41a908, consumer: 0x9a8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CINC_LT", producer: 0xba41a908, consumer: 0x9a8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CINC_GT", producer: 0xba41a908, consumer: 0x9a8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CINC_LE", producer: 0xba41a908, consumer: 0x9a8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CINV_GE", producer: 0xba41a908, consumer: 0xda8db1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CINV_LT", producer: 0xba41a908, consumer: 0xda8da1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CINV_GT", producer: 0xba41a908, consumer: 0xda8dd1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CINV_LE", producer: 0xba41a908, consumer: 0xda8dc1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CNEG_GE", producer: 0xba41a908, consumer: 0xda8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CNEG_LT", producer: 0xba41a908, consumer: 0xda8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CNEG_GT", producer: 0xba41a908, consumer: 0xda8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGECNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GE_CNEG_LE", producer: 0xba41a908, consumer: 0xda8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "ge", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_BCOND_GE", producer: 0xba41b908, consumer: 0x5400004a,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_BCOND_LT", producer: 0xba41b908, consumer: 0x5400004b,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_BCOND_GT", producer: 0xba41b908, consumer: 0x5400004c,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_BCOND_LE", producer: 0xba41b908, consumer: 0x5400004d,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSET_GE", producer: 0xba41b908, consumer: 0x9a9fb7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSET_LT", producer: 0xba41b908, consumer: 0x9a9fa7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSET_GT", producer: 0xba41b908, consumer: 0x9a9fd7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSET_LE", producer: 0xba41b908, consumer: 0x9a9fc7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSETM_GE", producer: 0xba41b908, consumer: 0xda9fb3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSETM_LT", producer: 0xba41b908, consumer: 0xda9fa3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSETM_GT", producer: 0xba41b908, consumer: 0xda9fd3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSETM_LE", producer: 0xba41b908, consumer: 0xda9fc3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSEL_GE", producer: 0xba41b908, consumer: 0x9a8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSEL_LT", producer: 0xba41b908, consumer: 0x9a8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSEL_GT", producer: 0xba41b908, consumer: 0x9a8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSEL_LE", producer: 0xba41b908, consumer: 0x9a8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSINC_GE", producer: 0xba41b908, consumer: 0x9a8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSINC_LT", producer: 0xba41b908, consumer: 0x9a8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSINC_GT", producer: 0xba41b908, consumer: 0x9a8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSINC_LE", producer: 0xba41b908, consumer: 0x9a8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSINV_GE", producer: 0xba41b908, consumer: 0xda8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSINV_LT", producer: 0xba41b908, consumer: 0xda8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSINV_GT", producer: 0xba41b908, consumer: 0xda8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSINV_LE", producer: 0xba41b908, consumer: 0xda8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSNEG_GE", producer: 0xba41b908, consumer: 0xda8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSNEG_LT", producer: 0xba41b908, consumer: 0xda8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSNEG_GT", producer: 0xba41b908, consumer: 0xda8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CSNEG_LE", producer: 0xba41b908, consumer: 0xda8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CINC_GE", producer: 0xba41b908, consumer: 0x9a8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CINC_LT", producer: 0xba41b908, consumer: 0x9a8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CINC_GT", producer: 0xba41b908, consumer: 0x9a8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CINC_LE", producer: 0xba41b908, consumer: 0x9a8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CINV_GE", producer: 0xba41b908, consumer: 0xda8db1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CINV_LT", producer: 0xba41b908, consumer: 0xda8da1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CINV_GT", producer: 0xba41b908, consumer: 0xda8dd1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CINV_LE", producer: 0xba41b908, consumer: 0xda8dc1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CNEG_GE", producer: 0xba41b908, consumer: 0xda8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CNEG_LT", producer: 0xba41b908, consumer: 0xda8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CNEG_GT", producer: 0xba41b908, consumer: 0xda8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLTCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LT_CNEG_LE", producer: 0xba41b908, consumer: 0xda8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "lt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_BCOND_GE", producer: 0xba41c908, consumer: 0x5400004a,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_BCOND_LT", producer: 0xba41c908, consumer: 0x5400004b,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_BCOND_GT", producer: 0xba41c908, consumer: 0x5400004c,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_BCOND_LE", producer: 0xba41c908, consumer: 0x5400004d,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSET_GE", producer: 0xba41c908, consumer: 0x9a9fb7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSET_LT", producer: 0xba41c908, consumer: 0x9a9fa7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSET_GT", producer: 0xba41c908, consumer: 0x9a9fd7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSET_LE", producer: 0xba41c908, consumer: 0x9a9fc7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSETM_GE", producer: 0xba41c908, consumer: 0xda9fb3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSETM_LT", producer: 0xba41c908, consumer: 0xda9fa3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSETM_GT", producer: 0xba41c908, consumer: 0xda9fd3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSETM_LE", producer: 0xba41c908, consumer: 0xda9fc3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSEL_GE", producer: 0xba41c908, consumer: 0x9a8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSEL_LT", producer: 0xba41c908, consumer: 0x9a8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSEL_GT", producer: 0xba41c908, consumer: 0x9a8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSEL_LE", producer: 0xba41c908, consumer: 0x9a8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSINC_GE", producer: 0xba41c908, consumer: 0x9a8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSINC_LT", producer: 0xba41c908, consumer: 0x9a8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSINC_GT", producer: 0xba41c908, consumer: 0x9a8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSINC_LE", producer: 0xba41c908, consumer: 0x9a8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSINV_GE", producer: 0xba41c908, consumer: 0xda8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSINV_LT", producer: 0xba41c908, consumer: 0xda8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSINV_GT", producer: 0xba41c908, consumer: 0xda8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSINV_LE", producer: 0xba41c908, consumer: 0xda8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSNEG_GE", producer: 0xba41c908, consumer: 0xda8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSNEG_LT", producer: 0xba41c908, consumer: 0xda8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSNEG_GT", producer: 0xba41c908, consumer: 0xda8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CSNEG_LE", producer: 0xba41c908, consumer: 0xda8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CINC_GE", producer: 0xba41c908, consumer: 0x9a8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CINC_LT", producer: 0xba41c908, consumer: 0x9a8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CINC_GT", producer: 0xba41c908, consumer: 0x9a8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CINC_LE", producer: 0xba41c908, consumer: 0x9a8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CINV_GE", producer: 0xba41c908, consumer: 0xda8db1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CINV_LT", producer: 0xba41c908, consumer: 0xda8da1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CINV_GT", producer: 0xba41c908, consumer: 0xda8dd1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CINV_LE", producer: 0xba41c908, consumer: 0xda8dc1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CNEG_GE", producer: 0xba41c908, consumer: 0xda8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CNEG_LT", producer: 0xba41c908, consumer: 0xda8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CNEG_GT", producer: 0xba41c908, consumer: 0xda8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMGTCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_GT_CNEG_LE", producer: 0xba41c908, consumer: 0xda8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "gt", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLEBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_BCOND_GE", producer: 0xba41d908, consumer: 0x5400004a,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLEBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_BCOND_LT", producer: 0xba41d908, consumer: 0x5400004b,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLEBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_BCOND_GT", producer: 0xba41d908, consumer: 0x5400004c,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLEBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_BCOND_LE", producer: 0xba41d908, consumer: 0x5400004d,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSET_GE", producer: 0xba41d908, consumer: 0x9a9fb7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSET_LT", producer: 0xba41d908, consumer: 0x9a9fa7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSET_GT", producer: 0xba41d908, consumer: 0x9a9fd7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSET_LE", producer: 0xba41d908, consumer: 0x9a9fc7e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSETM_GE", producer: 0xba41d908, consumer: 0xda9fb3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSETM_LT", producer: 0xba41d908, consumer: 0xda9fa3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSETM_GT", producer: 0xba41d908, consumer: 0xda9fd3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSETM_LE", producer: 0xba41d908, consumer: 0xda9fc3e0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSEL_GE", producer: 0xba41d908, consumer: 0x9a8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSEL_LT", producer: 0xba41d908, consumer: 0x9a8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSEL_GT", producer: 0xba41d908, consumer: 0x9a8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSEL_LE", producer: 0xba41d908, consumer: 0x9a8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSINC_GE", producer: 0xba41d908, consumer: 0x9a8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSINC_LT", producer: 0xba41d908, consumer: 0x9a8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSINC_GT", producer: 0xba41d908, consumer: 0x9a8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSINC_LE", producer: 0xba41d908, consumer: 0x9a8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSINV_GE", producer: 0xba41d908, consumer: 0xda8ea1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSINV_LT", producer: 0xba41d908, consumer: 0xda8eb1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSINV_GT", producer: 0xba41d908, consumer: 0xda8ec1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSINV_LE", producer: 0xba41d908, consumer: 0xda8ed1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSNEG_GE", producer: 0xba41d908, consumer: 0xda8ea5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSNEG_LT", producer: 0xba41d908, consumer: 0xda8eb5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSNEG_GT", producer: 0xba41d908, consumer: 0xda8ec5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CSNEG_LE", producer: 0xba41d908, consumer: 0xda8ed5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CINC_GE", producer: 0xba41d908, consumer: 0x9a8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CINC_LT", producer: 0xba41d908, consumer: 0x9a8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CINC_GT", producer: 0xba41d908, consumer: 0x9a8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CINC_LE", producer: 0xba41d908, consumer: 0x9a8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CINV_GE", producer: 0xba41d908, consumer: 0xda8db1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CINV_LT", producer: 0xba41d908, consumer: 0xda8da1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CINV_GT", producer: 0xba41d908, consumer: 0xda8dd1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CINV_LE", producer: 0xba41d908, consumer: 0xda8dc1a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CNEG_GE", producer: 0xba41d908, consumer: 0xda8db5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CNEG_LT", producer: 0xba41d908, consumer: 0xda8da5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CNEG_GT", producer: 0xba41d908, consumer: 0xda8dd5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64IMMLECNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_IMM_LE_CNEG_LE", producer: 0xba41d908, consumer: 0xda8dc5a0,
            family: "ccmn", form: "IMM", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "le", preservation: false, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALBCONDGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_BCOND_GE", producer: 0xba490108, consumer: 0x5400004a,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "b.ge",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALBCONDLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_BCOND_LT", producer: 0xba490108, consumer: 0x5400004b,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "b.lt",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALBCONDGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_BCOND_GT", producer: 0xba490108, consumer: 0x5400004c,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "b.gt",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALBCONDLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_BCOND_LE", producer: 0xba490108, consumer: 0x5400004d,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "b.le",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSETGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSET_GE", producer: 0xba490108, consumer: 0x9a9fb7e0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSETLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSET_LT", producer: 0xba490108, consumer: 0x9a9fa7e0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSETGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSET_GT", producer: 0xba490108, consumer: 0x9a9fd7e0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSETLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSET_LE", producer: 0xba490108, consumer: 0x9a9fc7e0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "cset",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSETMGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSETM_GE", producer: 0xba490108, consumer: 0xda9fb3e0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSETMLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSETM_LT", producer: 0xba490108, consumer: 0xda9fa3e0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSETMGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSETM_GT", producer: 0xba490108, consumer: 0xda9fd3e0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSETMLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSETM_LE", producer: 0xba490108, consumer: 0xda9fc3e0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "csetm",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSELGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSEL_GE", producer: 0xba490108, consumer: 0x9a8ea1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSELLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSEL_LT", producer: 0xba490108, consumer: 0x9a8eb1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSELGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSEL_GT", producer: 0xba490108, consumer: 0x9a8ec1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSELLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSEL_LE", producer: 0xba490108, consumer: 0x9a8ed1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "csel",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSINC_GE", producer: 0xba490108, consumer: 0x9a8ea5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSINC_LT", producer: 0xba490108, consumer: 0x9a8eb5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSINC_GT", producer: 0xba490108, consumer: 0x9a8ec5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSINC_LE", producer: 0xba490108, consumer: 0x9a8ed5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "csinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSINV_GE", producer: 0xba490108, consumer: 0xda8ea1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSINV_LT", producer: 0xba490108, consumer: 0xda8eb1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSINV_GT", producer: 0xba490108, consumer: 0xda8ec1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSINV_LE", producer: 0xba490108, consumer: 0xda8ed1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "csinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSNEG_GE", producer: 0xba490108, consumer: 0xda8ea5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSNEG_LT", producer: 0xba490108, consumer: 0xda8eb5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSNEG_GT", producer: 0xba490108, consumer: 0xda8ec5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCSNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CSNEG_LE", producer: 0xba490108, consumer: 0xda8ed5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "csneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCINCGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CINC_GE", producer: 0xba490108, consumer: 0x9a8db5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCINCLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CINC_LT", producer: 0xba490108, consumer: 0x9a8da5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCINCGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CINC_GT", producer: 0xba490108, consumer: 0x9a8dd5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCINCLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CINC_LE", producer: 0xba490108, consumer: 0x9a8dc5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "cinc",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCINVGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CINV_GE", producer: 0xba490108, consumer: 0xda8db1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCINVLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CINV_LT", producer: 0xba490108, consumer: 0xda8da1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCINVGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CINV_GT", producer: 0xba490108, consumer: 0xda8dd1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCINVLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CINV_LE", producer: 0xba490108, consumer: 0xda8dc1a0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "cinv",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCNEGGE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CNEG_GE", producer: 0xba490108, consumer: 0xda8db5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "ge", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCNEGLT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CNEG_LT", producer: 0xba490108, consumer: 0xda8da5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "lt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCNEGGT() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CNEG_GT", producer: 0xba490108, consumer: 0xda8dd5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "gt", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }
    func test340CCMN64REGREGISTERREFUSALCNEGLE() throws {
        try LogicalRemainder340Fixture.check("CCMN_64_REG_EQ_CNEG_LE", producer: 0xba490108, consumer: 0xda8dc5a0,
            family: "ccmn", form: "REG", width: 64, suffix: "le", mnemonic: "cneg",
            guardSuffix: "eq", preservation: true, refusal: true, retOnly: false)
    }

}


extension CmpCcmpChainElisionTests {
    // Only the two expressly superseded diagnostics call this helper. Their
    // original words remain untouched; old main is still constructed separately.
    private func check340SupersededDiagnostic(_ words: [UInt32],
        file: StaticString = #filePath, line: UInt = #line) {
        let rows = LogicalRemainder340Fixture.decode(words)
        let candidate = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false)
            .buildFunction(name: "_338_exclusion", instructions: rows)
        let legacy = MacIRBuilder(skippingRejectedCFGReconciliation: false,
            explicitCFGEnabled: false, nativeSignedWordCMPEnabled: false)
            .buildFunction(name: "_338_exclusion", instructions: rows)
        XCTAssertNotEqual(candidate.instructions, legacy.instructions, file: file, line: line)
        let text = PseudocodePrinter().print(function: candidate).text
        XCTAssertNotEqual(text, PseudocodePrinter().print(function: legacy).text, file: file, line: line)
        XCTAssertTrue(text.contains("0x80000000"), text, file: file, line: line)
        XCTAssertTrue(text.contains("-1 -"), text, file: file, line: line)
    }
}
