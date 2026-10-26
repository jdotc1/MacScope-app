import SwiftUI
import LumenUI

/// Identifies one pending Assemble Instruction… presentation. The request owns the exact image
/// address and opening binary identity for the entire delayed edit/commit lifecycle.
struct AssembleRequest: Identifiable, Equatable {
    struct ID: Hashable {
        let presentationID: UUID
        let target: ImageAddress
        let ownerBinaryID: UUID?
    }

    /// Unique lifecycle token for this exact sheet presentation. A dismissed callback cannot
    /// become current again merely because the same instruction is reopened.
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

    /// Returns the captured instruction only while its opening binary still owns the slot.
    func instruction(in snapshot: WorkspaceSnapshot) -> InstructionRow? {
        if let ownerBinaryID {
            guard snapshot.binary(in: target.slot)?.id == ownerBinaryID else { return nil }
            return snapshot.instruction(at: target)
        }

        // Legacy binary-less fixtures predate BinaryImage but retain a primary analysis bucket.
        guard snapshot.binaries.isEmpty else { return nil }
        return snapshot.analysis(in: target.slot)?.instructions.first { $0.address == target.address }
    }

    /// Architecture is also request-owned: a focus switch cannot change the assembler or hint.
    func architectureLabel(in snapshot: WorkspaceSnapshot) -> String? {
        guard instruction(in: snapshot) != nil else { return nil }
        if let ownerBinaryID {
            guard let binary = snapshot.binary(in: target.slot), binary.id == ownerBinaryID else {
                return nil
            }
            return binary.architecture.lowercased().hasPrefix("x86_64") ? "x86-64" : "ARM64"
        }

        guard snapshot.binaries.isEmpty else { return nil }
        return "ARM64"
    }
}

/// The Assemble Instruction… sheet: type one instruction to replace the selected one.
/// Routes through the request-owned `store.assemble(_:text:)`, which validates the captured owner
/// and encodes via the architecture-appropriate assembler (`X86_64Assembler` for x86_64 targets,
/// `ARM64Assembler` otherwise) and applies
/// the bytes through the reversible patch model; an unencodable instruction is rejected with
/// the assembler's precise reason rather than written as a garbage patch. This is what makes
/// the "Assemble Instruction…" command execute end to end instead of being dead code.
struct AssembleSheet: View {
    @ObservedObject var store: WorkspaceStore
    let request: AssembleRequest

    @State private var text: String = ""
    @State private var error: String?

    private var addressText: String { "0x" + String(request.address, radix: 16) }
    private var architectureLabel: String {
        request.architectureLabel(in: store.snapshot) ?? "Unavailable"
    }

    /// An architecture-appropriate example so the hint matches the assembler that will run.
    private var exampleInstruction: String {
        architectureLabel == "x86-64" ? "mov $1, %eax" : "mov x0, #1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s5) {
            Text("Assemble Instruction")
                .font(.headline)
                .lumenNeverTruncates("Assemble Instruction")
            Text("Replace the instruction at \(addressText) with one \(architectureLabel) instruction (e.g. \(exampleInstruction)).")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("instruction", text: $text)
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
                    store.cancelAssemble(request)
                }
                    .keyboardShortcut(.cancelAction)
                Button("Assemble", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        text.trimmingCharacters(in: .whitespaces).isEmpty
                            || request.instruction(in: store.snapshot) == nil
                    )
            }
        }
        .padding(Lumen.Space.s7)
        .frame(width: 360)
        .onAppear {
            // Prefill only from the exact image/binary owner captured when this sheet opened.
            if let row = request.instruction(in: store.snapshot) {
                let operands = row.operands.trimmingCharacters(in: .whitespaces)
                text = operands.isEmpty ? row.mnemonic : "\(row.mnemonic) \(operands)"
            }
        }
    }

    private func apply() {
        if !store.assemble(request, text: text) {
            error = store.lastIssue ?? "Couldn’t assemble that instruction."
        }
    }
}
