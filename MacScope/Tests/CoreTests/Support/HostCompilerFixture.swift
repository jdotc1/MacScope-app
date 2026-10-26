import Foundation
import XCTest

/// Compiles a small fixture on the host with `xcrun clang`, for tests that need a real binary.
/// Skips (`XCTSkip`) when the toolchain is unavailable or the compile fails. Shared so the skip
/// allowlist gate counts every caller: `Scripts/check_test_skip_allowlist.py` treats
/// `HostCompilerFixture.objc(` as a reviewed cross-file skip.
enum HostCompilerFixture {
    /// An arm64 Objective-C executable linked against Foundation, with selector stubs off so
    /// message sends load their selector references inline.
    static func objc(_ source: String) throws -> URL {
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else { throw XCTSkip("xcrun unavailable") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("host-objc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("t.m")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let binary = dir.appendingPathComponent("t")
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["clang", "-arch", "arm64", "-fobjc-arc", "-fno-objc-msgsend-selector-stubs",
                             "-framework", "Foundation", "-o", binary.path, file.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let drain = CoreTestPipeDrain(pipe)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw XCTSkip("clang failed: \(drain.text())") }
        return binary
    }
}
