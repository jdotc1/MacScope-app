import Darwin
import Foundation

#if MACSCOPE_GHOSTTY_PRODUCT_WIRING_FOCUSED_MAIN
@main
private enum Phase2GhosttyBrokerSurfaceFocusedMain {
    static func main() async {
        let scenarios: [(String, @MainActor @Sendable () async throws -> Void)] = [
            ("presentation identity projection", Phase2GhosttyBrokerSurfaceScenarios.presentationIdentityProjection),
            ("monotonic generation replacement", Phase2GhosttyBrokerSurfaceScenarios.monotonicGenerationReplacement),
            ("exact bridge command projection", Phase2GhosttyBrokerSurfaceScenarios.exactBridgeCommandProjection),
            ("fatal bridge health projection", Phase2GhosttyBrokerSurfaceScenarios.fatalBridgeHealthProjection),
            ("feed cursor resumes without duplicates", Phase2GhosttyBrokerSurfaceScenarios.feedCursorResumesWithoutDuplicates),
            ("command pump preserves order", Phase2GhosttyBrokerSurfaceScenarios.commandPumpPreservesOrder),
            ("command pump saturation fails closed", Phase2GhosttyBrokerSurfaceScenarios.commandPumpSaturationFailsClosed),
            ("fatal health retires command pump", Phase2GhosttyBrokerSurfaceScenarios.fatalHealthRetiresCommandPump),
            ("retirement rejects late completion", Phase2GhosttyBrokerSurfaceScenarios.retirementRejectsLateCompletion),
            ("replacement fences generation callbacks", Phase2GhosttyBrokerSurfaceScenarios.replacementFencesGenerationCallbacks),
            ("large transcript catch-up is bounded", Phase2GhosttyBrokerSurfaceScenarios.largeTranscriptCatchUpIsBounded),
            ("terminal outcome projection", Phase2GhosttyBrokerSurfaceScenarios.terminalOutcomeProjection),
            ("health fallback selects legacy grid", Phase2GhosttyBrokerSurfaceScenarios.healthFallbackSelectsLegacyGrid),
        ]
        var failures = 0
        for (name, scenario) in scenarios {
            do {
                try await scenario()
                print("PASS: \(name)")
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
            }
        }
        if failures > 0 { exit(1) }
    }
}
#else
import XCTest

@testable import MacScope

@MainActor
final class Phase2GhosttyBrokerSurfaceTests: XCTestCase {
    func testPresentationProjectsExactRendererIdentityAndLifecycle() throws {
        try Phase2GhosttyBrokerSurfaceScenarios.presentationIdentityProjection()
    }

    func testReplacementGenerationsAreMonotonicAndNeverReused() throws {
        try Phase2GhosttyBrokerSurfaceScenarios.monotonicGenerationReplacement()
    }

    func testBridgeCommandsRequireExactGenerationAndPreservePayloads() throws {
        try Phase2GhosttyBrokerSurfaceScenarios.exactBridgeCommandProjection()
    }

    func testOnlyFatalExactGenerationHealthRetiresTheSurface() throws {
        try Phase2GhosttyBrokerSurfaceScenarios.fatalBridgeHealthProjection()
    }

    func testFeedCursorResumesAfterBackpressureWithoutDuplicatingAcceptedOutput() throws {
        try Phase2GhosttyBrokerSurfaceScenarios.feedCursorResumesWithoutDuplicates()
    }

    func testCommandPumpPreservesWriteResizeAndCloseOrder() async throws {
        try await Phase2GhosttyBrokerSurfaceScenarios.commandPumpPreservesOrder()
    }

    func testCommandPumpFailsClosedAtFiniteCountAndByteCeilings() async throws {
        try await Phase2GhosttyBrokerSurfaceScenarios.commandPumpSaturationFailsClosed()
    }

    func testFatalHealthRetiresCommandPumpAndDeliversFailure() async throws {
        try await Phase2GhosttyBrokerSurfaceScenarios.fatalHealthRetiresCommandPump()
    }

    func testRetirementDropsPendingWorkAndRejectsLateRouteCompletion() async throws {
        try await Phase2GhosttyBrokerSurfaceScenarios.retirementRejectsLateCompletion()
    }

    func testReplacementGenerationRejectsStaleAndLateCallbacks() async throws {
        try await Phase2GhosttyBrokerSurfaceScenarios.replacementFencesGenerationCallbacks()
    }

    func testLargeTranscriptCatchUpIsCoalescedAndBoundedPerTurn() throws {
        try Phase2GhosttyBrokerSurfaceScenarios.largeTranscriptCatchUpIsBounded()
    }

    func testTerminalOutcomesMapToRendererStateWithoutProcessAuthority() throws {
        try Phase2GhosttyBrokerSurfaceScenarios.terminalOutcomeProjection()
    }

    func testRuntimeHealthFallbackSelectsTheLegacyGhosttyGrid() throws {
        try Phase2GhosttyBrokerSurfaceScenarios.healthFallbackSelectsLegacyGrid()
    }
}
#endif

private enum Phase2GhosttyBrokerSurfaceScenarioError: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): message
        }
    }
}

private enum Phase2GhosttyBrokerSurfaceScenarios {
    private static let sessionA = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
    private static let requestA = UUID(uuidString: "00000000-0000-0000-0000-000000000602")!
    private static let sessionB = UUID(uuidString: "00000000-0000-0000-0000-000000000603")!
    private static let requestB = UUID(uuidString: "00000000-0000-0000-0000-000000000604")!

    @MainActor
    static func presentationIdentityProjection() throws {
        let snapshot = Phase2HumanPTYSessionSnapshot(
            sessionID: sessionA,
            state: .running(requestID: requestA, processIdentifier: 4242),
            launchPlan: nil,
            transcriptEvents: [],
            issues: []
        )
        let projection = Phase2WorkspaceShellSessionProjection(
            snapshot: snapshot,
            inFlightCommand: nil,
            lastError: nil,
            lastAcceptedTranscriptEvents: [],
            lastBytesWritten: nil
        )

        let presentation = Phase2ShellAffordancePresentation.project(projection)
        try require(presentation.terminalSessionID == sessionA, "session identity was not projected")
        try require(presentation.terminalRequestID == requestA, "request identity was not projected")
        try require(
            presentation.terminalLifecycleState == snapshot.state,
            "lifecycle state was not projected"
        )
    }

    @MainActor
    static func monotonicGenerationReplacement() throws {
        var state = Phase2GhosttySurfaceBindingState()
        guard case let .replace(retiring, first) = state.reconcile(
            sessionID: sessionA,
            requestID: requestA
        ) else { throw assertion("first identity did not allocate a surface") }
        try require(retiring == nil, "first allocation unexpectedly retired a surface")
        try require(first.generation == 1, "first generation was not one")

        try require(
            state.reconcile(sessionID: sessionA, requestID: requestA) == .unchanged(first),
            "stable identity allocated a replacement"
        )

        guard case let .replace(retired, second) = state.reconcile(
            sessionID: sessionB,
            requestID: requestB
        ) else { throw assertion("replacement identity did not allocate a surface") }
        try require(retired == first, "replacement did not retire the exact prior coordinate")
        try require(second.generation == 2, "replacement generation was not monotonic")

        state.reject(second)
        guard case let .replace(_, third) = state.reconcile(
            sessionID: sessionB,
            requestID: requestB
        ) else { throw assertion("rejected binding was not replaceable") }
        try require(third.generation == 3, "a rejected generation was reused")
        try require(state.retire() == third, "retirement did not return the active coordinate")
        try require(state.activeCoordinate == nil, "retirement retained an active coordinate")
    }

    @MainActor
    static func exactBridgeCommandProjection() throws {
        let coordinate = surfaceCoordinate(generation: 7)
        let exact = coordinate.ghosttySurfaceGeneration
        let stale = MacScopeGhosttySurfaceGeneration(
            sessionID: exact.sessionID,
            requestID: exact.requestID,
            generation: exact.generation + 1
        )

        try require(
            Phase2GhosttyBrokerSurfaceCommand.project(
                .write(generation: exact, bytes: Data([0x41, 0x00, 0x42])),
                expected: coordinate
            ) == .write([0x41, 0x00, 0x42]),
            "exact write bytes changed"
        )
        try require(
            Phase2GhosttyBrokerSurfaceCommand.project(
                .write(generation: stale, bytes: Data([0x43])),
                expected: coordinate
            ) == nil,
            "stale write crossed the generation fence"
        )

        let resize = MacScopeGhosttyExternalIOBridge.ResizeProposal(
            columns: 132,
            rows: 43,
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )
        try require(
            Phase2GhosttyBrokerSurfaceCommand.project(
                .resize(generation: exact, proposal: resize),
                expected: coordinate
            ) == .resize(Phase2ShellSurfaceResizeProposal(
                terminalSize: .init(columns: 132, rows: 43),
                pixelSize: .init(width: 1_920, height: 1_080)
            )),
            "resize dimensions changed"
        )
        try require(
            Phase2GhosttyBrokerSurfaceCommand.project(
                .close(generation: exact, reason: .surfaceRequest),
                expected: coordinate
            ) == .close(reason: "ghosttySurfaceRequest"),
            "surface close was not projected to app cleanup"
        )
        try require(
            Phase2GhosttyBrokerSurfaceCommand.project(
                .health(generation: exact, event: .feedReady, detail: 3),
                expected: coordinate
            ) == nil,
            "health evidence was incorrectly projected as process authority"
        )
    }

    @MainActor
    static func fatalBridgeHealthProjection() throws {
        let coordinate = surfaceCoordinate(generation: 8)
        let exact = coordinate.ghosttySurfaceGeneration
        let stale = MacScopeGhosttySurfaceGeneration(
            sessionID: exact.sessionID,
            requestID: exact.requestID,
            generation: exact.generation + 1
        )

        try require(
            Phase2GhosttyBrokerHealthFailure.project(
                .health(generation: exact, event: .outputOverflow, detail: 4_096),
                expected: coordinate
            ) == .init(event: .outputOverflow, detail: 4_096),
            "exact overflow was not promoted to a surface health failure"
        )
        try require(
            Phase2GhosttyBrokerHealthFailure.project(
                .health(generation: exact, event: .outputSuppressed, detail: 17),
                expected: coordinate
            ) == .init(event: .outputSuppressed, detail: 17),
            "exact suppressed output was not promoted to a surface health failure"
        )
        try require(
            Phase2GhosttyBrokerHealthFailure.project(
                .health(generation: exact, event: .outputBackpressured, detail: 64),
                expected: coordinate
            ) == nil,
            "recoverable output backpressure was treated as terminal"
        )
        try require(
            Phase2GhosttyBrokerHealthFailure.project(
                .health(generation: stale, event: .outputOverflow, detail: 4_096),
                expected: coordinate
            ) == nil,
            "stale health crossed the generation fence"
        )
    }

    @MainActor
    static func feedCursorResumesWithoutDuplicates() throws {
        let coordinate = surfaceCoordinate(generation: 9).rendererCoordinate
        let first = transcriptEvent(sequence: 1, bytes: [0x41])
        let second = transcriptEvent(sequence: 3, bytes: [0x42, 0x43])
        let projection = Phase2GhosttyTranscriptProjection(
            coordinate: coordinate,
            highWaterSequence: 3,
            outputEvents: [first, second]
        )
        var cursor = Phase2GhosttyBrokerFeedCursor(coordinate: coordinate)
        let oneEvent = Phase2GhosttyBrokerFeedBudget(maximumEvents: 1, maximumBytes: 32)
        var firstAttempt: [Data] = []
        let firstAccepted = cursor.feed(projection, budget: oneEvent) { bytes in
            firstAttempt.append(bytes)
            return .accepted
        }
        try require(
            firstAccepted == .accepted(
                eventCount: 1,
                byteCount: 1,
                highWaterSequence: 3,
                requiresContinuation: true
            ),
            "the first bounded feed did not request continuation"
        )

        let backpressured = cursor.feed(projection, budget: oneEvent) { bytes in
            firstAttempt.append(bytes)
            return .backpressured
        }

        try require(
            backpressured == .rejected(.backendRejected(sequence: 3, admission: .backpressured)),
            "backpressure was not preserved"
        )
        try require(firstAttempt == [Data([0x41]), Data([0x42, 0x43])], "feed order changed")
        try require(cursor.lastFedOutputSequence == 1, "accepted output cursor did not advance")

        var retry: [Data] = []
        let accepted = cursor.feed(projection, budget: oneEvent) { bytes in
            retry.append(bytes)
            return .accepted
        }
        try require(retry == [Data([0x42, 0x43])], "retry duplicated already accepted output")
        try require(
            accepted == .accepted(
                eventCount: 1,
                byteCount: 2,
                highWaterSequence: 3,
                requiresContinuation: false
            ),
            "retry did not close the authoritative high water"
        )
    }

    @MainActor
    static func commandPumpPreservesOrder() async throws {
        let coordinate = surfaceCoordinate(generation: 41)
        let routes = Phase2GhosttyBrokerImmediateRouteRecorder(deferFirstAttempt: true)
        let failures = Phase2GhosttyBrokerPumpFailureRecorder()
        let pump = Phase2GhosttyBrokerCommandPump(
            coordinate: coordinate,
            configuration: .init(
                maximumPendingCommands: 8,
                maximumPendingWriteBytes: 1_024,
                contentionDelayNanoseconds: 1_000_000
            ),
            route: { await routes.route($0) },
            failureHandler: { failures.record($0) }
        )
        pump.setInputEnabled(true)
        let commands: [Phase2GhosttyBrokerSurfaceCommand] = [
            .write([0x41]),
            resizeCommand(columns: 80, rows: 24),
            .write([0x42, 0x43]),
            resizeCommand(columns: 132, rows: 43),
            .close(reason: "orderedClose"),
        ]

        for command in commands {
            try require(pump.submit(command) == .accepted, "an ordered command was rejected")
        }
        await routes.waitForCount(commands.count)
        try require(routes.commands == commands, "write/resize/close command order changed")
        try require(
            Array(routes.attempts.prefix(2)) == [commands[0], commands[0]],
            "contention advanced past the deferred head command"
        )
        try require(failures.failures.isEmpty, "ordered routing produced a pump failure")
        pump.retire()
    }

    @MainActor
    static func commandPumpSaturationFailsClosed() async throws {
        let coordinate = surfaceCoordinate(generation: 42)
        let routes = Phase2GhosttyBrokerRouteGate()
        let failures = Phase2GhosttyBrokerPumpFailureRecorder()
        let configuration = Phase2GhosttyBrokerCommandPump.Configuration(
            maximumPendingCommands: 2,
            maximumPendingWriteBytes: 2
        )
        let pump = Phase2GhosttyBrokerCommandPump(
            coordinate: coordinate,
            configuration: configuration,
            route: { await routes.route($0) },
            failureHandler: { failures.record($0) }
        )
        pump.setInputEnabled(true)

        try require(pump.submit(.write([0x01])) == .accepted, "initial command was rejected")
        await routes.waitUntilStarted()
        try require(
            pump.submit(resizeCommand(columns: 100, rows: 30)) == .accepted,
            "zero-byte resize did not enter the finite queue"
        )
        try require(
            pump.submit(.write([0x02, 0x03])) == .accepted,
            "write did not fill the finite byte budget"
        )
        let saturatedFailure = Phase2GhosttyBrokerCommandPumpFailure.saturated(
            maximumPendingCommands: configuration.maximumPendingCommands,
            maximumPendingWriteBytes: configuration.maximumPendingWriteBytes
        )
        try require(
            pump.submit(.close(reason: "mustNotQueue")) == .failed(saturatedFailure),
            "queue saturation did not fail closed"
        )

        let pendingSnapshot = pump.snapshot()
        try require(pendingSnapshot.lifecycle == .failurePending, "saturation stayed active")
        try require(pendingSnapshot.pendingCommandCount == 0, "saturation retained queued commands")
        try require(pendingSnapshot.pendingWriteByteCount == 0, "saturation retained queued bytes")
        try require(
            pendingSnapshot.maximumObservedPendingCommandCount == 2,
            "pending command count crossed or missed its finite ceiling"
        )
        try require(
            pendingSnapshot.maximumObservedPendingWriteByteCount == 2,
            "pending write bytes crossed or missed their finite ceiling"
        )

        routes.release(.accepted)
        await routes.waitForCompletion()
        await failures.waitForCount(1)
        try require(failures.failures == [saturatedFailure], "saturation failure was not exact")
        try require(routes.commands == [.write([0x01])], "queued work escaped after saturation")
        try require(pump.snapshot().lifecycle == .retired, "delivered saturation was not retired")

        let byteCoordinate = surfaceCoordinate(generation: 44)
        let byteRoutes = Phase2GhosttyBrokerRouteGate()
        let byteFailures = Phase2GhosttyBrokerPumpFailureRecorder()
        let byteConfiguration = Phase2GhosttyBrokerCommandPump.Configuration(
            maximumPendingCommands: 4,
            maximumPendingWriteBytes: 2
        )
        let bytePump = Phase2GhosttyBrokerCommandPump(
            coordinate: byteCoordinate,
            configuration: byteConfiguration,
            route: { await byteRoutes.route($0) },
            failureHandler: { byteFailures.record($0) }
        )
        bytePump.setInputEnabled(true)
        let heldResize = resizeCommand(columns: 101, rows: 31)
        try require(bytePump.submit(heldResize) == .accepted, "byte-budget gate did not start")
        await byteRoutes.waitUntilStarted()
        try require(
            bytePump.submit(.write([0x11, 0x12])) == .accepted,
            "write did not fill the independent byte ceiling"
        )
        let byteFailure = Phase2GhosttyBrokerCommandPumpFailure.saturated(
            maximumPendingCommands: byteConfiguration.maximumPendingCommands,
            maximumPendingWriteBytes: byteConfiguration.maximumPendingWriteBytes
        )
        try require(
            bytePump.submit(.write([0x13])) == .failed(byteFailure),
            "byte saturation was admitted below the command-count ceiling"
        )
        let byteSnapshot = bytePump.snapshot()
        try require(
            byteSnapshot.maximumObservedPendingCommandCount == 1,
            "byte-only saturation unexpectedly reached the command ceiling"
        )
        try require(
            byteSnapshot.maximumObservedPendingWriteByteCount == 2,
            "byte-only saturation crossed or missed its ceiling"
        )
        byteRoutes.release(.accepted)
        await byteRoutes.waitForCompletion()
        await byteFailures.waitForCount(1)
        try require(byteFailures.failures == [byteFailure], "byte failure was not exact")
        try require(byteRoutes.commands == [heldResize], "byte saturation leaked queued input")
    }

    @MainActor
    static func fatalHealthRetiresCommandPump() async throws {
        let coordinate = surfaceCoordinate(generation: 45)
        let failures = Phase2GhosttyBrokerPumpFailureRecorder()
        let pump = Phase2GhosttyBrokerCommandPump(
            coordinate: coordinate,
            route: { _ in .accepted },
            failureHandler: { failures.record($0) }
        )
        pump.setInputEnabled(true)
        let health = Phase2GhosttyBrokerHealthFailure(event: .outputSuppressed, detail: 77)
        let failure = Phase2GhosttyBrokerCommandPumpFailure.bridgeHealth(health)
        try require(
            pump.submit(.health(
                generation: coordinate.ghosttySurfaceGeneration,
                event: .outputSuppressed,
                detail: 77
            )) == .failed(failure),
            "fatal exact-coordinate health did not fail the pump"
        )
        await failures.waitForCount(1)
        try require(failures.failures == [failure], "fatal health delivery changed")
        try require(pump.snapshot().lifecycle == .retired, "fatal health pump stayed active")
        try require(
            pump.submit(.write([0x41])) == .retired,
            "fatal health allowed later input"
        )
    }

    @MainActor
    static func retirementRejectsLateCompletion() async throws {
        let coordinate = surfaceCoordinate(generation: 43)
        let routes = Phase2GhosttyBrokerRouteGate()
        let failures = Phase2GhosttyBrokerPumpFailureRecorder()
        let pump = Phase2GhosttyBrokerCommandPump(
            coordinate: coordinate,
            configuration: .init(
                maximumPendingCommands: 4,
                maximumPendingWriteBytes: 64
            ),
            route: { await routes.route($0) },
            failureHandler: { failures.record($0) }
        )
        pump.setInputEnabled(true)

        try require(pump.submit(.write([0x31])) == .accepted, "initial route was rejected")
        await routes.waitUntilStarted()
        try require(
            pump.submit(resizeCommand(columns: 90, rows: 25)) == .accepted,
            "pending resize was rejected before retirement"
        )
        pump.retire()
        try require(pump.snapshot().pendingCommandCount == 0, "retirement retained pending work")
        try require(
            pump.submit(.close(reason: "lateClose")) == .retired,
            "post-retirement submission was admitted"
        )

        routes.release(.failed)
        await routes.waitForCompletion()
        await yieldMainActorTurns()
        try require(routes.commands == [.write([0x31])], "late completion restarted the drain")
        try require(failures.failures.isEmpty, "late route failure escaped retirement")

        let lateFailurePump = Phase2GhosttyBrokerCommandPump(
            coordinate: coordinate,
            route: { _ in .accepted },
            failureHandler: { failures.record($0) }
        )
        let health = Phase2GhosttyBrokerHealthFailure(event: .outputOverflow, detail: 99)
        try require(
            lateFailurePump.submit(.health(
                generation: coordinate.ghosttySurfaceGeneration,
                event: .outputOverflow,
                detail: 99
            )) == .failed(.bridgeHealth(health)),
            "exact fatal health was not scheduled"
        )
        lateFailurePump.retire()
        await yieldMainActorTurns()
        try require(failures.failures.isEmpty, "retirement delivered a late health callback")
    }

    @MainActor
    static func replacementFencesGenerationCallbacks() async throws {
        let oldCoordinate = surfaceCoordinate(generation: 51)
        let replacementCoordinate = surfaceCoordinate(generation: 52)
        let oldRoutes = Phase2GhosttyBrokerRouteGate()
        let replacementRoutes = Phase2GhosttyBrokerImmediateRouteRecorder()
        let failures = Phase2GhosttyBrokerPumpFailureRecorder()
        let oldPump = Phase2GhosttyBrokerCommandPump(
            coordinate: oldCoordinate,
            route: { await oldRoutes.route($0) },
            failureHandler: { failures.record($0) }
        )
        let replacementPump = Phase2GhosttyBrokerCommandPump(
            coordinate: replacementCoordinate,
            route: { await replacementRoutes.route($0) },
            failureHandler: { failures.record($0) }
        )
        oldPump.setInputEnabled(true)
        replacementPump.setInputEnabled(true)

        try require(
            oldPump.submit(.write(
                generation: oldCoordinate.ghosttySurfaceGeneration,
                bytes: Data([0x41])
            )) == .accepted,
            "old generation did not start"
        )
        await oldRoutes.waitUntilStarted()
        oldPump.retire()

        try require(
            replacementPump.submit(.write(
                generation: oldCoordinate.ghosttySurfaceGeneration,
                bytes: Data([0x42])
            )) == .ignored,
            "stale generation callback entered the replacement pump"
        )
        try require(
            replacementPump.submit(.write(
                generation: replacementCoordinate.ghosttySurfaceGeneration,
                bytes: Data([0x43])
            )) == .accepted,
            "replacement generation callback was rejected"
        )
        try require(
            oldPump.submit(.write(
                generation: oldCoordinate.ghosttySurfaceGeneration,
                bytes: Data([0x44])
            )) == .retired,
            "late callback re-entered the old generation"
        )

        await replacementRoutes.waitForCount(1)
        oldRoutes.release(.accepted)
        await oldRoutes.waitForCompletion()
        await yieldMainActorTurns()
        try require(
            replacementRoutes.commands == [.write([0x43])],
            "replacement routed stale or reordered bytes"
        )
        try require(oldRoutes.commands == [.write([0x41])], "old completion routed more work")
        try require(failures.failures.isEmpty, "generation replacement produced false health")
        replacementPump.retire()
    }

    @MainActor
    static func largeTranscriptCatchUpIsBounded() throws {
        let outputEventCount = 4_096
        let bytesPerEvent = 19
        let coordinate = surfaceCoordinate(generation: 61).rendererCoordinate
        let events = (1...outputEventCount).map { value in
            transcriptEvent(
                sequence: UInt64(value),
                bytes: Array(
                    repeating: UInt8(truncatingIfNeeded: value),
                    count: bytesPerEvent
                )
            )
        }
        let projection = Phase2GhosttyTranscriptProjection(
            coordinate: coordinate,
            highWaterSequence: UInt64(outputEventCount),
            outputEvents: events
        )
        let budget = Phase2GhosttyBrokerFeedBudget(maximumEvents: 23, maximumBytes: 127)
        var cursor = Phase2GhosttyBrokerFeedCursor(coordinate: coordinate)
        var submitted: [Data] = []
        var requiresContinuation = true
        var turns = 0

        while requiresContinuation {
            turns += 1
            try require(turns < 10_000, "bounded catch-up failed to converge")
            let disposition = cursor.feed(projection, budget: budget) { bytes in
                submitted.append(bytes)
                return .accepted
            }
            guard case let .accepted(eventCount, byteCount, highWater, continuation) = disposition
            else { throw assertion("large catch-up was rejected") }
            try require(eventCount <= budget.maximumEvents, "one turn crossed its event budget")
            try require(byteCount <= budget.maximumBytes, "one turn crossed its byte budget")
            try require(highWater == UInt64(outputEventCount), "catch-up changed high water")
            requiresContinuation = continuation
        }

        var expectedBytes: [UInt8] = []
        expectedBytes.reserveCapacity(outputEventCount * bytesPerEvent)
        for event in events {
            guard case let .output(_, bytes) = event.payload else {
                throw assertion("fixture unexpectedly contained non-output")
            }
            expectedBytes.append(contentsOf: bytes)
        }
        var actualBytes: [UInt8] = []
        actualBytes.reserveCapacity(expectedBytes.count)
        for chunk in submitted {
            try require(chunk.count <= budget.maximumBytes, "submitted chunk crossed byte budget")
            actualBytes.append(contentsOf: chunk)
        }

        try require(actualBytes == expectedBytes, "coalesced catch-up changed authoritative bytes")
        try require(submitted.count == turns, "one turn issued more than one backend submission")
        try require(
            submitted.count < outputEventCount / 2,
            "large catch-up was not materially coalesced"
        )
        try require(
            cursor.lastFedOutputSequence == UInt64(outputEventCount),
            "large catch-up did not close the output cursor"
        )
        try require(cursor.nextOutputByteOffset == 0, "catch-up ended inside an output event")
    }

    @MainActor
    static func terminalOutcomeProjection() throws {
        try require(
            Phase2GhosttyBrokerProcessStateProjection.project(.exited(status: 7)) == .exited(status: 7),
            "exit status changed"
        )
        try require(
            Phase2GhosttyBrokerProcessStateProjection.project(.signaled(.terminate))
                == .signaled(signal: UInt32(SIGTERM)),
            "termination signal changed"
        )
        try require(
            Phase2GhosttyBrokerProcessStateProjection.project(.interrupted)
                == .signaled(signal: UInt32(SIGINT)),
            "interrupt was not reported as host evidence"
        )
        try require(
            Phase2GhosttyBrokerProcessStateProjection.project(.brokerCrashed) == .closed,
            "broker crash granted renderer process authority"
        )
    }

    @MainActor
    static func healthFallbackSelectsLegacyGrid() throws {
        let feature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: nil
        )
        let selection = Phase2TerminalRendererSelection.resolve(
            feature: feature,
            runtimeState: .failed(.health)
        )
        try require(selection.backend == .macScopeGhosttyVTGrid, "health failure did not select the legacy backend")
        try require(
            Phase2TerminalSurfacePresentation.renderingPath(
                rendererSelection: selection,
                fullSurfaceAvailable: true,
                sessionID: sessionA,
                events: [transcriptEvent(sequence: 1, bytes: [0x41])]
            ) == .ghostty(sessionA),
            "health fallback reused the full surface or transcript text instead of the legacy grid"
        )
    }

    private static func resizeCommand(
        columns: Int,
        rows: Int
    ) -> Phase2GhosttyBrokerSurfaceCommand {
        .resize(Phase2ShellSurfaceResizeProposal(
            terminalSize: .init(columns: columns, rows: rows),
            pixelSize: .init(width: columns * 10, height: rows * 20)
        ))
    }

    @MainActor
    private static func yieldMainActorTurns(_ count: Int = 8) async {
        for _ in 0..<count {
            await Task.yield()
        }
    }

    private static func surfaceCoordinate(
        generation: UInt64
    ) -> Phase2ShellSurfaceCommandCoordinate {
        Phase2ShellSurfaceCommandCoordinate(
            sessionID: sessionA,
            requestID: requestA,
            generation: generation
        )
    }

    private static func transcriptEvent(
        sequence: UInt64,
        bytes: [UInt8]
    ) -> Phase2HumanPTYTranscriptEvent {
        Phase2HumanPTYTranscriptEvent(
            sessionID: sessionA,
            sequence: sequence,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes)
        )
    }

    private static func assertion(_ message: String) -> Phase2GhosttyBrokerSurfaceScenarioError {
        .assertion(message)
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw assertion(message) }
    }
}

@MainActor
private final class Phase2GhosttyBrokerImmediateRouteRecorder {
    private(set) var commands: [Phase2GhosttyBrokerSurfaceCommand] = []
    private(set) var attempts: [Phase2GhosttyBrokerSurfaceCommand] = []
    private var shouldDeferFirstAttempt: Bool
    private var waiter: (
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )?

    init(deferFirstAttempt: Bool = false) {
        shouldDeferFirstAttempt = deferFirstAttempt
    }

    func route(
        _ command: Phase2GhosttyBrokerSurfaceCommand
    ) async -> Phase2GhosttyBrokerCommandRouteDisposition {
        attempts.append(command)
        if shouldDeferFirstAttempt {
            shouldDeferFirstAttempt = false
            return .deferred
        }
        commands.append(command)
        if let waiter, commands.count >= waiter.target {
            self.waiter = nil
            waiter.continuation.resume()
        }
        return .accepted
    }

    func waitForCount(_ target: Int) async {
        if commands.count >= target { return }
        await withCheckedContinuation { continuation in
            waiter = (target, continuation)
        }
    }
}

@MainActor
private final class Phase2GhosttyBrokerRouteGate {
    private(set) var commands: [Phase2GhosttyBrokerSurfaceCommand] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var routeContinuation: CheckedContinuation<
        Phase2GhosttyBrokerCommandRouteDisposition,
        Never
    >?
    private var completionCount = 0
    private var completionWaiter: CheckedContinuation<Void, Never>?

    func route(
        _ command: Phase2GhosttyBrokerSurfaceCommand
    ) async -> Phase2GhosttyBrokerCommandRouteDisposition {
        commands.append(command)
        startedWaiter?.resume()
        startedWaiter = nil
        let disposition = await withCheckedContinuation { continuation in
            routeContinuation = continuation
        }
        completionCount += 1
        completionWaiter?.resume()
        completionWaiter = nil
        return disposition
    }

    func waitUntilStarted() async {
        if !commands.isEmpty { return }
        await withCheckedContinuation { continuation in
            startedWaiter = continuation
        }
    }

    func release(_ disposition: Phase2GhosttyBrokerCommandRouteDisposition) {
        routeContinuation?.resume(returning: disposition)
        routeContinuation = nil
    }

    func waitForCompletion() async {
        if completionCount > 0 { return }
        await withCheckedContinuation { continuation in
            completionWaiter = continuation
        }
    }
}

@MainActor
private final class Phase2GhosttyBrokerPumpFailureRecorder {
    private(set) var failures: [Phase2GhosttyBrokerCommandPumpFailure] = []
    private var waiter: (
        target: Int,
        continuation: CheckedContinuation<Void, Never>
    )?

    func record(_ failure: Phase2GhosttyBrokerCommandPumpFailure) {
        failures.append(failure)
        if let waiter, failures.count >= waiter.target {
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ target: Int) async {
        if failures.count >= target { return }
        await withCheckedContinuation { continuation in
            waiter = (target, continuation)
        }
    }
}
