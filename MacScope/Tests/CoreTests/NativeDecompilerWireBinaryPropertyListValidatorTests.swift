import Foundation
import XCTest

@testable import MacScope

final class NativeDecompilerWireBinaryPropertyListValidatorTests: XCTestCase {
    func testAcceptsBinaryPropertyListAndRejectsXML() throws {
        let binary = try PropertyListSerialization.data(
            fromPropertyList: ["key": "value"],
            format: .binary,
            options: 0
        )
        let xml = try PropertyListSerialization.data(
            fromPropertyList: ["key": "value"],
            format: .xml,
            options: 0
        )

        XCTAssertNoThrow(try NativeDecompilerWireBinaryPropertyListValidator.validate(binary))
        XCTAssertThrowsError(try NativeDecompilerWireBinaryPropertyListValidator.validate(xml))
    }

    func testRejectsDuplicateDictionaryKeysBeforeFoundationMaterialization() {
        XCTAssertThrowsError(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(duplicateKeyPropertyList())
        )
    }

    func testRejectsObjectCountAboveOneMillionBeforeAllocatingOffsetStorage() {
        var data = Data("bplist00".utf8)
        data.append(0x00)
        data.append(8)
        appendTrailer(
            to: &data,
            offsetSize: 1,
            referenceSize: 1,
            objectCount: 1_000_001,
            topObject: 0,
            offsetTable: 9
        )

        XCTAssertThrowsError(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
        )
    }

    func testRejectsReachableOutOfRangeReference() {
        // Object zero is the top-level array and refers to nonexistent object one.
        let data = propertyList(objects: [Data([0xA1, 0x01])], topObject: 0)

        XCTAssertThrowsError(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
        )
    }

    func testRejectsReachableContainerCycle() {
        // Object zero is the top-level array and refers to itself.
        let data = propertyList(objects: [Data([0xA1, 0x00])], topObject: 0)

        XCTAssertThrowsError(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
        )
    }

    func testRejectsDeepAcyclicObjectGraphBeforeFoundationMaterialization() throws {
        var object: Any = "leaf"
        for _ in 0..<256 {
            object = [object]
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: object,
            format: .binary,
            options: 0
        )

        XCTAssertThrowsError(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
        )
    }

    func testRejectsReferenceArrayThatCrossesObjectTableBoundary() {
        // The top dictionary has no key/value reference payload in the object
        // table. Its apparent references (8 and 9) are actually the first two
        // bytes of the offset table. Both happen to be valid object indexes.
        var data = Data("bplist00".utf8)
        data.append(contentsOf: [
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x50, 0x00, 0xD1,
        ])
        let tableStart = data.count
        data.append(contentsOf: (8...18).map(UInt8.init))
        appendTrailer(
            to: &data,
            offsetSize: 1,
            referenceSize: 1,
            objectCount: 11,
            topObject: 10,
            offsetTable: UInt64(tableStart)
        )

        XCTAssertThrowsError(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
        )
    }

    func testDoesNotTraverseMalformedUnreachableCollection() {
        // Object zero is the top scalar. Object one contains an invalid
        // reference but is unreachable from the trailer's topObject.
        let data = propertyList(
            objects: [Data([0x00]), Data([0xA1, 0x09])],
            topObject: 0
        )

        XCTAssertNoThrow(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
        )
    }

    func testRejectsMoreThanTwoHundredFiftyThousandReachableDictionaries() {
        let data = manyDictionariesSharingOneLargeKeyPropertyList(
            dictionaryCount: 250_001,
            keyByteCount: 256
        )

        XCTAssertThrowsError(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
        )
    }

    func testRejectsMoreThanEightMiBOfUniqueDecodedKeyBytes() {
        let data = dictionaryWithUniqueLargeKeysPropertyList(
            keyCount: 8_193,
            keyByteCount: 1_024
        )

        XCTAssertThrowsError(
            try NativeDecompilerWireBinaryPropertyListValidator.validate(data)
        )
    }
}

private extension NativeDecompilerWireBinaryPropertyListValidatorTests {
    func duplicateKeyPropertyList() -> Data {
        var data = Data("bplist00".utf8)
        data.append(contentsOf: [0x51, 0x61])
        data.append(contentsOf: [0x10, 0x01])
        data.append(contentsOf: [0x10, 0x02])
        data.append(contentsOf: [0xD2, 0, 0, 1, 2])
        data.append(contentsOf: [8, 10, 12, 14])
        appendTrailer(
            to: &data,
            offsetSize: 1,
            referenceSize: 1,
            objectCount: 4,
            topObject: 3,
            offsetTable: 19
        )
        return data
    }

    func propertyList(objects: [Data], topObject: Int) -> Data {
        precondition(!objects.isEmpty)
        precondition(objects.count <= 0xFF)

        var data = Data("bplist00".utf8)
        var offsets = [Int]()
        offsets.reserveCapacity(objects.count)
        for object in objects {
            offsets.append(data.count)
            data.append(object)
        }

        let tableStart = data.count
        for offset in offsets {
            precondition(offset <= 0xFF)
            data.append(UInt8(offset))
        }
        appendTrailer(
            to: &data,
            offsetSize: 1,
            referenceSize: 1,
            objectCount: UInt64(objects.count),
            topObject: UInt64(topObject),
            offsetTable: UInt64(tableStart)
        )
        return data
    }

    func manyDictionariesSharingOneLargeKeyPropertyList(
        dictionaryCount: Int,
        keyByteCount: Int
    ) -> Data {
        let referenceSize = 3
        let objectCount = dictionaryCount + 3
        var data = Data("bplist00".utf8)
        data.reserveCapacity(8 + keyByteCount + dictionaryCount * 10)
        var offsets = [Int]()
        offsets.reserveCapacity(objectCount)

        offsets.append(data.count)
        appendASCIIString(Data(repeating: 0x6B, count: keyByteCount), to: &data)

        offsets.append(data.count)
        data.append(0x00)

        for _ in 0..<dictionaryCount {
            offsets.append(data.count)
            data.append(0xD1)
            appendInteger(0, byteCount: referenceSize, to: &data)
            appendInteger(1, byteCount: referenceSize, to: &data)
        }

        let topObject = offsets.count
        offsets.append(data.count)
        appendCollectionCount(dictionaryCount, kind: 0xA, to: &data)
        for dictionaryIndex in 0..<dictionaryCount {
            appendInteger(UInt64(dictionaryIndex + 2), byteCount: referenceSize, to: &data)
        }

        let tableStart = data.count
        for offset in offsets {
            appendInteger(UInt64(offset), byteCount: 3, to: &data)
        }
        appendTrailer(
            to: &data,
            offsetSize: 3,
            referenceSize: referenceSize,
            objectCount: UInt64(objectCount),
            topObject: UInt64(topObject),
            offsetTable: UInt64(tableStart)
        )
        return data
    }

    func dictionaryWithUniqueLargeKeysPropertyList(
        keyCount: Int,
        keyByteCount: Int
    ) -> Data {
        let referenceSize = 2
        let objectCount = keyCount + 2
        var data = Data("bplist00".utf8)
        data.reserveCapacity(8 + keyCount * (keyByteCount + 8))
        var offsets = [Int]()
        offsets.reserveCapacity(objectCount)

        for index in 0..<keyCount {
            offsets.append(data.count)
            let prefix = Data(String(format: "%08x", index).utf8)
            var key = Data()
            key.reserveCapacity(keyByteCount)
            key.append(prefix)
            key.append(Data(repeating: 0x6B, count: keyByteCount - prefix.count))
            appendASCIIString(key, to: &data)
        }

        let valueObject = offsets.count
        offsets.append(data.count)
        data.append(0x00)

        let topObject = offsets.count
        offsets.append(data.count)
        appendCollectionCount(keyCount, kind: 0xD, to: &data)
        for keyIndex in 0..<keyCount {
            appendInteger(UInt64(keyIndex), byteCount: referenceSize, to: &data)
        }
        for _ in 0..<keyCount {
            appendInteger(UInt64(valueObject), byteCount: referenceSize, to: &data)
        }

        let tableStart = data.count
        for offset in offsets {
            appendInteger(UInt64(offset), byteCount: 3, to: &data)
        }
        appendTrailer(
            to: &data,
            offsetSize: 3,
            referenceSize: referenceSize,
            objectCount: UInt64(objectCount),
            topObject: UInt64(topObject),
            offsetTable: UInt64(tableStart)
        )
        return data
    }

    func appendASCIIString(_ bytes: Data, to data: inout Data) {
        appendCollectionCount(bytes.count, kind: 0x5, to: &data)
        data.append(bytes)
    }

    func appendCollectionCount(_ count: Int, kind: UInt8, to data: inout Data) {
        if count < 0x0F {
            data.append(kind << 4 | UInt8(count))
        } else if count <= 0xFF {
            data.append(kind << 4 | 0x0F)
            data.append(0x10)
            appendInteger(UInt64(count), byteCount: 1, to: &data)
        } else if count <= 0xFFFF {
            data.append(kind << 4 | 0x0F)
            data.append(0x11)
            appendInteger(UInt64(count), byteCount: 2, to: &data)
        } else {
            data.append(kind << 4 | 0x0F)
            data.append(0x12)
            appendInteger(UInt64(count), byteCount: 4, to: &data)
        }
    }

    func appendTrailer(
        to data: inout Data,
        offsetSize: Int,
        referenceSize: Int,
        objectCount: UInt64,
        topObject: UInt64,
        offsetTable: UInt64
    ) {
        var trailer = Data(repeating: 0, count: 32)
        trailer[6] = UInt8(offsetSize)
        trailer[7] = UInt8(referenceSize)
        overwriteInteger(objectCount, at: 8, in: &trailer)
        overwriteInteger(topObject, at: 16, in: &trailer)
        overwriteInteger(offsetTable, at: 24, in: &trailer)
        data.append(trailer)
    }

    func appendInteger(_ value: UInt64, byteCount: Int, to data: inout Data) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    func overwriteInteger(_ value: UInt64, at offset: Int, in data: inout Data) {
        for index in 0..<8 {
            let shift = UInt64((7 - index) * 8)
            data[offset + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }
}
