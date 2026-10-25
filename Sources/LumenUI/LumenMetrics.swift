import SwiftUI

/// An app's sizes, type, corners and motion. Colors vary by theme; metrics vary by app: one app
/// uses system fonts on a 4 pt grid, another a document face with 5 pt corners.
///
/// Every LumenUI component, the gallery, the editor and density read metrics from
/// `@Environment(\.lumenMetrics)`. An app that customizes them applies its own once at the root:
///
/// ```swift
/// ContentView().lumenMetrics(.myApp)
/// ```
///
/// `standard` reproduces MacScope's shipped values. `Lumen.Space`, `Lumen.Radius` and the other
/// static scales equal `standard`, for app code that doesn't customize; components never use them.
public struct LumenMetrics: Sendable, Equatable {
    /// Spacing ladder. Names are steps, not sizes, so the scale can be retuned in one place.
    public struct Spacing: Sendable, Equatable {
        public var s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11: CGFloat

        public init(s0: CGFloat = 0, s1: CGFloat, s2: CGFloat, s3: CGFloat, s4: CGFloat, s5: CGFloat, s6: CGFloat,
                    s7: CGFloat, s8: CGFloat, s9: CGFloat, s10: CGFloat, s11: CGFloat) {
            (self.s0, self.s1, self.s2, self.s3, self.s4, self.s5) = (s0, s1, s2, s3, s4, s5)
            (self.s6, self.s7, self.s8, self.s9, self.s10, self.s11) = (s6, s7, s8, s9, s10, s11)
        }

        /// A 4 pt grid: 0, 2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48.
        public static let standard = Spacing(s1: 2, s2: 4, s3: 6, s4: 8, s5: 12, s6: 16, s7: 20, s8: 24, s9: 32, s10: 40, s11: 48)
    }

    /// The one corner-radius scale.
    public struct Radius: Sendable, Equatable {
        public var xs, sm, md, lg, xl, pill: CGFloat

        public init(xs: CGFloat, sm: CGFloat, md: CGFloat, lg: CGFloat, xl: CGFloat, pill: CGFloat = 999) {
            (self.xs, self.sm, self.md, self.lg, self.xl, self.pill) = (xs, sm, md, lg, xl, pill)
        }

        /// 4, 6, 8, 10, 14 on the 2 pt grid.
        public static let standard = Radius(xs: 4, sm: 6, md: 8, lg: 10, xl: 14)

        /// Every corner the same size, for apps with one corner radius (pills stay round).
        public static func uniform(_ radius: CGFloat) -> Radius {
            Radius(xs: radius, sm: radius, md: radius, lg: radius, xl: radius)
        }
    }

    public struct Stroke: Sendable, Equatable {
        public var hairline, regular, focus: CGFloat

        public init(hairline: CGFloat, regular: CGFloat, focus: CGFloat) {
            (self.hairline, self.regular, self.focus) = (hairline, regular, focus)
        }

        public static let standard = Stroke(hairline: 1, regular: 1.5, focus: 2)
    }

    /// The type ramp. The standard roles follow the system text size.
    public struct Typography: Sendable, Equatable {
        /// Query text shared by command and input palettes.
        public var paletteQuery: Font { title2 }
        /// Count digits in a row or section header: the emphasized caption with monospaced digits
        /// (not the rounded design), so counts don't shift as they change.
        public var countDigit: Font { captionEmphasized.monospacedDigit() }
        public var title2, title3, headline, body, bodyEmphasized, callout, subheadline, footnote: Font
        public var caption, captionEmphasized: Font
        /// Section headers in sidebars and inspectors: a small, heavy label.
        public var sectionLabel: Font
        public var monoCaption, monoSmall: Font
        /// Display face for welcome, empty states and About. Never in the working surfaces.
        public var display: Font
        /// Tracking of `sectionLabel` (uppercase group labels and table column headers): one value
        /// for every section label.
        public var sectionLabelTracking: CGFloat = 0.5
        /// Large numbers in a stats card.
        public var stat: Font = .system(.title2, design: .rounded).weight(.semibold).monospacedDigit()

        public init(title2: Font, title3: Font, headline: Font, body: Font, bodyEmphasized: Font, callout: Font,
                    subheadline: Font, footnote: Font, caption: Font, captionEmphasized: Font, sectionLabel: Font,
                    monoCaption: Font, monoSmall: Font, display: Font) {
            (self.title2, self.title3, self.headline, self.body, self.bodyEmphasized) = (title2, title3, headline, body, bodyEmphasized)
            (self.callout, self.subheadline, self.footnote, self.caption) = (callout, subheadline, footnote, caption)
            (self.captionEmphasized, self.sectionLabel, self.monoCaption, self.monoSmall, self.display)
                = (captionEmphasized, sectionLabel, monoCaption, monoSmall, display)
        }

        /// Every role, including the section labels' tracking and the stats font.
        public init(title2: Font, title3: Font, headline: Font, body: Font, bodyEmphasized: Font, callout: Font,
                    subheadline: Font, footnote: Font, caption: Font, captionEmphasized: Font, sectionLabel: Font,
                    monoCaption: Font, monoSmall: Font, display: Font, sectionLabelTracking: CGFloat, stat: Font) {
            self.init(title2: title2, title3: title3, headline: headline, body: body, bodyEmphasized: bodyEmphasized,
                      callout: callout, subheadline: subheadline, footnote: footnote, caption: caption,
                      captionEmphasized: captionEmphasized, sectionLabel: sectionLabel, monoCaption: monoCaption,
                      monoSmall: monoSmall, display: display)
            self.sectionLabelTracking = sectionLabelTracking
            self.stat = stat
        }

        public static let standard = Typography(
            // Calm weights: semibold headlines, medium emphasis; bold only for
            // titles and display, so a dense pane doesn't shout.
            title2: .title2.weight(.semibold), title3: .title3.weight(.semibold), headline: .body.weight(.semibold), body: .body,
            bodyEmphasized: .body.weight(.medium), callout: .callout, subheadline: .subheadline, footnote: .footnote,
            caption: .caption, captionEmphasized: .caption.weight(.medium), sectionLabel: .caption2.weight(.medium),
            monoCaption: .caption.monospaced().monospacedDigit(), monoSmall: .system(.callout, design: .monospaced),
            display: .system(.largeTitle, design: .rounded).weight(.bold)
        )
    }

    /// Durations and curves. Always go through `animation(_:reduceMotion:)` so Reduce Motion
    /// turns animation off.
    public struct Motion: Sendable, Equatable {
        /// Changing a duration retimes its curves, so the two never disagree (set a curve afterwards to
        /// give it a different shape).
        public var fast: Double { didSet { fastCurve = .easeInOut(duration: fast) } }
        public var standard: Double {
            didSet {
                regularCurve = .easeInOut(duration: standard)
                standardCurve = .snappy(duration: standard)
            }
        }
        public var emphasized: Double { didSet { emphasizedCurve = .spring(duration: emphasized, bounce: 0.18) } }
        /// Hover, selection and small state changes.
        public var fastCurve: Animation
        /// Panels and lists changing shape.
        public var regularCurve: Animation
        public var standardCurve: Animation
        public var emphasizedCurve: Animation

        public init(fast: Double, standard: Double, emphasized: Double) {
            (self.fast, self.standard, self.emphasized) = (fast, standard, emphasized)
            fastCurve = .easeInOut(duration: fast)
            regularCurve = .easeInOut(duration: standard)
            standardCurve = .snappy(duration: standard)
            emphasizedCurve = .spring(duration: emphasized, bounce: 0.18)
        }

        /// 0.14, 0.22 and 0.32 seconds.
        public static let standard = Motion(fast: 0.14, standard: 0.22, emphasized: 0.32)

        /// `base`, or no animation at all when Reduce Motion is on: the change happens at once.
        /// (A shorter linear animation would still move things, which Reduce Motion asks not to.)
        public func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : base
        }
    }

    /// SF Symbol glyph sizes. Glyphs are sized here, never with literal font sizes in features.
    public struct IconSize: Sendable, Equatable {
        /// Small marks within chips; scales with the small-glyph role.
        public var micro: CGFloat { small * 8 / 11 }
        public var xsmall, small, regular, large, xlarge, hero: CGFloat

        public init(xsmall: CGFloat, small: CGFloat, regular: CGFloat, large: CGFloat, xlarge: CGFloat, hero: CGFloat) {
            (self.xsmall, self.small, self.regular, self.large, self.xlarge, self.hero) = (xsmall, small, regular, large, xlarge, hero)
        }

        public static let standard = IconSize(xsmall: 10, small: 11, regular: 14, large: 16, xlarge: 24, hero: 32)
    }

    /// Structural sizes shared by an app's shell.
    public struct Layout: Sendable, Equatable {
        public var sidebarRailWidth: CGFloat = 40
        public var sidebarRailButton: CGFloat = 28
        /// One-line row heights, by density.
        public var rowHeightCompact: CGFloat = 22
        public var rowHeightRegular: CGFloat = 26
        public var rowHeightComfortable: CGFloat = 30
        /// Two-line (title and detail) row heights, by density.
        public var detailedRowHeightCompact: CGFloat = 32
        public var detailedRowHeightRegular: CGFloat = 36
        public var detailedRowHeightComfortable: CGFloat = 42
        /// Vertical padding of a one-line and a two-line row at regular density.
        public var rowVerticalPadding: CGFloat = 4
        public var detailedRowVerticalPadding: CGFloat = 5
        public var statusBarHeight: CGFloat = 22
        /// Document tab bars and split-pane tab strips.
        public var tabHeight: CGFloat = 32
        /// Pane and section headers that carry a section tile (28 pt tile, 4 pt above and below).
        public var paneHeaderHeight: CGFloat = 36
        /// Filter and control bars immediately below a pane header.
        public var subheaderHeight: CGFloat = 30
        /// The glyph size of a pane-local icon button (`LumenPanelIconButtonStyle`, code-pane and
        /// mode-switcher actions). A glyph size kept here beside the pane header roles it sits in,
        /// not in `IconSize`.
        public var paneActionGlyph: CGFloat = 12
        /// The diameter of a status or edited dot (status strips, document tabs, changed registers).
        public var statusDot: CGFloat = 6
        /// The minimum height of a palette's query field (command and input palettes).
        public var paletteQueryHeight: CGFloat = 50
        /// Content-specific dimensions; these roles intentionally retain different widths.
        public var frameIndexSize: CGFloat = 18
        public var watchExpressionMinWidth: CGFloat = 48
        public var variableNameMinWidth: CGFloat = 24
        public var fontPickerMinWidth: CGFloat = 110
        public var fontPickerMaxWidth: CGFloat = 180
        public var sidebarTileMinWidth: CGFloat = 68
        public var progressMaxWidth: CGFloat = 220
        public var stateMessageMaxWidth: CGFloat = 320
        public var heroRecentMaxWidth: CGFloat = 420
        public var heroMessageMaxWidth: CGFloat = 440
        public var minimumHitTarget: CGFloat = 24
        /// Every toolbar icon button: 28 pt target, 15 pt glyph.
        public var toolbarButton: CGFloat = 28
        public var toolbarGlyphSize: CGFloat = 15
        /// The label column of `LumenPropertyRow` in inspectors.
        public var propertyLabelWidth: CGFloat = 82
        /// Height of every one-line control: text, search, combo and number fields, pop-up and
        /// pull-down buttons, push buttons, and the pill switcher overall (24 pt).
        public var controlHeight: CGFloat = 24
        /// The rim of the pill switcher around its segments; segments are `controlHeight` less
        /// twice this, so the pill is `controlHeight` overall.
        public var pillRim: CGFloat = 2
        /// The box of a checkbox and the circle of a radio.
        public var toggleIndicator: CGFloat = 15
        /// A switch's track height; it is 1.75 times as wide.
        public var switchHeight: CGFloat = 17
        /// The thumb of a slider.
        public var sliderThumb: CGFloat = 16
        /// Horizontal inset of text inside a one-line field (text, combo, number and value fields).
        public var fieldInset: CGFloat = 6
        /// How far a disabled Lumen-drawn control fades.
        public var disabledOpacity: Double = 0.45
        /// How strongly `bg.hover` shows under a hovered row or button.
        public var hoverOpacity: Double = 0.6
        /// Press feedback for labels and filled action controls.
        public var pressedOpacity: Double = 0.8
        /// The icon-tile scale. A pane's header tile sets the size; the tiles under it never drop
        /// far below it (`LumenConformance.iconScale` checks this):
        /// tool switchers match the header, section headers use `tileSection`, and no clickable
        /// tile is smaller than `minimumHitTarget`.
        public var tileHeader: CGFloat = 28
        public var tileInspectorHeader: CGFloat = 32
        public var tileTool: CGFloat = 28
        public var tileSection: CGFloat = 28
        public var tileMode: CGFloat = 22
        /// Tiles beside their text in dense working surfaces (graph nodes, collection rows): the
        /// least an inline tile may be (PRINCIPLES §7).
        public var tileCompact: CGFloat = 16
        /// A one-line menu item or list row: the regular row height less its vertical padding.
        public var tileMenu: CGFloat = 18
        /// A sidebar or settings category row.
        public var tileRow: CGFloat = 20
        /// A two-line (title and detail) row, card or command: the detailed row height less its padding.
        public var tileRowDetailed: CGFloat = 26
        /// A tile that is an item's main visual: launch menus, input palettes, icon choices.
        public var tileProminent: CGFloat = 32
        /// The header of a settings pane, form or item card.
        public var tilePaneHeader: CGFloat = 40
        /// A detail header, or the app mark on a compact welcome panel.
        public var tileHeroCompact: CGFloat = 56
        /// An empty-state hero.
        public var tileHero: CGFloat = 64
        /// The app mark on the welcome window.
        public var tileWelcome: CGFloat = 72
        /// Disclosure and pop-up chevrons (`chevron.right`, `chevron.down`, `chevron.up.chevron.down`),
        /// always drawn bold.
        public var disclosureGlyph: CGFloat = 8

        public init() {}

        public static let standard = Layout()
    }

    public var spacing: Spacing
    public var radius: Radius
    public var stroke: Stroke
    public var typography: Typography
    public var motion: Motion
    public var layout: Layout
    public var iconSize: IconSize

    public init(spacing: Spacing = .standard, radius: Radius = .standard, stroke: Stroke = .standard,
                typography: Typography = .standard, motion: Motion = .standard, layout: Layout = .standard,
                iconSize: IconSize = .standard) {
        self.spacing = spacing
        self.radius = radius
        self.stroke = stroke
        self.typography = typography
        self.motion = motion
        self.layout = layout
        self.iconSize = iconSize
    }

    /// MacScope's shipped values: system fonts, a 4 pt spacing grid, 4/6/8/10/14 corners.
    public static let standard = LumenMetrics()
}

extension EnvironmentValues {
    /// The app's metrics. Set with `.lumenMetrics(_:)`; `standard` otherwise.
    @Entry public var lumenMetrics: LumenMetrics = .standard
}

extension View {
    /// Gives this subtree the app's metrics. Apply once at the root of each window.
    public func lumenMetrics(_ metrics: LumenMetrics) -> some View {
        environment(\.lumenMetrics, metrics)
    }
}

// MARK: Static conveniences

// For app code that doesn't customize metrics. All equal `LumenMetrics.standard`; LumenUI's own
// components read `@Environment(\.lumenMetrics)` instead.

public extension Lumen {
    enum Space {
        public static let s0 = LumenMetrics.standard.spacing.s0
        public static let s1 = LumenMetrics.standard.spacing.s1
        public static let s2 = LumenMetrics.standard.spacing.s2
        public static let s3 = LumenMetrics.standard.spacing.s3
        public static let s4 = LumenMetrics.standard.spacing.s4
        public static let s5 = LumenMetrics.standard.spacing.s5
        public static let s6 = LumenMetrics.standard.spacing.s6
        public static let s7 = LumenMetrics.standard.spacing.s7
        public static let s8 = LumenMetrics.standard.spacing.s8
        public static let s9 = LumenMetrics.standard.spacing.s9
        public static let s10 = LumenMetrics.standard.spacing.s10
        public static let s11 = LumenMetrics.standard.spacing.s11
    }

    enum Radius {
        public static let xs = LumenMetrics.standard.radius.xs
        public static let sm = LumenMetrics.standard.radius.sm
        public static let md = LumenMetrics.standard.radius.md
        public static let lg = LumenMetrics.standard.radius.lg
        public static let xl = LumenMetrics.standard.radius.xl
        public static let pill = LumenMetrics.standard.radius.pill
    }

    enum Stroke {
        public static let hairline = LumenMetrics.standard.stroke.hairline
        public static let regular = LumenMetrics.standard.stroke.regular
        public static let focus = LumenMetrics.standard.stroke.focus
    }

    enum Motion {
        public static let fast = LumenMetrics.standard.motion.fast
        public static let standard = LumenMetrics.standard.motion.standard
        public static let emphasized = LumenMetrics.standard.motion.emphasized
        public static let fastCurve = LumenMetrics.standard.motion.fastCurve
        public static let regularCurve = LumenMetrics.standard.motion.regularCurve
        public static let standardCurve = LumenMetrics.standard.motion.standardCurve
        public static let emphasizedCurve = LumenMetrics.standard.motion.emphasizedCurve

        /// `base`, or `nil` (change at once) when Reduce Motion is on.
        public static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
            LumenMetrics.standard.motion.animation(base, reduceMotion: reduceMotion)
        }
    }

    enum Font {
        public static let title2 = LumenMetrics.standard.typography.title2
        public static let title3 = LumenMetrics.standard.typography.title3
        public static let headline = LumenMetrics.standard.typography.headline
        public static let body = LumenMetrics.standard.typography.body
        public static let bodyEmphasized = LumenMetrics.standard.typography.bodyEmphasized
        public static let callout = LumenMetrics.standard.typography.callout
        public static let subheadline = LumenMetrics.standard.typography.subheadline
        public static let footnote = LumenMetrics.standard.typography.footnote
        public static let caption = LumenMetrics.standard.typography.caption
        public static let captionEmphasized = LumenMetrics.standard.typography.captionEmphasized
        public static let sectionLabel = LumenMetrics.standard.typography.sectionLabel
        public static let monoCaption = LumenMetrics.standard.typography.monoCaption
        public static let monoSmall = LumenMetrics.standard.typography.monoSmall
        public static let display = LumenMetrics.standard.typography.display
        public static let stat = LumenMetrics.standard.typography.stat
        public static let paletteQuery = LumenMetrics.standard.typography.paletteQuery
        public static let countDigit = LumenMetrics.standard.typography.countDigit
        public static let sectionLabelTracking = LumenMetrics.standard.typography.sectionLabelTracking
    }

    enum IconSize {
        public static let micro = LumenMetrics.standard.iconSize.micro
        public static let xsmall = LumenMetrics.standard.iconSize.xsmall
        public static let small = LumenMetrics.standard.iconSize.small
        public static let regular = LumenMetrics.standard.iconSize.regular
        public static let large = LumenMetrics.standard.iconSize.large
        public static let xlarge = LumenMetrics.standard.iconSize.xlarge
        public static let hero = LumenMetrics.standard.iconSize.hero
    }

    enum Layout {
        public static let sidebarRailWidth = LumenMetrics.standard.layout.sidebarRailWidth
        public static let sidebarRailButton = LumenMetrics.standard.layout.sidebarRailButton
        public static let rowHeightCompact = LumenMetrics.standard.layout.rowHeightCompact
        public static let rowHeightRegular = LumenMetrics.standard.layout.rowHeightRegular
        public static let rowHeightComfortable = LumenMetrics.standard.layout.rowHeightComfortable
        public static let detailedRowHeightCompact = LumenMetrics.standard.layout.detailedRowHeightCompact
        public static let detailedRowHeightRegular = LumenMetrics.standard.layout.detailedRowHeightRegular
        public static let detailedRowHeightComfortable = LumenMetrics.standard.layout.detailedRowHeightComfortable
        public static let rowVerticalPadding = LumenMetrics.standard.layout.rowVerticalPadding
        public static let detailedRowVerticalPadding = LumenMetrics.standard.layout.detailedRowVerticalPadding
        public static let statusBarHeight = LumenMetrics.standard.layout.statusBarHeight
        public static let tabHeight = LumenMetrics.standard.layout.tabHeight
        public static let paneHeaderHeight = LumenMetrics.standard.layout.paneHeaderHeight
        public static let minimumHitTarget = LumenMetrics.standard.layout.minimumHitTarget
        public static let toolbarButton = LumenMetrics.standard.layout.toolbarButton
        public static let toolbarGlyphSize = LumenMetrics.standard.layout.toolbarGlyphSize
        public static let propertyLabelWidth = LumenMetrics.standard.layout.propertyLabelWidth
        // The rest of the layout metrics: control height, control parts, opacities, tiles.
        public static let controlHeight = LumenMetrics.standard.layout.controlHeight
        public static let subheaderHeight = LumenMetrics.standard.layout.subheaderHeight
        public static let paneActionGlyph = LumenMetrics.standard.layout.paneActionGlyph
        public static let statusDot = LumenMetrics.standard.layout.statusDot
        public static let paletteQueryHeight = LumenMetrics.standard.layout.paletteQueryHeight
        public static let frameIndexSize = LumenMetrics.standard.layout.frameIndexSize
        public static let watchExpressionMinWidth = LumenMetrics.standard.layout.watchExpressionMinWidth
        public static let variableNameMinWidth = LumenMetrics.standard.layout.variableNameMinWidth
        public static let fontPickerMinWidth = LumenMetrics.standard.layout.fontPickerMinWidth
        public static let fontPickerMaxWidth = LumenMetrics.standard.layout.fontPickerMaxWidth
        public static let sidebarTileMinWidth = LumenMetrics.standard.layout.sidebarTileMinWidth
        public static let progressMaxWidth = LumenMetrics.standard.layout.progressMaxWidth
        public static let stateMessageMaxWidth = LumenMetrics.standard.layout.stateMessageMaxWidth
        public static let heroRecentMaxWidth = LumenMetrics.standard.layout.heroRecentMaxWidth
        public static let heroMessageMaxWidth = LumenMetrics.standard.layout.heroMessageMaxWidth
        public static let pressedOpacity = LumenMetrics.standard.layout.pressedOpacity
        public static let pillRim = LumenMetrics.standard.layout.pillRim
        public static let toggleIndicator = LumenMetrics.standard.layout.toggleIndicator
        public static let switchHeight = LumenMetrics.standard.layout.switchHeight
        public static let sliderThumb = LumenMetrics.standard.layout.sliderThumb
        public static let fieldInset = LumenMetrics.standard.layout.fieldInset
        public static let disabledOpacity = LumenMetrics.standard.layout.disabledOpacity
        public static let hoverOpacity = LumenMetrics.standard.layout.hoverOpacity
        public static let tileHeader = LumenMetrics.standard.layout.tileHeader
        public static let tileInspectorHeader = LumenMetrics.standard.layout.tileInspectorHeader
        public static let tileTool = LumenMetrics.standard.layout.tileTool
        public static let tileSection = LumenMetrics.standard.layout.tileSection
        public static let tileMode = LumenMetrics.standard.layout.tileMode
        public static let tileCompact = LumenMetrics.standard.layout.tileCompact
        public static let tileMenu = LumenMetrics.standard.layout.tileMenu
        public static let tileRow = LumenMetrics.standard.layout.tileRow
        public static let tileRowDetailed = LumenMetrics.standard.layout.tileRowDetailed
        public static let tileProminent = LumenMetrics.standard.layout.tileProminent
        public static let tilePaneHeader = LumenMetrics.standard.layout.tilePaneHeader
        public static let tileHeroCompact = LumenMetrics.standard.layout.tileHeroCompact
        public static let tileHero = LumenMetrics.standard.layout.tileHero
        public static let tileWelcome = LumenMetrics.standard.layout.tileWelcome
        public static let disclosureGlyph = LumenMetrics.standard.layout.disclosureGlyph
    }
}
