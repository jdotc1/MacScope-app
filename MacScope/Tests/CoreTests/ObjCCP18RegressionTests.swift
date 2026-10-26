import XCTest
@testable import MacScope

/// New deterministic layouts derived from CP18-F001/F002's saved witnesses. These do not
/// load, mutate or replay the completed campaign, and need no external binaries or model.
final class ObjCCP18RegressionTests: XCTestCase {
    private struct Image {
        var bytes = [UInt8](repeating: 0, count: 0x800)

        mutating func u64(_ offset: Int, _ value: UInt64) {
            for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }

        mutating func u32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }

        mutating func string(_ offset: Int, _ value: String) {
            let encoded = Array((value + "\0").utf8)
            bytes.replaceSubrange(offset..<offset + encoded.count, with: encoded)
        }

        func parser(sections: [ObjCClassParser.Section], rebases: [UInt64: UInt64] = [:]) -> ObjCClassParser {
            ObjCClassParser(data: Data(bytes), sections: sections, rebaseTargets: rebases, bindNames: [:])
        }
    }

    private func classImage() -> Image {
        var image = Image()
        image.u64(0, 0x1040)
        image.u64(0x60, 0x1080)
        image.u64(0x98, 0x1100)
        image.string(0x100, "CP18Witness")
        return image
    }

    private func classSections() -> [ObjCClassParser.Section] {
        [
            .init(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
            .init(address: 0x1008, fileOffset: 8, size: 0x7f8, name: "__objc_const"),
        ]
    }

    func testExtendedPropertyAndIvarStridesWalkBothEntries() throws {
        // F001 witnesses: property stride 24 (66248488...), ivar stride 64 (e1e1fbf6...).
        // A second independently named entry proves stepping by the declared stride.
        var image = classImage()
        image.u64(0xc0, 0x1200) // ro.baseProperties
        image.u32(0x200, 24)
        image.u32(0x204, 2)
        image.u64(0x208, 0x1500)
        image.u64(0x210, 0x1520)
        image.u64(0x220, 0x1540)
        image.u64(0x228, 0x1560)
        image.string(0x500, "weight")
        image.string(0x520, "Td,N,V_weight")
        image.string(0x540, "count")
        image.string(0x560, "Ti,N,V_count")
        image.u64(0xb0, 0x1300) // ro.ivars
        image.u32(0x300, 64)
        image.u32(0x304, 2)
        for (entry, name, type, offset, size) in [
            (0x308, 0x1580, 0x15a0, 16, 8),
            (0x348, 0x15c0, 0x15e0, 24, 4),
        ] {
            image.u64(entry, UInt64(0x1000 + entry + 32))
            image.u64(entry + 8, UInt64(name))
            image.u64(entry + 16, UInt64(type))
            image.u32(entry + 28, UInt32(size))
            image.u32(entry + 32, UInt32(offset))
        }
        image.string(0x580, "_weight")
        image.string(0x5a0, "d")
        image.string(0x5c0, "_count")
        image.string(0x5e0, "i")
        let cls = try XCTUnwrap(image.parser(sections: classSections()).parseClasses().first)
        XCTAssertEqual(cls.properties, [
            ObjCProperty(name: "weight", attributes: "Td,N,V_weight"),
            ObjCProperty(name: "count", attributes: "Ti,N,V_count"),
        ])
        XCTAssertEqual(cls.ivars, [
            ObjCIvar(name: "_weight", typeEncoding: "d", offset: 16, size: 8),
            ObjCIvar(name: "_count", typeEncoding: "i", offset: 24, size: 4),
        ])
    }

    func testMemberStridesRejectTooSmallAndUnmappedDeclaredExtent() throws {
        // Keep readable known prefixes and strings so rejection cannot pass just because
        // a name is missing. The raw size has no flags: high bits must not be masked away.
        for (propertyStride, ivarStride) in [(UInt32(8), UInt32(24)), (0x10010, 0x10020), (24, 64)] {
            var image = classImage()
            image.u64(0xc0, 0x1200)
            image.u32(0x200, propertyStride)
            image.u32(0x204, 1)
            image.u64(0x208, 0x1500)
            image.u64(0x210, 0x1520)
            image.u64(0xb0, 0x1300)
            image.u32(0x300, ivarStride)
            image.u32(0x304, 1)
            image.u64(0x310, 0x1540)
            image.u64(0x318, 0x1560)
            image.string(0x500, "weight")
            image.string(0x520, "Td,N,V_weight")
            image.string(0x540, "_weight")
            image.string(0x560, "d")
            let sections: [ObjCClassParser.Section] = [
                .init(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_classlist"),
                .init(address: 0x1008, fileOffset: 8, size: 0x1f8, name: "__objc_const"),
                .init(address: 0x1200, fileOffset: 0x200, size: 24, name: "__objc_const"),
                .init(address: 0x1300, fileOffset: 0x300, size: 40, name: "__objc_const"),
                .init(address: 0x1500, fileOffset: 0x500, size: 0x300, name: "__cstring"),
            ]
            let cls = try XCTUnwrap(image.parser(sections: sections).parseClasses().first)
            XCTAssertTrue(cls.properties.isEmpty, "invalid property stride \(propertyStride)")
            XCTAssertTrue(cls.ivars.isEmpty, "invalid ivar stride \(ivarStride)")
        }
    }

    private func protocolImage(nameTarget: UInt32) -> Image {
        var image = Image()
        image.u64(0, 0x1040)
        image.u64(0x48, 0x1100) // protocol.name
        image.u64(0x58, 0x1180) // required instance methods
        image.u32(0x80, 72)
        image.string(0x100, "CounterProtocol")
        image.u32(0x180, 0x8000_000c)
        image.u32(0x184, 1)
        image.u32(0x188, nameTarget - 0x1188)
        image.u32(0x18c, 0x1320 - 0x118c)
        image.u64(0x280, 0x1300) // aligned pointer slot in __objc_const
        image.string(0x300, "counter")
        image.string(0x320, "i16@0:8")
        return image
    }

    private func protocolSections() -> [ObjCClassParser.Section] {
        [
            .init(address: 0x1000, fileOffset: 0, size: 8, name: "__objc_protolist"),
            .init(address: 0x1008, fileOffset: 8, size: 0x2f8, name: "__objc_const"),
            .init(address: 0x1300, fileOffset: 0x300, size: 0x500, name: "__objc_methname"),
        ]
    }

    func testCompactProtocolSelectorDereferencesConstSlotRawAndRebased() throws {
        // F002 saved a531294c...: ordinary compact name references an aligned pointer
        // in __objc_const, not __objc_selrefs. Fixups must take precedence over raw bytes.
        for rebased in [false, true] {
            var image = protocolImage(nameTarget: 0x1280)
            if rebased { image.u64(0x280, 0xffff_ffff_ffff_ffff) }
            let rebases: [UInt64: UInt64] = rebased ? [0x1280: 0x1300] : [:]
            let proto = try XCTUnwrap(image.parser(sections: protocolSections(), rebases: rebases).parseProtocols().first)
            XCTAssertEqual(proto.requiredMethods, [ObjCMethod(selector: "counter", typeEncoding: "i16@0:8", isClassMethod: false)])
        }
    }

    func testCompactSelectorMetadataFailureDoesNotFallBackToPrintableSlotBytes() throws {
        // The slot happens to spell a plausible selector, but authoritative pointer metadata
        // says it is unresolved/unreadable. Never reinterpret those pointer bytes as a name.
        enum Failure: CaseIterable { case unresolvedBind, abstained, unreadableRebase }
        for failure in Failure.allCases {
            var image = protocolImage(nameTarget: 0x1280)
            image.string(0x280, "counter")
            var parser = image.parser(sections: protocolSections())
            switch failure {
            case .unresolvedBind:
                parser.bindNames[0x1280] = "_unresolved_selector"
            case .abstained:
                parser.abstainedPointerSlots.insert(0x1280)
            case .unreadableRebase:
                parser.rebaseTargets[0x1280] = 0x9000 // outside every mapped section
            }
            let proto = try XCTUnwrap(parser.parseProtocols().first)
            XCTAssertTrue(proto.requiredMethods.isEmpty, "must not invent selector for \(failure)")
        }
    }

    func testCompactDirectMethodNameStillDecodes() throws {
        let image = protocolImage(nameTarget: 0x1300)
        let proto = try XCTUnwrap(image.parser(sections: protocolSections()).parseProtocols().first)
        XCTAssertEqual(proto.requiredMethods, [ObjCMethod(selector: "counter", typeEncoding: "i16@0:8", isClassMethod: false)])
    }

    func testCompactMethodStrideRemainsExact() throws {
        var image = protocolImage(nameTarget: 0x1280)
        image.u32(0x180, 0x8000_0010) // Extended members do not authorize extended method_t.
        let proto = try XCTUnwrap(image.parser(sections: protocolSections()).parseProtocols().first)
        XCTAssertTrue(proto.requiredMethods.isEmpty)
    }
}
