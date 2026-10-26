import Foundation

struct ELFSectionInfo: Hashable, Sendable {
    let index: Int
    let name: String
    let type: UInt32
    let flags: UInt64
    let address: UInt64
    let fileOffset: UInt64
    let size: UInt64
    let link: UInt32
    let info: UInt32
    let entrySize: UInt64
}

struct ELFReloc: Hashable, Sendable {
    let sectionIndex: Int
    let sectionName: String
    let offset: UInt64
    let symIndex: UInt32
    let type: UInt32
    let addend: Int64?
    let isRela: Bool
}

struct ELFDynamicSymbol: Hashable, Sendable {
    let index: Int
    let name: String
    let info: UInt8
    let sectionIndex: UInt16
    let value: UInt64
    let size: UInt64
}

struct ELFVersionInfo: Hashable, Sendable {
    let versionIndexNames: [UInt16: String]
    let versionIndexLibraries: [UInt16: String]
    let symbolVersionIndices: [UInt16?]
    let symbolVersionNames: [String?]

    static let empty = ELFVersionInfo(
        versionIndexNames: [:],
        versionIndexLibraries: [:],
        symbolVersionIndices: [],
        symbolVersionNames: []
    )

    func versionName(forSymbolIndex index: Int) -> String? {
        guard index >= 0, index < symbolVersionNames.count else { return nil }
        return symbolVersionNames[index]
    }

    func libraryName(forSymbolIndex index: Int) -> String? {
        guard index >= 0, index < symbolVersionIndices.count,
              let versionIndex = symbolVersionIndices[index] else { return nil }
        return versionIndexLibraries[versionIndex]
    }

    func decoratedName(_ name: String, symbolIndex: Int) -> String {
        guard !name.isEmpty, let versionName = versionName(forSymbolIndex: symbolIndex), !versionName.isEmpty else {
            return name
        }
        return "\(name)@\(versionName)"
    }
}

struct ELFPLTStub: Hashable, Sendable {
    let tableIndex: UInt32
    let stubVA: UInt64
    let gotSlotVA: UInt64
    let symbolIndex: UInt32
    let importName: String
    let libraryName: String?
    let sourceSection: String
}

private let elfShtStrTab: UInt32 = 3
private let elfShtRela: UInt32 = 4
private let elfShtRel: UInt32 = 9
private let elfShtDynSym: UInt32 = 11
private let elfShtGNUVerDef: UInt32 = 0x6ffffffd
private let elfShtGNUVerNeed: UInt32 = 0x6ffffffe
private let elfShtGNUVerSym: UInt32 = 0x6fffffff
private let elfVersionIndexMask: UInt16 = 0x7fff
private let elfMachineX86_64: UInt16 = 62
private let elfMachineAArch64: UInt16 = 183
private let elfRelocX86_64JumpSlot: UInt32 = 7
private let elfRelocAArch64JumpSlot: UInt32 = 1026

func parseRelocations(reader: LittleEndianReader, sections: [ELFSectionInfo], is64: Bool) -> [ELFReloc] {
    var relocations: [ELFReloc] = []
    for section in sections where section.type == elfShtRela || section.type == elfShtRel {
        guard let span = reader.range(section.fileOffset, section.size) else { continue }
        let isRela = section.type == elfShtRela
        let defaultEntrySize = defaultRelocationEntrySize(is64: is64, isRela: isRela)
        let entrySize: Int
        if section.entrySize == 0 {
            entrySize = defaultEntrySize
        } else {
            guard let declared = Int(exactly: section.entrySize), declared >= defaultEntrySize else { continue }
            entrySize = declared
        }

        let count = span.count / entrySize
        for entryIndex in 0..<count {
            let base = span.lowerBound + entryIndex * entrySize
            guard let relocation = readRelocation(
                reader: reader,
                section: section,
                base: base,
                is64: is64,
                isRela: isRela
            ) else { continue }
            relocations.append(relocation)
        }
    }
    return relocations
}

func parseDynamicSymbols(reader: LittleEndianReader, sections: [ELFSectionInfo], is64: Bool) -> [ELFDynamicSymbol] {
    guard let dynsym = sections.first(where: { $0.type == elfShtDynSym }),
          let symbolSpan = reader.range(dynsym.fileOffset, dynsym.size),
          let linkedIndex = Int(exactly: dynsym.link),
          linkedIndex >= 0,
          linkedIndex < sections.count,
          sections[linkedIndex].type == elfShtStrTab,
          let stringSpan = reader.range(sections[linkedIndex].fileOffset, sections[linkedIndex].size) else {
        return []
    }

    let minimumEntrySize = is64 ? 24 : 16
    let entrySize: Int
    if dynsym.entrySize == 0 {
        entrySize = minimumEntrySize
    } else {
        guard let declared = Int(exactly: dynsym.entrySize), declared >= minimumEntrySize else { return [] }
        entrySize = declared
    }

    let count = symbolSpan.count / entrySize
    var symbols: [ELFDynamicSymbol] = []
    symbols.reserveCapacity(count)
    for symbolIndex in 0..<count {
        let base = symbolSpan.lowerBound + symbolIndex * entrySize
        let symbol = readDynamicSymbol(
            reader: reader,
            stringSpan: stringSpan,
            base: base,
            index: symbolIndex,
            is64: is64
        ) ?? ELFDynamicSymbol(
            index: symbolIndex,
            name: "",
            info: 0,
            sectionIndex: 0,
            value: 0,
            size: 0
        )
        symbols.append(symbol)
    }
    return symbols
}

func parseVersionInfo(
    reader: LittleEndianReader,
    sections: [ELFSectionInfo],
    dynSymbols: [ELFDynamicSymbol],
    is64: Bool
) -> ELFVersionInfo {
    _ = is64
    var versionIndexNames: [UInt16: String] = [:]
    var versionIndexLibraries: [UInt16: String] = [:]

    for section in sections where section.type == elfShtGNUVerDef {
        guard let verdefSpan = reader.range(section.fileOffset, section.size),
              let linkedIndex = Int(exactly: section.link),
              linkedIndex >= 0,
              linkedIndex < sections.count,
              let stringSpan = reader.range(sections[linkedIndex].fileOffset, sections[linkedIndex].size) else { continue }

        var definitionRelativeOffset = 0
        var visitedDefinitionRecords = 0
        let maximumDefinitionRecords = max(1, verdefSpan.count / 20)
        while definitionRelativeOffset + 20 <= verdefSpan.count && visitedDefinitionRecords < maximumDefinitionRecords {
            let definitionBase = verdefSpan.lowerBound + definitionRelativeOffset
            guard let rawIndex = try? reader.u16(definitionBase + 4),
                  let auxCount = try? reader.u16(definitionBase + 6),
                  let auxOffset = try? reader.u32(definitionBase + 12),
                  let nextDefinition = try? reader.u32(definitionBase + 16) else { break }

            let versionIndex = rawIndex & elfVersionIndexMask
            if versionIndex > 1,
               let auxStart = Int(exactly: auxOffset),
               definitionRelativeOffset <= Int.max - auxStart,
               let versionName = versionDefinitionName(
                reader: reader,
                span: verdefSpan,
                stringSpan: stringSpan,
                startRelativeOffset: definitionRelativeOffset + auxStart,
                count: auxCount
               ),
               !versionName.isEmpty {
                versionIndexNames[versionIndex] = versionName
            }

            visitedDefinitionRecords += 1
            guard nextDefinition != 0,
                  let advanced = advancedRelativeOffset(
                    from: definitionRelativeOffset,
                    by: nextDefinition,
                    limit: verdefSpan.count,
                    recordSize: 20
                  ) else { break }
            definitionRelativeOffset = advanced
        }
    }

    for section in sections where section.type == elfShtGNUVerNeed {
        guard let verneedSpan = reader.range(section.fileOffset, section.size),
              let linkedIndex = Int(exactly: section.link),
              linkedIndex >= 0,
              linkedIndex < sections.count,
              let stringSpan = reader.range(sections[linkedIndex].fileOffset, sections[linkedIndex].size) else { continue }

        var needRelativeOffset = 0
        var visitedNeedRecords = 0
        let maximumNeedRecords = max(1, verneedSpan.count / 16)
        while needRelativeOffset + 16 <= verneedSpan.count && visitedNeedRecords < maximumNeedRecords {
            let needBase = verneedSpan.lowerBound + needRelativeOffset
            guard let versionCount = try? reader.u16(needBase + 2),
                  let fileNameOffset = try? reader.u32(needBase + 4),
                  let auxOffset = try? reader.u32(needBase + 8),
                  let nextNeed = try? reader.u32(needBase + 12) else { break }

            let libraryName = string(in: stringSpan, offset: fileNameOffset, reader: reader)
            // `vn_aux` is the byte offset to the first Vernaux measured FROM THE START
            // OF THIS Verneed record (per the System V gABI), not from the section
            // start. Re-base it to a section-relative offset so the second-and-later
            // records resolve their own auxiliary list instead of re-reading the
            // first record's. Overflow-safe.
            if let auxStart = Int(exactly: auxOffset),
               needRelativeOffset <= Int.max - auxStart {
                parseVersionAuxiliaryRecords(
                    reader: reader,
                    span: verneedSpan,
                    stringSpan: stringSpan,
                    startRelativeOffset: needRelativeOffset + auxStart,
                    count: versionCount,
                    libraryName: libraryName,
                    versionIndexNames: &versionIndexNames,
                    versionIndexLibraries: &versionIndexLibraries
                )
            }

            visitedNeedRecords += 1
            guard nextNeed != 0,
                  let advanced = advancedRelativeOffset(
                    from: needRelativeOffset,
                    by: nextNeed,
                    limit: verneedSpan.count,
                    recordSize: 16
                  ) else { break }
            needRelativeOffset = advanced
        }
    }

    var symbolVersionIndices = Array<UInt16?>(repeating: nil, count: dynSymbols.count)
    var symbolVersionNames = Array<String?>(repeating: nil, count: dynSymbols.count)
    guard let versym = sections.first(where: { $0.type == elfShtGNUVerSym }),
          let versymSpan = reader.range(versym.fileOffset, versym.size),
          versymSpan.count / 2 == dynSymbols.count else {
        return ELFVersionInfo(
            versionIndexNames: versionIndexNames,
            versionIndexLibraries: versionIndexLibraries,
            symbolVersionIndices: symbolVersionIndices,
            symbolVersionNames: symbolVersionNames
        )
    }

    for symbolIndex in 0..<dynSymbols.count {
        let entryOffset = versymSpan.lowerBound + symbolIndex * 2
        guard let rawVersion = try? reader.u16(entryOffset) else { continue }
        let versionIndex = rawVersion & elfVersionIndexMask
        guard versionIndex > 1 else { continue }
        symbolVersionIndices[symbolIndex] = versionIndex
        symbolVersionNames[symbolIndex] = versionIndexNames[versionIndex]
    }

    return ELFVersionInfo(
        versionIndexNames: versionIndexNames,
        versionIndexLibraries: versionIndexLibraries,
        symbolVersionIndices: symbolVersionIndices,
        symbolVersionNames: symbolVersionNames
    )
}

func resolvePLTStubs(
    reader: LittleEndianReader,
    sections: [ELFSectionInfo],
    dynSymbols: [ELFDynamicSymbol],
    versionInfo: ELFVersionInfo,
    is64: Bool,
    machine: UInt16
) -> [ELFPLTStub] {
    guard is64, let jumpSlotType = jumpSlotRelocationType(machine: machine) else { return [] }
    let pltSection = sections.first(where: { $0.name == ".plt.sec" })
        ?? sections.first(where: { $0.name == ".plt" })
    guard let pltSection else { return [] }

    let relocationSectionNames: Set<String> = [".rela.plt", ".rel.plt"]
    let pltRelocations = parseRelocations(reader: reader, sections: sections, is64: is64)
        .filter { relocationSectionNames.contains($0.sectionName) && $0.type == jumpSlotType }

    let stubSize: UInt64 = 16
    let hasResolverStub = pltSection.name != ".plt.sec"
    var stubs: [ELFPLTStub] = []
    stubs.reserveCapacity(pltRelocations.count)
    for relocation in pltRelocations {
        guard let symbolIndex = Int(exactly: relocation.symIndex),
              symbolIndex >= 0,
              symbolIndex < dynSymbols.count else { continue }
        let dynSymbol = dynSymbols[symbolIndex]
        let importName = versionInfo.decoratedName(dynSymbol.name, symbolIndex: symbolIndex)
        guard !importName.isEmpty else { continue }

        let tableIndex = stubs.count
        let pltSlotIndex = hasResolverStub ? tableIndex + 1 : tableIndex
        guard let pltSlotIndex64 = UInt64(exactly: pltSlotIndex),
              pltSlotIndex64 <= UInt64.max / stubSize else { continue }
        let stubOffset = pltSlotIndex64 * stubSize
        guard stubOffset <= pltSection.size,
              stubSize <= pltSection.size - stubOffset,
              pltSection.address <= UInt64.max - stubOffset,
              let tableIndex32 = UInt32(exactly: tableIndex) else { continue }

        stubs.append(ELFPLTStub(
            tableIndex: tableIndex32,
            stubVA: pltSection.address + stubOffset,
            gotSlotVA: relocation.offset,
            symbolIndex: relocation.symIndex,
            importName: importName,
            libraryName: versionInfo.libraryName(forSymbolIndex: symbolIndex),
            sourceSection: pltSection.name
        ))
    }
    return stubs
}

private func defaultRelocationEntrySize(is64: Bool, isRela: Bool) -> Int {
    switch (is64, isRela) {
    case (true, true): return 24
    case (true, false): return 16
    case (false, true): return 12
    case (false, false): return 8
    }
}

private func readRelocation(
    reader: LittleEndianReader,
    section: ELFSectionInfo,
    base: Int,
    is64: Bool,
    isRela: Bool
) -> ELFReloc? {
    if is64 {
        guard let offset = try? reader.u64(base),
              let info = try? reader.u64(base + 8) else { return nil }
        let addend: Int64?
        if isRela {
            guard let rawAddend = try? reader.u64(base + 16) else { return nil }
            addend = Int64(bitPattern: rawAddend)
        } else {
            addend = nil
        }
        return ELFReloc(
            sectionIndex: section.index,
            sectionName: section.name,
            offset: offset,
            symIndex: UInt32(info >> 32),
            type: UInt32(info & 0xffffffff),
            addend: addend,
            isRela: isRela
        )
    } else {
        guard let offset = try? reader.u32(base),
              let info = try? reader.u32(base + 4) else { return nil }
        let addend: Int64?
        if isRela {
            guard let rawAddend = try? reader.u32(base + 8) else { return nil }
            addend = Int64(Int32(bitPattern: rawAddend))
        } else {
            addend = nil
        }
        return ELFReloc(
            sectionIndex: section.index,
            sectionName: section.name,
            offset: UInt64(offset),
            symIndex: info >> 8,
            type: info & 0xff,
            addend: addend,
            isRela: isRela
        )
    }
}

private func readDynamicSymbol(
    reader: LittleEndianReader,
    stringSpan: Range<Int>,
    base: Int,
    index: Int,
    is64: Bool
) -> ELFDynamicSymbol? {
    let nameOffset: UInt32
    let info: UInt8
    let sectionIndex: UInt16
    let value: UInt64
    let size: UInt64
    if is64 {
        guard let n = try? reader.u32(base),
              let shndx = try? reader.u16(base + 6),
              let v = try? reader.u64(base + 8),
              let s = try? reader.u64(base + 16) else { return nil }
        nameOffset = n
        info = reader.byte(base + 4) ?? 0
        sectionIndex = shndx
        value = v
        size = s
    } else {
        guard let n = try? reader.u32(base),
              let v = try? reader.u32(base + 4),
              let s = try? reader.u32(base + 8),
              let shndx = try? reader.u16(base + 14) else { return nil }
        nameOffset = n
        info = reader.byte(base + 12) ?? 0
        sectionIndex = shndx
        value = UInt64(v)
        size = UInt64(s)
    }

    return ELFDynamicSymbol(
        index: index,
        name: string(in: stringSpan, offset: nameOffset, reader: reader),
        info: info,
        sectionIndex: sectionIndex,
        value: value,
        size: size
    )
}

private func parseVersionAuxiliaryRecords(
    reader: LittleEndianReader,
    span: Range<Int>,
    stringSpan: Range<Int>,
    startRelativeOffset: Int,
    count: UInt16,
    libraryName: String,
    versionIndexNames: inout [UInt16: String],
    versionIndexLibraries: inout [UInt16: String]
) {
    guard startRelativeOffset >= 0,
          startRelativeOffset + 16 <= span.count else { return }
    var auxRelativeOffset = startRelativeOffset
    var visitedAuxRecords = 0
    let maximumAuxRecords = min(max(1, span.count / 16), Int(count))
    while auxRelativeOffset + 16 <= span.count && visitedAuxRecords < maximumAuxRecords {
        let auxBase = span.lowerBound + auxRelativeOffset
        guard let rawOther = try? reader.u16(auxBase + 6),
              let nameOffset = try? reader.u32(auxBase + 8),
              let nextAux = try? reader.u32(auxBase + 12) else { break }

        let versionIndex = rawOther & 0x7fff
        let versionName = string(in: stringSpan, offset: nameOffset, reader: reader)
        if versionIndex > 1, !versionName.isEmpty {
            versionIndexNames[versionIndex] = versionName
            if !libraryName.isEmpty {
                versionIndexLibraries[versionIndex] = libraryName
            }
        }

        visitedAuxRecords += 1
        guard nextAux != 0,
              let advanced = advancedRelativeOffset(
                from: auxRelativeOffset,
                by: nextAux,
                limit: span.count,
                recordSize: 16
              ) else { break }
        auxRelativeOffset = advanced
    }
}

private func versionDefinitionName(
    reader: LittleEndianReader,
    span: Range<Int>,
    stringSpan: Range<Int>,
    startRelativeOffset: Int,
    count: UInt16
) -> String? {
    guard count > 0,
          startRelativeOffset >= 0,
          startRelativeOffset + 8 <= span.count else { return nil }
    let auxBase = span.lowerBound + startRelativeOffset
    guard let nameOffset = try? reader.u32(auxBase) else { return nil }
    return string(in: stringSpan, offset: nameOffset, reader: reader)
}

private func advancedRelativeOffset(from current: Int, by byteDistance: UInt32, limit: Int, recordSize: Int) -> Int? {
    guard let distance = Int(exactly: byteDistance),
          distance > 0,
          current <= Int.max - distance else { return nil }
    let next = current + distance
    guard next > current, next + recordSize <= limit else { return nil }
    return next
}

private func string(in span: Range<Int>, offset: UInt32, reader: LittleEndianReader) -> String {
    guard let relativeOffset = Int(exactly: offset),
          relativeOffset >= 0,
          relativeOffset < span.count else { return "" }
    return reader.cString(fileOffset: span.lowerBound + relativeOffset, limit: span.upperBound)
}

private func jumpSlotRelocationType(machine: UInt16) -> UInt32? {
    switch machine {
    case elfMachineX86_64:
        return elfRelocX86_64JumpSlot
    case elfMachineAArch64:
        return elfRelocAArch64JumpSlot
    default:
        return nil
    }
}
