import Foundation

/// HOP-6: typed failures of the scripting/MCP workspace open and save tools. Each description
/// starts with a stable machine-readable code so an MCP client (which only sees the text) can
/// branch on it.
enum WorkspaceDocumentScriptingError: LocalizedError, Equatable {
    /// The path is empty, relative, contains NUL, or does not name a `.mscope` package.
    case invalidPath(String)
    /// Nothing exists at the workspace path (open), or the save target's folder is missing.
    case pathMissing(String)
    /// The workspace was written by a newer analyzer (HS-2 stamp); nothing was changed.
    case newerAnalyzerVersion(Int, missingFeatures: [String])
    /// `save-workspace` without `path` on a workspace that was never saved or opened.
    case noDocumentPath
    /// The package could not be read or validated; the current workspace is unchanged.
    case openFailed(String)
    /// The package could not be written; any prior package at the path is kept.
    case writeFailed(String)

    var code: String {
        switch self {
        case .invalidPath: "workspace-invalid-path"
        case .pathMissing: "workspace-path-missing"
        case .newerAnalyzerVersion: "workspace-newer-analyzer"
        case .noDocumentPath: "workspace-no-document-path"
        case .openFailed: "workspace-open-failed"
        case .writeFailed: "workspace-write-failed"
        }
    }

    var errorDescription: String? {
        let detail: String
        switch self {
        case .invalidPath(let path):
            detail = "'\(path)' is not an absolute path to a .mscope workspace package"
        case .pathMissing(let path):
            detail = "nothing exists at \(path)"
        case .newerAnalyzerVersion(let version, let missing):
            detail = "the workspace was saved by a newer MacScope analyzer (version \(version); this build reads up to "
                + "version \(WorkspaceAnalyzerStamp.currentVersion)); this build lacks: " + missing.joined(separator: "; ")
        case .noDocumentPath:
            detail = "the workspace has no saved location; pass `path`"
        case .openFailed(let reason):
            detail = "the workspace could not be opened and the current workspace is unchanged: \(reason)"
        case .writeFailed(let reason):
            detail = "the workspace could not be saved: \(reason)"
        }
        return "\(code): \(detail)."
    }
}

/// HOP-6: open an existing `.mscope` workspace into the bound store and save the current one,
/// through the same store paths the GUI's File ▸ Open / Save As use (atomic package publication,
/// HS-2 analyzer stamp on save, newer-analyzer refusal and HS-1 repair on open). No live relay to a
/// running GUI: the headless process owns its own store. Commands keep reading the primary image.
extension WorkspaceScriptingAPI {
    typealias DocumentCommand = (
        info: ScriptingCommandInfo,
        run: @MainActor (ScriptValue, WorkspaceStore) throws -> ScriptValue
    )

    nonisolated static let workspacePackageExtension = "mscope"

    nonisolated static var workspaceDocumentCommands: [DocumentCommand] {
        [
            (ScriptingCommandInfo(
                name: "open-workspace",
                summary: "Open the saved .mscope workspace at absolute `path` into this session, replacing the current workspace (annotations, overrides and analysis come from the package). A workspace saved by a newer analyzer is refused and nothing changes; an inconsistent saved analysis is repaired and the affected image re-analyzed. Commands keep defaulting to the primary image.",
                mutates: true, arguments: ["path"]
            ), { arguments, store in try openWorkspace(arguments, store: store) }),
            (ScriptingCommandInfo(
                name: "save-workspace",
                summary: "Save the current workspace as a .mscope package at absolute `path` (or, without `path`, to the package it was last opened from or saved to). Written atomically; a failed save keeps any prior package at that path.",
                mutates: true, arguments: ["path"]
            ), { arguments, store in try saveWorkspace(arguments, store: store) }),
        ]
    }

    /// Validates a caller path: absolute after `~` expansion, no NUL, `.mscope` extension.
    static func workspacePackageURL(_ raw: String) throws -> URL {
        let expanded = (raw as NSString).expandingTildeInPath
        guard !raw.isEmpty, expanded.hasPrefix("/"),
              !expanded.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw WorkspaceDocumentScriptingError.invalidPath(raw)
        }
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        guard url.pathExtension.lowercased() == workspacePackageExtension,
              url.deletingPathExtension().lastPathComponent.isEmpty == false else {
            throw WorkspaceDocumentScriptingError.invalidPath(raw)
        }
        return url
    }

    private static func pathArgument(_ arguments: ScriptValue) throws -> String? {
        switch arguments["path"] {
        case .none, .some(.null): return nil
        case .some(.string(let path)): return path
        case .some: throw ScriptingError.invalidArgument("path must be a string")
        }
    }

    private static func openWorkspace(_ arguments: ScriptValue, store: WorkspaceStore) throws -> ScriptValue {
        guard let raw = try pathArgument(arguments) else { throw ScriptingError.missingArgument("path") }
        let url = try workspacePackageURL(raw)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WorkspaceDocumentScriptingError.pathMissing(url.path)
        }
        let root: URL
        do {
            root = try store.openDocumentPackageThrowing(at: url)
        } catch MacScopeDocumentPackage.PackageError.newerAnalyzerVersion(let version, let missing) {
            throw WorkspaceDocumentScriptingError.newerAnalyzerVersion(version, missingFeatures: missing)
        } catch {
            throw WorkspaceDocumentScriptingError.openFailed(error.localizedDescription)
        }
        let snapshot = store.snapshot
        return .object([
            "ok": .bool(true),
            "path": .string(root.path),
            "workspaceName": .string(store.workspaceName),
            "primaryImage": .string(snapshot.binaries.first?.name ?? ""),
            "imageCount": .int(Int64(snapshot.binaries.count)),
            "functionCount": .int(Int64(snapshot.functions.count)),
            "repairs": .array(store.lastAnalysisRepairs.flatMap { repair in
                repair.items.map { ScriptValue.string("\(repair.imageName): \($0)") }
            }),
        ])
    }

    /// `--mcp <x.mscope>`: restores the package into a fresh store owned by the headless MCP
    /// process. This is the headless compatibility counterpart of `open-workspace`: the process
    /// has no window, session registry or WorkspaceDocumentSession, so there is no document
    /// authority to route through (the boundary test keeps App/Features off the legacy package
    /// entry points). Same typed failures as `open-workspace`.
    @MainActor
    static func openLaunchWorkspacePackage(at url: URL) throws -> WorkspaceStore {
        do {
            return try WorkspaceStore.restoredPackage(from: url)
        } catch MacScopeDocumentPackage.PackageError.newerAnalyzerVersion(let version, let missing) {
            throw WorkspaceDocumentScriptingError.newerAnalyzerVersion(version, missingFeatures: missing)
        } catch {
            throw WorkspaceDocumentScriptingError.openFailed(error.localizedDescription)
        }
    }

    private static func saveWorkspace(_ arguments: ScriptValue, store: WorkspaceStore) throws -> ScriptValue {
        let url: URL
        if let raw = try pathArgument(arguments) {
            url = try workspacePackageURL(raw)
        } else if let documentURL = store.documentURL {
            url = documentURL
        } else {
            throw WorkspaceDocumentScriptingError.noDocumentPath
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorkspaceDocumentScriptingError.pathMissing(parent.path)
        }
        let saved: (url: URL, manifest: WorkspacePackageManifest)
        do {
            saved = try store.writeDocumentPackageThrowing(to: url)
        } catch {
            throw WorkspaceDocumentScriptingError.writeFailed(error.localizedDescription)
        }
        return .object([
            "ok": .bool(true),
            "path": .string(saved.url.path),
            "analyzerVersion": .int(Int64(saved.manifest.analyzer?.version ?? WorkspaceAnalyzerStamp.currentVersion)),
            "functionCount": .int(Int64(store.snapshot.functions.count)),
        ])
    }
}
