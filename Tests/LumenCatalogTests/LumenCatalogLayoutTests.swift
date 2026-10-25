import AppKit
import SwiftUI
import XCTest
import LumenTokens
import LumenUI
import LumenConformance
@testable import LumenCatalog

/// The Catalog's windows never cut their content off (PRINCIPLES §6), checked with the same kit apps
/// use: every page fits the page column's minimum, the inspector fits its column, and the window's
/// minimum covers all three.
@MainActor
final class LumenCatalogLayoutTests: XCTestCase {
    func testTheMainWindowConforms() {
        let columns = [
            LumenConformance.Column("Sidebar", minWidth: CatalogLayout.sidebarMinWidth, contents: []),
            LumenConformance.Column("Page", minWidth: CatalogLayout.pageMinWidth,
                                    contents: CatalogPage.allCases.map { ("\($0) page", AnyView(CatalogPageView(page: $0))) }),
            LumenConformance.Column("Inspector", minWidth: LumenLayout.inspectorColumn.min,
                                    contents: CatalogPage.allCases.map { ("\($0) inspector", AnyView(CatalogInspector(page: $0, hue: .constant($0.hue)))) }),
        ]
        XCTAssertEqual(LumenConformance.layout(windowMinWidth: CatalogLayout.windowMinWidth, columns: columns).map(\.description), [])
    }

    func testTheSplitWorkspaceConforms() {
        let columns = [
            LumenConformance.Column("Navigator", minWidth: LumenLayout.sidebarColumn.min, contents: []),
            LumenConformance.Column("Editor", minWidth: SplitLayout.editorMinWidth) {
                LumenLogConsole([LumenLogEntry(date: .now, source: "lldb", message: "Process launched")], onClear: {})
            },
            LumenConformance.Column("Inspector", minWidth: LumenLayout.inspectorColumn.min) {
                LumenInspectorHeader("parse_header", subtitle: "Function", systemImage: "lumen.pseudocode", hue: .hueIndigo)
                LumenInspectorSection("Appearance", systemImage: "paintpalette.fill", hue: .huePink) {
                    LumenHueSwatchPicker(selection: .constant(.hueIndigo))
                }
            },
        ]
        XCTAssertEqual(LumenConformance.layout(windowMinWidth: SplitLayout.windowMinWidth, columns: columns, dividers: 2)
            .map(\.description), [])
        // The top bar spans the window, so it must fit the window's minimum too.
        let topBar = LumenConformance.Column("Top bar", minWidth: SplitLayout.windowMinWidth) {
            // The three-pane layout with its status showing (the widest it gets), plus the window buttons'
            // inset the unified placement adds before it.
            SplitWorkspaceTopBar(showsNavigator: .constant(true), showsDebugger: .constant(true), showsInspector: .constant(true),
                                 activity: .constant(.working("Analyzing libsystem_kernel.dylib", progress: 0.42)))
                .padding(.leading, LumenLayout.windowButtonsInset)
        }
        XCTAssertEqual(LumenConformance.layout(windowMinWidth: SplitLayout.windowMinWidth, columns: [topBar]).map(\.description), [])
    }
}
