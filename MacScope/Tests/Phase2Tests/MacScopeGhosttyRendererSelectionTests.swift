import XCTest

@testable import MacScope

final class MacScopeGhosttyRendererSelectionTests: XCTestCase {
    private let sessionID = UUID(
        uuidString: "50000000-0000-0000-0000-000000000001"
    )!
    private let requestID = UUID(
        uuidString: "60000000-0000-0000-0000-000000000001"
    )!
    private let shellBrokerProcessIdentifier: Int32 = 6_262

    func testReadyQualifiedRuntimeSelectsFullSurface() {
        let feature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: nil
        )
        XCTAssertEqual(
            Phase2TerminalRendererSelection.resolve(feature: feature, runtimeState: .ready),
            .init(backend: .ghosttyFullSurface, fallback: nil)
        )
    }

    func testCompileRecoveryAndRuntimeFailuresSelectLegacyGrid() {
        let unavailable = MacScopeGhosttySurfaceFeature(
            compileAvailability: .unavailable,
            recoveryDefaultsObject: nil
        )
        let recovery = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: true
        )
        let available = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: nil
        )

        XCTAssertEqual(
            Phase2TerminalRendererSelection.resolve(feature: unavailable, runtimeState: .ready),
            .init(backend: .macScopeGhosttyVTGrid, fallback: .compileTimeUnavailable)
        )
        XCTAssertEqual(
            Phase2TerminalRendererSelection.resolve(feature: recovery, runtimeState: .ready),
            .init(backend: .macScopeGhosttyVTGrid, fallback: .recoveryOverride)
        )
        XCTAssertEqual(
            Phase2TerminalRendererSelection.resolve(feature: available, runtimeState: .notStarted),
            .init(backend: .macScopeGhosttyVTGrid, fallback: .runtimeUnavailable)
        )
        XCTAssertEqual(
            Phase2TerminalRendererSelection.resolve(feature: available, runtimeState: .failed(.health)),
            .init(backend: .macScopeGhosttyVTGrid, fallback: .runtimeFailure)
        )
    }

    func testFullSurfacePresentationProducesExactInstantiationEvidence() {
        let selection = Phase2TerminalRendererSelection(
            backend: .ghosttyFullSurface,
            fallback: nil
        )
        let resolution = Phase2TerminalSurfacePresentation.renderingResolution(
            rendererSelection: selection,
            fullSurfaceAvailable: true,
            fullSurfaceFallbackReason: .none,
            sessionID: sessionID,
            events: [outputEvent()]
        )
        XCTAssertEqual(resolution, .init(path: .ghosttyFullSurface, fallbackReason: .none))

        let observation = Phase2TerminalRendererEvidence.observation(
            binding: .init(
                sessionID: sessionID,
                requestID: requestID,
                shellBrokerProcessIdentifier: shellBrokerProcessIdentifier,
                generation: .exact(3)
            )!,
            selection: selection,
            observedMode: .ghosttyFullSurface,
            fallbackReason: resolution.fallbackReason
        )
        XCTAssertEqual(observation.requestedMode, .ghosttyFullSurface)
        XCTAssertEqual(observation.observedMode, .ghosttyFullSurface)
        XCTAssertEqual(observation.fallbackReason, .none)
    }

    func testForcedLegacyGridIsNotReportedAsTranscriptFallback() {
        let selection = Phase2TerminalRendererSelection(
            backend: .macScopeGhosttyVTGrid,
            fallback: .recoveryOverride
        )
        let resolution = Phase2TerminalSurfacePresentation.renderingResolution(
            rendererSelection: selection,
            fullSurfaceAvailable: false,
            fullSurfaceFallbackReason: .none,
            sessionID: sessionID,
            events: [outputEvent()]
        )
        XCTAssertEqual(resolution.path, .ghostty(sessionID))
        XCTAssertEqual(resolution.fallbackReason, .recoveryOverride)

        let observation = Phase2TerminalRendererEvidence.observation(
            binding: .init(
                sessionID: sessionID,
                requestID: requestID,
                shellBrokerProcessIdentifier: shellBrokerProcessIdentifier,
                generation: .notAllocated
            )!,
            selection: selection,
            observedMode: .macScopeGhosttyVTGrid,
            fallbackReason: resolution.fallbackReason
        )
        XCTAssertEqual(observation.requestedMode, .macScopeGhosttyVTGrid)
        XCTAssertEqual(observation.observedMode, .macScopeGhosttyVTGrid)
        XCTAssertEqual(observation.fallbackReason, .recoveryOverride)
    }

    func testLegacyTranscriptSelectionUsesSessionAuthorityWithoutSyntheticCoordinate() {
        XCTAssertEqual(
            Phase2GhosttyTranscriptAdmissionState.replay(
                sessionID: sessionID,
                events: [outputEvent()]
            ),
            .complete
        )
        XCTAssertEqual(
            Phase2GhosttyTranscriptAdmissionState.replay(
                sessionID: sessionID,
                events: []
            ),
            .fallback(.emptyReplay)
        )
    }

    func testIntrinsicFullSurfaceFallbackReasonRemainsInResolution() {
        let selection = Phase2TerminalRendererSelection(
            backend: .ghosttyFullSurface,
            fallback: nil
        )
        XCTAssertEqual(
            Phase2TerminalSurfacePresentation.renderingResolution(
                rendererSelection: selection,
                fullSurfaceAvailable: false,
                fullSurfaceFallbackReason: .fullSurfaceFactoryUnavailable,
                sessionID: sessionID,
                events: [outputEvent()]
            ),
            .init(
                path: .ghostty(sessionID),
                fallbackReason: .fullSurfaceFactoryUnavailable
            )
        )
    }

    func testRejectedTranscriptNormalizesContentFreeFallbackReason() {
        let selection = Phase2TerminalRendererSelection(
            backend: .ghosttyFullSurface,
            fallback: nil
        )
        let gap = Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .gap(reason: .spoolLimitExceeded, lostByteCount: 99)
        )
        let resolution = Phase2TerminalSurfacePresentation.renderingResolution(
            rendererSelection: selection,
            fullSurfaceAvailable: false,
            fullSurfaceFallbackReason: .transcriptRejected,
            sessionID: sessionID,
            events: [gap]
        )
        XCTAssertEqual(
            resolution,
            .init(path: .transcriptFallback, fallbackReason: .transcriptRejected)
        )

        let observation = Phase2TerminalRendererEvidence.observation(
            binding: .init(
                sessionID: sessionID,
                requestID: requestID,
                shellBrokerProcessIdentifier: shellBrokerProcessIdentifier,
                generation: .exact(4)
            )!,
            selection: selection,
            observedMode: .transcriptOnlyFallback,
            fallbackReason: resolution.fallbackReason
        )
        XCTAssertEqual(observation.observedMode, .transcriptOnlyFallback)
        XCTAssertEqual(observation.fallbackReason, .transcriptRejected)
    }

    func testRendererEvidenceBindingUsesExactRunningShellBrokerCoordinate() {
        let binding = Phase2TerminalRendererEvidence.binding(
            sessionID: sessionID,
            requestID: requestID,
            rendererGeneration: 9,
            lifecycleState: .running(
                requestID: requestID,
                processIdentifier: shellBrokerProcessIdentifier
            ),
            observedMode: .ghosttyFullSurface
        )
        XCTAssertEqual(
            binding,
            .init(
                sessionID: sessionID,
                requestID: requestID,
                shellBrokerProcessIdentifier: shellBrokerProcessIdentifier,
                generation: .exact(9)
            )
        )

        XCTAssertNil(Phase2TerminalRendererEvidence.binding(
            sessionID: sessionID,
            requestID: requestID,
            rendererGeneration: 9,
            lifecycleState: .prepared(requestID: requestID),
            observedMode: .ghosttyFullSurface
        ))
        XCTAssertNil(Phase2TerminalRendererEvidence.binding(
            sessionID: sessionID,
            requestID: requestID,
            rendererGeneration: 9,
            lifecycleState: .running(
                requestID: UUID(),
                processIdentifier: shellBrokerProcessIdentifier
            ),
            observedMode: .ghosttyFullSurface
        ))
        XCTAssertNil(Phase2TerminalRendererEvidence.binding(
            sessionID: sessionID,
            requestID: requestID,
            rendererGeneration: 9,
            lifecycleState: .running(requestID: requestID, processIdentifier: 0),
            observedMode: .ghosttyFullSurface
        ))
        XCTAssertNil(Phase2TerminalRendererEvidence.binding(
            sessionID: sessionID,
            requestID: requestID,
            rendererGeneration: nil,
            lifecycleState: .running(
                requestID: requestID,
                processIdentifier: shellBrokerProcessIdentifier
            ),
            observedMode: .ghosttyFullSurface
        ))
    }

    func testLegacyEvidenceUsesNotAllocatedOnlyForActualGrid() {
        let lifecycle = Phase2HumanPTYSessionState.running(
            requestID: requestID,
            processIdentifier: shellBrokerProcessIdentifier
        )
        let legacy = Phase2TerminalRendererEvidence.binding(
            sessionID: sessionID,
            requestID: requestID,
            rendererGeneration: 11,
            lifecycleState: lifecycle,
            observedMode: .macScopeGhosttyVTGrid
        )
        XCTAssertEqual(legacy?.generation, .notAllocated)
        XCTAssertEqual(
            legacy?.shellBrokerProcessIdentifier,
            shellBrokerProcessIdentifier
        )
        XCTAssertNil(Phase2TerminalRendererEvidence.binding(
            sessionID: sessionID,
            requestID: requestID,
            rendererGeneration: nil,
            lifecycleState: lifecycle,
            observedMode: .transcriptOnlyFallback
        ))
    }

    private func outputEvent() -> Phase2HumanPTYTranscriptEvent {
        Phase2HumanPTYTranscriptEvent(
            sessionID: sessionID,
            sequence: 1,
            source: .broker,
            payload: .output(stream: .standardOutput, bytes: [0x41])
        )
    }
}
