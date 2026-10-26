import Foundation
import XCTest
@testable import MacScope

/// Smallest vectors observed under (logical nodes, edges, enumeration code).
/// The census uses explicit false-edge trampolines; these are not asserted to
/// be global minima over every possible linear CFG representation.
final class DecompilerStructuringCatalogueVectorsTests: XCTestCase {
    func test_conditionalOverReachesStop() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1028", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x4", hasBreakpoint: false, comment: "visit_4"),
            InstructionRow(address: 0x102c, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_conditionalOverReachesStop", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .conditionalOverReachesStop)
        XCTAssertEqual(cfg.blocks.count, 7)
    }

    func test_earlyExitFallthroughArmDominanceFailedInLoopCyclicPlainTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitFallthroughArmDominanceFailedInLoopCyclicPlainTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitFallthroughArmDominanceFailedInLoopCyclicPlainTail)
        XCTAssertEqual(cfg.blocks.count, 6)
    }

    func test_earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicPlainTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicPlainTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitFallthroughArmDominanceFailedOutOfLoopAcyclicPlainTail)
        XCTAssertEqual(cfg.blocks.count, 6)
    }

    func test_earlyExitFallthroughArmDominanceFailedOutOfLoopCyclicPlainTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitFallthroughArmDominanceFailedOutOfLoopCyclicPlainTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitFallthroughArmDominanceFailedOutOfLoopCyclicPlainTail)
        XCTAssertEqual(cfg.blocks.count, 4)
    }

    func test_earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicPlainTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicPlainTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitFallthroughBranchDominanceFailedOutOfLoopAcyclicPlainTail)
        XCTAssertEqual(cfg.blocks.count, 6)
    }

    func test_earlyExitFallthroughBranchDominanceFailedOutOfLoopCyclicPlainTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x102c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x102c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x4", hasBreakpoint: false, comment: "visit_4"),
            InstructionRow(address: 0x1030, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitFallthroughBranchDominanceFailedOutOfLoopCyclicPlainTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitFallthroughBranchDominanceFailedOutOfLoopCyclicPlainTail)
        XCTAssertEqual(cfg.blocks.count, 8)
    }

    func test_earlyExitFallthroughReachesContinuationInLoopCyclicPlainTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitFallthroughReachesContinuationInLoopCyclicPlainTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitFallthroughReachesContinuationInLoopCyclicPlainTail)
        XCTAssertEqual(cfg.blocks.count, 6)
    }

    func test_earlyExitFallthroughReachesContinuationOutOfLoopAcyclicPlainTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x102c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x102c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x4", hasBreakpoint: false, comment: "visit_4"),
            InstructionRow(address: 0x1030, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitFallthroughReachesContinuationOutOfLoopAcyclicPlainTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitFallthroughReachesContinuationOutOfLoopAcyclicPlainTail)
        XCTAssertEqual(cfg.blocks.count, 8)
    }

    func test_earlyExitFallthroughReachesContinuationOutOfLoopCyclicPlainTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x101c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitFallthroughReachesContinuationOutOfLoopCyclicPlainTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitFallthroughReachesContinuationOutOfLoopCyclicPlainTail)
        XCTAssertEqual(cfg.blocks.count, 6)
    }

    func test_earlyExitTakenSharedExit() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitTakenSharedExit", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitTakenSharedExit)
        XCTAssertEqual(cfg.blocks.count, 4)
    }

    func test_earlyExitTakenSinglePred() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x101c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1028", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x4", hasBreakpoint: false, comment: "visit_4"),
            InstructionRow(address: 0x102c, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_earlyExitTakenSinglePred", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .earlyExitTakenSinglePred)
        XCTAssertEqual(cfg.blocks.count, 7)
    }

    func test_gotoLeafRejoiningAmbiguousEntry() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_gotoLeafRejoiningAmbiguousEntry", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .gotoLeafRejoiningAmbiguousEntry)
        XCTAssertEqual(cfg.blocks.count, 6)
    }

    func test_gotoLeafRejoiningArmUnstructured() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_gotoLeafRejoiningArmUnstructured", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .gotoLeafRejoiningArmUnstructured)
        XCTAssertEqual(cfg.blocks.count, 6)
    }

    func test_gotoLeafRejoiningDoubleReachable() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_gotoLeafRejoiningDoubleReachable", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .gotoLeafRejoiningDoubleReachable)
        XCTAssertEqual(cfg.blocks.count, 7)
    }

    func test_gotoLeafRejoiningLeafEscapes() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1024", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1024", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_gotoLeafRejoiningLeafEscapes", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .gotoLeafRejoiningLeafEscapes)
        XCTAssertEqual(cfg.blocks.count, 7)
    }

    func test_gotoLeafRejoiningNoSharedTail() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1024", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1024", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "b", operands: "0x102c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1024", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x102c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x4", hasBreakpoint: false, comment: "visit_4"),
            InstructionRow(address: 0x1030, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_gotoLeafRejoiningNoSharedTail", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .gotoLeafRejoiningNoSharedTail)
        XCTAssertEqual(cfg.blocks.count, 8)
    }

    func test_gotoLeafRejoiningNonContiguous() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1028", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1028", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x4", hasBreakpoint: false, comment: "visit_4"),
            InstructionRow(address: 0x102c, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_gotoLeafRejoiningNonContiguous", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .gotoLeafRejoiningNonContiguous)
        XCTAssertEqual(cfg.blocks.count, 7)
    }

    func test_gotoLeafRejoiningOverReachesStop() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1024", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x102c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1024", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x102c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x4", hasBreakpoint: false, comment: "visit_4"),
            InstructionRow(address: 0x1030, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_gotoLeafRejoiningOverReachesStop", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .gotoLeafRejoiningOverReachesStop)
        XCTAssertEqual(cfg.blocks.count, 8)
    }

    func test_ifElseTakenBodyOrientation() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1028", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1028, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x4", hasBreakpoint: false, comment: "visit_4"),
            InstructionRow(address: 0x102c, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_ifElseTakenBodyOrientation", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .ifElseTakenBodyOrientation)
        XCTAssertEqual(cfg.blocks.count, 7)
    }

    func test_ifThenBodyUnstructured() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1020", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1020, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x3", hasBreakpoint: false, comment: "visit_3"),
            InstructionRow(address: 0x1024, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_ifThenBodyUnstructured", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .ifThenBodyUnstructured)
        XCTAssertEqual(cfg.blocks.count, 6)
    }

    func test_irreducibleBlocks() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_irreducibleBlocks", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .irreducibleBlocks)
        XCTAssertEqual(cfg.blocks.count, 4)
    }

    func test_loopMultipleExitTargets() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1000", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_loopMultipleExitTargets", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .loopMultipleExitTargets)
        XCTAssertEqual(cfg.blocks.count, 1)
    }

    func test_loopSecondaryExitNotInContinuation() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1018", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x101c, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_loopSecondaryExitNotInContinuation", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .loopSecondaryExitNotInContinuation)
        XCTAssertEqual(cfg.blocks.count, 5)
    }

    func test_loopShapeUnsupported() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1014", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1014, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x2", hasBreakpoint: false, comment: "visit_2"),
            InstructionRow(address: 0x1018, bytes: "00 00 00 00", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_loopShapeUnsupported", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .loopShapeUnsupported)
        XCTAssertEqual(cfg.blocks.count, 4)
    }

    func test_multiLatch() {
        let rows: [InstructionRow] = [
            InstructionRow(address: 0x1000, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x0", hasBreakpoint: false, comment: "visit_0"),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "cbnz", operands: "x0, 0x1000", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x1008, bytes: "00 00 00 00", mnemonic: "b", operands: "0x100c", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x100c, bytes: "00 00 00 00", mnemonic: "mov", operands: "x20, #0x1", hasBreakpoint: false, comment: "visit_1"),
            InstructionRow(address: 0x1010, bytes: "00 00 00 00", mnemonic: "b", operands: "0x1000", hasBreakpoint: false, comment: nil)
        ]
        let function = MacIRBuilder().buildFunction(name: "_multiLatch", instructions: rows)
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        let result = RegionTree.buildWithDiagnostics(cfg: cfg, instructions: function.instructions, collectDiagnostics: true)
        XCTAssertEqual(result.diagnostics.fatalVeto, .multiLatch)
        XCTAssertEqual(cfg.blocks.count, 3)
    }

}
