import Combine
import Foundation

/// One sheet's cancellable work, owned by NativePseudocodeActionRouter.sheet.
/// It is not a workspace/global registry and owns no canonical analysis state.
@MainActor
final class NativeValueNavigationSession: ObservableObject {
    enum Phase: Equatable, Sendable {
        case loading
        case candidates(NativeValueNavigationCandidates)
        case report(NativeValueNavigationCandidate, NativeValueNavigationReport)
        case unavailable(String)
        case invalidated
    }
    typealias IndexBuilder = @Sendable (
        NativeDecompilerWireStructuredResult, NativeValueNavigationLimits
    ) async throws -> NativeValueNavigationIndex

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var direction: NativeValueNavigationDirection
    // Rows are query-local: retaining their integer IDs must not rebind a later report.
    private(set) var reportID: UUID?
    let capture: NativeValueNavigationCapture
    private let limits: NativeValueNavigationLimits
    private let currentScope: @MainActor () -> NativePseudocodeActionScope?
    private let navigate: @MainActor (ImageAddress) -> Bool
    private let onNavigated: @MainActor () -> Void
    private let buildIndex: IndexBuilder
    private var index: NativeValueNavigationIndex?
    private var selection: NativeValueNavigationCandidates?
    private var selectedCandidate: NativeValueNavigationCandidate?
    private var activeWorkID: UUID?
    private(set) var task: Task<Void, Never>?
    private var didStart = false

    init(
        capture: NativeValueNavigationCapture,
        direction: NativeValueNavigationDirection,
        limits: NativeValueNavigationLimits = .init(),
        currentScope: @escaping @MainActor () -> NativePseudocodeActionScope?,
        navigate: @escaping @MainActor (ImageAddress) -> Bool,
        onNavigated: @escaping @MainActor () -> Void = {},
        buildIndex: @escaping IndexBuilder = { result, limits in
            try NativeValueNavigationIndex(result: result, limits: limits)
        }
    ) {
        self.capture = capture
        self.direction = direction
        self.limits = limits
        self.currentScope = currentScope
        self.navigate = navigate
        self.onNavigated = onNavigated
        self.buildIndex = buildIndex
    }

    deinit { task?.cancel() }

    private struct InitialOutput: Sendable {
        let index: NativeValueNavigationIndex
        let candidates: NativeValueNavigationCandidates
        let automaticReport: NativeValueNavigationReport?
    }

    func start() {
        guard !didStart, phase != .invalidated else { return }
        didStart = true
        guard capture.matches(currentScope()) else { invalidate(); return }
        let captured = capture
        let direction = direction
        let limits = limits
        let builder = buildIndex
        launch(operation: {
            let index = try await builder(captured.result, limits)
            let candidates = try index.candidates(forTokenID: captured.tokenID)
            let automaticReport: NativeValueNavigationReport?
            if !candidates.requiresChoice, let candidate = candidates.candidates.first {
                automaticReport = try index.query(seedValueID: candidate.id, direction: direction)
            } else {
                automaticReport = nil
            }
            return InitialOutput(index: index, candidates: candidates, automaticReport: automaticReport)
        }, apply: { session, output in
            session.index = output.index
            session.selection = output.candidates
            if let report = output.automaticReport,
               let candidate = output.candidates.candidates.first {
                session.selectedCandidate = candidate
                session.reportID = UUID()
                session.phase = .report(candidate, report)
            } else if output.candidates.candidates.isEmpty {
                session.phase = .unavailable(output.candidates.explanation)
            } else {
                session.phase = .candidates(output.candidates)
            }
        })
    }

    func choose(valueID: String) {
        guard capture.matches(currentScope()), let selection, let index,
              case .candidates = phase,
              let candidate = selection.candidates.first(where: { $0.id == valueID }) else { return }
        selectedCandidate = candidate
        run(index: index, candidate: candidate)
    }

    func changeDirection(_ newDirection: NativeValueNavigationDirection) {
        guard newDirection != direction else { return }
        guard capture.matches(currentScope()) else { invalidate(); return }
        direction = newDirection
        if let index, let selectedCandidate {
            run(index: index, candidate: selectedCandidate)
        }
        // Candidate-only state changes direction without rebuilding the index.
        // The view disables this control during the first index build.
    }

    func chooseAnotherValue() {
        guard capture.matches(currentScope()), let selection else { invalidate(); return }
        task?.cancel()
        task = nil
        activeWorkID = nil
        selectedCandidate = nil
        reportID = nil
        phase = .candidates(selection)
    }

    func reveal(rowID: Int, sourceIndex: Int, reportID: UUID?) {
        guard let reportID, reportID == self.reportID,
              case let .report(_, report) = phase,
              let target = capture.target(
                rowID: rowID, sourceIndex: sourceIndex, report: report, currentScope: currentScope()
              ) else {
            if !capture.matches(currentScope()) { invalidate() }
            return
        }
        if navigate(target) {
            invalidate()
            onNavigated()
        }
    }

    func reconcile() {
        if !capture.matches(currentScope()) { invalidate() }
    }

    func invalidate() {
        activeWorkID = nil
        task?.cancel()
        task = nil
        index = nil
        selection = nil
        selectedCandidate = nil
        reportID = nil
        phase = .invalidated
    }

    private func run(
        index: NativeValueNavigationIndex, candidate: NativeValueNavigationCandidate
    ) {
        let direction = direction
        launch(operation: {
            try index.query(seedValueID: candidate.id, direction: direction)
        }, apply: { session, report in
            session.reportID = UUID()
            session.phase = .report(candidate, report)
        })
    }

    /// The child task is explicitly cancelled with the UI task. Work-ID and the
    /// full publication identity must both still match before any result appears.
    /// This also rejects A -> B -> A switches and same-request cache republication.
    private func launch<Output: Sendable>(
        operation: @escaping @Sendable () async throws -> Output,
        apply: @escaping @MainActor (NativeValueNavigationSession, Output) -> Void
    ) {
        task?.cancel()
        let workID = UUID()
        activeWorkID = workID
        reportID = nil
        phase = .loading
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try await operation() }
            do {
                let output = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.activeWorkID == workID else { return }
                guard self.capture.matches(self.currentScope()) else { self.invalidate(); return }
                self.task = nil
                apply(self, output)
            } catch is CancellationError {
                // A superseding action owns its own phase; an obsolete worker
                // cannot overwrite it with an error or a partial result.
                guard let self, self.activeWorkID == workID else { return }
                self.invalidate()
            } catch {
                guard !Task.isCancelled, let self, self.activeWorkID == workID else { return }
                guard self.capture.matches(self.currentScope()) else { self.invalidate(); return }
                self.task = nil
                self.phase = .unavailable(Self.message(for: error))
            }
        }
    }

    private static func message(for error: Error) -> String {
        guard let failure = error as? NativeValueNavigationFailure else {
            return "Value navigation could not read this native publication."
        }
        return switch failure {
        case .noStructuredValues:
            "This publication does not include a structured SSA graph."
        case .indexLimit:
            "This function exceeds the value-navigation index budget."
        case .invalidLimits:
            "Value-navigation limits are invalid."
        case .unknownToken, .unknownValue, .invalidSelection:
            "The selected token or value is no longer available."
        case .duplicateRecord, .missingReference, .invalidBinding, .invalidSourceRange:
            "The native records do not satisfy the value-navigation query contract."
        }
    }
}
