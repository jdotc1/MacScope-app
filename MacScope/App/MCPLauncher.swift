import Darwin
import Foundation

enum MCPLauncherError: LocalizedError {
    case binaryIdentityChanged
    case analysisIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .binaryIdentityChanged:
            "The canonical binary changed while the headless workspace was active."
        case .analysisIdentityMismatch:
            "The analysis result does not belong to the canonical requested binary."
        }
    }
}

/// Headless MCP mode: `MacScope --mcp <binary-path | workspace.mscope>` loads the binary (or
/// opens the saved workspace package, HOP-6) and serves the
/// MCP (JSON-RPC) protocol over stdio instead of presenting the GUI. This is the
/// runnable transport on top of `MCPServer` — an MCP client launches the app with the
/// flag and talks newline-delimited JSON over the process's stdin/stdout.
enum MCPLauncher {
    struct BoundStore {
        let store: WorkspaceStore
        fileprivate let fingerprint: WorkspaceScriptingAPI.CallArgumentAuditFileFingerprint

        func validateIdentity() throws {
            try MCPLauncher.validateBinaryIdentity(fingerprint)
        }

        /// HOP-6: the launch binary is guarded only while the workspace's primary image is still
        /// that binary. After `open-workspace` replaces the workspace with another package's
        /// images, the launch file no longer backs anything this session serves.
        @MainActor
        func validateIdentityWhileBound() throws {
            guard let primary = store.snapshot.binaries.first,
                  URL(fileURLWithPath: primary.path).resolvingSymlinksInPath().standardizedFileURL.path
                    == fingerprint.canonicalPath else { return }
            try validateIdentity()
        }
    }

    /// HOP-6: `--mcp <workspace.mscope>` opens a saved workspace package instead of analyzing a
    /// binary. A package is a directory with the `.mscope` extension.
    static func isWorkspacePackage(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return url.pathExtension.lowercased() == WorkspaceScriptingAPI.workspacePackageExtension
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Parses `--mcp <path>` or `--mcp=<path>` — but ONLY when the flag occupies the
    /// mode slot (the first argument after the program name). Scanning all of argv would
    /// let a positional value from another launch mode (e.g. a `--run-script` path that
    /// happened to start with `--mcp=`) be misread as an MCP selector, silently running
    /// the wrong mode on the wrong file. nil if absent.
    static func requestedBinary(from arguments: [String]) -> URL? {
        guard let flag = arguments.dropFirst().first else { return nil }
        if flag == "--mcp" {
            guard arguments.count == 3 else { return nil }
            return canonicalURL(forPath: arguments[2])
        }
        if flag.hasPrefix("--mcp=") {
            guard arguments.count == 2 else { return nil }
            let path = String(flag.dropFirst("--mcp=".count))
            return canonicalURL(forPath: path)
        }
        return nil
    }

    static func canonicalURL(forPath path: String) -> URL? {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    /// Loads the binary into a headless workspace store.
    @MainActor
    static func makeStore(binaryURL: URL, engine: any AnalysisProviding = AnalysisEngine()) throws -> WorkspaceStore {
        try makeBoundStore(binaryURL: binaryURL, engine: engine).store
    }

    /// Binds one canonical regular file identity to the returned store. The whole-file
    /// fingerprint is checked on both sides of analysis so a symlink retarget, replacement,
    /// truncation, or in-place edit cannot silently establish a different workspace.
    @MainActor
    static func makeBoundStore(
        binaryURL: URL,
        engine: any AnalysisProviding = AnalysisEngine()
    ) throws -> BoundStore {
        let initial = try WorkspaceScriptingAPI.callArgumentAuditFileFingerprint(at: binaryURL)
        let canonicalURL = URL(fileURLWithPath: initial.canonicalPath).standardizedFileURL
        let snapshot = try engine.analyze(
            url: canonicalURL, requestedSliceIndex: nil, overrides: [:], cancellation: .never
        )
        let final = try WorkspaceScriptingAPI.callArgumentAuditFileFingerprint(at: canonicalURL)
        guard final == initial else { throw MCPLauncherError.binaryIdentityChanged }
        guard let primary = snapshot.binaries.first,
              URL(fileURLWithPath: primary.path)
                .resolvingSymlinksInPath().standardizedFileURL.path == canonicalURL.path else {
            throw MCPLauncherError.analysisIdentityMismatch
        }
        let store = WorkspaceStore(
            workspaceName: canonicalURL.lastPathComponent,
            snapshot: snapshot,
            engine: engine
        )
        return BoundStore(store: store, fingerprint: initial)
    }

    private static func validateBinaryIdentity(
        _ fingerprint: WorkspaceScriptingAPI.CallArgumentAuditFileFingerprint
    ) throws {
        let canonicalURL = URL(fileURLWithPath: fingerprint.canonicalPath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard canonicalURL.path == fingerprint.canonicalPath else {
            throw MCPLauncherError.binaryIdentityChanged
        }
        var metadata = stat()
        guard stat(canonicalURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              UInt64(metadata.st_dev) == fingerprint.device,
              UInt64(metadata.st_ino) == fingerprint.inode,
              Int64(metadata.st_size) == fingerprint.size,
              Int64(metadata.st_mtimespec.tv_sec) == fingerprint.modificationSeconds,
              Int64(metadata.st_mtimespec.tv_nsec) == fingerprint.modificationNanoseconds,
              Int64(metadata.st_ctimespec.tv_sec) == fingerprint.changeSeconds,
              Int64(metadata.st_ctimespec.tv_nsec) == fingerprint.changeNanoseconds else {
            throw MCPLauncherError.binaryIdentityChanged
        }
    }

    /// Loads the binary, serves the MCP protocol over stdio, and exits. Runs at program
    /// entry on the main thread (no SwiftUI run loop). Initial analysis is synchronous;
    /// dispatchMain then serves the async transport and MainActor command owner.
    @MainActor
    static func run(binaryURL: URL) -> Never {
        do {
            let protocolOutput = try HeadlessProtocolIO.isolateStandardOutput()
            let store: WorkspaceStore
            let validateIdentity: @MainActor () throws -> Void
            if isWorkspacePackage(binaryURL) {
                // The package carries its own input bytes; there is no launch file to guard.
                // Package I/O stays in the headless scripting document layer (no GUI
                // document session exists in this process), next to open-workspace.
                store = try WorkspaceScriptingAPI.openLaunchWorkspacePackage(at: binaryURL)
                validateIdentity = {}
            } else {
                let boundStore = try makeBoundStore(binaryURL: binaryURL)
                store = boundStore.store
                validateIdentity = { try boundStore.validateIdentityWhileBound() }
            }
            let server = MCPServer(
                api: WorkspaceScriptingAPI(
                    store: store,
                    nativeDecompiler: NativeDecompilerRuntimeRegistry.productionShared
                ),
                validateWorkspaceIdentity: validateIdentity
            )
            Task { @MainActor in
                await server.runStdioLoopAsync(output: protocolOutput)
                try? protocolOutput.close()
                exit(0)
            }
            dispatchMain()
        } catch {
            FileHandle.standardError.write(Data("MacScope MCP: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
