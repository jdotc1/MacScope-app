import Foundation
import XCTest
@testable import MacScope

/// U7c: a type's users in the inspector, labelled by the function each sits in, and class
/// references (RX-02a `classref`) reading "class ref" with the class badge in the xref lists.
@MainActor
final class TypeAtlasUsersTests: XCTestCase {
    private static let functions = [
        FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x1040, confidence: 1),
        FunctionSummary(id: UUID(), name: "_helper", startAddress: 0x1040, endAddress: 0x1080, confidence: 1),
    ]

    func testUsersAreLabelledByTheirFunctionAndOffsetInAddressOrder() {
        let result = TypeAtlasInspectorReading.userRows([0x1044, 0x1000, 0x1014, 0x2000, 0x1014],
                                                        functions: Self.functions, name: \.name)
        XCTAssertEqual(result.rows.map(\.label), ["_main", "_main+0x14", "_helper+0x4", "0x0000000000002000"])
        XCTAssertEqual(result.rows.map(\.address), [0x1000, 0x1014, 0x1044, 0x2000], "sorted, duplicates once")
        XCTAssertEqual(result.notListed, 0)
    }

    func testALongUserListIsCappedAndSaysHowManyMore() {
        let users = (0..<60).map { 0x1000 + UInt64($0) * 4 }
        let result = TypeAtlasInspectorReading.userRows(users, functions: Self.functions, name: \.name)
        XCTAssertEqual(result.rows.count, TypeAtlasInspectorReading.userRowLimit)
        XCTAssertEqual(result.notListed, 10)
    }

    func testClassesAndUserTypesSayWhenNothingUsesThem() {
        func entry(_ kind: TypeAtlasKind, users: [UInt64] = []) -> TypeAtlasEntry {
            TypeAtlasEntry(id: TypeAtlasEntryID(slot: .primary, kind: kind, key: .name("T")), kind: kind, name: "T",
                           superclass: nil, members: [], conformances: [], methods: [], users: users, evidence: .descriptor)
        }
        XCTAssertTrue(TypeAtlasInspectorReading.listsUsers(entry(.objcClass)))
        XCTAssertTrue(TypeAtlasInspectorReading.listsUsers(entry(.userType)))
        XCTAssertFalse(TypeAtlasInspectorReading.listsUsers(entry(.objcProtocol)), "the Atlas doesn't look for protocol users")
        XCTAssertTrue(TypeAtlasInspectorReading.listsUsers(entry(.swiftStruct, users: [0x1000])))
    }

    func testClassReferencesReadAsClassRefsWithTheClassBadge() {
        XCTAssertEqual(XRefKindPresentation.tag(XRefKind.classref), "class ref")
        XCTAssertEqual(XRefKindPresentation.title(XRefKind.classref), "Class ref")
        XCTAssertEqual(XRefKindPresentation.objectKind(XRefKind.classref), .objcClass)
        for kind in [XRefKind.call, XRefKind.string, XRefKind.selref, XRefKind.data] {
            XCTAssertEqual(XRefKindPresentation.tag(kind), kind, "other kinds keep their names")
            XCTAssertEqual(XRefKindPresentation.title(kind), kind.capitalized)
            XCTAssertEqual(XRefKindPresentation.objectKind(kind), .xref)
        }
        for kind in [XRefKind.classref, XRefKind.call] {
            let symbol = XRefKindPresentation.objectKind(kind).symbol
            XCTAssertEqual(XRefKindPresentation.badgeKind(forRowSymbol: symbol), XRefKindPresentation.objectKind(kind))
        }

        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "a", path: "/tmp/a", kind: "Mach-O", architecture: "arm64")],
            functions: [], instructions: [],
            xrefs: [XRef(id: UUID(), from: 0x1000, to: 0x4010, kind: XRefKind.classref),
                    XRef(id: UUID(), from: 0x1004, to: 0x1040, kind: XRefKind.call)],
            hexBytes: Data()
        )
        let store = WorkspaceStore(workspaceName: "U7c", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectedTool = .xrefs
        XCTAssertEqual(store.sidebarItems.map(\.title), ["Class ref", "Call"])
        XCTAssertEqual(store.sidebarItems.map(\.systemImage), [DSObjectKind.objcClass.symbol, DSObjectKind.xref.symbol])
    }

    /// A real ObjC executable: `main`'s use of `Widget` is listed as a user inside `_main`.
    func testARealClassUserIsListedInsideMain() throws {
        let url = try HostCompilerFixture.objc("""
        #import <Foundation/Foundation.h>
        @interface Widget : NSObject - (int)computeValue; @end
        @implementation Widget - (int)computeValue { return 7; } @end
        int main(void) { Widget *w = [Widget new]; return [w computeValue]; }
        """)
        let snapshot = try AnalysisEngine().analyze(url: url)
        let slot = snapshot.primarySlot
        let widget = try XCTUnwrap(snapshot.typeCatalog(in: slot).entries(named: "Widget").first { $0.kind == .objcClass })
        let rows = TypeAtlasInspectorReading.userRows(widget.users, functions: snapshot.analysis(in: slot)?.functions ?? [],
                                                      name: \.name).rows
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.label.hasPrefix("_main") }, rows.map(\.label).joined(separator: ", "))
    }
}
