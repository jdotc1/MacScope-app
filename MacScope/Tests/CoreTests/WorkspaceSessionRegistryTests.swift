import XCTest
@testable import MacScope

/// WS-2 Stage 2: one `WorkspaceStore` per document window, owned by the registry. These pin the
/// isolation property the multi-document flip (Stage 3) stands on: distinct windows must never
/// share a store, and the cold-launch (.primary) resolution must be stable.
@MainActor
final class WorkspaceSessionRegistryTests: XCTestCase {
    func testStoreForIDCreatesOnceAndIsStable() {
        let registry = WorkspaceSessionRegistry()
        let first = registry.store(for: .primary, launchConfiguration: WorkspaceLaunchConfiguration())
        let second = registry.store(for: .primary, launchConfiguration: WorkspaceLaunchConfiguration())
        XCTAssertTrue(first === second, "resolving the same window twice must return the same store")
        XCTAssertEqual(registry.count, 1)
    }

    /// The isolation RED-anchor: distinct window ids must resolve DISTINCT stores. (A registry
    /// that handed every window one shared store — today's App-level @StateObject behavior —
    /// fails this before any UI can even open a second window.)
    func testDistinctWindowsResolveDistinctStores() {
        let registry = WorkspaceSessionRegistry()
        let a = registry.store(for: .fresh(), launchConfiguration: WorkspaceLaunchConfiguration())
        let b = registry.store(for: .fresh(), launchConfiguration: WorkspaceLaunchConfiguration())
        XCTAssertFalse(a === b, "two windows must never share a document store")
        XCTAssertEqual(registry.count, 2)

        // Isolation is real: a mutation in A is invisible in B.
        a.snapshot.bookmarks.append(Bookmark(address: 0x1000, name: "only in A"))
        XCTAssertTrue(b.snapshot.bookmarks.isEmpty, "a bookmark added in window A must not appear in window B")
    }

    func testAdoptRegistersTheSpawnStoreAndEvictReleasesIt() {
        let registry = WorkspaceSessionRegistry()
        let spawned = WorkspaceStore(workspaceName: "Spawned",
                                     snapshot: AnalysisEngine.previewSnapshot(),
                                     engine: AnalysisEngine())
        let id = WorkspaceWindowID.fresh()
        registry.adopt(spawned, for: id)
        XCTAssertTrue(registry.store(for: id, launchConfiguration: WorkspaceLaunchConfiguration()) === spawned,
                      "an adopted store is what the window resolves — never a fresh fallback")

        registry.evict(id)
        XCTAssertEqual(registry.count, 0, "evicting the closed window releases its store")
        XCTAssertFalse(registry.store(for: id, launchConfiguration: WorkspaceLaunchConfiguration()) === spawned,
                       "after eviction the id resolves a NEW store, not the released one")
    }

    /// Stage 4: closing a window evicts its store (no accumulation), and window-placement indices
    /// increment so only the first window takes the explicit launch frame.
    func testEvictionAndPlacementIndexing() {
        let registry = WorkspaceSessionRegistry()
        _ = registry.store(for: .primary, launchConfiguration: WorkspaceLaunchConfiguration())
        let id = WorkspaceWindowID.fresh()
        _ = registry.store(for: id, launchConfiguration: WorkspaceLaunchConfiguration())
        XCTAssertEqual(registry.count, 2)
        registry.evict(id)
        XCTAssertEqual(registry.count, 1, "closing a window releases its store")

        // Placement is a monotonic counter: first window index 0 (explicit frame), then cascade.
        XCTAssertEqual(registry.nextWindowPlacementIndex(), 0)
        XCTAssertEqual(registry.nextWindowPlacementIndex(), 1)
        XCTAssertEqual(registry.nextWindowPlacementIndex(), 2)
    }

    /// The primary bootstrap honors the launch configuration exactly as the old single-store
    /// init did (the preview fixture is the observable knob).
    func testPrimaryBootstrapHonorsLaunchConfiguration() {
        let registry = WorkspaceSessionRegistry()
        let store = registry.store(
            for: .primary,
            launchConfiguration: WorkspaceLaunchConfiguration(loadsPreviewFixture: true)
        )
        XCTAssertFalse(store.snapshot.instructions.isEmpty,
                       "loadsPreviewFixture must seed the primary store's snapshot")
    }

    func testStoreAndDocumentSessionResolveAsOneStablePair() {
        let registry = WorkspaceSessionRegistry()
        let id = WorkspaceWindowID.fresh()
        let configuration = WorkspaceLaunchConfiguration()

        let firstStore = registry.store(for: id, launchConfiguration: configuration)
        let firstSession = registry.documentSession(
            for: id,
            launchConfiguration: configuration
        )
        let secondStore = registry.store(for: id, launchConfiguration: configuration)
        let secondSession = registry.documentSession(
            for: id,
            launchConfiguration: configuration
        )

        XCTAssertTrue(firstStore === secondStore)
        XCTAssertTrue(firstSession === secondSession)
        XCTAssertTrue(registry.storeIfPresent(for: id) === firstStore)
        XCTAssertTrue(registry.documentSessionIfPresent(for: id) === firstSession)
    }

    func testAdoptingPairedEntryEvictsAndClosesExactPriorSession() async {
        let registry = WorkspaceSessionRegistry()
        let id = WorkspaceWindowID.fresh()
        let priorStore = registry.store(
            for: id,
            launchConfiguration: WorkspaceLaunchConfiguration()
        )
        let priorSession = registry.documentSession(
            for: id,
            launchConfiguration: WorkspaceLaunchConfiguration()
        )
        let replacementStore = WorkspaceStore.bootstrap()
        let reservations = RegistryTestReservations()
        let replacementSession = WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: id,
            source: replacementStore,
            io: WorkspaceDocumentIO(),
            reservations: reservations
        )

        registry.adopt(
            replacementStore,
            documentSession: replacementSession,
            for: id
        )

        XCTAssertFalse(registry.storeIfPresent(for: id) === priorStore)
        XCTAssertTrue(registry.storeIfPresent(for: id) === replacementStore)
        XCTAssertTrue(registry.documentSessionIfPresent(for: id) === replacementSession)
        let priorSave = await priorSession.save()
        XCTAssertEqual(priorSave, .failed("document-session-closed"))

        registry.evict(id)
        let replacementSave = await replacementSession.save()
        XCTAssertEqual(replacementSave, .failed("document-session-closed"))
        XCTAssertEqual(reservations.releaseAllCount, 1)
        XCTAssertNil(registry.storeIfPresent(for: id))
        XCTAssertNil(registry.documentSessionIfPresent(for: id))
    }

    func testAdoptingReplacementRetiresPriorTransientPresentationAuthority() {
        let registry = WorkspaceSessionRegistry()
        let id = WorkspaceWindowID.fresh()
        _ = registry.store(
            for: id,
            launchConfiguration: WorkspaceLaunchConfiguration()
        )
        let priorPresentation = registry.nativeDecompilerPresentation(for: id)

        registry.adopt(WorkspaceStore.bootstrap(), for: id)

        let replacementPresentation = registry.nativeDecompilerPresentation(for: id)
        XCTAssertFalse(
            priorPresentation === replacementPresentation,
            "a replacement document must not inherit transient native evidence"
        )
    }

    func testEvictionDiscardsUnconsumedPendingBinaryOpen() {
        let registry = WorkspaceSessionRegistry()
        let id = WorkspaceWindowID.fresh()
        let pending = URL(fileURLWithPath: "/tmp/stale-pending-binary")
        registry.setPendingBinaryOpen(pending, for: id)
        _ = registry.store(
            for: id,
            launchConfiguration: WorkspaceLaunchConfiguration()
        )

        registry.evict(id)

        XCTAssertNil(
            registry.takePendingBinaryOpen(for: id),
            "a restored window identity must not consume a closed session's pending import"
        )
    }

    func testReusableWindowRequiresUntitledCleanEmptyAndIdlePair() {
        let registry = WorkspaceSessionRegistry()
        let reusableID = WorkspaceWindowID.fresh()
        let reusable = registry.store(
            for: reusableID,
            launchConfiguration: WorkspaceLaunchConfiguration()
        )
        XCTAssertTrue(reusable.snapshot.binaries.isEmpty)
        XCTAssertTrue(registry.isReusableDocumentWindow(reusableID))

        reusable.isImporting = true
        XCTAssertFalse(registry.isReusableDocumentWindow(reusableID))
    }

    /// Process termination must prepare a dirty document before the registry removes its entry.
    /// This fails under the former `shutdown -> removeEntry -> close` ordering because `close()`
    /// cancels the write instead of admitting the existing atomic publication path.
    func testShutdownPersistsDirtyDocumentBeforeRemovingItsSession() async throws {
        let registry = WorkspaceSessionRegistry()
        let windowID = WorkspaceWindowID.fresh()
        let store = WorkspaceStore(
            workspaceName: "Termination persistence fixture",
            snapshot: AnalysisEngine.previewSnapshot(),
            engine: AnalysisEngine()
        )
        let reservations = RegistryTestReservations()
        let session = WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: windowID,
            source: store,
            io: WorkspaceDocumentIO(),
            reservations: reservations
        )
        registry.adopt(store, documentSession: session, for: windowID)

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-Termination-\(UUID().uuidString).mscope")
        defer { try? FileManager.default.removeItem(at: packageURL) }
        guard case .saved(let clean, let adopted) = await session.saveAs(to: packageURL) else {
            return XCTFail("Expected initial Save As to establish a writable document")
        }
        XCTAssertTrue(clean)
        XCTAssertEqual(adopted?.canonicalURL, packageURL)
        store.setCustomName(0x1_0000_0000, name: "quit-persisted")
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertTrue(session.snapshot.hasUnsavedChanges)

        let didTerminate = await registry.shutdown()

        XCTAssertTrue(didTerminate)
        XCTAssertFalse(store.hasUnsavedChanges)
        XCTAssertNil(registry.storeIfPresent(for: windowID))
        XCTAssertNil(registry.documentSessionIfPresent(for: windowID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: packageURL.path))
    }

    /// RED anchor for the registry-level race: session A is prepared first, then becomes dirty
    /// while session B's already-admitted publication is still draining. Shutdown must compare
    /// the exact ID-to-session set and clean state again after the last await, causing A to be
    /// prepared a second time before either entry is removed.
    func testShutdownRepreparesEarlierSessionDirtiedWhileLaterSessionDrains() async throws {
        let registry = WorkspaceSessionRegistry()
        let firstID = WorkspaceWindowID(
            raw: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        )
        let secondID = WorkspaceWindowID(
            raw: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")!
        )
        let firstPublisher = RegistryTerminationPublisher()
        let secondPublisher = RegistryTerminationPublisher()
        let first = try makeTerminationFixture(
            id: firstID,
            name: "first",
            opened: true,
            publisher: firstPublisher
        )
        let second = try makeTerminationFixture(
            id: secondID,
            name: "second",
            opened: true,
            publisher: secondPublisher
        )
        registry.adopt(first.store, documentSession: first.session, for: firstID)
        registry.adopt(second.store, documentSession: second.session, for: secondID)

        first.store.setCustomName(0x1_0000_0000, name: "first-before-quit")
        second.store.setCustomName(0x1_0000_0000, name: "second-before-quit")
        await secondPublisher.pauseNextPublish()
        let admittedSecondSave = Task { await second.session.save() }
        await secondPublisher.waitUntilPublishStarted()

        let shutdown = Task { await registry.shutdown() }
        await firstPublisher.waitForPublishCount(1)
        await waitUntilTerminationRemovalIsReady(first.session)
        XCTAssertTrue(first.session.isReadyForTerminationRemoval())

        first.store.setCustomName(0x1_0000_0000, name: "first-after-preparation")
        XCTAssertTrue(first.session.snapshot.hasUnsavedChanges)
        await secondPublisher.releasePublish()

        let admittedSecondOutcome = await admittedSecondSave.value
        let didShutdown = await shutdown.value
        let firstPublishCount = await firstPublisher.publishCount
        let secondPublishCount = await secondPublisher.publishCount
        XCTAssertEqual(admittedSecondOutcome, .saved(clean: true, adopted: nil))
        XCTAssertTrue(didShutdown)
        XCTAssertEqual(firstPublishCount, 2)
        XCTAssertEqual(secondPublishCount, 1)
        XCTAssertFalse(first.store.hasUnsavedChanges)
        XCTAssertNil(registry.documentSessionIfPresent(for: firstID))
        XCTAssertNil(registry.documentSessionIfPresent(for: secondID))
    }

    /// A failed Quit is not a partial shutdown. Every prepared/current document stays registered,
    /// exits the termination fence, and can use its ordinary save path before a later retry.
    func testShutdownRefusalRestoresAllSessionsAndSupportsSuccessfulRetry() async throws {
        let registry = WorkspaceSessionRegistry()
        let openedID = WorkspaceWindowID(
            raw: UUID(uuidString: "00000000-0000-4000-8000-000000000010")!
        )
        let untitledID = WorkspaceWindowID(
            raw: UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFF0")!
        )
        let openedPublisher = RegistryTerminationPublisher()
        let untitledPublisher = RegistryTerminationPublisher()
        let opened = try makeTerminationFixture(
            id: openedID,
            name: "opened",
            opened: true,
            publisher: openedPublisher
        )
        let untitled = try makeTerminationFixture(
            id: untitledID,
            name: "untitled",
            opened: false,
            publisher: untitledPublisher
        )
        registry.adopt(opened.store, documentSession: opened.session, for: openedID)
        registry.adopt(untitled.store, documentSession: untitled.session, for: untitledID)
        opened.store.setCustomName(0x1_0000_0000, name: "opened-before-refusal")
        untitled.store.setCustomName(0x1_0000_0000, name: "untitled-before-refusal")

        let firstShutdown = await registry.shutdown()
        XCTAssertFalse(firstShutdown)

        XCTAssertTrue(registry.documentSessionIfPresent(for: openedID) === opened.session)
        XCTAssertTrue(registry.documentSessionIfPresent(for: untitledID) === untitled.session)
        XCTAssertFalse(opened.session.isTerminationPreparationActive)
        XCTAssertFalse(untitled.session.isTerminationPreparationActive)

        opened.store.setCustomName(0x1_0000_0000, name: "opened-after-refusal")
        let openedRecoverySave = await opened.session.save()
        XCTAssertEqual(openedRecoverySave, .saved(clean: true, adopted: nil))
        let untitledDestination = URL(
            fileURLWithPath: "/tmp/WorkspaceSessionRegistryTests/Recovered.mscope"
        )
        guard case .saved(let clean, let adopted) = await untitled.session.saveAs(
            to: untitledDestination
        ) else {
            return XCTFail("Untitled session did not recover after refused termination")
        }
        XCTAssertTrue(clean)
        XCTAssertEqual(adopted?.canonicalURL, untitledDestination)

        let retryShutdown = await registry.shutdown()
        XCTAssertTrue(retryShutdown)
        XCTAssertNil(registry.documentSessionIfPresent(for: openedID))
        XCTAssertNil(registry.documentSessionIfPresent(for: untitledID))
    }

    func testShutdownReplacementInvalidatesTransactionAndCannotBeAuthorizedByStaleSession() async throws {
        let registry = WorkspaceSessionRegistry()
        let windowID = WorkspaceWindowID.fresh()
        let stalePublisher = RegistryTerminationPublisher()
        let stale = try makeTerminationFixture(
            id: windowID,
            name: "replaced",
            opened: true,
            publisher: stalePublisher
        )
        registry.adopt(stale.store, documentSession: stale.session, for: windowID)
        stale.store.setCustomName(0x1_0000_0000, name: "stale-before-replacement")
        await stalePublisher.pauseNextPublish()

        let shutdown = Task { await registry.shutdown() }
        await stalePublisher.waitUntilPublishStarted()

        let replacementStore = WorkspaceStore.bootstrap()
        let replacementReservations = RegistryTestReservations()
        let replacementSession = WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: windowID,
            source: replacementStore,
            io: WorkspaceDocumentIO(),
            reservations: replacementReservations
        )
        registry.adopt(
            replacementStore,
            documentSession: replacementSession,
            for: windowID
        )
        await stalePublisher.releasePublish()

        let didShutdown = await shutdown.value
        XCTAssertFalse(didShutdown)
        XCTAssertTrue(registry.storeIfPresent(for: windowID) === replacementStore)
        XCTAssertTrue(registry.documentSessionIfPresent(for: windowID) === replacementSession)
        XCTAssertFalse(replacementSession.isTerminationPreparationActive)
        let replacementSave = await replacementSession.save()
        XCTAssertEqual(
            replacementSave,
            .failed("document-location-unavailable"),
            "the current session must return to normal admission after the stale attempt rolls back"
        )
    }

    func testShutdownNewAdmissionRollsBackEveryPreparedLiveSession() async throws {
        let drain = RegistryTerminationDrainProbe()
        drain.pauseNextDrain()
        let registry = WorkspaceSessionRegistry(
            terminationPreparationDeadline: nil,
            terminationAuthorityDrain: { store in await drain.drain(store) }
        )
        let originalID = WorkspaceWindowID.fresh()
        let admittedID = WorkspaceWindowID.fresh()
        let original = try makeTerminationFixture(
            id: originalID,
            name: "new-admission-original",
            opened: true,
            publisher: RegistryTerminationPublisher()
        )
        let admitted = try makeTerminationFixture(
            id: admittedID,
            name: "new-admission-current",
            opened: true,
            publisher: RegistryTerminationPublisher()
        )
        registry.adopt(original.store, documentSession: original.session, for: originalID)

        let shutdown = Task { await registry.shutdown() }
        await drain.waitUntilDrainStarted()
        XCTAssertTrue(original.session.isTerminationPreparationActive)
        registry.adopt(admitted.store, documentSession: admitted.session, for: admittedID)

        let didShutdown = await shutdown.value
        drain.releaseDrain()

        XCTAssertFalse(didShutdown)
        XCTAssertTrue(registry.documentSessionIfPresent(for: originalID) === original.session)
        XCTAssertTrue(registry.documentSessionIfPresent(for: admittedID) === admitted.session)
        XCTAssertFalse(original.session.isTerminationPreparationActive)
        XCTAssertFalse(admitted.session.isTerminationPreparationActive)
    }

    func testDuplicateShutdownCallersShareOnePreparationCommitAndResult() async throws {
        let drain = RegistryTerminationDrainProbe()
        drain.pauseNextDrain()
        let registry = WorkspaceSessionRegistry(
            terminationPreparationDeadline: nil,
            terminationAuthorityDrain: { store in await drain.drain(store) },
            terminationRetirementObserver: { id, store, session in
                drain.recordRetirement(id: id, store: store, session: session)
            }
        )
        let windowID = WorkspaceWindowID.fresh()
        let fixture = try makeTerminationFixture(
            id: windowID,
            name: "duplicate-callers",
            opened: true,
            publisher: RegistryTerminationPublisher()
        )
        registry.adopt(fixture.store, documentSession: fixture.session, for: windowID)

        let first = Task { await registry.shutdown() }
        await drain.waitUntilDrainStarted()
        let duplicate = Task { await registry.shutdown() }
        drain.releaseDrain()

        let firstResult = await first.value
        let duplicateResult = await duplicate.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(duplicateResult)
        XCTAssertEqual(drain.drainCount(for: fixture.store), 1)
        XCTAssertEqual(drain.retirementCount(for: fixture.store), 1)
        XCTAssertEqual(fixture.reservations.releaseAllCount, 1)
        XCTAssertEqual(drain.events, ["drain-start", "drain-end", "retire"])
        XCTAssertNil(registry.documentSessionIfPresent(for: windowID))
    }

    func testCancelledShutdownRollsBackFenceAndRetainsDirtyState() async throws {
        let drain = RegistryTerminationDrainProbe()
        drain.pauseNextDrain()
        let registry = WorkspaceSessionRegistry(
            terminationPreparationDeadline: nil,
            terminationAuthorityDrain: { store in await drain.drain(store) }
        )
        let windowID = WorkspaceWindowID.fresh()
        let fixture = try makeTerminationFixture(
            id: windowID,
            name: "caller-cancelled",
            opened: true,
            publisher: RegistryTerminationPublisher()
        )
        registry.adopt(fixture.store, documentSession: fixture.session, for: windowID)
        fixture.store.setCustomName(0x1_0000_0000, name: "still-dirty")

        let shutdown = Task { await registry.shutdown() }
        await drain.waitUntilDrainStarted()
        shutdown.cancel()
        let didShutdown = await shutdown.value
        drain.releaseDrain()

        XCTAssertFalse(didShutdown)
        XCTAssertTrue(registry.documentSessionIfPresent(for: windowID) === fixture.session)
        XCTAssertFalse(fixture.session.isTerminationPreparationActive)
        XCTAssertTrue(fixture.store.hasUnsavedChanges)
        let recoverySave = await fixture.session.save()
        XCTAssertEqual(recoverySave, .saved(clean: true, adopted: nil))
    }

    func testPreparationDeadlineRollsBackBeforeAnyRetirement() async throws {
        let drain = RegistryTerminationDrainProbe()
        drain.pauseNextDrain()
        let registry = WorkspaceSessionRegistry(
            terminationPreparationDeadline: .milliseconds(20),
            terminationAuthorityDrain: { store in await drain.drain(store) },
            terminationRetirementObserver: { id, store, session in
                drain.recordRetirement(id: id, store: store, session: session)
            }
        )
        let windowID = WorkspaceWindowID.fresh()
        let fixture = try makeTerminationFixture(
            id: windowID,
            name: "deadline",
            opened: true,
            publisher: RegistryTerminationPublisher()
        )
        registry.adopt(fixture.store, documentSession: fixture.session, for: windowID)
        fixture.store.setCustomName(0x1_0000_0000, name: "deadline-dirty")

        let didShutdown = await registry.shutdown()
        drain.releaseDrain()

        XCTAssertFalse(didShutdown)
        XCTAssertEqual(drain.retirementCount(for: fixture.store), 0)
        XCTAssertTrue(registry.documentSessionIfPresent(for: windowID) === fixture.session)
        XCTAssertFalse(fixture.session.isTerminationPreparationActive)
        XCTAssertTrue(fixture.store.hasUnsavedChanges)
    }

    func testCommitRejectsReentrantReplacementAndEvictionWithoutResurrection() async throws {
        let drain = RegistryTerminationDrainProbe()
        let holder = RegistryWeakRegistryBox()
        let windowID = WorkspaceWindowID.fresh()
        let replacementStore = WorkspaceStore.bootstrap()
        let replacementReservations = RegistryTestReservations()
        let replacementSession = WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: windowID,
            source: replacementStore,
            io: WorkspaceDocumentIO(),
            reservations: replacementReservations
        )
        let registry = WorkspaceSessionRegistry(
            terminationPreparationDeadline: nil,
            terminationAuthorityDrain: { store in await drain.drain(store) },
            terminationRetirementObserver: { id, store, session in
                drain.recordRetirement(id: id, store: store, session: session)
                holder.registry?.adopt(
                    replacementStore,
                    documentSession: replacementSession,
                    for: id
                )
                holder.registry?.evict(id)
            }
        )
        holder.registry = registry
        let fixture = try makeTerminationFixture(
            id: windowID,
            name: "commit-fence",
            opened: true,
            publisher: RegistryTerminationPublisher()
        )
        registry.adopt(fixture.store, documentSession: fixture.session, for: windowID)

        let didShutdown = await registry.shutdown()
        XCTAssertTrue(didShutdown)

        XCTAssertEqual(drain.drainCount(for: fixture.store), 1)
        XCTAssertEqual(drain.retirementCount(for: fixture.store), 1)
        XCTAssertEqual(fixture.reservations.releaseAllCount, 1)
        XCTAssertEqual(replacementReservations.releaseAllCount, 1)
        let rejectedReplacementSave = await replacementSession.save()
        XCTAssertEqual(
            rejectedReplacementSave,
            .failed("document-session-closed")
        )
        XCTAssertNil(registry.storeIfPresent(for: windowID))
        XCTAssertEqual(registry.count, 0)
    }

    private struct TerminationFixture {
        let store: WorkspaceStore
        let session: WorkspaceDocumentSession
        /// `WorkspaceDocumentSession` intentionally retains this authority weakly so the
        /// process-level coordinator owns its lifetime. The fixture must model that owner.
        let reservations: RegistryTestReservations
    }

    private func makeTerminationFixture(
        id: WorkspaceWindowID,
        name: String,
        opened: Bool,
        publisher: RegistryTerminationPublisher
    ) throws -> TerminationFixture {
        let store = WorkspaceStore(
            workspaceName: "Termination \(name)",
            snapshot: AnalysisEngine.previewSnapshot(),
            engine: AnalysisEngine()
        )
        let location = WorkspaceDocumentLocation(
            canonicalURL: URL(
                fileURLWithPath: "/tmp/WorkspaceSessionRegistryTests/\(name).mscope"
            ),
            fileObjectIdentity: nil
        )
        let observation = registryTerminationObservation(at: location, seed: name)
        let reservations = RegistryTestReservations()
        let session = WorkspaceDocumentSession(
            sessionID: WorkspaceDocumentSessionID(rawValue: UUID()),
            windowID: id,
            source: store,
            io: WorkspaceDocumentIO(
                probe: RegistryTerminationProbe(),
                reader: RegistryTerminationReader(),
                publisher: publisher,
                monitor: RegistryTerminationMonitor()
            ),
            reservations: reservations
        )
        if opened {
            try session.bindOpenedPackage(
                WorkspaceDocumentValidatedPackage(
                    manifestData: Data("registry-termination".utf8),
                    attachmentsByBinaryID: [:],
                    observation: observation
                ),
                at: location
            )
        }
        return TerminationFixture(
            store: store,
            session: session,
            reservations: reservations
        )
    }

    private func waitUntilTerminationRemovalIsReady(
        _ session: WorkspaceDocumentSession
    ) async {
        for _ in 0..<1_000 {
            if session.isReadyForTerminationRemoval() { return }
            await Task.yield()
        }
        XCTFail("Session never completed its initial termination preparation")
    }
}

@MainActor
private final class RegistryTerminationDrainProbe {
    private var shouldPauseNextDrain = false
    private var pausedDrain: CheckedContinuation<Void, Never>?
    private var drainStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var drainCounts: [ObjectIdentifier: Int] = [:]
    private var retirementCounts: [ObjectIdentifier: Int] = [:]
    private(set) var events: [String] = []

    func pauseNextDrain() {
        shouldPauseNextDrain = true
    }

    func drain(_ store: WorkspaceStore) async {
        let identity = ObjectIdentifier(store)
        drainCounts[identity, default: 0] += 1
        events.append("drain-start")
        if shouldPauseNextDrain {
            shouldPauseNextDrain = false
            let waiters = drainStartWaiters
            drainStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                pausedDrain = continuation
                waiters.forEach { $0.resume() }
            }
        }
        events.append("drain-end")
    }

    func waitUntilDrainStarted() async {
        if pausedDrain != nil { return }
        await withCheckedContinuation { continuation in
            drainStartWaiters.append(continuation)
        }
    }

    func releaseDrain() {
        pausedDrain?.resume()
        pausedDrain = nil
    }

    func recordRetirement(
        id: WorkspaceWindowID,
        store: WorkspaceStore,
        session: WorkspaceDocumentSession
    ) {
        _ = id
        _ = session
        retirementCounts[ObjectIdentifier(store), default: 0] += 1
        events.append("retire")
    }

    func drainCount(for store: WorkspaceStore) -> Int {
        drainCounts[ObjectIdentifier(store), default: 0]
    }

    func retirementCount(for store: WorkspaceStore) -> Int {
        retirementCounts[ObjectIdentifier(store), default: 0]
    }
}

@MainActor
private final class RegistryWeakRegistryBox {
    weak var registry: WorkspaceSessionRegistry?
}

@MainActor
private final class RegistryTestReservations: WorkspaceDocumentLocationReserving {
    private(set) var releaseAllCount = 0

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

    func releaseAll(for sessionID: WorkspaceDocumentSessionID) {
        releaseAllCount += 1
    }

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

private struct RegistryTerminationProbe: WorkspacePackageVersionProbing {
    func observe(_ url: URL) async throws -> WorkspacePackageExternalVersion {
        registryTerminationObservation(
            at: WorkspaceDocumentLocation(canonicalURL: url, fileObjectIdentity: nil),
            seed: "observed-\(url.lastPathComponent)"
        )
    }
}

private struct RegistryTerminationReader: WorkspaceDocumentReading {
    func readValidated(
        from location: WorkspaceDocumentLocation
    ) async throws -> WorkspaceDocumentValidatedPackage {
        throw WorkspaceDocumentSessionError.operationFailed(
            "registry-termination-read-not-supported"
        )
    }
}

private struct RegistryTerminationMonitor: WorkspaceDocumentChangeMonitoring {
    func changes(
        at location: WorkspaceDocumentLocation
    ) -> WorkspaceDocumentChangeFeed {
        WorkspaceDocumentChangeFeed(
            stream: AsyncStream { _ in },
            probeDemand: WorkspaceDocumentProbeDemand()
        )
    }
}

private actor RegistryTerminationPublisher: WorkspaceDocumentPublishing {
    private var shouldPauseNextPublish = false
    private var pausedPublish: CheckedContinuation<Void, Never>?
    private var publishStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var publishCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var publishCount = 0

    func pauseNextPublish() {
        shouldPauseNextPublish = true
    }

    func waitUntilPublishStarted() async {
        if pausedPublish != nil { return }
        await withCheckedContinuation { continuation in
            publishStartWaiters.append(continuation)
        }
    }

    func waitForPublishCount(_ expected: Int) async {
        if publishCount >= expected { return }
        await withCheckedContinuation { continuation in
            publishCountWaiters.append((expected, continuation))
        }
    }

    func releasePublish() {
        pausedPublish?.resume()
        pausedPublish = nil
    }

    func stage(
        _ payload: WorkspaceDocumentPackagePayload,
        in parentDirectory: URL
    ) async throws -> WorkspaceDocumentStagedPackage {
        let stagingID = UUID()
        let stagingLocation = WorkspaceDocumentLocation(
            canonicalURL: parentDirectory.appendingPathComponent(
                "registry-stage-\(stagingID.uuidString)"
            ),
            fileObjectIdentity: nil
        )
        return WorkspaceDocumentStagedPackage(
            stagingID: stagingID,
            stagingURL: stagingLocation.canonicalURL,
            stagedObservation: registryTerminationObservation(
                at: stagingLocation,
                seed: "staged"
            ),
            capturedMutationGeneration: payload.capturedMutationGeneration
        )
    }

    func publish(
        _ staged: WorkspaceDocumentStagedPackage,
        to destination: WorkspaceDocumentLocation,
        expecting expected: WorkspacePackageExternalVersion
    ) async throws -> WorkspaceDocumentPublishReceipt {
        publishCount += 1
        let ready = publishCountWaiters.filter { publishCount >= $0.0 }
        publishCountWaiters.removeAll { publishCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        if shouldPauseNextPublish {
            shouldPauseNextPublish = false
            let startWaiters = publishStartWaiters
            publishStartWaiters.removeAll()
            await withCheckedContinuation { continuation in
                pausedPublish = continuation
                startWaiters.forEach { $0.resume() }
            }
        }
        return WorkspaceDocumentPublishReceipt(
            stagingID: staged.stagingID,
            destination: destination,
            priorObservation: expected,
            publishedObservation: registryTerminationObservation(
                at: destination,
                seed: "published-\(publishCount)"
            )
        )
    }

    func discard(_ staged: WorkspaceDocumentStagedPackage) async {}
}

private func registryTerminationObservation(
    at location: WorkspaceDocumentLocation,
    seed: String
) -> WorkspacePackageExternalVersion {
    let digest = MacScopeDocumentPackage.fileHash(for: Data(seed.utf8))
    return WorkspacePackageExternalVersion(
        location: location,
        condition: .valid,
        observationSHA256: digest,
        manifestSHA256: digest,
        validatedContentSHA256: digest,
        boundedReason: nil
    )
}
