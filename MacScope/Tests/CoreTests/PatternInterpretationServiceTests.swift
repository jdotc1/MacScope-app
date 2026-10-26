import Foundation
import XCTest
@testable import MacScope

final class PatternInterpretationServiceTests: XCTestCase {
    func testUnavailableServiceNeverPublishesNativeDocument() throws {
        let request = makeRequest()
        let done = expectation(description: "unavailable reply")
        PatternInterpretationService.unavailable().handle(
            requestData: try JSONEncoder().encode(request), requestID: request.requestID
        ) { data in
            assertPatternFailure(data, requestID: request.requestID, expected: .unavailable)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testEarlyCancelPositive() throws {
        try assertCancellation(cancelBeforeAcquire: false)
    }

    func testEarlyCancelNegative() throws {
        try assertCancellation(cancelBeforeAcquire: true)
    }

    private func assertCancellation(cancelBeforeAcquire: Bool) throws {
        let request = makeRequest()
        let admission = PatternWorkerAdmission()
        let queue = DispatchQueue(label: "pattern-test-early-cancel")
        let job = PatternTestJob(document: try document(for: request))
        let service = PatternInterpretationService(makeJob: { _ in job }, admission: admission, queue: queue)
        let done = expectation(description: "cancelled reply")
        if cancelBeforeAcquire { service.cancel(requestID: request.requestID) }
        // Hold dispatch until cancellation after acquisition has been recorded.
        queue.suspend()
        service.handle(requestData: try JSONEncoder().encode(request), requestID: request.requestID) { data in
            assertPatternFailure(data, requestID: request.requestID, expected: .cancelled)
            done.fulfill()
        }
        if !cancelBeforeAcquire { service.cancel(requestID: request.requestID) }
        queue.resume()
        wait(for: [done], timeout: 2)
        queue.sync {}
        XCTAssertTrue(job.isCancelled)
        XCTAssertTrue(admission.tryAcquire(requestID: UUID()))
    }

    func testHeldNativeCallRemainsBusyAfterCancellationUntilReturn() throws {
        let request = makeRequest()
        let admission = PatternWorkerAdmission()
        let queue = DispatchQueue(label: "pattern-test-held")
        let started = expectation(description: "job entered")
        let returned = expectation(description: "cancelled return")
        let gate = DispatchSemaphore(value: 0)
        let job = PatternTestJob(document: try document(for: request), gate: gate) { started.fulfill() }
        let service = PatternInterpretationService(makeJob: { _ in job }, admission: admission, queue: queue)
        service.handle(requestData: try JSONEncoder().encode(request), requestID: request.requestID) { data in
            assertPatternFailure(data, requestID: request.requestID, expected: .cancelled)
            returned.fulfill()
        }
        wait(for: [started], timeout: 2)
        service.cancel(requestID: request.requestID)
        let busy = expectation(description: "second request refused")
        let second = makeRequest()
        service.handle(requestData: try JSONEncoder().encode(second), requestID: second.requestID) { data in
            assertPatternFailure(data, requestID: second.requestID, expected: .busy)
            busy.fulfill()
        }
        wait(for: [busy], timeout: 2)
        XCTAssertTrue(job.isCancelled)
        gate.signal()
        wait(for: [returned], timeout: 2)
        queue.sync {}
        XCTAssertTrue(admission.tryAcquire(requestID: UUID()))
    }

    func testSuccessfulNativeReturnPublishesOnceAndReleasesAdmission() throws {
        let request = makeRequest()
        let expected = try document(for: request)
        let admission = PatternWorkerAdmission()
        let queue = DispatchQueue(label: "pattern-test-success")
        let job = PatternTestJob(document: expected)
        let done = expectation(description: "success")
        done.assertForOverFulfill = true
        let service = PatternInterpretationService(makeJob: { _ in job }, admission: admission, queue: queue)
        service.handle(requestData: try JSONEncoder().encode(request), requestID: request.requestID) { data in
            XCTAssertEqual(try? PatternWorkerEnvelope.unwrap(data, requestID: request.requestID), expected)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        queue.sync {}
        XCTAssertTrue(admission.tryAcquire(requestID: UUID()))
    }

    func testMalformedNativeReplyIsRejected() throws {
        let request = makeRequest()
        let job = PatternTestJob(document: Data("{}".utf8))
        let done = expectation(description: "invalid native reply")
        let service = PatternInterpretationService(makeJob: { _ in job }, admission: PatternWorkerAdmission())
        service.handle(requestData: try JSONEncoder().encode(request), requestID: request.requestID) { data in
            assertPatternFailure(data, requestID: request.requestID, expected: .invalidNativeReply)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testRequestIDMismatchDoesNotConstructJob() throws {
        let request = makeRequest()
        let wrongID = UUID()
        let done = expectation(description: "invalid request")
        let service = PatternInterpretationService(makeJob: { _ in
            XCTFail("mismatched request must not construct a native job")
            throw PatternServiceFailure.unavailable
        }, admission: PatternWorkerAdmission())
        service.handle(requestData: try JSONEncoder().encode(request), requestID: wrongID) { data in
            assertPatternFailure(data, requestID: wrongID, expected: .invalidRequest)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testPrincipalPatternSelectorUsesUnavailableDefault() throws {
        let requestID = UUID()
        let done = expectation(description: "principal unavailable")
        let principal = AnalysisWorkerXPCPrincipal()
        principal.interpretPattern(requestData: try JSONEncoder().encode(makeRequest(id: requestID)),
                                   requestID: requestID) { data in
            assertPatternFailure(data, requestID: requestID, expected: .unavailable)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    private func makeRequest(id: UUID = UUID()) -> PatternInterpretationRequest {
        .init(requestID: id, key: .init(imageIdentity: "image", byteSnapshotID: UUID(),
              patternIdentity: "pattern", selectionImageOffset: 0, selectionByteCount: 2),
              bytes: Data([0, 0]), source: "u8 x @ 0;")
    }

    private func document(for request: PatternInterpretationRequest) throws -> Data {
        try JSONEncoder().encode(PatternInterpretationReply(
            schemaVersion: 1, engineCommit: "300d7388475dd7ffd04239dfc889b72fe08bae18",
            requestID: request.requestID.uuidString, imageIdentity: request.key.imageIdentity,
            patternIdentity: request.key.patternIdentity, byteSnapshotID: request.key.byteSnapshotID,
            selectionImageOffset: request.key.selectionImageOffset,
            selectionByteCount: request.key.selectionByteCount, status: .completed,
            nodes: [], diagnostics: []))
    }
}

private func assertPatternFailure(_ data: Data, requestID: UUID, expected: PatternServiceFailure,
                                  file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try PatternWorkerEnvelope.unwrap(data, requestID: requestID)
        XCTFail("Expected pattern service failure \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? PatternServiceFailure, expected, file: file, line: line)
    }
}

private final class PatternTestJob: PatternEvaluationJob, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let document: Data
    private let gate: DispatchSemaphore?
    private let started: @Sendable () -> Void

    init(document: Data, gate: DispatchSemaphore? = nil, started: @escaping @Sendable () -> Void = {}) {
        self.document = document
        self.gate = gate
        self.started = started
    }

    func run() throws -> Data {
        started()
        if let gate, gate.wait(timeout: .now() + 5) != .success {
            throw PatternServiceFailure.unavailable
        }
        return document
    }

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

final class PatternInterpretationAdmissionTests: XCTestCase {
    func testCancellationDoesNotReleaseLease() {
        let admission = PatternWorkerAdmission()
        let requestID = UUID()
        XCTAssertTrue(admission.tryAcquire(requestID: requestID))
        admission.cancel(requestID: requestID)
        XCTAssertFalse(admission.tryAcquire(requestID: UUID()))
        admission.releaseAfterNativeReturn(requestID: requestID)
        XCTAssertTrue(admission.tryAcquire(requestID: UUID()))
    }

    func testDifferentRequestCannotReleaseActiveLease() {
        let admission = PatternWorkerAdmission()
        let requestID = UUID()
        XCTAssertTrue(admission.tryAcquire(requestID: requestID))
        admission.releaseAfterNativeReturn(requestID: UUID())
        XCTAssertFalse(admission.tryAcquire(requestID: UUID()))
        admission.releaseAfterNativeReturn(requestID: requestID)
        XCTAssertTrue(admission.tryAcquire(requestID: UUID()))
    }

    func testCompletedRequestCannotReplay() {
        let admission = PatternWorkerAdmission()
        let requestID = UUID()
        XCTAssertTrue(admission.tryAcquire(requestID: requestID))
        admission.releaseAfterNativeReturn(requestID: requestID)
        XCTAssertFalse(admission.tryAcquire(requestID: requestID))
        XCTAssertTrue(admission.tryAcquire(requestID: UUID()))
    }

    func testCancellationTombstoneExhaustionFailsClosed() {
        let admission = PatternWorkerAdmission()
        for _ in 0..<65 { admission.cancel(requestID: UUID()) }
        XCTAssertFalse(admission.tryAcquire(requestID: UUID()))
    }
}
