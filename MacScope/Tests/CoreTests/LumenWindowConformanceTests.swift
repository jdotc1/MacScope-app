import AppKit
import LumenConformance
import LumenTokens
import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

/// PRINCIPLES §6 for the workspace window, through Lumen's conformance checks: every built-in theme
/// passes Lumen's validator, and nothing is cut off at the window's minimum width. Each column's real
/// content fits the minimum `WorkspaceRootView` gives it, and the columns that show at once fit the
/// window (the inspector only from `inspectorPresentationMinWindowWidth`).
@MainActor
final class LumenWindowConformanceTests: XCTestCase {
    private func store(tool: WorkspaceTool) -> WorkspaceStore {
        let base: UInt64 = 0x1_0000_3f00
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "Conformance Fixture", path: "", kind: "fixture", architecture: "arm64e")],
            functions: [],
            instructions: [InstructionRow(address: base, bytes: "1f2003d5", mnemonic: "nop", operands: "",
                                          hasBreakpoint: false, comment: nil)],
            xrefs: [],
            hexBytes: Data(repeating: 0, count: 64),
            sections: [SectionSummary(id: UUID(), name: "__text", address: base, size: 64, fileOffset: 0, isExecutable: true)],
            imageBytes: Data(repeating: 0, count: 64)
        )
        let store = WorkspaceStore(workspaceName: "Conformance", snapshot: snapshot, engine: AnalysisEngine(),
                                   autosaveScheduler: nil)
        store.selectedTool = tool
        return store
    }

    /// U8-0: the real workspace window keeps its top bar in place and at one height for every
    /// combination of sidebar, bottom deck and inspector, at 900×560 and 1440×900 (hiding the
    /// inspector once pushed the bar off the top of the window).
    func testTheWorkspaceWindowKeepsItsTopBarForEveryPanelCombination() {
        let runtime = WorkspaceDocumentRuntime()
        var sessions: [WorkspaceDocumentSession] = []
        let findings = LumenConformance.workspaceWindow { panels in
            let store = self.store(tool: .project)
            store.isSidebarPresented = panels.leading
            store.bottomPanelPresentation.isPresented = panels.bottom
            store.isInspectorPresented = panels.trailing
            let session = WorkspaceDocumentSession(sessionID: .init(rawValue: UUID()), windowID: .fresh(), source: store,
                                                   io: WorkspaceDocumentIO(), reservations: runtime.openCoordinator)
            sessions.append(session)
            // As the app's scene does (MacScopeApp): the session registry is an environment object.
            return WorkspaceRootView(store: store, documentSession: session, openCoordinator: runtime.openCoordinator,
                                     windowActivator: runtime.windowActivator)
                .environmentObject(runtime.registry)
        }
        sessions.forEach { $0.close() }
        XCTAssertEqual(findings.map(\.description), [])
    }

    func testBuiltInThemesConform() {
        let registry = MacScopeLumen.registry
        XCTAssertEqual(LumenConformance.themes(in: registry, themes: registry.galleryThemes).map(\.description), [])
    }

    func testEveryColumnFitsTheMinimumWindow() {
        let window = AppLayout.minimumSupportedWindowWidth
        let metrics = AppLayout.workspacePaneMetrics(for: window)
        XCTAssertFalse(metrics.allowsInspector, "The inspector isn't offered at the minimum window width")
        let findings = LumenConformance.layout(windowMinWidth: window, columns: [
            sidebarColumn(minWidth: metrics.sidebarWidth),
            editorColumn(minWidth: metrics.editorFrameMinimumWidth),
        ])
        XCTAssertEqual(findings.map(\.description), [])
    }

    func testEveryColumnFitsWhenTheInspectorFirstShows() {
        let window = AppLayout.inspectorPresentationMinWindowWidth
        let metrics = AppLayout.workspacePaneMetrics(for: window)
        XCTAssertTrue(metrics.allowsInspector)
        let findings = LumenConformance.layout(windowMinWidth: window, columns: [
            sidebarColumn(minWidth: AppLayout.sidebarMinWidth),
            editorColumn(minWidth: AppLayout.editorMinimumReadableWidth),
            LumenConformance.Column("inspector", minWidth: metrics.inspectorMinWidth) {
                InspectorView(store: self.store(tool: .project))
            },
        ])
        XCTAssertEqual(findings.map(\.description), [])
    }

    private func sidebarColumn(minWidth: CGFloat) -> LumenConformance.Column {
        LumenConformance.Column("sidebar", minWidth: minWidth, contents: WorkspaceTool.allCases.map { tool in
            (name: "sidebar · \(tool.rawValue)", view: AnyView(SidebarView(store: store(tool: tool))))
        })
    }

    private func editorColumn(minWidth: CGFloat) -> LumenConformance.Column {
        LumenConformance.Column("editor", minWidth: minWidth) {
            EditorStatusBar(store: self.store(tool: .project))
        }
    }
}
