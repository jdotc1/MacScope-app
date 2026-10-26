import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ReconstructionPresentationContractTests: XCTestCase {
    private let commandScopeID = presentationID(999)
    private let ready = ReconstructionModelReadinessProjection.ready(
        endpoint: "http://127.0.0.1:1234",
        model: "local-model"
    )

    func testProductCommandCatalogIsExactlyTheFiveFrozenTask10Controls() {
        XCTAssertEqual(
            ReconstructionCommandKind.allCases,
            [.create, .start, .pause, .resume, .cancel]
        )
        XCTAssertEqual(
            ReconstructionCommandKind.allCases.map(\.label),
            ["Create", "Start", "Pause", "Resume", "Cancel"]
        )
    }

    func testDashboardDispatcherInvokesOnlyTheExactInjectedCommandClosure() {
        var fired: [ReconstructionCommandKind] = []
        let dispatcher = ReconstructionDashboardCommandDispatcher(
            onCreate: { fired.append(.create) },
            onStart: { fired.append(.start) },
            onPause: { fired.append(.pause) },
            onResume: { fired.append(.resume) },
            onCancel: { fired.append(.cancel) }
        )

        for command in ReconstructionCommandKind.allCases {
            fired.removeAll()
            XCTAssertTrue(dispatcher.dispatch(command))
            XCTAssertEqual(fired, [command])
        }

        let unavailable = ReconstructionDashboardCommandDispatcher(
            onCreate: nil,
            onStart: nil,
            onPause: nil,
            onResume: nil,
            onCancel: nil
        )
        for command in ReconstructionCommandKind.allCases {
            XCTAssertFalse(unavailable.dispatch(command))
        }
    }

    func testDashboardAccessibilityAggregatesPreserveRelationsEvidenceAndGapIdentity() {
        let corpus = ReconstructionCorpusSummary(
            occurrenceCount: 7,
            uniqueContentCount: 5,
            relationCount: 3,
            unresolvedRelationCount: 2
        )
        XCTAssertEqual(
            ReconstructionDashboardView.corpusAccessibilityValue(corpus),
            "7 occurrences, 5 unique content items, 3 relations, 2 unresolved relations"
        )

        let evidence = ReconstructionEvidenceSummary(counts: [
            .acceptedCurrent: 4,
            .acceptedHistorical: 3,
            .staleArtifact: 2,
            .staleAnalysis: 1,
            .unavailable: 2,
            .failed: 1,
        ])
        XCTAssertEqual(
            ReconstructionDashboardView.evidenceAccessibilityValue(evidence),
            "4 current, 3 historical, 3 stale, 3 unavailable"
        )

        let operationID = "reconstruction.evidence.query.v1"
        let currentGap = ReconstructionStatusGapProjection(
            status: .current,
            operationID: operationID,
            reason: "Current evidence remains incomplete."
        )
        XCTAssertEqual(
            ReconstructionDashboardView.currentGapAccessibilityValue(currentGap),
            "Current evidence remains incomplete. Operation \(operationID)"
        )
        XCTAssertEqual(
            ReconstructionDashboardView.currentGapAccessibilityValue(.init(
                status: .stale,
                operationID: operationID,
                reason: "No current unresolved gap."
            )),
            "No current unresolved gap."
        )
        XCTAssertEqual(
            ReconstructionDashboardView.currentGapAccessibilityValue(.init(
                status: .current,
                operationID: "unsafe\noperation",
                reason: "Current evidence remains incomplete."
            )),
            "Current evidence remains incomplete."
        )

        // Mutation RED: omit relationCount, any evidence classification aggregate, or the exact
        // operation ID from its helper. The corresponding exact equality above fails while the
        // other two independent aggregates remain green.
    }

    func testSourceNavigationRefusalNoticeIsBoundedAndDoesNotDiscloseMutableAuthority() {
        let errors: [ReconstructionSourceNavigationError?] = [
            .workspaceMismatch,
            .workspaceStateInvalid,
            .projectUnavailable,
            .currentManifestUnavailable,
            .artifactOutsideCurrentManifest,
            .functionAuthorityMismatch,
            .addressUnavailable,
            nil,
        ]
        let notices = errors.map {
            WorkspaceRootView.reconstructionSourceNavigationRefusal(for: $0)
        }
        XCTAssertEqual(Set(notices.map(\.title)), ["Source reveal refused"])
        XCTAssertTrue(notices.allSatisfy { $0.tone == .warning })
        XCTAssertEqual(Set(notices.map(\.detail)).count, 1)
        let detail = notices[0].detail
        XCTAssertLessThanOrEqual(detail.utf8.count, 192)
        XCTAssertTrue(detail.contains("No source navigation was performed."))
        for forbidden in ["UUID", "SHA256", "0x", "/", "workspaceMismatch"] {
            XCTAssertFalse(detail.contains(forbidden), forbidden)
        }

        // Mutation RED: interpolate the typed error into the detail or remove the bounded generic
        // fallback. Equality/privacy assertions fail without requiring a live navigation target.
    }

    func testFocusedWindowRoutingHonorsLiveAvailabilityWithoutCrossWindowDispatch() throws {
        func controls(enabling command: ReconstructionCommandKind) throws
            -> ReconstructionControlProjection {
            switch command {
            case .create:
                ReconstructionStatusProjection.controlProjection(
                    state: .completed,
                    readiness: ready
                ).controls
            case .start:
                ReconstructionStatusProjection.controlProjection(
                    state: .created,
                    readiness: ready
                ).controls
            case .pause, .cancel:
                ReconstructionStatusProjection.controlProjection(
                    state: .retrieving,
                    readiness: ready
                ).controls
            case .resume:
                ReconstructionStatusProjection.controlProjection(
                    state: .paused,
                    readiness: ready,
                    pauseContext: try ReconstructionJobPauseContext(
                        cause: .pausedByUser,
                        resumeTarget: .retrieving
                    )
                ).controls
            }
        }

        var firstWindowEvents: [ReconstructionCommandKind] = []
        var siblingWindowEvents: [ReconstructionCommandKind] = []
        let firstDispatcher = ReconstructionDashboardCommandDispatcher(
            onCreate: { firstWindowEvents.append(.create) },
            onStart: { firstWindowEvents.append(.start) },
            onPause: { firstWindowEvents.append(.pause) },
            onResume: { firstWindowEvents.append(.resume) },
            onCancel: { firstWindowEvents.append(.cancel) }
        )
        let siblingDispatcher = ReconstructionDashboardCommandDispatcher(
            onCreate: { siblingWindowEvents.append(.create) },
            onStart: { siblingWindowEvents.append(.start) },
            onPause: { siblingWindowEvents.append(.pause) },
            onResume: { siblingWindowEvents.append(.resume) },
            onCancel: { siblingWindowEvents.append(.cancel) }
        )

        for command in ReconstructionCommandKind.allCases {
            firstWindowEvents.removeAll()
            siblingWindowEvents.removeAll()
            let routing = ReconstructionWindowCommandRouting(
                controls: try controls(enabling: command),
                dispatcher: firstDispatcher
            )
            XCTAssertTrue(routing.canPerform(command))
            XCTAssertTrue(routing.perform(command))
            XCTAssertEqual(firstWindowEvents, [command])
            XCTAssertTrue(siblingWindowEvents.isEmpty)

            // `.created` is an active state: Start, Pause, and Cancel are all intentionally
            // available there. Use Resume as the independent negative control for Start.
            let disabledCommand: ReconstructionCommandKind = command == .start ? .resume : .start
            XCTAssertFalse(routing.canPerform(disabledCommand))
            XCTAssertFalse(routing.perform(disabledCommand))
            XCTAssertEqual(firstWindowEvents, [command])

            let sibling = ReconstructionWindowCommandRouting(
                controls: try controls(enabling: command),
                dispatcher: siblingDispatcher
            )
            XCTAssertTrue(sibling.perform(command))
            XCTAssertEqual(siblingWindowEvents, [command])
            XCTAssertEqual(firstWindowEvents, [command])
        }

        let noBoundary = ReconstructionWindowCommandRouting(
            controls: try controls(enabling: .start),
            dispatcher: ReconstructionDashboardCommandDispatcher(
                onCreate: nil,
                onStart: nil,
                onPause: nil,
                onResume: nil,
                onCancel: nil
            )
        )
        XCTAssertFalse(noBoundary.canPerform(.start))
        XCTAssertEqual(
            noBoundary.help(for: .start),
            "The Reconstruction command boundary is unavailable in this window."
        )
    }

    func testEveryStateAndPendingIntentHasExactClosedAvailability() throws {
        for state in ReconstructionJobState.allCases {
            let pauseContext = state == .paused
                ? try ReconstructionJobPauseContext(
                    cause: .pausedByUser,
                    resumeTarget: .retrieving
                )
                : nil
            for pendingKind in ReconstructionPendingCommandKind.allCases {
                let pending = pendingKind == .none
                    ? ReconstructionPendingIntent.none
                    : ReconstructionPendingIntent(
                        kind: pendingKind,
                        commandScopeID: commandScopeID,
                        generation: 7,
                        baseProjectionRevision: 3,
                        jobID: presentationID(1)
                    )
                let projection = ReconstructionStatusProjection.controlProjection(
                    state: state,
                    readiness: ready,
                    pauseContext: pauseContext,
                    pendingIntent: pending
                )
                let controls = ReconstructionCommandKind.allCases.map {
                    projection.controls.availability(for: $0)
                }

                if pendingKind != .none {
                    XCTAssertTrue(
                        controls.allSatisfy { !$0.enabled && $0.disabledReason == .pending },
                        "Pending \(pendingKind) leaked a command for \(state)"
                    )
                    continue
                }

                let active = ReconstructionJobState.activeStates.contains(state)
                XCTAssertTrue(projection.controls.create.enabled)
                XCTAssertNil(projection.controls.create.disabledReason)
                XCTAssertEqual(projection.controls.start.enabled, state == .created)
                XCTAssertEqual(
                    projection.controls.start.disabledReason,
                    state == .created ? nil : (state.isTerminal ? .terminalState : .notCreated)
                )
                XCTAssertEqual(
                    projection.controls.pause.enabled,
                    active
                )
                XCTAssertEqual(
                    projection.controls.pause.disabledReason,
                    active ? nil : (state.isTerminal ? .terminalState : .notActive)
                )
                XCTAssertEqual(projection.controls.resume.enabled, state == .paused)
                XCTAssertEqual(
                    projection.controls.resume.disabledReason,
                    state == .paused ? nil : (state.isTerminal ? .terminalState : .notPaused)
                )
                XCTAssertEqual(
                    projection.controls.cancel.enabled,
                    active || state == .paused
                )
                XCTAssertEqual(
                    projection.controls.cancel.disabledReason,
                    active || state == .paused ? nil : (state.isTerminal ? .terminalState : .notActive)
                )
                if projection.controls.pause.enabled {
                    XCTAssertEqual(projection.controls.pause.requiredResumeTarget, state)
                }
            }
        }
    }

    func testCommandAvailabilityTracksTheCentralJobStateMachine() throws {
        func stateMachineAllows(
            _ command: ReconstructionCommandKind,
            state: ReconstructionJobState,
            pauseContext: ReconstructionJobPauseContext?
        ) -> Bool {
            do {
                switch command {
                case .create:
                    return false
                case .start:
                    try ReconstructionJobStateMachine.transition(
                        from: state,
                        to: .ingesting,
                        resumeTarget: nil
                    )
                case .pause:
                    try ReconstructionJobStateMachine.transition(
                        from: state,
                        to: .paused,
                        resumeTarget: state
                    )
                case .resume:
                    guard let target = pauseContext?.resumeTarget else { return false }
                    try ReconstructionJobStateMachine.transition(
                        from: state,
                        to: target,
                        resumeTarget: target
                    )
                case .cancel:
                    guard ReconstructionJobState.activeStates.contains(state) || state == .paused else {
                        return false
                    }
                    try ReconstructionJobStateMachine.transition(
                        from: state,
                        to: .cancelled,
                        resumeTarget: nil
                    )
                }
                return true
            } catch {
                return false
            }
        }

        for state in ReconstructionJobState.allCases {
            let pauseContext = state == .paused
                ? try ReconstructionJobPauseContext(
                    cause: .pausedByUser,
                    resumeTarget: .retrieving
                )
                : nil
            let projection = ReconstructionStatusProjection.controlProjection(
                state: state,
                readiness: ready,
                pauseContext: pauseContext
            )
            for command in [
                ReconstructionCommandKind.start,
                .pause,
                .resume,
                .cancel,
            ] {
                XCTAssertEqual(
                    projection.controls.availability(for: command).enabled,
                    stateMachineAllows(command, state: state, pauseContext: pauseContext),
                    "Presentation drifted from the durable state machine for \(state) / \(command)"
                )
            }
        }
    }

    func testPendingIntentDisablesEveryCommandBeforeOtherAuthorityChecks() {
        let pending = ReconstructionPendingIntent(
            kind: .pause,
            commandScopeID: commandScopeID,
            generation: 9,
            baseProjectionRevision: 2,
            jobID: presentationID(2)
        )
        let projection = ReconstructionStatusProjection.controlProjection(
            state: .created,
            readiness: .unavailable(title: "Unavailable", detail: "Unavailable"),
            pendingIntent: pending,
            checkpointCurrent: false,
            restoreStatus: .restoring,
            creationValidation: .invalid
        )

        for command in ReconstructionCommandKind.allCases {
            let availability = projection.controls.availability(for: command)
            XCTAssertFalse(availability.enabled)
            XCTAssertEqual(availability.disabledReason, .pending)
            XCTAssertEqual(availability.help, ReconstructionCommandDisabledReason.pending.message)
        }
        XCTAssertEqual(projection.pendingIntent.kind, .pause)
        XCTAssertEqual(projection.state, .created, "Pending intent must not overwrite committed state")
    }

    func testMissingDurableDocumentLocationDisablesCreateWithExactReason() {
        let projection = ReconstructionStatusProjection.controlProjection(
            state: .created,
            readiness: ready,
            creationValidation: .durableDocumentLocationMissing
        )

        XCTAssertFalse(projection.controls.create.enabled)
        XCTAssertEqual(
            projection.controls.create.disabledReason,
            .durableDocumentLocationRequired
        )
        XCTAssertEqual(
            projection.controls.create.help,
            "Save this document to a durable location before creating a Reconstruction job."
        )
    }

    func testRuntimeRestorationAndFailureRemainDistinctVisibleDisabledStates() {
        let restoring = ReconstructionStatusProjection.controlProjection(
            state: .created,
            readiness: ready,
            restoreStatus: .restoring
        )
        for command in ReconstructionCommandKind.allCases {
            XCTAssertEqual(
                restoring.controls.availability(for: command).disabledReason,
                .restoreIncomplete
            )
        }
        XCTAssertEqual(restoring.restoreStatus, .restoring)
        XCTAssertEqual(restoring.notice.kind, .runtimeRestoring)
        XCTAssertEqual(restoring.notice.title, "Preparing Reconstruction runtime")
        XCTAssertEqual(restoring.notice.tone, .active)

        let failed = ReconstructionStatusProjection.controlProjection(
            state: .created,
            readiness: ready,
            restoreStatus: .failed(.restorationUnavailable)
        )
        for command in ReconstructionCommandKind.allCases {
            XCTAssertEqual(
                failed.controls.availability(for: command).disabledReason,
                .restoreFailed
            )
        }
        XCTAssertEqual(failed.restoreStatus, .failed(.restorationUnavailable))
        XCTAssertEqual(failed.notice.kind, .runtimeFailed(.restorationUnavailable))
        XCTAssertEqual(failed.notice.title, "Reconstruction runtime unavailable")
        XCTAssertEqual(
            failed.notice.detail,
            "Durable Reconstruction state could not be reconciled and rehydrated."
        )
        XCTAssertLessThanOrEqual(
            failed.notice.detail?.utf8.count ?? 0,
            ReconstructionTerminalNoticeProjection.maximumUTF8Bytes
        )

        let readyProjection = ReconstructionStatusProjection.controlProjection(
            state: .created,
            readiness: ready,
            restoreStatus: .complete
        )
        XCTAssertTrue(readyProjection.controls.start.enabled)
    }

    func testMissingRuntimeFallbackDoesNotInventSidecarFailureAndDisablesEveryCommand() {
        // WorkspaceRootView uses this immutable sentinel when app composition is absent,
        // including while the one startup validator is pending. No database open was attempted.
        let fallback = ReconstructionWorkspaceActivationModel.unavailable.snapshot
        XCTAssertEqual(fallback.phase, .failed(.runtimeUnavailable))
        XCTAssertEqual(fallback.revision, 0)
        guard case .failed(let failure) = fallback.phase else {
            return XCTFail("the missing-runtime sentinel must remain fail-closed")
        }
        let projection = ReconstructionStatusProjection.controlProjection(
            state: .created,
            readiness: ready,
            restoreStatus: .failed(failure)
        )
        XCTAssertEqual(projection.notice.kind, .runtimeFailed(.runtimeUnavailable))
        XCTAssertEqual(projection.notice.title, "Reconstruction runtime unavailable")
        XCTAssertEqual(
            projection.notice.detail,
            "Reconstruction's production runtime is not available or has not completed validation."
        )
        XCTAssertEqual(projection.notice.tone, .warning)
        for command in ReconstructionCommandKind.allCases {
            let availability = projection.controls.availability(for: command)
            XCTAssertFalse(availability.enabled, "missing composition must disable \(command)")
            XCTAssertEqual(availability.disabledReason, .runtimeUnavailable)
            XCTAssertEqual(
                availability.help,
                "A validated production runtime is required before Reconstruction commands can run."
            )
            XCTAssertFalse(availability.help.contains("restoration failed"))
        }
        XCTAssertFalse(projection.notice.detail?.contains("sidecar") ?? false)
        let absentActions = ReconstructionWorkspaceCommandActions.unavailable
        XCTAssertNil(absentActions.createJob)
        XCTAssertNil(absentActions.startJob)
        XCTAssertNil(absentActions.pauseJob)
        XCTAssertNil(absentActions.resumeJob)
        XCTAssertNil(absentActions.cancelJob)
    }

    func testRealSidecarAndRestorationFailuresKeepTheirExactDiagnosticsAndDisableEveryCommand() {
        let failures: [(ReconstructionWorkspaceActivationFailure, String)] = [
            (
                .sidecarUnavailable,
                "The durable Reconstruction sidecar could not be opened for this document."
            ),
            (
                .restorationUnavailable,
                "Durable Reconstruction state could not be reconciled and rehydrated."
            ),
        ]
        for (failure, detail) in failures {
            let projection = ReconstructionStatusProjection.controlProjection(
                state: .created,
                readiness: ready,
                restoreStatus: .failed(failure)
            )
            XCTAssertEqual(projection.notice.kind, .runtimeFailed(failure))
            XCTAssertEqual(projection.notice.detail, detail)
            XCTAssertEqual(projection.notice.tone, .failure)
            for command in ReconstructionCommandKind.allCases {
                let availability = projection.controls.availability(for: command)
                XCTAssertFalse(availability.enabled, "\(failure): \(command)")
                XCTAssertEqual(availability.disabledReason, .restoreFailed)
                XCTAssertEqual(
                    availability.help,
                    "The Reconstruction runtime is unavailable because durable restoration failed."
                )
            }
        }
    }

    func testPauseCarriesItsDurableResumeTargetAndResumeRequiresPersistedContext() throws {
        let active = ReconstructionStatusProjection.controlProjection(
            state: .executingReads,
            readiness: ready
        )
        XCTAssertTrue(active.controls.pause.enabled)
        XCTAssertEqual(active.controls.pause.requiredResumeTarget, .executingReads)
        XCTAssertEqual(active.controls.pause.requiredTransition, "executingReads->paused")

        let missing = ReconstructionStatusProjection.controlProjection(
            state: .paused,
            readiness: ready
        )
        XCTAssertFalse(missing.controls.resume.enabled)
        XCTAssertEqual(missing.controls.resume.disabledReason, .resumeTargetMissing)

        let durable = ReconstructionStatusProjection.controlProjection(
            state: .paused,
            readiness: ready,
            pauseContext: try ReconstructionJobPauseContext(
                cause: .frontierMismatch,
                resumeTarget: .acceptingEvidence
            )
        )
        XCTAssertTrue(durable.controls.resume.enabled)
        XCTAssertEqual(durable.controls.resume.requiredResumeTarget, .acceptingEvidence)
        XCTAssertEqual(durable.controls.resumeTarget, .acceptingEvidence)
    }

    func testEvidenceFrontierMismatchWithholdsCurrentAuthority() throws {
        let jobID = presentationID(5)
        let checkpointID = presentationID(6)
        let corpusSHA256 = String(repeating: "a", count: 64)
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: checkpointID,
            jobID: jobID,
            revision: 0,
            parentCheckpointID: nil,
            parentCheckpointSHA256: nil,
            corpusManifestSHA256: corpusSHA256,
            evidenceFrontierSHA256: String(repeating: "b", count: 64),
            pendingTaskIDs: [],
            runningTaskIDs: [],
            completedTaskIDs: [],
            failedTaskIDs: [],
            blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: corpusSHA256,
            modelReceiptIDs: [],
            toolReceiptIDs: [],
            coordinatorState: .retrieving,
            terminalReason: nil
        )
        let job = try presentationJob(
            id: jobID,
            state: .retrieving,
            currentCheckpointID: checkpointID
        )

        let freshness = ReconstructionStatusProjection.checkpointFreshness(
            checkpoint: checkpoint,
            exactCheckpointID: checkpointID,
            job: job,
            currentManifestSHA256: corpusSHA256,
            currentEvidenceFrontierSHA256: String(repeating: "c", count: 64)
        )

        XCTAssertEqual(freshness.status, .stale)
        XCTAssertEqual(freshness.issues, ["checkpointEvidenceFrontierStale"])
        let controls = ReconstructionStatusProjection.controlProjection(
            state: .retrieving,
            readiness: ready,
            checkpointCurrent: freshness.isCurrent
        ).controls
        XCTAssertEqual(controls.pause.disabledReason, .staleProjection)
        XCTAssertEqual(controls.cancel.disabledReason, .staleProjection)
    }

    func testRichWorkspaceProjectsCountsGapFreshnessRevisionAndNoticeTruth() throws {
        let workspace = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: presentationID(333)
        )
        let jobID = try XCTUnwrap(workspace.jobs.first?.jobID)
        let current = ReconstructionStatusProjection.project(
            workspace: workspace,
            selectedJobID: jobID,
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete
        )

        XCTAssertEqual(current.jobID, jobID)
        XCTAssertEqual(current.checkpointRevision, 1)
        XCTAssertEqual(current.checkpointFreshness.status, .current)
        XCTAssertEqual(current.progress.totalTaskCount, 1)
        XCTAssertEqual(current.progress.completedTaskCount, 1)
        XCTAssertEqual(current.evidence.totalCount, 2)
        XCTAssertEqual(current.evidence.currentCount, 2)
        XCTAssertEqual(current.currentGap.status, .current)
        XCTAssertEqual(
            current.currentGap.operationID,
            ReconstructionOperationID.evidenceQuery.rawValue
        )
        XCTAssertNil(current.terminalNotice)
        XCTAssertTrue(
            current.controls.create.enabled,
            "An active durable job must not invent a single-active-job creation policy."
        )

        let stale = ReconstructionStatusProjection.project(
            workspace: workspace,
            selectedJobID: jobID,
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete,
            currentEvidenceFrontierSHA256: String(repeating: "f", count: 64)
        )
        XCTAssertEqual(stale.checkpointRevision, 1)
        XCTAssertEqual(stale.checkpointFreshness.status, .stale)
        XCTAssertEqual(stale.currentGap.status, .stale)
        XCTAssertEqual(stale.progress, current.progress)
        XCTAssertEqual(stale.evidence, current.evidence)
    }

    func testReadinessPreservesAllTwelveCasesAndSeparateExecutionAuthority() throws {
        let configuration = try Phase2AIProviderConfiguration(
            profileID: presentationID(3),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "local-model",
            maximumTokens: 1_024,
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 10_000
        )
        let source: [Phase2LocalAIProviderReadiness] = [
            .endpointMissing, .inventoryRequired, .authenticationRequired, .unavailable,
            .incompatible, .reconciliationRequired, .selectionRequired,
            .selectionIdentityMismatch, .selectedModelMissing, .selectedModelNotLanguage,
            .loadRequired(modelKey: "local-model"), .ready(configuration),
        ]

        XCTAssertEqual(
            source.map { ReconstructionModelReadinessProjection($0).readinessCase },
            ReconstructionModelReadinessCase.allCases
        )
        let busy = ReconstructionModelReadinessProjection(
            .ready(configuration),
            activity: .discovering(requestID: presentationID(4)),
            providerRevision: 7
        )
        XCTAssertTrue(busy.isReady)
        XCTAssertFalse(busy.isExecutable)
        XCTAssertEqual(busy.activity, .discovering)
        XCTAssertEqual(busy.providerRevision, 7)

        let invalidRevision = ReconstructionModelReadinessProjection(
            .ready(configuration),
            providerRevision: 0
        )
        XCTAssertFalse(invalidRevision.isExecutable)
        XCTAssertTrue(ReconstructionModelReadinessProjection(.ready(configuration)).isExecutable)
    }

    func testReadyButBusyOrInvalidProviderRevisionDisablesExecutableCommands() throws {
        let configuration = try Phase2AIProviderConfiguration(
            profileID: presentationID(5),
            generation: 1,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "local-model",
            maximumTokens: 1_024,
            requestTimeoutMilliseconds: 5_000,
            resourceTimeoutMilliseconds: 10_000
        )
        let nonExecutableAuthorities = [
            ReconstructionModelReadinessProjection(
                .ready(configuration),
                activity: .performingLifecycle(effectID: presentationID(6)),
                providerRevision: 8
            ),
            ReconstructionModelReadinessProjection(
                .ready(configuration),
                activity: .idle,
                providerRevision: 0
            ),
        ]

        for authority in nonExecutableAuthorities {
            let created = ReconstructionStatusProjection.controlProjection(
                state: .created,
                readiness: authority
            )
            XCTAssertFalse(created.controls.start.enabled)
            XCTAssertEqual(created.controls.start.disabledReason, .modelNotExecutable)

            let paused = ReconstructionStatusProjection.controlProjection(
                state: .paused,
                readiness: authority,
                pauseContext: try ReconstructionJobPauseContext(
                    cause: .pausedByUser,
                    resumeTarget: .retrieving
                )
            )
            XCTAssertFalse(paused.controls.resume.enabled)
            XCTAssertEqual(paused.controls.resume.disabledReason, .modelNotExecutable)
        }
    }

    func testPartialFailureIsDistinctFromCleanCompletion() {
        let partialProgress = ReconstructionProgressSummary(
            pendingTaskCount: 0,
            runningTaskCount: 0,
            completedTaskCount: 2,
            failedTaskCount: 1,
            blockedTaskCount: 0,
            cancelledTaskCount: 0
        )
        let cleanProgress = ReconstructionProgressSummary(
            pendingTaskCount: 0,
            runningTaskCount: 0,
            completedTaskCount: 3,
            failedTaskCount: 0,
            blockedTaskCount: 0,
            cancelledTaskCount: 0
        )

        XCTAssertTrue(
            ReconstructionStatusProjection.hasPartialFailure(
                progress: partialProgress,
                evidence: .empty
            )
        )
        XCTAssertEqual(
            ReconstructionStatusProjection.outcome(state: .completed, partialFailure: true),
            .partialSuccess
        )
        XCTAssertFalse(
            ReconstructionStatusProjection.hasPartialFailure(
                progress: cleanProgress,
                evidence: .empty
            )
        )
        XCTAssertEqual(
            ReconstructionStatusProjection.outcome(state: .completed, partialFailure: false),
            .completed
        )
    }

    func testTerminalDetailIsPrivacyFilteredBoundedAndIdentityStable() throws {
        let long = String(repeating: "bounded detail ", count: 40)
        let first = try XCTUnwrap(
            ReconstructionStatusProjection.terminalProjection(
                state: .failed,
                diagnostic: .sanitizing(long)
            )
        )
        let second = try XCTUnwrap(
            ReconstructionStatusProjection.terminalProjection(
                state: .failed,
                diagnostic: .sanitizing(long)
            )
        )
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(first.detail).utf8.count,
            ReconstructionTerminalNoticeProjection.maximumUTF8Bytes
        )
        XCTAssertEqual(first.cause, .failed)
        XCTAssertEqual(first.detailIdentity, second.detailIdentity)
        XCTAssertEqual(first.detailIdentity.utf8.count, 64)

        let sharedPrefix = String(repeating: "x", count: 192)
        let distinctTail = try XCTUnwrap(
            ReconstructionStatusProjection.terminalProjection(
                state: .failed,
                diagnostic: .sanitizing(sharedPrefix + "tail")
            )
        )
        let noTail = try XCTUnwrap(
            ReconstructionStatusProjection.terminalProjection(
                state: .failed,
                diagnostic: .sanitizing(sharedPrefix)
            )
        )
        XCTAssertEqual(distinctTail.detail, noTail.detail)
        XCTAssertNotEqual(distinctTail.detailIdentity, noTail.detailIdentity)
        XCTAssertNil(
            ReconstructionStatusProjection.terminalProjection(
                state: .paused,
                diagnostic: .sanitizing("Pause causes remain a separate durable vocabulary.")
            )
        )

        let privateDetail = try XCTUnwrap(
            ReconstructionStatusProjection.terminalProjection(
                state: .failed,
                diagnostic: .sanitizing(
                    "provider failed at /Users/private/input with token=secret"
                )
            )
        )
        XCTAssertNil(privateDetail.detail)
        XCTAssertTrue(privateDetail.detailSuppressed)
    }

    func testFinalResultProjectionDistinguishesSynthesisFromEvidenceAbstentionAndBoundsText()
        throws {
        let longText = String(repeating: "Bounded final synthesis sentence. ", count: 220)
        let synthesisWorkspace = try presentationFinalResultWorkspace(
            kind: .synthesis,
            text: longText
        )
        let synthesis = ReconstructionStatusProjection.project(
            workspace: synthesisWorkspace,
            selectedJobID: presentationID(900),
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete
        )
        guard case .synthesis(let synthesisSummary) = synthesis.finalResult else {
            return XCTFail("Expected a bounded synthesis result, got \(synthesis.finalResult)")
        }
        XCTAssertLessThanOrEqual(
            synthesisSummary.text.utf8.count,
            ReconstructionFinalResultSummary.maximumDisplayedUTF8Bytes
        )
        XCTAssertTrue(synthesisSummary.textWasTruncated)
        XCTAssertEqual(synthesisSummary.citedEvidenceCount, 0)
        XCTAssertEqual(synthesisSummary.checkpointRevision, 0)
        XCTAssertEqual(synthesisSummary.sourcePayloadByteCount, UInt64(longText.utf8.count))

        let insufficientWorkspace = try presentationFinalResultWorkspace(
            kind: .insufficientEvidence,
            text: "Current accepted evidence is insufficient for a supported synthesis."
        )
        let insufficient = ReconstructionStatusProjection.project(
            workspace: insufficientWorkspace,
            selectedJobID: presentationID(900),
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete
        )
        guard case .insufficientEvidence(let insufficientSummary) = insufficient.finalResult else {
            return XCTFail("Expected an explicit evidence abstention, got \(insufficient.finalResult)")
        }
        XCTAssertEqual(
            insufficientSummary.text,
            "Current accepted evidence is insufficient for a supported synthesis."
        )
        XCTAssertFalse(insufficientSummary.textWasTruncated)
    }

    func testFinalResultProjectionFailsClosedForUnsafeOrUnanchoredPayload() throws {
        let unsafeWorkspace = try presentationFinalResultWorkspace(
            kind: .synthesis,
            text: "Recovered details from /Users/private/input with token=secret"
        )
        let unsafe = ReconstructionStatusProjection.project(
            workspace: unsafeWorkspace,
            selectedJobID: presentationID(900),
            readiness: .inventoryRequired,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete
        )
        XCTAssertEqual(unsafe.finalResult, .unavailable(.unsafePayload))

        let job = try XCTUnwrap(unsafeWorkspace.jobs.first)
        XCTAssertEqual(
            ReconstructionStatusProjection.finalResultProjection(
                workspace: unsafeWorkspace,
                job: job,
                checkpoint: nil
            ),
            .unavailable(.authorityMismatch)
        )
    }

    func testAccessibilityCatalogIsExactStableUniqueAndContiguous() {
        let catalog = ReconstructionAccessibilityIdentifiers.orderedCatalog
        XCTAssertEqual(
            catalog.map(\.identifier),
            [
                "reconstruction.destination",
                "reconstruction.dashboard",
                "reconstruction.job.identity",
                "reconstruction.job.state",
                "reconstruction.progress",
                "reconstruction.primaryAction",
                "reconstruction.pause",
                "reconstruction.resume",
                "reconstruction.cancel",
                "reconstruction.corpusSummary",
                "reconstruction.taskSummary",
                "reconstruction.evidenceSummary",
                "reconstruction.currentGap",
                "reconstruction.terminalNotice",
                "reconstruction.details",
                "reconstruction.inspector",
            ]
        )
        XCTAssertEqual(Set(catalog.map(\.identifier)).count, 16)
        XCTAssertEqual(catalog.map(\.focusOrder), Array(0..<16))
    }

    func testFinalResultAccessibilityIdentifierExtendsWithoutRenumberingTheOracleCatalog()
        throws {
        let oracle = ReconstructionAccessibilityIdentifiers.orderedCatalog
        let complete = ReconstructionAccessibilityIdentifiers.completeCatalog

        XCTAssertEqual(oracle.count, 16)
        XCTAssertEqual(ReconstructionAccessibilityIdentifiers.result, "reconstruction.result")
        XCTAssertFalse(oracle.map(\.identifier).contains("reconstruction.result"))
        XCTAssertEqual(complete.count, 17)
        XCTAssertEqual(Set(complete.map(\.identifier)).count, 17)
        XCTAssertEqual(complete.map(\.focusOrder), Array(0..<17))

        let source = try dashboardSource()
        XCTAssertEqual(
            source.components(
                separatedBy: "ReconstructionAccessibilityIdentifiers.result"
            ).count - 1,
            1
        )
        XCTAssertTrue(source.contains("case .synthesis(let summary)"))
        XCTAssertTrue(source.contains("case .insufficientEvidence(let summary)"))
        XCTAssertFalse(source.contains("payloadUTF8"))
        XCTAssertFalse(source.contains("canonicalSHA256"))
        XCTAssertFalse(source.contains("producer"))
    }

    func testTaskAndEvidenceSamplesAreDeterministicAndBoundedToEight() throws {
        let jobID = presentationID(10)
        let checkpointID = presentationID(11)
        let tasks = try (0..<12).reversed().map { index in
            try presentationTask(
                id: presentationID(100 + index),
                jobID: jobID,
                kind: ReconstructionTaskKind.allCases[index % ReconstructionTaskKind.allCases.count]
            )
        }
        let evidence = try (0..<12).reversed().map { index in
            try presentationEvidence(
                id: presentationID(200 + index),
                jobID: jobID,
                taskID: tasks[index].identity.taskID,
                checkpointID: checkpointID,
                classification: ReconstructionEvidenceClassification.allCases[
                    index % ReconstructionEvidenceClassification.allCases.count
                ]
            )
        }

        let taskSample = ReconstructionStatusProjection.taskSamples(tasks)
        let evidenceSample = ReconstructionStatusProjection.evidenceSamples(evidence)
        XCTAssertEqual(taskSample.count, ReconstructionStatusProjection.sampleLimit)
        XCTAssertEqual(evidenceSample.count, ReconstructionStatusProjection.sampleLimit)
        XCTAssertEqual(
            taskSample,
            ReconstructionStatusProjection.taskSamples(Array(tasks.reversed()))
        )
        XCTAssertEqual(
            evidenceSample,
            ReconstructionStatusProjection.evidenceSamples(Array(evidence.reversed()))
        )
    }

    func testDashboardAppliesEveryStableAccessibilityIdentifier() throws {
        let source = try dashboardSource()
            + dashboardSource(fileName: "ReconstructionProgressSummaryView.swift")
        for entry in ReconstructionAccessibilityIdentifiers.orderedCatalog {
            let reference = "ReconstructionAccessibilityIdentifiers.\(entry.semanticName)"
            let expectedCount = ["jobIdentity", "jobState"].contains(entry.semanticName) ? 2 : 1
            XCTAssertEqual(
                source.components(separatedBy: reference).count - 1,
                expectedCount,
                "Dashboard misapplied stable accessibility surface \(entry.identifier)"
            )
        }
    }

    func testDashboardKeepsTheExactFiveControlsVisibleWithDisabledHelp() throws {
        let source = try dashboardSource()
        let commandSurface = try XCTUnwrap(
            source.range(of: "private var commandSurface: some View")
        )
        let commandButton = try XCTUnwrap(
            source.range(
                of: "private var createButton: some View",
                range: commandSurface.upperBound..<source.endIndex
            )
        )
        let surface = source[commandSurface.lowerBound..<commandButton.lowerBound]
        let controls = [
            "createButton", "startButton", "pauseButton", "resumeButton", "cancelButton",
        ]

        XCTAssertEqual(controls.filter { surface.contains($0) }, controls)
        XCTAssertFalse(surface.contains("if projection.controls"))
        XCTAssertTrue(source.contains(".disabled(!enabled)"))
        XCTAssertTrue(source.contains(".help(commandHelp(command))"))
        XCTAssertTrue(source.contains(".accessibilityHint(commandHelp(command))"))
    }

    func testTwoWindowsDoNotShareSelectionFilterInspectorOrPendingState() {
        let first = ReconstructionWindowPresentationState(
            windowID: presentationID(20),
            selectedJobID: presentationID(21),
            selectedTaskID: presentationID(22),
            inspectorVisible: true,
            scrollAnchor: "task-list",
            filterText: "native",
            pendingIntent: .init(
                kind: .pause,
                commandScopeID: commandScopeID,
                generation: 4,
                baseProjectionRevision: 2,
                jobID: presentationID(21)
            ),
            commandGeneration: 4
        )
        let second = ReconstructionWindowPresentationState(
            windowID: presentationID(30),
            selectedJobID: presentationID(31),
            selectedEvidenceID: presentationID(32),
            inspectorVisible: false,
            scrollAnchor: "evidence-list",
            filterText: "historical",
            pendingIntent: .none,
            commandGeneration: 1
        )
        let changedFirst = first
            .selectingTask(nil)
            .replacing(
                inspectorVisible: false,
                filterText: "checkpoint",
                commandGeneration: 5
            )

        XCTAssertNotEqual(changedFirst, first)
        XCTAssertNil(changedFirst.selectedTaskID)
        XCTAssertEqual(second.filterText, "historical")
        XCTAssertEqual(second.selectedEvidenceID, presentationID(32))
        XCTAssertFalse(second.inspectorVisible)
        XCTAssertEqual(second.pendingIntent, .none)
        XCTAssertEqual(second.commandGeneration, 1)
    }

    func testStaleOrSiblingDetailSelectionFailsClosed() throws {
        let selectedJob = try presentationJob(id: presentationID(40))
        let siblingTask = try presentationTask(
            id: presentationID(41),
            jobID: presentationID(42),
            kind: .decompileNative
        )
        let stale = ReconstructionWindowPresentationState(
            windowID: presentationID(43),
            selectedJobID: selectedJob.jobID,
            selectedTaskID: presentationID(44)
        )
        XCTAssertEqual(
            ReconstructionStatusProjection.selectedDetail(
                window: stale,
                job: selectedJob,
                allTasks: [siblingTask],
                allEvidence: [],
                taskSamples: [],
                evidenceSamples: [],
                checkpointRevision: nil
            ),
            .unavailable(.selectedTaskMissing)
        )

        let sibling = ReconstructionWindowPresentationState(
            windowID: presentationID(43),
            selectedJobID: selectedJob.jobID,
            selectedTaskID: siblingTask.identity.taskID
        )
        XCTAssertEqual(
            ReconstructionStatusProjection.selectedDetail(
                window: sibling,
                job: selectedJob,
                allTasks: [siblingTask],
                allEvidence: [],
                taskSamples: [],
                evidenceSamples: [],
                checkpointRevision: nil
            ),
            .unavailable(.selectedTaskBelongsToAnotherJob)
        )

        let siblingEvidence = try presentationEvidence(
            id: presentationID(45),
            jobID: presentationID(46),
            taskID: siblingTask.identity.taskID,
            checkpointID: presentationID(47),
            classification: .acceptedHistorical
        )
        let staleEvidence = ReconstructionWindowPresentationState(
            windowID: presentationID(43),
            selectedJobID: selectedJob.jobID,
            selectedEvidenceID: presentationID(48)
        )
        XCTAssertEqual(
            ReconstructionStatusProjection.selectedDetail(
                window: staleEvidence,
                job: selectedJob,
                allTasks: [],
                allEvidence: [siblingEvidence],
                taskSamples: [],
                evidenceSamples: [],
                checkpointRevision: nil
            ),
            .unavailable(.selectedEvidenceMissing)
        )

        let siblingEvidenceSelection = ReconstructionWindowPresentationState(
            windowID: presentationID(43),
            selectedJobID: selectedJob.jobID,
            selectedEvidenceID: siblingEvidence.evidenceID
        )
        XCTAssertEqual(
            ReconstructionStatusProjection.selectedDetail(
                window: siblingEvidenceSelection,
                job: selectedJob,
                allTasks: [],
                allEvidence: [siblingEvidence],
                taskSamples: [],
                evidenceSamples: [],
                checkpointRevision: nil
            ),
            .unavailable(.selectedEvidenceBelongsToAnotherJob)
        )
    }

    func testStaleCompletionCannotMutateWindowLocalSelection() {
        let jobID = presentationID(50)
        let window = ReconstructionWindowPresentationState(
            windowID: presentationID(51),
            selectedJobID: jobID,
            pendingIntent: .init(
                kind: .start,
                commandScopeID: commandScopeID,
                generation: 8,
                baseProjectionRevision: 4,
                jobID: jobID
            ),
            commandGeneration: 8
        )
        let stale = ReconstructionCommandCompletion(
            windowID: presentationID(52),
            commandScopeID: commandScopeID,
            commandGeneration: 7,
            baseProjectionRevision: 3,
            jobID: presentationID(53),
            selectedTaskID: presentationID(54),
            selectedEvidenceID: nil
        )
        let result = window.accepting(stale, durableProjectionRevision: 4)

        XCTAssertFalse(result.accepted)
        XCTAssertEqual(result.window, window)
        XCTAssertEqual(
            Set(result.rejectionReasons),
            Set([.windowMismatch, .commandGenerationStale, .projectionRevisionStale,
                 .jobSelectionChanged, .noMatchingPendingIntent])
        )
    }

    func testAcceptedCompletionReplacesRatherThanCombinesSiblingSelections() {
        let jobID = presentationID(55)
        let window = ReconstructionWindowPresentationState(
            windowID: presentationID(56),
            selectedJobID: jobID,
            selectedEvidenceID: presentationID(57),
            pendingIntent: .init(
                kind: .start,
                commandScopeID: commandScopeID,
                generation: 9,
                baseProjectionRevision: 5,
                jobID: jobID
            ),
            commandGeneration: 9
        )
        let completion = ReconstructionCommandCompletion(
            windowID: window.windowID,
            commandScopeID: commandScopeID,
            commandGeneration: 9,
            baseProjectionRevision: 5,
            jobID: jobID,
            selectedTaskID: presentationID(58),
            selectedEvidenceID: nil
        )

        let result = window.accepting(completion, durableProjectionRevision: 5)
        XCTAssertTrue(result.accepted)
        XCTAssertEqual(result.window.selectedTaskID, presentationID(58))
        XCTAssertNil(result.window.selectedEvidenceID)
        XCTAssertEqual(result.window.pendingIntent, .none)

        let ambiguous = ReconstructionCommandCompletion(
            windowID: window.windowID,
            commandScopeID: commandScopeID,
            commandGeneration: 9,
            baseProjectionRevision: 5,
            jobID: jobID,
            selectedTaskID: presentationID(58),
            selectedEvidenceID: presentationID(59)
        )
        let rejected = window.accepting(ambiguous, durableProjectionRevision: 5)
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.window, window)
        XCTAssertTrue(rejected.rejectionReasons.contains(.ambiguousSelection))
    }

    func testCreateCompletionIsFencedAgainstTheOriginallySelectedJob() throws {
        let originalJobID = presentationID(60)
        let base = ReconstructionDurablePresentationIdentity(
            jobID: originalJobID,
            state: .completed,
            projectionRevision: 6,
            checkpointRevision: 6
        )
        let pending = try XCTUnwrap(
            ReconstructionWindowPresentationState(
                windowID: presentationID(61),
                selectedJobID: originalJobID
            ).beginningCommand(
                .create,
                commandScopeID: commandScopeID,
                against: base,
                expectedCommittedState: nil
            )
        )
        let completion = ReconstructionCommandCompletion(
            windowID: pending.windowID,
            commandScopeID: commandScopeID,
            commandGeneration: pending.commandGeneration,
            baseProjectionRevision: base.projectionRevision,
            jobID: nil,
            selectedTaskID: nil,
            selectedEvidenceID: nil
        )

        let accepted = pending.accepting(
            completion,
            durableProjectionRevision: base.projectionRevision
        )
        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(accepted.window.selectedJobID, originalJobID)
        XCTAssertEqual(accepted.window.pendingIntent, .none)

        let siblingSelection = pending.selectingJob(presentationID(62))
        let rejected = siblingSelection.accepting(
            completion,
            durableProjectionRevision: base.projectionRevision
        )
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.window, siblingSelection)
        XCTAssertTrue(rejected.rejectionReasons.contains(.jobSelectionChanged))
    }

    func testLateOldRuntimeScopeCannotClearRepeatedSameWindowPendingIntent() throws {
        let windowID = presentationID(63)
        let jobID = presentationID(64)
        let oldScopeID = presentationID(65)
        let newScopeID = presentationID(66)
        let base = ReconstructionDurablePresentationIdentity(
            jobID: jobID,
            state: .created,
            projectionRevision: 6,
            checkpointRevision: 0
        )
        let initial = ReconstructionWindowPresentationState(
            windowID: windowID,
            selectedJobID: jobID
        )
        let oldPending = try XCTUnwrap(
            initial.beginningCommand(
                .start,
                commandScopeID: oldScopeID,
                against: base,
                expectedCommittedState: .ingesting
            )
        )
        let scopeReplacement = oldPending.reconcilingPending(
            with: base,
            activeCommandScopeID: newScopeID
        )
        XCTAssertEqual(scopeReplacement.disposition, .fenced(.commandScopeChanged))
        XCTAssertEqual(scopeReplacement.window.pendingIntent, .none)

        // A reconstructed view/runtime can repeat every visible key and command generation.
        let newPending = try XCTUnwrap(
            initial.beginningCommand(
                .start,
                commandScopeID: newScopeID,
                against: base,
                expectedCommittedState: .ingesting
            )
        )
        XCTAssertEqual(newPending.windowID, oldPending.windowID)
        XCTAssertEqual(newPending.commandGeneration, oldPending.commandGeneration)
        XCTAssertEqual(
            newPending.pendingIntent.baseProjectionRevision,
            oldPending.pendingIntent.baseProjectionRevision
        )
        XCTAssertEqual(newPending.pendingIntent.jobID, oldPending.pendingIntent.jobID)

        let lateOldOutcome = ReconstructionCommandCompletion(
            windowID: windowID,
            commandScopeID: oldScopeID,
            commandGeneration: newPending.commandGeneration,
            baseProjectionRevision: base.projectionRevision,
            jobID: jobID,
            selectedTaskID: nil,
            selectedEvidenceID: nil
        )
        let rejected = newPending.accepting(
            lateOldOutcome,
            durableProjectionRevision: base.projectionRevision
        )
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.window, newPending)
        XCTAssertTrue(rejected.rejectionReasons.contains(.commandScopeMismatch))

        let exactNewOutcome = ReconstructionCommandCompletion(
            windowID: windowID,
            commandScopeID: newScopeID,
            commandGeneration: newPending.commandGeneration,
            baseProjectionRevision: base.projectionRevision,
            jobID: jobID,
            selectedTaskID: nil,
            selectedEvidenceID: nil
        )
        XCTAssertTrue(newPending.accepting(
            exactNewOutcome,
            durableProjectionRevision: base.projectionRevision
        ).accepted)
    }

    func testPendingIntentClearsOnlyAfterTheExpectedDurableSuccessor() throws {
        let jobID = presentationID(80)
        let base = ReconstructionDurablePresentationIdentity(
            jobID: jobID,
            state: .created,
            projectionRevision: 4,
            checkpointRevision: 0
        )
        let window = ReconstructionWindowPresentationState(
            windowID: presentationID(81),
            selectedJobID: jobID
        )
        let pending = try XCTUnwrap(
            window.beginningCommand(
                .start,
                commandScopeID: commandScopeID,
                against: base,
                expectedCommittedState: .ingesting
            )
        )

        XCTAssertEqual(pending.pendingIntent.kind, .start)
        XCTAssertEqual(pending.pendingIntent.baseProjectionIdentity, base)
        XCTAssertEqual(pending.pendingIntent.expectedCommittedState, .ingesting)
        XCTAssertEqual(
            pending.reconcilingPending(
                with: base,
                activeCommandScopeID: commandScopeID
            ).disposition,
            .unchanged,
            "A command callback returning is not durable completion."
        )

        let successor = ReconstructionDurablePresentationIdentity(
            jobID: jobID,
            state: .ingesting,
            projectionRevision: 5,
            checkpointRevision: 1
        )
        let result = pending.reconcilingPending(
            with: successor,
            activeCommandScopeID: commandScopeID
        )
        XCTAssertEqual(result.disposition, .accepted)
        XCTAssertEqual(result.window.pendingIntent, .none)
        XCTAssertEqual(result.window.commandGeneration, 1)
    }

    func testUnexpectedDurableAdvanceAndSiblingSelectionFencePendingIntent() throws {
        let jobID = presentationID(82)
        let base = ReconstructionDurablePresentationIdentity(
            jobID: jobID,
            state: .executingReads,
            projectionRevision: 7,
            checkpointRevision: 3
        )
        let window = try XCTUnwrap(
            ReconstructionWindowPresentationState(
                windowID: presentationID(83),
                selectedJobID: jobID
            ).beginningCommand(
                .pause,
                commandScopeID: commandScopeID,
                against: base,
                expectedCommittedState: .paused
            )
        )
        let unexpected = ReconstructionDurablePresentationIdentity(
            jobID: jobID,
            state: .executingReads,
            projectionRevision: 8,
            checkpointRevision: 4
        )
        let advanced = window.reconcilingPending(
            with: unexpected,
            activeCommandScopeID: commandScopeID
        )
        XCTAssertEqual(
            advanced.disposition,
            .fenced(.unexpectedDurableProjectionChange)
        )
        XCTAssertEqual(advanced.window.pendingIntent, .none)

        let siblingID = presentationID(84)
        let siblingSelection = window.selectingJob(siblingID)
        let sibling = siblingSelection.reconcilingPending(
            with: .init(
                jobID: siblingID,
                state: .created,
                projectionRevision: 1,
                checkpointRevision: 0
            ),
            activeCommandScopeID: commandScopeID
        )
        XCTAssertEqual(sibling.disposition, .fenced(.selectedJobChanged))
        XCTAssertEqual(sibling.window.selectedJobID, siblingID)
        XCTAssertEqual(sibling.window.pendingIntent, .none)
    }

    func testRetiredCommandBoundaryFencesPendingWithoutChangingSelection() throws {
        let jobID = presentationID(85)
        let window = try XCTUnwrap(
            ReconstructionWindowPresentationState(
                windowID: presentationID(86),
                selectedJobID: jobID,
                selectedEvidenceID: presentationID(87)
            ).beginningCommand(
                .cancel,
                commandScopeID: commandScopeID,
                against: .init(
                    jobID: jobID,
                    state: .retrieving,
                    projectionRevision: 5,
                    checkpointRevision: 2
                ),
                expectedCommittedState: .cancelled
            )
        )
        let result = window.fencingPendingForUnavailableCommandBoundary()

        XCTAssertEqual(result.disposition, .fenced(.commandBoundaryUnavailable))
        XCTAssertEqual(result.window.pendingIntent, .none)
        XCTAssertEqual(result.window.selectedJobID, jobID)
        XCTAssertEqual(result.window.selectedEvidenceID, presentationID(87))
    }

    func testDashboardSampleRowsAreSelectableAndRevealOnlyPreflightedEvidence() throws {
        let source = try dashboardSource()
        XCTAssertTrue(source.contains("onSelectTask?(sample.taskID)"))
        XCTAssertTrue(source.contains("onSelectEvidence?(sample.evidenceID)"))
        XCTAssertTrue(source.contains("projection.windowState.selectedTaskID"))
        XCTAssertTrue(source.contains("projection.windowState.selectedEvidenceID"))
        XCTAssertTrue(source.contains("sample.sourceNavigationEligible"))
        XCTAssertTrue(source.contains("sourceNavigableEvidenceIDs.contains(sample.evidenceID)"))
        XCTAssertTrue(source.contains("onRevealEvidenceSource?(sample.evidenceID)"))
    }

    private func dashboardSource(fileName: String = "ReconstructionDashboardView.swift") throws -> String {
        let coreTests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let macScope = coreTests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: macScope
                .appendingPathComponent("Features")
                .appendingPathComponent("Reconstruction")
                .appendingPathComponent(fileName),
            encoding: .utf8
        )
    }
}

private func presentationID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "9a000000-0000-0000-0000-%012d", value))!
}

private func presentationTask(
    id: UUID,
    jobID: UUID,
    kind: ReconstructionTaskKind
) throws -> ReconstructionTaskRecord {
    let identity = try ReconstructionTaskIdentity.make(
        taskID: id,
        jobID: jobID,
        kind: kind,
        subject: nil,
        dependencyTaskIDs: [],
        operationContractIdentity: "reconstruction.presentation.\(kind.rawValue)"
    )
    return .init(identity: identity, state: .completed, diagnostic: nil)
}

private func presentationJob(
    id: UUID,
    state: ReconstructionJobState = .retrieving,
    currentCheckpointID: UUID? = nil
) throws -> ReconstructionJobRecord {
    let digest = String(repeating: "a", count: 64)
    return try ReconstructionJobRecord(
        jobID: id,
        reconstructionProjectID: presentationID(60),
        objective: "Recover selected corpus",
        objectiveSHA256: digest,
        creationCorpusManifestSHA256: digest,
        state: state,
        currentCheckpointID: currentCheckpointID,
        terminalReason: nil,
        budget: try ReconstructionJobBudget(
            maxRounds: 2,
            maxTasks: 32,
            maxEvidenceRecords: 32,
            maxEncodedBytes: 4_096
        ),
        creationOrdinal: 1
    )
}

private func presentationEvidence(
    id: UUID,
    jobID: UUID,
    taskID: UUID,
    checkpointID: UUID,
    classification: ReconstructionEvidenceClassification
) throws -> ReconstructionEvidenceRecord {
    let payload = Data("bounded evidence".utf8)
    let artifact = ReconstructionArtifactCoordinate(
        occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: presentationID(70)),
        contentIdentity: try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: String(repeating: "c", count: 64),
            byteCount: 16
        )
    )
    return try ReconstructionEvidenceRecord(
        evidenceID: id,
        subject: .artifact(artifact),
        operationID: "reconstruction.presentation.evidence",
        payloadKind: .structuredJSON,
        payload: payload,
        payloadByteCount: UInt64(payload.count),
        payloadSHA256: String(repeating: "d", count: 64),
        facetDependencies: [],
        producer: try ReconstructionProducerIdentity(
            macScopeBuildIdentity: "build-v1",
            macScopeSourceIdentity: "source-v1",
            operationIdentity: "reconstruction.presentation.evidence@1",
            registryIdentity: "reconstruction.v1",
            protocolIdentity: "reconstructionR1",
            canonicalSHA256: String(repeating: "e", count: 64)
        ),
        citations: [],
        creatingJobID: jobID,
        creatingTaskID: taskID,
        creatingCheckpointID: checkpointID,
        modelReceiptID: nil,
        toolReceiptID: nil,
        classification: classification,
        supersedesEvidenceID: nil,
        supersededByEvidenceID: nil,
        diagnostic: nil
    )
}

private func presentationFinalResultWorkspace(
    kind: ReconstructionFinalSynthesisKind,
    text: String
) throws -> ReconstructionWorkspaceState {
    let jobID = presentationID(900)
    let projectID = presentationID(901)
    let taskID = presentationID(902)
    let checkpointID = presentationID(903)
    let receiptID = presentationID(904)
    let resultID = presentationID(905)
    let digestA = String(repeating: "a", count: 64)
    let digestB = String(repeating: "b", count: 64)
    let digestC = String(repeating: "c", count: 64)
    let digestD = String(repeating: "d", count: 64)
    let digestE = String(repeating: "e", count: 64)
    let payload = Data(text.utf8)
    let producer = try ReconstructionProducerIdentity(
        macScopeBuildIdentity: "presentation-build-v1",
        macScopeSourceIdentity: "presentation-source-v1",
        operationIdentity: "reconstruction.finalSynthesis.v1",
        registryIdentity: "reconstruction.v1",
        protocolIdentity: "reconstructionR1",
        canonicalSHA256: digestE
    )
    let task = ReconstructionTaskRecord(
        identity: try ReconstructionTaskIdentity.make(
            taskID: taskID,
            jobID: jobID,
            kind: .modelRound,
            subject: nil,
            dependencyTaskIDs: [],
            operationContractIdentity: "reconstruction.finalSynthesis.v1"
        ),
        state: .completed,
        diagnostic: nil
    )
    let result = try ReconstructionFinalResultRecord(
        resultID: resultID,
        jobID: jobID,
        taskID: taskID,
        checkpointID: checkpointID,
        checkpointRevision: 0,
        requestID: receiptID,
        requestIdentitySHA256: digestB,
        kind: kind,
        payloadUTF8: payload,
        payloadByteCount: UInt64(payload.count),
        payloadSHA256: digestC,
        citedEvidenceIDs: [],
        producer: producer,
        modelReceiptID: receiptID,
        canonicalSHA256: digestD
    )
    let receipt = try ReconstructionModelReceipt(
        receiptID: receiptID,
        jobID: jobID,
        taskID: taskID,
        checkpointRevision: 0,
        requestIdentitySHA256: digestB,
        producer: producer,
        terminalState: .completed,
        selectedHandleIDs: [],
        acceptedEvidenceIDs: [],
        diagnostic: nil,
        finalResultCommitment: try ReconstructionFinalResultCommitment(
            resultID: resultID,
            canonicalSHA256: digestD
        ),
        canonicalSHA256: digestC
    )
    let checkpoint = try ReconstructionCheckpoint.make(
        checkpointID: checkpointID,
        jobID: jobID,
        revision: 0,
        parentCheckpointID: nil,
        parentCheckpointSHA256: nil,
        corpusManifestSHA256: digestA,
        evidenceFrontierSHA256: digestB,
        pendingTaskIDs: [],
        runningTaskIDs: [],
        completedTaskIDs: [taskID],
        failedTaskIDs: [],
        blockedTaskIDs: [],
        unresolvedEvidenceGapSHA256: digestA,
        modelReceiptIDs: [receiptID],
        toolReceiptIDs: [],
        coordinatorState: .completed,
        terminalReason: nil
    )
    let job = try ReconstructionJobRecord(
        jobID: jobID,
        reconstructionProjectID: projectID,
        objective: "Produce a bounded final synthesis",
        objectiveSHA256: digestA,
        creationCorpusManifestSHA256: digestA,
        state: .completed,
        currentCheckpointID: checkpointID,
        terminalReason: nil,
        budget: try ReconstructionJobBudget(
            maxRounds: 2,
            maxTasks: 8,
            maxEvidenceRecords: 8,
            maxEncodedBytes: 16_384
        ),
        creationOrdinal: 1
    )
    return try ReconstructionWorkspaceState(
        projects: [
            try ReconstructionProjectRecord(
                projectID: projectID,
                name: "Final Result Fixture",
                currentCorpusManifestSHA256: nil
            ),
        ],
        corpusManifests: [],
        evidence: [],
        evidenceRelations: [],
        evidenceGaps: [],
        jobs: [job],
        tasks: [task],
        checkpoints: [checkpoint],
        toolReceipts: [],
        modelReceipts: [receipt],
        finalResults: [result]
    )
}
