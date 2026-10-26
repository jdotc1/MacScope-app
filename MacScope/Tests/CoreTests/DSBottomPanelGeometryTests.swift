import XCTest
@testable import MacScope

final class DSBottomPanelGeometryTests: XCTestCase {
    func testWholeAreaBudgetIncludesDividerAcrossWindowHeightsAndDragExtremes() {
        for height in stride(from: CGFloat(0), through: 2_000, by: 0.5) {
            for divider in [CGFloat(0.5), 1, 2, 4] {
                let geometry = DSBottomPanelGeometry(availableHeight: height, dividerHeight: divider)
                for requested in [CGFloat(-100), 0, 48, 148, 10_000] {
                    let bottom = geometry.wholeBottomHeight(preferredHeight: requested, isPresented: true)
                    XCTAssertTrue(bottom.isFinite)
                    XCTAssertGreaterThanOrEqual(bottom, 0)
                    XCTAssertLessThanOrEqual(bottom, height * 0.25 + 0.000_001)
                    XCTAssertGreaterThanOrEqual(height - bottom + 0.000_001, min(height, 360))
                    // Reproduce the pinned Lumen maximum calculation, including its
                    // minimum-wins behavior. The adapter's inputs must be feasible.
                    let lumenMaximum = max(
                        geometry.minimumPanelHeight,
                        min(height - 360 - divider, height * geometry.lumenMaximumFraction)
                    )
                    if geometry.canPresent {
                        XCTAssertLessThanOrEqual(lumenMaximum, geometry.maximumPanelHeight + 0.000_001)
                    }
                }
            }
        }
    }

    func testKnownMinimumViewportLeavesEditorAndDividerInsideBudget() {
        // Conservative inner height after the title/context/status bars at 1080 × 680.
        let geometry = DSBottomPanelGeometry(availableHeight: 540, dividerHeight: 1)
        XCTAssertEqual(geometry.maximumPanelHeight, 134)
        XCTAssertEqual(geometry.wholeBottomHeight(preferredHeight: 148, isPresented: true), 135)
        XCTAssertEqual(540 - geometry.wholeBottomHeight(preferredHeight: 148, isPresented: true), 405)
    }

    func testInsufficientHeightSuppressesPanelWithoutNegativeFrames() {
        for height in [CGFloat(-10), 0, 100, 359, 360, 408] {
            let geometry = DSBottomPanelGeometry(availableHeight: height, dividerHeight: 1)
            XCTAssertFalse(geometry.canPresent)
            XCTAssertEqual(geometry.wholeBottomHeight(preferredHeight: 148, isPresented: true), 0)
            XCTAssertGreaterThanOrEqual(geometry.minimumPanelHeight, 0)
            XCTAssertGreaterThanOrEqual(geometry.clampedPanelHeight(148), 0)
        }
        XCTAssertTrue(DSBottomPanelGeometry(availableHeight: 409, dividerHeight: 1).canPresent)
    }

    func testNonfiniteInputsAndHiddenPanelProduceFiniteBounds() {
        for height in [CGFloat.nan, .infinity, -.infinity] {
            let geometry = DSBottomPanelGeometry(availableHeight: height, dividerHeight: .nan)
            XCTAssertEqual(geometry.availableHeight, 0)
            XCTAssertEqual(geometry.dividerHeight, 0)
            XCTAssertEqual(geometry.clampedPanelHeight(.nan), 0)
        }
        let geometry = DSBottomPanelGeometry(availableHeight: 800, dividerHeight: 1)
        XCTAssertEqual(geometry.wholeBottomHeight(preferredHeight: 148, isPresented: false), 0)
        XCTAssertTrue(geometry.clampedPanelHeight(.infinity).isFinite)
    }
}
