import Foundation

enum ELFLoadError: LocalizedError {
    case notELF
    case unsupported(String)
    case truncated(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notELF: "The file is not an ELF binary."
        case .unsupported(let detail): "Unsupported ELF: \(detail)."
        case .truncated(let context): "The ELF file is truncated or malformed (\(context))."
        case .malformed(let detail): "The ELF file is malformed (\(detail))."
        }
    }
}

/// An ELF loader — the second `BinaryLoader`, projecting an ELF image down to the same
/// neutral `LoadedBinary` the Mach-O loader produces, so the analysis pipeline
/// decodes/analyzes ELF identically to Mach-O.
///
/// Scope: ELF32 + ELF64, in either byte order (ELFDATA2LSB / ELFDATA2MSB). The
/// header, section table, symbol table, and string tables are all parsed per the
/// `EI_CLASS` (32/64-bit field widths and struct layouts) and `EI_DATA` (endianness)
/// markers in `e_ident`. It parses the header, section table, `.symtab`/`.dynsym`
/// (+ linked string tables), ELF dynamic relocations/PLT imports, and `.rodata*`
/// C-strings, then maps `e_machine` to a CPU type the decoder selector understands.
/// A section table remains primary. Sectionless ET_EXEC/ET_DYN images fall back to a
/// bounded PT_LOAD projection which deliberately does not invent section-only facts.
struct ELFBinaryLoader: BinaryLoader {
    func load(at url: URL) throws -> LoadedBinary {
        guard let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw ELFLoadError.truncated("file unreadable")
        }
        return try Self.parse(bytes: bytes, name: url.lastPathComponent, path: url.path)
    }

    static func isELF(_ bytes: Data) -> Bool {
        bytes.count >= 4 && bytes[bytes.startIndex] == 0x7F
            && bytes[bytes.startIndex + 1] == 0x45  // E
            && bytes[bytes.startIndex + 2] == 0x4C  // L
            && bytes[bytes.startIndex + 3] == 0x46  // F
    }

    // ELF constants
    private static let shtProgBits: UInt32 = 1
    private static let shtSymTab: UInt32 = 2
    private static let shtNoBits: UInt32 = 8
    private static let shtDynSym: UInt32 = 11
    private static let shfExecInstr: UInt64 = 4
    private static let sttObject: UInt8 = 1
    private static let sttFunc: UInt8 = 2
    private static let shnUndef: UInt16 = 0
    private static let shnAbs: UInt16 = 0xFFF1
    private static let emX86_64: UInt16 = 62
    private static let emAArch64: UInt16 = 183
    private static let em386: UInt16 = 3
    private static let emARM: UInt16 = 40
    private static let emPPC: UInt16 = 20
    private static let emPPC64: UInt16 = 21
    private static let emMIPS: UInt16 = 8
    private static let emSPARC: UInt16 = 2

    private struct SectionHeader {
        var nameOffset: UInt32
        var type: UInt32
        var flags: UInt64
        var address: UInt64
        var fileOffset: UInt64
        var size: UInt64
        var link: UInt32
        var info: UInt32
        var entrySize: UInt64
    }

    static func parse(bytes: Data, name: String, path: String) throws -> LoadedBinary {
        guard isELF(bytes) else { throw ELFLoadError.notELF }
        // e_ident is byte-order-independent: EI_CLASS@4 (1=32-bit, 2=64-bit),
        // EI_DATA@5 (1=LSB, 2=MSB). Decode them before picking the reader's byte order.
        guard bytes.count >= 6 else { throw ELFLoadError.truncated("header") }
        let plainReader = LittleEndianReader(bytes)
        let eiClass = plainReader.byte(4)
        let eiData = plainReader.byte(5)
        let is64Bit: Bool
        switch eiClass {
        case 1: is64Bit = false
        case 2: is64Bit = true
        default: throw ELFLoadError.unsupported("unknown ELF class \(eiClass.map(String.init) ?? "?")")
        }
        let bigEndian: Bool
        switch eiData {
        case 1: bigEndian = false
        case 2: bigEndian = true
        default: throw ELFLoadError.unsupported("unknown ELF data encoding \(eiData.map(String.init) ?? "?")")
        }

        let reader = LittleEndianReader(bytes, bigEndian: bigEndian)
        // Field widths/offsets after e_version diverge between the two classes.
        let headerSize = is64Bit ? 64 : 52
        guard bytes.count >= headerSize else { throw ELFLoadError.truncated("header") }

        let eType = try reader.u16(16)
        let eMachine = try reader.u16(18)
        let eEntry: UInt64
        let eShoff: UInt64
        let eShentsize: Int
        let eShnum: Int
        let eShstrndx: Int
        let minShentsize: Int
        if is64Bit {
            eEntry = try reader.u64(24)
            eShoff = try reader.u64(40)
            eShentsize = Int(try reader.u16(58))
            eShnum = Int(try reader.u16(60))
            eShstrndx = Int(try reader.u16(62))
            minShentsize = 64
        } else {
            eEntry = UInt64(try reader.u32(24))
            eShoff = UInt64(try reader.u32(32))
            eShentsize = Int(try reader.u16(46))
            eShnum = Int(try reader.u16(48))
            eShstrndx = Int(try reader.u16(50))
            minShentsize = 40
        }

        // Section tables remain authoritative whenever declared. Program-header parsing is
        // best-effort enrichment on that path, so a malformed optional table cannot regress a
        // previously valid sectioned ELF. For a truly sectionless image it is the mandatory,
        // fail-closed loading authority.
        let programHeaders: ELFProgramHeaderCatalog?
        if eShoff == 0 && eShnum == 0 {
            do {
                let catalog = try ELFProgramHeaderParser.parse(bytes)
                return try ELFProgramHeaderBinaryProjection.makeLoadedBinary(
                    catalog: catalog, bytes: bytes, name: name, path: path
                )
            } catch let error as ELFProgramHeaderError {
                throw mapProgramHeaderError(error)
            }
        } else {
            programHeaders = try? ELFProgramHeaderParser.parse(bytes)
        }

        guard eShnum > 0, eShentsize >= minShentsize, eShstrndx < eShnum else {
            throw ELFLoadError.unsupported("a section table is required this increment")
        }
        // Validate the whole section table lies within the file, with no UInt64→Int
        // overflow (a crafted offset/count must throw, never trap).
        guard let sectionTable = reader.range(eShoff, UInt64(eShnum) * UInt64(eShentsize)) else {
            throw ELFLoadError.truncated("section table")
        }

        var headers: [SectionHeader] = []
        headers.reserveCapacity(eShnum)
        for index in 0..<eShnum {
            let base = sectionTable.lowerBound + index * eShentsize
            if is64Bit {
                headers.append(SectionHeader(
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
                // Elf32_Shdr: all word-sized fields are 4 bytes.
                headers.append(SectionHeader(
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

        // Section names come from the section-header string table (validated range so
        // a bogus shstrtab offset/size yields empty names rather than a crash).
        let shstrRange = reader.range(headers[eShstrndx].fileOffset, headers[eShstrndx].size)
        func sectionName(_ header: SectionHeader) -> String {
            guard let shstrRange else { return "" }
            return reader.cString(fileOffset: shstrRange.lowerBound + Int(header.nameOffset),
                                  limit: shstrRange.upperBound)
        }

        let sections = headers.map { header in
            BinarySection(
                name: sectionName(header),
                address: header.address,
                size: header.size,
                fileOffset: header.fileOffset,
                isExecutable: header.type != Self.shtNoBits && header.flags & Self.shfExecInstr != 0,
                isZeroFill: header.type == Self.shtNoBits,   // SHT_NOBITS (.bss): no file content
                fileSize: header.type == Self.shtNoBits ? 0 : header.size
            )
        }
        let executableText = sections.first(where: { $0.name == ".text" })
            ?? sections.first(where: { $0.isExecutable && $0.size > 0 })
        let elfSections = headers.enumerated().map { index, header in
            ELFSectionInfo(
                index: index,
                name: sectionName(header),
                type: header.type,
                flags: header.flags,
                address: header.address,
                fileOffset: header.fileOffset,
                size: header.size,
                link: header.link,
                info: header.info,
                entrySize: header.entrySize
            )
        }

        // Symbols (.symtab preferred, else .dynsym) and their linked string table.
        var symbols: [SymbolSummary] = []
        var imports: [ImportSummary] = []
        var exports: [ExportSummary] = []
        var functionStarts: [UInt64] = []
        let minSymEntry: UInt64 = is64Bit ? 24 : 16
        if let symtabIndex = headers.firstIndex(where: { $0.type == Self.shtSymTab })
            ?? headers.firstIndex(where: { $0.type == Self.shtDynSym }),
           headers[symtabIndex].entrySize >= minSymEntry,
           headers[symtabIndex].entrySize <= headers[symtabIndex].size, // bounds Int(entrySize)
           Int(headers[symtabIndex].link) < headers.count,
           let symRange = reader.range(headers[symtabIndex].fileOffset, headers[symtabIndex].size) {
            let symtab = headers[symtabIndex]
            let strtabRange = reader.range(headers[Int(symtab.link)].fileOffset, headers[Int(symtab.link)].size)
            let entrySize = Int(symtab.entrySize)
            let count = symRange.count / entrySize
            for symbolIndex in 0..<count {
                let base = symRange.lowerBound + symbolIndex * entrySize
                // Elf64_Sym: name u32@0, info u8@4, other u8@5, shndx u16@6, value u64@8.
                // Elf32_Sym: name u32@0, value u32@4, size u32@8, info u8@12, shndx u16@14.
                let stName: UInt32
                let stShndx: UInt16
                let stValue: UInt64
                let stInfo: UInt8
                if is64Bit {
                    guard let n = try? reader.u32(base + 0),
                          let sh = try? reader.u16(base + 6),
                          let v = try? reader.u64(base + 8) else { continue }
                    stName = n; stShndx = sh; stValue = v
                    stInfo = reader.byte(base + 4) ?? 0
                } else {
                    guard let n = try? reader.u32(base + 0),
                          let v = try? reader.u32(base + 4),
                          let sh = try? reader.u16(base + 14) else { continue }
                    stName = n; stShndx = sh; stValue = UInt64(v)
                    stInfo = reader.byte(base + 12) ?? 0
                }
                let name: String = strtabRange.map {
                    reader.cString(fileOffset: $0.lowerBound + Int(stName), limit: $0.upperBound)
                } ?? ""
                guard !name.isEmpty else { continue }

                let type = stInfo & 0x0F
                let bind = stInfo >> 4
                // STT_SECTION (3) and STT_FILE (4) are not analysis-relevant names
                // (section labels, the source filename) — skip them so they don't
                // shadow real symbols when naming addresses.
                if type == 3 || type == 4 { continue }
                let isUndefined = stShndx == Self.shnUndef
                let kind: String = isUndefined ? "undefined"
                    : (stShndx == Self.shnAbs ? "absolute" : (bind == 0 ? "local" : "export"))
                symbols.append(SymbolSummary(
                    id: UUID(), name: name, address: isUndefined ? nil : stValue, kind: kind,
                    libraryName: nil, rawLinkageName: name
                ))
                if isUndefined {
                    imports.append(ImportSummary(id: UUID(), name: name, libraryName: nil, libraryOrdinal: nil))
                } else if type == Self.sttFunc {
                    functionStarts.append(stValue)
                }
            }
        }

        let dynamicSymbols = parseDynamicSymbols(reader: reader, sections: elfSections, is64: is64Bit)
        let versionInfo = parseVersionInfo(
            reader: reader,
            sections: elfSections,
            dynSymbols: dynamicSymbols,
            is64: is64Bit
        )
        // A full symbol table remains the naming authority, but it need not
        // contain every runtime import declared by the dynamic symbol table.
        // Merge undefined dynamic names before applying the existing versions.
        var importedNames = Set(imports.map(\.name))
        for dynSymbol in dynamicSymbols where dynSymbol.sectionIndex == Self.shnUndef {
            let type = dynSymbol.info & 0x0F
            guard !dynSymbol.name.isEmpty, type != 3, type != 4,
                  importedNames.insert(dynSymbol.name).inserted else { continue }
            imports.append(ImportSummary(
                id: UUID(), name: dynSymbol.name, libraryName: nil, libraryOrdinal: nil
            ))
        }
        var versionedDynamicNames: [String: (name: String, libraryName: String?)] = [:]
        for dynSymbol in dynamicSymbols where !dynSymbol.name.isEmpty {
            let decoratedName = versionInfo.decoratedName(dynSymbol.name, symbolIndex: dynSymbol.index)
            guard decoratedName != dynSymbol.name else { continue }
            versionedDynamicNames[dynSymbol.name] = (
                decoratedName,
                versionInfo.libraryName(forSymbolIndex: dynSymbol.index)
            )
        }
        if !versionedDynamicNames.isEmpty {
            for index in symbols.indices {
                guard let decorated = versionedDynamicNames[symbols[index].name] else { continue }
                symbols[index].name = decorated.name
                if symbols[index].libraryName == nil {
                    symbols[index].libraryName = decorated.libraryName
                }
            }
            for index in imports.indices {
                guard let decorated = versionedDynamicNames[imports[index].name] else { continue }
                imports[index].name = decorated.name
                if imports[index].libraryName == nil {
                    imports[index].libraryName = decorated.libraryName
                }
            }
        }
        exports = dynamicSymbols.compactMap { dynSymbol in
            guard !dynSymbol.name.isEmpty,
                  dynSymbol.sectionIndex != Self.shnUndef else { return nil }
            let type = dynSymbol.info & 0x0F
            guard type == Self.sttFunc || type == Self.sttObject else { return nil }
            return ExportSummary(
                id: UUID(),
                name: versionInfo.decoratedName(dynSymbol.name, symbolIndex: dynSymbol.index),
                address: dynSymbol.value,
                source: "dynsym"
            )
        }
        let pltStubs = resolvePLTStubs(
            reader: reader,
            sections: elfSections,
            dynSymbols: dynamicSymbols,
            versionInfo: versionInfo,
            is64: is64Bit,
            machine: eMachine
        )
        let pointerEntrySize: UInt32 = is64Bit ? 8 : 4
        let indirectSymbols = pltStubs.map { stub in
            let projectedSymbolIndex: Int?
            if let symbolIndex = Int(exactly: stub.symbolIndex),
               symbolIndex >= 0,
               symbolIndex < dynamicSymbols.count {
                projectedSymbolIndex = symbolIndex
            } else {
                projectedSymbolIndex = nil
            }
            return IndirectSymbolSummary(
                id: UUID(),
                kind: "plt",
                // Preserve the section the parser resolved (.plt vs .plt.sec for CET/IBT binaries)
                // instead of discarding it — mirrors the Mach-O qualified-sourceSection contract.
                sourceSection: stub.sourceSection,
                address: stub.gotSlotVA,
                entrySize: pointerEntrySize,
                tableIndex: stub.tableIndex,
                rawSymbolIndex: stub.symbolIndex,
                symbolIndex: projectedSymbolIndex,
                symbolName: stub.importName,
                libraryOrdinal: nil,
                libraryName: stub.libraryName,
                isLocal: false,
                isAbsolute: false
            )
        }

        // Read-only C-string literals from .rodata*.
        var stringLiterals: [StringLiteralSummary] = []
        for header in headers where header.type == Self.shtProgBits && sectionName(header).hasPrefix(".rodata") {
            guard let rodataRange = reader.range(header.fileOffset, header.size) else { continue }
            reader.scanCStrings(
                fileOffset: rodataRange.lowerBound,
                size: rodataRange.count,
                baseAddress: header.address,
                sectionName: sectionName(header)
            ) { stringLiterals.append($0) }
        }

        // Map e_machine → a decoder CPU type where a host decoder exists; otherwise a
        // descriptive name (cpuType 0 — the section/symbol model still loads, it just
        // won't disassemble). 32-bit and big-endian machines that lack a decoder fall
        // here, which is fine: the loader's job is the neutral model.
        let cpuType: Int32
        let architectureName: String
        switch eMachine {
        case Self.emX86_64: cpuType = MachOConstants.cpuTypeX86_64; architectureName = "x86_64"
        case Self.emAArch64: cpuType = MachOConstants.cpuTypeARM64; architectureName = "arm64"
        case Self.em386: cpuType = 0; architectureName = "i386"
        case Self.emARM: cpuType = 0; architectureName = "arm"
        case Self.emPPC: cpuType = 0; architectureName = "ppc"
        case Self.emPPC64: cpuType = 0; architectureName = "ppc64"
        case Self.emMIPS: cpuType = 0; architectureName = "mips"
        case Self.emSPARC: cpuType = 0; architectureName = "sparc"
        default: cpuType = 0; architectureName = "elf-machine-\(eMachine)"
        }

        let fileTypeName: String
        switch eType {
        case 1: fileTypeName = "ELF relocatable"
        case 2: fileTypeName = "ELF executable"
        case 3: fileTypeName = "ELF shared object"
        case 4: fileTypeName = "ELF core"
        default: fileTypeName = "ELF object"
        }

        // Format-neutral relocations surfaced on the model. Symbol names are resolved ONLY for
        // dynamic-linking relocation sections (.rela.plt/.rela.dyn), which link to .dynsym; other
        // sections (e.g. .rela.text in a relocatable object) link to .symtab, which this loader does
        // not parse — so their symbol stays nil rather than risk attaching a wrong .dynsym name.
        let relocations: [RelocationSummary] = parseRelocations(
            reader: reader, sections: elfSections, is64: is64Bit
        ).map { rel in
            let isDynamicSection = rel.sectionName.contains(".plt") || rel.sectionName.contains(".dyn")
            let resolvedName: String? = {
                guard isDynamicSection, rel.symIndex > 0,
                      Int(rel.symIndex) < dynamicSymbols.count else { return nil }
                let name = dynamicSymbols[Int(rel.symIndex)].name
                return name.isEmpty ? nil : name
            }()
            return RelocationSummary(
                id: UUID(),
                address: rel.offset,
                sectionName: rel.sectionName,
                typeCode: rel.type,
                typeName: Self.elfRelocationTypeName(rel.type, machine: eMachine),
                symbolName: resolvedName,
                symbolIndex: rel.symIndex,
                addend: rel.addend
            )
        }

        var metadata = BinaryMetadataSummary.empty
        if let programHeaders {
            let facts = ELFProgramHeaderBinaryProjection.metadataFacts(catalog: programHeaders)
            metadata.elfGNUBuildID = facts.buildID
            metadata.platformName = facts.platformName
            metadata.minimumOSVersion = facts.minimumOSVersion
        }
        // Reaching this point proves the section table is the primary loader authority.
        // Optional program headers may enrich GNU-note metadata, but they must not erase a
        // section-validated entry point merely because the catalog is empty or lacks PT_LOAD.
        // The sectionless path returned above and still requires an executable file-backed
        // PT_LOAD through ELFProgramHeaderBinaryProjection.validatedEntryPoint.
        let validatedEntry = validatedSectionEntryPoint(eEntry, sections: sections)

        return LoadedBinary(
            name: name,
            path: path,
            isBundle: false,
            cpuType: cpuType,
            fileTypeName: fileTypeName,
            architectureDisplayName: architectureName,
            metadata: metadata,
            bytes: bytes,
            sliceOffset: 0,
            sections: sections,
            executableTextSection: executableText,
            entryPointAddress: validatedEntry,
            symbols: symbols,
            imports: imports,
            indirectSymbols: indirectSymbols,
            exports: exports,
            stringLiterals: stringLiterals,
            functionStarts: functionStarts,
            objcSelectors: [:],
            diagnosticTruncations: metadataTableTruncations(headers, reader: reader, is64Bit: is64Bit),
            relocations: relocations
        )
    }

    /// Preserve best-effort loading while disclosing declared metadata tables
    /// whose extents, entries or linked strings cannot be consumed.
    private static func metadataTableTruncations(
        _ headers: [SectionHeader], reader: LittleEndianReader, is64Bit: Bool
    ) -> [LoaderDiagnosticTruncation] {
        headers.compactMap { header in
            guard header.size > 0 else { return nil }
            let message: String?
            switch header.type {
            case shtSymTab, shtDynSym:
                let minimumEntrySize: UInt64 = is64Bit ? 24 : 16
                if reader.range(header.fileOffset, header.size) == nil {
                    message = "ELF symbol table was skipped because its file extent is invalid."
                } else if header.entrySize < minimumEntrySize && !(header.type == shtDynSym && header.entrySize == 0) {
                    message = "ELF symbol table was skipped because its entry size is invalid."
                } else if Int(header.link) >= headers.count {
                    message = "ELF symbol table has an invalid linked string table."
                } else {
                    let strings = headers[Int(header.link)]
                    message = reader.range(strings.fileOffset, strings.size) == nil
                        ? "ELF symbol names were skipped because the linked string table extent is invalid."
                        : nil
                }
            case 4, 9: // SHT_RELA, SHT_REL; a zero stride uses the parser's ABI default.
                let minimumEntrySize: UInt64 = header.type == 4 ? (is64Bit ? 24 : 12) : (is64Bit ? 16 : 8)
                message = reader.range(header.fileOffset, header.size) == nil
                    || (header.entrySize != 0 && header.entrySize < minimumEntrySize)
                    ? "ELF relocation table was skipped because its file extent or entry size is invalid."
                    : nil
            default: return nil
            }
            return message.map { LoaderDiagnosticTruncation(address: header.address, message: $0) }
        }
    }

    private static func validatedSectionEntryPoint(
        _ entryPoint: UInt64,
        sections: [BinarySection]
    ) -> UInt64? {
        guard entryPoint != 0 else { return nil }
        return sections.contains { section in
            guard section.isExecutable, !section.isZeroFill,
                  entryPoint >= section.address else { return false }
            let relative = entryPoint - section.address
            return relative < min(section.size, section.fileSize ?? section.size)
        } ? entryPoint : nil
    }

    private static func mapProgramHeaderError(_ error: ELFProgramHeaderError) -> ELFLoadError {
        switch error {
        case .notELF: .notELF
        case .truncated(let context): .truncated(context)
        case .unsupported(let detail): .unsupported(detail)
        case .malformed(let detail): .malformed(detail)
        }
    }

    /// Best-effort human label for the common x86-64 / AArch64 relocation types; nil for the long
    /// tail (rendered as the raw code by callers). Correctness-over-coverage — only well-known codes.
    static func elfRelocationTypeName(_ type: UInt32, machine: UInt16) -> String? {
        switch machine {
        case Self.emX86_64:
            switch type {
            case 1: return "R_X86_64_64";        case 2: return "R_X86_64_PC32"
            case 4: return "R_X86_64_PLT32";      case 5: return "R_X86_64_COPY"
            case 6: return "R_X86_64_GLOB_DAT";   case 7: return "R_X86_64_JUMP_SLOT"
            case 8: return "R_X86_64_RELATIVE";   case 9: return "R_X86_64_GOTPCREL"
            case 41: return "R_X86_64_GOTPCRELX"; case 42: return "R_X86_64_REX_GOTPCRELX"
            default: return nil
            }
        case Self.emAArch64:
            switch type {
            case 257: return "R_AARCH64_ABS64";   case 258: return "R_AARCH64_ABS32"
            case 274: return "R_AARCH64_ADR_PREL_PG_HI21"
            case 277: return "R_AARCH64_ADD_ABS_LO12_NC"
            case 282: return "R_AARCH64_JUMP26";  case 283: return "R_AARCH64_CALL26"
            case 1024: return "R_AARCH64_COPY";   case 1025: return "R_AARCH64_GLOB_DAT"
            case 1026: return "R_AARCH64_JUMP_SLOT"; case 1027: return "R_AARCH64_RELATIVE"
            default: return nil
            }
        default:
            return nil
        }
    }
}
