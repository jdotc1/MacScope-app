import XCTest
@testable import MacScope

final class RejectedCFGJoinStateTests: XCTestCase {
    private func build(_ assembly: [(String, String)],
                       callerReturnWidth: MacIRCallerReturnEvidence.Width? = nil) -> MacIRFunction {
        let rows = assembly.enumerated().map { index, instruction in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 00 00",
                           mnemonic: instruction.0, operands: instruction.1,
                           hasBreakpoint: false, comment: nil)
        }
        XCTAssertNil(ScalarCFGStatePlan.admit(rows, hasExternalFacts: false),
                     "These shapes must exercise state handling outside scalar CFG admission")
        return MacIRBuilder().buildFunction(name: "join_state", callerReturnWidth: callerReturnWidth,
                                            instructions: rows)
    }

    private func operation(_ function: MacIRFunction, at index: Int) throws -> MacIROperation {
        try XCTUnwrap(function.instructions.first {
            $0.source.address == 0x1000 + UInt64(index * 4)
        }).operation
    }

    private func reads(_ operation: MacIROperation) -> [MacIRValue] {
        switch operation {
        case let .assign(_, source): return [source]
        case let .binary(_, _, left, right): return [left, right]
        case let .load(_, address): return [address]
        case let .store(source, address): return [source, address]
        case let .loadWriteback(_, _, base, _, _): return [base]
        case let .storeWriteback(source, _, base, _, _): return [source, base]
        case let .intrinsic(_, _, arguments): return arguments
        case let .conditionalBranch(_, left, right, _): return [left, right]
        case let .compareToBool(_, _, left, right): return [left, right]
        default: return []
        }
    }

    private func isUnavailableOrMerged(_ value: MacIRValue, in function: MacIRFunction) -> Bool {
        if case .unknown = value { return true }
        if function.phis.contains(where: {
            $0.destination == value && Set($0.incoming.map(\.value)).count > 1
        }) { return true }
        switch value {
        case let .unary(_, inner), let .bitTest(inner, _):
            return isUnavailableOrMerged(inner, in: function)
        case let .signedBitfield(field):
            return isUnavailableOrMerged(field.source, in: function)
        case let .binaryExpression(_, left, right):
            return isUnavailableOrMerged(left, in: function)
                || isUnavailableOrMerged(right, in: function)
        default: return false
        }
    }

    private func assertReconciled(_ function: MacIRFunction, at index: Int, operand: Int = 0,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let operands = reads(try operation(function, at: index))
        guard operands.indices.contains(operand) else {
            return XCTFail("Expected a modeled use at instruction \(index)", file: file, line: line)
        }
        XCTAssertTrue(isUnavailableOrMerged(operands[operand], in: function),
                      "A path-specific or initial value escaped: \(operands[operand])",
                      file: file, line: line)
    }

    func testListNextPointersDoNotRetainTheEntryIteration() throws {
        for pointer in ["x22", "x23"] {
            let function = build([
                ("mov", "\(pointer), x0"),
                ("ldr", "x9, [\(pointer)]"),
                ("str", "x9, [x19]"),
                ("ldr", "\(pointer), [\(pointer), #8]"),
                ("cbnz", "\(pointer), 0x1004"),
                ("ret", "")
            ])
            try assertReconciled(function, at: 1)
            try assertReconciled(function, at: 3)
        }
    }

    func testSavedNextPointerAcrossCallFeedsBothListLoopShapes() throws {
        for saved in ["x22", "x23"] {
            let function = build([
                ("mov", "x1, x0"),
                ("ldr", "\(saved), [x1]"),
                ("mov", "x0, x1"),
                ("bl", "0x9000"),
                ("mov", "x1, \(saved)"),
                ("cbnz", "x1, 0x1004"),
                ("ret", "")
            ])
            try assertReconciled(function, at: 1)
            try assertReconciled(function, at: 2)
            guard case let .load(savedValue, _) = try operation(function, at: 1),
                  case let .assign(_, restored) = try operation(function, at: 4) else {
                return XCTFail("The saved next pointer must remain modeled across the call")
            }
            XCTAssertEqual(restored, savedValue)
        }
    }

    func testCounterAndMixedWidthAccumulatorsAreReconciledAtLoopHeader() throws {
        let function = build([
            ("mov", "x8, #0"),
            ("mov", "w13, #1"),
            ("mov", "w14, #2"),
            ("str", "x8, [x19]"),
            ("str", "x13, [x20]"),
            ("str", "x14, [x21]"),
            ("add", "x8, x8, #1"),
            ("add", "x13, x13, x11"),
            ("add", "x14, x14, x12"),
            ("cmp", "x8, #256"),
            ("b.ne", "0x100c"),
            ("ret", "")
        ])
        for index in [3, 4, 5, 6, 7, 8] {
            try assertReconciled(function, at: index)
        }
    }

    func testPostIndexLoadStorePointersAndCountersAreReconciled() throws {
        let function = build([
            ("mov", "x8, x0"),
            ("mov", "x9, x1"),
            ("mov", "w27, #0"),
            ("mov", "w26, #0"),
            ("str", "w27, [x8], #4"),
            ("add", "w27, w27, #1"),
            ("ldr", "w10, [x9], #4"),
            ("add", "w26, w26, #1"),
            ("cmp", "w26, #16"),
            ("b.ne", "0x1010"),
            ("ret", "")
        ])
        try assertReconciled(function, at: 4)
        try assertReconciled(function, at: 4, operand: 1)
        try assertReconciled(function, at: 5)
        try assertReconciled(function, at: 6)
        try assertReconciled(function, at: 7)
    }

    func testPostIndexStoreAndDecrementDoNotRetainInitialValues() throws {
        let function = build([
            ("mov", "x16, x0"),
            ("mov", "x17, #16"),
            ("str", "w2, [x16], #4"),
            ("subs", "w17, w17, #1"),
            ("b.ne", "0x1008"),
            ("ret", "")
        ])
        try assertReconciled(function, at: 2, operand: 1)
        try assertReconciled(function, at: 3)
    }

    func testBypassedScalarFloatAssignmentIsNotDefiniteAtJoin() throws {
        let function = build([
            ("fmov", "s4, #1.0"),
            ("cbz", "x0, 0x100c"),
            ("fmov", "s4, #2.0"),
            ("fmov", "w0, s4"),
            ("ret", "")
        ])
        try assertReconciled(function, at: 3)
        let text = PseudocodePrinter().print(function: function).text
        if function.phis.isEmpty {
            XCTAssertTrue(text.contains("unavailable"), text)
            XCTAssertFalse(text.contains("fmov(s4_2)"), text)
        }
    }

    func testBypassedIntegerDefinitionIsNotDefiniteInTestAndSet() throws {
        for register in ["w22", "w23", "w24"] {
            let function = build([
                ("mov", "\(register), #1"),
                ("cbz", "x0, 0x100c"),
                ("mov", "\(register), #2"),
                ("tst", "\(register), #1"),
                ("cset", "w0, ne"),
                ("ret", "")
            ])
            try assertReconciled(function, at: 3)
            let text = PseudocodePrinter().print(function: function).text
            if function.phis.isEmpty { XCTAssertTrue(text.contains("unavailable"), text) }
        }
    }

    func testSiblingEntryCannotReadDefinitionFromOtherArm() throws {
        let function = build([
            ("cbz", "x0, 0x1010"),
            ("mov", "x19, #7"),
            ("str", "x19, [x1]"),
            ("b", "0x1018"),
            ("str", "x19, [x2]"),
            ("nop", ""),
            ("ret", "")
        ])
        let sibling = reads(try operation(function, at: 4))
        let firstArm = reads(try operation(function, at: 2))
        XCTAssertNotEqual(sibling.first, firstArm.first,
                          "A sibling entry must not inherit the preceding textual arm")
    }

    func testCommonDominatingValueSurvivesRejectedJoin() throws {
        let function = build([
            ("mov", "x19, #7"),
            ("cbz", "x0, 0x1010"),
            ("str", "x1, [x2]"),
            ("b", "0x1014"),
            ("str", "x3, [x2]"),
            ("str", "x19, [x2]"),
            ("ret", "")
        ])
        guard case let .assign(dominating, _) = try operation(function, at: 0),
              case let .store(used, _) = try operation(function, at: 5) else {
            return XCTFail("The dominating assignment and joined store must remain modeled")
        }
        XCTAssertEqual(used, dominating)
    }

    func testFreshDefinitionAfterJoinRemainsAvailable() throws {
        let function = build([
            ("cbz", "x0, 0x100c"),
            ("mov", "x19, #1"),
            ("b", "0x1010"),
            ("mov", "x19, #2"),
            ("mov", "x19, #3"),
            ("str", "x19, [x1]"),
            ("ret", "")
        ])
        guard case let .assign(fresh, _) = try operation(function, at: 4),
              case let .store(used, _) = try operation(function, at: 5) else {
            return XCTFail("The new dominating write must restore a definite value")
        }
        XCTAssertEqual(used, fresh)
    }

    func testDifferentFlagProducersCannotResolveJoinedConditionFromOneArm() throws {
        let function = build([
            ("cbz", "x0, 0x100c"),
            ("cmp", "x1, #1"),
            ("b", "0x1010"),
            ("cmp", "x2, #2"),
            ("cset", "w0, eq"),
            ("ret", "")
        ])
        switch try operation(function, at: 4) {
        case .unknown: break
        case let .compareToBool(_, _, left, right):
            XCTAssertTrue(isUnavailableOrMerged(left, in: function)
                          || isUnavailableOrMerged(right, in: function))
        default: XCTFail("Joined flags must be merged or explicitly unresolved")
        }
    }

    func testBypassedStackArgumentLoadCannotSurviveInCachedReturn() throws {
        for register in ["x0", "d0"] {
            let function = build([
                ("cbz", "x1, 0x1008"),
                ("ldr", "\(register), [sp, #16]"),
                ("ret", "")
            ])
            guard case let .returnValue(value) = try operation(function, at: 2),
                  let value else { return XCTFail("A bypassed result is unavailable, not proof of void") }
            XCTAssertTrue(isUnavailableOrMerged(value, in: function))
        }
    }

    func testFlagsModifiedOnSiblingPathAreUnavailableAtJoin() throws {
        for modifier in [("rmif", "x2, #1, #1"), ("setf8", "w2"),
                         ("setf16", "w2"), ("cfinv", ""), ("axflag", ""),
                         ("xaflag", ""), ("msr", "nzcv, x2")] {
            let function = build([
                ("cmp", "x1, #1"),
                ("cbz", "x0, 0x100c"),
                modifier,
                ("cset", "w0, eq"),
                ("ret", "")
            ])
            switch try operation(function, at: 3) {
            case .unknown: break
            case let .compareToBool(_, _, left, right):
                XCTAssertTrue(isUnavailableOrMerged(left, in: function)
                              || isUnavailableOrMerged(right, in: function))
            default: XCTFail("One path's predicate must not represent modified flags")
            }
        }
    }

    func testKnownCallKeepsUnavailableJoinedArgumentAndLaterSourcePositions() throws {
        let function = build([
            ("mov", "x1, x3"),
            ("cbz", "x4, 0x100c"),
            ("mov", "x1, x5"),
            ("mov", "x0, x6"),
            ("mov", "x2, #64"),
            ("bl", "_memcpy"),
            ("ret", "")
        ])
        guard case let .call(frame, _) = try operation(function, at: 5) else {
            return XCTFail("The known call must retain its frame")
        }
        let joined = try XCTUnwrap(frame.arguments.fixedArgument(at: 1))
        XCTAssertEqual(joined.location, .gpr(index: 1, carrierWidth: 64))
        if SSAPropertyAssertions.enabled {
            if let phi = SSAPropertyAssertions.phi(function, block: 0x100c, cell: 1, width: 64,
                incoming: [(0x1004, 0x1000), (0x1008, 0x1008)]) {
                SSAPropertyAssertions.assertView(joined.value, of: phi, width: 64)
            }
        } else {
            XCTAssertEqual(joined.value, .unknown("unavailable_x1"))
        }
        XCTAssertNotNil(frame.arguments.fixedArgument(at: 0))
        XCTAssertNotNil(frame.arguments.fixedArgument(at: 2))
        XCTAssertEqual(frame.arguments.denseFixedPrefixValues().count, 3)
    }

    func testUnknownPoolCallsKeepUnavailableObjectAndKnownSize() throws {
        for target in ["_jpeg_free_large", "_jpeg_free_small"] {
            let function = build([
                ("bl", "_arc4random_stir"),
                ("mov", "x1, x19"),
                ("ldr", "x23, [x1]"),
                ("mov", "x0, x20"),
                ("mov", "x2, #64"),
                ("bl", target),
                ("mov", "x1, x23"),
                ("cbnz", "x1, 0x1008"),
                ("ret", "")
            ])
            guard case let .call(frame, _) = try operation(function, at: 5),
                  case let .assign(size, _) = try operation(function, at: 4) else {
                return XCTFail("The call and size definition must remain modeled")
            }
            let arguments = try XCTUnwrap(frame.arguments.denseUnknownGPRPrefixValues())
            XCTAssertEqual(arguments.count, 3)
            if SSAPropertyAssertions.enabled {
                if let phi = SSAPropertyAssertions.phi(function, block: 0x1008, cell: 1, width: 64,
                    incoming: [(0x1004, 0x1004), (0x101c, 0x1018)]) {
                    SSAPropertyAssertions.assertView(arguments.dropFirst().first, of: phi, width: 64)
                }
            } else {
                XCTAssertEqual(arguments.dropFirst().first, .unknown("unavailable_x1"))
            }
            XCTAssertEqual(arguments.last, size)
        }
    }

    func testReturningCallClearsJoinedArgumentSlotEvidence() throws {
        let function = build([
            ("mov", "x1, x3"),
            ("cbz", "x4, 0x100c"),
            ("mov", "x1, x5"),
            ("bl", "_arc4random_stir"),
            ("mov", "x0, #1"),
            ("mov", "x2, #2"),
            ("bl", "_opaque"),
            ("ret", "")
        ])
        guard case let .call(frame, _) = try operation(function, at: 6) else {
            return XCTFail("The subsequent call must remain modeled")
        }
        XCTAssertNil(frame.arguments.argument(at: .gpr(index: 1)))
        XCTAssertNotNil(frame.arguments.argument(at: .gpr(index: 2)))
        let arguments = try XCTUnwrap(frame.arguments.denseUnknownGPRPrefixValues())
        XCTAssertEqual(arguments.count, 1)
    }

    func testOpaqueExitCannotPassLexicalDefinitionIntoUnenumeratedBlock() throws {
        let function = build([
            ("mov", "x19, #7"),
            ("br", "x9"),
            ("str", "x19, [x0]"),
            ("ret", "")
        ])
        try assertReconciled(function, at: 2)
    }

    func testProvenBooleanContractKeepsJoinedValueUnavailable() throws {
        let function = build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #1"), ("b", "0x1010"),
            ("mov", "w0, wzr"), ("ret", "")
        ])
        guard case let .returnValue(value) = try operation(function, at: 4) else {
            return XCTFail("The joined return must remain modeled")
        }
        if SSAPropertyAssertions.enabled {
            if let phi = SSAPropertyAssertions.phi(function, block: 0x1010, cell: 0, width: 32,
                incoming: [(0x1008, 0x1004), (0x100c, 0x100c)]) {
                SSAPropertyAssertions.assertView(value, of: phi, width: 32)
                SSAPropertyAssertions.assertView(function.returnValue, of: phi, width: 32)
            }
        } else {
            XCTAssertEqual(value, .unknown("unavailable_join_result"))
        }
    }

    func testUnprovenContractKeepsJoinedReturnContractUnresolved() throws {
        let function = build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #7"), ("b", "0x1010"),
            ("mov", "w0, wzr"), ("ret", "")
        ])
        guard case let .returnValue(value) = try operation(function, at: 4) else {
            return XCTFail("The unresolved return must remain modeled")
        }
        XCTAssertEqual(value, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

    func testCallerWidthKeepsJoinedValueUnavailableWithoutProducerProof() throws {
        let function = build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #7"), ("b", "0x1010"),
            ("mov", "w0, wzr"), ("ret", "")
        ], callerReturnWidth: .w0)
        guard case let .returnValue(value) = try operation(function, at: 4) else {
            return XCTFail("The caller-authorized return must remain modeled")
        }
        if SSAPropertyAssertions.enabled {
            if let phi = SSAPropertyAssertions.phi(function, block: 0x1010, cell: 0, width: 32,
                incoming: [(0x1008, 0x1004), (0x100c, 0x100c)]) {
                SSAPropertyAssertions.assertView(value, of: phi, width: 32)
                SSAPropertyAssertions.assertView(function.returnValue, of: phi, width: 32)
            }
        } else {
            XCTAssertEqual(value, .unknown("unavailable_join_result"))
        }
    }
}

final class RejectedCFGProducerRestoreTests: XCTestCase {
    private func rows(_ assembly: [(String, String)]) -> [InstructionRow] {
        assembly.enumerated().map { index, instruction in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 00 00",
                           mnemonic: instruction.0, operands: instruction.1,
                           hasBreakpoint: false, comment: nil)
        }
    }

    private func build(_ assembly: [(String, String)]) -> MacIRFunction {
        let instructions = rows(assembly)
        XCTAssertNil(ScalarCFGStatePlan.admit(instructions, hasExternalFacts: false))
        return MacIRBuilder(ssaEnabled: false).buildFunction(name: "preserved_producer", instructions: instructions)
    }

    private func operation(_ function: MacIRFunction, _ index: Int) throws -> MacIROperation {
        try XCTUnwrap(function.instructions.first {
            $0.source.address == 0x1000 + UInt64(index * 4)
        }).operation
    }

    private func destination(_ function: MacIRFunction, _ index: Int) throws -> MacIRValue {
        switch try operation(function, index) {
        case let .assign(value, _), let .binary(value, _, _, _), let .load(value, _): return value
        default: throw NSError(domain: "Expected producer", code: index)
        }
    }

    private func stored(_ function: MacIRFunction, _ index: Int) throws -> MacIRValue {
        guard case let .store(value, _) = try operation(function, index) else {
            throw NSError(domain: "Expected store", code: index)
        }
        return value
    }

    private func widened(_ value: MacIRValue) -> MacIRValue {
        .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: value))
    }

    func testBranchPastPairEpilogueRestoresBothProducers() throws {
        let function = build([
            ("mov", "x19, x0"), ("mov", "x20, x1"), ("cbz", "x2, 0x1014"),
            ("ldp", "x19, x20, [sp, #16]"), ("ret", ""),
            ("str", "x19, [x3]"), ("str", "x20, [x3, #8]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 5), try destination(function, 0))
        XCTAssertEqual(try stored(function, 6), try destination(function, 1))
    }

    func testBranchPastWideWriteRestoresZeroExtendedNarrowProducer() throws {
        let function = build([
            ("mov", "w25, w0"), ("cbz", "x1, 0x1010"),
            ("mov", "x25, x2"), ("ret", ""), ("str", "x25, [x3]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 4), widened(try destination(function, 0)))
    }

    func testArithmeticProducerSurvivesSiblingWrites() throws {
        let function = build([
            ("add", "x21, x8, x9"), ("cbz", "x0, 0x1014"),
            ("mov", "x21, x10"), ("add", "x21, x21, #8"), ("ret", ""),
            ("str", "x21, [x1]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 5), try destination(function, 0))
    }

    func testSkippedSiblingTombstoneRecoversBothWidths() throws {
        let function = build([
            ("cbz", "x0, 0x100c"), ("mov", "w25, w1"), ("b", "0x1014"),
            ("str", "x25, [x2]"), ("b", "0x101c"),
            ("str", "w25, [x3]"), ("str", "x25, [x3, #8]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 3), .unknown("unavailable_x25"))
        XCTAssertEqual(try stored(function, 5), try destination(function, 1))
        XCTAssertEqual(try stored(function, 6), widened(try destination(function, 1)))
    }

    func testSkippedLoopJoinRecoversDominatingProducer() throws {
        let function = build([
            ("mov", "x22, x0"), ("cbz", "x4, 0x100c"), ("b", "0x1014"),
            ("str", "x22, [x1]"), ("b", "0x1020"),
            ("str", "x22, [x2]"), ("add", "x22, x22, #8"),
            ("cbnz", "x3, 0x100c"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 3), .unknown("unavailable_x22"))
        XCTAssertEqual(try stored(function, 5), try destination(function, 0))
    }

    func testIncomingAliasWriteRemainsUnknown() throws {
        for register in ["w25", "x25"] {
            let function = build([
                ("mov", "x25, x0"), ("cbz", "x1, 0x100c"),
                ("mov", "\(register), #7"), ("str", "x25, [x2]"), ("ret", "")
            ])
            XCTAssertEqual(try stored(function, 3), .unknown("unavailable_x25"))
        }
    }

    func testBypassedProducerRemainsUnknown() throws {
        let function = build([
            ("cbz", "x0, 0x1008"), ("mov", "x25, #7"),
            ("str", "x25, [x1]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 2), .unknown("unavailable_x25"))
    }

    func testConflictingArmProducersRemainUnknown() throws {
        let function = build([
            ("cbz", "x0, 0x100c"), ("mov", "x25, #7"), ("b", "0x1010"),
            ("mov", "x25, #9"), ("str", "x25, [x1]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 4), .unknown("unavailable_x25"))
    }

    func testOpaqueIngressPreventsRestorationAtEnumeratedEntry() throws {
        let function = build([
            ("mov", "x25, x0"), ("cbz", "x1, 0x1010"),
            ("mov", "x25, x2"), ("br", "x9"), ("str", "x25, [x3]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 4), .unknown("unavailable_x25"))
    }

    func testDirectCallOnReachingPathPreventsRestoration() throws {
        try assertCallPreventsRestoration("bl", "_arc4random_stir")
    }

    func testIndirectCallOnReachingPathPreventsRestoration() throws {
        try assertCallPreventsRestoration("blr", "x9")
    }

    private func assertCallPreventsRestoration(_ mnemonic: String, _ operand: String) throws {
        let function = build([
            ("mov", "x25, x0"), (mnemonic, operand), ("cbz", "x1, 0x1014"),
            ("mov", "x25, x2"), ("ret", ""), ("str", "x25, [x3]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 5), .unknown("unavailable_x25"))
    }

    func testBypassArmEnteringUsePreventsTombstoneRepair() throws {
        let function = build([
            ("cbz", "x0, 0x100c"), ("mov", "w25, w1"), ("b", "0x1014"),
            ("str", "x25, [x2]"), ("b", "0x1014"),
            ("str", "x25, [x3]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 5), .unknown("unavailable_x25"))
    }

    func testUnmodeledReachingEffectPreventsRestoration() throws {
        let function = build([
            ("mov", "x25, x0"), ("opaque_effect", ""), ("cbz", "x1, 0x1014"),
            ("mov", "x25, x2"), ("ret", ""), ("str", "x25, [x3]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 5), .unknown("unavailable_x25"))
    }

    func testOpaquePathCannotRetainSiblingRestoration() throws {
        let function = build([
            ("cbz", "x0, 0x100c"), ("mov", "w25, w1"), ("b", "0x101c"),
            ("mov", "w25, w2"), ("opaque_effect", ""), ("cbz", "x4, 0x1024"),
            ("b", "0x1024"), ("str", "w25, [x5]"), ("ret", ""),
            ("str", "w25, [x5]"), ("str", "x25, [x5, #8]"), ("ret", "")
        ])
        XCTAssertEqual(try stored(function, 7), try destination(function, 1))
        XCTAssertEqual(try stored(function, 9), .unknown("unavailable_w25"))
        XCTAssertEqual(try stored(function, 10), .unknown("unavailable_x25"))
    }

    private func snapshotRows() -> [InstructionRow] {
        rows([("mov", "w25, w0"), ("b", "0x1010"),
              ("mov", "x25, x1"), ("ret", ""), ("str", "x25, [x2]"), ("ret", "")])
    }

    func testMissingAndUnsupportedSnapshotsStayUnknown() {
        for width in [nil, 16] as [Int?] {
            var plan = RejectedCFGStatePlan(rows: snapshotRows(), jumpTables: [:])
            var state = BuilderState()
            let producer = state.writeRegister("w25")
            if let width {
                state.currentIntegerDefinitionByIndex[25]?.width = width
                plan.capture(at: 0, operation: .assign(destination: producer, source: .immediate(7)), state: state)
            }
            plan.capture(at: 1, operation: .intrinsic(destination: nil, name: "branch", arguments: []), state: state)
            state.writeRegister("x25")
            XCTAssertTrue(plan.reconcile(at: 4, state: &state))
            XCTAssertEqual(state.readRegister("x25"), .unknown("unavailable_x25"))
        }
    }

    func testRestorationPreservesUncertaintyAndAllocationWithoutRestoringFacts() {
        var plan = RejectedCFGStatePlan(rows: snapshotRows(), jumpTables: [:])
        var state = BuilderState()
        let producer = MacIRValue.unknown("upstream_value")
        state.currentIntegerDefinitionByIndex[25] = IntegerRegisterDefinition(value: producer, width: 32)
        state.stackSlotValues[16] = StackSlotValueFact(value: .immediate(7), byteWidth: 8, carrierKind: .integer)
        plan.capture(at: 0, operation: .assign(destination: producer, source: .immediate(7)), state: state)
        plan.capture(at: 1, operation: .intrinsic(destination: nil, name: "branch", arguments: []), state: state)
        state.invalidateAllStackSlotValues()
        state.registerVersions["w25"] = 7
        state.registerVersionFloor = 12
        state.writeRegister("x25")
        let versions = state.registerVersions
        state.materializedImmediateByRegister["x25"] = 99
        state.stackBaseOffsets["x25"] = 32
        XCTAssertTrue(plan.reconcile(at: 4, state: &state))
        XCTAssertEqual(state.readRegister("w25"), producer)
        XCTAssertEqual(state.readRegister("x25"), widened(producer))
        XCTAssertEqual(state.registerVersions, versions)
        XCTAssertEqual(state.registerVersionFloor, 12)
        XCTAssertTrue(state.stackSlotValues.isEmpty)
        XCTAssertNil(state.materializedImmediateByRegister["x25"])
        XCTAssertNil(state.stackBaseOffsets["x25"])
        XCTAssertEqual(state.writeRegister("x25"), .register(name: "x25", version: 14))
    }
}
