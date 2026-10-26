import Foundation
import XCTest
@testable import MacScope

final class SwiftMetadataReflectionRecordsTests: XCTestCase {
    func testCapturePreservesMetadataSourcePairsAndBindings() {
        var image = ImageBuilder()
        image.u32(1); image.u32(1); image.u32(2)
        let capture = image.relSlot(), sourceType = image.relSlot(), source = image.relSlot()
        let length = image.count
        image.patchString(capture, "Si")
        image.patchString(sourceType, "SS")
        image.patchString(source, "B0")
        let report = image.parser(section: "__swift5_capture", length: length).parseCaptureDescriptorsReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.records.first?.captureTypeNames, ["Int"])
        XCTAssertEqual(report.records.first?.metadataSources.first?.typeName, "String")
        XCTAssertEqual(report.records.first?.metadataSources.first?.sourceName, "B0")
        XCTAssertEqual(report.records.first?.numBindings, 2)
    }

    func testTruncatedCaptureProducesDiagnostic() {
        var image = ImageBuilder()
        image.u32(1); image.u32(0); image.u32(0)
        let report = image.parser(section: "__swift5_capture").parseCaptureDescriptorsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    func testAssociatedTypesHonorEmittedRecordStride() {
        var image = ImageBuilder()
        let conforming = image.relSlot(), proto = image.relSlot()
        image.u32(2); image.u32(12)
        let name1 = image.relSlot(), type1 = image.relSlot(); image.u32(0xdeadbeef)
        let name2 = image.relSlot(), type2 = image.relSlot(); image.u32(0xdeadbeef)
        let length = image.count
        image.patchString(conforming, "4Demo1SV")
        image.patchString(proto, "4Demo1PP")
        image.patchString(name1, "A"); image.patchString(type1, "Si")
        image.patchString(name2, "B"); image.patchString(type2, "SS")
        let report = image.parser(section: "__swift5_assocty", length: length).parseAssociatedTypesReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.records.first?.associatedTypes.map(\.name), ["A", "B"])
        XCTAssertEqual(report.records.first?.associatedTypes.map(\.substitutedTypeName), ["Int", "String"])
    }

    func testTruncatedAssociatedTypeProducesDiagnostic() {
        var image = ImageBuilder()
        image.u32(1); image.u32(1); image.u32(1); image.u32(8)
        let report = image.parser(section: "__swift5_assocty").parseAssociatedTypesReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    func testAssociatedTypeStrideBelowMinimumProducesDiagnostic() {
        var image = ImageBuilder()
        image.u32(1); image.u32(1); image.u32(1); image.u32(4); image.u32(0)
        let report = image.parser(section: "__swift5_assocty").parseAssociatedTypesReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    func testBuiltinTypePreservesLayoutAndFlags() {
        var image = ImageBuilder()
        let type = image.relSlot()
        image.u32(7); image.u32(0x10008); image.u32(8); image.u32(3)
        let length = image.count
        image.patchString(type, "Si")
        let report = image.parser(section: "__swift5_builtin", length: length).parseBuiltinTypesReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.first?.typeName, "Int")
        XCTAssertEqual(report.records.first?.size, 7)
        XCTAssertEqual(report.records.first?.alignmentAndFlags, 0x10008)
        XCTAssertEqual(report.records.first?.stride, 8)
        XCTAssertEqual(report.records.first?.extraInhabitantCount, 3)
    }

    func testTruncatedBuiltinTypeProducesDiagnostic() {
        var image = ImageBuilder()
        image.u32(1); image.u32(8); image.u32(8); image.u32(8)
        let report = image.parser(section: "__swift5_builtin").parseBuiltinTypesReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    func testMultiPayloadEnumReadsMaskCountAndSkipsMaskPadding() {
        var image = ImageBuilder()
        let type = image.relSlot()
        image.u32(0x30001); image.u32(0x20003); image.u32(0x00ffffff)
        let secondType = image.relSlot(); image.u32(0x10000)
        let length = image.count
        image.patchString(type, "4Demo1EO")
        image.patchString(secondType, "4Demo1FO")
        let report = image.parser(section: "__swift5_mpenum", length: length).parseMultiPayloadEnumsReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.map(\.maskByteCount), [3, 0])
    }

    func testTruncatedMultiPayloadEnumProducesDiagnostic() {
        var image = ImageBuilder()
        image.u32(1); image.u32(0x30001); image.u32(3)
        let report = image.parser(section: "__swift5_mpenum").parseMultiPayloadEnumsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    func testMultiPayloadEnumRejectsMaskLargerThanRecord() {
        var image = ImageBuilder()
        image.u32(1); image.u32(0x20001); image.u32(9)
        let report = image.parser(section: "__swift5_mpenum").parseMultiPayloadEnumsReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
    }
}

private extension ImageBuilder {
    mutating func patchString(_ slot: Int, _ value: String) {
        let target = cstring(value)
        patchRel(slot, target)
    }
    func parser(section: String, length: Int? = nil) -> SwiftMetadataParser {
        let length = length ?? count
        var sections: [SwiftMetadataParser.Section] = [
            .init(name: section, address: 0, fileOffset: 0, size: UInt64(length))
        ]
        if count > length {
            sections.append(.init(name: "__swift5_typeref", address: UInt64(length),
                                  fileOffset: UInt64(length), size: UInt64(count - length)))
        }
        return SwiftMetadataParser(data: Data(data), sections: sections)
    }
}
