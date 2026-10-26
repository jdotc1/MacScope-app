import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerServiceCompositionTests: XCTestCase {
    private let requestID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    func testPreparedCompositionFailsClosedBeforeConstructingRequests() {
        let native = NativeRequestFactoryProbe(response: Data())
        let preparations = NativeCompositionPreparationProbe(result: false)

        let composition = NativeDecompilerServiceComposition.prepared(
            scheduler: NativeDecompilerRequestScheduler(label: #function),
            prepare: preparations.prepare,
            nativeRequestFactory: native.makeRequest
        )

        XCTAssertNil(composition)
        XCTAssertEqual(preparations.callCount, 1)
        XCTAssertEqual(native.createdRequestCount, 0)
    }

    func testCompositionPublishesValidSuccessThroughFullRequestBinding() throws {
        let successfulCase = try makeSuccessfulCase()
        let native = NativeRequestFactoryProbe(response: successfulCase.reply)
        let composition = NativeDecompilerServiceComposition(
            scheduler: NativeDecompilerRequestScheduler(label: #function),
            nativeRequestFactory: native.makeRequest
        )
        let replies = NativeCompositionReplyProbe()

        composition.host.decompile(
            requestID: successfulCase.binding.requestID,
            payload: successfulCase.payload,
            reply: replies.record
        )

        XCTAssertTrue(replies.waitForCount(1))
        let decoded = try NativeDecompilerWireCodec().decodeReply(
            replies.values[0],
            matching: successfulCase.binding
        )
        XCTAssertEqual(decoded.outcome, .success)
        XCTAssertEqual(decoded.success?.result, successfulCase.envelope.success?.result)
    }

    func testCompositionRejectsSuccessWithMatchingUUIDButForgedRequestBinding() throws {
        let successfulCase = try makeSuccessfulCase()
        let mutations: [(String, [String], Any)] = [
            (
                "SHA",
                ["success", "result", "requestSHA256"],
                String(repeating: "f", count: 64)
            ),
            ("image", ["success", "result", "image", "imageID"], "image.forged"),
            ("function", ["success", "result", "function", "functionID"], "function.forged"),
        ]

        for (label, path, value) in mutations {
            let forgedReply = try mutatingPropertyList(
                successfulCase.reply,
                path: path,
                value: value
            )
            let native = NativeRequestFactoryProbe(response: forgedReply)
            let composition = NativeDecompilerServiceComposition(
                scheduler: NativeDecompilerRequestScheduler(label: "\(#function).\(label)"),
                nativeRequestFactory: native.makeRequest
            )
            let replies = NativeCompositionReplyProbe()

            composition.host.decompile(
                requestID: successfulCase.binding.requestID,
                payload: successfulCase.payload,
                reply: replies.record
            )

            XCTAssertTrue(replies.waitForCount(1), label)
            XCTAssertEqual(try replyFailureCode(replies.values[0]), "malformed-reply", label)
        }
    }

    func testCompositionExecutesAcceptedRequestThroughSingleNativeFactory() throws {
        let payload = try makeRequestPayload(requestID: requestID)
        let native = NativeRequestFactoryProbe(
            response: try failureReply(requestID: requestID, code: .nativeFailure)
        )
        let composition = NativeDecompilerServiceComposition(
            scheduler: NativeDecompilerRequestScheduler(label: #function),
            nativeRequestFactory: native.makeRequest
        )
        let replies = NativeCompositionReplyProbe()

        composition.host.decompile(requestID: requestID, payload: payload, reply: replies.record)

        XCTAssertTrue(native.waitUntilStarted(requestID))
        XCTAssertTrue(replies.waitForCount(1))
        XCTAssertEqual(native.createdRequestCount, 1)
        XCTAssertEqual(native.executedPayloads[requestID], payload)
        XCTAssertEqual(try replyFailureCode(replies.values[0]), "native-failure")
    }

    func testCompositionRelaysActiveCancellationPromptlyAndPublishesCancelled() throws {
        let payload = try makeRequestPayload(requestID: requestID)
        let native = NativeRequestFactoryProbe(
            response: try failureReply(requestID: requestID, code: .cancelled),
            waitsForCancellation: true
        )
        let composition = NativeDecompilerServiceComposition(
            scheduler: NativeDecompilerRequestScheduler(label: #function),
            nativeRequestFactory: native.makeRequest
        )
        let replies = NativeCompositionReplyProbe()

        composition.host.decompile(requestID: requestID, payload: payload, reply: replies.record)
        XCTAssertTrue(native.waitUntilStarted(requestID))

        composition.host.cancel(requestID: requestID)

        XCTAssertTrue(native.waitUntilCancelled(requestID))
        XCTAssertTrue(replies.waitForCount(1))
        XCTAssertEqual(native.cancellationCounts[requestID], 1)
        XCTAssertEqual(try replyFailureCode(replies.values[0]), "cancelled")
    }

    func testDuplicateRequestIdentifierMapsToInvalidRequestWithoutSecondExecution() throws {
        let payload = try makeRequestPayload(requestID: requestID)
        let native = NativeRequestFactoryProbe(
            response: try failureReply(requestID: requestID, code: .cancelled),
            waitsForRelease: true
        )
        let composition = NativeDecompilerServiceComposition(
            scheduler: NativeDecompilerRequestScheduler(label: #function),
            nativeRequestFactory: native.makeRequest
        )
        let firstReplies = NativeCompositionReplyProbe()
        let duplicateReplies = NativeCompositionReplyProbe()

        composition.host.decompile(requestID: requestID, payload: payload, reply: firstReplies.record)
        XCTAssertTrue(native.waitUntilStarted(requestID))
        composition.host.decompile(
            requestID: requestID,
            payload: payload,
            reply: duplicateReplies.record
        )

        XCTAssertTrue(duplicateReplies.waitForCount(1))
        XCTAssertEqual(try replyFailureCode(duplicateReplies.values[0]), "invalid-request")
        XCTAssertEqual(native.createdRequestCount, 1)
        native.release(requestID)
        XCTAssertTrue(firstReplies.waitForCount(1))
    }

    func testThirdConcurrentRequestMapsToBusyWithoutNativeExecution() throws {
        let firstID = requestID
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
        let native = NativeRequestFactoryProbe(
            responseByRequestID: [
                firstID: try failureReply(requestID: firstID, code: .cancelled),
                secondID: try failureReply(requestID: secondID, code: .cancelled),
            ],
            waitsForRelease: true
        )
        let composition = NativeDecompilerServiceComposition(
            scheduler: NativeDecompilerRequestScheduler(label: #function),
            nativeRequestFactory: native.makeRequest
        )
        let firstReplies = NativeCompositionReplyProbe()
        let secondReplies = NativeCompositionReplyProbe()
        let thirdReplies = NativeCompositionReplyProbe()

        composition.host.decompile(
            requestID: firstID,
            payload: try makeRequestPayload(requestID: firstID),
            reply: firstReplies.record
        )
        XCTAssertTrue(native.waitUntilStarted(firstID))
        composition.host.decompile(
            requestID: secondID,
            payload: try makeRequestPayload(requestID: secondID),
            reply: secondReplies.record
        )
        composition.host.decompile(
            requestID: thirdID,
            payload: try makeRequestPayload(requestID: thirdID),
            reply: thirdReplies.record
        )

        XCTAssertTrue(thirdReplies.waitForCount(1))
        XCTAssertEqual(try replyFailureCode(thirdReplies.values[0]), "busy")
        XCTAssertEqual(native.createdRequestCount, 1)

        native.release(firstID)
        XCTAssertTrue(native.waitUntilStarted(secondID))
        native.release(secondID)
        XCTAssertTrue(firstReplies.waitForCount(1))
        XCTAssertTrue(secondReplies.waitForCount(1))
        XCTAssertEqual(native.createdRequestCount, 2)
    }

    func testMalformedNativeReplyMapsToCorrelatedMalformedReply() throws {
        let payload = try makeRequestPayload(requestID: requestID)
        let native = NativeRequestFactoryProbe(response: Data([0x00, 0x01]))
        let composition = NativeDecompilerServiceComposition(
            scheduler: NativeDecompilerRequestScheduler(label: #function),
            nativeRequestFactory: native.makeRequest
        )
        let replies = NativeCompositionReplyProbe()

        composition.host.decompile(requestID: requestID, payload: payload, reply: replies.record)

        XCTAssertTrue(replies.waitForCount(1))
        XCTAssertEqual(try replyFailureCode(replies.values[0]), "malformed-reply")
    }

    func testMalformedRequestCanPublishOnlyCorrelatedClosedFailure() throws {
        let native = NativeRequestFactoryProbe(
            response: try failureReply(requestID: requestID, code: .malformedRequest)
        )
        let composition = NativeDecompilerServiceComposition(
            scheduler: NativeDecompilerRequestScheduler(label: #function),
            nativeRequestFactory: native.makeRequest
        )
        let replies = NativeCompositionReplyProbe()

        composition.host.decompile(
            requestID: requestID,
            payload: Data([0x00, 0x01]),
            reply: replies.record
        )

        XCTAssertTrue(replies.waitForCount(1))
        XCTAssertEqual(try replyFailureCode(replies.values[0]), "malformed-request")
    }

    func testCompositionArmsHardDeadlineFromBoundedWireBudget() throws {
        let deadlines = NativeCompositionHardDeadlineProbe()
        let scheduler = NativeDecompilerRequestScheduler(
            label: #function,
            serviceProcessID: 42_426,
            scheduleHardDeadline: deadlines.schedule,
            terminateServiceProcess: { _ in XCTFail("deadline must not fire in this test") }
        )
        let native = NativeRequestFactoryProbe(
            response: try failureReply(requestID: requestID, code: .cancelled),
            waitsForRelease: true
        )
        let composition = NativeDecompilerServiceComposition(
            scheduler: scheduler,
            nativeRequestFactory: native.makeRequest
        )
        let replies = NativeCompositionReplyProbe()

        composition.host.decompile(
            requestID: requestID,
            payload: try makeRequestPayload(requestID: requestID),
            reply: replies.record
        )

        XCTAssertTrue(native.waitUntilStarted(requestID))
        XCTAssertEqual(deadlines.delays, [5_500])
        native.release(requestID)
        XCTAssertTrue(replies.waitForCount(1))
    }

    private func makeRequestPayload(
        requestID: UUID
    ) throws -> Data {
        let image = NativeDecompilerWireImageIdentity(
            imageID: "image-main",
            uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            preferredLoadAddress: NativeDecompilerWireUInt64(0x1_0000_0000)
        )
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: "function-main",
            name: "_main",
            entryAddress: NativeDecompilerWireUInt64(0x1_0000_1000),
            endAddressExclusive: NativeDecompilerWireUInt64(0x1_0000_1004)
        )
        let target = try NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_000c,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "a", count: 64),
            selectedSliceByteCount: 4
        )
        let memoryRegions = [
            NativeDecompilerWireMemoryRegion(
                name: "__text",
                startAddress: function.entryAddress,
                permissions: .readExecute,
                rawBytes: Data([0x1F, 0x20, 0x03, 0xD5]),
                effectiveBytes: Data([0x1F, 0x20, 0x03, 0xD5]),
                appliedPatchIDs: []
            ),
        ]
        let symbols: [NativeDecompilerWireSymbolRecord] = []
        let authoredInputs = NativeDecompilerWireAuthoredInputs.empty
        let budgets = NativeDecompilerProductBudgetProfile.v1
        let requestSHA256 = try NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: NativeDecompilerWireRequestEnvelope.currentSchemaVersion,
            operation: .decompile,
            target: target,
            image: image,
            function: function,
            memoryRegions: memoryRegions,
            symbols: symbols,
            authoredInputs: authoredInputs,
            budgets: budgets
        )
        let request = NativeDecompilerWireRequest(
            requestID: requestID,
            requestSHA256: requestSHA256,
            target: target,
            image: image,
            function: function,
            memoryRegions: memoryRegions,
            symbols: symbols,
            authoredInputs: authoredInputs,
            budgets: budgets.wireValue
        )
        return try NativeDecompilerWireCodec().encodeRequest(
            NativeDecompilerWireRequestEnvelope(requestID: requestID, body: request),
            matching: requestID
        )
    }

    private func makeSuccessfulCase() throws -> (
        payload: Data,
        reply: Data,
        envelope: NativeDecompilerWireReplyEnvelope,
        binding: NativeDecompilerWireExpectedRequestBinding
    ) {
        let fixture = makeNativeDecompilerWireSemanticValidatorTestFixture()
        let request = NativeDecompilerWireRequestEnvelope(
            requestID: fixture.request.requestID,
            body: fixture.request
        )
        let binding = NativeDecompilerWireExpectedRequestBinding(request: request)
        let availability = NativeDecompilerWireBackendAvailability(
            available: true,
            reasonCode: "",
            runtimeIdentity: NativeDecompilerRuntimeIdentity(
                backendID: "native-decompiler",
                engineVersion: "12.1.2",
                engineRevision: String(repeating: "b", count: 40),
                wrapperVersion: "dcp03b5-v1",
                wrapperRevision: String(repeating: "c", count: 40),
                packageManifestSHA256: String(repeating: "d", count: 64),
                packageTreeSHA256: String(repeating: "e", count: 64),
                languageID: "AARCH64:LE:64:AppleSilicon", compilerSpecID: "default",
                targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
                contextProfileSHA256: "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
            ),
            capabilities: fixture.capabilities
        )
        let reply = NativeDecompilerWireReplyEnvelope(
            requestID: request.requestID,
            success: NativeDecompilerWireSuccess(
                availability: availability,
                result: fixture.result
            )
        )
        let codec = NativeDecompilerWireCodec()
        return (
            payload: try codec.encodeRequest(request, matching: request.requestID),
            reply: try codec.encodeReply(reply, matching: binding),
            envelope: reply,
            binding: binding
        )
    }

    private func mutatingPropertyList(
        _ data: Data,
        path: [String],
        value: Any
    ) throws -> Data {
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [.mutableContainersAndLeaves],
                format: nil
            ) as? NSMutableDictionary
        )
        var current = root
        for component in path.dropLast() {
            current = try XCTUnwrap(current[component] as? NSMutableDictionary)
        }
        current[path.last!] = value
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    private func failureReply(
        requestID: UUID,
        code: NativeDecompilerWireFailureCode
    ) throws -> Data {
        try NativeDecompilerWireCodec().encodeReply(
            NativeDecompilerWireReplyEnvelope(
                requestID: requestID,
                failure: NativeDecompilerWireFailure(code: code, detail: nil)
            ),
            matching: requestID
        )
    }

    private func replyFailureCode(_ data: Data) throws -> String {
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        let failure = try XCTUnwrap(object["failure"] as? [String: Any])
        return try XCTUnwrap(failure["code"] as? String)
    }
}

private final class NativeCompositionPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Bool
    private var calls = 0

    init(result: Bool) {
        self.result = result
    }

    var callCount: Int { lock.withLock { calls } }

    func prepare() -> Bool {
        lock.withLock { calls += 1 }
        return result
    }
}

private final class NativeRequestFactoryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let defaultResponse: Data?
    private let responses: [UUID: Data]
    private let waitsForCancellation: Bool
    private let waitsForRelease: Bool
    private var created = 0
    private var payloads: [UUID: Data] = [:]
    private var starts: [UUID: DispatchSemaphore] = [:]
    private var cancellations: [UUID: DispatchSemaphore] = [:]
    private var cancellationCountByID: [UUID: Int] = [:]
    private var releases: [UUID: DispatchSemaphore] = [:]

    init(
        response: Data,
        waitsForCancellation: Bool = false,
        waitsForRelease: Bool = false
    ) {
        defaultResponse = response
        responses = [:]
        self.waitsForCancellation = waitsForCancellation
        self.waitsForRelease = waitsForRelease
    }

    init(responseByRequestID: [UUID: Data], waitsForRelease: Bool) {
        defaultResponse = nil
        responses = responseByRequestID
        waitsForCancellation = false
        self.waitsForRelease = waitsForRelease
    }

    var createdRequestCount: Int { lock.withLock { created } }
    var executedPayloads: [UUID: Data] { lock.withLock { payloads } }
    var cancellationCounts: [UUID: Int] { lock.withLock { cancellationCountByID } }

    func makeRequest(requestID: UUID) -> NativeDecompilerServiceNativeRequest {
        lock.withLock { created += 1 }
        return NativeRequestProbe(owner: self, requestID: requestID)
    }

    func execute(requestID: UUID, payload: Data) -> Data {
        let state = lock.withLock { () -> (DispatchSemaphore, DispatchSemaphore, DispatchSemaphore) in
            payloads[requestID] = payload
            let start = semaphore(for: requestID, in: &starts)
            let cancellation = semaphore(for: requestID, in: &cancellations)
            let release = semaphore(for: requestID, in: &releases)
            return (start, cancellation, release)
        }
        state.0.signal()
        if waitsForCancellation { state.1.wait() }
        if waitsForRelease { state.2.wait() }
        return lock.withLock { responses[requestID] ?? defaultResponse! }
    }

    func cancel(requestID: UUID) {
        let cancellation = lock.withLock { () -> DispatchSemaphore in
            cancellationCountByID[requestID, default: 0] += 1
            return semaphore(for: requestID, in: &cancellations)
        }
        cancellation.signal()
    }

    func waitUntilStarted(_ requestID: UUID) -> Bool {
        let semaphore = lock.withLock {
            semaphore(for: requestID, in: &starts)
        }
        return semaphore.wait(timeout: .now() + 1) == .success
    }

    func waitUntilCancelled(_ requestID: UUID) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if lock.withLock({ cancellationCountByID[requestID, default: 0] > 0 }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline
        return lock.withLock { cancellationCountByID[requestID, default: 0] > 0 }
    }

    func release(_ requestID: UUID) {
        let semaphore = lock.withLock {
            semaphore(for: requestID, in: &releases)
        }
        semaphore.signal()
    }

    private func semaphore(
        for requestID: UUID,
        in storage: inout [UUID: DispatchSemaphore]
    ) -> DispatchSemaphore {
        if let existing = storage[requestID] {
            return existing
        }
        let created = DispatchSemaphore(value: 0)
        storage[requestID] = created
        return created
    }
}

private final class NativeRequestProbe: NativeDecompilerServiceNativeRequest, @unchecked Sendable {
    private let owner: NativeRequestFactoryProbe
    private let requestID: UUID

    init(owner: NativeRequestFactoryProbe, requestID: UUID) {
        self.owner = owner
        self.requestID = requestID
    }

    func cancel() { owner.cancel(requestID: requestID) }

    func execute(requestID: UUID, payload: Data) -> Data {
        precondition(requestID == self.requestID)
        return owner.execute(requestID: requestID, payload: payload)
    }
}

private final class NativeCompositionReplyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Data] = []

    var values: [Data] { lock.withLock { recorded } }
    func record(_ data: Data) { lock.withLock { recorded.append(data) } }

    func waitForCount(_ count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if lock.withLock({ recorded.count >= count }) { return true }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline
        return lock.withLock { recorded.count >= count }
    }
}

private final class NativeCompositionHardDeadlineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDelays: [UInt64] = []

    var delays: [UInt64] { lock.withLock { recordedDelays } }

    func schedule(
        _ delayMilliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> NativeDecompilerHardDeadlineCancellation {
        lock.withLock { recordedDelays.append(delayMilliseconds) }
        return NativeDecompilerHardDeadlineCancellation {}
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
