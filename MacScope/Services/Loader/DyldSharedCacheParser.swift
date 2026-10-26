import Foundation

enum DyldSharedCacheError: LocalizedError, Equatable {
    case notADyldCache
    case truncated(String)
    case malformed(String)
    case imageNotFound(String)
    case addressNotMapped(UInt64)
    case subCacheOnly(String)
    case unsupportedImageMagic(UInt32)
    case missingSubCache(String)
    case crossFileAddressUnresolved(UInt64)
    case siblingUUIDMismatch(String)
    case overlappingMappings(UInt64)

    var errorDescription: String? {
        switch self {
        case .siblingUUIDMismatch(let suffix):
            "The declared sub-cache UUID does not match the file for '\(suffix)'."
        case .overlappingMappings(let address):
            String(format: "Cache mappings overlap at VM address 0x%llx.", address)
        case .notADyldCache:
            "The file is not a dyld shared cache (bad magic)."
        case .truncated(let context):
            "The dyld shared cache is truncated or malformed (\(context))."
        case .malformed(let context):
            "The dyld shared cache header is malformed (\(context))."
        case .imageNotFound(let path):
            "No image matching '\(path)' was found in the dyld shared cache."
        case .addressNotMapped(let address):
            String(format: "Cache VM address 0x%llx is not covered by any mapping.", address)
        case .subCacheOnly(let path):
            "Image '\(path)' lives in a separate sub-cache file, which this loader cannot project from the main cache alone."
        case .unsupportedImageMagic(let magic):
            String(format: "The located image is not a 64-bit Mach-O (magic 0x%08x).", magic)
        case .missingSubCache(let suffix):
            "The dyld shared cache references a sub-cache file '\(suffix)' that was not provided or is unreadable."
        case .crossFileAddressUnresolved(let address):
            String(format: "Cache VM address 0x%llx is not mapped by the main cache or any provided sub-cache.", address)
        }
    }
}

/// One `dyld_cache_mapping_info` record: a contiguous span of the cache that maps a
/// run of VM address space to a run of file bytes. The image-locator uses these to turn
/// a cache VM address into a file offset.
struct DyldCacheMapping: Equatable, Sendable {
    var address: UInt64      // VM address the mapping starts at
    var size: UInt64         // byte length
    var fileOffset: UInt64   // file offset the mapping's bytes begin at
    var maxProtection: UInt32
    var initialProtection: UInt32

    /// True when `cacheAddress` falls inside this mapping's VM range.
    func contains(_ cacheAddress: UInt64) -> Bool {
        let (end, overflow) = address.addingReportingOverflow(size)
        return !overflow && cacheAddress >= address && cacheAddress < end
    }
}

/// One `dyld_cache_image_info` record: an image's mach_header VM address and the file
/// offset of its NUL-terminated install-name/path string.
struct DyldCacheImage: Equatable, Sendable {
    var address: UInt64        // VM address of the image's mach_header
    var pathFileOffset: UInt64 // file offset of the image path C-string
    var path: String           // resolved install-name path
}

/// The parsed top of a `dyld_cache_header` plus its mapping and image arrays. Every
/// offset/count is range-validated against the file size during parse, so a crafted or
/// truncated cache degrades to a thrown `DyldSharedCacheError` rather than a crash.
struct DyldSharedCacheHeader: Sendable {
    var magicString: String        // e.g. "dyld_v1  arm64e"
    var architecture: String       // the arch token from the magic ("arm64e", "x86_64h", ...)
    var mappingOffset: UInt32
    var mappingCount: UInt32
    var imagesOffset: UInt32       // imagesOffset (or imagesTextOffset on newer caches)
    var imagesCount: UInt32
    var subCacheArrayOffset: UInt32 // file offset of the dyld_subcache_entry array
    var subCacheArrayCount: UInt32 // >0 indicates a split multi-sub-cache layout
    var usesImagesText: Bool       // true if we fell back to imagesText{Offset,Count}
    var sharedRegionStart: UInt64  // cache base address (DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE base)
    var mappings: [DyldCacheMapping]
    var images: [DyldCacheImage]
    var subCacheEntries: [DyldSubCacheEntry] // parsed sibling sub-cache descriptors
    var uuid: [UInt8]
    var symbolFileUUID: [UInt8]?
    var usesV2SubCacheEntries: Bool
}

/// Parses a dyld shared cache file (the documented blind spot: system dylibs live ONLY
/// in this cache on modern macOS) into a validated header + mapping + image model, and
/// projects a single requested image's Mach-O out of the cache into a standalone thin
/// Mach-O `Data` blob that the existing `MachOParser` pipeline can disassemble.
///
/// HARDENING: a shared cache is a large untrusted file. Every offset/count is
/// range-validated against the file length, every loop is bounded, and there is no
/// UInt64->Int trap (all conversions go through a checked `intOffset`). An image that
/// lives only in a sub-cache, or an address outside every mapping, degrades to a clear
/// typed error.
///
/// SCOPE: handles BOTH the classic single-file 64-bit cache AND the modern macOS split
/// multi-cache (verified firsthand against the real arm64e cache + Apple's authoritative
/// dyld_cache_format.h). It locates an image via the modern `imagesOffset@0x1C0` array,
/// finds the sibling sub-cache file holding its bytes via the `subCacheArray@0x188`
/// descriptors, and projects header + load commands + segment file-bytes (cross-sub-cache,
/// incl. the shared `__LINKEDIT`) into a self-contained blob. An image whose bytes are in
/// a sub-cache file that was not provided degrades to a typed `.subCacheOnly`. Slid/
/// authenticated pointer rebasing remains a runtime concern (see integrationRisks).
struct DyldSharedCacheParser: Sendable {
    struct Limits: Sendable {
        // Paths are normally short install names; these allowances also cover large catalogs.
        var maximumPathScanBytes: UInt64 = 1024 * 1024
        var maximumAggregatePathScanBytes: UInt64 = 64 * 1024 * 1024
        var maximumPathDecodedBytes: UInt64 = 3 * 1024 * 1024
        var maximumAggregatePathDecodedBytes: UInt64 = 128 * 1024 * 1024
        // Includes the header, segments, and all separately copied linkedit payloads.
        var maximumProjectedBytes: UInt64 = 1024 * 1024 * 1024

        static let production = Limits()
    }

    let limits: Limits

    init(limits: Limits = .production) {
        self.limits = limits
    }

    /// The magic prefix every dyld cache starts with: "dyld_v1" then spaces then arch.
    static let magicPrefix = "dyld_v1"
    /// Bound on mapping/image array element counts so a crafted count cannot allocate
    /// unboundedly even before the range check rejects it.
    static let maximumArrayCount = 1_000_000
    /// Largest segment we copy into a projected image blob. Real-cache shared segments
    /// (`__OBJC_RO`, the 1.6 GB `__LINKEDIT`) far exceed any sane per-image projection
    /// budget; a segment over this is emitted metadata-only (zero filesize) so the blob
    /// stays bounded — correctness over coverage.
    static let maxProjectedSegmentBytes: UInt64 = 64 * 1024 * 1024
    /// Largest individual `__LINKEDIT` data blob (export trie, function starts, nlist, or
    /// string table) we bring into a projected image. The real cache's string table is
    /// ~960 MB SHARED across every image; over this it is dropped (exports still come from
    /// the export trie).
    static let maxProjectedLinkeditBytes: UInt64 = 128 * 1024 * 1024

    // Field offsets within dyld_cache_header. Verified firsthand against the real macOS
    // arm64e cache AND Apple's authoritative dyld_cache_format.h (apple-oss-distributions/
    // dyld): the header grows append-only and `mappingOffset` doubles as the header size,
    // so a field is present only when its end offset <= mappingOffset.
    private enum Field {
        static let magic = 0            // char[16]
        static let mappingOffset = 16   // u32 — file offset of mappings AND header-size gate
        static let mappingCount = 20    // u32
        // Legacy ("Old") image array, still used by classic single-file caches. Modern
        // multi-caches ZERO these and use `imagesOffset`/`imagesCount` at 0x1C0/0x1C4
        // (moved so old dsc_extractors don't crash). dyld_cache_image_info layout.
        static let imagesOffsetOld = 24 // u32
        static let imagesCountOld = 28  // u32
        // Modern primary image array (dyld_cache_image_info: address@0, pathFileOffset@24).
        static let imagesOffset = 0x1C0 // u32
        static let imagesCount = 0x1C4  // u32
        // imagesText* (dyld_cache_image_text_info: uuid@0, loadAddress@16, pathOffset@28) —
        // last-resort fallback. The OLD loader wrongly put this at 0xE0/0xE8, which is
        // actually sharedRegionStart/Size (the real-cache oracle's headline finding).
        static let imagesTextOffset = 0x088 // u64
        static let imagesTextCount = 0x090  // u64
        // Base load address of the whole cache; doubles as the base for the
        // DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE runtime-offset pointer decode.
        static let sharedRegionStart = 0x0E0 // u64
        // Sub-cache entry array. The OLD loader wrongly put this at 0x1C0/0x1C4 (= the modern
        // image array); verified firsthand it lives at 0x188/0x18C.
        static let subCacheArrayOffset = 0x188 // u32
        static let subCacheArrayCount = 0x18C  // u32
        // End offset of the modern-images field block; a header is "modern" when it is at
        // least this large (its `mappingOffset` >= this).
        static let modernImagesEnd = 0x1C8
        static let subCacheArrayEnd = 0x190
    }

    /// Sub-cache entry strides. The v1 record is uuid[16]+cacheVMOffset(u64); the v2
    /// record appends fileSuffix[32]. Header extent selects the layout.
    private enum SubCacheStride {
        static let v1 = 24
        static let v2 = 56
        static let suffixLength = 32
    }

    /// Sniffs whether `bytes` begins with the dyld cache magic.
    static func isDyldSharedCache(_ bytes: Data) -> Bool {
        guard bytes.count >= magicPrefix.utf8.count else { return false }
        let prefix = magicPrefix.utf8
        var index = bytes.startIndex
        for expected in prefix {
            if bytes[index] != expected { return false }
            index = bytes.index(after: index)
        }
        return true
    }

    /// Converts an untrusted `UInt64` to an `Int` file offset without trapping; nil if it
    /// would overflow `Int` (i.e. not addressable on this platform).
    private static func intOffset(_ value: UInt64) -> Int? {
        value <= UInt64(Int.max) ? Int(value) : nil
    }

    /// Parses the header + mapping array + image array, validating every offset/count
    /// against the file length.
    func parseHeader(_ bytes: Data) throws -> DyldSharedCacheHeader {
        guard Self.isDyldSharedCache(bytes) else { throw DyldSharedCacheError.notADyldCache }
        guard bytes.count >= 32 else { throw DyldSharedCacheError.truncated("header") }
        let reader = LittleEndianReader(bytes)

        let magicString = Self.readMagicString(bytes)
        let architecture = magicString
            .dropFirst(Self.magicPrefix.count)
            .trimmingCharacters(in: .whitespaces)

        let mappingOffset = try reader.u32(Field.mappingOffset)
        let mappingCount = try reader.u32(Field.mappingCount)
        guard mappingOffset >= 32, UInt64(mappingOffset) <= UInt64(bytes.count) else {
            throw DyldSharedCacheError.truncated("header extent")
        }
        let imagesOffsetOld = try reader.u32(Field.imagesOffsetOld)
        let imagesCountOld = try reader.u32(Field.imagesCountOld)

        guard mappingCount > 0, mappingCount <= UInt32(Self.maximumArrayCount) else {
            throw DyldSharedCacheError.malformed("mapping count \(mappingCount) is zero or implausibly large")
        }

        // Sub-cache array offset/count. Present only when the header reaches its end offset
        // (`mappingOffset` is the header-size gate). A non-zero count signals the split
        // multi-sub-cache layout shipped on recent macOS — verified firsthand at 0x188/0x18C.
        var subCacheArrayOffset: UInt32 = 0
        var subCacheArrayCount: UInt32 = 0
        if mappingOffset >= UInt32(Field.subCacheArrayEnd), bytes.count >= Field.subCacheArrayEnd {
            subCacheArrayOffset = (try? reader.u32(Field.subCacheArrayOffset)) ?? 0
            subCacheArrayCount = (try? reader.u32(Field.subCacheArrayCount)) ?? 0
        }

        let mappings = try Self.parseMappings(
            reader: reader,
            mappingOffset: mappingOffset,
            mappingCount: mappingCount,
            fileCount: bytes.count
        )

        // Choose the image array from candidates in priority order: the modern
        // `imagesOffset@0x1C0` (multi-caches), then the legacy `imagesOffsetOld@0x18`
        // (classic single-file caches), then the `imagesText@0x88` text-info array. Each
        // record is 32 bytes. Pick the first candidate that is non-empty AND fully in
        // range; if every non-empty candidate is out of range, still select the
        // highest-priority non-empty one so `parseImages` throws `.truncated` (preserving
        // the malformed-cache hardening); if all are empty the cache simply has no images.
        var candidates: [(offset: UInt32, count: UInt32, usesText: Bool)] = []
        if mappingOffset >= UInt32(Field.modernImagesEnd), bytes.count >= Field.modernImagesEnd {
            let modernOffset = (try? reader.u32(Field.imagesOffset)) ?? 0
            let modernCount = (try? reader.u32(Field.imagesCount)) ?? 0
            candidates.append((modernOffset, modernCount, false))
        }
        candidates.append((imagesOffsetOld, imagesCountOld, false))
        if bytes.count >= Field.imagesTextCount + 8 {
            let textOffset = (try? reader.u64(Field.imagesTextOffset)) ?? 0
            let textCount = (try? reader.u64(Field.imagesTextCount)) ?? 0
            if textOffset <= UInt64(UInt32.max), textCount <= UInt64(UInt32.max) {
                candidates.append((UInt32(textOffset), UInt32(textCount), true))
            }
        }
        func arrayInRange(_ candidate: (offset: UInt32, count: UInt32, usesText: Bool)) -> Bool {
            candidate.count > 0 && candidate.count <= UInt32(Self.maximumArrayCount)
                && reader.range(UInt64(candidate.offset), UInt64(candidate.count) * 32) != nil
        }
        let chosen = candidates.first(where: arrayInRange) ?? candidates.first(where: { $0.count > 0 })
        let imagesOffset = chosen?.offset ?? 0
        let imagesCount = chosen?.count ?? 0
        let usesImagesText = chosen?.usesText ?? false

        let images = try Self.parseImages(
            reader: reader,
            imagesOffset: imagesOffset,
            imagesCount: imagesCount,
            usesImagesText: usesImagesText,
            fileCount: bytes.count,
            limits: limits
        )

        let subCacheEntries = try Self.parseSubCacheEntries(
            reader: reader,
            arrayOffset: subCacheArrayOffset,
            arrayCount: subCacheArrayCount,
            usesV2: mappingOffset >= 0x1CC
        )

        // Cache base (for the shared-cache pointer decode); present only on a large-enough header.
        var sharedRegionStart: UInt64 = 0
        if mappingOffset >= UInt32(Field.sharedRegionStart + 8) {
            sharedRegionStart = (try? reader.u64(Field.sharedRegionStart)) ?? 0
        }

        return DyldSharedCacheHeader(
            magicString: magicString,
            architecture: architecture,
            mappingOffset: mappingOffset,
            mappingCount: mappingCount,
            imagesOffset: imagesOffset,
            imagesCount: imagesCount,
            subCacheArrayOffset: subCacheArrayOffset,
            subCacheArrayCount: subCacheArrayCount,
            usesImagesText: usesImagesText,
            sharedRegionStart: sharedRegionStart,
            mappings: mappings,
            images: images,
            subCacheEntries: subCacheEntries,
            uuid: Self.cacheUUID(in: bytes) ?? [],
            symbolFileUUID: mappingOffset >= 0x1A0
                ? Self.nonzeroUUID((0x190..<0x1A0).map { reader.byte($0) ?? 0 }) : nil,
            usesV2SubCacheEntries: mappingOffset >= 0x1CC
        )
    }

    /// Header capability chooses the format; file bounds only validate that choice.
    private static func parseSubCacheEntries(
        reader: LittleEndianReader,
        arrayOffset: UInt32,
        arrayCount: UInt32,
        usesV2: Bool
    ) throws -> [DyldSubCacheEntry] {
        guard arrayCount > 0 else { return [] }
        guard arrayCount <= UInt32(maximumArrayCount) else {
            throw DyldSharedCacheError.malformed("sub-cache entry count exceeds bound")
        }
        let stride = usesV2 ? SubCacheStride.v2 : SubCacheStride.v1
        guard reader.range(UInt64(arrayOffset), UInt64(arrayCount) * UInt64(stride)) != nil else {
            throw DyldSharedCacheError.truncated("sub-cache entry array out of range")
        }
        var entries: [DyldSubCacheEntry] = []
        entries.reserveCapacity(Int(arrayCount))
        for index in 0..<Int(arrayCount) {
            let base = Int(arrayOffset) + index * stride
            var uuid: [UInt8] = []
            uuid.reserveCapacity(16)
            for i in 0..<16 { uuid.append(reader.byte(base + i) ?? 0) }
            let cacheVMOffset = try reader.u64(base + 16)
            var fileSuffix = ".\(index + 1)"
            if stride == SubCacheStride.v2 {
                fileSuffix = fixedCString(reader: reader, at: base + 24, length: SubCacheStride.suffixLength)
            }
            entries.append(DyldSubCacheEntry(uuid: uuid, cacheVMOffset: cacheVMOffset, fileSuffix: fileSuffix))
        }
        return entries
    }

    static func cacheUUID(in bytes: Data) -> [UInt8]? {
        guard isDyldSharedCache(bytes), bytes.count >= 0x68,
              let extent = try? LittleEndianReader(bytes).u32(16),
              extent >= 0x68, UInt64(extent) <= UInt64(bytes.count) else { return nil }
        return (0x58..<0x68).map { LittleEndianReader(bytes).byte($0) ?? 0 }
    }

    private static func nonzeroUUID(_ uuid: [UInt8]) -> [UInt8]? {
        uuid.contains(where: { $0 != 0 }) ? uuid : nil
    }

    private static func readMagicString(_ bytes: Data) -> String {
        let reader = LittleEndianReader(bytes)
        var scalars: [UInt8] = []
        for offset in 0..<16 {
            guard let byte = reader.byte(offset), byte != 0 else { break }
            scalars.append(byte)
        }
        return String(decoding: scalars, as: UTF8.self)
    }

    private static func parseMappings(
        reader: LittleEndianReader,
        mappingOffset: UInt32,
        mappingCount: UInt32,
        fileCount: Int
    ) throws -> [DyldCacheMapping] {
        // dyld_cache_mapping_info is 32 bytes: address u64, size u64, fileOffset u64,
        // maxProt u32, initProt u32.
        let recordSize: UInt64 = 32
        guard reader.range(UInt64(mappingOffset), UInt64(mappingCount) * recordSize) != nil else {
            throw DyldSharedCacheError.truncated("mapping array out of range")
        }
        var mappings: [DyldCacheMapping] = []
        mappings.reserveCapacity(Int(mappingCount))
        for index in 0..<Int(mappingCount) {
            let base = Int(mappingOffset) + index * Int(recordSize)
            let address = try reader.u64(base + 0)
            let size = try reader.u64(base + 8)
            let fileOffset = try reader.u64(base + 16)
            let maxProtection = try reader.u32(base + 24)
            let initialProtection = try reader.u32(base + 28)
            // The mapping's file bytes must lie within the file (a mapping can be huge in
            // VM but its backing file run must be present in this file).
            guard reader.range(fileOffset, size) != nil else {
                throw DyldSharedCacheError.malformed("mapping \(index) file range [\(fileOffset), +\(size)) exceeds the file")
            }
            mappings.append(DyldCacheMapping(
                address: address,
                size: size,
                fileOffset: fileOffset,
                maxProtection: maxProtection,
                initialProtection: initialProtection
            ))
        }
        if let error = MultiFileCacheReader.mappingError(mappings) { throw error }
        return mappings
    }

    private static func parseImages(
        reader: LittleEndianReader,
        imagesOffset: UInt32,
        imagesCount: UInt32,
        usesImagesText: Bool,
        fileCount: Int,
        limits: Limits
    ) throws -> [DyldCacheImage] {
        guard imagesCount > 0 else { return [] }
        guard imagesCount <= UInt32(maximumArrayCount) else {
            throw DyldSharedCacheError.malformed("image count \(imagesCount) is implausibly large")
        }
        // dyld_cache_image_info       : address u64, modTime u64, inode u64, pathFileOffset u32, pad u32 => 32 bytes
        // dyld_cache_image_text_info  : uuid[16], loadAddress u64, textSegmentSize u32, pathOffset u32  => 32 bytes
        let recordSize: UInt64 = 32
        guard reader.range(UInt64(imagesOffset), UInt64(imagesCount) * recordSize) != nil else {
            throw DyldSharedCacheError.truncated("image array out of range")
        }
        var images: [DyldCacheImage] = []
        images.reserveCapacity(Int(imagesCount))
        var pathsByOffset: [UInt64: String] = [:]
        var scannedBytes: UInt64 = 0
        var decodedBytes: UInt64 = 0
        for index in 0..<Int(imagesCount) {
            let base = Int(imagesOffset) + index * Int(recordSize)
            let address: UInt64
            let pathOffset: UInt64
            if usesImagesText {
                // text-info: loadAddress at +16, pathOffset (u32) at +28.
                address = try reader.u64(base + 16)
                pathOffset = UInt64(try reader.u32(base + 28))
            } else {
                // image-info: address at +0, pathFileOffset (u32) at +24.
                address = try reader.u64(base + 0)
                pathOffset = UInt64(try reader.u32(base + 24))
            }
            // The path string offset must be inside the file; read it bounded.
            let path: String
            if let cached = pathsByOffset[pathOffset] {
                path = cached
            } else if let pathInt = intOffset(pathOffset), pathInt < fileCount {
                var end = pathInt
                var pathScannedBytes: UInt64 = 0
                while end < fileCount {
                    guard pathScannedBytes < limits.maximumPathScanBytes else {
                        throw DyldSharedCacheError.malformed("image path exceeds scan budget")
                    }
                    guard scannedBytes < limits.maximumAggregatePathScanBytes else {
                        throw DyldSharedCacheError.malformed("image paths exceed aggregate scan budget")
                    }
                    pathScannedBytes += 1
                    scannedBytes += 1
                    if reader.byte(end) == 0 { break }
                    end += 1
                }
                // Reject the minimum decoded size before allocation, then account for
                // any replacement characters introduced while repairing invalid UTF-8.
                let encodedBytes = UInt64(end - pathInt)
                guard encodedBytes <= limits.maximumPathDecodedBytes else {
                    throw DyldSharedCacheError.malformed("image path exceeds decoded byte budget")
                }
                guard decodedBytes <= limits.maximumAggregatePathDecodedBytes,
                      encodedBytes <= limits.maximumAggregatePathDecodedBytes - decodedBytes else {
                    throw DyldSharedCacheError.malformed("image paths exceed decoded byte budget")
                }
                // Decode each distinct offset once; String values share their immutable storage.
                let start = reader.bytes.startIndex
                path = String(decoding: reader.bytes[(start + pathInt)..<(start + end)], as: UTF8.self)
                let pathBytes = UInt64(path.utf8.count)
                guard pathBytes <= limits.maximumPathDecodedBytes else {
                    throw DyldSharedCacheError.malformed("image path exceeds decoded byte budget")
                }
                guard decodedBytes <= limits.maximumAggregatePathDecodedBytes,
                      pathBytes <= limits.maximumAggregatePathDecodedBytes - decodedBytes else {
                    throw DyldSharedCacheError.malformed("image paths exceed decoded byte budget")
                }
                decodedBytes += pathBytes
                pathsByOffset[pathOffset] = path
            } else {
                path = ""
                pathsByOffset[pathOffset] = path
            }
            images.append(DyldCacheImage(address: address, pathFileOffset: pathOffset, path: path))
        }
        return images
    }

    /// Resolves a cache VM address to a file offset via the mappings. Returns nil when no
    /// mapping covers the address (e.g. it lives in a sub-cache).
    static func fileOffset(for cacheAddress: UInt64, mappings: [DyldCacheMapping]) -> UInt64? {
        guard MultiFileCacheReader.mappingError(mappings) == nil else { return nil }
        for mapping in mappings where mapping.contains(cacheAddress) {
            let delta = cacheAddress - mapping.address
            let (offset, overflow) = mapping.fileOffset.addingReportingOverflow(delta)
            return overflow ? nil : offset
        }
        return nil
    }

    /// Locates `imagePath` in the cache (suffix-tolerant: a trailing-path match counts so
    /// "libSystem.B.dylib" finds "/usr/lib/libSystem.B.dylib").
    func locateImage(path imagePath: String, in header: DyldSharedCacheHeader) throws -> DyldCacheImage {
        if let exact = header.images.first(where: { $0.path == imagePath }) {
            return exact
        }
        if let suffix = header.images.first(where: { $0.path.hasSuffix(imagePath) && !$0.path.isEmpty }) {
            return suffix
        }
        throw DyldSharedCacheError.imageNotFound(imagePath)
    }

    /// Projects one image's Mach-O out of the cache into a standalone, contiguous thin
    /// Mach-O `Data` blob. The header + load commands are copied verbatim; each
    /// LC_SEGMENT_64's segment file bytes are appended in order and the segment's (and its
    /// sections') `fileoff` fields are rewritten to the blob-relative offset, so the
    /// result is a self-contained Mach-O the normal parser can read. `__LINKEDIT` (symbol
    /// tables etc.) lives in a shared region whose bytes are not adjacent to the image, so
    /// it is included when its mapped file range is within this file and skipped (zero
    /// filesize) otherwise — the loader still recovers sections + disassembles code.
    func projectImage(
        _ image: DyldCacheImage,
        from bytes: Data,
        header: DyldSharedCacheHeader
    ) throws -> Data {
        let multiReader = MultiFileCacheReader(files: [
            .init(suffix: "", bytes: bytes, mappings: header.mappings)
        ])
        return try projectImage(image, using: multiReader, header: header)
    }

    // MARK: - Multi-file (sub-cache) stitching

    /// Builds a `MultiFileCacheReader` from the main cache + the loaded sibling sub-cache
    /// datas. `subCacheDatas` maps each sibling's on-disk file suffix (e.g. ".symbols",
    /// ".1") to its bytes — injectable so the unit tests need no filesystem; the on-disk
    /// open of those siblings is the thin runtime tail (see `DyldSharedCacheBinaryLoader`).
    ///
    /// Every sibling is itself a dyld cache: we parse ITS header to recover ITS mappings
    /// (whose `address` fields are absolute cache VM addresses), so the reader can map any
    /// cross-file VM address. A sibling referenced by a `subCacheEntry` but absent from
    /// `subCacheDatas` is skipped here; the projector surfaces `.missingSubCache` only if a
    /// required address actually lands in a missing file. A sibling whose bytes are not a
    /// dyld cache (or is malformed) is skipped. UUID mismatches and mapping overlaps
    /// instead invalidate the reader with a typed refusal.
    func makeMultiFileReader(
        mainBytes: Data,
        header: DyldSharedCacheHeader,
        subCacheDatas: [String: Data]
    ) -> MultiFileCacheReader {
        var files: [MultiFileCacheReader.CacheFile] = [
            .init(suffix: "", bytes: mainBytes, mappings: header.mappings)
        ]
        // Register each declared sibling that we were given bytes for. Order follows the
        // sub-cache array; overlapping mappings are rejected by the reader.
        for entry in header.subCacheEntries {
            guard let data = subCacheDatas[entry.fileSuffix] else { continue }
            // Parse the sibling's own header to recover its mappings. A malformed sibling
            // is skipped (its addresses stay unresolved) rather than aborting the open.
            let siblingHeader: DyldSharedCacheHeader
            do { siblingHeader = try parseHeader(data) }
            catch let error as DyldSharedCacheError {
                if case .overlappingMappings = error {
                    return MultiFileCacheReader(files: files, admissionError: error)
                }
                continue
            } catch { continue }
            guard siblingHeader.uuid == entry.uuid else {
                return MultiFileCacheReader(files: files, admissionError: .siblingUUIDMismatch(entry.fileSuffix))
            }
            files.append(.init(suffix: entry.fileSuffix, bytes: data, mappings: siblingHeader.mappings))
        }
        return MultiFileCacheReader(files: files)
    }

    /// Projects one image's Mach-O into a standalone thin blob, resolving its segments AND
    /// its shared `__LINKEDIT` symbol/string tables ACROSS the sub-cache files via the
    /// `MultiFileCacheReader`. This is the real-cache path: an image's bytes (or its
    /// `__LINKEDIT`, which on a split cache lives in the `.symbols` sub-cache) are located
    /// by VM address through every file's mappings, so the projected blob carries real
    /// symbols even when they were never in the main file.
    ///
    /// HARDENING: every resolve goes through the multi-file reader, which only returns a
    /// `(file, offset)` validated against THAT file's length. An address neither the main
    /// cache nor any provided sub-cache maps degrades to `.crossFileAddressUnresolved`; a
    /// segment is emitted at zero filesize if unresolved so the projection never reads out
    /// of range. No UInt64→Int trap, every loop bounded.
    func projectImage(
        _ image: DyldCacheImage,
        using multiReader: MultiFileCacheReader,
        header: DyldSharedCacheHeader
    ) throws -> Data {
        try projectImageWithCoverage(image, using: multiReader, header: header).bytes
    }

    func projectImageWithCoverage(
        _ image: DyldCacheImage,
        using multiReader: MultiFileCacheReader,
        header: DyldSharedCacheHeader
    ) throws -> DyldCacheImageProjection {
        try multiReader.validate()
        var unavailableSections: [BinarySection] = []
        var findings: [LoaderFinding] = []
        // 1. Locate + read the image's mach_header + load commands by VM address.
        guard let headerResolved = multiReader.resolve(image.address) else {
            throw DyldSharedCacheError.crossFileAddressUnresolved(image.address)
        }
        let headerFile = headerResolved.file
        guard multiReader.readBytes(at: image.address, length: 32) != nil else {
            throw DyldSharedCacheError.truncated("image mach_header crosses mapping")
        }
        guard let headerStart = Self.intOffset(headerResolved.fileOffset), headerStart >= 0,
              headerStart + 32 <= headerFile.bytes.count else {
            throw DyldSharedCacheError.truncated("image mach_header (cross-file)")
        }
        let reader = LittleEndianReader(headerFile.bytes)
        let magic = try reader.u32(headerStart)
        guard magic == MachOConstants.machMagic64 else {
            throw DyldSharedCacheError.unsupportedImageMagic(magic)
        }

        let loadCommandCount = try reader.u32(headerStart + 16)
        let loadCommandsSize = try reader.u32(headerStart + 20)
        guard loadCommandCount <= UInt32(Self.maximumArrayCount) else {
            throw DyldSharedCacheError.malformed("image load command count is implausibly large")
        }
        guard let lcRegion = reader.range(UInt64(headerStart) + 32, UInt64(loadCommandsSize)),
              lcRegion.upperBound <= headerFile.bytes.count else {
            throw DyldSharedCacheError.truncated("image load commands (cross-file)")
        }
        try Self.requireProjectionCapacity(currentCount: 0, additionalBytes: 32 + UInt64(loadCommandsSize),
            maximumBytes: limits.maximumProjectedBytes)
        guard multiReader.readBytes(at: image.address, length: 32 + UInt64(loadCommandsSize)) != nil else {
            throw DyldSharedCacheError.truncated("image load commands cross mapping")
        }
        let lcEnd = headerStart + 32 + Int(loadCommandsSize)

        // 2. Pass 1: collect LC_SEGMENT_64 records (vmaddr-keyed for cross-file resolution)
        // and remember the __LINKEDIT segment so file-relative linkedit offsets can be
        // turned into VM addresses.
        var segments: [CrossFileSegment] = []
        var linkeditSegment: CrossFileSegment?
        var hasFunctionVariantFixups = false
        var hasChainedFixups = false
        var cursor = headerStart + 32
        for index in 0..<Int(loadCommandCount) {
            guard cursor + 8 <= lcEnd else {
                throw DyldSharedCacheError.truncated("load command \(index)")
            }
            let command = try reader.u32(cursor)
            let commandSize = try reader.u32(cursor + 4)
            guard commandSize >= 8, cursor + Int(commandSize) <= lcEnd else {
                throw DyldSharedCacheError.malformed("load command \(index) size out of range")
            }
            // Preserve declarations before unavailable payload commands are omitted.
            if command == 0x38 || command == MachOConstants.loadCommandDyldChainedFixups,
               commandSize >= 16, try reader.u32(cursor + 12) > 0 {
                if command == 0x38 { hasFunctionVariantFixups = true }
                if command == MachOConstants.loadCommandDyldChainedFixups { hasChainedFixups = true }
            }
            if command == MachOConstants.loadCommandSegment64 {
                guard commandSize >= 72 else {
                    throw DyldSharedCacheError.malformed("LC_SEGMENT_64 \(index) is smaller than 72 bytes")
                }
                let segName = Self.fixedCString(reader: reader, at: cursor + 8, length: 16)
                let vmAddr = try reader.u64(cursor + 24)
                let fileOffsetField = try reader.u64(cursor + 40)
                let fileSizeField = try reader.u64(cursor + 48)
                let sectionCount = try reader.u32(cursor + 64)
                guard 72 + Int(sectionCount) * 80 <= Int(commandSize) else {
                    throw DyldSharedCacheError.malformed("LC_SEGMENT_64 \(index) section records exceed the command")
                }
                let segment = CrossFileSegment(
                    name: segName,
                    loadCommandOffset: cursor,
                    vmAddress: vmAddr,
                    cacheFileOffset: fileOffsetField,
                    fileSize: fileSizeField,
                    sectionCount: sectionCount
                )
                segments.append(segment)
                if segName == "__LINKEDIT" { linkeditSegment = segment }
            }
            cursor += Int(commandSize)
        }

        // 3. Build the blob: copy header + load commands, then append each segment's bytes
        // resolved BY VM ADDRESS through the multi-file reader. Two real-cache realities shape
        // this: (a) `__LINKEDIT` is the multi-GB SHARED region (1.6 GB on the real arm64e
        // cache) and the string table alone is ~960 MB shared across every image — copying it
        // wholesale is infeasible and wrong, so its small per-image blobs (export trie,
        // function starts, symtab) are brought separately by VM in step 4; (b) other shared
        // segments (e.g. `__OBJC_RO`, hundreds of MB) exceed a sane projection budget, so a
        // segment over `maxProjectedSegmentBytes` is emitted metadata-only (zero filesize) —
        // correctness over coverage: the parser still lists the section, just without bytes.
        var blob = Data(headerFile.bytes[headerFile.bytes.startIndex + headerStart ..< headerFile.bytes.startIndex + lcEnd])
        // Map the rewritten Mach-O header at slice offset zero. Native image identity
        // requires this ordinary segment geometry. Carry the original reservation and
        // exact emitted header bytes so the loader never infers an equality exception.
        let headerCandidates = segments.filter {
            $0.vmAddress == image.address && $0.cacheFileOffset == UInt64(headerStart)
                && $0.fileSize >= UInt64(lcEnd - headerStart)
                && $0.fileSize <= Self.maxProjectedSegmentBytes && $0.name != "__LINKEDIT"
        }
        var headerSegmentOffset: Int?
        if headerCandidates.count == 1, let segment = headerCandidates.first {
            try Self.requireProjectionCapacity(currentCount: 0, additionalBytes: segment.fileSize,
                maximumBytes: limits.maximumProjectedBytes)
            if let bytes = multiReader.readBytes(at: segment.vmAddress, length: segment.fileSize) {
                blob = bytes
                headerSegmentOffset = segment.loadCommandOffset
            }
        }
        var emittedRanges: [EmittedRange] = []
        for segment in segments {
            let isHeaderSegment = segment.loadCommandOffset == headerSegmentOffset
            let newFileOffset = isHeaderSegment ? 0 : UInt64(blob.count)
            var emittedFileSize: UInt64 = 0
            if segment.name != "__LINKEDIT", segment.fileSize > 0,
               segment.fileSize <= Self.maxProjectedSegmentBytes {
                if isHeaderSegment {
                    emittedFileSize = segment.fileSize
                } else {
                    try Self.requireProjectionCapacity(currentCount: blob.count, additionalBytes: segment.fileSize,
                        maximumBytes: limits.maximumProjectedBytes)
                    if let segmentBytes = multiReader.readBytes(at: segment.vmAddress, length: segment.fileSize) {
                        blob.append(segmentBytes)
                        emittedFileSize = segment.fileSize
                    }
                }
                if emittedFileSize > 0 {
                    emittedRanges.append(EmittedRange(
                        cacheStart: segment.cacheFileOffset,
                        size: emittedFileSize,
                        blobStart: newFileOffset
                    ))
                }
            }

            if segment.fileSize > 0, emittedFileSize == 0, segment.name != "__LINKEDIT" {
                findings.append(LoaderFinding(category: .metadataParseIssue,
                    code: "cacheSegmentBytesUnavailable", address: segment.vmAddress,
                    message: "Cache segment bytes are unavailable within the projection budget and mapping bounds."))
            }
            let blobLCOffset = segment.loadCommandOffset - headerStart
            Self.writeUInt64LE(&blob, at: blobLCOffset + 40, value: emittedFileSize > 0 ? newFileOffset : 0)
            Self.writeUInt64LE(&blob, at: blobLCOffset + 48, value: emittedFileSize)

            var sectionRecord = segment.loadCommandOffset + 72
            for _ in 0..<Int(segment.sectionCount) {
                guard sectionRecord + 80 <= lcEnd else { break }
                let sectionFileOffset = (try? reader.u32(sectionRecord + 48)) ?? 0
                let blobSectionRecord = sectionRecord - headerStart
                let sectionSize = try reader.u64(sectionRecord + 40)
                let sectionFlags = try reader.u32(sectionRecord + 64)
                let sectionType = sectionFlags & 0xff
                let zeroFill = [UInt32(1), 0xc, 0x12].contains(sectionType)
                if emittedFileSize > 0, UInt64(sectionFileOffset) >= segment.cacheFileOffset,
                   UInt64(sectionFileOffset) - segment.cacheFileOffset <= emittedFileSize,
                   sectionSize <= emittedFileSize - (UInt64(sectionFileOffset) - segment.cacheFileOffset) {
                    let delta = UInt64(sectionFileOffset) - segment.cacheFileOffset
                    Self.writeUInt32LE(&blob, at: blobSectionRecord + 48, value: UInt32(truncatingIfNeeded: newFileOffset + delta))
                } else {
                    Self.writeUInt32LE(&blob, at: blobSectionRecord + 48, value: 0)
                    if !zeroFill, sectionSize > 0 {
                        findings.append(LoaderFinding(category: .metadataParseIssue,
                            code: "cacheSectionBytesUnavailable", address: try reader.u64(sectionRecord + 32),
                            message: "Cache section bytes are outside the available projected segment."))
                        // Suppress unavailable payload parsing. Restore its declared VM extent
                        // only in LoadedBinary, with explicit zero physical coverage.
                        Self.writeUInt64LE(&blob, at: blobSectionRecord + 40, value: 0)
                        let sectionName = Self.fixedCString(reader: reader, at: sectionRecord, length: 16)
                        unavailableSections.append(BinarySection(
                            name: "\(segment.name),\(sectionName)",
                            address: try reader.u64(sectionRecord + 32), size: sectionSize,
                            fileOffset: 0, isExecutable: sectionFlags & 0x80000400 != 0
                                || (segment.name == "__TEXT" && sectionName == "__text"), fileSize: 0))
                    }
                }
                sectionRecord += 80
            }
        }

        // 4. Bring along the small per-image __LINKEDIT data blobs (export trie, function
        // starts, data-in-code, and a size-bounded symtab) by VM ADDRESS — since __LINKEDIT
        // itself was not emitted. Each blob's VM address is `linkedit.vmaddr + (offset -
        // linkedit.fileoff)`; it is read through the multi-file reader (so it resolves to
        // whichever sub-cache file backs the shared __LINKEDIT, e.g. `.NN.dyldlinkedit`),
        // appended, and its load-command offset rewritten. A blob that is too large (the
        // shared string table) or unresolved is disabled so the parser skips it cleanly.
        try Self.appendCrossFileLinkedit(
            in: &blob,
            reader: reader,
            multiReader: multiReader,
            headerStart: headerStart,
            imageAddress: image.address,
            loadCommandCount: Int(loadCommandCount),
            lcEnd: lcEnd,
            segments: segments,
            emittedRanges: emittedRanges,
            findings: &findings,
            maximumProjectedBytes: limits.maximumProjectedBytes
        )
        _ = linkeditSegment // resolution is segment-agnostic (see appendCrossFileLinkedit)

        for index in unavailableSections.indices {
            unavailableSections[index].fileOffset = UInt64(blob.count)
        }
        let headerRegion = headerSegmentOffset.map { _ in
            DyldCacheImageProjection.HeaderRegion(
                vmAddress: image.address, originalByteCount: UInt64(lcEnd - headerStart),
                writtenBytes: blob.subdata(in: 0..<(lcEnd - headerStart)))
        }
        return DyldCacheImageProjection(bytes: blob, unavailableSections: unavailableSections, findings: findings,
            headerRegion: headerRegion, hasFunctionVariantFixups: hasFunctionVariantFixups,
            hasChainedFixups: hasChainedFixups)
    }

    /// Brings the small per-image linkedit data blobs into the projected `blob` by VM
    /// address and rewrites their load-command offsets. Handles `LC_DYLD_EXPORTS_TRIE`,
    /// `LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`, `LC_SYMTAB` (nlist + string table, only when
    /// both fit `maxProjectedLinkeditBytes`), and the export sub-trie of legacy
    /// `LC_DYLD_INFO[_ONLY]`. `LC_DYSYMTAB` indirect symbols and the dyld_info bind/rebase
    /// streams are disabled (they index the shared/compacted tables). Any blob that is too
    /// large or unresolved is disabled (offset + paired size/count zeroed) so the downstream
    /// `MachOParser` treats that table as absent rather than reading garbage.
    ///
    /// A linkedit offset is a cache file offset; its VM address is resolved against
    /// WHICHEVER segment's file range contains it — `__LINKEDIT` on a real cache, but the
    /// single-file fixture parks its symtab inside `__TEXT`, so resolution is segment-
    /// agnostic rather than tied to a `__LINKEDIT` segment that may not exist.
    private static func appendCrossFileLinkedit(
        in blob: inout Data,
        reader: LittleEndianReader,
        multiReader: MultiFileCacheReader,
        headerStart: Int,
        imageAddress: UInt64,
        loadCommandCount: Int,
        lcEnd: Int,
        segments: [CrossFileSegment],
        emittedRanges: [EmittedRange],
        findings: inout [LoaderFinding],
        maximumProjectedBytes: UInt64
    ) throws {
        // VM address of a cache file offset, via the segment whose file range contains it.
        func vmForFileOffset(_ off: UInt64, size: UInt64) -> UInt64? {
            for segment in segments where segment.fileSize > 0
                && off >= segment.cacheFileOffset && off - segment.cacheFileOffset < segment.fileSize
                && size <= segment.fileSize - (off - segment.cacheFileOffset) {
                let result = segment.vmAddress.addingReportingOverflow(off - segment.cacheFileOffset)
                if !result.overflow { return result.partialValue }
            }
            return nil
        }

        var retainedCommands = Data()
        var retainedCount: UInt32 = 0
        var cursor = headerStart + 32
        for _ in 0..<loadCommandCount {
            guard cursor + 8 <= lcEnd,
                  let command = try? reader.u32(cursor),
                  let commandSize = try? reader.u32(cursor + 4),
                  commandSize >= 8,
                  cursor + Int(commandSize) <= lcEnd
            else { return }
            let blobLC = cursor - headerStart
            var omitCommand = false

            // Appends `size` bytes of linkedit data living at file offset `off` by resolving
            // its VM address through the reader. Returns the new blob offset, or nil when
            // unavailable/too large.
            func bring(_ off: UInt32, _ size: UInt32) throws -> UInt32? {
                guard off != 0, size != 0, UInt64(size) <= Self.maxProjectedLinkeditBytes,
                      let vmAddress = vmForFileOffset(UInt64(off), size: UInt64(size)) else { return nil }
                try Self.requireProjectionCapacity(currentCount: blob.count, additionalBytes: UInt64(size),
                    maximumBytes: maximumProjectedBytes)
                guard let data = multiReader.readBytes(at: vmAddress, length: UInt64(size)),
                      UInt64(blob.count) <= UInt64(UInt32.max) else { return nil }
                let at = UInt32(blob.count)
                blob.append(data)
                return at
            }
            func disable(_ offsetField: Int, _ pairedField: Int) {
                if (try? reader.u32(cursor + offsetField)) != 0
                    || (try? reader.u32(cursor + pairedField)) != 0 {
                    findings.append(LoaderFinding(category: .metadataParseIssue,
                        code: "cacheLinkeditPayloadUnavailable", address: imageAddress,
                        message: "Cache load command \(String(command, radix: 16)) payload at field \(offsetField) is unavailable in the rewritten image."))
                }
                writeUInt32LE(&blob, at: blobLC + offsetField, value: 0)
                writeUInt32LE(&blob, at: blobLC + pairedField, value: 0)
            }
            func rewriteDataInCodeEntryOffsets(tableOffset: UInt32, tableSize: UInt32) {
                guard tableSize > 0, tableSize % 8 == 0 else { return }
                var entryOffset = Int(tableOffset)
                let tableEnd = entryOffset + Int(tableSize)
                guard entryOffset >= 0, tableEnd <= blob.count else { return }
                while entryOffset + 8 <= tableEnd {
                    let cacheOffset = UInt64(blob.readUInt32LEUnchecked(at: entryOffset))
                    if let projected = translate(cacheOffset, in: emittedRanges),
                       projected <= UInt64(UInt32.max) {
                        writeUInt32LE(&blob, at: entryOffset, value: UInt32(projected))
                    } else {
                        writeUInt32LE(&blob, at: entryOffset, value: 0)
                    }
                    entryOffset += 8
                }
            }

            switch command {
            case MachOConstants.loadCommandSegment64 where commandSize >= 72:
                let count = Int((try? reader.u32(cursor + 64)) ?? 0)
                for index in 0..<count where 72 + (index + 1) * 80 <= Int(commandSize) {
                    let section = 72 + index * 80
                    let off = (try? reader.u32(cursor + section + 56)) ?? 0
                    let count = (try? reader.u32(cursor + section + 60)) ?? 0
                    let size = count.multipliedReportingOverflow(by: 8)
                    if count > 0, !size.overflow, let relocated = try bring(off, size.partialValue) {
                        writeUInt32LE(&blob, at: blobLC + section + 56, value: relocated)
                    } else if off != 0 || count != 0 {
                        disable(section + 56, section + 60)
                    }
                }
            case MachOConstants.loadCommandCodeSignature:
                omitCommand = true
                findings.append(LoaderFinding(category: .metadataParseIssue,
                    code: "cacheSignatureValidityUnavailable", address: imageAddress,
                    message: "The original cache signature cannot validate rewritten thin-image bytes; signature validity is unavailable."))
            case MachOConstants.loadCommandDyldChainedFixups,
                 0x1e, // segment split info
                 0x2b, // dylib code signing requirements
                 0x2e, // linker optimization hints
                 0x36, // atom info
                 0x37, // function variants
                 0x38, // function variant fixups
                 0x16, // two-level hints
                 0x31: // LC_NOTE
                // These payloads cannot retain their original offset or mutation
                // semantics in a thin projection. Omit the command itself.
                omitCommand = true
            case MachOConstants.loadCommandFunctionStarts where commandSize >= 16,
                 MachOConstants.loadCommandDyldExportsTrie where commandSize >= 16,
                 MachOConstants.loadCommandDataInCode where commandSize >= 16:
                // linkedit_data_command: dataoff@8, datasize@12.
                if let off = try? reader.u32(cursor + 8), let size = try? reader.u32(cursor + 12),
                   let newOff = try bring(off, size) {
                    writeUInt32LE(&blob, at: blobLC + 8, value: newOff)
                    if command == MachOConstants.loadCommandDataInCode {
                        rewriteDataInCodeEntryOffsets(tableOffset: newOff, tableSize: size)
                    }
                } else {
                    omitCommand = true
                }
            case MachOConstants.loadCommandSymtab where commandSize >= 24:
                // symoff@8 (nsyms@12), stroff@16 (strsize@20). Bring BOTH the nlist table and
                // the string table, or disable the whole symtab (the real cache's shared
                // strtab is ~960 MB and exceeds the budget → exports come from the trie).
                if let symoff = try? reader.u32(cursor + 8), let nsyms = try? reader.u32(cursor + 12),
                   let stroff = try? reader.u32(cursor + 16), let strsize = try? reader.u32(cursor + 20),
                   let newSym = try bring(symoff, nsyms.multipliedReportingOverflow(by: 16).overflow ? 0 : nsyms &* 16),
                   let newStr = try bring(stroff, strsize) {
                    writeUInt32LE(&blob, at: blobLC + 8, value: newSym)
                    writeUInt32LE(&blob, at: blobLC + 16, value: newStr)
                } else {
                    disable(8, 12)
                    disable(16, 20)
                }
            case MachOConstants.loadCommandDyldInfo where commandSize >= 48,
                 MachOConstants.loadCommandDyldInfoOnly where commandSize >= 48:
                // Bring only the export sub-trie (export_off@40, export_size@44); zero the
                // rebase/bind/weak/lazy streams (chained + large on a cache image).
                if let eoff = try? reader.u32(cursor + 40), let esize = try? reader.u32(cursor + 44),
                   let newOff = try bring(eoff, esize) {
                    writeUInt32LE(&blob, at: blobLC + 40, value: newOff)
                } else {
                    disable(40, 44)
                }
                for field in [8, 16, 24, 32] {
                    disable(field, field + 4)
                }
            case MachOConstants.loadCommandDysymtab where commandSize >= 64:
                // All six offset/count tables refer to the original cache layout.
                for field in stride(from: 32, through: 72, by: 8) where field + 8 <= Int(commandSize) {
                    disable(field, field + 4)
                }
            default:
                break
            }
            if omitCommand {
                findings.append(LoaderFinding(category: .metadataParseIssue,
                    code: "cacheLinkeditPayloadUnavailable", address: imageAddress,
                    message: "Cache load command \(String(command, radix: 16)) was omitted because its payload is unavailable in the rewritten image."))
            } else {
                retainedCommands.append(blob[blobLC..<(blobLC + Int(commandSize))])
                retainedCount += 1
            }
            cursor += Int(commandSize)
        }
        // Compact only after every original command and section offset was used.
        // Keep the reserved header area and all emitted payload offsets unchanged.
        let originalEnd = lcEnd - headerStart
        blob.replaceSubrange(32..<(32 + retainedCommands.count), with: retainedCommands)
        blob.replaceSubrange((32 + retainedCommands.count)..<originalEnd,
            with: repeatElement(UInt8(0), count: originalEnd - 32 - retainedCommands.count))
        writeUInt32LE(&blob, at: 16, value: retainedCount)
        writeUInt32LE(&blob, at: 20, value: UInt32(retainedCommands.count))
    }

    private static func requireProjectionCapacity(
        currentCount: Int,
        additionalBytes: UInt64,
        maximumBytes: UInt64
    ) throws {
        // Rewritten linkedit offsets use UInt32 even when a test supplies a larger limit.
        let maximum = min(maximumBytes, UInt64(UInt32.max))
        let current = UInt64(currentCount)
        guard current <= maximum, additionalBytes <= maximum - current else {
            throw DyldSharedCacheError.malformed("projected image exceeds aggregate byte budget")
        }
    }

    /// Translates a cache file offset to the projected blob offset using the emitted
    /// segment ranges, or nil if no emitted segment covers it.
    private static func translate(_ cacheOffset: UInt64, in ranges: [EmittedRange]) -> UInt64? {
        for range in ranges where cacheOffset >= range.cacheStart && cacheOffset < range.cacheStart &+ range.size {
            return range.blobStart &+ (cacheOffset - range.cacheStart)
        }
        return nil
    }

    /// Walks the copied load commands in the blob and rewrites the file-offset fields of
    /// LC_SYMTAB / LC_DYSYMTAB / LC_DYLD_INFO[_ONLY] / LC_FUNCTION_STARTS /
    /// LC_DATA_IN_CODE so they address the projected blob. An offset that cannot be
    /// translated is set to 0 (and its paired count, where applicable) so the downstream
    /// parser treats that table as absent rather than reading out of range.
    private static func rewriteLinkeditOffsets(
        in blob: inout Data,
        reader: LittleEndianReader,
        headerStart: Int,
        loadCommandCount: Int,
        lcEnd: Int,
        emittedRanges: [EmittedRange]
    ) {
        var cursor = headerStart + 32
        for _ in 0..<loadCommandCount {
            guard cursor + 8 <= lcEnd,
                  let command = try? reader.u32(cursor),
                  let commandSize = try? reader.u32(cursor + 4),
                  commandSize >= 8,
                  cursor + Int(commandSize) <= lcEnd
            else { return }
            let blobLC = cursor - headerStart

            // (fieldOffsetWithinCommand, pairedCountFieldOrNil) for each u32 file-offset.
            let offsetFields: [(Int, Int?)]
            switch command {
            case MachOConstants.loadCommandSymtab where commandSize >= 24:
                // symoff@8 (nsyms@12), stroff@16 (strsize@20)
                offsetFields = [(8, 12), (16, 20)]
            case MachOConstants.loadCommandDysymtab where commandSize >= 80:
                // indirectsymoff@56 (nindirectsyms@60); other tables left as-is/zeroed below
                offsetFields = [(56, 60)]
            case MachOConstants.loadCommandDyldInfo where commandSize >= 48,
                 MachOConstants.loadCommandDyldInfoOnly where commandSize >= 48:
                // export_off@40 (export_size@44)
                offsetFields = [(40, 44)]
            case MachOConstants.loadCommandFunctionStarts where commandSize >= 16:
                // dataoff@8 (datasize@12)
                offsetFields = [(8, 12)]
            default:
                offsetFields = []
            }

            for (fieldOffset, countField) in offsetFields {
                guard let original = try? reader.u32(cursor + fieldOffset), original != 0 else { continue }
                if let translated = translate(UInt64(original), in: emittedRanges),
                   translated <= UInt64(UInt32.max) {
                    writeUInt32LE(&blob, at: blobLC + fieldOffset, value: UInt32(translated))
                } else {
                    // Not brought along — disable the table so the parser skips it.
                    writeUInt32LE(&blob, at: blobLC + fieldOffset, value: 0)
                    if let countField { writeUInt32LE(&blob, at: blobLC + countField, value: 0) }
                }
            }

            cursor += Int(commandSize)
        }
    }

    // MARK: - Local byte helpers (blob is trusted/our own; cache reads use LittleEndianReader)

    private static func fixedCString(reader: LittleEndianReader, at offset: Int, length: Int) -> String {
        var scalars: [UInt8] = []
        for i in 0..<length {
            guard let byte = reader.byte(offset + i), byte != 0 else { break }
            scalars.append(byte)
        }
        return String(decoding: scalars, as: UTF8.self)
    }

    private static func writeUInt32LE(_ data: inout Data, at offset: Int, value: UInt32) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        let base = data.startIndex + offset
        data[base] = UInt8(value & 0xff)
        data[base + 1] = UInt8((value >> 8) & 0xff)
        data[base + 2] = UInt8((value >> 16) & 0xff)
        data[base + 3] = UInt8((value >> 24) & 0xff)
    }

    private static func writeUInt64LE(_ data: inout Data, at offset: Int, value: UInt64) {
        guard offset >= 0, offset + 8 <= data.count else { return }
        let base = data.startIndex + offset
        for i in 0..<8 {
            data[base + i] = UInt8((value >> (8 * i)) & 0xff)
        }
    }
}

/// Maps an emitted segment's cache file range to its offset in the projected blob, so
/// linkedit-style load-command offsets can be translated.
private struct EmittedRange {
    var cacheStart: UInt64
    var size: UInt64
    var blobStart: UInt64
}

/// Internal layout record for one projected LC_SEGMENT_64.
private struct ProjectedSegment {
    var name: String
    var loadCommandOffset: Int  // absolute file offset of the LC in the cache
    var cacheFileOffset: UInt64 // the segment's fileoff within the cache
    var fileSize: UInt64
    var sectionCount: UInt32
}

/// Internal layout record for one LC_SEGMENT_64 during cross-file (multi-sub-cache)
/// projection. Carries the segment's VM address so its bytes can be resolved through the
/// `MultiFileCacheReader` regardless of which sub-cache file backs them.
private struct CrossFileSegment {
    var name: String
    var loadCommandOffset: Int  // absolute file offset of the LC in the HEADER's file
    var vmAddress: UInt64       // segment vmaddr (used to resolve bytes across files)
    var cacheFileOffset: UInt64 // the segment's fileoff within the cache (for LE translation)
    var fileSize: UInt64
    var sectionCount: UInt32
}

private extension Data {
    func readUInt32LEUnchecked(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}

struct DyldCacheImageProjection {
    struct HeaderRegion {
        let vmAddress: UInt64
        /// Includes the original mach_header_64 and load-command reservation, even
        /// when command omission has shortened the emitted sizeofcmds.
        let originalByteCount: UInt64
        let writtenBytes: Data
    }

    var bytes: Data
    var unavailableSections: [BinarySection]
    var findings: [LoaderFinding]
    let headerRegion: HeaderRegion?
    let hasFunctionVariantFixups: Bool
    let hasChainedFixups: Bool
}

/// Local symbols are supplemental naming, never mapped image-byte authority.
struct DyldCacheLocalSymbolResult {
    var symbols: [SymbolSummary] = []
    var unavailableReason: String?
}

extension DyldSharedCacheParser {
    /// This route supports the UUID-declared modern companion's 64-bit VM-offset
    /// ownership entries. Legacy inline tables remain explicitly unavailable.
    func localSymbols(
        for image: DyldCacheImage,
        header: DyldSharedCacheHeader,
        companion: Data?,
        sections: [MachOSection]
    ) -> DyldCacheLocalSymbolResult {
        func unavailable(_ reason: String) -> DyldCacheLocalSymbolResult {
            DyldCacheLocalSymbolResult(unavailableReason: reason)
        }
        guard let expectedUUID = header.symbolFileUUID else {
            return unavailable("Cache has no declared local-symbol companion; legacy inline tables are unsupported.")
        }
        guard let companion else { return unavailable("The declared local-symbol companion is unavailable.") }
        guard Self.cacheUUID(in: companion) == expectedUUID else {
            return unavailable("The local-symbol companion UUID does not match the cache.")
        }
        guard header.usesV2SubCacheEntries, header.architecture.contains("64"),
              header.sharedRegionStart > 0, image.address >= header.sharedRegionStart else {
            return unavailable("Local-symbol ownership format is unsupported.")
        }
        do {
            let reader = LittleEndianReader(companion)
            let base = try reader.u64(0x48), size = try reader.u64(0x50)
            guard size >= 24, reader.range(base, size) != nil, let start = Int(exactly: base) else {
                return unavailable("Local-symbol payload is absent or out of range.")
            }
            let nlistOffset = UInt64(try reader.u32(start))
            let nlistCount = UInt64(try reader.u32(start + 4))
            let stringsOffset = UInt64(try reader.u32(start + 8))
            let stringsSize = UInt64(try reader.u32(start + 12))
            let entriesOffset = UInt64(try reader.u32(start + 16))
            let entriesCount = UInt64(try reader.u32(start + 20))
            func fits(_ offset: UInt64, _ count: UInt64) -> Bool {
                offset >= 24 && offset <= size && count <= size - offset
            }
            guard entriesCount <= UInt64(Self.maximumArrayCount),
                  fits(entriesOffset, entriesCount * 16), fits(nlistOffset, nlistCount * 16),
                  fits(stringsOffset, stringsSize) else {
                return unavailable("Local-symbol tables exceed their declared payload.")
            }
            let tables = [entriesOffset..<(entriesOffset + entriesCount * 16),
                          nlistOffset..<(nlistOffset + nlistCount * 16),
                          stringsOffset..<(stringsOffset + stringsSize)]
            guard !tables[0].overlaps(tables[1]), !tables[0].overlaps(tables[2]),
                  !tables[1].overlaps(tables[2]) else {
                return unavailable("Local-symbol tables overlap.")
            }
            let owner = image.address - header.sharedRegionStart
            var selected: Range<UInt64>?
            var ranges: [(owner: UInt64, range: Range<UInt64>)] = []
            for index in 0..<Int(entriesCount) {
                let at = start + Int(entriesOffset) + index * 16
                let key = try reader.u64(at)
                let first = UInt64(try reader.u32(at + 8))
                let count = UInt64(try reader.u32(at + 12))
                guard first <= nlistCount, count <= nlistCount - first else {
                    return unavailable("Local-symbol ownership range is invalid.")
                }
                let range = first..<(first + count)
                if key == owner {
                    guard selected == nil else { return unavailable("Local-symbol image ownership is ambiguous.") }
                    selected = range
                }
                ranges.append((key, range))
            }
            guard let selected else { return unavailable("No local-symbol entry owns the selected image.") }
            guard selected.count <= Self.maximumArrayCount,
                  !ranges.contains(where: { $0.owner != owner && $0.range.overlaps(selected) }) else {
                return unavailable("Local-symbol nlist ownership is ambiguous or exceeds the read budget.")
            }
            var symbols: [SymbolSummary] = []
            var nameBytes = 0
            var incompleteNames = false
            for index in selected {
                let at = start + Int(nlistOffset + index * 16)
                let stringIndex = UInt64(try reader.u32(at))
                let type = reader.byte(at + 4) ?? 0
                let sectionIndex = Int(reader.byte(at + 5) ?? 0)
                let address = try reader.u64(at + 8)
                guard type & 0xe0 == 0, type & 0x0e == 0x0e,
                      sectionIndex > 0, sectionIndex <= sections.count,
                      stringIndex > 0, stringIndex < stringsSize else { continue }
                let section = sections[sectionIndex - 1]
                guard address >= section.address, address - section.address < section.size else { continue }
                let stringStart = start + Int(stringsOffset + stringIndex)
                let limit = Int(min(stringsSize - stringIndex, 4096))
                var encoded: [UInt8] = []
                var terminated = false
                for offset in 0..<limit {
                    guard let byte = reader.byte(stringStart + offset) else { break }
                    if byte == 0 { terminated = true; break }
                    encoded.append(byte)
                }
                nameBytes += encoded.count
                guard nameBytes <= Int(Self.maxProjectedSegmentBytes) else {
                    return unavailable("Selected local-symbol names exceed the read budget.")
                }
                guard terminated, !encoded.isEmpty,
                      let name = String(bytes: encoded, encoding: .utf8) else {
                    incompleteNames = true
                    continue
                }
                symbols.append(SymbolSummary(id: UUID(), name: name, address: address,
                    kind: MachOSymbolKind.local.rawValue, libraryName: nil, rawLinkageName: name))
            }
            return DyldCacheLocalSymbolResult(symbols: symbols, unavailableReason: incompleteNames
                ? "Some selected local-symbol strings are invalid or exceed the bounded string read." : nil)
        } catch {
            return unavailable("Local-symbol metadata is truncated.")
        }
    }
}


extension DyldSharedCacheParser {
    /// Resolve one requested external code address. Only the candidate owner's load
    /// commands, export trie and owned local-symbol slice are read, never its image bytes.
    func ownedCodeSymbol(at target: UInt64, using cache: MultiFileCacheReader,
                         header: DyldSharedCacheHeader, companion: Data?) -> SymbolSummary? {
        guard let ownerAddress = header.images.filter({ $0.address <= target }).map(\.address).max() else { return nil }
        let owners = header.images.filter { $0.address == ownerAddress }
        guard owners.count == 1, let owner = owners.first,
              let prefix = cache.readBytes(at: owner.address, length: 32) else { return nil }
        let prefixReader = LittleEndianReader(prefix)
        guard (try? prefixReader.u32(0)) == 0xfeedfacf,
              let count = try? prefixReader.u32(16), count <= 4096,
              let size = try? prefixReader.u32(20), size <= 1024 * 1024,
              let commands = cache.readBytes(at: owner.address, length: 32 + UInt64(size)) else { return nil }
        let reader = LittleEndianReader(commands)
        func name(_ offset: Int) -> String {
            let bytes = commands[offset..<(offset + 16)]
            return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        var cursor = 32
        var segments: [(address: UInt64, size: UInt64, offset: UInt64, fileSize: UInt64, protection: UInt32)] = []
        var sections: [MachOSection] = []
        var exports: [(offset: UInt32, size: UInt32)] = []
        for _ in 0..<count {
            guard let kind = try? reader.u32(cursor), let length = try? reader.u32(cursor + 4),
                  length >= 8, Int(length) <= commands.count - cursor else { return nil }
            if kind == MachOConstants.loadCommandSegment64 {
                guard length >= 72,
                      let address = try? reader.u64(cursor + 24), let vmSize = try? reader.u64(cursor + 32),
                      let fileOffset = try? reader.u64(cursor + 40), let fileSize = try? reader.u64(cursor + 48),
                      let protection = try? reader.u32(cursor + 60), let sectionCount = try? reader.u32(cursor + 64),
                      UInt64(sectionCount) * 80 <= UInt64(length) - 72,
                      !address.addingReportingOverflow(vmSize).overflow else { return nil }
                segments.append((address, vmSize, fileOffset, fileSize, protection))
                for index in 0..<Int(sectionCount) {
                    let at = cursor + 72 + index * 80
                    guard let sectionAddress = try? reader.u64(at + 32), let sectionSize = try? reader.u64(at + 40),
                          sectionAddress >= address, sectionAddress - address <= vmSize,
                          sectionSize <= vmSize - (sectionAddress - address),
                          let offset = try? reader.u32(at + 48), let flags = try? reader.u32(at + 64) else { return nil }
                    sections.append(MachOSection(sectionName: name(at), segmentName: name(at + 16),
                        address: sectionAddress, size: sectionSize, fileOffset: offset, alignment: 0,
                        relocationOffset: 0, relocationCount: 0, flags: flags,
                        reserved1: 0, reserved2: 0, reserved3: 0))
                }
            } else if kind == MachOConstants.loadCommandDyldExportsTrie, length >= 16 {
                if let offset = try? reader.u32(cursor + 8), let size = try? reader.u32(cursor + 12) {
                    exports.append((offset, size))
                }
            } else if [MachOConstants.loadCommandDyldInfo, MachOConstants.loadCommandDyldInfoOnly].contains(kind), length >= 48 {
                if let offset = try? reader.u32(cursor + 40), let size = try? reader.u32(cursor + 44) {
                    exports.append((offset, size))
                }
            }
            cursor += Int(length)
        }
        guard cursor == commands.count,
              segments.filter({ $0.protection & 4 != 0 && target >= $0.address
                  && target - $0.address < min($0.size, $0.fileSize) }).count == 1,
              sections.contains(where: { $0.isExecutableInstructions && target >= $0.address && target - $0.address < $0.size }),
              cache.readBytes(at: target, length: 4) != nil else { return nil }
        var names = Set<String>()
        for export in exports where export.size > 0 && export.size <= 4 * 1024 * 1024 {
            let containing = segments.filter { UInt64(export.offset) >= $0.offset
                && UInt64(export.offset) - $0.offset <= $0.fileSize
                && UInt64(export.size) <= $0.fileSize - (UInt64(export.offset) - $0.offset) }
            guard containing.count == 1, let segment = containing.first else { continue }
            let vm = segment.address.addingReportingOverflow(UInt64(export.offset) - segment.offset)
            guard !vm.overflow, let trie = cache.readBytes(at: vm.partialValue, length: UInt64(export.size)),
                  let proven = Self.exportNames(in: trie, imageBase: owner.address, target: target) else { continue }
            names.formUnion(proven)
        }
        if let name = names.sorted().first {
            return SymbolSummary(id: UUID(), name: name, address: target, kind: MachOSymbolKind.export.rawValue,
                libraryName: owner.path, rawLinkageName: name)
        }
        guard var local = localSymbols(for: owner, header: header, companion: companion, sections: sections)
            .symbols.filter({ $0.address == target }).sorted(by: { $0.name < $1.name }).first else { return nil }
        local.libraryName = owner.path
        return local
    }

    private static func exportNames(in data: Data, imageBase: UInt64, target: UInt64) -> Set<String>? {
        func uleb(_ cursor: inout Int, limit: Int) -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard cursor < limit else { return nil }
                let byte = data[cursor]; cursor += 1
                guard shift < 63 || byte <= 1 else { return nil }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        var pending = [(offset: 0, name: "")]
        var visited = Set<Int>()
        var names = Set<String>()
        while let node = pending.popLast() {
            guard visited.count < 4096, visited.insert(node.offset).inserted,
                  node.offset >= 0, node.offset < data.count, node.name.utf8.count <= 4096 else { return nil }
            var cursor = node.offset
            guard let terminalSize = uleb(&cursor, limit: data.count), terminalSize <= UInt64(data.count - cursor) else { return nil }
            let terminalEnd = cursor + Int(terminalSize)
            if terminalSize > 0 {
                guard let flags = uleb(&cursor, limit: terminalEnd) else { return nil }
                if flags & ~UInt64(0x14) == 0 { // regular, optional weak definition or stub/resolver
                    guard let offset = uleb(&cursor, limit: terminalEnd) else { return nil }
                    if flags & 0x10 != 0, uleb(&cursor, limit: terminalEnd) == nil { return nil }
                    guard cursor == terminalEnd else { return nil }
                    let address = imageBase.addingReportingOverflow(offset)
                    if !address.overflow, address.partialValue == target, !node.name.isEmpty { names.insert(node.name) }
                }
            }
            cursor = terminalEnd
            guard cursor < data.count else { continue }
            let children = Int(data[cursor]); cursor += 1
            for _ in 0..<children {
                guard let end = data[cursor...].firstIndex(of: 0), end - cursor <= 4096,
                      let edge = String(data: data[cursor..<end], encoding: .utf8), !edge.isEmpty else { return nil }
                cursor = end + 1
                guard let offset = uleb(&cursor, limit: data.count), offset < UInt64(data.count), pending.count < 4096 else { return nil }
                pending.append((Int(offset), node.name + edge))
            }
        }
        return names
    }
}
