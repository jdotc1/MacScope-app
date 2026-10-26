#if MACSCOPE_LEGACY_GRID_ADVERSARIAL_HARNESS && canImport(GhosttyVt)
import AppKit
import Foundation

@main
struct Phase2GhosttyTerminalSurfaceAdversarialHarness {
    private struct Failure: Error {
        let scenario: String
    }

    @MainActor
    static func main() {
        do {
            try rawByteReplay()
            try evidenceRejection()
            try saturationBoundaries()
            try repeatedUpdateCoalescing()
            try replacementAndTeardown()
            print("legacy-grid-adversarial-harness: 5/5 passed")
        } catch let failure as Failure {
            fatalError("legacy-grid-adversarial-harness failed: \(failure.scenario)")
        } catch {
            fatalError("legacy-grid-adversarial-harness failed")
        }
    }

    @MainActor
    private static func rawByteReplay() throws {
        let sessionID = uuid(301)
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)
        let coordinator = makeCoordinator(sessionID, size: size)
        coordinator.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                output(sessionID, 1, [0xF0, 0x9F]),
                output(sessionID, 2, [0x99, 0x82]),
            ]
        )
        try require(coordinator.snapshot?.plainText == "🙂", "raw byte replay")
        try require(coordinator.acceptedByteCount == 4, "raw byte accounting")
    }

    @MainActor
    private static func evidenceRejection() throws {
        let sessionID = uuid(302)
        let foreignID = uuid(303)
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)

        let foreign = makeCoordinator(sessionID, size: size)
        foreign.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [output(sessionID, 1, [65]), output(foreignID, 2, [66])]
        )
        try require(foreign.snapshot == nil && foreign.model == nil, "cross-session rejection")

        let reordered = makeCoordinator(sessionID, size: size)
        reordered.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [output(sessionID, 2, [66]), output(sessionID, 1, [65])]
        )
        try require(reordered.snapshot == nil, "reordered rejection")

        let gapped = makeCoordinator(sessionID, size: size)
        gapped.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [
                output(sessionID, 1, [65]),
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 2,
                    source: .broker,
                    payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 1)
                ),
            ]
        )
        try require(gapped.snapshot == nil, "explicit gap rejection")

        let replayed = makeCoordinator(sessionID, size: size)
        let complete = [output(sessionID, 1, [65]), output(sessionID, 2, [66])]
        replayed.update(sessionID: sessionID, terminalSize: size, transcriptEvents: complete)
        try require(replayed.snapshot != nil, "replay fixture admission")
        replayed.update(sessionID: sessionID, terminalSize: size, transcriptEvents: [complete[0]])
        try require(replayed.snapshot == nil && replayed.model == nil, "stale replay rejection")
        replayed.update(sessionID: sessionID, terminalSize: size, transcriptEvents: [complete[0]])
        try require(
            replayed.snapshot == nil && replayed.acceptedEventCount == complete.count,
            "repeated stale replay resurrection"
        )

        let mutated = [output(sessionID, 1, [88]), complete[1]]
        replayed.update(sessionID: sessionID, terminalSize: size, transcriptEvents: mutated)
        replayed.update(sessionID: sessionID, terminalSize: size, transcriptEvents: mutated)
        try require(
            replayed.snapshot == nil && replayed.acceptedEventCount == complete.count,
            "repeated mutated-prefix resurrection"
        )
        replayed.update(sessionID: sessionID, terminalSize: size, transcriptEvents: complete)
        try require(replayed.snapshot?.plainText == "AB", "exact transcript rebuild after rejection")
    }

    @MainActor
    private static func saturationBoundaries() throws {
        let sessionID = uuid(304)
        let size = Phase2HumanPTYTerminalSize(columns: 4, rows: 2)
        let limits = Phase2GhosttyTerminalSurface.Coordinator.Limits(
            maximumEvents: 2,
            maximumEventBytes: 2,
            maximumCumulativeBytes: 3,
            maximumColumns: 4,
            maximumRows: 3,
            maximumCells: 8
        )
        let boundary = makeCoordinator(sessionID, size: size, limits: limits)
        boundary.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [output(sessionID, 1, [65, 66]), output(sessionID, 2, [67])]
        )
        try require(boundary.snapshot != nil && boundary.acceptedByteCount == 3, "exact budget boundary")

        let excessiveBytes = makeCoordinator(sessionID, size: size, limits: limits)
        excessiveBytes.update(
            sessionID: sessionID,
            terminalSize: size,
            transcriptEvents: [output(sessionID, 1, [65, 66, 67])]
        )
        try require(excessiveBytes.snapshot == nil, "byte saturation")

        let excessiveCells = makeCoordinator(sessionID, size: size, limits: limits)
        excessiveCells.update(
            sessionID: sessionID,
            terminalSize: .init(columns: 4, rows: 3),
            transcriptEvents: [output(sessionID, 1, [65])]
        )
        try require(excessiveCells.snapshot == nil, "cell saturation")
    }

    @MainActor
    private static func repeatedUpdateCoalescing() throws {
        let sessionID = uuid(305)
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)
        let coordinator = makeCoordinator(sessionID, size: size)
        let transcript = [output(sessionID, 1, Array("bounded".utf8))]
        coordinator.update(sessionID: sessionID, terminalSize: size, transcriptEvents: transcript)
        for _ in 0..<1_000 {
            coordinator.update(sessionID: sessionID, terminalSize: size, transcriptEvents: transcript)
        }
        try require(coordinator.appliedBatchCount == 1, "single applied batch")
        try require(coordinator.appliedEventCount == 1, "single applied event")
        try require(coordinator.coalescedUpdateCount == 1_000, "bounded coalescing")
    }

    @MainActor
    private static func replacementAndTeardown() throws {
        let firstID = uuid(306)
        let secondID = uuid(307)
        let size = Phase2HumanPTYTerminalSize(columns: 8, rows: 2)
        let coordinator = makeCoordinator(firstID, size: size)
        coordinator.update(
            sessionID: firstID,
            terminalSize: size,
            transcriptEvents: [output(firstID, 1, Array("first".utf8))]
        )
        weak let replacedModel = coordinator.model
        coordinator.update(
            sessionID: secondID,
            terminalSize: size,
            transcriptEvents: [output(secondID, 1, Array("second".utf8))]
        )
        try require(replacedModel == nil, "session replacement release")

        let view = Phase2GhosttyTerminalGridView()
        view.snapshot = coordinator.snapshot
        view.keyEventHandler = { _ in }
        weak let dismantledModel = coordinator.model
        Phase2GhosttyTerminalSurface.dismantleNSView(view, coordinator: coordinator)
        try require(dismantledModel == nil, "dismantle model release")
        try require(coordinator.isRetired && coordinator.model == nil, "dismantle retirement")
        try require(view.snapshot == nil && view.keyEventHandler == nil, "dismantle callback release")
    }

    @MainActor
    private static func makeCoordinator(
        _ sessionID: UUID,
        size: Phase2HumanPTYTerminalSize,
        limits: Phase2GhosttyTerminalSurface.Coordinator.Limits = .production
    ) -> Phase2GhosttyTerminalSurface.Coordinator {
        Phase2GhosttyTerminalSurface.Coordinator(
            sessionID: sessionID,
            terminalSize: size,
            limits: limits
        )
    }

    private static func output(
        _ sessionID: UUID,
        _ sequence: UInt64,
        _ bytes: [UInt8]
    ) -> Phase2HumanPTYTranscriptEvent {
        Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: sequence,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: bytes)
        )
    }

    private static func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ scenario: String) throws {
        guard condition() else { throw Failure(scenario: scenario) }
    }
}
#elseif MACSCOPE_LEGACY_GRID_COMPILE_DISABLED_HARNESS
import Foundation

@main
struct Phase2GhosttyTerminalSurfaceCompileDisabledHarness {
    static func main() {
        precondition(!Phase2GhosttyLegacyGridCompilation.isAvailable)
        print("legacy-grid-compile-disabled-harness: fail-closed passed")
    }
}
#endif
