import AppKit

/// A minimal, injectable clipboard seam so the Copy commands route through `WorkspaceStore`
/// like every other command yet stay unit-testable (a fake pasteboard captures the string
/// without touching the real system clipboard).
protocol WorkspacePasteboard {
    func setString(_ string: String)
}

/// The real macOS general pasteboard.
struct SystemPasteboard: WorkspacePasteboard {
    func setString(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
