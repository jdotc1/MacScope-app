import SwiftUI
import LumenTokens
import LumenUI

/// Session-only hardware watchpoints. The editor takes runtime addresses, never workspace offsets.
struct WatchpointsDeckView: View {
    let watchpoints: [DebuggerWatchpoint]
    let canEdit: Bool
    let error: String?
    let onRequest: (DebuggerWatchpointRequest) -> Void
    var rendersOffscreen = false
    @State private var draft: WatchpointEditorDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            HStack {
                VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                    Text("Hardware Watchpoints").font(.body.weight(.semibold))
                    Text("Runtime addresses · current session only")
                        .font(AppTypography.metadata).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { onRequest(.refresh) }.disabled(!canEdit)
                Button { draft = WatchpointEditorDraft() } label: {
                    Label("Add Watchpoint", systemImage: "plus")
                }
                .buttonStyle(LumenPrimaryButtonStyle())
                .disabled(!canEdit)
            }
            if !canEdit {
                Text("Pause a live debugger session to add or change watchpoints.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.lumen(.statusDanger)).textSelection(.enabled)
            }
            Divider()
            if rendersOffscreen {
                watchpointRows
                Spacer(minLength: 0)
            } else {
                ScrollView { watchpointRows }
            }
        }
        .padding(Lumen.Space.s5)
        .workbenchPaneBackground(.debugger)
        .sheet(item: $draft) { initial in
            WatchpointEditorSheet(draft: initial, canSave: canEdit) { request in
                onRequest(request)
                draft = nil
            } onCancel: {
                draft = nil
            }
        }
    }

    private var watchpointRows: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s3) {
            if watchpoints.isEmpty {
                Text("No hardware watchpoints")
                    .foregroundStyle(.secondary).padding(.vertical, Lumen.Space.s6)
            }
            ForEach(watchpoints, id: \.id) { watchpoint in
                WatchpointDeckRow(
                    watchpoint: watchpoint,
                    canEdit: canEdit,
                    onEnabled: { onRequest(.setEnabled(id: watchpoint.id, isEnabled: $0)) },
                    onEdit: { draft = WatchpointEditorDraft(watchpoint: watchpoint) },
                    onDelete: { onRequest(.remove(id: watchpoint.id)) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchpointDeckRow: View {
    let watchpoint: DebuggerWatchpoint
    let canEdit: Bool
    let onEnabled: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Lumen.Space.s4) {
            Toggle("Enabled", isOn: Binding(get: { watchpoint.isEnabled }, set: onEnabled))
                .labelsHidden().toggleStyle(.checkbox)
            Text(watchpoint.address.hexAddress).font(.system(.body, design: .monospaced))
            Text("\(watchpoint.size) bytes").foregroundStyle(.secondary)
            LumenBadge(watchpoint.access.rawValue.uppercased(), systemImage: "eye")
            Spacer()
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .disabled(!canEdit)
        .padding(.vertical, Lumen.Space.s2)
    }
}

struct WatchpointEditorDraft: Identifiable {
    var id: UUID
    var addressText: String
    var size: Int
    var access: DebuggerWatchpointAccess
    var isEnabled: Bool

    init(watchpoint: DebuggerWatchpoint? = nil) {
        id = watchpoint?.id ?? UUID()
        addressText = watchpoint?.address.hexAddress ?? ""
        size = watchpoint?.size ?? 8
        access = watchpoint?.access ?? .write
        isEnabled = watchpoint?.isEnabled ?? true
    }

    var validationMessage: String? {
        guard let address = DebuggerAuthoringValidation.parseHexAddress(addressText) else {
            return "Enter a hexadecimal runtime address."
        }
        guard [1, 2, 4, 8].contains(size) else { return "Choose a size of 1, 2, 4, or 8 bytes." }
        guard address % UInt64(size) == 0 else { return "The address must be aligned to the selected size." }
        guard address <= UInt64.max - UInt64(size - 1) else { return "The watched range overflows the address space." }
        return nil
    }

    var request: DebuggerWatchpointRequest? {
        guard validationMessage == nil,
              let address = DebuggerAuthoringValidation.parseHexAddress(addressText) else { return nil }
        return .upsert(id: id, address: address, size: size, access: access, isEnabled: isEnabled)
    }
}

private struct WatchpointEditorSheet: View {
    @State var draft: WatchpointEditorDraft
    let canSave: Bool
    let onSave: (DebuggerWatchpointRequest) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Hardware Watchpoint").font(.headline)
            Text("Use an address from the stopped process. Watchpoints end with this debugger session.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Runtime address (hex)", text: $draft.addressText)
                .textFieldStyle(.roundedBorder)
            Picker("Size", selection: $draft.size) {
                ForEach([1, 2, 4, 8], id: \.self) { Text("\($0) bytes").tag($0) }
            }
            Picker("Access", selection: $draft.access) {
                Text("Read").tag(DebuggerWatchpointAccess.read)
                Text("Write").tag(DebuggerWatchpointAccess.write)
                Text("Read / Write").tag(DebuggerWatchpointAccess.readWrite)
            }
            .pickerStyle(.segmented)
            Toggle("Enabled", isOn: $draft.isEnabled)
            if let message = draft.validationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { if let request = draft.request { onSave(request) } }
                    .buttonStyle(LumenPrimaryButtonStyle())
                    .disabled(!canSave || draft.request == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Lumen.Space.s6)
        .frame(width: AppLayout.watchpointEditorWidth)
    }
}
