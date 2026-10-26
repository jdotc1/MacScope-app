import Foundation
import XCTest
@testable import MacScope

/// U7d: the user's own types in the Type Atlas: a type defined the usual way appears under User
/// Types at once with its authored layout, and its row and inspector open the existing editor.
/// "Define Type…" itself stays in the command palette and Go To.
@MainActor
final class TypeAtlasUserTypesTests: XCTestCase {
    private func store() -> WorkspaceStore {
        var analysis = ImageAnalysis()
        analysis.objcClasses = [ObjCClass(name: "Widget", superclassName: "NSObject", adoptedProtocols: [], classMethods: [],
                                          instanceMethods: [], ivars: [], properties: [], address: 0x1_0000_8000, instanceSize: 8)]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "w", path: "/tmp/w", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis],
            typeDefinitions: [TypeDefinition(kind: .struct, name: "pair_s", fields: [FieldDef(name: "a", type: "int")])]
        )
        let store = WorkspaceStore(workspaceName: "U7d", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectedTool = .types
        return store
    }

    func testAUserTypeRowOpensTheExistingEditorOnThatType() throws {
        let store = store()
        let row = try XCTUnwrap(store.sidebarItems.first { $0.title == "pair_s" })
        XCTAssertEqual(row.id, "typeAtlas.userType:name:pair_s")
        XCTAssertNil(store.typeEditorRequest)
        XCTAssertTrue(store.editTypeAtlasItem(row.id))
        let request = try XCTUnwrap(store.typeEditorRequest)
        XCTAssertEqual(request.original?.name, "pair_s")
        XCTAssertEqual(request.fields.map(\.name), ["a"])
    }

    func testOnlyUserTypesAreEditableFromTheAtlas() throws {
        let store = store()
        let widget = try XCTUnwrap(store.sidebarItems.first { $0.title == "Widget" })
        XCTAssertFalse(store.editTypeAtlasItem(widget.id), "image metadata isn't an authored type")
        XCTAssertNil(store.typeEditorRequest)
        let entry = try XCTUnwrap(store.typeAtlasCatalog.entries(named: "Widget").first)
        XCTAssertNil(store.typeDefinition(for: entry))
        XCTAssertFalse(store.editTypeAtlasItem("typeAtlas.userType:name:missing"))
    }

    func testATypeDefinedTheUsualWayAppearsInTheAtlasWithItsAuthoredLayout() throws {
        let store = store()
        let summary = store.defineTypesFromCHeader("struct point_s { int x; int y; };")
        XCTAssertEqual(summary.addedNames, ["point_s"], "\(summary)")
        let row = try XCTUnwrap(store.sidebarItems.first { $0.title == "point_s" })
        XCTAssertEqual(TypeAtlasNavigator.kind(forItemID: row.id), .userType)
        store.activateSidebarItem(row.id)
        let entry = try XCTUnwrap(store.selectedTypeAtlasEntry)
        let reading = TypeAtlasInspectorReading(entry)
        XCTAssertEqual(reading.members.map(\.offset), ["+0x0", "+0x4"])
        XCTAssertEqual(reading.members.map(\.evidence), ["Authored", "Authored"])
        XCTAssertNil(reading.layoutNote)
        XCTAssertNotNil(store.typeDefinition(for: entry), "the inspector offers Edit Type…")
    }
}
