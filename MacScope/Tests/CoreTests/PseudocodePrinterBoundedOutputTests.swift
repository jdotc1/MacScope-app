import XCTest

@testable import MacScope

final class PseudocodePrinterBoundedOutputTests: XCTestCase {
    func testSSARecoverySeparatesIndependentMemoryEffectsInMachineOrder() {
        let base = MacIRValue.register(name: "x9", version: 1)
        let next = MacIRValue.register(name: "x9", version: 2)
        let first = MacIRValue.register(name: "w10", version: 1)
        let second = MacIRValue.register(name: "w11", version: 1)
        let function = MacIRFunction(name: "memory", startAddress: 0x1000, instructions: [])
        let printer = PseudocodePrinter()
        let legacy = PseudocodeNameContext(function: function)
        var recovery = legacy
        recovery.ordinarySSAMemoryEffects = true
        let cases: [(MacIROperation, String, String)] = [
            (.intrinsic(destination: nil, name: "save_pair", arguments: [first, second, base]),
             "*(uint32_t *)(x9_1), *(uint32_t *)(x9_1 + 0x4) = w10_1, w11_1",
             "*(uint32_t *)(x9_1) = w10_1; *(uint32_t *)(x9_1 + 0x4) = w11_1"),
            (.intrinsic(destination: nil, name: "restore_pair", arguments: [first, second, base]),
             "w10_1, w11_1 = *(uint32_t *)(x9_1), *(uint32_t *)(x9_1 + 0x4)",
             "w10_1 = *(uint32_t *)(x9_1); w11_1 = *(uint32_t *)(x9_1 + 0x4)"),
            (.loadWriteback(destination: first, baseDestination: next, baseSource: base, delta: 8, preIndex: false),
             "w10_1, x9_2 = *(uint32_t *)(x9_1), x9_1 + 0x8",
             "w10_1 = *(uint32_t *)(x9_1); x9_2 = x9_1 + 0x8"),
            (.storeWriteback(source: first, baseDestination: next, baseSource: base, delta: 8, preIndex: true),
             "*(uint32_t *)(x9_1 + 0x8), x9_2 = w10_1, x9_1 + 0x8",
             "*(uint32_t *)(x9_1 + 0x8) = w10_1; x9_2 = x9_1 + 0x8"),
            (.intrinsic(destination: nil, name: "restore_pair_writeback",
                        arguments: [first, second, base, next, .immediate(8), .immediate(0)]),
             "w10_1, w11_1, x9_2 = *(uint32_t *)(x9_1), *(uint32_t *)(x9_1 + 0x4), x9_1 + 0x8",
             "w10_1 = *(uint32_t *)(x9_1); w11_1 = *(uint32_t *)(x9_1 + 0x4); x9_2 = x9_1 + 0x8"),
            (.intrinsic(destination: nil, name: "save_pair_writeback",
                        arguments: [first, second, base, next, .immediate(8), .immediate(1)]),
             "*(uint32_t *)(x9_1 + 0x8), *(uint32_t *)((x9_1 + 0x8) + 0x4), x9_2 = w10_1, w11_1, x9_1 + 0x8",
             "*(uint32_t *)(x9_1 + 0x8) = w10_1; *(uint32_t *)((x9_1 + 0x8) + 0x4) = w11_1; x9_2 = x9_1 + 0x8"),
        ]
        for (operation, frozen, ordinary) in cases {
            let instruction = MacIRInstruction(
                source: .init(address: 0x1000, byteText: "", mnemonic: "redacted", operands: ""),
                operation: operation, memoryAccess: .init(byteWidth: 4))
            XCTAssertEqual(printer.render(instruction: instruction, names: legacy), frozen)
            XCTAssertEqual(printer.render(instruction: instruction, names: recovery), ordinary)
        }
    }

    func testSSARecoveryPreservesFrameAndDependentMemoryTuples() {
        let base = MacIRValue.register(name: "x9", version: 1)
        let next = MacIRValue.register(name: "x9", version: 2)
        let first = MacIRValue.register(name: "w10", version: 1)
        let function = MacIRFunction(name: "memory", startAddress: 0x1000, instructions: [])
        let printer = PseudocodePrinter()
        let cases: [(MacIROperation, [String: String])] = [
            (.intrinsic(destination: nil, name: "save_pair",
                        arguments: [first, first, .register(name: "sp", version: 1)]), [:]),
            (.intrinsic(destination: nil, name: "restore_pair",
                        arguments: [base, first, base]), [:]),
            (.intrinsic(destination: nil, name: "restore_pair",
                        arguments: [first, first, base]), [:]),
            (.loadWriteback(destination: first, baseDestination: next, baseSource: base, delta: 8, preIndex: false),
             ["x9": "cursor"]),
            (.storeWriteback(source: next, baseDestination: next, baseSource: base, delta: 8, preIndex: false), [:]),
        ]
        for (operation, overrides) in cases {
            let instruction = MacIRInstruction(
                source: .init(address: 0x1000, byteText: "", mnemonic: "redacted", operands: ""),
                operation: operation, memoryAccess: .init(byteWidth: 4))
            let legacy = PseudocodeNameContext(function: function, registerNameOverrides: overrides)
            var recovery = legacy
            recovery.ordinarySSAMemoryEffects = true
            let frozen = printer.render(instruction: instruction, names: legacy)
            XCTAssertEqual(printer.render(instruction: instruction, names: recovery), frozen)
            XCTAssertFalse(frozen.contains(";"), frozen)
        }
    }

    func testTypedAccessAndExplicitReturnSurviveRedactedSource() {
        let source = MacIRSourceSpan(address: 0x1000, byteText: "", mnemonic: "redacted", operands: "")
        let value = MacIRValue.register(name: "w0", version: 1)
        let function = MacIRFunction(name: "typed", startAddress: 0x1000, instructions: [
            MacIRInstruction(source: source,
                             operation: .load(destination: value, address: .register(name: "x1", version: 0)),
                             memoryAccess: .init(byteWidth: 1, extensionKind: .zero)),
            MacIRInstruction(source: .init(address: 0x1004, byteText: "", mnemonic: "redacted", operands: ""),
                             operation: .returnValue(value), returnTarget: .register(name: "x19", version: 0)),
        ])
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("*(uint8_t *)(x1_0)"), text)
        XCTAssertTrue(text.contains("__a64_ret_to(x19_0, w0_1)"), text)
    }

    func testNaturalWidthLegacyRenderingRemainsEquivalent() {
        let instruction = MacIRInstruction(
            source: .init(address: 0x2000, byteText: "", mnemonic: "redacted", operands: ""),
            operation: .load(destination: .register(name: "x0", version: 1), address: .register(name: "x1", version: 0))
        )
        var typed = instruction
        typed.memoryAccess = .init(byteWidth: 8)
        let legacy = MacIRFunction(name: "legacy", startAddress: 0x2000, instructions: [instruction])
        var explicit = legacy
        explicit.instructions = [typed]
        XCTAssertEqual(PseudocodePrinter().print(function: explicit).text,
                       PseudocodePrinter().print(function: legacy).text)
    }

    func testExplicitReturnTargetPreventsCallReturnFolding() {
        let rows = [
            InstructionRow(address: 0x3000, bytes: "", mnemonic: "bl", operands: "_callee", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x3004, bytes: "", mnemonic: "ret", operands: "x19", hasBreakpoint: false, comment: nil),
        ]
        var function = PseudocodePrinter().buildFunction(functionName: "transfer", startAddress: 0x3000, instructions: rows)
        for index in function.instructions.indices {
            function.instructions[index].source.mnemonic = "redacted"
            function.instructions[index].source.operands = ""
        }
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("__a64_ret_to("), text)
    }

    func testTypedPairAddressAtSignedBoundaryRemainsSymbolic() {
        let instruction = MacIRInstruction(
            source: .init(address: 0x4000, byteText: "", mnemonic: "redacted", operands: ""),
            operation: .intrinsic(destination: nil, name: "restore_pair", arguments: [
                .register(name: "x0", version: 1), .register(name: "x1", version: 1), .stackSlot(offset: Int64.max),
            ]), memoryAccess: .init(byteWidth: 4, extensionKind: .sign)
        )
        let function = MacIRFunction(name: "boundary", startAddress: 0x4000, instructions: [instruction])
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("*(int32_t *)"), text)
        XCTAssertTrue(text.contains("+ 0x4"), text)
    }

    #if DEBUG
    func testTypedPayloadsSurviveCP6RecoveryTextValidation() throws {
        var function = CP2GraphFixture.function([[1, 2], [0, 3], [], []])
        function.instructions[0].operation = .load(
            destination: .register(name: "w5", version: 1), address: .register(name: "x6", version: 0)
        )
        function.instructions[0].memoryAccess = .init(byteWidth: 1, extensionKind: .zero)
        let descriptor = MacIRScalarFP(operation: .add, inputType: .binary32, resultType: .binary32)
        let index = try XCTUnwrap(function.instructions.indices.first {
            function.instructions[$0].source.comment == "visit_1"
        })
        function.instructions[index].operation = .intrinsic(
            destination: .register(name: "s0", version: 1), name: descriptor.intrinsicName,
            arguments: [.register(name: "s1", version: 0), .register(name: "s2", version: 0)]
        )
        function.instructions[index].scalarFP = descriptor
        var options = DecompilerOptions.recoveryOn
        options.recoveryMaxTransferRatioPercent = 400
        options.recoveryMaxAdditionalNesting = 16
        var printer = PseudocodePrinter(options: options)
        printer.bypassRecoveryReadabilityForTesting = true
        let capture = CP6RecoveryTextCheck.Capture()
        printer.recoveryTextCheckCapture = capture
        let document = printer.print(function: function)
        XCTAssertNil(document.structureFallback)
        XCTAssertTrue(try XCTUnwrap(capture.snapshot).isValid)
        XCTAssertTrue(document.text.contains("*(uint8_t *)(x6_0)"), document.text)
        XCTAssertTrue(document.text.contains("__a64_add_f32("), document.text)
    }
    #endif

    func testBoundedTextStopsEmissionBeforeRenderingTheTail() {
        let rows = (0..<10_000).map { index in
            InstructionRow(
                address: 0x1000 + UInt64(index * 4),
                bytes: "00 00 00 00",
                mnemonic: "unknown_\(index)",
                operands: "operand_\(index)",
                hasBreakpoint: false,
                comment: "marker_\(index)"
            )
        }

        let bounded = PseudocodePrinter().printBoundedText(
            functionName: "bounded_entry",
            startAddress: 0x1000,
            instructions: rows,
            maximumUTF8Bytes: 256
        )

        XCTAssertLessThanOrEqual(bounded.text.utf8.count, 256)
        XCTAssertTrue(bounded.wasTruncated)
        XCTAssertGreaterThan(bounded.emittedLineCount, 0)
        XCTAssertLessThan(bounded.emittedLineCount, rows.count)
        XCTAssertFalse(bounded.text.contains("marker_9999"))
        XCTAssertFalse(bounded.text.contains("�"))
    }

    func testScalarBoundaryAndUnlimitedPrinterRemainIndependent() {
        let rows = (0..<64).map { index in
            InstructionRow(
                address: 0x2000 + UInt64(index * 4),
                bytes: "00 00 00 00",
                mnemonic: "unknown_\(index)",
                operands: "operand_\(index)",
                hasBreakpoint: false,
                comment: String(repeating: "a", count: 32) + "é_\(index)"
            )
        }
        let printer = PseudocodePrinter()
        let bounded = printer.printBoundedText(
            functionName: "scalar_boundary",
            startAddress: 0x2000,
            instructions: rows,
            maximumUTF8Bytes: 257
        )
        let unlimited = printer.print(
            functionName: "scalar_boundary",
            startAddress: 0x2000,
            instructions: rows
        )

        XCTAssertLessThanOrEqual(bounded.text.utf8.count, 257)
        XCTAssertTrue(bounded.wasTruncated)
        XCTAssertFalse(bounded.text.contains("�"))
        XCTAssertGreaterThan(unlimited.lines.count, bounded.emittedLineCount)
        XCTAssertEqual(unlimited.lines.last?.text, "}")
    }
}
