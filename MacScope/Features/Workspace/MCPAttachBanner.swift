import LumenUI
import SwiftUI

/// The window's agent-attach strip: asks to Allow/Deny a pending agent, then shows that an agent
/// is attached with a Disconnect button. Also registers the window with the coordinator so an
/// agent can find it, and marks it most recently active when it becomes key.
struct MCPAttachBanner: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var coordinator: MCPAttachCoordinator = .shared
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        let connections = coordinator.connections(for: store)
        VStack(spacing: Lumen.Space.s2) {
            ForEach(connections) { connection in
                MCPAttachConnectionBanner(
                    workspaceName: connection.workspaceName,
                    consent: connection.consent,
                    onAllow: { coordinator.allow(connection.id) },
                    onDeny: { coordinator.deny(connection.id) },
                    onDisconnect: { coordinator.disconnect(connection.id) }
                )
            }
        }
        .padding(connections.isEmpty ? 0 : Lumen.Space.s4)
        .onAppear { coordinator.register(store) }
        .onDisappear { coordinator.unregister(store) }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { coordinator.noteActive(store) }
        }
    }
}

/// One connection's banner, separate from the coordinator so it renders in review images.
struct MCPAttachConnectionBanner: View {
    let workspaceName: String
    let consent: MCPAttachExecutor.Consent
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        switch consent {
        case .pending:
            // Explicit Deny beside Allow (the banner's × alone wasn't clear).
            VStack(alignment: .trailing, spacing: Lumen.Space.s2) {
                LumenBanner(
                    "An MCP agent wants to read and edit \"\(workspaceName)\". Its edits are undoable.",
                    title: "Agent wants to attach",
                    tone: .info,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    spokenPrefix: "Agent request"
                )
                HStack(spacing: Lumen.Space.s3) {
                    Button("Deny", action: onDeny)
                        .buttonStyle(LumenQuietButtonStyle())
                        .accessibilityIdentifier("mcpAttach.deny")
                    Button("Allow", action: onAllow)
                        .buttonStyle(LumenTintedButtonStyle())
                        .accessibilityIdentifier("mcpAttach.allow")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mcpAttach.pending")
        case .allowed:
            LumenBanner(
                "Edits appear as \"Agent: …\" in Undo.",
                title: "Agent attached",
                tone: .success,
                systemImage: "point.3.connected.trianglepath.dotted",
                actionTitle: "Disconnect",
                action: onDisconnect,
                spokenPrefix: "Agent"
            )
            .accessibilityIdentifier("mcpAttach.attached")
        case .revoked:
            EmptyView()
        }
    }
}
