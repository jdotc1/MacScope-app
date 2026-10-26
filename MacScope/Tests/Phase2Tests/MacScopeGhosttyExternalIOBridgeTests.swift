import Foundation
import XCTest

@testable import MacScope

final class MacScopeGhosttyExternalIOBridgeTests: XCTestCase {
    func testWriteCallbackCopiesBytesAndNeverWaitsForDelivery() {
        let handlerStarted = expectation(description: "handler started asynchronously")
        let delivered = expectation(description: "copied bytes delivered")
        let releaseHandler = DispatchSemaphore(value: 0)
        let recorder = WorkRecorder()
        let bridge = makeBridge { work in
            handlerStarted.fulfill()
            releaseHandler.wait()
            recorder.append(work)
            delivered.fulfill()
        }

        var callerStorage: [UInt8] = [0x41, 0x00, 0xFF, 0x42]
        let admission = callerStorage.withUnsafeBytes {
            bridge.callbackBox.copyWrite($0.baseAddress, count: $0.count)
        }

        // This line is reachable while delivery is deliberately blocked, proving there is no
        // actor/store/XPC-style synchronous reentrancy on the callback stack.
        XCTAssertEqual(admission, .accepted)
        wait(for: [handlerStarted], timeout: 1)
        callerStorage = [0x58, 0x58, 0x58, 0x58]
        releaseHandler.signal()
        wait(for: [delivered], timeout: 1)

        guard case let .write(generation, bytes) = recorder.values.first else {
            return XCTFail("expected one write")
        }
        XCTAssertEqual(generation, fixtureGeneration)
        XCTAssertEqual(bytes, Data([0x41, 0x00, 0xFF, 0x42]))
    }

    func testBoundedQueueBackpressuresWithoutDiscardingAcceptedWork() {
        let firstStarted = expectation(description: "first work started")
        let twoDelivered = expectation(description: "accepted work delivered")
        twoDelivered.expectedFulfillmentCount = 2
        let releaseFirst = DispatchSemaphore(value: 0)
        let recorder = WorkRecorder()
        let diagnostics = MacScopeGhosttySurfaceDiagnostics()
        let bridge = makeBridge(
            limits: .init(
                maximumWriteByteCount: 8,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            ),
            diagnostics: diagnostics
        ) { work in
            let position = recorder.append(work)
            if position == 1 {
                firstStarted.fulfill()
                releaseFirst.wait()
            }
            twoDelivered.fulfill()
        }

        XCTAssertEqual(Self.write([0x31], to: bridge.callbackBox), .accepted)
        wait(for: [firstStarted], timeout: 1)
        XCTAssertEqual(Self.write([0x32], to: bridge.callbackBox), .accepted)
        XCTAssertEqual(Self.write([0x33], to: bridge.callbackBox), .backpressured)
        XCTAssertEqual(bridge.snapshot().pendingWorkCount, 1)

        releaseFirst.signal()
        wait(for: [twoDelivered], timeout: 1)
        XCTAssertEqual(recorder.writeBytes, [Data([0x31]), Data([0x32])])
        XCTAssertTrue(diagnostics.snapshot().entries.contains {
            $0.event == .callbackRejected(.write, .queueFull)
        })
    }

    func testRetirementWaitsForActiveDeliveryLeaseAndClosesLateCallbacks() {
        let handlerEntered = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let retirementStarted = DispatchSemaphore(value: 0)
        let retirementFinished = DispatchSemaphore(value: 0)
        let recorder = WorkRecorder()
        let retirementResults = BoolRecorder()
        let diagnostics = MacScopeGhosttySurfaceDiagnostics()
        let generation = fixtureGeneration
        let bridge = makeBridge(diagnostics: diagnostics) { work in
            handlerEntered.signal()
            releaseHandler.wait()
            recorder.append(work)
        }

        XCTAssertEqual(Self.write([0x41], to: bridge.callbackBox), .accepted)
        XCTAssertEqual(handlerEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            retirementStarted.signal()
            retirementResults.append(bridge.retire(generation: generation))
            retirementFinished.signal()
        }
        XCTAssertEqual(retirementStarted.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(Self.waitUntil(timeout: 1) {
            bridge.snapshot().lifecycle == .retired
        })
        XCTAssertFalse(diagnostics.snapshot().entries.contains {
            $0.event == .bridgeRetired(cancelledWorkCount: 0, cancelledByteCount: 0)
        })
        XCTAssertEqual(
            retirementFinished.wait(timeout: .now() + 0.05),
            .timedOut,
            "retirement returned while an older delivery lease still owned the handler"
        )

        releaseHandler.signal()
        XCTAssertEqual(retirementFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(retirementResults.values, [true])
        XCTAssertEqual(recorder.writeBytes, [Data([0x41])])
        XCTAssertEqual(diagnostics.snapshot().entries.filter {
            $0.event == .bridgeRetired(cancelledWorkCount: 0, cancelledByteCount: 0)
        }.count, 1)
        XCTAssertEqual(Self.write([0x42], to: bridge.callbackBox), .closed)
        XCTAssertEqual(recorder.writeBytes, [Data([0x41])])
    }

    func testTransientHealthRearmsOnceWhileItsHandlerIsActive() {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let delivered = DispatchSemaphore(value: 0)
        let recorder = WorkRecorder()
        let bridge = makeBridge { work in
            let position = recorder.append(work)
            if position == 1 {
                firstStarted.signal()
                releaseFirst.wait()
            }
            delivered.signal()
        }

        XCTAssertEqual(bridge.callbackBox.reportHealth(.feedReady, detail: 1), .accepted)
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(bridge.callbackBox.reportHealth(.feedReady, detail: 2), .accepted)
        XCTAssertEqual(bridge.callbackBox.reportHealth(.feedReady, detail: 3), .accepted)
        XCTAssertEqual(bridge.snapshot().pendingWorkCount, 1)

        releaseFirst.signal()
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(recorder.values, [
            .health(generation: fixtureGeneration, event: .feedReady, detail: 1),
            .health(generation: fixtureGeneration, event: .feedReady, detail: 3),
        ])
    }

    func testRetireWinsQueuedControlWorkAndReplacementCannotReceiveOldGeneration() {
        let deliveryQueue = DispatchQueue(
            label: "org.macscope.app.tests.external-io.retire-wins"
        )
        deliveryQueue.suspend()
        var didResumeQueue = false
        defer {
            if !didResumeQueue {
                deliveryQueue.resume()
            }
        }

        let diagnostics = MacScopeGhosttySurfaceDiagnostics()
        let router = GenerationRouter(destination: fixtureGeneration)
        let oldBridge = makeBridge(
            limits: .init(
                maximumWriteByteCount: 8,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            ),
            diagnostics: diagnostics,
            deliveryQueue: deliveryQueue
        ) { router.route($0) }
        let retainedOldBox = oldBridge.callbackBox

        XCTAssertEqual(Self.write([0x41], to: retainedOldBox), .accepted)
        XCTAssertEqual(
            retainedOldBox.reportHealth(.outputOverflow, detail: 4_096),
            .accepted
        )
        XCTAssertEqual(
            retainedOldBox.reportHealth(.outputOverflow, detail: 8_192),
            .accepted,
            "a duplicate terminal edge should coalesce without growing the queue"
        )
        XCTAssertEqual(retainedOldBox.requestClose(.hostExited), .accepted)
        XCTAssertEqual(oldBridge.snapshot().pendingWorkCount, 3)

        XCTAssertTrue(oldBridge.retire(generation: fixtureGeneration))
        XCTAssertFalse(oldBridge.retire(generation: fixtureGeneration))
        oldBridge.invalidateCallbacks()
        oldBridge.invalidateCallbacks()
        XCTAssertEqual(oldBridge.snapshot().pendingWorkCount, 0)

        let lifecycleEvents = diagnostics.snapshot().entries.map(\.event)
        XCTAssertEqual(lifecycleEvents.filter {
            $0 == .bridgeRetired(cancelledWorkCount: 3, cancelledByteCount: 1)
        }.count, 1)
        XCTAssertEqual(lifecycleEvents.filter {
            $0 == .callbacksInvalidated(cancelledWorkCount: 0, cancelledByteCount: 0)
        }.count, 1)

        let replacementGeneration = MacScopeGhosttySurfaceGeneration(
            sessionID: fixtureGeneration.sessionID,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            generation: fixtureGeneration.generation + 1
        )
        router.install(destination: replacementGeneration)
        let replacementDelivered = DispatchSemaphore(value: 0)
        let replacementBridge = MacScopeGhosttyExternalIOBridge(
            generation: replacementGeneration
        ) { work in
            router.route(work)
            replacementDelivered.signal()
        }
        XCTAssertEqual(Self.write([0x52], to: replacementBridge.callbackBox), .accepted)
        XCTAssertEqual(replacementDelivered.wait(timeout: .now() + 1), .success)

        deliveryQueue.resume()
        didResumeQueue = true
        deliveryQueue.sync {}

        XCTAssertEqual(router.values, [
            .init(destination: replacementGeneration, workGeneration: replacementGeneration),
        ])
        XCTAssertEqual(Self.write([0x53], to: retainedOldBox), .closed)
    }

    func testSaturationRejectsBeforeCopyAndPreservesFinalControlOrdering() {
        let handlerStarted = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let recorder = WorkRecorder()
        let diagnostics = MacScopeGhosttySurfaceDiagnostics()
        let bridge = makeBridge(
            limits: .init(
                maximumWriteByteCount: 8,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            ),
            diagnostics: diagnostics
        ) { work in
            let position = recorder.append(work)
            delivered.signal()
            if position == 1 {
                handlerStarted.signal()
                releaseHandler.wait()
            }
        }

        XCTAssertEqual(Self.write([0x31], to: bridge.callbackBox), .accepted)
        XCTAssertEqual(handlerStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(Self.write([0x32], to: bridge.callbackBox), .accepted)

        // This address is intentionally unreadable. A saturated bridge must reject it from the
        // capacity ledger before Data attempts to dereference or copy the payload.
        let unreadable = UnsafeRawPointer(bitPattern: 0x1)!
        XCTAssertEqual(bridge.callbackBox.copyWrite(unreadable, count: 1), .backpressured)
        XCTAssertEqual(bridge.callbackBox.copyWrite(nil, count: 1), .invalid)
        XCTAssertEqual(bridge.callbackBox.copyWrite(unreadable, count: 9), .invalid)
        XCTAssertEqual(bridge.callbackBox.copyWrite(nil, count: 0), .accepted)

        XCTAssertEqual(
            bridge.callbackBox.reportHealth(.outputOverflow, detail: 4_096),
            .accepted
        )
        XCTAssertEqual(
            bridge.callbackBox.reportHealth(.outputOverflow, detail: 8_192),
            .accepted
        )
        XCTAssertEqual(bridge.callbackBox.reportHealth(.feedReady, detail: 1_048_576), .accepted)
        XCTAssertEqual(bridge.callbackBox.reportHealth(.outputBackpressured, detail: 64), .accepted)
        XCTAssertEqual(bridge.callbackBox.reportHealth(.outputSuppressed, detail: 17), .accepted)
        XCTAssertEqual(bridge.callbackBox.requestClose(.hostExited), .accepted)
        XCTAssertEqual(bridge.callbackBox.requestClose(.hostClosed), .accepted)
        XCTAssertEqual(bridge.callbackBox.copyWrite(unreadable, count: 1), .closed)
        XCTAssertEqual(bridge.callbackBox.copyWrite(nil, count: 0), .closed)
        XCTAssertEqual(
            bridge.callbackBox.proposeResize(.init(
                columns: 80,
                rows: 24,
                pixelWidth: 800,
                pixelHeight: 600
            )),
            .closed
        )
        XCTAssertEqual(bridge.callbackBox.reportHealth(.feedReady, detail: 2_097_152), .closed)

        XCTAssertEqual(bridge.snapshot().pendingWorkCount, 6)
        XCTAssertEqual(bridge.snapshot().pendingByteCount, 1)
        releaseHandler.signal()
        for _ in 0..<7 {
            XCTAssertEqual(delivered.wait(timeout: .now() + 1), .success)
        }

        let values = recorder.values
        XCTAssertEqual(values.count, 7)
        XCTAssertEqual(values[0], .write(generation: fixtureGeneration, bytes: Data([0x31])))
        XCTAssertEqual(values[1], .write(generation: fixtureGeneration, bytes: Data([0x32])))
        XCTAssertEqual(
            values[2],
            .health(generation: fixtureGeneration, event: .outputOverflow, detail: 4_096)
        )
        XCTAssertEqual(
            values[3],
            .health(generation: fixtureGeneration, event: .feedReady, detail: 1_048_576)
        )
        XCTAssertEqual(
            values[4],
            .health(generation: fixtureGeneration, event: .outputBackpressured, detail: 64)
        )
        XCTAssertEqual(
            values[5],
            .health(generation: fixtureGeneration, event: .outputSuppressed, detail: 17)
        )
        XCTAssertEqual(values[6], .close(generation: fixtureGeneration, reason: .hostExited))
        XCTAssertEqual(values.filter {
            if case .health(_, .outputOverflow, _) = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(values.filter {
            if case .close = $0 { return true }
            return false
        }.count, 1)

        let diagnosticEvents = diagnostics.snapshot().entries.map(\.event)
        XCTAssertEqual(diagnosticEvents.filter {
            $0 == .callbackRejected(.write, .queueFull)
        }.count, 1)
        XCTAssertEqual(diagnosticEvents.filter {
            $0 == .callbackRejected(.write, .invalidPayload)
        }.count, 2)
    }

    func testOnlyExactGenerationCanRetireAndOldCallbacksFailClosed() {
        let recorder = WorkRecorder()
        let bridge = makeBridge { recorder.append($0) }

        let staleGeneration = MacScopeGhosttySurfaceGeneration(
            sessionID: fixtureGeneration.sessionID,
            requestID: fixtureGeneration.requestID,
            generation: fixtureGeneration.generation + 1
        )
        XCTAssertFalse(bridge.retire(generation: staleGeneration))
        XCTAssertEqual(bridge.snapshot().lifecycle, .active)
        XCTAssertTrue(bridge.retire(generation: fixtureGeneration))
        XCTAssertEqual(bridge.snapshot().lifecycle, .retired)
        XCTAssertEqual(Self.write([0x41], to: bridge.callbackBox), .closed)

        bridge.invalidateCallbacks()
        XCTAssertEqual(bridge.snapshot().lifecycle, .callbacksInvalidated)
        XCTAssertEqual(
            bridge.callbackBox.requestClose(.surfaceRequest),
            .closed
        )
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testInvalidAndOversizedCallbacksFailBeforeAllocationOrDelivery() {
        let recorder = WorkRecorder()
        let delivered = expectation(description: "valid callback after invalid payloads")
        let bridge = makeBridge(
            limits: .init(
                maximumWriteByteCount: 2,
                maximumPendingWorkCount: 2,
                maximumPendingByteCount: 2,
                maximumGridDimension: 100,
                maximumPixelDimension: 1_000
            )
        ) {
            recorder.append($0)
            delivered.fulfill()
        }

        XCTAssertEqual(bridge.callbackBox.copyWrite(nil, count: -1), .invalid)
        XCTAssertEqual(bridge.callbackBox.copyWrite(nil, count: 1), .invalid)
        XCTAssertEqual(Self.write([0x01, 0x02, 0x03], to: bridge.callbackBox), .invalid)
        XCTAssertEqual(
            bridge.callbackBox.proposeResize(.init(
                columns: 101,
                rows: 24,
                pixelWidth: 800,
                pixelHeight: 600
            )),
            .invalid
        )
        XCTAssertTrue(recorder.values.isEmpty)

        XCTAssertEqual(Self.write([0x01, 0x02], to: bridge.callbackBox), .accepted)
        wait(for: [delivered], timeout: 1)
        XCTAssertEqual(recorder.writeBytes, [Data([0x01, 0x02])])
    }

    func testConcurrentCallbacksRemainSafeWhileCloseRetiresAndInvalidatesBox() {
        let bridge = makeBridge(
            limits: .init(
                maximumWriteByteCount: 8,
                maximumPendingWorkCount: 8,
                maximumPendingByteCount: 8
            )
        ) { _ in }
        let box = bridge.callbackBox
        let results = AdmissionRecorder()
        let callbacks = DispatchGroup()

        for value in UInt8(0)..<64 {
            callbacks.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                results.append(Self.write([value], to: box))
                callbacks.leave()
            }
        }

        XCTAssertTrue(bridge.retire(generation: fixtureGeneration))
        bridge.invalidateCallbacks()
        XCTAssertEqual(callbacks.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(results.values.allSatisfy {
            $0 == .accepted || $0 == .backpressured || $0 == .closed
        })
        XCTAssertEqual(Self.write([0xFF], to: box), .closed)
    }

    func testInvalidationBreaksHandlerOwnershipCycleAndRetainedBoxFailsClosed() {
        var owner: BridgeOwner? = BridgeOwner(generation: fixtureGeneration)
        weak let weakOwner = owner
        weak let weakBridge = owner?.bridge
        let retainedBox = owner!.bridge!.callbackBox

        owner!.bridge!.retire(generation: fixtureGeneration)
        owner!.bridge!.invalidateCallbacks()
        owner = nil

        XCTAssertNil(weakOwner)
        XCTAssertNil(weakBridge)
        XCTAssertEqual(Self.write([0x41], to: retainedBox), .closed)
    }

    func testDiagnosticsAreBoundedAndAccountForEviction() {
        let diagnostics = MacScopeGhosttySurfaceDiagnostics(capacity: 2)
        let bridge = makeBridge(diagnostics: diagnostics) { _ in }

        XCTAssertEqual(bridge.callbackBox.copyWrite(nil, count: 1), .invalid)
        XCTAssertEqual(bridge.callbackBox.copyWrite(nil, count: 1), .invalid)
        XCTAssertEqual(bridge.callbackBox.copyWrite(nil, count: 1), .invalid)

        let snapshot = diagnostics.snapshot()
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.totalRecorded, 3)
        XCTAssertEqual(snapshot.evictedEntryCount, 1)
    }

    private let fixtureGeneration = MacScopeGhosttySurfaceGeneration(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
        generation: 7
    )

    private func makeBridge(
        limits: MacScopeGhosttyExternalIOBridge.Limits = .default,
        diagnostics: MacScopeGhosttySurfaceDiagnostics = MacScopeGhosttySurfaceDiagnostics(),
        deliveryQueue: DispatchQueue? = nil,
        handler: @escaping MacScopeGhosttyExternalIOBridge.Handler
    ) -> MacScopeGhosttyExternalIOBridge {
        MacScopeGhosttyExternalIOBridge(
            generation: fixtureGeneration,
            limits: limits,
            diagnostics: diagnostics,
            deliveryQueue: deliveryQueue,
            handler: handler
        )
    }

    private static func write(
        _ bytes: [UInt8],
        to box: MacScopeGhosttyExternalIOBridge.CallbackBox
    ) -> MacScopeGhosttyExternalIOBridge.Admission {
        bytes.withUnsafeBytes { box.copyWrite($0.baseAddress, count: $0.count) }
    }

    private static func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline
        return predicate()
    }
}

private final class WorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MacScopeGhosttyExternalIOBridge.Work] = []

    var values: [MacScopeGhosttyExternalIOBridge.Work] {
        lock.withLock { storage }
    }

    var writeBytes: [Data] {
        values.compactMap {
            guard case let .write(_, bytes) = $0 else { return nil }
            return bytes
        }
    }

    @discardableResult
    func append(_ work: MacScopeGhosttyExternalIOBridge.Work) -> Int {
        lock.withLock {
            storage.append(work)
            return storage.count
        }
    }
}

private final class AdmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MacScopeGhosttyExternalIOBridge.Admission] = []

    var values: [MacScopeGhosttyExternalIOBridge.Admission] {
        lock.withLock { storage }
    }

    func append(_ value: MacScopeGhosttyExternalIOBridge.Admission) {
        lock.withLock { storage.append(value) }
    }
}

private final class BoolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.withLock { storage }
    }

    func append(_ value: Bool) {
        lock.withLock { storage.append(value) }
    }
}

private final class GenerationRouter: @unchecked Sendable {
    struct Delivery: Equatable {
        let destination: MacScopeGhosttySurfaceGeneration
        let workGeneration: MacScopeGhosttySurfaceGeneration
    }

    private let lock = NSLock()
    private var destination: MacScopeGhosttySurfaceGeneration
    private var storage: [Delivery] = []

    init(destination: MacScopeGhosttySurfaceGeneration) {
        self.destination = destination
    }

    var values: [Delivery] {
        lock.withLock { storage }
    }

    func install(destination: MacScopeGhosttySurfaceGeneration) {
        lock.withLock { self.destination = destination }
    }

    func route(_ work: MacScopeGhosttyExternalIOBridge.Work) {
        let workGeneration: MacScopeGhosttySurfaceGeneration = switch work {
        case let .write(generation, _),
             let .resize(generation, _),
             let .close(generation, _),
             let .health(generation, _, _): generation
        }
        lock.withLock {
            storage.append(.init(
                destination: destination,
                workGeneration: workGeneration
            ))
        }
    }
}

private final class BridgeOwner: @unchecked Sendable {
    var bridge: MacScopeGhosttyExternalIOBridge?

    init(generation: MacScopeGhosttySurfaceGeneration) {
        bridge = MacScopeGhosttyExternalIOBridge(generation: generation) { [self] _ in
            withExtendedLifetime(self) {}
        }
    }
}
