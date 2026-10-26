import Foundation

/// Optional byte-only loading capability. Nil means the format needs its existing path-based
/// container loader; malformed supported images throw instead of silently falling back.
protocol CapturedByteBinaryLoader: BinaryLoader {
    func loadCapturedBytes(_ bytes: Data, sourceURL: URL,
                           cancellation: AnalysisCancellationToken) throws -> LoadedBinary?
}

/// Routes a file to the right `BinaryLoader` by sniffing its magic number: a dyld shared
/// cache ("dyld_v1 …") → `DyldSharedCacheBinaryLoader`, Unix archive →
/// `ELFArchiveBinaryLoader`, ELF → `ELFBinaryLoader`, PE/COFF
/// ("MZ" or a COFF machine word) → `PEBinaryLoader`, everything else (thin/fat Mach-O —
/// or an unsupported file the Mach-O importer will reject with its own error) →
/// `MachOBinaryLoader`, which also resolves `.app` bundles. This is the default loader the
/// engine uses so opening any supported binary "just works".
struct BinaryLoaderRouter: CapturedByteBinaryLoader {
    private let machO: MachOBinaryLoader
    private let elf: ELFBinaryLoader
    private let elfArchive: ELFArchiveBinaryLoader
    private let pe: PEBinaryLoader
    private let dyldCache: DyldSharedCacheBinaryLoader

    init(
        machO: MachOBinaryLoader = MachOBinaryLoader(),
        elf: ELFBinaryLoader = ELFBinaryLoader(),
        elfArchive: ELFArchiveBinaryLoader = ELFArchiveBinaryLoader(),
        pe: PEBinaryLoader = PEBinaryLoader(),
        dyldCache: DyldSharedCacheBinaryLoader = DyldSharedCacheBinaryLoader()
    ) {
        self.machO = machO
        self.elf = elf
        self.elfArchive = elfArchive
        self.pe = pe
        self.dyldCache = dyldCache
    }

    /// Convenience router that loads a fat/universal Mach-O's explicit slice (the user's
    /// pick from the open-time loader-options dialog). ELF/PE/dyld-cache routing is
    /// unchanged; each format-specific index reaches only its owning loader (the dyld cache
    /// image install name reaches only the cache loader).
    init(selection: BinaryLoadSelection) {
        self.init(
            machO: MachOBinaryLoader(requestedSliceIndex: selection.requestedMachOSliceIndex),
            elfArchive: ELFArchiveBinaryLoader(selection: selection.elfArchiveMember),
            pe: PEBinaryLoader(coffSectionLayoutVersion: selection.coffSectionLayoutVersion ?? 1),
            dyldCache: DyldSharedCacheBinaryLoader(targetImagePath: selection.dyldCacheImagePath)
        )
    }

    init(requestedMachOSliceIndex: Int?) {
        self.init(selection: .machOSlice(requestedMachOSliceIndex))
    }

    func load(at url: URL) throws -> LoadedBinary {
        try routeLoad(at: url, cancellation: nil)
    }

    func load(at url: URL, cancellation: AnalysisCancellationToken) throws -> LoadedBinary {
        try cancellation.check()
        return try routeLoad(at: url, cancellation: cancellation)
    }

    /// Rehydrate from the exact immutable bytes decoded at the worker boundary. The descriptive
    /// URL is never opened. Archive/dyld containers keep their established path-dependent loader;
    /// normal persisted archive members and Mach-O slices are already self-contained images.
    func loadCapturedBytes(_ bytes: Data, sourceURL: URL,
                           cancellation: AnalysisCancellationToken) throws -> LoadedBinary? {
        try cancellation.check()
        if DyldSharedCacheParser.isDyldSharedCache(bytes)
            || ELFArchiveParser.isArchiveContainer(bytes) { return nil }
        if ELFBinaryLoader.isELF(bytes) {
            return try ELFBinaryLoader.parse(bytes: bytes, name: sourceURL.lastPathComponent, path: sourceURL.path)
        }
        if PEBinaryLoader.isPEorCOFF(bytes) {
            return try PEBinaryLoader.parse(bytes: bytes, name: sourceURL.lastPathComponent, path: sourceURL.path,
                                          coffSectionLayoutVersion: pe.coffSectionLayoutVersion)
        }
        return try machO.load(bytes: bytes, sourceURL: sourceURL)
    }

    private func routeLoad(
        at url: URL,
        cancellation: AnalysisCancellationToken?
    ) throws -> LoadedBinary {
        // `.app` bundles are a macOS/Mach-O concept; let the Mach-O loader resolve the
        // bundle's executable. For plain files, sniff the leading magic bytes.
        if url.pathExtension.lowercased() == "ipa" { return try machO.load(at: url) }
        if url.pathExtension.caseInsensitiveCompare("app") != .orderedSame, let magic = Self.peekMagic(url) {
            if IPAArchive.isZIP(magic) { return try machO.load(at: url) }
            if DyldSharedCacheParser.isDyldSharedCache(magic) { return try dyldCache.load(at: url) }
            // Route both ordinary and thin magic to the archive loader. Thin archives must receive
            // their precise typed refusal rather than falling through to an unrelated Mach-O error.
            if ELFArchiveParser.isArchiveContainer(magic) {
                if let cancellation { return try elfArchive.load(at: url, cancellation: cancellation) }
                return try elfArchive.load(at: url)
            }
            if ELFBinaryLoader.isELF(magic) { return try elf.load(at: url) }
            if PEBinaryLoader.isPEorCOFF(magic) { return try pe.load(at: url) }
        }
        return try machO.load(at: url)
    }

    private static func peekMagic(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read enough for the longest magic we sniff: the dyld cache "dyld_v1" prefix.
        return try? handle.read(upToCount: 16)
    }
}
