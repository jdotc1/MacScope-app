import Foundation
import XCTest
@testable import MacScope

final class UnwindAuditCFITests: XCTestCase {
    private func op(_ code: UInt8, _ values: [UInt64]) -> DWARFStructuredCFAOperation {
        .init(sectionOffset: 0, opcode: code, operands: values.map { .unsigned($0) }, rawBytes: [code])
    }
    private func program(_ operations: [DWARFStructuredCFAOperation],
                         status: DWARFStructuredCFADecodeStatus = .complete) -> DWARFStructuredCFAProgram {
        .init(sectionOffset: 0, rawBytes: operations.flatMap(\.rawBytes), operations: operations, status: status)
    }
    private func table(initial: DWARFStructuredCFAProgram? = nil,
                       body: DWARFStructuredCFAProgram? = nil) -> DWARFStructuredCallFrameTable {
        let cie = DWARFStructuredCIE(sectionOffset: 0, version: 1, augmentation: "zR",
                                     augmentationData: [0x10], codeAlignmentFactor: 1,
                                     dataAlignmentFactor: -8, returnAddressRegister: 30,
                                     fdePointerEncoding: 0x10,
                                     initialProgram: initial ?? program([op(12, [31, 16]), op(0x9d, [29, 2]), op(0x9e, [30, 1])]))
        let fde = DWARFStructuredFDE(sectionOffset: 20, cieSectionOffset: 0,
                                     initialLocation: 0x100, rangeSize: 8, augmentationData: [],
                                     program: body ?? program([op(13, [29])]))
        return .init(cies: [cie], fdes: [fde])
    }
    private func state() -> UnwindAuditMachine {
        var state = UnwindAuditMachine()
        state.sp = .stack(displacement: -16)
        state.registers[29] = .stack(displacement: -16)
        state.registers[30] = .constant(0x104)
        state.memory[-16] = .original(register: 29, displacement: 0)
        state.memory[-8] = .original(register: 30, displacement: 0)
        return state
    }

    func testRegisterUpdateRetainsOffsetAndRecoversSavedCaller() throws {
        let evaluator = try UnwindAuditCFI(table: table())
        let fde = try evaluator.select(offset: 20, start: 0x100, end: 0x108)
        let row = try fde.row(at: 0x100)
        XCTAssertEqual(fde.offset, 20)
        XCTAssertEqual(fde.cieOffset, 0)
        XCTAssertEqual(row.pc, 0x100)
        XCTAssertEqual(row.register, 29)
        XCTAssertEqual(row.offset, 16)
        let values = try row.recover(state())
        XCTAssertEqual(values["SP"], .stack(displacement: 0))
        for number in 19...30 {
            XCTAssertEqual(values["x\(number)"], .original(register: number, displacement: 0))
        }
    }

    func testUnsupportedTailAndMissingPriorCFADecline() throws {
        XCTAssertThrowsError(try UnwindAuditCFI(table: table(body: program([op(13, [29]), op(15, [])]))))
        XCTAssertThrowsError(try UnwindAuditCFI(table: table(body: program([], status: .unsupported(opcode: 0x3f)))))
        XCTAssertThrowsError(try UnwindAuditCFI(table: table(body: program([], status: .malformed(offset: 45)))))
        XCTAssertThrowsError(try UnwindAuditCFI(table: table(initial: program([op(13, [29])]))))
    }

    func testUnknownSavedValueAndExactFDESelection() throws {
        let evaluator = try UnwindAuditCFI(table: table())
        let fde = try evaluator.select(offset: 20, start: 0x100, end: 0x108)
        var missing = state()
        missing.memory.removeValue(forKey: -8)
        let values = try fde.row(at: 0x100).recover(missing)
        XCTAssertEqual(values["x30"]?.known, false)
        XCTAssertThrowsError(try evaluator.select(offset: 21, start: 0x100, end: 0x108))
        XCTAssertThrowsError(try evaluator.select(offset: 20, start: 0x100, end: 0x104))
        var overlapping = table()
        var duplicateRange = overlapping.fdes[0]
        duplicateRange.sectionOffset = 80
        overlapping.fdes.append(duplicateRange)
        let overlaps = try UnwindAuditCFI(table: overlapping)
        XCTAssertThrowsError(try overlaps.select(offset: 20, start: 0x100, end: 0x108))
        XCTAssertThrowsError(try overlaps.select(offset: 80, start: 0x100, end: 0x108))
    }
}
