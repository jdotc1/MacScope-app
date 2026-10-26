import Foundation
import SwiftUI
import XCTest
@testable import MacScope
@testable import MacScopeAnalysisCore

@MainActor
final class ImportedTypeLayoutProjectionTests: XCTestCase {
    private let target = "arm64-apple-macosx27.0"

    func testPackedBitfieldAndFlexibleTailUseRecordedFactsNotAuthoredLayout() throws {
        let archive = try fixture()
        let secondArchive = try fixture(configurationDigit: "c")
        let provider = try ImportedTypeLayoutProvider(archives: [archive, secondArchive, archive], expectedTarget: target)
        let identity = try XCTUnwrap(archive.identity(for: "record:Packed"))
        let entry = try XCTUnwrap(provider.entry(for: identity))

        // Deliberate mismatch: identical names, type spellings, widths and packed
        // authored rules yield bit 3 / tail byte 8. The saved fixture instead
        // records bit 11 / tail byte 9. It is a projection witness, not fresh
        // compiler evidence, and importing it must not repair those facts.
        let authored = TypeDefinition(kind: .struct, name: "Packed", fields: [
            FieldDef(name: "a", type: "unsigned int", bitWidth: 3),
            FieldDef(name: "b", type: "unsigned int", bitWidth: 31),
            FieldDef(name: "", type: "unsigned int", bitWidth: 0),
            FieldDef(name: "tail", type: "char[]"),
        ], layoutRules: AggregateLayoutRules(isPacked: true))
        let authoredLayout = authored.memberLayout(in: [authored.name: authored])
        XCTAssertEqual(authoredLayout[1].field.bitOffset, 3)
        XCTAssertEqual(authoredLayout.last?.offset, 8)
        XCTAssertEqual(entry.members.map(\.offset), [0, 1, 8, 9])
        XCTAssertEqual(entry.members.map { $0.imported?.absoluteBitOffset }, [0, 11, 64, 72])
        XCTAssertEqual(entry.members.map { $0.imported?.bitWidth }, [3, 31, 0, nil])
        XCTAssertEqual(entry.instanceSize, 9)
        XCTAssertEqual(entry.imported?.alignmentBytes, 1)
        XCTAssertEqual(entry.imported?.layoutStatus, "known")
        XCTAssertEqual(entry.evidence, .compilerImport)
        XCTAssertTrue(entry.members.allSatisfy { $0.evidence == .compilerImport })
        XCTAssertTrue(entry.members.allSatisfy { $0.size == nil }, "No invented bitfield allocation unit or flexible extent")
        XCTAssertEqual(entry.members.last?.imported?.flexibleArray, true)
        XCTAssertEqual(entry.members[1].imported?.typeIdentity,
                       archive.identity(for: "scalar:uint"))

        let unknown = try XCTUnwrap(provider.entry(for: try XCTUnwrap(archive.identity(for: "record:Unknown"))))
        XCTAssertNil(unknown.instanceSize)
        XCTAssertNil(unknown.members.first?.offset)
        XCTAssertNil(unknown.members.first?.imported?.absoluteBitOffset)
        XCTAssertEqual(unknown.imported?.layoutReason, "field offset unavailable")
        let union = try XCTUnwrap(provider.entry(for: try XCTUnwrap(archive.identity(for: "record:Union"))))
        XCTAssertEqual(union.members.map(\.offset), [0, 0])
        XCTAssertEqual(union.members.map(\.size), [4, 4])

        var snapshot = WorkspaceSnapshot(binaries: [BinaryImage(id: UUID(), name: "projection", path: "/projection", kind: "Mach-O", architecture: "arm64")], analysisBySlot: [.primary: ImageAnalysis()], typeDefinitions: [authored])
        let legacyCatalog = snapshot.typeCatalog(in: .primary)
        let catalog = snapshot.typeCatalog(in: .primary, importedTypes: provider)
        XCTAssertEqual(catalog.entries.filter { $0.kind != .importedType }, legacyCatalog.entries)
        XCTAssertEqual(catalog.entries(named: "Packed").count, 3, "One authored and two archive-qualified records")
        XCTAssertEqual(Set(catalog.entries(named: "Packed").map(\.id)).count, 3)
        XCTAssertEqual(catalog.including(importedTypes: provider), catalog, "Repeated injection does not duplicate records")
        XCTAssertEqual(snapshot.typeDefinitions, [authored], "Imported facts never enter the authored namespace")
        XCTAssertTrue(snapshot.typeCatalog(in: ImageSlot(rawValue: 99), importedTypes: provider).entries.isEmpty)
        XCTAssertEqual(provider.entry(for: identity, in: ImageSlot(rawValue: 2))?.id.slot, ImageSlot(rawValue: 2))
        XCTAssertThrowsError(try ImportedTypeLayoutProvider(archives: [archive], expectedTarget: "arm64e-apple-macosx27.0"))
        XCTAssertNil(provider.entry(for: ImportedTypeIdentity(archiveSHA256: identity.archiveSHA256, declarationID: "missing")))

        // Existing store/scripting callers can consume the injected image catalog
        // in memory. No workspace schema, package, importer control or file I/O.
        snapshot.analysisBySlot[.primary]?.typeCatalog = ImageTypeCatalog.empty(in: .primary).including(importedTypes: provider)
        XCTAssertEqual(snapshot.typeCatalog(in: .primary).entries.filter { $0.kind == .importedType }, provider.entries(in: .primary))
        let bounded = try WorkspaceScriptingAPI.snapshotTypeListRead(
            "list-image-types", arguments: .object(["kind": .string("importedType")]), snapshot: snapshot)
        XCTAssertEqual(bounded["types"]?.arrayValue?.count, provider.entries(in: .primary).count)
        let oversized = try ImportedTypeLayoutProvider(
            archives: [fixture(compilerVersion: String(repeating: "v", count: 2_049))], expectedTarget: target)
        var oversizedSnapshot = snapshot
        oversizedSnapshot.analysisBySlot[.primary]?.typeCatalog = ImageTypeCatalog.empty(in: .primary).including(importedTypes: oversized)
        XCTAssertThrowsError(try WorkspaceScriptingAPI.snapshotTypeListRead(
            "list-image-types", arguments: .object([:]), snapshot: oversizedSnapshot)) { error in
            guard case ScriptingError.invalidArgument(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("finite preparation or nested-result budget"))
        }
        let rowID = TypeAtlasNavigator.itemID(for: entry.id)
        XCTAssertEqual(TypeAtlasNavigator.kind(forItemID: rowID), .importedType)
        XCTAssertEqual(TypeAtlasNavigator.entry(forItemID: rowID, in: catalog), entry)
        let sidebar = try XCTUnwrap(TypeAtlasNavigator.items(for: catalog).first { $0.id == rowID })
        XCTAssertTrue(try XCTUnwrap(sidebar.detail).contains(identity.archiveSHA256))
        XCTAssertTrue(try XCTUnwrap(sidebar.detail).contains(target))

        let reading = TypeAtlasInspectorReading(entry)
        XCTAssertEqual(reading.members.map(\.offset), ["+0x0", "+0x1", "+0x8", "+0x9"])
        XCTAssertTrue(reading.members.allSatisfy(\.allowsWrapping))
        XCTAssertTrue(reading.rows.allSatisfy(\.allowsWrapping))
        XCTAssertEqual(reading.members[1].detail, "Absolute bit position: 11 · Bit width: 31")
        XCTAssertEqual(reading.members[1].typeDetail, "unsigned int\nAbsolute bit position: 11 · Bit width: 31")
        XCTAssertEqual(reading.members[2].detail, "Absolute bit position: 64 · Bit width: 0")
        XCTAssertEqual(reading.members.last?.detail, "Absolute bit position: 72 · Flexible-array extent: unknown")
        XCTAssertEqual(reading.rows.first { $0.label == "Archive" }?.value, identity.archiveSHA256)
        XCTAssertEqual(reading.rows.first { $0.label == "Source" }?.value, "projection-fixture.h:7:2")
        XCTAssertEqual(TypeAtlasInspectorReading(unknown).members.first?.detail, "Absolute bit position: unknown")
        XCTAssertEqual(TypeAtlasInspectorReading.layout(unknown), "Unknown layout")
        XCTAssertTrue(try XCTUnwrap(reading.layoutNote).contains("extent is unknown"))
        XCTAssertEqual(DSTypeMembersTable.offsetWidth, 44)
        XCTAssertNil(DSTableMiddleText(reading.members[1].typeDetail, allowsWrapping: true).effectiveLineLimit)
        XCTAssertNil(MetadataRow(label: "Archive", value: identity.archiveSHA256, allowsWrapping: true).effectiveLineLimit)
        XCTAssertNil(SidebarSingleLineText(lineLimit: 1, allowsWrapping: true).effectiveLineLimit)

        let json = WorkspaceScriptingAPI.typeAtlasEntryValue(entry)
        let members = try XCTUnwrap(json["members"]?.arrayValue)
        XCTAssertEqual(json["kind"], .string("importedType"))
        XCTAssertEqual(json["evidence"], .string("compilerImport"))
        XCTAssertEqual(json["instanceSize"], .int(9))
        XCTAssertEqual(json["imported"]?["archiveSHA256"], .string(identity.archiveSHA256))
        XCTAssertEqual(json["imported"]?["declarationID"], .string("record:Packed"))
        XCTAssertEqual(json["imported"]?["targetTriple"], .string(target))
        XCTAssertEqual(json["imported"]?["layoutStatus"], .string("known"))
        XCTAssertEqual(json["imported"]?["alignmentBytes"], .int(1))
        XCTAssertEqual(json["imported"]?["sourceLine"], .int(7))
        XCTAssertEqual(members[1]["offset"], .int(1), "Legacy byte offset remains a byte offset")
        XCTAssertEqual(members[1]["absoluteBitOffset"], .int(11))
        XCTAssertEqual(members[1]["bitWidth"], .int(31))
        XCTAssertEqual(members[2]["bitWidth"], .int(0))
        XCTAssertEqual(members[3]["absoluteBitOffset"], .int(72))
        XCTAssertEqual(members[3]["flexibleArray"], .bool(true))
        XCTAssertEqual(members[3]["extent"], .string("unknown"))
        XCTAssertNil(members[3]["size"])
        XCTAssertEqual(WorkspaceScriptingAPI.typeAtlasEntryValue(unknown)["members"]?.arrayValue?.first?["absoluteBitOffset"], .null)
    }

    func testLegacyAuthoredRowsKeepExistingTextPoliciesAndJSON() throws {
        let definition = TypeDefinition(kind: .struct, name: "Legacy", fields: [FieldDef(name: "value", type: "int")])
        let entry = try XCTUnwrap(ImageTypeCatalogBuilder.userTypeEntries(
            typeDefinitions: [definition], addressOverrides: [:], slot: .primary).first)
        let reading = TypeAtlasInspectorReading(entry)
        let member = try XCTUnwrap(reading.members.first)
        XCTAssertFalse(member.allowsWrapping)
        XCTAssertNil(member.detail)
        XCTAssertEqual(member.typeDetail, "int")
        XCTAssertTrue(reading.rows.allSatisfy { !$0.allowsWrapping })
        XCTAssertEqual(DSTableMiddleText(member.typeDetail).effectiveLineLimit, 1)
        XCTAssertEqual(DSTableMiddleText(member.typeDetail).truncationMode, .middle)
        XCTAssertEqual(MetadataRow(label: "Layout", value: "Unknown size").effectiveLineLimit, 2)
        XCTAssertEqual(MetadataRow(label: "Layout", value: String(repeating: "x", count: 80)).effectiveLineLimit, 4)
        XCTAssertEqual(MetadataRow(label: "Layout", value: "Unknown size").truncationMode, .middle)
        XCTAssertEqual(SidebarSingleLineText(lineLimit: AppSidebarChrome.rowTitleLineLimit).effectiveLineLimit, 1)
        XCTAssertEqual(SidebarSingleLineText(lineLimit: AppSidebarChrome.rowTitleLineLimit).truncationMode, .tail)
        XCTAssertEqual(TypeAtlasNavigator.detail(for: entry), "1 member")
        XCTAssertEqual(WorkspaceScriptingAPI.typeAtlasEntryValue(entry), .object([
            "id": .object(["slot": .int(0), "kind": .string("userType"), "name": .string("Legacy")]),
            "imageSlot": .int(0),
            "kind": .string("userType"), "name": .string("Legacy"), "superclass": .null,
            "members": .array([.object(["name": .string("value"), "type": .string("int"),
                                        "offset": .int(0), "evidence": .string("authored")])]),
            "conformances": .array([]), "methods": .array([]), "users": .array([]), "evidence": .string("authored"),
        ]))
    }

    /// Authored saved facts with deliberate gaps. No compiler or SDK is invoked.
    private func fixture(configurationDigit: Character = "a",
                         compilerVersion: String = "authored projection witness; not extraction evidence") throws -> SDKTypeArchive {
        let knownUInt: [String: Any] = ["status": "known", "sizeBytes": 4, "alignmentBytes": 4]
        func node(_ id: String, _ kind: String, _ spelling: String, _ layout: [String: Any],
                  extra: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["id": id, "kind": kind, "spelling": spelling, "layout": layout,
                                         "fields": [], "enumValues": [], "qualifiers": []]
            value.merge(extra) { _, new in new }
            return value
        }
        func field(_ id: String, _ name: String, _ type: String, _ offset: UInt64?,
                   width: UInt64? = nil, flexible: Bool = false) -> [String: Any] {
            var value: [String: Any] = ["id": id, "name": name, "typeID": type,
                                         "flexibleArray": flexible, "anonymous": false]
            if let offset { value["bitOffset"] = offset }
            if let width { value["bitWidth"] = width }
            return value
        }
        let types = [
            node("scalar:uint", "scalar", "unsigned int", knownUInt, extra: ["signed": false]),
            node("scalar:char", "scalar", "char", ["status": "known", "sizeBytes": 1, "alignmentBytes": 1], extra: ["signed": true]),
            node("array:tail", "array", "char[]", ["status": "unknown", "reason": "flexible extent"],
                 extra: ["elementTypeID": "scalar:char"]),
            node("record:Packed", "record", "Packed", ["status": "known", "sizeBytes": 9, "alignmentBytes": 1], extra: [
                "recordKind": "struct", "origin": ["header": "projection-fixture.h", "line": 7, "column": 2],
                "fields": [field("Packed/a", "a", "scalar:uint", 0, width: 3),
                           field("Packed/b", "b", "scalar:uint", 11, width: 31),
                           field("Packed/barrier", "", "scalar:uint", 64, width: 0),
                           field("Packed/tail", "tail", "array:tail", 72, flexible: true)],
            ]),
            node("record:Unknown", "record", "Unknown", ["status": "unknown", "reason": "field offset unavailable"], extra: [
                "recordKind": "struct", "fields": [field("Unknown/value", "value", "scalar:uint", nil)],
            ]),
            node("record:Union", "record", "Union", knownUInt, extra: ["recordKind": "union", "fields": [
                field("Union/a", "a", "scalar:uint", 0), field("Union/b", "b", "scalar:uint", 0),
            ]]),
        ]
        let document: [String: Any] = [
            "schema": "macscope.sdk-type-archive", "schemaMajor": 1, "schemaMinor": 0,
            "configurationID": String(repeating: String(configurationDigit), count: 64),
            "provenance": ["compiler": "fixture-clang", "compilerVersion": compilerVersion,
                           "libclangVersion": "fixture", "sdkIdentity": "fixture-sdk", "targetTriple": target,
                           "language": "c", "extractorVersion": "1", "input": "projection-fixture.h",
                           "inputSHA256": String(repeating: "b", count: 64), "arguments": []] as [String: Any],
            "diagnostics": ["Deliberately differs from authored layout; replay only."], "types": types,
        ]
        return try SDKTypeArchive.decode(JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), expectedTarget: target)
    }
}
