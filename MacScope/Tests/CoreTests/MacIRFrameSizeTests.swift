import XCTest
@testable import MacScope

final class MacIRFrameSizeTests: XCTestCase {
    private func checkFrame(
        _ assembly: [(String, String)], size: Int64, semanticSize: Int64 = 0,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let rows = assembly.enumerated().map { index, item in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "",
                           mnemonic: item.0, operands: item.1,
                           hasBreakpoint: false, comment: nil)
        }
        for ssaEnabled in [false, true] {
            let function = MacIRBuilder(ssaEnabled: ssaEnabled)
                .buildFunction(name: "frame_size", instructions: rows)
            XCTAssertEqual(function.maxStackDisplacement, size,
                           "ssaEnabled=\(ssaEnabled)", file: file, line: line)
            XCTAssertEqual(function.stackFrameSize, semanticSize,
                           "ssaEnabled=\(ssaEnabled)", file: file, line: line)
            let metadata = size == 0 ? "no stack frame"
                : "stack frame 0x" + String(size, radix: 16) + " bytes"
            XCTAssertTrue(PseudocodePrinter().print(function: function).text.contains(metadata),
                          "ssaEnabled=\(ssaEnabled): \(metadata)", file: file, line: line)
        }
    }

    func testPreIndexPairAllocatesFrame() {
        checkFrame([("stp", "x29, x30, [sp, #-0x30]!"), ("ret", "")], size: 0x30)
    }

    func testPreIndexPairAndSubAllocationsAdd() {
        checkFrame([("stp", "x29, x30, [sp, #-0x30]!"),
                    ("sub", "sp, sp, #0x40"), ("ret", "")], size: 0x70, semanticSize: 0x40)
    }

    func testSubOnlyKeepsExistingFrameSize() {
        checkFrame([("sub", "sp, sp, #0x40"), ("ret", "")], size: 0x40, semanticSize: 0x40)
    }

    func testLeafHasNoStackFrame() {
        checkFrame([("mov", "x0, x1"), ("ret", "")], size: 0)
    }

    func testPairRestoreDoesNotDoubleCount() {
        checkFrame([("stp", "x29, x30, [sp, #-0x30]!"),
                    ("ldp", "x29, x30, [sp], #0x30"),
                    ("sub", "sp, sp, #0x10"), ("ret", "")], size: 0x30, semanticSize: 0x10)
    }

    func testRegisterAmountKeepsExistingUnknownDepthBehavior() {
        // A register amount is not an immediate allocation proof. Keep the
        // existing zero metadata rather than assuming a value for x8.
        checkFrame([("sub", "sp, sp, x8"), ("ret", "")], size: 0)
    }

    func testRegisterAmountPreservesExistingMetadataAcrossWriteback() {
        for adjustment in ["add", "sub"] {
            checkFrame([("str", "x19, [sp, #-0x20]!"),
                        (adjustment, "sp, sp, x8"),
                        ("sub", "sp, sp, #0x40"), ("ret", "")],
                       size: 0x40, semanticSize: 0x40)
            checkFrame([(adjustment, "sp, sp, x8"),
                        ("str", "x19, [sp, #-0x20]!"), ("ret", "")], size: 0)
        }
    }

    func testSingleRegisterPreIndexAllocation() {
        checkFrame([("str", "x19, [sp, #-0x20]!"), ("ret", "")], size: 0x20)
    }

    func testSingleRegisterAllocationAndSubAdd() {
        checkFrame([("str", "x19, [sp, #-0x20]!"),
                    ("sub", "sp, sp, #0x40"), ("ret", "")], size: 0x60, semanticSize: 0x40)
    }

    func testSingleRegisterRestoreReducesDepth() {
        checkFrame([("str", "x19, [sp, #-0x20]!"),
                    ("ldr", "x19, [sp], #0x20"),
                    ("stp", "x29, x30, [sp, #-0x10]!"), ("ret", "")], size: 0x20)
    }

    func testPostIndexAllocationCountsUpdatedSP() {
        checkFrame([("str", "x19, [sp], #-0x20"), ("ret", "")], size: 0x20)
    }

    func testLoadPreIndexAllocationCountsUpdatedSP() {
        checkFrame([("ldr", "x19, [sp, #-0x20]!"), ("ret", "")], size: 0x20)
    }

    func testRestoresClampDepthAtZero() {
        checkFrame([("ldr", "x19, [sp], #0x20"), ("add", "sp, sp, #0x10"),
                    ("str", "x19, [sp, #-0x10]!"), ("ret", "")], size: 0x10)
    }

    func testNonStackWritebackDoesNotAllocateFrame() {
        checkFrame([("str", "x19, [x8, #-0x20]!"), ("ret", "")], size: 0)
    }
}
