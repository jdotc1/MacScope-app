import SwiftUI
import LumenUI

/// One presentable row in the Problems panel — a pure projection of an `AnalysisDiagnostic`
/// into the text/icon/color the view renders. Keeping the projection here (not in the view)
/// matches the NavigationHistory pattern: the view is a dumb `ForEach` over these rows.
struct ProblemRow: Identifiable, Hashable {
    let id: String
    let address: UInt64
    let addressText: String
    let title: String
    let message: String
    let severity: AnalysisDiagnostic.Severity

    /// SF Symbol for the severity (filled, so it reads at small sizes and in high contrast).
    var iconSystemName: String {
        switch severity {
        case .error: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        }
    }

    /// Semantic color for the severity. System red/orange so Light/Dark/high-contrast and
    /// the accessibility "increase contrast" setting are all handled by the platform.
    var iconColor: Color {
        switch severity {
        case .error: Color.lumen(.statusDanger)
        case .warning: Color.lumen(.statusWarning)
        }
    }

    /// VoiceOver word for the severity.
    var severityLabel: String {
        switch severity {
        case .error: "Error"
        case .warning: "Warning"
        }
    }

    init(diagnostic: AnalysisDiagnostic) {
        self.id = diagnostic.id
        self.address = diagnostic.address
        self.addressText = diagnostic.addressText
        self.title = diagnostic.kind.title
        self.message = diagnostic.message
        self.severity = diagnostic.severity
    }
}

/// Projects the store's diagnostics into `ProblemRow`s and summarizes the counts. Pure and
/// `struct`-valued — built fresh from the diagnostics on each render, holding no state — so
/// it is trivially unit-testable without the view or a live store.
struct ProblemsViewModel {
    /// One loaded image's problems.
    struct ImageSection: Identifiable {
        let slot: ImageSlot
        let title: String
        let rows: [ProblemRow]
        var id: ImageSlot { slot }
    }

    let sections: [ImageSection]
    var rows: [ProblemRow] { sections.flatMap(\.rows) }

    /// One image's diagnostics, untitled (a single-image workspace shows no image headers).
    init(diagnostics: [AnalysisDiagnostic], slot: ImageSlot = .primary) {
        sections = diagnostics.isEmpty ? [] : [ImageSection(slot: slot, title: "", rows: diagnostics.map(ProblemRow.init))]
    }

    /// Every loaded image's diagnostics, grouped by image in slot order and titled with the
    /// image's name. Images without problems are left out.
    init(snapshot: WorkspaceSnapshot) {
        sections = snapshot.analysisBySlot.keys.sorted().compactMap { slot in
            guard let diagnostics = snapshot.analysis(in: slot)?.diagnostics, !diagnostics.isEmpty else { return nil }
            return ImageSection(slot: slot, title: snapshot.binary(in: slot)?.name ?? "Image",
                                rows: diagnostics.map(ProblemRow.init))
        }
    }

    /// Image headers show only when more than one image has problems.
    var showsImageHeaders: Bool { sections.count > 1 }

    var isEmpty: Bool { rows.isEmpty }
    var errorCount: Int { rows.lazy.filter { $0.severity == .error }.count }
    var warningCount: Int { rows.lazy.filter { $0.severity == .warning }.count }

    /// A short "3 errors, 1 warning" summary for the header / VoiceOver. Pluralized and
    /// omits a zero category; "No problems" when empty.
    var summary: String {
        guard !isEmpty else { return "No problems" }
        var parts: [String] = []
        if errorCount > 0 { parts.append("\(errorCount) " + (errorCount == 1 ? "error" : "errors")) }
        if warningCount > 0 { parts.append("\(warningCount) " + (warningCount == 1 ? "warning" : "warnings")) }
        return parts.joined(separator: ", ")
    }
}
