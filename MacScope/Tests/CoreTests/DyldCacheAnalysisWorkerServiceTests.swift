import Foundation
import XCTest
@testable import MacScope

final class DyldCacheAnalysisWorkerServiceTests: XCTestCase {
    private let codec = DyldCacheAnalysisWireCodec()

    func testSuccessfulProviderResultIsExactlyRequestBound() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let canonicalRequest = try request.validated()
        let provider = StubDyldCacheWorkerProvider { observed, cancellation in
            XCTAssertEqual(observed, canonicalRequest)
            try cancellation.check()
            return DyldCacheAnalysisTestFixtures.result(
                requestID: observed.requestID,
                sourceIdentity: observed.expectedSourceIdentity,
                subject: observed.subject
            )
        }
        let service = DyldCacheAnalysisWorkerService(provider: provider, codec: codec)

        let reply = service.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )

        XCTAssertEqual(try codec.decodeReply(reply).subject, request.subject)
        XCTAssertEqual(provider.callCount, 1)
    }

    func testEnvelopeRequestIDMismatchFailsBeforeProviderRuns() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let provider = StubDyldCacheWorkerProvider { _, _ in
            XCTFail("provider must not run")
            return DyldCacheAnalysisTestFixtures.result()
        }
        let service = DyldCacheAnalysisWorkerService(provider: provider, codec: codec)

        let reply = service.handle(
            requestData: try codec.encodeRequest(request),
            requestID: UUID()
        )

        assertRemoteFailure(reply, code: .invalidRequest)
        XCTAssertEqual(provider.callCount, 0)
    }

    func testStaleGenerationAndSubjectDriftAreRejectedAfterProviderReturns() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let staleProvider = StubDyldCacheWorkerProvider { observed, _ in
            DyldCacheAnalysisTestFixtures.result(
                subject: DyldCacheAnalysisTestFixtures.subject(
                    generation: observed.subject.analysisGeneration + 1
                )
            )
        }
        let staleService = DyldCacheAnalysisWorkerService(provider: staleProvider, codec: codec)
        let staleReply = staleService.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )
        assertRemoteFailure(staleReply, code: .staleGeneration)

        let driftProvider = StubDyldCacheWorkerProvider { observed, _ in
            DyldCacheAnalysisTestFixtures.result(
                subject: DyldCacheAnalysisTestFixtures.subject(
                    generation: observed.subject.analysisGeneration,
                    image: DyldCacheAnalysisTestFixtures.image("/usr/lib/drift.dylib", 0x2_0000_0000)
                )
            )
        }
        let driftService = DyldCacheAnalysisWorkerService(provider: driftProvider, codec: codec)
        let driftReply = driftService.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )
        assertRemoteFailure(driftReply, code: .subjectIdentityMismatch)
    }

    func testSourceAndRequestIdentityDriftAreRejectedAfterProviderReturns() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let wrongRequestProvider = StubDyldCacheWorkerProvider { observed, _ in
            DyldCacheAnalysisTestFixtures.result(
                requestID: UUID(),
                sourceIdentity: observed.expectedSourceIdentity,
                subject: observed.subject
            )
        }
        let wrongRequestService = DyldCacheAnalysisWorkerService(
            provider: wrongRequestProvider,
            codec: codec
        )
        let wrongRequestReply = wrongRequestService.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )
        assertRemoteFailure(wrongRequestReply, code: .invalidRequest)

        let wrongSourceProvider = StubDyldCacheWorkerProvider { observed, _ in
            DyldCacheAnalysisTestFixtures.result(
                requestID: observed.requestID,
                sourceIdentity: DyldCacheFileIdentity(
                    deviceID: 99,
                    fileID: 99,
                    byteCount: 99,
                    modificationTimeSeconds: 99,
                    modificationTimeNanoseconds: 99
                ),
                subject: observed.subject
            )
        }
        let wrongSourceService = DyldCacheAnalysisWorkerService(
            provider: wrongSourceProvider,
            codec: codec
        )
        let wrongSourceReply = wrongSourceService.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )
        assertRemoteFailure(wrongSourceReply, code: .sourceIdentityMismatch)
    }

    func testPartialResultRemainsExplicitAndAccepted() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let provider = StubDyldCacheWorkerProvider { observed, _ in
            DyldCacheAnalysisTestFixtures.result(
                requestID: observed.requestID,
                sourceIdentity: observed.expectedSourceIdentity,
                subject: observed.subject,
                completion: .partial
            )
        }
        let service = DyldCacheAnalysisWorkerService(provider: provider, codec: codec)
        let reply = service.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )

        XCTAssertEqual(try codec.decodeReply(reply).completion, .partial)
    }

    func testCancellationTimeoutAndOutputLimitRemainDistinct() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let cancellationProvider = StubDyldCacheWorkerProvider { _, cancellation in
            try cancellation.check()
            return DyldCacheAnalysisTestFixtures.result()
        }
        let cancellationService = DyldCacheAnalysisWorkerService(
            provider: cancellationProvider,
            codec: codec
        )
        cancellationService.cancel(requestID: request.requestID)
        let cancelledReply = cancellationService.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )
        XCTAssertThrowsError(try codec.decodeReply(cancelledReply)) { error in
            XCTAssertTrue(error is AnalysisCancelled)
        }

        let timeoutProvider = StubDyldCacheWorkerProvider { _, _ in
            throw DyldCacheAnalysisProviderError.timeout
        }
        let timeoutService = DyldCacheAnalysisWorkerService(provider: timeoutProvider, codec: codec)
        let timeoutReply = timeoutService.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )
        assertRemoteFailure(timeoutReply, code: .timeout)

        let tinyLimits = DyldCacheAnalysisLimits(
            maximumImages: 1,
            maximumMappings: 1,
            maximumLocalSymbols: 1,
            maximumTrieEntries: 1,
            maximumWarnings: 1,
            maximumOutputBytes: 1,
            maximumSourceBytes: 1,
            maximumDurationMilliseconds: 1_000
        )
        let tinyRequest = DyldCacheAnalysisTestFixtures.request(limits: tinyLimits)
        let outputProvider = StubDyldCacheWorkerProvider { observed, _ in
            DyldCacheAnalysisTestFixtures.result(
                requestID: observed.requestID,
                sourceIdentity: observed.expectedSourceIdentity,
                subject: observed.subject
            )
        }
        let outputService = DyldCacheAnalysisWorkerService(provider: outputProvider, codec: codec)
        let outputReply = outputService.handle(
            requestData: try codec.encodeRequest(tinyRequest),
            requestID: tinyRequest.requestID
        )
        assertRemoteFailure(outputReply, code: .outputLimitExceeded)
    }

    func testUnknownVendorDiagnosticIsCollapsedAtWorkerBoundary() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let provider = StubDyldCacheWorkerProvider { _, _ in
            throw NSError(
                domain: "/tmp/private/vendor-diagnostic",
                code: 91,
                userInfo: [NSLocalizedDescriptionKey: "third-party parser detail"]
            )
        }
        let service = DyldCacheAnalysisWorkerService(provider: provider, codec: codec)

        let reply = service.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )

        assertRemoteFailure(reply, code: .providerRejectedInput)
        let text = String(decoding: reply, as: UTF8.self)
        XCTAssertFalse(text.contains("/tmp/private"))
        XCTAssertFalse(text.contains("third-party"))
    }

    func testMalformedProviderResultIsRejectedBeforeWorkerEncoding() throws {
        let request = DyldCacheAnalysisTestFixtures.request()
        let malformed = try DyldCacheAnalysisTestFixtures.mutatingResult(
            DyldCacheAnalysisTestFixtures.result()
        ) { object in
            var coverage = object["coverage"] as! [[String: Any]]
            coverage[0]["returnedRecordCount"] = 1
            object["coverage"] = coverage
        }
        let provider = StubDyldCacheWorkerProvider { _, _ in malformed }
        let service = DyldCacheAnalysisWorkerService(provider: provider, codec: codec)

        let reply = service.handle(
            requestData: try codec.encodeRequest(request),
            requestID: request.requestID
        )

        assertRemoteFailure(reply, code: .providerRejectedInput)
    }

    private func assertRemoteFailure(
        _ data: Data,
        code: DyldCacheAnalysisFailureCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try codec.decodeReply(data), file: file, line: line) { error in
            XCTAssertEqual(
                error as? RemoteDyldCacheAnalysisFailure,
                RemoteDyldCacheAnalysisFailure(code: code),
                file: file,
                line: line
            )
        }
    }
}
private final class StubDyldCacheWorkerProvider: DyldCacheAnalysisWorkerProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (DyldCacheAnalysisRequest, AnalysisCancellationToken) throws -> DyldCacheAnalysisResult
    private var count = 0

    init(
        handler: @escaping (DyldCacheAnalysisRequest, AnalysisCancellationToken) throws -> DyldCacheAnalysisResult
    ) {
        self.handler = handler
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func inspectCache(
        request: DyldCacheAnalysisRequest,
        cancellation: AnalysisCancellationToken
    ) throws -> DyldCacheAnalysisResult {
        lock.lock()
        count += 1
        lock.unlock()
        return try handler(request, cancellation)
    }
}
