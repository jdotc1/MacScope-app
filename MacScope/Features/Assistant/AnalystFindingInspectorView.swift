import SwiftUI
import LumenUI

struct AnalystFindingSelection: Identifiable { let id: UUID }

/// Uses the existing document owner. Editor text is local until Apply; review is a separate
/// explicit action against the displayed revision. Refresh never silently overwrites a draft.
struct AnalystFindingInspectorView: View {
    @ObservedObject var store: WorkspaceStore
    let findingID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var token: AnalystFindingEditToken?
    @State private var text = ""
    @State private var decision: AnalystFindingReviewDecision = .reviewed
    @State private var retractionReason = ""
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            HStack {
                Text("Authored Finding").fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
            }
            if let record = store.analystFindings.records.first(where: { $0.id == findingID }) {
                let lifecycle = record.authoredLifecycle
                let isCurrent = token != nil && token == (try? store.analystFindingEditToken(for: findingID))
                ScrollView {
                    VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                        AnalystFindingStandingView(standing: record.standing)
                        AnalystFindingReviewStatus(lifecycle: lifecycle)
                        Text("Reviews apply to authored interpretation. Source freshness has not been established.")
                            .foregroundStyle(.secondary)
                        if !isCurrent {
                            Text("This finding or document changed. Reload before applying an edit or review.")
                                .foregroundStyle(.secondary)
                        }
                        TextEditor(text: $text).frame(minHeight: AppLayout.analystFindingEditorMinimumHeight)
                            .padding(Lumen.Space.s3)
                            .background(Color.lumen(.bgElevated), in: RoundedRectangle(cornerRadius: Lumen.Radius.sm))
                        HStack {
                            Button("Apply Text Edit") { applyEdit() }
                                .disabled(!isCurrent || record.standing.isRetracted || text == record.authoredText
                                          || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Reload Finding Text") { reload() }
                        }
                        HStack {
                            Picker("Review decision", selection: $decision) {
                                Text("Reviewed").tag(AnalystFindingReviewDecision.reviewed)
                                Text("Needs Changes").tag(AnalystFindingReviewDecision.needsChanges)
                            }.frame(maxWidth: AppLayout.analystFindingDecisionMaximumWidth)
                            Button("Record Review") { applyReview() }
                                .disabled(!isCurrent || record.standing.isRetracted || text != record.authoredText)
                        }
                        if record.standing.isStale {
                            Button("Readmit Finding") { applyReadmit() }.disabled(!isCurrent)
                        }
                        if !record.standing.isRetracted {
                            HStack {
                                TextField("Reason for retraction", text: $retractionReason).frame(maxWidth: 360)
                                Button("Retract Finding") { applyRetract() }
                                    .disabled(!isCurrent || retractionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        HStack {
                            Button(store.undoManager.undoMenuItemTitle) {
                                store.undoManager.undo(); reload(); issue = store.analystFindingIssue
                            }.disabled(!store.undoManager.canUndo || !isCurrent || text != record.authoredText)
                            Button(store.undoManager.redoMenuItemTitle) {
                                store.undoManager.redo(); reload(); issue = store.analystFindingIssue
                            }.disabled(!store.undoManager.canRedo || !isCurrent || text != record.authoredText)
                        }
                        Text("Apply text before reviewing it. These Undo/Redo controls use the document’s history, as does the Edit menu. Undo retains revision history and does not renew an earlier review. Use the document’s normal Save command to persist changes.")
                            .foregroundStyle(.secondary)
                        if let issue { Text(issue).foregroundStyle(.secondary).textSelection(.enabled) }
                        AnalystFindingHistoryView(history: lifecycle.history)
                        AnalystFindingProvenanceView(content: record.content)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("This finding is no longer in the current document.")
            }
        }
        .padding(Lumen.Space.s7)
        .frame(
            minWidth: AppLayout.analystFindingReviewMinimumWidth,
            idealWidth: AppLayout.analystFindingReviewIdealWidth,
            minHeight: AppLayout.analystFindingReviewMinimumHeight,
            idealHeight: AppLayout.analystFindingReviewIdealHeight
        )
        .task(id: findingID) { reload() }
    }

    private func reload() {
        do {
            let next = try store.analystFindingEditToken(for: findingID)
            guard let record = store.analystFindings.records.first(where: { $0.id == findingID }) else {
                throw AnalystFindingError.wrongOwner
            }
            token = next; text = record.authoredText; issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func applyEdit() {
        guard let token else { return }
        do { _ = try store.editAnalystFinding(token, text: text); reload() }
        catch { issue = error.localizedDescription }
    }
    private func applyReview() {
        guard let token else { return }
        do { _ = try store.reviewAnalystFinding(token, decision: decision); reload() }
        catch { issue = error.localizedDescription }
    }
    private func applyRetract() {
        guard let token else { return }
        do { _ = try store.retractFinding(token, reason: retractionReason); retractionReason = ""; reload() }
        catch { issue = error.localizedDescription }
    }
    private func applyReadmit() {
        guard let token else { return }
        do { _ = try store.readmitAnalystFinding(token); reload() }
        catch { issue = error.localizedDescription }
    }
}

/// State badge and reason line for a finding that is stale or retracted. Draws nothing for an active one.
struct AnalystFindingStandingView: View {
    let standing: AnalystFindingStanding
    var body: some View {
        if standing != .active {
            let tint: Color = standing.isRetracted ? .red : .orange
            VStack(alignment: .leading, spacing: 2) {
                Text(standing.label).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(tint.opacity(0.18), in: Capsule()).foregroundStyle(tint)
                if let detail = standing.detail { Text(detail).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
    }
}

private struct AnalystFindingReviewStatus: View {
    let lifecycle: AnalystFindingLifecycle
    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text("Content revision \(lifecycle.state.contentRevision) · review revision \(lifecycle.state.reviewRevision)")
            if let review = lifecycle.selectedReview {
                Text(review.decision == .reviewed ? "Reviewed" : "Needs Changes").fontWeight(.semibold)
                Text(lifecycle.isReviewCurrent
                     ? "Review applies to this authored revision."
                     : "Historical review of content revision \(review.contentRevision). Review the current text explicitly.")
            } else {
                Text("Unreviewed").fontWeight(.semibold)
            }
        }
    }
}

private struct AnalystFindingHistoryView: View {
    let history: [AnalystFindingHistoryEntry]
    var body: some View {
        DisclosureGroup("Revision history (\(history.count))") {
            LazyVStack(alignment: .leading, spacing: Lumen.Space.s5) {
                ForEach(history) { entry in
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        Text("\(entry.sequence). \(entry.operation.kind.rawValue.capitalized)").fontWeight(.semibold)
                        Text(Date(timeIntervalSinceReferenceDate: entry.recordedAt), style: .date)
                        if let target = entry.operation.targetSequence { Text("Compensates action \(target)") }
                        if let reason = entry.operation.reason { Text("Reason: \(reason)").textSelection(.enabled) }
                        if let stale = entry.operation.staleReason { Text(stale.detail) }
                        DisclosureGroup("Before: content \(entry.before.contentRevision), review \(entry.before.reviewRevision)") {
                            AnalystFindingHistoryStateView(state: entry.before)
                        }
                        DisclosureGroup("After: content \(entry.after.contentRevision), review \(entry.after.reviewRevision)") {
                            AnalystFindingHistoryStateView(state: entry.after)
                        }
                        Divider()
                    }
                }
            }
        }
    }
}

private struct AnalystFindingHistoryStateView: View {
    let state: AnalystFindingAuthoredState
    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text(state.text).textSelection(.enabled)
            if let review = state.latestReview {
                Text("Latest recorded decision: \(review.decision.rawValue), review \(review.reviewRevision), content \(review.contentRevision)")
            }
            Text(state.selectedReviewRevision.map { "Selected review: \($0)" } ?? "No selected review")
        }
    }
}

private struct AnalystFindingProvenanceView: View {
    let content: AnalystFindingContentSnapshot
    @State private var archivedJSON: String?
    @State private var issue: String?
    var body: some View {
        DisclosureGroup("Original accepted answer and source provenance") {
            VStack(alignment: .leading, spacing: Lumen.Space.s3) {
                Text(content.candidateText).textSelection(.enabled)
                Text("Request: \(content.originalRequest.requestID.uuidString)").textSelection(.enabled)
                Text("Evidence: " + content.evidenceIDs.map(\.uuidString).joined(separator: ", ")).textSelection(.enabled)
                Button("Show Complete Archived Provenance") {
                    do {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        archivedJSON = String(decoding: try encoder.encode(content), as: UTF8.self)
                    } catch { issue = error.localizedDescription }
                }
                if let archivedJSON { Text(archivedJSON).textSelection(.enabled) }
                if let issue { Text(issue).foregroundStyle(.secondary) }
            }
        }
    }
}
