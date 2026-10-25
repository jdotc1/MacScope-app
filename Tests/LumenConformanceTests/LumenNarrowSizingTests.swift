import AppKit
import SwiftUI
import XCTest
import LumenTokens
import LumenUI
@testable import LumenConformance

/// PRINCIPLES §6, narrow sizing: a split view sizing its columns measures content at a
/// near-zero width, and text that wraps without truncating answers with a height that becomes a
/// minimum taller than the window. Every Lumen component built that way is checked here, with the
/// sample content its golden uses.
@MainActor
final class LumenNarrowSizingTests: XCTestCase {
    private let sentence = "No symbols in the current document, so there is nothing to list yet"

    func testTheCheckFlagsTextThatBalloonsWhenMeasuredNarrow() {
        let balloons = LumenConformance.narrowSizing([("wrapping text", AnyView(Text(sentence).fixedSize(horizontal: false, vertical: true)))])
        XCTAssertEqual(balloons.count, 1, "unbounded wrapping text must be a finding")
        let bounded = LumenConformance.narrowSizing([("bounded text", AnyView(
            Text(sentence).lumenWrapsWithoutTruncating()))])
        XCTAssertEqual(bounded.map { $0.description }, [], "a minimum measuring width keeps it bounded")
    }

    /// The measuring width applies to the near-zero sizing pass only. In a
    /// real narrow column the text wraps within the column instead of reporting 120 pt and overflowing.
    func testWrappingTextIsBoundedAtNearZeroAndWrapsWithinARealNarrowColumn() {
        let text = Text(sentence).lumenWrapsWithoutTruncating()
        XCTAssertEqual(LumenConformance.narrowSizing([("near zero", AnyView(text))]).map { $0.description }, [])
        let column = NSHostingController(rootView: text).sizeThatFits(in: CGSize(width: 100, height: 10_000))
        XCTAssertLessThanOrEqual(column.width, 100, "text in a 100 pt column wraps within it")
        let banner = LumenBanner("The binary changed on disk since it was analyzed, and the listing may no longer match it.",
                                 title: "Out of date", actionTitle: "Reanalyze", action: {}, onDismiss: {})
        let bannerSize = NSHostingController(rootView: banner.lumenPaletteRoot()).sizeThatFits(in: CGSize(width: 180, height: 10_000))
        XCTAssertLessThanOrEqual(bannerSize.width, 180, "a long banner in a 180 pt column keeps its close button inside")
    }

    func testLumensColumnComponentsStayBoundedWhenMeasuredNarrow() {
        let notice = LumenNotice(source: "Extension: Git Hosting", title: "Remote repository detected",
                                 message: "Connect sample/Lumen to show issues and pull requests?", systemImage: "arrow.triangle.branch",
                                 primary: LumenBarAction("Connect") {}, secondary: LumenBarAction("Not Now") {})
        let locals = [
            LumenVariable(id: "self", name: "self", type: "Parser", value: "0x600003a1c000", disclosure: .expanded),
            LumenVariable(id: "header", depth: 1, name: "header", type: "UnsafePointer<Header>", value: "0x16fdff2a8", disclosure: .expanded),
            LumenVariable(id: "magic", depth: 2, name: "magic", type: "UInt32", value: "0xfeedfacf"),
        ]
        let subjects: [(name: String, view: AnyView)] = [
            ("LumenEmptyState inline", AnyView(LumenEmptyState(sentence, prominence: .inline))),
            ("LumenEmptyState pane", AnyView(LumenEmptyState("Nothing selected", message: sentence, systemImage: "cursorarrow.rays"))),
            ("LumenLoadingState", AnyView(LumenLoadingState("Analyzing", message: sentence, onCancel: {}))),
            ("LumenErrorState", AnyView(LumenErrorState("Couldn’t open the file", message: sentence, recovery: "Choose it again.", onRetry: {}))),
            ("LumenSidebarSection with inline empties", AnyView(VStack(spacing: 0) {
                LumenSidebarSection("Symbols") { LumenEmptyState(sentence, prominence: .inline) }
                LumenSidebarSection("Open Pull Requests") { LumenEmptyState("No open pull requests", prominence: .inline) }
                LumenSidebarSection("Repositories") { LumenEmptyState("No repositories configured", prominence: .inline) }
            })),
            ("LumenEmptyHero", AnyView(LumenEmptyHero("No binary open", message: "Open a macOS executable, app bundle, framework or dylib to begin analysis.",
                                                      systemImage: "cpu", hue: .huePink, primary: LumenBarAction("Open Binary…") {}))),
            ("LumenAddressField", AnyView(LumenAddressField(text: .constant("100000f50"), prompt: "100000f50", prefix: "0x",
                                                            hint: "Hex address, or select an instruction.") { _ in })),
            ("LumenBanner", AnyView(LumenBanner("The binary changed on disk since it was analyzed.", title: "Out of date",
                                                actionTitle: "Reanalyze", action: {}))),
            ("LumenNoticeCard", AnyView(LumenNoticeCard(notice) {})),
            ("LumenCodeSample", AnyView(LumenCodeSample(["editor ~/MyProject", "editor extras/index.html --line 740"]))),
            ("LumenItemCard", AnyView(LumenItemCard("Formatter", author: "Sam Ortiz", summary: "Formatting that’s fast and reliable.",
                                                    systemImage: "text.alignleft", hue: .huePink, state: .available))),
            ("LumenDetailHeader", AnyView(LumenDetailHeader("Snippets", summary: "The essential toolkit for web developers.",
                                                            systemImage: "chevron.left.forwardslash.chevron.right", hue: .hueGreen,
                                                            categories: ["Completions"], meta: ["Version 1.3.6"], links: [], permissions: [],
                                                            primary: LumenBarAction("Uninstall") {}, onShare: {}))),
            ("LumenEvaluationResult", AnyView(LumenEvaluationResult("Dictionary<String, Array<Int>>", type: "Dictionary<String, Array<Int>>"))),
            ("LumenVariableTree", AnyView(LumenVariableTree([LumenVariableSection("Locals", variables: locals)]))),
            ("LumenConsole", AnyView(LumenConsole(lines: [
                LumenConsoleLine(.command, "breakpoint set -n compute"),
                LumenConsoleLine(.output, "Breakpoint 1: Sample`compute(_:) + 12 at main.swift:42, a long line that wraps instead of truncating"),
            ], input: .constant(""), prompt: "(lldb)", placeholder: "frame variable", onSubmit: { _ in }))),
            ("LumenInspectorHeader", AnyView(LumenInspectorHeader("sub_100003f80", subtitle: "Function · 212 bytes", systemImage: "function", hue: .hueIndigo))),
            ("LumenRadioGroup", AnyView(LumenRadioGroup(selection: .constant("A"), options: ["Only if there are processes other than the login shell", "Never"],
                                                        title: { $0 }))),
            // Settings detail column, sidebar, table and debugger notes, input palette help.
            ("LumenSettingsRow", AnyView(LumenSettingsRow("Reopen windows", description: sentence) { Toggle("", isOn: .constant(true)).labelsHidden() })),
            ("LumenSettingsHeader", AnyView(LumenSettingsHeader("General", systemImage: "gearshape", hue: .hueIndigo, summary: sentence))),
            ("LumenSidebarPaneGrid", AnyView(LumenSidebarPaneGrid([LumenSidebarItem(id: "files", title: "Files", systemImage: "folder")],
                                                                  arrangement: .constant("files")))),
            ("LumenTable footnote", AnyView(LumenTable([NarrowRow(id: 1)], selection: .constant(nil), height: .fitRows(maxVisible: 4),
                                                       footnote: sentence, columns: [LumenTableColumn("Name") { _ in Text("main") }]))),
            ("LumenVariableTree truncation note", AnyView(LumenVariableTree([LumenVariableSection("Locals", variables: locals,
                                                                                                 truncationMessage: sentence)]))),
            ("LumenInputPalette help", AnyView(LumenInputPalette("Go to address", systemImage: "arrow.right", help: sentence) { _ in })),
        ]
        XCTAssertEqual(LumenConformance.narrowSizing(subjects).map { $0.description }, [])
    }
}

private struct NarrowRow: Identifiable { let id: Int }
