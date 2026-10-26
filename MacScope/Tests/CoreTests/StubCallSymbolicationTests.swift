import Foundation
import XCTest
@testable import MacScope

final class StubCallSymbolicationTests: XCTestCase {

    func testOversizedObjCStubSectionAbstainsWithoutIntegerConversionTrap() {
        for size in [UInt64(Int.max) + 1, UInt64.max, 0] {
            let section = BinarySection(name: "__TEXT,__objc_stubs", address: 0x1000,
                size: size, fileOffset: 0, isExecutable: true)
            let loaded = LoadedBinary(name: "malformed-stubs", path: "/fixture", isBundle: false,
                cpuType: MachOConstants.cpuTypeARM64, fileTypeName: "fixture",
                architectureDisplayName: "arm64", metadata: .empty, bytes: Data([0]),
                sliceOffset: 0, sections: [section], executableTextSection: section,
                entryPointAddress: nil, symbols: [], imports: [], indirectSymbols: [],
                exports: [], stringLiterals: [], functionStarts: [], objcSelectors: [0x2000: "selector"])
            XCTAssertEqual(AnalysisEngine.objcStubSelectorNames(in: loaded), [:])
        }
    }

    func testConflictingMessageSendDispatchSlotAbstains() {
        var bytes = Data()
        for word: UInt32 in [0x9000_0001, 0xF940_0021, 0x1400_0002] {
            withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
        }
        let section = BinarySection(name: "__TEXT,__objc_stubs", address: 0x1000,
            size: 12, fileOffset: 0, isExecutable: true)
        var loaded = LoadedBinary(name: "conflicting-stubs", path: "/fixture", isBundle: false,
            cpuType: MachOConstants.cpuTypeARM64, fileTypeName: "fixture", architectureDisplayName: "arm64",
            metadata: .empty, bytes: bytes, sliceOffset: 0, sections: [section], executableTextSection: section,
            entryPointAddress: nil, symbols: [], imports: [],
            indirectSymbols: [indirect("__stubs", 0x1010, name: "_objc_msgSend")],
            exports: [], stringLiterals: [], functionStarts: [], objcSelectors: [0x1000: "length"])
        XCTAssertEqual(AnalysisEngine.objcStubSelectorNames(in: loaded), [0x1000: "_objc_msgSend$length"])
        loaded.indirectSymbols.append(indirect("__stubs", 0x1010, name: "_printf"))
        XCTAssertEqual(AnalysisEngine.objcStubSelectorNames(in: loaded), [:])
    }

    private func indirect(
        _ section: String,
        _ address: UInt64,
        name: String?,
        isLocal: Bool = false,
        isAbsolute: Bool = false
    ) -> IndirectSymbolSummary {
        IndirectSymbolSummary(
            id: UUID(), kind: "pointer", sourceSection: section, address: address,
            entrySize: 8, tableIndex: 0, rawSymbolIndex: 0, symbolIndex: nil,
            symbolName: name, libraryOrdinal: nil, libraryName: nil,
            isLocal: isLocal, isAbsolute: isAbsolute
        )
    }

    func testResolvesStubAddressesToImportNames() {
        let sym = StubCallSymbolicator(indirectSymbols: [
            indirect("__stubs", 0x1_0000_4abc, name: "_printf"),
            indirect("__auth_stubs", 0x1_0000_4ad0, name: "_objc_msgSend"),
            indirect("__got", 0x1_0001_0000, name: "_$ss5Int32VMn"),
        ])
        XCTAssertEqual(sym.name(forStubTarget: 0x1_0000_4abc), "_printf")
        XCTAssertEqual(sym.name(forStubTarget: 0x1_0000_4ad0), "_objc_msgSend")
        XCTAssertEqual(sym.name(forStubTarget: 0x1_0001_0000), "_$ss5Int32VMn")     // GOT data ref
        XCTAssertNil(sym.name(forStubTarget: 0x1_0000_4000), "an address with no stub slot is unresolved")
        XCTAssertFalse(sym.isEmpty)
    }

    func testSkipsNonLinkageLocalAbsoluteAndNamelessSlots() {
        let sym = StubCallSymbolicator(indirectSymbols: [
            indirect("__text", 0x1_0000_1000, name: "_notAStub"),          // not a linkage section
            indirect("__stubs", 0x1_0000_2000, name: nil),                  // unresolved (no name)
            indirect("__got", 0x1_0000_3000, name: "", ),                   // empty name
            indirect("__la_symbol_ptr", 0x1_0000_4000, name: "_x", isLocal: true),    // local slot
            indirect("__got", 0x1_0000_5000, name: "_y", isAbsolute: true), // absolute slot
        ])
        XCTAssertTrue(sym.isEmpty, "none of these forward to a named import")
        XCTAssertNil(sym.name(forStubTarget: 0x1_0000_1000))
        XCTAssertNil(sym.name(forStubTarget: 0x1_0000_2000))
    }

    func testFirstWriterWinsOnDuplicateSlotAddress() {
        let sym = StubCallSymbolicator(indirectSymbols: [
            indirect("__stubs", 0x1_0000_2000, name: "_first"),
            indirect("__stubs", 0x1_0000_2000, name: "_second"),   // corrupt duplicate
        ])
        XCTAssertEqual(sym.name(forStubTarget: 0x1_0000_2000), "_first")
    }

    func testEmptyInputYieldsEmptyMap() {
        XCTAssertTrue(StubCallSymbolicator(indirectSymbols: []).isEmpty)
    }

    /// End-to-end oracle: a real binary that calls `printf` must, after the full `analyze()`
    /// pipeline, carry a synthetic `_printf` symbol at its `__stubs` slot AND have a real `bl` call
    /// site that targets that address — so the listing resolves `bl <stub>` to the import name.
    /// Skipped if clang is unavailable.
    func testSymbolicatesImportStubInRealBinary() throws {
        let url = try RealImportBinary.build()
        let snapshot = try AnalysisEngine().analyze(url: url)

        let printfStub = snapshot.symbols.first { $0.name == "_printf" && $0.kind == "stub" }
        let stub = try XCTUnwrap(printfStub, "the printf import stub was not symbolicated")
        let stubAddress = try XCTUnwrap(stub.address)

        // The whole point: a real `bl` call site resolves to the named stub (bl <addr> -> _printf).
        let callsToStub = snapshot.xrefs.contains { $0.kind == XRefKind.call && $0.to == stubAddress }
        XCTAssertTrue(callsToStub, "a call must resolve to the named printf stub at \(String(stubAddress, radix: 16))")
    }
}

/// Compiles a tiny arm64 binary that calls `printf` (so its `__stubs`/indirect-symbol table carries
/// a real import stub) and returns its URL. Skips the test if `xcrun clang` is unavailable.
private enum RealImportBinary {
    static func build() throws -> URL {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else {
            throw XCTSkip("xcrun unavailable on this host")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("t.c")
        try "#include <stdio.h>\nint main(void){ printf(\"hi\"); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let binary = dir.appendingPathComponent("t")
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["clang", "-arch", "arm64", "-o", binary.path, source.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        let out = drain.text()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("clang did not produce a binary on this host: \(out)")
        }
        return binary
    }
}
