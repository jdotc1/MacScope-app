import SwiftUI
import LumenUI

/// Content for the existing NativePseudocodeActionSheet. The surrounding sheet
/// retains its existing Close button and ownership/dismissal behavior.
struct NativeValueNavigationSheetView: View {
    @ObservedObject var session: NativeValueNavigationSession

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            HStack {
                Text("Value \(session.direction.title)").font(.headline)
                Spacer()
                Picker("Relationship", selection: Binding(
                    get: { session.direction },
                    set: { session.changeDirection($0) }
                )) {
                    ForEach(NativeValueNavigationDirection.allCases, id: \.rawValue) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: AppLayout.nativeValueRelationshipMaximumWidth)
                .disabled(isLoading)
            }
            Text("Recorded relationships within this function. Calls, memory and opaque effects remain explicit boundaries.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch session.phase {
            case .loading:
                HStack(spacing: Lumen.Space.s4) {
                    ProgressView().controlSize(.small)
                    Text("Reading value relationships…")
                }
                Spacer()
            case let .candidates(selection):
                Text(selection.explanation).foregroundStyle(.secondary)
                if !selection.limitsReached.isEmpty { limitNotice(selection.limitsReached) }
                List(selection.candidates) { candidate in
                    Button { session.choose(valueID: candidate.id) } label: {
                        candidateLabel(candidate)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            case let .report(candidate, report):
                let reportID = session.reportID
                HStack(alignment: .top) {
                    candidateLabel(candidate)
                    Spacer()
                    Button("Choose Value…") { session.chooseAnotherValue() }
                }
                if report.isBudgetLimited { limitNotice(report.limitsReached) }
                List {
                    Section("Relationships") {
                        if report.rows.isEmpty {
                            Text("No additional relationship is recorded for this value.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(report.rows) { row in
                            relationshipRow(row, reportID: reportID)
                        }
                    }
                    if !report.boundaries.isEmpty {
                        Section("Where traversal stops") {
                            ForEach(report.boundaries) { boundary in
                                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                                    Text(boundary.valueID).font(.caption.monospaced())
                                    Text(boundary.explanation).font(.caption)
                                    if let site = boundary.site {
                                        Text(site.recordID)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            case let .unavailable(explanation):
                Text(explanation).foregroundStyle(.secondary)
                Spacer()
            case .invalidated:
                Text("The native publication changed. Reopen this action from the current function.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var isLoading: Bool {
        if case .loading = session.phase { return true }
        return false
    }

    private func candidateLabel(_ candidate: NativeValueNavigationCandidate) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text(candidate.ssaValueID).font(.body.monospaced()).textSelection(.enabled)
            Text(candidate.kind.rawValue + " · " + candidate.varnodeID)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let register = candidate.registerName {
                Text("Register: " + String(register.prefix(128))).font(.caption)
            }
            if !candidate.variableNames.isEmpty {
                Text("Variables: " + candidate.variableNames.map { String($0.prefix(128)) }.joined(separator: ", "))
                    .font(.caption)
            }
            ForEach(candidate.contexts.indices, id: \.self) { index in
                Text(candidate.contexts[index]).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func relationshipRow(
        _ row: NativeValueNavigationRow, reportID: UUID?
    ) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text(row.siteLabel).font(.body.monospaced()).textSelection(.enabled)
            Text("Depth \(row.depth) · \(row.valueID)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let related = row.relatedValueID {
                Text("Related value: " + related).font(.caption.monospaced())
            }
            if let operand = row.operandIndex {
                Text("Input \(operand)").font(.caption)
            }
            if let predecessor = row.predecessorBlockID {
                Text("Incoming from " + predecessor).font(.caption.monospaced())
            }
            if let edge = row.incomingEdgeID {
                Text("Edge " + edge).font(.caption.monospaced())
            }
            if row.sourceRanges.isEmpty {
                Text("No navigable source range was recorded.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(row.sourceRanges.indices, id: \.self) { index in
                    let range = row.sourceRanges[index]
                    Button("Reveal " + address(range.startAddress.value) + "–" + address(range.endAddressExclusive.value)) {
                        session.reveal(rowID: row.id, sourceIndex: index, reportID: reportID)
                    }
                    .font(.caption.monospaced())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func limitNotice(_ limits: Set<NativeValueNavigationLimit>) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s2) {
            Text("Partial view").font(.caption.weight(.semibold))
            ForEach(limits.sorted { $0.rawValue < $1.rawValue }, id: \.rawValue) { limit in
                Text(limit.explanation).font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }

    private func address(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }
}
