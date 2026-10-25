// The MacScope pack: MacScope's 72 domain roles, its three themes (under their existing ids) and
// its rules, on top of Lumen's core. MacScopeTheme is its own target in this package, built on
// LumenTokens.

import Foundation
import LumenTokens

public extension LumenSurface {
    /// MacScope's code canvas: listing, gutter, graph, pseudocode, terminal.
    static let editor = LumenSurface("editor")
}

public extension LumenToken {
    static let bgGutter: LumenToken = "bg.gutter"
    static let bgCurrentLine: LumenToken = "bg.currentLine"
    static let evidenceProven: LumenToken = "evidence.proven"
    static let evidenceInferred: LumenToken = "evidence.inferred"
    static let evidenceUnknown: LumenToken = "evidence.unknown"
    static let evidenceMissing: LumenToken = "evidence.missing"
    static let syntaxMnemonicBranch: LumenToken = "syntax.mnemonicBranch"
    static let syntaxMnemonicArithmetic: LumenToken = "syntax.mnemonicArithmetic"
    static let syntaxMnemonicMemory: LumenToken = "syntax.mnemonicMemory"
    static let syntaxMnemonicGeneral: LumenToken = "syntax.mnemonicGeneral"
    static let syntaxRegister: LumenToken = "syntax.register"
    static let syntaxImmediate: LumenToken = "syntax.immediate"
    static let syntaxAddress: LumenToken = "syntax.address"
    static let syntaxModifier: LumenToken = "syntax.modifier"
    static let syntaxPunctuation: LumenToken = "syntax.punctuation"
    static let syntaxOperator: LumenToken = "syntax.operator"
    static let syntaxComment: LumenToken = "syntax.comment"
    static let syntaxString: LumenToken = "syntax.string"
    static let syntaxKeyword: LumenToken = "syntax.keyword"
    static let syntaxType: LumenToken = "syntax.type"
    static let syntaxFunction: LumenToken = "syntax.function"
    static let syntaxVariable: LumenToken = "syntax.variable"
    static let syntaxNumber: LumenToken = "syntax.number"
    static let debugBreakpoint: LumenToken = "debug.breakpoint"
    static let debugProgramCounter: LumenToken = "debug.programCounter"
    static let debugPatched: LumenToken = "debug.patched"
    static let listingSelection: LumenToken = "listing.selection"
    static let listingCurrentLine: LumenToken = "listing.currentLine"
    static let listingAlternateRow: LumenToken = "listing.alternateRow"
    static let listingProgramCounterRow: LumenToken = "listing.programCounterRow"
    static let listingPatchedRow: LumenToken = "listing.patchedRow"
    static let listingSecondaryText: LumenToken = "listing.secondaryText"
    static let statusbarBackground: LumenToken = "statusbar.background"
    static let welcomeAccent: LumenToken = "welcome.accent"
    static let graphEdgeBranch: LumenToken = "graph.edge.branch"
    static let graphEdgeCall: LumenToken = "graph.edge.call"
    static let graphEdgeReference: LumenToken = "graph.edge.reference"
    static let graphEdgeFallthrough: LumenToken = "graph.edge.fallthrough"
    static let graphEdgeSelected: LumenToken = "graph.edge.selected"
    static let graphNodeBackground: LumenToken = "graph.node.background"
    static let graphLaneBackground: LumenToken = "graph.lane.background"
    static let deckBackground: LumenToken = "deck.background"
    static let deckRowBackground: LumenToken = "deck.rowBackground"
    static let kindFunction: LumenToken = "kind.function"
    static let kindSymbol: LumenToken = "kind.symbol"
    static let kindImport: LumenToken = "kind.import"
    static let kindSegment: LumenToken = "kind.segment"
    static let kindSection: LumenToken = "kind.section"
    static let kindString: LumenToken = "kind.string"
    static let kindType: LumenToken = "kind.type"
    static let kindImage: LumenToken = "kind.image"
    static let kindSecurity: LumenToken = "kind.security"
    static let kindDebug: LumenToken = "kind.debug"
    static let terminalForeground: LumenToken = "terminal.foreground"
    static let terminalBackground: LumenToken = "terminal.background"
    static let terminalCursor: LumenToken = "terminal.cursor"
    static let terminalBlack: LumenToken = "terminal.ansi.black"
    static let terminalRed: LumenToken = "terminal.ansi.red"
    static let terminalGreen: LumenToken = "terminal.ansi.green"
    static let terminalYellow: LumenToken = "terminal.ansi.yellow"
    static let terminalBlue: LumenToken = "terminal.ansi.blue"
    static let terminalMagenta: LumenToken = "terminal.ansi.magenta"
    static let terminalCyan: LumenToken = "terminal.ansi.cyan"
    static let terminalWhite: LumenToken = "terminal.ansi.white"
    static let terminalBrightBlack: LumenToken = "terminal.ansi.brightBlack"
    static let terminalBrightRed: LumenToken = "terminal.ansi.brightRed"
    static let terminalBrightGreen: LumenToken = "terminal.ansi.brightGreen"
    static let terminalBrightYellow: LumenToken = "terminal.ansi.brightYellow"
    static let terminalBrightBlue: LumenToken = "terminal.ansi.brightBlue"
    static let terminalBrightMagenta: LumenToken = "terminal.ansi.brightMagenta"
    static let terminalBrightCyan: LumenToken = "terminal.ansi.brightCyan"
    static let terminalBrightWhite: LumenToken = "terminal.ansi.brightWhite"
}

extension MacScopeThemes {
    /// Lumen's hue family and other new roles MacScope never had (icon tiles, categories, the
    /// activity capsule) added to
    /// MacScope's own themes: Scope takes the standard hues, Contrast the deeper set in light and its
    /// bright dark set in dark (also Scope's Increase Contrast variants), Midnight the brighter set.
    static func withLumenHues(_ theme: LumenTheme) -> LumenTheme {
        var theme = theme
        let base = theme.id == midnightID ? LumenThemes.midnightHues : theme.id == contrastID ? LumenThemes.contrastHues : LumenThemes.standardHues
        // New roles MacScope never had: the activity capsule (a step lighter than bg.inset in Scope
        // light, so status text on it reaches 4.5:1).
        let additions: LumenPalette = theme.id == scopeID ? [.activityBackground: "#F3F4F6"] : [:]
        theme.light = theme.light.map { base.merging($0).merging(additions) }
        let darkBase = theme.id == contrastID ? LumenThemes.contrastDarkHues : base
        theme.dark = theme.dark.map { darkBase.merging($0) }
        theme.lightHighContrast = theme.lightHighContrast.map { LumenThemes.contrastHues.merging($0) }
        theme.darkHighContrast = theme.darkHighContrast.map { LumenThemes.contrastDarkHues.merging($0) }
        return theme
    }

    /// Only new core chrome roles are overridden; the 110 legacy MacScope roles are retained.
    static func withLumenTitlebar(_ theme: LumenTheme) -> LumenTheme {
        var theme = theme
        let light: LumenPalette = theme.id == contrastID
            ? [.titlebarActiveTop: "#FFFFFF", .titlebarActiveBottom: "#FFFFFF"]
            : [.titlebarActiveTop: "#ECE8FA", .titlebarActiveBottom: "#F3F2F8", .layoutToggleOn: "#1F66D1"]
        let dark: LumenPalette = switch theme.id {
        case contrastID: [.titlebarActiveTop: "#000000", .titlebarActiveBottom: "#000000"]
        case midnightID: [.titlebarActiveTop: "#2A0E40", .titlebarActiveBottom: "#0E1331"]
        default: [.titlebarActiveTop: "#2A2442", .titlebarActiveBottom: "#201E2E"]
        }
        theme.light = theme.light.map { $0.merging(light) }
        theme.dark = theme.dark.map { $0.merging(dark) }
        theme.lightHighContrast = theme.lightHighContrast.map {
            $0.merging([.titlebarActiveTop: "#FFFFFF", .titlebarActiveBottom: "#FFFFFF"])
        }
        theme.darkHighContrast = theme.darkHighContrast.map {
            $0.merging([.titlebarActiveTop: "#000000", .titlebarActiveBottom: "#000000"])
        }
        return theme
    }
}

/// MacScope's themes carry every color themselves (all 110 roles), so MacScope keeps its look
/// whatever Lumen's own themes look like. They don't inherit Lumen's themes.
public enum MacScopeThemes {
    public static let scopeID = "com.macscope.theme.scope"
    public static let midnightID = "com.macscope.theme.midnight"
    public static let contrastID = "com.macscope.theme.contrast"

    static let scope = LumenTheme(
        id: "com.macscope.theme.scope",
        name: "Scope",
        summary: "Cool slate with a violet accent. Follows Light and Dark.",
        light: [
            .bgWindow: "#ECEEF2", .bgSidebar: "#F6F6F8", .bgCanvas: "#FFFFFF", .bgGutter: "#F7F8FA",
            .bgElevated: "#FFFFFF", .bgInset: "#EEF0F3", .bgHover: "#E9EBF0", .bgSelected: "#E4DFFF",
            .bgSelectedInactive: "#ECEAF3", .bgCurrentLine: "#F4F2FF", .fgPrimary: "#1B1E26", .fgSecondary: "#4A5162",
            .fgTertiary: "#5C6476", .fgDisabled: "#A3A9B5", .fgOnAccent: "#FFFFFF", .fgLink: "#5443C9",
            .borderSubtle: "#E4E6EB", .borderDefault: "#DADADD", .borderStrong: "#B4B9C4", .borderFocus: "#6757D0",
            .accent: "#6757D0", .accentSubtle: "#EEEBFF", .accentSoft: "#B0A2FF", .statusSuccess: "#1E7F46",
            .statusWarning: "#935600", .statusDanger: "#C4283F", .statusInfo: "#2966B8", .statusNeutral: "#4A5162",
            .statusSuccessBackground: "#EDF5F0", .statusWarningBackground: "#EEE4D6",
            .statusDangerBackground: "#F7E1E4", .statusInfoBackground: "#DDE7F4", .statusNeutralBackground: "#EDEEEF",
            .evidenceProven: "#1E7F46", .evidenceInferred: "#935600", .evidenceUnknown: "#646C7E",
            .evidenceMissing: "#C4283F", .syntaxMnemonicBranch: "#B3345E", .syntaxMnemonicArithmetic: "#2663B5",
            .syntaxMnemonicMemory: "#00725C", .syntaxMnemonicGeneral: "#6657AD", .syntaxRegister: "#8B5A00",
            .syntaxImmediate: "#006F77", .syntaxAddress: "#5E4FB8", .syntaxModifier: "#636372",
            .syntaxPunctuation: "#5C6476", .syntaxOperator: "#9A4D00", .syntaxComment: "#6B7385",
            .syntaxString: "#8A5A00", .syntaxKeyword: "#A0308A", .syntaxType: "#0E7C8C", .syntaxFunction: "#2F5FB3",
            .syntaxVariable: "#1B1E26", .syntaxNumber: "#127880", .debugBreakpoint: "#D0343F",
            .debugProgramCounter: "#8A6200", .debugPatched: "#A9480F", .listingAlternateRow: "#F7F8FA",
            .listingProgramCounterRow: "#ECE6D6", .listingPatchedRow: "#F0DED4", .graphEdgeSelected: "#088187",
            .graphLaneBackground: "#F5F6F8", .deckBackground: "#F6F8F9", .deckRowBackground: "#FBFCFC",
            .kindFunction: "#0064C3", .kindSymbol: "#7B57B9", .kindImport: "#A03F81", .kindSegment: "#5B6578",
            .kindSection: "#077783", .kindString: "#906F02", .kindType: "#067650", .kindImage: "#9F5102",
            .kindSecurity: "#577D03", .kindDebug: "#AE0326", .terminalBlack: "#1B1E26", .terminalRed: "#C4283F",
            .terminalGreen: "#1E7F46", .terminalYellow: "#935600", .terminalBlue: "#2966B8",
            .terminalMagenta: "#A0308A", .terminalCyan: "#0E7C8C", .terminalWhite: "#8A90A0",
            .terminalBrightBlack: "#646C7E", .terminalBrightRed: "#D0343F", .terminalBrightGreen: "#12856E",
            .terminalBrightYellow: "#8A6200", .terminalBrightBlue: "#5443C9", .terminalBrightMagenta: "#BD3D66",
            .terminalBrightCyan: "#127880", .terminalBrightWhite: "#C3C7D0"
        ],
        dark: [
            .bgWindow: "#111318", .bgSidebar: "#1C1F26", .bgCanvas: "#16181E", .bgGutter: "#14161B",
            .bgElevated: "#23262F", .bgInset: "#101216", .bgInsetRaised: "#2B2F3A", .menuHighlight: "#5B4BD6", .menuHighlightForeground: "#FFFFFF", .bgHover: "#252934", .bgSelected: "#2F2A57",
            .bgSelectedInactive: "#262633", .bgCurrentLine: "#1E2030", .fgPrimary: "#DDE3EC", .fgSecondary: "#A3ADBB",
            .fgTertiary: "#959FAF", .fgDisabled: "#525A68", .fgOnAccent: "#111318", .fgLink: "#A99BFF",
            .borderSubtle: "#262A33", .borderDefault: "#333748", .borderStrong: "#4A4F63", .borderFocus: "#8B7CF6",
            .accent: "#8B7CF6", .accentSubtle: "#262245", .accentSoft: "#B0A2FF", .statusSuccess: "#4CC38A",
            .statusWarning: "#F2B45A", .statusDanger: "#F0607A", .statusInfo: "#7DA8F5", .statusNeutral: "#A3ADBB",
            .statusSuccessBackground: "#1F332F", .statusWarningBackground: "#393128",
            .statusDangerBackground: "#39242D", .statusInfoBackground: "#262F40", .statusNeutralBackground: "#2B2E36",
            .evidenceProven: "#4CC38A", .evidenceInferred: "#F2B872", .evidenceUnknown: "#8E97A6",
            .evidenceMissing: "#F0607A", .syntaxMnemonicBranch: "#E885A3", .syntaxMnemonicArithmetic: "#7DA8F5",
            .syntaxMnemonicMemory: "#61C7AB", .syntaxMnemonicGeneral: "#BAA1F2", .syntaxRegister: "#E6B066",
            .syntaxImmediate: "#5EBAC4", .syntaxAddress: "#AB96FA", .syntaxModifier: "#999EB2",
            .syntaxPunctuation: "#969FAE", .syntaxOperator: "#FFB86B", .syntaxComment: "#808A9A",
            .syntaxString: "#E8C170", .syntaxKeyword: "#F28FD0", .syntaxType: "#6FD3E0", .syntaxFunction: "#8DB4F7",
            .syntaxVariable: "#DDE3EC", .syntaxNumber: "#5EBAC4", .debugBreakpoint: "#FF6B6B",
            .debugProgramCounter: "#FFD24A", .debugPatched: "#F59E5B", .listingAlternateRow: "#1B1E26",
            .listingProgramCounterRow: "#3B3625", .listingPatchedRow: "#3E3029", .graphEdgeSelected: "#4AE9F9",
            .graphLaneBackground: "#121419", .deckBackground: "#13151A", .deckRowBackground: "#1B1E24",
            .kindFunction: "#7AB4FE", .kindSymbol: "#C4A9FF", .kindImport: "#ED92CB", .kindSegment: "#9AA4B6",
            .kindSection: "#15CBDF", .kindString: "#E4BC53", .kindType: "#52C794", .kindImage: "#FC984C",
            .kindSecurity: "#A4C973", .kindDebug: "#FF7475", .terminalBlack: "#2A2E3A", .terminalRed: "#F0607A",
            .terminalGreen: "#4CC38A", .terminalYellow: "#F2B45A", .terminalBlue: "#7DA8F5",
            .terminalMagenta: "#F28FD0", .terminalCyan: "#6FD3E0", .terminalWhite: "#C3CBD8",
            .terminalBrightBlack: "#5A6274", .terminalBrightRed: "#FF8A9E", .terminalBrightGreen: "#7FE0AE",
            .terminalBrightYellow: "#FFD28A", .terminalBrightBlue: "#A8C6FF", .terminalBrightMagenta: "#FFB0E6",
            .terminalBrightCyan: "#9CEAF2", .terminalBrightWhite: "#F2F5FA"
        ],
        lightHighContrast: [
            .bgWindow: "#FFFFFF", .bgSidebar: "#FFFFFF", .bgCanvas: "#FFFFFF", .bgGutter: "#FFFFFF",
            .bgElevated: "#FFFFFF", .bgInset: "#F2F2F2", .bgHover: "#E6E6E6", .bgSelected: "#D6CCFF",
            .bgSelectedInactive: "#E0E0E0", .bgCurrentLine: "#EFEAFF", .fgPrimary: "#000000", .fgSecondary: "#1F1F1F",
            .fgTertiary: "#3D3D3D", .fgDisabled: "#6E6E6E", .fgOnAccent: "#FFFFFF", .fgLink: "#3A1FB8",
            .borderSubtle: "#8C8C8C", .borderDefault: "#4D4D4D", .borderStrong: "#000000", .borderFocus: "#3A1FB8",
            .accent: "#4A2FD0", .accentSubtle: "#E6E0FF", .accentSoft: "#7B66E8", .statusSuccess: "#0B6B2E",
            .statusWarning: "#7A4500", .statusDanger: "#B00020", .statusInfo: "#0A4DA8", .statusNeutral: "#1F1F1F",
            .statusSuccessBackground: "#D8E7DE", .statusWarningBackground: "#EAE1D6",
            .statusDangerBackground: "#F2D6DB", .statusInfoBackground: "#D8E3F1", .statusNeutralBackground: "#DBDBDB",
            .evidenceProven: "#0B6B2E", .evidenceInferred: "#7A4500", .evidenceUnknown: "#3D3D3D",
            .evidenceMissing: "#B00020", .syntaxMnemonicBranch: "#9E1045", .syntaxMnemonicArithmetic: "#0A4DA8",
            .syntaxMnemonicMemory: "#0B6B55", .syntaxMnemonicGeneral: "#4A2FD0", .syntaxRegister: "#7A4500",
            .syntaxImmediate: "#0B5F66", .syntaxAddress: "#4A2FD0", .syntaxModifier: "#3D3D3D",
            .syntaxPunctuation: "#00505A", .syntaxOperator: "#5B2BB0", .syntaxComment: "#4D4D4D",
            .syntaxString: "#6B4500", .syntaxKeyword: "#8A106E", .syntaxType: "#0A4DA8", .syntaxFunction: "#0A4DA8",
            .syntaxVariable: "#000000", .syntaxNumber: "#7A4500", .debugBreakpoint: "#B00020",
            .debugProgramCounter: "#7A5A00", .debugPatched: "#9A3A00", .listingAlternateRow: "#F6F6F6",
            .listingProgramCounterRow: "#EAE5D6", .listingPatchedRow: "#EDDCD1", .graphEdgeSelected: "#046A77",
            .graphLaneBackground: "#F7F7F7", .deckBackground: "#F8F8F8", .deckRowBackground: "#FCFCFC",
            .kindFunction: "#004B96", .kindSymbol: "#613C9C", .kindImport: "#822266", .kindSegment: "#3F4654",
            .kindSection: "#005B65", .kindString: "#715700", .kindType: "#00593B", .kindImage: "#7B3D01",
            .kindSecurity: "#426003", .kindDebug: "#83021A", .terminalBlack: "#000000", .terminalRed: "#B00020",
            .terminalGreen: "#0B6B2E", .terminalYellow: "#7A4500", .terminalBlue: "#0A4DA8",
            .terminalMagenta: "#8A106E", .terminalCyan: "#0B5F66", .terminalWhite: "#6E6E6E",
            .terminalBrightBlack: "#3D3D3D", .terminalBrightRed: "#9E1045", .terminalBrightGreen: "#0B6B55",
            .terminalBrightYellow: "#6B4500", .terminalBrightBlue: "#3A1FB8", .terminalBrightMagenta: "#4A2FD0",
            .terminalBrightCyan: "#00505A", .terminalBrightWhite: "#8C8C8C"
        ],
        darkHighContrast: [
            .bgWindow: "#000000", .bgSidebar: "#000000", .bgCanvas: "#000000", .bgGutter: "#000000",
            .bgElevated: "#121212", .bgInset: "#1A1A1A", .bgInsetRaised: "#222222", .menuHighlight: "#4A3BC8", .menuHighlightForeground: "#FFFFFF", .bgHover: "#262626", .bgSelected: "#3A2FA0",
            .bgSelectedInactive: "#2A2A2A", .bgCurrentLine: "#1A1A2E", .fgPrimary: "#FFFFFF", .fgSecondary: "#E6E6E6",
            .fgTertiary: "#C8C8C8", .fgDisabled: "#8A8A8A", .fgOnAccent: "#000000", .fgLink: "#C9BDFF",
            .borderSubtle: "#8A8A8A", .borderDefault: "#BDBDBD", .borderStrong: "#FFFFFF", .borderFocus: "#C9BDFF",
            .accent: "#B8A8FF", .accentSubtle: "#2A2250", .accentSoft: "#D6CCFF", .statusSuccess: "#7CFF9E",
            .statusWarning: "#FFD28A", .statusDanger: "#FF8A9E", .statusInfo: "#9CC4FF", .statusNeutral: "#E6E6E6",
            .statusSuccessBackground: "#142919", .statusWarningBackground: "#292216",
            .statusDangerBackground: "#291619", .statusInfoBackground: "#191F29", .statusNeutralBackground: "#252525",
            .evidenceProven: "#7CFF9E", .evidenceInferred: "#FFD28A", .evidenceUnknown: "#C8C8C8",
            .evidenceMissing: "#FF8A9E", .syntaxMnemonicBranch: "#FF9EBB", .syntaxMnemonicArithmetic: "#9CC4FF",
            .syntaxMnemonicMemory: "#7FF0D6", .syntaxMnemonicGeneral: "#DCC6FF", .syntaxRegister: "#FFD28A",
            .syntaxImmediate: "#8AF4FF", .syntaxAddress: "#DCC6FF", .syntaxModifier: "#C8C8C8",
            .syntaxPunctuation: "#7FF0D6", .syntaxOperator: "#DCC6FF", .syntaxComment: "#C8C8C8",
            .syntaxString: "#FFE08A", .syntaxKeyword: "#FFB0E6", .syntaxType: "#9CC4FF", .syntaxFunction: "#9CC4FF",
            .syntaxVariable: "#FFFFFF", .syntaxNumber: "#FFD28A", .debugBreakpoint: "#FF8A9E",
            .debugProgramCounter: "#FFE08A", .debugPatched: "#FFB27A", .listingAlternateRow: "#0D0D0D",
            .listingProgramCounterRow: "#292416", .listingPatchedRow: "#2E2016", .graphEdgeSelected: "#2CECF5",
            .graphLaneBackground: "#101010", .deckBackground: "#0D0D0D", .deckRowBackground: "#101010",
            .kindFunction: "#A8CEFF", .kindSymbol: "#D9CBFE", .kindImport: "#FEB2E1", .kindSegment: "#CFCFCF",
            .kindSection: "#5AE3F7", .kindString: "#FCD679", .kindType: "#78E0AF", .kindImage: "#FEBE92",
            .kindSecurity: "#BFE293", .kindDebug: "#FFA39F", .terminalBlack: "#3A3A3A", .terminalRed: "#FF8A9E",
            .terminalGreen: "#7CFF9E", .terminalYellow: "#FFD28A", .terminalBlue: "#9CC4FF",
            .terminalMagenta: "#FFB0E6", .terminalCyan: "#8AF4FF", .terminalWhite: "#E6E6E6",
            .terminalBrightBlack: "#8A8A8A", .terminalBrightRed: "#FFB3C1", .terminalBrightGreen: "#B0FFC4",
            .terminalBrightYellow: "#FFE6B8", .terminalBrightBlue: "#C4DCFF", .terminalBrightMagenta: "#FFD0F0",
            .terminalBrightCyan: "#C0F9FF", .terminalBrightWhite: "#FFFFFF"
        ]
    )

    static let midnight = LumenTheme(
        id: "com.macscope.theme.midnight",
        name: "Midnight",
        summary: "Deep navy with neon signals. Always dark.",
        colorSpace: .displayP3,
        light: nil,
        dark: [
            .bgWindow: "#060B1B", .bgSidebar: "#0A1128", .bgCanvas: "#080F24", .bgGutter: "#070D20",
            .bgElevated: "#121B38", .bgInset: "#050918", .bgInsetRaised: "#19244A", .menuHighlight: "#6A3FD0", .menuHighlightForeground: "#FFFFFF", .bgHover: "#16213F", .bgSelected: "#2B1A66",
            .bgSelectedInactive: "#1B1F45", .bgCurrentLine: "#1A0F45", .fgPrimary: "#F2F5FF", .fgSecondary: "#B2B8CC",
            .fgTertiary: "#8C94AD", .fgDisabled: "#4C5470", .fgOnAccent: "#060B1B", .fgLink: "#00F0FF",
            .borderSubtle: "#141D3A", .borderDefault: "#1C2748", .borderStrong: "#2E3B63", .borderFocus: "#FF3D6E",
            .accent: "#FF3D6E", .accentSubtle: "#3A1030", .accentSoft: "#FF8FAE", .statusSuccess: "#75FB4C",
            .statusWarning: "#FFD321", .statusDanger: "#FF5A36", .statusInfo: "#3AA2FF", .statusNeutral: "#B2B8CC",
            .statusSuccessBackground: "#19352A", .statusWarningBackground: "#302E24",
            .statusDangerBackground: "#33171B", .statusInfoBackground: "#102747", .statusNeutralBackground: "#232A3F",
            .evidenceProven: "#75FB4C", .evidenceInferred: "#FFD321", .evidenceUnknown: "#8A92AB",
            .evidenceMissing: "#FF3D6E", .syntaxMnemonicBranch: "#FF5C8A", .syntaxMnemonicArithmetic: "#3AA2FF",
            .syntaxMnemonicMemory: "#00F0FF", .syntaxMnemonicGeneral: "#C58BFF", .syntaxRegister: "#FFB45C",
            .syntaxImmediate: "#FFE45C", .syntaxAddress: "#C58BFF", .syntaxModifier: "#8C94AD",
            .syntaxPunctuation: "#8C94AD", .syntaxOperator: "#FFB45C", .syntaxComment: "#737DA0",
            .syntaxString: "#75FB4C", .syntaxKeyword: "#E532AD", .syntaxType: "#5CE1E6", .syntaxFunction: "#8AB4FF",
            .syntaxVariable: "#F2F5FF", .syntaxNumber: "#FFE45C", .debugBreakpoint: "#FF3D6E",
            .debugProgramCounter: "#FFD321", .debugPatched: "#F29C38", .listingAlternateRow: "#0D152D",
            .listingProgramCounterRow: "#302E24", .listingPatchedRow: "#322828", .graphEdgeSelected: "#14FDFD",
            .graphLaneBackground: "#060B1D", .deckBackground: "#060C1E", .deckRowBackground: "#0C142B",
            .kindFunction: "#86BAFE", .kindSymbol: "#C9B2FF", .kindImport: "#FF8ED7", .kindSegment: "#A2ABC6",
            .kindSection: "#12D2E7", .kindString: "#F5BF0D", .kindType: "#07D493", .kindImage: "#FFA15C",
            .kindSecurity: "#A3D45A", .kindDebug: "#FF8180", .terminalBlack: "#121B38", .terminalRed: "#FF3D6E",
            .terminalGreen: "#75FB4C", .terminalYellow: "#FFD321", .terminalBlue: "#3AA2FF",
            .terminalMagenta: "#E532AD", .terminalCyan: "#00F0FF", .terminalWhite: "#B2B8CC",
            .terminalBrightBlack: "#4C5470", .terminalBrightRed: "#FF5C8A", .terminalBrightGreen: "#A6FF8A",
            .terminalBrightYellow: "#FFE45C", .terminalBrightBlue: "#8AB4FF", .terminalBrightMagenta: "#FF6FD0",
            .terminalBrightCyan: "#5CE1E6", .terminalBrightWhite: "#F2F5FF"
        ]
    )

    static let contrast = LumenTheme(
        id: "com.macscope.theme.contrast",
        name: "Contrast",
        summary: "Maximum legibility: pure grounds and strong lines.",
        light: [
            .bgWindow: "#FFFFFF", .bgSidebar: "#FFFFFF", .bgCanvas: "#FFFFFF", .bgGutter: "#FFFFFF",
            .bgElevated: "#FFFFFF", .bgInset: "#F2F2F2", .bgHover: "#E6E6E6", .bgSelected: "#D6CCFF",
            .bgSelectedInactive: "#E0E0E0", .bgCurrentLine: "#EFEAFF", .fgPrimary: "#000000", .fgSecondary: "#1F1F1F",
            .fgTertiary: "#3D3D3D", .fgDisabled: "#6E6E6E", .fgOnAccent: "#FFFFFF", .fgLink: "#3A1FB8",
            .borderSubtle: "#8C8C8C", .borderDefault: "#4D4D4D", .borderStrong: "#000000", .borderFocus: "#3A1FB8",
            .accent: "#4A2FD0", .accentSubtle: "#E6E0FF", .accentSoft: "#7B66E8", .statusSuccess: "#0B6B2E",
            .statusWarning: "#7A4500", .statusDanger: "#B00020", .statusInfo: "#0A4DA8", .statusNeutral: "#1F1F1F",
            .statusSuccessBackground: "#D8E7DE", .statusWarningBackground: "#EAE1D6",
            .statusDangerBackground: "#F2D6DB", .statusInfoBackground: "#D8E3F1", .statusNeutralBackground: "#DBDBDB",
            .evidenceProven: "#0B6B2E", .evidenceInferred: "#7A4500", .evidenceUnknown: "#3D3D3D",
            .evidenceMissing: "#B00020", .syntaxMnemonicBranch: "#9E1045", .syntaxMnemonicArithmetic: "#0A4DA8",
            .syntaxMnemonicMemory: "#0B6B55", .syntaxMnemonicGeneral: "#4A2FD0", .syntaxRegister: "#7A4500",
            .syntaxImmediate: "#0B5F66", .syntaxAddress: "#4A2FD0", .syntaxModifier: "#3D3D3D",
            .syntaxPunctuation: "#00505A", .syntaxOperator: "#5B2BB0", .syntaxComment: "#4D4D4D",
            .syntaxString: "#6B4500", .syntaxKeyword: "#8A106E", .syntaxType: "#0A4DA8", .syntaxFunction: "#0A4DA8",
            .syntaxVariable: "#000000", .syntaxNumber: "#7A4500", .debugBreakpoint: "#B00020",
            .debugProgramCounter: "#7A5A00", .debugPatched: "#9A3A00", .listingAlternateRow: "#F6F6F6",
            .listingProgramCounterRow: "#EAE5D6", .listingPatchedRow: "#EDDCD1", .graphEdgeSelected: "#046A77",
            .graphLaneBackground: "#F7F7F7", .deckBackground: "#F8F8F8", .deckRowBackground: "#FCFCFC",
            .kindFunction: "#004B96", .kindSymbol: "#613C9C", .kindImport: "#822266", .kindSegment: "#3F4654",
            .kindSection: "#005B65", .kindString: "#715700", .kindType: "#00593B", .kindImage: "#7B3D01",
            .kindSecurity: "#426003", .kindDebug: "#83021A", .terminalBlack: "#000000", .terminalRed: "#B00020",
            .terminalGreen: "#0B6B2E", .terminalYellow: "#7A4500", .terminalBlue: "#0A4DA8",
            .terminalMagenta: "#8A106E", .terminalCyan: "#0B5F66", .terminalWhite: "#6E6E6E",
            .terminalBrightBlack: "#3D3D3D", .terminalBrightRed: "#9E1045", .terminalBrightGreen: "#0B6B55",
            .terminalBrightYellow: "#6B4500", .terminalBrightBlue: "#3A1FB8", .terminalBrightMagenta: "#4A2FD0",
            .terminalBrightCyan: "#00505A", .terminalBrightWhite: "#8C8C8C"
        ],
        dark: [
            .bgWindow: "#000000", .bgSidebar: "#000000", .bgCanvas: "#000000", .bgGutter: "#000000",
            .bgElevated: "#121212", .bgInset: "#1A1A1A", .bgInsetRaised: "#222222", .menuHighlight: "#4A3BC8", .menuHighlightForeground: "#FFFFFF", .bgHover: "#262626", .bgSelected: "#3A2FA0",
            .bgSelectedInactive: "#2A2A2A", .bgCurrentLine: "#1A1A2E", .fgPrimary: "#FFFFFF", .fgSecondary: "#E6E6E6",
            .fgTertiary: "#C8C8C8", .fgDisabled: "#8A8A8A", .fgOnAccent: "#000000", .fgLink: "#C9BDFF",
            .borderSubtle: "#8A8A8A", .borderDefault: "#BDBDBD", .borderStrong: "#FFFFFF", .borderFocus: "#C9BDFF",
            .accent: "#B8A8FF", .accentSubtle: "#2A2250", .accentSoft: "#D6CCFF", .statusSuccess: "#7CFF9E",
            .statusWarning: "#FFD28A", .statusDanger: "#FF8A9E", .statusInfo: "#9CC4FF", .statusNeutral: "#E6E6E6",
            .statusSuccessBackground: "#142919", .statusWarningBackground: "#292216",
            .statusDangerBackground: "#291619", .statusInfoBackground: "#191F29", .statusNeutralBackground: "#252525",
            .evidenceProven: "#7CFF9E", .evidenceInferred: "#FFD28A", .evidenceUnknown: "#C8C8C8",
            .evidenceMissing: "#FF8A9E", .syntaxMnemonicBranch: "#FF9EBB", .syntaxMnemonicArithmetic: "#9CC4FF",
            .syntaxMnemonicMemory: "#7FF0D6", .syntaxMnemonicGeneral: "#DCC6FF", .syntaxRegister: "#FFD28A",
            .syntaxImmediate: "#8AF4FF", .syntaxAddress: "#DCC6FF", .syntaxModifier: "#C8C8C8",
            .syntaxPunctuation: "#7FF0D6", .syntaxOperator: "#DCC6FF", .syntaxComment: "#C8C8C8",
            .syntaxString: "#FFE08A", .syntaxKeyword: "#FFB0E6", .syntaxType: "#9CC4FF", .syntaxFunction: "#9CC4FF",
            .syntaxVariable: "#FFFFFF", .syntaxNumber: "#FFD28A", .debugBreakpoint: "#FF8A9E",
            .debugProgramCounter: "#FFE08A", .debugPatched: "#FFB27A", .listingAlternateRow: "#0D0D0D",
            .listingProgramCounterRow: "#292416", .listingPatchedRow: "#2E2016", .graphEdgeSelected: "#2CECF5",
            .graphLaneBackground: "#101010", .deckBackground: "#0D0D0D", .deckRowBackground: "#101010",
            .kindFunction: "#A8CEFF", .kindSymbol: "#D9CBFE", .kindImport: "#FEB2E1", .kindSegment: "#CFCFCF",
            .kindSection: "#5AE3F7", .kindString: "#FCD679", .kindType: "#78E0AF", .kindImage: "#FEBE92",
            .kindSecurity: "#BFE293", .kindDebug: "#FFA39F", .terminalBlack: "#3A3A3A", .terminalRed: "#FF8A9E",
            .terminalGreen: "#7CFF9E", .terminalYellow: "#FFD28A", .terminalBlue: "#9CC4FF",
            .terminalMagenta: "#FFB0E6", .terminalCyan: "#8AF4FF", .terminalWhite: "#E6E6E6",
            .terminalBrightBlack: "#8A8A8A", .terminalBrightRed: "#FFB3C1", .terminalBrightGreen: "#B0FFC4",
            .terminalBrightYellow: "#FFE6B8", .terminalBrightBlue: "#C4DCFF", .terminalBrightMagenta: "#FFD0F0",
            .terminalBrightCyan: "#C0F9FF", .terminalBrightWhite: "#FFFFFF"
        ]
    )
}

public extension LumenPack {
    static let macScope: LumenPack = {
        let pseudocode: [LumenToken] = [.syntaxComment, .syntaxVariable, .syntaxKeyword, .syntaxNumber,
                                        .syntaxOperator, .syntaxPunctuation, .syntaxType]
        let kinds: [LumenToken] = [.kindFunction, .kindSymbol, .kindImport, .kindSegment, .kindSection,
                                   .kindString, .kindType, .kindImage, .kindSecurity, .kindDebug]
        let edgeKinds: [LumenToken] = [.graphEdgeBranch, .graphEdgeCall, .graphEdgeReference, .graphEdgeFallthrough]
        let specs: [LumenTokenSpec] = [
        LumenTokenSpec(.bgGutter, group: "Surfaces", surface: .editor),
        LumenTokenSpec(.bgCurrentLine, group: "Surfaces", surface: .editor),
        LumenTokenSpec(.evidenceProven, group: "Evidence", contrast: [.text(on: .bgCanvas), .text(on: .statusSuccessBackground)]),
        LumenTokenSpec(.evidenceInferred, group: "Evidence", contrast: [.text(on: .bgCanvas), .text(on: .statusWarningBackground)]),
        LumenTokenSpec(.evidenceUnknown, group: "Evidence", contrast: [.text(on: .bgCanvas), .text(on: .statusNeutralBackground)]),
        LumenTokenSpec(.evidenceMissing, group: "Evidence", contrast: [.text(on: .bgCanvas), .text(on: .statusDangerBackground)]),
        LumenTokenSpec(.syntaxMnemonicBranch, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxMnemonicArithmetic, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxMnemonicMemory, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxMnemonicGeneral, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxRegister, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxImmediate, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxAddress, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxModifier, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxPunctuation, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.syntaxOperator, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.syntaxComment, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.syntaxString, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.syntaxKeyword, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.syntaxType, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.syntaxFunction, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.syntaxVariable, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.syntaxNumber, group: "Syntax", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.debugBreakpoint, group: "Debugger", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.debugProgramCounter, group: "Debugger", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.debugPatched, group: "Debugger", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.listingSelection, group: "Listing", fallback: .token(.bgSelected), surface: .editor),
        LumenTokenSpec(.listingCurrentLine, group: "Listing", fallback: .token(.bgCurrentLine), surface: .editor),
        LumenTokenSpec(.listingAlternateRow, group: "Listing", fallback: .composite(.bgHover, alpha: 0.35, over: .bgCanvas), surface: .editor),
        LumenTokenSpec(.listingProgramCounterRow, group: "Listing", fallback: .composite(.debugProgramCounter, alpha: 0.16, over: .bgCanvas), surface: .editor),
        LumenTokenSpec(.listingPatchedRow, group: "Listing", fallback: .composite(.debugPatched, alpha: 0.18, over: .bgCanvas), surface: .editor),
        LumenTokenSpec(.listingSecondaryText, group: "Listing", fallback: .token(.fgTertiary), surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.statusbarBackground, group: "Window Chrome", fallback: .token(.bgGutter), surface: .editor),
        LumenTokenSpec(.welcomeAccent, group: "Window Chrome", fallback: .token(.accent), followsSystemAccent: true),
        LumenTokenSpec(.graphEdgeBranch, group: "Graph", fallback: .token(.statusWarning), surface: .editor, contrast: [.graphic(on: .bgCanvas)]),
        LumenTokenSpec(.graphEdgeCall, group: "Graph", fallback: .token(.accent), surface: .editor, contrast: [.graphic(on: .bgCanvas)], followsSystemAccent: true),
        LumenTokenSpec(.graphEdgeReference, group: "Graph", fallback: .token(.fgSecondary), surface: .editor, contrast: [.graphic(on: .bgCanvas)]),
        LumenTokenSpec(.graphEdgeFallthrough, group: "Graph", fallback: .token(.fgTertiary), surface: .editor, contrast: [.graphic(on: .bgCanvas)]),
        LumenTokenSpec(.graphEdgeSelected, group: "Graph", fallback: .token(.syntaxType), surface: .editor, contrast: [.graphic(on: .bgCanvas)]),
        LumenTokenSpec(.graphNodeBackground, group: "Graph", fallback: .token(.bgElevated), surface: .editor),
        LumenTokenSpec(.graphLaneBackground, group: "Graph", fallback: .token(.bgInset), surface: .editor),
        LumenTokenSpec(.deckBackground, group: "Debugger and Shell Decks", fallback: .token(.bgInset)),
        LumenTokenSpec(.deckRowBackground, group: "Debugger and Shell Decks", fallback: .token(.bgElevated)),
        LumenTokenSpec(.kindFunction, group: "Object Kinds", fallback: .token(.syntaxFunction), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindSymbol, group: "Object Kinds", fallback: .token(.syntaxAddress), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindImport, group: "Object Kinds", fallback: .token(.syntaxKeyword), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindSegment, group: "Object Kinds", fallback: .token(.syntaxMnemonicArithmetic), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindSection, group: "Object Kinds", fallback: .token(.syntaxType), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindString, group: "Object Kinds", fallback: .token(.syntaxString), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindType, group: "Object Kinds", fallback: .token(.syntaxMnemonicGeneral), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindImage, group: "Object Kinds", fallback: .token(.accent), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindSecurity, group: "Object Kinds", fallback: .token(.statusSuccess), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.kindDebug, group: "Object Kinds", fallback: .token(.debugBreakpoint), contrast: [.graphic(on: .sidebarBackground, severity: .warning)]),
        LumenTokenSpec(.terminalForeground, group: "Terminal", fallback: .token(.fgPrimary), surface: .editor),
        LumenTokenSpec(.terminalBackground, group: "Terminal", fallback: .token(.bgCanvas), surface: .editor),
        LumenTokenSpec(.terminalCursor, group: "Terminal", fallback: .token(.accent), surface: .editor, followsSystemAccent: true),
        LumenTokenSpec(.terminalBlack, group: "Terminal", fallback: .token(.bgInset), surface: .editor),
        LumenTokenSpec(.terminalRed, group: "Terminal", fallback: .token(.statusDanger), surface: .editor),
        LumenTokenSpec(.terminalGreen, group: "Terminal", fallback: .token(.statusSuccess), surface: .editor),
        LumenTokenSpec(.terminalYellow, group: "Terminal", fallback: .token(.statusWarning), surface: .editor),
        LumenTokenSpec(.terminalBlue, group: "Terminal", fallback: .token(.statusInfo), surface: .editor),
        LumenTokenSpec(.terminalMagenta, group: "Terminal", fallback: .token(.syntaxKeyword), surface: .editor),
        LumenTokenSpec(.terminalCyan, group: "Terminal", fallback: .token(.syntaxType), surface: .editor),
        LumenTokenSpec(.terminalWhite, group: "Terminal", fallback: .token(.fgSecondary), surface: .editor),
        LumenTokenSpec(.terminalBrightBlack, group: "Terminal", fallback: .token(.fgTertiary), surface: .editor),
        LumenTokenSpec(.terminalBrightRed, group: "Terminal", fallback: .token(.statusDanger), surface: .editor),
        LumenTokenSpec(.terminalBrightGreen, group: "Terminal", fallback: .token(.statusSuccess), surface: .editor),
        LumenTokenSpec(.terminalBrightYellow, group: "Terminal", fallback: .token(.statusWarning), surface: .editor),
        LumenTokenSpec(.terminalBrightBlue, group: "Terminal", fallback: .token(.statusInfo), surface: .editor),
        LumenTokenSpec(.terminalBrightMagenta, group: "Terminal", fallback: .token(.syntaxKeyword), surface: .editor),
        LumenTokenSpec(.terminalBrightCyan, group: "Terminal", fallback: .token(.syntaxType), surface: .editor),
        LumenTokenSpec(.terminalBrightWhite, group: "Terminal", fallback: .token(.fgPrimary), surface: .editor),
        ]
        return LumenPack(
            id: "com.macscope",
            tokens: specs,
            surfaces: [.editor],
            themes: [MacScopeThemes.scope, MacScopeThemes.midnight, MacScopeThemes.contrast]
                .map(MacScopeThemes.withLumenHues).map(MacScopeThemes.withLumenTitlebar),
            rules: [
                LumenDistinctRule(pseudocode, minimumDistance: 0.000_001, severity: .error, noun: "pseudocode roles"),
                LumenDistinctRule(kinds, minimumDistance: 0.06, noun: "kinds"),
                // Core text and focus on MacScope's own grounds.
                LumenContrastPairsRule([.fgTertiary], on: [.listingAlternateRow, .listingCurrentLine, .listingProgramCounterRow, .listingPatchedRow]),
                LumenContrastPairsRule([.fgSecondary, .fgTertiary, .statusWarning, .statusSuccess], on: [.deckBackground, .deckRowBackground]),
                LumenContrastPairsRule([.fgPrimary, .fgSecondary], on: [.graphLaneBackground]),
                LumenContrastPairsRule([.borderFocus, .accent], on: [.sidebarBackground], minimum: 3),
                // The warning banner's body and the current-block entry chips (MacScope v5).
                LumenContrastPairsRule([.fgSecondary], on: [.statusWarningBackground, .bgElevated]),
                LumenCustomRule("kind badge tiles") { theme, appearance, registry in
                    // DSKindBadge draws the glyph on its own 16% tint over the navigator.
                    kinds.flatMap { kind -> [LumenIssue] in
                        let color = theme.color(kind, for: appearance, in: registry)
                        return [LumenToken.sidebarBackground, .sidebarRowSelected].compactMap { ground in
                            let tile = color.composited(alpha: 0.16, over: theme.color(ground, for: appearance, in: registry))
                            let ratio = color.contrastRatio(against: tile)
                            return ratio < 3 ? LumenIssue(.warning, appearance, token: kind,
                                "\(kind.rawValue) badge glyph is \(String(format: "%.2f", ratio)):1 on its tile over \(ground.rawValue); needs 3:1") : nil
                        }
                    }
                },
                LumenCustomRule("selected graph edge") { theme, appearance, registry in
                    let selected = theme.color(.graphEdgeSelected, for: appearance, in: registry)
                    return edgeKinds.filter { selected.perceptualDistance(to: theme.color($0, for: appearance, in: registry)) < 0.09 }
                        .map { LumenIssue(.warning, appearance, token: .graphEdgeSelected,
                                          "graph.edge.selected is too close to \($0.rawValue) to show the selection") }
                },
            ],
            // Every core theme, including ones Lumen adds later: MacScope's gallery offers only its own.
            hidesThemes: LumenPack.core.themes.map(\.id),
            surfaceOverrides: [.bgCanvas: .editor]
        )
    }()
}

public extension LumenRegistry {
    /// MacScope's complete vocabulary: Lumen's core plus the MacScope pack.
    static let macScope = LumenRegistry(packs: [.core, .macScope], defaultThemeID: MacScopeThemes.scopeID)
}
