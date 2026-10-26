import XCTest

@testable import MacScope

@MainActor
final class Phase2InstalledShellRendererPresentationTests: XCTestCase {
    private typealias Presentation = Phase2InstalledShellRendererPresentation

    func testFullSurfaceAdmissionReturnsExactLivePIDAndRealGenerationBinding() throws {
        let snapshot = runningSnapshot(pid: 4_201)
        let processCoordinate = Presentation.ProcessCoordinate(
            sessionID: snapshot.sessionID,
            requestID: requestID,
            processIdentifier: 4_201
        )
        let surfaceCoordinate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: snapshot.sessionID,
            requestID: requestID,
            generation: 19
        )
        let selection = Phase2TerminalRendererSelection(
            backend: .ghosttyFullSurface,
            fallback: nil
        )

        let mounted = try Presentation.admit(
            snapshot: snapshot,
            requestedMode: .defaultFullGhosttySurface,
            processCoordinate: processCoordinate,
            selection: selection,
            surfaceCoordinate: surfaceCoordinate
        )

        XCTAssertEqual(mounted.processCoordinate, processCoordinate)
        XCTAssertEqual(mounted.selection, selection)
        XCTAssertEqual(mounted.rendererBinding.sessionID, snapshot.sessionID)
        XCTAssertEqual(mounted.rendererBinding.requestID, requestID)
        XCTAssertEqual(mounted.rendererBinding.shellBrokerProcessIdentifier, 4_201)
        XCTAssertEqual(mounted.rendererBinding.generation, .exact(19))
    }

    func testForcedRecoveryAdmissionReturnsOnlyRealLegacyNotAllocatedBinding() throws {
        let snapshot = runningSnapshot(pid: 4_202)
        let processCoordinate = Presentation.ProcessCoordinate(
            sessionID: snapshot.sessionID,
            requestID: requestID,
            processIdentifier: 4_202
        )
        let selection = Phase2TerminalRendererSelection(
            backend: .macScopeGhosttyVTGrid,
            fallback: .recoveryOverride
        )

        let mounted = try Presentation.admit(
            snapshot: snapshot,
            requestedMode: .forcedLegacyGridRecoveryOverride,
            processCoordinate: processCoordinate,
            selection: selection,
            surfaceCoordinate: nil
        )

        XCTAssertEqual(mounted.processCoordinate, processCoordinate)
        XCTAssertEqual(mounted.selection, selection)
        XCTAssertEqual(mounted.rendererBinding.shellBrokerProcessIdentifier, 4_202)
        XCTAssertEqual(mounted.rendererBinding.generation, .notAllocated)
    }

    func testAdmissionRejectsInvalidOrStaleProcessCoordinates() {
        let snapshot = runningSnapshot(pid: 4_203)
        let fullSelection = Phase2TerminalRendererSelection(
            backend: .ghosttyFullSurface,
            fallback: nil
        )
        let surfaceCoordinate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: snapshot.sessionID,
            requestID: requestID,
            generation: 20
        )

        assertAdmissionError(.invalidProcessCoordinate) {
            try Presentation.admit(
                snapshot: snapshot,
                requestedMode: .defaultFullGhosttySurface,
                processCoordinate: .init(
                    sessionID: snapshot.sessionID,
                    requestID: requestID,
                    processIdentifier: 0
                ),
                selection: fullSelection,
                surfaceCoordinate: surfaceCoordinate
            )
        }
        assertAdmissionError(.snapshotCoordinateMismatch) {
            try Presentation.admit(
                snapshot: snapshot,
                requestedMode: .defaultFullGhosttySurface,
                processCoordinate: .init(
                    sessionID: snapshot.sessionID,
                    requestID: requestID,
                    processIdentifier: 4_204
                ),
                selection: fullSelection,
                surfaceCoordinate: surfaceCoordinate
            )
        }
        assertAdmissionError(.snapshotCoordinateMismatch) {
            try Presentation.admit(
                snapshot: snapshot,
                requestedMode: .defaultFullGhosttySurface,
                processCoordinate: .init(
                    sessionID: shellRendererPresentationUUID(3),
                    requestID: requestID,
                    processIdentifier: 4_203
                ),
                selection: fullSelection,
                surfaceCoordinate: surfaceCoordinate
            )
        }
    }

    func testRequestedModeCannotEchoSelectionOrPromoteTranscriptFallbackToProof() {
        let snapshot = runningSnapshot(pid: 4_205)
        let processCoordinate = Presentation.ProcessCoordinate(
            sessionID: snapshot.sessionID,
            requestID: requestID,
            processIdentifier: 4_205
        )
        let fullSelection = Phase2TerminalRendererSelection(
            backend: .ghosttyFullSurface,
            fallback: nil
        )
        let legacySelection = Phase2TerminalRendererSelection(
            backend: .macScopeGhosttyVTGrid,
            fallback: .recoveryOverride
        )
        let surfaceCoordinate = Phase2ShellSurfaceCommandCoordinate(
            sessionID: snapshot.sessionID,
            requestID: requestID,
            generation: 21
        )

        assertAdmissionError(.rendererSelectionMismatch) {
            try Presentation.admit(
                snapshot: snapshot,
                requestedMode: .defaultFullGhosttySurface,
                processCoordinate: processCoordinate,
                selection: legacySelection,
                surfaceCoordinate: surfaceCoordinate
            )
        }
        assertAdmissionError(.rendererSelectionMismatch) {
            try Presentation.admit(
                snapshot: snapshot,
                requestedMode: .forcedLegacyGridRecoveryOverride,
                processCoordinate: processCoordinate,
                selection: fullSelection,
                surfaceCoordinate: nil
            )
        }
        assertAdmissionError(.fullSurfaceBindingUnavailable) {
            try Presentation.admit(
                snapshot: snapshot,
                requestedMode: .defaultFullGhosttySurface,
                processCoordinate: processCoordinate,
                selection: fullSelection,
                surfaceCoordinate: nil
            )
        }
        assertAdmissionError(.legacySurfaceMustNotHaveGeneration) {
            try Presentation.admit(
                snapshot: snapshot,
                requestedMode: .forcedLegacyGridRecoveryOverride,
                processCoordinate: processCoordinate,
                selection: legacySelection,
                surfaceCoordinate: surfaceCoordinate
            )
        }

        let rejectedSnapshot = runningSnapshot(
            pid: 4_205,
            events: [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .broker,
                    payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 1)
                ),
            ]
        )
        assertAdmissionError(.transcriptCannotRenderRequestedBackend) {
            try Presentation.admit(
                snapshot: rejectedSnapshot,
                requestedMode: .defaultFullGhosttySurface,
                processCoordinate: processCoordinate,
                selection: fullSelection,
                surfaceCoordinate: surfaceCoordinate
            )
        }
        assertAdmissionError(.transcriptCannotRenderRequestedBackend) {
            try Presentation.admit(
                snapshot: rejectedSnapshot,
                requestedMode: .forcedLegacyGridRecoveryOverride,
                processCoordinate: processCoordinate,
                selection: legacySelection,
                surfaceCoordinate: nil
            )
        }
    }

    private let sessionID = shellRendererPresentationUUID(1)
    private let requestID = shellRendererPresentationUUID(2)

    private func runningSnapshot(
        pid: Int32,
        events: [Phase2HumanPTYTranscriptEvent]? = nil
    ) -> Phase2HumanPTYSessionSnapshot {
        Phase2HumanPTYSessionSnapshot(
            sessionID: sessionID,
            state: .running(requestID: requestID, processIdentifier: pid),
            launchPlan: nil,
            transcriptEvents: events ?? [
                Phase2HumanPTYTranscriptEvent(
                    sessionID: sessionID,
                    sequence: 1,
                    source: .broker,
                    payload: .output(stream: .standardOutput, bytes: Array("ready\n".utf8))
                ),
            ],
            issues: []
        )
    }

    private func assertAdmissionError(
        _ expected: Presentation.AdmissionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Presentation.MountedState
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? Presentation.AdmissionError, expected, file: file, line: line)
        }
    }
}

private func shellRendererPresentationUUID(_ value: UInt8) -> UUID {
    UUID(uuid: (
        value, value, value, value,
        value, value, value, value,
        value, value, value, value,
        value, value, value, value
    ))
}
