import Combine
import Foundation

/// Presentation-only authority: a snapshot emission is a new revision even when it
/// contains equal values. No equality walk, hashing, or store access occurs in body.
struct DisassemblyListingRequest: Sendable {
    let revision: UInt64
    let snapshot: WorkspaceSnapshot
    let slot: ImageSlot
    let encodingRaw: String

    var ownerBinaryID: UUID? { snapshot.binary(in: slot)?.id }
}

struct PreparedDisassemblyListing: Sendable {
    struct IndexedRow: Identifiable, Sendable {
        let index: Int
        let row: ListingRow
        var id: String { row.id }
    }

    let revision: UInt64
    let slot: ImageSlot
    let ownerBinaryID: UUID?
    let indexedRows: [IndexedRow]
    let resolved: [UInt64: DisassemblyListingBuilder.ResolvedInstruction]
    var branchLanes = DisassemblyBranchLanes.empty

    static let empty = PreparedDisassemblyListing(
        revision: 0, slot: .primary, ownerBinaryID: nil, indexedRows: [], resolved: [:]
    )

    static func prepare(_ request: DisassemblyListingRequest) throws -> Self {
        try Task.checkCancellation()
        let result = try MacScopePerformance.measure("Listing.prepare") {
            try DisassemblyListingBuilder.buildResolved(
                snapshot: request.snapshot,
                stringEncoding: StringDisplayEncoding.resolve(request.encodingRaw),
                slot: request.slot,
                checkCancellation: { try Task.checkCancellation() }
            )
        }
        var indexedRows: [IndexedRow] = []
        indexedRows.reserveCapacity(result.rows.count)
        for (index, row) in result.rows.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            indexedRows.append(IndexedRow(index: index, row: row))
        }
        try Task.checkCancellation()
        let analysis = request.snapshot.analysis(in: request.slot)
        let lanes = MacScopePerformance.measure("Listing.branchLanes") {
            DisassemblyBranchLanes.build(rows: result.rows, edges: analysis?.controlFlowEdges ?? [],
                                         functions: analysis?.functions ?? [])
        }
        try Task.checkCancellation()
        return Self(revision: request.revision, slot: request.slot,
                    ownerBinaryID: request.ownerBinaryID,
                    indexedRows: indexedRows, resolved: result.resolved, branchLanes: lanes)
    }
}

/// One running preparation and one replaceable pending request. A new request
/// cancels the active worker but waits for it to finish before launching another.
/// Thus even a noninterruptible sort cannot accumulate detached workers/snapshots.
@MainActor
final class DisassemblyListingCache: ObservableObject {
    typealias Worker = @Sendable (DisassemblyListingRequest) async throws -> PreparedDisassemblyListing

    @Published private(set) var listing = PreparedDisassemblyListing.empty
    private(set) var revision: UInt64 = 0
    private(set) var preparationCount = 0
    private var pending: DisassemblyListingRequest?
    private var active: Task<Void, Never>?
    private var latestSnapshot: WorkspaceSnapshot?
    private var slot: ImageSlot = .primary
    private var encodingRaw = StringDisplayEncoding.default.rawValue
    private let worker: Worker

    init(worker: Worker? = nil) {
        self.worker = worker ?? { request in
            try await DisassemblyListingCache.backgroundPrepare(request)
        }
    }

    /// Called by `$snapshot`, not `objectWillChange`: the published candidate is
    /// used directly because @Published emits before the store's value changes.
    func snapshotDidChange(_ snapshot: WorkspaceSnapshot, slot: ImageSlot, encodingRaw: String) {
        latestSnapshot = snapshot // Swift value/COW retention; no deep copy.
        self.slot = slot
        self.encodingRaw = encodingRaw
        enqueue(snapshot)
    }

    func presentationDidChange(slot: ImageSlot, encodingRaw: String) {
        guard self.slot != slot || self.encodingRaw != encodingRaw else { return }
        self.slot = slot
        self.encodingRaw = encodingRaw
        if let latestSnapshot { enqueue(latestSnapshot) }
    }

    func cancel() {
        revision += 1 // Also rejects workers whose cancellation is delayed/ignored.
        pending = nil
        latestSnapshot = nil
        active?.cancel()
    }

    private func enqueue(_ snapshot: WorkspaceSnapshot) {
        revision += 1
        let request = DisassemblyListingRequest(
            revision: revision, snapshot: snapshot, slot: slot, encodingRaw: encodingRaw
        )
        // Never render a previous owner's rows under a new slot/binary coordinate.
        // Same-owner revisions retain the stack/anchors while preparation is in flight.
        if listing.slot != request.slot || listing.ownerBinaryID != request.ownerBinaryID {
            listing = .empty
        }
        pending = request
        active?.cancel()
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard active == nil, let request = pending else { return }
        pending = nil
        preparationCount += 1
        let worker = worker
        active = Task { [weak self] in
            let result: PreparedDisassemblyListing?
            do { result = try await worker(request) }
            catch { result = nil }
            guard let self else { return }
            self.active = nil
            if let result, !Task.isCancelled,
               request.revision == self.revision,
               result.revision == request.revision,
               result.slot == self.slot,
               result.ownerBinaryID == request.ownerBinaryID {
                self.listing = result
            }
            self.startNextIfIdle()
        }
    }

    nonisolated private static func backgroundPrepare(
        _ request: DisassemblyListingRequest
    ) async throws -> PreparedDisassemblyListing {
        let task = Task.detached(priority: .userInitiated) {
            try PreparedDisassemblyListing.prepare(request)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
