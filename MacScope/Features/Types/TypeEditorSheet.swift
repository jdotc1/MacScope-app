import SwiftUI
import LumenUI

extension Notification.Name {
    static let macScopeExportRenderedTypeDefinition = Notification.Name(
        "MacScopeExportRenderedTypeDefinition"
    )
}

/// Lossless type-catalog editor. Only default-layout structs/unions with parser-proven
/// plain storage expose mutable controls; every richer definition is rendered read-only.
struct TypeEditorSheet: View {
    static let renderedCExportButtonTitle = "Export Rendered C…"

    @ObservedObject var store: WorkspaceStore
    @State private var draft: TypeEditorRequest
    @State private var selectedFieldID: TypeFieldDraft.ID?

    init(request: TypeEditorRequest, store: WorkspaceStore) {
        self.store = store
        _draft = State(initialValue: request)
    }

    var body: some View {
        Group {
            switch draft.access {
            case .editablePlainRecord:
                editableBody
            case let .readOnlyRichDefinition(reason):
                readOnlyBody(reason: reason)
            }
        }
        .padding(Lumen.Space.s7)
        .frame(minWidth: 500)
    }

    private var editableBody: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Text(draft.original == nil ? "Define Type" : "Edit Type")
                .font(.headline)
                .lumenNeverTruncates(draft.original == nil ? "Define Type" : "Edit Type")

            HStack(spacing: Lumen.Space.s5) {
                if draft.original == nil {
                    Picker("Kind", selection: $draft.kind) {
                        Text(TypeKind.struct.displayName).tag(TypeKind.struct)
                        Text(TypeKind.union.displayName).tag(TypeKind.union)
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    Text(draft.kind.displayName)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 54, alignment: .leading)
                }
                TextField("type name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Fields")
                .font(.subheadline.weight(.semibold))

            // U9-4a: the fields as a Lumen table. + appends a field (and selects it), − removes
            // the selected one; each cell edits the field in place.
            LumenTable(
                draft.fields,
                selection: $selectedFieldID,
                emptyMessage: "No fields",
                footer: LumenTableFooter(
                    onAdd: {
                        let field = TypeFieldDraft(name: "", type: "")
                        draft.fields.append(field)
                        selectedFieldID = field.id
                    },
                    onRemove: {
                        guard let selectedFieldID else { return }
                        draft.fields.removeAll { $0.id == selectedFieldID }
                        self.selectedFieldID = nil
                    }
                ),
                minHeight: 120,
                columns: [
                    LumenTableColumn("Type") { field in
                        LumenTextField("type", text: fieldBinding(field.id, \.type), monospaced: true)
                    },
                    LumenTableColumn("Name") { field in
                        LumenTextField("name", text: fieldBinding(field.id, \.name))
                    },
                ]
            )
            .frame(maxHeight: 260)
            .accessibilityIdentifier("typeEditor.fields")

            HStack {
                Spacer()
                Button("Cancel") { store.cancelTypeEditor(draft) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { store.commitTypeEditor(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.isEmpty)
            }
        }
    }

    private func fieldBinding(_ id: TypeFieldDraft.ID, _ path: WritableKeyPath<TypeFieldDraft, String>) -> Binding<String> {
        Binding(
            get: { draft.fields.first { $0.id == id }?[keyPath: path] ?? "" },
            set: { value in
                guard let index = draft.fields.firstIndex(where: { $0.id == id }) else { return }
                draft.fields[index][keyPath: path] = value
            }
        )
    }

    private func readOnlyBody(reason: String) -> some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Text("Type Definition")
                .font(.headline)
                .lumenNeverTruncates("Type Definition")
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(draft.original.map(CTypeHeaderRenderer.renderType) ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Lumen.Space.s6)
            }
            .frame(minHeight: 180, maxHeight: 360)
            .background(.lumen(.bgInset), in: RoundedRectangle(cornerRadius: Lumen.Radius.md))

            HStack {
                Button("Delete", role: .destructive) {
                    store.deleteTypeEditorDefinition(draft)
                }
                Spacer()
                Button(Self.renderedCExportButtonTitle) {
                    store.requestRenderedCExport(draft)
                }
                Button("Close") { store.cancelTypeEditor(draft) }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
