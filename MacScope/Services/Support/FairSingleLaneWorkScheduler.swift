import Foundation

/// How an accepted submission entered the scheduler's single-capacity lane.
enum FairSingleLaneSubmissionDisposition: Equatable, Sendable {
    /// A new unique entry found the lane idle and started immediately.
    case started
    /// A new unique entry was accepted behind the active entry.
    case queued
    /// The submission joined the unique entry that currently owns the lane.
    case joinedActive
    /// The submission joined a unique entry that was already waiting for the lane.
    case joinedQueued
}

/// Occupancy reported synchronously after one waiter has been accepted atomically.
struct FairSingleLaneSubmissionAdmission: Equatable, Sendable {
    let disposition: FairSingleLaneSubmissionDisposition
    let queuedEntryCount: Int
    let queuedWeight: UInt64
}

/// Terminal failures produced by the scheduler itself. An operation's own thrown error is
/// propagated to its waiters unchanged and is never wrapped in this type, so a caller can always
/// tell "the lane refused the work" apart from "the work ran and failed".
enum FairSingleLaneSchedulerError: Error, Equatable, Sendable {
    /// `shutdown()` had already been observed when this submission registered, or the shutdown
    /// transition won the race against an in-flight entry's terminal result.
    case shutDown
    /// The submission was a *new unique* entry that would have had to wait behind the active
    /// entry, and the bound on unique queued entries was already met. Duplicate submissions of a
    /// key that is already queued or active never hit this: they add a waiter, not an entry.
    case queueLimitReached(limit: Int)
    /// The submission was a *new unique* queued entry whose weight would overflow `UInt64` or
    /// exceed the configured aggregate queued-weight bound. Duplicate submissions add no weight.
    case queuedWeightLimitReached(limit: UInt64)
}

/// The scheduler can no longer mint a globally unique waiter or entry identity. This is separate
/// from the ordinary bounded-admission error catalog so existing exhaustive handling of queue and
/// shutdown failures remains source-compatible. Exhaustion is terminal for admission: accepted
/// work still settles normally, but this and every later submission fail closed.
struct FairSingleLaneIdentifierExhaustionError: Error, Equatable, Sendable {}

/// Read-only occupancy of the lane, sampled at one actor-isolated instant.
///
/// This is the scheduler's only introspection surface. It exists because a single-capacity lane
/// fronting several independent owners is otherwise opaque — callers cannot tell a slow operation
/// from a deep queue — and because deterministic tests need a benign, non-destructive way to
/// observe a state transition without sleeping. It reports occupancy only; it exposes no owner,
/// key, continuation, or operation, so it cannot be used to reach around the scheduling rules.
struct FairSingleLaneSchedulerSnapshot: Equatable, Sendable {
    /// True while one unique entry occupies the lane, including an entry that has lost every
    /// waiter and is draining to a terminal state after cancellation.
    let hasActiveEntry: Bool
    /// Unique entries waiting for the lane. Excludes the active entry and excludes duplicate
    /// waiters — this is the quantity `maximumQueuedEntries` bounds.
    let queuedEntryCount: Int
    /// Sum of the exact weights supplied by unique entries still waiting for the lane. The active
    /// entry and duplicate waiters contribute zero.
    let queuedWeight: UInt64
    /// Registered waiters across the active entry and every queued entry. Duplicate submissions
    /// of one key each contribute a waiter while contributing a single entry.
    let waiterCount: Int
    /// True once `shutdown()` has marked the lane closed, even if it has not yet returned.
    let isShutDown: Bool
}

/// A single-capacity work lane that is fair across owners and coalescing across work keys.
///
/// The problem this solves: several independent owners (windows, sessions, tabs) each want to run
/// async work, but the resource behind them can only serve one request at a time. Running the
/// submissions in plain global FIFO lets one busy owner monopolize the lane; running them
/// concurrently oversubscribes the resource. This actor serializes the lane, keeps each owner's
/// own submissions in order, and rotates *between* owners so a busy owner cannot starve a quiet
/// one. It also collapses concurrent requests for the same work key onto one execution, which is
/// what makes several windows asking the same question cheap instead of quadratic.
///
/// ## Scheduling
/// - Exactly one unique entry is active at a time.
/// - Each owner's queued entries run in submission order (FIFO within an owner).
/// - Between owners the lane is round-robin: when an entry finishes, its owner rotates to the back
///   of the ring, so the next owner in rotation runs before that owner's next entry. Concretely,
///   if owner `A` is active and `A2` then `B1` are queued, `B1` runs before `A2`.
/// - A key that is already queued or active does not enqueue or execute a second operation. The
///   first submission's owner, queue position, and closure are authoritative; a later duplicate's
///   closure is ignored and its caller simply joins the existing entry as another waiter.
///
/// ## Cancellation
/// Cancelling one caller removes only that caller's waiter and completes it with
/// `CancellationError`; sibling waiters on the same key and every other owner are untouched. When
/// an entry loses its *final* waiter the work itself is no longer wanted: a queued entry is
/// dropped from its owner's queue (FIFO order for the remainder is preserved, and the rotation
/// ring is repaired), and an active entry has its operation task cancelled. The lane does not
/// advance to the next entry until that cancelled task reaches a terminal state, so the
/// one-at-a-time guarantee holds even while a cancelled operation is still unwinding.
///
/// Cancellation is cooperative. A submitted operation that never checks `Task.isCancelled` and
/// never suspends at a cancellation-aware point cannot be stopped by generic in-process code, and
/// will hold the lane until it returns on its own. Callers must submit cancellation-cooperative
/// work.
///
/// ## Shutdown
/// `shutdown()` marks the lane closed first, so any submission that registers afterwards fails
/// with `.shutDown`. It then fails every queued waiter, releases the active entry's waiters,
/// cancels the active operation task, and awaits that task's terminal state before returning —
/// so no scheduler-started task outlives the call. It is idempotent: repeated and concurrent
/// calls observe the same terminal state.
///
/// ## Concurrency design
/// All mutable state is actor-isolated; nothing is `@unchecked Sendable`. Every waiter is given a
/// stable identifier *before* it enters cancellation-sensitive registration, and every resume path
/// (early cancellation, late cancellation, queue rejection, shutdown, operation completion) funnels
/// through `resolve(_:_:with:)` after the continuation has been removed from its entry — so a
/// continuation is structurally unable to resume twice. The injected operation never runs under
/// actor isolation: it is routed through the `nonisolated` runner `runOperation(entryID:operation:)`
/// so that even a closure doing synchronous work before its first suspension cannot block the lane's
/// bookkeeping. The runner reports back through the single actor-isolated `complete(entryID:result:)`,
/// which validates the entry identity it was started with and discards a stale result.
actor FairSingleLaneWorkScheduler<
    OwnerID: Hashable & Sendable,
    WorkKey: Hashable & Sendable,
    Output: Sendable
> {
    private typealias EntryID = UInt64
    private typealias WaiterID = UInt64

    /// One unit of unique work plus the callers currently waiting on it. Duplicate submissions of
    /// the same key add to `waiters`; they never produce a second `Entry`.
    private struct Entry {
        let id: EntryID
        let owner: OwnerID
        let key: WorkKey
        let operation: @Sendable () async throws -> Output
        /// Weight still charged to the queued aggregate. It is zero for work admitted directly
        /// into an idle lane and is cleared exactly once when queued work is dispatched.
        var weight: UInt64
        var waiters: [WaiterID: CheckedContinuation<Output, any Error>] = [:]
    }

    /// Bound on unique *queued* entries. Zero is meaningful: an idle lane still runs a submission
    /// immediately (it never queues), while any unique work that would have to wait behind an
    /// active entry is rejected.
    private let maximumQueuedEntries: Int
    /// Bound on the aggregate weight of unique entries waiting for the lane.
    private let maximumQueuedWeight: UInt64
    /// Inclusive upper bounds for monotonically issued identities. Product callers use the full
    /// `UInt64` space; narrow values are injectable so boundary behavior can be tested without
    /// relying on source inspection or an infeasible number of submissions.
    private let maximumEntryIDValue: EntryID
    private let maximumWaiterIDValue: WaiterID

    private var entries: [EntryID: Entry] = [:]
    private var entryIDsByKey: [WorkKey: EntryID] = [:]
    /// Queued entry identifiers per owner, oldest first. The active entry is not in here.
    private var queuesByOwner: [OwnerID: [EntryID]] = [:]
    /// Round-robin rotation. An owner is present while it has queued entries, and the active
    /// entry's owner stays present even with an empty queue so that it holds its rotation slot and
    /// cannot immediately re-take the lane ahead of owners that arrived while it was busy.
    private var ownerRing: [OwnerID] = []
    private var activeEntryID: EntryID?
    /// Handle to the most recently started operation task. Retained after the task terminates so
    /// that `shutdown()` always has something concrete to await.
    private var runningTask: Task<Void, Never>?
    /// Identity of the entry `runningTask` is executing, cleared as soon as its result is reported.
    /// This — not `runningTask` — gates dispatch, so the lane never starts a second operation.
    private var runningEntryID: EntryID?
    private var waiterEntryIDs: [WaiterID: EntryID] = [:]
    /// Waiters that have been allocated but not yet resumed. A waiter absent from this set has
    /// already reached a terminal state, which is what makes late cancellation a safe no-op.
    private var pendingWaiterIDs: Set<WaiterID> = []
    /// Waiters cancelled before their continuation was installed. Registration consumes these.
    private var earlyCancelledWaiterIDs: Set<WaiterID> = []
    /// Exact aggregate of `Entry.weight` for entries still present in `queuesByOwner`.
    private var queuedWeight: UInt64 = 0
    private var isShutDown = false
    /// A one-way admission fuse. It is deliberately separate from shutdown: exhaustion must stop
    /// new identity creation without preventing already-queued work from dispatching and settling.
    private var hasExhaustedIdentifierSpace = false
    private var nextEntryIDValue: EntryID = 0
    private var nextWaiterIDValue: WaiterID = 0

    /// - Parameters:
    ///   - maximumQueuedEntries: bound on unique entries waiting for the lane. Duplicate waiters
    ///     and the active entry are not counted. Zero permits immediate execution on an idle lane
    ///     while rejecting unique work that would have to queue.
    ///   - maximumQueuedWeight: bound on the aggregate exact weight of unique queued entries.
    ///     Work admitted directly into an idle lane and duplicate waiters are not charged.
    ///   - maximumEntryIDValue: inclusive entry-identity ceiling. The default uses the full
    ///     production identity space; lower values support deterministic boundary tests.
    ///   - maximumWaiterIDValue: inclusive waiter-identity ceiling. The default uses the full
    ///     production identity space; lower values support deterministic boundary tests.
    init(
        maximumQueuedEntries: Int,
        maximumQueuedWeight: UInt64 = .max,
        maximumEntryIDValue: UInt64 = .max,
        maximumWaiterIDValue: UInt64 = .max
    ) {
        precondition(
            maximumQueuedEntries >= 0,
            "FairSingleLaneWorkScheduler requires a non-negative queue bound, got \(maximumQueuedEntries)"
        )
        self.maximumQueuedEntries = maximumQueuedEntries
        self.maximumQueuedWeight = maximumQueuedWeight
        self.maximumEntryIDValue = maximumEntryIDValue
        self.maximumWaiterIDValue = maximumWaiterIDValue
    }

    // MARK: - Submission

    /// Runs `operation` on the lane and returns its result.
    ///
    /// If `key` is already queued or active, `operation` is *not* executed: the caller joins the
    /// existing entry and receives whatever that entry produces. Otherwise the work is queued for
    /// `owner` and dispatched when the rotation reaches it.
    ///
    /// Cancelling the calling task removes only this caller. Other waiters on `key` keep running,
    /// and the operation is cancelled only if this was its last waiter.
    ///
    /// - Throws: the operation's own error; `CancellationError` if the caller is cancelled;
    ///   `FairSingleLaneSchedulerError.shutDown` if the lane is closed;
    ///   `FairSingleLaneSchedulerError.queueLimitReached` if a new unique entry would exceed the
    ///   count bound; or `FairSingleLaneSchedulerError.queuedWeightLimitReached` if accepting its
    ///   queued weight would overflow or exceed the weight bound; or
    ///   `FairSingleLaneIdentifierExhaustionError` once no fresh waiter or entry identity remains.
    func submit(
        owner: OwnerID,
        key: WorkKey,
        queuedWeight: UInt64 = 0,
        admission: @escaping @Sendable (FairSingleLaneSubmissionAdmission) -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        // The identifier is minted before the cancellation handler is installed, so a cancellation
        // that arrives before the continuation exists still has a stable name to refer to.
        let waiterID = try allocateWaiterID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    waiterID: waiterID,
                    owner: owner,
                    key: key,
                    queuedWeight: queuedWeight,
                    admission: admission,
                    operation: operation,
                    continuation: continuation
                )
            }
        } onCancel: {
            // `onCancel` runs synchronously on whichever thread cancelled the caller, so reaching
            // isolated state needs a hop. This is the one unstructured task the type creates
            // besides the operation task; it is a plain `Task` (never `Task.detached`), it only
            // performs bookkeeping, and after shutdown it short-circuits on `pendingWaiterIDs`
            // because every waiter has already been resumed.
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Closes the lane and settles everything outstanding.
    ///
    /// Marks the scheduler closed first so no submission can slip in behind the drain, fails every
    /// queued waiter and the active entry's waiters with `.shutDown`, cancels the active operation
    /// task, and awaits that task's terminal state. Safe to call repeatedly and concurrently;
    /// every caller observes the same terminal state.
    func shutdown() async {
        if !isShutDown {
            isShutDown = true

            // Queued entries first: none of them has started, so there is nothing to await.
            let queuedEntryIDs = queuesByOwner.values.flatMap { $0 }
            queuesByOwner.removeAll()
            ownerRing.removeAll()
            for entryID in queuedEntryIDs {
                releaseEntry(entryID, with: .failure(FairSingleLaneSchedulerError.shutDown))
            }

            // The active entry's waiters are released now and its identity is dropped, so the
            // operation's eventual result is recognised as stale and discarded by `complete`.
            if let activeEntryID {
                self.activeEntryID = nil
                releaseEntry(activeEntryID, with: .failure(FairSingleLaneSchedulerError.shutDown))
            }
            runningTask?.cancel()
        }

        // Awaiting releases actor isolation, which is what lets the operation task run its final
        // hop back into `complete`. A concurrent caller that arrives during this window sees the
        // same handle and awaits the same terminal state. Nothing can be dispatched behind us:
        // `dispatchNextIfIdle` refuses to start work once `isShutDown` is set.
        if let task = runningTask {
            await task.value
        }
        runningTask = nil
        runningEntryID = nil
    }

    /// Point-in-time occupancy of the lane. See `FairSingleLaneSchedulerSnapshot`.
    func snapshot() -> FairSingleLaneSchedulerSnapshot {
        FairSingleLaneSchedulerSnapshot(
            hasActiveEntry: activeEntryID != nil,
            queuedEntryCount: queuedEntryCount,
            queuedWeight: queuedWeight,
            waiterCount: waiterEntryIDs.count,
            isShutDown: isShutDown
        )
    }

    // MARK: - Registration

    private func allocateWaiterID() throws -> WaiterID {
        if isShutDown {
            throw FairSingleLaneSchedulerError.shutDown
        }
        if hasExhaustedIdentifierSpace {
            throw FairSingleLaneIdentifierExhaustionError()
        }
        guard nextWaiterIDValue < maximumWaiterIDValue else {
            hasExhaustedIdentifierSpace = true
            throw FairSingleLaneIdentifierExhaustionError()
        }
        nextWaiterIDValue += 1
        let waiterID = nextWaiterIDValue
        pendingWaiterIDs.insert(waiterID)
        return waiterID
    }

    /// Mints an entry identity only after every ordinary admission bound has passed. Returning
    /// `nil` burns no identity and installs the same terminal admission fuse as waiter exhaustion.
    private func allocateEntryID() -> EntryID? {
        guard !hasExhaustedIdentifierSpace,
              nextEntryIDValue < maximumEntryIDValue else {
            hasExhaustedIdentifierSpace = true
            return nil
        }
        nextEntryIDValue += 1
        return nextEntryIDValue
    }

    /// Installs a caller's continuation, coalescing onto an existing entry when the key is already
    /// known. Runs under actor isolation: `withCheckedThrowingContinuation`'s body is synchronous
    /// and inherits the isolation of `submit`, so state is mutated here without an intervening
    /// suspension and cannot interleave with another submission.
    private func register(
        waiterID: WaiterID,
        owner: OwnerID,
        key: WorkKey,
        queuedWeight submittedQueuedWeight: UInt64,
        admission: @escaping @Sendable (FairSingleLaneSubmissionAdmission) -> Void,
        operation: @escaping @Sendable () async throws -> Output,
        continuation: CheckedContinuation<Output, any Error>
    ) {
        // The caller was cancelled before its continuation existed; honour it without ever
        // touching the queues.
        if earlyCancelledWaiterIDs.remove(waiterID) != nil {
            resolve(waiterID, continuation, with: .failure(CancellationError()))
            return
        }

        guard !isShutDown else {
            resolve(waiterID, continuation, with: .failure(FairSingleLaneSchedulerError.shutDown))
            return
        }

        guard !hasExhaustedIdentifierSpace else {
            resolve(
                waiterID,
                continuation,
                with: .failure(FairSingleLaneIdentifierExhaustionError())
            )
            return
        }

        // Coalesce. This precedes the bound check on purpose: a duplicate adds a waiter, not a
        // queued entry, so it must not be rejected by a limit that counts entries.
        if let existingEntryID = entryIDsByKey[key] {
            attach(waiterID, continuation, to: existingEntryID)
            reportAdmission(
                existingEntryID == activeEntryID ? .joinedActive : .joinedQueued,
                using: admission
            )
            return
        }

        // A new unique entry only has to queue when the lane is occupied. An idle lane dispatches
        // immediately, which is what makes a zero bound usable rather than a permanent refusal.
        let startsImmediately = activeEntryID == nil && runningEntryID == nil
        if !startsImmediately, queuedEntryCount >= maximumQueuedEntries {
            resolve(
                waiterID,
                continuation,
                with: .failure(FairSingleLaneSchedulerError.queueLimitReached(limit: maximumQueuedEntries))
            )
            return
        }

        let acceptedWeight: UInt64
        let resultingQueuedWeight: UInt64?
        if startsImmediately {
            acceptedWeight = 0
            resultingQueuedWeight = nil
        } else {
            let (newQueuedWeight, overflow) = queuedWeight.addingReportingOverflow(submittedQueuedWeight)
            guard !overflow, newQueuedWeight <= maximumQueuedWeight else {
                resolve(
                    waiterID,
                    continuation,
                    with: .failure(
                        FairSingleLaneSchedulerError.queuedWeightLimitReached(limit: maximumQueuedWeight)
                    )
                )
                return
            }
            acceptedWeight = submittedQueuedWeight
            resultingQueuedWeight = newQueuedWeight
        }

        guard let entryID = allocateEntryID() else {
            resolve(
                waiterID,
                continuation,
                with: .failure(FairSingleLaneIdentifierExhaustionError())
            )
            return
        }
        if let resultingQueuedWeight {
            queuedWeight = resultingQueuedWeight
        }
        entries[entryID] = Entry(
            id: entryID,
            owner: owner,
            key: key,
            operation: operation,
            weight: acceptedWeight
        )
        entryIDsByKey[key] = entryID
        queuesByOwner[owner, default: []].append(entryID)
        if !ownerRing.contains(owner) {
            ownerRing.append(owner)
        }
        attach(waiterID, continuation, to: entryID)
        dispatchNextIfIdle()
        reportAdmission(startsImmediately ? .started : .queued, using: admission)
    }

    /// Reports one accepted waiter's disposition while registration still owns actor isolation.
    /// A fast operation may finish concurrently, but its terminal `complete` hop cannot enter the
    /// actor until this synchronous callback returns.
    private func reportAdmission(
        _ disposition: FairSingleLaneSubmissionDisposition,
        using callback: @Sendable (FairSingleLaneSubmissionAdmission) -> Void
    ) {
        callback(
            FairSingleLaneSubmissionAdmission(
                disposition: disposition,
                queuedEntryCount: queuedEntryCount,
                queuedWeight: queuedWeight
            )
        )
    }

    private func attach(
        _ waiterID: WaiterID,
        _ continuation: CheckedContinuation<Output, any Error>,
        to entryID: EntryID
    ) {
        entries[entryID]?.waiters[waiterID] = continuation
        waiterEntryIDs[waiterID] = entryID
    }

    /// The single resume path. The continuation is always removed from its entry *before* it gets
    /// here, and `pendingWaiterIDs` is cleared here, so no other path can reach the same
    /// continuation afterwards.
    private func resolve(
        _ waiterID: WaiterID,
        _ continuation: CheckedContinuation<Output, any Error>,
        with result: Result<Output, any Error>
    ) {
        pendingWaiterIDs.remove(waiterID)
        waiterEntryIDs.removeValue(forKey: waiterID)
        continuation.resume(with: result)
    }

    // MARK: - Cancellation

    /// Removes one caller. Reached from `onCancel`, so it may arrive before registration, after
    /// the waiter has already been resumed, or at any point in between.
    private func cancelWaiter(_ waiterID: WaiterID) {
        // Already terminal — completed, rejected, or released by shutdown. Nothing to undo.
        guard pendingWaiterIDs.contains(waiterID) else { return }

        // Cancellation beat registration. Leave a marker; `register` consumes it and resumes the
        // continuation the moment it appears.
        guard let entryID = waiterEntryIDs[waiterID] else {
            earlyCancelledWaiterIDs.insert(waiterID)
            return
        }

        guard let continuation = entries[entryID]?.waiters.removeValue(forKey: waiterID) else {
            return
        }
        resolve(waiterID, continuation, with: .failure(CancellationError()))

        // Other callers still want this work; the operation is unaffected.
        guard entries[entryID]?.waiters.isEmpty == true else { return }

        if activeEntryID == entryID {
            // Nobody is left to receive the result, so stop the work. The lane deliberately stays
            // occupied until the cancelled task reports back through `complete`, which is what
            // preserves "one operation at a time" while the operation unwinds.
            //
            // Unpublish only this entry's key now so a later same-key submission can register a
            // fresh successor behind the draining operation. The old entry and running identities
            // remain until `complete`, whose identity guard prevents stale cleanup from removing
            // the successor's publication.
            if let entry = entries[entryID], entryIDsByKey[entry.key] == entryID {
                entryIDsByKey.removeValue(forKey: entry.key)
            }
            if runningEntryID == entryID {
                runningTask?.cancel()
            }
        } else {
            discardQueuedEntry(entryID)
        }
    }

    /// Drops a queued entry that nobody is waiting on, preserving FIFO order for the owner's
    /// remaining entries and repairing the rotation ring.
    private func discardQueuedEntry(_ entryID: EntryID) {
        guard let entry = entries.removeValue(forKey: entryID) else { return }
        releaseQueuedWeight(entry.weight)
        if entryIDsByKey[entry.key] == entryID {
            entryIDsByKey.removeValue(forKey: entry.key)
        }
        guard var queue = queuesByOwner[entry.owner],
              let index = queue.firstIndex(of: entryID) else { return }
        queue.remove(at: index)
        if queue.isEmpty {
            queuesByOwner.removeValue(forKey: entry.owner)
            // The owner leaves the rotation unless it is also the active owner, which holds its
            // slot until its entry completes. Removing it here would let it jump the rotation.
            if activeOwner != entry.owner {
                ownerRing.removeAll { $0 == entry.owner }
            }
        } else {
            queuesByOwner[entry.owner] = queue
        }
    }

    // MARK: - Dispatch

    private var queuedEntryCount: Int {
        queuesByOwner.values.reduce(0) { $0 + $1.count }
    }

    private var activeOwner: OwnerID? {
        activeEntryID.flatMap { entries[$0]?.owner }
    }

    /// Starts the next entry if the lane is free. `runningEntryID` — not `runningTask` — is the
    /// gate, because an operation task that has already reported its result is finished for
    /// scheduling purposes even though its handle is retained for `shutdown()` to await.
    private func dispatchNextIfIdle() {
        guard !isShutDown, activeEntryID == nil, runningEntryID == nil else { return }

        while let owner = ownerRing.first {
            guard var queue = queuesByOwner[owner], !queue.isEmpty else {
                ownerRing.removeFirst()
                continue
            }
            let entryID = queue.removeFirst()
            if queue.isEmpty {
                queuesByOwner.removeValue(forKey: owner)
            } else {
                queuesByOwner[owner] = queue
            }
            guard var entry = entries[entryID] else { continue }

            // Removing an entry from the queue releases exactly its outstanding charge. Clearing
            // the per-entry value makes later completion or shutdown unable to subtract it twice.
            releaseQueuedWeight(entry.weight)
            entry.weight = 0
            entries[entryID] = entry

            // State is fully committed before the task is created, so the result can never be
            // reported back into a half-updated scheduler.
            activeEntryID = entryID
            runningEntryID = entryID
            runningTask = Task {
                await self.runOperation(entryID: entryID, operation: entry.operation)
            }
            return
        }
    }

    /// Executes the injected closure off the actor.
    ///
    /// `Task { operation() }` on its own would be wrong here: a task created on an actor inherits
    /// that isolation, so any synchronous work the closure performs before its first suspension
    /// would run on — and block — the scheduler. This runner is the hop that prevents it, and
    /// `@concurrent` states the requirement rather than inferring it: a bare `nonisolated async`
    /// function only leaves the caller's executor under today's default, and would inherit the
    /// caller's isolation again under the `NonisolatedNonsendingByDefault` upcoming feature.
    /// Pinning it to the concurrent pool keeps the lane's bookkeeping responsive either way.
    ///
    /// The result comes back through exactly one isolated funnel, tagged with the entry identity
    /// the task was started with.
    @concurrent
    private nonisolated func runOperation(
        entryID: EntryID,
        operation: @escaping @Sendable () async throws -> Output
    ) async {
        let result: Result<Output, any Error>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        await complete(entryID: entryID, result: result)
    }

    /// The single place an operation's terminal result re-enters the scheduler.
    private func complete(entryID: EntryID, result: sending Result<Output, any Error>) {
        if runningEntryID == entryID {
            runningEntryID = nil
        }

        // Identity check. If shutdown released this entry while the operation was still running,
        // `activeEntryID` no longer names it and the result is discarded — its waiters already
        // completed with `.shutDown` and must not be resumed a second time.
        guard activeEntryID == entryID, entries[entryID] != nil else { return }
        activeEntryID = nil

        guard let owner = entries[entryID]?.owner else { return }
        releaseEntry(entryID, with: result)

        // Round-robin: the owner that just ran goes to the back of the ring, so an owner that
        // arrived while it held the lane is served before its next entry.
        ownerRing.removeAll { $0 == owner }
        if queuesByOwner[owner]?.isEmpty == false {
            ownerRing.append(owner)
        }
        dispatchNextIfIdle()
    }

    /// Removes an entry and broadcasts one terminal result to every waiter still registered on it.
    /// An entry whose waiters all cancelled is removed with no one to notify, which is the normal
    /// path for work that was abandoned while active.
    private func releaseEntry(_ entryID: EntryID, with result: Result<Output, any Error>) {
        guard let entry = entries.removeValue(forKey: entryID) else { return }
        releaseQueuedWeight(entry.weight)
        if entryIDsByKey[entry.key] == entryID {
            entryIDsByKey.removeValue(forKey: entry.key)
        }
        for (waiterID, continuation) in entry.waiters {
            resolve(waiterID, continuation, with: result)
        }
    }

    /// Removes a charge known to belong to one queued entry. Callers clear or remove that entry in
    /// the same actor turn, making each accepted charge structurally releasable only once.
    private func releaseQueuedWeight(_ weight: UInt64) {
        precondition(
            weight <= queuedWeight,
            "FairSingleLaneWorkScheduler queued-weight accounting underflow"
        )
        queuedWeight -= weight
    }
}
