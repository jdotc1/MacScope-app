import AppIntents
import LumenTokens
import LumenUI
import Foundation

extension Notification.Name {
    /// Opens a specific binary in the targeted workspace window, using the same spawn-or-reuse
    /// rule as File ▸ Open Binary. `object` is the file URL.
    static let macScopeOpenBinaryURL = Notification.Name("MacScopeOpenBinaryURL")
}

/// Errors an intent reports to Shortcuts, Spotlight or Siri in plain language.
enum MacScopeIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noWorkspace
    case fileUnavailable
    case notFound(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noWorkspace: "Open a MacScope window first."
        case .fileUnavailable: "MacScope couldn’t read that file."
        case .notFound(let reason): "\(reason)"
        }
    }
}

// MARK: Open Binary

struct OpenBinaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Binary"
    static let description = IntentDescription(
        "Opens a macOS executable, app bundle, framework or dylib in MacScope for analysis."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Binary", supportedContentTypes: [.item])
    var file: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$file) in MacScope")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let url = file.fileURL else { throw MacScopeIntentError.fileUnavailable }
        _ = try await WorkspaceApplicationOpenRouter.openIntentBinary(
            url, preferredStore: ScriptingHost.shared.activeStore
        )
        return .result()
    }
}

// MARK: Go to Address

struct GoToAddressIntent: AppIntent {
    static let title: LocalizedStringResource = "Go to Address or Symbol"
    static let description = IntentDescription(
        "Jumps the frontmost MacScope workspace to a hex address or a symbol name."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Address or Symbol", description: "A hex address such as 0x100003f40, or a symbol name.")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Go to \(\.$query) in MacScope")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let store = ScriptingHost.shared.activeStore else { throw MacScopeIntentError.noWorkspace }
        guard store.goTo(query: query) else {
            throw MacScopeIntentError.notFound(store.lastIssue ?? "MacScope couldn’t find \(query).")
        }
        return .result(dialog: "Showing \(query).")
    }
}

// MARK: Switch Theme

/// A MacScope theme (built-in or user) as Shortcuts and Spotlight see it.
struct ThemeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Theme"
    static let defaultQuery = ThemeQuery()

    let id: String
    let name: String
    let summary: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
    }

    init(_ theme: LumenTheme) {
        id = theme.id
        name = theme.displayName
        summary = theme.displaySummary
    }
}

struct ThemeQuery: EntityQuery {
    func entities(for identifiers: [ThemeEntity.ID]) async throws -> [ThemeEntity] {
        DSThemeStore.shared.themes.filter { identifiers.contains($0.id) }.map(ThemeEntity.init)
    }

    func suggestedEntities() async throws -> [ThemeEntity] {
        DSThemeStore.shared.themes.map(ThemeEntity.init)
    }
}

/// Which part of the window a theme applies to: Nova-style, the editor can differ.
enum ThemeTarget: String, AppEnum {
    case window
    case editor
    case both

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Theme Target"
    static let caseDisplayRepresentations: [ThemeTarget: DisplayRepresentation] = [
        .window: "Window",
        .editor: "Editor Only",
        .both: "Window and Editor",
    ]
}

struct SwitchThemeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Theme"
    static let description = IntentDescription(
        "Changes MacScope's theme, for the whole window or only the code editor."
    )

    @Parameter(title: "Theme")
    var theme: ThemeEntity

    @Parameter(title: "Apply To", default: .window)
    var target: ThemeTarget

    static var parameterSummary: some ParameterSummary {
        Summary("Switch MacScope to \(\.$theme)") {
            \.$target
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = DSThemeStore.shared
        switch target {
        case .window:
            store.select(theme.id)
        case .editor:
            store.selectEditorTheme(theme.id)
        case .both:
            store.select(theme.id)
            store.selectEditorTheme(nil)
        }
        return .result(dialog: "MacScope now uses \(theme.name).")
    }
}

// MARK: Shortcuts

struct MacScopeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenBinaryIntent(),
            phrases: ["Open a binary in \(.applicationName)", "Analyze a binary with \(.applicationName)"],
            shortTitle: "Open Binary",
            systemImageName: "doc.badge.gearshape"
        )
        AppShortcut(
            intent: GoToAddressIntent(),
            phrases: ["Go to an address in \(.applicationName)", "Find a symbol in \(.applicationName)"],
            shortTitle: "Go to Address",
            systemImageName: "location"
        )
        AppShortcut(
            intent: SwitchThemeIntent(),
            phrases: ["Switch \(.applicationName) theme", "Change the \(.applicationName) theme to \(\.$theme)"],
            shortTitle: "Switch Theme",
            systemImageName: "paintpalette"
        )
    }
}
