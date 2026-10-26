import Foundation

/// Image-wide negative authority for caller-discard evidence. References are deliberately
/// over-approximated from bytes, independently of discovery and xref producers. An incomplete
/// scan never permits a function to be treated as having only its observed direct callers.
struct FunctionAddressTakenIndex {
    let isComplete: Bool
    let addresses: Set<UInt64>
    /// Raw BL target -> source PCs, including instructions outside discovered function bodies.
    let directCalls: [UInt64: Set<UInt64>]

    func contains(_ address: UInt64) -> Bool {
        !isComplete || addresses.contains(address)
    }

    init(image: MachOFile, bytes: Data, functions: [FunctionSummary]) {
        let starts = Set(functions.map(\.startAddress))
        let sortedFunctions = functions.sorted { $0.startAddress < $1.startAddress }
        var complete = image.header.cpuType == MachOConstants.cpuTypeARM64
            && image.header.fileType != MachOConstants.fileTypeObject
            && !image.encryptionInfos.contains(where: \.isActive)
            && image.relocations.isEmpty
            && image.sections.allSatisfy { $0.relocationCount == 0 }
        // The loader retains one command of each kind. Duplicate declarations could
        // otherwise hide an earlier export table or pointer chain behind the last one.
        let singleCommands: Set<UInt32> = [MachOConstants.loadCommandSymtab,
            MachOConstants.loadCommandDysymtab, MachOConstants.loadCommandDyldExportsTrie,
            MachOConstants.loadCommandDyldChainedFixups]
        var seenCommands = Set<UInt32>()
        for command in image.loadCommands {
            let kind = command.command == MachOConstants.loadCommandDyldInfoOnly
                ? MachOConstants.loadCommandDyldInfo : command.command
            if singleCommands.contains(kind) || kind == MachOConstants.loadCommandDyldInfo {
                if !seenCommands.insert(kind).inserted { complete = false }
            }
        }
        var found = Set<UInt64>()
        var calls: [UInt64: Set<UInt64>] = [:]
        let preferredBase = image.segments.first(where: { $0.name == "__TEXT" })?.vmAddress
            ?? image.segments.filter { $0.fileSize > 0 }.map(\.vmAddress).min() ?? 0
        var offsets64: [UInt64: Set<UInt64>] = [:]
        var offsets32: [UInt32: Set<UInt64>] = [:]
        for start in starts where start >= preferredBase {
            let offset = start - preferredBase
            offsets64[offset, default: []].insert(start)
            offsets32[UInt32(truncatingIfNeeded: offset), default: []].insert(start)
        }
        // A malformed or overlapping body cannot delimit the same-function pairing rule.
        // Unknown code is handled separately below and does not depend on discovery coverage.
        for (index, function) in sortedFunctions.enumerated() {
            if function.endAddress <= function.startAddress { complete = false }
            if index > 0, sortedFunctions[index - 1].endAddress > function.startAddress {
                complete = false
            }
        }
        let bodies = Dictionary(grouping: functions, by: \.startAddress)
        var pairs: [UInt64: PageOffsets] = [:]
        var allPages = Set<UInt64>()
        var allOffsets = Set<UInt16>()
        var unknown = PageOffsets()

        func body(at pc: UInt64) -> UInt64? {
            var lower = 0
            var upper = sortedFunctions.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if sortedFunctions[middle].startAddress <= pc { lower = middle + 1 }
                else { upper = middle }
            }
            guard lower > 0, pc < sortedFunctions[lower - 1].endAddress else { return nil }
            return sortedFunctions[lower - 1].startAddress
        }
        func retain(_ target: UInt64?) {
            if let target, starts.contains(target) { found.insert(target) }
        }
        func retainBranch(_ target: UInt64?, from pc: UInt64) {
            guard let target, starts.contains(target) else { return }
            if !(bodies[target] ?? []).contains(where: { $0.startAddress <= pc && pc < $0.endAddress }) {
                found.insert(target)
            }
        }
        func recordPage(_ page: UInt64, at pc: UInt64) {
            allPages.insert(page)
            if let owner = body(at: pc) { pairs[owner, default: PageOffsets()].pages.insert(page) }
            else { unknown.pages.insert(page) }
        }
        func recordOffset(_ offset: UInt16, at pc: UInt64) {
            allOffsets.insert(offset)
            if let owner = body(at: pc) { pairs[owner, default: PageOffsets()].offsets.insert(offset) }
            else { unknown.offsets.insert(offset) }
        }

        // The existing loader decodes chained targets. Validate its enclosing declarations too:
        // malformed starts tables and the global fixup cap otherwise have silent empty returns.
        if let chained = image.dyldChainedFixups {
            complete = complete && Self.chainsAreComplete(chained, image: image, bytes: bytes)
            for fixup in chained.fixups { retain(fixup.rebaseTargetAddress) }
        }
        for command in image.loadCommands {
            if command.command == MachOConstants.loadCommandDyldChainedFixups,
               image.dyldChainedFixups == nil { complete = false }
            if command.command == MachOConstants.loadCommandDyldInfo
                || command.command == MachOConstants.loadCommandDyldInfoOnly {
                // Legacy rebase opcodes are not decoded by the retained loader facts. Raw
                // pointers alone cannot certify every relocation encoding, so refuse absence.
                guard command.commandSize >= 48,
                      let rebaseSize = Self.word32(bytes, command.offset + 12) else {
                    complete = false
                    continue
                }
                if rebaseSize != 0 { complete = false }
            }
            if command.command == MachOConstants.loadCommandDysymtab {
                guard command.commandSize >= 80,
                      let externalCount = Self.word32(bytes, command.offset + 68),
                      let localCount = Self.word32(bytes, command.offset + 76) else {
                    complete = false
                    continue
                }
                if externalCount != 0 || localCount != 0 { complete = false }
            }
        }
        if image.segments.reduce(UInt64(0), { $0 + UInt64($1.sectionCount) }) != UInt64(image.sections.count) {
            complete = false
        }
        for section in image.sections {
            let (end, addressOverflow) = section.address.addingReportingOverflow(section.size)
            guard !addressOverflow else { complete = false; continue }
            // Zero-fill bytes have a complete, implicit all-zero representation. A zero
            // offset can itself point to a function at the preferred base.
            if section.isZeroFill {
                if section.size >= 4 {
                    found.formUnion(offsets32[0] ?? [])
                    for start in starts where start & 3 == 0 && start >= section.address && start <= end - 4 {
                        found.insert(start) // A zero relative displacement refers to its own slot.
                    }
                }
                if section.size >= 8 { retain(0); found.formUnion(offsets64[0] ?? []) }
                continue
            }
            let fileStart = UInt64(section.fileOffset)
            guard fileStart <= UInt64(bytes.count), section.size <= UInt64(bytes.count) - fileStart else {
                complete = false
                continue
            }
            let executable = section.isExecutableInstructions || image.segments.contains {
                $0.name == section.segmentName && $0.initialProtection & 4 != 0
            }
            let padding = (4 - section.address % 4) % 4
            guard padding <= section.size else { continue }
            var position = padding
            while section.size - position >= 4 {
                let pc = section.address + position
                let fileOffset = fileStart + position
                guard let word = Self.word32(bytes, fileOffset) else { complete = false; break }
                // Apply data rules even to valid instructions: this includes every literal
                // pool/undecodable word without making absence depend on a decoder's coverage.
                retain(Self.add(pc, Int64(Int32(bitPattern: word))))
                found.formUnion(offsets32[word] ?? [])
                if pc & 7 == 0, section.size - position >= 8,
                   let wide = Self.word64(bytes, fileOffset) {
                    retain(wide)
                    found.formUnion(offsets64[wide] ?? [])
                }
                if executable {
                    if word & 0x9f00_0000 == 0x1000_0000 { // ADR
                        let immediate = ((word >> 5) & 0x7ffff) << 2 | ((word >> 29) & 3)
                        retain(Self.add(pc, Self.signed(immediate, bits: 21)))
                    } else if word & 0x9f00_0000 == 0x9000_0000 { // ADRP
                        let immediate = ((word >> 5) & 0x7ffff) << 2 | ((word >> 29) & 3)
                        if let page = Self.add(pc & ~0xfff, Self.signed(immediate, bits: 21) * 4096) {
                            recordPage(page, at: pc)
                        }
                    }
                    if word & 0x5f00_0000 == 0x1100_0000 { // ADD/ADDS immediate, both widths
                        let shift: UInt32 = word & (1 << 22) == 0 ? 0 : 12
                        recordOffset(UInt16((((word >> 10) & 0xfff) << shift) & 0xfff), at: pc)
                    }
                    if word & 0x3b00_0000 == 0x3900_0000 { // LDR/STR unsigned immediate
                        // Include every architectural element scale (including SIMD Q). Extra
                        // low bits are harmless; no register/type reconstruction is required.
                        for scale in 0...4 {
                            recordOffset(UInt16((((word >> 10) & 0xfff) << scale) & 0xfff), at: pc)
                        }
                    } else if word & 0x3b20_0000 == 0x3800_0000 { // LDUR/STUR and indexed forms
                        let displacement = Self.signed((word >> 12) & 0x1ff, bits: 9)
                        recordOffset(UInt16(truncatingIfNeeded: displacement) & 0xfff, at: pc)
                    } else if word & 0x3b00_0000 == 0x1800_0000 { // LDR literal
                        let target = Self.add(pc, Self.signed((word >> 5) & 0x7ffff, bits: 19) * 4)
                        retain(target)
                        if let target { recordOffset(UInt16(target & 0xfff), at: pc) }
                    }
                    if word & 0xfc00_0000 == 0x9400_0000 { // BL is caller evidence, not address-taken
                        if let target = Self.add(pc, Self.signed(word & 0x03ff_ffff, bits: 26) * 4),
                           starts.contains(target) { calls[target, default: []].insert(pc) }
                    } else if word & 0xfc00_0000 == 0x1400_0000 { // B, including tail calls
                        retainBranch(Self.add(pc, Self.signed(word & 0x03ff_ffff, bits: 26) * 4), from: pc)
                    } else if word & 0xff00_0000 == 0x5400_0000
                        || word & 0x7e00_0000 == 0x3400_0000 { // B.cond, CBZ/CBNZ
                        retainBranch(Self.add(pc, Self.signed((word >> 5) & 0x7ffff, bits: 19) * 4), from: pc)
                    } else if word & 0x7e00_0000 == 0x3600_0000 { // TBZ/TBNZ
                        retainBranch(Self.add(pc, Self.signed((word >> 5) & 0x3fff, bits: 14) * 4), from: pc)
                    }
                }
                position += 4
            }
        }
        var offsetsByPage: [UInt64: Set<UInt16>] = [:]
        for pair in pairs.values {
            for page in pair.pages { offsetsByPage[page, default: []].formUnion(pair.offsets) }
        }
        // Missing function boundaries broaden possible pairs rather than omitting evidence.
        for page in unknown.pages { offsetsByPage[page, default: []].formUnion(allOffsets) }
        for page in allPages { offsetsByPage[page, default: []].formUnion(unknown.offsets) }
        for start in starts {
            if offsetsByPage[start & ~0xfff]?.contains(UInt16(start & 0xfff)) == true {
                found.insert(start)
            }
        }
        isComplete = complete
        addresses = complete ? found : starts
        directCalls = calls
    }

    private struct PageOffsets {
        var pages = Set<UInt64>()
        var offsets = Set<UInt16>()
    }

    private static func signed(_ value: UInt32, bits: Int) -> Int64 {
        Int64(Int32(bitPattern: value << (32 - bits)) >> (32 - bits))
    }

    private static func add(_ address: UInt64, _ displacement: Int64) -> UInt64? {
        if displacement >= 0 {
            let (result, overflow) = address.addingReportingOverflow(UInt64(displacement))
            return overflow ? nil : result
        }
        let magnitude = UInt64(-displacement)
        return address >= magnitude ? address - magnitude : nil
    }

    private static func word32(_ bytes: Data, _ offset: UInt64) -> UInt32? {
        guard offset <= UInt64(bytes.count), UInt64(bytes.count) - offset >= 4 else { return nil }
        let index = bytes.startIndex + Int(offset)
        return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }

    private static func word64(_ bytes: Data, _ offset: UInt64) -> UInt64? {
        guard let low = word32(bytes, offset), let high = word32(bytes, offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }

    private static func chainsAreComplete(_ chained: MachODyldChainedFixups, image: MachOFile, bytes: Data) -> Bool {
        guard chained.fixupsVersion == 0, chained.diagnostics.isEmpty,
              chained.fixups.count < MachOConstants.dyldChainedMaxFixups,
              chained.endOffset <= UInt64(bytes.count) else { return false }
        let starts = chained.startsFileOffset
        guard starts >= UInt64(chained.dataOffset), starts <= chained.endOffset,
              chained.endOffset - starts >= 4,
              let count = word32(bytes, starts), Int(count) <= image.segments.count,
              UInt64(count) <= (chained.endOffset - starts - 4) / 4 else { return false }
        for index in 0..<Int(count) {
            guard let relative = word32(bytes, starts + 4 + UInt64(index) * 4) else { return false }
            if relative == 0 { continue }
            // walkPageChain can silently stop before emitting a diagnostic when its
            // segment offset does not fit Int. Require the entire captured file range.
            let segment = image.segments[index]
            guard segment.fileOffset <= UInt64(bytes.count),
                  segment.fileSize <= UInt64(bytes.count) - segment.fileOffset else { return false }
            let segmentStart = starts + UInt64(relative)
            guard segmentStart <= chained.endOffset, chained.endOffset - segmentStart >= 24,
                  let size = word32(bytes, segmentStart), size >= 24,
                  UInt64(size) <= chained.endOffset - segmentStart,
                  let sizeAndFormat = word32(bytes, segmentStart + 4), sizeAndFormat & 0xffff != 0,
                  let countAndFirst = word32(bytes, segmentStart + 20),
                  UInt64(countAndFirst & 0xffff) * 2 <= UInt64(size) - 22 else { return false }
        }
        return true
    }
}
