import Foundation
import XCTest
@testable import MacScope

/// Corpus gate locking the clean-room demangler's hard-won 0-WRONG property into the automated suite
/// (it was previously only a manual local script). For a real compiled binary, every mangled symbol is
/// run through BOTH the system tool (c++filt / swift-demangle = ground truth) and `Demangler`. The
/// strict invariant: whenever `Demangler` returns NON-nil, it must EQUAL the system tool's output — a
/// wrong demangle (the bug class unit pins + static review miss) fails here. nil is allowed
/// (correctness-over-coverage); a low coverage floor guards against a trivially all-nil pass. Skipped
/// when the toolchain is unavailable.
final class DemanglerCorpusGateTests: XCTestCase {

    private var xcrunInvocationCount = 0

    private func xcrun(_ args: [String], stdin: String? = nil) -> (status: Int32, out: String)? {
        xcrunInvocationCount += 1
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun"); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let inPipe = Pipe(); if stdin != nil { p.standardInput = inPipe }
        guard (try? p.run()) != nil else { return nil }
        // Drain before feeding stdin: a filter that writes while reading would otherwise
        // block on a full stdout pipe while this thread blocks writing its input.
        let drain = CoreTestPipeDrain(out)
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)); try? inPipe.fileHandleForWriting.close() }
        p.waitUntilExit()
        return (p.terminationStatus, drain.text())
    }

    private func compile(_ source: String, ext: String, args: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-demgate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("c.\(ext)"); let bin = dir.appendingPathComponent("c")
        try source.write(to: src, atomically: true, encoding: .utf8)
        guard let r = xcrun(args + ["-o", bin.path, src.path]), r.status == 0,
              FileManager.default.fileExists(atPath: bin.path) else {
            throw XCTSkip("could not compile the corpus fixture: \(args.first ?? "")")
        }
        return bin
    }

    /// Mangled symbols from `nm`, matched by `prefix` (`__Z` Itanium, `_$s`/`__$s` Swift).
    private func mangledSymbols(_ binary: URL, prefix: String) -> [String] {
        guard let r = xcrun(["nm", binary.path]) else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            line.split(separator: " ").last.map(String.init)
        }.filter { $0.contains(prefix) }
    }

    /// Runs the differential. `demangleTool` is the xcrun tool; `feed` maps an nm symbol to the form
    /// the tool + Demangler expect. Returns (mismatches, correct, total).
    private func differential(symbols: [String], tool: String,
                              normalizeForDemangler: (String) -> String) -> (mismatches: [String], correct: Int, total: Int) {
        let oracleInput = symbols.joined(separator: "\n") + "\n"
        guard let result = xcrun([tool], stdin: oracleInput), result.status == 0 else {
            return (["\(tool) did not produce a successful batch result"], 0, 0)
        }
        let oracleLines = result.out.split(separator: "\n", omittingEmptySubsequences: false)
        guard oracleLines.count == symbols.count + 1, oracleLines.last?.isEmpty == true else {
            return (["\(tool) returned \(oracleLines.count) lines for \(symbols.count) symbols"], 0, 0)
        }

        var mismatches: [String] = []; var correct = 0; var total = 0
        for (symbol, line) in zip(symbols, oracleLines.dropLast()) {
            let truth = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard truth != symbol, !truth.isEmpty else { continue }   // not actually mangled
            total += 1
            guard let ours = Demangler.mangledToReadable(normalizeForDemangler(symbol)) else { continue }
            if ours == truth { correct += 1 }
            else { mismatches.append("\(symbol)\n    ours:   \(ours)\n    truth:  \(truth)") }
        }
        return (mismatches, correct, total)
    }

    func testItaniumDemanglerMatchesCppFilt() throws {
        let binary = try compile("""
        #include <string>
        #include <vector>
        namespace ns { struct Widget {
            int compute(int n) const;
            virtual ~Widget();
        }; }
        int ns::Widget::compute(int n) const { return n; }
        ns::Widget::~Widget() {}
        template<typename T> T addv(T a, T b) { return a + b; }
        template int addv<int>(int, int);
        template double addv<double>(double, double);
        int freefn(char* p, unsigned long n) { return (int)n; }
        int main(){ return 0; }
        """, ext: "cpp", args: ["clang++", "-std=c++17", "-O0"])

        let symbols = mangledSymbols(binary, prefix: "__Z")
        try XCTSkipIf(symbols.isEmpty, "no Itanium-mangled symbols recovered")
        // c++filt strips one leading underscore from the Mach-O symbol; Demangler is given the same.
        let invocationsBeforeDifferential = xcrunInvocationCount
        let result = differential(symbols: symbols, tool: "c++filt", normalizeForDemangler: { $0 })
        XCTAssertEqual(xcrunInvocationCount - invocationsBeforeDifferential, 1)
        print("CPPFILT-GATE correct=\(result.correct) total-mangled=\(result.total) mismatches=\(result.mismatches.count)")

        XCTAssertTrue(result.mismatches.isEmpty,
                      "Demangler WRONG-OUTPUT vs c++filt (0-wrong violated):\n" + result.mismatches.joined(separator: "\n"))
        XCTAssertGreaterThan(result.correct, 2,
                             "Demangler demangled \(result.correct)/\(result.total) — suspiciously low (all-nil pass?)")
    }

    func testSwiftDemanglerMatchesSwiftDemangle() throws {
        let binary = try compile("""
        struct Box<T> { var value: T }
        func make(_ x: Int) -> Box<Int> { Box(value: x) }
        class Animal { func speak() -> String { "" } }
        print(make(1).value, Animal().speak())
        """, ext: "swift", args: ["swiftc", "-O"])

        let symbols = mangledSymbols(binary, prefix: "$s").filter { !$0.hasSuffix("Mp") && !$0.hasSuffix("Mn") }
        try XCTSkipIf(symbols.isEmpty, "no Swift-mangled symbols recovered")
        let invocationsBeforeDifferential = xcrunInvocationCount
        let result = differential(symbols: symbols, tool: "swift-demangle", normalizeForDemangler: { $0 })
        XCTAssertEqual(xcrunInvocationCount - invocationsBeforeDifferential, 1)
        print("SWIFTDEMANGLE-GATE correct=\(result.correct) total-mangled=\(result.total) mismatches=\(result.mismatches.count)")

        XCTAssertTrue(result.mismatches.isEmpty,
                      "Demangler WRONG-OUTPUT vs swift-demangle (0-wrong violated):\n" + result.mismatches.joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(result.correct, 28,
                                    "Demangler demangled \(result.correct)/\(result.total) Swift symbols")
    }
}
