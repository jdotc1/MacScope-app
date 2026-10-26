import XCTest

@testable import MacScope

final class Phase2AIWorkerModelLifecyclePrincipalTests: XCTestCase {
    func testLiveMTPLXLifecycleDeclinesLoadAndUnloadBeforeDispatchWithExactIdentity() async {
        let handler = Phase2LiveModelLifecycleHandler()
        for operation in [Phase2AIWorkerModelLifecycleOperationWire.load(
            modelKey: Phase2MTPLXQualityRuntimeExpectation.servedModelID, contextLength: 65_536),
            .unload(instanceID: "exact-loaded-instance")] {
            let request = lifecyclePrincipalRequest(effectID: UUID(), operation: operation)
            let reply = await handler.performModelLifecycle(request: request) {
                XCTFail("External MTPLX lifecycle must never reserve provider mutation dispatch")
                return true
            }
            XCTAssertEqual(reply.effectID, request.effectID)
            XCTAssertEqual(reply.profileID, request.profileID)
            XCTAssertEqual(reply.generation, request.generation)
            XCTAssertEqual(reply.operationKind, operation.kind)
            XCTAssertEqual(reply.status, .incompatibleBeforeDispatch)
            XCTAssertNil(reply.receipt)
        }
    }

    func testLifecycleConnectionPerformsExactlyOneCommandAndEchoesExactIdentity() async throws {
        let handler = LifecyclePrincipalHandler(mode: .immediateAfterDispatch(.rejected))
        let principal = Phase2AIWorkerPrincipal(modelLifecycleHandler: handler)
        let request = lifecyclePrincipalRequest()

        let firstData = await invokeLifecycle(principal: principal, request: request)
        let firstReply = try Phase2AIWorkerModelLifecycleWireCodec().decodeReply(firstData)

        XCTAssertEqual(firstReply.effectID, request.effectID)
        XCTAssertEqual(firstReply.profileID, request.profileID)
        XCTAssertEqual(firstReply.generation, request.generation)
        XCTAssertEqual(firstReply.operationKind, .load)
        XCTAssertEqual(firstReply.status, .rejected)
        XCTAssertNil(firstReply.receipt)

        let second = lifecyclePrincipalRequest(effectID: UUID())
        let secondData = await invokeLifecycle(principal: principal, request: second)

        XCTAssertTrue(secondData.isEmpty)
        let callCount = await handler.callCount
        let reservationCount = await handler.dispatchReservationCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(reservationCount, 1)
    }

    func testMalformedFirstLifecycleRequestPoisonsConnectionWithoutInvokingHandler() async throws {
        let handler = LifecyclePrincipalHandler(mode: .immediateAfterDispatch(.rejected))
        let principal = Phase2AIWorkerPrincipal(modelLifecycleHandler: handler)
        let request = lifecyclePrincipalRequest()

        let malformed = await invokeLifecycle(
            principal: principal,
            requestData: Data("not-json".utf8),
            requestID: request.effectID
        )
        XCTAssertTrue(malformed.isEmpty)

        let validAfterMalformed = await invokeLifecycle(principal: principal, request: request)
        XCTAssertTrue(validAfterMalformed.isEmpty)
        let callCount = await handler.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testLifecycleRoleRejectsInferenceConfigurationAndDiscovery() async throws {
        let lifecycleHandler = LifecyclePrincipalHandler(
            mode: .immediateAfterDispatch(.rejected)
        )
        let discoveryHandler = LifecyclePrincipalDiscoveryHandler()
        let principal = Phase2AIWorkerPrincipal(
            modelDiscoveryHandler: discoveryHandler,
            modelLifecycleHandler: lifecycleHandler
        )
        _ = await invokeLifecycle(
            principal: principal,
            request: lifecyclePrincipalRequest()
        )

        let configurationData = await invokeLifecycleConfiguration(principal: principal)
        let acknowledgement = try Phase2AIWorkerConfigurationWireCodec()
            .decodeAcknowledgement(configurationData)
        XCTAssertEqual(acknowledgement.status, .rejected)

        let discoveryData = await invokeLifecycleDiscovery(principal: principal)
        XCTAssertTrue(discoveryData.isEmpty)
        let discoveryCallCount = await discoveryHandler.callCount
        XCTAssertEqual(discoveryCallCount, 0)
    }

    func testInferenceAndDiscoveryRolesRejectLifecycleCommands() async throws {
        let inferenceLifecycleHandler = LifecyclePrincipalHandler(
            mode: .immediateAfterDispatch(.rejected)
        )
        let inferencePrincipal = Phase2AIWorkerPrincipal(
            modelLifecycleHandler: inferenceLifecycleHandler
        )
        let configurationData = await invokeLifecycleConfiguration(
            principal: inferencePrincipal
        )
        XCTAssertEqual(
            try Phase2AIWorkerConfigurationWireCodec()
                .decodeAcknowledgement(configurationData).status,
            .accepted
        )
        let inferenceLifecycleData = await invokeLifecycle(
            principal: inferencePrincipal,
            request: lifecyclePrincipalRequest()
        )
        let inferenceLifecycleCallCount = await inferenceLifecycleHandler.callCount
        XCTAssertTrue(inferenceLifecycleData.isEmpty)
        XCTAssertEqual(inferenceLifecycleCallCount, 0)

        let discoveryHandler = LifecyclePrincipalDiscoveryHandler()
        let discoveryLifecycleHandler = LifecyclePrincipalHandler(
            mode: .immediateAfterDispatch(.rejected)
        )
        let discoveryPrincipal = Phase2AIWorkerPrincipal(
            modelDiscoveryHandler: discoveryHandler,
            modelLifecycleHandler: discoveryLifecycleHandler
        )
        let discoveryData = await invokeLifecycleDiscovery(principal: discoveryPrincipal)
        XCTAssertFalse(discoveryData.isEmpty)
        let lifecycleAfterDiscovery = await invokeLifecycle(
            principal: discoveryPrincipal,
            request: lifecyclePrincipalRequest(effectID: UUID())
        )
        let discoveryLifecycleCallCount = await discoveryLifecycleHandler.callCount
        XCTAssertTrue(lifecycleAfterDiscovery.isEmpty)
        XCTAssertEqual(discoveryLifecycleCallCount, 0)
    }

    func testConcurrentDuplicateAndDistinctLifecycleCommandsDoNotStartAnotherHandler() async throws {
        let handler = LifecyclePrincipalHandler(mode: .blockBeforeDispatch)
        let principal = Phase2AIWorkerPrincipal(modelLifecycleHandler: handler)
        let request = lifecyclePrincipalRequest()
        let recorder = LifecyclePrincipalReplyRecorder()
        let requestData = try Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(request)

        principal.performModelLifecycle(
            requestData: requestData,
            requestID: request.effectID
        ) { recorder.receive($0) }
        try await waitForLifecyclePrincipalCalls(1, handler: handler)

        let duplicate = await invokeLifecycle(principal: principal, request: request)
        let distinct = await invokeLifecycle(
            principal: principal,
            request: lifecyclePrincipalRequest(effectID: UUID())
        )

        XCTAssertTrue(duplicate.isEmpty)
        XCTAssertTrue(distinct.isEmpty)
        let callCount = await handler.callCount
        XCTAssertEqual(callCount, 1)

        principal.cancelModelLifecycle(requestID: request.effectID)
        let terminal = try Phase2AIWorkerModelLifecycleWireCodec().decodeReply(
            await recorder.firstReply()
        )
        XCTAssertEqual(terminal.status, .cancelledBeforeDispatch)
        await handler.release()
    }

    func testCancellationBeforeDispatchProvesNoMutationAndSuppressesLateCompletion() async throws {
        let handler = LifecyclePrincipalHandler(mode: .blockBeforeDispatch)
        let principal = Phase2AIWorkerPrincipal(modelLifecycleHandler: handler)
        let request = lifecyclePrincipalRequest()
        let recorder = LifecyclePrincipalReplyRecorder()
        let requestData = try Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(request)

        principal.performModelLifecycle(
            requestData: requestData,
            requestID: request.effectID
        ) { recorder.receive($0) }
        try await waitForLifecyclePrincipalCalls(1, handler: handler)
        principal.cancelModelLifecycle(requestID: request.effectID)

        let terminal = try Phase2AIWorkerModelLifecycleWireCodec().decodeReply(
            await recorder.firstReply()
        )
        XCTAssertEqual(terminal.effectID, request.effectID)
        XCTAssertEqual(terminal.status, .cancelledBeforeDispatch)
        XCTAssertNil(terminal.receipt)
        let reservationCount = await handler.dispatchReservationCount
        XCTAssertEqual(reservationCount, 0)

        await handler.release()
        try await waitForLifecycleReplyQuiescence(recorder)
        XCTAssertEqual(recorder.replyCount, 1)
    }

    func testCancellationAfterDispatchRequiresReconciliationAndSuppressesLateSuccess() async throws {
        let handler = LifecyclePrincipalHandler(mode: .blockAfterDispatch)
        let principal = Phase2AIWorkerPrincipal(modelLifecycleHandler: handler)
        let request = lifecyclePrincipalRequest()
        let recorder = LifecyclePrincipalReplyRecorder()
        let requestData = try Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(request)

        principal.performModelLifecycle(
            requestData: requestData,
            requestID: request.effectID
        ) { recorder.receive($0) }
        try await waitForLifecycleDispatchReservation(handler: handler)
        principal.cancelModelLifecycle(requestID: request.effectID)

        let terminal = try Phase2AIWorkerModelLifecycleWireCodec().decodeReply(
            await recorder.firstReply()
        )
        XCTAssertEqual(terminal.effectID, request.effectID)
        XCTAssertEqual(terminal.status, .reconciliationRequired)
        XCTAssertNil(terminal.receipt)
        let reservationCount = await handler.dispatchReservationCount
        XCTAssertEqual(reservationCount, 1)

        await handler.release()
        try await waitForLifecycleReplyQuiescence(recorder)
        XCTAssertEqual(recorder.replyCount, 1)
    }

    func testInvalidationBeforeDispatchReturnsOneCancelledTerminalAndSuppressesLateReply() async throws {
        let handler = LifecyclePrincipalHandler(mode: .blockBeforeDispatch)
        let principal = Phase2AIWorkerPrincipal(modelLifecycleHandler: handler)
        let request = lifecyclePrincipalRequest()
        let recorder = LifecyclePrincipalReplyRecorder()
        let requestData = try Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(request)

        principal.performModelLifecycle(
            requestData: requestData,
            requestID: request.effectID
        ) { recorder.receive($0) }
        try await waitForLifecyclePrincipalCalls(1, handler: handler)
        principal.cancelAllForConnectionInvalidation()

        let terminal = try Phase2AIWorkerModelLifecycleWireCodec().decodeReply(
            await recorder.firstReply()
        )
        XCTAssertEqual(terminal.status, .cancelledBeforeDispatch)

        await handler.release()
        try await waitForLifecycleReplyQuiescence(recorder)
        XCTAssertEqual(recorder.replyCount, 1)
        let lifecycleAfterInvalidation = await invokeLifecycle(
            principal: principal,
            request: lifecyclePrincipalRequest(effectID: UUID())
        )
        XCTAssertTrue(lifecycleAfterInvalidation.isEmpty)
    }

    func testInvalidationAfterDispatchReturnsOneReconciliationTerminalAndSuppressesLateReply() async throws {
        let handler = LifecyclePrincipalHandler(mode: .blockAfterDispatch)
        let principal = Phase2AIWorkerPrincipal(modelLifecycleHandler: handler)
        let request = lifecyclePrincipalRequest()
        let recorder = LifecyclePrincipalReplyRecorder()
        let requestData = try Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(request)

        principal.performModelLifecycle(
            requestData: requestData,
            requestID: request.effectID
        ) { recorder.receive($0) }
        try await waitForLifecycleDispatchReservation(handler: handler)
        principal.cancelAllForConnectionInvalidation()

        let terminal = try Phase2AIWorkerModelLifecycleWireCodec().decodeReply(
            await recorder.firstReply()
        )
        XCTAssertEqual(terminal.status, .reconciliationRequired)

        await handler.release()
        try await waitForLifecycleReplyQuiescence(recorder)
        XCTAssertEqual(recorder.replyCount, 1)
    }

    func testValidatedTerminalWinsBeforeLateCancellation() async throws {
        let handler = LifecyclePrincipalHandler(mode: .immediateAfterDispatch(.rejected))
        let principal = Phase2AIWorkerPrincipal(modelLifecycleHandler: handler)
        let request = lifecyclePrincipalRequest()
        let recorder = LifecyclePrincipalReplyRecorder()
        let requestData = try Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(request)

        principal.performModelLifecycle(
            requestData: requestData,
            requestID: request.effectID
        ) { recorder.receive($0) }
        let terminal = try Phase2AIWorkerModelLifecycleWireCodec().decodeReply(
            await recorder.firstReply()
        )
        XCTAssertEqual(terminal.status, .rejected)

        principal.cancelModelLifecycle(requestID: request.effectID)
        try await waitForLifecycleReplyQuiescence(recorder)
        XCTAssertEqual(recorder.replyCount, 1)
    }
}

private actor LifecyclePrincipalHandler: Phase2AIWorkerModelLifecycleHandling {
    enum Mode: Sendable {
        case immediateAfterDispatch(Phase2AIWorkerModelLifecycleReply.Status)
        case blockBeforeDispatch
        case blockAfterDispatch
    }

    private(set) var callCount = 0
    private(set) var dispatchReservationCount = 0
    private var released = false
    private let mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func performModelLifecycle(
        request: Phase2AIWorkerModelLifecycleRequest,
        reserveDispatch: @escaping @Sendable () -> Bool
    ) async -> Phase2AIWorkerModelLifecycleReply {
        callCount += 1

        switch mode {
        case .immediateAfterDispatch(let status):
            if reserveDispatch() { dispatchReservationCount += 1 }
            return lifecyclePrincipalReply(for: request, status: status)

        case .blockBeforeDispatch:
            while !released, !Task.isCancelled { await Task.yield() }
            return lifecyclePrincipalReply(for: request, status: .unavailableBeforeDispatch)

        case .blockAfterDispatch:
            if reserveDispatch() { dispatchReservationCount += 1 }
            while !released, !Task.isCancelled { await Task.yield() }
            return lifecyclePrincipalReply(for: request, status: .reconciliationRequired)
        }
    }

    func release() {
        released = true
    }
}

private actor LifecyclePrincipalDiscoveryHandler: Phase2AIWorkerModelDiscoveryHandling {
    private(set) var callCount = 0

    func discoverModels(
        request: Phase2AIWorkerModelDiscoveryRequest
    ) async -> Phase2AIWorkerModelDiscoveryReply {
        callCount += 1
        return .init(
            schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
            requestID: request.requestID,
            profileID: request.profileID,
            generation: request.generation,
            status: .unavailable,
            inventory: nil
        )
    }
}

private final class LifecyclePrincipalReplyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Data] = []
    private var waiter: CheckedContinuation<Data, Never>?

    var replyCount: Int { lock.withLock { replies.count } }

    func receive(_ data: Data) {
        let waiter = lock.withLock { () -> CheckedContinuation<Data, Never>? in
            replies.append(data)
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: data)
    }

    func firstReply() async -> Data {
        if let existing = lock.withLock({ replies.first }) { return existing }
        return await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Data? in
                if let existing = replies.first { return existing }
                waiter = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }
}

private func invokeLifecycle(
    principal: Phase2AIWorkerPrincipal,
    request: Phase2AIWorkerModelLifecycleRequest
) async -> Data {
    let data = (try? Phase2AIWorkerModelLifecycleWireCodec().encodeRequest(request)) ?? Data()
    return await invokeLifecycle(
        principal: principal,
        requestData: data,
        requestID: request.effectID
    )
}

private func invokeLifecycle(
    principal: Phase2AIWorkerPrincipal,
    requestData: Data,
    requestID: UUID
) async -> Data {
    await withCheckedContinuation { continuation in
        principal.performModelLifecycle(
            requestData: requestData,
            requestID: requestID
        ) { data in
            continuation.resume(returning: data)
        }
    }
}

private func lifecyclePrincipalRequest(
    effectID: UUID = UUID(uuidString: "9430D56B-5804-414C-B5AD-FA5B87A03C54")!,
    operation: Phase2AIWorkerModelLifecycleOperationWire = .load(modelKey: "publisher/exact-model", contextLength: 32_768)
) -> Phase2AIWorkerModelLifecycleRequest {
    .init(
        schemaVersion: Phase2AIWorkerModelLifecycleWireCodec.schemaVersion,
        effectID: effectID,
        profileID: UUID(uuidString: "AC8800C8-374C-4E14-BC4B-8D863793A264")!,
        generation: 4,
        endpointOrigin: "http://127.0.0.1:1234",
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000,
        operation: operation
    )
}

private func lifecyclePrincipalReply(
    for request: Phase2AIWorkerModelLifecycleRequest,
    status: Phase2AIWorkerModelLifecycleReply.Status
) -> Phase2AIWorkerModelLifecycleReply {
    .init(
        schemaVersion: Phase2AIWorkerModelLifecycleWireCodec.schemaVersion,
        effectID: request.effectID,
        profileID: request.profileID,
        generation: request.generation,
        operationKind: .load,
        status: status,
        receipt: nil
    )
}

private func invokeLifecycleConfiguration(
    principal: Phase2AIWorkerPrincipal
) async -> Data {
    let configuration = Phase2AIWorkerConfigurationWire(
        schemaVersion: Phase2AIWorkerConfigurationWireCodec.schemaVersion,
        profileID: UUID(uuidString: "AC8800C8-374C-4E14-BC4B-8D863793A264")!,
        generation: 4,
        endpointOrigin: "http://127.0.0.1:1234",
        model: "publisher/exact-model",
        protocolManifestDigest: Phase2AIWorkerProductionProtocol.manifestDigest,
        maximumTokens: 1_024,
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000,
        inferencePolicy: Phase2LocalInferencePolicy()
    )
    let data = (try? Phase2AIWorkerConfigurationWireCodec()
        .encodeConfiguration(configuration)) ?? Data()
    return await withCheckedContinuation { continuation in
        principal.configure(configurationData: data) { continuation.resume(returning: $0) }
    }
}

private func invokeLifecycleDiscovery(
    principal: Phase2AIWorkerPrincipal
) async -> Data {
    let request = Phase2AIWorkerModelDiscoveryRequest(
        schemaVersion: Phase2AIWorkerModelDiscoveryWireCodec.schemaVersion,
        requestID: UUID(),
        profileID: UUID(uuidString: "AC8800C8-374C-4E14-BC4B-8D863793A264")!,
        generation: 4,
        endpointOrigin: "http://127.0.0.1:1234",
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000,
        inferencePolicy: Phase2LocalInferencePolicy()
    )
    let data = (try? Phase2AIWorkerModelDiscoveryWireCodec().encodeRequest(request)) ?? Data()
    return await withCheckedContinuation { continuation in
        principal.discoverModels(requestData: data, requestID: request.requestID) {
            continuation.resume(returning: $0)
        }
    }
}

private func waitForLifecyclePrincipalCalls(
    _ expected: Int,
    handler: LifecyclePrincipalHandler
) async throws {
    for _ in 0..<2_000 {
        if await handler.callCount >= expected { return }
        await Task.yield()
    }
    XCTFail("timed out waiting for worker lifecycle handler call")
}

private func waitForLifecycleDispatchReservation(
    handler: LifecyclePrincipalHandler
) async throws {
    for _ in 0..<2_000 {
        if await handler.dispatchReservationCount == 1 { return }
        await Task.yield()
    }
    XCTFail("timed out waiting for lifecycle dispatch reservation")
}

private func waitForLifecycleReplyQuiescence(
    _ recorder: LifecyclePrincipalReplyRecorder
) async throws {
    for _ in 0..<200 { await Task.yield() }
    XCTAssertEqual(recorder.replyCount, 1)
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
