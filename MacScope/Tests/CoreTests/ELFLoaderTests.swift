import Foundation
import XCTest
@testable import MacScope

final class ELFLoaderTests: XCTestCase {
    /// CP9 E06: malformed declared tables remain best-effort loads, with
    /// explicit degradation evidence instead of silently missing metadata.
    func testMalformedMetadataTablesDiscloseDegradation() throws {
        let cases = [
            ("elf-bad-strtab-extent.elf", "ELF symbol names were skipped"),
            ("elf-bad-symtab-extent.elf", "ELF symbol table was skipped"),
            ("elf-short-rela-entry.elf", "ELF relocation table was skipped")
        ]
        for (name, messagePrefix) in cases {
            let fixture = TestSourceRoot.url.appendingPathComponent(
                "MacScope/Tests/CoreTests/GoldenFixtures/elf-table-degradation/" + name
            )
            let loaded = try ELFBinaryLoader.parse(
                bytes: Data(contentsOf: fixture), name: name, path: fixture.path
            )
            XCTAssertTrue(loaded.diagnosticTruncations.contains { $0.message.hasPrefix(messagePrefix) }, name)
        }
    }

    /// CP9 E07: the full table contains "external", while .dynsym declares
    /// "imported" for a dynamic relocation. Both must survive import projection.
    func testDynamicImportSurvivesPreferredFullSymbolTable() throws {
        let fixture = TestSourceRoot.url.appendingPathComponent(
            "MacScope/Tests/CoreTests/GoldenFixtures/elf-dynsym-import-with-symtab.elf"
        )
        let bytes = try Data(contentsOf: fixture)
        let loaded = try ELFBinaryLoader.parse(bytes: bytes, name: fixture.lastPathComponent, path: fixture.path)
        XCTAssertEqual(loaded.imports.map(\.name).sorted(), ["external", "imported"])
        XCTAssertEqual(Set(loaded.imports.map(\.name)).count, loaded.imports.count)
        XCTAssertTrue(loaded.symbols.contains { $0.name == "globalfn" })
    }

    /// A hand-built minimal ELF64 LSB **executable** (x86_64), section-only (no
    /// program headers — the loader reads the section table). Two functions live in
    /// `.text` at distinct virtual addresses (so symbol addresses don't collapse the
    /// way a relocatable `.o` would) and `.rodata` holds an "elf-prog" C-string.
    ///
    ///   .text  @0x1000:  compute = mov eax,7 ; ret        (b8 07 00 00 00 c3)
    ///          @0x1006:  tag     = lea rax,[rip+0] ; ret  (48 8d 05 00 00 00 00 c3)
    ///   .rodata@0x2000:  "elf-prog\0"
    private func miniExecutableELF() -> Data {
        let text: [UInt8] = [0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3,
                             0x48, 0x8D, 0x05, 0x00, 0x00, 0x00, 0x00, 0xC3]
        let rodata = Array("elf-prog\u{0}".utf8)                                   // 9
        let shstr = Array("\u{0}.text\u{0}.rodata\u{0}.shstrtab\u{0}.symtab\u{0}.strtab\u{0}".utf8) // 41
        let strtab = Array("\u{0}compute\u{0}tag\u{0}".utf8)                        // 13

        let textOff = 64
        let rodataOff = textOff + text.count          // 78
        let shstrOff = rodataOff + rodata.count        // 87
        let symtabOff = shstrOff + shstr.count         // 128
        let strtabOff = symtabOff + 72                 // 200 (3 symbols × 24)
        let shoff = strtabOff + strtab.count           // 213

        var d = Data()
        // ELF header (64 bytes)
        d.append(contentsOf: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0]) // magic, ELFCLASS64, LSB, version, SYSV
        d.append(contentsOf: [UInt8](repeating: 0, count: 8))      // e_ident padding
        d.appendU16(2)                  // e_type ET_EXEC
        d.appendU16(62)                 // e_machine EM_X86_64
        d.appendU32(1)                  // e_version
        d.appendU64(0x1000)             // e_entry
        d.appendU64(0)                  // e_phoff (none)
        d.appendU64(UInt64(shoff))      // e_shoff
        d.appendU32(0)                  // e_flags
        d.appendU16(64)                 // e_ehsize
        d.appendU16(0)                  // e_phentsize
        d.appendU16(0)                  // e_phnum
        d.appendU16(64)                 // e_shentsize
        d.appendU16(6)                  // e_shnum
        d.appendU16(3)                  // e_shstrndx (.shstrtab)

        // Section contents
        d.append(contentsOf: text)
        d.append(contentsOf: rodata)
        d.append(contentsOf: shstr)
        appendSym(&d, name: 0, info: 0, shndx: 0, value: 0, size: 0)         // null symbol
        appendSym(&d, name: 1, info: 0x12, shndx: 1, value: 0x1000, size: 6) // compute (GLOBAL|FUNC, .text)
        appendSym(&d, name: 9, info: 0x12, shndx: 1, value: 0x1006, size: 8) // tag
        d.append(contentsOf: strtab)

        // Section header table (6 × 64)
        appendShdr(&d, name: 0, type: 0, flags: 0, addr: 0, off: 0, size: 0, link: 0, info: 0, entsize: 0)                                  // NULL
        appendShdr(&d, name: 1, type: 1, flags: 6, addr: 0x1000, off: UInt64(textOff), size: UInt64(text.count), link: 0, info: 0, entsize: 0)   // .text (ALLOC|EXEC)
        appendShdr(&d, name: 7, type: 1, flags: 2, addr: 0x2000, off: UInt64(rodataOff), size: UInt64(rodata.count), link: 0, info: 0, entsize: 0) // .rodata (ALLOC)
        appendShdr(&d, name: 15, type: 3, flags: 0, addr: 0, off: UInt64(shstrOff), size: UInt64(shstr.count), link: 0, info: 0, entsize: 0)       // .shstrtab
        appendShdr(&d, name: 25, type: 2, flags: 0, addr: 0, off: UInt64(symtabOff), size: 72, link: 5, info: 1, entsize: 24)                      // .symtab (link → .strtab)
        appendShdr(&d, name: 33, type: 3, flags: 0, addr: 0, off: UInt64(strtabOff), size: UInt64(strtab.count), link: 0, info: 0, entsize: 0)     // .strtab
        return d
    }

    /// A hand-built ELF64 LSB shared object with the dynamic-linking pieces the
    /// section-table loader needs for PLT import projection.
    ///
    ///   .plt          @0x401020: PLT0 + one 16-byte puts stub
    ///   .got.plt      @0x403000: imported slot at 0x403018
    ///   .dynsym/.dynstr: null + undefined puts
    ///   .rela.plt:    R_X86_64_JUMP_SLOT, sym=1, r_offset=0x403018
    ///   .gnu.version: dynsym[1] -> version index 2
    ///   .gnu.version_r: version index 2 -> libc.so.6 / GLIBC_2.2.5
    private func miniDynamicELF() -> Data {
        let plt = [UInt8](repeating: 0x90, count: 32)
        let got = [UInt8](repeating: 0, count: 32)
        let dynstr = Array("\u{0}puts\u{0}libc.so.6\u{0}GLIBC_2.2.5\u{0}".utf8)
        let shstr = Array("\u{0}.plt\u{0}.got.plt\u{0}.dynsym\u{0}.dynstr\u{0}.rela.plt\u{0}.gnu.version\u{0}.gnu.version_r\u{0}.shstrtab\u{0}".utf8)

        let pltOff = 64
        let gotOff = pltOff + plt.count                 // 96
        let dynsymOff = gotOff + got.count              // 128
        let dynstrOff = dynsymOff + 48                  // 176 (2 symbols x 24)
        let relaPltOff = dynstrOff + dynstr.count       // 204
        let versymOff = relaPltOff + 24                 // 228
        let verneedOff = versymOff + 4                  // 232
        let shstrOff = verneedOff + 32                  // 264
        let shoff = shstrOff + shstr.count              // 343

        var d = Data()
        // ELF header (64 bytes)
        d.append(contentsOf: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])
        d.append(contentsOf: [UInt8](repeating: 0, count: 8))
        d.appendU16(3)                  // e_type ET_DYN
        d.appendU16(62)                 // e_machine EM_X86_64
        d.appendU32(1)                  // e_version
        d.appendU64(0)                  // e_entry
        d.appendU64(0)                  // e_phoff
        d.appendU64(UInt64(shoff))      // e_shoff
        d.appendU32(0)                  // e_flags
        d.appendU16(64)                 // e_ehsize
        d.appendU16(0)                  // e_phentsize
        d.appendU16(0)                  // e_phnum
        d.appendU16(64)                 // e_shentsize
        d.appendU16(9)                  // e_shnum
        d.appendU16(8)                  // e_shstrndx (.shstrtab)

        d.append(contentsOf: plt)
        d.append(contentsOf: got)
        appendSym(&d, name: 0, info: 0, shndx: 0, value: 0, size: 0)      // null symbol
        appendSym(&d, name: 1, info: 0x12, shndx: 0, value: 0, size: 0)   // puts (GLOBAL|FUNC, undefined)
        d.append(contentsOf: dynstr)

        d.appendU64(0x403018)                         // r_offset: GOT slot VA
        d.appendU64((UInt64(1) << 32) | UInt64(7))     // r_info: sym=1, R_X86_64_JUMP_SLOT
        d.appendU64(0)                                // r_addend

        d.appendU16(0)                                // versym[0]
        d.appendU16(2)                                // versym[1] -> GLIBC_2.2.5

        d.appendU16(1)                                // vn_version
        d.appendU16(1)                                // vn_cnt
        d.appendU32(6)                                // vn_file -> libc.so.6
        d.appendU32(16)                               // vn_aux
        d.appendU32(0)                                // vn_next
        d.appendU32(0)                                // vna_hash
        d.appendU16(0)                                // vna_flags
        d.appendU16(2)                                // vna_other
        d.appendU32(16)                               // vna_name -> GLIBC_2.2.5
        d.appendU32(0)                                // vna_next

        d.append(contentsOf: shstr)

        appendShdr(&d, name: 0, type: 0, flags: 0, addr: 0, off: 0, size: 0, link: 0, info: 0, entsize: 0)                                      // NULL
        appendShdr(&d, name: 1, type: 1, flags: 6, addr: 0x401020, off: UInt64(pltOff), size: UInt64(plt.count), link: 0, info: 0, entsize: 16)     // .plt
        appendShdr(&d, name: 6, type: 1, flags: 3, addr: 0x403000, off: UInt64(gotOff), size: UInt64(got.count), link: 0, info: 0, entsize: 8)       // .got.plt
        appendShdr(&d, name: 15, type: 11, flags: 2, addr: 0x402000, off: UInt64(dynsymOff), size: 48, link: 4, info: 1, entsize: 24)                // .dynsym
        appendShdr(&d, name: 23, type: 3, flags: 2, addr: 0x402100, off: UInt64(dynstrOff), size: UInt64(dynstr.count), link: 0, info: 0, entsize: 0) // .dynstr
        appendShdr(&d, name: 31, type: 4, flags: 2, addr: 0x402200, off: UInt64(relaPltOff), size: 24, link: 3, info: 1, entsize: 24)                 // .rela.plt
        appendShdr(&d, name: 41, type: 0x6fffffff, flags: 2, addr: 0x402300, off: UInt64(versymOff), size: 4, link: 3, info: 0, entsize: 2)           // .gnu.version
        appendShdr(&d, name: 54, type: 0x6ffffffe, flags: 2, addr: 0x402304, off: UInt64(verneedOff), size: 32, link: 4, info: 1, entsize: 0)         // .gnu.version_r
        appendShdr(&d, name: 69, type: 3, flags: 0, addr: 0, off: UInt64(shstrOff), size: UInt64(shstr.count), link: 0, info: 0, entsize: 0)          // .shstrtab
        return d
    }

    /// A minimal ELF64 shared object whose defined dynsym entries are versioned by
    /// `.gnu.version_d`: one exported function and one exported OBJECT symbol.
    private func miniVersionedExportELF() -> Data {
        let text: [UInt8] = [0xC3]
        let data: [UInt8] = [41, 0, 0, 0]
        let dynstr = Array("\u{0}addnums\u{0}exported_data\u{0}libver.so\u{0}VERS_1\u{0}".utf8)
        let shstr = Array("\u{0}.text\u{0}.data\u{0}.dynsym\u{0}.dynstr\u{0}.gnu.version\u{0}.gnu.version_d\u{0}.shstrtab\u{0}".utf8)

        let textOff = 64
        let dataOff = textOff + text.count
        let dynsymOff = dataOff + data.count
        let dynstrOff = dynsymOff + 72               // 3 symbols x 24
        let versymOff = dynstrOff + dynstr.count
        let verdefOff = versymOff + 6                // 3 versym entries x 2
        let shstrOff = verdefOff + 56                // 2 Verdef records, each 20 + 8 bytes
        let shoff = shstrOff + shstr.count

        let addnumsName = stringOffset("addnums", in: dynstr)
        let exportedDataName = stringOffset("exported_data", in: dynstr)
        let libraryName = stringOffset("libver.so", in: dynstr)
        let versionName = stringOffset("VERS_1", in: dynstr)

        var d = Data()
        d.append(contentsOf: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])
        d.append(contentsOf: [UInt8](repeating: 0, count: 8))
        d.appendU16(3)                  // e_type ET_DYN
        d.appendU16(62)                 // e_machine EM_X86_64
        d.appendU32(1)                  // e_version
        d.appendU64(0)                  // e_entry
        d.appendU64(0)                  // e_phoff
        d.appendU64(UInt64(shoff))      // e_shoff
        d.appendU32(0)                  // e_flags
        d.appendU16(64)                 // e_ehsize
        d.appendU16(0)                  // e_phentsize
        d.appendU16(0)                  // e_phnum
        d.appendU16(64)                 // e_shentsize
        d.appendU16(8)                  // e_shnum
        d.appendU16(7)                  // e_shstrndx (.shstrtab)

        d.append(contentsOf: text)
        d.append(contentsOf: data)
        appendSym(&d, name: 0, info: 0, shndx: 0, value: 0, size: 0)
        appendSym(&d, name: addnumsName, info: 0x12, shndx: 1, value: 0x1000, size: UInt64(text.count))
        appendSym(&d, name: exportedDataName, info: 0x11, shndx: 2, value: 0x2000, size: UInt64(data.count))
        d.append(contentsOf: dynstr)

        d.appendU16(0)                                // versym[0]
        d.appendU16(2)                                // versym[1] -> VERS_1
        d.appendU16(0x8002)                           // versym[2] -> VERS_1 with hidden bit set

        d.appendU16(1)                                // vd_version
        d.appendU16(1)                                // vd_flags: VER_FLG_BASE
        d.appendU16(1)                                // vd_ndx: VER_NDX_GLOBAL, reserved
        d.appendU16(1)                                // vd_cnt
        d.appendU32(0)                                // vd_hash
        d.appendU32(20)                               // vd_aux
        d.appendU32(28)                               // vd_next
        d.appendU32(libraryName)                      // vda_name
        d.appendU32(0)                                // vda_next

        d.appendU16(1)                                // vd_version
        d.appendU16(0)                                // vd_flags
        d.appendU16(2)                                // vd_ndx
        d.appendU16(1)                                // vd_cnt
        d.appendU32(0)                                // vd_hash
        d.appendU32(20)                               // vd_aux
        d.appendU32(0)                                // vd_next
        d.appendU32(versionName)                      // vda_name
        d.appendU32(0)                                // vda_next

        d.append(contentsOf: shstr)

        appendShdr(&d, name: 0, type: 0, flags: 0, addr: 0, off: 0, size: 0, link: 0, info: 0, entsize: 0)
        appendShdr(&d, name: stringOffset(".text", in: shstr), type: 1, flags: 6, addr: 0x1000, off: UInt64(textOff), size: UInt64(text.count), link: 0, info: 0, entsize: 0)
        appendShdr(&d, name: stringOffset(".data", in: shstr), type: 1, flags: 3, addr: 0x2000, off: UInt64(dataOff), size: UInt64(data.count), link: 0, info: 0, entsize: 0)
        appendShdr(&d, name: stringOffset(".dynsym", in: shstr), type: 11, flags: 2, addr: 0x3000, off: UInt64(dynsymOff), size: 72, link: 4, info: 1, entsize: 24)
        appendShdr(&d, name: stringOffset(".dynstr", in: shstr), type: 3, flags: 2, addr: 0x3100, off: UInt64(dynstrOff), size: UInt64(dynstr.count), link: 0, info: 0, entsize: 0)
        appendShdr(&d, name: stringOffset(".gnu.version", in: shstr), type: 0x6fffffff, flags: 2, addr: 0x3200, off: UInt64(versymOff), size: 6, link: 3, info: 0, entsize: 2)
        appendShdr(&d, name: stringOffset(".gnu.version_d", in: shstr), type: 0x6ffffffd, flags: 2, addr: 0x3208, off: UInt64(verdefOff), size: 56, link: 4, info: 2, entsize: 0)
        appendShdr(&d, name: stringOffset(".shstrtab", in: shstr), type: 3, flags: 0, addr: 0, off: UInt64(shstrOff), size: UInt64(shstr.count), link: 0, info: 0, entsize: 0)
        return d
    }

    private func stringOffset(_ value: String, in table: [UInt8]) -> UInt32 {
        let needle = Array(value.utf8) + [0]
        precondition(table.count >= needle.count, "string table is too small")
        for index in 0...(table.count - needle.count) where Array(table[index..<(index + needle.count)]) == needle {
            return UInt32(index)
        }
        preconditionFailure("missing \(value) in string table")
    }

    private func appendSym(_ d: inout Data, name: UInt32, info: UInt8, shndx: UInt16, value: UInt64, size: UInt64) {
        d.appendU32(name); d.append(info); d.append(0); d.appendU16(shndx); d.appendU64(value); d.appendU64(size)
    }

    private func appendShdr(_ d: inout Data, name: UInt32, type: UInt32, flags: UInt64, addr: UInt64, off: UInt64, size: UInt64, link: UInt32, info: UInt32, entsize: UInt64) {
        d.appendU32(name); d.appendU32(type); d.appendU64(flags); d.appendU64(addr); d.appendU64(off)
        d.appendU64(size); d.appendU32(link); d.appendU32(info); d.appendU64(8); d.appendU64(entsize)
    }

    private struct ParsedELFSections {
        let reader: LittleEndianReader
        let is64: Bool
        let machine: UInt16
        let sections: [ELFSectionInfo]
    }

    private func parsedELFSections(_ bytes: Data) throws -> ParsedELFSections {
        guard ELFBinaryLoader.isELF(bytes), bytes.count >= 6 else { throw ELFLoadError.truncated("header") }
        let plainReader = LittleEndianReader(bytes)
        let is64: Bool
        switch plainReader.byte(4) {
        case 1: is64 = false
        case 2: is64 = true
        default: throw ELFLoadError.unsupported("unknown ELF class")
        }
        let bigEndian: Bool
        switch plainReader.byte(5) {
        case 1: bigEndian = false
        case 2: bigEndian = true
        default: throw ELFLoadError.unsupported("unknown ELF data encoding")
        }

        let reader = LittleEndianReader(bytes, bigEndian: bigEndian)
        let machine = try reader.u16(18)
        let eShoff: UInt64
        let eShentsize: Int
        let eShnum: Int
        let eShstrndx: Int
        if is64 {
            eShoff = try reader.u64(40)
            eShentsize = Int(try reader.u16(58))
            eShnum = Int(try reader.u16(60))
            eShstrndx = Int(try reader.u16(62))
        } else {
            eShoff = UInt64(try reader.u32(32))
            eShentsize = Int(try reader.u16(46))
            eShnum = Int(try reader.u16(48))
            eShstrndx = Int(try reader.u16(50))
        }
        guard eShnum > 0,
              eShstrndx < eShnum,
              let sectionTable = reader.range(eShoff, UInt64(eShnum) * UInt64(eShentsize)) else {
            throw ELFLoadError.truncated("section table")
        }

        struct RawSection {
            let nameOffset: UInt32
            let type: UInt32
            let flags: UInt64
            let address: UInt64
            let fileOffset: UInt64
            let size: UInt64
            let link: UInt32
            let info: UInt32
            let entrySize: UInt64
        }

        var rawSections: [RawSection] = []
        rawSections.reserveCapacity(eShnum)
        for index in 0..<eShnum {
            let base = sectionTable.lowerBound + index * eShentsize
            if is64 {
                rawSections.append(RawSection(
                    nameOffset: try reader.u32(base + 0),
                    type: try reader.u32(base + 4),
                    flags: try reader.u64(base + 8),
                    address: try reader.u64(base + 16),
                    fileOffset: try reader.u64(base + 24),
                    size: try reader.u64(base + 32),
                    link: try reader.u32(base + 40),
                    info: try reader.u32(base + 44),
                    entrySize: try reader.u64(base + 56)
                ))
            } else {
                rawSections.append(RawSection(
                    nameOffset: try reader.u32(base + 0),
                    type: try reader.u32(base + 4),
                    flags: UInt64(try reader.u32(base + 8)),
                    address: UInt64(try reader.u32(base + 12)),
                    fileOffset: UInt64(try reader.u32(base + 16)),
                    size: UInt64(try reader.u32(base + 20)),
                    link: try reader.u32(base + 24),
                    info: try reader.u32(base + 28),
                    entrySize: UInt64(try reader.u32(base + 36))
                ))
            }
        }

        let shstr = rawSections[eShstrndx]
        let shstrRange = reader.range(shstr.fileOffset, shstr.size)
        let sections = rawSections.enumerated().map { index, section in
            let name: String
            if let shstrRange,
               let relativeOffset = Int(exactly: section.nameOffset),
               relativeOffset >= 0,
               relativeOffset < shstrRange.count {
                name = reader.cString(fileOffset: shstrRange.lowerBound + relativeOffset, limit: shstrRange.upperBound)
            } else {
                name = ""
            }
            return ELFSectionInfo(
                index: index,
                name: name,
                type: section.type,
                flags: section.flags,
                address: section.address,
                fileOffset: section.fileOffset,
                size: section.size,
                link: section.link,
                info: section.info,
                entrySize: section.entrySize
            )
        }
        return ParsedELFSections(reader: reader, is64: is64, machine: machine, sections: sections)
    }

    // MARK: - Tests

    func testELFLoaderProjectsExecutableToNeutralModel() throws {
        let loaded = try ELFBinaryLoader.parse(bytes: miniExecutableELF(), name: "prog.elf", path: "/tmp/prog.elf")
        XCTAssertEqual(loaded.cpuType, MachOConstants.cpuTypeX86_64)
        XCTAssertEqual(loaded.architectureDisplayName, "x86_64")
        XCTAssertEqual(loaded.fileTypeName, "ELF executable")
        XCTAssertEqual(loaded.entryPointAddress, 0x1000)
        XCTAssertEqual(loaded.executableTextSection?.name, ".text")
        XCTAssertEqual(loaded.executableTextSection?.address, 0x1000)
        XCTAssertEqual(loaded.executableTextSection?.size, 14)
        XCTAssertEqual(loaded.functionStarts.sorted(), [0x1000, 0x1006])
        XCTAssertEqual(loaded.symbols.first(where: { $0.name == "compute" })?.address, 0x1000)
        XCTAssertTrue(loaded.symbols.contains { $0.name == "tag" })
        XCTAssertTrue(loaded.exports.isEmpty)
        XCTAssertTrue(loaded.stringLiterals.contains { $0.value == "elf-prog" && $0.address == 0x2000 })
    }

    func testELFLoaderRejectsMalformedOffsetsWithoutCrashing() {
        // e_shoff > Int.max must throw, not trap on a UInt64→Int conversion.
        var bad = miniExecutableELF()
        bad.replaceSubrange(40..<48, with: [0, 0, 0, 0, 0, 0, 0, 0x80]) // e_shoff = 0x8000000000000000
        XCTAssertThrowsError(try ELFBinaryLoader.parse(bytes: bad, name: "bad", path: "bad"))

        // A .symtab whose sh_offset is huge must degrade (no symbols), not crash.
        var badSym = miniExecutableELF()
        let symtabShdrOffset = 213 + 4 * 64            // section table @213, .symtab is index 4
        badSym.replaceSubrange((symtabShdrOffset + 24)..<(symtabShdrOffset + 32),
                               with: [0, 0, 0, 0, 0, 0, 0, 0x80]) // sh_offset = 0x8000000000000000
        let loaded = try? ELFBinaryLoader.parse(bytes: badSym, name: "x", path: "x")
        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded?.symbols.isEmpty ?? false)
    }

    func testELFMagicDetection() {
        XCTAssertTrue(ELFBinaryLoader.isELF(miniExecutableELF()))
        XCTAssertFalse(ELFBinaryLoader.isELF(Data([0xCF, 0xFA, 0xED, 0xFE]))) // Mach-O 64
        XCTAssertThrowsError(try ELFBinaryLoader.parse(bytes: Data([0x00, 0x01, 0x02, 0x03]), name: "x", path: "x"))
    }

    func testELFDynamicLinkingParsesRelocationsVersionsAndPLTProjection() throws {
        let bytes = miniDynamicELF()
        let parsed = try parsedELFSections(bytes)

        let relocations = parseRelocations(reader: parsed.reader, sections: parsed.sections, is64: parsed.is64)
        XCTAssertEqual(relocations.count, 1)
        let relocation = try XCTUnwrap(relocations.first)
        XCTAssertEqual(relocation.sectionName, ".rela.plt")
        XCTAssertEqual(relocation.offset, 0x403018)
        XCTAssertEqual(relocation.symIndex, 1)
        XCTAssertEqual(relocation.type, 7)
        XCTAssertEqual(relocation.addend, 0)
        XCTAssertTrue(relocation.isRela)

        let dynamicSymbols = parseDynamicSymbols(reader: parsed.reader, sections: parsed.sections, is64: parsed.is64)
        XCTAssertEqual(dynamicSymbols.count, 2)
        XCTAssertEqual(dynamicSymbols[1].name, "puts")
        let versionInfo = parseVersionInfo(
            reader: parsed.reader,
            sections: parsed.sections,
            dynSymbols: dynamicSymbols,
            is64: parsed.is64
        )
        XCTAssertEqual(versionInfo.versionIndexNames[2], "GLIBC_2.2.5")
        XCTAssertEqual(versionInfo.versionIndexLibraries[2], "libc.so.6")
        XCTAssertEqual(versionInfo.symbolVersionNames[1], "GLIBC_2.2.5")
        XCTAssertEqual(versionInfo.decoratedName("puts", symbolIndex: 1), "puts@GLIBC_2.2.5")

        let stubs = resolvePLTStubs(
            reader: parsed.reader,
            sections: parsed.sections,
            dynSymbols: dynamicSymbols,
            versionInfo: versionInfo,
            is64: parsed.is64,
            machine: parsed.machine
        )
        XCTAssertEqual(stubs.count, 1)
        let stub = try XCTUnwrap(stubs.first)
        XCTAssertEqual(stub.stubVA, 0x401030)
        XCTAssertEqual(stub.gotSlotVA, 0x403018)
        XCTAssertEqual(stub.symbolIndex, 1)
        XCTAssertEqual(stub.importName, "puts@GLIBC_2.2.5")
        XCTAssertEqual(stub.libraryName, "libc.so.6")

        let loaded = try ELFBinaryLoader.parse(bytes: bytes, name: "dyn.elf", path: "/tmp/dyn.elf")
        XCTAssertEqual(loaded.fileTypeName, "ELF shared object")
        XCTAssertEqual(loaded.imports.map(\.name), ["puts@GLIBC_2.2.5"])
        XCTAssertEqual(loaded.imports.first?.libraryName, "libc.so.6")
        XCTAssertTrue(loaded.symbols.contains { $0.name == "puts@GLIBC_2.2.5" && $0.kind == "undefined" })
        XCTAssertEqual(loaded.indirectSymbols.count, 1)
        let indirect = try XCTUnwrap(loaded.indirectSymbols.first)
        XCTAssertEqual(indirect.kind, "plt")
        XCTAssertEqual(indirect.sourceSection, ".plt")
        XCTAssertEqual(indirect.address, 0x403018)
        XCTAssertEqual(indirect.entrySize, 8)
        XCTAssertEqual(indirect.tableIndex, 0)
        XCTAssertEqual(indirect.rawSymbolIndex, 1)
        XCTAssertEqual(indirect.symbolIndex, 1)
        XCTAssertEqual(indirect.symbolName, "puts@GLIBC_2.2.5")
        XCTAssertNil(indirect.libraryOrdinal)
        XCTAssertEqual(indirect.libraryName, "libc.so.6")
        XCTAssertFalse(indirect.isLocal)
        XCTAssertFalse(indirect.isAbsolute)
    }

    func testELFVersionDefinitionsDecorateDefinedDynamicExports() throws {
        let bytes = miniVersionedExportELF()
        let parsed = try parsedELFSections(bytes)
        let dynamicSymbols = parseDynamicSymbols(reader: parsed.reader, sections: parsed.sections, is64: parsed.is64)
        XCTAssertEqual(dynamicSymbols.count, 3)
        XCTAssertEqual(dynamicSymbols[1].name, "addnums")
        XCTAssertEqual(dynamicSymbols[2].name, "exported_data")

        let versionInfo = parseVersionInfo(
            reader: parsed.reader,
            sections: parsed.sections,
            dynSymbols: dynamicSymbols,
            is64: parsed.is64
        )
        XCTAssertEqual(versionInfo.versionIndexNames[2], "VERS_1")
        XCTAssertEqual(versionInfo.symbolVersionNames[1], "VERS_1")
        XCTAssertEqual(versionInfo.symbolVersionNames[2], "VERS_1")
        XCTAssertEqual(versionInfo.decoratedName("addnums", symbolIndex: 1), "addnums@VERS_1")
        XCTAssertEqual(versionInfo.decoratedName("exported_data", symbolIndex: 2), "exported_data@VERS_1")
        XCTAssertNil(versionInfo.libraryName(forSymbolIndex: 1))

        let loaded = try ELFBinaryLoader.parse(bytes: bytes, name: "libver.so", path: "/tmp/libver.so")
        XCTAssertTrue(loaded.symbols.contains { $0.name == "addnums@VERS_1" && $0.kind == "export" })
        XCTAssertTrue(loaded.symbols.contains { $0.name == "exported_data@VERS_1" && $0.kind == "export" })
        XCTAssertEqual(
            Set(loaded.exports.map { "\($0.name)|\($0.address ?? 0)" }),
            ["addnums@VERS_1|4096", "exported_data@VERS_1|8192"]
        )
    }

    func testParseRelocationsOnRealClangObject() throws {
        let clang = "/usr/bin/clang"
        guard FileManager.default.isExecutableFile(atPath: clang) else {
            throw XCTSkip("clang not available")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeELFObject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("f.c")
        let object = root.appendingPathComponent("f.o")
        try "extern int ext(int);\nint f(int x) { return ext(x) + 1; }\n"
            .write(to: source, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: clang)
        process.arguments = ["-target", "x86_64-linux-gnu", "-c", source.path, "-o", object.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let drain: CoreTestPipeDrain
        do {
            try process.run()
            drain = CoreTestPipeDrain(output)
            process.waitUntilExit()
        } catch {
            throw XCTSkip("clang could not be launched: \(error)")
        }

        let outputData = drain.data()
        let outputText = String(decoding: outputData, as: UTF8.self)
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: object.path) else {
            throw XCTSkip("clang did not produce an ELF fixture on this host: \(outputText)")
        }

        let bytes = try Data(contentsOf: object)
        guard ELFBinaryLoader.isELF(bytes) else {
            throw XCTSkip("clang target did not produce an ELF object on this host")
        }
        let loaded = try ELFBinaryLoader.parse(bytes: bytes, name: object.lastPathComponent, path: object.path)
        XCTAssertEqual(loaded.fileTypeName, "ELF relocatable")

        let parsed = try parsedELFSections(bytes)
        let relocations = parseRelocations(reader: parsed.reader, sections: parsed.sections, is64: parsed.is64)
        XCTAssertTrue(relocations.contains {
            $0.sectionName == ".rela.text" && $0.type == 4 && $0.symIndex > 0 && $0.addend == -4
        })
    }

    // MARK: - ELF32-LSB fixture

    /// A hand-built minimal ELF32 LSB (i386) executable, section-only. Mirrors the
    /// ELF64 fixture but with 52-byte header, 40-byte Elf32_Shdr, and 16-byte Elf32_Sym
    /// (st_value is a u32 at offset 4, st_info a u8 at offset 12, st_shndx a u16 @14).
    ///
    ///   .text  @0x8048000: two stub functions
    ///   .rodata@0x8049000: "elf32-le\0"
    private func miniELF32(bigEndian: Bool = false) -> Data {
        let order: ByteOrderHelper = bigEndian ? .big : .little
        let text: [UInt8] = [0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3,
                             0x8D, 0x05, 0x00, 0x00, 0x00, 0x00]
        let rodata = Array((bigEndian ? "elf32-be\u{0}" : "elf32-le\u{0}").utf8)             // 9
        let shstr = Array("\u{0}.text\u{0}.rodata\u{0}.shstrtab\u{0}.symtab\u{0}.strtab\u{0}".utf8) // 41
        let strtab = Array("\u{0}alpha\u{0}beta\u{0}".utf8)                                  // 12

        let textOff = 52
        let rodataOff = textOff + text.count          // 64
        let shstrOff = rodataOff + rodata.count        // 73
        let symtabOff = shstrOff + shstr.count          // 114
        let strtabOff = symtabOff + 48                  // 162 (3 symbols × 16)
        let shoff = strtabOff + strtab.count            // 174

        var d = Data()
        // ELF32 header (52 bytes)
        d.append(contentsOf: [0x7F, 0x45, 0x4C, 0x46, 1, bigEndian ? 2 : 1, 1, 0]) // ELFCLASS32, data, version, SYSV
        d.append(contentsOf: [UInt8](repeating: 0, count: 8))      // e_ident padding
        d.appendU16(2, order)                  // e_type ET_EXEC
        d.appendU16(bigEndian ? 20 : 3, order) // e_machine: EM_PPC (be) / EM_386 (le)
        d.appendU32(1, order)                  // e_version
        d.appendU32(0x8048000, order)          // e_entry
        d.appendU32(0, order)                  // e_phoff (none)
        d.appendU32(UInt32(shoff), order)      // e_shoff
        d.appendU32(0, order)                  // e_flags
        d.appendU16(52, order)                 // e_ehsize
        d.appendU16(0, order)                  // e_phentsize
        d.appendU16(0, order)                  // e_phnum
        d.appendU16(40, order)                 // e_shentsize
        d.appendU16(6, order)                  // e_shnum
        d.appendU16(3, order)                  // e_shstrndx (.shstrtab)

        // Section contents
        d.append(contentsOf: text)
        d.append(contentsOf: rodata)
        d.append(contentsOf: shstr)
        appendSym32(&d, order, name: 0, value: 0, size: 0, info: 0, shndx: 0)               // null symbol
        appendSym32(&d, order, name: 1, value: 0x8048000, size: 6, info: 0x12, shndx: 1)    // alpha (GLOBAL|FUNC)
        appendSym32(&d, order, name: 7, value: 0x8048006, size: 6, info: 0x12, shndx: 1)    // beta
        d.append(contentsOf: strtab)

        // Section header table (6 × 40)
        appendShdr32(&d, order, name: 0, type: 0, flags: 0, addr: 0, off: 0, size: 0, link: 0, entsize: 0)                                       // NULL
        appendShdr32(&d, order, name: 1, type: 1, flags: 6, addr: 0x8048000, off: UInt32(textOff), size: UInt32(text.count), link: 0, entsize: 0)    // .text
        appendShdr32(&d, order, name: 7, type: 1, flags: 2, addr: 0x8049000, off: UInt32(rodataOff), size: UInt32(rodata.count), link: 0, entsize: 0) // .rodata
        appendShdr32(&d, order, name: 15, type: 3, flags: 0, addr: 0, off: UInt32(shstrOff), size: UInt32(shstr.count), link: 0, entsize: 0)          // .shstrtab
        appendShdr32(&d, order, name: 25, type: 2, flags: 0, addr: 0, off: UInt32(symtabOff), size: 48, link: 5, entsize: 16)                         // .symtab (link → .strtab)
        appendShdr32(&d, order, name: 33, type: 3, flags: 0, addr: 0, off: UInt32(strtabOff), size: UInt32(strtab.count), link: 0, entsize: 0)        // .strtab
        return d
    }

    private func appendSym32(_ d: inout Data, _ order: ByteOrderHelper, name: UInt32, value: UInt32, size: UInt32, info: UInt8, shndx: UInt16) {
        d.appendU32(name, order); d.appendU32(value, order); d.appendU32(size, order)
        d.append(info); d.append(0); d.appendU16(shndx, order)
    }

    private func appendShdr32(_ d: inout Data, _ order: ByteOrderHelper, name: UInt32, type: UInt32, flags: UInt32, addr: UInt32, off: UInt32, size: UInt32, link: UInt32, entsize: UInt32) {
        d.appendU32(name, order); d.appendU32(type, order); d.appendU32(flags, order)
        d.appendU32(addr, order); d.appendU32(off, order); d.appendU32(size, order)
        d.appendU32(link, order); d.appendU32(0, order); d.appendU32(8, order); d.appendU32(entsize, order)
    }

    func testELF32LSBLoadsSectionsAndSymbols() throws {
        let loaded = try ELFBinaryLoader.parse(bytes: miniELF32(), name: "p32.elf", path: "/tmp/p32.elf")
        XCTAssertEqual(loaded.architectureDisplayName, "i386")
        XCTAssertEqual(loaded.fileTypeName, "ELF executable")
        XCTAssertEqual(loaded.entryPointAddress, 0x8048000)
        XCTAssertEqual(loaded.executableTextSection?.name, ".text")
        XCTAssertEqual(loaded.executableTextSection?.address, 0x8048000)
        XCTAssertEqual(loaded.functionStarts.sorted(), [0x8048000, 0x8048006])
        XCTAssertEqual(loaded.symbols.first(where: { $0.name == "alpha" })?.address, 0x8048000)
        XCTAssertTrue(loaded.symbols.contains { $0.name == "beta" })
        XCTAssertTrue(loaded.stringLiterals.contains { $0.value == "elf32-le" && $0.address == 0x8049000 })
    }

    func testELF32MSBBigEndianLoadsSectionsAndSymbols() throws {
        // Big-endian (ELFDATA2MSB) 32-bit image: every multi-byte field is stored MSB
        // first. The loader must read header/section/symbol fields per EI_DATA and
        // recover the same neutral model.
        let loaded = try ELFBinaryLoader.parse(bytes: miniELF32(bigEndian: true), name: "ppc.elf", path: "/tmp/ppc.elf")
        XCTAssertEqual(loaded.architectureDisplayName, "ppc")
        XCTAssertEqual(loaded.fileTypeName, "ELF executable")
        XCTAssertEqual(loaded.entryPointAddress, 0x8048000)
        XCTAssertEqual(loaded.executableTextSection?.name, ".text")
        XCTAssertEqual(loaded.executableTextSection?.address, 0x8048000)
        XCTAssertEqual(loaded.executableTextSection?.size, 12)
        XCTAssertEqual(loaded.functionStarts.sorted(), [0x8048000, 0x8048006])
        XCTAssertEqual(loaded.symbols.first(where: { $0.name == "alpha" })?.address, 0x8048000)
        XCTAssertTrue(loaded.symbols.contains { $0.name == "beta" })
        XCTAssertTrue(loaded.stringLiterals.contains { $0.value == "elf32-be" && $0.address == 0x8049000 })
    }

    func testELF32RejectsMalformedSectionOffsetWithoutCrashing() {
        // A truncated/huge e_shoff (u32) must throw, not trap.
        var bad = miniELF32()
        bad.replaceSubrange(32..<36, with: [0xFF, 0xFF, 0xFF, 0xFF]) // e_shoff = 0xFFFFFFFF (LE)
        XCTAssertThrowsError(try ELFBinaryLoader.parse(bytes: bad, name: "bad", path: "bad"))

        // A truncated header (< 52 bytes for ELF32) must throw, not trap.
        let short = miniELF32().prefix(40)
        XCTAssertThrowsError(try ELFBinaryLoader.parse(bytes: Data(short), name: "short", path: "short"))
    }

    func testELFRejectsUnknownClassAndData() {
        var badClass = miniELF32()
        badClass[4] = 7 // EI_CLASS = bogus
        XCTAssertThrowsError(try ELFBinaryLoader.parse(bytes: badClass, name: "x", path: "x"))

        var badData = miniELF32()
        badData[5] = 9 // EI_DATA = bogus
        XCTAssertThrowsError(try ELFBinaryLoader.parse(bytes: badData, name: "x", path: "x"))
    }

    @MainActor
    func testAnalysisEngineLoadsAndDisassemblesELFExecutableEndToEnd() async throws {
        // The router sniffs the ELF magic and routes to the ELF loader; the engine
        // then decodes .text via the x86_64 decoder (selected by e_machine) and
        // recovers functions from the ELF symbol table — no Mach-O involved.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacScopeELF-\(UUID().uuidString)")
        try miniExecutableELF().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try await AnalysisEngine().openBinary(url: url)

        XCTAssertEqual(snapshot.binaries.first?.architecture, "x86_64")
        XCTAssertEqual(snapshot.binaries.first?.kind, "ELF executable")
        XCTAssertEqual(Set(snapshot.functions.map(\.name)), ["compute", "tag"])
        XCTAssertEqual(snapshot.functions.first(where: { $0.name == "compute" })?.startAddress, 0x1000)
        XCTAssertEqual(snapshot.instructions.first?.address, 0x1000)
        XCTAssertEqual(snapshot.instructions.first?.mnemonic, "mov") // mov eax, 0x7
        XCTAssertEqual(snapshot.instructions.map(\.mnemonic), ["mov", "ret", "lea", "ret"])
        XCTAssertTrue(snapshot.stringLiterals.contains { $0.value == "elf-prog" })
    }

    /// WS-5 edge oracle: restore-time rehydration is format-neutral. An ELF attachment regains its
    /// loader sections while every Mach-O/Objective-C/Swift-only product naturally stays empty.
    @MainActor
    func testDatabaseReopenRehydratesELFSectionsWithoutMachOMetadata() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeELFRehydrate-\(UUID().uuidString)")
        try miniExecutableELF().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = AnalysisEngine()
        let fresh = try engine.analyze(url: url)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let workspace = try database.saveSnapshot(workspaceName: "ELF rehydrate", snapshot: fresh)
        let reopened = try XCTUnwrap(database.loadSnapshot(
            workspaceID: try XCTUnwrap(workspace.id)
        ))
        XCTAssertTrue(reopened.sections.isEmpty)
        let store = WorkspaceStore(
            workspaceName: "ELF rehydrate", snapshot: reopened,
            engine: engine, autosaveScheduler: nil
        )

        await store.rehydrateLoadedImagesSynchronouslyForTesting()

        let result = try XCTUnwrap(store.snapshot.analysis(in: store.snapshot.primarySlot))
        XCTAssertFalse(result.sections.isEmpty)
        XCTAssertNil(result.machOMetadata)
        XCTAssertTrue(result.objcSelectors.isEmpty)
        XCTAssertTrue(result.objcClasses.isEmpty)
        XCTAssertTrue(result.objcCategories.isEmpty)
        XCTAssertTrue(result.swiftTypes.isEmpty)
        XCTAssertTrue(result.swiftConformances.isEmpty)
        XCTAssertEqual(result.functions, reopened.functions)
        XCTAssertFalse(store.isDirty)
    }
}

enum ByteOrderHelper { case little, big }

private extension Data {
    mutating func appendU16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendU32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * i)) & 0xFF)) } }
    mutating func appendU64(_ v: UInt64) { for i in 0..<8 { append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }

    mutating func appendU16(_ v: UInt16, _ order: ByteOrderHelper) {
        let le: [UInt8] = [UInt8(v & 0xFF), UInt8(v >> 8)]
        append(contentsOf: order == .big ? le.reversed() : le)
    }
    mutating func appendU32(_ v: UInt32, _ order: ByteOrderHelper) {
        let le: [UInt8] = (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }
        append(contentsOf: order == .big ? le.reversed() : le)
    }
}
