import Foundation
import XCTest
@testable import MacScope

@MainActor
final class XPCAnalysisProviderTests: XCTestCase {
    func testHappyPathReturnsDecodedSnapshotAndReturnsToIdle() async throws {
        let transport = MockAnalysisTransport(outcomes: [.reply(Data("reply".utf8))])
        let provider = XPCAnalysisProvider(transport: transport, codec: TestWireCodec())

        let snapshot = try await provider.openBinary(
            url: Self.fixtureURL,
            requestedSliceIndex: 2,
            overrides: [:],
            cancellation: .never
        )

        XCTAssertEqual(snapshot.hexBytes, Self.fixtureSnapshot.hexBytes)
        XCTAssertEqual(provider.connectionState, .idle)
        XCTAssertEqual(transport.calls.count, 1)
    }

    func testInterruptionFailsCurrentRequestAndNextRequestReconnectsWithoutRetrying() async throws {
        let transport = MockAnalysisTransport(outcomes: [
            .interrupt,
            .reply(Data("second-reply".utf8)),
        ])
        let provider = XPCAnalysisProvider(transport: transport, codec: TestWireCodec())

        do {
            _ = try await provider.openBinary(
                url: Self.fixtureURL,
                requestedSliceIndex: nil,
                overrides: [:],
                cancellation: .never
            )
            XCTFail("an interrupted request must fail")
        } catch let error as AnalysisWorkerError {
            guard case .workerCrashed = error else {
                return XCTFail("expected workerCrashed, got \(error)")
            }
        }

        XCTAssertEqual(transport.calls.count, 1, "the crashed request is never retried")
        XCTAssertEqual(provider.connectionState, .interrupted)

        let snapshot = try await provider.openBinary(
            url: Self.fixtureURL,
            requestedSliceIndex: nil,
            overrides: [:],
            cancellation: .never
        )

        XCTAssertEqual(snapshot.hexBytes, Self.fixtureSnapshot.hexBytes)
        XCTAssertEqual(transport.calls.count, 2, "the next request reconnects exactly once")
        XCTAssertEqual(provider.connectionState, .idle)
    }

    func testInvalidationFailsCurrentAndSubsequentRequestsWithoutHanging() async {
        let transport = MockAnalysisTransport(outcomes: [.invalidate])
        let provider = XPCAnalysisProvider(transport: transport, codec: TestWireCodec())

        await assertWorkerUnavailable {
            try await provider.openBinary(
                url: Self.fixtureURL,
                requestedSliceIndex: nil,
                overrides: [:],
                cancellation: .never
            )
        }
        XCTAssertEqual(provider.connectionState, .invalidated)

        let failedWithoutTransport = expectation(description: "sticky invalidation fails without hanging")
        Task {
            await self.assertWorkerUnavailable {
                try await provider.openBinary(
                    url: Self.fixtureURL,
                    requestedSliceIndex: nil,
                    overrides: [:],
                    cancellation: .never
                )
            }
            failedWithoutTransport.fulfill()
        }
        await fulfillment(of: [failedWithoutTransport], timeout: 0.5)
        XCTAssertEqual(transport.calls.count, 1, "an invalidated provider does not contact the transport")
    }

    func testExplicitCancellationOfHungRequestThrowsAnalysisCancelledAndForwardsCancel() async {
        let transport = MockAnalysisTransport(outcomes: [.hang])
        let provider = XPCAnalysisProvider(transport: transport, codec: TestWireCodec())
        let cancellation = LockedCancellationFlag()
        let finished = expectation(description: "cancelled hang finishes without a reply")

        Task {
            do {
                _ = try await provider.openBinary(
                    url: Self.fixtureURL,
                    requestedSliceIndex: nil,
                    overrides: [:],
                    cancellation: AnalysisCancellationToken { cancellation.isSet }
                )
                XCTFail("a cancelled request must not return a snapshot")
            } catch {
                XCTAssertTrue(error is AnalysisCancelled, "expected AnalysisCancelled, got \(error)")
            }
            finished.fulfill()
        }

        await waitUntil { transport.calls.count == 1 }
        let requestID = transport.calls[0].requestID
        cancellation.set()
        await fulfillment(of: [finished], timeout: 0.5)

        XCTAssertEqual(transport.cancelledRequestIDs, [requestID])
        XCTAssertEqual(transport.resolvedHungRequestIDs, [], "the worker reply never arrived")
        XCTAssertEqual(provider.connectionState, .idle)
    }

    func testTaskCancellationOfHungRequestThrowsAnalysisCancelledAndForwardsCancel() async {
        let transport = MockAnalysisTransport(outcomes: [.hang])
        let provider = XPCAnalysisProvider(transport: transport, codec: TestWireCodec())
        let finished = expectation(description: "task-cancelled hang finishes")

        let task = Task {
            do {
                _ = try await provider.openBinary(
                    url: Self.fixtureURL,
                    requestedSliceIndex: nil,
                    overrides: [:],
                    cancellation: .never
                )
                XCTFail("a task-cancelled request must not return a snapshot")
            } catch {
                XCTAssertTrue(error is AnalysisCancelled, "expected AnalysisCancelled, got \(error)")
            }
            finished.fulfill()
        }

        await waitUntil { transport.calls.count == 1 }
        let requestID = transport.calls[0].requestID
        task.cancel()
        await fulfillment(of: [finished], timeout: 0.5)

        XCTAssertEqual(transport.cancelledRequestIDs, [requestID])
        XCTAssertEqual(provider.connectionState, .idle)
    }

    func testMalformedReplyMapsToTypedError() async {
        let transport = MockAnalysisTransport(outcomes: [.reply(Data("garbage".utf8))])
        let provider = XPCAnalysisProvider(
            transport: transport,
            codec: TestWireCodec(decodeResult: .failure(TestWireCodec.DecodeFailure()))
        )

        do {
            _ = try await provider.openBinary(
                url: Self.fixtureURL,
                requestedSliceIndex: nil,
                overrides: [:],
                cancellation: .never
            )
            XCTFail("garbage must not decode")
        } catch let error as AnalysisWorkerError {
            guard case .malformedReply = error else {
                return XCTFail("expected malformedReply, got \(error)")
            }
        } catch {
            XCTFail("expected AnalysisWorkerError, got \(error)")
        }
        XCTAssertEqual(provider.connectionState, .idle)
    }

    func testVersionMismatchIsPreservedAsTypedError() async {
        let mismatch = AnalysisWorkerError.versionMismatch(expected: 1, got: 2)
        let transport = MockAnalysisTransport(outcomes: [.reply(Data("v2".utf8))])
        let provider = XPCAnalysisProvider(
            transport: transport,
            codec: TestWireCodec(decodeResult: .failure(mismatch))
        )

        do {
            _ = try await provider.openBinary(
                url: Self.fixtureURL,
                requestedSliceIndex: nil,
                overrides: [:],
                cancellation: .never
            )
            XCTFail("a mismatched wire version must fail")
        } catch let error as AnalysisWorkerError {
            XCTAssertEqual(error, mismatch)
        } catch {
            XCTFail("expected AnalysisWorkerError, got \(error)")
        }
    }

    func testSynchronousAnalyzeUsesTheSameMalformedReplyMappingAsOpenBinary() async {
        let transport = MockAnalysisTransport(outcomes: [
            .reply(Data("async-garbage".utf8)),
            .reply(Data("sync-garbage".utf8)),
        ])
        let provider = XPCAnalysisProvider(
            transport: transport,
            codec: TestWireCodec(decodeResult: .failure(TestWireCodec.DecodeFailure()))
        )

        let asyncError: AnalysisWorkerError?
        do {
            _ = try await provider.openBinary(
                url: Self.fixtureURL,
                requestedSliceIndex: nil,
                overrides: [:],
                cancellation: .never
            )
            asyncError = nil
        } catch {
            asyncError = error as? AnalysisWorkerError
        }

        // The sync bridge runs its work off-actor internally (detached task + semaphore), so a
        // direct call is both correct and a faithful exercise of a synchronous caller.
        let syncError: AnalysisWorkerError?
        do {
            _ = try provider.analyze(
                url: Self.fixtureURL,
                requestedSliceIndex: nil,
                overrides: [:],
                cancellation: .never
            )
            syncError = nil
        } catch {
            syncError = error as? AnalysisWorkerError
        }

        guard case .malformedReply = asyncError else {
            return XCTFail("async path did not return malformedReply")
        }
        guard case .malformedReply = syncError else {
            return XCTFail("sync path did not return malformedReply")
        }
        XCTAssertEqual(transport.calls.count, 2)
        XCTAssertEqual(provider.connectionState, .idle)
    }

    // MARK: PERF-C2 pinned analyze reply

    /// A >= 1 MiB image analyzed through `analyzePinned` (real principal + worker service + codec):
    /// the reply names the image bytes as a range of the pinned source plus SHA-256 instead of
    /// carrying them, and the client reads them from its own handle byte-exact. Also records
    /// bytes-on-wire for the inline reply (wire v2 form) versus the pinned-range reply.
    func testPinnedAnalyzeReplyCarriesRangeAndClientRestoresImageBytesByteExact() async throws {
        var bytes = WorkerRehydrateTests.importPE(count: 2, name: "puts")
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        bytes.append(contentsOf: (0..<(3 << 19)).map { _ -> UInt8 in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        })
        XCTAssertGreaterThanOrEqual(bytes.count, 1 << 20)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-c2-\(UUID().uuidString).exe")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try FileHandle(forReadingFrom: url)
        defer { try? source.close() }

        let loopback = LoopbackPinnedAnalyzeTransport()
        let provider = XPCAnalysisProvider(transport: loopback, codec: PayloadWireCodec())
        let remote = try await provider.openPinnedBinary(
            url: url, source: source, selection: .machOSlice(nil), overrides: [:], cancellation: .never
        )
        let local = try AnalysisEngine().analyze(url: url, requestedSliceIndex: nil, overrides: [:], cancellation: .never)

        XCTAssertEqual(local.imageBytes, bytes)
        XCTAssertEqual(remote.imageBytes, bytes, "client restored the exact bytes from its pinned source")
        XCTAssertEqual(AnalysisPinnedImageBytes.sha256Hex(remote.imageBytes), AnalysisPinnedImageBytes.sha256Hex(bytes))
        XCTAssertEqual(remote.sections.map(\.name), local.sections.map(\.name))
        XCTAssertFalse(remote.sections.isEmpty)
        XCTAssertEqual(provider.connectionState, .idle)

        let pinnedReply = try XCTUnwrap(loopback.lastReply)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: pinnedReply) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, PayloadWireCodec.wireVersion)
        let range = try XCTUnwrap(envelope["imageBytesInPinnedSource"] as? [String: Any])
        XCTAssertEqual(range["offset"] as? Int, 0)
        XCTAssertEqual(range["byteCount"] as? Int, bytes.count)
        XCTAssertEqual(range["sha256"] as? String, AnalysisPinnedImageBytes.sha256Hex(bytes))

        // Bytes on wire: the inline reply is the wire-v2 shape (image bytes base64 in the JSON).
        let inlineReply = PayloadWireCodec().encodeReply(.success(local))
        let inlineEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with: inlineReply) as? [String: Any])
        XCTAssertNil(inlineEnvelope["imageBytesInPinnedSource"], "no pinned source: bytes stay inline")
        XCTContext.runActivity(named: "PERF-C2 wire: image=\(bytes.count) inlineReply=\(inlineReply.count) "
              + "pinnedReply=\(pinnedReply.count) request=\(loopback.lastRequestByteCount) "
              + "before=\(inlineReply.count) after=\(pinnedReply.count)") { _ in }
        XCTAssertGreaterThan(inlineReply.count, bytes.count * 4 / 3, "inline reply base64-expands the image")
        XCTAssertLessThan(pinnedReply.count, 64 << 10, "pinned reply holds no image bytes")
    }

    private func assertWorkerUnavailable(
        _ operation: () async throws -> WorkspaceSnapshot
    ) async {
        do {
            _ = try await operation()
            XCTFail("an invalidated provider must fail")
        } catch let error as AnalysisWorkerError {
            guard case .workerUnavailable = error else {
                return XCTFail("expected workerUnavailable, got \(error)")
            }
        } catch {
            XCTFail("expected AnalysisWorkerError, got \(error)")
        }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        _ predicate: @escaping @Sendable () -> Bool
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !predicate(), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(predicate(), "condition was not met before timeout")
    }

    nonisolated private static let fixtureURL = URL(fileURLWithPath: "/tmp/xpc-fixture")
    nonisolated fileprivate static let fixtureSnapshot = WorkspaceSnapshot(
        binaries: [],
        functions: [],
        instructions: [],
        xrefs: [],
        hexBytes: Data([0xca, 0xfe])
    )
}

private struct TestWireCodec: AnalysisClientWireCodec {
    struct DecodeFailure: Error {}

    let decodeResult: Result<WorkspaceSnapshot, Error>

    init(decodeResult: Result<WorkspaceSnapshot, Error> = .success(XPCAnalysisProviderTests.fixtureSnapshot)) {
        self.decodeResult = decodeResult
    }

    func encodeRequest(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        requestID: UUID
    ) -> Data {
        Data(requestID.uuidString.utf8)
    }

    func decodeReply(_ data: Data) throws -> WorkspaceSnapshot {
        try decodeResult.get()
    }
}

private final class LockedCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// Routes `sendPinned` into a real `AnalysisWorkerXPCPrincipal` (worker service + engine +
/// `PayloadWireCodec`), standing in for the NSXPC hop (NSXPC would dup the descriptor).
private final class LoopbackPinnedAnalyzeTransport: AnalysisTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let principal = AnalysisWorkerXPCPrincipal(
        service: AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec())
    )
    private var reply: Data?
    private var requestBytes = 0

    var lastReply: Data? { lock.withLock { reply } }
    var lastRequestByteCount: Int { lock.withLock { requestBytes } }

    func send(requestID: UUID, payload: Data) async throws -> Data {
        throw AnalysisTransportError.invalidated(reason: "plain analyze is not routed by this loopback")
    }

    func sendPinned(requestID: UUID, payload: Data, source: FileHandle) async throws -> Data {
        let data: Data = await withCheckedContinuation { continuation in
            principal.analyzePinned(requestData: payload, requestID: requestID, source: source) {
                continuation.resume(returning: $0)
            }
        }
        lock.withLock {
            reply = data
            requestBytes = payload.count
        }
        return data
    }

    func cancel(requestID: UUID) { principal.cancel(requestID: requestID) }
}
