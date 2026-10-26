import Foundation
import XCTest
@testable import MacScope

final class DarwinARM64VariadicCursorTests: XCTestCase {
    private typealias V = DarwinARM64Variadic

    private struct Block: Sendable {
        let id: String
        let start: UInt64
        let bytes: [UInt8]
    }
    private enum TestReadFault: Error { case denied }

    private func identity(_ snapshot: String = "snapshot-A") throws -> V.SnapshotIdentity {
        try V.SnapshotIdentity(imageID: "fixture-image-sha256", snapshotID: snapshot)
    }

    private func field(_ offset: Int, _ count: Int) throws -> V.ValueByteRange {
        try V.ValueByteRange(offset: offset, byteCount: count)
    }

    private func argument(
        _ id: String, _ size: Int, _ alignment: UInt64, _ carrier: V.Carrier = .direct,
        source: String? = nil, fields: [V.ValueByteRange]? = nil
    ) throws -> V.ArgumentDescriptor {
        try V.ArgumentDescriptor(sourceTypeID: source ?? id, extractionTypeID: id, valueByteCount: size,
                                 valueAlignment: alignment, carrier: carrier,
                                 meaningfulBytes: fields ?? [field(0, size)])
    }

    private func cursor(_ args: [V.ArgumentDescriptor], named: UInt64 = 0, bytes: UInt64 = 1024) throws -> V.Cursor {
        try V.Cursor(identity: identity(), entrySP: 0x1000, namedStackExtent: named,
                     incomingStackBounds: V.AddressRange(start: 0x1000, byteCount: bytes), arguments: args)
    }

    private func little(_ value: UInt64, _ count: Int = 8) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private func memory(_ blocks: [Block], snapshot: String = "snapshot-A",
                        fail: V.ReadPurpose? = nil, short: V.ReadPurpose? = nil) throws -> V.SnapshotReader {
        let regions = try blocks.map {
            try V.ReadableRegion(id: $0.id, range: V.AddressRange(start: $0.start, byteCount: UInt64($0.bytes.count)))
        }
        return try V.SnapshotReader(identity: identity(snapshot), regions: regions) { request in
            if let fail, request.purpose == fail { throw TestReadFault.denied }
            guard let block = blocks.first(where: { $0.id == request.regionID }) else {
                throw V.Fault.unreadable(request.range)
            }
            let offset = Int(request.range.start - block.start)
            let result = Array(block.bytes[offset..<(offset + Int(request.range.byteCount))])
            if let short, request.purpose == short { return Array(result.dropLast()) }
            return result
        }
    }

    private func stack(_ bytes: [UInt8] = [UInt8](repeating: 0, count: 1024)) -> Block {
        Block(id: "stack", start: 0x1000, bytes: bytes)
    }

    func testVaStartRoundsTheNamedExtentToEightAndRefusesOtherProfiles() throws {
        for (extent, offset) in [(UInt64(0), UInt64(0)), (4, 8), (12, 16)] {
            XCTAssertEqual(try cursor([], named: extent).nextAddress, 0x1000 + offset)
        }
        XCTAssertEqual(V.vaListByteCount, 8)
        XCTAssertThrowsError(try V.Cursor(profileID: "aapcs64", identity: identity(), entrySP: 0x1000,
                                          namedStackExtent: 0,
                                          incomingStackBounds: V.AddressRange(start: 0x1000, byteCount: 16),
                                          arguments: [])) {
            XCTAssertEqual($0 as? V.Fault, .unsupportedProfile("aapcs64"))
        }
        XCTAssertThrowsError(try V.Cursor(identity: identity(), entrySP: 0x1008, namedStackExtent: 0,
                                          incomingStackBounds: V.AddressRange(start: 0x1000, byteCount: 16),
                                          arguments: [])) {
            XCTAssertEqual($0 as? V.Fault, .misalignedEntrySP)
        }
        XCTAssertThrowsError(try cursor([], named: 4097))
        XCTAssertNoThrow(try cursor(Array(repeating: argument("int", 4, 4), count: 64)))
        XCTAssertThrowsError(try cursor(Array(repeating: argument("int", 4, 4), count: 65)))
    }

    /// Witness `case_00113` (observation 3fecea34…): five named `__int128` after a pointer
    /// and before the final `int` exhaust x0-x6, spill two pairs at 0 and 16 and the
    /// `int` at 32, so `va_start` is entry SP + 40.
    func testNamedStackExtentComesFromTheRichBinderLocations() throws {
        let named = ["void *"] + Array(repeating: "__int128", count: 5) + ["int"]
        let locations = DarwinARM64ParameterBinder.bindRich(parameterTypes: named, isVariadic: true)
        XCTAssertEqual(Array(locations.suffix(3)), [
            .entryStack(byteOffset: 0, size: 16, alignment: 16),
            .entryStack(byteOffset: 16, size: 16, alignment: 16),
            .entryStack(byteOffset: 32, size: 4, alignment: 4),
        ])
        let extent = try V.namedStackExtent(of: locations)
        XCTAssertEqual(extent, 36)
        XCTAssertEqual(try cursor([], named: extent).nextAddress, 0x1000 + 40)

        XCTAssertEqual(try V.namedStackExtent(of: [
            .gpr(index: 0, carrierWidth: 64), .indirect(pointer: .gpr(index: 1), pointeeSize: 24, pointeeAlignment: 8),
        ]), 0)
        XCTAssertEqual(try V.namedStackExtent(of: [
            .entryStack(byteOffset: 0, size: 2, alignment: 2),
            .indirect(pointer: .entryStack(byteOffset: 8), pointeeSize: 40, pointeeAlignment: 8),
        ]), 16)
        XCTAssertThrowsError(try V.namedStackExtent(of: [
            .gpr(index: 0, carrierWidth: 64), .unbound(reason: .unsupportedType("struct Opaque")),
        ])) {
            XCTAssertEqual($0 as? V.Fault, .unboundNamedParameter(index: 1))
        }
        XCTAssertThrowsError(try V.namedStackExtent(of: [.entryStack(byteOffset: -8, size: 8, alignment: 8)]))
    }

    /// Witness `case_00001` (observation f28a36d5…): `char`, `unsigned short` and `float`
    /// actuals are read back as promoted `int`, `int` and `double`, one slot each.
    func testDefaultPromotionsAreDescriptorInputs() throws {
        let float = Float(1.1)
        var bytes = little(UInt64(UInt32(bitPattern: -128))) + little(0xFFFF)
        bytes += little(Double(float).bitPattern) + little(0xFFFF_FFFF)
        let reader = try memory([stack(bytes)])
        var c = try cursor([
            argument("int", 4, 4, source: "signed char"), argument("int", 4, 4, source: "unsigned short"),
            argument("double", 8, 8, source: "float"), argument("unsigned int", 4, 4),
        ])
        let before = c
        XCTAssertThrowsError(try c.extract(typeID: "signed char", using: reader)) {
            XCTAssertEqual($0 as? V.Fault, .typeMismatch(expected: "int", requested: "signed char"))
        }
        XCTAssertEqual(c, before)
        let values = try ["int", "int", "double", "unsigned int"].map { try c.extract(typeID: $0, using: reader) }
        XCTAssertEqual(values.map(\.slotRange.start), [0x1000, 0x1008, 0x1010, 0x1018])
        XCTAssertEqual(values[0].canonicalBytes, [0x80, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(values[1].canonicalBytes, [0xFF, 0xFF, 0x00, 0x00])
        XCTAssertEqual(values[2].canonicalBytes, little(Double(float).bitPattern))
        XCTAssertEqual(values[2].descriptor.sourceTypeID, "float")
        XCTAssertThrowsError(try c.extract(typeID: "int", using: reader)) { XCTAssertEqual($0 as? V.Fault, .exhausted) }
    }

    func testFormatArgumentsBecomeEightByteSlotDescriptors() throws {
        let arguments = try XCTUnwrap(FormatStringParser.arguments(of: "%*d %s %f %ld", flavor: .printf))
        let descriptors = try arguments.map(V.ArgumentDescriptor.init(formatArgument:))
        XCTAssertEqual(descriptors.map(\.extractionTypeID), ["int", "int", "const char *", "double", "long"])
        XCTAssertEqual(descriptors.map(\.valueByteCount), [4, 4, 8, 8, 8])
        var c = try cursor(descriptors)
        let reader = try memory([stack()])
        let ends = try descriptors.map { try c.extract(typeID: $0.extractionTypeID, using: reader).cursorAfter }
        XCTAssertEqual(ends, [0x1008, 0x1010, 0x1018, 0x1020, 0x1028])
        for (ordinal, end) in ends.enumerated() {
            XCTAssertEqual(MacIRCallFormatStringEvidence.tailLocation(ordinal: ordinal),
                           .callStack(byteOffset: Int(end - 0x1000) - 8, size: 8, alignment: 8))
        }
    }

    /// Apple clang 21 (`-arch arm64 -O0`) on this Mac: cursor offsets from callee-entry SP
    /// after each `va_arg`, as `docs/abi/darwin-varargs/witness/varargs_witness.c` printed them.
    func testAppleClangWitnessCursorOffsets() throws {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(8..<16, with: little(0x2000))
        let reader = try memory([stack(bytes), Block(id: "A32", start: 0x2000, bytes: [UInt8](repeating: 1, count: 32))])
        func offsets(_ args: [V.ArgumentDescriptor]) throws -> [UInt64] {
            var c = try cursor(args)
            return try args.map { try c.extract(typeID: $0.extractionTypeID, using: reader).cursorAfter - 0x1000 }
        }
        let int = try argument("int", 4, 4), long = try argument("long", 8, 8), double = try argument("double", 8, 8)
        let int128 = try argument("__int128", 16, 16), pointer = try argument("char *", 8, 8)
        let a32 = try argument("A32", 32, 8, .indirectPointer64)
        let hfa = try argument("HFA4D", 32, 8, .homogeneousFloat(baseByteCount: 8, memberCount: 4))
        XCTAssertEqual(try offsets([int, double, pointer, double, double]), [8, 16, 24, 32, 40])
        XCTAssertEqual(try offsets([int, int128, int, int128]), [8, 32, 40, 64])
        XCTAssertEqual(try offsets([int, a32, int, hfa, int]), [8, 16, 24, 56, 64])
        XCTAssertEqual(try offsets([int128, long, int128]), [16, 24, 48])
        XCTAssertEqual(try offsets(Array(repeating: double, count: 9)).last, 72)
    }

    func testIntegerSlotsAndInt128Alignment() throws {
        var c = try cursor([argument("int", 4, 4), argument("__int128", 16, 16), argument("int", 4, 4)])
        let reader = try memory([stack((0..<64).map { UInt8($0) })])
        let a = try c.extract(typeID: "int", using: reader)
        let b = try c.extract(typeID: "__int128", using: reader)
        let d = try c.extract(typeID: "int", using: reader)
        XCTAssertEqual([a.slotRange.start, b.slotRange.start, d.slotRange.start], [0x1000, 0x1010, 0x1020])
        XCTAssertEqual([a.cursorAfter, b.cursorAfter, d.cursorAfter], [0x1008, 0x1020, 0x1028])
        XCTAssertEqual(b.canonicalBytes, (16..<32).map { UInt8($0) })
    }

    func testLargeHFAStaysInlineWhileOtherLargeRecordsGoThroughAPointer() throws {
        var bytes = [UInt8](repeating: 0x3C, count: 64)
        bytes.replaceSubrange(40..<48, with: little(0x2000))
        let reader = try memory([stack(bytes), Block(id: "F5", start: 0x2000, bytes: [UInt8](repeating: 7, count: 20))])
        var c = try cursor([
            argument("F3", 12, 4, .homogeneousFloat(baseByteCount: 4, memberCount: 3)),
            argument("D3", 24, 8, .homogeneousFloat(baseByteCount: 8, memberCount: 3)),
            argument("F5", 20, 4, .indirectPointer64),
        ])
        let f = try c.extract(typeID: "F3", using: reader)
        let d = try c.extract(typeID: "D3", using: reader)
        let i = try c.extract(typeID: "F5", using: reader)
        XCTAssertEqual([f.cursorAfter, d.cursorAfter, i.cursorAfter], [0x1010, 0x1028, 0x1030])
        XCTAssertEqual(f.canonicalBytes.count, 12)
        XCTAssertEqual(d.payloadRange.start, 0x1010)
        XCTAssertTrue(d.carrierEvidence.isEmpty)
        XCTAssertEqual(i.slotRange.start, 0x1028)
        XCTAssertEqual(i.payloadRange.start, 0x2000)
        XCTAssertEqual(i.canonicalBytes, [UInt8](repeating: 7, count: 20))
    }

    /// Witness `case_00003` (observation 0de3a9b8…): a 16-aligned 32-byte record after an
    /// `int` takes an 8-aligned pointer slot, not a 16-aligned pointee-sized one.
    func testIndirectPointerSlotIsEightAlignedAndPaddingIsExcluded() throws {
        var bytes = [UInt8](repeating: 0xEE, count: 32)
        bytes.replaceSubrange(8..<16, with: little(0x2000))
        let payload = (0..<32).map { UInt8($0) }
        let reader = try memory([stack(bytes), Block(id: "record", start: 0x2000, bytes: payload)])
        let record = try argument("A32", 32, 16, .indirectPointer64, fields: [field(0, 16), field(16, 8)])
        var c = try cursor([argument("int", 4, 4), record, argument("int", 4, 4)])
        _ = try c.extract(typeID: "int", using: reader)
        let value = try c.extract(typeID: "A32", using: reader)
        XCTAssertEqual(value.slotRange.start, 0x1008)
        XCTAssertEqual(value.cursorAfter, 0x1010)
        XCTAssertEqual(value.canonicalBytes, Array(payload.prefix(24)))
        XCTAssertEqual(value.carrierEvidence.first?.range, value.slotRange)
        XCTAssertEqual(value.payloadEvidence.first?.identity, try identity())
    }

    func testInteriorPaddingDoesNotChangeTheCanonicalValue() throws {
        let descriptor = try argument("P16", 16, 8, fields: [field(0, 1), field(8, 8)])
        var first = [UInt8](repeating: 0x11, count: 16)
        first[0] = 7
        var second = first
        second.replaceSubrange(1..<8, with: [UInt8](repeating: 0xEE, count: 7))
        var a = try cursor([descriptor])
        var b = a
        let valueA = try a.extract(typeID: "P16", using: memory([stack(first)]))
        let valueB = try b.extract(typeID: "P16", using: memory([stack(second)]))
        XCTAssertEqual(valueA.canonicalBytes, [7] + [UInt8](repeating: 0x11, count: 8))
        XCTAssertEqual(valueA.canonicalBytes, valueB.canonicalBytes)
        XCTAssertEqual(valueA.payloadRange.byteCount, 16)
    }

    func testCopyStartsAtTheCurrentPositionAndOutlivesTheOriginal() throws {
        var c = try cursor([argument("int", 4, 4), argument("__int128", 16, 16), argument("int", 4, 4)])
        let reader = try memory([stack()])
        _ = try c.extract(typeID: "int", using: reader)
        var copy = try c.copied()
        let original = try c.extract(typeID: "__int128", using: reader)
        XCTAssertEqual(copy.nextAddress, 0x1008)
        try c.end()
        XCTAssertEqual(try copy.extract(typeID: "__int128", using: reader), original)
        _ = try copy.extract(typeID: "int", using: reader)
        XCTAssertEqual(c.nextAddress, 0x1020)
        XCTAssertEqual(copy.nextAddress, 0x1028)
        XCTAssertThrowsError(try c.copied()) { XCTAssertEqual($0 as? V.Fault, .ended) }
        XCTAssertThrowsError(try c.extract(typeID: "int", using: reader)) { XCTAssertEqual($0 as? V.Fault, .ended) }
        try copy.end()
        XCTAssertThrowsError(try copy.end()) { XCTAssertEqual($0 as? V.Fault, .ended) }
    }

    func testReadFaultsShortResponsesAndForeignSnapshotsLeaveTheCursorUnchanged() throws {
        let blocks = [stack(little(0x2000)), Block(id: "payload", start: 0x2000, bytes: [UInt8](repeating: 5, count: 24))]
        var c = try cursor([argument("I3", 24, 8, .indirectPointer64)])
        let before = c
        XCTAssertThrowsError(try c.extract(typeID: "I3", using: memory(blocks, fail: .indirectValue)))
        XCTAssertEqual(c, before)
        XCTAssertThrowsError(try c.extract(typeID: "I3", using: memory(blocks, short: .pointerCarrier))) {
            XCTAssertEqual($0 as? V.Fault, .shortRead(expected: 8, actual: 7))
        }
        XCTAssertEqual(c, before)
        XCTAssertThrowsError(try c.extract(typeID: "I3", using: memory(blocks, short: .indirectValue))) {
            XCTAssertEqual($0 as? V.Fault, .shortRead(expected: 24, actual: 23))
        }
        XCTAssertEqual(c, before)
        XCTAssertThrowsError(try c.extract(typeID: "I3", using: memory(blocks, snapshot: "other"))) {
            XCTAssertEqual($0 as? V.Fault, .identityMismatch)
        }
        XCTAssertEqual(c, before)
        XCTAssertEqual(try c.extract(typeID: "I3", using: memory(blocks)).cursorAfter, 0x1008)
    }

    func testReaderJoinsOnlyAdjacentRegions() throws {
        let left = Block(id: "left", start: 0x1000, bytes: [1, 2, 3, 4])
        let right = Block(id: "right", start: 0x1004, bytes: [5, 6, 7, 8])
        var c = try cursor([argument("unsigned long", 8, 8)])
        let value = try c.extract(typeID: "unsigned long", using: memory([right, left]))
        XCTAssertEqual(value.canonicalBytes, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(value.payloadEvidence.map(\.regionID), ["left", "right"])
        var gap = try cursor([argument("unsigned long", 8, 8)])
        let before = gap
        XCTAssertThrowsError(try gap.extract(typeID: "unsigned long",
                                             using: memory([left, Block(id: "gap", start: 0x1005, bytes: [6, 7, 8])])))
        XCTAssertEqual(gap, before)
        XCTAssertThrowsError(try memory([left, left]))
        XCTAssertThrowsError(try memory([left, Block(id: "overlap", start: 0x1002, bytes: [8, 9])]))
    }

    func testOverflowStackBoundsAndInvalidPointersDoNotAdvance() throws {
        XCTAssertThrowsError(try V.AddressRange(start: .max, byteCount: 1))
        let high = UInt64.max - 15
        let bounds = try V.AddressRange(start: high, byteCount: 15)
        XCTAssertThrowsError(try V.Cursor(identity: identity(), entrySP: high, namedStackExtent: 16,
                                          incomingStackBounds: bounds, arguments: [])) {
            XCTAssertEqual($0 as? V.Fault, .arithmeticOverflow)
        }
        var c = try V.Cursor(identity: identity(), entrySP: high, namedStackExtent: 8,
                             incomingStackBounds: bounds, arguments: [argument("__int128", 16, 16)])
        let before = c
        XCTAssertThrowsError(try c.extract(typeID: "__int128", using: memory([stack()])))
        XCTAssertEqual(c, before)
        var narrow = try cursor([argument("int", 4, 4)], bytes: 4)
        XCTAssertThrowsError(try narrow.extract(typeID: "int", using: memory([stack()]))) {
            XCTAssertEqual($0 as? V.Fault, .stackBounds)
        }
        XCTAssertEqual(narrow.nextAddress, 0x1000)
        for pointer in [UInt64(0), 0x2008] {
            var indirect = try cursor([argument("A32", 32, 16, .indirectPointer64)])
            XCTAssertThrowsError(try indirect.extract(typeID: "A32", using: memory([stack(little(pointer))]))) {
                XCTAssertEqual($0 as? V.Fault, .invalidIndirectPointer(address: pointer, alignment: 16))
            }
            XCTAssertEqual(indirect.nextArgumentIndex, 0)
        }
    }

    func testDescriptorRefusesAmbiguousOrMalformedLayouts() throws {
        XCTAssertThrowsError(try argument("huge-direct", 24, 8))
        XCTAssertThrowsError(try argument("small-indirect", 16, 8, .indirectPointer64))
        XCTAssertThrowsError(try argument("bad-alignment", 12, 3))
        XCTAssertThrowsError(try argument("bad-size", 8, 16))
        XCTAssertThrowsError(try argument("F5", 20, 4, .homogeneousFloat(baseByteCount: 4, memberCount: 5)))
        XCTAssertThrowsError(try argument("HVA", 32, 16, .homogeneousFloat(baseByteCount: 16, memberCount: 2)))
        XCTAssertThrowsError(try argument("gap-HFA", 12, 4, .homogeneousFloat(baseByteCount: 4, memberCount: 3),
                                          fields: [field(0, 8)]))
        XCTAssertThrowsError(try argument("duplicate", 8, 8, fields: [field(0, 4), field(0, 4)]))
        XCTAssertThrowsError(try argument("overlap", 8, 8, fields: [field(0, 5), field(4, 4)]))
        XCTAssertThrowsError(try argument("outside", 8, 8, fields: [field(7, 2)]))
        XCTAssertThrowsError(try argument("empty", 8, 8, fields: []))
        XCTAssertThrowsError(try argument("", 8, 8))
        XCTAssertThrowsError(try field(Int.max, 1))
        XCTAssertThrowsError(try field(-1, 1))
    }
}
