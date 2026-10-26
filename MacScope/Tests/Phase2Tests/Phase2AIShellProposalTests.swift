import XCTest
@testable import MacScope

final class Phase2AIShellProposalTests: XCTestCase {
    func testUTF8TruncationIncludesMarkerWithinExactByteBudget() {
        let text = String(repeating: "é🧭", count: 100)

        for maximumBytes in 0...80 {
            let truncated = Phase2AIShellOneShotExecutionResult.truncatedUTF8(
                text,
                maximumBytes: maximumBytes
            )
            XCTAssertLessThanOrEqual(truncated.utf8.count, maximumBytes)
            XCTAssertNotNil(truncated.data(using: .utf8))
        }

        let exactBudget = 36
        let truncated = Phase2AIShellOneShotExecutionResult.truncatedUTF8(
            text,
            maximumBytes: exactBudget
        )
        XCTAssertEqual(truncated.utf8.count, exactBudget)
        XCTAssertTrue(truncated.hasSuffix("\n[truncated by MacScope]"))
        XCTAssertEqual(
            Phase2AIShellOneShotExecutionResult.truncatedUTF8("unchanged", maximumBytes: 0),
            ""
        )
        XCTAssertEqual(
            Phase2AIShellOneShotExecutionResult.truncatedUTF8("unchanged", maximumBytes: -1),
            ""
        )
    }
    func testControlledDebuggerAuthorityAllowsRunControlWithoutBreakpointMutation() {
        let policy = Phase2DebuggerAuthorityToolPolicy.controlledRuntimeActions

        XCTAssertEqual(policy.authority, .controlledRuntimeActions)
        XCTAssertTrue(policy.allowFrames)
        XCTAssertTrue(policy.allowRegisters)
        XCTAssertTrue(policy.allowVariables)
        XCTAssertTrue(policy.allowMemoryRead)
        XCTAssertTrue(policy.allowRunControl)
        XCTAssertFalse(policy.allowBreakpointMutation)
        XCTAssertTrue(policy.isStructurallyValid)
    }

    func testControlledDebuggerAuthorityRejectsBreakpointMutationCapability() {
        let malformedPolicy = Phase2DebuggerAuthorityToolPolicy(
            authority: .controlledRuntimeActions,
            allowFrames: true,
            allowRegisters: true,
            allowVariables: true,
            allowMemoryRead: true,
            allowRunControl: true,
            allowBreakpointMutation: true
        )

        XCTAssertFalse(malformedPolicy.isStructurallyValid)
    }

    @MainActor
    func testWorkspaceStoreStagesAcceptedDebuggerProposalForReviewWithoutExecutionAuthority() {
        let store = makeStore()
        let proposal = Phase2AIDebuggerActionProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000090")!,
            action: .stepOver,
            sessionID: UUID(uuidString: "30000000-0000-0000-0000-000000000091")!,
            lifecycleRevision: 2,
            stopRevision: 1,
            eventSequence: 3,
            requestedAuthority: .controlledRuntimeActions
        )

        let review = store.stagePhase2AIDebuggerProposalForReview(proposal)

        XCTAssertEqual(review.disposition, .staged)
        XCTAssertEqual(review.humanDecision, .pendingReview)
        XCTAssertEqual(store.phase2AIDebuggerProposalReview, review)
        XCTAssertEqual(review.title, "Debugger proposal ready for review")
        XCTAssertTrue(review.validationResult.isAccepted)
        XCTAssertTrue(review.canApproveForFutureDebuggerControl)
        XCTAssertFalse(review.canExecuteDebuggerControl)
        XCTAssertTrue(review.authoritySummary.contains("no direct model LLDB command execution"))
        XCTAssertFalse(store.isDirty)

        let approved = store.approvePhase2AIDebuggerProposalForFutureControl(
            proposalID: proposal.proposalID
        )
        XCTAssertEqual(approved.humanDecision, .approvedForFutureDebuggerControl)
        XCTAssertTrue(approved.canExecuteDebuggerControl)
        XCTAssertTrue(approved.reviewPlainTextExport?.contains("- Can execute: yes") == true)

        store.dismissPhase2AIDebuggerProposalReview(proposalID: proposal.proposalID)
        XCTAssertEqual(store.phase2AIDebuggerProposalReview, .inactive)
    }

    func testDebuggerProposalValidationRejectsUnscopedStoppedAction() {
        let proposal = Phase2AIDebuggerActionProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000092")!,
            action: .continueExecution,
            sessionID: UUID(uuidString: "30000000-0000-0000-0000-000000000093")!,
            lifecycleRevision: 2,
            stopRevision: nil,
            eventSequence: 3,
            requestedAuthority: .controlledRuntimeActions
        )

        let review = Phase2AIDebuggerProposalReviewState.review(proposal: proposal)

        XCTAssertEqual(review.disposition, .rejected)
        XCTAssertEqual(review.humanDecision, .blockedByValidation)
        XCTAssertFalse(review.validationResult.isAccepted)
        XCTAssertEqual(review.validationResult.issues, [.missingStopCoordinate])
        XCTAssertFalse(review.canApproveForFutureDebuggerControl)
        XCTAssertFalse(review.canExecuteDebuggerControl)
    }

    @MainActor
    func testApprovedDebuggerProposalDispatchesThroughAppOwnedViewModel() async throws {
        let sessionID = UUID(uuidString: "30000000-0000-0000-0000-000000000094")!
        let executor = RecordingDebuggerProposalExecutor(
            snapshot: Self.phase2PausedDebuggerSnapshot(sessionID: sessionID)
        )
        let store = makeStore()
        let proposal = Phase2AIDebuggerActionProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000095")!,
            action: .stepOver,
            sessionID: sessionID,
            lifecycleRevision: 2,
            stopRevision: 1,
            eventSequence: 3,
            requestedAuthority: .controlledRuntimeActions
        )
        let review = store.stagePhase2AIDebuggerProposalForReview(proposal)
        let approved = store.approvePhase2AIDebuggerProposalForFutureControl(
            proposalID: proposal.proposalID
        )

        XCTAssertEqual(review.disposition, .staged)
        XCTAssertTrue(approved.canExecuteDebuggerControl)
        let result = await store.executeApprovedPhase2AIDebuggerProposalControl(
            proposalID: proposal.proposalID,
            executor: executor
        )

        XCTAssertEqual(result.disposition, .dispatched)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(executor.recordedActions, [.stepOver])
        XCTAssertEqual(store.phase2AIDebuggerProposalExecutionResults, [result])
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.surfaces, [.debuggerControl])
        XCTAssertEqual(
            store.phase2RuntimeAuthorityRecords.first?.debuggerAuthorityPolicy,
            .controlledRuntimeActions
        )
        let evidence = try XCTUnwrap(store.phase2ProviderVisibleDebuggerControlEvidenceText())
        XCTAssertTrue(evidence.contains("[") == false)
        XCTAssertTrue(evidence.contains("Debugger control execution 1:"), evidence)
        XCTAssertTrue(evidence.contains("Action: Step Over"), evidence)
        XCTAssertTrue(evidence.contains("Disposition: dispatched"), evidence)
        XCTAssertTrue(evidence.contains("Runtime session ID: \(sessionID.uuidString)"), evidence)
        XCTAssertTrue(evidence.contains("Lifecycle revision: 2"), evidence)
        XCTAssertTrue(evidence.contains("Stop revision: 1"), evidence)
        XCTAssertTrue(evidence.contains("Event sequence: 3"), evidence)
    }

    @MainActor
    func testApprovedDebuggerProposalRejectsStaleRuntimeCoordinateWithoutDispatch() async {
        let sessionID = UUID(uuidString: "30000000-0000-0000-0000-000000000096")!
        let executor = RecordingDebuggerProposalExecutor(
            snapshot: Self.phase2PausedDebuggerSnapshot(sessionID: sessionID)
        )
        let store = makeStore()
        let proposal = Phase2AIDebuggerActionProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000097")!,
            action: .stepOver,
            sessionID: sessionID,
            lifecycleRevision: 2,
            stopRevision: 1,
            eventSequence: 4,
            requestedAuthority: .controlledRuntimeActions
        )
        _ = store.stagePhase2AIDebuggerProposalForReview(proposal)
        let approved = store.approvePhase2AIDebuggerProposalForFutureControl(
            proposalID: proposal.proposalID
        )

        XCTAssertTrue(approved.canExecuteDebuggerControl)
        let result = await store.executeApprovedPhase2AIDebuggerProposalControl(
            proposalID: proposal.proposalID,
            executor: executor
        )

        XCTAssertEqual(result.disposition, .staleDebuggerCoordinate)
        XCTAssertTrue(result.failureMessage?.contains("event sequence changed") == true)
        XCTAssertEqual(executor.recordedActions, [])
        XCTAssertNil(store.phase2ProviderVisibleDebuggerControlEvidenceText())
    }

    @MainActor
    func testApprovedDebuggerProposalRejectsUncorrelatedRuntimeEvent() async {
        let sessionID = UUID(uuidString: "30000000-0000-0000-0000-000000000098")!
        let executor = RecordingDebuggerProposalExecutor(
            snapshot: Self.phase2PausedDebuggerSnapshot(sessionID: sessionID)
        )
        executor.returnsMismatchedCorrelation = true
        let store = makeStore()
        let proposal = Phase2AIDebuggerActionProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000099")!,
            action: .stepOver,
            sessionID: sessionID,
            lifecycleRevision: 2,
            stopRevision: 1,
            eventSequence: 3
        )
        _ = store.stagePhase2AIDebuggerProposalForReview(proposal)
        _ = store.approvePhase2AIDebuggerProposalForFutureControl(proposalID: proposal.proposalID)

        let result = await store.executeApprovedPhase2AIDebuggerProposalControl(
            proposalID: proposal.proposalID,
            executor: executor
        )

        XCTAssertEqual(result.disposition, .failed)
        XCTAssertTrue(result.failureMessage?.contains("correlation") == true)
        XCTAssertNil(store.phase2ProviderVisibleDebuggerControlEvidenceText())
    }

    @MainActor
    func testWorkspaceStoreStagesAcceptedProposalForReviewWithoutExecutionAuthority() throws {
        let store = makeStore()
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000010")!,
            executablePath: "/usr/bin/file",
            arguments: ["/tmp/MacScope Fixture"],
            environment: ["LC_ALL": "C"],
            workingDirectoryPath: "/tmp",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 4_096,
            requestedEffects: [.a5]
        )

        let review = store.stagePhase2AIShellProposalForReview(proposal)

        XCTAssertEqual(review.disposition, .staged)
        XCTAssertEqual(review.humanDecision, .pendingReview)
        XCTAssertEqual(review.humanDecisionSummary, "pending review")
        XCTAssertEqual(store.phase2AIShellProposalReview, review)
        XCTAssertEqual(review.title, "Shell proposal ready for review")
        XCTAssertEqual(review.argvPreview, "\"/usr/bin/file\" \"/tmp/MacScope Fixture\"")
        XCTAssertEqual(review.environmentPreview, ["\"LC_ALL\"=\"C\""])
        XCTAssertEqual(review.workingDirectoryPreview, "\"/tmp\"")
        XCTAssertEqual(review.limitsPreview, "timeout 2000 ms · output 4096 bytes")
        XCTAssertEqual(review.issueSummaries, [])
        XCTAssertEqual(
            review.authoritySummary,
            "exact .a5 restricted one-shot process only; no ShellBroker PTY, human PTY, debugger, network, credential, or mutation authority"
        )
        XCTAssertTrue(review.canCopyArgv)
        XCTAssertTrue(review.canCopyReview)
        XCTAssertTrue(review.canCopyReviewJSON)
        XCTAssertTrue(review.canApproveForFutureOneShot)
        XCTAssertFalse(review.canApproveForFutureShellBrokerPTY)
        XCTAssertTrue(review.canRejectByUser)
        XCTAssertFalse(review.canExecute)
        XCTAssertFalse(store.isDirty)

        let reviewExport = try XCTUnwrap(review.reviewPlainTextExport)
        XCTAssertTrue(reviewExport.hasPrefix("MacScope AI Shell Proposal Review"))
        XCTAssertTrue(reviewExport.contains("- Disposition: staged"))
        XCTAssertTrue(reviewExport.contains("- Proposal ID: 30000000-0000-0000-0000-000000000010"))
        XCTAssertTrue(reviewExport.contains("- Command: \"/usr/bin/file\" \"/tmp/MacScope Fixture\""))
        XCTAssertTrue(reviewExport.contains("- Working directory: \"/tmp\""))
        XCTAssertTrue(reviewExport.contains("- Limits: timeout 2000 ms · output 4096 bytes"))
        XCTAssertTrue(reviewExport.contains("- Execution surface: restrictedOneShotJob"))
        XCTAssertTrue(reviewExport.contains("- Requested effects: A5"))
        XCTAssertTrue(reviewExport.contains("- Human decision: pending review"))
        XCTAssertTrue(reviewExport.contains("- Authority: exact .a5 restricted one-shot process only"))
        XCTAssertTrue(reviewExport.contains("- Can execute: no"))
        XCTAssertTrue(reviewExport.contains("  - \"LC_ALL\"=\"C\""))
        XCTAssertTrue(reviewExport.contains("- Validation issues: none"))
        XCTAssertTrue(reviewExport.contains("no ShellBroker PTY"))

        let reviewJSON = try XCTUnwrap(review.reviewJSONExport)
        XCTAssertTrue(reviewJSON.contains("\"disposition\" : \"staged\""))
        XCTAssertTrue(reviewJSON.contains("\"proposalID\" : \"30000000-0000-0000-0000-000000000010\""))
        XCTAssertTrue(reviewJSON.contains("\"canExecute\" : false"))
        XCTAssertTrue(reviewJSON.contains("\"command\" : ["))
        XCTAssertTrue(reviewJSON.contains("\"/usr/bin/file\""))
        XCTAssertTrue(reviewJSON.contains("\"/tmp/MacScope Fixture\""))
        XCTAssertTrue(reviewJSON.contains("\"workingDirectoryPath\" : \"/tmp\""))
        XCTAssertTrue(reviewJSON.contains("\"executionSurface\" : \"restrictedOneShotJob\""))
        XCTAssertTrue(reviewJSON.contains("\"humanDecision\" : \"pending review\""))
        XCTAssertTrue(reviewJSON.contains("\"requestedEffects\" : ["))
        XCTAssertTrue(reviewJSON.contains("\"A5\""))
        XCTAssertTrue(reviewJSON.contains("\"key\" : \"LC_ALL\""))
        XCTAssertTrue(reviewJSON.contains("\"value\" : \"C\""))
        XCTAssertTrue(reviewJSON.contains("\"validationIssues\" : ["))
    }

    @MainActor
    func testWorkspaceStoreRejectsInvalidProposalAsReviewableNoAuthorityState() throws {
        let store = makeStore()
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000011")!,
            executablePath: "relative-tool",
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 4_096,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5, .a8]
        )

        let review = store.stagePhase2AIShellProposalForReview(proposal)

        XCTAssertEqual(review.disposition, .rejected)
        XCTAssertEqual(review.humanDecision, .blockedByValidation)
        XCTAssertEqual(review.humanDecisionSummary, "blocked by validation")
        XCTAssertEqual(store.phase2AIShellProposalReview, review)
        XCTAssertEqual(review.title, "Shell proposal rejected")
        XCTAssertEqual(review.authoritySummary, "no authority granted")
        XCTAssertFalse(review.canCopyArgv)
        XCTAssertTrue(review.canCopyReview)
        XCTAssertTrue(review.canCopyReviewJSON)
        XCTAssertFalse(review.canApproveForFutureOneShot)
        XCTAssertFalse(review.canApproveForFutureShellBrokerPTY)
        XCTAssertTrue(review.canRejectByUser)
        XCTAssertFalse(review.canExecute)
        XCTAssertEqual(review.rejectedIssueCount, 2)
        XCTAssertEqual(review.argvPreview, "\"relative-tool\"")
        XCTAssertNil(review.workingDirectoryPreview)
        XCTAssertEqual(review.limitsPreview, "timeout 2000 ms · output 4096 bytes")
        XCTAssertTrue(review.validationResult.issues.contains(.executablePathNotAbsolute("relative-tool")))
        XCTAssertTrue(review.validationResult.issues.contains(.disallowedAuthority(.a8)))
        XCTAssertTrue(review.issueSummaries.contains("Executable path is not absolute: relative-tool"))
        XCTAssertTrue(review.issueSummaries.contains("Effect A8 is not allowed for AI shell proposals."))
        XCTAssertFalse(store.isDirty)

        let rejectedExport = try XCTUnwrap(review.reviewPlainTextExport)
        XCTAssertTrue(rejectedExport.contains("- Disposition: rejected"))
        XCTAssertTrue(rejectedExport.contains("- Command: \"relative-tool\""))
        XCTAssertTrue(rejectedExport.contains("- Human decision: blocked by validation"))
        XCTAssertTrue(rejectedExport.contains("- Authority: no authority granted"))
        XCTAssertTrue(rejectedExport.contains("- Can execute: no"))
        XCTAssertTrue(rejectedExport.contains("  - Executable path is not absolute: relative-tool"))
        XCTAssertTrue(rejectedExport.contains("  - Effect A8 is not allowed for AI shell proposals."))

        let rejectedJSON = try XCTUnwrap(review.reviewJSONExport)
        XCTAssertTrue(rejectedJSON.contains("\"disposition\" : \"rejected\""))
        XCTAssertTrue(rejectedJSON.contains("\"command\" : ["))
        XCTAssertTrue(rejectedJSON.contains("\"relative-tool\""))
        XCTAssertTrue(rejectedJSON.contains("\"authority\" : \"no authority granted\""))
        XCTAssertTrue(rejectedJSON.contains("\"humanDecision\" : \"blocked by validation\""))
        XCTAssertTrue(rejectedJSON.contains("\"canExecute\" : false"))
        XCTAssertTrue(rejectedJSON.contains("\"Effect A8 is not allowed for AI shell proposals.\""))
    }

    @MainActor
    func testWorkspaceStoreRecordsHumanApprovalForValidProposalWithoutExecutionAuthority() throws {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000014")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/usr/bin/true",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(proposal)

        let mismatched = store.approvePhase2AIShellProposalForFutureOneShot(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000015")!
        )
        XCTAssertEqual(mismatched.humanDecision, .pendingReview)

        let approved = store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)

        XCTAssertEqual(approved.disposition, .staged)
        XCTAssertEqual(approved.humanDecision, .approvedForFutureOneShot)
        XCTAssertEqual(approved.humanDecisionSummary, "approved for future restricted one-shot")
        XCTAssertEqual(approved.title, "Shell proposal approved for future one-shot review")
        XCTAssertFalse(approved.canApproveForFutureOneShot)
        XCTAssertFalse(approved.canApproveForFutureShellBrokerPTY)
        XCTAssertTrue(approved.canRejectByUser)
        XCTAssertTrue(approved.canExecute)
        XCTAssertFalse(store.isDirty)
        XCTAssertTrue(try XCTUnwrap(approved.reviewPlainTextExport).contains(
            "- Human decision: approved for future restricted one-shot"
        ))
        XCTAssertTrue(try XCTUnwrap(approved.reviewJSONExport).contains(
            "\"humanDecision\" : \"approved for future restricted one-shot\""
        ))
        XCTAssertTrue(try XCTUnwrap(approved.reviewJSONExport).contains("\"canExecute\" : true"))
    }

    @MainActor
    func testWorkspaceStoreRecordsHumanRejectionAndPreventsLaterApproval() {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000016")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["do-not-run"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(proposal)

        let rejected = store.rejectPhase2AIShellProposalReviewByUser(proposalID: proposalID)

        XCTAssertEqual(rejected.disposition, .staged)
        XCTAssertEqual(rejected.humanDecision, .rejectedByUser)
        XCTAssertEqual(rejected.title, "Shell proposal rejected by user")
        XCTAssertFalse(rejected.canApproveForFutureOneShot)
        XCTAssertFalse(rejected.canApproveForFutureShellBrokerPTY)
        XCTAssertFalse(rejected.canRejectByUser)
        XCTAssertFalse(rejected.canExecute)

        let laterApproval = store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)

        XCTAssertEqual(laterApproval.humanDecision, .rejectedByUser)
        XCTAssertFalse(laterApproval.canExecute)
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testWorkspaceStoreRecordsHumanApprovalForShellBrokerPTYProposalWithoutExecuting() throws {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000019")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["pty-ready"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )

        let staged = store.stagePhase2AIShellProposalForReview(proposal)

        XCTAssertEqual(staged.disposition, .staged)
        XCTAssertEqual(staged.humanDecision, .pendingReview)
        XCTAssertFalse(staged.canApproveForFutureOneShot)
        XCTAssertTrue(staged.canApproveForFutureShellBrokerPTY)
        XCTAssertFalse(staged.canExecute)
        XCTAssertEqual(
            staged.authoritySummary,
            "exact .a5 app-mediated ShellBroker PTY transport request only; no direct model PTY ownership, human PTY ownership, debugger, network, credential, or mutation authority"
        )
        XCTAssertTrue(try XCTUnwrap(staged.reviewPlainTextExport).contains(
            "- Execution surface: shellBrokerPTY"
        ))

        let mismatched = store.approvePhase2AIShellProposalForFutureShellBrokerPTY(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000020")!
        )
        XCTAssertEqual(mismatched.humanDecision, .pendingReview)

        let approved = store.approvePhase2AIShellProposalForFutureShellBrokerPTY(proposalID: proposalID)

        XCTAssertEqual(approved.disposition, .staged)
        XCTAssertEqual(approved.humanDecision, .approvedForFutureShellBrokerPTY)
        XCTAssertEqual(approved.humanDecisionSummary, "approved for future ShellBroker PTY transport")
        XCTAssertEqual(approved.title, "Shell proposal approved for future ShellBroker PTY transport")
        XCTAssertFalse(approved.canApproveForFutureOneShot)
        XCTAssertFalse(approved.canApproveForFutureShellBrokerPTY)
        XCTAssertTrue(approved.canRejectByUser)
        XCTAssertFalse(approved.canExecute)
        XCTAssertTrue(approved.canExecuteShellBrokerPTY)
        XCTAssertFalse(store.isDirty)
        XCTAssertTrue(try XCTUnwrap(approved.reviewPlainTextExport).contains(
            "- Human decision: approved for future ShellBroker PTY transport"
        ))
        XCTAssertTrue(try XCTUnwrap(approved.reviewPlainTextExport).contains(
            "- Can execute ShellBroker PTY: yes"
        ))
        XCTAssertTrue(try XCTUnwrap(approved.reviewJSONExport).contains(
            "\"humanDecision\" : \"approved for future ShellBroker PTY transport\""
        ))
        XCTAssertTrue(try XCTUnwrap(approved.reviewJSONExport).contains("\"canExecute\" : false"))
        XCTAssertTrue(try XCTUnwrap(approved.reviewJSONExport).contains("\"canExecuteShellBrokerPTY\" : true"))
    }

    @MainActor
    func testWorkspaceStoreDoesNotApproveValidationRejectedProposal() {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000017")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "relative-tool",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .debuggerConsole,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(proposal)

        let attemptedApproval = store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)

        XCTAssertEqual(attemptedApproval.disposition, .rejected)
        XCTAssertEqual(attemptedApproval.humanDecision, .blockedByValidation)
        XCTAssertFalse(attemptedApproval.canApproveForFutureOneShot)
        XCTAssertFalse(attemptedApproval.canApproveForFutureShellBrokerPTY)
        XCTAssertFalse(attemptedApproval.canExecute)

        let userRejected = store.rejectPhase2AIShellProposalReviewByUser(proposalID: proposalID)

        XCTAssertEqual(userRejected.disposition, .rejected)
        XCTAssertEqual(userRejected.humanDecision, .rejectedByUser)
        XCTAssertFalse(userRejected.canApproveForFutureOneShot)
        XCTAssertFalse(userRejected.canApproveForFutureShellBrokerPTY)
        XCTAssertFalse(userRejected.canExecute)
        XCTAssertFalse(store.isDirty)
    }

    @MainActor
    func testWorkspaceStoreDismissesOnlyMatchingStagedProposal() {
        let store = makeStore()
        let stagedID = UUID(uuidString: "30000000-0000-0000-0000-000000000012")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: stagedID,
            executablePath: "/bin/echo",
            arguments: ["ready"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        store.stagePhase2AIShellProposalForReview(proposal)

        store.dismissPhase2AIShellProposalReview(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000013")!
        )
        XCTAssertEqual(store.phase2AIShellProposalReview.proposal?.proposalID, stagedID)

        store.dismissPhase2AIShellProposalReview(proposalID: stagedID)

        XCTAssertEqual(store.phase2AIShellProposalReview, .inactive)
        XCTAssertNil(store.phase2AIShellProposalReview.reviewPlainTextExport)
        XCTAssertNil(store.phase2AIShellProposalReview.reviewJSONExport)
    }

    func testValidatorAcceptsExactRestrictedOneShotProcessProposal() {
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            executablePath: "/usr/bin/otool",
            arguments: ["-l", "/tmp/MacScopeFixture"],
            environment: ["LC_ALL": "C"],
            workingDirectoryPath: "/tmp",
            timeoutMilliseconds: 5_000,
            maximumOutputBytes: 65_536,
            executionSurface: .restrictedOneShotJob,
            requestedEffects: [.a5]
        )

        XCTAssertTrue(Phase2AIShellProposalValidator.validate(proposal).isAccepted)
    }

    func testValidatorAcceptsAppMediatedShellBrokerPTYProposal() {
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000021")!,
            executablePath: "/bin/echo",
            arguments: ["hello"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            executionSurface: .shellBrokerPTY,
            requestedEffects: [.a5]
        )

        XCTAssertTrue(Phase2AIShellProposalValidator.validate(proposal).isAccepted)
    }

    func testValidatorRejectsHumanPTYAndDebuggerConsoleForAIProposal() {
        let baseID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        for surface in [
            Phase2AIShellExecutionSurface.humanPTYSession,
            .debuggerConsole,
        ] {
            let proposal = Phase2AIShellCommandProposal(
                proposalID: baseID,
                executablePath: "/bin/echo",
                arguments: ["hello"],
                timeoutMilliseconds: 1_000,
                maximumOutputBytes: 1_024,
                executionSurface: surface,
                requestedEffects: [.a5]
            )

            XCTAssertEqual(
                Phase2AIShellProposalValidator.validate(proposal).issues,
                [.unsupportedExecutionSurface(surface)]
            )
        }
    }

    func testValidatorRejectsUnboundedOrNonExactCommandInputs() {
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            executablePath: "bin/sh\u{0}",
            arguments: ["-c", "echo bad\u{0}"],
            environment: [
                "": "empty",
                "BAD=KEY": "value",
                "BAD_VALUE": "value\u{0}",
            ],
            workingDirectoryPath: "relative\u{0}",
            timeoutMilliseconds: 0,
            maximumOutputBytes: Phase2AIShellProposalValidator.maximumOutputBytes + 1,
            executionSurface: .restrictedOneShotJob,
            requestedEffects: [.a1]
        )

        let issues = Phase2AIShellProposalValidator.validate(proposal).issues

        XCTAssertTrue(issues.contains(.proposalIDNil))
        XCTAssertTrue(issues.contains(.executablePathNotAbsolute("bin/sh\u{0}")))
        XCTAssertTrue(issues.contains(.executablePathContainsNUL))
        XCTAssertTrue(issues.contains(.argumentContainsNUL(index: 1)))
        XCTAssertTrue(issues.contains(.environmentKeyEmpty))
        XCTAssertTrue(issues.contains(.environmentKeyContainsInvalidCharacter("BAD=KEY")))
        XCTAssertTrue(issues.contains(.environmentValueContainsNUL(key: "BAD_VALUE")))
        XCTAssertTrue(issues.contains(.workingDirectoryNotAbsolute("relative\u{0}")))
        XCTAssertTrue(issues.contains(.workingDirectoryContainsNUL))
        XCTAssertTrue(issues.contains(.invalidTimeout(milliseconds: 0)))
        XCTAssertTrue(issues.contains(.invalidOutputLimit(
            bytes: Phase2AIShellProposalValidator.maximumOutputBytes + 1
        )))
        XCTAssertTrue(issues.contains(.missingProcessAuthority))
        XCTAssertTrue(issues.contains(.disallowedAuthority(.a1)))
    }

    func testValidatorRejectsArgumentsAndEnvironmentPastDeclaredCaps() {
        let tooManyArguments = Array(
            repeating: "x",
            count: Phase2AIShellProposalValidator.maximumArguments + 1
        )
        var oversizedEnvironment: [String: String] = [:]
        for index in 0...Phase2AIShellProposalValidator.maximumEnvironmentEntries {
            oversizedEnvironment["KEY_\(index)"] = "value"
        }

        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000004")!,
            executablePath: "/bin/echo",
            arguments: tooManyArguments,
            environment: oversizedEnvironment,
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )

        let issues = Phase2AIShellProposalValidator.validate(proposal).issues
        XCTAssertTrue(issues.contains(.tooManyArguments(
            count: Phase2AIShellProposalValidator.maximumArguments + 1,
            maximum: Phase2AIShellProposalValidator.maximumArguments
        )))
        XCTAssertTrue(issues.contains(.tooManyEnvironmentEntries(
            count: Phase2AIShellProposalValidator.maximumEnvironmentEntries + 1,
            maximum: Phase2AIShellProposalValidator.maximumEnvironmentEntries
        )))
    }

    func testValidatorRejectsNetworkDebuggerCredentialAndMutationAuthority() {
        for effect in [Phase2EffectClass.a3, .a4, .a6, .a7, .a8, .a9] {
            let proposal = Phase2AIShellCommandProposal(
                proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
                executablePath: "/bin/echo",
                arguments: ["authority"],
                timeoutMilliseconds: 1_000,
                maximumOutputBytes: 1_024,
                requestedEffects: [.a5, effect]
            )

            XCTAssertTrue(
                Phase2AIShellProposalValidator.validate(proposal).issues.contains(
                    .disallowedAuthority(effect)
                )
            )
        }
    }

    @MainActor
    func testWorkspaceStoreExecutesOnlyApprovedOneShotProposalThroughInjectedExecutor() async {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000018")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["approved"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        let executor = RecordingOneShotExecutor()

        let blocked = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: proposalID,
            executor: executor
        )
        XCTAssertEqual(blocked.disposition, .authorizationRejected)
        let blockedRecordedIDs = await executor.recordedProposalIDs()
        XCTAssertEqual(blockedRecordedIDs, [])

        store.stagePhase2AIShellProposalForReview(proposal)
        let stillBlocked = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: proposalID,
            executor: executor
        )
        XCTAssertEqual(stillBlocked.disposition, .authorizationRejected)
        let stillBlockedRecordedIDs = await executor.recordedProposalIDs()
        XCTAssertEqual(stillBlockedRecordedIDs, [])

        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)
        let result = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: proposalID,
            executor: executor
        )

        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(result.proposalID, proposalID)
        XCTAssertEqual(result.standardOutput, "approved\n")
        let executedRecordedIDs = await executor.recordedProposalIDs()
        XCTAssertEqual(executedRecordedIDs, [proposalID])
        XCTAssertEqual(store.phase2AIShellOneShotExecutionResults.map(\.proposalID), [
            proposalID,
            proposalID,
            proposalID,
        ])
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, 3)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.map(\.sessionID), [
            result.id,
            stillBlocked.id,
            blocked.id,
        ])
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.map(\.providerVisibleShellExecutionEnabled), [
            true,
            false,
            false,
        ])
        XCTAssertTrue(store.phase2RuntimeAuthorityRecords.allSatisfy {
            $0.surfaces == [.providerVisibleShellExecution]
                && $0.terminalBackend == .ghosttyLib
                && $0.ptyReusePolicy == .disabled
                && $0.debuggerAuthorityPolicy == .disabled
        })
        XCTAssertTrue(store.isDirty)
    }

    @MainActor
    func testWorkspaceStoreBindsApprovedOneShotToReservedExecutionIdentity() async {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000118")!
        let executionID = UUID(uuidString: "30000000-0000-0000-0000-000000000119")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["reserved"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        let executor = RecordingOneShotExecutor()
        store.stagePhase2AIShellProposalForReview(proposal)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)

        let result = await store.executeApprovedPhase2AIShellProposalOneShot(
            expectedProposal: proposal,
            reservedExecutionID: executionID,
            executor: executor
        )

        XCTAssertEqual(result.id, executionID)
        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(store.phase2AIShellProposalReview.humanDecision, .consumed)
        XCTAssertEqual(store.phase2AIShellOneShotExecutionResults.first?.id, executionID)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.sessionID, executionID)
        XCTAssertEqual(
            store.phase2RuntimeAuthorityRecords.first?.providerVisibleShellExecutionEnabled,
            true
        )
    }

    @MainActor
    func testWorkspaceStoreRejectsReusedProposalIDWithChangedContentBeforeExecution() async {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000218")!
        let executionID = UUID(uuidString: "30000000-0000-0000-0000-000000000219")!
        let approved = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["approved"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        let swapped = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/usr/bin/false",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        let executor = RecordingOneShotExecutor()
        store.stagePhase2AIShellProposalForReview(swapped)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)

        let result = await store.executeApprovedPhase2AIShellProposalOneShot(
            expectedProposal: approved,
            reservedExecutionID: executionID,
            executor: executor
        )

        XCTAssertEqual(result.disposition, .authorizationRejected)
        let recordedProposalIDs = await executor.recordedProposalIDs()
        XCTAssertEqual(recordedProposalIDs, [])
        XCTAssertEqual(store.phase2AIShellProposalReview.humanDecision, .approvedForFutureOneShot)
        XCTAssertTrue(store.phase2AIShellOneShotExecutionResults.isEmpty)
        XCTAssertTrue(store.phase2RuntimeAuthorityRecords.isEmpty)
    }

    @MainActor
    func testWorkspaceStoreRejectsMismatchedApprovedOneShotProposalIDWithoutRunning() async {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000019")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["approved"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        let executor = RecordingOneShotExecutor()
        store.stagePhase2AIShellProposalForReview(proposal)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)

        let result = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000020")!,
            executor: executor
        )

        XCTAssertEqual(result.disposition, .authorizationRejected)
        XCTAssertEqual(result.proposalID, proposalID)
        let recordedIDs = await executor.recordedProposalIDs()
        XCTAssertEqual(recordedIDs, [])
        XCTAssertEqual(store.phase2AIShellOneShotExecutionResults.map(\.disposition), [
            .authorizationRejected,
        ])
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.count, 1)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.sessionID, result.id)
        XCTAssertEqual(store.phase2RuntimeAuthorityRecords.first?.providerVisibleShellExecutionEnabled, false)
        XCTAssertTrue(store.isDirty)
    }

    @MainActor
    func testWorkspaceStorePersistsRuntimeAuthorityRecordsFromApprovedOneShotShellExecution() async throws {
        let store = makeStore()
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000025")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["approved"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        let executor = RecordingOneShotExecutor()

        store.stagePhase2AIShellProposalForReview(proposal)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)
        let result = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: proposalID,
            executor: executor
        )
        let persisted = try store.saveWorkspace(
            to: database,
            now: Date(timeIntervalSince1970: 6_000),
            documentID: UUID(uuidString: "20000000-0000-0000-0000-000000000025")!
        )
        let persistedWorkspaceID = try XCTUnwrap(persisted.workspace.id)
        let reopened = try XCTUnwrap(WorkspaceStore.restored(workspaceID: persistedWorkspaceID, from: database))

        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(reopened.phase2RuntimeAuthorityRecords.count, 1)
        let authorityRecord = try XCTUnwrap(reopened.phase2RuntimeAuthorityRecords.first)
        XCTAssertEqual(authorityRecord.workspaceID, persistedWorkspaceID)
        XCTAssertEqual(authorityRecord.workspaceUUID, reopened.workspaceID)
        XCTAssertEqual(authorityRecord.sessionID, result.id)
        XCTAssertEqual(authorityRecord.surfaces, [.providerVisibleShellExecution])
        XCTAssertEqual(authorityRecord.terminalBackend, .ghosttyLib)
        XCTAssertEqual(authorityRecord.ptyReusePolicy, .disabled)
        XCTAssertEqual(authorityRecord.debuggerAuthorityPolicy, .disabled)
        XCTAssertTrue(authorityRecord.providerVisibleShellExecutionEnabled)
        XCTAssertTrue(authorityRecord.authorityRecord.isStructurallyValid)
    }

    func testOneShotExecutorRunsBoundedProcessAndCapturesOutput() async {
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000021")!,
            executablePath: "/bin/echo",
            arguments: ["hello"],
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )

        let result = await Phase2AIShellOneShotExecutor().run(proposal)

        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.standardOutput, "hello\n")
        XCTAssertEqual(result.standardError, "")
        XCTAssertFalse(result.outputWasTruncated)
        XCTAssertNil(result.failureMessage)
    }

    func testOneShotExecutorAppliesOneSharedBudgetAcrossStandardStreams() async {
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000121")!,
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 12345; printf 67890 >&2"],
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 7,
            requestedEffects: [.a5]
        )

        let result = await Phase2AIShellOneShotExecutor().run(proposal)

        XCTAssertEqual(result.disposition, .completed)
        XCTAssertLessThanOrEqual(
            result.standardOutput.utf8.count + result.standardError.utf8.count,
            proposal.maximumOutputBytes
        )
        XCTAssertTrue(result.outputWasTruncated)
    }

    @MainActor
    func testApprovedOneShotProposalIsConsumedBeforeAwaitAndCannotReplay() async {
        let store = makeStore()
        let proposalID = UUID(uuidString: "30000000-0000-0000-0000-000000000122")!
        let proposal = Phase2AIShellCommandProposal(
            proposalID: proposalID,
            executablePath: "/bin/echo",
            arguments: ["once"],
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )
        let executor = SuspendedOneShotExecutor()
        store.stagePhase2AIShellProposalForReview(proposal)
        store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)

        let firstTask = Task { @MainActor in
            await store.executeApprovedPhase2AIShellProposalOneShot(
                proposalID: proposalID,
                executor: executor
            )
        }
        await executor.waitUntilStarted()
        XCTAssertEqual(store.phase2AIShellProposalReview.humanDecision, .executingOneShot)
        let replay = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: proposalID,
            executor: executor
        )
        await executor.release()
        let first = await firstTask.value

        XCTAssertEqual(first.disposition, .completed)
        XCTAssertEqual(replay.disposition, .authorizationRejected)
        let recordedAfterReplay = await executor.recordedProposalIDs()
        XCTAssertEqual(recordedAfterReplay, [proposalID])
        XCTAssertEqual(store.phase2AIShellProposalReview.humanDecision, .consumed)

        let reapproved = store.approvePhase2AIShellProposalForFutureOneShot(proposalID: proposalID)
        XCTAssertEqual(reapproved.humanDecision, .approvedForFutureOneShot)
        let retryExecutor = RecordingOneShotExecutor()
        _ = await store.executeApprovedPhase2AIShellProposalOneShot(
            proposalID: proposalID,
            executor: retryExecutor
        )
        let recordedAfterFreshApproval = await retryExecutor.recordedProposalIDs()
        XCTAssertEqual(recordedAfterFreshApproval, [proposalID])
    }

    @MainActor
    func testOneShotExecutionResultHistoryIsBoundedPerWorkspace() async {
        let store = makeStore()
        let executor = RecordingOneShotExecutor()

        for index in 0...Phase2AIShellExecutionResultRetention.maximumResults {
            _ = await store.executeApprovedPhase2AIShellProposalOneShot(
                proposalID: UUID(),
                executor: executor
            )
            XCTAssertLessThanOrEqual(
                store.phase2AIShellOneShotExecutionResults.count,
                Phase2AIShellExecutionResultRetention.maximumResults,
                "overflow at index \(index)"
            )
        }
    }

    func testOneShotExecutorRejectsInvalidProposalBeforeLaunch() async {
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000022")!,
            executablePath: "relative",
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )

        let result = await Phase2AIShellOneShotExecutor().run(proposal)

        XCTAssertEqual(result.disposition, .validationRejected)
        XCTAssertNil(result.terminationStatus)
        XCTAssertTrue(result.failureMessage?.contains("Executable path is not absolute") == true)
    }

    func testOneShotExecutorEnforcesOutputCap() async {
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000023")!,
            executablePath: "/usr/bin/printf",
            arguments: ["abcdef"],
            timeoutMilliseconds: 2_000,
            maximumOutputBytes: 3,
            requestedEffects: [.a5]
        )

        let result = await Phase2AIShellOneShotExecutor().run(proposal)

        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(result.standardOutput, "abc")
        XCTAssertTrue(result.outputWasTruncated)
    }

    func testOneShotExecutorEnforcesTimeout() async {
        let proposal = Phase2AIShellCommandProposal(
            proposalID: UUID(uuidString: "30000000-0000-0000-0000-000000000024")!,
            executablePath: "/bin/sleep",
            arguments: ["2"],
            timeoutMilliseconds: 100,
            maximumOutputBytes: 1_024,
            requestedEffects: [.a5]
        )

        let result = await Phase2AIShellOneShotExecutor().run(proposal)

        XCTAssertEqual(result.disposition, .timedOut)
        XCTAssertTrue(result.failureMessage?.contains("timeout") == true)
    }

    @MainActor
    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(
            workspaceName: "AI Shell Proposal",
            snapshot: WorkspaceSnapshot(
                binaries: [],
                functions: [],
                instructions: [],
                xrefs: [],
                hexBytes: Data()
            ),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
    }

    private static func phase2PausedDebuggerSnapshot(sessionID: UUID) -> DebuggerSessionSnapshot {
        let coordinate = DebuggerSessionCoordinate(
            epoch: DebuggerSessionEpoch(rawValue: sessionID),
            lifecycleRevision: DebuggerLifecycleRevision(rawValue: 2)
        )
        return DebuggerSessionSnapshot(
            processState: .paused(processID: 4242, reason: .breakpoint(address: 0x1000)),
            breakpoints: [],
            frames: [
                DebuggerFrameSummary(
                    index: 0,
                    address: 0x1000,
                    functionName: "main",
                    moduleName: "fixture",
                    sourceLocation: nil
                ),
            ],
            registers: [],
            memoryRegions: [],
            statusMessage: "Paused.",
            backendState: .connected(processID: 4242, adapterName: "Stub LLDB"),
            transportSessionCoordinate: coordinate,
            transportStopCoordinate: DebuggerStopCoordinate(
                session: coordinate,
                stopRevision: DebuggerStopRevision(rawValue: 1)
            ),
            transportEventSequence: DebuggerEventSequence(rawValue: 3),
            transportTargetDisposition: .stopped(processID: 4242)
        )
    }
}

@MainActor
private final class RecordingDebuggerProposalExecutor: Phase2AIDebuggerProposalExecuting {
    var phase2CurrentDebuggerSnapshot: DebuggerSessionSnapshot
    private(set) var recordedActions: [Phase2AIDebuggerAction] = []
    var unavailableReason: String?
    var returnsMismatchedCorrelation = false

    init(snapshot: DebuggerSessionSnapshot) {
        self.phase2CurrentDebuggerSnapshot = snapshot
    }

    func phase2DebuggerControlUnavailableReason(for action: Phase2AIDebuggerAction) -> String? {
        _ = action
        return unavailableReason
    }

    func phase2ExecuteDebuggerProposalAction(
        _ request: Phase2AIDebuggerProposalExecutionRequest
    ) async -> DebuggerControlledRuntimeActionEvent? {
        let action = request.action
        recordedActions.append(action)
        return DebuggerControlledRuntimeActionEvent(
            correlationID: returnsMismatchedCorrelation ? UUID() : request.executionID,
            sequence: UInt64(recordedActions.count),
            action: action.testDebuggerControlAction,
            snapshot: phase2CurrentDebuggerSnapshot
        )
    }
}

private extension Phase2AIDebuggerAction {
    var testDebuggerControlAction: DebuggerControlAction {
        switch self {
        case .continueExecution: .continueExecution
        case .stepOver: .stepOver
        case .stepInto: .stepInto
        case .stepOut: .stepOut
        case .pause: .pause
        case .refreshSnapshot: .refreshSnapshot
        }
    }
}

private actor RecordingOneShotExecutor: Phase2AIShellOneShotExecuting {
    private var proposals: [Phase2AIShellCommandProposal] = []

    func run(_ proposal: Phase2AIShellCommandProposal) async -> Phase2AIShellOneShotExecutionResult {
        proposals.append(proposal)
        let now = Date()
        return Phase2AIShellOneShotExecutionResult(
            proposalID: proposal.proposalID,
            executablePath: proposal.executablePath,
            arguments: proposal.arguments,
            workingDirectoryPath: proposal.workingDirectoryPath,
            timeoutMilliseconds: proposal.timeoutMilliseconds,
            maximumOutputBytes: proposal.maximumOutputBytes,
            disposition: .completed,
            terminationStatus: 0,
            standardOutput: "approved\n",
            standardError: "",
            outputWasTruncated: false,
            startedAt: now,
            completedAt: now,
            failureMessage: nil
        )
    }

    func recordedProposalIDs() -> [UUID] {
        proposals.map(\.proposalID)
    }
}

private actor SuspendedOneShotExecutor: Phase2AIShellOneShotExecuting {
    private var proposals: [Phase2AIShellCommandProposal] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var executionContinuation: CheckedContinuation<Void, Never>?

    func run(_ proposal: Phase2AIShellCommandProposal) async -> Phase2AIShellOneShotExecutionResult {
        proposals.append(proposal)
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            executionContinuation = continuation
        }
        let now = Date()
        return Phase2AIShellOneShotExecutionResult(
            proposalID: proposal.proposalID,
            executablePath: proposal.executablePath,
            arguments: proposal.arguments,
            workingDirectoryPath: proposal.workingDirectoryPath,
            timeoutMilliseconds: proposal.timeoutMilliseconds,
            maximumOutputBytes: proposal.maximumOutputBytes,
            disposition: .completed,
            terminationStatus: 0,
            standardOutput: "approved\n",
            standardError: "",
            outputWasTruncated: false,
            startedAt: now,
            completedAt: now,
            failureMessage: nil
        )
    }

    func waitUntilStarted() async {
        guard proposals.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        executionContinuation?.resume()
        executionContinuation = nil
    }

    func recordedProposalIDs() -> [UUID] {
        proposals.map(\.proposalID)
    }
}
