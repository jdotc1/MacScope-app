import XCTest
@testable import MacScope

final class CodeDataEligibilityTests: XCTestCase {
    func testMachOParserProjectsLCDataInCodeToVirtualRanges() throws {
        let bytes = Self.thinMachOWithDataInCode()

        let machO = try MachOParser().parse(bytes)

        XCTAssertEqual(machO.dataInCodeEntries.count, 1)
        let entry = try XCTUnwrap(machO.dataInCodeEntries.first)
        XCTAssertEqual(entry.fileOffset, 0xCC)
        XCTAssertEqual(entry.length, 4)
        XCTAssertEqual(entry.kind, MachOConstants.dataInCodeKindData)
        XCTAssertEqual(entry.kindName, "data")
        XCTAssertEqual(entry.address, 0x1004)
    }

    func testSnapshotExecutableEligibilityRejectsLoaderDataInCodeRanges() {
        let snapshot = Self.snapshotWithDataInCodeRange()

        XCTAssertTrue(snapshot.isExecutableInstructionAddress(.primary(0x1000)))
        XCTAssertFalse(snapshot.isExecutableInstructionAddress(.primary(0x1004)))
        XCTAssertTrue(snapshot.isExecutableInstructionAddress(.primary(0x1008)))
        XCTAssertEqual(snapshot.codeExcludedAddresses(in: .primary), [0x1004])
    }

    func testAnalysisPayloadRoundTripsCodeDataRanges() throws {
        let snapshot = Self.snapshotWithDataInCodeRange()
        let payload = AnalysisPayloadCodec.payload(from: snapshot)
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(AnalysisResultPayload.self, from: encoded)
        let reconstructed = AnalysisPayloadCodec.snapshot(from: decoded)

        XCTAssertEqual(reconstructed.codeDataRanges, snapshot.codeDataRanges)
        XCTAssertFalse(reconstructed.isExecutableInstructionAddress(.primary(0x1004)))
    }

    private static func snapshotWithDataInCodeRange() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [
                BinaryImage(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    name: "InlineData",
                    path: "/tmp/InlineData",
                    kind: "Mach-O executable",
                    architecture: "arm64"
                ),
            ],
            functions: [],
            instructions: [
                InstructionRow(address: 0x1000, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "ef be ad de", mnemonic: "udf", operands: "#0xadef", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1008, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data(),
            sections: [
                SectionSummary(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    name: "__TEXT,__text",
                    address: 0x1000,
                    size: 0x0C,
                    fileOffset: 0xC8,
                    isExecutable: true
                ),
            ],
            codeDataRanges: [
                CodeDataRangeSummary(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    address: 0x1004,
                    size: 4,
                    kind: "data"
                ),
            ],
            imageBytes: Data()
        )
    }

    private static func thinMachOWithDataInCode() -> Data {
        let segmentCommandSize = 72 + 80
        let dataInCodeCommandSize = 16
        let loadCommandsSize = segmentCommandSize + dataInCodeCommandSize
        let codeOffset = 32 + loadCommandsSize
        let code = Data([
            0x1f, 0x20, 0x03, 0xd5, // nop
            0xef, 0xbe, 0xad, 0xde, // inline data
            0xc0, 0x03, 0x5f, 0xd6, // ret
        ])
        let dataInCodeOffset = codeOffset + code.count
        let finalSize = dataInCodeOffset + 8

        var bytes = Data()
        bytes.appendUInt32LE(0xfeedfacf)
        bytes.appendUInt32LE(UInt32(bitPattern: MachOConstants.cpuTypeARM64))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(MachOConstants.fileTypeExecute)
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(UInt32(loadCommandsSize))
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandSegment64)
        bytes.appendUInt32LE(UInt32(segmentCommandSize))
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(0x1000)
        bytes.appendUInt64LE(UInt64(finalSize - codeOffset))
        bytes.appendUInt64LE(UInt64(codeOffset))
        bytes.appendUInt64LE(UInt64(finalSize - codeOffset))
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(5)
        bytes.appendUInt32LE(1)
        bytes.appendUInt32LE(0)

        bytes.appendFixedCString("__text", length: 16)
        bytes.appendFixedCString("__TEXT", length: 16)
        bytes.appendUInt64LE(0x1000)
        bytes.appendUInt64LE(UInt64(code.count))
        bytes.appendUInt32LE(UInt32(codeOffset))
        bytes.appendUInt32LE(2)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(
            MachOConstants.sectionAttributePureInstructions
                | MachOConstants.sectionAttributeSomeInstructions
        )
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)
        bytes.appendUInt32LE(0)

        bytes.appendUInt32LE(MachOConstants.loadCommandDataInCode)
        bytes.appendUInt32LE(UInt32(dataInCodeCommandSize))
        bytes.appendUInt32LE(UInt32(dataInCodeOffset))
        bytes.appendUInt32LE(8)

        bytes.append(code)
        bytes.appendUInt32LE(UInt32(codeOffset + 4))
        bytes.appendUInt16LE(4)
        bytes.appendUInt16LE(MachOConstants.dataInCodeKindData)

        XCTAssertEqual(bytes.count, finalSize)
        return bytes
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        appendUInt32LE(UInt32(value & 0xffff_ffff))
        appendUInt32LE(UInt32((value >> 32) & 0xffff_ffff))
    }

    mutating func appendFixedCString(_ value: String, length: Int) {
        let utf8 = Array(value.utf8.prefix(length))
        append(contentsOf: utf8)
        if utf8.count < length {
            append(contentsOf: repeatElement(UInt8(0), count: length - utf8.count))
        }
    }
}
