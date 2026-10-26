import SwiftUI
import LumenUI

/// The Import C Header sheet: a paste area for C `struct` / `union` / `enum` / `typedef`
/// declarations that are parsed into the workspace type catalog in one undoable step
/// (`store.defineTypesFromCHeader`). This is the GUI affordance for the previously
/// scripting-only `define-types-from-c` command — File ▸ Import C Header.
///
/// On Import the sheet stays open and shows a summary (which types were added and any
/// parser diagnostics / name-collision skips) so the user sees exactly what landed before
/// dismissing. Names already in the catalog are skipped, never overwritten — the catalog's
/// UNIQUE(name) index would otherwise abort the whole workspace save.
struct CHeaderImportSheet: View {
    @ObservedObject var store: WorkspaceStore
    let request: CHeaderImportRequest
    @Environment(\.dismiss) private var dismiss

    @State private var source: String

    init(request: CHeaderImportRequest, store: WorkspaceStore) {
        self.request = request
        self.store = store
        _source = State(initialValue: request.source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Text("Import C Header")
                .font(.headline)
                .lumenNeverTruncates("Import C Header")
            Text("Paste C struct / union / enum / typedef declarations to add them to the type catalog. Existing names are skipped, never overwritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 460, minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: Lumen.Radius.xs)
                        .strokeBorder(Color.lumen(.borderSubtle), lineWidth: 1)
                )
                .accessibilityLabel("C header source")
                .accessibilityHint("Paste C type declarations here")

            if let summary = store.cHeaderImportSummary {
                importSummaryView(summary)
            }

            HStack {
                Spacer()
                Button("Done", role: .cancel) {
                    store.cancelCHeaderImport()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Import") {
                    store.commitCHeaderImport(source)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Lumen.Space.s7)
        .frame(minWidth: 500)
    }

    @ViewBuilder
    private func importSummaryView(_ summary: WorkspaceStore.CHeaderImportSummary) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            if summary.addedNames.isEmpty {
                Label("No types added.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Added \(summary.addedNames.count) type\(summary.addedNames.count == 1 ? "" : "s"): \(summary.addedNames.joined(separator: ", "))",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(Color.lumen(.statusSuccess))
            }
            ForEach(Array(summary.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Label(diagnostic, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Lumen.Space.s5)
        .background(Color.lumen(.listingAlternateRow), in: RoundedRectangle(cornerRadius: Lumen.Radius.xs))
        .accessibilityElement(children: .combine)
    }
}
