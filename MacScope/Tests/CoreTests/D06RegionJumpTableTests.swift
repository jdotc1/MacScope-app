import Foundation
import XCTest
@testable import MacScope

final class D06RegionJumpTableTests: XCTestCase {
    private func fixture() -> [InstructionRow] {
        let assembly = [
            ("mov", "w3, w0"), ("cmp", "w3, #1"), ("b.hi", "0x1040"),
            ("mov", "w8, w3"), ("adr", "x9, 0x2000"), ("adr", "x10, 0x1024"),
            ("ldrb", "w11, [x9, x8]"), ("add", "x10, x10, x11, lsl #2"), ("br", "x10"),
            ("add", "v0.8h, v0.8h, v1.8h"), ("b", "0x1034"),
            ("eor", "v0.16b, v0.16b, v2.16b"), ("nop", ""),
            ("subs", "w4, w4, #1"), ("b.ne", "0x1004"), ("b", "0x1040"), ("ret", "")
        ]
        return assembly.enumerated().map { i, row in
            InstructionRow(address: 0x1000 + UInt64(i * 4), bytes: "", mnemonic: row.0,
                           operands: row.1, hasBreakpoint: false, comment: nil)
        }
    }

    private func resolve(_ rows: [InstructionRow], bytes: [UInt8] = [0, 2]) -> [UInt64: [UInt64]] {
        JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
            guard address >= 0x2000, let offset = Int(exactly: address - 0x2000),
                  offset <= bytes.count, count <= bytes.count - offset else { return nil }
            return Data(bytes[offset..<offset + count])
        }, codeRange: .init(lowerBound: 0x1000, upperBound: 0x1044))
    }

    private func region(_ rows: [InstructionRow], _ tables: [UInt64: [UInt64]]) -> MacIRFunction? {
        MacIRBuilder().buildGeneralVectorRegion(name: "region", startAddress: 0x1000,
            rows: rows, initialState: BuilderState(parameters: []), jumpTables: tables,
            hasExternalFacts: false, isVariadic: false)
    }

    func testResolvedSwitchInsideVectorLoopPreservesTargetsAndJoinPhis() throws {
        let rows = fixture()
        let tables = resolve(rows)
        XCTAssertEqual(tables[0x1020], [0x1024, 0x102c])
        let function = try XCTUnwrap(region(rows, tables))
        guard case let .switchDispatch(selector, cases, defaultTarget) = function.instructions[8].operation else {
            return XCTFail("BR must become an explicit switch")
        }
        XCTAssertEqual(cases.map(\.target), [.immediate(0x1024), .immediate(0x102c)])
        XCTAssertEqual(defaultTarget, .immediate(0x1040))
        XCTAssertFalse(selector.description.contains("unavailable"))
        XCTAssertNotNil(function.instructions[9].neonLaneOp)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let dispatch = try XCTUnwrap(cfg.blocks.first { $0.instructionRange.contains(8) })
        XCTAssertEqual(Set(dispatch.successors.map { function.instructions[cfg.blocks[$0].startIndex].source.address }),
                       [0x1024, 0x102c, 0x1040])
        let phi = try XCTUnwrap(function.phis.first { $0.blockAddress == 0x1034 && $0.bitWidth == 128 })
        XCTAssertEqual(Set(phi.incoming.map(\.machineAddress)), [0x1028, 0x1030])
        let built = MacIRBuilder().buildFunction(name: "general", jumpTables: tables, instructions: rows)
        XCTAssertNotNil(built.instructions.first { $0.source.address == 0x1024 }?.neonLaneOp,
                        "The public builder must route the resolved table into the region")
    }

    func testUnresolvedPartialEmptyAndOutOfFunctionTablesRefuseRegion() {
        let rows = fixture()
        XCTAssertNil(region(rows, [:]))
        XCTAssertNil(region(rows, [0x1020: []]))
        XCTAssertNil(region(rows, [0x1020: [0x1024]]))
        XCTAssertNil(region(rows, [0x1020: [0x1024, 0x1044]]))
        XCTAssertNil(region(rows, [0x1020: [0x1024, 0x102d]]))
        XCTAssertTrue(resolve(rows, bytes: [0]).isEmpty)
        XCTAssertTrue(resolve(rows, bytes: [0, 255]).isEmpty)
    }

    func testMissingBoundsAndUnsupportedIndirectControlRefuseRegion() {
        var rows = fixture()
        rows[1].mnemonic = "nop"; rows[1].operands = ""
        XCTAssertNil(region(rows, [0x1020: [0x1024, 0x102c]]))
        rows = fixture(); rows[8].mnemonic = "braa"; rows[8].operands = "x10, x11"
        XCTAssertNil(region(rows, [0x1020: [0x1024, 0x102c]]))
    }

    func testSwitchEdgeCannotBypassSelectorGuard() {
        let rows = fixture()
        XCTAssertNil(region(rows, [0x1020: [0x1010, 0x102c]]))
    }

    func testReverseAddressCaseWithUnvisitedPredecessorRefuses() throws {
        let assembly = [
            ("b", "0x1010"), ("add", "v0.8h, v0.8h, v1.8h"), ("b", "0x1030"), ("ret", ""),
            ("cmp", "w0, #1"), ("b.hi", "0x1038"), ("mov", "w8, w0"),
            ("adr", "x9, 0x2000"), ("adr", "x10, 0x1004"), ("ldrb", "w11, [x9, x8]"),
            ("add", "x10, x10, x11, lsl #2"), ("br", "x10"),
            ("subs", "w4, w4, #1"), ("b.ne", "0x1010"), ("ret", "")
        ]
        let rows = assembly.enumerated().map { i, row in
            InstructionRow(address: 0x1000 + UInt64(i * 4), bytes: "", mnemonic: row.0,
                           operands: row.1, hasBreakpoint: false, comment: nil)
        }
        let tables: [UInt64: [UInt64]] = [0x102c: [0x1004, 0x100c]]
        XCTAssertNotNil(MacIRBuilder.generalVectorSwitches(rows, jumpTables: tables))
        XCTAssertNil(region(rows, tables), "Do not merge unvisited predecessor vector state as entry state")
    }

    func testClampCapturesPostSelectValueAndRejectsIndirectGuardBypass() throws {
        var rows = fixture()
        rows[2].mnemonic = "csel"; rows[2].operands = "w3, w3, wzr, ls"
        let tables: [UInt64: [UInt64]] = [0x1020: [0x1024, 0x102c]]
        let function = try XCTUnwrap(region(rows, tables))
        guard case let .switchDispatch(selector, _, defaultTarget) = function.instructions[8].operation else {
            return XCTFail("clamped switch missing")
        }
        XCTAssertNil(defaultTarget)
        XCTAssertFalse(selector.description.contains("unavailable"))
        // CSEL dominates BR but does not establish bounds if an indirect edge
        // bypasses the CMP whose NZCV it consumes.
        XCTAssertNil(region(rows, [0x1020: [0x1008, 0x102c]]))
    }

    func testBitBranchesRetainBothEdgesInSwitchRegion() throws {
        for mnemonic in ["tbz", "tbnz"] {
            var rows = fixture()
            rows[12].mnemonic = mnemonic; rows[12].operands = "w5, #3, 0x1040"
            let function = try XCTUnwrap(region(rows, resolve(rows)))
            guard case .conditionalBranch = function.instructions[12].operation else {
                return XCTFail("Bit branch cannot become unknown data or fallthrough")
            }
            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
            let block = try XCTUnwrap(cfg.blocks.first { $0.instructionRange.contains(12) })
            XCTAssertEqual(Set(block.successors.map { function.instructions[cfg.blocks[$0].startIndex].source.address }),
                           [0x1034, 0x1040])
        }
    }

    func testUnsupportedVectorRowRemainsExplicitUnknown() throws {
        var rows = fixture()
        rows[9].mnemonic = "not_supported"; rows[9].operands = "v0.8h, v1.8h"
        let function = try XCTUnwrap(region(rows, resolve(rows)))
        guard case let .unknown(_, inputs, mnemonic, _) = function.instructions[9].operation else {
            return XCTFail("Refused data row must remain present")
        }
        XCTAssertEqual(mnemonic, "not_supported")
        XCTAssertNotNil(inputs)
        guard case .switchDispatch = function.instructions[8].operation else { return XCTFail("Control lost") }
    }

    // Complete real symbol bytes, not a crafted dispatch. The supplied resolver
    // local proof alone cannot handle this tail; the CFG range extension must.
    func testRealWitnessRangeProofPreservesUnknownRowsAndInteriorReturns() throws {
        let hex = "282440a90c5962f82a5962f8280840f90b5962f8680040f9290000f01f4000716b050054e087036f6d7e9a52a10d024e2d6d8b52a20d024e23a142fd8481df0c468540fc678540fc0710272e0610262ed0c0610ed1c0614ef0a0620ef1a0624e108e110fe784674ee7d0634f308e114fc684664ec6d0734f1112242ef210242ed310242e1012252ee710252ec410252e452a212ee628212e272a212e102a212e712a212e8428212eb238064ef338104e343a044e12419f4c0d4000511f7c0071e0030daac8fbff5402000014ed0300aaad0500716b0700548081400c420140fd630140fde487036f8310232e8210222e6a7e9a52440d024e45c0640e44c0644e2a6d8b52460d024e65a0660e64a0664ea58c110f858c114f6384634e24a142fd63d0644f4284624e42d0744fa610202e6410202e4710202eb010212e6310212e5110212e8428212e6328212e8038030e8378030ec628212e102a212ec138100ec478100ee628212e272a212ec238070ec578070e290000f0299915918a0000102b696d384a090b8b40011fd6094900912039000d093d00912035000d093100912031000d09250091202d000d091900912029000d090d00912025000d0021000dc0035fd609a900912339000d099d00912335000d099100912331000d09850091232d000d097900912329000d096d00912325000d096100912321000d0041000cc0035fd6"
        let chars = Array(hex)
        let bytes = Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...$0+1]), radix: 16)!
        })
        let rows = ARM64Decoder().decode(bytes, baseAddress: 0x536c0,
            maxInstructionCount: bytes.count / 4).map {
            InstructionRow(address: $0.address, bytes: $0.byteText, mnemonic: $0.mnemonic,
                operands: $0.operands, hasBreakpoint: false, comment: $0.comment)
        }
        XCTAssertEqual(rows.count, 129)
        XCTAssertEqual(rows.filter { $0.mnemonic == "br" }.map(\.address), [0x53848])
        XCTAssertNil(JumpTableResolver.proveSelector(rows: rows, dispatchIndex: 98))
        XCTAssertNil(region(rows, [:]))
        // A partial caller-supplied table still refuses after general range recovery.
        XCTAssertNil(region(rows, [0x53848: Array(repeating: 0x5384c, count: 14)]))
        let tableBytes: [UInt8] = [12, 10, 8, 6, 4, 2, 0, 28, 26, 24, 22, 20, 18, 16, 14]
        let tables = JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
            guard address >= 0x5a566, address - 0x5a566 < UInt64(tableBytes.count), count == 1 else { return nil }
            return Data([tableBytes[Int(address - 0x5a566)]])
        }, codeRange: .init(lowerBound: 0x536c0, upperBound: 0x538c4))
        XCTAssertEqual(tables[0x53848], tableBytes.map { 0x5384c + UInt64($0) * 4 })
        let lifted = try XCTUnwrap(region(rows, tables))
        // The fourteen selected-element ST3 stores are now typed. Preserve
        // every switch edge and both interior returns while lifting them.
        let refused = lifted.instructions.filter { if case .unknown = $0.operation { return true }; return false }
        XCTAssertEqual(refused.count, 0, refused.map { "\($0.source.address): \($0.source.mnemonic) \($0.source.operands)" }.joined(separator: "\n"))
        XCTAssertEqual(lifted.instructions.filter { if case .returnValue = $0.operation { return true }; return false }.count, 2)
        let output = PseudocodePrinter().print(function: lifted).text
        XCTAssertFalse(output.contains("__unavailable_cfg_phi"))
        XCTAssertTrue(output.contains("switch ("))
        XCTAssertEqual(output.components(separatedBy: "\n").filter { $0.contains("__unknown") }.count, 0)
        // Keep the explicit legacy fallback comparison independently of the selected mode.
        let legacyFunction = MacIRBuilder(ssaEnabled: false).buildFunction(name: "real_witness", instructions: rows)
        XCTAssertEqual(PseudocodePrinter().print(function: legacyFunction).text.components(separatedBy: "\n")
            .filter { $0.contains("__unknown") }.count, 81)
        let function = MacIRBuilder().buildFunction(name: "real_witness", instructions: rows)
        // Without supplied table targets, legacy refuses the 81 vector rows with
        // the whole region. SSA lifts their row-local effects independently; its
        // unresolved indirect exit must remain a refusal, not an invented switch.
        XCTAssertEqual(PseudocodePrinter().print(function: function).text.components(separatedBy: "\n")
            .filter { $0.contains("__unknown") }.count, SSAPropertyAssertions.enabled ? 0 : 81)
        if SSAPropertyAssertions.enabled {
            XCTAssertTrue(function.refusals.contains { $0.reason == .unresolvedIndirectBranch })
            XCTAssertTrue(function.instructions.contains {
                guard $0.source.address == 0x53848,
                      case .intrinsic(_, "branch_register", _) = $0.operation else { return false }
                return true
            })
            XCTAssertFalse(function.instructions.contains {
                if case .switchDispatch = $0.operation { return true }
                return false
            })
            XCTAssertEqual(function.instructions.filter {
                if case .returnValue = $0.operation { return true }
                return false
            }.count, 2)
        }
    }
    // Retained instruction encodings and table entries; no mnemonic-only fixture.
    private func overwrittenBaseRows(_ hex: String, at address: UInt64) throws -> [InstructionRow] {
        let bytes = try hex.split(separator: " ").map { try XCTUnwrap(UInt8($0, radix: 16)) }
        return ARM64Decoder().decode(Data(bytes), baseAddress: address,
            maxInstructionCount: bytes.count / 4).map { InstructionRow(decoded: $0) }
    }

    private func resolveOverwrittenBase(_ rows: [InstructionRow], table: UInt64,
        entries: [UInt8], codeStart: UInt64, codeEnd: UInt64) -> [UInt64: [UInt64]] {
        JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
            guard count == 1, address >= table,
                  address - table < UInt64(entries.count) else { return nil }
            return Data([entries[Int(address - table)]])
        }, codeRange: .init(lowerBound: codeStart, upperBound: codeEnd))
    }

    func testOverwrittenADRPBaseAt45e4UsesNearestDefinition() throws {
        let rows = try overwrittenBaseRows("09 19 00 51 3f 25 00 71 08 04 00 54 08 00 00 90 08 71 1e 91 68 02 00 f9 a8 02 00 90 08 91 1e 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6", at: 0x45b8)
        let entries: [UInt8] = [63, 0, 69, 45, 48, 42, 0, 45, 48, 42]
        let targets = resolveOverwrittenBase(rows, table: 0x587a4, entries: entries,
            codeStart: 0x417c, codeEnd: 0x4744)
        XCTAssertEqual(targets[0x45e4], entries.map { 0x45e8 + UInt64($0) * 4 })
    }

    func testOverwrittenADRPBaseAt4630UsesNearestDefinition() throws {
        let rows = try overwrittenBaseRows("09 19 00 51 3f 25 00 71 88 03 00 54 08 00 00 90 08 71 1e 91 68 02 00 f9 a8 02 00 90 08 e1 1e 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6", at: 0x4604)
        let entries: [UInt8] = [56, 0, 59, 35, 38, 32, 0, 35, 38, 32]
        let targets = resolveOverwrittenBase(rows, table: 0x587b8, entries: entries,
            codeStart: 0x417c, codeEnd: 0x4744)
        XCTAssertEqual(targets[0x4630], entries.map { 0x4634 + UInt64($0) * 4 })
    }

    func testOverwrittenADRPBaseAt5d74UsesNearestDefinition() throws {
        let rows = try overwrittenBaseRows("09 19 00 51 3f 25 00 71 08 04 00 54 08 00 00 90 08 b1 3c 91 68 02 00 f9 88 02 00 f0 08 21 20 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6", at: 0x5d48)
        let entries: [UInt8] = [63, 0, 69, 45, 48, 42, 0, 45, 48, 42]
        let targets = resolveOverwrittenBase(rows, table: 0x58808, entries: entries,
            codeStart: 0x590c, codeEnd: 0x5ed4)
        XCTAssertEqual(targets[0x5d74], entries.map { 0x5d78 + UInt64($0) * 4 })
    }

    func testOverwrittenADRPBaseAt5dc0UsesNearestDefinition() throws {
        let rows = try overwrittenBaseRows("09 19 00 51 3f 25 00 71 88 03 00 54 08 00 00 90 08 b1 3c 91 68 02 00 f9 88 02 00 f0 08 71 20 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6", at: 0x5d94)
        let entries: [UInt8] = [56, 0, 59, 35, 38, 32, 0, 35, 38, 32]
        let targets = resolveOverwrittenBase(rows, table: 0x5881c, entries: entries,
            codeStart: 0x590c, codeEnd: 0x5ed4)
        XCTAssertEqual(targets[0x5dc0], entries.map { 0x5dc4 + UInt64($0) * 4 })
    }

    func testOverwrittenADRPBaseAt374f4UsesNearestDefinition() throws {
        let rows = try overwrittenBaseRows("09 00 00 90 29 51 1d 91 89 0a 00 f9 69 42 40 b9 2a 19 00 51 5f 25 00 71 08 07 00 54 09 01 00 d0 29 e9 1c 91 8b 00 00 10 2c 69 6a 38 6b 09 0c 8b 60 01 1f d6", at: 0x374c4)
        let entries: [UInt8] = [37, 0, 43, 25, 31, 19, 0, 25, 31, 19]
        let targets = resolveOverwrittenBase(rows, table: 0x5973a, entries: entries,
            codeStart: 0x37440, codeEnd: 0x37740)
        XCTAssertEqual(targets[0x374f4], entries.map { 0x374f8 + UInt64($0) * 4 })
    }

    func testOverwrittenADRPBaseAt37534UsesNearestDefinition() throws {
        let rows = try overwrittenBaseRows("08 00 00 b0 08 71 2a 91 88 0a 00 f9 68 42 40 b9 09 19 00 51 3f 25 00 71 48 06 00 54 08 01 00 d0 08 c1 1c 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6", at: 0x37504)
        let entries: [UInt8] = [24, 0, 30, 12, 18, 6, 0, 12, 18, 6]
        let targets = resolveOverwrittenBase(rows, table: 0x59730, entries: entries,
            codeStart: 0x37440, codeEnd: 0x37740)
        XCTAssertEqual(targets[0x37534], entries.map { 0x37538 + UInt64($0) * 4 })
    }

    func testOverwrittenADRPBaseRejectsUnboundedIndex() throws {
        // CMP -> NOP: stale NZCV cannot authorize the table.
        let hex = "09 19 00 51 3f 25 00 71 08 04 00 54 08 00 00 90 08 71 1e 91 68 02 00 f9 a8 02 00 90 08 91 1e 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6".replacingOccurrences(of: "3f 25 00 71", with: "1f 20 03 d5")
        let rows = try overwrittenBaseRows(hex, at: 0x45b8)
        XCTAssertTrue(resolveOverwrittenBase(rows, table: 0x587a4, entries: [63, 0, 69, 45, 48, 42, 0, 45, 48, 42],
            codeStart: 0x417c, codeEnd: 0x4744).isEmpty)
    }

    func testOverwrittenADRPBaseRejectsUnboundedUpperIndexBits() throws {
        // SUB W9 -> SUB X9: CMP W9 does not bound the upper half of X9.
        let hex = "09 19 00 51 3f 25 00 71 08 04 00 54 08 00 00 90 08 71 1e 91 68 02 00 f9 a8 02 00 90 08 91 1e 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6".replacingOccurrences(of: "09 19 00 51", with: "09 19 00 d1")
        let rows = try overwrittenBaseRows(hex, at: 0x45b8)
        XCTAssertTrue(resolveOverwrittenBase(rows, table: 0x587a4, entries: [63, 0, 69, 45, 48, 42, 0, 45, 48, 42],
            codeStart: 0x417c, codeEnd: 0x4744).isEmpty)
    }

    func testOverwrittenADRPBaseRejectsWrongEntryWidth() throws {
        // LDRB W11,[X8,X9] -> LDRH W11,[X8,X9,LSL #1]. The byte
        // table reader must not be reused as though this were a byte load.
        // Legitimate halfword backing remains supported; this reader supplies
        // only byte-width records and must refuse the two-byte request.
        let hex = "09 19 00 51 3f 25 00 71 08 04 00 54 08 00 00 90 08 71 1e 91 68 02 00 f9 a8 02 00 90 08 91 1e 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6".replacingOccurrences(of: "0b 69 69 38", with: "0b 79 69 78")
        let rows = try overwrittenBaseRows(hex, at: 0x45b8)
        XCTAssertEqual(rows[9].mnemonic, "ldrh")
        XCTAssertEqual(rows[9].operands, "w11, [x8, x9, lsl #1]")
        XCTAssertTrue(resolveOverwrittenBase(rows, table: 0x587a4, entries: [63, 0, 69, 45, 48, 42, 0, 45, 48, 42],
            codeStart: 0x417c, codeEnd: 0x4744).isEmpty)
    }

    func testOverwrittenADRPBaseRejectsInterveningBaseClobber() throws {
        // Insert MOV X8,X0 after the nearest ADRP+ADD, before ADR/load.
        // The old and new table bases still have the recognized shapes; only
        // the intervening non-role write breaks the load's reaching base.
        let hex = "09 19 00 51 3f 25 00 71 08 04 00 54 08 00 00 90 08 71 1e 91 68 02 00 f9 a8 02 00 90 08 91 1e 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6".replacingOccurrences(of: "08 91 1e 91",
            with: "08 91 1e 91 e8 03 00 aa")
        let rows = try overwrittenBaseRows(hex, at: 0x45b8)
        XCTAssertEqual(rows[8].mnemonic, "mov")
        XCTAssertEqual(rows[8].operands, "x8, x0")
        XCTAssertTrue(resolveOverwrittenBase(rows, table: 0x587a4,
            entries: [63, 0, 69, 45, 48, 42, 0, 45, 48, 42],
            codeStart: 0x417c, codeEnd: 0x4744).isEmpty)
    }

    func testOverwrittenADRPBaseRejectsGuardBypass() throws {
        // B at 0x45b4 enters the nearest ADRP at 0x45d0, bypassing both
        // SUB W9 and CMP/B.HI. Original dispatch addresses are unchanged.
        let rows = try overwrittenBaseRows("07 00 00 14 09 19 00 51 3f 25 00 71 08 04 00 54 08 00 00 90 08 71 1e 91 68 02 00 f9 a8 02 00 90 08 91 1e 91 8a 00 00 10 0b 69 69 38 4a 09 0b 8b 40 01 1f d6", at: 0x45b4)
        XCTAssertEqual(rows[0].mnemonic, "b")
        XCTAssertTrue(rows[0].operands.contains("45d0"))
        XCTAssertTrue(resolveOverwrittenBase(rows, table: 0x587a4,
            entries: [63, 0, 69, 45, 48, 42, 0, 45, 48, 42],
            codeStart: 0x417c, codeEnd: 0x4744).isEmpty)
    }

    func testOverwrittenADRPBeforeGuardMustReachEveryDispatchPathInBothModes() {
        // Both paths obey the selector guard. Only X1 > 0 skips the new base.
        let assembly: [(String, String, String)] = [
            ("08 00 00 b0", "adrp", "x8, 0x2000"),
            ("3f 00 00 f1", "cmp", "x1, #0"),
            ("48 00 00 54", "b.hi", "0x1010"),
            ("08 00 00 d0", "adrp", "x8, 0x3000"),
            ("1f 04 00 f1", "cmp", "x0, #1"),
            ("88 00 00 54", "b.hi", "0x1024"),
            ("09 79 60 f8", "ldr", "x9, [x8, x0, lsl #3]"),
            ("20 01 1f d6", "br", "x9"),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")
        ]
        let rows = assembly.enumerated().map { index, row in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: row.0,
                mnemonic: row.1, operands: row.2, hasBreakpoint: false, comment: nil)
        }
        let backing: [UInt64: [UInt8]] = [
            0x2000: [0x20, 0x10, 0, 0, 0, 0, 0, 0],
            0x2008: [0x24, 0x10, 0, 0, 0, 0, 0, 0],
            0x3000: [0x24, 0x10, 0, 0, 0, 0, 0, 0],
            0x3008: [0x20, 0x10, 0, 0, 0, 0, 0, 0]
        ]
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                func resolved(_ input: [InstructionRow]) -> [UInt64: [UInt64]] {
                    JumpTableResolver().resolve(instructions: input, readBytes: { address, count in
                        guard count == 8, let bytes = backing[address] else { return nil }
                        return Data(bytes)
                    }, codeRange: .init(lowerBound: 0x1000, upperBound: 0x1028))
                }
                // X0 = 0, X1 = 1 dispatches to 0x1020 from the old table.
                // X0 = 0, X1 = 0 dispatches to 0x1024 from the new table.
                XCTAssertNil(resolved(rows)[0x101c],
                    "The nearest lexical ADRP is not an all-path base; ssa=\(enabled)")
                var straightLine = rows
                straightLine[2] = InstructionRow(address: 0x1008, bytes: "1f 20 03 d5",
                    mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil)
                XCTAssertEqual(resolved(straightLine)[0x101c], [0x1024, 0x1020],
                    "A dominating overwrite must remain supported; ssa=\(enabled)")
            }
        }
    }

    private func allPathRows(_ assembly: [(String, String, String)], at start: UInt64 = 0x1000) -> [InstructionRow] {
        assembly.enumerated().map { index, row in
            InstructionRow(address: start + UInt64(index * 4), bytes: row.0,
                mnemonic: row.1, operands: row.2, hasBreakpoint: false, comment: nil)
        }
    }

    private func allPathOverwriteRows(_ bytes: String = "48 00 00 54",
        mnemonic: String = "b.hi", target: String = "0x1010") -> [InstructionRow] {
        allPathRows([
            ("08 00 00 b0", "adrp", "x8, 0x2000"),
            ("3f 00 00 f1", "cmp", "x1, #0"),
            (bytes, mnemonic, target),
            ("08 00 00 d0", "adrp", "x8, 0x3000"),
            ("1f 04 00 f1", "cmp", "x0, #1"),
            ("88 00 00 54", "b.hi", "0x1024"),
            ("09 79 60 f8", "ldr", "x9, [x8, x0, lsl #3]"),
            ("20 01 1f d6", "br", "x9"),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")
        ])
    }

    private func allPathAbsoluteTables(_ rows: [InstructionRow],
        tables: [UInt64: [UInt8]] = [0x2000: [0x20, 0x10, 0, 0, 0, 0, 0, 0, 0x24, 0x10, 0, 0, 0, 0, 0, 0],
            0x3000: [0x24, 0x10, 0, 0, 0, 0, 0, 0, 0x20, 0x10, 0, 0, 0, 0, 0, 0]],
        codeStart: UInt64 = 0x1000, codeEnd: UInt64 = 0x1028) -> [UInt64: [UInt64]] {
        JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
            guard count == 8 else { return nil }
            for (base, bytes) in tables {
                guard address >= base, let offset = Int(exactly: address - base),
                      offset <= bytes.count, count <= bytes.count - offset else { continue }
                return Data(bytes[offset..<offset + count])
            }
            return nil
        }, codeRange: .init(lowerBound: codeStart, upperBound: codeEnd))
    }

    func testPreGuardIntermediateEntryCannotBypassSelectedADRPInBothModes() {
        // The taken edge enters a NOP before CMP, not CMP itself. A >= guard fix is insufficient.
        let rows = allPathRows([
            ("08 00 00 b0", "adrp", "x8, 0x2000"),
            ("3f 00 00 f1", "cmp", "x1, #0"),
            ("48 00 00 54", "b.hi", "0x1010"),
            ("08 00 00 d0", "adrp", "x8, 0x3000"),
            ("1f 20 03 d5", "nop", ""),
            ("1f 04 00 f1", "cmp", "x0, #1"),
            ("88 00 00 54", "b.hi", "0x1028"),
            ("09 79 60 f8", "ldr", "x9, [x8, x0, lsl #3]"),
            ("20 01 1f d6", "br", "x9"),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")
        ])
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertNil(allPathAbsoluteTables(rows,
                    tables: [0x2000: [0x24, 0x10, 0, 0, 0, 0, 0, 0, 0x28, 0x10, 0, 0, 0, 0, 0, 0],
                        0x3000: [0x28, 0x10, 0, 0, 0, 0, 0, 0, 0x24, 0x10, 0, 0, 0, 0, 0, 0]],
                    codeEnd: 0x102c)[0x1020], "Pre-guard intermediate bypass; ssa=\(enabled)")
            }
        }
    }

    func testEntryAtIndexedLoadCannotBypassGuardAndBaseInBothModes() {
        let rows = allPathOverwriteRows("88 00 00 54", target: "0x1018")
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertNil(allPathAbsoluteTables(rows)[0x101c], "Inclusive load endpoint; ssa=\(enabled)")
            }
        }
    }

    func testEntryBeforeOrAtSelectedADRPStillExecutesAllRequiredDefinitionsInBothModes() {
        // The target is exactly the selected definition, not its successor.
        let rows = allPathOverwriteRows("28 00 00 54", target: "0x100c")
        let beforeRows = allPathRows([
            ("08 00 00 b0", "adrp", "x8, 0x2000"),
            ("3f 00 00 f1", "cmp", "x1, #0"),
            ("28 00 00 54", "b.hi", "0x100c"),
            ("1f 20 03 d5", "nop", ""),
            ("08 00 00 d0", "adrp", "x8, 0x3000"),
            ("1f 04 00 f1", "cmp", "x0, #1"),
            ("88 00 00 54", "b.hi", "0x1028"),
            ("09 79 60 f8", "ldr", "x9, [x8, x0, lsl #3]"),
            ("20 01 1f d6", "br", "x9"),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")
        ])
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertEqual(allPathAbsoluteTables(rows)[0x101c], [0x1024, 0x1020],
                    "Both paths execute the selected ADRP and guard; ssa=\(enabled)")
                XCTAssertEqual(allPathAbsoluteTables(beforeRows,
                    tables: [0x2000: [0x24, 0x10, 0, 0, 0, 0, 0, 0, 0x28, 0x10, 0, 0, 0, 0, 0, 0],
                        0x3000: [0x28, 0x10, 0, 0, 0, 0, 0, 0, 0x24, 0x10, 0, 0, 0, 0, 0, 0]],
                    codeEnd: 0x102c)[0x1020], [0x1028, 0x1024],
                    "Entry before the selected ADRP still executes it; ssa=\(enabled)")
            }
        }
    }

    func testDominatingOverwriteNOPControlPreservesOrderedTargetsInBothModes() {
        let rows = allPathOverwriteRows("1f 20 03 d5", mnemonic: "nop", target: "")
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertEqual(allPathAbsoluteTables(rows)[0x101c], [0x1024, 0x1020],
                    "Do not compare only an unordered target set; ssa=\(enabled)")
            }
        }
    }

    func testPreGuardEntryCannotBypassSelectedBaseADDInBothModes() {
        let rows = allPathRows([
            ("08 00 00 d0", "adrp", "x8, 0x3000"),
            ("3f 00 00 f1", "cmp", "x1, #0"),
            ("48 00 00 54", "b.hi", "0x1010"),
            ("08 41 00 91", "add", "x8, x8, #16"),
            ("1f 04 00 f1", "cmp", "x0, #1"),
            ("88 00 00 54", "b.hi", "0x1024"),
            ("09 79 60 f8", "ldr", "x9, [x8, x0, lsl #3]"),
            ("20 01 1f d6", "br", "x9"),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")
        ])
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertNil(allPathAbsoluteTables(rows,
                    tables: [0x3000: [0x20, 0x10, 0, 0, 0, 0, 0, 0, 0x24, 0x10, 0, 0, 0, 0, 0, 0],
                        0x3010: [0x24, 0x10, 0, 0, 0, 0, 0, 0, 0x20, 0x10, 0, 0, 0, 0, 0, 0]])[0x101c],
                    "ADRP executes on both paths but ADD does not; ssa=\(enabled)")
            }
        }
    }

    func testPreGuardEntryCannotBypassSelectedAnchorInBothModes() {
        let rows = allPathRows([
            ("08 00 00 b0", "adrp", "x8, 0x2000"),
            ("3f 00 00 f1", "cmp", "x1, #0"),
            ("48 00 00 54", "b.hi", "0x1010"),
            ("ca 00 00 10", "adr", "x10, 0x1024"),
            ("1f 04 00 f1", "cmp", "x0, #1"),
            ("a8 00 00 54", "b.hi", "0x1028"),
            ("0b 69 60 38", "ldrb", "w11, [x8, x0]"),
            ("4a 09 0b 8b", "add", "x10, x10, x11, lsl #2"),
            ("40 01 1f d6", "br", "x10"),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")
        ])
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                let entries: [UInt8] = [0, 1]
                let targets = JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
                    guard count == 1, address == 0x2000 || address == 0x2001 else { return nil }
                    return Data([entries[Int(address - 0x2000)]])
                }, codeRange: .init(lowerBound: 0x1000, upperBound: 0x102c))
                XCTAssertNil(targets[0x1020], "Anchor definition is skipped on the taken path; ssa=\(enabled)")
            }
        }
    }

    func testEntryOutsideBackwardScanCannotBypassSelectedADRPInBothModes() {
        // 0xf80 + 36 * 4 = 0x1010; 31 NOPs keep the original addresses intact.
        let prefix = allPathRows([("24 00 00 14", "b", "0x1010")]
            + Array(repeating: ("1f 20 03 d5", "nop", ""), count: 31), at: 0xf80)
        let rows = prefix + allPathOverwriteRows("1f 20 03 d5", mnemonic: "nop", target: "")
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertNil(allPathAbsoluteTables(rows, codeStart: 0xf80)[0x101c],
                    "Incoming edges are not limited to the 24-row idiom scan; ssa=\(enabled)")
            }
        }
    }

    func testADRPAfterIndexedLoadIsNotItsReachingBaseInBothModes() {
        let rows = allPathRows([
            ("08 00 00 b0", "adrp", "x8, 0x2000"),
            ("1f 04 00 f1", "cmp", "x0, #1"),
            ("c8 00 00 54", "b.hi", "0x1020"),
            ("09 79 60 f8", "ldr", "x9, [x8, x0, lsl #3]"),
            ("08 00 00 d0", "adrp", "x8, 0x3000"),
            ("20 01 1f d6", "br", "x9"),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")
        ])
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertNil(allPathAbsoluteTables(rows,
                    tables: [0x2000: [0x18, 0x10, 0, 0, 0, 0, 0, 0, 0x1c, 0x10, 0, 0, 0, 0, 0, 0],
                        0x3000: [0x1c, 0x10, 0, 0, 0, 0, 0, 0, 0x18, 0x10, 0, 0, 0, 0, 0, 0]],
                    codeEnd: 0x1024)[0x1014], "The load precedes the lexical ADRP candidate; ssa=\(enabled)")
            }
        }
    }

    private func certificateAbsoluteResolution(_ rows: [InstructionRow],
        backing: [UInt64: [UInt8]] = [
            0x2000: [0x20, 0x10, 0, 0, 0, 0, 0, 0],
            0x2008: [0x24, 0x10, 0, 0, 0, 0, 0, 0],
            0x3000: [0x24, 0x10, 0, 0, 0, 0, 0, 0],
            0x3008: [0x20, 0x10, 0, 0, 0, 0, 0, 0]
        ], codeStart: UInt64 = 0x1000, codeEnd: UInt64 = 0x1028) -> JumpTableResolver.Resolution {
        JumpTableResolver().resolveWithCertificates(instructions: rows, readBytes: { address, count in
            guard count == 8, let bytes = backing[address] else { return nil }
            return Data(bytes)
        }, codeRange: .init(lowerBound: codeStart, upperBound: codeEnd))
    }

    func testCertificateRecordsOtherUnresolvedIndirectBranchCountInBothModes() {
        let closedRows = allPathOverwriteRows("1f 20 03 d5", mnemonic: "nop", target: "")
        let openRows = closedRows + [InstructionRow(address: 0x1028, bytes: "00 02 1f d6",
            mnemonic: "br", operands: "x16", hasBreakpoint: false, comment: nil)]
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                let closed = certificateAbsoluteResolution(closedRows)
                XCTAssertEqual(closed.targets[0x101c], [0x1024, 0x1020])
                XCTAssertEqual(closed.certificates[0x101c]?.otherUnresolvedIndirectBranchCount, 0)
                let open = certificateAbsoluteResolution(openRows, codeEnd: 0x102c)
                XCTAssertEqual(open.targets[0x101c], [0x1024, 0x1020])
                XCTAssertNil(open.targets[0x1028])
                XCTAssertEqual(open.certificates[0x101c]?.otherUnresolvedIndirectBranchCount, 1,
                    "Unknown X16 destinations are outside the certificate, not silently proved; ssa=\(enabled)")
                XCTAssertEqual(open.certificates[0x101c]?.protectedStartAddress, 0x100c)
                XCTAssertEqual(open.certificates[0x101c]?.protectedEndAddress, 0x101c)
            }
        }
    }

    func testOtherResolvedTableCannotEnterSelectedBaseProtectedRegionInBothModes() {
        let first = allPathOverwriteRows("1f 20 03 d5", mnemonic: "nop", target: "")
        let padding = allPathRows(Array(repeating: ("1f 20 03 d5", "nop", ""), count: 6), at: 0x1028)
        let second = allPathRows([
            ("08 00 00 f0", "adrp", "x8, 0x4000"),
            ("5f 04 00 f1", "cmp", "x2, #1"),
            ("c8 00 00 54", "b.hi", "0x1060"),
            ("09 79 62 f8", "ldr", "x9, [x8, x2, lsl #3]"),
            ("20 01 1f d6", "br", "x9"),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")
        ], at: 0x1040)
        let backing: [UInt64: [UInt8]] = [
            0x3000: [0x24, 0x10, 0, 0, 0, 0, 0, 0],
            0x3008: [0x20, 0x10, 0, 0, 0, 0, 0, 0],
            0x4000: [0x10, 0x10, 0, 0, 0, 0, 0, 0],
            0x4008: [0x20, 0x10, 0, 0, 0, 0, 0, 0]
        ]
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                let result = certificateAbsoluteResolution(first + padding + second,
                    backing: backing, codeEnd: 0x1064)
                XCTAssertNil(result.targets[0x101c], "Second table enters 0x1010 after ADRP; ssa=\(enabled)")
                XCTAssertNil(result.certificates[0x101c])
                XCTAssertEqual(result.targets[0x1050], [0x1010, 0x1020],
                    "The attacking edge must come from an actually recovered second table; ssa=\(enabled)")
                XCTAssertEqual(result.certificates[0x1050]?.otherUnresolvedIndirectBranchCount, 1)
            }
        }
    }

    func testCurrentResolvedTableCannotReenterAfterSelectedADRPInBothModes() {
        let rows = allPathOverwriteRows("1f 20 03 d5", mnemonic: "nop", target: "")
        let backing: [UInt64: [UInt8]] = [
            0x3000: [0x10, 0x10, 0, 0, 0, 0, 0, 0],
            0x3008: [0x20, 0x10, 0, 0, 0, 0, 0, 0]
        ]
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                let result = certificateAbsoluteResolution(rows, backing: backing)
                XCTAssertNil(result.targets[0x101c], "Current-table reentry is also protected; ssa=\(enabled)")
                XCTAssertNil(result.certificates[0x101c])
            }
        }
    }

    func testUnparseableDirectDestinationCannotReceiveCertificateInBothModes() {
        // The caller has supplied an unresolved textual destination for a direct B.
        // Raw branch bytes do not authorize silently ignoring that destination.
        let rows = allPathOverwriteRows("1f 20 03 d5", mnemonic: "nop", target: "")
            + [InstructionRow(address: 0x1028, bytes: "00 00 00 14", mnemonic: "b",
                operands: "_unresolved_direct_target", hasBreakpoint: false, comment: nil)]
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                let result = certificateAbsoluteResolution(rows, codeEnd: 0x102c)
                XCTAssertNil(result.targets[0x101c], "Unparseable direct target fails closed; ssa=\(enabled)")
                XCTAssertNil(result.certificates[0x101c])
            }
        }
    }

    func testDirectCallAndConsistentBranchOutsideScanCannotEnterSelectedBaseProtectedRegionInBothModes() {
        // BL is a direct transfer too; its source is outside the 24-row scan.
        for transfer in [("24 00 00 94", "bl"), ("98 04 00 54", "bc.hi")] {
            let prefix = allPathRows([(transfer.0, transfer.1, "0x1010")]
                + Array(repeating: ("1f 20 03 d5", "nop", ""), count: 31), at: 0xf80)
            let rows = prefix + allPathOverwriteRows("1f 20 03 d5", mnemonic: "nop", target: "")
            for enabled in [false, true] {
                MacIRConfiguration.$ssaOverride.withValue(enabled) {
                    let result = certificateAbsoluteResolution(rows, codeStart: 0xf80)
                    XCTAssertNil(result.targets[0x101c], "Direct \(transfer.1) enters after selected ADRP; ssa=\(enabled)")
                    XCTAssertNil(result.certificates[0x101c])
                }
            }
        }
    }

    func testOtherResolvedTableCannotBypassWZeroExtensionBeforeGuardInBothModes() {
        // Function entry reaches B, which sets literal X0=0x100000000. B's table
        // then enters A at CMP W0, skipping MOV W0,W0. The low W guard passes,
        // but A's indexed load would use the nonzero upper X0 bits.
        let rows = allPathRows([
            ("09 00 00 14", "b", "0x1020"),
            ("e0 03 00 2a", "mov", "w0, w0"),
            ("1f 00 00 71", "cmp", "w0, #0"),
            ("c8 01 00 54", "b.hi", "0x1040"),
            ("09 00 00 b0", "adrp", "x9, 0x2000"),
            ("2a 79 60 f8", "ldr", "x10, [x9, x0, lsl #3]"),
            ("40 01 1f d6", "br", "x10"),
            ("c0 03 5f d6", "ret", ""),
            ("1f 20 03 d5", "nop", ""),
            ("20 00 c0 d2", "mov", "x0, #0x100000000"),
            ("3f 00 00 f1", "cmp", "x1, #0"),
            ("c8 00 00 54", "b.hi", "0x1040"),
            ("0c 00 00 d0", "adrp", "x12, 0x3000"),
            ("8d 79 61 f8", "ldr", "x13, [x12, x1, lsl #3]"),
            ("a0 01 1f d6", "br", "x13"),
            ("c0 03 5f d6", "ret", ""),
            ("1f 20 03 d5", "nop", ""),
            ("c0 03 5f d6", "ret", "")
        ], at: 0xffc)
        let backing: [UInt64: [UInt8]] = [
            0x2000: [0x40, 0x10, 0, 0, 0, 0, 0, 0],
            0x3000: [0x04, 0x10, 0, 0, 0, 0, 0, 0]
        ]
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                let result = certificateAbsoluteResolution(rows, backing: backing,
                    codeStart: 0xffc, codeEnd: 0x1044)
                XCTAssertNil(result.targets[0x1014], "Known table edge bypasses W zero extension; ssa=\(enabled)")
                XCTAssertNil(result.certificates[0x1014])
                XCTAssertEqual(result.targets[0x1034], [0x1004])
                XCTAssertEqual(result.certificates[0x1034]?.otherUnresolvedIndirectBranchCount, 1)
                XCTAssertNil(JumpTableResolver.proveSelector(rows: rows, dispatchIndex: 6,
                    resolvedTableTargets: [0x1004]), "Selector API must also honor its supplied table edges")
                var enteringDefinition = backing
                enteringDefinition[0x3000] = [0x00, 0x10, 0, 0, 0, 0, 0, 0]
                let safe = certificateAbsoluteResolution(rows, backing: enteringDefinition,
                    codeStart: 0xffc, codeEnd: 0x1044)
                XCTAssertEqual(safe.targets[0x1014], [0x1040])
                XCTAssertEqual(safe.targets[0x1034], [0x1000])
                XCTAssertEqual(safe.certificates[0x1014]?.zeroExtensionDefinitionAddress, 0x1000)
                XCTAssertEqual(safe.certificates[0x1014]?.otherUnresolvedIndirectBranchCount, 0)
                XCTAssertEqual(safe.certificates[0x1034]?.otherUnresolvedIndirectBranchCount, 0)
            }
        }
    }

    private func symbolizedBLSelectorRows(bytes: String = "ef 03 00 94",
        operand: String = "_external_callee") -> [InstructionRow] {
        allPathRows([
            ("08 00 40 b9", "ldr", "w8, [x0]"),
            ("09 19 00 51", "sub", "w9, w8, #6"),
            ("3f 25 00 71", "cmp", "w9, #9"),
            ("a8 01 00 54", "b.hi", "0x1040"),
            ("0a 00 00 b0", "adrp", "x10, 0x2000"),
            ("8b 00 00 10", "adr", "x11, 0x1024"),
            ("4c 69 69 38", "ldrb", "w12, [x10, x9]"),
            ("6b 09 0c 8b", "add", "x11, x11, x12, lsl #2"),
            ("60 01 1f d6", "br", "x11"),
            ("00 00 80 52", "mov", "w0, #0"),
            ("c0 03 5f d6", "ret", ""),
            ("1f 20 03 d5", "nop", ""),
            ("1f 20 03 d5", "nop", ""),
            ("1f 20 03 d5", "nop", ""),
            ("1f 20 03 d5", "nop", ""),
            ("1f 20 03 d5", "nop", ""),
            ("c0 03 5f d6", "ret", ""),
            (bytes, "bl", operand),
            ("c0 03 5f d6", "ret", "")
        ])
    }

    private func symbolizedBLSelectorResolution(_ rows: [InstructionRow]) -> JumpTableResolver.Resolution {
        let entries: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        return JumpTableResolver().resolveWithCertificates(instructions: rows, readBytes: { address, count in
            guard count == 1, address >= 0x2000, address - 0x2000 < UInt64(entries.count) else { return nil }
            return Data([entries[Int(address - 0x2000)]])
        }, codeRange: .init(lowerBound: 0x1000, upperBound: 0x104c))
    }

    func testSymbolizedBLPreservesRenderedSelectorAndUnsignedSubViewInBothModes() throws {
        // At 0x1044, imm26=0x3ef reaches 0x2000. Symbol spelling is display-only.
        let rows = symbolizedBLSelectorRows()
        for enabled in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(enabled) {
                let resolution = symbolizedBLSelectorResolution(rows)
                XCTAssertEqual(resolution.targets[0x1020], Array(repeating: 0x1024, count: 10))
                XCTAssertEqual(resolution.certificates[0x1020]?.zeroExtensionDefinitionAddress, 0x1004)
                let function = MacIRBuilder(ssaEnabled: enabled).buildFunction(name: "symbolized_bl_selector",
                    jumpTables: resolution.targets, instructions: rows)
                XCTAssertEqual(function.ssaEnabled, enabled)
                if enabled { XCTAssertNotNil(function.ssaInfo) }
                let dispatch = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1020 })
                let subtraction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
                guard case let .switchDispatch(selector, _, _) = dispatch.operation,
                      case let .binary(destination, "-", left, .immediate(6)) = subtraction.operation,
                      case let .register(register, _) = destination else {
                    return XCTFail("Require actual lifted switch and SUB definitions; ssa=\(enabled)")
                }
                XCTAssertEqual(register, "w9")
                XCTAssertEqual(selector, destination, "Capture the SUB W definition, not the loaded target")
                var names = PseudocodeNameContext(function: function)
                let printer = PseudocodePrinter()
                XCTAssertEqual(printer.valueText(for: selector, names: names), "tmp1")
                XCTAssertEqual(printer.valueText(for: left, names: names), "tmp0")
                XCTAssertEqual(printer.render(operation: dispatch.operation, names: names), "switch (tmp1)")
                // Use the same actual-switch-derived context as production SSA
                // recovery; do not inject a selector or mutate the lifted IR.
                names.unsignedSelectorDestinations = Set(function.instructions.compactMap { instruction in
                    if case let .switchDispatch(value, _, _) = instruction.operation { return value }
                    return nil
                })
                XCTAssertEqual(printer.render(instruction: subtraction, names: names),
                    "tmp1 = (uint32_t)((uint32_t)(tmp0) - 0x6)")
                // Flat printing owns a different assignment presentation from
                // SSA recovery, but must retain the literal selector and its W view.
                var options = DecompilerOptions.default
                options.structureControlFlow = false
                let flat = PseudocodePrinter(options: options).print(function: function).text
                XCTAssertTrue(flat.contains("tmp1 = tmp0 - 0x6;"), flat)
                XCTAssertTrue(flat.contains("switch (tmp1) {"), flat)
                XCTAssertTrue(flat.contains("(uint32_t)(tmp1) > (uint32_t)(0x9)"), flat)
                XCTAssertFalse(flat.contains("unproven_switch_selector"), flat)
                let ordinary = printer.print(function: function).text
                XCTAssertFalse(ordinary.contains("unproven_switch_selector"), ordinary)
            }
        }
    }

    func testSymbolizedBLIntoProtectedRegionStillRefusesInBothModes() {
        // Sign-extended imm26=-12: 0x1044 - 48 = 0x1014, after selected ADRP.
        let rows = symbolizedBLSelectorRows(bytes: "f4 ff ff 97", operand: "_display_name+0x20")
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertNil(symbolizedBLSelectorResolution(rows).targets[0x1020])
                XCTAssertNil(JumpTableResolver.proveSelector(rows: rows, dispatchIndex: 8),
                    "Symbolization must not hide a direct BL entry; ssa=\(enabled)")
            }
        }
    }

    func testSymbolizedBLMissingMalformedAndWrongOpcodeBytesRefuseInBothModes() {
        for bytes in ["", "ef 03 00", "ef 03 00 94 00", "zz 03 00 94", "+f 03 00 94", "-0 03 00 94", "ef 03 00 14", "ef030094", " "] {
            let rows = symbolizedBLSelectorRows(bytes: bytes)
            for enabled in [false, true] {
                MacIRConfiguration.$ssaOverride.withValue(enabled) {
                    XCTAssertNil(symbolizedBLSelectorResolution(rows).targets[0x1020],
                        "No address authority from malformed/non-BL bytes: \(bytes); ssa=\(enabled)")
                    XCTAssertNil(JumpTableResolver.proveSelector(rows: rows, dispatchIndex: 8))
                }
            }
        }
    }

    func testBLNumericTargetMustAgreeWithBytesAndRetainsTextOnlyCompatibilityInBothModes() {
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                let expected: [UInt64] = Array(repeating: 0x1024, count: 10)
                XCTAssertEqual(symbolizedBLSelectorResolution(symbolizedBLSelectorRows(operand: "0x2000"))
                    .targets[0x1020], expected)
                XCTAssertEqual(symbolizedBLSelectorResolution(symbolizedBLSelectorRows(bytes: "", operand: "0x2000"))
                    .targets[0x1020], expected, "Existing bytes-empty numeric fixture boundary is retained")
                XCTAssertNil(symbolizedBLSelectorResolution(symbolizedBLSelectorRows(operand: "0x3000"))
                    .targets[0x1020], "Numeric text disagrees with an exact BL word; ssa=\(enabled)")
                XCTAssertNil(symbolizedBLSelectorResolution(symbolizedBLSelectorRows(bytes: "f4 ff ff 97", operand: "0x2000"))
                    .targets[0x1020], "An external-looking operand cannot hide an encoded protected-region entry")
            }
        }
    }

    // Synthetic A64 encodings model the remaining fixed-slot pointer families.
    // Candidate bytes deliberately contain plausible in-range destinations, but
    // byte availability is not selector, table-length, or pointer authority.
    private func assertFixedSlotRefusal(_ hex: String, loadIndex: Int,
        loadOperands: String, branchRegister: String, candidateBytes: [UInt8],
        file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = try overwrittenBaseRows(hex, at: 0x1000)
        XCTAssertEqual(rows.count * 4, hex.split(separator: " ").count, file: file, line: line)
        XCTAssertEqual(rows[loadIndex].mnemonic, "ldr", file: file, line: line)
        XCTAssertEqual(rows[loadIndex].operands, loadOperands, file: file, line: line)
        let dispatch = try XCTUnwrap(rows.lastIndex { $0.mnemonic == "br" }, file: file, line: line)
        XCTAssertEqual(rows[dispatch].operands, branchRegister, file: file, line: line)
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertEqual(MacIRBuilder().ssaEnabled, enabled, file: file, line: line)
                var reads = 0
                let tables = JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
                    reads += 1
                    guard count > 0, address >= 0x2000,
                          let offset = Int(exactly: address - 0x2000),
                          offset <= candidateBytes.count, count <= candidateBytes.count - offset else { return nil }
                    return Data(candidateBytes[offset..<offset + count])
                }, codeRange: .init(lowerBound: 0x1000, upperBound: 0x1100))
                XCTAssertTrue(tables.isEmpty, "Fixed-slot pointer is not a jump table", file: file, line: line)
                XCTAssertEqual(reads, 0, "Refuse before consulting tempting target bytes", file: file, line: line)
            }
        }
    }

    func testObjectCallbackWithoutSelectorRefusesPlausiblePointerBytes() throws {
        // LDR X1,[X8]; BR X1. An eight-byte pointer is not a one-case table.
        try assertFixedSlotRefusal("01 01 40 f9 20 00 1f d6", loadIndex: 0,
            loadOperands: "x1, [x8]", branchRegister: "x1",
            candidateBytes: [0x04, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testObjectCallbackOffsetIsNotAnIndexBound() throws {
        // LDR X3,[X8,#0x28]; BR X3. The field displacement is not 40 cases.
        try assertFixedSlotRefusal("03 15 40 f9 60 00 1f d6", loadIndex: 0,
            loadOperands: "x3, [x8, #0x28]", branchRegister: "x3",
            candidateBytes: Array(repeating: 0, count: 0x28) + [0x04, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testObjectCallbackUnrelatedGuardDoesNotAuthorizeFixedSlot() throws {
        // MOV W9,W0; CMP W9,#9; B.HI 0x1014; LDR X1,[X8]; BR X1; RET.
        // The complete guard has a real destination, but W9 indexes no load.
        try assertFixedSlotRefusal("e9 03 00 2a 3f 25 00 71 68 00 00 54 01 01 40 f9 20 00 1f d6 c0 03 5f d6",
            loadIndex: 3, loadOperands: "x1, [x8]", branchRegister: "x1",
            candidateBytes: [0x14, 0x10, 0, 0, 0, 0, 0, 0, 0x10, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testSIMDDispatchStructurePointerRemainsOpaque() throws {
        // LDR X8,[X0,#0x280]; LDR X5,[X8,#0x20]; LDR W0,[X0,#0x30]; BR X5.
        try assertFixedSlotRefusal("08 40 41 f9 05 11 40 f9 00 30 40 b9 a0 00 1f d6",
            loadIndex: 1, loadOperands: "x5, [x8, #0x20]", branchRegister: "x5",
            candidateBytes: Array(repeating: 0, count: 0x20) + [0x0c, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testSIMDDispatchSlotWidthDoesNotDefineTableLength() throws {
        // LDR X8,[X0,#0x280]; LDR X6,[X8,#0x28]; BR X6.
        try assertFixedSlotRefusal("08 40 41 f9 06 15 40 f9 c0 00 1f d6",
            loadIndex: 1, loadOperands: "x6, [x8, #0x28]", branchRegister: "x6",
            candidateBytes: Array(repeating: 0, count: 0x28) + [0x08, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testSIMDDispatchBaseReloadCannotReuseEarlierStaticAddress() throws {
        // ADR X8,0x2000 is killed by the runtime structure load. Even fully
        // readable static backing cannot authorize the later callback target.
        try assertFixedSlotRefusal("08 80 00 10 08 40 41 f9 05 11 40 f9 a0 00 1f d6",
            loadIndex: 2, loadOperands: "x5, [x8, #0x20]", branchRegister: "x5",
            candidateBytes: Array(repeating: 0, count: 0x20) + [0x0c, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testImportStubWithoutSelectorDoesNotBecomeSingletonTable() throws {
        // ADRP X16,0x2000; LDR X16,[X16,#8]; BR X16.
        try assertFixedSlotRefusal("10 00 00 b0 10 06 40 f9 00 02 1f d6",
            loadIndex: 1, loadOperands: "x16, [x16, #8]", branchRegister: "x16",
            candidateBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0x08, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testImportStubGuardBeforePointerReloadIsNotATableBound() throws {
        // CMP X16,#1; B.HI 0x1014; ADRP X16,0x2000; LDR X16,[X16,#8]; BR X16; RET.
        // The guarded value is overwritten; the slot is still not indexed.
        try assertFixedSlotRefusal("1f 06 00 f1 88 00 00 54 10 00 00 b0 10 06 40 f9 00 02 1f d6 c0 03 5f d6",
            loadIndex: 3, loadOperands: "x16, [x16, #8]", branchRegister: "x16",
            candidateBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0x14, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testImportStubNarrowLoadCannotBorrowAbsolutePointerWidth() throws {
        // ADRP X16,0x2000; LDR W16,[X16,#8]; BR X16. Four tempting bytes
        // are not a proven absolute64 table, nor a bounded relative32 table.
        try assertFixedSlotRefusal("10 00 00 b0 10 0a 40 b9 00 02 1f d6",
            loadIndex: 1, loadOperands: "w16, [x16, #8]", branchRegister: "x16",
            candidateBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0x08, 0x10, 0, 0])
    }

    // A restored frame does not establish that a loaded PC leaves the function.
    // These countermodels exercise public lifting, not just table recognition.
    // Slot bytes are a countermodel witness, not runtime memory simulation.
    // The resolver deliberately does not read mutable object memory.
    private func assertLoadedTailRefusal(_ hex: String, start: UInt64,
        mnemonics: [String], loadIndex: Int, loadOperands: String,
        branchRegister: String, slotOffset: Int, candidatePointer: [UInt8],
        conditionalTarget: UInt64? = nil,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = try overwrittenBaseRows(hex, at: start)
        XCTAssertEqual(rows.map(\.mnemonic), mnemonics, file: file, line: line)
        XCTAssertEqual(rows.map(\.address), mnemonics.indices.map { start + UInt64($0 * 4) },
                       file: file, line: line)
        XCTAssertEqual(rows[loadIndex].operands, loadOperands, file: file, line: line)
        XCTAssertEqual(rows.last?.operands, branchRegister, file: file, line: line)
        XCTAssertEqual(candidatePointer.count, 8, file: file, line: line)
        let pointer = candidatePointer.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
        }
        XCTAssertEqual(pointer, start, "Countermodel slot holds this function's entry", file: file, line: line)
        if let conditionalTarget {
            let condition = try XCTUnwrap(rows.first { $0.mnemonic == "cbz" }, file: file, line: line)
            let target = condition.operands.split(separator: ",").last.map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            XCTAssertEqual(conditionalTarget, 0x100c, file: file, line: line)
            XCTAssertEqual(target, "0x000000000000100c", file: file, line: line)
        }
        let memory = Array(repeating: UInt8(0), count: slotOffset) + candidatePointer
        for enabled in [false, true] {
            let mode = "SSA enabled=\(enabled)"
            var reads = 0
            let tables = JumpTableResolver().resolve(instructions: rows, readBytes: { address, count in
                reads += 1
                guard count > 0, address >= 0x2000,
                      let offset = Int(exactly: address - 0x2000),
                      offset <= memory.count, count <= memory.count - offset else { return nil }
                return Data(memory[offset..<offset + count])
            }, codeRange: .init(lowerBound: start, upperBound: start + UInt64(rows.count * 4)))
            XCTAssertEqual(tables.count, 0, file: file, line: line)
            XCTAssertEqual(reads, 0, "Fixed slot has no immutable target-set authority", file: file, line: line)
            let builder = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: enabled)
            XCTAssertEqual(builder.ssaEnabled, enabled, file: file, line: line)
            let function = builder.buildFunction(name: "_loaded_tail_countermodel", startAddress: start,
                jumpTables: tables, instructions: rows)
            XCTAssertEqual(function.instructions.filter {
                if case .call = $0.operation { return true }; return false
            }.count, 0, mode, file: file, line: line)
            XCTAssertEqual(function.instructions.filter {
                if case .returnValue = $0.operation { return true }; return false
            }.count, 0, mode, file: file, line: line)
            XCTAssertEqual(function.instructions.filter {
                if case let .intrinsic(_, name, _) = $0.operation { return name == "branch_register" }
                return false
            }.count, 1, mode, file: file, line: line)
            let load = try XCTUnwrap(function.instructions.first {
                $0.source.address == rows[loadIndex].address
            }, file: file, line: line)
            guard case let .load(loadedTarget, _) = load.operation,
                  case let .register(name, _) = loadedTarget else {
                XCTFail("\(mode): target must remain the exact loaded register value", file: file, line: line)
                continue
            }
            XCTAssertEqual(name, branchRegister, file: file, line: line)
            let branch = try XCTUnwrap(function.instructions.last {
                $0.source.address == rows.last?.address
            }, file: file, line: line)
            guard case let .intrinsic(_, name, arguments) = branch.operation else {
                XCTFail("\(mode): loaded target must remain an opaque branch", file: file, line: line)
                continue
            }
            XCTAssertEqual(name, "branch_register", file: file, line: line)
            XCTAssertEqual(arguments, [loadedTarget], mode, file: file, line: line)
            XCTAssertEqual(function.refusals.filter {
                $0.reason == .unresolvedIndirectBranch && $0.scope == .row(branch.source.address)
            }.count, 1, mode, file: file, line: line)
        }
    }

    func testObjectLoadedTargetMayBeCurrentFunctionEntry() throws {
        // Retained 0x1184..0x118c: SP, FP and LR are unchanged. A slot containing
        // An entry target would be a self tail call; this loaded slot has no
        // independently established target-entry authority.
        try assertLoadedTailRefusal("08 08 41 f9 02 19 40 f9 40 00 1f d6", start: 0x1184,
            mnemonics: ["ldr", "ldr", "br"], loadIndex: 1,
            loadOperands: "x2, [x8, #0x30]", branchRegister: "x2", slotOffset: 0x30,
            candidatePointer: [0x84, 0x11, 0, 0, 0, 0, 0, 0])
    }

    func testObjectRestoredFrameDoesNotProveTargetKind() throws {
        // Save exact entry FP/LR; establish FP; reload both and balance SP.
        // This proves the frame coordinates, not the kind of the loaded PC.
        try assertLoadedTailRefusal("fd 7b bf a9 fd 03 00 91 03 15 40 f9 fd 7b c1 a8 60 00 1f d6", start: 0x1000,
            mnemonics: ["stp", "mov", "ldr", "ldp", "br"], loadIndex: 2,
            loadOperands: "x3, [x8, #0x28]", branchRegister: "x3", slotOffset: 0x28,
            candidatePointer: [0, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testObjectOneUnrestoredPathVetoesTail() throws {
        // CBZ skips the only ADD: one path reaches BR with SP=entry-16.
        try assertLoadedTailRefusal("ff 43 00 d1 49 00 00 34 ff 43 00 91 03 15 40 f9 60 00 1f d6", start: 0x1000,
            mnemonics: ["sub", "cbz", "add", "ldr", "br"], loadIndex: 3,
            loadOperands: "x3, [x8, #0x28]", branchRegister: "x3", slotOffset: 0x28,
            candidatePointer: [0, 0x10, 0, 0, 0, 0, 0, 0], conditionalTarget: 0x100c)
    }

    func testSIMDLoadedTargetMayBeCurrentFunctionEntry() throws {
        // Nested structure loads preserve all three entry frame coordinates,
        // but the fixed slot may still contain an intra-function destination.
        try assertLoadedTailRefusal("08 40 41 f9 05 11 40 f9 a0 00 1f d6", start: 0x1000,
            mnemonics: ["ldr", "ldr", "br"], loadIndex: 1,
            loadOperands: "x5, [x8, #0x20]", branchRegister: "x5", slotOffset: 0x20,
            candidatePointer: [0, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testSIMDRestoredFrameDoesNotProveTargetKind() throws {
        try assertLoadedTailRefusal("fd 7b bf a9 fd 03 00 91 08 40 41 f9 05 11 40 f9 fd 7b c1 a8 a0 00 1f d6", start: 0x1000,
            mnemonics: ["stp", "mov", "ldr", "ldr", "ldp", "br"], loadIndex: 3,
            loadOperands: "x5, [x8, #0x20]", branchRegister: "x5", slotOffset: 0x20,
            candidatePointer: [0, 0x10, 0, 0, 0, 0, 0, 0])
    }

    func testSIMDOneUnrestoredPathVetoesTail() throws {
        // The taken edge bypasses SP restoration before either structure load.
        try assertLoadedTailRefusal("ff 43 00 d1 49 00 00 34 ff 43 00 91 08 40 41 f9 05 11 40 f9 a0 00 1f d6", start: 0x1000,
            mnemonics: ["sub", "cbz", "add", "ldr", "ldr", "br"], loadIndex: 4,
            loadOperands: "x5, [x8, #0x20]", branchRegister: "x5", slotOffset: 0x20,
            candidatePointer: [0, 0x10, 0, 0, 0, 0, 0, 0], conditionalTarget: 0x100c)
    }
}
