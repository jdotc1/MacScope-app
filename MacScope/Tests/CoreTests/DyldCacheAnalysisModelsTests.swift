import Foundation
import XCTest
@testable import MacScope

final class DyldCacheAnalysisModelsTests: XCTestCase {
    func testRequestValidationPreservesExactSubjectAndCanonicalizesCategories() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let validated = try request.validated()

        XCTAssertEqual(validated.subject, request.subject)
        XCTAssertEqual(validated.categories, [.catalog, .mappings])
    }

    func testRequestRejectsDuplicateCategoriesAndZeroDuration() {
        let request = DyldCacheAnalysisRequest(
            url: URL(fileURLWithPath: "/tmp/cache"),
            expectedSourceIdentity: DyldCacheAnalysisTestFixtures.sourceIdentity,
            subject: DyldCacheAnalysisTestFixtures.subject(),
            categories: [.catalog, .catalog],
            limits: .default,
            requestID: DyldCacheAnalysisTestFixtures.requestID
        )
        XCTAssertThrowsError(try request.validated()) { error in
            XCTAssertEqual(
                error as? DyldCacheAnalysisModelError,
                .duplicateCategory(.catalog)
            )
        }

        let invalidLimits = DyldCacheAnalysisLimits(
            maximumImages: 1,
            maximumMappings: 1,
            maximumLocalSymbols: 1,
            maximumTrieEntries: 1,
            maximumWarnings: 1,
            maximumOutputBytes: 1,
            maximumSourceBytes: 1,
            maximumDurationMilliseconds: 0
        )
        XCTAssertThrowsError(try invalidLimits.validated())
    }

    func testResultValidationRejectsStaleGenerationSeparatelyFromSubjectDrift() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let stale = DyldCacheAnalysisTestFixtures.result(
            subject: DyldCacheAnalysisTestFixtures.subject(generation: request.subject.analysisGeneration + 1)
        )
        XCTAssertThrowsError(try request.validate(result: stale)) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .staleGeneration)
        }

        let wrongImage = DyldCacheAnalysisTestFixtures.result(
            subject: DyldCacheAnalysisTestFixtures.subject(
                generation: request.subject.analysisGeneration,
                image: DyldCacheAnalysisTestFixtures.image("/usr/lib/other.dylib", 0x2_0000_0000)
            )
        )
        XCTAssertThrowsError(try request.validate(result: wrongImage)) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .subjectIdentityMismatch)
        }

        let wrongArtifact = DyldCacheAnalysisTestFixtures.result(
            subject: DyldCacheAnalysisTestFixtures.subject(
                generation: request.subject.analysisGeneration,
                artifact: DyldCacheAnalysisTestFixtures.artifactIdentity(seed: "b")
            )
        )
        XCTAssertThrowsError(try request.validate(result: wrongArtifact)) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .subjectIdentityMismatch)
        }
    }

    func testResultValidationRejectsCrossRequestAndSourceDrift() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        XCTAssertThrowsError(try request.validate(result: DyldCacheAnalysisTestFixtures.result(
            requestID: UUID(uuidString: "aaaaaaaa-2222-3333-4444-555555555555")!
        ))) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .providerRejectedInput)
        }

        let changedSource = DyldCacheFileIdentity(
            deviceID: 1,
            fileID: 9,
            byteCount: 4_096,
            modificationTimeSeconds: 3,
            modificationTimeNanoseconds: 4
        )
        XCTAssertThrowsError(try request.validate(result: DyldCacheAnalysisTestFixtures.result(
            sourceIdentity: changedSource
        ))) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .sourceIdentityMismatch)
        }

        let unpinnedProvider = DyldCacheAnalysisProviderIdentity(
            providerID: "p-x9/MachOKit",
            version: "0.52.3",
            sourceRevision: String(repeating: "f", count: 40),
            sourceArchiveSHA256: String(repeating: "f", count: 64)
        )
        XCTAssertThrowsError(try request.validate(result: DyldCacheAnalysisTestFixtures.result(
            provider: unpinnedProvider
        ))) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .providerRejectedInput)
        }
    }

    func testResultValidationRejectsCoverageCountAndCompletionContradictions() throws {
        let request = try DyldCacheAnalysisTestFixtures.request().validated()
        let valid = DyldCacheAnalysisTestFixtures.result()
        XCTAssertEqual(try request.validate(result: valid), valid)

        let duplicateCoverage = try DyldCacheAnalysisTestFixtures.mutatingResult(valid) { object in
            var coverage = object["coverage"] as! [[String: Any]]
            coverage[1]["category"] = coverage[0]["category"]
            object["coverage"] = coverage
        }
        let impossibleAvailableCount = try DyldCacheAnalysisTestFixtures.mutatingResult(valid) { object in
            var coverage = object["coverage"] as! [[String: Any]]
            coverage[0]["availableRecordCount"] = -1
            object["coverage"] = coverage
        }
        let falsePartial = try DyldCacheAnalysisTestFixtures.mutatingResult(valid) { object in
            object["completion"] = DyldCacheAnalysisCompletionState.partial.rawValue
        }

        XCTAssertThrowsError(try duplicateCoverage.validated())
        XCTAssertThrowsError(try impossibleAvailableCount.validated())
        XCTAssertThrowsError(try request.validate(result: falsePartial))
    }

    func testResultValidationRejectsUnknownSourcesOrderingStringsLimitsAndUnrequestedRecords() throws {
        let valid = DyldCacheAnalysisTestFixtures.result(
            images: [
                DyldCacheImageRecord(
                    path: "/a",
                    loadAddress: 1,
                    headerFileOffset: nil,
                    sourceFileIndex: nil,
                    modificationTime: 0,
                    inode: 0
                ),
                DyldCacheImageRecord(
                    path: "/b",
                    loadAddress: 2,
                    headerFileOffset: nil,
                    sourceFileIndex: nil,
                    modificationTime: 0,
                    inode: 0
                ),
            ]
        )
        let unknownSource = try DyldCacheAnalysisTestFixtures.mutatingResult(valid) { object in
            var images = object["images"] as! [[String: Any]]
            images[0]["sourceFileIndex"] = 99
            object["images"] = images
        }
        let unordered = try DyldCacheAnalysisTestFixtures.mutatingResult(valid) { object in
            var images = object["images"] as! [[String: Any]]
            images.swapAt(0, 1)
            object["images"] = images
        }
        let unbounded = try DyldCacheAnalysisTestFixtures.mutatingResult(valid) { object in
            var images = object["images"] as! [[String: Any]]
            images[0]["path"] = "/" + String(repeating: "x", count: 4_096)
            object["images"] = images
        }
        let catalogOnlyRequest = DyldCacheAnalysisRequest(
            url: URL(fileURLWithPath: "/tmp/cache"),
            expectedSourceIdentity: DyldCacheAnalysisTestFixtures.sourceIdentity,
            subject: DyldCacheAnalysisTestFixtures.subject(),
            categories: [.catalog],
            limits: DyldCacheAnalysisLimits(
                maximumImages: 1,
                maximumMappings: 0,
                maximumLocalSymbols: 0,
                maximumTrieEntries: 0,
                maximumWarnings: 0,
                maximumOutputBytes: 16_384,
                maximumSourceBytes: 4_096,
                maximumDurationMilliseconds: 1_000
            ),
            requestID: DyldCacheAnalysisTestFixtures.requestID
        )
        let boundedRequest = DyldCacheAnalysisRequest(
            url: catalogOnlyRequest.url,
            expectedSourceIdentity: catalogOnlyRequest.expectedSourceIdentity,
            subject: catalogOnlyRequest.subject,
            categories: [.catalog, .mappings],
            limits: catalogOnlyRequest.limits,
            requestID: catalogOnlyRequest.requestID
        )
        let unrequestedMapping = DyldCacheAnalysisTestFixtures.result(
            mappings: [DyldCacheMappingRecord(
                name: nil,
                address: 0x1_0000,
                size: 0x1_000,
                fileOffset: 0,
                sourceFileIndex: nil,
                maximumProtection: 1,
                initialProtection: 1,
                flags: 0,
                slideInfoFileOffset: nil,
                slideInfoByteCount: nil,
                slideInfoVersion: nil
            )],
            requestedCategories: [.catalog]
        )

        XCTAssertThrowsError(try unknownSource.validated())
        XCTAssertThrowsError(try unordered.validated())
        XCTAssertThrowsError(try unbounded.validated())
        XCTAssertThrowsError(try catalogOnlyRequest.validate(result: valid))
        XCTAssertThrowsError(try boundedRequest.validate(result: valid))
        XCTAssertThrowsError(try catalogOnlyRequest.validate(result: unrequestedMapping))
    }

    func testResultValidationRejectsMappingRangeWrapAndFileExtentCrossing() throws {
        let addressWrap = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            address: UInt64.max - 0x7ff,
            size: 0x1_000,
            fileOffset: 0
        )])
        let fileOffsetWrap = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            address: 0x1_0000_0000,
            size: 0x1_000,
            fileOffset: UInt64.max - 0x7ff
        )])
        let fileExtentCrossing = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            address: 0x1_0000_0000,
            size: 0x900,
            fileOffset: 0x800
        )])

        XCTAssertThrowsError(try addressWrap.validated())
        XCTAssertThrowsError(try fileOffsetWrap.validated())
        XCTAssertThrowsError(try fileExtentCrossing.validated())
    }

    func testResultValidationRejectsIncoherentAndOutOfBoundsSlideInfo() throws {
        let missingByteCount = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            slideInfoFileOffset: 0x100,
            slideInfoByteCount: nil,
            slideInfoVersion: 2
        )])
        let versionWithoutRange = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            slideInfoVersion: 2
        )])
        let slideOverflow = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            slideInfoFileOffset: UInt64.max - 7,
            slideInfoByteCount: 16,
            slideInfoVersion: 2
        )])
        let slideExtentCrossing = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            slideInfoFileOffset: 0xf00,
            slideInfoByteCount: 0x200,
            slideInfoVersion: 2
        )])

        XCTAssertThrowsError(try missingByteCount.validated())
        XCTAssertThrowsError(try versionWithoutRange.validated())
        XCTAssertThrowsError(try slideOverflow.validated())
        XCTAssertThrowsError(try slideExtentCrossing.validated())
    }

    func testResultValidationRejectsMappingSourceAndProtectionContradictions() throws {
        let invalidSource = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            sourceFileIndex: 1
        )])
        let unknownMaximumProtection = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            maximumProtection: 0x8,
            initialProtection: 0
        )])
        let unknownInitialProtection = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            maximumProtection: 0x7,
            initialProtection: 0x8
        )])
        let initialExceedsMaximum = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            maximumProtection: 0x1,
            initialProtection: 0x3
        )])

        XCTAssertThrowsError(try invalidSource.validated())
        XCTAssertThrowsError(try unknownMaximumProtection.validated())
        XCTAssertThrowsError(try unknownInitialProtection.validated())
        XCTAssertThrowsError(try initialExceedsMaximum.validated())
    }

    func testResultValidationAcceptsBoundedMappingAndUnavailableSlideVersion() throws {
        let result = DyldCacheAnalysisTestFixtures.result(mappings: [mapping(
            address: 0x1_0000_0000,
            size: 0x1_000,
            fileOffset: 0,
            sourceFileIndex: 0,
            maximumProtection: 0x5,
            initialProtection: 0x5,
            slideInfoFileOffset: 0x100,
            slideInfoByteCount: 0x100,
            slideInfoVersion: nil
        )])

        XCTAssertEqual(try result.validated(), result)
    }

    func testPartialTimeoutAndStaleGenerationAreClosedDistinctStates() {
        XCTAssertNotEqual(
            DyldCacheAnalysisCompletionState.partial,
            DyldCacheAnalysisCompletionState.complete
        )
        XCTAssertNotEqual(
            DyldCacheAnalysisProviderError.timeout,
            DyldCacheAnalysisProviderError.outputLimitExceeded
        )
        XCTAssertNotEqual(
            DyldCacheAnalysisProviderError.cancelled,
            DyldCacheAnalysisProviderError.timeout
        )
        XCTAssertNotEqual(
            DyldCacheAnalysisProviderError.staleGeneration,
            DyldCacheAnalysisProviderError.sourceIdentityMismatch
        )
    }

    private func mapping(
        address: UInt64 = 0x1_0000_0000,
        size: UInt64 = 0x1_000,
        fileOffset: UInt64 = 0,
        sourceFileIndex: Int? = 0,
        maximumProtection: UInt32 = 0x5,
        initialProtection: UInt32 = 0x5,
        slideInfoFileOffset: UInt64? = nil,
        slideInfoByteCount: UInt64? = nil,
        slideInfoVersion: Int? = nil
    ) -> DyldCacheMappingRecord {
        DyldCacheMappingRecord(
            name: nil,
            address: address,
            size: size,
            fileOffset: fileOffset,
            sourceFileIndex: sourceFileIndex,
            maximumProtection: maximumProtection,
            initialProtection: initialProtection,
            flags: 0,
            slideInfoFileOffset: slideInfoFileOffset,
            slideInfoByteCount: slideInfoByteCount,
            slideInfoVersion: slideInfoVersion
        )
    }
}
