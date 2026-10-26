import XCTest
@testable import MacScope

/// Phase-0 byte-identity anchor for the per-image container refactor.
///
/// The single-image analysis pipeline must stay byte-identical across the refactor. `GoldenOutput`
/// is the canonical oracle for this: it normalizes away every nondeterministic field (runtime
/// UUIDs, absolute paths, the embedded Mach-O UUID) and renders all 23 derived analysis products
/// into deterministic JSON — proven stable by `GoldenOutputTests`.
///
/// This test compares the PRE-refactor golden bytes for `/bin/ls` when the local anchor exists.
/// Capturing a new anchor is an explicit developer action so an ordinary test run never mutates its
/// admitted source tree.
///
/// The captured bytes are host-specific (they depend on this machine's `/bin/ls`), so they are a
/// LOCAL wave artifact — git-ignored under `GoldenFixtures/prerefactor/`, exactly like the repo's
/// other host-reproducible golden outputs (`macscope.json`). On a host where the anchor is absent
/// (fresh checkout / CI / different `/bin/ls`), the test skips rather than writing into source. Set
/// `MACSCOPE_CAPTURE_PREREFACTOR_GOLDEN=1` only for the explicit pre-refactor capture action. The
/// byte gate is a same-host
/// developer gate during the wave — which is exactly what "pre-refactor vs post-refactor bytes"
/// requires.
@MainActor
final class PreRefactorByteIdentityTests: XCTestCase {
    private let systemBinaryURL = URL(fileURLWithPath: "/bin/ls")

    /// `GoldenFixtures/prerefactor/`, resolved from this file's compile-time path (survives no env).
    private func prerefactorDirectory() -> URL {
        TestSourceRoot.fileURL(#filePath)          // …/Tests/CoreTests/PreRefactorByteIdentityTests.swift
            .deletingLastPathComponent()          // …/Tests/CoreTests
            .appendingPathComponent("GoldenFixtures/prerefactor")
    }

    /// Assert `data` equals the committed/captured anchor `named`, or capture it if this host has
    /// none yet. Returns whether it asserted (true) or captured (false), for logging.
    @discardableResult
    private func assertOrCapture(_ data: Data, named name: String) throws -> Bool {
        let dir = prerefactorDirectory()
        let url = dir.appendingPathComponent(name)
        if let existing = try? Data(contentsOf: url) {
            XCTAssertEqual(data, existing,
                           "\(name): current output diverges from the pre-refactor byte anchor — "
                           + "single-image output is no longer byte-identical.")
            return true
        }
        let captureRequested =
            ProcessInfo.processInfo.environment["MACSCOPE_CAPTURE_PREREFACTOR_GOLDEN"] == "1"
        guard captureRequested else {
            throw XCTSkip("pre-refactor byte anchor is absent; explicit capture was not requested")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        print("PREREFACTOR_ANCHOR_CAPTURED -> \(url.path) (\(data.count) bytes)")
        return false
    }

    func testSingleImageGoldenJSONByteIdentity() throws {
        guard FileManager.default.isReadableFile(atPath: systemBinaryURL.path) else {
            throw XCTSkip("/bin/ls is not readable on this host")
        }
        let snapshot = try AnalysisEngine().analyze(url: systemBinaryURL)
        let json = try GoldenOutput(snapshot: snapshot).jsonData()
        // An explicit diagnostic may retain the current bytes outside the source tree.
        // This does not replace the anchor or change the comparison below.
        if let path = ProcessInfo.processInfo.environment["MACSCOPE_GOLDEN_OBSERVATION_PATH"] {
            let output = URL(fileURLWithPath: path).standardizedFileURL
            let source = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
            guard path.hasPrefix("/"),
                  !output.path.hasPrefix(source.path + "/"),
                  output.pathExtension == "json"
            else { throw CocoaError(.fileWriteInvalidFileName) }
            try json.write(to: output, options: .withoutOverwriting)
        }
        try assertOrCapture(json, named: "golden-ls.json")
    }
}
