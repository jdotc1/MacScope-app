import XCTest
@testable import MacScope

/// Locks the elidable-intrinsic policy that the IR-lifting track (W5²-B) depends on:
/// arm64e pointer-authentication intrinsics are semantically empty for pseudocode and are
/// dropped by `nopElision`, while trap intrinsics (`brk`/`udf`) must stay visible.
///
/// These are constructed as `.intrinsic` operations directly (not through the builder,
/// which today still surfaces `pacibsp` as `__unknown`) so the test pins the PRINTER's
/// elision policy independently of when the lifter starts emitting them.
final class PACIntrinsicElisionTests: XCTestCase {
    private func function(_ ops: [(UInt64, String, MacIROperation)]) -> MacIRFunction {
        let instructions = ops.map { address, mnemonic, operation in
            MacIRInstruction(
                source: MacIRSourceSpan(
                    address: address,
                    byteText: "00 00 00 00",
                    mnemonic: mnemonic,
                    operands: "",
                    comment: nil
                ),
                operation: operation
            )
        }
        return MacIRFunction(name: "_pac", startAddress: ops.first?.0 ?? 0, instructions: instructions)
    }

    private func document(_ fn: MacIRFunction, elide: Bool) -> PseudocodeDocument {
        var options = DecompilerOptions.default
        options.nopElision = elide
        return PseudocodePrinter(options: options).print(function: fn)
    }

    func testPACIntrinsicsAreElidedByNopElision() {
        let fn = function([
            (0x1000, "pacibsp", .intrinsic(destination: nil, name: "pacibsp", arguments: [])),
            (0x1004, "paciza", .intrinsic(destination: nil, name: "paciza", arguments: [])),
            (0x1008, "autibsp", .intrinsic(destination: nil, name: "autibsp", arguments: [])),
            (0x100c, "ret", .returnValue(nil)),
        ])

        let shown = document(fn, elide: false)
        XCTAssertTrue(shown.text.contains("__pacibsp()"), "default must render PAC intrinsics")

        let elided = document(fn, elide: true)
        XCTAssertFalse(elided.text.contains("pacibsp"), "nopElision must drop PAC intrinsic lines")
        XCTAssertFalse(elided.text.contains("paciza"))
        XCTAssertFalse(elided.text.contains("autibsp"))
        XCTAssertTrue(elided.text.contains("return"), "non-PAC content survives elision")
    }

    func testTrapIntrinsicsAreNeverElided() {
        let fn = function([
            (0x2000, "brk", .intrinsic(destination: nil, name: "brk", arguments: [.immediate(1)])),
            (0x2004, "udf", .intrinsic(destination: nil, name: "udf", arguments: [.immediate(0)])),
            (0x2008, "ret", .returnValue(nil)),
        ])

        let elided = document(fn, elide: true)
        XCTAssertTrue(elided.text.contains("brk"), "brk is a trap — must stay visible even under nopElision")
        XCTAssertTrue(elided.text.contains("udf"), "udf is a trap — must stay visible even under nopElision")
    }
}
