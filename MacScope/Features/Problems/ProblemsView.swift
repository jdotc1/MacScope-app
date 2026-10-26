import SwiftUI
import LumenUI

/// The analysis Problems panel — a diagnostics window for MacScope's analysis
/// side. It lists everything the static pipeline could NOT fully resolve:
/// unresolved branch/jump targets, undecodable bytes inside executable code, references that
/// land outside every section, and loader truncation/over-read flags. Each row carries a
/// severity (error/warning) and its address; selecting a row jumps the editor there.
///
/// Presented as a sheet from View ▸ Problems. The list is a dumb `ForEach` driven entirely by
/// a `ProblemsViewModel` projection of every image's diagnostics, grouped by image (a pure, derived value), so no
/// ordering/labeling logic lives in the view. Native `List`, keyboard-navigable, VoiceOver-
/// labeled — mirroring the Navigation History panel.
struct ProblemsSheet: View {
    @ObservedObject var store: WorkspaceStore

    private var model: ProblemsViewModel {
        ProblemsViewModel(snapshot: store.snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 460, idealWidth: 540, minHeight: 360, idealHeight: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Problems")
    }

    private var header: some View {
        HStack(spacing: Lumen.Space.s5) {
            Label("Problems", systemImage: "ladybug")
                .font(.headline)
                .lumenNeverTruncates("Problems")
                .accessibilityAddTraits(.isHeader)

            Text(model.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.summary)

            Spacer(minLength: Lumen.Space.s5)

            Button("Done") { store.showProblems = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
    }

    @ViewBuilder
    private var content: some View {
        let model = model
        if model.sections.isEmpty {
            VStack(spacing: Lumen.Space.s4) {
                Spacer()
                Image(systemName: "checkmark.seal")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No problems found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Analysis resolved every branch, instruction, and reference.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Lumen.Space.s7)
        } else {
            List {
                ForEach(model.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            let navigationTarget = store.diagnosticNavigationTarget(
                                id: row.id,
                                in: section.slot
                            )
                            ProblemRowView(row: row) {
                                if let navigationTarget,
                                   store.navigateToDiagnostic(navigationTarget) {
                                    store.showProblems = false
                                }
                            }
                        }
                    } header: {
                        if model.showsImageHeaders {
                            Text("\(section.title) · \(section.rows.count)")
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

}

/// One selectable problem row: a severity icon, the kind title, the anchor address, and the
/// detail message. A `Button` (not a tap gesture) so it is natively keyboard-focusable and
/// VoiceOver-actionable; selecting it triggers the jump.
private struct ProblemRowView: View {
    let row: ProblemRow
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
                Image(systemName: row.iconSystemName)
                    .font(.callout)
                    .foregroundStyle(row.iconColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    HStack(spacing: Lumen.Space.s4) {
                        Text(row.title)
                            .font(.body)
                            .fontWeight(.semibold)
                            .lineLimit(1)

                        Text(row.addressText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text(row.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Jumps to this address")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        "\(row.severityLabel): \(row.title) at \(row.addressText). \(row.message)"
    }
}
