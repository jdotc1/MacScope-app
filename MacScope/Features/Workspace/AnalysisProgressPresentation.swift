import Foundation

/// HOP-3 analysis progress as the loading view and the toolbar show it. Phases report as they
/// start, so the fraction counts the phases already finished; nil progress is indeterminate.
struct AnalysisProgressPresentation: Equatable {
    /// 0...1, or nil while no phase has been reported (an older worker, the very start).
    let fraction: Double?
    let detail: String

    static let indeterminateDetail = "MacScope is parsing the selected target and preparing the current analysis view."

    init(_ progress: AnalysisProgress?) {
        guard let progress, progress.phase != .rehydrate else {
            fraction = nil
            detail = Self.indeterminateDetail
            return
        }
        let count = AnalysisPhase.analysisPhaseCount
        fraction = Double(progress.phase.ordinal - 1) / Double(count)
        detail = "Step \(progress.phase.ordinal) of \(count): \(Self.title(progress.phase))…"
    }

    static func title(_ phase: AnalysisPhase) -> String {
        switch phase {
        case .load: "Loading the binary"
        case .decode: "Decoding instructions"
        case .functionDiscovery: "Finding functions"
        case .listing: "Building the listing"
        case .jumpTables: "Resolving jump tables"
        case .controlFlow: "Tracing control flow"
        case .dataReferences: "Finding data references"
        case .switchHints: "Reading switch hints"
        case .diagnostics: "Collecting diagnostics"
        case .rehydrate: "Restoring the workspace"
        }
    }
}
