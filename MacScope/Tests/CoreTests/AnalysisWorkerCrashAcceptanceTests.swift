import Foundation
import XCTest
@testable import MacScope

/// In-XCTest approximation of terminating a live analysis-worker process.
///
/// `TerminableAnalysisTransport` holds the first request exactly as a live worker would while
/// analyzing, then `terminateWorker()` ends that pending request with the event a real
/// `NSXPCConnection.interruptionHandler` reports. This exercises the production provider's
/// crash mapping and reconnect-on-next-request state machine. It deliberately does not claim to
/// launch, discover, signal, sign, or embed an `.xpc`; the driver owns that manual acceptance.
@MainActor
final class AnalysisWorkerCrashAcceptanceTests: XCTestCase {
    func testTerminatedWorkerFailsCurrentRequestAndNextRequestReconnects() async throws {
        let transport = TerminableAnalysisTransport(reconnectedReply: Data("reconnected".utf8))
        let codec = CrashAcceptanceWireCodec()
        let provider = XPCAnalysisProvider(transport: transport, codec: codec)
        let firstRequest = Task {
            try await provider.openBinary(
                url: URL(fileURLWithPath: "/tmp/crash-acceptance"),
                requestedSliceIndex: nil,
                overrides: [:],
                cancellation: .never
            )
        }

        await waitUntil { transport.pendingRequestCount == 1 }
        transport.terminateWorker(reason: "test worker terminated")

        do {
            _ = try await firstRequest.value
            XCTFail("the request owned by the terminated worker must fail")
        } catch let error as AnalysisWorkerError {
            XCTAssertEqual(error, .workerCrashed(reason: "test worker terminated"))
        } catch {
            XCTFail("expected AnalysisWorkerError.workerCrashed, got \(error)")
        }
        XCTAssertEqual(provider.connectionState, .interrupted)
        XCTAssertEqual(transport.requestCount, 1, "the crashed request is never retried")

        let snapshot = try await provider.openBinary(
            url: URL(fileURLWithPath: "/tmp/crash-acceptance"),
            requestedSliceIndex: nil,
            overrides: [:],
            cancellation: .never
        )

        XCTAssertEqual(snapshot.hexBytes, CrashAcceptanceWireCodec.fixtureSnapshot.hexBytes)
        XCTAssertEqual(provider.connectionState, .idle)
        XCTAssertEqual(transport.requestCount, 2, "the next request reconnects exactly once")
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
}

private final class TerminableAnalysisTransport: AnalysisTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let reconnectedReply: Data
    private var pending: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var shouldServeReconnectedRequests = false
    private var recordedRequestCount = 0

    init(reconnectedReply: Data) {
        self.reconnectedReply = reconnectedReply
    }

    var pendingRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequestCount
    }

    func send(requestID: UUID, payload: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            recordedRequestCount += 1
            if shouldServeReconnectedRequests {
                lock.unlock()
                continuation.resume(returning: reconnectedReply)
            } else {
                pending[requestID] = continuation
                lock.unlock()
            }
        }
    }

    func cancel(requestID: UUID) {
        lock.lock()
        let continuation = pending.removeValue(forKey: requestID)
        lock.unlock()
        continuation?.resume(throwing: AnalysisCancelled())
    }

    func terminateWorker(reason: String) {
        lock.lock()
        shouldServeReconnectedRequests = true
        let continuations = Array(pending.values)
        pending.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(throwing: AnalysisTransportError.interrupted(reason: reason))
        }
    }
}

private struct CrashAcceptanceWireCodec: AnalysisClientWireCodec {
    static let fixtureSnapshot = WorkspaceSnapshot(
        binaries: [],
        functions: [],
        instructions: [],
        xrefs: [],
        hexBytes: Data([0xde, 0xad])
    )

    func encodeRequest(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        requestID: UUID
    ) -> Data {
        Data(requestID.uuidString.utf8)
    }

    func decodeReply(_ data: Data) throws -> WorkspaceSnapshot {
        Self.fixtureSnapshot
    }
}
