import Combine
import Foundation

/// Window-owned investigation state. Results remain transient and are bound to
/// the captured workspace, exact image owners and authored/document revision.
@MainActor
final class RetainedFindModel: ObservableObject {
    struct Context: Equatable, Sendable {
        let workspaceOwner: ObjectIdentifier
        let workspaceID: UUID
        let documentID: UUID
        let revision: UInt64
        let imageOwners: [ImageSlot: UUID]
        let analysisFingerprints: [ImageSlot: String]
        let focusedSlot: ImageSlot
        let scope: BinarySearchScope
    }
    typealias Worker = @Sendable (String, BinarySearchMode, WorkspaceSnapshot, BinarySearchScope) async -> BinarySearchService.BoundedOutcome

    @Published var query = "" { didSet { if query != oldValue { invalidate() } } }
    @Published var mode: BinarySearchMode = .text { didSet { if mode != oldValue { invalidate() } } }
    @Published private(set) var results: [BinarySearchResult] = []
    @Published private(set) var lowerBound = 0
    @Published private(set) var isTruncated = false
    @Published private(set) var hasSearched = false
    @Published private(set) var isSearching = false
    @Published private(set) var publicationID: UUID?
    private(set) var context: Context?
    private(set) var cursor: SearchResultCursor?
    private var scope = BinarySearchScope.everything
    private var snapshot: WorkspaceSnapshot?
    private var requestID = UUID()
    private var workerTask: Task<BinarySearchService.BoundedOutcome, Never>?
    private var publicationTask: Task<Void, Never>?
    private let worker: Worker
    private weak var boundStore: WorkspaceStore?

    init(worker: @escaping Worker = { query, mode, snapshot, scope in
        BinarySearchService().searchBounded(query: query, mode: mode, in: snapshot, scope: scope)
    }) { self.worker = worker }

    var validationMessage: String? {
        if query.utf8.count > 256 { return "Find queries are limited to 256 UTF-8 bytes." }
        return BinarySearchService().validate(query: query, mode: mode)
    }

    static func makeContext(workspaceOwner: ObjectIdentifier, workspaceID: UUID, documentID: UUID,
                            snapshot: WorkspaceSnapshot, revision: UInt64,
                            focusedSlot: ImageSlot, scope: BinarySearchScope) -> Context {
        Context(workspaceOwner: workspaceOwner, workspaceID: workspaceID, documentID: documentID, revision: revision,
                           imageOwners: Dictionary(uniqueKeysWithValues: snapshot.binaries.map { ($0.slot, $0.id) }),
                           analysisFingerprints: Dictionary(uniqueKeysWithValues: snapshot.analysisBySlot.map {
                               ($0.key, $0.value.analysisInputFingerprint?.overallSHA256 ?? "unavailable")
                           }),
                           focusedSlot: scope.images == .focused ? focusedSlot : .primary, scope: scope)
    }

    /// One root-level onChange identity covers logical document, store, image,
    /// analysis, authoring revision and relevant search scope.
    func bindingIdentity(for store: WorkspaceStore) -> Context {
        Self.makeContext(workspaceOwner: ObjectIdentifier(store), workspaceID: store.workspaceID,
                         documentID: store.documentID, snapshot: store.snapshot,
                         revision: store.mutationGeneration.rawValue, focusedSlot: store.focusedImageSlot, scope: scope)
    }

    func bind(store: WorkspaceStore) {
        boundStore = store
        bind(workspaceOwner: ObjectIdentifier(store), workspaceID: store.workspaceID, documentID: store.documentID,
             snapshot: store.snapshot, revision: store.mutationGeneration.rawValue,
             focusedSlot: store.focusedImageSlot, scope: scope)
    }

    func bind(workspaceOwner: ObjectIdentifier, workspaceID: UUID, documentID: UUID,
              snapshot: WorkspaceSnapshot, revision: UInt64, focusedSlot: ImageSlot, scope: BinarySearchScope) {
        let next = Self.makeContext(workspaceOwner: workspaceOwner, workspaceID: workspaceID, documentID: documentID,
                                    snapshot: snapshot, revision: revision, focusedSlot: focusedSlot, scope: scope)
        let changed = context != next || self.scope != scope
        let replaced = context.map {
            $0.workspaceOwner != workspaceOwner || $0.workspaceID != workspaceID || $0.documentID != documentID
        } ?? false
        self.snapshot = snapshot
        self.scope = scope
        if changed { invalidate() }
        context = next
        if replaced { query = ""; mode = .text }
    }

    func search(selecting selected: ImageAddress?) {
        invalidate()
        hasSearched = true
        guard validationMessage == nil, let snapshot, let context,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = true
        let capturedQuery = query
        let capturedMode = mode
        var capturedScope = scope
        capturedScope.focusedSlot = context.focusedSlot
        let workerScope = capturedScope
        let token = requestID
        let worker = worker
        let task = Task.detached(priority: .userInitiated) {
            await worker(capturedQuery, capturedMode, snapshot, workerScope)
        }
        workerTask = task
        publicationTask = Task { [weak self] in
            let outcome = await task.value
            guard let self, !Task.isCancelled, !outcome.isCancelled,
                  self.requestID == token, self.context == context,
                  self.query == capturedQuery, self.mode == capturedMode else { return }
            self.results = outcome.results
            self.lowerBound = outcome.lowerBound
            self.isTruncated = outcome.isTruncated
            self.cursor = outcome.results.isEmpty ? nil : SearchResultCursor(results: outcome.results, selecting: selected)
            self.isSearching = false
            self.publicationID = UUID()
        }
    }

    func admits(_ result: BinarySearchResult, workspaceOwner: ObjectIdentifier, workspaceID: UUID, documentID: UUID,
                snapshot: WorkspaceSnapshot, revision: UInt64) -> Bool {
        guard context?.workspaceOwner == workspaceOwner, context?.workspaceID == workspaceID,
              context?.documentID == documentID, context?.revision == revision,
              results.contains(result), let owner = context?.imageOwners[result.imageSlot] else { return false }
        return snapshot.binary(in: result.imageSlot)?.id == owner
    }

    func select(_ result: BinarySearchResult) {
        cursor = SearchResultCursor(results: results, selecting: ImageAddress(slot: result.imageSlot, address: result.address))
    }

    func seedCursor(in store: WorkspaceStore, selecting target: ImageAddress? = nil) {
        guard context == bindingIdentity(for: store), let authority = cursorAuthority,
              !results.isEmpty else { return }
        boundStore = store
        store.searchCursor = SearchResultCursor(results: results, selecting: target,
                                               retainedFindAuthority: authority)
    }

    private var cursorAuthority: SearchResultCursor.RetainedFindAuthority? {
        guard let context, let publicationID else { return nil }
        return .init(publicationID: publicationID, workspaceOwner: context.workspaceOwner,
                     workspaceID: context.workspaceID, documentID: context.documentID, revision: context.revision,
                     imageOwners: context.imageOwners, analysisFingerprints: context.analysisFingerprints,
                     focusedSlot: context.focusedSlot, scope: context.scope)
    }

    func cancel() { invalidate() }

    private func invalidate() {
        // Retire only this publication's exact cursor, including when the
        // sheet observes invalidation before the root binding callback. A
        // separately seeded cursor remains another investigation's authority.
        if let boundStore, context?.workspaceOwner == ObjectIdentifier(boundStore),
           let authority = cursorAuthority,
           boundStore.searchCursor?.retainedFindAuthority == authority {
            boundStore.seedSearchCursor([])
        }
        requestID = UUID()
        workerTask?.cancel()
        publicationTask?.cancel()
        workerTask = nil
        publicationTask = nil
        results = []
        lowerBound = 0
        isTruncated = false
        hasSearched = false
        isSearching = false
        cursor = nil
        publicationID = nil
    }
}
