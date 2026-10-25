import XCTest
import LumenTokens
@testable import LumenUI

@MainActor final class LumenEditorsTests: XCTestCase {
    /// R6 Components #5: a typed value lands on the track's grid.
    func testSliderFieldSnapsTypedValuesToTheStep() {
        XCTAssertEqual(LumenSlider.typed(3, in: 0...10, step: 2), 4)
        XCTAssertEqual(LumenSlider.typed(2.9, in: 1...9, step: 2), 3)
        XCTAssertEqual(LumenSlider.typed(42, in: 0...10, step: 2), 10)
        XCTAssertEqual(LumenSlider.typed(3.3, in: 0...10, step: nil), 3.3)
    }

    func testSliderSnapsAndClamps() {
        XCTAssertEqual(LumenSlider.value(at: 0.38, in: 0...120, step: 15), 45)
        XCTAssertEqual(LumenSlider.value(at: 1.4, in: 0...120, step: 15), 120)
        XCTAssertEqual(LumenSlider.value(at: -0.2, in: 0...1, step: nil), 0)
        XCTAssertEqual(LumenSlider.value(at: 0.25, in: 0...1, step: nil), 0.25, accuracy: 0.0001)
        XCTAssertEqual(LumenSlider.format(45), "45")
        XCTAssertEqual(LumenSlider.format(0.3), "0.3")
    }

    func testNewKeysSkipTakenOnes() {
        let entries = [LumenKeyValue(key: "key1", value: ""), LumenKeyValue(key: "key2", value: "")]
        XCTAssertEqual(LumenKeyValue.newKey(among: entries), "key3")
        XCTAssertEqual(LumenKeyValue.newKey(among: []), "key1")
    }

    func testConditionsInsertAfterTheirRow() {
        let a = LumenRuleCondition(field: "Name", comparison: "is", value: "a")
        let b = LumenRuleCondition(field: "Name", comparison: "is", value: "b")
        let inserted = LumenRuleEditor.inserting(after: a.id, into: [a, b], field: "Name", comparison: "is")
        XCTAssertEqual(inserted.count, 3)
        XCTAssertEqual(inserted[0].id, a.id)
        XCTAssertEqual(inserted[2].id, b.id)
        XCTAssertEqual(LumenRuleEditor.inserting(after: nil, into: [a], field: "Size", comparison: ">").last?.field, "Size")
    }

    func testValueTypesHaveGlyphs() {
        XCTAssertEqual(LumenValueType.allCases.count, 6)
        XCTAssertEqual(LumenValueType.object.systemImage, "ellipsis.curlybraces")
        XCTAssertEqual(LumenValueType.boolean.title, "Boolean")
    }
}
