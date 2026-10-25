import SwiftUI
import XCTest
@testable import LumenUI

@MainActor
final class LumenFormsTests: XCTestCase {
    func testNumberFieldClampsAndRoundsToTheStep() {
        XCTAssertEqual(LumenNumberField.normalized(1.26, range: 1...3, step: 0.1)!, 1.3, accuracy: 0.0001)
        XCTAssertEqual(LumenNumberField.normalized(9, range: 1...3, step: 0.1), 3)
        XCTAssertEqual(LumenNumberField.normalized(-2, range: 0...10, step: 1), 0)
        XCTAssertNil(LumenNumberField.normalized(nil, range: 0...10, step: 1))
        XCTAssertNil(LumenNumberField.normalized(.infinity, range: 0...10, step: 1))
    }

    /// R6 Components #5: the number field counts steps from the range's lower bound, as the slider does.
    func testNumberFieldStepsFromTheLowerBoundLikeTheSlider() {
        XCTAssertEqual(LumenNumberField.normalized(1 + 2, range: 1...9, step: 2), 3, "One step up from 1 is 3, not 4")
        XCTAssertEqual(LumenNumberField.nudged(1, by: 1, range: 1...9, step: 2), 3)
        XCTAssertEqual(LumenNumberField.normalized("4", range: 1...9, step: 2), 5, "Typed values land on 1, 3, 5, 7, 9")
        for fraction in stride(from: 0.0, through: 1, by: 0.05) {
            let track = LumenSlider.value(at: fraction, in: 1...9, step: 2)
            XCTAssertEqual(LumenNumberField.normalized(track, range: 1...9, step: 2), track, "The field keeps every track value")
        }
    }

    /// R6 API #2: the whole-number field works in Int, so it neither traps at Int.max nor loses
    /// precision past 2⁵³.
    func testWholeNumberFieldIsExactAcrossInt() {
        let all = Int.min...Int.max
        XCTAssertEqual(LumenNumberField.normalized(String(Int.max), range: 0...Int.max, step: 1), Int.max)
        XCTAssertEqual(LumenNumberField.nudged(Int.max, by: 1, range: 0...Int.max, step: 1), Int.max)
        XCTAssertEqual(LumenNumberField.nudged(Int.min, by: -1, range: all, step: 1), Int.min)
        XCTAssertEqual(LumenNumberField.nudged(Int.max - 1, by: 1, range: 0...Int.max, step: 1), Int.max)
        let big = (1 << 53) + 1   // not representable as a Double
        XCTAssertEqual(LumenNumberField.normalized(String(big), range: all, step: 1), big)
        XCTAssertEqual(LumenNumberField.nudged(big, by: 1, range: all, step: 1), big + 1)
        XCTAssertEqual(LumenNumberField.normalized("1e300", range: 0...Int.max, step: 1), Int.max, "Past Int is the top")
        XCTAssertEqual(LumenNumberField.normalized("-1e300", range: all, step: 1), Int.min)
        XCTAssertEqual(LumenNumberField.normalized("2.6", range: 0...10, step: 1), 3)
        XCTAssertNil(LumenNumberField.normalized("abc", range: 0...10, step: 1))
        // The grid across the whole range, where Int subtraction would overflow.
        XCTAssertEqual(LumenStepping.snapped(Int.max, in: all, step: 2), Int.max, "A step past the top clamps to the top")
        XCTAssertEqual(LumenStepping.snapped(0, in: all, step: 3), 1, "Counted from Int.min, the grid is 1 mod 3 at zero")
        XCTAssertEqual(LumenStepping.snapped(9, in: 0...9, step: 2), 9, "As the Double grid: round, then clamp")
        XCTAssertEqual(LumenNumberField.normalized(9, range: 0...9, step: 2), 9)
    }

    func testListEditorRefusesBlanksAndDuplicates() {
        XCTAssertEqual(LumenListEditor.adding(" Build/** ", to: ["*.swift"]), ["*.swift", "Build/**"])
        XCTAssertNil(LumenListEditor.adding("   ", to: []))
        XCTAssertNil(LumenListEditor.adding("*.swift", to: ["*.swift"]))
    }

    func testInheritedPickerNamesTheDefault() {
        XCTAssertEqual(LumenInheritedPicker<String>.label(for: nil, inherited: "HTML", defaultLabel: "Global Default", title: { $0 }),
                       "Global Default (HTML)")
        XCTAssertEqual(LumenInheritedPicker<String>.label(for: "Swift", inherited: "HTML", defaultLabel: "Default", title: { $0 }), "Swift")
    }

    func testSettingsSearchMatchesSettingNamesAndListsThem() {
        let pane = LumenSettingsCategory(id: "a", title: "Appearance", systemImage: "paintpalette", hue: .hueViolet,
                                         settings: ["Listing font", "Font size", "Density"]) { EmptyView() }
        XCTAssertTrue(pane.matches("dens"))
        XCTAssertEqual(pane.matchingSettings("font"), ["Listing font", "Font size"])
        XCTAssertEqual(pane.matchingSettings(""), [])
        XCTAssertFalse(pane.matches("python"))
    }
}
