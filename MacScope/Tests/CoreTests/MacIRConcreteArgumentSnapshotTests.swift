import XCTest
@testable import MacScope

/// New DOT10 witnesses. Expected constants follow immutable source-formal semantics,
/// independently of register writes, memory stores and the evaluator's implementation.
final class MacIRConcreteArgumentSnapshotTests: XCTestCase {
    private func parameter(_ location: MacIRABIParameterLocation, _ type: String,
                           row: String = "row", bind: Bool = true) -> MacIRFunctionParameter {
        MacIRFunctionParameter(id: .init(rawValue: row), bindingID: bind ? location.bindingID : nil,
                               sourcePosition: nil, abiLocation: location, type: type,
                               evidence: .authoritativeUser)!
    }

    private func machine() throws -> A64MachineState {
        try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
    }

    private func evaluator(_ parameters: [MacIRFunctionParameter], _ state: A64MachineState) -> MacIRConcreteEvaluator {
        MacIRConcreteEvaluator(function: MacIRFunction(name: "snapshot", startAddress: A64MachineState.defaultPC,
                                                       parameters: parameters, instructions: []), state: state)
    }

    private func instruction(_ operation: MacIROperation) -> MacIRInstruction {
        .init(source: .init(address: A64MachineState.defaultPC, byteText: "", mnemonic: "redacted", operands: ""),
              operation: operation)
    }

    private func check(_ label: String, _ value: MacIRConcreteEvaluator.Scalar, _ bits: UInt64,
                       _ width: Int, _ kind: MacIRConcreteEvaluator.Kind,
                       file: StaticString = #filePath, line: UInt = #line) {
        print("DOT10 observation \(label): observed=\(value.bits)/\(value.width)/\(value.kind) expected=\(bits)/\(width)/\(kind)")
        XCTAssertEqual(value, .init(bits: bits, width: width, kind: kind), label, file: file, line: line)
    }

    private func unsupported(_ label: String, _ parameters: [MacIRFunctionParameter],
                             _ id: MacIRParameterBindingID, _ state: A64MachineState,
                             file: StaticString = #filePath, line: UInt = #line) {
        var e = evaluator(parameters, state)
        do {
            let value = try e.evaluate(.argument(bindingID: id))
            XCTFail("\(label): unexpectedly admitted \(value)", file: file, line: line)
        } catch MacIRConcreteEvaluator.Failure.unsupported(let reason) {
            print("DOT10 refusal \(label): unsupported=\(reason)")
        } catch { XCTFail("\(label): wrong error \(error)", file: file, line: line) }
    }

    func testOverwrittenGPRRetainsNarrowFormalAndLiveSSA() throws {
        var state = try machine()
        state.x[2] = 0x1234_5678_9abc_ff81
        var e = evaluator([parameter(.gpr(index: 2, carrierWidth: 64), "int8_t")], state)
        // No formal evaluation before the write: capture must happen at init, not first lookup.
        try e.run([instruction(.assign(destination: .register(name: "x2", version: 1), source: .immediate(42)))])
        check("gpr.formal", try e.evaluate(.argument(bindingID: .gpr(2))), 0x81, 8, .signed)
        check("gpr.machine", try e.evaluate(.register(name: "x2", version: 0)), 42, 64, .signed)
        check("gpr.ssa1", try e.evaluate(.register(name: "x2", version: 1)), 42, 64, .signed)
        try e.write(.register(name: "x2", version: 2), .int(71, width: 64, signed: true))
        try e.write(.temporary(7), .int(19, width: 32, signed: false))
        check("gpr.ssa1.retained", try e.evaluate(.register(name: "x2", version: 1)), 42, 64, .signed)
        check("gpr.ssa2", try e.evaluate(.register(name: "x2", version: 2)), 71, 64, .signed)
        check("gpr.temporary", try e.evaluate(.temporary(7)), 19, 32, .unsigned)
        check("gpr.formal.reread", try e.evaluate(.argument(bindingID: .gpr(2))), 0x81, 8, .signed)
    }

    func testEntryStackFormalSurvivesStoreAndSPChange() throws {
        var state = try machine()
        state.sp = 0x7000
        state.setByte(0x83, at: 0x7010)
        state.setByte(0xff, at: 0x7011)
        state.setByte(0xaa, at: 0x7012) // Padding must not widen an int16_t formal.
        state.setByte(0x80, at: 0x7022)
        state.setByte(0x3f, at: 0x7023) // IEEE float 1.0, with nonzero slot padding.
        state.setByte(0xbb, at: 0x7024)
        state.x[5] = 0x1122_3344_5566_7788
        var e = evaluator([
            parameter(.entryStack(byteOffset: 16, size: 8, alignment: 8), "int16_t", row: "integer"),
            parameter(.entryStack(byteOffset: 32, size: 8, alignment: 8), "float", row: "float")
        ], state)
        try e.run([
            instruction(.assign(destination: .register(name: "sp", version: 1), source: .immediate(0x6000))),
            instruction(.store(source: .register(name: "x5", version: 0), address: .stackSlot(offset: 16))),
            instruction(.store(source: .register(name: "x5", version: 0), address: .stackSlot(offset: 32))),
            instruction(.load(destination: .register(name: "x6", version: 1), address: .stackSlot(offset: 16)))
        ])
        check("stack.formal", try e.evaluate(.argument(bindingID: .entryStack(byteOffset: 16))), 0xff83, 16, .signed)
        check("stack.floatFormal", try e.evaluate(.argument(bindingID: .entryStack(byteOffset: 32))), 0x3f80_0000, 32, .float)
        check("stack.liveLoad", try e.evaluate(.register(name: "x6", version: 1)), 0x1122_3344_5566_7788, 64, .signed)
        check("stack.entryAddress", try e.evaluate(.stackSlot(offset: 16)), 0x7010, 64, .unsigned)
        check("stack.liveSP", try e.evaluate(.register(name: "sp", version: 0)), 0x6000, 64, .unsigned)
        XCTAssertEqual(e.state.byte(at: 0x7010), 0x88)
        XCTAssertEqual(e.state.byte(at: 0x6010), 0)
        e.alternateSignedness = true
        check("stack.floatAlternate", try e.evaluate(.argument(bindingID: .entryStack(byteOffset: 32))), 0x3f80_0000, 32, .float)
        check("stack.alternate", try e.evaluate(.argument(bindingID: .entryStack(byteOffset: 16))), 0xff83, 16, .unsigned)
    }

    func testWXArchitecturalViewsRemainIndependentOfFormal() throws {
        var state = try machine()
        state.x[3] = 0x1234_abcd_89ab_cdef
        var e = evaluator([parameter(.gpr(index: 3, carrierWidth: 32), "uint64_t")], state)
        check("wx.entryX", try e.evaluate(.register(name: "x3", version: 0)), 0x1234_abcd_89ab_cdef, 64, .signed)
        check("wx.entryW", try e.evaluate(.register(name: "w3", version: 0)), 0x89ab_cdef, 32, .signed)
        try e.write(.register(name: "w3", version: 1), .int(0xfedc_ba98, width: 32, signed: false))
        check("wx.liveX", try e.evaluate(.register(name: "x3", version: 0)), 0xfedc_ba98, 64, .signed)
        check("wx.liveW", try e.evaluate(.register(name: "w3", version: 0)), 0xfedc_ba98, 32, .signed)
        check("wx.formalProjection", try e.evaluate(.argument(bindingID: .gpr(3))), 0x89ab_cdef, 32, .unsigned)
        e.alternateSignedness = true
        check("wx.unsignedToSigned", try e.evaluate(.argument(bindingID: .gpr(3))), 0x89ab_cdef, 32, .signed)
    }

    func testSIMDScalarOverwriteKeepsBothEntryWidthsAndBanks() throws {
        var state = try machine()
        state.v[0] = .init(low: 0xabcd_1234_3fc0_0000, high: 0x55)
        state.v[1] = .init(low: 0xc004_0000_0000_0000, high: 0x66)
        state.x[0] = 23
        var e = evaluator([
            parameter(.simd(index: 0, scalarWidth: 32), "float", row: "s"),
            parameter(.simd(index: 1, scalarWidth: 64), "double", row: "d"),
            parameter(.gpr(index: 0, carrierWidth: 64), "uint64_t", row: "x")
        ], state)
        try e.write(.register(name: "s0", version: 1), .init(bits: 0x4080_0000, width: 32, kind: .float))
        try e.write(.register(name: "d1", version: 1), .init(bits: 0x4014_0000_0000_0000, width: 64, kind: .float))
        check("simd.entryS", try e.evaluate(.argument(bindingID: .simd(0))), 0x3fc0_0000, 32, .float)
        check("simd.entryD", try e.evaluate(.argument(bindingID: .simd(1))), 0xc004_0000_0000_0000, 64, .float)
        check("simd.liveS", try e.evaluate(.register(name: "s0", version: 0)), 0x4080_0000, 32, .float)
        check("simd.liveD", try e.evaluate(.register(name: "d1", version: 0)), 0x4014_0000_0000_0000, 64, .float)
        check("simd.separateGPRBank", try e.evaluate(.argument(bindingID: .gpr(0))), 23, 64, .unsigned)
        e.alternateSignedness = true
        check("simd.alternateUnaffected", try e.evaluate(.argument(bindingID: .simd(0))), 0x3fc0_0000, 32, .float)
    }

    func testAlternateSignednessConfiguredAfterInitAndBetweenReads() throws {
        var state = try machine()
        state.x[4] = 0xffff_ffff_8000_0005
        var e = evaluator([parameter(.gpr(index: 4, carrierWidth: 32), "int32_t")], state)
        e.alternateSignedness = true
        try e.write(.register(name: "w4", version: 1), .int(9, width: 32, signed: false))
        check("alternate.firstRead", try e.evaluate(.argument(bindingID: .gpr(4))), 0x8000_0005, 32, .unsigned)
        check("alternate.unsignedShift", try e.evaluate(.binaryExpression(op: ">>", left: .argument(bindingID: .gpr(4)), right: .immediate(1))), 0x4000_0002, 32, .unsigned)
        e.alternateSignedness = false
        check("alternate.secondRead", try e.evaluate(.argument(bindingID: .gpr(4))), 0x8000_0005, 32, .signed)
        check("alternate.signedShift", try e.evaluate(.binaryExpression(op: ">>", left: .argument(bindingID: .gpr(4)), right: .immediate(1))), 0xc000_0002, 32, .signed)
        check("alternate.live", try e.evaluate(.register(name: "w4", version: 0)), 9, 32, .signed)
    }

    func testAbsentUnsupportedAndConflictingIdentitiesFailClosed() throws {
        let state = try machine()
        let p = parameter(.gpr(index: 1, carrierWidth: 64), "int64_t")
        unsupported("absent", [], .gpr(1), state)
        unsupported("declarationOnly", [parameter(.entryStack(byteOffset: 0, size: 8, alignment: 8), "uint64_t", bind: false)], .entryStack(byteOffset: 0), state)
        unsupported("unbound", [parameter(.unbound(reason: .unsupportedType("struct Pair")), "struct Pair", bind: false)], .gpr(1), state)
        unsupported("duplicateBinding", [p, p], .gpr(1), state)
        unsupported("conflictingBinding", [p, parameter(.gpr(index: 1, carrierWidth: 32), "uint32_t", row: "other")], .gpr(1), state)
        unsupported("conflictingRow", [p, parameter(.gpr(index: 2, carrierWidth: 64), "int64_t")], .gpr(1), state)
        unsupported("aggregateGPR", [parameter(.gpr(index: 1, carrierWidth: 64), "struct Pair")], .gpr(1), state)
        unsupported("floatGPR", [parameter(.gpr(index: 1, carrierWidth: 64), "double")], .gpr(1), state)
        unsupported("integerSIMD", [parameter(.simd(index: 1, scalarWidth: 64), "uint64_t")], .simd(1), state)
        unsupported("mismatchedSIMD", [parameter(.simd(index: 1, scalarWidth: 64), "float")], .simd(1), state)
        unsupported("oversizedStack", [parameter(.entryStack(byteOffset: 0, size: 16, alignment: 8), "uint64_t")], .entryStack(byteOffset: 0), state)
        unsupported("undersizedStack", [parameter(.entryStack(byteOffset: 0, size: 2, alignment: 2), "double")], .entryStack(byteOffset: 0), state)
    }
}
