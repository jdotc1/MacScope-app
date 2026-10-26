import Foundation
import XCTest
@testable import MacScope

/// Advanced-SIMD "tail" decode: vector-by-indexed-element, dot product, and the scalar
/// families (three-same, copy, by-element, shift-by-immediate). Every word + rendering is
/// ground-truthed against `clang -arch arm64` + `otool -tvVj` (otool prints Apple `.suffix`
/// syntax, e.g. `mul.4s v0, v1, v2[1]`; MacScope renders the standard `mul v0.4s, v1.4s,
/// v2.s[1]` form asserted here). These families previously decoded as `unknown`.
final class ARM64SIMDByElementScalarTests: XCTestCase {
    private func text(_ word: UInt32) -> String {
        let bytes = Data([UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8),
                          UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 24)])
        let r = ARM64Decoder().decode(bytes, baseAddress: 0, maxInstructionCount: 1)[0]
        return "\(r.mnemonic) \(r.operands)"
    }

    // MARK: - Vector by indexed element (same-width)
    func testByElementInteger() {
        XCTAssertEqual(text(0x4fa28020), "mul v0.4s, v1.4s, v2.s[1]")
        XCTAssertEqual(text(0x6f720020), "mla v0.8h, v1.8h, v2.h[3]")   // H: index=H:L:M, Vm in v0-v15
        XCTAssertEqual(text(0x6f824820), "mls v0.4s, v1.4s, v2.s[2]")
        XCTAssertEqual(text(0x4fa2c020), "sqdmulh v0.4s, v1.4s, v2.s[1]")
    }
    func testByElementFP() {
        XCTAssertEqual(text(0x4fa29020), "fmul v0.4s, v1.4s, v2.s[1]")
        XCTAssertEqual(text(0x4fc21020), "fmla v0.2d, v1.2d, v2.d[0]")  // D: index=H
        XCTAssertEqual(text(0x4fa25820), "fmls v0.4s, v1.4s, v2.s[3]")
        XCTAssertEqual(text(0x6fa29020), "fmulx v0.4s, v1.4s, v2.s[1]")
    }

    // MARK: - Dot product (vector + by element)
    func testDotProduct() {
        XCTAssertEqual(text(0x4e829420), "sdot v0.4s, v1.16b, v2.16b")
        XCTAssertEqual(text(0x2e829420), "udot v0.2s, v1.8b, v2.8b")
        XCTAssertEqual(text(0x4fa2e020), "sdot v0.4s, v1.16b, v2.4b[1]")
        XCTAssertEqual(text(0x2f82e020), "udot v0.2s, v1.8b, v2.4b[0]")
    }

    // MARK: - Scalar three-same (integer)
    /// All 16 distinct words from the 48 DP02 whole-vector SQRDMULH cases.
    func testDP02WholeVectorSQRDMULH() {
        XCTAssertEqual(text(0x2e62b420), "sqrdmulh v0.4h, v1.4h, v2.4h")
        XCTAssertEqual(text(0x2e62b421), "sqrdmulh v1.4h, v1.4h, v2.4h")
        XCTAssertEqual(text(0x2e62b422), "sqrdmulh v2.4h, v1.4h, v2.4h")
        XCTAssertEqual(text(0x2e61b421), "sqrdmulh v1.4h, v1.4h, v1.4h")
        XCTAssertEqual(text(0x6e62b420), "sqrdmulh v0.8h, v1.8h, v2.8h")
        XCTAssertEqual(text(0x6e62b421), "sqrdmulh v1.8h, v1.8h, v2.8h")
        XCTAssertEqual(text(0x6e62b422), "sqrdmulh v2.8h, v1.8h, v2.8h")
        XCTAssertEqual(text(0x6e61b421), "sqrdmulh v1.8h, v1.8h, v1.8h")
        XCTAssertEqual(text(0x2ea2b420), "sqrdmulh v0.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x2ea2b421), "sqrdmulh v1.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x2ea2b422), "sqrdmulh v2.2s, v1.2s, v2.2s")
        XCTAssertEqual(text(0x2ea1b421), "sqrdmulh v1.2s, v1.2s, v1.2s")
        XCTAssertEqual(text(0x6ea2b420), "sqrdmulh v0.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6ea2b421), "sqrdmulh v1.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6ea2b422), "sqrdmulh v2.4s, v1.4s, v2.4s")
        XCTAssertEqual(text(0x6ea1b421), "sqrdmulh v1.4s, v1.4s, v1.4s")
        // Byte and doubleword element sizes are reserved for both Q values.
        for word: UInt32 in [0x2e22b420, 0x6e22b420, 0x2ee2b420, 0x6ee2b420] {
            XCTAssertTrue(text(word).hasPrefix("unknown "), String(format: "%08x", word))
        }
    }

    func testDP02WholeVectorSQDMULH() {
        // DP02-DIS-001...004: minimized dot vectors, QEMU 11.0.2 corroborated.
        XCTAssertEqual(text(0x0e60b400), "sqdmulh v0.4h, v0.4h, v0.4h")
        XCTAssertEqual(text(0x4e60b400), "sqdmulh v0.8h, v0.8h, v0.8h")
        XCTAssertEqual(text(0x0ea0b400), "sqdmulh v0.2s, v0.2s, v0.2s")
        XCTAssertEqual(text(0x4ea0b400), "sqdmulh v0.4s, v0.4s, v0.4s")
        // Distinct registers must retain all three operands.
        XCTAssertEqual(text(0x4e62b420), "sqdmulh v0.8h, v1.8h, v2.8h")
    }

    func testWholeVectorSQDMULHRejectsReservedSizes() {
        for word: UInt32 in [0x0e20b400, 0x4e20b400, 0x0ee0b400, 0x4ee0b400] {
            XCTAssertTrue(text(word).hasPrefix("unknown "), String(format: "%08x", word))
        }
    }

    func testScalarThreeSameInteger() {
        XCTAssertEqual(text(0x5ee28420), "add d0, d1, d2")
        XCTAssertEqual(text(0x7ee28420), "sub d0, d1, d2")
        XCTAssertEqual(text(0x7ee28c20), "cmeq d0, d1, d2")
        XCTAssertEqual(text(0x5ee23420), "cmgt d0, d1, d2")
        XCTAssertEqual(text(0x7ee23420), "cmhi d0, d1, d2")
        XCTAssertEqual(text(0x5e220c20), "sqadd b0, b1, b2")   // saturating: all element sizes
        XCTAssertEqual(text(0x5ea20c20), "sqadd s0, s1, s2")
        XCTAssertEqual(text(0x7ea20c20), "uqadd s0, s1, s2")
        XCTAssertEqual(text(0x5ea22c20), "sqsub s0, s1, s2")
        XCTAssertEqual(text(0x5ee24420), "sshl d0, d1, d2")
        XCTAssertEqual(text(0x7ee25420), "urshl d0, d1, d2")
        XCTAssertEqual(text(0x5ea25c20), "sqrshl s0, s1, s2")
        // saturating-doubling-multiply-high: the scalar peers of the by-element forms (H/S only)
        XCTAssertEqual(text(0x5e76b6b4), "sqdmulh h20, h21, h22")
        XCTAssertEqual(text(0x5eb9b717), "sqdmulh s23, s24, s25")
        XCTAssertEqual(text(0x7e7cb77a), "sqrdmulh h26, h27, h28")
        XCTAssertEqual(text(0x7ea0b7dd), "sqrdmulh s29, s30, s0")
    }

    // MARK: - Scalar three-same (FP)
    func testScalarThreeSameFP() {
        XCTAssertEqual(text(0x7ea2d420), "fabd s0, s1, s2")
        XCTAssertEqual(text(0x7ee2d420), "fabd d0, d1, d2")
        XCTAssertEqual(text(0x5e22dc20), "fmulx s0, s1, s2")
        XCTAssertEqual(text(0x5e22fc20), "frecps s0, s1, s2")
        XCTAssertEqual(text(0x5ea2fc20), "frsqrts s0, s1, s2")
        XCTAssertEqual(text(0x5e22e420), "fcmeq s0, s1, s2")
        XCTAssertEqual(text(0x7e22e420), "fcmge s0, s1, s2")
        XCTAssertEqual(text(0x7ea2e420), "fcmgt s0, s1, s2")
        XCTAssertEqual(text(0x7e22ec20), "facge s0, s1, s2")
        XCTAssertEqual(text(0x7ea2ec20), "facgt s0, s1, s2")
    }

    // MARK: - Scalar copy (mov from lane)
    func testScalarCopyMov() {
        XCTAssertEqual(text(0x5e070420), "mov b0, v1.b[3]")
        XCTAssertEqual(text(0x5e0a0420), "mov h0, v1.h[2]")
        XCTAssertEqual(text(0x5e1c0420), "mov s0, v1.s[3]")
        XCTAssertEqual(text(0x5e180420), "mov d0, v1.d[1]")
    }

    // MARK: - Scalar by indexed element
    func testScalarByElement() {
        XCTAssertEqual(text(0x5fa2c020), "sqdmulh s0, s1, v2.s[1]")
        XCTAssertEqual(text(0x5f72d020), "sqrdmulh h0, h1, v2.h[3]")
        XCTAssertEqual(text(0x5f829820), "fmul s0, s1, v2.s[2]")
        XCTAssertEqual(text(0x5f821820), "fmla s0, s1, v2.s[2]")
        XCTAssertEqual(text(0x5fc25820), "fmls d0, d1, v2.d[1]")
        XCTAssertEqual(text(0x7f829020), "fmulx s0, s1, v2.s[0]")
    }

    // MARK: - Scalar shift by immediate
    func testScalarShiftImmediate() {
        XCTAssertEqual(text(0x5f435420), "shl d0, d1, #3")
        XCTAssertEqual(text(0x5f7b0420), "sshr d0, d1, #5")
        XCTAssertEqual(text(0x7f790420), "ushr d0, d1, #7")
        XCTAssertEqual(text(0x5f7e2420), "srshr d0, d1, #2")
        XCTAssertEqual(text(0x5f447420), "sqshl d0, d1, #4")
        // sqshlu (saturating shift-left-unsigned): all sizes b/h/s/d
        XCTAssertEqual(text(0x7f0b6441), "sqshlu b1, b2, #3")
        XCTAssertEqual(text(0x7f7f6650), "sqshlu d16, d18, #63")
    }

    // MARK: - Regression: the FP load/store-register mask tightening (bit25=0) must not
    // break real load/store decoding (these share bits[29:26]=1111 with the SIMD data-proc space).
    func testFPLoadStoreStillDecodes() {
        XCTAssertEqual(text(0x3dc00000), "ldr q0, [x0]")
        XCTAssertEqual(text(0x3d800400), "str q0, [x0, #0x10]")
        XCTAssertEqual(text(0x3cc10400), "ldr q0, [x0], #0x10")   // post-index
    }
}
