import AppKit
import LumenTokens
import SwiftUI

/// Native theme editor: start from any theme, change colors with system color wells, watch the
/// miniature and the validation update live, and save a partial theme that inherits the rest.
///
/// Tokens are listed in the registry's groups (the app's packs decide them), with a filter field
/// and a "Changed only" toggle. Each check the validator reports links to the color it names.
public struct LumenThemeEditor: View {
    let base: LumenTheme
    let store: LumenThemeStore
    /// Saving writes into `base`'s own file (a user theme) rather than a new theme.
    let editsInPlace: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lumenPalette) private var palette
    @Environment(\.lumenMetrics) private var metrics

    @State private var name: String
    @State private var editingDark: Bool
    @State private var overrides: [Bool: [LumenToken: LumenColor]] = [:]
    @State private var saveError: String?
    @State private var filter = ""
    @State private var changedOnly = false
    /// The validator's issues for the overrides as they last rested; `nil` until the first run.
    @State private var validated: [LumenIssue]?

    /// - Parameter editsInPlace: for a user theme, Save writes the changes into its own file; otherwise
    ///   Save makes a new theme based on `base`.
    public init(base: LumenTheme, store: LumenThemeStore = .active, editsInPlace: Bool) {
        self.base = base
        self.store = store
        self.editsInPlace = editsInPlace && store.userThemeFile(for: base.id) != nil
        _name = State(initialValue: self.editsInPlace ? base.name : "\(base.name) Custom")
        let systemIsDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        _editingDark = State(initialValue: base.forcedAppearanceIsDark ?? systemIsDark)
    }

    /// An editor that saves a new theme based on `base`.
    public init(base: LumenTheme, store: LumenThemeStore = .active) {
        self.init(base: base, store: store, editsInPlace: false)
    }

    private var registry: LumenRegistry { store.registry }

    /// The theme being edited: the base plus the overrides, as a flattened theme.
    var draft: LumenTheme {
        LumenThemeLibrary.editorPreview(name: name, inheriting: base, overrides: overrides)
    }

    private var appearance: LumenAppearance { LumenAppearance(isDark: editingDark) }

    /// The registry's groups after the filter field and "Changed only": a case-insensitive match
    /// on the token name or its group title. Empty groups are dropped; order is kept.
    public nonisolated static func groups(in registry: LumenRegistry, matching query: String,
                              within changed: Set<LumenToken>? = nil) -> [(title: String, tokens: [LumenToken])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return registry.groups.compactMap { group in
            let titleMatches = !needle.isEmpty && group.title.lowercased().contains(needle)
            let kept = group.tokens.filter { token in
                (changed?.contains(token) ?? true)
                    && (needle.isEmpty || titleMatches || token.rawValue.lowercased().contains(needle))
            }
            return kept.isEmpty ? nil : (group.title, kept)
        }
    }

    /// Whether the editor offers an opacity slider for `token`: the tint roles (hover and selection
    /// fills) and component roles, which may be tints; the validator measures them composited over
    /// the canvas. Foregrounds (anything with contrast requirements, components included) and the
    /// grounds themselves (canvas, window, sidebar, elevated, inset) stay opaque.
    public nonisolated static func supportsOpacity(_ token: LumenToken, in registry: LumenRegistry) -> Bool {
        let spec = registry.spec(for: token)
        guard !(spec?.isForeground ?? false) else { return false }
        return tintRoles.contains(token) || (spec?.isComponent ?? false)
    }

    nonisolated static let tintRoles: Set<LumenToken> = [.bgHover, .bgSelected, .bgSelectedInactive]

    /// How long the overrides rest before the validator runs again: a color-well drag changes them
    /// on every tick, and the full validator per tick made dragging stutter.
    static let validationDelay: Duration = .milliseconds(120)

    public var body: some View {
        let draft = draft
        // The last validation: rows, the checks list and Save all read it. It follows the overrides
        // once they rest; typing in the filter or toggling "Changed only" doesn't validate at all.
        let issues = validated ?? LumenValidator.issues(for: draft, in: registry)
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                tokenList(draft: draft, issues: issues)
                    .frame(minWidth: 340)
                Divider()
                VStack(alignment: .leading, spacing: metrics.spacing.s6) {
                    LumenThemeMiniature(theme: draft, registry: registry, appearance: appearance)
                        .clipShape(.rect(cornerRadius: metrics.radius.md))
                        .overlay { RoundedRectangle(cornerRadius: metrics.radius.md).strokeBorder(palette[.borderSubtle]) }
                    validation(issues)
                    Spacer(minLength: 0)
                }
                .padding(metrics.spacing.s6)
                .frame(width: 300)
            }
            Divider()
            footer(issues)
        }
        .frame(minWidth: 680, minHeight: 520)
        .accessibilityIdentifier("lumen.theme.editor-sheet")
        .task(id: overrides) {
            if validated != nil {
                try? await Task.sleep(for: Self.validationDelay)
                guard !Task.isCancelled else { return }
            }
            validated = LumenValidator.issues(for: self.draft, in: registry)
        }
    }

    private var header: some View {
        HStack(spacing: metrics.spacing.s5) {
            TextField("Theme name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .disabled(editsInPlace)
            Text(editsInPlace ? "Editing \(base.name)" : "Based on \(base.name)")
                .font(metrics.typography.caption)
                .foregroundStyle(palette[.fgTertiary])
            Spacer()
            if base.forcedAppearanceIsDark == nil {
                LumenModeSwitcher(selection: $editingDark, options: [false, true], style: .pill,
                                  title: { $0 ? "Dark" : "Light" })
                    .lumenModeSwitcherPlacement(.content)
                    .accessibilityLabel("Appearance")
            }
        }
        .padding(metrics.spacing.s5)
    }

    private func tokenList(draft: LumenTheme, issues: [LumenIssue]) -> some View {
        let changed: Set<LumenToken>? = changedOnly ? Set(overrides[editingDark]?.keys.map { $0 } ?? []) : nil
        let shown = Self.groups(in: registry, matching: filter, within: changed)
        return VStack(spacing: 0) {
            HStack(spacing: metrics.spacing.s4) {
                TextField("Filter colors", text: $filter, prompt: Text("Filter colors, e.g. sidebar or accent"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("lumen.theme.editor.filter")
                Toggle("Changed only", isOn: $changedOnly)
                    .toggleStyle(.lumenCheckbox)
                    .fixedSize()
            }
            .padding(.horizontal, metrics.spacing.s5)
            .padding(.vertical, metrics.spacing.s3)
            if shown.isEmpty {
                LumenEmptyState(systemImage: "paintpalette", title: "No matching colors",
                                message: changedOnly ? "You haven’t changed any colors that match." : "No color name matches the filter.",
                                actionTitle: "Clear filter") {
                    filter = ""
                    changedOnly = false
                }
            } else {
                List {
                    ForEach(shown, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.tokens, id: \.self) { token in
                                row(for: token, draft: draft, issues: issues)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(for token: LumenToken, draft: LumenTheme, issues: [LumenIssue]) -> some View {
        let isOverridden = overrides[editingDark]?[token] != nil
        let binding = Binding<Color>(
            get: { Color(nsColor: draft.nsColor(token, for: appearance, in: registry)) },
            set: { newValue in
                // Store components in the theme's own color space: a Display P3 theme reads its hex
                // values as P3, so sRGB components would shift every picked color.
                guard let picked = LumenColor(NSColor(newValue), in: draft.colorSpace) else { return }
                overrides[editingDark, default: [:]][token] = picked
            }
        )
        // This appearance's issues for the token, Increase Contrast's included.
        let rowIssues = issues.filter { $0.token == token && $0.appearance.isDark == editingDark }
        return HStack(spacing: metrics.spacing.s4) {
            ColorPicker(token.rawValue, selection: binding, supportsOpacity: Self.supportsOpacity(token, in: registry))
                .font(metrics.typography.monoCaption)
                .help(registry.spec(for: token)?.summary ?? "")
            Spacer()
            Text(draft.color(token, for: appearance, in: registry).hexString)
                .font(metrics.typography.monoCaption)
                .foregroundStyle(palette[isOverridden ? .fgPrimary : .fgTertiary])
            if isOverridden {
                Button("Revert \(token.rawValue)", systemImage: "arrow.uturn.backward") {
                    overrides[editingDark]?[token] = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.lumenPanelIcon)
                .lumenIconOnlyControl("Revert \(token.rawValue)")
                .help("Revert to the theme's value")
            }
            if !rowIssues.isEmpty {
                LumenSymbol("exclamationmark.triangle.fill")
                    .foregroundStyle(palette[rowIssues.contains { $0.severity == .error } ? .statusDanger : .statusWarning])
                    .help(rowIssues.map(\.message).joined(separator: "\n"))
                    .accessibilityLabel(rowIssues.map(\.message).joined(separator: ". "))
            }
        }
    }

    /// Every issue, the appearance being edited first; issues elsewhere name their appearance. Save
    /// waits on errors anywhere, so the list shows them all.
    private func validation(_ issues: [LumenIssue]) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing.s3) {
            LumenSectionHeader("Checks")
            let current = issues.filter { $0.appearance == appearance }
                + issues.filter { $0.appearance != appearance }.sorted { $0.severity == .error && $1.severity != .error }
            if current.isEmpty {
                Label("Meets the contrast rules", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(palette[.statusSuccess])
                    .font(metrics.typography.callout)
            } else {
                ForEach(current.prefix(6)) { issue in
                    Button {
                        // Show the color the issue names, so it can be fixed right away.
                        if let token = issue.token {
                            filter = token.rawValue
                            changedOnly = false
                            if base.forcedAppearanceIsDark == nil { editingDark = issue.appearance.isDark }
                        }
                    } label: {
                        Label(issue.appearance == appearance ? issue.message : "\(issue.appearance): \(issue.message)", systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(palette[issue.severity == .error ? .statusDanger : .statusWarning])
                            .font(metrics.typography.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.lumenPlain).lumenFocusRing()
                    .disabled(issue.token == nil)
                    .help(issue.token.map { "Show \($0.rawValue)" } ?? "")
                }
                if current.count > 6 {
                    Text("and \(current.count - 6) more").font(metrics.typography.caption).foregroundStyle(palette[.fgTertiary])
                }
            }
        }
    }

    private func footer(_ issues: [LumenIssue]) -> some View {
        let hasErrors = issues.contains { $0.severity == .error }
        return HStack {
            if let saveError {
                Label(saveError, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(palette[.statusDanger])
                    .font(metrics.typography.caption)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(editsInPlace ? "Save Changes" : "Save Theme") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || hasErrors)
                .help(hasErrors ? "Fix the contrast errors to save" : "Save as a user theme")
        }
        .padding(metrics.spacing.s5)
    }

    /// Writes only the overrides, inheriting everything else from `base`.
    private func save() {
        // The shown checks can trail the last edit by `validationDelay`; Save checks the overrides as
        // they are now.
        let current = LumenValidator.issues(for: draft, in: registry)
        validated = current
        guard !current.contains(where: { $0.severity == .error }) else { return }
        do {
            if editsInPlace {
                try store.updateUserTheme(base.id, overrides: overrides)
            } else {
                _ = try store.saveUserTheme(name: name, inheriting: base, overrides: overrides)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview("Theme editor") {
    LumenThemeEditor(base: LumenThemes.midnight,
                     store: LumenThemeStore(registry: .core, configuration: .init(appName: "LumenPreview"),
                                            themes: LumenRegistry.core.galleryThemes, persistsSelection: false))
        .frame(width: 760, height: 600)
}
