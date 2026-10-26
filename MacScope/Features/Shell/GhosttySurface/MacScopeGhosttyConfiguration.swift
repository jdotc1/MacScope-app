import Foundation

/// MacScope-owned configuration for the embedded terminal renderer.
///
/// This value intentionally contains no Ghostty types, paths, shell command, or application
/// lifecycle settings. A host adapter may translate it to the reviewed Ghostty API, but cannot
/// use it to enable shell integration or Ghostty-owned window/tab/split behavior.
struct MacScopeGhosttyConfiguration: Equatable, Sendable {
    enum Font: Equatable, Sendable {
        case systemMonospaced(sizePoints: Double)
    }

    enum Theme: Equatable, Sendable {
        case followSystem
    }

    enum Cursor: Equatable, Sendable {
        case block(blinks: Bool)
    }

    enum HyperlinkPolicy: Equatable, Sendable {
        /// Links are inert until direct human activation and are then limited to HTTP(S).
        case humanActivatedHTTPAndHTTPSOnly
    }

    enum KeyboardProtocol: Equatable, Sendable {
        case kitty
    }

    enum ShellIntegration: Equatable, Sendable {
        case disabled
    }

    enum ApplicationCommands: Equatable, Sendable {
        /// New window/tab/split, quit, updater, config reload, and notifications stay disabled.
        case disabled
    }

    static let terminalOnlyDefault = MacScopeGhosttyConfiguration(
        font: .systemMonospaced(sizePoints: 13),
        theme: .followSystem,
        scrollbackLimitBytes: 16 * 1_048_576,
        cursor: .block(blinks: true),
        backgroundOpacity: 1,
        hyperlinkPolicy: .humanActivatedHTTPAndHTTPSOnly,
        keyboardProtocol: .kitty,
        shellIntegration: .disabled,
        applicationCommands: .disabled
    )

    let font: Font
    let theme: Theme
    let scrollbackLimitBytes: Int
    let cursor: Cursor
    let backgroundOpacity: Double
    let hyperlinkPolicy: HyperlinkPolicy
    let keyboardProtocol: KeyboardProtocol
    let shellIntegration: ShellIntegration
    let applicationCommands: ApplicationCommands

    private init(
        font: Font,
        theme: Theme,
        scrollbackLimitBytes: Int,
        cursor: Cursor,
        backgroundOpacity: Double,
        hyperlinkPolicy: HyperlinkPolicy,
        keyboardProtocol: KeyboardProtocol,
        shellIntegration: ShellIntegration,
        applicationCommands: ApplicationCommands
    ) {
        precondition(scrollbackLimitBytes > 0)
        precondition((0 ... 1).contains(backgroundOpacity))
        self.font = font
        self.theme = theme
        self.scrollbackLimitBytes = scrollbackLimitBytes
        self.cursor = cursor
        self.backgroundOpacity = backgroundOpacity
        self.hyperlinkPolicy = hyperlinkPolicy
        self.keyboardProtocol = keyboardProtocol
        self.shellIntegration = shellIntegration
        self.applicationCommands = applicationCommands
    }
}
