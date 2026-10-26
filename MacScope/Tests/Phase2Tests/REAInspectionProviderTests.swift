import Foundation
import XCTest
@testable import MacScope

private final class REAProviderTransportFixture: REAInspectionTransport, @unchecked Sendable {
    enum Mode: Sendable { case response(Data), interrupted, held }
    private let lock = NSLock()
    let mode: Mode
    private var continuation: CheckedContinuation<Data, Error>?
    private var retired = false
    private var cancellations = 0
    private var retirements = 0
    init(_ mode: Mode) { self.mode = mode }
    var counts: (Int, Int) { lock.withLock { (cancellations, retirements) } }
    func sendREAInspection(requestID: UUID, payload: Data) async throws -> Data {
        switch mode {
        case .response(let data): return data
        case .interrupted: throw AnalysisTransportError.interrupted(reason: "fixture")
        case .held:
            return try await withCheckedThrowingContinuation { continuation in
                let stopped = lock.withLock {
                    if retired { return true }
                    self.continuation = continuation; return false
                }
                if stopped { continuation.resume(throwing: CancellationError()) }
            }
        }
    }
    func cancelREAInspection(requestID: UUID) { lock.withLock { cancellations += 1 } }
    func retireREAConnection(requestID: UUID) {
        let saved = lock.withLock {
            retirements += 1; retired = true
            let current = continuation; continuation = nil; return current
        }
        saved?.resume(throwing: CancellationError())
    }
    func lateReply(_ data: Data) {
        let saved = lock.withLock { let current = continuation; continuation = nil; return current }
        saved?.resume(returning: data)
    }
}
final class REAInspectionProviderTests: XCTestCase {
    private func request(_ id: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
            "operation": "nativeApplication", "input": [:]], options: [.sortedKeys])
    }
    private func response(_ id: UUID, identity: String = "test") -> Data {
        REAInspectionWireCodec.failure(requestID: id, operation: .nativeApplication,
            implementationIdentity: identity, code: "fixture", message: "fixture")
    }
    func testActualPayloadIdentityAndOperationAreValidated() async throws {
        let id = UUID(), data = response(id)
        let provider = XPCREAInspectionProvider(transport: REAProviderTransportFixture(.response(data)))
        let accepted = try await provider.inspect(requestData: request(id), requestID: id,
            operation: .nativeApplication, implementationIdentity: "test")
        XCTAssertEqual(accepted, data)
        let wrong = XPCREAInspectionProvider(transport: REAProviderTransportFixture(.response(response(UUID()))))
        do {
            _ = try await wrong.inspect(requestData: request(id), requestID: id,
                operation: .nativeApplication, implementationIdentity: "test")
            XCTFail("Wrong response identity must reject")
        } catch { }
        do {
            _ = try await provider.inspect(requestData: request(id), requestID: id,
                operation: .uiResources, implementationIdentity: "test")
            XCTFail("Wrong operation must reject before transport")
        } catch { XCTAssertEqual(error as? XPCREAInspectionProvider.Failure, .operationMismatch) }
    }
    func testInterruptionIsPreserved() async throws {
        let id = UUID(), provider = XPCREAInspectionProvider(transport: REAProviderTransportFixture(.interrupted))
        do {
            _ = try await provider.inspect(requestData: request(id), requestID: id,
                operation: .nativeApplication, implementationIdentity: "test")
            XCTFail("Expected interruption")
        } catch { XCTAssertNotNil(error as? AnalysisTransportError) }
    }
    func testTimeoutRetiresClientAndLateReplyCannotChangeResult() async throws {
        let id = UUID(), transport = REAProviderTransportFixture(.held)
        let provider = XPCREAInspectionProvider(transport: transport, timeout: 0.02)
        do {
            _ = try await provider.inspect(requestData: request(id), requestID: id,
                operation: .nativeApplication, implementationIdentity: "test")
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? XPCREAInspectionProvider.Failure, .timeout) }
        transport.lateReply(response(id))
        XCTAssertEqual(transport.counts.0, 1); XCTAssertEqual(transport.counts.1, 1)
    }
    func testCancellationBeforeOrDuringRegistrationDoesNotHang() async throws {
        let id = UUID(), data = try request(id), transport = REAProviderTransportFixture(.held)
        let provider = XPCREAInspectionProvider(transport: transport)
        let task = Task {
            try await provider.inspect(requestData: data, requestID: id,
                operation: .nativeApplication, implementationIdentity: "test")
        }
        await Task.yield(); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        transport.lateReply(response(id))
    }
}
