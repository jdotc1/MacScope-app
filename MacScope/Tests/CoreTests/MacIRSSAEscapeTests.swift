import XCTest
@testable import MacScope

extension MacIRSSATests {
    private var escapingJumpTableRows: [InstructionRow] {
        let assembly: [(String, String)] = [
            ("mov", "x1, #7"), ("br", "x8"),
            ("mov", "x0, x1"), ("ret", ""),
            ("mov", "x2, x1"), ("ret", ""),
            ("mov", "x1, #99"), ("b", "0x1008")
        ]
        return assembly.enumerated().map { index, item in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "00 00 00 00",
                mnemonic: item.0, operands: item.1, hasBreakpoint: false, comment: nil)
        }
    }

    func testJumpTableKnownTailsKeepExactInputsAndOpaqueUnreachableEntries() throws {
        let rows = escapingJumpTableRows
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(
            name: "bounded_dispatch", startAddress: 0x1000, endAddress: 0x1018,
            jumpTables: [0x1004: [0x1008, 0x1018, 0x0ffc, 0x1008]],
            callerReturnWidth: .x0,
            knownTailCallTargets: [0x1018: "tail_high", 0x0ffc: "tail_low"], instructions: rows)
        let graph = try XCTUnwrap(function.cfg)
        let info = try XCTUnwrap(function.ssaInfo)
        let dispatch = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x1000 })
        let reachable = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x1008 })
        let lexicalDead = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x1010 })
        XCTAssertFalse(graph.blocks.contains { !(0x1000..<0x1018).contains($0.startAddress) })
        XCTAssertEqual(dispatch.successors.map(\.kind), [.jumpTable, .jumpTable, .jumpTable, .jumpTable])
        XCTAssertEqual(dispatch.successors.map(\.label), [0, 1, 2, 3])
        XCTAssertEqual(dispatch.successors.map(\.to), [reachable.index, nil, nil, reachable.index])
        XCTAssertEqual(graph.unreachable, [lexicalDead.index])
        let escapes = function.refusals.filter { $0.reason == .targetOutsideFunction }
        XCTAssertEqual(escapes.map(\.scope), [.block(dispatch.index), .block(dispatch.index)])
        XCTAssertEqual(escapes.map(\.detail), ["case 1: target 0x1018", "case 2: target 0xffc"])
        XCTAssertFalse(function.refusals.contains { $0.scope == .function })

        let input = try XCTUnwrap(info.plan.blockExitBindings[dispatch.index][1])
        XCTAssertEqual(info.plan.definitions[input].origin, .instruction(0x1000))
        let useRow = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x1008))
        XCTAssertEqual(info.plan.rowReadBindings[useRow][1], input)
        let opaque = try XCTUnwrap(info.plan.blockEntryBindings[lexicalDead.index][1])
        XCTAssertEqual(info.plan.definitions[opaque].origin,
                       .refusal(.unreachableBlock, lexicalDead.startAddress))
        let deadRead = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x1010))
        let deadInput = try XCTUnwrap(info.plan.rowReadBindings[deadRead][1])
        XCTAssertEqual(info.plan.definitions[deadInput].origin, .refusal(.unreachableBlock, 0x1010))
        XCTAssertFalse(function.phis.contains { SSAPropertyAssertions.physicalCell($0.destination) == 1 })
        XCTAssertEqual(graph.idom[reachable.index], dispatch.index)
    }

    func testJumpTableExternalReentryRefusesSSAForTheFunction() throws {
        // The external MOV changes W8 before branching back into the owned
        // ADD. A local-only SSA graph cannot safely retain the initial W8.
        let bytes: [UInt8] = [
            0x48, 0x05, 0x80, 0x52, 0x1f, 0x04, 0x00, 0x71,
            0x08, 0x01, 0x00, 0x54, 0xa9, 0x00, 0x00, 0x10,
            0x4a, 0x01, 0x00, 0x10, 0x4b, 0x69, 0x60, 0x38,
            0x29, 0x09, 0x0b, 0x8b, 0x20, 0x01, 0x1f, 0xd6,
            0x00, 0x05, 0x00, 0x11, 0xc0, 0x03, 0x5f, 0xd6,
            0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6,
            0x68, 0x0c, 0x80, 0x52, 0xfb, 0xff, 0xff, 0x17,
            0x00, 0x04
        ]
        let decoded = ARM64Decoder().decode(Data(bytes.prefix(56)), baseAddress: 0x1000,
                                            maxInstructionCount: 14)
        XCTAssertEqual(decoded.count, 14)
        XCTAssertFalse(decoded.contains { ["unknown", "unavailable"].contains($0.mnemonic) })
        let rows = decoded.map { InstructionRow(address: $0.address, bytes: $0.byteText,
            mnemonic: $0.mnemonic, operands: $0.operands, hasBreakpoint: false, comment: $0.comment) }
        let tables: [UInt64: [UInt64]] = [0x101c: bytes.suffix(2).map { 0x1020 + UInt64($0) * 4 }]
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(
            name: "external_reentry", startAddress: 0x1000, endAddress: 0x1030,
            jumpTables: tables, callerReturnWidth: .w0, instructions: rows)
        let retained = MacIRBuilder(ssaEnabled: false).buildFunction(
            name: "external_reentry", startAddress: 0x1000, endAddress: 0x1030,
            jumpTables: tables, callerReturnWidth: .w0, instructions: rows)
        let graph = try XCTUnwrap(function.cfg)
        let dispatch = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x100c })
        let local = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x1020 })
        XCTAssertFalse(graph.blocks.contains { !(0x1000..<0x1030).contains($0.startAddress) })
        XCTAssertEqual(dispatch.successors.map(\.kind), [.jumpTable, .jumpTable])
        XCTAssertEqual(dispatch.successors.map(\.label), [0, 1])
        XCTAssertEqual(dispatch.successors.map(\.to), [local.index, nil])
        XCTAssertEqual(function.refusals.filter { $0.reason == .targetOutsideFunction }, [
            .init(reason: .targetOutsideFunction, scope: .block(dispatch.index),
                  detail: "case 1: target 0x1030")
        ])
        XCTAssertEqual(function.refusals.filter { $0.scope == .function }, [
            .init(reason: .jumpTableOutsideFunction, scope: .function,
                  detail: "external case may re-enter the function")
        ])
        XCTAssertNil(function.ssaInfo)
        XCTAssertEqual(function.instructions, retained.instructions)
        XCTAssertEqual(function.phis, retained.phis)
        XCTAssertEqual(function.returnValue, retained.returnValue)
    }

    func testJumpTableMissingInternalDestinationIsAScopedExit() throws {
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(
            name: "missing_case", startAddress: 0x1000, endAddress: 0x1018,
            jumpTables: [0x1004: [0x1008, 0x1012]],
            callerReturnWidth: .x0, instructions: escapingJumpTableRows)
        let graph = try XCTUnwrap(function.cfg)
        let dispatch = try XCTUnwrap(graph.blocks.first { $0.startAddress == 0x1000 })
        XCTAssertEqual(dispatch.successors.count, 2)
        XCTAssertNil(dispatch.successors[1].to)
        XCTAssertEqual(dispatch.successors[1].label, 1)
        XCTAssertTrue(function.refusals.contains {
            $0.reason == .targetOutsideFunction && $0.scope == .block(dispatch.index)
                && $0.detail == "case 1: target 0x1012"
        })
    }

    func testExplicitOwnershipBoundsLeaveDisabledLifterUnchanged() {
        let builder = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: false)
        let tables: [UInt64: [UInt64]] = [0x1004: [0x1008, 0x1018]]
        let bounded = builder.buildFunction(name: "retained_dispatch", startAddress: 0x1000,
            endAddress: 0x1018, jumpTables: tables, instructions: escapingJumpTableRows)
        let retained = builder.buildFunction(name: "retained_dispatch", startAddress: 0x1000,
            jumpTables: tables, instructions: escapingJumpTableRows)
        XCTAssertEqual(bounded.instructions, retained.instructions)
        XCTAssertEqual(bounded.phis, retained.phis)
        XCTAssertEqual(bounded.cfg, retained.cfg)
        XCTAssertEqual(bounded.refusals, retained.refusals)
    }
}
