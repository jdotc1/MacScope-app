import SwiftUI
import XCTest
import LumenTokens
import LumenConformance
@testable import LumenUI

/// Golden images of Lumen's components and showcase in every built-in theme variant, plus the
/// showcase under custom metrics. Re-record after an intentional visual change with
/// `LUMEN_RECORD_SNAPSHOTS=1 swift test --filter LumenGoldenTests` (that run fails by design),
/// review the PNGs in Tests/LumenUITests/Goldens, then run again.
@MainActor
final class LumenGoldenTests: XCTestCase {
    /// CI runs on another macOS, whose text rendering differs from the recording machine's: there
    /// `LUMEN_SKIP_GOLDENS=1` skips the image comparisons. The design-rule checks in `check` still run.
    static var skipsGoldens: Bool { ProcessInfo.processInfo.environment["LUMEN_SKIP_GOLDENS"] == "1" }

    private func skipGoldensIfNeeded() throws {
        try XCTSkipIf(Self.skipsGoldens, "Golden images are checked on the recording Mac")
    }

    /// Design-rule findings in the golden views known today, as "<golden> · <check> · <finding>".
    /// Each is a known issue awaiting a fix. (Not checked for staleness: one test sees only its own goldens.)
    static let knownFindings: Set<String> = []

    /// Goldens with a `LumenTable`, drawn in a real window so its columns take their live, measured
    /// widths (CODE-11); the one-pass image renderer can only split them equally. "editors" stays on
    /// the image renderer: its rule editor's AppKit text fields settle a pixel differently depending
    /// on which tests ran earlier in the process, so a window capture of it isn't deterministic.
    static let windowRendered: Set<String> = ["controls", "forms", "table-headers", "table-live-widths", "tools"]
    /// `LUMEN_GOLDENS_DIR` points recording at a scratch folder, for a look without touching the goldens.
    static let goldens = ProcessInfo.processInfo.environment["LUMEN_GOLDENS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Goldens", directoryHint: .isDirectory)
    let registry = LumenRegistry.core
    var variants: [LumenSnapshot.Variant] { LumenSnapshot.Variant.all(for: registry.galleryThemes) }

    /// A neutral example of an app with its own identity: serif type, roomier spacing, sharper corners.
    static let customMetrics: LumenMetrics = {
        var metrics = LumenMetrics.standard
        metrics.radius = .uniform(2)
        metrics.spacing = .init(s1: 3, s2: 6, s3: 8, s4: 10, s5: 14, s6: 20, s7: 24, s8: 28, s9: 36, s10: 44, s11: 52)
        let serif = { (style: Font.TextStyle, weight: Font.Weight) in Font.system(style, design: .serif).weight(weight) }
        metrics.typography = .init(title2: serif(.title2, .bold), title3: serif(.title3, .bold), headline: serif(.headline, .bold),
                                   body: serif(.body, .regular), bodyEmphasized: serif(.body, .semibold), callout: serif(.callout, .regular),
                                   subheadline: serif(.subheadline, .regular), footnote: serif(.footnote, .regular),
                                   caption: serif(.caption, .regular), captionEmphasized: serif(.caption, .bold),
                                   sectionLabel: serif(.caption2, .bold), monoCaption: .caption.monospaced(),
                                   monoSmall: .system(.callout, design: .monospaced), display: serif(.largeTitle, .bold))
        metrics.layout.rowHeightRegular = 30
        return metrics
    }()

    private func check<V: View>(_ view: V, _ name: String, _ size: CGSize, metrics: LumenMetrics = .standard,
                                only: [LumenSnapshot.Variant]? = nil, registry: LumenRegistry? = nil,
                                renderer: LumenSnapshot.Renderer? = nil) {
        // PRINCIPLES §6–7 on every golden view, whether or not its images are compared here.
        let content = { view.lumenMetrics(metrics) }
        let sizes = [size]
        let findings = LumenConformance.truncation(sizes: sizes, of: content).map { "\(name) · truncation · \($0)" }
            + LumenConformance.iconScale(sizes: sizes, of: content).map { "\(name) · iconScale · \($0)" }
            + LumenConformance.overflow(sizes: sizes, of: content).map { "\(name) · overflow · \($0)" }
            + LumenConformance.backlight(sizes: sizes, of: content).map { "\(name) · backlight · \($0)" }
        for finding in findings where !Self.knownFindings.contains(finding) {
            XCTFail("new design-rule finding: \"\(finding)\"")
        }
        guard !Self.skipsGoldens else { return }
        for variant in only ?? variants {
            let outcome = LumenSnapshot.verify(view, named: name, size: size, variant: variant, registry: registry ?? self.registry,
                                               metrics: metrics, goldenDirectory: Self.goldens,
                                               renderer: renderer ?? (Self.windowRendered.contains(name) ? .window : .image))
            if let message = outcome.failureMessage { XCTFail("\(name)@\(variant.label): \(message)") }
        }
    }

    func testVariantsCoverEveryBuiltInAppearance() throws {
        try skipGoldensIfNeeded()
        XCTAssertEqual(variants.map(\.label), ["standard-light", "standard-dark", "midnight-dark", "ultraviolet-dark", "contrast-light", "contrast-dark"])
    }

    func testShowcase() { check(LumenShowcase(), "showcase", CGSize(width: 560, height: 340)) }

    func testBadgeTones() {
        // Real labels, in sentence case as apps write them (a lowercase enum name hides case issues).
        let labels: [LumenBadge.Tone: String] = [.neutral: "Draft", .accent: "New", .success: "Verified", .warning: "2 inferred",
                                                 .danger: "Unsigned", .info: "Beta"]
        check(HStack(spacing: 8) { ForEach(LumenBadge.Tone.allCases, id: \.self) { LumenBadge(labels[$0] ?? "Badge", tone: $0) } },
              "badge-tones", CGSize(width: 520, height: 44))
    }

    func testEmptyState() {
        check(LumenEmptyState(systemImage: "tray", title: "Nothing here yet", message: "Items you add appear in this list.",
                              actionTitle: "Add item", action: {}),
              "empty-state", CGSize(width: 320, height: 220))
    }

    func testIconTiles() {
        let symbols = ["star.fill", "paintpalette.fill", "bolt.fill", "leaf.fill", "drop.fill", "sun.max.fill",
                       "flame.fill", "heart.fill", "sparkles", "gearshape.fill"]
        check(VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Array(LumenToken.hues.enumerated()), id: \.offset) { index, hue in LumenIconTile(symbols[index], hue: hue, size: 28) }
            }
            HStack(spacing: 10) {
                LumenIconTile("gearshape.fill", hue: .hueGraphite, size: 16)
                LumenIconTile("gearshape.fill", hue: .hueGraphite, size: 20)
                LumenIconTile("gearshape.fill", hue: .hueGraphite, size: 40)
                LumenIconTile("gearshape.fill", hue: .hueGraphite, size: 64)
            }
        }, "icon-tiles", CGSize(width: 420, height: 130))
    }

    static let sampleMenu: [LumenMenuEntry] = [
        .section("Navigate"),
        .item("Go to Address…", subtitle: "Jump to any address or symbol", systemImage: "number", hue: .hueBlue,
              shortcut: KeyboardShortcut("g", modifiers: [.command])),
        .item("Find in Project", systemImage: "magnifyingglass", hue: .hueTeal, shortcut: KeyboardShortcut("f", modifiers: [.command, .shift])),
        .submenu("Open Recent", systemImage: "clock.fill", hue: .hueOrange, [
            .item("Calculator.app", systemImage: "app.fill", hue: .hueGraphite),
            .item("libsystem_kernel.dylib", systemImage: "shippingbox.fill", hue: .hueIndigo),
            .separator("recent"),
            .item("Clear Menu"),
        ]),
        .separator("main"),
        .section("View"),
        .item("Show Inspector", systemImage: "sidebar.right", hue: .hueViolet, shortcut: KeyboardShortcut("i", modifiers: [.command, .option]),
              isChecked: true),
        .item("Compact Rows", systemImage: "rectangle.compress.vertical", hue: .hueGreen, isEnabled: false),
        .separator("end"),
        .item("Delete Bookmark", systemImage: "trash.fill", hue: .hueRed, isDestructive: true),
    ]

    func testCommandMenuWithOpenSubmenu() {
        check(HStack(alignment: .top) {
            LumenCommandMenu(Self.sampleMenu, width: 300, highlighted: 3, openSubmenu: 3).padding(.top, 12).padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), "command-menu", CGSize(width: 640, height: 420))
    }

    func testKeycaps() {
        check(HStack(spacing: 14) {
            LumenKeycap(KeyboardShortcut("k", modifiers: [.command]))
            LumenKeycap(KeyboardShortcut("f", modifiers: [.command, .shift]))
            LumenKeycap(KeyboardShortcut(.return, modifiers: [.command, .option]))
            LumenKeycap(["⌃", "Space"])
        }, "keycaps", CGSize(width: 320, height: 40))
    }

    static let welcome = LumenWelcomeView(
        appName: "Lumen", version: "1.0", tagline: "A design system for Mac apps with character.",
        markSymbol: "lumen.lens", markHue: .hueViolet,
        actions: [
            LumenWelcomeAction("New Project", subtitle: "Start from a template", systemImage: "plus", hue: .hueViolet,
                               shortcut: KeyboardShortcut("n", modifiers: [.command]), isPrimary: true) {},
            LumenWelcomeAction("Open…", subtitle: "Browse for a project", systemImage: "folder.fill", hue: .hueBlue,
                               shortcut: KeyboardShortcut("o", modifiers: [.command])) {},
            LumenWelcomeAction("Clone Repository…", systemImage: "arrow.down", hue: .hueTeal) {},
        ],
        recents: [
            LumenRecentItem(title: "Lumen", detail: "~/Projects/Lumen", systemImage: "lumen.lens", hue: .hueViolet),
            LumenRecentItem(title: "MacScope", detail: "~/Projects/MacScope", systemImage: "scope", hue: .hueIndigo),
            LumenRecentItem(title: "Field Notes", detail: "~/Documents/Field Notes", systemImage: "book.closed.fill", hue: .hueOrange),
            LumenRecentItem(title: "Scans", detail: "~/Documents/Scans", systemImage: "doc.viewfinder.fill", hue: .hueTeal),
        ]
    )

    func testWelcomeWindow() { check(Self.welcome, "welcome", CGSize(width: 760, height: 460)) }

    func testToolbarPieces() {
        let tasks = [
            LumenTaskAction("Build", systemImage: "hammer.fill", shortcut: KeyboardShortcut("b", modifiers: [.command])) {},
            LumenTaskAction("Run", systemImage: "play.fill", role: .start, shortcut: KeyboardShortcut("r", modifiers: [.command])) {},
            LumenTaskAction("Stop", systemImage: "stop.fill", role: .stop, shortcut: KeyboardShortcut(".", modifiers: [.command])) {},
        ]
        let states: [LumenActivity] = [.idle(), .working("Analyzing libsystem_kernel.dylib", progress: 0.42),
                                       .succeeded("Build succeeded"), .failed("2 errors")]
        check(ToolbarStrip(tasks: tasks, states: states), "toolbar", CGSize(width: 760, height: 200))
    }

    private struct ToolbarStrip: View {
        let tasks: [LumenTaskAction]
        let states: [LumenActivity]
        @Environment(\.lumenPalette) private var palette
        var body: some View {
            VStack(spacing: 0) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    HStack(spacing: 16) {
                        LumenToolbarIdentity("Lumen", subtitle: "~/Projects/Lumen", systemImage: "lumen.lens", hue: .hueViolet)
                        Spacer()
                        // The toolbar's status, which shows nothing while idle (PRINCIPLES §9).
                        LumenToolbarStatus(state)
                        Spacer()
                        LumenTaskCluster(tasks, activity: state)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background(palette[.toolbarBackground])
                    .overlay(alignment: .bottom) { Rectangle().fill(palette[.borderSubtle]).frame(height: 1) }
                }
            }
        }
    }

    func testInspector() { check(InspectorSample(), "inspector", CGSize(width: 300, height: 520)) }

    private struct InspectorSample: View {
        var body: some View {
            LumenInspector(scrolls: false) {
                LumenInspectorHeader("sub_100003f80", subtitle: "Function · 212 bytes", systemImage: "function", hue: .hueIndigo)
                LumenInspectorSection("Identity", systemImage: "tag.fill", hue: .hueBlue) {
                    LumenPropertyRow(label: "Address", value: "0x100003f80")
                    LumenPropertyRow(label: "Segment", value: "__TEXT,__text")
                    LumenPropertyRow(label: "Callers", value: "4", monospaced: false)
                }
                LumenInspectorSection("Appearance", systemImage: "paintpalette.fill", hue: .huePink) {
                    LumenInspectorRow("Color") { LumenHueSwatchPicker(selection: .constant(.hueIndigo), hues: [.hueViolet, .hueIndigo, .hueBlue, .hueTeal, .hueGreen, .hueOrange], size: 16) }
                    LumenInspectorRow("Tags") {
                        HStack(spacing: 4) { LumenTag("hot path", token: .hueOrange); LumenTag("crypto", token: .hueTeal) }
                    }
                }
                LumenInspectorSection("Notes", systemImage: "note.text", hue: .hueYellow, isExpanded: .constant(false)) { Text("Hidden") }
                LumenInspectorSection("Evidence", systemImage: "checkmark.seal.fill", hue: .hueGreen) {
                    // Badges are a value: they sit in the value column, as every row does.
                    LumenInspectorRow("Status") {
                        HStack(spacing: 6) { LumenBadge("Verified", systemImage: "checkmark", tone: .success); LumenBadge("2 inferred", tone: .warning) }
                    }
                }
            }
        }
    }

    func testPopovers() { check(PopoverSample(), "popovers", CGSize(width: 640, height: 260)) }

    private struct PopoverSample: View {
        @Environment(\.lumenPalette) private var palette
        var body: some View {
            HStack(alignment: .top, spacing: 24) {
                card(LumenPopoverContent("Increase Contrast", systemImage: "info", hue: .hueBlue, width: 260) {
                    Text("Themes define a stronger variant for each appearance. Lumen switches to it when the system setting is on.")
                        .fixedSize(horizontal: false, vertical: true)
                })
                card(LumenPopoverContent("Color", subtitle: "Teal", systemImage: "paintpalette.fill", hue: .hueTeal, width: 260) {
                    LumenHueSwatchGrid(selection: .constant(.hueTeal), hues: LumenToken.hues)
                } footer: {
                    Button("Edit Colors…") {}.buttonStyle(.plain).foregroundStyle(palette[.fgLink])
                })
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette[.bgCanvas])
        }

        // Stands in for the system popover material, which offscreen rendering can't draw.
        private func card(_ content: some View) -> some View {
            content
                .background(palette[.bgElevated], in: .rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette[.borderSubtle]) }
                .compositingGroup()   // one shadow for the card, not one per swatch and text run (GB-12)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }

    func testGlyphs() { check(GlyphSheet(), "glyphs", CGSize(width: 728, height: 300)) }

    /// Every built-in glyph: inline as its symbol at 24 and 16 pt, and in tiles at 32 and 20 pt.
    private struct GlyphSheet: View {
        @Environment(\.lumenPalette) private var palette
        private let hues: [LumenToken] = [.hueViolet, .hueIndigo, .hueBlue, .hueTeal, .hueGreen, .hueYellow, .hueOrange, .hueRed, .huePink]
        var body: some View {
            let glyphs = LumenGlyph.builtIns
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(Array(stride(from: 0, to: glyphs.count, by: 9)), id: \.self) { start in
                    GridRow {
                        ForEach(Array(glyphs[start..<min(start + 9, glyphs.count)].enumerated()), id: \.offset) { index, glyph in
                            VStack(spacing: 6) {
                                HStack(alignment: .center, spacing: 6) {
                                    // Inline, as apps draw them: the symbol (outline), not the raw glyph paths.
                                    LumenSymbol(glyph.symbolName, size: 24)
                                    LumenSymbol(glyph.symbolName, size: 16)
                                }
                                .frame(height: 28)   // a fixed band, so tiles and labels line up across the row
                                .foregroundStyle(palette[.fgPrimary])
                                HStack(alignment: .bottom, spacing: 6) {
                                    LumenIconTile(glyph.symbolName, hue: hues[(start + index) % hues.count], size: 32)
                                    LumenIconTile(glyph.symbolName, hue: hues[(start + index) % hues.count], size: 20)
                                }
                                Text(glyph.title).font(.caption2).foregroundStyle(palette[.fgSecondary])
                                    .lineLimit(2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: 68)
                            .frame(maxHeight: .infinity, alignment: .top)   // top-aligned cells: one baseline per row
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette[.bgCanvas])
        }
    }

    func testWorkspacePieces() { check(WorkspaceSheet(), "workspace", CGSize(width: 780, height: 470)) }

    /// The workspace pieces that draw in SwiftUI (native menus, tables and text fields don't render offscreen).
    private struct WorkspaceSheet: View {
        @Environment(\.lumenPalette) private var palette
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                // A title bar strip with the glow, as an active window shows it.
                HStack(spacing: 12) {
                    LumenToolbarBreadcrumb(["Lumen", "Sources"], systemImage: "lumen.lens", hue: .hueViolet)
                    Spacer()
                    HStack(spacing: 2) {
                        LumenPanelToggles(leading: .constant(true), bottom: .constant(true), trailing: .constant(false))
                        LumenNewItemButton {}
                    }
                }
                .padding(.horizontal, 14).frame(height: 50)
                .background(LinearGradient(colors: [palette[.titlebarActiveTop], palette[.titlebarActiveBottom]], startPoint: .top, endPoint: .bottom))
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        LumenSidebarSwitcher(selection: .constant("symbols"), items: [
                            LumenSidebarItem(id: "files", title: "Files", systemImage: "folder"),
                            LumenSidebarItem(id: "symbols", title: "Symbols", systemImage: "list.bullet.indent"),
                            LumenSidebarItem(id: "graph", title: "Call Graph", systemImage: "lumen.callGraph"),
                            LumenSidebarItem(id: "cloud", title: "Remote", systemImage: "icloud"),
                        ])
                        LumenSidebarSection("Open Pull Requests", accessory: { Image(systemName: "plus") }) {
                            Text("No open pull requests.").font(.callout).foregroundStyle(palette[.fgTertiary]).padding(.vertical, 18)
                        }
                        // The filter is anchored at the sidebar's foot, as in the workspace, not floating under the list.
                        Spacer(minLength: 0)
                        Capsule().fill(palette[.fieldBackground]).frame(height: 24).padding(10)
                            .overlay(alignment: .leading) {
                                Label("Filter", systemImage: "line.3.horizontal.decrease.circle").font(.callout)
                                    .foregroundStyle(palette[.fgTertiary]).padding(.leading, 20)
                            }
                    }
                    // The sidebar's surface runs the window's full height (PRINCIPLES §8).
                    .frame(width: 230, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(palette[.sidebarBackground])
                    // The split view's divider, which a live HSplitView draws (Contrast has no fill change here).
                    .overlay(alignment: .trailing) { Rectangle().fill(palette[.borderSubtle]).frame(width: 1) }
                    // The document tabs belong to the content pane: their selected tab sits on the pane's surface.
                    VStack(alignment: .leading, spacing: 0) {
                    LumenDocumentTabBar([
                        LumenDocumentTab(id: "a", title: "index.html", systemImage: "globe", hue: .hueGreen, isEdited: true),
                        LumenDocumentTab(id: "b", title: "untitled", systemImage: "doc", hue: .fgTertiary, isPreview: true),
                    ], selection: .constant("a"))
                    VStack(alignment: .leading, spacing: 14) {
                        LumenPanelTabs(selection: .constant("console"), tabs: [
                            LumenPanelTab(id: "debug", title: "Debug Console", systemImage: "ladybug.fill", hue: .hueBlue),
                            LumenPanelTab(id: "console", title: "Extension Console", systemImage: "puzzlepiece.extension.fill", hue: .hueBlue),
                            LumenPanelTab(id: "transcript", title: "Transcript", systemImage: "doc.plaintext", hue: .hueBlue),
                        ])
                        HStack(spacing: 10) {
                            LumenFilterChips(selection: .constant(LumenLogFilter.all), options: LumenLogFilter.allCases, title: \.title)
                            // Clear is an action, set apart from the level chips (as LumenLogFilterBar draws it).
                            Rectangle().fill(palette[.borderSubtle]).frame(width: 1, height: 16)
                            Button("Clear") {}.buttonStyle(.lumenQuiet)
                        }
                        HStack(alignment: .top, spacing: 14) {
                            LumenLaunchMenu([
                                LumenLaunchItem("Document", systemImage: "doc.fill", hue: .hueGraphite) {},
                                LumenLaunchItem("Local Terminal", systemImage: "terminal.fill", hue: .hueGreen) {},
                                LumenLaunchItem("File Browser", systemImage: "folder.fill", hue: .hueTeal) {},
                            ])
                            // The popover's ground and edge, as in both appearances.
                            .background(palette[.menuBackground], in: .rect(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette[.borderDefault], lineWidth: 1) }
                            .frame(width: 250)
                            HStack(spacing: 8) {
                                LumenDropZone()
                                LumenDropZone("Drop to dock", isTargeted: true)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)   // the drop zones run the menu's height
                    }
                    .padding(14)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette[.bgCanvas])
        }
    }

    static let paletteCommands: [LumenCommand] = [
        LumenCommand(id: "view.panel", "Hide Panel", category: "View", systemImage: "rectangle.bottomthird.inset.filled", hue: .hueBlue,
                     shortcut: LumenShortcuts.panel) {},
        LumenCommand(id: "view.inspector", "Show Inspector", category: "View", systemImage: "sidebar.trailing", hue: .hueBlue,
                     shortcut: LumenShortcuts.inspector) {},
        LumenCommand(id: "go.graph", "Go to Call Graph", subtitle: "sub_100003f80", category: "Go", systemImage: "lumen.callGraph",
                     hue: .hueGreen) {},
        LumenCommand(id: "go.listing", "Go to Disassembly", category: "Go", systemImage: "lumen.disassembly", hue: .hueYellow,
                     isEnabled: false) {},
        LumenCommand(id: "panel.console", "Show Extension Console", category: "Panel", systemImage: "puzzlepiece.extension.fill",
                     hue: .hueTeal) {},
        LumenCommand(id: "theme.ultraviolet", "Use Ultraviolet Theme", subtitle: "Deep violet with a glowing title bar.",
                     category: "Theme", systemImage: "paintpalette.fill", hue: .hueOrange) {},
    ]

    func testCommandPalette() {
        check(LumenCommandPalette(Self.paletteCommands, query: "", recents: ["panel.console"], highlighted: "panel.console")
                .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top), "command-palette", CGSize(width: 640, height: 560))
        check(LumenCommandPalette(Self.paletteCommands, query: "pan", recents: [], highlighted: "view.panel")
                .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top), "command-palette-search", CGSize(width: 640, height: 300))
    }

    func testAppIcons() {
        check(HStack(spacing: 8) {
            LumenAppIcon("lumen.lens", hue: .hueViolet, size: 128)
            LumenAppIcon("lumen.callGraph", hue: .hueIndigo, size: 128)
            LumenAppIcon("lumen.anonymize", hue: .hueTeal, size: 128)
            LumenAppIcon("lumen.lens", hue: .hueViolet, size: 32)
        }.padding(8), "app-icons", CGSize(width: 456, height: 144))   // 8 + 3 × 128 + 3 × 8 + 32 + 8
    }

    func testDockIconImageIsFullResolution() throws {
        try skipGoldensIfNeeded()
        let image = try XCTUnwrap(LumenDockIcon.image("lumen.lens", hue: .hueViolet))
        XCTAssertEqual(image.size, NSSize(width: 512, height: 512))
        XCTAssertEqual(image.representations.first?.pixelsWide, 1024)
    }

    func testShowcaseAdaptsToAppMetrics() throws {
        let light = try XCTUnwrap(variants.first)
        check(LumenShowcase(), "showcase-custom-metrics", CGSize(width: 560, height: 340), metrics: Self.customMetrics, only: [light])
        try skipGoldensIfNeeded()
        let standard = try XCTUnwrap(LumenSnapshot.png(of: LumenShowcase(), size: CGSize(width: 560, height: 340), variant: light, registry: registry))
        let custom = try XCTUnwrap(LumenSnapshot.png(of: LumenShowcase(), size: CGSize(width: 560, height: 340), variant: light,
                                                     registry: registry, metrics: Self.customMetrics))
        XCTAssertGreaterThan(LumenSnapshot.compare(standard, custom).differingPixelFraction, 0.02,
                             "Same view, same theme, different metrics: the render must change")
    }

    // MARK: States, rows and the inline welcome 

    func testBannersAndStates() {
        check(VStack(spacing: 12) {
            LumenBanner("The binary changed on disk since it was analyzed.", title: "Out of date", tone: .warning,
                        actionTitle: "Reanalyze", action: {}, onDismiss: {})
            LumenBanner("Symbols loaded from the dSYM.", tone: .success)
            LumenBanner("The debugger lost its connection.", title: "Disconnected", tone: .danger, onDismiss: {})
            HStack(alignment: .top, spacing: 0) {
                LumenLoadingState("Analyzing", message: "Reading symbols", progress: 0.42, onCancel: {})
                LumenErrorState("Couldn’t open the file", message: "It was moved or deleted.", recovery: "Choose it again.", onRetry: {})
            }
            // Side by side, the states share a top edge (no card).
            .lumenStatePlacement(.top)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top), "states", CGSize(width: 620, height: 400))
    }

    func testRows() {
        check(VStack(spacing: 2) {
            LumenListRow("main", detail: "0x100003f00", systemImage: "lumen.entryPoint", isSelected: true, monospaced: true) { LumenCount(12) }
            LumenListRow("parse_header", detail: "0x100003f40", systemImage: "lumen.pseudocode", monospaced: true)
            LumenListRow("Strings", systemImage: "text.quote", hue: .hueOrange) { LumenCount(1204) }
            LumenListRow("Disabled", systemImage: "nosign").disabled(true)
            LumenListRow("Focused", systemImage: "scope", isFocused: true, context: .sidebar)
        }.frame(width: 300).padding(12), "rows", CGSize(width: 330, height: 200))
    }

    func testWelcomePanel() {
        check(LumenWelcomePanel(appName: "MacScope", tagline: "Open a binary to start analyzing.", markSymbol: "lumen.lens",
                                markHue: .hueIndigo, actions: [
            LumenWelcomeAction("Open…", subtitle: "Browse for a binary", systemImage: "folder.fill", hue: .hueBlue,
                               shortcut: KeyboardShortcut("o", modifiers: .command)) {},
            LumenWelcomeAction("Attach to Process…", systemImage: "bolt.fill", hue: .hueOrange) {},
        ], recents: [LumenRecentItem(title: "libsystem_kernel.dylib", detail: "/usr/lib/system", systemImage: "lumen.binaryFile", hue: .hueIndigo)]),
              "welcome-panel", CGSize(width: 520, height: 520))
    }

    func testModeSwitcher() {
        check(VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(LumenModeSwitcherStyle.allCases.enumerated()), id: \.offset) { _, style in
                LumenModeSwitcher(selection: .constant(GoldenMode.graph), options: GoldenMode.allCases, style: style,
                                  title: \.rawValue, systemImage: \.glyph, hue: \.hue)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LumenTitlebarBackground()), "mode-switcher", CGSize(width: 520, height: 170))
    }

    func testPanelBarAndSidebarHeader() {
        check(VStack(alignment: .leading, spacing: 16) {
            LumenPanelBar("Debugger", systemImage: "ladybug.fill", hue: .hueRed, status: "Not attached",
                          secondary: [LumenBarAction("Breakpoints", systemImage: "lumen.breakpoint") {}],
                          primary: LumenBarAction("Attach to Process…") {})
            VStack(alignment: .leading, spacing: 10) {
                LumenSidebarHeader("Project", subtitle: "MacScope Workspace", systemImage: "square.stack.3d.up.fill", hue: .huePink)
                LumenStatsCard([LumenStat("Targets", count: 0), LumenStat("Functions", count: 1204), LumenStat("Xrefs", count: 38)])
            }
            // The panel bar's own horizontal inset (spacing.s4), so both tiles share one leading edge.
            .padding(.vertical, 12).padding(.horizontal, 8).frame(width: 260)
            // A status at a row's end, and one count cell (a million and up shows compactly).
            HStack(spacing: 16) {
                LumenStatusLabel("Ready", tone: .statusSuccess)
                LumenStatusLabel("Backend unavailable", tone: .statusDanger)
                LumenStatCell(LumenStat("Instructions", count: 12_345_678)).frame(width: 100)
            }
            .padding(.horizontal, 8)
        }.padding(12), "panel-bar", CGSize(width: 620, height: 270))
    }

    func testAddressFieldAndEmptyHero() {
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                LumenAddressField(text: .constant("100000f50"), prompt: "100000f50", prefix: "0x",
                                  hint: "Hex address, or select an instruction.", drawsStatic: true) { _ in }
                LumenAddressField(text: .constant(""), prompt: "100000f50", prefix: "0x", hint: nil, drawsStatic: true) { _ in }
            }
            .frame(width: 260)
            LumenEmptyHero("No binary open", message: "Open a macOS executable, app bundle, framework or dylib to begin analysis.",
                           systemImage: "cpu", hue: .huePink, primary: LumenBarAction("Open Binary…") {},
                           secondary: [LumenBarAction("Open Workspace…") {}],
                           recents: [LumenRecentItem(title: "Acceptance Workspace", detail: "~/Projects/Code…acceptance1",
                                                     systemImage: "square.stack.3d.up.fill", hue: .huePink)],
                           recentsTitle: "Recent Workspaces", showsStarfield: false)
                .frame(width: 440, height: 400)
        }.padding(16), "address-hero", CGSize(width: 760, height: 432))
    }

    func testToolbarGroupsAndEmptyInspector() {
        check(HStack(alignment: .top, spacing: 16) {
            HStack(spacing: 10) {
                LumenNavigationButtons(canGoBack: true, canGoForward: false, back: {}, forward: {})
                LumenToolbarGroup {
                    ForEach(["folder.badge.plus", "sparkles", "location", "tablecells"], id: \.self) { icon in
                        Button(icon, systemImage: icon) {}.labelStyle(.iconOnly).buttonStyle(LumenToolbarIconButtonStyle())
                    }
                }
            }
            .padding(10).background(LumenTitlebarBackground())
            LumenInspector(scrolls: false) { Text("Sections") }
                .lumenInspectorEmptyState(true, message: "Select an instruction to see its bytes, function, data and cross-references.")
                .frame(width: 240, height: 260)
        }.padding(12), "toolbar-groups", CGSize(width: 640, height: 290))
    }

    func testCountSectionsAndTileRail() {
        check(VStack(alignment: .leading, spacing: 10) {
            LumenSidebarSwitcher(selection: .constant("project"), items: [
                LumenSidebarItem(id: "project", title: "Project", systemImage: "square.stack.3d.up", hue: .huePink),
                LumenSidebarItem(id: "functions", title: "Functions", systemImage: "function", hue: .hueBlue),
                LumenSidebarItem(id: "strings", title: "Strings", systemImage: "text.quote", hue: .hueOrange),
                LumenSidebarItem(id: "xrefs", title: "Cross-References", systemImage: "lumen.crossReference", hue: .hueTeal),
                LumenSidebarItem(id: "debug", title: "Debugger", systemImage: "ladybug", hue: .hueRed),
            ], shortcuts: false, style: .tiles)
            LumenSidebarCountSection("Binaries", systemImage: "lumen.binaryFile", hue: .hueIndigo, count: 0,
                                     emptyMessage: "Open a binary to list it here.") { EmptyView() }
            LumenSidebarCountSection("Functions", systemImage: "lumen.pseudocode", hue: .huePink, count: 2,
                                     emptyMessage: "Appear after analysis.") {
                LumenListRow("main", systemImage: "lumen.entryPoint", context: .sidebar, monospaced: true)
                LumenListRow("parse_header", systemImage: "lumen.pseudocode", context: .sidebar, monospaced: true)
            }
        }
        .padding(12).frame(width: 280).lumenSidebarBackground(), "count-sections", CGSize(width: 300, height: 300))
    }

    func testStackAndRegisters() {
        check(HStack(alignment: .top, spacing: 16) {
            LumenStackFrameList([
                LumenStackFrame(index: 0, function: "compute(_:)", address: 0x100003f50, location: "main.swift:42"),
                LumenStackFrame(index: 1, function: "run()", address: 0x100004120, location: "main.swift:17"),
                LumenStackFrame(index: 2, function: "start", address: 0x18c2a0274, location: "dyld", isSystem: true),
            ], selection: .constant(0))
            .frame(width: 300)
            VStack(alignment: .leading, spacing: 6) {
                LumenSectionHeader("Special")
                LumenRegisterGrid([
                    LumenRegister("fp", value: "0x000000016fdff290", role: "frame"),
                    LumenRegister("sp", value: "0x000000016fdff280", role: "stack", changed: true),
                    LumenRegister("lr", value: "0x0000000100004144", role: "link"),
                    LumenRegister("pc", value: "0x0000000100003f50", role: "program", changed: true),
                ])
            }
            .frame(width: 360)
        }.padding(12), "debugger-panes", CGSize(width: 700, height: 180))
    }

    func testConsoleAndBreakpoints() {
        check(HStack(alignment: .top, spacing: 16) {
            LumenConsole(lines: [
                LumenConsoleLine(.command, "breakpoint set -n compute"),
                LumenConsoleLine(.output, "Breakpoint 1: Sample`compute(_:) + 12 at main.swift:42, a long line that wraps instead of truncating"),
                LumenConsoleLine(.stop, "Stopped: thread 1, breakpoint 1.1"),
                LumenConsoleLine(.warning, "Symbol cache is stale; reloading"),
            ], input: .constant(""), prompt: "(lldb)", placeholder: "frame variable", drawsStatic: true, onSubmit: { _ in })
            .frame(width: 320, height: 200)
            .lumenCard(padding: 0)
            VStack(alignment: .leading, spacing: 2) {
                LumenBreakpointRow(isEnabled: .constant(true), locator: "compute(_:)", scope: "Sample · main.swift:42",
                                   status: "Armed", tone: .statusSuccess, hits: 3)
                LumenBreakpointRow(isEnabled: .constant(true), locator: "-[NSView layout]", scope: "AppKit · waiting for image",
                                   status: "Pending", tone: .statusWarning)
                LumenBreakpointRow(isEnabled: .constant(false), locator: "parse_header", scope: "libparse.dylib",
                                   status: "Off", tone: .fgTertiary)
            }
            .frame(width: 320)
        }.padding(12), "console-breakpoints", CGSize(width: 690, height: 230))
    }

    func testHexDump() {
        let bytes: [UInt8] = [0xa8, 0xf2, 0xdf, 0x6f, 0x01, 0, 0, 0, 0x44, 0x41, 0, 0, 0x01, 0, 0, 0]
            + Array("Hello, MacScope!".utf8) + [0x0a, 0x09, 0x1b, 0x5b, 0x33, 0x31, 0x6d, 0]
        check(VStack(alignment: .leading, spacing: 12) {
            LumenHexDump(bytes, baseAddress: 0x16fdff280, selection: .constant(16..<21))
            LumenHexDump(Array(bytes.prefix(16)), baseAddress: 0x16fdff280, selection: .constant(nil)).frame(width: 300)
        }.padding(12), "hex-dump", CGSize(width: 640, height: 190))
    }

    func testCommandsAndWatches() {
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                LumenCommandField("expr", parts: [LumenCommandPart(.constant("x0 + 1"), prompt: "Expression")],
                                  actionTitle: "Evaluate", isEnabled: true, help: nil, drawsStatic: true) {}
                LumenEvaluationResult("2", type: "unsigned long")
                LumenCommandField("reg", parts: [LumenCommandPart(.constant("x0"), prompt: "Name", width: 40),
                                                 LumenCommandPart(.constant(""), prompt: "0x… or decimal")],
                                  actionTitle: "Write", isEnabled: false, help: nil, drawsStatic: true) {}
            }
            .frame(width: 300)
            LumenWatchList([
                LumenWatch(id: "1", expression: "count", value: "42", type: "Int"),
                LumenWatch(id: "2", expression: "header->magic", value: "0xfeedfacf", type: "uint32_t"),
                LumenWatch(id: "3", expression: "missingVar", error: "not in scope"),
                LumenWatch(id: "4", expression: "self.buffer.count"),
            ], newExpression: .constant(""), limit: 16, canEvaluate: true, caution: "Evaluating can run code.",
               drawsStatic: true, onEvaluate: {}, onAdd: { _ in }, onRemove: { _ in })
            .frame(width: 320)
        }.padding(12), "commands-watches", CGSize(width: 670, height: 190))
    }

    func testVariableTree() {
        let locals = [
            LumenVariable(id: "self", name: "self", type: "Parser", value: "0x600003a1c000", disclosure: .expanded),
            LumenVariable(id: "buffer", depth: 1, name: "buffer", type: "[UInt8]", value: "1024 elements", disclosure: .collapsed),
            LumenVariable(id: "count", depth: 1, name: "count", type: "Int", value: "42", changed: true),
            LumenVariable(id: "header", depth: 1, name: "header", type: "UnsafePointer<Header>", value: "0x16fdff2a8", disclosure: .expanded),
            LumenVariable(id: "magic", depth: 2, name: "magic", type: "UInt32", value: "0xfeedfacf"),
            LumenVariable(id: "cache", name: "cache", type: "Cache?", value: "couldn’t read memory", disclosure: .failed),
        ]
        let sections = [LumenVariableSection("Locals", variables: locals),
                        LumenVariableSection("Arguments", variables: [], emptyMessage: "No arguments.")]
        check(HStack(alignment: .top, spacing: 16) {
            LumenVariableTree(sections).frame(width: 340)
            LumenVariableTree(sections).frame(width: 220)
        }.padding(12), "variable-tree", CGSize(width: 600, height: 248))
    }

    func testSheetAndProcesses() {
        // Real fields (a stand-in card hid that a field on the sheet's raised ground must step up).
        let field = { (text: String) in LumenTextField(text: .constant(text), monospaced: true) }
        check(HStack(alignment: .top, spacing: 16) {
            LumenSheet("New Breakpoint", subtitle: "Sample · arm64", systemImage: "lumen.breakpoint", hue: .hueBlue,
                       status: LumenSheetStatus("Saved while the debugger is offline.", tone: .success), onCancel: {},
                       primary: LumenBarAction("Save") {}) {
                LumenFormSection("Location") {
                    LumenFormRow("Symbol") { field("compute(_:)") }
                }
                LumenFormSection("Behavior") {
                    LumenFormRow("Condition") { field("count > 10") }
                }
            }
            .frame(width: 340)   // its own height: a forced one left the body empty under "Behavior"
            .fixedSize(horizontal: false, vertical: true)
            .lumenCard(padding: 0)
            LumenProcessList([
                LumenProcess(pid: 4312, name: "Sample", path: "~/Projects/Sample/Build/Sample.app", user: "dev"),
                LumenProcess(pid: 811, name: "Safari", path: "/Applications/Safari.app", user: "dev", systemImage: "safari", hue: .hueTeal),
                LumenProcess(pid: 98, name: "launchd", path: "/sbin/launchd", user: "root", isPrivileged: true,
                             systemImage: "lock", hue: .hueGraphite),
            ], selection: .constant(4312))
            .frame(width: 300)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), "sheet-processes", CGSize(width: 690, height: 310))
    }

    func testGraphNodes() {
        check(VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                LumenGraphNode("Entry", detail: "0x100003f50–3f64", systemImage: "lumen.entryPoint", hue: .hueGreen, count: 6)
                LumenGraphNode("Block 2", detail: "0x100003f68–3f7c", count: 4, state: .selected)
                LumenGraphNode("Block 3", detail: "0x100003f80–3f84", count: 2, state: .currentBlock, tag: .orange)
            }
            .frame(height: 60)
            HStack(spacing: 14) {
                LumenGraphNode("Exit", detail: "0x100003f88–3f90", systemImage: "arrow.uturn.left", hue: .hueOrange, count: 3,
                               isMultiSelected: true)
                .frame(width: 128, height: 60)
                ForEach(LumenGraphEdgeKind.allCases, id: \.self) { kind in
                    HStack(spacing: 4) {
                        EdgeSwatch(kind: kind)
                        LumenGraphEdgeBadge(kind)
                        LumenGraphEdgeBadge(kind, isSelected: true)
                    }
                }
            }
        }.padding(16), "graph-nodes", CGSize(width: 440, height: 180))
    }

    func testRichSettingsRows() {
        let rows = { (width: CGFloat) in
            VStack(alignment: .leading, spacing: 12) {
                LumenSettingsHeader("Appearance", systemImage: "paintpalette", hue: .hueViolet,
                                    summary: "Theme, accent, density and the listing font.")
                LumenFormSection("Layout") {
                    LumenSettingsRow("Density", description: "Row height in lists and listings.") {
                        LumenModeSwitcher(selection: .constant("Regular"), options: ["Compact", "Regular"], style: .pill, title: { $0 })
                    }
                    LumenSettingsRow("Listing font", description: "Used for code, addresses and bytes.") {
                        // A control, in pop-up chrome, so its edges line up with the switcher's above.
                        LumenMenuButton(help: "Listing font") { Button("SF Mono 12") {}; Button("Menlo 12") {} } label: {
                            LumenPopUpLabel("SF Mono 12").fixedSize()
                        }
                    }
                }
            }
            .frame(width: width, alignment: .leading)
        }
        check(HStack(alignment: .top, spacing: 24) { rows(400); rows(230) }.padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(LumenPanelFill()),
              "settings-rich", CGSize(width: 700, height: 290))
    }

    func testListingRowsAndLanes() {
        typealias C = LumenToken.Code
        let rows: [(String, String, String, LumenListingRowState, Bool)] = [
            ("100003f50", "cbz", "x1, loc_3f80", .init(), true),
            ("100003f54", "mov", "x19, x0", .init(), false),
            ("100003f60", "add", "x19, x19, x0", .init(isProgramCounter: true, isInCurrentBlock: true), false),
            ("100003f64", "subs", "x2, x2, #1", .init(isInCurrentBlock: true), false),
            ("100003f68", "b.ne", "loc_3f60", .init(isSelected: true, isInCurrentBlock: true), false),
            ("100003f6c", "ret", "", .init(isPatched: true), false),
            ("100003f80", "mov", "x0, #-1", .init(tag: .orange), false),
        ]
        let height: CGFloat = 18
        let view = HStack(spacing: 0) {
            // The lanes draw the row bands under the gutter, so bands run the pane's full width (§8).
            LumenBranchLanes([LumenBranchLane(fromRow: 0, toRow: 6), LumenBranchLane(fromRow: 4, toRow: 2, isHighlighted: true)],
                             rowHeight: height, rowCount: rows.count, rowStates: rows.map(\.3))
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    HStack(spacing: 8) {
                        Group {
                            if row.3.isProgramCounter { LumenProgramCounterMarker() }
                            else { Color.clear }
                        }.frame(width: 14)
                        Text(row.0).foregroundStyle(Color.gray)
                        Text(row.1).fontWeight(.semibold).frame(width: 36, alignment: .leading)
                        Text(row.2)
                        Spacer()
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: height)
                    .lumenListingRow(row.3, drawsLeadingMarks: false)
                }
            }
        }
        .frame(width: 390)
        .padding(.vertical, 12)   // the bands run to the pane's trailing edge (PRINCIPLES §8)
        check(view, "listing-lanes", CGSize(width: 390, height: 155), registry: LumenRegistry(packs: [.core, .code]))
    }

    func testThemeMiniaturesWithCode() {
        let registry = LumenRegistry(packs: [.core, .code])
        let view = HStack(spacing: 12) {
            ForEach(registry.galleryThemes) { theme in
                ForEach(theme.supportedAppearances, id: \.self) { dark in
                    LumenThemeMiniature(theme: theme, registry: registry, appearance: dark ? .dark : .light)
                        .frame(width: 180)
                        .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
        .padding(12)
        check(view, "theme-miniatures-code", CGSize(width: 1300, height: 130), only: [variants[0]], registry: registry)
    }

    func testInspectorSummary() {
        check(HStack(alignment: .top, spacing: 16) {
            ForEach([280, 200], id: \.self) { width in
                VStack(spacing: 0) {
                    LumenInspectorSummary(kind: "Instruction", title: "0x100003f60", link: "compute(_:)", detail: "+16 · __TEXT,__text",
                                          stats: [LumenStat("callers", count: 3), LumenStat("blocks", count: 4), LumenStat("bytes", count: 64)],
                                          onOpenLink: {})
                    VStack(alignment: .leading, spacing: 2) {
                        LumenReferenceRow("main+24", kind: "call") {}
                        LumenReferenceRow("0x100004200", kind: "data") {}
                        LumenReferenceRow("-[NSViewController loadViewIfRequired]+112", kind: "call") {}
                    }
                    .padding(.horizontal, 10)   // with the rows' own 4 pt inset, text meets the card's text edge
                }
                .frame(width: CGFloat(width))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(InspectorFill()), "inspector-summary", CGSize(width: 520, height: 270))
    }

    func testStringsNavigator() {
        let view = VStack(alignment: .leading, spacing: 8) {
            LumenModeSwitcher(selection: .constant("All"), options: ["All", "C", "CF", "ObjC"], style: .pill, title: { $0 })
            VStack(spacing: 2) {
                LumenStringRow("Hello, MacScope!", address: 0x100008000, section: "__cstring", length: 16)
                LumenStringRow("%s: invalid header (%d)\\n", address: 0x100008011, section: "__cstring", length: 24, isSelected: true)
                LumenStringRow("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", address: 0x10000802a,
                               section: "__cstring", length: 61)
            }
            LumenSidebarCountSection("compute(_:)", systemImage: "function", hue: .huePink, count: 2, emptyMessage: "") {
                LumenReferenceRow("main+24", kind: "call") {}
                LumenReferenceRow("0x100004200", kind: "data") {}
            }
        }
        .padding(12).frame(width: 260).frame(maxHeight: .infinity, alignment: .top).lumenSidebarBackground()
        check(view, "strings-navigator", CGSize(width: 260, height: 300), registry: LumenRegistry(packs: [.core, .code]))
    }

    func testSplitEditorAndStackedSidebar() {
        let layout = LumenEditorLayout(panes: [
            LumenEditorPane(id: "L", tabs: [
                LumenDocumentTab(id: "pkg", title: "Package.swift", systemImage: "shippingbox", hue: .hueOrange, isPinned: true),
                LumenDocumentTab(id: "listing", title: "Listing.swift", systemImage: "swift", hue: .hueOrange, isEdited: true),
            ], selection: "listing"),
            LumenEditorPane(id: "R", tabs: [
                LumenDocumentTab(id: "zsh", title: "zsh", systemImage: "terminal", hue: .hueTeal, isPinned: false, accent: .hueTeal),
            ]),
        ], focusedPaneID: "L")
        let editor = LumenSplitEditor(layout: .constant(layout), minimumPaneWidth: 180) { pane in
            EditorStandIn(title: pane.selection ?? "")
        }
        .frame(width: 640, height: 150)
        let m = LumenMetrics.standard
        let titleInset = m.spacing.s3 + m.layout.tileSection + m.spacing.s2   // LumenStackedSidebar's header: inset, tile, gap
        let sidebar = LumenStackedSidebar([
            LumenStackedPane(id: "fn", title: "Functions", systemImage: "function", hue: .huePink, count: 3,
                             actions: [LumenBarAction("Add", systemImage: "plus") {}]) {
                VStack(alignment: .leading, spacing: 3) { Text("main"); Text("parse_header"); Text("compute(_:)") }.font(.caption)
                    .padding(.leading, titleInset)   // the pane header's title inset
            },
            LumenStackedPane(id: "bp", title: "Breakpoints", systemImage: "lumen.breakpoint", hue: .hueBlue, count: 0,
                             emptyMessage: "Click a line number to add one.") { EmptyView() },
            LumenStackedPane(id: "str", title: "Strings", systemImage: "text.quote", hue: .hueOrange, count: 1284) { EmptyView() },
        ], collapsed: .constant(["str"]))
        .frame(width: 220, height: 230)
        .lumenSidebarBackground()
        check(HStack(alignment: .top, spacing: 16) { editor; sidebar }.padding(12), "workspace-splits", CGSize(width: 910, height: 260))
    }

    func testNavigation() {
        let scopes = [LumenPaletteScope("All", prefix: nil), LumenPaletteScope("Files", prefix: "/"),
                      LumenPaletteScope("Symbols", prefix: "#"), LumenPaletteScope("Commands", prefix: ">")]
        let commands = [
            LumenCommand("compute(_:)", category: "Function", systemImage: "function", hue: .huePink, scope: "Symbols",
                         detail: "Sources/LumenUI/LumenDebugger.swift") {},
            LumenCommand("computeHash(_:)", category: "Function", systemImage: "function", hue: .huePink, scope: "Symbols",
                         detail: "Sources/Hash.swift") {},
            LumenCommand("Toggle Panel", category: "View", systemImage: "rectangle.bottomthird.inset.filled") {},
        ]
        let files = [
            LumenSearchFile(id: "dbg", name: "LumenDebugger.swift", systemImage: "swift", hue: .hueOrange, matches: [
                LumenSearchMatch(line: 13, text: "public struct LumenStat: Identifiable", ranges: [14..<23]),
                LumenSearchMatch(line: 42, text: "let stats: [LumenStat] = []", ranges: [12..<21]),
            ]),
            LumenSearchFile(id: "log", name: "CHANGELOG.md", systemImage: "doc.text", hue: .hueBlue, matches: [
                LumenSearchMatch(line: 7, text: "- `LumenStat`, `LumenStatsCard`", ranges: [3..<12, 16..<25]),
            ]),
        ]
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                LumenCommandPalette(commands, scopes: scopes, query: "#comp", recents: [], highlighted: "Function.compute(_:)")
                LumenInputPalette("Go to Line", systemImage: "number", hue: .hueGraphite,
                                  help: "Enter a line number (“12”) or a line and column (“12:30”).", text: "", drawsStatic: true,
                                  isValid: { _ in true }, onSubmit: { _ in }, onDismiss: {})
            }
            VStack(alignment: .leading, spacing: 0) {
                LumenFindPanel(query: .constant(LumenFindQuery(pattern: "LumenStat")), scope: .constant("In Project"),
                               scopes: ["In Project", "Open Files"], scopeTitle: { $0 }, drawsStatic: true, onFind: {}, onReplaceAll: {})
                LumenSearchResults(files, collapsed: .constant(["log"])) { _, _ in }
            }
            .frame(width: 300).lumenSidebarBackground()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), "navigation", CGSize(width: 930, height: 440))
    }

    func testForms() {
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                LumenSettingsRow("Line height", description: "A multiple of the font size.") {
                    LumenNumberField(value: .constant(1.5), in: 1...3, step: 0.1, fractionDigits: 1, unit: "× font size")
                }
                .environment(\.lumenSettingsQuery, "height")
                LumenSentenceRow(isOn: .constant(true), label: "Limit uploads") {
                    LumenSentenceText("Limit uploads to")
                    LumenNumberField(value: .constant(500), in: 0...10_000, unit: "KB/s")
                }
                LumenSentenceRow(isOn: .constant(false), label: "Play a sound") {
                    LumenSentenceText("Play")
                    LumenInheritedPicker(selection: .constant(nil), options: ["Glass", "Sosumi"], inherited: "Sosumi", title: { $0 })
                    LumenSentenceText("when a build finishes")
                }
                LumenCheckboxGrid([
                    LumenCheckboxItem("Line numbers", isOn: .constant(true)), LumenCheckboxItem("Minimap", isOn: .constant(false)),
                    LumenCheckboxItem("Code folding", isOn: .constant(true)), LumenCheckboxItem("Invisibles", isOn: .constant(false)),
                ])
                LumenDependentGroup(enabled: false) {
                    LumenSentenceRow { LumenSentenceText("Hanging indent"); LumenNumberField(value: .constant(4), in: 0...16, unit: "spaces") }
                }
            }
            .frame(width: 360)
            VStack(alignment: .leading, spacing: 12) {
                LumenSettingsCard {
                    LumenIntegrationRow(isOn: .constant(true), name: "SourceKit-LSP", detail: "/usr/bin/sourcekit-lsp", status: .running,
                                        onRefresh: {}, onInfo: {})
                    LumenIntegrationRow(isOn: .constant(false), name: "SuperHTML", status: .notFound, onRefresh: {}, onInfo: {})
                }
                LumenListEditor(items: .constant(["*.generated.swift", "Build/**"]), addPrompt: "Add pattern", monospaced: true, minHeight: 80)
                LumenMasterDetail([LumenMasterSection("Build", items: [LumenMasterItem(id: "starts", title: "Starts"),
                                                                       LumenMasterItem(id: "fails", title: "Fails", isConfigured: true)])],
                                  selection: .constant("fails"), listWidth: 140) { item in
                    Text("When a build \(item.title.lowercased())…").font(.callout)
                }
                .frame(height: 90)
            }
            .frame(width: 400)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(InspectorFill()), "forms", CGSize(width: 810, height: 380))
    }

    func testDataViews() {
        let notice = LumenNotice(source: "Extension: Git Hosting", title: "Remote repository detected",
                                 message: "Connect sample/Lumen to show issues and pull requests?", systemImage: "arrow.triangle.branch",
                                 primary: LumenBarAction("Connect") {}, secondary: LumenBarAction("Not Now") {})
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                LumenNoticeCard(notice) {}
                LumenOutlineControls(mode: .constant(.tree), depth: .constant(2), sortsAlphabetically: .constant(false))
                    .frame(width: 300).lumenSidebarBackground()
                LumenComparisonHeader(leading: LumenComparisonSide("Current Version", tone: .hueBlue,
                                                                   choices: [LumenBarAction("Latest Commit") {}]),
                                      trailing: LumenComparisonSide("Latest Commit", tone: .hueOrange), detail: "Consistency cleanup")
                    .frame(width: 400)
                LumenDiffNavigator(status: "2 of 5", ignoresWhitespace: .constant(false), onPrevious: {}, onNext: {})
            }
            VStack(spacing: 0) {
                LumenHistoryRow(message: "Consistency cleanup: code font fallbacks", hash: "a1f5083",
                                refs: [("HEAD", .head), ("main", .branch), ("origin/main", .remote)], time: "14m", author: "avery",
                                isFirst: true)
                LumenHistoryRow(message: "Catalog Editor page", hash: "7ec64f9", refs: [("v0.27.0", .tag)], time: "28m", author: "avery",
                                isSelected: true)
                LumenHistoryRow(message: "Strings navigator rows", hash: "7c42c22", time: "32m", author: "Robin", isLast: true)
            }
            .frame(width: 330).lumenSidebarBackground()
            LumenMinimap(lineLengths: (0..<60).map { [40, 12, 66, 30, 0, 52, 24, 70][$0 % 8] },
                         lineTokens: (0..<60).map { [LumenToken.hueBlue, .fgSecondary, .huePink, .hueGreen][$0 % 4] },
                         viewport: .constant(0.25...0.5))
                .frame(height: 200)
        }.padding(14), "data-views", CGSize(width: 900, height: 300))
    }

    func testToolsBatch() {
        let panes = [
            LumenSidebarItem(id: "files", title: "Files", systemImage: "folder", hue: .hueBlue),
            LumenSidebarItem(id: "find", title: "Find", systemImage: "magnifyingglass", hue: .hueOrange),
            LumenSidebarItem(id: "symbols", title: "Symbols", systemImage: "list.bullet.indent", hue: .huePink),
            LumenSidebarItem(id: "git", title: "Git", systemImage: "arrow.triangle.branch", hue: .hueGreen),
        ]
        let items = [
            LumenCollectionItem(id: "lumen", title: "Lumen", detail: "~/Projects/Lumen", systemImage: "lumen.lens", hue: .hueViolet),
            LumenCollectionItem(id: "macscope", title: "MacScope", detail: "~/Projects/MacScope", systemImage: "scope", hue: .hueBlue, group: "Apps"),
            LumenCollectionItem(id: "archiver", title: "Image Archiver", detail: "~/Projects/ImageArchiver", systemImage: "cross.case", hue: .hueTeal, group: "Apps"),
        ]
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                LumenSidebarPaneGrid(panes, arrangement: .constant("files,find,-symbols,git")).frame(width: 260).lumenSidebarBackground()
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Toggle Panel").font(.callout); Spacer()
                        LumenShortcutRecorder(shortcut: .constant(KeyboardShortcut("y", modifiers: [.command, .shift]))) }
                    HStack { Text("Go to Line…").font(.callout); Spacer()
                        LumenShortcutRecorder(shortcut: .constant(nil), conflict: nil, width: 130, recording: true) }
                    HStack { Text("Jump to Selection").font(.callout); Spacer()
                        LumenShortcutRecorder(shortcut: .constant(KeyboardShortcut("l", modifiers: [.command, .option])),
                                              conflict: "Also used by Run Latest Test") }
                }
                .padding(.horizontal, LumenMetrics.standard.spacing.s3)   // the pane grid's inset: one leading edge for the column
                .frame(width: 300)
            }
            VStack(alignment: .leading, spacing: 12) {
                LumenCompletionList([
                    LumenCompletion("AnyClass", detail: "any AnyObject.Type", kind: .type),
                    LumenCompletion("AnyCollection", detail: "AnyCollection<Element>", kind: .structure),
                    LumenCompletion("anyMatches(_:)", detail: "(String) -> Bool", kind: .function),
                ], typed: "Any", selection: .constant("AnyCollection")) { _ in }
                .frame(width: 320)
                LumenCollection(items, mode: .list, selection: .constant("macscope"), sort: .constant(.title)) { _ in }
                    .frame(width: 400)
                LumenCollection(items, mode: .grid, size: 90, selection: .constant("lumen"), sort: .constant(.title)) { _ in }
                    .frame(width: 400)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(InspectorFill()), "tools", CGSize(width: 760, height: 520))
    }

    func testControls() {
        struct Binding2: Identifiable { let id: String; let key: String; let action: String }
        let rows = [Binding2(id: "1", key: "⌥F1", action: "\\033[17~"), Binding2(id: "2", key: "⌥F2", action: "\\033[18~"),
                    Binding2(id: "3", key: "⌥F3", action: "\\033[19~")]
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                LumenTabbedBox(selection: .constant("Display"), tabs: ["Display", "Editing", "Indentation", "Vim"], title: { $0 }) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Line numbers", isOn: .constant(true)).toggleStyle(.lumenCheckbox)
                        Toggle("Minimap", isOn: .constant(false)).toggleStyle(.lumenCheckbox)
                    }
                }
                LumenRadioGroup(selection: .constant("Only"), options: ["Always", "Never", "Only"],
                                title: { $0 == "Only" ? "Only if there are processes other than:" : $0 }) { option in
                    if option == "Only" { LumenTableText("rlogin, telnet, ssh", monospaced: true) }
                }
            }
            .frame(width: 360)
            VStack(alignment: .leading, spacing: 16) {
                LumenTable(rows, selection: .constant("2"), footer: LumenTableFooter(onAdd: {}, onRemove: {}, onEdit: {}, trailing: ("Restore Defaults", {})),
                           minHeight: 0, columns: [.text("Key", width: 70) { $0.key }, .text("Action", monospaced: true) { $0.action }])
                LumenTable([Binding2](), selection: .constant(nil), emptyMessage: "No environment variables",
                           footer: LumenTableFooter(onAdd: {}, onRemove: {}), minHeight: 44,
                           columns: [.text("Name") { $0.key }, .text("Value") { $0.action }])
            }
            .frame(width: 340)
        }
        .padding(16), "controls", CGSize(width: 760, height: 330))
    }

    func testEditors() {
        let entries = [LumenKeyValue(key: "format.enable", value: "true", type: .boolean),
                       LumenKeyValue(key: "suggest.maxItems", value: "40", type: .number),
                       LumenKeyValue(key: "html.customData", value: "./data.json", type: .string)]
        let conditions = [LumenRuleCondition(field: "Name", comparison: "is", value: ".svn"),
                          LumenRuleCondition(field: "Size", comparison: "greater than", value: "10 MB")]
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                LumenKeyValueEditor(entries: .constant(entries), typed: true, emptyMessage: "No values", selection: entries[1].id)
                LumenKeyValueEditor(entries: .constant([]), emptyMessage: "No environment variables")
            }
            .frame(width: 400)
            VStack(alignment: .leading, spacing: 18) {
                LumenRuleEditor(match: .constant(.any), conditions: .constant(conditions), fields: ["Name", "Size"],
                                comparisons: { $0 == "Size" ? ["greater than", "less than"] : ["is", "contains"] })
                LumenSlider(value: .constant(45), in: 0...120, step: 15, ticks: 9, endLabels: ("Off", "120"), showsField: true, unit: "sec")
                LumenSlider(value: .constant(0.3), in: 0...1)
                LumenComboField(text: .constant("xterm-256color"), suggestions: ["vt100", "xterm", "xterm-256color"], monospaced: true)
                    .frame(width: 220)
                HStack(spacing: 10) {
                    LumenPullDownButton("Add", systemImage: "plus") { Button("Generate Key…") {} }
                    LumenPullDownButton("Actions", systemImage: "ellipsis.circle") { Button("Import…") {} }
                    LumenPullDownButton("Server Actions", systemImage: "gearshape") { Button("Edit…") {} }
                }
            }
            .frame(width: 400)
        }
        .padding(16), "editors", CGSize(width: 850, height: 330))
    }

    func testPickers() {
        let ansi: [[Color]] = [[.black, Color(white: 0.33)], [Color(red: 1, green: 0.27, blue: 0.27), Color(red: 1, green: 0.45, blue: 0.38)],
                               [Color(red: 0.15, green: 0.76, blue: 0.12), Color(red: 0.44, green: 0.8, blue: 0.34)]]
        let services = [LumenWizardChoice(id: "gh", title: "Hosting A", systemImage: "chevron.left.forwardslash.chevron.right", hue: .hueGraphite),
                        LumenWizardChoice(id: "gl", title: "Hosting B", detail: "Cloud or self-managed", systemImage: "flame", hue: .hueOrange)]
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LumenColorGrid(rows: ["Black", "Red", "Green"], columns: ["Normal", "Bright"]) { row, column in .constant(ansi[row][column]) }
                HStack(spacing: 8) {
                    LumenSwatchStrip([.red, .orange, .yellow, .green, .blue, .purple])
                    Text("Rainbow").font(.callout)
                    LumenIconPicker(selection: .constant("server"), choices: [LumenIconChoice(id: "server", systemImage: "server.rack", hue: .hueGreen)], size: 32)
                }
                LumenPermissionsGrid(mode: .constant(0o644))
                LumenSettingsCard {
                    LumenSettingsRow("Trim trailing whitespace", badge: ("checkmark.seal", "Set by .editorconfig")) { Text("Default (Don’t Trim)").font(.callout) }
                }
            }
            .frame(width: 340)
            VStack(alignment: .leading, spacing: 14) {
                LumenWizardStep("Add a Service Account", choices: services, selection: .constant("gh"), step: 1, of: 2,
                                onCancel: {}, onNext: {})
                LumenFieldList("Untitled Server", subtitle: "SSH / SFTP", systemImage: "server.rack", hue: .hueGreen) {
                    LumenFieldRow("Address", text: .constant(""), prompt: "server.com")
                    LumenFieldRow("Password", text: .constant("secret"), secure: true)
                }
                LumenManagedToolRow("HTML Language Server", version: "4.10.0", detail: "A language server for HTML.", state: .available,
                                    onInstall: {}, learnMore: LumenBarAction("Learn More…") {}) { Button("Copy URL") {} }
            }
            .frame(width: 400)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), "pickers", CGSize(width: 790, height: 560))
    }

    func testTextFields() {
        check(VStack(alignment: .leading, spacing: 10) {
            LumenTextField("Display name (empty keeps original)", text: .constant(""))
            LumenTextField("Rebase offset", text: .constant("0x1000"), monospaced: true)
            LumenTextField(text: .constant("__TEXT,__text"))
        }
        .padding(16).frame(width: 320), "text-fields", CGSize(width: 320, height: 130))
    }

    func testExtras() {
        let nodes = [
            LumenChecklistNode(id: "src", title: "Sources", systemImage: "folder", hue: .hueBlue, depth: 0),
            LumenChecklistNode(id: "a", title: "LumenExtras.swift", systemImage: "swift", hue: .hueOrange, depth: 1, status: "A", statusTone: .statusSuccess),
            LumenChecklistNode(id: "b", title: "LumenPanels.swift", systemImage: "swift", hue: .hueOrange, depth: 1, status: "M", statusTone: .statusWarning),
            LumenChecklistNode(id: "n", title: "Configuration.json", systemImage: "curlybraces", hue: .hueYellow, depth: 0, status: "?"),
        ]
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                LumenToolbarBreadcrumb(["Lumen", "main"], systemImage: "lumen.lens", hue: .hueViolet,
                                       activity: .working("Indexing Files… 16 of 92", progress: 0.17)) {}
                LumenFilterChips(selection: .constant("Conflicts"), groups: [["All"], ["Menu", "Extensions"], ["Customized", "Conflicts"]],
                                 title: { $0 }, count: { $0 == "Conflicts" ? 2 : nil })
                LumenCommitComposer(message: .constant(""), amends: .constant(false), author: "avery") {}
                    .frame(width: 320)
                LumenChecklistTree(nodes, checked: .constant(["a", "n"]), selection: .constant("b")).frame(width: 320)
                LumenFontPicker(family: .constant("Menlo"), style: .constant("Regular"), size: .constant(13), families: ["Menlo"], onOptions: {})
                LumenCodeSample(["editor ~/MyProject", "editor extras/index.html --line 740"]).frame(width: 360)
                LumenStatusRow("Installed", value: "/usr/local/bin/lumen v14.1", monospaced: true,
                               action: LumenBarAction("Reveal", systemImage: "magnifyingglass") {})
            }
            VStack(alignment: .leading, spacing: 12) {
                LumenDetailHeader("Snippets", summary: "The essential toolkit for web developers.", systemImage: "chevron.left.forwardslash.chevron.right",
                                  hue: .hueGreen, categories: ["Completions"], meta: ["Version 1.3.6", "3 years ago"],
                                  links: [LumenBarAction("Homepage", systemImage: "globe") {}, LumenBarAction("Repository", systemImage: "arrow.triangle.branch") {}],
                                  permissions: [("Read & Write Files", "pencil"), ("Network", "antenna.radiowaves.left.and.right")],
                                  primary: LumenBarAction("Uninstall") {}, onShare: {})
                    .frame(width: 440)
                LumenCarousel("Most Popular", ids: ["formatter", "tidy"]) { id in
                    if id == "formatter" {
                        LumenItemCard("Formatter", author: "Sam Ortiz", summary: "Formatting that’s fast and reliable.",
                                      systemImage: "text.alignleft", hue: .huePink, state: .available)
                    } else {
                        LumenItemCard("Tidy", author: "Lee Marsh", summary: "Formats JavaScript, CSS and HTML.",
                                      systemImage: "curlybraces", hue: .hueBlue, state: .installed)
                    }
                }
                .frame(width: 612)   // two whole cards (2 × 300 + 12)
                LumenTabOverview([
                    LumenOverviewTab(id: "a", title: "Package.swift", systemImage: "shippingbox", hue: .hueOrange, isPinned: true) { ExtrasThumb() },
                    LumenOverviewTab(id: "b", title: "LumenExtras.swift", systemImage: "swift", hue: .hueOrange) { ExtrasThumb() },
                ], selection: "b", thumbnailWidth: 150) { _ in }
                .frame(width: 440)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(InspectorFill()), "extras", CGSize(width: 1060, height: 640))
    }

    func testCodePane() {
        typealias C = LumenToken.Code
        let lines: [[LumenCodeRun]] = [
            [LumenCodeRun("int64_t", C.type), LumenCodeRun(" "), LumenCodeRun("compute", C.function), LumenCodeRun("(int64_t a1)")],
            [LumenCodeRun("{", C.punctuation)],
            [LumenCodeRun("  "), LumenCodeRun("if", C.keyword), LumenCodeRun(" ( a1 < "), LumenCodeRun("0", C.number), LumenCodeRun(" ) "),
             LumenCodeRun("// x19", C.comment)],
            [LumenCodeRun("    "), LumenCodeRun("return", C.keyword), LumenCodeRun(" "), LumenCodeRun("-1", C.number), LumenCodeRun(";")],
            [LumenCodeRun("  "), LumenCodeRun("return", C.keyword), LumenCodeRun(" a1 * "), LumenCodeRun("2", C.number), LumenCodeRun(";")],
            [LumenCodeRun("}", C.punctuation)],
        ]
        let registry = LumenRegistry(packs: [.core, .code])
        let strip = { (width: CGFloat) in
            LumenStatusStrip(status: LumenStripStatus("Ready", tone: .statusSuccess),
                             chips: [LumenStripChip("Truncated", help: "The listing was cut short.")],
                             actions: [LumenBarAction("Refresh", systemImage: "arrow.clockwise") {}]) {
                LumenModeSwitcher(selection: .constant("Native"), options: ["Native", "MacScope", "Compare"], style: .pill, title: { $0 })
            }
            .frame(width: width)
        }
        let view = VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 0) { strip(420); LumenCodeListing(lines, currentLine: 3) }.frame(width: 420).lumenCard(padding: 0)
            strip(380)   // narrow: chips fold into a menu; the switcher and the whole status word still fit
        }.padding(12)
        check(view, "code-pane", CGSize(width: 450, height: 270), registry: registry)
    }

    // MARK: States and families no other golden showed

    /// Every control family disabled beside its enabled self: checkbox (on and off), radio, switch,
    /// fields, pop-up, buttons, and a sentence row and dependent group switched off.
    func testDisabledStates() {
        let column = { (disabled: Bool) in
            VStack(alignment: .leading, spacing: 10) {
                LumenSectionHeader(disabled ? "Disabled" : "Enabled")
                HStack(spacing: 14) {
                    Toggle("Line numbers", isOn: .constant(true)).toggleStyle(.lumenCheckbox)
                    Toggle("Minimap", isOn: .constant(false)).toggleStyle(.lumenCheckbox)
                }
                LumenRadioGroup(selection: .constant("Always"), options: ["Always", "Never"], title: { $0 })
                HStack(spacing: 14) {
                    LumenSwitch(isOn: .constant(true), label: "Sync")
                    LumenSwitch(isOn: .constant(false), label: "Upload")
                }
                LumenTextField("Display name", text: .constant("libsystem_kernel"))
                HStack(spacing: 10) {
                    LumenNumberField(value: .constant(4), in: 0...16, unit: "spaces")
                    LumenPopUp(selection: .constant("arm64e"), options: ["arm64e", "x86_64"], title: { $0 })
                }
                HStack(spacing: 10) {
                    Button("Analyze") {}.buttonStyle(.lumenPrimary)
                    Button("Reveal") {}.buttonStyle(.lumenTinted)
                    Button("Clear") {}.buttonStyle(.lumenQuiet)
                }
                LumenSentenceRow(isOn: .constant(!disabled), label: "Limit uploads") {
                    LumenSentenceText("Limit uploads to")
                    LumenNumberField(value: .constant(500), in: 0...10_000, unit: "KB/s")
                }
                LumenDependentGroup(enabled: !disabled) {
                    LumenSentenceRow { LumenSentenceText("Hanging indent"); LumenNumberField(value: .constant(4), in: 0...16, unit: "spaces") }
                }
            }
            .frame(width: 330, alignment: .leading)
            .disabled(disabled)
        }
        check(HStack(alignment: .top, spacing: 24) { column(false); column(true) }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
              "disabled-states", CGSize(width: 740, height: 344))
    }

    /// The selection families side by side (PRINCIPLES' family table): a navigation list (quiet
    /// bg.selected), a menu, a completion list, a master-detail list and history (filled
    /// accent.filled with white), modes and tools (the plate), and code rows (band and bar).
    func testSelectionFamilies() {
        typealias C = LumenToken.Code
        let menu: [LumenMenuEntry] = [
            .item("Go to Address…", systemImage: "number", hue: .hueBlue),
            .item("Find in Project", systemImage: "magnifyingglass", hue: .hueTeal),
            .item("Show Inspector", systemImage: "sidebar.right", hue: .hueViolet),
        ]
        let family = { (title: String, content: AnyView) in
            VStack(alignment: .leading, spacing: 6) { LumenSectionHeader(title); content }.frame(width: 270, alignment: .topLeading)
        }
        check(HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                family("Navigation", AnyView(VStack(spacing: 2) {
                    LumenListRow("Functions", systemImage: "function", hue: .hueBlue, isSelected: true, context: .sidebar) { LumenCount(1204) }
                    LumenListRow("Strings", systemImage: "text.quote", hue: .hueOrange, context: .sidebar) { LumenCount(88) }
                }.padding(6).lumenSidebarBackground()))
                family("Menu", AnyView(LumenCommandMenu(menu, width: 270, highlighted: 1, openSubmenu: nil)))
                family("Completion", AnyView(LumenCompletionList([
                    LumenCompletion("AnyClass", detail: "any AnyObject.Type", kind: .type),
                    LumenCompletion("AnyCollection", detail: "AnyCollection<Element>", kind: .structure),
                ], typed: "Any", selection: .constant("AnyCollection")) { _ in }))
            }
            VStack(alignment: .leading, spacing: 16) {
                family("Master-detail", AnyView(LumenMasterDetail([LumenMasterSection("Build", items: [
                    LumenMasterItem(id: "starts", title: "Starts"), LumenMasterItem(id: "fails", title: "Fails", isConfigured: true)])],
                    selection: .constant("fails"), listWidth: 120) { item in Text("When a build \(item.title.lowercased())…").font(.callout) }
                    .frame(height: 80)))
                family("History", AnyView(VStack(spacing: 0) {
                    LumenHistoryRow(message: "Consistency cleanup", hash: "a1f5083", time: "14m", author: "avery", isFirst: true)
                    LumenHistoryRow(message: "Catalog Editor page", hash: "7ec64f9", time: "28m", author: "avery", isLast: true, isSelected: true)
                }.lumenSidebarBackground()))
            }
            VStack(alignment: .leading, spacing: 16) {
                family("Modes", AnyView(LumenModeSwitcher(selection: .constant(GoldenMode.graph), options: GoldenMode.allCases, style: .pill,
                                                          title: \.rawValue, systemImage: \.glyph, hue: \.hue)))
                family("Tools", AnyView(LumenSidebarSwitcher(selection: .constant("functions"), items: [
                    LumenSidebarItem(id: "project", title: "Project", systemImage: "square.stack.3d.up", hue: .huePink),
                    LumenSidebarItem(id: "functions", title: "Functions", systemImage: "function", hue: .hueBlue),
                    LumenSidebarItem(id: "strings", title: "Strings", systemImage: "text.quote", hue: .hueOrange),
                ], shortcuts: false, style: .tiles).lumenSidebarBackground()))
                family("Code rows", AnyView(VStack(spacing: 0) {
                    ForEach(Array([("100003f50", "cbz", LumenListingRowState()),
                                   ("100003f54", "mov", LumenListingRowState(isSelected: true)),
                                   ("100003f58", "ret", LumenListingRowState())].enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) { Text(row.0).foregroundStyle(Color.gray); Text(row.1); Spacer() }
                            .font(.system(size: 11, design: .monospaced)).frame(height: 18).padding(.leading, 8)
                            .lumenListingRow(row.2)
                    }
                }))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
              "selection-families", CGSize(width: 880, height: 360), registry: LumenRegistry(packs: [.core, .code]))
    }

    /// A listing's selection inside the highlighted current block : the selected row must
    /// read apart from the block band and the program counter, in and out of the block.
    func testListingSelectionInsideTheCurrentBlock() {
        let rows: [(String, String, LumenListingRowState)] = [
            ("100003f50", "cbz x1, loc_3f80", .init()),
            ("100003f54", "mov x19, x0", .init(isInCurrentBlock: true)),
            ("100003f58", "add x19, x19, x0", .init(isSelected: true, isInCurrentBlock: true)),
            ("100003f5c", "subs x2, x2, #1", .init(isProgramCounter: true, isInCurrentBlock: true)),
            ("100003f60", "b.ne loc_3f54", .init(isSelected: true, isProgramCounter: true, isInCurrentBlock: true)),
            ("100003f64", "ret", .init(isInCurrentBlock: true)),
            ("100003f80", "mov x0, #-1", .init(isSelected: true)),
            ("100003f84", "ret", .init(isProgramCounter: true)),
        ]
        let view = VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(spacing: 8) {
                    Group {
                        if row.2.isProgramCounter { LumenProgramCounterMarker() } else { Color.clear }
                    }.frame(width: 14)
                    Text(row.0).foregroundStyle(Color.gray)
                    Text(row.1)
                    Spacer()
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 18)
                .lumenListingRow(row.2)
            }
        }
        .frame(width: 360)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        check(view, "listing-selection-block", CGSize(width: 360, height: 170), registry: LumenRegistry(packs: [.core, .code]))
    }

    /// An empty table beside a populated one at one width: the header must be the same height and
    /// its hairline in the same place (a 22 pt phantom band).
    /// CODE-11: a long value beside a short one. Live, the columns share the width by their natural
    /// widths, so the long value shows whole; the one-pass image renderer could only split them
    /// equally and truncate it. Drawn in a window (`windowRendered`), the golden shows the live layout.
    func testTableLiveWidths() {
        struct Item: Identifiable { let id: Int; let name: String; let value: String }
        let rows = [Item(id: 1, name: "PATH", value: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"),
                    Item(id: 2, name: "TERM", value: "xterm-256color")]
        check(LumenTable(rows, selection: .constant(1), columns: [.text("Name") { $0.name }, .text("Value", monospaced: true) { $0.value }])
                .padding(12),
              "table-live-widths", CGSize(width: 520, height: 176))
    }

    func testTableHeadersEmptyAndPopulated() {
        struct Row: Identifiable { let id: String; let name: String; let value: String }
        let rows = [Row(id: "1", name: "TERM", value: "xterm-256color"), Row(id: "2", name: "LANG", value: "en_US.UTF-8")]
        check(HStack(alignment: .top, spacing: 16) {
            LumenTable(rows, selection: .constant(nil), footer: LumenTableFooter(onAdd: {}, onRemove: {}), minHeight: 0,
                       columns: [.text("Name", width: 80) { $0.name }, .text("Value") { $0.value }])
                .frame(width: 300)
            LumenTable([Row](), selection: .constant(nil), emptyMessage: "No environment variables",
                       footer: LumenTableFooter(onAdd: {}, onRemove: {}), minHeight: 44,
                       columns: [.text("Name", width: 80) { $0.name }, .text("Value") { $0.value }])
                .frame(width: 300)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), "table-headers", CGSize(width: 648, height: 180))
    }

    /// Keycaps on raised grounds : a card on the raised ground, a shortcut recorder, a
    /// palette-like footer. A key is a well, lighter than what holds it, never a hole.
    func testKeycapsOnRaisedGrounds() {
        check(HStack(alignment: .top, spacing: 16) {
            HStack(spacing: 10) {
                LumenKeycap(KeyboardShortcut("k", modifiers: [.command]))
                LumenKeycap(["⌃", "Space"])
                Text("Open the palette").font(.callout)
            }
            .padding(12)
            .lumenCard()
            .lumenRaisedGround()
            LumenShortcutRecorder(shortcut: .constant(KeyboardShortcut("y", modifiers: [.command, .shift])))
            HStack(spacing: 6) {
                LumenKeycap(["↑"]); LumenKeycap(["↓"]); Text("to move").font(.caption)
                LumenKeycap(["↩"]); Text("to open").font(.caption)
            }
            .padding(10)
            .lumenCard()
            .lumenRaisedGround()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), "keycaps-raised", CGSize(width: 700, height: 100))
    }

    /// Hover states, forced (`lumenHoverForced`): renders unhovered until each component reads
    /// `lumenForcedHover` (see LumenForcedHover.swift).
    func testHoverStates() {
        check(VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 2) {
                LumenListRow("parse_header", detail: "0x100003f40", systemImage: "lumen.pseudocode", monospaced: true)
                LumenListRow("Strings", systemImage: "text.quote", hue: .hueOrange, context: .sidebar) { LumenCount(88) }
            }
            .frame(width: 300)
            LumenDocumentTabBar([
                LumenDocumentTab(id: "a", title: "index.html", systemImage: "globe", hue: .hueGreen),
                LumenDocumentTab(id: "b", title: "Listing.swift", systemImage: "swift", hue: .hueOrange),
            ], selection: .constant("a"))
            HStack(spacing: 10) {
                Button("Clear") {}.buttonStyle(.lumenQuiet)
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") {}
                    .labelStyle(.iconOnly).buttonStyle(LumenToolbarIconButtonStyle())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .lumenHoverForced(), "hover-states", CGSize(width: 420, height: 190))
    }

    /// The unified top bar as the window toolbar hosts it: the leading groups, the status and the
    /// trailing panels, each in its compact toolbar form, past the window buttons' inset, on the
    /// title bar glow. (The real toolbar can't render offscreen; the live-window test checks it.)
    func testUnifiedTopBar() {
        let bar = { (activity: LumenActivity) in
            HStack(spacing: 0) {
                Color.clear.frame(width: LumenLayout.windowButtonsInset)
                HStack(spacing: 8) {
                    LumenWorkspaceToolbar {
                        LumenIconTile("lumen.lens", hue: .huePink, size: 20)
                    } project: {
                        LumenToolbarIdentity("libsystem_kernel.dylib", subtitle: "arm64e · Mach-O dylib", systemImage: "lumen.binaryFile", hue: .hueOrange)
                    } tasks: {
                        LumenTaskCluster([
                            LumenTaskAction("Analyze", systemImage: "hammer.fill", hue: .hueOrange) {},
                            LumenTaskAction("Launch", systemImage: "play.fill", role: .start) {},
                            LumenTaskAction("Stop", systemImage: "stop.fill", role: .stop) {},
                        ], activity: activity)
                    }
                    LumenToolbarStatus(activity, width: 260).environment(\.lumenToolbarStatusRoom, 320)
                }
                .fixedSize()
                .environment(\.lumenToolbarCompact, true)
                Spacer(minLength: 8)
                LumenPanelToggles(leading: .constant(true), bottom: .constant(true), trailing: .constant(true), registersShortcuts: false)
                    .padding(.trailing, 12)
            }
            .frame(height: 40)
            .background(LumenTitlebarBackground())
        }
        check(VStack(spacing: 12) {
            bar(.working("Analyzing libsystem_kernel.dylib", progress: 0.42))
            bar(.idle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top), "unified-top-bar", CGSize(width: 1100, height: 92))
    }
}

private enum GoldenMode: String, CaseIterable {
    case disassembly = "Disassembly", pseudocode = "Pseudocode", graph = "Graph", hex = "Hex"
    var glyph: String { [.disassembly: "lumen.disassembly", .pseudocode: "lumen.pseudocode", .graph: "lumen.callGraph", .hex: "number"][self]! }
    var hue: LumenToken { [.disassembly: .hueIndigo, .pseudocode: .huePink, .graph: .hueTeal, .hex: .hueOrange][self]! }
}

/// A short stroke in an edge kind's color and dash, read from the snapshot's palette.
private struct EdgeSwatch: View {
    let kind: LumenGraphEdgeKind
    @Environment(\.lumenPalette) private var palette
    var body: some View {
        Path { $0.move(to: CGPoint(x: 0, y: 1)); $0.addLine(to: CGPoint(x: 18, y: 1)) }
            .stroke(palette[kind.token], style: StrokeStyle(lineWidth: kind.lineWidth(isSelected: false), dash: kind.dash))
            .frame(width: 18, height: 2)
    }
}

/// The settings panel color, read from the snapshot's palette.
private struct LumenPanelFill: View {
    @Environment(\.lumenPalette) private var palette
    var body: some View { palette[.panelBackground] }
}

/// The inspector panel color, read from the snapshot's palette.
private struct InspectorFill: View {
    @Environment(\.lumenPalette) private var palette
    var body: some View { palette[.inspectorBackground] }
}

/// A stand-in editor for golden images: the selected tab's name on lines of fake code.
private struct EditorStandIn: View {
    let title: String
    @Environment(\.lumenPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette[.fgPrimary])
            ForEach([120, 80, 150, 60], id: \.self) { width in
                RoundedRectangle(cornerRadius: 2).fill(palette[.fgTertiary].opacity(0.5)).frame(width: CGFloat(width), height: 6)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(palette[.bgCanvas])
    }
}

/// A tiny editor stand-in for tab overview thumbnails.
private struct ExtrasThumb: View {
    @Environment(\.lumenPalette) private var palette
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach([90, 60, 110, 40, 80], id: \.self) { width in
                RoundedRectangle(cornerRadius: 2).fill(palette[.fgTertiary].opacity(0.5)).frame(width: CGFloat(width), height: 5)
            }
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(palette[.bgCanvas])
    }
}
