import SwiftUI
import LumenUI

/// A pending Rename Register presentation. The qualified function and the binary that owned its
/// slot are captured at presentation time so delayed prefill/commit cannot rebind after focus,
/// removal, or slot reuse.
struct RegisterRenameRequest: Identifiable, Equatable {
    private struct OpeningIdentity: Equatable {
        let target: ImageAddress
        let ownerBinaryID: UUID?
        let register: String
    }

    struct ID: Hashable {
        let presentationID: UUID
        let target: ImageAddress
        let ownerBinaryID: UUID?
        let register: String
    }

    /// Unique lifecycle token for this exact sheet presentation. Reopening the same register at
    /// the same target creates a distinct request and cannot revive a dismissed callback.
    let presentationID: UUID
    /// Store-private immutable baseline paired with the presentation token. Even an adversarial
    /// request reconstructed with the same token cannot substitute another function or owner.
    private let openingIdentity: OpeningIdentity
    /// The image whose authored register names the sheet reads and mutates.
    let imageSlot: ImageSlot
    /// The procedure-start address the rename is keyed under.
    let procedureStart: UInt64
    /// Stable identity of the binary that occupied `imageSlot` when the request opened.
    let ownerBinaryID: UUID?
    /// A pre-filled register id when launched from the pseudocode context menu (e.g. "x19");
    /// empty when launched from the Procedure menu, where the user types it.
    let register: String

    var target: ImageAddress { ImageAddress(slot: imageSlot, address: procedureStart) }
    var id: ID {
        ID(
            presentationID: presentationID,
            target: target,
            ownerBinaryID: ownerBinaryID,
            register: register
        )
    }

    init(
        imageSlot: ImageSlot,
        procedureStart: UInt64,
        register: String,
        ownerBinaryID: UUID?,
        presentationID: UUID = UUID()
    ) {
        self.presentationID = presentationID
        self.openingIdentity = OpeningIdentity(
            target: ImageAddress(slot: imageSlot, address: procedureStart),
            ownerBinaryID: ownerBinaryID,
            register: register
        )
        self.imageSlot = imageSlot
        self.procedureStart = procedureStart
        self.ownerBinaryID = ownerBinaryID
        self.register = register
    }

    /// Explicit compatibility for binary-less single-image fixtures. Interactive presentation
    /// must use the owner-bearing initializer above.
    init(imageSlot: ImageSlot, procedureStart: UInt64, register: String = "") {
        self.init(
            imageSlot: imageSlot,
            procedureStart: procedureStart,
            register: register,
            ownerBinaryID: nil
        )
    }

    var retainsOpeningIdentity: Bool {
        openingIdentity == OpeningIdentity(
            target: target,
            ownerBinaryID: ownerBinaryID,
            register: register
        )
    }

    func hasSameOpeningPresentation(as other: RegisterRenameRequest) -> Bool {
        presentationID == other.presentationID && openingIdentity == other.openingIdentity
    }

    /// True only while the exact opening binary still owns this discovered function.
    func hasCurrentFunction(in snapshot: WorkspaceSnapshot) -> Bool {
        if let ownerBinaryID {
            guard snapshot.binary(in: imageSlot)?.id == ownerBinaryID else { return false }
        } else {
            guard snapshot.binaries.isEmpty else { return false }
        }
        return snapshot.analysis(in: imageSlot)?.functions.contains {
            $0.startAddress == procedureStart
        } ?? false
    }

    /// The exact slot-qualified prefill consumed by the sheet. Keeping this lookup on the
    /// request makes the captured image identity testable and prevents the view from falling
    /// back to a bare-address primary lookup.
    func prefilledName(in snapshot: WorkspaceSnapshot) -> String {
        guard hasCurrentFunction(in: snapshot) else { return "" }
        let key = register.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return "" }
        return snapshot.registerNameOverrides(
            forProcedureAt: procedureStart,
            in: imageSlot
        )[key] ?? ""
    }
}

/// The Rename Register sheet: names (or clears) a REGISTER in the decompiled pseudocode for
/// the current procedure. The GUI affordance for the previously scripting-only
/// `rename-register` command — Procedure ▸ Rename Register (and the pseudocode context menu).
///
/// The rename is keyed at the procedure start, shows at every occurrence of that register in
/// the procedure's body, and survives save/reopen + re-analysis (`store.renameRegister`).
struct RegisterRenameSheet: View {
    @ObservedObject var store: WorkspaceStore
    let request: RegisterRenameRequest

    @State private var register: String
    @State private var name: String

    init(request: RegisterRenameRequest, store: WorkspaceStore) {
        self.request = request
        self.store = store
        _register = State(initialValue: request.register)
        _name = State(initialValue: request.prefilledName(in: store.snapshot))
    }

    private var addressText: String { "0x" + String(request.procedureStart, radix: 16) }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s6) {
            Text("Rename Register")
                .font(.headline)
                .lumenNeverTruncates("Rename Register")
            Text("In the function at \(addressText). An empty name clears the rename.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: Lumen.Space.s5) {
                Text("Register")
                    .frame(width: 72, alignment: .leading)
                TextField("x19", text: $register)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(!request.register.isEmpty)
                    .accessibilityLabel("Register identifier")
            }
            HStack(spacing: Lumen.Space.s5) {
                Text("Name")
                    .frame(width: 72, alignment: .leading)
                TextField("name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(apply)
                    .accessibilityLabel("Register display name")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    // Clearing the exact request drives `.sheet(item:)` dismissal. A separate
                    // `dismiss()` would bypass the store's presentation-token guard.
                    store.cancelRegisterRename(request)
                }
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        register.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !request.hasCurrentFunction(in: store.snapshot)
                    )
            }
        }
        .padding(Lumen.Space.s7)
        .frame(minWidth: 360)
    }

    private func apply() {
        _ = store.commitRegisterRename(request, register: register, name: name)
    }
}
