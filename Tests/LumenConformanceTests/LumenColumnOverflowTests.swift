import SwiftUI
import XCTest
import LumenTokens
import LumenUI
import LumenConformance

/// PRINCIPLES §6 for columns: content wider than its column is centered by SwiftUI and cut off on
/// both edges with no label shortened (MacScope's Types inspector). Lumen's columns report it
/// themselves; `overflow`, `truncation` and `workspaceWindow` all surface it.
@MainActor
final class LumenColumnOverflowTests: XCTestCase {
    let sizes = [CGSize(width: 480, height: 320)]

    private func inspector<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LumenInspectorPane { content() }.frame(width: 259)
    }

    func testContentWithA272PointMinimumInA259PointInspectorIsReported() {
        let view = { self.inspector { Color.red.frame(minWidth: 272, minHeight: 40) } }
        let expected = ["“Inspector” content is 13 pt wider than its column"]
        XCTAssertEqual(LumenConformance.overflow(sizes: sizes, of: view).map(\.message), expected)
        XCTAssertEqual(LumenConformance.truncation(sizes: sizes, of: view).map(\.message), expected)
    }

    func testFlexibleContentIsNotReported() {
        let view = {
            self.inspector {
                Text(String(repeating: "A paragraph that wraps over several lines in the inspector. ", count: 6))
                Color.red.frame(maxWidth: .infinity, minHeight: 40)
                HStack { Text("Name"); Spacer(); Text("Value") }
            }
        }
        XCTAssertEqual(LumenConformance.overflow(sizes: sizes, of: view), [])
        XCTAssertEqual(LumenConformance.truncation(sizes: sizes, of: view), [])
    }

    func testAnAppsOwnColumnMarkedAsColumnContentIsReported() {
        let findings = LumenConformance.overflow(sizes: sizes) {
            Color.red.frame(width: 300, height: 40).lumenColumnContent("Types").frame(width: 250)
        }
        XCTAssertEqual(findings.map(\.message), ["“Types” content is 50 pt wider than its column"])
    }

    /// MacScope's case: the workspace window's inspector holds a view wider than the column.
    func testAWorkspaceInspectorHoldingAFixed300PointViewIsReported() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels(leading: true, bottom: false, trailing: true)]) { panels in
            LumenWorkspaceWindow(panels: .constant(panels)) {
                Color.gray
            } sidebar: {
                Color.red
            } inspector: {
                Color.blue.frame(width: 300)
            } topLeading: {
                Text("Project")
            }
        }
        XCTAssertEqual(findings.count, 2, findings.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(findings.allSatisfy { $0.message.hasPrefix("“Inspector” content is ") && $0.message.hasSuffix(" pt wider than its column") },
                      findings.map(\.description).joined(separator: "\n"))
    }

    /// A hidden region is zero wide by design, so it isn't watched.
    func testAHiddenInspectorIsNotReported() {
        let findings = LumenConformance.workspaceWindow(panels: [LumenWorkspacePanels(leading: true, bottom: false, trailing: false)]) { panels in
            LumenWorkspaceWindow(panels: .constant(panels)) {
                Color.gray
            } inspector: {
                Color.blue.frame(width: 300)
            } topLeading: {
                Text("Project")
            }
        }
        XCTAssertEqual(findings.map(\.description), [])
    }
}
