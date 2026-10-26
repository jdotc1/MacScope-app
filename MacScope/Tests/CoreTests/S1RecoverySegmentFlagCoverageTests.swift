import Foundation
import XCTest
@testable import MacScope

/// Exercises the existing production coverage API with real Mach-O bytes.
/// SG_READ_ONLY changes post-fixup permissions, not the linear file/VM mapping.
/// Its positive assertion must execute as behavioral red before the audit fix.
final class S1RecoverySegmentFlagCoverageTests: XCTestCase {
    private let options = MachOParseOptions(recoverStringLiterals: false,
        recoverObjectiveCMetadata: false, recoverSwiftMetadata: false, parseCodeSignature: false)

    private func fixture() -> Data {
        S1SegmentFlagMachOFixture.make(bodies: [
            0x1000: ("caller", [0xa9bf7bfd, 0x94000004, 0xd2800000, 0xa8c17bfd, 0xd65f03c0]),
            0x1014: ("leaf", [0xf9400008, 0xf9000028, 0xd65f03c0])
        ], exported: [], extraSections: [
            .init(segmentName: "__DATA_CONST", sectionName: "__const", address: 0x3000,
                  bytes: Data(repeating: 0, count: 16))
        ])
    }

    private func segmentCommand(in bytes: Data) throws -> Int {
        let file = try MachOParser().parse(bytes, options: options)
        let segments = file.loadCommands.filter { $0.command == 0x19 }
        let index = try XCTUnwrap(file.segments.firstIndex { $0.name == "__DATA_CONST" })
        return Int(segments[index].offset)
    }

    private func put(_ value: UInt64, at offset: Int, width: Int = 4, in bytes: inout Data) {
        for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    @discardableResult
    private func assertReadOnlyComplete(file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        var bytes = fixture()
        let command = try segmentCommand(in: bytes)
        put(0x10, at: command + 68, in: &bytes)
        let parsed = try MachOParser().parseWithFixupCoverage(bytes, options: options)
        XCTAssertEqual(parsed.file.segments.first { $0.name == "__DATA_CONST" }?.flags, 0x10,
                       file: file, line: line)
        XCTAssertEqual(parsed.file.functionStarts.map(\.address), [0x1000, 0x1014], file: file, line: line)
        let coverage = parsed.coverage
        XCTAssertTrue(coverage.isComplete && coverage.symbolInventoryIsComplete
            && coverage.exportInventoryIsComplete && coverage.functionStartsInventoryIsComplete
            && coverage.dataInCodeInventoryIsComplete,
            "SG_READ_ONLY must preserve otherwise complete declared coverage; refusals: \(coverage.refusalReasons)",
            file: file, line: line)
        return bytes
    }

    private func assertMappingRefused(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let parsed = try MachOParser().parseWithFixupCoverage(bytes, options: options)
        XCTAssertFalse(parsed.coverage.isComplete, file: file, line: line)
        XCTAssertTrue(parsed.coverage.refusalReasons.contains(.invalidMapping), file: file, line: line)
    }

    func testReadOnlySegmentAdmitsCoverageButUnsupportedFlagsDoNot() throws {
        let positive = try assertReadOnlyComplete()
        let command = try segmentCommand(in: positive)
        // Unknown bit, SG_HIGHVM (mapping-changing), and protected bytes remain unsupported.
        for flags in [UInt64(0x80000010), 0x11, 0x18] {
            var bytes = positive
            put(flags, at: command + 68, in: &bytes)
            try assertMappingRefused(bytes)
        }
    }

    func testReadOnlySegmentDoesNotBypassExtentOwnershipOrLinearMapping() throws {
        let positive = try assertReadOnlyComplete()
        let command = try segmentCommand(in: positive)
        var tooSmallVM = positive
        put(8, at: command + 32, width: 8, in: &tooSmallVM)
        try assertMappingRefused(tooSmallVM)

        var missingOwner = positive
        missingOwner[command + 88] = 0x58 // X: no matching segment owner
        try assertMappingRefused(missingOwner)

        var nonlinear = positive
        let file = try MachOParser().parse(nonlinear, options: options)
        let section = try XCTUnwrap(file.sections.first { $0.segmentName == "__DATA_CONST" })
        put(8, at: command + 112, width: 8, in: &nonlinear)
        put(UInt64(section.fileOffset) + 1, at: command + 120, in: &nonlinear)
        try assertMappingRefused(nonlinear)
    }
}

// Exact test-only byte fixture copied from the retained S1 fixture.
// Private naming makes this parser test independently compilable without S1 proof APIs.
private enum S1SegmentFlagMachOFixture {
    struct Section {
        var segmentName: String
        var sectionName: String
        var address: UInt64
        var bytes: Data
        var flags: UInt32 = 0
    }
    struct DataInCode {
        var offset: UInt32
        var length: UInt16
        var kind: UInt16
    }
    static func make(bodies: [UInt64: (String, [UInt32])], exported: Set<String>,
                     extraSections: [Section] = [], dataInCode: [DataInCode] = []) -> Data {
        let textStart: UInt64 = 0x1000
        let textEnd = bodies.map { $0.key + UInt64($0.value.1.count * 4) }.max()!
        let linkOffset = Int((textEnd + 0xfff) & ~UInt64(0xfff))
        var bytes = Data(repeating: 0, count: linkOffset)
        func put(_ value: UInt64, at offset: Int, width: Int = 4) {
            for index in 0..<width { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        func name(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.prefix(16).enumerated() { bytes[offset + index] = byte }
        }
        put(0xfeedfacf, at: 0); put(0x0100000c, at: 4); put(6, at: 12)
        put(6, at: 16); put(296, at: 20); put(4, at: 24)
        put(0x19, at: 32); put(152, at: 36); name("__TEXT", at: 40)
        put(UInt64(linkOffset), at: 64, width: 8); put(UInt64(linkOffset), at: 80, width: 8)
        put(5, at: 88); put(5, at: 92); put(1, at: 96)
        name("__text", at: 104); name("__TEXT", at: 120)
        put(textStart, at: 136, width: 8); put(textEnd - textStart, at: 144, width: 8)
        put(textStart, at: 152); put(2, at: 156); put(0x80000400, at: 168)
        put(0x19, at: 184); put(72, at: 188); name("__LINKEDIT", at: 192)
        put(UInt64(linkOffset), at: 208, width: 8); put(UInt64(linkOffset), at: 224, width: 8)
        put(1, at: 240); put(1, at: 244)
        for address in stride(from: Int(textStart), to: Int(textEnd), by: 4) { put(0xd503201f, at: address) }
        for (address, body) in bodies {
            for (index, word) in body.1.enumerated() { put(UInt64(word), at: Int(address) + index * 4) }
        }
        let ordered = bodies.sorted { $0.key < $1.key }
        var strings = Data([0]), symbols = Data()
        for (address, body) in ordered {
            append(UInt64(strings.count), width: 4, to: &symbols)
            symbols.append(exported.contains(body.0) ? 0x0f : 0x0e); symbols.append(1)
            append(0, width: 2, to: &symbols); append(address, width: 8, to: &symbols)
            strings.append(Data(("_" + body.0).utf8)); strings.append(0)
        }
        let symOffset = bytes.count; bytes.append(symbols)
        let strOffset = bytes.count; bytes.append(strings)
        var starts = Data(), previous: UInt64 = 0
        for (address, _) in ordered { starts.append(contentsOf: uleb(address - previous)); previous = address }
        starts.append(0)
        let startsOffset = bytes.count; bytes.append(starts)
        let exports = ordered.filter { exported.contains($0.value.0) }.map { ("_" + $0.value.0, $0.key) }
        var offsets = Array(repeating: 0, count: exports.count), root = Data(), leaves = Data()
        for _ in 0..<8 {
            root = Data([0, UInt8(exports.count)])
            for (index, item) in exports.enumerated() {
                root.append(Data(item.0.utf8)); root.append(0); root.append(contentsOf: uleb(UInt64(offsets[index])))
            }
            leaves = Data()
            var updated: [Int] = []
            for item in exports {
                updated.append(root.count + leaves.count)
                let terminal = [UInt8(0)] + uleb(item.1)
                leaves.append(contentsOf: uleb(UInt64(terminal.count))); leaves.append(contentsOf: terminal); leaves.append(0)
            }
            if updated == offsets { break }; offsets = updated
        }
        let exportOffset = bytes.count; bytes.append(root); bytes.append(leaves)
        let exportSize = root.count + leaves.count
        let fixupOffset = bytes.count
        var fixups = Data(repeating: 0, count: 40 + extraSections.count * 4)
        fixups[4] = 28; fixups[20] = 1
        for index in 0..<4 {
            fixups[8 + index] = UInt8(truncatingIfNeeded: UInt32(fixups.count) >> (index * 8))
            fixups[12 + index] = UInt8(truncatingIfNeeded: UInt32(fixups.count) >> (index * 8))
            fixups[28 + index] = UInt8(truncatingIfNeeded: UInt32(2 + extraSections.count) >> (index * 8))
        }
        bytes.append(fixups)
        put(2, at: 256); put(24, at: 260); put(UInt64(symOffset), at: 264)
        put(UInt64(ordered.count), at: 268); put(UInt64(strOffset), at: 272); put(UInt64(strings.count), at: 276)
        for (offset, command, payload, size) in [(280, UInt64(0x26), startsOffset, starts.count),
                                                (296, UInt64(0x80000033), exportOffset, exportSize),
                                                (312, UInt64(0x80000034), fixupOffset, fixups.count)] {
            put(command, at: offset); put(16, at: offset + 4); put(UInt64(payload), at: offset + 8); put(UInt64(size), at: offset + 12)
        }
        var commandOffset = 328
        var commandCount = 6
        if !dataInCode.isEmpty {
            let payloadOffset = bytes.count
            for entry in dataInCode {
                append(UInt64(entry.offset), width: 4, to: &bytes)
                append(UInt64(entry.length), width: 2, to: &bytes)
                append(UInt64(entry.kind), width: 2, to: &bytes)
            }
            put(0x29, at: commandOffset); put(16, at: commandOffset + 4)
            put(UInt64(payloadOffset), at: commandOffset + 8)
            put(UInt64(dataInCode.count * 8), at: commandOffset + 12)
            commandOffset += 16; commandCount += 1
        }
        put(UInt64(bytes.count - linkOffset), at: 216, width: 8)
        put(UInt64(bytes.count - linkOffset), at: 232, width: 8)
        for section in extraSections {
            precondition(commandOffset + 152 <= Int(textStart))
            let payloadOffset = (bytes.count + 0xfff) & ~0xfff
            bytes.append(Data(repeating: 0, count: payloadOffset - bytes.count))
            bytes.append(section.bytes)
            let at = commandOffset
            put(0x19, at: at); put(152, at: at + 4); name(section.segmentName, at: at + 8)
            put(section.address, at: at + 24, width: 8)
            put(UInt64(section.bytes.count), at: at + 32, width: 8)
            put(UInt64(payloadOffset), at: at + 40, width: 8)
            put(UInt64(section.bytes.count), at: at + 48, width: 8)
            put(1, at: at + 56); put(1, at: at + 60); put(1, at: at + 64)
            name(section.sectionName, at: at + 72); name(section.segmentName, at: at + 88)
            put(section.address, at: at + 104, width: 8)
            put(UInt64(section.bytes.count), at: at + 112, width: 8)
            put(UInt64(payloadOffset), at: at + 120); put(2, at: at + 124)
            put(UInt64(section.flags), at: at + 136)
            commandOffset += 152; commandCount += 1
        }
        put(UInt64(commandCount), at: 16); put(UInt64(commandOffset - 32), at: 20)
        return bytes
    }
    private static func append(_ value: UInt64, width: Int, to bytes: inout Data) {
        for index in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }
    private static func uleb(_ value: UInt64) -> [UInt8] {
        var value = value, result: [UInt8] = []
        repeat { var byte = UInt8(value & 0x7f); value >>= 7; if value != 0 { byte |= 0x80 }; result.append(byte) } while value != 0
        return result
    }
}
