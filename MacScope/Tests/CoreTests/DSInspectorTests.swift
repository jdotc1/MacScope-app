import Observation
import SwiftUI
import XCTest
@testable import MacScope

@MainActor
final class DSInspectorTests: XCTestCase {
    func testSectionStorageIdentitiesStayCompatibleAcrossTitleAndSelectionChanges() {
        let identities = [
            "selection", "function", "type", "switchHint", "data", "addressDetail",
            "segment", "crossReferences", "analysis", "breakpoints", "diagnostics", "typeAtlas",
            "typeMembers", "typeMethods", "typeUsers", "typeWitnesses", "typeProperties",
        ]
        XCTAssertEqual(DSInspectorSectionID.allCases.map(\.rawValue), identities)
        XCTAssertEqual(
            DSInspectorSectionID.allCases.map(\.sceneStorageKey),
            identities.map { "MacScope.inspector.section.\($0).expanded" }
        )
        XCTAssertEqual(Set(DSInspectorSectionID.allCases.map(\.sceneStorageKey)).count, 17)
        XCTAssertEqual(
            DSInspectorSectionID.allCases.map(\.accessibilityIdentifier),
            identities.map { "inspector.section.\($0)" }
        )
    }

    func testUnrestoredSectionDefaultsExpandedAndWritesThroughItsOwnerBinding() {
        @Bindable var choice = ExpansionChoice(isExpanded: DSInspectorExpansionPolicy.defaultExpanded)
        let binding = DSInspectorExpansionPolicy.binding(restored: $choice.isExpanded, override: nil)

        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertFalse(choice.isExpanded)
    }

    func testRecreatedBindingRetainsRestoredCollapseAndReexpansion() {
        @Bindable var sceneChoice = ExpansionChoice(isExpanded: false)
        let first = DSInspectorExpansionPolicy.binding(restored: $sceneChoice.isExpanded, override: nil)
        XCTAssertFalse(first.wrappedValue)

        let recreated = DSInspectorExpansionPolicy.binding(restored: $sceneChoice.isExpanded, override: nil)
        XCTAssertFalse(recreated.wrappedValue)
        recreated.wrappedValue = true

        let reopened = DSInspectorExpansionPolicy.binding(restored: $sceneChoice.isExpanded, override: nil)
        XCTAssertTrue(reopened.wrappedValue)
    }

    func testSnapshotOverrideDoesNotReadOrMutateRestoredExpansionChoice() {
        @Bindable var sceneChoice = ExpansionChoice(isExpanded: false)
        @Bindable var snapshotChoice = ExpansionChoice(isExpanded: true)
        let snapshot = DSInspectorExpansionPolicy.binding(
            restored: $sceneChoice.isExpanded,
            override: $snapshotChoice.isExpanded
        )

        XCTAssertTrue(snapshot.wrappedValue)
        snapshot.wrappedValue = false
        XCTAssertFalse(snapshotChoice.isExpanded)
        snapshot.wrappedValue = true
        XCTAssertTrue(snapshotChoice.isExpanded)
        XCTAssertFalse(sceneChoice.isExpanded)

        let restored = DSInspectorExpansionPolicy.binding(restored: $sceneChoice.isExpanded, override: nil)
        XCTAssertFalse(restored.wrappedValue)
    }
}

@MainActor
@Observable
private final class ExpansionChoice {
    var isExpanded: Bool

    init(isExpanded: Bool) {
        self.isExpanded = isExpanded
    }
}
