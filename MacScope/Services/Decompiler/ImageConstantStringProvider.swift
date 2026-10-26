import Foundation

/// HOP-5c: the once-per-image constant-string map the decompiler resolves format strings from
/// (address → `MacIRConstantString`).
///
/// Two sources feed it:
/// - recovered C-string literals (`__TEXT,__cstring` and the other C-string sections the loader
///   reads), keyed by the literal's own address, kind `.cString`;
/// - constant `CFString`/`NSConstantString` objects from `__DATA*,__cfstring`, keyed by the
///   OBJECT's address (what `adrp`+`add` materializes for `@"..."`), kind `.cfString`.
///
/// The map is built once when an image is analysed (fresh analysis, rehydrate, or a worker reply
/// decode) and stored on `ImageAnalysis.constantStrings`; every renderer reads that stored map
/// through `WorkspaceSnapshot.constantStrings(in:)` / `PseudocodeRenderInput.constantStrings`
/// and never rebuilds it per render.
enum ImageConstantStringProvider {
    /// Upper bound on one constant CFString's content (bytes for 8-bit, UTF-16 code units for
    /// UTF-16). Larger declared lengths are treated as malformed and skipped.
    static let maximumCFStringLength = 1 << 16
    /// Upper bound on CFString objects read from one image.
    static let maximumCFStringCount = 1 << 20

    /// `__CFConstantStringClassReference` info word: bit 4 marks UTF-16 contents
    /// (clang emits 0x7C8 for 8-bit and 0x7D0 for UTF-16 literals).
    static let cfStringUnicodeFlag: UInt64 = 0x10

    /// Aggregate decoded content budget, independent of malformed records and section sizes.
    static let maximumCFStringBytes = 64 * 1_024 * 1_024

    struct PersistedCFString: Codable, Equatable {
        let address: UInt64
        let text: String
    }

    enum PersistenceError: Error { case invalidConstantStrings }

    static func persistedCFStrings(in map: [UInt64: MacIRConstantString]) -> [PersistedCFString] {
        map.compactMap { address, value in
            value.kind == .cfString ? PersistedCFString(address: address, text: value.text) : nil
        }.sorted { $0.address < $1.address }
    }

    static func validated(_ entries: [PersistedCFString]) throws -> [PersistedCFString] {
        guard entries.count <= maximumCFStringCount else { throw PersistenceError.invalidConstantStrings }
        var seen: Set<UInt64> = []
        var bytes = 0
        for entry in entries {
            guard seen.insert(entry.address).inserted,
                  entry.text.utf16.count <= maximumCFStringLength,
                  entry.text.utf8.count <= maximumCFStringBytes - bytes else {
                throw PersistenceError.invalidConstantStrings
            }
            bytes += entry.text.utf8.count
        }
        return entries.sorted { $0.address < $1.address }
    }

    // MARK: - Map

    /// Builds the decompiler map from the image's C-string literals and its CFString objects.
    /// Objective-C metadata strings (selector, class and type names) are never format arguments
    /// and are left out. A CFString wins over a C string at the same address (they cannot
    /// legitimately overlap; the object is the more specific fact).
    static func build(
        stringLiterals: [StringLiteralSummary],
        cfStrings: [UInt64: String]
    ) -> [UInt64: MacIRConstantString] {
        var strings: [UInt64: MacIRConstantString] = [:]
        strings.reserveCapacity(stringLiterals.count + cfStrings.count)
        for literal in stringLiterals where !literal.sourceSection.contains("__objc_") {
            strings[literal.address] = MacIRConstantString(text: literal.value, kind: .cString)
        }
        for (address, text) in cfStrings {
            strings[address] = MacIRConstantString(text: text, kind: .cfString)
        }
        return strings
    }

    /// The CFString subset of a built map (the only part not derivable from `stringLiterals`);
    /// this is what crosses the analysis-worker boundary.
    static func cfStrings(in map: [UInt64: MacIRConstantString]) -> [UInt64: String] {
        var result: [UInt64: String] = [:]
        for (address, constant) in map where constant.kind == .cfString {
            result[address] = constant.text
        }
        return result
    }

    // MARK: - __cfstring

    /// Reads every constant CFString object in the image's `__cfstring` sections.
    ///
    /// Layout (pointer size `p`): `isa` (p), `flags` (4, padded to p), `data` (p), `length` (p).
    /// The data pointer is resolved through the chained-fixup REBASE map when the image uses
    /// `LC_DYLD_CHAINED_FIXUPS` (a slot the walker did not cover, or a BIND, is skipped: the raw
    /// word is a chain entry, not an address); without chained fixups the raw word is the
    /// unslid VM address. 8-bit contents must decode as UTF-8; UTF-16 contents (flag 0x10) are
    /// decoded little-endian. Anything malformed is skipped, never guessed.
    static func cfStrings(in machO: MachOFile, bytes: Data, sliceOffset: UInt64) -> [UInt64: String] {
        let sections = machO.sections.filter { $0.sectionName == "__cfstring" && !$0.isZeroFill && $0.size > 0 }
        guard !sections.isEmpty else { return [:] }
        let pointerSize = machO.header.magic == MachOConstants.machMagic64 ? 8 : 4
        var rebaseTargets: [UInt64: UInt64]?
        if let fixups = machO.dyldChainedFixups {
            var targets: [UInt64: UInt64] = [:]
            for fixup in fixups.fixups {
                guard let target = fixup.rebaseTargetAddress,
                      sections.contains(where: { fixup.address >= $0.address && fixup.address - $0.address < $0.size })
                else { continue }
                targets[fixup.address] = target
            }
            rebaseTargets = targets
        }
        let image = ImageReader(sections: machO.sections, bytes: bytes, sliceOffset: sliceOffset)
        return cfStrings(
            sections: sections.map { ($0.address, $0.size) },
            pointerSize: pointerSize,
            rebaseTargets: rebaseTargets,
            read: image.read
        )
    }

    /// Cache CFString objects retain their own VM addresses even when the cache builder moves
    /// their bytes/content into shared regions. Read those addresses from admitted mappings,
    /// never the projected file offsets. Only explicitly declared slide-v5 mappings are decoded;
    /// older/unknown encodings are unavailable, not guessed from plausible-looking pointer bits.
    static func cfStrings(in machO: MachOFile, cache: MultiFileCacheReader) -> [UInt64: String] {
        let regions = cache.files.flatMap { cachePointerRegions(in: $0) }
        var slotsByPage: [UInt64: Set<UInt64>] = [:]
        var remainingRebases = maximumCFStringCount
        return cfStrings(
            sections: machO.sections.filter { $0.sectionName == "__cfstring" && !$0.isZeroFill }
                .map { ($0.address, $0.size) },
            pointerSize: 8,
            rebaseTargets: nil,
            resolvePointer: { slot, raw in
                guard raw != 0, let region = regions.first(where: {
                    slot >= $0.address && slot - $0.address < $0.size
                }) else { return nil }
                let pageIndex = (slot - region.address) / region.pageSize
                let pageAddress = region.address + pageIndex * region.pageSize
                if slotsByPage[pageAddress] == nil {
                    slotsByPage[pageAddress] = cacheRebaseSlots(
                        pageIndex: pageIndex, region: region, cache: cache,
                        remaining: &remainingRebases
                    )
                }
                guard slotsByPage[pageAddress]?.contains(slot) == true else { return nil }
                // dyld_cache_slide_info5 / dyld_chained_ptr_arm64e_shared_cache_*:
                // both authenticated and ordinary pointers have a low-34-bit runtime offset.
                // Nonzero high8 on an ordinary pointer denotes a tagged value, not CF contents.
                guard raw >> 63 != 0 || (raw >> 34) & 0xFF == 0 else { return nil }
                let target = region.valueAdd.addingReportingOverflow(raw & 0x3_FFFF_FFFF)
                return target.overflow ? nil : target.partialValue
            },
            read: { address, count in cache.readBytes(at: address, length: UInt64(count)) }
        )
    }

    private struct CachePointerRegion {
        let address: UInt64
        let size: UInt64
        let valueAdd: UInt64
        let pageSize: UInt64
        let fileBytes: Data
        let pageStartsOffset: Int
        let pageCount: UInt64
    }

    /// Walk only a requested CFString page, once. A malformed link invalidates the whole page;
    /// merely lying inside a v5 mapping never establishes that a word is a rebase. The starting
    /// offset is bytes; each `next` is an eight-byte stride (Apple DyldSharedCache::fixupDataPages).
    private static func cacheRebaseSlots(
        pageIndex: UInt64, region: CachePointerRegion, cache: MultiFileCacheReader,
        remaining: inout Int
    ) -> Set<UInt64> {
        guard pageIndex < region.pageCount,
              let first = try? LittleEndianReader(region.fileBytes).u16(region.pageStartsOffset + Int(pageIndex) * 2),
              first != 0xFFFF, first % 8 == 0 else { return [] }
        let pageDelta = pageIndex * region.pageSize
        let pageAddress = region.address + pageDelta
        let length = min(region.pageSize, region.size - pageDelta)
        guard let page = cache.readBytes(at: pageAddress, length: length) else { return [] }
        let reader = LittleEndianReader(page)
        var offset = Int(first)
        var slots: Set<UInt64> = []
        while remaining > 0 {
            remaining -= 1
            guard let word = try? reader.u64(offset) else { return [] }
            slots.insert(pageAddress + UInt64(offset))
            let next = Int((word >> 52) & 0x7FF) * 8
            if next == 0 { return slots }
            offset += next // at most 16 KiB + a 14-bit delta, then the next bounded read rejects it
        }
        return []
    }

    private static func cachePointerRegions(in file: MultiFileCacheReader.CacheFile) -> [CachePointerRegion] {
        let reader = LittleEndianReader(file.bytes)
        guard let headerSize = try? reader.u32(16), headerSize >= 0x140,
              let table = try? reader.u32(0x138), let count = try? reader.u32(0x13C),
              count <= 4096, reader.range(UInt64(table), UInt64(count) * 56) != nil else { return [] }
        var result: [CachePointerRegion] = []
        for index in 0..<Int(count) {
            let record = Int(table) + index * 56
            guard let address = try? reader.u64(record), let size = try? reader.u64(record + 8),
                  let fileOffset = try? reader.u64(record + 16),
                  file.mappings.contains(where: { $0.address == address && $0.size == size && $0.fileOffset == fileOffset }),
                  let slideOffset = try? reader.u64(record + 24),
                  let slideSize = try? reader.u64(record + 32), slideSize >= 24,
                  let slideRange = reader.range(slideOffset, slideSize),
                  (try? reader.u32(slideRange.lowerBound)) == 5,
                  let valueAdd = try? reader.u64(slideRange.lowerBound + 16),
                  let pageSize = try? reader.u32(slideRange.lowerBound + 4),
                  pageSize == 4096 || pageSize == 16384,
                  let pageCount = try? reader.u32(slideRange.lowerBound + 8), pageCount > 0,
                  UInt64(pageCount) <= size / UInt64(pageSize) + (size % UInt64(pageSize) == 0 ? 0 : 1),
                  UInt64(pageCount) * 2 <= slideSize - 24,
                  !address.addingReportingOverflow(size).overflow else { continue }
            result.append(CachePointerRegion(
                address: address, size: size, valueAdd: valueAdd, pageSize: UInt64(pageSize),
                fileBytes: file.bytes, pageStartsOffset: slideRange.lowerBound + 24, pageCount: UInt64(pageCount)
            ))
        }
        return result
    }

    /// Core walk, independent of the Mach-O container so tests can drive the fixup/raw-pointer
    /// decision directly. `rebaseTargets == nil` means the image has no chained fixups.
    static func cfStrings(
        sections: [(address: UInt64, size: UInt64)],
        pointerSize: Int,
        rebaseTargets: [UInt64: UInt64]?,
        resolvePointer: ((UInt64, UInt64) -> UInt64?)? = nil,
        read: (UInt64, Int) -> Data?
    ) -> [UInt64: String] {
        guard pointerSize == 8 || pointerSize == 4 else { return [:] }
        let stride = UInt64(pointerSize * 4)
        var result: [UInt64: String] = [:]
        var visited = 0
        var contentBytes = 0
        for section in sections {
            guard !section.address.addingReportingOverflow(section.size).overflow else { continue }
            var offset: UInt64 = 0
            while offset + stride <= section.size, visited < maximumCFStringCount {
                visited += 1
                defer { offset += stride }
                let object = section.address &+ offset
                guard let record = read(object, Int(stride)), record.count == Int(stride) else { break }
                let flags = word(record, at: pointerSize, size: pointerSize)
                let dataSlot = object &+ UInt64(2 * pointerSize)
                let dataPointer: UInt64
                if let resolvePointer {
                    guard let target = resolvePointer(dataSlot, word(record, at: 2 * pointerSize, size: pointerSize)) else { continue }
                    dataPointer = target
                } else if let rebaseTargets {
                    guard let target = rebaseTargets[dataSlot] else { continue }
                    dataPointer = target
                } else {
                    dataPointer = word(record, at: 2 * pointerSize, size: pointerSize)
                }
                let length = word(record, at: 3 * pointerSize, size: pointerSize)
                guard dataPointer != 0, length <= UInt64(maximumCFStringLength) else { continue }
                let isUTF16 = flags & cfStringUnicodeFlag != 0
                let byteCount = Int(length) * (isUTF16 ? 2 : 1)
                guard byteCount <= maximumCFStringBytes - contentBytes else { return result }
                let text: String?
                if byteCount == 0 {
                    text = ""
                } else if let contents = read(dataPointer, byteCount), contents.count == byteCount {
                    text = isUTF16 ? decodeUTF16LE(contents) : String(data: contents, encoding: .utf8)
                } else {
                    text = nil
                }
                if let text {
                    guard text.utf8.count <= maximumCFStringBytes - contentBytes else { return result }
                    contentBytes += text.utf8.count
                    result[object] = text
                }
            }
        }
        return result
    }

    private static func word(_ data: Data, at offset: Int, size: Int) -> UInt64 {
        var value: UInt64 = 0
        let base = data.startIndex + offset
        for index in 0..<size {
            value |= UInt64(data[base + index]) << (8 * UInt64(index))
        }
        return value
    }

    private static func decodeUTF16LE(_ data: Data) -> String? {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            units.append(UInt16(data[index]) | UInt16(data[index + 1]) << 8)
            index += 2
        }
        var text = ""
        var iterator = units.makeIterator()
        var decoder = UTF16()
        loop: while true {
            switch decoder.decode(&iterator) {
            case let .scalarValue(scalar): text.unicodeScalars.append(scalar)
            case .emptyInput: break loop
            case .error: return nil
            }
        }
        return text
    }

    /// VM-address reads over the selected slice's file-backed sections.
    private struct ImageReader {
        let sections: [MachOSection]
        let bytes: Data
        let sliceOffset: UInt64

        func read(_ address: UInt64, _ count: Int) -> Data? {
            guard count >= 0 else { return nil }
            for section in sections where !section.isZeroFill
                && address >= section.address && address - section.address < section.size {
                let delta = address - section.address
                guard delta + UInt64(count) <= section.size else { return nil }
                let (start, overflow) = sliceOffset.addingReportingOverflow(UInt64(section.fileOffset) + delta)
                guard !overflow, start <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - start else {
                    return nil
                }
                let lower = bytes.startIndex + Int(start)
                return bytes.subdata(in: lower ..< lower + count)
            }
            return nil
        }
    }
}
