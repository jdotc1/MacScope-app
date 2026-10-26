import SwiftUI
import LumenTokens
import LumenUI

struct LogicalBreakpointsDeckView: View {
    let catalogAvailability: DebuggerLogicalBreakpointCatalogAvailability
    let rows: [DebuggerLogicalBreakpointRowPresentation]
    let sessionSummary: String
    let onAdd: () -> Void
    let onSetEnabled: (DebuggerLogicalBreakpointID, Bool) -> Void
    let onEdit: (DebuggerLogicalBreakpointID) -> Void
    let onDelete: (DebuggerLogicalBreakpointID) -> Void
    let onDiscardCorruptCatalog: () -> Void

    @State private var showsDiscardConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch catalogAvailability {
            case .available:
                availableContent
            case .unavailable:
                unavailableContent
            }
        }
        .workbenchPaneBackground(.debugger)
        .confirmationDialog(
            "Discard corrupt breakpoint catalog?",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Breakpoint Catalog", role: .destructive) {
                onDiscardCorruptCatalog()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only saved logical breakpoints and creates a fresh empty catalog. Binary analysis and other workspace authoring are preserved. This action cannot be undone.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Logical breakpoints")
        .accessibilityIdentifier(LogicalBreakpointDeckAccessibilityID.deck)
    }

    private var header: some View {
        HStack(spacing: Lumen.Space.s5) {
            VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                Text("Logical Breakpoints")
                    .font(.body.weight(.semibold))
                Text(sessionSummary)
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(LogicalBreakpointDeckAccessibilityID.summary)
            }

            Spacer(minLength: Lumen.Space.s5)

            // Lumen: the deck's one accent action.
            Button(action: onAdd) {
                Label("Add Breakpoint", systemImage: LogicalBreakpointSymbols.add)
            }
            .buttonStyle(LumenPrimaryButtonStyle())
            .dsPrimaryFocusRing()
            .disabled(catalogAvailability != .available)
            .help(catalogAvailability == .available ? "Add a saved logical breakpoint" : "Repair the breakpoint catalog before authoring")
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .accessibilityIdentifier(LogicalBreakpointDeckAccessibilityID.add)
        }
        .padding(.horizontal, Lumen.Space.s6)
        .padding(.vertical, Lumen.Space.s4)
    }

    @ViewBuilder
    private var availableContent: some View {
        if rows.isEmpty {
            VStack(spacing: Lumen.Space.s5) {
                Image(systemName: LogicalBreakpointSymbols.empty)
                    .font(.system(size: Lumen.IconSize.xlarge, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("No Saved Breakpoints")
                    .font(.headline)
                Text("Breakpoints remain available here while the debugger is idle, offline, or waiting for an image to load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Add Breakpoint", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Lumen.Space.s8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(LogicalBreakpointDeckAccessibilityID.empty)
        } else {
            List(rows) { row in
                LogicalBreakpointDeckRowView(
                    row: row,
                    onSetEnabled: { onSetEnabled(row.id, $0) },
                    onEdit: { onEdit(row.id) },
                    onDelete: { onDelete(row.id) }
                )
            }
            .listStyle(.inset)
            .accessibilityIdentifier(LogicalBreakpointDeckAccessibilityID.list)
        }
    }

    private var unavailableContent: some View {
        VStack(spacing: Lumen.Space.s6) {
            Image(systemName: LogicalBreakpointSymbols.failure)
                .font(.system(size: Lumen.IconSize.xlarge, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.lumen(.statusDanger))
                .accessibilityHidden(true)
            Text("Breakpoint Catalog Unavailable")
                .font(.headline)
            Text("The saved breakpoint catalog failed bounded integrity or schema validation. Its payload is not displayed, and no breakpoint from it is armed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Text("No saved breakpoint is armed, and ordinary save remains blocked until you explicitly repair the catalog.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Discard Corrupt Breakpoint Catalog", role: .destructive) {
                showsDiscardConfirmation = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier(LogicalBreakpointDeckAccessibilityID.discardCorrupt)
        }
        .padding(Lumen.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LogicalBreakpointDeckAccessibilityID.catalogUnavailable)
    }
}

private struct LogicalBreakpointDeckRowView: View {
    let row: DebuggerLogicalBreakpointRowPresentation
    let onSetEnabled: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// Lumen breakpoint row: marker, locator over scope, state capsule over
    /// the session hit count; clicking shows the runtime details; Enable/Disable, Edit… and Delete
    /// in the context menu (replacing the ⋯ menu).
    var body: some View {
        LumenBreakpointRow(
            isEnabled: Binding(get: { row.isEnabled }, set: { onSetEnabled($0) }),
            locator: row.locatorTitle,
            scope: "\(row.scopeTitle) · \(row.locationCount) \(row.locationCount == 1 ? "location" : "locations")",
            status: row.state.status.title,
            tone: row.state.status.tone.lumenToken,
            hits: Int(clamping: row.sessionHitCount),
            onEdit: onEdit,
            onDelete: onDelete
        ) {
            LogicalBreakpointRuntimeDetails(row: row)
        }
        .help(rowAccessibilityLabel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(rowAccessibilityID(nil))
    }

    private var rowAccessibilityLabel: String { row.accessibilityLabel }

    private func rowAccessibilityID(_ suffix: String?) -> String {
        LogicalBreakpointDeckAccessibilityID.row(row.id, suffix: suffix)
    }
}

private struct LogicalBreakpointRuntimeDetails: View {
    let row: DebuggerLogicalBreakpointRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Lumen.Space.s4) {
            Text(row.state.status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Array(row.locations.enumerated()), id: \.offset) { index, location in
                HStack(alignment: .firstTextBaseline, spacing: Lumen.Space.s5) {
                    Image(systemName: LogicalBreakpointSymbols.runtimeLocation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Lumen.Space.s2) {
                        Text(location.imageName)
                            .font(.caption.weight(.medium))
                        Text(location.runtimeAddress.hexAddress)
                            .font(AppTypography.address)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Preferred \(location.preferredAddress.hexAddress)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(location.accessibilityLabel)
                .accessibilityIdentifier(
                    LogicalBreakpointDeckAccessibilityID.location(row.id, index: index)
                )
            }

            if let diagnostic = row.state.diagnostic {
                Label(diagnostic.detail, systemImage: LogicalBreakpointSymbols.issue)
                    .font(.caption)
                    .foregroundStyle(diagnostic.tone.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        LogicalBreakpointDeckAccessibilityID.row(row.id, suffix: "diagnostic")
                    )
            }

            if row.locations.isEmpty && row.state.diagnostic == nil {
                Text("No proven runtime location is available for this saved breakpoint.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, Lumen.Space.s4)
    }
}

private enum LogicalBreakpointDeckAccessibilityID {
    static let deck = "debugger.logical-breakpoints.deck"
    static let summary = "debugger.logical-breakpoints.summary"
    static let add = "debugger.logical-breakpoints.add"
    static let list = "debugger.logical-breakpoints.list"
    static let empty = "debugger.logical-breakpoints.empty"
    static let catalogUnavailable = "debugger.logical-breakpoints.catalog-unavailable"
    static let discardCorrupt = "debugger.logical-breakpoints.discard-corrupt"

    static func row(_ id: DebuggerLogicalBreakpointID, suffix: String?) -> String {
        let base = "debugger.logical-breakpoints.row.\(id.rawValue.uuidString.lowercased())"
        guard let suffix else { return base }
        return "\(base).\(suffix)"
    }

    static func location(_ id: DebuggerLogicalBreakpointID, index: Int) -> String {
        "\(row(id, suffix: nil)).location.\(index)"
    }
}

private enum LogicalBreakpointSymbols {
    static let add = "plus"
    static let empty = "scope"
    static let failure = "exclamationmark.octagon.fill"
    static let issue = "exclamationmark.triangle.fill"
    static let more = "ellipsis"
    static let runtimeLocation = "memorychip"
}

private extension DebuggerLogicalBreakpointPresentationSymbol {
    var systemImage: String {
        switch self {
        case .none: "circle"
        case .saved: "bookmark.fill"
        case .disabled: "circle.slash"
        case .awaiting: "clock"
        case .pending: "hourglass"
        case .applying: "arrow.triangle.2.circlepath"
        case .bound: "checkmark.circle.fill"
        case .multiple: "point.3.connected.trianglepath.dotted"
        case .armed: "shield.lefthalf.filled"
        case .failure: "exclamationmark.octagon.fill"
        }
    }
}

private extension DebuggerLogicalBreakpointPresentationTone {
    /// The state capsule's color in the Lumen breakpoint row.
    var lumenToken: LumenToken {
        switch self {
        case .secondary, .disabled: .fgTertiary
        case .informational: .accent
        case .warning: .statusWarning
        case .success: .statusSuccess
        case .error: .statusDanger
        }
    }

    var foreground: Color {
        switch self {
        case .secondary, .disabled: .secondary
        case .informational: Color.lumen(.accent)
        case .warning: Color.lumen(.statusWarning)
        case .success: Color.lumen(.statusSuccess)
        case .error: Color.lumen(.statusDanger)
        }
    }
}
