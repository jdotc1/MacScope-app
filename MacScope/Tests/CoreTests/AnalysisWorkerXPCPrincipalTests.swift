import Foundation
import XCTest
@testable import MacScope

final class AnalysisWorkerXPCPrincipalTests: XCTestCase {
    func testAnalyzeRunsServiceOnWorkerQueueAndRepliesWithEncodedData() throws {
        let requestID = UUID()
        let request = AnalysisRequest(
            url: URL(fileURLWithPath: "/tmp/principal-fixture"),
            requestedSliceIndex: 3,
            overrides: [:],
            requestID: requestID
        )
        let requestData = Data("principal-request".utf8)
        let expectedReply = Data("principal-reply".utf8)
        let queueKey = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "org.macscope.app.tests.analysis-worker-principal")
        queue.setSpecific(key: queueKey, value: "worker")

        let engine = PrincipalStubAnalysisEngine { call in
            XCTAssertEqual(call.url, request.url)
            XCTAssertEqual(call.requestedSliceIndex, 3)
            XCTAssertEqual(call.overrides, [:])
            XCTAssertEqual(DispatchQueue.getSpecific(key: queueKey), "worker")
            return Self.fixtureSnapshot
        }
        let codec = PrincipalStubWireCodec(
            requestData: requestData,
            request: request,
            successReply: expectedReply,
            cancelledReply: Data("cancelled".utf8)
        )
        let service = AnalysisWorkerService(engine: engine, codec: codec)
        let principal = AnalysisWorkerXPCPrincipal(service: service, workerQueue: queue)
        let replied = expectation(description: "principal returned encoded worker reply")
        let observedReply = PrincipalLockedBox<Data?>(nil)

        principal.analyze(requestData: requestData, requestID: requestID) { data in
            observedReply.set(data)
            replied.fulfill()
        }

        wait(for: [replied], timeout: 1)
        XCTAssertEqual(observedReply.value, expectedReply)
        XCTAssertEqual(engine.callCount, 1)
    }

    func testCancelForwardsToWorkerServiceBeforeAnalyzeStarts() throws {
        let requestID = UUID()
        let requestData = Data("pre-cancelled-request".utf8)
        let cancelledReply = Data("cancelled-reply".utf8)
        let request = AnalysisRequest(
            url: URL(fileURLWithPath: "/tmp/pre-cancelled"),
            requestedSliceIndex: nil,
            overrides: [:],
            requestID: requestID
        )
        let engine = PrincipalStubAnalysisEngine { call in
            try call.cancellation.check()
            return Self.fixtureSnapshot
        }
        let codec = PrincipalStubWireCodec(
            requestData: requestData,
            request: request,
            successReply: Data("unexpected-success".utf8),
            cancelledReply: cancelledReply
        )
        let principal = AnalysisWorkerXPCPrincipal(
            service: AnalysisWorkerService(engine: engine, codec: codec),
            workerQueue: DispatchQueue(label: "org.macscope.app.tests.analysis-worker-cancel")
        )
        let replied = expectation(description: "pre-cancelled request returned")
        let observedReply = PrincipalLockedBox<Data?>(nil)

        principal.cancel(requestID: requestID)
        principal.analyze(requestData: requestData, requestID: requestID) { data in
            observedReply.set(data)
            replied.fulfill()
        }

        wait(for: [replied], timeout: 1)
        XCTAssertEqual(observedReply.value, cancelledReply)
        XCTAssertEqual(engine.callCount, 1, "the engine receives the service's already-cancelled token")
    }

    func testDyldCacheAdmissionIsProcessWideNonQueuingAndReleasesAfterCompletion() throws {
        XCTAssertEqual(
            DyldCacheInspectionAdmission.maximumCooperativeDurationMilliseconds,
            120_000
        )
        let request = DyldCacheAnalysisTestFixtures.request()
        let codec = DyldCacheAnalysisWireCodec()
        let requestData = try codec.encodeRequest(request)
        let firstStarted = expectation(description: "first synchronous provider call started")
        let provider = PrincipalBlockingDyldCacheProvider { firstStarted.fulfill() }
        defer { provider.releaseFirstCall() }
        let admission = DyldCacheInspectionAdmission()
        let firstPrincipal = makeDyldPrincipal(
            provider: provider,
            admission: admission,
            queueLabel: "org.macscope.app.tests.dyld-admission-first"
        )
        let secondPrincipal = makeDyldPrincipal(
            provider: provider,
            admission: admission,
            queueLabel: "org.macscope.app.tests.dyld-admission-second"
        )

        let firstReply = expectation(description: "first provider call completed")
        let firstData = PrincipalLockedBox<Data?>(nil)
        firstPrincipal.inspectDyldCache(
            requestData: requestData,
            requestID: request.requestID
        ) { data in
            firstData.set(data)
            firstReply.fulfill()
        }
        wait(for: [firstStarted], timeout: 1)

        let rejectedReply = expectation(description: "second connection rejected without queueing")
        let rejectedData = PrincipalLockedBox<Data?>(nil)
        secondPrincipal.inspectDyldCache(
            requestData: requestData,
            requestID: request.requestID
        ) { data in
            rejectedData.set(data)
            rejectedReply.fulfill()
        }
        wait(for: [rejectedReply], timeout: 1)
        XCTAssertThrowsError(try codec.decodeReply(try XCTUnwrap(rejectedData.value))) { error in
            XCTAssertEqual(
                error as? RemoteDyldCacheAnalysisFailure,
                RemoteDyldCacheAnalysisFailure(code: .providerUnavailable)
            )
        }
        XCTAssertEqual(provider.callCount, 1, "a rejected connection must not start or queue work")

        provider.releaseFirstCall()
        wait(for: [firstReply], timeout: 1)
        XCTAssertNoThrow(try codec.decodeReply(try XCTUnwrap(firstData.value)))

        let subsequentReply = expectation(description: "lease released after bounded completion")
        let subsequentData = PrincipalLockedBox<Data?>(nil)
        secondPrincipal.inspectDyldCache(
            requestData: requestData,
            requestID: request.requestID
        ) { data in
            subsequentData.set(data)
            subsequentReply.fulfill()
        }
        wait(for: [subsequentReply], timeout: 1)
        XCTAssertNoThrow(try codec.decodeReply(try XCTUnwrap(subsequentData.value)))
        XCTAssertEqual(provider.callCount, 2)
    }

    private func makeDyldPrincipal(
        provider: PrincipalBlockingDyldCacheProvider,
        admission: DyldCacheInspectionAdmission,
        queueLabel: String
    ) -> AnalysisWorkerXPCPrincipal {
        AnalysisWorkerXPCPrincipal(
            service: AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec()),
            dyldCacheService: DyldCacheAnalysisWorkerService(
                provider: provider,
                codec: DyldCacheAnalysisWireCodec()
            ),
            dyldCacheQueue: DispatchQueue(label: queueLabel),
            dyldCacheAdmission: admission
        )
    }

    private static let fixtureSnapshot = WorkspaceSnapshot(
        binaries: [],
        functions: [],
        instructions: [],
        xrefs: [],
        hexBytes: Data([0xca, 0xfe])
    )
}

private final class PrincipalBlockingDyldCacheProvider:
    DyldCacheAnalysisWorkerProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let firstCallStarted: () -> Void
    private let firstCallGate = DispatchSemaphore(value: 0)
    private var recordedCallCount = 0

    init(firstCallStarted: @escaping () -> Void) {
        self.firstCallStarted = firstCallStarted
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallCount
    }

    func releaseFirstCall() {
        firstCallGate.signal()
    }

    func inspectCache(
        request: DyldCacheAnalysisRequest,
        cancellation: AnalysisCancellationToken
    ) throws -> DyldCacheAnalysisResult {
        lock.lock()
        recordedCallCount += 1
        let ordinal = recordedCallCount
        lock.unlock()
        if ordinal == 1 {
            firstCallStarted()
            firstCallGate.wait()
        }
        try cancellation.check()
        return DyldCacheAnalysisTestFixtures.result(
            requestID: request.requestID,
            sourceIdentity: request.expectedSourceIdentity,
            subject: request.subject,
            requestedCategories: request.categories
        )
    }
}

private struct PrincipalEngineCall {
    let url: URL
    let requestedSliceIndex: Int?
    let overrides: [UInt64: AddressOverride]
    let cancellation: AnalysisCancellationToken
}

private final class PrincipalStubAnalysisEngine: AnalysisProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: (PrincipalEngineCall) throws -> WorkspaceSnapshot
    private var recordedCallCount = 0

    init(handler: @escaping (PrincipalEngineCall) throws -> WorkspaceSnapshot) {
        self.handler = handler
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCallCount
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        lock.lock()
        recordedCallCount += 1
        lock.unlock()
        return try handler(PrincipalEngineCall(
            url: url,
            requestedSliceIndex: requestedSliceIndex,
            overrides: overrides,
            cancellation: cancellation
        ))
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        try analyze(
            url: url,
            requestedSliceIndex: requestedSliceIndex,
            overrides: overrides,
            cancellation: cancellation
        )
    }
}

private struct PrincipalStubWireCodec: AnalysisWorkerWireCodec {
    let requestData: Data
    let request: AnalysisRequest
    let successReply: Data
    let cancelledReply: Data

    func decodeRequest(_ data: Data) throws -> AnalysisRequest {
        guard data == requestData else { throw PrincipalStubCodecError.unexpectedRequest }
        return request
    }

    func encodeReply(_ result: Result<WorkspaceSnapshot, Error>) -> Data {
        switch result {
        case .success:
            successReply
        case .failure(let error as AnalysisWorkerServiceError):
            error == .cancelled ? cancelledReply : Data("unexpected-worker-error".utf8)
        case .failure:
            Data("unexpected-error".utf8)
        }
    }
}

private enum PrincipalStubCodecError: Error {
    case unexpectedRequest
}

private final class PrincipalLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}
