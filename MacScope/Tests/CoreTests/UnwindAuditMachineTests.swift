import Foundation
import XCTest
@testable import MacScope

final class UnwindAuditMachineTests: XCTestCase {
    private func decode(_ words: [UInt32], start: UInt64 = 0x1000) throws -> [UnwindAuditInstruction] {
        let bytes = words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
        return try UnwindAuditInstruction.decode(data: Data(bytes), start: start, maximum: words.count)
    }

    private func effect(_ kind: String, rd: Int = 0, rn: Int = 0, rt2: Int = 0,
                        immediate: Int64 = 0, addressing: String = "") -> UnwindAuditInstruction {
        .init(address: 0x1000, word: 0, kind: kind, rd: rd, rn: rn, rt2: rt2,
              immediate: immediate, addressing: addressing)
    }

    func testFramePairAndCallSuspension() throws {
        let instructions = try decode([0xa9bf7bfd, 0x910003fd, 0x94000004, 0xa8c17bfd])
        var machine = UnwindAuditMachine(strictCallState: true)
        try machine.apply(instructions[0])
        try machine.apply(instructions[1])
        XCTAssertEqual(machine.sp, .stack(displacement: -16))
        XCTAssertEqual(machine.registers[29], .stack(displacement: -16))
        XCTAssertEqual(machine.memory[-16], .original(register: 29, displacement: 0))
        XCTAssertEqual(machine.memory[-8], .original(register: 30, displacement: 0))
        try machine.apply(instructions[2])
        XCTAssertEqual(machine.registers[30], .constant(0x100c))
        XCTAssertFalse(machine.registers[0].known)
        XCTAssertEqual(machine.registers[19], .original(register: 19, displacement: 0))
        machine.resumeAfterCall()
        XCTAssertFalse(machine.registers[30].known)
        try machine.apply(instructions[3])
        XCTAssertEqual(machine.registers[29], .original(register: 29, displacement: 0))
        XCTAssertEqual(machine.registers[30], .original(register: 30, displacement: 0))
        XCTAssertEqual(machine.sp, .stack(displacement: 0))
        XCTAssertTrue(machine.memory.isEmpty)
    }

    func testWidthBoundedArithmeticAndConditions() throws {
        let instructions = try decode([0xd2800060, 0x71000400, 0x11000114, 0xf100011f])
        var machine = UnwindAuditMachine()
        try machine.apply(instructions[0])
        for expected in [UInt64(2), 1, 0] {
            try machine.apply(instructions[1])
            XCTAssertEqual(machine.registers[0], .constant(expected))
            XCTAssertEqual(try machine.condition(1), expected != 0)
        }
        try machine.apply(instructions[2])
        XCTAssertFalse(machine.registers[20].known)
        XCTAssertNotEqual(machine.registers[20], .original(register: 20, displacement: 0))
        try machine.apply(instructions[3])
        XCTAssertNil(machine.flags)
        XCTAssertNil(try machine.condition(0))
    }

    func testUnknownAndFullSnapshot() throws {
        let unknown = UnwindAuditValue.unknown("source")
        XCTAssertEqual(try unknown.add(16), unknown)
        var machine = UnwindAuditMachine()
        let original = machine.snapshot(certain: true, priorCallCount: 1)
        XCTAssertEqual(original, machine.snapshot(certain: true, priorCallCount: 1))
        XCTAssertNotEqual(original, machine.snapshot(certain: true, priorCallCount: 2))
        XCTAssertNotEqual(original, machine.snapshot(certain: false, priorCallCount: 1))
        machine.registers[0] = .constant(1)
        XCTAssertNotEqual(original, machine.snapshot(certain: true, priorCallCount: 1))
        machine = .init()
        machine.memory[-8] = .constant(1)
        XCTAssertNotEqual(original, machine.snapshot(certain: true, priorCallCount: 1))
        machine = .init()
        machine.words[-4] = .constant(1)
        XCTAssertNotEqual(original, machine.snapshot(certain: true, priorCallCount: 1))
        machine = .init()
        machine.flags = .init(n: false, z: true, c: false, v: false)
        XCTAssertNotEqual(original, machine.snapshot(certain: true, priorCallCount: 1))
        machine = .init(strictCallState: true)
        XCTAssertNotEqual(original, machine.snapshot(certain: true, priorCallCount: 1))
    }

    func testUnknownAndUnsupportedEffectsDecline() throws {
        for word in [UInt32(0xffffffff), 0xd65f0000, 0xd503233f, 0x110003e0, 0xa94003e0, 0xa9bf77bd] {
            XCTAssertThrowsError(try decode([word]), "word \(String(word, radix: 16))")
        }
        XCTAssertThrowsError(try decode([0x94000001], start: UInt64.max - 3))
        XCTAssertThrowsError(try decode([0xd503201f], start: 1))
        XCTAssertThrowsError(try UnwindAuditInstruction.decode(data: Data([0]), start: 0, maximum: 1))
        XCTAssertThrowsError(try UnwindAuditInstruction.decode(data: Data([0x1f, 0x20, 0x03, 0xd5]), start: 0, maximum: 0))
    }

    func testStackBoundsAndCallEscape() throws {
        var machine = UnwindAuditMachine()
        XCTAssertThrowsError(try machine.apply(effect("add", rd: 31, rn: 31, immediate: 16)))
        XCTAssertThrowsError(try machine.apply(effect("sub", rd: 31, rn: 31, immediate: 8)))
        try machine.apply(effect("sub", rd: 31, rn: 31, immediate: 16))
        XCTAssertThrowsError(try machine.apply(effect("ldp", rd: 29, rn: 31, rt2: 30, addressing: "offset")))
        try machine.apply(effect("add", rd: 0, rn: 31))
        XCTAssertThrowsError(try machine.apply(effect("bl")))
    }

    func testWordStoreInvalidatesSavedIdentity() throws {
        var machine = UnwindAuditMachine()
        try machine.apply(effect("stp", rd: 19, rn: 31, rt2: 20, immediate: -16, addressing: "pre"))
        try machine.apply(effect("movz", rd: 0, immediate: 7))
        try machine.apply(effect("wstr", rd: 0, rn: 31))
        XCTAssertEqual(machine.memory[-16], .unknown("saved 64-bit value overwritten by a W store"))
        XCTAssertEqual(machine.memory[-8], .original(register: 20, displacement: 0))
        try machine.apply(effect("wldr", rd: 1, rn: 31))
        XCTAssertEqual(machine.registers[1], .constant(7))
        try machine.apply(effect("add", rd: 31, rn: 31, immediate: 16))
        XCTAssertTrue(machine.memory.isEmpty)
        XCTAssertTrue(machine.words.isEmpty)
    }
}
