import LumenConformance
import LumenTokens
import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

/// U10-3 (D17, visual issue 2, the "staircase"): the disassembly pane is one surface. Its
/// column header, lane gutter and listing share the pane's background, and every band (a section
/// header, the selection, the current block) runs the pane's full width. `LumenConformance.surfaceSteps`
/// renders the pane offscreen and reports each place two flat background colors meet at a vertical
/// edge inside it. The listing's ScrollView doesn't render offscreen, so the pane is assembled from
/// the same row views the listing uses, with the insets the listing hands them.
@MainActor
final class LumenSurfaceStepsConformanceTests: XCTestCase {
    private static let base: UInt64 = 0x1_0000_3f00
    private static let laneWidth = DisassemblyBranchLanes.gutterWidth
    private static let size = CGSize(width: 760, height: 260)

    private func store() -> WorkspaceStore {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "Surface Fixture", path: "", kind: "fixture", architecture: "arm64e")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: Self.base, endAddress: Self.base + 8, confidence: 1)],
            instructions: [],
            xrefs: [],
            hexBytes: Data(repeating: 0, count: 16),
            sections: [SectionSummary(id: UUID(), name: "__text", address: Self.base, size: 16, fileOffset: 0, isExecutable: true)],
            imageBytes: Data(repeating: 0, count: 16)
        )
        return WorkspaceStore(workspaceName: "Surface", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func row(_ address: UInt64, _ mnemonic: String, index: Int, columns: DisassemblyColumns,
                     selected: Bool = false, inBlock: Bool = false) -> DisassemblyListingRow {
        DisassemblyListingRow(
            row: InstructionRow(address: address, bytes: "1f2003d5", mnemonic: mnemonic, operands: "", hasBreakpoint: false, comment: nil),
            comment: nil, tag: nil, colorTag: nil, isData: false, operandFormat: nil,
            isInCurrentBlock: inBlock, index: index, columns: columns, isSelected: selected,
            breakpointTarget: ImageAddress(slot: .primary, address: address),
            breakpointGutter: DebuggerLogicalBreakpointGutterPresentation(
                action: .set, symbol: .disabled, stateDescription: "", logicalBreakpointCount: 0,
                locationCount: 0, accessibilityLabel: ""),
            isBreakpointCatalogAvailable: false, toggleBreakpoint: {}, select: { true }
        )
    }

    /// The pane as `DisassemblyView` lays it out; `rowsInset` re-creates the pre-U10-3 listing,
    /// which padded its rows' bands in from the pane's edges.
    private func pane(rowsInset: CGFloat = 0) -> some View {
        let store = store()
        let columns = DisassemblyColumns(width: Self.size.width - Self.laneWidth)
        return VStack(spacing: 0) {
            DisassemblyHeaderRow(columns: columns)
                .padding(.leading, Self.laneWidth)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                DisassemblySectionHeaderRow(header: SectionHeaderRow(address: Self.base, name: "__TEXT,__text", isExecutable: true),
                                            columns: columns, store: store)
                DisassemblyLabelRow(label: LabelRow(address: Self.base, name: "_main", isFunctionStart: true), columns: columns)
                row(Self.base, "nop", index: 2, columns: columns, inBlock: true)
                row(Self.base + 4, "ret", index: 3, columns: columns, selected: true, inBlock: true)
                row(Self.base + 8, "nop", index: 4, columns: columns)
            }
            .environment(\.disassemblyRowInsets,
                         EdgeInsets(top: 0, leading: Self.laneWidth + Lumen.Space.s5, bottom: 0, trailing: Lumen.Space.s5))
            .dsEditorSurface(ownsEveryColor: true)
            .padding(.horizontal, rowsInset)
            .padding(.vertical, Lumen.Space.s4)
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .workbenchPaneBackground(.editor)
        .dsPaletteRoot()
        .dsDensityRoot()
    }

    func testTheDisassemblyPaneIsOneSurface() {
        for scheme in [ColorScheme.dark, .light] {
            let findings = LumenConformance.surfaceSteps(
                sizes: [Self.size], variant: .init(themeID: MacScopeThemes.scopeID, colorScheme: scheme),
                registry: .macScope
            ) { pane() }
            XCTAssertEqual(findings.map(\.description), [], "\(scheme)")
        }
    }

    /// The check isn't vacuous: the old listing's inset bands are reported.
    func testTheCheckReportsInsetBands() {
        let findings = LumenConformance.surfaceSteps(
            sizes: [Self.size], variant: .init(themeID: MacScopeThemes.scopeID, colorScheme: .dark), registry: .macScope
        ) { pane(rowsInset: Lumen.Space.s5) }
        XCTAssertFalse(findings.isEmpty)
    }
}
