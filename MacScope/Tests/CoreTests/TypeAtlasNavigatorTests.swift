import Foundation
import XCTest
@testable import MacScope

/// U7a: the Types navigator over RX-02a's `ImageTypeCatalog`: one count section per kind in a
/// fixed order, `typeAtlas.<kind>:<key>` row ids that round-trip to their entries, a filter that
/// matches names and details, and a selection that drives the inspector without moving the editor.
@MainActor
final class TypeAtlasNavigatorTests: XCTestCase {
    private static func synthetic() -> WorkspaceSnapshot {
        var analysis = ImageAnalysis()
        analysis.objcClasses = [
            ObjCClass(name: "Widget", superclassName: "NSObject", adoptedProtocols: ["Pinger"], classMethods: [],
                      instanceMethods: [ObjCMethod(selector: "ping", typeEncoding: nil, isClassMethod: false, implementation: 0x1_0000_1000)],
                      ivars: [ObjCIvar(name: "_count", typeEncoding: "i", offset: 8, size: 4)],
                      properties: [], address: 0x1_0000_8000, instanceSize: 12),
        ]
        analysis.objcCategories = [
            ObjCCategory(name: "Extras", className: "Widget", classMethods: [], instanceMethods: [],
                         adoptedProtocols: [], properties: [], address: 0x1_0000_8100),
        ]
        analysis.swiftTypes = [
            SwiftTypeDescriptor(kind: .struct, name: "Point", fields: [SwiftField(name: "x", typeName: "Int")],
                                descriptorAddress: 0x1_0000_9000),
            SwiftTypeDescriptor(kind: .enum, name: "Mode", fields: [SwiftField(name: "on"), SwiftField(name: "off")],
                                descriptorAddress: 0x1_0000_9100),
        ]
        return WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "w", path: "/tmp/w", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis],
            typeDefinitions: [TypeDefinition(kind: .struct, name: "pair_s", fields: [FieldDef(name: "a", type: "int")])]
        )
    }

    private func store(_ snapshot: WorkspaceSnapshot) -> WorkspaceStore {
        let store = WorkspaceStore(workspaceName: "U7a", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectedTool = .types
        return store
    }

    func testSectionsFollowTheKindOrderAndRowIdsRoundTrip() throws {
        let catalog = Self.synthetic().typeCatalog(in: .primary)
        let items = TypeAtlasNavigator.items(for: catalog)
        XCTAssertEqual(items.filter(\.isSectionHeader).map(\.id), [
            "section:typeAtlas.objcClass", "section:typeAtlas.swiftStruct", "section:typeAtlas.swiftEnum",
            "section:typeAtlas.objcCategory", "section:typeAtlas.objcProtocol", "section:typeAtlas.userType",
        ], "empty kinds (Swift classes here) get no section")
        XCTAssertEqual(items.first { $0.title == "Widget" }?.id, "typeAtlas.objcClass:0x0000000100008000")
        XCTAssertEqual(items.first { $0.title == "pair_s" }?.id, "typeAtlas.userType:name:pair_s")

        let rows = items.filter { !$0.isSectionHeader }
        XCTAssertEqual(rows.count, catalog.entries.count)
        for row in rows {
            let entry = try XCTUnwrap(TypeAtlasNavigator.entry(forItemID: row.id, in: catalog), row.id)
            XCTAssertEqual(entry.name, row.title)
            XCTAssertEqual(TypeAtlasNavigator.kind(forItemID: row.id), entry.kind)
        }
        XCTAssertEqual(TypeAtlasNavigator.kind(forItemID: "section:typeAtlas.swiftEnum"), .swiftEnum)
        XCTAssertNil(TypeAtlasNavigator.kind(forItemID: "function:1234"))
        XCTAssertNil(TypeAtlasNavigator.entry(forItemID: "typeAtlas.objcClass:0xdead", in: catalog))
    }

    func testRowDetailsSayWhatTheTypeIsBuiltOnAndWhatIsKnown() throws {
        let catalog = Self.synthetic().typeCatalog(in: .primary)
        func detail(_ name: String) throws -> String {
            TypeAtlasNavigator.detail(for: try XCTUnwrap(catalog.entries(named: name).first, name))
        }
        XCTAssertEqual(try detail("Widget"), ": NSObject · 1 member · 1 method")
        XCTAssertEqual(try detail("Widget (Extras)"), "on Widget")
        XCTAssertEqual(try detail("Mode"), "2 cases")
        XCTAssertEqual(try detail("Pinger"), "Objective-C protocol", "name-only protocol")
    }

    func testTheFilterMatchesNamesAndDetailsAndSelectionDrivesTheInspector() throws {
        let store = store(Self.synthetic())
        XCTAssertEqual(store.sidebarItems, TypeAtlasNavigator.items(for: store.typeAtlasCatalog))
        store.sidebarSearchText = "nsobject"
        XCTAssertEqual(store.selectableVisibleSidebarItems.map(\.title), ["Widget"], "matches the superclass detail")
        store.sidebarSearchText = ""

        let addressBefore = store.selectedImageAddress
        let widgetID = "typeAtlas.objcClass:0x0000000100008000"
        store.activateSidebarItem(widgetID)
        XCTAssertEqual(store.selectedSidebarItemID, widgetID)
        XCTAssertEqual(store.selectedImageAddress, addressBefore, "selecting a type does not move the editor")
        let entry = try XCTUnwrap(store.selectedTypeAtlasEntry)
        XCTAssertEqual(entry.name, "Widget")

        let reading = TypeAtlasInspectorReading(entry)
        XCTAssertEqual(reading.title, "Widget")
        XCTAssertEqual(reading.rows.map(\.label),
                       ["Superclass", "Layout", "Conforms to", "Evidence"])
        XCTAssertEqual(reading.rows.first { $0.label == "Layout" }?.value, "12 bytes")

        XCTAssertFalse(store.activateSidebarItem(store.sidebarNavigationTarget(for: "typeAtlas.objcClass:0xdead")!),
                       "a row the catalog no longer has is refused")
        XCTAssertEqual(store.selectedSidebarItemID, widgetID)

        store.selectedTool = .symbols
        XCTAssertNil(store.selectedTypeAtlasEntry, "only the Types tool's selection drives the inspector")
    }

    func testLayoutIsStatedHonestly() throws {
        let catalog = Self.synthetic().typeCatalog(in: .primary)
        let point = try XCTUnwrap(catalog.entries(named: "Point").first)
        XCTAssertEqual(TypeAtlasInspectorReading.layout(point), "Unknown layout", "Swift field offsets are not read")
        let pair = try XCTUnwrap(catalog.entries(named: "pair_s").first)
        XCTAssertEqual(TypeAtlasInspectorReading.layout(pair), "Unknown size", "authored offsets, no recorded size")
        XCTAssertEqual(TypeAtlasInspectorReading(pair).rows.first { $0.label == "Evidence" }?.value, "Authored")
    }

    func testSwiftMethodLinksReachSelectedEntryWithoutMovingTheEditor() throws {
        var snapshot = Self.synthetic()
        let method = SwiftMetadataMethod(source: .vtable, index: 0, descriptorAddress: 0xa034,
                                         implementation: 0xb000, flags: 0x10)
        snapshot.analysisBySlot[.primary]?.swiftTypes.append(
            SwiftTypeDescriptor(kind: .class, name: "Runner", descriptorAddress: 0xa000, methods: [method])
        )
        snapshot.analysisBySlot[.primary]?.swiftConformances.append(
            SwiftConformance(typeName: "Runner", protocolName: "Running", descriptorAddress: 0xa100,
                             typeDescriptorAddress: 0xa000, methods: [
                                SwiftMetadataMethod(source: .witness, index: 0, descriptorAddress: 0xa200,
                                                    implementation: nil, flags: 0x11),
                             ])
        )
        let store = store(snapshot)
        let addressBefore = store.selectedImageAddress
        let row = try XCTUnwrap(store.sidebarItems.first { $0.title == "Runner" })
        store.activateSidebarItem(row.id)
        let entry = try XCTUnwrap(store.selectedTypeAtlasEntry)
        XCTAssertEqual(entry.id.key, .address(0xa000))
        XCTAssertEqual(entry.methods.first?.implementation, 0xb000)
        XCTAssertEqual(entry.methods.first?.swiftMetadata?.descriptorAddress, 0xa034)
        XCTAssertEqual(entry.swiftConformanceMethods?.first?.protocolName, "Running")
        XCTAssertNil(entry.swiftConformanceMethods?.first?.methods?.first?.implementation)
        XCTAssertEqual(store.selectedImageAddress, addressBefore)
    }

    /// The reconstruction C sample has no ObjC or Swift metadata: the navigator lists only the
    /// workspace's user types, and nothing invents a class.
    func testTheCSampleListsOnlyUserTypes() throws {
        let url = ReconstructionSourceRepairLoopbackTests.fixtureDirectory.appendingPathComponent("original-arm64")
        var snapshot = try AnalysisEngine().analyze(url: url)
        snapshot.typeDefinitions = [TypeDefinition(kind: .struct, name: "pair_s", fields: [FieldDef(name: "a", type: "int")])]
        let items = store(snapshot).sidebarItems
        XCTAssertEqual(items.filter(\.isSectionHeader).map(\.id), ["section:typeAtlas.userType"])
        XCTAssertEqual(items.filter { !$0.isSectionHeader }.map(\.title), ["pair_s"])
    }

    /// A real ObjC executable (compiled on the host; skipped without xcrun): its class is listed
    /// under Objective-C Classes, and selecting it shows the recorded instance size.
    func testARealObjCClassIsListedAndInspectable() throws {
        let url = try HostCompilerFixture.objc("""
        #import <Foundation/Foundation.h>
        @interface Widget : NSObject { @public int _count; double _ratio; }
        - (int)computeValue;
        @end
        @implementation Widget
        - (int)computeValue { return _count * 7 + 1; }
        @end
        int main(void) { Widget *w = [Widget new]; return [w computeValue]; }
        """)
        let store = store(try AnalysisEngine().analyze(url: url))
        let sectionIndex = try XCTUnwrap(store.sidebarItems.firstIndex { $0.id == "section:typeAtlas.objcClass" })
        let row = try XCTUnwrap(store.sidebarItems[(sectionIndex + 1)...].first { $0.title == "Widget" })
        XCTAssertTrue(row.id.hasPrefix("typeAtlas.objcClass:0x"), row.id)
        store.activateSidebarItem(row.id)
        let entry = try XCTUnwrap(store.selectedTypeAtlasEntry)
        XCTAssertEqual(entry.members.map(\.name), ["_count", "_ratio"])
        XCTAssertEqual(entry.members.map(\.offset), [8, 16])
        XCTAssertEqual(entry.members.map(\.evidence), [.descriptor, .descriptor])
        XCTAssertEqual(TypeAtlasInspectorReading.layout(entry), "24 bytes")
        XCTAssertFalse(entry.users.isEmpty, "main's [Widget new] uses the class")
    }
}
