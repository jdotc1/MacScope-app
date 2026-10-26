import XCTest
@testable import MacScope

final class NEONNarrowRoundAdmissionTests: XCTestCase {
    // Literal independent arbitrary-precision oracles; source-static only, not run.
    func testArchitecturalOraclesAndAdmission() throws {
        struct Row {
            let id: String
            let mnemonic: String
            let operands: String
            let n: MacIRNEONLaneOp.Vector
            let m: MacIRNEONLaneOp.Vector
            let old: MacIRNEONLaneOp.Vector
            let expected: MacIRNEONLaneOp.Vector
        }
        let rows: [Row] = [
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-1", mnemonic: "smlsl2", operands: "v0.8h, v1.16b, v2.16b",
                  n: (0x0707070707070707, 0x8786858483828180), m: (0x0909090909090909, 0x8080808080808080),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0xd3b417785b3c9ef0, 0xc25c7d9838d4f410)),
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-2", mnemonic: "smlsl2", operands: "v0.8h, v1.16b, v2.16b",
                  n: (0x0707070707070707, 0x868584838281807f), m: (0x0909090909090909, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x11b655f99a3cdf6f, 0xfe62ba1d75d83193)),
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-3", mnemonic: "smlsl2", operands: "v0.8h, v1.16b, v2.16b",
                  n: (0x0707070707070707, 0x06050403020100ff), m: (0x0909090909090909, 0x0101010101010101),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123256779abcdef1, 0xfed6ba937650320d)),
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-4", mnemonic: "smlsl2", operands: "v0.4s, v1.8h, v2.8h",
                  n: (0x0007000700070007, 0x8003800280018000), m: (0x0009000900090009, 0x8000800080008000),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0xd234d6785abcdef0, 0xbede3a9836553210)),
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-5", mnemonic: "smlsl2", operands: "v0.4s, v1.8h, v2.8h",
                  n: (0x0007000700070007, 0x8002800180007fff), m: (0x0009000900090009, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x1233d6789abd5eef, 0xfedc3a9a7653b211)),
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-6", mnemonic: "smlsl2", operands: "v0.4s, v1.8h, v2.8h",
                  n: (0x0007000700070007, 0x000200010000ffff), m: (0x0009000900090009, 0x0001000100010001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef1, 0xfedcba967654320f)),
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-7", mnemonic: "smlsl2", operands: "v0.2d, v1.4s, v2.4s",
                  n: (0x0000000700000007, 0x8000000180000000), m: (0x0000000900000009, 0x8000000080000000),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0xd23456789abcdef0, 0xbedcba98f6543210)),
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-8", mnemonic: "smlsl2", operands: "v0.2d, v1.4s, v2.4s",
                  n: (0x0000000700000007, 0x800000007fffffff), m: (0x0000000900000009, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456791abcdeef, 0xfedcba97f6543210)),
            // smlsl_advsimd_vec.xml#Operation
            .init(id: "smlsl2-9", mnemonic: "smlsl2", operands: "v0.2d, v1.4s, v2.4s",
                  n: (0x0000000700000007, 0x00000000ffffffff), m: (0x0000000900000009, 0x0000000100000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef1, 0xfedcba9876543210)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-1", mnemonic: "raddhn", operands: "v0.8b, v1.8h, v2.8h",
                  n: (0xfffcfffdfffeffff, 0xfff8fff9fffafffb), m: (0xffffffffffffffff, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0000000000000000, 0x0000000000000000)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-2", mnemonic: "raddhn", operands: "v0.8b, v1.8h, v2.8h",
                  n: (0x007c007d007e007f, 0x00780079007a007b), m: (0x0001000100010001, 0x0001000100010001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0000000000000001, 0x0000000000000000)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-3", mnemonic: "raddhn", operands: "v0.8b, v1.8h, v2.8h",
                  n: (0x00fc00fd00fe00ff, 0x00f800f900fa00fb), m: (0x0001000100010001, 0x0001000100010001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0101010101010101, 0x0000000000000000)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-4", mnemonic: "raddhn", operands: "v0.4h, v1.4s, v2.4s",
                  n: (0xfffffffeffffffff, 0xfffffffcfffffffd), m: (0xffffffffffffffff, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0000000000000000, 0x0000000000000000)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-5", mnemonic: "raddhn", operands: "v0.4h, v1.4s, v2.4s",
                  n: (0x00007ffe00007fff, 0x00007ffc00007ffd), m: (0x0000000100000001, 0x0000000100000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0000000000000001, 0x0000000000000000)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-6", mnemonic: "raddhn", operands: "v0.4h, v1.4s, v2.4s",
                  n: (0x0000fffe0000ffff, 0x0000fffc0000fffd), m: (0x0000000100000001, 0x0000000100000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0001000100010001, 0x0000000000000000)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-7", mnemonic: "raddhn", operands: "v0.2s, v1.2d, v2.2d",
                  n: (0xffffffffffffffff, 0xfffffffffffffffe), m: (0xffffffffffffffff, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0000000000000000, 0x0000000000000000)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-8", mnemonic: "raddhn", operands: "v0.2s, v1.2d, v2.2d",
                  n: (0x000000007fffffff, 0x000000007ffffffe), m: (0x0000000000000001, 0x0000000000000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0000000000000001, 0x0000000000000000)),
            // raddhn_advsimd.xml#Operation
            .init(id: "raddhn-9", mnemonic: "raddhn", operands: "v0.2s, v1.2d, v2.2d",
                  n: (0x00000000ffffffff, 0x00000000fffffffe), m: (0x0000000000000001, 0x0000000000000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x0000000100000001, 0x0000000000000000)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-1", mnemonic: "rshrn2", operands: "v0.16b, v1.8h, #1",
                  n: (0xfffcfffdfffeffff, 0xfff8fff9fffafffb), m: (0xffffffffffffffff, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0xfcfdfdfefeffff00)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-2", mnemonic: "rshrn2", operands: "v0.16b, v1.8h, #8",
                  n: (0x007c007d007e007f, 0x00780079007a007b), m: (0x0001000100010001, 0x0001000100010001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0x0000000000000000)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-3", mnemonic: "rshrn2", operands: "v0.16b, v1.8h, #7",
                  n: (0x00fc00fd00fe00ff, 0x00f800f900fa00fb), m: (0x0001000100010001, 0x0001000100010001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0x0202020202020202)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-4", mnemonic: "rshrn2", operands: "v0.8h, v1.4s, #1",
                  n: (0xfffffffeffffffff, 0xfffffffcfffffffd), m: (0xffffffffffffffff, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0xfffeffffffff0000)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-5", mnemonic: "rshrn2", operands: "v0.8h, v1.4s, #16",
                  n: (0x00007ffe00007fff, 0x00007ffc00007ffd), m: (0x0000000100000001, 0x0000000100000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0x0000000000000000)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-6", mnemonic: "rshrn2", operands: "v0.8h, v1.4s, #15",
                  n: (0x0000fffe0000ffff, 0x0000fffc0000fffd), m: (0x0000000100000001, 0x0000000100000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0x0002000200020002)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-7", mnemonic: "rshrn2", operands: "v0.4s, v1.2d, #1",
                  n: (0xffffffffffffffff, 0xfffffffffffffffe), m: (0xffffffffffffffff, 0xffffffffffffffff),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0xffffffff00000000)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-8", mnemonic: "rshrn2", operands: "v0.4s, v1.2d, #32",
                  n: (0x000000007fffffff, 0x000000007ffffffe), m: (0x0000000000000001, 0x0000000000000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0x0000000000000000)),
            // rshrn_advsimd.xml#Operation
            .init(id: "rshrn2-9", mnemonic: "rshrn2", operands: "v0.4s, v1.2d, #31",
                  n: (0x00000000ffffffff, 0x00000000fffffffe), m: (0x0000000000000001, 0x0000000000000001),
                  old: (0x123456789abcdef0, 0xfedcba9876543210), expected: (0x123456789abcdef0, 0x0000000200000002)),
        ]
        for row in rows {
            let parsed = try XCTUnwrap(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: row.mnemonic, operands: row.operands), row.id)
            let source = MacIRSourceSpan(address: 0x1000, byteText: "", mnemonic: row.mnemonic, operands: row.operands)
            let flow = C2MachineFlow(rows: [source])
            XCTAssertNil(flow.error, row.id)
            XCTAssertEqual(flow.writes[0], Set(["v0"]), row.id)
            XCTAssertEqual(flow.reads[0].contains("v0"), row.mnemonic != "raddhn", row.id)
            let effects = MacIRBuilder.ssaEffects(for: source)
            XCTAssertTrue(effects.refusals.isEmpty, row.id)
            XCTAssertEqual(Set(effects.writes.map { $0.cell }), Set([32, 64]), row.id)
            XCTAssertEqual(effects.reads.contains(32), row.mnemonic != "raddhn", row.id)
            XCTAssertEqual(effects.reads.contains(64), row.mnemonic != "raddhn", row.id)
            XCTAssertFalse(effects.reads.contains(98), row.id)
            let actual = parsed.semantics.evaluate(n: row.n, m: row.m, oldDestination: row.old)
            XCTAssertEqual(actual.low, row.expected.low, row.id)
            XCTAssertEqual(actual.high, row.expected.high, row.id)
            XCTAssertFalse(parsed.semantics.setsQC, row.id)
            if row.mnemonic == "rshrn2" { XCTAssertEqual(actual.low, row.old.low, row.id) }
        }
    }

    func testInvalidFormsRemainRefused() {
        for (mnemonic, operands) in [
            ("smlsl2", "v0.8h, v1.8b, v2.8b"),
            ("raddhn", "v0.8b, v1.8h, v2.4s"),
            ("rshrn2", "v0.16b, v1.8h, #0"),
            ("rshrn2", "v0.16b, v1.8h, #9")
        ] {
            XCTAssertNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic, operands: operands))
            let effects = MacIRBuilder.ssaEffects(for: .init(address: 0x1000, byteText: "", mnemonic: mnemonic, operands: operands))
            XCTAssertFalse(effects.refusals.isEmpty)
            let flow = C2MachineFlow(rows: [.init(address: 0x1000, byteText: "", mnemonic: mnemonic, operands: operands)])
            XCTAssertNotNil(flow.error)
        }
    }

    func testEveryRetainedFirstBlockerHasAdmission() throws {
        let sites: [(UInt64, String, String)] = [
            // rshrn_advsimd.xml#Operation
            (0x3d890, "rshrn2", "v4.8h, v19.4s, #0x2"),
            // raddhn_advsimd.xml#Operation
            (0x4e27c, "raddhn", "v6.4h, v6.4s, v11.4s"),
            // raddhn_advsimd.xml#Operation
            (0x4e6b8, "raddhn", "v6.4h, v6.4s, v11.4s"),
            // raddhn_advsimd.xml#Operation
            (0x4eaf4, "raddhn", "v6.4h, v6.4s, v11.4s"),
            // raddhn_advsimd.xml#Operation
            (0x4ef30, "raddhn", "v6.4h, v6.4s, v11.4s"),
            // raddhn_advsimd.xml#Operation
            (0x4f36c, "raddhn", "v6.4h, v6.4s, v11.4s"),
            // raddhn_advsimd.xml#Operation
            (0x4f7a8, "raddhn", "v6.4h, v6.4s, v11.4s"),
            // raddhn_advsimd.xml#Operation
            (0x4fbe4, "raddhn", "v6.4h, v6.4s, v11.4s"),
            // raddhn_advsimd.xml#Operation
            (0x4ffe0, "raddhn", "v0.4h, v1.4s, v19.4s"),
            // raddhn_advsimd.xml#Operation
            (0x50160, "raddhn", "v0.4h, v1.4s, v19.4s"),
            // raddhn_advsimd.xml#Operation
            (0x502dc, "raddhn", "v0.4h, v1.4s, v20.4s"),
            // raddhn_advsimd.xml#Operation
            (0x5045c, "raddhn", "v0.4h, v1.4s, v19.4s"),
            // raddhn_advsimd.xml#Operation
            (0x505d8, "raddhn", "v0.4h, v1.4s, v20.4s"),
            // raddhn_advsimd.xml#Operation
            (0x50754, "raddhn", "v0.4h, v1.4s, v20.4s"),
            // raddhn_advsimd.xml#Operation
            (0x508d0, "raddhn", "v0.4h, v1.4s, v20.4s"),
            // smlsl_advsimd_vec.xml#Operation
            (0x51e9c, "smlsl2", "v18.4s, v7.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x520dc, "smlsl2", "v18.4s, v7.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x52320, "smlsl2", "v22.4s, v19.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x525b0, "smlsl2", "v18.4s, v7.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x527f4, "smlsl2", "v22.4s, v19.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x52a88, "smlsl2", "v22.4s, v19.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x52d1c, "smlsl2", "v22.4s, v19.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x52fac, "smlsl2", "v18.4s, v7.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x531f0, "smlsl2", "v17.4s, v7.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x53418, "smlsl2", "v19.4s, v17.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x5371c, "smlsl2", "v17.4s, v7.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x53944, "smlsl2", "v19.4s, v17.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x53c50, "smlsl2", "v21.4s, v19.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x53f18, "smlsl2", "v23.4s, v17.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x54338, "smlsl2", "v17.4s, v7.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x54560, "smlsl2", "v19.4s, v17.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x5486c, "smlsl2", "v21.4s, v19.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x54b34, "smlsl2", "v23.4s, v17.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x54f5c, "smlsl2", "v21.4s, v19.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x55224, "smlsl2", "v23.4s, v17.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x55664, "smlsl2", "v21.4s, v19.8h, v2.8h"),
            // smlsl_advsimd_vec.xml#Operation
            (0x5592c, "smlsl2", "v23.4s, v17.8h, v2.8h"),
            // rshrn_advsimd.xml#Operation
            (0x55d9c, "rshrn2", "v16.16b, v2.8h, #0x2"),
            // rshrn_advsimd.xml#Operation
            (0x5649c, "rshrn2", "v7.8h, v16.4s, #0xb"),
            // rshrn_advsimd.xml#Operation
            (0x574d8, "rshrn2", "v1.8h, v3.4s, #0xd"),
            // rshrn_advsimd.xml#Operation
            (0x576a4, "rshrn2", "v23.8h, v5.4s, #0xc"),
        ]
        XCTAssertEqual(sites.count, 41)
        for (address, mnemonic, operands) in sites {
            let source = MacIRSourceSpan(address: address, byteText: "", mnemonic: mnemonic, operands: operands)
            XCTAssertNotNil(MacIRBuilder.ssaIntegerLaneOperation(mnemonic: mnemonic, operands: operands))
            XCTAssertTrue(MacIRBuilder.ssaEffects(for: source).refusals.isEmpty)
            XCTAssertNil(C2MachineFlow(rows: [source]).error)
        }
    }
}
