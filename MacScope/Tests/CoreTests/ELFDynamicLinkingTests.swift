import Foundation
import XCTest
@testable import MacScope

/// Adversarial oracle tests for the ELF dynamic-linking metadata parser
/// (`ELFDynamicLinking.swift`): relocations, symbol versioning (verneed/vernaux),
/// and PLT/GOT stub symbolication. The package's committed tests exercise NONE of
/// this code, so these are built from independent ground truth (the System V gABI
/// + clang-emitted reloc bytes verified by hand).
final class ELFDynamicLinkingTests: XCTestCase {

    // MARK: helpers

    private func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    private func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

    /// Elf64_Sym (24 bytes): name u32@0, info u8@4, other u8@5, shndx u16@6, value u64@8, size u64@16.
    private func sym64(name: UInt32, info: UInt8, shndx: UInt16, value: UInt64 = 0, size: UInt64 = 0) -> [UInt8] {
        u32(name) + [info, 0] + u16(shndx) + u64(value) + u64(size)
    }

    private func section(index: Int, name: String, type: UInt32, off: UInt64, size: UInt64,
                         link: UInt32 = 0, info: UInt32 = 0, entrySize: UInt64 = 0,
                         address: UInt64 = 0, flags: UInt64 = 0) -> ELFSectionInfo {
        ELFSectionInfo(index: index, name: name, type: type, flags: flags, address: address,
                       fileOffset: off, size: size, link: link, info: info, entrySize: entrySize)
    }

    private static let shtStrTab: UInt32 = 3
    private static let shtRela: UInt32 = 4
    private static let shtDynSym: UInt32 = 11
    private static let shtGNUVerNeed: UInt32 = 0x6ffffffe
    private static let shtGNUVerSym: UInt32 = 0x6fffffff
    private static let machineX86_64: UInt16 = 62
    private static let relocX86_64JumpSlot: UInt32 = 7

    /// Builds a buffer holding `.dynstr`, `.dynsym`, `.gnu.version`, `.gnu.version_r`
    /// with TWO distinct required libraries (libc.so.6/GLIBC_2.2.5 and libm.so.6/
    /// GLIBC_2.29). The two `Elf64_Verneed` records are laid out per the gABI:
    /// `vn_aux` is relative to the START OF EACH Verneed record (= 16), and `vn_next`
    /// chains record 0 → record 1 (= 32). Returns the buffer + the section table.
    private func twoLibraryVersionFixture() -> (Data, [ELFSectionInfo]) {
        // dynstr
        var strs: [UInt8] = [0]
        func add(_ s: String) -> UInt32 { let o = UInt32(strs.count); strs += Array(s.utf8) + [0]; return o }
        let nLibc = add("libc.so.6")
        let nG225 = add("GLIBC_2.2.5")
        let nLibm = add("libm.so.6")
        let nG229 = add("GLIBC_2.29")
        let nMalloc = add("malloc")
        let nPow = add("pow")

        var buf: [UInt8] = []
        let dynstrOff = UInt64(buf.count); buf += strs
        let dynstrSize = UInt64(strs.count)

        // dynsym: idx0 null, idx1 malloc (UNDEF), idx2 pow (UNDEF), idx3 pad
        let dynsymOff = UInt64(buf.count)
        buf += sym64(name: 0, info: 0, shndx: 0)
        buf += sym64(name: nMalloc, info: 0x12, shndx: 0) // GLOBAL|FUNC, UNDEF
        buf += sym64(name: nPow, info: 0x12, shndx: 0)
        buf += sym64(name: 0, info: 0, shndx: 0)
        let dynsymSize = UInt64(buf.count) - dynsymOff

        // .gnu.version: one u16 per dynsym. idx1 -> version index 2, idx2 -> 3.
        let versymOff = UInt64(buf.count)
        buf += u16(0) + u16(2) + u16(3) + u16(1)
        let versymSize = UInt64(buf.count) - versymOff

        // .gnu.version_r: two Verneed records, each with one Vernaux.
        let verneedOff = UInt64(buf.count)
        // Verneed0 (libc): version=1, cnt=1, file=libc, aux=16, next=32
        buf += u16(1) + u16(1) + u32(nLibc) + u32(16) + u32(32)
        // Vernaux0: hash=0, flags=0, other=2, name=GLIBC_2.2.5, next=0
        buf += u32(0) + u16(0) + u16(2) + u32(nG225) + u32(0)
        // Verneed1 (libm): version=1, cnt=1, file=libm, aux=16, next=0
        buf += u16(1) + u16(1) + u32(nLibm) + u32(16) + u32(0)
        // Vernaux1: other=3, name=GLIBC_2.29, next=0
        buf += u32(0) + u16(0) + u16(3) + u32(nG229) + u32(0)
        let verneedSize = UInt64(buf.count) - verneedOff

        let sections: [ELFSectionInfo] = [
            section(index: 0, name: "", type: 0, off: 0, size: 0),
            section(index: 1, name: ".dynstr", type: Self.shtStrTab, off: dynstrOff, size: dynstrSize),
            section(index: 2, name: ".dynsym", type: Self.shtDynSym, off: dynsymOff, size: dynsymSize, link: 1, entrySize: 24),
            section(index: 3, name: ".gnu.version", type: Self.shtGNUVerSym, off: versymOff, size: versymSize, link: 2, entrySize: 2),
            section(index: 4, name: ".gnu.version_r", type: Self.shtGNUVerNeed, off: verneedOff, size: verneedSize, link: 1, info: 2),
        ]
        return (Data(buf), sections)
    }

    // MARK: - symbol versioning

    /// The SECOND required library's version must resolve. `vn_aux` is relative to its
    /// own Verneed record; a parser that treats it as section-relative re-reads the
    /// first library's aux and loses GLIBC_2.29 entirely.
    func testVersionInfoResolvesAllRequiredLibraries() {
        let (data, sections) = twoLibraryVersionFixture()
        let reader = LittleEndianReader(data)
        let dynSymbols = parseDynamicSymbols(reader: reader, sections: sections, is64: true)
        XCTAssertEqual(dynSymbols.count, 4)
        XCTAssertEqual(dynSymbols[1].name, "malloc")
        XCTAssertEqual(dynSymbols[2].name, "pow")

        let info = parseVersionInfo(reader: reader, sections: sections, dynSymbols: dynSymbols, is64: true)

        // Both version indices must be recovered with the CORRECT names + libraries.
        XCTAssertEqual(info.versionIndexNames[2], "GLIBC_2.2.5")
        XCTAssertEqual(info.versionIndexNames[3], "GLIBC_2.29",
                       "second Verneed record's vernaux (vn_aux is record-relative) was not parsed")
        XCTAssertEqual(info.versionIndexLibraries[2], "libc.so.6")
        XCTAssertEqual(info.versionIndexLibraries[3], "libm.so.6")

        // Per-symbol decoration.
        XCTAssertEqual(info.decoratedName("malloc", symbolIndex: 1), "malloc@GLIBC_2.2.5")
        XCTAssertEqual(info.decoratedName("pow", symbolIndex: 2), "pow@GLIBC_2.29")
        XCTAssertEqual(info.libraryName(forSymbolIndex: 1), "libc.so.6")
        XCTAssertEqual(info.libraryName(forSymbolIndex: 2), "libm.so.6")
    }

    // MARK: - relocations (ground truth: clang -target x86_64-linux-gnu -fPIC -c)

    /// `.rela.text` from clang for `int callit(int x){return ext_func(x)+g;}`:
    ///   r_offset=0x0f sym=4 type=4(PLT32) addend=-4
    ///   r_offset=0x16 sym=5 type=42(REX_GOTPCRELX) addend=-4
    /// Verifies the ELF64 r_info split: sym = info>>32, type = info & 0xffffffff,
    /// and the signed addend.
    func testRelaParsesRInfoSplitAndSignedAddend() {
        var buf: [UInt8] = []
        // entry 0
        buf += u64(0x0f); buf += u64((UInt64(4) << 32) | 4); buf += u64(UInt64(bitPattern: -4))
        // entry 1
        buf += u64(0x16); buf += u64((UInt64(5) << 32) | 42); buf += u64(UInt64(bitPattern: -4))
        let sections = [
            section(index: 0, name: "", type: 0, off: 0, size: 0),
            section(index: 1, name: ".rela.text", type: Self.shtRela, off: 0, size: UInt64(buf.count), link: 0, info: 0, entrySize: 24),
        ]
        let reader = LittleEndianReader(Data(buf))
        let relocs = parseRelocations(reader: reader, sections: sections, is64: true)
        XCTAssertEqual(relocs.count, 2)
        XCTAssertEqual(relocs[0].offset, 0x0f)
        XCTAssertEqual(relocs[0].symIndex, 4)
        XCTAssertEqual(relocs[0].type, 4)
        XCTAssertEqual(relocs[0].addend, -4)
        XCTAssertTrue(relocs[0].isRela)
        XCTAssertEqual(relocs[1].offset, 0x16)
        XCTAssertEqual(relocs[1].symIndex, 5)
        XCTAssertEqual(relocs[1].type, 42)
        XCTAssertEqual(relocs[1].addend, -4)
    }

    /// REL (no addend) ELF64 split: same info layout, addend nil.
    func testRelParsesRInfoSplitNoAddend() {
        var buf: [UInt8] = []
        buf += u64(0x2000); buf += u64((UInt64(9) << 32) | 7) // sym 9, JUMP_SLOT
        let sections = [
            section(index: 0, name: "", type: 0, off: 0, size: 0),
            section(index: 1, name: ".rel.plt", type: 9 /* SHT_REL */, off: 0, size: UInt64(buf.count), link: 0, info: 0, entrySize: 16),
        ]
        let reader = LittleEndianReader(Data(buf))
        let relocs = parseRelocations(reader: reader, sections: sections, is64: true)
        XCTAssertEqual(relocs.count, 1)
        XCTAssertEqual(relocs[0].symIndex, 9)
        XCTAssertEqual(relocs[0].type, 7)
        XCTAssertNil(relocs[0].addend)
        XCTAssertFalse(relocs[0].isRela)
    }

    // MARK: - PLT/GOT stub symbolication

    /// A `.rela.plt` of JUMP_SLOT relocations + a `.plt` section must map each stub
    /// VA to its imported (version-decorated) name. With a resolver stub at slot 0,
    /// the first real stub is at `.plt` + 16.
    func testPLTStubsMapToImportNamesWithResolverStub() {
        let (verData, verSections) = twoLibraryVersionFixture()
        var buf = [UInt8](verData)

        // Append a .rela.plt with two JUMP_SLOT relocs (sym 1 = malloc, sym 2 = pow).
        let relaOff = UInt64(buf.count)
        // got slot VAs are arbitrary but distinct.
        buf += u64(0x404000); buf += u64((UInt64(1) << 32) | UInt64(Self.relocX86_64JumpSlot)); buf += u64(0)
        buf += u64(0x404008); buf += u64((UInt64(2) << 32) | UInt64(Self.relocX86_64JumpSlot)); buf += u64(0)
        let relaSize = UInt64(buf.count) - relaOff

        // .plt at VA 0x1000, 3 stubs (resolver + 2). file content size = 48.
        let pltVA: UInt64 = 0x1000
        let pltOff = UInt64(buf.count)
        buf += [UInt8](repeating: 0x90, count: 48)
        let pltSize = UInt64(buf.count) - pltOff

        var sections = verSections
        sections.append(section(index: 5, name: ".rela.plt", type: Self.shtRela, off: relaOff, size: relaSize, entrySize: 24))
        sections.append(section(index: 6, name: ".plt", type: 1, off: pltOff, size: pltSize, entrySize: 16, address: pltVA, flags: 6))

        let reader = LittleEndianReader(Data(buf))
        let dynSymbols = parseDynamicSymbols(reader: reader, sections: sections, is64: true)
        let info = parseVersionInfo(reader: reader, sections: sections, dynSymbols: dynSymbols, is64: true)
        let stubs = resolvePLTStubs(reader: reader, sections: sections, dynSymbols: dynSymbols,
                                    versionInfo: info, is64: true, machine: Self.machineX86_64)

        XCTAssertEqual(stubs.count, 2)
        // hasResolverStub == true (.plt not .plt.sec): first real stub at slot 1.
        XCTAssertEqual(stubs[0].stubVA, pltVA + 16)
        XCTAssertEqual(stubs[0].importName, "malloc@GLIBC_2.2.5")
        XCTAssertEqual(stubs[0].gotSlotVA, 0x404000)
        XCTAssertEqual(stubs[0].libraryName, "libc.so.6")
        XCTAssertEqual(stubs[1].stubVA, pltVA + 32)
        XCTAssertEqual(stubs[1].importName, "pow@GLIBC_2.29")
        XCTAssertEqual(stubs[1].gotSlotVA, 0x404008)
        XCTAssertEqual(stubs[1].libraryName, "libm.so.6")
    }

    // MARK: - malformed / adversarial

    /// vn_next is an UNSIGNED forward byte-distance, so a backwards "cycle" is unrepresentable; the
    /// degenerate runaway case is a zero-advance vn_next (0). The `nextNeed != 0` guard plus
    /// advancedRelativeOffset's `distance > 0` must terminate after this record rather than spin.
    func testVersionInfoTerminatesOnZeroAdvanceVerneed() {
        var strs: [UInt8] = [0]
        let nLib = UInt32(strs.count); strs += Array("a.so".utf8) + [0]
        let nVer = UInt32(strs.count); strs += Array("V1".utf8) + [0]
        var buf: [UInt8] = []
        let dynstrOff = UInt64(buf.count); buf += strs
        let dynstrSize = UInt64(strs.count)
        // single dynsym so versym matches.
        let dynsymOff = UInt64(buf.count)
        buf += sym64(name: 0, info: 0, shndx: 0)
        buf += sym64(name: nLib, info: 0x12, shndx: 0)
        let dynsymSize = UInt64(buf.count) - dynsymOff
        let versymOff = UInt64(buf.count)
        buf += u16(0) + u16(2)
        let versymSize = UInt64(buf.count) - versymOff
        let verneedOff = UInt64(buf.count)
        // vn_next = 0: terminator / zero-advance — the loop must stop after this record. aux=16.
        buf += u16(1) + u16(1) + u32(nLib) + u32(16) + u32(0)
        buf += u32(0) + u16(0) + u16(2) + u32(nVer) + u32(0)
        let verneedSize = UInt64(buf.count) - verneedOff

        let sections: [ELFSectionInfo] = [
            section(index: 0, name: "", type: 0, off: 0, size: 0),
            section(index: 1, name: ".dynstr", type: Self.shtStrTab, off: dynstrOff, size: dynstrSize),
            section(index: 2, name: ".dynsym", type: Self.shtDynSym, off: dynsymOff, size: dynsymSize, link: 1, entrySize: 24),
            section(index: 3, name: ".gnu.version", type: Self.shtGNUVerSym, off: versymOff, size: versymSize, link: 2, entrySize: 2),
            section(index: 4, name: ".gnu.version_r", type: Self.shtGNUVerNeed, off: verneedOff, size: verneedSize, link: 1, info: 1),
        ]
        let reader = LittleEndianReader(Data(buf))
        let dynSymbols = parseDynamicSymbols(reader: reader, sections: sections, is64: true)
        let info = parseVersionInfo(reader: reader, sections: sections, dynSymbols: dynSymbols, is64: true)
        XCTAssertEqual(info.versionIndexNames[2], "V1")
        XCTAssertEqual(info.decoratedName("a.so", symbolIndex: 1), "a.so@V1")
    }

    /// A non-zero vn_next that points PAST the verneed span must be rejected by
    /// advancedRelativeOffset's bounds check (no out-of-bounds read), terminating after the first
    /// record. This is the genuinely adversarial forward-offset path the zero-advance test cannot reach.
    func testVersionInfoTerminatesOnOutOfBoundsVerneedNext() {
        var strs: [UInt8] = [0]
        let nLib = UInt32(strs.count); strs += Array("a.so".utf8) + [0]
        let nVer = UInt32(strs.count); strs += Array("V1".utf8) + [0]
        var buf: [UInt8] = []
        let dynstrOff = UInt64(buf.count); buf += strs
        let dynstrSize = UInt64(strs.count)
        let dynsymOff = UInt64(buf.count)
        buf += sym64(name: 0, info: 0, shndx: 0)
        buf += sym64(name: nLib, info: 0x12, shndx: 0)
        let dynsymSize = UInt64(buf.count) - dynsymOff
        let versymOff = UInt64(buf.count)
        buf += u16(0) + u16(2)
        let versymSize = UInt64(buf.count) - versymOff
        let verneedOff = UInt64(buf.count)
        // vn_next = 0x10000 points far past the span -> advancedRelativeOffset returns nil, loop breaks.
        buf += u16(1) + u16(1) + u32(nLib) + u32(16) + u32(0x10000)
        buf += u32(0) + u16(0) + u16(2) + u32(nVer) + u32(0)
        let verneedSize = UInt64(buf.count) - verneedOff

        let sections: [ELFSectionInfo] = [
            section(index: 0, name: "", type: 0, off: 0, size: 0),
            section(index: 1, name: ".dynstr", type: Self.shtStrTab, off: dynstrOff, size: dynstrSize),
            section(index: 2, name: ".dynsym", type: Self.shtDynSym, off: dynsymOff, size: dynsymSize, link: 1, entrySize: 24),
            section(index: 3, name: ".gnu.version", type: Self.shtGNUVerSym, off: versymOff, size: versymSize, link: 2, entrySize: 2),
            section(index: 4, name: ".gnu.version_r", type: Self.shtGNUVerNeed, off: verneedOff, size: verneedSize, link: 1, info: 1),
        ]
        let reader = LittleEndianReader(Data(buf))
        let dynSymbols = parseDynamicSymbols(reader: reader, sections: sections, is64: true)
        let info = parseVersionInfo(reader: reader, sections: sections, dynSymbols: dynSymbols, is64: true)
        XCTAssertEqual(info.versionIndexNames[2], "V1",
                       "the first record must still parse before the out-of-bounds vn_next is rejected")
    }
}
