import SwiftUI
import XCTest
import LumenTokens
import LumenUI
import LumenConformance

/// PRINCIPLES §7 (icon scale) and §8 (one surface per pane): each rule fails on the pattern it
/// targets and passes on the fix.
@MainActor
final class LumenVisualRulesTests: XCTestCase {
    let size = [CGSize(width: 420, height: 240)]

    func testAnIconOnlyTileSmallerThanTheHeaderTileIsReported() {
        let small = LumenConformance.iconScale(sizes: size) {
            HStack { LumenIconTile("cube", hue: .hueBlue, size: 20).lumenIconRole(.control) }
        }
        XCTAssertEqual(small.count, 1, "\(small)")
        XCTAssertTrue(small.first?.description.contains("needs 28 pt") ?? false, "\(small)")
        let fits = LumenConformance.iconScale(sizes: size) {
            HStack { LumenIconTile("cube", hue: .hueBlue, size: 28).lumenIconRole(.control) }
        }
        XCTAssertEqual(fits, [])
    }

    func testTheSidebarSwitcherMeetsTheIconScale() {
        let items = ["cube", "function", "ladybug"].map { LumenSidebarItem(id: $0, title: $0, systemImage: $0, hue: .hueBlue) }
        let findings = LumenConformance.iconScale(sizes: size) {
            LumenSidebarSwitcher(selection: .constant("cube"), items: items, shortcuts: false, style: .tiles).frame(width: 300)
        }
        XCTAssertEqual(findings, [])
    }

    func testAnInlineTileUnder16PointsIsReported() {
        let findings = LumenConformance.iconScale(sizes: size) { Label { Text("Row") } icon: { LumenIconTile("cube", hue: .hueBlue, size: 12) } }
        XCTAssertEqual(findings.count, 1, "\(findings)")
    }

    /// A tinted gutter beside the listing, and a band inset from the pane's edge: MacScope's staircase.
    func testATintedGutterAndAnInsetBandAreReported() {
        let findings = LumenConformance.surfaceSteps(sizes: size) {
            HStack(spacing: 0) {
                Color(red: 0.08, green: 0.07, blue: 0.16).frame(width: 60)
                VStack(spacing: 0) {
                    Color(red: 0.12, green: 0.11, blue: 0.24).frame(height: 40).padding(.leading, 40)
                    Color(red: 0.10, green: 0.10, blue: 0.21)
                }
            }
        }
        XCTAssertFalse(findings.isEmpty, "a staircase pane passed")
    }

    func testOneSurfaceWithHairlinesAndFullWidthBandsPasses() {
        let surface = Color(red: 0.10, green: 0.10, blue: 0.21)
        let findings = LumenConformance.surfaceSteps(sizes: size) {
            HStack(spacing: 0) {
                surface.frame(width: 60)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                surface
            }
            .overlay(alignment: .top) { Color(red: 0.16, green: 0.14, blue: 0.30).frame(height: 24).padding(.top, 60) }
        }
        XCTAssertEqual(findings, [])
    }
}

@MainActor
final class LumenSurfaceStepsTallPaneTests: XCTestCase {
    /// One 28 pt band inset from the pane's edge, in a 900 pt pane: still a step.
    func testAnInsetBandInATallPaneIsReported() {
        let findings = LumenConformance.surfaceSteps(sizes: [CGSize(width: 600, height: 900)]) {
            ZStack(alignment: .top) {
                Color(red: 0.10, green: 0.10, blue: 0.21)
                Color(red: 0.16, green: 0.14, blue: 0.30).frame(height: 28).padding(.leading, 40).padding(.top, 300)
            }
        }
        XCTAssertFalse(findings.isEmpty, "an inset band in a tall pane passed")
    }
}

@MainActor
final class LumenSectionRoleTests: XCTestCase {
    func testASectionTileUnderTheSectionSizeIsReported() {
        let small = LumenConformance.iconScale(sizes: [CGSize(width: 300, height: 100)]) {
            LumenIconTile("cube", hue: .hueBlue, size: 20).lumenIconRole(.section)
        }
        XCTAssertEqual(small.count, 1, "\(small)")
        let fits = LumenConformance.iconScale(sizes: [CGSize(width: 300, height: 100)]) {
            LumenInspectorSection("Overview", systemImage: "cube", hue: .hueGreen) { Text("x") }
        }
        XCTAssertEqual(fits, [])
    }
}
