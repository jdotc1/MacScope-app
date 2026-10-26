import AppKit
import SwiftUI
import LumenTokens
import LumenUI

// Preserve MacScope's names and schema while Lumen owns the shared implementation.
enum MacScopeLumen {
    static let registry = LumenRegistry.macScope
}

extension LumenToken {
    /// MacScope's 104 theme roles in export/editor order: the original 110 less the six U5e retired
    /// (graph.edge.*, welcome.accent), with bg.currentLine now Lumen's code.currentLine.
    static let allCases: [LumenToken] = [
        .bgWindow,
        .bgSidebar,
        .bgCanvas,
        .bgGutter,
        .bgElevated,
        .bgInset,
        .bgHover,
        .bgSelected,
        .bgSelectedInactive,
        LumenToken.Code.currentLine,
        .fgPrimary,
        .fgSecondary,
        .fgTertiary,
        .fgDisabled,
        .fgOnAccent,
        .fgLink,
        .borderSubtle,
        .borderDefault,
        .borderStrong,
        .borderFocus,
        .accent,
        .accentSubtle,
        .accentSoft,
        .statusSuccess,
        .statusWarning,
        .statusDanger,
        .statusInfo,
        .statusNeutral,
        .statusSuccessBackground,
        .statusWarningBackground,
        .statusDangerBackground,
        .statusInfoBackground,
        .statusNeutralBackground,
        .evidenceProven,
        .evidenceInferred,
        .evidenceUnknown,
        .evidenceMissing,
        .syntaxMnemonicBranch,
        .syntaxMnemonicArithmetic,
        .syntaxMnemonicMemory,
        .syntaxMnemonicGeneral,
        .syntaxRegister,
        .syntaxImmediate,
        .syntaxAddress,
        .syntaxModifier,
        .syntaxPunctuation,
        .syntaxOperator,
        .syntaxComment,
        .syntaxString,
        .syntaxKeyword,
        .syntaxType,
        .syntaxFunction,
        .syntaxVariable,
        .syntaxNumber,
        .debugBreakpoint,
        .debugProgramCounter,
        .debugPatched,
        .sidebarBackground,
        .sidebarRowSelected,
        .sidebarRowHover,
        .toolbarBackground,
        .tabActiveFill,
        .tabAccentBar,
        .inspectorBackground,
        .listingSelection,
        .listingCurrentLine,
        .listingAlternateRow,
        .listingProgramCounterRow,
        .listingPatchedRow,
        .listingSecondaryText,
        .statusbarBackground,
        .graphNodeBackground,
        .graphLaneBackground,
        .deckBackground,
        .deckRowBackground,
        .kindFunction,
        .kindSymbol,
        .kindImport,
        .kindSegment,
        .kindSection,
        .kindString,
        .kindType,
        .kindImage,
        .kindSecurity,
        .kindDebug,
        .terminalForeground,
        .terminalBackground,
        .terminalCursor,
        .terminalBlack,
        .terminalRed,
        .terminalGreen,
        .terminalYellow,
        .terminalBlue,
        .terminalMagenta,
        .terminalCyan,
        .terminalWhite,
        .terminalBrightBlack,
        .terminalBrightRed,
        .terminalBrightGreen,
        .terminalBrightYellow,
        .terminalBrightBlue,
        .terminalBrightMagenta,
        .terminalBrightCyan,
        .terminalBrightWhite,
    ]
    static let terminalANSI: [LumenToken] = [
        .terminalBlack, .terminalRed, .terminalGreen, .terminalYellow,
        .terminalBlue, .terminalMagenta, .terminalCyan, .terminalWhite,
        .terminalBrightBlack, .terminalBrightRed, .terminalBrightGreen, .terminalBrightYellow,
        .terminalBrightBlue, .terminalBrightMagenta, .terminalBrightCyan, .terminalBrightWhite,
    ]
    static let groups: [(title: String, tokens: [LumenToken])] = {
        let sections: [(String, [String])] = [
            ("Surfaces", ["bg.", "code."]),
            ("Text and Lines", ["fg.", "border."]),
            ("Accent", ["accent."]),
            ("Status and Evidence", ["status.", "evidence."]),
            ("Syntax", ["syntax."]),
            ("Debugger", ["debug."]),
            ("Window Chrome", ["sidebar.", "toolbar.", "tab.", "inspector.", "statusbar.", "welcome."]),
            ("Listing", ["listing."]),
            ("Object Kinds", ["kind."]),
            ("Graph", ["graph."]),
            ("Debugger and Shell Decks", ["deck."]),
            ("Terminal", ["terminal."]),
        ]
        return sections.map { title, prefixes in
            (title, LumenToken.allCases.filter { token in prefixes.contains { token.rawValue.hasPrefix($0) } })
        }
    }()


    var isEditorOwned: Bool { MacScopeLumen.registry.surface(of: self) == .editor }
    var fallback: LumenToken? { MacScopeLumen.registry.spec(for: self)?.fallback?.base }
    var isComponent: Bool { MacScopeLumen.registry.spec(for: self)?.isComponent ?? false }
    var derivedFallback: (alpha: Double, over: LumenToken)? {
        guard case let .composite(_, alpha, over) = MacScopeLumen.registry.spec(for: self)?.fallback else { return nil }
        return (alpha, over)
    }
    var fallbackDescription: String? { MacScopeLumen.registry.spec(for: self)?.fallback?.description }
    var followsSystemAccent: Bool { MacScopeLumen.registry.spec(for: self)?.followsSystemAccent ?? false }
    var isReadableText: Bool {
        if self == .listingSecondaryText { return true }
        guard !isComponent, !rawValue.hasSuffix("Background") else { return false }
        if [.fgPrimary, .fgSecondary, .fgTertiary, .fgLink].contains(self) { return true }
        return ["syntax.", "status.", "evidence.", "debug."].contains(where: rawValue.hasPrefix)
    }
    static var semantic: [LumenToken] { allCases.filter { !$0.isComponent } }
}

extension LumenTheme {
    var supportedColorSchemes: [ColorScheme] { supportedAppearances.map { $0 ? .dark : .light } }
    func hex(_ token: LumenToken, for appearance: LumenAppearance) -> LumenColor {
        color(token, for: appearance, in: MacScopeLumen.registry)
    }
    func nsColor(_ token: LumenToken, for appearance: LumenAppearance) -> NSColor {
        nsColor(token, for: appearance, in: MacScopeLumen.registry)
    }
    var missingTokens: [(ColorScheme, LumenToken)] {
        supportedColorSchemes.flatMap { scheme in
            let palette = scheme == .dark ? dark : light
            return LumenToken.semantic.filter { palette?[$0] == nil }.map { (scheme, $0) }
        }
    }
}
