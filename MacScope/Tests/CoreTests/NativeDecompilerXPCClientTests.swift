import Foundation
#if NATIVE_DECOMPILER_XPC_CLIENT_FOCUSED_MAIN
import Darwin

class XCTestCase {}

private struct NativeDecompilerXPCClientFocusedAssertionFailure: Error {}

private final class NativeDecompilerXPCClientFocusedTestState: @unchecked Sendable {
    static let shared = NativeDecompilerXPCClientFocusedTestState()
    private let lock = NSLock()
    private var failures: [String] = []

    var failureCount: Int { lock.withLock { failures.count } }

    func record(_ message: String, file: StaticString, line: UInt) {
        lock.withLock { failures.append("\(file):\(line): \(message)") }
        fputs("FAIL: \(file):\(line): \(message)\n", stderr)
    }
}

private func XCTAssertEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let actual = try actual()
        let expected = try expected()
        guard actual != expected else { return }
        NativeDecompilerXPCClientFocusedTestState.shared.record(
            message().isEmpty ? "values are not equal" : message(),
            file: file,
            line: line
        )
    } catch {
        NativeDecompilerXPCClientFocusedTestState.shared.record(
            message().isEmpty ? "assertion expression threw" : message(),
            file: file,
            line: line
        )
    }
}

private func XCTAssertTrue(
    _ value: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard !value() else { return }
    NativeDecompilerXPCClientFocusedTestState.shared.record(
        message().isEmpty ? "expected true" : message(),
        file: file,
        line: line
    )
}

private func XCTAssertFalse(
    _ value: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard value() else { return }
    NativeDecompilerXPCClientFocusedTestState.shared.record(
        message().isEmpty ? "expected false" : message(),
        file: file,
        line: line
    )
}

private func XCTAssertNotNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard value() == nil else { return }
    NativeDecompilerXPCClientFocusedTestState.shared.record(
        message().isEmpty ? "expected non-nil value" : message(),
        file: file,
        line: line
    )
}

private func XCTAssertLessThanOrEqual<T: Comparable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard actual() > expected() else { return }
    NativeDecompilerXPCClientFocusedTestState.shared.record(
        message().isEmpty ? "value exceeds expected ceiling" : message(),
        file: file,
        line: line
    )
}

private func XCTUnwrap<T>(
    _ value: @autoclosure () -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    if let value = value() { return value }
    NativeDecompilerXPCClientFocusedTestState.shared.record(
        message().isEmpty ? "expected non-nil value" : message(),
        file: file,
        line: line
    )
    throw NativeDecompilerXPCClientFocusedAssertionFailure()
}
#else
import XCTest
#if SWIFT_PACKAGE
@testable import NativeDecompilerXPCClientCore
#else
@testable import MacScope
#endif
#endif

final class NativeDecompilerXPCClientTests: XCTestCase {
    func testClientGeneratesRequestIdentifierBeforeEncoding() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let encodedID = UUID()
        let dispatchRequest = try makeDispatchRequest(
            requestID: encodedID,
            binding: "identity-proof"
        )
        let request = NativeDecompilerXPCClientAsyncRequest()
        let task = Task { [request] in
            do {
                request.finish(.success(try await client.decompile(request: dispatchRequest)))
            } catch let failure as NativeDecompilerXPCClientFailure {
                request.finish(.failure(failure))
            } catch {
                request.finish(.failure(.connectionUnavailable))
            }
        }
        request.install(task: task)
        let call = try XCTUnwrap(connection.waitForCall())

        XCTAssertEqual(encodedID, call.requestID)
        XCTAssertEqual(requestID(in: call.payload), call.requestID)
        XCTAssertEqual(call.payload, dispatchRequest.payload)
        connection.emit(.invalidated)
        XCTAssertEqual(request.waitFailure(), .invalidated)
    }

    func testRequestEncodingFailureIsStableAndDoesNotCreateConnection() {
        let connection = NativeDecompilerXPCClientTestConnection()
        let factory = NativeDecompilerXPCClientTestConnectionFactory([connection])
        _ = makeClient(factory: factory)
        let valid = makeRequestEnvelope(requestID: UUID(), binding: "invalid-projection")
        let invalid = NativeDecompilerWireRequest(
            requestID: valid.requestID,
            requestSHA256: "not-a-canonical-sha256",
            target: valid.body.target,
            image: valid.body.image,
            function: valid.body.function,
            memoryRegions: valid.body.memoryRegions,
            symbols: valid.body.symbols,
            authoredInputs: valid.body.authoredInputs,
            budgets: valid.body.budgets
        )
        var observedFailure: NativeDecompilerSnapshotProjectionError?
        do {
            _ = try NativeDecompilerPreencodedDispatchRequest(
                projection: .init(request: invalid),
                requestID: valid.requestID
            )
        } catch let failure as NativeDecompilerSnapshotProjectionError {
            observedFailure = failure
        } catch {
            observedFailure = .invalidProjectedRequest
        }

        XCTAssertEqual(observedFailure, .invalidProjectedRequest)
        XCTAssertEqual(factory.creationCount, 0)
        XCTAssertTrue(connection.calls.isEmpty)
    }

    func testProxyErrorClassifierPreservesFoundationLifecycleCategories() {
        XCTAssertEqual(
            NativeDecompilerXPCProxyErrorClassifier.classify(NSError(
                domain: NSCocoaErrorDomain,
                code: NSXPCConnectionInterrupted
            )),
            .interrupted
        )
        XCTAssertEqual(
            NativeDecompilerXPCProxyErrorClassifier.classify(NSError(
                domain: NSCocoaErrorDomain,
                code: NSXPCConnectionInvalid
            )),
            .invalidated
        )
    }

    func testProxyErrorClassifierUsesConservativeCategoryForUnknownErrors() {
        XCTAssertEqual(
            NativeDecompilerXPCProxyErrorClassifier.classify(NSError(
                domain: "example.synthetic",
                code: NSXPCConnectionInterrupted
            )),
            .connectionFailure
        )
        XCTAssertEqual(
            NativeDecompilerXPCProxyErrorClassifier.classify(NSError(
                domain: NSCocoaErrorDomain,
                code: 9_999
            )),
            .connectionFailure
        )
    }

    func testCanonicalFailureReplyReturnsDecodedEnvelopeExactlyOnce() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let timer = NativeDecompilerXPCClientManualTimer()
        let client = makeClient(connections: [connection], timer: timer)
        let request = startRequest(client: client, payload: Data([0x01]))

        let call = try XCTUnwrap(connection.waitForCall())
        let reply = makeUnavailableReply(requestID: call.requestID)
        connection.reply(to: call.requestID, with: reply)
        connection.reply(to: call.requestID, with: Data("late-duplicate".utf8))

        XCTAssertEqual(try request.wait().get(), reply)
        XCTAssertEqual(connection.resumeCount, 1)
        XCTAssertEqual(connection.cancelledRequestIDs, [])
        XCTAssertEqual(connection.invalidateCount, 0)
        XCTAssertEqual(timer.activeActionCount, 0)
    }

    func testCanonicalCodecAcceptsLegitimateFailureEnvelope() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let request = startRequest(client: client, payload: Data())
        let call = try XCTUnwrap(connection.waitForCall())
        let reply = makeUnavailableReply(
            requestID: call.requestID,
            detail: "provider-unavailable"
        )

        connection.reply(to: call.requestID, with: reply)

        XCTAssertEqual(try request.wait().get(), reply)
    }

    func testOversizeRequestFailsBeforeCreatingAConnection() {
        let connection = NativeDecompilerXPCClientTestConnection()
        let factory = NativeDecompilerXPCClientTestConnectionFactory([connection])
        let client = NativeDecompilerXPCClient(
            configuration: .init(maximumRequestBytes: 3, maximumResponseBytes: 64),
            connectionFactory: factory.makeConnection,
            timerScheduler: NativeDecompilerXPCClientManualTimer()
        )

        let request = startRequest(client: client, payload: Data([0, 1, 2, 3]))

        XCTAssertEqual(request.waitFailure(), .requestTooLarge)
        XCTAssertEqual(factory.creationCount, 0)
        XCTAssertTrue(connection.calls.isEmpty)
    }

    func testOversizeResponseFailsWithoutPublishingOrDoubleCompleting() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = NativeDecompilerXPCClient(
            configuration: .init(maximumRequestBytes: 1_048_576, maximumResponseBytes: 4),
            connectionFactory: NativeDecompilerXPCClientTestConnectionFactory([connection]).makeConnection,
            timerScheduler: NativeDecompilerXPCClientManualTimer()
        )
        let request = startRequest(client: client, payload: Data())
        let call = try XCTUnwrap(connection.waitForCall())

        connection.reply(to: call.requestID, with: Data(repeating: 0x41, count: 5))
        connection.reply(to: call.requestID, with: makeUnavailableReply(requestID: call.requestID))

        XCTAssertEqual(request.waitFailure(), .responseTooLarge)
    }

    func testMalformedReplyFailsClosedWithoutLeakingPayloadText() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let request = startRequest(client: client, payload: Data("SECRET-SYMBOL".utf8))
        let call = try XCTUnwrap(connection.waitForCall())

        connection.reply(to: call.requestID, with: Data("/Users/example/private 0xdeadbeef".utf8))

        XCTAssertEqual(request.waitFailure(), .malformedReply)
        assertSanitized(.malformedReply)
    }

    func testMismatchedReplyIdentifierFailsClosed() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let request = startRequest(client: client, payload: Data())
        let call = try XCTUnwrap(connection.waitForCall())

        connection.reply(to: call.requestID, with: makeUnavailableReply(requestID: UUID()))

        XCTAssertEqual(request.waitFailure(), .replyRequestMismatch)
    }

    func testCanonicalCodecRejectsSuccessfulReplyBoundToDifferentRequest() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let reusedID = UUID()
        let client = NativeDecompilerXPCClient(
            connectionFactory: NativeDecompilerXPCClientTestConnectionFactory([connection]).makeConnection,
            timerScheduler: NativeDecompilerXPCClientManualTimer()
        )
        let request = startRequest(
            client: client,
            payload: Data([0x11]),
            binding: "expected-binding",
            requestID: reusedID
        )
        let call = try XCTUnwrap(connection.waitForCall())
        let forgedRequest = makeRequestEnvelope(
            requestID: reusedID,
            binding: "forged-binding",
            payload: Data([0x22])
        )
        let forgedReply = makeSuccessReply(for: forgedRequest)
        let forgedData = try NativeDecompilerWireCodec().encodeReply(
            forgedReply,
            matching: NativeDecompilerWireExpectedRequestBinding(request: forgedRequest)
        )

        connection.reply(to: call.requestID, with: forgedData)

        XCTAssertEqual(request.waitFailure(), .replyRequestMismatch)
    }

    func testCanonicalCodecRejectsTopLevelPlausibleSemanticallyMalformedSuccess() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let requestBox = NativeDecompilerXPCClientRequestEnvelopeBox()
        let request = startRequest(client: client, payload: Data(), requestBox: requestBox)
        let call = try XCTUnwrap(connection.waitForCall())
        let envelope = try XCTUnwrap(requestBox.value)
        let malformed = makeSuccessReply(for: envelope, omitMandatorySSABinding: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary

        connection.reply(to: call.requestID, with: try encoder.encode(malformed))

        XCTAssertEqual(request.waitFailure(), .malformedReply)
    }

    func testCanonicalCodecPublishesFullyDecodedSuccessfulReply() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let requestBox = NativeDecompilerXPCClientRequestEnvelopeBox()
        let request = startRequest(client: client, payload: Data(), requestBox: requestBox)
        let call = try XCTUnwrap(connection.waitForCall())
        let envelope = try XCTUnwrap(requestBox.value)
        let reply = makeSuccessReply(for: envelope)
        let data = try NativeDecompilerWireCodec().encodeReply(
            reply,
            matching: NativeDecompilerWireExpectedRequestBinding(request: envelope)
        )

        connection.reply(to: call.requestID, with: data)

        XCTAssertEqual(try request.wait().get(), reply)
    }

    func testCallerCancellationSendsOneCancelAndSuppressesReplyDuringGrace() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let timer = NativeDecompilerXPCClientManualTimer()
        let client = makeClient(connections: [connection], timer: timer)
        let request = startRequest(client: client, payload: Data())
        let call = try XCTUnwrap(connection.waitForCall())

        request.cancel()
        XCTAssertTrue(connection.waitForCancel(requestID: call.requestID))
        request.cancel()
        connection.reply(to: call.requestID, with: makeUnavailableReply(requestID: call.requestID))

        XCTAssertEqual(request.waitFailure(), .cancelled)
        XCTAssertEqual(connection.cancelledRequestIDs, [call.requestID])
        XCTAssertEqual(connection.invalidateCount, 0)
        XCTAssertEqual(timer.activeActionCount, 0)
    }

    func testCallerCancellationWinsOverOversizeReplyDuringGrace() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let timer = NativeDecompilerXPCClientManualTimer()
        let client = NativeDecompilerXPCClient(
            configuration: .init(maximumRequestBytes: 1_048_576, maximumResponseBytes: 4),
            connectionFactory: NativeDecompilerXPCClientTestConnectionFactory([connection]).makeConnection,
            timerScheduler: timer
        )
        let request = startRequest(client: client, payload: Data())
        let call = try XCTUnwrap(connection.waitForCall())

        request.cancel()
        XCTAssertTrue(connection.waitForCancel(requestID: call.requestID))
        connection.reply(to: call.requestID, with: Data(repeating: 0x41, count: 5))

        XCTAssertEqual(request.waitFailure(), .cancelled)
        XCTAssertEqual(connection.cancelledRequestIDs, [call.requestID])
        XCTAssertEqual(connection.invalidateCount, 0)
    }

    func testCancellationRecordedDuringReplyDecodeWinsTerminalArbitration() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let timer = NativeDecompilerXPCClientManualTimer()
        let decodeEntered = DispatchSemaphore(value: 0)
        let allowDecode = DispatchSemaphore(value: 0)
        let client = NativeDecompilerXPCClient(
            connectionFactory: NativeDecompilerXPCClientTestConnectionFactory([connection]).makeConnection,
            timerScheduler: timer,
            replyDecodeWillBegin: {
                decodeEntered.signal()
                allowDecode.wait()
            }
        )
        let request = startRequest(client: client, payload: Data())
        let call = try XCTUnwrap(connection.waitForCall())
        let replyDelivery = DispatchGroup()
        replyDelivery.enter()
        DispatchQueue.global().async {
            connection.reply(
                to: call.requestID,
                with: makeUnavailableReply(requestID: call.requestID)
            )
            replyDelivery.leave()
        }

        XCTAssertEqual(decodeEntered.wait(timeout: .now() + 1), .success)
        request.cancel()
        XCTAssertTrue(connection.waitForCancel(requestID: call.requestID))
        allowDecode.signal()
        XCTAssertEqual(replyDelivery.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(request.waitFailure(), .cancelled)
        XCTAssertEqual(connection.cancelledRequestIDs, [call.requestID])
        XCTAssertEqual(connection.invalidateCount, 0)
        XCTAssertEqual(timer.activeActionCount, 0)
        XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
    }

    func testDefaultWatchdogUsesFifteenSecondMonotonicDeadline() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let timer = NativeDecompilerXPCClientManualTimer()
        let client = makeClient(connections: [connection], timer: timer)
        let request = startRequest(client: client, payload: Data())
        let call = try XCTUnwrap(connection.waitForCall())

        XCTAssertTrue(timer.waitForSchedule())
        XCTAssertEqual(timer.scheduledDelays.first, .seconds(15))
        let reply = makeUnavailableReply(requestID: call.requestID)
        connection.reply(to: call.requestID, with: reply)
        XCTAssertEqual(try request.wait().get(), reply)
    }

    func testWatchdogClampsToElapsedBudgetThenInvalidatesAfterGrace() throws {
        let dispatchReturnGate = NativeDecompilerXPCClientLifecycleGate()
        defer { dispatchReturnGate.release() }
        let connection = NativeDecompilerXPCClientTestConnection(decompileReturnGate: dispatchReturnGate)
        let timer = NativeDecompilerXPCClientManualTimer()
        let client = makeClient(connections: [connection], timer: timer)
        let request = startRequest(
            client: client,
            payload: Data(),
            elapsedTimeBudget: .seconds(2)
        )
        let call = try XCTUnwrap(connection.waitForCall())

        // A recorded connection call does not mean dispatch has returned and
        // installed its watchdog. Hold that window open deterministically.
        XCTAssertTrue(dispatchReturnGate.waitUntilEntered())
        XCTAssertEqual(timer.scheduledDelays, [])
        dispatchReturnGate.release()
        XCTAssertTrue(timer.waitForSchedule())
        XCTAssertEqual(timer.scheduledDelays.first, .seconds(2))
        timer.advance(by: .milliseconds(1_999))
        XCTAssertEqual(connection.cancelledRequestIDs, [])
        timer.advance(by: .milliseconds(1))
        XCTAssertEqual(connection.cancelledRequestIDs, [call.requestID])
        XCTAssertEqual(connection.invalidateCount, 0)
        XCTAssertEqual(timer.scheduledDelays.last, .milliseconds(500))
        timer.advance(by: .milliseconds(499))
        XCTAssertEqual(connection.invalidateCount, 0)
        timer.advance(by: .milliseconds(1))

        XCTAssertEqual(request.waitFailure(), .timedOut)
        XCTAssertEqual(connection.cancelledRequestIDs, [call.requestID])
        XCTAssertEqual(connection.invalidateCount, 1)
    }

    func testInterruptionFailsPendingRequestWithoutAutomaticRetry() throws {
        let first = NativeDecompilerXPCClientTestConnection()
        let second = NativeDecompilerXPCClientTestConnection()
        let factory = NativeDecompilerXPCClientTestConnectionFactory([first, second])
        let client = makeClient(factory: factory)
        let request = startRequest(client: client, payload: Data())
        XCTAssertNotNil(first.waitForCall())

        first.emit(.interrupted)

        XCTAssertEqual(request.waitFailure(), .interrupted)
        XCTAssertEqual(factory.creationCount, 1, "A failed request must never be retried automatically.")
        XCTAssertEqual(second.calls.count, 0)
    }

    func testSynchronousInterruptionDuringResumeFailsWithoutDispatching() {
        let connection = NativeDecompilerXPCClientTestConnection(eventOnResume: .interrupted)
        let client = makeClient(connections: [connection])

        let request = startRequest(client: client, payload: Data())

        XCTAssertEqual(request.waitFailure(), .interrupted)
        XCTAssertEqual(connection.resumeCount, 1)
        XCTAssertTrue(connection.calls.isEmpty)
    }

    func testInvalidationHasDistinctTerminalCategory() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let request = startRequest(client: client, payload: Data())
        XCTAssertNotNil(connection.waitForCall())

        connection.emit(.invalidated)

        XCTAssertEqual(request.waitFailure(), .invalidated)
    }

    func testFoundationLifecycleMapsRemoteExitOrCrashToInterruption() {
        XCTAssertEqual(
            NativeDecompilerXPCFoundationLifecycleClassifier.remoteProcessTermination,
            .interrupted
        )
        XCTAssertEqual(
            NativeDecompilerXPCFoundationLifecycleClassifier.permanentInvalidation,
            .invalidated
        )
    }

    func testUnknownProxyFailureUsesConservativeTerminalCategory() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let request = startRequest(client: client, payload: Data())
        XCTAssertNotNil(connection.waitForCall())

        connection.emit(.connectionFailure)

        XCTAssertEqual(request.waitFailure(), .connectionFailure)
    }

    func testInterruptionCleansUpAndRelaunchesWithFreshGeneration() throws {
        let first = NativeDecompilerXPCClientTestConnection()
        let second = NativeDecompilerXPCClientTestConnection()
        let factory = NativeDecompilerXPCClientTestConnectionFactory([first, second])
        let reusedID = UUID()
        let client = NativeDecompilerXPCClient(
            connectionFactory: factory.makeConnection,
            timerScheduler: NativeDecompilerXPCClientManualTimer()
        )

        let firstRequest = startRequest(client: client, payload: Data([0x01]), requestID: reusedID)
        let firstCall = try XCTUnwrap(first.waitForCall())
        first.emit(.interrupted)
        XCTAssertEqual(firstRequest.waitFailure(), .interrupted)

        let secondRequest = startRequest(client: client, payload: Data([0x02]), requestID: reusedID)
        let secondCall = try XCTUnwrap(second.waitForCall())
        XCTAssertEqual(firstCall.requestID, reusedID)
        XCTAssertEqual(secondCall.requestID, reusedID)
        // The stale and current failure envelopes are intentionally identical: only connection
        // generation may distinguish the old callback when the UUID is reused.
        first.reply(to: firstCall.requestID, with: makeUnavailableReply(requestID: reusedID))
        XCTAssertFalse(secondRequest.isComplete)
        let currentReply = makeUnavailableReply(requestID: reusedID)
        second.reply(to: secondCall.requestID, with: currentReply)

        XCTAssertEqual(try secondRequest.wait().get(), currentReply)
        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertEqual(client.snapshot.connectionGeneration, 2)
    }

    func testStaleGenerationEventCannotRetireReplacementConnection() throws {
        let first = NativeDecompilerXPCClientTestConnection()
        let second = NativeDecompilerXPCClientTestConnection()
        let factory = NativeDecompilerXPCClientTestConnectionFactory([first, second])
        let client = makeClient(factory: factory)

        let firstRequest = startRequest(client: client, payload: Data([0x01]))
        XCTAssertNotNil(first.waitForCall())
        first.emit(.invalidated)
        XCTAssertEqual(firstRequest.waitFailure(), .invalidated)

        let secondRequest = startRequest(client: client, payload: Data([0x02]))
        let secondCall = try XCTUnwrap(second.waitForCall())
        first.emit(.interrupted)
        XCTAssertFalse(secondRequest.isComplete)
        let reply = makeUnavailableReply(requestID: secondCall.requestID)
        second.reply(to: secondCall.requestID, with: reply)

        XCTAssertEqual(try secondRequest.wait().get(), reply)
    }

    func testLifecycleHandlerReportsOnlyRetiredCurrentGenerations() throws {
        let first = NativeDecompilerXPCClientTestConnection()
        let second = NativeDecompilerXPCClientTestConnection()
        let factory = NativeDecompilerXPCClientTestConnectionFactory([first, second])
        let client = makeClient(factory: factory)
        let lifecycle = NativeDecompilerXPCClientLifecycleRecorder()
        client.setConnectionLifecycleHandler { event, generation in
            lifecycle.record(event: event, generation: generation)
        }

        let firstRequest = startRequest(client: client, payload: Data([0x01]))
        XCTAssertNotNil(first.waitForCall())
        first.emit(.interrupted)
        XCTAssertEqual(firstRequest.waitFailure(), .interrupted)

        let secondRequest = startRequest(client: client, payload: Data([0x02]))
        let secondCall = try XCTUnwrap(second.waitForCall())
        first.emit(.connectionFailure)
        XCTAssertEqual(lifecycle.events, [.init(event: .interrupted, generation: 1)])
        XCTAssertFalse(secondRequest.isComplete)

        second.emit(.invalidated)
        XCTAssertEqual(secondRequest.waitFailure(), .invalidated)
        XCTAssertEqual(
            lifecycle.events,
            [
                .init(event: .interrupted, generation: 1),
                .init(event: .invalidated, generation: 2),
            ]
        )
        second.reply(
            to: secondCall.requestID,
            with: makeUnavailableReply(requestID: secondCall.requestID)
        )
        XCTAssertEqual(lifecycle.events.count, 2)
    }

    func testTerminalShutdownInvalidatesCurrentConnectionAndRejectsReconnection() async throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let factory = NativeDecompilerXPCClientTestConnectionFactory([connection])
        let client = makeClient(factory: factory)
        let request = startRequest(client: client, payload: Data([0x01]))
        XCTAssertNotNil(connection.waitForCall())

        await client.shutdown()

        XCTAssertEqual(request.waitFailure(), .invalidated)
        XCTAssertEqual(connection.invalidateCount, 1)
        XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
        XCTAssertFalse(client.snapshot.hasConnection)

        let rejected = startRequest(client: client, payload: Data([0x02]))
        XCTAssertEqual(rejected.waitFailure(), .invalidated)
        XCTAssertEqual(factory.creationCount, 1)
    }

    func testLifecycleFenceClosesBeforeInterruptedRequestSettles() throws {
        let connection = NativeDecompilerXPCClientTestConnection()
        let client = makeClient(connections: [connection])
        let gate = NativeDecompilerXPCClientLifecycleGate()
        client.setConnectionLifecycleHandler { _, _ in
            gate.enterAndWait()
        }
        let request = startRequest(client: client, payload: Data([0x01]))
        XCTAssertNotNil(connection.waitForCall())

        connection.emit(.interrupted)

        XCTAssertTrue(gate.waitUntilEntered())
        XCTAssertFalse(request.isComplete)
        gate.release()
        XCTAssertEqual(request.waitFailure(), .interrupted)
    }

    func testConcurrentReplyAndInvalidationCompleteExactlyOnce() throws {
        for _ in 0..<50 {
            let connection = NativeDecompilerXPCClientTestConnection()
            let client = makeClient(connections: [connection])
            let request = startRequest(client: client, payload: Data())
            let call = try XCTUnwrap(connection.waitForCall())
            let reply = makeUnavailableReply(requestID: call.requestID)
            let gate = DispatchSemaphore(value: 0)
            let race = DispatchGroup()

            race.enter()
            DispatchQueue.global().async {
                gate.wait()
                connection.reply(to: call.requestID, with: reply)
                race.leave()
            }
            race.enter()
            DispatchQueue.global().async {
                gate.wait()
                connection.emit(.invalidated)
                race.leave()
            }
            gate.signal()
            gate.signal()

            XCTAssertEqual(race.wait(timeout: .now() + 1), .success)
            let outcome = request.wait()
            XCTAssertTrue(outcome == .success(reply) || outcome == .failure(.invalidated))
            XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
        }
    }

    func testConcurrentProxyAndLifecycleInterruptionUseSameFailure() throws {
        let proxyEvent = NativeDecompilerXPCProxyErrorClassifier.classify(NSError(
            domain: NSCocoaErrorDomain,
            code: NSXPCConnectionInterrupted
        ))
        for _ in 0..<50 {
            let connection = NativeDecompilerXPCClientTestConnection()
            let client = makeClient(connections: [connection])
            let request = startRequest(client: client, payload: Data())
            XCTAssertNotNil(connection.waitForCall())
            let gate = DispatchSemaphore(value: 0)
            let race = DispatchGroup()

            race.enter()
            DispatchQueue.global().async {
                gate.wait()
                connection.emit(proxyEvent)
                race.leave()
            }
            race.enter()
            DispatchQueue.global().async {
                gate.wait()
                connection.emit(.interrupted)
                race.leave()
            }
            gate.signal()
            gate.signal()

            XCTAssertEqual(race.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(request.waitFailure(), .interrupted)
            XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
        }
    }

    func testEveryClientFailureUsesBoundedStableSanitizedText() {
        for failure in NativeDecompilerXPCClientFailure.allCases {
            assertSanitized(failure)
        }
    }

    private func assertSanitized(
        _ failure: NativeDecompilerXPCClientFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let text = failure.errorDescription ?? ""
        XCTAssertFalse(text.isEmpty, file: file, line: line)
        XCTAssertLessThanOrEqual(text.utf8.count, 96, file: file, line: line)
        XCTAssertFalse(text.contains("/"), file: file, line: line)
        XCTAssertFalse(text.lowercased().contains("0x"), file: file, line: line)
        XCTAssertFalse(text.contains("SECRET"), file: file, line: line)
        XCTAssertFalse(text.contains("SYMBOL"), file: file, line: line)
    }
}

private func makeClient(
    connections: [NativeDecompilerXPCClientTestConnection],
    timer: NativeDecompilerXPCClientManualTimer = NativeDecompilerXPCClientManualTimer()
) -> NativeDecompilerXPCClient {
    makeClient(factory: NativeDecompilerXPCClientTestConnectionFactory(connections), timer: timer)
}

private func makeClient(
    factory: NativeDecompilerXPCClientTestConnectionFactory,
    timer: NativeDecompilerXPCClientManualTimer = NativeDecompilerXPCClientManualTimer()
) -> NativeDecompilerXPCClient {
    NativeDecompilerXPCClient(
        connectionFactory: factory.makeConnection,
        timerScheduler: timer
    )
}

/// One fully valid failure envelope used by lifecycle/race tests. The stale-generation regression
/// deliberately reuses these identical bytes so only the connection generation can reject it.
private func makeUnavailableReply(
    requestID: UUID,
    detail: String? = nil
) -> NativeDecompilerWireReplyEnvelope {
    NativeDecompilerWireReplyEnvelope(
        requestID: requestID,
        failure: .init(code: .unavailable, detail: detail)
    )
}

private func makeRequestEnvelope(
    requestID: UUID,
    binding: String,
    payload: Data = Data()
) -> NativeDecompilerWireRequestEnvelope {
    var bytes = Data(payload.prefix(4))
    while bytes.count < 4 { bytes.append(0) }
    let digestCharacters = ["a", "b", "c", "d", "e", "f"]
    let digestCharacter = digestCharacters[Int((payload.first ?? UInt8(binding.utf8.count)) % 6)]
    let target = try! NativeDecompilerSealedTargetProfile.normalizedTarget(
        rawCPUType: 0x0100_000c,
        rawCPUSubtype: 0,
        selectedSliceSHA256: String(repeating: digestCharacter, count: 64),
        selectedSliceByteCount: UInt64(bytes.count)
    )
    let image = NativeDecompilerWireImageIdentity(
        imageID: "image:main",
        uuid: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        preferredLoadAddress: .init(0x1000)
    )
    let function = NativeDecompilerWireFunctionIdentity(
        functionID: "function:\(binding)",
        name: binding,
        entryAddress: .init(0x1000),
        endAddressExclusive: .init(0x1004)
    )
    let memoryRegions = [
        NativeDecompilerWireMemoryRegion(
            name: "__text",
            startAddress: .init(0x1000),
            permissions: .readExecute,
            rawBytes: bytes,
            effectiveBytes: bytes,
            appliedPatchIDs: []
        ),
    ]
    let symbols: [NativeDecompilerWireSymbolRecord] = []
    let authoredInputs = NativeDecompilerWireAuthoredInputs.empty
    let budgets = NativeDecompilerProductBudgetProfile.v1
    let requestSHA256 = try! NativeDecompilerWireCanonicalRequest.sha256(
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
    let body = NativeDecompilerWireRequest(
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
    return NativeDecompilerWireRequestEnvelope(requestID: requestID, body: body)
}

private func makeSuccessReply(
    for request: NativeDecompilerWireRequestEnvelope,
    omitMandatorySSABinding: Bool = false
) -> NativeDecompilerWireReplyEnvelope {
    let range = NativeDecompilerWireSourceRange(
        imageID: request.body.image.imageID,
        startAddress: request.body.function.entryAddress,
        endAddressExclusive: request.body.function.endAddressExclusive
    )
    let result = NativeDecompilerWireStructuredResult(
        requestID: request.requestID,
        requestSHA256: request.body.requestSHA256,
        image: request.body.image,
        function: request.body.function,
        addressSpaces: [
            .init(
                id: "space:ram",
                name: "ram",
                kind: .processor,
                addressSizeBytes: 8,
                isProcessorSpace: true
            ),
        ],
        types: [],
        instructions: [
            .init(
                id: "instruction:0",
                address: request.body.function.entryAddress,
                bytes: request.body.memoryRegions[0].effectiveBytes,
                mnemonic: "ret",
                body: "",
                operationIDs: ["operation:0"],
                sourceRanges: [range]
            ),
        ],
        varnodes: [
            .init(
                id: "varnode:0",
                addressSpaceID: "space:ram",
                offset: .init(0),
                sizeBytes: 8,
                role: .register,
                typeID: nil,
                registerName: "x0"
            ),
        ],
        operations: [
            .init(
                id: "operation:0",
                blockID: "block:0",
                sequence: .init(0),
                opcode: .return,
                outputVarnodeID: nil,
                inputVarnodeIDs: ["varnode:0"],
                directTargetAddress: nil,
                sourceRanges: [range]
            ),
        ],
        blocks: [
            .init(
                id: "block:0",
                startAddress: request.body.function.entryAddress,
                endAddressExclusive: request.body.function.endAddressExclusive,
                operationIDs: ["operation:0"],
                predecessorEdgeIDs: [],
                successorEdgeIDs: [],
                terminatorKind: .return
            ),
        ],
        edges: [],
        ssaValues: [
            .init(
                id: "ssa:0",
                varnodeID: "varnode:0",
                kind: .functionEntry,
                definingOperationID: nil,
                definingPhiID: nil
            ),
        ],
        ssaBindings: omitMandatorySSABinding ? [] : [
            .init(
                operationID: "operation:0",
                inputSSAValueIDs: ["ssa:0"],
                outputSSAValueID: nil
            ),
        ],
        phis: [],
        memoryVersions: [],
        memoryPhis: [],
        memoryEffects: [],
        variables: [],
        calls: [],
        regions: [
            .init(
                id: "region:root",
                kind: .root,
                parentRegionID: nil,
                childRegionIDs: [],
                blockIDs: ["block:0"],
                conditionOperationID: nil,
                sourceRanges: [range]
            ),
        ],
        tokens: [],
        warnings: []
    )
    let availability = NativeDecompilerWireBackendAvailability(
        available: true,
        reasonCode: "",
        runtimeIdentity: .init(
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
        capabilities: .init(
            nativeDecompilerHeritage: true,
            completeRegisterSSA: false,
            memorySSA: false,
            recoveredVariables: false,
            recoveredTypes: false,
            structuredControlFlow: true,
            tokenizedPseudocode: false,
            imageQualifiedSourceRanges: true
        )
    )
    return NativeDecompilerWireReplyEnvelope(
        requestID: request.requestID,
        success: .init(availability: availability, result: result)
    )
}

private func requestID(in payload: Data) -> UUID? {
    var format = PropertyListSerialization.PropertyListFormat.binary
    guard let propertyList = try? PropertyListSerialization.propertyList(
        from: payload,
        options: [],
        format: &format
    ),
          format == .binary,
          let envelope = propertyList as? [String: Any],
          let text = envelope["requestID"] as? String
    else { return nil }
    return UUID(uuidString: text)
}

private final class NativeDecompilerXPCClientUUIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UUID?
    var value: UUID? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class NativeDecompilerXPCClientLifecycleRecorder: @unchecked Sendable {
    struct Event: Equatable {
        let event: NativeDecompilerXPCConnectionEvent
        let generation: UInt64
    }

    private let lock = NSLock()
    private var recordedEvents: [Event] = []

    var events: [Event] { lock.withLock { recordedEvents } }

    func record(event: NativeDecompilerXPCConnectionEvent, generation: UInt64) {
        lock.withLock {
            recordedEvents.append(.init(event: event, generation: generation))
        }
    }
}

private final class NativeDecompilerXPCClientRequestEnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: NativeDecompilerWireRequestEnvelope?

    var value: NativeDecompilerWireRequestEnvelope? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class NativeDecompilerXPCClientAsyncRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var outcome: Result<NativeDecompilerWireReplyEnvelope, NativeDecompilerXPCClientFailure>?
    private var task: Task<Void, Never>?

    var isComplete: Bool {
        lock.withLock { outcome != nil }
    }

    func install(task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func finish(_ result: Result<NativeDecompilerWireReplyEnvelope, NativeDecompilerXPCClientFailure>) {
        let shouldSignal = lock.withLock { () -> Bool in
            guard outcome == nil else { return false }
            outcome = result
            return true
        }
        if shouldSignal { completed.signal() }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }

    func wait(
        timeout: TimeInterval = 1
    ) -> Result<NativeDecompilerWireReplyEnvelope, NativeDecompilerXPCClientFailure> {
        if !isComplete {
            precondition(completed.wait(timeout: .now() + timeout) == .success, "client request timed out")
        }
        return lock.withLock { outcome! }
    }

    func waitFailure(timeout: TimeInterval = 1) -> NativeDecompilerXPCClientFailure {
        switch wait(timeout: timeout) {
        case .success:
            preconditionFailure("expected request failure")
        case .failure(let failure):
            return failure
        }
    }
}

private func startRequest(
    client: NativeDecompilerXPCClient,
    payload: Data,
    elapsedTimeBudget: Duration? = nil,
    binding: String = "fixture-binding",
    requestBox: NativeDecompilerXPCClientRequestEnvelopeBox? = nil,
    requestID: UUID = UUID()
) -> NativeDecompilerXPCClientAsyncRequest {
    let request = NativeDecompilerXPCClientAsyncRequest()
    let envelope = makeRequestEnvelope(
        requestID: requestID,
        binding: binding,
        payload: payload
    )
    requestBox?.value = envelope
    let dispatchRequest = try! NativeDecompilerPreencodedDispatchRequest(
        projection: .init(request: envelope.body),
        requestID: requestID
    )
    let task = Task { [request] in
        do {
            request.finish(.success(try await client.decompile(
                request: dispatchRequest,
                elapsedTimeBudget: elapsedTimeBudget
            )))
        } catch let failure as NativeDecompilerXPCClientFailure {
            request.finish(.failure(failure))
        } catch {
            request.finish(.failure(.connectionUnavailable))
        }
    }
    request.install(task: task)
    return request
}

private func makeDispatchRequest(
    requestID: UUID = UUID(),
    binding: String,
    payload: Data = Data()
) throws -> NativeDecompilerPreencodedDispatchRequest {
    let envelope = makeRequestEnvelope(
        requestID: requestID,
        binding: binding,
        payload: payload
    )
    return try NativeDecompilerPreencodedDispatchRequest(
        projection: .init(request: envelope.body),
        requestID: requestID
    )
}

private final class NativeDecompilerXPCClientTestConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [NativeDecompilerXPCClientTestConnection]
    private var creations = 0

    init(_ connections: [NativeDecompilerXPCClientTestConnection]) {
        remaining = connections
    }

    var creationCount: Int { lock.withLock { creations } }

    func makeConnection() throws -> any NativeDecompilerXPCConnecting {
        try lock.withLock {
            guard !remaining.isEmpty else { throw NativeDecompilerXPCClientTestFactoryError.exhausted }
            creations += 1
            return remaining.removeFirst()
        }
    }
}

private enum NativeDecompilerXPCClientTestFactoryError: Error {
    case exhausted
}

private final class NativeDecompilerXPCClientTestConnection: NativeDecompilerXPCConnecting, @unchecked Sendable {
    struct Call: Equatable {
        let requestID: UUID
        let payload: Data
    }

    private let lock = NSLock()
    private var handler: (@Sendable (NativeDecompilerXPCConnectionEvent) -> Void)?
    private var recordedCalls: [Call] = []
    private var replies: [UUID: [@Sendable (Data) -> Void]] = [:]
    private var cancellations: [UUID] = []
    private var resumes = 0
    private var invalidations = 0
    private let eventOnResume: NativeDecompilerXPCConnectionEvent?
    private let decompileReturnGate: NativeDecompilerXPCClientLifecycleGate?

    init(
        eventOnResume: NativeDecompilerXPCConnectionEvent? = nil,
        decompileReturnGate: NativeDecompilerXPCClientLifecycleGate? = nil
    ) {
        self.eventOnResume = eventOnResume
        self.decompileReturnGate = decompileReturnGate
    }

    var calls: [Call] { lock.withLock { recordedCalls } }
    var cancelledRequestIDs: [UUID] { lock.withLock { cancellations } }
    var resumeCount: Int { lock.withLock { resumes } }
    var invalidateCount: Int { lock.withLock { invalidations } }

    func setEventHandler(_ handler: @escaping @Sendable (NativeDecompilerXPCConnectionEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    func resume() {
        let eventAndHandler = lock.withLock {
            let isFirstResume = resumes == 0
            if isFirstResume { resumes = 1 }
            return isFirstResume ? (eventOnResume, handler) : (nil, nil)
        }
        if let event = eventAndHandler.0 {
            eventAndHandler.1?(event)
        }
    }

    func decompile(
        requestID: UUID,
        payload: Data,
        reply: @escaping @Sendable (Data) -> Void
    ) {
        lock.withLock {
            recordedCalls.append(.init(requestID: requestID, payload: payload))
            replies[requestID, default: []].append(reply)
        }
        decompileReturnGate?.enterAndWait()
    }

    func cancel(requestID: UUID) {
        lock.withLock { cancellations.append(requestID) }
    }

    func invalidate() {
        lock.withLock { invalidations += 1 }
    }

    func reply(to requestID: UUID, with data: Data, index: Int = 0) {
        let callback = lock.withLock { replies[requestID]?[safe: index] }
        callback?(data)
    }

    func reply(
        to requestID: UUID,
        with envelope: NativeDecompilerWireReplyEnvelope,
        index: Int = 0
    ) {
        let data = try! NativeDecompilerWireCodec().encodeReply(
            envelope,
            matching: envelope.requestID
        )
        reply(to: requestID, with: data, index: index)
    }

    func emit(_ event: NativeDecompilerXPCConnectionEvent) {
        let callback = lock.withLock { handler }
        callback?(event)
    }

    func waitForCall(timeout: TimeInterval = 1) -> Call? {
        waitForValue(timeout: timeout) { self.calls.first }
    }

    func waitForCancel(requestID: UUID, timeout: TimeInterval = 1) -> Bool {
        waitForValue(timeout: timeout) {
            self.cancelledRequestIDs.contains(requestID) ? true : nil
        } ?? false
    }
}

private final class NativeDecompilerXPCClientManualTimer: NativeDecompilerXPCClientTimerScheduling,
    @unchecked Sendable
{
    private final class Token: NativeDecompilerXPCClientScheduledAction, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    private struct Entry {
        let deadlineNanoseconds: Int64
        let delay: Duration
        let token: Token
        let action: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var nowNanoseconds: Int64 = 0
    private var entries: [Entry] = []
    private var delays: [Duration] = []
    private let scheduled = DispatchSemaphore(value: 0)

    var scheduledDelays: [Duration] { lock.withLock { delays } }
    var activeActionCount: Int { lock.withLock { entries.filter { !$0.token.isCancelled }.count } }

    func schedule(
        after delay: Duration,
        action: @escaping @Sendable () -> Void
    ) -> any NativeDecompilerXPCClientScheduledAction {
        let token = Token()
        lock.withLock {
            delays.append(delay)
            entries.append(.init(
                deadlineNanoseconds: nowNanoseconds + nanoseconds(delay),
                delay: delay,
                token: token,
                action: action
            ))
        }
        scheduled.signal()
        return token
    }

    func waitForSchedule(timeout: TimeInterval = 1) -> Bool {
        scheduled.wait(timeout: .now() + timeout) == .success
    }

    func advance(by duration: Duration) {
        let actions: [@Sendable () -> Void] = lock.withLock {
            nowNanoseconds += nanoseconds(duration)
            var due: [@Sendable () -> Void] = []
            entries.removeAll { entry in
                guard entry.deadlineNanoseconds <= nowNanoseconds else { return false }
                if !entry.token.isCancelled { due.append(entry.action) }
                return true
            }
            return due
        }
        actions.forEach { $0() }
    }
}

private final class NativeDecompilerXPCClientLifecycleGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func enterAndWait() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 1) == .success
    }

    func release() {
        released.signal()
    }
}

private func nanoseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
}

private func waitForValue<T>(
    timeout: TimeInterval,
    value: () -> T?
) -> T? {
    let deadline = DispatchTime.now() + timeout
    repeat {
        if let value = value() { return value }
        Thread.sleep(forTimeInterval: 0.001)
    } while DispatchTime.now() < deadline
    return value()
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#if NATIVE_DECOMPILER_XPC_CLIENT_FOCUSED_MAIN
@main
private enum NativeDecompilerXPCClientFocusedMain {
    static func main() async {
        let tests = NativeDecompilerXPCClientTests()
        let cases: [(String, () async throws -> Void)] = [
            ("testClientGeneratesRequestIdentifierBeforeEncoding", tests.testClientGeneratesRequestIdentifierBeforeEncoding),
            ("testRequestEncodingFailureIsStableAndDoesNotCreateConnection", { tests.testRequestEncodingFailureIsStableAndDoesNotCreateConnection() }),
            ("testProxyErrorClassifierPreservesFoundationLifecycleCategories", { tests.testProxyErrorClassifierPreservesFoundationLifecycleCategories() }),
            ("testProxyErrorClassifierUsesConservativeCategoryForUnknownErrors", { tests.testProxyErrorClassifierUsesConservativeCategoryForUnknownErrors() }),
            ("testCanonicalFailureReplyReturnsDecodedEnvelopeExactlyOnce", tests.testCanonicalFailureReplyReturnsDecodedEnvelopeExactlyOnce),
            ("testCanonicalCodecAcceptsLegitimateFailureEnvelope", tests.testCanonicalCodecAcceptsLegitimateFailureEnvelope),
            ("testOversizeRequestFailsBeforeCreatingAConnection", { tests.testOversizeRequestFailsBeforeCreatingAConnection() }),
            ("testOversizeResponseFailsWithoutPublishingOrDoubleCompleting", tests.testOversizeResponseFailsWithoutPublishingOrDoubleCompleting),
            ("testMalformedReplyFailsClosedWithoutLeakingPayloadText", tests.testMalformedReplyFailsClosedWithoutLeakingPayloadText),
            ("testMismatchedReplyIdentifierFailsClosed", tests.testMismatchedReplyIdentifierFailsClosed),
            ("testCanonicalCodecRejectsSuccessfulReplyBoundToDifferentRequest", tests.testCanonicalCodecRejectsSuccessfulReplyBoundToDifferentRequest),
            ("testCanonicalCodecRejectsTopLevelPlausibleSemanticallyMalformedSuccess", tests.testCanonicalCodecRejectsTopLevelPlausibleSemanticallyMalformedSuccess),
            ("testCanonicalCodecPublishesFullyDecodedSuccessfulReply", tests.testCanonicalCodecPublishesFullyDecodedSuccessfulReply),
            ("testCallerCancellationSendsOneCancelAndSuppressesReplyDuringGrace", tests.testCallerCancellationSendsOneCancelAndSuppressesReplyDuringGrace),
            ("testCallerCancellationWinsOverOversizeReplyDuringGrace", tests.testCallerCancellationWinsOverOversizeReplyDuringGrace),
            ("testCancellationRecordedDuringReplyDecodeWinsTerminalArbitration", tests.testCancellationRecordedDuringReplyDecodeWinsTerminalArbitration),
            ("testDefaultWatchdogUsesFifteenSecondMonotonicDeadline", tests.testDefaultWatchdogUsesFifteenSecondMonotonicDeadline),
            ("testWatchdogClampsToElapsedBudgetThenInvalidatesAfterGrace", tests.testWatchdogClampsToElapsedBudgetThenInvalidatesAfterGrace),
            ("testInterruptionFailsPendingRequestWithoutAutomaticRetry", tests.testInterruptionFailsPendingRequestWithoutAutomaticRetry),
            ("testSynchronousInterruptionDuringResumeFailsWithoutDispatching", { tests.testSynchronousInterruptionDuringResumeFailsWithoutDispatching() }),
            ("testInvalidationHasDistinctTerminalCategory", tests.testInvalidationHasDistinctTerminalCategory),
            ("testFoundationLifecycleMapsRemoteExitOrCrashToInterruption", { tests.testFoundationLifecycleMapsRemoteExitOrCrashToInterruption() }),
            ("testUnknownProxyFailureUsesConservativeTerminalCategory", tests.testUnknownProxyFailureUsesConservativeTerminalCategory),
            ("testInterruptionCleansUpAndRelaunchesWithFreshGeneration", tests.testInterruptionCleansUpAndRelaunchesWithFreshGeneration),
            ("testStaleGenerationEventCannotRetireReplacementConnection", tests.testStaleGenerationEventCannotRetireReplacementConnection),
            ("testLifecycleHandlerReportsOnlyRetiredCurrentGenerations", tests.testLifecycleHandlerReportsOnlyRetiredCurrentGenerations),
            ("testTerminalShutdownInvalidatesCurrentConnectionAndRejectsReconnection", tests.testTerminalShutdownInvalidatesCurrentConnectionAndRejectsReconnection),
            ("testLifecycleFenceClosesBeforeInterruptedRequestSettles", tests.testLifecycleFenceClosesBeforeInterruptedRequestSettles),
            ("testConcurrentReplyAndInvalidationCompleteExactlyOnce", tests.testConcurrentReplyAndInvalidationCompleteExactlyOnce),
            ("testConcurrentProxyAndLifecycleInterruptionUseSameFailure", tests.testConcurrentProxyAndLifecycleInterruptionUseSameFailure),
            ("testEveryClientFailureUsesBoundedStableSanitizedText", { tests.testEveryClientFailureUsesBoundedStableSanitizedText() })
        ]
        for (name, test) in cases {
            let failuresBefore = NativeDecompilerXPCClientFocusedTestState.shared.failureCount
            do {
                try await test()
            } catch {
                NativeDecompilerXPCClientFocusedTestState.shared.record(
                    "uncaught test error",
                    file: #filePath,
                    line: #line
                )
            }
            if NativeDecompilerXPCClientFocusedTestState.shared.failureCount == failuresBefore {
                print("PASS: \(name)")
            } else {
                print("FAIL: \(name)")
            }
        }
        let failures = NativeDecompilerXPCClientFocusedTestState.shared.failureCount
        print("Executed \(cases.count) tests with \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
#endif
