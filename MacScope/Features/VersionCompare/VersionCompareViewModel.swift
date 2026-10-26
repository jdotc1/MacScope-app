import Combine
import Foundation

/// Window-owned state for Compare Images (roadmap M8): pairs the functions of two images already
/// loaded in the same workspace. Fingerprinting and matching run off the main actor; every
/// publication is fenced by a generation token so a stale selection can never publish. Nothing
/// here is persisted — manual pins live only as long as the published comparison.
@MainActor
final class VersionCompareViewModel: ObservableObject {
    typealias Worker = @Sendable (ImageAnalysis, ImageAnalysis) async throws -> VersionCompareComputation
    typealias Resolver = @Sendable (FunctionVersionMatcher, FunctionVersionMatchResult, FunctionVersionManualPin)
        async throws -> FunctionVersionMatchResult

    enum Phase: Equatable {
        /// Fewer than two analyzed images are loaded.
        case unavailable
        /// Two images are available but no comparison is selected/published.
        case idle
        case running
        case ready
        case failed(String)
    }

    @Published private(set) var images: [VersionCompareImage] = []
    @Published private(set) var oldSlot: ImageSlot?
    @Published private(set) var newSlot: ImageSlot?
    @Published private(set) var phase: Phase = .unavailable
    @Published private(set) var report: VersionCompareReport?
    @Published private(set) var isPinning = false
    @Published private(set) var pinError: String?
    @Published var filter: VersionCompareFilter = .all
    @Published var searchText = ""
    /// RX-01: the open annotation-transfer review (nil when closed). Never outlives the comparison.
    @Published private(set) var transferReview: AnnotationTransferReview?
    /// RX-01: the last Apply's outcome, shown as a banner until dismissed or the comparison changes.
    @Published private(set) var transferOutcome: AnnotationTransferCommitOutcome?

    /// The exact pair and computation behind `report` (nil while running or unavailable).
    private(set) var comparedPair: VersionComparePair?
    private(set) var computation: VersionCompareComputation?
    /// The pair of the in-flight or published comparison; `bind` recomputes only when the
    /// selection no longer names it.
    private var requestedPair: VersionComparePair?

    private var snapshot: WorkspaceSnapshot?
    /// The workspace state the open review's candidates and preview were read from.
    private var transferSnapshot: WorkspaceSnapshot?
    private var generation: UInt64 = 0
    private var publicationTask: Task<Void, Never>?
    private var cancelWorkerJob: (() -> Void)?
    private let worker: Worker
    private let resolver: Resolver

    init(worker: @escaping Worker = { old, new in try VersionCompareComputation.build(old: old, new: new) },
         resolver: @escaping Resolver = { matcher, result, pin in try matcher.resolve(result, pinning: pin) }) {
        self.worker = worker
        self.resolver = resolver
    }

    // MARK: - Availability

    /// Every loaded image that has an analysis bucket, in slot order.
    static func images(in snapshot: WorkspaceSnapshot) -> [VersionCompareImage] {
        snapshot.binaries.sorted { $0.slot < $1.slot }.compactMap { binary in
            guard let analysis = snapshot.analysis(in: binary.slot) else { return nil }
            return VersionCompareImage(slot: binary.slot, binaryID: binary.id, name: binary.name,
                                       analysisFingerprint: analysis.analysisInputFingerprint?.overallSHA256)
        }
    }

    /// The menu command's enablement rule: at least two analyzed images in the workspace.
    static func isAvailable(in snapshot: WorkspaceSnapshot) -> Bool {
        images(in: snapshot).count >= 2
    }

    var isAvailable: Bool { images.count >= 2 }

    var selectedPair: VersionComparePair? {
        guard let old = image(at: oldSlot), let new = image(at: newSlot), old.slot != new.slot else { return nil }
        return VersionComparePair(old: old, new: new)
    }

    func image(at slot: ImageSlot?) -> VersionCompareImage? {
        guard let slot else { return nil }
        return images.first { $0.slot == slot }
    }

    // MARK: - Binding and selection

    /// Adopts the workspace's current images. Keeps a still-valid selection, defaults to the first
    /// two images, and recomputes only when the selected pair's identity changed.
    func bind(to snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        images = Self.images(in: snapshot)
        guard isAvailable else {
            invalidate()
            oldSlot = nil
            newSlot = nil
            phase = .unavailable
            return
        }
        if image(at: oldSlot) == nil { oldSlot = images.first?.slot }
        if image(at: newSlot) == nil || newSlot == oldSlot {
            newSlot = images.first { $0.slot != oldSlot }?.slot
        }
        if selectedPair != requestedPair { run() }
    }

    func selectOld(_ slot: ImageSlot) {
        guard image(at: slot) != nil, slot != oldSlot else { return }
        if slot == newSlot { newSlot = oldSlot }
        oldSlot = slot
        run()
    }

    func selectNew(_ slot: ImageSlot) {
        guard image(at: slot) != nil, slot != newSlot else { return }
        if slot == oldSlot { oldSlot = newSlot }
        newSlot = slot
        run()
    }

    func swapImages() {
        guard oldSlot != nil, newSlot != nil else { return }
        (oldSlot, newSlot) = (newSlot, oldSlot)
        run()
    }

    // MARK: - Running

    /// Recomputes the selected pair from scratch (manual pins are discarded). Any in-flight
    /// comparison or pin resolution is cancelled and can no longer publish.
    func run() {
        invalidate()
        guard let pair = selectedPair, let snapshot,
              let oldAnalysis = snapshot.analysis(in: pair.old.slot),
              let newAnalysis = snapshot.analysis(in: pair.new.slot),
              snapshot.binary(in: pair.old.slot)?.id == pair.old.binaryID,
              snapshot.binary(in: pair.new.slot)?.id == pair.new.binaryID else {
            phase = isAvailable ? .idle : .unavailable
            return
        }
        phase = .running
        requestedPair = pair
        let token = generation
        let worker = worker
        let job = Task.detached(priority: .userInitiated) {
            try await worker(oldAnalysis, newAnalysis)
        }
        cancelWorkerJob = { job.cancel() }
        publicationTask = Task { [weak self] in
            let outcome: Result<VersionCompareComputation, any Error>
            do { outcome = .success(try await job.value) } catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.cancelWorkerJob = nil
            switch outcome {
            case .success(let computation):
                self.computation = computation
                self.comparedPair = pair
                self.report = computation.report
                self.phase = .ready
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Cancels in-flight work without discarding a published comparison.
    func cancel() {
        let wasRunning = phase == .running
        generation &+= 1
        cancelInFlight()
        isPinning = false
        if wasRunning {
            requestedPair = nil
            phase = isAvailable ? .idle : .unavailable
        }
    }

    // MARK: - Manual resolution

    /// Pins `oldID` ↔ `newID` and recomputes every automatic phase with the accumulated pins.
    /// Only valid against the currently published comparison.
    func pin(oldID: String, newID: String) {
        guard phase == .ready, !isPinning, let computation, let pair = comparedPair else { return }
        generation &+= 1
        cancelInFlight()
        let token = generation
        isPinning = true
        pinError = nil
        let resolver = resolver
        let matcher = computation.matcher
        let result = computation.result
        let pin = FunctionVersionManualPin(oldID: oldID, newID: newID)
        let job = Task.detached(priority: .userInitiated) {
            try await resolver(matcher, result, pin)
        }
        cancelWorkerJob = { job.cancel() }
        publicationTask = Task { [weak self] in
            let outcome: Result<FunctionVersionMatchResult, any Error>
            do { outcome = .success(try await job.value) } catch { outcome = .failure(error) }
            guard let self, !Task.isCancelled, self.generation == token,
                  self.comparedPair == pair, let current = self.computation else { return }
            self.cancelWorkerJob = nil
            self.isPinning = false
            switch outcome {
            case .success(let resolved):
                let next = current.replacingResult(resolved)
                self.computation = next
                self.report = next.report
                self.discardTransferReview()
            case .failure(let error):
                self.pinError = error.localizedDescription
            }
        }
    }

    func clearPinError() { pinError = nil }

    // MARK: - Annotation transfer (RX-01)

    /// True when a review can open: a published, current comparison of two still-loaded images.
    var canBeginTransferReview: Bool { phase == .ready && computation != nil && comparedPair != nil && !isPinning }

    /// Opens the review for the published comparison (old → new), reading authored names and
    /// comments from `snapshot`. Preselects only `high` and `userConfirmed` pairs (D7). Refuses
    /// (returns false) when the snapshot no longer holds the compared images or analyses.
    @discardableResult
    func beginTransferReview(snapshot: WorkspaceSnapshot) -> Bool {
        guard canBeginTransferReview, let computation, let pair = comparedPair,
              Self.holds(pair, in: snapshot) else { return false }
        let candidates = AnnotationTransferCandidates.build(
            result: computation.result, oldSlot: pair.old.slot, newSlot: pair.new.slot, snapshot: snapshot)
        let selected = AnnotationTransferCandidates.defaultSelection(candidates)
        transferSnapshot = snapshot
        transferOutcome = nil
        transferReview = AnnotationTransferReview(
            pair: pair, candidates: candidates, selected: selected,
            unresolvedGroupCount: computation.result.unresolved.count,
            preview: Self.plan(candidates, selected: selected, pair: pair, snapshot: snapshot))
        return true
    }

    /// Rebuilds candidates and the preview from the current workspace (after a refusal), keeping
    /// the user's selection for rows that still exist and are not skipped.
    @discardableResult
    func rebuildTransferPreview(snapshot: WorkspaceSnapshot) -> Bool {
        guard let previous = transferReview else { return false }
        guard beginTransferReview(snapshot: snapshot), let review = transferReview else {
            discardTransferReview()
            return false
        }
        updateTransferSelection(previous.selected.intersection(review.selectableIDs))
        return true
    }

    func setTransferSelection(_ id: String, selected: Bool) {
        guard var ids = transferReview?.selected else { return }
        if selected { ids.insert(id) } else { ids.remove(id) }
        updateTransferSelection(ids)
    }

    /// Every row that is not skipped, whatever its confidence (each row shows its confidence).
    func selectAllTransferCandidates() {
        guard let review = transferReview else { return }
        updateTransferSelection(review.selectableIDs)
    }

    /// The default selection: `high` and `userConfirmed` pairs only.
    func selectHighConfidenceTransferCandidates() {
        guard let review = transferReview else { return }
        updateTransferSelection(AnnotationTransferCandidates.defaultSelection(review.candidates))
    }

    func clearTransferSelection() { updateTransferSelection([]) }

    /// Commits the reviewed plan through the store's one-undo bulk path. The store re-validates
    /// images, analyses and every examined annotation first. Applied or nothing-to-apply closes the
    /// review; a refusal keeps it open so the user can rebuild the preview.
    @discardableResult
    func applyTransfer(in store: WorkspaceStore) -> AnnotationTransferCommitOutcome? {
        guard let review = transferReview, let plan = review.plan,
              review.pair == comparedPair else { return nil }
        let outcome = store.commitAnnotationTransfer(.init(pair: review.pair, preview: plan))
        transferOutcome = outcome
        if !outcome.isRefused { discardTransferReview() }
        return outcome
    }

    func dismissTransferReview() { discardTransferReview() }

    func clearTransferOutcome() { transferOutcome = nil }

    private func updateTransferSelection(_ ids: Set<String>) {
        guard var review = transferReview, let snapshot = transferSnapshot else { return }
        review.selected = ids.intersection(review.selectableIDs)
        review.preview = Self.plan(review.candidates, selected: review.selected, pair: review.pair, snapshot: snapshot)
        transferReview = review
    }

    private func discardTransferReview() {
        transferReview = nil
        transferSnapshot = nil
    }

    private static func plan(_ candidates: [AnnotationTransferCandidate], selected: Set<String>,
                             pair: VersionComparePair,
                             snapshot: WorkspaceSnapshot) -> Result<AnnotationTransferPreview, AnnotationTransferError> {
        do {
            return .success(try AnnotationTransferCandidates.preview(
                candidates, selected: selected, oldSlot: pair.old.slot, newSlot: pair.new.slot, snapshot: snapshot))
        } catch let error as AnnotationTransferError {
            return .failure(error)
        } catch {
            return .failure(.pairLimitExceeded(0))
        }
    }

    /// The snapshot still holds both compared owners with the analyses the comparison used.
    private static func holds(_ pair: VersionComparePair, in snapshot: WorkspaceSnapshot) -> Bool {
        [pair.old, pair.new].allSatisfy { image in
            snapshot.binary(in: image.slot)?.id == image.binaryID
                && snapshot.analysis(in: image.slot).map {
                    $0.analysisInputFingerprint?.overallSHA256 == image.analysisFingerprint
                } == true
        }
    }

    // MARK: - Navigation

    /// A navigable function captured from a rendered row: the exact image owner plus the function.
    struct NavigationTarget: Hashable, Sendable {
        let image: VersionCompareImage
        let function: VersionCompareFunctionRef
    }

    enum Side { case old, new }

    func navigationTarget(for function: VersionCompareFunctionRef?, side: Side) -> NavigationTarget? {
        guard let function, function.address != nil, let pair = comparedPair else { return nil }
        return NavigationTarget(image: side == .old ? pair.old : pair.new, function: function)
    }

    /// Focuses the target's image and selects the function, through the store's image-qualified
    /// Go-to path. Rejected (returns false) once the image was replaced or the function is gone.
    @discardableResult
    static func navigate(to target: NavigationTarget, in store: WorkspaceStore) -> Bool {
        guard let address = target.function.address,
              store.snapshot.binary(in: target.image.slot)?.id == target.image.binaryID,
              let analysis = store.snapshot.analysis(in: target.image.slot),
              analysis.functions.contains(where: {
                  $0.id.uuidString == target.function.id && $0.startAddress == address
              }) else {
            return false
        }
        return store.goToAddress(address, in: target.image.slot)
    }

    // MARK: - Private

    /// Retires every in-flight publication and the published comparison.
    private func invalidate() {
        generation &+= 1
        cancelInFlight()
        isPinning = false
        pinError = nil
        computation = nil
        comparedPair = nil
        requestedPair = nil
        report = nil
        discardTransferReview()
        transferOutcome = nil
    }

    private func cancelInFlight() {
        cancelWorkerJob?()
        cancelWorkerJob = nil
        publicationTask?.cancel()
        publicationTask = nil
    }
}
