import SwiftUI
import LumenUI

/// Real Assistant consumer for initial authored findings. Full text is retained and selectable;
/// acceptance is a document edit; saved records open the document-owned revision inspector.
struct Phase2AnalystFindingAcceptanceView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var selectedFinding: AnalystFindingSelection?

    /// Reasons offered by the Retract menu. The inspector takes a free-text reason.
    private static let retractionReasons = [
        "The conclusion was wrong", "Superseded by a newer finding", "The evidence does not support it",
    ]

    var body: some View {
        if store.pendingAnalystFinding != nil || !store.analystFindings.isEmpty || store.analystFindingIssue != nil {
            VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                if let issue = store.analystFindingIssue {
                    Text(issue).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let pending = store.pendingAnalystFinding {
                    DisclosureGroup("Save this answer as an authored finding") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Lumen.Space.s4) {
                                Text(pending.draft.candidate.text).textSelection(.enabled)
                                Text("\(pending.draft.candidate.evidenceIDs.count) native evidence references"
                                     + (pending.citations.isEmpty ? "" : " · cites \(pending.citations.count) contract facts")
                                     + " · unreviewed")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Accept Finding") { try? store.acceptPendingAnalystFinding() }
                                    Button("Reject") { store.dismissPendingAnalystFinding() }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: AppLayout.analystFindingListMaximumHeight)
                    }
                }
                if !store.analystFindings.isEmpty {
                    DisclosureGroup("Authored findings (\(store.analystFindings.records.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                                ForEach(store.analystFindings.records) { record in
                                    VStack(alignment: .leading, spacing: Lumen.Space.s3) {
                                        Text(record.createdAt, style: .date).fontWeight(.semibold)
                                        AnalystFindingStandingView(standing: record.standing)
                                        Text(record.authoredText).textSelection(.enabled)
                                        Text("Content revision \(record.contentRevision) · review revision \(record.reviewRevision)")
                                        HStack {
                                            Button("Open Finding") { selectedFinding = .init(id: record.id) }
                                            if !record.standing.isRetracted {
                                                Menu("Retract") {
                                                    ForEach(Self.retractionReasons, id: \.self) { reason in
                                                        Button(reason) { retract(record.id, reason: reason) }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    Divider()
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: AppLayout.analystFindingListMaximumHeight)
                    }
                    .sheet(item: $selectedFinding) { selection in
                        AnalystFindingInspectorView(store: store, findingID: selection.id)
                    }
                }
            }
            .padding()
            Divider()
        }
    }

    /// A failure is published to the store's finding issue, which this view already shows.
    private func retract(_ findingID: UUID, reason: String) {
        guard let token = try? store.analystFindingEditToken(for: findingID) else { return }
        _ = try? store.retractFinding(token, reason: reason)
    }
}
