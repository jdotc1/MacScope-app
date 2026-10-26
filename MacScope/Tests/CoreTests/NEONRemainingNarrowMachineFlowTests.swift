import XCTest
@testable import MacScope

final class NEONRemainingNarrowMachineFlowTests: XCTestCase {
    typealias Lane = MacIRNEONLaneOp

    // Literal encodings and expectations below are independent of the production
    // encoder/evaluator. Gate assertions target the authorized C2 admission delta.
    private func check(_ mnemonic: String, _ operands: String, bytes: String,
                       machineReads: Set<String>, machineWrites: Set<String>, argumentRegisters: [Int],
                       n: Lane.Vector, m: Lane.Vector = (0, 0),
                       old: Lane.Vector = (0x0123456789abcdef, 0xfedcba9876543210),
                       expected: Lane.Vector, saturated: Bool = false,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let source = MacIRSourceSpan(address: 0x1000, byteText: bytes,
                                    mnemonic: mnemonic, operands: operands)
        let parsed = try XCTUnwrap(MacIRBuilder.neonLaneOperation(mnemonic: mnemonic,
            operandText: operands), file: file, line: line)
        let admitted = try XCTUnwrap(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic,
            operands: operands), file: file, line: line)
        XCTAssertEqual(admitted.semantics, parsed.semantics, file: file, line: line)
        let effects = MacIRBuilder.ssaEffects(for: source)
        XCTAssertTrue(effects.refusals.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(effects.writes.map { $0.cell }), Set([32, 64]), file: file, line: line)
        XCTAssertEqual(effects.reads.contains(32), parsed.semantics.readsDestination, file: file, line: line)
        XCTAssertEqual(effects.reads.contains(64), parsed.semantics.readsDestination, file: file, line: line)
        XCTAssertFalse(effects.reads.contains(98), file: file, line: line)
        let observed = MacIRBuilder.ssaEffects(for: source, observesFPSR: true)
        XCTAssertTrue(observed.refusals.isEmpty, file: file, line: line)
        XCTAssertEqual(observed.reads.contains(98), parsed.semantics.setsQC, file: file, line: line)
        XCTAssertEqual(observed.writes.filter { $0.cell == 98 }.count,
                       parsed.semantics.setsQC ? 1 : 0, file: file, line: line)
        for ssa in [false, true] {
            var rows = [InstructionRow(address: 0x1000, bytes: bytes, mnemonic: mnemonic,
                operands: operands, hasBreakpoint: false, comment: "")]
            if ssa {
                // Ensure the vector-only early route cannot substitute for SSA.
                rows.append(InstructionRow(address: 0x1004, bytes: "29 05 00 91", mnemonic: "add",
                    operands: "x9, x9, #1", hasBreakpoint: false, comment: ""))
            }
            rows.append(InstructionRow(address: ssa ? 0x1008 : 0x1004, bytes: "c0 03 5f d6",
                mnemonic: "ret", operands: "", hasBreakpoint: false, comment: ""))
            let flow = C2MachineFlow(rows: rows.map {
                MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
                                mnemonic: $0.mnemonic, operands: $0.operands)
            })
            XCTAssertNil(flow.error, file: file, line: line)
            // These literal expectations come from each fixture, never from
            // the lifted descriptor or the machine gate under test.
            XCTAssertEqual(flow.reads[0], machineReads, file: file, line: line)
            XCTAssertEqual(flow.writes[0], machineWrites, file: file, line: line)
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "remaining_narrow", startAddress: 0x1000, instructions: rows)
            XCTAssertEqual(function.ssaEnabled, ssa, file: file, line: line)
            let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 },
                                            file: file, line: line)
            let lane = try XCTUnwrap(instruction.neonLaneOp, file: file, line: line)
            XCTAssertEqual(lane, parsed.semantics, file: file, line: line)
            guard case let .intrinsic(destination?, name, arguments) = instruction.operation else {
                return XCTFail("missing typed lane operation", file: file, line: line)
            }
            XCTAssertEqual(name, lane.intrinsicName, file: file, line: line)
            XCTAssertEqual(arguments.count, lane.arity, file: file, line: line)
            if ssa {
                let info = try XCTUnwrap(function.ssaInfo, file: file, line: line)
                let lowID = try XCTUnwrap(info.plan.rowWriteBindings[0][32], file: file, line: line)
                let highID = try XCTUnwrap(info.plan.rowWriteBindings[0][64], file: file, line: line)
                let low = try XCTUnwrap(info.values[lowID], file: file, line: line)
                let high = try XCTUnwrap(info.values[highID], file: file, line: line)
                guard case let .register(_, version) = low else {
                    return XCTFail("missing low-half SSA definition", file: file, line: line)
                }
                let whole = MacIRValue.register(name: "q0", version: version)
                XCTAssertEqual(destination, whole, file: file, line: line)
                XCTAssertTrue(function.instructions.contains {
                    $0.source.address == 0x1000 && $0.operation == .assign(destination: low,
                        source: .unary(op: "__ssa_low64", value: whole))
                }, file: file, line: line)
                XCTAssertTrue(function.instructions.contains {
                    $0.source.address == 0x1000 && $0.operation == .assign(destination: high,
                        source: .unary(op: "__ssa_high64", value: whole))
                }, file: file, line: line)
            } else {
                guard case let .register(name, version) = destination else {
                    return XCTFail("missing legacy destination carrier", file: file, line: line)
                }
                XCTAssertEqual(name, "v0", file: file, line: line)
                XCTAssertGreaterThan(version, 0, file: file, line: line)
            }
            // Assert actual emitted identities, not merely arity. The fixture's
            // literal ordered register list is independent of the descriptor.
            // SSA entry vectors are joins of the literal low/high physical cells;
            // legacy entry vectors are the corresponding version-zero carriers.
            func entryRead(_ index: Int) throws -> MacIRValue {
                if !ssa { return .register(name: "v\(index)", version: 0) }
                let info = try XCTUnwrap(function.ssaInfo, file: file, line: line)
                let lowID = try XCTUnwrap(info.plan.rowReadBindings[0][32 + index], file: file, line: line)
                let highID = try XCTUnwrap(info.plan.rowReadBindings[0][64 + index], file: file, line: line)
                let low = try XCTUnwrap(info.values[lowID], file: file, line: line)
                let high = try XCTUnwrap(info.values[highID], file: file, line: line)
                let carrier = MacIRValue.register(name: "v\(index)", version: 0)
                let expectedLow = MacIRValue.unary(op: "__ssa_low64", value: carrier)
                let expectedHigh = MacIRValue.unary(op: "__ssa_high64", value: carrier)
                XCTAssertEqual(low, expectedLow, file: file, line: line)
                XCTAssertEqual(high, expectedHigh, file: file, line: line)
                return .binaryExpression(op: "__ssa_join_vector_halves", left: expectedLow, right: expectedHigh)
            }
            let expectedArguments = try argumentRegisters.map(entryRead)
            XCTAssertEqual(arguments, expectedArguments, file: file, line: line)
            // Bind the actual emitted identities to literal entry state. This
            // catches source permutation and old-Vd binding errors; it is not a
            // claim that the general concrete evaluator supports SSA lane joins.
            let bound: [Lane.Vector] = try arguments.map { value in
                let position = try XCTUnwrap(expectedArguments.firstIndex(of: value), file: file, line: line)
                switch argumentRegisters[position] {
                case 0: return old
                case 1: return n
                case 2: return m
                default: XCTFail("unexpected literal register", file: file, line: line); return (0, 0)
                }
            }
            let boundM: Lane.Vector = lane.sourceCount == 2 ? bound[1] : (0, 0)
            let boundOld: Lane.Vector = lane.readsDestination ? bound[bound.count - 1] : (0, 0)
            let actual = lane.evaluate(n: bound[0], m: boundM, oldDestination: boundOld)
            XCTAssertEqual(actual.low, expected.low, file: file, line: line)
            XCTAssertEqual(actual.high, expected.high, file: file, line: line)
            XCTAssertEqual(lane.saturates(n: bound[0], m: boundM), saturated, file: file, line: line)
            if lane.setsQC {
                let qc = MacIRNEONQCEffect(lane: lane, arguments: arguments,
                    input: .unknown("qc_input"), output: .unknown("qc_output"))
                XCTAssertEqual(qc.evaluate(inputQC: false, n: bound[0], m: boundM), saturated,
                               file: file, line: line)
                XCTAssertEqual(qc.evaluate(inputQC: true, n: bound[0], m: boundM), true,
                               file: file, line: line)
                XCTAssertEqual(qc.evaluate(inputQC: nil, n: bound[0], m: boundM), saturated ? true : nil,
                               file: file, line: line)
            }
        }
    }

    // Arm raddhn_advsimd.xml Operation: "sum = RShr(sum, esize, round);"
    // The rounding threshold is half a discarded unit; carry above 2n is discarded.
    func testRADDHN2BytesBelowAndAtHalfBothModes() throws {
        try check("raddhn2", "v0.16b, v1.8h, v2.8h", bytes: "20 40 22 6e",
            machineReads: ["v0", "v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2, 0],
            n: (127, 128), expected: (0x0123456789abcdef, 0x0000000100000000))
    }
    func testRADDHN2HalfwordsBelowAndAtHalfBothModes() throws {
        try check("raddhn2", "v0.8h, v1.4s, v2.4s", bytes: "20 40 62 6e",
            machineReads: ["v0", "v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2, 0],
            n: (32767, 32768), expected: (0x0123456789abcdef, 0x0000000100000000))
    }
    func testRADDHN2WordsWrapAndRoundBothModes() throws {
        try check("raddhn2", "v0.4s, v1.2d, v2.2d", bytes: "20 40 a2 6e",
            machineReads: ["v0", "v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2, 0],
            n: (0xffffffffffffffff, 0x0000000080000000), m: (1, 0),
            expected: (0x0123456789abcdef, 0x0000000100000000))
    }

    // Arm sqxtun_advsimd.xml Operation: "(result[e*:esize], sat) = UnsignedSatQ{esize}(SInt(element));"
    // These compatible literal vector fixtures are also
    // covering the independently failing machine gate. No second QC route.
    func testSQXTUN2BytesSaturationAndPreservedLowBothModes() throws {
        // [-1,0,255,256,-32768,32767,1,254] -> [0,0,255,255,0,255,1,254].
        try check("sqxtun2", "v0.16b, v1.8h", bytes: "20 28 21 6e",
            machineReads: ["v0", "v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1, 0],
            n: (0x010000ff0000ffff, 0x00fe00017fff8000), old: (0x0123456789abcdef, 0),
            expected: (0x0123456789abcdef, 0xfe01ff00ffff0000), saturated: true)
    }
    func testSQXTUN2HalfwordsSignedBoundsBothModes() throws {
        try check("sqxtun2", "v0.8h, v1.4s", bytes: "20 28 61 6e",
            machineReads: ["v0", "v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1, 0],
            n: (0x0000ffffffffffff, 0x8000000000010000), old: (0xfedcba9876543210, 0),
            expected: (0xfedcba9876543210, 0x0000ffffffff0000), saturated: true)
    }
    func testSQXTUN2WordsExactEndpointsBothModes() throws {
        try check("sqxtun2", "v0.4s, v1.2d", bytes: "20 28 a1 6e",
            machineReads: ["v0", "v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1, 0],
            n: (0, 0x00000000ffffffff), old: (0x89abcdef01234567, 0xffffffffffffffff),
            expected: (0x89abcdef01234567, 0xffffffff00000000))
    }

    // Arm shrn_advsimd.xml Operation: "result[e*:esize] = element[esize-1:0];"
    // SHRN does not round: 1 >> 1 is 0, while 3 >> 1 is 1.
    func testSHRN2BytesTruncateWithoutRoundingBothModes() throws {
        try check("shrn2", "v0.16b, v1.8h, #1", bytes: "20 84 0f 4f",
            machineReads: ["v0", "v1"], machineWrites: ["v0"], argumentRegisters: [1, 0],
            n: (0x010001ff00030001, 0x0000000000000200),
            expected: (0x0123456789abcdef, 0x0000000080ff0100))
    }
    func testSHRN2HalfwordsMaximumShiftBothModes() throws {
        try check("shrn2", "v0.8h, v1.4s, #16", bytes: "20 84 10 4f",
            machineReads: ["v0", "v1"], machineWrites: ["v0"], argumentRegisters: [1, 0],
            n: (0x00010000ffffffff, 0x800000007fffffff),
            expected: (0x0123456789abcdef, 0x80007fff0001ffff))
    }
    func testSHRN2WordsUnsignedTopBitBothModes() throws {
        try check("shrn2", "v0.4s, v1.2d, #32", bytes: "20 84 20 4f",
            machineReads: ["v0", "v1"], machineWrites: ["v0"], argumentRegisters: [1, 0],
            n: (0xffffffffffffffff, 0x8000000000000000),
            expected: (0x0123456789abcdef, 0x80000000ffffffff))
    }

    // Arm subhn_advsimd.xml Operation: "sum = element1 - element2;"
    // Borrow is retained in the selected high n bits, not saturated or rounded.
    func testSUBHN2BytesBorrowAndUpperSourceBothModes() throws {
        try check("subhn2", "v0.16b, v1.8h, v2.8h", bytes: "20 60 22 4e",
            machineReads: ["v0", "v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2, 0],
            n: (0, 0x0100), m: (1, 0),
            expected: (0x0123456789abcdef, 0x00000001000000ff))
    }
    func testSUBHN2HalfwordsBorrowAndTruncationBothModes() throws {
        try check("subhn2", "v0.8h, v1.4s, v2.4s", bytes: "20 60 62 4e",
            machineReads: ["v0", "v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2, 0],
            n: (0, 0x000100000000ffff), m: (1, 0),
            expected: (0x0123456789abcdef, 0x000100000000ffff))
    }
    func testSUBHN2WordsFullWidthBorrowBothModes() throws {
        try check("subhn2", "v0.4s, v1.2d, v2.2d", bytes: "20 60 a2 4e",
            machineReads: ["v0", "v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2, 0],
            n: (0, 0xffffffffffffffff), m: (1, 0),
            expected: (0x0123456789abcdef, 0xffffffffffffffff))
    }
    func testSUBHNBytesBorrowClearsHighBothModes() throws {
        try check("subhn", "v0.8b, v1.8h, v2.8h", bytes: "20 60 22 0e",
            machineReads: ["v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2],
            n: (0, 0x0100), m: (1, 0), expected: (0x00000001000000ff, 0))
    }
    func testSUBHNHalfwordsTruncationClearsHighBothModes() throws {
        try check("subhn", "v0.4h, v1.4s, v2.4s", bytes: "20 60 62 0e",
            machineReads: ["v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2],
            n: (0, 0x000100000000ffff), m: (1, 0), expected: (0x000100000000ffff, 0))
    }
    func testSUBHNWordsBorrowClearsHighBothModes() throws {
        try check("subhn", "v0.2s, v1.2d, v2.2d", bytes: "20 60 a2 0e",
            machineReads: ["v1", "v2"], machineWrites: ["v0"], argumentRegisters: [1, 2],
            n: (0, 0xffffffffffffffff), m: (1, 0), expected: (0xffffffffffffffff, 0))
    }

    // Arm sqshrn_advsimd.xml Operation: "(result[e*:esize], sat) = SignedSatQ{esize}(element);"
    // Arithmetic shift precedes saturation, with floor toward negative infinity.
    func testSQSHRN2BytesNegativeFloorAndBothSaturationEdgesBothModes() throws {
        // [-1,254,-257,256,-256,256,1,0] >> 1 -> [-1,127,-128,127,-128,127,0,0].
        try check("sqshrn2", "v0.16b, v1.8h, #1", bytes: "20 94 0f 4f",
            machineReads: ["v0", "v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1, 0],
            n: (0x0100feff00feffff, 0x000000010100ff00),
            expected: (0x0123456789abcdef, 0x00007f807f807fff), saturated: true)
    }
    func testSQSHRN2HalfwordsExactAndOutsideEdgesBothModes() throws {
        try check("sqshrn2", "v0.8h, v1.4s, #1", bytes: "20 94 1f 4f",
            machineReads: ["v0", "v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1, 0],
            n: (0x00010000fffeffff, 0x0000fffeffff0000),
            expected: (0x0123456789abcdef, 0x7fff80007fff8000), saturated: true)
    }
    func testSQSHRN2WordsFullWidthSignedEdgesBothModes() throws {
        try check("sqshrn2", "v0.4s, v1.2d, #1", bytes: "20 94 3f 4f",
            machineReads: ["v0", "v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1, 0],
            n: (0xfffffffeffffffff, 0x0000000100000000),
            expected: (0x0123456789abcdef, 0x7fffffff80000000), saturated: true)
    }

    // Arm sqshlu_advsimd.xml Operation: "(result[e*:esize], sat) = SatQ{esize}(element << shift, dst_unsigned);"
    // Negative signed inputs clamp to zero; positive overflow clamps to unsigned max.
    func testSQSHLUBytesNegativeInputsAndNoRoundingBothModes() throws {
        try check("sqshlu", "v0.16b, v1.16b, #1", bytes: "20 64 09 6f",
            machineReads: ["v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1],
            n: (0x7f8001ff00403f00, 0), expected: (0xfe00020000807e00, 0), saturated: true)
    }
    func testSQSHLUHalfwordsPositiveOverflowBothModes() throws {
        try check("sqshlu", "v0.8h, v1.8h, #8", bytes: "20 64 18 6f",
            machineReads: ["v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1],
            n: (0x010000ff0001ffff, 0x000000000080007f),
            expected: (0xffffff0001000000, 0x0000000080007f00), saturated: true)
    }
    func testSQSHLUDoublewordsExactUnsignedTopBitBothModes() throws {
        try check("sqshlu", "v0.2d, v1.2d, #63", bytes: "20 64 7f 6f",
            machineReads: ["v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1],
            n: (1, 0), expected: (0x8000000000000000, 0))
    }

    func testSQXTUNBytesSaturationClearsHighBothModes() throws {
        try check("sqxtun", "v0.8b, v1.8h", bytes: "20 28 21 2e",
            machineReads: ["v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1],
            n: (0x010000ff0000ffff, 0x00fe00017fff8000),
            expected: (0xfe01ff00ffff0000, 0), saturated: true)
    }
    func testSQXTUNHalfwordsSignedBoundsClearsHighBothModes() throws {
        try check("sqxtun", "v0.4h, v1.4s", bytes: "20 28 61 2e",
            machineReads: ["v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1],
            n: (0x0000ffffffffffff, 0x8000000000010000),
            expected: (0x0000ffffffff0000, 0), saturated: true)
    }
    func testSQXTUNWordsUnsignedEndpointClearsHighBothModes() throws {
        try check("sqxtun", "v0.2s, v1.2d", bytes: "20 28 a1 2e",
            machineReads: ["v1", "fpsr"], machineWrites: ["v0", "fpsr"], argumentRegisters: [1],
            n: (0, 0x00000000ffffffff), expected: (0xffffffff00000000, 0))
    }

    private func reject(_ mnemonic: String, _ operands: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        // Deliberately malformed text is not an encoded-instruction fixture.
        // The independent census gate must fail closed before reaching facts.
        let row = MacIRSourceSpan(address: 0x1000, byteText: "",
                                  mnemonic: mnemonic, operands: operands)
        let flow = C2MachineFlow(rows: [row])
        XCTAssertNotNil(flow.error, file: file, line: line)
        XCTAssertEqual(flow.reads[0], Set<String>(), file: file, line: line)
        XCTAssertEqual(flow.writes[0], Set<String>(), file: file, line: line)
    }

    func testNarrowGateRejectsMissingAndExtraOperands() {
        reject("raddhn2", "v0.16b, v1.8h")
        reject("sqxtun2", "v0.16b, v1.8h, v2.8h")
        reject("sqxtun", "v0.8b")
        reject("shrn2", "v0.16b, v1.8h")
        reject("subhn2", "v0.16b, v1.8h, v2.8h, #1")
        reject("sqshlu", "v0.16b, v1.16b")
    }

    func testNarrowGateRejectsNoncanonicalAndOutOfRangeRegisters() {
        reject("raddhn2", "v00.16b, v1.8h, v2.8h")
        reject("subhn", "v0.8b, v32.8h, v2.8h")
        reject("sqxtun2", "v0.16b, v01.8h")
        reject("sqxtun", "v-1.8b, v1.8h")
        reject("sqshrn2", "q0.16b, v1.8h, #1")
    }

    func testNarrowGateRejectsMismatchedArrangements() {
        reject("raddhn2", "v0.16b, v1.8h, v2.4s")
        reject("subhn2", "v0.8b, v1.8h, v2.8h")
        reject("subhn", "v0.16b, v1.8h, v2.8h")
        reject("sqxtun2", "v0.16b, v1.4h")
        reject("sqxtun", "v0.8b, v1.4s")
        reject("sqshlu", "v0.8h, v1.4h, #1")
    }

    func testNarrowGateRejectsShiftOutsideExactBounds() {
        reject("shrn2", "v0.16b, v1.8h, #0")
        reject("shrn2", "v0.16b, v1.8h, #9")
        reject("sqshrn2", "v0.4s, v1.2d, #0")
        reject("sqshrn2", "v0.4s, v1.2d, #33")
        reject("sqshlu", "v0.16b, v1.16b, #-1")
        reject("sqshlu", "v0.16b, v1.16b, #8")
        reject("sqshlu", "v0.2d, v1.2d, #64")
    }

    func testScalarSQXTUNKeepsFailClosedUntilExactSSARouteExists() {
        // The legacy lane parser recognizes scalar narrowing, but the pin's SSA
        // admission requires a vector arrangement. Do not keep a census-only
        // scalar admission that silently discards sticky FPSR.QC.
        for operands in ["b0, h1", "h0, s1", "s0, d1"] {
            XCTAssertNotNil(MacIRBuilder.neonLaneOperation(mnemonic: "sqxtun", operandText: operands))
            XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: "sqxtun", operands: operands))
            reject("sqxtun", operands)
        }
    }

    func testFCVTNDoesNotHideUnmodeledExceptionOutputBehindCensusAdmission() throws {
        // Both retained sites encode this same operation. The product has a
        // typed normal-completion FPConvert, but its raised exception result is
        // still symbolic unknown. Do not turn that into analyzed coverage.
        let row = MacIRSourceSpan(address: 0x6950, byteText: "21 68 61 0e",
                                  mnemonic: "fcvtn", operands: "v1.2s, v1.2d")
        let fp = try XCTUnwrap(MacIRVectorFP(source: row))
        XCTAssertEqual(fp.armPseudocode, "FPConvert")
        XCTAssertEqual(fp.completion, .normalOnlyMayTrap)
        XCTAssertTrue(fp.usesFPCRRounding)
        XCTAssertEqual(fp.exceptionMask, 0x9f)
        let flow = C2MachineFlow(rows: [row])
        XCTAssertEqual(flow.error, "0x6950: unsupported machine mnemonic fcvtn")
        XCTAssertEqual(flow.reads[0], Set<String>())
        XCTAssertEqual(flow.writes[0], Set<String>())
    }


    func testNarrowGateRejectsTrailingEmptyOperandBeforeAdmission() {
        let cases = [
            ("raddhn2", "v0.16b, v1.8h, v2.8h,"),
            ("subhn2", "v0.16b, v1.8h, v2.8h, "),
            ("subhn", "v0.8b, v1.8h, v2.8h,"),
            ("shrn2", "v0.16b, v1.8h, #1,"),
            ("sqxtun", "v0.8b, v1.8h,"),
            ("sqxtun2", "v0.16b, v1.8h,"),
            ("sqshrn2", "v0.16b, v1.8h, #1,"),
            ("sqshlu", "v0.16b, v1.16b, #1,")
        ]
        for (mnemonic, operands) in cases {
            XCTAssertNil(MacIRBuilder.neonLaneOperation(mnemonic: mnemonic, operandText: operands))
            reject(mnemonic, operands)
        }
        // Comment removal cannot erase the empty component before validation.
        reject("sqxtun2", "v0.16b, v1.8h, ; ignored comment")
        reject("sqxtun2", "v0.16b, v1.8h, // ignored comment")
    }

    func testTrailingEmptyPreservationDoesNotInventOperandsForNOPOrRET() {
        for operands in ["", "   ", " ; ignored comment", " // ignored comment"] {
            let nop = MacIRSourceSpan(address: 0x1000, byteText: "1f 20 03 d5",
                                     mnemonic: "nop", operands: operands)
            let nopFlow = C2MachineFlow(rows: [nop])
            XCTAssertNil(nopFlow.error)
            XCTAssertEqual(nopFlow.reads[0], Set<String>())
            XCTAssertEqual(nopFlow.writes[0], Set<String>())
            let ret = MacIRSourceSpan(address: 0x1000, byteText: "c0 03 5f d6",
                                     mnemonic: "ret", operands: operands)
            let retFlow = C2MachineFlow(rows: [ret])
            XCTAssertNil(retFlow.error)
            XCTAssertEqual(retFlow.reads[0], Set(["x30"]))
            XCTAssertEqual(retFlow.writes[0], Set<String>())
        }
    }


    func testSUBHN2AliasedSourceAndOldDestinationBindingsBothModes() throws {
        // Vn and preserved Vd are the same entry value. Swapping subtraction
        // sources or reading Vd after the write cannot satisfy these literals.
        try check("subhn2", "v0.4s, v0.2d, v2.2d", bytes: "00 60 a2 4e",
            machineReads: ["v0", "v2"], machineWrites: ["v0"], argumentRegisters: [0, 2, 0],
            n: (0x0000000100000000, 0x0000000300000000), m: (1, 0),
            old: (0x0000000100000000, 0x0000000300000000),
            expected: (0x0000000100000000, 0x0000000300000000))
    }

    func testOperandSplitRejectsDoubledComma() {
        reject("sqxtun2", "v0.16b,, v1.8h")
        reject("raddhn2", "v0.16b, v1.8h,, v2.8h")
    }

    func testOperandSplitRejectsTrailingCommaWithWhitespace() {
        reject("sqxtun2", "v0.16b, v1.8h,   ")
        reject("shrn2", "v0.16b, v1.8h, #1,   ")
    }

    func testWellFormedExistingRADDHNParseAndSetsStayUnchanged() {
        let row = MacIRSourceSpan(address: 0x1000, byteText: "20 40 22 2e",
                                  mnemonic: "raddhn", operands: "v0.8b, v1.8h, v2.8h")
        let flow = C2MachineFlow(rows: [row])
        XCTAssertNil(flow.error)
        XCTAssertEqual(flow.reads[0], Set(["v1", "v2"]))
        XCTAssertEqual(flow.writes[0], Set(["v0"]))
    }

    func testWellFormedExistingRSHRN2ParseAndSetsStayUnchanged() {
        let row = MacIRSourceSpan(address: 0x1000, byteText: "20 8c 0f 4f",
                                  mnemonic: "rshrn2", operands: "v0.16b, v1.8h, #1")
        let flow = C2MachineFlow(rows: [row])
        XCTAssertNil(flow.error)
        XCTAssertEqual(flow.reads[0], Set(["v0", "v1"]))
        XCTAssertEqual(flow.writes[0], Set(["v0"]))
    }

}
