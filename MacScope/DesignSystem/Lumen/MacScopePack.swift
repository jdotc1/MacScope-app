// The MacScope pack: MacScope's domain roles, its three themes (under their existing ids) and its
// rules, on top of Lumen's core and code packs. Since U5e the themes inherit Lumen's and carry only
// MacScope's own roles.

import Foundation
import LumenUI
import LumenTokens

public extension LumenSurface {
    /// MacScope's code canvas: listing, gutter, graph, pseudocode, terminal.
    static let editor = LumenSurface("editor")
}

public extension LumenToken {
    static let bgGutter: LumenToken = "bg.gutter"
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

/// MacScope's themes inherit Lumen's (Scope ← Lumen, Midnight ← Midnight, Contrast ← Contrast) for
/// core roles and hues. MacScope retains its warm red active title-bar tint.
public enum MacScopeThemes {
    public static let scopeID = "com.macscope.theme.scope"
    public static let midnightID = "com.macscope.theme.midnight"
    public static let contrastID = "com.macscope.theme.contrast"

    /// Keep the approved warm menu-bar wash independent of individual icon backlights.
    /// Contrast themes retain their flat inherited chrome.
    static func withWarmTitlebar(_ theme: LumenTheme) -> LumenTheme {
        guard theme.id != contrastID else { return theme }
        var theme = theme
        theme.light = theme.light.map {
            $0.merging([.titlebarActiveTop: "#F3E5E8", .titlebarActiveBottom: "#F3F2F8"])
        }
        let dark: LumenPalette = theme.id == midnightID
            ? [.titlebarActiveTop: "#391724", .titlebarActiveBottom: "#0E1331"]
            : [.titlebarActiveTop: "#3A202B", .titlebarActiveBottom: "#201E2E"]
        theme.dark = theme.dark.map { $0.merging(dark) }
        theme.lightHighContrast = theme.lightHighContrast.map {
            $0.merging([.titlebarActiveTop: "#FFFFFF", .titlebarActiveBottom: "#FFFFFF"])
        }
        theme.darkHighContrast = theme.darkHighContrast.map {
            $0.merging([.titlebarActiveTop: "#000000", .titlebarActiveBottom: "#000000"])
        }
        return theme
    }

    static let scope = LumenTheme(
        id: "com.macscope.theme.scope",
        name: "Scope",
        summary: "Cool slate with a violet accent. Follows Light and Dark.",
        inherits: LumenThemes.standardID,
        light: [
            .bgGutter: "#F7F8FA", LumenToken.Code.currentLine: "#F4F2FF", .evidenceProven: "#1E7F46", .evidenceInferred: "#935600",
            .evidenceUnknown: "#4A5162", .evidenceMissing: "#C4283F", .syntaxMnemonicBranch: "#B3345E",
            .syntaxMnemonicArithmetic: "#2663B5", .syntaxMnemonicMemory: "#00725C", .syntaxMnemonicGeneral: "#6657AD",
            .syntaxRegister: "#8B5A00", .syntaxImmediate: "#006F77", .syntaxAddress: "#5E4FB8",
            .syntaxModifier: "#636372", .syntaxPunctuation: "#5C6476", .syntaxOperator: "#9A4D00",
            .syntaxComment: "#6B7385", .syntaxString: "#8A5A00", .syntaxKeyword: "#A0308A", .syntaxType: "#0E7C8C",
            .syntaxFunction: "#2F5FB3", .syntaxVariable: "#1B1E26", .syntaxNumber: "#127880",
            .debugBreakpoint: "#D0343F", .debugProgramCounter: "#8A6200", .debugPatched: "#A9480F",
            .listingAlternateRow: "#F7F8FA", .listingProgramCounterRow: "#ECE6D6", .listingPatchedRow: "#F0DED4",
            .graphLaneBackground: "#F5F6F8", .deckBackground: "#F6F8F9",
            .deckRowBackground: "#FBFCFC", .kindFunction: "#0064C3", .kindSymbol: "#7B57B9", .kindImport: "#A03F81",
            .kindSegment: "#5B6578", .kindSection: "#077783", .kindString: "#906F02", .kindType: "#067650",
            .kindImage: "#9F5102", .kindSecurity: "#577D03", .kindDebug: "#AE0326", .terminalBlack: "#1B1E26",
            .terminalRed: "#C4283F", .terminalGreen: "#1E7F46", .terminalYellow: "#935600", .terminalBlue: "#2966B8",
            .terminalMagenta: "#A0308A", .terminalCyan: "#0E7C8C", .terminalWhite: "#8A90A0",
            .terminalBrightBlack: "#646C7E", .terminalBrightRed: "#D0343F", .terminalBrightGreen: "#12856E",
            .terminalBrightYellow: "#8A6200", .terminalBrightBlue: "#5443C9", .terminalBrightMagenta: "#BD3D66",
            .terminalBrightCyan: "#127880", .terminalBrightWhite: "#C3C7D0",
        ],
        dark: [
            .bgGutter: "#14161B", LumenToken.Code.currentLine: "#1E2030", .evidenceProven: "#4CC38A", .evidenceInferred: "#F2B872",
            .evidenceUnknown: "#A3ADBB", .evidenceMissing: "#F0607A", .syntaxMnemonicBranch: "#E885A3",
            .syntaxMnemonicArithmetic: "#7DA8F5", .syntaxMnemonicMemory: "#61C7AB", .syntaxMnemonicGeneral: "#BAA1F2",
            .syntaxRegister: "#E6B066", .syntaxImmediate: "#5EBAC4", .syntaxAddress: "#AB96FA",
            .syntaxModifier: "#999EB2", .syntaxPunctuation: "#969FAE", .syntaxOperator: "#FFB86B",
            .syntaxComment: "#808A9A", .syntaxString: "#E8C170", .syntaxKeyword: "#F28FD0", .syntaxType: "#6FD3E0",
            .syntaxFunction: "#8DB4F7", .syntaxVariable: "#DDE3EC", .syntaxNumber: "#5EBAC4",
            .debugBreakpoint: "#FF6B6B", .debugProgramCounter: "#FFD24A", .debugPatched: "#F59E5B",
            .listingAlternateRow: "#1B1E26", .listingProgramCounterRow: "#3B3625", .listingPatchedRow: "#3E3029",
            .graphLaneBackground: "#121419", .deckBackground: "#13151A",
            .deckRowBackground: "#1B1E24", .kindFunction: "#7AB4FE", .kindSymbol: "#C4A9FF", .kindImport: "#ED92CB",
            .kindSegment: "#9AA4B6", .kindSection: "#15CBDF", .kindString: "#E4BC53", .kindType: "#52C794",
            .kindImage: "#FC984C", .kindSecurity: "#A4C973", .kindDebug: "#FF7475", .terminalBlack: "#2A2E3A",
            .terminalRed: "#F0607A", .terminalGreen: "#4CC38A", .terminalYellow: "#F2B45A", .terminalBlue: "#7DA8F5",
            .terminalMagenta: "#F28FD0", .terminalCyan: "#6FD3E0", .terminalWhite: "#C3CBD8",
            .terminalBrightBlack: "#5A6274", .terminalBrightRed: "#FF8A9E", .terminalBrightGreen: "#7FE0AE",
            .terminalBrightYellow: "#FFD28A", .terminalBrightBlue: "#A8C6FF", .terminalBrightMagenta: "#FFB0E6",
            .terminalBrightCyan: "#9CEAF2", .terminalBrightWhite: "#F2F5FA",
        ],
        lightHighContrast: [
            .bgGutter: "#FFFFFF", LumenToken.Code.currentLine: "#EFEAFF", .evidenceProven: "#0B6B2E", .evidenceInferred: "#7A4500",
            .evidenceUnknown: "#3D3D3D", .evidenceMissing: "#B00020", .syntaxMnemonicBranch: "#9E1045",
            .syntaxMnemonicArithmetic: "#0A4DA8", .syntaxMnemonicMemory: "#0B6B55", .syntaxMnemonicGeneral: "#4A2FD0",
            .syntaxRegister: "#7A4500", .syntaxImmediate: "#0B5F66", .syntaxAddress: "#4A2FD0",
            .syntaxModifier: "#3D3D3D", .syntaxPunctuation: "#00505A", .syntaxOperator: "#5B2BB0",
            .syntaxComment: "#4D4D4D", .syntaxString: "#6B4500", .syntaxKeyword: "#8A106E", .syntaxType: "#0A4DA8",
            .syntaxFunction: "#0A4DA8", .syntaxVariable: "#000000", .syntaxNumber: "#7A4500",
            .debugBreakpoint: "#B00020", .debugProgramCounter: "#7A5A00", .debugPatched: "#9A3A00",
            .listingAlternateRow: "#F6F6F6", .listingProgramCounterRow: "#EAE5D6", .listingPatchedRow: "#EDDCD1",
            .graphLaneBackground: "#F7F7F7", .deckBackground: "#F8F8F8",
            .deckRowBackground: "#FCFCFC", .kindFunction: "#004B96", .kindSymbol: "#613C9C", .kindImport: "#822266",
            .kindSegment: "#3F4654", .kindSection: "#005B65", .kindString: "#715700", .kindType: "#00593B",
            .kindImage: "#7B3D01", .kindSecurity: "#426003", .kindDebug: "#83021A", .terminalBlack: "#000000",
            .terminalRed: "#B00020", .terminalGreen: "#0B6B2E", .terminalYellow: "#7A4500", .terminalBlue: "#0A4DA8",
            .terminalMagenta: "#8A106E", .terminalCyan: "#0B5F66", .terminalWhite: "#6E6E6E",
            .terminalBrightBlack: "#3D3D3D", .terminalBrightRed: "#9E1045", .terminalBrightGreen: "#0B6B55",
            .terminalBrightYellow: "#6B4500", .terminalBrightBlue: "#3A1FB8", .terminalBrightMagenta: "#4A2FD0",
            .terminalBrightCyan: "#00505A", .terminalBrightWhite: "#8C8C8C",
        ],
        darkHighContrast: [
            .bgGutter: "#000000", LumenToken.Code.currentLine: "#1A1A2E", .evidenceProven: "#7CFF9E", .evidenceInferred: "#FFD28A",
            .evidenceUnknown: "#C8C8C8", .evidenceMissing: "#FF8A9E", .syntaxMnemonicBranch: "#FF9EBB",
            .syntaxMnemonicArithmetic: "#9CC4FF", .syntaxMnemonicMemory: "#7FF0D6", .syntaxMnemonicGeneral: "#DCC6FF",
            .syntaxRegister: "#FFD28A", .syntaxImmediate: "#8AF4FF", .syntaxAddress: "#DCC6FF",
            .syntaxModifier: "#C8C8C8", .syntaxPunctuation: "#7FF0D6", .syntaxOperator: "#DCC6FF",
            .syntaxComment: "#C8C8C8", .syntaxString: "#FFE08A", .syntaxKeyword: "#FFB0E6", .syntaxType: "#9CC4FF",
            .syntaxFunction: "#9CC4FF", .syntaxVariable: "#FFFFFF", .syntaxNumber: "#FFD28A",
            .debugBreakpoint: "#FF8A9E", .debugProgramCounter: "#FFE08A", .debugPatched: "#FFB27A",
            .listingAlternateRow: "#0D0D0D", .listingProgramCounterRow: "#292416", .listingPatchedRow: "#2E2016",
            .graphLaneBackground: "#101010", .deckBackground: "#0D0D0D",
            .deckRowBackground: "#101010", .kindFunction: "#A8CEFF", .kindSymbol: "#D9CBFE", .kindImport: "#FEB2E1",
            .kindSegment: "#CFCFCF", .kindSection: "#5AE3F7", .kindString: "#FCD679", .kindType: "#78E0AF",
            .kindImage: "#FEBE92", .kindSecurity: "#BFE293", .kindDebug: "#FFA39F", .terminalBlack: "#3A3A3A",
            .terminalRed: "#FF8A9E", .terminalGreen: "#7CFF9E", .terminalYellow: "#FFD28A", .terminalBlue: "#9CC4FF",
            .terminalMagenta: "#FFB0E6", .terminalCyan: "#8AF4FF", .terminalWhite: "#E6E6E6",
            .terminalBrightBlack: "#8A8A8A", .terminalBrightRed: "#FFB3C1", .terminalBrightGreen: "#B0FFC4",
            .terminalBrightYellow: "#FFE6B8", .terminalBrightBlue: "#C4DCFF", .terminalBrightMagenta: "#FFD0F0",
            .terminalBrightCyan: "#C0F9FF", .terminalBrightWhite: "#FFFFFF",
        ]
    )

    static let midnight = LumenTheme(
        id: "com.macscope.theme.midnight",
        name: "Midnight",
        summary: "Deep navy with neon signals. Always dark.",
        colorSpace: .displayP3,
        inherits: LumenThemes.midnightID,
        light: nil,
        dark: [
            .bgGutter: "#070D20", LumenToken.Code.currentLine: "#1A0F45", .evidenceProven: "#75FB4C", .evidenceInferred: "#FFD321",
            .evidenceUnknown: "#8A92AB", .evidenceMissing: "#FF3D6E", .syntaxMnemonicBranch: "#FF5C8A",
            .syntaxMnemonicArithmetic: "#3AA2FF", .syntaxMnemonicMemory: "#00F0FF", .syntaxMnemonicGeneral: "#C58BFF",
            .syntaxRegister: "#FFB45C", .syntaxImmediate: "#FFE45C", .syntaxAddress: "#C58BFF",
            .syntaxModifier: "#8C94AD", .syntaxPunctuation: "#8C94AD", .syntaxOperator: "#FFB45C",
            .syntaxComment: "#737DA0", .syntaxString: "#75FB4C", .syntaxKeyword: "#E532AD", .syntaxType: "#5CE1E6",
            .syntaxFunction: "#8AB4FF", .syntaxVariable: "#F2F5FF", .syntaxNumber: "#FFE45C",
            .debugBreakpoint: "#FF3D6E", .debugProgramCounter: "#FFD321", .debugPatched: "#F29C38",
            .listingAlternateRow: "#0D152D", .listingProgramCounterRow: "#302E24", .listingPatchedRow: "#322828",
            .graphLaneBackground: "#060B1D", .deckBackground: "#060C1E",
            .deckRowBackground: "#0C142B", .kindFunction: "#86BAFE", .kindSymbol: "#C9B2FF", .kindImport: "#FF8ED7",
            .kindSegment: "#A2ABC6", .kindSection: "#12D2E7", .kindString: "#F5BF0D", .kindType: "#07D493",
            .kindImage: "#FFA15C", .kindSecurity: "#A3D45A", .kindDebug: "#FF8180", .terminalBlack: "#121B38",
            .terminalRed: "#FF3D6E", .terminalGreen: "#75FB4C", .terminalYellow: "#FFD321", .terminalBlue: "#3AA2FF",
            .terminalMagenta: "#E532AD", .terminalCyan: "#00F0FF", .terminalWhite: "#B2B8CC",
            .terminalBrightBlack: "#4C5470", .terminalBrightRed: "#FF5C8A", .terminalBrightGreen: "#A6FF8A",
            .terminalBrightYellow: "#FFE45C", .terminalBrightBlue: "#8AB4FF", .terminalBrightMagenta: "#FF6FD0",
            .terminalBrightCyan: "#5CE1E6", .terminalBrightWhite: "#F2F5FF",
        ]
    )

    static let contrast = LumenTheme(
        id: "com.macscope.theme.contrast",
        name: "Contrast",
        summary: "Maximum legibility: pure grounds and strong lines.",
        inherits: LumenThemes.contrastID,
        light: [
            .bgGutter: "#FFFFFF", LumenToken.Code.currentLine: "#EFEAFF", .evidenceProven: "#0B6B2E", .evidenceInferred: "#7A4500",
            .evidenceUnknown: "#3D3D3D", .evidenceMissing: "#B00020", .syntaxMnemonicBranch: "#9E1045",
            .syntaxMnemonicArithmetic: "#0A4DA8", .syntaxMnemonicMemory: "#0B6B55", .syntaxMnemonicGeneral: "#4A2FD0",
            .syntaxRegister: "#7A4500", .syntaxImmediate: "#0B5F66", .syntaxAddress: "#4A2FD0",
            .syntaxModifier: "#3D3D3D", .syntaxPunctuation: "#00505A", .syntaxOperator: "#5B2BB0",
            .syntaxComment: "#4D4D4D", .syntaxString: "#6B4500", .syntaxKeyword: "#8A106E", .syntaxType: "#0A4DA8",
            .syntaxFunction: "#0A4DA8", .syntaxVariable: "#000000", .syntaxNumber: "#7A4500",
            .debugBreakpoint: "#B00020", .debugProgramCounter: "#7A5A00", .debugPatched: "#9A3A00",
            .listingAlternateRow: "#F6F6F6", .listingProgramCounterRow: "#EAE5D6", .listingPatchedRow: "#EDDCD1",
            .graphLaneBackground: "#F7F7F7", .deckBackground: "#F8F8F8",
            .deckRowBackground: "#FCFCFC", .kindFunction: "#004B96", .kindSymbol: "#613C9C", .kindImport: "#822266",
            .kindSegment: "#3F4654", .kindSection: "#005B65", .kindString: "#715700", .kindType: "#00593B",
            .kindImage: "#7B3D01", .kindSecurity: "#426003", .kindDebug: "#83021A", .terminalBlack: "#000000",
            .terminalRed: "#B00020", .terminalGreen: "#0B6B2E", .terminalYellow: "#7A4500", .terminalBlue: "#0A4DA8",
            .terminalMagenta: "#8A106E", .terminalCyan: "#0B5F66", .terminalWhite: "#6E6E6E",
            .terminalBrightBlack: "#3D3D3D", .terminalBrightRed: "#9E1045", .terminalBrightGreen: "#0B6B55",
            .terminalBrightYellow: "#6B4500", .terminalBrightBlue: "#3A1FB8", .terminalBrightMagenta: "#4A2FD0",
            .terminalBrightCyan: "#00505A", .terminalBrightWhite: "#8C8C8C",
        ],
        dark: [
            .bgGutter: "#000000", LumenToken.Code.currentLine: "#1A1A2E", .evidenceProven: "#7CFF9E", .evidenceInferred: "#FFD28A",
            .evidenceUnknown: "#C8C8C8", .evidenceMissing: "#FF8A9E", .syntaxMnemonicBranch: "#FF9EBB",
            .syntaxMnemonicArithmetic: "#9CC4FF", .syntaxMnemonicMemory: "#7FF0D6", .syntaxMnemonicGeneral: "#DCC6FF",
            .syntaxRegister: "#FFD28A", .syntaxImmediate: "#8AF4FF", .syntaxAddress: "#DCC6FF",
            .syntaxModifier: "#C8C8C8", .syntaxPunctuation: "#7FF0D6", .syntaxOperator: "#DCC6FF",
            .syntaxComment: "#C8C8C8", .syntaxString: "#FFE08A", .syntaxKeyword: "#FFB0E6", .syntaxType: "#9CC4FF",
            .syntaxFunction: "#9CC4FF", .syntaxVariable: "#FFFFFF", .syntaxNumber: "#FFD28A",
            .debugBreakpoint: "#FF8A9E", .debugProgramCounter: "#FFE08A", .debugPatched: "#FFB27A",
            .listingAlternateRow: "#0D0D0D", .listingProgramCounterRow: "#292416", .listingPatchedRow: "#2E2016",
            .graphLaneBackground: "#101010", .deckBackground: "#0D0D0D",
            .deckRowBackground: "#101010", .kindFunction: "#A8CEFF", .kindSymbol: "#D9CBFE", .kindImport: "#FEB2E1",
            .kindSegment: "#CFCFCF", .kindSection: "#5AE3F7", .kindString: "#FCD679", .kindType: "#78E0AF",
            .kindImage: "#FEBE92", .kindSecurity: "#BFE293", .kindDebug: "#FFA39F", .terminalBlack: "#3A3A3A",
            .terminalRed: "#FF8A9E", .terminalGreen: "#7CFF9E", .terminalYellow: "#FFD28A", .terminalBlue: "#9CC4FF",
            .terminalMagenta: "#FFB0E6", .terminalCyan: "#8AF4FF", .terminalWhite: "#E6E6E6",
            .terminalBrightBlack: "#8A8A8A", .terminalBrightRed: "#FFB3C1", .terminalBrightGreen: "#B0FFC4",
            .terminalBrightYellow: "#FFE6B8", .terminalBrightBlue: "#C4DCFF", .terminalBrightMagenta: "#FFD0F0",
            .terminalBrightCyan: "#C0F9FF", .terminalBrightWhite: "#FFFFFF",
        ]
    )
}

public extension LumenPack {
    static let macScope: LumenPack = {
        let pseudocode: [LumenToken] = [.syntaxComment, .syntaxVariable, .syntaxKeyword, .syntaxNumber,
                                        .syntaxOperator, .syntaxPunctuation, .syntaxType]
        let kinds: [LumenToken] = [.kindFunction, .kindSymbol, .kindImport, .kindSegment, .kindSection,
                                   .kindString, .kindType, .kindImage, .kindSecurity, .kindDebug]
        let specs: [LumenTokenSpec] = [
        LumenTokenSpec(.bgGutter, group: "Surfaces", surface: .editor),
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
        LumenTokenSpec(.debugBreakpoint, group: "Debugger", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.debugProgramCounter, group: "Debugger", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.debugPatched, group: "Debugger", surface: .editor, contrast: [.text(on: .bgCanvas)]),
        LumenTokenSpec(.listingSelection, group: "Listing", fallback: .token(.bgSelected), surface: .editor),
        LumenTokenSpec(.listingCurrentLine, group: "Listing", fallback: .token(LumenToken.Code.currentLine), surface: .editor),
        LumenTokenSpec(.listingAlternateRow, group: "Listing", fallback: .composite(.bgHover, alpha: 0.35, over: .bgCanvas), surface: .editor),
        LumenTokenSpec(.listingProgramCounterRow, group: "Listing", fallback: .composite(.debugProgramCounter, alpha: 0.16, over: .bgCanvas), surface: .editor),
        LumenTokenSpec(.listingPatchedRow, group: "Listing", fallback: .composite(.debugPatched, alpha: 0.18, over: .bgCanvas), surface: .editor),
        LumenTokenSpec(.listingSecondaryText, group: "Listing", fallback: .token(.fgTertiary), surface: .editor, contrast: [.text(on: .bgCanvas), .text(on: .listingAlternateRow), .text(on: .listingCurrentLine), .text(on: .listingProgramCounterRow), .text(on: .listingPatchedRow)]),
        LumenTokenSpec(.statusbarBackground, group: "Window Chrome", fallback: .token(.bgGutter), surface: .editor),
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
        var pack = LumenPack(
            id: "com.macscope",
            tokens: specs,
            surfaces: [.editor],
            themes: [MacScopeThemes.scope, MacScopeThemes.midnight, MacScopeThemes.contrast]
                .map(MacScopeThemes.withWarmTitlebar),
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
            ],
            hidesThemes: LumenPack.core.themes.map(\.id),
            surfaceOverrides: [.bgCanvas: .editor],
            // Theme files written before U5e keep loading.
            renamedKeys: ["bg.currentLine": LumenToken.Code.currentLine]
        )
        // Retired in U5e without a successor (edges draw with LumenGraphEdgeKind's status tokens):
        // files that still carry these load without a warning and the values are ignored.
        pack.retiredKeys = ["graph.edge.branch", "graph.edge.call", "graph.edge.reference",
                            "graph.edge.fallthrough", "graph.edge.selected", "welcome.accent"]
        return pack
    }()
}

public extension LumenPack {
    /// Lumen's code pack as MacScope registers it. The nine shared `syntax.*` roles (keyword …
    /// punctuation) come from the code pack; MacScope's themes keep their values. MacScope keeps the
    /// checks it had for those roles (WCAG text on the canvas, punctuation also on every listing row
    /// ground, the pseudocode distinct rule in `.macScope`) instead of the code pack's current-line
    /// contrast and kinds-of-code distinctness, which its Scope and Contrast values were never
    /// designed against. Every code-pack role draws on MacScope's editor surface.
    static let codeForMacScope: LumenPack = {
        var pack = LumenPack.code
        let listingGrounds: [LumenToken] = [.listingAlternateRow, .listingCurrentLine, .listingProgramCounterRow, .listingPatchedRow]
        pack.tokens = pack.tokens.map { spec in
            var spec = spec
            spec.surface = .editor
            if spec.token.rawValue.hasPrefix("syntax.") {
                spec.group = "Syntax"
                spec.fallback = nil
                spec.contrast = [.text(on: .bgCanvas)]
                    + (spec.token == .syntaxPunctuation ? listingGrounds.map { .text(on: $0) } : [])
            }
            return spec
        }
        pack.rules = []
        return pack
    }()
}

public extension LumenRegistry {
    /// MacScope's complete vocabulary: Lumen's core plus the MacScope pack.
    static let macScope = LumenRegistry(packs: [.core, .codeForMacScope, .macScope], defaultThemeID: MacScopeThemes.scopeID)
}
