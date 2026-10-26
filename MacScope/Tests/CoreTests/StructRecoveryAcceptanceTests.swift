import Foundation
import XCTest
@testable import MacScope

/// DP04 D2: accepting a usage-derived struct candidate through type authoring.
@MainActor
final class StructRecoveryAcceptanceTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let program: [(String, String)] = [
            ("ldr", "x1, [x0, #0x8]"), ("ldr", "w2, [x0, #0x8]"), ("str", "x3, [x0, #0x18]"),
            ("add", "x4, x0, #0x10"), ("ldr", "w5, [x4, #0x4]"), ("ret", ""),
        ]
        let rows = program.enumerated().map { index, pair in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: "", mnemonic: pair.0, operands: pair.1,
                           hasBreakpoint: false, comment: nil)
        }
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "t.bin", path: "/tmp/t.bin", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "_use", startAddress: 0x1000, endAddress: 0x1018, confidence: 1)],
            instructions: rows, xrefs: [], hexBytes: Data(),
            sections: [SectionSummary(id: UUID(), name: "__TEXT,__text", address: 0x1000, size: 0x200, fileOffset: 0x1000, isExecutable: true)]
        )
        return WorkspaceStore(workspaceName: "structs", snapshot: snapshot, engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    func testConfirmPersistEvidenceAndInvalidate() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let preview = try api.execute("recover-struct-candidate", arguments: .object([
            "function": .string("_use"), "parameter": .int(0),
        ]))
        let candidate = try XCTUnwrap(preview["candidate"]?.stringValue)
        XCTAssertEqual(preview["extentLowerBound"], .int(0x20))
        XCTAssertEqual(preview["conflicts"]?.arrayValue?.count, 1)
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty, "preview mutates nothing")
        XCTAssertFalse(store.undoManager.canUndo)

        let accept: (ScriptValue, ScriptValue) -> ScriptValue = { candidate, choices in
            .object(["function": .string("_use"), "parameter": .int(0), "candidate": candidate,
                     "name": .string("UseObject"), "choices": choices, "local": .string("-24:-16")])
        }
        XCTAssertThrowsError(try api.execute("accept-struct-candidate", arguments: accept(.string(candidate), .array([]))),
                             "an overlap needs an explicit choice")
        XCTAssertThrowsError(try api.execute("accept-struct-candidate", arguments: accept(
            .string("struct-candidate-v1:0"), .array([.object(["offset": .int(8), "width": .int(8)])]))),
            "stale evidence rejects")
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty)

        _ = try api.execute("accept-struct-candidate", arguments: accept(
            .string(candidate), .array([.object(["offset": .int(8), "width": .int(8)])])))
        let type = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.name == "UseObject" })
        XCTAssertTrue(type.layoutRules.isPacked)
        XCTAssertEqual(type.fields.map { "\($0.name):\($0.type)" }, [
            "_unknown_0x0:uint8_t[8]", "field_0x8:uint64_t", "_unknown_0x10:uint8_t[4]",
            "field_0x14:uint32_t", "field_0x18:uint64_t",
        ])
        let offsets = type.memberLayout().map { "\($0.field.name)@\($0.offset)" }
        XCTAssertEqual(offsets, ["_unknown_0x0@0", "field_0x8@8", "_unknown_0x10@16", "field_0x14@20", "field_0x18@24"])
        let provenance = try XCTUnwrap(type.inferenceProvenance, "the evidence is recorded apart from the layout")
        XCTAssertEqual(provenance.source, "usage-candidate-v1")
        XCTAssertEqual(provenance.candidateID, candidate)
        XCTAssertEqual(provenance.root, "param:x0")
        XCTAssertEqual(provenance.functionStart, 0x1000)
        XCTAssertEqual(provenance.fieldCount, 4)
        XCTAssertEqual(provenance.conflictCount, 1)
        XCTAssertEqual(provenance.observationCount, 4)
        XCTAssertEqual(provenance.extentLowerBound, 0x20)
        // Package DTO and database round trips keep the record; legacy types have none.
        let decoded = try JSONDecoder().decode(TypeDefinition.self, from: JSONEncoder().encode(type))
        XCTAssertEqual(decoded.inferenceProvenance, provenance)
        let legacy = try JSONDecoder().decode(TypeDefinition.self, from: JSONEncoder().encode(
            TypeDefinition(kind: .struct, name: "Legacy", fields: [FieldDef(name: "a", type: "int")])))
        XCTAssertNil(legacy.inferenceProvenance)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("structs.sqlite")
        let workspaceID: Int64
        do {
            let database = try WorkspaceDatabase(path: url.path)
            try database.applySchema()
            workspaceID = try XCTUnwrap(try database.saveSnapshot(workspaceName: "structs", snapshot: store.snapshot).id)
        }
        let reloaded = try XCTUnwrap(try WorkspaceDatabase(path: url.path).loadSnapshot(workspaceID: workspaceID))
        XCTAssertEqual(reloaded.typeDefinitions.first { $0.name == "UseObject" }?.inferenceProvenance, provenance)

        let slot = store.snapshot.primarySlot
        XCTAssertEqual(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: slot)["-24:-16"]?.typeName,
                       "UseObject *")
        XCTAssertThrowsError(try api.execute("accept-struct-candidate", arguments: accept(
            .string(candidate), .array([.object(["offset": .int(8), "width": .int(8)])]))), "the name is taken")

        // Redefining with identical fields keeps the record (a packed accepted type refuses a
        // lossy field replacement through define-type).
        _ = try api.execute("define-type", arguments: .object(["name": .string("UseObject")]))
        XCTAssertEqual(store.snapshot.typeDefinitions.first { $0.name == "UseObject" }?.inferenceProvenance, provenance)

        // One undo step removes the type and the local assignment together.
        store.undoManager.undo()
        XCTAssertTrue(store.snapshot.typeDefinitions.isEmpty)
        XCTAssertTrue(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: slot).isEmpty)
    }

    func testSameSiteExtensionChangeRefusesPreviewWithoutMutationAndFreshTokenAccepts() throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let previewArguments: ScriptValue = .object(["function": .string("_use"), "parameter": .int(0)])
        let oldPreview = try api.execute("recover-struct-candidate", arguments: previewArguments)
        let oldToken = try XCTUnwrap(oldPreview["candidate"]?.stringValue)
        let function = try XCTUnwrap(store.snapshot.functions.first)
        let oldCandidate = WorkspaceScriptingAPI.structCandidate(snapshot: store.snapshot, function: function, parameter: 0)
        let oldType = try StructCandidateTypeAdapter.typeDefinition(
            for: oldCandidate, name: "ChangedObject", choices: [.init(offset: 8, byteWidth: 4)], existing: [])
        XCTAssertEqual(oldType.fields.first { $0.name == "field_0x8" }?.type, "uint32_t")

        // Reanalysis changes only the extension semantics at the same four-byte load site.
        // Its root, source address, offset, role and memory width remain the same.
        store.snapshot.instructions[1] = InstructionRow(
            address: 0x1004, bytes: "", mnemonic: "ldrsw", operands: "x2, [x0, #0x8]",
            hasBreakpoint: false, comment: nil)
        let currentCandidate = WorkspaceScriptingAPI.structCandidate(snapshot: store.snapshot, function: function, parameter: 0)
        XCTAssertEqual(currentCandidate.fields.map(\.offset), oldCandidate.fields.map(\.offset))
        XCTAssertEqual(currentCandidate.fields.map(\.byteWidth), oldCandidate.fields.map(\.byteWidth))
        let currentType = try StructCandidateTypeAdapter.typeDefinition(
            for: currentCandidate, name: "ChangedObject", choices: [.init(offset: 8, byteWidth: 4)], existing: [])
        XCTAssertEqual(currentType.fields.first { $0.name == "field_0x8" }?.type, "int32_t")
        let definitionsBefore = store.snapshot.typeDefinitions
        let overridesBefore = store.snapshot.addressOverrides
        let canUndoBefore = store.undoManager.canUndo
        let canRedoBefore = store.undoManager.canRedo
        func accept(_ token: String) throws -> ScriptValue {
            try api.execute("accept-struct-candidate", arguments: .object([
                "function": .string("_use"), "parameter": .int(0), "candidate": .string(token),
                "name": .string("ChangedObject"), "local": .string("-24:-16"),
                "choices": .array([.object(["offset": .int(8), "width": .int(4)])]),
            ]))
        }
        XCTAssertThrowsError(try accept(oldToken)) { error in
            guard case ScriptingError.invalidArgument(let reason) = error else {
                return XCTFail("expected stale-candidate refusal, got \(error)")
            }
            XCTAssertTrue(reason.contains("candidate is stale"), reason)
        }
        XCTAssertEqual(store.snapshot.typeDefinitions, definitionsBefore, "stale acceptance must not add a catalog type")
        XCTAssertEqual(store.snapshot.addressOverrides, overridesBefore, "stale acceptance must not type the local")
        XCTAssertEqual(store.undoManager.canUndo, canUndoBefore, "stale acceptance must not register undo")
        XCTAssertEqual(store.undoManager.canRedo, canRedoBefore)
        guard store.snapshot.typeDefinitions == definitionsBefore else { return }

        let freshPreview = try api.execute("recover-struct-candidate", arguments: previewArguments)
        let freshToken = try XCTUnwrap(freshPreview["candidate"]?.stringValue)
        XCTAssertNotEqual(freshToken, oldToken)
        let accepted = try accept(freshToken)
        XCTAssertEqual(accepted["candidate"], .string(freshToken))
        let type = try XCTUnwrap(store.snapshot.typeDefinitions.first { $0.name == "ChangedObject" })
        XCTAssertEqual(type.fields.first { $0.name == "field_0x8" }?.type, "int32_t")
        XCTAssertEqual(type.inferenceProvenance?.candidateID, freshToken)
        XCTAssertEqual(store.snapshot.stackLocalOverrides(forProcedureAt: 0x1000, in: store.snapshot.primarySlot)["-24:-16"]?.typeName,
                       "ChangedObject *")
        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.typeDefinitions, definitionsBefore)
        XCTAssertEqual(store.snapshot.addressOverrides, overridesBefore)
    }

    func testAdapterRefusesInteriorPointersAndUnexpressibleChoices() {
        let interior = MacIRBuilder().buildFunction(name: "_i", startAddress: 0x2000, instructions: [
            InstructionRow(address: 0x2000, bytes: "", mnemonic: "ldur", operands: "x1, [x0, #-0x8]", hasBreakpoint: false, comment: nil),
            InstructionRow(address: 0x2004, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
        ])
        let candidate = MacIRStructUsageAnalysis.candidate(for: .parameter(gprIndex: 0), in: interior)
        XCTAssertThrowsError(try StructCandidateTypeAdapter.typeDefinition(
            for: candidate, name: "Interior", choices: [], existing: [])) { error in
            XCTAssertEqual(error as? StructCandidateTypeAdapter.Refusal, .needsRebase)
        }
        XCTAssertThrowsError(try StructCandidateTypeAdapter.typeDefinition(
            for: candidate, name: "not valid", choices: [], existing: [])) { error in
            XCTAssertEqual(error as? StructCandidateTypeAdapter.Refusal, .invalidName)
        }
    }

    func testMCPExposesRecoveryWithValidatedArguments() {
        let names = Set(HeadlessAutomationAuthority.availableCommands.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["recover-struct-candidate", "accept-struct-candidate"]))
        XCTAssertTrue(MCPAttachExecutor.attachCommands.isSuperset(of: ["recover-struct-candidate", "accept-struct-candidate"]))
        XCTAssertNoThrow(try HeadlessAutomationAuthority.validate(command: "accept-struct-candidate", arguments: .object([
            "address": .hex(0x1000), "parameter": .int(0), "candidate": .string("struct-candidate-v1:1"),
            "name": .string("T"), "choices": .array([.object(["offset": .int(8), "width": .int(8)])]),
        ])))
        for bad: ScriptValue in [
            .object(["address": .hex(0x1000), "parameter": .int(9), "candidate": .string("c"), "name": .string("T")]),
            .object(["address": .hex(0x1000), "parameter": .int(0), "candidate": .string("c"), "name": .string("T"),
                     "choices": .array([.object(["offset": .int(8)])])]),
            .object(["address": .hex(0x1000), "parameter": .int(0), "candidate": .string("c"), "name": .string("T"),
                     "local": .string("bogus")]),
        ] {
            XCTAssertThrowsError(try HeadlessAutomationAuthority.validate(command: "accept-struct-candidate", arguments: bad))
        }
    }
}
