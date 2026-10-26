import Foundation

/// Where tests put scratch and stage directories, with no machine-specific path.
///
/// MACSCOPE_WORK_ROOT names the folder that holds MacScope caches, lanes and evidence.
enum TestWorkRoot {
    /// Scratch parent for fixtures production code never checks against the stage authority:
    /// the work root when MACSCOPE_WORK_ROOT is set to an existing directory, else the
    /// symlink-resolved temporary directory.
    static var scratch: URL {
        if let value = ProcessInfo.processInfo.environment["MACSCOPE_WORK_ROOT"], value.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        }
        return FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    }

    /// Parent that production stage-authority checks accept: the work root, or the home
    /// directory when MACSCOPE_WORK_ROOT is unset (these paths must be under it, so the
    /// temporary directory cannot be used).
    static var authority: URL { MacScopeWorkRoot.url }

    static func authorityPath(_ name: String) -> String {
        authority.appendingPathComponent(name).path
    }

    static func authorityURL(_ name: String, isDirectory: Bool = false) -> URL {
        authority.appendingPathComponent(name, isDirectory: isDirectory)
    }

    static func scratchURL(_ name: String, isDirectory: Bool = false) -> URL {
        scratch.appendingPathComponent(name, isDirectory: isDirectory)
    }
}
