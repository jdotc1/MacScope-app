// Generated from MacScope's validated built-in themes (shared roles only). The values are the
// same ones the MacScope design system ships, so apps adopting Lumen look and pass the same.

extension LumenThemes {
    /// The hue family per built-in look. Tiles stay the same in light and dark (as in System
    /// Settings); Midnight brightens them, Contrast deepens them in light and brightens them in dark.
    public static let standardHues: LumenPalette = [
        .hueViolet: "#7B5CE6", .hueIndigo: "#4E5BD8", .hueBlue: "#2D7FF0", .hueTeal: "#14A2A6", .hueGreen: "#25A854",
        .hueYellow: "#F1B80F", .hueOrange: "#E47518", .hueRed: "#EB4848", .huePink: "#E5487F", .hueGraphite: "#8C8E99",
    ]

    public static let midnightHues: LumenPalette = [
        .hueViolet: "#A06BFF", .hueIndigo: "#6F72FF", .hueBlue: "#3AA2FF", .hueTeal: "#00CFD1", .hueGreen: "#3FD86B",
        .hueYellow: "#FFD321", .hueOrange: "#FF9A3C", .hueRed: "#FF4D6D", .huePink: "#FF5CA8", .hueGraphite: "#7C84A3",
    ]

    public static let contrastHues: LumenPalette = [
        .hueViolet: "#5B2FD0", .hueIndigo: "#2F3BC0", .hueBlue: "#0A5BD8", .hueTeal: "#00777B", .hueGreen: "#11793A",
        .hueYellow: "#C98F00", .hueOrange: "#C45A00", .hueRed: "#C21F2F", .huePink: "#B8195A", .hueGraphite: "#5E606B",
    ]

    /// Contrast dark's own hues: brighter than Midnight's on pure black, so hue glyphs (the build
    /// hammer, tile symbols on dark tiles) read at least as strongly as in standard dark (GB-40).
    public static let contrastDarkHues: LumenPalette = [
        .hueViolet: "#BE82FF", .hueIndigo: "#828EFF", .hueBlue: "#4FAEFF", .hueTeal: "#1FE0E0", .hueGreen: "#4BE57E",
        .hueYellow: "#FFDA2E", .hueOrange: "#FFA24A", .hueRed: "#FF6474", .huePink: "#FF6FB5", .hueGraphite: "#A7AAB8",
    ]

    static let standardLight: LumenPalette = standardHues.merging(_standardLight)
    private static let _standardLight: LumenPalette = [
        .titlebarActiveTop: "#ECE8FA", .titlebarActiveBottom: "#F3F2F8",
        // The activity capsule is white: a step off the toolbar, and status text on it reaches 4.5:1.
        .activityBackground: "#FFFFFF",
        .bgWindow: "#ECEEF2", .bgSidebar: "#F6F6F8", .bgCanvas: "#FFFFFF", .bgElevated: "#FFFFFF",
        .bgInset: "#E4E6EB", .bgHover: "#E9EBF0", .bgSelected: "#E4DFFF", .bgSelectedInactive: "#E2E0E9",
        .fgPrimary: "#1B1E26", .fgSecondary: "#4A5162", .fgTertiary: "#5C6476", .fgDisabled: "#979DA9",
        .fgOnAccent: "#FFFFFF", .fgLink: "#5443C9", .borderSubtle: "#E4E6EB", .borderDefault: "#DADADD",
        .borderStrong: "#B4B9C4", .borderFocus: "#6757D0", .accent: "#6757D0", .accentSubtle: "#F5F3FF",
        .accentSoft: "#B0A2FF", .statusSuccess: "#1E7F46", .statusWarning: "#935600", .statusDanger: "#C4283F",
        .statusInfo: "#2966B8", .statusNeutral: "#4A5162", .statusSuccessBackground: "#EDF5F0",
        .statusWarningBackground: "#FBF0D4", .statusDangerBackground: "#F7E1E4", .statusInfoBackground: "#DDE7F4",
        .statusNeutralBackground: "#D9DBDF",
        .menuHighlight: "#5845BC", .borderControl: "#787E8A",
        // The sidebar's inactive selection a step deeper and more violet than
        // bg.selectedInactive, so a hovered neighbour (bg.hover) never reads as a second selection.
        .sidebarRowSelectedInactive: "#DAD6E8",
    ]

    static let standardDark: LumenPalette = standardHues.merging(_standardDark)
    private static let _standardDark: LumenPalette = [
        .titlebarActiveTop: "#2A2442", .titlebarActiveBottom: "#201E2E",
        .bgWindow: "#0D0F13", .bgSidebar: "#1C1F26", .bgCanvas: "#16181E", .bgElevated: "#23262F",
        .bgInset: "#21242C", .bgInsetRaised: "#2B2F3A", .menuHighlight: "#5340CA", .menuHighlightForeground: "#FFFFFF", .bgHover: "#252934", .bgSelected: "#2F2A57", .bgSelectedInactive: "#2D2B40",
        .fgPrimary: "#DDE3EC", .fgSecondary: "#ADB7C5", .fgTertiary: "#959FAF", .fgDisabled: "#5A6270",
        .fgOnAccent: "#111318", .fgLink: "#A99BFF", .borderSubtle: "#2C3039", .borderDefault: "#333748",
        .borderStrong: "#4A4F63", .borderFocus: "#8B7CF6", .accent: "#8B7CF6", .accentSubtle: "#262245",
        .accentSoft: "#B0A2FF", .statusSuccess: "#4CC38A", .statusWarning: "#F2B45A", .statusDanger: "#F0607A",
        .statusInfo: "#7DA8F5", .statusNeutral: "#A3ADBB", .statusSuccessBackground: "#1F332F",
        .statusWarningBackground: "#393128", .statusDangerBackground: "#39242D", .statusInfoBackground: "#262F40",
        .statusNeutralBackground: "#373A44",
        .bgHoverRaised: "#2D313D", .bgSelectedInactiveRaised: "#363449", .borderControl: "#737A90", .activityBackground: "#262935",
    ]

    static let midnightDark: LumenPalette = midnightHues.merging(_midnightDark)
    private static let _midnightDark: LumenPalette = [
        .titlebarActiveTop: "#2A0E40", .titlebarActiveBottom: "#0E1331",
        .bgWindow: "#040817", .bgSidebar: "#0A1128", .bgCanvas: "#080F24", .bgElevated: "#121B38",
        .bgInset: "#0D1530", .bgInsetRaised: "#19244A", .menuHighlight: "#6436C8", .menuHighlightForeground: "#FFFFFF", .bgHover: "#16213F", .bgSelected: "#2B1A66", .bgSelectedInactive: "#1F2250",
        .fgPrimary: "#F2F5FF", .fgSecondary: "#B2B8CC", .fgTertiary: "#8C94AD", .fgDisabled: "#535B78",
        .fgOnAccent: "#060B1B", .fgLink: "#C9A8FF", .borderSubtle: "#1C2644", .borderDefault: "#283456",
        .borderStrong: "#2E3B63", .borderFocus: "#A06BFF", .accent: "#A06BFF", .accentSubtle: "#21153F",
        .accentSoft: "#C9A8FF", .statusSuccess: "#5FD68F", .statusWarning: "#FFD321", .statusDanger: "#FF5468",
        .statusInfo: "#3AA2FF", .statusNeutral: "#B2B8CC", .statusSuccessBackground: "#19352A",
        .statusWarningBackground: "#3A2F1A", .statusDangerBackground: "#33171B", .statusInfoBackground: "#102747",
        .statusNeutralBackground: "#232A3F",
        .bgHoverRaised: "#1C2746", .bgSelectedInactiveRaised: "#252957", .borderControl: "#6371A0", .activityBackground: "#19244A",
    ]

    /// Ultraviolet: deep violet grounds, violet hairlines and a magenta title bar glow, with one accent
    /// (the neon violet) for the tab bar, selected chips, panel toggles and the sidebar's selected pane,
    /// and Midnight's hue values (in sRGB, so a little calmer than Midnight's wide-gamut ones).
    static let ultravioletDark: LumenPalette = midnightHues.merging(_ultravioletDark)
    private static let _ultravioletDark: LumenPalette = [
        .bgWindow: "#100A15", .bgSidebar: "#231834", .bgCanvas: "#18111F", .bgElevated: "#2B1F3E",
        .bgInset: "#291F36", .bgInsetRaised: "#36284C", .menuHighlight: "#7A3AB8", .menuHighlightForeground: "#FFFFFF", .bgHover: "#2E2242", .bgSelected: "#3A2360", .bgSelectedInactive: "#35274D",
        .fgPrimary: "#F1EAFB", .fgSecondary: "#BDB1D0", .fgTertiary: "#A194B6", .fgDisabled: "#66597B",
        .fgOnAccent: "#18111F", .fgLink: "#DDB0FF", .borderSubtle: "#35204F", .borderDefault: "#462A61",
        .borderStrong: "#603B82", .borderFocus: "#D28DFF", .accent: "#C98BFF", .accentSubtle: "#31204B",
        .accentSoft: "#E2BDFF", .statusSuccess: "#5BDC95", .statusWarning: "#F7C64F", .statusDanger: "#FF6B78",
        .statusInfo: "#74B6FF", .statusNeutral: "#B3A7C7", .statusSuccessBackground: "#163A2A",
        .statusWarningBackground: "#3D3016", .statusDangerBackground: "#4A1730", .statusInfoBackground: "#162E4E",
        .statusNeutralBackground: "#41375A",
        .toolbarBackground: "#2A1840", .titlebarActiveTop: "#5E1A8C", .titlebarActiveBottom: "#3F1263",
        .toolbarForeground: "#F6EEFF", .tabActiveFill: "#18111F", .fieldBackground: "#33214F",
        .bgHoverRaised: "#362A4B", .bgSelectedInactiveRaised: "#3C2957", .borderControl: "#8D6EB2", .activityBackground: "#36284C",
        .toolbarSecondaryForeground: "#D8C8EE",
    ]

    static let contrastLight: LumenPalette = contrastHues.merging(_contrastLight)
    private static let _contrastLight: LumenPalette = [
        .titlebarActiveTop: "#FFFFFF", .titlebarActiveBottom: "#FFFFFF",   // no glow under Increase Contrast
        .bgWindow: "#FFFFFF", .bgSidebar: "#FFFFFF", .bgCanvas: "#FFFFFF", .bgElevated: "#FFFFFF",
        .bgInset: "#F2F2F2", .bgHover: "#E6E6E6", .bgSelected: "#D6CCFF", .bgSelectedInactive: "#D9D9D9",
        .fgPrimary: "#000000", .fgSecondary: "#1F1F1F", .fgTertiary: "#555555", .fgDisabled: "#6E6E6E",
        .fgOnAccent: "#FFFFFF", .fgLink: "#3A1FB8", .borderSubtle: "#8C8C8C", .borderDefault: "#4D4D4D",
        .borderStrong: "#000000", .borderFocus: "#3A1FB8", .accent: "#4A2FD0", .accentSubtle: "#E6E0FF",
        .accentSoft: "#7B66E8", .statusSuccess: "#0B6B2E", .statusWarning: "#7A4500", .statusDanger: "#B00020",
        .statusInfo: "#0A4DA8", .statusNeutral: "#1F1F1F", .statusSuccessBackground: "#D8E7DE",
        .statusWarningBackground: "#EAE1D6", .statusDangerBackground: "#F2D6DB", .statusInfoBackground: "#D8E3F1",
        .statusNeutralBackground: "#DBDBDB",
        // Contrast owns every ground (it is also the standard theme's Increase Contrast palette, merged
        // over standard light): set each key standard light sets.
        .activityBackground: "#F2F2F2", .menuHighlight: "#4A2FD0", .borderControl: "#000000", .tabActiveFill: "#F0F0F0",
        .sidebarRowSelectedInactive: "#D9D9D9",
    ]

    static let contrastDark: LumenPalette = contrastDarkHues.merging(_contrastDark)
    private static let _contrastDark: LumenPalette = [
        .titlebarActiveTop: "#000000", .titlebarActiveBottom: "#000000",
        .bgWindow: "#000000", .bgSidebar: "#000000", .bgCanvas: "#000000", .bgElevated: "#121212",
        .bgInset: "#1A1A1A", .bgInsetRaised: "#222222", .menuHighlight: "#4A3BC8", .menuHighlightForeground: "#FFFFFF", .bgHover: "#262626", .bgSelected: "#2B2470", .bgSelectedInactive: "#333333",
        .fgPrimary: "#FFFFFF", .fgSecondary: "#E6E6E6", .fgTertiary: "#B0B0B0", .fgDisabled: "#8A8A8A",
        .fgOnAccent: "#000000", .fgLink: "#C9BDFF", .borderSubtle: "#8A8A8A", .borderDefault: "#BDBDBD",
        .borderStrong: "#FFFFFF", .borderFocus: "#C9BDFF", .accent: "#B8A8FF", .accentSubtle: "#2A2250",
        .accentSoft: "#D6CCFF", .statusSuccess: "#7CFF9E", .statusWarning: "#FFD28A", .statusDanger: "#FF8A9E",
        .statusInfo: "#9CC4FF", .statusNeutral: "#E6E6E6", .statusSuccessBackground: "#142919",
        .statusWarningBackground: "#292216", .statusDangerBackground: "#291619", .statusInfoBackground: "#191F29",
        .statusNeutralBackground: "#2E2E2E",
        .bgHoverRaised: "#262626", .bgSelectedInactiveRaised: "#333333", .borderControl: "#FFFFFF", .activityBackground: "#1A1A1A",
        .tabActiveFill: "#1A1A1A",
    ]
}
