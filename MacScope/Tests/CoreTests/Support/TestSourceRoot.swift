import Foundation

/// Locates the repository checkout that CoreTests read fixtures and sources from.
///
/// `#filePath` is a compile-time path. When the dev loop builds with compilation-cache prefix
/// mapping (`Scripts/dev_loop.sh`), the compiler sees every repository path under a constant
/// virtual root (`/^src/...`) so a compile cached by one worktree replays in another; the baked-in
/// `#filePath` then no longer names a real file. Tests therefore resolve repository paths through
/// this helper instead of using `#filePath` directly:
///
/// 1. `MACSCOPE_SOURCE_ROOT` in the test process environment (the dev loop exports
///    `TEST_RUNNER_MACSCOPE_SOURCE_ROOT`, which xcodebuild forwards without the prefix);
/// 2. otherwise the checkout this helper was compiled from, derived from its own `#filePath`
///    (unmapped builds: Xcode, the qualifier, CI).
///
/// `#filePath` uses that only feed XCTest failure locations stay as they are.
enum TestSourceRoot {
    /// This file's location relative to the repository root.
    private static let helperRelativePath = "MacScope/Tests/CoreTests/Support/TestSourceRoot.swift"

    /// The repository root as the compiler saw it (a real path, or the mapped virtual root).
    private static let compiledRoot: String = {
        let path = "\(#filePath)"
        let suffix = "/" + helperRelativePath
        precondition(path.hasSuffix(suffix), "TestSourceRoot.swift moved; update helperRelativePath")
        return String(path.dropLast(suffix.count))
    }()

    /// The repository root on disk.
    static let url: URL = {
        if let override = ProcessInfo.processInfo.environment["MACSCOPE_SOURCE_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: compiledRoot, isDirectory: true)
    }()

    /// Maps a compile-time source path (pass `#filePath`) to the same file under `url`.
    ///
    /// Equivalent to `URL(fileURLWithPath: #filePath)` in an unmapped build; in a prefix-mapped
    /// build it rebases the path from the virtual root onto the real checkout.
    static func fileURL(_ compiledPath: String) -> URL {
        let prefix = compiledRoot + "/"
        guard compiledPath.hasPrefix(prefix) else {
            return URL(fileURLWithPath: compiledPath)
        }
        return url.appendingPathComponent(String(compiledPath.dropFirst(prefix.count)))
    }
}
