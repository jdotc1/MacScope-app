import Foundation
import XCTest
@testable import MacScope

final class WorkspaceOperandPersistenceTests: XCTestCase {
    func testSaveReopenPreservesStructuredOperandsAndAuthoredEdits() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = fixture(root: root)
        let databaseURL = root.appendingPathComponent("workspace.sqlite")
        let workspaceID = try save(snapshot, to: databaseURL)
        // save() releases its database handle before this independent open.
        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        try reopened.applySchema()
        let loaded = try XCTUnwrap(reopened.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(loaded.snapshot.instructions, snapshot.instructions)
        XCTAssertEqual(loaded.snapshot.addressOverrides, snapshot.addressOverrides)
        XCTAssertEqual(try reopened.userVersion(), WorkspaceDatabase.schemaVersion)

        let package = root.appendingPathComponent("saved.mscope")
        _ = try reopened.writePackage(workspaceID: workspaceID, to: package,
                                      bookmarkResolutionDecision: .usePackageAttachmentsOnly)
        let opened = try MacScopeDocumentPackage.openPackage(from: package)
        XCTAssertEqual(opened.snapshot.instructions, snapshot.instructions)
        XCTAssertEqual(opened.snapshot.addressOverrides, snapshot.addressOverrides)
        let payload = try XCTUnwrap(opened.instructionSidecarData)
        XCTAssertEqual(payload[6], 4, "operand metadata requires MSINST v4")
        XCTAssertEqual(opened.manifest.formatVersion, 4, "outer package version is unchanged")
        XCTAssertEqual(opened.snapshot.instructions.map { $0.structuredOperands?.coverage },
                       [.complete, .partial, .unavailable, nil])
        // Exercise each v4 facet-header shape without running unrelated flow/block suites.
        let functionID = try XCTUnwrap(snapshot.functions.first?.id)
        for facets in 0...2 {
            let edges: [ControlFlowEdge]? = facets > 0 ? [] : nil
            let blocks: [BasicBlockSummary]? = facets == 2
                ? [.init(id: UUID(), functionID: functionID, startAddress: 0x1000, endAddress: 0x1010, instructionCount: 4)] : nil
            let group = WorkspaceInstructionSidecarCodec.Group(binaryID: nil, imageSlot: nil,
                instructions: snapshot.instructions, controlFlowEdges: edges, basicBlocks: blocks)
            let data = try WorkspaceInstructionSidecarCodec.encode([group])
            let descriptors = [WorkspaceInstructionSidecarGroupDescriptor(binaryID: nil, imageSlot: nil,
                rowCount: 4, controlFlowEdgeCount: edges.map { UInt64($0.count) }, basicBlockCount: blocks.map { UInt64($0.count) })]
            let decoded = try XCTUnwrap(WorkspaceInstructionSidecarCodec.decode(data, groups: descriptors).first)
            XCTAssertEqual(decoded.instructions, snapshot.instructions)
            XCTAssertEqual(decoded.controlFlowEdges, edges)
            XCTAssertEqual(decoded.basicBlocks, blocks)
        }
        XCTAssertThrowsError(try InstructionOperandsStorageCodec.encode(.init(schemaVersion: 2, coverage: .unavailable)))
        try reopened.executeRawForTesting("UPDATE instructions SET structured_operands_json = X'7B7D' WHERE address = 4096;")
        XCTAssertThrowsError(try reopened.loadWorkspaceState(workspaceID: workspaceID), "malformed present metadata must not become nil")
    }

    func testLegacyWorkspaceMigrationLoadsAbsentSidecars() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = fixture(root: root)
        snapshot.instructions = snapshot.instructions.map { row in
            var legacy = row
            legacy.structuredOperands = nil
            return legacy
        }
        let databaseURL = root.appendingPathComponent("legacy.sqlite")
        let workspaceID = try save(snapshot, to: databaseURL, legacyVersion42: true)
        let reopened = try WorkspaceDatabase(path: databaseURL.path)
        XCTAssertEqual(try reopened.userVersion(), 42)
        XCTAssertFalse(try reopened.columnNames(in: "instructions").contains("structured_operands_json"))
        try reopened.applySchema()
        XCTAssertEqual(try reopened.userVersion(), WorkspaceDatabase.schemaVersion)
        let loaded = try XCTUnwrap(reopened.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(loaded.snapshot.instructions, snapshot.instructions)
        XCTAssertTrue(loaded.snapshot.instructions.allSatisfy { $0.structuredOperands == nil })
        XCTAssertEqual(loaded.snapshot.addressOverrides, snapshot.addressOverrides)
        XCTAssertEqual(try reopened.scalarTextForTesting("SELECT hex(ir_json) FROM instructions WHERE address = 4096;"), "010203")

        let legacyPackage = root.appendingPathComponent("legacy.mscope")
        let components = try reopened.packageComponents(workspaceID: workspaceID, documentID: UUID(),
            inputCopyingDecision: .copyInputsIntoPackage, bookmarkResolutionDecision: .usePackageAttachmentsOnly,
            phase2ShellSession: nil)
        // Explicitly write the legacy inline manifest, with no structuredOperands keys.
        try MacScopeDocumentPackage.writeManifest(components.manifest, to: legacyPackage)
        for binary in components.manifest.binaries {
            let destination = try MacScopeDocumentPackage.attachmentURL(in: legacyPackage, relativePath: binary.attachmentRelativePath)
            try XCTUnwrap(components.attachmentsByBinaryID[binary.id]).write(to: destination)
        }
        let legacyOpen = try MacScopeDocumentPackage.openPackage(from: legacyPackage)
        XCTAssertNil(legacyOpen.instructionSidecarData)
        XCTAssertEqual(legacyOpen.snapshot.instructions, snapshot.instructions)
        XCTAssertTrue(legacyOpen.snapshot.instructions.allSatisfy { $0.structuredOperands == nil })

        // Existing binary versions remain readable and nil-only saves retain their old layout.
        for version in 1...3 {
            let edges: [ControlFlowEdge]? = version >= 2 ? [] : nil
            let blocks: [BasicBlockSummary]? = version >= 3 ? [] : nil
            let group = WorkspaceInstructionSidecarCodec.Group(binaryID: nil, imageSlot: nil,
                instructions: snapshot.instructions, controlFlowEdges: edges, basicBlocks: blocks)
            let data = try WorkspaceInstructionSidecarCodec.encode([group])
            XCTAssertEqual(data[6], UInt8(version))
            let descriptor = WorkspaceInstructionSidecarGroupDescriptor(binaryID: nil, imageSlot: nil,
                rowCount: 4, controlFlowEdgeCount: edges.map { UInt64($0.count) }, basicBlockCount: blocks.map { UInt64($0.count) })
            let decoded = try XCTUnwrap(WorkspaceInstructionSidecarCodec.decode(data, groups: [descriptor]).first)
            XCTAssertEqual(decoded.instructions, snapshot.instructions)
        }
    }

    private func save(_ snapshot: WorkspaceSnapshot, to url: URL, legacyVersion42: Bool = false) throws -> Int64 {
        let database = try WorkspaceDatabase(path: url.path)
        try database.applySchema()
        let saved = try database.createWorkspaceState(workspaceName: "Operand persistence", snapshot: snapshot,
            selectedSidebarItemID: nil, selectedAddress: nil, selectedTool: .project,
            editorMode: .disassembly, isInspectorPresented: false, sidebarSearchText: "")
        if legacyVersion42 {
            try database.executeRawForTesting("ALTER TABLE instructions DROP COLUMN structured_operands_json;")
            try database.executeRawForTesting("UPDATE instructions SET ir_json = X'010203' WHERE address = 4096;")
            try database.setUserVersionForTesting(42)
        }
        return try XCTUnwrap(saved.workspace.id)
    }

    private func temporaryRoot() throws -> URL {
        let root = TestWorkRoot.scratchURL("MacScopeDevLoop.noindex")
            .appendingPathComponent("operand-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(root: URL) -> WorkspaceSnapshot {
        let registers = [31, 0, 1, 2].map {
            InstructionOperands.Register(bank: .simd, index: $0, width: 128, arrangement: .init(elementWidth: 32), lane: 3)
        }
        let complete = InstructionOperands(coverage: .complete, opcodeClass: "ld4", operands: [
            .registerList(registers), .memory(.init(base: .init(index: 31, width: 64, role: .stackPointer),
                displacement: 16, indexing: .postIndex, writeback: true, displacementFormat: .decimal))
        ], semantics: .init(memoryAccessWidth: 32, memoryAccess: .read))
        let partial = InstructionOperands(coverage: .partial, opcodeClass: "partial", operands: [.opaque("unknown")])
        let rows = [
            InstructionRow(address: 0x1000, bytes: "ff b3 ff 4d", mnemonic: "ld4", operands: "{v31.s, v0.s, v1.s, v2.s}[3], [sp], #16", hasBreakpoint: false, comment: nil, structuredOperands: complete),
            InstructionRow(address: 0x1004, bytes: "00 00 00 00", mnemonic: "partial", operands: "unknown", hasBreakpoint: false, comment: "", structuredOperands: partial),
            InstructionRow(address: 0x1008, bytes: "20 48 28 4e", mnemonic: "aese", operands: "v0.16b, v1.16b", hasBreakpoint: false, comment: nil, structuredOperands: .unavailable(mnemonic: "aese", operands: "v0.16b, v1.16b")),
            InstructionRow(address: 0x100c, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil)
        ]
        let bytes = Data([0xff, 0xb3, 0xff, 0x4d, 0, 0, 0, 0, 0x20, 0x48, 0x28, 0x4e, 0xc0, 0x03, 0x5f, 0xd6])
        return WorkspaceSnapshot(binaries: [.init(id: UUID(), name: "operand fixture", path: root.appendingPathComponent("fixture.bin").path,
            kind: "synthetic fixture", architecture: "arm64")],
            functions: [.init(id: UUID(), name: "fixture", startAddress: 0x1000, endAddress: 0x1010, confidence: 1)],
            instructions: rows, xrefs: [], hexBytes: bytes, imageBytes: bytes,
            addressOverrides: [ImageAddress(slot: .primary, address: 0x1000): .init(customName: "saved_attach_name", customComment: "saved attach comment")])
    }
}
