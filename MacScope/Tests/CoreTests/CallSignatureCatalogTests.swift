import XCTest
@testable import MacScope

final class CallSignatureCatalogTests: XCTestCase {
    func testCanonicalizationStripsSingleLeadingUnderscore() {
        let catalog = CallSignatureCatalog([
            CallSignatureSpec(canonicalName: "malloc", returnType: "void *",
                              parameters: [.init(type: "size_t", name: "size")])
        ])
        XCTAssertNotNil(catalog.signature(for: "_malloc"))
        XCTAssertNotNil(catalog.signature(for: "malloc"))
        XCTAssertNil(catalog.signature(for: "nope"))
        // The rendered target preserves the decorated form that was passed in.
        XCTAssertEqual(catalog.signature(for: "_malloc")?.target, "_malloc")
    }

    func testIntegerArgsAssignSequentialXRegisters() {
        let params = CallSignatureCatalog.assignRegisters([
            .init(type: "void *", name: "dst"),
            .init(type: "const void *", name: "src"),
            .init(type: "size_t", name: "count")
        ])
        XCTAssertEqual(params.map(\.register), ["x0", "x1", "x2"])
        XCTAssertEqual(params.map(\.index), [0, 1, 2])
    }

    func testThirtyTwoBitIntegerUsesWRegister() {
        let params = CallSignatureCatalog.assignRegisters([
            .init(type: "int32_t", name: "value")
        ])
        XCTAssertEqual(params.map(\.register), ["w0"])
    }

    func testSeedsResolveAndRepresentativeShapesMatch() {
        let catalog = CallSignatureCatalog.standard
        // Spot-check representative shapes across the migrated table.
        let memcpy = catalog.signature(for: "_memcpy")
        XCTAssertEqual(memcpy?.returnType, "void *")
        XCTAssertEqual(memcpy?.parameters.map(\.type), ["void *", "const void *", "size_t"])
        XCTAssertEqual(memcpy?.parameters.map(\.register), ["x0", "x1", "x2"])
        XCTAssertEqual(memcpy?.parameters.map(\.name), ["dst", "src", "count"])

        let printf = catalog.signature(for: "_printf")
        XCTAssertEqual(printf?.isVariadic, true)
        XCTAssertEqual(printf?.parameters.map(\.type), ["const char *"])

        let objcMsgSend = catalog.signature(for: "_objc_msgSend")
        XCTAssertEqual(objcMsgSend?.returnType, "id")
        XCTAssertEqual(objcMsgSend?.parameters.map(\.type), ["id", "SEL"])
        XCTAssertEqual(objcMsgSend?.isVariadic, true)

        // Every seed, including the two Swift unknown-object aliases, resolves.
        let names = CallSignatureCatalog.seeds.map(\.canonicalName)
        XCTAssertEqual(names.count, 33)
        XCTAssertEqual(Set(names).count, names.count)
        for n in names { XCTAssertNotNil(catalog.signature(for: n), "missing seed \(n)") }
    }

    func testFloatArgsUseVRegisterFileIndependentOfIntegers() {
        // void f(int a, double b, void *c, float d) → x0, d0, x1, s1
        let params = CallSignatureCatalog.assignRegisters([
            .init(type: "int32_t", name: "a"),
            .init(type: "double", name: "b"),
            .init(type: "void *", name: "c"),
            .init(type: "float", name: "d")
        ])
        XCTAssertEqual(params.map(\.register), ["w0", "d0", "x1", "s1"])
        XCTAssertEqual(params.map(\.index), [0, 1, 2, 3])   // index = source position
    }

    func testDoubleOnlySignatureUsesDRegisters() {
        let params = CallSignatureCatalog.assignRegisters([
            .init(type: "double", name: "x"), .init(type: "double", name: "y")
        ])
        XCTAssertEqual(params.map(\.register), ["d0", "d1"])
    }

    func testFPRegisterNumberAcceptsOnlyAAPCSArgumentRange() {
        XCTAssertEqual(MacIRBuilder.fpRegisterNumber("d0"), 0)
        XCTAssertEqual(MacIRBuilder.fpRegisterNumber(" s7 "), 7)
        XCTAssertNil(MacIRBuilder.fpRegisterNumber("d8"))
        XCTAssertNil(MacIRBuilder.fpRegisterNumber("s8"))
        XCTAssertNil(MacIRBuilder.fpRegisterNumber("d-1"))
        XCTAssertNil(MacIRBuilder.fpRegisterNumber("q0"))
        XCTAssertNil(MacIRBuilder.fpRegisterNumber("d"))
    }

    func testFunctionReadingD0RecoversADoubleParameter() {
        // A body that reads d0 (a double arg) and returns — recovery should surface a float param.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "fmov", operands: "d1, d0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fn = MacIRBuilder().buildFunction(name: "f", instructions: rows)
        XCTAssertTrue(fn.parameters.contains { $0.type == "double" && $0.register == "d0" },
                      "expected a recovered double parameter in d0")
        let marker = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
        XCTAssertEqual(fn.returnValue, marker,
                       "an FP-only d0 parameter is not return evidence, and missing evidence is not void")
        XCTAssertEqual(fn.instructions.last?.operation, .returnValue(marker))
    }

    func testImmediateProducedFPRegisterIsNotRecoveredAsParameter() {
        // `fmov d0, #1.0` produces d0 locally; the later `fmov d1, d0` read must
        // be gated by the write, so NO double parameter should be fabricated.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "fmov", operands: "d0, #1.0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fmov", operands: "d1, d0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fn = MacIRBuilder().buildFunction(name: "f", instructions: rows)
        XCTAssertFalse(fn.parameters.contains { $0.register == "d0" },
                       "d0 was produced by fmov #imm and must not be recovered as a parameter")
    }

    func testArithmeticProducedFPRegisterStoredIsNotRecoveredAsParameter() {
        // `fmul d0, d1, d2` produces d0 locally; the later `str d0, [x8]` surfaces
        // d0 via the generic store-read path, but the fmul write must gate it so
        // NO double parameter is fabricated.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "fmul", operands: "d0, d1, d2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "str", operands: "d0, [x8]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fn = MacIRBuilder().buildFunction(name: "f", instructions: rows)
        XCTAssertFalse(fn.parameters.contains { $0.register == "d0" },
                       "d0 was produced by fmul and must not be recovered as a parameter")
    }

    func testMixedIntAndFloatParamsGetDistinctNonCollidingABINames() {
        // Mixed register banks do not prove a source-language parameter order.
        // Preserve the independent ABI identities and render them as inputs,
        // rather than compressing x0 and s0 into an ordered C prototype.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "mov", operands: "x8, x0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fmov", operands: "s1, s0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fn = MacIRBuilder().buildFunction(name: "f", instructions: rows)
        XCTAssertEqual(fn.parameters.map(\.register), ["x0", "s0"])
        XCTAssertEqual(fn.parameters.map(\.type), ["int64_t", "float"])
        XCTAssertEqual(fn.parameters.map(\.index), [0, 1])
        XCTAssertEqual(fn.parameters.map(\.name), ["in_x0", "in_s0"])
        // Names must remain distinct across the independently numbered banks.
        XCTAssertEqual(Set(fn.parameters.map(\.name)).count, fn.parameters.count)

        guard case let .assign(_, integerSource) = fn.instructions[0].operation else {
            return XCTFail("expected the x0 read to lift as an assignment")
        }
        XCTAssertEqual(integerSource, .argument(bindingID: .gpr(0)))
        guard case let .assign(_, floatingSource) = fn.instructions[1].operation else {
            return XCTFail("expected the s0 read to lift as an assignment")
        }
        XCTAssertEqual(floatingSource, .argument(bindingID: .simd(0)))

        let document = PseudocodePrinter().print(function: fn)
        XCTAssertTrue(
            document.text.contains("int64_t f(/* ABI inputs: x0:int64_t in_x0, s0:float in_s0 */) {")
        )
        XCTAssertFalse(document.text.contains("int64_t f(int64_t"))
    }

    func testSparseIntegerAndFloatParamsGetDistinctIndicesAndNames() {
        // x1 is a read-before-write incoming register candidate while x0 is absent. The
        // independently numbered d0 parameter must be placed after the highest
        // occupied integer index, not after the integer parameter count (1),
        // because index 1 is already occupied by x1.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "mov", operands: "x8, x1", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fmov", operands: "x9, d0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let fn = MacIRBuilder().buildFunction(name: "f", instructions: rows)
        XCTAssertEqual(fn.parameters.map(\.register), ["x1", "d0"])
        XCTAssertEqual(fn.parameters.map(\.type), ["int64_t", "double"])
        XCTAssertEqual(fn.parameters.map(\.index), [1, 2])
        XCTAssertEqual(fn.parameters.map(\.name), ["in_x1", "in_d0"])
        XCTAssertEqual(Set(fn.parameters.map(\.id)).count, fn.parameters.count)
        XCTAssertEqual(Set(fn.parameters.map(\.name)).count, fn.parameters.count)

        guard case let .assign(_, integerSource) = fn.instructions[0].operation else {
            return XCTFail("expected the x1 read to lift as an assignment")
        }
        XCTAssertEqual(integerSource, .argument(bindingID: .gpr(1)))
        guard case let .intrinsic(_, name, floatingArguments) = fn.instructions[1].operation else {
            return XCTFail("expected the d0 read to lift as an fmov intrinsic")
        }
        XCTAssertEqual(name, "fmov")
        XCTAssertEqual(floatingArguments, [.argument(bindingID: .simd(0))])

        let document = PseudocodePrinter().print(function: fn)
        XCTAssertTrue(
            document.text.contains("int64_t f(/* ABI inputs: x1:int64_t in_x1, d0:double in_d0 */) {")
        )
        XCTAssertFalse(document.text.contains("int64_t f(int64_t"))
    }

    // MARK: - FP corpus integration (bl-seed classification + FP call-site args)

    func testFPCatalogCallDoesNotFabricateParameterWhenDRegisterWritten() {
        // `fmov d0, #1.0` produces d0 locally, then `bl _sin` (a `double`-in-d0
        // callee). The bl seed must consult the FP write set and skip d0, so the
        // OUTER function recovers ZERO parameters (no fabricated double).
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "fmov", operands: "d0, #1.0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "bl", operands: "_sin", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fn = MacIRBuilder().buildFunction(name: "g", instructions: rows)
        XCTAssertTrue(fn.parameters.isEmpty,
                      "d0 was written locally; the _sin bl seed must not fabricate a double parameter")
    }

    func testKnownFPCallResultIsNotRecoveredAsAnOuterParameter() {
        // drand48 has no arguments and returns double in d0. A later read of that
        // result is local call output, never evidence for an incoming d0 formal.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: "_drand48", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fmov", operands: "x8, d0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let fn = MacIRBuilder().buildFunction(name: "random", instructions: rows)
        XCTAssertFalse(fn.parameters.contains { $0.register == "d0" },
                       "a known FP call result must join the FP write set")
    }

    func testLaterFPResultWriteSupersedesEarlierIntegerCallResult() {
        // The explicit d0 write is later than strlen's x0 result and is therefore
        // the stronger ABI-return candidate at ret.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: "_strlen", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fmov", operands: "d0, #1.0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let fn = MacIRBuilder().buildFunction(name: "mixed_result", instructions: rows)
        let marker = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
        XCTAssertEqual(fn.returnValue, marker)
        XCTAssertEqual(fn.instructions.last?.operation, .returnValue(marker))
    }

    func testLatestModeledWriteWinsAcrossEveryABIResultRegisterView() {
        let cases: [(name: String, firstCall: String, laterInstruction: (String, String), expected: MacIRValue)] = [
            ("x0_to_w0", "_strlen", ("mov", "w0, #1"), .register(name: "w0", version: 1)),
            ("w0_to_s0", "_getpid", ("fmov", "s0, #1.0"), .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)),
            ("s0_to_d0", "_sinf", ("fmov", "d0, #1.0"), .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)),
            ("d0_to_x0", "_drand48", ("mov", "x0, #1"), .register(name: "x0", version: 1)),
        ]

        for testCase in cases {
            let rows = [
                InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: testCase.firstCall, hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "", mnemonic: testCase.laterInstruction.0, operands: testCase.laterInstruction.1, hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ]
            let fn = MacIRBuilder().buildFunction(name: testCase.name, instructions: rows)
            XCTAssertEqual(fn.returnValue, testCase.expected, testCase.name)
            XCTAssertEqual(fn.instructions.last?.operation, .returnValue(testCase.expected), testCase.name)
        }
    }

    func testUnmodeledFPResultWriteInvalidatesEarlierReturnCandidate() {
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: "_strlen", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fadd", operands: "d0, d1, d2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let fn = MacIRBuilder().buildFunction(name: "unmodeled_result", instructions: rows)
        let marker = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
        XCTAssertEqual(fn.returnValue, marker)
        XCTAssertEqual(fn.instructions.last?.operation, .returnValue(marker))
    }

    func testUnmodeledFPWriteCannotFeedAStaleValueToLaterKnownCall() throws {
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: "_drand48", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fadd", operands: "d0, d1, d2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "bl", operands: "_sin", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let fn = MacIRBuilder().buildFunction(name: "stale_fp_call_argument", instructions: rows)
        let sinFrame = try XCTUnwrap(callFrame(in: fn, target: "_sin"))
        XCTAssertEqual(sinFrame.knownSignature?.target, "_sin")
        XCTAssertEqual(sinFrame.arguments.fixedArgument(at: 0)?.value, .register(name: "d0", version: 2))
        XCTAssertEqual(sinFrame.arguments.argument(at: .simd(index: 0))?.value, .register(name: "d0", version: 2))
        XCTAssertEqual(sinFrame.arguments.denseFixedPrefixValues(), [.register(name: "d0", version: 2)])
    }

    func testUnmodeledFPWriteCannotResurfaceAnOverwrittenRecoveredParameter() throws {
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "fmov", operands: "x8, d0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fadd", operands: "d0, d1, d2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "bl", operands: "_sin", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ]
        let fn = MacIRBuilder().buildFunction(name: "overwritten_fp_parameter", instructions: rows)
        let sinFrame = try XCTUnwrap(callFrame(in: fn, target: "_sin"))
        XCTAssertEqual(sinFrame.knownSignature?.target, "_sin")
        XCTAssertEqual(sinFrame.arguments.fixedArgument(at: 0)?.value, .register(name: "d0", version: 1))
        XCTAssertEqual(sinFrame.arguments.argument(at: .simd(index: 0))?.value, .register(name: "d0", version: 1))
        XCTAssertEqual(sinFrame.arguments.denseFixedPrefixValues(), [.register(name: "d0", version: 1)])
    }

    func testUnmodeledFPWriteTombstonesTheSiblingScalarView() throws {
        let cases: [(seed: (String, String), overwrite: (String, String), call: String)] = [
            (("fmov", "d0, #1.0"), ("fadd", "s0, s1, s2"), "_sin"),
            (("fmov", "s0, #1.0"), ("fadd", "d0, d1, d2"), "_sinf"),
        ]

        for testCase in cases {
            let rows = [
                InstructionRow(address: 0x1000, bytes: "", mnemonic: testCase.seed.0, operands: testCase.seed.1, hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "", mnemonic: testCase.overwrite.0, operands: testCase.overwrite.1, hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1008, bytes: "", mnemonic: "bl", operands: testCase.call, hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x100c, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ]
            let fn = MacIRBuilder().buildFunction(name: "sibling_fp_tombstone", instructions: rows)
            let frame = try XCTUnwrap(callFrame(in: fn, target: testCase.call))
            XCTAssertEqual(frame.knownSignature?.target, testCase.call)
            XCTAssertNil(frame.arguments.fixedArgument(at: 0), testCase.call)
            XCTAssertNil(frame.arguments.argument(at: .simd(index: 0)), testCase.call)
            XCTAssertEqual(frame.arguments.denseFixedPrefixValues(), [], testCase.call)
        }
    }

    func testUnknownIntegerResultWritesMaterializeFreshReturnCandidates() {
        for destination in ["x0", "w0"] {
            // The shifted movn form falls through to an unknown instruction, but
            // its scalar-GPR destination is definite. The unknown lift therefore
            // materializes a fresh SSA result that must supersede the earlier d0.
            let rows = [
                InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: "_drand48", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "", mnemonic: "movn", operands: "\(destination), #1, lsl #16", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ]
            let fn = MacIRBuilder().buildFunction(name: "unmodeled_\(destination)", instructions: rows)
            let expected = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
            XCTAssertEqual(fn.returnValue, expected, destination)
            XCTAssertEqual(fn.instructions.last?.operation, .returnValue(expected), destination)
        }
    }

    func testGenuineFPParamNotDuplicatedByFPCatalogCall() {
        // `str d0, [sp, #0x8]` reads d0 as a genuine incoming arg (read-before-write),
        // then `bl _sin` (also a d0 callee). The bl seed must MERGE into the same FP
        // register slot, not add a second parameter on d0.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "str", operands: "d0, [sp, #0x8]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "bl", operands: "_sin", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fn = MacIRBuilder().buildFunction(name: "h", instructions: rows)
        XCTAssertEqual(fn.parameters.filter { $0.register == "d0" }.count, 1,
                       "d0 must be recovered exactly once (no duplicate from the _sin bl seed)")
    }

    func testFPCallSiteRecoversArgumentFromDRegisterAndIntegerStillWorks() throws {
        // FP call: value in d0 then `bl _sin` -> the call must surface d0's value
        // as its argument (the old index-only probe read x0 and recovered nothing).
        let fpRows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "fmov", operands: "d0, #2.0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "bl", operands: "_sin", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fpFn = MacIRBuilder().buildFunction(name: "k", instructions: fpRows)
        let sinFrame = try XCTUnwrap(callFrame(in: fpFn, target: "_sin"))
        XCTAssertEqual(sinFrame.knownSignature?.target, "_sin")
        let sinArgument = try XCTUnwrap(sinFrame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(sinArgument.location, .simd(index: 0, scalarWidth: 64))
        XCTAssertEqual(sinArgument.role, .fixed(sourcePosition: 0))
        XCTAssertEqual(sinArgument.value, .register(name: "d0", version: 1))
        XCTAssertEqual(
            sinFrame.arguments.denseFixedPrefixValues(),
            [.register(name: "d0", version: 1)],
            "_sin's d0 argument must be recovered from the d register"
        )

        // Parallel integer call: value in x0 then `bl _strlen` still recovers its arg.
        let intRows = [
            InstructionRow(address: 0x2000, bytes: "", mnemonic: "mov", operands: "x0, #5", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2004, bytes: "", mnemonic: "bl", operands: "_strlen", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let intFn = MacIRBuilder().buildFunction(name: "m", instructions: intRows)
        let strlenFrame = try XCTUnwrap(callFrame(in: intFn, target: "_strlen"))
        XCTAssertEqual(strlenFrame.knownSignature?.target, "_strlen")
        let strlenArgument = try XCTUnwrap(strlenFrame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(strlenArgument.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(strlenArgument.role, .fixed(sourcePosition: 0))
        XCTAssertEqual(strlenArgument.value, .register(name: "x0", version: 1))
        XCTAssertEqual(
            strlenFrame.arguments.denseFixedPrefixValues(),
            [.register(name: "x0", version: 1)],
            "_strlen's x0 argument must still be recovered"
        )
    }

    func testMixedSignatureCallDoesNotFabricateWhenRegistersLocallyWritten() {
        // frexp(double value, int* exp): value=d0 (source index0), exp=x0 but source
        // index1 (NSRN/NGRN advance independently). Body writes BOTH x0 (add x0,sp,#16)
        // and d0 (fmov d0,#3.0) locally, then bl _frexp. The integer seed must key/gate
        // by exp's REGISTER number (x0 -> 0), which is in writtenArgumentIndexes, so it
        // is skipped. Keying by source position (1) would wrongly fabricate `int * arg1`.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "add", operands: "x0, sp, #16", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fmov", operands: "d0, #3.0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "bl", operands: "_frexp", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fn = MacIRBuilder().buildFunction(name: "user", instructions: rows)
        XCTAssertTrue(fn.parameters.isEmpty,
                      "both x0 and d0 were locally written; the _frexp seed must fabricate nothing")
    }

    func testMixedCatalogOnlyCallUsesRegisterBasedOuterParamIndicesAndKeepsBothArguments() throws {
        // frexp(double value, int *exp) assigns source positions 0/1 to d0/x0,
        // but recovered outer-function parameter identity is register based.
        // With no local writes, both incoming registers must be recovered and
        // the lifted call must retain both values in the catalog's source order.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: "_frexp", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let fn = MacIRBuilder().buildFunction(name: "forward", instructions: rows)
        XCTAssertEqual(fn.parameters.map(\.register), ["x0", "d0"])
        XCTAssertEqual(fn.parameters.map(\.type), ["int *", "double"])
        XCTAssertEqual(fn.parameters.map(\.index), [0, 1])
        XCTAssertEqual(fn.parameters.map(\.name), ["in_x0", "in_d0"])
        XCTAssertEqual(Set(fn.parameters.map(\.id)).count, fn.parameters.count)
        XCTAssertEqual(Set(fn.parameters.map(\.name)).count, fn.parameters.count)

        let frame = try XCTUnwrap(callFrame(in: fn, target: "_frexp"))
        XCTAssertEqual(frame.knownSignature?.target, "_frexp")
        let valueArgument = try XCTUnwrap(frame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(valueArgument.location, .simd(index: 0, scalarWidth: 64))
        XCTAssertEqual(valueArgument.role, .fixed(sourcePosition: 0))
        XCTAssertEqual(valueArgument.value, .argument(bindingID: .simd(0)))
        let exponentArgument = try XCTUnwrap(frame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(exponentArgument.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(exponentArgument.role, .fixed(sourcePosition: 1))
        XCTAssertEqual(exponentArgument.value, .argument(bindingID: .gpr(0)))
        XCTAssertEqual(
            frame.arguments.denseFixedPrefixValues(),
            [
                .argument(bindingID: .simd(0)),
                .argument(bindingID: .gpr(0))
            ]
        )
        XCTAssertTrue(
            PseudocodePrinter().print(function: fn).text.contains(
                "/* ABI inputs: x0:int * in_x0, d0:double in_d0 */"
            )
        )
    }

    func testKnownMixedCallAbstainsWhenLeadingArgumentRegisterIsUnavailable() throws {
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "fadd", operands: "d0, d1, d2", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "bl", operands: "_frexp", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let fn = MacIRBuilder().buildFunction(name: "partial", instructions: rows)
        let frame = try XCTUnwrap(callFrame(in: fn, target: "_frexp"))
        XCTAssertEqual(frame.knownSignature?.target, "_frexp")
        XCTAssertEqual(frame.arguments.fixedArgument(at: 0)?.value, .register(name: "d0", version: 1))
        XCTAssertEqual(frame.arguments.argument(at: .simd(index: 0))?.value, .register(name: "d0", version: 1))
        let exponentArgument = try XCTUnwrap(frame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(exponentArgument.location, .gpr(index: 0, carrierWidth: 64))
        XCTAssertEqual(exponentArgument.role, .fixed(sourcePosition: 1))
        XCTAssertEqual(exponentArgument.value, .argument(bindingID: .gpr(0)))
        XCTAssertEqual(
            frame.arguments.denseFixedPrefixValues(),
            [.register(name: "d0", version: 1), .argument(bindingID: .gpr(0))],
            "the modeled floating-point result precedes the independent pointer argument"
        )
        XCTAssertFalse(PseudocodePrinter().print(function: fn).text.contains("_frexp(arg0)"),
                       "the later exp pointer must not render as frexp's leading double argument")
    }

    func testKnownCallRetainsSparseLaterArgumentAndProjectsOnlyAvailablePrefix() throws {
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "fmov", operands: "d0, #2.0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "fadd", operands: "d1, d4, d5", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "fmov", operands: "d2, #3.0", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "", mnemonic: "bl", operands: "_fma", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1010, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]

        let fn = MacIRBuilder().buildFunction(name: "prefix", instructions: rows)
        let frame = try XCTUnwrap(callFrame(in: fn, target: "_fma"))
        XCTAssertEqual(frame.knownSignature?.target, "_fma")
        let firstArgument = try XCTUnwrap(frame.arguments.fixedArgument(at: 0))
        XCTAssertEqual(firstArgument.location, .simd(index: 0, scalarWidth: 64))
        XCTAssertEqual(firstArgument.value, .register(name: "d0", version: 1))
        XCTAssertEqual(frame.arguments.fixedArgument(at: 1)?.value, .register(name: "d1", version: 1))
        XCTAssertEqual(frame.arguments.argument(at: .simd(index: 1))?.value, .register(name: "d1", version: 1))
        let laterArgument = try XCTUnwrap(frame.arguments.fixedArgument(at: 2))
        XCTAssertEqual(laterArgument.location, .simd(index: 2, scalarWidth: 64))
        XCTAssertEqual(laterArgument.role, .fixed(sourcePosition: 2))
        XCTAssertEqual(laterArgument.value, .register(name: "d2", version: 1))
        XCTAssertEqual(
            frame.arguments.denseFixedPrefixValues(),
            [.register(name: "d0", version: 1), .register(name: "d1", version: 1), .register(name: "d2", version: 1)]
        )
    }

    func testMixedSignatureBlSeedDoesNotDuplicateIntegerParam() {
        // ldexp(double x, int n): x=d0 (index0), n=w0 but source index1. Body directly
        // reads d0 and w0 as genuine args (read-before-write), then bl _ldexp. The seed
        // must MERGE n into the same integer register slot (w0 -> 0) as the direct read,
        // not add a second integer param keyed by source position 1.
        let rows = [
            InstructionRow(address: 0x1000, bytes: "", mnemonic: "str", operands: "d0, [sp, #0x8]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "str", operands: "w0, [sp, #0x4]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "bl", operands: "_ldexp", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let fn = MacIRBuilder().buildFunction(name: "h", instructions: rows)
        XCTAssertEqual(fn.parameters.count, 2,
                       "expected exactly one integer (w0) and one float (d0) param — no duplicate")
        XCTAssertEqual(fn.parameters.filter { $0.register == "w0" }.count, 1,
                       "the w0 integer param must not be duplicated by the _ldexp bl seed")
        XCTAssertEqual(fn.parameters.filter { $0.register == "d0" }.count, 1,
                       "the d0 float param must be present exactly once")
    }

    private func callFrame(in function: MacIRFunction, target: String) -> MacIRCallFrame? {
        function.instructions.compactMap { instruction -> MacIRCallFrame? in
            guard case let .call(frame, _) = instruction.operation,
                  frame.target == target else {
                return nil
            }
            return frame
        }.first
    }
}
