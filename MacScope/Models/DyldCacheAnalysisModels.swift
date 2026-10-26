import Foundation

enum DyldCacheAnalysisCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case catalog
    case mappings
    case slideInfo
    case localSymbols
    case trieSummary
    case optimizationSummary
    case prebuiltLoaderSummary
}

struct DyldCacheAnalysisLimits: Codable, Equatable, Sendable {
    static let `default` = DyldCacheAnalysisLimits(
        maximumImages: 100_000,
        maximumMappings: 4_096,
        maximumLocalSymbols: 250_000,
        maximumTrieEntries: 250_000,
        maximumWarnings: 64,
        maximumOutputBytes: 32 * 1024 * 1024,
        maximumSourceBytes: 32 * 1024 * 1024 * 1024,
        maximumDurationMilliseconds: 15_000
    )

    static let hardMaximum = DyldCacheAnalysisLimits(
        maximumImages: 1_000_000,
        maximumMappings: 16_384,
        maximumLocalSymbols: 2_000_000,
        maximumTrieEntries: 1_000_000,
        maximumWarnings: 256,
        maximumOutputBytes: 128 * 1024 * 1024,
        maximumSourceBytes: 128 * 1024 * 1024 * 1024,
        maximumDurationMilliseconds: 120_000
    )

    let maximumImages: Int
    let maximumMappings: Int
    let maximumLocalSymbols: Int
    let maximumTrieEntries: Int
    let maximumWarnings: Int
    let maximumOutputBytes: Int
    let maximumSourceBytes: UInt64
    let maximumDurationMilliseconds: Int

    func validated() throws -> Self {
        let boundedCounts = [
            ("maximumImages", maximumImages, Self.hardMaximum.maximumImages),
            ("maximumMappings", maximumMappings, Self.hardMaximum.maximumMappings),
            ("maximumLocalSymbols", maximumLocalSymbols, Self.hardMaximum.maximumLocalSymbols),
            ("maximumTrieEntries", maximumTrieEntries, Self.hardMaximum.maximumTrieEntries),
            ("maximumWarnings", maximumWarnings, Self.hardMaximum.maximumWarnings),
        ]
        for (name, value, upperBound) in boundedCounts where value < 0 || value > upperBound {
            throw DyldCacheAnalysisModelError.invalidLimit(name: name, value: value, maximum: upperBound)
        }
        guard (1...Self.hardMaximum.maximumOutputBytes).contains(maximumOutputBytes) else {
            throw DyldCacheAnalysisModelError.invalidLimit(
                name: "maximumOutputBytes",
                value: maximumOutputBytes,
                maximum: Self.hardMaximum.maximumOutputBytes
            )
        }
        guard maximumSourceBytes > 0,
              maximumSourceBytes <= Self.hardMaximum.maximumSourceBytes else {
            throw DyldCacheAnalysisModelError.invalidUnsignedLimit(
                name: "maximumSourceBytes",
                value: maximumSourceBytes,
                maximum: Self.hardMaximum.maximumSourceBytes
            )
        }
        guard (1...Self.hardMaximum.maximumDurationMilliseconds).contains(maximumDurationMilliseconds) else {
            throw DyldCacheAnalysisModelError.invalidLimit(
                name: "maximumDurationMilliseconds",
                value: maximumDurationMilliseconds,
                maximum: Self.hardMaximum.maximumDurationMilliseconds
            )
        }
        return self
    }
}

enum DyldCacheAnalysisModelError: Error, Equatable, LocalizedError {
    case invalidLimit(name: String, value: Int, maximum: Int)
    case invalidUnsignedLimit(name: String, value: UInt64, maximum: UInt64)
    case invalidPath
    case invalidSourceIdentity
    case invalidImageIdentity
    case emptyCategorySelection
    case duplicateCategory(DyldCacheAnalysisCategory)
    case invalidResult(reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalidLimit(name, value, maximum):
            "\(name) is \(value); expected a value from 0 through \(maximum)."
        case let .invalidUnsignedLimit(name, value, maximum):
            "\(name) is \(value); expected a positive value no greater than \(maximum)."
        case .invalidPath:
            "The dyld cache source path is invalid."
        case .invalidSourceIdentity:
            "The dyld cache source identity is invalid."
        case .invalidImageIdentity:
            "The selected dyld cache image identity is invalid."
        case .emptyCategorySelection:
            "At least one dyld cache analysis category is required."
        case let .duplicateCategory(category):
            "The dyld cache category '\(category.rawValue)' appears more than once."
        case let .invalidResult(reason):
            "The dyld cache analysis result is invalid: \(reason)."
        }
    }
}

struct DyldCacheFileIdentity: Codable, Equatable, Hashable, Sendable {
    let deviceID: UInt64
    let fileID: UInt64
    let byteCount: UInt64
    let modificationTimeSeconds: Int64
    let modificationTimeNanoseconds: Int64

    func validated() throws -> Self {
        guard byteCount > 0, (0..<1_000_000_000).contains(modificationTimeNanoseconds) else {
            throw DyldCacheAnalysisModelError.invalidSourceIdentity
        }
        return self
    }
}

struct DyldCacheImageIdentity: Codable, Equatable, Hashable, Sendable {
    let path: String
    let loadAddress: UInt64

    func validated() throws -> Self {
        guard path.hasPrefix("/"),
              !path.utf8.contains(0),
              (1...4_096).contains(path.utf8.count),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DyldCacheAnalysisModelError.invalidImageIdentity
        }
        return self
    }
}

/// Binds supplemental cache metadata to the exact selected artifact/slice, image, and analysis
/// generation that admitted the request. A reply for any other generation must be discarded.
struct DyldCacheAnalysisSubjectIdentity: Codable, Equatable, Hashable, Sendable {
    let artifactIdentity: MachOSliceArtifactIdentity
    let imageIdentity: DyldCacheImageIdentity
    let analysisGeneration: UInt64

    func validated() throws -> Self {
        _ = try imageIdentity.validated()
        return self
    }
}

struct DyldCacheAnalysisProviderIdentity: Codable, Equatable, Sendable {
    let providerID: String
    let version: String
    let sourceRevision: String
    let sourceArchiveSHA256: String

    static let machOKit0522 = DyldCacheAnalysisProviderIdentity(
        providerID: "p-x9/MachOKit",
        version: "0.52.2",
        sourceRevision: "773e10797abc53914b94c2ee8c6f40f5da0b06eb",
        sourceArchiveSHA256: "2e6d429f248ac3f01b896379c3c77518858a2213ef3da0d89939d112de9fd945"
    )
}

enum DyldCacheFileRole: String, Codable, Sendable { case main, subcache, symbols, other }

struct DyldCacheFileRecord: Codable, Equatable, Sendable {
    let index: Int
    let role: DyldCacheFileRole
    let displayName: String
    let suffix: String?
    let identity: DyldCacheFileIdentity
}

struct DyldCacheHeaderRecord: Codable, Equatable, Sendable {
    let magic: String
    let architecture: String
    let uuid: String
    let symbolFileUUID: String?
    let cacheTypeRawValue: UInt64
    let cacheSubTypeRawValue: UInt32?
    let platformRawValue: UInt32
    let platformName: String
    let isSimulator: Bool
    let osVersion: String
    let imageCount: Int
}

struct DyldCacheImageRecord: Codable, Equatable, Hashable, Sendable {
    let path: String
    let loadAddress: UInt64
    let headerFileOffset: UInt64?
    let sourceFileIndex: Int?
    let modificationTime: UInt64
    let inode: UInt64

    var identity: DyldCacheImageIdentity { DyldCacheImageIdentity(path: path, loadAddress: loadAddress) }
}

struct DyldCacheMappingRecord: Codable, Equatable, Hashable, Sendable {
    let name: String?
    let address: UInt64
    let size: UInt64
    let fileOffset: UInt64
    let sourceFileIndex: Int?
    let maximumProtection: UInt32
    let initialProtection: UInt32
    let flags: UInt64
    let slideInfoFileOffset: UInt64?
    let slideInfoByteCount: UInt64?
    let slideInfoVersion: Int?
}

struct DyldCacheLocalSymbolRecord: Codable, Equatable, Hashable, Sendable {
    let name: String
    let value: UInt64
    let sectionNumber: Int?
    let flags: UInt32?
}

struct DyldCacheDylibTrieRecord: Codable, Equatable, Hashable, Sendable {
    let path: String
    let index: UInt32
}

struct DyldCacheProgramTrieRecord: Codable, Equatable, Hashable, Sendable {
    let path: String
    let offset: UInt32
}

struct DyldCacheOptimizationSummary: Codable, Equatable, Sendable {
    let hasObjectiveCOptimization: Bool
    let objectiveCVersion: UInt32?
    let objectiveCFlags: UInt32?
    let hasLegacyObjectiveCOptimization: Bool
    let hasSwiftOptimization: Bool
    let swiftVersion: UInt32?
    let tproMappingCount: Int
    let functionVariantCount: Int
    let prewarmingEntryCount: Int
}

struct DyldCachePrebuiltLoaderSummary: Codable, Equatable, Sendable {
    let isPresent: Bool
    let magic: String?
    let versionHash: UInt32?
    let isKnownVersion: Bool
    let loaderCount: Int
    let missingPathCount: Int?
}

enum DyldCacheAnalysisCoverageStatus: String, Codable, Sendable {
    case notRequested
    case complete
    case partial
    case unavailable
}

struct DyldCacheAnalysisCoverage: Codable, Equatable, Sendable {
    let category: DyldCacheAnalysisCategory
    let status: DyldCacheAnalysisCoverageStatus
    let availableRecordCount: Int?
    let returnedRecordCount: Int
}

enum DyldCacheAnalysisCompletionState: String, Codable, Equatable, Sendable {
    case complete
    case partial
}

enum DyldCacheAnalysisWarningCode: String, Codable, Sendable {
    case imagePathUnavailable
    case imageFileOffsetUnavailable
    case localSymbolsUnavailable
    case slideInfoUnavailable
    case requestedCategoryUnavailable
    case recordLimitReached
    case stringTruncated
}

struct DyldCacheAnalysisWarning: Codable, Equatable, Sendable {
    let code: DyldCacheAnalysisWarningCode
    let category: DyldCacheAnalysisCategory
    let recordIndex: Int?
}

struct DyldCacheAnalysisResult: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let version: Int
    let requestID: UUID
    let subject: DyldCacheAnalysisSubjectIdentity
    let provider: DyldCacheAnalysisProviderIdentity
    let sourceIdentity: DyldCacheFileIdentity
    let header: DyldCacheHeaderRecord
    let files: [DyldCacheFileRecord]
    let images: [DyldCacheImageRecord]
    let mappings: [DyldCacheMappingRecord]
    let localSymbols: [DyldCacheLocalSymbolRecord]
    let dylibTrieEntries: [DyldCacheDylibTrieRecord]
    let programTrieEntries: [DyldCacheProgramTrieRecord]
    let optimizationSummary: DyldCacheOptimizationSummary?
    let prebuiltLoaderSummary: DyldCachePrebuiltLoaderSummary?
    let coverage: [DyldCacheAnalysisCoverage]
    let completion: DyldCacheAnalysisCompletionState
    let warnings: [DyldCacheAnalysisWarning]

    /// Validates the MacScope-owned result envelope without trusting the provider that produced it.
    /// Request-specific category and negotiated-limit checks are applied by the overload below.
    func validated() throws -> Self {
        guard version == Self.schemaVersion else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "schema version mismatch")
        }
        _ = try subject.validated()
        _ = try sourceIdentity.validated()

        let boundedStrings: [String] = [
            header.magic,
            header.architecture,
            header.uuid,
            header.symbolFileUUID,
            header.platformName,
            header.osVersion,
        ].compactMap { $0 }
            + files.flatMap { [$0.displayName, $0.suffix].compactMap { $0 } }
            + images.map(\.path)
            + mappings.compactMap(\.name)
            + localSymbols.map(\.name)
            + dylibTrieEntries.map(\.path)
            + programTrieEntries.map(\.path)
            + [prebuiltLoaderSummary?.magic].compactMap { $0 }
        guard boundedStrings.allSatisfy(Self.isBoundedWireString) else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "unbounded or invalid string")
        }

        guard header.imageCount >= 0, header.imageCount >= images.count else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "header image count is inconsistent")
        }
        guard files.indices.allSatisfy({ files[$0].index == $0 }),
              files.first.map({ $0.role == .main }) ?? true,
              files.dropFirst().allSatisfy({ $0.role != .main }),
              files.allSatisfy({ (try? $0.identity.validated()) != nil }) else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "cache file table is inconsistent")
        }
        let sourceFileIndices = images.compactMap(\.sourceFileIndex)
            + mappings.compactMap(\.sourceFileIndex)
        guard sourceFileIndices.allSatisfy({ files.indices.contains($0) }) else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "record references an unknown cache file")
        }
        let knownVMProtectionBits: UInt32 = 0x7
        for mapping in mappings {
            let (_, addressOverflow) = mapping.address.addingReportingOverflow(mapping.size)
            let (fileEnd, fileOffsetOverflow) = mapping.fileOffset.addingReportingOverflow(mapping.size)
            guard mapping.size > 0, !addressOverflow, !fileOffsetOverflow else {
                throw DyldCacheAnalysisModelError.invalidResult(
                    reason: "mapping range is empty or overflows"
                )
            }
            guard mapping.maximumProtection & ~knownVMProtectionBits == 0,
                  mapping.initialProtection & ~knownVMProtectionBits == 0,
                  mapping.initialProtection & ~mapping.maximumProtection == 0 else {
                throw DyldCacheAnalysisModelError.invalidResult(
                    reason: "mapping protection mask is inconsistent"
                )
            }
            if let sourceFileIndex = mapping.sourceFileIndex {
                guard fileEnd <= files[sourceFileIndex].identity.byteCount else {
                    throw DyldCacheAnalysisModelError.invalidResult(
                        reason: "mapping range crosses its cache file"
                    )
                }
            }

            let hasSlideOffset = mapping.slideInfoFileOffset != nil
            let hasSlideByteCount = mapping.slideInfoByteCount != nil
            guard hasSlideOffset == hasSlideByteCount,
                  hasSlideOffset || mapping.slideInfoVersion == nil else {
                throw DyldCacheAnalysisModelError.invalidResult(
                    reason: "slide-info tuple is inconsistent"
                )
            }
            if let slideInfoVersion = mapping.slideInfoVersion, slideInfoVersion <= 0 {
                throw DyldCacheAnalysisModelError.invalidResult(
                    reason: "slide-info version is invalid"
                )
            }
            if let slideInfoFileOffset = mapping.slideInfoFileOffset,
               let slideInfoByteCount = mapping.slideInfoByteCount {
                let (slideEnd, slideOffsetOverflow) = slideInfoFileOffset.addingReportingOverflow(
                    slideInfoByteCount
                )
                guard slideInfoFileOffset > 0,
                      slideInfoByteCount > 0,
                      !slideOffsetOverflow,
                      let sourceFileIndex = mapping.sourceFileIndex,
                      slideEnd <= files[sourceFileIndex].identity.byteCount else {
                    throw DyldCacheAnalysisModelError.invalidResult(
                        reason: "slide-info range is invalid or crosses its cache file"
                    )
                }
            }
        }
        guard images.allSatisfy({ (try? $0.identity.validated()) != nil }) else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "image identity is invalid")
        }
        guard Self.isCanonicallyOrdered(images, by: {
            ($0.path, $0.loadAddress) <= ($1.path, $1.loadAddress)
        }), Self.isCanonicallyOrdered(mappings, by: {
            ($0.address, $0.size, $0.fileOffset) <= ($1.address, $1.size, $1.fileOffset)
        }), Self.isCanonicallyOrdered(localSymbols, by: {
            ($0.value, $0.name) <= ($1.value, $1.name)
        }), Self.isCanonicallyOrdered(dylibTrieEntries, by: {
            ($0.path, $0.index) <= ($1.path, $1.index)
        }), Self.isCanonicallyOrdered(programTrieEntries, by: {
            ($0.path, $0.offset) <= ($1.path, $1.offset)
        }) else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "record ordering is not canonical")
        }

        guard coverage.map(\.category) == DyldCacheAnalysisCategory.allCases else {
            throw DyldCacheAnalysisModelError.invalidResult(
                reason: "coverage must contain every category exactly once in canonical order"
            )
        }
        let returnedCounts: [DyldCacheAnalysisCategory: Int] = [
            .catalog: images.count,
            .mappings: mappings.count,
            .slideInfo: mappings.lazy.filter { $0.slideInfoVersion != nil }.count,
            .localSymbols: localSymbols.count,
            .trieSummary: dylibTrieEntries.count + programTrieEntries.count,
            .optimizationSummary: optimizationSummary == nil ? 0 : 1,
            .prebuiltLoaderSummary: prebuiltLoaderSummary == nil ? 0 : 1,
        ]
        for entry in coverage {
            guard entry.returnedRecordCount == returnedCounts[entry.category],
                  entry.returnedRecordCount >= 0 else {
                throw DyldCacheAnalysisModelError.invalidResult(
                    reason: "returned count disagrees with \(entry.category.rawValue) records"
                )
            }
            switch entry.status {
            case .notRequested, .unavailable:
                guard entry.availableRecordCount == nil, entry.returnedRecordCount == 0 else {
                    throw DyldCacheAnalysisModelError.invalidResult(
                        reason: "\(entry.category.rawValue) absence is inconsistent"
                    )
                }
            case .complete:
                guard let available = entry.availableRecordCount,
                      entry.category == .slideInfo
                        ? available >= entry.returnedRecordCount
                        : available == entry.returnedRecordCount else {
                    throw DyldCacheAnalysisModelError.invalidResult(
                        reason: "complete \(entry.category.rawValue) coverage is inconsistent"
                    )
                }
            case .partial:
                guard let available = entry.availableRecordCount,
                      available > entry.returnedRecordCount else {
                    throw DyldCacheAnalysisModelError.invalidResult(
                        reason: "partial \(entry.category.rawValue) coverage is inconsistent"
                    )
                }
            }
        }
        guard warnings.allSatisfy({ warning in
            warning.recordIndex.map { $0 >= 0 } ?? true
        }) else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "warning index is invalid")
        }
        if let summary = optimizationSummary {
            guard summary.tproMappingCount >= 0,
                  summary.functionVariantCount >= 0,
                  summary.prewarmingEntryCount >= 0 else {
                throw DyldCacheAnalysisModelError.invalidResult(
                    reason: "optimization summary count is invalid"
                )
            }
        }
        if let summary = prebuiltLoaderSummary {
            guard summary.loaderCount >= 0,
                  summary.missingPathCount.map({ $0 >= 0 }) ?? true else {
                throw DyldCacheAnalysisModelError.invalidResult(
                    reason: "prebuilt-loader summary count is invalid"
                )
            }
        }
        return self
    }

    /// Applies the exact category and count budgets negotiated by the request.
    func validated(
        requestedCategories: [DyldCacheAnalysisCategory],
        limits: DyldCacheAnalysisLimits
    ) throws -> Self {
        _ = try validated()
        let requested = Set(requestedCategories)
        let coverageByCategory = Dictionary(uniqueKeysWithValues: coverage.map { ($0.category, $0) })
        for category in DyldCacheAnalysisCategory.allCases {
            guard let entry = coverageByCategory[category] else {
                throw DyldCacheAnalysisModelError.invalidResult(reason: "missing category coverage")
            }
            if requested.contains(category) {
                guard entry.status != .notRequested else {
                    throw DyldCacheAnalysisModelError.invalidResult(
                        reason: "requested \(category.rawValue) category was not evaluated"
                    )
                }
            } else {
                guard entry.status == .notRequested else {
                    throw DyldCacheAnalysisModelError.invalidResult(
                        reason: "unrequested \(category.rawValue) category was evaluated"
                    )
                }
            }
        }
        guard images.count <= limits.maximumImages,
              mappings.count <= limits.maximumMappings,
              localSymbols.count <= limits.maximumLocalSymbols,
              dylibTrieEntries.count <= limits.maximumTrieEntries,
              programTrieEntries.count <= limits.maximumTrieEntries - dylibTrieEntries.count,
              warnings.count <= limits.maximumWarnings else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "negotiated record limit exceeded")
        }
        guard requested.contains(.catalog) || images.isEmpty,
              requested.contains(.mappings) || requested.contains(.slideInfo) || mappings.isEmpty,
              requested.contains(.localSymbols) || localSymbols.isEmpty,
              requested.contains(.trieSummary)
                || (dylibTrieEntries.isEmpty && programTrieEntries.isEmpty),
              requested.contains(.optimizationSummary) || optimizationSummary == nil,
              requested.contains(.prebuiltLoaderSummary) || prebuiltLoaderSummary == nil,
              requested.contains(.slideInfo)
                || mappings.allSatisfy({ $0.slideInfoVersion == nil }) else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "unrequested records were returned")
        }
        let expectedCompletion: DyldCacheAnalysisCompletionState = requestedCategories.allSatisfy {
            coverageByCategory[$0]?.status == .complete
        } ? .complete : .partial
        guard completion == expectedCompletion else {
            throw DyldCacheAnalysisModelError.invalidResult(reason: "completion state is inconsistent")
        }
        return self
    }

    private static func isBoundedWireString(_ value: String) -> Bool {
        value.utf8.count <= 4_096 && !value.utf8.contains(0)
    }

    private static func isCanonicallyOrdered<Element>(
        _ elements: [Element],
        by areInOrder: (Element, Element) -> Bool
    ) -> Bool {
        zip(elements, elements.dropFirst()).allSatisfy(areInOrder)
    }
}

enum DyldCacheAnalysisProviderError: Error, Equatable, LocalizedError {
    case sourceIsNotRegularFile
    case sourceIdentityMismatch
    case subjectIdentityMismatch
    case staleGeneration
    case unsafeSubcacheSuffix
    case sourceChangedDuringInspection
    case providerUnavailable
    case providerRejectedInput
    case outputLimitExceeded
    case cancelled
    case timeout

    var errorDescription: String? {
        switch self {
        case .sourceIsNotRegularFile: "The dyld cache source is not a regular file."
        case .sourceIdentityMismatch: "The dyld cache source no longer matches the accepted identity."
        case .subjectIdentityMismatch: "The dyld cache result belongs to another artifact or image."
        case .staleGeneration: "The dyld cache result belongs to a stale analysis generation."
        case .unsafeSubcacheSuffix: "The dyld cache declares an unsafe subcache suffix."
        case .sourceChangedDuringInspection: "The dyld cache source changed during inspection."
        case .providerUnavailable: "The dyld cache metadata provider is unavailable."
        case .providerRejectedInput: "The dyld cache metadata provider rejected the input."
        case .outputLimitExceeded: "The dyld cache metadata output exceeded its bounded limit."
        case .cancelled: "The dyld cache metadata inspection was cancelled."
        case .timeout: "The dyld cache metadata inspection exceeded its time budget."
        }
    }
}
