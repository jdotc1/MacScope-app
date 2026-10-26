import XCTest
@testable import MacScope

@MainActor
final class SignedFieldValueTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "") -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic,
                       operands: operands, hasBreakpoint: false, comment: nil)
    }

    private func lift(_ rows: [InstructionRow], name: String = "sample") -> MacIRFunction {
        MacIRBuilder(explicitCFGEnabled: false).buildFunction(name: name, instructions: rows)
    }

    private func node(_ operation: MacIROperation, file: StaticString = #filePath,
                      line: UInt = #line) throws -> MacIRSignedBitfield {
        guard case let .assign(_, .signedBitfield(field)) = operation else {
            XCTFail("Expected an admitted signed field: \(operation)", file: file, line: line)
            throw NSError(domain: "SignedFieldValueTests", code: 1)
        }
        return field
    }

    private func fixture(_ index: Int, _ mnemonic: String, _ operands: String) -> MacIRFunction {
        let source = MacIRBuilder.splitOperands(operands)[1]
        let word = "w" + source.dropFirst()
        let start = UInt64(0x8000 + index * 0x20)
        return lift([row(start, "mov", "\(word), w0"), row(start + 4, mnemonic, operands),
                     row(start + 8, "ret")])
    }

    private func assertRendering(_ index: Int, _ mnemonic: String, _ operands: String,
                                 sourceName: String, destinationName: String,
                                 indentation: Int, expected: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let function = fixture(index, mnemonic, operands)
        let field = try node(function.instructions[1].operation, file: file, line: line)
        guard case let .register(sourceRegister, sourceVersion) = field.origin.definition,
              case let .assign(.register(destinationRegister, destinationVersion), _) = function.instructions[1].operation else {
            return XCTFail("Missing captured definition or destination", file: file, line: line)
        }
        var names = PseudocodeNameContext(function: function)
        names.registerNamesByValue[.register(name: sourceRegister, version: sourceVersion)] = sourceName
        names.registerNamesByValue[.register(name: destinationRegister, version: destinationVersion)] = destinationName
        let rendered = String(repeating: " ", count: indentation)
            + PseudocodePrinter().render(operation: function.instructions[1].operation, names: names) + ";"
        XCTAssertEqual(rendered, expected, file: file, line: line)
        XCTAssertEqual(field.source, .unary(op: "(uint64_t)", value:
            .unary(op: "(uint32_t)", value: field.origin.definition)), file: file, line: line)
        XCTAssertEqual(field.origin.instructionAddress, function.instructions[1].source.address, file: file, line: line)
    }

    func testProjectedRendering01() throws {
        try assertRendering(0, "sbfiz", "x2, x9, #3, #32", sourceName: "tmp22",
            destinationName: "x2_1", indentation: 4,
            expected: "    x2_1 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp22)), 3, 32);")
    }

    func testProjectedRendering02() throws {
        try assertRendering(1, "sbfiz", "x9, x9, #3, #32", sourceName: "tmp24",
            destinationName: "tmp26", indentation: 4,
            expected: "    tmp26 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp24)), 3, 32);")
    }

    func testProjectedRendering03() throws {
        try assertRendering(2, "sbfiz", "x22, x22, #3, #32", sourceName: "w22_1",
            destinationName: "x22_1", indentation: 4,
            expected: "    x22_1 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(w22_1)), 3, 32);")
    }

    func testProjectedRendering04() throws {
        try assertRendering(3, "sbfiz", "x2, x9, #3, #32", sourceName: "tmp22",
            destinationName: "x2_1", indentation: 4,
            expected: "    x2_1 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp22)), 3, 32);")
    }

    func testProjectedRendering05() throws {
        try assertRendering(4, "sbfiz", "x9, x9, #3, #32", sourceName: "tmp24",
            destinationName: "tmp26", indentation: 4,
            expected: "    tmp26 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp24)), 3, 32);")
    }

    func testProjectedRendering06() throws {
        try assertRendering(5, "sbfiz", "x22, x22, #3, #32", sourceName: "w22_1",
            destinationName: "x22_1", indentation: 4,
            expected: "    x22_1 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(w22_1)), 3, 32);")
    }

    func testProjectedRendering07() throws {
        try assertRendering(6, "sbfiz", "x2, x9, #3, #32", sourceName: "tmp22",
            destinationName: "x2_1", indentation: 4,
            expected: "    x2_1 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp22)), 3, 32);")
    }

    func testProjectedRendering08() throws {
        try assertRendering(7, "sbfiz", "x9, x9, #3, #32", sourceName: "tmp24",
            destinationName: "tmp26", indentation: 4,
            expected: "    tmp26 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp24)), 3, 32);")
    }

    func testProjectedRendering09() throws {
        try assertRendering(8, "sbfiz", "x22, x22, #3, #32", sourceName: "w22_1",
            destinationName: "x22_1", indentation: 4,
            expected: "    x22_1 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(w22_1)), 3, 32);")
    }

    func testProjectedRendering10() throws {
        try assertRendering(9, "sbfiz", "x2, x9, #3, #32", sourceName: "tmp32",
            destinationName: "x2_2", indentation: 8,
            expected: "        x2_2 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp32)), 3, 32);")
    }

    func testProjectedRendering11() throws {
        try assertRendering(10, "sbfiz", "x2, x9, #3, #32", sourceName: "tmp32",
            destinationName: "x2_2", indentation: 8,
            expected: "        x2_2 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp32)), 3, 32);")
    }

    func testProjectedRendering12() throws {
        try assertRendering(11, "sbfiz", "x2, x9, #3, #32", sourceName: "tmp32",
            destinationName: "x2_2", indentation: 8,
            expected: "        x2_2 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp32)), 3, 32);")
    }

    func testProjectedRendering13() throws {
        try assertRendering(12, "sbfiz", "x9, x25, #9, #32", sourceName: "w25_1",
            destinationName: "tmp23", indentation: 8,
            expected: "        tmp23 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(w25_1)), 9, 32);")
    }

    func testProjectedRendering14() throws {
        try assertRendering(13, "sbfiz", "x3, x11, #1, #32", sourceName: "tmp90",
            destinationName: "x3_1", indentation: 12,
            expected: "            x3_1 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(tmp90)), 1, 32);")
    }

    func testProjectedRendering15() throws {
        try assertRendering(14, "sbfiz", "x9, x25, #9, #32", sourceName: "w25_1",
            destinationName: "tmp23", indentation: 8,
            expected: "        tmp23 = mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(w25_1)), 9, 32);")
    }

    func testProjectedRendering16() throws {
        try assertRendering(15, "sbfx", "x15, x15, #6, #26", sourceName: "tmp10",
            destinationName: "tmp11", indentation: 12,
            expected: "            tmp11 = mscope_sbfx_bits_u64((uint64_t)((uint32_t)(tmp10)), 6, 26);")
    }

    func testProjectedRendering17() throws {
        try assertRendering(16, "sbfx", "x10, x8, #6, #26", sourceName: "tmp4",
            destinationName: "tmp7", indentation: 12,
            expected: "            tmp7 = mscope_sbfx_bits_u64((uint64_t)((uint32_t)(tmp4)), 6, 26);")
    }

    private func admitted(_ mnemonic: String = "sbfx", bits: Int? = 64,
                          offset: Int64 = 0, width: Int64 = 8,
                          sourceRegister: String = "x1", destinationRegister: String = "x2",
                          definition: MacIRValue = .register(name: "x1", version: 1),
                          source: MacIRValue? = nil, definitionBits: Int = 64) -> MacIRSignedBitfield? {
        MacIRSignedBitfield(source: source ?? definition, operandBits: bits,
            sourceLSB: mnemonic == "sbfiz" ? 0 : offset, fieldBits: width,
            insertLSB: mnemonic == "sbfiz" ? offset : 0,
            origin: .init(functionName: "sample", functionStart: 0x9000,
                instructionAddress: 0x9004, mnemonic: mnemonic,
                sourceRegister: sourceRegister, destinationRegister: destinationRegister,
                definition: definition, definitionBits: definitionBits))
    }

    func testPrewriteIdentityAcrossOperandForms() throws {
        let forms = [("sbfiz", "x9, x9, #3, #32"), ("sbfiz", "x22, x22, #3, #32"),
                     ("sbfx", "x15, x15, #6, #26"), ("sbfx", "x10, x8, #6, #26")]
        for (index, form) in forms.enumerated() {
            let function = fixture(index + 20, form.0, form.1)
            let field = try node(function.instructions[1].operation)
            guard case let .assign(previous, _) = function.instructions[0].operation,
                  case let .assign(destination, _) = function.instructions[1].operation else {
                return XCTFail("Missing definition")
            }
            XCTAssertEqual(field.origin.definition, previous)
            XCTAssertNotEqual(field.origin.definition, destination)
            XCTAssertEqual(field.source, .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: previous)))
        }
    }

    func testWholeOperationRenderingLeavesGenericShiftsUnchanged() throws {
        let function = fixture(30, "sbfiz", "x2, x9, #3, #32")
        var names = PseudocodeNameContext(function: function)
        names.registerNamesByValue[.register(name: "w9", version: 1)] = "captured_bits"
        let generic = MacIRValue.binaryExpression(op: ">>", left:
            .binaryExpression(op: "<<", left: .temporary(22), right: .immediate(32)), right: .immediate(29))
        XCTAssertEqual(PseudocodePrinter().valueText(for: generic, names: names), "(tmp_22 << 0x20) >> 0x1d")
        let field = try node(function.instructions[1].operation)
        let rendered = PseudocodePrinter().valueText(for: .signedBitfield(field), names: names)
        XCTAssertEqual(rendered, "mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(captured_bits)), 3, 32)")
        XCTAssertFalse(rendered.contains(">>"))
        XCTAssertFalse(rendered.contains("<<"))
        let unsigned = lift([row(0x9800, "ubfiz", "x0, x1, #4, #8"), row(0x9804, "ret")])
        XCTAssertEqual(PseudocodePrinter().render(operation: unsigned.instructions[0].operation,
            names: PseudocodeNameContext(function: unsigned)), "x0_1 = (in_x1 & 0xff) << 0x4")
    }

    func testWordResultZeroProjectsToParent() throws {
        let function = lift([row(0x9000, "sbfx", "w1, w0, #0, #8"),
                             row(0x9004, "mov", "x2, x1"), row(0x9008, "ret")])
        let field = try node(function.instructions[0].operation)
        XCTAssertEqual(field.operandBits, 32)
        XCTAssertEqual(field.evaluatedBits(sourceBits: 0x80), 0xffff_ff80)
        var state = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        state.x[0] = 0x80
        state.nzcv = 0b1010
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        let evaluated = try evaluator.evaluate(.signedBitfield(field))
        XCTAssertEqual(evaluated.bits, 0xffff_ff80)
        XCTAssertEqual(evaluated.width, 32)
        XCTAssertEqual(evaluated.kind, .unsigned)
        XCTAssertEqual(evaluator.state.nzcv, 0b1010)
        guard case let .assign(_, source) = function.instructions[1].operation else {
            return XCTFail("Missing parent read")
        }
        XCTAssertEqual(source, .unary(op: "(uint64_t)", value:
            .unary(op: "(uint32_t)", value: .register(name: "w1", version: 1))))
    }

    func testFullWidthMaskRetainsAllBits() throws {
        for bits in [32, 64] {
            let prefix = bits == 32 ? "w" : "x"
            for mnemonic in ["sbfx", "sbfiz"] {
                let field = try XCTUnwrap(admitted(mnemonic, bits: bits, width: Int64(bits),
                    sourceRegister: prefix + "1", destinationRegister: prefix + "2",
                    definition: .register(name: prefix + "1", version: 1), definitionBits: bits))
                let mask = bits == 32 ? UInt64(UInt32.max) : UInt64.max
                for value in [UInt64(0), 1, 0x8000_0000, 0x8000_0000_0000_0000, UInt64.max] {
                    XCTAssertEqual(field.evaluatedBits(sourceBits: value), value & mask)
                }
                XCTAssertTrue(field.helperDefinition.contains("w == \(bits) ? storage"))
            }
        }
    }

    func testOneBitAndBoundaryFields() throws {
        for bits in [32, 64] {
            let prefix = bits == 32 ? "w" : "x"
            let mask = bits == 32 ? UInt64(UInt32.max) : UInt64.max
            for mnemonic in ["sbfx", "sbfiz"] {
                for offset in [0, bits - 1] {
                    let field = try XCTUnwrap(admitted(mnemonic, bits: bits, offset: Int64(offset), width: 1,
                        sourceRegister: prefix + "1", destinationRegister: prefix + "2",
                        definition: .register(name: prefix + "1", version: 1), definitionBits: bits))
                    XCTAssertEqual(field.evaluatedBits(sourceBits: 0), 0)
                    let input = mnemonic == "sbfx" ? UInt64(1) << offset : 1
                    let expected = mnemonic == "sbfx" ? mask : (mask << offset) & mask
                    XCTAssertEqual(field.evaluatedBits(sourceBits: input), expected)
                }
            }
        }
    }

    func testTransportRetainsFieldsAndOrigin() throws {
        let function = fixture(31, "sbfiz", "x2, x9, #3, #32")
        let field = try node(function.instructions[1].operation)
        let value = MacIRValue.signedBitfield(field)
        let serialized = try WorkspaceScriptingAPI.callArgumentAuditValueObject(value)
        XCTAssertEqual(try ScriptValue.decode(serialized.jsonData()), serialized)
        XCTAssertEqual(serialized["operand_bits"], .int(64))
        XCTAssertEqual(serialized["source_lsb"], .int(0))
        XCTAssertEqual(serialized["field_bits"], .int(32))
        XCTAssertEqual(serialized["insert_lsb"], .int(3))
        XCTAssertEqual(serialized["source"], try WorkspaceScriptingAPI.callArgumentAuditValueObject(field.source))
        XCTAssertEqual(serialized["origin"]?["definition"], try WorkspaceScriptingAPI.callArgumentAuditValueObject(field.origin.definition))
        XCTAssertEqual(serialized["origin"]?["function_name"], .string(function.name))
        XCTAssertEqual(serialized["origin"]?["instruction_address"], .string(String(field.origin.instructionAddress, radix: 16)))
        XCTAssertEqual(serialized["origin"]?["function_start"], .string(String(function.startAddress, radix: 16)))
        XCTAssertEqual(serialized["origin"]?["mnemonic"], .string("sbfiz"))
        XCTAssertEqual(serialized["origin"]?["source_register"], .string("x9"))
        XCTAssertEqual(serialized["origin"]?["destination_register"], .string("x2"))
        XCTAssertEqual(serialized["origin"]?["definition_bits"], .int(32))
        XCTAssertEqual(Set([value, value]).count, 1)
        let other = try node(fixture(32, "sbfiz", "x2, x9, #3, #32").instructions[1].operation)
        XCTAssertNotEqual(field, other)
        XCTAssertEqual(Set([value, .signedBitfield(other)]).count, 2)
        var atoms: Set<MacIRValue> = []
        RegionalBoundaryPlan.collectAtoms(value, into: &atoms)
        XCTAssertEqual(atoms, [field.origin.definition])
        XCTAssertEqual(value.description, "mscope_sbfiz_bits_u64((uint64_t)((uint32_t)(w9_1)), 3, 32)")
        XCTAssertThrowsError(try WorkspaceScriptingAPI.callArgumentAuditValueObject(value, depth: 32))
        var unchanged = function
        RegionalLexicalProof.record(reconciled: &unchanged, lexical: function)
        XCTAssertFalse(unchanged.nonMarkerDifference)
        XCTAssertEqual(unchanged.instructions, function.instructions)
        var rewritten = function
        if case let .assign(destination, _) = rewritten.instructions[1].operation {
            rewritten.instructions[1].operation = .assign(destination: destination, source: .signedBitfield(other))
        }
        var original = function
        RegionalLexicalProof.record(reconciled: &original, lexical: rewritten)
        XCTAssertTrue(original.nonMarkerDifference)
        XCTAssertEqual(original.instructions[1].operation, function.instructions[1].operation)
    }

    func testLoadedSourceIsEvaluatedOnceWithoutFlags() throws {
        let function = lift([row(0xa000, "ldr", "w9, [x0]"),
            row(0xa004, "sbfiz", "x2, x9, #3, #32"), row(0xa008, "ret")])
        let field = try node(function.instructions[1].operation)
        XCTAssertEqual(field.origin.definition, .register(name: "w9", version: 1))
        var names = PseudocodeNameContext(function: function)
        names.registerNamesByValue[.register(name: "w9", version: 1)] = "loaded_bits"
        let text = PseudocodePrinter().render(operation: function.instructions[1].operation, names: names)
        XCTAssertEqual(text.components(separatedBy: "loaded_bits").count - 1, 1)
        XCTAssertFalse(text.contains("*("))
        XCTAssertEqual(function.instructions.filter { if case .load = $0.operation { true } else { false } }.count, 1)
        XCTAssertEqual(function.instructions.count, 3)
        XCTAssertFalse(field.helperDefinition.contains("NZCV"))
    }

    func testMissingOriginCannotAdmitSignedMeaning() {
        let source = MacIRValue.register(name: "x1", version: 1)
        XCTAssertNil(MacIRSignedBitfield(source: source, operandBits: 64,
            sourceLSB: 0, fieldBits: 8, insertLSB: 0, origin: nil))
        let generic = MacIRValue.binaryExpression(op: ">>", left:
            .binaryExpression(op: "<<", left: source, right: .immediate(56)), right: .immediate(56))
        XCTAssertFalse(generic.description.contains("mscope_"))
        XCTAssertFalse(MacIRValue.unknown("sbfx x2, x1, #0, #8").description.contains("mscope_"))
    }

    func testMissingOrMismatchedWidthsRefuse() {
        for bits in [Int?](arrayLiteral: nil, 0, 8, 16, 128) { XCTAssertNil(admitted(bits: bits)) }
        for register in ["w1", "q1", "xzr", "unknown"] {
            XCTAssertNil(admitted(sourceRegister: register))
        }
        XCTAssertNil(admitted(destinationRegister: "w2"))
        XCTAssertNil(admitted(definitionBits: 0))
        for mnemonic in ["sbfx", "sbfiz"] {
            let function = lift([row(0xb000, mnemonic, "x0, w1, #0, #8"), row(0xb004, "ret")])
            guard case .unknown = function.instructions[0].operation else {
                return XCTFail("Mismatched views were admitted")
            }
        }
    }

    func testInvalidCountsRefuseBeforeArithmetic() {
        for mnemonic in ["sbfx", "sbfiz"] {
            for (offset, width) in [(Int64(0), Int64(0)), (0, -1), (-1, 8), (0, 65), (63, 2), (64, 1), (Int64.max, Int64.max)] {
                XCTAssertNil(admitted(mnemonic, offset: offset, width: width))
            }
            for operands in ["x0, x1, x2, #8", "x0, x1, #0, unknown"] {
                let function = lift([row(0xb100, mnemonic, operands), row(0xb104, "ret")])
                guard case .unknown = function.instructions[0].operation else {
                    return XCTFail("Nonconstant bound was admitted")
                }
            }
        }
    }

    func testUnavailableStaleClobberedAndJoinedSourcesRefuse() {
        XCTAssertNil(admitted(definition: .register(name: "x1", version: 0)))
        XCTAssertNil(admitted(definition: .register(name: "x3", version: 1)))
        XCTAssertNil(admitted(source: .register(name: "x1", version: 2)))
        XCTAssertNil(admitted(definition: .unknown("unavailable_x1")))
        let unbound = lift([row(0xb200, "sbfiz", "x2, x9, #3, #32"), row(0xb204, "ret")])
        guard case .unknown = unbound.instructions[0].operation else { return XCTFail("Unbound source admitted") }
        let clobbered = lift([row(0xb300, "mov", "x9, x0"), row(0xb304, "bl", "0xc000"),
            row(0xb308, "sbfx", "x2, x9, #0, #8"), row(0xb30c, "ret")])
        guard case .unknown = clobbered.instructions[2].operation else { return XCTFail("Clobbered source admitted") }
        var state = BuilderState(parameters: [])
        state.signedBitfieldFunctionName = "sample"
        state.returnProducerEntryAddress = 0xb400
        state.currentRowAddress = 0xb404
        state.currentIntegerDefinitionByIndex[1] = .init(value: .register(name: "x1", version: 2), width: 64, isJoinedDefinition: true)
        XCTAssertNil(state.signedBitfieldOrigin(mnemonic: "sbfx", source: "x1", destination: "x2"))
    }

    func testUnsignedOriginsStayUnsigned() {
        for mnemonic in ["ubfx", "ubfiz"] {
            XCTAssertNil(admitted(mnemonic))
            let function = lift([row(0xc000, mnemonic, "x0, x1, #4, #8"), row(0xc004, "ret")])
            XCTAssertFalse(PseudocodePrinter().print(function: function).text.contains("mscope_"))
            guard case .assign(_, .binaryExpression) = function.instructions[0].operation else {
                return XCTFail("Unsigned alias lost its existing expression")
            }
        }
    }

    func testUnadmittedAliasesAndZeroRegistersRefuseSignedNode() {
        for mnemonic in ["sbfm", "asr", "sxtb", "sxth", "sxtw"] { XCTAssertNil(admitted(mnemonic)) }
        XCTAssertNil(admitted(sourceRegister: "xzr"))
        XCTAssertNil(admitted(destinationRegister: "xzr"))
        for operands in ["x0, xzr, #0, #8", "xzr, x1, #0, #8"] {
            let function = lift([row(0xc100, "sbfx", operands), row(0xc104, "ret")])
            guard case .unknown = function.instructions[0].operation else { return XCTFail("Zero register admitted") }
        }
    }

    func testHelperArithmeticUsesUnsignedStorage() throws {
        for bits in [32, 64] {
            let prefix = bits == 32 ? "w" : "x"
            for mnemonic in ["sbfx", "sbfiz"] {
                let field = try XCTUnwrap(admitted(mnemonic, bits: bits, offset: 0, width: Int64(bits),
                    sourceRegister: prefix + "1", destinationRegister: prefix + "2",
                    definition: .register(name: prefix + "1", version: 1), definitionBits: bits))
                let helper = field.helperDefinition
                XCTAssertTrue(helper.contains("uint\(bits)_t source"))
                XCTAssertTrue(helper.contains("const uint64_t field"))
                XCTAssertTrue(helper.contains("const uint64_t fill"))
                XCTAssertTrue(helper.contains("w == \(bits) ? storage"))
                XCTAssertTrue(helper.contains("w == 0 || w > \(bits)"))
                XCTAssertTrue(helper.contains("__builtin_trap()"))
                XCTAssertFalse(helper.contains("(int32_t)"))
                XCTAssertFalse(helper.contains("(int64_t)"))
                XCTAssertFalse(helper.contains("INT_MIN"))
                XCTAssertFalse(helper.contains("<< \(bits)"))
                XCTAssertFalse(helper.contains(">> \(bits)"))
                XCTAssertEqual(field.evaluatedBits(sourceBits: UInt64.max), bits == 32 ? UInt64(UInt32.max) : UInt64.max)
            }
        }
    }

    func testDestinationMutationCannotReplaceCapturedSource() throws {
        let function = lift([row(0xc200, "mov", "w9, w0"), row(0xc204, "sbfx", "w9, w9, #0, #8"),
            row(0xc208, "mov", "x2, x9"), row(0xc20c, "ret")])
        let field = try node(function.instructions[1].operation)
        XCTAssertEqual(field.source, .register(name: "w9", version: 1))
        guard case let .assign(destination, _) = function.instructions[1].operation,
              case let .assign(_, parentRead) = function.instructions[2].operation else { return XCTFail("Missing write") }
        XCTAssertEqual(destination, .register(name: "w9", version: 2))
        XCTAssertNotEqual(field.source, destination)
        XCTAssertEqual(parentRead, .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: destination)))
        XCTAssertEqual(field.evaluatedBits(sourceBits: 0xff), 0xffff_ffff)
    }

    func testSignedValueDoesNotGrantPointerOrSourceAuthority() throws {
        let field = try XCTUnwrap(admitted())
        XCTAssertNil(admitted(definition: .unknown("unavailable_pointer")))
        XCTAssertNil(admitted(definition: .stackSlot(offset: 0)))
        let value = MacIRValue.signedBitfield(field)
        var atoms: Set<MacIRValue> = []
        RegionalBoundaryPlan.collectAtoms(value, into: &atoms)
        XCTAssertEqual(atoms, [field.source])
        let serialized = try WorkspaceScriptingAPI.callArgumentAuditValueObject(value)
        XCTAssertNil(serialized["pointer_valid"])
        XCTAssertNil(serialized["reachable"])
        XCTAssertNil(serialized["ssa_repaired"])
    }

    func testIndependentManifestationsAndFollowingSubtractionStaySeparate() throws {
        let forms: [(String, String)] = Array(repeating: ("sbfiz", "x2, x9, #3, #32"), count: 12)
            + [("sbfiz", "x9, x25, #9, #32"), ("sbfiz", "x3, x11, #1, #32"),
               ("sbfiz", "x9, x25, #9, #32"), ("sbfx", "x15, x15, #6, #26"), ("sbfx", "x10, x8, #6, #26")]
        let fields = try forms.enumerated().map { try node(fixture(40 + $0.offset, $0.element.0, $0.element.1).instructions[1].operation) }
        XCTAssertEqual(fields.count, 17)
        XCTAssertEqual(Set(fields.map(\.origin)).count, 17)
        XCTAssertEqual(fields[12].origin.functionName, fields[14].origin.functionName)
        XCTAssertNotEqual(fields[12].origin.functionStart, fields[14].origin.functionStart)
        let function = lift([row(0xd000, "mov", "w15, w0"), row(0xd004, "sbfx", "x15, x15, #6, #26"),
            row(0xd008, "sub", "x0, x15, #1"), row(0xd00c, "ret")])
        _ = try node(function.instructions[1].operation)
        guard case let .binary(_, op, left, right) = function.instructions[2].operation else { return XCTFail("Subtraction folded") }
        XCTAssertEqual(op, "-")
        // e656c8771d24 allocates one SSA counter for physical X15/W15.
        // MOV W15 is version1; SBFX X15 is version2. Legacy numbers the views
        // separately. In either mode SUB must consume the SBFX result itself.
        let expected = MacIRValue.register(name: "x15", version: function.ssaEnabled ? 2 : 1)
        XCTAssertEqual(left, expected)
        guard case let .assign(destination, _) = function.instructions[1].operation else {
            return XCTFail("Missing signed-field result")
        }
        XCTAssertEqual(destination, expected)
        XCTAssertEqual(left, destination)
        XCTAssertEqual(right, .immediate(1))
    }
}
