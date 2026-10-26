import Foundation

enum PELoadError: LocalizedError {
    case notPE
    case unsupported(String)
    case truncated(String)
    case boundExceeded(String)

    var errorDescription: String? {
        switch self {
        case .notPE: "The file is not a PE/COFF binary."
        case .unsupported(let detail): "Unsupported PE/COFF: \(detail)."
        case .truncated(let context): "The PE/COFF file is truncated or malformed (\(context))."
        case .boundExceeded(let context): "The PE/COFF file exceeds analysis limits (\(context))."
        }
    }
}

/// A first-increment PE / COFF loader — the third `BinaryLoader`. Handles a PE image
/// (the "MZ" DOS header → "PE\0\0" → COFF header → optional header → sections) and a
/// bare COFF object (the COFF header directly), projecting either to the neutral
/// `LoadedBinary` so PE binaries decode/analyze exactly like Mach-O and ELF.
///
/// Scope: x86_64 / arm64 (the host decoders), PE32+ and PE32. It reads the COFF file
/// header, optional header (entry point + image base), the section table (incl. the
/// `/N` long-name indirection), the COFF symbol table (incl. aux-entry skipping and
/// the string table), and `.rdata` C-strings. It ALSO parses the PE optional-header data
/// directories — `IMAGE_DIRECTORY_ENTRY_IMPORT` (the import directory table → per-DLL
/// hint/name entries, ordinal imports included) into `ImportSummary`, and
/// `IMAGE_DIRECTORY_ENTRY_EXPORT` (the export directory → named + ordinal exports) into
/// `ExportSummary` — which is the only source of imports/exports for real linked PE
/// images (those don't carry a COFF symbol table); the COFF-symbol path remains the
/// fallback for object files. Relocations and resource data are out of scope this
/// increment. Hardened against malformed input (every region range-validated via
/// `LittleEndianReader`; RVA→file-offset translation is bounds-checked, never traps).
struct PEBinaryLoader: BinaryLoader {
    /// 0 preserves saved legacy coordinates; 1 assigns fixed 4-GiB slots in table order.
    let coffSectionLayoutVersion: Int

    init(coffSectionLayoutVersion: Int = 1) {
        self.coffSectionLayoutVersion = coffSectionLayoutVersion
    }

    private static let machineAMD64: UInt16 = 0x8664
    private static let machineARM64: UInt16 = 0xAA64
    private static let machineI386: UInt16 = 0x014C
    private static let scnMemExecute: UInt32 = 0x2000_0000
    private static let scnCntCode: UInt32 = 0x0000_0020
    private static let scnCntUninitializedData: UInt32 = 0x0000_0080  // IMAGE_SCN_CNT_UNINITIALIZED_DATA (.bss)
    private static let fileDLL: UInt16 = 0x2000
    private static let symClassExternal: UInt8 = 2
    private static let symDTypeFunction: UInt16 = 2 // (Type >> 4) == 2

    func load(at url: URL) throws -> LoadedBinary {
        guard let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw PELoadError.truncated("file unreadable")
        }
        return try Self.parse(bytes: bytes, name: url.lastPathComponent, path: url.path,
                              coffSectionLayoutVersion: coffSectionLayoutVersion)
    }

    /// Detects a PE image ("MZ") or a bare COFF object (a known machine word at 0).
    static func isPEorCOFF(_ bytes: Data) -> Bool {
        guard bytes.count >= 2 else { return false }
        let s = bytes.startIndex
        if bytes[s] == 0x4D && bytes[s + 1] == 0x5A { return true } // "MZ"
        let machine = UInt16(bytes[s]) | UInt16(bytes[s + 1]) << 8
        return machine == machineAMD64 || machine == machineARM64 || machine == machineI386
    }

    private struct Section {
        var name: String
        var virtualSize: UInt32
        var rva: UInt32
        var sizeOfRawData: UInt32
        var pointerToRawData: UInt32
        var characteristics: UInt32
    }

    /// One budget is shared by every name/string consumer during a parse. Counting entries alone
    /// does not bound work or memory when many entries point at the same long string.
    struct StringLimits: Sendable {
        var maximumStringBytes: Int
        var maximumTotalStringBytes: Int
        var maximumTotalScannedBytes: Int

        static let production = StringLimits(
            maximumStringBytes: 1 * 1_024 * 1_024,
            maximumTotalStringBytes: 32 * 1_024 * 1_024,
            maximumTotalScannedBytes: 64 * 1_024 * 1_024
        )
    }

    static func parse(
        bytes: Data, name fileName: String, path: String,
        coffSectionLayoutVersion: Int = 1,
        stringLimits: StringLimits = .production
    ) throws -> LoadedBinary {
        guard coffSectionLayoutVersion == 0 || coffSectionLayoutVersion == 1 else {
            throw PELoadError.unsupported("COFF analysis coordinate layout version")
        }
        let reader = LittleEndianReader(bytes)
        let stringBudget = try StringReadBudget(limits: stringLimits)

        // Locate the COFF file header: after the DOS+PE chain for an image, or at 0
        // for a bare object.
        var coffOffset = 0
        var hasOptionalHeader = false
        let isImage = reader.byte(0) == 0x4D && reader.byte(1) == 0x5A
        if isImage {
            guard bytes.count >= 0x40 else { throw PELoadError.truncated("DOS header") }
            let peSignatureOffset = Int(try reader.u32(0x3C))
            guard reader.byte(peSignatureOffset) == 0x50, reader.byte(peSignatureOffset + 1) == 0x45,
                  reader.byte(peSignatureOffset + 2) == 0, reader.byte(peSignatureOffset + 3) == 0 else {
                throw PELoadError.notPE
            }
            coffOffset = peSignatureOffset + 4
            hasOptionalHeader = true
        } else {
            let machine = try reader.u16(0)
            guard machine == machineAMD64 || machine == machineARM64 || machine == machineI386 else {
                throw PELoadError.notPE
            }
        }

        // COFF file header (20 bytes).
        let machine = try reader.u16(coffOffset + 0)
        let numberOfSections = Int(try reader.u16(coffOffset + 2))
        let pointerToSymbolTable = try reader.u32(coffOffset + 8)
        let numberOfSymbols = try reader.u32(coffOffset + 12)
        let sizeOfOptionalHeader = Int(try reader.u16(coffOffset + 16))
        let characteristics = try reader.u16(coffOffset + 18)

        // Optional header (entry point + image base + data directories), PE images only.
        // The data-directory array lives at a magic-dependent offset: PE32 puts
        // `NumberOfRvaAndSizes` at +92 and the array at +96; PE32+ at +108 / +112
        // (the 8-byte ImageBase vs 4-byte BaseOfData/ImageBase shifts everything after).
        // Each directory entry is {RVA: u32, Size: u32}. Index 0 = EXPORT, 1 = IMPORT.
        var imageBase: UInt64 = 0
        var entryRVA: UInt32 = 0
        var isPE32Plus = false
        var exportDirRVA: UInt32 = 0, exportDirSize: UInt32 = 0
        var importDirRVA: UInt32 = 0, importDirSize: UInt32 = 0
        if hasOptionalHeader, sizeOfOptionalHeader >= 32 {
            let optionalOffset = coffOffset + 20
            let magic = try reader.u16(optionalOffset)
            entryRVA = try reader.u32(optionalOffset + 16)
            let dataDirArrayOffset: Int
            if magic == 0x20B {        // PE32+
                isPE32Plus = true
                imageBase = try reader.u64(optionalOffset + 24)
                dataDirArrayOffset = optionalOffset + 112
            } else if magic == 0x10B { // PE32
                imageBase = UInt64(try reader.u32(optionalOffset + 28))
                dataDirArrayOffset = optionalOffset + 96
            } else {
                dataDirArrayOffset = -1
            }
            // The logical count is independent of the declared/readable byte extents.
            // Its complete field must belong to the optional header, not section bytes.
            let optionalEnd = optionalOffset + sizeOfOptionalHeader
            if dataDirArrayOffset >= 0, dataDirArrayOffset <= optionalEnd,
               let directoryCount = try? reader.u32(dataDirArrayOffset - 4) {
                func directory(_ index: Int) -> (rva: UInt32, size: UInt32) {
                    let entry = dataDirArrayOffset + index * 8
                    guard index < Int(directoryCount), entry + 8 <= optionalEnd,
                          let rva = try? reader.u32(entry),
                          let size = try? reader.u32(entry + 4) else { return (0, 0) }
                    return (rva, size)
                }
                (exportDirRVA, exportDirSize) = directory(0) // IMAGE_DIRECTORY_ENTRY_EXPORT
                (importDirRVA, importDirSize) = directory(1) // IMAGE_DIRECTORY_ENTRY_IMPORT
            }
        }

        // The string table (long section names + symbol names) follows the symbol
        // table; its first 4 bytes are its total size. `stringTableEnd` is the
        // VALIDATED end so name lookups can't wander outside it on a crafted offset.
        let stringTableOffset = pointerToSymbolTable != 0
            ? Int(pointerToSymbolTable) + Int(numberOfSymbols) * 18
            : 0
        let stringTableEnd: Int = {
            guard stringTableOffset > 0, stringTableOffset + 4 <= bytes.count,
                  let size = try? reader.u32(stringTableOffset),
                  let full = reader.range(UInt64(stringTableOffset), UInt64(size)) else { return 0 }
            return full.upperBound
        }()

        // Section table (40 bytes each).
        let sectionTableOffset = coffOffset + 20 + sizeOfOptionalHeader
        guard reader.range(UInt64(sectionTableOffset), UInt64(numberOfSections) * 40) != nil else {
            throw PELoadError.truncated("section table")
        }
        var sectionHeaders: [Section] = []
        sectionHeaders.reserveCapacity(numberOfSections)
        for index in 0..<numberOfSections {
            let base = sectionTableOffset + index * 40
            sectionHeaders.append(Section(
                name: try sectionName(reader, at: base, stringTableOffset: stringTableOffset, stringTableEnd: stringTableEnd, budget: stringBudget),
                virtualSize: try reader.u32(base + 8),
                rva: try reader.u32(base + 12),
                sizeOfRawData: try reader.u32(base + 16),
                pointerToRawData: try reader.u32(base + 20),
                characteristics: try reader.u32(base + 36)
            ))
        }

        let usesSectionCoordinates = !isImage && coffSectionLayoutVersion == 1
        func sectionAddress(_ index: Int) -> UInt64 {
            // The header limits section count to UInt16 and each span to UInt32. A one-based
            // ordinal shifted by 32 therefore gives disjoint, nonoverflowing fixed-aligned slots.
            usesSectionCoordinates
                ? UInt64(index + 1) << 32
                : imageBase &+ UInt64(sectionHeaders[index].rva)
        }
        let sections = sectionHeaders.enumerated().map { index, section -> BinarySection in
            let size = section.virtualSize != 0 ? section.virtualSize : section.sizeOfRawData
            let isBSS = section.characteristics & Self.scnCntUninitializedData != 0
            return BinarySection(
                name: section.name,
                address: sectionAddress(index),
                size: UInt64(size),
                fileOffset: UInt64(section.pointerToRawData),
                isExecutable: section.characteristics & (Self.scnMemExecute | Self.scnCntCode) != 0,
                isZeroFill: isBSS,
                // PE raw data (`SizeOfRawData`) and virtual span (`VirtualSize`) differ: raw is
                // padded up to file alignment, virtual is the real in-memory extent. Carrying the
                // physical size lets the byte-mapping derivation clamp raw padding past the virtual
                // span so it never acquires a synthetic address. Zero-fill sections have no file
                // bytes regardless, so leave their physical size unset.
                fileSize: isBSS ? nil : UInt64(section.sizeOfRawData),
                coffCoordinate: usesSectionCoordinates
                    ? COFFSectionCoordinate(sectionOrdinal: index + 1, originalRVA: section.rva)
                    : nil
            )
        }
        let executableText = sections.first(where: { $0.name == ".text" && $0.isExecutable && $0.size > 0 })
            ?? sections.first(where: { $0.isExecutable && $0.size > 0 })

        // COFF symbol table (18-byte records; aux records follow their owner and are
        // skipped). A defined symbol's value is its offset within its section, so the
        // virtual address is imageBase + section RVA + value.
        var symbols: [SymbolSummary] = []
        var imports: [ImportSummary] = []
        var exports: [ExportSummary] = []
        var functionStarts: [UInt64] = []
        if pointerToSymbolTable != 0, numberOfSymbols > 0,
           let symRange = reader.range(UInt64(pointerToSymbolTable), UInt64(numberOfSymbols) * 18) {
            var index = 0
            while index < Int(numberOfSymbols) {
                let base = symRange.lowerBound + index * 18
                let auxCount = Int(reader.byte(base + 17) ?? 0)
                index += 1 + auxCount
                let name = try symbolName(reader, at: base, stringTableOffset: stringTableOffset, stringTableEnd: stringTableEnd, budget: stringBudget)
                guard !name.isEmpty else { continue }
                let value = (try? reader.u32(base + 8)) ?? 0
                let sectionNumber = Int(Int16(bitPattern: (try? reader.u16(base + 12)) ?? 0))
                let type = (try? reader.u16(base + 14)) ?? 0
                let storageClass = reader.byte(base + 16) ?? 0

                let isUndefined = sectionNumber == 0
                let address: UInt64? = {
                    guard sectionNumber > 0, sectionNumber <= sectionHeaders.count else { return nil }
                    let section = sections[sectionNumber - 1]
                    // A section-relative symbol outside its declared span has no authoritative
                    // address. Keep the name, but never seed a function in another section.
                    if usesSectionCoordinates, UInt64(value) >= section.size { return nil }
                    return section.address &+ UInt64(value)
                }()
                let kind: String = isUndefined ? "undefined"
                    : (sectionNumber < 0 ? "absolute" : (storageClass == Self.symClassExternal ? "export" : "local"))
                symbols.append(SymbolSummary(
                    id: UUID(), name: name, address: address, kind: kind,
                    libraryName: nil, rawLinkageName: name
                ))

                if isUndefined {
                    imports.append(ImportSummary(id: UUID(), name: name, libraryName: nil, libraryOrdinal: nil))
                } else if type >> 4 == Self.symDTypeFunction, let address {
                    functionStarts.append(address)
                    if storageClass == Self.symClassExternal {
                        exports.append(ExportSummary(id: UUID(), name: name, address: address, source: "symtab"))
                    }
                }
            }
        }

        // PE data directories (real linked images carry no COFF symbol table, so this
        // is the primary import/export source). RVA→file-offset goes through the section
        // map; every read is bounds-checked via `reader`, so malformed tables can't trap.
        if hasOptionalHeader {
            // Map an RVA to a file offset by finding the containing section. Returns nil
            // for RVAs outside every section's raw range (so reads degrade, never trap).
            func fileOffset(forRVA rva: UInt32) -> Int? {
                for section in sectionHeaders {
                    let rawSize = section.virtualSize != 0
                        ? max(section.virtualSize, section.sizeOfRawData) : section.sizeOfRawData
                    guard let delta = sectionRelativeOffset(
                        forRVA: rva, sectionStart: section.rva, sectionSize: rawSize
                    ) else { continue }
                    // Only data that's actually backed by file bytes is readable.
                    guard delta < section.sizeOfRawData else { return nil }
                    return Int(section.pointerToRawData) + Int(delta)
                }
                return nil
            }
            // Read a NUL-terminated ASCII name at an RVA, confined to the file.
            func nameAtRVA(_ rva: UInt32) throws -> String {
                guard rva != 0, let off = fileOffset(forRVA: rva) else { return "" }
                return try stringBudget.cString(reader, fileOffset: off, limit: bytes.count)
            }

            if importDirRVA != 0 {
                try parseImportDirectory(
                    reader: reader, dirRVA: importDirRVA, dirSize: importDirSize,
                    isPE32Plus: isPE32Plus,
                    fileOffset: fileOffset, nameAtRVA: nameAtRVA, budget: stringBudget, into: &imports)
            }
            if exportDirRVA != 0 {
                try parseExportDirectory(
                    reader: reader, dirRVA: exportDirRVA, dirSize: exportDirSize,
                    imageBase: imageBase, fileOffset: fileOffset, nameAtRVA: nameAtRVA, budget: stringBudget, into: &exports)
            }
        }

        // Read-only C-string literals from .rdata / .rodata.
        var stringLiterals: [StringLiteralSummary] = []
        for (index, section) in sectionHeaders.enumerated() where section.name.hasPrefix(".rdata") || section.name.hasPrefix(".rodata") {
            let scanSize = usesSectionCoordinates
                ? min(UInt64(section.sizeOfRawData), sections[index].size)
                : UInt64(section.sizeOfRawData)
            guard !sections[index].isZeroFill,
                  let range = reader.range(UInt64(section.pointerToRawData), scanSize) else { continue }
            try stringBudget.scanCStrings(
                reader: reader,
                fileOffset: range.lowerBound,
                size: range.count,
                baseAddress: sectionAddress(index),
                sectionName: section.name
            ) { stringLiterals.append($0) }
        }

        let cpuType: Int32
        let architectureName: String
        switch machine {
        case Self.machineAMD64: cpuType = MachOConstants.cpuTypeX86_64; architectureName = "x86_64"
        case Self.machineARM64: cpuType = MachOConstants.cpuTypeARM64; architectureName = "arm64"
        default: cpuType = 0; architectureName = "pe-machine-0x\(String(machine, radix: 16))"
        }
        let fileTypeName: String
        if !isImage {
            fileTypeName = "COFF object"
        } else if characteristics & Self.fileDLL != 0 {
            fileTypeName = "PE dynamic library"
        } else {
            fileTypeName = "PE executable"
        }

        var metadata = BinaryMetadataSummary.empty
        if !isImage { metadata.coffSectionLayoutVersion = coffSectionLayoutVersion }
        return LoadedBinary(
            name: fileName,
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
            entryPointAddress: (isImage && entryRVA != 0) ? imageBase &+ UInt64(entryRVA) : nil,
            symbols: symbols,
            imports: imports,
            indirectSymbols: [],
            exports: exports,
            stringLiterals: stringLiterals,
            functionStarts: functionStarts,
            objcSelectors: [:]
        )
    }

    /// Validates membership without forming an exclusive end that may exceed UInt32.
    /// File backing is checked separately by the caller and the bounded reader.
    static func sectionRelativeOffset(
        forRVA rva: UInt32, sectionStart: UInt32, sectionSize: UInt32
    ) -> UInt32? {
        guard rva >= sectionStart else { return nil }
        let offset = rva - sectionStart
        guard offset < sectionSize else { return nil }
        return offset
    }

    // The ordinal flag in an Import Lookup Table / IAT thunk: the high bit of the
    // pointer-sized entry (0x8000_0000 for PE32, 0x8000_0000_0000_0000 for PE32+).
    private static let ordinalFlag32: UInt32 = 0x8000_0000
    private static let ordinalFlag64: UInt64 = 0x8000_0000_0000_0000
    // A safety cap on per-table iteration so a malformed (unterminated) table can't loop
    // indefinitely on a large mapped file.
    private static let maxDirectoryEntries = 65_536

    /// Parses `IMAGE_DIRECTORY_ENTRY_IMPORT`: an array of 20-byte import descriptors
    /// (terminated by an all-zero descriptor), each naming a DLL and pointing at an
    /// Import Lookup Table of hint/name (or ordinal) entries. Emits one `ImportSummary`
    /// per imported symbol, tagged with its DLL and (for by-ordinal imports) the ordinal.
    private static func parseImportDirectory(
        reader: LittleEndianReader,
        dirRVA: UInt32, dirSize: UInt32,
        isPE32Plus: Bool,
        fileOffset: (UInt32) -> Int?,
        nameAtRVA: (UInt32) throws -> String,
        budget: StringReadBudget,
        into imports: inout [ImportSummary]
    ) throws {
        guard let descBase = fileOffset(dirRVA) else { return }
        // Aggregate cap across ALL descriptors × thunks. The per-descriptor and per-thunk
        // caps are each `maxDirectoryEntries`, so without this they MULTIPLY: a crafted PE
        // whose descriptors all point at a shared in-bounds, non-zero thunk region (no read
        // fails, no null terminator) would emit up to 65536×65536 ≈ 4.29e9 imports → OOM/hang.
        // `totalImports` bounds emitted entries; `totalThunks` bounds WORK. An entry
        // that resolves to an empty name `continue`s without emitting, so it would not
        // advance `totalImports` — but it still costs a read + name scan. Without a
        // work budget, 65536 descriptors × 65536 empty-name thunks = ~4.29e9 iterations
        // bypasses the import cap. `totalThunks` advances on EVERY thunk, append or not.
        var totalImports = 0
        var totalThunks = 0
        var descIndex = 0
        while descIndex < maxDirectoryEntries {
            if totalImports >= maxDirectoryEntries || totalThunks >= maxDirectoryEntries { break }
            let desc = descBase + descIndex * 20
            // Each descriptor: OriginalFirstThunk(ILT RVA)@0, TimeDateStamp@4,
            // ForwarderChain@8, Name(DLL name RVA)@12, FirstThunk(IAT RVA)@16.
            guard let iltRVA = try? reader.u32(desc),
                  let nameRVA = try? reader.u32(desc + 12),
                  let iatRVA = try? reader.u32(desc + 16) else { break }
            if iltRVA == 0 && nameRVA == 0 && iatRVA == 0 { break } // null terminator
            descIndex += 1

            let dll = try nameAtRVA(nameRVA)
            let library = dll.isEmpty ? nil : dll
            // Prefer the Import Lookup Table (a.k.a. OriginalFirstThunk); fall back to the
            // IAT (FirstThunk) when the ILT is absent (bound/stripped imports).
            let thunkRVA = iltRVA != 0 ? iltRVA : iatRVA
            guard thunkRVA != 0, let thunkBase = fileOffset(thunkRVA) else { continue }

            var thunkIndex = 0
            while thunkIndex < maxDirectoryEntries {
                if totalImports >= maxDirectoryEntries || totalThunks >= maxDirectoryEntries { break }
                let entryOffset = thunkBase + thunkIndex * (isPE32Plus ? 8 : 4)
                thunkIndex += 1
                let isOrdinal: Bool
                let hintNameRVA: UInt32
                let ordinal: Int?
                if isPE32Plus {
                    guard let value = try? reader.u64(entryOffset) else { break }
                    if value == 0 { break } // null terminator
                    isOrdinal = (value & ordinalFlag64) != 0
                    hintNameRVA = UInt32(truncatingIfNeeded: value)
                    ordinal = isOrdinal ? Int(value & 0xFFFF) : nil
                } else {
                    guard let value = try? reader.u32(entryOffset) else { break }
                    if value == 0 { break } // null terminator
                    isOrdinal = (value & ordinalFlag32) != 0
                    hintNameRVA = value
                    ordinal = isOrdinal ? Int(value & 0xFFFF) : nil
                }
                // Count every NON-terminator thunk against the work budget — AFTER the
                // terminator checks (a terminator exits the loop anyway) but BEFORE the
                // empty-name `continue`, which is the path that would otherwise spin
                // without advancing the append-only `totalImports` counter.
                totalThunks += 1
                if isOrdinal {
                    let label = library.map { "\($0)#\(ordinal ?? 0)" } ?? "#\(ordinal ?? 0)"
                    imports.append(ImportSummary(id: UUID(), name: try budget.admit(label), libraryName: library, libraryOrdinal: ordinal))
                    totalImports += 1
                } else {
                    // hint/name entry: u16 hint, then a NUL-terminated name.
                    let name = try nameAtRVA(hintNameRVA &+ 2)
                    guard !name.isEmpty else { continue }
                    imports.append(ImportSummary(id: UUID(), name: name, libraryName: library, libraryOrdinal: nil))
                    totalImports += 1
                }
            }
        }
    }

    /// Parses `IMAGE_DIRECTORY_ENTRY_EXPORT`: the export directory table → the parallel
    /// name-pointer / name-ordinal arrays (named exports) and the export-address table
    /// (every export's address, including by-ordinal-only ones). Emits one `ExportSummary`
    /// per export. Forwarder exports (whose address falls inside the export directory
    /// itself) keep their declared address but are still listed.
    private static func parseExportDirectory(
        reader: LittleEndianReader,
        dirRVA: UInt32, dirSize: UInt32,
        imageBase: UInt64,
        fileOffset: (UInt32) -> Int?,
        nameAtRVA: (UInt32) throws -> String,
        budget: StringReadBudget,
        into exports: inout [ExportSummary]
    ) throws {
        guard let base = fileOffset(dirRVA) else { return }
        // IMAGE_EXPORT_DIRECTORY: OrdinalBase@16, NumberOfFunctions@20, NumberOfNames@24,
        // AddressOfFunctions(EAT RVA)@28, AddressOfNames@32, AddressOfNameOrdinals@36.
        guard let ordinalBase = try? reader.u32(base + 16),
              let numFunctions = try? reader.u32(base + 20),
              let numNames = try? reader.u32(base + 24),
              let eatRVA = try? reader.u32(base + 28),
              let namesRVA = try? reader.u32(base + 32),
              let nameOrdinalsRVA = try? reader.u32(base + 36) else { return }

        let funcCount = min(Int(numFunctions), maxDirectoryEntries)
        let nameCount = min(Int(numNames), maxDirectoryEntries)
        // The export directory's own RVA range — addresses inside it are forwarders.
        let dirStart = dirRVA
        // Checked/saturating add: `dirSize` is attacker-controlled, so a wrapping `&+` could
        // wrap `dirEnd` BELOW `dirStart`, making the `rva >= dirStart && rva < dirEnd`
        // forwarder test never fire and mislabeling genuine forwarders as "export-table".
        let (sum, ov) = dirRVA.addingReportingOverflow(dirSize)
        let dirEnd = ov ? UInt32.max : sum

        // Read every export address from the EAT (index = ordinal - ordinalBase).
        var addresses: [UInt32] = []
        addresses.reserveCapacity(funcCount)
        if let eatBase = fileOffset(eatRVA) {
            for i in 0..<funcCount {
                addresses.append((try? reader.u32(eatBase + i * 4)) ?? 0)
            }
        }

        // Resolve names → ordinals so named exports carry their symbol name.
        var nameByOrdinalIndex: [Int: String] = [:]
        if let namesBase = fileOffset(namesRVA), let ordinalsBase = fileOffset(nameOrdinalsRVA) {
            for i in 0..<nameCount {
                guard let nameRVA = try? reader.u32(namesBase + i * 4),
                      let ordIndex = try? reader.u16(ordinalsBase + i * 2) else { continue }
                let name = try nameAtRVA(nameRVA)
                if !name.isEmpty { nameByOrdinalIndex[Int(ordIndex)] = name }
            }
        }

        for index in 0..<addresses.count {
            let rva = addresses[index]
            if rva == 0 { continue } // unused EAT slot
            let isForwarder = rva >= dirStart && rva < dirEnd
            let address = imageBase &+ UInt64(rva)
            if let name = nameByOrdinalIndex[index] {
                exports.append(ExportSummary(id: UUID(), name: name, address: address, source: isForwarder ? "forwarder" : "export-table"))
            } else {
                let ordinal = UInt32(index) &+ ordinalBase
                exports.append(ExportSummary(id: UUID(), name: try budget.admit("#\(ordinal)"), address: address, source: isForwarder ? "forwarder" : "export-table"))
            }
        }
    }

    /// Reads an 8-byte COFF section name, resolving the `/N` long-name indirection
    /// into the string table.
    private static func sectionName(_ reader: LittleEndianReader, at base: Int, stringTableOffset: Int, stringTableEnd: Int, budget: StringReadBudget) throws -> String {
        var raw: [UInt8] = []
        for offset in 0..<8 {
            try budget.accountScannedByte()
            guard let byte = reader.byte(base + offset), byte != 0 else { break }
            raw.append(byte)
        }
        guard let first = raw.first else { return "" }
        if first == 0x2F, stringTableEnd > 0 { // "/<decimal>" long-name offset
            // offset >= 4 skips the 4-byte size prefix; the read is confined to the
            // validated string table so a crafted offset can't read elsewhere.
            if let offset = Int(String(decoding: raw.dropFirst(), as: UTF8.self)), offset >= 4 {
                return try budget.cString(reader, fileOffset: stringTableOffset + offset, limit: stringTableEnd)
            }
        }
        return try budget.decode(raw)
    }

    /// Reads a COFF symbol name: 8-byte inline, or (when the first 4 bytes are zero) a
    /// string-table offset in the next 4 bytes (confined to the validated string table).
    private static func symbolName(_ reader: LittleEndianReader, at base: Int, stringTableOffset: Int, stringTableEnd: Int, budget: StringReadBudget) throws -> String {
        if (try? reader.u32(base)) == 0, stringTableEnd > 0 {
            let offset = Int((try? reader.u32(base + 4)) ?? 0)
            if offset >= 4 {
                return try budget.cString(reader, fileOffset: stringTableOffset + offset, limit: stringTableEnd)
            }
            return ""
        }
        var raw: [UInt8] = []
        for index in 0..<8 {
            try budget.accountScannedByte()
            guard let byte = reader.byte(base + index), byte != 0 else { break }
            raw.append(byte)
        }
        return try budget.decode(raw)
    }

    private final class StringReadBudget {
        let maximumStringBytes: Int
        var remainingStringBytes: Int
        var remainingScannedBytes: Int

        init(limits: StringLimits) throws {
            guard limits.maximumStringBytes >= 0,
                  limits.maximumTotalStringBytes >= 0,
                  limits.maximumTotalScannedBytes >= 0 else {
                throw PELoadError.boundExceeded("invalid string budget")
            }
            maximumStringBytes = limits.maximumStringBytes
            remainingStringBytes = limits.maximumTotalStringBytes
            remainingScannedBytes = limits.maximumTotalScannedBytes
        }

        func accountScannedByte() throws {
            guard remainingScannedBytes > 0 else {
                throw PELoadError.boundExceeded("aggregate string scan bytes")
            }
            remainingScannedBytes -= 1
        }

        func decode(_ raw: [UInt8]) throws -> String {
            guard raw.count <= maximumStringBytes else {
                throw PELoadError.boundExceeded("individual string bytes")
            }
            return try admit(String(decoding: raw, as: UTF8.self))
        }

        func admit(_ value: String) throws -> String {
            // Invalid UTF-8 expands during replacement; budget the retained text's actual size.
            // Constructed ordinal labels are charged too: one long DLL name can otherwise be
            // copied into thousands of distinct "DLL#ordinal" names after its original read.
            let count = value.utf8.count
            guard count <= maximumStringBytes else {
                throw PELoadError.boundExceeded("individual decoded string bytes")
            }
            guard count <= remainingStringBytes else {
                throw PELoadError.boundExceeded("aggregate decoded string bytes")
            }
            remainingStringBytes -= count
            return value
        }

        func cString(
            _ reader: LittleEndianReader, fileOffset: Int, limit: Int
        ) throws -> String {
            let upper = min(limit, reader.bytes.count)
            guard fileOffset >= 0, fileOffset < upper else { return "" }
            var raw: [UInt8] = []
            for offset in fileOffset..<upper {
                try accountScannedByte()
                guard let byte = reader.byte(offset), byte != 0 else { break }
                guard raw.count < maximumStringBytes else {
                    throw PELoadError.boundExceeded("individual string bytes")
                }
                raw.append(byte)
            }
            return try decode(raw)
        }

        func scanCStrings(
            reader: LittleEndianReader, fileOffset: Int, size: Int,
            baseAddress: UInt64, sectionName: String,
            emit: (StringLiteralSummary) -> Void
        ) throws {
            guard fileOffset >= 0, size > 0,
                  reader.range(UInt64(fileOffset), UInt64(size)) != nil else { return }
            var runStart: Int?
            var current: [UInt8] = []
            for relative in 0..<size {
                try accountScannedByte()
                guard let byte = reader.byte(fileOffset + relative) else { return }
                if byte == 0 {
                    if let runStart, !current.isEmpty {
                        let value = try decode(current)
                        emit(StringLiteralSummary(
                            id: UUID(), value: value,
                            address: baseAddress &+ UInt64(runStart),
                            sourceSection: sectionName, byteLength: current.count + 1
                        ))
                    }
                    runStart = nil
                    current.removeAll(keepingCapacity: true)
                } else if byte >= 0x20 && byte < 0x7F {
                    if runStart == nil { runStart = relative }
                    guard current.count < maximumStringBytes else {
                        throw PELoadError.boundExceeded("individual string literal bytes")
                    }
                    current.append(byte)
                } else {
                    runStart = nil
                    current.removeAll(keepingCapacity: true)
                }
            }
        }
    }

}
