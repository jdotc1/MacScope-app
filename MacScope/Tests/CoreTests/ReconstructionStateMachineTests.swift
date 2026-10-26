import XCTest
@testable import MacScope

final class ReconstructionStateMachineTests: XCTestCase {
    func testHappyPathAndBoundedRoundTransitionsAreAccepted() throws {
        let transitions: [(ReconstructionJobState, ReconstructionJobState)] = [
            (.created, .ingesting),
            (.ingesting, .indexing),
            (.indexing, .retrieving),
            (.retrieving, .awaitingModel),
            (.awaitingModel, .executingReads),
            (.executingReads, .acceptingEvidence),
            (.acceptingEvidence, .checkpointing),
            (.checkpointing, .retrieving),
            (.retrieving, .completed)
        ]

        for (from, to) in transitions {
            XCTAssertNoThrow(
                try ReconstructionJobStateMachine.transition(
                    from: from,
                    to: to,
                    resumeTarget: nil
                ),
                "Expected \(from) -> \(to) to be accepted"
            )
        }
    }

    func testInvalidSkipsAndTerminalStateMutationAreRejected() {
        let transitions: [(ReconstructionJobState, ReconstructionJobState)] = [
            (.created, .indexing),
            (.ingesting, .awaitingModel),
            (.retrieving, .executingReads),
            (.completed, .retrieving),
            (.cancelled, .created),
            (.failed, .ingesting)
        ]

        for (from, to) in transitions {
            XCTAssertThrowsError(
                try ReconstructionJobStateMachine.transition(
                    from: from,
                    to: to,
                    resumeTarget: nil
                ),
                "Expected \(from) -> \(to) to be rejected"
            )
        }
    }

    func testActiveStatesMayPauseCancelOrFail() throws {
        for state in ReconstructionJobState.activeStates {
            XCTAssertNoThrow(
                try ReconstructionJobStateMachine.transition(
                    from: state,
                    to: .paused,
                    resumeTarget: state
                )
            )
            XCTAssertNoThrow(
                try ReconstructionJobStateMachine.transition(
                    from: state,
                    to: .cancelled,
                    resumeTarget: nil
                )
            )
            XCTAssertNoThrow(
                try ReconstructionJobStateMachine.transition(
                    from: state,
                    to: .failed,
                    resumeTarget: nil
                )
            )
        }
    }

    func testPausedResumeRequiresMatchingActiveTarget() throws {
        XCTAssertNoThrow(
            try ReconstructionJobStateMachine.transition(
                from: .paused,
                to: .retrieving,
                resumeTarget: .retrieving
            )
        )
        XCTAssertThrowsError(
            try ReconstructionJobStateMachine.transition(
                from: .paused,
                to: .retrieving,
                resumeTarget: .indexing
            )
        )
        XCTAssertThrowsError(
            try ReconstructionJobStateMachine.transition(
                from: .paused,
                to: .completed,
                resumeTarget: .completed
            )
        )
    }

    func testPausedJobsMayTerminateOnlyWhenResumeAuthorityIsCleared() throws {
        for terminalState in [ReconstructionJobState.cancelled, .failed] {
            XCTAssertNoThrow(
                try ReconstructionJobStateMachine.transition(
                    from: .paused,
                    to: terminalState,
                    resumeTarget: nil
                )
            )
            XCTAssertThrowsError(
                try ReconstructionJobStateMachine.transition(
                    from: .paused,
                    to: terminalState,
                    resumeTarget: .retrieving
                )
            )
        }
        XCTAssertThrowsError(
            try ReconstructionJobStateMachine.transition(
                from: .paused,
                to: .completed,
                resumeTarget: nil
            )
        )
    }

    func testTransitionMatrixIsExhaustive() {
        for from in ReconstructionJobState.allCases {
            for to in ReconstructionJobState.allCases {
                let resumeTarget: ReconstructionJobState? = if to == .paused {
                    from
                } else if from == .paused, ReconstructionJobState.activeStates.contains(to) {
                    to
                } else {
                    nil
                }
                let expected = Self.expectedTransition(from: from, to: to)
                if expected {
                    XCTAssertNoThrow(
                        try ReconstructionJobStateMachine.transition(
                            from: from,
                            to: to,
                            resumeTarget: resumeTarget
                        ),
                        "Expected \(from) -> \(to) to be allowed"
                    )
                } else {
                    XCTAssertThrowsError(
                        try ReconstructionJobStateMachine.transition(
                            from: from,
                            to: to,
                            resumeTarget: resumeTarget
                        ),
                        "Expected \(from) -> \(to) to be rejected"
                    )
                }
            }
        }
    }

    private static func expectedTransition(
        from: ReconstructionJobState,
        to: ReconstructionJobState
    ) -> Bool {
        if from == .paused {
            return ReconstructionJobState.activeStates.contains(to)
                || to == .cancelled
                || to == .failed
        }
        guard ReconstructionJobState.activeStates.contains(from) else { return false }
        if to == .paused || to == .cancelled || to == .failed { return true }
        return switch (from, to) {
        case (.created, .ingesting),
             (.ingesting, .indexing),
             (.indexing, .retrieving),
             (.retrieving, .awaitingModel),
             (.retrieving, .completed),
             (.awaitingModel, .executingReads),
             (.executingReads, .acceptingEvidence),
             (.acceptingEvidence, .checkpointing),
             (.checkpointing, .retrieving):
            true
        default:
            false
        }
    }
}
