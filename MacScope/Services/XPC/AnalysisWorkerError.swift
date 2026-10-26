import Foundation

/// Stable client-side failures from the out-of-process analysis worker.
///
/// Cancellation deliberately is not represented here: both in-process and XPC analysis reuse
/// the existing `AnalysisCancelled` marker so callers continue to treat cancellation as benign.
enum AnalysisWorkerError: Error, Equatable {
    case workerCrashed(reason: String)
    case workerUnavailable(reason: String)
    case malformedReply(reason: String)
    case versionMismatch(expected: Int, got: Int)
}

extension AnalysisWorkerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .workerCrashed(let reason):
            "The analysis worker crashed: \(reason)"
        case .workerUnavailable(let reason):
            "The analysis worker is unavailable: \(reason)"
        case .malformedReply(let reason):
            "The analysis worker returned a malformed reply: \(reason)"
        case .versionMismatch(let expected, let got):
            "The analysis worker protocol version is \(got); expected \(expected)."
        }
    }
}
