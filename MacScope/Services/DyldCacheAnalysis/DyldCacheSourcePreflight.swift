import Foundation

enum DyldCachePathReopenAssurance: String, Codable, Equatable, Sendable {
    /// MacScope's preflight is descriptor-bound. The provider still accepts URLs, so identities
    /// must be recaptured after its pathname reopen before any result is accepted.
    case identityRecaptureRequired
}

struct DyldCacheSourcePreflightResult: Sendable {
    let header: DyldSharedCacheHeader
    let urls: [URL]
    let suffixes: [String?]
    let identities: [DyldCacheFileIdentity]
    let contentSeals: [DyldCacheSourceContentSeal]
    let pathReopenAssurance: DyldCachePathReopenAssurance
    // Kept outside provider URLs/suffixes: this file has no mapped image authority.
    var symbolCompanion: DyldCacheSymbolCompanion? = nil

    func validateProviderSuffixes(_ providerSuffixes: [String]) throws {
        let expected = suffixes.dropFirst().compactMap { $0 }
        guard providerSuffixes.count <= DyldCacheSourcePreflight.maximumSubcacheCount,
              providerSuffixes == expected else {
            throw DyldCacheAnalysisProviderError.sourceIdentityMismatch
        }
        var observed: Set<String> = []
        for suffix in providerSuffixes {
            guard observed.insert(suffix).inserted else {
                throw DyldCacheAnalysisProviderError.providerRejectedInput
            }
            _ = try DyldCacheSourceIdentityReader.safeSiblingURL(mainURL: urls[0], suffix: suffix)
        }
    }

    func validateOpenedURLs(_ openedURLs: [URL]) throws {
        guard openedURLs.map({ $0.standardizedFileURL.path })
                == urls.map({ $0.standardizedFileURL.path }) else {
            throw DyldCacheAnalysisProviderError.sourceIdentityMismatch
        }
    }

    func recapturedIdentities() throws -> [DyldCacheFileIdentity] {
        try urls.map(DyldCacheSourceIdentityReader.identity(for:))
    }

    private func recapturedSources(
        budget: inout DyldCacheInspectionBudget
    ) throws -> (
        data: [Data],
        seals: [DyldCacheSourceContentSeal]
    ) {
        guard urls.count == identities.count else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }
        var data: [Data] = []
        var seals: [DyldCacheSourceContentSeal] = []
        data.reserveCapacity(urls.count)
        seals.reserveCapacity(urls.count)
        for index in urls.indices {
            let observed: (data: Data, seal: DyldCacheSourceContentSeal)
            do {
                observed = try DyldCacheSourceIdentityReader.sealedMappedData(
                    for: urls[index],
                    expectedIdentity: identities[index],
                    maximumBytes: identities[index].byteCount,
                    budget: &budget
                )
            } catch DyldCacheAnalysisProviderError.sourceIdentityMismatch {
                // Admission succeeded earlier. Any later identity mismatch is temporal source
                // drift, not an invalid caller-supplied expected identity.
                throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
            }
            data.append(observed.data)
            seals.append(observed.seal)
        }
        return (data, seals)
    }

    /// One fail-closed post-open check for worker adapters. The provider still owns its mapped
    /// object lifetime; this only proves that its reported path set remained the admitted set and
    /// that every path still resolves to the same filesystem identity and content seal after
    /// inspection.
    func validateProviderObservation(
        suffixes providerSuffixes: [String],
        openedURLs: [URL],
        selectedSubject: DyldCacheAnalysisSubjectIdentity? = nil
    ) throws {
        var budget = try DyldCacheInspectionBudget(
            maximumDurationMilliseconds: DyldCacheAnalysisLimits.hardMaximum.maximumDurationMilliseconds,
            cancellation: .never
        )
        try validateProviderObservation(
            suffixes: providerSuffixes,
            openedURLs: openedURLs,
            selectedSubject: selectedSubject,
            budget: &budget
        )
    }

    func validateProviderObservation(
        suffixes providerSuffixes: [String],
        openedURLs: [URL],
        selectedSubject: DyldCacheAnalysisSubjectIdentity? = nil,
        budget: inout DyldCacheInspectionBudget
    ) throws {
        try budget.check()
        try validateProviderSuffixes(providerSuffixes)
        try validateOpenedURLs(openedURLs)
        let recaptured = try recapturedSources(budget: &budget)
        guard recaptured.seals == contentSeals else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }
        if let selectedSubject {
            try validateSelectedArtifact(
                selectedSubject,
                recapturedData: recaptured.data,
                parser: DyldSharedCacheParser(),
                budget: &budget
            )
            let afterProjection = try recapturedSources(budget: &budget)
            guard afterProjection.seals == contentSeals else {
                throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
            }
        }
    }

    /// Reconstructs the selected thin Mach-O with MacScope's authoritative cache projector and
    /// hashes those bytes independently of both MachOKit and the request. This prevents the worker
    /// from merely echoing a caller-supplied selected-slice SHA-256 as supplemental authority.
    func validateSelectedArtifact(
        _ subject: DyldCacheAnalysisSubjectIdentity,
        parser: DyldSharedCacheParser = DyldSharedCacheParser()
    ) throws {
        var budget = try DyldCacheInspectionBudget(
            maximumDurationMilliseconds: DyldCacheAnalysisLimits.hardMaximum.maximumDurationMilliseconds,
            cancellation: .never
        )
        try validateSelectedArtifact(subject, parser: parser, budget: &budget)
    }

    func validateSelectedArtifact(
        _ subject: DyldCacheAnalysisSubjectIdentity,
        parser: DyldSharedCacheParser = DyldSharedCacheParser(),
        budget: inout DyldCacheInspectionBudget
    ) throws {
        let recaptured = try recapturedSources(budget: &budget)
        guard recaptured.seals == contentSeals else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }
        try validateSelectedArtifact(
            subject,
            recapturedData: recaptured.data,
            parser: parser,
            budget: &budget
        )
        let afterProjection = try recapturedSources(budget: &budget)
        guard afterProjection.seals == contentSeals else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }
    }

    private func validateSelectedArtifact(
        _ subject: DyldCacheAnalysisSubjectIdentity,
        recapturedData: [Data],
        parser: DyldSharedCacheParser,
        budget: inout DyldCacheInspectionBudget
    ) throws {
        try budget.check()
        guard let mainBytes = recapturedData.first else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }

        let currentHeader: DyldSharedCacheHeader
        do {
            currentHeader = try parser.parseHeader(mainBytes)
        } catch {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        guard let selected = currentHeader.images.first(where: {
            $0.path == subject.imageIdentity.path
                && $0.address == subject.imageIdentity.loadAddress
        }) else {
            throw DyldCacheAnalysisProviderError.subjectIdentityMismatch
        }

        var subcacheData: [String: Data] = [:]
        for index in recapturedData.indices.dropFirst() {
            guard let suffix = suffixes[index] else {
                throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
            }
            subcacheData[suffix] = recapturedData[index]
        }
        let reader = parser.makeMultiFileReader(
            mainBytes: mainBytes,
            header: currentHeader,
            subCacheDatas: subcacheData
        )
        let projected: Data
        do {
            try budget.check()
            projected = try parser.projectImage(selected, using: reader, header: currentHeader)
            try budget.check()
        } catch {
            if error is AnalysisCancelled
                || error as? DyldCacheAnalysisProviderError == .timeout {
                throw error
            }
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        let digest = try DyldCacheSourceIdentityReader.sha256Hex(projected, budget: &budget)
        guard UInt64(projected.count) == subject.artifactIdentity.selectedSliceByteCount,
              digest == subject.artifactIdentity.selectedSliceSHA256 else {
            throw DyldCacheAnalysisProviderError.subjectIdentityMismatch
        }
    }
}

enum DyldCacheSourcePreflight {
    static let maximumSubcacheCount = 128
    static let maximumCacheFileCount = maximumSubcacheCount + 1
    static let maximumDeclaredImageCount = 1_000_000
    static let maximumDeclaredMappingCount = 16_384

    static func inspect(
        mainURL: URL,
        expectedMainIdentity: DyldCacheFileIdentity,
        requestedCategories: Set<DyldCacheAnalysisCategory> = [],
        maximumAggregateSourceBytes: UInt64 = DyldCacheAnalysisLimits.hardMaximum.maximumSourceBytes,
        parser: DyldSharedCacheParser = DyldSharedCacheParser()
    ) throws -> DyldCacheSourcePreflightResult {
        var budget = try DyldCacheInspectionBudget(
            maximumDurationMilliseconds: DyldCacheAnalysisLimits.hardMaximum.maximumDurationMilliseconds,
            cancellation: .never
        )
        return try inspect(
            mainURL: mainURL,
            expectedMainIdentity: expectedMainIdentity,
            requestedCategories: requestedCategories,
            maximumAggregateSourceBytes: maximumAggregateSourceBytes,
            parser: parser,
            budget: &budget
        )
    }

    static func inspect(
        mainURL: URL,
        expectedMainIdentity: DyldCacheFileIdentity,
        requestedCategories: Set<DyldCacheAnalysisCategory> = [],
        maximumAggregateSourceBytes: UInt64 = DyldCacheAnalysisLimits.hardMaximum.maximumSourceBytes,
        parser: DyldSharedCacheParser = DyldSharedCacheParser(),
        budget: inout DyldCacheInspectionBudget
    ) throws -> DyldCacheSourcePreflightResult {
        try budget.check()
        let mainURL = mainURL.standardizedFileURL
        let sealedMain = try DyldCacheSourceIdentityReader.sealedMappedData(
            for: mainURL,
            expectedIdentity: expectedMainIdentity,
            maximumBytes: maximumAggregateSourceBytes,
            budget: &budget
        )
        let mainBytes = sealedMain.data
        let header: DyldSharedCacheHeader
        do {
            header = try parser.parseHeader(mainBytes)
        } catch {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        try budget.check()

        guard header.subCacheEntries.count <= maximumSubcacheCount,
              header.subCacheEntries.count + 1 <= maximumCacheFileCount,
              header.images.count <= maximumDeclaredImageCount,
              header.mappings.count <= maximumDeclaredMappingCount else {
            throw DyldCacheAnalysisProviderError.outputLimitExceeded
        }
        try validateMachOKitReadSurface(
            bytes: mainBytes,
            parsedHeader: header,
            requestedCategories: requestedCategories.subtracting([
                .trieSummary, .optimizationSummary, .prebuiltLoaderSummary,
            ]),
            isMainCache: true
        )
        try budget.check()

        var urls = [mainURL]
        var suffixes: [String?] = [nil]
        var seenPaths: Set<String> = [mainURL.path]
        var seenSuffixes: Set<String> = []
        for (index, entry) in header.subCacheEntries.enumerated() {
            try budget.check(index: index << 8)
            let suffix = entry.fileSuffix
            guard seenSuffixes.insert(suffix).inserted else {
                throw DyldCacheAnalysisProviderError.providerRejectedInput
            }
            let sibling = try DyldCacheSourceIdentityReader.safeSiblingURL(
                mainURL: mainURL,
                suffix: suffix
            )
            guard seenPaths.insert(sibling.path).inserted else {
                throw DyldCacheAnalysisProviderError.providerRejectedInput
            }
            urls.append(sibling)
            suffixes.append(suffix)
        }

        let identities = try urls.map(DyldCacheSourceIdentityReader.identity(for:))
        guard identities.first == expectedMainIdentity else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }
        var aggregate: UInt64 = 0
        for identity in identities {
            try budget.check()
            let addition = aggregate.addingReportingOverflow(identity.byteCount)
            guard !addition.overflow, addition.partialValue <= maximumAggregateSourceBytes else {
                throw DyldCacheAnalysisProviderError.outputLimitExceeded
            }
            aggregate = addition.partialValue
        }

        // MachOKit evaluates slide/local-symbol metadata on every cache file. Admit every sibling
        // through the same bounded raw-field checks before the vendor object can reach a `try!`
        // read. Catalog/trie/optimization/prebuilt authority remains on the main cache.
        var contentSeals = [sealedMain.seal]
        var admittedMappings = header.mappings
        for index in urls.indices.dropFirst() {
            try budget.check()
            let sealed = try DyldCacheSourceIdentityReader.sealedMappedData(
                for: urls[index],
                expectedIdentity: identities[index],
                maximumBytes: maximumAggregateSourceBytes,
                budget: &budget
            )
            let bytes = sealed.data
            contentSeals.append(sealed.seal)
            let siblingHeader: DyldSharedCacheHeader
            do {
                siblingHeader = try parser.parseHeader(bytes)
            } catch {
                throw DyldCacheAnalysisProviderError.providerRejectedInput
            }
            guard siblingHeader.uuid == header.subCacheEntries[index - 1].uuid else {
                throw DyldCacheAnalysisProviderError.sourceIdentityMismatch
            }
            admittedMappings.append(contentsOf: siblingHeader.mappings)
            try validateMachOKitReadSurface(
                bytes: bytes,
                parsedHeader: siblingHeader,
                requestedCategories: requestedCategories,
                isMainCache: false
            )
        }
        try validateMachOKitReadSurface(
            bytes: mainBytes,
            parsedHeader: header,
            requestedCategories: requestedCategories,
            isMainCache: true,
            admittedMappings: admittedMappings
        )
        try budget.check()

        guard MultiFileCacheReader.mappingError(admittedMappings) == nil else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        let companion = DyldSharedCacheBinaryLoader.discoverSymbolCompanion(
            mainURL: mainURL, header: header, maximumBytes: maximumAggregateSourceBytes - aggregate)
        return DyldCacheSourcePreflightResult(
            header: header,
            urls: urls,
            suffixes: suffixes,
            identities: identities,
            contentSeals: contentSeals,
            pathReopenAssurance: .identityRecaptureRequired,
            symbolCompanion: companion
        )
    }

    /// Mirrors only the raw ranges that the pinned MachOKit 0.52.2 getters read through
    /// nonthrowing/`try!` helpers. It deliberately does not interpret vendor models.
    static func validateMachOKitReadSurface(
        bytes: Data,
        parsedHeader: DyldSharedCacheHeader,
        requestedCategories: Set<DyldCacheAnalysisCategory>,
        isMainCache: Bool,
        admittedMappings: [DyldCacheMapping]? = nil
    ) throws {
        let reader = AdmissionReader(bytes)
        let headerSize = Int(parsedHeader.mappingOffset)

        func propertyPresent(_ end: Int) -> Bool { headerSize >= end && bytes.count >= end }
        func requireRange(offset: UInt64, size: UInt64) throws {
            guard offset <= UInt64(bytes.count), size <= UInt64(bytes.count),
                  offset <= UInt64(bytes.count) - size else {
                throw DyldCacheAnalysisProviderError.providerRejectedInput
            }
        }
        func requireArray(offset: UInt64, count: UInt64, stride: UInt64) throws {
            let (size, overflow) = count.multipliedReportingOverflow(by: stride)
            guard !overflow else { throw DyldCacheAnalysisProviderError.providerRejectedInput }
            try requireRange(offset: offset, size: size)
        }
        func requireMapped(address: UInt64, size: UInt64) throws {
            let mappings = admittedMappings ?? parsedHeader.mappings
            guard size == 0 || mappings.contains(where: { mapping in
                guard address >= mapping.address else { return false }
                let delta = address - mapping.address
                return delta <= mapping.size && size <= mapping.size - delta
            }) else {
                throw DyldCacheAnalysisProviderError.providerRejectedInput
            }
        }

        if isMainCache {
            if !requestedCategories.isEmpty {
                // MachOKit always consumes the modern image fields. Do not let MacScope fall back
                // to a valid legacy/text array while its modern array is malformed.
                guard propertyPresent(0x1c8) else {
                    throw DyldCacheAnalysisProviderError.providerRejectedInput
                }
                let imagesOffset = try reader.u32(0x1c0)
                let imagesCount = try reader.u32(0x1c4)
                guard imagesOffset == parsedHeader.imagesOffset,
                      imagesCount == parsedHeader.imagesCount,
                      imagesCount <= UInt32(maximumDeclaredImageCount) else {
                    throw DyldCacheAnalysisProviderError.providerRejectedInput
                }
                try requireArray(
                    offset: UInt64(imagesOffset), count: UInt64(imagesCount), stride: 32
                )
            }
            if parsedHeader.subCacheArrayCount > 0 {
                guard propertyPresent(0x190),
                      try reader.u32(0x188) == parsedHeader.subCacheArrayOffset,
                      try reader.u32(0x18c) == parsedHeader.subCacheArrayCount else {
                    throw DyldCacheAnalysisProviderError.providerRejectedInput
                }
                // The pinned package currently reads `general` bytes even for v1 records before
                // decoding the selected stride. Bound that exact read to prevent an upstream trap.
                try requireArray(
                    offset: UInt64(parsedHeader.subCacheArrayOffset),
                    count: UInt64(parsedHeader.subCacheArrayCount),
                    stride: 56
                )
                guard propertyPresent(0x1cc) == parsedHeader.usesV2SubCacheEntries else {
                    throw DyldCacheAnalysisProviderError.providerRejectedInput
                }
            }
        }

        if requestedCategories.contains(.mappings) || requestedCategories.contains(.slideInfo) {
            if propertyPresent(0x140) {
                let offset = UInt64(try reader.u32(0x138))
                let count = UInt64(try reader.u32(0x13c))
                try requireArray(
                    offset: offset,
                    count: count,
                    stride: 56
                )
                for index in 0..<Int(count) {
                    let recordOffset = Int(offset) + index * 56
                    let slideOffset = try reader.u64(recordOffset + 24)
                    let slideSize = try reader.u64(recordOffset + 32)
                    if slideSize > 0 {
                        guard slideSize >= 4 else {
                            throw DyldCacheAnalysisProviderError.providerRejectedInput
                        }
                        try requireRange(offset: slideOffset, size: slideSize)
                    }
                }
            }
        }

        if requestedCategories.contains(.localSymbols), propertyPresent(0x58) {
            let offset = try reader.u64(0x48)
            let size = try reader.u64(0x50)
            if size > 0 {
                guard size >= 24 else { throw DyldCacheAnalysisProviderError.providerRejectedInput }
                try requireRange(offset: offset, size: size)
                let nlistOffset = UInt64(try reader.u32(Int(offset)))
                let nlistCount = UInt64(try reader.u32(Int(offset) + 4))
                let stringsOffset = UInt64(try reader.u32(Int(offset) + 8))
                let stringsSize = UInt64(try reader.u32(Int(offset) + 12))
                let nlistStride: UInt64 = parsedHeader.architecture.contains("64") ? 16 : 12
                let (nlistBytes, nlistOverflow) = nlistCount.multipliedReportingOverflow(
                    by: nlistStride
                )
                guard !nlistOverflow,
                      nlistOffset <= size, nlistBytes <= size - nlistOffset,
                      stringsOffset <= size, stringsSize <= size - stringsOffset else {
                    throw DyldCacheAnalysisProviderError.providerRejectedInput
                }
                let (nlistFileOffset, nlistFileOverflow) = offset.addingReportingOverflow(
                    nlistOffset
                )
                let (stringsFileOffset, stringsFileOverflow) = offset.addingReportingOverflow(
                    stringsOffset
                )
                guard !nlistFileOverflow, !stringsFileOverflow else {
                    throw DyldCacheAnalysisProviderError.providerRejectedInput
                }
                try requireRange(offset: nlistFileOffset, size: nlistBytes)
                try requireRange(offset: stringsFileOffset, size: stringsSize)
            }
        }

        if isMainCache && requestedCategories.contains(.trieSummary) {
            if propertyPresent(0x118) {
                try requireMapped(address: try reader.u64(0x108), size: try reader.u64(0x110))
            }
            if propertyPresent(0x16c) {
                try requireMapped(
                    address: try reader.u64(0x160),
                    size: UInt64(try reader.u32(0x168))
                )
            }
        }

        if isMainCache && requestedCategories.contains(.optimizationSummary) {
            let sharedRegionStart = parsedHeader.sharedRegionStart
            if propertyPresent(0x188) {
                for (offsetField, sizeField) in [(0x178, 0x180)] {
                    let offset = try reader.u64(offsetField)
                    let size = try reader.u64(sizeField)
                    if size > 0 {
                        guard size >= 16 else {
                            throw DyldCacheAnalysisProviderError.providerRejectedInput
                        }
                        let (address, overflow) = sharedRegionStart.addingReportingOverflow(offset)
                        guard !overflow else { throw DyldCacheAnalysisProviderError.providerRejectedInput }
                        try requireMapped(address: address, size: size)
                    }
                }
            }
            if propertyPresent(0x1e0) {
                let offset = try reader.u64(0x1d0)
                let size = try reader.u64(0x1d8)
                if size > 0 {
                    guard size >= 16 else {
                        throw DyldCacheAnalysisProviderError.providerRejectedInput
                    }
                    let (address, overflow) = sharedRegionStart.addingReportingOverflow(offset)
                    guard !overflow else { throw DyldCacheAnalysisProviderError.providerRejectedInput }
                    try requireMapped(address: address, size: size)
                }
            }
            if propertyPresent(0x208) {
                let relativeOffset = UInt64(try reader.u32(0x200))
                let count = UInt64(try reader.u32(0x204))
                guard count <= UInt64(maximumDeclaredMappingCount) else {
                    throw DyldCacheAnalysisProviderError.outputLimitExceeded
                }
                let (address, overflow) = sharedRegionStart.addingReportingOverflow(relativeOffset)
                let (size, sizeOverflow) = count.multipliedReportingOverflow(by: 16)
                guard !overflow, !sizeOverflow else {
                    throw DyldCacheAnalysisProviderError.providerRejectedInput
                }
                try requireMapped(address: address, size: size)
            }
            if propertyPresent(0x218) {
                let size = try reader.u64(0x210)
                if size > 0 {
                    guard size >= 16 else {
                        throw DyldCacheAnalysisProviderError.providerRejectedInput
                    }
                    try requireMapped(address: try reader.u64(0x208), size: size)
                }
            }
            if propertyPresent(0x228) {
                let relativeOffset = try reader.u64(0x218)
                let size = try reader.u64(0x220)
                if size > 0 {
                    guard size >= 16 else {
                        throw DyldCacheAnalysisProviderError.providerRejectedInput
                    }
                    let (address, overflow) = sharedRegionStart.addingReportingOverflow(relativeOffset)
                    guard !overflow else {
                        throw DyldCacheAnalysisProviderError.providerRejectedInput
                    }
                    try requireMapped(address: address, size: size)
                }
            }
        }

        if isMainCache && requestedCategories.contains(.prebuiltLoaderSummary), propertyPresent(0x160) {
            let address = try reader.u64(0x148)
            if address > 0 { try requireMapped(address: address, size: 32) }
            try requireMapped(address: try reader.u64(0x150), size: try reader.u64(0x158))
        }
    }
}

private struct AdmissionReader {
    let bytes: Data
    init(_ bytes: Data) { self.bytes = bytes }

    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        return bytes.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    func u64(_ offset: Int) throws -> UInt64 {
        guard offset >= 0, offset <= bytes.count - 8 else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        return bytes.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }.littleEndian
    }
}
