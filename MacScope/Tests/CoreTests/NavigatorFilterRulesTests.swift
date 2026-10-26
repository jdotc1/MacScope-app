import Foundation
import LumenUI
import XCTest
@testable import MacScope

/// U8-3: the Symbols and Strings rule filters (`LumenRuleEditor`): how a condition reads a row, how
/// All/Any/None combine, and how the store narrows the navigator, keeping only headers with rows.
@MainActor
final class NavigatorFilterRulesTests: XCTestCase {
    private typealias Field = NavigatorFilterField

    private func rules(_ match: LumenRuleMatch = .all, _ conditions: (String, String, String)...) -> NavigatorFilterRules {
        var rules = NavigatorFilterRules(tool: .symbols)
        rules.match = match
        rules.conditions = conditions.map { LumenRuleCondition(field: $0.0, comparison: $0.1, value: $0.2) }
        return rules
    }

    func testTextComparisonsAreCaseInsensitiveAndEmptyValuesFilterNothing() {
        let row = [Field.name: "_objc_msgSend", Field.library: "/usr/lib/libobjc.A.dylib"]
        XCTAssertTrue(rules(.all, (Field.name, Field.contains, "MSGSEND")).matches(row))
        XCTAssertTrue(rules(.all, (Field.name, Field.beginsWith, "_objc")).matches(row))
        XCTAssertTrue(rules(.all, (Field.library, Field.endsWith, ".dylib")).matches(row))
        XCTAssertTrue(rules(.all, (Field.name, Field.isEqual, "_OBJC_MSGSEND")).matches(row))
        XCTAssertFalse(rules(.all, (Field.name, Field.doesNotContain, "msg")).matches(row))
        XCTAssertFalse(rules(.all, (Field.name, Field.beginsWith, "msg")).matches(row))

        let blank = rules(.all, (Field.name, Field.contains, "  "))
        XCTAssertFalse(blank.isActive, "a fresh rule with no value filters nothing")
        XCTAssertTrue(blank.matches(row))
        XCTAssertFalse(NavigatorFilterRules(tool: .strings).isActive)
    }

    /// The sidebar binding rebuilds a fresh rule on every read until the first edit stores it; the
    /// editor writes by the id it rendered, so that id must survive the rebuild (#399 live RED).
    func testAFirstEditThroughTheSidebarBindingLands() {
        var stored: [WorkspaceTool: NavigatorFilterRules] = [:]
        for tool in [WorkspaceTool.symbols, .strings] {
            let read = { stored[tool] ?? NavigatorFilterRules(tool: tool) }
            let rendered = read().conditions[0].id
            var rules = read()
            guard let index = rules.conditions.firstIndex(where: { $0.id == rendered }) else {
                XCTFail("\(tool): the rendered condition is found again on the next read")
                continue
            }
            rules.conditions[index].value = "main"
            stored[tool] = rules
            XCTAssertTrue(stored[tool]?.isActive == true)
        }
        XCTAssertNotEqual(NavigatorFilterRules.defaultConditionID(for: .symbols),
                          NavigatorFilterRules.defaultConditionID(for: .strings))
    }

    func testAllAnyAndNoneCombineTheConditions() {
        let row = [Field.name: "_main", Field.kind: "Symbol"]
        let both = [(Field.name, Field.contains, "main"), (Field.kind, Field.isEqual, "Import")]
        XCTAssertFalse(rules(.all, both[0], both[1]).matches(row))
        XCTAssertTrue(rules(.any, both[0], both[1]).matches(row))
        XCTAssertFalse(rules(.none, both[0], both[1]).matches(row))
        XCTAssertTrue(rules(.none, (Field.kind, Field.isEqual, "Import")).matches(row))
    }

    func testAddressesReadAsHexAndLengthsAsNumbers() {
        let row = [Field.address: 0x1_0000_3f00.hexAddress, Field.length: "12"]
        XCTAssertTrue(rules(.all, (Field.address, Field.greaterThan, "0x100000000")).matches(row))
        XCTAssertTrue(rules(.all, (Field.address, Field.isEqual, "100003f00")).matches(row))
        XCTAssertTrue(rules(.all, (Field.length, Field.lessThan, "20")).matches(row))
        XCTAssertFalse(rules(.all, (Field.length, Field.greaterThan, "12")).matches(row))
        XCTAssertFalse(rules(.all, (Field.address, Field.isEqual, "not hex")).matches(row), "an unreadable value matches nothing")
        XCTAssertFalse(rules(.all, (Field.address, Field.greaterThan, "0")).matches([:]), "a row without an address fails a numeric rule")
        XCTAssertEqual(Field.comparisons(for: Field.address), [Field.isEqual, Field.greaterThan, Field.lessThan])
    }

    func testStringTextAlsoOffersARegularExpression() {
        XCTAssertTrue(Field.comparisons(for: Field.text).contains(Field.matchesPattern))
        XCTAssertFalse(Field.comparisons(for: Field.name).contains(Field.matchesPattern))
        let row = [Field.text: "Error %d: %s"]
        XCTAssertTrue(rules(.all, (Field.text, Field.matchesPattern, #"%[ds]"#)).matches(row))
        XCTAssertFalse(rules(.all, (Field.text, Field.matchesPattern, #"^\d+$"#)).matches(row))
        XCTAssertFalse(rules(.all, (Field.text, Field.matchesPattern, "([")).matches(row), "an invalid pattern matches nothing")
    }

    private func store() -> WorkspaceStore {
        var analysis = ImageAnalysis()
        analysis.imports = [ImportSummary(id: UUID(), name: "_printf", libraryName: "/usr/lib/libSystem.B.dylib", libraryOrdinal: nil),
                            ImportSummary(id: UUID(), name: "_objc_msgSend", libraryName: "/usr/lib/libobjc.A.dylib", libraryOrdinal: nil)]
        analysis.exports = [ExportSummary(id: UUID(), name: "_main", address: 0x1_0000_3f00, source: "export trie")]
        analysis.stringLiterals = [
            StringLiteralSummary(id: UUID(), value: "Error %d", address: 0x1_0000_4000, sourceSection: "__cstring", byteLength: 9),
            StringLiteralSummary(id: UUID(), value: "Done", address: 0x1_0000_4010, sourceSection: "__cstring", byteLength: 5),
            StringLiteralSummary(id: UUID(), value: "objc", address: 0x1_0000_5000, sourceSection: "__objc_methname", byteLength: 5),
        ]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "f", path: "/tmp/f", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis]
        )
        return WorkspaceStore(workspaceName: "U8-3", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    func testSymbolRulesKeepOnlyMatchingRowsAndTheirHeaders() {
        let store = store()
        store.selectedTool = .symbols
        XCTAssertEqual(store.selectableVisibleSidebarItems.count, 3)
        store.navigatorFilterRules[.symbols] = rules(.all, (Field.kind, Field.isEqual, "Import"), (Field.library, Field.contains, "libobjc"))
        XCTAssertEqual(store.visibleSidebarItems.map(\.title), ["Imports", "_objc_msgSend"], "the Exports header goes with its rows")

        store.sidebarSearchText = "printf"
        XCTAssertEqual(store.selectableVisibleSidebarItems, [], "the text filter and the rules both apply")
        store.sidebarSearchText = ""

        store.selectedTool = .strings
        XCTAssertEqual(store.selectableVisibleSidebarItems.count, 3, "rules are per tool")
    }

    func testStringRulesFilterBySectionLengthAndAddress() {
        let store = store()
        store.selectedTool = .strings
        store.navigatorFilterRules[.strings] = rules(.all, (Field.section, Field.isEqual, "__cstring"), (Field.length, Field.greaterThan, "5"))
        XCTAssertEqual(store.selectableVisibleSidebarItems.map(\.title), ["Error %d"])
        store.navigatorFilterRules[.strings] = rules(.any, (Field.address, Field.greaterThan, "0x100004fff"), (Field.text, Field.isEqual, "done"))
        XCTAssertEqual(Set(store.selectableVisibleSidebarItems.map(\.title)), ["Done", "objc"])
        store.navigatorFilterRules[.strings] = rules(.all, (Field.text, Field.contains, "nothing like this"))
        XCTAssertEqual(store.visibleSidebarItems, [], "rules that hide everything leave the empty state, which offers Clear Rules")
    }
}
