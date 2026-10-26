import SwiftUI
import LumenUI

/// Identifies one pending Patch Bytes… presentation. Both the durable workspace address and the
/// binary that occupied its slot are captured when the command executes, so a delayed sheet can
/// neither rebind a colliding address after focus changes nor attach to a replacement binary.
struct PatchBytesRequest: Identifiable, Equatable {
    struct ID: Hashable {
        let presentationID: UUID
        let target: ImageAddress
        let ownerBinaryID: UUID?
    }

    /// Unique lifecycle token for this exact sheet presentation. Reopening the same target must
    /// not make a delayed callback from the dismissed sheet equal the new pending request.
    let presentationID: UUID
    let target: ImageAddress
    let ownerBinaryID: UUID?

    var id: ID { ID(presentationID: presentationID, target: target, ownerBinaryID: ownerBinaryID) }
    var address: UInt64 { target.address }

    init(target: ImageAddress, ownerBinaryID: UUID?) {
        self.presentationID = UUID()
        self.target = target
        self.ownerBinaryID = ownerBinaryID
    }

    /// Explicit single-image compatibility for deterministic fixtures that have no BinaryImage.
    /// Interactive presenters must use `init(target:ownerBinaryID:)` instead.
    init(address: UInt64) {
        self.init(target: .primary(address), ownerBinaryID: nil)
    }

    /// Reads sheet state only when this request still names its opening instruction owner.
    func existingPatch(in snapshot: WorkspaceSnapshot) -> BytePatch? {
        guard instruction(in: snapshot) != nil else { return nil }
        if ownerBinaryID == nil {
            guard let patch = snapshot.addressOverrides[target]?.patch, !patch.isEmpty else { return nil }
            return patch
        }
        return snapshot.patch(at: target)
    }

    func hasCurrentInstruction(in snapshot: WorkspaceSnapshot) -> Bool {
        instruction(in: snapshot) != nil
    }

    private func instruction(in snapshot: WorkspaceSnapshot) -> InstructionRow? {
        if let ownerBinaryID {
            guard snapshot.binary(in: target.slot)?.id == ownerBinaryID else { return nil }
            return snapshot.instruction(at: target)
        }

        // Legacy binary-less fixtures predate BinaryImage but retain a primary analysis bucket.
        guard snapshot.binaries.isEmpty else { return nil }
        return snapshot.analysis(in: target.slot)?.instructions.first { $0.address == target.address }
    }
}

/// The Patch Bytes… sheet: enter replacement bytes as hex for the selected instruction.
/// Routes through the request-owned `store.patchBytes(_:hex:)`, which validates the hex and
/// captured owner (an invalid or stale request is rejected rather than redirected). Invalid hex is
/// rejected with a message rather than written as a garbage patch, and a valid patch re-drives
/// analysis.
/// This is what makes the "Patch Bytes…" command execute end to end instead of being a dead
/// menu item.
struct PatchBytesSheet: View {
    @ObservedObject var store: WorkspaceStore
    let request: PatchBytesRequest

    @State private var hex: String = ""
    @State private var error: String?

    private var addressText: String { "0x" + String(request.address, radix: 16) }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Patch Bytes")
                .font(.headline)
                .lumenNeverTruncates("Patch Bytes")
            Text("Replacement bytes for the instruction at \(addressText). Enter hex (e.g. 1f 20 03 d5).")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("hex bytes", text: $hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(apply)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.lumen(.statusDanger))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    store.cancelPatchBytes(request)
                }
                    .keyboardShortcut(.cancelAction)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        hex.trimmingCharacters(in: .whitespaces).isEmpty
                            || !request.hasCurrentInstruction(in: store.snapshot)
                    )
            }
        }
        .padding(Lumen.Space.s7)
        .frame(width: 360)
        .onAppear {
            // Prefill only from the exact image/binary owner captured when this sheet opened.
            if let existing = request.existingPatch(in: store.snapshot) {
                hex = existing.byteText
            }
        }
    }

    private func apply() {
        if !store.patchBytes(request, hex: hex) {
            // patchBytes surfaced the reason via lastIssue; mirror it inline.
            error = store.lastIssue ?? "Invalid hex bytes."
        }
    }
}
