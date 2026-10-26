import Foundation

/// The identity of one document WINDOW (WS-2 per-document sessions). A value key for
/// `WindowGroup(for:)`: SwiftUI hands each window its `WorkspaceWindowID`, and the
/// `WorkspaceSessionRegistry` maps it to that window's own `WorkspaceStore`. The cold-launch
/// window carries no value (SwiftUI presents `nil`) and maps to `.primary` — exactly the one
/// store the app has always had, so single-window behavior is unchanged.
struct WorkspaceWindowID: Hashable, Codable, Sendable {
    let raw: UUID

    /// The cold-launch window's identity. A fixed UUID (not random) so the primary window's
    /// store lookup is stable across scene restorations within a process.
    static let primary = WorkspaceWindowID(raw: UUID(uuidString: "00000000-0000-0000-0000-4D6163530001")!)

    /// A fresh identity for a newly spawned document window (WS-2 Stage 3).
    static func fresh() -> WorkspaceWindowID { WorkspaceWindowID(raw: UUID()) }
}

/// Owns one `WorkspaceStore` per document window (WS-2). Replaces the single App-level
/// `@StateObject` store — the invisible-sharing trap where every window of a `WindowGroup`
/// would share one document. `stores` is deliberately NOT `@Published`: the registry is a
/// stable owner resolved during view construction, and publishing it would re-render every
/// window whenever any window opens or closes.
@MainActor
final class WorkspaceSessionRegistry: ObservableObject {
    var terminationChoice: (@MainActor (WorkspaceWindowID, WorkspaceDocumentSessionSnapshot) async -> WorkspaceDocumentTerminationChoice)?
    var terminationSaveDestination: (@MainActor (WorkspaceWindowID) async -> URL?)?
    typealias TerminationAuthorityDrain = @MainActor (WorkspaceStore) async -> Void
    typealias TerminationRetirementObserver = @MainActor (
        WorkspaceWindowID,
        WorkspaceStore,
        WorkspaceDocumentSession
    ) -> Void

    private struct WorkspaceWindowSessionEntry {
        let store: WorkspaceStore
        let documentSession: WorkspaceDocumentSession
        var reconstructionRuntime: ReconstructionWorkspaceRuntime?
    }

    private struct CapturedTerminationEntry {
        let id: WorkspaceWindowID
        let store: WorkspaceStore
        let documentSession: WorkspaceDocumentSession
        let reconstructionRuntime: ReconstructionWorkspaceRuntime?
    }

    private enum TerminationState: Equatable {
        case accepting
        case preparing(UUID)
        case committing(UUID)
        case terminated
    }

    private struct TerminationTransaction {
        let token: UUID
        let task: Task<Bool, Never>
        var deadlineTask: Task<Void, Never>?
    }

    private struct ReconstructionRuntimeRetirement {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var entries: [WorkspaceWindowID: WorkspaceWindowSessionEntry] = [:]
    private var nativeDecompilerPresentations:
        [WorkspaceWindowID: NativeDecompilerPresentationModel] = [:]
    private let nativeDecompilerSessions: (any NativeDecompilerSessionProviding)?
    private var reconstructionRuntimeFactory: ReconstructionWorkspaceRuntimeFactory?
    private var reconstructionFactoryInstallationTask: Task<Void, Never>?
    private var reconstructionFactoryInstallationStarted = false
    // Publish only accepted startup readiness, never teardown from a view lifecycle callback.
    @Published private var reconstructionFactoryDidInstall = false

    var isReconstructionRuntimeFactoryInstalled: Bool {
        canAdmitReconstructionRuntime && reconstructionFactoryDidInstall
    }
    private var reconstructionRuntimeRetirements:
        [WorkspaceWindowID: ReconstructionRuntimeRetirement] = [:]
    private let fallbackDocumentReservations = WorkspaceUnownedDocumentReservations()
    private var documentSessionFactory:
        (@MainActor (WorkspaceWindowID, WorkspaceStore) -> WorkspaceDocumentSession?)?
    private let terminationPreparationDeadline: Duration?
    private let terminationAuthorityDrain: TerminationAuthorityDrain
    private let terminationRetirementObserver: TerminationRetirementObserver
    private var terminationState = TerminationState.accepting
    private var terminationTransaction: TerminationTransaction?
    /// A UUID is used instead of a wrapping counter so exhaustion can never make two registry
    /// generations compare equal. Every entry-authority mutation replaces it synchronously.
    private var entryAuthorityGeneration = UUID()
    /// A binary URL a freshly-spawned window should import once it appears (WS-2 Stage 3). The
    /// file picker runs in the ORIGINATING window; the chosen binary is then imported in the NEW
    /// window so its slice picker / progress belong to that document. Consumed once, on appear.
    private var pendingBinaryOpen: [WorkspaceWindowID: URL] = [:]

    init(
        nativeDecompilerSessions: (any NativeDecompilerSessionProviding)? = nil,
        reconstructionRuntimeFactory: ReconstructionWorkspaceRuntimeFactory? = nil,
        terminationPreparationDeadline: Duration? = .seconds(30),
        terminationAuthorityDrain: TerminationAuthorityDrain? = nil,
        terminationRetirementObserver: @escaping TerminationRetirementObserver = { _, _, _ in }
    ) {
        self.nativeDecompilerSessions = nativeDecompilerSessions
        self.reconstructionRuntimeFactory = reconstructionRuntimeFactory
        reconstructionFactoryInstallationStarted = reconstructionRuntimeFactory != nil
        reconstructionFactoryDidInstall = reconstructionRuntimeFactory != nil
        self.terminationPreparationDeadline = terminationPreparationDeadline
        self.terminationAuthorityDrain = terminationAuthorityDrain ?? { store in
            // These are the store's existing retained task seams. Waiting here is reversible:
            // no document, native, or reconstruction authority has been retired yet.
            await store.awaitPendingImport()
            await store.awaitPendingReanalysis()
            await store.awaitPendingDyldCacheDifferential()
            await store.phase2ShellRecoveryTask?.value
        }
        self.terminationRetirementObserver = terminationRetirementObserver
    }

    /// One app-owned installation task, never a per-window validation. Pending or rejected
    /// resolution leaves the nil factory as the activation and command boundary.
    func installReconstructionRuntimeFactoryIfNeeded(
        using resolver: @escaping @MainActor @Sendable () async
            -> ReconstructionWorkspaceRuntimeFactory?
    ) {
        guard canAdmitReconstructionRuntime, !reconstructionFactoryInstallationStarted else {
            return
        }
        reconstructionFactoryInstallationStarted = true
        reconstructionFactoryInstallationTask = Task { @MainActor [weak self] in
            let factory = await resolver()
            guard let self else { return }
            self.reconstructionFactoryInstallationTask = nil
            guard !Task.isCancelled, let factory,
                  self.beginEntryAuthorityMutation() else { return }
            // Late readiness can admit runtimes into existing entries. Invalidate a reversible
            // termination preparation before exposing that new authority; commit rejects it.
            self.reconstructionRuntimeFactory = factory
            self.reconstructionFactoryDidInstall = true
        }
    }

    private var canAdmitReconstructionRuntime: Bool {
        switch terminationState {
        case .accepting, .preparing: true
        case .committing, .terminated: false
        }
    }

    @discardableResult
    func setPendingBinaryOpen(_ url: URL, for id: WorkspaceWindowID) -> Bool {
        guard beginEntryAuthorityMutation() else { return false }
        pendingBinaryOpen[id] = url
        return true
    }

    /// Returns and clears the pending binary import for a window (nil when none).
    func takePendingBinaryOpen(for id: WorkspaceWindowID) -> URL? {
        guard let pending = pendingBinaryOpen[id] else { return nil }
        guard beginEntryAuthorityMutation() else { return nil }
        pendingBinaryOpen[id] = nil
        return pending
    }

    /// The store for a window, creating it on first resolution. The primary window bootstraps
    /// from the launch configuration (argv/env: preview fixture, editor mode, window frame) —
    /// byte-identical to the old single-store init. A non-primary window without an adopted
    /// store gets an empty workspace; Stage 3's spawn-on-open paths `adopt(_:for:)` a store
    /// built from the chosen URL *before* opening the window, so that fallback is only
    /// reachable via scene restoration of a window whose store is gone.
    func store(
        for id: WorkspaceWindowID,
        launchConfiguration: WorkspaceLaunchConfiguration
    ) -> WorkspaceStore {
        resolveEntry(for: id, launchConfiguration: launchConfiguration).store
    }

    /// The document-lifecycle authority paired with this window's store. Resolving either half
    /// creates the same stable entry, so a session cannot accidentally bind to a different store
    /// than the one rendered by the window.
    func documentSession(
        for id: WorkspaceWindowID,
        launchConfiguration: WorkspaceLaunchConfiguration
    ) -> WorkspaceDocumentSession {
        resolveEntry(for: id, launchConfiguration: launchConfiguration).documentSession
    }

    func storeIfPresent(for id: WorkspaceWindowID) -> WorkspaceStore? {
        entries[id]?.store
    }

    func documentSessionIfPresent(
        for id: WorkspaceWindowID
    ) -> WorkspaceDocumentSession? {
        entries[id]?.documentSession
    }

    /// Resolves the lightweight Reconstruction owner for this exact Store lifecycle. A same-ID
    /// restore invalidates the opaque publication authority, so the stale runtime is synchronously
    /// closed to new commands and its replacement inherits an async predecessor-retirement
    /// barrier. Missing production composition deliberately returns nil.
    func reconstructionRuntime(
        for id: WorkspaceWindowID,
        launchConfiguration: WorkspaceLaunchConfiguration
    ) -> ReconstructionWorkspaceRuntime? {
        guard canAdmitReconstructionRuntime else { return nil }
        let entry = resolveEntry(for: id, launchConfiguration: launchConfiguration)
        if let runtime = entry.reconstructionRuntime,
           runtime.isCurrent(
               for: entry.store,
               documentSession: entry.documentSession
           ) {
            return runtime
        }
        guard let reconstructionRuntimeFactory else { return nil }
        guard beginEntryAuthorityMutation() else { return nil }

        if let stale = entry.reconstructionRuntime {
            beginReconstructionRuntimeRetirement(stale, for: id)
        }
        let replacement = reconstructionRuntimeFactory(
            id,
            entry.store,
            entry.documentSession,
            reconstructionRuntimeRetirements[id]?.task
        )
        entries[id]?.reconstructionRuntime = replacement
        return replacement
    }

    func reconstructionRuntimeIfPresent(
        for id: WorkspaceWindowID
    ) -> ReconstructionWorkspaceRuntime? {
        guard canAdmitReconstructionRuntime, let entry = entries[id],
              let runtime = entry.reconstructionRuntime,
              runtime.isCurrent(
                  for: entry.store,
                  documentSession: entry.documentSession
              ) else { return nil }
        return runtime
    }

    /// Installs the process document authority before production windows resolve their entries.
    /// Tests and headless compatibility callers that do not compose a coordinator retain the
    /// deliberately unowned fallback session.
    func installDocumentSessionFactory(
        _ factory: @escaping @MainActor (
            WorkspaceWindowID,
            WorkspaceStore
        ) -> WorkspaceDocumentSession?
    ) {
        documentSessionFactory = factory
    }

    private func resolveEntry(
        for id: WorkspaceWindowID,
        launchConfiguration: WorkspaceLaunchConfiguration
    ) -> WorkspaceWindowSessionEntry {
        if let existing = entries[id] { return existing }
        guard beginEntryAuthorityMutation() else {
            preconditionFailure("workspace entry admission after termination commit")
        }
        let store = id == .primary
            ? WorkspaceStore.bootstrap(launchConfiguration: launchConfiguration)
            : WorkspaceStore.bootstrap()
        let documentSession = makeDocumentSession(for: id, store: store)
        bindNativeDecompilerSession(to: store, owner: id)
        let entry = WorkspaceWindowSessionEntry(
            store: store,
            documentSession: documentSession,
            reconstructionRuntime: reconstructionRuntimeFactory?(
                id,
                store,
                documentSession,
                reconstructionRuntimeRetirements[id]?.task
            )
        )
        entries[id] = entry
        return entry
    }

    /// Returns the one transient native-decompiler presentation model owned by this document
    /// window. It is intentionally separate from `WorkspaceStore` and `WorkspaceSnapshot`, so
    /// native output can never become persisted analysis authority accidentally.
    func nativeDecompilerPresentation(
        for id: WorkspaceWindowID
    ) -> NativeDecompilerPresentationModel {
        if let existing = nativeDecompilerPresentations[id] { return existing }
        guard beginEntryAuthorityMutation() else {
            preconditionFailure("native presentation admission after termination commit")
        }
        let presentation = NativeDecompilerPresentationModel()
        nativeDecompilerPresentations[id] = presentation
        return presentation
    }

    /// Registers a store for a window BEFORE the window opens (the spawn-on-open path:
    /// build the store from the chosen binary/package, adopt it, then `openWindow(value:)`).
    func adopt(_ store: WorkspaceStore, for id: WorkspaceWindowID) {
        guard beginEntryAuthorityMutation() else {
            store.terminateNativeDecompilerSession()
            return
        }
        removeEntry(for: id)
        let documentSession = makeDocumentSession(for: id, store: store)
        bindNativeDecompilerSession(to: store, owner: id)
        entries[id] = WorkspaceWindowSessionEntry(
            store: store,
            documentSession: documentSession,
            reconstructionRuntime: reconstructionRuntimeFactory?(
                id,
                store,
                documentSession,
                reconstructionRuntimeRetirements[id]?.task
            )
        )
    }

    /// Atomically adopts the content and document authorities prepared by the open coordinator.
    /// A stale scene callback therefore cannot observe a new store with a prior session's
    /// reservation or filesystem monitor.
    func adopt(
        _ store: WorkspaceStore,
        documentSession: WorkspaceDocumentSession,
        for id: WorkspaceWindowID
    ) {
        if let current = entries[id],
           current.store === store,
           current.documentSession === documentSession {
            return
        }
        guard beginEntryAuthorityMutation() else {
            documentSession.close()
            store.terminateNativeDecompilerSession()
            return
        }
        removeEntry(for: id)
        store.bindDocumentSessionMutationObserver(documentSession)
        bindNativeDecompilerSession(to: store, owner: id)
        entries[id] = WorkspaceWindowSessionEntry(
            store: store,
            documentSession: documentSession,
            reconstructionRuntime: reconstructionRuntimeFactory?(
                id,
                store,
                documentSession,
                reconstructionRuntimeRetirements[id]?.task
            )
        )
    }

    /// Releases a closed window's store so closed documents do not accumulate. Wired to
    /// `NSWindow.willCloseNotification` by `WindowLifecycleReader`.
    func evict(_ id: WorkspaceWindowID) {
        guard entries[id] != nil else { return }
        guard beginEntryAuthorityMutation() else { return }
        removeEntry(for: id)
    }

    /// App termination first gives every still-open document a termination-only persistence
    /// chance before removing its session. This is deliberately different from ordinary window
    /// eviction: `close()` remains prompt-cancelling for a disappearing window, whereas process
    /// termination must not throw away an already-admitted atomic publication or dirty state.
    /// Native decision callbacks resolve untitled destinations and conflicts through the same
    /// version-checked session writer. Headless callers without callbacks remain fail-closed.
    @discardableResult
    func shutdown() async -> Bool {
        if terminationState == .terminated { return true }
        let transaction = terminationTransaction ?? startTerminationTransaction()
        return await withTaskCancellationHandler {
            let result = await transaction.task.value
            finishTerminationTransaction(transaction.token, result: result)
            return result
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelTerminationTransaction(transaction.token)
            }
        }
    }

    private func startTerminationTransaction() -> TerminationTransaction {
        precondition(terminationState == .accepting)
        let token = UUID()
        terminationState = .preparing(token)
        let task = Task { @MainActor [weak self] in
            await self?.performTerminationTransaction(token) ?? false
        }
        var transaction = TerminationTransaction(
            token: token,
            task: task,
            deadlineTask: nil
        )
        terminationTransaction = transaction
        if let terminationPreparationDeadline {
            let deadlineTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: terminationPreparationDeadline)
                } catch {
                    return
                }
                self?.cancelTerminationTransaction(token)
            }
            transaction.deadlineTask = deadlineTask
            terminationTransaction = transaction
        }
        return transaction
    }

    private func performTerminationTransaction(_ token: UUID) async -> Bool {
        let capturedGeneration = entryAuthorityGeneration
        var preparedSessions: [ObjectIdentifier: WorkspaceDocumentSession] = [:]

        while true {
            guard terminationState == .preparing(token),
                  !Task.isCancelled,
                  entryAuthorityGeneration == capturedGeneration else {
                rollbackTerminationPreparation(preparedSessions.values, token: token)
                return false
            }

            let captured = capturedTerminationEntries()
            for capturedEntry in captured {
                guard terminationEntryIsCurrent(capturedEntry, generation: capturedGeneration),
                      terminationState == .preparing(token),
                      !Task.isCancelled else {
                    rollbackTerminationPreparation(preparedSessions.values, token: token)
                    return false
                }

                let session = capturedEntry.documentSession
                session.beginTerminationPreparation()
                preparedSessions[ObjectIdentifier(session)] = session

                let drained = await awaitReversibleAuthorityDrain(
                    capturedEntry.store
                )
                guard drained,
                      terminationEntryIsCurrent(capturedEntry, generation: capturedGeneration),
                      terminationState == .preparing(token),
                      !Task.isCancelled else {
                    rollbackTerminationPreparation(preparedSessions.values, token: token)
                    return false
                }

                let chooseForSession: (@MainActor (WorkspaceDocumentSessionSnapshot) async
                    -> WorkspaceDocumentTerminationChoice)?
                if let choose = terminationChoice {
                    chooseForSession = { @MainActor snapshot in
                        await self.awaitTerminationDecision(token) {
                            await choose(capturedEntry.id, snapshot)
                        }
                    }
                } else {
                    chooseForSession = nil
                }
                let chooseDestinationForSession: @MainActor () async -> URL? = { [weak self] in
                    guard let self else { return nil }
                    return await self.awaitTerminationDecision(token) {
                        await self.terminationSaveDestination?(capturedEntry.id)
                    }
                }
                let preparation = await session.quiesceAndSaveForTermination(
                    choose: chooseForSession,
                    chooseSaveDestination: chooseDestinationForSession
                )
                guard terminationEntryIsCurrent(capturedEntry, generation: capturedGeneration),
                      terminationState == .preparing(token),
                      !Task.isCancelled else {
                    rollbackTerminationPreparation(preparedSessions.values, token: token)
                    return false
                }
                guard case .ready = preparation else {
                    rollbackTerminationPreparation(preparedSessions.values, token: token)
                    return false
                }
            }

            // This proof and the state transition to `.committing` are one main-actor turn.
            // Once committed, every entry-mutating API rejects/no-ops, so no suspension can
            // admit, replace, or evict authority before exact retirement begins.
            let current = capturedTerminationEntries()
            guard entryAuthorityGeneration == capturedGeneration,
                  sameTerminationEntryIdentities(captured, current) else {
                rollbackTerminationPreparation(preparedSessions.values, token: token)
                return false
            }
            guard current.allSatisfy({ entry in
                entry.documentSession.isReadyForTerminationRemoval()
                    && !entry.store.isImporting
                    && !entry.store.isReanalyzing
            }) else {
                continue
            }

            terminationState = .committing(token)
            terminationTransaction?.deadlineTask?.cancel()
            return await commitTermination(current, token: token)
        }
    }

    private func capturedTerminationEntries() -> [CapturedTerminationEntry] {
        entries.map { id, entry in
            CapturedTerminationEntry(
                id: id,
                store: entry.store,
                documentSession: entry.documentSession,
                reconstructionRuntime: entry.reconstructionRuntime
            )
        }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
    }

    private func sameTerminationEntryIdentities(
        _ lhs: [CapturedTerminationEntry],
        _ rhs: [CapturedTerminationEntry]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id
                && left.store === right.store
                && left.documentSession === right.documentSession
                && left.reconstructionRuntime === right.reconstructionRuntime
        }
    }

    private func terminationEntryIsCurrent(
        _ captured: CapturedTerminationEntry,
        generation: UUID
    ) -> Bool {
        guard entryAuthorityGeneration == generation,
              let current = entries[captured.id] else { return false }
        return current.store === captured.store
            && current.documentSession === captured.documentSession
            && current.reconstructionRuntime === captured.reconstructionRuntime
    }

    private func rollbackTerminationPreparation<S: Sequence>(
        _ prepared: S,
        token: UUID?
    ) where S.Element == WorkspaceDocumentSession {
        var sessionsByIdentity: [ObjectIdentifier: WorkspaceDocumentSession] = [:]
        for session in prepared {
            sessionsByIdentity[ObjectIdentifier(session)] = session
        }
        for entry in entries.values {
            let session = entry.documentSession
            sessionsByIdentity[ObjectIdentifier(session)] = session
        }
        for session in sessionsByIdentity.values {
            session.cancelTerminationPreparation()
        }
        if let token, terminationState == .preparing(token) {
            terminationState = .accepting
        }
    }

    private func awaitReversibleAuthorityDrain(_ store: WorkspaceStore) async -> Bool {
        let drain = terminationAuthorityDrain
        let task = Task { @MainActor in await drain(store) }
        return await WorkspaceTerminationDrainWaiter.wait(for: task)
    }

    private func commitTermination(
        _ captured: [CapturedTerminationEntry],
        token: UUID
    ) async -> Bool {
        precondition(terminationState == .committing(token))

        // Commit the installation fence only after reversible preparation has succeeded.
        // A veto/cancellation leaves the pending validator available to the still-running app.
        reconstructionFactoryInstallationTask?.cancel()
        reconstructionFactoryInstallationTask = nil
        reconstructionRuntimeFactory = nil

        for capturedEntry in captured {
            guard terminationEntryIsCurrent(capturedEntry, generation: entryAuthorityGeneration)
            else {
                preconditionFailure("workspace entry identity changed after termination commit")
            }
            if let runtime = capturedEntry.reconstructionRuntime {
                beginReconstructionRuntimeRetirement(runtime, for: capturedEntry.id)
            }
            capturedEntry.documentSession.close()
            capturedEntry.store.terminateNativeDecompilerSession()
            terminationRetirementObserver(
                capturedEntry.id,
                capturedEntry.store,
                capturedEntry.documentSession
            )
        }

        let retirements = reconstructionRuntimeRetirements.values.map(\.task)
        for capturedEntry in captured {
            await capturedEntry.store.awaitDebuggerPresentationRetirement()
        }
        for retirement in retirements {
            await retirement.value
        }

        // Remove only the exact generations proven and retired above. No mutating API can run
        // while `.committing`, and the process-global native runtime drains immediately after
        // this registry transaction returns to the application lifecycle coordinator.
        for capturedEntry in captured {
            guard let current = entries[capturedEntry.id],
                  current.store === capturedEntry.store,
                  current.documentSession === capturedEntry.documentSession else {
                preconditionFailure("workspace entry disappeared during termination commit")
            }
            entries.removeValue(forKey: capturedEntry.id)
            nativeDecompilerPresentations.removeValue(forKey: capturedEntry.id)
            pendingBinaryOpen.removeValue(forKey: capturedEntry.id)
        }
        terminationState = .terminated
        return true
    }

    private func cancelTerminationTransaction(_ token: UUID) {
        guard terminationState == .preparing(token),
              terminationTransaction?.token == token else { return }
        terminationTransaction?.task.cancel()
    }

    /// Human decisions have no IO deadline. Resume the bounded transaction when the sheet ends.
    private func awaitTerminationDecision<Value>(
        _ token: UUID,
        decision: @MainActor () async -> Value
    ) async -> Value {
        terminationTransaction?.deadlineTask?.cancel()
        let result = await decision()
        if terminationState == .preparing(token), !Task.isCancelled,
           let deadline = terminationPreparationDeadline {
            terminationTransaction?.deadlineTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: deadline) } catch { return }
                self?.cancelTerminationTransaction(token)
            }
        }
        return result
    }

    private func finishTerminationTransaction(_ token: UUID, result: Bool) {
        guard terminationTransaction?.token == token else { return }
        terminationTransaction?.deadlineTask?.cancel()
        terminationTransaction = nil
        if result {
            precondition(terminationState == .terminated)
        } else if case .preparing(token) = terminationState {
            rollbackTerminationPreparation(entries.values.map(\.documentSession), token: token)
        }
    }

    private func beginEntryAuthorityMutation() -> Bool {
        switch terminationState {
        case .accepting:
            entryAuthorityGeneration = UUID()
            return true
        case .preparing(let token):
            entryAuthorityGeneration = UUID()
            cancelTerminationTransaction(token)
            return true
        case .committing, .terminated:
            return false
        }
    }

    /// A preferred window may be reused only when replacement cannot discard content, an
    /// in-flight write, a conflict decision, or active analysis/import work.
    func isReusableDocumentWindow(_ id: WorkspaceWindowID) -> Bool {
        guard let entry = entries[id] else { return false }
        let document = entry.documentSession.snapshot
        return document.location == nil
            && !document.hasUnsavedChanges
            && document.activeSave == nil
            && document.conflict == nil
            && entry.store.snapshot.binaries.isEmpty
            && !entry.store.isImporting
            && !entry.store.isReanalyzing
            && entry.store.loaderOptionsRequest == nil
            && (entry.store.binaryOpenState?.phase.isTerminal ?? true)
    }

    /// Read-only lookup for an external document event delivered to the key workspace.
    func storeForWindow(identity: ObjectIdentifier, resolve: (WorkspaceWindowID) -> ObjectIdentifier?) -> WorkspaceStore? {
        let matches = entries.filter { resolve($0.key) == identity }
        guard matches.count == 1 else { return nil }
        return matches.first?.value.store
    }

    var count: Int { entries.count }

    func windowID(for store: WorkspaceStore) -> WorkspaceWindowID? {
        entries.first { $0.value.store === store }?.key
    }

    /// A monotonically increasing placement index so the FIRST window takes the explicit launch
    /// frame and each later window cascades off it (instead of all stacking on the same rect).
    private var windowPlacementCount = 0
    func nextWindowPlacementIndex() -> Int {
        defer { windowPlacementCount += 1 }
        return windowPlacementCount
    }

    private func bindNativeDecompilerSession(
        to store: WorkspaceStore,
        owner: WorkspaceWindowID
    ) {
        guard let nativeDecompilerSessions else { return }
        store.bindNativeDecompilerSession(
            nativeDecompilerSessions.makeWorkspaceSession(
                windowID: owner,
                presentation: nativeDecompilerPresentation(for: owner)
            )
        )
    }

    private func makeDocumentSession(
        for id: WorkspaceWindowID,
        store: WorkspaceStore
    ) -> WorkspaceDocumentSession {
        if let session = documentSessionFactory?(id, store) {
            return session
        }
        return WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: id,
            source: store,
            io: WorkspaceDocumentIO(),
            reservations: fallbackDocumentReservations
        )
    }

    private func removeEntry(for id: WorkspaceWindowID) {
        // Window IDs may be restored or deliberately reused. Transient evidence and one-shot
        // import intent belong to the exact retiring entry generation, never to the ID alone.
        nativeDecompilerPresentations.removeValue(forKey: id)
        pendingBinaryOpen.removeValue(forKey: id)
        guard let prior = entries.removeValue(forKey: id) else { return }
        if let runtime = prior.reconstructionRuntime {
            beginReconstructionRuntimeRetirement(runtime, for: id)
        }
        prior.documentSession.close()
        prior.store.terminateNativeDecompilerSession()
    }

    private func beginReconstructionRuntimeRetirement(
        _ runtime: ReconstructionWorkspaceRuntime,
        for id: WorkspaceWindowID
    ) {
        let predecessor = reconstructionRuntimeRetirements[id]?.task
        let current = runtime.beginRetirement()
        let token = UUID()
        let retirement = ReconstructionRuntimeRetirement(
            token: token,
            task: Task {
                await predecessor?.value
                await current.value
            }
        )
        reconstructionRuntimeRetirements[id] = retirement
        Task { [weak self] in
            await retirement.task.value
            guard self?.reconstructionRuntimeRetirements[id]?.token == token else { return }
            self?.reconstructionRuntimeRetirements[id] = nil
        }
    }
}

/// Cancellation-aware wait over a reversible authority drain. The drain itself is await-only and
/// may continue observing a store task after Quit is cancelled; this waiter returns immediately
/// to the registry so it can remove every document termination fence before replying `false`.
@MainActor
private final class WorkspaceTerminationDrainWaiter {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    static func wait(for task: Task<Void, Never>) async -> Bool {
        let waiter = WorkspaceTerminationDrainWaiter()
        return await withTaskCancellationHandler {
            await waiter.waitForCompletion(of: task)
        } onCancel: {
            Task { @MainActor in waiter.resolve(false) }
        }
    }

    private func waitForCompletion(of task: Task<Void, Never>) async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            if let result {
                continuation.resume(returning: result)
                return
            }
            self.continuation = continuation
            Task { @MainActor [weak self] in
                await task.value
                self?.resolve(true)
            }
        }
    }

    private func resolve(_ result: Bool) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// Compatibility authority for registry entries created before the process-wide document
/// runtime resolves them. Untitled sessions have no location to reserve; a coordinator-created
/// session replaces this one before a package is exposed.
@MainActor
private final class WorkspaceUnownedDocumentReservations:
    WorkspaceDocumentLocationReserving {
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
