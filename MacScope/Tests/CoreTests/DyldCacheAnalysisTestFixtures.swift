import Foundation
@testable import MacScope

enum DyldCacheAnalysisTestFixtures {
    static let requestID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    static let sourceIdentity = DyldCacheFileIdentity(
        deviceID: 1,
        fileID: 2,
        byteCount: 4_096,
        modificationTimeSeconds: 3,
        modificationTimeNanoseconds: 4
    )

    static func artifactIdentity(seed: Character = "a") -> MachOSliceArtifactIdentity {
        try! MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 2,
            selectedSliceSHA256: String(repeating: seed, count: 64),
            selectedSliceByteCount: 4_096
        )
    }

    static func image(
        _ path: String = "/usr/lib/libFixture.dylib",
        _ address: UInt64 = 0x1_0000_0000
    ) -> DyldCacheImageIdentity {
        DyldCacheImageIdentity(path: path, loadAddress: address)
    }

    static func subject(
        generation: UInt64 = 7,
        artifact: MachOSliceArtifactIdentity? = nil,
        image: DyldCacheImageIdentity? = nil
    ) -> DyldCacheAnalysisSubjectIdentity {
        DyldCacheAnalysisSubjectIdentity(
            artifactIdentity: artifact ?? artifactIdentity(),
            imageIdentity: image ?? self.image(),
            analysisGeneration: generation
        )
    }

    static func request(
        subject: DyldCacheAnalysisSubjectIdentity? = nil,
        limits: DyldCacheAnalysisLimits = .default
    ) -> DyldCacheAnalysisRequest {
        DyldCacheAnalysisRequest(
            url: URL(fileURLWithPath: "/tmp/dyld_shared_cache_arm64e"),
            expectedSourceIdentity: sourceIdentity,
            subject: subject ?? self.subject(),
            categories: [.mappings, .catalog],
            limits: limits,
            requestID: requestID
        )
    }

    static func result(
        requestID: UUID = requestID,
        sourceIdentity: DyldCacheFileIdentity = sourceIdentity,
        subject: DyldCacheAnalysisSubjectIdentity? = nil,
        provider: DyldCacheAnalysisProviderIdentity = .machOKit0522,
        images: [DyldCacheImageRecord] = [],
        mappings: [DyldCacheMappingRecord] = [],
        requestedCategories: [DyldCacheAnalysisCategory] = [.catalog, .mappings],
        catalogCoverage: DyldCacheAnalysisCoverageStatus? = nil,
        mappingCoverage: DyldCacheAnalysisCoverageStatus? = nil,
        completion: DyldCacheAnalysisCompletionState = .complete
    ) -> DyldCacheAnalysisResult {
        let requested = Set(requestedCategories)
        let partialCategory = completion == .partial
            ? DyldCacheAnalysisCategory.allCases.first(where: requested.contains)
            : nil
        func coverage(
            _ category: DyldCacheAnalysisCategory,
            returned: Int,
            explicitStatus: DyldCacheAnalysisCoverageStatus? = nil
        ) -> DyldCacheAnalysisCoverage {
            guard requested.contains(category) else {
                return DyldCacheAnalysisCoverage(
                    category: category,
                    status: .notRequested,
                    availableRecordCount: nil,
                    returnedRecordCount: 0
                )
            }
            let status = explicitStatus
                ?? (partialCategory == category ? .partial : .complete)
            let available: Int?
            switch status {
            case .notRequested, .unavailable: available = nil
            case .complete: available = returned
            case .partial: available = returned + 1
            }
            return DyldCacheAnalysisCoverage(
                category: category,
                status: status,
                availableRecordCount: available,
                returnedRecordCount: status == .unavailable ? 0 : returned
            )
        }
        return DyldCacheAnalysisResult(
            version: DyldCacheAnalysisResult.schemaVersion,
            requestID: requestID,
            subject: subject ?? self.subject(),
            provider: provider,
            sourceIdentity: sourceIdentity,
            header: DyldCacheHeaderRecord(
                magic: "dyld_v1 arm64e",
                architecture: "arm64e",
                uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                symbolFileUUID: nil,
                cacheTypeRawValue: 1,
                cacheSubTypeRawValue: nil,
                platformRawValue: 1,
                platformName: "macOS",
                isSimulator: false,
                osVersion: "27.0",
                imageCount: images.count
            ),
            files: [DyldCacheFileRecord(
                index: 0,
                role: .main,
                displayName: "dyld_shared_cache_arm64e",
                suffix: nil,
                identity: sourceIdentity
            )],
            images: images,
            mappings: mappings,
            localSymbols: [],
            dylibTrieEntries: [],
            programTrieEntries: [],
            optimizationSummary: nil,
            prebuiltLoaderSummary: nil,
            coverage: DyldCacheAnalysisCategory.allCases.map { category in
                switch category {
                case .catalog:
                    coverage(category, returned: images.count, explicitStatus: catalogCoverage)
                case .mappings:
                    coverage(category, returned: mappings.count, explicitStatus: mappingCoverage)
                case .slideInfo:
                    coverage(category, returned: mappings.filter { $0.slideInfoVersion != nil }.count)
                case .localSymbols, .trieSummary, .optimizationSummary,
                     .prebuiltLoaderSummary:
                    coverage(category, returned: 0)
                }
            },
            completion: completion,
            warnings: []
        )
    }

    static func imageRecord(
        _ path: String,
        _ address: UInt64
    ) -> DyldCacheImageRecord {
        DyldCacheImageRecord(
            path: path,
            loadAddress: address,
            headerFileOffset: 0,
            sourceFileIndex: 0,
            modificationTime: 0,
            inode: 0
        )
    }

    static func mappingRecord(
        address: UInt64,
        sourceFileIndex: Int = 0,
        maximumProtection: UInt32 = 5,
        initialProtection: UInt32 = 5
    ) -> DyldCacheMappingRecord {
        DyldCacheMappingRecord(
            name: nil,
            address: address,
            size: 0x1000,
            fileOffset: address,
            sourceFileIndex: sourceFileIndex,
            maximumProtection: maximumProtection,
            initialProtection: initialProtection,
            flags: 0,
            slideInfoFileOffset: nil,
            slideInfoByteCount: nil,
            slideInfoVersion: nil
        )
    }

    static func mutatingResult(
        _ result: DyldCacheAnalysisResult,
        _ mutation: (inout [String: Any]) -> Void
    ) throws -> DyldCacheAnalysisResult {
        let data = try JSONEncoder().encode(result)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        mutation(&object)
        return try JSONDecoder().decode(
            DyldCacheAnalysisResult.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}
