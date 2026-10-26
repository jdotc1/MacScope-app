import Foundation
import XCTest
@testable import MacScope

final class PELoaderTests: XCTestCase {
    /// A hand-built minimal PE32+ (x86_64) EXECUTABLE: DOS header → "PE\0\0" → COFF
    /// header → optional header → 2 sections (.text @rva0x1000, .rdata @rva0x2000) →
    /// COFF symbol table (two function symbols) → string table. ImageBase 0x140000000.
    ///
    ///   .text:  func1 @+0  = mov eax,7 ; ret        (b8 07 00 00 00 c3)
    ///           func2 @+6  = lea rax,[rip+0] ; ret  (48 8d 05 00 00 00 00 c3)
    ///   .rdata: "pe-test\0"
    private let imageBase: UInt64 = 0x1_4000_0000

    private func miniPE() -> Data {
        let text: [UInt8] = [0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3,
                             0x48, 0x8D, 0x05, 0x00, 0x00, 0x00, 0x00, 0xC3]
        let rdata = Array("pe-test\u{0}".utf8)

        // Fixed layout offsets.
        let peSigOffset = 0x40
        let coffOffset = peSigOffset + 4          // 0x44
        let optionalSize = 0x70
        let sectionTable = coffOffset + 20 + optionalSize // 0xC8
        let textRaw = sectionTable + 2 * 40        // 0x118
        let rdataRaw = textRaw + text.count        // 0x126
        let symtab = rdataRaw + rdata.count        // 0x12E
        let stringTable = symtab + 2 * 18          // 0x152

        var d = Data()
        // DOS header: "MZ", e_lfanew @0x3C → PE signature.
        d.append(contentsOf: [0x4D, 0x5A])
        pad(&d, to: 0x3C)
        d.appendU32(UInt32(peSigOffset))
        pad(&d, to: peSigOffset)

        // PE signature + COFF file header (20 bytes).
        d.append(contentsOf: [0x50, 0x45, 0x00, 0x00]) // "PE\0\0"
        d.appendU16(0x8664)                 // Machine (AMD64)
        d.appendU16(2)                      // NumberOfSections
        d.appendU32(0)                      // TimeDateStamp
        d.appendU32(UInt32(symtab))         // PointerToSymbolTable
        d.appendU32(2)                      // NumberOfSymbols
        d.appendU16(UInt16(optionalSize))   // SizeOfOptionalHeader
        d.appendU16(0x0022)                 // Characteristics (EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE)

        // Optional header (PE32+): magic, entry RVA @16, image base @24.
        let optionalStart = d.count
        d.appendU16(0x020B)                 // PE32+ magic
        pad(&d, to: optionalStart + 16)
        d.appendU32(0x1000)                 // AddressOfEntryPoint (RVA)
        pad(&d, to: optionalStart + 24)
        d.appendU64(imageBase)              // ImageBase
        pad(&d, to: optionalStart + optionalSize)

        // Section table.
        appendSection(&d, name: ".text", virtualSize: UInt32(text.count), rva: 0x1000,
                      rawSize: UInt32(text.count), rawPtr: UInt32(textRaw), characteristics: 0x6000_0020)  // CODE|EXEC|READ
        appendSection(&d, name: ".rdata", virtualSize: UInt32(rdata.count), rva: 0x2000,
                      rawSize: UInt32(rdata.count), rawPtr: UInt32(rdataRaw), characteristics: 0x4000_0040) // INIT_DATA|READ

        // Raw section data.
        pad(&d, to: textRaw); d.append(contentsOf: text)
        pad(&d, to: rdataRaw); d.append(contentsOf: rdata)

        // COFF symbol table: two external function symbols in .text (section 1).
        pad(&d, to: symtab)
        appendSymbol(&d, name: "func1", value: 0, sectionNumber: 1, type: 0x20, storageClass: 2)
        appendSymbol(&d, name: "func2", value: 6, sectionNumber: 1, type: 0x20, storageClass: 2)
        // String table (just the 4-byte size header; all names are inline).
        pad(&d, to: stringTable)
        d.appendU32(4)
        return d
    }

    private func pad(_ d: inout Data, to target: Int) {
        if d.count < target { d.append(contentsOf: [UInt8](repeating: 0, count: target - d.count)) }
    }

    private func appendSection(_ d: inout Data, name: String, virtualSize: UInt32, rva: UInt32, rawSize: UInt32, rawPtr: UInt32, characteristics: UInt32) {
        var nameBytes = Array(name.utf8)
        nameBytes.append(contentsOf: [UInt8](repeating: 0, count: max(0, 8 - nameBytes.count)))
        d.append(contentsOf: nameBytes.prefix(8))
        d.appendU32(virtualSize); d.appendU32(rva); d.appendU32(rawSize); d.appendU32(rawPtr)
        d.appendU32(0); d.appendU32(0); d.appendU16(0); d.appendU16(0); d.appendU32(characteristics)
    }

    private func appendSymbol(_ d: inout Data, name: String, value: UInt32, sectionNumber: Int16, type: UInt16, storageClass: UInt8) {
        var nameBytes = Array(name.utf8)
        nameBytes.append(contentsOf: [UInt8](repeating: 0, count: max(0, 8 - nameBytes.count)))
        d.append(contentsOf: nameBytes.prefix(8))
        d.appendU32(value); d.appendU16(UInt16(bitPattern: sectionNumber)); d.appendU16(type)
        d.append(storageClass); d.append(0) // StorageClass, NumberOfAuxSymbols
    }

    // MARK: - Tests

    func testPELoaderProjectsExecutableToNeutralModel() throws {
        let loaded = try PEBinaryLoader.parse(bytes: miniPE(), name: "mini.exe", path: "/tmp/mini.exe")
        XCTAssertEqual(loaded.cpuType, MachOConstants.cpuTypeX86_64)
        XCTAssertEqual(loaded.architectureDisplayName, "x86_64")
        XCTAssertEqual(loaded.fileTypeName, "PE executable")
        XCTAssertEqual(loaded.entryPointAddress, imageBase + 0x1000)
        XCTAssertEqual(loaded.executableTextSection?.name, ".text")
        XCTAssertEqual(loaded.executableTextSection?.address, imageBase + 0x1000)
        XCTAssertEqual(loaded.executableTextSection?.size, 14)
        XCTAssertEqual(loaded.functionStarts.sorted(), [imageBase + 0x1000, imageBase + 0x1006])
        XCTAssertEqual(loaded.symbols.first(where: { $0.name == "func1" })?.address, imageBase + 0x1000)
        XCTAssertTrue(loaded.symbols.contains { $0.name == "func2" })
        XCTAssertTrue(loaded.stringLiterals.contains { $0.value == "pe-test" && $0.address == imageBase + 0x2000 })
    }

    func testPEMagicDetection() {
        XCTAssertTrue(PEBinaryLoader.isPEorCOFF(miniPE()))
        XCTAssertTrue(PEBinaryLoader.isPEorCOFF(Data([0x64, 0x86]))) // bare COFF AMD64 machine word
        XCTAssertFalse(PEBinaryLoader.isPEorCOFF(Data([0x7F, 0x45, 0x4C, 0x46]))) // ELF
        XCTAssertFalse(PEBinaryLoader.isPEorCOFF(Data([0xCF, 0xFA, 0xED, 0xFE]))) // Mach-O
    }

    func testPELoaderRejectsMalformedHeaderWithoutCrashing() {
        var bad = miniPE()
        bad.replaceSubrange(0x3C..<0x40, with: [0xFF, 0xFF, 0xFF, 0x7F]) // e_lfanew way past the file
        XCTAssertThrowsError(try PEBinaryLoader.parse(bytes: bad, name: "bad", path: "bad"))
    }

    @MainActor
    func testAnalysisEngineLoadsAndDisassemblesPEEndToEnd() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacScopePE-\(UUID().uuidString).exe")
        try miniPE().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try await AnalysisEngine().openBinary(url: url)

        XCTAssertEqual(snapshot.binaries.first?.architecture, "x86_64")
        XCTAssertEqual(snapshot.binaries.first?.kind, "PE executable")
        XCTAssertEqual(Set(snapshot.functions.map(\.name)), ["func1", "func2"])
        XCTAssertEqual(snapshot.instructions.first?.address, imageBase + 0x1000)
        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["mov", "ret", "lea", "ret"])
        XCTAssertTrue(snapshot.stringLiterals.contains { $0.value == "pe-test" })
    }
}

private extension Data {
    mutating func appendU16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendU32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func appendU64(_ v: UInt64) { for i in 0..<8 { append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
}
