import XCTest
@testable import MacScope

/// Real arm64 / arm64e Mach-O images built with swiftc: chained-fixup rebases and binds must
/// reach `SwiftMetadataParser` as real targets, not raw fixup bits.
final class SwiftMetadataMachOFixupTests: XCTestCase {
    enum FixtureError: Error { case build(String) }

    static let source = """
    import Foundation
    public protocol Greeter { func hi() -> String }
    public struct Pt: Greeter { public var x: Int; public var u: URL; public var d: Date; public var a: [String]; public func hi() -> String { "p" } }
    public final class Box<T> { public var v: T?; public var p: Pt?; public init() {} }
    public enum E { case a(Pt), b }
    public struct Q: Codable, Hashable { public var s: String; public var n: Int }
    """

    private func parse(arch: String, legacy: Bool = false) throws -> MachOFile {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else { throw FixtureError.build("xcrun unavailable") }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-fixup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Fx.swift")
        try Self.source.write(to: src, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("libFx.dylib")
        let p = Process()
        p.executableURL = xcrun
        p.arguments = ["swiftc", "-parse-as-library", "-module-name", "Fx", "-target", "\(arch)-apple-macos13",
                       "-emit-library", "-o", out.path, src.path] + (legacy ? ["-Xlinker", "-no_fixup_chains"] : [])
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FixtureError.build("swiftc \(arch) failed") }
        return try MachOParser().parse(try Data(contentsOf: out), options: MachOParseOptions(
            recoverStringLiterals: false, recoverObjectiveCMetadata: false,
            recoverSwiftMetadata: true, parseCodeSignature: false))
    }

    /// Chained (arm64), PAC-authenticated chained (arm64e) and classic `LC_DYLD_INFO` (arm64,
    /// `-no_fixup_chains`) encodings of the same source must recover identical Swift metadata,
    /// including the conformances that sit behind GOT slots.
    /// Address-independent view of the recovered metadata (descriptor VAs differ per encoding).
    private static func summary(_ m: MachOFile) -> [String] {
        m.swiftTypes.map { t in
            "\(t.kind) \(t.name): " + t.fields.map { "\($0.name):\($0.typeName ?? "nil")" }.joined(separator: ",")
        }.sorted() + m.swiftConformances.map { "\($0.typeName):\($0.protocolName)" }.sorted()
    }

    func testChainedPacAndClassicEncodingsRecoverTheSameMetadata() throws {
        let chained = try parse(arch: "arm64")
        let pac = try parse(arch: "arm64e")
        let classic = try parse(arch: "arm64", legacy: true)

        XCTAssertNotNil(chained.dyldChainedFixups)
        XCTAssertNil(classic.dyldChainedFixups, "the legacy fixture must use classic rebase/bind opcodes")
        XCTAssertFalse((pac.dyldChainedFixups?.fixups ?? []).isEmpty)

        XCTAssertEqual(chained.swiftTypes.map(\.name).sorted(), ["Box", "CodingKeys", "E", "Pt", "Q"])
        XCTAssertEqual(chained.swiftConformances.count, 10)
        XCTAssertEqual(Self.summary(pac), Self.summary(chained), "arm64e PAC metadata must match arm64 chained metadata")
        XCTAssertEqual(Self.summary(classic), Self.summary(chained), "classic metadata must match arm64 chained metadata")
    }

    func testClassicOpcodeDecoderResolvesRebaseAndBindSlots() {
        var image = Data(count: 0x40)
        image.replaceSubrange(0x20..<0x28, with: withUnsafeBytes(of: UInt64(0x1_0000_1234).littleEndian) { Data($0) })
        let segments = [
            MachOSegment(name: "__PAGEZERO", vmAddress: 0, vmSize: 0x1_0000_0000, fileOffset: 0, fileSize: 0,
                         maxProtection: 0, initialProtection: 0, sectionCount: 0, flags: 0),
            MachOSegment(name: "__DATA", vmAddress: 0x1_0000_0000, vmSize: 0x40, fileOffset: 0, fileSize: 0x40,
                         maxProtection: 3, initialProtection: 3, sectionCount: 0, flags: 0),
        ]
        // rebase: segment 1 offset 0x20, one rebase.  bind: segment 1 offset 0x28, "_sym", one bind.
        let rebase: [UInt8] = [0x11, 0x21, 0x20, 0x51, 0x00]
        let bind: [UInt8] = [0x40] + Array("_sym".utf8) + [0, 0x71, 0x28, 0x90, 0x00]
        let stream = Data(rebase + bind)
        let combined = image + stream
        let decoded = MachODyldInfoFixups.decode(
            data: combined,
            streams: .init(rebase: 0x40..<(0x40 + rebase.count), bind: (0x40 + rebase.count)..<combined.count),
            segments: segments
        )
        XCTAssertEqual(decoded.rebaseTargets, [0x1_0000_0020: 0x1_0000_1234])
        XCTAssertEqual(decoded.bindNames, [0x1_0000_0028: "_sym"])
    }

    private func classicFixups(rebase: [UInt8], bind: [UInt8] = [],
                               words: [UInt64] = [0x1234, 0x5678, 0x9abc, 0xdef0],
                               fileSize: UInt64? = nil, fileOffset: UInt64 = 0) -> MachODyldInfoFixups {
        var data = Data()
        for word in words {
            data.append(withUnsafeBytes(of: word.littleEndian) { Data($0) })
        }
        let start = data.count
        data.append(contentsOf: rebase + bind)
        let segment = MachOSegment(name: "__DATA", vmAddress: 0x1000, vmSize: UInt64(start),
                                   fileOffset: fileOffset, fileSize: fileSize ?? UInt64(start),
                                   maxProtection: 3, initialProtection: 3, sectionCount: 0, flags: 0)
        return MachODyldInfoFixups.decode(
            data: data,
            streams: .init(rebase: start..<(start + rebase.count), bind: (start + rebase.count)..<data.count),
            segments: [segment])
    }

    func testClassicRebaseIgnoresNonPointerTypesAndAdvances() {
        // TEXT_ABSOLUTE32 must not be interpreted as an eight-byte pointer.
        let original = classicFixups(rebase: [0x12, 0x20, 0x00, 0x51, 0x00],
                                     words: [0x1234, 0, 0, 0])
        XCTAssertTrue(original.rebaseTargets.isEmpty)
        for type in [UInt8(0), 2, 3, 15] {
            let decoded = classicFixups(rebase: [0x10 | type, 0x20, 0, 0x51, 0x11, 0x51, 0])
            XCTAssertEqual(decoded.rebaseTargets, [0x1008: 0x5678], "type \(type) must still advance")
        }
    }

    func testClassicOffsetOverflowStopsAndPreservesEarlierSlots() {
        let maxULEB = Array(repeating: UInt8(0xff), count: 9) + [0x01]
        let original: [UInt8] = [0x20] + maxULEB + [0x30, 0x01, 0x51, 0x00]
        XCTAssertTrue(classicFixups(rebase: [0x11] + original,
                                   words: [0x5678, 0, 0, 0]).rebaseTargets.isEmpty)

        let rebaseOverflows: [[UInt8]] = [
            [0x20] + maxULEB + [0x30, 1],
            [0x20] + maxULEB + [0x41],
            [0x20] + maxULEB + [0x51],
            [0x20] + maxULEB + [0x60, 1],
            [0x20, 0x10, 0x70] + maxULEB,
            [0x20, 0x10, 0x80, 1] + maxULEB,
        ]
        for (index, overflow) in rebaseOverflows.enumerated() {
            let stream: [UInt8] = [0x11, 0x20, 0x10, 0x51] + overflow + [0x20, 0, 0x51, 0]
            XCTAssertEqual(classicFixups(rebase: stream).rebaseTargets, [0x1010: 0x9abc],
                           "rebase overflow case \(index) must stop before the trailing slot")
        }

        let bindOverflows: [[UInt8]] = [
            [0x70] + maxULEB + [0x80, 1],
            [0x70, 0, 0x80] + maxULEB,
            [0x70] + maxULEB + [0x80] + maxULEB,
            [0x70] + maxULEB + [0x90],
            [0x70, 0x10, 0xa0] + maxULEB,
            [0x70] + maxULEB + [0xb1],
            [0x70, 0x10, 0xc0, 1] + maxULEB,
        ]
        for (index, overflow) in bindOverflows.enumerated() {
            let stream: [UInt8] = [0x40, 0x73, 0, 0x70, 0x10, 0x90] + overflow + [0x70, 0, 0x90, 0]
            XCTAssertEqual(classicFixups(rebase: [], bind: stream).bindNames, [0x1010: "s"],
                           "bind overflow case \(index) must stop before the trailing slot")
        }

        // The linker uses a ULEB-encoded -16 to move backward between imported symbols.
        let minus16 = [UInt8(0xf0)] + Array(repeating: UInt8(0xff), count: 8) + [0x01]
        let backward: [UInt8] = [0x40, 0x73, 0, 0x70, 0x18, 0x90, 0x80] + minus16 + [0x90, 0]
        XCTAssertEqual(classicFixups(rebase: [], bind: backward).bindNames, [0x1018: "s", 0x1010: "s"])
    }

    func testClassicPointerSlotMustFitSegmentAndFile() {
        let rebase: [UInt8] = [0x11, 0x20, 0, 0x51, 0]
        let bind: [UInt8] = [0x40, 0x73, 0, 0x70, 0, 0x90, 0]
        let original = classicFixups(rebase: rebase, words: [0x9abc], fileSize: 1)
        XCTAssertTrue(original.rebaseTargets.isEmpty)
        for size in [UInt64(0), 1, 7] {
            let decoded = classicFixups(rebase: rebase, bind: bind, words: [0x9abc], fileSize: size)
            XCTAssertTrue(decoded.rebaseTargets.isEmpty, "segment size \(size)")
            XCTAssertTrue(decoded.bindNames.isEmpty, "segment size \(size)")
        }
        let exact = classicFixups(rebase: rebase, bind: bind, words: [0x9abc], fileSize: 8)
        XCTAssertEqual(exact.rebaseTargets, [0x1000: 0x9abc])
        XCTAssertEqual(exact.bindNames, [0x1000: "s"])
        let pastFile = classicFixups(rebase: rebase, bind: bind, fileSize: 8, fileOffset: 0x100)
        XCTAssertTrue(pastFile.rebaseTargets.isEmpty)
        XCTAssertTrue(pastFile.bindNames.isEmpty)
    }

    func testClassicRebaseAddAddressULEB() {
        let decoded = classicFixups(rebase: [0x11, 0x20, 0, 0x30, 8, 0x51, 0])
        XCTAssertEqual(decoded.rebaseTargets, [0x1008: 0x5678])
    }

    func testClassicRebaseAddAddressImmediateScaled() {
        let decoded = classicFixups(rebase: [0x11, 0x20, 0, 0x42, 0x51, 0])
        XCTAssertEqual(decoded.rebaseTargets, [0x1010: 0x9abc])
    }

    func testClassicRebaseULEBTimes() {
        let decoded = classicFixups(rebase: [0x11, 0x20, 0, 0x60, 2, 0])
        XCTAssertEqual(decoded.rebaseTargets, [0x1000: 0x1234, 0x1008: 0x5678])
    }

    func testClassicRebaseAndAddAddressULEB() {
        let decoded = classicFixups(rebase: [0x11, 0x20, 0, 0x70, 8, 0x51, 0])
        XCTAssertEqual(decoded.rebaseTargets, [0x1000: 0x1234, 0x1010: 0x9abc])
    }

    func testClassicRebaseULEBTimesSkippingULEB() {
        let decoded = classicFixups(rebase: [0x11, 0x20, 0, 0x80, 2, 8, 0])
        XCTAssertEqual(decoded.rebaseTargets, [0x1000: 0x1234, 0x1010: 0x9abc])
    }

    func testClassicRebaseUnknownOpcodeStopsWithEarlierSlots() {
        let decoded = classicFixups(rebase: [0x11, 0x20, 0, 0x51, 0x90, 0x51, 0])
        XCTAssertEqual(decoded.rebaseTargets, [0x1000: 0x1234])
    }
}
