import Foundation
#if TESTING_NATIVE_DECOMPILER_SERVICE_COMPOSITION
@testable import MacScope
#endif

/// One synchronous request-scoped native invocation.
///
/// Production instances own exactly one Objective-C cancellation handle. Test instances exercise
/// the same scheduler/composition boundary without loading the governed native package.
protocol NativeDecompilerServiceNativeRequest: Sendable {
    func cancel()
    func execute(requestID: UUID, payload: Data) -> Data
}

/// Owns the process-wide service graph and is created before the service listener starts.
final class NativeDecompilerServiceComposition: @unchecked Sendable {
    typealias NativeRequestFactory = @Sendable (
        _ requestID: UUID
    ) -> any NativeDecompilerServiceNativeRequest

    private static let maximumNativeWallTimeMilliseconds: UInt64 = 15_000
    private static let nativeTerminationGraceMilliseconds: UInt64 = 500

    let host: NativeDecompilerServiceHost
    private let listenerDelegate: NativeDecompilerServiceListenerDelegate

    init(
        scheduler: NativeDecompilerRequestScheduler,
        nativeRequestFactory: @escaping NativeRequestFactory
    ) {
        let codec = NativeDecompilerWireCodec()
        let dependencies = NativeDecompilerServiceDependencies(
            submit: { requestID, payload, completion in
                let disposition = scheduler.submit(
                    requestID: requestID,
                    payload: payload,
                    hardDeadlineMilliseconds: Self.hardDeadlineMilliseconds(
                        requestID: requestID,
                        payload: payload,
                        codec: codec
                    ),
                    operation: { requestID, payload, cancellationState, finish in
                        let request = nativeRequestFactory(requestID)
                        let cancellationRegistration = cancellationState.observeCancellation {
                            request.cancel()
                            #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
                            NativeDecompilerLiveXPCTestControl.shared.observeCancellation(
                                requestID: requestID
                            )
                            #endif
                        }
                        #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
                        guard NativeDecompilerLiveXPCTestControl.shared.enterNativeExecution(
                            requestID: requestID
                        ) else {
                            cancellationRegistration.invalidate()
                            finish(.failure(.internalFailure))
                            return
                        }
                        #endif
                        let reply = request.execute(requestID: requestID, payload: payload)
                        cancellationRegistration.invalidate()
                        finish(.success(reply))
                    },
                    completion: { result in
                        switch result {
                        case let .success(reply):
                            completion(reply)
                        case let .failure(failure):
                            completion(
                                Self.encodeFailure(
                                    requestID: requestID,
                                    failure: Self.serviceFailure(for: failure),
                                    codec: codec
                                )
                            )
                        }
                    }
                )
                #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
                NativeDecompilerLiveXPCTestControl.shared.observeSubmission(
                    requestID: requestID,
                    isQueued: disposition == .queued
                )
                #endif
                return Self.serviceDisposition(for: disposition)
            },
            cancel: { requestID in
                _ = scheduler.cancel(requestID: requestID)
            },
            validateReply: { requestID, requestPayload, reply in
                Self.validateReply(
                    reply,
                    requestID: requestID,
                    requestPayload: requestPayload,
                    codec: codec
                )
            },
            encodeFailure: { requestID, failure in
                Self.encodeFailure(requestID: requestID, failure: failure, codec: codec)
            }
        )
        let host = NativeDecompilerServiceHost(dependencies: dependencies)
        self.host = host
        listenerDelegate = NativeDecompilerServiceListenerDelegate(host: host)
    }

    /// Constructs the complete service graph only after the native backend readiness gate passes.
    /// The caller may make the listener reachable only from the returned composition.
    static func prepared(
        scheduler: NativeDecompilerRequestScheduler,
        prepare: () -> Bool,
        nativeRequestFactory: @escaping NativeRequestFactory
    ) -> NativeDecompilerServiceComposition? {
        guard prepare() else { return nil }
        return NativeDecompilerServiceComposition(
            scheduler: scheduler,
            nativeRequestFactory: nativeRequestFactory
        )
    }

    #if !TESTING_NATIVE_DECOMPILER_SERVICE_COMPOSITION
    /// Eagerly verifies and constructs exactly one shared native backend before listener startup.
    static func production() -> NativeDecompilerServiceComposition? {
        let bridge = NativeDecompilerObjCBridgeBox(bridge: MSNativeDecompilerObjCBridge())
        return prepared(
            scheduler: NativeDecompilerRequestScheduler(),
            prepare: bridge.bridge.prepare,
            nativeRequestFactory: { _ in
                NativeDecompilerObjCRequest(bridge: bridge)
            }
        )
    }
    #endif

    /// Enters the Foundation-managed XPC service loop only after the complete graph exists.
    func runService() {
        let listener = NSXPCListener.service()
        listener.delegate = listenerDelegate
        listener.resume()
    }

    private static func serviceDisposition(
        for disposition: NativeDecompilerSchedulingDisposition
    ) -> NativeDecompilerServiceSubmissionDisposition {
        switch disposition {
        case .started:
            return .started
        case .queued:
            return .queued
        case let .rejected(failure):
            return .rejected(serviceFailure(for: failure))
        }
    }

    private static func serviceFailure(
        for failure: NativeDecompilerSchedulingFailure
    ) -> NativeDecompilerServiceFailure {
        switch failure {
        case .busy:
            return .busy
        case .duplicateRequestID:
            return .invalidRequest
        case .cancelled:
            return .cancelled
        case .internalFailure:
            return .nativeFailure
        }
    }

    private static func validateReply(
        _ reply: Data,
        requestID: UUID,
        requestPayload: Data,
        codec: NativeDecompilerWireCodec
    ) -> Bool {
        do {
            let request = try codec.decodeRequest(requestPayload, matching: requestID)
            _ = try codec.decodeReply(
                reply,
                matching: NativeDecompilerWireExpectedRequestBinding(request: request)
            )
            return true
        } catch {
            // A malformed request can still produce a valid, correlated closed failure union.
            // Success can never pass this fallback because UUID-only success validation is
            // intentionally prohibited by the wire codec.
            guard let decoded = try? codec.decodeReply(reply, matching: requestID) else {
                return false
            }
            return decoded.outcome == .failure
        }
    }

    private static func hardDeadlineMilliseconds(
        requestID: UUID,
        payload: Data,
        codec: NativeDecompilerWireCodec
    ) -> UInt64 {
        let requestedMilliseconds = (
            try? codec.decodeRequest(payload, matching: requestID)
        )?.body.budgets.maxWallTimeMilliseconds.value
        let boundedRequestBudget = min(
            requestedMilliseconds ?? maximumNativeWallTimeMilliseconds,
            maximumNativeWallTimeMilliseconds
        )
        return boundedRequestBudget + nativeTerminationGraceMilliseconds
    }

    private static func encodeFailure(
        requestID: UUID,
        failure: NativeDecompilerServiceFailure,
        codec: NativeDecompilerWireCodec
    ) -> Data {
        guard let wireCode = NativeDecompilerWireFailureCode(rawValue: failure.rawValue) else {
            preconditionFailure("service failure is not represented by the current wire registry")
        }
        do {
            return try codec.encodeReply(
                NativeDecompilerWireReplyEnvelope(
                    requestID: requestID,
                    failure: NativeDecompilerWireFailure(code: wireCode, detail: nil)
                ),
                matching: requestID
            )
        } catch {
            preconditionFailure("closed native-decompiler failure envelope could not encode")
        }
    }
}

#if !TESTING_NATIVE_DECOMPILER_SERVICE_COMPOSITION
/// Swift concurrency wrapper for the Objective-C bridge's process-wide mutable state.
private final class NativeDecompilerObjCBridgeBox: @unchecked Sendable {
    let bridge: MSNativeDecompilerObjCBridge

    init(bridge: MSNativeDecompilerObjCBridge) {
        self.bridge = bridge
    }
}

/// Request-scoped owner of the native cancellation handle.
private final class NativeDecompilerObjCRequest: NativeDecompilerServiceNativeRequest,
    @unchecked Sendable
{
    private let bridge: NativeDecompilerObjCBridgeBox
    private let cancellation = MSNativeDecompilerCancellationHandle()

    init(bridge: NativeDecompilerObjCBridgeBox) {
        self.bridge = bridge
    }

    func cancel() {
        cancellation.cancel()
    }

    func execute(requestID: UUID, payload: Data) -> Data {
        bridge.bridge.decompileRequest(
            requestID,
            payload: payload,
            cancellation: cancellation
        )
    }
}
#endif
