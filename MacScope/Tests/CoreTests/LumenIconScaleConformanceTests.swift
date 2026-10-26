import LumenConformance
import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

/// U10-2 (D17, visual issues 1 and 4): no icon tile is smaller than its role allows. Lumen
/// 0.40.0 sizes the sidebar's tool tiles and the inspector's section tiles at 28 pt and has tiles
/// report themselves when undersized; `LumenConformance.iconScale` turns the reports into failures
/// for each pane MacScope shows, at its minimum size. (`LumenWindowConformanceTests` covers the
/// whole workspace window.)
@MainActor
final class LumenIconScaleConformanceTests: XCTestCase {
    private static let base: UInt64 = 0x1_0000_3f00

    private func store() -> WorkspaceStore {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "Icon Scale Fixture", path: "", kind: "fixture", architecture: "arm64e")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: Self.base, endAddress: Self.base + 8, confidence: 1)],
            instructions: [
                InstructionRow(address: Self.base, bytes: "1f2003d5", mnemonic: "nop", operands: "", hasBreakpoint: false, comment: nil),
                InstructionRow(address: Self.base + 4, bytes: "c0035fd6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data(repeating: 0, count: 64),
            sections: [SectionSummary(id: UUID(), name: "__text", address: Self.base, size: 64, fileOffset: 0, isExecutable: true)],
            imageBytes: Data(repeating: 0, count: 64)
        )
        let store = WorkspaceStore(workspaceName: "Icon Scale", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: store.focusedImageSlot, address: Self.base)))
        return store
    }

    private func assertNoUndersizedTiles<Content: View>(_ name: String, _ size: CGSize, file: StaticString = #filePath,
                                                       line: UInt = #line, _ content: () -> Content) {
        let findings = LumenConformance.iconScale(sizes: [size], of: { content().dsPaletteRoot().dsDensityRoot() })
        XCTAssertEqual(findings.map(\.description), [], name, file: file, line: line)
    }

    func testTheSidebarToolTilesAndInspectorSectionTilesAreFullSize() {
        for tool in WorkspaceTool.allCases {
            let store = store()
            store.selectedTool = tool
            assertNoUndersizedTiles("sidebar · \(tool.rawValue)", CGSize(width: AppLayout.sidebarMinWidth, height: 720)) {
                SidebarView(store: store)
            }
        }
        let store = store()
        for width in [AppLayout.compactInspectorMinWidth, AppLayout.inspectorMinWidth] {
            assertNoUndersizedTiles("inspector · \(Int(width))", CGSize(width: width, height: 900)) { InspectorView(store: store) }
        }
    }

    func testEverySettingsPageKeepsItsTilesFullSize() {
        let controller = Phase2LocalAIProviderController(endpoint: nil)
        for category in SettingsCategory.allCases {
            assertNoUndersizedTiles("Settings · \(category.rawValue)", CGSize(width: AppSettingsChrome.windowMinWidth, height: 620)) {
                SettingsView(providerController: controller, initialCategory: category)
            }
        }
    }

    /// The check isn't vacuous: a 14 pt tile beside its text is below the 16 pt inline minimum.
    func testTheCheckReportsAnUndersizedTile() {
        let findings = LumenConformance.iconScale(sizes: [CGSize(width: 200, height: 60)]) {
            HStack { LumenIconTile("cube", hue: .hueBlue, size: 14); Text("Types") }.dsPaletteRoot().dsDensityRoot()
        }
        XCTAssertFalse(findings.isEmpty)
    }
}
