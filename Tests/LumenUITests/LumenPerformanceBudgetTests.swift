import AppKit
import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

/// Speed budgets: dense views (MacScope's listings, the graph) lean on these paths, so a slowdown
/// should fail here before anyone sees it. Each budget is several times today's debug-build time, so
/// a slower CI machine passes and a real regression doesn't. `LUMEN_BENCH=1` prints the timings.
@MainActor
final class LumenPerformanceBudgetTests: XCTestCase {
    /// The median of `runs` timings of `body`, in milliseconds.
    private func milliseconds(runs: Int = 5, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            // Keep native objects from one sample out of the next sample's lifetime.
            let elapsed = autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            samples.append(elapsed)
        }
        return samples.sorted()[runs / 2]
    }

    /// Budgets are set on the maintainer's Apple-silicon laptop. Shared CI virtual machines are
    /// slower and noisier, so CI sets `LUMEN_PERF_BUDGET_SCALE` to widen every budget equally.
    private static let budgetScale = ProcessInfo.processInfo.environment["LUMEN_PERF_BUDGET_SCALE"].flatMap(Double.init).map { max($0, 1) } ?? 1

    private func budget(_ name: String, _ ms: Double, under unscaled: Double) {
        let limit = unscaled * Self.budgetScale
        if ProcessInfo.processInfo.environment["LUMEN_BENCH"] == "1" {
            print("BENCH \(name): \(String(format: "%.2f", ms)) ms (budget \(Int(limit)) ms)")
        }
        XCTAssertLessThan(ms, limit, "\(name) took \(String(format: "%.1f", ms)) ms; its budget is \(Int(limit)) ms")
    }

    private func freshStore() -> LumenThemeStore {
        TestPack.store(themes: LumenRegistry.core.builtInThemes)
    }

    func testBuildingAPaletteForANewSelection() {
        let ms = milliseconds { _ = freshStore().resolvedPalette() }
        budget("palette, cold", ms, under: 20)
    }

    func testReadingColorsFromAPalette() {
        let palette = freshStore().resolvedPalette()
        let tokens = TestPack.registry.tokens
        let ms = milliseconds {
            for _ in 0..<1_000 { for token in tokens { _ = palette[token] } }
        }
        budget("palette reads ×\(1_000 * tokens.count)", ms, under: 150)
    }

    func testSwitchingThemesBackAndForth() {
        let store = freshStore()
        let ids = [LumenThemes.standardID, LumenThemes.midnightID, LumenThemes.ultravioletID, LumenThemes.contrastID]
        ids.forEach { store.select($0); _ = store.resolvedPalette() }   // warm: each palette built once
        let ms = milliseconds {
            for round in 0..<100 { store.select(ids[round % ids.count]); _ = store.resolvedPalette() }
        }
        budget("theme switch ×100", ms, under: 20)
    }

    func testValidatingATheme() {
        let theme = LumenRegistry.core.theme(id: LumenThemes.standardID)!
        let ms = milliseconds { _ = LumenValidator.issues(for: theme, in: .core) }
        budget("validate one theme", ms, under: 150)
    }

    func testMatchingCommandsAsYouType() {
        let words = ["Show", "Hide", "Open", "Toggle", "Go to", "Find", "Reveal", "Run", "Build", "Clean"]
        let things = ["Panel", "Inspector", "Navigator", "Symbol", "Address", "Breakpoint", "Graph", "Console", "Theme", "Tab"]
        let commands = (0..<500).map { i in
            LumenCommand(id: "c\(i)", "\(words[i % 10]) \(things[(i / 10) % 10]) \(i)", category: "Test", systemImage: "circle",
                         keywords: ["keyword\(i % 7)"]) {}
        }
        let ms = milliseconds {
            for query in ["p", "pa", "pan", "pane", "panel", "sho", "go sym", "brk", "theme 4", "zz"] {
                _ = LumenCommandMatcher.rows(commands, query: query, recents: [])
            }
        }
        budget("palette matching, 500 commands × 10 queries", ms, under: 250)
    }

    func testLayingOutAThousandRows() {
        let rows = VStack(spacing: 0) {
            ForEach(0..<1_000, id: \.self) { i in
                LumenListRow("symbol_\(i)", detail: String(format: "0x%08X", i * 16), systemImage: "lumen.pseudocode",
                             isSelected: i == 3, monospaced: true) { LumenCount(i) }
            }
        }
        let ms = milliseconds(runs: 3) {
            let host = NSHostingController(rootView: rows.frame(width: 320).lumenPaletteRoot().lumenMetrics(.standard))
            _ = host.sizeThatFits(in: CGSize(width: 320, height: 1_000_000))
        }
        budget("lay out 1,000 list rows", ms, under: 2_500)
    }

    // MARK: Interaction budgets
    //
    // Typing, selecting and scrolling at the sizes a disassembler and an archiving app produce, hosted in
    // windows that are never shown. Each step is one change, then layout and display until settled.
    // Ceilings are generous (debug build, any machine): they catch the multi-second hangs that
    // were fixed, not small drifts. Table reports are off, as in a shipping app.

    private final class Hosted {
        let window: NSWindow
        let host: NSView
        init(_ window: NSWindow, _ host: NSView) { self.window = window; self.host = host }

        @MainActor func close() {
            window.close()
            window.contentView = nil
        }
    }

    private func settle(_ hosted: Hosted) {
        for _ in 0..<3 {
            RunLoop.current.run(mode: .default, before: Date())
            hosted.host.layoutSubtreeIfNeeded()
            hosted.host.display()
            CATransaction.flush()
        }
    }

    private func timed(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    /// `view` in a window that is never ordered on screen, laid out; and how long that took.
    private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 700, height: 800)) -> (Hosted, Double) {
        let store = LumenSnapshot.store(for: .init(themeID: LumenThemes.standardID, colorScheme: .dark), registry: LumenRegistry(packs: [.core, .code]))
        let root = view.lumenPaletteRoot(store: store).lumenDensityRoot(store: store).lumenMetrics(.standard)
            .environment(\.lumenReportsLayoutChecks, false)
        var hosted: Hosted!
        let ms = timed {
            let hosting = NSHostingView(rootView: AnyView(root))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            hosted = Hosted(window, hosting)
            settle(hosted)
        }
        return (hosted, ms)
    }

    private func change(_ hosted: Hosted, _ body: () -> Void) -> Double {
        timed { body(); settle(hosted) }
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// Types into the first editable field as a person would, through its delegate.
    private func type(_ hosted: Hosted, _ text: String) -> Double {
        guard let field = views(NSTextField.self, in: hosted.host).first(where: \.isEditable) else {
            XCTFail("No editable field"); return 0
        }
        return change(hosted) {
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
    }

    /// Scrolls the tallest scroll view to `fraction` of its document.
    private func scroll(_ hosted: Hosted, to fraction: CGFloat) -> Double {
        guard let scrollView = views(NSScrollView.self, in: hosted.host).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scrollView.documentView else { XCTFail("No scroll view"); return 0 }
        return change(hosted) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, (document.frame.height - scrollView.contentView.bounds.height) * fraction)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private static func symbol(_ i: Int) -> String {
        let modules = ["Swift", "Foundation", "MacScopeCore", "AnalysisCore", "DebuggerCore"]
        return "\(modules[i % 5]).Dictionary<Swift.String, \(modules[(i + 1) % 5]).Array<Swift.Int>>.Index.Storage.symbolicatedValue\(i)"
    }

    private static func logEntries(_ count: Int) -> [LumenLogEntry] {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<count).map { (i: Int) -> LumenLogEntry in
            let level: LumenLogEntry.Level = i % 31 == 0 ? .error : (i % 7 == 0 ? .warning : .log)
            return LumenLogEntry(date: base.addingTimeInterval(Double(i) * 0.01), source: "source\(i % 12)",
                                 level: level,
                                 message: "Archived file \(i) of batch: /Volumes/Data/Archive/Study\(i % 200)/Series\(i % 9)/IM\(i).bin")
        }
    }

    /// 1.4 to 4.5 s per keystroke before.
    func testTypingInAPaletteOfFiveThousandCommands() {
        let words = ["Show", "Hide", "Open", "Toggle", "Go to", "Find", "Reveal", "Run", "Build", "Clean"]
        let things = ["Panel", "Inspector", "Navigator", "Symbol", "Address", "Breakpoint", "Graph", "Console", "Theme", "Tab"]
        let commands = (0..<5_000).map { i in
            LumenCommand(id: "c\(i)", "\(words[i % 10]) \(things[(i / 10) % 10]) \(Self.symbol(i).suffix(30))", category: "Cat\(i % 9)",
                         systemImage: "circle", keywords: ["keyword\(i % 7)"]) {}
        }
        let (hosted, _) = host(LumenCommandPalette(commands, recentsKey: nil), size: CGSize(width: 700, height: 600))
        defer { hosted.close() }
        let ms = ["t", "tg", "tgp", "symbolicated"].reduce(0) { $0 + type(hosted, $1) }
        budget("palette, 5,000 commands, 4 keystrokes", ms, under: 4_000)
    }

    /// Highlight moves and hovers re-evaluate the palette's body; they must not
    /// re-match every command.
    func testThePaletteMatchesOncePerQuery() {
        let commands = (0..<50).map { LumenCommand(id: "c\($0)", "Command \($0)", category: "Test", systemImage: "circle") {} }
        let cache = LumenCommandPaletteCache()
        let first = cache.rows(commands, scope: nil, query: "co", recents: [])
        _ = cache.rows(commands, scope: nil, query: "co", recents: [])   // a body after ↓ or a hover
        XCTAssertEqual(cache.matchPasses, 1)
        XCTAssertEqual(first.map(\.command.id), LumenCommandMatcher.rows(commands, query: "co", recents: []).map(\.command.id))
        _ = cache.rows(commands, scope: nil, query: "com", recents: [])
        XCTAssertEqual(cache.matchPasses, 2, "A new query matches again")
        var changed = commands
        changed[0] = LumenCommand(id: "c0", "Renamed", category: "Test", systemImage: "circle") {}
        XCTAssertFalse(cache.rows(changed, scope: nil, query: "com", recents: []).contains { $0.command.id == "c0" },
                       "A changed command set matches again")
    }

    /// 12 s for one keystroke at 100k lines before.
    func testFilteringAFiftyThousandLineLogConsole() {
        let (hosted, _) = host(LumenLogConsole(Self.logEntries(50_000), onClear: {}))
        defer { hosted.close() }
        let ms = ["S", "St", "Study19", ""].reduce(0) { $0 + type(hosted, $1) }
        budget("log console, 50,000 lines, 4 filter edits", ms, under: 5_000)
    }

    /// The console filters once per change, and appended lines on their own.
    func testTheLogConsoleFiltersOncePerChange() {
        let cache = LumenLogConsoleCache()
        var entries = Self.logEntries(1_000)
        let shown = cache.shown(entries, filter: .errors, source: nil, query: "")
        _ = cache.shown(entries, filter: .errors, source: nil, query: "")
        XCTAssertEqual(cache.fullPasses, 1)
        entries.append(LumenLogEntry(date: .now, source: "lldb", level: .error, message: "new"))
        let appended = cache.shown(entries, filter: .errors, source: nil, query: "")
        XCTAssertEqual(cache.fullPasses, 1, "An appended line is filtered on its own")
        XCTAssertEqual(appended.map(\.id), shown.map(\.id) + [entries.last!.id])
        entries[0] = LumenLogEntry(date: .now, source: "lldb", level: .error, message: "replaced")
        XCTAssertEqual(cache.shown(entries, filter: .errors, source: nil, query: "").first?.message, "replaced")
        XCTAssertEqual(cache.fullPasses, 2)
        XCTAssertEqual(cache.sources(for: entries), Array(Set(entries.map(\.source))).sorted())
    }

    /// 4.5 s to first draw before.
    func testShowingAThousandVariables() {
        let variables = (0..<1_000).map { i in
            LumenVariable(id: "v\(i)", name: "member\(i)", type: "Swift.Array<Thing\(i % 5)>",
                          value: "0x\(String(i * 4096, radix: 16)) \(Self.symbol(i))", disclosure: .collapsed)
        }
        let (hosted, first) = host(ScrollView { LumenVariableTree([LumenVariableSection("Locals", variables: variables)]) })
        defer { hosted.close() }
        budget("variable tree, 1,000 rows, first layout", first, under: 2_000)
        budget("variable tree, 1,000 rows, scroll", scroll(hosted, to: 0.5), under: 1_000)
    }

    /// 7.7 s to first draw before.
    func testShowingAThousandStackFrames() {
        final class Model: ObservableObject { @Published var selection: Int? = 0 }
        struct Stack: View {
            let frames: [LumenStackFrame]
            @ObservedObject var model: Model
            var body: some View { ScrollView { LumenStackFrameList(frames, selection: $model.selection) }.frame(width: 360) }
        }
        let model = Model()
        let frames = (0..<1_000).map { LumenStackFrame(index: $0, function: Self.symbol($0), address: UInt64(0x1000 + $0 * 16), location: "File\($0).swift:\($0)") }
        let (hosted, first) = host(Stack(frames: frames, model: model))
        defer { hosted.close() }
        budget("stack, 1,000 frames, first layout", first, under: 2_000)
        budget("stack, 1,000 frames, select", change(hosted) { model.selection = 3 }, under: 500)
    }

    /// About 1 s a scroll step before.
    func testScrollingAHexDump() {
        let bytes = (0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) }
        let (hosted, _) = host(ScrollView { LumenHexDump(bytes, baseAddress: 0x1_0000_0000, selection: .constant(nil)) })
        defer { hosted.close() }
        let ms = scroll(hosted, to: 0.5) + scroll(hosted, to: 0.51)
        budget("hex dump, 64 KB, two scroll steps", ms, under: 1_500)
    }

    /// Small scroll steps grew with the row count before.
    func testScrollingAFiftyThousandRowTable() {
        struct Row: Identifiable { let id: Int; let name: String }
        let rows = (0..<50_000).map { Row(id: $0, name: Self.symbol($0)) }
        let (hosted, _) = host(LumenTable(rows, selection: .constant(nil), height: .minimum(600), columns: [
            .text("Name", monospaced: true, truncationMode: .middle) { $0.name },
            .text("Index", width: 80) { "\($0.id)" },
        ]))
        defer { hosted.close() }
        let ms = scroll(hosted, to: 0.5) + scroll(hosted, to: 0.51) + scroll(hosted, to: 1)
        budget("table, 50,000 rows, three scroll steps", ms, under: 1_000)
    }

    /// 2.7 s for 1,000 lines before.
    func testShowingAThousandLineCodeListing() {
        let lines: [[LumenCodeRun]] = (0..<1_000).map { i in
            [LumenCodeRun("    let ", LumenToken.Code.keyword), LumenCodeRun("value\(i)"), LumenCodeRun(" = "), LumenCodeRun("\(i * 7)", LumenToken.Code.number)]
        }
        let (hosted, first) = host(ScrollView { LumenCodeListing(lines, currentLine: 0) })
        defer { hosted.close() }
        budget("code listing, 1,000 lines, first layout", first, under: 1_500)
        budget("code listing, 1,000 lines, scroll", scroll(hosted, to: 0.5), under: 500)
    }
}
