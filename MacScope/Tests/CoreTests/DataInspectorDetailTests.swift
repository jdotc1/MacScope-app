import Foundation
import XCTest
@testable import MacScope

/// Tests for the deepened data inspector: the pure endianness/radix/signedness value
/// formatter and the pure address-detail resolver. Both keep all logic GUI-free, so
/// these exercise them directly without a SwiftUI host.
final class DataInspectorDetailTests: XCTestCase {

    // MARK: - Value formatter: byte order

    func testFormatterAssemblesLittleAndBigEndian() {
        // 0x12 0x34 -> LE 0x3412, BE 0x1234.
        let bytes = Data([0x12, 0x34])
        let little = DataValueFormatter(
            bytes: bytes, offset: 0,
            options: DataValueFormatOptions(byteOrder: .little, radix: .hex, signedness: .unsigned)
        )
        let big = DataValueFormatter(
            bytes: bytes, offset: 0,
            options: DataValueFormatOptions(byteOrder: .big, radix: .hex, signedness: .unsigned)
        )
        XCTAssertEqual(little.integer(width: .int16), "0x3412")
        XCTAssertEqual(big.integer(width: .int16), "0x1234")
    }

    func testFormatterByteOrderDoesNotAffectSingleByte() {
        let bytes = Data([0xAB])
        for order in DataByteOrder.allCases {
            let f = DataValueFormatter(
                bytes: bytes, offset: 0,
                options: DataValueFormatOptions(byteOrder: order, radix: .hex, signedness: .unsigned)
            )
            XCTAssertEqual(f.integer(width: .int8), "0xab", "8-bit value is order-invariant")
        }
    }

    // MARK: - Value formatter: radix

    func testFormatterRendersAllRadices() {
        // 42 = 0x2a = 0o52 = 0b101010.
        let bytes = Data([0x2A])
        func render(_ radix: DataRadix) -> String? {
            DataValueFormatter(
                bytes: bytes, offset: 0,
                options: DataValueFormatOptions(byteOrder: .little, radix: radix, signedness: .unsigned)
            ).integer(width: .int8)
        }
        XCTAssertEqual(render(.decimal), "42")
        XCTAssertEqual(render(.hex), "0x2a")
        XCTAssertEqual(render(.octal), "0o52")
        XCTAssertEqual(render(.binary), "0b101010")
    }

    // MARK: - Value formatter: signedness

    func testFormatterSignednessAcrossWidths() {
        // All-0xFF window: signed -1 at every width, unsigned the full magnitude.
        let bytes = Data(repeating: 0xFF, count: 8)
        func decimal(_ width: DataIntegerWidth, _ sign: DataSignedness) -> String? {
            DataValueFormatter(
                bytes: bytes, offset: 0,
                options: DataValueFormatOptions(byteOrder: .little, radix: .decimal, signedness: sign)
            ).integer(width: width)
        }
        XCTAssertEqual(decimal(.int8, .signed), "-1")
        XCTAssertEqual(decimal(.int8, .unsigned), "255")
        XCTAssertEqual(decimal(.int16, .signed), "-1")
        XCTAssertEqual(decimal(.int16, .unsigned), "65535")
        XCTAssertEqual(decimal(.int32, .signed), "-1")
        XCTAssertEqual(decimal(.int32, .unsigned), "4294967295")
        XCTAssertEqual(decimal(.int64, .signed), "-1")
        XCTAssertEqual(decimal(.int64, .unsigned), "18446744073709551615")
    }

    func testFormatterSignedNegativeInNonDecimalRadices() {
        // 0xFF as signed Int8 = -1: a leading minus is applied even in hex/oct/bin,
        // rendering the magnitude (1).
        let bytes = Data([0xFF])
        func render(_ radix: DataRadix) -> String? {
            DataValueFormatter(
                bytes: bytes, offset: 0,
                options: DataValueFormatOptions(byteOrder: .little, radix: radix, signedness: .signed)
            ).integer(width: .int8)
        }
        XCTAssertEqual(render(.hex), "-0x1")
        XCTAssertEqual(render(.octal), "-0o1")
        XCTAssertEqual(render(.binary), "-0b1")
        XCTAssertEqual(render(.decimal), "-1")
    }

    func testFormatterHandlesMostNegativeWithoutTrapping() {
        // 0x80 signed Int8 is -128; its magnitude (128) overflows Int8 but the
        // UInt64-magnitude path must not trap.
        let bytes = Data([0x80])
        let signed = DataValueFormatter(
            bytes: bytes, offset: 0,
            options: DataValueFormatOptions(byteOrder: .little, radix: .decimal, signedness: .signed)
        )
        XCTAssertEqual(signed.integer(width: .int8), "-128")

        // Most-negative Int64 = 0x8000000000000000.
        var bytes64 = Data(repeating: 0x00, count: 8)
        bytes64[7] = 0x80
        let signed64 = DataValueFormatter(
            bytes: bytes64, offset: 0,
            options: DataValueFormatOptions(byteOrder: .little, radix: .decimal, signedness: .signed)
        )
        XCTAssertEqual(signed64.integer(width: .int64), "-9223372036854775808")
    }

    // MARK: - Value formatter: floats are format-agnostic

    func testFormatterDecodesFloatAndDoubleRegardlessOfRadix() {
        // Float 1.0 = 0x3F800000 LE.
        let floatBytes = Data([0x00, 0x00, 0x80, 0x3F])
        for radix in DataRadix.allCases {
            let f = DataValueFormatter(
                bytes: floatBytes, offset: 0,
                options: DataValueFormatOptions(byteOrder: .little, radix: radix, signedness: .unsigned)
            )
            XCTAssertEqual(f.float32.flatMap(Float.init), 1.0)
        }
        // Big-endian float 1.0.
        let beFloat = DataValueFormatter(
            bytes: Data([0x3F, 0x80, 0x00, 0x00]), offset: 0,
            options: DataValueFormatOptions(byteOrder: .big, radix: .hex, signedness: .signed)
        )
        XCTAssertEqual(beFloat.float32.flatMap(Float.init), 1.0)

        // Double 1.0 = 0x3FF0000000000000 LE.
        let doubleBytes = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F])
        let d = DataValueFormatter(
            bytes: doubleBytes, offset: 0,
            options: DataValueFormatOptions(byteOrder: .little, radix: .octal, signedness: .unsigned)
        )
        XCTAssertEqual(d.double64.flatMap(Double.init), 1.0)
    }

    // MARK: - Value formatter: truncation / bounds / overflow hardening

    func testFormatterTruncatesWhenBytesDoNotFit() {
        // Only two bytes available: 16-bit fits, 32/64 and float/double do not.
        let bytes = Data([0x2A, 0x00])
        let f = DataValueFormatter(
            bytes: bytes, offset: 0,
            options: DataValueFormatOptions(byteOrder: .little, radix: .decimal, signedness: .unsigned)
        )
        XCTAssertEqual(f.integer(width: .int8), "42")
        XCTAssertEqual(f.integer(width: .int16), "42")
        XCTAssertNil(f.integer(width: .int32))
        XCTAssertNil(f.integer(width: .int64))
        XCTAssertNil(f.float32)
        XCTAssertNil(f.double64)

        let labels = f.rows.map(\.label)
        XCTAssertTrue(labels.contains("UInt16"))
        XCTAssertFalse(labels.contains("UInt32"))
        XCTAssertFalse(labels.contains("Float"))
    }

    func testFormatterRowLabelsTrackSignedness() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let signed = DataValueFormatter(
            bytes: bytes, offset: 0,
            options: DataValueFormatOptions(byteOrder: .little, radix: .decimal, signedness: .signed)
        )
        XCTAssertEqual(Array(signed.rows.prefix(4).map(\.label)), ["Int8", "Int16", "Int32", "Int64"])
        let unsigned = DataValueFormatter(
            bytes: bytes, offset: 0,
            options: DataValueFormatOptions(byteOrder: .little, radix: .decimal, signedness: .unsigned)
        )
        XCTAssertEqual(Array(unsigned.rows.prefix(4).map(\.label)), ["UInt8", "UInt16", "UInt32", "UInt64"])
    }

    func testFormatterIsUnresolvableForNilAndOutOfRangeOffset() {
        let bytes = Data([0x2A])
        XCTAssertFalse(
            DataValueFormatter(bytes: bytes, offset: nil,
                               options: DataValueFormatOptions()).isResolvable
        )
        // Offset at the count is out of range; bitPattern must return nil, not trap.
        let past = DataValueFormatter(bytes: bytes, offset: 1, options: DataValueFormatOptions())
        XCTAssertNil(past.integer(width: .int8))
        XCTAssertNil(past.bitPattern(byteCount: 1))
    }

    func testFormatterByteOffsetGuardsAgainstUInt64ToIntOverflow() {
        // A selected address far above base whose delta overflows Int must yield nil,
        // never trap the Int() cast.
        let offset = DataValueFormatter.byteOffset(
            byteCount: 16,
            baseAddress: 0,
            selectedAddress: UInt64(Int.max) + 100
        )
        XCTAssertNil(offset)

        // selectedAddress < baseAddress -> nil (no negative offset).
        XCTAssertNil(
            DataValueFormatter.byteOffset(byteCount: 16, baseAddress: 0x2000, selectedAddress: 0x1000)
        )
        // In-window mapping resolves.
        XCTAssertEqual(
            DataValueFormatter.byteOffset(byteCount: 16, baseAddress: 0x1000, selectedAddress: 0x1004),
            4
        )
    }

    func testFormatterMaskAndSignedMagnitudeHelpers() {
        // mask narrows; full width is a no-op.
        XCTAssertEqual(DataValueFormatter.mask(0xFFFF, byteCount: 1), 0xFF)
        XCTAssertEqual(DataValueFormatter.mask(0xDEAD_BEEF_CAFE_BABE, byteCount: 8), 0xDEAD_BEEF_CAFE_BABE)
        // signedMagnitude of 0x80 at one byte = (negative, 128).
        let (neg, mag) = DataValueFormatter.signedMagnitude(0x80, byteCount: 1)
        XCTAssertTrue(neg)
        XCTAssertEqual(mag, 128)
        // Positive value passes through.
        let (neg2, mag2) = DataValueFormatter.signedMagnitude(0x7F, byteCount: 1)
        XCTAssertFalse(neg2)
        XCTAssertEqual(mag2, 0x7F)
    }

    // MARK: - Address-detail resolver

    private func detailSnapshot() -> WorkspaceSnapshot {
        let textSection = SectionSummary(
            id: UUID(), name: "__text", address: 0x1000, size: 0x400,
            fileOffset: 0x1000, isExecutable: true
        )
        let dataSection = SectionSummary(
            id: UUID(), name: "__data", address: 0x2000, size: 0x100,
            fileOffset: 0x2000, isExecutable: false
        )
        let alpha = FunctionSummary(id: UUID(), name: "_alpha", startAddress: 0x1000, endAddress: 0x1040, confidence: 1)
        let beta = FunctionSummary(id: UUID(), name: "_beta", startAddress: 0x1040, endAddress: 0x1080, confidence: 1)
        let symbol = SymbolSummary(id: UUID(), name: "_gGlobal", address: 0x2000, kind: "data", libraryName: nil)
        var snapshot = WorkspaceSnapshot(
            binaries: [],
            functions: [alpha, beta],
            instructions: [],
            xrefs: [
                XRef(id: UUID(), from: 0x1004, to: 0x1040, kind: "call"),
                XRef(id: UUID(), from: 0x1008, to: 0x1040, kind: "call"),
                XRef(id: UUID(), from: 0x1040, to: 0x2000, kind: "data"),
            ],
            hexBytes: Data()
        )
        snapshot.symbols = [symbol]
        snapshot.sections = [textSection, dataSection]
        return snapshot
    }

    func testAddressDetailResolvesSectionAndExactSymbol() {
        let snapshot = detailSnapshot()
        let atAlpha = AddressDetailReading(address: 0x1000, snapshot: snapshot)
        XCTAssertEqual(atAlpha.section?.name, "__text")
        XCTAssertTrue(atAlpha.isInSection)
        XCTAssertEqual(atAlpha.nearestSymbolName, "_alpha")
        XCTAssertEqual(atAlpha.nearestSymbolOffset, 0)
        XCTAssertEqual(atAlpha.symbolWithOffset, "_alpha")
    }

    func testAddressDetailResolvesNearestSymbolWithOffset() {
        let snapshot = detailSnapshot()
        // 0x1014 is inside _alpha (0x1000..0x1040): nearest symbol _alpha+0x14.
        let interior = AddressDetailReading(address: 0x1014, snapshot: snapshot)
        XCTAssertEqual(interior.nearestSymbolName, "_alpha")
        XCTAssertEqual(interior.nearestSymbolOffset, 0x14)
        XCTAssertEqual(interior.symbolWithOffset, "_alpha+0x14")
        XCTAssertEqual(interior.section?.name, "__text")
    }

    func testAddressDetailPicksHighestLandmarkAtOrBefore() {
        let snapshot = detailSnapshot()
        // 0x1050 is past _beta's start (0x1040): nearest is _beta, not _alpha.
        let inBeta = AddressDetailReading(address: 0x1050, snapshot: snapshot)
        XCTAssertEqual(inBeta.nearestSymbolName, "_beta")
        XCTAssertEqual(inBeta.nearestSymbolOffset, 0x10)
    }

    func testAddressDetailCountsBidirectionalXrefs() {
        let snapshot = detailSnapshot()
        // 0x1040 (_beta start) has two refs to it and one ref from it.
        let beta = AddressDetailReading(address: 0x1040, snapshot: snapshot)
        XCTAssertEqual(beta.referencesToCount, 2)
        XCTAssertEqual(beta.referencesFromCount, 1)
    }

    func testAddressDetailUsesRequestedImageSlotForCollidingAddresses() {
        let siblingSlot = ImageSlot(rawValue: 1)
        let primaryBinary = BinaryImage(
            id: UUID(), name: "primary", path: "/tmp/primary",
            kind: "executable", architecture: "arm64", slot: .primary
        )
        let siblingBinary = BinaryImage(
            id: UUID(), name: "sibling", path: "/tmp/sibling",
            kind: "executable", architecture: "arm64", slot: siblingSlot
        )

        var primary = ImageAnalysis()
        primary.functions = [
            FunctionSummary(id: UUID(), name: "_primary", startAddress: 0x1000, endAddress: 0x1040, confidence: 1)
        ]
        primary.sections = [
            SectionSummary(id: UUID(), name: "__primary", address: 0x1000, size: 0x100, fileOffset: 0, isExecutable: true)
        ]
        primary.xrefs = [
            XRef(id: UUID(), from: 0x2000, to: 0x1000, kind: "call")
        ]

        var sibling = ImageAnalysis()
        sibling.functions = [
            FunctionSummary(id: UUID(), name: "_sibling", startAddress: 0x1000, endAddress: 0x1040, confidence: 1)
        ]
        sibling.sections = [
            SectionSummary(id: UUID(), name: "__sibling", address: 0x1000, size: 0x100, fileOffset: 0, isExecutable: true)
        ]
        sibling.xrefs = [
            XRef(id: UUID(), from: 0x3000, to: 0x1000, kind: "call"),
            XRef(id: UUID(), from: 0x3004, to: 0x1000, kind: "call"),
        ]

        let snapshot = WorkspaceSnapshot(
            binaries: [primaryBinary, siblingBinary],
            analysisBySlot: [.primary: primary, siblingSlot: sibling],
            addressOverrides: [
                .primary(0x1000): AddressOverride(customName: "primaryName"),
                ImageAddress(slot: siblingSlot, address: 0x1000): AddressOverride(
                    customName: "focusedSibling",
                    isData: true
                ),
            ]
        )

        let reading = AddressDetailReading(
            address: 0x1000,
            snapshot: snapshot,
            imageSlot: siblingSlot
        )

        XCTAssertEqual(reading.section?.name, "__sibling")
        XCTAssertEqual(reading.nearestSymbolName, "focusedSibling")
        XCTAssertEqual(reading.appliedName, "focusedSibling")
        XCTAssertTrue(reading.isMarkedAsData)
        XCTAssertEqual(reading.referencesToCount, 2)
    }

    func testAddressDetailSurfacesOverrideNameTypeTagAndData() {
        var snapshot = detailSnapshot()
        snapshot.typeDefinitions = [
            TypeDefinition(kind: .struct, name: "Header", fields: [FieldDef(name: "magic", type: "uint32_t")])
        ]
        snapshot.addressOverrides[.primary(0x2000)] = AddressOverride(
            customName: "frameHeader",
            customComment: "parsed lazily",
            tag: "parser",
            isData: true,
            appliedTypeName: "Header"
        )
        let reading = AddressDetailReading(address: 0x2000, snapshot: snapshot)
        XCTAssertEqual(reading.appliedName, "frameHeader")
        XCTAssertEqual(reading.appliedComment, "parsed lazily")
        XCTAssertEqual(reading.appliedTag, "parser")
        XCTAssertEqual(reading.appliedTypeName, "Header")
        XCTAssertTrue(reading.isMarkedAsData)
        XCTAssertTrue(reading.hasOverride)

        let labels = reading.rows.map(\.label)
        XCTAssertTrue(labels.contains("Name"))
        XCTAssertTrue(labels.contains("Type"))
        XCTAssertTrue(labels.contains("Tag"))
        XCTAssertTrue(labels.contains("Kind"))
        XCTAssertTrue(labels.contains("Comment"))
    }

    func testAddressDetailDanglingTypeNameDegradesToNil() {
        var snapshot = detailSnapshot()
        // Applied type references a name that no longer exists in the catalog.
        snapshot.addressOverrides[.primary(0x2000)] = AddressOverride(appliedTypeName: "GhostType")
        let reading = AddressDetailReading(address: 0x2000, snapshot: snapshot)
        XCTAssertNil(reading.appliedTypeName)
    }

    func testAddressDetailDegradesForAddressOutsideAnySection() {
        let snapshot = detailSnapshot()
        // 0x9000 is past every section and every landmark.
        let outside = AddressDetailReading(address: 0x9000, snapshot: snapshot)
        XCTAssertNil(outside.section)
        XCTAssertFalse(outside.isInSection)
        // The highest landmark at-or-before 0x9000 is the _gGlobal symbol at 0x2000.
        XCTAssertEqual(outside.nearestSymbolName, "_gGlobal")
        XCTAssertEqual(outside.referencesToCount, 0)
        XCTAssertEqual(outside.referencesFromCount, 0)
        // Section row still renders, as "(none)".
        XCTAssertEqual(outside.rows.first { $0.label == "Section" }?.value, "(none)")
    }

    func testAddressDetailBelowEveryLandmarkHasNoSymbol() {
        let snapshot = detailSnapshot()
        // 0x0800 precedes every function and symbol.
        let low = AddressDetailReading(address: 0x0800, snapshot: snapshot)
        XCTAssertNil(low.nearestSymbolName)
        XCTAssertNil(low.symbolWithOffset)
        XCTAssertNil(low.section)
    }

    func testAddressDetailSectionContainmentDoesNotWrapOnMalformedSize() {
        // A section whose address+size overflows UInt64 must not spuriously contain
        // a low address below its start.
        let evil = SectionSummary(
            id: UUID(), name: "__evil", address: 0xFFFF_FFFF_FFFF_FF00, size: 0x400,
            fileOffset: 0, isExecutable: false
        )
        let result = AddressDetailReading.section(containing: 0x10, in: [evil])
        XCTAssertNil(result, "Low address must not match an overflowing high section")
        // An address at-or-above the overflowing section's start still matches.
        XCTAssertEqual(
            AddressDetailReading.section(containing: 0xFFFF_FFFF_FFFF_FFF0, in: [evil])?.name,
            "__evil"
        )
    }

    func testAddressDetailRowsAlwaysIncludeAddressSectionAndRefCounts() {
        let snapshot = detailSnapshot()
        let reading = AddressDetailReading(address: 0x1000, snapshot: snapshot)
        let labels = reading.rows.map(\.label)
        XCTAssertTrue(labels.contains("Address"))
        XCTAssertTrue(labels.contains("Section"))
        XCTAssertTrue(labels.contains("Refs to"))
        XCTAssertTrue(labels.contains("Refs from"))
        XCTAssertEqual(reading.rows.first { $0.label == "Address" }?.value, UInt64(0x1000).hexAddress)
    }
}
