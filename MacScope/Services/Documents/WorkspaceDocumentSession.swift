import Combine
import Foundation

enum WorkspaceDocumentTerminationChoice {
    case cancel
    case saveAs
    case keepLocalVersion
    /// "Don't Save" on the untitled-workspace quit prompt: standard NSDocument semantics, the
    /// untitled content is dropped and termination continues. Refused for a conflicted or
    /// located document, whose quit path never silently discards.
    case discard
}

@MainActor
protocol WorkspaceDocumentLocationReserving: AnyObject {
    func owner(of location: WorkspaceDocumentLocation) -> WorkspaceWindowID?

    func reserve(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentLocationReservationResult

    func release(
        _ location: WorkspaceDocumentLocation,
        for sessionID: WorkspaceDocumentSessionID
    )

    func releaseAll(for sessionID: WorkspaceDocumentSessionID)

    func beginPhysicalPublication(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        retainingPublishedOwnership: Bool,
        for sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID
    ) -> WorkspaceDocumentPublicationReservationResult

    func completePhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation,
        at publishedLocation: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentPublicationCompletionResult

    func cancelPhysicalPublication(
        _ publication: WorkspaceDocumentPublicationReservation
    )
}

/// The result of preparing one document for process termination. A refusal leaves the session
/// open so AppKit can cancel Quit rather than discarding dirty state that cannot be persisted
/// without violating the document's existing conflict or destination rules.
enum WorkspaceDocumentTerminationPreparationOutcome: Equatable {
    case ready
    case refused(WorkspaceDocumentWriteOutcome)
}

enum WorkspaceDocumentWindowCloseChoice: Sendable {
    case save
    case discard
    case cancel
}

/// A close request belongs to one exact document session and content identity, never just a
/// reusable window ID. Only its session can mint it; a cancelled request cannot admit a later close.
struct WorkspaceDocumentWindowCloseRequest: Equatable, Sendable {
    fileprivate let id: UUID
    fileprivate let sessionID: WorkspaceDocumentSessionID
    fileprivate let documentID: UUID
    fileprivate let workspaceID: UUID
}

struct WorkspaceDocumentWindowClosePermit: Equatable, Sendable {
    fileprivate let request: WorkspaceDocumentWindowCloseRequest
    fileprivate let generation: WorkspaceDocumentMutationGeneration
    fileprivate let discardsChanges: Bool
}

enum WorkspaceDocumentWindowCloseOutcome: Equatable, Sendable {
    case admitted(WorkspaceDocumentWindowClosePermit)
    case cancelled
    case refused(WorkspaceDocumentWriteOutcome)
}

/// Main-actor lifecycle authority for one workspace document window.
///
/// `WorkspaceStore` remains the content authority and `WorkspaceDocumentIO` remains the
/// serialized filesystem authority. This object owns the transaction boundary between them:
/// a completion may land only while its exact request ID and save generation are still active.
@MainActor
final class WorkspaceDocumentSession: ObservableObject, WorkspaceDocumentMutationObserving {
    private struct PublicationCompletion: Sendable {
        let receipt: WorkspaceDocumentPublishReceipt
        let reservation: WorkspaceDocumentPublicationReservation
    }

    @Published private(set) var snapshot: WorkspaceDocumentSessionSnapshot

    private let sessionID: WorkspaceDocumentSessionID
    private let windowID: WorkspaceWindowID
    private weak var source: (any WorkspaceDocumentContentSource)?
    private let io: WorkspaceDocumentIO
    private weak var reservations: (any WorkspaceDocumentLocationReserving)?

    private var documentID: UUID
    private var workspaceID: UUID
    private var location: WorkspaceDocumentLocation?
    private var expectedExternalVersion: WorkspacePackageExternalVersion?
    private var mutationGeneration: WorkspaceDocumentMutationGeneration
    private var savedMutationGeneration: WorkspaceDocumentMutationGeneration
    private var hasUnsavedChanges: Bool
    private var nextSaveGeneration = WorkspaceDocumentSaveGeneration(rawValue: 0)
    private var activeSave: WorkspaceDocumentActiveSave?
    private var conflict: WorkspaceDocumentConflict?
    private var lastFailure: String?

    private var isClosed = false
    private var windowClosePreparation: WorkspaceDocumentWindowCloseRequest?
    private var windowClosePermit: WorkspaceDocumentWindowClosePermit?
    /// App termination is distinct from an ordinary window close. A close must revoke an
    /// in-flight publication immediately so a dead window cannot publish later; termination
    /// instead first drains an already-admitted publication and persists any dirty, located
    /// document through the same atomic write path. This fence rejects new UI writes while that
    /// bounded drain is in progress.
    private var isTerminating = false
    /// Identity-fences one reversible termination preparation. Rollback clears the identity, so
    /// a late continuation from a cancelled attempt can neither save nor authorize a later one.
    private var terminationPreparationID: UUID?
    private var terminationCancellationRequestedID: UUID?
    /// The exact mutation generation an explicit quit-time "Don't Save" approved for discard.
    /// A later edit changes the generation and so is never discarded by an earlier approval.
    private var terminationDiscardedGeneration: WorkspaceDocumentMutationGeneration?
    private var writeIntentActive = false
    private var writeIntentSucceeded = false
    /// A debounce that fires during a write is demand for the latest content, not another
    /// writer. A successful write drains at most one coalesced demand after releasing admission.
    private var pendingAutosave = false
    private var autosaveDrainTask: Task<Void, Never>?
    private var lifecycleEpoch: UInt64 = 0
    private var writeTask: Task<PublicationCompletion, Error>?
    private var preflightTask: Task<WorkspacePackageExternalVersion, Error>?
    private var reloadTask: Task<WorkspaceDocumentValidatedPackage, Error>?
    private var monitorTask: Task<Void, Never>?
    private var monitorProbeTask: Task<Void, Never>?
    private var monitorProbeDemand: WorkspaceDocumentProbeDemand?
    private var monitorHintPendingForWrite = false
    private var monitorEpoch: UInt64 = 0
    private var terminationQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        sessionID: WorkspaceDocumentSessionID,
        windowID: WorkspaceWindowID,
        source: any WorkspaceDocumentContentSource,
        io: WorkspaceDocumentIO,
        reservations: any WorkspaceDocumentLocationReserving
    ) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.source = source
        self.io = io
        self.reservations = reservations
        documentID = source.documentID
        workspaceID = source.workspaceID
        mutationGeneration = source.mutationGeneration
        savedMutationGeneration = source.mutationGeneration
        hasUnsavedChanges = source.hasUnsavedChanges
        snapshot = WorkspaceDocumentSessionSnapshot(
            sessionID: sessionID,
            documentID: source.documentID,
            workspaceID: source.workspaceID,
            location: nil,
            expectedExternalVersion: nil,
            mutationGeneration: source.mutationGeneration,
            savedMutationGeneration: source.mutationGeneration,
            hasUnsavedChanges: source.hasUnsavedChanges,
            nextSaveGeneration: WorkspaceDocumentSaveGeneration(rawValue: 0),
            activeSave: nil,
            conflict: nil,
            lastFailure: nil
        )

        (source as? WorkspaceStore)?.bindDocumentSessionMutationObserver(self)
    }

    func noteMutation(_ generation: WorkspaceDocumentMutationGeneration) {
        guard !isClosed, generation >= mutationGeneration, let source else { return }
        mutationGeneration = generation
        documentID = source.documentID
        workspaceID = source.workspaceID
        hasUnsavedChanges = source.hasUnsavedChanges
        publishSnapshot()
    }

    func bindOpenedPackage(
        _ package: WorkspaceDocumentValidatedPackage,
        at proposedLocation: WorkspaceDocumentLocation
    ) throws {
        guard !isClosed, !isTerminating, windowClosePreparation == nil else {
            throw WorkspaceDocumentSessionError.closed
        }
        guard package.observation.condition == .valid,
              package.observation.location.canonicalURL == proposedLocation.canonicalURL else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-open-observation-mismatch"
            )
        }
        guard let reservations else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-reservation-authority-unavailable"
            )
        }
        switch reservations.reserve(
            package.observation.location,
            for: sessionID,
            windowID: windowID
        ) {
        case .reserved:
            break
        case .alreadyOwned:
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-location-owned-by-another-window"
            )
        }

        if let prior = location,
           prior.canonicalURL != package.observation.location.canonicalURL {
            reservations.release(prior, for: sessionID)
        }
        location = package.observation.location
        expectedExternalVersion = package.observation
        cancelPendingAutosave()
        refreshFromSource(markCurrentAsSaved: true)
        conflict = nil
        lastFailure = nil
        publishSnapshot()
        replaceMonitorRegistration(at: package.observation.location)
    }

    func save() async -> WorkspaceDocumentWriteOutcome {
        await save(allowingWindowClose: nil)
    }

    private func save(
        allowingWindowClose request: WorkspaceDocumentWindowCloseRequest?
    ) async -> WorkspaceDocumentWriteOutcome {
        guard admitWriteIntent(allowingWindowClose: request) else { return writeAdmissionFailure() }
        defer { finishWriteIntent() }
        guard conflict == nil else {
            return .failed("document-conflict-unresolved")
        }
        guard let location, let expectedExternalVersion else {
            return .failed("document-location-unavailable")
        }
        return await performWrite(
            intent: .save,
            destination: location,
            expected: expectedExternalVersion,
            adopting: nil,
            clearsDirty: true
        )
    }

    func autosaveIfNeeded() async -> WorkspaceDocumentWriteOutcome? {
        // A debounce may fire while Reload owns admission, before mutation observation lands.
        if reloadTask != nil, let source, source.hasUnsavedChanges {
            pendingAutosave = true
            return nil
        }
        guard !isClosed,
              !isTerminating,
              windowClosePreparation == nil,
              conflict == nil,
              hasUnsavedChanges else {
            return nil
        }
        if writeIntentActive || activeSave != nil {
            pendingAutosave = true
            return nil
        }
        guard location != nil, expectedExternalVersion != nil else { return nil }
        guard admitWriteIntent() else { return nil }
        defer { finishWriteIntent() }
        guard let location, let expectedExternalVersion else { return nil }
        return await performWrite(
            intent: .autosave,
            destination: location,
            expected: expectedExternalVersion,
            adopting: nil,
            clearsDirty: true
        )
    }

    func saveAs(to url: URL) async -> WorkspaceDocumentWriteOutcome {
        await saveAs(to: url, allowingWindowClose: nil)
    }

    private func saveAs(
        to url: URL,
        allowingWindowClose request: WorkspaceDocumentWindowCloseRequest?,
        allowingTermination: Bool = false
    ) async -> WorkspaceDocumentWriteOutcome {
        guard admitWriteIntent(allowingTermination: allowingTermination, allowingWindowClose: request) else { return writeAdmissionFailure() }
        defer { finishWriteIntent() }

        let destination: WorkspaceDocumentLocation
        do {
            destination = try WorkspaceDocumentLocation.canonicalized(from: url)
        } catch {
            return failCurrentIntent(error)
        }
        guard let reservations else {
            return failCurrentIntent(
                WorkspaceDocumentSessionError.operationFailed(
                    "document-reservation-authority-unavailable"
                )
            )
        }

        let priorLocation = location
        let acquiredDestinationReservation = priorLocation.map {
            $0.canonicalURL != destination.canonicalURL
        } ?? true
        func releaseNewlyAcquiredDestinationReservation() {
            guard acquiredDestinationReservation else { return }
            reservations.release(destination, for: sessionID)
        }

        switch reservations.reserve(
            destination,
            for: sessionID,
            windowID: windowID
        ) {
        case .reserved:
            break
        case .alreadyOwned:
            return await ownershipConflict(at: destination, intent: .saveAs(adopting: destination))
        }

        let expected: WorkspacePackageExternalVersion
        do {
            expected = try await observeForWriteIntent(destination.canonicalURL)
        } catch {
            releaseNewlyAcquiredDestinationReservation()
            return isClosed ? .superseded : failCurrentIntent(error)
        }
        guard !isClosed else {
            releaseNewlyAcquiredDestinationReservation()
            return .superseded
        }
        if let request, !windowCloseRequestIsCurrent(request) {
            releaseNewlyAcquiredDestinationReservation()
            return .superseded
        }

        let outcome = await performWrite(
            intent: .saveAs(adopting: expected.location),
            destination: expected.location,
            expected: expected,
            adopting: expected.location,
            clearsDirty: true
        )
        guard case .saved = outcome else {
            releaseNewlyAcquiredDestinationReservation()
            return outcome
        }
        if let priorLocation,
           priorLocation.canonicalURL != destination.canonicalURL {
            reservations.release(priorLocation, for: sessionID)
        }
        return outcome
    }

    func saveCopy(to url: URL) async -> WorkspaceDocumentWriteOutcome {
        guard admitWriteIntent() else { return writeAdmissionFailure() }
        defer { finishWriteIntent() }

        let destination: WorkspaceDocumentLocation
        do {
            destination = try WorkspaceDocumentLocation.canonicalized(from: url)
        } catch {
            return failCurrentIntent(error)
        }
        guard !isActiveCopyDestination(destination) else {
            return .failed("document-save-copy-active-destination-use-save")
        }
        if let owner = reservations?.owner(of: destination), owner != windowID {
            return await ownershipConflict(at: destination, intent: .saveCopy(to: destination))
        }
        let expected: WorkspacePackageExternalVersion
        do {
            expected = try await observeForWriteIntent(destination.canonicalURL)
        } catch {
            return isClosed ? .superseded : failCurrentIntent(error)
        }
        guard !isClosed else { return .superseded }
        guard !isActiveCopyDestination(expected.location) else {
            return .failed("document-save-copy-active-destination-use-save")
        }
        return await performWrite(
            intent: .saveCopy(to: expected.location),
            destination: expected.location,
            expected: expected,
            adopting: nil,
            clearsDirty: false
        )
    }

    func reloadFromDisk() async -> Result<Void, WorkspaceDocumentSessionError> {
        guard !isClosed, !isTerminating, windowClosePreparation == nil else { return .failure(.closed) }
        guard !writeIntentActive, activeSave == nil, reloadTask == nil else {
            return .failure(.writeAlreadyActive)
        }
        guard let location else { return .failure(.noActiveLocation) }
        guard let capturedSource = source else { return .failure(.closed) }
        let capturedDocumentID = capturedSource.documentID
        let capturedWorkspaceID = capturedSource.workspaceID
        let capturedMutation = capturedSource.mutationGeneration
        let capturedExternalVersion = expectedExternalVersion
        var installed = false

        cancelPendingAutosave()
        writeIntentActive = true
        let epoch = lifecycleEpoch
        let task = Task { [io] in
            try await io.readValidated(from: location)
        }
        reloadTask = task
        defer {
            reloadTask = nil
            let sameIdentity = source === capturedSource
                && capturedSource.documentID == capturedDocumentID
                && capturedSource.workspaceID == capturedWorkspaceID
                && self.location == location
                && expectedExternalVersion == capturedExternalVersion
            if !installed, sameIdentity, !isClosed, lifecycleEpoch == epoch {
                refreshFromSource(markCurrentAsSaved: false)
                pendingAutosave = pendingAutosave || capturedSource.hasUnsavedChanges
            }
            finishWriteIntent(resumeReloadAutosave: !installed && sameIdentity,
                              probeMonitor: sameIdentity || installed)
        }

        do {
            let package = try await task.value
            guard !isClosed, lifecycleEpoch == epoch else {
                return .failure(.closed)
            }
            guard package.observation.condition == .valid,
                  package.observation.location.canonicalURL == location.canonicalURL,
                  let source else {
                return .failure(.operationFailed("document-reload-observation-mismatch"))
            }
            // Read source authority directly: its observer can still be queued. Check and
            // installation are synchronous on the main actor, with no intervening suspension.
            guard source === capturedSource,
                  source.documentID == capturedDocumentID,
                  source.workspaceID == capturedWorkspaceID,
                  self.location == location,
                  expectedExternalVersion == capturedExternalVersion else {
                return .failure(.operationFailed("document-reload-identity-changed"))
            }
            guard source.mutationGeneration == capturedMutation else {
                refreshFromSource(markCurrentAsSaved: false)
                lastFailure = "document-reload-newer-edits"
                publishSnapshot()
                return .failure(.operationFailed("document-reload-newer-edits"))
            }
            try source.installValidatedPackage(package, from: package.observation.location)
            installed = true
            self.location = package.observation.location
            expectedExternalVersion = package.observation
            refreshFromSource(markCurrentAsSaved: true)
            conflict = nil
            lastFailure = nil
            publishSnapshot()
            replaceMonitorRegistration(at: package.observation.location)
            return .success(())
        } catch {
            guard !isClosed, lifecycleEpoch == epoch else {
                return .failure(.closed)
            }
            guard source === capturedSource,
                  capturedSource.documentID == capturedDocumentID,
                  capturedSource.workspaceID == capturedWorkspaceID,
                  self.location == location,
                  expectedExternalVersion == capturedExternalVersion else {
                return .failure(.operationFailed("document-reload-identity-changed"))
            }
            refreshFromSource(markCurrentAsSaved: false)
            let mapped = mappedSessionError(error)
            lastFailure = diagnostic(for: mapped)
            publishSnapshot()
            return .failure(mapped)
        }
    }

    func keepLocalVersion() async -> WorkspaceDocumentWriteOutcome {
        guard admitWriteIntent() else { return writeAdmissionFailure() }
        defer { finishWriteIntent() }
        guard let conflict else {
            return .failed("document-conflict-unresolved")
        }
        guard conflict.observed.condition != .unverifiable else {
            return .failed("package-state-unverifiable")
        }
        guard let location,
              location.canonicalURL == conflict.observed.location.canonicalURL else {
            return .failed("document-conflict-location-mismatch")
        }
        return await performWrite(
            intent: .keepLocalVersion(over: conflict.observed),
            destination: conflict.observed.location,
            expected: conflict.observed,
            adopting: nil,
            clearsDirty: true
        )
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        (source as? WorkspaceStore)?.retireDocumentSessionWriter()
        (source as? WorkspaceStore)?.retireDebuggerPresentationSession()
        windowClosePreparation = nil
        windowClosePermit = nil
        cancelPendingAutosave()
        lifecycleEpoch &+= 1
        writeTask?.cancel()
        preflightTask?.cancel()
        reloadTask?.cancel()
        monitorTask?.cancel()
        monitorProbeTask?.cancel()
        writeTask = nil
        preflightTask = nil
        reloadTask = nil
        monitorTask = nil
        monitorProbeTask = nil
        monitorProbeDemand = nil
        monitorHintPendingForWrite = false
        terminationPreparationID = nil
        terminationCancellationRequestedID = nil
        writeIntentActive = false
        activeSave = nil
        resumeTerminationWaitersIfQuiescent()
        reservations?.releaseAll(for: sessionID)
        (source as? WorkspaceStore)?.bindDocumentSessionMutationObserver(nil)
        publishSnapshot()
    }

    /// Fences new user-initiated operations, waits for an operation that was already admitted to
    /// reach its normal terminal state, then persists remaining dirty state using the ordinary
    /// atomic save transaction. Untitled destinations and conflict replacement require an
    /// explicit native decision; callers without a presenter remain fail-closed.
    ///
    /// The registry calls this only for process termination. Ordinary window eviction still calls
    /// `close()` directly, preserving the prompt cancellation behavior required when a document
    /// window disappears before an in-flight transaction may publish.
    @discardableResult
    func beginTerminationPreparation() -> Bool {
        guard !isClosed, windowClosePreparation == nil else { return false }
        if isTerminating {
            guard let terminationPreparationID else { return false }
            return terminationCancellationRequestedID != terminationPreparationID
        }
        isTerminating = true
        cancelPendingAutosave()
        (source as? WorkspaceStore)?.autosaveScheduler?.cancelPendingAutosave()
        terminationPreparationID = UUID()
        terminationCancellationRequestedID = nil
        cancelDocumentMonitoring()
        return true
    }

    func quiesceAndSaveForTermination(
        choose: (@MainActor (WorkspaceDocumentSessionSnapshot) async -> WorkspaceDocumentTerminationChoice)? = nil,
        chooseSaveDestination: @escaping @MainActor () async -> URL? = { nil }
    ) async
        -> WorkspaceDocumentTerminationPreparationOutcome {
        guard !isClosed else { return .ready }
        guard beginTerminationPreparation(), let preparationID = terminationPreparationID else {
            return .refused(.failed("document-termination-cancelled"))
        }

        return await withTaskCancellationHandler {
            guard await waitForWriteQuiescenceForTermination(preparationID: preparationID),
                  terminationPreparationIsCurrent(preparationID) else {
                return .refused(.failed("document-termination-cancelled"))
            }

            // A retained store operation may have changed content without an observer delivery
            // while the registry was draining it. Refresh before deciding that no write is needed.
            refreshFromSource(markCurrentAsSaved: false)
            guard hasUnsavedChanges || conflict != nil else { return .ready }
            if conflict == nil, terminationDiscardedGeneration == mutationGeneration { return .ready }
            if conflict != nil || location == nil {
                guard let choose else {
                    return .refused(.failed(conflict != nil
                        ? "document-conflict-unresolved" : "document-location-unavailable"))
                }
                publishSnapshot()
                let decisionSnapshot = snapshot
                let choice = await choose(decisionSnapshot)
                guard terminationPreparationIsCurrent(preparationID) else {
                    return .refused(.failed("document-termination-cancelled"))
                }
                refreshFromSource(markCurrentAsSaved: false)
                guard mutationGeneration == decisionSnapshot.mutationGeneration,
                      conflict == decisionSnapshot.conflict else {
                    return .refused(.failed("document-termination-content-changed"))
                }
                let outcome: WorkspaceDocumentWriteOutcome
                switch choice {
                case .cancel:
                    return .refused(.failed("document-termination-cancelled"))
                case .saveAs:
                    guard let destination = await chooseSaveDestination(),
                          terminationPreparationIsCurrent(preparationID) else {
                        return .refused(.failed("document-termination-cancelled"))
                    }
                    // A conflict's original destination is never overwritten by Save As.
                    if let conflict,
                       (try? WorkspaceDocumentLocation.canonicalized(from: destination))?.canonicalURL
                        == conflict.observed.location.canonicalURL {
                        return .refused(.failed("document-conflict-save-as-requires-new-location"))
                    }
                    outcome = await saveAs(to: destination, allowingWindowClose: nil, allowingTermination: true)
                case .keepLocalVersion:
                    guard let conflict, conflict == decisionSnapshot.conflict,
                          conflict.observed.condition != .unverifiable,
                          location?.canonicalURL == conflict.observed.location.canonicalURL,
                          admitWriteIntent(allowingTermination: true) else {
                        return .refused(.failed("document-conflict-unresolved"))
                    }
                    outcome = await performWrite(
                        intent: .keepLocalVersion(over: conflict.observed),
                        destination: conflict.observed.location, expected: conflict.observed,
                        adopting: nil, clearsDirty: true
                    )
                    finishWriteIntent()
                case .discard:
                    guard conflict == nil, location == nil else {
                        return .refused(.failed("document-termination-discard-refused"))
                    }
                    terminationDiscardedGeneration = mutationGeneration
                    return .ready
                }
                guard terminationPreparationIsCurrent(preparationID),
                      case .saved(let clean, _) = outcome, clean, !hasUnsavedChanges else {
                    return .refused(outcome)
                }
                return .ready
            }
            guard let location, let expectedExternalVersion else {
                return .refused(.failed("document-location-unavailable"))
            }
            guard admitWriteIntent(allowingTermination: true) else {
                return .refused(writeAdmissionFailure())
            }
            let outcome = await performWrite(
                intent: .save,
                destination: location,
                expected: expectedExternalVersion,
                adopting: nil,
                clearsDirty: true
            )
            finishWriteIntent()
            guard terminationPreparationIsCurrent(preparationID) else {
                return .refused(.failed("document-termination-cancelled"))
            }
            if case .conflicted = outcome, choose != nil {
                return await quiesceAndSaveForTermination(
                    choose: choose, chooseSaveDestination: chooseSaveDestination
                )
            }
            guard case .saved(let clean, _) = outcome,
                  clean,
                  !hasUnsavedChanges else {
                return .refused(outcome)
            }
            return .ready
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.requestTerminationCancellation(preparationID)
            }
        }
    }

    /// Synchronous removal fence used only after the registry has prepared its complete captured
    /// session set. Refreshing from the content source here closes the gap where a mutation was
    /// delivered while another document's async termination preparation was still running.
    /// Callers must inspect the complete ID-to-session set and remove it without another `await`.
    func isReadyForTerminationRemoval() -> Bool {
        guard isTerminating, !isClosed, source != nil else { return false }
        refreshFromSource(markCurrentAsSaved: false)
        let discarded = conflict == nil && location == nil
            && terminationDiscardedGeneration == mutationGeneration
        return (!hasUnsavedChanges || discarded)
            && activeSave == nil
            && !hasInFlightWriteIntent
    }

    /// Test-observable proof that termination reached the write-admission fence. This remains
    /// internal so focused CoreTests can deterministically coordinate a paused publication
    /// without a timing-only `Task.yield()` assumption.
    var isTerminationPreparationActive: Bool {
        isTerminating && !isClosed
    }

    /// Cancels a previously prepared (but not yet closed) termination attempt. The registry uses
    /// this when another document refuses to terminate, restoring every earlier session to its
    /// normal live state before AppKit receives a negative Quit reply.
    func cancelTerminationPreparation() {
        guard isTerminating, !isClosed else { return }
        if let preparationID = terminationPreparationID {
            requestTerminationCancellation(preparationID)
        }
        isTerminating = false
        terminationPreparationID = nil
        terminationCancellationRequestedID = nil
        terminationDiscardedGeneration = nil
        guard let location else { return }
        replaceMonitorRegistration(at: location)
    }

    // MARK: - Ordinary window-close admission

    var isClosedForWindowClose: Bool { isClosed }

    /// Native closure first acquires a reversible, per-session write fence. This is separate
    /// from Quit: neither operation can adopt or cancel the other's preparation.
    func beginWindowClosePreparation() -> WorkspaceDocumentWindowCloseRequest? {
        guard !isClosed, !isTerminating, windowClosePreparation == nil, source != nil else {
            return nil
        }
        refreshFromSource(markCurrentAsSaved: false)
        let request = WorkspaceDocumentWindowCloseRequest(
            id: UUID(), sessionID: sessionID, documentID: documentID, workspaceID: workspaceID
        )
        windowClosePreparation = request
        windowClosePermit = nil
        cancelPendingAutosave()
        (source as? WorkspaceStore)?.autosaveScheduler?.cancelPendingAutosave()
        cancelDocumentMonitoring()
        publishSnapshot()
        return request
    }

    /// Cancellation revokes only this close request. An atomic write already admitted before
    /// cancellation remains owned by this live session and may finish; it can never close it.
    func cancelWindowClosePreparation(
        _ request: WorkspaceDocumentWindowCloseRequest,
        resumeAutosave: Bool = true
    ) {
        guard windowClosePreparation == request, !isClosed else { return }
        windowClosePreparation = nil
        windowClosePermit = nil
        resumeAllTerminationWaiters()
        refreshFromSource(markCurrentAsSaved: false)
        if let location { replaceMonitorRegistration(at: location) }
        if resumeAutosave, hasUnsavedChanges, conflict == nil {
            (source as? WorkspaceStore)?.autosaveScheduler?.scheduleAutosave()
        }
        publishSnapshot()
    }

    /// Waits only for admitted work, then obtains an explicit decision for dirty content.
    /// The native adapter supplies window-bound sheets and registry identity validation.
    /// IO waits are bounded; time spent deciding in a sheet is not a timeout.
    func prepareForWindowClose(
        _ request: WorkspaceDocumentWindowCloseRequest,
        isCurrent: @escaping @MainActor () -> Bool,
        drain: @escaping @MainActor () async -> Bool,
        choose: @escaping @MainActor (WorkspaceDocumentSessionSnapshot) async -> WorkspaceDocumentWindowCloseChoice,
        chooseSaveDestination: @escaping @MainActor () async -> URL?,
        ioTimeout: Duration = .seconds(30)
    ) async -> WorkspaceDocumentWindowCloseOutcome {
        var preservesPreparation = false
        var resumesAutosave = true
        defer {
            if !preservesPreparation {
                cancelWindowClosePreparation(request, resumeAutosave: resumesAutosave)
            }
        }
        return await withTaskCancellationHandler {
            guard windowCloseRequestIsCurrent(request), isCurrent() else { return .cancelled }

            let drainTask = Task { @MainActor in await drain() }
            switch await WorkspaceDocumentCloseWaiter.wait(for: drainTask, timeout: ioTimeout) {
            case .completed(true): break
            case .completed(false):
                return .refused(.failed("document-close-analysis-in-progress"))
            case .cancelled: return .cancelled
            case .timedOut:
                resumesAutosave = false
                return .refused(.failed("document-close-wait-timed-out"))
            }
            guard windowCloseRequestIsCurrent(request), isCurrent() else { return .cancelled }

            let writeDrain = Task { @MainActor in
                await self.waitForWriteQuiescenceForWindowClose(request)
            }
            switch await WorkspaceDocumentCloseWaiter.wait(for: writeDrain, timeout: ioTimeout) {
            case .completed(true): break
            case .completed(false), .cancelled: return .cancelled
            case .timedOut:
                resumesAutosave = false
                return .refused(.failed("document-close-wait-timed-out"))
            }
            guard windowCloseRequestIsCurrent(request), isCurrent() else { return .cancelled }
            publishSnapshot()
            let decisionSnapshot = snapshot
            var discardsChanges = false

            if hasUnsavedChanges {
                let choice = await choose(decisionSnapshot)
                guard windowCloseRequestIsCurrent(request), isCurrent() else { return .cancelled }
                switch choice {
                case .cancel:
                    return .cancelled
                case .discard:
                    // Approval for an earlier revision must never discard a later arriving edit.
                    guard mutationGeneration == decisionSnapshot.mutationGeneration else {
                        return .refused(.failed("document-close-content-changed"))
                    }
                    discardsChanges = true
                case .save:
                    let destination: URL?
                    if location == nil {
                        guard let chosen = await chooseSaveDestination() else { return .cancelled }
                        destination = chosen
                    } else {
                        destination = nil
                    }
                    guard windowCloseRequestIsCurrent(request), isCurrent() else { return .cancelled }
                    let write = Task { @MainActor in
                        guard self.windowCloseRequestIsCurrent(request) else {
                            return WorkspaceDocumentWriteOutcome.superseded
                        }
                        if let destination {
                            return await self.saveAs(to: destination, allowingWindowClose: request)
                        }
                        return await self.save(allowingWindowClose: request)
                    }
                    let outcome: WorkspaceDocumentWriteOutcome
                    switch await WorkspaceDocumentCloseWaiter.wait(for: write, timeout: ioTimeout) {
                    case .completed(let result): outcome = result
                    case .cancelled: return .cancelled
                    case .timedOut:
                        resumesAutosave = false
                        return .refused(.failed("document-close-wait-timed-out"))
                    }
                    guard windowCloseRequestIsCurrent(request), isCurrent() else { return .cancelled }
                    guard case .saved(let clean, _) = outcome, clean, !hasUnsavedChanges else {
                        // Preserve the usual no-automatic-retry behavior after a failed write.
                        resumesAutosave = false
                        if case .saved = outcome {
                            return .refused(.failed("document-close-content-changed"))
                        }
                        return .refused(outcome)
                    }
                }
            }

            guard windowCloseRequestIsCurrent(request), isCurrent(), !hasInFlightWriteIntent,
                  discardsChanges || !hasUnsavedChanges else {
                return .refused(.failed("document-close-content-changed"))
            }
            let permit = WorkspaceDocumentWindowClosePermit(
                request: request, generation: mutationGeneration, discardsChanges: discardsChanges
            )
            windowClosePermit = permit
            preservesPreparation = true
            return .admitted(permit)
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancelWindowClosePreparation(request) }
        }
    }

    /// Called synchronously from the replayed native should-close callback, after the previous
    /// delegate's veto. Keep the write fence until willClose performs normal terminal eviction.
    func consumeWindowClosePermit(_ permit: WorkspaceDocumentWindowClosePermit) -> Bool {
        guard windowClosePermit == permit else { return false }
        windowClosePermit = nil
        guard windowCloseRequestIsCurrent(permit.request),
              mutationGeneration == permit.generation,
              !hasInFlightWriteIntent,
              permit.discardsChanges || !hasUnsavedChanges else { return false }
        return true
    }

    private func windowCloseRequestIsCurrent(_ request: WorkspaceDocumentWindowCloseRequest) -> Bool {
        guard !Task.isCancelled, !isClosed, !isTerminating,
              windowClosePreparation == request, source != nil else { return false }
        refreshFromSource(markCurrentAsSaved: false)
        return sessionID == request.sessionID
            && documentID == request.documentID
            && workspaceID == request.workspaceID
    }

    private func waitForWriteQuiescenceForWindowClose(
        _ request: WorkspaceDocumentWindowCloseRequest
    ) async -> Bool {
        while hasInFlightWriteIntent && windowCloseRequestIsCurrent(request) {
            await withCheckedContinuation { continuation in
                if hasInFlightWriteIntent && windowCloseRequestIsCurrent(request) {
                    terminationQuiescenceWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
        return windowCloseRequestIsCurrent(request)
    }

    private func performWrite(
        intent: WorkspaceDocumentWriteIntent,
        destination: WorkspaceDocumentLocation,
        expected: WorkspacePackageExternalVersion,
        adopting adoptedLocation: WorkspaceDocumentLocation?,
        clearsDirty: Bool
    ) async -> WorkspaceDocumentWriteOutcome {
        guard !isClosed else { return .failed("document-session-closed") }
        guard activeSave == nil else { return .failed("document-write-already-active") }
        guard destination.canonicalURL == expected.location.canonicalURL else {
            return .failed("document-write-observation-location-mismatch")
        }
        guard let source else {
            return .failed("document-content-source-unavailable")
        }
        guard let reservations else {
            return .failed("document-reservation-authority-unavailable")
        }

        let saveGeneration: WorkspaceDocumentSaveGeneration
        do {
            saveGeneration = try nextSaveGeneration.next()
        } catch {
            return failCurrentIntent(error)
        }
        // One decode-once scope spans payload capture, staging and publication of these
        // manifest bytes (lane AG); it ends with the write task.
        let decodeScope = WorkspaceManifestDecodeScope()
        let payload: WorkspaceDocumentPackagePayload
        do {
            payload = try WorkspaceManifestDecodeScope.$current.withValue(decodeScope) {
                try source.makePackagePayload()
            }
        } catch {
            return failCurrentIntent(Self.classifiedWriteError(error, phase: "capture"))
        }
        guard payload.documentID == source.documentID,
              payload.workspaceID == source.workspaceID,
              payload.capturedMutationGeneration == source.mutationGeneration else {
            return .failed("document-payload-capture-mismatch")
        }

        nextSaveGeneration = saveGeneration
        let requestID = WorkspaceDocumentSaveRequestID(rawValue: UUID())
        let admitted = WorkspaceDocumentActiveSave(
            requestID: requestID,
            saveGeneration: saveGeneration,
            capturedMutationGeneration: payload.capturedMutationGeneration,
            intent: intent
        )
        activeSave = admitted
        lastFailure = nil
        publishSnapshot()

        let task = Task { [io, reservations, decodeScope] in
            try await WorkspaceManifestDecodeScope.$current.withValue(decodeScope) {
                let staged: WorkspaceDocumentStagedPackage
                do {
                    staged = try await io.stage(
                        payload, in: destination.canonicalURL.deletingLastPathComponent()
                    )
                } catch {
                    throw Self.classifiedWriteError(error, phase: "stage")
                }
                var publication: WorkspaceDocumentPublicationReservation?
                do {
                    try Task.checkCancellation()
                    switch reservations.beginPhysicalPublication(
                        staged,
                        to: destination,
                        retainingPublishedOwnership: clearsDirty,
                        for: sessionID,
                        windowID: windowID
                    ) {
                    case .reserved(let admitted):
                        publication = admitted
                    case .alreadyOwned:
                        throw WorkspaceDocumentSessionError.operationFailed(
                            "document-location-owned-by-another-window"
                        )
                    }
                    let receipt = try await io.publish(
                        staged,
                        to: destination,
                        expecting: expected
                    )
                    guard let publication else {
                        throw WorkspaceDocumentSessionError.operationFailed(
                            "document-publication-reservation-missing"
                        )
                    }
                    return PublicationCompletion(
                        receipt: receipt,
                        reservation: publication
                    )
                } catch {
                    if let publication {
                        reservations.cancelPhysicalPublication(publication)
                    }
                    await io.discard(staged)
                    throw Self.classifiedWriteError(error, phase: "publish")
                }
            }
        }
        writeTask = task

        do {
            let completion = try await task.value
            let receipt = completion.receipt
            guard isCurrent(admitted) else {
                reservations.cancelPhysicalPublication(completion.reservation)
                return .superseded
            }
            writeTask = nil
            guard receipt.destination.canonicalURL == destination.canonicalURL,
                  receipt.priorObservation == expected,
                  receipt.publishedObservation.condition == .valid,
                  receipt.publishedObservation.location.canonicalURL
                    == destination.canonicalURL else {
                activeSave = nil
                reservations.cancelPhysicalPublication(completion.reservation)
                lastFailure = "document-publish-receipt-invalid"
                publishSnapshot()
                return .failed("document-publish-receipt-invalid")
            }

            switch reservations.completePhysicalPublication(
                completion.reservation,
                at: receipt.publishedObservation.location
            ) {
            case .completed:
                break
            case .alreadyOwned:
                return await reconcileFailedWrite(
                    WorkspaceDocumentSessionError.operationFailed(
                        "document-location-owned-by-another-window"
                    ),
                    expected: expected,
                    destination: destination,
                    admitted: admitted
                )
            case .invalid:
                return await reconcileFailedWrite(
                    WorkspaceDocumentSessionError.operationFailed(
                        "document-publication-reservation-invalid"
                    ),
                    expected: expected,
                    destination: destination,
                    admitted: admitted
                )
            }

            activeSave = nil
            if clearsDirty {
                source.acceptPublishedWrite(
                    capturedGeneration: payload.capturedMutationGeneration,
                    adopting: adoptedLocation
                )
                location = receipt.publishedObservation.location
                if adoptedLocation != nil {
                    replaceMonitorRegistration(at: receipt.publishedObservation.location)
                }
                expectedExternalVersion = receipt.publishedObservation
                savedMutationGeneration = payload.capturedMutationGeneration
                refreshFromSource(markCurrentAsSaved: false)
                conflict = nil
                lastFailure = nil
                writeIntentSucceeded = true
                publishSnapshot()
                return .saved(
                    clean: !hasUnsavedChanges,
                    adopted: adoptedLocation.map { _ in receipt.publishedObservation.location }
                )
            }

            writeIntentSucceeded = true
            publishSnapshot()
            return .copied(receipt.publishedObservation.location)
        } catch {
            guard isCurrent(admitted) else { return .superseded }
            writeTask = nil
            return await reconcileFailedWrite(
                error,
                expected: expected,
                destination: destination,
                admitted: admitted
            )
        }
    }

    private func reconcileFailedWrite(
        _ error: Error,
        expected: WorkspacePackageExternalVersion,
        destination: WorkspaceDocumentLocation,
        admitted: WorkspaceDocumentActiveSave
    ) async -> WorkspaceDocumentWriteOutcome {
        let observed: WorkspacePackageExternalVersion
        do {
            observed = try await observeForWriteIntent(destination.canonicalURL)
        } catch {
            guard isCurrent(admitted) else { return .superseded }
            activeSave = nil
            let failure = diagnostic(for: mappedSessionError(error))
            lastFailure = failure
            publishSnapshot()
            return .failed(failure)
        }
        guard isCurrent(admitted) else { return .superseded }
        activeSave = nil
        if observed != expected {
            let conflict = makeConflict(expected: expected, observed: observed)
            return publishWriteConflict(conflict, intent: admitted.intent)
        }
        let failure = diagnostic(for: mappedSessionError(error))
        lastFailure = failure
        publishSnapshot()
        return .failed(failure)
    }

    /// Canonical active location is authoritative even when the saved physical identity is
    /// absent or stale. Physical equality is an additional known-alias guard, never a reason
    /// to reinterpret a different canonical destination as the active package's conflict.
    private func isActiveCopyDestination(_ destination: WorkspaceDocumentLocation) -> Bool {
        guard let location else { return false }
        if destination.canonicalURL == location.canonicalURL { return true }
        guard let identity = location.fileObjectIdentity else { return false }
        return destination.fileObjectIdentity == identity
    }

    private func publishWriteConflict(
        _ conflict: WorkspaceDocumentConflict,
        intent: WorkspaceDocumentWriteIntent
    ) -> WorkspaceDocumentWriteOutcome {
        let destination: WorkspaceDocumentLocation?
        switch intent {
        case .saveAs(let location), .saveCopy(let location): destination = location
        default: destination = nil
        }
        if let destination, destination.canonicalURL != location?.canonicalURL {
            // Publish only the ended active-save state. Binding, baseline, dirty state and a
            // genuine conflict on the active package all belong to the original document.
            publishSnapshot()
            return .destinationConflicted(intent: intent, conflict: conflict)
        }
        self.conflict = conflict
        lastFailure = nil
        publishSnapshot()
        return .conflicted(conflict)
    }

    private func ownershipConflict(
        at destination: WorkspaceDocumentLocation,
        intent: WorkspaceDocumentWriteIntent
    ) async -> WorkspaceDocumentWriteOutcome {
        let epoch = lifecycleEpoch
        let closeRequest = windowClosePreparation
        let terminationID = terminationPreparationID
        let originalLocation = location
        let originalVersion = expectedExternalVersion
        let originalDocumentID = documentID
        let originalWorkspaceID = workspaceID
        func isCurrentIntent() -> Bool {
            if let closeRequest, !windowCloseRequestIsCurrent(closeRequest) { return false }
            if let terminationID, !terminationPreparationIsCurrent(terminationID) { return false }
            return !isClosed && lifecycleEpoch == epoch && writeIntentActive
                && location == originalLocation && expectedExternalVersion == originalVersion
                && documentID == originalDocumentID && workspaceID == originalWorkspaceID
                && !Task.isCancelled
        }
        let observed: WorkspacePackageExternalVersion
        do {
            observed = try await observeForWriteIntent(destination.canonicalURL)
        } catch {
            return isCurrentIntent() ? failCurrentIntent(error) : .superseded
        }
        guard isCurrentIntent() else { return .superseded }
        let conflict = WorkspaceDocumentConflict(
            expected: observed,
            observed: observed,
            reason: .destinationOwnedByAnotherWindow
        )
        return publishWriteConflict(conflict, intent: intent)
    }

    private func observeForWriteIntent(
        _ url: URL
    ) async throws -> WorkspacePackageExternalVersion {
        let task = Task { [io] in try await io.observe(url) }
        preflightTask = task
        defer { preflightTask = nil }
        return try await task.value
    }

    private func admitWriteIntent(
        allowingTermination: Bool = false,
        allowingWindowClose request: WorkspaceDocumentWindowCloseRequest? = nil
    ) -> Bool {
        guard !isClosed,
              (allowingTermination || !isTerminating),
              (request == nil && windowClosePreparation == nil)
                || (request != nil && windowClosePreparation == request),
              !writeIntentActive,
              activeSave == nil else { return false }
        // An explicit write may win admission before a scheduled drain runs. It takes over
        // that demand, so failure cannot leave an older task behind to retry automatically.
        if autosaveDrainTask != nil {
            autosaveDrainTask?.cancel()
            autosaveDrainTask = nil
            pendingAutosave = true
        }
        writeIntentSucceeded = false
        writeIntentActive = true
        return true
    }

    private func writeAdmissionFailure() -> WorkspaceDocumentWriteOutcome {
        if isClosed {
            return .failed("document-session-closed")
        }
        if isTerminating {
            return .failed("document-termination-in-progress")
        }
        if windowClosePreparation != nil {
            return .failed("document-close-in-progress")
        }
        return .failed("document-write-already-active")
    }

    private func finishWriteIntent(resumeReloadAutosave: Bool = false, probeMonitor: Bool = true) {
        let shouldDrainAutosave = pendingAutosave && (writeIntentSucceeded || resumeReloadAutosave)
        pendingAutosave = false
        writeIntentSucceeded = false
        writeIntentActive = false
        resumeTerminationWaitersIfQuiescent()
        guard !isClosed, !isTerminating, windowClosePreparation == nil else { return }
        monitorHintPendingForWrite = false
        if probeMonitor { scheduleAuthoritativeMonitorProbe() }
        guard shouldDrainAutosave, hasUnsavedChanges, conflict == nil else { return }
        autosaveDrainTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.autosaveDrainTask = nil
            _ = await self.autosaveIfNeeded()
        }
    }

    private func cancelPendingAutosave() {
        pendingAutosave = false
        autosaveDrainTask?.cancel()
        autosaveDrainTask = nil
    }

    private var hasInFlightWriteIntent: Bool {
        writeIntentActive
            || activeSave != nil
            || writeTask != nil
            || preflightTask != nil
            || reloadTask != nil
    }

    private func waitForWriteQuiescenceForTermination(
        preparationID: UUID
    ) async -> Bool {
        while hasInFlightWriteIntent && terminationPreparationIsCurrent(preparationID) {
            await withCheckedContinuation { continuation in
                if hasInFlightWriteIntent && terminationPreparationIsCurrent(preparationID) {
                    terminationQuiescenceWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
        return terminationPreparationIsCurrent(preparationID)
    }

    private func resumeTerminationWaitersIfQuiescent() {
        guard !hasInFlightWriteIntent else { return }
        resumeAllTerminationWaiters()
    }

    private func resumeAllTerminationWaiters() {
        let waiters = terminationQuiescenceWaiters
        terminationQuiescenceWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func terminationPreparationIsCurrent(_ preparationID: UUID) -> Bool {
        isTerminating
            && !isClosed
            && terminationPreparationID == preparationID
            && terminationCancellationRequestedID != preparationID
            && !Task.isCancelled
    }

    private func requestTerminationCancellation(_ preparationID: UUID) {
        guard isTerminating,
              !isClosed,
              terminationPreparationID == preparationID,
              terminationCancellationRequestedID != preparationID else { return }
        terminationCancellationRequestedID = preparationID
        writeTask?.cancel()
        preflightTask?.cancel()
        reloadTask?.cancel()
        resumeAllTerminationWaiters()
    }

    private func cancelDocumentMonitoring() {
        monitorTask?.cancel()
        monitorProbeTask?.cancel()
        monitorTask = nil
        monitorProbeTask = nil
        monitorProbeDemand = nil
        monitorHintPendingForWrite = false
        monitorEpoch &+= 1
    }

    private func isCurrent(_ admitted: WorkspaceDocumentActiveSave) -> Bool {
        !isClosed
            && activeSave?.requestID == admitted.requestID
            && activeSave?.saveGeneration == admitted.saveGeneration
    }

    private func refreshFromSource(markCurrentAsSaved: Bool) {
        guard let source else { return }
        documentID = source.documentID
        workspaceID = source.workspaceID
        mutationGeneration = source.mutationGeneration
        hasUnsavedChanges = source.hasUnsavedChanges
        if markCurrentAsSaved {
            savedMutationGeneration = source.mutationGeneration
        }
    }

    private func replaceMonitorRegistration(at location: WorkspaceDocumentLocation) {
        guard !isClosed, !isTerminating, windowClosePreparation == nil else {
            cancelDocumentMonitoring()
            return
        }
        monitorTask?.cancel()
        monitorProbeTask?.cancel()
        monitorProbeTask = nil
        monitorProbeDemand = nil
        monitorEpoch &+= 1
        let epoch = monitorEpoch
        monitorTask = Task { @MainActor [weak self, io] in
            let feed = await io.changes(at: location)
            guard self?.isClosed == false,
                  self?.isTerminating == false,
                  self?.monitorEpoch == epoch else { return }
            self?.monitorProbeDemand = feed.probeDemand
            for await _ in feed.stream {
                guard let self else { break }
                guard !Task.isCancelled,
                      !self.isClosed,
                      !self.isTerminating,
                      self.monitorEpoch == epoch else { break }
                self.handleMonitorHint(feed.probeDemand)
            }
        }
    }

    private func handleMonitorHint(_ probeDemand: WorkspaceDocumentProbeDemand) {
        guard !isClosed,
              !isTerminating,
              monitorProbeDemand === probeDemand else { return }
        if writeIntentActive || activeSave != nil {
            monitorHintPendingForWrite = true
            return
        }
        scheduleAuthoritativeMonitorProbe(probeDemand: probeDemand)
    }

    private func scheduleAuthoritativeMonitorProbe(
        probeDemand: WorkspaceDocumentProbeDemand? = nil
    ) {
        guard !isClosed,
              !isTerminating,
              let location,
              let expectedExternalVersion,
              let probeDemand = probeDemand ?? monitorProbeDemand,
              monitorProbeDemand === probeDemand else { return }
        guard monitorProbeTask == nil,
              let initialGeneration = probeDemand.beginNext() else { return }
        let epoch = monitorEpoch
        monitorProbeTask = Task { @MainActor [weak self, io] in
            guard let self else { return }
            var generation: UInt64? = initialGeneration
            while !Task.isCancelled, let currentGeneration = generation {
                let observed: WorkspacePackageExternalVersion
                do {
                    observed = try await io.observe(location.canonicalURL)
                } catch {
                    guard !Task.isCancelled,
                          !self.isClosed,
                          !self.isTerminating,
                          self.monitorEpoch == epoch else { break }
                    self.lastFailure = self.diagnostic(for: self.mappedSessionError(error))
                    self.publishSnapshot()
                    observed = expectedExternalVersion
                }

                guard !Task.isCancelled,
                      !self.isClosed,
                      !self.isTerminating,
                      self.monitorEpoch == epoch else { break }
                let mustRecheckAfterWrite = self.writeIntentActive || self.activeSave != nil
                if mustRecheckAfterWrite {
                    self.monitorHintPendingForWrite = true
                    probeDemand.admit()
                } else if observed != self.expectedExternalVersion {
                    let expected = self.expectedExternalVersion ?? expectedExternalVersion
                    self.conflict = self.makeConflict(expected: expected, observed: observed)
                    self.cancelPendingAutosave()
                    self.lastFailure = nil
                    self.publishSnapshot()
                }
                probeDemand.complete(currentGeneration)
                if mustRecheckAfterWrite { break }
                generation = probeDemand.beginNext()
            }
            guard !self.isTerminating,
                  self.monitorEpoch == epoch else { return }
            self.monitorProbeTask = nil
            if !self.writeIntentActive, self.activeSave == nil {
                self.scheduleAuthoritativeMonitorProbe(probeDemand: probeDemand)
            }
        }
    }

    private func makeConflict(
        expected: WorkspacePackageExternalVersion,
        observed: WorkspacePackageExternalVersion
    ) -> WorkspaceDocumentConflict {
        let reason: WorkspaceDocumentConflictReason
        switch observed.condition {
        case .valid:
            reason = .externallyChanged
        case .absent:
            reason = .destinationMissing
        case .invalid:
            reason = .destinationInvalid(
                boundedDiagnostic(observed.boundedReason ?? "package-invalid")
            )
        case .unverifiable:
            reason = .destinationUnverifiable(
                boundedDiagnostic(
                    observed.boundedReason ?? "package-state-unverifiable"
                )
            )
        }
        return WorkspaceDocumentConflict(
            expected: expected,
            observed: observed,
            reason: reason
        )
    }

    private func failCurrentIntent(_ error: Error) -> WorkspaceDocumentWriteOutcome {
        let failure = diagnostic(for: mappedSessionError(error))
        lastFailure = failure
        publishSnapshot()
        return .failed(failure)
    }

    /// Retains only closed categories; associated values can contain user paths or content.
    static func classifiedWriteError(_ error: Error, phase: String) -> WorkspaceDocumentSessionError {
        if let error = error as? WorkspaceDocumentSessionError { return error }
        let category: String
        if let error = error as? MacScopeDocumentPackage.PackageError {
            switch error {
            case .duplicateBinaryID: category = "package-duplicateBinaryID"
            case .duplicateImageSlot: category = "package-duplicateImageSlot"
            case .duplicateAssistantSessionID: category = "package-duplicateAssistantSessionID"
            case .duplicateAssistantSessionSequence: category = "package-duplicateAssistantSessionSequence"
            case .duplicateAssistantConversationTurn: category = "package-duplicateAssistantConversationTurn"
            case .duplicateAssistantInferenceTurnID: category = "package-duplicateAssistantInferenceTurnID"
            case .duplicateAssistantShellProposalID: category = "package-duplicateAssistantShellProposalID"
            case .duplicateAssistantShellExecutionID: category = "package-duplicateAssistantShellExecutionID"
            case .duplicateAssistantContinuationRequestID: category = "package-duplicateAssistantContinuationRequestID"
            case .invalidAssistantContinuationCheckpoint: category = "package-invalidAssistantContinuationCheckpoint"
            case .duplicateRuntimeAuthorityRecordID: category = "package-duplicateRuntimeAuthorityRecordID"
            case .duplicateImageAnalysisBinaryID: category = "package-duplicateImageAnalysisBinaryID"
            case .duplicateImageAnalysisSlot: category = "package-duplicateImageAnalysisSlot"
            case .imageAnalysisSlotMismatch: category = "package-imageAnalysisSlotMismatch"
            case .missingImageAnalysis: category = "package-missingImageAnalysis"
            case .unknownImageAnalysisBinaryID: category = "package-unknownImageAnalysisBinaryID"
            case .unknownAttachmentBinaryID: category = "package-unknownAttachmentBinaryID"
            case .attachmentHashMismatch: category = "package-attachmentHashMismatch"
            case .attachmentSizeMismatch: category = "package-attachmentSizeMismatch"
            case .invalidAttachmentHash: category = "package-invalidAttachmentHash"
            case .invalidArchiveMemberIdentity: category = "package-invalidArchiveMemberIdentity"
            case .archiveMemberAttachmentMismatch: category = "package-archiveMemberAttachmentMismatch"
            case .archiveMemberFingerprintMismatch: category = "package-archiveMemberFingerprintMismatch"
            case .binaryMetadataFingerprintMismatch: category = "package-binaryMetadataFingerprintMismatch"
            case .attachmentArtifactReconstructionFailed: category = "package-attachmentArtifactReconstructionFailed"
            case .emptyWorkspaceName: category = "package-emptyWorkspaceName"
            case .invalidAttachmentRelativePath: category = "package-invalidAttachmentRelativePath"
            case .invalidFormatIdentifier: category = "package-invalidFormatIdentifier"
            case .missingAttachment: category = "package-missingAttachment"
            case .invalidAssistantSessionProviderToolCount: category = "package-invalidAssistantSessionProviderToolCount"
            case .invalidAssistantSessionSchemaVersion: category = "package-invalidAssistantSessionSchemaVersion"
            case .invalidAssistantSessionContentHash: category = "package-invalidAssistantSessionContentHash"
            case .invalidRuntimeAuthorityRecord: category = "package-invalidRuntimeAuthorityRecord"
            case .invalidRuntimeAuthorityRecordSchemaVersion: category = "package-invalidRuntimeAuthorityRecordSchemaVersion"
            case .unsupportedFormatVersion: category = "package-unsupportedFormatVersion"
            case .version1ContainsImageAnalyses: category = "package-version1ContainsImageAnalyses"
            case .version2ImageAnalysisContainsAuthoring: category = "package-version2ImageAnalysisContainsAuthoring"
            case .version2TopLevelAnalysisContainsDerivedData: category = "package-version2TopLevelAnalysisContainsDerivedData"
            case .packagePublicationRollbackFailed: category = "package-packagePublicationRollbackFailed"
            case .packagePublicationCleanupOwnershipUnproven: category = "package-packagePublicationCleanupOwnershipUnproven"
            case .newerAnalyzerVersion: category = "package-newerAnalyzerVersion"
            }
        } else if let error = error as? DecodingError {
            switch error {
            case .dataCorrupted: category = "decode-data-corrupted"
            case .keyNotFound: category = "decode-key-not-found"
            case .typeMismatch: category = "decode-type-mismatch"
            case .valueNotFound: category = "decode-value-not-found"
            @unknown default: category = "decode-other"
            }
        } else if error is EncodingError {
            category = "encode-invalid-value"
        } else if error is CancellationError {
            category = "cancelled"
        } else {
            let bridged = error as NSError
            switch bridged.domain {
            case NSCocoaErrorDomain: category = "cocoa-\(bridged.code)"
            case NSPOSIXErrorDomain: category = "posix-\(bridged.code)"
            default: category = "other"
            }
        }
        return .operationFailed("document-write-\(phase)-\(category)")
    }

    private func mappedSessionError(_ error: Error) -> WorkspaceDocumentSessionError {
        if let error = error as? WorkspaceDocumentSessionError { return error }
        if error is CancellationError { return .operationFailed("document-operation-cancelled") }
        return .operationFailed("document-operation-failed")
    }

    private func diagnostic(for error: WorkspaceDocumentSessionError) -> String {
        switch error {
        case .closed:
            return "document-session-closed"
        case .noActiveLocation:
            return "document-location-unavailable"
        case .writeAlreadyActive:
            return "document-write-already-active"
        case .unresolvedConflict:
            return "document-conflict-unresolved"
        case .invalidResolution(let reason), .operationFailed(let reason):
            return boundedDiagnostic(reason)
        }
    }

    private func boundedDiagnostic(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let replacement: String
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-" || scalar == "_" || scalar == "." || scalar == " " {
                replacement = String(scalar)
            } else {
                replacement = "?"
            }
            guard (result + replacement).utf8.count <= 256 else { break }
            result += replacement
        }
        return result.isEmpty ? "document-operation-failed" : result
    }

    private func publishSnapshot() {
        snapshot = WorkspaceDocumentSessionSnapshot(
            sessionID: sessionID,
            documentID: documentID,
            workspaceID: workspaceID,
            location: location,
            expectedExternalVersion: expectedExternalVersion,
            mutationGeneration: mutationGeneration,
            savedMutationGeneration: savedMutationGeneration,
            hasUnsavedChanges: hasUnsavedChanges,
            nextSaveGeneration: nextSaveGeneration,
            activeSave: activeSave,
            conflict: conflict,
            lastFailure: lastFailure
        )
    }
}

/// A cancelled/timed-out close stops waiting without cancelling an already-admitted atomic
/// write. The retained document session remains that write's owner. Its eventual completion
/// cannot mint a close permit because the caller revokes the request on every non-admitted exit.
@MainActor
private final class WorkspaceDocumentCloseWaiter<Value: Sendable> {
    enum Outcome: Sendable {
        case completed(Value)
        case cancelled
        case timedOut
    }

    private var continuation: CheckedContinuation<Outcome, Never>?
    private var result: Outcome?
    private var deadline: Task<Void, Never>?

    static func wait(for task: Task<Value, Never>, timeout: Duration) async -> Outcome {
        let waiter = WorkspaceDocumentCloseWaiter<Value>()
        return await withTaskCancellationHandler {
            if Task.isCancelled { return .cancelled }
            return await waiter.waitForCompletion(of: task, timeout: timeout)
        } onCancel: {
            Task { @MainActor in waiter.resolve(.cancelled) }
        }
    }

    private func waitForCompletion(of task: Task<Value, Never>, timeout: Duration) async -> Outcome {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.resolve(.timedOut)
            }
            Task { @MainActor [weak self] in
                let value = await task.value
                self?.resolve(.completed(value))
            }
        }
    }

    private func resolve(_ outcome: Outcome) {
        guard result == nil else { return }
        result = outcome
        deadline?.cancel()
        deadline = nil
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}
