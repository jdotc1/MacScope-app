import Foundation
import MachOKit

/// Worker-only adapter. MachOKit values are normalized immediately into MacScope-owned bounded
/// DTOs; no third-party type escapes this file or becomes executable-byte authority.
struct MachOKitDyldCacheAnalysisProvider: DyldCacheAnalysisWorkerProviding {
    private static let providerIdentity = DyldCacheAnalysisProviderIdentity.machOKit0522
    private static let expectedMachOKitMarkerPrefix = "MACSCOPE_MACHOKIT_BUILD_ID"
    private static let expectedMachOKitRevision =
        "773e10797abc53914b94c2ee8c6f40f5da0b06eb"
    private static let expectedMachOKitGovernedSourceIdentity =
        "b2f928cfc635b3a539129d1dbd50464c9d218c4a815553bc4b710ac813a790ea"

    func inspectCache(
        request: DyldCacheAnalysisRequest,
        cancellation: AnalysisCancellationToken
    ) throws -> DyldCacheAnalysisResult {
        let buildIdentity = MacScopeMachOKitBuildIdentity.marker.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard buildIdentity.count == 3,
              buildIdentity[0] == Self.expectedMachOKitMarkerPrefix,
              buildIdentity[1] == Self.expectedMachOKitRevision,
              buildIdentity[2] == Self.expectedMachOKitGovernedSourceIdentity else {
            throw DyldCacheAnalysisProviderError.providerUnavailable
        }
        let request = try request.validated()
        var budget = try DyldCacheInspectionBudget(
            maximumDurationMilliseconds: request.limits.maximumDurationMilliseconds,
            cancellation: cancellation
        )
        try budget.check()

        // Discover and identity-bind the exact cache file set with MacScope's existing bounded
        // parser before MachOKit opens any sibling. This preserves MacScope as path authority and
        // prevents an untrusted subcache suffix from widening filesystem access.
        let preflight = try DyldCacheSourcePreflight.inspect(
            mainURL: request.url,
            expectedMainIdentity: request.expectedSourceIdentity,
            requestedCategories: Set(request.categories),
            maximumAggregateSourceBytes: request.limits.maximumSourceBytes,
            budget: &budget
        )
        let acceptedIdentity = preflight.identities[0]
        try budget.check()

        // Parse only the main cache with MachOKit first. Validate its exact suffix sequence
        // against MacScope's bounded preflight before `FullDyldCache` can open any sibling.
        // A provider/parser disagreement therefore fails closed without widening filesystem access.
        let providerMain: DyldCache
        do {
            providerMain = try DyldCache(url: request.url.standardizedFileURL)
        } catch {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        let providerSuffixes = providerMain.subCaches?.map(\.fileSuffix) ?? []
        try preflight.validateProviderSuffixes(providerSuffixes)
        guard try preflight.recapturedIdentities() == preflight.identities else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }
        try budget.check()

        let cache: FullDyldCache
        do {
            cache = try FullDyldCache(url: request.url.standardizedFileURL)
        } catch {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        try budget.check()

        try preflight.validateProviderObservation(
            suffixes: providerSuffixes,
            openedURLs: cache.urls,
            selectedSubject: request.subject,
            budget: &budget
        )
        let fileIdentitiesBefore = preflight.identities
        try validateSelectedImage(
            request.subject.imageIdentity,
            in: cache,
            budget: &budget
        )

        var warningSink = WarningSink(maximumCount: request.limits.maximumWarnings)
        var coverage = Dictionary(
            uniqueKeysWithValues: DyldCacheAnalysisCategory.allCases.map {
                ($0, DyldCacheAnalysisCoverage(
                    category: $0,
                    status: .notRequested,
                    availableRecordCount: nil,
                    returnedRecordCount: 0
                ))
            }
        )
        let requested = Set(request.categories)

        let files = try makeFileRecords(
            cache: cache,
            identities: fileIdentitiesBefore,
            budget: &budget
        )
        let header = try makeHeader(cache: cache)

        var images: [DyldCacheImageRecord] = []
        if requested.contains(.catalog) {
            if let imageInfos = cache.imageInfos {
                images = try makeImages(
                    cache: cache,
                    maximumCount: request.limits.maximumImages,
                    budget: &budget,
                    warnings: &warningSink
                )
                let available = imageInfos.count
                coverage[.catalog] = DyldCacheAnalysisCoverage(
                    category: .catalog,
                    status: available > images.count ? .partial : .complete,
                    availableRecordCount: available,
                    returnedRecordCount: images.count
                )
                if available > images.count {
                    warningSink.append(.recordLimitReached, category: .catalog)
                }
            } else {
                coverage[.catalog] = DyldCacheAnalysisCoverage(
                    category: .catalog,
                    status: .unavailable,
                    availableRecordCount: nil,
                    returnedRecordCount: 0
                )
                warningSink.append(.requestedCategoryUnavailable, category: .catalog)
            }
        }

        var mappings: [DyldCacheMappingRecord] = []
        let mappingRequested = requested.contains(.mappings)
        let slideRequested = requested.contains(.slideInfo)
        if mappingRequested || slideRequested {
            let mappingOutput = try makeMappings(
                cache: cache,
                maximumCount: request.limits.maximumMappings,
                includeSlideInfo: slideRequested,
                budget: &budget,
                warnings: &warningSink
            )
            mappings = mappingOutput.records
            if mappingRequested {
                coverage[.mappings] = DyldCacheAnalysisCoverage(
                    category: .mappings,
                    status: mappingOutput.isAvailable
                        ? (mappingOutput.availableCount > mappings.count ? .partial : .complete)
                        : .unavailable,
                    availableRecordCount: mappingOutput.isAvailable ? mappingOutput.availableCount : nil,
                    returnedRecordCount: mappings.count
                )
                if !mappingOutput.isAvailable {
                    warningSink.append(.requestedCategoryUnavailable, category: .mappings)
                }
            }
            if slideRequested {
                let returned = mappings.filter { $0.slideInfoVersion != nil }.count
                coverage[.slideInfo] = DyldCacheAnalysisCoverage(
                    category: .slideInfo,
                    status: mappingOutput.hasSlideRecords
                        ? (mappingOutput.availableCount > mappings.count ? .partial : .complete)
                        : .unavailable,
                    availableRecordCount: mappingOutput.hasSlideRecords
                        ? mappingOutput.availableCount : nil,
                    returnedRecordCount: returned
                )
                if !mappingOutput.hasSlideRecords {
                    warningSink.append(.slideInfoUnavailable, category: .slideInfo)
                }
            }
            if mappingOutput.availableCount > mappings.count {
                warningSink.append(.recordLimitReached, category: .mappings)
            }
        }

        var localSymbols: [DyldCacheLocalSymbolRecord] = []
        if requested.contains(.localSymbols) {
            if let localSymbolsInfo = cache.localSymbolsInfo {
                let symbols = localSymbolsInfo.symbols(in: cache)
                localSymbols = try makeLocalSymbols(
                    symbols: symbols,
                    maximumCount: request.limits.maximumLocalSymbols,
                    budget: &budget,
                    warnings: &warningSink
                )
                coverage[.localSymbols] = DyldCacheAnalysisCoverage(
                    category: .localSymbols,
                    status: symbols.count > localSymbols.count ? .partial : .complete,
                    availableRecordCount: symbols.count,
                    returnedRecordCount: localSymbols.count
                )
                if symbols.count > localSymbols.count {
                    warningSink.append(.recordLimitReached, category: .localSymbols)
                }
            } else {
                coverage[.localSymbols] = DyldCacheAnalysisCoverage(
                    category: .localSymbols,
                    status: .unavailable,
                    availableRecordCount: nil,
                    returnedRecordCount: 0
                )
                warningSink.append(.localSymbolsUnavailable, category: .localSymbols)
            }
        }

        var dylibTrieEntries: [DyldCacheDylibTrieRecord] = []
        var programTrieEntries: [DyldCacheProgramTrieRecord] = []
        if requested.contains(.trieSummary) {
            try budget.check()
            let dylibs = cache.dylibIndices
            try budget.check()
            let programs = cache.programOffsets
            let available = try checkedAdd(dylibs.count, programs.count)
            let maximum = request.limits.maximumTrieEntries
            let dylibLimit = min(maximum, dylibs.count)
            dylibTrieEntries = try dylibs.prefix(dylibLimit).enumerated().map { index, entry in
                try budget.check(index: index)
                let bounded = Self.boundedString(entry.name)
                if bounded.wasTruncated {
                    warningSink.append(.stringTruncated, category: .trieSummary, recordIndex: index)
                }
                return DyldCacheDylibTrieRecord(path: bounded.value, index: entry.index)
            }.sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                return $0.index < $1.index
            }
            let remaining = max(0, maximum - dylibTrieEntries.count)
            programTrieEntries = try programs.prefix(remaining).enumerated().map { index, entry in
                try budget.check(index: index)
                let bounded = Self.boundedString(entry.name)
                if bounded.wasTruncated {
                    warningSink.append(.stringTruncated, category: .trieSummary, recordIndex: index)
                }
                return DyldCacheProgramTrieRecord(path: bounded.value, offset: entry.offset)
            }.sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                return $0.offset < $1.offset
            }
            let returned = try checkedAdd(dylibTrieEntries.count, programTrieEntries.count)
            coverage[.trieSummary] = DyldCacheAnalysisCoverage(
                category: .trieSummary,
                status: available > returned ? .partial : .complete,
                availableRecordCount: available,
                returnedRecordCount: returned
            )
            if available > returned {
                warningSink.append(.recordLimitReached, category: .trieSummary)
            }
        }

        let optimizationSummary: DyldCacheOptimizationSummary?
        if requested.contains(.optimizationSummary) {
            try budget.check()
            optimizationSummary = makeOptimizationSummary(cache: cache)
            coverage[.optimizationSummary] = DyldCacheAnalysisCoverage(
                category: .optimizationSummary,
                status: .complete,
                availableRecordCount: 1,
                returnedRecordCount: 1
            )
        } else {
            optimizationSummary = nil
        }

        let prebuiltLoaderSummary: DyldCachePrebuiltLoaderSummary?
        if requested.contains(.prebuiltLoaderSummary) {
            try budget.check()
            prebuiltLoaderSummary = makePrebuiltLoaderSummary(cache: cache)
            coverage[.prebuiltLoaderSummary] = DyldCacheAnalysisCoverage(
                category: .prebuiltLoaderSummary,
                status: .complete,
                availableRecordCount: 1,
                returnedRecordCount: 1
            )
        } else {
            prebuiltLoaderSummary = nil
        }

        try budget.check()
        try preflight.validateProviderObservation(
            suffixes: providerSuffixes,
            openedURLs: cache.urls,
            budget: &budget
        )

        let completion: DyldCacheAnalysisCompletionState = request.categories.allSatisfy {
            coverage[$0]?.status == .complete
        } ? .complete : .partial

        return DyldCacheAnalysisResult(
            version: DyldCacheAnalysisResult.schemaVersion,
            requestID: request.requestID,
            subject: request.subject,
            provider: Self.providerIdentity,
            sourceIdentity: acceptedIdentity,
            header: header,
            files: files,
            images: images,
            mappings: mappings,
            localSymbols: localSymbols,
            dylibTrieEntries: dylibTrieEntries,
            programTrieEntries: programTrieEntries,
            optimizationSummary: optimizationSummary,
            prebuiltLoaderSummary: prebuiltLoaderSummary,
            coverage: DyldCacheAnalysisCategory.allCases.compactMap { coverage[$0] },
            completion: completion,
            warnings: warningSink.values
        )
    }

    /// MachOKit opens the complete cache set, but the supplemental result is admitted for one
    /// exact selected image. Confirm that image inside the same worker-local cache lifetime before
    /// echoing the request subject across XPC.
    private func validateSelectedImage(
        _ selected: DyldCacheImageIdentity,
        in cache: FullDyldCache,
        budget: inout DyldCacheInspectionBudget
    ) throws {
        guard let imageInfos = cache.imageInfos else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        for (index, info) in imageInfos.enumerated() {
            try budget.check(index: index)
            guard info.layout.address == selected.loadAddress else { continue }
            if info.path(in: cache) == selected.path { return }
        }
        throw DyldCacheAnalysisProviderError.subjectIdentityMismatch
    }

    private func makeFileRecords(
        cache: FullDyldCache,
        identities: [DyldCacheFileIdentity],
        budget: inout DyldCacheInspectionBudget
    ) throws -> [DyldCacheFileRecord] {
        guard cache.urls.count == identities.count else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }
        return try zip(cache.urls.indices, zip(cache.urls, identities)).map { index, pair in
            try budget.check(index: index)
            let (url, identity) = pair
            let suffix = index == 0 ? nil : cache.subCacheSuffixes[safe: index - 1]
            let role: DyldCacheFileRole
            if index == 0 {
                role = .main
            } else if suffix == ".symbols" {
                role = .symbols
            } else if suffix != nil {
                role = .subcache
            } else {
                role = .other
            }
            return DyldCacheFileRecord(
                index: index,
                role: role,
                displayName: Self.boundedString(url.lastPathComponent).value,
                suffix: suffix,
                identity: identity
            )
        }
    }

    private func makeHeader(cache: FullDyldCache) throws -> DyldCacheHeaderRecord {
        guard let cacheType = cache.header.cacheType else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        let magic = cache.header.magic
        let architecture = magic
            .dropFirst("dyld_v1".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let symbolUUID = cache.header.symbolFileUUID.uuidString.lowercased()
        return DyldCacheHeaderRecord(
            magic: magic,
            architecture: architecture,
            uuid: cache.header.uuid.uuidString.lowercased(),
            symbolFileUUID: symbolUUID == "00000000-0000-0000-0000-000000000000" ? nil : symbolUUID,
            cacheTypeRawValue: cacheType.rawValue,
            cacheSubTypeRawValue: cache.header.cacheSubType?.rawValue,
            platformRawValue: cache.header.platform.rawValue,
            platformName: cache.header.platform.description,
            isSimulator: cache.header.isSimulator,
            osVersion: cache.header.osVersion.description,
            imageCount: cache.header.imagesCount
        )
    }

    private func makeImages(
        cache: FullDyldCache,
        maximumCount: Int,
        budget: inout DyldCacheInspectionBudget,
        warnings: inout WarningSink
    ) throws -> [DyldCacheImageRecord] {
        guard let imageInfos = cache.imageInfos else { return [] }
        var records: [DyldCacheImageRecord] = []
        records.reserveCapacity(min(maximumCount, imageInfos.count))
        for (index, info) in imageInfos.prefix(maximumCount).enumerated() {
            try budget.check(index: index)
            guard let path = info.path(in: cache) else {
                warnings.append(.imagePathUnavailable, category: .catalog, recordIndex: index)
                continue
            }
            let bounded = Self.boundedString(path)
            if bounded.wasTruncated {
                warnings.append(.stringTruncated, category: .catalog, recordIndex: index)
            }
            let fileOffset = cache.fileOffset(of: info.layout.address)
            if fileOffset == nil {
                warnings.append(.imageFileOffsetUnavailable, category: .catalog, recordIndex: index)
            }
            records.append(DyldCacheImageRecord(
                path: bounded.value,
                loadAddress: info.layout.address,
                headerFileOffset: fileOffset,
                sourceFileIndex: fileOffset.flatMap { sourceFileIndex(cache: cache, fileOffset: $0) },
                modificationTime: info.layout.modTime,
                inode: info.layout.inode
            ))
        }
        return records.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.loadAddress < $1.loadAddress
        }
    }

    private struct MappingOutput {
        let records: [DyldCacheMappingRecord]
        let availableCount: Int
        let isAvailable: Bool
        let hasSlideRecords: Bool
    }

    private func makeMappings(
        cache: FullDyldCache,
        maximumCount: Int,
        includeSlideInfo: Bool,
        budget: inout DyldCacheInspectionBudget,
        warnings: inout WarningSink
    ) throws -> MappingOutput {
        if let source = cache.mappingAndSlideInfos {
            var records: [DyldCacheMappingRecord] = []
            records.reserveCapacity(min(maximumCount, source.count))
            for (index, mapping) in source.prefix(maximumCount).enumerated() {
                try budget.check(index: index)
                let version = includeSlideInfo ? mapping.slideInfoVersion(in: cache)?.rawValue : nil
                if includeSlideInfo, mapping.layout.slideInfoFileOffset > 0, version == nil {
                    warnings.append(.slideInfoUnavailable, category: .slideInfo, recordIndex: index)
                }
                records.append(DyldCacheMappingRecord(
                    name: mapping.mappingName,
                    address: mapping.layout.address,
                    size: mapping.layout.size,
                    fileOffset: mapping.layout.fileOffset,
                    sourceFileIndex: sourceFileIndex(cache: cache, fileOffset: mapping.layout.fileOffset),
                    maximumProtection: mapping.layout.maxProt,
                    initialProtection: mapping.layout.initProt,
                    flags: mapping.flags.rawValue,
                    slideInfoFileOffset: mapping.layout.slideInfoFileOffset == 0
                        ? nil : mapping.layout.slideInfoFileOffset,
                    slideInfoByteCount: mapping.layout.slideInfoFileSize == 0
                        ? nil : mapping.layout.slideInfoFileSize,
                    slideInfoVersion: version
                ))
            }
            return MappingOutput(
                records: Self.sortedMappings(records),
                availableCount: source.count,
                isAvailable: true,
                hasSlideRecords: source.contains { $0.layout.slideInfoFileOffset > 0 }
            )
        }

        guard let source = cache.mappingInfos else {
            return MappingOutput(
                records: [],
                availableCount: 0,
                isAvailable: false,
                hasSlideRecords: false
            )
        }
        let records = try source.prefix(maximumCount).enumerated().map { index, mapping in
            try budget.check(index: index)
            return DyldCacheMappingRecord(
                name: nil,
                address: mapping.layout.address,
                size: mapping.layout.size,
                fileOffset: mapping.layout.fileOffset,
                sourceFileIndex: sourceFileIndex(cache: cache, fileOffset: mapping.layout.fileOffset),
                maximumProtection: mapping.layout.maxProt,
                initialProtection: mapping.layout.initProt,
                flags: 0,
                slideInfoFileOffset: nil,
                slideInfoByteCount: nil,
                slideInfoVersion: nil
            )
        }
        return MappingOutput(
            records: Self.sortedMappings(records),
            availableCount: source.count,
            isAvailable: true,
            hasSlideRecords: false
        )
    }

    private func makeLocalSymbols(
        symbols: AnyRandomAccessCollection<MachOKit.MachOFile.Symbol>,
        maximumCount: Int,
        budget: inout DyldCacheInspectionBudget,
        warnings: inout WarningSink
    ) throws -> [DyldCacheLocalSymbolRecord] {
        var records: [DyldCacheLocalSymbolRecord] = []
        records.reserveCapacity(min(maximumCount, symbols.count))
        for (index, symbol) in symbols.prefix(maximumCount).enumerated() {
            try budget.check(index: index)
            guard symbol.offset >= 0 else { continue }
            let bounded = Self.boundedString(symbol.name)
            if bounded.wasTruncated {
                warnings.append(.stringTruncated, category: .localSymbols, recordIndex: index)
            }
            records.append(DyldCacheLocalSymbolRecord(
                name: bounded.value,
                value: UInt64(symbol.offset),
                sectionNumber: symbol.nlist.sectionNumber,
                flags: symbol.nlist.flags.map { UInt32(bitPattern: $0.rawValue) }
            ))
        }
        return records.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.name < $1.name
        }
    }

    private func makeOptimizationSummary(cache: FullDyldCache) -> DyldCacheOptimizationSummary {
        let objc = cache.objcOptimization
        let swift = cache.swiftOptimization
        return DyldCacheOptimizationSummary(
            hasObjectiveCOptimization: objc != nil,
            objectiveCVersion: objc?.layout.version,
            objectiveCFlags: objc?.flags.rawValue,
            // Legacy discovery walks a Mach-O image and load-command graph through additional
            // nonthrowing vendor reads. It is supplemental, so remain conservative instead of
            // widening the admitted hostile-input surface merely to report this optional bit.
            hasLegacyObjectiveCOptimization: false,
            hasSwiftOptimization: swift != nil,
            swiftVersion: swift?.layout.version,
            tproMappingCount: cache.tproMappings?.count ?? 0,
            functionVariantCount: cache.functionVariantInfo.map { Int($0.layout.count) } ?? 0,
            prewarmingEntryCount: cache.prewarmingData.map { Int($0.layout.count) } ?? 0
        )
    }

    private func makePrebuiltLoaderSummary(cache: FullDyldCache) -> DyldCachePrebuiltLoaderSummary {
        guard let loaderSet = cache.dylibsPrebuiltLoaderSet else {
            return DyldCachePrebuiltLoaderSummary(
                isPresent: false,
                magic: nil,
                versionHash: nil,
                isKnownVersion: false,
                loaderCount: 0,
                missingPathCount: nil
            )
        }
        return DyldCachePrebuiltLoaderSummary(
            isPresent: true,
            magic: loaderSet.magic,
            versionHash: loaderSet.layout.versionHash,
            isKnownVersion: loaderSet.isKnownVersion,
            loaderCount: Int(loaderSet.layout.loadersArrayCount),
            missingPathCount: Int(loaderSet.layout.mustBeMissingPathsCount)
        )
    }

    private func sourceFileIndex(cache: FullDyldCache, fileOffset: UInt64) -> Int? {
        guard let url = cache.url(forFileOffset: fileOffset) else { return nil }
        return cache.urls.firstIndex(of: url)
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw DyldCacheAnalysisProviderError.outputLimitExceeded }
        return result
    }

    private static func sortedMappings(_ records: [DyldCacheMappingRecord]) -> [DyldCacheMappingRecord] {
        records.sorted {
            if $0.address != $1.address { return $0.address < $1.address }
            if $0.size != $1.size { return $0.size < $1.size }
            return $0.fileOffset < $1.fileOffset
        }
    }

    private static func boundedString(_ value: String, maximumUTF8Bytes: Int = 4_096) -> (
        value: String,
        wasTruncated: Bool
    ) {
        guard value.utf8.count > maximumUTF8Bytes else { return (value, false) }
        var end = value.startIndex
        var bytes = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let width = value[end..<next].utf8.count
            if bytes + width > maximumUTF8Bytes { break }
            bytes += width
            end = next
        }
        return (String(value[..<end]), true)
    }
}

private struct WarningSink {
    private let maximumCount: Int
    private(set) var values: [DyldCacheAnalysisWarning] = []

    init(maximumCount: Int) {
        self.maximumCount = maximumCount
    }

    mutating func append(
        _ code: DyldCacheAnalysisWarningCode,
        category: DyldCacheAnalysisCategory,
        recordIndex: Int? = nil
    ) {
        guard values.count < maximumCount else { return }
        values.append(DyldCacheAnalysisWarning(
            code: code,
            category: category,
            recordIndex: recordIndex
        ))
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
