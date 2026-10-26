import Foundation
import XCTest
@testable import MacScope

/// HS-1 (load-time analysis repair) and HS-2 (analyzer-version stamp) for `.mscope` workspaces.
@MainActor
final class WorkspaceIntegrityTests: XCTestCase {
    private static let code = Data([
        0x00, 0x00, 0x80, 0x52,         // mov w0, #0
        0x02, 0x00, 0x00, 0x14,         // b .+8
        0xc0, 0x03, 0x5f, 0xd6,         // ret
        0xff, 0x43, 0x00, 0xd1,         // sub sp, sp, #0x10
        0xc0, 0x03, 0x5f, 0xd6,         // ret
    ])

    private func function(_ start: UInt64, _ end: UInt64, _ name: String = "f") -> FunctionSummary {
        FunctionSummary(id: UUID(), name: name, startAddress: start, endAddress: end, confidence: 1)
    }

    private func row(_ address: UInt64) -> InstructionRow {
        InstructionRow(address: address, bytes: "1f 20 03 d5", mnemonic: "nop", operands: "", hasBreakpoint: false)
    }

    // MARK: HS-1 pure repair

    func testRepairDropsOutOfImageDuplicateAndOverlappingProcedures() {
        var analysis = ImageAnalysis()
        let a = function(0x1000, 0x1010, "a")
        let b = function(0x1010, 0x1020, "b")
        analysis.functions = [
            a, b,
            function(0x1000, 0x1010, "a_dup"),       // duplicate start
            function(0x1018, 0x1030, "overlaps_b"),  // starts inside b
            function(0x9000, 0x9010, "outside"),     // outside every segment
        ]
        analysis.basicBlocks = analysis.functions.map {
            BasicBlockSummary(id: UUID(), functionID: $0.id, startAddress: $0.startAddress,
                              endAddress: $0.endAddress, instructionCount: 1)
        }
        var repair = WorkspaceAnalysisRepair(slot: .primary, imageName: "image")
        WorkspaceAnalysisIntegrity.repair(&analysis, imageRanges: [0x1000..<0x2000], into: &repair)
        XCTAssertEqual(analysis.functions.map(\.id), [a.id, b.id])
        XCTAssertEqual(repair.functionsOutsideImage, 1)
        XCTAssertEqual(repair.duplicateFunctions, 1)
        XCTAssertEqual(repair.overlappingFunctions, 1)
        XCTAssertEqual(repair.danglingBasicBlocks, 3)
        XCTAssertEqual(Set(analysis.basicBlocks.map(\.functionID)), [a.id, b.id])
        let message = WorkspaceAnalysisIntegrity.message(for: [repair]) ?? ""
        XCTAssertTrue(message.contains("1 duplicate procedure(s)"), message)
        XCTAssertTrue(message.contains("1 procedure(s) outside the image"), message)
    }

    func testRepairDropsDerivedEntriesNotAtSavedInstructions() {
        var analysis = ImageAnalysis()
        analysis.functions = [function(0x1000, 0x1008)]
        analysis.instructions = [row(0x1000), row(0x1004)]
        analysis.xrefs = [
            XRef(id: UUID(), from: 0x1000, to: 0x5000, kind: XRefKind.call),   // ok
            XRef(id: UUID(), from: 0x1002, to: 0x5000, kind: XRefKind.call),   // mid-instruction
            XRef(id: UUID(), from: 0x7000, to: 0x1000, kind: XRefKind.data),   // data refs untouched
        ]
        analysis.jumpTables = [0x1004: [0x1000], 0x1006: [0x1000]]
        analysis.controlFlowEdges = [
            ControlFlowEdge(id: UUID(), from: 0x1004, to: 0x9999, kind: "branch"),  // external target ok
            ControlFlowEdge(id: UUID(), from: 0x1003, to: 0x1004, kind: "fallthrough"),
        ]
        var repair = WorkspaceAnalysisRepair(slot: .primary, imageName: "image")
        WorkspaceAnalysisIntegrity.repair(&analysis, imageRanges: nil, into: &repair)
        XCTAssertEqual(repair.danglingCallXRefs, 1)
        XCTAssertEqual(repair.danglingJumpTables, 1)
        XCTAssertEqual(repair.danglingControlFlowEdges, 1)
        XCTAssertEqual(analysis.xrefs.count, 2)
        XCTAssertEqual(Array(analysis.jumpTables.keys), [0x1004])
        XCTAssertEqual(analysis.controlFlowEdges.map(\.from), [0x1004])
    }

    func testFreshAnalysisNeedsNoRepair() throws {
        var snapshot = try AnalysisEngine().analyze(url: try TinyMachO.make(code: Self.code).write())
        let before = snapshot.functions
        XCTAssertEqual(WorkspaceAnalysisIntegrity.repair(&snapshot), [])
        XCTAssertEqual(snapshot.functions, before)
    }

    // MARK: Package round trips

    private func savedPackage() throws -> (url: URL, functions: [FunctionSummary], parent: URL) {
        let fixture = TinyMachO.make(code: Self.code)
        let source = try fixture.write()
        let engine = AnalysisEngine()
        let snapshot = try engine.analyze(url: source)
        let store = WorkspaceStore(workspaceName: "integrity", snapshot: snapshot, engine: engine,
                                   autosaveScheduler: nil)
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent("Integrity.mscope", isDirectory: true)
        XCTAssertTrue(store.writeDocumentPackage(to: url), store.saveError ?? "")
        return (url, snapshot.functions, parent)
    }

    private func editManifest(_ url: URL, _ body: (inout [String: Any]) throws -> Void) throws {
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        try body(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)
    }

    func testSaveStampsAnalyzerVersionAndReopens() throws {
        let saved = try savedPackage()
        defer { try? FileManager.default.removeItem(at: saved.parent) }
        let manifest = try MacScopeDocumentPackage.readManifest(from: saved.url)
        XCTAssertEqual(manifest.analyzer, .current)
        let reopened = try WorkspaceStore.restoredPackage(from: saved.url)
        XCTAssertEqual(reopened.lastAnalysisRepairs, [])
        XCTAssertEqual(reopened.snapshot.functions.map(\.startAddress), saved.functions.map(\.startAddress))
    }

    func testNewerAnalyzerWorkspaceIsRefusedNamingTheMissingFeature() throws {
        let saved = try savedPackage()
        defer { try? FileManager.default.removeItem(at: saved.parent) }
        let future = WorkspaceAnalyzerStamp.currentVersion + 1
        try editManifest(saved.url) { object in
            object["analyzer"] = [
                "version": future,
                "features": [["version": future, "name": "persisted SSA value numbering"]],
            ]
        }
        XCTAssertThrowsError(try WorkspaceStore.restoredPackage(from: saved.url)) { error in
            XCTAssertEqual(error as? MacScopeDocumentPackage.PackageError,
                           .newerAnalyzerVersion(future, missingFeatures: ["persisted SSA value numbering"]))
            XCTAssertTrue(error.localizedDescription.contains("persisted SSA value numbering"))
        }
    }

    func testUnstampedOlderWorkspaceStillLoads() throws {
        let saved = try savedPackage()
        defer { try? FileManager.default.removeItem(at: saved.parent) }
        try editManifest(saved.url) { object in object.removeValue(forKey: "analyzer") }
        let reopened = try WorkspaceStore.restoredPackage(from: saved.url)
        XCTAssertEqual(reopened.snapshot.functions.count, saved.functions.count)
    }

    /// A synthetic corrupted package: a duplicated and an out-of-image procedure. Open drops them,
    /// reports one diagnostic, and rebuilds the image through the reanalysis path.
    func testCorruptedPackageIsRepairedReportedAndRebuiltOnOpen() async throws {
        let saved = try savedPackage()
        defer { try? FileManager.default.removeItem(at: saved.parent) }
        let first = try XCTUnwrap(saved.functions.first)
        try editManifest(saved.url) { object in
            var analysis = try XCTUnwrap(object["analysis"] as? [String: Any])
            var functions = try XCTUnwrap(analysis["functions"] as? [[String: Any]])
            var duplicate = try XCTUnwrap(functions.first)
            duplicate["id"] = UUID().uuidString
            duplicate["name"] = "duplicate"
            var outside = duplicate
            outside["id"] = UUID().uuidString
            outside["name"] = "outside"
            outside["startAddress"] = 0x7fff_0000_0000 as UInt64
            outside["endAddress"] = 0x7fff_0000_0010 as UInt64
            functions.append(duplicate)
            functions.append(outside)
            analysis["functions"] = functions
            object["analysis"] = analysis
        }
        let reopened = try WorkspaceStore.restoredPackage(from: saved.url)
        let repair = try XCTUnwrap(reopened.lastAnalysisRepairs.first)
        XCTAssertEqual(repair.duplicateFunctions, 1)
        XCTAssertEqual(repair.functionsOutsideImage, 1)
        XCTAssertTrue(reopened.lastIssue?.contains("repaired on open") == true, reopened.lastIssue ?? "")
        await reopened.awaitPendingReanalysis()
        XCTAssertEqual(reopened.snapshot.functions.map(\.startAddress), saved.functions.map(\.startAddress))
        XCTAssertEqual(reopened.snapshot.functions.first?.startAddress, first.startAddress)
        XCTAssertFalse(reopened.snapshot.instructions.isEmpty, "rebuilt from the retained bytes")
    }

    // MARK: HS-2b database import / restore paths

    private func corruptFunctions(_ url: URL) throws {
        try editManifest(url) { object in
            var analysis = try XCTUnwrap(object["analysis"] as? [String: Any])
            var functions = try XCTUnwrap(analysis["functions"] as? [[String: Any]])
            var duplicate = try XCTUnwrap(functions.first)
            duplicate["id"] = UUID().uuidString
            duplicate["name"] = "duplicate"
            functions.append(duplicate)
            analysis["functions"] = functions
            object["analysis"] = analysis
        }
    }

    /// `WorkspaceDatabase.importPackage` reads through the open path; its repairs must reach the
    /// store that restores the imported workspace: one diagnostic, then a rebuild.
    func testDatabaseImportOfCorruptedPackageIsReportedAndRebuilt() async throws {
        let saved = try savedPackage()
        defer { try? FileManager.default.removeItem(at: saved.parent) }
        try corruptFunctions(saved.url)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let imported = try database.importPackage(from: saved.url)
        XCTAssertEqual(imported.analysisRepairs.first?.duplicateFunctions, 1)
        XCTAssertEqual(imported.snapshot.functions.count, saved.functions.count, "import stores the repaired analysis")

        let store = WorkspaceStore(workspaceName: "restore", snapshot: WorkspaceSnapshot(binaries: [], functions: [], instructions: [], xrefs: [], hexBytes: Data()), engine: AnalysisEngine(),
                                   autosaveScheduler: nil)
        store.restoreWorkspace(imported)
        XCTAssertEqual(store.lastAnalysisRepairs.first?.duplicateFunctions, 1)
        XCTAssertTrue(store.lastIssue?.contains("repaired on open") == true, store.lastIssue ?? "")
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.functions.map(\.startAddress), saved.functions.map(\.startAddress))
        XCTAssertFalse(store.snapshot.instructions.isEmpty, "rebuilt from the retained bytes")
    }

    /// A workspace already in the database (e.g. imported before #293, or written by an older
    /// build) is validated on restore exactly like a package open.
    func testDatabaseRestoreRepairsReportsAndRebuildsStoredAnalysis() async throws {
        let source = try TinyMachO.make(code: Self.code).write()
        var snapshot = try AnalysisEngine().analyze(url: source)
        let clean = snapshot.functions
        let slot = try XCTUnwrap(snapshot.binaries.first?.slot)
        var analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        analysis.functions.append(function(0x7fff_0000_0000, 0x7fff_0000_0010, "outside"))
        snapshot.replaceAnalysis(analysis, in: slot)

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let persisted = try database.saveWorkspaceState(
            workspaceName: "db-integrity", snapshot: snapshot, selectedSidebarItemID: nil,
            selectedAddress: nil, selectedTool: .project, editorMode: .disassembly,
            isInspectorPresented: false, sidebarSearchText: ""
        )
        XCTAssertEqual(persisted.analysisRepairs, [], "loading from the database alone does not repair")
        let store = try XCTUnwrap(try WorkspaceStore.restored(
            workspaceID: try XCTUnwrap(persisted.workspace.id), from: database))
        XCTAssertEqual(store.lastAnalysisRepairs.first?.functionsOutsideImage, 1)
        XCTAssertTrue(store.lastIssue?.contains("repaired on open") == true, store.lastIssue ?? "")
        XCTAssertFalse(store.snapshot.functions.contains { $0.name == "outside" })
        await store.awaitPendingReanalysis()
        XCTAssertEqual(store.snapshot.functions.map(\.startAddress), clean.map(\.startAddress))
    }
}
