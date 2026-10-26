import SwiftUI
import LumenUI

/// Lumen owns the divider and drag interaction; MacScope owns the whole-area budget.
/// The editor is passed directly as the content, so its 360-point minimum excludes
/// the context bar, status bar, and all bottom-deck chrome.
struct DSBottomPanel<Editor: View, Panel: View>: View {
    @Binding var presentation: WorkspaceBottomPanelPresentation
    let debuggerExpanded: Bool
    @ViewBuilder var editor: Editor
    @ViewBuilder var panel: Panel
    @Environment(\.lumenMetrics) private var metrics

    var body: some View {
        GeometryReader { proxy in
            let geometry = DSBottomPanelGeometry(
                availableHeight: proxy.size.height,
                dividerHeight: metrics.stroke.hairline
            )
            editor
                .lumenBottomPanel(
                    isPresented: $presentation[isPresentedIn: geometry],
                    height: $presentation[heightIn: geometry, debuggerExpanded: debuggerExpanded],
                    minHeight: geometry.minimumPanelHeight,
                    contentMinHeight: DSBottomPanelGeometry.minimumEditorHeight + geometry.dividerHeight,
                    maxFraction: 0.25,
                    maximumHeight: 360
                ) {
                    panel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
        }
    }
}

/// Always mounted in the editor context bar, including when the bottom panel is hidden.
/// The focused-window View menu is the sole keyboard-shortcut owner.
struct DSBottomPanelControls: View {
    @Binding var presentation: WorkspaceBottomPanelPresentation

    var body: some View {
        HStack(spacing: Lumen.Space.s2) {
            // U9-4i: Lumen's pull-down (the deck's glyph and a chevron in a quiet capsule).
            LumenPullDownButton("Choose Shell or Debugger panel", systemImage: presentation.selectedDeck.systemImage) {
                ForEach(WorkspaceBottomDeck.allCases) { deck in
                    Button {
                        presentation.show(deck)
                    } label: {
                        Label(deck.title, systemImage: deck.systemImage)
                    }
                }
            }
            .accessibilityLabel("Choose bottom panel")
            .accessibilityIdentifier("workspace.bottomPanel.selector")

            Button {
                presentation.isPresented.toggle()
            } label: {
                Image(systemName: "rectangle.bottomthird.inset.filled")
            }
            .help(presentation.isPresented ? "Hide Panel" : "Show Panel")
            .accessibilityLabel(presentation.isPresented ? "Hide Panel" : "Show Panel")
            .accessibilityIdentifier("workspace.bottomPanel.toggle")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
    }
}

/// Receives targeted commands above Lumen's conditional subtree. Revealing the debugger
/// and selecting its tab do not depend on a previously mounted panel listener.
@MainActor
enum WorkspaceBottomPanelRouting {
    static func showLogicalBreakpoints(in store: WorkspaceStore, notification: Notification) {
        guard store.commandTargetsSelf(notification) else { return }
        showLogicalBreakpoints(in: store)
    }

    static func showLogicalBreakpoints(in store: WorkspaceStore) {
        store.bottomPanelPresentation.debuggerTab = .breakpoints
        store.bottomPanelPresentation.show(.debugger)
        store.selectedTool = .debug
        store.activateSidebarItem("debug:breakpoints")
    }
}
