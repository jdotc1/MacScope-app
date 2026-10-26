import Foundation
import XCTest
@testable import MacScope

// NEW RECONSTRUCTION / SOURCE ONLY / NOT STAGED OR RUN. Original mutation bodies
// remain verbatim historical evidence. Excluded-null mutations are BLOCKED and
// require the separate exact-fallback integration layer. The memory replacement
// covers retained 4e84/29a70 non-width obligations only; width, signed-load/full-
// cell and full64 W-zero-high obligations remain OPEN. No source draft supplies
// numerical credit; parser/UB/fuel errors are not numerical kills.

/// Only real, complete corpus instruction streams enter the production path.
/// The text oracle never sees assembly, MacIR, architectural names, or the proof.
final class DecodedScalarCFGTests: XCTestCase {
    private var historicalNativeCache: [UInt64: (fixture: Fixture, prepared: HistoricalNativePrepared)] = [:]
    // _null_convert @ 0x3704, all 84 instructions / 336 bytes.
    // SHA-256 01b2ede48249160ae0bb2397ec861599a8c26b32b9c1c742423a539cb126e161.
    // Source: retained loop-family-input-diagnostic metadata, not a synthetic loop.
    private static let planarBytes = """
    09 5c 40 b9 08 30 40 b9 3f 0d 00 71 e0 03 00 54
    3f 11 00 71 c1 06 00 54 9f 04 00 71 8b 09 00 54
    88 02 00 34 49 28 40 a9 29 59 63 f8 4a 59 63 f8
    4b 30 41 a9 6b 59 63 f8 8c 59 63 f8 ed 03 08 aa
    2e 00 40 f9 cf 01 40 39 2f 15 00 38 cf 05 40 39
    4f 15 00 38 cf 09 40 39 6f 15 00 38 cf 0d 40 39
    8f 15 00 38 ce 11 00 91 ad 05 00 f1 c1 fe ff 54
    21 20 00 91 63 04 00 11 9f 08 00 71 84 04 00 51
    63 06 00 54 e7 ff ff 17 9f 04 00 71 0b 06 00 54
    28 02 00 34 49 28 40 a9 29 59 63 f8 4a 59 63 f8
    4b 08 40 f9 6b 59 63 f8 2c 00 40 f9 ed 03 08 aa
    8e 01 40 39 2e 15 00 38 8e 05 40 39 4e 15 00 38
    8e 09 40 39 6e 15 00 38 8c 0d 00 91 ad 05 00 f1
    01 ff ff 54 21 20 00 91 63 04 00 11 9f 08 00 71
    84 04 00 51 43 03 00 54 ea ff ff 17 9f 04 00 71
    eb 02 00 54 2a 7d 40 93 5f 05 00 71 eb 01 00 54
    0b 00 80 d2 48 01 00 34 4c 78 6b f8 8c 59 63 f8
    2d 00 40 f9 ee 03 08 aa af 69 6b 38 8f 15 00 38
    ad 01 0a 8b ce 05 00 f1 81 ff ff 54 6b 05 00 91
    7f 01 09 eb 81 fe ff 54 21 20 00 91 63 04 00 11
    9f 04 00 71 84 04 00 51 8c fd ff 54 c0 03 5f d6
    """

    // _jpeg_difference_first_row @ 0x17cb0, all 99 instructions / 396 bytes.
    // SHA-256 26a963a43b2a6fceba4ea646b5de06256d1c7329c0065e7b90e628ec7459edcb.
    // Includes the actual BR X1 at 0x17e04; not a grafted indirect branch.
    private static let indirectBytes = """
    08 14 41 f9 4a 00 40 39 09 58 40 b9 0b d8 41 b9
    eb 03 2b 2a 29 01 0b 0b 0b 00 80 12 69 21 c9 1a
    29 01 0a 0b 89 00 00 b9 a9 04 00 71 20 01 00 54
    4b 04 00 91 8c 10 00 91 6d 15 40 38 aa 01 0a 4b
    8a 45 00 b8 ea 03 0d aa 29 05 00 71 61 ff ff 54
    09 3c 41 b9 c9 00 00 34 09 a1 01 91 2a d9 61 b8
    4a 05 00 71 2a d9 21 b8 00 03 00 54 09 cc 41 b9
    3f 0d 00 71 6d 01 00 54 3f 15 00 71 8c 03 00 54
    3f 11 00 71 a0 06 00 54 3f 15 00 71 81 04 00 54
    08 cd 21 8b 09 00 00 b0 29 b1 01 91 3a 00 00 14
    3f 05 00 71 40 03 00 54 3f 09 00 71 60 06 00 54
    3f 0d 00 71 41 03 00 54 08 cd 21 8b 09 00 00 90
    29 21 3d 91 30 00 00 14 2a 7c 40 93 0b 3c 41 b9
    0c 98 41 b9 6b 09 cc 1a 2b 79 2a b8 08 0d 0a 8b
    09 00 00 90 29 c1 32 91 27 00 00 14 3f 19 00 71
    c0 03 00 54 3f 1d 00 71 21 01 00 54 08 cd 21 8b
    09 00 00 b0 29 61 06 91 1f 00 00 14 08 cd 21 8b
    09 00 00 90 29 f1 38 91 1b 00 00 14 08 00 40 f9
    2a 02 80 52 0a 25 05 29 08 d0 41 b9 09 00 40 f9
    28 31 00 b9 08 d4 41 b9 09 00 40 f9 28 35 00 b9
    08 d8 41 b9 09 00 40 f9 28 39 00 b9 08 00 40 f9
    01 01 40 f9 20 00 1f d6 08 cd 21 8b 09 00 00 90
    29 51 3f 91 08 00 00 14 08 cd 21 8b 09 00 00 b0
    29 01 04 91 04 00 00 14 08 cd 21 8b 09 00 00 90
    29 01 3b 91 09 0d 00 f9 c0 03 5f d6
    """

    private static let planarSourceText = """
    ldr w9, [x0, #0x5c]
    ldr w8, [x0, #0x30]
    cmp w9, #3
    b.eq 0x000000000000378c
    cmp w9, #4
    b.ne 0x00000000000037f0
    cmp w4, #1
    b.lt 0x0000000000003850
    cbz w8, 0x0000000000003774
    ldp x9, x10, [x2]
    ldr x9, [x9, w3, uxtw #3]
    ldr x10, [x10, w3, uxtw #3]
    ldp x11, x12, [x2, #0x10]
    ldr x11, [x11, w3, uxtw #3]
    ldr x12, [x12, w3, uxtw #3]
    mov x13, x8
    ldr x14, [x1]
    ldrb w15, [x14]
    strb w15, [x9], #1
    ldrb w15, [x14, #1]
    strb w15, [x10], #1
    ldrb w15, [x14, #2]
    strb w15, [x11], #1
    ldrb w15, [x14, #3]
    strb w15, [x12], #1
    add x14, x14, #4
    subs x13, x13, #1
    b.ne 0x0000000000003748
    add x1, x1, #8
    add w3, w3, #1
    cmp w4, #2
    sub w4, w4, #1
    b.lo 0x0000000000003850
    b 0x0000000000003724
    cmp w4, #1
    b.lt 0x0000000000003850
    cbz w8, 0x00000000000037d8
    ldp x9, x10, [x2]
    ldr x9, [x9, w3, uxtw #3]
    ldr x10, [x10, w3, uxtw #3]
    ldr x11, [x2, #0x10]
    ldr x11, [x11, w3, uxtw #3]
    ldr x12, [x1]
    mov x13, x8
    ldrb w14, [x12]
    strb w14, [x9], #1
    ldrb w14, [x12, #1]
    strb w14, [x10], #1
    ldrb w14, [x12, #2]
    strb w14, [x11], #1
    add x12, x12, #3
    subs x13, x13, #1
    b.ne 0x00000000000037b4
    add x1, x1, #8
    add w3, w3, #1
    cmp w4, #2
    sub w4, w4, #1
    b.lo 0x0000000000003850
    b 0x0000000000003794
    cmp w4, #1
    b.lt 0x0000000000003850
    sxtw x10, w9
    cmp w10, #1
    b.lt 0x000000000000383c
    mov x11, #0
    cbz w8, 0x0000000000003830
    ldr x12, [x2, x11, lsl #3]
    ldr x12, [x12, w3, uxtw #3]
    ldr x13, [x1]
    mov x14, x8
    ldrb w15, [x13, x11]
    strb w15, [x12], #1
    add x13, x13, x10
    subs x14, x14, #1
    b.ne 0x000000000000381c
    add x11, x11, #1
    cmp x11, x9
    b.ne 0x0000000000003808
    add x1, x1, #8
    add w3, w3, #1
    cmp w4, #1
    sub w4, w4, #1
    b.gt 0x00000000000037fc
    ret
    """

    // New unsigned-memory series. Every positive is a complete retained corpus
    // stream at its actual base, not a synthetic instruction list or relocation.
    private struct MemorySeed {
        let base: UInt64
        let name: String
        let kind: UnsignedMemoryScenario.Kind?
        let bytes: String
        let text: String
        let unavailable: Set<Int>
        let operandWitnesses: [UInt64]
        let blocks: Int
    }
    // _null_convert @ 0x27b30: 84 rows; SHA-256 04c65b68258e95928c9e0479a1f16fe39b92f8016a4e01a2495aa478cefd2a40.
    // Capture: scalar-memory-input-diagnostic/metadata.json.document-metadata.json.
    private static let planar8 = MemorySeed(base: 0x27b30, name: "_null_convert",
        kind: .planar8, bytes: """
        09 38 40 b9 08 88 40 b9 3f 0d 00 71 e0 03 00 54
        3f 11 00 71 c1 06 00 54 9f 04 00 71 8b 09 00 54
        88 02 00 34 29 28 40 a9 29 59 62 f8 4a 59 62 f8
        2b 30 41 a9 6b 59 62 f8 8c 59 62 f8 ed 03 08 aa
        6e 00 40 f9 2f 15 40 38 cf 01 00 39 4f 15 40 38
        cf 05 00 39 6f 15 40 38 cf 09 00 39 8f 15 40 38
        cf 0d 00 39 ce 11 00 91 ad 05 00 f1 c1 fe ff 54
        42 04 00 11 63 20 00 91 9f 08 00 71 84 04 00 51
        63 06 00 54 e7 ff ff 17 9f 04 00 71 0b 06 00 54
        28 02 00 34 29 28 40 a9 29 59 62 f8 4a 59 62 f8
        2b 08 40 f9 6b 59 62 f8 6c 00 40 f9 ed 03 08 aa
        2e 15 40 38 8e 01 00 39 4e 15 40 38 8e 05 00 39
        6e 15 40 38 8e 09 00 39 8c 0d 00 91 ad 05 00 f1
        01 ff ff 54 42 04 00 11 63 20 00 91 9f 08 00 71
        84 04 00 51 43 03 00 54 ea ff ff 17 9f 04 00 71
        eb 02 00 54 2a 7d 40 93 5f 05 00 71 eb 01 00 54
        0b 00 80 d2 48 01 00 34 2c 78 6b f8 8c 59 62 f8
        6d 00 40 f9 ee 03 08 aa 8f 15 40 38 af 69 2b 38
        ad 01 0a 8b ce 05 00 f1 81 ff ff 54 6b 05 00 91
        7f 01 09 eb 81 fe ff 54 63 20 00 91 42 04 00 11
        9f 04 00 71 84 04 00 51 8c fd ff 54 c0 03 5f d6
        """, text: """
        ldr w9, [x0, #0x38]
        ldr w8, [x0, #0x88]
        cmp w9, #3
        b.eq 0x0000000000027bb8
        cmp w9, #4
        b.ne 0x0000000000027c1c
        cmp w4, #1
        b.lt 0x0000000000027c7c
        cbz w8, 0x0000000000027ba0
        ldp x9, x10, [x1]
        ldr x9, [x9, w2, uxtw #3]
        ldr x10, [x10, w2, uxtw #3]
        ldp x11, x12, [x1, #0x10]
        ldr x11, [x11, w2, uxtw #3]
        ldr x12, [x12, w2, uxtw #3]
        mov x13, x8
        ldr x14, [x3]
        ldrb w15, [x9], #1
        strb w15, [x14]
        ldrb w15, [x10], #1
        strb w15, [x14, #1]
        ldrb w15, [x11], #1
        strb w15, [x14, #2]
        ldrb w15, [x12], #1
        strb w15, [x14, #3]
        add x14, x14, #4
        subs x13, x13, #1
        b.ne 0x0000000000027b74
        add w2, w2, #1
        add x3, x3, #8
        cmp w4, #2
        sub w4, w4, #1
        b.lo 0x0000000000027c7c
        b 0x0000000000027b50
        cmp w4, #1
        b.lt 0x0000000000027c7c
        cbz w8, 0x0000000000027c04
        ldp x9, x10, [x1]
        ldr x9, [x9, w2, uxtw #3]
        ldr x10, [x10, w2, uxtw #3]
        ldr x11, [x1, #0x10]
        ldr x11, [x11, w2, uxtw #3]
        ldr x12, [x3]
        mov x13, x8
        ldrb w14, [x9], #1
        strb w14, [x12]
        ldrb w14, [x10], #1
        strb w14, [x12, #1]
        ldrb w14, [x11], #1
        strb w14, [x12, #2]
        add x12, x12, #3
        subs x13, x13, #1
        b.ne 0x0000000000027be0
        add w2, w2, #1
        add x3, x3, #8
        cmp w4, #2
        sub w4, w4, #1
        b.lo 0x0000000000027c7c
        b 0x0000000000027bc0
        cmp w4, #1
        b.lt 0x0000000000027c7c
        sxtw x10, w9
        cmp w10, #1
        b.lt 0x0000000000027c68
        mov x11, #0
        cbz w8, 0x0000000000027c5c
        ldr x12, [x1, x11, lsl #3]
        ldr x12, [x12, w2, uxtw #3]
        ldr x13, [x3]
        mov x14, x8
        ldrb w15, [x12], #1
        strb w15, [x13, x11]
        add x13, x13, x10
        subs x14, x14, #1
        b.ne 0x0000000000027c48
        add x11, x11, #1
        cmp x11, x9
        b.ne 0x0000000000027c34
        add x3, x3, #8
        add w2, w2, #1
        cmp w4, #1
        sub w4, w4, #1
        b.gt 0x0000000000027c28
        ret
        """, unavailable: [15, 43, 61, 69, 83], operandWitnesses: [
            0x0231d172788a590e, 0x97b28c34cdef8d60, 0x8ca33218f2e1396d, 0x2fce95d54d1962fa,
            0x7b7130b8866e0873, 0xf4f4a3ec1274d6bf, 0x54d63be132cb02d8, 0x3e0a904103969b7b,
            0x808c6e2078488950, 0xbf0fd9e9905ffe8a, 0x4d98c13703ed294b, 0xabe7f78eb0926773,
            0x3d1ac1e2578b0260, 0x55688993d2a8aa29, 0x96d727207bba5143, 0x87f116892b66367e,
            0x631794c6eed97f06, 0xa18130ab97dcf6d3, 0x759ae259ff5d0b6c, 0xf8e0542fa8f04a81,
            0x26f35adef2b0f0c1, 0xab9b31c67cd0fc88, 0xfd07224f3469265a, 0x802c4382f93cbd93,
            0x1ce69403a5dae54f, 0x3a55e97ece5a443e, 0x110b1fe2ed631776, 0x0c508f724d4d2887,
            0xd2790fee5e8a7f88, 0xc34c571d9187d30a, 0x25fab711cf5216ea, 0x8c167aec0b61cbde,
            0x156a0f96394f8416, 0x8c33ace15be7cfe1, 0x54d63be132cb02d8, 0x96d9a52fe9583d3a,
            0x6a03401c2b4b8962, 0xbf0fd9e9905ffe8a, 0x4d98c13703ed294b, 0xabe7f78eb0926773,
            0xc57c7283c0279e3e, 0x55688993d2a8aa29, 0x68c962a407ffdfbc, 0x87f116892b66367e,
            0x02ec1b19d89cf15a, 0xaaaa4408bd161907, 0x627d5fbf00476bca, 0x8bdaf575fc831cd2,
            0x31f2952e2739bd13, 0xb01bf13f412bc679, 0xf762817302e6d4f4, 0x110b1fe2ed631776,
            0xcfa82889bd08d775, 0xd2790fee5e8a7f88, 0xc34c571d9187d30a, 0x25fab711cf5216ea,
            0x8c167aec0b61cbde, 0x51b14c0e55e283ac, 0x28265ad30801ce0f, 0x54d63be132cb02d8,
            0x10284964940a3540, 0x59a20dac63f49534, 0xea9cb6c5f3b442b1, 0xb34fbf851f861fe9,
            0x13a448ae83f37603, 0x8d3add22c57a6c80, 0x750ad4883102755d, 0x96d727207bba5143,
            0x16eafbc721f16efb, 0x1f788660806b80fa, 0x802c4382f93cbd93, 0xd1b0858428908384,
            0x8fb6106cc7bea021, 0x98bb26ec17da986a, 0xe6651bc2ff5d0c4f, 0xe3724cb377df715c,
            0x3609bbc4db39611b, 0x36855fbd84dc0781, 0xc34c571d9187d30a, 0xd2790fee5e8a7f88,
            0x54d63be132cb02d8, 0x8c167aec0b61cbde, 0x184fe8c236cf04c1, 0x52dc34e2ac6a9178
        ], blocks: 24)
    // _extrgb_rgb_convert @ 0x3854: 26 rows; SHA-256 5ec350ffd70d93a29f4b3f136953fa621abb1cdd4b0a7a9e3a50715a84672a66.
    // Capture: scalar-memory-input-diagnostic/metadata.json.document-metadata.json.
    private static let rgbToPlanes8 = MemorySeed(base: 0x3854, name: "_extrgb_rgb_convert",
        kind: .rgbToPlanes8, bytes: """
        9f 04 00 71 0b 03 00 54 08 30 40 b9 28 02 00 34
        49 28 40 a9 29 59 63 f8 4a 59 63 f8 4b 08 40 f9
        6b 59 63 f8 2c 00 40 f9 ed 03 08 aa 8e 01 40 39
        2e 15 00 38 8e 05 40 39 4e 15 00 38 8e 09 40 39
        6e 15 00 38 8c 0d 00 91 ad 05 00 f1 01 ff ff 54
        21 20 00 91 63 04 00 11 9f 08 00 71 84 04 00 51
        62 fd ff 54 c0 03 5f d6
        """, text: """
        cmp w4, #1
        b.lt 0x00000000000038b8
        ldr w8, [x0, #0x30]
        cbz w8, 0x00000000000038a4
        ldp x9, x10, [x2]
        ldr x9, [x9, w3, uxtw #3]
        ldr x10, [x10, w3, uxtw #3]
        ldr x11, [x2, #0x10]
        ldr x11, [x11, w3, uxtw #3]
        ldr x12, [x1]
        mov x13, x8
        ldrb w14, [x12]
        strb w14, [x9], #1
        ldrb w14, [x12, #1]
        strb w14, [x10], #1
        ldrb w14, [x12, #2]
        strb w14, [x11], #1
        add x12, x12, #3
        subs x13, x13, #1
        b.ne 0x0000000000003880
        add x1, x1, #8
        add w3, w3, #1
        cmp w4, #2
        sub w4, w4, #1
        b.hs 0x0000000000003860
        ret
        """, unavailable: [10, 25], operandWitnesses: [
            0x54d63be132cb02d8, 0x3a0feacb6e6c9c8a, 0xecd3bb873353f7da, 0x2ff9d01d975a9933,
            0xa55eeb7979a9bcc7, 0x2185f1b0dfdd3a14, 0xb82ac1f7b8a9bdbc, 0xf9e09d83f8ae8569,
            0xfd53b4433cde7ffa, 0xcf4d496e1e30031a, 0x87f116892b66367e, 0x31a634b57f5154e9,
            0x4d6e3a9b940398ec, 0xbbcd144d4e891122, 0xf8f80bdee9e12e06, 0xb70d6481f678fdcf,
            0xfcaec20a07946d61, 0xf762817302e6d4f4, 0x110b1fe2ed631776, 0xd6e019ff1d50a2ed,
            0xf9b089671436a422, 0x4a6d15638bc6e4fe, 0x25fab711cf5216ea, 0x8c167aec0b61cbde,
            0xe926230baedf6779, 0x52dc34e2ac6a9178
        ], blocks: 7)
    // _rgb_extbgr_convert @ 0x29a70: 27 rows; SHA-256 d8c4c7bc376bca371d43cd0695b6c2157e6f61d80742dd1039c301a6d30bead5.
    // Capture: scalar-memory-input-diagnostic/metadata.json.document-metadata.json.
    private static let planesToBGR16 = MemorySeed(base: 0x29a70, name: "_rgb_extbgr_convert",
        kind: .planesToBGR16, bytes: """
        9f 04 00 71 2b 03 00 54 08 88 40 b9 29 28 40 a9
        2b 08 40 f9 08 02 00 34 2c 59 62 f8 4d 59 62 f8
        6e 59 62 f8 6f 00 40 f9 ef 11 00 91 f0 03 08 aa
        91 25 40 78 f1 01 00 79 b1 25 40 78 f1 e1 1f 78
        d1 25 40 78 f1 c1 1f 78 ef 19 00 91 10 06 00 f1
        01 ff ff 54 42 04 00 11 63 20 00 91 9f 08 00 71
        84 04 00 51 82 fd ff 54 c0 03 5f d6
        """, text: """
        cmp w4, #1
        b.lt 0x0000000000029ad8
        ldr w8, [x0, #0x88]
        ldp x9, x10, [x1]
        ldr x11, [x1, #0x10]
        cbz w8, 0x0000000000029ac4
        ldr x12, [x9, w2, uxtw #3]
        ldr x13, [x10, w2, uxtw #3]
        ldr x14, [x11, w2, uxtw #3]
        ldr x15, [x3]
        add x15, x15, #4
        mov x16, x8
        ldrh w17, [x12], #2
        strh w17, [x15]
        ldrh w17, [x13], #2
        sturh w17, [x15, #-0x2]
        ldrh w17, [x14], #2
        sturh w17, [x15, #-0x4]
        add x15, x15, #6
        subs x16, x16, #1
        b.ne 0x0000000000029aa0
        add w2, w2, #1
        add x3, x3, #8
        cmp w4, #2
        sub w4, w4, #1
        b.hs 0x0000000000029a84
        ret
        """, unavailable: [11, 26], operandWitnesses: [
            0x54d63be132cb02d8, 0x9082f83018dbc67a, 0x97b28c34cdef8d60, 0xbf0fd9e9905ffe8a,
            0xc57c7283c0279e3e, 0x9e71426b86a8d4c9, 0x7312638106ef2e43, 0x39f2557465d4db4e,
            0xa53bfd3f3650e2aa, 0x7c448cafcac81acd, 0xcbe7153d8e499546, 0xc97f2db3e56717f6,
            0x1ce9b5d0e088a6ff, 0xad066adc5f730448, 0x96cd52f6524d1188, 0xfad86c550ae833bc,
            0xc2cfe0230734d035, 0x5c7abbf379f3b81a, 0xbad21de3dbd974a6, 0x11b443bfe27bc83e,
            0x1e60abb89ca07cc1, 0xd2790fee5e8a7f88, 0xc34c571d9187d30a, 0x25fab711cf5216ea,
            0x8c167aec0b61cbde, 0x7cc5c3646efdcb05, 0x52dc34e2ac6a9178
        ], blocks: 7)
    // _extbgr_rgb_convert @ 0x3924: 27 rows; SHA-256 c6b835adeb38378e1eb848c48b19b2b09c3bf08f33830dc8938f426773d3b6aa.
    // Capture: scalar-memory-and-rejoin-input-diagnostic/metadata.json.document-metadata.json.
    private static let bgrToPlanes8 = MemorySeed(base: 0x3924, name: "_extbgr_rgb_convert",
        kind: .bgrToPlanes8, bytes: """
        9f 04 00 71 2b 03 00 54 08 30 40 b9 48 02 00 34
        49 28 40 a9 29 59 63 f8 4a 59 63 f8 4b 08 40 f9
        6b 59 63 f8 2c 00 40 f9 8c 09 00 91 ed 03 08 aa
        8e 01 40 39 2e 15 00 38 8e f1 5f 38 4e 15 00 38
        8e e1 5f 38 6e 15 00 38 8c 0d 00 91 ad 05 00 f1
        01 ff ff 54 21 20 00 91 63 04 00 11 9f 08 00 71
        84 04 00 51 42 fd ff 54 c0 03 5f d6
        """, text: """
        cmp w4, #1
        b.lt 0x000000000000398c
        ldr w8, [x0, #0x30]
        cbz w8, 0x0000000000003978
        ldp x9, x10, [x2]
        ldr x9, [x9, w3, uxtw #3]
        ldr x10, [x10, w3, uxtw #3]
        ldr x11, [x2, #0x10]
        ldr x11, [x11, w3, uxtw #3]
        ldr x12, [x1]
        add x12, x12, #2
        mov x13, x8
        ldrb w14, [x12]
        strb w14, [x9], #1
        ldurb w14, [x12, #-0x1]
        strb w14, [x10], #1
        ldurb w14, [x12, #-0x2]
        strb w14, [x11], #1
        add x12, x12, #3
        subs x13, x13, #1
        b.ne 0x0000000000003954
        add x1, x1, #8
        add w3, w3, #1
        cmp w4, #2
        sub w4, w4, #1
        b.hs 0x0000000000003930
        ret
        """, unavailable: [11, 26], operandWitnesses: [
            0x54d63be132cb02d8, 0x6607fb9bb9b64acd, 0xecd3bb873353f7da, 0x84605c1cc024eb73,
            0xa55eeb7979a9bcc7, 0x2185f1b0dfdd3a14, 0xb82ac1f7b8a9bdbc, 0xf9e09d83f8ae8569,
            0xfd53b4433cde7ffa, 0xcf4d496e1e30031a, 0xdcfd92a7ef706732, 0x87f116892b66367e,
            0x31a634b57f5154e9, 0x4d6e3a9b940398ec, 0x3db6e828ad6e5b2c, 0xf8f80bdee9e12e06,
            0x7cbe0fc347e93325, 0xfcaec20a07946d61, 0xf762817302e6d4f4, 0x110b1fe2ed631776,
            0xc83e971da8c89bef, 0xf9b089671436a422, 0x4a6d15638bc6e4fe, 0x25fab711cf5216ea,
            0x8c167aec0b61cbde, 0x591f31482284ec62, 0x52dc34e2ac6a9178
        ], blocks: 7)
    // _extbgr_rgb_convert @ 0x4e84: 27 rows; SHA-256 0759ca1642f541645306f4f41da6ba64a2fb6433f98c136ae02fcc4be7554b66.
    // Capture: scalar-memory-and-rejoin-input-diagnostic/metadata.json.document-metadata.json.
    private static let bgrToPlanes16 = MemorySeed(base: 0x4e84, name: "_extbgr_rgb_convert",
        kind: .bgrToPlanes16, bytes: """
        9f 04 00 71 2b 03 00 54 08 30 40 b9 49 28 40 a9
        4b 08 40 f9 08 02 00 34 2c 59 63 f8 4d 59 63 f8
        6e 59 63 f8 2f 00 40 f9 ef 11 00 91 f0 03 08 aa
        f1 01 40 79 91 25 00 78 f1 e1 5f 78 b1 25 00 78
        f1 c1 5f 78 d1 25 00 78 ef 19 00 91 10 06 00 f1
        01 ff ff 54 21 20 00 91 63 04 00 11 9f 08 00 71
        84 04 00 51 82 fd ff 54 c0 03 5f d6
        """, text: """
        cmp w4, #1
        b.lt 0x0000000000004eec
        ldr w8, [x0, #0x30]
        ldp x9, x10, [x2]
        ldr x11, [x2, #0x10]
        cbz w8, 0x0000000000004ed8
        ldr x12, [x9, w3, uxtw #3]
        ldr x13, [x10, w3, uxtw #3]
        ldr x14, [x11, w3, uxtw #3]
        ldr x15, [x1]
        add x15, x15, #4
        mov x16, x8
        ldrh w17, [x15]
        strh w17, [x12], #2
        ldurh w17, [x15, #-0x2]
        strh w17, [x13], #2
        ldurh w17, [x15, #-0x4]
        strh w17, [x14], #2
        add x15, x15, #6
        subs x16, x16, #1
        b.ne 0x0000000000004eb4
        add x1, x1, #8
        add w3, w3, #1
        cmp w4, #2
        sub w4, w4, #1
        b.hs 0x0000000000004e98
        ret
        """, unavailable: [11, 26], operandWitnesses: [
            0x54d63be132cb02d8, 0x430435fd373b9244, 0xecd3bb873353f7da, 0xa55eeb7979a9bcc7,
            0xf9e09d83f8ae8569, 0xa87df111cdbbd9be, 0x58df47dc1e320f4c, 0xa92a7b536230088d,
            0xb8cb2940effe5c19, 0xa70278c2d7098c47, 0xcbe7153d8e499546, 0xc97f2db3e56717f6,
            0x793d4169951724ae, 0xc275e1c1dfc96cd7, 0x27b45967d9d94baa, 0xab27c43dee6b452a,
            0x042089de3035d3cc, 0x75423cb607c0a8dd, 0xbad21de3dbd974a6, 0x11b443bfe27bc83e,
            0xdfb186b7bb6ae8f4, 0xf9b089671436a422, 0x4a6d15638bc6e4fe, 0x25fab711cf5216ea,
            0x8c167aec0b61cbde, 0x9e4ea7e8dc0a22ba, 0x52dc34e2ac6a9178
        ], blocks: 7)
    // _rgb_extbgr_convert @ 0x27d58: 27 rows; SHA-256 405aaf78f6a203cc8df663862efd3622a9e6b50767a72b24ff1d37b42c165f33.
    // Capture: scalar-memory-and-rejoin-input-diagnostic/metadata.json.document-metadata.json.
    private static let planesToBGR8 = MemorySeed(base: 0x27d58, name: "_rgb_extbgr_convert",
        kind: .planesToBGR8, bytes: """
        9f 04 00 71 2b 03 00 54 08 88 40 b9 48 02 00 34
        29 28 40 a9 29 59 62 f8 4a 59 62 f8 2b 08 40 f9
        6b 59 62 f8 6c 00 40 f9 8c 09 00 91 ed 03 08 aa
        2e 15 40 38 8e 01 00 39 4e 15 40 38 8e f1 1f 38
        6e 15 40 38 8e e1 1f 38 8c 0d 00 91 ad 05 00 f1
        01 ff ff 54 42 04 00 11 63 20 00 91 9f 08 00 71
        84 04 00 51 42 fd ff 54 c0 03 5f d6
        """, text: """
        cmp w4, #1
        b.lt 0x0000000000027dc0
        ldr w8, [x0, #0x88]
        cbz w8, 0x0000000000027dac
        ldp x9, x10, [x1]
        ldr x9, [x9, w2, uxtw #3]
        ldr x10, [x10, w2, uxtw #3]
        ldr x11, [x1, #0x10]
        ldr x11, [x11, w2, uxtw #3]
        ldr x12, [x3]
        add x12, x12, #2
        mov x13, x8
        ldrb w14, [x9], #1
        strb w14, [x12]
        ldrb w14, [x10], #1
        sturb w14, [x12, #-0x1]
        ldrb w14, [x11], #1
        sturb w14, [x12, #-0x2]
        add x12, x12, #3
        subs x13, x13, #1
        b.ne 0x0000000000027d88
        add w2, w2, #1
        add x3, x3, #8
        cmp w4, #2
        sub w4, w4, #1
        b.hs 0x0000000000027d64
        ret
        """, unavailable: [11, 26], operandWitnesses: [
            0x54d63be132cb02d8, 0x288d29140a3de332, 0x97b28c34cdef8d60, 0x3105d7b71d217984,
            0xbf0fd9e9905ffe8a, 0x4d98c13703ed294b, 0xabe7f78eb0926773, 0xc57c7283c0279e3e,
            0x55688993d2a8aa29, 0x68c962a407ffdfbc, 0xdcfd92a7ef706732, 0x87f116892b66367e,
            0x02ec1b19d89cf15a, 0xaaaa4408bd161907, 0x627d5fbf00476bca, 0x9628676fd3ca3afc,
            0x31f2952e2739bd13, 0xa8e72ead7aba865f, 0xf762817302e6d4f4, 0x110b1fe2ed631776,
            0xa2e8e8f02ddab2ad, 0xd2790fee5e8a7f88, 0xc34c571d9187d30a, 0x25fab711cf5216ea,
            0x8c167aec0b61cbde, 0x5cb91e34e8338c94, 0x52dc34e2ac6a9178
        ], blocks: 7)
    // _null_convert @ 0x4c58: 87 rows; SHA-256 428963c15791d510245d33adf31134f5579310fd721e701c9087ef82cd5c3edb.
    // Capture: scalar-memory-input-diagnostic/metadata.json.document-metadata.json.
    private static let returnHalfwordInput = MemorySeed(base: 0x4c58, name: "_null_convert",
        kind: nil, bytes: """
        09 5c 40 b9 08 30 40 b9 3f 0d 00 71 e0 03 00 54
        3f 11 00 71 c1 06 00 54 9f 04 00 71 eb 09 00 54
        49 28 40 a9 4b 30 41 a9 48 02 00 34 2d 59 63 f8
        4e 59 63 f8 ef 03 08 aa 70 59 63 f8 91 59 63 f8
        20 00 40 f9 02 00 40 79 a2 25 00 78 02 04 40 79
        c2 25 00 78 02 08 40 79 02 26 00 78 02 0c 40 79
        22 26 00 78 00 20 00 91 ef 05 00 f1 c1 fe ff 54
        21 20 00 91 63 04 00 11 9f 08 00 71 84 04 00 51
        c3 06 00 54 e9 ff ff 17 9f 04 00 71 6b 06 00 54
        49 28 40 a9 4b 08 40 f9 e8 01 00 34 2c 59 63 f8
        4d 59 63 f8 ee 03 08 aa 6f 59 63 f8 30 00 40 f9
        11 02 40 79 91 25 00 78 11 06 40 79 b1 25 00 78
        11 0a 40 79 f1 25 00 78 10 1a 00 91 ce 05 00 f1
        01 ff ff 54 21 20 00 91 63 04 00 11 9f 08 00 71
        84 04 00 51 a3 03 00 54 ec ff ff 17 9f 04 00 71
        4b 03 00 54 2a 7d 40 93 4b f9 7f d3 5f 05 00 71
        2b 02 00 54 0c 00 80 d2 2d 00 40 f9 48 01 00 34
        4e 78 6c f8 ce 59 63 f8 ef 03 0d aa f0 03 08 aa
        f1 01 40 79 d1 25 00 78 ef 01 0b 8b 10 06 00 f1
        81 ff ff 54 8c 05 00 91 ad 09 00 91 9f 01 09 eb
        61 fe ff 54 21 20 00 91 63 04 00 11 9f 04 00 71
        84 04 00 51 4c fd ff 54 c0 03 5f d6
        """, text: """
        ldr w9, [x0, #0x5c]
        ldr w8, [x0, #0x30]
        cmp w9, #3
        b.eq 0x0000000000004ce0
        cmp w9, #4
        b.ne 0x0000000000004d44
        cmp w4, #1
        b.lt 0x0000000000004db0
        ldp x9, x10, [x2]
        ldp x11, x12, [x2, #0x10]
        cbz w8, 0x0000000000004cc8
        ldr x13, [x9, w3, uxtw #3]
        ldr x14, [x10, w3, uxtw #3]
        mov x15, x8
        ldr x16, [x11, w3, uxtw #3]
        ldr x17, [x12, w3, uxtw #3]
        ldr x0, [x1]
        ldrh w2, [x0]
        strh w2, [x13], #2
        ldrh w2, [x0, #2]
        strh w2, [x14], #2
        ldrh w2, [x0, #4]
        strh w2, [x16], #2
        ldrh w2, [x0, #6]
        strh w2, [x17], #2
        add x0, x0, #8
        subs x15, x15, #1
        b.ne 0x0000000000004c9c
        add x1, x1, #8
        add w3, w3, #1
        cmp w4, #2
        sub w4, w4, #1
        b.lo 0x0000000000004db0
        b 0x0000000000004c80
        cmp w4, #1
        b.lt 0x0000000000004db0
        ldp x9, x10, [x2]
        ldr x11, [x2, #0x10]
        cbz w8, 0x0000000000004d2c
        ldr x12, [x9, w3, uxtw #3]
        ldr x13, [x10, w3, uxtw #3]
        mov x14, x8
        ldr x15, [x11, w3, uxtw #3]
        ldr x16, [x1]
        ldrh w17, [x16]
        strh w17, [x12], #2
        ldrh w17, [x16, #2]
        strh w17, [x13], #2
        ldrh w17, [x16, #4]
        strh w17, [x15], #2
        add x16, x16, #6
        subs x14, x14, #1
        b.ne 0x0000000000004d08
        add x1, x1, #8
        add w3, w3, #1
        cmp w4, #2
        sub w4, w4, #1
        b.lo 0x0000000000004db0
        b 0x0000000000004cf0
        cmp w4, #1
        b.lt 0x0000000000004db0
        sxtw x10, w9
        lsl x11, x10, #1
        cmp w10, #1
        b.lt 0x0000000000004d9c
        mov x12, #0
        ldr x13, [x1]
        cbz w8, 0x0000000000004d8c
        ldr x14, [x2, x12, lsl #3]
        ldr x14, [x14, w3, uxtw #3]
        mov x15, x13
        mov x16, x8
        ldrh w17, [x15]
        strh w17, [x14], #2
        add x15, x15, x11
        subs x16, x16, #1
        b.ne 0x0000000000004d78
        add x12, x12, #1
        add x13, x13, #2
        cmp x12, x9
        b.ne 0x0000000000004d64
        add x1, x1, #8
        add w3, w3, #1
        cmp w4, #1
        sub w4, w4, #1
        b.gt 0x0000000000004d54
        ret
        """, unavailable: [13, 41, 61, 62, 70, 71, 86], operandWitnesses: [
            0x114dcd541909305e, 0xecd3bb873353f7da, 0x8ca33218f2e1396d, 0x71a779a57c59dbc7,
            0x7b7130b8866e0873, 0x81b5a4b5ef44fd07, 0x54d63be132cb02d8, 0x01886de14672a292,
            0xa55eeb7979a9bcc7, 0xc3a54d9862fed13f, 0x0838ba6020030ddf, 0x091dd0bd4f9c7591,
            0xf3c25d9f8aed2fe0, 0x16a09895dcb1603a, 0x51e4191c0575df53, 0x065f9c8ec5cc585b,
            0x93632d518472dde1, 0x3e8f26a35fa29d06, 0xddd9121540758c3a, 0x3bfabd0a365ebe64,
            0xb4f6f846582b7aad, 0x1189d4e405f8a602, 0x95eb9d0db9858033, 0x118a40f82d386700,
            0x9688954ceecdcdf6, 0x7676d819a89f1fc4, 0x615596a7e9195bc2, 0xb12f534bcdc30385,
            0xf9b089671436a422, 0x4a6d15638bc6e4fe, 0x25fab711cf5216ea, 0x8c167aec0b61cbde,
            0xb58c6de0fc4989ad, 0xf12e45657ec9a962, 0x54d63be132cb02d8, 0xb9dc8da58d297d6a,
            0xa55eeb7979a9bcc7, 0xf9e09d83f8ae8569, 0x68d293c40601aa66, 0x58df47dc1e320f4c,
            0xa92a7b536230088d, 0x1f788660806b80fa, 0x294374b966902b5e, 0xa28a7c71f082423e,
            0xc1e9543eed1be9ef, 0xc275e1c1dfc96cd7, 0x9027714d400101a5, 0xab27c43dee6b452a,
            0xc9556a5f7a2a56fb, 0x87923d50e0804130, 0xf1e7ca48d2f9dae2, 0x98bb26ec17da986a,
            0x1b50a48107217fa1, 0xf9b089671436a422, 0x4a6d15638bc6e4fe, 0x25fab711cf5216ea,
            0x8c167aec0b61cbde, 0xae6d8495271b5fe1, 0xf912a6adafccffb0, 0x54d63be132cb02d8,
            0x5f450ef58fd84fa2, 0x59a20dac63f49534, 0xe493bfcaa9521fca, 0xea9cb6c5f3b442b1,
            0x1a6d7d07db03298c, 0x212f1310ed32d18a, 0x7975a1a58f246ba1, 0xbc39331463736ee2,
            0x8860c1bf43099b63, 0x9368323c2b53ebc4, 0xfbf48e1847f8cab4, 0xc97f2db3e56717f6,
            0x793d4169951724ae, 0x75423cb607c0a8dd, 0x3e143bb2403ac9c6, 0x11b443bfe27bc83e,
            0x1a840ee00c901eb9, 0x05b10b8b6a75a250, 0xbb7d567f8fc6f12a, 0x3b2dac41a55b6d04,
            0xdca4a8e4d078c9fb, 0xf9b089671436a422, 0x4a6d15638bc6e4fe, 0x54d63be132cb02d8,
            0x8c167aec0b61cbde, 0x720964687948de66, 0x52dc34e2ac6a9178
        ], blocks: 26)
    // _null_convert @ 0x2983c: 87 rows; SHA-256 ad0f3dfa47251940d4c3b69b57a69f18ae606502537e756ab64e40336295d347.
    // Capture: scalar-memory-input-diagnostic/metadata.json.document-metadata.json.
    private static let returnHalfwordOutput = MemorySeed(base: 0x2983c, name: "_null_convert",
        kind: nil, bytes: """
        09 38 40 b9 08 88 40 b9 3f 0d 00 71 e0 03 00 54
        3f 11 00 71 c1 06 00 54 9f 04 00 71 eb 09 00 54
        29 28 40 a9 2b 30 41 a9 48 02 00 34 2d 59 62 f8
        4e 59 62 f8 ef 03 08 aa 70 59 62 f8 91 59 62 f8
        60 00 40 f9 a1 25 40 78 01 00 00 79 c1 25 40 78
        01 04 00 79 01 26 40 78 01 08 00 79 21 26 40 78
        01 0c 00 79 00 20 00 91 ef 05 00 f1 c1 fe ff 54
        42 04 00 11 63 20 00 91 9f 08 00 71 84 04 00 51
        c3 06 00 54 e9 ff ff 17 9f 04 00 71 6b 06 00 54
        29 28 40 a9 2b 08 40 f9 e8 01 00 34 2c 59 62 f8
        4d 59 62 f8 ee 03 08 aa 6f 59 62 f8 70 00 40 f9
        91 25 40 78 11 02 00 79 b1 25 40 78 11 06 00 79
        f1 25 40 78 11 0a 00 79 10 1a 00 91 ce 05 00 f1
        01 ff ff 54 42 04 00 11 63 20 00 91 9f 08 00 71
        84 04 00 51 a3 03 00 54 ec ff ff 17 9f 04 00 71
        4b 03 00 54 2a 7d 40 93 4b f9 7f d3 5f 05 00 71
        2b 02 00 54 0c 00 80 d2 6d 00 40 f9 48 01 00 34
        2e 78 6c f8 ce 59 62 f8 ef 03 0d aa f0 03 08 aa
        d1 25 40 78 f1 01 00 79 ef 01 0b 8b 10 06 00 f1
        81 ff ff 54 8c 05 00 91 ad 09 00 91 9f 01 09 eb
        61 fe ff 54 63 20 00 91 42 04 00 11 9f 04 00 71
        84 04 00 51 4c fd ff 54 c0 03 5f d6
        """, text: """
        ldr w9, [x0, #0x38]
        ldr w8, [x0, #0x88]
        cmp w9, #3
        b.eq 0x00000000000298c4
        cmp w9, #4
        b.ne 0x0000000000029928
        cmp w4, #1
        b.lt 0x0000000000029994
        ldp x9, x10, [x1]
        ldp x11, x12, [x1, #0x10]
        cbz w8, 0x00000000000298ac
        ldr x13, [x9, w2, uxtw #3]
        ldr x14, [x10, w2, uxtw #3]
        mov x15, x8
        ldr x16, [x11, w2, uxtw #3]
        ldr x17, [x12, w2, uxtw #3]
        ldr x0, [x3]
        ldrh w1, [x13], #2
        strh w1, [x0]
        ldrh w1, [x14], #2
        strh w1, [x0, #2]
        ldrh w1, [x16], #2
        strh w1, [x0, #4]
        ldrh w1, [x17], #2
        strh w1, [x0, #6]
        add x0, x0, #8
        subs x15, x15, #1
        b.ne 0x0000000000029880
        add w2, w2, #1
        add x3, x3, #8
        cmp w4, #2
        sub w4, w4, #1
        b.lo 0x0000000000029994
        b 0x0000000000029864
        cmp w4, #1
        b.lt 0x0000000000029994
        ldp x9, x10, [x1]
        ldr x11, [x1, #0x10]
        cbz w8, 0x0000000000029910
        ldr x12, [x9, w2, uxtw #3]
        ldr x13, [x10, w2, uxtw #3]
        mov x14, x8
        ldr x15, [x11, w2, uxtw #3]
        ldr x16, [x3]
        ldrh w17, [x12], #2
        strh w17, [x16]
        ldrh w17, [x13], #2
        strh w17, [x16, #2]
        ldrh w17, [x15], #2
        strh w17, [x16, #4]
        add x16, x16, #6
        subs x14, x14, #1
        b.ne 0x00000000000298ec
        add w2, w2, #1
        add x3, x3, #8
        cmp w4, #2
        sub w4, w4, #1
        b.lo 0x0000000000029994
        b 0x00000000000298d4
        cmp w4, #1
        b.lt 0x0000000000029994
        sxtw x10, w9
        lsl x11, x10, #1
        cmp w10, #1
        b.lt 0x0000000000029980
        mov x12, #0
        ldr x13, [x3]
        cbz w8, 0x0000000000029970
        ldr x14, [x1, x12, lsl #3]
        ldr x14, [x14, w2, uxtw #3]
        mov x15, x13
        mov x16, x8
        ldrh w17, [x14], #2
        strh w17, [x15]
        add x15, x15, x11
        subs x16, x16, #1
        b.ne 0x000000000002995c
        add x12, x12, #1
        add x13, x13, #2
        cmp x12, x9
        b.ne 0x0000000000029948
        add x3, x3, #8
        add w2, w2, #1
        cmp w4, #1
        sub w4, w4, #1
        b.gt 0x0000000000029938
        ret
        """, unavailable: [13, 41, 61, 62, 70, 71, 86], operandWitnesses: [
            0x0231d172788a590e, 0x97b28c34cdef8d60, 0x8ca33218f2e1396d, 0x5b6236ee407a98cc,
            0x7b7130b8866e0873, 0xfadb1db267f88650, 0x54d63be132cb02d8, 0xaef7eb6e13ce77fd,
            0xbf0fd9e9905ffe8a, 0x3d1ac1e2578b0260, 0x370c95386011f782, 0x18ae70af423e6fa2,
            0xb3143a99853f7d27, 0x16a09895dcb1603a, 0x3ff8e45b160e201c, 0x72312f69c96e60a4,
            0xf466c0bbfe255a3b, 0xbdc1fbc1a3d95afd, 0xbe22b1d9ee94a297, 0x58be354e1b6b8e90,
            0x6088c3d264693629, 0x45a86b6239f826fa, 0xd8188d2514760183, 0xf5cd4abe91cd0969,
            0xe5fb08437229ddb5, 0x7676d819a89f1fc4, 0x615596a7e9195bc2, 0xbd29984aa23790f4,
            0xd2790fee5e8a7f88, 0xc34c571d9187d30a, 0x25fab711cf5216ea, 0x8c167aec0b61cbde,
            0xf84958fd16f44cb4, 0xf8ff8f34beb0fc41, 0x54d63be132cb02d8, 0xd9cf5d239cd2a313,
            0xbf0fd9e9905ffe8a, 0xc57c7283c0279e3e, 0x03b8ed3ace4270d9, 0x7312638106ef2e43,
            0x39f2557465d4db4e, 0x1f788660806b80fa, 0x3f8d7e8eb942bd5d, 0xae78adfd7622d2f0,
            0x1ce9b5d0e088a6ff, 0x1dbadd44674fc147, 0x96cd52f6524d1188, 0x4629dad232c66f59,
            0x6425256b602add56, 0x0271c4f1d78125f3, 0xf1e7ca48d2f9dae2, 0x98bb26ec17da986a,
            0xb868d419c3300892, 0xd2790fee5e8a7f88, 0xc34c571d9187d30a, 0x25fab711cf5216ea,
            0x8c167aec0b61cbde, 0xa3575d34c436560a, 0x76b203cedc9a0459, 0x54d63be132cb02d8,
            0x7c49b412b0fcdba5, 0x59a20dac63f49534, 0xe493bfcaa9521fca, 0xea9cb6c5f3b442b1,
            0x5cfec2c9bd9219c3, 0x212f1310ed32d18a, 0x16eafbc721f16efb, 0xf7709122c3367815,
            0xc31a42f09eacbe5c, 0xb1a3eb313e97dffb, 0xfbf48e1847f8cab4, 0xc97f2db3e56717f6,
            0xc2cfe0230734d035, 0xad066adc5f730448, 0x3e143bb2403ac9c6, 0x11b443bfe27bc83e,
            0x53369788c88276c0, 0x05b10b8b6a75a250, 0xbb7d567f8fc6f12a, 0x3b2dac41a55b6d04,
            0x52c9a986632dcca2, 0xc34c571d9187d30a, 0xd2790fee5e8a7f88, 0x54d63be132cb02d8,
            0x8c167aec0b61cbde, 0xca6ff063a44f6747, 0x52dc34e2ac6a9178
        ], blocks: 26)
    // _extxrgb_ycc_convert @ 0x3f18: 49 rows; SHA-256 ff160d794edddb8d4bd1f78b41bce877b323e3a81497cf0552391373e686eab8.
    // Capture: scalar-memory-input-diagnostic/metadata.json.document-metadata.json.
    private static let returnYCC = MemorySeed(base: 0x3f18, name: "_extxrgb_ycc_convert",
        kind: nil, bytes: """
        9f 04 00 71 eb 05 00 54 08 0c 41 f9 08 15 40 f9
        09 30 40 b9 c9 04 00 34 4a 2c 40 a9 4a 59 63 f8
        6b 59 63 f8 4c 08 40 f9 8c 59 63 f8 2d 00 40 f9
        ad 0d 00 91 ee 03 09 aa af e1 5f 38 b0 f1 5f 38
        b1 45 40 38 0f 0d 0f 8b e0 01 40 f9 10 0d 10 8b
        05 02 48 b9 11 0d 11 8b 26 02 50 b9 a0 00 00 0b
        00 00 06 0b 00 7c 10 53 40 15 00 38 e0 01 58 b9
        05 02 60 b9 26 02 68 b9 a0 00 00 0b 00 00 06 0b
        00 7c 10 53 60 15 00 38 ef 01 68 b9 10 02 70 b9
        31 02 78 b9 0f 02 0f 0b ef 01 11 0b ef 7d 10 53
        8f 15 00 38 ce 05 00 f1 81 fc ff 54 21 20 00 91
        63 04 00 11 9f 08 00 71 84 04 00 51 c2 fa ff 54
        c0 03 5f d6
        """, text: """
        cmp w4, #1
        b.lt 0x0000000000003fd8
        ldr x8, [x0, #0x218]
        ldr x8, [x8, #0x28]
        ldr w9, [x0, #0x30]
        cbz w9, 0x0000000000003fc4
        ldp x10, x11, [x2]
        ldr x10, [x10, w3, uxtw #3]
        ldr x11, [x11, w3, uxtw #3]
        ldr x12, [x2, #0x10]
        ldr x12, [x12, w3, uxtw #3]
        ldr x13, [x1]
        add x13, x13, #3
        mov x14, x9
        ldurb w15, [x13, #-0x2]
        ldurb w16, [x13, #-0x1]
        ldrb w17, [x13], #4
        add x15, x8, x15, lsl #3
        ldr x0, [x15]
        add x16, x8, x16, lsl #3
        ldr w5, [x16, #0x800]
        add x17, x8, x17, lsl #3
        ldr w6, [x17, #0x1000]
        add w0, w5, w0
        add w0, w0, w6
        lsr w0, w0, #16
        strb w0, [x10], #1
        ldr w0, [x15, #0x1800]
        ldr w5, [x16, #0x2000]
        ldr w6, [x17, #0x2800]
        add w0, w5, w0
        add w0, w0, w6
        lsr w0, w0, #16
        strb w0, [x11], #1
        ldr w15, [x15, #0x2800]
        ldr w16, [x16, #0x3000]
        ldr w17, [x17, #0x3800]
        add w15, w16, w15
        add w15, w15, w17
        lsr w15, w15, #16
        strb w15, [x12], #1
        subs x14, x14, #1
        b.ne 0x0000000000003f50
        add x1, x1, #8
        add w3, w3, #1
        cmp w4, #2
        sub w4, w4, #1
        b.hs 0x0000000000003f2c
        ret
        """, unavailable: [13, 25, 32, 39, 48], operandWitnesses: [
            0x54d63be132cb02d8, 0x08e5d1f2c396fab8, 0x532ba69585584e54, 0x8a8f6f7bc2bf1c1c,
            0x90def8b820161d3f, 0x1ddfc3034d5a0473, 0x0e29f92bd8735e62, 0xb82ac1f7b8a9bdbc,
            0xfd53b4433cde7ffa, 0xb2935a82981c8b52, 0x7ca40b7b92fd324c, 0x7975a1a58f246ba1,
            0x79faee3aaefe568c, 0xe2777d1d45946d7a, 0x2e5ef7ecd150129b, 0x70ec8754301b5ead,
            0xfa92b7cf5afa8fa7, 0x53981904b62f09e1, 0x63e9e0649ca664be, 0x0e7b80330d5e36fb,
            0xa390cbc2cf968b4e, 0x0e48d3d16f6a9e89, 0x3332e819acad1819, 0x971b483999204c50,
            0x9716fef0ff53714b, 0x391d75e12c6e6dd2, 0x4d33e51b2e6230c7, 0x4a06e6ec5445f4df,
            0x06d6e7c6121e03b8, 0x2cf7bb67d78c0eaf, 0x971b483999204c50, 0x9716fef0ff53714b,
            0x391d75e12c6e6dd2, 0xf81ccdc4a9ad6314, 0x7026f3182f240779, 0xc6959790692fd381,
            0x8072b45264ffac67, 0x421e463885854922, 0xc8947cd04ebaa8a1, 0x0fe0fbfb41c96472,
            0xdba01aae0ab6c835, 0x98bb26ec17da986a, 0x282d29e29bccb90a, 0xf9b089671436a422,
            0x4a6d15638bc6e4fe, 0x25fab711cf5216ea, 0x8c167aec0b61cbde, 0x1e274035161e1393,
            0x52dc34e2ac6a9178
        ], blocks: 7)
    private static var unsignedMemorySeeds: [MemorySeed] {
        [planar8, rgbToPlanes8, bgrToPlanes8, bgrToPlanes16, planesToBGR8, planesToBGR16]
    }

    private struct Fixture: Equatable {
        let rows: [InstructionRow]
        let function: MacIRFunction
        let document: PseudocodeDocument
        let legacy: PseudocodeDocument
    }

    private func fixture(_ hex: String? = nil, at start: UInt64 = 0x21704,
                         name: String = "_decoded_scalar_a") throws -> Fixture {
        let bytes = try (hex ?? Self.planarBytes).split(whereSeparator: \.isWhitespace).map { try XCTUnwrap(UInt8($0, radix: 16)) }
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: start)
        XCTAssertEqual(decoded.count * 4, bytes.count)
        var rows = decoded.map { InstructionRow(decoded: $0) }
        for index in rows.indices {
            XCTAssertNotNil(rows[index].structuredOperands)
            XCTAssertEqual(rows[index].structuredOperands, decoded[index].structuredOperands)
            rows[index].comment = "decoded_cfg_effect_\(index)_end"
        }
        if hex == nil {
            XCTAssertEqual(rows.count, 84)
            let unavailable = Set([15, 43, 61, 69, 83])
            for index in rows.indices {
                let envelope = try XCTUnwrap(rows[index].structuredOperands)
                if unavailable.contains(index) {
                    XCTAssertEqual(envelope, .unavailable(mnemonic: rows[index].mnemonic, operands: rows[index].operands))
                } else { XCTAssertEqual(envelope.coverage, .complete) }
            }
            if start == 0x3704 {
                XCTAssertEqual(rows.map { $0.operands.isEmpty ? $0.mnemonic : $0.mnemonic + " " + $0.operands },
                               Self.planarSourceText.split(separator: "\n").map(String.init))
            }
        }
        let summary = FunctionSummary(id: UUID(), name: name, startAddress: start,
                                      endAddress: start + UInt64(bytes.count), confidence: 1)
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [summary], instructions: rows,
                                         xrefs: [], hexBytes: Data())
        let input = snapshot.pseudocodeRenderInput(selectedAddress: start, in: .primary)
        let function = MacIRBuilder().buildFunction(name: input.functionName, instructions: input.instructions)
        let actual = PseudocodePrinter(options: .default).print(function: function)
        XCTAssertEqual(actual.text, DocumentExportService().pseudocodeText(for: input, options: .default))
        var options = DecompilerOptions.default
        options.structureControlFlow = false
        let legacy = PseudocodePrinter(options: options).print(function: function)
        return .init(rows: rows, function: function, document: actual, legacy: legacy)
    }

    /// The pre-fix failure is this production behavior assertion, never an
    /// unsupported legacy helper / unbound SSA name thrown by the text oracle.
    private func requireRepair(_ fixture: Fixture, file: StaticString = #filePath,
                               line: UInt = #line) -> Bool {
        func count(_ needle: String, _ text: String) -> Int {
            text.components(separatedBy: needle).count - 1
        }
        let actual = fixture.document.text, legacy = fixture.legacy.text
        let raw = count("goto 0x", actual), oldRaw = count("goto 0x", legacy)
        XCTAssertGreaterThan(oldRaw, 0, legacy, file: file, line: line)
        XCTAssertLessThan(raw, oldRaw, "default export must remove genuine raw transfers\n\(actual)", file: file, line: line)
        XCTAssertLessThan(count("goto ", actual), count("goto ", legacy),
                          "renaming raw targets to labels earns no credit\n\(actual)", file: file, line: line)
        let structured = actual.contains("while (") || actual.contains("do {")
        XCTAssertTrue(structured, "default export must recover a loop\n\(actual)", file: file, line: line)
        guard raw < oldRaw, count("goto ", actual) < count("goto ", legacy), structured else { return false }
        XCTAssertEqual(fixture.rows.count, 84, file: file, line: line)
        XCTAssertEqual(fixture.function.instructions.count, 84, file: file, line: line)
        XCTAssertEqual(CFGBuilder.buildCFG(instructions: fixture.function.instructions).blocks.count, 24,
                       file: file, line: line)
        XCTAssertTrue(fixture.function.phis.isEmpty, file: file, line: line)
        XCTAssertEqual(fixture.document.parameters, fixture.legacy.parameters, file: file, line: line)
        XCTAssertEqual(fixture.document.parameters.map(\.register), ["x0", "x1", "x2", "w3", "w4"], file: file, line: line)
        XCTAssertEqual(fixture.document.parameters.map(\.type), ["int64_t", "int64_t", "int64_t", "int32_t", "int32_t"], file: file, line: line)
        XCTAssertEqual(fixture.document.parameters.map(\.name), ["arg0", "arg1", "arg2", "arg3", "arg4"], file: file, line: line)
        XCTAssertEqual(fixture.document.returnType, "int64_t", file: file, line: line)
        XCTAssertEqual(fixture.document.lines.filter { $0.kind == .signature }.map(\.text),
                       fixture.legacy.lines.filter { $0.kind == .signature }.map(\.text), file: file, line: line)
        XCTAssertEqual(fixture.document.stackFrameSize, 0, file: file, line: line)
        XCTAssertTrue(fixture.document.localVariables.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.document.callTargets.isEmpty, file: file, line: line)
        do { _ = try historicalNative(fixture) }
        catch {
            XCTFail("historical native complete row/slot/writer/copy/edge ownership: \(error)", file: file, line: line)
            return false
        }
        let returned = fixture.rows.last!.address
        XCTAssertEqual(fixture.document.lines(sourcedAt: returned).map(\.text),
                       fixture.legacy.lines(sourcedAt: returned).map(\.text),
                       "the original unresolved RET contract is immutable", file: file, line: line)
        XCTAssertTrue(actual.contains("return unresolved_return_contract;"), file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverSharedTails, file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverLoopExits, file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverGuardRegions, file: file, line: line)
        return true
    }

    private func execute(_ fixture: Fixture, _ scenario: PlanarScenario) throws -> ScalarTextMachine.Result {
        let physical: [Int: UInt64] = [0: scenario.context, 1: scenario.sourceRows, 2: scenario.planes,
                                      3: UInt64(scenario.outputIndex), 4: UInt64(scenario.rowCount)]
        let prepared = try historicalNative(fixture), expected = try scenario.reference()
        let trace = try historicalTrace(prepared.inventory, physical: physical, memory: scenario.memory)
        try requireHistoricalLiteralAgreement(trace, expected: expected, label: scenario.label)
        let actual = try runHistoricalNative(prepared, physical: physical, memory: scenario.memory,
            model: .strictOrdinaryC, label: scenario.label)
        try compareHistoricalTrace(prepared, actual: actual, reference: trace, label: scenario.label)
        try assertHistoricalStrictSpanBoundary(prepared, physical: physical, memory: scenario.memory, reference: trace, label: scenario.label)
        XCTAssertEqual(actual.events, expected.events, "\(scenario.label)\n\(fixture.document.text)")
        XCTAssertEqual(actual.memory, expected.memory, scenario.label)
        XCTAssertTrue(actual.returned, scenario.label)
        XCTAssertEqual(actual.returnMarker, "unresolved_return_contract", scenario.label)
        XCTAssertNil(actual.returnValue, scenario.label)
        return historicalObservations(actual, prepared: prepared)
    }

    func testDefaultDecodedScalarCFGMatchesPlanarMatrix() throws {
        // Both the fixture and export service use the scoped legacy mode.
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            // These exact named/relocated inputs are excluded by the admission limit.
            // This is fallback identity, not native matrix or numerical repair credit.
            for (base, name): (UInt64, String) in [(0x3704, "_decoded_scalar_a"), (0x913804, "_decoded_scalar_b")] {
                let decoded = try fixture(at: base, name: name)
                ExcludedNullFallback39A.requireHistorical(function: decoded.function,
                    document: decoded.document, legacy: decoded.legacy)
            }
        }
    }

    func testDefaultDecodedScalarCFGPreservesAliasesWrapAndWriterTiming() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let decoded = try fixture(at: 0x3a704, name: "_decoded_scalar_alias")
            // The original alias/wrap/writer-time matrix is preserved as excluded evidence.
            ExcludedNullFallback39A.requireHistorical(function: decoded.function,
                document: decoded.document, legacy: decoded.legacy)
        }
    }

    func testDefaultDecodedScalarCFGRejectsContradictoryAuthority() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let decoded = try fixture(at: 0x4b704, name: "_decoded_scalar_rejection_control")
            // Original null mutation assertions are BLOCKED evidence, never passing credit.
            ExcludedNullFallback39A.requireHistorical(function: decoded.function,
                document: decoded.document, legacy: decoded.legacy)
            try assertOracleStrictness()

            func decline(_ function: MacIRFunction, _ reason: String) {
                var options = DecompilerOptions.default
                options.structureControlFlow = false
                let legacy = PseudocodePrinter(options: options).print(function: function)
                let actual = PseudocodePrinter(options: .default).print(function: function)
                XCTAssertEqual(actual.text, legacy.text, "unproved authority must preserve fallback: \(reason)")
            }
            func envelope(_ source: InstructionOperands, coverage: InstructionOperands.Coverage? = nil,
                          operands: [InstructionOperands.Operand]? = nil,
                          semantics: InstructionOperands.Semantics? = nil,
                          legacyText: InstructionOperands.LegacyText? = nil) -> InstructionOperands {
                .init(architecture: source.architecture, schemaVersion: source.schemaVersion,
                      coverage: coverage ?? source.coverage, opcodeClass: source.opcodeClass,
                      operands: operands ?? source.operands, presentation: source.presentation,
                      semantics: semantics ?? source.semantics, legacyText: legacyText ?? source.legacyText)
            }
            let load = try XCTUnwrap(decoded.rows[0].structuredOperands)
            let pair = try XCTUnwrap(decoded.rows[9].structuredOperands)
            let returned = try XCTUnwrap(decoded.rows[83].structuredOperands)
            var badLoad = load.operands
            badLoad[0] = .register(.init(index: 8, width: 32))
            for (index, changed, reason): (Int, InstructionOperands, String) in [
                (0, envelope(load, operands: badLoad), "complete operand contradiction"),
                (0, envelope(load, coverage: .partial), "partial operand authority"),
                (0, envelope(load, semantics: .init(memoryAccessWidth: 64, memoryAccess: .read)), "load width contradiction"),
                (9, envelope(pair, semantics: .init(memoryAccessWidth: 64, memoryAccess: .write)), "pair direction contradiction"),
                (83, envelope(returned, legacyText: .init(mnemonic: "ret", operands: "x1")), "RET legacy target contradiction"),
                (83, envelope(returned, semantics: .init(memoryAccessWidth: 64, memoryAccess: .write)), "hidden RET side effect")
            ] {
                var rows = decoded.rows
                rows[index].structuredOperands = changed
                decline(MacIRBuilder().buildFunction(name: "_decoded_metadata_negative", instructions: rows), reason)
            }
            for index in [0, 9, 17] {
                var function = decoded.function
                function.instructions[index].memoryAccess = .init(byteWidth: 2, extensionKind: .sign)
                decline(function, "typed memory width/extension contradicts decoded source at \(index)")
            }
            var roleMismatch = decoded.function
            if case let .assign(destination, _) = roleMismatch.instructions[61].operation {
                roleMismatch.instructions[61].operation = .assign(destination: destination, source: .immediate(5))
                decline(roleMismatch, "SXTW source role must not be inferred from a coincidentally equal value")
            } else { XCTFail("decoded SXTW operation changed") }
            var targetMismatch = decoded.function
            if case let .conditionalBranch(condition, left, right, _) = targetMismatch.instructions[3].operation {
                targetMismatch.instructions[3].operation = .conditionalBranch(condition: condition, left: left, right: right,
                    target: .immediate(Int64(decoded.rows[14].address)))
                decline(targetMismatch, "typed branch target contradicts original decoded target")
            } else { XCTFail("decoded conditional operation changed") }
            var explicitTarget = decoded.function
            explicitTarget.instructions[83].returnTarget = .register(name: "x1", version: 0)
            decline(explicitTarget, "unproved typed RET target")
            var inventedReturn = decoded.function
            inventedReturn.instructions[83].operation = .returnValue(.immediate(0))
            decline(inventedReturn, "invented returned value replaces unresolved contract")
            var duplicateName = decoded.function
            duplicateName.parameters[1].name = duplicateName.parameters[0].name
            decline(duplicateName, "two entry physical roles cannot capture one printed name")
            var reservedName = decoded.function
            reservedName.parameters[0].name = "while"
            decline(reservedName, "reserved parameter identifier")

            let indirect = try fixture(Self.indirectBytes, at: 0x17cb0, name: "_decoded_indirect_control")
            XCTAssertEqual(indirect.rows.count, 99)
            XCTAssertEqual(indirect.rows[85].mnemonic, "br")
            XCTAssertEqual(indirect.rows[85].address, 0x17e04)
            XCTAssertEqual(indirect.rows[85].operands, "x1")
            decline(indirect.function, "actual complete indirect-control corpus function")
        }
    }

    /// Deliberately corrupt already-parsed emitted programs, never product
    /// fixtures. Sources choose mutation sites only; all values/names still
    /// come verbatim from the emitted expressions. Runtime errors count as
    /// semantic detection only after the unmodified program has run correctly.
    private func assertSemanticSensitivity(_ fixture: Fixture) throws {
        let scenario = PlanarScenario(width: 3, rows: 2, components: 5, outputIndex: .max)
        let expected = try scenario.reference()
        let program = try ScalarTextMachine.Program(document: fixture.document)
        let physical: [Int: UInt64] = [0: scenario.context, 1: scenario.sourceRows, 2: scenario.planes,
                                      3: UInt64(scenario.outputIndex), 4: UInt64(scenario.rowCount)]
        var inputs: [String: ScalarTextMachine.Value] = [:]
        for parameter in fixture.document.parameters {
            let register = try XCTUnwrap(Int(parameter.register.dropFirst()))
            inputs[parameter.name] = .init(bits: try XCTUnwrap(physical[register]),
                                           type: try XCTUnwrap(ScalarTextMachine.CType(parameter.type)))
        }
        let original = try ScalarTextMachine(program: program, inputs: inputs, memory: scenario.memory).run()
        XCTAssertEqual(original.events, expected.events)
        func sites(_ row: Int) -> [Int] {
            program.code.indices.filter { program.code[$0].source == fixture.rows[row].address }
        }
        func assignment(_ row: Int) throws -> Int {
            try XCTUnwrap(sites(row).last { if case .assign = program.code[$0].operation { return true }; return false })
        }
        func detect(_ label: String, _ changed: ScalarTextMachine.Program) {
            do {
                let result = try ScalarTextMachine(program: changed, inputs: inputs, memory: scenario.memory).run()
                XCTAssertTrue(result.events != expected.events || result.memory != expected.memory || !result.returned,
                              "oracle failed to detect semantic mutation: \(label)")
            } catch ScalarTextMachine.Failure.invalid { /* Unbound/wrong-address reads and fuel exhaustion are real failures. */ }
              catch ScalarTextMachine.Failure.undefined { /* The mutation introduced undefined arithmetic. */ }
              catch { XCTFail("unexpected oracle failure for \(label): \(error)") }
        }
        for (row, label) in [(72, "stale inner source pointer"), (78, "stale outer row pointer"), (79, "stale outer output index")] {
            var changed = program
            let site = try assignment(row)
            guard case let .assign(left, _, type) = changed.code[site].operation, left.count == 1 else {
                return XCTFail("mutation expects scalar state write at row \(row)")
            }
            changed.code[site] = .init(operation: .assign(left, left, type), source: changed.code[site].source)
            detect(label, changed)
        }
        func widen(_ value: ScalarTextMachine.Expression) -> ScalarTextMachine.Expression {
            switch value {
            case let .cast(type, child): return .cast(type == .u32 ? .u64 : type, widen(child))
            case let .binary(op, lhs, rhs): return .binary(op, widen(lhs), widen(rhs))
            case let .unary(op, child): return .unary(op, widen(child))
            case let .memory(type, address): return .memory(type, widen(address))
            default: return value
            }
        }
        var widened = program
        for site in sites(79) {
            if case let .assign(left, right, type) = widened.code[site].operation {
                for destination in left {
                    if case let .variable(name) = destination, widened.declarations[name] == .u32 {
                        widened.declarations[name] = .u64
                    }
                }
                widened.code[site] = .init(operation: .assign(left, right.map(widen), type == .u32 ? .u64 : type), source: widened.code[site].source)
            }
        }
        // Later UXTW reads still project low32, so this wrong full64 W3
        // state is deliberately invisible to memory/termination comparison.
        // Observe the literal committed source effect instead of weakening
        // the mutation or changing other reads to manufacture a memory error.
        let indexSource = fixture.rows[79].address
        let expectedIndexWrites: [UInt64] = [0, 1]
        XCTAssertEqual(original.finalAssignments[indexSource]?.compactMap { $0.last?.bits }, expectedIndexWrites)
        let widenedResult = try ScalarTextMachine(program: widened, inputs: inputs, memory: scenario.memory).run()
        let widenedWrites = widenedResult.finalAssignments[indexSource]?.compactMap { $0.last?.bits }
        XCTAssertEqual(widenedResult.events, expected.events, "the unchanged UXTW reads mask the corrupt high bits")
        XCTAssertEqual(widenedResult.memory, expected.memory)
        XCTAssertTrue(widenedResult.returned)
        XCTAssertEqual(widenedWrites, [0x1_0000_0000, 0x1_0000_0001], "the unweakened mutation corrupts full64 W-write state")
        XCTAssertNotEqual(widenedWrites, expectedIndexWrites, "the oracle must detect the missing W3 zero-extension at commit time")

        func readsMemory(_ value: ScalarTextMachine.Expression) -> Bool {
            switch value {
            case .memory: return true
            case let .cast(_, child), let .unary(_, child): return readsMemory(child)
            case let .binary(_, left, right): return readsMemory(left) || readsMemory(right)
            default: return false
            }
        }
        var frozen = program
        let load = try XCTUnwrap(sites(70).first {
            if case let .assign(_, values, _) = program.code[$0].operation { return values.contains(where: readsMemory) }
            return false
        })
        if case let .assign(left, right, type) = frozen.code[load].operation, right.count == 1 {
            let first = try XCTUnwrap(original.finalAssignments[fixture.rows[70].address]?.first?.first)
            frozen.code[load] = .init(operation: .assign(left, [.literal(first)], type), source: frozen.code[load].source)
            detect("hoisted/frozen per-iteration byte load", frozen)
        } else { XCTFail("expected one emitted scalar byte load") }

        var delayed = program
        let compareSites = sites(80), subtractSites = sites(81)
        guard let first = compareSites.first, let last = subtractSites.last,
              Array(first...last) == compareSites + subtractSites,
              (compareSites + subtractSites).allSatisfy({ if case .assign = program.code[$0].operation { return true }; return false }) else {
            return XCTFail("CMP snapshots and following SUB must be explicit adjacent scalar effects")
        }
        let reordered = subtractSites.map { program.code[$0] } + compareSites.map { program.code[$0] }
        delayed.code.replaceSubrange(first...last, with: reordered)
        detect("CMP reads post-SUB W4 instead of writer-time W4", delayed)

        var wrongArm = program
        let extensionSite = try assignment(61), otherArmSite = try assignment(43)
        guard case let .assign(left, _, type) = wrongArm.code[extensionSite].operation,
              case let .assign(otherLeft, _, _) = wrongArm.code[otherArmSite].operation,
              let otherValue = otherLeft.first else { return XCTFail("missing wrong-arm mutation inputs") }
        wrongArm.code[extensionSite] = .init(operation: .assign(left, [otherValue], type), source: wrongArm.code[extensionSite].source)
        detect("join reads storage only initialized by another dispatch arm", wrongArm)
    }

    private func assertOracleStrictness() throws {
        func run(_ lines: [String]) throws -> ScalarTextMachine.Result {
            let document = PseudocodeDocument(functionName: "_oracle_only", lines: lines.enumerated().map {
                PseudocodeLine(lineNumber: $0.offset + 1, text: $0.element)
            })
            return try ScalarTextMachine(program: .init(document: document), inputs: [:], memory: [:]).run()
        }
        for text in ["return not_bound;", "unknown_helper();", "x = pair_guess(0);", "discarded(); return;",
                     "x = *(uint8_t *)(0x1234);", "uint32_t x = 0; uint32_t x = 1;",
                     "if (1) { uint64_t x = 7; } return x;", "x = 1; uint8_t x; return x;"] {
            XCTAssertThrowsError(try run([text]), "no skipped syntax, helpers, unbound names, undefined memory, or duplicate declarations: \(text)")
        }
        XCTAssertThrowsError(try run(["return 0x7fffffffffffffff + 1;"]))
        XCTAssertEqual(try run(["return (uint64_t)((int32_t)(0xffffffff));"]).returnValue?.bits, UInt64.max)
        XCTAssertEqual(try run(["return (uint64_t)((uint32_t)(0xffffffff));"]).returnValue?.bits, 0xffff_ffff)
        XCTAssertEqual(try run(["return (uint32_t)(0xffffffff) + (uint32_t)(1);"]).returnValue?.bits, 0)
        XCTAssertEqual(try run(["return (int32_t)(0xffffffff) < 1;"]).returnValue?.bits, 1)
        XCTAssertEqual(try run(["return (uint32_t)(0xffffffff) < 1;"]).returnValue?.bits, 0)
        let control = try run(["uint64_t n = 0;", "while (n < 4) {", "n = n + 1;", "if (n == 2) {",
                               "continue;", "} else {", "if (n == 3) {", "break;", "}", "}", "}",
                               "do {", "n = n - 1;", "} while (n > 1);", "return n;"])
        XCTAssertEqual(control.returnValue?.bits, 1)
    }
}

// The unsigned-memory selectors deliberately do not alter the earlier three
// selectors or the text machine's accepted language.
extension DecodedScalarCFGTests {
    private func memoryFixture(_ seed: MemorySeed) throws -> Fixture {
        let result = try fixture(seed.bytes, at: seed.base, name: seed.name)
        let expectedText = seed.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(result.rows.count, expectedText.count)
        XCTAssertEqual(result.rows.map { $0.operands.isEmpty ? $0.mnemonic : $0.mnemonic + " " + $0.operands }, expectedText)
        XCTAssertEqual(result.rows.map(\.address), expectedText.indices.map { seed.base + UInt64($0 * 4) })
        XCTAssertEqual(result.function.instructions.count, expectedText.count)
        XCTAssertEqual(CFGBuilder.buildCFG(instructions: result.function.instructions).blocks.count, seed.blocks)
        for (index, row) in result.rows.enumerated() {
            let metadata = try XCTUnwrap(row.structuredOperands)
            // Pin the entire independently retained envelope. Only diagnostic
            // vs production module qualification is normalized; no fields,
            // nil markers, operand roles or enum cases are discarded.
            let capturedShape = String(reflecting: row.structuredOperands)
                .replacingOccurrences(of: "MacScopeAnalysisCore.", with: "")
                .replacingOccurrences(of: "MacScope.", with: "")
                .replacingOccurrences(of: "RenderAll.", with: "")
            let witness = capturedShape.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
            XCTAssertEqual(witness, seed.operandWitnesses[index], "complete independent captured operand envelope at \(row.address): \(capturedShape)")
            if ["ldrb", "ldurb", "strb", "sturb", "ldrh", "ldurh", "strh", "sturh"].contains(row.mnemonic) {
                let expectedBits = row.mnemonic.hasSuffix("h") ? 16 : 8
                XCTAssertEqual(try XCTUnwrap(metadata.semantics).memoryAccessWidth, expectedBits)
                XCTAssertEqual(metadata.semantics?.memoryAccess, row.mnemonic.hasPrefix("ld") ? .read : .write)
            }
            XCTAssertEqual(metadata.architecture, .arm64)
            XCTAssertEqual(metadata.schemaVersion, 1)
            if seed.unavailable.contains(index) {
                XCTAssertEqual(metadata, .unavailable(mnemonic: row.mnemonic, operands: row.operands))
            } else {
                XCTAssertEqual(metadata.coverage, .complete, "actual captured coverage at \(row.address)")
            }
            // All complete operand metadata survives the production Workspace
            // path and a Codable roundtrip, not just the printed mnemonic.
            XCTAssertEqual(try JSONDecoder().decode(InstructionOperands.self, from: JSONEncoder().encode(metadata)), metadata)
            if let bits = metadata.semantics?.memoryAccessWidth {
                let access = try XCTUnwrap(result.function.instructions[index].memoryAccess)
                XCTAssertEqual(access.byteWidth * 8, bits)
                if ["ldrb", "ldurb", "ldrh", "ldurh"].contains(row.mnemonic) {
                    XCTAssertEqual(access.extensionKind, .zero)
                    XCTAssertEqual(metadata.semantics?.memoryAccess, .read)
                }
                if ["strb", "sturb", "strh", "sturh"].contains(row.mnemonic) {
                    XCTAssertEqual(access.extensionKind, .none)
                    XCTAssertEqual(metadata.semantics?.memoryAccess, .write)
                }
            }
        }
        return result
    }

    /// This named RED precondition must fail before trying to parse unchanged
    /// fallback text. Labels, fewer comments, or cosmetic braces earn no pass.
    private func requireUnsignedMemoryRepair(_ fixture: Fixture, _ seed: MemorySeed,
                                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        func count(_ token: String, _ text: String) -> Int { text.components(separatedBy: token).count - 1 }
        let actual = fixture.document.text, old = fixture.legacy.text
        let flatHasLabels = count("goto loc_", old) + count("goto L_", old) > 0
        let totalImproved = count("goto ", actual) < count("goto ", old)
        let structured = actual.contains("while (") || actual.contains("do {")
        XCTAssertTrue(flatHasLabels, old, file: file, line: line)
        XCTAssertNil(fixture.document.structureFallback, "valid loop plan owns the deterministic render", file: file, line: line)
        XCTAssertTrue(totalImproved, "UNSIGNED_MEMORY_REPAIR_REQUIRED: labels cannot stand in for control-flow repair", file: file, line: line)
        XCTAssertTrue(structured, "UNSIGNED_MEMORY_REPAIR_REQUIRED: recover a genuine loop", file: file, line: line)
        guard flatHasLabels && fixture.document.structureFallback == nil && totalImproved && structured else { return false }
        XCTAssertEqual(fixture.document.parameters, fixture.legacy.parameters, file: file, line: line)
        let planar = seed.kind!.planarToInterleaved
        XCTAssertEqual(fixture.document.parameters.map(\.register), planar ? ["x0", "x1", "w2", "x3", "w4"] : ["x0", "x1", "x2", "w3", "w4"], file: file, line: line)
        XCTAssertEqual(fixture.document.parameters.map(\.type), planar ? ["int64_t", "int64_t", "int32_t", "int64_t", "int32_t"] : ["int64_t", "int64_t", "int64_t", "int32_t", "int32_t"], file: file, line: line)
        XCTAssertEqual(fixture.document.parameters.map(\.name), ["arg0", "arg1", "arg2", "arg3", "arg4"], file: file, line: line)
        XCTAssertEqual(fixture.document.returnType, fixture.legacy.returnType, file: file, line: line)
        XCTAssertEqual(fixture.document.returnType, "int64_t", file: file, line: line)
        XCTAssertEqual(fixture.document.lines.filter { $0.kind == .signature }.map(\.text), fixture.legacy.lines.filter { $0.kind == .signature }.map(\.text), file: file, line: line)
        XCTAssertEqual(fixture.document.stackFrameSize, 0, file: file, line: line)
        XCTAssertTrue(fixture.document.localVariables.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.function.phis.isEmpty, file: file, line: line)
        XCTAssertTrue(fixture.document.callTargets.isEmpty, file: file, line: line)
        XCTAssertFalse(fixture.rows.contains { ["bl", "blr"].contains($0.mnemonic) }, file: file, line: line)
        for instruction in fixture.function.instructions {
            if case .call = instruction.operation { XCTFail("real fixture unexpectedly contains a call", file: file, line: line) }
        }
        do { _ = try historicalNative(fixture) }
        catch {
            XCTFail("historical native complete row/slot/writer/copy/edge ownership: \(error)", file: file, line: line)
            return false
        }
        let returned = fixture.rows.last!.address
        XCTAssertEqual(fixture.document.lines(sourcedAt: returned).map(\.text), fixture.legacy.lines(sourcedAt: returned).map(\.text), file: file, line: line)
        XCTAssertTrue(actual.contains("return unresolved_return_contract;"), file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverSharedTails, file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverLoopExits, file: file, line: line)
        XCTAssertFalse(DecompilerOptions.default.recoverGuardRegions, file: file, line: line)
        return true
    }

    private func memoryInputs(_ fixture: Fixture, _ scenario: UnsignedMemoryScenario) throws -> [String: ScalarTextMachine.Value] {
        var inputs: [String: ScalarTextMachine.Value] = [:]
        for parameter in fixture.document.parameters {
            let index = try XCTUnwrap(Int(parameter.register.dropFirst()))
            inputs[parameter.name] = .init(bits: try XCTUnwrap(scenario.physical[index]), type: try XCTUnwrap(ScalarTextMachine.CType(parameter.type)))
        }
        return inputs
    }

    @discardableResult
    private func executeMemory(_ fixture: Fixture, _ scenario: UnsignedMemoryScenario) throws -> ScalarTextMachine.Result {
        let prepared = try historicalNative(fixture)
        // Model selection is fixed by the original scenario identity before
        // either reference or candidate execution, never by a failed run.
        let model = try historicalMemoryModel(scenario, prepared: prepared)
        let expected = try scenario.reference()
        let trace = try historicalTrace(prepared.inventory, physical: scenario.physical, memory: scenario.memory)
        try requireHistoricalLiteralAgreement(trace, expected: expected.result, label: scenario.label)
        if case .retainedHalfwordByteMap64 = model {
            guard trace.events.contains(where: { $0.bytes > 1 && $0.address > UInt64.max - UInt64($0.bytes - 1) }) else {
                throw Ordinary.Failure.invalidContract("retained abstract wrap scenario lost its independent cross-end observation")
            }
        }
        let native = try runHistoricalNative(prepared, physical: scenario.physical, memory: scenario.memory,
            model: model, label: scenario.label)
        try compareHistoricalTrace(prepared, actual: native, reference: trace, label: model.label(scenario.label))
        try assertHistoricalStrictSpanBoundary(prepared, physical: scenario.physical, memory: scenario.memory, reference: trace, label: scenario.label)
        let actual = historicalObservations(native, prepared: prepared)
        XCTAssertEqual(actual.nativeLoadedValues.map(\.bits), expected.states["loaded"] ?? [], "complete unsigned load-slot bits: \(scenario.label)")
        XCTAssertEqual(actual.events, expected.result.events, "ordered accesses: \(scenario.label)\n\(fixture.document.text)")
        XCTAssertEqual(actual.memory, expected.result.memory, "final memory: \(scenario.label)")
        XCTAssertTrue(actual.returned, scenario.label)
        XCTAssertEqual(actual.returnMarker, "unresolved_return_contract", scenario.label)
        XCTAssertNil(actual.returnValue, scenario.label)
        // Source tags locate observable commits only. Expected values are
        // calculated by the literal reference and never by decoding emission.
        var stateRows: [String: Int]
        if scenario.kind == .planar8 {
            if scenario.components == 4 {
                stateRows = ["plane0": 17, "plane1": 19, "plane2": 21, "plane3": 23, "inter": 25, "pixels": 26, "index": 28, "rowsPointer": 29, "remaining": 31]
            } else if scenario.components == 3 {
                stateRows = ["plane0": 44, "plane1": 46, "plane2": 48, "inter": 50, "pixels": 51, "index": 53, "rowsPointer": 54, "remaining": 56]
            } else {
                stateRows = ["source": 70, "inter": 72, "pixels": 73, "component": 75, "rowsPointer": 78, "index": 79, "remaining": 81]
            }
        } else if scenario.kind == .rgbToPlanes8 {
            stateRows = ["plane0": 12, "plane1": 14, "plane2": 16, "inter": 17, "pixels": 18, "rowsPointer": 20, "index": 21, "remaining": 23]
        } else {
            let first = scenario.kind.planarToInterleaved ? 12 : 13
            stateRows = ["plane0": first, "plane1": first + 2, "plane2": first + 4, "inter": 18, "pixels": 19,
                         "index": scenario.kind.planarToInterleaved ? 21 : 22,
                         "rowsPointer": scenario.kind.planarToInterleaved ? 22 : 21, "remaining": 24]
        }
        for (state, row) in stateRows {
            let slots = prepared.definitions.values.filter {
                $0.slot.row == row && ($0.kind == .scalarDefinition || $0.kind == .writeback)
            }
            guard slots.count == 1, let slot = slots.first else {
                throw Ordinary.Failure.invalidContract("historical live state \(state) has no unique original destination slot")
            }
            let values = actual.sourceSlotWrites[fixture.rows[row].address]?[slot.slot.ordinal]?.map(\.bits) ?? []
            XCTAssertEqual(values, expected.states[state] ?? [], "backedge-live committed \(state): \(scenario.label)")
        }
        return actual
    }

    /// Select by printed self-dependency, never architectural names, MacIR,
    /// proof metadata, expected values, or a hard-coded assignment position.
    /// A SUBS result reads and redefines its own cell; its later flag snapshot
    /// reads that cell but defines a different destination.
    private func committedSelfUpdatingScalar(_ program: ScalarTextMachine.Program,
                                             _ result: ScalarTextMachine.Result,
                                             at source: UInt64) throws -> [ScalarTextMachine.Value] {
        let assignments = program.code.filter { instruction in
            guard instruction.source == source else { return false }
            if case .assign = instruction.operation { return true }; return false
        }
        let candidates = assignments.indices.filter { ordinal in
            guard case let .assign(left, right, _) = assignments[ordinal].operation,
                  left.count == 1, right.count == 1,
                  case let .variable(name) = left[0] else { return false }
            return right[0].variables.contains(name)
        }
        let selected = try XCTUnwrap(candidates.count == 1 ? candidates.first : nil,
                                    "pixel source must contain exactly one printed self-updating scalar cell")
        var ordinal = 0, values: [ScalarTextMachine.Value] = []
        for commit in result.commits where commit.source == source {
            if ordinal % assignments.count == selected {
                values.append(try XCTUnwrap(commit.values.first))
            }
            ordinal += 1
        }
        return values
    }

    /// Follow only parsed RHS dependencies within each actual load row to
    /// find its last memory-dependent destination. The oracle reads the real
    /// committed value and type, not an architectural register or MacIR value.
    private func committedMemoryLoads(_ program: ScalarTextMachine.Program, _ result: ScalarTextMachine.Result,
                                      _ fixture: Fixture) throws -> [ScalarTextMachine.Value] {
        var observations: [UInt64: (count: Int, ordinal: Int, lane: Int)] = [:]
        for row in fixture.rows where ["ldrb", "ldurb", "ldrh", "ldurh"].contains(row.mnemonic) {
            let assignments = program.code.filter { instruction in
                guard instruction.source == row.address else { return false }
                if case .assign = instruction.operation { return true }; return false
            }
            var tainted = Set<String>(), selected: (Int, Int)?
            func depends(_ value: ScalarTextMachine.Expression) -> Bool {
                switch value {
                case .memory: return true
                case let .variable(name): return tainted.contains(name)
                case let .cast(_, value), let .unary(_, value): return depends(value)
                case let .binary(_, left, right): return depends(left) || depends(right)
                case .literal: return false
                }
            }
            for (ordinal, instruction) in assignments.enumerated() {
                guard case let .assign(left, right, _) = instruction.operation else { continue }
                let dependencies = right.map(depends)
                for lane in left.indices {
                    if case let .variable(name) = left[lane] {
                        if dependencies[lane] { tainted.insert(name); selected = (ordinal, lane) }
                        else { tainted.remove(name) }
                    }
                }
            }
            let selection = try XCTUnwrap(selected, "every actual unsigned data load must have an observable committed destination")
            observations[row.address] = (assignments.count, selection.0, selection.1)
        }
        var ordinals: [UInt64: Int] = [:], values: [ScalarTextMachine.Value] = []
        for commit in result.commits {
            guard let observation = observations[commit.source] else { continue }
            let ordinal = ordinals[commit.source, default: 0]
            if ordinal % observation.count == observation.ordinal { values.append(commit.values[observation.lane]) }
            ordinals[commit.source] = ordinal + 1
        }
        return values
    }

    private func assertMemorySemanticSensitivity(_ fixture: Fixture, _ seed: MemorySeed) throws {
        let kind = try XCTUnwrap(seed.kind)
        let scenario = UnsignedMemoryScenario(kind: kind, width: 3, rows: 2, components: kind == .planar8 ? 5 : 3, index: .max, alias: .laterRead)
        let original = try executeMemory(fixture, scenario)
        let expected = try scenario.reference()
        let program = try ScalarTextMachine.Program(document: fixture.document)
        let inputs = try memoryInputs(fixture, scenario)
        func sites(_ row: Int) -> [Int] { program.code.indices.filter { program.code[$0].source == fixture.rows[row].address } }
        func assignment(_ row: Int) throws -> Int {
            try XCTUnwrap(sites(row).last { if case .assign = program.code[$0].operation { return true }; return false })
        }
        func detect(_ label: String, _ changed: ScalarTextMachine.Program) {
            do {
                let result = try ScalarTextMachine(program: changed, inputs: inputs, memory: scenario.memory).run()
                let loaded = try committedMemoryLoads(changed, result, fixture).map(\.bits)
                XCTAssertTrue(result.events != expected.result.events || result.memory != expected.result.memory ||
                    result.finalAssignments != original.finalAssignments || loaded != expected.states["loaded"] || !result.returned,
                    "oracle failed to detect parsed semantic corruption: \(label)")
            } catch ScalarTextMachine.Failure.invalid { /* Unbound reads/undefined memory/fuel exhaustion detect an already-valid program's mutation. */ }
              catch ScalarTextMachine.Failure.undefined { /* A mutation introduced undefined arithmetic. */ }
              catch { XCTFail("unexpected oracle failure for \(label): \(error)") }
        }
        func map(_ expression: ScalarTextMachine.Expression,
                 memory: (ScalarTextMachine.CType, ScalarTextMachine.Expression) -> ScalarTextMachine.Expression) -> ScalarTextMachine.Expression {
            switch expression {
            case let .cast(type, value): return .cast(type, map(value, memory: memory))
            case let .unary(op, value): return .unary(op, map(value, memory: memory))
            case let .binary(op, left, right): return .binary(op, map(left, memory: memory), map(right, memory: memory))
            case let .memory(type, address): return memory(type, address)
            default: return expression
            }
        }
        let loadRow = kind == .planar8 ? 70 : 12
        // OPEN: original load-width/sign numerical sensitivity is preserved outside executable scope.
        if kind.planarToInterleaved {
            var earlyWriteback = program
            var touched = false
            for site in sites(loadRow) {
                if case let .assign(left, right, type) = earlyWriteback.code[site].operation {
                    let values = right.map { value in map(value) { memoryType, address in
                        touched = true
                        return .memory(memoryType, .binary("+", address, .literal(.init(bits: UInt64(kind.bytes), type: .u64))))
                    } }
                    earlyWriteback.code[site] = .init(operation: .assign(left, values, type), source: earlyWriteback.code[site].source)
                }
            }
            XCTAssertTrue(touched)
            detect("post-index load reads advanced rather than old base", earlyWriteback)
            var wrongAdvance = program
            let site = try assignment(loadRow)
            guard case let .assign(left, right, type) = wrongAdvance.code[site].operation, right.count == 1 else { return XCTFail("expected final scalar pointer commit") }
            wrongAdvance.code[site] = .init(operation: .assign(left, [.binary("+", right[0], .literal(.init(bits: 1, type: .u64)))], type), source: wrongAdvance.code[site].source)
            detect("wrong post-index pointer increment", wrongAdvance)
        }
        for row in [kind == .planar8 ? 72 : 18, kind == .planar8 ? 78 : (kind.planarToInterleaved ? 22 : 21)] {
            var stale = program
            let site = try assignment(row)
            guard case let .assign(left, _, type) = stale.code[site].operation else { return XCTFail("missing backedge pointer commit") }
            stale.code[site] = .init(operation: .assign(left, left, type), source: stale.code[site].source)
            detect("missing live loop pointer state", stale)
        }
        // OPEN: original full64 W-write numerical sensitivity is preserved outside executable scope.
        let compareRow = kind == .planar8 ? 80 : 23, subtractRow = kind == .planar8 ? 81 : 24
        let compare = sites(compareRow), subtract = sites(subtractRow)
        guard let first = compare.first, let last = subtract.last,
              Array(first...last) == compare + subtract,
              (compare + subtract).allSatisfy({ if case .assign = program.code[$0].operation { return true }; return false }) else {
            return XCTFail("CMP and SUB must remain explicit neighboring scalar effects")
        }
        var lateCompare = program
        lateCompare.code.replaceSubrange(first...last, with: subtract.map { program.code[$0] } + compare.map { program.code[$0] })
        detect("late CMP snapshots post-SUB count and loses second row", lateCompare)
        if kind == .planesToBGR16 {
            let store = sites(13), nextLoad = sites(14)
            guard let first = store.first, let last = nextLoad.last,
                  Array(first...last) == store + nextLoad,
                  (store + nextLoad).allSatisfy({ if case .assign = program.code[$0].operation { return true }; return false }) else {
                return XCTFail("alias sensitivity needs adjacent store and subsequent load effects")
            }
            var hoistedRead = program
            hoistedRead.code.replaceSubrange(first...last, with: nextLoad.map { program.code[$0] } + store.map { program.code[$0] })
            detect("source-order corruption: later read precedes store and overwrites its shared loaded cell", hoistedRead)
        }
    }

    func testDefaultDecodedScalarMemoryCFGMatchesSixCompleteCorpusSites() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            for seed in Self.unsignedMemorySeeds {
                let decoded = try memoryFixture(seed)
                if seed.kind == .planar8 {
                    // Null-only native semantics are excluded; every retained seed continues.
                    // Original null mutation assertions remain BLOCKED preserved evidence.
                    ExcludedNullFallback39A.requireHistorical(function: decoded.function,
                        document: decoded.document, legacy: decoded.legacy)
                    continue
                }
                guard requireUnsignedMemoryRepair(decoded, seed) else { return }
                let kind = try XCTUnwrap(seed.kind)
                let modes: [UInt32] = kind == .planar8 ? [0, 3, 4, 5, 0x8000_0000, .max] : [3]
                for components in modes {
                    for width: UInt32 in [0, 1, 3] {
                        for rows: UInt32 in [0, 1, 2, .max] {
                            let scenario = UnsignedMemoryScenario(kind: kind, width: width, rows: rows, components: components)
                            let result = try executeMemory(decoded, scenario)
                            if rows == 2 && width == 3 && components > 0 && components < 6 {
                                // Independent direct output formula, in addition
                                // to the access-ordered literal reference.
                                for row in 0..<2 {
                                    for pixel in 0..<3 {
                                        for component in 0..<Int(components) {
                                            let address = scenario.outputAddress(component, row, pixel)
                                            let value = scenario.sourceSample(component, row, pixel)
                                            for byte in 0..<kind.bytes {
                                                XCTAssertEqual(result.memory[address &+ UInt64(byte)], UInt8(truncatingIfNeeded: value >> (byte * 8)), scenario.label)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testDefaultDecodedScalarMemoryCFGPreservesAliasWrapAndLiveState() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            for seed in Self.unsignedMemorySeeds {
                let decoded = try memoryFixture(seed)
                if seed.kind == .planar8 {
                    // Null-only native semantics are excluded; every retained seed continues.
                    // Original null mutation assertions remain BLOCKED preserved evidence.
                    ExcludedNullFallback39A.requireHistorical(function: decoded.function,
                        document: decoded.document, legacy: decoded.legacy)
                    continue
                }
                guard requireUnsignedMemoryRepair(decoded, seed) else { return }
                let kind = try XCTUnwrap(seed.kind)
                for components: UInt32 in kind == .planar8 ? [3, 4, 5] : [3] {
                    for alias in [UnsignedMemoryScenario.Alias.laterRead, .nextPixel, .nextRowPointer, .dataWrap, .destinationWrap, .rowPointerWrap] {
                        let scenario = UnsignedMemoryScenario(kind: kind, width: 3, rows: 2, components: components, index: .max, alias: alias)
                        let result = try executeMemory(decoded, scenario)
                        XCTAssertTrue(result.events.contains { $0.address > UInt64(UInt32.max) }, scenario.label)
                        if alias == .nextRowPointer {
                            let changedPointer = scenario.interleaved(1) &+ 0x80
                            XCTAssertTrue(result.events.contains { $0.kind == .load && $0.address == scenario.interleavedRows &+ 8 && $0.bytes == 8 && $0.value == changedPointer }, "next row must reload the aliased pointer")
                        }
                    }
                }
            }
        }
    }

    func testDefaultDecodedScalarMemoryCFGRejectsContradictoryAndSignedAuthority() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            func decline(_ function: MacIRFunction, _ reason: String) {
                var options = DecompilerOptions.default
                options.structureControlFlow = false
                let legacy = PseudocodePrinter(options: options).print(function: function)
                let actual = PseudocodePrinter(options: .default).print(function: function)
                XCTAssertEqual(actual.text, legacy.text, "fail closed, not partial recovery: \(reason)")
            }
            func envelope(_ source: InstructionOperands, operands: [InstructionOperands.Operand]? = nil,
                          semantics: InstructionOperands.Semantics? = nil, coverage: InstructionOperands.Coverage? = nil) -> InstructionOperands {
                .init(architecture: source.architecture, schemaVersion: source.schemaVersion, coverage: coverage ?? source.coverage,
                      opcodeClass: source.opcodeClass, operands: operands ?? source.operands, presentation: source.presentation,
                      semantics: semantics ?? source.semantics, legacyText: source.legacyText)
            }
            // These are contradictions on captured streams, not fabricated new
            // positive fixtures. Retain byte/text evidence while varying authority.
            for seed in [Self.planar8, Self.planesToBGR8, Self.planesToBGR16, Self.bgrToPlanes8, Self.bgrToPlanes16] {
                let decoded = try memoryFixture(seed)
                let row = seed.kind == .planar8 ? 17 : (seed.kind!.planarToInterleaved ? 12 : 14)
                let load = try XCTUnwrap(decoded.rows[row].structuredOperands)
                let width = try XCTUnwrap(load.semantics?.memoryAccessWidth)
                var changes: [(InstructionOperands, String)] = [
                    (envelope(load, semantics: .init(memoryAccessWidth: width, memoryAccess: .write)), "load direction"),
                    (envelope(load, semantics: .init(memoryAccessWidth: width == 8 ? 16 : 8, memoryAccess: .read)), "load access width"),
                    (envelope(load, coverage: .partial), "partial load authority")
                ]
                var memoryOperands = load.operands
                let memoryIndex = try XCTUnwrap(memoryOperands.firstIndex { if case .memory = $0 { return true }; return false })
                guard case let .memory(memory) = memoryOperands[memoryIndex] else { return XCTFail("missing captured memory") }
                memoryOperands[memoryIndex] = .memory(.init(base: memory.base, index: memory.index, modifier: memory.modifier,
                    displacement: memory.displacement, indexing: memory.indexing, writeback: !memory.writeback, displacementFormat: memory.displacementFormat))
                changes.append((envelope(load, operands: memoryOperands), "decoded load writeback contradiction"))
                for (metadata, reason) in changes {
                    var rows = decoded.rows
                    rows[row].structuredOperands = metadata
                    decline(MacIRBuilder().buildFunction(name: seed.name, instructions: rows), reason)
                }
                for extensionKind: MacIRMemoryAccess.ExtensionKind in [.sign, .none] {
                    var function = decoded.function
                    function.instructions[row].memoryAccess = .init(byteWidth: width / 8, extensionKind: extensionKind)
                    decline(function, "unsigned corpus load falsely made signed/unextended")
                }
                var badWidth = decoded.function
                badWidth.instructions[row].memoryAccess = .init(byteWidth: width == 8 ? 2 : 1, extensionKind: .zero)
                decline(badWidth, "typed access width differs from recorded metadata")
                if case let .loadWriteback(destination, baseDestination, baseSource, delta, preIndex) = decoded.function.instructions[row].operation {
                    var wrongDelta = decoded.function
                    wrongDelta.instructions[row].operation = .loadWriteback(destination: destination, baseDestination: baseDestination, baseSource: baseSource, delta: delta + 1, preIndex: preIndex)
                    decline(wrongDelta, "typed load pointer advancement contradiction")
                    var wrongOrder = decoded.function
                    wrongOrder.instructions[row].operation = .loadWriteback(destination: destination, baseDestination: baseDestination, baseSource: baseSource, delta: delta, preIndex: !preIndex)
                    decline(wrongOrder, "typed load pre/post-index contradiction")
                }
                if let storeRow = decoded.rows.firstIndex(where: { ["strb", "sturb", "strh", "sturh"].contains($0.mnemonic) && !$0.operands.contains("],") }) {
                    let store = try XCTUnwrap(decoded.rows[storeRow].structuredOperands)
                    var rows = decoded.rows
                    rows[storeRow].structuredOperands = envelope(store, semantics: .init(memoryAccessWidth: store.semantics?.memoryAccessWidth, memoryAccess: .read))
                    decline(MacIRBuilder().buildFunction(name: seed.name, instructions: rows), "no-writeback store direction contradiction")
                    var operands = store.operands
                    let memoryIndex = try XCTUnwrap(operands.firstIndex { if case .memory = $0 { return true }; return false })
                    guard case let .memory(memory) = operands[memoryIndex] else { return XCTFail("missing store memory authority") }
                    operands[memoryIndex] = .memory(.init(base: memory.base, index: memory.index, modifier: memory.modifier,
                        displacement: memory.displacement, indexing: memory.indexing, writeback: true, displacementFormat: memory.displacementFormat))
                    rows[storeRow].structuredOperands = envelope(store, operands: operands)
                    decline(MacIRBuilder().buildFunction(name: seed.name, instructions: rows), "no-writeback store cannot invent a base definition")
                }
            }
            let hsFixture = try memoryFixture(Self.rgbToPlanes8)
            let hs = try XCTUnwrap(hsFixture.rows[24].structuredOperands)
            var conditions = hs.operands
            let conditionIndex = try XCTUnwrap(conditions.firstIndex { if case .condition = $0 { return true }; return false })
            XCTAssertEqual(conditions[conditionIndex], .condition(.hs))
            conditions[conditionIndex] = .condition(.ge)
            var wrongCondition = hsFixture.rows
            wrongCondition[24].structuredOperands = envelope(hs, operands: conditions)
            decline(MacIRBuilder().buildFunction(name: Self.rgbToPlanes8.name, instructions: wrongCondition), "HS source condition cannot become signed GE")
            // Initial B.LT bypasses high-bit W4, so small executable scenarios do
            // not claim to distinguish signed GE from HS. Source authority does.
            for seed in [Self.returnHalfwordInput, Self.returnHalfwordOutput, Self.returnYCC] {
                let decoded = try memoryFixture(seed)
                guard case let .returnValue(value) = decoded.function.instructions.last!.operation else { return XCTFail("actual corpus RET operation changed") }
                let returned = try XCTUnwrap(value)
                XCTAssertEqual(returned, .unknown("unresolved_return_contract"), "retain the base policy marker when the captured stream lacks return-contract evidence")
                XCTAssertTrue(decoded.legacy.text.contains("return unresolved_return_contract;"))
                decline(decoded.function, "actual non-nil return control at \(seed.base)")
            }
            // Each new selector has a genuine production RED premise. All above
            // negative controls run before this positive admission assertion.
            let positive = try memoryFixture(Self.planesToBGR16)
            _ = requireUnsignedMemoryRepair(positive, Self.planesToBGR16)
        }
    }

    func testDefaultDecodedScalarMemoryCFGOracleDetectsSemanticCorruption() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            // Reuse the unchanged strict-parser baseline; only new parsed emissions
            // and their new semantic mutations are exercised by this selector.
            for seed in [Self.planar8, Self.bgrToPlanes16, Self.planesToBGR16] {
                let decoded = try memoryFixture(seed)
                if seed.kind == .planar8 {
                    // Null-only native semantics are excluded; every retained seed continues.
                    // Original null mutation assertions remain BLOCKED preserved evidence.
                    ExcludedNullFallback39A.requireHistorical(function: decoded.function,
                        document: decoded.document, legacy: decoded.legacy)
                    continue
                }
                guard requireUnsignedMemoryRepair(decoded, seed) else { return }
                // Bounded non-width adapter only. The integration layer handles
                // excluded planar8 before this call; width/sign/full64 stay OPEN.
                try assertNativeMemoryNonWidthSensitivity(decoded, seed)
            }
        }
    }
}

/// Literal conversion algorithms, not an instruction interpreter. This code
/// receives external inputs only. It distinguishes hoisted halfword tables,
/// per-row byte tables, component-major generic conversion, and access order.
private struct UnsignedMemoryScenario {
    enum Kind: String {
        case planar8, rgbToPlanes8, bgrToPlanes8, bgrToPlanes16, planesToBGR8, planesToBGR16
        var planarToInterleaved: Bool { self == .planar8 || self == .planesToBGR8 || self == .planesToBGR16 }
        var bytes: Int { self == .bgrToPlanes16 || self == .planesToBGR16 ? 2 : 1 }
        var reversed: Bool { self != .planar8 && self != .rgbToPlanes8 }
    }
    enum Alias: String { case none, laterRead, nextPixel, nextRowPointer, dataWrap, destinationWrap, rowPointerWrap }
    struct Reference { let result: ScalarTextMachine.Result; let states: [String: [UInt64]] }
    let context: UInt64 = 0x1_0000_1000
    let planes: UInt64 = 0x3_0000_3000
    let kind: Kind
    let width: UInt32
    let rows: UInt32
    let components: UInt32
    let initialIndex: UInt32
    let alias: Alias
    var memory: [UInt64: UInt8] = [:]
    var interleavedRows: UInt64 { alias == .rowPointerWrap ? UInt64.max - 7 : 0x2_0000_2000 }
    var label: String { "\(kind.rawValue), width=\(width), rows=\(rows), components=\(components), index=\(initialIndex), alias=\(alias.rawValue)" }
    var physical: [Int: UInt64] {
        kind.planarToInterleaved
            ? [0: context, 1: planes, 2: UInt64(initialIndex), 3: interleavedRows, 4: UInt64(rows)]
            : [0: context, 1: interleavedRows, 2: planes, 3: UInt64(initialIndex), 4: UInt64(rows)]
    }
    func table(_ component: Int) -> UInt64 { 0x4_0000_0000 + UInt64(component * 0x10000) }
    private func normalPlane(_ component: Int, _ row: Int) -> UInt64 {
        if component == 0 && row == 0 && ((alias == .dataWrap && kind.planarToInterleaved) || (alias == .destinationWrap && !kind.planarToInterleaved)) { return UInt64.max - UInt64(kind.bytes) }
        return 0x5_0000_0000 + UInt64(component * 0x10000 + row * 0x1000)
    }
    private func normalInterleaved(_ row: Int) -> UInt64 {
        if alias == .dataWrap && !kind.planarToInterleaved && row == 0 { return UInt64.max - UInt64(4 * kind.bytes) }
        if alias == .destinationWrap && kind.planarToInterleaved && row == 0 { return UInt64.max - UInt64(kind.bytes) }
        return 0x6_0000_0000 + UInt64(row * 0x10000)
    }
    func componentOffset(_ component: Int) -> UInt64 { UInt64((kind.reversed ? 2 - component : component) * kind.bytes) }
    func plane(_ component: Int, _ row: Int) -> UInt64 {
        if !kind.planarToInterleaved && component == 0 && row == 0 {
            switch alias {
            case .laterRead: return normalInterleaved(0) &+ componentOffset(1)
            case .nextPixel: return normalInterleaved(0) &+ UInt64(3 * kind.bytes) &+ componentOffset(0)
            case .nextRowPointer: return interleavedRows &+ 8
            default: break
            }
        }
        return normalPlane(component, row)
    }
    func interleaved(_ row: Int) -> UInt64 {
        if kind.planarToInterleaved && row == 0 {
            switch alias {
            case .laterRead: return normalPlane(1, 0) &- componentOffset(0)
            case .nextPixel: return normalPlane(0, 0) &+ UInt64(kind.bytes) &- componentOffset(0)
            case .nextRowPointer: return interleavedRows &+ 8
            default: break
            }
        }
        return normalInterleaved(row)
    }
    static func sample(component: Int, row: Int, pixel: Int, bytes: Int) -> UInt64 {
        // Every nominal sample has its top bit set; byte halves differ and
        // include nonzero high bytes, making accidental 8/16 widening visible.
        let lower = UInt64((0x81 + component * 17 + row * 29 + pixel * 11) & 0xff)
        return bytes == 1 ? lower : lower | (UInt64((0x91 + component * 7 + row * 13 + pixel * 5) & 0xff) << 8)
    }
    func sourceSample(_ component: Int, _ row: Int, _ pixel: Int) -> UInt64 {
        Self.sample(component: component, row: row, pixel: pixel, bytes: kind.bytes)
    }
    func outputAddress(_ component: Int, _ row: Int, _ pixel: Int) -> UInt64 {
        kind.planarToInterleaved
            ? interleaved(row) &+ UInt64(pixel * Int(components) * kind.bytes) &+ componentOffset(component)
            : plane(component, row) &+ UInt64(pixel * kind.bytes)
    }
    init(kind: Kind, width: UInt32, rows: UInt32, components: UInt32 = 3, index: UInt32 = 7, alias: Alias = .none) {
        self.kind = kind; self.width = width; self.rows = rows; self.components = components
        initialIndex = index; self.alias = alias
        func put(_ value: UInt64, _ address: UInt64, _ bytes: Int) {
            for offset in 0..<bytes { memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: value >> (offset * 8)) }
        }
        // Initialize bounded backing buffers, including the row-pointer alias
        // landing zone. No undefined source reads are silently zero-filled.
        for row in 0..<2 {
            for component in 0..<5 {
                for pixel in 0..<256 {
                    put(Self.sample(component: component, row: row, pixel: pixel, bytes: kind.bytes), normalPlane(component, row) &+ UInt64(pixel * kind.bytes), kind.bytes)
                }
            }
            for offset in 0..<1024 { memory[normalInterleaved(row) &+ UInt64(offset)] = UInt8(truncatingIfNeeded: 0xa5 + offset) }
            if components > 0 && components <= 5 {
                for pixel in 0..<32 {
                    for component in 0..<Int(components) {
                        put(sourceSample(component, row, pixel), normalInterleaved(row) &+ UInt64(pixel * Int(components) * kind.bytes) &+ componentOffset(component), kind.bytes)
                    }
                }
            }
        }
        put(UInt64(components), context &+ 0x38, 4)
        put(UInt64(width), context &+ (kind.planarToInterleaved ? 0x88 : 0x30), 4)
        for row in 0..<2 { put(interleaved(row), interleavedRows &+ UInt64(row * 8), 8) }
        for component in 0..<5 {
            put(table(component), planes &+ UInt64(component * 8), 8)
            for row in 0..<2 { put(plane(component, row), table(component) &+ (UInt64(index &+ UInt32(row)) << 3), 8) }
        }
        if alias == .nextRowPointer {
            let desired = interleaved(1) &+ 0x80
            if kind.planarToInterleaved {
                // Output byte positions 0...7 overwrite row one's pointer.
                // Supply exact source samples for that pointer, including BGR.
                for pixel in 0..<3 {
                    for component in 0..<Int(components) {
                        let offset = pixel * Int(components) * kind.bytes + Int(componentOffset(component))
                        if offset < 8 {
                            put(desired >> (offset * 8), normalPlane(component, 0) &+ UInt64(pixel * kind.bytes), kind.bytes)
                        }
                    }
                }
            } else {
                // Plane zero overwrites the low 3 or 6 bytes; untouched high
                // bytes are already the desired high bits of row one's pointer.
                for pixel in 0..<3 {
                    put(desired >> (pixel * kind.bytes * 8), normalInterleaved(0) &+ UInt64(pixel * 3 * kind.bytes) &+ componentOffset(0), kind.bytes)
                }
            }
        }
    }

    func reference() throws -> Reference {
        var result = ScalarTextMachine.Result(memory: memory)
        var states: [String: [UInt64]] = [:]
        func state(_ key: String, _ value: UInt64) { states[key, default: []].append(value) }
        func load(_ address: UInt64, _ bytes: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for offset in 0..<bytes {
                guard let byte = result.memory[address &+ UInt64(offset)] else { throw ScalarTextMachine.Failure.invalid("undefined literal source at \(address &+ UInt64(offset)): \(label)") }
                value |= UInt64(byte) << (offset * 8)
            }
            result.events.append(.init(kind: .load, address: address, bytes: bytes, value: value))
            return value
        }
        func store(_ value: UInt64, _ address: UInt64) {
            let narrowed = value & (kind.bytes == 1 ? 0xff : 0xffff)
            result.events.append(.init(kind: .store, address: address, bytes: kind.bytes, value: narrowed))
            for offset in 0..<kind.bytes { result.memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: narrowed >> (offset * 8)) }
        }
        var remaining = rows, index = initialIndex, rowPointers = interleavedRows
        var count: UInt32 = 3, pixels: UInt32 = 0
        if kind == .planar8 {
            count = UInt32(truncatingIfNeeded: try load(context &+ 0x38, 4))
            pixels = UInt32(truncatingIfNeeded: try load(context &+ 0x88, 4))
        }
        if Int32(bitPattern: remaining) >= 1 {
            if kind != .planar8 { pixels = UInt32(truncatingIfNeeded: try load(context &+ (kind.planarToInterleaved ? 0x88 : 0x30), 4)) }
            var invariantTables: [UInt64]? = nil
            if kind.bytes == 2 {
                // The halfword functions load all three table bases once,
                // including when pixel count is zero; the byte forms do not.
                invariantTables = [try load(planes, 8), try load(planes &+ 8, 8), try load(planes &+ 16, 8)]
            }
            repeat {
                if kind == .planar8 && count != 3 && count != 4 {
                    if Int32(bitPattern: count) >= 1 {
                        for component in 0..<Int(count) {
                            if pixels != 0 {
                                let table = try load(planes &+ UInt64(component * 8), 8)
                                var source = try load(table &+ (UInt64(index) << 3), 8)
                                var destination = try load(rowPointers, 8)
                                var left = UInt64(pixels)
                                repeat {
                                    let value = try load(source, 1)
                                    state("loaded", value)
                                    source &+= 1; state("source", source)
                                    store(value, destination &+ UInt64(component))
                                    destination &+= UInt64(count); state("inter", destination)
                                    left &-= 1; state("pixels", left)
                                } while left != 0
                            }
                            state("component", UInt64(component + 1))
                        }
                    }
                } else if pixels != 0 {
                    var pointers: [UInt64] = []
                    if let tables = invariantTables {
                        for table in tables { pointers.append(try load(table &+ (UInt64(index) << 3), 8)) }
                    } else {
                        let first = try load(planes, 8), second = try load(planes &+ 8, 8)
                        pointers = [try load(first &+ (UInt64(index) << 3), 8), try load(second &+ (UInt64(index) << 3), 8)]
                        if count == 4 {
                            let third = try load(planes &+ 16, 8), fourth = try load(planes &+ 24, 8)
                            pointers.append(try load(third &+ (UInt64(index) << 3), 8))
                            pointers.append(try load(fourth &+ (UInt64(index) << 3), 8))
                        } else {
                            let third = try load(planes &+ 16, 8)
                            pointers.append(try load(third &+ (UInt64(index) << 3), 8))
                        }
                    }
                    var inter = try load(rowPointers, 8)
                    inter &+= kind.reversed ? UInt64(2 * kind.bytes) : 0
                    var left = UInt64(pixels)
                    repeat {
                        for component in 0..<Int(count) {
                            let offset = kind.reversed ? -component * kind.bytes : component * kind.bytes
                            let address = inter &+ UInt64(bitPattern: Int64(offset))
                            if kind.planarToInterleaved {
                                let value = try load(pointers[component], kind.bytes)
                                state("loaded", value)
                                pointers[component] &+= UInt64(kind.bytes); state("plane\(component)", pointers[component])
                                store(value, address)
                            } else {
                                let value = try load(address, kind.bytes)
                                state("loaded", value)
                                store(value, pointers[component])
                                pointers[component] &+= UInt64(kind.bytes); state("plane\(component)", pointers[component])
                            }
                        }
                        inter &+= UInt64(Int(count) * kind.bytes); state("inter", inter)
                        left &-= 1; state("pixels", left)
                    } while left != 0
                }
                index &+= 1; state("index", UInt64(index))
                rowPointers &+= 8; state("rowsPointer", rowPointers)
                let oldCount = remaining
                remaining &-= 1; state("remaining", UInt64(remaining))
                if kind == .planar8 && count != 3 && count != 4 {
                    if Int32(bitPattern: oldCount) <= 1 { break }
                } else if oldCount < 2 { break }
            } while true
        }
        result.returned = true; result.returnMarker = "unresolved_return_contract"
        return Reference(result: result, states: states)
    }
}

/// Independent, finite memory reference for the decoded planar routine. It
/// receives only external inputs, never emitted expressions or register names.
private struct PlanarScenario {
    enum Alias: String { case none, sameSample, nextSample, nextRowPointer, addressWrap, signedBoundary }
    let context: UInt64 = 0x1_0000_1000
    var sourceRows: UInt64 { alias == .signedBoundary ? UInt64(Int64.max) - 4 : 0x2_0000_2000 }
    let planes: UInt64 = 0x3_0000_3000
    let width: UInt32
    let rowCount: UInt32
    let components: UInt32
    let outputIndex: UInt32
    let alias: Alias
    var memory: [UInt64: UInt8] = [:]
    var label: String { "components=\(components), width=\(width), rows=\(rowCount), index=\(outputIndex), alias=\(alias.rawValue)" }
    func table(_ component: Int) -> UInt64 { 0x4_0000_0000 + UInt64(component * 0x10000) }
    func samples(_ row: Int) -> UInt64 { alias == .addressWrap && row == 0 ? UInt64.max - 4 : 0x5_0000_0000 + UInt64(row * 0x10000) }
    func destination(_ component: Int, _ row: Int) -> UInt64 {
        if component == 0 && row == 0 {
            switch alias {
            case .sameSample: return samples(0) + 1
            case .nextSample: return samples(0) + UInt64(components)
            case .nextRowPointer: return sourceRows + 8
            case .addressWrap: return UInt64.max - 1
            case .none, .signedBoundary: break
            }
        }
        return 0x6_0000_0000 + UInt64(component * 0x10000 + row * 0x1000)
    }
    static func sampleValue(row: Int, byte: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: 0x11 + row * 0x61 + byte * 0x11)
    }
    init(width: UInt32, rows: UInt32, components: UInt32, outputIndex: UInt32 = 7, alias: Alias = .none) {
        self.width = width; rowCount = rows; self.components = components
        self.outputIndex = outputIndex; self.alias = alias
        func put(_ bits: UInt64, at address: UInt64, bytes: Int) {
            for offset in 0..<bytes { memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: bits >> (offset * 8)) }
        }
        put(UInt64(components), at: context + 0x5c, bytes: 4)
        put(UInt64(width), at: context + 0x30, bytes: 4)
        for row in 0..<2 {
            put(samples(row), at: sourceRows + UInt64(row * 8), bytes: 8)
        }
        for component in 0..<5 {
            put(table(component), at: planes + UInt64(component * 8), bytes: 8)
            for row in 0..<2 {
                let index = outputIndex &+ UInt32(row)
                put(destination(component, row), at: table(component) &+ (UInt64(index) << 3), bytes: 8)
                let normal: UInt64 = 0x6_0000_0000 + UInt64(component * 0x10000 + row * 0x1000)
                for offset in 0..<32 { memory[normal + UInt64(offset)] = 0xa5 }
            }
        }
        for row in 0..<2 {
            for offset in 0..<512 { memory[samples(row) &+ UInt64(offset)] = Self.sampleValue(row: row, byte: offset) }
        }
        if alias == .nextRowPointer {
            // The first plane overwrites the low three bytes of row one's
            // source pointer. Its next read must observe samples(1)+0x80.
            for (pixel, byte): (Int, UInt8) in [(0, 0x80), (1, 0), (2, 1)] {
                memory[samples(0) + UInt64(pixel) * UInt64(components)] = byte
            }
        }
    }
    func reference() throws -> ScalarTextMachine.Result {
        var result = ScalarTextMachine.Result(memory: memory)
        func load(_ address: UInt64, _ bytes: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for offset in 0..<bytes {
                guard let byte = result.memory[address &+ UInt64(offset)] else {
                    throw ScalarTextMachine.Failure.invalid("reference read of undefined byte at \(address + UInt64(offset))")
                }
                value |= UInt64(byte) << (offset * 8)
            }
            result.events.append(.init(kind: .load, address: address, bytes: bytes, value: value))
            return value
        }
        func store(_ value: UInt64, _ address: UInt64) {
            let byte = UInt8(truncatingIfNeeded: value)
            result.events.append(.init(kind: .store, address: address, bytes: 1, value: UInt64(byte)))
            result.memory[address] = byte
        }
        let count = UInt32(truncatingIfNeeded: try load(context + 0x5c, 4))
        let pixels = UInt32(truncatingIfNeeded: try load(context + 0x30, 4))
        var remaining = rowCount, index = outputIndex, inputRows = sourceRows
        if Int32(bitPattern: remaining) >= 1 {
            repeat {
                if count == 3 || count == 4 {
                    if pixels != 0 {
                        // Both halves of each LDP are reads before either
                        // indexed pointer use. Keep this observable order.
                        let firstTable = try load(planes, 8)
                        let secondTable = try load(planes + 8, 8)
                        var destinations = [try load(firstTable &+ (UInt64(index) << 3), 8),
                                            try load(secondTable &+ (UInt64(index) << 3), 8)]
                        if count == 4 {
                            let thirdTable = try load(planes + 16, 8)
                            let fourthTable = try load(planes + 24, 8)
                            destinations.append(try load(thirdTable &+ (UInt64(index) << 3), 8))
                            destinations.append(try load(fourthTable &+ (UInt64(index) << 3), 8))
                        } else {
                            let thirdTable = try load(planes + 16, 8)
                            destinations.append(try load(thirdTable &+ (UInt64(index) << 3), 8))
                        }
                        var source = try load(inputRows, 8)
                        for _ in 0..<pixels {
                            for component in 0..<Int(count) {
                                let byte = try load(source &+ UInt64(component), 1)
                                store(byte, destinations[component])
                                destinations[component] &+= 1
                            }
                            source &+= UInt64(count)
                        }
                    }
                } else if Int32(bitPattern: count) >= 1 {
                    for component in 0..<Int(count) {
                        if pixels != 0 {
                            let rowTable = try load(planes &+ UInt64(component * 8), 8)
                            var destination = try load(rowTable &+ (UInt64(index) << 3), 8)
                            var source = try load(inputRows, 8)
                            for _ in 0..<pixels {
                                let byte = try load(source &+ UInt64(component), 1)
                                store(byte, destination)
                                destination &+= 1
                                source &+= UInt64(count)
                            }
                        }
                    }
                }
                inputRows &+= 8
                index &+= 1
                let writerTimeRows = remaining
                remaining &-= 1
                // The actual compare precedes SUB. Modes 3/4 use unsigned
                // old-W4<2; the general arm uses signed old-W4>1.
                if count == 3 || count == 4 {
                    if writerTimeRows < 2 { break }
                } else if Int32(bitPattern: writerTimeRows) <= 1 { break }
            } while true
        }
        result.returned = true
        result.returnMarker = "unresolved_return_contract"
        return result
    }
}
private struct ScalarTextMachine {
    enum Failure: Error { case invalid(String), undefined(String) }
    struct CType: Equatable {
        let width: Int
        let unsigned: Bool
        static let u32 = CType(width: 32, unsigned: true)
        static let u64 = CType(width: 64, unsigned: true)
        static let i32 = CType(width: 32, unsigned: false)
        static let i64 = CType(width: 64, unsigned: false)
        init(width: Int, unsigned: Bool) { self.width = width; self.unsigned = unsigned }
        init?(_ text: String) {
            let unsigned = text.hasPrefix("uint")
            guard text.hasSuffix("_t"), text.hasPrefix("int") || unsigned else { return nil }
            let digits = text.dropFirst(unsigned ? 4 : 3).dropLast(2)
            guard let width = Int(digits), [8, 16, 32, 64].contains(width) else { return nil }
            self.init(width: width, unsigned: unsigned)
        }
        var mask: UInt64 { width == 64 ? .max : (UInt64(1) << width) - 1 }
    }
    struct Value: Equatable {
        let bits: UInt64
        let type: CType
        init(bits: UInt64, type: CType) { self.bits = bits & type.mask; self.type = type }
        var signed: Int64 {
            if type.width == 64 { return Int64(bitPattern: bits) }
            let sign = UInt64(1) << (type.width - 1)
            return Int64(bitPattern: (bits ^ sign) &- sign)
        }
        func cast(_ target: CType) -> Value {
            let extended = !type.unsigned && signed < 0 ? UInt64(bitPattern: signed) : bits
            return .init(bits: extended, type: target)
        }
        var promoted: Value { type.width < 32 ? cast(.i32) : self }
    }
    indirect enum Expression {
        case literal(Value), variable(String), cast(CType, Expression)
        case binary(String, Expression, Expression), unary(String, Expression)
        case memory(CType, Expression)
        var variables: Set<String> {
            switch self {
            case .literal: return []
            case let .variable(name): return [name]
            case let .cast(_, value), let .unary(_, value), let .memory(_, value): return value.variables
            case let .binary(_, left, right): return left.variables.union(right.variables)
            }
        }
    }
    enum Operation {
        case assign([Expression], [Expression], CType?)
        case declare(String)
        case branch(Expression, Int)
        case jump(Int)
        case returned(Expression?)
        case unresolvedReturn
    }
    struct Instruction { let operation: Operation; let source: UInt64? }
    struct Program {
        var code: [Instruction]
        var declarations: [String: CType]
        init(document: PseudocodeDocument) throws {
            var compiler = Compiler(document: document)
            try compiler.compile()
            code = compiler.code
            declarations = compiler.declarations
        }
        static func number(_ text: String) -> UInt64? {
            text.hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
        }
        static func lex(_ text: String) throws -> [String] {
            let chars = Array(text)
            var result: [String] = [], index = 0
            while index < chars.count {
                let char = chars[index]
                if char.isWhitespace { index += 1; continue }
                if char.isLetter || char.isNumber || char == "_" {
                    let start = index
                    while index < chars.count && (chars[index].isLetter || chars[index].isNumber || chars[index] == "_") { index += 1 }
                    result.append(String(chars[start..<index])); continue
                }
                if index + 1 < chars.count {
                    let pair = String(chars[index...index + 1])
                    if ["==", "!=", "<<", ">>", "<=", ">=", "&&", "||"].contains(pair) {
                        result.append(pair); index += 2; continue
                    }
                }
                guard "()+-*&|^~=,;{}<>!:".contains(char) else { throw Failure.invalid("unknown token \(char)") }
                result.append(String(char)); index += 1
            }
            return result
        }
        static func split(_ tokens: [String], at separator: String) throws -> [[String]] {
            var result: [[String]] = [[]], depth = 0
            for token in tokens {
                if token == "(" { depth += 1 }
                if token == ")" { depth -= 1 }
                guard depth >= 0 else { throw Failure.invalid("unbalanced expression") }
                if token == separator && depth == 0 { result.append([]) }
                else { result[result.count - 1].append(token) }
            }
            guard depth == 0 else { throw Failure.invalid("unclosed expression") }
            return result
        }
        static func expression(_ tokens: [String]) throws -> Expression {
            var parser = ExpressionParser(tokens: tokens)
            let result = try parser.parse()
            guard parser.index == tokens.count else { throw Failure.invalid("trailing expression / unknown helper: \(tokens)") }
            return result
        }
    }
    /// Compile only the deliberately enumerated scalar text grammar. No line
    /// is ignored because it is unfamiliar; source metadata only locates raw
    /// goto targets and records observations, never supplies expression values.
    struct Compiler {
        struct Token { let text: String; let source: UInt64? }
        struct Loop { let continueTarget: Int?; var breaks: [Int] = []; var continues: [Int] = [] }
        let document: PseudocodeDocument
        var tokens: [Token] = []
        var markers: [Int: [UInt64]] = [:]
        var index = 0
        var code: [Instruction] = []
        var declarations: [String: CType] = [:]
        var addresses: [UInt64: Int] = [:]
        var labels: [String: Int] = [:]
        var pending: [(Int, String)] = []
        var loops: [Loop] = []
        var braceDepth = 0
        var seenExecutable = false
        var current: String? { index < tokens.count ? tokens[index].text : nil }
        mutating func mark() {
            for source in markers[index] ?? [] where addresses[source] == nil { addresses[source] = code.count }
        }
        mutating func take(_ expected: String) throws {
            guard current == expected else { throw Failure.invalid("expected \(expected), got \(current ?? "end")") }
            index += 1
        }
        mutating func emit(_ operation: Operation, source: UInt64?) -> Int {
            let pc = code.count
            code.append(.init(operation: operation, source: source))
            return pc
        }
        mutating func patch(_ pc: Int, _ target: Int) throws {
            switch code[pc].operation {
            case let .branch(predicate, _): code[pc] = .init(operation: .branch(predicate, target), source: code[pc].source)
            case .jump: code[pc] = .init(operation: .jump(target), source: code[pc].source)
            default: throw Failure.invalid("invalid control patch")
            }
        }
        mutating func compile() throws {
            for line in document.lines {
                let clean = line.text.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                switch line.kind {
                case .signature: continue // The declared function frame is not an executable statement.
                case .closingBrace:
                    guard clean == "}" else { throw Failure.invalid("invalid function close") }
                    continue
                case .metadata:
                    guard clean.isEmpty else { throw Failure.invalid("executable metadata must not be skipped") }
                    continue
                case .instruction, .declaration: break
                }
                if let source = line.sourceAddress { markers[tokens.count, default: []].append(source) }
                tokens += try Program.lex(clean).map { Token(text: $0, source: line.sourceAddress) }
            }
            try sequence(untilClose: false)
            for (pc, target) in pending {
                let resolved = Program.number(target).flatMap { addresses[$0] } ?? labels[target]
                guard let resolved else { throw Failure.invalid("unresolved emitted goto \(target)") }
                try patch(pc, resolved)
            }
        }
        mutating func sequence(untilClose: Bool) throws {
            while index < tokens.count {
                mark()
                if current == "}" {
                    guard untilClose else { throw Failure.invalid("unexpected closing brace") }
                    index += 1
                    return
                }
                try statement()
            }
            mark()
            guard !untilClose else { throw Failure.invalid("unclosed body") }
        }
        mutating func condition() throws -> Expression {
            try take("(")
            let start = index
            var depth = 1
            while index < tokens.count {
                if current == "(" { depth += 1 }
                if current == ")" { depth -= 1 }
                if depth == 0 {
                    let expression = try Program.expression(tokens[start..<index].map(\.text))
                    index += 1
                    return expression
                }
                index += 1
            }
            throw Failure.invalid("unclosed condition")
        }
        mutating func statement() throws {
            mark()
            guard index < tokens.count else { throw Failure.invalid("missing statement") }
            let source = tokens[index].source
            if current == "{" {
                index += 1; braceDepth += 1
                try sequence(untilClose: true)
                braceDepth -= 1
                return
            }
            if current == "if" {
                seenExecutable = true
                index += 1
                let predicate = try condition()
                let falsePC = emit(.branch(.unary("!", predicate), -1), source: source)
                try statement()
                if current == "else" {
                    index += 1
                    let endPC = emit(.jump(-1), source: nil)
                    try patch(falsePC, code.count)
                    try statement()
                    try patch(endPC, code.count)
                } else { try patch(falsePC, code.count) }
                return
            }
            if current == "while" {
                seenExecutable = true
                index += 1
                let start = code.count
                let predicate = try condition()
                let exitPC = emit(.branch(.unary("!", predicate), -1), source: source)
                loops.append(.init(continueTarget: start))
                try statement()
                _ = emit(.jump(start), source: nil)
                let loop = loops.removeLast()
                try patch(exitPC, code.count)
                for site in loop.breaks { try patch(site, code.count) }
                for site in loop.continues { try patch(site, start) }
                return
            }
            if current == "do" {
                seenExecutable = true
                index += 1
                let start = code.count
                loops.append(.init(continueTarget: nil))
                try statement()
                mark()
                let conditionSource = index < tokens.count ? tokens[index].source : nil
                try take("while")
                let predicate = try condition()
                try take(";")
                let test = emit(.branch(predicate, start), source: conditionSource)
                let loop = loops.removeLast()
                for site in loop.breaks { try patch(site, code.count) }
                for site in loop.continues { try patch(site, test) }
                return
            }
            if current == "break" || current == "continue" {
                let isBreak = current == "break"
                guard !loops.isEmpty else { throw Failure.invalid("loop control outside loop") }
                index += 1; try take(";")
                let site = emit(.jump(-1), source: source)
                if isBreak { loops[loops.count - 1].breaks.append(site) }
                else { loops[loops.count - 1].continues.append(site) }
                return
            }
            if current == "goto" {
                seenExecutable = true
                index += 1
                guard let target = current else { throw Failure.invalid("missing goto target") }
                index += 1; try take(";")
                pending.append((emit(.jump(-1), source: source), target))
                return
            }
            if index + 1 < tokens.count, tokens[index + 1].text == ":" {
                let name = tokens[index].text
                guard labels[name] == nil else { throw Failure.invalid("duplicate label") }
                labels[name] = code.count
                index += 2
                return
            }
            let start = index
            while index < tokens.count && current != ";" {
                guard current != "{" && current != "}" else { throw Failure.invalid("unterminated simple statement") }
                index += 1
            }
            guard current == ";" else { throw Failure.invalid("missing semicolon") }
            var body = tokens[start..<index].map(\.text)
            index += 1
            guard !body.isEmpty else { throw Failure.invalid("empty statement not in emitted subset") }
            if body.first == "return" {
                seenExecutable = true
                body.removeFirst()
                if body == ["unresolved_return_contract"] { _ = emit(.unresolvedReturn, source: source) }
                else { _ = emit(.returned(body.isEmpty ? nil : try Program.expression(body)), source: source) }
                return
            }
            let declared = body.first.flatMap(CType.init)
            if declared != nil { body.removeFirst() }
            let parts = try Program.split(body, at: "=")
            if let declared {
                guard braceDepth == 0, !seenExecutable else {
                    throw Failure.invalid("nested or late declaration outside the supported function-scope storage grammar")
                }
                guard parts[0].count == 1, let name = parts[0].first,
                      name.first?.isLetter == true || name.first == "_",
                      !["if", "else", "while", "do", "break", "continue", "goto", "return", "true", "false"].contains(name),
                      declarations[name] == nil,
                      !document.parameters.contains(where: { $0.name == name }),
                      !document.localVariables.contains(where: { $0.name == name }) else {
                    throw Failure.invalid("duplicate, colliding, or non-scalar declaration")
                }
                declarations[name] = declared
                if parts.count == 1 { _ = emit(.declare(name), source: source); return }
            }
            if declared == nil { seenExecutable = true }
            guard parts.count == 2 else { throw Failure.invalid("unknown statement / helper: \(body)") }
            let left = try Program.split(parts[0], at: ",").map(Program.expression)
            let right = try Program.split(parts[1], at: ",").map(Program.expression)
            guard left.count == right.count, !left.isEmpty else { throw Failure.invalid("tuple arity") }
            for destination in left {
                if case let .variable(name) = destination, document.parameters.contains(where: { $0.name == name }) {
                    throw Failure.invalid("assignment to an external input parameter outside the storage grammar")
                }
            }
            _ = emit(.assign(left, right, declared), source: source)
        }
    }
    struct ExpressionParser {
        let tokens: [String]
        var index = 0
        let precedence = ["||": 1, "&&": 2, "|": 3, "^": 4, "&": 5, "==": 6, "!=": 6,
                          "<": 7, ">": 7, "<=": 7, ">=": 7, "<<": 8, ">>": 8, "+": 9, "-": 9, "*": 10]
        mutating func take(_ expected: String) throws {
            guard index < tokens.count, tokens[index] == expected else { throw Failure.invalid("expected \(expected): \(tokens)") }
            index += 1
        }
        mutating func parse(_ minimum: Int = 0) throws -> Expression {
            var left = try prefix()
            while index < tokens.count, let priority = precedence[tokens[index]], priority >= minimum {
                let op = tokens[index]; index += 1
                let right = try parse(priority + 1)
                left = .binary(op, left, right)
            }
            return left
        }
        mutating func prefix() throws -> Expression {
            guard index < tokens.count else { throw Failure.invalid("empty expression") }
            let token = tokens[index]; index += 1
            if token == "*" {
                try take("(")
                if index < tokens.count, let type = CType(tokens[index]) {
                    index += 1; try take("*"); try take(")")
                    return .memory(type, try prefix())
                }
                let address = try parse(); try take(")")
                // The existing scalar wide-memory dialect prints *(address).
                return .memory(.u64, address)
            }
            if token == "(" {
                if index < tokens.count, let type = CType(tokens[index]) {
                    index += 1; try take(")")
                    return .cast(type, try prefix())
                }
                let result = try parse(); try take(")"); return result
            }
            if token == "-" || token == "~" || token == "!" { return .unary(token, try prefix()) }
            if token == "true" || token == "false" { return .literal(.init(bits: token == "true" ? 1 : 0, type: .i32)) }
            if token.first?.isNumber == true {
                guard let bits = Program.number(token) else { throw Failure.invalid("unsupported integer literal \(token)") }
                let type: CType
                if token.hasPrefix("0x") {
                    // Unsuffixed hexadecimal LP64 candidates are int,
                    // unsigned int, long, unsigned long (then equivalent LL).
                    if bits <= UInt64(Int32.max) { type = .i32 }
                    else if bits <= UInt64(UInt32.max) { type = .u32 }
                    else if bits <= UInt64(Int64.max) { type = .i64 }
                    else { type = .u64 }
                } else {
                    // Unsuffixed decimal has no unsigned candidate. Extended
                    // integer types and decimal values outside signed64 are
                    // intentionally outside this emitted subset.
                    guard bits <= UInt64(Int64.max) else { throw Failure.invalid("unsupported decimal overflow \(token)") }
                    type = bits <= UInt64(Int32.max) ? .i32 : .i64
                }
                return .literal(.init(bits: bits, type: type))
            }
            guard token.first?.isLetter == true || token.first == "_" else { throw Failure.invalid("invalid expression atom \(token)") }
            return .variable(token)
        }
    }
    struct Event: Equatable {
        enum Kind: Equatable { case load, store }
        let kind: Kind
        let address: UInt64
        let bytes: Int
        let value: UInt64
    }
    struct Commit { let source: UInt64; let values: [Value] }
    struct Result {
        // Native observations are indexed by original semantic slot and actual
        // committed AST span; they are never candidate environment cells.
        var sourceSlotWrites: [UInt64: [Int: [Value]]] = [:]
        var nativeLoadedValues: [Value] = []
        // Observation only: existing execution and accepted grammar are unchanged.
        var commits: [Commit] = []
        var events: [Event] = []
        var decisions: [Bool] = []
        var assignments: [UInt64: [[Value]]] = [:]
        var finalAssignments: [UInt64: [[Value]]] = [:]
        var memory: [UInt64: UInt8]
        var returned = false
        var returnValue: Value?
        var returnMarker: String?
    }
    let program: Program
    var environment: [String: Value]
    var result: Result
    init(program: Program, inputs: [String: Value], memory: [UInt64: UInt8]) {
        self.program = program; environment = inputs; result = .init(memory: memory)
    }
    func run() throws -> Result {
        var machine = self
        return try machine.execute()
    }
    private mutating func execute() throws -> Result {
        var pc = 0, fuel = 20000
        var lastAssignment: [UInt64: Int] = [:]
        for (site, instruction) in program.code.enumerated() {
            if let source = instruction.source, case .assign = instruction.operation { lastAssignment[source] = site }
        }
        while program.code.indices.contains(pc), fuel > 0 {
            fuel -= 1
            let instruction = program.code[pc]
            switch instruction.operation {
            case let .assign(left, right, declared):
                // Evaluate all RHS and all memory lvalue addresses before any
                // assignment. This models the printer's parallel tuple dialect.
                var values: [Value] = []
                for expression in right { values.append(try evaluate(expression)) }
                var addresses: [UInt64?] = []
                for target in left {
                    if case let .memory(_, address) = target { addresses.append(try evaluate(address).bits) }
                    else { addresses.append(nil) }
                }
                var committed: [Value] = []
                for index in left.indices {
                    let value = declared.map { values[index].cast($0) } ?? values[index]
                    switch left[index] {
                    case let .variable(name):
                        let stored = program.declarations[name].map { value.cast($0) } ?? value
                        environment[name] = stored
                        committed.append(stored)
                    case let .memory(type, _):
                        guard let address = addresses[index] else { throw Failure.invalid("missing lvalue address") }
                        let narrowed = value.cast(type)
                        committed.append(narrowed)
                        result.events.append(.init(kind: .store, address: address, bytes: type.width / 8, value: narrowed.bits))
                        for offset in 0..<(type.width / 8) {
                            result.memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: narrowed.bits >> (offset * 8))
                        }
                    default: throw Failure.invalid("non-lvalue assignment")
                    }
                }
                if let source = instruction.source {
                    result.assignments[source, default: []].append(values)
                    result.commits.append(.init(source: source, values: committed))
                    if lastAssignment[source] == pc { result.finalAssignments[source, default: []].append(committed) }
                }
                pc += 1
            case let .declare(name):
                environment.removeValue(forKey: name)
                pc += 1
            case let .jump(target): pc = target
            case let .branch(predicate, target):
                let taken = try evaluate(predicate).bits != 0
                result.decisions.append(taken)
                pc = taken ? target : pc + 1
            case let .returned(value):
                if let value { result.returnValue = try evaluate(value) }
                result.returned = true; return result
            case .unresolvedReturn:
                result.returned = true; result.returnMarker = "unresolved_return_contract"; return result
            }
        }
        throw Failure.invalid(fuel == 0 ? "unproductive control-flow fuel exhaustion" : "fell out without RET")
    }
    private mutating func evaluate(_ expression: Expression) throws -> Value {
        switch expression {
        case let .literal(value): return value
        case let .variable(name):
            guard let value = environment[name] else { throw Failure.invalid("unbound emitted identifier \(name)") }
            return value
        case let .cast(type, value): return try evaluate(value).cast(type)
        case let .memory(type, address):
            let location = try evaluate(address).bits
            var bits: UInt64 = 0
            for offset in 0..<(type.width / 8) {
                guard let byte = result.memory[location &+ UInt64(offset)] else {
                    throw Failure.invalid("read of undefined memory at \(location &+ UInt64(offset))")
                }
                bits |= UInt64(byte) << (offset * 8)
            }
            result.events.append(.init(kind: .load, address: location, bytes: type.width / 8, value: bits))
            return .init(bits: bits, type: type)
        case let .unary(op, expression):
            let value = try evaluate(expression).promoted
            if op == "~" { return .init(bits: ~value.bits, type: value.type) }
            if op == "!" { return .init(bits: value.bits == 0 ? 1 : 0, type: .i32) }
            guard op == "-" else { throw Failure.invalid("unknown unary operator \(op)") }
            return try binary("-", .init(bits: 0, type: value.type), value)
        case let .binary(op, lhs, rhs):
            let left = try evaluate(lhs)
            if op == "&&", left.bits == 0 { return .init(bits: 0, type: .i32) }
            if op == "||", left.bits != 0 { return .init(bits: 1, type: .i32) }
            let right = try evaluate(rhs)
            if op == "&&" || op == "||" { return .init(bits: right.bits != 0 ? 1 : 0, type: .i32) }
            return try binary(op, left, right)
        }
    }
    private func binary(_ op: String, _ lhs: Value, _ rhs: Value) throws -> Value {
        let left = lhs.promoted, right = rhs.promoted
        if op == "<<" || op == ">>" {
            guard right.type.unsigned || right.signed >= 0, right.bits < UInt64(left.type.width) else {
                throw Failure.undefined("shift amount outside width")
            }
            let shift = Int(right.bits)
            if op == ">>" {
                return .init(bits: left.type.unsigned ? left.bits >> shift : UInt64(bitPattern: left.signed >> shift), type: left.type)
            }
            if !left.type.unsigned && (left.signed < 0 || left.bits > (left.type.mask >> 1) >> shift) {
                throw Failure.undefined("signed left shift overflow")
            }
            return .init(bits: left.bits << shift, type: left.type)
        }
        let type: CType
        if left.type.width == right.type.width {
            type = .init(width: left.type.width, unsigned: left.type.unsigned || right.type.unsigned)
        } else {
            // The wider signed type represents every value of a narrower
            // unsigned type for the supported 32/64-bit integer domains.
            type = left.type.width > right.type.width ? left.type : right.type
        }
        let a = left.cast(type), b = right.cast(type)
        if op == "==" || op == "!=" { return .init(bits: (op == "==" ? a.bits == b.bits : a.bits != b.bits) ? 1 : 0, type: .i32) }
        if ["<", ">", "<=", ">="].contains(op) {
            let less = type.unsigned ? a.bits < b.bits : a.signed < b.signed
            let equal = a.bits == b.bits
            let truth: Bool
            switch op {
            case "<": truth = less
            case ">": truth = !less && !equal
            case "<=": truth = less || equal
            default: truth = !less
            }
            return .init(bits: truth ? 1 : 0, type: .i32)
        }
        if op == "&" { return .init(bits: a.bits & b.bits, type: type) }
        if op == "|" { return .init(bits: a.bits | b.bits, type: type) }
        if op == "^" { return .init(bits: a.bits ^ b.bits, type: type) }
        if type.unsigned {
            switch op {
            case "+": return .init(bits: a.bits &+ b.bits, type: type)
            case "-": return .init(bits: a.bits &- b.bits, type: type)
            case "*": return .init(bits: a.bits &* b.bits, type: type)
            default: throw Failure.invalid("unknown binary operator \(op)")
            }
        }
        let checked: (partialValue: Int64, overflow: Bool)
        switch op {
        case "+": checked = a.signed.addingReportingOverflow(b.signed)
        case "-": checked = a.signed.subtractingReportingOverflow(b.signed)
        case "*": checked = a.signed.multipliedReportingOverflow(by: b.signed)
        default: throw Failure.invalid("unknown signed binary operator \(op)")
        }
        guard !checked.overflow,
              type.width == 64 || (checked.partialValue >= Int64(Int32.min) && checked.partialValue <= Int64(Int32.max)) else {
            throw Failure.undefined("signed arithmetic overflow")
        }
        return .init(bits: UInt64(bitPattern: checked.partialValue), type: type)
    }
}


// Native candidate adapter for the seven historical scalar selectors. This is
// separately bound to their original byte/text/envelope inputs. No exact-site
// native scalar receipt is imported, and the literal algorithms above are unchanged.
// SOURCE ONLY / NOT RUN. The retained legacy mutation bodies are not retired.
extension DecodedScalarCFGTests {
    private typealias Ordinary = OrdinaryC
    private typealias NoCall = NativeScalarNoCallContract
    private typealias NativeOwnership = NativeScalarSourceOwnership
    private typealias NativeAnchors = NativeScalarSourceAnchors
    private typealias NativeLedger = OrdinaryCSourceEdgeLedger
    private typealias OriginalAccess = NativeScalarOriginalBindings

    private struct HistoricalSlot: Hashable {
        let row: Int
        let ordinal: Int
    }
    private struct HistoricalDefinition {
        let slot: HistoricalSlot
        let architecturalOrdinal: Int
        let width: Int
        let name: String
        let span: Ordinary.Span
        let kind: NativeAnchors.Kind
    }
    private struct HistoricalNativePrepared {
        let program: Ordinary.Program
        let manifest: NoCall.FrozenManifest
        let inventory: NativeOwnership.Inventory
        let anchors: NativeAnchors.Certificate
        let topology: NativeLedger.Report
        let byteMap: NativeOwnership.HistoricalByteMapProgram
        let definitions: [Ordinary.Span: HistoricalDefinition]
        let copies: Set<Ordinary.Span>
        let formals: [String: Int]
    }
    private struct HistoricalNativeResult {
        let raw: Ordinary.Result
        let memory: [UInt64: UInt8]
        let events: [ScalarTextMachine.Event]
        let writes: [HistoricalSlot: [Ordinary.Value]]
        let loaded: [Ordinary.Value]
        var returned: Bool { raw.returned }
        var returnMarker: String? { raw.unavailableTerminal == .unresolvedReturnContract ? "unresolved_return_contract" : nil }
        var returnValue: Ordinary.Value? { raw.terminal }
        func values(row: Int, ordinal: Int = 0) -> [UInt64] {
            writes[.init(row: row, ordinal: ordinal), default: []].map(\.bits)
        }
    }
    private enum HistoricalMemoryModel {
        case strictOrdinaryC, retainedHalfwordByteMap64
        func label(_ name: String) -> String {
            switch self {
            case .strictOrdinaryC: return name + " [strict ordinary C]"
            case .retainedHalfwordByteMap64: return name + " [abstract historical ByteMap64, not C-definedness]"
            }
        }
    }
    private func historicalMemoryModel(_ scenario: UnsignedMemoryScenario,
        prepared: HistoricalNativePrepared) throws -> HistoricalMemoryModel {
        guard scenario.kind.bytes == 2, scenario.alias == .dataWrap || scenario.alias == .destinationWrap else {
            return .strictOrdinaryC
        }
        let base: UInt64
        switch scenario.kind {
        case .bgrToPlanes16: base = 0x4e84
        case .planesToBGR16: base = 0x29a70
        default: throw Ordinary.Failure.invalidContract("no historical byte-map authority for this source kind")
        }
        guard prepared.inventory.source.rows.first?.address == base,
              scenario.width == 3, scenario.rows == 2, scenario.components == 3,
              scenario.initialIndex == UInt32.max else {
            throw Ordinary.Failure.invalidContract("abstract byte-map mode is limited to the exact retained halfword wrap scenarios")
        }
        return .retainedHalfwordByteMap64
    }
    private func historicalInput(_ fixture: Fixture) throws -> NativeOwnership.HistoricalSource {
        func bytes(_ text: String) throws -> [UInt8] {
            try text.split(whereSeparator: \.isWhitespace).map {
                guard let byte = UInt8($0, radix: 16) else { throw Ordinary.Failure.invalidContract("invalid frozen byte") }
                return byte
            }
        }
        guard let base = fixture.rows.first?.address else { throw Ordinary.Failure.invalidContract("empty historical source") }
        if [UInt64(0x3704), 0x913804, 0x3a704, 0x4b704].contains(base) {
            return try NativeOwnership.bindHistoricalScalar(.planar, rows: fixture.rows,
                literalBytes: bytes(Self.planarBytes),
                literalText: Self.planarSourceText.split(separator: "\n").map(String.init), operandWitnesses: nil)
        }
        guard let seed = Self.unsignedMemorySeeds.first(where: { $0.base == base }), let kind = seed.kind else {
            throw Ordinary.Failure.invalidContract("not one of the seven original historical scalar streams")
        }
        let identity: NativeOwnership.HistoricalSeed
        switch kind {
        case .planar8: identity = .planar8
        case .rgbToPlanes8: identity = .rgbToPlanes8
        case .bgrToPlanes8: identity = .bgrToPlanes8
        case .bgrToPlanes16: identity = .bgrToPlanes16
        case .planesToBGR8: identity = .planesToBGR8
        case .planesToBGR16: identity = .planesToBGR16
        }
        return try NativeOwnership.bindHistoricalScalar(identity, rows: fixture.rows,
            literalBytes: bytes(seed.bytes), literalText: seed.text.split(separator: "\n").map(String.init),
            operandWitnesses: seed.operandWitnesses)
    }
    private func historicalNative(_ fixture: Fixture) throws -> HistoricalNativePrepared {
        guard let base = fixture.rows.first?.address else { throw Ordinary.Failure.invalidContract("empty historical source") }
        if let cached = historicalNativeCache[base], cached.fixture == fixture {
            return cached.prepared
        }
        let prepared = try prepareHistoricalNative(fixture)
        historicalNativeCache[base] = (fixture, prepared)
        return prepared
    }
    private func historicalObservations(_ result: HistoricalNativeResult,
        prepared: HistoricalNativePrepared) -> ScalarTextMachine.Result {
        var observation = ScalarTextMachine.Result(memory: result.memory)
        observation.events = result.events; observation.returned = result.returned
        observation.returnMarker = result.returnMarker
        func value(_ value: Ordinary.Value) -> ScalarTextMachine.Value {
            .init(bits: value.bits, type: .init(width: value.type.width, unsigned: value.type.unsigned))
        }
        for (slot, values) in result.writes {
            observation.sourceSlotWrites[prepared.inventory.source.rows[slot.row].address, default: [:]][slot.ordinal] = values.map(value)
        }
        observation.nativeLoadedValues = result.loaded.map(value)
        return observation
    }
    private func prepareHistoricalNative(_ fixture: Fixture) throws -> HistoricalNativePrepared {
        let historical = try historicalInput(fixture)
        let inventory = try NativeOwnership.makeHistoricalScalar(historical)
        let source = inventory.source, accesses = try fixture.rows.map(OriginalAccess.literalAccess)
        // Original literal backwards demand, not candidate variable spelling.
        var demands: [Int: [Int: Int]] = [:], changed = true
        while changed {
            changed = false
            for block in source.blocks.reversed() where inventory.reachableBlocks.contains(block.index) {
                var demand: [Int: Int] = [:]
                for successor in block.successors {
                    for (register, width) in demands[successor, default: [:]] {
                        demand[register] = max(demand[register, default: 0], width)
                    }
                }
                for row in block.rows.reversed() {
                    for write in accesses[row].writes { demand.removeValue(forKey: write.index) }
                    for read in accesses[row].reads { demand[read.index] = max(demand[read.index, default: 0], read.width) }
                }
                if demand != demands[block.index] { demands[block.index] = demand; changed = true }
            }
        }
        var formals: [NoCall.Formal] = [], formalRegisters: [String: Int] = [:]
        let parameters = fixture.function.parameters
        guard Set(parameters.map(\.id)).count == parameters.count,
              Set(parameters.compactMap(\.bindingID)).count == parameters.count else {
            throw Ordinary.Failure.invalidContract("duplicate original historical input identity")
        }
        for (ordinal, parameter) in parameters.enumerated() {
            guard let binding = parameter.bindingID, binding.kind == .gpr,
                  case let .gpr(register, width) = parameter.abiLocation,
                  binding.value == register, parameter.richLocation == nil,
                  parameter.sourcePosition == ordinal, demands[0]?[register] == width,
                  let type = Ordinary.CType.named(parameter.type), type.width == width,
                  !type.pointer, Ordinary.identifier(parameter.name), formalRegisters[parameter.name] == nil else {
                throw Ordinary.Failure.invalidContract("original historical typed formal contradicts literal entry demand")
            }
            formals.append(.init(name: parameter.name, type: type)); formalRegisters[parameter.name] = register
        }
        guard Set(formalRegisters.values) == Set(demands[0, default: [:]].keys),
              fixture.legacy.parameters == parameters, fixture.document.parameters == parameters,
              fixture.function.instructions.count == fixture.rows.count,
              zip(fixture.function.instructions, fixture.rows).allSatisfy({ $0.0.source.address == $0.1.address && $0.0.source.byteText == $0.1.bytes }),
              let terminal = fixture.function.instructions.last,
              case .returnValue(.some(.unknown("unresolved_return_contract"))) = terminal.operation,
              source.returns == [fixture.rows.count - 1] else {
            throw Ordinary.Failure.invalidContract("historical formal/source/terminal authority changed")
        }
        let signatures = fixture.legacy.lines.filter { $0.kind == .signature }
        let terminals = fixture.legacy.lines(sourcedAt: fixture.rows.last!.address)
        guard signatures.count == 1, terminals.count == 1,
              Set(fixture.document.lines.compactMap(\.sourceAddress)).isSubset(of: Set(fixture.rows.map(\.address))) else {
            throw Ordinary.Failure.invalidContract("missing original envelope or foreign candidate source row")
        }
        let manifest = NoCall.FrozenManifest(signature: signatures[0].text, formals: formals,
            sourceAddresses: fixture.rows.map(\.address), terminalRow: fixture.rows.count - 1,
            terminalPayload: terminals[0].text.trimmingCharacters(in: .whitespaces), terminal: .unavailableReturnContract,
            labelAddresses: Set(source.blocks.map { fixture.rows[$0.rows.lowerBound].address }),
            memoryEffects: inventory.memoryEffects)
        let program = try NoCall.program(lines: Ordinary.lines(fixture.document), manifest: manifest)
        let anchors = try NativeAnchors.make(candidate: program, inventory: inventory)
        let topology = try NativeLedger.analyzeNativeScalar(anchors)
        try topology.requireCompleteTopology()
        var definitions: [Ordinary.Span: HistoricalDefinition] = [:], copies: Set<Ordinary.Span> = []
        for (pc, operation) in anchors.operations {
            switch operation.kind {
            case .scalarDefinition, .load, .writeback:
                guard case let .assign(left, right) = program.code[pc].node,
                      left.count == 1, right.count == 1, case let .name(name) = left[0].node,
                      let symbol = program.symbols[name], !symbol.external, !symbol.type.pointer, symbol.type.unsigned else {
                    throw Ordinary.Failure.invalidContract("historical source definition has no unsigned actual scalar commit")
                }
                let access = accesses[operation.row]
                let ordinal = operation.kind == .writeback ? access.writes.count - 1 : operation.kind == .load ? operation.ordinal : 0
                guard access.writes.indices.contains(ordinal) else { throw Ordinary.Failure.invalidContract("original destination slot missing") }
                let width = access.writes[ordinal].width
                let narrowLoad = operation.kind == .load && width == 32 && [8, 16].contains(symbol.type.width)
                    && inventory.memoryEffects[operation.row]?[operation.ordinal].bytes == symbol.type.width / 8
                guard symbol.type.width == width || narrowLoad, definitions[left[0].span] == nil else {
                    throw Ordinary.Failure.invalidContract("historical destination representation loses original committed bits")
                }
                definitions[left[0].span] = .init(slot: .init(row: operation.row, ordinal: operation.ordinal),
                    architecturalOrdinal: ordinal, width: width, name: name, span: left[0].span, kind: operation.kind)
            case .condition, .store, .terminal: break
            }
        }
        for pc in anchors.administrativeCopies {
            guard case let .assign(left, _) = program.code[pc].node, left.count == 1 else {
                throw Ordinary.Failure.invalidContract("missing edge-owned administrative copy")
            }
            copies.insert(left[0].span)
        }
        let prepared = HistoricalNativePrepared(program: program, manifest: manifest, inventory: inventory,
            anchors: anchors, topology: topology,
            byteMap: try NativeOwnership.historicalByteMapProgram(source: historical, candidate: program),
            definitions: definitions, copies: copies, formals: formalRegisters)
        try bindHistoricalDefinitionUses(prepared, accesses: accesses)
        return prepared
    }
    private func runHistoricalNative(_ prepared: HistoricalNativePrepared, physical: [Int: UInt64],
        memory: [UInt64: UInt8], model: HistoricalMemoryModel, label: String) throws -> HistoricalNativeResult {
        guard Set(physical.keys) == Set(prepared.formals.values) else {
            throw Ordinary.Failure.invalidContract("historical scenario does not supply exactly the original external inputs")
        }
        let inputs = Dictionary(uniqueKeysWithValues: prepared.manifest.formals.map { formal in
            (formal.name, Ordinary.Value(physical[prepared.formals[formal.name]!]!, formal.type))
        })
        let input = try NoCall.scenario(name: model.label(label), inputs: inputs, memory: memory, manifest: prepared.manifest)
        let raw: Ordinary.Result
        switch model {
        case .strictOrdinaryC:
            raw = try Ordinary.Machine(program: prepared.program, scenario: input).run()
        case .retainedHalfwordByteMap64:
            // Exact original scenario selection happened before execution. No
            // refusal fallback, inferred memory, or shared-default relaxation.
            raw = try Ordinary.Machine(historicalByteMap: prepared.byteMap, scenario: input).run()
        }
        try NoCall.requireTerminal(raw, manifest: prepared.manifest)
        var events: [ScalarTextMachine.Event] = [], writes: [HistoricalSlot: [Ordinary.Value]] = [:], loaded: [Ordinary.Value] = []
        for event in raw.events {
            switch event {
            case let .load(_, _, address, bytes, value): events.append(.init(kind: .load, address: address, bytes: bytes, value: value))
            case let .store(_, _, address, bytes, value): events.append(.init(kind: .store, address: address, bytes: bytes, value: value))
            case .call: throw Ordinary.Failure.invalidContract("historical no-call candidate invented a call")
            }
        }
        for commit in raw.commits {
            if let definition = prepared.definitions[commit.span] {
                guard commit.sourceRow == definition.slot.row, commit.name == definition.name,
                      commit.value.type.unsigned, commit.value.type.width <= definition.width else {
                    throw Ordinary.Failure.invalidContract("actual historical commit lost its independent source destination slot")
                }
                writes[definition.slot, default: []].append(commit.value)
                if definition.kind == .load,
                   ["ldrb", "ldurb", "ldrh", "ldurh"].contains(prepared.inventory.source.rows[definition.slot.row].mnemonic) {
                    loaded.append(commit.value)
                }
            } else if !prepared.copies.contains(commit.span) {
                throw Ordinary.Failure.invalidContract("actual historical commit is neither an original slot nor a certified edge copy")
            }
        }
        return .init(raw: raw, memory: raw.memory, events: events, writes: writes, loaded: loaded)
    }
}


extension DecodedScalarCFGTests {
    private enum HistoricalOrigin: Hashable { case input(Int), definition(Int, Int) }
    /// Necessary may-origin check, not a path-correlated equivalence proof.
    /// Unioned reaching sets do not preserve predecessor or operand correlation.
    /// The independent complete slot/effect/edge trace below supplies evidence
    /// for the exact original scenarios; this check alone cannot retire any
    /// writer-time, wrong-arm, operand-role or coalescing mutation obligation.
    /// Candidate spelling is never decoded as a register.
    private func bindHistoricalDefinitionUses(_ p: HistoricalNativePrepared,
        accesses: [OriginalAccess.Access]) throws {
        typealias Origins = Set<HistoricalOrigin>
        let source = p.inventory.source
        func joined<Key: Hashable>(_ states: [[Key: Origins]]) -> [Key: Origins] {
            var result: [Key: Origins] = [:]
            for state in states { for (key, origins) in state { result[key, default: []].formUnion(origins) } }
            return result
        }
        var predecessors: [Int: [Int]] = [:]
        for block in source.blocks { for next in block.successors { predecessors[next, default: []].append(block.index) } }
        let entry: [Int: Origins] = Dictionary(uniqueKeysWithValues: p.formals.values.map { ($0, [.input($0)]) })
        var exits: [Int: [Int: Origins]] = [:], sourceBefore: [Int: [Int: Origins]] = [:], changed = true
        while changed {
            changed = false
            for block in source.blocks where p.inventory.reachableBlocks.contains(block.index) {
                var state = joined(predecessors[block.index, default: []].compactMap { exits[$0] } + (block.index == 0 ? [entry] : []))
                for row in block.rows {
                    sourceBefore[row] = state
                    for (ordinal, write) in accesses[row].writes.enumerated() { state[write.index] = [.definition(row, ordinal)] }
                }
                if exits[block.index] != state { exits[block.index] = state; changed = true }
            }
        }
        func names(_ e: Ordinary.Expression) -> Set<String> {
            switch e.node {
            case let .name(name): return [name]
            case .literal: return []
            case let .cast(_, child), let .unary(_, child), let .load(_, child), let .field(child, _): return names(child)
            case let .binary(_, a, b): return names(a).union(names(b))
            case let .select(c, a, b): return names(c).union(names(a)).union(names(b))
            case let .helper(_, arguments): return arguments.reduce(into: Set<String>()) { $0.formUnion(names($1)) }
            case let .update(name, _, _): return [name]
            }
        }
        func origins(_ expressions: [Ordinary.Expression], _ state: [String: Origins]) -> Origins {
            expressions.reduce(into: Origins()) { result, expression in
                for name in names(expression) { result.formUnion(state[name, default: []]) }
            }
        }
        let code = p.program.code
        func successors(_ pc: Int) -> [Int] {
            switch code[pc].node {
            case let .branch(_, yes, no): return [yes, no]
            case let .jump(next): return [next]
            case .returned, .unavailableReturn: return []
            default: return pc + 1 < code.count ? [pc + 1] : []
            }
        }
        var incoming: [Int: [String: Origins]] = [0: Dictionary(uniqueKeysWithValues: p.formals.map { ($0.key, [.input($0.value)]) })]
        var outgoing: [Int: [String: Origins]] = [:], work = [0]
        while let pc = work.popLast() {
            guard code.indices.contains(pc), var state = incoming[pc] else { throw Ordinary.Failure.invalidContract("historical provenance leaves actual CFG") }
            switch code[pc].node {
            case let .declaration(name, initializer):
                guard initializer == nil else { throw Ordinary.Failure.invalidContract("initialized historical local is not an original source slot") }
                state.removeValue(forKey: name)
            case let .assign(left, right):
                guard left.count == 1, right.count == 1 else { throw Ordinary.Failure.invalidContract("historical assignment is not scalar") }
                if case let .name(name) = left[0].node {
                    if let definition = p.definitions[left[0].span] {
                        state[name] = [.definition(definition.slot.row, definition.architecturalOrdinal)]
                    } else if p.copies.contains(left[0].span) {
                        state[name] = origins(right, state)
                    } else { throw Ordinary.Failure.invalidContract("historical provenance found an unowned definition") }
                }
            default: break
            }
            if outgoing[pc] == state { continue }
            outgoing[pc] = state
            for next in successors(pc) {
                let merged = joined([incoming[next, default: [:]], state])
                if incoming[next] != merged { incoming[next] = merged; work.append(next) }
            }
        }
        for (pc, operation) in p.anchors.operations {
            guard let candidateState = incoming[pc], let originalState = sourceBefore[operation.row] else {
                throw Ordinary.Failure.invalidContract("source slot has no established actual/original entry state")
            }
            var wanted: Origins = [], actual: Origins = []
            switch operation.kind {
            case .terminal: continue
            case .condition:
                guard case let .branch(expression, _, _) = code[pc].node else { throw Ordinary.Failure.invalidContract("missing actual historical condition") }
                actual = origins([expression], candidateState)
                let row = operation.row
                if source.rows[row].mnemonic.hasPrefix("b.") {
                    guard let writer = p.inventory.flagWriters[row], let writerState = sourceBefore[writer] else {
                        throw Ordinary.Failure.invalidContract("historical predicate has no unique original NZCV writer")
                    }
                    if source.rows[writer].mnemonic == "subs" { wanted = [.definition(writer, 0)] }
                    else { for read in accesses[writer].reads { wanted.formUnion(writerState[read.index, default: []]) } }
                } else { for read in accesses[row].reads { wanted.formUnion(originalState[read.index, default: []]) } }
            case .load, .store, .scalarDefinition, .writeback:
                guard case let .assign(left, right) = code[pc].node else { throw Ordinary.Failure.invalidContract("missing historical assignment") }
                actual = origins(right + (operation.kind == .store ? left : []), candidateState)
                if operation.kind == .writeback {
                    let memories = source.rows[operation.row].structuredOperands!.operands.compactMap { operand -> InstructionOperands.Memory? in
                        if case let .memory(value) = operand { return value }; return nil
                    }
                    guard memories.count == 1 else { throw Ordinary.Failure.invalidContract("ambiguous original writeback base") }
                    wanted = originalState[memories[0].base.index, default: []]
                } else {
                    for read in accesses[operation.row].reads { wanted.formUnion(originalState[read.index, default: []]) }
                }
            }
            guard actual == wanted else {
                throw Ordinary.Failure.invalidContract("historical row \(operation.row) slot \(operation.ordinal) has incompatible original may-reaching definitions")
            }
        }
        // Every omitted CMP has an independently bound current consumer. Every
        // omitted B is accounted by complete routes. No dead effect gets credit
        // merely because its source address is absent from the candidate text.
        let writers = Set(p.inventory.flagWriters.values)
        for row in source.rows.indices {
            if !p.inventory.reachableRows.contains(row) {
                guard source.rows[row].mnemonic == "nop" else { throw Ordinary.Failure.invalidContract("unreachable historical effect needs its own preservation proof") }
            } else if source.rows[row].mnemonic == "cmp", !writers.contains(row) {
                throw Ordinary.Failure.invalidContract("omitted historical CMP has no independently bound writer-owned predicate")
            }
        }
    }
}


extension DecodedScalarCFGTests {
    private struct HistoricalTrace {
        var memory: [UInt64: UInt8]
        var events: [ScalarTextMachine.Event] = []
        var writes: [HistoricalSlot: [UInt64]] = [:]
        var branches: [RegionalCallOracle.Branch] = []
        var visits: [Int: Int] = [:]
        var returned = false
    }
    /// Supplementary literal-row trace, never a replacement for either original
    /// reference algorithm above. It supplies complete branch/slot observations
    /// the historical formula oracles did not record. It receives no candidate.
    /// Its only callers supply the seven factory-pinned historical inventories;
    /// these cases do not define a general ARM instruction interpreter.
    private func historicalTrace(_ inventory: NativeOwnership.Inventory, physical: [Int: UInt64],
        memory: [UInt64: UInt8]) throws -> HistoricalTrace {
        let source = inventory.source
        var registers = physical, result = HistoricalTrace(memory: memory)
        var comparison: (UInt64, UInt64, Int)?, pc = 0, fuel = 100_000
        func register(_ text: String) throws -> (index: Int, width: Int) {
            guard let prefix = text.first, prefix == "w" || prefix == "x",
                  let index = Int(text.dropFirst()), (0...30).contains(index) else {
                throw Ordinary.Failure.invalidContract("unsupported immutable historical register literal")
            }
            return (index, prefix == "w" ? 32 : 64)
        }
        func bits(_ text: String) throws -> UInt64 {
            if text.hasPrefix("#") {
                let literal = String(text.dropFirst()), negative = literal.hasPrefix("-")
                let digits = negative ? String(literal.dropFirst()) : literal
                let number = digits.hasPrefix("0x") ? UInt64(digits.dropFirst(2), radix: 16) : UInt64(digits)
                guard let number else { throw Ordinary.Failure.invalidContract("unsupported immutable immediate") }
                return negative ? 0 &- number : number
            }
            let r = try register(text)
            guard let value = registers[r.index] else { throw Ordinary.Failure.uninitializedRead("original register \(r.index)") }
            return r.width == 32 ? value & 0xffff_ffff : value
        }
        func signed(_ bits: UInt64, width: Int) -> Int64 {
            width == 32 ? Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: bits))) : Int64(bitPattern: bits)
        }
        func assign(_ row: Int, _ ordinal: Int, _ index: Int, _ width: Int, _ value: UInt64) {
            let value = width == 32 ? value & 0xffff_ffff : value
            registers[index] = value
            result.writes[.init(row: row, ordinal: ordinal), default: []].append(value)
        }
        func load(_ row: Int, _ ordinal: Int, _ address: UInt64, _ bytes: Int) throws -> UInt64 {
            var value: UInt64 = 0
            for offset in 0..<bytes {
                guard let byte = result.memory[address &+ UInt64(offset)] else {
                    throw Ordinary.Failure.uninitializedRead("original historical byte at \(address &+ UInt64(offset))")
                }
                value |= UInt64(byte) << (offset * 8)
            }
            result.events.append(.init(kind: .load, address: address, bytes: bytes, value: value))
            return value
        }
        func store(_ address: UInt64, _ bytes: Int, _ value: UInt64) {
            let value = bytes == 8 ? value : value & ((UInt64(1) << (bytes * 8)) - 1)
            result.events.append(.init(kind: .store, address: address, bytes: bytes, value: value))
            for offset in 0..<bytes { result.memory[address &+ UInt64(offset)] = UInt8(truncatingIfNeeded: value >> (offset * 8)) }
        }
        while source.rows.indices.contains(pc), fuel > 0 {
            fuel -= 1; result.visits[pc, default: 0] += 1
            let row = source.rows[pc], mnemonic = row.mnemonic
            let operands = row.operands.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            var next = pc + 1
            if let effects = inventory.memoryEffects[pc] {
                let envelope = row.structuredOperands!
                let memories = envelope.operands.compactMap { operand -> InstructionOperands.Memory? in
                    if case let .memory(value) = operand { return value }; return nil
                }
                let data = envelope.operands.compactMap { operand -> InstructionOperands.Register? in
                    if case let .register(value) = operand { return value }; return nil
                }
                guard memories.count == 1, data.count == effects.count, let oldBase = registers[memories[0].base.index] else {
                    throw Ordinary.Failure.invalidContract("historical memory source operand shape changed")
                }
                let m = memories[0]
                guard m.indexing != .preIndex else { throw Ordinary.Failure.invalidContract("historical pre-index is outside exact streams") }
                var address = oldBase
                if let index = m.index {
                    guard let value = registers[index.index] else { throw Ordinary.Failure.uninitializedRead("original index register") }
                    var offset = index.width == 32 ? value & 0xffff_ffff : value
                    if let modifier = m.modifier {
                        guard modifier.kind == .uxtw || modifier.kind == .lsl,
                              let shift = modifier.amount, (0..<64).contains(shift) else {
                            throw Ordinary.Failure.invalidContract("historical address modifier outside literal slice")
                        }
                        offset <<= shift
                    }
                    address &+= offset
                }
                if m.indexing == .offset { address &+= UInt64(bitPattern: m.displacement) }
                for (ordinal, effect) in effects.enumerated() {
                    let location = address &+ UInt64(ordinal * effect.bytes)
                    if effect.loading {
                        let value = try load(pc, ordinal, location, effect.bytes)
                        assign(pc, ordinal, data[ordinal].index, data[ordinal].width, value)
                    } else {
                        guard let value = registers[data[ordinal].index] else { throw Ordinary.Failure.uninitializedRead("original store data") }
                        store(location, effect.bytes, value)
                    }
                }
                if m.writeback { assign(pc, effects.count, m.base.index, 64, oldBase &+ UInt64(bitPattern: m.displacement)) }
            } else if mnemonic == "ret" {
                result.returned = true; return result
            } else if NativeOwnership.conditional(mnemonic) || mnemonic == "b" {
                guard let target = source.branchTargets[pc] else { throw Ordinary.Failure.invalidContract("missing original branch target") }
                let taken: Bool
                if mnemonic == "b" { taken = true }
                else if mnemonic == "cbz" || mnemonic == "cbnz" {
                    let zero = try bits(operands[0]) == 0; taken = mnemonic == "cbz" ? zero : !zero
                } else {
                    guard let (left, right, width) = comparison else { throw Ordinary.Failure.invalidContract("uninitialized original NZCV") }
                    switch mnemonic {
                    case "b.eq": taken = left == right
                    case "b.ne": taken = left != right
                    case "b.hs": taken = left >= right
                    case "b.lo": taken = left < right
                    case "b.lt": taken = signed(left, width: width) < signed(right, width: width)
                    case "b.gt": taken = signed(left, width: width) > signed(right, width: width)
                    default: throw Ordinary.Failure.invalidContract("unsupported immutable branch condition")
                    }
                }
                result.branches.append(.init(row: pc, taken: taken, target: source.rows[target].address))
                if taken { next = target }
            } else if mnemonic == "cmp" {
                guard operands.count == 2 else { throw Ordinary.Failure.invalidContract("original CMP shape") }
                let r = try register(operands[0]), left = try bits(operands[0]), right = try bits(operands[1])
                comparison = (left, r.width == 32 ? right & 0xffff_ffff : right, r.width)
            } else if mnemonic == "nop" {
                // The exact fixture inventory has no effect to execute here.
            } else {
                guard operands.count >= 2 else { throw Ordinary.Failure.invalidContract("original scalar shape") }
                let target = try register(operands[0]), left = try bits(operands[1]), value: UInt64
                switch mnemonic {
                case "mov": value = left
                case "sxtw": value = UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: left))))
                case "add": value = left &+ (try bits(operands[2]))
                case "sub", "subs": value = left &- (try bits(operands[2]))
                case "lsl": value = left << (try bits(operands[2]))
                case "lsr": value = left >> (try bits(operands[2]))
                default: throw Ordinary.Failure.invalidContract("unsupported immutable scalar operation")
                }
                assign(pc, 0, target.index, target.width, value)
                if mnemonic == "subs" { comparison = (registers[target.index]!, 0, target.width) }
            }
            pc = next
        }
        throw Ordinary.Failure.invalidContract(fuel == 0 ? "original historical source trace exhausted fuel" : "original historical source fell out")
    }
    private func compareHistoricalTrace(_ p: HistoricalNativePrepared, actual: HistoricalNativeResult,
        reference: HistoricalTrace, label: String) throws {
        guard reference.returned else { throw Ordinary.Failure.invalidContract("original historical trace did not return") }
        XCTAssertEqual(actual.events, reference.events, "independent literal-row effects: " + label)
        XCTAssertEqual(actual.memory, reference.memory, "independent literal-row memory: " + label)
        XCTAssertEqual(actual.writes.mapValues { $0.map(\.bits) }, reference.writes,
                       "every original definition/writeback slot, excluding edge transport: " + label)
        _ = try NativeLedger.observe(p.topology, candidate: p.program, actual: actual.raw,
            referenceBranches: reference.branches, referenceRowVisits: reference.visits,
            referenceReturned: reference.returned, name: label)
    }
}


extension DecodedScalarCFGTests {
    private func requireHistoricalLiteralAgreement(_ trace: HistoricalTrace,
        expected: ScalarTextMachine.Result, label: String) throws {
        guard trace.returned, expected.returned, trace.events == expected.events, trace.memory == expected.memory,
              expected.returnMarker == "unresolved_return_contract", expected.returnValue == nil else {
            throw Ordinary.Failure.invalidContract("supplementary historical trace contradicts unchanged literal algorithm: " + label)
        }
    }
    /// Independent refusal control on the identical actual candidate and normal
    /// inputs. This is not a numerical kill or a fallback to the ByteMap64 model.
    private func assertHistoricalStrictSpanBoundary(_ p: HistoricalNativePrepared, physical: [Int: UInt64],
        memory: [UInt64: UInt8], reference: HistoricalTrace, label: String) throws {
        let crosses = reference.events.contains { $0.bytes > 1 && $0.address > UInt64.max - UInt64($0.bytes - 1) }
        guard crosses else { return }
        let inputs = Dictionary(uniqueKeysWithValues: p.manifest.formals.map { formal in
            (formal.name, Ordinary.Value(physical[p.formals[formal.name]!]!, formal.type))
        })
        let input = try NoCall.scenario(name: label, inputs: inputs, memory: memory, manifest: p.manifest)
        XCTAssertThrowsError(try Ordinary.Machine(program: p.program, scenario: input).run(),
                             "strict ordinary-C must refuse the same cross-end access; abstract historical ByteMap64 success is separate") { error in
            guard case let Ordinary.Failure.undefinedC(reason) = error, reason == "memory span overflows address space" else {
                XCTFail("wrong strict-default boundary outcome: \(error)"); return
            }
        }
    }
}
// NEW RECONSTRUCTION AFTER WORKSPACE LOSS / SOURCE ONLY / NOT COMPILED OR RUN.
// Reconstructs only the already source-reviewed retained 4e84/29a70 non-width
// obligations. This is new source, not a claim of recovered prior-draft bytes.
// The original helper is preserved verbatim in evidence; no appended selector is added.
// Width/sign/full64-cell controls remain OPEN and are not generated here.
// Excluded planar/null paths belong to the separate exact-fallback layer.
extension DecodedScalarCFGTests {
    private struct HistoricalNonWidthMutation {
        let name: String
        let row: Int
        let ordinal: Int
        let program: Ordinary.Program
        let anchors: NativeAnchors.Certificate
        // Nil only for the exact row13-store / row14-load+writeback permutation.
        // That deliberately violates source order; its bounded permutation is
        // proved separately, never accepted by weakening NativeLedger.
        let topology: NativeLedger.Report?
        let sourceSpan: Ordinary.Span
        let changedRole: String
    }
    private struct HistoricalNonWidthAssignment {
        let pc: Int
        let left: Ordinary.Expression
        let right: Ordinary.Expression
    }
    private func nonWidthUnique<T>(_ values: [T], _ identity: String) throws -> T {
        guard values.count == 1 else {
            throw Ordinary.Failure.invalidContract("\(identity): expected one original-slot AST binding, found \(values.count)")
        }
        return values[0]
    }
    private func nonWidthStripped(_ e: Ordinary.Expression) -> Ordinary.Expression {
        if case let .cast(_, child) = e.node { return nonWidthStripped(child) }
        return e
    }
    private func nonWidthDescendants(_ e: Ordinary.Expression) -> [Ordinary.Expression] {
        switch e.node {
        case let .cast(_, child), let .unary(_, child), let .load(_, child), let .field(child, _):
            return [e] + nonWidthDescendants(child)
        case let .binary(_, a, b): return [e] + nonWidthDescendants(a) + nonWidthDescendants(b)
        case let .select(c, a, b): return [e] + nonWidthDescendants(c) + nonWidthDescendants(a) + nonWidthDescendants(b)
        case let .helper(_, arguments): return [e] + arguments.flatMap(nonWidthDescendants)
        default: return [e]
        }
    }
    private func nonWidthName(_ e: Ordinary.Expression) throws -> String {
        guard case let .name(name) = nonWidthStripped(e).node else {
            throw Ordinary.Failure.invalidContract("non-width operand role is not one parsed name under scalar casts")
        }
        return name
    }
    private func nonWidthLiteral(_ e: Ordinary.Expression, equals bits: UInt64) -> Bool {
        if case let .literal(value) = nonWidthStripped(e).node { return value.bits == bits }
        return false
    }
    private func nonWidthAssignment(_ p: HistoricalNativePrepared, row: Int, ordinal: Int,
        kind: NativeAnchors.Kind, mnemonic: String, operands: String) throws -> HistoricalNonWidthAssignment {
        let rows = p.inventory.source.rows
        guard rows.indices.contains(row), rows[row].mnemonic == mnemonic, rows[row].operands == operands else {
            throw Ordinary.Failure.invalidContract("non-width mutation lost exact literal source row \(row): \(mnemonic) \(operands)")
        }
        let pc = try nonWidthUnique(p.anchors.operations.compactMap { pc, operation in
            operation.row == row && operation.ordinal == ordinal && operation.kind == kind ? pc : nil
        }, "non-width original row \(row) effect \(ordinal)")
        guard case let .assign(left, right) = p.program.code[pc].node, left.count == 1, right.count == 1,
              p.definitions[left[0].span]?.slot == HistoricalSlot(row: row, ordinal: ordinal),
              try p.program.row(at: left[0].span) == row, try p.program.row(at: right[0].span) == row else {
            throw Ordinary.Failure.invalidContract("non-width original slot has no unique parsed scalar commit")
        }
        return .init(pc: pc, left: left[0], right: right[0])
    }
    private func nonWidthText(_ program: Ordinary.Program, _ span: Ordinary.Span) throws -> String {
        guard span.first < span.last, program.tokens.indices.contains(span.first),
              program.tokens.indices.contains(span.last - 1) else {
            throw Ordinary.Failure.invalidContract("invalid bound non-width expression span")
        }
        let first = program.tokens[span.first], last = program.tokens[span.last - 1]
        let bytes = Array(program.lines.map(\.text).joined(separator: "\n").utf8)
        return String(decoding: bytes[first.byteOffset..<(last.byteOffset + last.text.utf8.count)], as: UTF8.self)
    }
    /// Only a pre-bound pure operand span can be replaced. In particular this
    /// function cannot select or change a memory type, declaration, manifest,
    /// load/store node, statement ordering, source tag, or terminal payload.
    private func nonWidthReplacing(_ p: HistoricalNativePrepared, operand: Ordinary.Expression,
        replacement: String, row: Int, ordinal: Int, name: String, role: String) throws -> HistoricalNonWidthMutation {
        guard !nonWidthDescendants(operand).contains(where: { e in
            switch e.node { case .load, .field, .helper, .update: return true; default: return false }
        }), try p.program.row(at: operand.span) == row, !replacement.contains("\n") else {
            throw Ordinary.Failure.invalidContract("non-width edit is not one original pure scalar operand")
        }
        _ = try nonWidthText(p.program, operand.span)
        let first = p.program.tokens[operand.span.first], last = p.program.tokens[operand.span.last - 1]
        let line = first.line - 1
        guard first.line == last.line, p.program.lines.indices.contains(line),
              p.program.lines[line].envelope == .body, row != p.manifest.terminalRow,
              p.program.lines[line].source == p.manifest.sourceAddresses[row] else {
            throw Ordinary.Failure.invalidContract("non-width operand crosses an original body/source boundary")
        }
        let offset = p.program.lines.prefix(line).reduce(0) { $0 + $1.text.utf8.count + 1 }
        var bytes = Array(p.program.lines[line].text.utf8)
        bytes.replaceSubrange((first.byteOffset - offset)..<(last.byteOffset - offset + last.text.utf8.count),
                              with: replacement.utf8)
        var lines = p.program.lines
        lines[line] = .init(text: String(decoding: bytes, as: UTF8.self),
                           source: lines[line].source, envelope: lines[line].envelope)
        // Reparse and retype under the IDENTICAL strict memory manifest. There
        // is no AST mutation constructor or alternative memory authorization.
        let candidate = try NoCall.program(lines: lines, manifest: p.manifest)
        guard candidate.symbols.mapValues(\.type) == p.program.symbols.mapValues(\.type),
              candidate.code.count == p.program.code.count,
              candidate.memorySites.count == p.program.memorySites.count,
              Set(candidate.memorySites.values) == Set(p.program.memorySites.values),
              try nonWidthMemoryTypes(candidate) == nonWidthMemoryTypes(p.program) else {
            throw Ordinary.Failure.invalidContract("non-width operand edit changed declarations, effects, or statement cardinality")
        }
        let anchors = try NativeAnchors.make(candidate: candidate, inventory: p.inventory)
        let topology = try NativeLedger.analyzeNativeScalar(anchors)
        guard anchors.operations == p.anchors.operations,
              anchors.administrativeCopies == p.anchors.administrativeCopies else {
            throw Ordinary.Failure.invalidContract("non-width operand edit changed original row/effect/edge ownership")
        }
        return .init(name: name, row: row, ordinal: ordinal, program: candidate,
                     anchors: anchors, topology: topology, sourceSpan: operand.span, changedRole: role)
    }
    private func nonWidthZero(_ p: HistoricalNativePrepared, _ e: Ordinary.Expression) throws -> String {
        guard let type = p.program.expressionTypes[e.span], !type.pointer,
              [32, 64].contains(type.width) else {
            throw Ordinary.Failure.invalidContract("non-width recurrence operand has no unchanged scalar representation")
        }
        return "(\(type.unsigned ? "u" : "")int\(type.width)_t)0"
    }
    /// Bind the second ADD operand by exact source row/slot and parsed role,
    /// never by observed values. Dynamic stride additionally needs the unique
    /// original SXTW definition, not a unioned may-origin claim.
    private func nonWidthStaleAdd(_ p: HistoricalNativePrepared, row: Int, operands: String,
        increment: UInt64?, name: String) throws -> HistoricalNonWidthMutation {
        let site = try nonWidthAssignment(p, row: row, ordinal: 0, kind: .scalarDefinition,
                                          mnemonic: "add", operands: operands)
        guard case let .binary("+", old, step) = nonWidthStripped(site.right).node else {
            throw Ordinary.Failure.invalidContract("non-width source ADD is not one parsed addition")
        }
        _ = try nonWidthName(old)
        if let increment {
            guard nonWidthLiteral(step, equals: increment) else {
                throw Ordinary.Failure.invalidContract("non-width ADD immediate role differs from exact original operand")
            }
        } else {
            let stride = try nonWidthName(step)
            let definitions = p.definitions.values.filter { $0.name == stride }
            guard definitions.count == 1, definitions[0].slot == HistoricalSlot(row: 61, ordinal: 0),
                  definitions[0].width == 64, p.inventory.source.rows[61].mnemonic == "sxtw",
                  p.inventory.source.rows[61].operands == "x10, w9" else {
                throw Ordinary.Failure.invalidContract("dynamic stride is not uniquely the original row61 SXTW definition")
            }
        }
        return try nonWidthReplacing(p, operand: step, replacement: nonWidthZero(p, step), row: row, ordinal: 0,
                                     name: name, role: "ADD increment operand, not destination storage")
    }
    /// The source writer, intervening SUB, and consumer are exact adjacent
    /// original rows. Bind the consumer's one old-count leaf to the SUB's
    /// parsed input, and substitute only the distinct committed SUB output.
    private func nonWidthLateCMP(_ p: HistoricalNativePrepared, writer: Int, subtract: Int,
        consumer: Int, threshold: UInt64) throws -> HistoricalNonWidthMutation {
        let source = p.inventory.source
        guard subtract == writer + 1, consumer == subtract + 1,
              p.inventory.flagWriters[consumer] == writer,
              source.rows[writer].mnemonic == "cmp", source.rows[writer].operands == "w4, #\(threshold)",
              source.blockAtRow[writer] == source.blockAtRow[consumer] else {
            throw Ordinary.Failure.invalidContract("late-CMP mutation lost original writer/SUB/consumer timing")
        }
        let sub = try nonWidthAssignment(p, row: subtract, ordinal: 0, kind: .scalarDefinition,
                                         mnemonic: "sub", operands: "w4, w4, #1")
        guard case let .binary("-", old, one) = nonWidthStripped(sub.right).node,
              nonWidthLiteral(one, equals: 1) else {
            throw Ordinary.Failure.invalidContract("writer-time count has no exact parsed decrement input role")
        }
        let oldName = try nonWidthName(old), newName = try nonWidthName(sub.left)
        let branch = try nonWidthUnique(p.anchors.operations.compactMap { pc, operation in
            operation.row == consumer && operation.ordinal == 0 && operation.kind == .condition ? pc : nil
        }, "original CMP consumer \(consumer)")
        guard sub.pc < branch, case let .branch(predicate, _, _) = p.program.code[branch].node,
              oldName != newName, p.program.symbols[oldName]?.type == .u32,
              p.program.symbols[newName]?.type == .u32 else {
            throw Ordinary.Failure.invalidContract("writer-time count and post-SUB count are not distinct native uint32 definitions")
        }
        let leaves = nonWidthDescendants(predicate).filter { if case .name = $0.node { return true }; return false }
        let leaf = try nonWidthUnique(leaves, "original CMP operand leaf")
        guard try nonWidthName(leaf) == oldName else {
            throw Ordinary.Failure.invalidContract("CMP consumer does not read the exact parsed SUB pre-state operand")
        }
        return try nonWidthReplacing(p, operand: leaf, replacement: newName, row: consumer, ordinal: 0,
            name: "CMP reads post-SUB count", role: "writer-time count operand at original consumer")
    }
    /// Same access width and same memory effect. Only the independently bound
    /// old-base operand is changed to that row's explicit writeback expression.
    private func nonWidthEarlyPostindex(_ p: HistoricalNativePrepared, row: Int, mnemonic: String,
        operands: String, bytes: Int) throws -> HistoricalNonWidthMutation {
        let load = try nonWidthAssignment(p, row: row, ordinal: 0, kind: .load,
                                          mnemonic: mnemonic, operands: operands)
        let writeback = try nonWidthAssignment(p, row: row, ordinal: 1, kind: .writeback,
                                               mnemonic: mnemonic, operands: operands)
        guard case let .load(type, address) = nonWidthStripped(load.right).node,
              type.unsigned, type.width == bytes * 8,
              p.program.memorySites[nonWidthStripped(load.right).span] == Ordinary.SourceSite(row: row, effectOrdinal: 0),
              p.manifest.memoryEffects[row]?.count == 1,
              p.manifest.memoryEffects[row]?[0].bytes == bytes,
              p.manifest.memoryEffects[row]?[0].loading == true,
              case let .binary("+", oldBase, step) = nonWidthStripped(writeback.right).node,
              nonWidthLiteral(step, equals: UInt64(bytes)),
              try nonWidthName(address) == nonWidthName(oldBase),
              p.program.expressionTypes[address.span] == .u64,
              p.program.expressionTypes[writeback.right.span] == .u64 else {
            throw Ordinary.Failure.invalidContract("postindex old-base/load/writeback roles are not uniquely bound at unchanged width")
        }
        return try nonWidthReplacing(p, operand: address, replacement: "(\(try nonWidthText(p.program, writeback.right.span)))",
            row: row, ordinal: 0, name: "postindex load reads advanced base", role: "load address only; exact original access width")
    }
    private func nonWidthCommitted(_ mutation: HistoricalNonWidthMutation, _ result: Ordinary.Result,
        row: Int, ordinal: Int) throws -> [UInt64] {
        let pc = try nonWidthUnique(mutation.anchors.operations.compactMap { pc, operation in
            operation.row == row && operation.ordinal == ordinal &&
                [.scalarDefinition, .load, .writeback].contains(operation.kind) ? pc : nil
        }, "mutant observation row \(row) effect \(ordinal)")
        guard case let .assign(left, _) = mutation.program.code[pc].node, left.count == 1,
              case let .name(name) = left[0].node else {
            throw Ordinary.Failure.invalidContract("mutant numerical observer lost its exact original definition slot")
        }
        return result.commits.filter { $0.span == left[0].span && $0.sourceRow == row && $0.name == name }.map { $0.value.bits }
    }

    private func nonWidthMemoryTypes(_ program: Ordinary.Program) throws -> [Ordinary.SourceSite: Ordinary.CType] {
        var result: [Ordinary.SourceSite: Ordinary.CType] = [:]
        for (span, site) in program.memorySites {
            guard let type = program.expressionTypes[span], result[site] == nil else {
                throw Ordinary.Failure.invalidContract("non-width memory effect has no unique parsed type")
            }
            result[site] = type
        }
        return result
    }

    private func nonWidthWrongPostindex(_ p: HistoricalNativePrepared) throws -> HistoricalNonWidthMutation {
        let load = try nonWidthAssignment(p, row: 12, ordinal: 0, kind: .load,
            mnemonic: "ldrh", operands: "w17, [x12], #2")
        let writeback = try nonWidthAssignment(p, row: 12, ordinal: 1, kind: .writeback,
            mnemonic: "ldrh", operands: "w17, [x12], #2")
        guard case let .load(type, address) = nonWidthStripped(load.right).node,
              type == Ordinary.CType(16, true),
              case let .binary("+", oldBase, step) = nonWidthStripped(writeback.right).node,
              nonWidthLiteral(step, equals: 2),
              try nonWidthName(address) == nonWidthName(oldBase),
              p.program.expressionTypes[address.span] == .u64,
              p.program.expressionTypes[writeback.right.span] == .u64,
              let stepType = p.program.expressionTypes[step.span], !stepType.pointer,
              [32, 64].contains(stepType.width) else {
            throw Ordinary.Failure.invalidContract("wrong-increment control lost exact old-base, +2, or uint16 load roles")
        }
        // Original legacy mutation added one to the committed pointer result.
        // Replacing only the independently bound +2 operand by same-type +3 is
        // algebraically identical for the unchanged unsigned64 pointer add.
        let three = "(\(stepType.unsigned ? "u" : "")int\(stepType.width)_t)3"
        return try nonWidthReplacing(p, operand: step, replacement: three, row: 12, ordinal: 1,
            name: "wrong post-index pointer increment", role: "post-index +2 operand becomes same-type +3")
    }

    /// Lexical/CFG identity for a bounded reparse comparison. No candidate
    /// expressions are evaluated and no values are derived from this key.
    private func nonWidthInstructionKey(_ program: Ordinary.Program, pc: Int) throws -> String {
        let instruction = program.code[pc]
        let routing: String
        let payloadSpan: Ordinary.Span?
        switch instruction.node {
        case let .branch(predicate, yes, no):
            routing = "branch:\(yes):\(no)"; payloadSpan = predicate.span
        case let .jump(target): routing = "jump:\(target)"; payloadSpan = nil
        case .assign: routing = "assign"; payloadSpan = instruction.span
        case .nop: routing = "nop"; payloadSpan = nil
        case let .declaration(name, initial):
            guard initial == nil else { throw Ordinary.Failure.invalidContract("alias control has an initialized declaration") }
            routing = "declaration:\(name)"; payloadSpan = nil
        case .unavailableReturn: routing = "unavailableReturn"; payloadSpan = instruction.span
        default: throw Ordinary.Failure.invalidContract("alias-order control found an unsupported instruction kind")
        }
        // Compiler scaffolding spans can enclose a complete loop body. Compare
        // their routing, not that body's intentionally permuted token order.
        let tokens = payloadSpan.map { Array(program.tokens[$0.first..<$0.last]) } ?? []
        let payload = tokens.map(\.text).joined(separator: " ")
        let sources = tokens.map { String(describing: $0.source) }.joined(separator: ",")
        return "\(routing)|\(instruction.scopes)|\(sources)|\(payload)"
    }

    private func nonWidthAliasOrder(_ p: HistoricalNativePrepared) throws -> HistoricalNonWidthMutation {
        guard p.inventory.source.rows.first?.address == 0x29a70,
              p.inventory.source.rows[13].mnemonic == "strh",
              p.inventory.source.rows[13].operands == "w17, [x15]" else {
            throw Ordinary.Failure.invalidContract("alias-order control is limited to retained planesToBGR16 row13/14")
        }
        let firstLoad = try nonWidthAssignment(p, row: 12, ordinal: 0, kind: .load,
            mnemonic: "ldrh", operands: "w17, [x12], #2")
        let nextLoad = try nonWidthAssignment(p, row: 14, ordinal: 0, kind: .load,
            mnemonic: "ldrh", operands: "w17, [x13], #2")
        let writeback = try nonWidthAssignment(p, row: 14, ordinal: 1, kind: .writeback,
            mnemonic: "ldrh", operands: "w17, [x13], #2")
        let storePC = try nonWidthUnique(p.anchors.operations.compactMap { pc, operation in
            operation.row == 13 && operation.ordinal == 0 && operation.kind == .store ? pc : nil
        }, "original row13 halfword store")
        guard case let .assign(left, right) = p.program.code[storePC].node,
              left.count == 1, right.count == 1,
              case let .load(storeType, _) = left[0].node, storeType == Ordinary.CType(16, true),
              p.program.memorySites[left[0].span] == Ordinary.SourceSite(row: 13, effectOrdinal: 0),
              try nonWidthName(right[0]) == nonWidthName(firstLoad.left),
              case let .load(loadType, oldBase) = nonWidthStripped(nextLoad.right).node,
              loadType == storeType,
              case let .binary("+", sameBase, step) = nonWidthStripped(writeback.right).node,
              try nonWidthName(oldBase) == nonWidthName(sameBase), nonWidthLiteral(step, equals: 2),
              nextLoad.pc == storePC + 1, writeback.pc == nextLoad.pc + 1,
              p.program.code[storePC].scopes == p.program.code[nextLoad.pc].scopes,
              p.program.code[storePC].scopes == p.program.code[writeback.pc].scopes else {
            throw Ordinary.Failure.invalidContract("alias-order control lost exact adjacent store/load/writeback AST roles")
        }
        let pcs = [storePC, nextLoad.pc, writeback.pc]
        for instruction in p.program.code {
            switch instruction.node {
            case let .branch(_, yes, no):
                guard !pcs.contains(yes), !pcs.contains(no) else {
                    throw Ordinary.Failure.invalidContract("alias permutation intersects an incoming branch target")
                }
            case let .jump(target):
                guard !pcs.contains(target) else {
                    throw Ordinary.Failure.invalidContract("alias permutation intersects an incoming jump target")
                }
            default: break
            }
        }
        let lineIndexes = try pcs.map { pc -> Int in
            let span = p.program.code[pc].span
            let first = p.program.tokens[span.first], last = p.program.tokens[span.last - 1]
            guard first.line == last.line else {
                throw Ordinary.Failure.invalidContract("alias-order assignment is not on one original source line")
            }
            let line = first.line - 1
            guard p.program.lines[line].envelope == .body else {
                throw Ordinary.Failure.invalidContract("alias-order edit crosses an envelope")
            }
            return line
        }
        guard lineIndexes == Array(lineIndexes[0]...lineIndexes[0] + 2),
              p.program.lines[lineIndexes[0]].source == p.manifest.sourceAddresses[13],
              p.program.lines[lineIndexes[1]].source == p.manifest.sourceAddresses[14],
              p.program.lines[lineIndexes[2]].source == p.manifest.sourceAddresses[14] else {
            throw Ordinary.Failure.invalidContract("alias-order edit is not exactly three adjacent original tagged lines")
        }
        // Reorder these three unchanged tagged lines only: [store, load, wb]
        // becomes [load, wb, store]. No text, source tag, memory type or operand
        // is changed, and every other line remains byte-for-byte untouched.
        var lines = p.program.lines
        let oldLines = lineIndexes.map { lines[$0] }
        for (offset, old) in [1, 2, 0].enumerated() { lines[lineIndexes[offset]] = oldLines[old] }
        let candidate = try NoCall.program(lines: lines, manifest: p.manifest)
        let anchors = try NativeAnchors.make(candidate: candidate, inventory: p.inventory)
        guard candidate.symbols.mapValues(\.type) == p.program.symbols.mapValues(\.type),
              candidate.code.count == p.program.code.count,
              candidate.memorySites.count == p.program.memorySites.count,
              try nonWidthMemoryTypes(candidate) == nonWidthMemoryTypes(p.program),
              anchors.administrativeCopies == p.anchors.administrativeCopies else {
            throw Ordinary.Failure.invalidContract("alias-order edit changed types, effects, statements, or edge-copy ownership")
        }
        var permutation = Array(p.program.code.indices)
        permutation.replaceSubrange(storePC...writeback.pc, with: [nextLoad.pc, writeback.pc, storePC])
        for pc in candidate.code.indices {
            guard try nonWidthInstructionKey(candidate, pc: pc) == nonWidthInstructionKey(p.program, pc: permutation[pc]),
                  anchors.operations[pc] == p.anchors.operations[permutation[pc]] else {
                throw Ordinary.Failure.invalidContract("alias candidate differs from the one allowed AST source-slot permutation")
            }
        }
        return .init(name: "store-before-next-load alias order", row: 14, ordinal: 0,
            program: candidate, anchors: anchors, topology: nil, sourceSpan: nextLoad.right.span,
            changedRole: "only row14 load+writeback moves before adjacent row13 store")
    }

    private struct NonWidthAccess: Equatable {
        let loading: Bool
        let site: Ordinary.SourceSite
        let occurrence: Int
        let bytes: Int
    }
    private func nonWidthAccesses(_ result: Ordinary.Result) throws -> [NonWidthAccess] {
        try result.events.map { event in
            switch event {
            case let .load(site, occurrence, _, bytes, _):
                return .init(loading: true, site: site, occurrence: occurrence, bytes: bytes)
            case let .store(site, occurrence, _, bytes, _):
                return .init(loading: false, site: site, occurrence: occurrence, bytes: bytes)
            case .call: throw Ordinary.Failure.invalidContract("non-width control invented a call")
            }
        }
    }

    private func nonWidthSameTransfers(_ left: Ordinary.Result, _ right: Ordinary.Result) -> Bool {
        guard left.transfers.count == right.transfers.count else { return false }
        return zip(left.transfers, right.transfers).allSatisfy {
            $0.0.sourceRow == $0.1.sourceRow && $0.0.taken == $0.1.taken && $0.0.destination == $0.1.destination
        }
    }

    private func assertNativeMemoryNonWidthSensitivity(_ fixture: Fixture, _ seed: MemorySeed) throws {
        let kind = try XCTUnwrap(seed.kind)
        guard (seed.base == 0x4e84 && kind == .bgrToPlanes16) ||
              (seed.base == 0x29a70 && kind == .planesToBGR16) else {
            throw Ordinary.Failure.invalidContract("native non-width adapter only covers retained 4e84/29a70 originals")
        }
        let p = try historicalNative(fixture)
        let pointerRow = kind.planarToInterleaved ? 22 : 21
        let pointerOperands = kind.planarToInterleaved ? "x3, x3, #8" : "x1, x1, #8"
        // Bind every actual source row/slot/operand AST before either literal
        // reference or unchanged candidate execution. Do not select mutations
        // from observed values or recover from a failed mutation by reseeding.
        var mutations = try [
            nonWidthStaleAdd(p, row: 18, operands: "x15, x15, #6", increment: 6,
                name: "missing live inner loop pointer state"),
            nonWidthStaleAdd(p, row: pointerRow, operands: pointerOperands, increment: 8,
                name: "missing live outer loop pointer state"),
            nonWidthLateCMP(p, writer: 23, subtract: 24, consumer: 25, threshold: 2)
        ]
        if kind == .planesToBGR16 {
            mutations.append(try nonWidthEarlyPostindex(p, row: 12, mnemonic: "ldrh",
                operands: "w17, [x12], #2", bytes: 2))
            mutations.append(try nonWidthWrongPostindex(p))
            mutations.append(try nonWidthAliasOrder(p))
        }
        var scenario = UnsignedMemoryScenario(kind: kind, width: 3, rows: 2,
            components: 3, index: .max, alias: .laterRead)
        // Row one has disjoint source and destination buffers. Make its first
        // output byte differ from the source before either oracle executes,
        // so omitting that row must leave a concrete final-memory discrepancy.
        let secondRowOutput = scenario.outputAddress(0, 1, 0)
        scenario.memory[secondRowOutput] = UInt8(truncatingIfNeeded: scenario.sourceSample(0, 1, 0)) ^ 0xff
        let expected = try scenario.reference()
        let reference = try historicalTrace(p.inventory, physical: scenario.physical, memory: scenario.memory)
        try requireHistoricalLiteralAgreement(reference, expected: expected.result, label: scenario.label)
        let original = try runHistoricalNative(p, physical: scenario.physical, memory: scenario.memory,
            model: .strictOrdinaryC, label: scenario.label)
        try compareHistoricalTrace(p, actual: original, reference: reference, label: scenario.label)
        guard original.returned, original.events == expected.result.events,
              original.memory == expected.result.memory,
              original.writes.mapValues({ $0.map(\.bits) }) == reference.writes,
              original.loaded.map(\.bits) == (expected.states["loaded"] ?? []),
              original.values(row: 24) == [1, 0] else {
            throw Ordinary.Failure.semanticMismatch("unchanged native non-width control failed before mutant execution")
        }
        let inputs = Dictionary(uniqueKeysWithValues: p.manifest.formals.map { formal in
            (formal.name, Ordinary.Value(scenario.physical[p.formals[formal.name]!]!, formal.type))
        })
        let input = try NoCall.scenario(name: scenario.label, inputs: inputs, memory: scenario.memory, manifest: p.manifest)
        let originalAccesses = try nonWidthAccesses(original.raw)
        for mutation in mutations {
            // Refusal, uninitialized/type/parse errors, undefined arithmetic,
            // and fuel exhaustion propagate as test failures, never kills.
            let wrong = try Ordinary.Machine(program: mutation.program, scenario: input).run()
            try NoCall.requireTerminal(wrong, manifest: p.manifest)
            guard wrong.returned, wrong.memory != expected.result.memory else {
                throw Ordinary.Failure.semanticMismatch("non-width mutation lacks normal return and concrete final-memory discrepancy: " + mutation.name)
            }
            let countMutation = mutation.name == "CMP reads post-SUB count"
            let observedRow = countMutation ? 24 : mutation.row
            let actual = try nonWidthCommitted(mutation, wrong, row: observedRow, ordinal: mutation.ordinal)
            let correct = reference.writes[.init(row: observedRow, ordinal: mutation.ordinal), default: []]
            guard !actual.isEmpty, !correct.isEmpty, actual != correct else {
                throw Ordinary.Failure.semanticMismatch("non-width mutation lacks its named original-slot numerical discrepancy: " + mutation.name)
            }
            let accesses = try nonWidthAccesses(wrong)
            if countMutation {
                // Old count=2 permits the second row; post-SUB count=1 does not.
                // Static access inventory is unchanged. This one control-flow
                // mutation intentionally has exactly the first-row dynamic
                // access prefix, not an arbitrary decrease or a refusal.
                guard actual == [1], correct == [1, 0],
                      let secondRow = originalAccesses.firstIndex(where: { $0.site.row == 6 && $0.occurrence == 1 }),
                      accesses == Array(originalAccesses[..<secondRow]),
                      wrong.events == Array(original.raw.events[..<secondRow]) else {
                    throw Ordinary.Failure.semanticMismatch("writer-time CMP mutation did not normally lose exactly the second row")
                }
            } else {
                guard actual.count == correct.count, nonWidthSameTransfers(wrong, original.raw) else {
                    throw Ordinary.Failure.semanticMismatch("non-control mutation changed source-slot visits or branch routing")
                }
                if mutation.name == "store-before-next-load alias order" {
                    var reordered = originalAccesses
                    var pairs = 0
                    for index in originalAccesses.indices.dropLast() {
                        if originalAccesses[index].site == Ordinary.SourceSite(row: 13, effectOrdinal: 0) {
                            guard originalAccesses[index + 1].site == Ordinary.SourceSite(row: 14, effectOrdinal: 0) else {
                                throw Ordinary.Failure.invalidContract("original alias event pair is not store13 then load14")
                            }
                            reordered.swapAt(index, index + 1); pairs += 1
                        }
                    }
                    guard pairs == 6, accesses == reordered,
                          correct.first == scenario.sourceSample(0, 0, 0),
                          actual.first == scenario.sourceSample(1, 0, 0) else {
                        throw Ordinary.Failure.semanticMismatch("alias mutation lacks the exact six same-width permutations and old-versus-stored first load")
                    }
                } else {
                    guard accesses == originalAccesses, let topology = mutation.topology else {
                        throw Ordinary.Failure.semanticMismatch("non-order mutation changed access cardinality, widths, order, or source ownership")
                    }
                    _ = try NativeLedger.observe(topology, candidate: mutation.program, actual: wrong,
                        referenceBranches: reference.branches, referenceRowVisits: reference.visits,
                        referenceReturned: reference.returned, name: scenario.label + ": " + mutation.name)
                    switch mutation.name {
                    case "missing live inner loop pointer state":
                        let bases = (0..<2).flatMap { row in Array(repeating: scenario.interleaved(row) + 4, count: 3) }
                        guard actual == bases else {
                            throw Ordinary.Failure.semanticMismatch("inner recurrence mutation is not the exact unchanged pre-increment base for each pixel")
                        }
                    case "missing live outer loop pointer state":
                        guard actual == [scenario.interleavedRows, scenario.interleavedRows],
                              correct == [scenario.interleavedRows + 8, scenario.interleavedRows + 16] else {
                            throw Ordinary.Failure.semanticMismatch("outer recurrence mutation is not the exact unadvanced row-table pointer")
                        }
                    case "wrong post-index pointer increment":
                        let expectedWrong = (0..<2).flatMap { row in (1...3).map { scenario.plane(0, row) + UInt64($0 * 3) } }
                        let expectedCorrect = (0..<2).flatMap { row in (1...3).map { scenario.plane(0, row) + UInt64($0 * 2) } }
                        guard actual == expectedWrong, correct == expectedCorrect else {
                            throw Ordinary.Failure.semanticMismatch("wrong post-index control did not commit exact +3 rather than +2 recurrence")
                        }
                    case "postindex load reads advanced base":
                        guard actual.first == scenario.sourceSample(0, 0, 1),
                              correct.first == scenario.sourceSample(0, 0, 0) else {
                            throw Ordinary.Failure.semanticMismatch("old-base control did not read exactly the next halfword at its first access")
                        }
                    default: throw Ordinary.Failure.invalidContract("unexpected non-width mutation obligation")
                    }
                }
            }
            print("HISTORICAL_NATIVE_NONWIDTH_NORMAL_COMPLETION name=\(mutation.name) scenario=\(scenario.label) row=\(mutation.row) ordinal=\(mutation.ordinal) observationRow=\(observedRow) original=\(correct) mutant=\(actual) finalMemoryDiffers=true normalReturn=true")
        }
        // This selector's bounded non-width portion cannot retire the retained
        // original width/sign/full64-cell obligations. Their bodies remain
        // preserved above and their execution status is explicitly OPEN.
    }
}
