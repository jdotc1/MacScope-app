import XCTest
@testable import MacScope

final class MacIRScalarCFGStateTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "") -> InstructionRow {
        InstructionRow(address: address, bytes: "00 00 00 00", mnemonic: mnemonic,
                       operands: operands, hasBreakpoint: false, comment: nil)
    }

    func testDiamondJoinSelectsTheTakenPredecessorValue() {
        let rows = [
            row(0x1000, "cbz", "x0, 0x100c"),
            row(0x1004, "mov", "x1, #1"),
            row(0x1008, "b", "0x1010"),
            row(0x100c, "mov", "x1, #2"),
            row(0x1010, "mov", "x0, x1"),
            row(0x1014, "ret")
        ]
        let plan = ScalarCFGStatePlan.admit(rows, hasExternalFacts: false)
        XCTAssertNotNil(plan)
        let function = MacIRBuilder().buildFunction(name: "diamond", instructions: rows)
        if SSAPropertyAssertions.enabled {
            guard let phi = SSAPropertyAssertions.phi(function, block: 0x1010, cell: 1, width: 64,
                incoming: [(0x1008, 0x1004), (0x100c, 0x100c)]),
                  case let .assign(_, source) = function.instructions[4].operation else {
                return XCTFail("join move must read the predecessor phi")
            }
            SSAPropertyAssertions.assertView(source, of: phi, width: 64)
            SSAPropertyAssertions.assertOrdinaryUsesDominated(function)
        } else {
            guard case let .select(_, condition, left, right, trueValue, falseValue) = function.instructions[4].operation else {
                return XCTFail("join move must lift as a predecessor select")
            }
            XCTAssertEqual(condition, "==")
            XCTAssertEqual(left, .argument(bindingID: .gpr(0)))
            XCTAssertEqual(right, .immediate(0))
            XCTAssertNotEqual(trueValue, falseValue)
            guard case .register(name: "x1", _) = trueValue,
                  case .register(name: "x1", _) = falseValue else {
                return XCTFail("select must use the two distinct branch definitions")
            }
        }
        guard case let .returnValue(returned) = function.instructions[5].operation else {
            return XCTFail("final instruction must return")
        }
        XCTAssertEqual(returned, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        XCTAssertEqual(function.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        let structured = PseudocodePrinter().print(function: function)
        let raw = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: false, deadCodeElimination: false,
            nopElision: false, functionSizeGate: 1024)).print(function: function)
        let structuredJoin = structured.lines(sourcedAt: 0x1010).map(\.text)
        let rawJoin = raw.lines(sourcedAt: 0x1010).map(\.text)
        XCTAssertEqual(structuredJoin.count, 1)
        XCTAssertEqual(rawJoin.count, 1)
        XCTAssertEqual(structuredJoin.first?.trimmingCharacters(in: .whitespaces),
                       rawJoin.first?.trimmingCharacters(in: .whitespaces))
        // The visible-join shortcut requires returning the selected value.
        // A refused return keeps the original branch definitions and select.
        if SSAPropertyAssertions.enabled {
            var identities = SSAAlphaEquivalence(expected: MacIRBuilder(ssaEnabled: false).buildFunction(
                name: "diamond", instructions: rows), actual: function)
            identities.assertEquivalent(structured.lines(sourcedAt: 0x1004).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }, ["x1_8 = 0x1;"])
            identities.assertEquivalent(structured.lines(sourcedAt: 0x100c).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }, ["x1_15 = 0x2;"])
        } else {
            XCTAssertEqual(structured.lines(sourcedAt: 0x1004).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }, ["x1_8 = 0x1;"])
            XCTAssertEqual(structured.lines(sourcedAt: 0x100c).map {
                $0.text.trimmingCharacters(in: .whitespaces)
            }, ["x1_15 = 0x2;"])
        }
        XCTAssertTrue(structured.text.contains("return unresolved_return_contract;"), structured.text)
    }

    func testAgreedPredecessorsPreserveValueAtJoin() {
        let rows = [
            row(0x2000, "mov", "x1, #7"),
            row(0x2004, "cbz", "x0, 0x2010"),
            row(0x2008, "nop"),
            row(0x200c, "b", "0x2014"),
            row(0x2010, "nop"),
            row(0x2014, "mov", "x0, x1"),
            row(0x2018, "ret")
        ]
        XCTAssertNotNil(ScalarCFGStatePlan.admit(rows, hasExternalFacts: false))
        let function = MacIRBuilder().buildFunction(name: "same", instructions: rows)
        guard case let .assign(_, source) = function.instructions[5].operation else {
            return XCTFail("join move must lift as an assignment")
        }
        guard case .register(name: "x1", _) = source else {
            return XCTFail("agreed predecessor value must remain the entry x1 definition")
        }
    }

    func testBypassIntoOneArmUsesTypedPhiInsteadOfUnjustifiedSelect() {
        let rows = [
            row(0x1000, "cbz", "x2, 0x1008"),
            row(0x1004, "cbz", "x0, 0x1010"),
            row(0x1008, "mov", "x1, #1"),
            row(0x100c, "b", "0x1014"),
            row(0x1010, "mov", "x1, #2"),
            row(0x1014, "mov", "x0, x1"),
            row(0x1018, "ret")
        ]
        XCTAssertNotNil(ScalarCFGStatePlan.admit(rows, hasExternalFacts: false))
        let function = MacIRBuilder().buildFunction(name: "bypassed_fork", instructions: rows)
        guard case let .assign(_, source) = function.instructions[5].operation else {
            return XCTFail("bypassed fork cannot justify a select")
        }
        XCTAssertEqual(function.phis.count, 1)
        XCTAssertEqual(function.phis[0].destination, source)
        XCTAssertEqual(function.phis[0].incoming.count, 2)
        XCTAssertEqual(function.phis[0].bitWidth, 64)
    }

    func testDivergentReturnRegisterPhiNeedsReturnContract() {
        let rows = [
            row(0x2800, "cbz", "x1, 0x280c"),
            row(0x2804, "mov", "x0, #1"),
            row(0x2808, "b", "0x2810"),
            row(0x280c, "mov", "x0, #2"),
            row(0x2810, "ret")
        ]
        XCTAssertNotNil(ScalarCFGStatePlan.admit(rows, hasExternalFacts: false))
        let function = MacIRBuilder().buildFunction(name: "return_join", instructions: rows)
        guard case let .returnValue(returned) = function.instructions[4].operation else {
            return XCTFail("final instruction must return")
        }
        if SSAPropertyAssertions.enabled {
            _ = SSAPropertyAssertions.phi(function, block: 0x2810, cell: 0, width: 64,
                incoming: [(0x2808, 0x2804), (0x280c, 0x280c)])
        } else {
            // Once its sole return use is unresolved, the join is no longer live.
            XCTAssertTrue(function.phis.isEmpty)
        }
        // Both incoming writes establish data flow, not a result contract.
        XCTAssertEqual(returned,
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
        XCTAssertEqual(function.returnValue,
                       .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker))
    }

    func testUnresolvedTargetAndBackEdgeRefuseBoundedRoute() {
        let unresolved = [
            row(0x3000, "cbz", "x0, 0x3020"),
            row(0x3004, "mov", "x1, #1"),
            row(0x3008, "mov", "x0, x1"),
            row(0x300c, "ret")
        ]
        XCTAssertNil(ScalarCFGStatePlan.admit(unresolved, hasExternalFacts: false))
        let loop = [
            row(0x4000, "mov", "x1, #0"),
            row(0x4004, "cbz", "x0, 0x4010"),
            row(0x4008, "b", "0x4004"),
            row(0x400c, "nop"),
            row(0x4010, "ret")
        ]
        XCTAssertNil(ScalarCFGStatePlan.admit(loop, hasExternalFacts: false))
    }

    func testLoopAdmissionRefusesBypassedFlagsAndEntryBackedge() {
        let bypassedFlags = [
            row(0x5000, "cbz", "x0, 0x5008"),
            row(0x5004, "subs", "x1, x1, #1"),
            row(0x5008, "b.ne", "0x5004"),
            row(0x500c, "ret")
        ]
        XCTAssertNil(ScalarCFGStatePlan.admit(bypassedFlags, hasExternalFacts: false))

        let entryBackedge = [
            row(0x6000, "add", "x0, x0, #1"),
            row(0x6004, "subs", "x1, x1, #1"),
            row(0x6008, "b.ne", "0x6000"),
            row(0x600c, "ret")
        ]
        XCTAssertNil(ScalarCFGStatePlan.admit(entryBackedge, hasExternalFacts: false))
    }

    func testPhiPrinterRefusesUnhandledConditionalTerminator() {
        func instruction(_ address: UInt64, _ mnemonic: String,
                         _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address,
                byteText: "00 00 00 00", mnemonic: mnemonic, operands: "", comment: nil),
                operation: operation)
        }
        let phiValue = MacIRValue.register(name: "x0", version: 9)
        let function = MacIRFunction(name: "unresolved_flags", startAddress: 0x7000,
            instructions: [
                instruction(0x7000, "b.ne", .intrinsic(destination: nil,
                    name: "branch_ne", arguments: [.immediate(0x7008)])),
                instruction(0x7004, "mov", .assign(destination: .register(name: "x0", version: 1),
                    source: .immediate(1))),
                instruction(0x7008, "ret", .returnValue(phiValue))
            ], phis: [MacIRPhi(blockAddress: 0x7008, destination: phiValue, bitWidth: 64,
                incoming: [
                    .init(predecessorAddress: 0x7000, value: .immediate(2)),
                    .init(predecessorAddress: 0x7004, value: .immediate(1))
                ])])
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("__unavailable_cfg_phi();"), text)
        XCTAssertFalse(text.contains("goto L_7008"), text)
    }

    func testUnknownClobberRemainsAnEffectBarrier() {
        let rows = [
            row(0x8000, "cbz", "x0, 0x800c"),
            row(0x8004, "ldaxr", "x1, [x2]"),
            row(0x8008, "b", "0x8010"),
            row(0x800c, "mov", "x1, #2"),
            row(0x8010, "mov", "x0, x1"),
            row(0x8014, "ret")
        ]
        XCTAssertNil(ScalarCFGStatePlan.admit(rows, hasExternalFacts: false))
        let function = MacIRBuilder().buildFunction(name: "unknown_clobber", instructions: rows)
        guard case .unknown = function.instructions[1].operation else {
            return XCTFail("unknown atomic read must remain an effect barrier")
        }
        if SSAPropertyAssertions.enabled {
            guard let phi = SSAPropertyAssertions.phi(function, block: 0x8010, cell: 1, width: 64,
                incoming: [(0x8008, 0x8004), (0x800c, 0x800c)], refusalProducers: [0x8004]),
                  case let .assign(_, source) = function.instructions[4].operation else {
                return XCTFail("the refused predecessor must remain in the joined value")
            }
            SSAPropertyAssertions.assertView(source, of: phi, width: 64)
            XCTAssertNotEqual(source, .immediate(2))
        } else {
            XCTAssertTrue(function.phis.isEmpty)
        }
    }

    func testLoopHeaderPhisBindEntryAndBackedgeSSAValues() {
        let rows = [
            row(0x9000, "mov", "x1, #0"),
            row(0x9004, "cbz", "x0, 0x9014"),
            row(0x9008, "add", "x1, x1, x0"),
            row(0x900c, "subs", "x0, x0, #1"),
            row(0x9010, "b.ne", "0x9008"),
            row(0x9014, "mov", "x0, x1"),
            row(0x9018, "ret")
        ]
        let function = MacIRBuilder().buildFunction(name: "loop_phi", instructions: rows)
        let header = function.phis.filter { $0.blockAddress == 0x9008 }
        XCTAssertEqual(header.count, 2)
        let x0 = try? XCTUnwrap(header.first { $0.destination.description.hasPrefix("x0_") })
        let x1 = try? XCTUnwrap(header.first { $0.destination.description.hasPrefix("x1_") })
        XCTAssertNotNil(x0)
        XCTAssertNotNil(x1)
        for phi in header {
            XCTAssertEqual(Set(phi.incoming.map(\.machineAddress)), [0x9004, 0x9010])
        }
        if let x0, let x1 {
            guard case let .binary(addDestination, "+", addLeft, addRight) = function.instructions[2].operation,
                  case let .binary(subDestination, "-", subLeft, _) = function.instructions[3].operation else {
                return XCTFail("loop body must retain add and flag-setting subtraction")
            }
            XCTAssertEqual(addLeft, x1.destination)
            XCTAssertEqual(addRight, x0.destination)
            XCTAssertEqual(subLeft, x0.destination)
            XCTAssertEqual(x0.incoming.first { $0.machineAddress == 0x9010 }?.value,
                           subDestination)
            XCTAssertEqual(x1.incoming.first { $0.machineAddress == 0x9010 }?.value,
                           addDestination)
        }
    }

    // T2: exercise the shared composer directly so the scalar plan (which has
    // no referencedVRegisters) cannot silently inherit a predecessor's SIMD SSA.
    private func partialJoin(_ first: BuilderState, _ second: BuilderState,
                             region: Bool = false) throws -> BuilderState {
        let rows = [row(0xa000, "cbz", "x0, 0xa00c"),
                    row(0xa004, "nop"), row(0xa008, "b", "0xa010"),
                    row(0xa00c, "nop"), row(0xa010, "ret")]
        var plan = try XCTUnwrap(ScalarCFGStatePlan.admit(rows, hasExternalFacts: false))
        if region { plan.referencedVRegisters = [0, 1] }
        let join = try XCTUnwrap(plan.blockAtStart[4])
        let predecessors = plan.cfg.blocks[join].predecessors
        XCTAssertEqual(predecessors.count, 2)
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        return plan.incoming(for: join, entry: BuilderState(),
            outgoing: [predecessors[0]: first, predecessors[1]: second], phis: &phis)
    }

    private func partialResult(width: Int, floor: Int, fragments: Int = 1,
                               region: Bool = true) -> BuilderState {
        var state = BuilderState()
        state.permitsNEONBufferCarrier = region
        state.permitsNEONScalarViewCarrier = region
        state.registerVersionFloor = floor
        for index in 0..<fragments {
            _ = state.writeRegister("\(width == 64 ? "d" : "s")\(index)")
            state.callResultVectorWidth[index] = width
        }
        return state
    }

    private func assertUnavailable(_ value: MacIRValue,
                                   file: StaticString = #filePath, line: UInt = #line) {
        if case .unknown = value { return }
        XCTFail("join retained an unproved predecessor value: \(value)", file: file, line: line)
    }

    func testPartialVectorJoinRejectsDFirstSSecond() throws {
        let d = partialResult(width: 64, floor: 100)
        let s = partialResult(width: 32, floor: 200)
        let joined = try partialJoin(d, s, region: true)
        assertUnavailable(joined.readRegister("d0"))
        assertUnavailable(joined.readRegister("s0")) // different producer, not just a width mismatch
        let control = try partialJoin(d, d, region: true)
        XCTAssertEqual(control.readRegister("d0"), d.readRegister("d0"))
        var sameProducerNarrow = d
        sameProducerNarrow.callResultVectorWidth[0] = 32
        for (left, right) in [(d, sameProducerNarrow), (sameProducerNarrow, d)] {
            let minimum = try partialJoin(left, right, region: true)
            XCTAssertEqual(minimum.callResultVectorWidth[0], 32)
            assertUnavailable(minimum.readRegister("d0"))
            XCTAssertEqual(minimum.readRegister("s0"), sameProducerNarrow.readRegister("s0"))
        }
    }

    func testPartialVectorJoinRejectsSFirstDSecond() throws {
        let s = partialResult(width: 32, floor: 100)
        let d = partialResult(width: 64, floor: 200)
        let joined = try partialJoin(s, d, region: true)
        assertUnavailable(joined.readRegister("d0"))
        // The pinned S-first code already refuses D; this assertion exposes
        // the independently wrong retention of the first S producer.
        assertUnavailable(joined.readRegister("s0"))
        let control = try partialJoin(s, s, region: true)
        XCTAssertEqual(control.readRegister("s0"), s.readRegister("s0"))
    }

    func testScalarComposerRejectsDistinctSingleProducers() throws {
        // These are the separate SSA destinations of fmov s0,w1 / fmov s0,w2.
        let first = partialResult(width: 32, floor: 100, region: false)
        let second = partialResult(width: 32, floor: 200, region: false)
        let joined = try partialJoin(first, second)
        assertUnavailable(joined.readRegister("s0"))
        assertUnavailable(try XCTUnwrap(joined.latestABIResultValue))
        let control = try partialJoin(first, first)
        XCTAssertEqual(control.readRegister("s0"), first.readRegister("s0"))
    }

    func testPartialHFAJoinRejectsEachDistinctFragment() throws {
        var first = partialResult(width: 64, floor: 100, fragments: 2)
        var second = partialResult(width: 64, floor: 200, fragments: 2)
        first.latestABIResultValue = .abiComposite(type: "Pair", fragments: [
            first.readRegister("d0"), first.readRegister("d1")])
        second.latestABIResultValue = .abiComposite(type: "Pair", fragments: [
            second.readRegister("d0"), second.readRegister("d1")])
        let joined = try partialJoin(first, second, region: true)
        for index in 0..<2 { assertUnavailable(joined.readRegister("d\(index)")) }
        assertUnavailable(try XCTUnwrap(joined.latestABIResultValue))

        let control = try partialJoin(first, first, region: true)
        XCTAssertEqual(control.latestABIResultValue, first.latestABIResultValue)
        for index in 0..<2 {
            XCTAssertEqual(control.readRegister("d\(index)"), first.readRegister("d\(index)"))
        }
        // An unrelated current integer result must not be discarded.
        let integerResult = MacIRValue.register(name: "x0", version: 999)
        first.latestABIResultValue = integerResult
        second.latestABIResultValue = integerResult
        let integerControl = try partialJoin(first, second, region: true)
        XCTAssertEqual(integerControl.latestABIResultValue, integerResult)
    }

}
