import Foundation
import XCTest
@testable import MacScope

@MainActor
final class TypeLayoutPersistenceTests: XCTestCase {
    func testImportedUnknownOffsetsStayUnknownAfterDatabaseRoundTrip() throws {
        let recovered = [
            DWARFType(name: "Partial", kind: "struct", byteSize: 32, members: [
                DWARFTypeMember(name: "recorded", typeName: "char", byteOffset: 3),
                DWARFTypeMember(name: "missing", typeName: "int", byteOffset: nil),
                DWARFTypeMember(name: "unrepresentable", typeName: "int", byteOffset: UInt64.max),
                DWARFTypeMember(name: "tail", typeName: "int", byteOffset: 24),
            ]),
            DWARFType(name: "Unknown", kind: "union", byteSize: 8, members: [
                DWARFTypeMember(name: "value", typeName: "double", byteOffset: nil),
            ]),
        ]
        let imported = WorkspaceStore.typeDefinitions(from: recovered, existingTypeNames: [])
        XCTAssertTrue(imported.flatMap(\.fields).allSatisfy { $0.layoutSource == .dwarf })
        let authored = TypeDefinition(kind: .struct, name: "Authored", fields: [
            FieldDef(name: "a", type: "char"), FieldDef(name: "b", type: "int"),
        ])
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = imported + [authored]
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try database.saveSnapshot(workspaceName: "Unknown offsets", snapshot: snapshot, now: Date())
        let restored = try XCTUnwrap(database.loadWorkspaceState(workspaceID: try XCTUnwrap(saved.id)))
        XCTAssertEqual(restored.snapshot.typeDefinitions, snapshot.typeDefinitions.sorted { $0.name < $1.name })
        let catalog = restored.snapshot.typeCatalog(in: .primary)
        let partial = try XCTUnwrap(catalog.entries(named: "Partial").first)
        XCTAssertEqual(partial.members.map(\.offset), [3, nil, nil, 24])
        XCTAssertEqual(partial.members.map(\.evidence), [.descriptor, .unknown, .unknown, .descriptor])
        let unknown = try XCTUnwrap(catalog.entries(named: "Unknown").first)
        XCTAssertNil(unknown.members.first?.offset)
        XCTAssertEqual(unknown.members.first?.evidence, .unknown)
        XCTAssertEqual(TypeAtlasInspectorReading.layout(unknown), "Unknown layout")
        let authoredEntry = try XCTUnwrap(catalog.entries(named: "Authored").first)
        XCTAssertEqual(authoredEntry.members.map(\.offset), [0, 4])
        XCTAssertEqual(authoredEntry.members.map(\.evidence), [.authored, .authored])
    }

    func testFieldCodecsPreserveNestedOffsetsAndOptionalProvenance() throws {
        let fields = [FieldDef(name: "nested", type: "struct", inlineAggregateKind: .struct, inlineFields: [
            FieldDef(name: "known", type: "int", byteOffset: 12, layoutSource: .dwarf),
            FieldDef(name: "unknown", type: "int", layoutSource: .dwarf),
        ], byteOffset: 8, layoutSource: .dwarf)]
        XCTAssertEqual(try WorkspaceTypeDefinitionDatabaseCodec.decodeFields(
            WorkspaceTypeDefinitionDatabaseCodec.encodeFields(fields)), fields)
        XCTAssertEqual(try JSONDecoder().decode([FieldDef].self, from: JSONEncoder().encode(fields)), fields)
        let legacy = #"[{"name":"a","type":"char"},{"name":"b","type":"int"}]"#
        let decoded = try WorkspaceTypeDefinitionDatabaseCodec.decodeFields(legacy)
        XCTAssertTrue(decoded.allSatisfy { $0.byteOffset == nil && $0.layoutSource == nil })
        let encoded = try WorkspaceTypeDefinitionDatabaseCodec.encodeFields(decoded)
        XCTAssertFalse(encoded.contains("byteOffset"))
        XCTAssertFalse(encoded.contains("layoutSource"))
    }

    func testCP8MetadataSurvivesDatabaseSnapshotRoundTrip() throws {
        let definitions = [
            TypeDefinition(kind: .typedef, name: "Vector", fields: [
                FieldDef(name: "", type: "float", isAtomic: false),
            ], vectorByteSize: 16),
            TypeDefinition(kind: .enum, name: "Incomplete", fields: [
                FieldDef(name: "Known", type: "0"),
            ], enumValuesIncomplete: true),
            TypeDefinition(kind: .enum, name: "Complete", fields: [
                FieldDef(name: "Known", type: "0"),
            ], enumValuesIncomplete: false),
            TypeDefinition(kind: .struct, name: "Nested", fields: [
                FieldDef(name: "inner", type: "struct", isPacked: true,
                         inlineAggregateKind: .struct, inlineFields: [
                    FieldDef(name: "bits", type: "unsigned int", bitWidth: 3,
                             bitOffset: 5, isPacked: true, layoutIsUnknown: false, isAtomic: false),
                    FieldDef(name: "atomic", type: "int", isPacked: false, isAtomic: true),
                    FieldDef(name: "opaque", type: "Unknown", layoutIsUnknown: true),
                ]),
            ], layoutRules: AggregateLayoutRules(packAlignment: 2, minimumAlignment: 8)),
        ]
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = definitions
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try database.saveSnapshot(workspaceName: "CP8 metadata", snapshot: snapshot, now: Date())
        let restored = try XCTUnwrap(database.loadWorkspaceState(workspaceID: try XCTUnwrap(saved.id)))
        XCTAssertEqual(restored.snapshot.typeDefinitions, definitions.sorted { $0.name < $1.name })
        let catalog = Dictionary(uniqueKeysWithValues: restored.snapshot.typeDefinitions.map { ($0.name, $0) })
        XCTAssertEqual(TypeDefinition.size(ofType: "Vector", in: catalog), 16)
        XCTAssertNil(TypeDefinition.size(ofType: "Incomplete", in: catalog))
        XCTAssertNil(TypeDefinition.size(ofType: "Nested", in: catalog))

        // A second snapshot write consumes the restored representation, as a later Save does.
        let second = try database.saveWorkspaceState(
            workspaceID: try XCTUnwrap(saved.id), workspaceName: "CP8 resaved", snapshot: restored.snapshot,
            selectedSidebarItemID: nil, selectedAddress: nil, selectedTool: .project,
            editorMode: .disassembly, isInspectorPresented: true, sidebarSearchText: ""
        )
        XCTAssertEqual(second.workspace.uuid, saved.uuid)
        let resaved = try XCTUnwrap(database.loadWorkspaceState(workspaceID: try XCTUnwrap(second.workspace.id)))
        XCTAssertEqual(resaved.snapshot.typeDefinitions, restored.snapshot.typeDefinitions)
    }

    func testLegacyDatabaseTypeRowsKeepDefaultCP8Metadata() throws {
        var snapshot = AnalysisEngine.previewSnapshot()
        snapshot.typeDefinitions = []
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try database.saveSnapshot(workspaceName: "Legacy types", snapshot: snapshot, now: Date())
        let workspaceID = try XCTUnwrap(saved.id)
        let legacyRules = #"{"isPacked":false,"minimumAlignment":null,"packAlignment":null}"#
        for (name, rules) in [("LegacyNull", nil as String?), ("LegacyJSON", legacyRules)] {
            try database.insertTypeDefinition(.init(
                id: UUID(), workspaceID: workspaceID, kind: TypeKind.struct.rawValue,
                name: name, fieldsJSON: #"[{"name":"value","type":"int"}]"#,
                layoutRulesJSON: rules, createdAt: Date(), modifiedAt: Date()
            ))
        }
        let restored = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(restored.snapshot.typeDefinitions.count, 2)
        for type in restored.snapshot.typeDefinitions {
            XCTAssertEqual(type.layoutRules, .default)
            XCTAssertNil(type.vectorByteSize)
            XCTAssertNil(type.enumValuesIncomplete)
            XCTAssertEqual(type.fields, [FieldDef(name: "value", type: "int")])
            XCTAssertEqual(try WorkspaceTypeDefinitionDatabaseCodec.encodeTypeLayout(type), legacyRules)
        }
    }

    func testCP8LayoutEnvelopeRetainsLegacyValidation() throws {
        for json in [
            "{}",
            #"{"isPacked":false,"minimumAlignment":null,"packAlignment":null,"unknown":true}"#,
            #"{"isPacked":false,"minimumAlignment":null,"packAlignment":null,"vectorByteSize":"16"}"#,
            #"{"isPacked":false,"minimumAlignment":null,"packAlignment":null,"enumValuesIncomplete":1}"#,
        ] {
            XCTAssertThrowsError(try WorkspaceTypeDefinitionDatabaseCodec.decodeTypeLayout(json), json)
        }
    }

    func testScriptingUpsertsRetainCP8MetadataAndRejectLossyChanges() throws {
        let definitions = [
            TypeDefinition(kind: .typedef, name: "Vector", fields: [FieldDef(name: "element", type: "float")], vectorByteSize: 16),
            TypeDefinition(kind: .enum, name: "Incomplete", fields: [FieldDef(name: "Known", type: "0")], enumValuesIncomplete: true),
            TypeDefinition(kind: .struct, name: "Packed", fields: [FieldDef(name: "value", type: "int", isPacked: true)]),
            TypeDefinition(kind: .struct, name: "Unknown", fields: [FieldDef(name: "value", type: "int", layoutIsUnknown: true)]),
            TypeDefinition(kind: .struct, name: "Atomic", fields: [FieldDef(name: "value", type: "int", isAtomic: true)]),
            TypeDefinition(kind: .struct, name: "BitPosition", fields: [FieldDef(name: "value", type: "int", bitOffset: 3)]),
        ]
        for definition in definitions {
            var snapshot = AnalysisEngine.previewSnapshot()
            snapshot.typeDefinitions = [definition]
            let store = WorkspaceStore(workspaceName: "CP8 scripting", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
            let api = WorkspaceScriptingAPI(store: store)
            _ = try api.execute("define-type", arguments: .object(["name": .string(definition.name)]))
            XCTAssertEqual(store.snapshot.typeDefinitions, [definition])
            _ = try api.execute("define-type", arguments: .object([
                "name": .string(definition.name),
                "fields": .array(definition.fields.map { .object(["name": .string($0.name), "type": .string($0.type)]) }),
            ]))
            XCTAssertEqual(store.snapshot.typeDefinitions, [definition])
            XCTAssertThrowsError(try api.execute("define-type", arguments: .object([
                "name": .string(definition.name), "fields": .array([]),
            ])))
            XCTAssertEqual(store.snapshot.typeDefinitions, [definition])
        }
    }

    func testLegacyNativeFieldProjectionDeclinesUnrepresentableCP8Metadata() throws {
        let catalog = try NativeAuthoredCatalogIndex(definitions: [])
        let position = NativeAuthoredFieldPosition(ownerKind: .struct, index: 0, count: 1)
        let plain = FieldDef(name: "value", type: "int", declaratorSemanticsV1: .ordinary,
                             isPacked: false, layoutIsUnknown: false, isAtomic: false)
        XCTAssertNoThrow(try NativeAuthoredFieldStorageParserV1.parse(field: plain, position: position, catalog: catalog))
        var fields = [FieldDef]()
        var field = plain; field.bitOffset = 0; fields.append(field)
        field = plain; field.isPacked = true; fields.append(field)
        field = plain; field.layoutIsUnknown = true; fields.append(field)
        field = plain; field.isAtomic = true; fields.append(field)
        for field in fields {
            XCTAssertThrowsError(try NativeAuthoredFieldStorageParserV1.parse(field: field, position: position, catalog: catalog)) { error in
                XCTAssertEqual(error as? NativeAuthoredProjectionDiagnostic, .unsupported(id: .authoringInputUnsupported))
            }
            let nested = FieldDef(name: "inner", type: "struct", declaratorSemanticsV1: .ordinary,
                                  inlineAggregateKind: .struct, inlineFields: [field])
            XCTAssertThrowsError(try NativeAuthoredFieldStorageParserV1.parse(field: nested, position: position, catalog: catalog))
        }
    }

    func testLegacyNativeDefinitionProjectionDeclinesCP8VectorAndIncompleteEnum() throws {
        var snapshot = AnalysisEngine.previewSnapshot()
        let binary = try XCTUnwrap(snapshot.binaries.first)
        let function = try XCTUnwrap(snapshot.analysis(in: binary.slot)?.functions.first)
        let complete = TypeDefinition(kind: .enum, name: "E", fields: [FieldDef(name: "A", type: "0")], enumValuesIncomplete: false)
        // The native catalog is scoped to referenced definitions (04a29b865), so each
        // definition is referenced by the function's signature to exercise the decline.
        func referencing(_ name: String) {
            snapshot.addressOverrides[ImageAddress(slot: binary.slot, address: function.startAddress)] =
                AddressOverride(signature: FunctionSignatureOverride(returnType: name))
        }
        referencing("E")
        snapshot.typeDefinitions = [complete]
        if case .invalid(let diagnostic) = NativeDecompilerAuthoredInputProjector.project(workspace: snapshot, imageSlot: binary.slot, functionID: function.id) {
            XCTFail("Legacy-compatible false metadata was rejected: \(diagnostic)")
        }
        var incomplete = complete; incomplete.enumValuesIncomplete = true
        let vector = TypeDefinition(kind: .typedef, name: "Vector", fields: [FieldDef(name: "", type: "float", declaratorSemanticsV1: .ordinary)], vectorByteSize: 16)
        for definition in [incomplete, vector] {
            snapshot.typeDefinitions = [definition]
            referencing(definition.name)
            switch NativeDecompilerAuthoredInputProjector.project(workspace: snapshot, imageSlot: binary.slot, functionID: function.id) {
            case .valid: XCTFail("Unrepresentable metadata must not become a legacy wire definition")
            case .invalid(let diagnostic):
                guard case .unsupported(let identity) = diagnostic else {
                    return XCTFail("Expected unsupported metadata: \(diagnostic)")
                }
                XCTAssertEqual(identity.code, "authoring-input-unsupported")
                XCTAssertEqual(identity.subject, "type-catalog")
            }
        }
    }

    func testLegacyPartialDescriptorAndInvalidOffsetsNeverFallBackToABI() throws {
        let partial = TypeDefinition(kind: .struct, name: "Legacy", fields: [
            FieldDef(name: "known", type: "char", byteOffset: 0),
            FieldDef(name: "missing", type: "int"),
            FieldDef(name: "invalid", type: "int", byteOffset: -1),
        ])
        let entry = try XCTUnwrap(ImageTypeCatalogBuilder.userTypeEntries(
            typeDefinitions: [partial], addressOverrides: [:], slot: .primary).first)
        XCTAssertEqual(entry.members.map(\.offset), [0, nil, nil])
        XCTAssertEqual(entry.members.map(\.evidence), [.descriptor, .unknown, .unknown])
    }
}
