import XCTest
@testable import MacScope

final class D05RichABIIntegrationTests: XCTestCase {
    private let base: UInt64 = 0x7d00

    private func types() -> [TypeDefinition] {
        CTypeHeaderParser.parse("""
        struct Pair { double real; double imag; };
        struct Rect { double x; double y; double width; double height; };
        struct Large { long a; long b; long c; };
        struct IntegerPair { uint64_t low64; uint64_t high64; };
        struct IntegerOne { uint64_t value; };
        struct IntegerSmall { uint32_t value; };
        struct MixedPair { uint64_t tag; double value; };
        struct DepthStencil { float depth; uint32_t stencil; };
        struct MixedPointer { float scale; char *name; };
        """).types
    }

    private func signature(_ type: String, row: String = "source:pair") -> FunctionSignatureOverride {
        FunctionSignatureOverride(
            returnType: type,
            args: [ArgOverride(rowToken: row, name: "z", type: type, provenance: .script)]
        )
    }

    private func row(_ offset: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        InstructionRow(address: base + offset, bytes: "", mnemonic: mnemonic,
                       operands: operands, hasBreakpoint: false, comment: nil)
    }

    func testOneSourceHFAFlowsThroughBodyCallAndReturn() throws {
        let authored = signature("Pair")
        let function = PseudocodePrinter().buildFunction(
            functionName: "caller", startAddress: base,
            signatureOverrides: [base: authored],
            authoredCallSignaturesByTarget: ["_callee": authored],
            types: types(),
            instructions: [
                row(0, "fmov", "d2, d0"), row(4, "fneg", "d0, d1"),
                row(8, "fmov", "d1, d2"), row(12, "bl", "_callee"),
                row(16, "ret", ""),
            ]
        )
        XCTAssertEqual(function.parameters.count, 1)
        XCTAssertEqual(function.parameters[0].id.rawValue, "source:pair")
        guard case let .composite(incoming)? = function.parameters[0].richLocation else {
            return XCTFail("one source row must retain both HFA carriers")
        }
        XCTAssertEqual(incoming.map(\.valueByteOffset), [0, 8])
        XCTAssertEqual(incoming.map(\.register), [
            .simd(index: 0, registerWidth: 64), .simd(index: 1, registerWidth: 64),
        ])
        let audit = function.parameterBindingAudit()
        XCTAssertEqual(audit.records.count, 1)
        XCTAssertEqual(audit.records[0].binding, "source-row:source:pair")
        XCTAssertEqual(audit.records[0].location, "d0@0+8,d1@8+8")
        XCTAssertFalse(audit.records[0].bodyUses.isEmpty)
        XCTAssertTrue(audit.danglingBodyUses.isEmpty)
        guard let call = function.instructions.first(where: {
            if case .call = $0.operation { return true }; return false
        }), case let .call(frame, result) = call.operation else {
            return XCTFail("rich call must be lifted")
        }
        XCTAssertEqual(frame.richArguments?.count, 1)
        XCTAssertEqual(frame.richArguments?[0].rowID.rawValue, "source:pair")
        XCTAssertEqual(frame.richArguments?[0].pieces.map(\.valueByteOffset), [0, 8])
        guard case let .abiComposite(_, resultFragments)? = result else {
            return XCTFail("rich result must retain two output carriers")
        }
        XCTAssertEqual(resultFragments.count, 2)
        guard case let .abiComposite(_, returnedFragments)? = function.returnValue else {
            return XCTFail("return must read two output carriers")
        }
        XCTAssertEqual(returnedFragments.count, 2)
        let text = PseudocodePrinter().print(function: function, types: types()).text
        XCTAssertTrue(text.contains("z.real"), text)
        XCTAssertTrue(text.contains("z.imag"), text)
        XCTAssertTrue(text.contains("_callee(__abi_compose<Pair>("), text)
        XCTAssertFalse(text.contains("x0_1 = _callee"), text)
    }

    func testLargeReturnUsesX8BufferEvidenceAndNeverTreatsX8AsReturnedValue() throws {
        let large = FunctionSignatureOverride(returnType: "Large", args: [])
        let function = PseudocodePrinter().buildFunction(
            functionName: "caller", startAddress: base,
            signatureOverrides: [base: large],
            authoredCallSignaturesByTarget: ["_large": large],
            types: types(),
            instructions: [row(0, "mov", "x8, x20"), row(4, "bl", "_large"), row(8, "ret", "")]
        )
        guard let call = function.instructions.first(where: {
            if case .call = $0.operation { return true }; return false
        }), case let .call(frame, result) = call.operation else {
            return XCTFail("indirect result call must be lifted")
        }
        XCTAssertNil(result)
        XCTAssertNotNil(frame.indirectResultPointer)
        let text = PseudocodePrinter().print(function: function, types: types()).text
        XCTAssertTrue(text.contains("indirect result buffer:"), text)
        XCTAssertTrue(text.contains("indirect_result_via_x8_unverified"), text)
        XCTAssertFalse(text.contains("return x8"), text)
    }

    func testVectorWriteInvalidatesIncomingDoubleFragment() {
        let function = PseudocodePrinter().buildFunction(
            functionName: "shadowed", startAddress: base,
            signatureOverrides: [base: signature("Pair")], types: types(),
            instructions: [row(0, "movi", "v0.16b, #0"),
                           row(4, "fmov", "d2, d0"), row(8, "ret", "")]
        )
        let text = PseudocodePrinter().print(function: function, types: types()).text
        XCTAssertFalse(text.contains("z.real"), text)
    }

    func testUnsupportedAuthoredReturnDoesNotFallBackToX0() {
        let authored = FunctionSignatureOverride(returnType: "opaque_missing_type", args: [])
        let function = PseudocodePrinter().buildFunction(
            functionName: "unknown_return", startAddress: base,
            signatureOverrides: [base: authored], types: types(),
            instructions: [row(0, "mov", "x0, x3"), row(4, "ret", "")]
        )
        let text = PseudocodePrinter().print(function: function, types: types()).text
        XCTAssertTrue(text.contains("unbound_authored_return"), text)
        XCTAssertFalse(text.contains("return x0"), text)
    }

    func testIntegerStructKeepsOneSourceRowAcrossBodyCallAndReturn() {
        let pair = FunctionSignatureOverride(
            returnType: "IntegerPair",
            args: [ArgOverride(rowToken: "source:integer-pair", name: "hash",
                               type: "IntegerPair", provenance: .script)]
        )
        let function = PseudocodePrinter().buildFunction(
            functionName: "integer_caller", startAddress: base,
            signatureOverrides: [base: pair],
            authoredCallSignaturesByTarget: ["_integer_callee": pair],
            types: types(),
            instructions: [row(0, "eor", "x2, x0, x1"),
                           row(4, "bl", "_integer_callee"), row(8, "ret", "")]
        )
        XCTAssertEqual(function.parameters.count, 1)
        let audit = function.parameterBindingAudit()
        XCTAssertEqual(audit.records.count, 1)
        XCTAssertEqual(audit.records[0].binding, "source-row:source:integer-pair")
        XCTAssertEqual(audit.records[0].location, "x0@0+8,x1@8+8")
        XCTAssertFalse(audit.records[0].bodyUses.isEmpty)
        XCTAssertTrue(audit.danglingBodyUses.isEmpty)
        guard let call = function.instructions.first(where: {
            if case .call = $0.operation { return true }; return false
        }), case let .call(frame, result) = call.operation else {
            return XCTFail("integer struct call must be lifted")
        }
        XCTAssertEqual(frame.richArguments?.count, 1)
        XCTAssertEqual(frame.richArguments?[0].rowID.rawValue, "source:integer-pair")
        XCTAssertEqual(frame.richArguments?[0].pieces.map(\.valueByteOffset), [0, 8])
        guard case let .abiComposite(_, resultFragments)? = result else {
            return XCTFail("returning integer struct call must retain x0/x1")
        }
        XCTAssertEqual(resultFragments.count, 2)
        guard case let .abiComposite(_, returnFragments)? = function.returnValue else {
            return XCTFail("integer struct return must retain x0/x1")
        }
        XCTAssertEqual(returnFragments.count, 2)
        let text = PseudocodePrinter().print(function: function, types: types()).text
        XCTAssertTrue(text.contains("hash.low64"), text)
        XCTAssertTrue(text.contains("hash.high64"), text)
        XCTAssertTrue(text.contains("_integer_callee(__abi_compose<IntegerPair>("), text)
        XCTAssertFalse(text.contains("unbound_aggregate_return"), text)
    }

    func testOneCarrierIntegerStructAndMixedStructsBindInGPRs() {
        let one = FunctionSignatureOverride(
            returnType: "IntegerOne",
            args: [ArgOverride(rowToken: "source:one", name: "one", type: "IntegerOne", provenance: .script)]
        )
        let admitted = PseudocodePrinter().buildFunction(
            functionName: "one", startAddress: base,
            signatureOverrides: [base: one], types: types(),
            instructions: [row(0, "mov", "x0, x0"), row(4, "ret", "")]
        )
        XCTAssertEqual(admitted.parameterBindingAudit().records[0].location, "x0@0+8")
        XCTAssertEqual(admitted.parameterBindingAudit().records[0].binding, "source-row:source:one")

        let mixed = FunctionSignatureOverride(
            returnType: "MixedPair",
            args: [ArgOverride(rowToken: "source:mixed", name: "mixed", type: "MixedPair", provenance: .script)]
        )
        // A non-HFA mixed integer/FP struct travels byte-for-byte in dense GPRs.
        let bound = PseudocodePrinter().buildFunction(
            functionName: "mixed", startAddress: base,
            signatureOverrides: [base: mixed], types: types(),
            instructions: [row(0, "mov", "x0, x0"), row(4, "mov", "x1, x1"), row(8, "ret", "")]
        )
        XCTAssertEqual(bound.parameterBindingAudit().records[0].location, "x0@0+8,x1@8+8")
        XCTAssertEqual(bound.parameterBindingAudit().records[0].binding, "source-row:source:mixed")
        let text = PseudocodePrinter().print(function: bound, types: types()).text
        XCTAssertFalse(text.contains("unbound_authored_return"), text)

        // MoltenVK `double mvkMTLClearDepthFromVkClearValue(VkClearDepthStencilValue)`
        // shape: one 8-byte {float, uint32_t} in x0, depth read as the low 32 bits.
        let depth = FunctionSignatureOverride(
            returnType: "double",
            args: [ArgOverride(rowToken: "source:clear", name: "clearValue", type: "DepthStencil", provenance: .script)]
        )
        let clear = PseudocodePrinter().buildFunction(
            functionName: "clear_depth", startAddress: base,
            signatureOverrides: [base: depth], types: types(),
            instructions: [row(0, "mov", "x19, x0"), row(4, "fmov", "s0, w19"),
                           row(8, "fcvt", "d0, s0"), row(12, "ret", "")]
        )
        let record = clear.parameterBindingAudit().records[0]
        XCTAssertEqual(record.location, "x0@0+8")
        XCTAssertEqual(record.binding, "source-row:source:clear")
        XCTAssertFalse(record.bodyUses.isEmpty)

        // Pointer-bearing mixed structs still abstain.
        let pointer = FunctionSignatureOverride(
            returnType: "void",
            args: [ArgOverride(rowToken: "source:ptr", name: "p", type: "MixedPointer", provenance: .script)]
        )
        let refused = PseudocodePrinter().buildFunction(
            functionName: "pointer", startAddress: base,
            signatureOverrides: [base: pointer], types: types(),
            instructions: [row(0, "mov", "x0, x0"), row(4, "ret", "")]
        )
        XCTAssertNil(refused.parameters[0].richLocation)
        XCTAssertNil(refused.parameterBindingAudit().records[0].binding)
    }

    func testTwoIntegerStructCallArgumentsWithScalarReturn() {
        let compare = FunctionSignatureOverride(
            returnType: "int",
            args: [
                ArgOverride(rowToken: "source:h1", name: "h1", type: "IntegerPair", provenance: .script),
                ArgOverride(rowToken: "source:h2", name: "h2", type: "IntegerPair", provenance: .script),
            ]
        )
        let function = PseudocodePrinter().buildFunction(
            functionName: "compare_caller", startAddress: base,
            signatureOverrides: [base: compare],
            authoredCallSignaturesByTarget: ["_compare": compare],
            types: types(),
            instructions: [row(0, "bl", "_compare"), row(4, "ret", "")]
        )
        guard let call = function.instructions.first(where: {
            if case .call = $0.operation { return true }; return false
        }), case let .call(frame, result) = call.operation else {
            return XCTFail("two integer-struct call arguments must be lifted")
        }
        XCTAssertEqual(frame.richArguments?.map(\.rowID.rawValue), ["source:h1", "source:h2"])
        XCTAssertEqual(frame.richArguments?.flatMap { $0.pieces.map(\.valueByteOffset) }, [0, 8, 0, 8])
        guard case .register(name: "w0", version: _)? = result else {
            return XCTFail("scalar result must use w0")
        }
        guard case .register(name: "w0", version: _)? = function.returnValue else {
            return XCTFail("authored int return must read the w0 result")
        }
        let text = PseudocodePrinter().print(function: function, types: types()).text
        XCTAssertTrue(text.contains("_compare(__abi_compose<IntegerPair>("), text)
        XCTAssertTrue(text.contains("h1.low64"), text)
        XCTAssertTrue(text.contains("h2.high64"), text)
        XCTAssertTrue(text.contains("return _compare("), text)
    }

    func testIntegerReturnWithUnwrittenHighCarrierAbstains() {
        let authored = FunctionSignatureOverride(returnType: "IntegerPair", args: [])
        let function = PseudocodePrinter().buildFunction(
            functionName: "incomplete", startAddress: base,
            signatureOverrides: [base: authored], types: types(),
            instructions: [row(0, "mov", "x0, #1"), row(4, "ret", "")]
        )
        guard case let .abiComposite(_, fragments)? = function.returnValue else {
            return XCTFail("integer return should preserve both carrier positions")
        }
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments[1], .unknown("unbound_return_fragment_8"))
    }

    func testFourByteIntegerStructUsesXCarrier() {
        let authored = FunctionSignatureOverride(
            returnType: "IntegerSmall",
            args: [ArgOverride(rowToken: "source:small", name: "small",
                               type: "IntegerSmall", provenance: .script)]
        )
        let function = PseudocodePrinter().buildFunction(
            functionName: "small", startAddress: base,
            signatureOverrides: [base: authored], types: types(),
            instructions: [row(0, "mov", "x0, x0"), row(4, "ret", "")]
        )
        XCTAssertEqual(function.parameterBindingAudit().records[0].location, "x0@0+4")
        let text = PseudocodePrinter().print(function: function, types: types()).text
        XCTAssertTrue(text.contains("small.value"), text)
        XCTAssertTrue(text.contains("__abi_compose<IntegerSmall>("), text)
        XCTAssertFalse(text.contains("unbound_return_fragment"), text)
    }

    /// DP01 #628: a double field carried in a GPR holds raw bits; it must not
    /// render as the bare floating field inside an integer expression.
    func testGPRCarriedDoubleFieldRendersAsRawFragment() {
        let mixed = FunctionSignatureOverride(
            returnType: "uint64_t",
            args: [ArgOverride(rowToken: "source:mixed", name: "mixed", type: "MixedPair", provenance: .script)]
        )
        let function = PseudocodePrinter().buildFunction(
            functionName: "mixed_bits", startAddress: base,
            signatureOverrides: [base: mixed], types: types(),
            instructions: [row(0, "and", "x0, x1, #0x1"), row(4, "add", "x2, x0, x0"), row(8, "ret", "")]
        )
        let text = PseudocodePrinter().print(function: function, types: types()).text
        XCTAssertFalse(text.contains("mixed.value &"), text)
        XCTAssertTrue(text.contains("__abi_fragment(mixed, 8, 8) & 0x1"), text)
        // The integer field in its GPR keeps its field name.
        let tag = PseudocodePrinter().buildFunction(
            functionName: "mixed_tag", startAddress: base,
            signatureOverrides: [base: mixed], types: types(),
            instructions: [row(0, "and", "x0, x0, #0x1"), row(4, "ret", "")]
        )
        XCTAssertTrue(PseudocodePrinter().print(function: tag, types: types()).text.contains("mixed.tag & 0x1"))
    }

    /// DP01 #597: an aggregate passed on the stack (after GPR exhaustion) must
    /// not bind as a scalar argument whose whole object feeds integer operations.
    func testStackPassedAggregateDoesNotBindAsScalar() {
        let registers = (0..<8).map { ArgOverride(rowToken: "source:a\($0)", name: "a\($0)", type: "uint64_t", provenance: .script) }
        func build(_ type: String) -> MacIRFunction {
            PseudocodePrinter().buildFunction(
                functionName: "stack_\(type)", startAddress: base,
                signatureOverrides: [base: FunctionSignatureOverride(returnType: "uint64_t",
                    args: registers + [ArgOverride(rowToken: "source:p", name: "p", type: type, provenance: .script)])],
                types: types(),
                instructions: [row(0, "ldr", "x0, [sp]"), row(4, "and", "x0, x0, #0x1"), row(8, "ret", "")]
            )
        }
        let aggregate = build("IntegerOne")
        let record = aggregate.parameterBindingAudit().records[8]
        XCTAssertNil(record.binding, "stack aggregate must abstain: \(record.location)")
        XCTAssertFalse(PseudocodePrinter().print(function: aggregate, types: types()).text.contains("p & 0x1"))
        // Control: a scalar ninth argument still binds on the entry stack.
        let scalar = build("uint64_t")
        XCTAssertEqual(scalar.parameterBindingAudit().records[8].binding, "entry-stack:0")
    }
}

extension D05RichABIIntegrationTests {
    /// D05 mixed int/float struct on the real MoltenVK witness
    /// `double mvkMTLClearDepthFromVkClearValue(VkClearDepthStencilValue)` (MoltenVK 1.4.2,
    /// 0x602b8; DP07 finding 4): the bit move of the low word is the `depth` field, then widened.
    func testMoltenVKDepthFieldReadsAsFieldThenWidens() {
        let rows: [(UInt64, String, String)] = [
            (0x602b8, "stp", "x22, x21, [sp, #-0x30]!"), (0x602bc, "stp", "x20, x19, [sp, #0x10]"),
            (0x602c0, "stp", "x29, x30, [sp, #0x20]"), (0x602c4, "add", "x29, sp, #0x20"),
            (0x602c8, "mov", "x19, x0"), (0x602cc, "adrp", "x21, 0x396000"),
            (0x602d0, "ldr", "x8, [x21, #0xd30]"), (0x602d4, "cbnz", "x8, 0x60304"),
            (0x602d8, "mov", "w0, #0x430"), (0x602dc, "bl", "0x2b1dcc"), (0x602e0, "mov", "x20, x0"),
            (0x602e4, "mov", "x1, #0x0"), (0x602e8, "bl", "0x701ec"), (0x602ec, "ldr", "x0, [x21, #0xd30]"),
            (0x602f0, "str", "x20, [x21, #0xd30]"), (0x602f4, "cbz", "x0, 0x60304"),
            (0x602f8, "ldr", "x8, [x0]"), (0x602fc, "ldr", "x8, [x8, #0x20]"), (0x60300, "blr", "x8"),
            (0x60304, "fmov", "s0, w19"), (0x60308, "fcvt", "d0, s0"),
            (0x6030c, "ldp", "x29, x30, [sp, #0x20]"), (0x60310, "ldp", "x20, x19, [sp, #0x10]"),
            (0x60314, "ldp", "x22, x21, [sp], #0x30"), (0x60318, "ret", ""),
        ]
        let signature = FunctionSignatureOverride(
            returnType: "double",
            args: [ArgOverride(rowToken: "source:clear", name: "clearValue", type: "DepthStencil", provenance: .script)]
        )
        let instructions = rows.map {
            InstructionRow(address: $0.0, bytes: "", mnemonic: $0.1, operands: $0.2, hasBreakpoint: false, comment: nil)
        }
        let text = PseudocodePrinter().print(
            functionName: "_mvkMTLClearDepthFromVkClearValue", startAddress: 0x602b8,
            signatureOverrides: [0x602b8: signature], types: types(), instructions: instructions
        ).text
        XCTAssertTrue(text.contains("double _mvkMTLClearDepthFromVkClearValue(DepthStencil clearValue)"), text)
        XCTAssertTrue(text.range(of: #"s0_\d+ = clearValue\.depth;"#, options: .regularExpression) != nil, text)
        XCTAssertTrue(text.range(of: #"d0_\d+ = \(double\)s0_\d+;"#, options: .regularExpression) != nil, text)
        XCTAssertFalse(text.contains("__fmov"), text)
    }
}
