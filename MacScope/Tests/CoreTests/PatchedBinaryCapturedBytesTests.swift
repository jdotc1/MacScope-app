import Foundation
import XCTest
@testable import MacScope

/// MS-15 / MS-16 store-level contracts: Save Patched Binary and structural reanalysis use the
/// image bytes captured into the workspace, never whatever file is at `binary.path` now.
@MainActor
final class PatchedBinaryCapturedBytesTests: XCTestCase {
    private func makeStore(path: String, bytes: Data, architecture: String = "arm64",
                           patches: [UInt64: BytePatch] = [:],
                           functions: [FunctionSummary] = []) -> WorkspaceStore {
        var snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: (path as NSString).lastPathComponent, path: path,
                                   kind: "Mach-O executable", architecture: architecture)],
            functions: [], instructions: [], xrefs: [], hexBytes: Data()
        )
        snapshot.imageBytes = bytes
        snapshot.functions = functions
        for (address, patch) in patches {
            snapshot.addressOverrides[.primary(address)] = AddressOverride(patch: patch)
        }
        return WorkspaceStore(workspaceName: "captured", snapshot: snapshot,
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ms15-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func expectedOutput(_ fixture: MachOFixture) -> Data {
        var expected = fixture.bytes
        expected.replaceSubrange(fixture.codeOffset..<(fixture.codeOffset + 4), with: BytePatch.arm64NOP.bytes)
        return expected
    }

    private func exportedBytes(_ store: WorkspaceStore) throws -> Data {
        let result = try WorkspaceScriptingAPI(store: store).execute("save-patched-binary")
        return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result["bytesBase64"]?.stringValue)))
    }

    func testExportUsesCapturedBytesAfterOriginalReplacedWithEqualSizeBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MachOFixture.makeExecutable()
        let source = directory.appendingPathComponent("target")
        try fixture.bytes.write(to: source)
        let store = makeStore(path: source.path, bytes: fixture.bytes,
                              patches: [fixture.baseAddress: .arm64NOP])
        var replaced = fixture.bytes
        replaced[fixture.codeOffset + 8] ^= 0xff
        try replaced.write(to: source, options: .atomic)
        XCTAssertEqual(try exportedBytes(store), expectedOutput(fixture))
    }

    func testDeletedOriginalDoesNotBlockExportAndWritesExactBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MachOFixture.makeExecutable()
        let source = directory.appendingPathComponent("target")
        let store = makeStore(path: source.path, bytes: fixture.bytes,
                              patches: [fixture.baseAddress: .arm64NOP])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let out = directory.appendingPathComponent("out")
        let result = try WorkspaceScriptingAPI(store: store).execute(
            "save-patched-binary", arguments: .object(["path": .string(out.path)]))
        XCTAssertEqual(result["unsigned"]?.boolValue, true, "the signature warning stays")
        XCTAssertEqual(try Data(contentsOf: out), expectedOutput(fixture))
    }

    func testPatchEditAfterCaptureIsRefusedAsStale() throws {
        let fixture = MachOFixture.makeExecutable()
        let store = makeStore(path: "/nonexistent/target", bytes: fixture.bytes,
                              patches: [fixture.baseAddress: .arm64NOP])
        let capture = try store.capturePatchedBinaryExport(in: .primary)
        let prepared = try capture.prepare()
        // A patch edit while the Save panel is open.
        XCTAssertTrue(store.setPatch(fixture.baseAddress + 4, in: .primary, .arm64NOP))
        XCTAssertThrowsError(try store.finishPatchedBinaryExport(prepared, in: .primary)) {
            XCTAssertEqual($0 as? PreparedMachOPatchExport.PreparationError, .staleInvestigation)
        }
        // Unchanged state still finishes.
        let fresh = try store.capturePatchedBinaryExport(in: .primary).prepare()
        XCTAssertNoThrow(try store.finishPatchedBinaryExport(fresh, in: .primary))
    }

    func testUniversalSliceOriginIsRefusedWithTheFatContract() throws {
        let fixture = MachOFixture.makeExecutable()
        let store = makeStore(path: "/nonexistent/fat", bytes: fixture.bytes,
                              architecture: "arm64 (universal slice 2/2 @ 0x4000)",
                              patches: [fixture.baseAddress: .arm64NOP])
        XCTAssertThrowsError(try WorkspaceScriptingAPI(store: store).execute("save-patched-binary")) { error in
            XCTAssertTrue(String(describing: error).contains("thin (single-architecture)"), "\(error)")
        }
    }

    func testNamedDyldCacheProjectionOriginIsRefused() throws {
        let fixture = MachOFixture.makeExecutable()
        let store = makeStore(path: "/nonexistent/dyld_shared_cache_arm64e(/usr/lib/libfoo.dylib)",
                              bytes: fixture.bytes)
        XCTAssertThrowsError(try store.capturePatchedBinaryExport(in: .primary).prepare()) {
            XCTAssertEqual($0 as? PreparedMachOPatchExport.PreparationError,
                           .unsupportedOrigin(.dyldCacheProjection))
        }
    }

    /// MS-16: an unnamed dyld-cache image gets the typed refusal and keeps its prior analysis.
    func testUnnamedDyldCacheImageReanalysisRefusesAndKeepsPriorAnalysis() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        try Data("dyld_v1  arm64e\0".utf8).write(to: cache)
        let fixture = MachOFixture.makeExecutable()
        let function = FunctionSummary(id: UUID(), name: "prior", startAddress: fixture.baseAddress,
                                       endAddress: fixture.baseAddress + 8, confidence: 1)
        let store = makeStore(path: cache.path, bytes: fixture.bytes, functions: [function])
        store.withSynchronousReanalysis {
            store.setMarkAsProcedure(fixture.baseAddress + 4, true)
        }
        XCTAssertEqual(store.lastReanalysisRefusal, .recaptureRequired(slot: .primary))
        XCTAssertEqual(store.snapshot.functions.map(\.id), [function.id])
        XCTAssertEqual(store.snapshot.imageBytes, fixture.bytes)
        XCTAssertNotNil(store.lastIssue)
    }

    /// The GUI fence: the requesting document is retired while the patch map is still being
    /// applied off the main actor, so the finished preparation gets no Save panel and no write.
    /// With the owner kept, the same sequence presents one panel and writes the rechecked bytes.
    func testOwnerRetiredDuringPreparationGetsNoPanelAndNoWrite() async throws {
        let fixture = MachOFixture.makeExecutable()
        let store = makeStore(path: "/nonexistent/target", bytes: fixture.bytes,
                              patches: [fixture.baseAddress: .arm64NOP])
        let prepared = try store.capturePatchedBinaryExport(in: .primary).prepare()

        func run(retireDuringPreparation: Bool) async -> (panels: Int, writes: [Data], errors: Int) {
            var ownerIsCurrent = true
            var panels = 0
            var writes: [Data] = []
            var errors = 0
            let (latch, release) = AsyncStream<Void>.makeStream()
            let sequence = PatchedBinarySaveSequence(
                isCurrentOwner: { ownerIsCurrent },
                prepare: {
                    for await _ in latch { break }
                    return prepared
                },
                chooseDestination: { _ in
                    panels += 1
                    return URL(fileURLWithPath: "/nonexistent/out")
                },
                write: { prepared, _ in
                    if let data = try? store.finishPatchedBinaryExport(prepared, in: .primary) {
                        writes.append(data)
                    }
                },
                reportPreparationError: { _ in errors += 1 }
            )
            let task = Task { await sequence.run() }
            await Task.yield()
            if retireDuringPreparation { ownerIsCurrent = false }
            release.yield()
            release.finish()
            await task.value
            return (panels, writes, errors)
        }

        let retired = await run(retireDuringPreparation: true)
        XCTAssertEqual(retired.panels, 0)
        XCTAssertEqual(retired.writes, [])
        XCTAssertEqual(retired.errors, 0)

        let kept = await run(retireDuringPreparation: false)
        XCTAssertEqual(kept.panels, 1)
        XCTAssertEqual(kept.writes, [expectedOutput(fixture)])
    }

    /// `Data.write(.atomic)` alone makes a 0644 file; the patched copy keeps the source's mode,
    /// and an executable whose source is gone still comes out 0755.
    func testWrittenCopyKeepsSourcePermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = MachOFixture.makeExecutable()
        func mode(_ url: URL) throws -> Int {
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
        }

        let source = directory.appendingPathComponent("target")
        try fixture.bytes.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: source.path)
        let store = makeStore(path: source.path, bytes: fixture.bytes,
                              patches: [fixture.baseAddress: .arm64NOP])
        let out = directory.appendingPathComponent("out")
        _ = try WorkspaceScriptingAPI(store: store).execute(
            "save-patched-binary", arguments: .object(["path": .string(out.path)]))
        XCTAssertEqual(try mode(out), 0o750)
        XCTAssertEqual(try Data(contentsOf: out), expectedOutput(fixture))

        let orphan = makeStore(path: directory.appendingPathComponent("gone").path, bytes: fixture.bytes,
                               patches: [fixture.baseAddress: .arm64NOP])
        let orphanOut = directory.appendingPathComponent("orphan-out")
        let capture = try orphan.capturePatchedBinaryExport(in: .primary)
        try capture.write(orphan.finishPatchedBinaryExport(capture.prepare(), in: .primary), to: orphanOut)
        XCTAssertEqual(try mode(orphanOut), 0o755)
    }
}
