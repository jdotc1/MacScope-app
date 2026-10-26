import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import MacScope

final class DyldCacheSourcePreflightTests: XCTestCase {
    func testSymbolUUIDCompanionIsBoundSeparatelyFromMappedSubcaches() throws {
        let fixture = DyldLocalSymbolFixture.make()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = directory.appendingPathComponent("cache")
        let symbols = URL(fileURLWithPath: main.path + ".symbols")
        try fixture.main.write(to: main)
        try fixture.companion.write(to: symbols)
        let identity = try DyldCacheSourceIdentityReader.identity(for: main)
        let result = try DyldCacheSourcePreflight.inspect(mainURL: main, expectedMainIdentity: identity,
            maximumAggregateSourceBytes: UInt64(fixture.main.count + fixture.companion.count))
        XCTAssertEqual(result.urls, [main])
        XCTAssertTrue(result.header.subCacheEntries.isEmpty)
        XCTAssertEqual(result.symbolCompanion?.url, symbols)
        XCTAssertEqual(result.symbolCompanion?.bytes, fixture.companion)
        XCTAssertNoThrow(try result.validateProviderSuffixes([]))
        let loaded = try DyldSharedCacheBinaryLoader().load(at: main)
        XCTAssertTrue(loaded.symbols.contains { $0.name == "_ownedLocal" })

        var mismatch = fixture.companion
        mismatch[0x58] ^= 1
        try mismatch.write(to: symbols)
        // Reuse the admitted main header; attaching names does not repeat source sealing.
        XCTAssertNil(DyldSharedCacheBinaryLoader.discoverSymbolCompanion(mainURL: main,
            header: result.header, maximumBytes: UInt64(mismatch.count)))
    }

    func testDescriptorBoundSealObservesCancellationBetweenHashChunks() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("large-cache")
        try Data(repeating: 0xa5, count: 3 * 1024 * 1024).write(to: sourceURL)
        let identity = try DyldCacheSourceIdentityReader.identity(for: sourceURL)
        let probe = DyldPreflightCancellationProbe(cancelAtCheck: 3)
        var budget = try DyldCacheInspectionBudget(
            maximumDurationMilliseconds: 1_000,
            cancellation: AnalysisCancellationToken { probe.shouldCancel() }
        )

        XCTAssertThrowsError(try DyldCacheSourceIdentityReader.sealedMappedData(
            for: sourceURL,
            expectedIdentity: identity,
            maximumBytes: identity.byteCount,
            budget: &budget
        )) { error in
            XCTAssertTrue(error is AnalysisCancelled)
        }
        XCTAssertGreaterThanOrEqual(
            probe.checkCount,
            3,
            "removing chunk-level cancellation checks must make this test fail"
        )
        XCTAssertGreaterThanOrEqual(
            budget.indexedCheckpointCount,
            2,
            "cancellation must be observed during chunked hashing, not only after it finishes"
        )
    }

    func testPreflightEnforcesDeadlineDuringDescriptorBoundSealing() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.bytes.write(to: mainURL, options: .atomic)
        let identity = try DyldCacheSourceIdentityReader.identity(for: mainURL)
        let clock = DyldPreflightClockProbe(expireAtRead: 5, expiredNanoseconds: 2_000_000)
        var budget = try DyldCacheInspectionBudget(
            maximumDurationMilliseconds: 1,
            cancellation: .never,
            nowNanoseconds: { clock.read() }
        )

        XCTAssertThrowsError(try DyldCacheSourcePreflight.inspect(
            mainURL: mainURL,
            expectedMainIdentity: identity,
            maximumAggregateSourceBytes: UInt64(fixture.bytes.count),
            budget: &budget
        )) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .timeout)
        }
        XCTAssertGreaterThanOrEqual(
            clock.readCount,
            5,
            "removing sealing/preflight deadline checkpoints must make this test fail"
        )
    }

    func testSplitCachePreflightBindsExactMainAndSymbolsSibling() throws {
        let fixture = DyldSplitCacheFixture.make()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        let symbolsURL = URL(fileURLWithPath: mainURL.path + ".symbols")
        try fixture.mainBytes.write(to: mainURL, options: .atomic)
        try fixture.symbolsBytes.write(to: symbolsURL, options: .atomic)

        let identity = try DyldCacheSourceIdentityReader.identity(for: mainURL)
        let preflight = try DyldCacheSourcePreflight.inspect(
            mainURL: mainURL,
            expectedMainIdentity: identity,
            maximumAggregateSourceBytes: UInt64(fixture.mainBytes.count + fixture.symbolsBytes.count)
        )

        XCTAssertEqual(preflight.urls.map(\.path), [mainURL.path, symbolsURL.path])
        XCTAssertEqual(preflight.identities.first, identity)
        XCTAssertEqual(preflight.pathReopenAssurance, .identityRecaptureRequired)
        XCTAssertNoThrow(try preflight.validateProviderSuffixes([".symbols"]))
        XCTAssertNoThrow(try preflight.validateOpenedURLs([mainURL, symbolsURL]))
        XCTAssertNoThrow(try preflight.validateProviderObservation(
            suffixes: [".symbols"],
            openedURLs: [mainURL, symbolsURL]
        ))
    }

    func testMappedPreflightReadsTheIdentityBoundFileDescriptor() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.bytes.write(to: mainURL, options: .atomic)
        let identity = try DyldCacheSourceIdentityReader.identity(for: mainURL)

        let mapped = try DyldCacheSourceIdentityReader.mappedData(
            for: mainURL,
            expectedIdentity: identity,
            maximumBytes: UInt64(fixture.bytes.count)
        )
        XCTAssertEqual(mapped, fixture.bytes)
    }

    func testPreflightRejectsAggregateBoundaryPlusOne() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.bytes.write(to: mainURL, options: .atomic)
        let identity = try DyldCacheSourceIdentityReader.identity(for: mainURL)

        XCTAssertThrowsError(try DyldCacheSourcePreflight.inspect(
            mainURL: mainURL,
            expectedMainIdentity: identity,
            maximumAggregateSourceBytes: UInt64(fixture.bytes.count - 1)
        )) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .outputLimitExceeded)
        }
    }

    func testFinalComponentSymlinkAndUnsafeSuffixAreRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let link = directory.appendingPathComponent("link")
        try Data("fixture".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try DyldCacheSourceIdentityReader.identity(for: link)) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .sourceIsNotRegularFile)
        }
        for suffix in ["", ".", "..", "../foreign", ".1/foreign", ".1\\foreign", "/absolute"] {
            XCTAssertThrowsError(try DyldCacheSourceIdentityReader.safeSiblingURL(
                mainURL: target,
                suffix: suffix
            ))
        }
    }

    func testPostOpenValidationRejectsSourceReplacement() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.bytes.write(to: mainURL, options: .atomic)
        let identity = try DyldCacheSourceIdentityReader.identity(for: mainURL)
        let preflight = try DyldCacheSourcePreflight.inspect(
            mainURL: mainURL,
            expectedMainIdentity: identity,
            maximumAggregateSourceBytes: UInt64(fixture.bytes.count + 1)
        )

        var changed = fixture.bytes
        changed.append(0)
        try changed.write(to: mainURL, options: .atomic)

        XCTAssertThrowsError(try preflight.validateProviderObservation(
            suffixes: [],
            openedURLs: [mainURL]
        )) { error in
            XCTAssertEqual(
                error as? DyldCacheAnalysisProviderError,
                .sourceChangedDuringInspection
            )
        }
    }

    func testPostOpenValidationRejectsSameInodeRewriteWithRestoredSizeAndMTime() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.bytes.write(to: mainURL, options: .atomic)
        let identity = try DyldCacheSourceIdentityReader.identity(for: mainURL)
        let preflight = try DyldCacheSourcePreflight.inspect(
            mainURL: mainURL,
            expectedMainIdentity: identity,
            maximumAggregateSourceBytes: UInt64(fixture.bytes.count)
        )

        var originalMetadata = stat()
        XCTAssertEqual(mainURL.path.withCString { stat($0, &originalMetadata) }, 0)
        let handle = try FileHandle(forWritingTo: mainURL)
        try handle.seek(toOffset: UInt64(fixture.bytes.count - 1))
        try handle.write(contentsOf: Data([fixture.bytes.last! ^ 0xff]))
        try handle.synchronize()
        try handle.close()
        var exactTimes = [originalMetadata.st_atimespec, originalMetadata.st_mtimespec]
        let restoreResult = exactTimes.withUnsafeMutableBufferPointer { times in
            mainURL.path.withCString {
                utimensat(AT_FDCWD, $0, times.baseAddress, 0)
            }
        }
        XCTAssertEqual(restoreResult, 0)
        XCTAssertEqual(
            try DyldCacheSourceIdentityReader.identity(for: mainURL),
            identity,
            "the adversarial rewrite must preserve every legacy metadata-identity field"
        )

        XCTAssertThrowsError(try preflight.validateProviderObservation(
            suffixes: [],
            openedURLs: [mainURL]
        )) { error in
            XCTAssertEqual(
                error as? DyldCacheAnalysisProviderError,
                .sourceChangedDuringInspection
            )
        }
    }

    func testSelectedArtifactSHAIsRecomputedFromAdmittedCacheContent() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainURL = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try fixture.bytes.write(to: mainURL, options: .atomic)
        let identity = try DyldCacheSourceIdentityReader.identity(for: mainURL)
        let preflight = try DyldCacheSourcePreflight.inspect(
            mainURL: mainURL,
            expectedMainIdentity: identity,
            maximumAggregateSourceBytes: UInt64(fixture.bytes.count)
        )
        let parser = DyldSharedCacheParser()
        let header = try parser.parseHeader(fixture.bytes)
        let selected = try XCTUnwrap(header.images.first)
        let projected = try parser.projectImage(
            selected,
            using: parser.makeMultiFileReader(
                mainBytes: fixture.bytes,
                header: header,
                subCacheDatas: [:]
            ),
            header: header
        )
        let digest = SHA256.hash(data: projected)
            .map { String(format: "%02x", $0) }
            .joined()
        let artifact = try MachOSliceArtifactIdentity(
            uuid: nil,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: digest,
            selectedSliceByteCount: UInt64(projected.count)
        )
        let validSubject = DyldCacheAnalysisSubjectIdentity(
            artifactIdentity: artifact,
            imageIdentity: DyldCacheImageIdentity(
                path: selected.path,
                loadAddress: selected.address
            ),
            analysisGeneration: 1
        )
        XCTAssertNoThrow(try preflight.validateSelectedArtifact(validSubject))

        let wrongArtifact = try MachOSliceArtifactIdentity(
            uuid: nil,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "0", count: 64),
            selectedSliceByteCount: UInt64(projected.count)
        )
        XCTAssertThrowsError(try preflight.validateSelectedArtifact(
            DyldCacheAnalysisSubjectIdentity(
                artifactIdentity: wrongArtifact,
                imageIdentity: validSubject.imageIdentity,
                analysisGeneration: 1
            )
        )) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .subjectIdentityMismatch)
        }
    }

    func testMachOKitAdmissionRejectsLegacyFallbackWhenProviderSelectsModernImages() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        let header = try DyldSharedCacheParser().parseHeader(fixture.bytes)

        XCTAssertThrowsError(try DyldCacheSourcePreflight.validateMachOKitReadSurface(
            bytes: fixture.bytes,
            parsedHeader: header,
            requestedCategories: [.catalog],
            isMainCache: true
        )) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .providerRejectedInput)
        }
    }

    func testMachOKitAdmissionRejectsOutOfRangeSlideArrayBeforeVendorRead() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        var bytes = fixture.bytes
        replaceUInt32(&bytes, at: 0x1c0, with: UInt32(fixture.imagesOffset))
        replaceUInt32(&bytes, at: 0x1c4, with: 1)
        replaceUInt32(&bytes, at: 0x138, with: UInt32(bytes.count - 8))
        replaceUInt32(&bytes, at: 0x13c, with: 1)
        let header = try DyldSharedCacheParser().parseHeader(bytes)

        XCTAssertThrowsError(try DyldCacheSourcePreflight.validateMachOKitReadSurface(
            bytes: bytes,
            parsedHeader: header,
            requestedCategories: [.slideInfo],
            isMainCache: true
        )) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .providerRejectedInput)
        }
    }

    func testMachOKitAdmissionRejectsSecondaryCategoryRangesBeforeVendorRead() throws {
        let fixture = DyldCacheFixture.makeSingleImageCache()
        var base = fixture.bytes
        replaceUInt32(&base, at: 0x1c0, with: UInt32(fixture.imagesOffset))
        replaceUInt32(&base, at: 0x1c4, with: 1)
        let header = try DyldSharedCacheParser().parseHeader(base)

        var local = base
        let localOffset = local.count - 24
        replaceUInt64(&local, at: 0x48, with: UInt64(localOffset))
        replaceUInt64(&local, at: 0x50, with: 24)
        replaceUInt32(&local, at: localOffset, with: 24)
        replaceUInt32(&local, at: localOffset + 4, with: 1)
        assertRejected(local, header: header, category: .localSymbols)

        var trie = base
        replaceUInt64(&trie, at: 0x108, with: UInt64.max - 15)
        replaceUInt64(&trie, at: 0x110, with: 16)
        assertRejected(trie, header: header, category: .trieSummary)

        var optimization = base
        replaceUInt64(&optimization, at: 0x178, with: UInt64.max - 15)
        replaceUInt64(&optimization, at: 0x180, with: 16)
        assertRejected(optimization, header: header, category: .optimizationSummary)

        var prebuilt = base
        replaceUInt64(&prebuilt, at: 0x148, with: UInt64.max - 31)
        assertRejected(prebuilt, header: header, category: .prebuiltLoaderSummary)
    }

    private func assertRejected(
        _ bytes: Data,
        header: DyldSharedCacheHeader,
        category: DyldCacheAnalysisCategory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try DyldCacheSourcePreflight.validateMachOKitReadSurface(
            bytes: bytes,
            parsedHeader: header,
            requestedCategories: [category],
            isMainCache: true
        ), file: file, line: line) { error in
            XCTAssertEqual(
                error as? DyldCacheAnalysisProviderError,
                .providerRejectedInput,
                file: file,
                line: line
            )
        }
    }

    private func replaceUInt32(_ data: inout Data, at offset: Int, with value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    private func replaceUInt64(_ data: inout Data, at offset: Int, with value: UInt64) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + 8), with: bytes)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-DyldPreflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class DyldPreflightCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAtCheck: Int
    private var checks = 0

    init(cancelAtCheck: Int) {
        self.cancelAtCheck = cancelAtCheck
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= cancelAtCheck
    }
}

private final class DyldPreflightClockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let expireAtRead: Int
    private let expiredNanoseconds: UInt64
    private var reads = 0

    init(expireAtRead: Int, expiredNanoseconds: UInt64) {
        self.expireAtRead = expireAtRead
        self.expiredNanoseconds = expiredNanoseconds
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return reads >= expireAtRead ? expiredNanoseconds : 0
    }
}
