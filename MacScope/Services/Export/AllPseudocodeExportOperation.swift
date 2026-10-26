import Foundation

/// One serial export of immutable captured inputs. The renderer must not consult a live store.
/// Each block is written to an owned temporary spool as soon as it is rendered, so memory stays
/// bounded by one block; the bytes are exactly those of joining the blocks with a blank line.
/// Cancellation is cooperative: it cannot interrupt the current printer or a committed publication.
/// A failed or cancelled run removes its spool and never publishes.
final class AllPseudocodeExportOperation: @unchecked Sendable {
    struct Owner: Equatable, Sendable {
        let documentID: UUID
        let windowGeneration: UUID
        let documentGeneration: UInt64
        let imageSlot: Int
        let binaryID: UUID
    }

    struct Item: Sendable {
        let startAddress: UInt64
    }

    struct Progress: Equatable, Sendable {
        /// completed means rendering finished, not that the output was written.
        enum Phase: Sendable { case rendering, completed, cancelled, failed }
        /// Number of attempted items that returned successfully, including skipped inputs.
        let completed: Int
        let total: Int
        let phase: Phase
    }

    enum Failure: Error, Equatable {
        case alreadyStarted
        case staleOwner
        case notPublishable
    }

    /// Opaque, complete output: a finished spool. Only this operation can construct or publish it.
    struct Output: Sendable {
        fileprivate let operationID: UUID
        fileprivate let sink: any PseudocodeExportSink
        /// UTF-8 bytes in the spool.
        let byteCount: Int
    }

    let owner: Owner
    let items: [Item]
    private let operationID = UUID()
    private let lock = NSLock()
    private enum State { case idle, running, ready, publishing, published, cancelled, failed }
    private var state = State.idle
    private var cancellationRequested = false
    private var hasStarted = false
    private var pendingSink: (any PseudocodeExportSink)?

    init(owner: Owner, items: [Item]) {
        self.owner = owner
        // Equal starts retain the incoming order, as Swift's canonical stable sort does.
        self.items = items.sorted { $0.startAddress < $1.startAddress }
    }

    deinit { pendingSink?.remove() }

    func cancel() {
        let sink: (any PseudocodeExportSink)? = lock.withLock {
            cancellationRequested = true
            guard state == .ready || state == .idle else { return nil }
            state = .cancelled
            defer { pendingSink = nil }
            return pendingSink
        }
        sink?.remove()
    }

    var isCancelled: Bool { lock.withLock { cancellationRequested } }

    private func checkCancellation() throws {
        if Task.isCancelled || lock.withLock({ cancellationRequested }) {
            throw CancellationError()
        }
    }

    /// At most maxProgressUpdates intermediate callbacks plus initial and terminal callbacks.
    /// Awaiting each callback provides backpressure rather than enqueuing unbounded UI tasks.
    /// nil skips an input; an empty String is a real block and retains its separator.
    func run(
        maxProgressUpdates: Int = 32,
        makeSink: @Sendable () throws -> any PseudocodeExportSink = { try PseudocodeExportSpool() },
        renderer: @escaping @Sendable (Item) throws -> String?,
        progress: @Sendable (Progress) async -> Void = { _ in }
    ) async throws -> Output {
        try lock.withLock {
            guard !hasStarted else {
                throw Failure.alreadyStarted
            }
            hasStarted = true
            // A pre-cancelled job still has one run and one cancellation terminal event.
            state = .running
        }
        var completed = 0
        let total = items.count
        let budget = max(1, maxProgressUpdates)
        let stride = max(1, total / budget + (total % budget == 0 ? 0 : 1))
        await progress(Progress(completed: 0, total: total, phase: .rendering))
        var sink: (any PseudocodeExportSink)?
        do {
            try checkCancellation()
            let spool = try makeSink()
            sink = spool
            lock.withLock { pendingSink = spool }
            var byteCount = 0
            var wroteBlock = false
            let separator = Data("\n\n".utf8)
            for item in items {
                try checkCancellation()
                if let block = try await PseudocodeRenderingThread.run({ try renderer(item) }) {
                    // Same bytes as `blocks.joined(separator: "\n\n")`, one block at a time.
                    if wroteBlock {
                        try spool.append(separator)
                        byteCount += separator.count
                    }
                    let data = Data(block.utf8)
                    try spool.append(data)
                    byteCount += data.count
                    wroteBlock = true
                }
                completed += 1
                try checkCancellation()
                if completed < total && completed % stride == 0 {
                    await progress(Progress(completed: completed, total: total, phase: .rendering))
                }
            }
            try checkCancellation()
            _ = try spool.finish()
            try lock.withLock {
                guard !cancellationRequested else { throw CancellationError() }
                state = .ready
            }
            await progress(Progress(completed: completed, total: total, phase: .completed))
            return Output(operationID: operationID, sink: spool, byteCount: byteCount)
        } catch {
            let cancelled = error is CancellationError
            lock.withLock {
                state = cancelled ? .cancelled : .failed
                pendingSink = nil
            }
            sink?.remove()
            await progress(Progress(completed: completed, total: total,
                                    phase: cancelled ? .cancelled : .failed))
            throw error
        }
    }

    /// Call on MainActor immediately after the live owner/window fence, with no intervening await.
    /// Publication is single-use. Cancellation linearizes before or after publication begins;
    /// once the commit starts, cancellation cannot undo it. The destination is replaced atomically
    /// (a prior file survives any failure) and the spool is removed either way.
    @MainActor
    func publish(_ output: Output, currentOwner: Owner, to destination: URL,
                 fileManager: FileManager = .default) throws {
        try lock.withLock {
            guard !cancellationRequested else { throw CancellationError() }
            guard owner == currentOwner else { throw Failure.staleOwner }
            guard state == .ready, output.operationID == operationID else { throw Failure.notPublishable }
            state = .publishing
            pendingSink = nil
        }
        defer { output.sink.remove() }
        do {
            try PseudocodeExportPublication.withStaging(for: destination, fileManager: fileManager) { staging in
                let staged = staging.appendingPathComponent("text")
                try fileManager.copyItem(at: output.sink.textURL, to: staged)
                // The spool is owner-only; the published file keeps the ordinary mode it had
                // when it was written with String.write.
                try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staged.path)
                try PseudocodeExportPublication.commit(staged, to: destination, fileManager: fileManager)
            }
            lock.withLock { state = .published }
        } catch {
            lock.withLock { state = .failed }
            throw error
        }
    }
}
