import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

/// Offscreen review renders of the agent-attach UI (not goldens): the window's consent banner,
/// the attached indicator, and the Settings row.
final class MCPAttachShotTests: XCTestCase {
    @MainActor
    func testRenderAgentAttachUIForReview() throws {
        try UIReviewShots.write("mcp-attach-banners", size: CGSize(width: 560, height: 210)) {
            VStack(spacing: Lumen.Space.s3) {
                MCPAttachConnectionBanner(workspaceName: "libobjc.A.dylib", consent: .pending,
                                          onAllow: {}, onDeny: {}, onDisconnect: {})
                MCPAttachConnectionBanner(workspaceName: "libobjc.A.dylib", consent: .allowed,
                                          onAllow: {}, onDeny: {}, onDisconnect: {})
            }
            .padding(Lumen.Space.s4)
        }
        try UIReviewShots.write("mcp-attach-settings", size: CGSize(width: 620, height: 150)) {
            LumenFormSection("Agents") {
                LumenSettingsRow("Allow agents to attach", description: "MCP clients started with MacScope --mcp-attach can work in an open window after you allow them there. Their edits are undoable and saved like yours. Only your user account can connect.") {
                    Toggle("Allow agents to attach", isOn: .constant(true)).toggleStyle(.switch)
                }
            }
            .padding(Lumen.Space.s4)
        }
    }

    /// Live fixes (1) and (2): the consent banner sits in its own bottom inset under the editor (the
    /// mode buttons stay clear), and the Agents switch stays on the row's trailing edge.
    @MainActor
    func testRenderLiveFixesForReview() throws {
        try UIReviewShots.write("live-fix-1-banner-bottom-inset", size: CGSize(width: 900, height: 360)) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    LumenModeSwitcher(selection: .constant(EditorMode.graph), options: EditorMode.allCases, style: .pill) { $0.rawValue }
                    Spacer()
                }
                .padding(Lumen.Space.s4)
                Divider()
                Color.lumen(.bgCanvas).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { Text("Editor").foregroundStyle(.secondary) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MCPAttachConnectionBanner(workspaceName: "libjpeg.8.3.2.dylib", consent: .pending,
                                          onAllow: {}, onDeny: {}, onDisconnect: {})
                    .padding(Lumen.Space.s4)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        try UIReviewShots.write("live-fix-2-agents-settings-row", size: CGSize(width: 620, height: 170)) {
            LumenFormSection("Agents") {
                LumenSettingsRow("Allow agents to attach", description: "Let MCP agents work in a window you allow.") {
                    Toggle("Allow agents to attach", isOn: .constant(true)).toggleStyle(.switch)
                }
                Text("Agents connect with MacScope --mcp-attach and wait until you click Allow in the window. Their edits are undoable and saved like yours. Only your user account can connect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Lumen.Space.s4)
        }
    }
}
