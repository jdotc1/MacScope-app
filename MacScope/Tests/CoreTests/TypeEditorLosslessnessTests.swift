import XCTest
@testable import MacScope

@MainActor
final class TypeEditorLosslessnessTests: XCTestCase {
    func testScriptingRichNoOpAndEquivalentLeavesPreserveCompletePersistence() throws {
        let field = FieldDef(name: "flags", type: "uint32_t", declaratorSemanticsV1: .ordinary,
                             bitWidth: 3)
        let definition = TypeDefinition(kind: .struct, name: "Packed", fields: [field],
            layoutRules: .init(isPacked: true, packAlignment: 2, minimumAlignment: 8))
        let store = store(containing: [definition])
        let api = WorkspaceScriptingAPI(store: store)
        _ = try api.execute("define-type", arguments: .object(["name": .string("Packed")]))
        XCTAssertEqual(store.snapshot.typeDefinitions, [definition])
        _ = try api.execute("define-type", arguments: .object([
            "name": .string("Packed"), "fields": .array([
                .object(["name": .string("flags"), "type": .string("uint32_t")])
            ])
        ]))
        XCTAssertEqual(store.snapshot.typeDefinitions, [definition])
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try store.saveWorkspace(to: database)
        let reloaded = try XCTUnwrap(database.loadWorkspaceState(workspaceID: try XCTUnwrap(saved.workspace.id)))
        XCTAssertEqual(reloaded.snapshot.typeDefinitions, [definition])
        let reopened = WorkspaceStore(workspaceName: "Reopened", snapshot: reloaded.snapshot,
                                      engine: AnalysisEngine(), autosaveScheduler: nil)
        XCTAssertEqual(reopened.snapshot.typeDefinitions, [definition])
    }

    func testScriptingRichReplacementRejectsWithoutMutatingOrFlattening() throws {
        let definition = TypeDefinition(kind: .struct, name: "Packed",
            fields: [ordinaryField("value", "uint32_t")], layoutRules: .init(isPacked: true))
        let store = store(containing: [definition])
        let api = WorkspaceScriptingAPI(store: store)
        for arguments: ScriptValue in [
            .object(["name": .string("Packed"), "kind": .string("union")]),
            .object(["name": .string("Packed"), "fields": .array([])]),
            .object(["name": .string("Packed"), "fields": .array([
                .object(["name": .string("value"), "type": .string("uint64_t")])
            ])]),
        ] {
            XCTAssertThrowsError(try api.execute("define-type", arguments: arguments))
            XCTAssertEqual(store.snapshot.typeDefinitions, [definition])
        }
    }

    func testPlainDefaultRecordWithOrdinaryProvenanceIsEditable() throws {
        let fixedArray = FieldDef(
            name: "words",
            type: "uint32_t[4]",
            declaratorSemanticsV1: .ordinary
        )
        let definition = TypeDefinition(
            kind: .struct,
            name: "Packet",
            fields: [
                FieldDef(name: "tag", type: "uint8_t", declaratorSemanticsV1: .ordinary),
                fixedArray,
            ]
        )
        let store = store(containing: [definition])

        store.beginTypeDefinition(editing: definition)

        let request = try XCTUnwrap(store.typeEditorRequest)
        XCTAssertEqual(request.original, definition)
        XCTAssertEqual(request.access, .editablePlainRecord)
        XCTAssertEqual(request.fields.map(\.original), definition.fields.map(Optional.some))
        XCTAssertEqual(request.fields.map(\.type), ["uint8_t", "uint32_t[4]"])

        // A fixed array is editable because the authoritative storage parser accepts it;
        // classification must not reject every spelling merely containing brackets.
        XCTAssertNoThrow(try NativeAuthoredFieldStorageParserV1.parse(
            field: fixedArray,
            position: .init(ownerKind: .struct, index: 1, count: 2),
            catalog: NativeAuthoredCatalogIndex(definitions: [definition])
        ))
    }

    func testExistingKindIsFixedAndNewDefinitionsAllowOnlyStructOrUnion() throws {
        let existing = TypeDefinition(
            kind: .struct,
            name: "Header",
            fields: [ordinaryField("magic", "uint32_t")]
        )
        let store = store(containing: [existing])
        store.beginTypeDefinition(editing: existing)
        var existingDraft = try XCTUnwrap(store.typeEditorRequest)

        // `kind` remains mutable draft state for SwiftUI, but the active request owns the
        // existing definition's immutable kind.
        existingDraft.kind = .union
        store.commitTypeEditor(existingDraft)
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.id == existing.id }?.kind, .struct)

        store.beginTypeDefinition()
        var invalidNewDraft = try XCTUnwrap(store.typeEditorRequest)
        invalidNewDraft.name = "NotARecord"
        invalidNewDraft.kind = .enum
        store.commitTypeEditor(invalidNewDraft)
        XCTAssertNotNil(store.typeEditorRequest)
        XCTAssertFalse(store.snapshot.typeDefinitions.contains { $0.name == "NotARecord" })

        store.cancelTypeEditor(try XCTUnwrap(store.typeEditorRequest))
        store.beginTypeDefinition()
        var unionDraft = try XCTUnwrap(store.typeEditorRequest)
        unionDraft.name = "Payload"
        unionDraft.kind = .union
        unionDraft.fields = [TypeFieldDraft(original: nil, name: "word", type: "uint64_t")]
        store.commitTypeEditor(unionDraft)
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.name == "Payload" }?.kind, .union)
    }

    func testEditingOnePlainLeafPreservesEveryUntouchedCompleteField() throws {
        let untouched = ordinaryField("flags", "uint32_t[4]")
        let edited = ordinaryField("length", "uint16_t")
        let definition = TypeDefinition(kind: .struct, name: "Header", fields: [edited, untouched])
        let store = store(containing: [definition])
        store.beginTypeDefinition(editing: definition)
        var request = try XCTUnwrap(store.typeEditorRequest)

        request.fields[0].name = "byteCount"
        request.fields[0].type = "uint64_t"
        store.commitTypeEditor(request)

        let committed = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.id == definition.id })
        XCTAssertEqual(committed.kind, definition.kind)
        XCTAssertEqual(committed.layoutRules, definition.layoutRules)
        XCTAssertEqual(committed.fields[1], untouched)
        XCTAssertEqual(committed.fields[0], ordinaryField("byteCount", "uint64_t"))
    }

    func testEditedPlainTypeIsReparsedAndPersistsOrdinaryProvenance() throws {
        let definition = TypeDefinition(
            kind: .struct,
            name: "Header",
            fields: [ordinaryField("value", "uint32_t")]
        )
        let store = store(containing: [definition])
        store.beginTypeDefinition(editing: definition)
        var request = try XCTUnwrap(store.typeEditorRequest)
        request.fields[0].type = "const uint64_t *"
        store.commitTypeEditor(request)

        let committed = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.id == definition.id })
        XCTAssertEqual(committed.fields[0].type, "const uint64_t *")
        XCTAssertEqual(committed.fields[0].declaratorSemanticsV1, .ordinary)

        // Empty leaves are errors, not an invitation to manufacture `field` / `int64_t`.
        store.beginTypeDefinition(editing: committed)
        var emptyLeaf = try XCTUnwrap(store.typeEditorRequest)
        emptyLeaf.fields[0].name = ""
        emptyLeaf.fields[0].type = ""
        store.commitTypeEditor(emptyLeaf)
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.id == definition.id }, committed)
        XCTAssertEqual(store.typeEditorRequest?.id, emptyLeaf.id)

        // Unicode whitespace is not normalized into a different authored spelling.
        var unicodeWhitespace = emptyLeaf
        unicodeWhitespace.fields[0].name = "\u{00a0}value"
        unicodeWhitespace.fields[0].type = "uint64_t\u{00a0}"
        store.commitTypeEditor(unicodeWhitespace)
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.id == definition.id }, committed)
        XCTAssertEqual(store.typeEditorRequest?.id, unicodeWhitespace.id)
    }

    func testRichRecordEnumAndTypedefAreReadOnly() throws {
        let inline = ordinaryField("inner", "uint16_t")
        let fixtures: [TypeDefinition] = [
            TypeDefinition(kind: .struct, name: "Packed", fields: [ordinaryField("x", "int")], layoutRules: .init(isPacked: true)),
            TypeDefinition(kind: .struct, name: "Bits", fields: [FieldDef(name: "x", type: "uint32_t", declaratorSemanticsV1: .ordinary, bitWidth: 3)]),
            TypeDefinition(kind: .struct, name: "NumericAligned", fields: [FieldDef(name: "x", type: "uint32_t", declaratorSemanticsV1: .ordinary, minimumAlignment: 16)]),
            TypeDefinition(kind: .struct, name: "TypeAligned", fields: [FieldDef(name: "x", type: "uint32_t", declaratorSemanticsV1: .ordinary, minimumAlignmentType: "uint64_t")]),
            TypeDefinition(kind: .struct, name: "Inline", fields: [FieldDef(name: "part", type: "unused", declaratorSemanticsV1: .ordinary, inlineAggregateKind: .struct, inlineFields: [inline])]),
            TypeDefinition(kind: .struct, name: "Promoted", fields: [FieldDef(name: "", type: "unused", declaratorSemanticsV1: .ordinary, inlineAggregateKind: .union, inlineFields: [inline], promotesInlineFields: true)]),
            TypeDefinition(kind: .struct, name: "Flexible", fields: [ordinaryField("bytes", "uint8_t[]")]),
            TypeDefinition(kind: .struct, name: "Carrier", fields: [FieldDef(name: "callback", type: "void *", declaratorSemanticsV1: .functionPointerCarrier)]),
            TypeDefinition(kind: .struct, name: "Legacy", fields: [FieldDef(name: "pointer", type: "void *")]),
            TypeDefinition(kind: .enum, name: "Mode", fields: [ordinaryField("Enabled", "1")]),
            TypeDefinition(kind: .typedef, name: "Word", fields: [ordinaryField("Word", "uint64_t")]),
        ]
        let store = store(containing: fixtures)

        for definition in fixtures {
            store.beginTypeDefinition(editing: definition)
            let request = try XCTUnwrap(store.typeEditorRequest)
            guard case .readOnlyRichDefinition(let reason) = request.access else {
                return XCTFail("Expected \(definition.name) to be read-only, got \(request.access)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testOpeningCancellingAndAttemptedReadOnlyCommitAreEquatablePreserving() throws {
        let first = TypeDefinition(
            kind: .struct,
            name: "Packed",
            fields: [ordinaryField("value", "uint32_t")],
            layoutRules: .init(isPacked: true, packAlignment: 2, minimumAlignment: 8)
        )
        let second = TypeDefinition(kind: .enum, name: "Mode", fields: [ordinaryField("Enabled", "1")])
        let store = store(containing: [first, second])
        let baseline = store.snapshot.typeDefinitions
        let baselineGeneration = store.mutationGeneration
        store.undoManager.removeAllActions()

        store.beginTypeDefinition(editing: first)
        var stale = try XCTUnwrap(store.typeEditorRequest)
        stale.name = "DestructiveRename"
        stale.fields = []
        store.commitTypeEditor(stale)
        XCTAssertEqual(store.snapshot.typeDefinitions, baseline)
        XCTAssertEqual(store.typeEditorRequest?.id, stale.id)
        XCTAssertEqual(store.mutationGeneration, baselineGeneration)
        XCTAssertFalse(store.undoManager.canUndo)

        store.beginTypeDefinition(editing: second)
        let current = try XCTUnwrap(store.typeEditorRequest)
        let exportedStaleRequest = TypeEditorExportObservation()
        let observer = NotificationCenter.default.addObserver(
            forName: .macScopeExportRenderedTypeDefinition,
            object: nil,
            queue: nil
        ) { note in
            exportedStaleRequest.value = note.object as? RenderedTypeDefinitionExportRequest
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.requestRenderedCExport(stale)
        store.deleteTypeEditorDefinition(stale)
        store.cancelTypeEditor(stale)
        store.commitTypeEditor(stale)
        XCTAssertNil(exportedStaleRequest.value)
        XCTAssertEqual(store.snapshot.typeDefinitions, baseline)
        XCTAssertEqual(store.typeEditorRequest, current)
        XCTAssertEqual(store.mutationGeneration, baselineGeneration)
        XCTAssertFalse(store.undoManager.canUndo)

        store.cancelTypeEditor(current)
        XCTAssertNil(store.typeEditorRequest)
        XCTAssertEqual(store.snapshot.typeDefinitions, baseline)
        XCTAssertEqual(store.mutationGeneration, baselineGeneration)
    }

    func testReadOnlyDefinitionOffersRenderedDeclarationExportAndDelete() throws {
        let definition = TypeDefinition(
            kind: .enum,
            name: "Mode",
            fields: [ordinaryField("Off", "0"), ordinaryField("On", "1")]
        )
        let store = store(containing: [definition])
        store.beginTypeDefinition(editing: definition)
        let request = try XCTUnwrap(store.typeEditorRequest)
        let received = TypeEditorExportObservation()
        let observer = NotificationCenter.default.addObserver(
            forName: .macScopeExportRenderedTypeDefinition,
            object: nil,
            queue: nil
        ) { note in
            received.value = note.object as? RenderedTypeDefinitionExportRequest
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        XCTAssertEqual(TypeEditorSheet.renderedCExportButtonTitle, "Export Rendered C…")
        store.requestRenderedCExport(request)

        let export = try XCTUnwrap(received.value)
        XCTAssertEqual(export.typeID, definition.id)
        XCTAssertEqual(export.suggestedFileName, "Mode.h")
        XCTAssertEqual(export.contents, CTypeHeaderRenderer.renderType(definition))
        XCTAssertFalse(export.contents.contains("/"), "the typed payload must not invent a filesystem path")
        XCTAssertEqual(store.snapshot.typeDefinitions, [definition])

        store.deleteTypeEditorDefinition(request)
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty)
        XCTAssertNil(store.typeEditorRequest)
    }
}

private extension TypeEditorLosslessnessTests {
    func ordinaryField(_ name: String, _ type: String) -> FieldDef {
        FieldDef(name: name, type: type, declaratorSemanticsV1: .ordinary)
    }

    func store(containing definitions: [TypeDefinition]) -> WorkspaceStore {
        let store = WorkspaceStore.bootstrapForPreviewFixture()
        for definition in definitions {
            store.upsertTypeDefinition(definition)
        }
        return store
    }
}

private final class TypeEditorExportObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: RenderedTypeDefinitionExportRequest?

    var value: RenderedTypeDefinitionExportRequest? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
