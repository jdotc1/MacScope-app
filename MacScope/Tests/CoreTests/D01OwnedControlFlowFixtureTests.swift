import Foundation
import XCTest
@testable import MacScope

/// Runs the audit's owned machine-code witnesses through the production parser,
/// decoder and MacIR builder before interpreting only the selected scalar path.
final class D01OwnedControlFlowFixtureTests: XCTestCase {
    private static let objectURL = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Support/A64Oracle/Fixtures/control_flow.o")

    private func lift(_ name: String, until nextName: String? = nil,
                      callerReturnWidth: MacIRCallerReturnEvidence.Width? = nil) throws -> MacIRFunction {
        let object = try Data(contentsOf: Self.objectURL)
        let machO = try MachOParser().parse(object)
        XCTAssertEqual(machO.header.fileType, MachOConstants.fileTypeObject)
        let text = try XCTUnwrap(machO.sections.first {
            $0.segmentName == "__TEXT" && $0.sectionName == "__text"
        })
        let start = try XCTUnwrap(machO.symbols.first { $0.name == name }?.address)
        let end = try nextName.map { next in
            try XCTUnwrap(machO.symbols.first { $0.name == next }?.address)
        } ?? (text.address + text.size)
        guard start >= text.address, end > start,
              end <= text.address + text.size,
              let relativeStart = Int(exactly: start - text.address),
              let length = Int(exactly: end - start),
              let fileStart = Int(exactly: UInt64(text.fileOffset) + UInt64(relativeStart)),
              fileStart <= object.count, length <= object.count - fileStart else {
            throw MacIRConcreteEvaluator.Failure.harness("owned control-flow symbol lies outside __text")
        }
        let decoded = ARM64Decoder().decode(
            object.subdata(in: fileStart..<(fileStart + length)),
            baseAddress: start,
            maxInstructionCount: length / 4
        )
        XCTAssertEqual(decoded.count, length / 4)
        XCTAssertFalse(decoded.contains { $0.mnemonic == "unknown" || $0.mnemonic == "unavailable" })
        let rows = decoded.map { item in
            InstructionRow(address: item.address, bytes: item.byteText,
                           mnemonic: item.mnemonic, operands: item.operands,
                           hasBreakpoint: false, comment: item.comment)
        }
        return MacIRBuilder().buildFunction(name: name, startAddress: start,
                                            callerReturnWidth: callerReturnWidth, instructions: rows)
    }

    private func evaluate(_ function: MacIRFunction, input: UInt64) throws -> UInt64 {
        var state = try A64MachineState(seeding:
            JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
        state.x[0] = input
        var evaluator = MacIRConcreteEvaluator(function: function, state: state)
        try evaluator.runScalarCFG(function.instructions)
        return evaluator.state.x[0]
    }

    private func render(_ function: MacIRFunction, structured: Bool) -> String {
        let options = DecompilerOptions(structureControlFlow: structured,
                                        deadCodeElimination: false, nopElision: false,
                                        functionSizeGate: 1_024)
        return PseudocodePrinter(options: options).print(function: function).text
    }

    func testOwnedDiamondSelectsBothPredecessorsThroughDecodedMacIR() throws {
        let function = try lift("_audit_phi_select", until: "_audit_loop_sum", callerReturnWidth: .x0)
        XCTAssertEqual(function.instructions.count, 6)
        if SSAPropertyAssertions.enabled {
            let addresses = function.instructions.map { $0.source.address }
            guard let phi = SSAPropertyAssertions.phi(function, block: addresses[4], cell: 1, width: 64,
                incoming: [(addresses[2], addresses[1]), (addresses[3], addresses[3])]),
                  case let .assign(_, source) = function.instructions[4].operation else {
                return XCTFail("the decoded join move must consume its predecessor phi")
            }
            SSAPropertyAssertions.assertView(source, of: phi, width: 64)
            SSAPropertyAssertions.assertOrdinaryUsesDominated(function)
        } else {
            XCTAssertTrue(function.instructions.contains { instruction in
                if case .select = instruction.operation { return true }
                return false
            }, "the join must retain predecessor-dependent values in typed MacIR")
        }
        for (input, expected) in [(UInt64(0), UInt64(2)), (1, 1), (7, 1)] {
            XCTAssertEqual(try evaluate(function, input: input), expected, "input x0=\(input)")
        }
        let raw = render(function, structured: false)
        let structured = render(function, structured: true)
        for text in [raw, structured] {
            XCTAssertTrue(text.contains("0x1") && text.contains("0x2"), text)
            XCTAssertTrue(text.contains("int64_t joined_x1;"), text)
            XCTAssertTrue(text.contains("joined_x1 = 0x1;"), text)
            XCTAssertTrue(text.contains("joined_x1 = 0x2;"), text)
            XCTAssertTrue(text.contains("return joined_x1;"), text)
            XCTAssertFalse(text.contains("x0_22 = ("), text)
            XCTAssertFalse(text.contains("unavailable_x1"), text)
        }
        XCTAssertEqual(raw, structured)
        let document = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: false, deadCodeElimination: false,
            nopElision: false, functionSizeGate: 1_024
        )).print(function: function)
        XCTAssertTrue(document.lines.contains { line in
            line.sourceAddress == function.instructions[4].source.address
                && line.text.contains("joined_x1")
        }, "the original join move must remain selectable")
        var narrowReturn = function
        narrowReturn.returnType = "uint32_t"
        XCTAssertFalse(render(narrowReturn, structured: false).contains("int64_t joined_x1;"))
        let collision = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: false, deadCodeElimination: false,
            nopElision: false, functionSizeGate: 1_024
        )).print(function: function, registerNameOverrides: ["x0": "joined_x1"])
        XCTAssertFalse(collision.text.contains("int64_t joined_x1;"))
    }

    func testOwnedLoopCarriesCounterAccumulatorAndFlagsAcrossBackedge() throws {
        let function = try lift("_audit_loop_sum", until: "_audit_vector_loop")
        XCTAssertEqual(function.instructions.count, 7)
        for (input, expected) in [(UInt64(0), UInt64(0)), (1, 1), (3, 6)] {
            XCTAssertEqual(try evaluate(function, input: input), expected, "input x0=\(input)")
        }
        let rawDocument = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: false, deadCodeElimination: false, nopElision: false,
            functionSizeGate: 1_024)).print(function: function)
        let structuredDocument = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: true, deadCodeElimination: false, nopElision: false,
            functionSizeGate: 1_024)).print(function: function)
        let raw = rawDocument.text
        let structured = structuredDocument.text
        if SSAPropertyAssertions.enabled {
            let addresses = function.instructions.map { $0.source.address }
            let headerPhis = function.phis.filter { $0.blockAddress == addresses[2] }
            let accumulator = try XCTUnwrap(headerPhis.first {
                SSAPropertyAssertions.physicalCell($0.destination) == 1
            })
            XCTAssertEqual(accumulator.bitWidth, 64)
            XCTAssertEqual(accumulator.incoming.map(\.machineAddress), [addresses[1], addresses[4]])
            guard case let .assign(initialAccumulator, _) = function.instructions[0].operation,
                  case let .binary(nextAccumulator, _, left, _) = function.instructions[2].operation,
                  case let .binary(nextCounter, _, _, _) = function.instructions[3].operation else {
                return XCTFail("the decoded loop must retain its accumulator and counter writes")
            }
            XCTAssertEqual(accumulator.incoming.map(\.value), [initialAccumulator, nextAccumulator])
            let counter = try XCTUnwrap(headerPhis.first {
                SSAPropertyAssertions.physicalCell($0.destination) == 0
            })
            XCTAssertEqual(counter.bitWidth, 64)
            XCTAssertEqual(counter.incoming.map(\.machineAddress), [addresses[1], addresses[4]])
            XCTAssertEqual(counter.incoming.map(\.value), [.argument(bindingID: .gpr(0)), nextCounter])
            SSAPropertyAssertions.assertView(left, of: accumulator, width: 64)
            SSAPropertyAssertions.assertOrdinaryUsesDominated(function)
            XCTAssertNotNil(structuredDocument.regionTree)
            XCTAssertLessThanOrEqual(structured.components(separatedBy: "goto ").count,
                                     raw.components(separatedBy: "goto ").count)
            SSARenderExpectation.assertEdgeCopyAgreement(structuredDocument, rawDocument, function: function)
        } else {
            XCTAssertEqual(raw, structured, "phi edge copies must preserve identical typed values")
        }
        XCTAssertTrue(raw.contains("__edge_"), raw)
        XCTAssertTrue(raw.contains("goto L_"), raw)
        for text in [raw, structured] {
            XCTAssertTrue(text.contains("return"), text)
            XCTAssertFalse(text.contains("unavailable_x0"), text)
            XCTAssertFalse(text.contains("unavailable_x1"), text)
        }
    }

    func testOwnedVectorLoopKeepsDecodedControlAndOrderedQEffects() throws {
        let function = try lift("_audit_vector_loop", callerReturnWidth: .x0)
        let rows = function.instructions.reduce(into: [MacIRInstruction]()) { result, instruction in
            if result.last?.source.address != instruction.source.address { result.append(instruction) }
        }
        XCTAssertEqual(rows.map { $0.source.mnemonic.lowercased() },
                       ["cbz", "ldr", "ldr", "eor", "str", "subs", "b.ne", "ret"])
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows.filter { $0.neonLogical != nil }.count, 1)
        let sequences = rows.compactMap { $0.neonBufferSequence?.sequence }
        XCTAssertEqual(sequences.count, 3)
        XCTAssertEqual(sequences.map(\.firstMemorySequence), [0, 1, 2])
        XCTAssertTrue(sequences.allSatisfy { $0.mode == .postIndex && $0.delta == 16 && $0.effectCount == 2 })
        XCTAssertEqual(sequences.map(\.effect), [.load, .load, .store])
        XCTAssertEqual(sequences.map(\.baseRegister), ["x1", "x2", "x0"])
        XCTAssertEqual(sequences.map { $0.vectors.count }, [1, 1, 1])
        XCTAssertTrue(function.phis.contains { phi in
            phi.destination == function.returnValue && phi.incoming.count == 2
        }, "the exit must retain predecessor-specific x0 instead of forcing void")
        for row in rows where row.neonBufferSequence != nil {
            let effects = function.instructions.filter { $0.source.address == row.source.address }
            XCTAssertEqual(effects.map { $0.neonBufferSequence?.ordinal }, [0, 1])
            XCTAssertEqual(effects.filter { $0.neonBufferMemory != nil }.count, 1)
            XCTAssertNotNil(effects[0].memoryAccess)
            XCTAssertNil(effects[1].memoryAccess)
        }
        let raw = render(function, structured: false)
        XCTAssertTrue(raw.contains("goto L_"), raw)
        XCTAssertTrue(raw.contains("return"), raw)
        XCTAssertFalse(raw.contains("unknown"), raw)
    }

    func testRefusedPreIndexVectorTransferClobbersBaseAndKeepsBranch() throws {
        let owned = try lift("_audit_vector_loop")
        let bytes = try XCTUnwrap(owned.instructions.first {
            $0.source.mnemonic == "ldr"
        }?.source.byteText)
        let rows = [
            InstructionRow(address: 0x1000, bytes: bytes, mnemonic: "ldr",
                           operands: "q0, [x1, #16]!", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1004, bytes: "", mnemonic: "cbz",
                           operands: "x1, 0x1008", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "", mnemonic: "ret",
                           operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "refused_preindex",
                                                    instructions: rows)
        XCTAssertEqual(function.instructions.count, 3)
        if case .unknown = function.instructions[0].operation {
            // Refusal is explicit and cannot publish a speculative Q load.
        } else {
            XCTFail("malformed byte/text pre-index transfer must refuse")
        }
        if case let .conditionalBranch(_, left, _, target) = function.instructions[1].operation {
            XCTAssertEqual(left, .unknown("unavailable_x1"))
            XCTAssertEqual(target, .immediate(0x1008))
        } else {
            XCTFail("refusal must preserve the raw cbz edge")
        }
    }

    /// B574-1: a B.EQ backedge (outside the #574 exact plan) keeps its CFG edge.
    func testBEQBackedgeOutsideControlRegionPlanKeepsItsEdge() throws {
        let admitted = try lift("_audit_vector_loop")
        let originalRows = admitted.instructions.reduce(into: [MacIRInstruction]()) { result, instruction in
            if result.last?.source.address != instruction.source.address { result.append(instruction) }
        }
        let backedge = try XCTUnwrap(originalRows.firstIndex { $0.source.mnemonic == "b.ne" })
        let rows = originalRows.enumerated().map { index, instruction in
            let source = instruction.source
            return InstructionRow(address: source.address, bytes: source.byteText,
                mnemonic: index == backedge ? "b.eq" : source.mnemonic, operands: source.operands,
                hasBreakpoint: false, comment: source.comment)
        }
        let function = MacIRBuilder().buildFunction(name: "beq_loop", instructions: rows)
        let row = try XCTUnwrap(function.instructions.first { $0.source.address == rows[backedge].address })
        guard case .conditionalBranch = row.operation else {
            return XCTFail("B.EQ backedge lost its edge: \(row.operation)")
        }
    }

    func testControlRegionRefusalFallsThroughToPerRowLiftingAndKeepsControls() throws {
        let admitted = try lift("_audit_vector_loop")
        let originalRows = admitted.instructions.reduce(into: [MacIRInstruction]()) { result, instruction in
            if result.last?.source.address != instruction.source.address { result.append(instruction) }
        }
        XCTAssertEqual(originalRows.count, 8)
        let rows = originalRows.enumerated().map { index, instruction in
            let source = instruction.source
            return InstructionRow(address: source.address, bytes: source.byteText,
                mnemonic: source.mnemonic,
                operands: index == 2 ? "q1, [x2, #16]!" : source.operands,
                hasBreakpoint: false, comment: source.comment)
        }
        let refused = MacIRBuilder().buildFunction(name: "refused_vector_loop",
                                                    instructions: rows)
        // The fixed #574 plan refuses the pre-index row, so the general region
        // lifts the loop per row instead of erasing its body.
        XCTAssertEqual(refused.instructions.count, 8, "one effect per row")
        guard case .loadWriteback(_, _, _, 16, true) = refused.instructions[2].operation else {
            return XCTFail("pre-index Q load must be a typed writeback: \(refused.instructions[2].operation)")
        }
        XCTAssertEqual(refused.instructions[2].memoryAccess?.byteWidth, 16)
        for index in [0, 6] {
            if case let .conditionalBranch(_, _, _, target) = refused.instructions[index].operation {
                let text = try XCTUnwrap(rows[index].operands.split(separator: ",").last)
                    .trimmingCharacters(in: .whitespaces)
                let address = try XCTUnwrap(text.hasPrefix("0x")
                    ? Int64(text.dropFirst(2), radix: 16) : Int64(text))
                XCTAssertEqual(target, .immediate(address))
            } else {
                XCTFail("raw control row \(index) was erased")
            }
        }
        if case .returnValue = refused.instructions[7].operation {
            // The exit remains explicit after a rejected loop body.
        } else {
            XCTFail("refused region must retain return")
        }
    }

    func testOwnedVectorLoopExecutesZeroOneAndTwoIterationsWithExactWriteback() throws {
        let function = try lift("_audit_vector_loop")
        let left = (0..<32).map { UInt8($0 &* 7 &+ 3) }
        let right = (0..<32).map { UInt8(truncatingIfNeeded: $0 * 11 + 0x51) }
        let sentinel = [UInt8](repeating: 0xa5, count: 32)
        for count in 0...2 {
            var state = try A64MachineState(seeding:
                JSONDecoder().decode(A64OracleVector.State.self, from: Data("{}".utf8)))
            state.x[0] = 0x3000
            state.x[1] = 0x1000
            state.x[2] = 0x2000
            state.x[3] = UInt64(count)
            for offset in 0..<32 {
                state.setByte(left[offset], at: 0x1000 + UInt64(offset))
                state.setByte(right[offset], at: 0x2000 + UInt64(offset))
                state.setByte(sentinel[offset], at: 0x3000 + UInt64(offset))
            }
            var evaluator = MacIRConcreteEvaluator(function: function, state: state)
            try evaluator.runOwnedVectorLoopCFG(function.instructions)
            let actual = (0..<32).map { evaluator.state.byte(at: 0x3000 + UInt64($0)) }
            let expected = (0..<32).map { index in
                index < 16 * count ? left[index] ^ right[index] : sentinel[index]
            }
            XCTAssertEqual(actual, expected, "iteration count \(count)")
            XCTAssertEqual(evaluator.state.x[0], 0x3000 + UInt64(16 * count))
            XCTAssertEqual(evaluator.state.x[1], 0x1000 + UInt64(16 * count))
            XCTAssertEqual(evaluator.state.x[2], 0x2000 + UInt64(16 * count))
            XCTAssertEqual(evaluator.state.x[3], 0)
            if count > 0 {
                let final = Array(expected[(count - 1) * 16..<(count * 16)])
                let register = evaluator.state.v[0]
                let bytes = (0..<16).map { index in
                    UInt8(truncatingIfNeeded: (index < 8 ? register.low : register.high) >> ((index % 8) * 8))
                }
                XCTAssertEqual(bytes, final, "q0/v0 must alias the final XOR result")
            }
        }
    }
}
