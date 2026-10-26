import SwiftUI
import LumenUI

/// On-demand review over existing loaded images; neither discovery nor source acquisition.
struct SourceFunctionCandidatesView: View {
    @ObservedObject var store: WorkspaceStore
    let slot: ImageSlot
    let address: UInt64
    @State private var references: [Reference] = []
    @State private var selectedReference: ImageSlot?
    @State private var revision: SourceRevisionIdentity?
    @State private var candidates: [SourceFunctionCorrelation] = []
    @State private var installationID: UUID?
    @State private var attempted = false
    @State private var message: String?

    private struct Reference: Identifiable {
        let id: ImageSlot
        let name: String
    }
    private struct ReadingKey: Hashable {
        let slot: ImageSlot
        let address: UInt64
        let sourceState: Data
        let analysisRevision: UUID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s3) {
            if revision != nil, !references.isEmpty {
                Picker("Compiled source reference", selection: $selectedReference) {
                    Text("Choose Image…").tag(Optional<ImageSlot>.none)
                    ForEach(references) { reference in
                        Text(reference.name).tag(Optional(reference.id))
                    }
                }
                Button("Find Source Candidates") { find() }
                    .controlSize(.small)
                    .disabled(selectedReference == nil)
                if attempted, candidates.isEmpty {
                    Text("No unique compatible match. The revision, architecture, code, or debug evidence did not qualify.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(candidates) { candidate in
                    SourceFunctionCandidateRow(candidate: candidate) { accept(candidate) }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: ReadingKey(slot: slot, address: address, sourceState: store.snapshot.sourceLinkState,
                             analysisRevision: store.nativeDecompilerSnapshotRevision)) {
            refresh()
        }
        .onChange(of: selectedReference) { _, _ in
            candidates = []
            attempted = false
            message = nil
        }
    }

    private func refresh() {
        candidates = []
        attempted = false
        revision = nil
        references = []
        guard let state = try? SourceLinkWorkspaceState.decode(store.snapshot.sourceLinkState, binaries: store.snapshot.binaries),
              let binary = store.snapshot.binary(in: slot),
              let binding = state.binding(for: binary) else { return }
        revision = binding.image.sourceRevision
        references = store.snapshot.binaries.compactMap { reference in
            guard reference.slot != slot, let referenceBinding = state.binding(for: reference),
                  referenceBinding.image.sourceRevision == binding.image.sourceRevision else { return nil }
            return Reference(id: reference.slot, name: reference.name)
        }
        if !references.contains(where: { $0.id == selectedReference }) { selectedReference = nil }
    }

    private func find() {
        guard let selectedReference, let revision else { return }
        installationID = store.documentInstallationID
        do {
            candidates = try store.sourceFunctionCandidates(from: selectedReference, to: slot,
                                                            targetRevision: revision)
                .filter { $0.targetAddress == address }
            attempted = true
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func accept(_ candidate: SourceFunctionCorrelation) {
        guard let installationID else { return }
        do {
            try store.acceptSourceFunctionCandidate(candidate, expectedInstallationID: installationID)
            candidates.removeAll { $0.id == candidate.id }
            attempted = false
            message = nil
        } catch { message = error.localizedDescription }
    }
}

private struct SourceFunctionCandidateRow: View {
    let candidate: SourceFunctionCorrelation
    let accept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.sourceCandidateDetailSpacing) {
            Text(candidate.referenceLink.recordedPath ?? "")
                .font(.system(.caption, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            Text("Unique code and semantic fingerprint match to a source-qualified reference.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Text("The target line mapping remains a candidate. Review the source before accepting.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Accept Source Candidate", action: accept).controlSize(.small)
        }
    }
}
