import XCTest
@testable import MacScope

extension MacIRSSATests {
    private func stateRows(_ assembly: [(String, String)]) -> [InstructionRow] {
        assembly.enumerated().map { index, item in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: item.0,
                           operands: item.1, hasBreakpoint: false, comment: nil)
        }
    }

    func testStackPhiMeetsEqualOffsetsAndRejectsDisagreement() throws {
        for otherAmount in [16, 32] {
            let rows = stateRows([("cbz", "x0, 0x100c"), ("sub", "sp, sp, #16"),
                ("b", "0x1010"), ("sub", "sp, sp, #\(otherAmount)"),
                ("ldr", "x0, [sp, #16]"), ("ret", "")])
            let function = MacIRBuilder(ssaEnabled: true).buildFunction(name: "stack_join", instructions: rows)
            let info = try XCTUnwrap(function.ssaInfo)
            let sp = try XCTUnwrap(info.plan.rowReadBindings[4][31])
            let phi = try XCTUnwrap(info.plan.phis.first { $0.destination == sp })
            XCTAssertEqual(phi.incoming.map(\.machineAddress), [0x1008, 0x100c])
            if otherAmount == 16 {
                XCTAssertEqual(info.stackOffsets[sp], -16)
                XCTAssertEqual(function.stackFrameSize, 16)
            } else {
                XCTAssertNil(info.stackOffsets[sp])
            }
        }
    }

    func testPostPopStackArgumentUsesRecoveredEntryDisplacement() throws {
        var parameters = try (0..<8).map { index in
            try XCTUnwrap(MacIRFunctionParameter(id: .init(rawValue: "argument:\(index)"),
                bindingID: .gpr(index), sourcePosition: index,
                abiLocation: .gpr(index: index, carrierWidth: 64), type: "int64_t",
                name: "value\(index)", evidence: .authoritativeUser))
        }
        parameters.append(try XCTUnwrap(MacIRFunctionParameter(id: .init(rawValue: "stack_argument"),
            bindingID: nil, sourcePosition: 8, abiLocation: .entryStack(byteOffset: 0, size: 8, alignment: 8),
            type: "int64_t", name: "value8", evidence: .authoritativeUser)))
        let plan = try XCTUnwrap(MacIRAuthoritativeParameterPlan(parameters: parameters, isVariadic: false))
        let rows = stateRows([("stp", "x29, x30, [sp, #-16]!"),
            ("ldp", "x29, x30, [sp], #16"), ("ldr", "x0, [sp]"), ("ret", "")])
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(name: "post_pop",
            authoritativeParameterPlan: plan, instructions: rows)
        let info = try XCTUnwrap(function.ssaInfo)
        let sp = try XCTUnwrap(info.plan.rowReadBindings[2][31])
        XCTAssertEqual(info.stackOffsets[sp], 0)
        XCTAssertEqual(function.parameters.first { $0.sourcePosition == 8 }?.bindingID,
                       .entryStack(byteOffset: 0))
        let loaded = try XCTUnwrap(info.plan.rowWriteBindings[2][0])
        XCTAssertEqual(info.values[loaded], .argument(bindingID: .entryStack(byteOffset: 0)))
        XCTAssertEqual(function.stackFrameSize, 0)
        XCTAssertEqual(function.maxStackDisplacement, 16)
        let overwrittenRows = stateRows([("stp", "x29, x30, [sp, #-16]!"),
            ("ldp", "x29, x30, [sp], #16"), ("str", "x2, [sp]"),
            ("ldr", "x0, [sp]"), ("ret", "")])
        let overwritten = MacIRBuilder(ssaEnabled: true).buildFunction(name: "overwritten_stack_argument",
            authoritativeParameterPlan: plan, instructions: overwrittenRows)
        XCTAssertNil(overwritten.parameters.first { $0.sourcePosition == 8 }?.bindingID)
        let overwrittenInfo = try XCTUnwrap(overwritten.ssaInfo)
        let overwrittenLoad = try XCTUnwrap(overwrittenInfo.plan.rowWriteBindings[3][0])
        XCTAssertNotEqual(overwrittenInfo.values[overwrittenLoad], .argument(bindingID: .entryStack(byteOffset: 0)))
    }

    func testLateUnsupportedOperationKeepsItsClaimedDefinitionIdentity() throws {
        let rows = stateRows([("add", "x1, x2, x3, invalid"), ("mov", "x0, x1"), ("ret", "")])
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(name: "late_refusal",
            callerReturnWidth: .x0, instructions: rows)
        let info = try XCTUnwrap(function.ssaInfo)
        let definition = try XCTUnwrap(info.plan.rowWriteBindings[0][1])
        XCTAssertEqual(info.plan.definitions[definition].origin, .refusal(.unknownEffects, 0x1000))
        guard case let .unknown(destination, _, _, _) = function.instructions[0].operation,
              case let .assign(_, source) = function.instructions[1].operation else {
            return XCTFail("unsupported arithmetic must retain its claim and its downstream use")
        }
        XCTAssertEqual(destination, info.values[definition])
        XCTAssertEqual(source, info.values[definition])
        XCTAssertEqual(info.plan.rowReadBindings[1][1], definition)
        XCTAssertEqual(function.refusals.filter { $0.scope == .row(0x1000) }.count, 1)
    }

    func testScalarSIMDWriteDefinesZeroUpperHalfAndCallClobberIsSeparate() throws {
        let rows = stateRows([("fmov", "d8, #1.0"), ("bl", "callee"), ("fmov", "x0, d8"), ("ret", "")])
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(name: "scalar_halves",
            callerReturnWidth: .x0, instructions: rows)
        let info = try XCTUnwrap(function.ssaInfo)
        let cleared = try XCTUnwrap(info.plan.rowWriteBindings[0][72])
        let clobbered = try XCTUnwrap(info.plan.rowWriteBindings[1][72])
        XCTAssertEqual(info.values[cleared], .immediate(0))
        XCTAssertEqual(info.plan.definitions[clobbered].origin, .callClobber(0x1004))
        XCTAssertEqual(info.values[clobbered], .unknown("unavailable_vh8"))
        XCTAssertEqual(info.plan.rowReadBindings[2][40], info.plan.rowWriteBindings[0][40])
        XCTAssertNotEqual(cleared, clobbered)
    }

    func testNamedScalarRefusalPreservesReadsWithoutGrantingAuthority() throws {
        let rows = stateRows([("cset", "w14, eq"), ("and", "w1, w14, w21"),
            ("mov", "x2, x14"), ("mov", "x0, x1"), ("ret", "")])
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(name: "named_refusal",
            callerReturnWidth: .x0, instructions: rows)
        let info = try XCTUnwrap(function.ssaInfo)
        let definition = try XCTUnwrap(info.plan.rowWriteBindings[0][14])
        let value = try XCTUnwrap(info.values[definition])
        let origin = info.plan.definitions[definition].origin
        XCTAssertEqual(origin, .refusal(.unknownEffects, 0x1000))
        guard case let .unknown(destination, _, _, _) = function.instructions[0].operation,
              case let .binary(_, "&", left, _) = function.instructions[1].operation,
              case let .assign(_, widened) = function.instructions[2].operation else {
            return XCTFail("the refused CSET must retain its named result and W/X consumers")
        }
        XCTAssertEqual(destination, value)
        XCTAssertEqual(left, value)
        XCTAssertEqual(widened, .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: value)))
        XCTAssertEqual(info.plan.rowReadBindings[1][14], definition)
        XCTAssertEqual(info.plan.rowReadBindings[2][14], definition)
        XCTAssertEqual(function.refusals.filter { $0.scope == .row(0x1000) }.count, 1)

        var state = BuilderState()
        let named = MacIRSSAState.Binding(value: value, bitWidth: 32, view: .integer, origin: origin)
        XCTAssertTrue(named.isUnavailable, "named refusal remains unproved for authority consumers")
        state.ssa = .init(current: [
            14: named,
            15: .init(value: .unknown("unavailable_w15"), bitWidth: 32, view: .integer,
                      origin: .refusal(.unknownEffects, 0x1004)),
            16: .init(value: .register(name: "w16", version: 1), bitWidth: 32, view: .integer,
                      origin: .callClobber(0x1008))
        ], writes: [:], clobbers: [:])
        XCTAssertEqual(state.readRegister("w14"), value)
        XCTAssertEqual(state.readRegister("w15"), .unknown("unavailable_w15"))
        XCTAssertEqual(state.readRegister("x15"), .unknown("unavailable_x15"))
        XCTAssertEqual(state.readRegister("w16"), .unknown("unavailable_w16"))
        XCTAssertEqual(state.readRegister("x16"), .unknown("unavailable_x16"))
        XCTAssertTrue(state.ssa?.current[14]?.isUnavailable == true)
    }

    func testWideWriteMaterializesBothPlannedHalfDefinitions() throws {
        let rows = stateRows([("mov", "v8.16b, v0.16b"), ("mov", "x0, #1"), ("ret", "")])
        let function = try XCTUnwrap(MacIRBuilder(ssaEnabled: true).buildSSAFunction(
            name: "wide_halves", startAddress: 0x1000, rows: rows, initialState: BuilderState(),
            jumpTables: [:], recoveredSwitches: [:], tailCalls: [:], isVariadic: false,
            slotCallContracts: [:], slotCallSignatures: [:], knownTailCallTargets: [:]))
        let info = try XCTUnwrap(function.ssaInfo)
        let lowID = try XCTUnwrap(info.plan.rowWriteBindings[0][40])
        let highID = try XCTUnwrap(info.plan.rowWriteBindings[0][72])
        let low = try XCTUnwrap(info.values[lowID])
        let high = try XCTUnwrap(info.values[highID])
        let row = function.instructions.filter { $0.source.address == 0x1000 }
        XCTAssertEqual(row.count, 3)
        guard case let .assign(whole, _) = row[0].operation else {
            return XCTFail("the retained vector operation must define the whole temporary")
        }
        XCTAssertEqual(row[1].operation,
                       .assign(destination: low, source: .unary(op: "__ssa_low64", value: whole)))
        XCTAssertEqual(row[2].operation,
                       .assign(destination: high, source: .unary(op: "__ssa_high64", value: whole)))
        XCTAssertNotEqual(low, high)
    }

}

extension MacIRSSATests {
    // Fixed minimal-equivalent encodings, not bytes extracted from libjpeg.
    private func decodedSIMDRows(_ bytes: String, base: UInt64 = 0x1b854) throws -> [InstructionRow] {
        let data = try XCTUnwrap(A64OracleHex.bytes(bytes.replacingOccurrences(of: " ", with: "")))
        let decoded = ARM64Decoder().decode(Data(data), baseAddress: base, maxInstructionCount: data.count / 4)
        XCTAssertEqual(decoded.count, data.count / 4)
        return decoded.map {
            InstructionRow(address: $0.address, bytes: $0.byteText, mnemonic: $0.mnemonic,
                operands: $0.operands, hasBreakpoint: false, comment: $0.comment)
        }
    }

    private func simdFunction(_ rows: [InstructionRow]) throws -> MacIRFunction {
        try XCTUnwrap(MacIRBuilder(ssaEnabled: true).buildSSAFunction(
            name: "minimal_simd", startAddress: rows.first?.address, rows: rows, initialState: BuilderState(),
            jumpTables: [:], recoveredSwitches: [:], tailCalls: [:], isVariadic: false,
            slotCallContracts: [:], slotCallSignatures: [:], knownTailCallTargets: [:]))
    }

    private func assertSIMDText(_ function: MacIRFunction, address: UInt64, expected: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let document = PseudocodePrinter(options: .init(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024)).print(function: function)
        let lines = document.lines(sourcedAt: address).map { $0.text.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains(expected), lines.joined(separator: "\n"), file: file, line: line)
        print("Minimal-equivalent SIMD 0x\(String(address, radix: 16)): \(lines.joined(separator: " | "))")
    }

    func testDecodedSIMDReadModifyWriteUsesPriorWholeValue() throws {
        let rows = try decodedSIMDRows("06 1c a0 4e 32 1c a1 4e c6 1c 32 4e c0 03 5f d6", base: 0x1b858)
        XCTAssertEqual(rows[2].mnemonic, "and")
        XCTAssertEqual(rows[2].operands, "v6.16b, v6.16b, v18.16b")
        let function = try simdFunction(rows)
        let operations = function.instructions.filter { $0.source.address == 0x1b860 }.map(\.operation)
        let whole = MacIRValue.register(name: "q6", version: 2)
        XCTAssertEqual(operations, [
            .binary(destination: whole, op: "&", left: .register(name: "q6", version: 1),
                    right: .register(name: "q18", version: 1)),
            .assign(destination: .register(name: "v6", version: 2), source: .unary(op: "__ssa_low64", value: whole)),
            .assign(destination: .register(name: "vh6", version: 2), source: .unary(op: "__ssa_high64", value: whole))
        ])
        assertSIMDText(function, address: 0x1b860, expected: "q6_2 = q6_1 & q18_1;")
        // INS preserves both halves in a new whole value; a full read uses that definition.
        let refusedRows = try decodedSIMDRows("06 1c a0 4e a6 1d 18 4e 32 1c a1 4e c6 1c 32 4e c0 03 5f d6")
        XCTAssertEqual(refusedRows[1].mnemonic, "ins")
        let refused = try simdFunction(refusedRows)
        assertSIMDText(refused, address: 0x1b860, expected: "q6_3 = q6_2 & q18_1;")
    }

    func testDecodedSIMDMvnChainKeepsSuccessiveReachingValues() throws {
        let rows = try decodedSIMDRows("06 1c a0 4e 32 1c a1 4e 52 5a 20 6e c6 1c 32 4e 52 5a 20 6e c0 03 5f d6")
        XCTAssertEqual(rows.map(\.mnemonic), ["orr", "orr", "mvn", "and", "mvn", "ret"])
        XCTAssertEqual(rows[2].operands, "v18.16b, v18.16b")
        let function = try simdFunction(rows)
        assertSIMDText(function, address: 0x1b85c, expected: "q18_2 = ~(q18_1);")
        assertSIMDText(function, address: 0x1b860, expected: "q6_2 = q6_1 & q18_2;")
        assertSIMDText(function, address: 0x1b864, expected: "q18_3 = ~(q18_2);")
        // INS is precise, while the independent opaque producer still refuses v18.
        let refusedRows = try decodedSIMDRows("06 1c a0 4e a6 1d 18 4e d2 34 e3 4e c6 1c 32 4e 52 5a 20 6e c0 03 5f d6")
        XCTAssertEqual(refusedRows[1].mnemonic, "ins")
        XCTAssertEqual(refusedRows[2].mnemonic, "cmgt")
        let refused = try simdFunction(refusedRows)
        assertSIMDText(refused, address: 0x1b860, expected: "q6_3 = q6_2 & unavailable_v18.16b;")
        assertSIMDText(refused, address: 0x1b864, expected: "q18_1 = ~(unavailable_v18.16b);")
    }

    func testDecodedSIMDDistinctRegisterMulUsesPriorWholeValues() throws {
        let rows = try decodedSIMDRows("61 1c a3 4e 82 1c a4 4e 20 9c a2 4e c0 03 5f d6", base: 0x1000)
        XCTAssertEqual(rows[2].mnemonic, "mul")
        XCTAssertEqual(rows[2].operands, "v0.4s, v1.4s, v2.4s")
        let function = try simdFunction(rows)
        let whole = MacIRValue.register(name: "q0", version: 1)
        XCTAssertEqual(function.instructions.filter { $0.source.address == 0x1008 }.map(\.operation), [
            .binary(destination: whole, op: "*", left: .register(name: "q1", version: 1),
                    right: .register(name: "q2", version: 1)),
            .assign(destination: .register(name: "v0", version: 1), source: .unary(op: "__ssa_low64", value: whole)),
            .assign(destination: .register(name: "vh0", version: 1), source: .unary(op: "__ssa_high64", value: whole))
        ])
        assertSIMDText(function, address: 0x1008, expected: "q0_1 = q1_1 * q2_1;")
        // INS supplies a new preserved whole source even with a distinct destination.
        let refusedRows = try decodedSIMDRows("61 1c a3 4e a1 1d 18 4e 82 1c a4 4e 20 9c a2 4e c0 03 5f d6",
                                             base: 0x1000)
        XCTAssertEqual(refusedRows[1].mnemonic, "ins")
        let refused = try simdFunction(refusedRows)
        assertSIMDText(refused, address: 0x100c, expected: "q0_1 = q1_2 * q2_1;")
    }

    func testDecodedVectorFMulDefinesNormalResultAndStatus() throws {
        let rows = try decodedSIMDRows("61 1c a3 4e 82 1c a4 4e 20 dc 22 6e 03 1c a0 4e c0 03 5f d6",
                                       base: 0x1000)
        XCTAssertEqual(rows[2].mnemonic, "fmul")
        XCTAssertEqual(rows[2].operands, "v0.4s, v1.4s, v2.4s")
        XCTAssertNil(MacIRBuilder.scalarFPSemantics(mnemonic: "fmul",
            operands: ["v0.4s", "v1.4s", "v2.4s"]))
        let function = try simdFunction(rows)
        let instructions = function.instructions.filter { $0.source.address == 0x1008 }
        XCTAssertEqual(instructions.count, 4, "Numeric, status and both physical projections are explicit")
        let numeric = try XCTUnwrap(instructions.first?.vectorFP)
        XCTAssertEqual(numeric.semantics.operation, .multiply)
        XCTAssertEqual(numeric.arguments, [.register(name: "q1", version: 1), .register(name: "q2", version: 1)])
        XCTAssertNotNil(instructions.first { $0.vectorFPStatus != nil })
        let info = try XCTUnwrap(function.ssaInfo)
        for cell in [32, 64, 99] {
            let definition = try XCTUnwrap(info.plan.rowWriteBindings[2][cell])
            XCTAssertEqual(info.plan.definitions[definition].origin, .instruction(0x1008))
        }
        XCTAssertFalse(function.refusals.contains { $0.scope == .row(0x1008) })
        assertSIMDText(function, address: 0x100c, expected: "q3_1 = q0_1 | q0_1;")
    }

    func testSIMDWholeProvenanceRequiresBothReachingHalves() {
        let whole = MacIRValue.register(name: "q6", version: 4)
        var low = MacIRSSAState.Binding(value: .register(name: "v6", version: 4), bitWidth: 64,
            view: .bits, origin: .instruction(0x1000), wholeVector: whole)
        var high = MacIRSSAState.Binding(value: .register(name: "vh6", version: 4), bitWidth: 64,
            view: .bits, origin: .instruction(0x1000), wholeVector: whole)
        var state = BuilderState()
        func read(_ low: MacIRSSAState.Binding, _ high: MacIRSSAState.Binding) -> MacIRValue {
            state.ssa = .init(current: [38: low, 70: high], writes: [:], clobbers: [:])
            return MacIRBuilder.value(for: "v6.16b", state: state)
        }
        XCTAssertEqual(read(low, high), whole)
        high.wholeVector = .register(name: "q6", version: 3)
        XCTAssertEqual(read(low, high), .binaryExpression(op: "__ssa_join_vector_halves", left: low.value, right: high.value))
        high.wholeVector = nil
        low.wholeVector = nil
        XCTAssertEqual(read(low, high), .binaryExpression(op: "__ssa_join_vector_halves", left: low.value, right: high.value),
                       "matching half version counters do not establish whole-vector provenance")
        high.origin = .callClobber(0x1004)
        high.value = .unknown("unavailable_vh6")
        XCTAssertEqual(read(low, high), high.value)
        low.origin = .refusal(.unknownEffects, 0x1008)
        XCTAssertEqual(read(low, high), .unknown("unavailable_v6.16b"))
        state.ssa = .init(current: [:], writes: [:], clobbers: [:])
        XCTAssertEqual(MacIRBuilder.value(for: "v6.16b", state: state), .unknown("v6.16b"))
        XCTAssertEqual(MacIRBuilder.value(for: "v6.d[1]", state: state), .unknown("v6.d[1]"))
        XCTAssertFalse(MacIRBuilder.isRegister("v6.16b"))
    }
}

extension MacIRSSATests {
    func testEncodedAAPCS64CallsClobberObservedQCWithoutGrantingSignature() throws {
        // BL #4 (0x94000001), BLR x16 (0xd63f0200), little-endian.
        // AAPCS64 2025Q1 sections 6.1.1, 6.1.2 and 6.5.
        for bytes in ["01000094", "00023fd6"] {
            let row = try XCTUnwrap(decodedSIMDRows(bytes, base: 0x1000).first)
            let source = MacIRSourceSpan(address: row.address, byteText: row.bytes,
                                         mnemonic: row.mnemonic, operands: row.operands)
            // No return or argument type follows from the ABI. Supply no result
            // for this effects witness so x0 remains a clobber, not a return fact.
            let call = SSAEffectsCallContext(returnsValue: false)
            let effects = MacIRBuilder.ssaEffects(for: source, call: call, observesFPSR: true)
            let clobber = MacIRSSA.DefinitionOrigin.callClobber(0x1000)
            let writes = Dictionary(uniqueKeysWithValues: effects.writes.map { ($0.cell, $0) })
            XCTAssertEqual(writes[98], .init(cell: 98, bitWidth: 1, view: .qc, origin: clobber))
            XCTAssertFalse(effects.reads.contains(98), "a call does not preserve old QC")
            for cell in Array(0...17) + [30, 96] {
                XCTAssertEqual(writes[cell]?.origin, clobber)
            }
            for cell in 19...29 { XCTAssertNil(writes[cell]) }
            XCTAssertNil(writes[31])
            for index in 0..<32 {
                XCTAssertEqual(writes[64 + index]?.origin, clobber)
                if (8...15).contains(index) {
                    XCTAssertNil(writes[32 + index], "only the low 64 bits are preserved")
                } else {
                    XCTAssertEqual(writes[32 + index]?.origin, clobber)
                }
            }
            let unobserved = MacIRBuilder.ssaEffects(for: source, call: call)
            XCTAssertFalse(unobserved.writes.contains { $0.cell == 98 })
        }
    }

    func testEncodedCallMakesObservedQCUnknownAtFollowingFPSRRead() throws {
        // MSR FPSR,x0; BL #4; MRS x1,FPSR; RET.
        // Encodings: d51b4420, 94000001, d53b4421, d65f03c0.
        // AAPCS64 2025Q1 section 6.1.2: QC is not preserved.
        let rows = try decodedSIMDRows("20441bd5 01000094 21443bd5 c0035fd6", base: 0x1000)
        let function = try simdFunction(rows)
        let info = try XCTUnwrap(function.ssaInfo)
        let before = try XCTUnwrap(info.plan.rowWriteBindings[0][98])
        let after = try XCTUnwrap(info.plan.rowWriteBindings[1][98])
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(info.plan.definitions[after].origin, .callClobber(0x1004))
        XCTAssertEqual(info.values[after], .unknown("unavailable_qc"))
        XCTAssertEqual(info.plan.rowReadBindings[2][98], after)
    }
}

extension MacIRSSATests {
    // AAPCS64 2025Q1 §§6.1.1–6.1.2, 6.5. Encodings are decoded by the
    // existing helper when these authored tests are eventually executed.
    // NOP; MOV x16,x19; MOV x17,x20; MOVI v6.16b,#7; call;
    // CBNZ x23,0x1004; RET. The backedge does not target function entry.
    private func abiRegionRows(_ callBytes: String) throws -> [InstructionRow] {
        try decodedSIMDRows("1f 20 03 d5 f0 03 13 aa f1 03 14 aa e6 e4 00 4f "
            + callBytes + " 97 ff ff b5 c0 03 5f d6", base: 0x1000)
    }

    private func abiRegion(_ rows: [InstructionRow]) -> MacIRFunction? {
        MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildGeneralVectorRegion(name: "abi_region", startAddress: 0x1000,
            rows: rows, initialState: BuilderState(), hasExternalFacts: false, isVariadic: false)
    }

    func testEncodedIndirectReturningCallsAdmitVectorLoopWithoutSignature() throws {
        // BLR x16; BLRAAZ x16; BLRABZ x16. No modifier argument is invented.
        for (bytes, mnemonic) in [("00 02 3f d6", "blr"),
                                  ("1f 0a 3f d6", "blraaz"),
                                  ("1f 0e 3f d6", "blrabz")] {
            let rows = try abiRegionRows(bytes)
            XCTAssertEqual(rows[4].mnemonic, mnemonic)
            let function = try XCTUnwrap(abiRegion(rows))
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 })
            guard case let .call(frame, _) = call.operation else { return XCTFail("returning call required") }
            XCTAssertEqual(frame.target, "(*x16)")
            XCTAssertNotNil(frame.controlInputs.indirectTarget)
            XCTAssertNil(frame.controlInputs.pointerAuthenticationModifier)
            XCTAssertNil(frame.knownSignature)
            XCTAssertNil(frame.typedIndirectSignature)
            XCTAssertTrue(function.instructions.contains { $0.neonImmediate != nil })
        }
    }

    func testEncodedAuthenticatedCallsCaptureBothControlsBeforeClobber() throws {
        // BLRAA/BLRAB x16,x17: instruction semantics retain both pre-call controls;
        // AAPCS64 §6.1.1 then makes these caller-saved registers unavailable.
        for (bytes, mnemonic) in [("11 0a 3f d7", "blraa"), ("11 0e 3f d7", "blrab")] {
            let rows = try decodedSIMDRows(bytes, base: 0x1010)
            XCTAssertEqual(rows[0].mnemonic, mnemonic)
            var state = BuilderState()
            let target = state.writeRegister("x16"), modifier = state.writeRegister("x17")
            let source = MacIRSourceSpan(address: 0x1010, byteText: bytes,
                mnemonic: rows[0].mnemonic, operands: rows[0].operands)
            guard case let .call(frame, _) = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).operationForVectorRegion(for: source, state: &state)
            else { return XCTFail("authenticated returning call required") }
            XCTAssertEqual(frame.controlInputs.indirectTarget?.value, target)
            XCTAssertEqual(frame.controlInputs.pointerAuthenticationModifier?.value, modifier)
            XCTAssertEqual(state.readRegister("x16"), .unknown("unavailable_x16"))
            XCTAssertEqual(state.readRegister("x17"), .unknown("unavailable_x17"))
            XCTAssertNotNil(abiRegion(try abiRegionRows(bytes)))
        }
    }

    func testABIRegionCallPreservesOnlyLow64OfV8ThroughV15() throws {
        // AAPCS64 §6.1.2: low64 preserved, upper64 caller-saved.
        var state = BuilderState()
        state.permitsNEONBufferCarrier = true
        state.permitsNEONScalarViewCarrier = true
        for index in 0..<32 { _ = state.writeRegister("v\(index)") }
        let low = (8...15).map { state.readRegister("d\($0)") }
        let row = try XCTUnwrap(decodedSIMDRows("00 02 3f d6", base: 0x1010).first)
        let source = MacIRSourceSpan(address: row.address, byteText: row.bytes,
            mnemonic: row.mnemonic, operands: row.operands)
        guard case let .call(_, result) = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false)
            .operationForVectorRegion(for: source, state: &state) else { return XCTFail("BLR required") }
        state.invalidateGeneralVectorRegionAtCall(returning: result)
        for (offset, index) in (8...15).enumerated() {
            XCTAssertEqual(state.readRegister("d\(index)"), low[offset])
            XCTAssertEqual(state.readRegister("v\(index)"), .unknown("unavailable_upper_v\(index)"))
        }
        for index in Array(0...7) + Array(16...31) {
            XCTAssertEqual(state.readRegister("v\(index)"), .unknown("unavailable_v\(index)"))
        }
    }

    func testMalformedIndirectCallDoesNotBecomeRegionFallthrough() throws {
        // Valid BLR encoding with deliberately contradictory malformed operands.
        var rows = try abiRegionRows("00 02 3f d6")
        rows[4] = InstructionRow(address: 0x1010, bytes: rows[4].bytes, mnemonic: "blr",
            operands: "w16", hasBreakpoint: false, comment: nil)
        XCTAssertNil(abiRegion(rows))
    }

    func testUnavailableIndirectControlDoesNotAdmitRegion() throws {
        // AAPCS64 §6.1.1: x16 cannot survive an earlier call. Replace its loop
        // definition with NOP, and seed a clobber; no target is invented.
        var rows = try abiRegionRows("00 02 3f d6")
        rows[1] = InstructionRow(address: 0x1004, bytes: "1f 20 03 d5", mnemonic: "nop",
            operands: "", hasBreakpoint: false, comment: nil)
        var state = BuilderState()
        state.recordUnmodeledDefiniteWrite(for: "x16")
        XCTAssertNil(MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildGeneralVectorRegion(name: "unavailable_control",
            startAddress: 0x1000, rows: rows, initialState: state,
            hasExternalFacts: false, isVariadic: false))
    }

    func testIndirectCallSiteExternalControlConflictsRetainFallback() throws {
        let rows = try abiRegionRows("00 02 3f d6")
        let jumpConflict = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildFunction(name: "jump_conflict",
            jumpTables: [0x1010: [0x1004]], instructions: rows)
        let tailConflict = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildFunction(name: "tail_conflict",
            knownTailCallTargets: [0x1010: "not_call_authority"], instructions: rows)
        XCTAssertFalse(jumpConflict.instructions.contains { $0.neonImmediate != nil })
        XCTAssertFalse(tailConflict.instructions.contains { $0.neonImmediate != nil })
    }

    func testIndirectSlotSignatureIsNotSilentlyDiscardedByRegion() throws {
        let rows = try abiRegionRows("00 02 3f d6")
        let function = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildFunction(name: "slot_context",
            slotCallSignatures: [0x1010: .init(target: "(*x16)", returnType: "void")],
            instructions: rows)
        XCTAssertFalse(function.instructions.contains { $0.neonImmediate != nil })
        let contractOnly = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false)
            .buildFunction(name: "slot_contract",
                slotCallContracts: [0x1010: .init(returnType: "void", parameters: [])], instructions: rows)
        XCTAssertFalse(contractOnly.instructions.contains { $0.neonImmediate != nil })
    }

    func testEncodedDirectBLKeepsExistingRegionCallShape() throws {
        // BL 0x2000 at 0x1010 is 0x940003fc. Existing direct-call semantics
        // remain the control; this is a source-authored expectation, not a rerender.
        let rows = try abiRegionRows("fc 03 00 94")
        XCTAssertEqual(rows[4].mnemonic, "bl")
        let function = try XCTUnwrap(abiRegion(rows))
        let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 })
        guard case let .call(frame, _) = call.operation else { return XCTFail("direct call required") }
        XCTAssertNil(frame.controlInputs.indirectTarget)
        XCTAssertNil(frame.controlInputs.pointerAuthenticationModifier)
        XCTAssertTrue(function.instructions.contains { $0.neonImmediate != nil })
    }
}

extension MacIRSSATests {
    func testIndirectControlGraphRejectsUnknownAssignmentProducer() throws {
        // Same encoded BLR fixture; mutate only its IR producer to model a
        // refused producer. ABI §6.5 does not supply a replacement target.
        let rows = try abiRegionRows("00 02 3f d6")
        let function = try XCTUnwrap(abiRegion(rows))
        var instructions = function.instructions
        let index = try XCTUnwrap(instructions.firstIndex { $0.source.address == 0x1004 })
        guard case let .assign(destination, _) = instructions[index].operation else {
            return XCTFail("MOV target producer required")
        }
        instructions[index].operation = .assign(destination: destination,
            source: .unknown("unavailable_target_producer"))
        XCTAssertFalse(MacIRBuilder.generalVectorCallControlsRepresentable(
            instructions: instructions, phis: function.phis))
    }
}


extension MacIRSSATests {
    func testEncodedDirectBLIsByteIdenticalWithUnrelatedIndirectSiteFacts() throws {
        // Same BL encoding as the direct-call witness. Indirect-only guards
        // must not reinterpret these facts as a new direct-call contract.
        let rows = try abiRegionRows("fc 03 00 94")
        let builder = MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false)
        let baseline = builder.buildFunction(name: "direct_identity", instructions: rows)
        let contextual = builder.buildFunction(name: "direct_identity",
            jumpTables: [0x1010: [0x1004]],
            slotCallSignatures: [0x1010: .init(target: "(*x16)", returnType: "void")],
            knownTailCallTargets: [0x1010: "not_direct_call_authority"], instructions: rows)
        XCTAssertEqual(baseline.instructions, contextual.instructions)
        XCTAssertEqual(Array(PseudocodePrinter().print(function: baseline).text.utf8),
                       Array(PseudocodePrinter().print(function: contextual).text.utf8))
    }
}


extension MacIRSSATests {
    func testAuthenticatedControlGraphRejectsUnknownModifierProducer() throws {
        let function = try XCTUnwrap(abiRegion(try abiRegionRows("11 0a 3f d7")))
        var instructions = function.instructions
        let index = try XCTUnwrap(instructions.firstIndex { $0.source.address == 0x1008 })
        guard case let .assign(destination, _) = instructions[index].operation else {
            return XCTFail("modifier MOV required")
        }
        instructions[index].operation = .assign(destination: destination,
            source: .unknown("unavailable_pac_modifier"))
        XCTAssertFalse(MacIRBuilder.generalVectorCallControlsRepresentable(
            instructions: instructions, phis: function.phis))
    }

    func testIndirectControlGraphRejectsClobberedBackedgePhi() throws {
        for bytes in ["00 02 3f d6", "11 0a 3f d7"] {
            let function = try XCTUnwrap(abiRegion(try abiRegionRows(bytes)))
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 })
            guard case let .call(frame, _) = call.operation else { return XCTFail("call required") }
            for control in frame.controlInputs.bindingValues {
                // Neither target nor PAC modifier may convert a caller-clobber
                // on a completed backedge into register preservation.
                let badPhi = MacIRPhi(blockAddress: 0x1004, destination: control, bitWidth: 64,
                    incoming: [.init(predecessorAddress: 0x1000, value: .register(name: "x19", version: 0)),
                               .init(predecessorAddress: 0x1014, value: .unknown("unavailable_control"))])
                XCTAssertFalse(MacIRBuilder.generalVectorCallControlsRepresentable(
                    instructions: function.instructions, phis: function.phis + [badPhi]))
            }
        }
    }
}
