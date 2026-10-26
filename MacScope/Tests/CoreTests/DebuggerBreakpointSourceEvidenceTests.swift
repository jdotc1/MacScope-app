import CryptoKit
import Foundation
import XCTest
@testable import MacScope

final class DebuggerBreakpointSourceEvidenceTests: XCTestCase {
    func testSameBasenameInDistinctLineUnitsRetainsDistinctExactAuthority() throws {
        let firstUnit = Self.v4Unit(directory: "/checkout/first", file: "shared.c", address: 0x1000)
        let secondUnit = Self.v4Unit(directory: "/checkout/second", file: "shared.c", address: 0x2000)

        let rows = DWARFLineProgram(debugLine: Data(firstUnit + secondUnit))
            .decode()
            .filter { !$0.endSequence }

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.lineProgramUnitOffset), [0, UInt64(firstUnit.count)])
        XCTAssertEqual(rows.map(\.fileTableIndex), [1, 1])
        XCTAssertEqual(rows.map(\.file), ["/checkout/first/shared.c", "/checkout/second/shared.c"])
        XCTAssertEqual(rows[0].canonicalTablePath, .absoluteUTF8("/checkout/first/shared.c"))
        XCTAssertEqual(rows[1].canonicalTablePath, .absoluteUTF8("/checkout/second/shared.c"))
        XCTAssertNotEqual(rows[0].canonicalTablePath, rows[1].canonicalTablePath)
    }

    func testRelativeTablePathIsNotStandardizedOrResolvedOnImportingMachine() throws {
        let unit = Self.v4Unit(
            directory: "Sources/../Generated",
            file: "./item.c",
            address: 0x3000
        )
        let row = try XCTUnwrap(
            DWARFLineProgram(debugLine: Data(unit)).decode().first { !$0.endSequence }
        )

        XCTAssertEqual(row.file, "Sources/../Generated/./item.c")
        XCTAssertEqual(
            row.canonicalTablePath,
            .compilationDirectoryRelativeUTF8("Sources/../Generated/./item.c")
        )
    }

    func testV5UsesZeroBasedFileAndDirectoryTableIdentity() throws {
        let unit = Self.v5Unit(directory: "/v5/root", file: "shared.c", address: 0x3500)
        let row = try XCTUnwrap(
            DWARFLineProgram(debugLine: Data(unit)).decode().first { !$0.endSequence }
        )

        XCTAssertEqual(row.fileIndex, 0)
        XCTAssertEqual(row.fileTableIndex, 0)
        XCTAssertEqual(row.file, "/v5/root/shared.c")
        XCTAssertEqual(row.canonicalTablePath, .absoluteUTF8("/v5/root/shared.c"))
        XCTAssertEqual(row.lineProgramUnitOffset, 0)
    }

    func testCanonicalPathPreservesExactUTF8WithoutUnicodeNormalization() throws {
        let decomposed = "Cafe\u{301}.c"
        let composed = "Caf\u{e9}.c"
        let firstUnit = Self.v4Unit(directory: "src", file: decomposed, address: 0x4000)
        let secondUnit = Self.v4Unit(directory: "src", file: composed, address: 0x5000)
        let rows = DWARFLineProgram(debugLine: Data(firstUnit + secondUnit))
            .decode()
            .filter { !$0.endSequence }

        XCTAssertEqual(rows.count, 2)
        XCTAssertNotEqual(Array(rows[0].file!.utf8), Array(rows[1].file!.utf8))
        XCTAssertNotEqual(rows[0].canonicalTablePath, rows[1].canonicalTablePath)
    }

    func testMatchedDSYMSealsExactSelectedMachOBytes() throws {
        let built = try Self.buildDSYM()
        defer { try? FileManager.default.removeItem(at: built.rootURL) }

        let result = try DSYMImportService().importDebugSymbols(
            at: built.dsymURL,
            expectedUUID: built.uuid
        )
        let seal = try XCTUnwrap(result.debugArtifactSeal)
        let selectedURL = try DSYMImportService().resolveDWARFBinary(at: built.dsymURL)
        let exactBytes = try Data(contentsOf: selectedURL)
        let expectedDigest = SHA256.hash(data: exactBytes)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(seal.uuid, UUID(uuidString: built.uuid))
        XCTAssertEqual(seal.selectedMachOSHA256, expectedDigest)
        XCTAssertEqual(seal.selectedMachOByteCount, UInt64(exactBytes.count))
        XCTAssertFalse(result.canonicalLineRows.isEmpty)
        XCTAssertTrue(result.canonicalLineRows.contains {
            !$0.endSequence && $0.fileTableIndex != nil && $0.canonicalTablePath != nil
        })
        let authoritativeLine = try XCTUnwrap(result.sourceLines.first {
            !$0.endSequence && $0.tablePath != nil
        })
        XCTAssertEqual(authoritativeLine.debugArtifactUUID, seal.uuid)
        XCTAssertEqual(authoritativeLine.debugArtifactMachOSHA256, expectedDigest)
        XCTAssertEqual(authoritativeLine.debugArtifactMachOByteCount, UInt64(exactBytes.count))
        XCTAssertNotNil(authoritativeLine.lineProgramUnitOffset)
        XCTAssertNotNil(authoritativeLine.fileTableIndex)
    }

    func testFatDSYMReadsSectionsRelativeToSelectedSliceAndSealsOnlyThatSlice() throws {
        let built = try Self.buildDSYM()
        defer { try? FileManager.default.removeItem(at: built.rootURL) }
        let thinURL = try DSYMImportService().resolveDWARFBinary(at: built.dsymURL)
        let thinBytes = try Data(contentsOf: thinURL)
        let fatBytes = Self.fatContainerWithArm64Second(thinBytes)
        let fatURL = built.rootURL.appendingPathComponent("fat-dwarf")
        try fatBytes.write(to: fatURL, options: .atomic)

        let result = try DSYMImportService().importDebugSymbols(at: fatURL, expectedUUID: built.uuid)
        let seal = try XCTUnwrap(result.debugArtifactSeal)
        let expectedDigest = SHA256.hash(data: thinBytes)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(seal.selectedMachOSHA256, expectedDigest)
        XCTAssertEqual(seal.selectedMachOByteCount, UInt64(thinBytes.count))
        XCTAssertFalse(result.functions.isEmpty)
        XCTAssertTrue(result.sourceLines.contains { !$0.endSequence && $0.tablePath != nil })
    }

    private static func v4Unit(directory: String, file: String, address: UInt64) -> [UInt8] {
        var body: [UInt8] = [0x04, 0x00]
        let headerLengthIndex = body.count
        body.append(contentsOf: [0, 0, 0, 0])
        let afterHeaderLength = body.count
        body.append(contentsOf: [
            0x01, // minimum_instruction_length
            0x01, // maximum_operations_per_instruction
            0x01, // default_is_stmt
            0x00, // line_base
            0x01, // line_range
            0x0d, // opcode_base
        ])
        body.append(contentsOf: Array(repeating: 0, count: 12))
        body.append(contentsOf: directory.utf8)
        body.append(0)
        body.append(0) // directory-table terminator
        body.append(contentsOf: file.utf8)
        body.append(0)
        body.append(1) // v2-v4 directory index 1
        body.append(0) // timestamp
        body.append(0) // byte count
        body.append(0) // file-table terminator

        let headerLength = UInt32(body.count - afterHeaderLength)
        for shift in stride(from: 0, through: 24, by: 8) {
            body[headerLengthIndex + shift / 8] = UInt8(truncatingIfNeeded: headerLength >> shift)
        }

        body.append(contentsOf: [0, 9, 2]) // DW_LNE_set_address, 8-byte operand
        for shift in stride(from: 0, through: 56, by: 8) {
            body.append(UInt8(truncatingIfNeeded: address >> shift))
        }
        body.append(1) // DW_LNS_copy
        body.append(contentsOf: [0, 1, 1]) // DW_LNE_end_sequence

        var result: [UInt8] = []
        let unitLength = UInt32(body.count)
        for shift in stride(from: 0, through: 24, by: 8) {
            result.append(UInt8(truncatingIfNeeded: unitLength >> shift))
        }
        result.append(contentsOf: body)
        return result
    }

    private static func v5Unit(directory: String, file: String, address: UInt64) -> [UInt8] {
        var body: [UInt8] = [
            0x05, 0x00, // version 5
            0x08,       // address size
            0x00,       // segment selector size
        ]
        let headerLengthIndex = body.count
        body.append(contentsOf: [0, 0, 0, 0])
        let afterHeaderLength = body.count
        body.append(contentsOf: [
            0x01, // minimum_instruction_length
            0x01, // maximum_operations_per_instruction
            0x01, // default_is_stmt
            0x00, // line_base
            0x01, // line_range
            0x0d, // opcode_base
        ])
        body.append(contentsOf: Array(repeating: 0, count: 12))
        body.append(1) // directory format count
        body.append(contentsOf: [0x01, 0x08]) // DW_LNCT_path, DW_FORM_string
        body.append(1) // directory count
        body.append(contentsOf: directory.utf8)
        body.append(0)
        body.append(2) // file format count
        body.append(contentsOf: [0x01, 0x08]) // path, string
        body.append(contentsOf: [0x02, 0x0f]) // directory index, udata
        body.append(1) // file count
        body.append(contentsOf: file.utf8)
        body.append(0)
        body.append(0) // v5 directory index zero

        let headerLength = UInt32(body.count - afterHeaderLength)
        for shift in stride(from: 0, through: 24, by: 8) {
            body[headerLengthIndex + shift / 8] = UInt8(truncatingIfNeeded: headerLength >> shift)
        }
        body.append(contentsOf: [0, 9, 2]) // set_address
        for shift in stride(from: 0, through: 56, by: 8) {
            body.append(UInt8(truncatingIfNeeded: address >> shift))
        }
        body.append(contentsOf: [4, 0]) // DW_LNS_set_file to v5 index zero
        body.append(1) // copy
        body.append(contentsOf: [0, 1, 1]) // end_sequence

        var result: [UInt8] = []
        let unitLength = UInt32(body.count)
        for shift in stride(from: 0, through: 24, by: 8) {
            result.append(UInt8(truncatingIfNeeded: unitLength >> shift))
        }
        result.append(contentsOf: body)
        return result
    }

    private static func fatContainerWithArm64Second(_ arm64Slice: Data) -> Data {
        let alignment = 0x1_000
        let firstOffset = alignment
        let firstSlice = Data([0xca, 0xfe, 0xba, 0xbe])
        let secondOffset = ((firstOffset + firstSlice.count + alignment - 1) / alignment) * alignment
        var bytes = Data()
        appendBE(0xca_fe_ba_be, to: &bytes)
        appendBE(2, to: &bytes)
        appendBE(UInt32(bitPattern: MachOConstants.cpuTypeX86_64), to: &bytes)
        appendBE(0, to: &bytes)
        appendBE(UInt32(firstOffset), to: &bytes)
        appendBE(UInt32(firstSlice.count), to: &bytes)
        appendBE(12, to: &bytes)
        appendBE(UInt32(bitPattern: MachOConstants.cpuTypeARM64), to: &bytes)
        appendBE(0, to: &bytes)
        appendBE(UInt32(secondOffset), to: &bytes)
        appendBE(UInt32(arm64Slice.count), to: &bytes)
        appendBE(12, to: &bytes)
        bytes.append(Data(repeating: 0, count: firstOffset - bytes.count))
        bytes.append(firstSlice)
        bytes.append(Data(repeating: 0, count: secondOffset - bytes.count))
        bytes.append(arm64Slice)
        return bytes
    }

    private static func appendBE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private struct BuiltDSYM {
        let rootURL: URL
        let dsymURL: URL
        let uuid: String
    }

    private static func buildDSYM() throws -> BuiltDSYM {
        let clang = URL(fileURLWithPath: "/usr/bin/clang")
        let dsymutil = URL(fileURLWithPath: "/usr/bin/dsymutil")
        guard FileManager.default.isExecutableFile(atPath: clang.path),
              FileManager.default.isExecutableFile(atPath: dsymutil.path) else {
            throw XCTSkip("clang/dsymutil unavailable")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-ws21-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("shared.c")
        let object = root.appendingPathComponent("shared.o")
        let binary = root.appendingPathComponent("shared")
        try "int helper(int x) { return x + 1; }\nint main(void) { return helper(1); }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        try run(clang, ["-g", "-O0", "-c", "-o", object.path, source.path])
        try run(clang, ["-g", "-O0", "-o", binary.path, object.path])
        try run(dsymutil, [binary.path])

        let bytes = try Data(contentsOf: binary)
        let machO = try MachOParser().parse(bytes, options: MachOParseOptions(
            recoverStringLiterals: false,
            recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false,
            parseCodeSignature: false
        ))
        guard let uuid = machO.uuid?.stringValue else { throw XCTSkip("fixture has no UUID") }
        let dsym = root.appendingPathComponent("shared.dSYM", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dsym.path) else {
            throw XCTSkip("dsymutil did not produce a dSYM")
        }
        return BuiltDSYM(rootURL: root, dsymURL: dsym, uuid: uuid)
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip(String(decoding: output, as: UTF8.self))
        }
    }
}
