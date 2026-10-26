import XCTest
@testable import MacScope

/// Source-owned bindings for the compact T10C vector set. This suite deliberately does not load
/// generated Python fixtures or reproduce the oracle's 2,448 advisory XCTest methods.
final class ReconstructionTask10OracleVectorTests: XCTestCase {
    func testPausedTerminalDeltaSeparatesDomainRetirementFromProductCommandAvailability() throws {
        for terminal in [ReconstructionJobState.cancelled, .failed] {
            XCTAssertNoThrow(
                try ReconstructionJobStateMachine.transition(
                    from: .paused,
                    to: terminal,
                    resumeTarget: nil
                ),
                "t10c.transition.paused.\(terminal.rawValue).none"
            )
        }

        let pauseContext = try ReconstructionJobPauseContext(
            cause: .pausedByUser,
            resumeTarget: .retrieving
        )
        let projection = ReconstructionStatusProjection.controlProjection(
            state: .paused,
            readiness: .ready(endpoint: "http://127.0.0.1:1234", model: "local-model"),
            pauseContext: pauseContext
        )
        XCTAssertTrue(
            projection.controls.canCancel,
            "T10A-P1-004: R1 stability explicitly admits Cancel for a durably paused job"
        )
        XCTAssertTrue(projection.controls.canResume)
        XCTAssertEqual(projection.controls.resumeTarget, .retrieving)
    }

    func testCreationVectorsBindWhitespaceAndClosedBudgetPolicy() throws {
        XCTAssertNil(
            ReconstructionJobCreationRequest.normalizedObjective(" \t\n "),
            "creation.whitespaceObjective.readiness.ready"
        )
        XCTAssertEqual(
            ReconstructionJobCreationRequest.normalizedObjective("  Recover\n selected\tcorpus  "),
            "Recover selected corpus"
        )

        let maximum = try ReconstructionJobBudget(
            maxRounds: ReconstructionNewJobBudgetPolicy.maxRounds.upperBound,
            maxTasks: ReconstructionNewJobBudgetPolicy.maxTasks.upperBound,
            maxEvidenceRecords: ReconstructionNewJobBudgetPolicy.maxEvidenceRecords.upperBound,
            maxEncodedBytes: ReconstructionNewJobBudgetPolicy.maxEncodedBytes.upperBound
        )
        XCTAssertTrue(
            ReconstructionNewJobBudgetPolicy.accepts(maximum),
            "creation.maximumBudget.readiness.ready"
        )
        let overflow = try ReconstructionJobBudget(
            maxRounds: ReconstructionNewJobBudgetPolicy.maxRounds.upperBound + 1,
            maxTasks: maximum.maxTasks,
            maxEvidenceRecords: maximum.maxEvidenceRecords,
            maxEncodedBytes: maximum.maxEncodedBytes
        )
        XCTAssertFalse(
            ReconstructionNewJobBudgetPolicy.accepts(overflow),
            "creation.overflowBudget.readiness.ready"
        )
    }

    func testClosedPresentationAndAccessibilityVectorsRemainBoundToCurrentSource() {
        XCTAssertEqual(
            ReconstructionCommandKind.allCases,
            [.create, .start, .pause, .resume, .cancel]
        )
        XCTAssertEqual(
            ReconstructionModelReadinessCase.allCases,
            [
                .endpointMissing, .inventoryRequired, .authenticationRequired, .unavailable,
                .incompatible, .reconciliationRequired, .selectionRequired,
                .selectionIdentityMismatch, .selectedModelMissing, .selectedModelNotLanguage,
                .loadRequired, .ready,
            ]
        )
        XCTAssertEqual(
            ReconstructionAccessibilityIdentifiers.orderedCatalog.map(\.identifier),
            [
                "reconstruction.destination", "reconstruction.dashboard",
                "reconstruction.job.identity", "reconstruction.job.state",
                "reconstruction.progress", "reconstruction.primaryAction",
                "reconstruction.pause", "reconstruction.resume", "reconstruction.cancel",
                "reconstruction.corpusSummary", "reconstruction.taskSummary",
                "reconstruction.evidenceSummary", "reconstruction.currentGap",
                "reconstruction.terminalNotice", "reconstruction.details",
                "reconstruction.inspector",
            ]
        )
        XCTAssertEqual(ReconstructionAccessibilityIdentifiers.orderedCatalog.map(\.focusOrder), Array(0..<16))
    }
}
