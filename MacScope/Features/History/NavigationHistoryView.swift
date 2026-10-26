import SwiftUI
import LumenUI

/// A browsable list of the back/forward navigation history — every address the user has
/// visited, newest on top, with its symbol/section context. Selecting a row jumps the
/// editor there (without truncating forward history), so it doubles as a "recent places"
/// jump list. The same stack is surfaced here as a first-class, keyboard-navigable,
/// VoiceOver-labeled panel.
///
/// Presented as a sheet from View ▸ Navigation History. The list is a dumb `ForEach`
/// driven entirely by `store.navigationHistoryRows` (a pure projection over the snapshot),
/// so no ordering/labeling logic lives in the view.
struct NavigationHistorySheet: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigation history")
    }

    private var header: some View {
        HStack(spacing: Lumen.Space.s5) {
            Label("Navigation History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .lumenNeverTruncates("Navigation History")
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Lumen.Space.s5)

            Button("Done") { store.showNavigationHistory = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s5)
    }

    @ViewBuilder
    private var content: some View {
        let rows = store.navigationHistoryRows
        if rows.isEmpty {
            VStack {
                Spacer()
                Text("No navigation history yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Lumen.Space.s7)
        } else {
            List {
                ForEach(rows) { row in
                    NavigationHistoryRowView(row: row) {
                        store.navigateToHistoryEntry(at: row.panelIndex)
                        store.showNavigationHistory = false
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

/// One selectable history row. The current cursor is marked with a leading indicator and a
/// bold title; selecting a row triggers the jump. A `Button` (not a tap gesture) so it is
/// natively keyboard-focusable and VoiceOver-actionable.
private struct NavigationHistoryRowView: View {
    let row: NavigationHistoryRow
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Lumen.Space.s5) {
                Image(systemName: row.isCurrent ? "location.fill" : "location")
                    .font(.caption)
                    .foregroundStyle(row.isCurrent ? Color.lumen(.accent) : Color.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Lumen.Space.s1) {
                    Text(row.title)
                        .font(.body)
                        .fontWeight(row.isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Jumps to this address")
        .accessibilityAddTraits(row.isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        var label = row.title
        if !row.subtitle.isEmpty {
            label += ", " + row.subtitle.replacingOccurrences(of: "  •  ", with: ", ")
        }
        if row.isCurrent {
            label += ", current location"
        }
        return label
    }
}
