import Foundation

/// One `dyld_subcache_entry` record parsed from the main cache header's sub-cache array.
///
/// Modern (macOS 12+) dyld shared caches are SPLIT across sibling files: a main file
/// (`dyld_shared_cache_arm64e`) plus numbered/data/linkedit sub-caches. The separate
/// `symbolFileUUID` companion contains unmapped local symbols and is not a mapped sibling. The main header carries a `dyld_subcache_entry` array describing
/// each sibling: its UUID, the VM offset its mappings begin at (`cacheVMOffset`, relative
/// to the main cache base), and — on the v2 layout — the on-disk file suffix to append to
/// the main path to find that sibling.
///
/// Header capability selects one of two on-disk layouts:
///   v1 (`dyld_subcache_entry_v1`, 24 bytes): uuid[16] + cacheVMOffset(u64)
///   v2 (`dyld_subcache_entry`,    56 bytes): uuid[16] + cacheVMOffset(u64) + fileSuffix[32]
struct DyldSubCacheEntry: Equatable, Sendable {
    var uuid: [UInt8]        // 16-byte UUID of the sibling sub-cache
    var cacheVMOffset: UInt64 // VM offset (from the main cache base) of this sub-cache
    var fileSuffix: String   // normalized on-disk suffix, including numbered v1 entries
}

/// Maps a cache VM address to the `(file, file offset)` that backs it, across the main
/// cache AND every loaded sibling sub-cache. This is the heart of sub-cache stitching:
/// an image's bytes (and especially the shared `__LINKEDIT` symbol/string tables) often
/// live in a sibling file, so a single-file mapping lookup degrades to `.subCacheOnly`.
/// With every sibling's mappings registered, a cross-file VM address resolves to the right
/// file's bytes.
///
/// HARDENING: each registered file's mappings were already range-validated against THAT
/// file's length when parsed, so a resolved `(file, offset, size)` is guaranteed in-range
/// for the returned file. The resolver never traps: an unmapped address returns nil and
/// the caller degrades to a typed error.
struct MultiFileCacheReader: Sendable {
    /// One registered cache file: its bytes plus its own (already validated) mappings.
    struct CacheFile: Sendable {
        var suffix: String                 // "" for the main cache, e.g. ".symbols" for a sibling
        var bytes: Data
        var mappings: [DyldCacheMapping]
    }

    /// The main cache is always first; siblings follow in array order.
    let files: [CacheFile]
    let validationError: DyldSharedCacheError?

    init(files: [CacheFile], admissionError: DyldSharedCacheError? = nil) {
        self.files = files
        self.validationError = admissionError ?? Self.mappingError(files.flatMap(\.mappings))
    }

    static func mappingError(_ mappings: [DyldCacheMapping]) -> DyldSharedCacheError? {
        let ordered = mappings.filter { $0.size > 0 }.sorted { $0.address < $1.address }
        var previousEnd: UInt64?
        for mapping in ordered {
            let (end, overflow) = mapping.address.addingReportingOverflow(mapping.size)
            if overflow { return .malformed("mapping VM range overflows") }
            if let previousEnd, mapping.address < previousEnd {
                return .overlappingMappings(mapping.address)
            }
            previousEnd = end
        }
        return nil
    }

    func validate() throws {
        if let validationError { throw validationError }
    }

    /// Resolves a cache VM address to the file that backs it and the byte offset within
    /// that file. Walks every registered file's mappings (main first, then siblings) and
    /// returns its unique containing mapping's `(file, fileOffset)`. nil when no file maps
    /// the address or registration found an identity/mapping conflict.
    func resolve(_ cacheAddress: UInt64) -> (file: CacheFile, fileOffset: UInt64)? {
        guard validationError == nil else { return nil }
        for file in files {
            if let offset = DyldSharedCacheParser.fileOffset(for: cacheAddress, mappings: file.mappings) {
                return (file, offset)
            }
        }
        return nil
    }

    /// Reads `length` bytes of the file backing `cacheAddress`, spanning ONLY within the
    /// single mapping/file that contains the start address (a cache mapping is contiguous
    /// in both VM and file space, so a run that starts in one mapping and stays within its
    /// VM span stays contiguous in that file). Returns nil if the address is unmapped or
    /// the run would exceed the containing mapping or file — never traps, never reads cross-file in
    /// one call.
    func readBytes(at cacheAddress: UInt64, length: UInt64) -> Data? {
        guard length > 0 else { return Data() }
        guard validationError == nil else { return nil }
        for file in files {
            for mapping in file.mappings where mapping.contains(cacheAddress) {
                let delta = cacheAddress - mapping.address
                guard length <= mapping.size - delta else { return nil }
                let (fileStart, overflow) = mapping.fileOffset.addingReportingOverflow(delta)
                guard !overflow,
                      let range = LittleEndianReader(file.bytes).range(fileStart, length) else { return nil }
                let base = file.bytes.startIndex
                return file.bytes.subdata(in: base + range.lowerBound ..< base + range.upperBound)
            }
        }
        return nil
    }

    /// Reads UP TO `maxLength` bytes at `cacheAddress`, CLAMPED to the end of the CONTAINING MAPPING
    /// (returns however many are available rather than nil). For variable-length reads where the
    /// exact length is unknown — e.g. a C-string in the shared `__OBJC_RO` whose terminator position
    /// is not known up front. Clamping to the mapping (not merely the file) honors the documented
    /// "never reads cross-mapping" invariant: a string near a mapping edge must not spill into the
    /// unmapped file tail / adjacent region and yield a wrong/overlong name. Returns nil only when
    /// the address is unmapped. Never traps.
    func readBytesClamped(at cacheAddress: UInt64, maxLength: Int) -> Data? {
        guard maxLength > 0, validationError == nil else { return nil }
        for file in files {
            for mapping in file.mappings where mapping.contains(cacheAddress) {
                let delta = cacheAddress - mapping.address              // safe: contains() checked
                let (fileStart, overflow) = mapping.fileOffset.addingReportingOverflow(delta)
                guard !overflow, fileStart <= UInt64(Int.max) else { return nil }
                let start = Int(fileStart)
                guard start >= 0, start <= file.bytes.count else { return nil }
                // Bytes remaining within THIS mapping, and within the backing file.
                let mappingRemaining = mapping.size - delta            // safe: delta < size
                let avail = Int(min(UInt64(maxLength), mappingRemaining))
                let end = start + min(file.bytes.count - start, avail)
                guard end > start else { return Data() }
                let base = file.bytes.startIndex
                return file.bytes.subdata(in: base + start ..< base + end)
            }
        }
        return nil
    }
}


/// Mapping-bound static targets, with authentication facts retained separately.
/// This never authenticates a runtime pointer or clears arbitrary high address bits.
extension MultiFileCacheReader {
    struct SlideAuthentication: Equatable, Sendable {
        let diversity: UInt16
        let addressDiversity: Bool
        let key: UInt8 // IA=0, IB=1, DA=2, DB=3
    }

    struct SlidePointer: Equatable, Sendable {
        let rawValue: UInt64
        let target: UInt64
        let version: UInt32
        let authentication: SlideAuthentication?
    }

    struct SlidePage: Sendable {
        var start: UInt64 = 0
        var size: UInt64 = 0
        var pointers: [UInt64: SlidePointer] = [:]
        var unavailableReason: String?
    }

    /// Decode only the requested page. The page is all-or-nothing: a malformed later
    /// link cannot lend authority to an earlier word. No cache image enumeration occurs.
    func slidePage(containing address: UInt64) -> SlidePage {
        func unavailable(_ reason: String) -> SlidePage { SlidePage(unavailableReason: reason) }
        guard let resolved = resolve(address),
              let mapping = resolved.file.mappings.first(where: { $0.contains(address) }) else {
            return unavailable("The address has no admitted cache mapping.")
        }
        let bytes = LittleEndianReader(resolved.file.bytes)
        guard let headerSize = try? bytes.u32(16), headerSize >= 0x140,
              let table = try? bytes.u32(0x138), let count = try? bytes.u32(0x13c),
              count > 0, count <= 4096, table >= headerSize,
              bytes.range(UInt64(table), UInt64(count) * 56) != nil else {
            return unavailable("Mapping-bound slide metadata is absent or malformed.")
        }
        let matches = (0..<Int(count)).filter { index in
            let record = Int(table) + index * 56
            return (try? bytes.u64(record)) == mapping.address
                && (try? bytes.u64(record + 8)) == mapping.size
                && (try? bytes.u64(record + 16)) == mapping.fileOffset
                && (try? bytes.u32(record + 48)) == mapping.maxProtection
                && (try? bytes.u32(record + 52)) == mapping.initialProtection
        }
        guard matches.count == 1 else { return unavailable("Slide record is not uniquely bound to the admitted mapping.") }
        let record = Int(table) + matches[0] * 56
        guard let offset = try? bytes.u64(record + 24), let size = try? bytes.u64(record + 32) else {
            return unavailable("Slide record is truncated.")
        }
        if offset == 0 && size == 0 {
            return SlidePage(start: mapping.address, size: mapping.size)
        }
        guard size >= 24, let range = bytes.range(offset, size),
              let version = try? bytes.u32(range.lowerBound), version == 3 || version == 5 else {
            return unavailable("The mapping's slide format is unsupported or truncated.")
        }
        guard let pageSize32 = try? bytes.u32(range.lowerBound + 4),
              pageSize32 == 4096 || pageSize32 == 16384,
              let pageCount = try? bytes.u32(range.lowerBound + 8),
              let valueAdd = try? bytes.u64(range.lowerBound + 16),
              UInt64(pageCount) * 2 <= size - 24 else {
            return unavailable("Slide page metadata is malformed.")
        }
        let pageSize = UInt64(pageSize32)
        let pageIndex = (address - mapping.address) / pageSize
        let mappingPages = mapping.size / pageSize + (mapping.size % pageSize == 0 ? 0 : 1)
        guard UInt64(pageCount) <= mappingPages, pageIndex < UInt64(pageCount),
              let first = try? bytes.u16(range.lowerBound + 24 + Int(pageIndex) * 2) else {
            return unavailable("The requested page has no complete slide coverage.")
        }
        let pageStart = mapping.address + pageIndex * pageSize
        let length = min(pageSize, mapping.size - pageIndex * pageSize)
        var result = SlidePage(start: pageStart, size: length)
        if first == 0xffff { return result }
        guard first % 8 == 0, let page = readBytes(at: pageStart, length: length) else {
            return unavailable("Slide page start is unaligned or unreadable.")
        }
        let words = LittleEndianReader(page)
        var cursor = Int(first)
        for _ in 0..<(Int(length) / 8) {
            guard let raw = try? words.u64(cursor) else { return unavailable("Slide chain leaves its mapped page.") }
            let authenticated = raw >> 63 != 0
            let target: UInt64
            let auth: SlideAuthentication?
            let next: Int
            if version == 5 {
                // fixup-chains.h: dyld_chained_ptr_arm64e_shared_cache_*.
                guard authenticated || (raw >> 42) & 0x3ff == 0 else {
                    return unavailable("Slide v5 reserved bits are nonzero.")
                }
                let sum = valueAdd.addingReportingOverflow(raw & 0x3_ffff_ffff)
                guard !sum.overflow else { return unavailable("Slide target overflows.") }
                target = authenticated ? sum.partialValue : sum.partialValue | (((raw >> 34) & 0xff) << 56)
                auth = authenticated ? SlideAuthentication(diversity: UInt16((raw >> 34) & 0xffff),
                    addressDiversity: (raw >> 50) & 1 != 0, key: (raw >> 51) & 1 == 0 ? 0 : 2) : nil
                next = Int((raw >> 52) & 0x7ff) * 8
            } else {
                guard (raw >> 62) & 1 == 0 else { return unavailable("Slide v3 reserved bit is nonzero.") }
                if authenticated {
                    let sum = valueAdd.addingReportingOverflow(raw & 0xffff_ffff)
                    guard !sum.overflow else { return unavailable("Slide target overflows.") }
                    target = sum.partialValue
                    auth = SlideAuthentication(diversity: UInt16((raw >> 32) & 0xffff),
                        addressDiversity: (raw >> 48) & 1 != 0, key: UInt8((raw >> 49) & 3))
                } else {
                    target = (raw & 0x0000_07ff_ffff_ffff) | ((raw & 0x0007_f800_0000_0000) << 13)
                    auth = nil
                }
                next = Int((raw >> 51) & 0x7ff) * 8
            }
            result.pointers[pageStart + UInt64(cursor)] = SlidePointer(
                rawValue: raw, target: target, version: version, authentication: auth)
            if next == 0 { return result }
            cursor += next
        }
        return unavailable("Slide chain exceeds its page bound.")
    }
}
