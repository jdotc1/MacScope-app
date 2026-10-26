import Foundation

/// Loads a single dylib image OUT of a dyld shared cache and projects it down to the
/// neutral `LoadedBinary`, so the analysis pipeline disassembles a cached system library
/// exactly as it would a thin Mach-O on disk. This is the documented blind spot: on
/// modern macOS the system dylibs exist ONLY inside the cache.
///
/// Flow: `DyldSharedCacheParser` parses + validates the header/mappings/images, locates
/// the requested image, and projects its Mach-O into a standalone thin `Data` blob; that
/// blob is then handed to the existing `MachOParser` so all the downstream Mach-O →
/// neutral translation (`MachOBinaryLoader`'s projection) is reused unchanged.
///
/// The target image path is configurable; with none set, the FIRST image in the cache is
/// projected (useful for the crafted single-image fixture and for "open the cache" UX
/// that later lets the user pick an image).
struct DyldSharedCacheBinaryLoader: BinaryLoader {
    static let maximumCacheFileBytes: UInt64 = 32 * 1_024 * 1_024 * 1_024
    static let maximumAggregateCacheBytes: UInt64 = 128 * 1_024 * 1_024 * 1_024

    let targetImagePath: String?
    private let parser: DyldSharedCacheParser
    private let machOParser: MachOParser
    private let perFileByteLimit: UInt64
    private let aggregateByteLimit: UInt64

    init(
        targetImagePath: String? = nil,
        parser: DyldSharedCacheParser = DyldSharedCacheParser(),
        machOParser: MachOParser = MachOParser(),
        perFileByteLimit: UInt64 = Self.maximumCacheFileBytes,
        aggregateByteLimit: UInt64 = Self.maximumAggregateCacheBytes
    ) {
        self.targetImagePath = targetImagePath
        self.parser = parser
        self.machOParser = machOParser
        self.perFileByteLimit = perFileByteLimit
        self.aggregateByteLimit = aggregateByteLimit
    }

    func load(at url: URL) throws -> LoadedBinary {
        let mainURL = url.standardizedFileURL
        let mainIdentity = try Self.sourceIdentity(at: mainURL, context: "main cache")
        guard mainIdentity.byteCount <= perFileByteLimit,
              mainIdentity.byteCount <= aggregateByteLimit else {
            throw DyldSharedCacheError.malformed("main cache exceeds source byte budget")
        }
        let bytes = try Self.admittedData(
            at: mainURL,
            expectedIdentity: mainIdentity,
            maximumBytes: perFileByteLimit,
            context: "main cache"
        )
        let header = try parser.parseHeader(bytes)

        // Runtime sibling admission is fail-closed. Each declared suffix passes the same
        // canonical syntax validator used by the MachOKit preflight, and every file is opened
        // O_NOFOLLOW as a descriptor-bound regular file with both per-file and aggregate caps.
        // No pathname-derived sibling bypasses descriptor-bound admission.
        let subCacheDatas = try Self.discoverSubCaches(
            mainURL: mainURL,
            mainIdentity: mainIdentity,
            header: header,
            perFileByteLimit: perFileByteLimit,
            aggregateByteLimit: aggregateByteLimit
        )
        let remaining = aggregateByteLimit - mainIdentity.byteCount
            - subCacheDatas.values.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        let companion = Self.discoverSymbolCompanion(mainURL: mainURL, header: header,
            maximumBytes: min(perFileByteLimit, remaining))
        return try loadFromBytes(bytes, name: url.lastPathComponent, path: url.path,
            subCacheDatas: subCacheDatas, symbolCompanionData: companion?.bytes)
    }

    /// Pure, file-system-free entry point: project + load an image from in-memory cache
    /// bytes, stitching across any provided sibling sub-cache datas (`[fileSuffix: Data]`).
    /// Used by both `load(at:)` and the crafted-bytes unit tests.
    func loadFromBytes(
        _ bytes: Data,
        name: String,
        path: String,
        subCacheDatas: [String: Data] = [:],
        symbolCompanionData: Data? = nil
    ) throws -> LoadedBinary {
        let header = try parser.parseHeader(bytes)

        let image: DyldCacheImage
        if let targetImagePath {
            image = try parser.locateImage(path: targetImagePath, in: header)
        } else if let first = header.images.first(where: { !$0.path.isEmpty }) ?? header.images.first {
            image = first
        } else {
            throw DyldSharedCacheError.imageNotFound("<any>")
        }

        // Build a multi-file reader spanning the main cache + every provided sibling. When
        // no siblings are provided this collapses to the single (main) file.
        let multiReader = parser.makeMultiFileReader(
            mainBytes: bytes,
            header: header,
            subCacheDatas: subCacheDatas
        )

        try multiReader.validate()

        // The image's mach_header must be mapped by SOME file (main or a provided sibling).
        // If it is mapped nowhere, the bytes live in a sub-cache we don't have — surface
        // the clear typed `.subCacheOnly` error rather than projecting garbage.
        guard multiReader.resolve(image.address) != nil else {
            throw DyldSharedCacheError.subCacheOnly(image.path.isEmpty ? "<image>" : image.path)
        }

        let projection = try parser.projectImageWithCoverage(image, using: multiReader, header: header)
        let projected = projection.bytes

        // For a real split cache, the image's ObjC class metadata references the SHARED regions
        // (class-name/selector strings in the 123 MB `__OBJC_RO`, NOT projected per-image) and its
        // data pointers use the DYLD_CHAINED_PTR_ARM64E_SHARED_CACHE rebase encoding. Hand the ObjC
        // walker the cache base (to decode pointers) + a reader over the whole cache (to fetch the
        // shared strings on demand) so class-dump works without bloating the projected blob.
        //
        // The shared parser recovers preoptimized lists and selector/type strings. Cache-only
        // enrichment below recovers relative IMPs after checking executable mapping coverage.
        let objcCache: MachOObjCCacheContext? = header.sharedRegionStart != 0
            ? MachOObjCCacheContext(
                pointerBase: header.sharedRegionStart,
                readBytes: { vmAddress, count in
                    guard count > 0,
                          let data = multiReader.readBytesClamped(at: vmAddress, maxLength: count)
                    else { return nil }
                    return [UInt8](data)
                }
            )
            : nil
        var machO = try machOParser.parse(projected, objcCache: objcCache)
        Self.enrichSmallMethods(in: &machO, reader: multiReader, cacheBase: header.sharedRegionStart)

        let localSymbols = parser.localSymbols(for: image, header: header,
            companion: symbolCompanionData, sections: machO.sections)
        var loaded = try Self.project(
            machO: machO,
            projectedBytes: projected,
            image: image,
            cacheName: name,
            cachePath: path,
            constantCFStrings: ImageConstantStringProvider.cfStrings(in: machO, cache: multiReader),
            projection: projection,
            localSymbols: localSymbols
        )
        Self.enrichSlideTargetsAndCalls(in: &loaded, image: image, reader: multiReader,
            header: header, companion: symbolCompanionData)
        loaded.identityEffectiveByteRanges = Self.cacheIdentityRanges(for: loaded, machO: machO, reader: multiReader, projection: projection)
        return loaded
    }

    /// Opens the declared sibling set only after validating every suffix and filesystem
    /// identity. Missing or inadmissible declared files are rejected before projection; an
    /// untrusted cache cannot use a symlink, special file, replacement race, or oversized file
    /// to establish alternate byte authority.
    private static func discoverSubCaches(
        mainURL: URL,
        mainIdentity: DyldCacheFileIdentity,
        header: DyldSharedCacheHeader,
        perFileByteLimit: UInt64,
        aggregateByteLimit: UInt64
    ) throws -> [String: Data] {
        guard header.subCacheEntries.count <= DyldCacheSourcePreflight.maximumSubcacheCount else {
            throw DyldSharedCacheError.malformed("sub-cache count exceeds bound")
        }
        var datas: [String: Data] = [:]
        var aggregateBytes = mainIdentity.byteCount
        var observedSuffixes: Set<String> = []
        var observedPaths: Set<String> = [mainURL.standardizedFileURL.path]

        for entry in header.subCacheEntries {
            let suffix = entry.fileSuffix
            guard observedSuffixes.insert(suffix).inserted else {
                throw DyldSharedCacheError.malformed("duplicate sub-cache suffix '\(suffix)'")
            }
            let siblingURL: URL
            do {
                siblingURL = try DyldCacheSourceIdentityReader.safeSiblingURL(
                    mainURL: mainURL,
                    suffix: suffix
                )
            } catch {
                throw DyldSharedCacheError.malformed("unsafe sub-cache suffix '\(suffix)'")
            }
            guard observedPaths.insert(siblingURL.path).inserted else {
                throw DyldSharedCacheError.malformed("duplicate sub-cache path")
            }

            let identity = try sourceIdentity(at: siblingURL, context: "sub-cache '\(suffix)'")
            guard identity.byteCount <= perFileByteLimit else {
                throw DyldSharedCacheError.malformed("sub-cache '\(suffix)' exceeds per-file byte budget")
            }
            let addition = aggregateBytes.addingReportingOverflow(identity.byteCount)
            guard !addition.overflow, addition.partialValue <= aggregateByteLimit else {
                throw DyldSharedCacheError.malformed("aggregate cache sources exceed byte budget")
            }
            aggregateBytes = addition.partialValue
            datas[suffix] = try admittedData(
                at: siblingURL,
                expectedIdentity: identity,
                maximumBytes: perFileByteLimit,
                context: "sub-cache '\(suffix)'"
            )
        }
        return datas
    }

    /// The optional unmapped companion is admitted independently and never contributes
    /// mappings. Failure here only removes supplemental names.
    static func discoverSymbolCompanion(
        mainURL: URL, header: DyldSharedCacheHeader, maximumBytes: UInt64
    ) -> DyldCacheSymbolCompanion? {
        guard let uuid = header.symbolFileUUID,
              !header.subCacheEntries.contains(where: { $0.fileSuffix == ".symbols" }),
              let url = try? DyldCacheSourceIdentityReader.safeSiblingURL(mainURL: mainURL, suffix: ".symbols"),
              let identity = try? DyldCacheSourceIdentityReader.identity(for: url),
              identity.byteCount <= maximumBytes,
              let bytes = try? admittedData(at: url, expectedIdentity: identity,
                  maximumBytes: maximumBytes, context: "local-symbol companion"),
              DyldSharedCacheParser.cacheUUID(in: bytes) == uuid else { return nil }
        return DyldCacheSymbolCompanion(url: url, identity: identity, bytes: bytes)
    }

    /// Internal for deterministic replacement-race tests. The identity is captured before this
    /// call; `mappedData` must open the same regular file with O_NOFOLLOW or refuse it.
    static func admittedData(
        at url: URL,
        expectedIdentity: DyldCacheFileIdentity,
        maximumBytes: UInt64,
        context: String = "cache source"
    ) throws -> Data {
        do {
            return try DyldCacheSourceIdentityReader.mappedData(
                for: url,
                expectedIdentity: expectedIdentity,
                maximumBytes: maximumBytes
            )
        } catch DyldCacheAnalysisProviderError.sourceIsNotRegularFile {
            throw DyldSharedCacheError.malformed("\(context) is not a regular file")
        } catch DyldCacheAnalysisProviderError.sourceIdentityMismatch {
            throw DyldSharedCacheError.malformed("\(context) changed during admission")
        } catch DyldCacheAnalysisProviderError.sourceChangedDuringInspection {
            throw DyldSharedCacheError.malformed("\(context) changed during admission")
        } catch DyldCacheAnalysisProviderError.outputLimitExceeded {
            throw DyldSharedCacheError.malformed("\(context) exceeds source byte budget")
        } catch {
            throw DyldSharedCacheError.truncated("\(context) unreadable")
        }
    }

    private static func sourceIdentity(
        at url: URL,
        context: String
    ) throws -> DyldCacheFileIdentity {
        do {
            return try DyldCacheSourceIdentityReader.identity(for: url)
        } catch DyldCacheAnalysisProviderError.sourceIsNotRegularFile {
            throw DyldSharedCacheError.malformed("\(context) is not a regular file")
        } catch DyldCacheAnalysisProviderError.sourceChangedDuringInspection {
            throw DyldSharedCacheError.malformed("\(context) changed during admission")
        } catch {
            throw DyldSharedCacheError.truncated("\(context) unreadable")
        }
    }

    /// Projects a parsed image `MachOFile` down to `LoadedBinary`. Mirrors
    /// `MachOBinaryLoader`'s neutral translation, with the display name/path reflecting
    /// the cache origin (`<cache>(<image path>)`).
    /// A cache image's nlist table usually can't be projected: `LC_SYMTAB` indexes the cache's
    /// shared string table (about 1 GB), so it is dropped, and every function would be named
    /// `sub_…`. The image's own exports trie is small and always projected; its names (the
    /// image's real exported symbols, e.g. `_deflate`, `_inflate`) are added as export symbols at
    /// addresses no nlist symbol already names. Ordered by address, then name, so the result is
    /// deterministic; nothing is invented beyond what the trie states.
    static func namingSymbols(symbols: [SymbolSummary], exports: [(name: String, address: UInt64?)],
                              localSymbols: [SymbolSummary] = []) -> [SymbolSummary] {
        let symbols = symbols.filter { !$0.name.isEmpty }
        var named = Set(symbols.compactMap(\.address))
        var added: [SymbolSummary] = []
        for export in exports.sorted(by: { ($0.address ?? 0, $0.name) < ($1.address ?? 0, $1.name) }) {
            guard let address = export.address, !export.name.isEmpty, named.insert(address).inserted else { continue }
            added.append(SymbolSummary(id: UUID(), name: export.name, address: address,
                                       kind: MachOSymbolKind.export.rawValue, libraryName: nil,
                                       rawLinkageName: export.name))
        }
        for symbol in localSymbols.sorted(by: { ($0.address ?? 0, $0.name) < ($1.address ?? 0, $1.name) }) {
            guard let address = symbol.address, !symbol.name.isEmpty, named.insert(address).inserted else { continue }
            added.append(symbol)
        }
        return symbols + added
    }

    private static func project(
        machO: MachOFile,
        projectedBytes: Data,
        image: DyldCacheImage,
        cacheName: String,
        cachePath: String,
        constantCFStrings: [UInt64: String],
        projection: DyldCacheImageProjection,
        localSymbols: DyldCacheLocalSymbolResult
    ) throws -> LoadedBinary {
        let artifact = projection.unavailableSections.isEmpty
            ? try MachOSliceArtifactReconstructor.reconstructOrMarkUnavailableForAnonymousObject(
                machO: machO, selectedSliceBytes: projectedBytes)
            : nil
        let imageName = image.path.isEmpty
            ? cacheName
            : (image.path as NSString).lastPathComponent
        let displayPath = image.path.isEmpty ? cachePath : "\(cachePath)(\(image.path))"

        let metadata = BinaryMetadataSummary(
            uuid: machO.uuid?.stringValue,
            platformName: machO.buildVersion?.platformName ?? machO.legacyMinimumOSVersion?.platformName,
            minimumOSVersion: machO.buildVersion?.minimumOSVersion.stringValue
                ?? machO.legacyMinimumOSVersion?.minimumOSVersion.stringValue,
            sdkVersion: machO.buildVersion?.sdkVersion.stringValue
                ?? machO.legacyMinimumOSVersion?.sdkVersion.stringValue,
            buildTools: machO.buildVersion?.tools.map(\.displayName) ?? []
        )

        let symbols = Self.namingSymbols(
            symbols: machO.symbols.map { symbol in
                SymbolSummary(
                    id: UUID(),
                    name: symbol.name,
                    address: symbol.address,
                    kind: symbol.kind.rawValue,
                    libraryName: symbol.libraryName,
                    rawLinkageName: symbol.name
                )
            },
            exports: machO.exports.map { (name: $0.name, address: $0.address) },
            localSymbols: localSymbols.symbols
        )
        let imports = machO.imports.map { importedSymbol in
            ImportSummary(
                id: UUID(),
                name: importedSymbol.name,
                libraryName: importedSymbol.libraryName,
                libraryOrdinal: importedSymbol.libraryOrdinal
            )
        }
        let indirectSymbols = machO.indirectSymbols.map { indirectSymbol in
            IndirectSymbolSummary(
                id: UUID(),
                kind: indirectSymbol.kind.rawValue,
                sourceSection: indirectSymbol.sourceSection,
                address: indirectSymbol.address,
                entrySize: indirectSymbol.entrySize,
                tableIndex: indirectSymbol.tableIndex,
                rawSymbolIndex: indirectSymbol.rawSymbolIndex,
                symbolIndex: indirectSymbol.symbolIndex,
                symbolName: indirectSymbol.symbolName,
                libraryOrdinal: indirectSymbol.libraryOrdinal,
                libraryName: indirectSymbol.libraryName,
                isLocal: indirectSymbol.isLocal,
                isAbsolute: indirectSymbol.isAbsolute
            )
        }
        let exports = machO.exports.map { exportedSymbol in
            ExportSummary(
                id: UUID(),
                name: exportedSymbol.name,
                address: exportedSymbol.address,
                source: exportedSymbol.source,
                terminalFlags: exportedSymbol.flags
            )
        }
        let stringLiterals = machO.stringLiterals.map { literal in
            StringLiteralSummary(
                id: UUID(),
                value: literal.value,
                address: literal.address,
                sourceSection: literal.sourceSection,
                byteLength: literal.byteLength
            )
        }

        var objcSelectors: [UInt64: String] = [:]
        for reference in machO.objectiveCMetadata.selectorReferences {
            guard let resolvedName = reference.resolvedName, !resolvedName.isEmpty else { continue }
            objcSelectors[reference.sourceAddress] = resolvedName
        }
        let objcClassReferences = ObjCClassReferenceTarget.projection(
            of: machO.objectiveCMetadata.classReferences + machO.objectiveCMetadata.superclassReferences
        )

        var sections = machO.sections.map(Self.section)
        for unavailable in projection.unavailableSections {
            if let index = sections.firstIndex(where: { $0.name == unavailable.name && $0.address == unavailable.address }) {
                sections[index] = unavailable
            }
        }
        let preferredText = machO.executableTextSection.flatMap { preferred in
            sections.first { $0.name == preferred.qualifiedName && $0.address == preferred.address && $0.fileSize != 0 }
        }
        var findings = projection.findings + machO.loaderFindings.map(MachOBinaryLoader.loaderFinding)
        if !findings.contains(where: { $0.code == "cacheSignatureValidityUnavailable" }) {
            findings.append(LoaderFinding(category: .metadataParseIssue,
                code: "cacheSignatureValidityUnavailable", address: image.address,
                message: "Signature validity is unavailable for rewritten cache projections."))
        }
        if let reason = localSymbols.unavailableReason {
            findings.append(LoaderFinding(category: .metadataParseIssue,
                code: "cacheLocalSymbolsUnavailable", address: image.address, message: reason))
        }

        return LoadedBinary(
            name: imageName,
            path: displayPath,
            isBundle: false,
            cpuType: machO.header.cpuType,
            cpuSubtype: machO.header.cpuSubtype,
            fileTypeName: machO.fileTypeName,
            architectureDisplayName: machO.architectureDisplayName,
            metadata: metadata,
            artifactIdentity: artifact?.identity,
            preferredSegmentLayout: artifact?.preferredSegmentLayout,
            artifactIntegrityState: artifact == nil ? .unavailable : .verified,
            bytes: projectedBytes,
            sliceOffset: machO.selectedSliceOffset,
            sections: sections,
            executableTextSection: preferredText ?? sections.first { $0.isExecutable && $0.fileSize != 0 },
            codeDataRanges: machO.dataInCodeEntries.map(Self.codeDataRange),
            entryPointAddress: machO.entryPointAddress,
            symbols: symbols,
            imports: imports,
            indirectSymbols: indirectSymbols,
            exports: exports,
            stringLiterals: stringLiterals,
            functionStarts: machO.functionStarts.map(\.address),
            objcSelectors: objcSelectors,
            objcClassReferences: objcClassReferences,
            constantCFStrings: constantCFStrings,
            objcClasses: machO.objectiveCMetadata.classes,
            codePointerTargets: [],
            objcCategories: machO.objectiveCMetadata.categories,
            objcProtocols: machO.objectiveCMetadata.protocols,
            swiftTypes: machO.swiftTypes,
            swiftConformances: machO.swiftConformances,
            loaderFindings: findings,
            machOMetadata: MachOLoadMetadata(codeSignature: nil,
                importedSymbols: MachOLoadMetadata.from(machO).importedSymbols,
                dependentDylibs: MachOLoadMetadata.from(machO).dependentDylibs),
            relocations: machO.relocations.map { relocation in
                RelocationSummary(id: UUID(),
                    address: relocation.resolvedAddress ?? UInt64(relocation.relocationAddress),
                    sectionName: relocation.sourceSection, typeCode: UInt32(relocation.type),
                    typeName: nil, symbolName: relocation.symbolName, symbolIndex: relocation.symbolNumber,
                    addend: nil, isPCRelative: relocation.isPCRelative, widthInBytes: relocation.widthInBytes)
            },
            isDyldSharedCacheProjection: true
        )
    }

    private static func codeDataRange(_ entry: MachODataInCodeEntry) -> BinaryCodeDataRange {
        BinaryCodeDataRange(
            address: entry.address,
            size: UInt64(entry.length),
            kind: entry.kindName
        )
    }

    private static func section(_ section: MachOSection) -> BinarySection {
        BinarySection(
            name: section.qualifiedName,
            address: section.address,
            size: section.size,
            fileOffset: UInt64(section.fileOffset),
            isExecutable: section.isExecutableInstructions,
            isZeroFill: section.isZeroFill
        )
    }

    /// Enrich only already recovered methods, tied to their class/category and selector.
    /// Traversal pointers require mapping-version slide membership. Relative IMPs are
    /// signed field-relative values, never PAC-masked code addresses.
    private static func enrichSmallMethods(in machO: inout MachOFile,
                                          reader: MultiFileCacheReader, cacheBase: UInt64) {
        guard cacheBase != 0,
              let scoffs = machO.sections.first(where: { $0.sectionName == "__objc_scoffs" && $0.size >= 16 })
        else { return }
        func word(_ address: UInt64) -> UInt64? {
            guard let data = reader.readBytes(at: address, length: 8) else { return nil }
            return try? LittleEndianReader(data).u64(0)
        }
        func pointer(_ address: UInt64) -> UInt64? {
            let page = reader.slidePage(containing: address)
            guard page.unavailableReason == nil, let pointer = page.pointers[address],
                  pointer.target <= UInt64.max - 4096, reader.resolve(pointer.target) != nil else { return nil }
            return pointer.target
        }
        let selectorSlot = scoffs.address.addingReportingOverflow(8)
        guard !selectorSlot.overflow, let selectorBase = pointer(selectorSlot.partialValue) else { return }
        func relative(_ address: UInt64, _ delta: Int64) -> UInt64? {
            if delta >= 0 {
                let sum = address.addingReportingOverflow(UInt64(delta))
                return sum.overflow ? nil : sum.partialValue
            }
            let magnitude = UInt64(-delta)
            return address >= magnitude ? address - magnitude : nil
        }
        var remainingMethods = 65_536
        func candidates(_ list: UInt64, nested: Bool = false) -> [String: Set<UInt64>] {
            guard let data = reader.readBytes(at: list, length: 8) else { return [:] }
            let header = LittleEndianReader(data)
            guard let flags = try? header.u32(0), let count = try? header.u32(4) else { return [:] }
            if flags & 0xfffc == 8, !nested, count <= 512,
               reader.readBytes(at: list, length: 8 + UInt64(count) * 8) != nil {
                var result: [String: Set<UInt64>] = [:]
                for i in 0..<UInt64(count) {
                    let entry = list + 8 + i * 8
                    guard let raw = word(entry), let target = relative(entry, Int64(bitPattern: raw) >> 16) else { continue }
                    for (name, addresses) in candidates(target, nested: true) {
                        result[name, default: []].formUnion(addresses)
                    }
                }
                return result
            }
            guard flags & 0xc000_0000 == 0xc000_0000, flags & 0xfffc == 12, count <= 65_536,
                  Int(count) <= remainingMethods,
                  let entries = reader.readBytes(at: list, length: 8 + UInt64(count) * 12) else { return [:] }
            remainingMethods -= Int(count)
            let bytes = LittleEndianReader(entries)
            var result: [String: Set<UInt64>] = [:]
            for i in 0..<Int(count) {
                let offset = 8 + i * 12
                guard let nameOffset = try? bytes.u32(offset),
                      let delta = try? bytes.u32(offset + 8), delta != 0,
                      let imp = relative(list + UInt64(offset + 8), Int64(Int32(bitPattern: delta))),
                      let mapping = reader.files.flatMap(\.mappings).first(where: { $0.contains(imp) }),
                      mapping.initialProtection & 4 != 0,
                      reader.readBytes(at: imp, length: 4) != nil else { continue }
                let nameAddress = selectorBase.addingReportingOverflow(UInt64(nameOffset))
                guard !nameAddress.overflow,
                      let string = reader.readBytesClamped(at: nameAddress.partialValue, maxLength: 4096),
                      let end = string.firstIndex(of: 0),
                      let name = String(data: string.prefix(upTo: end), encoding: .utf8), !name.isEmpty else { continue }
                result[name, default: []].insert(imp)
            }
            return result
        }
        func enrich(_ methods: [ObjCMethod], list: UInt64?) -> [ObjCMethod] {
            guard let list else { return methods }
            let proven = candidates(list & ~7)
            return methods.map { method in
                var result = method
                if result.implementation == nil, let targets = proven[method.selector], targets.count == 1 {
                    result.implementation = targets.first
                }
                return result
            }
        }
        func methodList(_ classAddress: UInt64) -> UInt64? {
            guard let ro = pointer(classAddress + 32) else { return nil }
            return pointer((ro & ~7) + 32)
        }
        for index in machO.objectiveCMetadata.classes.indices {
            guard let address = machO.objectiveCMetadata.classes[index].address,
                  address <= UInt64.max - 40 else { continue }
            machO.objectiveCMetadata.classes[index].instanceMethods = enrich(
                machO.objectiveCMetadata.classes[index].instanceMethods, list: methodList(address))
            machO.objectiveCMetadata.classes[index].classMethods = enrich(
                machO.objectiveCMetadata.classes[index].classMethods, list: pointer(address).flatMap(methodList))
        }
        for index in machO.objectiveCMetadata.categories.indices {
            guard let address = machO.objectiveCMetadata.categories[index].address,
                  address <= UInt64.max - 32 else { continue }
            machO.objectiveCMetadata.categories[index].instanceMethods = enrich(
                machO.objectiveCMetadata.categories[index].instanceMethods, list: pointer(address + 16))
            machO.objectiveCMetadata.categories[index].classMethods = enrich(
                machO.objectiveCMetadata.categories[index].classMethods, list: pointer(address + 24))
        }
    }
}

struct DyldCacheSymbolCompanion: Sendable {
    let url: URL
    let identity: DyldCacheFileIdentity
    let bytes: Data
}


extension DyldSharedCacheBinaryLoader {
    private static func enrichSlideTargetsAndCalls(in loaded: inout LoadedBinary,
        image: DyldCacheImage, reader: MultiFileCacheReader, header: DyldSharedCacheHeader, companion: Data?) {
        var pages: [UInt64: MultiFileCacheReader.SlidePage] = [:]
        var unavailable = Set<String>()
        func page(_ address: UInt64) -> MultiFileCacheReader.SlidePage {
            let key = address & ~UInt64(4095)
            if let result = pages[key], result.unavailableReason == nil,
               result.start <= address, address - result.start < result.size { return result }
            guard pages.count < 4096 else {
                let result = MultiFileCacheReader.SlidePage(unavailableReason: "Selected-image slide-page budget exhausted.")
                unavailable.insert("Selected-image slide-page budget exhausted.")
                return result
            }
            let result = reader.slidePage(containing: address)
            pages[key] = result
            if let reason = result.unavailableReason { unavailable.insert(reason) }
            return result
        }
        func executable(_ address: UInt64) -> Bool {
            reader.files.contains { file in file.mappings.contains { $0.contains(address) && $0.initialProtection & 4 != 0 } }
        }
        var targets = Set(loaded.codePointerTargets)
        for section in loaded.sections where !section.isZeroFill && section.fileSize != 0 {
            let length = min(section.size, section.fileSize ?? section.size)
            var offset: UInt64 = 0
            while offset < length, pages.count < 4096 {
                let address = section.address.addingReportingOverflow(offset)
                guard !address.overflow else { break }
                let evidence = page(address.partialValue)
                if evidence.unavailableReason == nil {
                    for (slot, pointer) in evidence.pointers where slot >= section.address && slot - section.address < length {
                        if loaded.sections.contains(where: { $0.isExecutable && pointer.target >= $0.address
                            && pointer.target - $0.address < min($0.size, $0.fileSize ?? $0.size) }) {
                            targets.insert(pointer.target)
                        }
                    }
                }
                let step = min(length - offset, 4096 - (address.partialValue & 4095))
                offset += step
            }
            if offset < length { unavailable.insert("Selected-image slide-page budget exhausted.") }
        }
        loaded.codePointerTargets = targets.sorted()
        func word(_ address: UInt64) -> UInt32? {
            guard executable(address), !loaded.codeDataRanges.contains(where: {
                $0.size > 0 && ($0.address <= address ? address - $0.address < $0.size : $0.address - address < 4)
            }), let bytes = reader.readBytes(at: address, length: 4) else { return nil }
            return try? LittleEndianReader(bytes).u32(0)
        }
        func add(_ base: UInt64, signed: Int64) -> UInt64? {
            if signed < 0 { return base >= UInt64(-signed) ? base - UInt64(-signed) : nil }
            let result = base.addingReportingOverflow(UInt64(signed))
            return result.overflow ? nil : result.partialValue
        }
        func branch(_ address: UInt64, _ instruction: UInt32) -> UInt64? {
            let immediate = Int64(Int32(bitPattern: (instruction & 0x03ff_ffff) << 6) >> 4)
            return add(address, signed: immediate)
        }
        var owners: [UInt64: SymbolSummary] = [:]
        var queried = Set<UInt64>()
        func symbol(_ address: UInt64) -> SymbolSummary? {
            if let result = owners[address] { return result }
            guard !queried.contains(address) else { return nil }
            guard queried.count < 128 else {
                unavailable.insert("Selected-image call-target lookup budget exhausted.")
                return nil
            }
            queried.insert(address)
            let result = DyldSharedCacheParser().ownedCodeSymbol(at: address, using: reader,
                header: header, companion: companion)
            if let result { owners[address] = result }
            return result
        }
        // A bounded abstract execution of address-producing stub instructions. Registers
        // retain whether a value came from an authenticated slide slot; BR/BRAA consume it.
        func forwardedTarget(_ start: UInt64) -> UInt64? {
            var registers: [UInt32: UInt64] = [:]
            var pointers: [UInt32: (slot: UInt64, pointer: MultiFileCacheReader.SlidePointer)] = [:]
            var pc = start
            for _ in 0..<8 {
                guard let instruction = word(pc) else { return nil }
                let rd = instruction & 31, rn = (instruction >> 5) & 31
                if instruction & 0xfc00_0000 == 0x1400_0000 { return branch(pc, instruction) }
                if instruction & 0x9f00_0000 == 0x9000_0000 { // ADRP
                    let bits = ((instruction >> 5) & 0x7ffff) << 2 | ((instruction >> 29) & 3)
                    let immediate = Int64(Int32(bitPattern: bits << 11) >> 11) << 12
                    guard rd != 31, let value = add(pc & ~UInt64(4095), signed: immediate) else { return nil }
                    registers[rd] = value; pointers[rd] = nil
                } else if instruction & 0xff80_0000 == 0x9100_0000 { // ADD Xd, Xn, #imm
                    guard rd != 31, let source = registers[rn],
                          pointers[rn]?.pointer.authentication == nil else { return nil }
                    let immediate = UInt64((instruction >> 10) & 0xfff) << ((instruction >> 22) & 1 == 0 ? 0 : 12)
                    let value = source.addingReportingOverflow(immediate)
                    guard !value.overflow else { return nil }
                    registers[rd] = value.partialValue; pointers[rd] = nil
                } else if instruction & 0xffc0_0000 == 0xf940_0000 { // LDR Xt, [Xn,#imm]
                    guard rd != 31, let base = registers[rn],
                          pointers[rn]?.pointer.authentication == nil else { return nil }
                    let slot = base.addingReportingOverflow(UInt64((instruction >> 10) & 0xfff) * 8)
                    guard !slot.overflow else { return nil }
                    let evidence = page(slot.partialValue)
                    guard evidence.unavailableReason == nil, let pointer = evidence.pointers[slot.partialValue] else { return nil }
                    registers[rd] = pointer.target; pointers[rd] = (slot.partialValue, pointer)
                } else if instruction & 0xffff_fc1f == 0xd61f_0000 { // BR
                    guard let value = registers[rn], pointers[rn]?.pointer.authentication == nil else { return nil }
                    return value
                } else if instruction & 0xffff_fc00 == 0xd71f_0800 { // BRAA Xn, Xm
                    guard let loadedPointer = pointers[rn], let auth = loadedPointer.pointer.authentication,
                          auth.key == 0, auth.diversity == 0, auth.addressDiversity,
                          let modifier = registers[rd], modifier == loadedPointer.slot,
                          pointers[rd]?.pointer.authentication == nil else { return nil }
                    return loadedPointer.pointer.target
                } else if instruction != 0xd503_201f && instruction & 0xffff_fc1f != 0xd503_241f {
                    return nil // NOP and BTI may precede address production.
                }
                guard let next = add(pc, signed: 4) else { return nil }
                pc = next
            }
            return nil
        }
        func resolve(_ original: UInt64) -> SymbolSummary? {
            var current = original
            var visited = Set<UInt64>()
            for _ in 0..<8 {
                guard visited.insert(current).inserted, executable(current) else { return nil }
                if let owned = symbol(current) { return owned }
                guard let next = forwardedTarget(current) else { return nil }
                current = next
            }
            return nil
        }
        var named = Set(loaded.symbols.compactMap(\.address))
        var instructionBudget = 262_144
        for section in loaded.sections where section.isExecutable && section.fileSize != 0 {
            let length = min(section.size, section.fileSize ?? section.size)
            var offset: UInt64 = 0
            while length >= 4, offset <= length - 4, instructionBudget > 0 {
                instructionBudget -= 1
                let source = section.address.addingReportingOverflow(offset)
                guard !source.overflow else { break }
                if let instruction = word(source.partialValue), instruction & 0xfc00_0000 == 0x9400_0000,
                   let original = branch(source.partialValue, instruction), !named.contains(original),
                   let owned = resolve(original) {
                    var alias = owned
                    alias.address = original
                    loaded.symbols.append(alias)
                    named.insert(original)
                }
                offset += 4
            }
            if length >= 4, offset <= length - 4 {
                unavailable.insert("Selected-image call-naming instruction budget exhausted.")
            }
        }
        for reason in unavailable.sorted() {
            loaded.loaderFindings.append(LoaderFinding(category: .unsupportedFixup,
                code: "cacheSlideInfoUnavailable", address: image.address, message: reason))
        }
    }
}


extension DyldSharedCacheBinaryLoader {
    static func cacheIdentityRanges(for loaded: LoadedBinary, machO: MachOFile, reader: MultiFileCacheReader,
                                    projection: DyldCacheImageProjection)
        -> [IdentityEffectiveByteRangeAttestation] {
        guard loaded.isDyldSharedCacheProjection, loaded.artifactIntegrityState == .verified,
              let artifact = loaded.artifactIdentity, let layout = loaded.preferredSegmentLayout,
              machO.sections.allSatisfy({ $0.relocationCount == 0 }),
              machO.encryptionInfos.allSatisfy({ $0.cryptID == 0 }),
              machO.segments.allSatisfy({ $0.flags & MachOConstants.segmentFlagProtectedVersion1 == 0 }),
              !projection.hasFunctionVariantFixups else { return [] }
        // Chained fixups need mapping-bound slide evidence. Every emitted attestation
        // below additionally proves complete, slot-free coverage of its entire range.
        if projection.hasChainedFixups,
           !layout.records.contains(where: {
               $0.fileSize > 0 && reader.slidePage(containing: $0.preferredVMStart).unavailableReason == nil
           }) { return [] }
        var result: [IdentityEffectiveByteRangeAttestation] = []
        for record in layout.records {
            guard record.fileSize > 0, record.fileSize <= record.preferredVMSize,
                  record.initialProtections & 1 == 1, record.initialProtections & 2 == 0,
                  record.initialProtections & ~7 == 0 else { continue }
            let end = record.preferredVMStart.addingReportingOverflow(record.fileSize)
            let fileEnd = record.sliceRelativeFileOffset.addingReportingOverflow(record.fileSize)
            guard !end.overflow, !fileEnd.overflow, fileEnd.partialValue <= UInt64(loaded.bytes.count),
                  !loaded.relocations.contains(where: { relocation in
                      let relocationEnd = relocation.address.addingReportingOverflow(UInt64(relocation.widthInBytes))
                      return relocationEnd.overflow || (relocation.address < end.partialValue
                          && relocationEnd.partialValue > record.preferredVMStart)
                  }),
                  let original = reader.readBytes(at: record.preferredVMStart, length: record.fileSize),
                  let mapping = reader.files.flatMap(\.mappings).first(where: { $0.contains(record.preferredVMStart) }),
                  mapping.initialProtection & 1 == 1, mapping.initialProtection & 2 == 0,
                  record.initialProtections & 4 == 0 || mapping.initialProtection & 4 != 0 else { continue }
            let rangeBytes = loaded.bytes.subdata(in: Int(record.sliceRelativeFileOffset)..<Int(fileEnd.partialValue))
            if record.name == "__TEXT", record.initialProtections & 4 != 0,
               record.sliceRelativeFileOffset == 0, let header = projection.headerRegion,
               header.vmAddress == record.preferredVMStart {
                guard header.originalByteCount >= 32, header.originalByteCount <= record.fileSize,
                      header.originalByteCount == UInt64(header.writtenBytes.count),
                      rangeBytes.prefix(header.writtenBytes.count) == header.writtenBytes,
                      rangeBytes.dropFirst(header.writtenBytes.count) == original.dropFirst(header.writtenBytes.count)
                else { continue }
            } else {
                // Non-executable read-only segments have no header exception.
                guard rangeBytes == original else { continue }
            }
            var cursor = record.preferredVMStart
            var complete = true
            while cursor < end.partialValue {
                let page = reader.slidePage(containing: cursor)
                guard page.unavailableReason == nil, page.start <= cursor, cursor - page.start < page.size,
                      !page.pointers.keys.contains(where: { slot in
                          slot < end.partialValue && slot + 8 > record.preferredVMStart
                      }) else { complete = false; break }
                cursor += min(end.partialValue - cursor, page.size - (cursor - page.start))
            }
            guard complete, let attestation = try? IdentityEffectiveByteRangeAttestation(
                artifactIdentity: artifact, segmentName: record.name,
                startAddress: record.preferredVMStart, endAddressExclusive: end.partialValue,
                sliceRelativeFileOffset: record.sliceRelativeFileOffset, byteCount: record.fileSize,
                initialProtections: record.initialProtections,
                rawBytesSHA256: AnalysisFingerprintBuilder.sha256Hex(rangeBytes)) else { continue }
            result.append(attestation)
        }
        return result
    }
}
