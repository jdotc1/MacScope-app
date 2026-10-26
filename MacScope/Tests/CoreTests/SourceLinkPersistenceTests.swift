import Foundation
import XCTest
@testable import MacScope

final class SourceLinkPersistenceTests: XCTestCase {
    func testSourcePreviewUsesPhysicalCRLFLinesAndRejectsOutOfRangeLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourcePreview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.c")
        try "first\r\nsecond\r\nthird".write(to: file, atomically: true, encoding: .utf8)
        let fixture = try snapshot(sourceRoot: root)
        let state = try SourceLinkWorkspaceState.decode(fixture.sourceLinkState)
        let image = try XCTUnwrap(state.bindings.first?.image)
        let document = try SourcePreviewDocument(target: .init(
            fileURL: file, line: 2, column: nil, image: image, origin: .inspector(slot: .primary)
        ))
        XCTAssertEqual(document.lines, ["first", "second", "third"])
        XCTAssertThrowsError(try SourcePreviewDocument(target: .init(
            fileURL: file, line: 4, column: nil, image: image, origin: .inspector(slot: .primary)
        )))
    }

    @MainActor
    func testLegacyDisplayArchitectureMigratesOnlyExactOwnerAndSlice() throws {
        var fixture = try snapshot(sourceRoot: URL(fileURLWithPath: "/tmp/source-checkout"))
        var binary = fixture.binaries[0]
        binary.architecture = "arm64"
        binary.artifactIdentity = try MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: try XCTUnwrap(binary.metadata.uuid)),
            rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 2,
            selectedSliceSHA256: String(repeating: "a", count: 64), selectedSliceByteCount: 4096)
        fixture.binaries[0] = binary
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.sourceLinkState) as? [String: Any])
        object["version"] = 1
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let legacy = try SourceLinkWorkspaceState.decode(bytes)
        XCTAssertEqual(legacy.bindings[0].image.architecture, "arm64")
        XCTAssertNil(legacy.binding(for: binary))
        let migrated = try SourceLinkWorkspaceState.decode(bytes, binaries: fixture.binaries)
        let binding = try XCTUnwrap(migrated.binding(for: binary))
        XCTAssertEqual(binding.image.architecture, "arm64e")
        XCTAssertEqual(binding.checkout, legacy.bindings[0].checkout)
        XCTAssertEqual(binding.acceptedLinks[0].image, binding.image)
        XCTAssertEqual(binding.acceptedLinks[0].recordedPath, legacy.bindings[0].acceptedLinks[0].recordedPath)
        let persisted = try SourceLinkWorkspaceState.decode(migrated.encoded())
        XCTAssertEqual(persisted.version, 2)
        XCTAssertEqual(persisted.binding(for: binary), binding)
        var replaced = binary
        replaced = BinaryImage(id: UUID(), name: binary.name, path: binary.path,
                               kind: binary.kind, architecture: binary.architecture, metadata: binary.metadata,
                               artifactIdentity: binary.artifactIdentity, slot: binary.slot)
        XCTAssertNil(try SourceLinkWorkspaceState.decode(bytes, binaries: [replaced]).binding(for: replaced))
        replaced = binary
        replaced.selectedSliceIndex = 3
        XCTAssertNil(try SourceLinkWorkspaceState.decode(bytes, binaries: [replaced]).binding(for: replaced))
        // V2 never treats a display label as precise architecture authority.
        object["version"] = 2
        XCTAssertNil(try SourceLinkWorkspaceState.decode(JSONSerialization.data(withJSONObject: object),
                                                        binaries: [binary]).binding(for: binary))
    }

    @MainActor
    func testDatabaseAndPackageReopenKeepBothImageOpenersAndRemapOwners() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceLinks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Array(repeating: "// source", count: 50).joined(separator: "\n")
            .write(to: root.appendingPathComponent("main.c"), atomically: true, encoding: .utf8)
        let fixture = try snapshot(sourceRoot: root)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let store = WorkspaceStore(workspaceName: "Source evidence", snapshot: fixture,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let saved = try store.saveWorkspace(to: database)
        let reopened = try XCTUnwrap(database.loadWorkspaceState(workspaceID: try XCTUnwrap(saved.workspace.id)))
        XCTAssertEqual(reopened.snapshot.sourceLinkState, fixture.sourceLinkState)
        try assertOpeners(snapshot: reopened.snapshot)

        let packageURL = root.appendingPathComponent("Source.mscope")
        _ = try database.writePackage(workspaceID: try XCTUnwrap(saved.workspace.id),
                                      documentID: store.documentID, to: packageURL)
        let destination = try WorkspaceDatabase.inMemory()
        try destination.applySchema()
        _ = try destination.importPackage(from: packageURL)
        let imported = try destination.importPackage(from: packageURL)
        XCTAssertNotEqual(imported.snapshot.binaries.map(\.id), fixture.binaries.map(\.id))
        let state = try SourceLinkWorkspaceState.decode(imported.snapshot.sourceLinkState)
        XCTAssertEqual(state.bindings.map(\.checkout.localRootPath), [root.path, root.path])
        XCTAssertEqual(state.bindings.map(\.image.binaryID), imported.snapshot.binaries.map(\.id))
        XCTAssertTrue(state.bindings.allSatisfy { $0.acceptedLinks.count == 1 })
        try assertOpeners(snapshot: imported.snapshot)
    }

    func testLegacyStateDefaultsEmptyAndMalformedOrOversizedStateRefuses() throws {
        let legacy = try WorkspacePackageAnalysis.decodeStrictPackageJSON(from: Data("{}".utf8))
        XCTAssertTrue(legacy.sourceLinkState.isEmpty)
        XCTAssertThrowsError(try SourceLinkWorkspaceState.decode(Data("{\"version\":99}".utf8)))
        XCTAssertThrowsError(try SourceLinkWorkspaceState.decode(Data(repeating: 0, count: 1_048_577)))
        XCTAssertThrowsError(try WorkspacePackageAnalysis.decodeStrictPackageJSON(
            from: Data("{\"sourceLinkState\":\"\",\"sourceLinkState\":\"\"}".utf8)
        ))
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try database.saveSnapshot(workspaceName: "Legacy", snapshot: AnalysisEngine.previewSnapshot())
        let id = try XCTUnwrap(saved.id)
        XCTAssertTrue(try XCTUnwrap(database.loadSnapshot(workspaceID: id)).sourceLinkState.isEmpty)
        try database.executeRawForTesting("PRAGMA ignore_check_constraints = ON;")
        try database.executeRawForTesting("INSERT INTO source_link_states VALUES (\(id), zeroblob(1048577));")
        XCTAssertThrowsError(try database.loadSnapshot(workspaceID: id))
    }

    @MainActor
    func testReplacementOrRevisionChangeRefusesPreviouslyRenderedLink() throws {
        let fixture = try snapshot(sourceRoot: URL(fileURLWithPath: "/tmp/source-checkout"))
        let store = WorkspaceStore(workspaceName: "Source stale", snapshot: fixture,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        let link = try XCTUnwrap(store.sourceLinks(at: 0x1000_00000, in: .primary).first)
        var replacement = fixture.binaries[0]
        replacement = BinaryImage(id: UUID(), name: replacement.name, path: replacement.path,
                                  kind: replacement.kind, architecture: replacement.architecture,
                                  metadata: replacement.metadata, slot: .primary)
        store.snapshot.binaries[0] = replacement
        XCTAssertThrowsError(try store.sourceOpenTarget(link, origin: .inspector(slot: .primary)))
        XCTAssertTrue(try store.sourceLinks(at: 0x1000_00000, in: .primary).isEmpty)
        let revision = try XCTUnwrap(SourceRevisionIdentity("different-build"))
        let checkout = try XCTUnwrap(AcceptedLocalSourceCheckout(
            localRootPath: "/tmp/source-checkout", recordedSourceRoot: "/build", revision: revision
        ))
        let originalRevision = try XCTUnwrap(SourceRevisionIdentity("source-commit-a"))
        XCTAssertThrowsError(try store.acceptSourceCheckout(
            checkout, buildRevision: originalRevision, expectedBinary: replacement,
            expectedInstallationID: store.documentInstallationID, address: 0x1000_00000
        ))
        XCTAssertEqual(store.snapshot.sourceLinkState, fixture.sourceLinkState)
    }

    @MainActor
    private func assertOpeners(snapshot: WorkspaceSnapshot) throws {
        let store = WorkspaceStore(workspaceName: "Reopened source", snapshot: snapshot,
                                   engine: AnalysisEngine(), autosaveScheduler: nil)
        for binary in snapshot.binaries {
            let link = try XCTUnwrap(store.sourceLinks(at: 0x1000_00000, in: binary.slot).first)
            XCTAssertEqual(link.qualification, .exactDebugSymbols)
            let origin: SourceLinkOpenOrigin = binary.slot == .primary
                ? .inspector(slot: binary.slot) : .compareImagesNew(slot: binary.slot)
            let target = try store.sourceOpenTarget(link, origin: origin)
            XCTAssertEqual(target.line, 42)
            XCTAssertEqual(target.fileURL.lastPathComponent, "main.c")
            XCTAssertEqual(target.image.binaryID, binary.id)
        }
    }

    private func snapshot(sourceRoot: URL) throws -> WorkspaceSnapshot {
        var snapshot = AnalysisEngine.previewSnapshot()
        let uuid = UUID()
        snapshot.binaries[0].metadata.uuid = uuid.uuidString
        let primary = snapshot.binaries[0]
        var secondary = primary
        secondary = BinaryImage(id: UUID(), name: "Comparison", path: primary.path,
                                kind: primary.kind, architecture: primary.architecture,
                                metadata: primary.metadata, slot: ImageSlot(rawValue: 7))
        snapshot.binaries.append(secondary)
        snapshot.analysisBySlot[secondary.slot] = AnalysisEngine.previewSnapshot().analysisBySlot[.primary]
        let revision = try XCTUnwrap(SourceRevisionIdentity("source-commit-a"))
        let checkout = try XCTUnwrap(AcceptedLocalSourceCheckout(
            localRootPath: sourceRoot.path, recordedSourceRoot: "/build", revision: revision
        ))
        var state = SourceLinkWorkspaceState()
        for binary in snapshot.binaries {
            let rows = [SourceLineEntry(
                address: 0x1000_00000, file: "/build/main.c", line: 42, column: 1, endSequence: false,
                debugArtifactUUID: uuid, debugArtifactMachOSHA256: String(repeating: "a", count: 64),
                debugArtifactMachOByteCount: 4096, lineProgramUnitOffset: 0, fileTableIndex: 1,
                tablePath: .absoluteUTF8("/build/main.c")
            )]
            snapshot.analysisBySlot[binary.slot]?.sourceLines = rows
            let index = SourceCandidateIndex(
                binary: binary, sourceRevision: revision,
                debugContext: .init(architecture: "arm64", sourceRevision: revision),
                sourceLines: rows, acceptedCheckouts: [checkout]
            )
            state.bindings.append(.init(image: try XCTUnwrap(index.image), checkout: checkout,
                                        debugArchitecture: "arm64", acceptedLinks: index.links(functionAddress: 0x1000_00000)))
        }
        snapshot.sourceLinkState = try state.encoded()
        return snapshot
    }
}
