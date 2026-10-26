import XCTest
@testable import MacScope

final class MacIRPairWritebackFrameTests: XCTestCase {
    private func checkFrame(
        _ instructions: [(String, String)],
        size: Int64,
        semanticSize: Int64 = 0,
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let rows = instructions.enumerated().map { index, instruction in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "",
                           mnemonic: instruction.0, operands: instruction.1,
                           hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder().buildFunction(name: name, instructions: rows)
        let rendered = PseudocodePrinter().print(function: function).text
        if let directory = ProcessInfo.processInfo.environment["PAIR_FRAME_CAPTURE_DIRECTORY"] {
            try rendered.write(toFile: directory + "/" + name + ".c", atomically: false, encoding: .utf8)
        }
        XCTAssertEqual(function.maxStackDisplacement, size, file: file, line: line)
        XCTAssertEqual(function.stackFrameSize, semanticSize, file: file, line: line)
        XCTAssertTrue(rendered.contains("stack frame 0x" + String(size, radix: 16) + " bytes"),
                      rendered, file: file, line: line)
        let pairNames = function.instructions.compactMap { instruction -> String? in
            if case let .intrinsic(_, name, _) = instruction.operation,
               name == "save_pair_writeback" || name == "restore_pair_writeback" {
                return name
            }
            return nil
        }
        XCTAssertEqual(pairNames.filter { $0 == "save_pair_writeback" }.count,
                       instructions.filter { $0.0 == "stp" && $0.1.contains("!") }.count,
                       file: file, line: line)
        XCTAssertEqual(pairNames.filter { $0 == "restore_pair_writeback" }.count,
                       instructions.filter { $0.0 == "ldp" && $0.1.contains("],") }.count,
                       file: file, line: line)
    }

    func testDRegisterPairPrologueContributesStackFrameSize() throws {
        try checkFrame([("stp", "d11, d10, [sp, #-0x70]!"), ("mov", "x0, x1"),
                        ("ldp", "d11, d10, [sp], #0x70"), ("ret", "")],
                       size: 0x70, name: "d_register_frame")
    }

    func testGPRPairPrologueContributesStackFrameSize() throws {
        try checkFrame([("stp", "x20, x19, [sp, #-0x20]!"),
                        ("stp", "x29, x30, [sp, #0x10]"), ("add", "x29, sp, #0x10"),
                        ("blr", "x8"), ("ldp", "x29, x30, [sp, #0x10]"),
                        ("ldp", "x20, x19, [sp], #0x20"), ("ret", "")],
                       size: 0x20, name: "gpr_frame")
    }

    func testConditionalFloatDCTProloguePreservesFrameMaximum() throws {
        try checkFrame([("cbz", "w6, 0x1014"), ("stp", "x28, x27, [sp, #-0x60]!"),
                        ("blr", "x25"), ("ldp", "x28, x27, [sp], #0x60"),
                        ("ret", ""), ("ret", "")],
                       size: 0x60, name: "conditional_float_frame")
    }

    func testConditionalIntegerDCTProloguePreservesFrameMaximum() throws {
        try checkFrame([("cbz", "w6, 0x1014"), ("stp", "x28, x27, [sp, #-0x60]!"),
                        ("blr", "x24"), ("ldp", "x28, x27, [sp], #0x60"),
                        ("ret", ""), ("ret", "")],
                       size: 0x60, name: "conditional_integer_frame")
    }

    func testSequentialPairFramesRetainMaximumRatherThanSum() throws {
        try checkFrame([("stp", "x20, x19, [sp, #-0x20]!"),
                        ("ldp", "x20, x19, [sp], #0x20"),
                        ("stp", "x29, x30, [sp, #-0x10]!"),
                        ("ldp", "x29, x30, [sp], #0x10"), ("ret", "")],
                       size: 0x20, name: "sequential_frames")
    }

    func testMixedSubAndPairAllocationsContributeToFrameMaximum() throws {
        try checkFrame([("sub", "sp, sp, #0x30"), ("stp", "x29, x30, [sp, #-0x20]!"),
                        ("ldp", "x29, x30, [sp], #0x20"), ("add", "sp, sp, #0x30"),
                        ("ret", "")],
                       size: 0x50, semanticSize: 0x30, name: "mixed_frame")
    }
}
