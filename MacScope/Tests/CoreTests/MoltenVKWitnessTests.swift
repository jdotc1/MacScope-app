import XCTest
@testable import MacScope

/// DP07 MoltenVK items on the real witness `_mvkMTLClearDepthFromVkClearValue` (MoltenVK 1.4.2,
/// 0x602b8..0x6031c; DP07 handback finding 4): the float->double widening reads as a cast after the
/// explicit bit transfer, and the vtable call goes through the loaded target.
final class MoltenVKWitnessTests: XCTestCase {
    private let rows: [(UInt64, String, String)] = [
            (0x602b8, "stp", "x22, x21, [sp, #-0x30]!"),
            (0x602bc, "stp", "x20, x19, [sp, #0x10]"),
            (0x602c0, "stp", "x29, x30, [sp, #0x20]"),
            (0x602c4, "add", "x29, sp, #0x20"),
            (0x602c8, "mov", "x19, x0"),
            (0x602cc, "adrp", "x21, 0x396000"),
            (0x602d0, "ldr", "x8, [x21, #0xd30]"),
            (0x602d4, "cbnz", "x8, 0x60304"),
            (0x602d8, "mov", "w0, #0x430"),
            (0x602dc, "bl", "0x2b1dcc"),
            (0x602e0, "mov", "x20, x0"),
            (0x602e4, "mov", "x1, #0x0"),
            (0x602e8, "bl", "0x701ec"),
            (0x602ec, "ldr", "x0, [x21, #0xd30]"),
            (0x602f0, "str", "x20, [x21, #0xd30]"),
            (0x602f4, "cbz", "x0, 0x60304"),
            (0x602f8, "ldr", "x8, [x0]"),
            (0x602fc, "ldr", "x8, [x8, #0x20]"),
            (0x60300, "blr", "x8"),
            (0x60304, "fmov", "s0, w19"),
            (0x60308, "fcvt", "d0, s0"),
            (0x6030c, "ldp", "x29, x30, [sp, #0x20]"),
            (0x60310, "ldp", "x20, x19, [sp, #0x10]"),
            (0x60314, "ldp", "x22, x21, [sp], #0x30"),
            (0x60318, "ret", ""),
    ]

    func testDepthWideningAndIndirectCallThroughTheLoadedTarget() throws {
        let instructions = rows.map {
            InstructionRow(address: $0.0, bytes: "", mnemonic: $0.1, operands: $0.2, hasBreakpoint: false, comment: nil)
        }
        let text = PseudocodePrinter().print(
            functionName: "_mvkMTLClearDepthFromVkClearValue", startAddress: 0x602b8, instructions: instructions
        ).text
        // fmov s0, w19 stays an explicit bit transfer; fcvt d0, s0 is an exact widening.
        XCTAssertTrue(text.range(of: #"d0_\d+ = \(double\)s0_\d+"#, options: .regularExpression) != nil, text)
        XCTAssertFalse(text.contains("__a64_convert_f32_f64"), text)
        // ldr x8, [x0]; ldr x8, [x8, #0x20]; blr x8: the call names the value that load defined.
        let load = try XCTUnwrap(text.range(of: #"\w+ = \*\(\w+ \+ 0x20\)"#, options: .regularExpression),
                                 "the second vtable load\n\(text)")
        let loaded = String(text[load].split(separator: " ").first ?? "")
        XCTAssertTrue(text.contains("(*\(loaded))("), "the indirect call uses \(loaded)\n\(text)")
        XCTAssertFalse(text.contains("(*x8)("), text)
    }
}
