import Foundation
import XCTest
@testable import MacScope

/// End-to-end oracle for jump-table recovery: compile a real dense `switch` with clang (which emits
/// a byte-offset table dispatched through a `mov`-aliased index — `cmp w0` / `mov w8,w0` /
/// `ldrb [..,x8]` / `br`), analyze the binary through the full AnalysisEngine pipeline, and assert
/// the table is recovered (`snapshot.jumpTables` non-empty). The unit fixtures feed hand-written
/// rows; only this proves the real decoder's rendering + the resolver + the table read all line up.
/// Guarded on otool actually showing a `br` dispatch inside the switch function, so it can never
/// pass vacuously when clang lowers the switch some other way on a given host.
final class JumpTableRealBinaryTests: XCTestCase {

    func testRealClangSwitchJumpTableIsRecovered() throws {
        let clang = "/usr/bin/clang"
        let otool = "/usr/bin/otool"
        guard FileManager.default.isExecutableFile(atPath: clang),
              FileManager.default.isExecutableFile(atPath: otool) else {
            throw XCTSkip("clang/otool unavailable on this host")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScopeJumpTable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 20-case dense switch with distinct non-linear bodies forces clang -O2 onto a byte-offset
        // jump table rather than a comparison tree or arithmetic. Everything is defined in-file so it
        // links standalone; `noinline` keeps `classify` a real, analyzable function.
        var src = "__attribute__((noinline)) int sink(int x){ return x*2+1; }\n"
        src += "__attribute__((noinline)) int classify(int x){\n  switch(x){\n"
        for i in 0..<20 { src += "    case \(i): return sink(\(i * 7 + 3)) ^ \(i);\n" }
        src += "    default: return -1;\n  }\n}\n"
        src += "int main(int argc, char** argv){ return classify(argc); }\n"

        let source = dir.appendingPathComponent("sw.c")
        let exe = dir.appendingPathComponent("sw")
        try src.write(to: source, atomically: true, encoding: .utf8)

        guard runProcess(clang, ["-arch", "arm64", "-O2", "-o", exe.path, source.path]) == 0,
              FileManager.default.fileExists(atPath: exe.path) else {
            throw XCTSkip("clang could not build the arm64 switch executable on this host")
        }

        // Guard: confirm clang actually emitted a `br`-dispatched jump table inside `classify`. A
        // function that returns via `ret` and calls via `bl`/`blr` only has no `br`; a computed `br`
        // is the jump-table dispatch. If absent, clang lowered the switch differently — skip rather
        // than assert against a binary that has no table to find.
        let disasm = processOutput(otool, ["-tvVj", exe.path])
        guard classifyContainsBranchDispatch(disasm) else {
            throw XCTSkip("clang did not emit a br-dispatched jump table for the switch on this host")
        }

        let snapshot = try AnalysisEngine().analyze(url: exe)
        XCTAssertFalse(
            snapshot.jumpTables.isEmpty,
            "a real clang switch compiled to a mov-aliased byte-offset jump table must be recovered "
                + "end-to-end (decoder → JumpTableResolver → snapshot.jumpTables)"
        )
        // The recovered table must have multiple distinct case targets, not a degenerate single entry.
        XCTAssertTrue(
            snapshot.jumpTables.values.contains { Set($0).count >= 3 },
            "the recovered jump table must carry the switch's multiple case targets"
        )
    }

    // MARK: - helpers

    /// True if the `_classify` function in otool output contains a `br` dispatch (its jump table).
    private func classifyContainsBranchDispatch(_ disasm: String) -> Bool {
        var inClassify = false
        for line in disasm.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("_classify:") { inClassify = true; continue }
            if inClassify {
                // A new label (no leading address/whitespace, ends with ':') ends the function.
                if line.hasSuffix(":") && !line.hasPrefix(" ") && !line.contains("\t") { break }
                let tokens = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if tokens.contains("br") { return true }
            }
        }
        return false
    }

    @discardableResult
    private func runProcess(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        // Output is never read; discard it rather than leave it to fill an unread pipe.
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { return -1 }
        return p.terminationStatus
    }

    private func processOutput(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
