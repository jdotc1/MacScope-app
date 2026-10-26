import Foundation
import XCTest
@testable import MacScope

/// Appending an RX cave must preserve dyld's original chains while inserting the cave's
/// empty segment ordinal before the relocated, final __LINKEDIT segment.
final class MachOChainedCaveWriterTests: XCTestCase {
    private let writer = MachOPatchWriter()
    private let cave = Data([0xa0, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]) // mov w0, #5; ret
    private static let fixupsCommand: UInt32 = 0x8000_0034
    private static let imageBase: UInt64 = 0x1_0000_0000

    func testRewrittenStartsKeepOriginalRecordsAndInsertEmptyCaveOrdinal() throws {
        // Fixed witnesses cover both admitted pointer encodings and all three import
        // encodings. The MULTI page contains two independently terminated chains.
        let formats: [(UInt16, UInt32)] = [(6, 1), (2, 2), (6, 3)]
        for (pointerFormat, importsFormat) in formats {
            let original = Self.fixture(pointerFormat: pointerFormat, importsFormat: importsFormat)
            let before = try Self.metadata(original)
            let result = try writer.makePatchedDataWithAppendedExecutableCave(
                originalData: original, patches: [:], caveBytes: cave)
            let after = try Self.metadata(result.data)
            try assertPreserved(before: before, after: after)
            XCTAssertEqual(after.segmentNames, ["__TEXT", "__MSCAVE", "__LINKEDIT"])
            XCTAssertEqual(after.records[0], before.records[0], "the complete starts_in_segment is exact")
            XCTAssertEqual(try Self.read16(try XCTUnwrap(after.records[0]), at: 22), 0xffff)
            XCTAssertEqual(try Self.read16(try XCTUnwrap(after.records[0]), at: 24), 0x8002)
            XCTAssertEqual(try Self.read16(try XCTUnwrap(after.records[0]), at: 26), 0x0100)
            XCTAssertEqual(try Self.read16(try XCTUnwrap(after.records[0]), at: 28), 0x8200)
            for offset in [0x4100, 0x4200] {
                XCTAssertEqual(try Self.bytes(result.data, offset, 8), try Self.bytes(original, offset, 8),
                               "the original encoded chain is untouched")
            }
            let parsed = try Self.parse(result.data)
            let link = try XCTUnwrap(parsed.segments.last)
            XCTAssertEqual(UInt64(after.fileOffset), link.fileOffset)
            XCTAssertGreaterThan(after.fileOffset, before.fileOffset)
            XCTAssertGreaterThan(after.payloadSize, before.payloadSize)
            XCTAssertEqual(link.fileOffset + link.fileSize, UInt64(result.data.count))
            let signature = try XCTUnwrap(parsed.loadCommands.first {
                $0.command == MachOConstants.loadCommandCodeSignature
            })
            let signatureOffset = Int(try Self.read32(result.data, at: Int(signature.offset) + 8))
            XCTAssertEqual(signatureOffset % 16, 0, "the following signature keeps its alignment")
            XCTAssertEqual(try Self.bytes(result.data, signatureOffset, 0x100),
                           try Self.bytes(original, 0x8100, 0x100), "following LINKEDIT bytes survive growth")
        }
    }

    func testUnknownFormatsAndMalformedChainedStartsAreRefused() throws {
        let original = Self.fixture()
        // Each mutation has one specific ambiguity; no malformed layout is emitted.
        let mutations: [(String, (inout Data) -> Void)] = [
            ("unknown pointer format", { Self.write16(0xffff, into: &$0, at: 0x8000 + 48 + 6) }),
            ("unknown imports format", { Self.write32(0xffff, into: &$0, at: 0x8000 + 20) }),
            ("unknown symbols format", { Self.write32(1, into: &$0, at: 0x8000 + 24) }),
            ("starts outside payload", { Self.write32(0xffff_fff0, into: &$0, at: 0x8000 + 4) }),
            ("segment record outside payload", { Self.write32(0xffff_fff0, into: &$0, at: 0x8000 + 36) }),
            ("segment count mismatch", { Self.write32(3, into: &$0, at: 0x8000 + 32) }),
            ("imports outside payload", { Self.write32(0xffff_fff0, into: &$0, at: 0x8000 + 8) }),
            ("unterminated MULTI list", { Self.write16(0x0200, into: &$0, at: 0x8000 + 48 + 28) }),
            ("fixups in relocated LINKEDIT", { Self.write32(16, into: &$0, at: 0x8000 + 40) }),
            ("rebase points into relocated LINKEDIT", { Self.write64(0x8000, into: &$0, at: 0x4100) }),
        ]
        for (name, mutate) in mutations {
            var bytes = original
            mutate(&bytes)
            XCTAssertThrowsError(try writer.makePatchedDataWithAppendedExecutableCave(
                originalData: bytes, patches: [:], caveBytes: cave), name) { error in
                if name == "imports outside payload",
                   case .notMachO(let reason) = error as? MachOPatchWriter.PatchWriteError {
                    // The shared Mach-O parser rejects this extent before cave admission.
                    XCTAssertTrue(reason.contains("imports_offset points outside the payload"), reason)
                    return
                }
                guard case .unsupportedLayout = error as? MachOPatchWriter.CaveWriteError else {
                    return XCTFail("\(name): expected a clean unsupported-layout refusal, got \(error)")
                }
            }
        }
    }

    func testSegmentAfterLinkeditIsRefused() throws {
        var original = Self.fixture()
        // A sectionless zero-file-size segment after LINKEDIT still changes segment
        // ordinals and VM authority: it must not be silently accepted or reordered.
        var command = Data(repeating: 0, count: 72)
        Self.write32(MachOConstants.loadCommandSegment64, into: &command, at: 0)
        Self.write32(72, into: &command, at: 4)
        command.replaceSubrange(8..<15, with: "__AFTER".utf8)
        Self.write64(Self.imageBase + 0xc000, into: &command, at: 24)
        Self.write64(0x4000, into: &command, at: 32)
        original.replaceSubrange(336..<408, with: command)
        Self.write32(7, into: &original, at: 16)
        Self.write32(376, into: &original, at: 20)
        XCTAssertThrowsError(try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: original, patches: [:], caveBytes: cave)) { error in
            guard case .unsupportedLayout = error as? MachOPatchWriter.CaveWriteError else {
                return XCTFail("expected unsupported-layout refusal, got \(error)")
            }
        }
    }

    func testDefaultClangChainedWitnessResignsAndRunsWithCaveExitCode() throws {
        let directory = TestWorkRoot.scratch
            .appendingPathComponent("macscope-chained-cave-witness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Retain the source and both executables as the real witness for this run.
        let source = directory.appendingPathComponent("witness.c")
        let originalURL = directory.appendingPathComponent("original")
        let outputURL = directory.appendingPathComponent("cave-exit-5")
        try "static int value = 0; int * volatile selected = &value; int main(void) { return *selected; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        // Default linker fixups: deliberately no -no_fixup_chains or -fixup_chains flag.
        let built = try tool(["clang", "-arch", "arm64", "-O2", "-Wl,-headerpad,0x4000",
                              "-o", originalURL.path, source.path], directory: directory)
        XCTAssertEqual(built.status, 0, built.output)
        guard built.status == 0 else { return }
        let original = try Data(contentsOf: originalURL)
        let before = try Self.metadata(original)
        XCTAssertTrue(before.records.contains { $0 != nil }, "the witness must have actual chained starts")
        XCTAssertEqual(try execute(originalURL), 0)
        let symbols = try tool(["nm", originalURL.path], directory: directory)
        XCTAssertEqual(symbols.status, 0, symbols.output)
        let mainLine = try XCTUnwrap(symbols.output.split(separator: "\n").first { $0.hasSuffix(" _main") })
        let mainAddress = try XCTUnwrap(mainLine.split(whereSeparator: { $0.isWhitespace }).first)
        let main = try XCTUnwrap(UInt64(mainAddress, radix: 16))
        let appended = try writer.makePatchedDataWithAppendedExecutableCave(
            originalData: original, patches: [:], caveBytes: cave, branchSourceAddress: main)
        try assertPreserved(before: before, after: Self.metadata(appended.data))
        let signed = try MachOAdHocSigner.resign(appended.data)
        try signed.data.write(to: outputURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
        let verified = try tool(["codesign", "--verify", "--strict", "--verbose=2", outputURL.path],
                                directory: directory)
        XCTAssertEqual(verified.status, 0, verified.output)
        XCTAssertEqual(try execute(outputURL), 5, "the appended cave is the executed code")
        print("Chained-fixups cave witness retained at \(directory.path)")
    }

    private func assertPreserved(before: Metadata, after: Metadata,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let oldLinkOrdinal = try XCTUnwrap(before.segmentNames.firstIndex(of: "__LINKEDIT"), file: file, line: line)
        XCTAssertEqual(after.segmentNames.count, before.segmentNames.count + 1, file: file, line: line)
        XCTAssertEqual(after.records.count, before.records.count + 1, file: file, line: line)
        XCTAssertEqual(after.segmentNames[oldLinkOrdinal], "__MSCAVE", file: file, line: line)
        XCTAssertNil(after.records[oldLinkOrdinal], "the cave has no fixups", file: file, line: line)
        XCTAssertEqual(after.segmentOffsets[oldLinkOrdinal], 0, file: file, line: line)
        let growth = after.payloadSize - before.payloadSize
        XCTAssertGreaterThan(growth, 0, file: file, line: line)
        XCTAssertEqual(after.startsOffset, before.startsOffset, file: file, line: line)
        XCTAssertEqual(after.importsOffset, before.importsOffset + growth, file: file, line: line)
        XCTAssertEqual(after.symbolsOffset, before.symbolsOffset + growth, file: file, line: line)
        for index in before.records.indices {
            let newIndex = index < oldLinkOrdinal ? index : index + 1
            XCTAssertEqual(after.segmentNames[newIndex], before.segmentNames[index], file: file, line: line)
            XCTAssertEqual(after.records[newIndex], before.records[index],
                           "all original starts_in_segment and page_start bytes survive", file: file, line: line)
            if before.segmentOffsets[index] == 0 {
                XCTAssertEqual(after.segmentOffsets[newIndex], 0, file: file, line: line)
            } else {
                XCTAssertEqual(Int(after.segmentOffsets[newIndex]), Int(before.segmentOffsets[index]) + growth,
                               file: file, line: line)
            }
        }
        XCTAssertEqual(after.fixupsVersion, before.fixupsVersion, file: file, line: line)
        XCTAssertEqual(after.importsCount, before.importsCount, file: file, line: line)
        XCTAssertEqual(after.importsFormat, before.importsFormat, file: file, line: line)
        XCTAssertEqual(after.symbolsFormat, before.symbolsFormat, file: file, line: line)
        XCTAssertEqual(after.importBytes, before.importBytes, file: file, line: line)
        XCTAssertEqual(after.symbolBytes, before.symbolBytes, file: file, line: line)
    }

    private struct Metadata {
        let segmentNames: [String]
        let fileOffset: Int
        let payloadSize: Int
        let startsOffset: Int
        let importsOffset: Int
        let symbolsOffset: Int
        let fixupsVersion: UInt32
        let importsCount: UInt32
        let importsFormat: UInt32
        let symbolsFormat: UInt32
        let segmentOffsets: [UInt32]
        let records: [Data?]
        let importBytes: Data
        let symbolBytes: Data
    }

    private static func metadata(_ data: Data) throws -> Metadata {
        let parsed = try parse(data)
        let command = try XCTUnwrap(parsed.loadCommands.first { $0.command == fixupsCommand })
        let fileOffset = Int(try read32(data, at: Int(command.offset) + 8))
        let size = Int(try read32(data, at: Int(command.offset) + 12))
        let payload = try bytes(data, fileOffset, size)
        let starts = Int(try read32(payload, at: 4))
        let imports = Int(try read32(payload, at: 8))
        let symbols = Int(try read32(payload, at: 12))
        let segmentCount = Int(try read32(payload, at: starts))
        guard segmentCount <= parsed.segments.count + 1 else { throw FixtureError.invalidBounds }
        var offsets: [UInt32] = []
        var records: [Data?] = []
        for index in 0..<segmentCount {
            let offset = try read32(payload, at: starts + 4 + 4 * index)
            offsets.append(offset)
            if offset == 0 { records.append(nil) }
            else {
                let record = starts + Int(offset)
                records.append(try bytes(payload, record, Int(try read32(payload, at: record))))
            }
        }
        return Metadata(segmentNames: parsed.segments.map(\.name), fileOffset: fileOffset, payloadSize: size,
                        startsOffset: starts, importsOffset: imports, symbolsOffset: symbols,
                        fixupsVersion: try read32(payload, at: 0), importsCount: try read32(payload, at: 16),
                        importsFormat: try read32(payload, at: 20), symbolsFormat: try read32(payload, at: 24),
                        segmentOffsets: offsets, records: records,
                        importBytes: try bytes(payload, imports, symbols - imports),
                        symbolBytes: try bytes(payload, symbols, size - symbols))
    }

    private static func parse(_ data: Data) throws -> MachOFile {
        try MachOParser().parse(data, options: MachOParseOptions(
            recoverStringLiterals: false, recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: false, parseCodeSignature: false))
    }

    private static func fixture(pointerFormat: UInt16 = 6, importsFormat: UInt32 = 1) -> Data {
        var data = MachOPatchWriterTests.makeSignedExecutableWithCommandSlack().bytes
        // Make the whole two-page __TEXT file-backed; chains occupy non-code padding.
        write64(0x8000, into: &data, at: 80)
        data.insert(contentsOf: repeatElement(0, count: 0x100), at: 0x8000)
        write64(0x200, into: &data, at: 208 + 48)
        write32(0x8100, into: &data, at: 280 + 8)
        write32(6, into: &data, at: 16)
        write32(304, into: &data, at: 20)
        write32(fixupsCommand, into: &data, at: 320)
        write32(16, into: &data, at: 324)
        write32(0x8000, into: &data, at: 328)
        write32(112, into: &data, at: 332)

        var payload = Data(repeating: 0, count: 112)
        write32(32, into: &payload, at: 4) // starts_offset
        write32(80, into: &payload, at: 8) // imports_offset
        let importSize: UInt32 = importsFormat == 1 ? 4 : importsFormat == 2 ? 8 : 16
        write32(80 + importSize, into: &payload, at: 12) // symbols_offset
        write32(1, into: &payload, at: 16)
        write32(importsFormat, into: &payload, at: 20)
        write32(2, into: &payload, at: 32) // __TEXT, __LINKEDIT
        write32(16, into: &payload, at: 36) // __TEXT record relative to starts
        write32(30, into: &payload, at: 48) // starts_in_segment size including overflow list
        write16(0x4000, into: &payload, at: 52)
        write16(pointerFormat, into: &payload, at: 54)
        write16(2, into: &payload, at: 68) // page_count
        write16(0xffff, into: &payload, at: 70) // page 0 has no fixups
        write16(0x8002, into: &payload, at: 72) // page 1 starts at overflow index 2
        write16(0x0100, into: &payload, at: 74)
        write16(0x8200, into: &payload, at: 76) // last overflow entry
        // One self import at symbol-pool offset zero, including a nonzero addend
        // for the encodings that have one; none of the synthetic chains bind it.
        if importsFormat == 2 { write32(7, into: &payload, at: 84) }
        if importsFormat == 3 { write64(7, into: &payload, at: 88) }
        let symbolOffset = 80 + Int(importSize)
        payload.replaceSubrange(symbolOffset..<(symbolOffset + 9), with: Array("_fixture\0".utf8))
        data.replaceSubrange(0x8000..<0x8070, with: payload)
        let target = pointerFormat == 2 ? imageBase + 0x4000 : 0x4000
        write64(target, into: &data, at: 0x4100)
        write64(target, into: &data, at: 0x4200)
        return data
    }

    private func tool(_ arguments: [String], directory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = directory.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        return (process.terminationStatus, drain.text())
    }

    private func execute(_ url: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = url
        process.currentDirectoryURL = url.deletingLastPathComponent()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private enum FixtureError: Error { case invalidBounds }
    private static func bytes(_ data: Data, _ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw FixtureError.invalidBounds
        }
        return Data(data[offset..<(offset + count)])
    }
    private static func read16(_ data: Data, at offset: Int) throws -> UInt16 {
        let value = try bytes(data, offset, 2)
        return UInt16(value[0]) | UInt16(value[1]) << 8
    }
    private static func read32(_ data: Data, at offset: Int) throws -> UInt32 {
        let value = try bytes(data, offset, 4)
        return UInt32(value[0]) | UInt32(value[1]) << 8 | UInt32(value[2]) << 16 | UInt32(value[3]) << 24
    }
    private static func write16(_ value: UInt16, into data: inout Data, at offset: Int) {
        for index in 0..<2 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
    private static func write32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
    private static func write64(_ value: UInt64, into data: inout Data, at offset: Int) {
        for index in 0..<8 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }
}
