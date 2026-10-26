import AppKit
import SwiftUI
import LumenTokens
import LumenUI

// MARK: Validation

/// The rules every MacScope theme must meet, shared by the theme editor and the tests.
enum DSThemeValidator {
    struct Issue: Hashable, Identifiable, Sendable {
        enum Severity: Sendable { case error, warning }
        let severity: Severity
        let appearance: LumenAppearance
        let token: LumenToken?
        let message: String
        var id: String { "\(appearance.isDark)\(appearance.isHighContrast)\(token?.rawValue ?? "")\(message)" }
    }

    /// Text and syntax roles that must reach WCAG AA (4.5:1) on the canvas.
    static var readableTokens: [LumenToken] { LumenToken.allCases.filter(\.isReadableText) }

    /// Roles native pseudocode draws side by side; each needs its own color.
    static let pseudocodeTokens: [LumenToken] = [
        .syntaxComment, .syntaxVariable, .syntaxKeyword, .syntaxNumber,
        .syntaxOperator, .syntaxPunctuation, .syntaxType,
    ]

    /// Text the disassembly listing draws on its rows: mnemonics, operands, addresses and bytes
    /// (`fg.tertiary`), and data-row declarations (`syntax.address`).
    static let listingTextTokens: [LumenToken] = [
        .syntaxMnemonicBranch, .syntaxMnemonicArithmetic, .syntaxMnemonicMemory, .syntaxMnemonicGeneral,
        .syntaxRegister, .syntaxImmediate, .syntaxAddress, .syntaxModifier, .syntaxPunctuation, .fgTertiary,
        .listingSecondaryText,
    ]

    /// Object-kind colors, which sit side by side in the navigator.
    static var kindTokens: [LumenToken] { LumenToken.allCases.filter { $0.rawValue.hasPrefix("kind.") } }

    /// Minimum OKLab distance between two kind colors (see `LumenColor.perceptualDistance`).
    static let kindSeparation = 0.06

    private static func compatibilityIssue(_ issue: LumenIssue) -> Issue {
        Issue(severity: issue.severity == .error ? .error : .warning,
              appearance: issue.appearance, token: issue.token,
              message: issue.message.replacingOccurrences(of: "is not a color this app knows", with: "is not a MacScope color"))
    }

    static func unknownKeyIssues(in theme: LumenTheme) -> [Issue] {
        LumenValidator.unknownKeyIssues(in: theme, registry: MacScopeLumen.registry).map(compatibilityIssue)
    }

    static func issues(for theme: LumenTheme) -> [Issue] {
        LumenValidator.issues(for: theme, in: MacScopeLumen.registry).map(compatibilityIssue)
    }
}

// MARK: Editor

/// App-facing compatibility wrapper; Lumen owns editing, validation, and saving.
struct DSThemeEditor: View {
    let base: LumenTheme
    var store: DSThemeStore = .active

    nonisolated static func supportsOpacity(_ token: LumenToken) -> Bool {
        LumenThemeEditor.supportsOpacity(token, in: MacScopeLumen.registry)
    }

    /// Retain the historical token-reference surface while the editor exposes the complete registry.
    nonisolated static var groups: [(String, [LumenToken])] { LumenToken.groups.map { ($0.title, $0.tokens) } }

    nonisolated static func groups(matching query: String, within changed: Set<LumenToken>? = nil) -> [(String, [LumenToken])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.compactMap { title, tokens in
            let titleMatches = !needle.isEmpty && title.lowercased().contains(needle)
            let kept = tokens.filter { token in
                (changed?.contains(token) ?? true)
                    && (needle.isEmpty || titleMatches || token.rawValue.lowercased().contains(needle))
            }
            return kept.isEmpty ? nil : (title, kept)
        }
    }

    var body: some View {
        LumenThemeEditor(base: base, store: store.lumen)
            .accessibilityIdentifier("settings.theme.editor-sheet")
    }
}

extension DSThemeStore {
    static func editorPreview(name: String, inheriting base: LumenTheme,
                              overrides: [Bool: [LumenToken: LumenColor]]) -> LumenTheme {
        LumenThemeLibrary.editorPreview(name: name, inheriting: base, overrides: overrides)
    }

    @discardableResult
    func saveUserTheme(name: String, inheriting base: LumenTheme, overrides: [Bool: [LumenToken: LumenColor]]) throws -> URL {
        try lumen.saveUserTheme(name: name, inheriting: base, overrides: overrides)
    }

    static func partialTheme(name: String, inheriting base: LumenTheme, overrides: [Bool: [LumenToken: LumenColor]],
                             existingIDs: Set<String>) -> LumenTheme {
        LumenThemeLibrary.partialTheme(name: name, inheriting: base, overrides: overrides, existingIDs: existingIDs)
    }
}

#Preview("Theme editor") {
    DSThemeEditor(base: DSBuiltInThemes.midnight, store: DSThemeStore(persistsSelection: false))
        .frame(width: 760, height: 600)
}
