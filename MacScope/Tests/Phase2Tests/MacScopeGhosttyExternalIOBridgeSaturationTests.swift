import Darwin
import Foundation

#if MACSCOPE_GHOSTTY_EXTERNAL_IO_BRIDGE_FOCUSED_MAIN
struct MacScopeGhosttySurfaceGeneration: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let generation: UInt64
}

@main
private enum MacScopeGhosttyExternalIOBridgeFocusedMain {
    static func main() {
        do {
            try MacScopeGhosttyExternalIOBridgeSaturationScenario.run()
            print("PASS: external I/O bridge saturation and retirement")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }
}
#else
import XCTest

@testable import MacScope

final class MacScopeGhosttyExternalIOBridgeSaturationTests: XCTestCase {
    func testSaturationPreservesControlEdgesAndRetirementFence() throws {
        try MacScopeGhosttyExternalIOBridgeSaturationScenario.run()
    }
}
#endif

private enum MacScopeGhosttyExternalIOBridgeSaturationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): message
        }
    }
}

private enum MacScopeGhosttyExternalIOBridgeSaturationScenario {
    private static let generation = MacScopeGhosttySurfaceGeneration(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000311")!,
        requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
        generation: 11
    )

    static func run() throws {
        try saturationPreservesControlEdges()
        try resizeUsesReservedLatestValueSlot()
        try activeResizeRetainsOneLatestFollowUp()
        try writeCapacityRecoveryRetriesExactlyOnce()
        try retirementCancelsPendingCapacityRecovery()
        try transientHealthRearmsOnceWhileActive()
        try closeIsTerminalBoundary()
        try activeLeaseMakesRetirementSynchronous()
        try reentrantRetirementDoesNotDeadlock()
        try retirementCancelsBeforeReplacement()
        try invalidPayloadsDoNotConsumeCapacity()
    }

    private static func resizeUsesReservedLatestValueSlot() throws {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let delivered = DispatchSemaphore(value: 0)
        let recorder = MacScopeGhosttyExternalIOBridgeFocusedRecorder()
        let bridge = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            limits: .init(
                maximumWriteByteCount: 1,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            )
        ) { work in
            let position = recorder.append(work)
            delivered.signal()
            if position == 1 {
                firstStarted.signal()
                releaseFirst.wait()
            }
        }

        try require(write([0x31], to: bridge.callbackBox) == .accepted, "first write rejected")
        try require(firstStarted.wait(timeout: .now() + 2) == .success, "first write did not start")
        try require(write([0x32], to: bridge.callbackBox) == .accepted, "ordinary slot did not fill")

        let firstResize = MacScopeGhosttyExternalIOBridge.ResizeProposal(
            columns: 80,
            rows: 24,
            pixelWidth: 800,
            pixelHeight: 600
        )
        let latestResize = MacScopeGhosttyExternalIOBridge.ResizeProposal(
            columns: 120,
            rows: 40,
            pixelWidth: 1_200,
            pixelHeight: 800
        )
        try require(
            bridge.callbackBox.proposeResize(firstResize) == .accepted,
            "resize was lost to ordinary saturation"
        )
        try require(
            bridge.callbackBox.reportHealth(.feedReady, detail: 1) == .accepted,
            "reserved health edge was rejected"
        )
        try require(
            bridge.callbackBox.proposeResize(latestResize) == .accepted,
            "latest resize did not coalesce"
        )
        try require(
            bridge.snapshot().pendingWorkCount == 3,
            "resize coalescing exceeded one pending reserved slot"
        )

        releaseFirst.signal()
        for _ in 0..<4 {
            try require(delivered.wait(timeout: .now() + 2) == .success, "resize work did not drain")
        }
        try require(recorder.values == [
            .write(generation: generation, bytes: Data([0x31])),
            .write(generation: generation, bytes: Data([0x32])),
            .health(generation: generation, event: .feedReady, detail: 1),
            .resize(generation: generation, proposal: latestResize),
        ], "latest resize was lost, duplicated, or delivered out of callback order")
        try require(bridge.retire(generation: generation), "resize bridge did not retire")
        bridge.invalidateCallbacks()
    }

    private static func activeResizeRetainsOneLatestFollowUp() throws {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let delivered = DispatchSemaphore(value: 0)
        let recorder = MacScopeGhosttyExternalIOBridgeFocusedRecorder()
        let bridge = MacScopeGhosttyExternalIOBridge(generation: generation) { work in
            let position = recorder.append(work)
            delivered.signal()
            if position == 1 {
                firstStarted.signal()
                releaseFirst.wait()
            }
        }
        let first = MacScopeGhosttyExternalIOBridge.ResizeProposal(
            columns: 80, rows: 24, pixelWidth: 800, pixelHeight: 600
        )
        let middle = MacScopeGhosttyExternalIOBridge.ResizeProposal(
            columns: 100, rows: 30, pixelWidth: 1_000, pixelHeight: 700
        )
        let latest = MacScopeGhosttyExternalIOBridge.ResizeProposal(
            columns: 120, rows: 40, pixelWidth: 1_200, pixelHeight: 800
        )

        try require(bridge.callbackBox.proposeResize(first) == .accepted, "first resize rejected")
        try require(firstStarted.wait(timeout: .now() + 2) == .success, "first resize did not start")
        try require(bridge.callbackBox.proposeResize(middle) == .accepted, "resize follow-up rejected")
        try require(bridge.callbackBox.proposeResize(latest) == .accepted, "latest resize rejected")
        try require(bridge.snapshot().pendingWorkCount == 1, "active resize accumulated follow-ups")

        releaseFirst.signal()
        for _ in 0..<2 {
            try require(delivered.wait(timeout: .now() + 2) == .success, "resize follow-up did not drain")
        }
        try require(recorder.values == [
            .resize(generation: generation, proposal: first),
            .resize(generation: generation, proposal: latest),
        ], "active resize did not retain exactly the latest follow-up")
        try require(bridge.retire(generation: generation), "active-resize bridge did not retire")
        bridge.invalidateCallbacks()
    }

    private static func writeCapacityRecoveryRetriesExactlyOnce() throws {
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let delivered = DispatchSemaphore(value: 0)
        let recorder = MacScopeGhosttyExternalIOBridgeFocusedRecorder()
        let admissions = MacScopeGhosttyExternalIOBridgeFocusedAdmissionRecorder()
        let recoveredGenerations = MacScopeGhosttyExternalIOBridgeFocusedGenerationRecorder()
        let holder = MacScopeGhosttyExternalIOBridgeFocusedHolder()
        let bridge = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            limits: .init(
                maximumWriteByteCount: 1,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            ),
            writeCapacityRecovered: { candidate in
                recoveredGenerations.append(candidate)
                admissions.append(holder.write([0x33]))
            }
        ) { work in
            let position = recorder.append(work)
            delivered.signal()
            if position == 1 {
                firstStarted.signal()
                releaseFirst.wait()
            }
        }
        holder.install(bridge)
        defer { holder.clear() }

        try require(write([0x31], to: bridge.callbackBox) == .accepted, "first write rejected")
        try require(firstStarted.wait(timeout: .now() + 2) == .success, "first write did not start")
        try require(write([0x32], to: bridge.callbackBox) == .accepted, "queued write rejected")
        try require(write([0x33], to: bridge.callbackBox) == .backpressured, "full bridge did not backpressure")

        releaseFirst.signal()
        for _ in 0..<3 {
            try require(delivered.wait(timeout: .now() + 2) == .success, "retried write did not drain")
        }
        try require(recoveredGenerations.values == [generation], "capacity recovery was not exact-generation/exact-once")
        try require(admissions.values == [.accepted], "reentrant capacity retry was not admitted")
        try require(recorder.values == [
            .write(generation: generation, bytes: Data([0x31])),
            .write(generation: generation, bytes: Data([0x32])),
            .write(generation: generation, bytes: Data([0x33])),
        ], "capacity recovery lost or reordered retained output")
        try require(bridge.retire(generation: generation), "capacity bridge did not retire")
        bridge.invalidateCallbacks()
    }

    private static func retirementCancelsPendingCapacityRecovery() throws {
        let deliveryQueue = DispatchQueue(
            label: "org.macscope.app.focused.external-io.capacity-retirement"
        )
        deliveryQueue.suspend()
        var didResume = false
        defer {
            if !didResume { deliveryQueue.resume() }
        }
        let recovered = MacScopeGhosttyExternalIOBridgeFocusedGenerationRecorder()
        let bridge = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            limits: .init(
                maximumWriteByteCount: 1,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            ),
            deliveryQueue: deliveryQueue,
            writeCapacityRecovered: { recovered.append($0) }
        ) { _ in }

        try require(write([0x41], to: bridge.callbackBox) == .accepted, "queued write rejected")
        try require(write([0x42], to: bridge.callbackBox) == .backpressured, "capacity episode missing")
        try require(bridge.retire(generation: generation), "capacity episode did not retire")
        bridge.invalidateCallbacks()
        deliveryQueue.resume()
        didResume = true
        deliveryQueue.sync {}
        try require(recovered.values.isEmpty, "capacity hook escaped retirement/invalidation")
    }

    private static func saturationPreservesControlEdges() throws {
        let handlerStarted = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        defer { releaseHandler.signal() }
        let delivered = DispatchSemaphore(value: 0)
        let recorder = MacScopeGhosttyExternalIOBridgeFocusedRecorder()
        let bridge = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            limits: .init(
                maximumWriteByteCount: 8,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            )
        ) { work in
            let position = recorder.append(work)
            delivered.signal()
            if position == 1 {
                handlerStarted.signal()
                releaseHandler.wait()
            }
        }

        try require(write([0x31], to: bridge.callbackBox) == .accepted, "first write rejected")
        try require(
            handlerStarted.wait(timeout: .now() + 2) == .success,
            "first delivery did not acquire its lease"
        )
        try require(write([0x32], to: bridge.callbackBox) == .accepted, "queued write rejected")

        let unreadable = UnsafeRawPointer(bitPattern: 0x1)!
        try require(
            bridge.callbackBox.copyWrite(unreadable, count: 1) == .backpressured,
            "saturated write was not rejected before copying"
        )
        try require(
            bridge.callbackBox.reportHealth(.outputOverflow, detail: 4_096) == .accepted,
            "overflow edge was lost to ordinary saturation"
        )
        try require(
            bridge.callbackBox.reportHealth(.outputOverflow, detail: 8_192) == .accepted,
            "duplicate overflow edge was not coalesced as accepted"
        )
        try require(
            bridge.callbackBox.reportHealth(.feedReady, detail: 1_048_576) == .accepted,
            "readiness edge was lost to ordinary saturation"
        )
        try require(
            bridge.callbackBox.requestClose(.hostExited) == .accepted,
            "final close was lost to ordinary saturation"
        )

        releaseHandler.signal()
        for _ in 0..<5 {
            try require(
                delivered.wait(timeout: .now() + 2) == .success,
                "accepted work did not drain"
            )
        }

        let expected: [MacScopeGhosttyExternalIOBridge.Work] = [
            .write(generation: generation, bytes: Data([0x31])),
            .write(generation: generation, bytes: Data([0x32])),
            .health(generation: generation, event: .outputOverflow, detail: 4_096),
            .health(generation: generation, event: .feedReady, detail: 1_048_576),
            .close(generation: generation, reason: .hostExited),
        ]
        try require(recorder.values == expected, "control/final-frame order changed")
        try require(bridge.retire(generation: generation), "exact generation did not retire")
        try require(
            write([0x33], to: bridge.callbackBox) == .closed,
            "late callback crossed the retirement fence"
        )
        bridge.invalidateCallbacks()
        try require(
            bridge.snapshot() == .init(
                lifecycle: .callbacksInvalidated,
                pendingWorkCount: 0,
                pendingByteCount: 0
            ),
            "retirement left pending work or bytes"
        )
    }

    private static func transientHealthRearmsOnceWhileActive() throws {
        let firstHandlerStarted = DispatchSemaphore(value: 0)
        let releaseFirstHandler = DispatchSemaphore(value: 0)
        defer { releaseFirstHandler.signal() }
        let delivered = DispatchSemaphore(value: 0)
        let recorder = MacScopeGhosttyExternalIOBridgeFocusedRecorder()
        let bridge = MacScopeGhosttyExternalIOBridge(generation: generation) { work in
            let position = recorder.append(work)
            delivered.signal()
            if position == 1 {
                firstHandlerStarted.signal()
                releaseFirstHandler.wait()
            }
        }

        try require(
            bridge.callbackBox.reportHealth(.feedReady, detail: 1) == .accepted,
            "initial readiness callback was rejected"
        )
        try require(
            firstHandlerStarted.wait(timeout: .now() + 2) == .success,
            "initial readiness callback did not acquire its delivery lease"
        )
        try require(
            bridge.callbackBox.reportHealth(.feedReady, detail: 2) == .accepted,
            "active readiness callback did not arm a follow-up"
        )
        try require(
            bridge.callbackBox.reportHealth(.feedReady, detail: 3) == .accepted,
            "duplicate readiness follow-up was not coalesced"
        )
        try require(
            bridge.snapshot().pendingWorkCount == 1,
            "readiness follow-up grew beyond one reserved slot"
        )

        releaseFirstHandler.signal()
        for _ in 0..<2 {
            try require(
                delivered.wait(timeout: .now() + 2) == .success,
                "readiness follow-up did not drain"
            )
        }
        try require(recorder.values == [
            .health(generation: generation, event: .feedReady, detail: 1),
            .health(generation: generation, event: .feedReady, detail: 3),
        ], "readiness follow-up was lost, duplicated, or retained stale detail")
        try require(bridge.retire(generation: generation), "readiness bridge did not retire")
        bridge.invalidateCallbacks()
    }

    private static func closeIsTerminalBoundary() throws {
        let delivered = DispatchSemaphore(value: 0)
        let recorder = MacScopeGhosttyExternalIOBridgeFocusedRecorder()
        let bridge = MacScopeGhosttyExternalIOBridge(generation: generation) { work in
            recorder.append(work)
            delivered.signal()
        }
        let unreadable = UnsafeRawPointer(bitPattern: 0x1)!

        try require(
            bridge.callbackBox.requestClose(.hostExited) == .accepted,
            "terminal close was rejected"
        )
        try require(
            bridge.callbackBox.requestClose(.hostClosed) == .accepted,
            "duplicate close did not coalesce as accepted"
        )
        try require(
            bridge.callbackBox.copyWrite(unreadable, count: 1) == .closed,
            "post-close write reached payload copying"
        )
        try require(
            bridge.callbackBox.copyWrite(nil, count: 0) == .closed,
            "post-close no-op write was admitted"
        )
        try require(
            bridge.callbackBox.proposeResize(.init(
                columns: 80,
                rows: 24,
                pixelWidth: 800,
                pixelHeight: 600
            )) == .closed,
            "post-close resize was admitted"
        )
        try require(
            bridge.callbackBox.reportHealth(.feedReady, detail: 1) == .closed,
            "post-close health callback was admitted"
        )
        try require(
            delivered.wait(timeout: .now() + 2) == .success,
            "terminal close did not deliver"
        )
        try require(
            delivered.wait(timeout: .now() + 0.05) == .timedOut,
            "post-close work reached the handler"
        )
        try require(
            recorder.values == [.close(generation: generation, reason: .hostExited)],
            "close was not the final delivered frame"
        )
        try require(bridge.retire(generation: generation), "closed bridge did not retire")
        bridge.invalidateCallbacks()
    }

    private static func activeLeaseMakesRetirementSynchronous() throws {
        let diagnostics = MacScopeGhosttySurfaceDiagnostics()
        let handlerEntered = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        defer { releaseHandler.signal() }
        let retirementStarted = DispatchSemaphore(value: 0)
        let retirementFinished = DispatchSemaphore(value: 0)
        let retirementResults = MacScopeGhosttyExternalIOBridgeFocusedBoolRecorder()
        let recorder = MacScopeGhosttyExternalIOBridgeFocusedRecorder()
        let bridge = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            diagnostics: diagnostics
        ) { work in
            handlerEntered.signal()
            releaseHandler.wait()
            recorder.append(work)
        }

        try require(write([0x41], to: bridge.callbackBox) == .accepted, "lease write rejected")
        try require(
            handlerEntered.wait(timeout: .now() + 2) == .success,
            "delivery lease was not acquired"
        )

        DispatchQueue.global(qos: .userInitiated).async {
            retirementStarted.signal()
            retirementResults.append(bridge.retire(generation: generation))
            retirementFinished.signal()
        }
        try require(
            retirementStarted.wait(timeout: .now() + 2) == .success,
            "retirement task did not start"
        )
        try require(
            waitUntil(timeout: 2) {
                bridge.snapshot().lifecycle == .retired
            },
            "retirement never reached the delivery-lease fence"
        )
        try require(
            !diagnostics.snapshot().entries.contains {
                $0.event == .bridgeRetired(cancelledWorkCount: 0, cancelledByteCount: 0)
            },
            "retirement health was emitted before its delivery lease quiesced"
        )
        try require(
            retirementFinished.wait(timeout: .now() + 0.05) == .timedOut,
            "retirement returned before its older delivery lease finished"
        )

        releaseHandler.signal()
        try require(
            retirementFinished.wait(timeout: .now() + 2) == .success,
            "retirement did not finish after the delivery lease released"
        )
        try require(retirementResults.values == [true], "exact retirement did not succeed once")
        try require(
            diagnostics.snapshot().entries.filter {
                $0.event == .bridgeRetired(cancelledWorkCount: 0, cancelledByteCount: 0)
            }.count == 1,
            "retirement health was not emitted exactly once after the lease fence"
        )
        try require(
            recorder.values == [.write(generation: generation, bytes: Data([0x41]))],
            "the leased work was lost or duplicated"
        )
        try require(
            write([0x42], to: bridge.callbackBox) == .closed,
            "a callback invoked after synchronous retirement returned"
        )
    }

    private static func retirementCancelsBeforeReplacement() throws {
        let oldDeliveryQueue = DispatchQueue(
            label: "org.macscope.app.focused.external-io.retire-wins"
        )
        oldDeliveryQueue.suspend()
        var didResumeQueue = false
        defer {
            if !didResumeQueue {
                oldDeliveryQueue.resume()
            }
        }

        let diagnostics = MacScopeGhosttySurfaceDiagnostics()
        let router = MacScopeGhosttyExternalIOBridgeFocusedRouter(destination: generation)
        let oldBridge = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            limits: .init(
                maximumWriteByteCount: 8,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            ),
            diagnostics: diagnostics,
            deliveryQueue: oldDeliveryQueue
        ) { router.route($0) }
        let retainedOldBox = oldBridge.callbackBox

        try require(write([0x51], to: retainedOldBox) == .accepted, "old write rejected")
        try require(
            retainedOldBox.reportHealth(.outputOverflow, detail: 4_096) == .accepted,
            "old overflow edge rejected"
        )
        try require(
            retainedOldBox.reportHealth(.outputOverflow, detail: 8_192) == .accepted,
            "duplicate old overflow edge did not coalesce"
        )
        try require(
            retainedOldBox.requestClose(.hostExited) == .accepted,
            "old close rejected"
        )
        try require(oldBridge.snapshot().pendingWorkCount == 3, "control coalescing was unbounded")
        try require(oldBridge.retire(generation: generation), "old generation did not retire")
        try require(!oldBridge.retire(generation: generation), "old generation retired twice")
        oldBridge.invalidateCallbacks()
        oldBridge.invalidateCallbacks()

        let lifecycleEvents = diagnostics.snapshot().entries.map(\.event)
        try require(
            lifecycleEvents.filter {
                $0 == .bridgeRetired(cancelledWorkCount: 3, cancelledByteCount: 1)
            }.count == 1,
            "retirement cancellation accounting was not exact"
        )
        try require(
            lifecycleEvents.filter {
                $0 == .callbacksInvalidated(cancelledWorkCount: 0, cancelledByteCount: 0)
            }.count == 1,
            "callback invalidation was not idempotent"
        )

        let replacement = MacScopeGhosttySurfaceGeneration(
            sessionID: generation.sessionID,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000313")!,
            generation: generation.generation + 1
        )
        router.install(destination: replacement)
        let replacementDelivered = DispatchSemaphore(value: 0)
        let replacementBridge = MacScopeGhosttyExternalIOBridge(generation: replacement) { work in
            router.route(work)
            replacementDelivered.signal()
        }
        try require(
            write([0x52], to: replacementBridge.callbackBox) == .accepted,
            "replacement write rejected"
        )
        try require(
            replacementDelivered.wait(timeout: .now() + 2) == .success,
            "replacement work did not deliver"
        )

        oldDeliveryQueue.resume()
        didResumeQueue = true
        oldDeliveryQueue.sync {}
        try require(
            router.values == [.init(destination: replacement, workGeneration: replacement)],
            "retired work crossed into the replacement route"
        )
        try require(
            write([0x53], to: retainedOldBox) == .closed,
            "retained old callback box did not fail closed"
        )
    }

    private static func reentrantRetirementDoesNotDeadlock() throws {
        let holder = MacScopeGhosttyExternalIOBridgeFocusedHolder()
        let retirementResults = MacScopeGhosttyExternalIOBridgeFocusedBoolRecorder()
        let selfRetired = DispatchSemaphore(value: 0)
        let releaseHandlerTail = DispatchSemaphore(value: 0)
        defer {
            releaseHandlerTail.signal()
            holder.clear()
        }
        let externalRetirementStarted = DispatchSemaphore(value: 0)
        let externalRetirementFinished = DispatchSemaphore(value: 0)
        let handlerFinished = DispatchSemaphore(value: 0)
        let bridge = MacScopeGhosttyExternalIOBridge(generation: generation) { _ in
            retirementResults.append(holder.retire(generation: generation))
            selfRetired.signal()
            releaseHandlerTail.wait()
            handlerFinished.signal()
        }
        holder.install(bridge)

        try require(
            write([0x61], to: bridge.callbackBox) == .accepted,
            "reentrant-retirement write rejected"
        )
        try require(
            selfRetired.wait(timeout: .now() + 2) == .success,
            "handler deadlocked while initiating retirement of its own lease"
        )
        try require(retirementResults.values == [true], "reentrant retirement did not succeed")

        DispatchQueue.global(qos: .userInitiated).async {
            externalRetirementStarted.signal()
            retirementResults.append(bridge.retire(generation: generation))
            externalRetirementFinished.signal()
        }
        try require(
            externalRetirementStarted.wait(timeout: .now() + 2) == .success,
            "external retirement task did not start"
        )
        try require(
            externalRetirementFinished.wait(timeout: .now() + 0.05) == .timedOut,
            "a second retirement caller crossed the active reentrant lease"
        )

        releaseHandlerTail.signal()
        try require(
            handlerFinished.wait(timeout: .now() + 2) == .success,
            "reentrantly retired handler did not finish"
        )
        try require(
            externalRetirementFinished.wait(timeout: .now() + 2) == .success,
            "external retirement did not complete after the handler tail finished"
        )
        try require(
            retirementResults.values == [true, false],
            "retirement ownership or synchronous fencing changed"
        )
        try require(
            write([0x62], to: bridge.callbackBox) == .closed,
            "reentrantly retired bridge admitted a later callback"
        )
        bridge.invalidateCallbacks()
    }

    private static func invalidPayloadsDoNotConsumeCapacity() throws {
        let delivered = DispatchSemaphore(value: 0)
        let recorder = MacScopeGhosttyExternalIOBridgeFocusedRecorder()
        let bridge = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            limits: .init(
                maximumWriteByteCount: 2,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 2,
                maximumGridDimension: 100,
                maximumPixelDimension: 1_000
            )
        ) { work in
            recorder.append(work)
            delivered.signal()
        }

        try require(bridge.callbackBox.copyWrite(nil, count: -1) == .invalid, "negative count admitted")
        try require(bridge.callbackBox.copyWrite(nil, count: 1) == .invalid, "nil payload admitted")
        try require(write([0x01, 0x02, 0x03], to: bridge.callbackBox) == .invalid, "oversize admitted")
        try require(
            bridge.callbackBox.proposeResize(.init(
                columns: 101,
                rows: 24,
                pixelWidth: 800,
                pixelHeight: 600
            )) == .invalid,
            "invalid resize admitted"
        )
        try require(recorder.values.isEmpty, "invalid payload reached the handler")
        try require(
            write([0x01, 0x02], to: bridge.callbackBox) == .accepted,
            "invalid payload consumed valid capacity"
        )
        try require(
            delivered.wait(timeout: .now() + 2) == .success,
            "valid callback after invalid payloads did not deliver"
        )
        try require(
            recorder.values == [.write(generation: generation, bytes: Data([0x01, 0x02]))],
            "valid callback after invalid payloads changed"
        )

        let permanentlyOversized = MacScopeGhosttyExternalIOBridge(
            generation: generation,
            limits: .init(
                maximumWriteByteCount: 8,
                maximumPendingWorkCount: 1,
                maximumPendingByteCount: 1
            )
        ) { _ in }
        try require(
            write([0x01, 0x02], to: permanentlyOversized.callbackBox) == .invalid,
            "a write that can never fit was reported as retryable backpressure"
        )
        try require(permanentlyOversized.retire(generation: generation), "oversize bridge did not retire")
        permanentlyOversized.invalidateCallbacks()
    }

    private static func write(
        _ bytes: [UInt8],
        to box: MacScopeGhosttyExternalIOBridge.CallbackBox
    ) -> MacScopeGhosttyExternalIOBridge.Admission {
        bytes.withUnsafeBytes { box.copyWrite($0.baseAddress, count: $0.count) }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw MacScopeGhosttyExternalIOBridgeSaturationFailure.assertion(message)
        }
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

private final class MacScopeGhosttyExternalIOBridgeFocusedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MacScopeGhosttyExternalIOBridge.Work] = []

    var values: [MacScopeGhosttyExternalIOBridge.Work] {
        lock.withLock { storage }
    }

    @discardableResult
    func append(_ work: MacScopeGhosttyExternalIOBridge.Work) -> Int {
        lock.withLock {
            storage.append(work)
            return storage.count
        }
    }
}

private final class MacScopeGhosttyExternalIOBridgeFocusedBoolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []

    var values: [Bool] {
        lock.withLock { storage }
    }

    func append(_ value: Bool) {
        lock.withLock { storage.append(value) }
    }
}

private final class MacScopeGhosttyExternalIOBridgeFocusedAdmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MacScopeGhosttyExternalIOBridge.Admission] = []

    var values: [MacScopeGhosttyExternalIOBridge.Admission] {
        lock.withLock { storage }
    }

    func append(_ value: MacScopeGhosttyExternalIOBridge.Admission) {
        lock.withLock { storage.append(value) }
    }
}

private final class MacScopeGhosttyExternalIOBridgeFocusedGenerationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MacScopeGhosttySurfaceGeneration] = []

    var values: [MacScopeGhosttySurfaceGeneration] {
        lock.withLock { storage }
    }

    func append(_ value: MacScopeGhosttySurfaceGeneration) {
        lock.withLock { storage.append(value) }
    }
}

private final class MacScopeGhosttyExternalIOBridgeFocusedHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var bridge: MacScopeGhosttyExternalIOBridge?

    func install(_ bridge: MacScopeGhosttyExternalIOBridge) {
        lock.withLock { self.bridge = bridge }
    }

    func retire(generation: MacScopeGhosttySurfaceGeneration) -> Bool {
        lock.withLock { bridge?.retire(generation: generation) ?? false }
    }

    func write(_ bytes: [UInt8]) -> MacScopeGhosttyExternalIOBridge.Admission {
        let bridge = lock.withLock { self.bridge }
        guard let bridge else { return .closed }
        return bytes.withUnsafeBytes {
            bridge.callbackBox.copyWrite($0.baseAddress, count: $0.count)
        }
    }

    func clear() {
        lock.withLock { bridge = nil }
    }
}

private final class MacScopeGhosttyExternalIOBridgeFocusedRouter: @unchecked Sendable {
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
