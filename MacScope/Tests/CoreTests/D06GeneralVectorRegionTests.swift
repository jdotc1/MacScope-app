import Foundation
import XCTest
@testable import MacScope

final class D06GeneralVectorRegionTests: XCTestCase {
    // Exact retained machine rows, including bytes and structured operands,
    // are bundled with the tests; historical rendered dumps are not inputs.
    private struct RetainedMachineCapture: Decodable {
        struct MachineRow: Decodable {
            let address: String
            let byteText: String
            let mnemonic: String
            let operands: String
            let comment: String?
            let structuredOperands: InstructionOperands?
        }
        let schemaVersion: Int
        let function: String
        let start: String
        let machineInstructions: [MachineRow]
    }

    private func retainedFunction(_ fixtureName: String, name: String,
                                      start: UInt64, count: Int) throws -> MacIRFunction {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixtureName, withExtension: "json"),
            "The exact retained machine-row fixture must be bundled with CoreTests")
        let capture = try JSONDecoder().decode(RetainedMachineCapture.self, from: Data(contentsOf: url))
        XCTAssertEqual(capture.schemaVersion, 1)
        XCTAssertEqual(capture.function, name)
        XCTAssertEqual(UInt64(capture.start.dropFirst(2), radix: 16), start)
        XCTAssertEqual(capture.machineInstructions.count, count)
        let rows = try capture.machineInstructions.map { row in
            InstructionRow(address: try XCTUnwrap(UInt64(row.address.dropFirst(2), radix: 16)),
                bytes: row.byteText, mnemonic: row.mnemonic, operands: row.operands,
                hasBreakpoint: false, comment: row.comment, structuredOperands: row.structuredOperands)
        }
        return MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildFunction(
            name: name, startAddress: start, instructions: rows)
    }

    private func assertAllocatedSP(_ function: MacIRFunction, at address: UInt64,
                                      offset: Int64, file: StaticString = #filePath,
                                      line: UInt = #line) throws {
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == address },
                                         file: file, line: line)
        guard case let .binary(_, op, left, right) = instruction.operation else {
            return XCTFail("Expected retained SP address arithmetic", file: file, line: line)
        }
        XCTAssertEqual(op, "+", file: file, line: line)
        XCTAssertEqual(left, .register(name: "sp", version: 1), file: file, line: line)
        XCTAssertEqual(right, .immediate(offset), file: file, line: line)
    }

    func testPendingPredecessorRetainsAllocatedWorkspaceBase() throws {
        let function = try retainedFunction(
            "pending-sp-allocated-workspace",
            name: "_jpeg12_idct_islow", start: 0x4204c, count: 310)
        try assertAllocatedSP(function, at: 0x42304, offset: 0x10)
    }

    func testPendingPredecessorRetainsBothWorkspaceBases() throws {
        let function = try retainedFunction(
            "pending-sp-dual-workspace",
            name: "_jsimd_idct_islow_neon", start: 0x56c40, count: 513)
        try assertAllocatedSP(function, at: 0x56ea8, offset: 0x48)
        try assertAllocatedSP(function, at: 0x56eb0, offset: 8)
    }

    private func pendingPlan(_ predecessors: [[Int]]) -> ScalarCFGStatePlan {
        let blocks = predecessors.enumerated().map { index, incoming in
            BasicBlock(index: index, startIndex: index, endIndex: index + 1,
                successors: predecessors.indices.filter { predecessors[$0].contains(index) },
                predecessors: incoming, isLoopHeader: false)
        }
        let cfg = CFG(blocks: blocks, entryIndex: 0, domTree: [:], postDomTree: [:],
            loopHeaders: [], backEdges: [], irreducibleBlocks: [],
            blockByStartIndex: Dictionary(uniqueKeysWithValues: blocks.map { ($0.startIndex, $0.index) }),
            hasUnresolvedTargets: false)
        var plan = ScalarCFGStatePlan(cfg: cfg, blockAtStart: [:], blockAtEnd: [:],
            conditionalForks: [:], referencedXRegisters: [])
        plan.permitsPendingSPRecovery = true
        plan.spWritingBlocks = [0]
        return plan
    }

    func testPendingPredecessorCarriesOnlySPNotStackCoordinates() {
        let plan = pendingPlan([[], [0, 2], [0]])
        var entry = BuilderState(parameters: [])
        entry.stackSlotValues[8] = StackSlotValueFact(value: .immediate(7), byteWidth: 8, carrierKind: .integer)
        entry.outgoingCallStackStores[16] = StackSlotValueFact(value: .immediate(9), byteWidth: 8, carrierKind: .integer)
        var allocated = entry
        let sp = allocated.writeRegister("sp")
        var phis: [ScalarCFGStatePlan.PhiDraft] = []
        let result = plan.incoming(for: 1, entry: entry,
                                   outgoing: [0: allocated], phis: &phis)
        XCTAssertEqual(result.readRegister("sp"), sp)
        XCTAssertEqual(result.readRegister("wsp"), .unknown("unavailable_wsp"))
        XCTAssertFalse(result.entrySPIsExact)
        XCTAssertTrue(result.hasExplicitStackWriteback)
        XCTAssertTrue(result.stackSlotValues.isEmpty)
        XCTAssertTrue(result.outgoingCallStackStores.isEmpty)
        XCTAssertEqual(entry.stackSlotValues[8]?.value, .immediate(7))
        XCTAssertEqual(entry.outgoingCallStackStores[16]?.value, .immediate(9))
        XCTAssertEqual(allocated.readRegister("sp"), sp)
    }

    func testPendingSPProofFailsClosed() {
        let entry = BuilderState(parameters: [])
        var allocated = entry
        allocated.writeRegister("sp")
        var different = allocated
        different.writeRegister("sp")
        var unknown = allocated
        unknown.callUnavailableRegisterValues.insert("sp")
        func result(_ plan: ScalarCFGStatePlan, _ outgoing: [Int: BuilderState]) -> MacIRValue {
            var phis: [ScalarCFGStatePlan.PhiDraft] = []
            return plan.incoming(for: 1, entry: entry, outgoing: outgoing, phis: &phis).readRegister("sp")
        }
        var plan = pendingPlan([[], [0, 2], [0]])
        XCTAssertEqual(result(plan, [0: unknown]), .unknown("unavailable_sp"))
        plan.spWritingBlocks.insert(2)
        XCTAssertEqual(result(plan, [0: allocated]), .unknown("unavailable_sp"))
        plan = pendingPlan([[], [0, 2], [3], []])
        XCTAssertEqual(result(plan, [0: allocated]), .unknown("unavailable_sp"))
        XCTAssertEqual(result(plan, [0: allocated, 3: different]), .unknown("unavailable_sp"))
        plan = pendingPlan([[], [0, 2], [2]])
        XCTAssertEqual(result(plan, [0: allocated]), .unknown("unavailable_sp"))
        plan = pendingPlan([[], [0, 2], [0]])
        plan.permitsPendingSPRecovery = false
        XCTAssertEqual(result(plan, [0: allocated]), .unknown("unavailable_sp"))
    }

    func testEarlyNoReturnPathRetainsFrameDepthFromOtherBranch() throws {
        let word: UInt32 = 0x4cdf_0500
        let bytes = withUnsafeBytes(of: word.littleEndian) { Data($0) }
        let decoded = try XCTUnwrap(ARM64Decoder().decode(bytes, baseAddress: 0xb008,
                                                            maxInstructionCount: 1).first)
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            .init(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                  hasBreakpoint: false, comment: nil)
        }
        let rows = [
            row(0xb000, "cbz", "x0, 0xb014"),
            row(0xb004, "sub", "sp, sp, #0xa0"),
            InstructionRow(address: decoded.address, bytes: decoded.byteText,
                           mnemonic: decoded.mnemonic, operands: decoded.operands,
                           hasBreakpoint: false, comment: decoded.comment),
            row(0xb00c, "add", "sp, sp, #0xa0"),
            row(0xb010, "ret", ""),
            row(0xb014, "bl", "___stack_chk_fail"),
        ]
        let function = MacIRBuilder().buildFunction(name: "branch_frame", startAddress: 0xb000,
                                                    instructions: rows)
        XCTAssertTrue(function.instructions.contains { $0.source.address == 0xb008 &&
            $0.neonInterleavedMemory != nil })
        XCTAssertEqual(function.stackFrameSize, 0xa0,
                       "the final no-return path bypasses this branch's frame allocation")
    }

    func testPhiRegionEmitsNoReturnCallAsTerminalExit() throws {
        let loadWord: UInt32 = 0x4cdf_0500
        let loadBytes = withUnsafeBytes(of: loadWord.littleEndian) { Data($0) }
        let decoded = try XCTUnwrap(ARM64Decoder().decode(loadBytes, baseAddress: 0xa008,
                                                            maxInstructionCount: 1).first)
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
            .init(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                  hasBreakpoint: false, comment: nil)
        }
        let rows = [
            row(0xa000, "mov", "x8, #0"),
            row(0xa004, "cbz", "x0, 0xa018"),
            InstructionRow(address: decoded.address, bytes: decoded.byteText,
                           mnemonic: decoded.mnemonic, operands: decoded.operands,
                           hasBreakpoint: false, comment: decoded.comment),
            row(0xa00c, "subs", "x1, x1, #1"),
            row(0xa010, "b.ne", "0xa008"),
            row(0xa014, "ret", ""),
            row(0xa018, "bl", "___stack_chk_fail"),
        ]
        let function = MacIRBuilder().buildFunction(name: "phi_call_exit", startAddress: 0xa000,
                                                    instructions: rows)
        XCTAssertTrue(function.instructions.contains { $0.source.address == 0xa008 &&
            $0.neonInterleavedMemory != nil })
        XCTAssertFalse(function.phis.isEmpty, "the loop must carry SSA values across an edge")
        let text = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: true, deadCodeElimination: false,
            nopElision: false, functionSizeGate: 1_024
        )).print(function: function).text
        XCTAssertFalse(text.contains("__unavailable_cfg_phi"), text)
        XCTAssertTrue(text.contains("___stack_chk_fail("), text)
    }

    func testDecodedSaturatingNarrowLiftsWithoutVetoingCallRegion() throws {
        func decoded(_ word: UInt32, at address: UInt64) -> InstructionRow {
            let bytes = withUnsafeBytes(of: word.littleEndian) { Data($0) }
            let row = ARM64Decoder().decode(bytes, baseAddress: address,
                                            maxInstructionCount: 1)[0]
            return .init(address: row.address, bytes: row.byteText,
                         mnemonic: row.mnemonic, operands: row.operands,
                         hasBreakpoint: false, comment: row.comment)
        }
        let narrow = decoded(0x0f0e_9e45, at: 0x9008)
        XCTAssertEqual(narrow.mnemonic, "sqrshrn")
        XCTAssertEqual(narrow.operands, "v5.8b, v18.8h, #2")
        let rows = [
            InstructionRow(address: 0x9000, bytes: "", mnemonic: "cbz",
                           operands: "x0, 0x9010", hasBreakpoint: false, comment: nil),
            decoded(0x4cdf_0500, at: 0x9004), narrow,
            InstructionRow(address: 0x900c, bytes: "", mnemonic: "ret",
                           operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x9010, bytes: "", mnemonic: "bl",
                           operands: "___stack_chk_fail", hasBreakpoint: false, comment: nil),
        ]
        let function = MacIRBuilder().buildFunction(name: "narrow_then_exit", startAddress: 0x9000,
                                                    instructions: rows)
        XCTAssertTrue(function.instructions.contains { $0.source.address == 0x9004 &&
            $0.neonInterleavedMemory != nil }, "the decoded narrow must not veto the earlier LD4")
        let modeled = try XCTUnwrap(function.instructions.first { $0.source.address == 0x9008 })
        XCTAssertEqual(modeled.neonLaneOp?.kind, .sqrshrn)
        XCTAssertEqual(modeled.neonLaneOp?.setsQC, true)
        guard case .intrinsic = modeled.operation else { return XCTFail("Expected typed saturating narrow") }
        XCTAssertTrue(function.instructions.contains { instruction in
            guard instruction.source.address == 0x9010 else { return false }
            if case .call = instruction.operation { return true }
            return false
        })
    }

    func testReturningCallClobbersRegionAndNoReturnCallEndsOtherPath() throws {
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String, _ word: UInt32 = 0) -> InstructionRow {
            if word != 0 {
                let bytes = withUnsafeBytes(of: word.littleEndian) { Data($0) }
                let decoded = ARM64Decoder().decode(bytes, baseAddress: address,
                                                     maxInstructionCount: 1)[0]
                return InstructionRow(address: address, bytes: decoded.byteText,
                    mnemonic: decoded.mnemonic, operands: decoded.operands,
                    hasBreakpoint: false, comment: decoded.comment)
            }
            return InstructionRow(address: address, bytes: "00000000", mnemonic: mnemonic,
                                  operands: operands, hasBreakpoint: false, comment: nil)
        }
        let rows = [
            row(0x8000, "cbz", "x0, 0x8014"),
            row(0x8004, "ld4", "{v0.8h, v1.8h, v2.8h, v3.8h}, [x8], #64", 0x4cdf_0500),
            row(0x8008, "bl", "_callee"),
            row(0x800c, "st4", "{v0.2d, v1.2d, v2.2d, v3.2d}, [x8]", 0x4c00_0c00),
            row(0x8010, "ret", ""),
            row(0x8014, "bl", "___stack_chk_fail")
        ]
        XCTAssertTrue(MacIRBuilder.attemptsGeneralVectorRegion(rows),
                      "a vector row with conditional control must request region admission")
        let direct = MacIRBuilder().buildGeneralVectorRegion(name: "region_calls",
            startAddress: 0x8000, rows: rows, initialState: BuilderState(),
            hasExternalFacts: false, isVariadic: false)
        XCTAssertNotNil(direct, "the bounded CFG plan must admit both terminal paths")
        XCTAssertTrue(direct?.instructions.contains { $0.source.address == 0x8004 &&
            $0.neonInterleavedMemory != nil } == true,
            "direct effects=\(direct?.instructions.map { "\($0.source.mnemonic):\($0.operation)" } ?? [])")
        let function = MacIRBuilder().buildFunction(name: "region_calls", startAddress: 0x8000,
                                                    instructions: rows)
        let load = try XCTUnwrap(function.instructions.first { $0.source.address == 0x8004 &&
            $0.neonInterleavedMemory != nil }, "direct=\(direct != nil), operations=\(function.instructions.map { "\($0.source.mnemonic):\($0.source.operands)" })")
        XCTAssertEqual(load.neonInterleavedMemory?.frame.structureCount, 4)
        let returning = try XCTUnwrap(function.instructions.first { $0.source.address == 0x8008 })
        if case let .call(frame, _) = returning.operation { XCTAssertEqual(frame.target, "_callee") }
        else { XCTFail("returning call was refused") }
        let store = try XCTUnwrap(function.instructions.first { $0.source.address == 0x800c })
        XCTAssertNil(store.neonInterleavedMemory)
        if case .unknown = store.operation {} else {
            XCTFail("a store with call-clobbered vector inputs must refuse its row")
        }
        XCTAssertTrue(function.instructions.contains { instruction in
            guard instruction.source.address == 0x8010 else { return false }
            if case .returnValue = instruction.operation { return true }
            return false
        })
        let fatal = try XCTUnwrap(function.instructions.first { $0.source.address == 0x8014 })
        if case let .call(frame, result) = fatal.operation {
            XCTAssertEqual(frame.target, "___stack_chk_fail")
            XCTAssertNil(result)
            XCTAssertEqual(CFGBuilder.terminatorKind(of: fatal.operation), .returnTerminator)
        } else { XCTFail("no-return call was refused") }
    }

    func testCallBoundaryPreservesOnlyLowHalfOfCalleeSavedVectors() {
        var state = BuilderState()
        state.permitsNEONBufferCarrier = true
        state.permitsNEONScalarViewCarrier = true
        _ = state.writeRegister("v8")
        state.stackSlotValues[0] = .init(value: .immediate(42), byteWidth: 8,
                                          carrierKind: .integer)
        state.invalidateAppleCallerSavedState()
        state.invalidateGeneralVectorRegionAtCall(returning: nil)
        XCTAssertTrue(state.stackSlotValues.isEmpty)
        if case .unknown = state.readRegister("v8") {} else { XCTFail("upper half survived call") }
        if case .unknown = state.readRegister("d8") { XCTFail("low half was clobbered") }
        _ = state.writeRegister("v8")
        if case .unknown = state.readRegister("v8") { XCTFail("fresh full write did not restore v8") }

        var returning = BuilderState()
        returning.permitsNEONBufferCarrier = true
        returning.permitsNEONScalarViewCarrier = true
        returning.invalidateAppleCallerSavedState()
        let result = returning.writeRegister("d0")
        returning.invalidateGeneralVectorRegionAtCall(returning: result)
        XCTAssertEqual(returning.readRegister("d0"), result, "the scalar SIMD result survives the call boundary")
        // DP12 #661: a D0 result defines 64 bits; V0's upper half is unspecified.
        if case .unknown = returning.readRegister("v0") {} else { XCTFail("a D0 result was read as a defined V0") }
        if case .unknown = returning.readRegister("q0") {} else { XCTFail("a D0 result was read as a defined Q0") }
        _ = returning.writeRegister("v0")
        if case .unknown = returning.readRegister("v0") { XCTFail("a full write after the call defines V0") }
        // An S0 result leaves bits 32-63 unspecified as well.
        var single = BuilderState()
        single.permitsNEONBufferCarrier = true
        single.permitsNEONScalarViewCarrier = true
        let s0 = single.writeRegister("s0")
        single.invalidateGeneralVectorRegionAtCall(returning: s0)
        XCTAssertEqual(single.readRegister("s0"), s0)
        if case .unknown = single.readRegister("d0") {} else { XCTFail("an S0 result was read as a defined D0") }
        if case .unknown = returning.readRegister("v1") {} else {
            XCTFail("another caller-saved vector survived the call")
        }
    }

    func testMultipleStructureRowsPreserveElementOrderAndWriteback() throws {
        // Fixed ISA words include the libjpeg LD4 halfword and ST3 byte
        // shapes, plus LD1 list lengths and LD2–LD4 element widths.
        let cases: [(UInt32, String, Int, Int, Int, Bool)] = [
            (0x4cdf_0500, "ld4", 4, 2, 16, true),
            (0x4c9f_4114, "st3", 3, 1, 16, true),
            (0x0c40_6500, "ld1", 1, 2, 8, false),
            (0x0c40_7000, "ld1", 1, 1, 8, false),
            (0x4c40_8800, "ld2", 2, 4, 16, false),
            (0x0c40_4400, "ld3", 3, 2, 8, false),
            (0x4c00_0c00, "st4", 4, 8, 16, false),
            (0x4c00_8400, "st2", 2, 2, 16, false),
        ]
        for (word, mnemonic, channels, elementBytes, activeBytes, writesBack) in cases {
            let bytes = withUnsafeBytes(of: word.littleEndian) { Data($0) }
            let decoded = try XCTUnwrap(ARM64Decoder().decode(bytes, baseAddress: 0x8000,
                maxInstructionCount: 1).first)
            XCTAssertEqual(decoded.mnemonic, mnemonic)
            let row = InstructionRow(address: decoded.address, bytes: decoded.byteText,
                mnemonic: decoded.mnemonic, operands: decoded.operands,
                hasBreakpoint: false, comment: decoded.comment)
            let function = MacIRBuilder().buildFunction(name: "structure_row",
                startAddress: 0x8000, instructions: [row])
            let effects = function.instructions.filter { $0.source.address == 0x8000 }
            let frame = try XCTUnwrap(effects.first?.neonInterleavedMemory?.frame,
                "missing typed frame for \(decoded.mnemonic) \(decoded.operands)")
            XCTAssertEqual(frame.structureCount, channels)
            XCTAssertEqual(frame.elementBytes, elementBytes)
            XCTAssertEqual(frame.activeBytes, activeBytes)
            XCTAssertEqual(frame.byteCount, frame.groupCount * activeBytes)
            XCTAssertEqual(effects.map { $0.neonInterleavedMemory?.ordinal },
                Array(0..<frame.effectCount))
            XCTAssertEqual(frame.baseDestination != nil, writesBack)
            XCTAssertEqual(frame.orderedBytes.map(\.offset), Array(0..<frame.byteCount))
            XCTAssertEqual(Set(frame.orderedBytes.map(\.sequence)).count, frame.byteCount)
            if channels == 1 {
                if frame.groupCount > 1 {
                    XCTAssertEqual(frame.orderedBytes[activeBytes].vector, 1,
                        "LD1 list members must occupy contiguous blocks")
                }
            } else {
                XCTAssertEqual(frame.orderedBytes[elementBytes].vector, 1,
                    "interleaving advances after one complete element")
                if elementBytes > 1 {
                    XCTAssertEqual(frame.orderedBytes[1].lane, 1,
                        "bytes inside a multibyte element retain order")
                }
            }
            let text = PseudocodePrinter(options: DecompilerOptions(
                structureControlFlow: true, deadCodeElimination: false,
                nopElision: false, functionSizeGate: 1_024
            )).print(function: function).text
            XCTAssertFalse(text.contains("__unknown"), text)
            XCTAssertTrue(text.contains("__neon_\(mnemonic)_") ||
                (mnemonic == "ld1" && text.contains("__neon_ld1_")), text)
        }
    }

    // The 88-byte `_jsimd_h2v1_upsample_neon` from the installed
    // libjpeg.8.dylib. A fixed symbol slice keeps this test independent of
    // the local library's location and avoids a binary-wide decode.
    private let words: [UInt32] = [
        0x7100041f, 0x5400028b, 0xd2800008, 0xf9400069,
        0x2a0003ea, 0x340001a1, 0x5280000b, 0x5280000c,
        0xf868784d, 0xf868792e, 0x3cec49a0, 0x4ea01c01,
        0x8b2b41cf, 0x4c0081e0, 0x1100418c, 0x1100816b,
        0x6b01017f, 0x54ffff23, 0x91000508, 0xeb0a011f,
        0x54fffe21, 0xd65f03c0
    ]

    private func rows() -> [InstructionRow] {
        let bytes = Data(words.flatMap { word in
            let le = word.littleEndian
            return withUnsafeBytes(of: le) { Array($0) }
        })
        return ARM64Decoder().decode(bytes, baseAddress: 0x56180,
                                     maxInstructionCount: words.count).map { item in
            InstructionRow(address: item.address, bytes: item.byteText,
                mnemonic: item.mnemonic, operands: item.operands,
                hasBreakpoint: false, comment: item.comment)
        }
    }

    private func containsEmittedPhi(_ value: MacIRValue, in function: MacIRFunction) -> Bool {
        if function.phis.contains(where: { $0.destination == value }) { return true }
        switch value {
        case let .unary(_, inner): return containsEmittedPhi(inner, in: function)
        case let .signedBitfield(field): return containsEmittedPhi(field.source, in: function)
        case let .binaryExpression(_, left, right):
            return containsEmittedPhi(left, in: function)
                || containsEmittedPhi(right, in: function)
        default: return false
        }
    }

    func testDecodedNestedLoopComposesIndexedLoadLogicalMoveAndOrderedST2() throws {
        let decoded = rows()
        XCTAssertEqual(decoded.count, words.count)
        XCTAssertFalse(decoded.contains { $0.mnemonic == "unknown" || $0.mnemonic == "unavailable" })
        let function = MacIRBuilder().buildFunction(name: "_jsimd_h2v1_upsample_neon",
            startAddress: 0x56180,
            jumpTables: [0x900000: [0x900004]],
            instructions: decoded)
        let indexed = try XCTUnwrap(function.instructions.first {
            $0.source.address == 0x561a8 && $0.neonIndexedMemory != nil
        })
        let indexedMemory = try XCTUnwrap(indexed.neonIndexedMemory)
        XCTAssertEqual(indexedMemory.byteWidth, 16)
        for addressInput in [indexedMemory.base, indexedMemory.index] {
            XCTAssertTrue(containsEmittedPhi(addressInput, in: function),
                "each loop-carried indexed address input needs an emitted phi")
        }
        let scalarPointerLoad = try XCTUnwrap(function.instructions.first {
            $0.source.address == 0x561a4
        })
        guard case let .load(_, scalarAddress) = scalarPointerLoad.operation,
              case let .binaryExpression(_, pointerBase, _) = scalarAddress else {
            return XCTFail("expected scalar indexed pointer load")
        }
        XCTAssertTrue(containsEmittedPhi(pointerBase, in: function),
            "the outer-loop pointer must have an emitted phi")
        let logical = try XCTUnwrap(function.instructions.first {
            $0.source.address == 0x561ac && $0.neonLogical != nil
        })
        XCTAssertEqual(logical.neonLogical?.kind, .orr)
        let stores = function.instructions.filter { $0.source.address == 0x561b4 }
        XCTAssertEqual(stores.map { $0.neonInterleavedMemory?.ordinal }, [0, 1])
        let frame = try XCTUnwrap(stores.first?.neonInterleavedMemory?.frame)
        XCTAssertEqual(frame.orderedBytes.count, 32)
        XCTAssertEqual(frame.orderedBytes.prefix(4).map(\.vector), [0, 1, 0, 1])
        XCTAssertEqual(frame.orderedBytes.prefix(4).map(\.lane), [0, 0, 1, 1])
        for address in [UInt64(0x56184), 0x56194, 0x561c4, 0x561d0] {
            XCTAssertTrue(function.instructions.contains { instruction in
                guard instruction.source.address == address else { return false }
                if case .conditionalBranch = instruction.operation { return true }
                return false
            }, "missing original control edge at \(String(address, radix: 16))")
        }
        XCTAssertTrue(function.instructions.contains { instruction in
            guard instruction.source.address == 0x561d4 else { return false }
            if case .returnValue = instruction.operation { return true }
            return false
        })
        let text = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: true, deadCodeElimination: false,
            nopElision: false, functionSizeGate: 1_024
        )).print(function: function).text
        XCTAssertTrue(text.contains("__neon_st2_16b_scatter_even_bytes_stride2"), text)
        XCTAssertTrue(text.contains("__neon_st2_16b_scatter_odd_bytes_stride2"), text)
        XCTAssertTrue(text.contains("*(__uint128_t *)"), text)
        XCTAssertFalse(text.contains("__neon_scatter2_bytes"), text)
    }

    func testMalformedInterleavedStoreRefusesOnlyItsRowAndKeepsBackedge() {
        var decoded = rows()
        let storeIndex = decoded.firstIndex { $0.address == 0x561b4 }!
        let original = decoded[storeIndex]
        decoded[storeIndex] = InstructionRow(address: original.address,
            bytes: original.bytes, mnemonic: original.mnemonic,
            operands: "{v0.16b, v2.16b}, [x15]",
            hasBreakpoint: false, comment: original.comment)
        let function = MacIRBuilder().buildFunction(name: "refused_mixed_block",
            startAddress: 0x56180, instructions: decoded)
        // Refusal is per row: the indexed Q load before the malformed ST2 in
        // the same block keeps its typed semantics; the ST2 alone is unknown.
        XCTAssertTrue(function.instructions.contains { $0.source.address == 0x561a8 && $0.neonIndexedMemory != nil })
        XCTAssertFalse(function.instructions.contains { $0.source.address == 0x561b4 && $0.neonInterleavedMemory != nil })
        XCTAssertTrue(function.instructions.contains { instruction in
            guard instruction.source.address == 0x561b4 else { return false }
            if case .unknown = instruction.operation { return true }
            return false
        })
        XCTAssertTrue(function.instructions.contains { instruction in
            guard instruction.source.address == 0x561c4 else { return false }
            if case .conditionalBranch = instruction.operation { return true }
            if case .intrinsic(_, let name, _) = instruction.operation { return name == "branch_lo" }
            return false
        })

        // The architectural post-index writeback must be poisoned even when
        // malformed list text prevents typed ST2 admission.
        var state = BuilderState(parameters: [])
        state.permitsNEONBufferCarrier = true
        let priorBase = state.writeRegister("x15")
        let postIndexed = InstructionRow(address: 0x7000, bytes: "e0 81 9f 4c",
            mnemonic: "st2", operands: "{v0.16b, v2.16b}, [x15], #32",
            hasBreakpoint: false, comment: nil)
        let refused = MacIRBuilder().generalVectorRefusal(postIndexed, state: &state)
        if case .unknown = refused.operation {} else { XCTFail("malformed ST2 must refuse") }
        XCTAssertNotEqual(state.readRegister("x15"), priorBase)
        XCTAssertEqual(state.readRegister("x15"), .unknown("unavailable_x15"))

        let variadic = MacIRAuthoritativeParameterPlan(parameters: [], isVariadic: true)!
        let refusedVariadic = MacIRBuilder().buildFunction(name: "variadic_refusal",
            authoritativeParameterPlan: variadic, instructions: rows())
        XCTAssertTrue(refusedVariadic.isVariadic)
    }

    // The 112-byte two-row sibling `_jsimd_h2v2_upsample_neon` (0x561d8).
    // Its row-pointer pair load `ldp x15, x16, [x16]` is an ordinary scalar
    // row inside the region and must keep its typed memory access.
    private let h2v2Words: [UInt32] = [
        0x7100040b, 0x5400034b, 0xd2800008, 0xd2800009,
        0xf940006a, 0x53017d6b, 0x1100056b, 0x34000201,
        0x5280000c, 0x5280000d, 0xf869784e, 0x8b080d50,
        0xa940420f, 0x3ced49c0, 0x4ea01c01, 0x8b2c41f1,
        0x4c008220, 0x8b2c4211, 0x4c008220, 0x110041ad,
        0x1100818c, 0x6b01019f, 0x54fffee3, 0x91000908,
        0x91000529, 0xeb0b013f, 0x54fffda1, 0xd65f03c0
    ]

    func testTwoRowSiblingKeepsTypedScalarPairLoadInsideRegion() throws {
        let bytes = Data(h2v2Words.flatMap { word in
            withUnsafeBytes(of: word.littleEndian) { Array($0) }
        })
        let decoded = ARM64Decoder().decode(bytes, baseAddress: 0x561d8,
            maxInstructionCount: h2v2Words.count).map { item in
            InstructionRow(address: item.address, bytes: item.byteText,
                mnemonic: item.mnemonic, operands: item.operands,
                hasBreakpoint: false, comment: item.comment)
        }
        XCTAssertEqual(decoded.count, h2v2Words.count)
        let function = MacIRBuilder().buildFunction(name: "_jsimd_h2v2_upsample_neon",
            startAddress: 0x561d8, instructions: decoded)
        XCTAssertFalse(function.instructions.contains {
            if case .unknown = $0.operation { return true }; return false
        })
        let pair = try XCTUnwrap(function.instructions.first { $0.source.address == 0x56208 })
        XCTAssertEqual(pair.memoryAccess?.byteWidth, 8)
        XCTAssertEqual(pair.memoryAccess?.extensionKind, MacIRMemoryAccess.ExtensionKind.none)
        let rowLoad = try XCTUnwrap(function.instructions.first { $0.source.address == 0x56200 })
        XCTAssertEqual(rowLoad.memoryAccess?.byteWidth, 8)
        for address in [UInt64(0x56218), 0x56220] {
            XCTAssertEqual(function.instructions.filter { $0.source.address == address }
                .map { $0.neonInterleavedMemory?.ordinal }, [0, 1])
        }
        let text = PseudocodePrinter(options: DecompilerOptions(
            structureControlFlow: true, deadCodeElimination: false,
            nopElision: false, functionSizeGate: 1_024
        )).print(function: function).text
        XCTAssertFalse(text.contains("__restore_pair"), text)
        XCTAssertFalse(text.contains("__unknown"), text)
    }

    /// A refused store may alias a known stack value: a later load in the same
    /// block must not be forwarded from the store before it.
    func testLoadAfterRefusedStoreIsNotForwardedFromBeforeIt() throws {
        func rows(middle: InstructionRow) -> [InstructionRow] {
            func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
                InstructionRow(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                               hasBreakpoint: false, comment: nil)
            }
            return [
                row(0x7000, "sub", "sp, sp, #0x10"),
                row(0x7004, "mov", "x3, #0x4"),
                row(0x7008, "ldr", "q0, [x15]"),
                row(0x700c, "str", "x0, [sp]"),
                middle,
                row(0x7014, "ldr", "x2, [sp]"),
                row(0x7018, "subs", "x3, x3, #0x1"),
                row(0x701c, "b.ne", "0x7008"),
                row(0x7020, "add", "sp, sp, #0x10"),
                row(0x7024, "ret", ""),
            ]
        }
        func reload(_ function: MacIRFunction) throws -> MacIROperation {
            try XCTUnwrap(function.instructions.first { $0.source.address == 0x7014 }).operation
        }
        // Control: with a lifted vector row between them, the load forwards.
        let lifted = MacIRBuilder().buildFunction(name: "forwarded", startAddress: 0x7000,
            instructions: rows(middle: InstructionRow(address: 0x7010, bytes: "", mnemonic: "orr",
                operands: "v1.16b, v0.16b, v0.16b", hasBreakpoint: false, comment: nil)))
        guard case .stackSlotRead = try reload(lifted) else {
            return XCTFail("control must forward the stored stack value: \(try reload(lifted))")
        }
        // A malformed ST2 is refused; it must invalidate the stack fact.
        let refused = MacIRBuilder().buildFunction(name: "not_forwarded", startAddress: 0x7000,
            instructions: rows(middle: InstructionRow(address: 0x7010, bytes: "e0 81 00 4c", mnemonic: "st2",
                operands: "{v0.16b, v2.16b}, [x15]", hasBreakpoint: false, comment: nil)))
        XCTAssertTrue(refused.instructions.contains { instruction in
            guard instruction.source.address == 0x7010 else { return false }
            if case .unknown = instruction.operation { return true }
            return false
        })
        if case .stackSlotRead = try reload(refused) {
            XCTFail("load after a refused store was forwarded from before it")
        }
        // A stack fact stored inside the loop must not reach the loop header
        // on the first-predecessor path: the back edge may have overwritten it.
        let headerLoad = MacIRBuilder().buildFunction(name: "join", startAddress: 0x7000,
            instructions: [
                InstructionRow(address: 0x7000, bytes: "", mnemonic: "sub", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x7004, bytes: "", mnemonic: "str", operands: "x0, [sp]", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x7008, bytes: "", mnemonic: "ldr", operands: "x2, [sp]", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x700c, bytes: "", mnemonic: "ldr", operands: "q0, [x15]", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x7010, bytes: "", mnemonic: "str", operands: "x1, [sp]", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x7014, bytes: "", mnemonic: "subs", operands: "x3, x3, #0x1", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x7018, bytes: "", mnemonic: "b.ne", operands: "0x7008", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x701c, bytes: "", mnemonic: "add", operands: "sp, sp, #0x10", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x7020, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ])
        let header = try XCTUnwrap(headerLoad.instructions.first { $0.source.address == 0x7008 })
        if case .stackSlotRead = header.operation {
            XCTFail("loop-header load forwarded the pre-loop store across the back edge")
        }
        XCTAssertTrue(refused.instructions.contains { instruction in
            guard instruction.source.address == 0x701c else { return false }
            if case .conditionalBranch = instruction.operation { return true }
            return false
        }, "loop backedge kept")
    }

    /// SP joins at a loop header only when the loop can change it.
    func testLoopHeaderJoinsSPOnlyWhenTheLoopWritesIt() {
        func rows(_ body: [(String, String)]) -> [InstructionRow] {
            let text = [("sub", "sp, sp, #0x10"), ("mov", "x3, #0x4"), ("ldr", "q0, [x15]")] + body
                + [("subs", "x3, x3, #0x1"), ("b.ne", "0x5008"), ("add", "sp, sp, #0x10"), ("ret", "")]
            return text.enumerated().map { index, pair in
                InstructionRow(address: 0x5000 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                               operands: pair.1, hasBreakpoint: false, comment: nil)
            }
        }
        func spPhis(_ function: MacIRFunction) -> [MacIRPhi] {
            function.phis.filter { phi in
                guard phi.blockAddress == 0x5008, case .register(name: "sp", _) = phi.destination else { return false }
                return true
            }
        }
        let steady = MacIRBuilder().buildFunction(name: "steady", startAddress: 0x5000,
                                                  instructions: rows([("str", "x0, [sp]")]))
        XCTAssertTrue(steady.instructions.contains { $0.memoryAccess?.byteWidth == 16 }, "region path claimed it")
        XCTAssertTrue(spPhis(steady).isEmpty, "a loop that never writes SP keeps it unchanged")

        // A loop that moves SP and reads it as a value: the header must join SP
        // instead of reusing the pre-loop SSA value on every iteration.
        let moving = MacIRBuilder().buildFunction(name: "moving", startAddress: 0x5000,
            instructions: rows([("mov", "x1, sp"), ("str", "x1, [x15]"), ("sub", "sp, sp, #0x10")]))
        let joined = spPhis(moving)
        XCTAssertEqual(joined.count, 1, moving.instructions.map { "\($0.source.address): \($0.operation)" }
            .joined(separator: "\n"))
        XCTAssertEqual(joined.first?.incoming.count, 2)
    }

    /// DP01 #601: a definition skipped by TBZ must reach its use through a phi.
    func testTBZSkippedDefinitionJoinsThroughPhi() {
        let text: [(String, String)] = [
            ("mov", "x3, #0x4"), ("ldr", "q0, [x1]"), ("tbz", "x2, #0, 0x6010"),
            ("mov", "x4, #0x7"), ("add", "x5, x4, #0x1"), ("subs", "x3, x3, #0x1"),
            ("b.ne", "0x6004"), ("ret", ""),
        ]
        let rows = text.enumerated().map { index, pair in
            InstructionRow(address: 0x6000 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                           operands: pair.1, hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder().buildFunction(name: "tbz_skip", startAddress: 0x6000, instructions: rows)
        XCTAssertTrue(function.instructions.contains { $0.memoryAccess?.byteWidth == 16 }, "region path claimed it")
        let tbz = function.instructions.first { $0.source.address == 0x6008 }
        if case .unknown = tbz?.operation { XCTFail("TBZ must stay a branch") }
        XCTAssertTrue(function.phis.contains { phi in
            guard phi.blockAddress == 0x6010, case .register(name: "x4", _) = phi.destination else { return false }
            return phi.incoming.count == 2
        }, "x4 joins at the TBZ target: \(function.phis.map { "\($0.blockAddress): \($0.destination)" })")
    }

    /// DP01 #634: `fmov d0, d1` in a region writes the low 64 bits of v0 and
    /// zeroes bits 64-127; it must not copy the whole 128-bit register.
    func testScalarViewFMOVZeroExtendsInsteadOfCopyingTheVector() throws {
        let text: [(String, String)] = [
            ("mov", "x3, #0x4"), ("ldr", "q1, [x1]"), ("fmov", "d0, d1"), ("str", "q0, [x2]"),
            ("fmov", "x5, d1"), ("subs", "x3, x3, #0x1"), ("b.ne", "0x7004"), ("ret", ""),
        ]
        let rows = text.enumerated().map { index, pair in
            InstructionRow(address: 0x7000 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                           operands: pair.1, hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder().buildFunction(name: "fmov_view", startAddress: 0x7000, instructions: rows)
        XCTAssertTrue(function.instructions.contains { $0.memoryAccess?.byteWidth == 16 }, "region path claimed it")
        let move = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7008 })
        guard case let .assign(.register(name: "v0", _), source) = move.operation,
              case .unary("(uint64_t)", .register(name: "v1", _)) = source else {
            return XCTFail("fmov d0, d1 must be a zero-extended low-64 copy: \(move.operation)")
        }
        let toGPR = try XCTUnwrap(function.instructions.first { $0.source.address == 0x7010 })
        guard case .assign(.register(name: "x5", _), .unary("(uint64_t)", .register(name: "v1", _))) = toGPR.operation else {
            return XCTFail("fmov x5, d1 reads the low 64 bits: \(toGPR.operation)")
        }
    }

    /// DP01 #605: a refused vector write must poison the overlapping D/S view.
    func testRefusedVectorWritePoisonsOverlappingScalarView() throws {
        let text: [(String, String)] = [
            ("mov", "x3, #0x4"), ("ldr", "q1, [x1]"), ("fmov", "d0, x0"),
            ("add", "v0.16b, v0.16b, v1.8h"), ("fmov", "x5, d0"), ("str", "x5, [x2]"),
            ("subs", "x3, x3, #0x1"), ("b.ne", "0x8004"), ("ret", ""),
        ]
        let rows = text.enumerated().map { index, pair in
            InstructionRow(address: 0x8000 + UInt64(index * 4), bytes: "", mnemonic: pair.0,
                           operands: pair.1, hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder().buildFunction(name: "view_poison", startAddress: 0x8000, instructions: rows)
        XCTAssertTrue(function.instructions.contains { $0.memoryAccess?.byteWidth == 16 }, "region path claimed it")
        let refused = try XCTUnwrap(function.instructions.first { $0.source.address == 0x800c })
        guard case .unknown = refused.operation else { return XCTFail("malformed add must be refused") }
        let read = try XCTUnwrap(function.instructions.first { $0.source.address == 0x8010 })
        guard case let .assign(_, .unary("(uint64_t)", value)) = read.operation else {
            return XCTFail("fmov x5, d0: \(read.operation)")
        }
        guard case .unknown = value else {
            return XCTFail("the D view after a refused vector write must be unavailable, not \(value)")
        }
    }

    func testMixedScalarCallResultsDoNotBorrowFirstProducerAtRegionJoin() throws {
        func row(_ address: UInt64, _ mnemonic: String, _ operands: String = "") -> InstructionRow {
            .init(address: address, bytes: "", mnemonic: mnemonic, operands: operands,
                  hasBreakpoint: false, comment: nil)
        }
        // Terminal no-return edge admits an acyclic region. The independent
        // v2 row is unchanged by the calls and keeps this on the vector route.
        for firstIsDouble in [true, false] {
            let rows = [
                row(0xb000, "cbz", "x3, 0xb024"),
                row(0xb004, "movi", "v2.16b, #1"),
                row(0xb008, "cbz", "x4, 0xb014"),
                row(0xb00c, "bl", firstIsDouble ? "_sqrt" : "_sqrtf"),
                row(0xb010, "b", "0xb018"),
                row(0xb014, "bl", firstIsDouble ? "_sqrtf" : "_sqrt"),
                row(0xb018, "str", "d0, [x19]"),
                row(0xb01c, "str", "s0, [x19, #8]"),
                row(0xb020, "ret"), row(0xb024, "bl", "___stack_chk_fail")
            ]
            let function = try XCTUnwrap(MacIRBuilder().buildGeneralVectorRegion(
                name: "mixed_scalar_join", startAddress: 0xb000, rows: rows,
                initialState: BuilderState(), hasExternalFacts: false, isVariadic: false))
            XCTAssertTrue(function.instructions.contains { $0.source.address == 0xb004 && $0.neonImmediate != nil })
            for address: UInt64 in [0xb018, 0xb01c] {
                let operation = try XCTUnwrap(function.instructions.first { $0.source.address == address }?.operation)
                if case .unknown = operation { continue }
                XCTAssertTrue("\(operation)".contains("unavailable"),
                              "joined store borrowed one call result: \(operation)")
            }
        }
    }

}
