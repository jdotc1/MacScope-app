import Foundation

#if MACSCOPE_CONTINUOUS_SHELL_TRANSCRIPT_FOCUSED_MAIN
struct Phase2ShellSurfaceCommandCoordinate: Equatable, Hashable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let generation: UInt64
}

@main
private enum Phase2ContinuousShellTranscriptControllerFocusedMain {
    static func main() async {
        let scenarios: [(String, @MainActor () async throws -> Void)] = [
            ("stable token and exact coordinate", Phase2ContinuousShellTranscriptControllerScenarios.stableTokenAndExactCoordinate),
            ("replacement fences late health", Phase2ContinuousShellTranscriptControllerScenarios.replacementFencesLateHealth),
            ("same-coordinate command replacement fences canceled task", Phase2ContinuousShellTranscriptControllerScenarios.sameCoordinateCommandReplacementFencesCanceledTask),
            ("same-token stop and restart fences stale retirement", Phase2ContinuousShellTranscriptControllerScenarios.sameTokenStopAndRestartFencesStaleRetirement),
            ("continuous ownership excludes manual reduction", Phase2ContinuousShellTranscriptControllerScenarios.continuousOwnershipExcludesManualReduction),
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
final class Phase2ContinuousShellTranscriptControllerTests: XCTestCase {
    func testEmptyPacingStartsAfterOperationReleaseAndStopPreventsAnotherPoll() async throws {
        let gate = Phase2ContinuousIdleGate()
        let coordinate = Phase2ShellSurfaceCommandCoordinate(sessionID: UUID(), requestID: UUID(), generation: 1)
        var operationInFlight = false
        var polls = 0
        let controller = Phase2ContinuousShellTranscriptController(idleWait: { await gate.wait($0) })
        controller.start(coordinate: coordinate, commandID: UUID(), poll: { _, _, _, _, _ in
            polls += 1
            operationInFlight = true
            // Models the store's accepted reduction and operation release before returning.
            operationInFlight = false
            return .acceptedEmpty
        }, healthFailure: { _ in XCTFail("Idle pacing must not fail the surface") })
        await gate.waitUntilStarted()
        XCTAssertFalse(operationInFlight, "Pacing must leave control commands admissible")
        XCTAssertEqual(polls, 1)
        let duration = await gate.duration
        XCTAssertEqual(duration, 50_000_000)
        controller.stop()
        await gate.release()
        // A fresh controller task establishes progress without depending on a wall-clock delay.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(polls, 1, "Cancellation during pacing must not issue another poll")
    }

    func testOutputPollContinuesWithoutIdlePacing() async throws {
        let finished = expectation(description: "Output immediately followed by another poll")
        let gate = Phase2ContinuousIdleGate()
        let coordinate = Phase2ShellSurfaceCommandCoordinate(sessionID: UUID(), requestID: UUID(), generation: 1)
        var polls = 0
        let controller = Phase2ContinuousShellTranscriptController(
            idleWait: { await gate.record($0) },
            dispositionHandled: { disposition, _ in if disposition == .retired { finished.fulfill() } })
        controller.start(coordinate: coordinate, commandID: UUID(), poll: { _, _, _, _, _ in
            polls += 1
            return polls == 1 ? .accepted : .retired
        }, healthFailure: { _ in XCTFail("Unexpected failure") })
        await fulfillment(of: [finished], timeout: 2)
        let waits = await gate.count
        XCTAssertEqual(waits, 0)
        XCTAssertEqual(polls, 2)
    }

    func testPollsUseFreshInvocationIDsAndExactCoordinate() async throws {
        try await Phase2ContinuousShellTranscriptControllerScenarios.stableTokenAndExactCoordinate()
    }

    func testReplacementFencesLateHealthAndStaleStop() async throws {
        try await Phase2ContinuousShellTranscriptControllerScenarios.replacementFencesLateHealth()
    }

    func testSameCoordinateCommandReplacementFencesCanceledTask() async throws {
        try await Phase2ContinuousShellTranscriptControllerScenarios.sameCoordinateCommandReplacementFencesCanceledTask()
    }

    func testSameTokenStopAndRestartFencesStaleRetirement() async throws {
        try await Phase2ContinuousShellTranscriptControllerScenarios.sameTokenStopAndRestartFencesStaleRetirement()
    }

    func testContinuousOwnershipExcludesManualReduction() async throws {
        try await Phase2ContinuousShellTranscriptControllerScenarios.continuousOwnershipExcludesManualReduction()
    }
}
#endif

private enum Phase2ContinuousShellTranscriptControllerScenarioError: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): message
        }
    }
}

private enum Phase2ContinuousShellTranscriptControllerScenarios {
    private static let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
    private static let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000702")!

    @MainActor
    static func stableTokenAndExactCoordinate() async throws {
        let coordinate = surfaceCoordinate(generation: 11)
        let commandID = UUID(uuidString: "00000000-0000-0000-0000-000000000703")!
        let recorder = Phase2ContinuousStablePollRecorder()
        let controller = Phase2ContinuousShellTranscriptController(configuration: .init(
            maximumEvents: 17,
            maximumBytes: 2_048,
            timeoutMilliseconds: 41
        ))
        controller.start(
            coordinate: coordinate,
            commandID: commandID,
            poll: { token, candidate, events, bytes, timeout in
                recorder.record(
                    token: token,
                    coordinate: candidate,
                    maximumEvents: events,
                    maximumBytes: bytes,
                    timeoutMilliseconds: timeout
                )
            },
            healthFailure: { _ in }
        )
        await recorder.waitForCompletion()

        try require(recorder.calls.count == 2, "the loop did not perform the expected serial polls")
        try require(Set(recorder.calls.map(\.token)).count == recorder.calls.count,
                    "new wire polls reused an invocation identity")
        try require(recorder.calls.allSatisfy { $0.token != commandID },
                    "the lifetime fence leaked into a wire invocation")
        try require(recorder.calls.allSatisfy { $0.coordinate == coordinate }, "a poll lost the exact surface coordinate")
        try require(
            recorder.calls.allSatisfy {
                $0.maximumEvents == 17 && $0.maximumBytes == 2_048 && $0.timeoutMilliseconds == 41
            },
            "bounded poll configuration changed in transit"
        )
    }

    @MainActor
    static func replacementFencesLateHealth() async throws {
        let old = surfaceCoordinate(generation: 21)
        let replacement = surfaceCoordinate(generation: 22)
        let gate = Phase2ContinuousPollGate()
        let health = Phase2ContinuousHealthRecorder()
        let controller = Phase2ContinuousShellTranscriptController()

        controller.start(
            coordinate: old,
            commandID: UUID(),
            poll: { _, coordinate, _, _, _ in await gate.poll(coordinate) },
            healthFailure: { health.record($0) }
        )
        await gate.waitUntilStarted(old)
        controller.start(
            coordinate: replacement,
            commandID: UUID(),
            poll: { _, coordinate, _, _, _ in await gate.poll(coordinate) },
            healthFailure: { health.record($0) }
        )
        await gate.waitUntilStarted(replacement)

        try require(!controller.stop(coordinate: old), "a stale generation stopped its replacement")
        gate.release(old, disposition: .failed)
        gate.release(replacement, disposition: .failed)
        await health.waitForFailure()
        try require(health.coordinates == [replacement], "late health escaped the generation fence")
    }

    @MainActor
    static func sameCoordinateCommandReplacementFencesCanceledTask() async throws {
        let coordinate = surfaceCoordinate(generation: 23)
        let oldGate = Phase2ContinuousPollGate()
        let replacementGate = Phase2ContinuousPollGate()
        let oldHealth = Phase2ContinuousHealthRecorder()
        let replacementHealth = Phase2ContinuousHealthRecorder()
        let controller = Phase2ContinuousShellTranscriptController()

        controller.start(
            coordinate: coordinate,
            commandID: UUID(),
            poll: { _, candidate, _, _, _ in await oldGate.poll(candidate) },
            healthFailure: { oldHealth.record($0) }
        )
        await oldGate.waitUntilStarted(coordinate)

        controller.start(
            coordinate: coordinate,
            commandID: UUID(),
            poll: { _, candidate, _, _, _ in await replacementGate.poll(candidate) },
            healthFailure: { replacementHealth.record($0) }
        )
        await replacementGate.waitUntilStarted(coordinate)

        oldGate.release(coordinate, disposition: .failed)
        for _ in 0..<8 { await Task.yield() }
        try require(oldHealth.coordinates.isEmpty, "the canceled owner delivered late health")
        try require(
            replacementHealth.coordinates.isEmpty,
            "the canceled owner retired the same-coordinate replacement"
        )

        replacementGate.release(coordinate, disposition: .failed)
        await replacementHealth.waitForFailure()
        try require(
            replacementHealth.coordinates == [coordinate],
            "the replacement did not retain its own health-failure authority"
        )
    }

    @MainActor
    static func sameTokenStopAndRestartFencesStaleRetirement() async throws {
        let coordinate = surfaceCoordinate(generation: 24)
        let commandID = UUID()
        let oldGate = Phase2ContinuousPollGate()
        let replacementGate = Phase2ContinuousPollGate()
        let dispositionRecorder = Phase2ContinuousDispositionRecorder()
        let controller = Phase2ContinuousShellTranscriptController(
            dispositionHandled: { disposition, retainedOwnership in
                dispositionRecorder.record(
                    disposition: disposition,
                    retainedOwnership: retainedOwnership
                )
            }
        )

        controller.start(
            coordinate: coordinate,
            commandID: commandID,
            poll: { _, candidate, _, _, _ in await oldGate.poll(candidate) },
            healthFailure: { _ in }
        )
        await oldGate.waitUntilStarted(coordinate)
        try require(controller.stop(coordinate: coordinate), "the original owner did not stop")

        controller.start(
            coordinate: coordinate,
            commandID: commandID,
            poll: { _, candidate, _, _, _ in await replacementGate.poll(candidate) },
            healthFailure: { _ in }
        )
        await replacementGate.waitUntilStarted(coordinate)

        oldGate.release(coordinate, disposition: .retired)
        let observation = await dispositionRecorder.waitForObservation()
        try require(observation.disposition == .retired, "the stale retirement was not handled")
        try require(!observation.retainedOwnership, "the stale task retained replacement authority")
        try require(
            controller.stop(coordinate: coordinate),
            "the canceled owner retired its same-token replacement"
        )
        replacementGate.release(coordinate, disposition: .retired)
    }

    @MainActor
    static func continuousOwnershipExcludesManualReduction() async throws {
        let coordinate = surfaceCoordinate(generation: 31)
        try require(
            !Phase2ShellTranscriptPollingOwner.unselected.permitsManualReduction,
            "unselected startup permitted manual reduction"
        )
        try require(
            !Phase2ShellTranscriptPollingOwner.continuousSurface(coordinate).permitsManualReduction,
            "continuous polling permitted the legacy/manual reducer to race"
        )
        try require(
            Phase2ShellTranscriptPollingOwner.legacyManual.permitsManualReduction,
            "legacy fallback did not restore manual polling"
        )
    }

    private static func surfaceCoordinate(
        generation: UInt64
    ) -> Phase2ShellSurfaceCommandCoordinate {
        Phase2ShellSurfaceCommandCoordinate(
            sessionID: sessionID,
            requestID: requestID,
            generation: generation
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw Phase2ContinuousShellTranscriptControllerScenarioError.assertion(message)
        }
    }
}

@MainActor
private final class Phase2ContinuousDispositionRecorder {
    struct Observation {
        let disposition: Phase2ContinuousShellTranscriptController.PollDisposition
        let retainedOwnership: Bool
    }

    private var observations: [Observation] = []
    private var waiter: CheckedContinuation<Observation, Never>?

    func record(
        disposition: Phase2ContinuousShellTranscriptController.PollDisposition,
        retainedOwnership: Bool
    ) {
        let observation = Observation(
            disposition: disposition,
            retainedOwnership: retainedOwnership
        )
        observations.append(observation)
        waiter?.resume(returning: observation)
        waiter = nil
    }

    func waitForObservation() async -> Observation {
        if let observation = observations.first { return observation }
        return await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
private final class Phase2ContinuousStablePollRecorder {
    struct Call {
        let token: UUID
        let coordinate: Phase2ShellSurfaceCommandCoordinate
        let maximumEvents: Int
        let maximumBytes: Int
        let timeoutMilliseconds: Int
    }

    private(set) var calls: [Call] = []
    private var completion: CheckedContinuation<Void, Never>?

    func record(
        token: UUID,
        coordinate: Phase2ShellSurfaceCommandCoordinate,
        maximumEvents: Int,
        maximumBytes: Int,
        timeoutMilliseconds: Int
    ) -> Phase2ContinuousShellTranscriptController.PollDisposition {
        calls.append(.init(
            token: token,
            coordinate: coordinate,
            maximumEvents: maximumEvents,
            maximumBytes: maximumBytes,
            timeoutMilliseconds: timeoutMilliseconds
        ))
        if calls.count == 2 {
            completion?.resume()
            completion = nil
            return .retired
        }
        return .accepted
    }

    func waitForCompletion() async {
        if calls.count >= 2 { return }
        await withCheckedContinuation { completion = $0 }
    }
}

@MainActor
private final class Phase2ContinuousPollGate {
    private var started: Set<Phase2ShellSurfaceCommandCoordinate> = []
    private var startWaiters: [Phase2ShellSurfaceCommandCoordinate: CheckedContinuation<Void, Never>] = [:]
    private var releases: [Phase2ShellSurfaceCommandCoordinate: CheckedContinuation<Phase2ContinuousShellTranscriptController.PollDisposition, Never>] = [:]

    func poll(
        _ coordinate: Phase2ShellSurfaceCommandCoordinate
    ) async -> Phase2ContinuousShellTranscriptController.PollDisposition {
        started.insert(coordinate)
        startWaiters.removeValue(forKey: coordinate)?.resume()
        return await withCheckedContinuation { releases[coordinate] = $0 }
    }

    func waitUntilStarted(_ coordinate: Phase2ShellSurfaceCommandCoordinate) async {
        if started.contains(coordinate) { return }
        await withCheckedContinuation { startWaiters[coordinate] = $0 }
    }

    func release(
        _ coordinate: Phase2ShellSurfaceCommandCoordinate,
        disposition: Phase2ContinuousShellTranscriptController.PollDisposition
    ) {
        releases.removeValue(forKey: coordinate)?.resume(returning: disposition)
    }
}

@MainActor
private final class Phase2ContinuousHealthRecorder {
    private(set) var coordinates: [Phase2ShellSurfaceCommandCoordinate] = []
    private var waiter: CheckedContinuation<Void, Never>?

    func record(_ coordinate: Phase2ShellSurfaceCommandCoordinate) {
        coordinates.append(coordinate)
        waiter?.resume()
        waiter = nil
    }

    func waitForFailure() async {
        if !coordinates.isEmpty { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private actor Phase2ContinuousIdleGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var starters: [CheckedContinuation<Void, Never>] = []
    private(set) var duration: UInt64?
    private(set) var count = 0
    func record(_ duration: UInt64) { self.duration = duration; count += 1 }
    func wait(_ duration: UInt64) async {
        record(duration)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let pending = starters
            starters.removeAll()
            pending.forEach { $0.resume() }
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { starters.append($0) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
