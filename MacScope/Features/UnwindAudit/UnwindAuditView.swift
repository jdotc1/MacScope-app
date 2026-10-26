import SwiftUI
import LumenTokens
import LumenUI

/// A workspace-owned audit, presented inside Signature & Dependencies.
struct UnwindAuditView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        UnwindAuditContent(store: store, coordinator: store.unwindAuditCoordinator)
    }
}

private struct UnwindAuditRow: Identifiable {
    let finding: UnwindAuditFinding
    var id: String { finding.function.id }
    var title: String { finding.function.symbolName ?? "0x" + String(finding.function.address, radix: 16) }
    var address: String { "0x" + String(finding.function.address, radix: 16) }
}

private struct UnwindAuditContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var coordinator: UnwindAuditCoordinator
    @State private var selection: String?

    private var key: UnwindAuditResultKey? { store.unwindAuditKey(in: store.focusedImageSlot) }
    private var isCurrent: Bool { key != nil && coordinator.state.key == key }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack {
                Label("Unwind Audit", systemImage: "arrow.uturn.backward")
                    .font(.headline)
                Spacer()
                if isCurrent && coordinator.state.phase == .running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { coordinator.cancel() }
                } else {
                    Button("Run Audit") { store.startUnwindAudit(in: store.focusedImageSlot) }
                        .disabled(key == nil)
                }
            }
            if let binary = store.focusedBinary {
                Text("\(binary.name) · slot \(binary.slot.rawValue) · \(binary.architecture)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Bounded static caller recovery. Agreement applies only to the modeled observations; unsupported recovery remains unresolved.")
                .font(.caption).foregroundStyle(.secondary)
            if isCurrent {
                status
                if coordinator.state.phase == .completed {
                    results
                }
            } else {
                Text(key == nil
                     ? "Audit unavailable. A verified Mach-O slice, retained bytes, and segment mappings are required. Wait for loading to finish or re-import the image."
                     : "Run an audit for this image. Results from another image or generation are not shown.")
                    .foregroundStyle(.secondary)
            }
            Text("Cancel prevents publication immediately. The current bounded analysis may finish before its worker stops.")
                .font(.caption).foregroundStyle(.secondary)
            if coordinator.state.discardedPublicationCount > 0 {
                Text("Discarded stale publications: \(coordinator.state.discardedPublicationCount)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: key, initial: true) { _, current in
            selection = nil
            coordinator.activate(current)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch coordinator.state.phase {
        case .idle: Text("Ready to audit this image.").foregroundStyle(.secondary)
        case .running: Text("Auditing the captured image…").foregroundStyle(.secondary)
        case .cancelled: Text("Audit cancelled. Run again to produce a result.").foregroundStyle(.secondary)
        case .failed(let message): Text(message).foregroundStyle(.secondary).textSelection(.enabled)
        case .completed:
            if let report = coordinator.state.report {
                Text("\(report.findings.count) functions · model \(report.analysisModelVersion)")
                    .font(.caption).textSelection(.enabled)
                Text("Limits: \(report.configuration.maxInstructions) instructions/function, \(report.configuration.maxSteps) steps, \(report.configuration.maxPaths) paths, \(report.configuration.maxObservations) observations, \(report.configuration.maxEvidence) evidence items.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var results: some View {
        let rows = coordinator.state.sortedFindings.map { UnwindAuditRow(finding: $0) }
        return VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text("Unresolved findings appear first, followed by inconsistencies and agreements.")
                .font(.caption).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No independently declared function starts were available. No recovery agreement is claimed.")
                    .foregroundStyle(.secondary)
            } else {
                LumenTable(rows, selection: $selection, minHeight: 0, columns: [
                    .text("Function", monospaced: true) { $0.title },
                    .text("Address", monospaced: true) { $0.address },
                    LumenTableColumn("Verdict") { row in
                        LumenTag(row.finding.verdict, color: row.finding.verdict == "agreement" ? .secondary : .orange)
                    },
                ])
                .frame(height: 220)
                if let row = rows.first(where: { $0.id == selection }) {
                    UnwindAuditFindingDetail(finding: row.finding,
                        target: coordinator.state.navigationTarget(for: row.finding),
                        navigate: { store.navigateFromUnwindAudit($0) })
                } else {
                    Text("Select a finding to inspect its evidence and limitations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct UnwindAuditFindingDetail: View {
    let finding: UnwindAuditFinding
    let target: UnwindAuditNavigationTarget?
    let navigate: (UnwindAuditNavigationTarget) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack {
                Text("\(finding.coverage) · \(finding.mode) · \(finding.scope)")
                    .font(.caption).textSelection(.enabled)
                Spacer()
                Button("Show Function") { if let target { _ = navigate(target) } }
                    .disabled(target == nil)
            }
            Text("Reasons: " + finding.reasonCodes.joined(separator: ", "))
                .font(.caption).textSelection(.enabled)
            Text(finding.evidence.map { evidence in
                let location = evidence.address.map { " at 0x" + String($0, radix: 16) } ?? ""
                let comparison = [evidence.expected.map { "Expected: " + $0 },
                                  evidence.observed.map { "Observed: " + $0 }]
                    .compactMap { $0 }.joined(separator: "; ")
                return "\(evidence.code)\(location): \(evidence.message)" + (comparison.isEmpty ? "" : "\n" + comparison)
            }.joined(separator: "\n\n"))
                .font(.caption).textSelection(.enabled)
            Text("Checked PCs: " + (finding.checkedPCs.isEmpty ? "none" :
                finding.checkedPCs.map { "0x" + String($0, radix: 16) }.joined(separator: ", ")))
                .font(.caption).textSelection(.enabled)
            Text(finding.limitations.joined(separator: "\n"))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}
