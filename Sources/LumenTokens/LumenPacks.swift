import Foundation

// Optional packs for kinds of content more than one app draws: code, and charts. An app adds the ones
// it needs (`LumenRegistry(packs: [.core, .code, .chart, .myApp])`) and supplies values for its own
// themes; Lumen's built-in themes already have them, checked by the validator like every other role.
//
// The syntax keys match the names apps already use (MacScope's pack has the same `syntax.*` keys), so
// an app moving onto this pack drops its own copies and users' theme files keep working.

public extension LumenToken {
    /// The code pack's roles. Namespaced, so an app's own `LumenToken` extensions (MacScope declares
    /// `syntaxKeyword` for the same key) never collide with Lumen's names.
    enum Code {
        public static let keyword: LumenToken = "syntax.keyword"
        public static let type: LumenToken = "syntax.type"
        public static let function: LumenToken = "syntax.function"
        public static let variable: LumenToken = "syntax.variable"
        public static let string: LumenToken = "syntax.string"
        public static let number: LumenToken = "syntax.number"
        public static let comment: LumenToken = "syntax.comment"
        public static let `operator`: LumenToken = "syntax.operator"
        public static let punctuation: LumenToken = "syntax.punctuation"

        public static let currentLine: LumenToken = "code.currentLine"
        /// The program counter's bar and arrow in listings and gutters.
        public static let programCounter: LumenToken = "code.programCounter"
        public static let selection: LumenToken = "code.selection"
        public static let lineNumber: LumenToken = "code.lineNumber"

        public static let addedBackground: LumenToken = "diff.addedBackground"
        public static let removedBackground: LumenToken = "diff.removedBackground"
        public static let changedBackground: LumenToken = "diff.changedBackground"
        public static let addedForeground: LumenToken = "diff.addedForeground"
        public static let removedForeground: LumenToken = "diff.removedForeground"
    }

    /// The chart pack's roles.
    enum Chart {
        /// Series, in the order a chart assigns them.
        public static let series: [LumenToken] = (1...8).map { LumenToken("chart.series\($0)") }
        public static let grid: LumenToken = "chart.grid"
        public static let axis: LumenToken = "chart.axis"
        public static let label: LumenToken = "chart.label"
    }
}

// MARK: Code

public extension LumenPack {
    /// Source code, listings and diffs: syntax colors, the current line, the selection, line
    /// numbers, and added, removed and changed lines. Apps that draw code on their own surface move
    /// these onto it with `surfaceOverrides`.
    static let code: LumenPack = {
        let ink: [LumenToken] = [LumenToken.Code.keyword, LumenToken.Code.type, LumenToken.Code.function, LumenToken.Code.string, LumenToken.Code.number]
        let grounds: [LumenToken] = [.bgCanvas, LumenToken.Code.currentLine]
        func text(_ token: LumenToken, _ summary: String, fallback: LumenFallback? = nil) -> LumenTokenSpec {
            LumenTokenSpec(token, group: "Code", fallback: fallback, contrast: grounds.map { .text(on: $0) }, summary: summary)
        }
        let specs: [LumenTokenSpec] = [
            text(LumenToken.Code.keyword, "Keywords: func, if, return"),
            text(LumenToken.Code.type, "Type names"),
            text(LumenToken.Code.function, "Function and method names"),
            text(LumenToken.Code.string, "String literals"),
            text(LumenToken.Code.number, "Number literals"),
            text(LumenToken.Code.variable, "Variables and parameters", fallback: .token(.fgPrimary)),
            text(LumenToken.Code.comment, "Comments", fallback: .token(.fgTertiary)),
            text(LumenToken.Code.operator, "Operators", fallback: .token(.fgSecondary)),
            text(LumenToken.Code.punctuation, "Brackets, commas, semicolons", fallback: .token(.fgSecondary)),
            LumenTokenSpec(LumenToken.Code.currentLine, group: "Code", fallback: .composite(.accent, alpha: 0.1, over: .bgCanvas),
                           summary: "The line the cursor or program counter is on"),
            LumenTokenSpec(LumenToken.Code.programCounter, group: "Code", fallback: .token(.statusWarning),
                           contrast: [.graphic(on: .bgCanvas), .graphic(on: LumenToken.Code.currentLine)],
                           summary: "The program counter's bar and arrow: amber, never the accent or a status yellow"),
            LumenTokenSpec(LumenToken.Code.selection, group: "Code", fallback: .token(.bgSelected), summary: "Selected text"),
            LumenTokenSpec(LumenToken.Code.lineNumber, group: "Code", fallback: .token(.fgTertiary),
                           contrast: [.text(on: .bgCanvas)], summary: "Line numbers in the gutter"),
            LumenTokenSpec(LumenToken.Code.addedBackground, group: "Diff", fallback: .composite(.statusSuccess, alpha: 0.14, over: .bgCanvas),
                           summary: "Added lines"),
            LumenTokenSpec(LumenToken.Code.removedBackground, group: "Diff", fallback: .composite(.statusDanger, alpha: 0.14, over: .bgCanvas),
                           summary: "Removed lines"),
            LumenTokenSpec(LumenToken.Code.changedBackground, group: "Diff", fallback: .composite(.statusInfo, alpha: 0.14, over: .bgCanvas),
                           summary: "Changed lines"),
            LumenTokenSpec(LumenToken.Code.addedForeground, group: "Diff", fallback: .token(.statusSuccess),
                           contrast: [.graphic(on: LumenToken.Code.addedBackground)], summary: "The + marker and added-word highlight"),
            LumenTokenSpec(LumenToken.Code.removedForeground, group: "Diff", fallback: .token(.statusDanger),
                           contrast: [.graphic(on: LumenToken.Code.removedBackground)], summary: "The − marker and removed-word highlight"),
        ]
        func palette(keyword: LumenColor, type: LumenColor, function: LumenColor, string: LumenColor, number: LumenColor) -> LumenPalette {
            [LumenToken.Code.keyword: keyword, LumenToken.Code.type: type, LumenToken.Code.function: function, LumenToken.Code.string: string, LumenToken.Code.number: number]
        }
        // The program counter is a true amber in every theme (deep enough for 3:1 on white).
        let amberLight: LumenPalette = [LumenToken.Code.programCounter: "#A87200"]
        let amberDark: LumenPalette = [LumenToken.Code.programCounter: "#F5A623"]
        let standardLight = palette(keyword: "#9B2393", type: "#0B4F79", function: "#2E6970", string: "#C41A16", number: "#1C00CF")
            .merging(amberLight).merging([LumenToken.Code.currentLine: "#EAEAEE"])   // neutral, apart from the violet tints
        let standardDark = palette(keyword: "#FC5FA3", type: "#5DD8FF", function: "#67B7A4", string: "#FC6A5D", number: "#D0BF69")
            .merging(amberDark).merging([LumenToken.Code.currentLine: "#20222C"])
        // Maximum legibility wants a plain current-line band (an accent tint over pure white or black
        // barely shows), neutral in light so a find highlight (accent.subtle) still reads on it.
        let contrastLight = palette(keyword: "#7A0F74", type: "#063A5C", function: "#0F4A4F", string: "#9E0D0A", number: "#1400A0")
            .merging([LumenToken.Code.currentLine: "#E8E8E8", LumenToken.Code.programCounter: "#8A5A00"])
        let contrastDark = palette(keyword: "#FF9AC8", type: "#9BE6FF", function: "#9FF0DA", string: "#FFB3A8", number: "#FFE68A")
            .merging([LumenToken.Code.currentLine: "#221D3A", LumenToken.Code.programCounter: "#FFB020"])
        return LumenPack(
            id: "lumen.code",
            tokens: specs,
            themeValues: [
                LumenThemes.standardID: LumenThemeValues(light: standardLight, dark: standardDark,
                                                         lightHighContrast: contrastLight, darkHighContrast: contrastDark),
                LumenThemes.midnightID: LumenThemeValues(dark: palette(keyword: "#FF7AB6", type: "#5CE1FF", function: "#7CF0C8",
                                                                       string: "#FF9E7A", number: "#FFD866").merging(amberDark)
                                                                .merging([LumenToken.Code.currentLine: "#131B33"])),
                LumenThemes.ultravioletID: LumenThemeValues(dark: palette(keyword: "#FF7AD0", type: "#7FD8FF", function: "#8EF0C4",
                                                                          string: "#FFA68A", number: "#F7D774").merging(amberDark)),
                LumenThemes.contrastID: LumenThemeValues(light: contrastLight, dark: contrastDark),
            ],
            rules: [
                LumenDistinctRule(ink, minimumDistance: 0.06, noun: "kinds of code"),
                // A listing's selection, its current-line band and a find highlight can overlap.
                LumenDistinctRule([.accentSubtle, LumenToken.Code.currentLine, .bgSelected], minimumDistance: 0.03,
                                  noun: "the selection, the current line and a find highlight"),
                // The current line must read on the canvas in every theme, Contrast included (7% of the
                // accent over black is still black).
                LumenCustomRule("current line") { theme, appearance, registry in
                    // Contrast, not OKLab distance: near black, distance overstates what a display shows.
                    // Maximum-legibility variants want a plainly visible band.
                    let minimum = theme.isHighContrast || appearance.isHighContrast ? 1.2 : 1.1
                    let canvas = LumenValidator.opaqueGround(.bgCanvas, in: theme, appearance: appearance, registry: registry)
                    let line = theme.color(LumenToken.Code.currentLine, for: appearance, in: registry).over(canvas)
                    let ratio = line.contrastRatio(against: canvas)
                    return ratio >= minimum ? [] : [LumenIssue(.warning, appearance, token: LumenToken.Code.currentLine,
                        "The current line on bg.canvas is \(LumenValidator.format(ratio)):1; needs \(LumenValidator.format(minimum)):1 to show")]
                },
            ]
        )
    }()
}

// MARK: Chart

public extension LumenPack {
    /// Charts and data views: eight series in assignment order, each visible against the canvas (3:1)
    /// and distinct from the others, plus grid lines, axes and labels. Series start from the hue
    /// family and deepen or lighten where a hue alone would be too faint on the canvas.
    static let chart: LumenPack = {
        let hues: [LumenToken] = [.hueViolet, .hueBlue, .hueTeal, .hueOrange, .huePink, .hueGreen, .hueYellow, .hueGraphite]
        var specs: [LumenTokenSpec] = zip(LumenToken.Chart.series, hues).enumerated().map { index, pair in
            LumenTokenSpec(pair.0, group: "Chart", fallback: .token(pair.1), contrast: [.graphic(on: .bgCanvas)],
                           summary: "Series \(index + 1)")
        }
        specs += [
            LumenTokenSpec(LumenToken.Chart.grid, group: "Chart", fallback: .composite(.fgPrimary, alpha: 0.08, over: .bgCanvas),
                           summary: "Grid lines (quiet by design)"),
            LumenTokenSpec(LumenToken.Chart.axis, group: "Chart", fallback: .token(.fgTertiary), contrast: [.graphic(on: .bgCanvas)],
                           summary: "Axes and tick marks"),
            LumenTokenSpec(LumenToken.Chart.label, group: "Chart", fallback: .token(.fgSecondary), contrast: [.text(on: .bgCanvas)],
                           summary: "Axis labels and legends"),
        ]
        // On light canvases the yellow, orange, green, teal and pink hues fall under 3:1; these keep
        // their character a step deeper.
        let deepened: LumenPalette = [
            LumenToken.Chart.series[2]: "#0E8A8A", LumenToken.Chart.series[3]: "#C25E00", LumenToken.Chart.series[4]: "#C2337A",
            LumenToken.Chart.series[5]: "#2E8540", LumenToken.Chart.series[6]: "#9A7300",
        ]
        let contrastLight: LumenPalette = [
            LumenToken.Chart.series[0]: "#4A2FD0", LumenToken.Chart.series[1]: "#0A4DA8", LumenToken.Chart.series[2]: "#006B6B",
            LumenToken.Chart.series[3]: "#B34700", LumenToken.Chart.series[4]: "#9C1C5C", LumenToken.Chart.series[5]: "#0B6B2E",
            LumenToken.Chart.series[6]: "#5E5A00", LumenToken.Chart.series[7]: "#3D3D3D",
        ]
        let contrastDark: LumenPalette = [LumenToken.Chart.series[0]: "#B8A8FF"]
        return LumenPack(
            id: "lumen.chart",
            tokens: specs,
            themeValues: [
                LumenThemes.standardID: LumenThemeValues(light: deepened, lightHighContrast: contrastLight, darkHighContrast: contrastDark),
                LumenThemes.contrastID: LumenThemeValues(light: contrastLight, dark: contrastDark),
            ],
            rules: [LumenDistinctRule(LumenToken.Chart.series, minimumDistance: 0.08, noun: "chart series")]
        )
    }()
}
