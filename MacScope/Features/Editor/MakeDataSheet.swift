import SwiftUI
import LumenUI

/// The Make Data sheet: shapes the bytes at the selected address as an ARRAY, a STRING, or
/// ALIGNMENT padding. This is the GUI affordance for the previously scripting-only
/// `make-array` / `make-string` / `make-alignment` commands — Procedure ▸ Make Data (and
/// the listing context menu's Data submenu).
///
/// Each shape commits one undoable, re-analysis-driving `setDataShape` (a shaped address is
/// data over its whole span). Invalid numeric entry is rejected with an inline message
/// rather than applied as a garbage shape.
struct MakeDataSheet: View {
    @ObservedObject var store: WorkspaceStore
    @State private var draft: DataShapeEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    init(request: DataShapeEditorRequest, store: WorkspaceStore) {
        self.store = store
        _draft = State(initialValue: request)
    }

    private var addressText: String { "0x" + String(draft.address, radix: 16) }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Text("Make Data")
                .font(.headline)
                .lumenNeverTruncates("Make Data")
            Text("Shape the bytes at \(addressText).")
                .font(.caption)
                .foregroundStyle(.secondary)

            // U9-4f: the shape's fields in a Lumen tabbed box, its tabs on the box's top edge.
            LumenTabbedBox(selection: $draft.shape, tabs: DataShapeEditorRequest.Shape.allCases,
                           title: \.displayName) { shape in
                VStack(alignment: .leading, spacing: Lumen.Space.s5) {
                    switch shape {
                    case .array:
                        arrayFields
                    case .string:
                        stringFields
                    case .alignment:
                        alignmentFields
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Data shape")

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.lumen(.statusDanger))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    // The request-aware store mutation is also the presentation binding's
                    // dismissal. Do not call `dismiss()` separately: a late callback must not
                    // bypass the token guard and dismiss a replacement request.
                    store.cancelDataShapeEditor(draft)
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Lumen.Space.s7)
        .frame(minWidth: 380)
    }

    @ViewBuilder
    private var arrayFields: some View {
        labeledField("Element type") {
            TextField("int32_t", text: $draft.elementType)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Array element type")
        }
        labeledField("Count") {
            TextField("1", text: $draft.countText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Array element count")
        }
    }

    @ViewBuilder
    private var stringFields: some View {
        Toggle("NUL-terminated C string", isOn: $draft.isNullTerminated)
            .accessibilityLabel("NUL-terminated C string")
        if !draft.isNullTerminated {
            labeledField("Length") {
                TextField("1", text: $draft.stringLengthText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Fixed string length in bytes")
            }
        }
    }

    @ViewBuilder
    private var alignmentFields: some View {
        labeledField("Boundary") {
            TextField("4", text: $draft.boundaryText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Alignment byte boundary")
        }
        Text("A power-of-two byte boundary (2, 4, 8, 16, …).")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Lumen.Space.s5) {
            Text(label)
                .frame(width: 96, alignment: .leading)
            content()
        }
    }

    private func apply() {
        if store.commitDataShapeEditor(draft) {
            dismiss()
        } else {
            // commitDataShapeEditor surfaced the reason via lastIssue; mirror it inline.
            error = store.lastIssue ?? "Invalid data shape."
        }
    }
}
