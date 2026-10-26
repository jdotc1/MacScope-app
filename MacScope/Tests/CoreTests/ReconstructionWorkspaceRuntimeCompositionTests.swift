import Combine
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class ReconstructionWorkspaceRuntimeCompositionTests: XCTestCase {
    func testOrdinaryCorpusImportRetirementCancelsAndDrainsSuspendedAcquisition() async throws {
        let scenario = try await makeDurableScenario(paused: true)
        let importCorpus = try XCTUnwrap(scenario.runtime.commandActions.importCorpus)
        var database = await scenario.databaseOpenProbe.openedRuntime()
        let binding = try XCTUnwrap(database?.binding)
        let originalState = scenario.store.reconstructionState
        let originalSources = scenario.store.reconstructionAttachmentSources
        let gate = ReconstructionStartupAsyncGate()
        let cancellation = ReconstructionCancellation()
        var importFinished = false
        let importing = Task { @MainActor in
            defer { importFinished = true }
            return try await importCorpus(
                [.init(
                    rootURL: scenario.baseDirectoryURL.appendingPathComponent("fixture.bin"),
                    roles: [.primaryTarget]
                )],
                cancellation,
                { _ in await gate.wait() }
            )
        }
        let entered = await waitUntil { await gate.waiterCount == 1 }
        guard entered else {
            await gate.release()
            importing.cancel()
            _ = await importing.result
            await scenario.close()
            return XCTFail("Import must reach the held progress boundary")
        }

        // Retirement closes admission immediately, but cannot close the sidecar until the
        // held importer callback returns. This explicit gate, rather than a sleep, owns the race.
        let retiring = scenario.runtime.beginRetirement()
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertNil(scenario.runtime.commandActions.importCorpus)
        XCTAssertFalse(importFinished)
        XCTAssertEqual(scenario.store.reconstructionState, originalState)
        _ = try XCTUnwrap(database).databaseOwner()

        await gate.release()
        await retiring.value
        let result = await importing.result
        XCTAssertTrue(importFinished, "Retirement must drain its retained acquisition task")
        let observedTaskCancellation = await gate.observedCancellation
        XCTAssertTrue(observedTaskCancellation)
        switch result {
        case .success:
            XCTFail("A retiring document must reject the late import completion")
        case let .failure(error):
            XCTAssertEqual(error as? ReconstructionWorkspaceRuntimeError, .retired)
        }
        XCTAssertEqual(scenario.store.reconstructionState, originalState)
        XCTAssertThrowsError(try XCTUnwrap(database).databaseOwner()) { error in
            XCTAssertEqual(error as? ReconstructionWorkspaceDatabaseRuntimeError, .closed)
        }

        // A retired database intentionally retains its identity claim while a discard-capable
        // handle exists. Release this test's inspection handle, as the document runtime does,
        // before requiring physical reopen; revocation alone must not weaken that guard.
        database = nil
        let retainedDatabase = await scenario.databaseOpenProbe.openedRuntime()
        XCTAssertNil(retainedDatabase, "Retirement must leave no runtime-owned sidecar handle")
        // Reopen the physical sidecar, proving cancellation did not append durable corpus
        // state while acquisition was suspended and did not leave an owner lease.
        let reopened = try await scenario.databaseOpenProbe.open(
            binding: binding,
            state: originalState,
            sources: originalSources,
            workspaceName: scenario.store.workspaceName
        )
        XCTAssertEqual(reopened.reconciledOpeningState, originalState)
        try await reopened.retire(binding: binding)
        await scenario.close()
    }

    func testOrdinaryCorpusImportCommandPublishesSelectedArtifactWithoutModelAdmission() async throws {
        let scenario = try await makeDurableScenario(paused: true)
        let importCorpus = try XCTUnwrap(scenario.runtime.commandActions.importCorpus)
        let retainedIDs = Set(ReconstructionJobCreationItem.committedItems(
            in: scenario.store.reconstructionState
        ).map(\.occurrenceID))
        let source = scenario.baseDirectoryURL.appendingPathComponent("fixture.bin")
        let publication = try await importCorpus(
            [.init(rootURL: source, roles: [.primaryTarget])],
            ReconstructionCancellation(),
            nil
        )
        XCTAssertTrue(publication.publicationAccepted)
        XCTAssertFalse(publication.result.occurrences.isEmpty)
        let committedItems = ReconstructionJobCreationItem.committedItems(
            in: scenario.store.reconstructionState
        )
        XCTAssertTrue(retainedIDs.isSubset(of: Set(committedItems.map(\.occurrenceID))))
        for occurrence in publication.result.occurrences {
            XCTAssertTrue(committedItems.contains {
                $0.occurrenceID == occurrence.occurrenceID
                    && $0.contentIdentity == occurrence.contentIdentity
            })
        }
        let admitted = await scenario.sessionProbe.coordinator.startedJobIDs()
        XCTAssertTrue(admitted.isEmpty, "Import must not start a model-backed job")
        await scenario.close()
    }

    func testOrdinaryCorpusImportCommandRejectsCapturedActionAfterRetirement() async throws {
        let scenario = try await makeDurableScenario(paused: true)
        let importCorpus = try XCTUnwrap(scenario.runtime.commandActions.importCorpus)
        await scenario.runtime.retireTransiently()
        XCTAssertNil(scenario.runtime.commandActions.importCorpus)
        do {
            _ = try await importCorpus([], ReconstructionCancellation(), nil)
            XCTFail("A captured import command must not acquire authority after retirement")
        } catch {
            XCTAssertEqual(error as? ReconstructionWorkspaceRuntimeError, .retired)
        }
        scenario.documentSession.close()
        try? FileManager.default.removeItem(at: scenario.baseDirectoryURL)
    }

    func testPresentationAuthorityCapturesExactCurrentCheckpointFrontierAndRevision() throws {
        let workspace = try ReconstructionDatabaseTestFixtures.makeRichState(
            workspaceBinaryID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000333"
            )!
        )
        let job = try XCTUnwrap(workspace.jobs.first)
        let checkpoint = try XCTUnwrap(workspace.checkpoints.first(where: {
            $0.checkpointID == job.currentCheckpointID
        }))

        let authority = ReconstructionWorkspacePresentationAuthority(workspace: workspace)
        XCTAssertEqual(
            authority.job(job.jobID),
            .init(
                evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
                projectionRevision: checkpoint.revision
            )
        )
        XCTAssertNil(authority.job(UUID()))

        let currentProjection = ReconstructionStatusProjection.project(
            workspace: workspace,
            selectedJobID: job.jobID,
            readiness: .endpointMissing,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete,
            currentEvidenceFrontierSHA256: authority.job(job.jobID)?.evidenceFrontierSHA256,
            durableProjectionRevision: authority.job(job.jobID)?.projectionRevision
        )
        XCTAssertEqual(currentProjection.checkpointFreshness.status, .current)
        XCTAssertEqual(currentProjection.projectionRevision, checkpoint.revision)

        let staleProjection = ReconstructionStatusProjection.project(
            workspace: workspace,
            selectedJobID: job.jobID,
            readiness: .endpointMissing,
            activity: .idle,
            providerRevision: 1,
            restoreStatus: .complete,
            currentEvidenceFrontierSHA256: String(repeating: "f", count: 64),
            durableProjectionRevision: checkpoint.revision + 1
        )
        XCTAssertEqual(staleProjection.checkpointFreshness.status, .stale)
        XCTAssertEqual(staleProjection.projectionRevision, checkpoint.revision + 1)
        XCTAssertEqual(staleProjection.controls.pause.disabledReason, .staleProjection)
        XCTAssertEqual(staleProjection.controls.cancel.disabledReason, .staleProjection)

        // Mutation RED: source either authority coordinate from the selected projection instead
        // of the exact current checkpoint. The exact authority equality or stale command refusal
        // fails, proving this is an independent runtime-owned cut rather than a second rendering.
    }

    func testPhysicalPackageReopenPreservesOrdinalSelectionProjectionAndPublishesBeforeResume()
        async throws {
        let packageFixture = try ReconstructionPackageFixture.make()
        defer { packageFixture.remove() }
        let state = try physicalTwoJobState(from: packageFixture.state)
        let latestJobID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000102"
        )!
        let olderJobID = UUID(
            uuidString: "ffffffff-ffff-ffff-ffff-ffffffffff01"
        )!
        XCTAssertGreaterThan(
            olderJobID.uuidString.lowercased(),
            latestJobID.uuidString.lowercased(),
            "the UUID order must oppose durable creation order"
        )
        let preSaveProjection = ReconstructionStatusProjection.project(
            workspace: state,
            selectedJobID: latestJobID,
            readiness: .endpointMissing,
            activity: .idle,
            providerRevision: 0,
            restoreStatus: .complete
        )
        try MacScopeDocumentPackage.writePackage(
            packageFixture.manifest,
            attachmentsByBinaryID: [
                packageFixture.binaryID: packageFixture.binaryBytes,
            ],
            reconstructionState: state,
            reconstructionAttachmentSources: [packageFixture.source],
            to: packageFixture.packageURL
        )

        let reopenedStore = try WorkspaceStore.restoredPackage(
            from: packageFixture.packageURL,
            scheduleDurableRecovery: false
        )
        reopenedStore.selectedTool = .reconstruction
        reopenedStore.selectDefaultSidebarItemIfNeeded()
        XCTAssertEqual(reopenedStore.selectedReconstructionJobID, latestJobID)
        let reopenedProjection = ReconstructionStatusProjection.project(
            workspace: reopenedStore.reconstructionState,
            selectedJobID: reopenedStore.selectedReconstructionJobID,
            readiness: .endpointMissing,
            activity: .idle,
            providerRevision: 0,
            restoreStatus: .complete
        )
        XCTAssertEqual(reopenedProjection, preSaveProjection)

        let location = try WorkspaceDocumentLocation.canonicalized(
            from: packageFixture.packageURL
        )
        let io = WorkspaceDocumentIO()
        let validatedPackage = try await io.readValidated(from: location)
        let windowID = WorkspaceWindowID.fresh()
        let reservations = ReconstructionRuntimeTestReservations()
        defer { withExtendedLifetime(reservations) {} }
        let documentSession = WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: windowID,
            source: reopenedStore,
            io: io,
            reservations: reservations
        )
        try documentSession.bindOpenedPackage(validatedPackage, at: location)
        let sidecarRoot = packageFixture.root.appendingPathComponent(
            "FreshSidecar",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sidecarRoot,
            withIntermediateDirectories: false
        )
        let sessionProbe = ReconstructionRuntimeSessionFactoryProbe(
            admissionObservation: { _, store in
                guard store.selectedReconstructionJobID == latestJobID else { return false }
                let projection = ReconstructionStatusProjection.project(
                    workspace: store.reconstructionState,
                    selectedJobID: store.selectedReconstructionJobID,
                    readiness: .endpointMissing,
                    activity: .idle,
                    providerRevision: 0,
                    restoreStatus: .complete
                )
                return projection == preSaveProjection
            }
        )
        let runtime = ReconstructionWorkspaceRuntime(
            windowID: windowID,
            store: reopenedStore,
            documentSession: documentSession,
            openDatabaseRuntime: { binding, packageState, sources, workspaceName in
                try ReconstructionWorkspaceDatabaseRuntime.open(
                    binding: binding,
                    packageState: packageState,
                    packageAttachmentSources: sources,
                    workspaceName: workspaceName,
                    baseDirectoryURL: sidecarRoot
                )
            },
            makeJobSession: sessionProbe.factory()
        )

        let activated = await runtime.activateReconstructionDestination()
        XCTAssertTrue(activated)
        XCTAssertEqual(runtime.activationModel.snapshot.phase, .ready)
        XCTAssertEqual(sessionProbe.creationCount, 2)
        XCTAssertEqual(sessionProbe.admissionObservedPublishedProjection, [true, true])

        // Mutation RED recipes:
        // 1. Select the lexicographically greatest UUID instead of greatest creationOrdinal;
        //    the selected-job assertion fails because these fixtures deliberately oppose them.
        // 2. Remove any field from ReconstructionStatusProjection.project; the exact rich
        //    pre-save/reopened projection equality fails.
        // 3. Move restored Store publication after session admission; both recorded admission
        //    observations become false before either optional resume/start can acquire authority.
        // 4. Replace the retained document reservation fixture with an inline temporary; the
        //    package bind fails exactly with `document-reservation-authority-unavailable`.

        await runtime.retireTransiently()
        documentSession.close()
    }

    func testPhysicalVersion3PackageReopenResumesExactPausedJobThroughFreshSession()
        async throws {
        let packageFixture = try ReconstructionPackageFixture.make()
        defer { packageFixture.remove() }
        let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
            workspaceBinaryID: packageFixture.binaryID
        )
        let paused = try pausedState(from: foundation)
        let sourceURL = packageFixture.root.appendingPathComponent(
            "physical-paused-source.bin",
            isDirectory: false
        )
        try Data("test".utf8).write(to: sourceURL)
        let source = ReconstructionAttachmentSource(
            contentIdentity: foundation.occurrence.contentIdentity,
            verifiedURL: sourceURL
        )
        try MacScopeDocumentPackage.writePackage(
            packageFixture.manifest,
            attachmentsByBinaryID: [
                packageFixture.binaryID: packageFixture.binaryBytes,
            ],
            reconstructionState: paused.state,
            reconstructionAttachmentSources: [source],
            to: packageFixture.packageURL
        )

        let physicallyReopened = try MacScopeDocumentPackage.openPackage(
            from: packageFixture.packageURL
        )
        XCTAssertEqual(
            physicallyReopened.manifest.formatVersion,
            WorkspacePackageManifest.instructionSidecarFormatVersion
        )
        XCTAssertEqual(physicallyReopened.manifest.analysisFormatVersion, WorkspacePackageManifest.reconstructionFormatVersion)
        XCTAssertEqual(physicallyReopened.reconstructionState, paused.state)

        let reopenedStore = try WorkspaceStore.restoredPackage(
            from: packageFixture.packageURL,
            scheduleDurableRecovery: false
        )
        reopenedStore.selectedTool = .reconstruction
        reopenedStore.selectDefaultSidebarItemIfNeeded()
        XCTAssertEqual(reopenedStore.selectedReconstructionJobID, paused.job.jobID)

        let location = try WorkspaceDocumentLocation.canonicalized(
            from: packageFixture.packageURL
        )
        let io = WorkspaceDocumentIO()
        let validatedPackage = try await io.readValidated(from: location)
        let windowID = WorkspaceWindowID.fresh()
        let reservations = ReconstructionRuntimeTestReservations()
        defer { withExtendedLifetime(reservations) {} }
        let documentSession = WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: windowID,
            source: reopenedStore,
            io: io,
            reservations: reservations
        )
        try documentSession.bindOpenedPackage(validatedPackage, at: location)
        let sidecarRoot = packageFixture.root.appendingPathComponent(
            "PausedResumeSidecar",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sidecarRoot,
            withIntermediateDirectories: false
        )
        let sessionProbe = ReconstructionRuntimeSessionFactoryProbe()
        let runtime = ReconstructionWorkspaceRuntime(
            windowID: windowID,
            store: reopenedStore,
            documentSession: documentSession,
            openDatabaseRuntime: { binding, packageState, sources, workspaceName in
                try ReconstructionWorkspaceDatabaseRuntime.open(
                    binding: binding,
                    packageState: packageState,
                    packageAttachmentSources: sources,
                    workspaceName: workspaceName,
                    baseDirectoryURL: sidecarRoot
                )
            },
            makeJobSession: sessionProbe.factory()
        )

        let activated = await runtime.activateReconstructionDestination()
        XCTAssertTrue(activated)
        XCTAssertEqual(runtime.activationModel.snapshot.phase, .ready)
        XCTAssertEqual(sessionProbe.creationCount, 0)

        let authority = commandAuthority(job: paused.job, checkpoint: paused.checkpoint)
        let resumed = await runtime.resume(authority: authority)
        XCTAssertTrue(resumed)
        let resumedJobIDs = await sessionProbe.coordinator.resumedJobIDs()
        let schedulerResumeIDs = await sessionProbe.scheduler.resumedJobIDs()
        XCTAssertEqual(sessionProbe.creationCount, 1)
        XCTAssertEqual(resumedJobIDs, [paused.job.jobID])
        XCTAssertTrue(
            schedulerResumeIDs.isEmpty,
            "the physically reopened job must resume through one fresh session"
        )

        // Mandatory mutation RED: replace `runtime.resume(authority: authority)` with a call
        // carrying a different job coordinate. The exact resumed-job assertion fails while the
        // physical package-v3 write/open and fresh-runtime activation still succeed.
        await runtime.retireTransiently()
        documentSession.close()
    }

    func testRegistryCreatesOnlyLightweightRuntimeForUntitledWindow() async throws {
        let probe = ReconstructionWorkspaceRuntimeFactoryProbe()
        let registry = WorkspaceSessionRegistry(
            reconstructionRuntimeFactory: probe.factory()
        )
        let windowID = WorkspaceWindowID.fresh()

        let runtime = try XCTUnwrap(registry.reconstructionRuntime(
            for: windowID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        ))
        let store = try XCTUnwrap(registry.storeIfPresent(for: windowID))
        let session = try XCTUnwrap(registry.documentSessionIfPresent(for: windowID))

        XCTAssertTrue(runtime.isCurrent(for: store, documentSession: session))
        XCTAssertEqual(probe.runtimeCreationCount, 1)
        XCTAssertEqual(probe.databaseOpenCount, 0)
        XCTAssertEqual(probe.jobSessionCreationCount, 0)
        XCTAssertNil(runtime.commandActions.createJob)
        XCTAssertNil(runtime.commandActions.startJob)
        XCTAssertNil(runtime.commandActions.pauseJob)
        XCTAssertNil(runtime.commandActions.resumeJob)
        XCTAssertNil(runtime.commandActions.cancelJob)

        let activated = await runtime.activateReconstructionDestination()
        XCTAssertFalse(activated)
        XCTAssertEqual(
            runtime.activationModel.snapshot.phase,
            .failed(.documentLocationRequired)
        )
        XCTAssertEqual(probe.databaseOpenCount, 0)

        await registry.shutdown()
        XCTAssertFalse(runtime.isCurrent(for: store, documentSession: session))
        XCTAssertEqual(probe.databaseOpenCount, 0)
        XCTAssertEqual(probe.jobSessionCreationCount, 0)
    }

    func testDistinctWindowsReceiveDistinctLifecycleOwners() async throws {
        let probe = ReconstructionWorkspaceRuntimeFactoryProbe()
        let registry = WorkspaceSessionRegistry(
            reconstructionRuntimeFactory: probe.factory()
        )
        let firstID = WorkspaceWindowID.fresh()
        let secondID = WorkspaceWindowID.fresh()

        let first = try XCTUnwrap(registry.reconstructionRuntime(
            for: firstID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        ))
        let second = try XCTUnwrap(registry.reconstructionRuntime(
            for: secondID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        ))

        XCTAssertFalse(first === second)
        XCTAssertEqual(probe.runtimeCreationCount, 2)
        XCTAssertEqual(probe.databaseOpenCount, 0)

        await registry.shutdown()
    }

    func testSameIdentityRestoreReplacesAndRetiresPriorRuntime() async throws {
        let probe = ReconstructionWorkspaceRuntimeFactoryProbe()
        let registry = WorkspaceSessionRegistry(
            reconstructionRuntimeFactory: probe.factory()
        )
        let windowID = WorkspaceWindowID.fresh()
        let first = try XCTUnwrap(registry.reconstructionRuntime(
            for: windowID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        ))
        let store = try XCTUnwrap(registry.storeIfPresent(for: windowID))
        let documentSession = try XCTUnwrap(
            registry.documentSessionIfPresent(for: windowID)
        )
        let originalWorkspaceID = store.workspaceID
        let originalDocumentID = store.documentID

        store.restoreWorkspace(sameIdentityWorkspace(for: store))
        XCTAssertEqual(store.workspaceID, originalWorkspaceID)
        XCTAssertEqual(store.documentID, originalDocumentID)
        XCTAssertFalse(first.isCurrent(for: store, documentSession: documentSession))

        let replacement = try XCTUnwrap(registry.reconstructionRuntime(
            for: windowID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        ))
        XCTAssertFalse(first === replacement)
        XCTAssertTrue(replacement.isCurrent(
            for: store,
            documentSession: documentSession
        ))
        XCTAssertEqual(probe.runtimeCreationCount, 2)
        XCTAssertEqual(probe.databaseOpenCount, 0)
        XCTAssertEqual(probe.jobSessionCreationCount, 0)

        await registry.shutdown()
    }

    func testObservedDocumentLocationTransitionReplacesAndActivatesExactRuntime() async throws {
        let sidecarRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionRuntimeHost-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sidecarRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: sidecarRoot) }

        let windowID = WorkspaceWindowID.fresh()
        let store = WorkspaceStore.bootstrap()
        store.selectedTool = .reconstruction
        let reservations = ReconstructionRuntimeTestReservations()
        defer { withExtendedLifetime(reservations) {} }
        let documentSession = try openedDocumentSession(
            windowID: windowID,
            store: store,
            reservations: reservations
        )
        let firstSidecarRoot = sidecarRoot.appendingPathComponent(
            "FirstRuntime",
            isDirectory: true
        )
        let replacementSidecarRoot = sidecarRoot.appendingPathComponent(
            "ReplacementRuntime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstSidecarRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: replacementSidecarRoot,
            withIntermediateDirectories: false
        )
        var runtimeCreationCount = 0
        let registry = WorkspaceSessionRegistry(
            reconstructionRuntimeFactory: {
                windowID,
                store,
                documentSession,
                predecessorRetirement in
                runtimeCreationCount += 1
                let runtimeSidecarRoot = runtimeCreationCount == 1
                    ? firstSidecarRoot
                    : replacementSidecarRoot
                return ReconstructionWorkspaceRuntime(
                    windowID: windowID,
                    store: store,
                    documentSession: documentSession,
                    predecessorRetirement: predecessorRetirement,
                    openDatabaseRuntime: { binding, state, sources, workspaceName in
                        try ReconstructionWorkspaceDatabaseRuntime.open(
                            binding: binding,
                            packageState: state,
                            packageAttachmentSources: sources,
                            workspaceName: workspaceName,
                            baseDirectoryURL: runtimeSidecarRoot
                        )
                    },
                    makeJobSession: { _, _, _, _ in
                        throw ReconstructionRuntimeCompositionTestError.unexpectedJobSession
                    }
                )
            }
        )
        registry.adopt(store, documentSession: documentSession, for: windowID)

        let first = try XCTUnwrap(registry.reconstructionRuntime(
            for: windowID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        ))
        let firstActivated = await first.activateReconstructionDestination()
        XCTAssertTrue(firstActivated)
        XCTAssertEqual(first.activationModel.snapshot.phase, .ready)

        let replacementLocation = WorkspaceDocumentLocation(
            canonicalURL: sidecarRoot.appendingPathComponent(
                "Saved-As.mscope",
                isDirectory: true
            ),
            fileObjectIdentity: nil
        )
        let digest = String(repeating: "c", count: 64)
        let replacementObservation = WorkspacePackageExternalVersion(
            location: replacementLocation,
            condition: .valid,
            observationSHA256: digest,
            manifestSHA256: digest,
            validatedContentSHA256: digest,
            boundedReason: nil
        )
        try documentSession.bindOpenedPackage(
            WorkspaceDocumentValidatedPackage(
                manifestData: Data("runtime-host-location-transition".utf8),
                attachmentsByBinaryID: [:],
                observation: replacementObservation
            ),
            at: replacementLocation
        )

        XCTAssertFalse(first.isCurrent(for: store, documentSession: documentSession))
        let replacement = try XCTUnwrap(registry.reconstructionRuntime(
            for: windowID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        ))
        XCTAssertFalse(first === replacement)
        XCTAssertTrue(replacement.isCurrent(for: store, documentSession: documentSession))
        let replacementActivated = await replacement.activateReconstructionDestination()
        XCTAssertTrue(replacementActivated)
        XCTAssertEqual(replacement.activationModel.snapshot.phase, .ready)
        XCTAssertEqual(runtimeCreationCount, 2)

        // Mutation REDs:
        // 1. Drop the strong reservation fixture before the observed location transition; the
        //    second bind throws exactly `document-reservation-authority-unavailable`.
        // 2. Reuse one sidecar test root across both synthetic package paths; the replacement
        //    activation fails closed on the sidecar's canonical-package-path binding instead of
        //    testing the registry's runtime-replacement responsibility in isolation.

        await registry.shutdown()
    }

    func testStartActivationIsCoalescedByDurableJobID() async throws {
        let scenario = try await makeDurableScenario(paused: false, activate: false)
        let authority = commandAuthority(
            job: scenario.job,
            checkpoint: scenario.checkpoint
        )
        await scenario.sessionProbe.coordinator.holdStarts()

        let activation = Task { await scenario.runtime.activateReconstructionDestination() }
        await scenario.sessionProbe.coordinator.waitUntilStarted()
        let activated = await activation.value
        XCTAssertTrue(activated)
        XCTAssertEqual(scenario.runtime.activationModel.snapshot.phase, .ready)
        let duplicateAccepted = await scenario.runtime.start(authority: authority)
        XCTAssertFalse(
            duplicateAccepted,
            "a second activation must be rejected while the first retained run is active"
        )
        let duplicateDestinationActivation = await scenario.runtime
            .activateReconstructionDestination()
        let startedJobIDs = await scenario.sessionProbe.coordinator.startedJobIDs()
        XCTAssertTrue(duplicateDestinationActivation)
        XCTAssertEqual(scenario.sessionProbe.creationCount, 1)
        XCTAssertEqual(
            startedJobIDs,
            [scenario.job.jobID],
            "a ready destination must not enumerate or admit the same durable job twice"
        )

        await scenario.sessionProbe.coordinator.releaseStarts()
        await scenario.runtime.retireTransiently()
        let acceptedAfterRetirement = await scenario.runtime.start(authority: authority)
        XCTAssertFalse(acceptedAfterRetirement)

        // Mutation RED: remove durable-job coalescing after admission; the duplicate start above
        // dispatches a second coordinator run while the retained first run remains live.
        scenario.documentSession.close()
        try? FileManager.default.removeItem(at: scenario.baseDirectoryURL)
    }

    func testExplicitRestorationPublishesReadyAfterAdmissionWhileCoordinatorRunRemainsLive()
        async throws
    {
        let scenario = try await makeDurableScenario(paused: false, activate: false)
        await scenario.sessionProbe.coordinator.holdStarts()

        let restored = await scenario.runtime.restoreAndResumeEligibleJobs()
        XCTAssertTrue(restored)
        await scenario.sessionProbe.coordinator.waitUntilStarted()
        let completedBeforeRelease = await scenario.sessionProbe.coordinator
            .completedStartJobIDs()
        XCTAssertTrue(completedBeforeRelease.isEmpty)
        XCTAssertEqual(
            scenario.runtime.activationModel.snapshot.phase,
            .ready,
            "installed admission, not full coordinator lifetime, is the readiness barrier"
        )
        let actions = scenario.runtime.commandActions
        XCTAssertNotNil(actions.pauseJob)
        XCTAssertNotNil(actions.cancelJob)

        await scenario.sessionProbe.coordinator.releaseStarts()
        let coordinatorCompleted = await waitUntil {
            await scenario.sessionProbe.coordinator.completedStartJobIDs()
                == [scenario.job.jobID]
        }
        XCTAssertTrue(coordinatorCompleted)
        XCTAssertEqual(scenario.runtime.activationModel.snapshot.phase, .ready)

        // Mandatory mutation RED: reattach restoration readiness to coordinator completion; the
        // pre-release phase and Pause/Cancel availability assertions fail.
        await scenario.close()
    }

    func testEligibleJobRestorationFailureIsObservableAndRetryable() async throws {
        let scenario = try await makeDurableScenario(
            paused: false,
            activate: false,
            sessionFactoryFailures: 1
        )

        let first = await scenario.runtime.activateReconstructionDestination()
        XCTAssertFalse(first)
        XCTAssertEqual(
            scenario.runtime.activationModel.snapshot.phase,
            .failed(.restorationUnavailable)
        )
        XCTAssertNil(scenario.runtime.commandActions.startJob)

        let second = await scenario.runtime.activateReconstructionDestination()
        XCTAssertTrue(second)
        let becameReady = await waitUntil {
            scenario.runtime.activationModel.snapshot.phase == .ready
        }
        XCTAssertTrue(becameReady)
        XCTAssertEqual(scenario.runtime.activationModel.snapshot.phase, .ready)
        await scenario.sessionProbe.coordinator.waitUntilStarted()
        XCTAssertEqual(scenario.sessionProbe.creationCount, 2)
        await scenario.close()
    }

    func testLaterEligibleJobAdmissionFailureUnwindsEarlierTransientSessionBeforeRetry()
        async throws
    {
        let scenario = try await makeTwoJobDurableScenario(
            failingJobIDs: [
                UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
            ]
        )
        let firstJobID = try XCTUnwrap(scenario.jobs.first?.jobID)
        let laterJobID = try XCTUnwrap(scenario.jobs.last?.jobID)

        let first = await scenario.runtime.activateReconstructionDestination()
        XCTAssertFalse(first)
        XCTAssertEqual(
            scenario.runtime.activationModel.snapshot.phase,
            .failed(.restorationUnavailable)
        )
        XCTAssertEqual(scenario.sessionProbe.creationCount, 2)
        let startedAfterFailedAttempt = await scenario.sessionProbe.coordinator.startedJobIDs()
        XCTAssertEqual(
            startedAfterFailedAttempt,
            [firstJobID],
            "only the durable prefix may start before the later admission fails"
        )
        let firstWasRetired = await waitUntil {
            await scenario.sessionProbe.scheduler.retiredJobIDs() == [firstJobID]
        }
        XCTAssertTrue(
            firstWasRetired,
            "a failed multi-job restoration must retire its attempt-owned live prefix"
        )

        let second = await scenario.runtime.activateReconstructionDestination()
        XCTAssertTrue(second)
        let becameReady = await waitUntil {
            scenario.runtime.activationModel.snapshot.phase == .ready
        }
        XCTAssertTrue(becameReady)
        XCTAssertEqual(scenario.sessionProbe.creationCount, 4)
        // Ready means every session retained its coordinator task, not that those independent
        // tasks have already entered the coordinator actor. Await the observable run boundary
        // before asserting the unchanged exact prefix/retry sequence.
        let retryRunsStarted = await waitUntil {
            await scenario.sessionProbe.coordinator.startedJobIDs().count == 3
        }
        XCTAssertTrue(retryRunsStarted, "every admitted retry job must enter the coordinator")
        let startedAfterRetry = await scenario.sessionProbe.coordinator.startedJobIDs()
        XCTAssertEqual(
            startedAfterRetry,
            [firstJobID, firstJobID, laterJobID],
            "retry must create a fresh exact prefix rather than reuse a stranded session"
        )

        // Mandatory mutation RED: remove `unwindFailedRestorationAttempt` from the catch path.
        // The first scheduler-retirement assertion remains red and the retry's first session is
        // rejected because the stale prefix is still installed in this runtime.
        await scenario.close()
    }

    func testActivationStaysRestoringUntilEligibleSessionAdmissionSucceeds() async throws {
        let scenario = try await makeDurableScenario(paused: false, activate: false)
        scenario.sessionProbe.holdCreations()
        let activationOutcome = ReconstructionRuntimeActivationProbe()

        let activation = Task {
            let result = await scenario.runtime.activateReconstructionDestination()
            activationOutcome.complete(result)
            return result
        }
        let observedCreationOrEarlyCompletion = await waitUntil {
            scenario.sessionProbe.creationCount > 0 || activationOutcome.result != nil
        }
        XCTAssertTrue(
            observedCreationOrEarlyCompletion,
            "activation neither entered session admission nor completed within the bounded wait"
        )
        guard observedCreationOrEarlyCompletion else {
            scenario.sessionProbe.releaseCreations()
            activation.cancel()
            let cancellationSettled = await waitUntil(timeout: .seconds(1)) {
                activationOutcome.result != nil
            }
            if cancellationSettled {
                await scenario.close()
            } else {
                scenario.documentSession.close()
            }
            return
        }
        guard activationOutcome.result == nil else {
            let earlyResult = try XCTUnwrap(activationOutcome.result)
            let restorationDiagnostic = await scenario.databaseOpenProbe
                .restorationDiagnostic(
                    workspaceID: scenario.store.workspaceID,
                    jobID: scenario.job.jobID
                )
            scenario.sessionProbe.releaseCreations()
            XCTFail(
                "activation completed with result \(earlyResult) before the eligible "
                    + "session-admission seam was reached; \(restorationDiagnostic)"
            )
            await scenario.close()
            return
        }

        XCTAssertEqual(scenario.runtime.activationModel.snapshot.phase, .restoring)
        XCTAssertNil(scenario.runtime.commandActions.startJob)

        scenario.sessionProbe.releaseCreations()
        await scenario.sessionProbe.coordinator.waitUntilStarted()
        let activated = await activation.value
        XCTAssertTrue(activated)
        let becameReady = await waitUntil {
            scenario.runtime.activationModel.snapshot.phase == .ready
        }
        XCTAssertTrue(becameReady)
        XCTAssertEqual(scenario.runtime.activationModel.snapshot.phase, .ready)

        // Mutation RED: make the injected database factory throw before session creation. This
        // must now fail here with the explicit early-completion diagnostic instead of timing out.
        await scenario.close()
    }

    func testEmptyDurableWorkspaceRetriesSidecarOpenAndBecomesReadyWithoutAJobSession() async throws {
        let baseDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionActivationRetry-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: baseDirectoryURL,
            withIntermediateDirectories: false
        )
        let store = WorkspaceStore(
            workspaceName: "Empty durable activation fixture",
            snapshot: AnalysisEngine.previewSnapshot(),
            engine: AnalysisEngine(),
            autosaveScheduler: nil
        )
        let windowID = WorkspaceWindowID.fresh()
        let documentSession = try openedDocumentSession(
            windowID: windowID,
            store: store,
            reservations: ReconstructionRuntimeTestReservations()
        )
        let openProbe = ReconstructionActivationDatabaseOpenProbe(
            baseDirectoryURL: baseDirectoryURL,
            remainingFailures: 1
        )
        let sessionProbe = ReconstructionRuntimeSessionFactoryProbe()
        let runtime = ReconstructionWorkspaceRuntime(
            windowID: windowID,
            store: store,
            documentSession: documentSession,
            openDatabaseRuntime: { binding, state, sources, name in
                try await openProbe.open(
                    binding: binding,
                    state: state,
                    sources: sources,
                    workspaceName: name
                )
            },
            makeJobSession: sessionProbe.factory()
        )

        let first = await runtime.activateReconstructionDestination()
        XCTAssertFalse(first)
        XCTAssertEqual(runtime.activationModel.snapshot.phase, .failed(.sidecarUnavailable))
        XCTAssertNil(runtime.commandActions.createJob)

        let second = await runtime.activateReconstructionDestination()
        XCTAssertTrue(second)
        XCTAssertEqual(runtime.activationModel.snapshot.phase, .ready)
        let attempts = await openProbe.attemptCount()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sessionProbe.creationCount, 0)

        await runtime.retireTransiently()
        documentSession.close()
        try? FileManager.default.removeItem(at: baseDirectoryURL)
    }

    func testProductionAnalysisPolicyIsFixedAndFailsClosedWithoutReserve() throws {
        let gibibyte: UInt64 = 1_073_741_824
        let budget = ReconstructionProductionComposition.productionAnalysisBudget
        // PERF-B (#301): the outer/inner widths come from the shared CPU policy (2 outer x 3
        // inner = 6 aggregate slots on the 10-core reference Mac), not a fixed outer 6.
        XCTAssertTrue(AnalysisHostResourcePolicy.reconstructionParallelism(processorCount: 10) == (2, 3))
        let slots = AnalysisHostResourcePolicy.reconstructionParallelism(
            processorCount: ProcessInfo.processInfo.activeProcessorCount)

        XCTAssertEqual(budget.maximumActiveAnalyses, slots.outer)
        XCTAssertEqual(budget.maximumInnerParallelism, slots.inner)
        XCTAssertEqual(budget.estimatedResidentBytesPerAnalysis, 2 * gibibyte)
        XCTAssertEqual(budget.reservedHostBytes, 4 * gibibyte)
        XCTAssertEqual(
            try budget.width(
                processorCount: 8,
                physicalMemory: 64 * gibibyte
            ),
            min(slots.outer, max(1, 8 / slots.inner))
        )
        XCTAssertThrowsError(try budget.width(
            processorCount: 8,
            physicalMemory: 4 * gibibyte
        )) { error in
            XCTAssertEqual(
                error as? ReconstructionAnalysisProviderPoolBudgetError,
                .insufficientHostMemory
            )
        }
    }

    func testWorkerSourceBoundaryUsesTinyFinalKindWithoutAppTerminalAuthority() throws {
        var root = TestSourceRoot.fileURL(#filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let project = try String(
            contentsOf: root.appendingPathComponent("MacScope/project.yml"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(project.range(of: "  AIAgentWorkerXPCService:"))
        let suffix = project[start.lowerBound...]
        let end = try XCTUnwrap(suffix.range(of: "  NativeDecompilerXPCService:"))
        let worker = String(suffix[..<end.lowerBound])

        XCTAssertTrue(worker.contains(
            "Models/Reconstruction/ReconstructionFinalSynthesisKind.swift"
        ))
        XCTAssertTrue(worker.contains(
            "Models/Reconstruction/ReconstructionInference.swift"
        ))
        XCTAssertFalse(worker.contains(
            "Services/Reconstruction/ReconstructionModelTerminalRequestAuthority.swift"
        ))
        XCTAssertFalse(worker.contains(
            "Services/Reconstruction/ReconstructionCanonicalJSON.swift"
        ))
    }

    func testPausedDurableJobMayBindOnlyWithValidResumeAuthority() throws {
        let pauseContext = try ReconstructionJobPauseContext(
            cause: .pausedByUser,
            resumeTarget: .indexing
        )

        XCTAssertTrue(ReconstructionDatabaseJobPersistence.acceptsNativeAdmissionBinding(
            state: .created,
            pauseContext: nil
        ))
        XCTAssertTrue(ReconstructionDatabaseJobPersistence.acceptsNativeAdmissionBinding(
            state: .paused,
            pauseContext: pauseContext
        ))
        XCTAssertFalse(ReconstructionDatabaseJobPersistence.acceptsNativeAdmissionBinding(
            state: .paused,
            pauseContext: nil
        ))
        XCTAssertFalse(ReconstructionDatabaseJobPersistence.acceptsNativeAdmissionBinding(
            state: .completed,
            pauseContext: nil
        ))
        XCTAssertFalse(ReconstructionDatabaseJobPersistence.acceptsNativeAdmissionBinding(
            state: .ingesting,
            pauseContext: pauseContext
        ))
    }

    func testEveryCommandAuthorityFieldIsRebuiltFromDatabaseBeforeDispatch() async throws {
        let scenario = try await makeDurableScenario(paused: true)
        let valid = commandAuthority(
            job: scenario.job,
            checkpoint: scenario.checkpoint
        )
        let staleAuthorities = [
            ReconstructionJobCommandAuthority(
                jobID: UUID(),
                expectedJobState: valid.expectedJobState,
                checkpointID: valid.checkpointID,
                checkpointRevision: valid.checkpointRevision,
                corpusManifestSHA256: valid.corpusManifestSHA256,
                evidenceFrontierSHA256: valid.evidenceFrontierSHA256
            ),
            ReconstructionJobCommandAuthority(
                jobID: valid.jobID,
                expectedJobState: .indexing,
                checkpointID: valid.checkpointID,
                checkpointRevision: valid.checkpointRevision,
                corpusManifestSHA256: valid.corpusManifestSHA256,
                evidenceFrontierSHA256: valid.evidenceFrontierSHA256
            ),
            ReconstructionJobCommandAuthority(
                jobID: valid.jobID,
                expectedJobState: valid.expectedJobState,
                checkpointID: UUID(),
                checkpointRevision: valid.checkpointRevision,
                corpusManifestSHA256: valid.corpusManifestSHA256,
                evidenceFrontierSHA256: valid.evidenceFrontierSHA256
            ),
            ReconstructionJobCommandAuthority(
                jobID: valid.jobID,
                expectedJobState: valid.expectedJobState,
                checkpointID: valid.checkpointID,
                checkpointRevision: valid.checkpointRevision + 1,
                corpusManifestSHA256: valid.corpusManifestSHA256,
                evidenceFrontierSHA256: valid.evidenceFrontierSHA256
            ),
            ReconstructionJobCommandAuthority(
                jobID: valid.jobID,
                expectedJobState: valid.expectedJobState,
                checkpointID: valid.checkpointID,
                checkpointRevision: valid.checkpointRevision,
                corpusManifestSHA256: String(repeating: "c", count: 64),
                evidenceFrontierSHA256: valid.evidenceFrontierSHA256
            ),
            ReconstructionJobCommandAuthority(
                jobID: valid.jobID,
                expectedJobState: valid.expectedJobState,
                checkpointID: valid.checkpointID,
                checkpointRevision: valid.checkpointRevision,
                corpusManifestSHA256: valid.corpusManifestSHA256,
                evidenceFrontierSHA256: String(repeating: "d", count: 64)
            ),
        ]

        for stale in staleAuthorities {
            await scenario.runtime.cancel(authority: stale)
        }

        let cancelledBeforeValid = await scenario.sessionProbe.coordinator.cancelledJobIDs()
        let retiredBeforeValid = await scenario.sessionProbe.scheduler.retiredJobIDs()
        XCTAssertEqual(scenario.sessionProbe.creationCount, 0)
        XCTAssertTrue(cancelledBeforeValid.isEmpty)
        XCTAssertTrue(retiredBeforeValid.isEmpty)

        await scenario.runtime.cancel(authority: valid)

        let cancelledAfterValid = await scenario.sessionProbe.coordinator.cancelledJobIDs()
        let retiredAfterValid = await scenario.sessionProbe.scheduler.retiredJobIDs()
        XCTAssertEqual(scenario.sessionProbe.creationCount, 1)
        XCTAssertEqual(cancelledAfterValid, [valid.jobID])
        XCTAssertEqual(retiredAfterValid, [valid.jobID])
        await scenario.close()
    }

    func testReopenedPausedJobResumeExecutesThroughFreshSession() async throws {
        let scenario = try await makeDurableScenario(paused: true)
        let authority = commandAuthority(
            job: scenario.job,
            checkpoint: scenario.checkpoint
        )

        let resumed = await scenario.runtime.resume(authority: authority)
        XCTAssertTrue(resumed)

        let resumedJobIDs = await scenario.sessionProbe.coordinator.resumedJobIDs()
        let schedulerResumeIDs = await scenario.sessionProbe.scheduler.resumedJobIDs()
        XCTAssertEqual(scenario.sessionProbe.creationCount, 1)
        XCTAssertEqual(resumedJobIDs, [authority.jobID])
        XCTAssertTrue(
            schedulerResumeIDs.isEmpty,
            "a fresh session has no preexisting scheduler child to resume"
        )
        await scenario.close()
    }

    func testCommandOutcomeEchoesExactWindowCoordinateAndRejectsAfterRetirement() async throws {
        let scenario = try await makeDurableScenario(paused: false)
        let actions = scenario.runtime.commandActions
        let cancel = try XCTUnwrap(actions.cancelJob)
        let context = ReconstructionWorkspaceCommandContext(
            windowID: scenario.runtime.windowID.raw,
            commandScopeID: actions.commandScopeID,
            commandGeneration: 17,
            baseProjectionRevision: 41,
            jobID: scenario.job.jobID
        )

        let completed = await cancel(scenario.job.jobID, context)
        XCTAssertEqual(completed.context, context)
        XCTAssertEqual(completed.disposition, .completed)
        XCTAssertNil(completed.createdJobID)

        let siblingContext = ReconstructionWorkspaceCommandContext(
            windowID: UUID(),
            commandScopeID: actions.commandScopeID,
            commandGeneration: 18,
            baseProjectionRevision: 42,
            jobID: scenario.job.jobID
        )
        let sibling = await cancel(scenario.job.jobID, siblingContext)
        XCTAssertEqual(sibling.context, siblingContext)
        XCTAssertEqual(sibling.disposition, .rejected)

        let foreignScopeContext = ReconstructionWorkspaceCommandContext(
            windowID: scenario.runtime.windowID.raw,
            commandScopeID: UUID(),
            commandGeneration: context.commandGeneration,
            baseProjectionRevision: context.baseProjectionRevision,
            jobID: context.jobID
        )
        let foreignScope = await cancel(scenario.job.jobID, foreignScopeContext)
        XCTAssertEqual(foreignScope.context, foreignScopeContext)
        XCTAssertEqual(foreignScope.disposition, .rejected)

        await scenario.runtime.retireTransiently()
        let retired = await cancel(scenario.job.jobID, context)
        XCTAssertEqual(retired.context, context)
        XCTAssertEqual(retired.disposition, .rejected)
        scenario.documentSession.close()
        try? FileManager.default.removeItem(at: scenario.baseDirectoryURL)
    }

    func testAwaitedCreateOutcomeReturnsExactContextAndCommittedJobIdentity() async throws {
        let scenario = try await makeDurableScenario(paused: true)
        let actions = scenario.runtime.commandActions
        let create = try XCTUnwrap(actions.createJob)
        let items = ReconstructionJobCreationItem.committedItems(
            in: scenario.store.reconstructionState
        )
        let request = try XCTUnwrap(ReconstructionJobCreationRequest(
            selectedItems: items,
            committedItems: items,
            objective: "Recover the selected committed image",
            budget: try ReconstructionJobBudget(
                maxRounds: 4,
                maxTasks: 64,
                maxEvidenceRecords: 128,
                maxEncodedBytes: 1_048_576
            )
        ))
        let context = ReconstructionWorkspaceCommandContext(
            windowID: scenario.runtime.windowID.raw,
            commandScopeID: actions.commandScopeID,
            commandGeneration: 51,
            baseProjectionRevision: 71,
            jobID: nil
        )

        let outcome = await create(request, context)

        XCTAssertEqual(outcome.context, context)
        XCTAssertEqual(outcome.disposition, .completed)
        let createdJobID = try XCTUnwrap(outcome.createdJobID)
        XCTAssertTrue(scenario.store.reconstructionState.jobs.contains {
            $0.jobID == createdJobID
        })
        await scenario.close()
    }

    func testAwaitedPauseAndResumeOutcomesReflectExactSessionAcceptance() async throws {
        let active = try await makeDurableScenario(paused: false)
        let activeActions = active.runtime.commandActions
        let pause = try XCTUnwrap(activeActions.pauseJob)
        let pauseContext = ReconstructionWorkspaceCommandContext(
            windowID: active.runtime.windowID.raw,
            commandScopeID: activeActions.commandScopeID,
            commandGeneration: 61,
            baseProjectionRevision: 81,
            jobID: active.job.jobID
        )

        let pauseOutcome = await pause(active.job.jobID, pauseContext)

        XCTAssertEqual(pauseOutcome.context, pauseContext)
        XCTAssertEqual(pauseOutcome.disposition, .completed)
        await active.close()

        let paused = try await makeDurableScenario(paused: true)
        let pausedActions = paused.runtime.commandActions
        let resume = try XCTUnwrap(pausedActions.resumeJob)
        let resumeContext = ReconstructionWorkspaceCommandContext(
            windowID: paused.runtime.windowID.raw,
            commandScopeID: pausedActions.commandScopeID,
            commandGeneration: 62,
            baseProjectionRevision: 82,
            jobID: paused.job.jobID
        )

        let resumeOutcome = await resume(paused.job.jobID, resumeContext)

        XCTAssertEqual(resumeOutcome.context, resumeContext)
        XCTAssertEqual(resumeOutcome.disposition, .completed)
        await paused.close()
    }

    func testInFlightOldRuntimeOutcomeCannotCrossSameWindowScopeReplacement() async throws {
        let scenario = try await makeDurableScenario(paused: false)
        await scenario.sessionProbe.coordinator.holdPauses()
        let oldActions = scenario.runtime.commandActions
        let pause = try XCTUnwrap(oldActions.pauseJob)
        let oldContext = ReconstructionWorkspaceCommandContext(
            windowID: scenario.runtime.windowID.raw,
            commandScopeID: oldActions.commandScopeID,
            commandGeneration: 73,
            baseProjectionRevision: 91,
            jobID: scenario.job.jobID
        )
        let oldOutcome = Task { await pause(scenario.job.jobID, oldContext) }
        await scenario.sessionProbe.coordinator.waitUntilPaused()

        let predecessorRetirement = scenario.runtime.beginRetirement()
        let replacementProbe = ReconstructionRuntimeSessionFactoryProbe()
        let baseDirectoryURL = scenario.baseDirectoryURL
        let replacement = ReconstructionWorkspaceRuntime(
            windowID: scenario.runtime.windowID,
            store: scenario.store,
            documentSession: scenario.documentSession,
            predecessorRetirement: predecessorRetirement,
            openDatabaseRuntime: { binding, state, sources, workspaceName in
                try ReconstructionWorkspaceDatabaseRuntime.open(
                    binding: binding,
                    packageState: state,
                    packageAttachmentSources: sources,
                    workspaceName: workspaceName,
                    baseDirectoryURL: baseDirectoryURL
                )
            },
            makeJobSession: replacementProbe.factory()
        )
        XCTAssertNotEqual(replacement.lifecycleID, oldActions.commandScopeID)
        XCTAssertNil(replacement.commandActions.pauseJob)

        await scenario.sessionProbe.coordinator.releasePauses()
        let rejectedOldOutcome = await oldOutcome.value
        XCTAssertEqual(rejectedOldOutcome.context, oldContext)
        XCTAssertEqual(rejectedOldOutcome.disposition, .rejected)
        await predecessorRetirement.value

        let replacementActivated = await replacement.activateReconstructionDestination()
        XCTAssertTrue(replacementActivated)
        let replacementBecameReady = await waitUntil {
            replacement.activationModel.snapshot.phase == .ready
        }
        XCTAssertTrue(replacementBecameReady)
        XCTAssertEqual(replacement.activationModel.snapshot.phase, .ready)
        XCTAssertEqual(
            replacement.commandActions.commandScopeID,
            replacement.lifecycleID
        )

        // Mutation RED: make the diagnostic database probe retain its opened runtime strongly;
        // the predecessor's retired identity claim remains artificially live and replacement
        // activation fails exactly as `.failed(.sidecarUnavailable)`.

        await replacement.retireTransiently()
        scenario.documentSession.close()
        try? FileManager.default.removeItem(at: scenario.baseDirectoryURL)
    }

    func testProductionFactoryFailsClosedForUnsignedNonBundle() {
        XCTAssertNil(ReconstructionProductionComposition.jobSessionFactoryBuilder(
            nativeDecompilerRuntime: .productionShared,
            appBundleURL: URL(fileURLWithPath: NSTemporaryDirectory())
        ))
    }

    func testRuntimeServicesBuilderReceivesExactInferenceCoordinator() async throws {
        let inference = ReconstructionRuntimeUnusedInferenceCoordinator()
        let identityProbe = ReconstructionRuntimeInferenceIdentityProbe()
        let services = MacScopeAppRuntimeServices.testing(
            debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities(),
            nativeDecompilerRuntime: .productionShared,
            reconstructionJobSessionFactoryBuilder: { injected in
                identityProbe.injected = injected as AnyObject
                return { _, _, _, _ in
                    throw ReconstructionRuntimeCompositionTestError.unexpectedJobSession
                }
            }
        )

        let factory = await services.reconstructionWorkspaceRuntimeFactory(
            inferenceCoordinator: inference
        )
        XCTAssertNotNil(factory)
        XCTAssertTrue(identityProbe.injected === inference)
    }

    func testRuntimeServicesValidatesOnceOffMainAcrossCopiesWhileMainActorRemainsResponsive()
        async {
        let inference = ReconstructionRuntimeUnusedInferenceCoordinator()
        let validation = ReconstructionStartupValidationProbe(builder: { _ in
            { _, _, _, _ in
                throw ReconstructionRuntimeCompositionTestError.unexpectedJobSession
            }
        })
        defer { validation.release() }
        let services = MacScopeAppRuntimeServices.testing(
            debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities(),
            nativeDecompilerRuntime: .productionShared,
            reconstructionJobSessionFactoryBuilderResolver: validation.resolve
        )
        let copiedServices = services
        let results = ReconstructionStartupFactoryResults()
        let first = Task {
            results.record(await services.reconstructionWorkspaceRuntimeFactory(
                inferenceCoordinator: inference
            ))
        }
        let second = Task {
            results.record(await copiedServices.reconstructionWorkspaceRuntimeFactory(
                inferenceCoordinator: inference
            ))
        }
        defer { first.cancel(); second.cancel() }

        let entered = await waitUntil { validation.callCount > 0 }
        XCTAssertTrue(entered)
        var heartbeatRan = false
        Task { @MainActor in heartbeatRan = true }
        let responsive = await waitUntil { heartbeatRan }
        XCTAssertTrue(responsive, "pending signature verification must not block MainActor")
        XCTAssertEqual(results.factories.count, 0, "pending validation must expose no factory")
        XCTAssertEqual(validation.callCount, 1, "copies must await one validation task")
        XCTAssertFalse(validation.ranOnMainThread)
        XCTAssertFalse(validation.timedOut)
        XCTAssertTrue(copiedServices.nativeDecompilerRuntime === services.nativeDecompilerRuntime)
        XCTAssertTrue(
            copiedServices.debuggerRuntimeAuthorities.sessionLeaseRegistry
                === services.debuggerRuntimeAuthorities.sessionLeaseRegistry
        )

        validation.release()
        let completed = await waitUntil { results.factories.count == 2 }
        XCTAssertTrue(completed)
        XCTAssertEqual(results.factories.compactMap { $0 }.count, 2)
        XCTAssertEqual(validation.callCount, 1)
        XCTAssertFalse(validation.timedOut)
    }

    func testRuntimeServicesRejectedValidationRemainsUnavailableAcrossCopies() async {
        let inference = ReconstructionRuntimeUnusedInferenceCoordinator()
        let validation = ReconstructionStartupValidationProbe(builder: nil)
        defer { validation.release() }
        let services = MacScopeAppRuntimeServices.testing(
            debuggerRuntimeAuthorities: DebuggerRuntimeAuthorities(),
            nativeDecompilerRuntime: .productionShared,
            reconstructionJobSessionFactoryBuilderResolver: validation.resolve
        )
        let copiedServices = services
        let results = ReconstructionStartupFactoryResults()
        let first = Task {
            results.record(await services.reconstructionWorkspaceRuntimeFactory(
                inferenceCoordinator: inference
            ))
        }
        let second = Task {
            results.record(await copiedServices.reconstructionWorkspaceRuntimeFactory(
                inferenceCoordinator: inference
            ))
        }
        defer { first.cancel(); second.cancel() }
        let entered = await waitUntil { validation.callCount > 0 }
        XCTAssertTrue(entered)
        XCTAssertEqual(results.factories.count, 0)

        validation.release()
        let completed = await waitUntil { results.factories.count == 2 }
        XCTAssertTrue(completed)
        XCTAssertTrue(results.factories.allSatisfy { $0 == nil })
        XCTAssertEqual(validation.callCount, 1)
        XCTAssertFalse(validation.ranOnMainThread)
        XCTAssertFalse(validation.timedOut)
    }

    func testRegistryInstallsValidatedFactoryOnceIntoExistingWindowsWithoutReplacingAuthorities()
        async throws {
        let nativeSessions = ReconstructionStartupNativeSessionProbe()
        let registry = WorkspaceSessionRegistry(nativeDecompilerSessions: nativeSessions)
        var readinessPublications = 0
        let observation = registry.objectWillChange.sink { _ in readinessPublications += 1 }
        defer { observation.cancel() }
        let probe = ReconstructionWorkspaceRuntimeFactoryProbe()
        let gate = ReconstructionStartupAsyncGate()
        let firstID = WorkspaceWindowID.fresh()
        let secondID = WorkspaceWindowID.fresh()
        let configuration = WorkspaceLaunchConfiguration()
        let firstStore = registry.store(for: firstID, launchConfiguration: configuration)
        let secondStore = registry.store(for: secondID, launchConfiguration: configuration)
        let firstSession = registry.documentSession(for: firstID, launchConfiguration: configuration)
        let secondSession = registry.documentSession(for: secondID, launchConfiguration: configuration)
        let firstNativePresentation = registry.nativeDecompilerPresentation(for: firstID)
        let secondNativePresentation = registry.nativeDecompilerPresentation(for: secondID)
        let firstNativeSession = try XCTUnwrap(nativeSessions.handlers[firstID])
        let secondNativeSession = try XCTUnwrap(nativeSessions.handlers[secondID])
        var resolverCalls = 0
        var duplicateCalls = 0
        registry.installReconstructionRuntimeFactoryIfNeeded {
            resolverCalls += 1
            await gate.wait()
            return probe.factory()
        }
        let entered = await waitUntil { await gate.waiterCount == 1 }
        XCTAssertTrue(entered)
        XCTAssertFalse(registry.isReconstructionRuntimeFactoryInstalled)
        XCTAssertEqual(readinessPublications, 0)
        XCTAssertNil(registry.reconstructionRuntime(for: firstID, launchConfiguration: configuration))
        XCTAssertNil(registry.reconstructionRuntime(for: secondID, launchConfiguration: configuration))
        XCTAssertEqual(probe.runtimeCreationCount, 0)
        registry.installReconstructionRuntimeFactoryIfNeeded {
            duplicateCalls += 1
            return probe.factory()
        }

        await gate.release()
        let installed = await waitUntil { registry.isReconstructionRuntimeFactoryInstalled }
        XCTAssertTrue(installed)
        XCTAssertEqual(readinessPublications, 1, "existing windows must observe accepted readiness")
        let firstRuntime = try XCTUnwrap(registry.reconstructionRuntime(
            for: firstID, launchConfiguration: configuration
        ))
        let secondRuntime = try XCTUnwrap(registry.reconstructionRuntime(
            for: secondID, launchConfiguration: configuration
        ))
        XCTAssertTrue(registry.storeIfPresent(for: firstID) === firstStore)
        XCTAssertTrue(registry.storeIfPresent(for: secondID) === secondStore)
        XCTAssertTrue(registry.documentSessionIfPresent(for: firstID) === firstSession)
        XCTAssertTrue(registry.documentSessionIfPresent(for: secondID) === secondSession)
        XCTAssertTrue(registry.nativeDecompilerPresentation(for: firstID) === firstNativePresentation)
        XCTAssertTrue(registry.nativeDecompilerPresentation(for: secondID) === secondNativePresentation)
        XCTAssertTrue(nativeSessions.handlers[firstID] === firstNativeSession)
        XCTAssertTrue(nativeSessions.handlers[secondID] === secondNativeSession)
        XCTAssertEqual(nativeSessions.creationCount, 2, "readiness cannot mint replacement native owners")
        XCTAssertTrue(firstRuntime.isCurrent(for: firstStore, documentSession: firstSession))
        XCTAssertTrue(secondRuntime.isCurrent(for: secondStore, documentSession: secondSession))
        XCTAssertFalse(firstRuntime === secondRuntime)
        XCTAssertEqual(probe.runtimeCreationCount, 2)
        XCTAssertEqual(probe.databaseOpenCount, 0, "installing composition must not open sidecars")
        XCTAssertEqual(probe.jobSessionCreationCount, 0)
        XCTAssertNil(firstRuntime.commandActions.createJob, "untitled windows remain fail-closed")
        XCTAssertNil(secondRuntime.commandActions.startJob)

        registry.installReconstructionRuntimeFactoryIfNeeded {
            duplicateCalls += 1
            return probe.factory()
        }
        await Task.yield()
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertEqual(duplicateCalls, 0)
        XCTAssertTrue(registry.reconstructionRuntimeIfPresent(for: firstID) === firstRuntime)
        XCTAssertEqual(probe.runtimeCreationCount, 2)
        let shutDown = await registry.shutdown()
        XCTAssertTrue(shutDown)
        XCTAssertEqual(readinessPublications, 1, "termination must not request a fresh window render")
    }

    func testRegistryRejectedValidationKeepsRuntimeAndCommandsUnavailableWithoutRetrying() async {
        let registry = WorkspaceSessionRegistry()
        var readinessPublications = 0
        let observation = registry.objectWillChange.sink { _ in readinessPublications += 1 }
        defer { observation.cancel() }
        let windowID = WorkspaceWindowID.fresh()
        let configuration = WorkspaceLaunchConfiguration()
        let store = registry.store(for: windowID, launchConfiguration: configuration)
        let gate = ReconstructionStartupAsyncGate()
        var resolverCalls = 0
        var returned = false
        registry.installReconstructionRuntimeFactoryIfNeeded {
            resolverCalls += 1
            await gate.wait()
            returned = true
            return nil
        }
        let entered = await waitUntil { await gate.waiterCount == 1 }
        XCTAssertTrue(entered)
        XCTAssertNil(registry.reconstructionRuntime(for: windowID, launchConfiguration: configuration))
        await gate.release()
        let rejected = await waitUntil { returned }
        XCTAssertTrue(rejected)
        registry.installReconstructionRuntimeFactoryIfNeeded {
            resolverCalls += 1
            return ReconstructionWorkspaceRuntimeFactoryProbe().factory()
        }
        await Task.yield()
        XCTAssertFalse(registry.isReconstructionRuntimeFactoryInstalled)
        XCTAssertNil(registry.reconstructionRuntimeIfPresent(for: windowID))
        XCTAssertNil(registry.reconstructionRuntime(for: windowID, launchConfiguration: configuration))
        XCTAssertTrue(registry.storeIfPresent(for: windowID) === store)
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertEqual(readinessPublications, 0)
        let shutDown = await registry.shutdown()
        XCTAssertTrue(shutDown)
    }

    func testRegistryRejectsLateValidatedFactoryAfterSuccessfulShutdown() async {
        let registry = WorkspaceSessionRegistry()
        var readinessPublications = 0
        let observation = registry.objectWillChange.sink { _ in readinessPublications += 1 }
        defer { observation.cancel() }
        let probe = ReconstructionWorkspaceRuntimeFactoryProbe()
        let gate = ReconstructionStartupAsyncGate()
        let windowID = WorkspaceWindowID.fresh()
        let configuration = WorkspaceLaunchConfiguration()
        _ = registry.store(for: windowID, launchConfiguration: configuration)
        var returned = false
        var duplicateCalls = 0
        registry.installReconstructionRuntimeFactoryIfNeeded {
            // This gate deliberately ignores cancellation: a slow synchronous Security call can
            // return successfully after its waiter was cancelled by application termination.
            await gate.wait()
            returned = true
            return probe.factory()
        }
        let entered = await waitUntil { await gate.waiterCount == 1 }
        XCTAssertTrue(entered)
        let shutDown = await registry.shutdown()
        XCTAssertTrue(shutDown)
        XCTAssertEqual(registry.count, 0)

        await gate.release()
        let completedLate = await waitUntil { returned }
        XCTAssertTrue(completedLate)
        registry.installReconstructionRuntimeFactoryIfNeeded {
            duplicateCalls += 1
            return probe.factory()
        }
        await Task.yield()
        XCTAssertFalse(registry.isReconstructionRuntimeFactoryInstalled)
        XCTAssertNil(registry.reconstructionRuntime(for: windowID, launchConfiguration: configuration))
        XCTAssertEqual(registry.count, 0, "late validation cannot resurrect a terminated window")
        XCTAssertEqual(probe.runtimeCreationCount, 0)
        XCTAssertEqual(duplicateCalls, 0)
        XCTAssertEqual(readinessPublications, 0)
    }

    func testRegistryRefusedShutdownDoesNotDiscardPendingValidatedFactory() async throws {
        let registry = WorkspaceSessionRegistry()
        let probe = ReconstructionWorkspaceRuntimeFactoryProbe()
        let gate = ReconstructionStartupAsyncGate()
        let windowID = WorkspaceWindowID.fresh()
        let configuration = WorkspaceLaunchConfiguration()
        let store = registry.store(for: windowID, launchConfiguration: configuration)
        let documentSession = registry.documentSession(
            for: windowID, launchConfiguration: configuration
        )
        store.setCustomName(0x1_0000_0000, name: "dirty untitled startup fixture")
        registry.installReconstructionRuntimeFactoryIfNeeded {
            await gate.wait()
            return probe.factory()
        }
        let entered = await waitUntil { await gate.waiterCount == 1 }
        XCTAssertTrue(entered)
        let shutDown = await registry.shutdown()
        XCTAssertFalse(shutDown, "dirty untitled document must refuse termination")
        XCTAssertTrue(registry.storeIfPresent(for: windowID) === store)
        XCTAssertTrue(registry.documentSessionIfPresent(for: windowID) === documentSession)

        await gate.release()
        let installed = await waitUntil { registry.isReconstructionRuntimeFactoryInstalled }
        XCTAssertTrue(installed)
        let runtime = try XCTUnwrap(registry.reconstructionRuntime(
            for: windowID, launchConfiguration: configuration
        ))
        XCTAssertTrue(runtime.isCurrent(for: store, documentSession: documentSession))
        XCTAssertEqual(probe.runtimeCreationCount, 1)
        registry.evict(windowID)
        let cleanedUp = await registry.shutdown()
        XCTAssertTrue(cleanedUp)
    }

    func testValidatedFactoryArrivalInvalidatesReversibleTerminationPreparation()
        async throws {
        let drain = ReconstructionStartupAsyncGate()
        let validation = ReconstructionStartupAsyncGate()
        let registry = WorkspaceSessionRegistry(
            terminationPreparationDeadline: nil,
            terminationAuthorityDrain: { _ in await drain.wait() }
        )
        let probe = ReconstructionWorkspaceRuntimeFactoryProbe()
        let windowID = WorkspaceWindowID.fresh()
        let configuration = WorkspaceLaunchConfiguration()
        let store = registry.store(for: windowID, launchConfiguration: configuration)
        let session = registry.documentSession(
            for: windowID, launchConfiguration: configuration
        )
        registry.installReconstructionRuntimeFactoryIfNeeded {
            await validation.wait()
            return probe.factory()
        }
        let validationStarted = await waitUntil { await validation.waiterCount == 1 }
        XCTAssertTrue(validationStarted)

        var shutdownResult: Bool?
        let shutdown = Task {
            let result = await registry.shutdown()
            shutdownResult = result
            return result
        }
        defer { shutdown.cancel() }
        let drainStarted = await waitUntil { await drain.waiterCount == 1 }
        XCTAssertTrue(drainStarted)
        XCTAssertTrue(session.isTerminationPreparationActive)

        await validation.release()
        let installed = await waitUntil { registry.isReconstructionRuntimeFactoryInstalled }
        XCTAssertTrue(installed)
        // Installing new runtime authority must cancel the captured preparation, even when
        // its await-only drain ignores cancellation and no view has resolved a runtime yet.
        let preparationInvalidated = await waitUntil { shutdownResult != nil }
        XCTAssertTrue(preparationInvalidated)
        if !preparationInvalidated { shutdown.cancel() }
        let didShutdown = await shutdown.value
        XCTAssertFalse(didShutdown)
        XCTAssertFalse(session.isTerminationPreparationActive)
        XCTAssertTrue(registry.storeIfPresent(for: windowID) === store)
        XCTAssertTrue(registry.documentSessionIfPresent(for: windowID) === session)
        XCTAssertEqual(probe.runtimeCreationCount, 0)

        let runtime = try XCTUnwrap(registry.reconstructionRuntime(
            for: windowID, launchConfiguration: configuration
        ))
        XCTAssertTrue(runtime.isCurrent(for: store, documentSession: session))
        await drain.release()
        let retryShutdown = await registry.shutdown()
        XCTAssertTrue(retryShutdown)
        XCTAssertEqual(registry.count, 0)
        XCTAssertFalse(registry.isReconstructionRuntimeFactoryInstalled)
        XCTAssertNil(registry.reconstructionRuntime(
            for: windowID, launchConfiguration: configuration
        ))
    }

    private func sameIdentityWorkspace(
        for store: WorkspaceStore
    ) -> WorkspaceDatabase.PersistedWorkspace {
        WorkspaceDatabase.PersistedWorkspace(
            workspace: .init(
                id: 1,
                uuid: store.workspaceID,
                name: store.workspaceName,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            ),
            snapshot: store.snapshot,
            session: .init(
                workspaceID: 1,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                updatedAt: Date(timeIntervalSince1970: 2),
                focusedImageSlot: .primary
            ),
            reconstructionState: store.reconstructionState
        )
    }

    private func physicalTwoJobState(
        from base: ReconstructionWorkspaceState
    ) throws -> ReconstructionWorkspaceState {
        let project = try XCTUnwrap(base.projects.first)
        let manifest = try XCTUnwrap(base.corpusManifests.first)
        let frontier = try ReconstructionEvidenceFrontier.canonicalSHA256(
            corpusManifestSHA256: manifest.canonicalSHA256,
            records: [],
            projectedClassificationsByEvidenceID: [:],
            relations: [],
            gaps: [],
            checkpointRevisionsByID: [:]
        )
        let gapFrontier = try ReconstructionEvidenceGapFrontier.canonicalSHA256(for: [])
        let jobs: [(jobID: UUID, taskID: UUID, checkpointID: UUID, ordinal: UInt64)] = [
            (
                UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffff01")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000121")!,
                1
            ),
            (
                UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
                UUID(uuidString: "00000000-0000-0000-0000-000000000122")!,
                2
            ),
        ]
        var jobRecords: [ReconstructionJobRecord] = []
        var tasks: [ReconstructionTaskRecord] = []
        var checkpoints: [ReconstructionCheckpoint] = []
        for coordinates in jobs {
            let task = ReconstructionTaskRecord(
                identity: try ReconstructionTaskIdentity.make(
                    taskID: coordinates.taskID,
                    jobID: coordinates.jobID,
                    kind: .retrieveEvidence,
                    subject: nil,
                    dependencyTaskIDs: [],
                    operationContractIdentity: ReconstructionOperationID.evidenceQuery.rawValue
                ),
                state: .pending,
                diagnostic: nil
            )
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: coordinates.checkpointID,
                jobID: coordinates.jobID,
                revision: 0,
                parentCheckpointID: nil,
                parentCheckpointSHA256: nil,
                corpusManifestSHA256: manifest.canonicalSHA256,
                evidenceFrontierSHA256: frontier,
                pendingTaskIDs: [coordinates.taskID],
                runningTaskIDs: [],
                completedTaskIDs: [],
                failedTaskIDs: [],
                blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: gapFrontier,
                modelReceiptIDs: [],
                toolReceiptIDs: [],
                coordinatorState: .created,
                terminalReason: nil
            )
            let objective = "Ordinal reconstruction job \(coordinates.ordinal)"
            let job = try ReconstructionJobRecord(
                jobID: coordinates.jobID,
                reconstructionProjectID: project.projectID,
                objective: objective,
                objectiveSHA256: ReconstructionPackageFixture.digest(Data(objective.utf8)),
                creationCorpusManifestSHA256: manifest.canonicalSHA256,
                state: .created,
                currentCheckpointID: checkpoint.checkpointID,
                terminalReason: nil,
                budget: try ReconstructionJobBudget(
                    maxRounds: 4,
                    maxTasks: 16,
                    maxEvidenceRecords: 32,
                    maxEncodedBytes: 1_048_576
                ),
                creationOrdinal: coordinates.ordinal
            )
            jobRecords.append(job)
            tasks.append(task)
            checkpoints.append(checkpoint)
        }
        return try ReconstructionWorkspaceState(
            projects: base.projects,
            corpusManifests: base.corpusManifests,
            evidence: [],
            evidenceRelations: [],
            evidenceGaps: [],
            jobs: jobRecords,
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: [],
            modelReceipts: [],
            finalResults: []
        )
    }

    private func openedDocumentSession(
        windowID: WorkspaceWindowID,
        store: WorkspaceStore,
        reservations: ReconstructionRuntimeTestReservations
    ) throws -> WorkspaceDocumentSession {
        let session = WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: windowID,
            source: store,
            io: WorkspaceDocumentIO(),
            reservations: reservations
        )
        let location = WorkspaceDocumentLocation(
            canonicalURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ReconstructionRuntime-\(UUID().uuidString).mscope"),
            fileObjectIdentity: nil
        )
        let digest = String(repeating: "a", count: 64)
        let observation = WorkspacePackageExternalVersion(
            location: location,
            condition: .valid,
            observationSHA256: digest,
            manifestSHA256: digest,
            validatedContentSHA256: digest,
            boundedReason: nil
        )
        try session.bindOpenedPackage(
            WorkspaceDocumentValidatedPackage(
                manifestData: Data("runtime-composition-test".utf8),
                attachmentsByBinaryID: [:],
                observation: observation
            ),
            at: location
        )
        return session
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(10),
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else { return false }
            do {
                try await clock.sleep(for: pollInterval)
            } catch {
                return await condition()
            }
        }
        return true
    }

    private func commandAuthority(jobID: UUID) -> ReconstructionJobCommandAuthority {
        ReconstructionJobCommandAuthority(
            jobID: jobID,
            expectedJobState: .created,
            checkpointID: UUID(),
            checkpointRevision: 0,
            corpusManifestSHA256: String(repeating: "a", count: 64),
            evidenceFrontierSHA256: String(repeating: "b", count: 64)
        )
    }

    private func commandAuthority(
        job: ReconstructionJobRecord,
        checkpoint: ReconstructionCheckpoint
    ) -> ReconstructionJobCommandAuthority {
        ReconstructionJobCommandAuthority(
            jobID: job.jobID,
            expectedJobState: job.state,
            checkpointID: checkpoint.checkpointID,
            checkpointRevision: checkpoint.revision,
            corpusManifestSHA256: checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256
        )
    }

    private func makeDurableScenario(
        paused: Bool,
        activate: Bool = true,
        sessionFactoryFailures: Int = 0
    ) async throws
        -> ReconstructionRuntimeDurableScenario {
        let baseDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionWorkspaceRuntime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: baseDirectoryURL,
            withIntermediateDirectories: false
        )
        do {
            let snapshot = AnalysisEngine.previewSnapshot()
            let store = WorkspaceStore(
                workspaceName: "Runtime authority fixture",
                snapshot: snapshot,
                engine: AnalysisEngine(),
                autosaveScheduler: nil
            )
            let binaryID = try XCTUnwrap(snapshot.binaries.first?.id)
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: binaryID
            )
            let durableState: ReconstructionWorkspaceState
            let durableJob: ReconstructionJobRecord
            let durableCheckpoint: ReconstructionCheckpoint
            if paused {
                let paused = try pausedState(from: foundation)
                durableState = paused.state
                durableJob = paused.job
                durableCheckpoint = paused.checkpoint
            } else {
                durableState = foundation.state
                durableJob = foundation.job
                durableCheckpoint = foundation.checkpoint
            }
            let sourceURL = baseDirectoryURL.appendingPathComponent("fixture.bin")
            try Data("test".utf8).write(to: sourceURL)
            let attachmentSources = [
                ReconstructionAttachmentSource(
                    contentIdentity: foundation.occurrence.contentIdentity,
                    verifiedURL: sourceURL
                ),
            ]
            store.restoreWorkspace(
                persistedWorkspace(
                    store: store,
                    snapshot: snapshot,
                    reconstructionState: durableState
                ),
                reconstructionAttachmentSources: attachmentSources
            )
            let windowID = WorkspaceWindowID.fresh()
            let reservations = ReconstructionRuntimeTestReservations()
            let documentSession = try openedDocumentSession(
                windowID: windowID,
                store: store,
                reservations: reservations
            )
            let sessionProbe = ReconstructionRuntimeSessionFactoryProbe(
                remainingFailures: sessionFactoryFailures
            )
            let databaseOpenProbe = ReconstructionActivationDatabaseOpenProbe(
                baseDirectoryURL: baseDirectoryURL,
                remainingFailures: 0
            )
            let runtime = ReconstructionWorkspaceRuntime(
                windowID: windowID,
                store: store,
                documentSession: documentSession,
                openDatabaseRuntime: { binding, state, sources, workspaceName in
                    try await databaseOpenProbe.open(
                        binding: binding,
                        state: state,
                        sources: sources,
                        workspaceName: workspaceName,
                    )
                },
                makeJobSession: sessionProbe.factory()
            )
            if activate {
                let activated = await runtime.activateReconstructionDestination()
                XCTAssertTrue(activated)
                XCTAssertEqual(runtime.activationModel.snapshot.phase, .ready)
            }
            return ReconstructionRuntimeDurableScenario(
                baseDirectoryURL: baseDirectoryURL,
                runtime: runtime,
                store: store,
                documentSession: documentSession,
                reservations: reservations,
                sessionProbe: sessionProbe,
                databaseOpenProbe: databaseOpenProbe,
                job: durableJob,
                checkpoint: durableCheckpoint
            )
        } catch {
            try? FileManager.default.removeItem(at: baseDirectoryURL)
            throw error
        }
    }

    private func makeTwoJobDurableScenario(
        failingJobIDs: Set<UUID>
    ) async throws -> ReconstructionRuntimeTwoJobDurableScenario {
        let baseDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacScope-ReconstructionWorkspaceRuntime-TwoJob-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: baseDirectoryURL,
            withIntermediateDirectories: false
        )
        do {
            let snapshot = AnalysisEngine.previewSnapshot()
            let store = WorkspaceStore(
                workspaceName: "Runtime multi-job restoration fixture",
                snapshot: snapshot,
                engine: AnalysisEngine(),
                autosaveScheduler: nil
            )
            let binaryID = try XCTUnwrap(snapshot.binaries.first?.id)
            let foundation = try ReconstructionDatabaseTestFixtures.makeFoundationState(
                workspaceBinaryID: binaryID
            )
            let durableState = try physicalTwoJobState(from: foundation.state)
            let sourceURL = baseDirectoryURL.appendingPathComponent("fixture.bin")
            try Data("test".utf8).write(to: sourceURL)
            store.restoreWorkspace(
                persistedWorkspace(
                    store: store,
                    snapshot: snapshot,
                    reconstructionState: durableState
                ),
                reconstructionAttachmentSources: [
                    ReconstructionAttachmentSource(
                        contentIdentity: foundation.occurrence.contentIdentity,
                        verifiedURL: sourceURL
                    ),
                ]
            )
            let windowID = WorkspaceWindowID.fresh()
            let reservations = ReconstructionRuntimeTestReservations()
            let documentSession = try openedDocumentSession(
                windowID: windowID,
                store: store,
                reservations: reservations
            )
            let sessionProbe = ReconstructionRuntimeSessionFactoryProbe(
                failingJobIDs: failingJobIDs
            )
            let databaseOpenProbe = ReconstructionActivationDatabaseOpenProbe(
                baseDirectoryURL: baseDirectoryURL,
                remainingFailures: 0
            )
            let runtime = ReconstructionWorkspaceRuntime(
                windowID: windowID,
                store: store,
                documentSession: documentSession,
                openDatabaseRuntime: { binding, state, sources, workspaceName in
                    try await databaseOpenProbe.open(
                        binding: binding,
                        state: state,
                        sources: sources,
                        workspaceName: workspaceName
                    )
                },
                makeJobSession: sessionProbe.factory()
            )
            return ReconstructionRuntimeTwoJobDurableScenario(
                baseDirectoryURL: baseDirectoryURL,
                runtime: runtime,
                store: store,
                documentSession: documentSession,
                sessionProbe: sessionProbe,
                jobs: durableState.jobs
            )
        } catch {
            try? FileManager.default.removeItem(at: baseDirectoryURL)
            throw error
        }
    }

    private func persistedWorkspace(
        store: WorkspaceStore,
        snapshot: WorkspaceSnapshot,
        reconstructionState: ReconstructionWorkspaceState
    ) -> WorkspaceDatabase.PersistedWorkspace {
        WorkspaceDatabase.PersistedWorkspace(
            workspace: .init(
                id: 1,
                uuid: store.workspaceID,
                name: store.workspaceName,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            ),
            snapshot: snapshot,
            session: .init(
                workspaceID: 1,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                updatedAt: Date(timeIntervalSince1970: 2),
                focusedImageSlot: .primary
            ),
            reconstructionState: reconstructionState
        )
    }

    private func pausedState(
        from foundation: ReconstructionDatabaseTestFixtures.StateFixture
    ) throws -> (
        state: ReconstructionWorkspaceState,
        job: ReconstructionJobRecord,
        checkpoint: ReconstructionCheckpoint
    ) {
        let context = try ReconstructionJobPauseContext(
            cause: .pausedByUser,
            resumeTarget: foundation.job.state
        )
        let checkpoint = try ReconstructionCheckpoint.make(
            checkpointID: ReconstructionDatabaseTestFixtures.checkpointOneUUID,
            schemaVersion: foundation.checkpoint.schemaVersion,
            jobID: foundation.checkpoint.jobID,
            revision: foundation.checkpoint.revision + 1,
            parentCheckpointID: foundation.checkpoint.checkpointID,
            parentCheckpointSHA256: foundation.checkpoint.canonicalSHA256,
            corpusManifestSHA256: foundation.checkpoint.corpusManifestSHA256,
            evidenceFrontierSHA256: foundation.checkpoint.evidenceFrontierSHA256,
            pendingTaskIDs: foundation.checkpoint.pendingTaskIDs,
            runningTaskIDs: foundation.checkpoint.runningTaskIDs,
            completedTaskIDs: foundation.checkpoint.completedTaskIDs,
            failedTaskIDs: foundation.checkpoint.failedTaskIDs,
            blockedTaskIDs: foundation.checkpoint.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: foundation.checkpoint.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: foundation.checkpoint.modelReceiptIDs,
            toolReceiptIDs: foundation.checkpoint.toolReceiptIDs,
            coordinatorState: .paused,
            terminalReason: nil
        )
        let job = try ReconstructionJobRecord(
            jobID: foundation.job.jobID,
            reconstructionProjectID: foundation.job.reconstructionProjectID,
            objective: foundation.job.objective,
            objectiveSHA256: foundation.job.objectiveSHA256,
            creationCorpusManifestSHA256: foundation.job.creationCorpusManifestSHA256,
            state: .paused,
            currentCheckpointID: checkpoint.checkpointID,
            terminalReason: nil,
            budget: foundation.job.budget,
            creationOrdinal: try XCTUnwrap(foundation.job.creationOrdinal),
            pauseContext: context
        )
        let state = try ReconstructionWorkspaceState(
            projects: foundation.state.projects,
            corpusManifests: foundation.state.corpusManifests,
            evidence: foundation.state.evidence,
            evidenceRelations: foundation.state.evidenceRelations,
            evidenceGaps: foundation.state.evidenceGaps,
            jobs: [job],
            tasks: foundation.state.tasks,
            checkpoints: [foundation.checkpoint, checkpoint],
            toolReceipts: foundation.state.toolReceipts,
            modelReceipts: foundation.state.modelReceipts
        )
        try ReconstructionPackageCodec.validateGraph(state)
        // Mutation RED: rewrite revision zero in place or omit its parent from this paused
        // history. The fixture's package-v3 validation then reports exactly
        // `stateGraphInvalid("job pause context history")` before sidecar/session admission.
        return (state, job, checkpoint)
    }
}

@MainActor
private struct ReconstructionRuntimeDurableScenario {
    let baseDirectoryURL: URL
    let runtime: ReconstructionWorkspaceRuntime
    let store: WorkspaceStore
    let documentSession: WorkspaceDocumentSession
    let reservations: ReconstructionRuntimeTestReservations
    let sessionProbe: ReconstructionRuntimeSessionFactoryProbe
    let databaseOpenProbe: ReconstructionActivationDatabaseOpenProbe
    let job: ReconstructionJobRecord
    let checkpoint: ReconstructionCheckpoint

    func close() async {
        await runtime.retireTransiently()
        documentSession.close()
        try? FileManager.default.removeItem(at: baseDirectoryURL)
    }
}

@MainActor
private struct ReconstructionRuntimeTwoJobDurableScenario {
    let baseDirectoryURL: URL
    let runtime: ReconstructionWorkspaceRuntime
    let store: WorkspaceStore
    let documentSession: WorkspaceDocumentSession
    let sessionProbe: ReconstructionRuntimeSessionFactoryProbe
    let jobs: [ReconstructionJobRecord]

    func close() async {
        await runtime.retireTransiently()
        documentSession.close()
        try? FileManager.default.removeItem(at: baseDirectoryURL)
    }
}

@MainActor
private final class ReconstructionRuntimeSessionFactoryProbe {
    let coordinator = ReconstructionRuntimeCoordinatorProbe()
    let scheduler = ReconstructionRuntimeSchedulerProbe()
    private(set) var creationCount = 0
    private(set) var admissionObservedPublishedProjection: [Bool] = []
    private var remainingFailures: Int
    private var failingJobIDs: Set<UUID>
    private let admissionObservation: ((UUID, WorkspaceStore) -> Bool)?
    private var creationsReleased = true
    private var creationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        remainingFailures: Int = 0,
        failingJobIDs: Set<UUID> = [],
        admissionObservation: ((UUID, WorkspaceStore) -> Bool)? = nil
    ) {
        self.remainingFailures = remainingFailures
        self.failingJobIDs = failingJobIDs
        self.admissionObservation = admissionObservation
    }

    func factory() -> ReconstructionJobSessionFactory {
        { [self] _, jobID, _, store in
            creationCount += 1
            if let admissionObservation {
                admissionObservedPublishedProjection.append(
                    admissionObservation(jobID, store)
                )
            }
            if !creationsReleased {
                await withCheckedContinuation { creationWaiters.append($0) }
            }
            if remainingFailures > 0 {
                remainingFailures -= 1
                throw ReconstructionRuntimeCompositionTestError.unexpectedJobSession
            }
            if failingJobIDs.remove(jobID) != nil {
                throw ReconstructionRuntimeCompositionTestError.unexpectedJobSession
            }
            return ReconstructionJobSession(
                durableJobID: jobID,
                coordinator: coordinator,
                scheduler: scheduler
            )
        }
    }

    func holdCreations() {
        creationsReleased = false
    }

    func releaseCreations() {
        creationsReleased = true
        creationWaiters.forEach { $0.resume() }
        creationWaiters.removeAll()
    }
}

@MainActor
private final class ReconstructionRuntimeActivationProbe {
    private(set) var result: Bool?

    func complete(_ result: Bool) {
        self.result = result
    }
}

private actor ReconstructionRuntimeCoordinatorProbe:
    ReconstructionJobSessionCoordinating
{
    private var started: [UUID] = []
    private var completedStarts: [UUID] = []
    private var cancelled: [UUID] = []
    private var paused: [UUID] = []
    private var resumed: [UUID] = []
    private var startsReleased = true
    private var pausesReleased = true
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var startReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func start(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool {
        started.append(jobID)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if !startsReleased {
            await withCheckedContinuation { startReleaseWaiters.append($0) }
        }
        completedStarts.append(jobID)
        return true
    }
    func pause(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool {
        paused.append(jobID)
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        guard !pausesReleased else { return true }
        await withCheckedContinuation { pauseReleaseWaiters.append($0) }
        return true
    }

    func resume(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool {
        resumed.append(jobID)
        resumeWaiters.forEach { $0.resume() }
        resumeWaiters.removeAll()
        return true
    }

    func cancel(jobID: UUID, authority: ReconstructionJobCommandAuthority) async -> Bool {
        cancelled.append(jobID)
        return true
    }

    func suspendWithoutDurableDisposition(jobID: UUID) async {}

    func cancelledJobIDs() -> [UUID] { cancelled }
    func startedJobIDs() -> [UUID] { started }
    func completedStartJobIDs() -> [UUID] { completedStarts }
    func resumedJobIDs() -> [UUID] { resumed }

    func holdStarts() {
        startsReleased = false
    }

    func holdPauses() {
        pausesReleased = false
    }

    func releaseStarts() {
        startsReleased = true
        startReleaseWaiters.forEach { $0.resume() }
        startReleaseWaiters.removeAll()
    }

    func releasePauses() {
        pausesReleased = true
        pauseReleaseWaiters.forEach { $0.resume() }
        pauseReleaseWaiters.removeAll()
    }

    func waitUntilStarted() async {
        if !started.isEmpty { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilResumed() async {
        if !resumed.isEmpty { return }
        await withCheckedContinuation { resumeWaiters.append($0) }
    }


    func waitUntilPaused() async {
        if !paused.isEmpty { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }
}

private actor ReconstructionRuntimeSchedulerProbe: ReconstructionJobSessionScheduling {
    private var resumed: [UUID] = []
    private var retired: [UUID] = []

    func pause(jobID: UUID) async {}
    func resume(jobID: UUID) async { resumed.append(jobID) }
    func retire(jobID: UUID) async { retired.append(jobID) }

    func resumedJobIDs() -> [UUID] { resumed }
    func retiredJobIDs() -> [UUID] { retired }
}

private actor ReconstructionActivationDatabaseOpenProbe {
    private let baseDirectoryURL: URL
    private var remainingFailures: Int
    private var attempts = 0
    private weak var latestRuntime: ReconstructionWorkspaceDatabaseRuntime?
    private var latestOpenError: Error?

    init(baseDirectoryURL: URL, remainingFailures: Int) {
        self.baseDirectoryURL = baseDirectoryURL
        self.remainingFailures = remainingFailures
    }

    func open(
        binding: ReconstructionWorkspaceStateBinding,
        state: ReconstructionWorkspaceState,
        sources: [ReconstructionAttachmentSource],
        workspaceName: String
    ) throws -> ReconstructionWorkspaceDatabaseRuntime {
        attempts += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw ReconstructionRuntimeCompositionTestError.unexpectedDatabaseOpen
        }
        do {
            let runtime = try ReconstructionWorkspaceDatabaseRuntime.open(
                binding: binding,
                packageState: state,
                packageAttachmentSources: sources,
                workspaceName: workspaceName,
                baseDirectoryURL: baseDirectoryURL
            )
            latestRuntime = runtime
            latestOpenError = nil
            return runtime
        } catch {
            latestOpenError = error
            throw error
        }
    }

    func attemptCount() -> Int { attempts }

    func openedRuntime() -> ReconstructionWorkspaceDatabaseRuntime? { latestRuntime }

    func restorationDiagnostic(workspaceID: UUID, jobID: UUID) async -> String {
        if let latestOpenError {
            return "database open failed with \(String(reflecting: latestOpenError))"
        }
        guard let latestRuntime else {
            return "database factory was never reached"
        }
        do {
            let owner = try latestRuntime.databaseOwner()
            let rows = try await owner.captureProductionRoundRows(
                workspaceID: workspaceID,
                jobID: jobID
            )
            _ = try ReconstructionProductionRoundBasis(rows: rows)
            return "database open and production-round basis both succeeded"
        } catch {
            return "production-round basis failed with \(String(reflecting: error))"
        }
    }
}

private enum ReconstructionRuntimeCompositionTestError: Error {
    case unexpectedDatabaseOpen
    case unexpectedJobSession
}

/// The injected verifier models synchronous Security work without ever making the test's main
/// actor wait on a semaphore. A broken inline implementation times out and fails, rather than
/// hanging the suite; all accesses shared with the detached validator are protected by the lock.
private final class ReconstructionStartupValidationProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private let builder: ReconstructionJobSessionFactoryBuilder?
    private var released = false
    private var recordedCalls = 0
    private var recordedMainThread = false
    private var recordedTimeout = false

    init(builder: ReconstructionJobSessionFactoryBuilder?) {
        self.builder = builder
    }

    var callCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return recordedCalls
    }

    var ranOnMainThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return recordedMainThread
    }

    var timedOut: Bool {
        condition.lock()
        defer { condition.unlock() }
        return recordedTimeout
    }

    func resolve() -> ReconstructionJobSessionFactoryBuilder? {
        condition.lock()
        defer { condition.unlock() }
        recordedCalls += 1
        recordedMainThread = recordedMainThread || Thread.isMainThread
        let deadline = Date(timeIntervalSinceNow: 5)
        while !released {
            guard condition.wait(until: deadline) else {
                recordedTimeout = true
                return nil
            }
        }
        return builder
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
private final class ReconstructionStartupFactoryResults {
    private(set) var factories: [ReconstructionWorkspaceRuntimeFactory?] = []

    func record(_ factory: ReconstructionWorkspaceRuntimeFactory?) {
        factories.append(factory)
    }
}

private actor ReconstructionStartupAsyncGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiterCount = 0
    private(set) var observedCancellation = false

    func wait() async {
        waiterCount += 1
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
        observedCancellation = observedCancellation || Task.isCancelled
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class ReconstructionStartupNativeSessionProbe: NativeDecompilerSessionProviding {
    private(set) var creationCount = 0
    private(set) var handlers: [WorkspaceWindowID: ReconstructionStartupNativeHandler] = [:]

    func makeWorkspaceSession(
        windowID: WorkspaceWindowID,
        presentation: NativeDecompilerPresentationModel
    ) -> any NativeDecompilerWorkspaceSessionHandling {
        creationCount += 1
        let handler = ReconstructionStartupNativeHandler()
        handlers[windowID] = handler
        return handler
    }
}

@MainActor
private final class ReconstructionStartupNativeHandler: NativeDecompilerWorkspaceSessionHandling {
    func submit(_ submission: NativeDecompilerWorkspaceSubmission) {}
    func retry(_ retry: NativeDecompilerWorkspaceRetry) {}
    func publishAuthoredProjectionFailure(
        _ diagnostic: NativeAuthoredProjectionDiagnostic,
        ticket: NativeDriveSubmissionTicket
    ) {}
    func cancelOutstanding() {}
    func terminateSession() {}
}

@MainActor
private final class ReconstructionWorkspaceRuntimeFactoryProbe {
    private(set) var runtimeCreationCount = 0
    private(set) var databaseOpenCount = 0
    private(set) var jobSessionCreationCount = 0

    func factory() -> ReconstructionWorkspaceRuntimeFactory {
        { [self] windowID, store, documentSession, predecessorRetirement in
            makeRuntime(
                windowID: windowID,
                store: store,
                documentSession: documentSession,
                predecessorRetirement: predecessorRetirement
            )
        }
    }

    func makeRuntime(
        windowID: WorkspaceWindowID,
        store: WorkspaceStore,
        documentSession: WorkspaceDocumentSession,
        predecessorRetirement: Task<Void, Never>?
    ) -> ReconstructionWorkspaceRuntime {
        runtimeCreationCount += 1
        return ReconstructionWorkspaceRuntime(
            windowID: windowID,
            store: store,
            documentSession: documentSession,
            predecessorRetirement: predecessorRetirement,
            openDatabaseRuntime: { [weak self] _, _, _, _ in
                await self?.recordDatabaseOpen()
                throw ReconstructionRuntimeCompositionTestError.unexpectedDatabaseOpen
            },
            makeJobSession: { [weak self] _, _, _, _ in
                self?.jobSessionCreationCount += 1
                throw ReconstructionRuntimeCompositionTestError.unexpectedJobSession
            }
        )
    }

    private func recordDatabaseOpen() {
        databaseOpenCount += 1
    }
}

@MainActor
private final class ReconstructionRuntimeInferenceIdentityProbe {
    var injected: AnyObject?
}

@MainActor
private final class ReconstructionRuntimeUnusedInferenceCoordinator:
    ReconstructionReadyInferenceCoordinating
{
    func run(
        request: ReconstructionInferenceRoundRequest
    ) async -> ReconstructionReadyInferenceExecutionResult {
        fatalError("unused test inference coordinator")
    }

    func synthesize(
        request: ReconstructionFinalSynthesisRequest
    ) async -> ReconstructionReadyFinalSynthesisExecutionResult {
        fatalError("unused test inference coordinator")
    }
}

@MainActor
private final class ReconstructionRuntimeTestReservations:
    WorkspaceDocumentLocationReserving
{
    func owner(of location: WorkspaceDocumentLocation) -> WorkspaceWindowID? { nil }

    func reserve(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentLocationReservationResult {
        .reserved
    }

    func release(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID
    ) {}

    func releaseAll(for sessionID: WorkspaceDocumentSessionID) {}

    func beginPhysicalPublication(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        retainingPublishedOwnership: Bool,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentPublicationReservationResult {
        .reserved(WorkspaceDocumentPublicationReservation())
    }

    func completePhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation,
        at publishedLocation: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentPublicationCompletionResult {
        .completed
    }

    func cancelPhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation
    ) {}
}
