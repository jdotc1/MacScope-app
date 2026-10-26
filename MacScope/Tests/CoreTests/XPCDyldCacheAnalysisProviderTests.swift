import Foundation
import XCTest
@testable import MacScope

final class XPCDyldCacheAnalysisProviderTests: XCTestCase {
    private let codec = DyldCacheAnalysisWireCodec()

    func testSuccessfulInspectionVerifiesExactSubjectSourceAndProvider() async throws {
        let source = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let subject = DyldCacheAnalysisTestFixtures.subject(generation: 41)
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: source)
        let transport = MockDyldCacheAnalysisTransport()
        transport.enqueue(.reply(codec.encodeReply(.success(
            DyldCacheAnalysisTestFixtures.result(
                requestID: DyldCacheAnalysisTestFixtures.requestID,
                sourceIdentity: sourceIdentity,
                subject: subject,
                requestedCategories: [.catalog]
            )
        ))))
        let provider = makeProvider(transport: transport)

        let result = try await provider.inspectCache(
            at: source,
            expectedSourceIdentity: sourceIdentity,
            subject: subject,
            categories: [.catalog]
        )

        XCTAssertEqual(result.subject, subject)
        XCTAssertEqual(result.sourceIdentity, sourceIdentity)
        XCTAssertEqual(result.provider, .machOKit0522)
        XCTAssertEqual(provider.connectionState, .idle)
    }

    func testStaleGenerationReplyIsRejectedAndNeverPublished() async throws {
        let source = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let subject = DyldCacheAnalysisTestFixtures.subject(generation: 41)
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: source)
        let transport = MockDyldCacheAnalysisTransport()
        transport.enqueue(.reply(codec.encodeReply(.success(
            DyldCacheAnalysisTestFixtures.result(
                requestID: DyldCacheAnalysisTestFixtures.requestID,
                sourceIdentity: sourceIdentity,
                subject: DyldCacheAnalysisTestFixtures.subject(generation: 40),
                requestedCategories: [.catalog]
            )
        ))))
        let provider = makeProvider(transport: transport)

        await XCTAssertThrowsDyldError(
            try await provider.inspectCache(
                at: source,
                expectedSourceIdentity: sourceIdentity,
                subject: subject,
                categories: [.catalog]
            )
        ) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .staleGeneration)
        }
        XCTAssertEqual(provider.connectionState, .idle)
    }

    func testSameGenerationWrongArtifactOrImageIsRejected() async throws {
        let source = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let subject = DyldCacheAnalysisTestFixtures.subject(generation: 41)
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: source)

        for driftedSubject in [
            DyldCacheAnalysisTestFixtures.subject(
                generation: 41,
                artifact: DyldCacheAnalysisTestFixtures.artifactIdentity(seed: "b")
            ),
            DyldCacheAnalysisTestFixtures.subject(
                generation: 41,
                image: DyldCacheAnalysisTestFixtures.image("/usr/lib/other.dylib", 0x2_0000_0000)
            ),
        ] {
            let transport = MockDyldCacheAnalysisTransport()
            transport.enqueue(.reply(codec.encodeReply(.success(
                DyldCacheAnalysisTestFixtures.result(
                    requestID: DyldCacheAnalysisTestFixtures.requestID,
                    sourceIdentity: sourceIdentity,
                    subject: driftedSubject,
                    requestedCategories: [.catalog]
                )
            ))))
            let provider = makeProvider(transport: transport)

            await XCTAssertThrowsDyldError(
                try await provider.inspectCache(
                    at: source,
                    expectedSourceIdentity: sourceIdentity,
                    subject: subject,
                    categories: [.catalog]
                )
            ) { error in
                XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .subjectIdentityMismatch)
            }
        }
    }

    func testSourceOrProviderIdentityDriftIsRejectedAtClientBoundary() async throws {
        let source = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let subject = DyldCacheAnalysisTestFixtures.subject()
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: source)

        let sourceDriftTransport = MockDyldCacheAnalysisTransport()
        sourceDriftTransport.enqueue(.reply(codec.encodeReply(.success(
            DyldCacheAnalysisTestFixtures.result(
                sourceIdentity: DyldCacheAnalysisTestFixtures.sourceIdentity,
                subject: subject,
                requestedCategories: [.catalog]
            )
        ))))
        await XCTAssertThrowsDyldError(
            try await makeProvider(transport: sourceDriftTransport).inspectCache(
                at: source,
                expectedSourceIdentity: sourceIdentity,
                subject: subject,
                categories: [.catalog]
            )
        ) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .sourceIdentityMismatch)
        }

        let wrongProvider = DyldCacheAnalysisProviderIdentity(
            providerID: "unexpected",
            version: "0",
            sourceRevision: String(repeating: "0", count: 40),
            sourceArchiveSHA256: String(repeating: "0", count: 64)
        )
        let providerDriftTransport = MockDyldCacheAnalysisTransport()
        let baseResult = DyldCacheAnalysisTestFixtures.result(
            sourceIdentity: sourceIdentity,
            subject: subject,
            requestedCategories: [.catalog]
        )
        let driftedResult = DyldCacheAnalysisResult(
            version: baseResult.version,
            requestID: baseResult.requestID,
            subject: baseResult.subject,
            provider: wrongProvider,
            sourceIdentity: baseResult.sourceIdentity,
            header: baseResult.header,
            files: baseResult.files,
            images: baseResult.images,
            mappings: baseResult.mappings,
            localSymbols: baseResult.localSymbols,
            dylibTrieEntries: baseResult.dylibTrieEntries,
            programTrieEntries: baseResult.programTrieEntries,
            optimizationSummary: baseResult.optimizationSummary,
            prebuiltLoaderSummary: baseResult.prebuiltLoaderSummary,
            coverage: baseResult.coverage,
            completion: baseResult.completion,
            warnings: baseResult.warnings
        )
        providerDriftTransport.enqueue(.reply(codec.encodeReply(.success(driftedResult))))

        await XCTAssertThrowsDyldError(
            try await makeProvider(transport: providerDriftTransport).inspectCache(
                at: source,
                expectedSourceIdentity: sourceIdentity,
                subject: subject,
                categories: [.catalog]
            )
        ) { error in
            guard case AnalysisWorkerError.malformedReply = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPartialReplyRemainsExplicitInsteadOfBeingPromotedToComplete() async throws {
        let source = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let subject = DyldCacheAnalysisTestFixtures.subject()
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: source)
        let transport = MockDyldCacheAnalysisTransport()
        transport.enqueue(.reply(codec.encodeReply(.success(
            DyldCacheAnalysisTestFixtures.result(
                sourceIdentity: sourceIdentity,
                subject: subject,
                requestedCategories: [.catalog],
                completion: .partial
            )
        ))))
        let provider = makeProvider(transport: transport)

        let result = try await provider.inspectCache(
            at: source,
            expectedSourceIdentity: sourceIdentity,
            subject: subject,
            categories: [.catalog]
        )

        XCTAssertEqual(result.completion, .partial)
    }

    func testDeadlineCancelsTransportAndReturnsTypedTimeout() async throws {
        let source = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let transport = MockDyldCacheAnalysisTransport(outcomes: [.hang])
        let provider = makeProvider(transport: transport)
        let limits = DyldCacheAnalysisLimits(
            maximumImages: 1,
            maximumMappings: 1,
            maximumLocalSymbols: 1,
            maximumTrieEntries: 1,
            maximumWarnings: 1,
            maximumOutputBytes: 16_384,
            maximumSourceBytes: 4_096,
            maximumDurationMilliseconds: 10
        )

        await XCTAssertThrowsDyldError(
            try await provider.inspectCache(
                at: source,
                expectedSourceIdentity: try DyldCacheSourceIdentityReader.identity(for: source),
                subject: DyldCacheAnalysisTestFixtures.subject(),
                categories: [.catalog],
                limits: limits
            )
        ) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .timeout)
        }
        XCTAssertEqual(transport.retiredRequestIDs, [DyldCacheAnalysisTestFixtures.requestID])
        XCTAssertEqual(provider.connectionState, .invalidated)
    }

    func testCooperativeCancellationForwardsExactlyOnce() async throws {
        let source = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let transport = MockDyldCacheAnalysisTransport(outcomes: [.hang])
        let cancellation = MutableDyldCancellationToken()
        let provider = makeProvider(transport: transport)

        let task = Task {
            try await provider.inspectCache(
                at: source,
                expectedSourceIdentity: try DyldCacheSourceIdentityReader.identity(for: source),
                subject: DyldCacheAnalysisTestFixtures.subject(),
                categories: [.catalog],
                cancellation: cancellation.token
            )
        }
        while transport.calls.isEmpty { await Task.yield() }
        cancellation.cancel()

        await XCTAssertThrowsDyldError(try await task.value) { error in
            XCTAssertTrue(error is AnalysisCancelled)
        }
        XCTAssertEqual(transport.cancelledRequestIDs, [DyldCacheAnalysisTestFixtures.requestID])
        XCTAssertEqual(provider.connectionState, .idle)
    }

    func testTimeoutRequiresResetAndLateReplyCannotSatisfyNextGeneration() async throws {
        let source = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: source)
        let timedOutSubject = DyldCacheAnalysisTestFixtures.subject(generation: 1)
        let currentSubject = DyldCacheAnalysisTestFixtures.subject(generation: 2)
        let transport = MockDyldCacheAnalysisTransport(outcomes: [
            .delay(
                nanoseconds: 50_000_000,
                then: .reply(codec.encodeReply(.success(
                    DyldCacheAnalysisTestFixtures.result(
                        sourceIdentity: sourceIdentity,
                        subject: timedOutSubject,
                        requestedCategories: [.catalog]
                    )
                )))
            ),
            .reply(codec.encodeReply(.success(
                DyldCacheAnalysisTestFixtures.result(
                    sourceIdentity: sourceIdentity,
                    subject: currentSubject,
                    requestedCategories: [.catalog]
                )
            ))),
        ])
        let provider = makeProvider(transport: transport)
        let shortLimits = DyldCacheAnalysisLimits(
            maximumImages: 1,
            maximumMappings: 1,
            maximumLocalSymbols: 1,
            maximumTrieEntries: 1,
            maximumWarnings: 1,
            maximumOutputBytes: 16_384,
            maximumSourceBytes: 4_096,
            maximumDurationMilliseconds: 5
        )

        await XCTAssertThrowsDyldError(
            try await provider.inspectCache(
                at: source,
                expectedSourceIdentity: sourceIdentity,
                subject: timedOutSubject,
                categories: [.catalog],
                limits: shortLimits
            )
        ) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisProviderError, .timeout)
        }

        await XCTAssertThrowsDyldError(
            try await provider.inspectCache(
                at: source,
                expectedSourceIdentity: sourceIdentity,
                subject: currentSubject,
                categories: [.catalog]
            )
        ) { error in
            guard case AnalysisWorkerError.workerUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        provider.resetConnection()

        let current = try await provider.inspectCache(
            at: source,
            expectedSourceIdentity: sourceIdentity,
            subject: currentSubject,
            categories: [.catalog]
        )
        XCTAssertEqual(current.subject, currentSubject)
    }

    private func makeProvider(
        transport: MockDyldCacheAnalysisTransport
    ) -> XPCDyldCacheAnalysisProvider {
        XPCDyldCacheAnalysisProvider(
            transport: transport,
            codec: codec,
            makeRequestID: { DyldCacheAnalysisTestFixtures.requestID }
        )
    }

    private func temporaryFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-dyld-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("dyld_shared_cache_arm64e")
        try Data([0x64, 0x79, 0x6c, 0x64]).write(to: file)
        return file
    }
}

private final class MutableDyldCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var token: AnalysisCancellationToken {
        AnalysisCancellationToken { [weak self] in self?.isCancelled ?? true }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private func XCTAssertThrowsDyldError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
