import Combine
import Foundation
import os

enum ReconstructionWorkspaceActivationFailure: String, Equatable, Sendable {
    case runtimeUnavailable
    case documentLocationRequired
    case staleLifecycle
    case sidecarUnavailable
    case restorationUnavailable
}

enum ReconstructionWorkspaceActivationPhase: Equatable, Sendable {
    case inactive
    case activating
    case restoring
    case ready
    case failed(ReconstructionWorkspaceActivationFailure)
}

struct ReconstructionWorkspaceActivationSnapshot: Equatable, Sendable {
    let phase: ReconstructionWorkspaceActivationPhase
    let revision: UInt64
    let presentationAuthority: ReconstructionWorkspacePresentationAuthority

    init(
        phase: ReconstructionWorkspaceActivationPhase,
        revision: UInt64,
        presentationAuthority: ReconstructionWorkspacePresentationAuthority = .empty
    ) {
        self.phase = phase
        self.revision = revision
        self.presentationAuthority = presentationAuthority
    }
}

/// The immutable Store-published checkpoint coordinates that a live window may present. Keeping
/// this cut beside the activation lifecycle gives SwiftUI a second, runtime-owned authority to
/// compare with the durable projection; an in-flight or stale publication therefore disables
/// commands instead of being treated as current by construction.
struct ReconstructionWorkspacePresentationAuthority: Equatable, Sendable {
    struct Job: Equatable, Sendable {
        let evidenceFrontierSHA256: String
        let projectionRevision: UInt64
    }

    static let empty = Self(jobsByID: [:])

    let jobsByID: [UUID: Job]

    init(workspace: ReconstructionWorkspaceState) {
        var checkpointsByID: [UUID: ReconstructionCheckpoint] = [:]
        checkpointsByID.reserveCapacity(workspace.checkpoints.count)
        for checkpoint in workspace.checkpoints {
            checkpointsByID[checkpoint.checkpointID] = checkpoint
        }
        var jobsByID: [UUID: Job] = [:]
        jobsByID.reserveCapacity(workspace.jobs.count)
        for job in workspace.jobs {
            guard let checkpointID = job.currentCheckpointID,
                  let checkpoint = checkpointsByID[checkpointID],
                  checkpoint.jobID == job.jobID else { continue }
            jobsByID[job.jobID] = Job(
                evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
                projectionRevision: checkpoint.revision
            )
        }
        self.init(jobsByID: jobsByID)
    }

    private init(jobsByID: [UUID: Job]) {
        self.jobsByID = jobsByID
    }

    func job(_ jobID: UUID?) -> Job? {
        jobID.flatMap { jobsByID[$0] }
    }
}

/// The sole observable projection of one runtime's transient activation lifecycle. The static
/// sentinel is immutable and fail-closed; a live runtime is the only authority allowed to advance
/// its own model.
@MainActor
final class ReconstructionWorkspaceActivationModel: ObservableObject {
    static let unavailable = ReconstructionWorkspaceActivationModel(
        snapshot: .init(phase: .failed(.runtimeUnavailable), revision: 0),
        acceptsTransitions: false
    )

    @Published private(set) var snapshot: ReconstructionWorkspaceActivationSnapshot
    private let acceptsTransitions: Bool

    init(
        snapshot: ReconstructionWorkspaceActivationSnapshot = .init(
            phase: .inactive,
            revision: 0
        ),
        acceptsTransitions: Bool = true
    ) {
        self.snapshot = snapshot
        self.acceptsTransitions = acceptsTransitions
    }

    fileprivate func publish(_ phase: ReconstructionWorkspaceActivationPhase) {
        guard acceptsTransitions, snapshot.phase != phase else { return }
        let (revision, overflow) = snapshot.revision.addingReportingOverflow(1)
        guard !overflow else {
            snapshot = .init(
                phase: .failed(.staleLifecycle),
                revision: snapshot.revision,
                presentationAuthority: snapshot.presentationAuthority
            )
            return
        }
        snapshot = .init(
            phase: phase,
            revision: revision,
            presentationAuthority: snapshot.presentationAuthority
        )
    }

    fileprivate func publishPresentationAuthority(
        _ authority: ReconstructionWorkspacePresentationAuthority
    ) {
        guard acceptsTransitions, snapshot.presentationAuthority != authority else { return }
        snapshot = .init(
            phase: snapshot.phase,
            revision: snapshot.revision,
            presentationAuthority: authority
        )
    }
}

enum ReconstructionWorkspaceRuntimeError: Error, Equatable {
    case publicationAuthorityUnavailable
    case documentLocationRequired
    case documentCoordinateMismatch
    case staleLifecycle
    case retired
    case runtimeWorkspaceMismatch
    case durableStatePublicationRejected
    case commandAuthorityMismatch
    case sessionActivationRejected
}

/// The only sidecar-opening seam retained by a window runtime. The closure receives an immutable
/// package cut and must return only after the exact workspace/document/path binding has been
/// reconciled and all selected attachment bytes are available in the durable vault.
typealias ReconstructionWorkspaceDatabaseRuntimeFactory = @Sendable (
    _ binding: ReconstructionWorkspaceStateBinding,
    _ packageState: ReconstructionWorkspaceState,
    _ packageAttachmentSources: [ReconstructionAttachmentSource],
    _ workspaceName: String
) async throws -> ReconstructionWorkspaceDatabaseRuntime

/// Builds the one live execution graph for one durable job. The exact Store is supplied only so
/// the coordinator's receipt publisher can bind its opaque publication authority; it must never
/// become a source of round inputs.
typealias ReconstructionJobSessionFactory = @MainActor @Sendable (
    _ workspaceID: UUID,
    _ durableJobID: UUID,
    _ owner: ReconstructionDatabaseOwner,
    _ store: WorkspaceStore
) async throws -> ReconstructionJobSession

/// Registry-owned factory. The predecessor barrier prevents a same-window replacement from
/// activating before every authority retained by the prior Store lifecycle has been released.
typealias ReconstructionWorkspaceRuntimeFactory = @MainActor @Sendable (
    _ windowID: WorkspaceWindowID,
    _ store: WorkspaceStore,
    _ documentSession: WorkspaceDocumentSession,
    _ predecessorRetirement: Task<Void, Never>?
) -> ReconstructionWorkspaceRuntime

@MainActor
private final class ReconstructionWorkspaceJobSessionFactoryContext: Sendable {
    weak var store: WorkspaceStore?
    let workspaceID: UUID
    let owner: ReconstructionDatabaseOwner
    let factory: ReconstructionJobSessionFactory

    init(
        store: WorkspaceStore,
        workspaceID: UUID,
        owner: ReconstructionDatabaseOwner,
        factory: @escaping ReconstructionJobSessionFactory
    ) {
        self.store = store
        self.workspaceID = workspaceID
        self.owner = owner
        self.factory = factory
    }

    func make(durableJobID: UUID) async throws -> ReconstructionJobSession {
        guard let store else {
            throw ReconstructionWorkspaceRuntimeError.staleLifecycle
        }
        return try await factory(workspaceID, durableJobID, owner, store)
    }
}

/// One lightweight Reconstruction owner per document window and Store lifecycle.
///
/// Construction captures no model, XPC, native-decompiler, analysis-provider, or database
/// authority. The sidecar opens only when the Reconstruction destination is entered or a command
/// explicitly needs it; each job session is then minted lazily for exactly one durable job ID.
@MainActor
final class ReconstructionWorkspaceRuntime: WorkspaceReconstructionJobRuntime {
    private static let logger = Logger(
        subsystem: "org.macscope.MacScope",
        category: "ReconstructionWorkspace"
    )

    private struct DatabaseOpening {
        let token: UUID
        let binding: ReconstructionWorkspaceStateBinding
        let task: Task<ReconstructionWorkspaceDatabaseRuntime, Error>
    }

    private struct ActivationTask {
        let token: UUID
        let task: Task<Bool, Never>
    }

    private struct RestorationTask {
        let token: UUID
        let task: Task<Void, Error>
    }

    private struct PresentationCommandKey: Hashable {
        let windowID: UUID
        let commandScopeID: UUID
        let commandGeneration: UInt64
        let baseProjectionRevision: UInt64
        let jobID: UUID?

        init(context: ReconstructionWorkspaceCommandContext) {
            windowID = context.windowID
            commandScopeID = context.commandScopeID
            commandGeneration = context.commandGeneration
            baseProjectionRevision = context.baseProjectionRevision
            jobID = context.jobID
        }
    }

    private struct PresentationCommandTask {
        let token: UUID
        let task: Task<ReconstructionWorkspaceCommandOutcome, Never>
    }

    private enum PresentationCommandExecution {
        case completed(createdJobID: UUID?)
        case rejected
    }

    let windowID: WorkspaceWindowID
    let lifecycleID = UUID()
    let activationModel = ReconstructionWorkspaceActivationModel()

    private weak var store: WorkspaceStore?
    private weak var documentSession: WorkspaceDocumentSession?
    private let publicationAuthority: WorkspaceStore.ReconstructionPublicationAuthority?
    private let openDatabaseRuntime: ReconstructionWorkspaceDatabaseRuntimeFactory
    private let makeJobSession: ReconstructionJobSessionFactory
    private let sourceRegistryWorkspaceID: UUID
    private var predecessorRetirement: Task<Void, Never>?
    private var durableStateObservation: AnyCancellable?

    private var databaseRuntime: ReconstructionWorkspaceDatabaseRuntime?
    private var databaseOpening: DatabaseOpening?
    private var sessionResolvers:
        [UUID: ReconstructionDestinationSessionResolver<ReconstructionJobSession>] = [:]
    /// Start/resume setup is coalesced by durable job identity. The session actor owns the
    /// longer-lived coordinator loop; this table prevents two concurrent UI/restoration calls
    /// from both reporting that they enqueued the same activation while that session is resolving.
    private var activationTasks: [UUID: ActivationTask] = [:]
    /// Covers the actor-reentrant validation/factory window before a JobSession has installed
    /// its coordinator run. It makes duplicate admission synchronously observable even while the
    /// first caller is awaiting database or session construction.
    private var activationAdmissions: Set<UUID> = []
    /// Initial durable-job starts remain part of destination restoration only until each job
    /// session has installed and retained its coordinator run. The longer-lived run completion
    /// remains in `activationTasks` independently so Pause/Cancel can become available while it
    /// is live.
    private var restoringActivationJobIDs: Set<UUID> = []
    /// Presentation commands are keyed by the exact window-issued completion coordinate. An
    /// accidental duplicate awaits the same retained task instead of dispatching twice, while
    /// different generations may overlap after a durable Store change has already cleared the
    /// earlier pending intent.
    private var presentationCommandTasks:
        [PresentationCommandKey: PresentationCommandTask] = [:]
    private var restorationCompleted = false
    private var restorationTask: RestorationTask?
    private var acceptsCommands = true
    private var corpusImportTask: Task<WorkspaceReconstructionCorpusImportPublication, Error>?
    private var corpusImportCancellation: ReconstructionCancellation?
    private var sourcePreparationSession: ReconstructionSourceOriginalSession?
    private var retirementTask: Task<Void, Never>?

    init(
        windowID: WorkspaceWindowID,
        store: WorkspaceStore,
        documentSession: WorkspaceDocumentSession,
        predecessorRetirement: Task<Void, Never>? = nil,
        openDatabaseRuntime: @escaping ReconstructionWorkspaceDatabaseRuntimeFactory,
        makeJobSession: @escaping ReconstructionJobSessionFactory
    ) {
        self.windowID = windowID
        self.store = store
        self.documentSession = documentSession
        self.predecessorRetirement = predecessorRetirement
        self.openDatabaseRuntime = openDatabaseRuntime
        self.makeJobSession = makeJobSession
        sourceRegistryWorkspaceID = store.workspaceID
        publicationAuthority = store.captureReconstructionPublicationAuthority()
        activationModel.publishPresentationAuthority(
            ReconstructionWorkspacePresentationAuthority(workspace: store.reconstructionState)
        )
        // Every accepted Reconstruction publication installs `reconstructionState` before
        // `markDocumentMutated()` publishes `isDirty`. Observing that narrow durable-mutation
        // signal avoids rebuilding the authority map for unrelated selection and debugger churn.
        durableStateObservation = store.$isDirty.sink { [weak self, weak store] _ in
            Task { @MainActor [weak self, weak store] in
                guard let self, let store, self.acceptsCommands,
                      let publicationAuthority = self.publicationAuthority,
                      store.ownsReconstructionPublicationAuthority(publicationAuthority) else {
                    return
                }
                self.activationModel.publishPresentationAuthority(
                    ReconstructionWorkspacePresentationAuthority(
                        workspace: store.reconstructionState
                    )
                )
            }
        }
    }

    /// Synchronous registry predicate. It includes the opaque Store lifecycle and, once the
    /// sidecar exists, the exact canonical document path. A same-ID restore or Save As therefore
    /// cannot reuse a runtime bound to an obsolete package coordinate.
    func isCurrent(
        for candidateStore: WorkspaceStore,
        documentSession candidateDocumentSession: WorkspaceDocumentSession
    ) -> Bool {
        guard acceptsCommands,
              store === candidateStore,
              documentSession === candidateDocumentSession,
              let publicationAuthority,
              candidateStore.ownsReconstructionPublicationAuthority(publicationAuthority),
              candidateStore.workspaceID == candidateDocumentSession.snapshot.workspaceID,
              candidateStore.documentID == candidateDocumentSession.snapshot.documentID else {
            return false
        }
        guard let binding = databaseRuntime?.binding else { return true }
        return candidateDocumentSession.snapshot.location?.canonicalURL.path
            == binding.canonicalPackagePath
    }

    var commandActions: ReconstructionWorkspaceCommandActions {
        guard commandCoordinateIsCurrentlyUsable() else { return .unavailable }
        return ReconstructionWorkspaceCommandActions(
            commandScopeID: lifecycleID,
            importCorpus: { [weak self] selections, cancellation, progress in
                guard let self else { throw ReconstructionWorkspaceRuntimeError.retired }
                return try await self.importCorpus(
                    selections: selections,
                    cancellation: cancellation,
                    progress: progress
                )
            },
            createJob: { [weak self] request, context in
                guard let self else { return Self.rejectedOutcome(for: context) }
                return await self.performPresentationCommand(
                    context: context,
                    expectedJobID: nil
                ) { runtime in
                    guard let store = runtime.store else { return .rejected }
                    do {
                        let committed = try await store.createReconstructionJob(
                            request,
                            using: runtime
                        )
                        try runtime.requireCurrentCoordinate()
                        guard store.reconstructionState.jobs.contains(where: {
                            $0.jobID == committed.job.jobID
                                && $0.reconstructionProjectID
                                    == committed.job.reconstructionProjectID
                        }) else {
                            return .rejected
                        }
                        return .completed(createdJobID: committed.job.jobID)
                    } catch {
                        return .rejected
                    }
                }
            },
            startSourceExample: { [weak self] context in
                guard let self else { return Self.rejectedOutcome(for: context) }
                return await self.runFixedSourceExperiment(context: context)
            },
            startJob: { [weak self] jobID, context in
                guard let self else { return Self.rejectedOutcome(for: context) }
                return await self.performPresentationCommand(
                    context: context,
                    expectedJobID: jobID
                ) { runtime in
                    guard let store = runtime.store,
                          await store.startReconstructionJob(jobID, using: runtime) else {
                        return .rejected
                    }
                    return .completed(createdJobID: nil)
                }
            },
            pauseJob: { [weak self] jobID, context in
                guard let self else { return Self.rejectedOutcome(for: context) }
                return await self.performPresentationCommand(
                    context: context,
                    expectedJobID: jobID
                ) { runtime in
                    guard let store = runtime.store,
                          await store.pauseReconstructionJob(jobID, using: runtime) else {
                        return .rejected
                    }
                    return .completed(createdJobID: nil)
                }
            },
            resumeJob: { [weak self] jobID, context in
                guard let self else { return Self.rejectedOutcome(for: context) }
                return await self.performPresentationCommand(
                    context: context,
                    expectedJobID: jobID
                ) { runtime in
                    guard let store = runtime.store,
                          await store.resumeReconstructionJob(jobID, using: runtime) else {
                        return .rejected
                    }
                    return .completed(createdJobID: nil)
                }
            },
            cancelJob: { [weak self] jobID, context in
                guard let self else { return Self.rejectedOutcome(for: context) }
                return await self.performPresentationCommand(
                    context: context,
                    expectedJobID: jobID
                ) { runtime in
                    guard let store = runtime.store,
                          await store.cancelReconstructionJob(jobID, using: runtime) else {
                        return .rejected
                    }
                    return .completed(createdJobID: nil)
                }
            }
        )
    }

    /// The explicit fixed-source entry uses the same sidecar, import, publication and automatic
    /// job start as ordinary creation. Unsaved or replaced documents cannot prepare an original.
    func runFixedSourceExperiment(context: ReconstructionWorkspaceCommandContext) async
        -> ReconstructionWorkspaceCommandOutcome {
        await performPresentationCommand(context: context, expectedJobID: nil) { runtime in
            guard runtime.sourcePreparationSession == nil, let store = runtime.store else {
                return .rejected
            }
            let session: ReconstructionSourceOriginalSession
            do {
                try runtime.requireCurrentCoordinate()
                _ = try await runtime.ensureDatabaseRuntime()
                try runtime.requireCurrentCoordinate()
                guard runtime.sourcePreparationSession == nil else { return .rejected }
                let workflow = ReconstructionSourceExecutionWorkflow(
                    transport: NSXPCShellBrokerTransport(),
                    toolAuthority: try .capture())
                session = ReconstructionSourceOriginalSession(workflow: workflow,
                    stageParent: try ReconstructionProductionComposition.sourceStageParent())
            } catch { return .rejected }
            runtime.sourcePreparationSession = session
            defer { runtime.sourcePreparationSession = nil }
            let workspaceID = store.workspaceID
            var proxy: ReconstructionSourceEntryJobRuntime?
            do {
                let candidate = try await session.prepare()
                try runtime.requireCurrentCoordinate()
                try Task.checkCancellation()
                let publication = try await runtime.importCorpus(
                    selections: [.init(rootURL: candidate.executableURL, roles: [.primaryTarget])],
                    cancellation: ReconstructionCancellation(), progress: nil)
                try runtime.requireCurrentCoordinate()
                guard publication.publicationAccepted, publication.result.failures.isEmpty else {
                    throw ReconstructionSourceOriginalSession.Failure.invalidBinding
                }
                let request = try ReconstructionSourceEntryJobRuntime.creationRequest(
                    candidate: candidate, imported: publication.result.occurrences,
                    committedItems: ReconstructionJobCreationItem.committedItems(in: store.reconstructionState))
                let artifact = request.selectedItems[0].artifactCoordinate
                let entry = ReconstructionSourceEntryJobRuntime(runtime: runtime, artifact: artifact,
                    projectID: request.projectID,
                    validateCoordinate: { [weak runtime] in
                        guard let runtime else { throw ReconstructionWorkspaceRuntimeError.retired }
                        try runtime.requireCurrentCoordinate()
                        try Task.checkCancellation()
                    }, bindAndRegister: { projectID, jobID in
                        try await session.bind(projectID: projectID, jobID: jobID, importedArtifact: artifact)
                        try await ReconstructionSourceOriginalSessionRegistry.shared.register(
                            workspaceID: workspaceID, jobID: jobID, session: session)
                    })
                proxy = entry
                let committed = try await store.createReconstructionJob(request, using: entry)
                try runtime.requireCurrentCoordinate()
                guard store.reconstructionState.jobs.contains(where: {
                    $0.jobID == committed.job.jobID && $0.reconstructionProjectID == request.projectID
                }) else { throw ReconstructionWorkspaceRuntimeError.durableStatePublicationRejected }
                return .completed(createdJobID: committed.job.jobID)
            } catch {
                if let jobID = proxy?.registeredJobID {
                    await ReconstructionSourceOriginalSessionRegistry.shared.remove(
                        workspaceID: workspaceID, jobID: jobID)
                }
                await session.retire()
                return .rejected
            }
        }
    }

    /// Destination entry is the sole automatic sidecar/corpus-seed reachability point. Empty
    /// windows or windows never visiting Reconstruction create no database or execution authority.
    @discardableResult
    func activateReconstructionDestination() async -> Bool {
        switch activationModel.snapshot.phase {
        case .ready, .restoring:
            return true
        case .inactive, .activating, .failed:
            break
        }
        activationModel.publish(.activating)
        do {
            _ = try await ensureDatabaseRuntime()
        } catch {
            activationModel.publish(.failed(activationFailure(for: error)))
            return false
        }
        activationModel.publish(.restoring)
        do {
            try await restoreEligibleJobs()
            publishReadyWhenInitialRestorationHasSettled()
            return true
        } catch {
            switch activationFailure(for: error) {
            case .runtimeUnavailable, .documentLocationRequired, .staleLifecycle:
                activationModel.publish(.failed(activationFailure(for: error)))
            case .sidecarUnavailable, .restorationUnavailable:
                activationModel.publish(.failed(.restorationUnavailable))
            }
            return false
        }
    }

    func commitInitialJob(
        workspaceID: UUID,
        mutation: ReconstructionInitialJobMutation
    ) async throws -> WorkspaceReconstructionInitialJobPublication {
        try requireCurrentCoordinate()
        guard store?.workspaceID == workspaceID else {
            throw ReconstructionWorkspaceRuntimeError.runtimeWorkspaceMismatch
        }
        let runtime = try await ensureDatabaseRuntime()
        let owner = try runtime.databaseOwner()
        let committed = try await owner.commitInitialJob(
            workspaceID: workspaceID,
            mutation: mutation
        )
        let sources = try await owner.availableDurableAttachmentSources(
            workspaceID: workspaceID
        )
        try requireCurrentCoordinate()
        return WorkspaceReconstructionInitialJobPublication(
            committed: committed,
            attachmentSources: sources
        )
    }

    func start(authority: ReconstructionJobCommandAuthority) async -> Bool {
        do {
            let task = try await enqueueSessionActivation(
                authority: authority,
                resuming: false
            )
            return await task.value
        } catch {
            return false
        }
    }

    func pause(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard commandCoordinateIsCurrentlyUsable() else {
            Self.logger.error("Pause rejected at command-coordinate gate")
            return false
        }
        var stage = "validate-command-authority"
        do {
            try await validateCommandAuthority(authority)
            stage = "resolve-job-session"
            let session = try await jobSession(for: authority.jobID)
            stage = "validate-command-authority-after-session-resolution"
            try await validateCommandAuthority(authority)
            stage = "validate-current-coordinate-before-session-pause"
            try requireCurrentCoordinate()
            stage = "session-pause"
            guard await session.pause(authority: authority) else {
                Self.logger.error("Pause rejected at session-pause boundary (session returned false)")
                return false
            }
            stage = "validate-current-coordinate-after-session-pause"
            try requireCurrentCoordinate()
            return true
        } catch {
            Self.logFailure("Pause", stage: stage, error: error)
            return false
        }
    }

    func resume(authority: ReconstructionJobCommandAuthority) async -> Bool {
        do {
            let task = try await enqueueSessionActivation(
                authority: authority,
                resuming: true
            )
            return await task.value
        } catch {
            return false
        }
    }

    func cancel(authority: ReconstructionJobCommandAuthority) async -> Bool {
        guard commandCoordinateIsCurrentlyUsable() else { return false }
        do {
            try await validateCommandAuthority(authority)
            let session = try await jobSession(for: authority.jobID)
            try await validateCommandAuthority(authority)
            try requireCurrentCoordinate()
            guard await session.cancel(authority: authority) else { return false }
            try requireCurrentCoordinate()
            return true
        } catch {
            return false
        }
    }

    /// Workspace restoration alone enumerates eligible IDs. Every resulting call crosses a
    /// job-scoped resolver/session; no job-bound native admission can dispatch a sibling job.
    func restoreAndResumeEligibleJobs() async -> Bool {
        guard acceptsCommands else { return false }
        activationModel.publish(.restoring)
        do {
            try await restoreEligibleJobs()
            publishReadyWhenInitialRestorationHasSettled()
            return true
        } catch {
            activationModel.publish(.failed(.restorationUnavailable))
            return false
        }
    }

    func retireTransiently() async {
        await beginRetirement().value
    }

    /// UI supplies selections and cooperative cancellation only. The database owner remains
    /// private to this document runtime, and retirement drains acquisition before closing it.
    private func importCorpus(
        selections: [ReconstructionImportSelection],
        cancellation: ReconstructionCancellation,
        progress: (@Sendable (ReconstructionImportProgress) async -> Void)?
    ) async throws -> WorkspaceReconstructionCorpusImportPublication {
        try requireCurrentCoordinate()
        guard commandCoordinateIsCurrentlyUsable(), corpusImportTask == nil else {
            throw ReconstructionWorkspaceRuntimeError.commandAuthorityMismatch
        }
        corpusImportCancellation = cancellation
        let task = Task { @MainActor [weak self] in
            guard let self else { throw ReconstructionWorkspaceRuntimeError.retired }
            try cancellation.check()
            let database = try await self.ensureDatabaseRuntime()
            try self.requireCurrentCoordinate(expectedBinding: database.binding)
            try cancellation.check()
            guard let store = self.store else {
                throw ReconstructionWorkspaceRuntimeError.staleLifecycle
            }
            let owner = try database.databaseOwner()
            let publication = try await store.importReconstructionCorpus(
                selections: selections,
                using: owner,
                cancellation: cancellation,
                progress: progress
            )
            try self.requireCurrentCoordinate(expectedBinding: database.binding)
            return publication
        }
        corpusImportTask = task
        defer {
            corpusImportTask = nil
            corpusImportCancellation = nil
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            cancellation.cancel()
            task.cancel()
        }
    }

    /// Closes command admission synchronously, then retires all job sessions through
    /// `suspendWithoutDurableDisposition` and preserves the sidecar for crash/window resume.
    func beginRetirement() -> Task<Void, Never> {
        if let retirementTask { return retirementTask }
        acceptsCommands = false
        let sourcePreparation = sourcePreparationSession
        sourcePreparationSession = nil
        let sourceWorkspaceID = sourceRegistryWorkspaceID
        corpusImportCancellation?.cancel()
        let corpusImport = corpusImportTask
        corpusImport?.cancel()
        durableStateObservation = nil
        activationModel.publish(.failed(.staleLifecycle))

        let resolvers = Array(sessionResolvers.values)
        sessionResolvers.removeAll()
        let activations = activationTasks.values.map(\.task)
        let presentationCommands = presentationCommandTasks.values.map(\.task)
        let restoration = restorationTask?.task
        activationTasks.removeAll()
        activationAdmissions.removeAll()
        presentationCommandTasks.removeAll()
        restorationTask = nil
        let opening = databaseOpening
        databaseOpening = nil
        let database = databaseRuntime
        databaseRuntime = nil
        let retirementBinding = database?.binding ?? opening?.binding

        let task = Task { [weak self] in
            await sourcePreparation?.retire()
            await ReconstructionSourceOriginalSessionRegistry.shared.retire(workspaceID: sourceWorkspaceID)
            if let corpusImport {
                _ = try? await corpusImport.value
            }
            for resolver in resolvers {
                await resolver.retire()
            }
            for activation in activations {
                _ = await activation.value
            }
            for command in presentationCommands {
                _ = await command.value
            }
            if let restoration {
                restoration.cancel()
                _ = try? await restoration.value
            }
            // Native capture can publish transient facts after its await points. Clear them only
            // after every resolver, activation, command, and restoration task that could publish
            // has quiesced, so retirement cannot race with a late registry insertion.
            await ReconstructionTransientNativePublicationRegistry.shared.retire(
                workspaceID: sourceWorkspaceID)
            var lateDatabase: ReconstructionWorkspaceDatabaseRuntime?
            if let opening {
                opening.task.cancel()
                lateDatabase = try? await opening.task.value
            }
            let sidecars = [database, lateDatabase].compactMap { $0 }
            var retiredObjectIDs: Set<ObjectIdentifier> = []
            for sidecar in sidecars {
                let identity = ObjectIdentifier(sidecar)
                guard retiredObjectIDs.insert(identity).inserted else { continue }
                if let retirementBinding, sidecar.binding == retirementBinding {
                    do {
                        try await sidecar.retire(binding: retirementBinding)
                    } catch {
                        await sidecar.close()
                    }
                } else {
                    await sidecar.close()
                }
            }
            await MainActor.run {
                self?.predecessorRetirement = nil
            }
        }
        retirementTask = task
        return task
    }

    private func enqueueSessionActivation(
        authority: ReconstructionJobCommandAuthority,
        resuming: Bool,
        preparedSession: ReconstructionJobSession? = nil,
        restoring: Bool = false
    ) async throws -> Task<Bool, Never> {
        let jobID = authority.jobID
        let coordinateIsUsable = restoring
            ? restorationCoordinateIsCurrentlyUsable()
            : commandCoordinateIsCurrentlyUsable()
        guard coordinateIsUsable,
              activationTasks[jobID] == nil,
              activationAdmissions.insert(jobID).inserted else {
            throw ReconstructionWorkspaceRuntimeError.sessionActivationRejected
        }
        if restoring {
            restoringActivationJobIDs.insert(jobID)
        }
        var admissionInstalled = false
        defer {
            if !admissionInstalled {
                activationAdmissions.remove(jobID)
                if restoring {
                    restoringActivationJobIDs.remove(jobID)
                }
            }
        }

        try await validateCommandAuthority(authority)
        let session = if let preparedSession {
            preparedSession
        } else {
            try await jobSession(for: jobID)
        }
        try await validateCommandAuthority(authority)
        try requireCurrentCoordinate()
        let sessionAdmission: ReconstructionJobSessionAdmission? = if resuming {
            await session.enqueueResume(authority: authority)
        } else {
            await session.enqueueStart(authority: authority)
        }
        guard let sessionAdmission else {
            throw ReconstructionWorkspaceRuntimeError.sessionActivationRejected
        }
        try requireCurrentCoordinate()

        let token = UUID()
        let task = Task { [weak self] in
            let accepted = await sessionAdmission.coordinatorCompletion.value
            self?.finishActivation(jobID: jobID, token: token)
            return accepted
        }
        activationTasks[jobID] = ActivationTask(token: token, task: task)
        if restoring {
            restoringActivationJobIDs.remove(jobID)
        }
        activationAdmissions.remove(jobID)
        admissionInstalled = true
        publishReadyWhenInitialRestorationHasSettled()
        return task
    }

    /// Rebuilds the immutable DB basis around every command. UI/Store membership is only the
    /// first fence; exact state, checkpoint, corpus, and evidence-frontier equality must still
    /// hold immediately before the job-scoped session receives control.
    private func validateCommandAuthority(
        _ expected: ReconstructionJobCommandAuthority
    ) async throws {
        let runtime = try await ensureDatabaseRuntime()
        let owner = try runtime.databaseOwner()
        let observed = try await commandAuthority(
            jobID: expected.jobID,
            workspaceID: runtime.binding.workspaceID,
            owner: owner
        )
        try requireCurrentCoordinate(expectedBinding: runtime.binding)
        guard observed == expected else {
            throw ReconstructionWorkspaceRuntimeError.commandAuthorityMismatch
        }
    }

    private func commandAuthority(
        jobID: UUID,
        workspaceID: UUID,
        owner: ReconstructionDatabaseOwner
    ) async throws -> ReconstructionJobCommandAuthority {
        let rows = try await owner.captureProductionRoundRows(
            workspaceID: workspaceID,
            jobID: jobID
        )
        let basis = try ReconstructionProductionRoundBasis(rows: rows)
        return ReconstructionJobCommandAuthority(
            jobID: basis.job.jobID,
            expectedJobState: basis.job.state,
            checkpointID: basis.checkpoint.checkpointID,
            checkpointRevision: basis.checkpoint.revision,
            corpusManifestSHA256: basis.manifest.canonicalSHA256,
            evidenceFrontierSHA256: basis.evidenceCut.frontierSHA256
        )
    }

    private func performPresentationCommand(
        context: ReconstructionWorkspaceCommandContext,
        expectedJobID: UUID?,
        operation: @escaping @MainActor @Sendable (
            ReconstructionWorkspaceRuntime
        ) async -> PresentationCommandExecution
    ) async -> ReconstructionWorkspaceCommandOutcome {
        guard commandContextIsCurrentlyUsable(
            context,
            expectedJobID: expectedJobID
        ) else {
            return Self.rejectedOutcome(for: context)
        }
        let key = PresentationCommandKey(context: context)
        if let existing = presentationCommandTasks[key] {
            return await existing.task.value
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return Self.rejectedOutcome(for: context) }
            let execution: PresentationCommandExecution
            if self.commandContextIsCurrentlyUsable(
                context,
                expectedJobID: expectedJobID
            ) {
                execution = await operation(self)
            } else {
                execution = .rejected
            }
            let outcome: ReconstructionWorkspaceCommandOutcome
            switch execution {
            case let .completed(createdJobID):
                outcome = ReconstructionWorkspaceCommandOutcome(
                    context: context,
                    disposition: .completed,
                    createdJobID: createdJobID
                )
            case .rejected:
                outcome = Self.rejectedOutcome(for: context)
            }
            self.finishPresentationCommand(key: key, token: token)
            return outcome
        }
        presentationCommandTasks[key] = PresentationCommandTask(
            token: token,
            task: task
        )
        return await task.value
    }

    private func commandContextIsCurrentlyUsable(
        _ context: ReconstructionWorkspaceCommandContext,
        expectedJobID: UUID?
    ) -> Bool {
        context.windowID == windowID.raw
            && context.commandScopeID == lifecycleID
            && context.jobID == expectedJobID
            && commandCoordinateIsCurrentlyUsable()
    }

    private static func rejectedOutcome(
        for context: ReconstructionWorkspaceCommandContext
    ) -> ReconstructionWorkspaceCommandOutcome {
        ReconstructionWorkspaceCommandOutcome(
            context: context,
            disposition: .rejected,
            createdJobID: nil
        )
    }

    private func finishPresentationCommand(
        key: PresentationCommandKey,
        token: UUID
    ) {
        guard presentationCommandTasks[key]?.token == token else { return }
        presentationCommandTasks[key] = nil
    }

    private func finishActivation(jobID: UUID, token: UUID) {
        guard activationTasks[jobID]?.token == token else { return }
        activationTasks[jobID] = nil
    }

    /// A destination is ready only after it has enumerated durable jobs and every initial job
    /// session has installed its retained coordinator run. Coordinator completion is deliberately
    /// not a readiness barrier because a live run is the state in which Pause/Cancel are needed.
    private func publishReadyWhenInitialRestorationHasSettled() {
        guard restorationCompleted,
              restoringActivationJobIDs.isEmpty,
              activationModel.snapshot.phase == .restoring else {
            return
        }
        activationModel.publish(.ready)
    }

    private func jobSession(for jobID: UUID) async throws -> ReconstructionJobSession {
        try requireCurrentCoordinate()
        if let resolver = sessionResolvers[jobID] {
            return try await resolver.resolve(forDurableJobID: jobID)
        }

        let runtime = try await ensureDatabaseRuntime()
        let owner = try runtime.databaseOwner()
        guard let store else {
            throw ReconstructionWorkspaceRuntimeError.staleLifecycle
        }
        let context = ReconstructionWorkspaceJobSessionFactoryContext(
            store: store,
            workspaceID: runtime.binding.workspaceID,
            owner: owner,
            factory: makeJobSession
        )
        let resolver = ReconstructionDestinationSessionResolver<ReconstructionJobSession>(
            factory: { requestedJobID in
                try await context.make(durableJobID: requestedJobID)
            },
            retire: { session in
                await session.retire()
            }
        )
        sessionResolvers[jobID] = resolver
        do {
            let session = try await resolver.resolve(forDurableJobID: jobID)
            try requireCurrentCoordinate()
            return session
        } catch {
            if sessionResolvers[jobID] === resolver {
                sessionResolvers[jobID] = nil
            }
            await resolver.retire()
            throw error
        }
    }

    private func ensureDatabaseRuntime() async throws
        -> ReconstructionWorkspaceDatabaseRuntime {
        try requireCurrentCoordinate()
        await awaitPredecessorRetirement()
        try requireCurrentCoordinate()
        if let databaseRuntime { return databaseRuntime }

        let opening: DatabaseOpening
        if let databaseOpening {
            opening = databaseOpening
        } else {
            guard let store, let documentSession else {
                throw ReconstructionWorkspaceRuntimeError.staleLifecycle
            }
            let binding = try currentBinding(store: store, documentSession: documentSession)
            let packageState = store.reconstructionState
            let packageSources = store.reconstructionAttachmentSources
            let workspaceName = store.workspaceName
            let factory = openDatabaseRuntime
            let token = UUID()
            opening = DatabaseOpening(
                token: token,
                binding: binding,
                task: Task {
                    try await factory(
                        binding,
                        packageState,
                        packageSources,
                        workspaceName
                    )
                }
            )
            databaseOpening = opening
        }

        let openedRuntime: ReconstructionWorkspaceDatabaseRuntime
        do {
            openedRuntime = try await opening.task.value
        } catch {
            if databaseOpening?.token == opening.token {
                databaseOpening = nil
            }
            throw error
        }

        do {
            guard databaseOpening?.token == opening.token else {
                throw ReconstructionWorkspaceRuntimeError.staleLifecycle
            }
            guard openedRuntime.binding == opening.binding else {
                throw ReconstructionWorkspaceRuntimeError.documentCoordinateMismatch
            }
            try requireCurrentCoordinate(expectedBinding: opening.binding)
            try await publishResolvedDurableStateIfNeeded(openedRuntime)
            try requireCurrentCoordinate(expectedBinding: opening.binding)
            databaseRuntime = openedRuntime
            databaseOpening = nil
            return openedRuntime
        } catch {
            if databaseOpening?.token == opening.token {
                databaseOpening = nil
            }
            if openedRuntime.binding == opening.binding {
                try? await openedRuntime.retire(binding: opening.binding)
            } else {
                await openedRuntime.close()
            }
            throw error
        }
    }

    private func publishResolvedDurableStateIfNeeded(
        _ runtime: ReconstructionWorkspaceDatabaseRuntime
    ) async throws {
        guard runtime.reconciliationDisposition == .usedDurableDescendant else { return }
        guard let store else {
            throw ReconstructionWorkspaceRuntimeError.staleLifecycle
        }
        let owner = try runtime.databaseOwner()
        let sources = try await owner.availableDurableAttachmentSources(
            workspaceID: runtime.binding.workspaceID
        )
        try requireCurrentCoordinate(expectedBinding: runtime.binding)
        store.publishCommittedReconstructionCorpus(ReconstructionCommittedCorpus(
            state: runtime.reconciledOpeningState,
            attachmentSources: sources,
            commitSequence: 0
        ))
        guard store.reconstructionState == runtime.reconciledOpeningState else {
            throw ReconstructionWorkspaceRuntimeError.durableStatePublicationRejected
        }
    }

    private func awaitPredecessorRetirement() async {
        guard let predecessorRetirement else { return }
        await predecessorRetirement.value
        self.predecessorRetirement = nil
    }

    private func commandCoordinateIsCurrentlyUsable() -> Bool {
        guard acceptsCommands,
              activationModel.snapshot.phase == .ready,
              store != nil,
              documentSession?.snapshot.location != nil else { return false }
        do {
            try requireCurrentCoordinate()
            return true
        } catch {
            return false
        }
    }

    private func restorationCoordinateIsCurrentlyUsable() -> Bool {
        guard acceptsCommands,
              activationModel.snapshot.phase == .restoring,
              store != nil,
              documentSession?.snapshot.location != nil else { return false }
        do {
            try requireCurrentCoordinate()
            return true
        } catch {
            return false
        }
    }

    private func restoreEligibleJobs() async throws {
        if restorationCompleted { return }
        if let restorationTask {
            try await restorationTask.task.value
            return
        }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { throw ReconstructionWorkspaceRuntimeError.staleLifecycle }
            var attemptOwnedJobIDs: [UUID] = []
            var stage = "open-database-runtime"
            do {
                let runtime = try await self.ensureDatabaseRuntime()
                stage = "create-job-persistence"
                let owner = try runtime.databaseOwner()
                let persistence = ReconstructionDatabaseJobPersistence(
                    workspaceID: runtime.binding.workspaceID,
                    owner: owner
                )
                stage = "enumerate-eligible-jobs"
                let eligibleJobIDs = try await persistence.eligibleJobIDs()
                stage = "validate-restoration-coordinate"
                try self.requireCurrentCoordinate()
                for jobID in eligibleJobIDs {
                    // A failed first restoration must leave the durable sidecar authoritative,
                    // but may not strand a transient sibling admission. Record only resolver
                    // leases this attempt minted, so a later failure never retires a caller's
                    // pre-existing session.
                    if self.sessionResolvers[jobID] == nil {
                        attemptOwnedJobIDs.append(jobID)
                    }
                    stage = "capture-command-authority"
                    let authority = try await self.commandAuthority(
                        jobID: jobID,
                        workspaceID: runtime.binding.workspaceID,
                        owner: owner
                    )
                    stage = "validate-command-authority-before-session-resolution"
                    try await self.validateCommandAuthority(authority)
                    stage = "resolve-job-session"
                    let session = try await self.jobSession(for: jobID)
                    stage = "validate-command-authority-after-session-resolution"
                    try await self.validateCommandAuthority(authority)
                    stage = "validate-coordinate-before-session-activation"
                    try self.requireCurrentCoordinate(expectedBinding: runtime.binding)
                    stage = "enqueue-restored-session-activation"
                    _ = try await self.enqueueSessionActivation(
                        authority: authority,
                        resuming: false,
                        preparedSession: session,
                        restoring: true
                    )
                }
            } catch {
                Self.logFailure("Restore eligible jobs", stage: stage, error: error)
                await self.unwindFailedRestorationAttempt(
                    attemptOwnedJobIDs: attemptOwnedJobIDs
                )
                throw error
            }
        }
        restorationTask = RestorationTask(token: token, task: task)
        do {
            try await task.value
            restorationCompleted = true
            if restorationTask?.token == token {
                restorationTask = nil
            }
            publishReadyWhenInitialRestorationHasSettled()
        } catch {
            if restorationTask?.token == token {
                restorationTask = nil
            }
            throw error
        }
    }

    /// Reverses only transient authority minted by one failed initial restoration. Durable jobs
    /// remain eligible in the sidecar, while every resolver and retained coordinator run from
    /// the failed prefix is retired before a clean retry can compose fresh sessions.
    private func unwindFailedRestorationAttempt(attemptOwnedJobIDs: [UUID]) async {
        let ownedJobIDs = Set(attemptOwnedJobIDs)
        let ownedResolvers = ownedJobIDs.compactMap { jobID in
            sessionResolvers.removeValue(forKey: jobID)
        }
        let ownedActivations = ownedJobIDs.compactMap { jobID in
            activationTasks.removeValue(forKey: jobID)?.task
        }
        for jobID in ownedJobIDs {
            activationAdmissions.remove(jobID)
            restoringActivationJobIDs.remove(jobID)
        }
        for resolver in ownedResolvers {
            await resolver.retire()
        }
        for activation in ownedActivations {
            _ = await activation.value
        }
    }

    private func activationFailure(for error: Error) -> ReconstructionWorkspaceActivationFailure {
        switch error {
        case ReconstructionWorkspaceRuntimeError.documentLocationRequired:
            .documentLocationRequired
        case ReconstructionWorkspaceRuntimeError.staleLifecycle,
             ReconstructionWorkspaceRuntimeError.retired,
             ReconstructionWorkspaceRuntimeError.publicationAuthorityUnavailable,
             ReconstructionWorkspaceRuntimeError.documentCoordinateMismatch:
            .staleLifecycle
        default:
            .sidecarUnavailable
        }
    }

    private static func logFailure(_ operation: String, stage: String, error: Error) {
        let errorType = String(reflecting: type(of: error))
        logger.error(
            "\(operation, privacy: .public) failed at \(stage, privacy: .public); errorType=\(errorType, privacy: .public)"
        )
    }

    private func requireCurrentCoordinate(
        expectedBinding: ReconstructionWorkspaceStateBinding? = nil
    ) throws {
        guard acceptsCommands else {
            if retirementTask == nil {
                throw ReconstructionWorkspaceRuntimeError.staleLifecycle
            }
            throw ReconstructionWorkspaceRuntimeError.retired
        }
        guard let store, let documentSession, let publicationAuthority else {
            throw ReconstructionWorkspaceRuntimeError.publicationAuthorityUnavailable
        }
        guard store.ownsReconstructionPublicationAuthority(publicationAuthority) else {
            throw ReconstructionWorkspaceRuntimeError.staleLifecycle
        }
        let binding = try currentBinding(store: store, documentSession: documentSession)
        if let expectedBinding, binding != expectedBinding {
            throw ReconstructionWorkspaceRuntimeError.documentCoordinateMismatch
        }
        if let runtimeBinding = databaseRuntime?.binding, binding != runtimeBinding {
            throw ReconstructionWorkspaceRuntimeError.documentCoordinateMismatch
        }
    }

    private func currentBinding(
        store: WorkspaceStore,
        documentSession: WorkspaceDocumentSession
    ) throws -> ReconstructionWorkspaceStateBinding {
        let snapshot = documentSession.snapshot
        guard snapshot.workspaceID == store.workspaceID,
              snapshot.documentID == store.documentID else {
            throw ReconstructionWorkspaceRuntimeError.documentCoordinateMismatch
        }
        guard let location = snapshot.location else {
            throw ReconstructionWorkspaceRuntimeError.documentLocationRequired
        }
        return ReconstructionWorkspaceStateBinding(
            workspaceID: store.workspaceID,
            documentID: store.documentID,
            canonicalPackagePath: location.canonicalURL.path
        )
    }
}
