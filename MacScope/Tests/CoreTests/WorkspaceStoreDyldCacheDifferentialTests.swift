import Foundation
import XCTest
@testable import MacScope

@MainActor
final class WorkspaceStoreDyldCacheDifferentialTests: XCTestCase {
    func testProviderErrorCannotFailOrReplaceAuthoritativeImport() async throws {
        let source = try makeCacheSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let store = makeStore(provider: WorkspaceDyldCacheProvider(failure: .providerUnavailable))

        await store.importBinary(url: source)
        let imported = try XCTUnwrap(store.snapshot.binaries.first)
        let importedInstructionCount = store.snapshot.instructions.count
        XCTAssertNil(store.lastIssue)
        XCTAssertGreaterThan(importedInstructionCount, 0)

        await store.awaitPendingDyldCacheDifferential()

        XCTAssertEqual(store.snapshot.binaries.first?.id, imported.id)
        XCTAssertEqual(store.snapshot.instructions.count, importedInstructionCount)
        XCTAssertNil(store.lastIssue)
        XCTAssertEqual(store.dyldCacheDifferentialReport?.state, .error)
        XCTAssertEqual(store.dyldCacheDifferentialReport?.failure, .providerUnavailable)
        XCTAssertNil(store.dyldCacheDifferentialReport?.differential)
    }

    func testDistinctWindowStoresAllocateIndependentSupplementalGenerations() async throws {
        let firstSource = try makeCacheSource()
        let secondSource = try makeCacheSource()
        defer {
            try? FileManager.default.removeItem(at: firstSource)
            try? FileManager.default.removeItem(at: secondSource)
        }
        let first = makeStore(provider: WorkspaceDyldCacheProvider())
        let second = makeStore(provider: WorkspaceDyldCacheProvider())

        await first.importBinary(url: firstSource)
        await second.importBinary(url: secondSource)
        await first.awaitPendingDyldCacheDifferential()
        await second.awaitPendingDyldCacheDifferential()

        XCTAssertEqual(first.dyldCacheDifferentialReport?.binding?.subject.analysisGeneration, 1)
        XCTAssertEqual(second.dyldCacheDifferentialReport?.binding?.subject.analysisGeneration, 1)

        await first.importBinary(url: firstSource)
        await first.awaitPendingDyldCacheDifferential()

        XCTAssertEqual(first.dyldCacheDifferentialReport?.binding?.subject.analysisGeneration, 2)
        XCTAssertEqual(second.dyldCacheDifferentialReport?.binding?.subject.analysisGeneration, 1)
    }

    func testAuthoritativeNonDyldReplacementRetiresPriorSupplementalReport() async throws {
        let cacheSource = try makeCacheSource()
        let replacementSource = try makeELFSource()
        defer {
            try? FileManager.default.removeItem(at: cacheSource)
            try? FileManager.default.removeItem(at: replacementSource)
        }
        let store = makeStore(provider: WorkspaceDyldCacheProvider())

        await store.importBinary(url: cacheSource)
        await store.awaitPendingDyldCacheDifferential()
        XCTAssertNotNil(store.dyldCacheDifferentialReport)

        await store.importBinary(url: replacementSource)

        XCTAssertNil(store.lastIssue)
        XCTAssertEqual(store.snapshot.binaries.first?.path, replacementSource.path)
        XCTAssertEqual(store.snapshot.binaries.first?.kind, "ELF executable")
        XCTAssertNil(store.snapshot.binaries.first?.artifactIdentity)
        XCTAssertNil(store.dyldCacheDifferentialReport)
    }

    func testFocusSwitchToDifferentImageRetiresSupplementalReport() async throws {
        let primarySource = try makeCacheSource()
        let secondarySource = try makeCacheSource()
        defer {
            try? FileManager.default.removeItem(at: primarySource)
            try? FileManager.default.removeItem(at: secondarySource)
        }
        let store = makeStore(provider: WorkspaceDyldCacheProvider())

        await store.importBinary(url: primarySource)
        await store.awaitPendingDyldCacheDifferential()
        await store.loadAdditionalBinary(url: secondarySource)
        await store.awaitPendingDyldCacheDifferential()
        let secondarySlot = store.focusedImageSlot
        XCTAssertNotEqual(secondarySlot, .primary)
        XCTAssertNotNil(store.dyldCacheDifferentialReport)

        store.focusImage(.primary)

        XCTAssertEqual(store.focusedImageSlot, .primary)
        XCTAssertNil(store.dyldCacheDifferentialReport)
    }

    private func makeStore(provider: WorkspaceDyldCacheProvider) -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "dyld-differential",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil,
            dyldCacheDifferentialWorkflow:
                DyldCacheDifferentialWorkflowCoordinator(provider: provider)
        )
    }

    private func makeCacheSource() throws -> URL {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-store-dyld-\(UUID().uuidString)")
        try DyldCacheFixture.makeSingleImageCache().bytes.write(to: source, options: .atomic)
        return source
    }

    private func makeELFSource() throws -> URL {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-store-ordinary-\(UUID().uuidString)")
        var bytes = Data(repeating: 0, count: 0x1001)
        bytes.replaceSubrange(
            0..<16,
            with: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
        )
        replaceLittleEndian(UInt16(2), at: 16, in: &bytes) // ET_EXEC
        replaceLittleEndian(UInt16(62), at: 18, in: &bytes) // EM_X86_64
        replaceLittleEndian(UInt32(1), at: 20, in: &bytes)
        replaceLittleEndian(UInt64(0x400000), at: 24, in: &bytes)
        replaceLittleEndian(UInt64(64), at: 32, in: &bytes)
        replaceLittleEndian(UInt16(64), at: 52, in: &bytes)
        replaceLittleEndian(UInt16(56), at: 54, in: &bytes)
        replaceLittleEndian(UInt16(1), at: 56, in: &bytes)
        replaceLittleEndian(UInt32(1), at: 64, in: &bytes) // PT_LOAD
        replaceLittleEndian(UInt32(5), at: 68, in: &bytes) // PF_R | PF_X
        replaceLittleEndian(UInt64(0x1000), at: 72, in: &bytes)
        replaceLittleEndian(UInt64(0x400000), at: 80, in: &bytes)
        replaceLittleEndian(UInt64(0x400000), at: 88, in: &bytes)
        replaceLittleEndian(UInt64(1), at: 96, in: &bytes)
        replaceLittleEndian(UInt64(1), at: 104, in: &bytes)
        replaceLittleEndian(UInt64(0x1000), at: 112, in: &bytes)
        bytes[0x1000] = 0xc3 // x86_64 ret
        try bytes.write(to: source, options: .atomic)
        return source
    }

    private func replaceLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        at offset: Int,
        in data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { rawBytes in
            data.replaceSubrange(offset..<(offset + rawBytes.count), with: rawBytes)
        }
    }
}

private struct WorkspaceDyldCacheProvider: DyldCacheAnalysisProviding {
    let failure: DyldCacheAnalysisProviderError?

    init(failure: DyldCacheAnalysisProviderError? = nil) {
        self.failure = failure
    }

    func inspectCache(
        at url: URL,
        expectedSourceIdentity: DyldCacheFileIdentity,
        subject: DyldCacheAnalysisSubjectIdentity,
        categories: [DyldCacheAnalysisCategory],
        limits: DyldCacheAnalysisLimits,
        cancellation: AnalysisCancellationToken
    ) async throws -> DyldCacheAnalysisResult {
        _ = url
        _ = limits
        try cancellation.check()
        if let failure { throw failure }
        return DyldCacheAnalysisTestFixtures.result(
            sourceIdentity: expectedSourceIdentity,
            subject: subject,
            images: [DyldCacheAnalysisTestFixtures.imageRecord(
                subject.imageIdentity.path,
                subject.imageIdentity.loadAddress
            )],
            requestedCategories: categories
        )
    }
}
