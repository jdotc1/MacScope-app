import Foundation
import XCTest
@testable import MacScope

final class SwiftMetadataRuntimeRecordTests: XCTestCase {
    func testAsyncArraysRetainIndependentPartialsAndPointerContext() {
        var b = ImageBuilder()
        b.u32(0)
        let entry = b.count; b.u32(0)
        let resume = b.count; b.u32(0)
        let continuation = b.count; b.u32(0)
        let entrySlot = b.relSlot()
        let resumeSlot = b.relSlot()
        let continuationSlot = b.relSlot()
        let pointer = b.relSlot(); b.u32(32)
        b.patchRel(entrySlot, entry); b.patchRel(resumeSlot, resume)
        b.patchRel(continuationSlot, continuation); b.patchRel(pointer, entry)
        let sections: [SwiftMetadataParser.Section] = [
            .init(name: "__text", address: UInt64(entry), fileOffset: UInt64(entry), size: 12),
            .init(name: "__swift_as_entry", address: UInt64(entrySlot), fileOffset: UInt64(entrySlot), size: 4),
            .init(name: "__swift_as_ret", address: UInt64(resumeSlot), fileOffset: UInt64(resumeSlot), size: 4),
            .init(name: "__swift_as_cont", address: UInt64(continuationSlot), fileOffset: UInt64(continuationSlot), size: 4),
            .init(name: "__const", address: UInt64(pointer), fileOffset: UInt64(pointer), size: 8)
        ]
        let report = SwiftMetadataParser(data: Data(b.data), sections: sections).parseAsyncFunctionsReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.entries.map(\.entryAddress), [UInt64(entry)])
        XCTAssertEqual(report.records.resumePartialAddresses, [UInt64(resume)])
        XCTAssertEqual(report.records.continuationPartialAddresses, [UInt64(continuation)])
        XCTAssertEqual(report.records.entries.first?.pointerRecords,
                       [.init(address: UInt64(pointer), expectedContextSize: 32)])
    }

    func testTruncatedAsyncArrayProducesDiagnostic() {
        let parser = SwiftMetadataParser(data: Data([0, 0, 0]), sections: [
            .init(name: "__swift_as_entry", address: 0, fileOffset: 0, size: 3)
        ])
        let report = parser.parseAsyncFunctionsReport()
        XCTAssertTrue(report.records.entries.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    func testDuplicateAsyncPointerCandidatesRemainExplicit() {
        var b = ImageBuilder()
        b.u32(0); let entry = b.count; b.u32(0)
        let slot = b.relSlot()
        let first = b.relSlot(); b.u32(16)
        let second = b.relSlot(); b.u32(32)
        b.patchRel(slot, entry); b.patchRel(first, entry); b.patchRel(second, entry)
        let report = SwiftMetadataParser(data: Data(b.data), sections: [
            .init(name: "__text", address: UInt64(entry), fileOffset: UInt64(entry), size: 4),
            .init(name: "__swift_as_entry", address: UInt64(slot), fileOffset: UInt64(slot), size: 4),
            .init(name: "__const", address: UInt64(first), fileOffset: UInt64(first), size: 16)
        ]).parseAsyncFunctionsReport()
        XCTAssertEqual(report.records.entries.first?.pointerRecords.count, 2)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    func testSharedAsyncTargetReconcilesArrayAndPointerMultiplicity() {
        var b = ImageBuilder()
        b.u32(0); let entry = b.count; b.u32(0)
        let firstSlot = b.relSlot(); let secondSlot = b.relSlot()
        let first = b.relSlot(); b.u32(32)
        let second = b.relSlot(); b.u32(32)
        b.patchRel(firstSlot, entry); b.patchRel(secondSlot, entry)
        b.patchRel(first, entry); b.patchRel(second, entry)
        let report = SwiftMetadataParser(data: Data(b.data), sections: [
            .init(name: "__text", address: UInt64(entry), fileOffset: UInt64(entry), size: 4),
            .init(name: "__swift_as_entry", address: UInt64(firstSlot), fileOffset: UInt64(firstSlot), size: 8),
            .init(name: "__const", address: UInt64(first), fileOffset: UInt64(first), size: 16)
        ]).parseAsyncFunctionsReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.entries.count, 2)
        XCTAssertEqual(report.records.entryGroups.count, 1)
        XCTAssertEqual(report.records.entryGroups.first?.entryCount, 2)
        XCTAssertEqual(report.records.entryGroups.first?.pointerRecords.map(\.address), [UInt64(first), UInt64(second)])
    }

    func testEnumWitnessDiscoveryDoesNotChangeNominalMetadataCandidates() {
        let fixture = witnessImage(kind: 0x201, descriptorKind: 18, flags: 0x00210007)
        let parser = SwiftMetadataParser(data: fixture.data, sections: fixture.sections,
                                         metadataAddresses: [fixture.metadata])
        let original = parser.parseTypes()
        let report = parser.parseValueWitnessSummariesReport()
        XCTAssertEqual(parser.parseTypes(), original)
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.count, 1)
        let record = report.records.first
        XCTAssertEqual(record?.typeName, "E")
        XCTAssertEqual(record?.size, 9)
        XCTAssertEqual(record?.stride, 16)
        XCTAssertEqual(record?.alignment, 8)
        XCTAssertEqual(record?.extraInhabitantCount, 7)
        XCTAssertEqual(record?.isPOD, false)
        XCTAssertEqual(record?.isBitwiseTakable, true)
        XCTAssertEqual(record?.hasEnumWitnesses, true)
        XCTAssertEqual(record?.isIncomplete, false)
    }

    func testClassWitnessDiscoveryUsesDarwinClassDescriptorOffset() {
        let fixture = witnessImage(kind: 0, descriptorKind: 16, flags: 7)
        let report = SwiftMetadataParser(data: fixture.data, sections: fixture.sections,
                                         metadataAddresses: [fixture.metadata]).parseValueWitnessSummariesReport()
        XCTAssertTrue(report.diagnostics.isEmpty)
        XCTAssertEqual(report.records.first?.alignment, 8)
    }

    func testTruncatedWitnessTableProducesDiagnostic() {
        let fixture = witnessImage(kind: 0x201, descriptorKind: 18, flags: 0, tableBytes: 84)
        let report = SwiftMetadataParser(data: fixture.data, sections: fixture.sections,
                                         metadataAddresses: [fixture.metadata]).parseValueWitnessSummariesReport()
        XCTAssertTrue(report.records.isEmpty)
        XCTAssertEqual(report.diagnostics.count, 1)
    }

    private func witnessImage(kind: UInt64, descriptorKind: UInt32, flags: UInt32, tableBytes: Int = 112)
        -> (data: Data, sections: [SwiftMetadataParser.Section], metadata: UInt64) {
        var b = ImageBuilder()
        b.u32(0)
        let name = b.cstring("E"); b.align(4)
        let descriptor = b.count
        b.u32(descriptorKind); b.u32(0)
        let nameSlot = b.relSlot(); b.u32(0); b.u32(0)
        b.patchRel(nameSlot, name)
        b.align(8)
        let table = b.count
        for _ in 0..<8 { b.u32(0); b.u32(0) }
        b.u32(9); b.u32(0); b.u32(16); b.u32(0); b.u32(flags); b.u32(7)
        for _ in 0..<6 { b.u32(0) }
        b.u32(UInt32(table)); b.u32(0)
        let metadata = b.count
        b.u32(UInt32(kind)); b.u32(UInt32(kind >> 32))
        if descriptorKind == 16 { for _ in 0..<14 { b.u32(0) } }
        b.u32(UInt32(descriptor)); b.u32(0)
        let tableEnd = table + 112
        let sections: [SwiftMetadataParser.Section] = [
            .init(name: "__constg_swiftt", address: 0, fileOffset: 0, size: UInt64(table)),
            .init(name: "__const", address: UInt64(table), fileOffset: UInt64(table), size: UInt64(tableBytes)),
            .init(name: "__data", address: UInt64(tableEnd), fileOffset: UInt64(tableEnd), size: UInt64(b.count - tableEnd))
        ]
        return (Data(b.data), sections, UInt64(metadata))
    }
}
