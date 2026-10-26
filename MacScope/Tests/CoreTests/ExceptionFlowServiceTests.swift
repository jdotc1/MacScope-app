import Foundation
import XCTest
@testable import MacScope

final class ExceptionFlowServiceTests: XCTestCase {
    /// One loader admission for this fixture. Other methods use captured values;
    /// mutation cases exercise the parser boundary, without rehashing the fixture.
    private static let captured: Result<LoadedBinary, Error> = Result {
        try MachOBinaryLoader().load(at: TestSourceRoot.url.appendingPathComponent(
            "Scripts/parser-oracles/exception-flow/exception_cases_O1.dylib"))
    }

    func testCompilerFixtureFromLoaderThroughExactAssociationAndLSDA() throws {
        let binary = try Self.captured.get()
        XCTAssertEqual(binary.exceptionMetadataInput?.linkedMachOFileType, 6)
        XCTAssertEqual(binary.exceptionMetadataInput?.encryptedSliceRanges, [])
        let report = try ExceptionFlowService.analyze(binary: binary)
        XCTAssertEqual(report.identity, binary.artifactIdentity)
        XCTAssertEqual(report.functions.map(\.functionRange.lowerBound), [0x5f8, 0x684, 0x6c8, 0x77c])
        XCTAssertEqual(report.functions.map(\.lsda.address), [0x8ec, 0x920, 0x93c, 0x980])
        let first = try XCTUnwrap(report.functions.first)
        XCTAssertEqual(first.functionRange, 0x5f8..<0x684)
        XCTAssertEqual(first.personality, .indirectSlot(0x4010))
        XCTAssertEqual(first.cieSectionOffset, 0)
        XCTAssertEqual(first.fdeSectionOffset, 28)
        XCTAssertEqual(first.lsda.callsites[0].protectedRange, 0x608..<0x60c)
        XCTAssertEqual(first.lsda.callsites[0].landingPad, 0x62c)
        XCTAssertEqual(first.lsda.callsites[0].actionChain, [35, 33, 31])
        XCTAssertEqual(first.lsda.types.map(\.pointer), [.direct(0), .indirectSlot(0x4000), .indirectSlot(0x4008)])
        XCTAssertEqual(report.functions.map { $0.candidates.count }, [4, 3, 7, 2])
        XCTAssertEqual(first.associationSources.count, 3)
        XCTAssertEqual(first.lsdaSource.sliceRange.lowerBound, 0x8ec)
        XCTAssertTrue(first.frontier.contains(.personalityTargetUnresolved))
        XCTAssertTrue(first.frontier.contains(.runtimeTypeMatchingUnknown))
    }

    func testWrongDesignatedFDEAndMalformedPresentCompactRefuse() throws {
        let binary = try Self.captured.get()
        var badFDE = binary
        badFDE.bytes = Data(binary.bytes)
        // The compiler's first common encoding is 0x5300001c; +1 is not an FDE boundary.
        badFDE.bytes.replaceSubrange(2560..<2564, with: [0x1d, 0, 0, 0x53])
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: badFDE))
        var badCompact = binary
        badCompact.bytes = Data(binary.bytes)
        let section = try XCTUnwrap(binary.sections.first { $0.name == "__TEXT,__unwind_info" })
        let offset = Int(section.fileOffset)
        badCompact.bytes.replaceSubrange(offset..<(offset + 4), with: [2, 0, 0, 0])
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: badCompact))
    }

    func testAbsentCompactUsesExactFDEAssociation() throws {
        var binary = try Self.captured.get()
        binary.sections.removeAll { $0.name == "__TEXT,__unwind_info" }
        let report = try ExceptionFlowService.analyze(binary: binary)
        XCTAssertEqual(report.functions.count, 4)
        XCTAssertEqual(report.functions.first?.fdeSectionOffset, 28)
        XCTAssertEqual(report.functions.first?.associationSources.count, 2)
    }

    func testFDERangeMustCoverTheDesignatingCompactRow() throws {
        var binary = try Self.captured.get()
        binary.bytes = Data([UInt8](binary.bytes))
        // First FDE is at 6676; its 8-byte range field begins at +16.
        binary.bytes.replaceSubrange(6692..<6700, with: [0x88, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: binary))
    }

    func testLoaderAdmissionEncryptionAndOverlappingMappingRefuse() throws {
        let binary = try Self.captured.get()
        var missing = binary
        missing.exceptionMetadataInput = nil
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: missing))
        var encrypted = binary
        encrypted.exceptionMetadataInput = .init(linkedMachOFileType: 6, encryptedSliceRanges: [0x8ef..<0x8f0])
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: encrypted))
        var overlapping = binary
        let section = try XCTUnwrap(binary.sections.first { $0.name == "__TEXT,__gcc_except_tab" })
        var duplicate = section
        duplicate.name = "__TEXT,__overlap"
        duplicate.address += 1
        duplicate.size -= 1
        duplicate.fileOffset += 1
        overlapping.sections.append(duplicate)
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: overlapping))
        var inconsistentMapping = binary
        let index = try XCTUnwrap(inconsistentMapping.sections.firstIndex { $0.name == "__TEXT,__gcc_except_tab" })
        inconsistentMapping.sections[index].fileOffset += 1
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: inconsistentMapping))
        var object = binary
        object.exceptionMetadataInput = .init(linkedMachOFileType: 1, encryptedSliceRanges: [])
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: object))
        var unverified = binary
        unverified.artifactIntegrityState = .unavailable
        XCTAssertThrowsError(try ExceptionFlowService.analyze(binary: unverified))
    }
}
