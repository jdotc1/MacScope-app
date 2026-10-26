import Foundation
import XCTest
@testable import MacScope

/// Real-binary oracle for the PE/COFF loader. Until now PEBinaryLoader was validated ONLY against
/// hand-built `miniPE()` fixtures — which were authored to match the loader's own assumptions, so they
/// cannot catch a wrong assumption (self-mirror). This builds a REAL linked PE with clang's
/// x86_64-pc-windows-msvc target + lld-link (a DLL with exports + an exe importing from it), then
/// asserts the loader recovers the export directory, import directory, sections, and entry point that
/// `objdump -p` independently reports. Skipped when clang/lld-link is unavailable on the host.
final class PERealBinaryOracleTests: XCTestCase {

    // x86-64 PE default image bases: EXEs link at 0x140000000, DLLs at 0x180000000. The loader must
    // read each binary's actual base from its optional header (not assume one) — this oracle exercises
    // BOTH, which the fixed-base hand-built fixtures never did.
    private static let exeBase: UInt64 = 0x1_4000_0000
    private static let dllBase: UInt64 = 0x1_8000_0000

    /// Locates lld-link (ships with the Homebrew Swift/LLVM toolchains, not on PATH).
    private func findLLDLink() -> String? {
        let candidates = ["/opt/homebrew/opt/llvm/bin/lld-link"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        // Glob the versioned Swift toolchain dirs.
        let base = "/opt/homebrew/Cellar/swift"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: base) {
            for v in versions.sorted().reversed() {
                let p = "\(base)/\(v)/Swift-6.2.xctoolchain/usr/bin/lld-link"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
                // Toolchain dir name varies; scan for any *.xctoolchain.
                let vdir = "\(base)/\(v)"
                if let tcs = try? FileManager.default.contentsOfDirectory(atPath: vdir) {
                    for tc in tcs where tc.hasSuffix(".xctoolchain") {
                        let q = "\(vdir)/\(tc)/usr/bin/lld-link"
                        if FileManager.default.isExecutableFile(atPath: q) { return q }
                    }
                }
            }
        }
        return nil
    }

    @discardableResult
    private func run(_ path: String, _ args: [String], cwd: URL) throws -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.currentDirectoryURL = cwd
        // Output is never read; discard it rather than leave it to fill an unread pipe.
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw XCTSkip("could not launch \(path): \(error)") }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Builds test.dll (exports addnums/subnums) + test.exe (imports addnums). Returns the dir.
    private func buildRealPE() throws -> URL {
        let clang = "/usr/bin/clang"
        guard FileManager.default.isExecutableFile(atPath: clang) else { throw XCTSkip("clang unavailable") }
        guard let lld = findLLDLink() else { throw XCTSkip("lld-link unavailable on this host") }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeRealPE-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "__declspec(dllexport) int addnums(int a,int b){return a+b;}\n__declspec(dllexport) int subnums(int a,int b){return a-b;}\n"
            .write(to: dir.appendingPathComponent("dll.c"), atomically: true, encoding: .utf8)
        try "__declspec(dllimport) int addnums(int,int);\nint mainCRTStartup(void){return addnums(2,3);}\n"
            .write(to: dir.appendingPathComponent("exe.c"), atomically: true, encoding: .utf8)
        let target = ["-target", "x86_64-pc-windows-msvc", "-ffreestanding", "-O1", "-c"]
        guard try run(clang, target + ["dll.c", "-o", "dll.obj"], cwd: dir) == 0,
              try run(lld, ["/dll", "/noentry", "/nodefaultlib", "/export:addnums", "/export:subnums",
                            "/implib:lib.lib", "/out:test.dll", "dll.obj"], cwd: dir) == 0,
              try run(clang, target + ["exe.c", "-o", "exe.obj"], cwd: dir) == 0,
              try run(lld, ["/subsystem:console", "/nodefaultlib", "/entry:mainCRTStartup",
                            "/out:test.exe", "exe.obj", "lib.lib"], cwd: dir) == 0 else {
            throw XCTSkip("could not build a real PE with this toolchain")
        }
        return dir
    }

    func testLoaderRecoversExportsFromRealDLL() throws {
        let dir = try buildRealPE()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.dll")
        let loaded = try PEBinaryLoader.parse(bytes: try Data(contentsOf: url), name: "test.dll", path: url.path)

        // objdump ground truth: DLL base 0x180000000, addnums @ RVA 0x1000, subnums @ RVA 0x1010.
        let add = loaded.exports.first { $0.name == "addnums" }
        XCTAssertNotNil(add, "real DLL export 'addnums' must be recovered from the export directory")
        XCTAssertEqual(add?.address, Self.dllBase &+ 0x1000)
        XCTAssertNotNil(loaded.exports.first { $0.name == "subnums" }, "real DLL export 'subnums' missing")
        XCTAssertEqual(loaded.exports.first { $0.name == "subnums" }?.address, Self.dllBase &+ 0x1010)
    }

    func testLoaderRecoversImportsFromRealEXE() throws {
        let dir = try buildRealPE()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.exe")
        let loaded = try PEBinaryLoader.parse(bytes: try Data(contentsOf: url), name: "test.exe", path: url.path)

        let imp = loaded.imports.first { $0.name == "addnums" }
        XCTAssertNotNil(imp, "real EXE import 'addnums' must be recovered from the import directory")
        XCTAssertEqual(imp?.libraryName?.lowercased(), "test.dll")
        // EXE base 0x140000000, .text @ RVA 0x1000 + a real entry point.
        XCTAssertEqual(loaded.entryPointAddress, Self.exeBase &+ 0x1000,
                       "entry point must resolve to the .text RVA the PE optional header records")
        XCTAssertTrue(loaded.sections.contains { $0.name == ".text" }, "real PE .text section missing")
    }
}
