import Foundation
import XCTest
@testable import MacScope

final class DyldCacheAnalysisWireCodecTests: XCTestCase {
    private let codec = DyldCacheAnalysisWireCodec()

    func testRequestRoundTripPreservesExactSubjectAndCanonicalizesCategories() throws {
        let request = DyldCacheAnalysisTestFixtures.request()

        let first = try codec.encodeRequest(request)
        let second = try codec.encodeRequest(request)

        XCTAssertEqual(first, second)
        let decoded = try codec.decodeRequest(first)
        XCTAssertEqual(decoded.requestID, request.requestID)
        XCTAssertEqual(decoded.expectedSourceIdentity, request.expectedSourceIdentity)
        XCTAssertEqual(decoded.subject, request.subject)
        XCTAssertEqual(decoded.categories, [.catalog, .mappings])
    }

    func testEncodeRejectsInvalidRequestInsteadOfPublishingUnvalidatedFields() {
        let invalid = DyldCacheAnalysisRequest(
            url: URL(string: "https://example.invalid/cache")!,
            expectedSourceIdentity: DyldCacheAnalysisTestFixtures.sourceIdentity,
            subject: DyldCacheAnalysisTestFixtures.subject(),
            categories: [.catalog],
            limits: .default,
            requestID: DyldCacheAnalysisTestFixtures.requestID
        )

        XCTAssertThrowsError(try codec.encodeRequest(invalid)) { error in
            XCTAssertEqual(error as? DyldCacheAnalysisModelError, .invalidPath)
        }
    }

    func testDecodeRejectsMalformedOversizedAndConflictingReplies() throws {
        XCTAssertThrowsError(try codec.decodeRequest(Data("not-json".utf8)))
        XCTAssertThrowsError(
            try codec.decodeRequest(Data(repeating: 0x41, count: DyldCacheAnalysisWireCodec.maximumRequestBytes + 1))
        )

        let success = try JSONSerialization.jsonObject(
            with: codec.encodeReply(.success(DyldCacheAnalysisTestFixtures.result()))
        ) as! [String: Any]
        var conflicting = success
        conflicting["failure"] = DyldCacheAnalysisFailureCode.timeout.rawValue
        let conflictingData = try JSONSerialization.data(withJSONObject: conflicting)

        XCTAssertThrowsError(try codec.decodeReply(conflictingData)) { error in
            guard case AnalysisWorkerError.malformedReply = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testPartialSuccessAndTypedFailuresRoundTripWithoutDiagnostics() throws {
        let partial = DyldCacheAnalysisTestFixtures.result(completion: .partial)
        XCTAssertEqual(try codec.decodeReply(codec.encodeReply(.success(partial))), partial)

        for failure in [
            DyldCacheAnalysisWorkerServiceError.cancelled,
            .timeout,
            .staleGeneration,
            .subjectIdentityMismatch,
            .providerRejectedInput,
        ] {
            let reply = codec.encodeReply(.failure(failure))
            XCTAssertFalse(String(decoding: reply, as: UTF8.self).contains("/tmp/"))
            XCTAssertThrowsError(try codec.decodeReply(reply)) { error in
                if failure == .cancelled {
                    XCTAssertTrue(error is AnalysisCancelled)
                } else {
                    XCTAssertEqual(
                        error as? RemoteDyldCacheAnalysisFailure,
                        RemoteDyldCacheAnalysisFailure(code: failure.failureCode)
                    )
                }
            }
        }
    }

    func testDecodeRejectsStructurallyMalformedSuccessfulResult() throws {
        let validReply = codec.encodeReply(.success(DyldCacheAnalysisTestFixtures.result()))
        var envelope = try JSONSerialization.jsonObject(with: validReply) as! [String: Any]
        var result = envelope["result"] as! [String: Any]
        var coverage = result["coverage"] as! [[String: Any]]
        coverage.removeLast()
        result["coverage"] = coverage
        envelope["result"] = result
        let hostileReply = try JSONSerialization.data(withJSONObject: envelope)

        XCTAssertThrowsError(try codec.decodeReply(hostileReply)) { error in
            guard case AnalysisWorkerError.malformedReply = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
