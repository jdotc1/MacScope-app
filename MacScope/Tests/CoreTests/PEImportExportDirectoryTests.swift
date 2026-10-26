import Foundation
import XCTest
@testable import MacScope

/// Proves PE optional-header data-directory parsing: real linked PE images carry their
/// imports/exports in `IMAGE_DIRECTORY_ENTRY_IMPORT` / `IMAGE_DIRECTORY_ENTRY_EXPORT`
/// (NOT in a COFF symbol table), so these tests build a synthetic PE32+ that has BOTH
/// directories — and NO COFF symbol table — and assert the names/addresses are recovered.
final class PEImportExportDirectoryTests: XCTestCase {
    private let imageBase: UInt64 = 0x1_4000_0000

    // RVAs we lay out (all inside a single .rdata-style section @ rva 0x1000, file 0x400).
    private let sectionRVA: UInt32 = 0x1000
    private let sectionFileOffset = 0x400

    // Sub-layout WITHIN the data section (offsets relative to sectionFileOffset / +sectionRVA).
    // Import side:
    //   importDescriptors  @ +0x00   (two 20-byte descriptors + null terminator = 60 bytes)
    //   importLookupTable  @ +0x40   (PE32+: 8-byte thunks, null terminated)
    //   hintNameAdd        @ +0x80   ("Add\0" preceded by 2-byte hint)
    //   hintNameSub        @ +0x90   ("Sub\0")
    //   dllNameKernel      @ +0xA0   ("MYLIB.DLL\0")
    // Export side:
    //   exportDirectory    @ +0x100  (40-byte IMAGE_EXPORT_DIRECTORY)
    //   eat                @ +0x140  (NumberOfFunctions u32 entries)
    //   namePointers       @ +0x160  (NumberOfNames u32 entries)
    //   nameOrdinals       @ +0x180  (NumberOfNames u16 entries)
    //   exportName0        @ +0x190  ("Start\0")
    //   exportDllName      @ +0x1A0  ("MYDLL.DLL\0")
    private let descsRel = 0x00
    private let iltRel = 0x40
    private let hintAddRel = 0x80
    private let hintSubRel = 0x90
    private let dllNameRel = 0xA0
    private let exportDirRel = 0x100
    private let eatRel = 0x140
    private let namePtrRel = 0x160
    private let nameOrdRel = 0x180
    private let exportName0Rel = 0x190
    private let exportDllNameRel = 0x1A0

    private func rva(_ rel: Int) -> UInt32 { sectionRVA + UInt32(rel) }

    /// Build a minimal PE32+ EXE with import + export directories and no symbol table.
    private func miniPE() -> Data {
        let peSigOffset = 0x80
        let coffOffset = peSigOffset + 4
        let optionalSize = 0xF0          // PE32+ optional header incl. 16 data directories
        let sectionTable = coffOffset + 20 + optionalSize
        let dataSection = sectionFileOffset

        var d = Data()
        d.append(contentsOf: [0x4D, 0x5A]) // "MZ"
        pad(&d, to: 0x3C)
        d.appendU32(UInt32(peSigOffset))
        pad(&d, to: peSigOffset)

        // PE signature + COFF file header.
        d.append(contentsOf: [0x50, 0x45, 0x00, 0x00]) // "PE\0\0"
        d.appendU16(0x8664)                 // Machine AMD64
        d.appendU16(1)                      // NumberOfSections
        d.appendU32(0)                      // TimeDateStamp
        d.appendU32(0)                      // PointerToSymbolTable (NONE)
        d.appendU32(0)                      // NumberOfSymbols
        d.appendU16(UInt16(optionalSize))   // SizeOfOptionalHeader
        d.appendU16(0x0022)                 // Characteristics

        // Optional header (PE32+).
        let optionalStart = d.count
        d.appendU16(0x020B)                 // PE32+ magic
        pad(&d, to: optionalStart + 16)
        d.appendU32(0x0000)                 // AddressOfEntryPoint
        pad(&d, to: optionalStart + 24)
        d.appendU64(imageBase)              // ImageBase
        pad(&d, to: optionalStart + 108)
        d.appendU32(16)                     // NumberOfRvaAndSizes
        // Data directory array starts at optionalStart + 112.
        pad(&d, to: optionalStart + 112)
        // [0] EXPORT
        d.appendU32(rva(exportDirRel)); d.appendU32(0x80)
        // [1] IMPORT
        d.appendU32(rva(descsRel)); d.appendU32(60)
        // remaining 14 directories zeroed
        pad(&d, to: optionalStart + optionalSize)

        // Section table: one r/o data section covering the whole directory layout.
        appendSection(&d, name: ".rdata", virtualSize: 0x1000, rva: sectionRVA,
                      rawSize: 0x800, rawPtr: UInt32(dataSection), characteristics: 0x4000_0040)

        // Raw section bytes.
        pad(&d, to: dataSection)
        var sec = [UInt8](repeating: 0, count: 0x800)

        // --- Import descriptors ---
        // descriptor 0: ILT@iltRel, Name@dllNameRel, IAT (reuse ILT for the test).
        putU32(&sec, descsRel + 0, rva(iltRel))       // OriginalFirstThunk
        putU32(&sec, descsRel + 12, rva(dllNameRel))  // Name
        putU32(&sec, descsRel + 16, rva(iltRel))      // FirstThunk
        // descriptor 1: all-zero null terminator (already zero) at descsRel+20.

        // ILT (PE32+ 8-byte thunks): [0] = hint/name Add, [1] = ordinal import #7, [2] = NULL.
        putU64(&sec, iltRel + 0, UInt64(rva(hintAddRel)))           // by name "Add"
        putU64(&sec, iltRel + 8, 0x8000_0000_0000_0000 | 7)         // by ordinal 7
        putU64(&sec, iltRel + 16, 0)                                // terminator

        // hint/name entries (u16 hint + name).
        putU16(&sec, hintAddRel, 0); putCString(&sec, hintAddRel + 2, "Add")
        putU16(&sec, hintSubRel, 0); putCString(&sec, hintSubRel + 2, "Sub")
        putCString(&sec, dllNameRel, "MYLIB.DLL")

        // --- Export directory ---
        // Two exported functions; one named ("Start", ordinal index 0), one by-ordinal only.
        putU32(&sec, exportDirRel + 12, rva(exportDllNameRel)) // Name (the DLL's own name)
        putU32(&sec, exportDirRel + 16, 5)                     // OrdinalBase = 5
        putU32(&sec, exportDirRel + 20, 2)                     // NumberOfFunctions
        putU32(&sec, exportDirRel + 24, 1)                     // NumberOfNames
        putU32(&sec, exportDirRel + 28, rva(eatRel))           // AddressOfFunctions
        putU32(&sec, exportDirRel + 32, rva(namePtrRel))       // AddressOfNames
        putU32(&sec, exportDirRel + 36, rva(nameOrdRel))       // AddressOfNameOrdinals

        // EAT: index 0 -> 0x3000 (named "Start"), index 1 -> 0x3100 (ordinal-only #6).
        putU32(&sec, eatRel + 0, 0x3000)
        putU32(&sec, eatRel + 4, 0x3100)
        // Name pointer array (1 entry) -> "Start".
        putU32(&sec, namePtrRel + 0, rva(exportName0Rel))
        // Name ordinal array (1 entry) -> EAT index 0.
        putU16(&sec, nameOrdRel + 0, 0)
        putCString(&sec, exportName0Rel, "Start")
        putCString(&sec, exportDllNameRel, "MYDLL.DLL")

        d.append(contentsOf: sec)
        return d
    }

    // MARK: - Tests

    func testRecoversImportsFromImportDirectory() throws {
        let loaded = try PEBinaryLoader.parse(bytes: miniPE(), name: "mini.exe", path: "/tmp/mini.exe")

        let add = loaded.imports.first { $0.name == "Add" }
        XCTAssertNotNil(add, "named import 'Add' should be recovered from the ILT hint/name entry")
        XCTAssertEqual(add?.libraryName, "MYLIB.DLL")
        XCTAssertNil(add?.libraryOrdinal)

        let ordinalImport = loaded.imports.first { $0.libraryOrdinal == 7 }
        XCTAssertNotNil(ordinalImport, "by-ordinal import #7 should be recovered")
        XCTAssertEqual(ordinalImport?.libraryName, "MYLIB.DLL")
    }

    func testRecoversExportsFromExportDirectory() throws {
        let loaded = try PEBinaryLoader.parse(bytes: miniPE(), name: "mini.exe", path: "/tmp/mini.exe")

        let start = loaded.exports.first { $0.name == "Start" }
        XCTAssertNotNil(start, "named export 'Start' should be recovered from the name table")
        XCTAssertEqual(start?.address, imageBase + 0x3000)
        XCTAssertEqual(start?.source, "export-table")

        // The second EAT slot has no name; ordinalBase 5 + index 1 => ordinal 6.
        let byOrdinal = loaded.exports.first { $0.name == "#6" }
        XCTAssertNotNil(byOrdinal, "by-ordinal-only export #6 should be recovered")
        XCTAssertEqual(byOrdinal?.address, imageBase + 0x3100)
    }

    /// The data directories are the ONLY import/export source here (no symbol table), so
    /// these prove the gap that COFF-symbol-only parsing left empty is now filled.
    func testImageWithoutSymbolTableStillHasImportsAndExports() throws {
        let loaded = try PEBinaryLoader.parse(bytes: miniPE(), name: "mini.exe", path: "/tmp/mini.exe")
        XCTAssertTrue(loaded.symbols.isEmpty, "fixture intentionally carries no COFF symbol table")
        XCTAssertFalse(loaded.imports.isEmpty, "imports must come from the import directory")
        XCTAssertFalse(loaded.exports.isEmpty, "exports must come from the export directory")
    }

    /// Malformed data-directory RVAs (pointing past the file / into nowhere) must not trap.
    func testMalformedDataDirectoriesDoNotTrap() throws {
        var bytes = miniPE()
        // Find the optional header to corrupt the directory entries in place.
        let peSigOffset = 0x80
        let coffOffset = peSigOffset + 4
        let optionalStart = coffOffset + 20
        let dirArray = optionalStart + 112
        // EXPORT dir [0] RVA → 0x7FFF_FFFF (way past file); IMPORT dir [1] RVA likewise.
        bytes.replaceSubrange(dirArray..<dirArray + 4, with: [0xFF, 0xFF, 0xFF, 0x7F])
        bytes.replaceSubrange(dirArray + 8..<dirArray + 12, with: [0xFF, 0xFF, 0xFF, 0x7F])
        // Should parse without crashing (imports/exports simply unrecoverable).
        let loaded = try PEBinaryLoader.parse(bytes: bytes, name: "bad.exe", path: "/tmp/bad.exe")
        XCTAssertNotNil(loaded)
    }

    /// A truncated import table (thunk array running off the file end) must not trap.
    func testTruncatedImportThunkArrayDoesNotTrap() throws {
        var bytes = miniPE()
        // Chop the file right after the import descriptors / ILT start so the thunk walk
        // reads past the end; the bounds-checked reader must yield nil, not crash.
        let cut = sectionFileOffset + iltRel + 4
        bytes = bytes.prefix(cut)
        let loaded = try PEBinaryLoader.parse(bytes: bytes, name: "trunc.exe", path: "/tmp/trunc.exe")
        XCTAssertNotNil(loaded)
    }

    // MARK: - Builders

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

    private func putU16(_ b: inout [UInt8], _ off: Int, _ v: UInt16) {
        b[off] = UInt8(v & 0xFF); b[off + 1] = UInt8(v >> 8)
    }
    private func putU32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        for i in 0..<4 { b[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
    }
    private func putU64(_ b: inout [UInt8], _ off: Int, _ v: UInt64) {
        for i in 0..<8 { b[off + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }
    private func putCString(_ b: inout [UInt8], _ off: Int, _ s: String) {
        let bytes = Array(s.utf8)
        for (i, byte) in bytes.enumerated() { b[off + i] = byte }
        b[off + bytes.count] = 0
    }
}

private extension Data {
    mutating func appendU16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendU32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func appendU64(_ v: UInt64) { for i in 0..<8 { append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
}
