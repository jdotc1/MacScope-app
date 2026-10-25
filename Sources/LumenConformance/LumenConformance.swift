import AppKit
import LumenTokens
import LumenUI
import SwiftUI

/// Checks an app runs in its own tests at every Lumen pin bump, so a release that would break it
/// says so in the app's test run rather than on screen. Each check returns findings; an empty list
/// passes:
///
/// ```swift
/// XCTAssertEqual(LumenConformance.themes(in: AppTheme.registry).map(\.description), [])
/// ```
///
/// Known exceptions are listed by exact message (`allowing:`), so anything new still fails.
public enum LumenConformance {
    /// One thing that doesn't conform.
    public struct Finding: Hashable, Sendable, CustomStringConvertible {
        public enum Area: String, Sendable { case theme, layout, shortcut, coverage }
        public let area: Area
        /// What it's about: a theme name, a column, a shortcut owner, a color key.
        public let subject: String
        public let message: String

        public init(_ area: Area, _ subject: String, _ message: String) {
            self.area = area
            self.subject = subject
            self.message = message
        }

        public var description: String { "\(area.rawValue) · \(subject): \(message)" }
    }

    // MARK: Themes

    /// Every theme passes the validator: errors and warnings, in every appearance it declares. A
    /// theme that `inherits` is checked flattened (its parent among `themes` or the registry's
    /// built-ins); one whose chain doesn't resolve, or that declares no appearance at all, is a
    /// finding rather than a vacuous pass.
    /// - Parameters:
    ///   - themes: the themes to check; by default every built-in the registry holds, hidden ones too
    ///     (an app's users can still inherit them).
    ///   - allowing: known issues by theme name, as `"<appearance>: <message>"`.
    public static func themes(in registry: LumenRegistry, themes: [LumenTheme]? = nil,
                              allowing known: [String: [String]] = [:]) -> [Finding] {
        let supplied = Dictionary((themes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (themes ?? registry.builtInThemes).flatMap { unflattened -> [Finding] in
            let theme: LumenTheme
            do {
                theme = try unflattened.flattened { supplied[$0] ?? registry.theme(id: $0) }
            } catch {
                return [Finding(.theme, unflattened.name, "it \(error)")]
            }
            guard !theme.supportedAppearances.isEmpty else {
                return [Finding(.theme, theme.name, "declares no light or dark palette, so there is nothing to check")]
            }
            let allowed = Set(known[theme.name] ?? [])
            var findings = LumenValidator.issues(for: theme, in: registry)
                .map { "\($0.appearance): \($0.message)" }
                .filter { !allowed.contains($0) }
                .map { Finding(.theme, theme.name, $0) }
            for (isDark, token) in theme.missingTokens(in: registry) {
                findings.append(Finding(.theme, theme.name, "\(isDark ? "dark" : "light") leaves \(token.rawValue) undefined"))
            }
            return findings
        }
    }

    // MARK: Layout

    /// One column of a window: its declared minimum width and a view that stands for its widest
    /// content (each page of a detail column, say).
    public struct Column {
        public let name: String
        public let minWidth: CGFloat
        let contents: [(String, AnyView)]

        public init<Content: View>(_ name: String, minWidth: CGFloat, @ViewBuilder content: () -> Content) {
            self.name = name
            self.minWidth = minWidth
            contents = [(name, AnyView(content()))]
        }

        /// A column that shows one of several views (pages, tabs); each must fit.
        public init(_ name: String, minWidth: CGFloat, contents: [(name: String, view: AnyView)]) {
            self.name = name
            self.minWidth = minWidth
            self.contents = contents.map { ($0.name, $0.view) }
        }
    }

    /// PRINCIPLES §6: nothing is ever cut off. Each column's content fits its minimum, and the
    /// window's minimum covers every column that can show at once (plus `dividers`, the split views'
    /// divider widths).
    @MainActor
    public static func layout(windowMinWidth: CGFloat, columns: [Column], dividers: CGFloat = 0) -> [Finding] {
        var findings: [Finding] = []
        for column in columns {
            for (name, view) in column.contents {
                let width = LumenLayout.minimumWidth(of: view)
                if width > column.minWidth + 0.5 {
                    findings.append(Finding(.layout, name, "needs \(Int(width.rounded(.up))) pt; its column (\(column.name)) allows \(Int(column.minWidth))"))
                }
            }
        }
        let total = columns.map(\.minWidth).reduce(dividers, +)
        if windowMinWidth + 0.5 < total {
            findings.append(Finding(.layout, "window", "minimum \(Int(windowMinWidth)) pt is under its columns' \(Int(total.rounded(.up)))"))
        }
        return findings
    }

    // MARK: Shortcuts

    /// Each shortcut has one owner, none takes a shortcut macOS reserves, and a standard command's
    /// shortcut (⌘F, ⌘S…) is used only for that command.
    /// - Parameter owners: every shortcut the app registers, with what it does: its menu commands,
    ///   toolbar controls, and Lumen's own (`LumenShortcuts.all` for the ones it keeps).
    public static func shortcuts(_ owners: [(title: String, shortcut: KeyboardShortcut)]) -> [Finding] {
        var findings: [Finding] = []
        let name = { (shortcut: KeyboardShortcut) in LumenKeycap.text(for: shortcut) }
        let grouped = Dictionary(grouping: owners) { signature($0.shortcut) }
        for (_, group) in grouped.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            findings.append(Finding(.shortcut, name(group[0].shortcut),
                                    "has \(group.count) owners: \(group.map(\.title).joined(separator: ", "))"))
        }
        let reserved = Dictionary(LumenShortcuts.systemReserved.map { (signature($0.shortcut), $0.title) }, uniquingKeysWith: { a, _ in a })
        let standard = Dictionary(LumenShortcuts.standardCommands.map { (signature($0.shortcut), $0.title) }, uniquingKeysWith: { a, _ in a })
        for owner in owners {
            let key = signature(owner.shortcut)
            if let system = reserved[key] {
                findings.append(Finding(.shortcut, owner.title, "\(name(owner.shortcut)) is macOS's \(system)"))
            } else if let command = standard[key], !owner.title.localizedCaseInsensitiveContains(command) {
                findings.append(Finding(.shortcut, owner.title, "\(name(owner.shortcut)) is every Mac app's \(command)"))
            }
        }
        return findings
    }

    // MARK: Coverage

    /// Every color key the app uses (its views, its user theme files) is a registered role, so
    /// nothing falls back to black or white.
    public static func coverage(in registry: LumenRegistry, usedKeys: [String]) -> [Finding] {
        Set(usedKeys).sorted().compactMap { key in
            registry.contains(LumenToken(key)) ? nil : Finding(.coverage, key, "isn't a registered color role")
        }
    }

    // MARK: Window

    /// The workspace window stays intact whatever the user shows or hides: at each size and each
    /// combination of panels, the top bar is there, at the top of the window, at one height. Hiding
    /// the inspector once pushed MacScope's top bar off screen; this catches that in the app's tests.
    ///
    /// A unified bar (the default) starts at the window's top edge, its content
    /// starts after the window buttons, and the buttons are centered in it. A bar under the title bar
    /// (`.underTitleBar`) starts right under the buttons' band. Either way no panel starts above the
    /// bar's bottom edge. The checks use the real window's title bar: its buttons' frames, and the
    /// band AppKit makes for the unified bar's toolbar.
    ///
    /// Build the window with `LumenWorkspaceWindow` or `.lumenTopBar`, which report their bar; a
    /// window whose bar isn't Lumen's fails here, since nothing then guards it.
    /// - Parameter window: the app's window content for a set of panels, as the app builds it.
    @MainActor
    public static func workspaceWindow<Window: View>(sizes: [CGSize] = [CGSize(width: 900, height: 560), CGSize(width: 1440, height: 900)],
                                                     panels: [LumenWorkspacePanels] = LumenWorkspacePanels.allCombinations,
                                                     window: (LumenWorkspacePanels) -> Window) -> [Finding] {
        var findings: [Finding] = []
        var reference: CGRect?
        for size in sizes {
            for state in panels {
                let subject = "\(Int(size.width))×\(Int(size.height)), " + describe(state)
                let (recorder, top) = layOut(window(state), size: size)
                for label in recorder.truncated.sorted() {
                    findings.append(Finding(.layout, subject, "“\(label)” is cut short"))
                }
                for duplicate in visibleDuplicates(recorder.visibleTexts) {
                    findings.append(Finding(.layout, subject, duplicate))
                }
                for glow in backlightEscapes(recorder) {
                    findings.append(Finding(.layout, subject, glow))
                }
                for icon in recorder.undersizedIcons.sorted() {
                    findings.append(Finding(.layout, subject, icon))
                }
                for clip in recorder.overflowing.sorted() + recorder.columnOverflowing.sorted() {
                    findings.append(Finding(.layout, subject, clip))
                }
                guard let bar = recorder.frame else {
                    findings.append(Finding(.layout, subject, "has no Lumen top bar; use LumenWorkspaceWindow or .lumenTopBar"))
                    continue
                }
                if recorder.placement == .unified {
                    // Unified: the bar is the title bar band, so it starts at the window's top edge.
                    if abs(bar.minY) > 0.5 {
                        let moved = Int(bar.minY.rounded())
                        findings.append(Finding(.layout, subject, moved > 0 ? "top bar starts \(moved) pt below the window's top" : "top bar moved \(-moved) pt up, off the top"))
                    }
                    if let buttons = recorder.windowButtons {
                        if let content = recorder.contentFrame, content.minX < buttons.maxX - 0.5,
                           content.minY < buttons.maxY, content.maxY > buttons.minY {
                            findings.append(Finding(.layout, subject, "toolbar content overlaps the window buttons"))
                        }
                        if abs(buttons.midY - bar.midY) > 1.5 {
                            findings.append(Finding(.layout, subject, "window buttons are \(Int(abs(buttons.midY - bar.midY).rounded())) pt off the top bar's center"))
                        }
                        // The rule: every item sits on the window buttons' center line.
                        for (index, item) in recorder.toolbarItems.enumerated() where abs(item.midY - buttons.midY) > 1 {
                            findings.append(Finding(.layout, subject, "toolbar item \(index + 1) is \(Int(abs(item.midY - buttons.midY).rounded())) pt off the window buttons' center line"))
                        }
                        for (index, item) in recorder.toolbarItems.enumerated() where item.minX < buttons.maxX - 0.5 {
                            findings.append(Finding(.layout, subject, "toolbar item \(index + 1) overlaps the window buttons"))
                        }
                    }
                    for name in recorder.droppedToolbarItems {
                        findings.append(Finding(.layout, subject, "toolbar item “\(name)” was dropped for lack of room"))
                    }
                    if recorder.hasToolbar == false {
                        findings.append(Finding(.layout, subject, "the unified top bar has no window toolbar to host its items"))
                    }
                } else if abs(bar.minY - top) > 0.5 {
                    let moved = Int((top - bar.minY).rounded())
                    findings.append(Finding(.layout, subject, moved > 0 ? "top bar moved \(moved) pt up, off the top" : "top bar moved \(-moved) pt down"))
                }
                if let regionTop = recorder.regionTop, regionTop < bar.maxY - 0.5 {
                    findings.append(Finding(.layout, subject, "a panel starts \(Int((bar.maxY - regionTop).rounded())) pt under the top bar"))
                }
                if bar.height < 1 {
                    findings.append(Finding(.layout, subject, "top bar has no height"))
                } else if let reference, abs(reference.height - bar.height) > 0.5 {
                    findings.append(Finding(.layout, subject, "top bar is \(Int(bar.height)) pt tall, not \(Int(reference.height))"))
                }
                if reference == nil { reference = bar }
            }
        }
        return findings
    }

    /// PRINCIPLES §6, for any pane, sheet, settings page or window: no primary label in Lumen's
    /// components is cut short at any of `sizes`, and no column is narrower than its content (which
    /// SwiftUI centers, cutting off both edges with no label shortened). Labels report themselves
    /// (`.lumenNeverTruncates`), as do Lumen's columns; an app marks its own the same way
    /// (`.lumenColumnContent`).
    @MainActor
    public static func truncation<Content: View>(sizes: [CGSize], of content: () -> Content) -> [Finding] {
        sizes.flatMap { size in
            let recorder = layOut(content(), size: size).0
            let subject = "\(Int(size.width))×\(Int(size.height))"
            return recorder.truncated.sorted().map { Finding(.layout, subject, "“\($0)” is cut short") }
                + visibleDuplicates(recorder.visibleTexts).map { Finding(.layout, subject, $0) }
                + recorder.columnOverflowing.sorted().map { Finding(.layout, subject, $0) }
        }
    }

    /// PRINCIPLES §6, for table columns and lists of one-line values: no two different `values` of
    /// one column show the same text at `width` (MacScope's members table showed "triggerAna…"
    /// twice; each passed the 8-character floor). For a column the app lays out itself;
    /// cells that report themselves (`.lumenReportsVisibleText`) are checked by `truncation` and
    /// `workspaceWindow` as rendered.
    public static func visibleDuplicates(column: String, values: [String], width: CGFloat, font: NSFont,
                                         truncation: Text.TruncationMode = .tail) -> [Finding] {
        let entries = Set(values.map {
            LumenVisibleTextEntry(column: column, text: $0, visible: LumenVisibleText.visible($0, width: width, font: font, truncation: truncation))
        })
        return visibleDuplicates(entries).map { Finding(.layout, column, $0) }
    }

    /// Groups of different texts in one column that show the same visible text, as messages.
    static func visibleDuplicates(_ entries: Set<LumenVisibleTextEntry>) -> [String] {
        var messages: [String] = []
        let byColumn = Dictionary(grouping: entries, by: \.column)
        for column in byColumn.keys.sorted() {
            let byVisible = Dictionary(grouping: byColumn[column]!, by: \.visible)
            for visible in byVisible.keys.sorted() {
                let texts = Set(byVisible[visible]!.map(\.text)).sorted()
                guard texts.count > 1 else { continue }
                messages.append("“\(column)” shows “\(visible)” for \(texts.map { "“\($0)”" }.joined(separator: ", "))")
            }
        }
        return messages
    }

    /// PRINCIPLES §7, icon scale: no icon tile is smaller than its role allows at any of `sizes`. A
    /// tile that is a whole control matches the pane's header tile (`tileTool`); a tile beside its
    /// text is at least 16 pt. Tiles report themselves; mark an app's own icon-only tiles with
    /// `.lumenIconRole(.control)`.
    @MainActor
    public static func iconScale<Content: View>(sizes: [CGSize], of content: () -> Content) -> [Finding] {
        sizes.flatMap { size in
            layOut(content(), size: size).0.undersizedIcons.sorted().map { Finding(.layout, "\(Int(size.width))×\(Int(size.height))", $0) }
        }
    }

    /// Contained backlight: at each of `sizes`, every tile backlight stays
    /// inside the strip that backlights it (`.lumenBacklightContainer`), so it never crosses that
    /// strip's hairline or edge, and no backlight shows outside such a strip (in a toolbar, where it
    /// can only be clipped into a hard-edged disc). Backlights report themselves
    /// (`.lumenBacklightExtent`).
    @MainActor
    public static func backlight<Content: View>(sizes: [CGSize], of content: () -> Content) -> [Finding] {
        sizes.flatMap { size in
            backlightEscapes(layOut(content(), size: size).0).map { Finding(.layout, "\(Int(size.width))×\(Int(size.height))", $0) }
        }
    }

    @MainActor
    private static func backlightEscapes(_ recorder: FrameRecorder) -> [String] {
        var messages: Set<String> = []
        for entry in recorder.backlights {
            guard let id = entry.containerID, let name = entry.container else {
                messages.insert("a tile backlight shows outside any backlit strip (.lumenBacklightContainer)")
                continue
            }
            guard let box = recorder.backlightContainers[id] else { continue }
            let over = [box.minX - entry.glow.minX, entry.glow.maxX - box.maxX, box.minY - entry.glow.minY, entry.glow.maxY - box.maxY].max() ?? 0
            if over > 0.5 {
                messages.insert("a tile backlight crosses the edge of “\(name)” by \(Int(over.rounded(.up))) pt")
            }
        }
        return messages.sorted()
    }

    /// PRINCIPLES §6, for fixed-height containers and columns: none clips its content at any of
    /// `sizes`. Containers report themselves (`.lumenFixedContainer`) when their content's natural
    /// height at their width exceeds the height they got, and columns (Lumen's own, and
    /// `.lumenColumnContent`) when their content is wider than they are; an app marks its own the
    /// same way.
    ///
    /// The view as a whole is checked too: content that needs more than `size` (a row of fixed-size
    /// views wider than the window, a minimum height taller than it) is centered by SwiftUI and cut
    /// off on both edges, with nothing inside reporting it, so it's measured directly.
    @MainActor
    public static func overflow<Content: View>(sizes: [CGSize], of content: () -> Content) -> [Finding] {
        sizes.flatMap { size in
            let subject = "\(Int(size.width))×\(Int(size.height))"
            let recorder = layOut(content(), size: size).0
            return rootOverflow(content(), size: size).map { Finding(.layout, subject, $0) }
                + (recorder.overflowing.sorted() + recorder.columnOverflowing.sorted()).map { Finding(.layout, subject, $0) }
        }
    }

    /// PRINCIPLES §6, narrow sizing: a split view or `NavigationSplitView` sizing its columns asks
    /// content for its height at a near-zero width, and text that wraps without truncating
    /// (`.fixedSize(horizontal: false, vertical: true)`) answers with its height wrapped a few
    /// letters per line. That height becomes a minimum: three inline empty sentences held the
    /// Catalog's Workspace window at 1325 pt, centred and clipped in a 712 pt window (0.51.1). Each
    /// subject is measured at `referenceWidth` and at 1 pt; a finding when the narrow height is more
    /// than `factor` times the reference and at least `slack` points more.
    ///
    /// Limit: both measurements propose height 0, so they return each subject's *minimum* height, the
    /// one a split view turns into the window's minimum. A view with no minimum height of its own (one
    /// that fills its pane or scrolls, as `LumenWelcomePanel` does) measures 0 at both widths and
    /// passes, rightly for this failure. Its
    /// *ideal* height isn't judged: wrapped text is tall at 1 pt in any view, so that would only flag
    /// noise. A view whose ideal height is used, inside a sheet, popover or `fixedSize` container, is
    /// checked with `overflow(sizes:of:)` at the sizes it really gets.
    /// - Parameter subjects: names and views, each as it sits in a column (sample content included).
    @MainActor
    public static func narrowSizing(_ subjects: [(name: String, view: AnyView)], referenceWidth: CGFloat = 240,
                                    factor: CGFloat = 4, slack: CGFloat = 80) -> [Finding] {
        subjects.compactMap { subject in
            let host = NSHostingController(rootView: subject.view)
            let reference = host.sizeThatFits(in: CGSize(width: referenceWidth, height: 0)).height
            let narrow = host.sizeThatFits(in: CGSize(width: 1, height: 0)).height
            guard narrow > reference * factor, narrow - reference >= slack else { return nil }
            return Finding(.layout, subject.name, "measured 1 pt wide it asks for \(Int(narrow.rounded())) pt, "
                           + "\(Int(reference.rounded())) pt at \(Int(referenceWidth)) pt: text that wraps without truncating "
                           + "needs a minimum measuring width (see LumenEmptyState.inlineMeasureWidth)")
        }
    }

    /// How far `content` overflows `size` as a whole, as messages: what it takes when offered `size`,
    /// less `size`. Containers and columns inside report their own overflow; the root has no
    /// container to report it (the app-icons golden overflowed its frame by 16 pt this way, unseen).
    @MainActor
    static func rootOverflow<Content: View>(_ content: Content, size: CGSize) -> [String] {
        let host = NSHostingController(rootView: content)
        let taken = host.sizeThatFits(in: size)
        var messages: [String] = []
        if taken.width > size.width + 0.5 {
            messages.append("the content is \(Int((taken.width - size.width).rounded(.up))) pt wider than its \(Int(size.width)) pt frame")
        }
        if taken.height > size.height + 0.5 {
            messages.append("the content is \(Int((taken.height - size.height).rounded(.up))) pt taller than its \(Int(size.height)) pt frame")
        }
        return messages
    }

    /// PRINCIPLES §8, one surface per pane: renders `pane` at each of `sizes` and reports every place
    /// inside it where two flat background colors meet at a vertical edge (a tinted gutter, an inset
    /// band). Hairlines are fine, since the same color sits on both sides. The pane is drawn in a real
    /// (offscreen) window, so AppKit-backed SwiftUI (List, Table, text views) is scanned as shipped.
    @MainActor
    public static func surfaceSteps<Content: View>(sizes: [CGSize], variant: LumenSnapshot.Variant = .init(themeID: LumenThemes.standardID, colorScheme: .dark),
                                                   registry: LumenRegistry = .core, of pane: () -> Content) -> [Finding] {
        surfaceScan(sizes: sizes, variant: variant, registry: registry, headerHeight: nil, renderer: .window, of: pane)
    }

    /// `surfaceSteps(sizes:variant:registry:of:)`, and also compares the flat background of the top
    /// `headerHeight` band (a pane's column header) with the body under it, reporting "the header's
    /// surface differs from the pane's" when they differ. Opt-in, since a full-width band of its own
    /// color is legal in general; a column header on the pane's surface is the rule.
    @MainActor
    public static func surfaceSteps<Content: View>(sizes: [CGSize], variant: LumenSnapshot.Variant = .init(themeID: LumenThemes.standardID, colorScheme: .dark),
                                                   registry: LumenRegistry = .core, headerHeight: CGFloat, of pane: () -> Content) -> [Finding] {
        surfaceScan(sizes: sizes, variant: variant, registry: registry, headerHeight: headerHeight, renderer: .window, of: pane)
    }

    /// How a surface scan draws the pane: in a real window (as shipped), or with `ImageRenderer`
    /// (which leaves AppKit-backed views out). The window is the default; the other is for tests.
    enum SurfaceRenderer { case window, imageRenderer }

    @MainActor
    static func surfaceScan<Content: View>(sizes: [CGSize], variant: LumenSnapshot.Variant, registry: LumenRegistry, headerHeight: CGFloat?,
                                           renderer: SurfaceRenderer, inspectCapture: ((NSBitmapImageRep) -> Void)? = nil, of pane: () -> Content) -> [Finding] {
        sizes.flatMap { size -> [Finding] in
            let subject = "\(Int(size.width))×\(Int(size.height))"
            var (image, unknown) = renderer == .window ? renderInWindow(pane(), size: size, variant: variant, registry: registry) : (nil, [])
            if image == nil {
                // ImageRenderer, when the window drew nothing (or was asked for).
                let (data, imageUnknown) = LumenSnapshot.render(pane(), size: size, variant: variant, registry: registry, scale: 1)
                image = data.flatMap(NSBitmapImageRep.init(data:))
                unknown.formUnion(imageUnknown)
            }
            // A token the registry doesn't know draws a last-resort color, so the scan would judge a
            // pane the app never shows. Report it rather than pass silently.
            let unknownFindings = unknown.map(\.rawValue).sorted().map {
                Finding(.layout, subject, "token “\($0)” isn't in the registry; pass the app's registry")
            }
            guard let image else { return unknownFindings + [Finding(.layout, subject, "pane didn't render")] }
            inspectCapture?(image)
            let scan = SurfaceScan(image)
            var findings = unknownFindings + scan.steps().map { Finding(.layout, subject, $0) }
            if let headerHeight, let difference = scan.headerDifference(height: Int(headerHeight.rounded())),
               difference >= SurfaceScan.headerStep {
                findings.append(Finding(.layout, subject, "the header's surface differs from the pane's (by \(Int(difference.rounded())))"))
            }
            return findings
        }
    }

    /// Use the snapshot renderer's bounded layout/display settling for native row content, at
    /// one pixel per point. A single cacheDisplay after layout can capture only the pane background.
    @MainActor
    private static func renderInWindow<Content: View>(_ pane: Content, size: CGSize, variant: LumenSnapshot.Variant,
                                                      registry: LumenRegistry) -> (NSBitmapImageRep?, Set<LumenToken>) {
        let (data, unknown) = LumenSnapshot.render(pane, size: size, variant: variant, registry: registry,
                                                  scale: 1, renderer: .window)
        guard let image = data.flatMap(NSBitmapImageRep.init(data:)), !isBlank(image) else { return (nil, unknown) }
        return (image, unknown)
    }

    /// True when every sampled pixel is fully transparent: the capture drew nothing.
    private static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                return false
            }
        }
        return true
    }

    private static func describe(_ panels: LumenWorkspacePanels) -> String {
        let shown = [panels.leading ? "sidebar" : nil, panels.bottom ? "bottom" : nil, panels.trailing ? "inspector" : nil].compactMap { $0 }
        return shown.isEmpty ? "no panels" : shown.joined(separator: " + ")
    }

    @MainActor
    private final class FrameRecorder { var frame: CGRect?; var placement: LumenTopBarPlacement?; var contentFrame: CGRect?; var windowButtons: CGRect?; var hasToolbar: Bool?; var toolbarItems: [CGRect] = []; var droppedToolbarItems: [String] = []; var regionTop: CGFloat?; var truncated: Set<String> = []; var undersizedIcons: Set<String> = []; var overflowing: Set<String> = []; var columnOverflowing: Set<String> = []; var visibleTexts: Set<LumenVisibleTextEntry> = []; var backlights: Set<LumenBacklightEntry> = []; var backlightContainers: [UUID: CGRect] = [:] }

    /// Lays the window out in a real (offscreen) window of `size` and returns where its top bar went,
    /// with where it belongs: right under the window's top safe area (the window buttons' band).
    @MainActor
    private static func measureTopBar<Content: View>(_ content: Content, size: CGSize) -> (CGRect, CGFloat, CGFloat?)? {
        let (recorder, top) = layOut(content, size: size)
        return recorder.frame.map { ($0, top, recorder.regionTop) }
    }

    /// Lays `content` out in a real (offscreen) window of `size` and records what it reports.
    @MainActor
    private static func layOut<Content: View>(_ content: Content, size: CGSize) -> (FrameRecorder, CGFloat) {
        let recorder = FrameRecorder()
        let root = content
            .onPreferenceChange(LumenTopBarFrameKey.self) { frame in MainActor.assumeIsolated { recorder.frame = frame } }
            .onPreferenceChange(LumenTopBarPlacementKey.self) { placement in MainActor.assumeIsolated { recorder.placement = placement } }
            .onPreferenceChange(LumenTopBarContentFrameKey.self) { frame in MainActor.assumeIsolated { recorder.contentFrame = frame } }
            .onPreferenceChange(LumenRegionTopKey.self) { top in MainActor.assumeIsolated { recorder.regionTop = top } }
            .onPreferenceChange(LumenTruncationKey.self) { labels in MainActor.assumeIsolated { recorder.truncated = labels } }
            .onPreferenceChange(LumenIconScaleKey.self) { icons in MainActor.assumeIsolated { recorder.undersizedIcons = icons } }
            .onPreferenceChange(LumenOverflowKey.self) { clips in MainActor.assumeIsolated { recorder.overflowing = clips } }
            .onPreferenceChange(LumenColumnOverflowKey.self) { clips in MainActor.assumeIsolated { recorder.columnOverflowing = clips } }
            .onPreferenceChange(LumenVisibleTextKey.self) { texts in MainActor.assumeIsolated { recorder.visibleTexts = texts } }
            .onPreferenceChange(LumenBacklightKey.self) { glows in MainActor.assumeIsolated { recorder.backlights = glows } }
            .onPreferenceChange(LumenBacklightContainerKey.self) { frames in MainActor.assumeIsolated { recorder.backlightContainers = frames } }
        let (window, host) = offscreenWindow(AnyView(root), size: size)
        let top = host.safeAreaInsets.top
        // The window buttons, in the same top-left coordinates SwiftUI's global frames use.
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type -> CGRect? in
            guard let button = window.standardWindowButton(type), !button.isHidden else { return nil }
            var frame = host.convert(button.bounds, from: button)
            if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
            return frame
        }
        recorder.windowButtons = buttons.isEmpty ? nil : buttons.dropFirst().reduce(buttons[0]) { $0.union($1) }
        // The toolbar-hosted bar's items: where AppKit put them.
        recorder.hasToolbar = window.toolbar != nil
        recorder.toolbarItems = (window.toolbar?.items ?? []).compactMap { item -> CGRect? in
            guard let view = item.view, view.window != nil, !view.isHidden, view.bounds.width > 1 else { return nil }
            var frame = host.convert(view.bounds, from: view)
            if !host.isFlipped { frame.origin.y = host.bounds.height - frame.maxY }
            return frame
        }
        // Items AppKit left out for lack of room: in the toolbar, not among its visible items (a
        // hosted item that's dropped this way isn't in the overflow menu either). A unified
        // `LumenTopBar` hosts its leading content first, its status next, its panels last.
        if let toolbar = window.toolbar {
            let hosted = toolbar.items.filter { $0.view != nil }
            let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
            recorder.droppedToolbarItems = hosted.enumerated().compactMap { index, item in
                guard !visible.contains(item.itemIdentifier) else { return nil }
                if index == hosted.count - 1 && hosted.count > 1 { return "Panels" }
                // The status is temporary and gives way first: dropping it is by design.
                return index == 0 ? "Leading" : nil
            }
        }
        window.close()
        return (recorder, top)
    }

    /// Hosts `content` in a real (offscreen) window of `size` and lays it out; close the window when
    /// done. Used for geometry checks; pixel scans use the settled snapshot renderer.
    @MainActor
    private static func offscreenWindow(_ content: AnyView, size: CGSize, appearance: NSAppearance? = nil) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        // A SwiftUI scene would install the views' toolbar items (the unified top bar's) in the
        // window's toolbar; so does a hosting view that bridges toolbars, in the scene's compact style.
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        if let appearance { window.appearance = appearance }
        window.contentView = host
        window.setContentSize(size)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return (window, host)
    }

    static func signature(_ shortcut: KeyboardShortcut) -> String {
        "\(shortcut.modifiers.rawValue)-\(shortcut.key.character)"
    }
}


/// Finds vertical edges between two flat runs of different, close colors: the staircase of
/// PRINCIPLES §8. Strong contrasts (text, controls) and single-pixel lines aren't backgrounds and
/// are skipped; the surfaces either side of a line are still compared.
private struct SurfaceScan {
    let image: NSBitmapImageRep
    init(_ image: NSBitmapImageRep) { self.image = image }

    /// The least run on each side of an edge that counts as a background, in pixels.
    static let flatRun = 12
    /// The widest line between two runs that's looked past, in pixels: a 1 pt separator, antialiased.
    static let hairline = 2
    /// Colors closer than this are the same surface; ones further apart than `maximumStep` are
    /// content rather than a background tint.
    static let minimumStep = 2.0, maximumStep = 60.0
    /// How far a header's flat background may sit from the body's before it's its own surface.
    static let headerStep = 3.0

    func color(_ x: Int, _ y: Int) -> SIMD3<Double> {
        guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return .zero }
        return SIMD3(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)) * 255
    }

    func steps() -> [String] {
        let width = image.pixelsWide, height = image.pixelsHigh
        var rowsByEdge: [Int: Int] = [:]
        for y in stride(from: 0, to: height, by: 2) {
            var x = 0
            while x < width - 1 {
                // Extend a flat run from x.
                let start = x, base = color(x, y)
                while x + 1 < width, distance(color(x + 1, y), base) < 1.5 { x += 1 }
                let runEnd = x
                guard runEnd - start + 1 >= Self.flatRun, runEnd + Self.flatRun < width else { x += 1; continue }
                // The next surface starts right after the run, or past a hairline of up to
                // `hairline` pixels: a line between two surfaces mustn't hide the step between them.
                var next: SIMD3<Double>?
                for gap in 0...Self.hairline where runEnd + gap + Self.flatRun < width {
                    let candidate = color(runEnd + 1 + gap, y)
                    var flat = true
                    for k in 1...Self.flatRun where distance(color(runEnd + gap + k, y), candidate) >= 1.5 { flat = false; break }
                    if flat { next = candidate; break }
                }
                if let next, case let step = distance(base, next),
                   step >= Self.minimumStep, step <= Self.maximumStep, runEnd + 1 > 2, runEnd + 1 < width - 2 {
                    rowsByEdge[runEnd + 1, default: 0] += 1
                }
                x = runEnd + 1
            }
        }
        // An edge that spans a good stretch of rows is a background boundary, not a stray glyph. A
        // fixed 12 pt (6 scanned rows), not a share of the height: a 28 pt inset band in a 900 pt pane
        // must still count.
        let minimumRows = 6
        return rowsByEdge.filter { $0.value >= minimumRows }.keys.sorted().map { "the background steps at x = \($0) pt (\(rowsByEdge[$0]! * 2) pt tall)" }
    }

    /// The color distance between the mean flat background of the top `height` rows and that of the
    /// rows under them; `nil` when either has no flat background. Flat means inside a horizontal run
    /// of at least `flatRun` like pixels, so text and controls don't count.
    func headerDifference(height: Int) -> Double? {
        let rows = image.pixelsHigh
        guard height > 0, height < rows else { return nil }
        guard let header = meanFlatColor(rows: 0..<height), let body = meanFlatColor(rows: height..<rows) else { return nil }
        return distance(header, body)
    }

    private func meanFlatColor(rows: Range<Int>) -> SIMD3<Double>? {
        let width = image.pixelsWide
        var sum = SIMD3<Double>.zero, count = 0.0
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
            var x = 0
            while x < width {
                let start = x, base = color(x, y)
                while x + 1 < width, distance(color(x + 1, y), base) < 1.5 { x += 1 }
                let length = x - start + 1
                if length >= Self.flatRun {
                    sum += base * Double(length)
                    count += Double(length)
                }
                x += 1
            }
        }
        return count > 0 ? sum / count : nil
    }

    private func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d * d).sum().squareRoot()
    }
}
