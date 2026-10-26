import Foundation
import XCTest
@testable import MacScope

/// Surface relocations on the format-neutral `LoadedBinary` (and onward to the snapshot) so ELF and
/// Mach-O relocations — previously stranded on their format-specific parsers and never reaching the
/// model/UI — become reachable. Real-binary oracle: compile objects with clang and assert the loader
/// populates `relocations`. Skipped when clang or a given target is unavailable on the host.
final class NeutralRelocationTests: XCTestCase {

    private static let callsExtern = "extern int ext(int);\nint f(int x) { return ext(x) + 1; }\n"

    /// Compiles `source` to an object file with the given extra clang args and returns its bytes.
    private func compileObject(_ source: String, args: [String]) throws -> Data {
        let clangPath = "/usr/bin/clang"
        guard FileManager.default.isExecutableFile(atPath: clangPath) else { throw XCTSkip("clang unavailable") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeReloc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("f.c")
        let obj = root.appendingPathComponent("f.o")
        try source.write(to: src, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: clangPath)
        process.arguments = args + ["-c", src.path, "-o", obj.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let drain: CoreTestPipeDrain
        do {
            try process.run()
            drain = CoreTestPipeDrain(pipe)
            process.waitUntilExit()
        } catch { throw XCTSkip("clang launch failed: \(error)") }
        let output = drain.text()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: obj.path) else {
            throw XCTSkip("clang did not produce an object: " + output)
        }
        return try Data(contentsOf: obj)
    }

    func testElfRelocationsSurfacedOnLoadedBinary() throws {
        let bytes = try compileObject(Self.callsExtern, args: ["-target", "x86_64-linux-gnu"])
        guard ELFBinaryLoader.isELF(bytes) else { throw XCTSkip("clang did not emit an ELF object on this host") }
        let loaded = try ELFBinaryLoader.parse(bytes: bytes, name: "f.o", path: "/tmp/f.o")
        // `.rela.text` carries the R_X86_64_PLT32 (type 4) call to `ext`, addend -4. Symbol name may be
        // nil for a relocatable object (refs .symtab, not .dynsym), so pin the reliably-available facts.
        XCTAssertTrue(
            loaded.relocations.contains { $0.typeCode == 4 && ($0.symbolIndex ?? 0) > 0 && $0.addend == -4 },
            "ELF PLT32 relocation must surface on LoadedBinary.relocations; got \(loaded.relocations.count)"
        )
    }

    func testMachORelocationsSurfacedOnLoadedBinary() throws {
        let bytes = try compileObject(Self.callsExtern, args: ["-arch", "arm64"])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeRelocMachO-\(UUID().uuidString).o")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = try MachOBinaryLoader().load(at: url)
        XCTAssertFalse(loaded.relocations.isEmpty,
                       "Mach-O object relocations must surface on LoadedBinary.relocations")
        XCTAssertTrue(loaded.relocations.contains { ($0.symbolName ?? "").contains("ext") },
                      "the external call to `ext` must appear as a named relocation")
    }

    /// End-to-end reachability: relocations must reach the WorkspaceSnapshot through AnalysisEngine
    /// AND be queryable via the `relocations` scripting command — the whole point of surfacing them.
    @MainActor
    func testRelocationsReachSnapshotAndScriptingCommand() throws {
        let bytes = try compileObject(Self.callsExtern, args: ["-arch", "arm64"])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeRelocReach-\(UUID().uuidString).o")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = try AnalysisEngine().analyze(url: url)
        XCTAssertFalse(snapshot.relocations.isEmpty,
                       "relocations must reach the WorkspaceSnapshot, not stay stranded on the loader")

        let store = WorkspaceStore(workspaceName: "Reloc", snapshot: snapshot, engine: AnalysisEngine())
        let result = try WorkspaceScriptingAPI(store: store).execute("relocations")
        let rows = try XCTUnwrap(result.arrayValue, "the `relocations` command must return an array")
        XCTAssertFalse(rows.isEmpty, "the `relocations` command must surface the snapshot relocations")
        XCTAssertTrue(rows.contains { ($0["symbol"]?.stringValue ?? "").contains("ext") },
                      "the named `ext` relocation must be reachable through the scripting command")
    }
}
