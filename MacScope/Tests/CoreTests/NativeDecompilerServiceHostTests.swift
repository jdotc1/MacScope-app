import Foundation
import XCTest
@testable import MacScope

final class NativeDecompilerServiceHostTests: XCTestCase {
    private let requestID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!

    func testOversizedRequestFailsWithoutSubmitting() throws {
        let probe = ServiceHostProbe()
        let host = makeHost(probe: probe)
        let replies = ReplyProbe()

        host.decompile(
            requestID: requestID,
            payload: Data(repeating: 0xA5, count: NativeDecompilerServiceHost.maximumRequestBytes + 1),
            reply: replies.record
        )

        XCTAssertEqual(probe.submittedRequestIDs, [])
        XCTAssertEqual(probe.validatedRequestPayloads, [])
        XCTAssertEqual(replies.values.count, 1)
        XCTAssertEqual(
            try replySchemaVersion(in: replies.values[0]),
            3
        )
        XCTAssertEqual(try failureCode(in: replies.values[0]), "request-too-large")
        XCTAssertEqual(try replyRequestID(in: replies.values[0]), requestID.uuidString)
    }

    func testAcceptedRequestPublishesOnlyFirstValidatedReply() {
        let probe = ServiceHostProbe()
        probe.submissionDisposition = .started
        probe.validateReply = { _, _, data in data == Data([0x01]) || data == Data([0x02]) }
        probe.onSubmit = { _, _, completion in
            completion(Data([0x01]))
            completion(Data([0x02]))
        }
        let host = makeHost(probe: probe)
        let replies = ReplyProbe()

        host.decompile(requestID: requestID, payload: Data([0xCC]), reply: replies.record)

        XCTAssertEqual(probe.submittedRequestIDs, [requestID])
        XCTAssertEqual(probe.validatedRequestPayloads, [Data([0xCC])])
        XCTAssertEqual(replies.values, [Data([0x01])])
    }

    func testMismatchedOrMalformedReplyFailsClosed() throws {
        let probe = ServiceHostProbe()
        probe.submissionDisposition = .started
        probe.validateReply = { _, _, _ in false }
        probe.onSubmit = { _, _, completion in completion(Data([0xFF])) }
        let host = makeHost(probe: probe)
        let replies = ReplyProbe()

        host.decompile(requestID: requestID, payload: Data([0xCC]), reply: replies.record)

        XCTAssertEqual(replies.values.count, 1)
        XCTAssertEqual(try failureCode(in: replies.values[0]), "malformed-reply")
    }

    func testOversizedNativeReplyIsReplacedByBoundedFailure() throws {
        let probe = ServiceHostProbe()
        probe.submissionDisposition = .started
        probe.validateReply = { _, _, _ in true }
        probe.onSubmit = { _, _, completion in
            completion(Data(repeating: 0x7F, count: NativeDecompilerServiceHost.maximumResponseBytes + 1))
        }
        let host = makeHost(probe: probe)
        let replies = ReplyProbe()

        host.decompile(requestID: requestID, payload: Data([0xCC]), reply: replies.record)

        XCTAssertEqual(replies.values.count, 1)
        XCTAssertEqual(try failureCode(in: replies.values[0]), "response-too-large")
        XCTAssertLessThan(replies.values[0].count, NativeDecompilerServiceHost.maximumResponseBytes)
    }

    func testImmediateSchedulerRejectionUsesClosedFailureUnion() throws {
        let probe = ServiceHostProbe()
        probe.submissionDisposition = .rejected(.busy)
        let host = makeHost(probe: probe)
        let replies = ReplyProbe()

        host.decompile(requestID: requestID, payload: Data([0xCC]), reply: replies.record)

        XCTAssertEqual(replies.values.count, 1)
        XCTAssertEqual(try failureCode(in: replies.values[0]), "busy")
    }

    func testInvalidInjectedFailureEncoderFallsBackToClosedCorrelatedFailure() throws {
        let probe = ServiceHostProbe()
        probe.submissionDisposition = .rejected(.busy)
        probe.validateReply = { _, _, _ in false }
        let host = NativeDecompilerServiceHost(
            dependencies: NativeDecompilerServiceDependencies(
                submit: probe.submit,
                cancel: probe.cancel,
                validateReply: probe.validate,
                encodeFailure: { _, _ in Data([0xFF]) }
            )
        )
        let replies = ReplyProbe()

        host.decompile(requestID: requestID, payload: Data([0xCC]), reply: replies.record)

        XCTAssertEqual(replies.values.count, 1)
        XCTAssertEqual(try failureCode(in: replies.values[0]), "busy")
        XCTAssertEqual(try replyRequestID(in: replies.values[0]), requestID.uuidString)
    }

    func testCancellationForwardsOnlyTheExactRequestIdentifier() {
        let probe = ServiceHostProbe()
        let host = makeHost(probe: probe)

        host.cancel(requestID: requestID)

        XCTAssertEqual(probe.cancelledRequestIDs, [requestID])
    }

    func testDefaultDependenciesFailClosedAsUnavailable() throws {
        let host = NativeDecompilerServiceHost(dependencies: .unavailable)
        let replies = ReplyProbe()

        host.decompile(requestID: requestID, payload: Data([0xCC]), reply: replies.record)

        XCTAssertEqual(replies.values.count, 1)
        XCTAssertEqual(try failureCode(in: replies.values[0]), "unavailable")
    }

    func testPrincipalBridgesOnlyNSUUIDAndNSDataAndStillRepliesOnce() throws {
        let probe = ServiceHostProbe()
        probe.submissionDisposition = .started
        probe.validateReply = { _, _, data in data == Data([0x12, 0x34]) }
        probe.onSubmit = { _, _, completion in
            completion(Data([0x12, 0x34]))
            completion(Data([0x56, 0x78]))
        }
        let principal = NativeDecompilerXPCPrincipal(host: makeHost(probe: probe))
        let replies = NSDataReplyProbe()

        principal.decompile(
            requestID: requestID as NSUUID,
            payload: Data([0xAB]) as NSData,
            withReply: replies.record
        )
        principal.cancel(requestID: requestID as NSUUID)

        XCTAssertEqual(replies.values.map { $0 as Data }, [Data([0x12, 0x34])])
        XCTAssertTrue(probe.cancelledRequestIDs.isEmpty)
        XCTAssertNoThrow(NSXPCInterface(with: NativeDecompilerXPCProtocol.self))
    }

    func testPrincipalScopesCancellationToOwningConnectionExactlyOnce() {
        let probe = ServiceHostProbe()
        probe.submissionDisposition = .started
        let host = makeHost(probe: probe)
        let owner = NativeDecompilerXPCPrincipal(host: host)
        let otherConnection = NativeDecompilerXPCPrincipal(host: host)

        owner.decompile(
            requestID: requestID as NSUUID,
            payload: Data([0xAB]) as NSData,
            withReply: { _ in }
        )
        otherConnection.cancel(requestID: requestID as NSUUID)
        owner.cancel(requestID: requestID as NSUUID)
        owner.cancel(requestID: requestID as NSUUID)

        XCTAssertEqual(probe.cancelledRequestIDs, [requestID])
    }

    func testPrincipalInvalidationCancelsOwnedRequestsOnceAndClosesAdmission() throws {
        let probe = ServiceHostProbe()
        probe.submissionDisposition = .started
        let principal = NativeDecompilerXPCPrincipal(host: makeHost(probe: probe))
        let secondRequestID = UUID()

        principal.decompile(
            requestID: requestID as NSUUID,
            payload: Data([0x01]) as NSData,
            withReply: { _ in }
        )
        principal.decompile(
            requestID: secondRequestID as NSUUID,
            payload: Data([0x02]) as NSData,
            withReply: { _ in }
        )
        principal.invalidateConnection()
        principal.invalidateConnection()

        let lateReplies = NSDataReplyProbe()
        let lateRequestID = UUID()
        principal.decompile(
            requestID: lateRequestID as NSUUID,
            payload: Data([0x03]) as NSData,
            withReply: lateReplies.record
        )

        XCTAssertEqual(Set(probe.cancelledRequestIDs), Set([requestID, secondRequestID]))
        XCTAssertEqual(probe.cancelledRequestIDs.count, 2)
        XCTAssertEqual(probe.submittedRequestIDs, [requestID, secondRequestID])
        XCTAssertEqual(lateReplies.values.count, 1)
        XCTAssertEqual(try failureCode(in: lateReplies.values[0] as Data), "unavailable")
    }

    func testFailureEncoderEmitsExclusiveBinaryPropertyListUnion() throws {
        let payload = NativeDecompilerServiceFailureReplyEncoder.encode(
            requestID: requestID,
            failure: .cancelled
        )
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(
            object["schemaVersion"] as? Int,
            3
        )
        XCTAssertEqual(object["requestID"] as? String, requestID.uuidString)
        XCTAssertEqual(object["outcome"] as? String, "failure")
        XCTAssertNil(object["success"])
        let failure = try XCTUnwrap(object["failure"] as? [String: Any])
        XCTAssertEqual(failure["code"] as? String, "cancelled")
        XCTAssertNil(failure["detail"])
        XCTAssertTrue(payload.starts(with: Data("bplist00".utf8)))
    }

    private func makeHost(probe: ServiceHostProbe) -> NativeDecompilerServiceHost {
        NativeDecompilerServiceHost(
            dependencies: NativeDecompilerServiceDependencies(
                submit: probe.submit,
                cancel: probe.cancel,
                validateReply: probe.validate,
                encodeFailure: NativeDecompilerServiceFailureReplyEncoder.encode
            )
        )
    }

    private func failureCode(in data: Data) throws -> String {
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        let failure = try XCTUnwrap(object["failure"] as? [String: Any])
        return try XCTUnwrap(failure["code"] as? String)
    }

    private func replyRequestID(in data: Data) throws -> String {
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        return try XCTUnwrap(object["requestID"] as? String)
    }

    private func replySchemaVersion(in data: Data) throws -> Int {
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
        return try XCTUnwrap(object["schemaVersion"] as? Int)
    }
}

private final class ServiceHostProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _submittedRequestIDs: [UUID] = []
    private var _cancelledRequestIDs: [UUID] = []
    private var _validatedRequestPayloads: [Data] = []

    var submissionDisposition: NativeDecompilerServiceSubmissionDisposition = .started
    var validateReply: @Sendable (UUID, Data, Data) -> Bool = { _, _, _ in true }
    var onSubmit: @Sendable (
        UUID,
        Data,
        @escaping @Sendable (Data) -> Void
    ) -> Void = { _, _, _ in }

    var submittedRequestIDs: [UUID] {
        lock.withLock { _submittedRequestIDs }
    }

    var cancelledRequestIDs: [UUID] {
        lock.withLock { _cancelledRequestIDs }
    }

    var validatedRequestPayloads: [Data] {
        lock.withLock { _validatedRequestPayloads }
    }

    func submit(
        requestID: UUID,
        payload: Data,
        completion: @escaping @Sendable (Data) -> Void
    ) -> NativeDecompilerServiceSubmissionDisposition {
        lock.withLock { _submittedRequestIDs.append(requestID) }
        onSubmit(requestID, payload, completion)
        return submissionDisposition
    }

    func cancel(requestID: UUID) {
        lock.withLock { _cancelledRequestIDs.append(requestID) }
    }

    func validate(requestID: UUID, requestPayload: Data, reply: Data) -> Bool {
        lock.withLock { _validatedRequestPayloads.append(requestPayload) }
        return validateReply(requestID, requestPayload, reply)
    }
}

private final class ReplyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Data] = []

    var values: [Data] {
        lock.withLock { _values }
    }

    func record(_ value: Data) {
        lock.withLock { _values.append(value) }
    }
}

private final class NSDataReplyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [NSData] = []

    var values: [NSData] {
        lock.withLock { _values }
    }

    func record(_ value: NSData) {
        lock.withLock { _values.append(value) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
