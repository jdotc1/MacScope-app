import SwiftUI
import XCTest
import LumenTokens
@testable import LumenUI

@MainActor
final class LumenBranchLaneTests: XCTestCase {
    func testNestedJumpsTakeOuterColumnsAndDisjointOnesShare() {
        let lanes = [
            LumenBranchLane(fromRow: 0, toRow: 10),   // long, encloses the loop
            LumenBranchLane(fromRow: 6, toRow: 4),    // short loop
            LumenBranchLane(fromRow: 12, toRow: 14),  // after both, overlaps neither
        ]
        XCTAssertEqual(LumenBranchLanes.columns(for: lanes, maximum: 4), [1, 0, 0])
    }

    func testColumnsStopAtTheMaximum() {
        let lanes = (0..<6).map { LumenBranchLane(fromRow: 0, toRow: 10 + $0) }
        XCTAssertEqual(LumenBranchLanes.columns(for: lanes, maximum: 3).max(), 2)
    }

    /// The selection is a step above the current-block band, a patch never
    /// outweighs it, and the program counter's bar is its own token.
    @MainActor
    func testRowStatesKeepTheSelectionStrongest() {
        let palette = TestPack.store(registry: LumenRegistry(packs: [.core, .code])).resolvedPalette()
        let selectedInBlock = LumenListingRowState(isSelected: true, isInCurrentBlock: true)
        XCTAssertEqual(selectedInBlock.background(palette), palette[.bgSelected])
        XCTAssertEqual(selectedInBlock.background(palette, isActiveWindow: false), palette[.bgSelectedInactive])
        XCTAssertNotEqual(selectedInBlock.background(palette), LumenListingRowState(isInCurrentBlock: true).background(palette))
        XCTAssertEqual(LumenListingRowState(isPatched: true).background(palette), palette[LumenToken.Code.changedBackground])
        XCTAssertEqual(LumenListingRowState(isSelected: true, isPatched: true).background(palette), palette[.bgSelected])
        // GB-03: a patch is never color alone; its dashed mark shows beside the selection's bar too.
        XCTAssertEqual(LumenListingRowState(isSelected: true, isPatched: true).patchMark(palette), palette[.statusInfo])
        XCTAssertNil(LumenListingRowState(isSelected: true).patchMark(palette))
        XCTAssertEqual(LumenListingRowState(isProgramCounter: true, tag: .orange).leadingBar(palette),
                       palette[LumenToken.Code.programCounter])
    }

    /// The hanging console gutter and hex cells follow the code font's measured advance.
    func testDigitAdvanceIsMeasured() {
        let standard = LumenCodeFont.standard.digitAdvance
        XCTAssertGreaterThan(standard, 5)
        XCTAssertGreaterThan(LumenCodeFont(family: nil, size: 18).digitAdvance, standard)
    }

    /// A tree's types are one column, needing room for every row's name and type.
    func testVariableTypeColumnCoversEveryRow() throws {
        let variables = [
            LumenVariable(id: "a", name: "self", type: "Parser", value: "0x1"),
            LumenVariable(id: "b", depth: 2, name: "magic", type: "UnsafePointer<Header>", value: "0x2"),
            LumenVariable(id: "c", name: "untyped", value: "3"),
        ]
        let column = try XCTUnwrap(LumenVariableTree.typeColumn(for: variables, metrics: .standard, codeFont: .standard))
        XCTAssertGreaterThan(column.nameColumn, 2 * LumenVariableRow.guideWidth(.standard))
        XCTAssertGreaterThan(column.requiredWidth, column.nameColumn + LumenVariableTree.valueRoom)
        XCTAssertNil(LumenVariableTree.typeColumn(for: [variables[2]], metrics: .standard, codeFont: .standard))
    }

    /// GB-30 / L10: the deepest name keeps an s5 gap to the type column (the row adds its s2 spacing).
    func testVariableTypeColumnKeepsAGutterAfterTheDeepestName() throws {
        let metrics = LumenMetrics.standard
        let deep = LumenVariable(id: "b", depth: 2, name: "magic", type: "UInt32", value: "0x2")
        let column = try XCTUnwrap(LumenVariableTree.typeColumn(for: [deep], metrics: metrics, codeFont: .standard))
        let name = ceil(("magic" as NSString).size(withAttributes: [.font: LumenCodeFont.standard.nsFont(weight: .medium)]).width)
        let leading = 2 * LumenVariableRow.guideWidth(metrics) + LumenVariableRow.disclosureWidth + metrics.spacing.s2 + name
        XCTAssertEqual(column.nameColumn - leading + metrics.spacing.s2, metrics.spacing.s5, accuracy: 0.01)
    }

    func testStripChipMenuTakesTheMostUrgentTone() {
        XCTAssertEqual(LumenStatusStrip<EmptyView>.urgent([.statusInfo, .statusWarning]), .statusWarning)
        XCTAssertEqual(LumenStatusStrip<EmptyView>.urgent([.statusWarning, .statusDanger]), .statusDanger)
        XCTAssertEqual(LumenStatusStrip<EmptyView>.symbol(for: .statusWarning), "exclamationmark.triangle.fill")
    }
}
