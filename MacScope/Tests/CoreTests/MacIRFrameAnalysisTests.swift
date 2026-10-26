import XCTest
@testable import MacScope

/// DP04 B1: frame coordinates over the CFG.
final class MacIRFrameAnalysisTests: XCTestCase {
    private func analyze(_ text: [(String, String)]) -> (MacIRFrameAnalysis, [InstructionRow]) {
        let rows = text.enumerated().map { index, pair in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0, operands: pair.1,
                           hasBreakpoint: false, comment: nil)
        }
        let function = MacIRBuilder().buildFunction(name: "frame", startAddress: 0x1000, instructions: rows)
        return (MacIRFrameAnalysis.analyze(rows: rows, instructions: function.instructions), rows)
    }

    private func ranges(_ analysis: MacIRFrameAnalysis, at address: UInt64) -> [Range<Int64>] {
        analysis.accesses.filter { $0.address == address }.map(\.range)
    }

    func testFrameJoinWritebackAndDynamicSP() {
        // FP prologue/epilogue: an SP slot and the same slot through x29 resolve alike.
        let (frame, _) = analyze([
            ("stp", "x29, x30, [sp, #-0x20]!"), ("mov", "x29, sp"), ("str", "x0, [sp, #0x10]"),
            ("ldr", "x1, [x29, #0x10]"), ("ldp", "x29, x30, [sp], #0x20"), ("ret", ""),
        ])
        XCTAssertTrue(frame.isComplete)
        XCTAssertEqual(ranges(frame, at: 0x1000), [-32 ..< -24, -24 ..< -16], "pair: two 8-byte ranges after pre-index")
        XCTAssertEqual(ranges(frame, at: 0x1008), [-16 ..< -8])
        XCTAssertEqual(ranges(frame, at: 0x100c), [-16 ..< -8], "x29-relative load names the same slot")
        XCTAssertEqual(ranges(frame, at: 0x1010), [-32 ..< -24, -24 ..< -16], "post-index accesses before the update")
        XCTAssertEqual(frame.stateBefore[0x1014]?.sp, .entrySP(0), "epilogue restores entry SP")
        XCTAssertEqual(frame.stateBefore[0x1014]?.aliases[29], nil, "ldp reloads x29")

        // Divergent join: SP differs on the two paths, so the access is not exact.
        let (join, _) = analyze([
            ("cbz", "x0, 0x1008"), ("sub", "sp, sp, #0x10"), ("str", "x1, [sp]"),
            ("add", "sp, sp, #0x10"), ("ret", ""),
        ])
        XCTAssertTrue(join.isComplete)
        XCTAssertEqual(join.stateBefore[0x1008]?.sp, .unknown)
        XCTAssertEqual(ranges(join, at: 0x1008), [])

        // Pre-index applies before the access, post-index after.
        let (order, _) = analyze([("str", "x0, [sp, #-0x10]!"), ("ldr", "x0, [sp], #0x10"), ("ret", "")])
        XCTAssertEqual(ranges(order, at: 0x1000), [-16 ..< -8])
        XCTAssertEqual(ranges(order, at: 0x1004), [-16 ..< -8])
        XCTAssertEqual(order.stateBefore[0x1008]?.sp, .entrySP(0))

        // Dynamic SP: fixed locals stay anchored through FP; SP restores from FP.
        let (dynamic, _) = analyze([
            ("stp", "x29, x30, [sp, #-0x10]!"), ("mov", "x29, sp"), ("sub", "sp, sp, x8"),
            ("str", "x1, [sp]"), ("str", "x2, [x29, #0x8]"), ("mov", "sp, x29"),
            ("ldp", "x29, x30, [sp], #0x10"), ("ret", ""),
        ])
        XCTAssertEqual(dynamic.stateBefore[0x100c]?.sp, .dynamic(0x1008))
        XCTAssertEqual(ranges(dynamic, at: 0x100c), [], "a dynamic SP access is not an exact slot")
        XCTAssertEqual(ranges(dynamic, at: 0x1010), [-8 ..< 0], "x29 still anchors the fixed slot")
        XCTAssertEqual(dynamic.stateBefore[0x1018]?.sp, .entrySP(-16), "mov sp, x29 restores SP")
        XCTAssertEqual(dynamic.stateBefore[0x101c]?.sp, .entrySP(0))

        // A call clobbers caller-saved aliases; callee-saved ones survive.
        let (call, _) = analyze([
            ("add", "x0, sp, #0x8"), ("add", "x19, sp, #0x10"), ("bl", "_f"), ("ret", ""),
        ])
        XCTAssertEqual(call.stateBefore[0x100c]?.aliases[0], nil)
        XCTAssertEqual(call.stateBefore[0x100c]?.aliases[19], .entrySP(16))
    }

    func testLDPSWUsesFourByteElementsWithoutMergingAdjacentRegions() {
        let (frame, rows) = analyze([
            ("sub", "sp, sp, #32"), ("str", "w8, [sp]"), ("str", "w9, [sp, #12]"),
            ("ldpsw", "x2, x3, [sp, #4]"), ("add", "sp, sp, #32"), ("ret", ""),
        ])
        XCTAssertTrue(frame.isComplete)
        XCTAssertEqual(ranges(frame, at: 0x100c), [-28 ..< -24, -24 ..< -20])
        let function = MacIRBuilder().buildFunction(name: "pair", startAddress: 0x1000, instructions: rows)
        let regions = MacIRStackRegionAnalysis.analyze(functionStart: 0x1000, rows: rows,
                                                       instructions: function.instructions, frame: frame)
        XCTAssertEqual(regions.regions.map(\.range), [-32 ..< -28, -28 ..< -24, -24 ..< -20, -20 ..< -16])
        XCTAssertTrue(regions.regions.allSatisfy { !$0.hasPartialOverlap })
        XCTAssertEqual(regions.regions.last?.accessAddresses, [0x1008])

        let (pre, _) = analyze([
            ("sub", "sp, sp, #32"), ("ldpsw", "x2, x3, [sp, #4]!"), ("ret", ""),
        ])
        XCTAssertEqual(ranges(pre, at: 0x1004), [-28 ..< -24, -24 ..< -20])
        XCTAssertEqual(pre.stateBefore[0x1008]?.sp, .entrySP(-28))
        let (post, _) = analyze([
            ("sub", "sp, sp, #32"), ("add", "sp, sp, #4"),
            ("ldpsw", "x2, x3, [sp], #8"), ("ret", ""),
        ])
        XCTAssertEqual(ranges(post, at: 0x1008), [-28 ..< -24, -24 ..< -20])
        XCTAssertEqual(post.stateBefore[0x100c]?.sp, .entrySP(-20))
    }

}
