import Foundation

/// Budgeted in-process diagnostic/test path. The async API runs synchronous analysis on a
/// detached executor and folds caller cancellation into the existing cooperative token.
/// Production untrusted parsing remains in XPC; this wrapper does not change provider policy.
struct ResourceBudgetedAnalysisProvider: AnalysisProviding {
    let provider: any AnalysisProviding
    let budget: AnalysisResourceBudget
    private let hostResourceBudget: @Sendable () -> AnalysisResourceBudget

    init(provider: any AnalysisProviding, budget: AnalysisResourceBudget,
         hostResourceBudget: @escaping @Sendable () -> AnalysisResourceBudget = { .interactive }) {
        self.provider = provider
        self.budget = budget
        self.hostResourceBudget = hostResourceBudget
    }

    func analyze(url: URL, requestedSliceIndex: Int?, overrides: [UInt64: AddressOverride],
                 cancellation: AnalysisCancellationToken) throws -> WorkspaceSnapshot {
        try analyze(url: url, selection: .machOSlice(requestedSliceIndex),
            overrides: overrides, cancellation: cancellation)
    }

    func analyze(url: URL, selection: BinaryLoadSelection, overrides: [UInt64: AddressOverride],
                 cancellation: AnalysisCancellationToken) throws -> WorkspaceSnapshot {
        try AnalysisParallelism.withBudget(budget.clamped(to: hostResourceBudget())) {
            try provider.analyze(url: url, selection: selection, overrides: overrides, cancellation: cancellation)
        }
    }

    func openBinary(url: URL, requestedSliceIndex: Int?, overrides: [UInt64: AddressOverride],
                    cancellation: AnalysisCancellationToken) async throws -> WorkspaceSnapshot {
        try await openBinary(url: url, selection: .machOSlice(requestedSliceIndex),
            overrides: overrides, cancellation: cancellation)
    }

    func openBinary(url: URL, selection: BinaryLoadSelection, overrides: [UInt64: AddressOverride],
                    cancellation: AnalysisCancellationToken) async throws -> WorkspaceSnapshot {
        if Task.isCancelled || cancellation.isCancelled { throw AnalysisCancelled() }
        let signal = AnalysisResourceCancellationSignal()
        let folded = AnalysisCancellationToken { signal.isCancelled || cancellation.isCancelled }
        let task = Task.detached { try analyze(url: url, selection: selection,
            overrides: overrides, cancellation: folded) }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { signal.cancel() }
            let snapshot = try await task.value
            if signal.isCancelled || cancellation.isCancelled { throw AnalysisCancelled() }
            return snapshot
        } onCancel: { signal.cancel() }
    }

    func rehydrate(imageBytes: Data, requestedSliceIndex: Int?, preserving persisted: ImageAnalysis,
                   cancellation: AnalysisCancellationToken) throws -> ImageAnalysis {
        try rehydrate(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
            preserving: persisted, overrides: [:], cancellation: cancellation)
    }

    func rehydrate(imageBytes: Data, requestedSliceIndex: Int?, preserving persisted: ImageAnalysis,
                   overrides: [UInt64: AddressOverride], cancellation: AnalysisCancellationToken) throws -> ImageAnalysis {
        try AnalysisParallelism.withBudget(budget.clamped(to: hostResourceBudget())) {
            try provider.rehydrate(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
                preserving: persisted, overrides: overrides, cancellation: cancellation)
        }
    }

    func rehydrate(imageBytes: Data, requestedSliceIndex: Int?, preserving persisted: ImageAnalysis,
                   overrides: [UInt64: AddressOverride], coffSectionLayoutVersion: Int?,
                   cancellation: AnalysisCancellationToken) throws -> ImageAnalysis {
        try AnalysisParallelism.withBudget(budget.clamped(to: hostResourceBudget())) {
            try provider.rehydrate(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
                preserving: persisted, overrides: overrides, coffSectionLayoutVersion: coffSectionLayoutVersion,
                cancellation: cancellation)
        }
    }

}

private final class AnalysisResourceCancellationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
