import Foundation
import LumenUI
import XCTest
@testable import MacScope

/// U7b: the Type Atlas entry inspector's reading: the summary card, the members table with
/// honest offsets ("—" and an "Unknown layout" note where the metadata records none), methods
/// with their IMPs, and the superclass link that selects the class it names.
@MainActor
final class TypeAtlasInspectorTests: XCTestCase {
    private static func catalog() -> ImageTypeCatalog {
        var analysis = ImageAnalysis()
        analysis.objcClasses = [
            ObjCClass(name: "Base", superclassName: "NSObject", adoptedProtocols: [], classMethods: [], instanceMethods: [],
                      ivars: [], properties: [], address: 0x1_0000_8000, instanceSize: 8),
            ObjCClass(name: "Widget", superclassName: "Base", adoptedProtocols: ["Pinger"],
                      classMethods: [ObjCMethod(selector: "make", typeEncoding: nil, isClassMethod: true, implementation: 0x1_0000_1100)],
                      instanceMethods: [ObjCMethod(selector: "ping", typeEncoding: nil, isClassMethod: false, implementation: nil)],
                      ivars: [ObjCIvar(name: "_count", typeEncoding: "i", offset: 8, size: 4),
                              ObjCIvar(name: "_blob", typeEncoding: nil, offset: nil, size: nil)],
                      properties: [], address: 0x1_0000_8100, instanceSize: nil),
        ]
        analysis.swiftTypes = [
            SwiftTypeDescriptor(kind: .enum, name: "Mode", fields: [SwiftField(name: "on"), SwiftField(name: "off")],
                                descriptorAddress: 0x1_0000_9100),
        ]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "w", path: "/tmp/w", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis]
        )
        return snapshot.typeCatalog(in: .primary)
    }

    private func entry(_ name: String) throws -> TypeAtlasEntry {
        try XCTUnwrap(Self.catalog().entries(named: name).first, name)
    }

    func testTheSummaryCardNamesTheKindTheClassItBuildsOnAndTheCounts() throws {
        let reading = TypeAtlasInspectorReading(try entry("Widget"))
        XCTAssertEqual(reading.kind, "Objective-C class")
        XCTAssertEqual(reading.title, "Widget")
        XCTAssertEqual(reading.link, "Base")
        XCTAssertEqual(reading.detail, "0x0000000100008100 · Unknown layout")
        XCTAssertEqual(reading.stats, [LumenStat("Members", count: 2), LumenStat("Methods", count: 2), LumenStat("Users", count: 0)])
    }

    func testMembersShowKnownOffsetsAndMarkTheRestUnknown() throws {
        let reading = TypeAtlasInspectorReading(try entry("Widget"))
        XCTAssertEqual(reading.membersTitle, "Members")
        XCTAssertEqual(reading.members.map(\.offset), ["+0x8", "—"])
        XCTAssertEqual(reading.members.map(\.name), ["_count", "_blob"])
        XCTAssertEqual(reading.members.first?.type, "int")
        XCTAssertEqual(reading.members.last?.type, "—", "no encoding, no guessed type")
        XCTAssertEqual(reading.members.map(\.evidence), ["Compiler metadata", "Unknown"], "#441: a recorded ivar offset is descriptor evidence")
        XCTAssertEqual(reading.layoutNote, "Partly unknown layout: rows marked — have no offset recorded in the image.")
    }

    func testAnEnumWithoutOffsetsHasCasesAndAnUnknownLayoutNote() throws {
        let reading = TypeAtlasInspectorReading(try entry("Mode"))
        XCTAssertEqual(reading.membersTitle, "Cases")
        XCTAssertEqual(reading.members.map(\.offset), ["—", "—"])
        XCTAssertEqual(reading.layoutNote, "Unknown layout: the image records no offsets for these cases.")
        XCTAssertTrue(reading.methods.isEmpty)
        XCTAssertNil(TypeAtlasInspectorReading(try entry("Base")).layoutNote, "no members, nothing unknown")
    }

    func testMethodsCarryTheirKindAndImplementation() throws {
        let methods = TypeAtlasInspectorReading(try entry("Widget")).methods
        let bySignature = Dictionary(uniqueKeysWithValues: methods.map { ($0.signature, $0.implementation) })
        XCTAssertEqual(Set(bySignature.keys), ["+make", "-ping"])
        XCTAssertEqual(bySignature["+make"], 0x1_0000_1100)
        XCTAssertEqual(bySignature["-ping"], .some(nil), "no IMP in this image is shown, not invented")
    }

    func testTheSuperclassLinkSelectsThatClassInTheNavigator() throws {
        let catalog = Self.catalog()
        let widget = try XCTUnwrap(catalog.entries(named: "Widget").first)
        let base = try XCTUnwrap(catalog.entries(named: "Base").first)
        XCTAssertEqual(TypeAtlasInspectorReading.linkedItemID(for: widget, in: catalog), TypeAtlasNavigator.itemID(for: base.id))
        XCTAssertNil(TypeAtlasInspectorReading.linkedItemID(for: base, in: catalog), "NSObject isn't in this image")

        let store = WorkspaceStore(workspaceName: "U7b", snapshot: WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "w", path: "/tmp/w", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: {
                var analysis = ImageAnalysis()
                analysis.objcClasses = [base, widget].map { entry in
                    ObjCClass(name: entry.name, superclassName: entry.superclass, adoptedProtocols: [], classMethods: [],
                              instanceMethods: [], ivars: [], properties: [], address: entry.id.key.address, instanceSize: nil)
                }
                return analysis
            }()]
        ), engine: AnalysisEngine(), autosaveScheduler: nil)
        store.selectedTool = .types
        let widgetItem = try XCTUnwrap(store.sidebarItems.first { $0.title == "Widget" }).id
        store.activateSidebarItem(widgetItem)
        let selected = try XCTUnwrap(store.selectedTypeAtlasEntry)
        let link = try XCTUnwrap(TypeAtlasInspectorReading.linkedItemID(for: selected, in: store.typeAtlasCatalog))
        store.activateSidebarItem(link)
        XCTAssertEqual(store.selectedTypeAtlasEntry?.name, "Base")
    }

    // MARK: - C7: Swift method tables, protocol witnesses, protocol requirements and properties

    private func swiftMethod(_ source: SwiftMetadataMethod.Source, _ index: UInt64, implementation: UInt64?,
                             instance: Bool = true) -> TypeAtlasMethod {
        let record = SwiftMetadataMethod(source: source, index: index, descriptorAddress: 0x1_0000_a000 + index * 8,
                                         implementation: implementation, flags: instance ? 0x10 : 0x0)
        return TypeAtlasMethod(name: record.label, implementation: implementation,
                               isClassMethod: record.isInstance == false, swiftMetadata: record)
    }

    private func entry(_ kind: TypeAtlasKind, _ name: String, methods: [TypeAtlasMethod] = [],
                       witnesses: [TypeAtlasConformanceMethods]? = nil, tableResolved: Bool? = nil,
                       properties: [ObjCProperty]? = nil) -> TypeAtlasEntry {
        TypeAtlasEntry(id: TypeAtlasEntryID(slot: .primary, kind: kind, key: .name(name)), kind: kind, name: name,
                       superclass: nil, members: [], conformances: witnesses?.map(\.protocolName) ?? [],
                       methods: methods, users: [], evidence: .descriptor, declaredProperties: properties,
                       swiftConformanceMethods: witnesses, swiftMethodTableResolved: tableResolved)
    }

    func testSwiftTableRecordsAreNamedBySymbolOnlyWhenTheImageHasOne() {
        let reading = TypeAtlasInspectorReading(
            entry(.swiftClass, "Engine", methods: [
                swiftMethod(.vtable, 0, implementation: 0x1_0000_2000),
                swiftMethod(.override, 1, implementation: 0x1_0000_2100, instance: false),
                swiftMethod(.vtable, 2, implementation: nil),
            ], tableResolved: true),
            implementationNames: [0x1_0000_2000: "Engine.start() -> ()"]
        )
        XCTAssertEqual(reading.methods.map(\.signature),
                       ["Engine.start() -> ()", "override #1 (name unknown)", "vtable #2 (name unknown)"],
                       "a table records no source names; only a symbol at the implementation names a row")
        XCTAssertEqual(reading.methods.map(\.badge), ["vtable #0", "override · static", "vtable"])
        XCTAssertEqual(reading.methods.map(\.implementation), [0x1_0000_2000, 0x1_0000_2100, nil])
        XCTAssertNil(reading.methodsNote)
        XCTAssertEqual(TypeAtlasInspectorReading.swiftImplementationAddresses(
            entry(.swiftClass, "Engine", methods: [swiftMethod(.vtable, 0, implementation: 0x1_0000_2000)])),
            [0x1_0000_2000])
    }

    func testAnUnresolvedSwiftMethodTableIsSaidRatherThanShownEmpty() {
        let reading = TypeAtlasInspectorReading(entry(.swiftClass, "Opaque", tableResolved: false))
        XCTAssertTrue(reading.methods.isEmpty)
        XCTAssertEqual(reading.methodsNote, TypeAtlasInspectorReading.unresolvedMethodTableNote)
        XCTAssertNil(TypeAtlasInspectorReading(entry(.swiftStruct, "Plain")).methodsNote, "structs have no table")
    }

    func testWitnessTablesListPerProtocolAndSayWhenUnresolvedOrEmpty() {
        let reading = TypeAtlasInspectorReading(entry(.swiftStruct, "Runner", witnesses: [
            TypeAtlasConformanceMethods(protocolName: "Running", descriptorAddress: 0x1_0000_b000,
                                        methods: [swiftMethod(.witness, 0, implementation: 0x1_0000_3000)]),
            TypeAtlasConformanceMethods(protocolName: "Hashable", descriptorAddress: nil, methods: nil),
            TypeAtlasConformanceMethods(protocolName: "Marker", descriptorAddress: nil, methods: []),
        ]), implementationNames: [0x1_0000_3000: "Runner.run()"])
        XCTAssertEqual(reading.witnesses.map(\.protocolName), ["Running", "Hashable", "Marker"])
        XCTAssertEqual(reading.witnesses[0].methods.map(\.signature), ["Runner.run()"])
        XCTAssertEqual(reading.witnesses[0].methods.map(\.badge), ["witness #0"])
        XCTAssertNil(reading.witnesses[0].note)
        XCTAssertEqual(reading.witnesses[1].note, TypeAtlasInspectorReading.unresolvedWitnessTableNote)
        XCTAssertEqual(reading.witnesses[2].note, TypeAtlasInspectorReading.emptyWitnessTableNote)
    }

    func testProtocolRequirementsCarryRequiredOrOptionalAndPropertiesAreListed() {
        var optional = TypeAtlasMethod(name: "didFinish:", implementation: nil)
        optional.isOptionalRequirement = true
        var required = TypeAtlasMethod(name: "shared", implementation: nil, isClassMethod: true)
        required.isOptionalRequirement = false
        let reading = TypeAtlasInspectorReading(entry(.objcProtocol, "Delegate", methods: [required, optional],
            properties: [ObjCProperty(name: "title", attributes: "T@\"NSString\",C,N"), ObjCProperty(name: "raw", attributes: "")]))
        XCTAssertEqual(reading.methods.map(\.signature), ["+shared", "-didFinish:"])
        XCTAssertEqual(reading.methods.map(\.badge), ["required", "optional"])
        XCTAssertEqual(reading.methods.map(\.implementation), [nil, nil], "requirements never get an IMP")
        XCTAssertEqual(reading.properties.map(\.label), ["title", "raw"])
        XCTAssertEqual(reading.properties.map(\.value), ["T@\"NSString\",C,N", "—"])
    }

}

private extension TypeAtlasEntryID.Key {
    var address: UInt64? {
        if case .address(let address) = self { return address }
        return nil
    }
}
