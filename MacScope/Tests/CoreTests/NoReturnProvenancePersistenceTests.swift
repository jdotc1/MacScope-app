import Foundation
import XCTest
@testable import MacScope

/// MASTER-PLAN §4.12a: HOP-1 `noReturnProvenance` survives save → reopen through the workspace
/// database and the `.mscope` package; a workspace saved before the field existed loads with it
/// absent (recomputed by the next re-analysis).
@MainActor
final class NoReturnProvenancePersistenceTests: XCTestCase {
    private static let code = Data([
        0x00, 0x00, 0x80, 0x52,         // mov w0, #0
        0x02, 0x00, 0x00, 0x14,         // b .+8
        0xc0, 0x03, 0x5f, 0xd6,         // ret
        0xff, 0x43, 0x00, 0xd1,         // sub sp, sp, #0x10
        0xc0, 0x03, 0x5f, 0xd6,         // ret
    ])

    func testNoReturnProvenanceRoundTripsThroughDatabaseAndPackage() throws {
        let source = try TinyMachO.make(code: Self.code).write()
        let engine = AnalysisEngine()
        var snapshot = try engine.analyze(url: source)
        var functions = snapshot.functions
        XCTAssertFalse(functions.isEmpty)
        functions[0].noReturnProvenance = .catalog
        if functions.count > 1 { functions[1].noReturnProvenance = .propagated }
        snapshot.functions = functions
        let expected = Dictionary(uniqueKeysWithValues: functions.map { ($0.startAddress, $0.noReturnProvenance) })
        func provenance(_ functions: [FunctionSummary]) -> [UInt64: AnalysisNoReturnProvenance?] {
            Dictionary(uniqueKeysWithValues: functions.map { ($0.startAddress, $0.noReturnProvenance) })
        }

        // Database row round trip.
        let store = WorkspaceStore(workspaceName: "noreturn", snapshot: snapshot, engine: engine,
                                   autosaveScheduler: nil)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let persisted = try store.saveWorkspace(to: database)
        let workspaceID = try XCTUnwrap(persisted.workspace.id)
        let loaded = try XCTUnwrap(try database.loadWorkspaceState(workspaceID: workspaceID))
        XCTAssertEqual(provenance(loaded.snapshot.functions), expected)

        // Package round trip (the GUI Save As / Open path).
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mscope-noreturn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("NoReturn.mscope", isDirectory: true)
        XCTAssertTrue(store.writeDocumentPackage(to: url), store.saveError ?? "")
        let reopened = try WorkspaceStore.restoredPackage(from: url)
        XCTAssertEqual(provenance(reopened.snapshot.functions), expected)

        // A workspace written before the field existed: no key, loads as "not known to halt".
        let manifestURL = MacScopeDocumentPackage.manifestURL(in: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var analysis = try XCTUnwrap(object["analysis"] as? [String: Any])
        var rows = try XCTUnwrap(analysis["functions"] as? [[String: Any]])
        XCTAssertTrue(rows.contains { $0["noReturnProvenance"] != nil })
        for index in rows.indices { rows[index].removeValue(forKey: "noReturnProvenance") }
        analysis["functions"] = rows
        object["analysis"] = analysis
        if var images = object["imageAnalyses"] as? [[String: Any]] {
            for i in images.indices {
                guard var payload = images[i]["analysis"] as? [String: Any],
                      var imageRows = payload["functions"] as? [[String: Any]] else { continue }
                for j in imageRows.indices { imageRows[j].removeValue(forKey: "noReturnProvenance") }
                payload["functions"] = imageRows
                images[i]["analysis"] = payload
            }
            object["imageAnalyses"] = images
        }
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)
        let legacy = try WorkspaceStore.restoredPackage(from: url)
        XCTAssertEqual(legacy.snapshot.functions.map(\.startAddress), functions.map(\.startAddress))
        XCTAssertTrue(legacy.snapshot.functions.allSatisfy { $0.noReturnProvenance == nil })
    }
}
