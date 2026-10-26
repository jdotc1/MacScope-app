import Foundation
import XCTest
@testable import MacScope

/// Regression tests for two CONFIRMED adversarial findings in `PEBinaryLoader`'s
/// untrusted data-directory parsing:
///
///  1. (HIGH) `parseImportDirectory` had a per-descriptor cap AND a per-thunk cap (each
///     `maxDirectoryEntries`), but NO aggregate cap — so they MULTIPLY. A crafted PE whose
///     many descriptors all point their ILT at a SHARED, in-bounds, NON-ZERO thunk region
///     (every read succeeds, no null terminator fires) would emit up to ~4.29e9
///     `ImportSummary` values → OOM / hang. The fix adds an aggregate counter capped at
///     `maxDirectoryEntries` that breaks BOTH loops.
///
///  2. (LOW) `parseExportDirectory` computed the forwarder range with a WRAPPING add
///     (`dirRVA &+ dirSize`) over the attacker-controlled `dirSize`; a huge `dirSize`
///     wrapped `dirEnd` below `dirStart`, so genuine forwarders (whose address falls inside
///     the export directory) were mislabeled `source == "export-table"`. The fix uses a
///     saturating add so `dirEnd` clamps to `UInt32.max`.
final class PEDirectoryDoSTests: XCTestCase {
    private let imageBase: UInt64 = 0x1_4000_0000
    private let sectionRVA: UInt32 = 0x1000
    private let sectionFileOffset = 0x400

    // MARK: - Finding #1: aggregate import cap (the per-descriptor × per-thunk MULTIPLY)

    /// Build a PE32+ whose descriptors ALL point their ILT/IAT at a single shared, in-bounds,
    /// non-zero ordinal-thunk region. Every read is in-bounds and non-zero (NOT truncated),
    /// and no entry is a null terminator within the region — exactly the shape that, before
    /// the fix, multiplied descriptors × thunks. With the aggregate cap the import count is
    /// pinned at `maxDirectoryEntries` and the parse returns promptly.
    func testAggregateImportCapPreventsDescriptorThunkMultiply() throws {
        // 3 descriptors, each ILT = a shared region of 30_000 non-zero ordinal thunks.
        // Potential without the aggregate cap: 3 × 30_000 = 90_000 (> 65_536 cap), and the
        // unbounded MULTIPLY bug would instead be 65_536 × 65_536 ≈ 4.29e9. With the fix the
        // total is pinned to exactly maxDirectoryEntries.
        let descriptorCount = 3
        let thunksPerRegion = 30_000

        let start = Date()
        let loaded = try PEBinaryLoader.parse(
            bytes: craftedSharedThunkPE(descriptorCount: descriptorCount, thunksPerRegion: thunksPerRegion),
            name: "dos.exe", path: "/tmp/dos.exe")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(loaded.imports.count, 65_536,
                       "imports must be capped at maxDirectoryEntries, not descriptors × thunks")
        // Every recovered import is the by-ordinal #7 we planted — proves the reads genuinely
        // succeeded (the region is in-bounds and non-zero, not silently truncated to empty).
        XCTAssertTrue(loaded.imports.allSatisfy { $0.libraryOrdinal == 7 },
                      "all capped imports should be the planted by-ordinal #7 entries")
        // "Promptly": the bounded work is ~65_536 appends; the unbounded bug would never
        // finish. A generous ceiling still distinguishes the two regimes by many orders.
        XCTAssertLessThan(elapsed, 10.0, "parse must return promptly under the aggregate cap")
    }

    /// A single descriptor whose shared region is itself larger than the cap proves the
    /// inner (per-thunk) loop also honors the aggregate counter and breaks mid-region.
    func testAggregateCapBreaksWithinASingleOversizedThunkRegion() throws {
        let loaded = try PEBinaryLoader.parse(
            bytes: craftedSharedThunkPE(descriptorCount: 1, thunksPerRegion: 70_000),
            name: "dos1.exe", path: "/tmp/dos1.exe")
        XCTAssertEqual(loaded.imports.count, 65_536,
                       "a single oversized region must still be capped at maxDirectoryEntries")
    }

    /// The aggregate IMPORT counter only advances when an entry is APPENDED. A hint/name
    /// thunk whose name resolves to "" hits `continue` and emits nothing — so it would not
    /// advance an append-only counter, leaving the descriptor × thunk MULTIPLY open via the
    /// empty-name path (65_536 descriptors × 65_536 empty-name thunks ≈ 4.29e9 read+scan
    /// iterations). The fix adds a separate WORK counter that advances on every thunk. Here
    /// 65_536 descriptors share one 70_000-entry region of non-zero, non-ordinal thunks that
    /// all resolve to an empty name: without the work budget this hangs for minutes; with it
    /// the parse touches ~65_536 thunks total and returns instantly with zero imports.
    func testEmptyNameThunksCannotBypassTheAggregateWorkBudget() throws {
        let start = Date()
        let loaded = try PEBinaryLoader.parse(
            bytes: craftedEmptyNameThunkPE(descriptorCount: 65_536, thunksPerRegion: 70_000),
            name: "dos2.exe", path: "/tmp/dos2.exe")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(loaded.imports.count, 0, "every thunk resolves to an empty name → no imports")
        XCTAssertLessThan(elapsed, 10.0, "the work budget must bound empty-name thunks too")
    }

    // MARK: - Finding #2: forwarder range must not wrap on a huge dirSize

    /// A genuine forwarder (EAT address points inside the export directory) with an oversized
    /// export `dirSize`. With the old wrapping add `dirEnd = dirRVA &+ dirSize` wraps below
    /// `dirStart`, so the forwarder is mislabeled "export-table". The saturating fix clamps
    /// `dirEnd` to `UInt32.max`, so it is correctly labeled "forwarder".
    func testForwarderWithOversizedDirSizeIsLabeledForwarder() throws {
        let loaded = try PEBinaryLoader.parse(
            bytes: forwarderPE(exportDirSize: 0xFFFF_FFF0),  // dirRVA + this wraps UInt32
            name: "fwd.exe", path: "/tmp/fwd.exe")
        let fwd = loaded.exports.first { $0.name == "Forwarded" }
        XCTAssertNotNil(fwd, "the named forwarder export should be recovered")
        XCTAssertEqual(fwd?.source, "forwarder",
                       "a forwarder must stay labeled 'forwarder' even with an overflowing dirSize")
    }

    // MARK: - Fixture: many descriptors sharing one non-zero ordinal-thunk region

    /// Layout inside one r/w-x section @ rva 0x1000 / file 0x400:
    ///   descriptors @ +0x00 : `descriptorCount` × 20-byte descriptors + a 20-byte null terminator
    ///   thunkRegion @ +0x400: `thunksPerRegion` × 8-byte non-zero ordinal thunks, then a u64 0 terminator
    private func craftedSharedThunkPE(descriptorCount: Int, thunksPerRegion: Int) -> Data {
        let descsRel = 0x00
        let thunkRel = 0x400
        let thunkBytes = thunksPerRegion * 8
        // Section big enough for descriptors + the shared thunk region + its terminator.
        let sectionRawSize = thunkRel + thunkBytes + 8 + 0x100

        let peSigOffset = 0x80
        let coffOffset = peSigOffset + 4
        let optionalSize = 0xF0
        let dataSection = sectionFileOffset

        var d = Data()
        d.append(contentsOf: [0x4D, 0x5A]) // "MZ"
        pad(&d, to: 0x3C)
        d.appendU32(UInt32(peSigOffset))
        pad(&d, to: peSigOffset)

        d.append(contentsOf: [0x50, 0x45, 0x00, 0x00]) // "PE\0\0"
        d.appendU16(0x8664)                 // Machine AMD64
        d.appendU16(1)                      // NumberOfSections
        d.appendU32(0)                      // TimeDateStamp
        d.appendU32(0)                      // PointerToSymbolTable (none)
        d.appendU32(0)                      // NumberOfSymbols
        d.appendU16(UInt16(optionalSize))   // SizeOfOptionalHeader
        d.appendU16(0x0022)                 // Characteristics

        let optionalStart = d.count
        d.appendU16(0x020B)                 // PE32+ magic
        pad(&d, to: optionalStart + 16)
        d.appendU32(0x0000)                 // AddressOfEntryPoint
        pad(&d, to: optionalStart + 24)
        d.appendU64(imageBase)              // ImageBase
        pad(&d, to: optionalStart + 108)
        d.appendU32(16)                     // NumberOfRvaAndSizes
        pad(&d, to: optionalStart + 112)    // data directory array
        // [0] EXPORT (none)
        d.appendU32(0); d.appendU32(0)
        // [1] IMPORT → descriptor array, size = descriptors + terminator.
        d.appendU32(rva(descsRel)); d.appendU32(UInt32((descriptorCount + 1) * 20))
        pad(&d, to: optionalStart + optionalSize)

        appendSection(&d, name: ".text", virtualSize: UInt32(sectionRawSize), rva: sectionRVA,
                      rawSize: UInt32(sectionRawSize), rawPtr: UInt32(dataSection),
                      characteristics: 0x6000_0020)  // code | execute | read

        pad(&d, to: dataSection)
        var sec = [UInt8](repeating: 0, count: sectionRawSize)

        // Every descriptor shares the SAME non-zero thunk region (ILT == IAT == thunkRel).
        for i in 0..<descriptorCount {
            let base = descsRel + i * 20
            putU32(&sec, base + 0, rva(thunkRel))   // OriginalFirstThunk (ILT)
            putU32(&sec, base + 12, 0)              // Name (none → library nil; fine for ordinals)
            putU32(&sec, base + 16, rva(thunkRel))  // FirstThunk (IAT)
        }
        // descriptor[descriptorCount] is all-zero (null terminator) — already zero.

        // Shared region: non-zero by-ordinal PE32+ thunks (high bit set, ordinal 7), then a
        // u64 0 terminator so the inner walk exits cleanly at the region's true end.
        let ordinalThunk: UInt64 = 0x8000_0000_0000_0000 | 7
        for t in 0..<thunksPerRegion {
            putU64(&sec, thunkRel + t * 8, ordinalThunk)
        }
        putU64(&sec, thunkRel + thunksPerRegion * 8, 0)

        d.append(contentsOf: sec)
        return d
    }

    // MARK: - Fixture: many descriptors sharing one EMPTY-NAME hint/name region

    /// Like `craftedSharedThunkPE`, but the shared region holds non-zero, NON-ordinal
    /// hint/name thunks whose `hintNameRVA` points at an all-zero area, so every name
    /// resolves to "" (the `continue` / no-append path). Layout in one r/w section:
    ///   descriptors  @ +0x00     : `descriptorCount` × 20-byte descriptors + a null terminator
    ///   thunkRegion  @ thunkRel   : `thunksPerRegion` × 8-byte non-zero/non-ordinal thunks + u64 0
    ///   zeroName     @ zeroNameRel: all-zero (the empty name the thunks point at)
    private func craftedEmptyNameThunkPE(descriptorCount: Int, thunksPerRegion: Int) -> Data {
        let descsRel = 0x00
        let descBytes = (descriptorCount + 1) * 20
        // Place the thunk region after the descriptor table (8-byte aligned).
        let thunkRel = (descsRel + descBytes + 0xF) & ~0xF
        let thunkBytes = thunksPerRegion * 8
        let zeroNameRel = thunkRel + thunkBytes + 8 + 0x10   // past the region + its terminator
        let sectionRawSize = zeroNameRel + 0x100

        let peSigOffset = 0x80
        let optionalSize = 0xF0
        let dataSection = sectionFileOffset

        var d = Data()
        d.append(contentsOf: [0x4D, 0x5A]) // "MZ"
        pad(&d, to: 0x3C)
        d.appendU32(UInt32(peSigOffset))
        pad(&d, to: peSigOffset)

        d.append(contentsOf: [0x50, 0x45, 0x00, 0x00]) // "PE\0\0"
        d.appendU16(0x8664)
        d.appendU16(1)
        d.appendU32(0)
        d.appendU32(0)
        d.appendU32(0)
        d.appendU16(UInt16(optionalSize))
        d.appendU16(0x0022)

        let optionalStart = d.count
        d.appendU16(0x020B)                 // PE32+ magic
        pad(&d, to: optionalStart + 24)
        d.appendU64(imageBase)
        pad(&d, to: optionalStart + 108)
        d.appendU32(16)                     // NumberOfRvaAndSizes
        pad(&d, to: optionalStart + 112)
        d.appendU32(0); d.appendU32(0)      // [0] EXPORT (none)
        // [1] IMPORT → descriptor array.
        d.appendU32(rva(descsRel)); d.appendU32(UInt32(descBytes))
        pad(&d, to: optionalStart + optionalSize)

        appendSection(&d, name: ".idata", virtualSize: UInt32(sectionRawSize), rva: sectionRVA,
                      rawSize: UInt32(sectionRawSize), rawPtr: UInt32(dataSection),
                      characteristics: 0xC000_0040)  // read | write | initialized data

        pad(&d, to: dataSection)
        var sec = [UInt8](repeating: 0, count: sectionRawSize)

        // Every descriptor shares the SAME non-zero thunk region (ILT == IAT == thunkRel).
        for i in 0..<descriptorCount {
            let base = descsRel + i * 20
            putU32(&sec, base + 0, rva(thunkRel))   // OriginalFirstThunk (ILT)
            putU32(&sec, base + 12, 0)              // Name (none)
            putU32(&sec, base + 16, rva(thunkRel))  // FirstThunk (IAT)
        }
        // descriptor[descriptorCount] is all-zero (null terminator) — already zero.

        // Non-zero, NON-ordinal thunks (high bit clear) whose hintNameRVA points at the
        // all-zero `zeroNameRel` region → nameAtRVA(hintNameRVA + 2) == "" → empty name.
        let emptyNameThunk = UInt64(rva(zeroNameRel))
        for t in 0..<thunksPerRegion {
            putU64(&sec, thunkRel + t * 8, emptyNameThunk)
        }
        putU64(&sec, thunkRel + thunksPerRegion * 8, 0) // region terminator

        d.append(contentsOf: sec)
        return d
    }

    // MARK: - Fixture: a single named forwarder export + tunable export dirSize

    /// One export, named "Forwarded", whose EAT address points INSIDE the export directory
    /// (the canonical forwarder shape). `exportDirSize` is whatever the caller wants so the
    /// forwarder-range overflow can be exercised.
    private func forwarderPE(exportDirSize: UInt32) -> Data {
        // Sub-layout within the data section.
        let exportDirRel = 0x00     // IMAGE_EXPORT_DIRECTORY (40 bytes)
        let eatRel = 0x40           // AddressOfFunctions (1 u32)
        let namePtrRel = 0x60       // AddressOfNames (1 u32)
        let nameOrdRel = 0x80       // AddressOfNameOrdinals (1 u16)
        let exportName0Rel = 0x90   // "Forwarded\0"
        let exportDllNameRel = 0xA0 // "MYDLL.DLL\0"
        let forwardStringRel = 0xB0 // the forwarder target string "OTHER.Func\0" (lives in the dir)

        let peSigOffset = 0x80
        let coffOffset = peSigOffset + 4
        let optionalSize = 0xF0
        let dataSection = sectionFileOffset

        var d = Data()
        d.append(contentsOf: [0x4D, 0x5A]) // "MZ"
        pad(&d, to: 0x3C)
        d.appendU32(UInt32(peSigOffset))
        pad(&d, to: peSigOffset)

        d.append(contentsOf: [0x50, 0x45, 0x00, 0x00])
        d.appendU16(0x8664)
        d.appendU16(1)
        d.appendU32(0)
        d.appendU32(0)
        d.appendU32(0)
        d.appendU16(UInt16(optionalSize))
        d.appendU16(0x0022)

        let optionalStart = d.count
        d.appendU16(0x020B)
        pad(&d, to: optionalStart + 16)
        d.appendU32(0x0000)
        pad(&d, to: optionalStart + 24)
        d.appendU64(imageBase)
        pad(&d, to: optionalStart + 108)
        d.appendU32(16)                     // NumberOfRvaAndSizes
        pad(&d, to: optionalStart + 112)
        // [0] EXPORT → directory @ exportDirRel, SIZE = the (attacker-controlled) value.
        d.appendU32(rva(exportDirRel)); d.appendU32(exportDirSize)
        // [1] IMPORT (none)
        d.appendU32(0); d.appendU32(0)
        pad(&d, to: optionalStart + optionalSize)

        appendSection(&d, name: ".rdata", virtualSize: 0x1000, rva: sectionRVA,
                      rawSize: 0x800, rawPtr: UInt32(dataSection), characteristics: 0x4000_0040)

        pad(&d, to: dataSection)
        var sec = [UInt8](repeating: 0, count: 0x800)

        // IMAGE_EXPORT_DIRECTORY.
        putU32(&sec, exportDirRel + 12, rva(exportDllNameRel)) // Name
        putU32(&sec, exportDirRel + 16, 1)                     // OrdinalBase
        putU32(&sec, exportDirRel + 20, 1)                     // NumberOfFunctions
        putU32(&sec, exportDirRel + 24, 1)                     // NumberOfNames
        putU32(&sec, exportDirRel + 28, rva(eatRel))           // AddressOfFunctions
        putU32(&sec, exportDirRel + 32, rva(namePtrRel))       // AddressOfNames
        putU32(&sec, exportDirRel + 36, rva(nameOrdRel))       // AddressOfNameOrdinals

        // EAT[0] → an RVA INSIDE the export directory (forwarder target string) → forwarder.
        putU32(&sec, eatRel + 0, rva(forwardStringRel))
        putU32(&sec, namePtrRel + 0, rva(exportName0Rel))
        putU16(&sec, nameOrdRel + 0, 0)
        putCString(&sec, exportName0Rel, "Forwarded")
        putCString(&sec, exportDllNameRel, "MYDLL.DLL")
        putCString(&sec, forwardStringRel, "OTHER.Func")

        d.append(contentsOf: sec)
        return d
    }

    // MARK: - Builders

    private func rva(_ rel: Int) -> UInt32 { sectionRVA + UInt32(rel) }

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
