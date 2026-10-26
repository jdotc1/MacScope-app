import Foundation

enum DyldCacheDifferentialState: String, Codable, Equatable, Sendable {
    case agreement
    case supplementalOnly
    case nativeOnly
    case disagreement
    case uncomparable
    case invalid
}

struct DyldCacheComparableMapping: Codable, Equatable, Hashable, Sendable {
    let address: UInt64
    let size: UInt64
    let fileOffset: UInt64
    let sourceFileIndex: Int?
    let maximumProtection: UInt32
    let initialProtection: UInt32
    let flags: UInt64
}

enum DyldCacheDifferentialInvalidReason: Equatable, Sendable {
    case duplicateNativeImage(DyldCacheImageIdentity)
    case duplicateSupplementalImage(DyldCacheImageIdentity)
    case duplicateNativeMapping(DyldCacheComparableMapping)
    case duplicateSupplementalMapping(DyldCacheComparableMapping)
}

struct DyldCacheCatalogDifferentialReport: Equatable, Sendable {
    let state: DyldCacheDifferentialState
    let agreementImages: [DyldCacheImageIdentity]
    let nativeOnlyImages: [DyldCacheImageIdentity]
    let supplementalOnlyImages: [DyldCacheImageIdentity]
    let agreementMappings: [DyldCacheComparableMapping]
    let nativeOnlyMappings: [DyldCacheComparableMapping]
    let supplementalOnlyMappings: [DyldCacheComparableMapping]
    let invalidReasons: [DyldCacheDifferentialInvalidReason]
}

struct DyldCacheCatalogDifferentialComparator: Sendable {
    func compare(
        nativeImages: [DyldCacheImageIdentity],
        nativeMappings: [DyldCacheComparableMapping],
        provider: DyldCacheAnalysisResult
    ) -> DyldCacheCatalogDifferentialReport {
        let supplementalImages = provider.images.map(\.identity)
        let supplementalMappings = provider.mappings.map {
            DyldCacheComparableMapping(
                address: $0.address,
                size: $0.size,
                fileOffset: $0.fileOffset,
                sourceFileIndex: $0.sourceFileIndex,
                maximumProtection: $0.maximumProtection,
                initialProtection: $0.initialProtection,
                flags: $0.flags
            )
        }

        let nativeImageDuplicates = sorted(duplicates(in: nativeImages)).map {
            DyldCacheDifferentialInvalidReason.duplicateNativeImage($0)
        }
        let supplementalImageDuplicates = sorted(duplicates(in: supplementalImages)).map {
            DyldCacheDifferentialInvalidReason.duplicateSupplementalImage($0)
        }
        let nativeMappingDuplicates = sorted(duplicates(in: nativeMappings)).map {
            DyldCacheDifferentialInvalidReason.duplicateNativeMapping($0)
        }
        let supplementalMappingDuplicates = sorted(duplicates(in: supplementalMappings)).map {
            DyldCacheDifferentialInvalidReason.duplicateSupplementalMapping($0)
        }
        let invalidReasons = nativeImageDuplicates + supplementalImageDuplicates
            + nativeMappingDuplicates + supplementalMappingDuplicates

        let nativeImageSet = Set(nativeImages)
        let supplementalImageSet = Set(supplementalImages)
        let nativeMappingSet = Set(nativeMappings)
        let supplementalMappingSet = Set(supplementalMappings)

        let agreementImages = sorted(nativeImageSet.intersection(supplementalImageSet))
        let nativeOnlyImages = sorted(nativeImageSet.subtracting(supplementalImageSet))
        let supplementalOnlyImages = sorted(supplementalImageSet.subtracting(nativeImageSet))
        let agreementMappings = sorted(nativeMappingSet.intersection(supplementalMappingSet))
        let nativeOnlyMappings = sorted(nativeMappingSet.subtracting(supplementalMappingSet))
        let supplementalOnlyMappings = sorted(supplementalMappingSet.subtracting(nativeMappingSet))

        let comparable = provider.completion == .complete
            && provider.coverageStatus(for: .catalog) == .complete
            && provider.coverageStatus(for: .mappings) == .complete
        let state: DyldCacheDifferentialState
        if !invalidReasons.isEmpty {
            state = .invalid
        } else if !comparable {
            state = .uncomparable
        } else {
            let hasNativeOnly = !nativeOnlyImages.isEmpty || !nativeOnlyMappings.isEmpty
            let hasSupplementalOnly = !supplementalOnlyImages.isEmpty || !supplementalOnlyMappings.isEmpty
            switch (hasNativeOnly, hasSupplementalOnly) {
            case (false, false): state = .agreement
            case (false, true): state = .supplementalOnly
            case (true, false): state = .nativeOnly
            case (true, true): state = .disagreement
            }
        }

        return DyldCacheCatalogDifferentialReport(
            state: state,
            agreementImages: agreementImages,
            nativeOnlyImages: nativeOnlyImages,
            supplementalOnlyImages: supplementalOnlyImages,
            agreementMappings: agreementMappings,
            nativeOnlyMappings: nativeOnlyMappings,
            supplementalOnlyMappings: supplementalOnlyMappings,
            invalidReasons: invalidReasons
        )
    }

    private func duplicates<T: Hashable>(in values: [T]) -> Set<T> {
        var observed: Set<T> = []
        var duplicates: Set<T> = []
        for value in values where !observed.insert(value).inserted {
            duplicates.insert(value)
        }
        return duplicates
    }

    private func sorted(_ values: Set<DyldCacheImageIdentity>) -> [DyldCacheImageIdentity] {
        values.sorted { lhs, rhs in
            lhs.path == rhs.path ? lhs.loadAddress < rhs.loadAddress : lhs.path < rhs.path
        }
    }

    private func sorted(_ values: Set<DyldCacheComparableMapping>) -> [DyldCacheComparableMapping] {
        values.sorted { lhs, rhs in
            if lhs.address != rhs.address { return lhs.address < rhs.address }
            if lhs.size != rhs.size { return lhs.size < rhs.size }
            if lhs.fileOffset != rhs.fileOffset { return lhs.fileOffset < rhs.fileOffset }
            if lhs.sourceFileIndex != rhs.sourceFileIndex {
                return (lhs.sourceFileIndex ?? -1) < (rhs.sourceFileIndex ?? -1)
            }
            if lhs.maximumProtection != rhs.maximumProtection {
                return lhs.maximumProtection < rhs.maximumProtection
            }
            if lhs.initialProtection != rhs.initialProtection {
                return lhs.initialProtection < rhs.initialProtection
            }
            return lhs.flags < rhs.flags
        }
    }
}

private extension DyldCacheAnalysisResult {
    func coverageStatus(for category: DyldCacheAnalysisCategory) -> DyldCacheAnalysisCoverageStatus? {
        let matching = coverage.filter { $0.category == category }
        guard matching.count == 1 else { return nil }
        return matching[0].status
    }
}
