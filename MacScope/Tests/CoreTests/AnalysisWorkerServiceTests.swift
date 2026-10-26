import Foundation
import XCTest
@testable import MacScope

final class AnalysisWorkerServiceTests: XCTestCase {
    func testHappyPathForwardsRequestAndEncodesSnapshot() throws {
        let snapshot = Self.snapshot(named: "happy")
        let engine = WorkerStubEngine { call in
            XCTAssertEqual(call.url.path, "/tmp/fat-binary")
            XCTAssertEqual(call.requestedSliceIndex, 2)
            XCTAssertEqual(call.overrides.keys.sorted(), [0x1000])
            XCTAssertFalse(call.cancellation.isCancelled)
            return snapshot
        }
        let codec = InMemoryAnalysisWireCodec()
        let requestID = UUID()
        let requestData = codec.addRequest(
            AnalysisRequest(
                url: URL(fileURLWithPath: "/tmp/fat-binary"),
                requestedSliceIndex: 2,
                overrides: [0x1000: Self.addressOverride(name: "entry")],
                requestID: requestID
            )
        )
        let service = AnalysisWorkerService(engine: engine, codec: codec)

        let replyData = service.handle(requestData: requestData, requestID: requestID)

        let reply = try codec.reply(for: replyData)
        XCTAssertEqual(reply.snapshot?.binaries.first?.name, "happy")
        XCTAssertNil(reply.error)
    }

    func testPinnedHandleOverridesRequestPathAtWorkerBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requestedPath = directory.appendingPathComponent("replacement")
        let pinnedURL = directory.appendingPathComponent("pinned")
        let replacement = Data([0x11, 0x22, 0x33])
        let pinned = Data([0xaa, 0xbb, 0xcc, 0xdd])
        try replacement.write(to: requestedPath)
        try pinned.write(to: pinnedURL)
        let handle = try FileHandle(forReadingFrom: pinnedURL)
        defer { try? handle.close() }

        let engine = WorkerStubEngine { call in
            XCTAssertEqual(try Data(contentsOf: call.url), pinned)
            return Self.snapshot(named: "pinned")
        }
        let codec = InMemoryAnalysisWireCodec()
        let requestID = UUID()
        let requestData = codec.addRequest(Self.request(id: requestID, path: requestedPath.path))
        let service = AnalysisWorkerService(engine: engine, codec: codec)

        let replyData = service.handle(
            requestData: requestData,
            requestID: requestID,
            pinnedURL: URL(fileURLWithPath: "/dev/fd/\(handle.fileDescriptor)")
        )

        XCTAssertEqual(try codec.reply(for: replyData).snapshot?.binaries.first?.name, "pinned")
    }

    func testCancelDuringGatedAnalysisTripsTokenAndEncodesCancelled() throws {
        let engine = GatedWorkerStubEngine()
        let codec = InMemoryAnalysisWireCodec()
        let requestID = UUID()
        let requestData = codec.addRequest(Self.request(id: requestID, path: "/tmp/hung"))
        let service = AnalysisWorkerService(engine: engine, codec: codec)
        let finished = expectation(description: "cancelled handle returned")
        let replyBox = LockedBox<Data?>(nil)

        DispatchQueue.global().async {
            replyBox.set(service.handle(requestData: requestData, requestID: requestID))
            finished.fulfill()
        }
        XCTAssertTrue(engine.waitUntilStarted(count: 1, timeout: 1))

        service.cancel(requestID: requestID)

        wait(for: [finished], timeout: 2)
        let replyData = try XCTUnwrap(replyBox.value)
        XCTAssertEqual(try codec.reply(for: replyData).error, .cancelled)
    }

    func testCancelBeforeRegisterCancelsSubsequentAnalysis() throws {
        let engine = WorkerStubEngine { call in
            try call.cancellation.check()
            return Self.snapshot(named: "unexpected")
        }
        let codec = InMemoryAnalysisWireCodec()
        let requestID = UUID()
        let service = AnalysisWorkerService(engine: engine, codec: codec)
        service.cancel(requestID: requestID)

        let replyData = service.handle(
            requestData: codec.addRequest(Self.request(id: requestID, path: "/tmp/pre-cancelled")),
            requestID: requestID
        )

        XCTAssertEqual(try codec.reply(for: replyData).error, .cancelled)
        XCTAssertEqual(engine.callCount, 1, "the engine receives an already-cancelled token")
    }

    func testGarbageRequestEncodesMalformedRequestWithoutThrowing() throws {
        let engine = WorkerStubEngine { _ in Self.snapshot(named: "unexpected") }
        let codec = InMemoryAnalysisWireCodec()
        let service = AnalysisWorkerService(engine: engine, codec: codec)

        let replyData = service.handle(requestData: Data([0xde, 0xad, 0xbe, 0xef]), requestID: UUID())

        XCTAssertEqual(try codec.reply(for: replyData).error, .malformedRequest)
        XCTAssertEqual(engine.callCount, 0)
    }

    func testEngineErrorEncodesItsDescriptionWithoutThrowing() throws {
        let engine = WorkerStubEngine { _ in throw AnalysisEngineError.unreadableInput }
        let codec = InMemoryAnalysisWireCodec()
        let requestID = UUID()
        let service = AnalysisWorkerService(engine: engine, codec: codec)

        let replyData = service.handle(
            requestData: codec.addRequest(Self.request(id: requestID, path: "/missing")),
            requestID: requestID
        )

        XCTAssertEqual(
            try codec.reply(for: replyData).error,
            .analysisFailed(AnalysisEngineError.unreadableInput.localizedDescription)
        )
    }

    func testUnexpectedEngineErrorEncodesGenericReplyWithoutThrowing() throws {
        struct UnexpectedFailure: LocalizedError {
            var errorDescription: String? { "stub exploded" }
        }
        let engine = WorkerStubEngine { _ in throw UnexpectedFailure() }
        let codec = InMemoryAnalysisWireCodec()
        let requestID = UUID()
        let service = AnalysisWorkerService(engine: engine, codec: codec)

        let replyData = service.handle(
            requestData: codec.addRequest(Self.request(id: requestID, path: "/tmp/explode")),
            requestID: requestID
        )

        XCTAssertEqual(try codec.reply(for: replyData).error, .unexpectedFailure("stub exploded"))
    }

    func testCancellingOneOfTwoConcurrentRequestsLeavesTheOtherRunning() throws {
        let engine = GatedWorkerStubEngine()
        let codec = InMemoryAnalysisWireCodec()
        let cancelledID = UUID()
        let survivingID = UUID()
        let service = AnalysisWorkerService(engine: engine, codec: codec)
        let cancelledData = codec.addRequest(Self.request(id: cancelledID, path: "/tmp/cancel-me"))
        let survivingData = codec.addRequest(Self.request(id: survivingID, path: "/tmp/keep-running"))
        let cancelledFinished = expectation(description: "cancelled request returned")
        let survivingFinished = expectation(description: "surviving request returned")
        let cancelledReply = LockedBox<Data?>(nil)
        let survivingReply = LockedBox<Data?>(nil)

        DispatchQueue.global().async {
            cancelledReply.set(service.handle(requestData: cancelledData, requestID: cancelledID))
            cancelledFinished.fulfill()
        }
        DispatchQueue.global().async {
            survivingReply.set(service.handle(requestData: survivingData, requestID: survivingID))
            survivingFinished.fulfill()
        }
        XCTAssertTrue(engine.waitUntilStarted(count: 2, timeout: 1))

        service.cancel(requestID: cancelledID)

        wait(for: [cancelledFinished], timeout: 2)
        XCTAssertEqual(try codec.reply(for: XCTUnwrap(cancelledReply.value)).error, .cancelled)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertNil(survivingReply.value, "the uncancelled request must remain gated")

        engine.release(path: "/tmp/keep-running")
        wait(for: [survivingFinished], timeout: 2)
        let survivor = try codec.reply(for: XCTUnwrap(survivingReply.value))
        XCTAssertEqual(survivor.snapshot?.binaries.first?.name, "keep-running")
        XCTAssertNil(survivor.error)
    }

    /// PERF-C2: the worker names the image bytes as a verified range of the pinned source. In a fat
    /// file with two equal-size slices, only the slice whose bytes match is named; bytes found
    /// nowhere in the source stay inline.
    func testPinnedReplyNamesTheVerifiedFatSliceRangeOrFallsBackInline() throws {
        let sliceSize = 0x1000
        var file = Data(count: 0x3000)
        for index in file.indices { file[index] = UInt8(truncatingIfNeeded: index &* 13 &+ (index >> 8)) }
        let header: [UInt32] = [0xCAFE_BABE, 2,
                                0x0100_000C, 0, 0x1000, UInt32(sliceSize), 12,
                                0x0100_000C, 2, 0x2000, UInt32(sliceSize), 12]
        file.replaceSubrange(0..<(header.count * 4), with: header.flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) }
        })
        let slice = file.subdata(in: 0x2000..<0x3000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-c2-fat-\(UUID().uuidString)")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }

        let reported = LockedBox(slice)
        let engine = WorkerStubEngine { _ in
            var snapshot = Self.snapshot(named: "fat")
            snapshot.imageBytes = reported.value
            return snapshot
        }
        let codec = PayloadWireCodec()
        let service = AnalysisWorkerService(engine: engine, codec: codec)
        let requestID = UUID()
        let request = codec.encodeRequest(url: url, requestedSliceIndex: nil, overrides: [:], requestID: requestID)

        let pinned = service.handle(requestData: request, requestID: requestID, pinnedSource: source)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: pinned) as? [String: Any])
        let range = try XCTUnwrap(envelope["imageBytesInPinnedSource"] as? [String: Any])
        XCTAssertEqual(range["offset"] as? Int, 0x2000)
        XCTAssertEqual(range["byteCount"] as? Int, sliceSize)
        XCTAssertEqual(try codec.decodeReply(pinned, pinnedSource: source).imageBytes, slice)

        reported.set(Data(repeating: 0x5A, count: sliceSize))
        let inline = service.handle(requestData: request, requestID: requestID, pinnedSource: source)
        let inlineEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: inline) as? [String: Any])
        XCTAssertNil(inlineEnvelope["imageBytesInPinnedSource"])
        XCTAssertEqual(try codec.decodeReply(inline).imageBytes, Data(repeating: 0x5A, count: sliceSize))
    }

    private static func request(id: UUID, path: String) -> AnalysisRequest {
        AnalysisRequest(
            url: URL(fileURLWithPath: path), requestedSliceIndex: nil, overrides: [:], requestID: id
        )
    }

    fileprivate static func snapshot(named name: String) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: name, path: "/tmp/\(name)", kind: "test", architecture: "arm64")],
            functions: [], instructions: [], xrefs: [], hexBytes: Data()
        )
    }

    private static func addressOverride(name: String) -> AddressOverride {
        var value = AddressOverride()
        value.customName = name
        return value
    }
}

private struct WorkerEngineCall {
    let url: URL
    let requestedSliceIndex: Int?
    let overrides: [UInt64: AddressOverride]
    let cancellation: AnalysisCancellationToken
}

private final class WorkerStubEngine: AnalysisProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let script: @Sendable (WorkerEngineCall) throws -> WorkspaceSnapshot
    private var _callCount = 0

    init(script: @escaping @Sendable (WorkerEngineCall) throws -> WorkspaceSnapshot) {
        self.script = script
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return try script(
            WorkerEngineCall(
                url: url,
                requestedSliceIndex: requestedSliceIndex,
                overrides: overrides,
                cancellation: cancellation
            )
        )
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

private final class GatedWorkerStubEngine: AnalysisProviding, @unchecked Sendable {
    private let condition = NSCondition()
    private var startedPaths: Set<String> = []
    private var releasedPaths: Set<String> = []

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        let path = url.path
        condition.lock()
        startedPaths.insert(path)
        condition.broadcast()
        while !releasedPaths.contains(path) && !cancellation.isCancelled {
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
        }
        condition.unlock()
        try cancellation.check()
        return AnalysisWorkerServiceTests.snapshot(named: url.lastPathComponent)
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

    func waitUntilStarted(count: Int, timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while startedPaths.count < count {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release(path: String) {
        condition.lock()
        releasedPaths.insert(path)
        condition.broadcast()
        condition.unlock()
    }
}

private enum InMemoryReplyError: Equatable {
    case malformedRequest
    case cancelled
    case analysisFailed(String)
    case unexpectedFailure(String)
}

private struct InMemoryReply {
    let snapshot: WorkspaceSnapshot?
    let error: InMemoryReplyError?
}

private enum InMemoryCodecError: Error {
    case unknownRequest
    case unknownReply
}

private final class InMemoryAnalysisWireCodec: AnalysisWorkerWireCodec, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Data: AnalysisRequest] = [:]
    private var replies: [Data: InMemoryReply] = [:]

    func addRequest(_ request: AnalysisRequest) -> Data {
        let data = withUnsafeBytes(of: request.requestID.uuid) { Data($0) }
        lock.lock()
        requests[data] = request
        lock.unlock()
        return data
    }

    func decodeRequest(_ data: Data) throws -> AnalysisRequest {
        lock.lock()
        defer { lock.unlock() }
        guard let request = requests[data] else { throw InMemoryCodecError.unknownRequest }
        return request
    }

    func encodeReply(_ result: Result<WorkspaceSnapshot, Error>) -> Data {
        let reply: InMemoryReply
        switch result {
        case let .success(snapshot):
            reply = InMemoryReply(snapshot: snapshot, error: nil)
        case let .failure(error as AnalysisWorkerServiceError):
            let mapped: InMemoryReplyError
            switch error {
            case .malformedRequest: mapped = .malformedRequest
            case .cancelled: mapped = .cancelled
            case let .analysisFailed(description): mapped = .analysisFailed(description)
            case let .unexpectedFailure(description): mapped = .unexpectedFailure(description)
            }
            reply = InMemoryReply(snapshot: nil, error: mapped)
        case let .failure(error):
            reply = InMemoryReply(snapshot: nil, error: .unexpectedFailure(error.localizedDescription))
        }

        let data = withUnsafeBytes(of: UUID().uuid) { Data($0) }
        lock.lock()
        replies[data] = reply
        lock.unlock()
        return data
    }

    func reply(for data: Data) throws -> InMemoryReply {
        lock.lock()
        defer { lock.unlock() }
        guard let reply = replies[data] else { throw InMemoryCodecError.unknownReply }
        return reply
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
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
