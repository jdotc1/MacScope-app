import Darwin
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class NSXPCConnectionTransportTests: XCTestCase {
    func testPatternProtocolDoubleReturnsUnavailableEnvelope() throws {
        let requestID = UUID()
        let worker: any AnalysisWorkerXPCProtocol = TransportStubWorker(mode: .hold)
        var response: Data?
        worker.interpretPattern(requestData: Data(), requestID: requestID) { response = $0 }
        let data = try XCTUnwrap(response)
        XCTAssertThrowsError(try PatternWorkerEnvelope.unwrap(data, requestID: requestID)) {
            XCTAssertEqual($0 as? PatternServiceFailure, .unavailable)
        }
        worker.cancelPatternInterpretation(requestID: requestID)
    }

    func testSendInvokesRemoteAnalyzeAndReturnsItsReply() async throws {
        let expectedReply = Data("remote-reply".utf8)
        let worker = TransportStubWorker(mode: .reply(expectedReply))
        let connection = TransportStubConnection(remoteObject: worker)
        let transport = NSXPCConnectionTransport(connectionFactory: { serviceName in
            XCTAssertEqual(serviceName, NSXPCConnectionTransport.serviceName)
            return connection
        })
        let requestID = UUID()
        let payload = Data("request".utf8)

        let reply = try await transport.send(requestID: requestID, payload: payload)

        XCTAssertEqual(reply, expectedReply)
        XCTAssertEqual(worker.analyzeCalls, [.init(requestID: requestID, requestData: payload)])
        XCTAssertEqual(connection.resumeCount, 1)
        XCTAssertNotNil(connection.configuredInterface)
        XCTAssertEqual(
            connection.codeSigningRequirement,
            AnalysisWorkerXPCPeerRequirement.worker,
            "the transport must gate its connection on the signed analysis worker"
        )
    }

    func testSendPinnedInvokesPinnedSelectorWithTheOpenHandle() async throws {
        let expectedBytes = Data([0xfa, 0xce, 0xb0, 0x0c])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try expectedBytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let worker = TransportStubWorker(mode: .reply(Data("pinned-reply".utf8)))
        let transport = NSXPCConnectionTransport(connectionFactory: { _ in
            TransportStubConnection(remoteObject: worker)
        })

        let reply = try await transport.sendPinned(
            requestID: UUID(), payload: Data("request".utf8), source: handle
        )

        XCTAssertEqual(reply, Data("pinned-reply".utf8))
        XCTAssertEqual(worker.receivedPinnedBytes, expectedBytes)
    }

    func testSendRehydratePinnedInvokesPinnedRehydrateSelectorWithTheSealedHandle() async throws {
        let expectedBytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let handle = try AnalysisSealedByteDescriptor.make(expectedBytes)
        let worker = TransportStubWorker(mode: .reply(Data("rehydrate-reply".utf8)))
        let transport = NSXPCConnectionTransport(connectionFactory: { _ in
            TransportStubConnection(remoteObject: worker)
        })

        let reply = try await transport.sendRehydratePinned(
            requestID: UUID(), payload: Data("request".utf8), imageSource: handle
        )

        XCTAssertEqual(reply, Data("rehydrate-reply".utf8))
        XCTAssertEqual(worker.receivedPinnedBytes, expectedBytes)
        XCTAssertEqual(worker.receivedPinnedRehydrate, true)
    }

    func testInterruptionResumesPendingSendWithInterruptedError() async {
        let worker = TransportStubWorker(mode: .hold)
        let connection = TransportStubConnection(remoteObject: worker)
        let transport = NSXPCConnectionTransport(connectionFactory: { _ in connection })
        let requestID = UUID()
        let send = Task {
            try await transport.send(requestID: requestID, payload: Data("pending".utf8))
        }

        await waitUntil { worker.analyzeCalls.count == 1 }
        connection.interrupt()

        do {
            _ = try await send.value
            XCTFail("an interrupted connection must fail its pending request")
        } catch let error as AnalysisTransportError {
            XCTAssertEqual(error, .interrupted(reason: "connection interrupted"))
        } catch {
            XCTFail("expected AnalysisTransportError.interrupted, got \(error)")
        }
    }

    func testInvalidationResumesPendingSendWithInvalidatedError() async {
        let worker = TransportStubWorker(mode: .hold)
        let connection = TransportStubConnection(remoteObject: worker)
        let transport = NSXPCConnectionTransport(connectionFactory: { _ in connection })
        let requestID = UUID()
        let send = Task {
            try await transport.send(requestID: requestID, payload: Data("pending".utf8))
        }

        await waitUntil { worker.analyzeCalls.count == 1 }
        connection.invalidateFromService()

        do {
            _ = try await send.value
            XCTFail("an invalidated connection must fail its pending request")
        } catch let error as AnalysisTransportError {
            XCTAssertEqual(error, .invalidated(reason: "connection invalidated"))
        } catch {
            XCTFail("expected AnalysisTransportError.invalidated, got \(error)")
        }
    }

    func testCancelForwardsRequestIdentifierToRemoteWorker() {
        let worker = TransportStubWorker(mode: .hold)
        let connection = TransportStubConnection(remoteObject: worker)
        let transport = NSXPCConnectionTransport(connectionFactory: { _ in connection })
        let requestID = UUID()

        transport.cancel(requestID: requestID)

        XCTAssertEqual(worker.cancelledRequestIDs, [requestID])
    }

    func testDeliveryFailureCompletesEveryRequestOnRetiredConnectionGeneration() async {
        let worker = TransportStubWorker(mode: .hold)
        let connection = TransportStubConnection(remoteObject: worker)
        let transport = NSXPCConnectionTransport(connectionFactory: { _ in connection })
        let firstSend = Task {
            try await transport.send(requestID: UUID(), payload: Data("first".utf8))
        }
        let secondSend = Task {
            try await transport.send(requestID: UUID(), payload: Data("second".utf8))
        }

        await waitUntil { worker.analyzeCalls.count == 2 }
        connection.failFirstDelivery(with: TransportStubError.syntheticDeliveryFailure)

        for send in [firstSend, secondSend] {
            do {
                _ = try await send.value
                XCTFail("every request on a retired connection must fail")
            } catch let error as AnalysisTransportError {
                XCTAssertEqual(error, .invalidated(reason: "synthetic delivery failure"))
            } catch {
                XCTFail("expected AnalysisTransportError.invalidated, got \(error)")
            }
        }
    }

    func testDyldDeadlineRetiresConnectionAndCompletesEveryPendingContinuation() async {
        let worker = TransportStubWorker(mode: .hold)
        let connection = TransportStubConnection(remoteObject: worker)
        let transport = NSXPCConnectionTransport(connectionFactory: { _ in connection })
        let dyldID = UUID()
        let analysisID = UUID()
        let dyldSend = Task {
            try await transport.sendDyldCacheInspection(
                requestID: dyldID,
                payload: Data("dyld".utf8)
            )
        }
        let analysisSend = Task {
            try await transport.send(requestID: analysisID, payload: Data("analysis".utf8))
        }

        await waitUntil { worker.dyldCalls.count == 1 && worker.analyzeCalls.count == 1 }
        transport.retireDyldCacheConnection(requestID: dyldID)

        for send in [dyldSend, analysisSend] {
            do {
                _ = try await send.value
                XCTFail("retirement must clear every continuation on the poisoned connection")
            } catch let error as AnalysisTransportError {
                XCTAssertEqual(
                    error,
                    .invalidated(reason: "dyld-cache deadline retired the worker connection")
                )
            } catch {
                XCTFail("expected invalidated transport error, got \(error)")
            }
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
}

private final class TransportStubConnection: AnalysisXPCConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private let remoteObject: Any
    private var interruption: (() -> Void)?
    private var invalidation: (() -> Void)?
    private var deliveryErrorHandlers: [(Error) -> Void] = []
    private var interface: NSXPCInterface?
    private var resumes = 0

    init(remoteObject: Any) {
        self.remoteObject = remoteObject
    }

    var remoteProcessIdentifier: pid_t? { nil }

    var configuredInterface: NSXPCInterface? {
        lock.lock()
        defer { lock.unlock() }
        return interface
    }

    var resumeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resumes
    }

    func setRemoteObjectInterface(_ interface: NSXPCInterface) {
        lock.lock()
        self.interface = interface
        lock.unlock()
    }

    func setCodeSigningRequirement(_ requirement: String) {
        lock.lock()
        installedRequirement = requirement
        lock.unlock()
    }

    var codeSigningRequirement: String? {
        lock.lock()
        defer { lock.unlock() }
        return installedRequirement
    }

    private var installedRequirement: String?

    func setInterruptionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        interruption = handler
        lock.unlock()
    }

    func setInvalidationHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        invalidation = handler
        lock.unlock()
    }

    func resume() {
        lock.lock()
        resumes += 1
        lock.unlock()
    }

    func invalidate() {
        invalidateFromService()
    }

    func remoteObjectProxy(withErrorHandler handler: @escaping (Error) -> Void) -> Any? {
        lock.lock()
        deliveryErrorHandlers.append(handler)
        lock.unlock()
        return remoteObject
    }

    func interrupt() {
        lock.lock()
        let handler = interruption
        lock.unlock()
        handler?()
    }

    func invalidateFromService() {
        lock.lock()
        let handler = invalidation
        lock.unlock()
        handler?()
    }

    func failFirstDelivery(with error: Error) {
        lock.lock()
        let handler = deliveryErrorHandlers.isEmpty ? nil : deliveryErrorHandlers.removeFirst()
        lock.unlock()
        handler?(error)
    }
}

private enum TransportStubError: LocalizedError {
    case syntheticDeliveryFailure

    var errorDescription: String? { "synthetic delivery failure" }
}

private final class TransportStubWorker: NSObject, AnalysisWorkerXPCProtocol, @unchecked Sendable {
    func interpretPattern(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) {
        reply(PatternWorkerEnvelope(requestID: requestID, failure: .unavailable).encode())
    }
    func cancelPatternInterpretation(requestID: UUID) {}
    func inspectREA(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) { reply(Data()) }
    func cancelREAInspection(requestID: UUID) {}
    enum Mode {
        case reply(Data)
        case hold
    }

    struct AnalyzeCall: Equatable {
        let requestID: UUID
        let requestData: Data
    }

    private let lock = NSLock()
    private let mode: Mode
    private var calls: [AnalyzeCall] = []
    private var pinnedBytes: Data?
    private var pinnedRehydrate = false
    private var cancellations: [UUID] = []
    private var dyldInspectionCalls: [AnalyzeCall] = []
    private var dyldCancellations: [UUID] = []

    init(mode: Mode) {
        self.mode = mode
    }

    var analyzeCalls: [AnalyzeCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var receivedPinnedBytes: Data? {
        lock.lock()
        defer { lock.unlock() }
        return pinnedBytes
    }

    var receivedPinnedRehydrate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pinnedRehydrate
    }

    var cancelledRequestIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    var dyldCalls: [AnalyzeCall] {
        lock.lock()
        defer { lock.unlock() }
        return dyldInspectionCalls
    }

    func analyze(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) {
        lock.lock()
        calls.append(AnalyzeCall(requestID: requestID, requestData: requestData))
        let mode = self.mode
        lock.unlock()

        if case .reply(let data) = mode {
            reply(data)
        }
    }

    func rehydrate(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) {
        analyze(requestData: requestData, requestID: requestID, with: reply)
    }

    func rehydratePinned(requestData: Data, requestID: UUID, imageSource: FileHandle,
                         with reply: @escaping (Data) -> Void) {
        let bytes = try? AnalysisSealedByteDescriptor.read(
            imageSource, expectedCount: Int((try? imageSource.seekToEnd()) ?? 0)
        )
        lock.lock()
        pinnedBytes = bytes
        pinnedRehydrate = true
        lock.unlock()
        analyze(requestData: requestData, requestID: requestID, with: reply)
    }

    func analyzePinned(requestData: Data, requestID: UUID, source: FileHandle,
                       with reply: @escaping (Data) -> Void) {
        let bytes = try? source.readToEnd()
        lock.lock()
        pinnedBytes = bytes
        lock.unlock()
        analyze(requestData: requestData, requestID: requestID, with: reply)
    }

    func cancel(requestID: UUID) {
        lock.lock()
        cancellations.append(requestID)
        lock.unlock()
    }

    func inspectDyldCache(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    ) {
        lock.lock()
        dyldInspectionCalls.append(AnalyzeCall(requestID: requestID, requestData: requestData))
        let mode = self.mode
        lock.unlock()
        if case .reply(let data) = mode { reply(data) }
    }

    func cancelDyldCacheInspection(requestID: UUID) {
        lock.lock()
        dyldCancellations.append(requestID)
        lock.unlock()
    }
}
