import SwiftUI
import LumenTokens
import LumenUI

/// The welcome surface for an empty workspace: the starfield behind the app mark, one line of
/// what MacScope does, and one primary action. Hovering the action makes the stars surge.
struct DSWelcomeView: View {
    /// A recent workspace offered on the welcome surface.
    struct Recent: Identifiable {
        let url: URL
        let open: () -> Void
        var id: URL { url }
    }

    let title: String
    let message: String
    let actionTitle: String
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?
    var recents: [Recent] = []
    let action: () -> Void

    /// Lumen's empty hero (0.13.0; identifiers and `primaryIsDefault` 0.34.2): the
    /// glowing mark over a quiet starfield, the title and one sentence, Open Binary… as the one accent
    /// action, Open Workspace… quiet, Recent Workspaces below. Return is left to the window's fields.
    /// The installed-app UI tests find it by `workspace.empty.*`; the container identifier sits on the
    /// hero itself, so it exists whether or not the hero scrolls.
    var body: some View {
        LumenEmptyHero(
            title,
            message: message,
            systemImage: "cpu",
            hue: .huePink,
            primary: LumenBarAction(actionTitle, accessibilityIdentifier: "workspace.empty.open-binary", perform: action),
            secondary: secondaryActions,
            recents: recents.map { recent in
                LumenRecentItem(
                    id: recent.url.path(percentEncoded: false),
                    title: recent.url.deletingPathExtension().lastPathComponent,
                    detail: recent.url.deletingLastPathComponent().path(percentEncoded: false)
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    systemImage: "folder.fill",
                    hue: .hueBlue
                )
            },
            recentsTitle: "Recent Workspaces",
            onOpenRecent: { item in
                recents.first { $0.url.path(percentEncoded: false) == item.id }?.open()
            },
            primaryIsDefault: false,
            identifiers: (container: "workspace.empty.scroll", recents: "workspace.empty.recents")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var secondaryActions: [LumenBarAction] {
        guard let secondaryActionTitle, let secondaryAction else { return [] }
        return [LumenBarAction(secondaryActionTitle, accessibilityIdentifier: "workspace.empty.open-workspace",
                            perform: secondaryAction)]
    }
}

#Preview("Welcome") {
    DSWelcomeView(
        title: "No binary open",
        message: "Open a macOS executable, app bundle, framework, or dylib to begin analysis.",
        actionTitle: "Open Binary…",
        action: {}
    )
    .frame(width: 820, height: 520)
    .background(.lumen(.bgCanvas))
}
