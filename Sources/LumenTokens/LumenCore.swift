// The roles every app shares, and the built-in themes that value them.

public extension LumenToken {
    // Surfaces
    static let bgWindow: LumenToken = "bg.window"
    static let bgSidebar: LumenToken = "bg.sidebar"
    static let bgCanvas: LumenToken = "bg.canvas"
    static let bgElevated: LumenToken = "bg.elevated"
    static let bgInset: LumenToken = "bg.inset"
    /// Wells drawn on a card, popover or sheet. In dark, a step lighter than `bg.elevated`, as
    /// `bg.inset` is a step lighter than the canvas: a well is never darker than what holds it.
    static let bgInsetRaised: LumenToken = "bg.insetRaised"
    static let bgHover: LumenToken = "bg.hover"
    static let bgSelected: LumenToken = "bg.selected"
    static let bgSelectedInactive: LumenToken = "bg.selectedInactive"
    // Text and lines
    static let fgPrimary: LumenToken = "fg.primary"
    static let fgSecondary: LumenToken = "fg.secondary"
    static let fgTertiary: LumenToken = "fg.tertiary"
    static let fgDisabled: LumenToken = "fg.disabled"
    static let fgOnAccent: LumenToken = "fg.onAccent"
    static let fgLink: LumenToken = "fg.link"
    static let borderSubtle: LumenToken = "border.subtle"
    static let borderDefault: LumenToken = "border.default"
    static let borderStrong: LumenToken = "border.strong"
    static let borderFocus: LumenToken = "border.focus"
    // Accent
    static let accent: LumenToken = "accent.default"
    static let accentSubtle: LumenToken = "accent.subtle"
    static let accentSoft: LumenToken = "accent.soft"
    // Status
    static let statusSuccess: LumenToken = "status.success"
    static let statusWarning: LumenToken = "status.warning"
    static let statusDanger: LumenToken = "status.danger"
    static let statusInfo: LumenToken = "status.info"
    static let statusNeutral: LumenToken = "status.neutral"
    static let statusSuccessBackground: LumenToken = "status.successBackground"
    static let statusWarningBackground: LumenToken = "status.warningBackground"
    static let statusDangerBackground: LumenToken = "status.dangerBackground"
    static let statusInfoBackground: LumenToken = "status.infoBackground"
    static let statusNeutralBackground: LumenToken = "status.neutralBackground"
    // Window chrome (component tier)
    static let sidebarBackground: LumenToken = "sidebar.background"
    static let sidebarRowSelected: LumenToken = "sidebar.rowSelected"
    static let sidebarRowSelectedInactive: LumenToken = "sidebar.rowSelectedInactive"
    static let sidebarRowHover: LumenToken = "sidebar.rowHover"
    static let toolbarBackground: LumenToken = "toolbar.background"
    static let tabActiveFill: LumenToken = "tab.activeFill"
    static let tabAccentBar: LumenToken = "tab.accentBar"
    static let inspectorBackground: LumenToken = "inspector.background"
    /// Text on chrome that can differ from the canvas, such as a dark sidebar in a light app.
    static let sidebarForeground: LumenToken = "sidebar.foreground"
    static let sidebarSecondaryForeground: LumenToken = "sidebar.secondaryForeground"
    static let toolbarForeground: LumenToken = "toolbar.foreground"
    /// Selection marks and focus rings drawn on the sidebar. Separate from the accent because no
    /// single color can stand out on both a light canvas and a dark sidebar.
    static let sidebarAccent: LumenToken = "sidebar.accent"
    // Hues: a categorical family for icon tiles, categories and navigation. Glyphs on a tile pick
    // black or white automatically, so every hue stays legible.
    static let hueViolet: LumenToken = "hue.violet"
    static let hueIndigo: LumenToken = "hue.indigo"
    static let hueBlue: LumenToken = "hue.blue"
    static let hueTeal: LumenToken = "hue.teal"
    static let hueGreen: LumenToken = "hue.green"
    static let hueYellow: LumenToken = "hue.yellow"
    static let hueOrange: LumenToken = "hue.orange"
    static let hueRed: LumenToken = "hue.red"
    static let huePink: LumenToken = "hue.pink"
    static let hueGraphite: LumenToken = "hue.graphite"
    /// The hue family in display order.
    static let hues: [LumenToken] = [.hueViolet, .hueIndigo, .hueBlue, .hueTeal, .hueGreen, .hueYellow,
                                     .hueOrange, .hueRed, .huePink, .hueGraphite]
    // Menus and command panels
    static let menuBackground: LumenToken = "menu.background"
    static let menuForeground: LumenToken = "menu.foreground"
    static let menuSecondaryForeground: LumenToken = "menu.secondaryForeground"
    static let menuHighlight: LumenToken = "menu.highlight"
    static let menuHighlightForeground: LumenToken = "menu.highlightForeground"
    static let menuSeparator: LumenToken = "menu.separator"
    static let menuDestructive: LumenToken = "menu.destructive"
    static let keycapBackground: LumenToken = "keycap.background"
    static let keycapForeground: LumenToken = "keycap.foreground"
    // Settings and grouped panels
    static let panelBackground: LumenToken = "panel.background"
    static let panelGroup: LumenToken = "panel.group"
    static let panelGroupBorder: LumenToken = "panel.groupBorder"
    // Welcome window: personality at the edges
    static let welcomeBackground: LumenToken = "welcome.background"
    static let welcomePanel: LumenToken = "welcome.panel"
    static let welcomeGlow: LumenToken = "welcome.glow"
    // Toolbar activity status
    static let activityBackground: LumenToken = "activity.background"
    static let titlebarActiveTop: LumenToken = "titlebar.activeTop"
    static let titlebarActiveBottom: LumenToken = "titlebar.activeBottom"
    static let layoutToggleOn: LumenToken = "layoutToggle.on"
    static let chipSelectedBackground: LumenToken = "chip.selectedBackground"
    static let chipSelectedForeground: LumenToken = "chip.selectedForeground"
    static let fieldBackground: LumenToken = "field.background"
    // one filled-accent look, control edges, raised-ground states
    /// Filled accent shapes: primary buttons, checked boxes and radios, selected chips, filled
    /// selections. In dark a deep tone of the accent under white text (`accent` stays for lines,
    /// glyphs, links and tints).
    static let accentFilled: LumenToken = "accent.filled"
    static let accentFilledForeground: LumenToken = "accent.filledForeground"
    /// Edges of unchecked checkboxes, radios and switches: they must read as controls (3:1).
    static let borderControl: LumenToken = "border.control"
    /// Secondary text in the toolbar (the identity's location), on the title bar glow.
    static let toolbarSecondaryForeground: LumenToken = "toolbar.secondaryForeground"
    /// Hover and inactive selection on a raised ground (cards, popovers, sheets, menus), swapped in
    /// by `LumenResolvedPalette.raised()`; a step above `bg.elevated` in dark.
    static let bgHoverRaised: LumenToken = "bg.hoverRaised"
    static let bgSelectedInactiveRaised: LumenToken = "bg.selectedInactiveRaised"
}

/// Ids and palettes of Lumen's built-in themes.
public enum LumenThemes {
    public static let standardID = "lumen.standard"
    public static let midnightID = "lumen.midnight"
    public static let contrastID = "lumen.contrast"
    public static let ultravioletID = "lumen.ultraviolet"

    /// Cool slate with a violet accent; follows Light and Dark, and uses the Contrast palettes
    /// under Increase Contrast.
    public static let standard = LumenTheme(
        id: standardID, name: "Lumen", summary: "Cool slate with a violet accent. Follows Light and Dark.",
        light: standardLight, dark: standardDark, lightHighContrast: contrastLight, darkHighContrast: contrastDark
    )

    /// Deep navy with wide-gamut signal colors. Always dark.
    public static let midnight = LumenTheme(
        id: midnightID, name: "Midnight", summary: "Deep navy with neon signals. Always dark.",
        colorSpace: .displayP3, light: nil, dark: midnightDark
    )

    /// Deep violet with a glowing title bar, violet hairlines and one neon violet accent. Always dark.
    public static let ultraviolet = LumenTheme(
        id: ultravioletID, name: "Ultraviolet", summary: "Deep violet with a glowing title bar and a neon violet accent. Always dark.",
        light: nil, dark: ultravioletDark
    )

    /// Maximum legibility: pure grounds and strong lines.
    public static let contrast = LumenTheme(
        id: contrastID, name: "Contrast", summary: "Maximum legibility: pure grounds and strong lines.", isHighContrast: true,
        light: contrastLight, dark: contrastDark
    )
}

public extension LumenPack {
    /// Lumen's shared roles, built-in themes and checks.
    static let core: LumenPack = {
        let text: [LumenToken] = [.fgPrimary, .fgSecondary, .fgTertiary]
        let selection: [LumenToken] = [.bgSelected, .bgSelectedInactive]
        let grounds: [LumenToken] = [.bgCanvas, .bgElevated, .bgWindow]
        func surfaces(_ token: LumenToken, _ summary: String) -> LumenTokenSpec {
            LumenTokenSpec(token, group: "Surfaces", summary: summary)
        }
        func status(_ tone: LumenToken, _ background: LumenToken) -> [LumenTokenSpec] {
            [LumenTokenSpec(tone, group: "Status", contrast: [.text(on: .bgCanvas), .text(on: background)]),
             LumenTokenSpec(background, group: "Status", summary: "Fill behind \(tone.rawValue) text")]
        }
        var specs: [LumenTokenSpec] = [
            surfaces(.bgWindow, "Window background and title area"),
            surfaces(.bgSidebar, "Sidebars and source lists"),
            surfaces(.bgCanvas, "The main content area"),
            surfaces(.bgElevated, "Cards, popovers and raised controls"),
            surfaces(.bgInset, "Wells, pills and tags"),
            LumenTokenSpec(.bgInsetRaised, group: "Surfaces", fallback: .token(.bgInset),
                           summary: "Wells, pills and tags on cards, popovers and sheets"),
            surfaces(.bgHover, "Hovered rows"),
            LumenTokenSpec(.bgSelected, group: "Surfaces", followsSystemAccent: true,
                           summary: "Selected rows in the focused window; with the system accent, the canvas tinted with it"),
            surfaces(.bgSelectedInactive, "Selected rows when the window is inactive"),
            LumenTokenSpec(.fgPrimary, group: "Text and Lines",
                           contrast: [.text(on: .bgCanvas), .init(on: .bgSelected, minimum: 7), .text(on: .accentSubtle), .text(on: .bgInset)]),
            LumenTokenSpec(.fgSecondary, group: "Text and Lines",
                           contrast: [.text(on: .bgCanvas), .text(on: .accentSubtle), .text(on: .bgInset)] + selection.map { .text(on: $0) }),
            LumenTokenSpec(.fgTertiary, group: "Text and Lines",
                           contrast: [.text(on: .bgCanvas), .text(on: .accentSubtle)] + selection.map { .text(on: $0) }),
            LumenTokenSpec(.fgDisabled, group: "Text and Lines", summary: "Disabled text; exempt from contrast (WCAG)"),
            LumenTokenSpec(.fgOnAccent, group: "Text and Lines", contrast: [.text(on: .accent)], followsSystemAccent: true),
            LumenTokenSpec(.fgLink, group: "Text and Lines", contrast: [.text(on: .bgCanvas), .text(on: .accentSubtle)]),
            LumenTokenSpec(.borderSubtle, group: "Text and Lines"),
            LumenTokenSpec(.borderDefault, group: "Text and Lines"),
            LumenTokenSpec(.borderStrong, group: "Text and Lines"),
            LumenTokenSpec(.borderFocus, group: "Text and Lines", contrast: grounds.map { .graphic(on: $0) }, followsSystemAccent: true),
            LumenTokenSpec(.accent, group: "Accent", contrast: grounds.map { .graphic(on: $0) } + [.text(on: .accentSubtle)],
                           followsSystemAccent: true),
            LumenTokenSpec(.accentSubtle, group: "Accent", followsSystemAccent: true, summary: "Accent tint behind text"),
            LumenTokenSpec(.accentSoft, group: "Accent", followsSystemAccent: true,
                           summary: "A lighter accent for apps' own marks (charts, badges); Lumen's components don't draw it"),
        ]
        specs += status(.statusSuccess, .statusSuccessBackground) + status(.statusWarning, .statusWarningBackground)
            + status(.statusDanger, .statusDangerBackground) + status(.statusInfo, .statusInfoBackground)
            + status(.statusNeutral, .statusNeutralBackground)
        specs += LumenToken.hues.map { LumenTokenSpec($0, group: "Hues", summary: "Categorical hue for tiles and categories") }
        specs += [
            LumenTokenSpec(.sidebarBackground, group: "Window Chrome", fallback: .token(.bgSidebar)),
            LumenTokenSpec(.sidebarRowSelected, group: "Window Chrome", fallback: .token(.bgSelected)),
            LumenTokenSpec(.sidebarRowSelectedInactive, group: "Window Chrome", fallback: .token(.bgSelectedInactive),
                           summary: "A selected sidebar row in an inactive window; set it with sidebar.foreground so that text reads on it"),
            LumenTokenSpec(.sidebarRowHover, group: "Window Chrome", fallback: .token(.bgHover)),
            LumenTokenSpec(.toolbarBackground, group: "Window Chrome", fallback: .token(.bgSidebar)),
            LumenTokenSpec(.tabActiveFill, group: "Window Chrome", fallback: .token(.bgCanvas)),
            LumenTokenSpec(.tabAccentBar, group: "Window Chrome", fallback: .token(.accent), followsSystemAccent: true),
            LumenTokenSpec(.inspectorBackground, group: "Window Chrome", fallback: .token(.bgSidebar)),
            LumenTokenSpec(.sidebarForeground, group: "Window Chrome", fallback: .token(.fgPrimary),
                           contrast: [.text(on: .sidebarBackground), .text(on: .sidebarRowSelected),
                                      .text(on: .sidebarRowSelectedInactive)],
                           summary: "Sidebar text; set it with sidebar.background for a sidebar darker or lighter than the canvas"),
            LumenTokenSpec(.sidebarSecondaryForeground, group: "Window Chrome", fallback: .token(.fgSecondary),
                           contrast: [.text(on: .sidebarBackground)]),
            LumenTokenSpec(.toolbarForeground, group: "Window Chrome", fallback: .token(.fgPrimary),
                           contrast: [.text(on: .toolbarBackground)]),
            LumenTokenSpec(.sidebarAccent, group: "Window Chrome", fallback: .token(.accent),
                           contrast: [.graphic(on: .sidebarBackground)], followsSystemAccent: true),
            LumenTokenSpec(.menuBackground, group: "Menus", fallback: .token(.bgElevated)),
            LumenTokenSpec(.menuForeground, group: "Menus", fallback: .token(.fgPrimary), contrast: [.text(on: .menuBackground)]),
            LumenTokenSpec(.menuSecondaryForeground, group: "Menus", fallback: .token(.fgSecondary), contrast: [.text(on: .menuBackground)]),
            LumenTokenSpec(.menuHighlight, group: "Menus", fallback: .token(.accent), followsSystemAccent: true,
                           summary: "The highlighted item's fill in menus, and the filled selection in pickers and lists; in dark a deep tone under white text"),
            LumenTokenSpec(.menuHighlightForeground, group: "Menus", fallback: .token(.fgOnAccent),
                           contrast: [.text(on: .menuHighlight)], followsSystemAccent: true),
            LumenTokenSpec(.menuSeparator, group: "Menus", fallback: .token(.borderSubtle)),
            LumenTokenSpec(.menuDestructive, group: "Menus", fallback: .token(.statusDanger), contrast: [.text(on: .menuBackground)]),
            LumenTokenSpec(.keycapBackground, group: "Menus", fallback: .token(.bgInset)),
            LumenTokenSpec(.keycapForeground, group: "Menus", fallback: .token(.fgSecondary), contrast: [.text(on: .keycapBackground)]),
            LumenTokenSpec(.panelBackground, group: "Panels", fallback: .token(.bgWindow), summary: "Settings and preference panes"),
            LumenTokenSpec(.panelGroup, group: "Panels", fallback: .token(.bgElevated), summary: "Grouped form cards"),
            LumenTokenSpec(.panelGroupBorder, group: "Panels", fallback: .token(.borderSubtle)),
            LumenTokenSpec(.welcomeBackground, group: "Welcome", fallback: .token(.bgWindow), summary: "The welcome window's hero side, behind the starfield"),
            LumenTokenSpec(.welcomePanel, group: "Welcome", fallback: .token(.bgSidebar), summary: "The welcome window's recents panel"),
            LumenTokenSpec(.welcomeGlow, group: "Welcome", fallback: .token(.accent), followsSystemAccent: true,
                           summary: "The soft glow behind the app mark"),
            LumenTokenSpec(.activityBackground, group: "Window Chrome", fallback: .token(.bgInset), summary: "The toolbar's activity status capsule"),
            LumenTokenSpec(.titlebarActiveTop, group: "Window Chrome", fallback: .token(.toolbarBackground),
                           summary: "Top of the title bar's glow while the window is active; inactive windows use toolbar.background"),
            LumenTokenSpec(.titlebarActiveBottom, group: "Window Chrome", fallback: .token(.toolbarBackground),
                           summary: "Bottom of the title bar's glow while the window is active"),
            LumenTokenSpec(.layoutToggleOn, group: "Workspace", fallback: .token(.accent),
                           contrast: [.graphic(on: .toolbarBackground), .graphic(on: .titlebarActiveTop), .graphic(on: .titlebarActiveBottom)],
                           followsSystemAccent: true, summary: "A panel toggle's region while that panel shows"),
            LumenTokenSpec(.chipSelectedBackground, group: "Workspace", fallback: .token(.accentFilled), followsSystemAccent: true,
                           summary: "The selected filter chip: a filled accent shape, deep in dark"),
            LumenTokenSpec(.chipSelectedForeground, group: "Workspace", fallback: .token(.accentFilledForeground),
                           contrast: [.text(on: .chipSelectedBackground)], followsSystemAccent: true),
            LumenTokenSpec(.accentFilled, group: "Accent", fallback: .token(.menuHighlight), followsSystemAccent: true,
                           summary: "Filled accent shapes: primary buttons, checked boxes, selected chips; deep in dark"),
            LumenTokenSpec(.accentFilledForeground, group: "Accent", fallback: .token(.menuHighlightForeground),
                           contrast: [.text(on: .accentFilled)], followsSystemAccent: true),
            LumenTokenSpec(.borderControl, group: "Text and Lines", fallback: .token(.borderStrong),
                           summary: "Edges of unchecked checkboxes, radios and switches"),
            LumenTokenSpec(.toolbarSecondaryForeground, group: "Window Chrome", fallback: .token(.fgSecondary),
                           contrast: [.text(on: .toolbarBackground)], summary: "Secondary toolbar text (the identity's location)"),
            LumenTokenSpec(.bgHoverRaised, group: "Surfaces", fallback: .token(.bgHover),
                           summary: "Hover on cards, popovers, sheets and menus"),
            LumenTokenSpec(.bgSelectedInactiveRaised, group: "Surfaces", fallback: .token(.bgSelectedInactive),
                           summary: "Inactive selection on cards, popovers, sheets and menus"),
            LumenTokenSpec(.fieldBackground, group: "Workspace", fallback: .composite(.accent, alpha: 0.1, over: .bgSidebar),
                           summary: "Capsule filter and search fields"),
        ]
        return LumenPack(
            id: "lumen.core",
            tokens: specs,
            themes: [LumenThemes.standard, LumenThemes.midnight, LumenThemes.ultraviolet, LumenThemes.contrast],
            rules: [
                LumenVisibilityRule(.bgSelected, against: .bgCanvas, minimumContrast: 1.25,
                                    message: "The selection is hard to see against the canvas"),
                LumenVisibilityRule(.bgInset, against: .bgCanvas, minimumDistance: 0.02,
                                    message: "Inset surfaces (pills, tags) are hard to see against the canvas"),
                // Dark grounds step up, never down: a well is lighter than the surface that holds it.
                LumenLiftRule(.bgInset, on: .bgCanvas),
                LumenLiftRule(.bgInsetRaised, on: .bgElevated),
                LumenDistinctRule(LumenToken.hues, minimumDistance: 0.06, noun: "hues"),
                // The accent mustn't read as a status: an accent that matches the danger red makes
                // every selection and link look like an error.
                LumenDistinctRule([.accent, .statusDanger, .statusSuccess, .statusWarning], minimumDistance: 0.06,
                                  noun: "the accent from a status"),
                LumenContrastPairsRule([.fgPrimary, .fgSecondary, .fgTertiary], on: [.panelGroup, .panelBackground]),
                LumenContrastPairsRule([.fgPrimary, .fgSecondary, .fgTertiary], on: [.inspectorBackground]),
                LumenContrastPairsRule([.fgPrimary, .fgSecondary, .fgTertiary], on: [.welcomeBackground, .welcomePanel]),
                LumenContrastPairsRule([.fgPrimary, .fgSecondary, .statusSuccess, .statusDanger, .statusWarning], on: [.activityBackground]),
                LumenContrastPairsRule([.toolbarForeground], on: [.titlebarActiveTop, .titlebarActiveBottom]),
                LumenContrastPairsRule([.fgPrimary, .fgSecondary, .fgTertiary], on: [.fieldBackground]),
                LumenContrastPairsRule([.fgPrimary], on: [.tabActiveFill]),
                // Banners: text on the status tints. Rows: text on the selection, active and inactive.
                LumenContrastPairsRule([.fgPrimary], on: [.statusInfoBackground, .statusSuccessBackground,
                                                         .statusWarningBackground, .statusDangerBackground]),
                LumenContrastPairsRule([.fgPrimary, .fgSecondary], on: [.bgSelected, .bgSelectedInactive]),
                LumenContrastPairsRule([.sidebarForeground], on: [.sidebarRowSelected]),
                LumenContrastPairsRule([.sidebarSecondaryForeground], on: [.sidebarRowSelectedInactive]),
                // The accent as text on its own tint: a mode switcher's current mode, tinted badges.
                LumenContrastPairsRule([.accent], on: [.accentSubtle]),
                // Hover fills keep text readable; disabled text stays perceivable (2:1, below the
                // 4.5:1 that active text needs).
                LumenContrastPairsRule([.fgPrimary, .fgSecondary], on: [.bgHover]),
                LumenContrastPairsRule([.sidebarForeground], on: [.sidebarRowHover]),
                LumenContrastPairsRule([.fgDisabled], on: [.bgCanvas, .bgWindow, .bgSidebar, .bgSelected, .bgElevated, .bgInsetRaised],
                                       minimum: 2),
                // wells on every ground that holds them (sidebars, inspectors, panes) step
                // the right way and stay visible.
                LumenLiftRule(.bgInset, on: .bgSidebar),
                LumenLiftRule(.bgInset, on: .inspectorBackground),
                LumenLiftRule(.bgInset, on: .panelBackground),
                LumenVisibilityRule(.bgInset, against: .bgSidebar, minimumDistance: 0.02,
                                    message: "Wells (pills, counts, fields) are hard to see in the sidebar"),
                LumenVisibilityRule(.bgInset, against: .bgWindow, minimumDistance: 0.02,
                                    message: "Wells (pills, counts, fields) are hard to see on the window ground"),
                // Hover and inactive selection: visible on every ground, and told apart from each other.
                LumenVisibilityRule(.bgHoverRaised, against: .bgElevated, minimumDistance: 0.03,
                                    message: "Hover is hard to see on cards, popovers and sheets"),
                LumenLiftRule(.bgHoverRaised, on: .bgElevated),
                LumenVisibilityRule(.bgSelectedInactiveRaised, against: .bgElevated, minimumDistance: 0.03,
                                    message: "An inactive selection is hard to see on cards, popovers and sheets"),
                LumenLiftRule(.bgSelectedInactiveRaised, on: .bgElevated),
                LumenVisibilityRule(.sidebarRowSelectedInactive, against: .sidebarRowHover, minimumDistance: 0.02,
                                    message: "In the sidebar an inactive selection looks like a hovered row"),
                LumenVisibilityRule(.bgSelectedInactive, against: .bgHover, minimumDistance: 0.02,
                                    message: "An inactive selection looks like a hovered row"),
                LumenVisibilityRule(.bgSelectedInactiveRaised, against: .bgHoverRaised, minimumDistance: 0.02,
                                    message: "On raised grounds an inactive selection looks like a hovered row"),
                LumenContrastPairsRule([.fgPrimary, .fgSecondary], on: [.bgHoverRaised, .bgSelectedInactiveRaised]),
                LumenDistinctRule([.accentSubtle, .bgSelected], minimumDistance: 0.03, noun: "a find highlight on a selected row"),
                // Hairlines on raised grounds: menu separators and grouped-card borders.
                LumenVisibilityRule(.menuSeparator, against: .menuBackground, minimumDistance: 0.03,
                                    message: "Menu separators are hard to see"),
                LumenVisibilityRule(.panelGroupBorder, against: .panelGroup, minimumDistance: 0.03,
                                    message: "Grouped card borders and row hairlines are hard to see"),
                // Neutral tags and badges have no border: their fill must read on every ground.
                LumenVisibilityRule(.statusNeutralBackground, against: .bgCanvas, minimumDistance: 0.03,
                                    message: "Neutral tags are hard to see on the canvas"),
                LumenVisibilityRule(.statusNeutralBackground, against: .bgWindow, minimumDistance: 0.03,
                                    message: "Neutral tags are hard to see on the window ground"),
                LumenVisibilityRule(.statusNeutralBackground, against: .bgElevated, minimumDistance: 0.03,
                                    message: "Neutral tags are hard to see on cards"),
                LumenVisibilityRule(.statusNeutralBackground, against: .bgInsetRaised, minimumDistance: 0.03,
                                    message: "Neutral tags are hard to see in wells on cards"),
                LumenContrastPairsRule([.fgPrimary, .statusNeutral], on: [.statusNeutralBackground]),
                // Unchecked checkboxes, radios and switches must read as controls (WCAG 1.4.11).
                LumenContrastPairsRule([.borderControl], on: [.bgCanvas, .bgWindow, .bgElevated, .bgInset, .bgInsetRaised],
                                       minimum: 3),
                // The toolbar's secondary text and the activity capsule sit on the title bar's glow.
                LumenContrastPairsRule([.toolbarSecondaryForeground], on: [.titlebarActiveTop, .titlebarActiveBottom]),
                LumenVisibilityRule(.activityBackground, against: .toolbarBackground, minimumDistance: 0.02,
                                    message: "The activity capsule is hard to see on the toolbar"),
                LumenVisibilityRule(.activityBackground, against: .titlebarActiveTop, minimumDistance: 0.02,
                                    message: "The activity capsule is hard to see on the title bar's glow"),
                // The selected editor tab's plate reads on the strip (the window ground).
                LumenVisibilityRule(.tabActiveFill, against: .bgWindow, minimumDistance: 0.03,
                                    message: "The selected tab's plate is hard to see on the tab strip"),
                // Pairs in real use that nothing else protects.
                LumenContrastPairsRule([.accent], on: [.menuBackground, .bgElevated]),
                LumenContrastPairsRule([.fgTertiary], on: [.bgInsetRaised, .bgHover, .bgElevated]),
                LumenContrastPairsRule([.statusSuccess, .statusWarning, .statusDanger, .statusInfo], on: [.bgElevated, .bgSidebar]),
                LumenDistinctRule([.accent, .statusInfo], minimumDistance: 0.06, noun: "the accent from information"),
                LumenCustomRule("composited text on filled accent shapes") { theme, appearance, registry in
                    // Palette rows dim matched letters to 82% of the highlight's text, and keycaps on a
                    // highlighted row are the text at 18% over the fill.
                    [(LumenToken.menuHighlight, LumenToken.menuHighlightForeground), (.accentFilled, .accentFilledForeground)]
                        .flatMap { fill, text -> [LumenIssue] in
                            let ground = LumenValidator.opaqueGround(fill, in: theme, appearance: appearance, registry: registry)
                            let ink = theme.color(text, for: appearance, in: registry)
                            let dimmed = ink.composited(alpha: 0.82, over: ground).contrastRatio(against: ground, in: theme.colorSpace)
                            let keycap = ink.composited(alpha: 0.18, over: ground)
                            let onKeycap = ink.over(keycap).contrastRatio(against: keycap, in: theme.colorSpace)
                            return [(dimmed, "at 82%"), (onKeycap, "on a keycap")].compactMap { ratio, how in
                                ratio >= 4.5 ? nil : LumenIssue(.error, appearance, token: text,
                                    "\(text.rawValue) \(how) on \(fill.rawValue) is \(LumenValidator.format(ratio)):1; needs 4.5:1")
                            }
                        }
                },
                LumenCustomRule("disabled toolbar buttons") { theme, appearance, registry in
                    // Lumen's toolbar button style draws a disabled glyph at 45% of toolbar.foreground.
                    let glyph = theme.color(.toolbarForeground, for: appearance, in: registry)
                    return [LumenToken.toolbarBackground, .titlebarActiveTop, .titlebarActiveBottom].compactMap { ground in
                        let groundColor = theme.color(ground, for: appearance, in: registry)
                        let ratio = glyph.composited(alpha: 0.45, over: groundColor).contrastRatio(against: groundColor, in: theme.colorSpace)
                        return ratio >= 2 ? nil : LumenIssue(.error, appearance, token: .toolbarForeground,
                                                             "Disabled toolbar buttons on \(ground.rawValue) are \(LumenValidator.format(ratio)):1; need 2:1")
                    }
                },
            ]
        )
    }()
}
